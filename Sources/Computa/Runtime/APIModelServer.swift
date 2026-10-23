import Foundation
import Network
import Darwin
import CoreFoundation
import OSLog

/// The engine speaks Responses on loopback; only this actor handles provider credentials.
/// It never runs tools, changes permissions, or replays a failed inference.
actor APIModelServer {
    enum Failure: String, Error, LocalizedError, Sendable {
        case invalidRequest, unauthorized, modelUnavailable, busy, cancelled, stopped, credentialUnavailable, inferenceContextRequired, toolNamingUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The local API model request is invalid."
            case .unauthorized: "The local API model request was not authorized."
            case .modelUnavailable: "The configured API model is no longer available."
            case .busy: "This task already has an active API inference. No request was replayed."
            case .cancelled: "The API inference was cancelled. No request was replayed."
            case .stopped: "The local API model service is stopped."
            case .credentialUnavailable: "The API credential could not be read from secure storage."
            case .inferenceContextRequired: "The API inference does not belong to the current native turn."
            case .toolNamingUnavailable: "This chat's API tool naming could not be verified. No provider request was sent."
            }
        }
    }
    nonisolated let bearerToken = UUID().uuidString + UUID().uuidString
    private let credentials: any APIProviderCredentials
    private let client: APIProviderHTTPClient
    private let suppliedCapsules: APIReasoningCapsules?
    private let rejectionDiagnosticsDirectory: URL?
    private let toolNamingDirectory: URL?
    private let correctionAccountingDirectory: URL?
    private let inferenceTimeout: Duration
    private var correctionsUsed: [String: Context] = [:]
    private var capsules: APIReasoningCapsules?
    private var providers: [APIProviderDefinition] = []
    private var listener: NWListener?
    private var baseURL: URL?
    private var starting: Task<URL, Error>?
    private var stopped = false
    private let queue = DispatchQueue(label: "com.ahmedelamin.Computa.api-model-http")
    private static let responseLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "APIModelResponse")
    enum FailureStage: String, Sendable, CaseIterable, Equatable {
        case prepare, requestTransport = "request_transport", decode, eventSerialization = "event_serialization"
    }
    private struct StagedFailure: Error {
        let stage: FailureStage
        let cause: any Error
        var argumentDiagnostic: ArgumentFailureDiagnostic? = nil
        var responseDiagnostic: ResponseFailureDiagnostic? = nil
    }
    struct ArgumentFailureDiagnostic: Codable, Sendable {
        enum Gate: String, Codable, Sendable {
            case decoderExcluded = "decoder_excluded", accountingDisabled = "accounting_disabled"
            case accountingUnavailable = "accounting_unavailable", budgetExhausted = "budget_exhausted"
            case correctionRejected = "correction_rejected"
        }
        let validation: APIModelResponseCodec.ArgumentValidationDiagnostic?
        let gate: Gate
        let attempt: Int
    }
    struct ResponseFailureDiagnostic: Codable, Sendable {
        let validation: APIModelResponseCodec.InvalidResponseDiagnostic
        let attempt: Int
    }
    struct FailureDiagnosticContext: Codable, Sendable {
        let taskID: UUID
        let threadID: UUID
        let turnID: UUID
    }
#if DEBUG
    private var failureDiagnosticsObserverForTesting: (@Sendable (String) -> Void)?
    private var beforeCorrectionDispatchForTesting: (@Sendable () async throws -> Void)?
    private var beforeInferenceDispatchForTesting: (@Sendable () async throws -> Void)?
    func setBeforeCorrectionDispatchForTesting(_ hook: (@Sendable () async throws -> Void)?) { beforeCorrectionDispatchForTesting = hook }
    func setBeforeInferenceDispatchForTesting(_ hook: (@Sendable () async throws -> Void)?) { beforeInferenceDispatchForTesting = hook }
    func setFailureDiagnosticsObserverForTesting(_ observer: (@Sendable (String) -> Void)?) {
        failureDiagnosticsObserverForTesting = observer
    }
#endif
    private struct Connection { let socket: NWConnection; let task: Task<Void, Never> }
    private var connections: [UUID: Connection] = [:]
    private struct Lane { let id: UUID; let request: Task<APIModelResponseCodec.Reply, Error> }
    private var lanes: [String: Lane] = [:]
    private struct Prepared: Equatable { let threadID: String; let preparationID: UUID; let isNewThread: Bool; let executionPolicy: String?; let userRequest: Data? }
    private struct Identity: Equatable, Sendable { let threadID: String; let turnID: String }
    private struct Context: Equatable, Sendable { let identity: Identity; let preparationID: UUID; let isNewThread: Bool; let executionPolicy: String?; let userRequest: Data? }
    private struct ExecutionCheckpoint { let context: Context; let revision: Int; let text: String }
    private struct NativeRequestContext { let identity: Identity; let requestKind: String? }
    private struct ActiveUserInputs { let context: Context; var revision: Int; var inputs: [Data] }
    private struct UserInputUpdate {
        let context: Context; let ticket: UUID; let baseRevision: Int; let input: Data
        let deadline: ContinuousClock.Instant
        var timeout: Task<Void, Never>?
    }
    private struct UserInputWaiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Context, Error> }
    private var prepared: [String: Prepared] = [:]
    private var contexts: [String: Context] = [:]
    private var executionCheckpoints: [String: ExecutionCheckpoint] = [:]
    private var activeUserInputs: [String: ActiveUserInputs] = [:]
    private var userInputUpdates: [String: UserInputUpdate] = [:]
    private var userInputWaiters: [String: UserInputWaiter] = [:]
    private let userInputUpdateTimeout: Duration
    private var waiters: [String: Waiter] = [:]
    private var admissions: [String: UUID] = [:]
    private var retiring = Set<String>()
    private var retirementWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(credentials: any APIProviderCredentials = APIProviderCredentialStore(),
         client: APIProviderHTTPClient = APIProviderHTTPClient(), capsules: APIReasoningCapsules? = nil,
         rejectionDiagnosticsDirectory: URL? = nil, toolNamingDirectory: URL? = nil,
         correctionAccountingDirectory: URL? = nil, inferenceTimeout: Duration = .seconds(300),
         userInputUpdateTimeout: Duration = .seconds(30)) {
        self.userInputUpdateTimeout = userInputUpdateTimeout
        self.credentials = credentials; self.client = client; suppliedCapsules = capsules
        self.rejectionDiagnosticsDirectory = rejectionDiagnosticsDirectory
        self.toolNamingDirectory = toolNamingDirectory
        self.correctionAccountingDirectory = correctionAccountingDirectory
        self.inferenceTimeout = min(max(inferenceTimeout, .milliseconds(1)), .seconds(300))
    }
    func updateProviders(_ values: [APIProviderDefinition]) throws {
        try APIProviderCatalog.validate(values)
        for provider in values { _ = try APIProviderHTTPClient.endpoint(provider.baseURL, path: "models") }
        // Active Request values are immutable snapshots. A settings edit cannot redirect
        // an already admitted inference or replace its selected model midway through it.
        providers = values
    }
    /// The Core configuration reservation prevents new submissions while this atomic
    /// actor transaction validates, mutates Keychain and replaces the registry.
    func applyProviderConfiguration(_ values: [APIProviderDefinition],
                                    credentialUpdate: @escaping @Sendable () throws -> Void) throws {
        try APIProviderCatalog.validate(values)
        for provider in values { _ = try APIProviderHTTPClient.endpoint(provider.baseURL, path: "models") }
        guard lanes.isEmpty, admissions.isEmpty, prepared.isEmpty, contexts.isEmpty, retiring.isEmpty else { throw Failure.busy }
        try credentialUpdate()
        providers = values
    }
    func start() async throws -> URL {
        if let baseURL { return baseURL }
        if let starting { return try await starting.value }
        let task = Task { try await self.startListener() }; starting = task
        defer { starting = nil }
        return try await task.value
    }
    private func startListener() async throws -> URL {
        try Task.checkCancellation(); stopped = false
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = APIListenerReady(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port { once.finish(.success(port.rawValue)) }
                    else { once.finish(.failure(Failure.stopped)) }
                case .failed: once.finish(.failure(Failure.stopped))
                case .cancelled: once.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        try Task.checkCancellation(); guard !stopped else { throw Failure.stopped }
        let url = URL(string: "http://127.0.0.1:\(port)/v1")!; baseURL = url; return url
    }
    func prepareInferenceTurn(taskID: String, threadID: String, preparationID: UUID, isNewThread: Bool = false,
                              executionPolicy: String? = nil, userRequest: String? = nil) throws {
        let task = try Self.canonicalID(taskID), thread = try Self.canonicalID(threadID)
        if let executionPolicy { try Self.validateExecutionText(executionPolicy, limit: 8_192) }
        let userRequest = try userRequest.map { try Self.validatedUserInput($0) }
        guard !stopped, !retiring.contains(task), lanes[task] == nil, admissions[task] == nil else { throw Failure.busy }
        let value = Prepared(threadID: thread, preparationID: preparationID, isNewThread: isNewThread,
            executionPolicy: executionPolicy, userRequest: userRequest)
        if prepared[task] == value { return }
        guard prepared[task] == nil, contexts[task] == nil else { throw Failure.inferenceContextRequired }
        prepared[task] = value
    }
    func registerInferenceTurn(taskID: String, threadID: String, turnID: String, preparationID: UUID) throws {
        let task = try Self.canonicalID(taskID)
        let identity = Identity(threadID: try Self.canonicalID(threadID), turnID: try Self.canonicalID(turnID))
        guard let preparation = prepared[task], preparation.threadID == identity.threadID,
              preparation.preparationID == preparationID else { throw Failure.inferenceContextRequired }
        let value = Context(identity: identity, preparationID: preparationID, isNewThread: preparation.isNewThread,
                            executionPolicy: preparation.executionPolicy, userRequest: preparation.userRequest)
        if contexts[task] == value { return }
        guard !stopped, !retiring.contains(task), contexts[task] == nil,
              prepared[task] == preparation else { throw Failure.inferenceContextRequired }
        contexts[task] = value
        if value.executionPolicy != nil || value.userRequest != nil {
            executionCheckpoints[task] = .init(context: value, revision: 0,
                text: "No browser operations are recorded for this prepared turn.")
        }
        if let input = value.userRequest { activeUserInputs[task] = .init(context: value, revision: 0, inputs: [input]) }
        waiters.removeValue(forKey: task)?.continuation.resume(returning: value)
    }
    /// Native Core only. There is no HTTP/tool endpoint for this host evidence.
    /// Updating the checkpoint does not alter immutable admission identity or
    /// invalidate an inference already dispatched with an earlier snapshot.
    func updateExecutionCheckpoint(taskID: String, threadID: String, turnID: String,
                                   preparationID: UUID, revision: Int, checkpoint: String) throws {
        let task = try Self.canonicalID(taskID)
        let identity = Identity(threadID: try Self.canonicalID(threadID), turnID: try Self.canonicalID(turnID))
        try Self.validateExecutionText(checkpoint, limit: 4_096)
        guard revision > 0 else { throw Failure.invalidRequest }
        guard !stopped, !retiring.contains(task), let context = contexts[task],
              context.identity == identity, context.preparationID == preparationID,
              context.executionPolicy != nil || context.userRequest != nil,
              prepared[task]?.preparationID == preparationID,
              let current = executionCheckpoints[task], current.context == context else { throw Failure.inferenceContextRequired }
        // Actor reentrancy can deliver a delayed cumulative update after a newer
        // one. Chronology must never move backwards within the same native turn.
        if revision < current.revision { return }
        if revision == current.revision {
            guard checkpoint == current.text else { throw Failure.invalidRequest }
            return
        }
        executionCheckpoints[task] = .init(context: context, revision: revision, text: checkpoint)
    }

    /// Stage before turn/steer is sent. Already-dispatched inference keeps its
    /// snapshot; new admissions wait for an unambiguous acknowledgment.
    func beginUserInputUpdate(taskID: String, threadID: String, turnID: String,
                              preparationID: UUID, prompt: String) throws -> UUID {
        let task = try Self.canonicalID(taskID)
        let context = try activeUserContext(task: task, threadID: threadID, turnID: turnID, preparationID: preparationID)
        guard userInputUpdates[task] == nil else { throw Failure.busy }
        let input = try Self.validatedUserInput(prompt), current = activeUserInputs[task]!
        guard current.inputs.count < 1_024,
              current.inputs.reduce(input.count, { $0 + $1.count }) <= 2_000_000 else { throw Failure.invalidRequest }
        let ticket = UUID(), deadline = ContinuousClock.now.advanced(by: userInputUpdateTimeout)
        userInputUpdates[task] = .init(context: context, ticket: ticket, baseRevision: current.revision,
            input: input, deadline: deadline)
        userInputUpdates[task]?.timeout = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.expireUserInputUpdate(task: task, ticket: ticket)
        }
        return ticket
    }

    /// accepted=false requires a confirmed engine rejection. An ambiguous RPC
    /// outcome must cancel/retire the context rather than restore stale inputs.
    func resolveUserInputUpdate(taskID: String, threadID: String, turnID: String,
                                preparationID: UUID, ticket: UUID, accepted: Bool) throws {
        let task = try Self.canonicalID(taskID)
        let context = try activeUserContext(task: task, threadID: threadID, turnID: turnID, preparationID: preparationID)
        guard let staged = userInputUpdates[task], staged.context == context, staged.ticket == ticket,
              staged.deadline > ContinuousClock.now,
              var current = activeUserInputs[task], current.revision == staged.baseRevision else { throw Failure.inferenceContextRequired }
        if accepted {
            current.inputs.append(staged.input); current.revision += 1
            activeUserInputs[task] = current
        }
        userInputUpdates.removeValue(forKey: task)?.timeout?.cancel()
        userInputWaiters.removeValue(forKey: task)?.continuation.resume()
    }
    private func activeUserContext(task: String, threadID: String, turnID: String, preparationID: UUID) throws -> Context {
        let identity = Identity(threadID: try Self.canonicalID(threadID), turnID: try Self.canonicalID(turnID))
        guard !stopped, !retiring.contains(task), let context = contexts[task],
              context.identity == identity, context.preparationID == preparationID,
              prepared[task]?.preparationID == preparationID,
              activeUserInputs[task]?.context == context else { throw Failure.inferenceContextRequired }
        return context
    }
    private static func validatedUserInput(_ input: String) throws -> Data {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.utf8.count <= 2_000_000 else { throw Failure.invalidRequest }
        return Data(input.utf8) // Preserve exact Unicode/whitespace; never normalize or summarize.
    }
    private func expireUserInputUpdate(task: String, ticket: UUID) {
        guard userInputUpdates[task]?.ticket == ticket else { return }
        // Keep the staged transaction closed until Core resolves or retires it.
        // A timeout cannot prove the engine rejected an accepted restriction.
        userInputWaiters.removeValue(forKey: task)?.continuation.resume(throwing: Failure.inferenceContextRequired)
    }
    private func awaitUserInputUpdate(task: String, context: Context) async throws {
        while let staged = userInputUpdates[task] {
            guard staged.context == context, staged.deadline > ContinuousClock.now, userInputWaiters[task] == nil else { throw Failure.inferenceContextRequired }
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    userInputWaiters[task] = .init(id: id, continuation: continuation)
                }
            } onCancel: { Task { await self.cancelUserInputWaiter(task: task, id: id) } }
            guard !stopped, !retiring.contains(task), contexts[task] == context else { throw Failure.cancelled }
        }
    }
    private func cancelUserInputWaiter(task: String, id: UUID) {
        guard userInputWaiters[task]?.id == id else { return }
        userInputWaiters.removeValue(forKey: task)?.continuation.resume(throwing: Failure.cancelled)
    }
    #if DEBUG
    func userInputAdmissionIsWaitingForTesting(taskID: String) -> Bool {
        guard let task = try? Self.canonicalID(taskID) else { return false }
        return userInputWaiters[task] != nil
    }
    #endif
    private static func validateExecutionText(_ value: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= limit else { throw Failure.invalidRequest }
    }
    private func executionMessage(taskID: String, context: Context, remindsUser: Bool,
                                  purpose: APIModelResponseCodec.HostProjectionPurpose) throws -> String? {
        guard context.executionPolicy != nil || context.userRequest != nil else { return nil }
        guard let checkpoint = executionCheckpoints[taskID], checkpoint.context == context else {
            throw Failure.inferenceContextRequired
        }
        var message = """
        APP_RUNTIME_EXECUTION_CHECKPOINT
        Host current turn: \(context.identity.turnID)
        This is current host execution evidence, independent of conversation history. Summaries and prior assistant claims are not current tool receipts or permission policy. Preserve the user's constraints and follow the current host policy. Do not invent an execution result or access restriction from a historical summary.
        Current-turn checkpoint:
        \(checkpoint.text)
        """
        if let policy = context.executionPolicy { message += "\nHost interaction policy:\n" + policy }
        if purpose == .nativeCompaction {
            message += """

            This inference performs context maintenance only. Do not execute tools, answer the user's task, restart work or replay completed or uncertain actions. The final user-role message is the runtime's maintenance instruction and remains last; it is not a new human task or authorization.
            """
            if remindsUser {
                message += """

                Immediately before the final maintenance instruction are exact user-level reminders of this active native turn's original request and accepted steers, in order. Preserve that active request in the continuation notes; later accepted user steering may revise earlier user instructions. Preserve ongoing user restrictions and their scope from the existing history. Do not substitute an older task or this maintenance instruction for the active request. These reminders retain user authority and are not new instructions to execute or repeat any action during maintenance.
                """
            }
        } else if remindsUser {
            message += """

            The following user messages repeat this same active native turn's original request and accepted steers, in order. They are reminders of the current task, not a new turn or a request to restart, repeat completed actions or replay uncertain input. Preserve their user-level authority and constraints. Continue remaining work using current tool evidence. A maintenance prompt or historical summary does not replace this active request.
            """
        }
        return message
    }
    func finish(taskID: String) async { await cancel(taskID: taskID) }
    func cancel(taskID: String) async {
        guard let task = try? Self.canonicalID(taskID) else { return }
        retiring.insert(task)
        prepared.removeValue(forKey: task); contexts.removeValue(forKey: task); correctionsUsed.removeValue(forKey: task)
        executionCheckpoints.removeValue(forKey: task)
        activeUserInputs.removeValue(forKey: task)
        userInputUpdates.removeValue(forKey: task)?.timeout?.cancel()
        userInputWaiters.removeValue(forKey: task)?.continuation.resume(throwing: Failure.cancelled)
        waiters.removeValue(forKey: task)?.continuation.resume(throwing: Failure.cancelled)
        if let lane = lanes[task] {
            lane.request.cancel(); _ = await lane.request.result
            if lanes[task]?.id == lane.id { lanes.removeValue(forKey: task) }
        }
        if admissions[task] != nil {
            await withCheckedContinuation { retirementWaiters[task, default: []].append($0) }
        }
        retiring.remove(task)
    }
    private static func canonicalID(_ value: String) throws -> String {
        guard let id = UUID(uuidString: value) else { throw Failure.inferenceContextRequired }
        return id.uuidString.lowercased()
    }
    private static func nativeIdentity(_ body: [String: Any], header: String?) throws -> NativeRequestContext {
        func parse(_ value: String) throws -> NativeRequestContext {
            guard value.utf8.count <= 16_384,
                  let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                  let thread = object["thread_id"] as? String, let turn = object["turn_id"] as? String else { throw Failure.inferenceContextRequired }
            let kind: String?
            if let value = object["request_kind"] {
                guard let text = value as? String, ["turn", "prewarm", "compaction", "memory"].contains(text) else { throw Failure.inferenceContextRequired }
                kind = text
            } else { kind = nil }
            return try .init(identity: Identity(threadID: canonicalID(thread), turnID: canonicalID(turn)), requestKind: kind)
        }
        let headerValue = try header.map(parse)
        var bodyValue: NativeRequestContext?
        if let raw = body["client_metadata"], !(raw is NSNull) {
            guard let metadata = raw as? [String: Any], let text = metadata["x-codex-turn-metadata"] as? String else { throw Failure.inferenceContextRequired }
            bodyValue = try parse(text)
        }
        if let headerValue, let bodyValue {
            guard headerValue.identity == bodyValue.identity else { throw Failure.inferenceContextRequired }
            if let headerKind = headerValue.requestKind, let bodyKind = bodyValue.requestKind,
               headerKind != bodyKind { throw Failure.inferenceContextRequired }
        }
        guard let value = headerValue ?? bodyValue else { throw Failure.inferenceContextRequired }
        let kind = headerValue?.requestKind ?? bodyValue?.requestKind
        if kind == "compaction", let tools = body["tools"], !(tools is NSNull) {
            guard let tools = tools as? [Any], tools.isEmpty else { throw Failure.invalidRequest }
        }
        return .init(identity: value.identity, requestKind: kind)
    }
    private func context(taskID: String) async throws -> Context {
        if let value = contexts[taskID] { return value }
        guard prepared[taskID] != nil, waiters[taskID] == nil else { throw Failure.inferenceContextRequired }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[taskID] = Waiter(id: id, continuation: continuation)
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    self.expireWaiter(taskID, id: id)
                }
            }
        } onCancel: { Task { await self.expireWaiter(taskID, id: id) } }
    }
    private func expireWaiter(_ task: String, id: UUID) {
        guard waiters[task]?.id == id else { return }
        waiters.removeValue(forKey: task)?.continuation.resume(throwing: Failure.inferenceContextRequired)
    }
    func shutdown() async {
        stopped = true; starting?.cancel(); listener?.cancel(); listener = nil; baseURL = nil
        let active = lanes
        prepared.removeAll(); contexts.removeAll(); correctionsUsed.removeAll(); executionCheckpoints.removeAll()
        activeUserInputs.removeAll()
        for update in userInputUpdates.values { update.timeout?.cancel() }; userInputUpdates.removeAll()
        for waiter in userInputWaiters.values { waiter.continuation.resume(throwing: Failure.stopped) }; userInputWaiters.removeAll()
        for waiter in waiters.values { waiter.continuation.resume(throwing: Failure.stopped) }; waiters.removeAll()
        for lane in active.values { lane.request.cancel() }
        for lane in active.values { _ = await lane.request.result }
        lanes.removeAll()
        let sockets = connections
        for value in sockets.values { value.task.cancel(); value.socket.cancel() }
        for value in sockets.values { await value.task.value }
        connections.removeAll()
        if let starting { _ = await starting.result }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connection.start(queue: queue)
        let task = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            await self.handle(connection)
            connection.cancel(); await self.retire(id)
        }
        connections[id] = Connection(socket: connection, task: task)
    }
    private func retire(_ id: UUID) { connections.removeValue(forKey: id) }
    private func handle(_ connection: NWConnection) async {
        // A cancelled slow header read is also interrupted at the socket boundary.
        let deadline = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { connection.cancel() } }
        var failureStage: FailureStage?
        var failureContext: FailureDiagnosticContext?
        do {
            let request = try await Self.readRequest(connection); deadline.cancel()
            guard !stopped else { throw Failure.stopped }
            guard request.headers["authorization"] == "Bearer " + bearerToken,
                  request.headers["origin"] == nil else { throw Failure.unauthorized }
            if request.method == "GET", request.path == "/v1/models" {
                let data = try JSONSerialization.data(withJSONObject: ["object": "list", "data": providers.flatMap { provider in provider.models.map { model in
                    ["id": APIProviderCatalog.appModelID(providerID: provider.id, modelID: model.id), "object": "model", "owned_by": provider.id]
                } }])
                try await Self.send(connection, status: "200 OK", type: "application/json", body: data); return
            }
            guard request.method == "POST", request.path == "/v1/responses",
                  request.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?.lowercased() == "application/json",
                  let taskText = request.headers["x-computa-task-id"], let taskID = UUID(uuidString: taskText)?.uuidString.lowercased(),
                  let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let modelID = object["model"] as? String else { throw Failure.invalidRequest }
            guard !retiring.contains(taskID), admissions[taskID] == nil, lanes[taskID] == nil else { throw Failure.busy }
            let nativeRequest = try Self.nativeIdentity(object, header: request.headers["x-codex-turn-metadata"])
            let admissionID = UUID(); admissions[taskID] = admissionID
            defer {
                if admissions[taskID] == admissionID {
                    admissions.removeValue(forKey: taskID)
                    for waiter in retirementWaiters.removeValue(forKey: taskID) ?? [] { waiter.resume() }
                }
            }
            let context = try await context(taskID: taskID)
            guard !stopped, contexts[taskID] == context, nativeRequest.identity == context.identity else { throw Failure.inferenceContextRequired }
            try await awaitUserInputUpdate(task: taskID, context: context)
            if let task = UUID(uuidString: taskID), let thread = UUID(uuidString: context.identity.threadID),
               let turn = UUID(uuidString: context.identity.turnID) {
                failureContext = .init(taskID: task, threadID: thread, turnID: turn)
            }
            guard let selection = APIProviderCatalog.selection(for: modelID, providers: providers) else { throw Failure.modelUnavailable }
            if capsules == nil { capsules = try suppliedCapsules ?? APIReasoningCapsules.persistent() }
            guard let capsules else { throw Failure.credentialUnavailable }
            try Task.checkCancellation()
            guard !stopped, !retiring.contains(taskID), contexts[taskID] == context,
                  admissions[taskID] == admissionID else { throw Failure.inferenceContextRequired }
            let proposedNaming: APIModelResponseCodec.ToolNaming = context.isNewThread && Self.hasOnlyUnmodeledInput(object) ? .semantic : .legacy
            failureStage = .prepare
            let translated: APIModelResponseCodec.Request
            if let toolNamingDirectory {
                // Synchronous ownership-checked pin publication cannot yield to
                // a later turn between validation and the durable write. The
                // store validates the request before admitting a new pin.
                translated = try APIThreadToolNamingStore(directory: toolNamingDirectory).withPinnedStyle(
                    threadID: context.identity.threadID, proposed: proposedNaming) { style in
                        try APIModelResponseCodec.prepare(request.body, selection: selection,
                            threadID: context.identity.threadID, capsules: capsules, toolNaming: style)
                    }
            } else {
                translated = try APIModelResponseCodec.prepare(request.body, selection: selection,
                    threadID: context.identity.threadID, capsules: capsules, toolNaming: .legacy)
            }
            // The pinned engine explicitly labels maintenance in native turn
            // metadata. Never guess from a summary or from prompt wording.
            let purpose: APIModelResponseCodec.HostProjectionPurpose = nativeRequest.requestKind == "compaction"
                ? .nativeCompaction : .ordinaryInference
            let userInputs: [String]
            if context.userRequest != nil {
                guard let active = activeUserInputs[taskID], active.context == context else { throw Failure.inferenceContextRequired }
                userInputs = active.inputs.map { String(decoding: $0, as: UTF8.self) }
            } else { userInputs = [] }
            let hostMessage = try executionMessage(taskID: taskID, context: context, remindsUser: !userInputs.isEmpty, purpose: purpose)
            let prepared = try hostMessage.map {
                try APIModelResponseCodec.appendingHostDeveloperMessage($0, to: translated, userInputs: userInputs, purpose: purpose)
            } ?? translated
            let userInputRevision = activeUserInputs[taskID]?.revision
            let key: String
            do { guard let value = try credentials.key(for: selection.provider.id) else { throw APIProviderHTTPClient.Failure.missingCredential }; key = value }
            catch let failure as APIProviderHTTPClient.Failure { throw failure }
            catch { throw Failure.credentialUnavailable }
            let capture = APIRejectedRequestCapture.consume(directory: rejectionDiagnosticsDirectory, taskID: UUID(uuidString: taskID)!,
                threadID: UUID(uuidString: context.identity.threadID)!, turnID: UUID(uuidString: context.identity.turnID)!,
                ordinaryInference: nativeRequest.requestKind == nil || nativeRequest.requestKind == "turn")
            // No body inspection or expected-content copy for unarmed requests.
            // Expectations come from native admission, before provider encoding.
            let projectionExpectation: APIProviderHTTPClient.RequestProjectionExpectation? = capture?.mode == .projection
                ? .init(provider: prepared.provider, modelID: prepared.model.id, hostMessage: hostMessage,
                    userInputs: userInputs, userInputRevision: userInputRevision,
                    checkpointRevision: executionCheckpoints[taskID]?.revision) : nil
            let onRejection: (@Sendable (APIProviderHTTPClient.RejectionDiagnostic) -> Void)?
            if let capture, capture.mode == .rejection { onRejection = { diagnostic in capture.capture(diagnostic) } }
            else { onRejection = nil }
            failureStage = .requestTransport
            let laneID = UUID()
            let inferenceDeadline = ContinuousClock.now.advanced(by: inferenceTimeout)
            let requestTask = Task<APIModelResponseCodec.Reply, Error> {
                try await withThrowingTaskGroup(of: APIModelResponseCodec.Reply.self) { group in
                    group.addTask { try await self.performInference(prepared, key: key, taskID: taskID,
                        context: context, userInputRevision: userInputRevision, laneID: laneID,
                        deadline: inferenceDeadline, onRejection: onRejection,
                        projectionExpectation: projectionExpectation, requestCapture: capture) }
                    group.addTask {
                        try await ContinuousClock().sleep(until: inferenceDeadline)
                        throw StagedFailure(stage: .requestTransport, cause: APIProviderHTTPClient.Failure.timeout)
                    }
                    defer { group.cancelAll() }
                    guard let reply = try await group.next() else { throw Failure.cancelled }
                    return reply
                }
            }
            let lane = Lane(id: laneID, request: requestTask); lanes[taskID] = lane
            defer { if lanes[taskID]?.id == lane.id { lanes.removeValue(forKey: taskID) } }
            let reply: APIModelResponseCodec.Reply
            do {
                reply = try await withTaskCancellationHandler { try await requestTask.value } onCancel: { requestTask.cancel() }
            } catch {
                let cause = (error as? StagedFailure)?.cause ?? error
                if let failure = cause as? APIProviderHTTPClient.Failure,
                   prepared.stream && [.rateLimited, .providerBusy].contains(failure) {
                    try Task.checkCancellation()
                    guard !stopped, contexts[taskID] == context, lanes[taskID]?.id == lane.id else { throw Failure.cancelled }
                    // The native client's HTTP-429 bridge drops the provider cause.
                    // Standard Responses failure events preserve it without replay,
                    // while non-streaming callers retain the HTTP status below.
                    failureStage = .eventSerialization
                    guard ContinuousClock.now < inferenceDeadline else { throw APIProviderHTTPClient.Failure.timeout }
                    let failed = try APIModelResponseCodec.encodeRateLimitFailure(request: prepared, failure: failure)
                    guard ContinuousClock.now < inferenceDeadline else { throw APIProviderHTTPClient.Failure.timeout }
                    try await Self.send(connection, status: "200 OK", type: "text/event-stream", body: failed)
                    return
                }
                throw error
            }
            failureStage = .eventSerialization
            try Task.checkCancellation()
            guard !stopped, contexts[taskID] == context, lanes[taskID]?.id == lane.id else { throw Failure.cancelled }
            guard ContinuousClock.now < inferenceDeadline else { throw APIProviderHTTPClient.Failure.timeout }
            let encoded = try APIModelResponseCodec.encode(reply, stream: prepared.stream)
            guard ContinuousClock.now < inferenceDeadline else { throw APIProviderHTTPClient.Failure.timeout }
            // Only finite final-message metadata, correlated by the response ID
            // already retained in native usage records. Never capture the text.
            if let diagnostic = APIModelResponseCodec.finalTextDiagnostic(reply, encoded: encoded, stream: prepared.stream),
               let data = try? JSONEncoder().encode(diagnostic), data.count <= 2_048,
               let record = String(data: data, encoding: .utf8) {
                Self.responseLog.notice("finalTextBoundary \(record, privacy: .public)")
            }
            try requireInference(taskID: taskID, context: context, laneID: lane.id, deadline: inferenceDeadline)
            try await Self.send(connection, status: "200 OK", type: prepared.stream ? "text/event-stream" : "application/json", body: encoded)
        } catch {
            deadline.cancel()
            let cause = (error as? StagedFailure)?.cause ?? error
            let stage = (error as? StagedFailure)?.stage ?? failureStage
            if let stage, let record = Self.failureDiagnostic(cause, stage: stage,
                argumentDiagnostic: (error as? StagedFailure)?.argumentDiagnostic,
                responseDiagnostic: (error as? StagedFailure)?.responseDiagnostic, context: failureContext) {
                Self.responseLog.error("failureStage \(record, privacy: .public)")
#if DEBUG
                failureDiagnosticsObserverForTesting?(record)
#endif
            }
            try? await Self.send(connection, status: Self.errorStatus(cause), type: "application/json", body: Self.errorBody(cause, stage: stage))
        }
    }
    private func requireInference(taskID: String, context: Context, laneID: UUID, deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw APIProviderHTTPClient.Failure.timeout }
        guard !stopped, !retiring.contains(taskID), contexts[taskID] == context,
              prepared[taskID]?.preparationID == context.preparationID, lanes[taskID]?.id == laneID else { throw Failure.cancelled }
    }

    private func performInference(_ original: APIModelResponseCodec.Request, key: String, taskID: String,
                                  context: Context, userInputRevision: Int?, laneID: UUID, deadline: ContinuousClock.Instant,
                                  onRejection: (@Sendable (APIProviderHTTPClient.RejectionDiagnostic) -> Void)?,
                                  projectionExpectation: APIProviderHTTPClient.RequestProjectionExpectation?,
                                  requestCapture: APIRejectedRequestCapture.Ticket?) async throws -> APIModelResponseCodec.Reply {
#if DEBUG
        try await beforeInferenceDispatchForTesting?()
#endif
        try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
        try requireUserInputSnapshot(taskID: taskID, context: context, revision: userInputRevision)
        let first: APIProviderHTTPClient.Result
        do { first = try await client.request(provider: original.provider, key: key, path: original.path,
            body: original.body, modelID: original.model.id, onRejection: onRejection,
            projectionExpectation: projectionExpectation) }
        catch { throw StagedFailure(stage: .requestTransport, cause: error) }
        func captureProjection(_ outcome: APIRejectedRequestCapture.ProjectionDecodeOutcome) {
            guard requestCapture?.mode == .projection else { return }
            // A diagnostic cannot publish for a cancelled/retired lane or an
            // obsolete user revision. This gate does not change reply handling.
            do {
                try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
                try requireUserInputSnapshot(taskID: taskID, context: context, revision: userInputRevision)
            } catch { return }
            requestCapture?.captureProjection(first.requestProjection, decodeOutcome: outcome)
        }
        let outcome: APIModelResponseCodec.DecodeOutcome
        var firstDiagnostic: APIModelResponseCodec.ArgumentValidationDiagnostic?
        var firstResponseDiagnostic: APIModelResponseCodec.InvalidResponseDiagnostic?
        do { outcome = try APIModelResponseCodec.decodeForCorrection(first, request: original,
            onArgumentRejection: { firstDiagnostic = $0 }, onInvalidResponse: { firstResponseDiagnostic = $0 }) }
        catch {
            captureProjection(.decodeFailed)
            throw StagedFailure(stage: .decode, cause: error,
                argumentDiagnostic: firstDiagnostic.map { .init(validation: $0, gate: .decoderExcluded, attempt: 1) },
                responseDiagnostic: firstResponseDiagnostic.map { .init(validation: $0, attempt: 1) })
        }
        switch outcome {
        case .reply(let reply):
            captureProjection(.responseValidated)
            return reply
        case .argumentsRejected(let firstUsage, let rejectionDetails):
            captureProjection(.argumentsRejected)
            guard let directory = correctionAccountingDirectory else {
                throw StagedFailure(stage: .decode, cause: APIModelResponseCodec.Failure.invalidArguments,
                    argumentDiagnostic: .init(validation: firstDiagnostic, gate: .accountingDisabled, attempt: 1))
            }
            let accounting = APIModelCorrectionAccounting(directory: directory)
            let ticket: APIModelCorrectionAccounting.Ticket
            let finiteFirstValidation: APIModelCorrectionAccounting.FirstValidation? = firstDiagnostic.flatMap {
                Self.finiteArgumentValidation($0) ? APIModelCorrectionAccounting.FirstValidation($0) : nil
            }
            do { ticket = try accounting.begin(taskID: taskID, threadID: context.identity.threadID,
                turnID: context.identity.turnID, firstUsage: firstUsage, firstValidation: finiteFirstValidation) }
            catch {
                Self.responseLog.error("argumentCorrection accounting_unavailable; no corrective request claimed")
                throw StagedFailure(stage: .decode, cause: APIModelResponseCodec.Failure.invalidArguments,
                    argumentDiagnostic: .init(validation: firstDiagnostic, gate: .accountingUnavailable, attempt: 1))
            }
            var secondClaimed = false, finished = false
            var secondUsage: APIModelCorrectionUsage?
            var secondStage = FailureStage.decode
            var terminal = APIModelCorrectionAccounting.Outcome.decodeFailed
            var secondDiagnostic: APIModelResponseCodec.ArgumentValidationDiagnostic?
            var secondResponseDiagnostic: APIModelResponseCodec.InvalidResponseDiagnostic?
            do {
                guard correctionsUsed[taskID] != context else {
                    terminal = .budgetExhausted; throw APIModelResponseCodec.Failure.invalidArguments
                }
                try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
                try requireUserInputSnapshot(taskID: taskID, context: context, revision: userInputRevision)
                correctionsUsed[taskID] = context // one corrective inference per native user turn
                let correction = try APIModelResponseCodec.correctiveRequest(original, rejectionDetails: rejectionDetails)
#if DEBUG
                try await beforeCorrectionDispatchForTesting?()
#endif
                try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
                try requireUserInputSnapshot(taskID: taskID, context: context, revision: userInputRevision)
                try accounting.claimed(ticket)
                secondClaimed = true
                // Claim is not network acceptance proof. There is no actor await
                // between this final identity check and starting the same native
                // HTTP client; it checks cancellation again before URLSession.
                try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
                try requireUserInputSnapshot(taskID: taskID, context: context, revision: userInputRevision)
                secondStage = .requestTransport; terminal = .transportFailed
                let second = try await client.request(provider: correction.provider, key: key, path: correction.path,
                    body: correction.body, modelID: correction.model.id, onRejection: onRejection)
                secondStage = .decode; terminal = .decodeFailed
                switch try APIModelResponseCodec.decodeForCorrection(second, request: correction,
                    onArgumentRejection: { secondDiagnostic = $0 }, onInvalidResponse: { secondResponseDiagnostic = $0 }) {
                case .argumentsRejected(let usage, _):
                    secondUsage = usage; terminal = .argumentsRejected
                    throw APIModelResponseCodec.Failure.invalidArguments
                case .reply(let reply):
                    secondUsage = APIModelResponseCodec.correctionUsage(reply.response["usage"])
                    try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
                    let corrected = try APIModelResponseCodec.withCorrectionMetadata(reply, ticket: ticket, secondUsage: secondUsage)
                    try accounting.finish(ticket, claimed: secondClaimed, usage: secondUsage, outcome: .responseValidated)
                    finished = true
                    logCorrection(ticket, outcome: .responseValidated)
                    return corrected
                }
            } catch {
                if error is CancellationError || error as? Failure == .cancelled || error as? APIProviderHTTPClient.Failure == .cancelled { terminal = .cancelled }
                if error as? APIProviderHTTPClient.Failure == .timeout || ContinuousClock.now >= deadline { terminal = .timedOut }
                if !finished {
                    let finiteSecondValidation = secondDiagnostic.flatMap {
                        Self.finiteArgumentValidation($0) ? APIModelCorrectionAccounting.FirstValidation($0) : nil
                    }
                    do { try accounting.finish(ticket, claimed: secondClaimed, usage: secondUsage, outcome: terminal,
                        secondValidation: finiteSecondValidation) }
                    catch { Self.responseLog.error("argumentCorrection terminal_accounting_unavailable; first usage remains durable") }
                }
                logCorrection(ticket, outcome: terminal)
                throw StagedFailure(stage: secondStage, cause: error, argumentDiagnostic: .init(
                    validation: secondClaimed ? secondDiagnostic : firstDiagnostic,
                    gate: terminal == .budgetExhausted ? .budgetExhausted : .correctionRejected, attempt: secondClaimed ? 2 : 1),
                    responseDiagnostic: secondResponseDiagnostic.map { .init(validation: $0, attempt: 2) })
            }
        }
    }
    /// Admission and actual provider dispatch are separated by task scheduling.
    /// A new call (including an internal correction) cannot use an input snapshot
    /// superseded by a staged or accepted steer. Already-dispatched calls may finish.
    private func requireUserInputSnapshot(taskID: String, context: Context, revision: Int?) throws {
        guard userInputUpdates[taskID] == nil, activeUserInputs[taskID]?.revision == revision,
              context.userRequest == nil || activeUserInputs[taskID]?.context == context else { throw Failure.cancelled }
    }

    private func logCorrection(_ ticket: APIModelCorrectionAccounting.Ticket, outcome: APIModelCorrectionAccounting.Outcome) {
        // Native context identifiers correlate recovery without text or tool IDs.
        let record: [String: Any] = ["kind": "api_argument_correction_v1", "correction_id": ticket.id.uuidString.lowercased(),
            "task_id": ticket.taskID, "thread_id": ticket.threadID, "turn_id": ticket.turnID,
            "outcome": outcome.rawValue, "normal_usage": "accepted_response_only", "clean_completion": false]
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys), bytes.count <= 512,
              let text = String(data: bytes, encoding: .utf8) else { return }
        Self.responseLog.notice("argumentCorrection \(text, privacy: .public)")
    }

    /// This is a conservative migration check, never freshness authority. Only
    /// Core's actual thread/start flag can opt a missing pin into semantic names.
    /// Unknown item types or model-generated history keep the legacy mapping.
    private static func hasOnlyUnmodeledInput(_ object: [String: Any]) -> Bool {
        if object["input"] is String { return true }
        guard let input = object["input"] as? [[String: Any]], !input.isEmpty else { return false }
        return input.allSatisfy { item in
            guard item["type"] == nil || item["type"] as? String == "message",
                  let role = item["role"] as? String else { return false }
            return ["system", "developer", "user"].contains(role)
        }
    }
    static func errorStatus(_ error: any Error) -> String {
        if error as? Failure == .unauthorized || error as? APIProviderHTTPClient.Failure == .unauthorized || error as? APIProviderHTTPClient.Failure == .missingCredential { return "401 Unauthorized" }
        if let failure = error as? APIProviderHTTPClient.Failure, [.rateLimited, .providerBusy].contains(failure) { return "429 Too Many Requests" }
        if error as? Failure == .modelUnavailable || error as? APIProviderHTTPClient.Failure == .modelNotFound { return "404 Not Found" }
        return "400 Bad Request"
    }
    private static func finiteCode(_ value: String) -> String {
        switch value {
        case "missingCredential", "unauthorized", "credentialUnavailable": return "auth_required"
        case "rateLimited": return "rate_limit"
        case "modelNotFound", "modelUnavailable": return "model_not_found"
        case "contextLimit": return "context_limit"
        case "incompleteResponse": return "truncated"
        default: return value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
        }
    }
    static func errorBody(_ error: any Error, stage: FailureStage? = nil) throws -> Data {
        let code: String, message: String
        if let value = error as? Failure { code = finiteCode(value.rawValue); message = value.localizedDescription }
        else if let value = error as? APIModelResponseCodec.Failure { code = finiteCode(value.rawValue); message = value.localizedDescription }
        else if let value = error as? APIProviderHTTPClient.Failure { code = finiteCode(value.rawValue); message = value.localizedDescription }
        else if error is CancellationError { code = Failure.cancelled.rawValue; message = Failure.cancelled.localizedDescription }
        else { code = APIProviderHTTPClient.Failure.unavailable.rawValue; message = APIProviderHTTPClient.Failure.unavailable.localizedDescription }
        let scopedMessage: String
        if error as? APIModelResponseCodec.Failure == .invalidArguments, stage == .prepare {
            scopedMessage = "The retained tool history in this API request contains invalid arguments. This inference sent no provider request and executed no new tool."
        } else if error as? APIModelResponseCodec.Failure == .invalidArguments, stage == .decode {
            scopedMessage = "The provider response contained invalid tool arguments. No tool from this response was executed."
        } else { scopedMessage = message }
        return try JSONSerialization.data(withJSONObject: ["error": ["type": "api_model_error", "code": code, "message": scopedMessage, "x-computa-retryable": false]])
    }
    static func failureDiagnostic(_ error: any Error, stage: FailureStage,
                                  argumentDiagnostic: ArgumentFailureDiagnostic? = nil,
                                  responseDiagnostic: ResponseFailureDiagnostic? = nil,
                                  context: FailureDiagnosticContext? = nil) -> String? {
        guard let body = try? errorBody(error, stage: stage),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let envelope = object["error"] as? [String: Any], let code = envelope["code"] as? String else { return nil }
        var record: [String: Any] = ["kind": "api_failure_stage_v1", "stage": stage.rawValue, "code": code, "retryable": false]
        // Only this typed projection can enrich argument decode failures. Generic
        // prepare/transport failures and the public error schema remain unchanged.
        if stage == .decode, error as? APIModelResponseCodec.Failure == .invalidArguments, let argumentDiagnostic,
           (1...2).contains(argumentDiagnostic.attempt),
           argumentDiagnostic.validation.map(finiteArgumentValidation) ?? true,
           let bytes = try? JSONEncoder().encode(argumentDiagnostic),
           let finite = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            record["argument_validation"] = finite
            if let context, let bytes = try? JSONEncoder().encode(context),
               let ids = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { record["native_context"] = ids }
        }
        // A separate closed enum labels only the fatal invalid-response guard.
        // Never copy raw content or infer a cause from an absent observation.
        if stage == .decode, error as? APIModelResponseCodec.Failure == .invalidResponse,
           let responseDiagnostic, (1...2).contains(responseDiagnostic.attempt),
           responseDiagnostic.validation.isConsistent,
           let bytes = try? JSONEncoder().encode(responseDiagnostic),
           let finite = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            record["response_validation"] = finite
            if let context, let bytes = try? JSONEncoder().encode(context),
               let ids = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { record["native_context"] = ids }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys),
              data.count <= (record["argument_validation"] == nil && record["response_validation"] == nil ? 256 : 1_024) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    /// Shared by terminal failure logs and durable recovered-response metadata.
    /// Values and arbitrary paths are absent; optional builtin paths use closed
    /// enums checked against the admitted schema. Malformed observations cannot
    /// affect admission, correction eligibility, or the request budget.
    private static func finiteArgumentValidation(_ value: APIModelResponseCodec.ArgumentValidationDiagnostic) -> Bool {
        (0...128).contains(value.callCount) && (1...128).contains(value.rejectedCount)
            && value.rejectedCount <= value.callCount && (value.schemaFailures?.count ?? 0) <= 2
            && (value.schemaFailures?.allSatisfy { (0..<128).contains($0.toolIndex) && ($0.location?.isConsistent ?? true) } ?? true)
    }
    struct HTTPRequest: Sendable { let method: String; let path: String; let headers: [String: String]; let body: Data }
    static func parseRequest(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 2_097_152 else { throw Failure.invalidRequest }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw Failure.invalidRequest }; return nil
        }
        guard separator.lowerBound <= 16_384, let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw Failure.invalidRequest }
        let lines = head.components(separatedBy: "\r\n"), start = lines[0].components(separatedBy: " ")
        guard start.count == 3, start[2] == "HTTP/1.1", ["GET", "POST"].contains(start[0]) else { throw Failure.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.invalidRequest }
            let name = String(line[..<colon]).lowercased(), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[name] == nil,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidRequest }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? (start[0] == "GET" ? "0" : "")), (0...2_000_000).contains(length),
              start[0] != "POST" || length > 0, start[0] != "GET" || length == 0 else { throw Failure.invalidRequest }
        let available = data.count - separator.upperBound
        if available < length { return nil }
        guard available == length else { throw Failure.invalidRequest }
        return HTTPRequest(method: start[0], path: start[1], headers: headers, body: Data(data[separator.upperBound...]))
    }
    private static func readRequest(_ connection: NWConnection) async throws -> HTTPRequest {
        var data = Data()
        while true {
            let next: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                    if error != nil { continuation.resume(throwing: Failure.invalidRequest) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: Failure.invalidRequest) }
                }
            }
            data.append(next); if let request = try parseRequest(data) { return request }
        }
    }
    private static func send(_ connection: NWConnection, status: String, type: String, body: Data) async throws {
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8); data.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: Failure.cancelled) } else { continuation.resume() }
            })
        }
    }
}

/// Immutable per-native-thread protocol metadata. No input, output, reasoning,
/// endpoint, model, credential or tool arguments are stored here.
private struct APIThreadToolNamingStore {
    private static let maximumBytes = 512
    let directory: URL

    func withPinnedStyle<T>(threadID: String, proposed: APIModelResponseCodec.ToolNaming,
                            validate: (APIModelResponseCodec.ToolNaming) throws -> T) throws -> T {
        guard let id = UUID(uuidString: threadID), id.uuidString.lowercased() == threadID else {
            throw APIModelServer.Failure.toolNamingUnavailable
        }
        try Task.checkCancellation()
        let handles = try openDirectory()
        defer { close(handles.directory); close(handles.parent) }
        guard flock(handles.directory, LOCK_EX | LOCK_NB) == 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
        defer { _ = flock(handles.directory, LOCK_UN) }
        let filename = threadID + ".json"
        try requireDirectory(handles)
        if let existing = try load(filename, threadID: threadID, handles: handles) {
            return try validate(existing)
        }
        // Invalid request/history cannot create a naming pin. Validation is
        // completed against the candidate style before the atomic publication.
        let result = try validate(proposed)
        try Task.checkCancellation()
        try requireDirectory(handles)
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "threadID": threadID,
            "style": proposed.rawValue], options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= Self.maximumBytes else { throw APIModelServer.Failure.toolNamingUnavailable }
        try publish(bytes, named: filename, handles: handles)
        guard try load(filename, threadID: threadID, handles: handles) == proposed else {
            throw APIModelServer.Failure.toolNamingUnavailable
        }
        return result
    }

    private struct Handles {
        let parent: Int32, directory: Int32
        let name: String
        let identity: stat
    }

    private func openDirectory() throws -> Handles {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw APIModelServer.Failure.toolNamingUnavailable }
        let components = directory.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw APIModelServer.Failure.toolNamingUnavailable
        }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
        do {
            // Resolve each ancestor through an owned descriptor. An ancestor
            // symlink cannot redirect this store into an unrelated location.
            for component in components.dropLast() {
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
                close(parent); parent = next
            }
            let name = components.last!
            var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT {
                try Task.checkCancellation()
                if mkdirat(parent, name, 0o700) == 0 {
                    guard fsync(parent) == 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
                } else if errno != EEXIST { throw APIModelServer.Failure.toolNamingUnavailable }
                descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o700 else {
                close(descriptor); throw APIModelServer.Failure.toolNamingUnavailable
            }
            let result = Handles(parent: parent, directory: descriptor, name: name, identity: metadata)
            do { try requireDirectory(result) }
            catch { close(descriptor); throw error }
            return result
        } catch { close(parent); throw error }
    }

    private func requireDirectory(_ handles: Handles) throws {
        var held = stat(), named = stat()
        guard fstat(handles.directory, &held) == 0,
              fstatat(handles.parent, handles.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameInode(held, handles.identity), sameInode(held, named),
              held.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              held.st_uid == geteuid(), held.st_mode & 0o777 == 0o700 else {
            throw APIModelServer.Failure.toolNamingUnavailable
        }
    }

    private func load(_ name: String, threadID: String, handles: Handles) throws -> APIModelResponseCodec.ToolNaming? {
        try requireDirectory(handles)
        let descriptor = openat(handles.directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw APIModelServer.Failure.toolNamingUnavailable
        }
        defer { close(descriptor) }
        var before = stat(), named = stat()
        guard fstat(descriptor, &before) == 0,
              fstatat(handles.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameInode(before, named), privateFile(before),
              before.st_size > 0, before.st_size <= Self.maximumBytes else { throw APIModelServer.Failure.toolNamingUnavailable }
        var bytes = Data(count: Self.maximumBytes + 1)
        let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw APIModelServer.Failure.toolNamingUnavailable }
                if count == 0 { return offset }
                offset += count
            }
            return offset
        }
        var after = stat(), current = stat()
        guard count == before.st_size, count <= Self.maximumBytes,
              fstat(descriptor, &after) == 0,
              fstatat(handles.directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              unchangedFile(before, after), unchangedFile(after, current), privateFile(after) else {
            throw APIModelServer.Failure.toolNamingUnavailable
        }
        bytes.count = count
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["version", "threadID", "style"],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1,
              object["threadID"] as? String == threadID,
              let raw = object["style"] as? String,
              let style = APIModelResponseCodec.ToolNaming(rawValue: raw) else {
            throw APIModelServer.Failure.toolNamingUnavailable
        }
        try requireDirectory(handles)
        return style
    }

    private func publish(_ bytes: Data, named name: String, handles: Handles) throws {
        let temporary = ".tool-naming-" + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(handles.directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
        defer { close(descriptor); _ = unlinkat(handles.directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw APIModelServer.Failure.toolNamingUnavailable }
                guard count > 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
                offset += count
            }
        }
        guard fchmod(descriptor, 0o400) == 0, fsync(descriptor) == 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
        try Task.checkCancellation()
        try requireDirectory(handles)
        // Publication is exclusive across processes. An existing pin is never
        // rewritten; even a contradictory racing writer cannot change its style.
        guard renameatx_np(handles.directory, temporary, handles.directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw APIModelServer.Failure.toolNamingUnavailable
        }
        guard fsync(handles.directory) == 0 else { throw APIModelServer.Failure.toolNamingUnavailable }
        try requireDirectory(handles)
    }

    private func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1
            && value.st_uid == geteuid() && value.st_mode & 0o777 == 0o400
    }
    private func sameInode(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }
    private func unchangedFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameInode(lhs, rhs) && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

private final class APIListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume(with: result)
    }
}

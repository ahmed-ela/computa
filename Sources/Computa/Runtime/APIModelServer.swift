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
    }
#if DEBUG
    private var failureDiagnosticsObserverForTesting: (@Sendable (String) -> Void)?
    private var beforeCorrectionDispatchForTesting: (@Sendable () async throws -> Void)?
    func setBeforeCorrectionDispatchForTesting(_ hook: (@Sendable () async throws -> Void)?) { beforeCorrectionDispatchForTesting = hook }
    func setFailureDiagnosticsObserverForTesting(_ observer: (@Sendable (String) -> Void)?) {
        failureDiagnosticsObserverForTesting = observer
    }
#endif
    private struct Connection { let socket: NWConnection; let task: Task<Void, Never> }
    private var connections: [UUID: Connection] = [:]
    private struct Lane { let id: UUID; let request: Task<APIModelResponseCodec.Reply, Error> }
    private var lanes: [String: Lane] = [:]
    private struct Prepared: Equatable { let threadID: String; let preparationID: UUID; let isNewThread: Bool }
    private struct Identity: Equatable, Sendable { let threadID: String; let turnID: String }
    private struct Context: Equatable, Sendable { let identity: Identity; let preparationID: UUID; let isNewThread: Bool }
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Context, Error> }
    private var prepared: [String: Prepared] = [:]
    private var contexts: [String: Context] = [:]
    private var waiters: [String: Waiter] = [:]
    private var admissions: [String: UUID] = [:]
    private var retiring = Set<String>()
    private var retirementWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(credentials: any APIProviderCredentials = APIProviderCredentialStore(),
         client: APIProviderHTTPClient = APIProviderHTTPClient(), capsules: APIReasoningCapsules? = nil,
         rejectionDiagnosticsDirectory: URL? = nil, toolNamingDirectory: URL? = nil,
         correctionAccountingDirectory: URL? = nil, inferenceTimeout: Duration = .seconds(300)) {
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
    func prepareInferenceTurn(taskID: String, threadID: String, preparationID: UUID, isNewThread: Bool = false) throws {
        let task = try Self.canonicalID(taskID), thread = try Self.canonicalID(threadID)
        guard !stopped, !retiring.contains(task), lanes[task] == nil, admissions[task] == nil else { throw Failure.busy }
        let value = Prepared(threadID: thread, preparationID: preparationID, isNewThread: isNewThread)
        if prepared[task] == value { return }
        guard prepared[task] == nil, contexts[task] == nil else { throw Failure.inferenceContextRequired }
        prepared[task] = value
    }
    func registerInferenceTurn(taskID: String, threadID: String, turnID: String, preparationID: UUID) throws {
        let task = try Self.canonicalID(taskID)
        let identity = Identity(threadID: try Self.canonicalID(threadID), turnID: try Self.canonicalID(turnID))
        guard let preparation = prepared[task], preparation.threadID == identity.threadID,
              preparation.preparationID == preparationID else { throw Failure.inferenceContextRequired }
        let value = Context(identity: identity, preparationID: preparationID, isNewThread: preparation.isNewThread)
        if contexts[task] == value { return }
        guard !stopped, !retiring.contains(task), contexts[task] == nil,
              prepared[task] == preparation else { throw Failure.inferenceContextRequired }
        contexts[task] = value
        waiters.removeValue(forKey: task)?.continuation.resume(returning: value)
    }
    func finish(taskID: String) async { await cancel(taskID: taskID) }
    func cancel(taskID: String) async {
        guard let task = try? Self.canonicalID(taskID) else { return }
        retiring.insert(task)
        prepared.removeValue(forKey: task); contexts.removeValue(forKey: task); correctionsUsed.removeValue(forKey: task)
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
    private static func nativeIdentity(_ body: [String: Any], header: String?) throws -> Identity {
        func parse(_ value: String) throws -> Identity {
            guard value.utf8.count <= 16_384,
                  let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                  let thread = object["thread_id"] as? String, let turn = object["turn_id"] as? String else { throw Failure.inferenceContextRequired }
            return try Identity(threadID: canonicalID(thread), turnID: canonicalID(turn))
        }
        let headerValue = try header.map(parse)
        var bodyValue: Identity?
        if let raw = body["client_metadata"], !(raw is NSNull) {
            guard let metadata = raw as? [String: Any], let text = metadata["x-codex-turn-metadata"] as? String else { throw Failure.inferenceContextRequired }
            bodyValue = try parse(text)
        }
        if let headerValue, let bodyValue, headerValue != bodyValue { throw Failure.inferenceContextRequired }
        guard let value = headerValue ?? bodyValue else { throw Failure.inferenceContextRequired }
        return value
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
        prepared.removeAll(); contexts.removeAll(); correctionsUsed.removeAll()
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
            let identity = try Self.nativeIdentity(object, header: request.headers["x-codex-turn-metadata"])
            let admissionID = UUID(); admissions[taskID] = admissionID
            defer {
                if admissions[taskID] == admissionID {
                    admissions.removeValue(forKey: taskID)
                    for waiter in retirementWaiters.removeValue(forKey: taskID) ?? [] { waiter.resume() }
                }
            }
            let context = try await context(taskID: taskID)
            guard !stopped, contexts[taskID] == context, identity == context.identity else { throw Failure.inferenceContextRequired }
            guard let selection = APIProviderCatalog.selection(for: modelID, providers: providers) else { throw Failure.modelUnavailable }
            if capsules == nil { capsules = try suppliedCapsules ?? APIReasoningCapsules.persistent() }
            guard let capsules else { throw Failure.credentialUnavailable }
            try Task.checkCancellation()
            guard !stopped, !retiring.contains(taskID), contexts[taskID] == context,
                  admissions[taskID] == admissionID else { throw Failure.inferenceContextRequired }
            let proposedNaming: APIModelResponseCodec.ToolNaming = context.isNewThread && Self.hasOnlyUnmodeledInput(object) ? .semantic : .legacy
            failureStage = .prepare
            let prepared: APIModelResponseCodec.Request
            if let toolNamingDirectory {
                // Synchronous ownership-checked pin publication cannot yield to
                // a later turn between validation and the durable write. The
                // store validates the request before admitting a new pin.
                prepared = try APIThreadToolNamingStore(directory: toolNamingDirectory).withPinnedStyle(
                    threadID: context.identity.threadID, proposed: proposedNaming) { style in
                        try APIModelResponseCodec.prepare(request.body, selection: selection,
                            threadID: context.identity.threadID, capsules: capsules, toolNaming: style)
                    }
            } else {
                prepared = try APIModelResponseCodec.prepare(request.body, selection: selection,
                    threadID: context.identity.threadID, capsules: capsules, toolNaming: .legacy)
            }
            let key: String
            do { guard let value = try credentials.key(for: selection.provider.id) else { throw APIProviderHTTPClient.Failure.missingCredential }; key = value }
            catch let failure as APIProviderHTTPClient.Failure { throw failure }
            catch { throw Failure.credentialUnavailable }
            let capture = APIRejectedRequestCapture.consume(directory: rejectionDiagnosticsDirectory, taskID: UUID(uuidString: taskID)!,
                threadID: UUID(uuidString: context.identity.threadID)!, turnID: UUID(uuidString: context.identity.turnID)!)
            let onRejection: (@Sendable (APIProviderHTTPClient.RejectionDiagnostic) -> Void)?
            if let capture { onRejection = { diagnostic in capture.capture(diagnostic) } }
            else { onRejection = nil }
            failureStage = .requestTransport
            let laneID = UUID()
            let inferenceDeadline = ContinuousClock.now.advanced(by: inferenceTimeout)
            let requestTask = Task<APIModelResponseCodec.Reply, Error> {
                try await withThrowingTaskGroup(of: APIModelResponseCodec.Reply.self) { group in
                    group.addTask { try await self.performInference(prepared, key: key, taskID: taskID,
                        context: context, laneID: laneID, deadline: inferenceDeadline, onRejection: onRejection) }
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
            if let stage, let record = Self.failureDiagnostic(cause, stage: stage) {
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
                                  context: Context, laneID: UUID, deadline: ContinuousClock.Instant,
                                  onRejection: (@Sendable (APIProviderHTTPClient.RejectionDiagnostic) -> Void)?) async throws -> APIModelResponseCodec.Reply {
        try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
        let first: APIProviderHTTPClient.Result
        do { first = try await client.request(provider: original.provider, key: key, path: original.path,
            body: original.body, modelID: original.model.id, onRejection: onRejection) }
        catch { throw StagedFailure(stage: .requestTransport, cause: error) }
        let outcome: APIModelResponseCodec.DecodeOutcome
        do { outcome = try APIModelResponseCodec.decodeForCorrection(first, request: original) }
        catch { throw StagedFailure(stage: .decode, cause: error) }
        switch outcome {
        case .reply(let reply): return reply
        case .argumentsRejected(let firstUsage):
            guard let directory = correctionAccountingDirectory else {
                throw StagedFailure(stage: .decode, cause: APIModelResponseCodec.Failure.invalidArguments)
            }
            let accounting = APIModelCorrectionAccounting(directory: directory)
            let ticket: APIModelCorrectionAccounting.Ticket
            do { ticket = try accounting.begin(taskID: taskID, threadID: context.identity.threadID,
                turnID: context.identity.turnID, firstUsage: firstUsage) }
            catch {
                Self.responseLog.error("argumentCorrection accounting_unavailable; no corrective request claimed")
                throw StagedFailure(stage: .decode, cause: APIModelResponseCodec.Failure.invalidArguments)
            }
            var secondClaimed = false, finished = false
            var secondUsage: APIModelCorrectionUsage?
            var secondStage = FailureStage.decode
            var terminal = APIModelCorrectionAccounting.Outcome.decodeFailed
            do {
                guard correctionsUsed[taskID] != context else {
                    terminal = .budgetExhausted; throw APIModelResponseCodec.Failure.invalidArguments
                }
                try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
                correctionsUsed[taskID] = context // one corrective inference per native user turn
                let correction = try APIModelResponseCodec.correctiveRequest(original)
#if DEBUG
                try await beforeCorrectionDispatchForTesting?()
#endif
                try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
                try accounting.claimed(ticket)
                secondClaimed = true
                // Claim is not network acceptance proof. There is no actor await
                // between this final identity check and starting the same native
                // HTTP client; it checks cancellation again before URLSession.
                try requireInference(taskID: taskID, context: context, laneID: laneID, deadline: deadline)
                secondStage = .requestTransport; terminal = .transportFailed
                let second = try await client.request(provider: correction.provider, key: key, path: correction.path,
                    body: correction.body, modelID: correction.model.id, onRejection: onRejection)
                secondStage = .decode; terminal = .decodeFailed
                switch try APIModelResponseCodec.decodeForCorrection(second, request: correction) {
                case .argumentsRejected(let usage):
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
                    do { try accounting.finish(ticket, claimed: secondClaimed, usage: secondUsage, outcome: terminal) }
                    catch { Self.responseLog.error("argumentCorrection terminal_accounting_unavailable; first usage remains durable") }
                }
                logCorrection(ticket, outcome: terminal)
                throw StagedFailure(stage: secondStage, cause: error)
            }
        }
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
    static func failureDiagnostic(_ error: any Error, stage: FailureStage) -> String? {
        guard let body = try? errorBody(error, stage: stage),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let envelope = object["error"] as? [String: Any], let code = envelope["code"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: ["kind": "api_failure_stage_v1",
                  "stage": stage.rawValue, "code": code, "retryable": false], options: .sortedKeys), data.count <= 256 else { return nil }
        return String(decoding: data, as: UTF8.self)
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

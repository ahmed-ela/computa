import Foundation
import CryptoKit
import Darwin
import OSLog
@preconcurrency import Network

/// Inference transport is separate from the agent loop and transcript store.
/// Another website transport can replace the browser implementation without
/// changing the desktop tools or local transcript.
protocol WebModelTransport: Sendable {
    func startWithRequestMetadata(params: Data, authorization: ChatGPTRequestMetadataLease) async throws -> Data
    func activateRequestMetadata(sessionToken: String) async -> Bool
    func snapshotRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot?
    func stopRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot?
    func revokeRequestMetadata(sessionToken: String) async
    func grantInspectorDiagnostic(_ authorization: ChatGPTInspectorLease, sessionToken: String) async -> Bool
    func revokeInspectorDiagnostic(sessionToken: String) async
    func request(operation: String, params: Data) async throws -> Data
    func request(operation: String, params: Data,
                 onChatSubmissionFailure: (@Sendable (ChatSubmissionFailureDiagnostic) -> Void)?) async throws -> Data
    func changeRevision(sessionToken: String) async throws -> UInt64?
    func waitForChange(sessionToken: String, after revision: UInt64,
                       until deadline: ContinuousClock.Instant) async throws -> UInt64?
    func interruptPostBlockObservation(sessionToken: String) async
}

/// Stopping inference and disposing its session remain cancellation operations.
/// Only an ordinary failed turn may retain an already-enrolled passive probe.
enum WebModelCleanupCause: String, Sendable {
    case failedTurn = "failed_turn"
    case cancelled
}

extension WebModelTransport {
    func startWithRequestMetadata(params: Data, authorization: ChatGPTRequestMetadataLease) async throws -> Data {
        authorization.revoke()
        return try await request(operation: "webProviderStart", params: params)
    }
    func activateRequestMetadata(sessionToken: String) async -> Bool { false }
    func snapshotRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot? { nil }
    func stopRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot? { nil }
    func revokeRequestMetadata(sessionToken: String) async {}
    func request(operation: String, params: Data,
                 onChatSubmissionFailure: (@Sendable (ChatSubmissionFailureDiagnostic) -> Void)?) async throws -> Data {
        try await request(operation: operation, params: params)
    }
    func grantInspectorDiagnostic(_ authorization: ChatGPTInspectorLease, sessionToken: String) async -> Bool { false }
    func revokeInspectorDiagnostic(sessionToken: String) async {}
    func changeRevision(sessionToken: String) async throws -> UInt64? { nil }
    func waitForChange(sessionToken: String, after revision: UInt64,
                       until deadline: ContinuousClock.Instant) async throws -> UInt64? { nil }
    func interruptPostBlockObservation(sessionToken: String) async {}
}

/// An authenticated, loopback-only Responses endpoint consumed by our owned
/// App Server. The App Server keeps its normal tools, approvals and local SQLite/
/// rollout persistence; only model inference goes through the website.
actor WebModelServer {
    private static let promptLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "WebsitePrompt")
    enum Failure: LocalizedError {
        case embeddedRequired, invalidRequest, busy, providerFailed, preparationDeadline, deadline, cleanupFailed
        case modelUnverified, modelMismatch, productModeUnverified
        case modelNotFound, inferenceContextRequired, persistenceRequired, startOwnershipUnconfirmed, turnLimit, requestMetadataUnavailable
        case malformedReply(WebModelResponseCodec.MalformedEnvelopeDiagnostic)
        var errorDescription: String? {
            switch self {
            case .embeddedRequired: "Open the selected website in Computa's built-in browser and sign in before using this model."
            case .invalidRequest: "The browser model request could not be validated."
            case .turnLimit: "The bounded website conversation limit was reached. No prompt was replayed; start a new task."
            case .busy: "This browser model already has a request running."
            case .providerFailed: "The website could not produce a response. Check its sign-in, usage limit, or error message in the browser."
            case .preparationDeadline: "The website did not become ready before the 45-second preparation deadline. This website inference was not submitted."
            case .deadline: "The website did not finish its response before the five-minute deadline."
            case .cleanupFailed: "The web conversation cleanup could not be verified. Its local transcript has been retained."
            case .productModeUnverified: "ChatGPT normal Chat mode could not be verified. No response was accepted and no prompt was replayed. Refresh website models before retrying."
            case .modelUnverified: "The website's selected model could not be verified. No response was accepted and no prompt was replayed."
            case .modelMismatch: "The website selected or reported a different model. No response was accepted and no prompt was replayed."
            case .modelNotFound: "The requested website model is not supported. Choose a model from Computa's selector."
            case .inferenceContextRequired: "The website inference could not be linked to its active local turn. No model response or tool calls were released."
            case .persistenceRequired: "The website inference evidence could not be saved locally. No model response or tool calls were released."
            case .startOwnershipUnconfirmed: "Website startup did not return a verifiable owned session. Cleanup remains unconfirmed and this task is paused."
            case .requestMetadataUnavailable: "The explicitly armed decoded metadata diagnostic could not activate. This website inference was not submitted and no prompt was replayed."
            case let .malformedReply(diagnostic):
                "The website returned a malformed model response envelope (\(diagnostic.reason.rawValue)). No tool calls from this reply were dispatched."
            }
        }
    }

    // Native-turn bounds survive physical website-page replacement. Every
    // inference still receives the complete canonical local request.
    static let maximumTurnInferences = 16
    static let maximumTurnPromptUTF8Bytes = 1_048_576
    private static func requiresNativeContinuationProof(provider: String) -> Bool {
        provider == "gemini" || provider == "chatgpt"
    }

    private struct Session: Sendable {
        let token: String
        let provider: String
        let modelID: String
        let modelChoice: WebsiteModelChoice?
        let transport: any WebModelTransport
        var inferenceID: UUID
        let context: InferenceContext
        let transportGeneration: UUID
        let provesNativeContinuation: Bool
        let retainsConversation: Bool
        var requestMetadata: ChatGPTRequestMetadataLease?
        var submittedPromptFingerprint = ""
        var cumulativePromptUTF8Count = 0
        var turnInferenceCount = 0
        var usesBoundedTurn: Bool { provesNativeContinuation && provider == "chatgpt" }
        var sequence = 1
        var baselineResponseCount = 0
        var documentGeneration: UUID?
        var firstUserFingerprint: String?
        var resolvedModel: WebsiteModelEvidence?
        var completedResponseCount: Int?
        var completedText: String?
        var completedSnapshot: Data?
    }

    private struct YieldedTurn: Sendable {
        let inferenceID: UUID
        let continuation: WebsiteTurnContinuation
    }

    private struct ClosedTurn: Sendable {
        let inferenceID: UUID
        let context: InferenceContext
        let continuation: WebsiteTurnContinuation
        let transportGeneration: UUID
        let resolvedModel: WebsiteModelEvidence?
        let turnInferenceCount: Int
        let cumulativePromptUTF8Count: Int
        var ambiguousHandoff = false
    }

    private struct InferenceResult: Sendable {
        let data: Data
        let inferenceID: UUID
        let responseProfile: WebsiteResponseProfile?
    }

    private struct InferenceContext: Equatable, Sendable {
        let threadID: String
        let turnID: String
        let runtimeGeneration: UUID
        let preparationID: UUID
        let isMaintenance: Bool
        // Diagnostic provenance only; never page/tool or inference authority.
        let isNewThread: Bool
    }

    private struct PreparedInferenceContext: Equatable, Sendable {
        let threadID: String
        let runtimeGeneration: UUID
        let preparationID: UUID
        let isMaintenance: Bool
        // Diagnostic provenance only; never page/tool or inference authority.
        let isNewThread: Bool
    }

    private struct ContextWaiter {
        let id: UUID
        let continuation: CheckedContinuation<InferenceContext, Error>
    }

    private struct NativeRequestIdentity: Equatable, Sendable {
        let threadID: String
        let turnID: String
    }

    /// Physical closure is irreversible. A failed durable write must retry
    /// this receipt, never Finish against a token the transport has removed.
    private struct PendingClosedTransaction: Sendable {
        let session: Session
        let receipt: WebsiteSessionCleanupReceipt
    }

    private struct UnresolvedStartAttempt: Sendable {
        let inferenceID: UUID
        let context: InferenceContext
        let provider: String
        let modelID: String
    }

    private struct ActiveRequest: Sendable {
        let id: UUID
        let operation: Task<InferenceResult, Error>
    }

    nonisolated let bearerToken = UUID().uuidString + UUID().uuidString
    /// The native HTTP client can replace a provider's JSON error with generic
    /// status prose. Keep the exact bounded local diagnostic until Core's
    /// correlated terminal notification consumes it, without changing HTTP.
    private nonisolated let failureDiagnostics = WebModelFailureDiagnosticStore()

    nonisolated func takeFailureDiagnostic(taskID: String) -> String? {
        failureDiagnostics.take(taskID: taskID).map { String(decoding: $0, as: UTF8.self) }
    }
    private var listener: NWListener?
    private var baseURL: URL?
    private var starting: Task<URL, Error>?
    private var embeddedTransport: (any WebModelTransport)?
    private var embeddedTransportGeneration = UUID()
    private var embeddedTransportIdentity: AnyObject?
    private var browserToolAvailabilityProvider: EmbeddedBrowserToolAvailabilityProvider?
    private var browserToolAvailabilityProviderRevision = UUID()
    private var yieldedTurns: [String: YieldedTurn] = [:]
    private var closedTurns: [String: ClosedTurn] = [:]
    // A claimed Send whose output failed was never handed off. Saving its
    // cleanup later cannot manufacture continuation authority or replay Send.
    private var failedClosedHandoffs = Set<String>()
    private var sessions: [String: Session] = [:]
    private var pendingClosedTransactions: [String: PendingClosedTransaction] = [:]
    private var lastClosedTransactions: [String: WebsiteSessionCleanupReceipt] = [:]
    private var preparedInferenceContexts: [String: PreparedInferenceContext] = [:]
    private var inferenceContexts: [String: InferenceContext] = [:]
    private var contextWaiters: [String: ContextWaiter] = [:]
    private var usedSessionTokens: [String: Set<String>] = [:]
    private var unresolvedStartAttempts: [String: UnresolvedStartAttempt] = [:]
    private var unresolvedStartReceipts: [String: WebsiteSessionCleanupReceipt] = [:]
    private var evidenceThreads: [String: String] = [:]
    private var active: [String: ActiveRequest] = [:]
    private var retiringTaskIDs = Set<String>()
    private struct CleanupResult: Sendable {
        let receipt: WebsiteSessionCleanupReceipt
        let issues: [String]
    }
    private var cleanupTasks: [String: Task<CleanupResult, Never>] = [:]
    private var cleanupTurns: [String: String] = [:]
    private var cleanupReceiptStore: WebsiteSessionCleanupStore?
    private var cleanupRuntimeGeneration = UUID()
    private var cleanupReceiptObserver: (@Sendable (WebsiteSessionCleanupReceipt) async -> Void)?
    private var connections: [UUID: NWConnection] = [:]
    private var shuttingDown = false
    private var readinessTimeout: Duration = .seconds(45)
    private var responseTimeout: Duration = .seconds(300)
    private var evidenceDirectory: URL?
    private let rejectedReplyDirectory: URL?
    private var inspectorAuthorizations: [String: ChatGPTInspectorLease] = [:]
    private let queue = DispatchQueue(label: "wtf.computa.web-model-http")

    func setBrowserToolAvailabilityProvider(_ provider: EmbeddedBrowserToolAvailabilityProvider?) {
        browserToolAvailabilityProvider = provider
        browserToolAvailabilityProviderRevision = UUID()
    }

    func configureCleanupReceipts(directory: URL, runtimeGeneration: UUID,
                                  observer: @escaping @Sendable (WebsiteSessionCleanupReceipt) async -> Void) {
        cleanupReceiptStore = WebsiteSessionCleanupStore(directory: directory)
        if runtimeGeneration != cleanupRuntimeGeneration { revokeAllInspectorAuthorizations() }
        cleanupRuntimeGeneration = runtimeGeneration
        cleanupReceiptObserver = observer
    }

    func setCleanupRuntimeGeneration(_ generation: UUID) {
        if generation != cleanupRuntimeGeneration { revokeAllInspectorAuthorizations() }
        cleanupRuntimeGeneration = generation
    }

    /// Core calls this before turn/start, removing any preceding turn's
    /// identity before the native engine can open its first HTTP inference.
    func prepareInferenceTurn(taskID: String, threadID: String, runtimeGeneration: UUID, preparationID: UUID,
                              isMaintenance: Bool = false, isNewThread: Bool = false) throws {
        let task = try Self.canonicalID(taskID)
        let thread = try Self.canonicalID(threadID)
        guard !shuttingDown, active[task] == nil, cleanupTasks[task] == nil,
              !retiringTaskIDs.contains(task) else { throw Failure.busy }
        guard sessions[task] == nil, pendingClosedTransactions[task] == nil else { throw Failure.cleanupFailed }
        guard unresolvedStartAttempts[task] == nil else { throw Failure.startOwnershipUnconfirmed }
        guard cleanupReceiptStore != nil, evidenceDirectory != nil else { throw Failure.persistenceRequired }
        guard runtimeGeneration == cleanupRuntimeGeneration else { throw Failure.inferenceContextRequired }
        preparedInferenceContexts[task] = PreparedInferenceContext(threadID: thread,
            runtimeGeneration: runtimeGeneration, preparationID: preparationID, isMaintenance: isMaintenance, isNewThread: isNewThread)
        inspectorAuthorizations.removeValue(forKey: task)?.revoke()
        inferenceContexts.removeValue(forKey: task)
        if usedSessionTokens[task] == nil { usedSessionTokens[task] = [] }
        closedTurns.removeValue(forKey: task)
        failedClosedHandoffs.remove(task)
        registerEvidenceThread(taskID: task, threadID: thread)
        cleanupTurns.removeValue(forKey: task)
    }

    /// Actual native turn acknowledgement/notification resolves the prepared
    /// context. Duplicate acknowledgements are harmless; identities cannot
    /// change under an active inference or retained lease.
    func registerInferenceTurn(taskID: String, threadID: String, turnID: String, runtimeGeneration: UUID, preparationID: UUID) throws {
        let task = try Self.canonicalID(taskID)
        let context = InferenceContext(threadID: try Self.canonicalID(threadID),
            turnID: try Self.canonicalID(turnID), runtimeGeneration: runtimeGeneration, preparationID: preparationID,
            isMaintenance: preparedInferenceContexts[task]?.isMaintenance ?? false,
            isNewThread: preparedInferenceContexts[task]?.isNewThread ?? false)
        if inferenceContexts[task] == context { return }
        guard !shuttingDown, !retiringTaskIDs.contains(task),
              sessions[task] == nil, pendingClosedTransactions[task] == nil,
              inferenceContexts[task] == nil,
              preparedInferenceContexts[task] == PreparedInferenceContext(threadID: context.threadID,
                  runtimeGeneration: runtimeGeneration, preparationID: preparationID,
                  isMaintenance: context.isMaintenance, isNewThread: context.isNewThread) else { throw Failure.inferenceContextRequired }
        inferenceContexts[task] = context
        cleanupTurns[task] = context.turnID
        if let waiter = contextWaiters.removeValue(forKey: task) { waiter.continuation.resume(returning: context) }
    }

    private static func canonicalID(_ value: String) throws -> String {
        guard let id = UUID(uuidString: value) else { throw Failure.inferenceContextRequired }
        return id.uuidString.lowercased()
    }

    private static func nativeRequestIdentity(_ data: Data, header: String?) throws -> NativeRequestIdentity {
        func parse(_ text: String, limit: Int) throws -> NativeRequestIdentity {
            guard text.utf8.count <= limit,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let thread = object["thread_id"] as? String, let turn = object["turn_id"] as? String else {
                throw Failure.inferenceContextRequired
            }
            return try NativeRequestIdentity(threadID: canonicalID(thread), turnID: canonicalID(turn))
        }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidRequest }
        let headerIdentity = try header.map { try parse($0, limit: 16_384) }
        let bodyIdentity: NativeRequestIdentity?
        if let raw = body["client_metadata"], !(raw is NSNull) {
            guard let metadata = raw as? [String: Any],
                  let text = metadata["x-codex-turn-metadata"] as? String else { throw Failure.inferenceContextRequired }
            bodyIdentity = try parse(text, limit: WebModelResponseCodec.maximumPromptBytes)
        } else { bodyIdentity = nil }
        if let headerIdentity, let bodyIdentity, headerIdentity != bodyIdentity { throw Failure.inferenceContextRequired }
        guard let identity = headerIdentity ?? bodyIdentity else { throw Failure.inferenceContextRequired }
        return identity
    }

    private func inferenceContext(taskID: String) async throws -> InferenceContext {
        if let context = inferenceContexts[taskID] { return context }
        guard preparedInferenceContexts[taskID] != nil else { throw Failure.inferenceContextRequired }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                contextWaiters[taskID] = ContextWaiter(id: id, continuation: continuation)
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    self.expireContextWaiter(taskID: taskID, id: id, cancelled: false)
                }
            }
        } onCancel: {
            Task { await self.expireContextWaiter(taskID: taskID, id: id, cancelled: true) }
        }
    }

    private func expireContextWaiter(taskID: String, id: UUID, cancelled: Bool) {
        guard contextWaiters[taskID]?.id == id,
              let waiter = contextWaiters.removeValue(forKey: taskID) else { return }
        if cancelled { waiter.continuation.resume(throwing: CancellationError()) }
        else { waiter.continuation.resume(throwing: Failure.inferenceContextRequired) }
    }

    private func revokeAllInspectorAuthorizations() {
        inspectorAuthorizations.values.forEach { $0.revoke() }
        inspectorAuthorizations.removeAll()
    }

    private func revokeInferenceContext(taskID: String) {
        inspectorAuthorizations.removeValue(forKey: taskID)?.revoke()
        preparedInferenceContexts.removeValue(forKey: taskID)
        inferenceContexts.removeValue(forKey: taskID)
        if let waiter = contextWaiters.removeValue(forKey: taskID) {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    func registerCleanupTurn(taskID: String, threadID: String?, turnID: String?) {
        let taskID = UUID(uuidString: taskID)?.uuidString.lowercased() ?? taskID
        if let threadID { registerEvidenceThread(taskID: taskID, threadID: threadID) }
        guard let turnID, UUID(uuidString: turnID) != nil else { return }
        cleanupTurns[taskID] = turnID
    }

    func latestCleanupReceipts() -> [WebsiteSessionCleanupReceipt] { cleanupReceiptStore?.latest() ?? [] }

    func recordCleanupRejection(taskID: String, runtimeGeneration: UUID, reason: WebsiteSessionCleanupReceipt.Reason) async -> WebsiteSessionCleanupReceipt {
        let taskID = UUID(uuidString: taskID)?.uuidString.lowercased() ?? taskID
        let receipt = recordCleanupReceipt(taskID: taskID, session: sessions[taskID] ?? pendingClosedTransactions[taskID]?.session,
            runtimeGeneration: runtimeGeneration,
            outcome: .unconfirmed, reason: reason, trigger: .manual)
        await cleanupReceiptObserver?(receipt)
        return receipt
    }

    func retryWebsiteSessionCleanup(taskID: String, runtimeGeneration: UUID) async -> WebsiteSessionCleanupReceipt {
        let taskID = UUID(uuidString: taskID)?.uuidString.lowercased() ?? taskID
        guard !shuttingDown else { return await recordCleanupRejection(taskID: taskID, runtimeGeneration: runtimeGeneration, reason: .shuttingDown) }
        guard active[taskID] == nil, cleanupTasks[taskID] == nil, !retiringTaskIDs.contains(taskID) else {
            return await recordCleanupRejection(taskID: taskID, runtimeGeneration: runtimeGeneration, reason: .busy)
        }
        return await cleanup(taskID: taskID, cancel: true, runtimeGeneration: runtimeGeneration, trigger: .manual).receipt
    }

    private func recordCleanupReceipt(taskID: String, session: Session?, runtimeGeneration: UUID,
                                      outcome: WebsiteSessionCleanupReceipt.Outcome, reason: WebsiteSessionCleanupReceipt.Reason,
                                      trigger: WebsiteSessionCleanupReceipt.Trigger) -> WebsiteSessionCleanupReceipt {
        var receipt = makeCleanupReceipt(taskID: taskID, session: session, runtimeGeneration: runtimeGeneration,
            outcome: outcome, reason: reason, trigger: trigger)
        receipt.receiptSaved = true
        if cleanupReceiptStore?.save(receipt) != true { receipt.receiptSaved = false }
        return receipt
    }

    private func makeCleanupReceipt(taskID: String, session: Session?, runtimeGeneration: UUID,
                                    outcome: WebsiteSessionCleanupReceipt.Outcome, reason: WebsiteSessionCleanupReceipt.Reason,
                                    trigger: WebsiteSessionCleanupReceipt.Trigger) -> WebsiteSessionCleanupReceipt {
        let canonicalTask = UUID(uuidString: taskID)?.uuidString.lowercased() ?? taskID
        return WebsiteSessionCleanupReceipt(taskID: taskID,
            threadID: session?.context.threadID ?? evidenceThreads[canonicalTask],
            turnID: session?.context.turnID ?? cleanupTurns[canonicalTask],
            runtimeGeneration: session?.context.runtimeGeneration ?? runtimeGeneration, outcome: outcome,
            provider: session.flatMap { WebsiteSessionCleanupReceipt.Provider(rawValue: $0.provider) },
            route: session.map { _ in .embedded }, modelID: session?.modelID,
            reason: reason, trigger: trigger, inferenceID: session?.inferenceID.uuidString.lowercased(),
            sessionToken: session?.token)
    }
    #if DEBUG
    private var beforeListenerStartForTesting: (@Sendable () async -> Void)?
    private var retainsChatGPTConversationForTesting = false

    func retainChatGPTConversationForTesting() {
        retainsChatGPTConversationForTesting = true
    }
    #endif

    private func retainsConversation(provider: String) -> Bool {
        #if DEBUG
        if provider == "chatgpt" { return retainsChatGPTConversationForTesting }
        #endif
        return provider == "gemini"
    }

    /// A configured directory alone never enables response-content capture.
    /// Its private arm.json must explicitly name the exact local task.
    init(rejectedReplyDirectory: URL? = nil) {
        self.rejectedReplyDirectory = rejectedReplyDirectory
    }

    func start() async throws -> URL {
        if let baseURL { return baseURL }
        if let starting { return try await starting.value }
        let startup = Task { try await self.startListener() }
        starting = startup
        defer { starting = nil }
        return try await startup.value
    }

    func configureEvidenceDirectory(_ url: URL) {
        evidenceDirectory = url
    }

    func registerEvidenceThread(taskID: String, threadID: String) {
        failureDiagnostics.clear(taskID: taskID)
        guard let task = UUID(uuidString: taskID), let thread = UUID(uuidString: threadID) else { return }
        evidenceThreads[task.uuidString.lowercased()] = thread.uuidString.lowercased()
    }

    private func startListener() async throws -> URL {
        #if DEBUG
        if let beforeListenerStartForTesting { await beforeListenerStartForTesting() }
        #endif
        // Shutdown may cancel this task before the actor starts running it.
        // Check before reopening the server or creating a listener.
        try Task.checkCancellation()
        shuttingDown = false
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = WebListenerReady(continuation)
            server.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = server.port { once.complete(.success(port.rawValue)) }
                    else { once.complete(.failure(Failure.invalidRequest)) }
                case .failed(let error): once.complete(.failure(error))
                case .cancelled: once.complete(.failure(CancellationError()))
                default: break
                }
            }
            server.start(queue: queue)
        }
        // A ready callback can race shutdown while this actor is suspended.
        // Never restore a cached endpoint for a listener shutdown cancelled.
        try Task.checkCancellation()
        let url = URL(string: "http://127.0.0.1:\(port)/v1")!
        baseURL = url
        return url
    }

    func configureEmbeddedTransport(_ value: any WebModelTransport) {
        let identity = value as AnyObject
        if embeddedTransportIdentity === identity { return }
        revokeAllInspectorAuthorizations()
        embeddedTransport = value
        embeddedTransportIdentity = identity
        embeddedTransportGeneration = UUID()
    }

    #if DEBUG
    func setTimeoutsForTesting(readiness: Duration, response: Duration) {
        readinessTimeout = max(.milliseconds(1), min(.seconds(45), readiness))
        responseTimeout = max(.milliseconds(1), min(.seconds(300), response))
    }

    func setBeforeListenerStartForTesting(_ value: (@Sendable () async -> Void)?) {
        beforeListenerStartForTesting = value
    }

    func invalidateHandoffForTesting(taskID: String, inferenceID: UUID) {
        invalidateHandoff(taskID: (try? Self.canonicalID(taskID)) ?? taskID, inferenceID: inferenceID)
    }

    func isRetiringForTesting(taskID: String) -> Bool {
        retiringTaskIDs.contains(UUID(uuidString: taskID)?.uuidString.lowercased() ?? taskID)
    }

    func isWaitingForContextForTesting(taskID: String) -> Bool {
        contextWaiters[UUID(uuidString: taskID)?.uuidString.lowercased() ?? taskID] != nil
    }
    #endif

    func finish(taskID: String, runtimeGeneration: UUID? = nil) async -> [String] {
        let taskID = UUID(uuidString: taskID)?.uuidString.lowercased() ?? taskID
        failureDiagnostics.clear(taskID: taskID)
        guard active[taskID] == nil else { return [Failure.busy.localizedDescription] }
        yieldedTurns.removeValue(forKey: taskID)
        closedTurns.removeValue(forKey: taskID)
        failedClosedHandoffs.remove(taskID)
        revokeInferenceContext(taskID: taskID)
        return await cleanup(taskID: taskID, cancel: false, runtimeGeneration: runtimeGeneration ?? cleanupRuntimeGeneration, trigger: .automatic).issues
    }

    func cancel(taskID: String, runtimeGeneration: UUID? = nil,
                cleanupCause: WebModelCleanupCause = .cancelled) async -> [String] {
        let taskID = UUID(uuidString: taskID)?.uuidString.lowercased() ?? taskID
        failureDiagnostics.clear(taskID: taskID)
        retiringTaskIDs.insert(taskID)
        yieldedTurns.removeValue(forKey: taskID)
        closedTurns.removeValue(forKey: taskID)
        failedClosedHandoffs.remove(taskID)
        revokeInferenceContext(taskID: taskID)
        defer { retiringTaskIDs.remove(taskID) }
        let cause: WebModelCleanupCause = shuttingDown ? .cancelled : cleanupCause
        let request = active[taskID]
        request?.operation.cancel()
        if cause == .cancelled { await interruptPostBlockObservation(taskID: taskID) }
        if let request { _ = try? await request.operation.value }
        if active[taskID]?.id == request?.id { active.removeValue(forKey: taskID) }
        return await cleanup(taskID: taskID, cancel: true, runtimeGeneration: runtimeGeneration ?? cleanupRuntimeGeneration,
            trigger: shuttingDown ? .shutdown : .automatic, cleanupCause: cause).issues
    }

    func shutdown() async -> [String] {
        failureDiagnostics.removeAll()
        shuttingDown = true
        starting?.cancel()
        listener?.cancel(); listener = nil; baseURL = nil
        embeddedTransport = nil
        embeddedTransportIdentity = nil
        let ids = Set(sessions.keys).union(active.keys).union(pendingClosedTransactions.keys).union(unresolvedStartAttempts.keys)
            .union(preparedInferenceContexts.keys).union(inferenceContexts.keys)
        var issues: [String] = []
        for id in ids { issues += await cancel(taskID: id) }
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        return issues
    }

    private func cleanup(taskID: String, cancel: Bool, runtimeGeneration: UUID,
                         trigger: WebsiteSessionCleanupReceipt.Trigger,
                         cleanupCause: WebModelCleanupCause = .cancelled) async -> CleanupResult {
        yieldedTurns.removeValue(forKey: taskID)
        if let existing = cleanupTasks[taskID] { return await waitForCleanup(existing, taskID: taskID) }
        if let attempt = unresolvedStartAttempts[taskID] {
            var receipt = unresolvedStartReceipts[taskID] ?? WebsiteSessionCleanupReceipt(taskID: taskID,
                threadID: attempt.context.threadID, turnID: attempt.context.turnID,
                runtimeGeneration: attempt.context.runtimeGeneration, outcome: .unconfirmed,
                provider: WebsiteSessionCleanupReceipt.Provider(rawValue: attempt.provider),
                route: .embedded, modelID: attempt.modelID,
                reason: .cleanupUnverified, trigger: trigger,
                inferenceID: attempt.inferenceID.uuidString.lowercased())
            receipt.receiptSaved = true
            if cleanupReceiptStore?.save(receipt) != true { receipt.receiptSaved = false }
            unresolvedStartReceipts[taskID] = receipt
            await cleanupReceiptObserver?(receipt)
            return CleanupResult(receipt: receipt, issues: [Failure.startOwnershipUnconfirmed.localizedDescription]
                + (receipt.receiptSaved ? [] : [Failure.persistenceRequired.localizedDescription]))
        }
        if let pending = pendingClosedTransactions[taskID] {
            return await persistClosedTransaction(taskID: taskID, pending: pending)
        }
        guard let session = sessions[taskID] else {
            // A final inference closure already has the strongest causal proof.
            // Turn-end must not replace it with a weaker no_owned_session row.
            if let receipt = lastClosedTransactions[taskID], receipt.receiptSaved,
               receipt.runtimeGeneration == runtimeGeneration.uuidString.lowercased(),
               receipt.turnID == cleanupTurns[taskID] {
                await cleanupReceiptObserver?(receipt)
                return CleanupResult(receipt: receipt, issues: [])
            }
            let receipt = recordCleanupReceipt(taskID: taskID, session: nil, runtimeGeneration: runtimeGeneration,
                outcome: .noOwnedSession, reason: .noOwnedSession, trigger: trigger)
            await cleanupReceiptObserver?(receipt)
            return CleanupResult(receipt: receipt, issues: receipt.receiptSaved ? [] : [Failure.persistenceRequired.localizedDescription])
        }
        let cleanup = Task { await self.performCleanup(taskID: taskID, session: session, cancel: cancel,
            runtimeGeneration: runtimeGeneration, trigger: trigger, cleanupCause: cleanupCause) }
        cleanupTasks[taskID] = cleanup
        let receipt = await waitForCleanup(cleanup, taskID: taskID)
        cleanupTasks.removeValue(forKey: taskID)
        return receipt
    }

    private func waitForCleanup(_ cleanup: Task<CleanupResult, Never>, taskID: String) async -> CleanupResult {
        let interruption = postBlockInterruption(taskID: taskID)
        return await withTaskCancellationHandler(operation: { await cleanup.value }, onCancel: {
            // Cancelling a waiter must not abandon ordinary session cleanup.
            // Bind its exact old session before launching work that could run
            // after a newer session is admitted for this task ID.
            guard let interruption else { return }
            Task { await interruption() }
        })
    }

    private func postBlockInterruption(taskID: String) -> (@Sendable () async -> Void)? {
        guard let session = sessions[taskID] else { return nil }
        let transport = session.transport, token = session.token
        return { await transport.interruptPostBlockObservation(sessionToken: token) }
    }

    #if DEBUG
    func postBlockInterruptionForTesting(taskID: String) -> (@Sendable () async -> Void)? {
        postBlockInterruption(taskID: taskID)
    }
    #endif

    private func interruptPostBlockObservation(taskID: String) async {
        guard let interruption = postBlockInterruption(taskID: taskID) else { return }
        await interruption()
    }

    private func performCleanup(taskID: String, session: Session, cancel: Bool, runtimeGeneration: UUID,
                                trigger: WebsiteSessionCleanupReceipt.Trigger,
                                cleanupCause: WebModelCleanupCause) async -> CleanupResult {
        session.requestMetadata?.revoke()
        if session.requestMetadata != nil { await session.transport.revokeRequestMetadata(sessionToken: session.token) }
        if let authorization = inspectorAuthorizations.removeValue(forKey: taskID) {
            authorization.revoke()
            await session.transport.revokeInspectorDiagnostic(sessionToken: session.token)
        }
        do {
            var params = ["sessionToken": session.token]
            if cancel { params["cleanupCause"] = cleanupCause.rawValue }
            let reply = try await call(session.transport,
                operation: cancel ? "webProviderCancel" : "webProviderFinish",
                params: params)
            guard ["deleted", "not_created"].contains(reply["cleanup"] as? String ?? "") else {
                throw Self.snapshotFailure(reply, fallback: .cleanupFailed)
            }
            let receipt = makeCleanupReceipt(taskID: taskID, session: session, runtimeGeneration: runtimeGeneration,
                outcome: .closed, reason: reply["cleanup"] as? String == "deleted" ? .deleted : .notCreated, trigger: trigger)
            if sessions[taskID]?.token == session.token { sessions.removeValue(forKey: taskID) }
            let pending = PendingClosedTransaction(session: session, receipt: receipt)
            pendingClosedTransactions[taskID] = pending
            return await persistClosedTransaction(taskID: taskID, pending: pending)
        } catch {
            // Retain exact ownership for another cleanup attempt; never claim
            // that closing a tab alone deleted a saved website conversation.
            let receipt = recordCleanupReceipt(taskID: taskID, session: session, runtimeGeneration: runtimeGeneration,
                outcome: .unconfirmed, reason: .cleanupUnverified, trigger: trigger)
            await cleanupReceiptObserver?(receipt)
            // Preserve only the existing finite bridge diagnostic, never raw
            // transport text, in the user-facing warning.
            let detail = error as? WebsiteProviderFailure
            let issues = detail.map { [Failure.cleanupFailed.localizedDescription + " " + $0.localizedDescription] }
                ?? [Failure.cleanupFailed.localizedDescription]
            return CleanupResult(receipt: receipt, issues: issues)
        }
    }

    private func persistClosedTransaction(taskID: String, pending: PendingClosedTransaction) async -> CleanupResult {
        let profile = WebsiteResponseProfile.cleanup?.matchingCleanup(sessionToken: pending.session.token,
            sequence: pending.session.sequence, inferenceID: pending.session.inferenceID)
        var receipt = pending.receipt
        receipt.receiptSaved = true
        profile?.mark(.cleanupPersistStart)
        let saved = cleanupReceiptStore?.save(receipt) == true
        profile?.mark(.cleanupPersistEnd)
        guard saved else {
            receipt.receiptSaved = false
            await cleanupReceiptObserver?(receipt)
            return CleanupResult(receipt: receipt, issues: [Failure.persistenceRequired.localizedDescription])
        }
        if pending.session.provesNativeContinuation, let data = pending.session.completedSnapshot {
            do {
                profile?.mark(.cleanupReleaseStart)
                defer { profile?.mark(.cleanupReleaseEnd) }
                guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.persistenceRequired }
                try recordEvidence(pending.session.resolvedModel, snapshot: snapshot, taskID: taskID,
                    inferenceID: pending.session.inferenceID, session: pending.session,
                    phase: "release_verified", cleanupAttemptID: receipt.attemptID)
            } catch {
                // Closure already happened. Keep only this exact persistence
                // transaction; retry must never send Finish or inference again.
                return CleanupResult(receipt: receipt, issues: [Failure.persistenceRequired.localizedDescription])
            }
        }
        if pendingClosedTransactions[taskID]?.receipt.attemptID == pending.receipt.attemptID {
            pendingClosedTransactions.removeValue(forKey: taskID)
        }
        lastClosedTransactions[taskID] = receipt
        profile?.mark(.cleanupObserverStart)
        do {
            defer { profile?.mark(.cleanupObserverEnd) }
            await cleanupReceiptObserver?(receipt)
        }
        return CleanupResult(receipt: receipt, issues: [])
    }

    func infer(_ data: Data, taskID: String) async throws -> Data {
        let prepared: WebModelResponseCodec.Request
        let identity: NativeRequestIdentity
        do {
            prepared = try WebModelResponseCodec.prepareRequest(data)
            identity = try Self.nativeRequestIdentity(data, header: nil)
        } catch {
            retireMalformedRequest(taskID: taskID)
            throw error
        }
        return try await infer(prepared, taskID: taskID, identity: identity).data
    }

    private func retireMalformedRequest(taskID: String) {
        guard let task = try? Self.canonicalID(taskID), active[task] == nil else { return }
        yieldedTurns.removeValue(forKey: task)
    }

    private func infer(_ request: WebModelResponseCodec.Request, taskID: String, identity: NativeRequestIdentity) async throws -> InferenceResult {
        let taskID = try Self.canonicalID(taskID)
        guard !shuttingDown, active[taskID] == nil, cleanupTasks[taskID] == nil,
              !retiringTaskIDs.contains(taskID) else { throw Failure.busy }
        guard let selection = WebsiteModelCatalog.inferenceSelection(for: request.model) else {
            yieldedTurns.removeValue(forKey: taskID)
            if request.model.hasPrefix("browser/") { throw Failure.invalidRequest }
            throw Failure.modelNotFound
        }
        let provider = selection.provider
        // All catalog website models use the app-owned browser.
        guard let transport = embeddedTransport else { throw Failure.embeddedRequired }
        guard cleanupReceiptStore != nil, evidenceDirectory != nil else { throw Failure.persistenceRequired }
        guard pendingClosedTransactions[taskID] == nil,
              sessions[taskID] == nil || yieldedTurns[taskID] != nil,
              !failedClosedHandoffs.contains(taskID) else { throw Failure.cleanupFailed }
        guard unresolvedStartAttempts[taskID] == nil else { throw Failure.startOwnershipUnconfirmed }
        let generation = embeddedTransportGeneration
        let operation = Task { try await self.perform(request, provider: provider,
            taskID: taskID, identity: identity, transport: transport, transportGeneration: generation) }
        let id = UUID()
        active[taskID] = ActiveRequest(id: id, operation: operation)
        defer { if active[taskID]?.id == id { active.removeValue(forKey: taskID) } }
        return try await operation.value
    }

    private func perform(_ originalRequest: WebModelResponseCodec.Request, provider: String,
                         taskID: String, identity: NativeRequestIdentity,
                         transport: any WebModelTransport, transportGeneration: UUID) async throws -> InferenceResult {
        let context = try await inferenceContext(taskID: taskID)
        var inferenceID = UUID()
        let submissionFailureSink = ChatSubmissionFailureDiagnosticSink()
        var lease = sessions[taskID]
        var closedHandoff = closedTurns[taskID]
        var requestMetadata = lease?.requestMetadata
        // Claim this handoff before any suspension. A duplicate request cannot
        // reuse a claim, including after validation, Send or persistence fails.
        var yielded = yieldedTurns.removeValue(forKey: taskID)
        let firstNativeInference = lease == nil && closedHandoff == nil && yielded == nil
        let correctionStore = evidenceDirectory.map {
            WebsiteModelFormatCorrectionStore(directory: $0.appendingPathComponent("format-corrections-v1"))
        }
        var correctionTicket: WebsiteModelFormatCorrectionStore.Ticket?
        var correctionSource: Session?
        var correctionFinished = false
        var rejectionRecordedID: UUID?
        var responseDeadline: ContinuousClock.Instant?
        func requireCurrentContext(includeResponseDeadline: Bool = true) throws {
            try Task.checkCancellation()
            guard !shuttingDown, !retiringTaskIDs.contains(taskID), cleanupTasks[taskID] == nil,
                  context.runtimeGeneration == cleanupRuntimeGeneration,
                  inferenceContexts[taskID] == context,
                  identity == NativeRequestIdentity(threadID: context.threadID, turnID: context.turnID),
                  transportGeneration == embeddedTransportGeneration else {
                throw Failure.inferenceContextRequired
            }
            if includeResponseDeadline, correctionTicket != nil, let responseDeadline,
               ContinuousClock.now >= responseDeadline { throw Failure.deadline }
        }
        // Validate the full saved request first, then project its callable subset
        // only after native turn admission. Freeze it for corrective attempts;
        // continuation checks still use the unchanged original request bytes.
        try requireCurrentContext()
        let request: WebModelResponseCodec.Request
        if originalRequest.requiresBrowserToolAvailability {
            guard let browserToolAvailabilityProvider else { throw Failure.inferenceContextRequired }
            let revision = browserToolAvailabilityProviderRevision
            let availability: EmbeddedBrowserToolAvailability
            do {
                availability = try await browserToolAvailabilityProvider(.init(taskID: taskID,
                    threadID: context.threadID, turnID: context.turnID, preparationID: context.preparationID))
            } catch {
                try Task.checkCancellation()
                throw Failure.inferenceContextRequired
            }
            try requireCurrentContext()
            guard revision == browserToolAvailabilityProviderRevision else { throw Failure.inferenceContextRequired }
            request = try WebModelResponseCodec.prepareRequest(originalRequest.continuationRequest,
                browserToolAvailability: availability)
        } else {
            request = originalRequest
        }
        if provider == "chatgpt" {
            // Finite sizes only: no prompt, account data, URLs or authority tokens.
            Self.promptLog.info("promptSizes version=1 \(request.promptStatistics.diagnostic, privacy: .public)")
        }
        let correctionPrompt = request.prompt + Self.formatCorrectionReminder
        func verifiedModelEvidence(_ snapshot: [String: Any], session: inout Session) throws -> WebsiteModelEvidence? {
            let current = try Self.modelEvidence(snapshot, session: session)
            guard !session.provesNativeContinuation || current != nil else { throw Failure.modelUnverified }
            if let pinned = session.resolvedModel {
                guard let current, pinned.isSameResolvedSelection(as: current) else { throw Failure.modelMismatch }
            } else if let current { session.resolvedModel = current }
            return current
        }
        attempts: while true {
            do {
                try requireCurrentContext()
                guard let selection = WebsiteModelCatalog.inferenceSelection(for: request.model),
                      selection.provider == provider else { throw Failure.invalidRequest }
                let choice = selection.choice
                var session: Session
                let prompt: String
                if var previous = lease {
                    guard let yielded, yielded.inferenceID == previous.inferenceID,
                          previous.context == context, previous.provider == provider,
                          previous.modelID == request.model, previous.modelChoice == choice,
                          previous.transportGeneration == transportGeneration,
                          let completedCount = previous.completedResponseCount,
                          let completedText = previous.completedText,
                          previous.sequence < 1_024 else { throw Failure.invalidRequest }
                    try yielded.continuation.validate(next: request)
                    if previous.usesBoundedTurn {
                        guard previous.turnInferenceCount < Self.maximumTurnInferences,
                              request.prompt.utf8.count <= Self.maximumTurnPromptUTF8Bytes - previous.cumulativePromptUTF8Count else {
                            throw Failure.turnLimit
                        }
                    }
                    prompt = request.prompt
                    try recordTransactionEvidence(taskID: taskID, inferenceID: inferenceID, context: context,
                        provider: provider, modelID: request.model, sessionToken: previous.token, phase: "continuation_requested",
                        sequence: previous.sequence + 1, baseline: completedCount, turnScoped: previous.retainsConversation)
                    let observed = try await call(previous.transport, operation: "webProviderPoll", params: ["sessionToken": previous.token])
                    try requireCurrentContext()
                    guard observed["state"] as? String == "complete" else { throw Self.snapshotFailure(observed) }
                    try Self.verifyInferenceSnapshot(observed, session: &previous)
                    _ = try verifiedModelEvidence(observed, session: &previous)
                    guard (observed["modelProofContext"] as? [String: Any])?["responseCount"] as? Int == completedCount,
                          observed["text"] as? String == completedText else { throw Failure.invalidRequest }
                    previous.inferenceID = inferenceID
                    previous.sequence += 1
                    previous.baselineResponseCount = completedCount
                    previous.completedResponseCount = nil
                    previous.completedText = nil
                    previous.completedSnapshot = nil
                    session = previous
                    sessions[taskID] = session
                    lease = session
                    try recordTransactionEvidence(taskID: taskID, inferenceID: inferenceID, context: context,
                        provider: provider, modelID: request.model, sessionToken: session.token, phase: "continued",
                        sequence: session.sequence, baseline: session.baselineResponseCount, turnScoped: session.retainsConversation)
                } else {
                    guard yielded == nil else { throw Failure.invalidRequest }
                    let closed = closedHandoff
                    if let closed {
                        guard closed.context == context, closed.transportGeneration == transportGeneration,
                              !closed.ambiguousHandoff else { throw Failure.inferenceContextRequired }
                        try closed.continuation.validate(next: request)
                    }
                    let provesNativeContinuation = Self.requiresNativeContinuationProof(provider: provider)
                    if provesNativeContinuation { try WebsiteTurnContinuation.validateRequest(request) }
                    if provider == "chatgpt", provesNativeContinuation {
                        guard (closed?.turnInferenceCount ?? 0) < Self.maximumTurnInferences,
                              request.prompt.utf8.count <= Self.maximumTurnPromptUTF8Bytes - (closed?.cumulativePromptUTF8Count ?? 0)
                        else { throw Failure.turnLimit }
                    }
                    prompt = correctionTicket == nil ? request.prompt : correctionPrompt
                    var params = ["provider": provider]
                    if let choice {
                        guard let encoded = choice.canonicalJSONString else { throw Failure.invalidRequest }
                        params["modelChoice"] = encoded
                    }
                    try recordTransactionEvidence(taskID: taskID, inferenceID: inferenceID, context: context,
                        provider: provider, modelID: request.model, sessionToken: nil, phase: "start_requested",
                        turnScoped: retainsConversation(provider: provider))
                    unresolvedStartAttempts[taskID] = UnresolvedStartAttempt(inferenceID: inferenceID, context: context,
                        provider: provider, modelID: request.model)
                    if correctionTicket == nil, provider == "chatgpt", !context.isMaintenance,
                       let task = UUID(uuidString: taskID), let thread = UUID(uuidString: context.threadID),
                       let turn = UUID(uuidString: context.turnID),
                       let directory = rejectedReplyDirectory?.deletingLastPathComponent()
                        .appendingPathComponent("WebsiteRequestMetadataDiagnostics-v1") {
                        requestMetadata = ChatGPTRequestMetadataLease.consume(directory: directory,
                            taskID: task, threadID: thread, turnID: turn, preparationID: context.preparationID,
                            isMaintenance: context.isMaintenance)
                    }
                    let reply: [String: Any]
                    if let requestMetadata {
                        let data = try await transport.startWithRequestMetadata(
                            params: JSONSerialization.data(withJSONObject: params), authorization: requestMetadata)
                        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidRequest }
                        reply = object
                    } else { reply = try await call(transport, operation: "webProviderStart", params: params) }
                    guard let rawToken = reply["sessionToken"] as? String, let token = UUID(uuidString: rawToken) else {
                        throw Self.snapshotFailure(reply)
                    }
                    let advertised = reply["turnContinuationCapability"]
                    session = Session(token: rawToken, provider: provider, modelID: request.model,
                        modelChoice: choice, transport: transport, inferenceID: inferenceID,
                        context: context, transportGeneration: transportGeneration,
                        provesNativeContinuation: provesNativeContinuation,
                        retainsConversation: retainsConversation(provider: provider))
                    session.requestMetadata = requestMetadata
                    session.resolvedModel = correctionSource?.resolvedModel ?? closed?.resolvedModel
                    session.turnInferenceCount = correctionSource?.turnInferenceCount ?? closed?.turnInferenceCount ?? 0
                    session.cumulativePromptUTF8Count = correctionSource?.cumulativePromptUTF8Count ?? closed?.cumulativePromptUTF8Count ?? 0
                    // Capture ownership before cancellation or validation can fail.
                    sessions[taskID] = session
                    lease = session
                    if unresolvedStartAttempts[taskID]?.inferenceID == inferenceID {
                        unresolvedStartAttempts.removeValue(forKey: taskID)
                    }
                    try recordTransactionEvidence(taskID: taskID, inferenceID: inferenceID, context: context,
                        provider: provider, modelID: request.model, sessionToken: session.token, phase: "started", turnScoped: session.retainsConversation)
                    guard usedSessionTokens[taskID, default: []].insert(token.uuidString.lowercased()).inserted else { throw Failure.invalidRequest }
                    try requireCurrentContext()
                    if let closed {
                        guard closedTurns[taskID]?.inferenceID == closed.inferenceID,
                              closedTurns[taskID]?.ambiguousHandoff == false else { throw Failure.inferenceContextRequired }
                    }
                    guard ["ready", "loading"].contains(reply["state"] as? String ?? "") else { throw Self.snapshotFailure(reply) }
                    if provider == "chatgpt", advertised != nil,
                       advertised as? String != "per_submission_ownership_v1" { throw Failure.invalidRequest }
                    if session.provesNativeContinuation {
                        guard reply["turnContinuationCapability"] as? String == "per_submission_ownership_v1" else { throw Failure.invalidRequest }
                        try WebsiteTurnContinuation.validateRequest(request)
                    }
                    if reply["state"] as? String == "ready" { _ = try verifiedModelEvidence(reply, session: &session) }
                    let stageDeadline = ContinuousClock.now + readinessTimeout
                    let readinessDeadline = correctionTicket == nil ? stageDeadline : min(stageDeadline, responseDeadline ?? stageDeadline)
                    var ready = reply["state"] as? String == "ready"
                    while !ready, ContinuousClock.now < readinessDeadline {
                        try requireCurrentContext()
                        let revision = try await session.transport.changeRevision(sessionToken: session.token)
                        guard ContinuousClock.now < readinessDeadline else { throw Failure.preparationDeadline }
                        let state = try await call(session.transport, operation: "webProviderPoll", params: ["sessionToken": session.token])
                        try requireCurrentContext()
                        guard ContinuousClock.now < readinessDeadline else { throw Failure.preparationDeadline }
                        if ["ready", "running"].contains(state["state"] as? String ?? "") { _ = try verifiedModelEvidence(state, session: &session) }
                        if state["state"] as? String == "ready" { ready = true }
                        else if !["loading", "running"].contains(state["state"] as? String ?? "") { throw Self.snapshotFailure(state) }
                        if !ready { try await waitForNextPoll(session, after: revision, until: readinessDeadline) }
                    }
                    guard ready else { throw Failure.preparationDeadline }
                }
                try requireCurrentContext()
                if let requestMetadata, session.sequence == 1 {
                    var activated = false
                    if let task = UUID(uuidString: taskID), let thread = UUID(uuidString: context.threadID),
                          let turn = UUID(uuidString: context.turnID),
                          requestMetadata.matches(taskID: task, threadID: thread, turnID: turn,
                            preparationID: context.preparationID) {
                        activated = await session.transport.activateRequestMetadata(sessionToken: session.token)
                    } else { requestMetadata.revoke() }
                    try requireCurrentContext()
                    if requestMetadata.capturesDecodedEvents && !activated { throw Failure.requestMetadataUnavailable }
                }
                // No wire/model-tool grant. A same-UID manual arm scopes one current
                // native turn; it is not authentication of the person who wrote it.
                if correctionTicket == nil, provider == "chatgpt", inspectorAuthorizations[taskID] == nil,
                   let task = UUID(uuidString: taskID), let thread = UUID(uuidString: context.threadID),
                   let turn = UUID(uuidString: context.turnID),
                   let directory = rejectedReplyDirectory?.deletingLastPathComponent().appendingPathComponent("WebsiteInspectorDiagnostics-v1"),
                   let authorization = ChatGPTInspectorLease.consume(directory: directory, taskID: task, threadID: thread, turnID: turn) {
                    inspectorAuthorizations[taskID] = authorization
                    let granted = await session.transport.grantInspectorDiagnostic(authorization, sessionToken: session.token)
                    try requireCurrentContext()
                    if !granted || !authorization.matches(taskID: task, threadID: thread, turnID: turn) {
                        authorization.revoke()
                        if granted { await session.transport.revokeInspectorDiagnostic(sessionToken: session.token) }
                    }
                }
                if session.usesBoundedTurn {
                    let bytes = prompt.utf8.count
                    guard session.turnInferenceCount < Self.maximumTurnInferences,
                          bytes <= Self.maximumTurnPromptUTF8Bytes - session.cumulativePromptUTF8Count else {
                        throw Failure.turnLimit
                    }
                    session.cumulativePromptUTF8Count += bytes
                    session.turnInferenceCount += 1
                }
                // An earlier HTTP output may fail while the new page prepares.
                // Recheck its exact closed handoff after every preparation await.
                if let closedHandoff {
                    guard closedTurns[taskID]?.inferenceID == closedHandoff.inferenceID,
                          closedTurns[taskID]?.ambiguousHandoff == false else { throw Failure.inferenceContextRequired }
                    closedTurns.removeValue(forKey: taskID)
                }
                session.submittedPromptFingerprint = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
                sessions[taskID] = session
                lease = session
                if provider == "chatgpt", responseDeadline == nil {
                    // Include the first Send await in the one absolute correction
                    // budget; a rejected reply never renews this deadline.
                    responseDeadline = ContinuousClock.now + responseTimeout
                }
                // A private nonce arm can retain only a new synthetic first
                // Instant payload. Task-local metadata reaches the exact native
                // send without adding wire fields, tools, waits or page authority.
                let benchmarkCapture = WebsiteBenchmarkCaptureLease.consume(
                    directory: rejectedReplyDirectory?.deletingLastPathComponent().appendingPathComponent("WebsiteBenchmarkDiagnostics-v1"),
                    request: request, taskID: taskID, threadID: context.threadID, turnID: context.turnID,
                    runtimeGeneration: context.runtimeGeneration, preparationID: context.preparationID,
                    isNewThread: context.isNewThread, isMaintenance: context.isMaintenance,
                    isFirstInference: firstNativeInference && correctionTicket == nil && session.sequence == 1 && session.turnInferenceCount == 1)
                defer { benchmarkCapture?.revoke() }
                let sent = try await WebsiteBenchmarkCaptureLease.$current.withValue(benchmarkCapture) {
                    try await call(session.transport, operation: "webProviderSend",
                        params: ["sessionToken": session.token, "prompt": prompt], submissionFailureSink: submissionFailureSink)
                }
                try requireCurrentContext()
                guard sent["state"] as? String == "running" else { throw Self.snapshotFailure(sent) }
                try Self.verifyInferenceSnapshot(sent, session: &session)
                var submissionModelVerificationPending = sent["modelVerificationPending"] as? Bool == true
                if !submissionModelVerificationPending {
                    let submittedEvidence = try verifiedModelEvidence(sent, session: &session)
                    try recordEvidence(submittedEvidence, snapshot: sent, taskID: taskID, inferenceID: inferenceID, session: session, phase: "submission_verified")
                }
                sessions[taskID] = session
                lease = session
                let responseProfile = provider == "chatgpt"
                    ? WebsiteResponseProfile.begin(source: .serverAcknowledged, sessionToken: session.token,
                        sequence: session.sequence, inferenceID: inferenceID) : nil
                responseProfile?.mark(.serverSendAcknowledged)
                let end = responseDeadline ?? (ContinuousClock.now + responseTimeout)
                while ContinuousClock.now < end {
                    try requireCurrentContext()
                    let revision = try await session.transport.changeRevision(sessionToken: session.token)
                    guard ContinuousClock.now < end else { throw Failure.deadline }
                    let value = try await call(session.transport, operation: "webProviderPoll", params: ["sessionToken": session.token],
                        submissionFailureSink: submissionFailureSink)
                    try requireCurrentContext()
                    guard ContinuousClock.now < end else { throw Failure.deadline }
                    switch value["state"] as? String {
                    case "complete":
                        try Self.verifyInferenceSnapshot(value, session: &session)
                        let evidence = try verifiedModelEvidence(value, session: &session)
                        if submissionModelVerificationPending {
                            // Dispatch-only observations never assert fresh model
                            // selection. The owned final answer establishes both
                            // submission and completion before any text/tool parse.
                            responseProfile?.mark(.submissionEvidenceStart)
                            do {
                                defer { responseProfile?.mark(.submissionEvidenceEnd) }
                                try recordEvidence(evidence, snapshot: value, taskID: taskID, inferenceID: inferenceID, session: session, phase: "submission_verified")
                            }
                            submissionModelVerificationPending = false
                        }
                        guard let text = value["text"] as? String, !text.isEmpty else { throw Failure.providerFailed }
                        let reply: WebModelResponseCodec.Reply
                        responseProfile?.mark(.codecStart)
                        do {
                            defer { responseProfile?.mark(.codecEnd) }
                            reply = try WebModelResponseCodec.parseEmbeddedReply(text, request: request)
                        } catch {
                            let diagnostic = WebModelResponseCodec.malformedEmbeddedReplyDiagnostic(text, request: request)
                            if let diagnostic {
                                captureRejectedReply(text, diagnostic: .malformed(diagnostic), taskID: taskID,
                                    inferenceID: inferenceID, session: session, evidence: evidence, snapshot: value)
                                if diagnostic.reason == .invalidJSON, correctionTicket == nil,
                                   provider == "chatgpt", !context.isMaintenance,
                                   session.provesNativeContinuation, !session.retainsConversation,
                                   session.sequence == 1, session.baselineResponseCount == 0,
                                   session.resolvedModel != nil,
                                   session.turnInferenceCount < Self.maximumTurnInferences,
                                   correctionPrompt.utf8.count <= WebModelResponseCodec.maximumPromptBytes,
                                   correctionPrompt.utf8.count <= Self.maximumTurnPromptUTF8Bytes - session.cumulativePromptUTF8Count,
                                   ContinuousClock.now < end, let correctionStore,
                                   let firstToken = UUID(uuidString: session.token),
                                   let ticket = try? correctionStore.claim(taskID: taskID, threadID: context.threadID,
                                       turnID: context.turnID, firstInferenceID: inferenceID,
                                       firstSessionToken: firstToken, secondInferenceID: UUID()) {
                                    // Claim is durable before any corrective await.
                                    // The rejected bytes confer no output authority.
                                    correctionTicket = ticket
                                    correctionSource = session
                                    try recordEvidence(evidence, snapshot: value, taskID: taskID, inferenceID: inferenceID,
                                        session: session, phase: "failed", errorCode: Self.errorPresentation(for: Failure.malformedReply(diagnostic)).code)
                                    rejectionRecordedID = inferenceID
                                    if let authorization = requestMetadata {
                                        let snapshot = await session.transport.stopRequestMetadata(sessionToken: session.token)
                                        if (try? requireCurrentContext(includeResponseDeadline: false)) != nil,
                                           let snapshot, authorization.isCurrent {
                                            _ = authorization.persist(snapshot, inferenceID: inferenceID, sessionToken: firstToken)
                                        }
                                        authorization.revoke()
                                        await session.transport.revokeRequestMetadata(sessionToken: session.token)
                                        requestMetadata = nil
                                        session.requestMetadata = nil
                                        sessions[taskID] = session
                                        lease = session
                                    }
                                    // Cleanup always settles, even when cancellation
                                    // or the original deadline expires in this await.
                                    let closed = await cleanup(taskID: taskID, cancel: Task.isCancelled,
                                        runtimeGeneration: context.runtimeGeneration, trigger: .inference)
                                    guard closed.receipt.outcome == .closed,
                                          closed.receipt.inferenceID == inferenceID.uuidString.lowercased(),
                                          closed.receipt.sessionToken == session.token.lowercased() else { throw Failure.cleanupFailed }
                                    guard closed.receipt.receiptSaved, closed.issues.isEmpty,
                                          let cleanupID = UUID(uuidString: closed.receipt.attemptID) else { throw Failure.persistenceRequired }
                                    do { try correctionStore.recordClosed(ticket, cleanupAttemptID: cleanupID) }
                                    catch { throw Failure.persistenceRequired }
                                    lease = nil
                                    yielded = nil
                                    closedHandoff = nil
                                    try requireCurrentContext()
                                    inferenceID = ticket.secondInferenceID
                                    continue attempts
                                }
                                throw Failure.malformedReply(diagnostic)
                            }
                            if case .unknownTool = error as? WebModelResponseCodec.Failure {
                                captureRejectedReply(text, diagnostic: .unofferedTool, taskID: taskID,
                                    inferenceID: inferenceID, session: session, evidence: evidence, snapshot: value)
                            }
                            throw error
                        }
                        session.completedResponseCount = (value["modelProofContext"] as? [String: Any])?["responseCount"] as? Int
                        session.completedText = text
                        session.completedSnapshot = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                        sessions[taskID] = session
                        lease = session
                        responseProfile?.mark(.completionEvidenceStart)
                        do {
                            defer { responseProfile?.mark(.completionEvidenceEnd) }
                            try recordEvidence(evidence, snapshot: value, taskID: taskID, inferenceID: inferenceID, session: session, phase: "complete")
                        }
                        // Parse and validate the entire proposal above before
                        // selecting a native action. No unselected call is queued.
                        responseProfile?.mark(.encodeStart)
                        let selection = try WebsiteToolCallSelection.select(validatedReply: reply,
                            singleAction: request.singleActionRelay && provider == "chatgpt")
                        let responseID = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                        let encoded = try request.stream
                            ? WebModelResponseCodec.streamData(for: selection.reply, request: request, responseID: responseID, websiteModelEvidence: evidence, websiteToolSelection: selection.metadataValue)
                            : WebModelResponseCodec.completedResponse(for: selection.reply, request: request, responseID: responseID, websiteModelEvidence: evidence, websiteToolSelection: selection.metadataValue)
                        responseProfile?.mark(.encoded)
                        let continuation: WebsiteTurnContinuation? = try session.provesNativeContinuation ? WebsiteTurnContinuation(request: request, encodedResponse: encoded) : nil
                        if let requestMetadata {
                            let retain = session.retainsConversation && (continuation?.pendingToolCallCount ?? 0) > 0
                            let diagnostic = retain
                                ? await session.transport.snapshotRequestMetadata(sessionToken: session.token)
                                : await session.transport.stopRequestMetadata(sessionToken: session.token)
                            try requireCurrentContext()
                            if let diagnostic, let token = UUID(uuidString: session.token), requestMetadata.isCurrent {
                                _ = requestMetadata.persist(diagnostic, inferenceID: inferenceID, sessionToken: token)
                            }
                            if !retain {
                                requestMetadata.revoke()
                                await session.transport.revokeRequestMetadata(sessionToken: session.token)
                                session.requestMetadata = nil
                                sessions[taskID] = session
                                lease = session
                            }
                        }
                        if let continuation, continuation.pendingToolCallCount > 0, session.retainsConversation {
                            try recordEvidence(evidence, snapshot: value, taskID: taskID, inferenceID: inferenceID,
                                session: session, phase: "yield_verified")
                            try requireCurrentContext()
                            yieldedTurns[taskID] = YieldedTurn(inferenceID: inferenceID, continuation: continuation)
                        } else {
                            let closed = await WebsiteResponseProfile.$cleanup.withValue(responseProfile) {
                                await cleanup(taskID: taskID, cancel: Task.isCancelled,
                                    runtimeGeneration: context.runtimeGeneration, trigger: .inference)
                            }
                            guard closed.receipt.outcome == .closed,
                                  closed.receipt.inferenceID == inferenceID.uuidString.lowercased(),
                                  closed.receipt.sessionToken == session.token.lowercased() else { throw Failure.cleanupFailed }
                            guard closed.receipt.receiptSaved, closed.issues.isEmpty else { throw Failure.persistenceRequired }
                            responseProfile?.mark(.cleanupReceiptDone)
                            try requireCurrentContext()
                            if !session.provesNativeContinuation {
                                try recordEvidence(evidence, snapshot: value, taskID: taskID, inferenceID: inferenceID,
                                    session: session, phase: "release_verified", cleanupAttemptID: closed.receipt.attemptID)
                            }
                            if let continuation {
                                closedTurns[taskID] = ClosedTurn(inferenceID: inferenceID, context: context, continuation: continuation,
                                    transportGeneration: session.transportGeneration, resolvedModel: session.resolvedModel,
                                    turnInferenceCount: session.turnInferenceCount, cumulativePromptUTF8Count: session.cumulativePromptUTF8Count)
                            }
                        }
                        try requireCurrentContext()
                        if let correctionTicket, let correctionStore, let token = UUID(uuidString: session.token) {
                            do { try correctionStore.finish(correctionTicket, secondInferenceID: inferenceID,
                                secondSessionToken: token, outcome: .responseValidated) }
                            catch { throw Failure.persistenceRequired }
                            correctionFinished = true
                        }
                        try requireCurrentContext()
                        responseProfile?.mark(.inferenceReturnReady)
                        return InferenceResult(data: encoded, inferenceID: inferenceID, responseProfile: responseProfile)
                    case "running":
                        try Self.verifyInferenceSnapshot(value, session: &session)
                        if value["modelVerificationPending"] as? Bool != true {
                            _ = try verifiedModelEvidence(value, session: &session)
                        }
                        sessions[taskID] = session
                        lease = session
                        try await waitForNextPoll(session, after: revision, until: end)
                    default: throw Self.snapshotFailure(value)
                    }
                }
                throw Failure.deadline
            } catch {
                if let correctionTicket, let correctionStore, !correctionFinished {
                    let second = inferenceID == correctionTicket.secondInferenceID ? lease : nil
                    let outcome: WebsiteModelFormatCorrectionStore.Outcome
                    if error is CancellationError { outcome = .cancelled }
                    else if let failure = error as? Failure {
                        switch failure {
                        case .deadline, .preparationDeadline: outcome = .timedOut
                        case .turnLimit: outcome = .budgetExhausted
                        case let .malformedReply(diagnostic) where diagnostic.reason == .invalidJSON: outcome = .invalidJSON
                        default: outcome = .failed
                        }
                    } else { outcome = .failed }
                    try? correctionStore.finish(correctionTicket,
                        secondInferenceID: second == nil ? nil : inferenceID,
                        secondSessionToken: second.flatMap { UUID(uuidString: $0.token) }, outcome: outcome)
                    failedClosedHandoffs.insert(taskID)
                }
                if let lease, lease.provesNativeContinuation, !lease.retainsConversation,
                   !lease.submittedPromptFingerprint.isEmpty {
                    failedClosedHandoffs.insert(taskID)
                }
                if let requestMetadata {
                    if !Task.isCancelled, (try? requireCurrentContext()) != nil, let lease, lease.context == context {
                        let diagnostic = await lease.transport.stopRequestMetadata(sessionToken: lease.token)
                        if (try? requireCurrentContext()) != nil, let diagnostic, let token = UUID(uuidString: lease.token),
                           requestMetadata.isCurrent {
                            _ = requestMetadata.persist(diagnostic, inferenceID: inferenceID, sessionToken: token)
                        }
                    }
                    requestMetadata.revoke()
                    if let lease { await lease.transport.revokeRequestMetadata(sessionToken: lease.token) }
                }
                let submissionDiagnostic: ChatSubmissionFailureDiagnostic?
                if provider == "chatgpt",
                   (error as? EmbeddedWebModelTransport.Failure) == .ownershipFailure(.javaScriptSubmission),
                   (try? requireCurrentContext()) != nil, let lease, lease.context == context,
                   sessions[taskID]?.token == lease.token {
                    submissionDiagnostic = submissionFailureSink.snapshot
                } else { submissionDiagnostic = nil }
                if let authorization = inspectorAuthorizations.removeValue(forKey: taskID) {
                    authorization.revoke()
                    if let lease { await lease.transport.revokeInspectorDiagnostic(sessionToken: lease.token) }
                }
                yieldedTurns.removeValue(forKey: taskID)
                let turnLimit = (error as? EmbeddedWebModelTransport.Failure) == .turnLimit
                    || { if let failure = error as? Failure, case .turnLimit = failure { return true }; return false }()
                let decodedDiagnosticUnavailable = { if let failure = error as? Failure, case .requestMetadataUnavailable = failure { return true }; return false }()
                if turnLimit || decodedDiagnosticUnavailable {
                    let closed = await cleanup(taskID: taskID, cancel: true,
                        runtimeGeneration: context.runtimeGeneration, trigger: .automatic)
                    guard closed.receipt.outcome == .closed else { throw Failure.cleanupFailed }
                    guard closed.receipt.receiptSaved, closed.issues.isEmpty else { throw Failure.persistenceRequired }
                }
                if rejectionRecordedID != inferenceID {
                    try? recordTransactionEvidence(taskID: taskID, inferenceID: inferenceID, context: context,
                        provider: provider, modelID: request.model, sessionToken: lease?.token,
                        phase: error is CancellationError ? "cancelled" : "failed",
                        errorCode: Self.errorPresentation(for: error).code,
                        sequence: lease?.sequence ?? 0, baseline: lease?.baselineResponseCount ?? 0, turnScoped: lease?.retainsConversation,
                        submissionDiagnostic: (try? requireCurrentContext()) != nil ? submissionDiagnostic : nil)
                }
                throw error
            }
        }
    }

    private static let formatCorrectionReminder = """


    COMPUTA FORMAT CORRECTION — ONE ATTEMPT
    The entire previous website reply was rejected as invalid JSON. Fulfil the unchanged canonical request above using exactly one complete JSON response envelope inside one json code fence. Put every result or explanation inside the envelope; place no headings, prose, or summaries outside the fence. Keep the original offered tools, tool choice, permissions, arguments, and history authoritative. This corrects formatting only: do not invent results or repeat actions already completed in the canonical history.
    """


    /// An unsuccessful HTTP write cannot make this particular handoff reusable.
    /// A later round that already reconciled the exact output has a distinct ID.
    private func invalidateHandoff(taskID: String, inferenceID: UUID) {
        if yieldedTurns[taskID]?.inferenceID == inferenceID { yieldedTurns.removeValue(forKey: taskID) }
        if closedTurns[taskID]?.inferenceID == inferenceID { closedTurns[taskID]?.ambiguousHandoff = true }
    }

    private func waitForNextPoll(_ session: Session, after revision: UInt64?,
                                 until deadline: ContinuousClock.Instant) async throws {
        if let revision,
           try await session.transport.waitForChange(sessionToken: session.token, after: revision, until: deadline) != nil {
            return
        }
        // Deterministic test transports may omit notifications. Production
        // WebKit supplies versioned notifications and never takes this fallback.
        let remaining = deadline - .now
        if remaining > .zero { try await Task.sleep(for: min(.milliseconds(500), remaining)) }
    }

    static func provider(for model: String) -> String? {
        LocalModelCatalog.webProvider(for: model)
    }

    private static func modelEvidence(_ snapshot: [String: Any], session: Session) throws -> WebsiteModelEvidence? {
        guard snapshot["modelVerificationPending"] == nil, snapshot["pendingSubmissionContext"] == nil else {
            throw Failure.modelUnverified
        }
        if session.provider == "chatgpt" {
            guard (try? WebsiteProductModeEvidence.parse(snapshot["productModeEvidence"], requireTemporary: true)) != nil else {
                throw Failure.productModeUnverified
            }
        }
        guard session.modelChoice != nil || snapshot["modelEvidence"] != nil && !(snapshot["modelEvidence"] is NSNull) else { return nil }
        do { return try WebsiteModelEvidence.parse(snapshot["modelEvidence"], provider: session.provider, expected: session.modelChoice) }
        catch WebsiteModelEvidence.Failure.mismatch { throw Failure.modelMismatch }
        catch { throw Failure.modelUnverified }
    }

    private enum RejectedReplyDiagnostic {
        case malformed(WebModelResponseCodec.MalformedEnvelopeDiagnostic)
        case unofferedTool
    }

    private func captureRejectedReply(_ text: String, diagnostic: RejectedReplyDiagnostic,
                                      taskID: String, inferenceID: UUID, session: Session,
                                      evidence: WebsiteModelEvidence?, snapshot: [String: Any]) {
        guard let directory = rejectedReplyDirectory, let task = UUID(uuidString: taskID),
              let token = UUID(uuidString: session.token),
              text.utf8.count <= WebModelRejectedReplyCapture.maximumReplyBytes,
              session.modelID.utf8.count <= 2_048,
              ["chatgpt", "claude", "gemini"].contains(session.provider) else { return }
        let diagnosticFields: [String: Any]
        switch diagnostic {
        case let .malformed(value):
            guard value.utf8Bytes == text.utf8.count else { return }
            diagnosticFields = ["reason": value.reason.rawValue, "utf8Bytes": value.utf8Bytes,
                                "fenced": value.fenced]
        case .unofferedTool:
            diagnosticFields = ["reason": "unoffered_tool", "utf8Bytes": text.utf8.count]
        }
        var record: [String: Any] = ["schemaVersion": 1, "timestamp": ISO8601DateFormatter().string(from: Date()),
                                    "taskID": task.uuidString.lowercased(), "inferenceID": inferenceID.uuidString.lowercased(),
                                    "sessionToken": token.uuidString.lowercased(), "provider": session.provider,
                                    "modelID": session.modelID, "replyText": text,
                                    "diagnostic": diagnosticFields, "automaticReplay": false]
        if let thread = evidenceThreads[task.uuidString.lowercased()] { record["threadID"] = thread }
        if let evidence { record["modelEvidence"] = evidence.dictionary }
        if let context = snapshot["modelProofContext"] as? [String: Any],
           let rawGeneration = context["documentGeneration"] as? String, let generation = UUID(uuidString: rawGeneration) {
            record["documentGeneration"] = generation.uuidString.lowercased()
        }
        if let sequence = Self.receiptInteger(snapshot["sequence"], range: 1...10_000) { record["sequence"] = sequence }
        if let completion = snapshot["completionEvidence"] as? [String: Any],
           let raw = completion["codeStructure"] as? [String: Any] {
            record["codeStructure"] = Self.rejectedReplyCodeStructure(raw)
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        // A capture failure changes neither parser acceptance nor the original
        // error, execution, cleanup or retry policy. Content never enters logs.
        WebModelRejectedReplyCapture.capture(directory: directory, taskID: task, record: bytes)
    }

    private static func rejectedReplyCodeStructure(_ raw: [String: Any]) -> [String: Any] {
        // The transport's shared finite projection includes bounded widget
        // ancestry. Preserve it in an explicitly armed private capture, so a
        // final header mismatch can be diagnosed after its owned tab closes.
        if let encoded = EmbeddedWebModelTransport.sanitizedCodeStructure(raw),
           let projected = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] {
            return projected
        }
        var safe: [String: Any] = [:]
        for key in ["preCount", "codeCount"] {
            if let number = receiptInteger(raw[key], range: 0...1_000) { safe[key] = number }
        }
        for key in ["codeTextLength", "outsideTextLength"] {
            if let number = receiptInteger(raw[key], range: 0...220_001) { safe[key] = number }
        }
        if let value = raw["outsideTruncated"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            safe["outsideTruncated"] = value.boolValue
        }
        if raw["literalCodeValidJSON"] is NSNull {
            safe["literalCodeValidJSON"] = NSNull()
        } else if let value = raw["literalCodeValidJSON"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            safe["literalCodeValidJSON"] = value.boolValue
        }
        if raw["literalCodeKnownEnvelopeType"] is NSNull {
            safe["literalCodeKnownEnvelopeType"] = NSNull()
        } else if let kind = raw["literalCodeKnownEnvelopeType"] as? String, ["message", "tool_calls", "unknown"].contains(kind) {
            safe["literalCodeKnownEnvelopeType"] = kind
        }
        if let extraction = raw["selectedExtraction"] as? String, ["raw_code", "rendered_fallback"].contains(extraction) {
            safe["selectedExtraction"] = extraction
        }
        if let reason = raw["extractionReason"] as? String,
           ["absent_answer", "missing_pre", "multiple_pre", "missing_code", "multiple_code", "oversized_code", "invalid_json",
            "unknown_envelope_type", "outside_content", "outside_scan_limit", "accepted_literal_code"].contains(reason) {
            safe["extractionReason"] = reason
        }
        if let tags = raw["preParentTags"] as? [String], tags.count <= 3,
           tags.allSatisfy({ ["div", "pre", "code", "span", "p", "section", "article", "main", "li", "ul", "ol", "blockquote", "other"].contains($0) }) {
            safe["preParentTags"] = tags
        }
        return safe
    }

    private static func verifyInferenceSnapshot(_ snapshot: [String: Any], session: inout Session) throws {
        let pendingModel = snapshot["modelVerificationPending"] != nil
        if pendingModel {
            guard let flag = snapshot["modelVerificationPending"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue,
                  session.provider == "chatgpt",
                  session.modelChoice?.chatGPTPower != nil, session.resolvedModel != nil,
                  !session.submittedPromptFingerprint.isEmpty,
                  snapshot["state"] as? String == "running",
                  snapshot["text"] as? String == "", snapshot["modelEvidence"] == nil,
                  snapshot["modelProofContext"] == nil, snapshot["completionEvidence"] == nil,
                  (try? WebsiteProductModeEvidence.parse(snapshot["productModeEvidence"], requireTemporary: true)) != nil else {
                throw Failure.invalidRequest
            }
        } else if snapshot["pendingSubmissionContext"] != nil { throw Failure.invalidRequest }
        guard let token = snapshot["sessionToken"] as? String,
              UUID(uuidString: token) == UUID(uuidString: session.token),
              receiptInteger(snapshot["sequence"], range: 1...1_024) == session.sequence,
              let context = snapshot[pendingModel ? "pendingSubmissionContext" : "modelProofContext"] as? [String: Any],
              receiptInteger(context["sequence"], range: 1...1_024) == session.sequence,
              let rawGeneration = context["documentGeneration"] as? String, let generation = UUID(uuidString: rawGeneration),
              receiptInteger(context["baselineResponseCount"], range: 0...10_000) == session.baselineResponseCount,
              let responseCount = receiptInteger(context["responseCount"], range: session.baselineResponseCount...10_000),
              let fingerprint = context["firstUserFingerprint"] as? String,
              fingerprint.isEmpty || (fingerprint.utf8.count == 64 &&
                  fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })),
              session.documentGeneration == nil || session.documentGeneration == generation,
              session.firstUserFingerprint == nil || session.firstUserFingerprint == fingerprint,
              snapshot["state"] as? String != "complete" || (responseCount > session.baselineResponseCount && !fingerprint.isEmpty) else {
            throw Failure.invalidRequest
        }
        if session.provesNativeContinuation {
            guard snapshot["turnContinuationCapability"] as? String == "per_submission_ownership_v1",
                  let submitted = context["submittedPromptFingerprint"] as? String,
                  submitted.isEmpty || submitted == session.submittedPromptFingerprint,
                  snapshot["state"] as? String != "complete" ||
                    (submitted == session.submittedPromptFingerprint && responseCount == session.baselineResponseCount + 1) else {
                throw Failure.invalidRequest
            }
        }
        session.documentGeneration = generation
        if !fingerprint.isEmpty { session.firstUserFingerprint = fingerprint }
    }

    private func recordTransactionEvidence(taskID: String, inferenceID: UUID, context: InferenceContext,
                                           provider: String, modelID: String, sessionToken: String?, phase: String, errorCode: String? = nil,
                                           sequence: Int = 0, baseline: Int = 0, turnScoped: Bool? = nil,
                                           submissionDiagnostic: ChatSubmissionFailureDiagnostic? = nil) throws {
        var record = transactionEvidenceRecord(taskID: taskID, inferenceID: inferenceID, context: context,
            provider: provider, modelID: modelID, sessionToken: sessionToken, phase: phase, turnScoped: turnScoped)
        record["sequence"] = sequence
        record["baselineResponseCount"] = baseline
        if let errorCode { record["errorCode"] = errorCode }
        if phase == "failed", provider == "chatgpt", let submissionDiagnostic {
            record["submissionFailureDiagnostic"] = submissionDiagnostic.dictionary
        }
        try appendEvidence(record, taskID: taskID)
    }

    private func transactionEvidenceRecord(taskID: String, inferenceID: UUID, context: InferenceContext,
                                            provider: String, modelID: String, sessionToken: String?, phase: String, turnScoped: Bool?) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let policy: Bool?
        if let turnScoped { policy = turnScoped }
        else if provider == "chatgpt" { policy = nil }
        else { policy = Self.requiresNativeContinuationProof(provider: provider) }
        var record: [String: Any] = ["schemaVersion": 2, "timestamp": formatter.string(from: Date()),
            "transactionMode": policy.map { $0 ? "temporary_conversation_per_turn" : "temporary_conversation_per_inference" } ?? "capability_pending",
            "transactionVersion": policy.map { $0 ? 2 : 1 } ?? 0,
            "transactionPolicyEstablished": policy != nil,
            "taskID": taskID, "threadID": context.threadID, "turnID": context.turnID,
            "runtimeGeneration": context.runtimeGeneration.uuidString.lowercased(),
            "preparationID": context.preparationID.uuidString.lowercased(),
            "modelID": modelID, "provider": provider, "inferenceID": inferenceID.uuidString.lowercased(), "phase": phase]
        if let sessionToken { record["sessionToken"] = sessionToken.lowercased() }
        return record
    }

    private func recordEvidence(_ evidence: WebsiteModelEvidence?, snapshot: [String: Any], taskID: String,
                                inferenceID: UUID, session: Session, phase: String, cleanupAttemptID: String? = nil, errorCode: String? = nil) throws {
        var checkedSession = session
        try Self.verifyInferenceSnapshot(snapshot, session: &checkedSession)
        guard let context = snapshot["modelProofContext"] as? [String: Any] else { throw Failure.invalidRequest }
        var record = transactionEvidenceRecord(taskID: taskID, inferenceID: inferenceID, context: session.context,
            provider: session.provider, modelID: session.modelID, sessionToken: session.token, phase: phase, turnScoped: session.retainsConversation)
        for key in ["responseCount", "baselineResponseCount", "firstUserFingerprint"] {
            record[key] = context[key]
        }
        if session.provesNativeContinuation { record["submittedPromptFingerprint"] = context["submittedPromptFingerprint"] }
        if let raw = context["documentGeneration"] as? String, let generation = UUID(uuidString: raw) {
            record["documentGeneration"] = generation.uuidString.lowercased()
        }
        record["sequence"] = session.sequence
        if let cleanupAttemptID { record["cleanupAttemptID"] = cleanupAttemptID }
        if let errorCode { record["errorCode"] = errorCode }
        if let evidence { record["modelEvidence"] = evidence.dictionary }
        if session.provider == "chatgpt",
           let product = try? WebsiteProductModeEvidence.parse(snapshot["productModeEvidence"], requireTemporary: true) {
            record["productModeEvidence"] = product.dictionary
        }
        try appendEvidence(record, taskID: taskID)
    }

    private struct EvidenceJournalLocation {
        let file: URL
        let currentBytes: Int
        let allJournalBytes: Int
    }

    private func evidenceJournalLocation(taskID: String, turnID: String) throws -> EvidenceJournalLocation {
        guard let root = evidenceDirectory,
              UUID(uuidString: taskID)?.uuidString.lowercased() == taskID,
              UUID(uuidString: turnID)?.uuidString.lowercased() == turnID else { throw Failure.persistenceRequired }
        let directory = root.appendingPathComponent("transactions", isDirectory: true)
        for parent in [root, directory] {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw Failure.persistenceRequired }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }
        let tasks = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard tasks.count <= 256 else { throw Failure.persistenceRequired }
        var fileCount = 0, totalBytes = 0, currentBytes = 0
        var taskPresent = false
        let taskDirectory = directory.appendingPathComponent(taskID, isDirectory: true)
        let target = taskDirectory.appendingPathComponent(turnID + ".jsonl")
        for task in tasks {
            let attributes = try task.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard UUID(uuidString: task.lastPathComponent)?.uuidString.lowercased() == task.lastPathComponent,
                  attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw Failure.persistenceRequired }
            let files = try FileManager.default.contentsOfDirectory(at: task,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard files.count <= 1_024 else { throw Failure.persistenceRequired }
            if task.lastPathComponent == taskID {
                taskPresent = true
                guard FileManager.default.fileExists(atPath: target.path) || files.count < 1_024 else { throw Failure.persistenceRequired }
            }
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard file.pathExtension == "jsonl", UUID(uuidString: name)?.uuidString.lowercased() == name,
                      attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let size = attributes.fileSize, size <= 33_554_432 else { throw Failure.persistenceRequired }
                fileCount += 1; totalBytes += size
                if task.lastPathComponent == taskID, file.lastPathComponent == turnID + ".jsonl" { currentBytes = size }
            }
        }
        guard fileCount <= 16_384, totalBytes <= 134_217_728,
              FileManager.default.fileExists(atPath: target.path) || fileCount < 16_384 else { throw Failure.persistenceRequired }
        if !taskPresent {
            guard tasks.count < 256 else { throw Failure.persistenceRequired }
            try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        // Previous flat v1 files remain untouched. All new transaction evidence
        // is partitioned by actual native turn rather than the task lifetime.
        return EvidenceJournalLocation(file: target, currentBytes: currentBytes, allJournalBytes: totalBytes)
    }

    private func appendEvidence(_ record: [String: Any], taskID: String) throws {
        guard let turnID = record["turnID"] as? String, let inferenceID = record["inferenceID"] as? String,
              let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]),
              encoded.count <= 4_096 else { throw Failure.persistenceRequired }
        do {
            let location = try evidenceJournalLocation(taskID: taskID, turnID: turnID)
            let file = location.file
            var data = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : Data()
            guard data.count == location.currentBytes, data.count + encoded.count + 1 <= 33_554_432,
                  location.allJournalBytes + encoded.count + 1 <= 134_217_728 else { throw Failure.persistenceRequired }
            let lines = data.split(separator: 0x0A)
            guard lines.count < 6_144 else { throw Failure.persistenceRequired }
            var inferences = Set<String>()
            for line in lines {
                guard line.count <= 4_096,
                      let previous = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      previous["taskID"] as? String == taskID, previous["turnID"] as? String == turnID,
                      let id = previous["inferenceID"] as? String, UUID(uuidString: id) != nil else { throw Failure.persistenceRequired }
                inferences.insert(id)
            }
            guard inferences.contains(inferenceID) || inferences.count < 1_024 else { throw Failure.persistenceRequired }
            // No prompt, tool payload, response text, cookies or credentials
            // enter this bounded journal. Sync/readback failure blocks handoff.
            data.append(encoded); data.append(0x0A)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file)
            do { try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  attributes.fileSize == data.count, data.count <= 33_554_432,
                  try Data(contentsOf: file) == data else { throw Failure.persistenceRequired }
        } catch { throw Failure.persistenceRequired }
    }

    private static func receiptInteger(_ value: Any?, range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = value as? Int, number.doubleValue == Double(integer), range.contains(integer) else { return nil }
        return integer
    }

    private static func snapshotFailure(_ value: [String: Any], fallback: Failure = .providerFailed) -> any Error {
        // A successful bridge frame can carry a failed provider snapshot. Use
        // the same finite native reasons as ok:false replies, never page copy.
        let code = (value["error"] as? [String: Any])?["code"] as? String
        if let failure = WebsiteProviderFailure.from(errorCode: code) { return failure }
        return fallback
    }

    private func call(_ transport: any WebModelTransport, operation: String,
                      params: [String: String], submissionFailureSink: ChatSubmissionFailureDiagnosticSink? = nil) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params)
        let result: Data
        if let submissionFailureSink {
            result = try await transport.request(operation: operation, params: data,
                onChatSubmissionFailure: { submissionFailureSink.record($0) })
        } else { result = try await transport.request(operation: operation, params: data) }
        guard let value = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { throw Failure.invalidRequest }
        return value
    }

    private func accept(_ connection: NWConnection) {
        guard !shuttingDown, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        Task {
            let headerDeadline = Task {
                do { try await Task.sleep(for: .seconds(15)); connection.cancel() } catch { }
            }
            defer { headerDeadline.cancel() }
            do {
                let request = try await Self.readRequest(connection)
                headerDeadline.cancel()
                // No browser CORS, Origin, preflight, or unauthenticated endpoint.
                guard request.headers["authorization"] == "Bearer " + bearerToken else {
                    try await Self.sendError(connection, error: HTTPFailure.unauthorized)
                    close(id); return
                }
                guard request.headers["origin"] == nil,
                      let taskID = request.headers["x-computa-task-id"],
                      !taskID.isEmpty, taskID.utf8.count <= 256 else {
                    try await Self.sendError(connection, error: HTTPFailure.forbidden)
                    close(id); return
                }
                let diagnosticEpoch = failureDiagnostics.epoch(taskID: taskID)
                do {
                    guard request.method == "POST", request.path == "/v1/responses" else { throw HTTPFailure.notFound }
                    let contentType = request.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    guard contentType == "application/json" else { throw HTTPFailure.unsupportedMediaType }
                    let prepared: WebModelResponseCodec.Request
                    let identity: NativeRequestIdentity
                    do {
                        prepared = try WebModelResponseCodec.prepareRequest(request.body)
                        identity = try Self.nativeRequestIdentity(request.body, header: request.headers["x-codex-turn-metadata"])
                    } catch {
                        retireMalformedRequest(taskID: taskID)
                        throw error
                    }
                    let body = try await infer(prepared, taskID: taskID, identity: identity)
                    failureDiagnostics.clear(taskID: taskID)
                    body.responseProfile?.mark(.httpWriteStart)
                    do {
                        defer { body.responseProfile?.mark(.httpWriteEnd) }
                        try await Self.send(connection, status: "200 OK",
                            type: prepared.stream ? "text/event-stream" : "application/json", body: body.data)
                    } catch {
                        invalidateHandoff(taskID: (try? Self.canonicalID(taskID)) ?? taskID, inferenceID: body.inferenceID)
                        throw error
                    }
                } catch {
                    if !shuttingDown, Self.hasFiniteDiagnostic(error), let diagnostic = try? Self.errorBody(for: error) {
                        failureDiagnostics.record(diagnostic, taskID: taskID, epoch: diagnosticEpoch)
                    }
                    try await Self.sendError(connection, error: error)
                }
            } catch {
                if !(error is CancellationError) { try? await Self.sendError(connection, error: error) }
            }
            close(id)
        }
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    private enum HTTPFailure: LocalizedError {
        case unauthorized, forbidden, notFound, unsupportedMediaType
        var errorDescription: String? {
            switch self {
            case .unauthorized: "A valid local model authorization token is required."
            case .forbidden: "This request is not authorized for Computa's local model endpoint."
            case .notFound: "The requested model endpoint does not exist."
            case .unsupportedMediaType: "Model requests must use Content-Type: application/json."
            }
        }
    }

    struct ErrorPresentation {
        let status: String
        let type: String
        let code: String
        var param: String? = nil
    }

    static func errorPresentation(for error: any Error) -> ErrorPresentation {
        if let failure = error as? HTTPFailure {
            switch failure {
            case .unauthorized: return .init(status: "401 Unauthorized", type: "invalid_request", code: "authentication_required")
            case .forbidden: return .init(status: "403 Forbidden", type: "invalid_request", code: "access_denied")
            case .notFound: return .init(status: "404 Not Found", type: "not_found", code: "endpoint_not_found")
            case .unsupportedMediaType: return .init(status: "415 Unsupported Media Type", type: "invalid_request", code: "unsupported_media_type")
            }
        }
        if error is WebsiteTurnContinuation.Failure {
            return .init(status: "409 Conflict", type: "invalid_request", code: "website_continuation_unverified")
        }
        if let failure = error as? WebModelResponseCodec.Failure {
            switch failure {
            case .invalidParameter(let param): return .init(status: "400 Bad Request", type: "invalid_request", code: "invalid_parameter", param: param)
            case .unsupportedParameter(let param): return .init(status: "400 Bad Request", type: "invalid_request", code: "unsupported_parameter", param: param)
            case .invalidToolChoice: return .init(status: "400 Bad Request", type: "invalid_request", code: "invalid_tool_choice", param: "tool_choice")
            case .rejectedToolChoice: return .init(status: "500 Internal Server Error", type: "model_error", code: "tool_choice_violation", param: "tool_choice")
            case .parallelToolCallsUnsupported: return .init(status: "500 Internal Server Error", type: "model_error", code: "parallel_tool_calls_violation", param: "parallel_tool_calls")
            case .toolCallLimitExceeded: return .init(status: "500 Internal Server Error", type: "model_error", code: "max_tool_calls_violation", param: "max_tool_calls")
            case .missingModel: return .init(status: "400 Bad Request", type: "invalid_request", code: "missing_model", param: "model")
            case .missingInput: return .init(status: "400 Bad Request", type: "invalid_request", code: "missing_input", param: "input")
            case .previousResponseUnsupported: return .init(status: "400 Bad Request", type: "invalid_request", code: "unsupported_parameter", param: "previous_response_id")
            case .invalidTools, .unsupportedToolType: return .init(status: "400 Bad Request", type: "invalid_request", code: "unsupported_tools", param: "tools")
            case .unsupportedModality: return .init(status: "400 Bad Request", type: "invalid_request", code: "unsupported_modality", param: "input")
            case .promptTooLarge: return .init(status: "400 Bad Request", type: "invalid_request", code: "input_too_large", param: "input")
            case .invalidRequest: return .init(status: "400 Bad Request", type: "invalid_request", code: "invalid_request")
            default: return .init(status: "500 Internal Server Error", type: "model_error", code: "invalid_model_output")
            }
        }
        if let failure = error as? EmbeddedWebModelTransport.Failure {
            switch failure {
            case .humanVerificationRequired, .signInRequired:
                return .init(status: "403 Forbidden", type: "model_error", code: failure.diagnosticCode!)
            case .usageLimited:
                return .init(status: "429 Too Many Requests", type: "too_many_requests", code: failure.diagnosticCode!)
            case .capacity: return .init(status: "429 Too Many Requests", type: "too_many_requests", code: "provider_capacity")
            case .turnLimit: return .init(status: "409 Conflict", type: "invalid_request", code: "website_turn_limit")
            case .modelUnavailable: return .init(status: "404 Not Found", type: "not_found", code: "model_unavailable", param: "model")
            case .invalidRequest, .unsupportedProvider: return .init(status: "400 Bad Request", type: "invalid_request", code: "invalid_request")
            case .deadline, .preparationDeadline: return .init(status: "504 Gateway Timeout", type: "server_error", code: "provider_timeout")
            default: return .init(status: "500 Internal Server Error", type: "model_error", code: failure.diagnosticCode ?? "browser_model_error")
            }
        }
        if let failure = error as? Failure {
            switch failure {
            case .turnLimit: return .init(status: "409 Conflict", type: "invalid_request", code: "website_turn_limit")
            case .invalidRequest: return .init(status: "400 Bad Request", type: "invalid_request", code: "invalid_request")
            case .modelNotFound: return .init(status: "404 Not Found", type: "not_found", code: "model_not_found", param: "model")
            case .productModeUnverified: return .init(status: "500 Internal Server Error", type: "model_error", code: "product_mode_unverified")
            case .busy: return .init(status: "429 Too Many Requests", type: "too_many_requests", code: "provider_busy")
            case .deadline, .preparationDeadline: return .init(status: "504 Gateway Timeout", type: "server_error", code: "provider_timeout")
            case .embeddedRequired: return .init(status: "503 Service Unavailable", type: "server_error", code: "provider_unavailable")
            case .malformedReply: return .init(status: "500 Internal Server Error", type: "model_error", code: "malformed_website_reply")
            case .inferenceContextRequired: return .init(status: "409 Conflict", type: "invalid_request", code: "native_turn_mismatch")
            case .persistenceRequired: return .init(status: "503 Service Unavailable", type: "server_error", code: "inference_evidence_unsaved")
            case .startOwnershipUnconfirmed: return .init(status: "500 Internal Server Error", type: "model_error", code: "website_start_ownership_unconfirmed")
            case .requestMetadataUnavailable: return .init(status: "503 Service Unavailable", type: "server_error", code: "request_metadata_unavailable")
            default: return .init(status: "500 Internal Server Error", type: "model_error", code: "browser_model_error")
            }
        }
        if error is WebsiteProviderFailure { return .init(status: "500 Internal Server Error", type: "model_error", code: "browser_model_error") }
        return .init(status: "500 Internal Server Error", type: "server_error", code: "internal_error")
    }

    private static func sendError(_ connection: NWConnection, error: any Error) async throws {
        try await send(connection, status: errorPresentation(for: error).status,
                       type: "application/json", body: errorBody(for: error))
    }

    private static func hasFiniteDiagnostic(_ error: any Error) -> Bool {
        // Arbitrary NSError descriptions and other transport prose cannot be
        // promoted into an authoritative local model diagnostic.
        error is Failure || error is WebModelResponseCodec.Failure || error is WebsiteTurnContinuation.Failure
            || error is EmbeddedWebModelTransport.Failure || error is WebsiteProviderFailure
    }

    /// Only native finite classifications can add recovery metadata. Website
    /// copy, URLs and response prose cannot populate these protocol fields.
    static func errorBody(for error: any Error) throws -> Data {
        let presentation = errorPresentation(for: error)
        var fields: [String: Any] = ["type": presentation.type, "message": error.localizedDescription,
            "code": presentation.code, "param": presentation.param.map { $0 as Any } ?? NSNull()]
        if let failure = error as? WebsiteTurnContinuation.Failure {
            fields["reason"] = failure.rawValue
            fields["retryable"] = false
        }
        if let failure = error as? EmbeddedWebModelTransport.Failure,
           let code = failure.diagnosticCode, let action = failure.requiredAction {
            fields["code"] = code
            fields["retryable"] = false
            fields["required_action"] = action
        }
        if case let .ownershipFailure(reason) = error as? EmbeddedWebModelTransport.Failure {
            fields["ownership_reason"] = reason.rawValue
        }
        if case .productModeUnverified = error as? Failure {
            fields["retryable"] = false
            fields["required_action"] = "refresh_website_models"
        }
        if case let .malformedReply(diagnostic) = error as? Failure {
            fields["code"] = "malformed_website_reply"
            fields["retryable"] = false
            fields["reason"] = diagnostic.reason.rawValue
            fields["reply_bytes"] = diagnostic.utf8Bytes
            fields["json_fenced"] = diagnostic.fenced
        }
        return try JSONSerialization.data(withJSONObject: ["error": fields])
    }

    struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    static func parseRequest(_ buffer: Data) throws -> HTTPRequest? {
        guard buffer.count <= 2_097_152 else { throw Failure.invalidRequest }
        guard let delimiter = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 16_384 else { throw Failure.invalidRequest }
            return nil
        }
        guard delimiter.lowerBound <= 16_384,
              let head = String(data: buffer[..<delimiter.lowerBound], encoding: .utf8) else { throw Failure.invalidRequest }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].components(separatedBy: " ")
        guard start.count == 3, start[2] == "HTTP/1.1" else { throw Failure.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.invalidRequest }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw Failure.invalidRequest }
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let lengthText = headers["content-length"], let length = Int(lengthText),
              length > 0, length <= 2_000_000 else { throw Failure.invalidRequest }
        let available = buffer.count - delimiter.upperBound
        if available < length { return nil }
        guard available == length else { throw Failure.invalidRequest }
        return HTTPRequest(method: start[0], path: start[1], headers: headers,
                           body: Data(buffer[delimiter.upperBound...]))
    }

    private static func readRequest(_ connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        while true {
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: complete ? CancellationError() : Failure.invalidRequest) }
                }
            }
            buffer.append(part)
            if let request = try parseRequest(buffer) { return request }
        }
    }

    private static func send(_ connection: NWConnection, status: String, type: String, body: Data) async throws {
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

/// Every method holds the same lock; Data is immutable once recorded. Epochs
/// revoke pending writers when a turn is replaced, succeeds, or is cleaned up.
/// Recent active HTTP tasks fit well within this bound (at most eight sockets).
final class WebModelFailureDiagnosticStore: @unchecked Sendable {
    static let maximumEntries = 64
    static let maximumDiagnosticBytes = 8_192
    private struct Slot {
        var epoch = UUID()
        var diagnostic: Data?
        var order: UInt64
    }
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]
    private var order: UInt64 = 0

    func epoch(taskID: String) -> UUID {
        lock.lock(); defer { lock.unlock() }
        order &+= 1
        if var slot = slots[taskID] {
            slot.order = order
            slots[taskID] = slot
            return slot.epoch
        }
        evictIfFull()
        let slot = Slot(order: order)
        slots[taskID] = slot
        return slot.epoch
    }

    func record(_ diagnostic: Data, taskID: String, epoch: UUID) {
        guard !diagnostic.isEmpty, diagnostic.count <= Self.maximumDiagnosticBytes else { return }
        lock.lock(); defer { lock.unlock() }
        guard slots[taskID]?.epoch == epoch else { return }
        slots[taskID]?.diagnostic = diagnostic
    }

    func take(taskID: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let value = slots[taskID]?.diagnostic
        slots[taskID]?.diagnostic = nil
        return value
    }

    func clear(taskID: String) {
        lock.lock(); defer { lock.unlock() }
        guard var slot = slots[taskID] else { return }
        slot.epoch = UUID()
        slot.diagnostic = nil
        slots[taskID] = slot
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        slots.removeAll()
    }

    private func evictIfFull() {
        guard slots.count >= Self.maximumEntries,
              let oldest = slots.min(by: { $0.value.order < $1.value.order })?.key else { return }
        slots.removeValue(forKey: oldest)
    }
}

/// Explicit, one-shot local debugging only. It never creates, repairs or logs
/// an arm, replaces existing evidence, or follows a symlink. A directory is
/// provisioned by the operator with mode0700; arm.json is mode0600 and contains
/// only {"taskID":"<exact local UUID>"}. Remove a prior rejected-reply.json
/// deliberately before arming another capture. All failures are silent.
enum WebModelRejectedReplyCapture {
    static let maximumReplyBytes = 220_000
    static let maximumRecordBytes = maximumReplyBytes * 6 + 16_384
    private static let maximumArmBytes = 512

    @discardableResult
    static func capture(directory: URL, taskID: UUID, record: Data) -> Bool {
        capture(directory: directory, taskID: taskID, record: record, beforeArmClaim: nil)
    }

    #if DEBUG
    static func capture(directory: URL, taskID: UUID, record: Data,
                        beforeArmClaimForTesting: @escaping @Sendable () -> Void) -> Bool {
        capture(directory: directory, taskID: taskID, record: record, beforeArmClaim: beforeArmClaimForTesting)
    }
    #endif

    private static func capture(directory: URL, taskID: UUID, record: Data,
                                beforeArmClaim: (@Sendable () -> Void)?) -> Bool {
        guard !record.isEmpty, record.count <= maximumRecordBytes,
              let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              object["taskID"] as? String == taskID.uuidString.lowercased(),
              let reply = object["replyText"] as? String, reply.utf8.count <= maximumReplyBytes else { return false }
        let directoryFD = openDirectoryWithoutSymlinks(directory)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, privateDirectory(directoryInfo),
              flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else { return false }
        let armFD = openat(directoryFD, "arm.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard armFD >= 0 else { return false }
        defer { close(armFD) }
        var before = stat()
        guard fstat(armFD, &before) == 0, privateFile(before), before.st_size > 0,
              before.st_size <= maximumArmBytes, let arm = readArm(armFD), arm.count == before.st_size,
              let armText = String(data: arm, encoding: .utf8),
              armText.range(of: #"^\s*\{\s*"taskID"\s*:\s*"[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}"\s*\}\s*$"#, options: .regularExpression) != nil,
              let value = try? JSONSerialization.jsonObject(with: arm) as? [String: Any], Set(value.keys) == ["taskID"],
              let rawTask = value["taskID"] as? String, UUID(uuidString: rawTask) == taskID else { return false }
        var after = stat(), named = stat(), output = stat()
        guard fstat(armFD, &after) == 0, sameUnchangedFile(before, after),
              fstatat(directoryFD, "arm.json", &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(before, named),
              fstatat(directoryFD, "rejected-reply.json", &output, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return false }
        let claimed = ".claimed-arm-" + UUID().uuidString.lowercased()
        beforeArmClaim?()
        guard renameatx_np(directoryFD, "arm.json", directoryFD, claimed, UInt32(RENAME_EXCL)) == 0 else { return false }
        var claimedInfo = stat()
        // A replaced arm must never grant capture authority to its old reader.
        // Preserve a raced replacement: restore it exclusively, or leave its
        // private claimed file recoverable if another new arm already exists.
        guard fstatat(directoryFD, claimed, &claimedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              privateFile(claimedInfo), before.st_dev == claimedInfo.st_dev, before.st_ino == claimedInfo.st_ino,
              before.st_size == claimedInfo.st_size,
              before.st_mtimespec.tv_sec == claimedInfo.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == claimedInfo.st_mtimespec.tv_nsec,
              lseek(armFD, 0, SEEK_SET) == 0, readArm(armFD) == arm,
              fstat(armFD, &after) == 0, sameUnchangedFile(claimedInfo, after),
              fstatat(directoryFD, claimed, &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(after, named) else {
            _ = renameatx_np(directoryFD, claimed, directoryFD, "arm.json", UInt32(RENAME_EXCL))
            return false
        }
        let authorizedClaim = after
        defer {
            var remaining = stat()
            if fstatat(directoryFD, claimed, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               sameUnchangedFile(authorizedClaim, remaining) { _ = unlinkat(directoryFD, claimed, 0) }
        }
        let temporary = ".rejected-reply-" + UUID().uuidString.lowercased() + ".tmp"
        let outputFD = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { return false }
        defer {
            var held = stat(), remaining = stat()
            if fstat(outputFD, &held) == 0,
               fstatat(directoryFD, temporary, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               sameUnchangedFile(held, remaining) { _ = unlinkat(directoryFD, temporary, 0) }
            close(outputFD)
        }
        guard fchmod(outputFD, 0o600) == 0, writeAll(record, descriptor: outputFD), fsync(outputFD) == 0,
              directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return false }
        var written = stat(), temporaryInfo = stat()
        guard fstat(outputFD, &written) == 0, privateFile(written), written.st_size == record.count,
              fstatat(directoryFD, temporary, &temporaryInfo, AT_SYMLINK_NOFOLLOW) == 0,
              sameUnchangedFile(written, temporaryInfo),
              renameatx_np(directoryFD, temporary, directoryFD, "rejected-reply.json", UInt32(RENAME_EXCL)) == 0 else { return false }
        _ = fsync(directoryFD)
        return true
    }

    private static func openDirectoryWithoutSymlinks(_ url: URL) -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { return -1 }
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return -1 }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }

    private static func directoryStillMatches(_ directory: URL, descriptor: Int32, initial: stat) -> Bool {
        let currentFD = openDirectoryWithoutSymlinks(directory)
        guard currentFD >= 0 else { return false }
        defer { close(currentFD) }
        var current = stat(), held = stat()
        return fstat(currentFD, &current) == 0 && fstat(descriptor, &held) == 0
            && privateDirectory(current) && privateDirectory(held)
            && current.st_dev == initial.st_dev && current.st_ino == initial.st_ino
            && held.st_dev == initial.st_dev && held.st_ino == initial.st_ino
    }

    private static func privateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o700
    }

    private static func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1
            && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o600
    }

    private static func sameUnchangedFile(_ lhs: stat, _ rhs: stat) -> Bool {
        privateFile(rhs) && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func readArm(_ descriptor: Int32) -> Data? {
        var bytes = Data(count: maximumArmBytes + 1)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int? in
            var count = 0
            while count < buffer.count {
                let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if result < 0 { if errno == EINTR { continue }; return nil }
                if result == 0 { return count }
                count += result
            }
            return count
        }
        guard let count, count <= maximumArmBytes else { return nil }
        bytes.count = count
        return bytes
    }

    private static func writeAll(_ bytes: Data, descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if result < 0 { if errno == EINTR { continue }; return false }
                guard result > 0 else { return false }
                count += result
            }
            return true
        }
    }
}

private final class WebListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func complete(_ result: Result<UInt16, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

/// Explicit synthetic-only benchmark capture, separate from finite request
/// metadata/Inspector diagnostics. It never creates an arm, replays inference,
/// grants page authority or prints payload contents. Diagnostic builds can
/// separately admit one UI-requested native focus experiment after publication.
/// This same-UID operator
/// convention is not authentication against another process running as the user.
final class WebsiteBenchmarkCaptureLease: @unchecked Sendable {
    @TaskLocal static var current: WebsiteBenchmarkCaptureLease?
    static let purpose = "synthetic_latency_payload_v1"
    static let maximumPayloadBytes = 180_000
    private static let maximumArmBytes = 1_024
    private static let maximumRecordBytes = maximumPayloadBytes * 6 + 8_192

    let nonce: UUID
    private let taskID: UUID, threadID: UUID, turnID: UUID, runtimeGeneration: UUID, preparationID: UUID
    private let modelID: String, promptFingerprint: String
    private let directory: URL, directoryDevice: dev_t, directoryInode: ino_t
    private let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private var active = true
    private var attempted = false
    struct ObservationBinding: Sendable, Equatable {
        let nonce: UUID
        let rawOutboundSHA: String
        let canonicalOutboundSHA: String
        let utf8Bytes: Int
    }
    private var publishedBinding: ObservationBinding?
    var observationBinding: ObservationBinding? { lock.withLock { publishedBinding } }

    #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
    private var nativeFocusCapture: (sessionToken: String, generation: UUID)?
    private var nativeFocusBound = false
    private var nativeFocusActivated = false
    private var nativeFocusRevoked = false
    private var nativeFocusOnRevocation: (@Sendable () -> Void)?

    /// Native-only diagnostic capability. Passive observation hashes alone
    /// cannot admit focus; this requires a successfully published live capture.
    final class NativeFocusBinding: @unchecked Sendable {
        private let lease: WebsiteBenchmarkCaptureLease
        let deadline: ContinuousClock.Instant
        let nonce: UUID, generation: UUID
        let ownerToken: String
        private let view: ObjectIdentifier

        fileprivate init(lease: WebsiteBenchmarkCaptureLease, view: ObjectIdentifier,
                         ownerToken: String, generation: UUID) {
            self.lease = lease; deadline = lease.deadline; nonce = lease.nonce
            self.view = view; self.ownerToken = ownerToken; self.generation = generation
        }

        func activate(view: ObjectIdentifier, ownerToken: String, generation: UUID,
                      onRevocation: @escaping @Sendable () -> Void, action: () -> Bool) -> Bool {
            lease.lock.withLock {
                guard !Task.isCancelled, lease.active, !lease.nativeFocusRevoked,
                      !lease.nativeFocusActivated, ContinuousClock.now < deadline,
                      self.view == view, self.ownerToken == ownerToken, self.generation == generation else { return false }
                lease.nativeFocusActivated = true
                guard action() else { return false }
                lease.nativeFocusOnRevocation = onRevocation
                return true
            }
        }

        func revoke() { lease.revokeNativeFocusDiagnostic() }
    }

    func bindNativeFocusDiagnostic(view: ObjectIdentifier, ownerToken: String,
                                   generation: UUID) -> NativeFocusBinding? {
        lock.withLock {
            guard !Task.isCancelled, active, ContinuousClock.now < deadline,
                  !nativeFocusBound, !nativeFocusRevoked, publishedBinding != nil,
                  let captured = nativeFocusCapture, captured.sessionToken == ownerToken,
                  captured.generation == generation else { return nil }
            nativeFocusBound = true
            return NativeFocusBinding(lease: self, view: view, ownerToken: ownerToken, generation: generation)
        }
    }

    private func revokeNativeFocusDiagnostic() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            nativeFocusRevoked = true
            let callback = nativeFocusOnRevocation; nativeFocusOnRevocation = nil
            return callback
        }
        callback?()
    }
    #endif

    private init(nonce: UUID, taskID: UUID, threadID: UUID, turnID: UUID,
        runtimeGeneration: UUID, preparationID: UUID, modelID: String, prompt: String,
        directory: URL, directoryIdentity: stat, deadline: ContinuousClock.Instant) {
        self.nonce = nonce; self.taskID = taskID; self.threadID = threadID; self.turnID = turnID
        self.runtimeGeneration = runtimeGeneration; self.preparationID = preparationID
        self.modelID = modelID; promptFingerprint = EmbeddedWebModelTransport.promptFingerprint(prompt)
        self.directory = directory; directoryDevice = directoryIdentity.st_dev; directoryInode = directoryIdentity.st_ino
        self.deadline = deadline
    }

    func revoke() {
        lock.withLock { active = false }
        #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
        revokeNativeFocusDiagnostic()
        #endif
    }
    private var isCurrent: Bool { lock.withLock { active && ContinuousClock.now < deadline } }

    static func consume(directory: URL?, request: WebModelResponseCodec.Request,
        taskID: String, threadID: String, turnID: String, runtimeGeneration: UUID, preparationID: UUID,
        isNewThread: Bool, isMaintenance: Bool, isFirstInference: Bool, now: Date = Date()) -> WebsiteBenchmarkCaptureLease? {
        consume(directory: directory, request: request, taskID: taskID, threadID: threadID, turnID: turnID,
            runtimeGeneration: runtimeGeneration, preparationID: preparationID, isNewThread: isNewThread,
            isMaintenance: isMaintenance, isFirstInference: isFirstInference, now: now, beforeArmClaim: nil)
    }

    #if DEBUG
    static func consume(directory: URL?, request: WebModelResponseCodec.Request,
        taskID: String, threadID: String, turnID: String, runtimeGeneration: UUID, preparationID: UUID,
        isNewThread: Bool, isMaintenance: Bool, isFirstInference: Bool, now: Date,
        beforeArmClaimForTesting: @escaping @Sendable () -> Void) -> WebsiteBenchmarkCaptureLease? {
        consume(directory: directory, request: request, taskID: taskID, threadID: threadID, turnID: turnID,
            runtimeGeneration: runtimeGeneration, preparationID: preparationID, isNewThread: isNewThread,
            isMaintenance: isMaintenance, isFirstInference: isFirstInference, now: now,
            beforeArmClaim: beforeArmClaimForTesting)
    }
    #endif

    private static func consume(directory: URL?, request: WebModelResponseCodec.Request,
        taskID: String, threadID: String, turnID: String, runtimeGeneration: UUID, preparationID: UUID,
        isNewThread: Bool, isMaintenance: Bool, isFirstInference: Bool, now: Date,
        beforeArmClaim: (@Sendable () -> Void)?) -> WebsiteBenchmarkCaptureLease? {
        let started = ContinuousClock.now
        guard !Task.isCancelled, isNewThread, !isMaintenance, isFirstInference,
              let selection = WebsiteModelCatalog.inferenceSelection(for: request.model),
              selection.provider == "chatgpt", selection.choice?.key == "chat/latest/instant",
              let task = canonicalID(taskID), let thread = canonicalID(threadID), let turn = canonicalID(turnID),
              let directory else { return nil }
        let descriptor = openDirectory(directory)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0, privateDirectory(directoryInfo),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        let armFD = openat(descriptor, "arm.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard armFD >= 0 else { return nil }
        defer { close(armFD) }
        var before = stat()
        guard fstat(armFD, &before) == 0, privateFile(before), before.st_size > 0,
              before.st_size <= maximumArmBytes, let bytes = read(armFD, maximum: maximumArmBytes),
              bytes.count == before.st_size, APIModelCorrectionJSON.isUnambiguous(bytes),
              let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(fields.keys) == ["schemaVersion", "purpose", "nonce", "expiresAt"],
              ComputerToolArgumentContract.exactInt64(fields["schemaVersion"]) == 1,
              fields["purpose"] as? String == purpose,
              let nonceText = fields["nonce"] as? String, let nonce = canonicalID(nonceText),
              let expiry = fields["expiresAt"] as? String, expiry.utf8.count == 24,
              matchesSyntheticRequest(request, nonce: nonce) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        guard let expiresAt = formatter.date(from: expiry), formatter.string(from: expiresAt) == expiry else { return nil }
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds > 0, seconds <= 600 else { return nil }
        let originalDeadline = started + .seconds(seconds)
        let outputName = "payload-" + nonce.uuidString.lowercased() + ".json"
        var after = stat(), named = stat(), existing = stat()
        guard fstat(armFD, &after) == 0, same(before, after),
              fstatat(descriptor, "arm.json", &named, AT_SYMLINK_NOFOLLOW) == 0, same(before, named),
              fstatat(descriptor, outputName, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              directoryMatches(directory, descriptor: descriptor, identity: directoryInfo), !Task.isCancelled else { return nil }
        let claimed = ".claimed-benchmark-" + UUID().uuidString.lowercased()
        beforeArmClaim?()
        guard renameatx_np(descriptor, "arm.json", descriptor, claimed, UInt32(RENAME_EXCL)) == 0 else { return nil }
        var moved = stat()
        // A raced replacement is not this open arm. Restore it exclusively or
        // retain the private claimed file if a newer arm already occupies its name.
        guard fstatat(descriptor, claimed, &moved, AT_SYMLINK_NOFOLLOW) == 0, privateFile(moved),
              before.st_dev == moved.st_dev, before.st_ino == moved.st_ino, before.st_size == moved.st_size,
              before.st_mtimespec.tv_sec == moved.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == moved.st_mtimespec.tv_nsec,
              lseek(armFD, 0, SEEK_SET) == 0, read(armFD, maximum: maximumArmBytes) == bytes,
              fstat(armFD, &after) == 0, same(moved, after),
              fstatat(descriptor, claimed, &named, AT_SYMLINK_NOFOLLOW) == 0, same(after, named) else {
            _ = renameatx_np(descriptor, claimed, descriptor, "arm.json", UInt32(RENAME_EXCL)); return nil
        }
        guard unlinkat(descriptor, claimed, 0) == 0 else { return nil }
        _ = fsync(descriptor)
        guard directoryMatches(directory, descriptor: descriptor, identity: directoryInfo),
              !Task.isCancelled, ContinuousClock.now < originalDeadline else { return nil }
        return WebsiteBenchmarkCaptureLease(nonce: nonce, taskID: task, threadID: thread, turnID: turn,
            runtimeGeneration: runtimeGeneration, preparationID: preparationID, modelID: request.model, prompt: request.prompt,
            directory: directory, directoryIdentity: directoryInfo, deadline: originalDeadline)
    }

    @discardableResult
    func capture(prompt: String, outbound: String, modelID: String, sessionToken: String,
        generation: UUID, marker: String, nativeFirstFreshInstant: Bool) -> Bool {
        capture(prompt: prompt, outbound: outbound, modelID: modelID, sessionToken: sessionToken,
            generation: generation, marker: marker, nativeFirstFreshInstant: nativeFirstFreshInstant, beforePublish: nil)
    }

    #if DEBUG
    @discardableResult
    func capture(prompt: String, outbound: String, modelID: String, sessionToken: String,
        generation: UUID, marker: String, nativeFirstFreshInstant: Bool,
        beforePublishForTesting: @escaping @Sendable () -> Void) -> Bool {
        capture(prompt: prompt, outbound: outbound, modelID: modelID, sessionToken: sessionToken,
            generation: generation, marker: marker, nativeFirstFreshInstant: nativeFirstFreshInstant,
            beforePublish: beforePublishForTesting)
    }
    #endif

    private func capture(prompt: String, outbound: String, modelID: String, sessionToken: String,
        generation: UUID, marker: String, nativeFirstFreshInstant: Bool, beforePublish: (@Sendable () -> Void)?) -> Bool {
        let started = ContinuousClock.now
        guard nativeFirstFreshInstant, modelID == self.modelID, let session = UUID(uuidString: sessionToken),
              marker.count == 36, UUID(uuidString: marker) != nil,
              !outbound.isEmpty, outbound.utf8.count <= Self.maximumPayloadBytes,
              EmbeddedWebModelTransport.promptFingerprint(prompt) == promptFingerprint,
              outbound.utf8.elementsEqual((prompt + "\n\nComputa session marker: " + marker).utf8),
              lock.withLock({ () -> Bool in
                  guard active, !attempted, ContinuousClock.now < deadline, !Task.isCancelled else { return false }
                  attempted = true; return true
              }) else { return false }
        let descriptor = Self.openDirectory(directory)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0, Self.privateDirectory(directoryInfo),
              directoryInfo.st_dev == directoryDevice, directoryInfo.st_ino == directoryInode,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0, isCurrent else { return false }
        let outputName = "payload-" + nonce.uuidString.lowercased() + ".json"
        let bytes = Data(outbound.utf8)
        let rawHash = EmbeddedWebModelTransport.promptFingerprint(outbound)
        let canonicalHash = EmbeddedWebModelTransport.outboundFingerprint(outbound)
        // The immutable record cannot time its own final write. This field has
        // an explicit preparation boundary; native logs the full publication
        // span separately using only a UUID, boolean and bounded milliseconds.
        let elapsed = Self.milliseconds(.now - started)
        let record: [String: Any] = ["schemaVersion": 1, "purpose": Self.purpose,
            "nonce": nonce.uuidString.lowercased(), "stage": "before_insert", "automaticReplay": false,
            "provider": "chatgpt", "modelID": modelID,
            "taskID": taskID.uuidString.lowercased(), "threadID": threadID.uuidString.lowercased(),
            "turnID": turnID.uuidString.lowercased(), "runtimeGeneration": runtimeGeneration.uuidString.lowercased(),
            "preparationID": preparationID.uuidString.lowercased(), "sessionToken": session.uuidString.lowercased(),
            "documentGeneration": generation.uuidString.lowercased(), "marker": marker,
            "payload": outbound, "utf8Bytes": bytes.count, "utf16Count": outbound.utf16.count,
            "rawSHA256": rawHash, "canonicalSHA256": canonicalHash,
            "captureElapsedMs": elapsed, "captureElapsedBoundary": "record_preparation_before_atomic_write"]
        guard let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]),
              encoded.count <= Self.maximumRecordBytes, isCurrent else { return false }
        let temporary = ".payload-" + UUID().uuidString.lowercased() + ".tmp"
        let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return false }
        defer {
            var held = stat(), named = stat()
            if fstat(output, &held) == 0, fstatat(descriptor, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
               Self.same(held, named) { _ = unlinkat(descriptor, temporary, 0) }
            close(output)
        }
        guard fchmod(output, 0o600) == 0, Self.write(encoded, descriptor: output), fsync(output) == 0 else { return false }
        beforePublish?()
        let published = lock.withLock { () -> Bool in
            var held = stat(), named = stat()
            guard active, ContinuousClock.now < deadline, !Task.isCancelled,
                  fstat(output, &held) == 0, Self.privateFile(held), held.st_size == encoded.count,
                  fstatat(descriptor, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(held, named),
                  Self.directoryMatches(directory, descriptor: descriptor, identity: directoryInfo),
                  renameatx_np(descriptor, temporary, descriptor, outputName, UInt32(RENAME_EXCL)) == 0 else { return false }
            publishedBinding = ObservationBinding(nonce: nonce, rawOutboundSHA: rawHash,
                canonicalOutboundSHA: canonicalHash, utf8Bytes: bytes.count)
            #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
            nativeFocusCapture = (sessionToken, generation)
            #endif
            return true
        }
        guard published else { return false }
        _ = fsync(descriptor)
        return true
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(max(0, min(600_000, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)))
    }
    private static func canonicalID(_ value: String) -> UUID? {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { return nil }; return id
    }
    private static func openDirectory(_ url: URL) -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { return -1 }
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return -1 }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor); guard next >= 0 else { return -1 }; descriptor = next
        }
        return descriptor
    }
    private static func directoryMatches(_ url: URL, descriptor: Int32, identity: stat) -> Bool {
        let current = openDirectory(url); guard current >= 0 else { return false }; defer { close(current) }
        var named = stat(), held = stat()
        return fstat(current, &named) == 0 && fstat(descriptor, &held) == 0 && privateDirectory(named) && privateDirectory(held)
            && named.st_dev == identity.st_dev && named.st_ino == identity.st_ino
            && held.st_dev == identity.st_dev && held.st_ino == identity.st_ino
    }
    private static func privateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o700
    }
    private static func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1 && value.st_mode & 0o7777 == 0o600
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode
            && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func read(_ descriptor: Int32, maximum: Int) -> Data? {
        var bytes = Data(count: maximum + 1)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int? in
            var count = 0
            while count < buffer.count {
                let read = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if read < 0 { if errno == EINTR { continue }; return nil }; if read == 0 { return count }; count += read
            }
            return count
        }
        guard let count, count <= maximum else { return nil }; bytes.count = count; return bytes
    }
    private static func write(_ bytes: Data, descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }; guard count > 0 else { return false }; offset += count
            }
            return true
        }
    }
    static func matchesSyntheticRequest(_ request: WebModelResponseCodec.Request, nonce: UUID) -> Bool {
        let expectedModel = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID
        guard request.model == expectedModel,
              request.continuationRequest.count <= WebModelResponseCodec.maximumPromptBytes,
              APIModelCorrectionJSON.isUnambiguous(request.continuationRequest),
              let object = try? JSONSerialization.jsonObject(with: request.continuationRequest) as? [String: Any],
              object["model"] as? String == request.model,
              ["previous_response_id", "conversation", "conversation_id", "response_id"].allSatisfy({ object[$0] == nil || object[$0] is NSNull }),
              let input = object["input"] as? [[String: Any]], (2...34).contains(input.count) else { return false }
        // Top-level instructions are engine/native-owned and remain in the captured
        // complete payload. This helper does not reconstruct or replace them/tools.
        func parts(_ item: [String: Any], role: String) -> [String]? {
            guard Set(item.keys).isSubset(of: ["type", "role", "content", "id"]),
                  item["type"] as? String == "message", item["role"] as? String == role,
                  let content = item["content"] as? [[String: Any]], (1...32).contains(content.count) else { return nil }
            if let id = item["id"] {
                guard let value = id as? String, value.hasPrefix("msg_"), value.utf8.count <= 128,
                      value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            }
            var texts: [String] = []
            for part in content {
                guard Set(part.keys) == ["type", "text"], part["type"] as? String == "input_text",
                      let text = part["text"] as? String, !text.isEmpty else { return nil }
                texts.append(text)
            }
            return texts
        }
        let preludeCount = input.count - 2
        for item in input.prefix(preludeCount) { guard parts(item, role: "developer") != nil else { return false } }
        guard let environment = parts(input[preludeCount], role: "user"), environment.count == 1,
              matchesEnvironmentFragment(environment[0]),
              let user = parts(input[preludeCount + 1], role: "user") else { return false }
        let expected = "Computa latency benchmark \(nonce.uuidString.lowercased()). Reply with exactly HI. Do not use tools."
        let policy = ComputaAgentInstructions.runtimeInteractionPolicy()
        // The native host appends one exact policy text item; the engine can
        // join it to the user text with LF. Accept only those byte-exact forms,
        // plus the original bare synthetic form. No generic trimming/joining.
        if user.count == 1 {
            return user[0].utf8.elementsEqual(expected.utf8)
                || user[0].utf8.elementsEqual((expected + "\n" + policy).utf8)
        }
        return user.count == 2 && user[0].utf8.elementsEqual(expected.utf8)
            && user[1].utf8.elementsEqual(policy.utf8)
    }

    private static func matchesEnvironmentFragment(_ text: String) -> Bool {
        guard text.utf8.count <= 16_384, !text.contains("<!"), !text.contains("<?"), !text.contains("\0") else { return false }
        final class Environment: NSObject, XMLParserDelegate {
            struct Node { let name: String; let attributes: [String: String]; var text = ""; var children: [String: Int] = [:] }
            var stack: [Node] = [], valid = true, roots = 0, nodes = 0
            let graph: [String: Set<String>] = [
                "environment_context": ["cwd", "shell", "shell_version", "current_date", "timezone", "filesystem", "network"],
                "filesystem": ["workspace_roots", "permission_profile"], "workspace_roots": ["root"],
                "permission_profile": ["file_system"], "file_system": ["entry"], "entry": ["path", "glob", "special"],
                "network": ["allowed", "denied"]]
            func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                nodes += 1
                guard valid, nodes <= 256, stack.count < 8 else { reject(parser); return }
                if stack.isEmpty {
                    roots += 1; guard roots == 1, name == "environment_context", attributes.isEmpty else { reject(parser); return }
                } else {
                    let i = stack.count - 1
                    guard graph[stack[i].name]?.contains(name) == true else { reject(parser); return }
                    let repeated = stack[i].name == "workspace_roots" && name == "root" || stack[i].name == "file_system" && name == "entry"
                    guard repeated || stack[i].children[name] == nil else { reject(parser); return }
                    stack[i].children[name, default: 0] += 1
                }
                let allowed: Bool
                switch name {
                case "permission_profile": allowed = Set(attributes.keys) == ["type"] && ["disabled", "managed", "external"].contains(attributes["type"] ?? "")
                case "file_system":
                    allowed = Set(attributes.keys).isSubset(of: ["type", "glob_scan_max_depth"])
                        && ["unrestricted", "restricted", "external"].contains(attributes["type"] ?? "")
                        && (attributes["glob_scan_max_depth"] == nil || attributes["glob_scan_max_depth"].flatMap { Int($0) }.map { (0...1_024).contains($0) } == true)
                case "entry": allowed = Set(attributes.keys).isSubset(of: ["access", "escalatable"])
                    && ["read", "write", "deny"].contains(attributes["access"] ?? "")
                    && (attributes["escalatable"] == nil || attributes["escalatable"] == "false")
                case "network": allowed = attributes == ["enabled": "true"]
                default: allowed = attributes.isEmpty
                }
                guard allowed else { reject(parser); return }
                stack.append(Node(name: name, attributes: attributes))
            }
            func parser(_ parser: XMLParser, foundCharacters text: String) {
                guard !stack.isEmpty else { if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }; return }
                stack[stack.count - 1].text += text
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                guard let node = stack.popLast(), node.name == name else { reject(parser); return }
                let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if graph[name] != nil {
                    guard value.isEmpty else { reject(parser); return }
                    if name == "environment_context", node.children["cwd"] != 1 || node.children["shell"] != 1 { reject(parser); return }
                    if name == "filesystem", node.children["permission_profile"] != 1 { reject(parser); return }
                    if name == "permission_profile", node.children["file_system"] != 1 { reject(parser); return }
                    if name == "entry", node.children.values.reduce(0, +) != 1 { reject(parser); return }
                } else {
                    guard !value.isEmpty, value.utf8.count <= 16_384 else { reject(parser); return }
                    if ["cwd", "root", "path"].contains(name), !value.hasPrefix("/") { reject(parser); return }
                    if ["shell", "shell_version", "current_date", "timezone"].contains(name), value.utf8.count > 128 { reject(parser) }
                }
            }
            func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) { valid = false }
            func parser(_ parser: XMLParser, validationErrorOccurred validationError: any Error) { valid = false }
        }
        let delegate = Environment(), parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        return parser.parse() && delegate.valid && delegate.roots == 1 && delegate.stack.isEmpty
    }
}

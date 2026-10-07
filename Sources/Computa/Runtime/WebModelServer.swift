import Foundation
import Darwin
@preconcurrency import Network

/// Inference transport is separate from the agent loop and transcript store.
/// Another transport can replace Chrome without changing the desktop tools.
protocol WebModelTransport: Sendable {
    func request(operation: String, params: Data) async throws -> Data
    func changeRevision(sessionToken: String) async throws -> UInt64?
    func waitForChange(sessionToken: String, after revision: UInt64,
                       until deadline: ContinuousClock.Instant) async throws -> UInt64?
}

extension WebModelTransport {
    func changeRevision(sessionToken: String) async throws -> UInt64? { nil }
    func waitForChange(sessionToken: String, after revision: UInt64,
                       until deadline: ContinuousClock.Instant) async throws -> UInt64? { nil }
}

private struct ChromeWebModelTransport: WebModelTransport {
    let connection: ChromeConnectionRequest

    func request(operation: String, params: Data) async throws -> Data {
        // Revoking inference access must still allow disposal of the exact
        // session we created. Cleanup cannot submit or inspect another tab.
        let cleanup = ["webProviderFinish", "webProviderCancel"].contains(operation)
        if !cleanup { try connection.consent.check() }
        guard let admission = connection.extensionAdmission else {
            throw WebModelServer.Failure.chromeRequired
        }
        try admission.check()
        // Cancellation never tears down the shared computer-use connection.
        // Each extension operation is bounded; cancellation is checked between operations.
        let operationTask = Task {
            try await admission.link.request(operation: operation, params: params,
                                            generation: admission.generation.uuidString,
                                            consent: cleanup ? nil : connection.consent)
        }
        return try await operationTask.value
    }
}

/// An authenticated, loopback-only Responses endpoint consumed by our owned
/// App Server. The App Server keeps its normal tools, approvals and local SQLite/
/// rollout persistence; only model inference goes through the website.
actor WebModelServer {
    enum Failure: LocalizedError {
        case chromeRequired, embeddedRequired, invalidRequest, busy, providerFailed, preparationDeadline, deadline, cleanupFailed
        case modelUnverified, modelMismatch, productModeUnverified
        case modelNotFound
        case malformedReply(WebModelResponseCodec.MalformedEnvelopeDiagnostic)
        var errorDescription: String? {
            switch self {
            case .chromeRequired: "Connect the Computa Chrome extension, then sign in to the selected website in Chrome."
            case .embeddedRequired: "Open the selected website in Computa's built-in browser and sign in before using this model."
            case .invalidRequest: "The browser model request could not be validated."
            case .busy: "This browser model already has a request running."
            case .providerFailed: "The website could not produce a response. Check its sign-in, usage limit, or error message in the browser."
            case .preparationDeadline: "The website did not become ready before the 45-second preparation deadline. No prompt was sent."
            case .deadline: "The website did not finish its response before the five-minute deadline."
            case .cleanupFailed: "The web conversation cleanup could not be verified. Its local transcript has been retained."
            case .productModeUnverified: "ChatGPT normal Chat mode could not be verified. No response was accepted and no prompt was replayed. Refresh website models before retrying."
            case .modelUnverified: "The website's selected model could not be verified. No response was accepted and no prompt was replayed."
            case .modelMismatch: "The website selected or reported a different model. No response was accepted and no prompt was replayed."
            case .modelNotFound: "The requested website model is not supported. Choose a model from Computa's selector."
            case let .malformedReply(diagnostic):
                "The website returned a malformed model response envelope (\(diagnostic.reason.rawValue)). No tool calls from this reply were dispatched."
            }
        }
    }

    private enum Route: Equatable, Sendable {
        case embedded, chrome
    }

    private struct Session: Sendable {
        let token: String
        let provider: String
        let modelID: String
        let modelChoice: WebsiteModelChoice?
        let route: Route
        let transport: any WebModelTransport
    }

    private struct ActiveRequest: Sendable {
        let id: UUID
        let route: Route
        let operation: Task<Data, Error>
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
    private var transport: (any WebModelTransport)?
    private var embeddedTransport: (any WebModelTransport)?
    private var sessions: [String: Session] = [:]
    private var evidenceThreads: [String: String] = [:]
    private var active: [String: ActiveRequest] = [:]
    private var retiringTaskIDs = Set<String>()
    private var cleanupTasks: [String: Task<[String], Never>] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var shuttingDown = false
    private var readinessTimeout: Duration = .seconds(45)
    private var responseTimeout: Duration = .seconds(300)
    private var evidenceDirectory: URL?
    private let rejectedReplyDirectory: URL?
    private let queue = DispatchQueue(label: "wtf.computa.web-model-http")
    #if DEBUG
    private var beforeListenerStartForTesting: (@Sendable () async -> Void)?
    #endif

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

    func connect(_ request: ChromeConnectionRequest) async {
        _ = await disconnect()
        if request.extensionAdmission != nil { transport = ChromeWebModelTransport(connection: request) }
    }

    func configureEmbeddedTransport(_ value: any WebModelTransport) {
        embeddedTransport = value
    }

    // Also permits a deterministic transport in tests without touching Chrome.
    #if DEBUG
    func setTransportForTesting(_ value: any WebModelTransport) { transport = value }
    func setTimeoutsForTesting(readiness: Duration, response: Duration) {
        readinessTimeout = max(.milliseconds(1), min(.seconds(45), readiness))
        responseTimeout = max(.milliseconds(1), min(.seconds(300), response))
    }

    func setBeforeListenerStartForTesting(_ value: (@Sendable () async -> Void)?) {
        beforeListenerStartForTesting = value
    }
    #endif

    @discardableResult
    func disconnect() async -> [String] {
        transport = nil
        let ids = Set(sessions.filter { $0.value.route == .chrome }.keys)
            .union(active.filter { $0.value.route == .chrome }.keys)
        var issues: [String] = []
        for id in ids { issues += await cancel(taskID: id) }
        return issues
    }

    func finish(taskID: String) async -> [String] {
        failureDiagnostics.clear(taskID: taskID)
        return await cleanup(taskID: taskID, cancel: false)
    }

    func cancel(taskID: String) async -> [String] {
        failureDiagnostics.clear(taskID: taskID)
        retiringTaskIDs.insert(taskID)
        defer { retiringTaskIDs.remove(taskID) }
        let request = active[taskID]
        request?.operation.cancel()
        if let request { _ = try? await request.operation.value }
        if active[taskID]?.id == request?.id { active.removeValue(forKey: taskID) }
        return await cleanup(taskID: taskID, cancel: true)
    }

    func shutdown() async -> [String] {
        failureDiagnostics.removeAll()
        shuttingDown = true
        starting?.cancel()
        listener?.cancel(); listener = nil; baseURL = nil
        transport = nil
        embeddedTransport = nil
        let ids = Set(sessions.keys).union(active.keys)
        var issues: [String] = []
        for id in ids { issues += await cancel(taskID: id) }
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        return issues
    }

    private func cleanup(taskID: String, cancel: Bool) async -> [String] {
        if let existing = cleanupTasks[taskID] { return await existing.value }
        guard let session = sessions[taskID] else { return [] }
        let cleanup = Task { await self.performCleanup(taskID: taskID, session: session, cancel: cancel) }
        cleanupTasks[taskID] = cleanup
        let issues = await cleanup.value
        cleanupTasks.removeValue(forKey: taskID)
        return issues
    }

    private func performCleanup(taskID: String, session: Session, cancel: Bool) async -> [String] {
        do {
            let reply = try await call(session.transport,
                operation: cancel ? "webProviderCancel" : "webProviderFinish",
                params: ["sessionToken": session.token])
            guard ["deleted", "not_created"].contains(reply["cleanup"] as? String ?? "") else {
                throw Self.snapshotFailure(reply, fallback: .cleanupFailed)
            }
            if sessions[taskID]?.token == session.token { sessions.removeValue(forKey: taskID) }
            return []
        } catch {
            // Retain exact ownership for another cleanup attempt; never claim
            // that closing a tab alone deleted a saved website conversation.
            let cause = (error as? ChromeBridgeIPC.Failure)?.localizedDescription
            return [Failure.cleanupFailed.localizedDescription + (cause.map { " " + $0 } ?? "")]
        }
    }

    func infer(_ data: Data, taskID: String) async throws -> Data {
        try await infer(WebModelResponseCodec.prepareRequest(data), taskID: taskID)
    }

    private func infer(_ request: WebModelResponseCodec.Request, taskID: String) async throws -> Data {
        guard !shuttingDown, active[taskID] == nil, cleanupTasks[taskID] == nil,
              !retiringTaskIDs.contains(taskID) else { throw Failure.busy }
        guard let provider = Self.provider(for: request.model) else {
            if request.model.hasPrefix("browser/") { throw Failure.invalidRequest }
            throw Failure.modelNotFound
        }
        // All catalog website models use the app-owned browser. The Chrome
        // connection is an independent computer-tool capability.
        let route: Route = .embedded
        guard let transport = embeddedTransport else { throw Failure.embeddedRequired }
        let operation = Task { try await self.perform(request, provider: provider, route: route,
                                                     taskID: taskID, transport: transport) }
        let id = UUID()
        active[taskID] = ActiveRequest(id: id, route: route, operation: operation)
        defer { if active[taskID]?.id == id { active.removeValue(forKey: taskID) } }
        return try await operation.value
    }

    private func perform(_ request: WebModelResponseCodec.Request, provider: String,
                         route: Route, taskID: String, transport: any WebModelTransport) async throws -> Data {
        let choice = WebsiteModelCatalog.choice(for: request.model)
        let inferenceID = UUID()
        let session: Session
        if let existing = sessions[taskID],
           existing.provider != provider || existing.route != route || existing.modelID != request.model {
            // A failed earlier cleanup can leave an owned session even after
            // the UI changes provider. Retire it through its original transport
            // and token before admitting any replacement provider or choice.
            let closed = try await call(existing.transport, operation: "webProviderFinish", params: ["sessionToken": existing.token])
            guard ["deleted", "not_created"].contains(closed["cleanup"] as? String ?? "") else { throw Failure.cleanupFailed }
            try Task.checkCancellation()
            guard sessions[taskID]?.token == existing.token else { throw Failure.invalidRequest }
            sessions.removeValue(forKey: taskID)
        }
        if let existing = sessions[taskID] {
            guard existing.provider == provider, existing.route == route, existing.modelID == request.model else { throw Failure.invalidRequest }
            session = existing
        } else {
            var params = ["provider": provider]
            if let choice {
                guard let encoded = choice.canonicalJSONString else { throw Failure.invalidRequest }
                params["modelChoice"] = encoded
            }
            let reply = try await call(transport, operation: "webProviderStart", params: params)
            guard let token = reply["sessionToken"] as? String, UUID(uuidString: token) != nil,
                  ["ready", "loading"].contains(reply["state"] as? String ?? "") else { throw Self.snapshotFailure(reply) }
            session = Session(token: token, provider: provider, modelID: request.model, modelChoice: choice, route: route, transport: transport)
            sessions[taskID] = session
            if reply["state"] as? String == "ready" { _ = try Self.modelEvidence(reply, session: session) }
            let readinessDeadline = ContinuousClock.now + readinessTimeout
            var ready = reply["state"] as? String == "ready"
            while !ready, ContinuousClock.now < readinessDeadline {
                try Task.checkCancellation()
                let revision = try await transport.changeRevision(sessionToken: token)
                guard ContinuousClock.now < readinessDeadline else { throw Failure.preparationDeadline }
                let state = try await call(transport, operation: "webProviderPoll", params: ["sessionToken": token])
                guard ContinuousClock.now < readinessDeadline else { throw Failure.preparationDeadline }
                if ["ready", "running"].contains(state["state"] as? String ?? "") { _ = try Self.modelEvidence(state, session: session) }
                if state["state"] as? String == "ready" { ready = true }
                else if !["loading", "running"].contains(state["state"] as? String ?? "") { throw Self.snapshotFailure(state) }
                if !ready { try await waitForNextPoll(session, after: revision, until: readinessDeadline) }
            }
            guard ready else { throw Failure.preparationDeadline }
        }
        try Task.checkCancellation()
        let sent = try await call(session.transport, operation: "webProviderSend",
                                  params: ["sessionToken": session.token, "prompt": request.prompt])
        guard sent["state"] as? String == "running" else { throw Self.snapshotFailure(sent) }
        let submittedEvidence = try Self.modelEvidence(sent, session: session)
        recordEvidence(submittedEvidence, snapshot: sent, taskID: taskID, inferenceID: inferenceID, session: session, phase: "submission_verified")
        let end = ContinuousClock.now + responseTimeout
        while ContinuousClock.now < end {
            try Task.checkCancellation()
            let revision = try await session.transport.changeRevision(sessionToken: session.token)
            guard ContinuousClock.now < end else { throw Failure.deadline }
            let value = try await call(session.transport, operation: "webProviderPoll", params: ["sessionToken": session.token])
            guard ContinuousClock.now < end else { throw Failure.deadline }
            switch value["state"] as? String {
            case "complete":
                let evidence = try Self.modelEvidence(value, session: session)
                guard let text = value["text"] as? String, !text.isEmpty else { throw Failure.providerFailed }
                let reply: WebModelResponseCodec.Reply
                do {
                    reply = try WebModelResponseCodec.parseReply(text, request: request, requireEnvelope: session.route == .embedded)
                } catch {
                    if let diagnostic = WebModelResponseCodec.malformedEnvelopeDiagnostic(text, request: request,
                                                                                         requireEnvelope: session.route == .embedded) {
                        captureRejectedReply(text, diagnostic: diagnostic, taskID: taskID,
                                             inferenceID: inferenceID, session: session,
                                             evidence: evidence, snapshot: value)
                        throw Failure.malformedReply(diagnostic)
                    }
                    throw error
                }
                recordEvidence(evidence, snapshot: value, taskID: taskID, inferenceID: inferenceID, session: session, phase: "complete")
                return try request.stream
                    ? WebModelResponseCodec.streamData(for: reply, request: request, websiteModelEvidence: evidence)
                    : WebModelResponseCodec.completedResponse(for: reply, request: request, websiteModelEvidence: evidence)
            case "running":
                _ = try Self.modelEvidence(value, session: session)
                try await waitForNextPoll(session, after: revision, until: end)
            default: throw Self.snapshotFailure(value)
            }
        }
        throw Failure.deadline
    }

    private func waitForNextPoll(_ session: Session, after revision: UInt64?,
                                 until deadline: ContinuousClock.Instant) async throws {
        if let revision,
           try await session.transport.waitForChange(sessionToken: session.token, after: revision, until: deadline) != nil {
            return
        }
        // The Chrome extension retains its current polling contract. Embedded
        // WebKit supplies versioned notifications and never takes this fallback.
        let remaining = deadline - .now
        if remaining > .zero { try await Task.sleep(for: min(.milliseconds(500), remaining)) }
    }

    static func provider(for model: String) -> String? {
        LocalModelCatalog.webProvider(for: model)
    }

    private static func modelEvidence(_ snapshot: [String: Any], session: Session) throws -> WebsiteModelEvidence? {
        if session.route == .embedded, session.provider == "chatgpt" {
            guard (try? WebsiteProductModeEvidence.parse(snapshot["productModeEvidence"], requireTemporary: true)) != nil else {
                throw Failure.productModeUnverified
            }
        }
        guard session.modelChoice != nil || snapshot["modelEvidence"] != nil && !(snapshot["modelEvidence"] is NSNull) else { return nil }
        do { return try WebsiteModelEvidence.parse(snapshot["modelEvidence"], provider: session.provider, expected: session.modelChoice) }
        catch WebsiteModelEvidence.Failure.mismatch { throw Failure.modelMismatch }
        catch { throw Failure.modelUnverified }
    }

    private func captureRejectedReply(_ text: String, diagnostic: WebModelResponseCodec.MalformedEnvelopeDiagnostic,
                                      taskID: String, inferenceID: UUID, session: Session,
                                      evidence: WebsiteModelEvidence?, snapshot: [String: Any]) {
        guard let directory = rejectedReplyDirectory, let task = UUID(uuidString: taskID),
              let token = UUID(uuidString: session.token),
              text.utf8.count <= WebModelRejectedReplyCapture.maximumReplyBytes,
              diagnostic.utf8Bytes == text.utf8.count, session.modelID.utf8.count <= 2_048,
              ["chatgpt", "claude", "gemini"].contains(session.provider) else { return }
        var record: [String: Any] = ["schemaVersion": 1, "timestamp": ISO8601DateFormatter().string(from: Date()),
                                    "taskID": task.uuidString.lowercased(), "inferenceID": inferenceID.uuidString.lowercased(),
                                    "sessionToken": token.uuidString.lowercased(), "provider": session.provider,
                                    "modelID": session.modelID, "replyText": text,
                                    "diagnostic": ["reason": diagnostic.reason.rawValue, "utf8Bytes": diagnostic.utf8Bytes,
                                                   "fenced": diagnostic.fenced], "automaticReplay": false]
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

    private func recordEvidence(_ evidence: WebsiteModelEvidence?, snapshot: [String: Any], taskID: String,
                                inferenceID: UUID, session: Session, phase: String) {
        guard let evidence, let directory = evidenceDirectory,
              let task = UUID(uuidString: taskID), let context = snapshot["modelProofContext"] as? [String: Any],
              let generation = context["documentGeneration"] as? String, UUID(uuidString: generation) != nil,
              let sequence = Self.receiptInteger(snapshot["sequence"], range: 1...10_000),
              let responseCount = Self.receiptInteger(context["responseCount"], range: 0...10_000),
              let baseline = Self.receiptInteger(context["baselineResponseCount"], range: 0...10_000),
              responseCount >= baseline else { return }
        let fingerprint = context["firstUserFingerprint"] as? String
        if let fingerprint, !fingerprint.isEmpty {
            guard fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return }
        } else if context["firstUserFingerprint"] != nil && fingerprint == nil { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record: [String: Any] = ["schemaVersion": 1, "timestamp": formatter.string(from: Date()),
                                    "taskID": task.uuidString.lowercased(), "modelID": session.modelID, "provider": session.provider,
                                    "inferenceID": inferenceID.uuidString.lowercased(), "phase": phase, "sessionToken": session.token,
                                    "sequence": sequence, "documentGeneration": generation,
                                    "responseCount": responseCount, "baselineResponseCount": baseline,
                                    "modelEvidence": evidence.dictionary]
        if session.provider == "chatgpt", session.route == .embedded,
           let product = try? WebsiteProductModeEvidence.parse(snapshot["productModeEvidence"], requireTemporary: true) {
            record["productModeEvidence"] = product.dictionary
        }
        if let threadID = evidenceThreads[task.uuidString.lowercased()] { record["threadID"] = threadID }
        if let fingerprint, !fingerprint.isEmpty { record["firstUserFingerprint"] = fingerprint }
        guard let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]), encoded.count <= 4_096 else { return }
        // Model identity receipts contain no prompt, tool payload, response
        // text, cookies or credentials. They are private and bounded.
        let file = directory.appendingPathComponent(task.uuidString.lowercased() + ".jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 1_048_576 else { return }
            if size == 0 {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                guard files.count < 256 else { return }
            }
            var data = (try? Data(contentsOf: file)) ?? Data()
            guard data.count + encoded.count + 1 <= 1_048_576 else { return }
            data.append(encoded); data.append(0x0A)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { }
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
        if let failure = ChromeBridgeIPC.Failure.websiteOperationFailure(errorCode: code) { return failure }
        return fallback
    }

    private func call(_ transport: any WebModelTransport, operation: String,
                      params: [String: String]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params)
        let result = try await transport.request(operation: operation, params: data)
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
                    let prepared = try WebModelResponseCodec.prepareRequest(request.body)
                    let body = try await infer(prepared, taskID: taskID)
                    failureDiagnostics.clear(taskID: taskID)
                    try await Self.send(connection, status: "200 OK",
                        type: prepared.stream ? "text/event-stream" : "application/json", body: body)
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
            case .modelUnavailable: return .init(status: "404 Not Found", type: "not_found", code: "model_unavailable", param: "model")
            case .invalidRequest, .unsupportedProvider: return .init(status: "400 Bad Request", type: "invalid_request", code: "invalid_request")
            case .deadline, .preparationDeadline: return .init(status: "504 Gateway Timeout", type: "server_error", code: "provider_timeout")
            default: return .init(status: "500 Internal Server Error", type: "model_error", code: failure.diagnosticCode ?? "browser_model_error")
            }
        }
        if let failure = error as? Failure {
            switch failure {
            case .invalidRequest: return .init(status: "400 Bad Request", type: "invalid_request", code: "invalid_request")
            case .modelNotFound: return .init(status: "404 Not Found", type: "not_found", code: "model_not_found", param: "model")
            case .productModeUnverified: return .init(status: "500 Internal Server Error", type: "model_error", code: "product_mode_unverified")
            case .busy: return .init(status: "429 Too Many Requests", type: "too_many_requests", code: "provider_busy")
            case .deadline, .preparationDeadline: return .init(status: "504 Gateway Timeout", type: "server_error", code: "provider_timeout")
            case .chromeRequired, .embeddedRequired: return .init(status: "503 Service Unavailable", type: "server_error", code: "provider_unavailable")
            case .malformedReply: return .init(status: "500 Internal Server Error", type: "model_error", code: "malformed_website_reply")
            default: return .init(status: "500 Internal Server Error", type: "model_error", code: "browser_model_error")
            }
        }
        if error is ChromeBridgeIPC.Failure { return .init(status: "500 Internal Server Error", type: "model_error", code: "browser_model_error") }
        return .init(status: "500 Internal Server Error", type: "server_error", code: "internal_error")
    }

    private static func sendError(_ connection: NWConnection, error: any Error) async throws {
        try await send(connection, status: errorPresentation(for: error).status,
                       type: "application/json", body: errorBody(for: error))
    }

    private static func hasFiniteDiagnostic(_ error: any Error) -> Bool {
        // Arbitrary NSError descriptions and other transport prose cannot be
        // promoted into an authoritative local model diagnostic.
        error is Failure || error is WebModelResponseCodec.Failure
            || error is EmbeddedWebModelTransport.Failure || error is ChromeBridgeIPC.Failure
    }

    /// Only native finite classifications can add recovery metadata. Website
    /// copy, URLs and response prose cannot populate these protocol fields.
    static func errorBody(for error: any Error) throws -> Data {
        let presentation = errorPresentation(for: error)
        var fields: [String: Any] = ["type": presentation.type, "message": error.localizedDescription,
            "code": presentation.code, "param": presentation.param.map { $0 as Any } ?? NSNull()]
        if let failure = error as? EmbeddedWebModelTransport.Failure,
           let code = failure.diagnosticCode, let action = failure.requiredAction {
            fields["code"] = code
            fields["retryable"] = false
            fields["required_action"] = action
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

import Foundation
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
        case modelUnverified, modelMismatch
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
            case .modelUnverified: "The website's selected model could not be verified. No response was accepted and no prompt was replayed."
            case .modelMismatch: "The website selected or reported a different model. No response was accepted and no prompt was replayed."
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
    private let queue = DispatchQueue(label: "wtf.computa.web-model-http")
    #if DEBUG
    private var beforeListenerStartForTesting: (@Sendable () async -> Void)?
    #endif

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
        await cleanup(taskID: taskID, cancel: false)
    }

    func cancel(taskID: String) async -> [String] {
        retiringTaskIDs.insert(taskID)
        defer { retiringTaskIDs.remove(taskID) }
        let request = active[taskID]
        request?.operation.cancel()
        if let request { _ = try? await request.operation.value }
        if active[taskID]?.id == request?.id { active.removeValue(forKey: taskID) }
        return await cleanup(taskID: taskID, cancel: true)
    }

    func shutdown() async -> [String] {
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
        guard !shuttingDown, active[taskID] == nil, cleanupTasks[taskID] == nil,
              !retiringTaskIDs.contains(taskID) else { throw Failure.busy }
        let request = try WebModelResponseCodec.prepareRequest(data)
        guard let provider = Self.provider(for: request.model) else { throw Failure.invalidRequest }
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
                let reply = try WebModelResponseCodec.parseReply(text, request: request, requireEnvelope: session.route == .embedded)
                recordEvidence(evidence, snapshot: value, taskID: taskID, inferenceID: inferenceID, session: session, phase: "complete")
                return try WebModelResponseCodec.streamData(for: reply, request: request, websiteModelEvidence: evidence)
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
        guard session.modelChoice != nil || snapshot["modelEvidence"] != nil && !(snapshot["modelEvidence"] is NSNull) else { return nil }
        do { return try WebsiteModelEvidence.parse(snapshot["modelEvidence"], provider: session.provider, expected: session.modelChoice) }
        catch WebsiteModelEvidence.Failure.mismatch { throw Failure.modelMismatch }
        catch { throw Failure.modelUnverified }
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
                guard request.method == "POST", request.path == "/v1/responses",
                      request.headers["origin"] == nil,
                      request.headers["authorization"] == "Bearer " + bearerToken,
                      let taskID = request.headers["x-computa-task-id"],
                      !taskID.isEmpty, taskID.utf8.count <= 256 else {
                    try await Self.send(connection, status: "403 Forbidden", type: "application/json", body: Data("{\"error\":{\"message\":\"Unauthorized browser model request\"}}".utf8))
                    close(id); return
                }
                do {
                    let stream = try await infer(request.body, taskID: taskID)
                    try await Self.send(connection, status: "200 OK", type: "text/event-stream", body: stream)
                } catch {
                    let body = try Self.errorBody(for: error)
                    try await Self.send(connection, status: "400 Bad Request", type: "application/json", body: body)
                }
            } catch { }
            close(id)
        }
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    /// Only native finite classifications can add recovery metadata. Website
    /// copy, URLs and response prose cannot populate these protocol fields.
    static func errorBody(for error: any Error) throws -> Data {
        var fields: [String: Any] = ["type": "browser_model_error", "message": error.localizedDescription]
        if let failure = error as? EmbeddedWebModelTransport.Failure,
           let code = failure.diagnosticCode, let action = failure.requiredAction {
            fields["code"] = code
            fields["retryable"] = false
            fields["required_action"] = action
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

private final class WebListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func complete(_ result: Result<UInt16, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

import Foundation
@preconcurrency import Network

/// Inference transport is separate from the agent loop and transcript store.
/// Another transport can replace Chrome without changing the desktop tools.
protocol WebModelTransport: Sendable {
    func request(operation: String, params: Data) async throws -> Data
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
        case chromeRequired, invalidRequest, busy, providerFailed, deadline, cleanupFailed
        var errorDescription: String? {
            switch self {
            case .chromeRequired: "Connect the Computa Chrome extension, then sign in to the selected website in Chrome."
            case .invalidRequest: "The browser model request could not be validated."
            case .busy: "This browser model already has a request running."
            case .providerFailed: "The website could not produce a response. Check its sign-in, usage limit, or error message in Chrome."
            case .deadline: "The website did not finish its response before the five-minute deadline."
            case .cleanupFailed: "The web conversation cleanup could not be verified. Its local transcript has been retained."
            }
        }
    }

    struct Session: Sendable {
        let token: String
        let provider: String
        let transport: any WebModelTransport
    }

    nonisolated let bearerToken = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var baseURL: URL?
    private var starting: Task<URL, Error>?
    private var transport: (any WebModelTransport)?
    private var sessions: [String: Session] = [:]
    private var active: [String: Task<Data, Error>] = [:]
    private var cleanupTasks: [String: Task<[String], Never>] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var shuttingDown = false
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

    // Also permits a deterministic transport in tests without touching Chrome.
    #if DEBUG
    func setTransportForTesting(_ value: any WebModelTransport) { transport = value }
    func setBeforeListenerStartForTesting(_ value: (@Sendable () async -> Void)?) {
        beforeListenerStartForTesting = value
    }
    #endif

    @discardableResult
    func disconnect() async -> [String] {
        transport = nil
        let ids = Set(sessions.keys).union(active.keys)
        var issues: [String] = []
        for id in ids { issues += await cancel(taskID: id) }
        return issues
    }

    func finish(taskID: String) async -> [String] {
        await cleanup(taskID: taskID, cancel: false)
    }

    func cancel(taskID: String) async -> [String] {
        active[taskID]?.cancel()
        if let task = active[taskID] { _ = try? await task.value }
        active.removeValue(forKey: taskID)
        return await cleanup(taskID: taskID, cancel: true)
    }

    func shutdown() async -> [String] {
        shuttingDown = true
        starting?.cancel()
        listener?.cancel(); listener = nil; baseURL = nil
        let issues = await disconnect()
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
                throw Failure.cleanupFailed
            }
            if sessions[taskID]?.token == session.token { sessions.removeValue(forKey: taskID) }
            return []
        } catch {
            // Retain exact ownership for another cleanup attempt; never claim
            // that closing a tab alone deleted a saved website conversation.
            return [Failure.cleanupFailed.localizedDescription]
        }
    }

    func infer(_ data: Data, taskID: String) async throws -> Data {
        guard !shuttingDown, active[taskID] == nil, cleanupTasks[taskID] == nil else { throw Failure.busy }
        let request = try WebModelResponseCodec.prepareRequest(data)
        guard let provider = Self.provider(for: request.model), let transport else { throw Failure.chromeRequired }
        let operation = Task { try await self.perform(request, provider: provider, taskID: taskID, transport: transport) }
        active[taskID] = operation
        defer { active.removeValue(forKey: taskID) }
        return try await operation.value
    }

    private func perform(_ request: WebModelResponseCodec.Request, provider: String,
                         taskID: String, transport: any WebModelTransport) async throws -> Data {
        let session: Session
        if let existing = sessions[taskID] {
            guard existing.provider == provider else { throw Failure.invalidRequest }
            session = existing
        } else {
            let reply = try await call(transport, operation: "webProviderStart", params: ["provider": provider])
            guard let token = reply["sessionToken"] as? String, UUID(uuidString: token) != nil,
                  ["ready", "loading"].contains(reply["state"] as? String ?? "") else { throw Failure.providerFailed }
            session = Session(token: token, provider: provider, transport: transport)
            sessions[taskID] = session
            let readinessDeadline = ContinuousClock.now + .seconds(45)
            var ready = reply["state"] as? String == "ready"
            while !ready, ContinuousClock.now < readinessDeadline {
                try Task.checkCancellation()
                let state = try await call(transport, operation: "webProviderPoll", params: ["sessionToken": token])
                if state["state"] as? String == "ready" { ready = true }
                else if !["loading", "running"].contains(state["state"] as? String ?? "") { throw Failure.providerFailed }
                if !ready { try await Task.sleep(for: .milliseconds(500)) }
            }
            guard ready else { throw Failure.deadline }
        }
        try Task.checkCancellation()
        let sent = try await call(session.transport, operation: "webProviderSend",
                                  params: ["sessionToken": session.token, "prompt": request.prompt])
        guard sent["state"] as? String == "running" else { throw Failure.providerFailed }
        let end = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < end {
            try Task.checkCancellation()
            let value = try await call(session.transport, operation: "webProviderPoll", params: ["sessionToken": session.token])
            switch value["state"] as? String {
            case "complete":
                guard let text = value["text"] as? String, !text.isEmpty else { throw Failure.providerFailed }
                let reply = try WebModelResponseCodec.parseReply(text, request: request)
                return try WebModelResponseCodec.streamData(for: reply, request: request)
            case "running": try await Task.sleep(for: .milliseconds(500))
            default: throw Failure.providerFailed
            }
        }
        throw Failure.deadline
    }

    static func provider(for model: String) -> String? {
        LocalModelCatalog.webProvider(for: model)
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
                    let body = try JSONSerialization.data(withJSONObject: ["error": ["type": "browser_model_error", "message": error.localizedDescription]])
                    try await Self.send(connection, status: "400 Bad Request", type: "application/json", body: body)
                }
            } catch { }
            close(id)
        }
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

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

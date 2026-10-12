import Foundation
import Network

/// The engine speaks Responses on loopback; only this actor handles provider credentials.
/// It never runs tools, changes permissions, or replays a failed inference.
actor APIModelServer {
    enum Failure: String, Error, LocalizedError, Sendable {
        case invalidRequest, unauthorized, modelUnavailable, busy, cancelled, stopped, credentialUnavailable, inferenceContextRequired
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
            }
        }
    }
    nonisolated let bearerToken = UUID().uuidString + UUID().uuidString
    private let credentials: any APIProviderCredentials
    private let client: APIProviderHTTPClient
    private let suppliedCapsules: APIReasoningCapsules?
    private var capsules: APIReasoningCapsules?
    private var providers: [APIProviderDefinition] = []
    private var listener: NWListener?
    private var baseURL: URL?
    private var starting: Task<URL, Error>?
    private var stopped = false
    private let queue = DispatchQueue(label: "com.ahmedelamin.Computa.api-model-http")
    private struct Connection { let socket: NWConnection; let task: Task<Void, Never> }
    private var connections: [UUID: Connection] = [:]
    private struct Lane { let id: UUID; let request: Task<APIModelResponseCodec.Reply, Error> }
    private var lanes: [String: Lane] = [:]
    private struct Prepared: Equatable { let threadID: String; let preparationID: UUID }
    private struct Identity: Equatable, Sendable { let threadID: String; let turnID: String }
    private struct Context: Equatable { let identity: Identity; let preparationID: UUID }
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Context, Error> }
    private var prepared: [String: Prepared] = [:]
    private var contexts: [String: Context] = [:]
    private var waiters: [String: Waiter] = [:]
    private var admissions: [String: UUID] = [:]
    private var retiring = Set<String>()
    private var retirementWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(credentials: any APIProviderCredentials = APIProviderCredentialStore(),
         client: APIProviderHTTPClient = APIProviderHTTPClient(), capsules: APIReasoningCapsules? = nil) {
        self.credentials = credentials; self.client = client; suppliedCapsules = capsules
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
    func prepareInferenceTurn(taskID: String, threadID: String, preparationID: UUID) throws {
        let task = try Self.canonicalID(taskID), thread = try Self.canonicalID(threadID)
        guard !stopped, !retiring.contains(task), lanes[task] == nil, admissions[task] == nil else { throw Failure.busy }
        let value = Prepared(threadID: thread, preparationID: preparationID)
        if prepared[task] == value { return }
        guard prepared[task] == nil, contexts[task] == nil else { throw Failure.inferenceContextRequired }
        prepared[task] = value
    }
    func registerInferenceTurn(taskID: String, threadID: String, turnID: String, preparationID: UUID) throws {
        let task = try Self.canonicalID(taskID)
        let identity = Identity(threadID: try Self.canonicalID(threadID), turnID: try Self.canonicalID(turnID))
        let value = Context(identity: identity, preparationID: preparationID)
        if contexts[task] == value { return }
        guard !stopped, !retiring.contains(task), contexts[task] == nil,
              prepared[task] == Prepared(threadID: identity.threadID, preparationID: preparationID) else { throw Failure.inferenceContextRequired }
        contexts[task] = value
        waiters.removeValue(forKey: task)?.continuation.resume(returning: value)
    }
    func finish(taskID: String) async { await cancel(taskID: taskID) }
    func cancel(taskID: String) async {
        guard let task = try? Self.canonicalID(taskID) else { return }
        retiring.insert(task)
        prepared.removeValue(forKey: task); contexts.removeValue(forKey: task)
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
        prepared.removeAll(); contexts.removeAll()
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
            let key: String
            do { guard let value = try credentials.key(for: selection.provider.id) else { throw APIProviderHTTPClient.Failure.missingCredential }; key = value }
            catch let failure as APIProviderHTTPClient.Failure { throw failure }
            catch { throw Failure.credentialUnavailable }
            if capsules == nil { capsules = try suppliedCapsules ?? APIReasoningCapsules.persistent() }
            guard let capsules else { throw Failure.credentialUnavailable }
            let prepared = try APIModelResponseCodec.prepare(request.body, selection: selection, threadID: context.identity.threadID, capsules: capsules)
            let client = self.client
            let requestTask = Task {
                let result = try await client.request(provider: prepared.provider, key: key, path: prepared.path, body: prepared.body)
                try Task.checkCancellation()
                return try APIModelResponseCodec.decode(result, request: prepared)
            }
            let lane = Lane(id: UUID(), request: requestTask); lanes[taskID] = lane
            defer { if lanes[taskID]?.id == lane.id { lanes.removeValue(forKey: taskID) } }
            let reply = try await withTaskCancellationHandler { try await requestTask.value } onCancel: { requestTask.cancel() }
            try Task.checkCancellation()
            guard !stopped, contexts[taskID] == context, lanes[taskID]?.id == lane.id else { throw Failure.cancelled }
            try await Self.send(connection, status: "200 OK", type: prepared.stream ? "text/event-stream" : "application/json",
                                body: APIModelResponseCodec.encode(reply, stream: prepared.stream))
        } catch {
            deadline.cancel()
            try? await Self.send(connection, status: Self.errorStatus(error), type: "application/json", body: Self.errorBody(error))
        }
    }
    static func errorStatus(_ error: any Error) -> String {
        if error as? Failure == .unauthorized || error as? APIProviderHTTPClient.Failure == .unauthorized || error as? APIProviderHTTPClient.Failure == .missingCredential { return "401 Unauthorized" }
        if error as? APIProviderHTTPClient.Failure == .rateLimited { return "429 Too Many Requests" }
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
    static func errorBody(_ error: any Error) throws -> Data {
        let code: String, message: String
        if let value = error as? Failure { code = finiteCode(value.rawValue); message = value.localizedDescription }
        else if let value = error as? APIModelResponseCodec.Failure { code = finiteCode(value.rawValue); message = value.localizedDescription }
        else if let value = error as? APIProviderHTTPClient.Failure { code = finiteCode(value.rawValue); message = value.localizedDescription }
        else if error is CancellationError { code = Failure.cancelled.rawValue; message = Failure.cancelled.localizedDescription }
        else { code = APIProviderHTTPClient.Failure.unavailable.rawValue; message = APIProviderHTTPClient.Failure.unavailable.localizedDescription }
        return try JSONSerialization.data(withJSONObject: ["error": ["type": "api_model_error", "code": code, "message": message, "x-computa-retryable": false]])
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

private final class APIListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume(with: result)
    }
}

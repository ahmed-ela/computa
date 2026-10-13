import Foundation
import Network
import Darwin
import CoreFoundation

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
    private struct Prepared: Equatable { let threadID: String; let preparationID: UUID; let isNewThread: Bool }
    private struct Identity: Equatable, Sendable { let threadID: String; let turnID: String }
    private struct Context: Equatable { let identity: Identity; let preparationID: UUID; let isNewThread: Bool }
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Context, Error> }
    private var prepared: [String: Prepared] = [:]
    private var contexts: [String: Context] = [:]
    private var waiters: [String: Waiter] = [:]
    private var admissions: [String: UUID] = [:]
    private var retiring = Set<String>()
    private var retirementWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(credentials: any APIProviderCredentials = APIProviderCredentialStore(),
         client: APIProviderHTTPClient = APIProviderHTTPClient(), capsules: APIReasoningCapsules? = nil,
         rejectionDiagnosticsDirectory: URL? = nil, toolNamingDirectory: URL? = nil) {
        self.credentials = credentials; self.client = client; suppliedCapsules = capsules
        self.rejectionDiagnosticsDirectory = rejectionDiagnosticsDirectory
        self.toolNamingDirectory = toolNamingDirectory
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
            if capsules == nil { capsules = try suppliedCapsules ?? APIReasoningCapsules.persistent() }
            guard let capsules else { throw Failure.credentialUnavailable }
            try Task.checkCancellation()
            guard !stopped, !retiring.contains(taskID), contexts[taskID] == context,
                  admissions[taskID] == admissionID else { throw Failure.inferenceContextRequired }
            let proposedNaming: APIModelResponseCodec.ToolNaming = context.isNewThread && Self.hasOnlyUnmodeledInput(object) ? .semantic : .legacy
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
            let client = self.client
            let capture = APIRejectedRequestCapture.consume(directory: rejectionDiagnosticsDirectory, taskID: UUID(uuidString: taskID)!,
                threadID: UUID(uuidString: context.identity.threadID)!, turnID: UUID(uuidString: context.identity.turnID)!)
            let onRejection: (@Sendable (APIProviderHTTPClient.RejectionDiagnostic) -> Void)?
            if let capture { onRejection = { diagnostic in capture.capture(diagnostic) } }
            else { onRejection = nil }
            let requestTask = Task<APIModelResponseCodec.Reply, Error> {
                let result = try await client.request(provider: prepared.provider, key: key, path: prepared.path, body: prepared.body,
                    modelID: prepared.model.id, onRejection: onRejection)
                try Task.checkCancellation()
                return try APIModelResponseCodec.decode(result, request: prepared)
            }
            let lane = Lane(id: UUID(), request: requestTask); lanes[taskID] = lane
            defer { if lanes[taskID]?.id == lane.id { lanes.removeValue(forKey: taskID) } }
            let reply: APIModelResponseCodec.Reply
            do {
                reply = try await withTaskCancellationHandler { try await requestTask.value } onCancel: { requestTask.cancel() }
            } catch let failure as APIProviderHTTPClient.Failure
                where prepared.stream && [.rateLimited, .providerBusy].contains(failure) {
                try Task.checkCancellation()
                guard !stopped, contexts[taskID] == context, lanes[taskID]?.id == lane.id else { throw Failure.cancelled }
                // The native client's HTTP-429 bridge drops the provider cause.
                // Standard Responses failure events preserve it without replay,
                // while non-streaming callers retain the HTTP status below.
                try await Self.send(connection, status: "200 OK", type: "text/event-stream",
                    body: APIModelResponseCodec.encodeRateLimitFailure(request: prepared, failure: failure))
                return
            }
            try Task.checkCancellation()
            guard !stopped, contexts[taskID] == context, lanes[taskID]?.id == lane.id else { throw Failure.cancelled }
            try await Self.send(connection, status: "200 OK", type: prepared.stream ? "text/event-stream" : "application/json",
                                body: APIModelResponseCodec.encode(reply, stream: prepared.stream))
        } catch {
            deadline.cancel()
            try? await Self.send(connection, status: Self.errorStatus(error), type: "application/json", body: Self.errorBody(error))
        }
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

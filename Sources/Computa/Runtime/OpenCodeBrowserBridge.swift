import Foundation
import Network

/// One authenticated streamable-HTTP MCP endpoint for one OpenCode process and turn.
/// Only the ACP session setup receives the credential. Discovery needs no endpoint.
actor OpenCodeBrowserBridge {
    typealias Call = @Sendable (_ tool: String, _ arguments: Data) async throws -> [String]
    private let call: Call
    private let queue = DispatchQueue(label: "Computa.OpenCodeBrowser")
    private let credential = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var port: UInt16?
    private var closed = false
    private var initialized = false
    private var sockets: [UUID: NWConnection] = [:]
    private var inFlight: (id: Data, operation: Task<[String], Error>)?
    private var dispatched = Set<Data>()

    init(call: @escaping Call) { self.call = call }

    struct Endpoint: Sendable {
        let port: UInt16
        let credential: String
        var url: URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }
        var descriptor: [String: Any] {
            ["type": "http", "name": "computa", "url": url.absoluteString,
             "headers": [["name": "Authorization", "value": "Bearer " + credential]]]
        }
    }

    func start() async throws -> Endpoint {
        guard !closed, listener == nil else { throw AgentCLIError.cancelled }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] socket in
            Task { guard let self else { socket.cancel(); return }; await self.accept(socket) }
        }
        let port = try await LoopbackHTTP.start(server, queue: queue)
        guard !closed else { throw AgentCLIError.cancelled }
        self.port = port
        return Endpoint(port: port, credential: credential)
    }

    func close() {
        closed = true
        listener?.cancel()
        inFlight?.operation.cancel()
        for socket in sockets.values { socket.cancel() }
    }

    private func accept(_ socket: NWConnection) async {
        guard !closed, sockets.count < 8 else { socket.cancel(); return }
        let id = UUID()
        sockets[id] = socket
        socket.start(queue: queue)
        defer { socket.cancel(); sockets.removeValue(forKey: id) }
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            socket.cancel()
        }
        defer { deadline.cancel() }
        do {
            let request = try await LoopbackHTTP.readRequest(socket)
            deadline.cancel()
            let (status, body) = try await handle(request)
            try await LoopbackHTTP.send(socket, status: status, type: "application/json", body: body)
        } catch {
            try? await LoopbackHTTP.send(socket, status: "400 Bad Request", type: "application/json", body: Data())
        }
    }

    private func handle(_ request: LoopbackHTTP.HTTPRequest) async throws -> (String, Data) {
        guard !closed, let port, request.headers["origin"] == nil,
              request.headers["host"] == "127.0.0.1:\(port)" else { return ("403 Forbidden", Data()) }
        guard request.headers["authorization"] == "Bearer " + credential else { return ("401 Unauthorized", Data()) }
        guard request.path == "/mcp" else { return ("404 Not Found", Data()) }
        guard request.method == "POST" else { return ("405 Method Not Allowed", Data()) }
        guard request.headers["content-type"]?.lowercased().components(separatedBy: ";").first == "application/json",
              let message = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return ("400 Bad Request", Data())
        }
        let params = message["params"] as? [String: Any] ?? [:]
        func identity(_ value: Any?) -> Data? {
            guard let value, value is String || value is Int,
                  CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                  data.count <= 128 else { return nil }
            return data
        }
        guard let id = message["id"] else {
            if method == "notifications/cancelled", let key = identity(params["requestId"]), key == inFlight?.id {
                inFlight?.operation.cancel()
            }
            return ("202 Accepted", Data())
        }
        guard let key = identity(id) else { return ("400 Bad Request", Data()) }
        func reply(_ value: Any, error: Bool = false) throws -> (String, Data) {
            ("200 OK", try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, error ? "error" : "result": value]))
        }
        switch method {
        case "initialize":
            let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
            let requested = params["protocolVersion"] as? String ?? ""
            initialized = true
            return try reply(["protocolVersion": versions.contains(requested) ? requested : versions[0],
                "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "Computa browser", "version": "1.0.0"],
                "instructions": "These tools control Computa's built-in browser. Open or bind a tab, read its current controls, and act using its returned references."])
        case "ping":
            return try reply([String: Any]())
        case "tools/list" where initialized:
            let catalog = EmbeddedBrowserTools.definitions().map { $0.filter { $0.key != "type" } }
            return try reply(["tools": catalog])
        case "tools/call" where initialized:
            guard let tool = params["name"] as? String, EmbeddedBrowserTools.names.contains(tool),
                  let args = (params["arguments"] ?? [String: Any]()) as? [String: Any] else {
                return try reply(["code": -32602, "message": "Invalid browser tool or arguments."], error: true)
            }
            guard inFlight == nil, dispatched.count < 4096, dispatched.insert(key).inserted else {
                return try reply(["code": -32600, "message": "Duplicate, concurrent or over-limit browser operation."], error: true)
            }
            let input = try JSONSerialization.data(withJSONObject: args, options: .sortedKeys)
            let operation = Task { try await call(tool, input) }
            inFlight = (key, operation)
            defer { inFlight = nil }
            do {
                let content = try await operation.value
                return try reply(["content": content.map { ["type": "text", "text": $0] }])
            } catch {
                return try reply(["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
            }
        default:
            return try reply(["code": -32601, "message": "Unsupported MCP method."], error: true)
        }
    }
}

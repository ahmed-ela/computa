import Foundation
import Network
import XCTest
@testable import Computa

/// Exercises the authenticated production HTTP boundary. Only the model
/// transport is synthetic; no provider account or running app is touched.
final class OpenResponsesIntegrationTests: XCTestCase {
    func testJSONAndSSEModesThroughHTTPAndOfficialSchema() async throws {
        let transport = OpenResponsesFixtureTransport()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport, defaultChatChoice: syntheticChatGPTChoice))
        let base = try await server.start()
        do {
            var artifacts: [[String: Any]] = []
            let root = try artifactRoot()
            for (name, stream) in [("default-json", Optional<Bool>.none), ("explicit-json", false), ("text-stream", true)] {
                var body: [String: Any] = ["model": syntheticChatGPTModelID, "input": "Synthetic HTTP contract", "metadata": ["fixture": "open-responses"]]
                if let stream { body["stream"] = stream }
                let (data, response) = try await send(body, to: base, server: server)
                XCTAssertEqual(response.statusCode, 200)
                XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), stream == true ? "text/event-stream" : "application/json")
                if stream == true {
                    XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("data: [DONE]\n\n"))
                } else {
                    let resource = try object(data)
                    XCTAssertEqual(resource["object"] as? String, "response")
                    XCTAssertEqual(resource["status"] as? String, "completed")
                    XCTAssertTrue(resource["usage"] is NSNull)
                    XCTAssertEqual((resource["metadata"] as? [String: Any])?["fixture"] as? String, "open-responses")
                }
                try export(data, name: name, kind: stream == true ? "sse" : "response", root: root, cases: &artifacts)
            }
            let function: [String: Any] = ["type": "function", "name": "get_weather", "parameters": ["type": "object"]]
            for stream in [false, true] {
                let (data, response) = try await send(["model": syntheticChatGPTModelID, "input": "Parallel tool contract", "stream": stream,
                    "tools": [function], "tool_choice": "required", "parallel_tool_calls": true], to: base, server: server)
                XCTAssertEqual(response.statusCode, 200)
                try export(data, name: stream ? "function-stream" : "function-json", kind: stream ? "sse" : "response", root: root, cases: &artifacts)
            }
            let (custom, customResponse) = try await send(["model": syntheticChatGPTModelID, "input": "Custom tool contract", "stream": true,
                "tools": [["type": "namespace", "name": "functions", "tools": [["type": "custom", "name": "apply_patch", "format": ["type": "text"]]]]],
                "tool_choice": "required"], to: base, server: server)
            XCTAssertEqual(customResponse.statusCode, 200)
            try export(custom, name: "codex-custom-stream", kind: "sse", profile: "codex-custom-tools", root: root, cases: &artifacts)
            let (error, errorResponse) = try await send(["model": syntheticChatGPTModelID, "input": "Synthetic", "stream": "true"], to: base, server: server)
            XCTAssertEqual(errorResponse.statusCode, 400)
            try export(error, name: "request-error", kind: "error", root: root, cases: &artifacts)
            try JSONSerialization.data(withJSONObject: ["version": 1, "cases": artifacts], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("manifest.json"))
            let result = try await runConformance(["--artifacts", root.path])
            XCTAssertEqual(result.status, 0, result.output)
            print(result.output)
            _ = await server.shutdown()
        } catch { _ = await server.shutdown(); throw error }
    }

    func testUpstreamAcceptanceTemplatesAgainstRealHTTPListener() async throws {
        let transport = OpenResponsesFixtureTransport()
        var servers: [WebModelServer] = []
        var relay: OpenResponsesOfficialRelay?
        do {
            // The six upstream HTTP cases are independent requests, including
            // multi-turn's complete history in one body. Each needs its own
            // native task/turn rather than an unrelated same-turn continuation.
            var targets: [OpenResponsesOfficialRoutes.Target] = []
            for _ in 0..<6 {
                let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
                servers.append(server)
                await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport, defaultChatChoice: syntheticChatGPTChoice))
                let taskID = UUID().uuidString.lowercased()
                _ = try await bindWebsiteInferenceFixtureTurn(server, taskID: taskID)
                targets.append(.init(base: try await server.start(), token: server.bearerToken,
                    taskID: taskID, metadata: try websiteInferenceFixtureMetadata(taskID: taskID)))
            }
            let taskID = UUID().uuidString.lowercased(), token = UUID().uuidString
            let metadata = try websiteInferenceFixtureMetadata(taskID: taskID)
            let routes = OpenResponsesOfficialRoutes(targets: targets, token: token, taskID: taskID, metadata: metadata)
            let listener = try OpenResponsesOfficialRelay(routes: routes)
            relay = listener
            let base = try await listener.start()
            let contextRoot = try artifactRoot()
            let contextURL = contextRoot.appendingPathComponent("official-fixture-headers.json")
            try JSONSerialization.data(withJSONObject: ["x-computa-task-id": taskID,
                "x-codex-turn-metadata": metadata], options: [.sortedKeys])
                .write(to: contextURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contextURL.path)
            defer { try? FileManager.default.removeItem(at: contextURL) }
            let result = try await runConformance(["--official", "--base-url", base.absoluteString, "--model", syntheticChatGPTModelID,
                "--fixture-headers", contextURL.path], token: token)
            XCTAssertEqual(result.status, 0, result.output)
            print(result.output)
            let sends = await transport.sendCount()
            // One upstream case is a local schema fixture and sends no HTTP.
            XCTAssertEqual(sends, 6)
            let forwarded = await routes.forwardedCount()
            let starts = await transport.startCount()
            XCTAssertEqual(forwarded, 6)
            XCTAssertEqual(starts, 6)
            listener.stop()
            for server in servers { _ = await server.shutdown() }
        } catch {
            relay?.stop()
            for server in servers { _ = await server.shutdown() }
            throw error
        }
    }

    func testUnsupportedRequestsAndSecurityFailBeforeTransport() async throws {
        let transport = OpenResponsesFixtureTransport()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport, defaultChatChoice: syntheticChatGPTChoice))
        let base = try await server.start()
        do {
            let invalid: [([String: Any], Int, String?)] = [
                (["model": "unknown/model", "input": "fixture"], 404, "model"),
                (["model": syntheticChatGPTModelID, "input": "fixture", "store": true], 400, "store"),
                (["model": syntheticChatGPTModelID, "input": "fixture", "background": true], 400, "background"),
                (["model": syntheticChatGPTModelID, "input": "fixture", "temperature": 0.3], 400, "temperature"),
                (["model": syntheticChatGPTModelID, "input": "fixture", "previous_response_id": "resp_fixture"], 400, "previous_response_id"),
                (["model": syntheticChatGPTModelID, "input": [["type": "item_reference", "id": "msg_missing"]]], 400, "input.item_reference"),
                (["model": syntheticChatGPTModelID, "input": "fixture", "tool_choice": "required"], 400, "tool_choice"),
            ]
            for (body, status, param) in invalid {
                let (data, response) = try await send(body, to: base, server: server)
                XCTAssertEqual(response.statusCode, status)
                let error = try XCTUnwrap(try object(data)["error"] as? [String: Any])
                XCTAssertEqual(error["param"] as? String, param)
                XCTAssertNotNil(error["code"])
            }
            for (headers, expected) in [(["Authorization": "Bearer invalid"], 401), (["Origin": "https://fixture.invalid"], 403), (["Content-Type": "text/plain"], 415)] {
                let (_, response) = try await send(["model": syntheticChatGPTModelID, "input": "fixture"], to: base, server: server, headers: headers)
                XCTAssertEqual(response.statusCode, expected)
            }
            let sends = await transport.sendCount()
            let starts = await transport.startCount()
            XCTAssertEqual(sends, 0); XCTAssertEqual(starts, 0)
            _ = await server.shutdown()
        } catch { _ = await server.shutdown(); throw error }
    }

    func testToolPolicyViolationDoesNotEmitItemsOrReplay() async throws {
        for policy in ["none", "required"] {
            let reply = policy == "none" ? #"{"type":"tool_calls","calls":[{"name":"get_weather","arguments":{}}]}"# : #"{"type":"message","text":"Synthetic"}"#
            let transport = OpenResponsesFixtureTransport(forcedReply: reply)
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport, defaultChatChoice: syntheticChatGPTChoice))
            let base = try await server.start()
            do {
                let (data, response) = try await send(["model": syntheticChatGPTModelID, "input": "fixture", "stream": true, "tool_choice": policy,
                    "tools": [["type": "function", "name": "get_weather", "parameters": ["type": "object"]]]], to: base, server: server)
                XCTAssertEqual(response.statusCode, 500)
                let error = try XCTUnwrap(try object(data)["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? String, "tool_choice_violation")
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("response.output_item"))
                let sends = await transport.sendCount()
                XCTAssertEqual(sends, 1)
                _ = await server.shutdown()
            } catch { _ = await server.shutdown(); throw error }
        }
    }

    private func send(_ body: [String: Any], to base: URL, server: WebModelServer, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let taskID = UUID().uuidString.lowercased()
        _ = try await bindWebsiteInferenceFixtureTurn(server, taskID: taskID)
        var request = URLRequest(url: base.appendingPathComponent("responses"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + server.bearerToken, forHTTPHeaderField: "Authorization")
        request.setValue(taskID, forHTTPHeaderField: "X-Computa-Task-ID")
        request.setValue(try websiteInferenceFixtureMetadata(taskID: taskID), forHTTPHeaderField: "x-codex-turn-metadata")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func artifactRoot() throws -> URL {
        let configured = ProcessInfo.processInfo.environment["COMPUTA_OPEN_RESPONSES_ARTIFACT_DIR"]
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ComputaOpenResponses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if configured == nil { addTeardownBlock { try? FileManager.default.removeItem(at: root) } }
        return root
    }

    private func export(_ data: Data, name: String, kind: String, profile: String = "standard", root: URL, cases: inout [[String: Any]]) throws {
        let file = name + (kind == "sse" ? ".sse" : ".json")
        try data.write(to: root.appendingPathComponent(file))
        cases.append(["name": name, "file": file, "kind": kind, "profile": profile])
    }

    private func runConformance(_ arguments: [String], token: String? = nil) async throws -> (status: Int32, output: String) {
        let executable = try FixtureBunExecutable.resolve()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = [repo.appendingPathComponent("Scripts/open-responses-conformance.ts").path] + arguments
            process.currentDirectoryURL = repo
            var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR"].contains($0.key) }
            if let token { environment["COMPUTA_OPEN_RESPONSES_API_KEY"] = token }
            process.environment = environment
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// Supplies native context outside the pinned upstream request body. It never
/// manufactures a response: status, Content-Type and bytes come from the real
/// authenticated WebModelServer listener for that independent fixture case.
private actor OpenResponsesOfficialRoutes {
    struct Target: Sendable {
        let base: URL
        let token: String
        let taskID: String
        let metadata: String
    }
    struct Response: Sendable {
        let status: Int
        let contentType: String
        let body: Data
    }
    private let targets: [Target]
    private let token: String
    private let taskID: String
    private let metadata: String
    private var forwarded = 0

    init(targets: [Target], token: String, taskID: String, metadata: String) {
        self.targets = targets; self.token = token; self.taskID = taskID; self.metadata = metadata
    }
    func forwardedCount() -> Int { forwarded }

    func forward(_ incoming: APIModelServer.HTTPRequest) async throws -> Response {
        guard incoming.method == "POST", incoming.path == "/v1/responses",
              incoming.headers["authorization"] == "Bearer " + token,
              incoming.headers["x-computa-task-id"] == taskID,
              incoming.headers["x-codex-turn-metadata"] == metadata,
              forwarded < targets.count else { throw URLError(.badServerResponse) }
        let target = targets[forwarded]
        forwarded += 1
        var request = URLRequest(url: target.base.appendingPathComponent("responses"))
        request.httpMethod = incoming.method; request.timeoutInterval = 20
        request.httpBody = incoming.body
        let replaced = Set(["host", "content-length", "connection", "authorization", "x-computa-task-id", "x-codex-turn-metadata"])
        for (name, value) in incoming.headers where !replaced.contains(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Each fixture listener has its own immutable bearer credential. Both
        // the relay credential and the actual native listener credential are
        // checked; only the request's transport identity changes here.
        request.setValue("Bearer " + target.token, forHTTPHeaderField: "Authorization")
        request.setValue(target.taskID, forHTTPHeaderField: "X-Computa-Task-ID")
        request.setValue(target.metadata, forHTTPHeaderField: "X-Codex-Turn-Metadata")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= 2_097_152, let response = response as? HTTPURLResponse,
              response.url == request.url,
              let contentType = response.value(forHTTPHeaderField: "Content-Type") else {
            throw URLError(.badServerResponse)
        }
        return .init(status: response.statusCode, contentType: contentType, body: data)
    }
}

/// A bounded loopback-only test relay. SSE is buffered because this acceptance
/// suite validates the full wire contract rather than first-event latency.
private final class OpenResponsesOfficialRelay: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ComputaTests.OpenResponses.official")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init(routes: OpenResponsesOfficialRoutes) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.retain(connection) else { connection.cancel(); return }
            connection.start(queue: self.queue)
            Task {
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(25)); connection.cancel() } catch { }
                }
                defer { deadline.cancel(); connection.cancel() }
                do {
                    let request = try await Self.read(connection)
                    let response = try await routes.forward(request)
                    try await Self.send(response, on: connection)
                } catch {
                    // Any fixture routing/parsing failure remains a failing
                    // upstream HTTP result rather than a synthetic success.
                    try? await Self.send(.init(status: 502, contentType: "text/plain", body: Data("Fixture relay failed".utf8)), on: connection)
                }
            }
        }
    }

    private func retain(_ connection: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard connections.count < 8 else { return false }
        connections.append(connection); return true
    }

    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let ready = OpenResponsesOfficialReady(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if let port = listener.port { ready.finish(.success(port.rawValue)) }
                case .failed(let error): ready.finish(.failure(error))
                case .cancelled: ready.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    func stop() {
        listener.cancel()
        lock.lock(); let values = connections; lock.unlock()
        values.forEach { $0.cancel() }
    }

    private static func read(_ connection: NWConnection) async throws -> APIModelServer.HTTPRequest {
        var buffer = Data()
        while true {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: CancellationError()) }
                }
            }
            buffer.append(data)
            // Reuse the strict finite parser (16 KiB headers, 2 MiB request,
            // exact Content-Length, no transfer encoding or duplicate headers).
            if let request = try APIModelServer.parseRequest(buffer) { return request }
        }
    }

    private static func send(_ response: OpenResponsesOfficialRoutes.Response, on connection: NWConnection) async throws {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status)
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var output = Data(head.utf8); output.append(response.body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: output, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

private final class OpenResponsesOfficialReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
}

private actor OpenResponsesFixtureTransport: WebModelTransport {
    private let forcedReply: String?
    private var replies: [String: String] = [:]
    private var sends = 0
    private var starts = 0
    init(forcedReply: String? = nil) { self.forcedReply = forcedReply }
    func sendCount() -> Int { sends }
    func startCount() -> Int { starts }

    func request(operation: String, params: Data) throws -> Data {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        var response: [String: Any]
        switch operation {
        case "webProviderStart":
            starts += 1
            let token = UUID().uuidString; replies[token] = ""
            response = ["sessionToken": token, "state": "ready"]
        case "webProviderSend":
            sends += 1
            let token = try XCTUnwrap(input["sessionToken"])
            let prompt = try XCTUnwrap(input["prompt"])
            let json = try WebsiteRequestFixture.json(in: prompt)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            let tools = request["tools"] as? [[String: Any]] ?? []
            if let forcedReply { replies[token] = forcedReply }
            else if tools.first?["type"] as? String == "namespace" {
                replies[token] = #"{"type":"tool_calls","calls":[{"name":"functions.apply_patch","input":"*** Begin Patch\n*** End Patch"}]}"#
            } else if !tools.isEmpty {
                let calls: [[String: Any]] = Array(repeating: ["name": "get_weather", "arguments": ["location": "San Francisco, CA"]], count: request["parallel_tool_calls"] as? Bool == true ? 2 : 1)
                replies[token] = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": calls]), as: UTF8.self)
            } else {
                replies[token] = #"{"type":"message","text":"Synthetic fixture response"}"#
            }
            response = ["state": "running"]
        case "webProviderPoll":
            let token = try XCTUnwrap(input["sessionToken"])
            response = ["state": "complete", "text": try XCTUnwrap(replies[token])]
        case "webProviderFinish", "webProviderCancel": response = ["cleanup": "not_created"]
        default: throw WebModelServer.Failure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(response))
    }
}

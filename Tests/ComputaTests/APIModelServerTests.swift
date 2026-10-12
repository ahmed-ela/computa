import XCTest
import Network
@testable import Computa

private actor APIRequestRecorder {
    var requests: [APIModelServer.HTTPRequest] = []
    func record(_ request: APIModelServer.HTTPRequest) { requests.append(request) }
    func count() -> Int { requests.count }
    func first() -> APIModelServer.HTTPRequest? { requests.first }
}
private struct APIFixtureCredentials: APIProviderCredentials {
    let value: String?
    func key(for providerID: String) throws -> String? { value }
    func save(_ key: String, for providerID: String) throws { XCTFail("inference must not save credentials") }
    func remove(for providerID: String) throws { XCTFail("inference must not delete credentials") }
}
private final class APICredentialCounter: APIProviderCredentials, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var writes = 0
    func key(for providerID: String) throws -> String? { lock.lock(); defer { lock.unlock() }; reads += 1; return "fixture-secret" }
    func save(_ key: String, for providerID: String) throws { lock.lock(); defer { lock.unlock() }; writes += 1 }
    func remove(for providerID: String) throws { lock.lock(); defer { lock.unlock() }; writes += 1 }
    func counts() -> (reads: Int, writes: Int) { lock.lock(); defer { lock.unlock() }; return (reads, writes) }
}
private final class APILoopbackFixture: @unchecked Sendable {
    struct Response: Sendable { let status: String; let headers: [String: String]; let body: Data }
    let listener: NWListener
    private let queue = DispatchQueue(label: "ComputaTests.API.loopback")
    private let lock = NSLock()
    private var sockets: [NWConnection] = []
    init(_ handler: @escaping @Sendable (APIModelServer.HTTPRequest) async -> Response) throws {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.sockets.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            Task {
                defer { connection.cancel() }
                do {
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
                        if let request = try APIModelServer.parseRequest(buffer) {
                            let response = await handler(request)
                            var head = "HTTP/1.1 \(response.status)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
                            for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
                            var output = Data((head + "\r\n").utf8); output.append(response.body)
                            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                connection.send(content: output, completion: .contentProcessed { error in
                                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                                })
                            }
                            break
                        }
                    }
                } catch { }
            }
        }
    }
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = APIFixtureReady(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if let port = listener.port { once.finish(.success(port.rawValue)) }
                case .failed(let error): once.finish(.failure(error))
                case .cancelled: once.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/v1")!
    }
    func stop() { listener.cancel(); lock.lock(); let values = sockets; lock.unlock(); values.forEach { $0.cancel() } }
}
private final class APIFixtureReady: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) { lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume(with: result) }
}

final class APIModelServerTests: XCTestCase, @unchecked Sendable {
    private func provider(_ url: URL) -> APIProviderDefinition { .init(id: "fixture", name: "Fixture", baseURL: url, wireAPI: .chatCompletions, models: [.init(id: "fixture-model", name: "Fixture")]) }
    private func response(_ content: String = "done") -> APILoopbackFixture.Response {
        .init(status: "200 OK", headers: ["Content-Type": "application/json"], body: Data("{\"id\":\"r1\",\"model\":\"fixture-model\",\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"\(content)\"}}]}".utf8))
    }
    private func localRequest(base: URL, token: String, task: String, thread: String, turn: String, provider: APIProviderDefinition) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("responses"))
        request.httpMethod = "POST"; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(task, forHTTPHeaderField: "X-Computa-Task-ID")
        let identity = try JSONSerialization.data(withJSONObject: ["thread_id": thread, "turn_id": turn])
        request.setValue(String(decoding: identity, as: UTF8.self), forHTTPHeaderField: "X-Codex-Turn-Metadata")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": APIProviderCatalog.appModelID(providerID: provider.id, modelID: provider.models[0].id), "input": [["role": "user", "content": "hello"]], "stream": true, "store": false])
        return request
    }
    private func server() throws -> APIModelServer {
        APIModelServer(credentials: APIFixtureCredentials(value: "fixture-secret"), capsules: try .init(key: Data(repeating: 1, count: 32)))
    }
    func testAuthenticatedGatewayPreservesNativeTurnAndOneDispatch() async throws {
        let records = APIRequestRecorder(), reply = response()
        let remote = try APILoopbackFixture { request in await records.record(request); return reply }; defer { remote.stop() }
        let p = provider(try await remote.start()), server = try server(); try await server.updateProviders([p])
        let url = try await server.start(), task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString, preparation = UUID()
        try await server.prepareInferenceTurn(taskID: task, threadID: thread, preparationID: preparation)
        // Real inference may beat the native turn/start acknowledgement.
        let request = try localRequest(base: url, token: server.bearerToken, task: task, thread: thread, turn: turn, provider: p)
        let pending = Task { try await URLSession.shared.data(for: request) }
        try await Task.sleep(for: .milliseconds(30))
        try await server.registerInferenceTurn(taskID: task, threadID: thread, turnID: turn, preparationID: preparation)
        let (data, result) = try await pending.value
        XCTAssertEqual((result as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("response.completed"))
        let count = await records.count(); XCTAssertEqual(count, 1)
        let upstream = await records.first(); XCTAssertEqual(upstream?.path, "/v1/chat/completions")
        XCTAssertEqual(upstream?.headers["authorization"], "Bearer fixture-secret")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-secret"))
        await server.finish(taskID: task)
        let (_, stale) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((stale as? HTTPURLResponse)?.statusCode, 400)
        let after = await records.count(); XCTAssertEqual(after, 1)
        await server.shutdown()
    }
    func testAuthenticationModelsAndMetadataConflictsRejectBeforeProviderAccess() async throws {
        let records = APIRequestRecorder(), reply = response()
        let remote = try APILoopbackFixture { request in await records.record(request); return reply }; defer { remote.stop() }
        let counter = APICredentialCounter()
        let p = provider(try await remote.start()), server = APIModelServer(credentials: counter, capsules: try .init(key: Data(repeating: 1, count: 32))); try await server.updateProviders([p])
        let url = try await server.start(), task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString, prep = UUID()
        var modelRequest = URLRequest(url: url.appendingPathComponent("models"))
        let (_, unauthorized) = try await URLSession.shared.data(for: modelRequest)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        modelRequest.setValue("Bearer " + server.bearerToken, forHTTPHeaderField: "Authorization")
        let (catalog, ok) = try await URLSession.shared.data(for: modelRequest)
        XCTAssertEqual((ok as? HTTPURLResponse)?.statusCode, 200)
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        XCTAssertEqual((listed["data"] as? [[String: Any]])?.first?["id"] as? String, APIProviderCatalog.appModelID(providerID: p.id, modelID: p.models[0].id))
        try await server.prepareInferenceTurn(taskID: task, threadID: thread, preparationID: prep)
        try await server.registerInferenceTurn(taskID: task, threadID: thread, turnID: turn, preparationID: prep)
        var request = try localRequest(base: url, token: server.bearerToken, task: task, thread: thread, turn: turn, provider: p)
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        body["client_metadata"] = ["x-codex-turn-metadata": "{\"thread_id\":\"\(thread)\",\"turn_id\":\"\(UUID().uuidString)\"}"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, rejected) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        let count = await records.count(); XCTAssertEqual(count, 0)
        XCTAssertEqual(counter.counts().reads, 0)
        await server.shutdown()
    }
    func testCancelDrainsExactRequestAndStaleTurnCannotReviveAfterNewPreparation() async throws {
        let records = APIRequestRecorder(), reply = response()
        let remote = try APILoopbackFixture { request in
            await records.record(request); try? await Task.sleep(for: .seconds(2)); return reply
        }; defer { remote.stop() }
        let p = provider(try await remote.start()), server = try server(); try await server.updateProviders([p])
        let url = try await server.start(), task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString, prep = UUID()
        try await server.prepareInferenceTurn(taskID: task, threadID: thread, preparationID: prep)
        try await server.registerInferenceTurn(taskID: task, threadID: thread, turnID: turn, preparationID: prep)
        let request = try localRequest(base: url, token: server.bearerToken, task: task, thread: thread, turn: turn, provider: p)
        let pending = Task { try await URLSession.shared.data(for: request) }
        for _ in 0..<100 { if await records.count() == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let beforeCancel = await records.count(); XCTAssertEqual(beforeCancel, 1)
        let (_, concurrent) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((concurrent as? HTTPURLResponse)?.statusCode, 400)
        await server.cancel(taskID: task)
        let (_, cancelled) = try await pending.value
        XCTAssertEqual((cancelled as? HTTPURLResponse)?.statusCode, 400)
        let nextPrep = UUID(), nextTurn = UUID().uuidString
        try await server.prepareInferenceTurn(taskID: task, threadID: thread, preparationID: nextPrep)
        try await server.registerInferenceTurn(taskID: task, threadID: thread, turnID: nextTurn, preparationID: nextPrep)
        let (_, stale) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((stale as? HTTPURLResponse)?.statusCode, 400)
        let after = await records.count(); XCTAssertEqual(after, 1)
        await server.shutdown()
    }
    func testHTTPParserRejectsSmugglingAndErrorProjectionNeverLeaksRawDescriptions() throws {
        for text in ["POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}", "POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}", "POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}EXTRA", "GET /v1/models HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"] {
            XCTAssertThrowsError(try APIModelServer.parseRequest(Data(text.utf8)))
        }
        let raw = NSError(domain: "fixture-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "credential fixture-secret and user content"])
        XCTAssertFalse(String(decoding: try APIModelServer.errorBody(raw), as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual(APIModelServer.errorStatus(APIProviderHTTPClient.Failure.rateLimited), "429 Too Many Requests")
    }
    func testRedirectNeverForwardsCredentialsAndRemoteErrorsAreFiniteWithoutRetry() async throws {
        let targetRecords = APIRequestRecorder(), reply = response()
        let target = try APILoopbackFixture { request in await targetRecords.record(request); return reply }; defer { target.stop() }
        let targetURL = try await target.start()
        let records = APIRequestRecorder()
        let redirect = try APILoopbackFixture { request in await records.record(request); return .init(status: "302 Found", headers: ["Location": targetURL.appendingPathComponent("chat/completions").absoluteString], body: Data()) }; defer { redirect.stop() }
        let client = APIProviderHTTPClient(), p = provider(try await redirect.start())
        do { _ = try await client.request(provider: p, key: "fixture-secret", path: "chat/completions", body: Data("{}".utf8)); XCTFail("redirect must fail") }
        catch { XCTAssertEqual(error as? APIProviderHTTPClient.Failure, .redirectRejected) }
        let sourceCount = await records.count(), targetCount = await targetRecords.count(); XCTAssertEqual(sourceCount, 1); XCTAssertEqual(targetCount, 0)
        let codes: [(String, APIProviderHTTPClient.Failure)] = [("401 Unauthorized", .unauthorized), ("429 Too Many Requests", .rateLimited), ("404 Not Found", .modelNotFound), ("400 Bad Request", .contextLimit)]
        for (status, expected) in codes {
            let counter = APIRequestRecorder()
            let remote = try APILoopbackFixture { request in await counter.record(request); return .init(status: status, headers: ["Content-Type": "application/json"], body: Data("{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"fixture-secret\"}}".utf8)) }
            let p = provider(try await remote.start())
            do { _ = try await client.request(provider: p, key: "fixture-secret", path: "chat/completions", body: Data("{}".utf8)); XCTFail("expected finite error") }
            catch { XCTAssertEqual(error as? APIProviderHTTPClient.Failure, expected); XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
            let count = await counter.count(); XCTAssertEqual(count, 1); remote.stop()
        }
    }
    func testEndpointPolicyAndNativeModelDiscovery() async throws {
        for raw in ["http://example.invalid/v1", "https://user:secret@example.invalid/v1", "https://example.invalid/v1?key=secret", "https://example.invalid/v1#fragment", "https://example.invalid/v1/%2e%2e"] {
            XCTAssertThrowsError(try APIProviderHTTPClient.endpoint(URL(string: raw)!, path: "models"))
        }
        XCTAssertEqual(try APIProviderHTTPClient.endpoint(URL(string: "https://api.cerebras.ai/v1")!, path: "chat/completions").absoluteString, "https://api.cerebras.ai/v1/chat/completions")
        let records = APIRequestRecorder()
        let remote = try APILoopbackFixture { request in await records.record(request); return .init(status: "200 OK", headers: ["Content-Type": "application/json"], body: Data("{\"object\":\"list\",\"data\":[{\"id\":\"qwen-3.8-27b\"}]}".utf8)) }; defer { remote.stop() }
        let p = APIProviderDefinition(id: "cerebras", name: "Cerebras", baseURL: try await remote.start(), wireAPI: .chatCompletions, models: [])
        let models = try await APIProviderHTTPClient().listModels(provider: p, key: "fixture-secret")
        XCTAssertEqual(models.map(\.id), ["qwen-3.8-27b"]); XCTAssertEqual(models.first?.contextWindow, 32_768); XCTAssertEqual(models.first?.supportsImages, false)
        let first = await records.first(); XCTAssertEqual(first?.method, "GET"); XCTAssertEqual(first?.path, "/v1/models")
    }
    func testAtomicConfigurationRejectsBusyBeforeCredentialMutationAndCommitsTogether() async throws {
        let credentials = APICredentialCounter()
        let server = APIModelServer(credentials: credentials, capsules: try .init(key: Data(repeating: 1, count: 32)))
        let original = provider(URL(string: "https://original.invalid/v1")!)
        try await server.updateProviders([original])
        let url = try await server.start(), task = UUID().uuidString, thread = UUID().uuidString, preparation = UUID()
        try await server.prepareInferenceTurn(taskID: task, threadID: thread, preparationID: preparation)
        let replacement = APIProviderDefinition(id: original.id, name: "New", baseURL: URL(string: "https://replacement.invalid/v1")!, wireAPI: .chatCompletions, models: [.init(id: "new-model", name: "New model")])
        do { try await server.applyProviderConfiguration([replacement]) { try credentials.save("new-secret", for: original.id) }; XCTFail("busy configuration must fail") }
        catch { XCTAssertEqual(error as? APIModelServer.Failure, .busy) }
        XCTAssertEqual(credentials.counts().writes, 0)
        await server.finish(taskID: task)
        try await server.applyProviderConfiguration([replacement]) { try credentials.save("new-secret", for: original.id) }
        XCTAssertEqual(credentials.counts().writes, 1)
        var request = URLRequest(url: url.appendingPathComponent("models")); request.setValue("Bearer " + server.bearerToken, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((catalog["data"] as? [[String: Any]])?.first?["id"] as? String, APIProviderCatalog.appModelID(providerID: original.id, modelID: "new-model"))
        do { try await server.applyProviderConfiguration([original]) { throw APIProviderCredentialStore.Failure.unavailable }; XCTFail("failed key mutation must not change registry") } catch { }
        let (unchanged, _) = try await URLSession.shared.data(for: request)
        let unchangedCatalog = try JSONSerialization.jsonObject(with: unchanged) as? NSDictionary
        XCTAssertEqual(catalog as NSDictionary, unchangedCatalog)
        await server.shutdown()
    }

}

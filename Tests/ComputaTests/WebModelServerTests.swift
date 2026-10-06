import Foundation
import XCTest
@testable import Computa

final class WebModelServerTests: XCTestCase {
    private let request = Data("{\"model\":\"browser/chatgpt\",\"input\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"tools\":[],\"stream\":true}".utf8)

    func testSessionSurvivesToolIterationsAndFinishesOnlyItsTask() async throws {
        let transport = FixtureWebModelTransport()
        let server = WebModelServer()
        await server.setTransportForTesting(transport)
        let first = try await server.infer(request, taskID: "task-one")
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("response.completed"))
        _ = try await server.infer(request, taskID: "task-one")
        _ = try await server.infer(request, taskID: "task-two")
        let operations = await transport.operations()
        XCTAssertEqual(operations.filter { $0 == "webProviderStart" }.count, 2)
        let issues = await server.finish(taskID: "task-one")
        XCTAssertTrue(issues.isEmpty)
        let after = await transport.operations()
        XCTAssertEqual(after.filter { $0 == "webProviderFinish" }.count, 1)
        _ = await server.shutdown()
    }

    func testClaudeRoutesToClaudeReusesItsSessionAndStartsFreshAfterCleanup() async throws {
        let transport = FixtureWebModelTransport()
        let server = WebModelServer()
        await server.setTransportForTesting(transport)
        let claudeRequest = Data("{\"model\":\"browser/claude\",\"input\":\"Say OK\",\"tools\":[],\"stream\":true}".utf8)
        _ = try await server.infer(claudeRequest, taskID: "claude-task")
        _ = try await server.infer(claudeRequest, taskID: "claude-task")
        let initialProviders = await transport.startedProviders()
        XCTAssertEqual(initialProviders, ["claude"])
        let issues = await server.finish(taskID: "claude-task")
        XCTAssertTrue(issues.isEmpty)
        let finishedOperations = await transport.operations()
        XCTAssertEqual(finishedOperations.filter { $0 == "webProviderFinish" }.count, 1)
        _ = try await server.infer(claudeRequest, taskID: "claude-task")
        let restartedProviders = await transport.startedProviders()
        XCTAssertEqual(restartedProviders, ["claude", "claude"])
        let shutdownIssues = await server.shutdown()
        XCTAssertTrue(shutdownIssues.isEmpty)
        let finalOperations = await transport.operations()
        XCTAssertEqual(finalOperations.filter { $0 == "webProviderCancel" }.count, 1)
    }

    func testUnverifiedCleanupIsReportedAndRetried() async throws {
        let transport = FixtureWebModelTransport(cleanupFailsOnce: true)
        let server = WebModelServer()
        await server.setTransportForTesting(transport)
        _ = try await server.infer(request, taskID: "one")
        let failed = await server.finish(taskID: "one")
        XCTAssertFalse(failed.isEmpty)
        let retried = await server.finish(taskID: "one")
        XCTAssertTrue(retried.isEmpty)
        let operations = await transport.operations()
        XCTAssertEqual(operations.filter { $0 == "webProviderFinish" }.count, 2)
        _ = await server.shutdown()
    }

    func testHTTPRejectsWebsiteOriginWithoutInvokingProvider() async throws {
        let transport = FixtureWebModelTransport()
        let server = WebModelServer()
        await server.setTransportForTesting(transport)
        let endpoint = try await server.start().appendingPathComponent("responses")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"; urlRequest.httpBody = request
        urlRequest.setValue("Bearer " + server.bearerToken, forHTTPHeaderField: "Authorization")
        urlRequest.setValue("one", forHTTPHeaderField: "X-Computa-Task-ID")
        urlRequest.setValue("https://untrusted.example", forHTTPHeaderField: "Origin")
        let (_, response) = try await URLSession.shared.data(for: urlRequest)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        let operations = await transport.operations()
        XCTAssertTrue(operations.isEmpty)
        _ = await server.shutdown()
    }

    func testHTTPParserHandlesFragmentationAndRejectsAmbiguousFraming() throws {
        let header = "POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try WebModelServer.parseRequest(Data((header + "{").utf8)))
        XCTAssertEqual(try WebModelServer.parseRequest(Data((header + "{}").utf8))?.body, Data("{}".utf8))
        XCTAssertThrowsError(try WebModelServer.parseRequest(Data("POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 3\r\n\r\n{}".utf8)))
        XCTAssertThrowsError(try WebModelServer.parseRequest(Data((header + "{}extra").utf8)))
    }

    func testConcurrentFinishAndShutdownShareOneCleanup() async throws {
        let transport = FixtureWebModelTransport(cleanupDelay: true)
        let server = WebModelServer()
        await server.setTransportForTesting(transport)
        _ = try await server.infer(request, taskID: "one")
        async let finished = server.finish(taskID: "one")
        async let disposed = server.shutdown()
        let issues = await finished + disposed
        XCTAssertTrue(issues.isEmpty)
        let operations = await transport.operations()
        XCTAssertEqual(operations.filter { ["webProviderFinish", "webProviderCancel"].contains($0) }.count, 1)
    }

    func testShutdownCancelsQueuedStartupAndAllowsExplicitRestart() async throws {
        let server = WebModelServer()
        let gate = WebListenerStartupGate()
        await server.setBeforeListenerStartForTesting { await gate.pause() }
        let startup = Task { try await server.start() }
        await gate.waitUntilEntered()
        _ = await server.shutdown()
        await gate.resume()
        switch await startup.result {
        case .success:
            XCTFail("A startup cancelled by shutdown must not reopen its listener")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        await server.setBeforeListenerStartForTesting(nil)
        let endpoint = try await server.start()
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.path, "/v1")
        _ = await server.shutdown()
    }
}

private actor WebListenerStartupGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var paused: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { paused = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func resume() {
        paused?.resume()
        paused = nil
    }
}

private actor FixtureWebModelTransport: WebModelTransport {
    private var ledger: [String] = []
    private var providers: [String] = []
    private var cleanupFailsOnce: Bool
    private let cleanupDelay: Bool
    private var tokens = Set<String>()
    init(cleanupFailsOnce: Bool = false, cleanupDelay: Bool = false) {
        self.cleanupFailsOnce = cleanupFailsOnce; self.cleanupDelay = cleanupDelay
    }
    func operations() -> [String] { ledger }
    func startedProviders() -> [String] { providers }
    func request(operation: String, params: Data) async throws -> Data {
        ledger.append(operation)
        var response: [String: String]
        if operation == "webProviderStart" {
            let object = try JSONSerialization.jsonObject(with: params) as! [String: String]
            guard let provider = object["provider"] else { throw WebModelServer.Failure.invalidRequest }
            providers.append(provider)
            let token = UUID().uuidString; tokens.insert(token)
            response = ["sessionToken": token, "state": "ready"]
        } else {
            let object = try JSONSerialization.jsonObject(with: params) as! [String: String]
            guard let token = object["sessionToken"], tokens.contains(token) else { throw WebModelServer.Failure.invalidRequest }
            switch operation {
            case "webProviderSend": response = ["state": "running"]
            case "webProviderPoll": response = ["state": "complete", "text": "{\"type\":\"message\",\"text\":\"OK\"}"]
            case "webProviderFinish", "webProviderCancel":
                if cleanupDelay { try await Task.sleep(for: .milliseconds(30)) }
                if cleanupFailsOnce { cleanupFailsOnce = false; response = ["cleanup": "failed"] }
                else { tokens.remove(token); response = ["cleanup": "not_created"] }
            default: throw WebModelServer.Failure.invalidRequest
            }
        }
        return try JSONSerialization.data(withJSONObject: response)
    }
}

import Foundation
import XCTest
@testable import Macrouse

@MainActor
final class LocalModelServerPreflightTests: XCTestCase {
    private let model = "lmstudio-community/Qwen3.5-4B-MLX-4bit"

    func testMirrorsBuiltInDefaultAndLaunchPort() throws {
        XCTAssertEqual(try endpoint([:]), "http://localhost:1234/v1/models")
        XCTAssertEqual(try endpoint(["CODEX_OSS_PORT": "54321"]), "http://localhost:54321/v1/models")
        for invalid in ["", " ", "invalid", "70000", "-1"] {
            XCTAssertEqual(try endpoint(["CODEX_OSS_PORT": invalid]), "http://localhost:1234/v1/models")
        }
    }

    func testLaunchBaseURLWinsAndKeepsProxyPathAndPort() throws {
        XCTAssertEqual(try endpoint(["CODEX_OSS_BASE_URL": "http://127.0.0.1:54321/proxy/v1///", "CODEX_OSS_PORT": "1234"]),
                       "http://127.0.0.1:54321/proxy/v1/models")
        XCTAssertEqual(try endpoint(["CODEX_OSS_BASE_URL": "http://[::1]:54321/v1"]), "http://[::1]:54321/v1/models")
        XCTAssertEqual(try endpoint(["CODEX_OSS_BASE_URL": "  ", "CODEX_OSS_PORT": "54321"]),
                       "http://localhost:54321/v1/models")
    }

    func testRejectsNonlocalCredentialedAmbiguousOrInvalidEndpointWithoutEchoingIt() {
        for value in ["https://example.com/v1", "http://localhost.evil.test/v1", "file:///tmp/models", "http://user:secret@localhost:1234/v1",
                      "http://localhost:1234/v1?token=secret", "http://localhost:1234/v1#secret", "http://localhost:0/v1", "not-a-url"] {
            XCTAssertThrowsError(try endpoint(["CODEX_OSS_BASE_URL": value])) { error in
                XCTAssertEqual(error as? LocalModelServerPreflight.Failure, .unsupportedConfiguration)
                XCTAssertFalse(error.localizedDescription.contains(value))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testAdvertisedExactModelPassesButDoesNotImplyLoadedState() throws {
        let data = try payload([model, "another-model"])
        XCTAssertNoThrow(try LocalModelServerPreflight.validateModels(data, status: 200, modelID: model))
        XCTAssertThrowsError(try LocalModelServerPreflight.validateModels(data, status: 200, modelID: "other-selected-model")) {
            XCTAssertEqual($0 as? LocalModelServerPreflight.Failure, .modelNotAdvertised)
        }
        XCTAssertThrowsError(try LocalModelServerPreflight.validateModels(data, status: 200, modelID: model.lowercased())) {
            XCTAssertEqual($0 as? LocalModelServerPreflight.Failure, .modelNotAdvertised)
        }
    }

    func testMalformedOrOversizedResponseNeverPasses() throws {
        for data in [Data(), Data("{\"data\":null}".utf8), Data("{\"data\":[{\"id\":7}]}".utf8),
                     Data("{\"data\":[{}]}".utf8), Data(repeating: 0x20, count: 1_048_577)] {
            XCTAssertThrowsError(try LocalModelServerPreflight.validateModels(data, status: 200, modelID: model)) {
                XCTAssertEqual($0 as? LocalModelServerPreflight.Failure, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try LocalModelServerPreflight.validateModels(payload([]), status: 200, modelID: model)) {
            XCTAssertEqual($0 as? LocalModelServerPreflight.Failure, .modelNotAdvertised)
        }
    }

    func testErrorAndRedirectStatusesExposeNoBodyOrAssumedCause() {
        for status in [301, 401, 500, 503] {
            XCTAssertThrowsError(try LocalModelServerPreflight.validateModels(Data("secret response body".utf8), status: status, modelID: model)) {
                XCTAssertEqual($0 as? LocalModelServerPreflight.Failure, .httpStatus(status))
                XCTAssertFalse($0.localizedDescription.contains("secret"))
            }
        }
    }

    func testProductionOnlyPreflightPreservesCustomProviderAndFixtureContracts() {
        var config = CodexAppServerRuntime.Configuration.localQwen
        XCTAssertTrue(config.requiresLocalModelPreflight)
        config.modelProvider = "bounded-test-proxy"
        XCTAssertFalse(config.requiresLocalModelPreflight)
        config.modelProvider = "lmstudio"
        config.executable = .fixture(path: "/not-executed")
        XCTAssertFalse(config.requiresLocalModelPreflight)
    }

    func testNetworkReadIsGETWithNoPromptOrAuthorization() async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:54321/v1/models"))
        let data = try payload([model])
        let observation = PreflightHTTPProtocol.Observation()
        PreflightHTTPProtocol.setHandler { request, client in
            observation.record(request)
            client.respond(data: data, status: 200)
        }
        defer { PreflightHTTPProtocol.setHandler(nil) }
        try await LocalModelServerPreflight.check(endpoint: url, modelID: model, timeout: 2,
                                                  sessionConfiguration: mockConfiguration())
        let request = try XCTUnwrap(observation.request)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.timeoutInterval, 2)
    }

    func testConnectionFailureIsFactualAndDoesNotLeakTransportDetails() async throws {
        PreflightHTTPProtocol.setHandler { _, client in
            client.client?.urlProtocol(client, didFailWithError: URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "secret transport details"]))
        }
        defer { PreflightHTTPProtocol.setHandler(nil) }
        do {
            try await LocalModelServerPreflight.check(endpoint: URL(string: "http://127.0.0.1:54321/v1/models")!,
                                                      modelID: model, timeout: 2, sessionConfiguration: mockConfiguration())
            XCTFail("Expected a connection failure")
        } catch {
            XCTAssertEqual(error as? LocalModelServerPreflight.Failure, .unavailable)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testTimeoutHasBoundedFactualMessageAndZeroBudgetDoesNotRequest() async throws {
        let observation = PreflightHTTPProtocol.Observation()
        PreflightHTTPProtocol.setHandler { request, client in
            observation.record(request)
            client.client?.urlProtocol(client, didFailWithError: URLError(.timedOut))
        }
        defer { PreflightHTTPProtocol.setHandler(nil) }
        for timeout in [0.0, 2.0] {
            do {
                try await LocalModelServerPreflight.check(endpoint: URL(string: "http://127.0.0.1:54321/v1/models")!,
                                                          modelID: model, timeout: timeout, sessionConfiguration: mockConfiguration())
                XCTFail("Expected timeout")
            } catch { XCTAssertEqual(error as? LocalModelServerPreflight.Failure, .timedOut) }
            if timeout == 0 { XCTAssertNil(observation.request) }
        }
    }

    func testOrdinaryPreflightRejectionPreservesTaskAndSelectedModel() async throws {
        let runtime = PreflightRejectingRuntime()
        let state = makeState(runtime: runtime)
        let accepted = await state.submit(prompt: "Read my package delivery date", toTaskID: "existing-task")
        XCTAssertFalse(accepted)
        XCTAssertEqual(state.selectedTaskID, "existing-task")
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.selectedTask?.model, model)
        XCTAssertFalse(state.isBusy(taskID: "existing-task"))
        XCTAssertEqual(state.selectedTask?.entries.filter { $0.kind == .user }.map(\.body), ["Read my package delivery date"])
        XCTAssertEqual(state.selectedTask?.entries.last?.title, "Prompt was not delivered")
        XCTAssertEqual(state.selectedTask?.entries.last?.body, LocalModelServerPreflight.Failure.unavailable.localizedDescription)
        let receivedModels = await runtime.receivedModels
        XCTAssertEqual(receivedModels, [model])
    }

    func testQueuedDrainChecksAgainAndRetainsUnsentMessageWithoutAutomaticReplay() async throws {
        let runtime = PreflightRejectingRuntime()
        let state = makeState(runtime: runtime)
        state.activeTurnTaskIDs.insert("existing-task")
        let accepted = await state.submitOrQueue(prompt: "Next package question", toTaskID: "existing-task")
        XCTAssertTrue(accepted)
        let beforeDrain = await runtime.receivedModels
        XCTAssertTrue(beforeDrain.isEmpty)
        state.apply(.taskStatusChanged(taskID: "existing-task", status: .completed))
        for _ in 0..<100 where state.queuedPrompts["existing-task"]?.first?.status != .failed {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.queuedPrompts["existing-task"]?.first?.text, "Next package question")
        XCTAssertEqual(state.queuedPrompts["existing-task"]?.first?.status, .failed)
        XCTAssertTrue(state.pausedQueueTaskIDs.contains("existing-task"))
        XCTAssertEqual(state.selectedTaskID, "existing-task")
        XCTAssertEqual(state.selectedTask?.model, model)
        XCTAssertFalse(state.isBusy(taskID: "existing-task"))
        state.apply(.taskStatusChanged(taskID: "existing-task", status: .completed))
        for _ in 0..<10 { await Task.yield() }
        let receivedModels = await runtime.receivedModels
        XCTAssertEqual(receivedModels, [model], "A failed preflight must not silently replay the queued prompt")
    }

    private func makeState(runtime: PreflightRejectingRuntime) -> AppState {
        AppState(tasks: [AgentTask(id: "existing-task", title: "Existing task", summary: "",
                                  status: .draft, workspace: "/tmp", model: model)],
                 runtime: runtime, preferences: isolatedTestPreferences())
    }

    private func endpoint(_ environment: [String: String]) throws -> String {
        try LocalModelServerPreflight.endpoint(launchEnvironment: environment).absoluteString
    }
    private func payload(_ models: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": models.map { ["id": $0] }])
    }
    private func mockConfiguration() -> URLSessionConfiguration {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [PreflightHTTPProtocol.self]
        return settings
    }
}

private actor PreflightRejectingRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Network-free preflight rejection fixture"
    private(set) var receivedModels: [String] = []
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { _ in } }
    func submit(prompt: String, toTaskID taskID: String, modelID: String) async throws {
        receivedModels.append(modelID)
        throw LocalModelServerPreflight.Failure.unavailable
    }
    func interrupt(taskID: String) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

private final class PreflightHTTPProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, PreflightHTTPProtocol) -> Void
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
    }
    final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var request: URLRequest? { lock.withLock { stored } }
        func record(_ request: URLRequest) { lock.withLock { stored = request } }
    }
    private static let storage = Storage()
    static func setHandler(_ handler: Handler?) { storage.lock.withLock { storage.handler = handler } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.storage.lock.withLock { Self.storage.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        handler(request, self)
    }
    override func stopLoading() {}
    func respond(data: Data, status: Int) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

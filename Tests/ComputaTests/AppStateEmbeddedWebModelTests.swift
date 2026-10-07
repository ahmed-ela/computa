import XCTest
@testable import Computa

@MainActor
final class AppStateEmbeddedWebModelTests: XCTestCase {
    func testEmbeddedTransportIsConfiguredBeforeLoadingSavedTasksWithoutChrome() async {
        let browser = EmbeddedBrowserSession(persistent: false)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences(), browserSession: browser)
        await state.startRuntime()
        XCTAssertEqual(runtime.operations, ["configure", "load"])
        XCTAssertNotNil(runtime.transport)
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        XCTAssertEqual(state.connectionState, .connected(provider: runtime.providerName))
        _ = await state.shutdownRuntime()
    }

    func testShutdownKeepsBrowserAliveUntilRuntimeSessionCleanupFinishes() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        _ = try browser.createTab()
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences(), browserSession: browser)
        await state.startRuntime()
        let report = await state.shutdownRuntime()
        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(runtime.browserWasLiveDuringShutdown)
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertThrowsError(try browser.createTab())
        _ = await state.shutdownRuntime()
        XCTAssertEqual(runtime.operations.filter { $0 == "shutdown" }.count, 1)
    }
}

@MainActor
private final class EmbeddedConfigurationRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Embedded startup fixture"
    let browser: EmbeddedBrowserSession
    var operations: [String] = []
    var transport: (any WebModelTransport)?
    var browserWasLiveDuringShutdown = false

    init(browser: EmbeddedBrowserSession) { self.browser = browser }
    func configureEmbeddedWebModelTransport(_ transport: any WebModelTransport) async {
        operations.append("configure")
        self.transport = transport
    }
    func loadTasks() async throws -> [AgentTask] {
        operations.append("load")
        XCTAssertNotNil(transport)
        return []
    }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
    func shutdown() async -> RuntimeShutdownReport {
        operations.append("shutdown")
        browserWasLiveDuringShutdown = !browser.tabs.isEmpty
        return RuntimeShutdownReport(issues: [])
    }
}

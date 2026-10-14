import WebKit
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

    func testHumanRecoveryMergedIntoStartupCanRetryOnlyGeminiAndNeverSubmit() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        browser.recordHumanVerificationRequired(provider: "gemini")
        let checkpoint = browser.savedHumanVerificationCheckpointIDs["gemini"]
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences(), browserSession: browser,
            websiteModelDiscovery: { provider in
                if provider == "chatgpt" { return try await withCheckedThrowingContinuation { held = $0 } }
                return Self.choices(provider)
            })
        var observed: [(String, Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { observed.append(($0, $1)) }
        state.refreshWebsiteModelsIfNeeded()
        try await waitUntil { held != nil }
        _ = try await healthyHumanPage(browser)
        try await waitUntil { state.websiteModelRefreshIntentsForTesting.contains { $0.provider == "gemini" && $0.retryBlocked } }
        held?.resume(returning: Self.choices("chatgpt")); held = nil
        try await waitUntil { !state.websiteModelsRefreshing }
        XCTAssertEqual(observed.map { $0.0 }, ["chatgpt", "gemini", "claude"])
        XCTAssertEqual(observed.map { $0.1 }, [false, true, false], "A Gemini intent cannot widen ChatGPT or Claude's startup gate")
        XCTAssertEqual(browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint, "Injected catalog results cannot clear a checkpoint")
        XCTAssertEqual(runtime.submissions, 0)
        XCTAssertEqual(browser.tabs.count, 1)
    }

    func testRevokedHumanCandidateBeforeOrDuringAwaitCannotClearOrRetry() async throws {
        for beforeProbe in [true, false] {
            let browser = EmbeddedBrowserSession(persistent: false)
            defer { browser.shutdown() }
            browser.recordHumanVerificationRequired(provider: "gemini")
            let checkpoint = browser.savedHumanVerificationCheckpointIDs["gemini"]
            let preferences = isolatedTestPreferences()
            if !beforeProbe { WebsiteModelCatalog.save(WebsiteModelCatalog.providers.flatMap(Self.choices), to: preferences) }
            let runtime = EmbeddedConfigurationRuntime(browser: browser)
            var held: CheckedContinuation<[WebsiteModelChoice], Error>?
            let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
                websiteModelDiscovery: { provider in
                    if provider == (beforeProbe ? "chatgpt" : "gemini") {
                        return try await withCheckedThrowingContinuation { held = $0 }
                    }
                    return Self.choices(provider)
                })
            var observed: [String] = []
            state.setWebsiteModelRefreshObserverForTesting { provider, _ in observed.append(provider) }
            state.refreshWebsiteModelsIfNeeded()
            if beforeProbe { try await waitUntil { held != nil } }
            let (id, _) = try await healthyHumanPage(browser)
            if beforeProbe {
                try await waitUntil { state.websiteModelRefreshIntentsForTesting.contains { $0.provider == "gemini" && $0.retryBlocked } }
            } else { try await waitUntil { held != nil } }
            _ = try browser.prepareToolMutation(tabID: id, generation: XCTUnwrap(browser.documentGeneration(for: id)))
            held?.resume(returning: Self.choices(beforeProbe ? "chatgpt" : "gemini")); held = nil
            try await waitUntil { !state.websiteModelsRefreshing }
            XCTAssertEqual(observed.filter { $0 == "gemini" }.count, beforeProbe ? 0 : 1)
            XCTAssertEqual(browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
            XCTAssertEqual(browser.humanVerificationRecoveryReports["gemini"]?.phase, .superseded)
            XCTAssertEqual(runtime.submissions, 0)
            XCTAssertEqual(browser.tabs.count, 1)
        }
    }

    func testActiveTaskSuppressesOneHumanEventUntilANewCommittedHumanDocument() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        browser.recordHumanVerificationRequired(provider: "gemini")
        let preferences = isolatedTestPreferences()
        WebsiteModelCatalog.save(WebsiteModelCatalog.providers.flatMap(Self.choices), to: preferences)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        var probes = 0
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
            websiteModelDiscovery: { _ in probes += 1; throw EmbeddedWebModelTransport.Failure.modelUnverified })
        state.refreshWebsiteModelsIfNeeded()
        state.activeTurnTaskIDs.insert("recovery-active-task")
        let (_, view) = try await healthyHumanPage(browser)
        try await waitUntil { browser.humanVerificationRecoveryReports["gemini"]?.phase == .superseded }
        XCTAssertEqual(browser.humanVerificationRecoveryReports["gemini"]?.reason, .taskActive)
        XCTAssertEqual(probes, 0)
        state.activeTurnTaskIDs.removeAll()
        view.navigationDelegate?.webView?(view, didFinish: nil)
        await Task.yield()
        XCTAssertEqual(probes, 0, "Becoming idle is not an automatic retry of a spent human event")
        try await loadHealthyFixture(view)
        try await waitUntil { browser.humanVerificationRecoveryReports["gemini"]?.phase == .blocked }
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(browser.humanVerificationRecoveryReports["gemini"]?.reason, .discoveryFailed)
        XCTAssertNotNil(browser.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertEqual(runtime.submissions, 0)
    }

    func testExplicitRefreshMergedIntoStartupRetainsEveryProvidersRecoveryIntent() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        var chatReads = 0
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: browser,
            websiteModelDiscovery: { provider in
                if provider == "chatgpt" {
                    chatReads += 1
                    if chatReads == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
                }
                return Self.choices(provider)
            })
        var observed: [(String, Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { observed.append(($0, $1)) }
        state.refreshWebsiteModelsIfNeeded()
        try await waitUntil { held != nil }
        let explicit = Task { await state.refreshWebsiteModels() }
        try await waitUntil { state.websiteModelRefreshIntentsForTesting.count == 3 }
        held?.resume(returning: Self.choices("chatgpt")); held = nil
        await explicit.value
        XCTAssertEqual(observed.first?.0, "chatgpt"); XCTAssertEqual(observed.first?.1, false)
        for provider in WebsiteModelCatalog.providers {
            XCTAssertEqual(observed.filter { $0.0 == provider && $0.1 }.count, 1)
        }
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertTrue(browser.savedHumanVerificationProviders.isEmpty)
    }

    func testExplicitManualRefreshSurvivesARevokedPausedAutomaticRecovery() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        browser.recordHumanVerificationRequired(provider: "gemini")
        let checkpoint = browser.savedHumanVerificationCheckpointIDs["gemini"]
        let preferences = isolatedTestPreferences()
        WebsiteModelCatalog.save(WebsiteModelCatalog.providers.flatMap(Self.choices), to: preferences)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        var geminiReads = 0
        let manualChoice = WebsiteModelChoice(provider: "gemini", key: "manual-fixture", label: "Manual Gemini choice")
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
            websiteModelDiscovery: { provider in
                if provider == "gemini" {
                    geminiReads += 1
                    if geminiReads == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
                    return [manualChoice]
                }
                return Self.choices(provider)
            })
        var observed: [(String, Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { observed.append(($0, $1)) }
        state.refreshWebsiteModelsIfNeeded()
        let (id, _) = try await healthyHumanPage(browser)
        try await waitUntil { held != nil }
        let manual = Task { await state.refreshWebsiteModels() }
        try await waitUntil { state.websiteModelRefreshIntentsForTesting.count == 3 }
        _ = try browser.prepareToolMutation(tabID: id, generation: XCTUnwrap(browser.documentGeneration(for: id)))
        held?.resume(returning: Self.choices("gemini")); held = nil
        await manual.value
        XCTAssertEqual(observed.map { $0.0 }, ["gemini", "chatgpt", "gemini", "claude"])
        XCTAssertTrue(observed.allSatisfy { $0.1 }, "The explicit all-provider refresh retains its own per-provider recovery flags")
        XCTAssertEqual(geminiReads, 2, "Revoking automatic recovery cannot drop the queued manual Gemini request")
        XCTAssertTrue(state.websiteModelChoices.contains(manualChoice))
        XCTAssertEqual(browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint, "Injected discovery cannot clear a real checkpoint")
        XCTAssertEqual(runtime.submissions, 0)
    }

    func testCoalescedHumanCandidateIsSpentWithRecoveryInProgressForActiveOrPendingAutomaticProbe() async throws {
        for pending in [true, false] {
            let browser = EmbeddedBrowserSession(persistent: false)
            defer { browser.shutdown() }
            browser.recordHumanVerificationRequired(provider: "gemini")
            let preferences = isolatedTestPreferences()
            if !pending { WebsiteModelCatalog.save(WebsiteModelCatalog.providers.flatMap(Self.choices), to: preferences) }
            var held: CheckedContinuation<[WebsiteModelChoice], Error>?
            var geminiReads = 0
            let state = AppState(tasks: [], preferences: preferences, browserSession: browser,
                websiteModelDiscovery: { provider in
                    if provider == "gemini" { geminiReads += 1 }
                    if provider == (pending ? "chatgpt" : "gemini") {
                        return try await withCheckedThrowingContinuation { held = $0 }
                    }
                    return Self.choices(provider)
                })
            state.refreshWebsiteModelsIfNeeded()
            if pending { try await waitUntil { held != nil } }
            let (_, view) = try await healthyHumanPage(browser)
            if pending {
                try await waitUntil { state.websiteModelRefreshIntentsForTesting.contains { $0.provider == "gemini" && $0.retryBlocked } }
            } else { try await waitUntil { held != nil } }
            let previousID = try XCTUnwrap(browser.humanVerificationRecoveryReports["gemini"]?.recoveryID)
            try await loadHealthyFixture(view)
            try await waitUntil {
                let report = browser.humanVerificationRecoveryReports["gemini"]
                return report?.recoveryID != previousID && report?.phase == .superseded
            }
            XCTAssertEqual(browser.humanVerificationRecoveryReports["gemini"]?.reason, .recoveryInProgress)
            held?.resume(returning: Self.choices(pending ? "chatgpt" : "gemini")); held = nil
            try await waitUntil { !state.websiteModelsRefreshing }
            XCTAssertEqual(geminiReads, pending ? 0 : 1)
            XCTAssertEqual(browser.humanVerificationRecoveryReports["gemini"]?.phase, .superseded)
            XCTAssertEqual(browser.humanVerificationRecoveryReports["gemini"]?.reason, .recoveryInProgress)
            XCTAssertNotNil(browser.savedHumanVerificationCheckpointIDs["gemini"])
        }
    }

    private static func choices(_ provider: String) -> [WebsiteModelChoice] {
        provider == "chatgpt" ? [.init(provider: provider, key: "chat/latest/instant", label: "Instant")]
            : [.init(provider: provider, key: "fixture-choice", label: "Fixture choice")]
    }

    private func healthyHumanPage(_ browser: EmbeddedBrowserSession) async throws -> (UUID, WKWebView) {
        let id = try browser.createTab(), view = try XCTUnwrap(browser.webView(for: id))
        try await loadHealthyFixture(view)
        return (id, view)
    }

    private func loadHealthyFixture(_ view: WKWebView) async throws {
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        view.loadHTMLString("<!doctype html><p>Local healthy human fixture</p>", baseURL: url)
        try await waitUntil { !view.isLoading && view.url == url }
        await Task.yield()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The deterministic local recovery fixture did not settle")
    }

}

@MainActor
private final class EmbeddedConfigurationRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Embedded startup fixture"
    let browser: EmbeddedBrowserSession
    var operations: [String] = []
    var transport: (any WebModelTransport)?
    var browserWasLiveDuringShutdown = false
    var submissions = 0

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
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws { submissions += 1 }
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
    func shutdown() async -> RuntimeShutdownReport {
        operations.append("shutdown")
        browserWasLiveDuringShutdown = !browser.tabs.isEmpty
        return RuntimeShutdownReport(issues: [])
    }
}

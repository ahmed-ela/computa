import AppKit
import WebKit
import XCTest
@testable import Computa

@MainActor
final class AppStateEmbeddedWebModelTests: XCTestCase {
    func testKimiProfileVerificationReportsItsActualOutcomeAndSwitchesOnlyWhenIdle() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        _ = try browser.openKimiModelSignInForTesting()
        let profile = try XCTUnwrap(browser.kimiModelProfileID)
        var signedIn = false
        var discoveries: [String] = []
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: browser,
            websiteModelDiscovery: { provider in
                discoveries.append(provider)
                guard signedIn else { throw EmbeddedWebModelTransport.Failure.signInRequired }
                return Self.choices(provider)
            })

        await state.verifyKimiModelSignIn()
        let instructions = "Sign in on the Kimi sign-in tab, then choose Verify Kimi sign-in from Model sign-ins."
        XCTAssertEqual(state.kimiModelSignInMessage, instructions)
        XCTAssertEqual(state.websiteModelsError, "Kimi: " + instructions)
        signedIn = true
        await state.verifyKimiModelSignIn()
        XCTAssertEqual(discoveries, ["kimi", "kimi"])
        XCTAssertEqual(state.kimiModelSignInMessage, "Kimi sign-in verified for this profile.")
        XCTAssertNil(state.websiteModelsError)

        state.activeTurnTaskIDs.insert("fixture-running")
        XCTAssertFalse(state.canConfigureKimiProfile)
        state.useSharedKimiModelProfile()
        XCTAssertEqual(browser.kimiModelProfileID, profile)
        state.activeTurnTaskIDs.remove("fixture-running")
        state.useSharedKimiModelProfile()
        XCTAssertNil(browser.kimiModelProfileID)
        XCTAssertNil(state.kimiModelSignInMessage)
    }

    func testWebsitePrewarmingFollowsSelectedProviderOnlyAfterRenderHostReadiness() async {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let preferences = isolatedTestPreferences()
        preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID")
        WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
        WebsiteModeCatalog.save(Self.modes, to: preferences)
        let instant = Self.choices("chatgpt")[0].modelID
        let task = AgentTask(title: "Prewarm fixture", summary: "", status: .draft,
            workspace: "No workspace selected", model: instant)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        let state = AppState(tasks: [task], runtime: runtime, preferences: preferences, browserSession: browser)
        let local = state.defaultModel
        var enabled: [Bool] = []
        var preserved: [Bool] = []
        state.setWebsitePrewarmingObserverForTesting { enabled.append($0); preserved.append($1) }
        state.selectTask(task.id)
        XCTAssertEqual(enabled, [false], "No provider load before the render host is attached")
        state.refreshWebsiteModelsIfNeeded()
        XCTAssertEqual(enabled.last, true)
        let beforeDemand = enabled.count
        state.prepareWebsiteModel(taskID: "foreign-task")
        XCTAssertEqual(enabled.count, beforeDemand)
        state.prepareWebsiteModel(taskID: task.id)
        XCTAssertEqual(enabled.count, beforeDemand + 1)
        XCTAssertEqual(enabled.last, true)
        state.prepareWebsiteModel(taskID: task.id)
        XCTAssertEqual(enabled.count, beforeDemand + 1, "Native demand hints are throttled independently of the web client")
        XCTAssertTrue(state.setTaskModel(local, taskID: task.id))
        XCTAssertEqual(enabled.last, false, "Changing away from ChatGPT releases its unused page")
        XCTAssertTrue(state.setTaskModel(instant, taskID: task.id))
        XCTAssertEqual(enabled.last, true)
        state.replaceTasks(with: [])
        XCTAssertEqual(enabled.last, false)
        XCTAssertTrue(state.setDefaultModel(instant))
        XCTAssertEqual(enabled.last, true)
        state.createTask()
        XCTAssertEqual(enabled.last, true)
        _ = await state.shutdownRuntime()
        XCTAssertEqual(enabled.last, false)
        XCTAssertFalse(preserved.contains(true), "Only creating a non-ChatGPT draft can preserve an unused page")
        XCTAssertTrue(browser.tabs.isEmpty)
    }

    func testOnlyNewDraftSoftPausesWebsitePrewarmingWithUnchangedLocalDefault() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let preferences = isolatedTestPreferences()
        preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID")
        WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
        WebsiteModeCatalog.save(Self.modes, to: preferences)
        let instant = Self.choices("chatgpt")[0].modelID
        let websiteTask = AgentTask(title: "Website fixture", summary: "", status: .draft,
            workspace: "No workspace selected", model: instant)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        let state = AppState(tasks: [websiteTask], runtime: runtime, preferences: preferences, browserSession: browser)
        let local = state.defaultModel
        XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: local))
        let localTask = AgentTask(title: "Existing local fixture", summary: "", status: .draft,
            workspace: "No workspace selected", model: local)
        state.replaceTasks(with: [websiteTask, localTask])
        var observations: [[Bool]] = []
        state.setWebsitePrewarmingObserverForTesting { observations.append([$0, $1]) }
        state.selectTask(websiteTask.id)
        state.refreshWebsiteModelsIfNeeded()
        XCTAssertEqual(observations.last, [true, false])

        state.createTask()
        let newDraftID = try XCTUnwrap(state.selectedTaskID)
        XCTAssertEqual(state.selectedTask?.model, local)
        XCTAssertEqual(state.defaultModel, local, "New task must keep the user's default model")
        XCTAssertEqual(observations.last, [false, true])
        XCTAssertTrue(state.setTaskModel(instant, taskID: newDraftID))
        XCTAssertEqual(observations.last, [true, false])
        XCTAssertTrue(state.setTaskModel(local, taskID: newDraftID))
        XCTAssertEqual(observations.last, [false, false], "An explicit provider change is a hard deselection")
        state.selectTask(websiteTask.id)
        XCTAssertEqual(observations.last, [true, false])
        state.selectTask(localTask.id)
        XCTAssertEqual(observations.last, [false, false], "Selecting an existing local task cannot preserve the page")
        state.selectTask(newDraftID)
        XCTAssertEqual(observations.last, [false, false], "Re-selecting a draft is an explicit task selection")
        XCTAssertTrue(state.setDefaultModel(instant))
        XCTAssertEqual(observations.last, [false, false], "Changing the default is not new-draft preservation")
        _ = await state.shutdownRuntime()
    }

    func testNewDraftWebsitePrewarmingPreservationRequiresReadinessAndStopsAtShutdown() async {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let preferences = isolatedTestPreferences()
        preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID")
        WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
        WebsiteModeCatalog.save(Self.modes, to: preferences)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser)
        XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: state.defaultModel))
        var observations: [[Bool]] = []
        state.setWebsitePrewarmingObserverForTesting { observations.append([$0, $1]) }

        state.createTask()
        XCTAssertEqual(observations.last, [false, false], "No unused page may be retained before render-host readiness")
        state.refreshWebsiteModelsIfNeeded()
        XCTAssertEqual(observations.last, [false, false], "Readiness with a local model is not a new-draft hint")
        state.createTask()
        XCTAssertEqual(observations.last, [false, true])
        _ = await state.shutdownRuntime()
        XCTAssertEqual(observations.last, [false, false])
        state.createTask()
        XCTAssertEqual(observations.last, [false, false], "A new draft cannot preserve a page after shutdown")
        XCTAssertTrue(browser.tabs.isEmpty)
    }

    func testMaintenanceLaunchCannotStartRuntimeOrIndependentWebsiteDiscovery() async {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        var discovered: [String] = []
        var maintenanceRuns = 0
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences(), browserSession: browser,
            websiteModelDiscovery: { provider in discovered.append(provider); return Self.choices(provider) }, websiteModeDiscovery: { provider in
                XCTAssertEqual(provider, "deepseek")
                discovered.append(provider)
                return Self.modes
            },
            cookieMaintenanceOnlyLaunch: true,
            cookieMaintenanceRunner: { _ in maintenanceRuns += 1 })
        state.refreshWebsiteModelsIfNeeded()
        await state.refreshWebsiteModels()
        await state.startRuntime()
        XCTAssertTrue(runtime.operations.isEmpty)
        XCTAssertEqual(maintenanceRuns, 1)
        XCTAssertTrue(discovered.isEmpty)
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertFalse(state.canRefreshWebsiteModels)
        XCTAssertEqual(state.connectionState,
            .failed(message: "Browser maintenance launch finished. Restart Computa to connect the runtime."))
    }

    func testMaintenanceLaunchWithNoRuntimeStillCannotStartWebsiteDiscovery() async {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        var discovered: [String] = []
        var maintenanceRuns = 0
        let state = AppState(tasks: [], runtime: nil, preferences: isolatedTestPreferences(), browserSession: browser,
            websiteModelDiscovery: { provider in discovered.append(provider); return Self.choices(provider) }, websiteModeDiscovery: { provider in
                XCTAssertEqual(provider, "deepseek")
                discovered.append(provider)
                return Self.modes
            },
            cookieMaintenanceOnlyLaunch: true,
            cookieMaintenanceRunner: { _ in maintenanceRuns += 1 })
        state.refreshWebsiteModelsIfNeeded()
        await state.refreshWebsiteModels()
        await state.startRuntime()
        XCTAssertTrue(discovered.isEmpty)
        XCTAssertEqual(maintenanceRuns, 0)
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertFalse(state.canRefreshWebsiteModels)
    }

    func testEmbeddedTransportIsConfiguredBeforeLoadingSavedTasksWithoutChrome() async {
        let browser = EmbeddedBrowserSession(persistent: false)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences(), browserSession: browser)
        await state.startRuntime()
        XCTAssertEqual(runtime.operations, ["configure", "load"])
        XCTAssertNotNil(runtime.transport)
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

    func testNormalDeepSeekHumanLandingAutomaticallyClearsOnlyItsActualSignInGateWithoutSending() async throws {
        let fixture = DeepSeekSignInRecoveryFixture(); defer { fixture.shutdown() }
        let runtime = EmbeddedConfigurationRuntime(browser: fixture.browser)
        let state = AppState(tasks: [], runtime: runtime, preferences: deepSeekRecoveryPreferences(), browserSession: fixture.browser)
        state.refreshWebsiteModelsIfNeeded()
        let gate = try await seedDeepSeekSignInGate(state, fixture: fixture)
        fixture.signIn = false
        var refreshes: [(String, Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { refreshes.append(($0, $1)) }
        let (humanID, _) = try await deepSeekHumanPage(fixture.browser, url: "https://chat.deepseek.com/")
        try await waitUntil {
            state.websiteTransportForTesting.didClearSignInRecoveryGate(gate) && !state.websiteModelsRefreshing
        }
        XCTAssertEqual(refreshes.map { $0.0 }, ["deepseek"])
        XCTAssertEqual(refreshes.map { $0.1 }, [true])
        XCTAssertEqual(state.websiteModeChoices, Self.modes)
        XCTAssertEqual(fixture.modelLoads, 2, "One auth observation and one read-only recovery discovery")
        XCTAssertEqual(fixture.browser.tabs.map(\.id), [humanID], "Both private discovery views have physically closed")
        XCTAssertNotNil(fixture.browser.webView(for: humanID))
        XCTAssertNil(state.websiteTransportForTesting.signInRecoveryGate(provider: "deepseek"))
        XCTAssertEqual(runtime.submissions, 0)
        _ = await state.shutdownRuntime()
    }

    func testDeepSeekHumanLandingWithoutSignInGateOrOnForeignRouteCannotScheduleDiscovery() async throws {
        let fixture = DeepSeekSignInRecoveryFixture(); defer { fixture.shutdown() }
        let runtime = EmbeddedConfigurationRuntime(browser: fixture.browser)
        var probes: [String] = []
        let state = AppState(tasks: [], runtime: runtime, preferences: deepSeekRecoveryPreferences(), browserSession: fixture.browser,
            websiteModeDiscovery: { provider in probes.append(provider); return Self.modes })
        state.refreshWebsiteModelsIfNeeded()
        let forwarding = fixture.browser.onProviderSignInRecoveryCandidate
        var candidates: [EmbeddedBrowserSession.ProviderSignInRecoveryCandidate] = []
        fixture.browser.onProviderSignInRecoveryCandidate = { candidate in candidates.append(candidate); forwarding?(candidate) }
        let (id, view) = try await deepSeekHumanPage(fixture.browser, url: "https://chat.deepseek.com/")
        try await waitUntil { candidates.count == 1 }
        XCTAssertTrue(probes.isEmpty)
        XCTAssertNil(state.websiteTransportForTesting.signInRecoveryGate(provider: "deepseek"))
        let oldCandidate = try XCTUnwrap(candidates.last)
        try await loadDeepSeekHumanFixture(view, url: "https://chat.deepseek.com/sign_in")
        XCTAssertFalse(fixture.browser.isProviderSignInRecoveryCandidateCurrent(oldCandidate))
        try await loadDeepSeekHumanFixture(view, url: "https://chat.deepseek.com/a/chat/s/foreign")
        try await loadDeepSeekHumanFixture(view, url: "https://example.test/")
        try await loadDeepSeekHumanFixture(view, url: "https://chat.deepseek.com/")
        try await waitUntil { candidates.count == 2 }
        XCTAssertEqual(candidates.map(\.provider), ["deepseek", "deepseek"])
        XCTAssertTrue(probes.isEmpty, "A committed normal page is not a saved sign-in gate")
        let gate = try await seedDeepSeekSignInGate(state, fixture: fixture)
        fixture.signIn = false
        let modes = try await state.websiteTransportForTesting.discoverModes(provider: "deepseek", retryBlocked: true)
        XCTAssertEqual(Set(modes.map(\.key)), Set(Self.modes.map(\.key)))
        XCTAssertTrue(state.websiteTransportForTesting.didClearSignInRecoveryGate(gate))
        XCTAssertEqual(candidates.count, 2, "A healthy model-owned root discovery cannot mint a normal-human event")
        XCTAssertTrue(probes.isEmpty)
        XCTAssertNotNil(fixture.browser.webView(for: id))
        XCTAssertEqual(runtime.submissions, 0)
        _ = await state.shutdownRuntime()
    }

    func testDeepSeekSignInRecoveryCoalescesBusyHumanEventAndDispatchesOnceWhenIdle() async throws {
        let fixture = DeepSeekSignInRecoveryFixture(); defer { fixture.shutdown() }
        let runtime = EmbeddedConfigurationRuntime(browser: fixture.browser)
        var probes: [String] = []
        var held: CheckedContinuation<[WebsiteModeChoice], Error>?
        let state = AppState(tasks: [], runtime: runtime, preferences: deepSeekRecoveryPreferences(), browserSession: fixture.browser,
            websiteModeDiscovery: { provider in
                probes.append(provider)
                return try await withCheckedThrowingContinuation { held = $0 }
            })
        state.refreshWebsiteModelsIfNeeded()
        let gate = try await seedDeepSeekSignInGate(state, fixture: fixture)
        state.activeTurnTaskIDs.insert("busy-native-turn")
        let forwarding = fixture.browser.onProviderSignInRecoveryCandidate
        var observed: [EmbeddedBrowserSession.ProviderSignInRecoveryCandidate] = []
        fixture.browser.onProviderSignInRecoveryCandidate = { candidate in observed.append(candidate); forwarding?(candidate) }
        var refreshes: [(String, Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { refreshes.append(($0, $1)) }
        let (_, view) = try await deepSeekHumanPage(fixture.browser, url: "https://chat.deepseek.com/")
        try await waitUntil { observed.count == 1 }
        let candidate = try XCTUnwrap(observed.first)
        XCTAssertTrue(state.providerSignInRecoveryPendingForTesting)
        forwarding?(candidate); forwarding?(candidate)
        view.navigationDelegate?.webView?(view, didFinish: nil)
        XCTAssertTrue(probes.isEmpty)
        XCTAssertTrue(state.websiteTransportForTesting.isSignInRecoveryGateCurrent(gate))
        state.activeTurnTaskIDs.removeAll()
        try await waitUntil { held != nil }
        XCTAssertEqual(probes, ["deepseek"])
        XCTAssertEqual(refreshes.map { $0.0 }, ["deepseek"])
        XCTAssertEqual(refreshes.map { $0.1 }, [true])
        held?.resume(throwing: EmbeddedWebModelTransport.Failure.modelUnverified); held = nil
        try await waitUntil { !state.websiteModelsRefreshing }
        view.navigationDelegate?.webView?(view, didFinish: nil)
        await Task.yield()
        XCTAssertEqual(probes, ["deepseek"], "The spent document cannot auto-retry a failed recovery")
        XCTAssertTrue(state.websiteTransportForTesting.isSignInRecoveryGateCurrent(gate))
        XCTAssertEqual(runtime.submissions, 0)
        _ = await state.shutdownRuntime()
    }

    func testDeepSeekPendingSignInRecoveryDropsChangedDocumentOrNewerGateBeforeIdle() async throws {
        for replaceGate in [false, true] {
            let fixture = DeepSeekSignInRecoveryFixture(); defer { fixture.shutdown() }
            let runtime = EmbeddedConfigurationRuntime(browser: fixture.browser)
            var probes: [String] = []
            let state = AppState(tasks: [], runtime: runtime, preferences: deepSeekRecoveryPreferences(), browserSession: fixture.browser,
                websiteModeDiscovery: { provider in probes.append(provider); throw EmbeddedWebModelTransport.Failure.modelUnverified })
            state.refreshWebsiteModelsIfNeeded()
            let oldGate = try await seedDeepSeekSignInGate(state, fixture: fixture)
            state.activeTurnTaskIDs.insert("busy-native-turn")
            let forwarding = fixture.browser.onProviderSignInRecoveryCandidate
            var candidate: EmbeddedBrowserSession.ProviderSignInRecoveryCandidate?
            fixture.browser.onProviderSignInRecoveryCandidate = { candidate = $0; forwarding?($0) }
            let (_, view) = try await deepSeekHumanPage(fixture.browser, url: "https://chat.deepseek.com/")
            try await waitUntil { candidate != nil }
            XCTAssertTrue(state.providerSignInRecoveryPendingForTesting)
            if replaceGate {
                fixture.signIn = false
                let modes = try await state.websiteTransportForTesting.discoverModes(provider: "deepseek", retryBlocked: true)
                XCTAssertEqual(modes, Self.modes)
                XCTAssertTrue(state.websiteTransportForTesting.didClearSignInRecoveryGate(oldGate))
                fixture.signIn = true
                _ = try await seedDeepSeekSignInGate(state, fixture: fixture)
                XCTAssertFalse(state.websiteTransportForTesting.isSignInRecoveryGateCurrent(oldGate))
                XCTAssertNotNil(state.websiteTransportForTesting.signInRecoveryGate(provider: "deepseek"))
            } else {
                try await loadDeepSeekHumanFixture(view, url: "https://example.test/")
                XCTAssertFalse(fixture.browser.isProviderSignInRecoveryCandidateCurrent(try XCTUnwrap(candidate)))
            }
            state.activeTurnTaskIDs.removeAll()
            try await waitUntil { !state.providerSignInRecoveryPendingForTesting }
            XCTAssertTrue(probes.isEmpty, "An old event cannot borrow a newer gate or document")
            XCTAssertEqual(runtime.submissions, 0)
            _ = await state.shutdownRuntime()
        }
    }

    func testInjectedDeepSeekRecoverySuccessOrFailureCannotClearSavedGateOrPublishCatalog() async throws {
        for fail in [false, true] {
            let fixture = DeepSeekSignInRecoveryFixture(); defer { fixture.shutdown() }
            let runtime = EmbeddedConfigurationRuntime(browser: fixture.browser)
            var probes = 0
            var held: CheckedContinuation<[WebsiteModeChoice], Error>?
            let state = AppState(tasks: [], runtime: runtime, preferences: deepSeekRecoveryPreferences(), browserSession: fixture.browser,
                websiteModeDiscovery: { provider in
                    XCTAssertEqual(provider, "deepseek"); probes += 1
                    return try await withCheckedThrowingContinuation { held = $0 }
                })
            state.refreshWebsiteModelsIfNeeded()
            let oldModes = state.websiteModeChoices
            let gate = try await seedDeepSeekSignInGate(state, fixture: fixture)
            let (_, view) = try await deepSeekHumanPage(fixture.browser, url: "https://chat.deepseek.com/")
            try await waitUntil { held != nil }
            view.navigationDelegate?.webView?(view, didFinish: nil)
            if fail { held?.resume(throwing: EmbeddedWebModelTransport.Failure.modelUnverified) }
            else { held?.resume(returning: Self.modes) }
            held = nil
            try await waitUntil { !state.websiteModelsRefreshing }
            XCTAssertEqual(probes, 1)
            XCTAssertEqual(state.websiteModeChoices, oldModes)
            XCTAssertTrue(state.websiteTransportForTesting.isSignInRecoveryGateCurrent(gate),
                "Injected catalog values are not authenticated cleanup/gate-clearance proof")
            XCTAssertEqual(runtime.submissions, 0)
            _ = await state.shutdownRuntime()
        }
    }

    private func deepSeekRecoveryPreferences() -> UserDefaults {
        let preferences = isolatedTestPreferences()
        preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID")
        WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
        WebsiteModeCatalog.save(Self.modes, to: preferences)
        return preferences
    }

    private func seedDeepSeekSignInGate(_ state: AppState, fixture: DeepSeekSignInRecoveryFixture) async throws -> EmbeddedWebModelTransport.SignInRecoveryGate {
        let loads = fixture.modelLoads
        do {
            _ = try await state.websiteTransportForTesting.discoverModes(provider: "deepseek")
            XCTFail("The actual local sign-in document must reject discovery")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
        let gate = try XCTUnwrap(state.websiteTransportForTesting.signInRecoveryGate(provider: "deepseek"))
        XCTAssertTrue(state.websiteTransportForTesting.isSignInRecoveryGateCurrent(gate))
        XCTAssertTrue(state.websiteTransportForTesting.canRecoverSignInGate(gate))
        XCTAssertEqual(fixture.modelLoads, loads + 1, "The gate came from one actual intercepted local discovery")
        return gate
    }

    private func deepSeekHumanPage(_ browser: EmbeddedBrowserSession, url: String) async throws -> (UUID, WKWebView) {
        let id = try browser.createTab(), view = try XCTUnwrap(browser.webView(for: id))
        try await loadDeepSeekHumanFixture(view, url: url)
        return (id, view)
    }

    private func loadDeepSeekHumanFixture(_ view: WKWebView, url raw: String) async throws {
        let url = try XCTUnwrap(URL(string: raw))
        view.loadHTMLString("<!doctype html><p>Local normal human DeepSeek fixture</p>", baseURL: url)
        try await waitUntil { !view.isLoading && view.url == url }
        await Task.yield()
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
            }, websiteModeDiscovery: { provider in
                XCTAssertEqual(provider, "deepseek")
                return Self.modes
            })
        var observed: [(String, Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { observed.append(($0, $1)) }
        state.refreshWebsiteModelsIfNeeded()
        try await waitUntil { held != nil }
        _ = try await healthyHumanPage(browser)
        try await waitUntil { state.websiteModelRefreshIntentsForTesting.contains { $0.provider == "gemini" && $0.retryBlocked } }
        held?.resume(returning: Self.choices("chatgpt")); held = nil
        try await waitUntil { !state.websiteModelsRefreshing }
        XCTAssertEqual(observed.map { $0.0 }, WebsiteModelCatalog.discoveryProviders)
        XCTAssertEqual(observed.map { $0.1 }, WebsiteModelCatalog.discoveryProviders.map { $0 == "gemini" },
                       "A Gemini intent cannot widen another provider's startup gate")
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
            // Isolate revocation from unrelated missing-provider demand. The
            // before-probe case deliberately holds selected ChatGPT's refresh;
            // the during-probe case has only the human Gemini recovery intent.
            WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
            WebsiteModeCatalog.save(Self.modes, to: preferences)
            if !beforeProbe { preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID") }
            let runtime = EmbeddedConfigurationRuntime(browser: browser)
            var held: CheckedContinuation<[WebsiteModelChoice], Error>?
            let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
                websiteModelDiscovery: { provider in
                    if provider == (beforeProbe ? "chatgpt" : "gemini") {
                        return try await withCheckedThrowingContinuation { held = $0 }
                    }
                    return Self.choices(provider)
                }, websiteModeDiscovery: { provider in
                    XCTAssertEqual(provider, "deepseek")
                    return Self.modes
                })
            var observed: [String] = []
            state.setWebsiteModelRefreshObserverForTesting { provider, _ in observed.append(provider) }
            XCTAssertEqual(state.websiteModelChoices.count, namedWebsiteModelProviders.count)
            XCTAssertEqual(state.websiteModeChoices, Self.modes)
            XCTAssertEqual(WebsiteModelCatalog.selection(for: state.defaultModel)?.provider, beforeProbe ? "chatgpt" : nil)
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
        // This fixture exercises human recovery, not selected-provider startup.
        preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID")
        WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
        WebsiteModeCatalog.save(Self.modes, to: preferences)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        var probes = 0
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
            websiteModelDiscovery: { _ in probes += 1; throw EmbeddedWebModelTransport.Failure.modelUnverified }, websiteModeDiscovery: { provider in
                XCTAssertEqual(provider, "deepseek")
                return Self.modes
            })
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
            }, websiteModeDiscovery: { provider in
                XCTAssertEqual(provider, "deepseek")
                return Self.modes
            })
        var observed: [(String, Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { observed.append(($0, $1)) }
        state.refreshWebsiteModelsIfNeeded()
        try await waitUntil { held != nil }
        let explicit = Task { await state.refreshWebsiteModels() }
        try await waitUntil { state.websiteModelRefreshIntentsForTesting.count == WebsiteModelCatalog.discoveryProviders.count }
        held?.resume(returning: Self.choices("chatgpt")); held = nil
        await explicit.value
        XCTAssertEqual(observed.first?.0, "chatgpt"); XCTAssertEqual(observed.first?.1, false)
        for provider in WebsiteModelCatalog.discoveryProviders {
            XCTAssertEqual(observed.filter { $0.0 == provider && $0.1 }.count, 1)
        }
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertTrue(browser.savedHumanVerificationProviders.isEmpty)
    }

    func testSuccessfulHumanRecoverySatisfiesQueuedScopedManualRefreshWithoutAnotherDiscovery() async throws {
        try await assertSuccessfulRecoverySatisfiesQueuedManualRefresh(allProviders: false)
    }

    func testSuccessfulHumanRecoverySatisfiesOnlyItsProviderInQueuedGlobalManualRefresh() async throws {
        try await assertSuccessfulRecoverySatisfiesQueuedManualRefresh(allProviders: true)
    }

    private func assertSuccessfulRecoverySatisfiesQueuedManualRefresh(allProviders: Bool) async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        browser.recordHumanVerificationRequired(provider: "gemini")
        let preferences = isolatedTestPreferences()
        preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID")
        WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
        WebsiteModeCatalog.save(Self.modes, to: preferences)
        let runtime = EmbeddedConfigurationRuntime(browser: browser)
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        var reads: [String] = []
        let automaticChoice = WebsiteModelChoice(provider: "gemini", key: "automatic-fixture", label: "Automatic Gemini choice")
        let manualChoice = WebsiteModelChoice(provider: "gemini", key: "manual-fixture", label: "Manual Gemini choice")
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
            websiteModelDiscovery: { provider in
                reads.append(provider)
                if provider == "gemini" {
                    if reads.filter({ $0 == "gemini" }).count == 1 {
                        return try await withCheckedThrowingContinuation { held = $0 }
                    }
                    return [manualChoice]
                }
                return Self.choices(provider)
            }, websiteModeDiscovery: { provider in
                XCTAssertEqual(provider, "deepseek")
                reads.append(provider)
                return Self.modes
            })
        state.refreshWebsiteModelsIfNeeded()
        let (humanID, _) = try await healthyHumanPage(browser)
        try await waitUntil { held != nil }
        let manual = Task {
            if allProviders { await state.refreshWebsiteModels() }
            else { await state.refreshWebsiteModels(provider: "gemini") }
        }
        try await waitUntil { state.websiteModelRefreshIntentsForTesting.count == (allProviders ? WebsiteModelCatalog.discoveryProviders.count : 1) }
        // Model production discovery's successful cleanup/checkpoint clearance.
        // This fixture does not grant that authority to injected catalog data.
        browser.clearHumanVerificationRequired(provider: "gemini")
        held?.resume(returning: [automaticChoice]); held = nil
        await manual.value
        XCTAssertEqual(reads, allProviders ? ["gemini"] + WebsiteModelCatalog.discoveryProviders.filter { $0 != "gemini" } : ["gemini"],
                       "An equivalent completed recovery must satisfy the pending same-provider refresh")
        XCTAssertEqual(state.websiteModelChoices.filter { $0.provider == "gemini" }, [automaticChoice])
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), state.websiteModelChoices)
        XCTAssertNil(state.websiteModelsError)
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertNil(browser.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertEqual(browser.humanVerificationRecoveryReports["gemini"]?.phase, .verified)
        XCTAssertEqual(browser.tabs.map(\.id), [humanID])
        XCTAssertEqual(runtime.submissions, 0)

        await state.refreshWebsiteModels(provider: "gemini")
        XCTAssertEqual(reads.filter { $0 == "gemini" }.count, 2,
                       "A later explicit refresh is a new request, not a cached recovery result")
        XCTAssertEqual(state.websiteModelChoices.filter { $0.provider == "gemini" }, [manualChoice])
    }

    func testFailedOrChangedHumanRecoveryCannotConsumeQueuedManualRefresh() async throws {
        for fault in ["discovery", "cleanup", "catalog", "checkpoint", "closed", "toolMutation"] {
            let browser = EmbeddedBrowserSession(persistent: false)
            defer { browser.shutdown() }
            browser.recordHumanVerificationRequired(provider: "gemini")
            let preferences = isolatedTestPreferences()
            preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID")
            WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
            WebsiteModeCatalog.save(Self.modes, to: preferences)
            let runtime = EmbeddedConfigurationRuntime(browser: browser)
            var held: CheckedContinuation<[WebsiteModelChoice], Error>?
            var reads = 0
            let manualChoice = WebsiteModelChoice(provider: "gemini", key: "manual-fixture", label: "Manual Gemini choice")
            let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
                websiteModelDiscovery: { provider in
                    XCTAssertEqual(provider, "gemini")
                    reads += 1
                    if reads == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
                    return [manualChoice]
                }, websiteModeDiscovery: { provider in
                    XCTAssertEqual(provider, "deepseek")
                    return Self.modes
                })
            state.refreshWebsiteModelsIfNeeded()
            let (humanID, _) = try await healthyHumanPage(browser)
            try await waitUntil { held != nil }
            let manual = Task { await state.refreshWebsiteModels(provider: "gemini") }
            try await waitUntil { state.websiteModelRefreshIntentsForTesting.count == 1 }
            if fault == "discovery" || fault == "cleanup" {
                held?.resume(throwing: fault == "cleanup"
                    ? EmbeddedWebModelTransport.Failure.discoveryCleanupFailed
                    : EmbeddedWebModelTransport.Failure.modelUnverified)
            } else {
                browser.clearHumanVerificationRequired(provider: "gemini")
                if fault == "checkpoint" { browser.recordHumanVerificationRequired(provider: "gemini") }
                if fault == "closed" { browser.closeTab(humanID) }
                if fault == "toolMutation" {
                    _ = try browser.prepareToolMutation(tabID: humanID,
                        generation: XCTUnwrap(browser.documentGeneration(for: humanID)))
                }
                held?.resume(returning: fault == "catalog" ? [] : Self.choices("gemini"))
            }
            held = nil
            await manual.value
            XCTAssertEqual(reads, 2, "The manual request must survive \(fault)")
            XCTAssertEqual(state.websiteModelChoices.filter { $0.provider == "gemini" }, [manualChoice])
            XCTAssertEqual(runtime.submissions, 0)
            XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.isEmpty)
            if ["discovery", "cleanup", "checkpoint"].contains(fault) {
                XCTAssertNotNil(browser.savedHumanVerificationCheckpointIDs["gemini"])
            }
        }
    }

    func testExplicitManualRefreshSurvivesARevokedPausedAutomaticRecovery() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        browser.recordHumanVerificationRequired(provider: "gemini")
        let checkpoint = browser.savedHumanVerificationCheckpointIDs["gemini"]
        let preferences = isolatedTestPreferences()
        preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID")
        WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
        WebsiteModeCatalog.save(Self.modes, to: preferences)
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
            }, websiteModeDiscovery: { provider in
                XCTAssertEqual(provider, "deepseek")
                return Self.modes
            })
        var observed: [(String, Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { observed.append(($0, $1)) }
        state.refreshWebsiteModelsIfNeeded()
        let (id, _) = try await healthyHumanPage(browser)
        try await waitUntil { held != nil }
        let manual = Task { await state.refreshWebsiteModels() }
        try await waitUntil { state.websiteModelRefreshIntentsForTesting.count == WebsiteModelCatalog.discoveryProviders.count }
        _ = try browser.prepareToolMutation(tabID: id, generation: XCTUnwrap(browser.documentGeneration(for: id)))
        held?.resume(returning: Self.choices("gemini")); held = nil
        await manual.value
        XCTAssertEqual(observed.map { $0.0 }, ["gemini"] + WebsiteModelCatalog.discoveryProviders)
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
            WebsiteModelCatalog.save(namedWebsiteModelProviders.flatMap(Self.choices), to: preferences)
            WebsiteModeCatalog.save(Self.modes, to: preferences)
            if !pending { preferences.set(LocalModelCatalog.defaultModelID, forKey: "LocalCodex.defaultModelID") }
            var held: CheckedContinuation<[WebsiteModelChoice], Error>?
            var geminiReads = 0
            let state = AppState(tasks: [], preferences: preferences, browserSession: browser,
                websiteModelDiscovery: { provider in
                    if provider == "gemini" { geminiReads += 1 }
                    if provider == (pending ? "chatgpt" : "gemini") {
                        return try await withCheckedThrowingContinuation { held = $0 }
                    }
                    return Self.choices(provider)
                }, websiteModeDiscovery: { provider in
                    XCTAssertEqual(provider, "deepseek")
                    return Self.modes
                })
            XCTAssertEqual(state.websiteModelChoices.count, namedWebsiteModelProviders.count)
            XCTAssertEqual(state.websiteModeChoices, Self.modes)
            XCTAssertEqual(WebsiteModelCatalog.selection(for: state.defaultModel)?.provider, pending ? "chatgpt" : nil)
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

    func testManualRefreshRejectsActiveNativeWorkWithoutQueueingOrChangingCatalog() async {
        let busy: [@MainActor (AppState) -> Void] = [
            { $0.tasks = [.init(id: "running", title: "Active task", summary: "", status: .running,
                               workspace: "/tmp", model: LocalModelCatalog.defaultModelID)] },
            { $0.activeTurnTaskIDs.insert("turn-not-yet-reflected-in-task-status") },
            { $0.compactionStateByTask["compacting"] = .running },
            { $0.resolvingApprovalIDs.insert("approval-being-resolved") },
        ]
        for makeBusy in busy {
            let browser = EmbeddedBrowserSession(persistent: false)
            defer { browser.shutdown() }
            browser.recordHumanVerificationRequired(provider: "gemini")
            let checkpoint = browser.savedHumanVerificationCheckpointIDs["gemini"]
            let preferences = isolatedTestPreferences()
            let cached = namedWebsiteModelProviders.flatMap(Self.choices)
            WebsiteModelCatalog.save(cached, to: preferences)
            WebsiteModeCatalog.save(Self.modes, to: preferences)
            var probes: [String] = []
            let runtime = EmbeddedConfigurationRuntime(browser: browser)
            let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
                websiteModelDiscovery: { provider in probes.append(provider); return Self.choices(provider) }, websiteModeDiscovery: { provider in
                    XCTAssertEqual(provider, "deepseek")
                    probes.append(provider)
                    return Self.modes
                })
            makeBusy(state)
            XCTAssertFalse(WebUISnapshot(state: state).canRefreshWebsiteModels)
            await state.refreshWebsiteModels()
            XCTAssertTrue(probes.isEmpty, "Rejected manual refresh must create no provider probe")
            XCTAssertFalse(state.websiteModelsRefreshing)
            XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.isEmpty)
            XCTAssertEqual(state.websiteModelChoices, cached)
            XCTAssertEqual(browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
            state.activeTurnTaskIDs.removeAll()
            state.compactionStateByTask.removeAll()
            state.resolvingApprovalIDs.removeAll()
            state.tasks = [.init(id: "terminal", title: "Failed or paused persisted goal", summary: "", status: .waiting,
                                 workspace: "/tmp", model: LocalModelCatalog.defaultModelID),
                           .init(id: "completed", title: "Completed chat", summary: "", status: .completed,
                                 workspace: "/tmp", model: LocalModelCatalog.defaultModelID)]
            await Task.yield()
            XCTAssertTrue(probes.isEmpty, "Returning to idle must not replay a rejected refresh")
            XCTAssertTrue(WebUISnapshot(state: state).canRefreshWebsiteModels)
            await state.refreshWebsiteModels()
            XCTAssertEqual(probes, WebsiteModelCatalog.discoveryProviders)
            XCTAssertEqual(browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint,
                           "Injected catalog results never clear a saved checkpoint")
            XCTAssertEqual(runtime.submissions, 0)
        }
    }

    func testManualRefreshAdmittedWhileIdleDropsRemainingProbesIfANativeTurnStarts() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        browser.recordHumanVerificationRequired(provider: "gemini")
        let checkpoint = browser.savedHumanVerificationCheckpointIDs["gemini"]
        let preferences = isolatedTestPreferences()
        let cached = namedWebsiteModelProviders.flatMap(Self.choices)
        WebsiteModelCatalog.save(cached, to: preferences)
        WebsiteModeCatalog.save(Self.modes, to: preferences)
        var probes: [String] = []
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        let replacement = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/high", label: "High")
        let state = AppState(tasks: [], preferences: preferences, browserSession: browser,
            websiteModelDiscovery: { provider in
                probes.append(provider)
                if probes.count == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
                return Self.choices(provider)
            }, websiteModeDiscovery: { provider in
                XCTAssertEqual(provider, "deepseek")
                probes.append(provider)
                return Self.modes
            })
        let refresh = Task { await state.refreshWebsiteModels() }
        try await waitUntil { held != nil }
        XCTAssertTrue(state.websiteModelsRefreshing)
        XCTAssertTrue(state.canRefreshWebsiteModels, "The idle predicate must not depend on its own refresh flag")
        state.activeTurnTaskIDs.insert("new-native-turn")
        XCTAssertFalse(WebUISnapshot(state: state).canRefreshWebsiteModels)
        held?.resume(returning: [replacement]); held = nil
        await refresh.value
        XCTAssertEqual(probes, ["chatgpt"], "An already-started probe may finish, but no later provider may load")
        XCTAssertEqual(state.websiteModelChoices, cached, "Late manual results cannot change the catalog during a turn")
        XCTAssertEqual(browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.isEmpty)
        state.activeTurnTaskIDs.removeAll()
        await Task.yield()
        XCTAssertEqual(probes, ["chatgpt"], "Idle transition must not requeue the skipped probes")
        await state.refreshWebsiteModels()
        XCTAssertEqual(probes, ["chatgpt"] + WebsiteModelCatalog.discoveryProviders)
    }

    private static var modes: [WebsiteModeChoice] { WebsiteModeChoice.DeepSeekMode.allCases.map { .init(deepSeekMode: $0) } }

    private static func choices(_ provider: String) -> [WebsiteModelChoice] {
        provider == "chatgpt" ? [.init(provider: provider, key: "chat/latest/instant", label: "Instant")]
            : provider == "kimi" ? [syntheticKimiChoice]
            : provider == "qwen" ? [syntheticWebsiteChoice(provider: provider, key: "fixture", label: "Fixture")]
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

@MainActor
private final class DeepSeekSignInRecoveryFixture {
    let browser = EmbeddedBrowserSession(persistent: false)
    private let window: Window
    private let host: EmbeddedModelRenderContainer
    var signIn = true
    private(set) var modelLoads = 0

    init() {
        window = Window(contentRect: NSRect(x: 20, y: 20, width: 1024, height: 768), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        host = EmbeddedModelRenderContainer(session: browser)
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.contentView = host; browser.installModelRenderHost(host); window.orderBack(nil)
        browser.setModelViewFactoryForTesting { [unowned self] configuration in
            let view = LocalView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
            view.fixtureURL = URL(string: self.signIn ? "https://chat.deepseek.com/sign_in" : "https://chat.deepseek.com/")!
            view.fixtureHTML = self.signIn ? "<!doctype html><p>Local sign-in gate</p>" : DeepSeekFixturePage.html
            view.onLoad = { [unowned self] in self.modelLoads += 1 }
            return view
        }
    }

    func shutdown() {
        browser.shutdown(); host.detach(); window.orderOut(nil); window.close()
    }

    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class LocalView: WKWebView {
        var fixtureURL: URL!
        var fixtureHTML = ""
        var onLoad: (() -> Void)?
        override func load(_ request: URLRequest) -> WKNavigation? {
            onLoad?()
            return super.loadHTMLString(fixtureHTML, baseURL: fixtureURL)
        }
    }
}

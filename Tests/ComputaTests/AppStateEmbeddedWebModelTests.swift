import WebKit
import XCTest
@testable import Computa

@MainActor
final class AppStateEmbeddedWebModelTests: XCTestCase {
    func testWebsitePrewarmingFollowsSelectedProviderOnlyAfterRenderHostReadiness() async {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let preferences = isolatedTestPreferences()
        WebsiteModelCatalog.save(WebsiteModelCatalog.providers.flatMap(Self.choices), to: preferences)
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
        WebsiteModelCatalog.save(WebsiteModelCatalog.providers.flatMap(Self.choices), to: preferences)
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
        WebsiteModelCatalog.save(WebsiteModelCatalog.providers.flatMap(Self.choices), to: preferences)
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
            websiteModelDiscovery: { provider in discovered.append(provider); return Self.choices(provider) },
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
            websiteModelDiscovery: { provider in discovered.append(provider); return Self.choices(provider) },
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
            let cached = WebsiteModelCatalog.providers.flatMap(Self.choices)
            WebsiteModelCatalog.save(cached, to: preferences)
            var probes: [String] = []
            let runtime = EmbeddedConfigurationRuntime(browser: browser)
            let state = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser,
                websiteModelDiscovery: { provider in probes.append(provider); return Self.choices(provider) })
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
            XCTAssertEqual(probes, WebsiteModelCatalog.providers)
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
        let cached = WebsiteModelCatalog.providers.flatMap(Self.choices)
        WebsiteModelCatalog.save(cached, to: preferences)
        var probes: [String] = []
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        let replacement = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/high", label: "High")
        let state = AppState(tasks: [], preferences: preferences, browserSession: browser,
            websiteModelDiscovery: { provider in
                probes.append(provider)
                if probes.count == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
                return Self.choices(provider)
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
        XCTAssertEqual(probes, ["chatgpt"] + WebsiteModelCatalog.providers)
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

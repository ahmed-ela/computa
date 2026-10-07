import Foundation
import XCTest
@testable import Computa

@MainActor
final class WebsiteModelStateTests: XCTestCase {
    func testStartupUsesCompleteCachedCatalogWithoutDiscovery() async {
        let preferences = isolatedTestPreferences()
        let cached = WebsiteModelCatalog.providers.map {
            WebsiteModelChoice(provider: $0, key: "cached", label: "Cached")
        }
        WebsiteModelCatalog.save(cached, to: preferences)
        var calls: [String] = []
        let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
            calls.append(provider)
            return [WebsiteModelChoice(provider: provider, key: "unexpected", label: "Unexpected")]
        })

        state.refreshWebsiteModelsIfNeeded()
        state.refreshWebsiteModelsIfNeeded()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(state.websiteModelChoices, cached)
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertNil(state.websiteModelsError)
    }

    func testStartupDiscoversOnlyMissingProvidersOnce() async {
        let preferences = isolatedTestPreferences()
        let cached = WebsiteModelChoice(provider: "chatgpt", key: "cached", label: "Cached")
        WebsiteModelCatalog.save([cached], to: preferences)
        let ledger = WebsiteDiscoveryLedger()
        let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
            try await ledger.discover(provider)
        })

        state.refreshWebsiteModelsIfNeeded()
        state.refreshWebsiteModelsIfNeeded()
        await waitForDiscovery { ledger.calls.count == 2 && !state.websiteModelsRefreshing }
        XCTAssertEqual(ledger.calls, ["gemini", "claude"])
        XCTAssertEqual(ledger.maximumActive, 1)
        XCTAssertEqual(state.websiteModelChoices.filter { $0.provider == "chatgpt" }, [cached])
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), state.websiteModelChoices)

        state.refreshWebsiteModelsIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(ledger.calls, ["gemini", "claude"])
    }

    func testExplicitRefreshReplacesAllCachedProviders() async {
        let preferences = isolatedTestPreferences()
        let cached = WebsiteModelCatalog.providers.map {
            WebsiteModelChoice(provider: $0, key: "cached", label: "Cached")
        }
        WebsiteModelCatalog.save(cached, to: preferences)
        let ledger = WebsiteDiscoveryLedger()
        let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
            try await ledger.discover(provider)
        })

        await state.refreshWebsiteModels()

        XCTAssertEqual(ledger.calls, WebsiteModelCatalog.providers)
        XCTAssertEqual(state.websiteModelChoices.map(\.key), ["fixture", "fixture", "fixture"])
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), state.websiteModelChoices)
        XCTAssertNil(state.websiteModelsError)
    }

    func testExplicitRefreshExtendsPartialStartupWithoutDuplicateLoads() async {
        let preferences = isolatedTestPreferences()
        let cached = ["chatgpt", "claude"].map {
            WebsiteModelChoice(provider: $0, key: "cached", label: "Cached")
        }
        WebsiteModelCatalog.save(cached, to: preferences)
        let ledger = WebsiteDiscoveryLedger(delay: .milliseconds(50))
        let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
            try await ledger.discover(provider)
        })

        state.refreshWebsiteModelsIfNeeded()
        await waitForDiscovery { ledger.active == 1 }
        await state.refreshWebsiteModels()

        XCTAssertEqual(ledger.calls, ["gemini", "chatgpt", "claude"])
        XCTAssertEqual(ledger.maximumActive, 1)
        XCTAssertEqual(state.websiteModelChoices.map(\.key), ["fixture", "fixture", "fixture"])
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertNil(state.websiteModelsError)
    }

    private func waitForDiscovery(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Website discovery did not reach the expected state")
    }

    func testDiscoveryPublishesExactChoicesToBothSelectorsAndPersistsThem() async throws {
        let preferences = isolatedTestPreferences()
        let task = AgentTask(id: "fixture-task", title: "Fixture", summary: "", status: .draft, workspace: "/tmp", model: "browser/chatgpt")
        let state = AppState(tasks: [task], preferences: preferences, websiteModelDiscovery: { provider in
            [WebsiteModelChoice(provider: provider, key: "fixture-fast", label: "Fixture Fast"),
             WebsiteModelChoice(provider: provider, key: "fixture-pro", label: "Fixture Pro")]
        })
        await state.refreshWebsiteModels()
        let snapshot = WebUISnapshot(state: state)
        XCTAssertFalse(snapshot.websiteModelsRefreshing)
        XCTAssertNil(snapshot.websiteModelsError)
        XCTAssertEqual(state.websiteModelChoices.count, 6)
        for choice in state.websiteModelChoices {
            XCTAssertTrue(snapshot.modelOptions.contains { $0.id == choice.modelID && $0.label.contains(choice.label) && $0.available == true })
        }
        let choice = try XCTUnwrap(state.websiteModelChoices.first)
        XCTAssertTrue(state.setTaskModel(choice.modelID, taskID: task.id))
        XCTAssertTrue(state.setDefaultModel(choice.modelID))
        let reopened = AppState(tasks: [], preferences: preferences)
        XCTAssertEqual(reopened.defaultModel, choice.modelID)
        XCTAssertEqual(reopened.websiteModelChoices, state.websiteModelChoices)
        XCTAssertEqual(WebUISnapshot(state: reopened).modelOptions.map(\.id), snapshot.modelOptions.map(\.id))
    }

    func testSavedDefaultAndTaskChoiceRemainSelectedWhenNoLongerAvailable() async throws {
        let preferences = isolatedTestPreferences()
        let old = WebsiteModelChoice(provider: "claude", key: "fixture-old", label: "Fixture Old")
        WebsiteModelCatalog.save([old], to: preferences)
        preferences.set(old.modelID, forKey: "LocalCodex.defaultModelID")
        let task = AgentTask(id: "saved-task", title: "Saved", summary: "", status: .completed, workspace: "/tmp", model: old.modelID)
        let state = AppState(tasks: [task], preferences: preferences, websiteModelDiscovery: { provider in
            [WebsiteModelChoice(provider: provider, key: "fixture-new", label: "Fixture New")]
        })
        await state.refreshWebsiteModels()
        XCTAssertEqual(state.defaultModel, old.modelID)
        XCTAssertEqual(state.selectedTask?.model, old.modelID)
        let unavailable = try XCTUnwrap(state.modelOptions.first { $0.id == old.modelID })
        XCTAssertEqual(unavailable.available, false)
        XCTAssertTrue(unavailable.label.contains("Fixture Old"))
        XCTAssertFalse(state.setDefaultModel(old.modelID))
        XCTAssertFalse(state.setTaskModel(old.modelID, taskID: task.id))
        let reopened = AppState(tasks: [task], preferences: preferences)
        XCTAssertEqual(reopened.defaultModel, old.modelID)
        XCTAssertEqual(reopened.modelOptions.first { $0.id == old.modelID }?.available, false)
    }

    func testSavedConcreteDefaultDoesNotFallBackToQwenWithoutCachedMenu() throws {
        let preferences = isolatedTestPreferences()
        let choice = WebsiteModelChoice(provider: "gemini", key: "fixture-pro", label: "Fixture Pro")
        preferences.set(choice.modelID, forKey: "LocalCodex.defaultModelID")
        let state = AppState(tasks: [], preferences: preferences)
        XCTAssertEqual(state.defaultModel, choice.modelID)
        state.createTask()
        XCTAssertEqual(state.selectedTask?.model, choice.modelID)
        XCTAssertEqual(state.modelOptions.first { $0.id == choice.modelID }?.available, false)
        XCTAssertFalse(state.setDefaultModel(WebsiteModelChoice(provider: "gemini", key: "unobserved", label: "Unobserved").modelID))
    }

    func testMalformedSavedWebsiteDefaultStaysVisibleAndCannotBeSubmittedToLocalRoute() throws {
        let preferences = isolatedTestPreferences()
        let malformed = "browser/chatgpt/choice/invalid"
        preferences.set(malformed, forKey: "LocalCodex.defaultModelID")
        let state = AppState(tasks: [], preferences: preferences)
        XCTAssertEqual(state.defaultModel, malformed)
        XCTAssertEqual(state.modelOptions.first { $0.id == malformed }?.available, false)
        XCTAssertFalse(state.setDefaultModel(malformed))
        XCTAssertThrowsError(try CodexAppServerRuntime.Configuration.localQwen.validateSelectedModel(state.defaultModel))
    }

    func testInvalidDiscoveryAndProviderFailureRetainPreviousMenuWithoutPartialPoisoning() async {
        let preferences = isolatedTestPreferences()
        let old = WebsiteModelChoice(provider: "chatgpt", key: "fixture-old", label: "Fixture Old")
        WebsiteModelCatalog.save([old], to: preferences)
        let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
            if provider == "chatgpt" { return [old, old] }
            if provider == "gemini" { throw WebsiteModelCatalog.Failure.invalidChoices }
            return [WebsiteModelChoice(provider: provider, key: "fixture-new", label: "Fixture New")]
        })
        await state.refreshWebsiteModels()
        XCTAssertEqual(state.websiteModelChoices.filter { $0.provider == "chatgpt" }, [old])
        XCTAssertTrue(state.websiteModelChoices.filter { $0.provider == "gemini" }.isEmpty)
        XCTAssertEqual(state.websiteModelChoices.filter { $0.provider == "claude" }.count, 1)
        XCTAssertTrue(state.websiteModelsError?.contains("ChatGPT:") == true)
        XCTAssertTrue(state.websiteModelsError?.contains("Gemini:") == true)
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), state.websiteModelChoices)
    }

    func testConcurrentRefreshRequestsCoalesceAndDiscoveryIsSequential() async {
        let ledger = WebsiteDiscoveryLedger()
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), websiteModelDiscovery: { provider in
            try await ledger.discover(provider)
        })
        let first = Task { await state.refreshWebsiteModels() }
        for _ in 0..<1_000 where !state.websiteModelsRefreshing { await Task.yield() }
        XCTAssertTrue(state.websiteModelsRefreshing)
        let second = Task { await state.refreshWebsiteModels() }
        await first.value
        await second.value
        XCTAssertEqual(ledger.calls, WebsiteModelCatalog.providers)
        XCTAssertEqual(ledger.maximumActive, 1)
        XCTAssertFalse(state.websiteModelsRefreshing)
    }

    func testBusyTaskCannotSwitchToAnotherDiscoveredChoice() async {
        let first = WebsiteModelChoice(provider: "chatgpt", key: "first", label: "First")
        let second = WebsiteModelChoice(provider: "chatgpt", key: "second", label: "Second")
        let preferences = isolatedTestPreferences()
        WebsiteModelCatalog.save([first, second], to: preferences)
        let task = AgentTask(id: "busy-task", title: "Busy", summary: "", status: .running, workspace: "/tmp", model: first.modelID)
        let state = AppState(tasks: [task], preferences: preferences)
        XCTAssertFalse(state.setTaskModel(second.modelID, taskID: task.id))
        state.apply(.taskStatusChanged(taskID: task.id, status: .completed))
        XCTAssertTrue(state.setTaskModel(second.modelID, taskID: task.id))
        XCTAssertEqual(state.selectedTask?.model, second.modelID)
    }

    func testShutdownCancelsDiscoveryBeforeBrowserDisposalAndNeverPublishesLateChoices() async {
        let ledger = WebsiteDiscoveryLedger(delay: .seconds(60))
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), websiteModelDiscovery: { provider in
            try await ledger.discover(provider)
        })
        let refresh = Task { await state.refreshWebsiteModels() }
        for _ in 0..<1_000 where ledger.calls.isEmpty { await Task.yield() }
        XCTAssertFalse(ledger.calls.isEmpty)
        let report = await state.shutdownRuntime()
        await refresh.value
        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(ledger.cancelled)
        XCTAssertTrue(state.websiteModelChoices.isEmpty)
        XCTAssertFalse(state.websiteModelsRefreshing)
        await state.refreshWebsiteModels()
        XCTAssertEqual(ledger.calls, ["chatgpt"])
    }
}

@MainActor
private final class WebsiteDiscoveryLedger {
    var calls: [String] = []
    var maximumActive = 0
    var active = 0
    var cancelled = false
    let delay: Duration
    init(delay: Duration = .milliseconds(20)) { self.delay = delay }
    func discover(_ provider: String) async throws -> [WebsiteModelChoice] {
        calls.append(provider)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        do { try await Task.sleep(for: delay) }
        catch { cancelled = true; throw error }
        return [WebsiteModelChoice(provider: provider, key: "fixture", label: "Fixture")]
    }
}

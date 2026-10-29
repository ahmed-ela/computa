import Foundation
import XCTest
@testable import Computa

@MainActor
final class WebsiteModelStateTests: XCTestCase {
    func testRetiredFamilyDefaultAndIdleChatMigrateToCachedMediumWithoutChangingHistory() throws {
        let preferences = isolatedTestPreferences()
        let latest = WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Latest")
        let other = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let sol = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium")
        let gemini = WebsiteModelChoice(provider: "gemini", key: "Pro", label: "Pro")
        preferences.set(try JSONEncoder().encode([latest, other, sol, gemini]), forKey: WebsiteModelCatalog.preferenceKey)
        preferences.set(latest.modelID, forKey: "LocalCodex.defaultModelID")
        let entry = TimelineEntry(kind: .assistant, title: "Recorded answer", body: "Keep this history", turnID: "historic-turn")
        let old = AgentTask(id: "latest-chat", title: "Existing chat", summary: "", status: .completed, workspace: "/tmp", model: latest.modelID, entries: [entry])
        let state = AppState(tasks: [old], preferences: preferences)

        XCTAssertEqual(state.defaultModel, sol.modelID)
        XCTAssertEqual(preferences.string(forKey: "LocalCodex.defaultModelID"), sol.modelID)
        XCTAssertEqual(state.selectedTask?.model, sol.modelID)
        XCTAssertEqual(state.selectedTask?.entries, [entry])
        XCTAssertFalse(WebUISnapshot(state: state).modelOptions.contains { $0.id == latest.modelID })
        XCTAssertFalse(state.setDefaultModel(latest.modelID))
        XCTAssertFalse(state.setTaskModel(latest.modelID, taskID: old.id))
        XCTAssertEqual(WebsiteModelCatalog.choice(for: latest.modelID), latest)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [other, sol, gemini])

        state.replaceTasks(with: [old])
        XCTAssertEqual(state.selectedTask?.model, sol.modelID)
        XCTAssertEqual(state.selectedTask?.entries, [entry])
        state.apply(.taskUpserted(old))
        XCTAssertEqual(state.selectedTask?.model, sol.modelID)
        XCTAssertEqual(state.selectedTask?.entries, [entry])
    }

    func testRetiredLatestWithoutConcreteCatalogUsesChatGPTWebsiteDefault() {
        let preferences = isolatedTestPreferences()
        let latest = WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Latest")
        preferences.set(latest.modelID, forKey: "LocalCodex.defaultModelID")
        let state = AppState(tasks: [], preferences: preferences)
        XCTAssertEqual(state.defaultModel, "browser/chatgpt")
        state.createTask()
        XCTAssertEqual(state.selectedTask?.model, "browser/chatgpt")
        XCTAssertFalse(state.modelOptions.contains { $0.id == latest.modelID })
    }

    func testBusyRefreshDoesNotDiscoverAndIdleInvalidDiscoveryPreservesVerifiedPreset() async {
        let latest = WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Latest")
        let sol = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium")
        let preferences = isolatedTestPreferences()
        WebsiteModelCatalog.save([sol], to: preferences)
        let saved = preferences.data(forKey: WebsiteModelCatalog.preferenceKey)
        let busy = AgentTask(id: "active-latest", title: "Active", summary: "", status: .running, workspace: "/tmp", model: latest.modelID)
        var calls: [String] = []
        let state = AppState(tasks: [busy], preferences: preferences, websiteModelDiscovery: { provider in
            calls.append(provider)
            return provider == "chatgpt" ? [latest, sol] : [WebsiteModelChoice(provider: provider, key: "fixture", label: "Fixture")]
        })
        await state.refreshWebsiteModels()
        XCTAssertTrue(calls.isEmpty, "Busy manual refresh must not create a provider probe")
        XCTAssertNil(state.websiteModelsError)
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.isEmpty)
        XCTAssertEqual(state.websiteModelChoices, [sol])
        XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), saved)
        XCTAssertFalse(state.modelOptions.contains { $0.id == latest.modelID })
        XCTAssertEqual(state.selectedTask?.model, latest.modelID)
        state.apply(.taskStatusChanged(taskID: busy.id, status: .completed))
        XCTAssertEqual(state.selectedTask?.model, sol.modelID)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(calls.isEmpty, "Returning to idle must not replay the rejected refresh")

        await state.refreshWebsiteModels()

        XCTAssertEqual(calls, WebsiteModelCatalog.providers)
        XCTAssertTrue(state.websiteModelsError?.contains("ChatGPT:") == true,
                      "An explicit idle discovery with retired choices cannot replace the verified preset cache")
        XCTAssertEqual(state.websiteModelChoices.filter { $0.provider == "chatgpt" }, [sol])
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), state.websiteModelChoices)
        XCTAssertEqual(state.selectedTask?.model, sol.modelID)
        XCTAssertFalse(state.modelOptions.contains { $0.id == latest.modelID })
    }

    func testDeletingFinalPausedPromptReleasesRetiredModelWithoutDispatchingIt() async throws {
        let latest = WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Latest")
        let sol = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium")
        let preferences = isolatedTestPreferences()
        WebsiteModelCatalog.save([sol], to: preferences)
        let busy = AgentTask(id: "queued-latest", title: "Queued", summary: "", status: .running, workspace: "/tmp", model: latest.modelID)
        let state = AppState(tasks: [busy], preferences: preferences)
        let accepted = await state.submitOrQueue(prompt: "Keep pending", toTaskID: busy.id)
        XCTAssertTrue(accepted)
        state.apply(.taskStatusChanged(taskID: busy.id, status: .waiting))
        let pending = try XCTUnwrap(state.queuedPrompts[busy.id]?.first)
        XCTAssertEqual(state.selectedTask?.model, latest.modelID)
        XCTAssertFalse(state.canChangeModel(for: busy.id))
        XCTAssertTrue(state.deleteQueuedPrompt(taskID: busy.id, id: pending.id))
        XCTAssertTrue(state.canChangeModel(for: busy.id))
        XCTAssertEqual(state.selectedTask?.model, sol.modelID)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
        XCTAssertTrue(state.queuedPrompts[busy.id]?.isEmpty == true)
    }

    func testStartupUsesCompleteCachedCatalogWithoutDiscovery() async {
        let preferences = isolatedTestPreferences()
        let cached = WebsiteModelCatalog.providers.map {
            modelStateChoice(provider: $0, key: "cached", label: "Cached")
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
        let cached = modelStateChoice(provider: "chatgpt", key: "cached", label: "Cached")
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
            modelStateChoice(provider: $0, key: "cached", label: "Cached")
        }
        WebsiteModelCatalog.save(cached, to: preferences)
        let ledger = WebsiteDiscoveryLedger()
        let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
            try await ledger.discover(provider)
        })

        await state.refreshWebsiteModels()

        XCTAssertEqual(ledger.calls, WebsiteModelCatalog.providers)
        XCTAssertEqual(Set(state.websiteModelChoices.map(\.provider)), Set(WebsiteModelCatalog.providers))
        XCTAssertTrue(state.websiteModelChoices.allSatisfy(\.isSelectable))
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), state.websiteModelChoices)
        XCTAssertNil(state.websiteModelsError)
    }

    func testExplicitRefreshPreservesManualRecoveryIntentBehindPartialStartup() async {
        let preferences = isolatedTestPreferences()
        let cached = ["chatgpt", "claude"].map {
            modelStateChoice(provider: $0, key: "cached", label: "Cached")
        }
        WebsiteModelCatalog.save(cached, to: preferences)
        var calls: [String] = []
        var active = 0, maximumActive = 0
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
            calls.append(provider)
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if calls.count == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
            return [modelStateChoice(provider: provider, key: "fixture", label: "Fixture")]
        })
        var observed: [(provider: String, retryBlocked: Bool)] = []
        state.setWebsiteModelRefreshObserverForTesting { observed.append(($0, $1)) }

        state.refreshWebsiteModelsIfNeeded()
        await waitForDiscovery { held != nil }
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.provider, "gemini")
        XCTAssertEqual(observed.first?.retryBlocked, false)
        let manual = Task { await state.refreshWebsiteModels() }
        await waitForDiscovery { state.websiteModelRefreshIntentsForTesting.count == 3 }
        XCTAssertEqual(state.websiteModelRefreshIntentsForTesting.map(\.provider), WebsiteModelCatalog.providers)
        XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.allSatisfy(\.retryBlocked))
        held?.resume(returning: [modelStateChoice(provider: "gemini", key: "startup", label: "Startup")])
        held = nil
        await manual.value

        XCTAssertEqual(calls, ["gemini", "chatgpt", "gemini", "claude"])
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(observed.filter { !$0.retryBlocked }.map(\.provider), ["gemini"])
        for provider in WebsiteModelCatalog.providers {
            XCTAssertEqual(observed.filter { $0.provider == provider && $0.retryBlocked }.count, 1,
                           "The explicit recovery intent must survive the non-recovery startup probe")
        }
        XCTAssertEqual(Set(state.websiteModelChoices.map(\.provider)), Set(WebsiteModelCatalog.providers))
        XCTAssertTrue(state.websiteModelChoices.allSatisfy(\.isSelectable))
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
            provider == "chatgpt"
                ? [WebsiteModelChoice(provider: provider, key: "chat/latest/medium", label: "Medium"),
                   WebsiteModelChoice(provider: provider, key: "chat/latest/pro", label: "GPT-6 Pro")]
                : [WebsiteModelChoice(provider: provider, key: "fixture-fast", label: "Fixture Fast"),
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
        let old = modelStateChoice(provider: "chatgpt", key: "fixture-old", label: "Fixture Old")
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

    func testLegacyChatFamilyDiscoveryCannotReplaceVerifiedPresetCache() async {
        for rejected in [WebsiteModelChoice(provider: "chatgpt", key: "GPT-6", label: "GPT-6"),
                         WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/pro", label: "Pro")] {
            let preferences = isolatedTestPreferences()
            let medium = syntheticChatGPTChoice
            WebsiteModelCatalog.save([medium], to: preferences)
            let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
                provider == "chatgpt" ? [rejected] : [modelStateChoice(provider: provider, key: "fixture", label: "Fixture")]
            })
            await state.refreshWebsiteModels()
            XCTAssertEqual(state.websiteModelChoices.filter { $0.provider == "chatgpt" }, [medium])
            XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), state.websiteModelChoices)
            XCTAssertTrue(state.websiteModelsError?.contains("ChatGPT:") == true)
            XCTAssertFalse(state.setDefaultModel(rejected.modelID))
        }
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

    func testScopedGeminiRefreshReplacesItsCatalogAndRetainsUnavailableSavedSelection() async throws {
        let preferences = isolatedTestPreferences()
        let old = WebsiteModelChoice(provider: "gemini", key: "3.1 Pro", label: "3.1 Pro")
        // A synthetic next version tests replacement, not current website availability.
        let replacement = WebsiteModelChoice(provider: "gemini", key: "4.2 Flash", label: "4.2 Flash")
        let others = [modelStateChoice(provider: "chatgpt", key: "cached", label: "Cached"),
                      modelStateChoice(provider: "claude", key: "cached", label: "Cached")]
        WebsiteModelCatalog.save(others + [old], to: preferences)
        preferences.set(old.modelID, forKey: "LocalCodex.defaultModelID")
        let task = AgentTask(id: "old-gemini", title: "Saved", summary: "", status: .completed, workspace: "/tmp", model: old.modelID)
        var calls: [String] = []
        let state = AppState(tasks: [task], preferences: preferences, websiteModelDiscovery: { provider in
            calls.append(provider)
            return [replacement]
        })

        await state.refreshWebsiteModels(provider: "gemini")

        XCTAssertEqual(calls, ["gemini"])
        XCTAssertEqual(state.websiteModelChoices, others + [replacement])
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), others + [replacement])
        XCTAssertEqual(state.defaultModel, old.modelID)
        XCTAssertEqual(state.selectedTask?.model, old.modelID)
        let snapshot = WebUISnapshot(state: state)
        XCTAssertEqual(snapshot.modelOptions.first { $0.id == old.modelID }?.available, false)
        XCTAssertEqual(snapshot.modelOptions.first { $0.id == replacement.modelID }?.available, true)
        XCTAssertFalse(state.setDefaultModel(old.modelID))
        XCTAssertFalse(state.setTaskModel(old.modelID, taskID: task.id))
        XCTAssertTrue(state.setDefaultModel(replacement.modelID))
        XCTAssertTrue(state.setTaskModel(replacement.modelID, taskID: task.id))
        XCTAssertNil(state.websiteModelsError)
    }

    func testScopedRefreshFailureOrInvalidCatalogPreservesAllSavedChoices() async throws {
        for failure in ["throw", "foreign", "duplicate"] {
            let preferences = isolatedTestPreferences()
            let cached = WebsiteModelCatalog.providers.map { modelStateChoice(provider: $0, key: "cached", label: "Cached") }
            WebsiteModelCatalog.save(cached, to: preferences)
            let saved = preferences.data(forKey: WebsiteModelCatalog.preferenceKey)
            var calls: [String] = []
            let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
                calls.append(provider)
                let choice = WebsiteModelChoice(provider: "gemini", key: "4.2 Flash", label: "4.2 Flash")
                if failure == "throw" { throw WebsiteModelCatalog.Failure.invalidChoices }
                return failure == "foreign" ? [choice, modelStateChoice(provider: "claude", key: "new", label: "New")]
                    : [choice, choice]
            })

            await state.refreshWebsiteModels(provider: "gemini")

            XCTAssertEqual(calls, ["gemini"])
            XCTAssertEqual(state.websiteModelChoices, cached)
            XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), saved)
            XCTAssertTrue(state.websiteModelsError?.hasPrefix("Gemini:") == true)
            XCTAssertFalse(state.websiteModelsRefreshing)
        }
    }

    func testScopedRefreshRejectsUnknownProviderWithoutFallingBackToGlobalDiscovery() async {
        var calls: [String] = []
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), websiteModelDiscovery: { provider in
            calls.append(provider)
            return [modelStateChoice(provider: provider, key: "new", label: "New")]
        })
        for provider in ["", "Gemini", "gemini ", "unknown", "browser/gemini"] {
            await state.refreshWebsiteModels(provider: provider)
        }
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.isEmpty)
    }

    func testScopedAndGlobalRefreshCoalesceWithoutRepeatingTheScopedProvider() async {
        var calls: [String] = []
        var active = 0, maximumActive = 0
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), websiteModelDiscovery: { provider in
            calls.append(provider)
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if calls.count == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
            return [modelStateChoice(provider: provider, key: "new", label: "New")]
        })
        let scoped = Task { await state.refreshWebsiteModels(provider: "gemini") }
        await waitForDiscovery { held != nil }
        let global = Task { await state.refreshWebsiteModels() }
        await waitForDiscovery { state.websiteModelRefreshIntentsForTesting.count == 2 }
        held?.resume(returning: [modelStateChoice(provider: "gemini", key: "new", label: "New")])
        held = nil
        await scoped.value
        await global.value
        XCTAssertEqual(calls, ["gemini", "chatgpt", "claude"])
        XCTAssertEqual(maximumActive, 1)
        XCTAssertFalse(state.websiteModelsRefreshing)
    }

    func testScopedRefreshPreservesIdleBoundaryAndDropsLateResultsWithoutReplay() async {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        browser.recordHumanVerificationRequired(provider: "gemini")
        let checkpoint = browser.savedHumanVerificationCheckpointIDs["gemini"]
        let preferences = isolatedTestPreferences()
        let cached = WebsiteModelCatalog.providers.map { modelStateChoice(provider: $0, key: "cached", label: "Cached") }
        WebsiteModelCatalog.save(cached, to: preferences)
        let saved = preferences.data(forKey: WebsiteModelCatalog.preferenceKey)
        var calls: [String] = []
        var held: CheckedContinuation<[WebsiteModelChoice], Error>?
        let state = AppState(tasks: [], preferences: preferences, browserSession: browser, websiteModelDiscovery: { provider in
            calls.append(provider)
            return try await withCheckedThrowingContinuation { held = $0 }
        })
        state.activeTurnTaskIDs.insert("already-running")
        await state.refreshWebsiteModels(provider: "gemini")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.isEmpty)
        state.activeTurnTaskIDs.removeAll()
        let refresh = Task { await state.refreshWebsiteModels(provider: "gemini") }
        await waitForDiscovery { held != nil }
        state.activeTurnTaskIDs.insert("new-turn")
        held?.resume(returning: [WebsiteModelChoice(provider: "gemini", key: "4.2 Flash", label: "4.2 Flash")])
        held = nil
        await refresh.value
        XCTAssertEqual(calls, ["gemini"])
        XCTAssertEqual(state.websiteModelChoices, cached)
        XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), saved)
        XCTAssertEqual(browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.isEmpty)
        state.activeTurnTaskIDs.removeAll()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, ["gemini"], "Returning to idle must not replay a scoped refresh")
    }

    func testBusyTaskCannotSwitchToAnotherDiscoveredChoice() async {
        let first = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let second = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium")
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
        return [modelStateChoice(provider: provider, key: "fixture", label: "Fixture")]
    }
}

private func modelStateChoice(provider: String, key: String, label: String) -> WebsiteModelChoice {
    provider == "chatgpt" ? WebsiteModelChoice(provider: provider, key: "chat/latest/medium", label: "Medium")
        : WebsiteModelChoice(provider: provider, key: key, label: label)
}

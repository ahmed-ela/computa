import Foundation
import XCTest
@testable import Computa

@MainActor
final class WebsiteModeCatalogTests: XCTestCase {
    private let modes = WebsiteModeChoice.DeepSeekMode.allCases.map { WebsiteModeChoice(deepSeekMode: $0) }

    func testOnlyObservedTypedModesSurviveCacheReloadWithoutNamedModelAliases() throws {
        let preferences = isolatedTestPreferences()
        WebsiteModeCatalog.save(modes, to: preferences)
        XCTAssertEqual(WebsiteModeCatalog.load(from: preferences), modes)
        let bytes = try XCTUnwrap(preferences.data(forKey: WebsiteModeCatalog.preferenceKey))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: bytes), modes.map(\.requestID))
        XCTAssertNil(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
        for invalid in [modes.map(\.requestID) + [modes[0].requestID], [modes[0].requestID, modes[0].requestID],
                        ["browser/deepseek", modes[1].requestID], ["browser/deepseek/mode/pro", modes[1].requestID],
                        ["browser/qwen/mode/chat", modes[1].requestID]] {
            preferences.set(try JSONEncoder().encode(invalid), forKey: WebsiteModeCatalog.preferenceKey)
            XCTAssertTrue(WebsiteModeCatalog.load(from: preferences).isEmpty)
        }
        preferences.set(bytes, forKey: WebsiteModeCatalog.preferenceKey)
        WebsiteModeCatalog.save([modes[0]], to: preferences)
        XCTAssertEqual(preferences.data(forKey: WebsiteModeCatalog.preferenceKey), bytes,
            "A partial observation must not replace the last verified mode menu")
    }

    func testObservedModeDiscoveryPublishesHonestLabelsAndPersistsOnlyTypedChoices() async {
        let preferences = isolatedTestPreferences(), browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        var namedCalls: [String] = [], modeCalls: [String] = []
        let state = AppState(tasks: [], preferences: preferences, browserSession: browser,
            websiteModelDiscovery: { provider in namedCalls.append(provider); return [] },
            websiteModeDiscovery: { provider in modeCalls.append(provider); return self.modes })
        await state.refreshWebsiteModels(provider: "deepseek")
        XCTAssertEqual(namedCalls, []); XCTAssertEqual(modeCalls, ["deepseek"])
        XCTAssertEqual(state.websiteModeChoices, modes); XCTAssertNil(state.websiteModelsError)
        XCTAssertTrue(state.websiteModelChoices.allSatisfy { $0.provider != "deepseek" })
        XCTAssertEqual(WebsiteModeCatalog.load(from: preferences), modes)
        let options = state.modelOptions.filter { $0.id.hasPrefix("browser/deepseek") }
        XCTAssertEqual(options.map(\.id), modes.map(\.requestID))
        XCTAssertEqual(options.map(\.label), ["DeepSeek / Chat · Built-in browser", "DeepSeek / DeepThink · Built-in browser"])
        XCTAssertTrue(options.allSatisfy { $0.available == true && $0.detail.contains("No backend model or version is attested") })
        XCTAssertTrue(browser.tabs.isEmpty)
    }

    func testSavedModeWithoutAnObservedMenuKeepsReadableUnavailableIdentity() {
        let preferences = isolatedTestPreferences(), mode = modes[1]
        preferences.set(mode.requestID, forKey: "LocalCodex.defaultModelID")
        let browser = EmbeddedBrowserSession(persistent: false); defer { browser.shutdown() }
        let state = AppState(tasks: [], preferences: preferences, browserSession: browser)
        let option = state.modelOptions.first { $0.id == mode.requestID }
        XCTAssertEqual(state.defaultModel, mode.requestID)
        XCTAssertEqual(option?.label, "DeepSeek / DeepThink · Built-in browser")
        XCTAssertEqual(option?.available, false)
        XCTAssertFalse(state.modelOptions.contains { $0.id == "browser/deepseek" })
    }

    func testFailedOrIncompleteModeRefreshPreservesCachedChoicesAndSelection() async {
        let preferences = isolatedTestPreferences(), browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        WebsiteModeCatalog.save(modes, to: preferences)
        preferences.set(modes[1].requestID, forKey: "LocalCodex.defaultModelID")
        let state = AppState(tasks: [], preferences: preferences, browserSession: browser,
            websiteModeDiscovery: { _ in [self.modes[0]] })
        await state.refreshWebsiteModels(provider: "deepseek")
        XCTAssertEqual(state.websiteModeChoices, modes)
        XCTAssertEqual(state.defaultModel, modes[1].requestID)
        XCTAssertEqual(WebsiteModeCatalog.load(from: preferences), modes)
        XCTAssertTrue(state.websiteModelsError?.contains("DeepSeek:") == true)
        XCTAssertTrue(browser.tabs.isEmpty)
    }

    func testSingleKindInjectedDiscoveryCannotOpenOtherLiveProviderPages() async {
        let observedModes = modes
        let namedDiscovery: @MainActor @Sendable (String) async throws -> [WebsiteModelChoice] = { _ in [] }
        let modeDiscovery: @MainActor @Sendable (String) async throws -> [WebsiteModeChoice] = { _ in observedModes }
        for modesOnly in [false, true] {
            let browser = EmbeddedBrowserSession(persistent: false); defer { browser.shutdown() }
            let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: browser,
                websiteModelDiscovery: modesOnly ? nil : namedDiscovery,
                websiteModeDiscovery: modesOnly ? modeDiscovery : nil)
            await state.refreshWebsiteModels()
            XCTAssertTrue(browser.tabs.isEmpty)
            XCTAssertFalse(state.websiteModelsRefreshing)
        }
    }

    func testCachedModesRevalidateOnlySelectedProviderOncePerLaunch() async throws {
        let preferences = isolatedTestPreferences(), browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let named = WebsiteModelCatalog.providers.filter { $0 != "deepseek" }.map { provider -> WebsiteModelChoice in
            switch provider {
            case "chatgpt": syntheticChatGPTChoice
            case "kimi": syntheticKimiChoice
            case "qwen": .init(provider: provider, key: "Qwen3.7-Plus", label: "Qwen3.7-Plus")
            case "groq": .init(provider: provider, key: "openai/gpt-oss-120b", label: "GPT OSS 120B")
            default: .init(provider: provider, key: "fixture", label: "Fixture")
            }
        }
        WebsiteModelCatalog.save(named, to: preferences); WebsiteModeCatalog.save(modes, to: preferences)
        preferences.set(modes[0].requestID, forKey: "LocalCodex.defaultModelID")
        var calls: [String] = []
        let state = AppState(tasks: [], preferences: preferences, browserSession: browser,
            websiteModelDiscovery: { provider in calls.append(provider); return named.filter { $0.provider == provider } },
            websiteModeDiscovery: { provider in calls.append(provider); return self.modes })
        state.refreshWebsiteModelsIfNeeded(); state.refreshWebsiteModelsIfNeeded()
        let deadline = ContinuousClock.now + .seconds(2)
        while calls.isEmpty || state.websiteModelsRefreshing {
            guard ContinuousClock.now < deadline else { XCTFail("Startup discovery did not complete"); return }
            await Task.yield()
        }
        state.refreshWebsiteModelsIfNeeded()
        XCTAssertEqual(calls, ["deepseek"])
        XCTAssertEqual(state.websiteModeChoices, modes)
        XCTAssertTrue(browser.tabs.isEmpty)
    }
}

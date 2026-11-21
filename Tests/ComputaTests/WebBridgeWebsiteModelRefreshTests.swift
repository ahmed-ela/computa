import Foundation
import XCTest
@testable import Computa

@MainActor
final class WebBridgeWebsiteModelRefreshTests: XCTestCase {
    func testFreshAccountCatalogSurvivesRestartAndSignOutRetiresOnlyItsModels() async throws {
        let prefs = isolatedTestPreferences()
        let gemini = syntheticWebsiteChoice(provider: "gemini", key: "Pro", label: "Pro")
        let chat = syntheticWebsiteChoice(provider: "chatgpt", key: "new", label: "High")
        @MainActor final class Account { var failure: EmbeddedWebModelTransport.Failure? }
        let account = Account()
        let state = AppState(tasks: [], preferences: prefs, websiteModelDiscovery: { provider in
            if let failure = account.failure { throw failure }
            return provider == "gemini" ? [gemini] : [chat]
        })
        let first = WebUISnapshot(state: state)
        XCTAssertEqual(first.providerSetups.map(\.route), WebsiteModelCatalog.discoveryProviders.map { "browser/" + $0 })
        XCTAssertTrue(first.providerSetups.allSatisfy { !$0.connected })
        await state.refreshWebsiteModels(provider: "gemini")
        await state.refreshWebsiteModels(provider: "chatgpt")
        XCTAssertTrue(state.setDefaultModel(chat.modelID))
        let restored = AppState(tasks: [], preferences: prefs)
        XCTAssertEqual(WebUISnapshot(state: restored).providerSetups.filter(\.connected).map(\.route), ["browser/chatgpt", "browser/gemini"])
        account.failure = .usageLimited(.chatgpt)
        await state.refreshWebsiteModels(provider: "chatgpt")
        XCTAssertTrue(state.websiteModelChoices.contains(chat))
        XCTAssertEqual(WebUISnapshot(state: state).providerSetups.first { $0.route == "browser/chatgpt" }?.checkStatus, .unavailable)
        account.failure = .signInRequired
        await state.refreshWebsiteModels(provider: "chatgpt")
        XCTAssertEqual(WebUISnapshot(state: state).providerSetups.first { $0.route == "browser/chatgpt" }?.checkStatus, .signInRequired)
        XCTAssertEqual(WebsiteModelCatalog.load(from: prefs), [gemini])
        let nextLaunch = AppState(tasks: [], preferences: prefs)
        XCTAssertEqual(nextLaunch.websiteModelSetupStatus(for: "chatgpt"), .unchecked)
        XCTAssertEqual(state.defaultModel, chat.modelID)
        XCTAssertFalse(state.setDefaultModel(chat.modelID))
    }

    func testOnlySupportedIdleSetupRoutesCanOpenTabsOrProviderSettings() {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let task = AgentTask(title: "Busy fixture", summary: "", status: .running, workspace: "", model: "browser/chatgpt")
        let state = AppState(tasks: [task], preferences: prefs, browserSession: session)
        for route in ["browser/chatgpt", "api/alibaba"] { state.connectModelProvider(route: route) }
        state.apply(.taskStatusChanged(taskID: task.id, status: .completed))
        for route in ["browser/groq", "api/cerebras", "api/alibaba", "https://example.org", "browser/gemini/other", "api/unknown"] {
            state.connectModelProvider(route: route)
        }
        XCTAssertTrue(session.humanTabs.isEmpty)
        XCTAssertFalse(state.isBrowserPresented)
        XCTAssertFalse(state.isAPIProvidersPresented)
    }

    func testExplicitProviderRefreshesOnlyThatProviderAndOmittedProviderRetainsGlobalAction() async {
        var calls: [String] = []
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), websiteModelDiscovery: { provider in
            calls.append(provider)
            return [syntheticWebsiteChoice(provider: provider, key: "fixture", label: "Fixture")]
        }, websiteModeDiscovery: { provider in
            calls.append(provider)
            return WebsiteModeChoice.DeepSeekMode.allCases.map { WebsiteModeChoice(deepSeekMode: $0) }
        })
        let bridge = WebBridge(state: state)
        for provider in WebsiteModelCatalog.discoveryProviders {
            await bridge.refreshWebsiteModels(body: ["action": "refreshWebsiteModels", "provider": provider])
            XCTAssertEqual(calls, [provider])
            calls.removeAll()
        }
        await bridge.refreshWebsiteModels(body: ["action": "refreshWebsiteModels"])
        XCTAssertEqual(calls, WebsiteModelCatalog.discoveryProviders)
    }

    func testMalformedOrPausedScopedRefreshNeverFallsBackToGlobalDiscovery() async {
        var calls: [String] = []
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), websiteModelDiscovery: { provider in
            calls.append(provider)
            return [WebsiteModelChoice(provider: provider, key: "fixture", label: "Fixture")]
        })
        let bridge = WebBridge(state: state)
        let invalid: [[String: Any]] = [
            [:], ["action": "different"], ["action": "refreshWebsiteModels", "extra": true],
            ["action": "refreshWebsiteModels", "provider": NSNull()],
            ["action": "refreshWebsiteModels", "provider": true],
            ["action": "refreshWebsiteModels", "provider": 17],
            ["action": "refreshWebsiteModels", "provider": ["gemini"]],
            ["action": "refreshWebsiteModels", "provider": "unknown"],
            ["action": "refreshWebsiteModels", "provider": "groq"],
            ["action": "refreshWebsiteModels", "provider": "Gemini"],
            ["action": "refreshWebsiteModels", "provider": " gemini"],
            ["action": "refreshWebsiteModels", "provider": "gemini "],
            ["action": "refreshWebsiteModels", "provider": "gemini", "extra": true],
        ]
        for body in invalid { await bridge.refreshWebsiteModels(body: body) }
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(state.websiteModelChoices.isEmpty)
        XCTAssertFalse(state.websiteModelsRefreshing)
        XCTAssertTrue(state.websiteModelRefreshIntentsForTesting.isEmpty)
    }
}

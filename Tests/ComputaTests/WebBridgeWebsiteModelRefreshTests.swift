import Foundation
import XCTest
@testable import Computa

@MainActor
final class WebBridgeWebsiteModelRefreshTests: XCTestCase {
    func testExplicitProviderRefreshesOnlyThatProviderAndOmittedProviderRetainsGlobalAction() async {
        var calls: [String] = []
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), websiteModelDiscovery: { provider in
            calls.append(provider)
            return [provider == "chatgpt" ? syntheticChatGPTChoice
                : WebsiteModelChoice(provider: provider, key: "fixture", label: "Fixture")]
        })
        let bridge = WebBridge(state: state)
        for provider in WebsiteModelCatalog.providers {
            await bridge.refreshWebsiteModels(body: ["action": "refreshWebsiteModels", "provider": provider])
            XCTAssertEqual(calls, [provider])
            calls.removeAll()
        }
        await bridge.refreshWebsiteModels(body: ["action": "refreshWebsiteModels"])
        XCTAssertEqual(calls, WebsiteModelCatalog.providers)
    }

    func testMalformedScopedRefreshNeverFallsBackToGlobalDiscovery() async {
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

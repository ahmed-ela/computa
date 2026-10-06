import XCTest
@testable import Computa

final class BrowserModelCatalogTests: XCTestCase {
    func testChatGPTDescribesTheBuiltInBrowserWhileOtherProvidersKeepChrome() throws {
        let chatgpt = try XCTUnwrap(LocalModelCatalog.option(for: LocalModelCatalog.chatGPTBrowserModelID))
        XCTAssertEqual(chatgpt.label, "ChatGPT · Built-in browser")
        XCTAssertTrue(chatgpt.detail.contains("Computa's built-in browser"))
        XCTAssertTrue(chatgpt.detail.contains("screenshots are unavailable"))
        XCTAssertFalse(chatgpt.detail.contains("Chrome"))
        for model in [LocalModelCatalog.geminiBrowserModelID, LocalModelCatalog.claudeBrowserModelID] {
            XCTAssertTrue(try XCTUnwrap(LocalModelCatalog.option(for: model)).label.contains("Chrome"))
        }
    }

    func testBrowserToolsOmitCaptureWhileRetainingSemanticToolsAndLocalSchemas() {
        for policy: ComputerInteractionPolicy in [.backgroundOnly, .foregroundAllowed] {
            let localNames = Set(ComputerV2ToolContract.referenceSpecs(for: LocalModelCatalog.defaultModelID,
                interactionPolicy: policy).compactMap { $0["name"] as? String })
            XCTAssertTrue(localNames.contains("computer_v2_capture"))
            for browser in [LocalModelCatalog.chatGPTBrowserModelID, LocalModelCatalog.geminiBrowserModelID,
                            LocalModelCatalog.claudeBrowserModelID] {
                let browserNames = Set(ComputerV2ToolContract.referenceSpecs(for: browser,
                    interactionPolicy: policy).compactMap { $0["name"] as? String })
                XCTAssertFalse(browserNames.contains("computer_v2_capture"))
                XCTAssertTrue(["computer_v2_read_page", "computer_v2_read_region", "computer_v2_press",
                    "computer_v2_follow", "computer_v2_fill", "computer_v2_tabs", "computer_v2_bind_tab"].allSatisfy(browserNames.contains))
            }
        }
    }

    func testBrowserModelsRouteToTheirWebsitesWithoutLocalInferenceRequirements() throws {
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        for (model, provider) in [(LocalModelCatalog.chatGPTBrowserModelID, "chatgpt"),
                                  (LocalModelCatalog.geminiBrowserModelID, "gemini"),
                                  (LocalModelCatalog.claudeBrowserModelID, "claude")] {
            XCTAssertNotNil(LocalModelCatalog.option(for: model))
            XCTAssertEqual(LocalModelCatalog.webProvider(for: model), provider)
            XCTAssertEqual(WebModelServer.provider(for: model), provider)
            XCTAssertEqual(configuration.modelProvider(for: model), "web_browser")
            XCTAssertNoThrow(try configuration.validateSelectedModel(model))
            XCTAssertFalse(LocalModelCatalog.supportsHeadlessMLX(model))
            XCTAssertFalse(LocalModelCatalog.supportsResidentVisualGrounding(model))
        }
        XCTAssertEqual(configuration.modelProvider(for: LocalModelCatalog.defaultModelID), "lmstudio")
        XCTAssertNil(LocalModelCatalog.webProvider(for: "browser/unrecognized"))
        XCTAssertNil(WebModelServer.provider(for: "browser/unrecognized"))
        XCTAssertNil(WebModelServer.provider(for: LocalModelCatalog.defaultModelID))
    }

    func testProviderSwitchNeedsNewThreadWhileWebsitesShareBrowserContextProfile() {
        let browser = LocalThreadContext.forModel(LocalModelCatalog.chatGPTBrowserModelID)
        XCTAssertEqual(browser, .webBrowser)
        XCTAssertTrue(browser.supportsModelSwitch(to: LocalModelCatalog.geminiBrowserModelID))
        XCTAssertTrue(browser.supportsModelSwitch(to: LocalModelCatalog.claudeBrowserModelID))
        XCTAssertEqual(LocalThreadContext.forModel(LocalModelCatalog.claudeBrowserModelID), browser)
        XCTAssertFalse(browser.supportsModelSwitch(to: LocalModelCatalog.defaultModelID))
        XCTAssertFalse(LocalThreadContext.forModel(LocalModelCatalog.defaultModelID)
            .supportsModelSwitch(to: LocalModelCatalog.chatGPTBrowserModelID))
        XCTAssertFalse(LocalThreadContext.forModel(LocalModelCatalog.defaultModelID)
            .supportsModelSwitch(to: LocalModelCatalog.claudeBrowserModelID))
        let config = CodexAppServerRuntime.localThreadConfig(for: LocalModelCatalog.chatGPTBrowserModelID)
        XCTAssertEqual(config["model_context_window"] as? Int, 65_536)
        XCTAssertEqual(config["model_auto_compact_token_limit"] as? Int, 49_152)
        XCTAssertEqual(config["features.unified_exec"] as? Bool, true)
        XCTAssertEqual(config["features.browser_use"] as? Bool, false)
        XCTAssertEqual(config["features.computer_use"] as? Bool, false)
    }

    func testSavedTranscriptRestoresEveryTurnTextAndToolResultWithoutTruncation() throws {
        let longAnswer = String(repeating: "Saved answer 東京 👋\n", count: 10_000)
        let turns: [[String: Any]] = [
            ["id": "turn-1", "startedAt": 100, "items": [
                ["id": "user-1", "type": "userMessage", "content": [["type": "text", "text": "Original prompt"],
                    ["type": "text", "text": "APP_RUNTIME_CONTINUATION: Internal guidance"]]],
                ["id": "tool-1", "type": "dynamicToolCall", "tool": "computer_v2_read_page", "status": "completed",
                 "success": true, "arguments": [:], "contentItems": [["type": "inputText", "text": "Observed webpage text"]]],
                ["id": "answer-1", "type": "agentMessage", "text": longAnswer, "phase": "final_answer"],
            ]],
            ["id": "turn-2", "startedAt": 200, "items": [
                ["id": "user-2", "type": "userMessage", "content": [["type": "text", "text": "Follow-up"]]],
                ["id": "answer-2", "type": "agentMessage", "text": "Follow-up answer"],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["result": ["thread": ["turns": turns]]])
        let entries = try AppServerThreadHistoryContract.entries(from: data)
        XCTAssertEqual(entries.map(\.id), ["user-1", "tool-1", "answer-1", "user-2", "answer-2"])
        XCTAssertEqual(entries[2].body, longAnswer)
        XCTAssertEqual(entries[0].body, "Original prompt")
        XCTAssertEqual(entries[1].toolEvent?.output, "Observed webpage text")
        XCTAssertEqual(entries[2].activityGroupID, "user-1")
        XCTAssertEqual(entries[4].activityGroupID, "user-2")
        XCTAssertEqual(entries[0].timestamp, Date(timeIntervalSince1970: 100))
        let suppressed = try AppServerThreadHistoryContract.entries(from: data, excludingAssistantTurns: ["turn-1"])
        XCTAssertFalse(suppressed.contains { $0.id == "answer-1" })
        XCTAssertTrue(suppressed.contains { $0.id == "tool-1" })
        XCTAssertTrue(suppressed.contains { $0.id == "answer-2" })
    }
}

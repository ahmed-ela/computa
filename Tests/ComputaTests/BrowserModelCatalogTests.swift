import XCTest
@testable import Computa

final class BrowserModelCatalogTests: XCTestCase {
    func testStableGroqSchemaDiscoveryIsExplicitAndCannotBorrowForeignOrUnknownCatalogs() throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        func wire(_ definition: [String: Any]) -> [String: Any] {
            var value = definition; value["parameters"] = value.removeValue(forKey: "inputSchema"); return value
        }
        let loader = wire(GroqToolCatalog.specification), browser = EmbeddedBrowserTools.definitions().map(wire)
        for namespace: String? in [nil, "functions"] {
            func wrap(_ tools: [[String: Any]]) -> [[String: Any]] {
                namespace.map { [["type": "namespace", "name": $0, "tools": tools]] } ?? tools
            }
            let definitions = wrap([loader] + browser)
            let legacy = ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: model, browserToolAvailability: .unbound)
            let stable = ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: model,
                browserToolAvailability: .unbound, stableGroqBrowserSchemas: true)
            let bound = ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: model, browserToolAvailability: .bound)
            XCTAssertEqual(stable as NSArray, bound as NSArray, "Schema discovery is independent of binding in the exact opted-in catalog")
            XCTAssertNotEqual(stable as NSArray, legacy as NSArray)
            let children: [[String: Any]]
            if namespace == nil { children = stable }
            else { children = try XCTUnwrap(stable.first?["tools"] as? [[String: Any]]) }
            XCTAssertTrue(EmbeddedBrowserTools.names.isSubset(of: Set(children.compactMap { $0["name"] as? String })))
            XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: model,
                browserToolAvailability: .unbound, stableGroqBrowserSchemas: false) as NSArray, legacy as NSArray)
            for state: EmbeddedBrowserToolAvailability? in [nil, .bound] {
                XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: model,
                    browserToolAvailability: state, stableGroqBrowserSchemas: true) as NSArray,
                    ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: model, browserToolAvailability: state) as NSArray)
            }
            for other in ["browser/chatgpt", "browser/claude", "browser/gemini", "api/fixture/model"] {
                XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: other,
                    browserToolAvailability: .unbound, stableGroqBrowserSchemas: true) as NSArray,
                    ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: other, browserToolAvailability: .unbound) as NSArray)
            }
            var impostorLoader = loader; impostorLoader["parameters"] = ["type": "object", "properties": [:]]
            let absentAndForeign = [wrap(browser), wrap([impostorLoader] + browser),
                [["type": "namespace", "name": "foreign", "tools": [loader] + browser]]]
            for foreign in absentAndForeign {
                XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(foreign, modelID: model,
                    browserToolAvailability: .unbound, stableGroqBrowserSchemas: true) as NSArray,
                    ComputaModelToolCatalog.visibleToolDefinitions(foreign, modelID: model, browserToolAvailability: .unbound) as NSArray)
            }
            var modified = try XCTUnwrap(browser.first { $0["name"] as? String == "browser_read" })
            modified["parameters"] = ["type": "object", "properties": ["foreign": ["type": "string"]]]
            let foreignPage = wrap([loader, modified])
            XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(foreignPage, modelID: model,
                browserToolAvailability: .unbound, stableGroqBrowserSchemas: true) as NSArray,
                ComputaModelToolCatalog.visibleToolDefinitions(foreignPage, modelID: model, browserToolAvailability: .unbound) as NSArray)
        }
    }

    func testSavedWaitCatalogsRefreshOnlyExactNativeVersionsAndRetainBindingGate() throws {
        let legacy = try XCTUnwrap(EmbeddedBrowserTools.legacyWaitDefinition["inputSchema"] as? [String: Any])
        let current = try XCTUnwrap(EmbeddedBrowserTools.waitDefinition["inputSchema"] as? [String: Any])
        let dropped: Set<String> = ["description", "minimum", "maximum", "minLength", "maxLength", "pattern"]
        func engineProjection(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { !dropped.contains($0.key) }.mapValues(engineProjection)
            }
            if let array = value as? [Any] { return array.map(engineProjection) }
            return value
        }
        for schema in [legacy, current, engineProjection(legacy) as! [String: Any], engineProjection(current) as! [String: Any]] {
            for key in ["parameters", "inputSchema"] {
                let saved: [String: Any] = ["type": "function", "name": "browser_wait", "description": "Saved description", key: schema]
                for namespace: String? in [nil, "functions"] {
                    let definitions: [[String: Any]] = namespace.map { [["type": "namespace", "name": $0, "tools": [saved]]] } ?? [saved]
                    XCTAssertTrue(ComputaModelToolCatalog.requiresBrowserToolAvailability(definitions))
                    let visible = ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: "api/fixture/model", browserToolAvailability: .bound)
                    let definition = try XCTUnwrap(namespace == nil ? visible.first : (visible.first?["tools"] as? [[String: Any]])?.first)
                    XCTAssertEqual(definition[key] as? NSDictionary, current as NSDictionary)
                    XCTAssertEqual(definition["description"] as? String, EmbeddedBrowserTools.waitDefinition["description"] as? String)
                    XCTAssertTrue(ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: "api/fixture/model", browserToolAvailability: .unbound).isEmpty)
                    XCTAssertEqual(saved[key] as? NSDictionary, schema as NSDictionary)
                }
            }
        }
    }

    func testWaitSchemaEvolutionLeavesForeignNarrowedAndConflictingDeclarationsUntouched() throws {
        let legacy = try XCTUnwrap(EmbeddedBrowserTools.legacyWaitDefinition["inputSchema"] as? [String: Any])
        let current = try XCTUnwrap(EmbeddedBrowserTools.waitDefinition["inputSchema"] as? [String: Any])
        var required = legacy; required["required"] = ["text"]
        var narrowed = current, fields = try XCTUnwrap(current["properties"] as? [String: [String: Any]])
        fields["timeout_ms"]?["maximum"] = 500; narrowed["properties"] = fields
        var wrongBoolean = legacy, oldFields = try XCTUnwrap(legacy["properties"] as? [String: [String: Any]])
        oldFields["timeout_ms"]?["minimum"] = true; wrongBoolean["properties"] = oldFields
        var changedBranch = current, branches = try XCTUnwrap(current["oneOf"] as? [[String: Any]])
        branches[1]["required"] = [String](); changedBranch["oneOf"] = branches
        var open = current; open["additionalProperties"] = true
        var custom = current; custom["properties"] = ["mode": ["type": "string"]]
        let modified = [required, narrowed, wrongBoolean, changedBranch, open, custom]
        var cases: [([String: Any], String?)] = modified.map {
            (["type": "function", "name": "browser_wait", "description": "Foreign contract", "parameters": $0], nil)
        }
        cases.append((["type": "function", "name": "browser_wait", "parameters": legacy, "inputSchema": current], nil))
        cases.append((["type": "function", "name": "browser_wait", "parameters": current, "inputSchema": required], nil))
        cases.append((["type": "function", "name": "browser_wait", "parameters": legacy], "foreign"))
        for (definition, namespace) in cases {
            let definitions: [[String: Any]] = namespace.map { [["type": "namespace", "name": $0, "tools": [definition]]] } ?? [definition]
            XCTAssertNil(ComputaModelToolCatalog.browserWaitDefinitionVariants(definition, namespace: namespace))
            XCTAssertFalse(ComputaModelToolCatalog.requiresBrowserToolAvailability(definitions))
            let visible = ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: "api/fixture/model", browserToolAvailability: .unbound)
            XCTAssertEqual(visible as NSArray, definitions as NSArray)
        }
        let duplicate: [String: Any] = ["type": "function", "name": "browser_wait", "parameters": legacy, "inputSchema": legacy]
        XCTAssertNotNil(ComputaModelToolCatalog.browserWaitDefinitionVariants(duplicate, namespace: nil))
    }

    func testEveryWebsiteDescribesTheBuiltInBrowserAndTextOnlyHarness() throws {
        for (model, provider) in [(LocalModelCatalog.chatGPTBrowserModelID, "ChatGPT"),
                                  (LocalModelCatalog.geminiBrowserModelID, "Gemini"),
                                  (LocalModelCatalog.claudeBrowserModelID, "Claude")] {
            let option = try XCTUnwrap(LocalModelCatalog.option(for: model))
            XCTAssertEqual(option.label, "\(provider) / Website default · Built-in browser")
            XCTAssertTrue(option.detail.contains("Computa's built-in browser"))
            XCTAssertTrue(option.detail.contains("screenshots are unavailable"))
            XCTAssertTrue(option.detail.contains("history is saved locally"))
            XCTAssertFalse(option.detail.contains("Chrome"))
        }
    }

    func testBrowserToolsOmitCaptureWhileRetainingSemanticToolsAndLocalSchemas() {
        for policy: ComputerInteractionPolicy in [.backgroundOnly, .foregroundAllowed] {
            let localNames = Set(ComputerV2ToolContract.referenceSpecs(for: LocalModelCatalog.defaultModelID,
                interactionPolicy: policy).compactMap { $0["name"] as? String })
            XCTAssertTrue(localNames.contains("computer_v2_capture"))
            for browser in [LocalModelCatalog.chatGPTBrowserModelID, LocalModelCatalog.geminiBrowserModelID,
                            LocalModelCatalog.claudeBrowserModelID] {
                let nativeSpecs = ComputerV2ToolContract.referenceSpecs(for: browser, interactionPolicy: policy)
                let browserNames = Set(nativeSpecs.compactMap { $0["name"] as? String })
                XCTAssertFalse(browserNames.contains("computer_v2_capture"))
                XCTAssertTrue(["computer_v2_read_page", "computer_v2_read_region", "computer_v2_press",
                    "computer_v2_fill", "computer_v2_continue", "computer_v2_open", "computer_v2_apps",
                    "computer_v2_status"].allSatisfy(browserNames.contains))
                let retired: Set<String> = ["computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_create_workspace",
                    "computer_v2_follow", "computer_v2_follow_link"]
                XCTAssertTrue(browserNames.isDisjoint(with: retired))
                let offered = ComputaModelToolCatalog.visibleToolDefinitions(nativeSpecs + EmbeddedBrowserTools.definitions(),
                    modelID: browser, browserToolAvailability: .bound)
                let names = Set(offered.compactMap { $0["name"] as? String })
                XCTAssertTrue(EmbeddedBrowserTools.names.isSubset(of: names))
                XCTAssertTrue(names.isDisjoint(with: retired.union(["computer_v2_capture"])))
            }
        }
    }

    func testBrowserModelsRouteToTheirWebsitesWithoutLocalInferenceRequirements() throws {
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        for (model, provider) in [(syntheticChatGPTModelID, "chatgpt"),
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

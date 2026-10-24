import XCTest
@testable import Computa

final class APIModelResponseCodecTests: XCTestCase {
    private let taskID = "550e8400-e29b-41d4-a716-446655440000"
    private var provider: APIProviderDefinition { .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://example.invalid/v1")!, wireAPI: .chatCompletions, models: [.init(id: "fixture-model", name: "Fixture", supportsImages: true)]) }
    private var capsules: APIReasoningCapsules { try! .init(key: Data(repeating: 7, count: 32)) }
    private var function: [String: Any] { ["type": "function", "name": "read", "description": "Read a file", "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"], "additionalProperties": false]] }
    private var tools: [[String: Any]] { [["type": "namespace", "name": "files", "tools": [function]], ["type": "custom", "name": "apply_patch", "description": "Apply patch", "format": ["type": "grammar", "syntax": "lark", "definition": "start: /.+/"]]] }
    private func request(_ changes: [String: Any] = [:], provider customProvider: APIProviderDefinition? = nil,
                         toolNaming: APIModelResponseCodec.ToolNaming = .legacy,
                         browserToolAvailability: EmbeddedBrowserToolAvailability? = nil,
                         browserActionReferences: EmbeddedBrowserCurrentActionReferences? = nil) throws -> APIModelResponseCodec.Request {
        let p = customProvider ?? provider
        var object: [String: Any] = ["model": APIProviderCatalog.appModelID(providerID: p.id, modelID: p.models[0].id), "input": [["role": "user", "content": "read it"]], "instructions": "Use the native tools.", "tools": tools, "store": false, "stream": true]
        object.merge(changes) { _, new in new }
        return try APIModelResponseCodec.prepare(JSONSerialization.data(withJSONObject: object), selection: .init(provider: p, model: p.models[0]), threadID: taskID, capsules: capsules, toolNaming: toolNaming, browserToolAvailability: browserToolAvailability, browserActionReferences: browserActionReferences)
    }
    private func decode(_ message: [String: Any], finish: String = "stop", request: APIModelResponseCodec.Request? = nil, model: String = "fixture-model") throws -> APIModelResponseCodec.Reply {
        let data = try JSONSerialization.data(withJSONObject: ["id": "remote1", "model": model, "choices": [["index": 0, "message": message, "finish_reason": finish]], "usage": ["prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20, "completion_tokens_details": ["reasoning_tokens": 3]]])
        return try APIModelResponseCodec.decode(.init(body: data, contentType: "application/json"), request: request ?? self.request())
    }
    private func wireFunctions(_ request: APIModelResponseCodec.Request) throws -> [[String: Any]] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let definitions = try XCTUnwrap(body["tools"] as? [[String: Any]])
        return try definitions.map { try XCTUnwrap($0["function"] as? [String: Any]) }
    }
    private func correctionResult(_ prepared: APIModelResponseCodec.Request, arguments: String = "{\"path\":false}",
                                  changes: [String: Any] = [:], additionalCalls: [[String: Any]] = [],
                                  toolIndex: Int = 0) throws -> APIProviderHTTPClient.Result {
        let call: [String: Any] = ["id": "rejected-call", "type": "function", "function": ["name": prepared.tools[toolIndex].wireName, "arguments": arguments]]
        var envelope: [String: Any] = ["id": "remote-rejected", "model": prepared.model.id,
            "choices": [["index": 0, "finish_reason": "tool_calls", "message": ["role": "assistant", "tool_calls": [call] + additionalCalls]]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14,
                      "prompt_tokens_details": ["cached_tokens": 3], "completion_tokens_details": ["reasoning_tokens": 2]]]
        envelope.merge(changes) { _, value in value }
        return .init(body: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]), contentType: "application/json")
    }
    private func rejectedDetails(_ prepared: APIModelResponseCodec.Request, arguments: String) throws -> [APIModelResponseCodec.ArgumentRejectionDetail] {
        guard case .argumentsRejected(_, let details) = try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, arguments: arguments), request: prepared) else {
            XCTFail("Fixture must be atomically rejected"); return []
        }
        return details
    }
    private func schemaFeedback(_ prepared: APIModelResponseCodec.Request, details: [APIModelResponseCodec.ArgumentRejectionDetail]) throws -> ([[String: Any]], String) {
        let corrected = try APIModelResponseCodec.correctiveRequest(prepared, rejectionDetails: details)
        let body = try JSONSerialization.jsonObject(with: corrected.body) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]], text = messages[0]["content"] as! String
        guard let range = text.range(of: APIModelResponseCodec.schemaFeedbackMarker) else { return ([], text) }
        let json = String(text[range.upperBound...])
        return (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]], json)
    }


    private func cerebrasStreamRequest() throws -> APIModelResponseCodec.Request {
        try request(provider: .init(id: "cerebras-fixture", name: "Cerebras Fixture", baseURL: URL(string: "https://api.cerebras.ai/v1")!,
            wireAPI: .chatCompletions, models: [.init(id: "fixture-model", name: "Fixture")]))
    }

    func testCurrentOutcomeVerificationSurvivesRetiredChromeToolFiltering() throws {
        let retired: [String: Any] = ["type": "function", "name": "computer_v2_tabs",
                                      "inputSchema": ["type": "object", "properties": [:]]]
        let verify = ComputerOutcomeToolContract.spec
        for modelID in ["browser/chatgpt", "api/cerebras/gpt-oss-120b", "local-fixture"] {
            let definitions: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [retired, verify]]]
            let visible = ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: modelID)
            let children = try XCTUnwrap(visible.first?["tools"] as? [[String: Any]])
            XCTAssertEqual(children.compactMap { $0["name"] as? String }, [ComputerOutcomeToolContract.name])
            XCTAssertEqual(children.first as NSDictionary?, verify as NSDictionary)
            XCTAssertEqual(ComputaModelToolCatalog.nativeToolDescriptions(modelID: modelID)[ComputerOutcomeToolContract.name],
                           verify["description"] as? String)
        }
    }

    func testRetiredToolFilteringPreservesEveryOfferedNativeToolForBothPolicies() {
        for policy: ComputerInteractionPolicy in [.backgroundOnly, .foregroundAllowed] {
            for modelID in ["browser/chatgpt", "api/cerebras/gpt-oss-120b", "local-fixture"] {
                let offered = ComputerV2ToolContract.specs(for: modelID, interactionPolicy: policy)
                    + ComputerV2ToolContract.referenceSpecs(for: modelID, interactionPolicy: policy)
                    + [ComputerOutcomeToolContract.spec]
                let visible = ComputaModelToolCatalog.visibleToolDefinitions(offered, modelID: modelID)
                XCTAssertEqual(visible.compactMap { $0["name"] as? String },
                               offered.compactMap { $0["name"] as? String })
            }
        }
    }

    func testRestoredAppsSchemaRefreshReachesCerebrasWithoutRewritingFailedHistory() throws {
        let p = APIProviderDefinition(id: "cerebras-fixture", name: "Cerebras Fixture",
            baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions,
            models: [.init(id: "gpt-oss-120b", name: "GPT OSS")])
        let modelID = APIProviderCatalog.appModelID(providerID: p.id, modelID: p.models[0].id)
        let oldSchema: [String: Any] = ["type": "object", "properties": ["query": ["type": "string"]],
                                      "required": [String](), "additionalProperties": false]
        let canonical = try XCTUnwrap(ComputerV2ToolContract.specs(for: modelID)
            .first { $0["name"] as? String == "computer_v2_apps" }?["inputSchema"] as? [String: Any])
        for key in ["parameters", "inputSchema"] {
            let saved: [String: Any] = ["type": "function", "name": "computer_v2_apps", key: oldSchema]
            let visible = try XCTUnwrap(ComputaModelToolCatalog.visibleToolDefinitions([saved], modelID: modelID).first)
            XCTAssertEqual(visible[key] as? NSDictionary, canonical as NSDictionary)
            XCTAssertEqual(saved[key] as? NSDictionary, oldSchema as NSDictionary, "Saved definitions remain unchanged")
        }
        let saved: [String: Any] = ["type": "function", "name": "computer_v2_apps", "parameters": oldSchema]
        let history: [[String: Any]] = [
            ["role": "user", "content": "Find the requested application"],
            ["type": "function_call", "call_id": "old-empty-apps", "name": "computer_v2_apps",
             "namespace": "functions", "arguments": "{\"query\":\"\"}"],
            ["type": "function_call_output", "call_id": "old-empty-apps", "output": "Invalid computer V2 argument: query"],
            ["role": "user", "content": "Continue using current tools"],
        ]
        let prepared = try request(["tools": [["type": "namespace", "name": "functions", "tools": [saved]]],
                                    "input": history], provider: p, toolNaming: .semantic)
        let wire = try XCTUnwrap(try wireFunctions(prepared).first)
        XCTAssertEqual(wire["parameters"] as? NSDictionary, canonical as NSDictionary)
        let properties = try XCTUnwrap(canonical["properties"] as? [String: Any])
        let query = try XCTUnwrap(properties["query"] as? [String: Any])
        XCTAssertEqual(query["minLength"] as? Int, 1)
        XCTAssertNotNil(query["pattern"] as? String); XCTAssertNil(query["maxLength"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let oldCall = try XCTUnwrap(messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.first?.first)
        XCTAssertEqual((oldCall["function"] as? [String: Any])?["arguments"] as? String, "{\"query\":\"\"}")
        XCTAssertEqual(messages.first { $0["role"] as? String == "tool" }?["content"] as? String,
                       "Invalid computer V2 argument: query")
        let alias = try XCTUnwrap(wire["name"] as? String)
        for arguments in ["{}", "{\"query\":\"Outlook\"}"] {
            XCTAssertNoThrow(try decode(["role": "assistant", "tool_calls": [["id": "current-apps", "type": "function",
                "function": ["name": alias, "arguments": arguments]]]], finish: "tool_calls", request: prepared, model: p.models[0].id))
        }
        for arguments in ["{\"query\":\"\"}", "{\"query\":\" \\t\"}", "{\"query\":\"\\u200b\"}"] {
            XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "current-apps", "type": "function",
                "function": ["name": alias, "arguments": arguments]]]], finish: "tool_calls", request: prepared, model: p.models[0].id)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
        }
    }

    func testRestoredBrowserReadFieldsRefreshWithoutChangingViewsOrFailedHistory() throws {
        let p = APIProviderDefinition(id: "cerebras-fixture", name: "Cerebras Fixture",
            baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions,
            models: [.init(id: "gpt-oss-120b", name: "GPT OSS")])
        let modelID = APIProviderCatalog.appModelID(providerID: p.id, modelID: p.models[0].id)
        for name in ["browser_tabs", "browser_read"] {
            var oldProperties: [String: Any] = ["cursor": ["type": "string"]]
            if name == "browser_read" {
                oldProperties["query"] = ["type": "string"]
                oldProperties["view"] = ["type": "string", "enum": ["overview", "content", "all", "headings", "links"]]
            }
            let oldSchema: [String: Any] = ["type": "object", "properties": oldProperties,
                                          "required": [String](), "additionalProperties": false]
            for key in ["parameters", "inputSchema"] {
                let old: [String: Any] = ["type": "function", "name": name, key: oldSchema]
                let refreshed = try XCTUnwrap(ComputaModelToolCatalog.visibleToolDefinitions([old], modelID: modelID).first)
                let schema = try XCTUnwrap(refreshed[key] as? [String: Any])
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                for field in ["cursor", "query"] where oldProperties[field] != nil {
                    let property = try XCTUnwrap(properties[field] as? [String: Any])
                    XCTAssertEqual(property["minLength"] as? Int, 1)
                    if field == "cursor" {
                        XCTAssertEqual(property["type"] as? [String], ["string", "null"])
                    } else { XCTAssertEqual(property["type"] as? String, "string") }
                    XCTAssertNotNil(property["description"], "Recognized native cursor catalogs receive current guidance")
                }
                XCTAssertEqual(properties["view"] as? NSDictionary, oldProperties["view"] as? NSDictionary)
                XCTAssertEqual(schema["required"] as? [String], [])
                XCTAssertEqual(old[key] as? NSDictionary, oldSchema as NSDictionary)
            }
            let saved: [String: Any] = ["type": "function", "name": name, "parameters": oldSchema]
            let history: [[String: Any]] = [
                ["role": "user", "content": "Read the built-in browser"],
                ["type": "function_call", "call_id": "old-empty-cursor", "name": name,
                 "namespace": "functions", "arguments": "{\"cursor\":\"\"}"],
                ["type": "function_call_output", "call_id": "old-empty-cursor", "output": "Invalid built-in browser string argument."],
                ["role": "user", "content": "Continue with current tools"],
            ]
            let prepared = try request(["tools": [["type": "namespace", "name": "functions", "tools": [saved]]],
                                        "input": history], provider: p, toolNaming: .semantic)
            let wire = try XCTUnwrap(try wireFunctions(prepared).first)
            let parameters = try XCTUnwrap(wire["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
            for field in ["cursor", "query"] where oldProperties[field] != nil {
                let property = try XCTUnwrap(properties[field] as? [String: Any])
                XCTAssertEqual(property["minLength"] as? Int, 1)
                if field == "cursor" {
                    XCTAssertEqual(property["type"] as? [String], ["string", "null"])
                } else { XCTAssertEqual(property["type"] as? String, "string") }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let oldCall = try XCTUnwrap(messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.first?.first)
            XCTAssertEqual((oldCall["function"] as? [String: Any])?["arguments"] as? String, "{\"cursor\":\"\"}")
            XCTAssertEqual(messages.first { $0["role"] as? String == "tool" }?["content"] as? String,
                           "Invalid built-in browser string argument.")
            let alias = try XCTUnwrap(wire["name"] as? String)
            XCTAssertNoThrow(try decode(["role": "assistant", "tool_calls": [["id": "current-browser", "type": "function",
                "function": ["name": alias, "arguments": "{}"]]]], finish: "tool_calls", request: prepared, model: p.models[0].id))
            for field in ["cursor", "query"] where oldProperties[field] != nil {
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [field: ""]), as: UTF8.self)
                XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "current-browser", "type": "function",
                    "function": ["name": alias, "arguments": arguments]]]], finish: "tool_calls", request: prepared, model: p.models[0].id)) {
                        XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                }
            }
        }
    }

    private func savedBrowserCursorSchema(_ name: String = "browser_read") throws -> [String: Any] {
        var properties: [String: Any] = ["cursor": ["type": "string"]]
        if name == "browser_read" {
            properties["view"] = ["type": "string", "enum": ["overview", "content", "all", "headings", "links"]]
            properties["query"] = ["type": "string"]
        }
        return ["type": "object", "properties": properties, "required": [String](), "additionalProperties": false]
    }

    /// Independently describes the saved 231–233 composition; never derive it
    /// from today's definition or migration code.
    private func savedDisjointBrowserReadSchema() -> [String: Any] {
        let view: [String: Any] = ["type": "string", "enum": ["overview", "content", "all", "headings", "links"]]
        let query: [String: Any] = ["type": "string", "minLength": 1]
        return ["type": "object", "properties": ["view": view, "query": query,
            "cursor": ["type": ["string", "null"], "minLength": 1]],
            "required": [String](), "additionalProperties": false, "oneOf": [
                ["type": "object", "properties": ["view": view, "query": query, "cursor": ["type": "null"]],
                 "required": [String](), "additionalProperties": false],
                ["type": "object", "properties": ["cursor": ["type": "string", "minLength": 1]],
                 "required": ["cursor"], "additionalProperties": false],
            ]]
    }

    func testNullableBrowserCursorsPreserveRawCallsAndCompletedHistoryUnderSavedCatalogs() throws {
        let providers = [provider, APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
            wireAPI: .responses, models: provider.models)]
        for name in ["browser_read", "browser_tabs"] {
            let definition: [String: Any]
            if name == "browser_read" { definition = EmbeddedBrowserTools.legacyReadDefinition }
            else { definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name }) }
            let current = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            for p in providers {
                for schema in [try savedBrowserCursorSchema(name), current] {
                    let catalog: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [
                        ["type": "function", "name": name, "description": "Saved snapshot/index action guidance", "parameters": schema]]]]
                    let prepared = try request(["tools": catalog], provider: p)
                    XCTAssertEqual(prepared.tools.first?.schema as? NSDictionary, current as NSDictionary)
                    XCTAssertEqual(prepared.tools.first?.description,
                        definition["description"] as? String)
                    let nullArguments = name == "browser_read" ? "{ \"cursor\": null, \"view\": \"content\" }" : " { \"cursor\" : null } "
                    for arguments in [nullArguments, #"{"cursor":"exact-issued-cursor"}"#, "{}"] {
                        let reply = try browserMutationReply(arguments, request: prepared, callID: "read-current")
                        let call = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first)
                        XCTAssertEqual((call["arguments"] as? String).map { Data($0.utf8) }, Data(arguments.utf8))
                        let history = [call, ["type": "function_call_output", "call_id": "read-current", "output": "Observed page"]]
                        let next = try request(["tools": catalog, "input": history], provider: p)
                        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: next.body) as? [String: Any])
                        let actual: String?
                        if p.wireAPI == .responses {
                            actual = (body["input"] as? [[String: Any]])?.first?["arguments"] as? String
                        } else {
                            let calls = (body["messages"] as? [[String: Any]])?.flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }
                            actual = (calls?.first?["function"] as? [String: Any])?["arguments"] as? String
                        }
                        XCTAssertEqual(actual.map { Data($0.utf8) }, Data(arguments.utf8))
                        XCTAssertEqual(next.tools.first?.schema as? NSDictionary, current as NSDictionary)
                    }
                    for arguments in [#"{"cursor":""}"#, #"{"cursor":false}"#, #"{"cursor":123}"#,
                        #"{"cursor":[]}"#, #"{"cursor":{}}"#, #"{"view":null}"#, #"{"query":null}"#,
                        #"{"cursor":null,"click_ref":"bclick_unknown"}"#] {
                        XCTAssertThrowsError(try browserMutationReply(arguments, request: prepared)) {
                            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                        }
                    }
                }
            }
        }
    }

    func testBrowserReadFlatFormsPreserveNativeFilterChecksAndCompletedHistoryOnBothWires() throws {
        let current = try XCTUnwrap(EmbeddedBrowserTools.legacyReadDefinition["inputSchema"] as? [String: Any])
        func engineThin(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { !["description", "minLength"].contains($0.key) }.mapValues(engineThin)
            }
            if let array = value as? [Any] { return array.map(engineThin) }
            return value
        }
        var nullableFlat = try savedBrowserCursorSchema()
        var flatProperties = try XCTUnwrap(nullableFlat["properties"] as? [String: [String: Any]])
        flatProperties["cursor"]?["type"] = ["string", "null"]
        nullableFlat["properties"] = flatProperties
        let schemas = [try savedBrowserCursorSchema(), nullableFlat, current, savedDisjointBrowserReadSchema(),
                       try XCTUnwrap(engineThin(savedDisjointBrowserReadSchema()) as? [String: Any])]
        let providers = [provider, APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
            wireAPI: .responses, models: provider.models)]
        let historicalArguments = " { \"cursor\" : \"prior-issued\", \"view\":\"content\", \"query\": \"café é\" } "
        for p in providers {
            for schema in schemas {
                let catalog: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [
                    ["type": "function", "name": "browser_read", "parameters": schema]]]]
                let history: [[String: Any]] = [
                    ["type": "function_call", "name": "browser_read", "namespace": "functions", "call_id": "historical-read",
                     "arguments": historicalArguments],
                    ["type": "function_call_output", "call_id": "historical-read", "output": "Historical observation"],
                ]
                let prepared = try request(["tools": catalog, "input": history], provider: p)
                XCTAssertEqual(prepared.tools.first?.schema as? NSDictionary, current as NSDictionary)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
                let wireHistory = try XCTUnwrap(body[p.wireAPI == .responses ? "input" : "messages"] as? [[String: Any]])
                let arguments: String?
                if p.wireAPI == .responses { arguments = wireHistory.first?["arguments"] as? String }
                else {
                    arguments = (wireHistory.compactMap { $0["tool_calls"] as? [[String: Any]] }.first?.first?["function"] as? [String: Any])?["arguments"] as? String
                }
                XCTAssertEqual(arguments.map { Data($0.utf8) }, Data(historicalArguments.utf8))
                for valid in ["{}", #"{"view":"content","query":"café"}"#,
                              #"{"cursor":null,"view":"content","query":"café"}"#,
                              #"{"cursor":"exact-next-cursor"}"#,
                              #"{"cursor":"exact-next-cursor","view":"content"}"#,
                              #"{"cursor":"exact-next-cursor","query":"café"}"#,
                              historicalArguments] {
                    // Syntax preserves the exact requested filters; only the
                    // native retained cursor can decide whether they match.
                    let reply = try browserMutationReply(valid, request: prepared)
                    XCTAssertEqual(((reply.response["output"] as? [[String: Any]])?.first?["arguments"] as? String).map { Data($0.utf8) }, Data(valid.utf8))
                }
                for invalid in [#"{"cursor":"","view":"content"}"#, #"{"cursor":"issued","query":null}"#,
                                #"{"cursor":"issued","view":"unknown"}"#, #"{"cursor":false}"#] {
                    XCTAssertThrowsError(try browserMutationReply(invalid, request: prepared)) {
                        XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                    }
                }
            }
        }
    }

    func testModifiedBrowserReadCompositionIsNeverMigratedAsAnAppContract() throws {
        let current = savedDisjointBrowserReadSchema()
        var stringRoot = current
        var properties = try XCTUnwrap(current["properties"] as? [String: [String: Any]])
        properties["cursor"]?["type"] = "string"; stringRoot["properties"] = properties
        var narrowedBranch = current
        var branches = try XCTUnwrap(current["oneOf"] as? [[String: Any]])
        var freshProperties = try XCTUnwrap(branches[0]["properties"] as? [String: [String: Any]])
        freshProperties["view"]?["enum"] = ["content"]
        branches[0]["properties"] = freshProperties; narrowedBranch["oneOf"] = branches
        var widenedBranch = current
        branches = try XCTUnwrap(current["oneOf"] as? [[String: Any]])
        branches[1]["additionalProperties"] = true; widenedBranch["oneOf"] = branches
        for schema in [stringRoot, narrowedBranch, widenedBranch] {
            let catalog: [[String: Any]] = [["type": "function", "name": "browser_read", "parameters": schema]]
            XCTAssertNil(ComputaModelToolCatalog.browserCursorSchemaVariants(name: "browser_read", namespace: nil, schema: schema))
            XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(catalog, modelID: "fixture") as NSArray, catalog as NSArray)
            let prepared = try request(["tools": catalog])
            XCTAssertEqual(prepared.tools.first?.schema as? NSDictionary, schema as NSDictionary)
        }
        let foreign: [[String: Any]] = [["type": "namespace", "name": "mcp_external", "tools": [
            ["type": "function", "name": "browser_read", "parameters": current]]]]
        XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(foreign, modelID: "fixture") as NSArray, foreign as NSArray)
        let oldMixedCall: [String: Any] = ["type": "function_call", "name": "browser_read", "namespace": "mcp_external",
            "call_id": "foreign-old", "arguments": #"{"cursor":"issued","view":"content"}"#]
        XCTAssertThrowsError(try request(["tools": foreign, "input": [oldMixedCall,
            ["type": "function_call_output", "call_id": "foreign-old", "output": "Old foreign result"]]])) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
        }
    }

    func testNullableBrowserCursorMigrationPreservesForeignRequiredAndModifiedSchemas() throws {
        for name in ["browser_read", "browser_tabs"] {
            let original = try savedBrowserCursorSchema(name)
            var required = original; required["required"] = ["cursor"]
            var narrowed = original
            var properties = try XCTUnwrap(original["properties"] as? [String: Any])
            if name == "browser_read" { properties["view"] = ["type": "string", "enum": ["content"]] }
            else { properties["cursor"] = ["type": "string", "enum": ["only-this-cursor"]] }
            narrowed["properties"] = properties
            var extra = original
            properties = try XCTUnwrap(original["properties"] as? [String: Any]); properties["custom_field"] = ["type": "string"]
            extra["properties"] = properties
            var restricted = original
            properties = try XCTUnwrap(original["properties"] as? [String: Any]); properties["cursor"] = ["type": "string", "maxLength": 12]
            restricted["properties"] = properties
            let cases: [([String: Any], String?)] = [(original, "mcp_external"), (required, nil), (narrowed, nil), (extra, nil), (restricted, nil)]
            for (schema, namespace) in cases {
                let function: [String: Any] = ["type": "function", "name": name, "parameters": schema]
                let definitions: [[String: Any]] = namespace.map { [["type": "namespace", "name": $0, "tools": [function]]] } ?? [function]
                XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: "fixture") as NSArray, definitions as NSArray)
                let prepared = try request(["tools": definitions])
                XCTAssertEqual(prepared.tools.first?.schema as? NSDictionary, schema as NSDictionary)
                var call: [String: Any] = ["type": "function_call", "name": name, "call_id": "old", "arguments": #"{"cursor":null}"#]
                if let namespace { call["namespace"] = namespace }
                XCTAssertThrowsError(try request(["tools": definitions, "input": [call,
                    ["type": "function_call_output", "call_id": "old", "output": "Historical result"]]])) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                }
            }
            let custom: [[String: Any]] = [["type": "custom", "name": name, "format": ["type": "text"]]]
            XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(custom, modelID: "fixture") as NSArray, custom as NSArray)
        }
    }

    private func nativeBrowserTool(_ name: String) throws -> [String: Any] {
        let definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
        return ["type": "function", "name": name, "description": try XCTUnwrap(definition["description"]),
                "parameters": try XCTUnwrap(definition["inputSchema"])]
    }

    func testUnboundCatalogFiltersOnlyOriginalNativeBindingDependentShapes() throws {
        let native = try EmbeddedBrowserTools.definitions().map { try nativeBrowserTool(XCTUnwrap($0["name"] as? String)) }
        let kept = ["browser_tabs", "browser_open", "browser_bind"]
        func names(_ values: [[String: Any]]) -> [String] { values.compactMap { $0["name"] as? String } }
        for namespace in [nil, "functions"] as [String?] {
            let catalog = namespace.map { [["type": "namespace", "name": $0, "tools": native]] } ?? native
            XCTAssertTrue(ComputaModelToolCatalog.requiresBrowserToolAvailability(catalog))
            let unbound = ComputaModelToolCatalog.visibleToolDefinitions(catalog, modelID: "fixture", browserToolAvailability: .unbound)
            let children: [[String: Any]]
            if namespace == nil { children = unbound }
            else { children = try XCTUnwrap(unbound.first?["tools"] as? [[String: Any]]) }
            XCTAssertEqual(names(children), kept)
            XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(catalog, modelID: "fixture", browserToolAvailability: .bound) as NSArray,
                ComputaModelToolCatalog.visibleToolDefinitions(catalog, modelID: "fixture") as NSArray)
        }
        var savedRead = try nativeBrowserTool("browser_read"); savedRead["parameters"] = try savedBrowserCursorSchema()
        for original in [savedRead, ["type": "function", "name": "browser_click", "parameters": legacyBrowserMutationSchema("browser_click")],
                         ["type": "function", "name": "browser_fill", "parameters": assertedBrowserMutationSchema("browser_fill")]] {
            XCTAssertTrue(ComputaModelToolCatalog.requiresBrowserToolAvailability([original]))
            XCTAssertTrue(ComputaModelToolCatalog.visibleToolDefinitions([original], modelID: "fixture", browserToolAvailability: .unbound).isEmpty)
        }
        var narrowed = try nativeBrowserTool("browser_navigate")
        var schema = try XCTUnwrap(narrowed["parameters"] as? [String: Any])
        var properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        properties["url"]?["minLength"] = 9_999; schema["properties"] = properties; narrowed["parameters"] = schema
        var conflicting = try nativeBrowserTool("browser_click"); conflicting["inputSchema"] = schema
        var extra = try nativeBrowserTool("browser_close")
        schema = try XCTUnwrap(extra["parameters"] as? [String: Any]); schema["properties"] = ["extra": ["type": "string"]]; extra["parameters"] = schema
        let custom: [String: Any] = ["type": "custom", "name": "browser_click", "format": ["type": "text"]]
        for original in [narrowed, conflicting, extra, custom] {
            XCTAssertFalse(ComputaModelToolCatalog.requiresBrowserToolAvailability([original]))
            XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions([original], modelID: "fixture", browserToolAvailability: .unbound) as NSArray,
                ComputaModelToolCatalog.visibleToolDefinitions([original], modelID: "fixture") as NSArray,
                "The gate cannot recognize a modified original only after constraint refresh")
        }
        for (name, field, constraint) in [("browser_continue", "cursor", "minLength"), ("browser_click", "click_ref", "minLength"),
                                          ("browser_wait", "timeout_ms", "minimum")] {
            var malformed = try nativeBrowserTool(name)
            var schema = try XCTUnwrap(malformed["parameters"] as? [String: Any])
            var fields = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            fields[field]?[constraint] = true; schema["properties"] = fields; malformed["parameters"] = schema
            XCTAssertFalse(ComputaModelToolCatalog.requiresBrowserToolAvailability([malformed]), "JSON booleans are not numeric schema constraints")
            XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions([malformed], modelID: "fixture", browserToolAvailability: .unbound) as NSArray,
                ComputaModelToolCatalog.visibleToolDefinitions([malformed], modelID: "fixture") as NSArray)
        }
        let foreign: [[String: Any]] = [["type": "namespace", "name": "mcp_external", "tools": native]]
        XCTAssertFalse(ComputaModelToolCatalog.requiresBrowserToolAvailability(foreign))
        XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions(foreign, modelID: "fixture", browserToolAvailability: .unbound) as NSArray,
            ComputaModelToolCatalog.visibleToolDefinitions(foreign, modelID: "fixture") as NSArray)
        let mixed: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [try nativeBrowserTool("browser_close"), function]]]
        XCTAssertEqual((ComputaModelToolCatalog.visibleToolDefinitions(mixed, modelID: "fixture", browserToolAvailability: .unbound)
            .first?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["read"])
        XCTAssertTrue(ComputaModelToolCatalog.visibleToolDefinitions([["type": "namespace", "name": "functions",
            "tools": [try nativeBrowserTool("browser_close")]]], modelID: "fixture", browserToolAvailability: .unbound).isEmpty)
        XCTAssertFalse(ComputaModelToolCatalog.requiresBrowserToolAvailability([]))
        XCTAssertFalse(ComputaModelToolCatalog.requiresBrowserToolAvailability(native.filter { kept.contains($0["name"] as? String ?? "") }))
    }

    func testUnboundProjectionPreservesHistoryWireNamesAndRejectsUnofferedCallsOnBothWires() throws {
        let click = try nativeBrowserTool("browser_click"), tabs = try nativeBrowserTool("browser_tabs")
        let catalog = [function, click, tabs]
        let arguments = " { \"click_ref\" : \"bclick_old-é\" } "
        let history: [[String: Any]] = [
            ["type": "function_call", "name": "browser_click", "call_id": "prior-click", "arguments": arguments],
            ["type": "function_call_output", "call_id": "prior-click", "output": "Original literal observation\nUntouched."],
            ["role": "user", "content": "Open the current mailbox."]]
        for wire in APIProviderDefinition.WireAPI.allCases {
            let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: wire, models: provider.models)
            let all = try request(["tools": catalog, "input": history], provider: p)
            let restricted = try request(["tools": catalog, "input": history], provider: p, browserToolAvailability: .unbound)
            XCTAssertEqual(restricted.tools.map(\.name), ["read", "browser_tabs"])
            XCTAssertEqual(restricted.tools.map(\.wireName), all.tools.filter { $0.name != "browser_click" }.map(\.wireName))
            let originalBody = try XCTUnwrap(JSONSerialization.jsonObject(with: all.body) as? [String: Any])
            let restrictedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: restricted.body) as? [String: Any])
            let historyKey = wire == .responses ? "input" : "messages"
            XCTAssertEqual(originalBody[historyKey] as? NSArray, restrictedBody[historyKey] as? NSArray)
            XCTAssertTrue(String(decoding: restricted.body, as: UTF8.self).contains("prior-click"))
            let hidden = try XCTUnwrap(all.tools.first { $0.name == "browser_click" })
            let response: [String: Any]
            if wire == .responses {
                response = ["id": "r-hidden", "object": "response", "status": "completed", "model": p.models[0].id,
                    "output": [["id": "fc-hidden", "type": "function_call", "status": "completed", "call_id": "new-hidden",
                                "name": hidden.name, "arguments": arguments]]]
            } else {
                response = ["id": "r-hidden", "model": p.models[0].id, "choices": [["index": 0, "finish_reason": "tool_calls",
                    "message": ["role": "assistant", "tool_calls": [["id": "new-hidden", "type": "function",
                        "function": ["name": hidden.wireName, "arguments": arguments]]]]]]]
            }
            let result = APIProviderHTTPClient.Result(body: try JSONSerialization.data(withJSONObject: response), contentType: "application/json")
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: restricted)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
            }
            for choice in [["type": "function", "name": "browser_click"], "required"] as [Any] {
                XCTAssertThrowsError(try request(["tools": [click], "tool_choice": choice], provider: p, browserToolAvailability: .unbound)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
                }
            }
            XCTAssertNoThrow(try request(["tools": [click], "tool_choice": "none"], provider: p, browserToolAvailability: .unbound))
            XCTAssertThrowsError(try request(["tools": [click, click]], provider: p, browserToolAvailability: .unbound))
            XCTAssertThrowsError(try request(["tools": catalog, "input": [history[0]]], provider: p, browserToolAvailability: .unbound))
            let restored = try request(["tools": catalog, "input": history], provider: p, browserToolAvailability: .bound)
            XCTAssertEqual(restored.body, all.body)
        }
    }

    func testCorrectionKeepsTheAdmittedUnboundCatalog() throws {
        let prepared = try request(["tools": [function, try nativeBrowserTool("browser_click"), try nativeBrowserTool("browser_tabs")]],
            browserToolAvailability: .unbound)
        let corrected = try APIModelResponseCodec.correctiveRequest(prepared, rejectionDetails: rejectedDetails(prepared, arguments: #"{"path":false}"#))
        XCTAssertEqual(corrected.tools.map(\.wireName), prepared.tools.map(\.wireName))
        XCTAssertEqual(corrected.allowedTools, prepared.allowedTools)
        XCTAssertFalse(corrected.tools.contains { $0.name == "browser_click" })
        XCTAssertEqual(try wireFunctions(corrected) as NSArray, try wireFunctions(prepared) as NSArray)
    }

    func testCurrentReferencesNarrowOnlyWholeRecognizedNativeMutationDefinitions() throws {
        let refs = EmbeddedBrowserCurrentActionReferences(clickReferences: ["bclick_first", "bclick_prior-page"], fillReferences: ["bfill_current"])
        func project(_ definitions: [[String: Any]], refs supplied: EmbeddedBrowserCurrentActionReferences? = nil) -> [[String: Any]] {
            ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: "fixture",
                browserToolAvailability: .bound, browserActionReferences: supplied ?? refs)
        }
        for name in ["browser_click", "browser_fill"] {
            let field = name == "browser_click" ? "click_ref" : "fill_ref"
            let canonical = try nativeBrowserTool(name)
            let current = try XCTUnwrap(canonical["parameters"] as? [String: Any])
            for schema in [legacyBrowserMutationSchema(name), assertedBrowserMutationSchema(name), current] {
                for namespace in [nil, "functions"] as [String?] {
                    let definition: [String: Any] = ["type": "function", "name": name, "parameters": schema, "inputSchema": schema]
                    let catalog = namespace.map { [["type": "namespace", "name": $0, "tools": [definition]]] } ?? [definition]
                    let visible = project(catalog)
                    let tool = try XCTUnwrap(namespace == nil ? visible.first : (visible.first?["tools"] as? [[String: Any]])?.first)
                    var expected = current
                    var fields = try XCTUnwrap(expected["properties"] as? [String: [String: Any]])
                    fields[field]?["enum"] = name == "browser_click" ? refs.clickReferences : refs.fillReferences
                    expected["properties"] = fields
                    for key in ["parameters", "inputSchema"] { XCTAssertEqual(tool[key] as? NSDictionary, expected as NSDictionary) }
                    XCTAssertTrue(project(catalog, refs: .empty).isEmpty)
                }
            }
            var modified: [[String: Any]] = []
            for constraint in [["enum": ["custom-only"]], ["minLength": 9_999], ["minLength": true]] as [[String: Any]] {
                var schema = current, fields = try XCTUnwrap(current["properties"] as? [String: [String: Any]])
                fields[field]?.merge(constraint) { _, value in value }; schema["properties"] = fields
                var tool = canonical; tool["parameters"] = schema; modified.append(tool)
            }
            var extra = current, fields = try XCTUnwrap(current["properties"] as? [String: [String: Any]])
            fields["custom"] = ["type": "string"]; extra["properties"] = fields
            var extraTool = canonical; extraTool["parameters"] = extra; modified.append(extraTool)
            var dual = canonical; dual["inputSchema"] = extra; modified.append(dual)
            dual = extraTool; dual["inputSchema"] = current; modified.append(dual)
            modified.append(["type": "custom", "name": name, "format": ["type": "text"]])
            for tool in modified {
                XCTAssertEqual(project([tool]) as NSArray, [tool] as NSArray)
                XCTAssertEqual(project([tool], refs: .empty) as NSArray, [tool] as NSArray)
            }
            let foreign: [[String: Any]] = [["type": "namespace", "name": "mcp_external", "tools": [canonical]]]
            XCTAssertEqual(project(foreign) as NSArray, foreign as NSArray)
            XCTAssertEqual(ComputaModelToolCatalog.visibleToolDefinitions([canonical], modelID: "fixture") as NSArray,
                           [canonical] as NSArray, "Website/default callers receive no API-only enum")
        }
        let onlyClick = project([try nativeBrowserTool("browser_click"), try nativeBrowserTool("browser_fill")],
            refs: .init(clickReferences: refs.clickReferences, fillReferences: []))
        XCTAssertEqual(onlyClick.compactMap { $0["name"] as? String }, ["browser_click"])
    }

    func testCurrentReferenceEnumsPreserveHistoricalArgumentsAndStableNamesOnBothWires() throws {
        let refs = EmbeddedBrowserCurrentActionReferences(clickReferences: ["bclick_current"], fillReferences: ["bfill_current"])
        for wire in APIProviderDefinition.WireAPI.allCases {
            let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: wire, models: provider.models)
            for name in ["browser_click", "browser_fill"] {
                let key = name == "browser_click" ? "click_ref" : "fill_ref"
                let current = name == "browser_click" ? refs.clickReferences[0] : refs.fillReferences[0]
                let other = name == "browser_click" ? refs.fillReferences[0] : refs.clickReferences[0]
                let suffix = name == "browser_fill" ? ", \"text\" : \"  e\\u0301 🧭\\n\" " : ""
                let old = " { \"\(key)\" : \"retired-token\"\(suffix) } "
                let valid = " { \"\(key)\" : \"\(current)\"\(suffix) } "
                for schema in [legacyBrowserMutationSchema(name), assertedBrowserMutationSchema(name), try XCTUnwrap(nativeBrowserTool(name)["parameters"] as? [String: Any])] {
                    let catalog: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [function,
                        ["type": "function", "name": name, "parameters": schema]]]]
                    let history: [[String: Any]] = [["type": "function_call", "name": name, "namespace": "functions", "call_id": "old", "arguments": old],
                        ["type": "function_call_output", "call_id": "old", "output": "Historical action; outcome unverified."],
                        ["role": "user", "content": "Continue with the current target."]]
                    let unrestricted = try request(["tools": catalog, "input": history], provider: p)
                    let prepared = try request(["tools": catalog, "input": history], provider: p, browserToolAvailability: .bound, browserActionReferences: refs)
                    XCTAssertEqual(prepared.tools.map(\.wireName), unrestricted.tools.map(\.wireName))
                    let a = try XCTUnwrap(JSONSerialization.jsonObject(with: unrestricted.body) as? [String: Any])
                    let b = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
                    XCTAssertEqual(a[wire == .responses ? "input" : "messages"] as? NSArray, b[wire == .responses ? "input" : "messages"] as? NSArray)
                    let reply = try browserMutationReply(valid, request: prepared, toolName: name)
                    let call = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first)
                    XCTAssertEqual((call["arguments"] as? String).map { Data($0.utf8) }, Data(valid.utf8))
                    for token in ["retired-token", other, ""] {
                        XCTAssertThrowsError(try browserMutationReply("{\"\(key)\":\"\(token)\"\(suffix)}", request: prepared, toolName: name)) {
                            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                        }
                    }
                    let next = try request(["tools": catalog, "input": history + [call, ["type": "function_call_output", "call_id": "new-ref-call", "output": "Dispatched once."]]],
                        provider: p, browserToolAvailability: .bound, browserActionReferences: .empty)
                    XCTAssertEqual(next.tools.map(\.name), ["read"])
                    XCTAssertEqual(next.historyCallIDs, ["old", "new-ref-call"])
                }
            }
        }
    }

    func testCurrentReferenceCorrectionIsAtomicGenericAndFrozen() throws {
        let click = try nativeBrowserTool("browser_click"), fill = try nativeBrowserTool("browser_fill")
        let refs = EmbeddedBrowserCurrentActionReferences(clickReferences: ["bclick_current"], fillReferences: [])
        let prepared = try request(["tools": [click, fill]], browserToolAvailability: .bound, browserActionReferences: refs)
        let valid: [String: Any] = ["id": "valid", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": #"{"click_ref":"bclick_current"}"#]]
        guard case .argumentsRejected(_, let details) = try APIModelResponseCodec.decodeForCorrection(
            correctionResult(prepared, arguments: #"{"click_ref":"retired"}"#, additionalCalls: [valid]), request: prepared) else {
            return XCTFail("A rejected enum must prevent the entire reply from publishing")
        }
        XCTAssertEqual(details.count, 1)
        XCTAssertNil(details[0].location, "Dynamic enums must not broaden the finite native schema recognizer")
        let corrected = try APIModelResponseCodec.correctiveRequest(prepared, rejectionDetails: details)
        XCTAssertEqual(try wireFunctions(corrected) as NSArray, try wireFunctions(prepared) as NSArray)
        XCTAssertEqual(corrected.allowedTools, prepared.allowedTools)
        for choice in [["type": "function", "name": "browser_fill"], "required"] as [Any] {
            XCTAssertThrowsError(try request(["tools": [fill], "tool_choice": choice], browserToolAvailability: .bound, browserActionReferences: refs)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
            }
        }
        XCTAssertThrowsError(try request(["tools": [click, click]], browserToolAvailability: .bound, browserActionReferences: .empty))
        XCTAssertThrowsError(try request(["tools": [click], "input": [["type": "function_call", "name": "browser_click", "call_id": "orphan", "arguments": #"{"click_ref":"old"}"#]]],
            browserToolAvailability: .bound, browserActionReferences: .empty))
    }

    func testCurrentReferenceProjectionKeepsExistingSetAndEncodedRequestBounds() throws {
        let catalog = [try nativeBrowserTool("browser_click"), try nativeBrowserTool("browser_fill")]
        let tokens = (0..<120).map { String(format: "%03d", $0) + String(repeating: "x", count: 125) }
        let refs = EmbeddedBrowserCurrentActionReferences(clickReferences: Array(tokens.prefix(60)), fillReferences: Array(tokens.suffix(60)))
        XCTAssertTrue(refs.isValid)
        for invalid in [EmbeddedBrowserCurrentActionReferences(clickReferences: tokens + ["extra"], fillReferences: []),
                        .init(clickReferences: ["same"], fillReferences: ["same"]), .init(clickReferences: [""], fillReferences: []),
                        .init(clickReferences: [String(repeating: "x", count: 129)], fillReferences: []), .init(clickReferences: ["line\nbreak"], fillReferences: [])] {
            XCTAssertThrowsError(try request(["tools": catalog], browserToolAvailability: .bound, browserActionReferences: invalid)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidRequest)
            }
        }
        XCTAssertThrowsError(try request(["tools": catalog], browserToolAvailability: .unbound, browserActionReferences: refs))
        for wire in APIProviderDefinition.WireAPI.allCases {
            let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: wire, models: provider.models)
            let nativeRefs = EmbeddedBrowserCurrentActionReferences(
                clickReferences: (0..<60).map { "bclick_00000000-0000-4000-8000-" + String(format: "%012d", $0) },
                fillReferences: (0..<60).map { "bfill_00000000-0000-4000-8000-" + String(format: "%012d", $0) })
            XCTAssertTrue(nativeRefs.isValid)
            XCTAssertTrue(nativeRefs.clickReferences.allSatisfy { $0.utf8.count == 43 })
            XCTAssertTrue(nativeRefs.fillReferences.allSatisfy { $0.utf8.count == 42 })
            let unprojected = try request(["tools": catalog], provider: p, browserToolAvailability: .bound)
            let projected = try request(["tools": catalog], provider: p, browserToolAvailability: .bound, browserActionReferences: nativeRefs)
            print("CURRENT_REFERENCE_PAYLOAD wire=\(wire.rawValue) before=\(unprojected.body.count) after=\(projected.body.count) added=\(projected.body.count - unprojected.body.count)")
            XCTAssertGreaterThan(projected.body.count, unprojected.body.count)
            func sized(_ count: Int) throws -> APIModelResponseCodec.Request {
                try request(["tools": catalog, "input": [["role": "user", "content": String(repeating: "x", count: count)]]],
                    provider: p, browserToolAvailability: .bound, browserActionReferences: refs)
            }
            let base = try sized(0), padding = 2_000_000 - base.body.count
            XCTAssertGreaterThan(padding, 0)
            XCTAssertEqual(try sized(padding).body.count, 2_000_000)
            XCTAssertThrowsError(try sized(padding + 1)) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidRequest) }
        }
    }

    func testSeparateContinuationUsesOnlyRegisteredNativeCapabilityAndKeepsForeignContracts() throws {
        let fresh = try nativeBrowserTool("browser_read"), next = try nativeBrowserTool("browser_continue")
        var legacy = fresh; legacy["parameters"] = try XCTUnwrap(EmbeddedBrowserTools.legacyReadDefinition["inputSchema"])
        legacy["description"] = EmbeddedBrowserTools.legacyReadDefinition["description"]
        func project(_ values: [[String: Any]]) -> [[String: Any]] {
            ComputaModelToolCatalog.visibleToolDefinitions(values, modelID: "api/fixture")
        }
        XCTAssertEqual(project([legacy]) as NSArray, [legacy] as NSArray)
        let freshOnly = project([fresh])
        XCTAssertEqual(freshOnly.count, 1, "No unavailable continuation tool is inserted")
        XCTAssertEqual(freshOnly.first?["parameters"] as? NSDictionary, fresh["parameters"] as? NSDictionary)
        XCTAssertFalse((freshOnly.first?["description"] as? String ?? "").contains("browser_continue"))
        XCTAssertEqual(project([legacy, next]) as NSArray, [fresh, next] as NSArray)
        var thinned = next
        var thinSchema = try XCTUnwrap(next["parameters"] as? [String: Any])
        thinSchema["properties"] = ["cursor": ["type": "string"]]
        thinned["parameters"] = thinSchema
        XCTAssertEqual(project([legacy, thinned]) as NSArray, [fresh, next] as NSArray,
                       "The actual engine's omitted scalar constraints do not hide registered capability")
        let namespaced: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [legacy, next]]]
        XCTAssertEqual(project(namespaced).first?["tools"] as? NSArray, [fresh, next] as NSArray)
        var wrongRequired = next, extra = next, narrowed = next, openEnded = next
        var schema = try XCTUnwrap(next["parameters"] as? [String: Any]); schema["required"] = [String](); wrongRequired["parameters"] = schema
        schema = try XCTUnwrap(next["parameters"] as? [String: Any])
        var fields = try XCTUnwrap(schema["properties"] as? [String: Any]); fields["view"] = ["type": "string"]
        schema["properties"] = fields; extra["parameters"] = schema
        schema = try XCTUnwrap(next["parameters"] as? [String: Any]); fields = try XCTUnwrap(schema["properties"] as? [String: Any])
        fields["cursor"] = ["type": "string", "enum": ["private-only"]]; schema["properties"] = fields; narrowed["parameters"] = schema
        schema = try XCTUnwrap(next["parameters"] as? [String: Any]); schema.removeValue(forKey: "additionalProperties")
        openEnded["parameters"] = schema
        for modified in [wrongRequired, extra, narrowed, openEnded, ["type": "custom", "name": "browser_continue", "format": ["type": "text"]]] {
            XCTAssertEqual(project([legacy, modified]) as NSArray, [legacy, modified] as NSArray)
        }
        let foreign: [[String: Any]] = [legacy, ["type": "namespace", "name": "mcp_external", "tools": [next]]]
        XCTAssertEqual(project(foreign) as NSArray, foreign as NSArray, "A foreign same-name tool grants no native capability")
        var restrictedRead = legacy
        schema = try XCTUnwrap(legacy["parameters"] as? [String: Any]); schema["required"] = ["cursor"]
        restrictedRead["parameters"] = schema
        XCTAssertEqual(project([restrictedRead, next]) as NSArray, [restrictedRead, next] as NSArray)
        var customFresh = fresh
        schema = try XCTUnwrap(fresh["parameters"] as? [String: Any]); fields = try XCTUnwrap(schema["properties"] as? [String: Any])
        fields["view"] = ["type": "string", "enum": ["content"]]; schema["properties"] = fields
        customFresh["parameters"] = schema
        XCTAssertEqual(project([customFresh, next]) as NSArray, [customFresh, next] as NSArray)
        let unregistered: [[String: Any]] = [
            ["type": "function_call", "name": "browser_continue", "call_id": "unknown", "arguments": #"{"cursor":"issued"}"#],
            ["type": "function_call_output", "call_id": "unknown", "output": "Claimed continuation"]]
        XCTAssertThrowsError(try request(["tools": [legacy], "input": unregistered]),
                             "Completed history cannot register an absent tool")
    }

    func testSplitReadContinuationIsStrictButPreservesBothHistoricalIdentitiesOnBothWires() throws {
        let read = try nativeBrowserTool("browser_read"), next = try nativeBrowserTool("browser_continue")
        let providers = [provider, APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
            wireAPI: .responses, models: provider.models)]
        let oldArgs = " { \"cursor\":\"prior-issued\", \"view\":\"content\", \"query\":\"café é\" } "
        let nextArgs = " { \"cursor\" : \"next-page-é\" } "
        for p in providers {
            let catalog: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [read, next]]]
            let old: [String: Any] = ["type": "function_call", "name": "browser_read", "namespace": "functions",
                "call_id": "old-read", "arguments": oldArgs]
            let history = [old, ["type": "function_call_output", "call_id": "old-read", "output": "Original observed page"]]
            let prepared = try request(["tools": catalog, "input": history], provider: p)
            XCTAssertEqual(prepared.tools.map(\.name), ["browser_read", "browser_continue"])
            for valid in ["{}", #"{"view":"content","query":"term"}"#] {
                XCTAssertNoThrow(try browserMutationReply(valid, request: prepared, toolName: "browser_read"))
            }
            for invalid in [#"{"cursor":null}"#, #"{"cursor":"issued"}"#, #"{"cursor":"issued","view":"content"}"#] {
                XCTAssertThrowsError(try browserMutationReply(invalid, request: prepared, toolName: "browser_read")) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                }
            }
            for invalid in ["{}", #"{"cursor":null}"#, #"{"cursor":""}"#, #"{"cursor":false}"#,
                            #"{"cursor":"issued","view":"content"}"#, #"{"cursor":"issued","query":"term"}"#] {
                XCTAssertThrowsError(try browserMutationReply(invalid, request: prepared, toolName: "browser_continue")) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                }
            }
            let reply = try browserMutationReply(nextArgs, request: prepared, callID: "new-continue", toolName: "browser_continue")
            let call = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first)
            XCTAssertEqual(call["name"] as? String, "browser_continue")
            XCTAssertEqual((call["arguments"] as? String).map { Data($0.utf8) }, Data(nextArgs.utf8))
            let continuation = try request(["tools": catalog, "input": history + [call,
                ["type": "function_call_output", "call_id": "new-continue", "output": "Next immutable page"]]], provider: p)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: continuation.body) as? [String: Any])
            let wire = try XCTUnwrap(body[p.wireAPI == .responses ? "input" : "messages"] as? [[String: Any]])
            let arguments: [String]
            if p.wireAPI == .responses {
                let calls = wire.filter { $0["type"] as? String == "function_call" }
                XCTAssertEqual(calls.compactMap { $0["name"] as? String }, ["browser_read", "browser_continue"])
                arguments = calls.compactMap { $0["arguments"] as? String }
            } else {
                let calls = wire.flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }
                let functions = calls.compactMap { $0["function"] as? [String: Any] }
                XCTAssertEqual(functions.compactMap { $0["name"] as? String }, prepared.tools.map(\.wireName))
                arguments = functions.compactMap { $0["arguments"] as? String }
            }
            XCTAssertEqual(arguments.map { Data($0.utf8) }, [oldArgs, nextArgs].map { Data($0.utf8) })
            XCTAssertThrowsError(try request(["tools": catalog, "input": [old]], provider: p), "History still requires genuine completion pairing")
        }
        let diagnostic = try request(["tools": [next]])
        let failure = try observedSchemaFailure(diagnostic, arguments: #"{"cursor":null}"#)
        XCTAssertEqual(failure.location, .init(tool: .browserContinue, schemaPath: [.cursor], expectedType: .string, actualType: .null))
        XCTAssertTrue(try XCTUnwrap(failure.location).isConsistent)
    }

    private func legacyBrowserMutationSchema(_ name: String) -> [String: Any] {
        var properties: [String: Any] = ["snapshot_id": ["type": "string"], "element_index": ["type": "integer"]]
        if name == "browser_fill" { properties["text"] = ["type": "string"] }
        return ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    private func assertedBrowserMutationSchema(_ name: String) -> [String: Any] {
        var schema = legacyBrowserMutationSchema(name)
        var properties = schema["properties"] as! [String: Any]
        properties["expected_role"] = ["type": "string", "minLength": 1, "maxLength": 128]
        properties["expected_label"] = ["type": "string", "maxLength": 4_096]
        schema["properties"] = properties; schema["required"] = properties.keys.sorted()
        return schema
    }

    private func browserMutationReply(_ arguments: String, request prepared: APIModelResponseCodec.Request,
                                      callID: String = "new-ref-call", toolName: String? = nil) throws -> APIModelResponseCodec.Reply {
        let tool = try XCTUnwrap(prepared.tools.first { toolName == nil || $0.name == toolName })
        if prepared.provider.wireAPI == .responses {
            let item: [String: Any] = ["id": "fc-ref", "type": "function_call", "status": "completed",
                "call_id": callID, "namespace": "functions", "name": tool.name, "arguments": arguments]
            let data = try JSONSerialization.data(withJSONObject: ["id": "response-ref", "object": "response",
                "status": "completed", "model": prepared.model.id, "output": [item]])
            return try APIModelResponseCodec.decode(.init(body: data, contentType: "application/json"), request: prepared)
        }
        return try decode(["role": "assistant", "tool_calls": [["id": callID, "type": "function",
            "function": ["name": tool.wireName, "arguments": arguments]]]], finish: "tool_calls", request: prepared, model: prepared.model.id)
    }

    func testBrowserMutationSchemaUpgradePreservesMixedHistoryAndNextInference() throws {
        let providers = [APIProviderDefinition(id: "cerebras-fixture", name: "Cerebras Fixture",
            baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions,
            models: [.init(id: "gpt-oss-120b", name: "GPT OSS")]),
            APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
                wireAPI: .responses, models: provider.models)]
        for p in providers {
            for name in ["browser_click", "browser_fill"] {
                let canonical = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any])
                for savedSchema in [legacyBrowserMutationSchema(name), assertedBrowserMutationSchema(name), canonical] {
                    let saved: [String: Any] = ["type": "function", "name": name, "parameters": savedSchema]
                    let catalog: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [saved]]]
                    var legacy: [String: Any] = ["snapshot_id": "11111111-1111-4111-8111-111111111111", "element_index": 0]
                    var current: [String: Any] = [name == "browser_fill" ? "fill_ref" : "click_ref":
                        (name == "browser_fill" ? "bfill_" : "bclick_") + "11111111-1111-4111-8111-111111111111"]
                    if name == "browser_fill" { legacy["text"] = "  Complete Cafe\u{301} value\n"; current["text"] = legacy["text"] }
                    let asserted = legacy.merging(["expected_role": name == "browser_fill" ? "AXTextField" : "AXButton",
                                                 "expected_label": "  Cafe\u{301} \"lookup\"  "]) { _, new in new }
                    func encoded(_ arguments: [String: Any]) throws -> String {
                        String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
                    }
                    let texts = try [legacy, asserted, current].map(encoded)
                    func pair(_ id: String, _ text: String) -> [[String: Any]] {
                        [["type": "function_call", "call_id": id, "namespace": "functions", "name": name, "arguments": text],
                         ["type": "function_call_output", "call_id": id, "output": "Historical dispatch; outcome unverified."]]
                    }
                    let history = pair("legacy-call", texts[0]) + pair("asserted-call", texts[1]) + pair("ref-call", texts[2])
                        + [["role": "user", "content": "Continue the authorized task."]]
                    func verifyWire(_ request: APIModelResponseCodec.Request, expectedArguments: [String]) throws {
                        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
                        let arguments: [String]
                        let schema: [String: Any]
                        if p.wireAPI == .responses {
                            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
                            arguments = input.filter { $0["type"] as? String == "function_call" }.compactMap { $0["arguments"] as? String }
                            let namespace = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
                            schema = try XCTUnwrap((namespace["tools"] as? [[String: Any]])?.first?["parameters"] as? [String: Any])
                        } else {
                            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                            arguments = messages.flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }
                                .compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }
                            schema = try XCTUnwrap(try wireFunctions(request).first?["parameters"] as? [String: Any])
                        }
                        XCTAssertEqual(schema as NSDictionary, canonical as NSDictionary)
                        XCTAssertEqual(arguments.map { Data($0.utf8) }, expectedArguments.map { Data($0.utf8) })
                    }
                    let prepared = try request(["tools": catalog, "input": history], provider: p, toolNaming: .semantic)
                    try verifyWire(prepared, expectedArguments: texts)
                    let reply = try browserMutationReply(texts[2], request: prepared)
                    let newCall = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" })
                    XCTAssertEqual((newCall["arguments"] as? String).map { Data($0.utf8) }, Data(texts[2].utf8))
                    let nextHistory = history + [newCall,
                        ["type": "function_call_output", "call_id": "new-ref-call", "output": "Current dispatch; outcome unverified."]]
                    let next = try request(["tools": catalog, "input": nextHistory], provider: p, toolNaming: .semantic)
                    XCTAssertEqual(next.historyCallIDs, ["legacy-call", "asserted-call", "ref-call", "new-ref-call"])
                    try verifyWire(next, expectedArguments: texts + [texts[2]])
                }
            }
        }
    }

    func testBrowserHistoryCompatibilityNeverAdmitsPartialOrNewLegacyCalls() throws {
        let providers = [provider, APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
            wireAPI: .responses, models: provider.models)]
        for p in providers {
            for name in ["browser_click", "browser_fill"] {
                let saved: [String: Any] = ["type": "function", "name": name, "parameters": legacyBrowserMutationSchema(name)]
                let catalog: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [saved]]]
                var legacy: [String: Any] = ["snapshot_id": "11111111-1111-4111-8111-111111111111", "element_index": 0]
                let key = name == "browser_fill" ? "fill_ref" : "click_ref"
                var current: [String: Any] = [key: (name == "browser_fill" ? "bfill_" : "bclick_") + UUID().uuidString]
                if name == "browser_fill" { legacy["text"] = ""; current["text"] = "" }
                let asserted = legacy.merging(["expected_role": "AXButton", "expected_label": ""]) { _, new in new }
                let prepared = try request(["tools": catalog], provider: p)
                let malformed = [legacy.merging(["expected_role": "AXButton"]) { _, new in new },
                    legacy.merging(["expected_label": ""]) { _, new in new },
                    asserted.merging(["expected_role": ""]) { _, new in new },
                    asserted.merging(["expected_label": NSNull()]) { _, new in new },
                    current.merging(["unexpected": true]) { _, new in new },
                    current.merging([key: NSNull()]) { _, new in new },
                    current.merging([key: ""]) { _, new in new },
                    current.merging(["snapshot_id": legacy["snapshot_id"]!]) { _, new in new },
                    current.merging(["expected_label": ""]) { _, new in new }]
                for arguments in [legacy, asserted] + malformed {
                    let text = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                    XCTAssertThrowsError(try browserMutationReply(text, request: prepared)) {
                        XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                    }
                }
                for arguments in malformed {
                    let text = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                    let history: [[String: Any]] = [["type": "function_call", "namespace": "functions", "name": name,
                        "call_id": "bad", "arguments": text], ["type": "function_call_output", "call_id": "bad", "output": "Historical result"]]
                    XCTAssertThrowsError(try request(["tools": catalog, "input": history], provider: p)) {
                        XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                    }
                }
                let text = String(decoding: try JSONSerialization.data(withJSONObject: current), as: UTF8.self)
                XCTAssertNoThrow(try browserMutationReply(text, request: prepared))
                for arguments in [legacy, asserted, current] {
                    let text = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                    XCTAssertThrowsError(try request(["tools": catalog, "input": [["type": "function_call", "namespace": "functions",
                        "name": name, "call_id": "orphan", "arguments": text]]], provider: p)) {
                        XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidHistory)
                    }
                }
            }
        }
    }

    func testBrowserReferenceProjectionDoesNotRewriteCustomMCPOrModifiedSchemas() throws {
        let modelID = "api/cerebras/model/Z3B0LW9zcy0xMjBi"
        let legacy = legacyBrowserMutationSchema("browser_click")
        let foreign: [String: Any] = ["type": "namespace", "name": "mcp_external", "tools": [
            ["type": "function", "name": "browser_click", "parameters": legacy]]]
        let custom: [String: Any] = ["type": "custom", "name": "browser_click", "description": "External custom tool",
            "format": ["type": "text"]]
        var modified = legacy
        var properties = try XCTUnwrap(modified["properties"] as? [String: Any])
        properties["element_index"] = ["type": "integer", "maximum": 10]
        modified["properties"] = properties
        let restricted: [String: Any] = ["type": "function", "name": "browser_click", "parameters": modified]
        let canonical = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == "browser_click" }?["inputSchema"] as? [String: Any])
        var partialAssertions = assertedBrowserMutationSchema("browser_click")
        var partialProperties = try XCTUnwrap(partialAssertions["properties"] as? [String: Any])
        partialProperties.removeValue(forKey: "expected_label")
        partialAssertions["properties"] = partialProperties; partialAssertions["required"] = partialProperties.keys.sorted()
        var optionalRef = canonical; optionalRef["required"] = [String]()
        var narrowerRef = canonical
        narrowerRef["properties"] = ["click_ref": ["type": "string", "minLength": 1, "maxLength": 32]]
        var mixed = canonical
        mixed["properties"] = ["click_ref": ["type": "string"], "snapshot_id": ["type": "string"]]
        mixed["required"] = ["click_ref", "snapshot_id"]
        let unrecognized = [partialAssertions, optionalRef, narrowerRef, mixed].map {
            ["type": "function", "name": "browser_click", "parameters": $0] as [String: Any]
        }
        for definition in [foreign, custom, restricted] + unrecognized {
            let projected = ComputaModelToolCatalog.visibleToolDefinitions([definition], modelID: modelID)
            XCTAssertEqual(projected as NSArray, [definition] as NSArray)
        }
        let prepared = try request(["tools": [foreign]])
        let args = #"{"snapshot_id":"old","element_index":0,"expected_role":"AXButton","expected_label":"Click"}"#
        let history: [[String: Any]] = [["type": "function_call", "namespace": "mcp_external", "name": "browser_click", "call_id": "external", "arguments": args],
            ["type": "function_call_output", "call_id": "external", "output": "External result"]]
        XCTAssertThrowsError(try request(["tools": [foreign], "input": history])) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
        }
        XCTAssertEqual(try wireFunctions(prepared).first?["parameters"] as? NSDictionary, legacy as NSDictionary)
        for key in ["parameters", "inputSchema"] {
            for original in [legacy, assertedBrowserMutationSchema("browser_click"), canonical] {
                let saved: [String: Any] = ["type": "function", "name": "browser_click", key: original]
                let refreshed = try XCTUnwrap(ComputaModelToolCatalog.visibleToolDefinitions([saved], modelID: modelID).first)
                let schema = try XCTUnwrap(refreshed[key] as? [String: Any])
                XCTAssertEqual(schema as NSDictionary, canonical as NSDictionary)
                XCTAssertEqual(saved[key] as? NSDictionary, original as NSDictionary)
            }
        }
    }

    func testBrowserHistoryRetainsSavedConstraintsWithoutGrantingLiveLegacyInput() throws {
        var bounded = legacyBrowserMutationSchema("browser_click")
        bounded["properties"] = ["snapshot_id": ["type": "string", "minLength": 1],
            "element_index": ["type": "integer", "minimum": 0, "maximum": 2_999]]
        let tool: [String: Any] = ["type": "function", "name": "browser_click", "parameters": bounded]
        for args in [#"{"snapshot_id":"","element_index":0}"#, #"{"snapshot_id":"old","element_index":3000}"#] {
            let history: [[String: Any]] = [["type": "function_call", "name": "browser_click", "call_id": "old", "arguments": args],
                ["type": "function_call_output", "call_id": "old", "output": "Historical result"]]
            XCTAssertThrowsError(try request(["tools": [tool], "input": history])) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
        }
        // An omitted constraint in the saved engine catalog stays omitted for
        // that historical shape, including a failed call with empty input.
        let saved: [String: Any] = ["type": "function", "name": "browser_click", "parameters": legacyBrowserMutationSchema("browser_click")]
        let args = #"{"snapshot_id":"","element_index":0}"#
        let history: [[String: Any]] = [["type": "function_call", "name": "browser_click", "call_id": "old", "arguments": args],
            ["type": "function_call_output", "call_id": "old", "output": "Rejected before input"]]
        let prepared = try request(["tools": [saved], "input": history])
        XCTAssertEqual(prepared.tools.first?.schema["required"] as? [String], ["click_ref"])
        XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "new", "type": "function",
            "function": ["name": try XCTUnwrap(prepared.tools.first?.wireName), "arguments": args]]]],
            finish: "tool_calls", request: prepared)) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
        }
    }

    func testWaitDocumentChangeUpgradePreservesCompletedCallsAndStrictCurrentModesOnBothWires() throws {
        let legacy = try XCTUnwrap(EmbeddedBrowserTools.legacyWaitDefinition["inputSchema"] as? [String: Any])
        let current = try XCTUnwrap(EmbeddedBrowserTools.waitDefinition["inputSchema"] as? [String: Any])
        let dropped: Set<String> = ["description", "minimum", "maximum", "minLength", "maxLength", "pattern"]
        func projected(_ value: Any) -> Any {
            if let object = value as? [String: Any] { return object.filter { !dropped.contains($0.key) }.mapValues(projected) }
            if let array = value as? [Any] { return array.map(projected) }
            return value
        }
        let snapshot = "11111111-1111-4111-8111-111111111111"
        let oldArguments = #"{ "timeout_ms": 50, "text": "Cafe\u0301 \\\"ready\\\"" }"#
        let newArguments = "{ \"after_snapshot\" : \"\(snapshot)\", \"timeout_ms\": 200 }"
        let arguments = [oldArguments, newArguments]
        func pair(_ id: String, _ arguments: String) -> [[String: Any]] {
            [["type": "function_call", "call_id": id, "name": "browser_wait", "namespace": "functions", "arguments": arguments],
             ["type": "function_call_output", "call_id": id, "output": "Read-only wait completed; outcome unverified."]]
        }
        for wire in APIProviderDefinition.WireAPI.allCases {
            let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: wire, models: provider.models)
            for savedSchema in [legacy, current, projected(legacy) as! [String: Any], projected(current) as! [String: Any]] {
                let saved: [String: Any] = ["type": "function", "name": "browser_wait", "parameters": savedSchema]
                let catalog: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [saved]]]
                let history = pair("old-wait", oldArguments) + pair("change-wait", newArguments)
                let prepared = try request(["tools": catalog, "input": history], provider: p, toolNaming: .semantic)
                XCTAssertEqual(prepared.tools.first?.schema as NSDictionary?, current as NSDictionary)
                func historyArguments(_ prepared: APIModelResponseCodec.Request) throws -> [String] {
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
                    if wire == .responses {
                        return try XCTUnwrap(body["input"] as? [[String: Any]])
                            .filter { $0["type"] as? String == "function_call" }.compactMap { $0["arguments"] as? String }
                    }
                    return try XCTUnwrap(body["messages"] as? [[String: Any]])
                        .flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }
                        .compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }
                }
                XCTAssertEqual(try historyArguments(prepared).map { Data($0.utf8) }, arguments.map { Data($0.utf8) })
                XCTAssertEqual(prepared.historyCallIDs, ["old-wait", "change-wait"])
                for valid in ["{}", oldArguments, newArguments, #"{"timeout_ms":10000}"#] {
                    let reply = try browserMutationReply(valid, request: prepared, callID: "next-wait")
                    let call = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call" })
                    XCTAssertEqual((call["arguments"] as? String).map { Data($0.utf8) }, Data(valid.utf8))
                }
                for invalid in ["{\"after_snapshot\":\"\(snapshot)\",\"text\":\"ready\"}",
                                #"{"after_snapshot":null}"#, #"{"after_snapshot":""}"#,
                                "{\"after_snapshot\":\"\(String(repeating: "a", count: 37))\"}",
                                #"{"text":""}"#, #"{"timeout_ms":10001}"#, #"{"after_snapshot":"x","extra":true}"#] {
                    XCTAssertThrowsError(try browserMutationReply(invalid, request: prepared)) {
                        XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                    }
                }
                let next = try request(["tools": catalog, "input": history + pair("next-wait", newArguments)], provider: p, toolNaming: .semantic)
                XCTAssertEqual(try historyArguments(next).map { Data($0.utf8) }, (arguments + [newArguments]).map { Data($0.utf8) })
                XCTAssertThrowsError(try request(["tools": catalog, "input": [pair("incomplete", newArguments)[0]]], provider: p))
            }
        }
    }

    func testWaitHistoryEvolutionDoesNotWidenForeignNarrowedOrConflictingSchemas() throws {
        let legacy = try XCTUnwrap(EmbeddedBrowserTools.legacyWaitDefinition["inputSchema"] as? [String: Any])
        let current = try XCTUnwrap(EmbeddedBrowserTools.waitDefinition["inputSchema"] as? [String: Any])
        var required = legacy; required["required"] = ["text"]
        let args = #"{"after_snapshot":"11111111-1111-4111-8111-111111111111"}"#
        let cases: [([String: Any], String)] = [
            (["type": "function", "name": "browser_wait", "parameters": legacy], "foreign"),
            (["type": "function", "name": "browser_wait", "parameters": required], "functions"),
            (["type": "function", "name": "browser_wait", "parameters": legacy, "inputSchema": current], "functions"),
            (["type": "function", "name": "browser_wait", "parameters": legacy, "inputSchema": required], "functions"),
        ]
        for wire in APIProviderDefinition.WireAPI.allCases {
            let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: wire, models: provider.models)
            for (saved, namespace) in cases {
                let catalog: [[String: Any]] = [["type": "namespace", "name": namespace, "tools": [saved]]]
                let prepared = try request(["tools": catalog], provider: p)
                XCTAssertEqual(prepared.tools.first?.schema as NSDictionary?, saved["parameters"] as? NSDictionary)
                let history: [[String: Any]] = [
                    ["type": "function_call", "name": "browser_wait", "namespace": namespace, "call_id": "foreign-wait", "arguments": args],
                    ["type": "function_call_output", "call_id": "foreign-wait", "output": "Saved outcome"],
                ]
                XCTAssertThrowsError(try request(["tools": catalog, "input": history], provider: p)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                }
            }
            let saved: [String: Any] = ["type": "function", "name": "browser_wait", "parameters": legacy]
            for invalid in [#"{"text":""}"#, #"{"timeout_ms":10001}"#,
                            #"{"text":"ready","after_snapshot":"11111111-1111-4111-8111-111111111111"}"#] {
                let history: [[String: Any]] = [
                    ["type": "function_call", "name": "browser_wait", "call_id": "invalid-wait", "arguments": invalid],
                    ["type": "function_call_output", "call_id": "invalid-wait", "output": "Saved outcome"],
                ]
                XCTAssertThrowsError(try request(["tools": [saved], "input": history], provider: p))
            }
        }
    }

    func testWaitModeConflictUsesGenericRootDiagnosticAndPreservesOldFieldLocations() throws {
        let schema = try XCTUnwrap(EmbeddedBrowserTools.waitDefinition["inputSchema"] as? [String: Any])
        let prepared = try request(["tools": [["type": "function", "name": "browser_wait", "parameters": schema]]])
        let conflict = try observedSchemaFailure(prepared, arguments: #"{"text":"ready","after_snapshot":"11111111-1111-4111-8111-111111111111"}"#)
        XCTAssertEqual(conflict.constraint, .schemaMismatch)
        XCTAssertEqual(conflict.location, .init(tool: .browserWait, schemaPath: [], expectedType: .object, actualType: .object))
        let timeout = try observedSchemaFailure(prepared, arguments: #"{"timeout_ms":true}"#)
        XCTAssertEqual(timeout.location, .init(tool: .browserWait, schemaPath: [.timeoutMS], expectedType: .integer, actualType: .boolean))
        let text = try observedSchemaFailure(prepared, arguments: #"{"text":false}"#)
        XCTAssertEqual(text.location, .init(tool: .browserWait, schemaPath: [.text], expectedType: .string, actualType: .boolean))
    }

    func testEngineProjectedBrowserWaitBoundsAreRestoredBeforeCerebrasValidationAndCorrection() throws {
        let p = APIProviderDefinition(id: "cerebras-fixture", name: "Cerebras Fixture",
            baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions,
            models: [.init(id: "gpt-oss-120b", name: "GPT OSS")])
        let modelID = APIProviderCatalog.appModelID(providerID: p.id, modelID: p.models[0].id)
        // Pinned codex-tools JsonSchema retains integer type but has no numeric
        // bound fields. The original dynamic-tool rollout still has the bounds.
        let engineSchema: [String: Any] = ["type": "object", "properties": [
            "text": ["type": "string"], "timeout_ms": ["type": "integer"]],
            "required": [String](), "additionalProperties": false]
        let canonical = try XCTUnwrap(EmbeddedBrowserTools.definitions()
            .first { $0["name"] as? String == "browser_wait" }?["inputSchema"] as? [String: Any])
        let currentProperties = try XCTUnwrap(canonical["properties"] as? [String: Any])
        for key in ["parameters", "inputSchema"] {
            let original: [String: Any] = ["type": "function", "name": "browser_wait", key: engineSchema]
            let refreshed = try XCTUnwrap(ComputaModelToolCatalog.visibleToolDefinitions([original], modelID: modelID).first)
            let schema = try XCTUnwrap(refreshed[key] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(properties["timeout_ms"] as? NSDictionary, currentProperties["timeout_ms"] as? NSDictionary)
            XCTAssertEqual(original[key] as? NSDictionary, engineSchema as NSDictionary)
        }
        let saved: [String: Any] = ["type": "function", "name": "browser_wait", "parameters": engineSchema]
        let historicalArguments = #"{"text":"Inbox","timeout_ms":15000}"#
        let history: [[String: Any]] = [
            ["role": "user", "content": "Read the mailbox"],
            ["type": "function_call", "call_id": "old-unbounded-wait", "name": "browser_wait",
             "namespace": "functions", "arguments": historicalArguments],
            ["type": "function_call_output", "call_id": "old-unbounded-wait",
             "output": "The browser wait deadline must be from 1 to 10000 milliseconds."],
            ["role": "user", "content": "Continue with current tools"],
        ]
        let prepared = try request(["tools": [["type": "namespace", "name": "functions", "tools": [saved]]],
                                    "input": history], provider: p, toolNaming: .semantic)
        let wire = try XCTUnwrap(try wireFunctions(prepared).first)
        let parameters = try XCTUnwrap(wire["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let timeout = try XCTUnwrap(properties["timeout_ms"] as? [String: Any])
        XCTAssertEqual(timeout["minimum"] as? Int, 1); XCTAssertEqual(timeout["maximum"] as? Int, 10_000)
        let waitText = try XCTUnwrap(properties["text"] as? [String: Any])
        XCTAssertEqual(waitText["minLength"] as? Int, 1)
        XCTAssertNotNil(waitText["pattern"] as? String)
        XCTAssertNil(waitText["maxLength"], "A code-point length constraint would misstate the native UTF-8 byte limit")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let historicalCall = try XCTUnwrap(messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.first?.first)
        XCTAssertEqual((historicalCall["function"] as? [String: Any])?["arguments"] as? String, historicalArguments)
        let alias = try XCTUnwrap(wire["name"] as? String)
        func message(_ arguments: String) -> [String: Any] {
            ["role": "assistant", "tool_calls": [["id": "current-wait", "type": "function",
                "function": ["name": alias, "arguments": arguments]]]]
        }
        for arguments in ["{}", #"{"text":"Inbox"}"#, #"{"timeout_ms":1}"#, #"{"timeout_ms":10000}"#] {
            let reply = try decode(message(arguments), finish: "tool_calls", request: prepared, model: p.models[0].id)
            XCTAssertEqual((reply.response["output"] as? [[String: Any]])?.first?["arguments"] as? String, arguments,
                           "Valid current arguments remain byte-for-byte unchanged")
        }
        for arguments in [historicalArguments, #"{"timeout_ms":0}"#, #"{"timeout_ms":-1}"#,
                          #"{"timeout_ms":10001}"#, #"{"timeout_ms":1.5}"#, #"{"timeout_ms":true}"#,
                          #"{"timeout_ms":"10000"}"#] {
            XCTAssertThrowsError(try decode(message(arguments), finish: "tool_calls", request: prepared, model: p.models[0].id)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
        }
        for text in ["", " \t\n", "\u{200b}", "\u{0085}\u{00a0}", "\u{3000}"] {
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
            XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: "browser_wait", arguments: ["text": text]))
            XCTAssertThrowsError(try decode(message(arguments), finish: "tool_calls", request: prepared, model: p.models[0].id)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
        }
        guard case .argumentsRejected(_, let details) = try APIModelResponseCodec.decodeForCorrection(
            correctionResult(prepared, arguments: historicalArguments), request: prepared) else {
            return XCTFail("An out-of-range current response must be withheld before native dispatch")
        }
        let correction = try APIModelResponseCodec.correctiveRequest(prepared, rejectionDetails: details)
        let correctedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: correction.body) as? [String: Any])
        XCTAssertEqual(correctedBody["tools"] as? NSArray, body["tools"] as? NSArray,
                       "Correction keeps the same canonical advertised bounds")
        XCTAssertTrue(String(decoding: correction.body, as: UTF8.self).contains("No call from that rejected response was executed"))
        let correctedArguments = #"{"text":"Inbox","timeout_ms":10000}"#
        let reply = try decode(message(correctedArguments), finish: "tool_calls", request: correction, model: p.models[0].id)
        XCTAssertEqual((reply.response["output"] as? [[String: Any]])?.first?["arguments"] as? String, correctedArguments)
    }

    func testOwnedBrowserConstraintOverlayRepairsEngineLossWithoutAddingFieldsOrRestrictingEmptyText() throws {
        let p = APIProviderDefinition(id: "cerebras-fixture", name: "Cerebras Fixture",
            baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions,
            models: [.init(id: "gpt-oss-120b", name: "GPT OSS")])
        let constraints: Set<String> = ["minimum", "maximum", "minLength", "maxLength", "pattern"]
        let id = "11111111-1111-4111-8111-111111111111"
        let cases: [(String, [String], [String])] = [
            ("browser_open", [#"{"url":"https://outlook.live.com/mail/"}"#], [#"{"url":""}"#]),
            ("browser_navigate", [#"{"url":"https://outlook.live.com/mail/"}"#], [#"{"url":""}"#]),
            ("browser_bind", ["{\"tab_id\":\"\(id)\"}"], [#"{"tab_id":""}"#]),
            ("browser_tabs", ["{}", #"{"cursor":null}"#], [#"{"cursor":""}"#, #"{"cursor":false}"#]),
            ("browser_read", ["{}", #"{"view":"content"}"#], [#"{"cursor":null}"#, #"{"cursor":"issued"}"#, #"{"query":""}"#, #"{"view":"invalid"}"#]),
            ("browser_continue", [#"{"cursor":"issued"}"#], ["{}", #"{"cursor":null}"#, #"{"cursor":""}"#, #"{"cursor":"issued","view":"all"}"#]),
            ("browser_click", ["{\"click_ref\":\"bclick_\(id)\"}"],
                              [#"{"click_ref":""}"#, "{\"click_ref\":\"\(String(repeating: "x", count: 129))\"}"]),
            ("browser_fill", ["{\"fill_ref\":\"bfill_\(id)\",\"text\":\"\"}"],
                             [#"{"fill_ref":"","text":""}"#, #"{"fill_ref":null,"text":""}"#]),
            ("browser_wait", ["{}", #"{"text":"Inbox"}"#, #"{"timeout_ms":10000}"#],
                             [#"{"timeout_ms":15000}"#, #"{"text":""}"#, #"{"text":" \t"}"#]),
            ("browser_close", ["{}"], []),
        ]
        for (name, accepted, rejected) in cases {
            let definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            var schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            let canonical = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            let projected = canonical.mapValues { $0.filter { !constraints.contains($0.key) } }
            schema["properties"] = projected
            let originalRequired = schema["required"] as? [String]
            let prepared = try request(["tools": [["type": "function", "name": name, "parameters": schema]]],
                                       provider: p, toolNaming: .semantic)
            let wire = try XCTUnwrap(try wireFunctions(prepared).first)
            let repaired = try XCTUnwrap(wire["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(repaired["properties"] as? [String: [String: Any]])
            XCTAssertEqual(Set(properties.keys), Set(projected.keys)); XCTAssertEqual(repaired["required"] as? [String], originalRequired)
            for (field, property) in properties {
                XCTAssertEqual(property["type"] as? String, projected[field]?["type"] as? String)
                XCTAssertEqual(property["enum"] as? [String], projected[field]?["enum"] as? [String])
                for constraint in constraints {
                    XCTAssertEqual(property[constraint] as? NSObject, canonical[field]?[constraint] as? NSObject,
                                   "Every current constraint must reach the actual provider wire unchanged")
                }
            }
            let alias = try XCTUnwrap(wire["name"] as? String)
            func message(_ arguments: String) -> [String: Any] {
                ["role": "assistant", "tool_calls": [["id": "current-browser", "type": "function",
                    "function": ["name": alias, "arguments": arguments]]]]
            }
            for arguments in accepted {
                let reply = try decode(message(arguments), finish: "tool_calls", request: prepared, model: p.models[0].id)
                XCTAssertEqual((reply.response["output"] as? [[String: Any]])?.first?["arguments"] as? String, arguments)
            }
            for arguments in rejected {
                XCTAssertThrowsError(try decode(message(arguments), finish: "tool_calls", request: prepared, model: p.models[0].id)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                }
            }
        }
    }

    private func cerebrasErrorWire(_ envelope: Any, event: String? = nil, prefix: Data = Data()) throws -> Data {
        var result = prefix
        if let event { result.append(Data("event: \(event)\n".utf8)) }
        result.append(Data("data: ".utf8)); result.append(try JSONSerialization.data(withJSONObject: envelope))
        result.append(Data("\n\ndata: [DONE]\n\n".utf8)); return result
    }
    func testDocumentedCerebrasErrorChunksClassifyAtomicallyBeforeAndAfterPartialTools() throws {
        let prepared = try cerebrasStreamRequest()
        let partial: [String: Any] = ["id": "remote", "model": "fixture-model", "choices": [["index": 0,
            "delta": ["role": "assistant", "content": "PRIVATE_PARTIAL_TEXT", "tool_calls": [["index": 0, "id": "PRIVATE_CALL", "type": "function",
                "function": ["name": prepared.tools[0].wireName, "arguments": "{\"path\":\"PRIVATE_PARTIAL_ARG"]]]], "finish_reason": NSNull()]]]
        var prefix = Data("data: ".utf8); prefix.append(try JSONSerialization.data(withJSONObject: partial)); prefix.append(Data("\n\n".utf8))
        let cases: [(Int, [String: Any], APIProviderHTTPClient.Failure)] = [
            (400, ["message": "PRIVATE_CANARY"], .invalidRequest), (401, [:], .unauthorized), (403, [:], .unauthorized),
            (404, [:], .modelNotFound), (408, [:], .unavailable), (413, [:], .contextLimit),
            (422, ["param": "messages[0].content", "message": "PRIVATE_CANARY"], .invalidMessages),
            (400, ["code": "context_length_exceeded"], .contextLimit), (429, ["message": "PRIVATE_CANARY"], .rateLimited),
            (429, ["message": "We're experiencing high traffic right now! Please try again soon."], .providerBusy),
            (429, ["code": "model_overloaded"], .providerBusy),
            (429, ["message": "We're experiencing high traffic right now! Please try again soon. PRIVATE_CANARY"], .rateLimited),
            (500, ["id": NSNull(), "code": NSNull(), "message": NSNull(), "param": NSNull(), "type": NSNull()], .unavailable),
            (599, ["type": "PRIVATE_CANARY"], .unavailable)]
        for (status, fields, expected) in cases {
            for event in [nil, "error"] as [String?] {
                for before in [Data(), prefix] {
                    var guards: [APIModelResponseCodec.InvalidResponseDiagnostic] = [], argumentsObserved = false
                    let body = try cerebrasErrorWire(["error": fields, "status_code": status], event: event, prefix: before)
                    XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: body, contentType: "text/event-stream"), request: prepared,
                        onArgumentRejection: { _ in argumentsObserved = true }, onInvalidResponse: { guards.append($0) })) {
                        XCTAssertEqual($0 as? APIProviderHTTPClient.Failure, expected)
                        XCTAssertFalse($0.localizedDescription.contains("PRIVATE"))
                        let projected = try? APIModelServer.errorBody($0, stage: .decode)
                        XCTAssertFalse(String(decoding: projected ?? Data(), as: UTF8.self).contains("PRIVATE"))
                    }
                    XCTAssertTrue(guards.isEmpty); XCTAssertFalse(argumentsObserved)
                }
            }
        }
    }
    func testCerebrasMalformedErrorChunksOtherProvidersAndDoneOrderingKeepOriginalGuards() throws {
        let prepared = try cerebrasStreamRequest(), valid: [String: Any] = ["error": ["message": "PRIVATE_CANARY"], "status_code": 429]
        var invalid: [[String: Any]] = []
        for status: Any in [true, false, "429", 429.5, 399, 600, NSNull()] {
            var row = valid; row["status_code"] = status; invalid.append(row)
        }
        invalid += [["error": [:]], ["status_code": 429], ["error": NSNull(), "status_code": 429],
            ["error": "PRIVATE_CANARY", "status_code": 429], ["error": [], "status_code": 429],
            ["error": ["message": true], "status_code": 429], ["error": ["detail": "PRIVATE_CANARY"], "status_code": 429],
            valid.merging(["choices": []]) { _, new in new },
            ["error": ["message": String(repeating: "x", count: 16_384)], "status_code": 429]]
        var wires = try invalid.map { try cerebrasErrorWire($0) }
        wires += [try cerebrasErrorWire(valid, event: "unknown"), try cerebrasErrorWire(valid, event: "error\nevent: error")]
        wires += [Data("data: {\"error\":{},\"status_code\":401,\"status_code\":429}\n\ndata: [DONE]\n\n".utf8),
                  Data("data: {\"error\":{\"message\":\"a\",\"message\":\"b\"},\"status_code\":429}\n\ndata: [DONE]\n\n".utf8)]
        let successLooking: [String: Any] = ["id": "remote", "model": "fixture-model", "choices": [["index": 0,
            "delta": ["role": "assistant", "content": "PRIVATE_FAKE_SUCCESS"], "finish_reason": "stop"]]]
        for event in ["error", "error\nevent: error", "unknown\nevent: error"] {
            wires.append(try cerebrasErrorWire(successLooking, event: event))
        }
        for body in wires {
            var guards: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: body, contentType: "text/event-stream"), request: prepared,
                onInvalidResponse: { guards.append($0) })) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidResponse) }
            XCTAssertEqual(guards, [.init(format: .chatSSE, guardID: .sseChunkEnvelope)])
        }
        for p in [provider, APIProviderDefinition(id: "cerebras", name: "Not the Cerebras endpoint", baseURL: provider.baseURL, wireAPI: .chatCompletions, models: provider.models)] {
            var guards: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: try cerebrasErrorWire(valid), contentType: "text/event-stream"),
                request: request(provider: p), onInvalidResponse: { guards.append($0) })) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidResponse) }
            XCTAssertEqual(guards.first?.guardID, .sseChunkEnvelope)
        }
        // Positive control: ordinary Cerebras streams still use the same
        // content/tool fragment assembly, identities, arguments and final usage.
        let normalText = try APIModelResponseCodec.decode(.init(body: try cerebrasErrorWire(successLooking), contentType: "text/event-stream"), request: prepared)
        XCTAssertEqual(normalText.textDeltas, ["PRIVATE_FAKE_SUCCESS"])
        let deltas: [[String: Any]] = [["role": "assistant", "tool_calls": [["index": 0, "id": "ordinary-call", "type": "function",
            "function": ["name": prepared.tools[0].wireName, "arguments": "{\"path\":"]]]],
            ["tool_calls": [["index": 0, "function": ["arguments": "\"ok\"}"]]]], [:]]
        var normalTools = Data()
        for (index, delta) in deltas.enumerated() {
            let row: [String: Any] = ["id": "ordinary-stream", "model": "fixture-model", "choices": [["index": 0, "delta": delta,
                "finish_reason": index == 2 ? "tool_calls" : NSNull()]]]
            normalTools.append(Data("data: ".utf8)); normalTools.append(try JSONSerialization.data(withJSONObject: row)); normalTools.append(Data("\n\n".utf8))
        }
        normalTools.append(Data("data: ".utf8)); normalTools.append(try JSONSerialization.data(withJSONObject: ["id": "ordinary-stream", "model": "fixture-model", "choices": [],
            "usage": ["prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5]])); normalTools.append(Data("\n\ndata: [DONE]\n\n".utf8))
        let normalReply = try APIModelResponseCodec.decode(.init(body: normalTools, contentType: "text/event-stream"), request: prepared)
        XCTAssertEqual(normalReply.argumentDeltas, [["{\"path\":", "\"ok\"}"]])
        let normalCall = try XCTUnwrap((normalReply.response["output"] as? [[String: Any]])?.first)
        XCTAssertEqual(normalCall["call_id"] as? String, "ordinary-call"); XCTAssertEqual(normalCall["arguments"] as? String, "{\"path\":\"ok\"}")
        XCTAssertEqual((normalReply.response["usage"] as? [String: Any])?["total_tokens"] as? Int, 5)
        // The new event-error failure fence is endpoint scoped. Other
        // providers retain their existing treatment of successful SSE payloads.
        let unchanged = try APIModelResponseCodec.decode(.init(body: try cerebrasErrorWire(successLooking, event: "error"),
            contentType: "text/event-stream"), request: request())
        XCTAssertEqual(unchanged.textDeltas, ["PRIVATE_FAKE_SUCCESS"])
        var guards: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: try cerebrasErrorWire(valid, prefix: Data("data: [DONE]\n\n".utf8)),
            contentType: "text/event-stream"), request: prepared, onInvalidResponse: { guards.append($0) })) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidResponse)
        }
        XCTAssertEqual(guards.first?.guardID, .sseAfterDone)
    }


    func testJSONParserFailuresUseOneFiniteGuardAcrossAllFormatsWithoutPublishingPartialTools() throws {
        let chat = try request()
        let responseProvider = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
            wireAPI: .responses, models: provider.models)
        let responses = try request(provider: responseProvider)
        let malformed = Data("{\"PRIVATE_JSON_PARSE_CANARY\":".utf8)
        let partial: [String: Any] = ["id": "PRIVATE_STREAM", "model": "fixture-model", "choices": [["index": 0,
            "delta": ["role": "assistant", "tool_calls": [["index": 0, "id": "PRIVATE_CALL", "type": "function",
                "function": ["name": chat.tools[0].wireName, "arguments": "{\"path\":\"PRIVATE_PARTIAL"]]]],
            "finish_reason": NSNull()]]]
        let scalar = Data("true".utf8)
        let scalarEvent = Data("data: true\n\ndata: [DONE]\n\n".utf8)
        let badEvent = Data("data: ".utf8) + malformed + Data("\n\ndata: [DONE]\n\n".utf8)
        let partialEvent = Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: partial)) + Data("\n\n".utf8)
        let cases: [(APIModelResponseCodec.Request, Data, String, APIModelResponseCodec.InvalidResponseDiagnostic.Format)] = [
            (chat, malformed, "application/json", .chatJSON), (responses, malformed, "application/json", .responsesJSON),
            (chat, badEvent, "text/event-stream", .chatSSE), (chat, partialEvent + badEvent, "text/event-stream", .chatSSE),
            (chat, scalar, "application/json", .chatJSON), (responses, scalar, "application/json", .responsesJSON),
            (chat, scalarEvent, "text/event-stream", .chatSSE)]
        for (prepared, body, contentType, format) in cases {
            var guards: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
            var argumentRejections: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: body, contentType: contentType), request: prepared,
                onArgumentRejection: { argumentRejections.append($0) }, onInvalidResponse: { guards.append($0) })) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidResponse)
            }
            XCTAssertEqual(guards.count, 1)
            XCTAssertEqual(guards.first?.format, format)
            XCTAssertEqual(guards.first?.guardID.rawValue, "json_parse")
            if let diagnostic = guards.first { XCTAssertTrue(diagnostic.isConsistent) }
            XCTAssertTrue(argumentRejections.isEmpty)
            let encoded = try JSONEncoder().encode(guards)
            XCTAssertLessThan(encoded.count, 128); XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE"))
        }
    }

    func testJSONParseClassificationPreservesNonobjectUTF8AndTruncatedStreamFailures() throws {
        let chat = try request()
        let responseProvider = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
            wireAPI: .responses, models: provider.models)
        let responses = try request(provider: responseProvider)
        let partial: [String: Any] = ["id": "r", "model": "fixture-model", "choices": [["index": 0,
            "delta": ["role": "assistant", "tool_calls": [["index": 0, "id": "c", "type": "function",
                "function": ["name": chat.tools[0].wireName, "arguments": "{\"path\":\"partial"]]]], "finish_reason": NSNull()]]]
        let truncated = Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: partial)) + Data("\n\n".utf8)
        typealias Guard = APIModelResponseCodec.InvalidResponseDiagnostic.Guard
        let cases: [(APIModelResponseCodec.Request, Data, String, APIModelResponseCodec.Failure, Guard?)] = [
            (chat, Data("[]".utf8), "application/json", .invalidResponse, .chatRootObject),
            (responses, Data("[]".utf8), "application/json", .incompleteResponse, nil),
            (responses, Data("{\"object\":\"other\"}".utf8), "application/json", .incompleteResponse, nil),
            (chat, Data([0xff]), "text/event-stream", .invalidResponse, .sseUTF8),
            (chat, truncated, "text/event-stream", .incompleteResponse, nil),
            (chat, Data("data: []\n\ndata: [DONE]\n\n".utf8), "text/event-stream", .invalidResponse, .sseChunkEnvelope)]
        for (prepared, body, contentType, expected, guardID) in cases {
            var guards: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: body, contentType: contentType), request: prepared,
                onInvalidResponse: { guards.append($0) })) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, expected) }
            XCTAssertEqual(guards.map(\.guardID), guardID.map { [$0] } ?? [])
        }
    }

    func testFatalJSONResponseGuardsRetainExactFailuresAndEmitOnlyOneFiniteLabel() throws {
        let prepared = try request()
        typealias Guard = APIModelResponseCodec.InvalidResponseDiagnostic.Guard
        let valid: [String: Any] = ["model": "fixture-model", "choices": [["index": 0,
            "message": ["role": "assistant", "content": "PRIVATE_RESPONSE_CANARY"], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5]]
        func changedMessage(_ field: String, _ value: Any) -> [String: Any] {
            var envelope = valid, choices = envelope["choices"] as! [[String: Any]], message = choices[0]["message"] as! [String: Any]
            message[field] = value; choices[0]["message"] = message; envelope["choices"] = choices; return envelope
        }
        func changedUsage(_ field: String, _ value: Any) -> [String: Any] {
            var envelope = valid, usage = envelope["usage"] as! [String: Any]
            usage[field] = value; envelope["usage"] = usage; return envelope
        }
        var cases: [(Any, Guard)] = [([], .chatRootObject),
            (valid.merging(["choices": []]) { _, value in value }, .chatChoiceEnvelope),
            (valid.merging(["choices": [["index": true, "message": ["role": "assistant", "content": "safe"], "finish_reason": "stop"]]]) { _, value in value }, .chatChoiceIndex),
            (changedMessage("content", []), .chatContentType),
            (changedMessage("refusal", "PRIVATE_REFUSAL_CANARY"), .chatUnsupportedMessageFields),
            (changedMessage("tool_calls", false), .chatCallsType),
            (valid.merging(["choices": [["index": 0, "message": ["role": "assistant", "content": "safe"], "finish_reason": "tool_calls"]]]) { _, value in value }, .chatCallFinishConsistency),
            (changedMessage("reasoning", []), .chatReasoningType), (changedMessage("content", ""), .chatEmptyOutput),
            (valid.merging(["usage": []]) { _, value in value }, .usageObject)]
        cases += [(changedUsage("prompt_tokens", true), .usageInputTokens),
            (changedUsage("completion_tokens", 1.5), .usageOutputTokens), (changedUsage("total_tokens", -1), .usageTotalTokens),
            (changedUsage("total_tokens", 6), .usageTotalConsistency),
            (changedUsage("completion_tokens_details", "PRIVATE_USAGE_CANARY"), .usageOutputDetails),
            (changedUsage("completion_tokens_details", ["reasoning_tokens": 4]), .usageReasoningTokens),
            (changedUsage("prompt_tokens_details", []), .usageInputDetails),
            (changedUsage("prompt_tokens_details", ["cached_tokens": 3]), .usageCachedTokens)]
        for (envelope, guardID) in cases {
            let result = APIProviderHTTPClient.Result(body: try JSONSerialization.data(withJSONObject: envelope), contentType: "application/json")
            for observe in [false, true] {
                var observed: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
                XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared,
                    onInvalidResponse: observe ? { observed.append($0) } : nil)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidResponse, "\(guardID)")
                }
                XCTAssertEqual(observed, observe ? [.init(format: .chatJSON, guardID: guardID)] : [])
                if let diagnostic = observed.first {
                    XCTAssertTrue(diagnostic.isConsistent)
                    let bytes = try JSONEncoder().encode(diagnostic)
                    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    XCTAssertEqual(Set(fields.keys), ["format", "guardID"])
                    XCTAssertLessThan(bytes.count, 128); XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
                }
            }
        }
    }

    func testFatalSSEGuardsRetainExactFailuresWithoutCapturingChunkValues() throws {
        let prepared = try request()
        typealias Guard = APIModelResponseCodec.InvalidResponseDiagnostic.Guard
        func row(_ delta: Any, index: Any = 0, id: String = "PRIVATE_REMOTE_CANARY", finish: Any = NSNull()) -> [String: Any] {
            ["id": id, "model": "fixture-model", "choices": [["index": index, "delta": delta, "finish_reason": finish]]]
        }
        func wire(_ chunks: [[String: Any]], done: Bool = true) throws -> Data {
            var data = Data()
            for chunk in chunks { data.append(Data("data: ".utf8)); data.append(try JSONSerialization.data(withJSONObject: chunk)); data.append(Data("\n\n".utf8)) }
            if done { data.append(Data("data: [DONE]\n\n".utf8)) }; return data
        }
        let first = row(["role": "assistant", "content": "PRIVATE_TEXT_CANARY"])
        var missingID = first; missingID.removeValue(forKey: "id")
        let initialCall: [String: Any] = ["index": 0, "id": "PRIVATE_CALL_CANARY", "function": ["name": "computa_tool_0", "arguments": "{}"]]
        let cases: [(Data, Guard)] = [
            (Data([0xff]), .sseUTF8), (try wire([first], done: true) + wire([first]), .sseAfterDone),
            (try wire([missingID]), .sseChunkEnvelope), (try wire([first, row([:], id: "PRIVATE_CHANGED_CANARY")]), .sseChunkIdentity),
            (try wire([row(["role": "assistant"], index: true)]), .sseChoiceIndex), (try wire([row([])]), .sseChoiceDelta),
            (try wire([row(["role": "user"])]), .sseRole), (try wire([row(["content": []])]), .sseContentType),
            (try wire([row(["reasoning": []])]), .sseReasoningType),
            (try wire([row(["tool_calls": [["index": true]]])]), .sseToolIndex),
            (try wire([row(["role": "assistant", "tool_calls": [initialCall]]), row(["tool_calls": [initialCall]])]), .sseRepeatedCallID),
            (try wire([row(["tool_calls": false])]), .sseCallsType)]
        for (body, guardID) in cases {
            let result = APIProviderHTTPClient.Result(body: body, contentType: "text/event-stream")
            for observe in [false, true] {
                var observed: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
                XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared,
                    onInvalidResponse: observe ? { observed.append($0) } : nil)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidResponse, "\(guardID)")
                }
                XCTAssertEqual(observed, observe ? [.init(format: .chatSSE, guardID: guardID)] : [])
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(observed), as: UTF8.self).contains("PRIVATE"))
            }
        }
    }

    func testResponseGuardObservationIgnoresNonfatalUsageProbeAndOtherFailureKinds() throws {
        let prepared = try request()
        // The existing assembler tolerates an unusable intermediate usage field
        // for a clean reply. That speculative try? must never emit a fatal label.
        let chunks: [[String: Any]] = [
            ["id": "remote", "model": "fixture-model", "choices": [["index": 0, "delta": ["role": "assistant", "content": "safe"], "finish_reason": "stop"]], "usage": false],
            ["id": "remote", "model": "fixture-model", "choices": [], "usage": ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2]]]
        var wire = Data()
        for chunk in chunks { wire.append(Data("data: ".utf8)); wire.append(try JSONSerialization.data(withJSONObject: chunk)); wire.append(Data("\n\n".utf8)) }
        wire.append(Data("data: [DONE]\n\n".utf8))
        var observed: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
        guard case .reply = try APIModelResponseCodec.decodeForCorrection(.init(body: wire, contentType: "text/event-stream"), request: prepared,
            onInvalidResponse: { observed.append($0) }) else { return XCTFail("Expected unchanged clean reply") }
        XCTAssertTrue(observed.isEmpty)
        let failures: [(APIProviderHTTPClient.Result, APIModelResponseCodec.Failure)] = [
            (try correctionResult(prepared, changes: ["model": "other"]), .modelMismatch),
            (.init(body: Data("data: [DONE]\n\n".utf8), contentType: "text/event-stream"), .incompleteResponse)]
        for (result, expected) in failures {
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared,
                onInvalidResponse: { observed.append($0) })) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, expected) }
            XCTAssertTrue(observed.isEmpty)
        }
        guard case .argumentsRejected = try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared), request: prepared,
            onInvalidResponse: { observed.append($0) }) else { return XCTFail("Existing bounded argument-correction classification must be unchanged") }
        XCTAssertTrue(observed.isEmpty)
    }

    func testNativeResponsesFatalGuardLabelsStayBoundToTheirOwnFormat() throws {
        let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: .responses, models: provider.models)
        let prepared = try request(provider: p)
        typealias Guard = APIModelResponseCodec.InvalidResponseDiagnostic.Guard
        let items: [([String: Any], Guard)] = [
            (["type": "message"], .responsesItemIdentity),
            (["type": "message", "id": "i", "role": "user"], .responsesMessage),
            (["type": "reasoning", "id": "i", "summary": false], .responsesSummary),
            (["type": "reasoning", "id": "i", "summary": [], "encrypted_content": false], .responsesEncryptedType),
            (["type": "PRIVATE_UNKNOWN_CANARY", "id": "i"], .responsesItemType)]
        for (item, guardID) in items {
            let body = try JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed", "model": "fixture-model", "output": [item]])
            var observed: [APIModelResponseCodec.InvalidResponseDiagnostic] = []
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: body, contentType: "application/json"), request: prepared,
                onInvalidResponse: { observed.append($0) })) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidResponse) }
            XCTAssertEqual(observed, [.init(format: .responsesJSON, guardID: guardID)])
            XCTAssertTrue(try XCTUnwrap(observed.first).isConsistent)
        }
    }

    func testSchemaFeedbackLocalizesCustomMissingInputAndNeverCopiesRejectedPrivateKeysOrValues() throws {
        let custom = try request(["tools": [tools[1]]])
        let missing = try rejectedDetails(custom, arguments: "{}")
        XCTAssertEqual(missing.count, 1); XCTAssertEqual(missing[0].constraint, .missingRequired)
        let (customFacts, customJSON) = try schemaFeedback(custom, details: missing)
        XCTAssertEqual(customFacts[0]["schema_path"] as? [String], ["properties", "input"])
        XCTAssertEqual(customFacts[0]["expected_types"] as? [String], ["string"])
        XCTAssertEqual(customFacts[0]["callable"] as? String, custom.tools[0].wireName)
        XCTAssertFalse(customJSON.contains("arguments"))
        let prepared = try request()
        let unknown = try rejectedDetails(prepared, arguments: #"{"path":"PRIVATE_REJECTED_VALUE","PRIVATE_UNKNOWN_KEY":"PRIVATE_REASONING_VALUE"}"#)
        XCTAssertEqual(unknown[0].constraint, .unexpectedFields)
        let (facts, json) = try schemaFeedback(prepared, details: unknown)
        XCTAssertEqual(facts[0]["declared_fields"] as? [String], ["path"])
        XCTAssertEqual(facts[0]["additional_fields_allowed"] as? Bool, false)
        for privateText in ["PRIVATE_REJECTED_VALUE", "PRIVATE_UNKNOWN_KEY", "PRIVATE_REASONING_VALUE"] { XCTAssertFalse(json.contains(privateText)) }
    }
    func testSchemaFeedbackKnownNestedTypeAndArrayItemsAreResolvedOnlyFromOfferedSchema() throws {
        let schema: [String: Any] = ["type": "object", "properties": ["config": ["type": "object", "properties": ["enabled": ["type": "boolean"]], "required": ["enabled"], "additionalProperties": false],
            "values": ["type": "array", "items": ["type": "string"]]], "required": ["config", "values"], "additionalProperties": false]
        let prepared = try request(["tools": [["type": "function", "name": "configure", "parameters": schema]]])
        let nested = try rejectedDetails(prepared, arguments: #"{"config":{"enabled":"PRIVATE_BAD_TYPE"},"values":[]}"#)
        XCTAssertEqual(nested[0].constraint, .typeMismatch)
        let (facts, json) = try schemaFeedback(prepared, details: nested)
        XCTAssertEqual(facts[0]["schema_path"] as? [String], ["properties", "config", "properties", "enabled"])
        XCTAssertEqual(facts[0]["expected_types"] as? [String], ["boolean"]); XCTAssertFalse(json.contains("PRIVATE_BAD_TYPE"))
        let array = try rejectedDetails(prepared, arguments: #"{"config":{"enabled":true},"values":[42]}"#)
        let (arrayFacts, arrayJSON) = try schemaFeedback(prepared, details: array)
        XCTAssertEqual(arrayFacts[0]["schema_path"] as? [String], ["properties", "values", "items"])
        XCTAssertEqual(arrayFacts[0]["expected_types"] as? [String], ["string"]); XCTAssertFalse(arrayJSON.contains("42"))
        let forged = APIModelResponseCodec.ArgumentRejectionDetail(toolIndex: 0, wireName: prepared.tools[0].wireName,
            constraint: .typeMismatch, path: [.property("PRIVATE_UNKNOWN_SCHEMA_PATH")])
        let (safe, forgedJSON) = try schemaFeedback(prepared, details: [forged])
        XCTAssertEqual(safe[0]["constraint"] as? String, "schema_mismatch"); XCTAssertEqual(safe[0]["schema_path"] as? [String], [])
        XCTAssertFalse(forgedJSON.contains("PRIVATE_UNKNOWN_SCHEMA_PATH"))
        let wrongTool = APIModelResponseCodec.ArgumentRejectionDetail(toolIndex: 0, wireName: "PRIVATE_FAKE_TOOL", constraint: .typeMismatch, path: [])
        XCTAssertTrue(try schemaFeedback(prepared, details: [wrongTool]).0.isEmpty)
    }
    func testSchemaFeedbackEnumReferencesCompositionAndTraversalLimitsStayGenericWithoutAcceptance() throws {
        let variants: [[String: Any]] = [
            ["type": "string", "enum": ["allowed"]],
            ["$ref": "#/$defs/value"],
            ["anyOf": [["type": "string"], ["type": "boolean"]]]]
        for leaf in variants {
            let schema: [String: Any] = ["type": "object", "properties": ["value": leaf], "required": ["value"], "additionalProperties": false,
                "$defs": ["value": ["type": "string"]]]
            let prepared = try request(["tools": [["type": "function", "name": "fixture", "parameters": schema]]])
            let details = try rejectedDetails(prepared, arguments: #"{"value":42}"#)
            // Direct type proof is allowed; reference/composition localization is deliberately generic.
            XCTAssertEqual(details[0].constraint, leaf["type"] == nil ? .schemaMismatch : .typeMismatch)
            let (_, json) = try schemaFeedback(prepared, details: details); XCTAssertFalse(json.contains("42"))
        }
        let enumPrepared = try request(["tools": [["type": "function", "name": "fixture", "parameters": ["type": "object", "properties": ["value": ["type": "string", "enum": ["allowed"]]], "required": ["value"]]]]])
        XCTAssertEqual(try rejectedDetails(enumPrepared, arguments: #"{"value":"PRIVATE_ENUM_VALUE"}"#)[0].constraint, .schemaMismatch)
        let arrayPrepared = try request(["tools": [["type": "function", "name": "fixture", "parameters": ["type": "object", "properties": ["values": ["type": "array", "items": ["type": "string"]]], "required": ["values"]]]]])
        let items: [Any] = Array(repeating: "valid", count: 255).map { $0 as Any } + [42]
        let tooMany = try JSONSerialization.data(withJSONObject: ["values": items])
        let bounded = try rejectedDetails(arrayPrepared, arguments: String(decoding: tooMany, as: UTF8.self))
        XCTAssertEqual(bounded[0].constraint, .schemaMismatch); XCTAssertEqual(bounded[0].path, [])
        var nestedSchema: [String: Any] = ["type": "string"], nestedValue: Any = 42
        for _ in 0..<9 {
            nestedSchema = ["type": "object", "properties": ["p": nestedSchema], "required": ["p"], "additionalProperties": false]
            nestedValue = ["p": nestedValue]
        }
        let nested = try request(["tools": [["type": "function", "name": "deep", "parameters": nestedSchema]]])
        let deep = try rejectedDetails(nested, arguments: String(decoding: JSONSerialization.data(withJSONObject: nestedValue), as: UTF8.self))
        XCTAssertEqual(deep[0].constraint, .schemaMismatch); XCTAssertEqual(deep[0].path, [])
    }
    func testSchemaFeedbackFiniteLogsContainOnlyToolIndexAndConstraintAndRequestStillRejectsWholeBatch() throws {
        let prepared = try request()
        let additional: [String: Any] = ["id": "valid-half", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": "{\"path\":\"PRIVATE_VALID_HALF\"}"]]
        var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
        guard case .argumentsRejected(let usage, let details) = try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, arguments: "{\"path\":false}", additionalCalls: [additional]), request: prepared, onArgumentRejection: { observed.append($0) }) else { return XCTFail("Entire batch must be rejected") }
        XCTAssertEqual(usage.totalTokens, 14); XCTAssertEqual(details.count, 1)
        let encoded = try JSONEncoder().encode(observed[0]), object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let finite = object["schemaFailures"] as! [[String: Any]]
        XCTAssertEqual(Set(finite[0].keys), ["toolIndex", "constraint"])
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in [prepared.tools[0].wireName, "path", "PRIVATE_VALID_HALF", "arguments"] { XCTAssertFalse(text.contains(forbidden)) }
    }

    private func diagnosticBrowserDefinition(_ name: String = "browser_read") throws -> [String: Any] {
        // These regressions exercise the still-supported saved cursor catalog.
        let definition: [String: Any]
        if name == "browser_read" { definition = EmbeddedBrowserTools.legacyReadDefinition }
        else { definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name }) }
        return ["type": "function", "name": name, "parameters": try XCTUnwrap(definition["inputSchema"])]
    }
    private func observedSchemaFailure(_ prepared: APIModelResponseCodec.Request, arguments: String,
                                       toolIndex: Int = 0) throws -> APIModelResponseCodec.FiniteSchemaFailure {
        var observed: APIModelResponseCodec.ArgumentValidationDiagnostic?
        let result = try correctionResult(prepared, arguments: arguments, toolIndex: toolIndex)
        guard case .argumentsRejected = try APIModelResponseCodec.decodeForCorrection(result, request: prepared,
            onArgumentRejection: { observed = $0 }) else { throw APIModelResponseCodec.Failure.invalidResponse }
        XCTAssertThrowsError(try APIModelResponseCodec.decode(result, request: prepared), "Diagnostics grant no normal reply or tool publication")
        return try XCTUnwrap(observed?.schemaFailures?.first)
    }
    func testFlatReadFiltersNeedNoAPIRepairWhileForeignCompositionsStillReject() throws {
        let browser = try diagnosticBrowserDefinition()
        for naming in [APIModelResponseCodec.ToolNaming.legacy, .semantic] {
            let prepared = try request(["tools": [function, browser]], toolNaming: naming)
            for arguments in [#"{"cursor":"PRIVATE_CURSOR","view":"content"}"#,
                              #"{"cursor":"PRIVATE_CURSOR","query":"PRIVATE_QUERY"}"#,
                              #"{"cursor":"PRIVATE_CURSOR","view":"all","query":"PRIVATE_QUERY"}"#] {
                var rejected: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
                guard case let .reply(reply) = try APIModelResponseCodec.decodeForCorrection(
                    correctionResult(prepared, arguments: arguments, toolIndex: 1), request: prepared,
                    onArgumentRejection: { rejected.append($0) }) else { return XCTFail("Native state owns filter consistency") }
                XCTAssertTrue(rejected.isEmpty)
                XCTAssertEqual(((reply.response["output"] as? [[String: Any]])?.first?["arguments"] as? String).map { Data($0.utf8) }, Data(arguments.utf8))
            }
            for arguments in [#"{"cursor":"","view":"content"}"#, #"{"cursor":false,"view":"content"}"#,
                              #"{"cursor":"issued","view":null}"#, #"{"cursor":"issued","query":""}"#,
                              #"{"cursor":"issued","view":"unknown"}"#, #"{"cursor":"issued","query":null}"#,
                              #"{"cursor":"issued","query":"valid","PRIVATE_EXTRA":true}"#] {
                let failure = try observedSchemaFailure(prepared, arguments: arguments, toolIndex: 1)
                XCTAssertNotEqual(failure.constraint, .readModeConflict)
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self).contains("PRIVATE_EXTRA"))
            }
        }
        // Compositions outside the exact saved app contract are still enforced.
        var legacy = browser; legacy["parameters"] = savedDisjointBrowserReadSchema()
        var narrowed = legacy, schema = savedDisjointBrowserReadSchema()
        var properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        properties["cursor"]?["type"] = "string"; schema["properties"] = properties; narrowed["parameters"] = schema
        let catalogs: [[[String: Any]]] = [[narrowed], [["type": "namespace", "name": "mcp_external", "tools": [legacy]]]]
        for catalog in catalogs {
            let prepared = try request(["tools": catalog])
            let arguments = #"{"cursor":"PRIVATE_CURSOR","view":"content"}"#
            let failure = try observedSchemaFailure(prepared, arguments: arguments)
            XCTAssertEqual(failure.constraint, .schemaMismatch); XCTAssertNil(failure.location)
            let (records, _) = try schemaFeedback(prepared, details: rejectedDetails(prepared, arguments: arguments))
            XCTAssertNil(records.first?["allowed_forms"])
        }
    }
    func testGenericKnownReadMismatchIdentifiesOnlyProvenRootWithoutInventingConstraint() throws {
        let browser = try diagnosticBrowserDefinition()
        let known = try request(["tools": [browser]])
        for arguments in [#"{"cursor":""}"#, #"{"view":"PRIVATE_UNKNOWN_VIEW"}"#] {
            let failure = try observedSchemaFailure(known, arguments: arguments)
            XCTAssertEqual(failure.constraint, .schemaMismatch)
            XCTAssertEqual(failure.location, .init(tool: .browserRead, schemaPath: [], expectedType: .object, actualType: .object))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self).contains("PRIVATE_UNKNOWN_VIEW"))
        }
        let foreign = try request(["tools": [["type": "namespace", "name": "mcp_external", "tools": [browser]]]])
        XCTAssertNil(try observedSchemaFailure(foreign, arguments: #"{"view":"PRIVATE_UNKNOWN_VIEW"}"#).location)
        var narrowed = browser, schema = savedDisjointBrowserReadSchema()
        var properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        properties["cursor"]?["type"] = "string"; schema["properties"] = properties; narrowed["parameters"] = schema
        let modified = try request(["tools": [narrowed]])
        let failure = try observedSchemaFailure(modified, arguments: #"{"cursor":null}"#)
        XCTAssertEqual(failure.constraint, .schemaMismatch); XCTAssertNil(failure.location)
    }
    func testReadFieldCorrectionIsBoundedAndDoesNotReintroduceRetiredDisjointForms() throws {
        let prepared = try request(["tools": [diagnosticBrowserDefinition()]])
        let arguments = #"{"cursor":"PRIVATE_CURSOR","query":false}"#
        let details = try rejectedDetails(prepared, arguments: arguments)
        XCTAssertEqual(details.first?.constraint, .typeMismatch)
        let (records, text) = try schemaFeedback(prepared, details: details)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["constraint"] as? String, "type_mismatch")
        XCTAssertEqual(records.first?["schema_path"] as? [String], ["properties", "query"])
        XCTAssertEqual(records.first?["expected_types"] as? [String], ["string"])
        XCTAssertNil(records.first?["allowed_forms"])
        XCTAssertLessThanOrEqual(text.utf8.count, 1_536)
        XCTAssertFalse(text.contains("PRIVATE_CURSOR")); XCTAssertFalse(text.contains("read_mode_conflict"))
        let corrected = try APIModelResponseCodec.correctiveRequest(prepared, rejectionDetails: details)
        XCTAssertEqual(corrected.tools.first?.schema as? NSDictionary, prepared.tools.first?.schema as? NSDictionary)
        XCTAssertThrowsError(try browserMutationReply(arguments, request: corrected), "Feedback never normalizes wrong field types")
        for valid in [#"{"cursor":"PRIVATE_CURSOR"}"#,
                      #"{"cursor":"PRIVATE_CURSOR","view":"content","query":"PRIVATE_QUERY"}"#,
                      #"{"cursor":null,"view":"content","query":"PRIVATE_QUERY"}"#] {
            XCTAssertNoThrow(try browserMutationReply(valid, request: corrected))
        }
        let (overflowRecords, overflowText) = try schemaFeedback(prepared, details: Array(repeating: details[0], count: 32))
        XCTAssertTrue(overflowRecords.isEmpty)
        XCTAssertTrue(overflowText.contains(APIModelResponseCodec.correctiveFeedback))
        XCTAssertFalse(overflowText.contains(APIModelResponseCodec.schemaFeedbackMarker), "Optional details keep the existing byte cap")
    }
    func testBuiltinSchemaDiagnosticUsesExactAdmittedOrderAndBothNamingStyles() throws {
        let browser = try diagnosticBrowserDefinition()
        for naming in [APIModelResponseCodec.ToolNaming.legacy, .semantic] {
            for definitions in [[function, browser], [browser, function]] {
                let prepared = try request(["tools": definitions], toolNaming: naming)
                let index = try XCTUnwrap(prepared.tools.firstIndex { $0.name == "browser_read" })
                let failure = try observedSchemaFailure(prepared, arguments: #"{"view":null}"#, toolIndex: index)
                XCTAssertEqual(failure.toolIndex, index)
                XCTAssertEqual(failure.constraint, .typeMismatch)
                XCTAssertEqual(failure.location, .init(tool: .browserRead, schemaPath: [.view], expectedType: .string, actualType: .null))
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self).contains(prepared.tools[index].wireName))
            }
        }
    }
    func testBuiltinSchemaDiagnosticDistinguishesMissingNullBooleanAndNumericTypesWithoutValues() throws {
        for name in ["browser_read", "browser_tabs"] {
            let read = try request(["tools": [diagnosticBrowserDefinition(name)]])
            for (arguments, actual) in [(#"{"cursor":false}"#, APIModelResponseCodec.DiagnosticJSONType.boolean),
                                        (#"{"cursor":91234567}"#, .integer), (#"{"cursor":1.25}"#, .number),
                                        (#"{"cursor":[]}"#, .array), (#"{"cursor":{}}"#, .object)] {
                let failure = try observedSchemaFailure(read, arguments: arguments)
                XCTAssertEqual(failure.location?.tool.rawValue, name)
                XCTAssertEqual(failure.location?.actualType, actual)
                XCTAssertEqual(failure.location?.schemaPath, [.cursor])
                XCTAssertEqual(failure.location?.expectedType, .stringOrNull)
                let text = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
                XCTAssertFalse(text.contains("91234567")); XCTAssertFalse(text.contains("1.25"))
            }
        }
        let wait = try request(["tools": [diagnosticBrowserDefinition("browser_wait")]])
        for (arguments, actual) in [(#"{"timeout_ms":"PRIVATE_ARGUMENT_VALUE"}"#, APIModelResponseCodec.DiagnosticJSONType.string),
                                   (#"{"timeout_ms":true}"#, .boolean)] {
            let failure = try observedSchemaFailure(wait, arguments: arguments)
            XCTAssertEqual(failure.location, .init(tool: .browserWait, schemaPath: [.timeoutMS], expectedType: .integer, actualType: actual))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self).contains("PRIVATE"))
        }
        let open = try request(["tools": [diagnosticBrowserDefinition("browser_open")]])
        let missing = try observedSchemaFailure(open, arguments: "{}")
        XCTAssertEqual(missing.constraint, .missingRequired)
        XCTAssertEqual(missing.location, .init(tool: .browserOpen, schemaPath: [.url], expectedType: .string, actualType: .missing))
        let read = try request(["tools": [diagnosticBrowserDefinition()]])
        guard case .reply = try APIModelResponseCodec.decodeForCorrection(correctionResult(read, arguments: "{}"), request: read) else {
            return XCTFail("Omitted optional fields remain valid")
        }
    }
    func testNullableCursorDiagnosticTypeIsFiniteExpectedOnlyAndKeepsOldJournalLocationsReadable() throws {
        for tool in [APIModelResponseCodec.DiagnosticBuiltinTool.browserRead, .browserTabs] {
            let old = APIModelResponseCodec.BuiltinSchemaLocation(tool: tool, schemaPath: [.cursor],
                expectedType: .string, actualType: .null)
            let current = APIModelResponseCodec.BuiltinSchemaLocation(tool: tool, schemaPath: [.cursor],
                expectedType: .stringOrNull, actualType: .boolean)
            for location in [old, current] {
                XCTAssertEqual(try JSONDecoder().decode(APIModelResponseCodec.BuiltinSchemaLocation.self,
                    from: JSONEncoder().encode(location)), location)
            }
        }
        for location in [
            APIModelResponseCodec.BuiltinSchemaLocation(tool: .browserRead, schemaPath: [.query], expectedType: .stringOrNull, actualType: .boolean),
            .init(tool: .browserTabs, schemaPath: [.query], expectedType: .stringOrNull, actualType: .boolean),
            .init(tool: .browserOpen, schemaPath: [.url], expectedType: .stringOrNull, actualType: .boolean),
            .init(tool: .browserRead, schemaPath: [.cursor], expectedType: .stringOrNull, actualType: .stringOrNull),
            .init(tool: .browserTabs, schemaPath: [.cursor], expectedType: .stringOrNull, actualType: .stringOrNull),
        ] {
            XCTAssertFalse(location.isConsistent)
            XCTAssertThrowsError(try JSONDecoder().decode(APIModelResponseCodec.BuiltinSchemaLocation.self,
                from: JSONEncoder().encode(location)))
        }
    }
    func testUnknownCustomMCPAndModifiedSchemasNeverAcquireBuiltinDiagnosticNames() throws {
        let browser = try diagnosticBrowserDefinition()
        var renamed = browser; renamed["name"] = "PRIVATE_TOOL_NAME"
        var modified = browser
        var schema = try XCTUnwrap(browser["parameters"] as? [String: Any])
        var properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        properties["PRIVATE_SCHEMA_FIELD"] = ["type": "string"]
        schema["properties"] = properties; modified["parameters"] = schema
        var changedType = browser
        var typeSchema = try XCTUnwrap(browser["parameters"] as? [String: Any])
        var typeProperties = try XCTUnwrap(typeSchema["properties"] as? [String: Any])
        typeProperties["cursor"] = ["type": "integer"]
        typeSchema["properties"] = typeProperties; changedType["parameters"] = typeSchema
        let cases: [([[String: Any]], String)] = [
            ([renamed], #"{"view":null}"#),
            ([["type": "namespace", "name": "PRIVATE_MCP_NAMESPACE", "tools": [browser]]], #"{"view":null}"#),
            ([["type": "custom", "name": "browser_read", "format": ["type": "text"]]], #"{"input":false}"#),
            ([modified], #"{"PRIVATE_SCHEMA_FIELD":91234567}"#),
            ([changedType], #"{"cursor":"PRIVATE_VALUE"}"#),
        ]
        for (definitions, arguments) in cases {
            let prepared = try request(["tools": definitions])
            let failure = try observedSchemaFailure(prepared, arguments: arguments)
            XCTAssertNil(failure.location)
            let raw = try JSONEncoder().encode(failure), text = String(decoding: raw, as: UTF8.self)
            XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: raw) as! [String: Any]).keys), ["toolIndex", "constraint"])
            XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains("91234567"))
        }
        let prepared = try request(["tools": [browser]])
        let extra = try observedSchemaFailure(prepared, arguments: #"{"PRIVATE_ARGUMENT_KEY":"PRIVATE_ARGUMENT_VALUE"}"#)
        XCTAssertEqual(extra.location, .init(tool: .browserRead, schemaPath: [], expectedType: .object, actualType: .object))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(extra), as: UTF8.self).contains("PRIVATE"))
    }
    func testDocumentedNestedTimingMetadataAllowsOnlyOtherwiseEligibleArgumentCorrection() throws {
        let prepared = try request()
        let timing: [String: Any] = ["created": 1775679664.285658, "queue_time": 0.000630072,
            "prompt_time": 0.006339716, "completion_time": 0.01440533, "total_time": 0.022999626968]
        let changes: [String: Any] = ["created": 1775679664, "time_info": timing]
        var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
        guard case .argumentsRejected(let usage, _) = try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, changes: changes), request: prepared, onArgumentRejection: { observed.append($0) }) else {
            return XCTFail("Unrelated timing metadata must not poison a fully validated argument-only rejection")
        }
        XCTAssertEqual(usage, .init(inputTokens: 10, outputTokens: 4, totalTokens: 14, cachedInputTokens: 3, reasoningOutputTokens: 2))
        let diagnostic = try XCTUnwrap(observed.count == 1 ? observed.first : nil)
        XCTAssertEqual(diagnostic.reason, .schemaMismatch); XCTAssertTrue(diagnostic.knownUsage)
        XCTAssertTrue(diagnostic.unambiguousJSON); XCTAssertTrue(diagnostic.correctionEligible); XCTAssertNil(diagnostic.jsonRejection)
        XCTAssertTrue(diagnostic.envelopeShapeValid); XCTAssertTrue(diagnostic.streamShapeAndUsageValid)
        for rootCreated: Any in [1775679664.5, -1, true, "PRIVATE_INVALID_CREATED"] {
            let bad = changes.merging(["created": rootCreated]) { _, new in new }
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, changes: bad), request: prepared))
        }
        for nonArgumentChange: [String: Any] in [["model": "PRIVATE_WRONG_MODEL"], ["usage": NSNull()],
                ["usage": ["prompt_tokens": true, "completion_tokens": 4]],
                ["usage": ["prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 99]]] {
            let bad = changes.merging(nonArgumentChange) { _, new in new }
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, changes: bad), request: prepared))
        }
        let unknown: [String: Any] = ["id": "PRIVATE_UNKNOWN", "type": "function", "function": ["name": "PRIVATE_UNOFFERED", "arguments": "{}"]]
        let duplicate: [String: Any] = ["id": "rejected-call", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": "{\"path\":\"safe\"}"]]
        for call in [unknown, duplicate] {
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, changes: changes, additionalCalls: [call]), request: prepared)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
            }
        }
        let wire = try correctionResult(prepared, changes: changes).body
        let duplicateMetadata = String(decoding: wire, as: UTF8.self).replacingOccurrences(of: "\"time_info\":{", with: "\"time_info\":{\"PRIVATE_DUPLICATE_METADATA\":1,\"PRIVATE_DUPLICATE_METADATA\":2,")
        XCTAssertNotEqual(duplicateMetadata, String(decoding: wire, as: UTF8.self))
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: Data(duplicateMetadata.utf8), contentType: "application/json"), request: prepared)) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
        }
        let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertFalse(json.contains("1775679664")); XCTAssertFalse(json.contains("time_info")); XCTAssertFalse(json.contains("PRIVATE"))
    }
    func testArgumentDecodeJSONScannerDiagnosticsDoNotAuthorizeCorrectionOrCapturePayload() throws {
        let prepared = try request(), normal = try correctionResult(prepared)
        let text = String(decoding: normal.body, as: UTF8.self)
        let cases: [(String, APIModelCorrectionJSON.RejectionDiagnostic.Reason, APIModelCorrectionJSON.RejectionDiagnostic.KeyCategory)] = [
            (text.replacingOccurrences(of: "\"index\":0", with: "\"index\":0.0"), .integerLexeme, .choiceIndex),
            (text.replacingOccurrences(of: "\"total_tokens\":14", with: "\"total_tokens\":14.0"), .integerLexeme, .usageCounter),
            (text.replacingOccurrences(of: "\"total_tokens\":14", with: "\"total_tokens\":14,\"total_tokens\":14"), .duplicateKey, .usageCounter)]
        for (raw, reason, category) in cases {
            XCTAssertNotEqual(text, raw)
            let result = APIProviderHTTPClient.Result(body: Data(raw.utf8), contentType: "application/json")
            var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared, onArgumentRejection: { observed.append($0) })) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
            let diagnostic = try XCTUnwrap(observed.count == 1 ? observed.first : nil)
            XCTAssertTrue(diagnostic.envelopeShapeValid); XCTAssertTrue(diagnostic.knownUsage); XCTAssertTrue(diagnostic.streamShapeAndUsageValid)
            XCTAssertFalse(diagnostic.unambiguousJSON); XCTAssertFalse(diagnostic.correctionEligible)
            XCTAssertEqual(diagnostic.jsonRejection, .init(reason: reason, keyCategory: category))
            let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
            for privateValue in ["remote-rejected", "rejected-call", prepared.tools[0].wireName, "path", "arguments", "14.0"] { XCTAssertFalse(encoded.contains(privateValue)) }
        }
        let usage: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14]
        let chunks: [[String: Any]] = [
            ["id": "PRIVATE_STREAM", "object": "chat.completion.chunk", "model": prepared.model.id,
             "choices": [["index": 0, "delta": ["role": "assistant", "tool_calls": [["index": 0, "id": "PRIVATE_CALL", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": "{\"path\":false}"]]]], "finish_reason": NSNull()]]],
            ["id": "PRIVATE_STREAM", "object": "chat.completion.chunk", "model": prepared.model.id,
             "choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]],
            ["id": "PRIVATE_STREAM", "object": "chat.completion.chunk", "model": prepared.model.id, "choices": [], "usage": usage]]
        var bytes = Data()
        for (index, chunk) in chunks.enumerated() {
            var json = String(decoding: try JSONSerialization.data(withJSONObject: chunk, options: [.sortedKeys]), as: UTF8.self)
            if index == 0 { json = json.replacingOccurrences(of: "\"index\":0", with: "\"index\":0.0") }
            bytes.append(Data(("data: " + json + "\n\n").utf8))
        }
        bytes.append(Data("data: [DONE]\n\n".utf8))
        var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: bytes, contentType: "text/event-stream"), request: prepared, onArgumentRejection: { observed.append($0) })) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
        }
        let diagnostic = try XCTUnwrap(observed.count == 1 ? observed.first : nil)
        XCTAssertEqual(diagnostic.jsonRejection, .init(reason: .integerLexeme, keyCategory: .choiceIndex))
        XCTAssertFalse(diagnostic.correctionEligible); XCTAssertFalse(diagnostic.unambiguousJSON)
        XCTAssertTrue(diagnostic.envelopeShapeValid); XCTAssertTrue(diagnostic.streamShapeAndUsageValid); XCTAssertTrue(diagnostic.knownUsage)
    }
    func testArgumentDecodeDiagnosticsDistinguishJSONSchemaAndSizeWithoutGrantingCorrection() throws {
        let prepared = try request()
        let cases: [(String, APIModelResponseCodec.ArgumentValidationDiagnostic.Reason)] = [
            ("{PRIVATE_ARGUMENT_SECRET_URL", .invalidJSON), ("[\"PRIVATE_ARGUMENT_SECRET_URL\"]", .nonObject),
            ("{\"path\":false,\"PRIVATE_ARGUMENT_SECRET_URL\":42}", .schemaMismatch),
            (String(repeating: "x", count: 2_000_001), .oversized)]
        for (arguments, reason) in cases {
            var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
            let result = try correctionResult(prepared, arguments: arguments)
            if reason == .oversized {
                XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared, onArgumentRejection: { observed.append($0) })) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                }
                XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared))
            } else {
                guard case .argumentsRejected(let usage, _) = try APIModelResponseCodec.decodeForCorrection(result, request: prepared, onArgumentRejection: { observed.append($0) }),
                      case .argumentsRejected(let unchangedUsage, _) = try APIModelResponseCodec.decodeForCorrection(result, request: prepared) else { return XCTFail("No rejected call may become a reply") }
                XCTAssertEqual(usage, unchangedUsage)
            }
            let diagnostic = try XCTUnwrap(observed.count == 1 ? observed.first : nil)
            XCTAssertEqual(diagnostic.reason, reason); XCTAssertEqual(diagnostic.callCount, 1); XCTAssertEqual(diagnostic.rejectedCount, 1)
            XCTAssertTrue(diagnostic.envelopeShapeValid); XCTAssertTrue(diagnostic.unambiguousJSON)
            XCTAssertTrue(diagnostic.streamShapeAndUsageValid); XCTAssertTrue(diagnostic.knownUsage)
            XCTAssertEqual(diagnostic.correctionEligible, reason != .oversized)
            let data = try JSONEncoder().encode(diagnostic), text = String(decoding: data, as: UTF8.self)
            XCTAssertLessThanOrEqual(data.count, 512)
            for privateValue in ["PRIVATE", "remote-rejected", "rejected-call", prepared.tools[0].wireName, "path", "http"] { XCTAssertFalse(text.contains(privateValue)) }
        }
    }
    func testArgumentDecodeDiagnosticsExposeMissingUsageAndUnsafeEnvelopeWithoutCorrection() throws {
        let prepared = try request(), normal = try correctionResult(prepared)
        let text = String(decoding: normal.body, as: UTF8.self)
        let ambiguous = text.replacingOccurrences(of: "\"total_tokens\":14", with: "\"total_tokens\":14,\"total_tokens\":14")
        XCTAssertNotEqual(text, ambiguous)
        let cases: [(APIProviderHTTPClient.Result, Bool, Bool, Bool, APIModelResponseCodec.ArgumentValidationDiagnostic.EnvelopeRejection?)] = [
            (try correctionResult(prepared, changes: ["usage": NSNull()]), true, true, false, nil),
            (try correctionResult(prepared, changes: ["id": ""]), false, true, true, .invalidID),
            (try correctionResult(prepared, changes: ["id": NSNull()]), false, true, true, .missingID),
            (try correctionResult(prepared, changes: ["error": "PRIVATE_PROVIDER_ERROR"]), false, true, true, .errorPresent),
            (try correctionResult(prepared, changes: ["object": "PRIVATE_WRONG_OBJECT"]), false, true, true, .objectKind),
            (try correctionResult(prepared, changes: ["system_fingerprint": 42]), false, true, true, .systemFingerprintType),
            (try correctionResult(prepared, changes: ["created": 0.5]), false, false, true, .createdNoninteger),
            (try correctionResult(prepared, changes: ["created": true]), false, true, true, .createdNoninteger),
            (try correctionResult(prepared, changes: ["created": "PRIVATE_TIMESTAMP"]), false, true, true, .createdNoninteger),
            (try correctionResult(prepared, changes: ["created": -1]), false, false, true, .createdOutOfRange),
            (try correctionResult(prepared, changes: ["created": 4_102_444_801]), false, true, true, .createdOutOfRange),
            (.init(body: Data(ambiguous.utf8), contentType: "application/json"), true, false, true, nil)]
        for (result, shape, unambiguous, usage, envelopeReason) in cases {
            var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared, onArgumentRejection: { observed.append($0) })) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
            let diagnostic = try XCTUnwrap(observed.count == 1 ? observed.first : nil)
            XCTAssertEqual(diagnostic.reason, .schemaMismatch); XCTAssertEqual(diagnostic.envelopeShapeValid, shape)
            XCTAssertEqual(diagnostic.unambiguousJSON, unambiguous); XCTAssertEqual(diagnostic.knownUsage, usage)
            XCTAssertEqual(diagnostic.envelopeRejection, envelopeReason); XCTAssertFalse(diagnostic.correctionEligible)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains("PRIVATE"))
        }
    }
    func testArgumentDecodeDiagnosticsNeverMaskLaterIdentityUsageReasoningOrModelFailures() throws {
        let prepared = try request()
        let unknown: [String: Any] = ["id": "PRIVATE_UNKNOWN_CALL", "type": "function", "function": ["name": "PRIVATE_UNKNOWN_TOOL", "arguments": "{}"]]
        let duplicate: [String: Any] = ["id": "rejected-call", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": "{\"path\":\"safe\"}"]]
        let cases: [(APIProviderHTTPClient.Result, APIModelResponseCodec.Failure)] = [
            (try correctionResult(prepared, additionalCalls: [unknown]), .invalidTool),
            (try correctionResult(prepared, additionalCalls: [duplicate]), .invalidTool),
            (try correctionResult(prepared, changes: ["model": "PRIVATE_WRONG_MODEL"]), .modelMismatch),
            (try correctionResult(prepared, changes: ["usage": ["prompt_tokens": true, "completion_tokens": 4]]), .invalidResponse)]
        for (result, expected) in cases {
            var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(result, request: prepared, onArgumentRejection: { observed.append($0) })) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, expected)
            }
            XCTAssertTrue(observed.isEmpty, "An argument diagnostic is not a complete-envelope validation bypass")
        }
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: correctionResult(prepared).body) as? [String: Any])
        var choices = envelope["choices"] as! [[String: Any]], message = choices[0]["message"] as! [String: Any]
        message["reasoning"] = String(repeating: "x", count: 2_000_001); choices[0]["message"] = message; envelope["choices"] = choices
        var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: JSONSerialization.data(withJSONObject: envelope), contentType: "application/json"), request: prepared, onArgumentRejection: { observed.append($0) })) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidReasoning)
        }
        XCTAssertTrue(observed.isEmpty)
    }
    func testArgumentDecodeDiagnosticsDistinguishConflictingStreamUsageFromEnvelopeAmbiguity() throws {
        let prepared = try request()
        let chunks: [[String: Any]] = [
            ["id": "PRIVATE_STREAM_ID", "object": "chat.completion.chunk", "model": prepared.model.id,
             "choices": [["index": 0, "delta": ["role": "assistant", "tool_calls": [["index": 0, "id": "PRIVATE_CALL_ID", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": "{\"path\":false}"]]]], "finish_reason": NSNull()]],
             "usage": ["prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14]],
            ["id": "PRIVATE_STREAM_ID", "object": "chat.completion.chunk", "model": prepared.model.id,
             "choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]],
            ["id": "PRIVATE_STREAM_ID", "object": "chat.completion.chunk", "model": prepared.model.id, "choices": [],
             "usage": ["prompt_tokens": 11, "completion_tokens": 4, "total_tokens": 15]]]
        var data = Data()
        for chunk in chunks { data.append(Data("data: ".utf8)); data.append(try JSONSerialization.data(withJSONObject: chunk)); data.append(Data("\n\n".utf8)) }
        data.append(Data("data: [DONE]\n\n".utf8))
        var observed: [APIModelResponseCodec.ArgumentValidationDiagnostic] = []
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: data, contentType: "text/event-stream"), request: prepared, onArgumentRejection: { observed.append($0) })) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
        }
        let diagnostic = try XCTUnwrap(observed.count == 1 ? observed.first : nil)
        XCTAssertTrue(diagnostic.envelopeShapeValid); XCTAssertTrue(diagnostic.unambiguousJSON); XCTAssertTrue(diagnostic.knownUsage)
        XCTAssertFalse(diagnostic.streamShapeAndUsageValid); XCTAssertFalse(diagnostic.correctionEligible)
    }
    func testArgumentCorrectionRequiresCompleteBatchAndPresentExactUsageBeforeClassification() throws {
        let prepared = try request()
        for bad in ["{", "{\"path\":false}"] {
            guard case .argumentsRejected(let usage, _) = try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, arguments: bad), request: prepared) else { return XCTFail("Expected argument-only rejection") }
            XCTAssertEqual(usage, .init(inputTokens: 10, outputTokens: 4, totalTokens: 14, cachedInputTokens: 3, reasoningOutputTokens: 2))
        }
        let unknown: [String: Any] = ["id": "unknown-call", "type": "function", "function": ["name": "unoffered", "arguments": "{}"]]
        let duplicate: [String: Any] = ["id": "rejected-call", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": "{\"path\":\"ok\"}"]]
        for call in [unknown, duplicate] {
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, additionalCalls: [call]), request: prepared)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
            }
        }
        for changes: [String: Any] in [["model": "wrong"], ["usage": NSNull()],
                ["usage": ["prompt_tokens": true, "completion_tokens": 4]],
                ["usage": ["prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 99]]] {
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, changes: changes), request: prepared))
        }
    }
    func testArgumentCorrectionDoesNotHideBadReasoningOrIncompleteStreamOrMissingArgumentShape() throws {
        let prepared = try request()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: correctionResult(prepared).body) as? [String: Any])
        var choices = raw["choices"] as! [[String: Any]], message = choices[0]["message"] as! [String: Any]
        message["reasoning"] = ["PRIVATE_REASONING"]; choices[0]["message"] = message; raw["choices"] = choices
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: JSONSerialization.data(withJSONObject: raw), contentType: "application/json"), request: prepared)) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidResponse)
        }
        choices[0]["finish_reason"] = "length"; raw["choices"] = choices
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: JSONSerialization.data(withJSONObject: raw), contentType: "application/json"), request: prepared))
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: Data("data: {}\n\n".utf8), contentType: "text/event-stream"), request: prepared))
        let oversized = String(repeating: "a", count: 2_000_001)
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, arguments: oversized), request: prepared))
        var hugeReasoning = try XCTUnwrap(JSONSerialization.jsonObject(with: correctionResult(prepared).body) as? [String: Any])
        var hugeChoices = hugeReasoning["choices"] as! [[String: Any]], hugeMessage = hugeChoices[0]["message"] as! [String: Any]
        hugeMessage["reasoning"] = oversized; hugeChoices[0]["message"] = hugeMessage; hugeReasoning["choices"] = hugeChoices
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: JSONSerialization.data(withJSONObject: hugeReasoning), contentType: "application/json"), request: prepared)) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidReasoning)
        }
        let streamID = "remote-stream", alias = prepared.tools[0].wireName
        func chunk(_ delta: [String: Any], finish: Any = NSNull(), usage: Any = NSNull()) -> [String: Any] {
            ["id": streamID, "object": "chat.completion.chunk", "model": prepared.model.id,
             "choices": [["index": 0, "delta": delta, "finish_reason": finish]], "usage": usage]
        }
        let start = chunk(["role": "assistant", "tool_calls": [["index": 0, "id": "bad-stream", "type": "function", "function": ["name": alias, "arguments": "{"]]]])
        let finish = chunk([:], finish: "tool_calls")
        let validUsage: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14]
        let end: [String: Any] = ["id": streamID, "model": prepared.model.id, "choices": [], "usage": validUsage]
        for malformed in [chunk(["tool_calls": [["index": 0, "function": ["arguments": 42]]]]),
                chunk(["role": 42]), chunk(["tool_calls": [["index": 0, "function": false]]]),
                chunk(["tool_calls": [["index": 0, "function": ["arguments": NSNull()]]]]),
                chunk(["tool_calls": [["index": 0, "id": NSNull()]]]),
                chunk([:], usage: ["prompt_tokens": true, "completion_tokens": 4, "total_tokens": 5])] {
            var bytes = Data()
            for value in [start, malformed, finish, end] {
                bytes.append(Data("data: ".utf8)); bytes.append(try JSONSerialization.data(withJSONObject: value)); bytes.append(Data("\n\n".utf8))
            }
            bytes.append(Data("data: [DONE]\n\n".utf8))
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: bytes, contentType: "text/event-stream"), request: prepared))
        }
        let normal = try correctionResult(prepared).body, bodyText = String(decoding: normal, as: UTF8.self)
        // These otherwise parse through Foundation; ambiguity must not spend an inference.
        for ambiguous in [bodyText.replacingOccurrences(of: "\"prompt_tokens\":10", with: "\"prompt_tokens\":10.00000000000000001"),
                          bodyText.replacingOccurrences(of: "\"total_tokens\":14", with: "\"total_tokens\":14,\"total_tokens\":14")] {
            XCTAssertNotEqual(ambiguous, bodyText)
            XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(.init(body: Data(ambiguous.utf8), contentType: "application/json"), request: prepared))
        }
        let nonString: [String: Any] = ["id": "non-string", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": true]]
        XCTAssertThrowsError(try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, additionalCalls: [nonString]), request: prepared)) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
        }
    }
    func testCorrectiveRequestChangesOnlyTrustedLeadingFeedbackAndPreservesConfirmedHistoryAndCatalog() throws {
        let history: [[String: Any]] = [["role": "user", "content": "PRIVATE_USER_URL_/_😀"],
            ["type": "function_call", "call_id": "prior", "name": "read", "namespace": "files", "arguments": "{\"path\":\"completed\"}"],
            ["type": "function_call_output", "call_id": "prior", "output": "PRIVATE_CONFIRMED_RESULT"]]
        let original = try request(["input": history])
        let corrected = try APIModelResponseCodec.correctiveRequest(original)
        var before = try XCTUnwrap(JSONSerialization.jsonObject(with: original.body) as? [String: Any])
        var after = try XCTUnwrap(JSONSerialization.jsonObject(with: corrected.body) as? [String: Any])
        var beforeMessages = before.removeValue(forKey: "messages") as! [[String: Any]]
        var afterMessages = after.removeValue(forKey: "messages") as! [[String: Any]]
        XCTAssertEqual(before as NSDictionary, after as NSDictionary)
        let first = beforeMessages.removeFirst(), updated = afterMessages.removeFirst()
        XCTAssertEqual(updated["role"] as? String, "system")
        XCTAssertEqual(updated["content"] as? String, (first["content"] as! String) + "\n\n" + APIModelResponseCodec.correctiveFeedback)
        XCTAssertEqual(beforeMessages as NSArray, afterMessages as NSArray)
        XCTAssertEqual(corrected.historyCallIDs, original.historyCallIDs)
        XCTAssertEqual(corrected.allowedTools, original.allowedTools)
        XCTAssertEqual(corrected.tools.map(\.wireName), original.tools.map(\.wireName))
        XCTAssertEqual(corrected.toolNaming, original.toolNaming)
        XCTAssertFalse(APIModelResponseCodec.correctiveFeedback.contains("PRIVATE"))
        XCTAssertTrue(APIModelResponseCodec.correctiveFeedback.contains("No call from that rejected response was executed"))
        XCTAssertEqual(try APIModelResponseCodec.correctiveRequest(request(["instructions": NSNull()])).provider, original.provider)
    }
    func testCorrectionMetadataSeparatesBillableUsageFromAcceptedContextAndNeverAddsCalls() throws {
        let prepared = try request()
        let reply = try decode(["role": "assistant", "content": "done"], request: prepared)
        let first = APIModelCorrectionUsage(inputTokens: 10, outputTokens: 4, totalTokens: 14, cachedInputTokens: 3, reasoningOutputTokens: 2)
        let second = try XCTUnwrap(APIModelResponseCodec.correctionUsage(reply.response["usage"]))
        let ticket = APIModelCorrectionAccounting.Ticket(id: UUID(), taskID: taskID, threadID: taskID, turnID: taskID, firstUsage: first)
        let corrected = try APIModelResponseCodec.withCorrectionMetadata(reply, ticket: ticket, secondUsage: second)
        XCTAssertEqual(corrected.response["usage"] as? NSDictionary, reply.response["usage"] as? NSDictionary)
        XCTAssertEqual(corrected.response["output"] as? NSArray, reply.response["output"] as? NSArray)
        let meta = try XCTUnwrap(corrected.response["x_computa_correction"] as? [String: Any])
        XCTAssertEqual(meta["recovered"] as? Bool, true); XCTAssertEqual(meta["attempt_count"] as? Int, 2)
        XCTAssertEqual((meta["known_billable_usage"] as? [String: Any])?["input_tokens"] as? Int, 22)
        XCTAssertEqual((corrected.response["usage"] as? [String: Any])?["input_tokens"] as? Int, 12)
        let encoded = String(decoding: try APIModelResponseCodec.encode(corrected, stream: true), as: UTF8.self)
        XCTAssertTrue(encoded.contains("x_computa_correction")); XCTAssertFalse(encoded.contains("function_call")); XCTAssertFalse(encoded.contains("custom_tool_call"))
        XCTAssertFalse(encoded.contains("PRIVATE"))
    }

    func testSemanticToolNamesStayStableAcrossFilteringReorderingAndNamedChoice() throws {
        let chrome: [String: Any] = ["type": "function", "name": "computer_v2_tabs", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        let browser: [String: Any] = ["type": "function", "name": "browser_open", "description": "Open the requested built-in page.",
            "parameters": ["type": "object", "properties": ["url": ["type": "string"],
                "caller_scope": ["type": "string", "enum": ["fixture"], "description": "Caller-owned optional field."]],
                "required": ["url"], "additionalProperties": false]]
        let expectedParameters: [String: Any] = ["type": "object", "properties": [
            "url": ["type": "string", "minLength": 1],
            "caller_scope": ["type": "string", "enum": ["fixture"], "description": "Caller-owned optional field."]],
            "required": ["url"], "additionalProperties": false]
        var aliases: [String] = []
        for definitions in [[browser], [chrome, browser], [browser, chrome]] {
            let prepared = try request(["tools": [["type": "namespace", "name": "functions", "tools": definitions]],
                                        "tool_choice": ["type": "function", "name": "browser_open", "namespace": "functions"]], toolNaming: .semantic)
            XCTAssertEqual(prepared.toolNaming, .semantic)
            let declared = try wireFunctions(prepared)
            XCTAssertEqual(declared.count, 1)
            let function = try XCTUnwrap(declared.first), alias = try XCTUnwrap(function["name"] as? String)
            aliases.append(alias)
            XCTAssertNotNil(alias.range(of: #"^browser_open__[0-9a-f]{24}$"#, options: .regularExpression))
            XCTAssertTrue((function["description"] as? String ?? "").contains("Callable API function: \(alias)."))
            XCTAssertEqual(function["parameters"] as? NSDictionary, expectedParameters as NSDictionary,
                           "Only the canonical URL constraint changes; caller fields, enum and identity stay intact")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            XCTAssertEqual(((body["tool_choice"] as? [String: Any])?["function"] as? [String: Any])?["name"] as? String, alias)
            XCTAssertEqual(prepared.allowedTools, [alias])
            let reply = try decode(["role": "assistant", "tool_calls": [["id": "open", "type": "function", "function": ["name": alias, "arguments": "{\"url\":\"http://127.0.0.1/inbox\"}"]]]], finish: "tool_calls", request: prepared)
            let result = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first)
            XCTAssertEqual(result["name"] as? String, "browser_open")
            XCTAssertEqual(result["namespace"] as? String, "functions")
            for unoffered in ["browser_open", "functions.browser_open", "computa_tool_0", "computa_tool_1"] {
                XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "bad", "type": "function", "function": ["name": unoffered, "arguments": "{\"url\":\"http://127.0.0.1/inbox\"}"]]]], finish: "tool_calls", request: prepared)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
                }
            }
            XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "bad-args", "type": "function", "function": ["name": alias, "arguments": "{\"url\":false}"]]]], finish: "tool_calls", request: prepared)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
        }
        XCTAssertEqual(Set(aliases).count, 1)
        let completedHistory: [[String: Any]] = [
            ["type": "function_call", "call_id": "old-chrome", "name": "computer_v2_tabs", "namespace": "functions", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "old-chrome", "output": "Old result retained"],
            ["type": "function_call", "call_id": "old-browser", "name": "browser_open", "namespace": "functions", "arguments": "{\"url\":\"http://127.0.0.1/inbox\"}"],
            ["type": "function_call_output", "call_id": "old-browser", "output": "Fixture opened"],
        ]
        let resumed = try request(["tools": [["type": "namespace", "name": "functions", "tools": [browser, chrome]]], "input": completedHistory], toolNaming: .semantic)
        let resumedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: resumed.body) as? [String: Any])
        let resumedMessages = try XCTUnwrap(resumedBody["messages"] as? [[String: Any]])
        let oldCalls = resumedMessages.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }
        let hiddenAlias = try XCTUnwrap((oldCalls[0]["function"] as? [String: Any])?["name"] as? String)
        XCTAssertTrue(hiddenAlias.hasPrefix("computer_v2_tabs__"))
        XCTAssertEqual((oldCalls[1]["function"] as? [String: Any])?["name"] as? String, aliases[0])
        XCTAssertEqual(resumed.allowedTools, [aliases[0]])
        XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "hidden", "type": "function", "function": ["name": hiddenAlias, "arguments": "{}"]]]], finish: "tool_calls", request: resumed)) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
        }
        let legacy = try request(["tools": [browser]])
        XCTAssertEqual(legacy.toolNaming, .legacy)
        XCTAssertEqual(legacy.tools.first?.wireName, "computa_tool_0")
    }
    func testSemanticToolNamesPreserveQualifiedIdentityAndBoundsWithoutOrderFallback() throws {
        func named(_ name: String) -> [String: Any] { function.merging(["name": name]) { _, new in new } }
        let long = String(repeating: "a", count: 127)
        let definitions: [[String: Any]] = [
            ["type": "namespace", "name": "files", "tools": [named("read")]],
            ["type": "namespace", "name": "records", "tools": [named("read")]],
            named("read"), named("read.file"), named("read_file"), named("read-file"), named(long + "x"), named(long + "y"),
        ]
        let prepared = try request(["tools": definitions], toolNaming: .semantic)
        let aliases = prepared.tools.map(\.wireName)
        XCTAssertEqual(Set(aliases).count, definitions.count)
        XCTAssertEqual(aliases[6].utf8.count, 64)
        XCTAssertEqual(aliases[7].utf8.count, 64)
        XCTAssertTrue(aliases.allSatisfy { $0.utf8.count <= 64 && $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil })
        XCTAssertTrue(aliases[3].hasPrefix("read_file__"))
        XCTAssertTrue(aliases[4].hasPrefix("read_file__"))
        XCTAssertNotEqual(aliases[3], aliases[4])
        XCTAssertTrue(aliases[5].hasPrefix("read-file__"))
        let reversed = try request(["tools": Array(definitions.reversed())], toolNaming: .semantic)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: prepared.tools.map { ($0.identity, $0.wireName) }),
                       Dictionary(uniqueKeysWithValues: reversed.tools.map { ($0.identity, $0.wireName) }))
        for (index, tool) in prepared.tools.enumerated() {
            let reply = try decode(["role": "assistant", "tool_calls": [["id": "call-\(index)", "type": "function", "function": ["name": tool.wireName, "arguments": "{\"path\":\"fixture\"}"]]]], finish: "tool_calls", request: prepared)
            let item = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first)
            XCTAssertEqual(item["name"] as? String, tool.name)
            XCTAssertEqual(item["namespace"] as? String, tool.namespace)
        }
        XCTAssertThrowsError(try request(["tools": definitions + [definitions[0]]], toolNaming: .semantic)) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
        }
    }
    func testSemanticNamingColdReasoningAndCompletedHistoryRejectDifferentOrLegacyStyles() throws {
        let initial = try request(toolNaming: .semantic)
        let readAlias = try XCTUnwrap(initial.tools.first?.wireName)
        let reply = try decode(["role": "assistant", "reasoning": "Private continuation keeps " + readAlias, "tool_calls": [
            ["id": "read-semantically", "type": "function", "function": ["name": readAlias, "arguments": "{\"path\":\"fixture\"}"]]
        ]], finish: "tool_calls", request: initial)
        let encoded = try JSONSerialization.data(withJSONObject: XCTUnwrap(reply.response["output"] as? [[String: Any]]))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Private continuation"))
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let history: [[String: Any]] = [["role": "user", "content": "Read fixture"]] + restored + [
            ["type": "function_call_output", "call_id": "read-semantically", "output": "Fixture contents"],
            ["role": "user", "content": "Continue"],
        ]
        let raw: [String: Any] = ["model": initial.localModelID, "input": history, "tools": Array(tools.reversed()), "store": false]
        let coldCapsules = try APIReasoningCapsules(key: Data(repeating: 7, count: 32))
        let cold = try APIModelResponseCodec.prepare(JSONSerialization.data(withJSONObject: raw), selection: .init(provider: provider, model: provider.models[0]), threadID: taskID, capsules: coldCapsules, toolNaming: .semantic)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: cold.body) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["reasoning"] as? String }, ["Private continuation keeps " + readAlias])
        let call = try XCTUnwrap(messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.first?.first)
        XCTAssertEqual((call["function"] as? [String: Any])?["name"] as? String, readAlias)
        XCTAssertEqual(call["id"] as? String, "read-semantically")
        XCTAssertEqual(messages.compactMap { $0["tool_call_id"] as? String }, ["read-semantically"])
        let id = try XCTUnwrap(restored.first?["id"] as? String)
        let encrypted = try XCTUnwrap(restored.first?["encrypted_content"] as? String)
        let payload = try coldCapsules.open(encrypted, itemID: id, providerID: provider.id, modelID: provider.models[0].id, baseURL: provider.baseURL, threadID: taskID)
        XCTAssertEqual(payload.toolNaming, APIModelResponseCodec.ToolNaming.semantic.rawValue)
        XCTAssertThrowsError(try request(["input": history])) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidReasoning) }
        for style in [nil, APIModelResponseCodec.ToolNaming.legacy.rawValue, "unknown_style"] {
            let oldCapsule = try coldCapsules.seal(.init(reasoning: "Original thinking retains computa_tool_0", callIDs: ["read-semantically"], responseID: "old-response", toolNaming: style), itemID: id,
                                                  providerID: provider.id, modelID: provider.models[0].id, baseURL: provider.baseURL, threadID: taskID)
            var changed = history
            changed[1]["encrypted_content"] = oldCapsule
            XCTAssertThrowsError(try request(["input": changed], toolNaming: .semantic)) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidReasoning) }
            if style == "unknown_style" {
                XCTAssertThrowsError(try request(["input": changed])) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidReasoning) }
            } else {
                let legacy = try request(["input": changed])
                let legacyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.body) as? [String: Any])
                let legacyMessages = try XCTUnwrap(legacyBody["messages"] as? [[String: Any]])
                XCTAssertEqual(legacyMessages.compactMap { $0["reasoning"] as? String }, ["Original thinking retains computa_tool_0"])
                XCTAssertEqual((legacyMessages.compactMap { $0["tool_calls"] as? [[String: Any]] }.first?.first?["function"] as? [String: Any])?["name"] as? String, "computa_tool_0")
            }
        }
        let legacyReply = try decode(["role": "assistant", "reasoning": "Legacy new capsule", "content": "done"])
        let legacyItem = try XCTUnwrap((legacyReply.response["output"] as? [[String: Any]])?.first)
        let legacyPayload = try coldCapsules.open(XCTUnwrap(legacyItem["encrypted_content"] as? String), itemID: XCTUnwrap(legacyItem["id"] as? String), providerID: provider.id, modelID: provider.models[0].id, baseURL: provider.baseURL, threadID: taskID)
        XCTAssertEqual(legacyPayload.toolNaming, APIModelResponseCodec.ToolNaming.legacy.rawValue)
    }
    func testSemanticStyleLeavesNativeResponsesNamesDescriptionsAndOpaqueContinuationUnchanged() throws {
        let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: .responses, models: provider.models)
        let prepared = try request(provider: p, toolNaming: .semantic)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(body["tools"] as? NSArray, tools as NSArray)
        let remote: [[String: Any]] = [["id": "opaque", "type": "reasoning", "summary": [], "encrypted_content": "OPAQUE_NATIVE"],
            ["id": "call-item", "type": "function_call", "status": "completed", "call_id": "read", "namespace": "files", "name": "read", "arguments": "{\"path\":\"fixture\"}"]]
        let data = try JSONSerialization.data(withJSONObject: ["id": "response", "object": "response", "status": "completed", "model": "fixture-model", "output": remote])
        let reply = try APIModelResponseCodec.decode(.init(body: data, contentType: "application/json"), request: prepared)
        let items = try XCTUnwrap(reply.response["output"] as? [[String: Any]])
        let next = try request(["input": items + [["type": "function_call_output", "call_id": "read", "output": "fixture"]]], provider: p, toolNaming: .semantic)
        let nextBody = try XCTUnwrap(JSONSerialization.jsonObject(with: next.body) as? [String: Any])
        XCTAssertEqual(nextBody["tools"] as? NSArray, tools as NSArray)
        let nextInput = try XCTUnwrap(nextBody["input"] as? [[String: Any]])
        XCTAssertEqual(nextInput.first?["encrypted_content"] as? String, "OPAQUE_NATIVE")
        XCTAssertEqual(nextInput[1]["name"] as? String, "read")
        XCTAssertEqual(nextInput[1]["namespace"] as? String, "files")
    }
    func testChatToolDescriptionsIdentifyCurrentAndFilteredBrowserAliasesWithoutChangingSchemas() throws {
        let browser: [String: Any] = ["type": "function", "name": "browser_open", "description": "Create one task-owned browser tab.",
            "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"], "additionalProperties": false]]
        let expectedParameters: [String: Any] = ["type": "object", "properties": ["url": ["type": "string", "minLength": 1]],
                                               "required": ["url"], "additionalProperties": false]
        let chrome: [String: Any] = ["type": "function", "name": "computer_v2_tabs", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        for (definitions, alias) in [([browser], "computa_tool_0"), ([chrome, browser], "computa_tool_1")] {
            let prepared = try request(["instructions": "Use browser_open for the requested page.",
                                        "tools": [["type": "namespace", "name": "functions", "tools": definitions]]])
            let emitted = try wireFunctions(prepared)
            XCTAssertEqual(emitted.count, 1)
            let tool = try XCTUnwrap(emitted.first)
            XCTAssertEqual(tool["name"] as? String, alias)
            let description = try XCTUnwrap(tool["description"] as? String)
            XCTAssertTrue(description.hasPrefix("Native tool: functions.browser_open.\n"))
            XCTAssertTrue(description.contains("Native namespace: functions; native name: browser_open."))
            XCTAssertTrue(description.contains("Callable API function: \(alias).\n"))
            XCTAssertTrue(description.hasSuffix("Create one task-owned browser tab."))
            XCTAssertFalse(description.contains("computer_v2_tabs"))
            XCTAssertEqual(tool["parameters"] as? NSDictionary, expectedParameters as NSDictionary,
                           "The current URL constraint is restored without rewriting the declared fields")
            XCTAssertEqual(prepared.tools.first?.description, browser["description"] as? String)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            XCTAssertEqual((body["messages"] as? [[String: Any]])?.first?["content"] as? String,
                           "Use browser_open for the requested page.")
            for returnedName in ["browser_open", "functions.browser_open", "computa_tool_2"] {
                XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "unoffered", "type": "function", "function": ["name": returnedName, "arguments": "{\"url\":\"http://127.0.0.1/inbox\"}"]]]], finish: "tool_calls", request: prepared)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
                }
            }
            let result = try decode(["role": "assistant", "tool_calls": [["id": "open", "type": "function", "function": ["name": alias, "arguments": "{\"url\":\"http://127.0.0.1/inbox\"}"]]]], finish: "tool_calls", request: prepared)
            let output = try XCTUnwrap((result.response["output"] as? [[String: Any]])?.first)
            XCTAssertEqual(output["name"] as? String, "browser_open")
            XCTAssertEqual(output["namespace"] as? String, "functions")
            XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "bad", "type": "function", "function": ["name": alias, "arguments": "{\"url\":false}"]]]], finish: "tool_calls", request: prepared)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
        }
    }
    func testChatToolDescriptionsDisambiguateSameLeafNamespacesAndBoundOnlyAddedIdentity() throws {
        let definitions: [[String: Any]] = [
            ["type": "namespace", "name": "files", "tools": [function]],
            ["type": "namespace", "name": "records", "tools": [function]],
        ]
        let prepared = try request(["tools": definitions])
        let emitted = try wireFunctions(prepared)
        XCTAssertEqual(emitted.count, 2)
        for (index, namespace) in ["files", "records"].enumerated() {
            let description = try XCTUnwrap(emitted[index]["description"] as? String)
            XCTAssertTrue(description.hasPrefix("Native tool: \(namespace).read.\n"))
            XCTAssertTrue(description.contains("Native namespace: \(namespace); native name: read."))
            XCTAssertTrue(description.contains("Callable API function: computa_tool_\(index).\n"))
            XCTAssertTrue(description.hasSuffix("Read a file"))
            let reply = try decode(["role": "assistant", "tool_calls": [["id": "read-\(index)", "type": "function", "function": ["name": "computa_tool_\(index)", "arguments": "{\"path\":\"fixture\"}"]]]], finish: "tool_calls", request: prepared)
            XCTAssertEqual((reply.response["output"] as? [[String: Any]])?.first?["namespace"] as? String, namespace)
        }
        var boundary = function
        boundary["name"] = String(repeating: "n", count: 128)
        boundary["description"] = String(repeating: "d", count: 64_000)
        let bounded = try request(["tools": [["type": "namespace", "name": String(repeating: "s", count: 128), "tools": [boundary]]]])
        let description = try XCTUnwrap(wireFunctions(bounded).first?["description"] as? String)
        XCTAssertTrue(description.hasSuffix(String(repeating: "d", count: 64_000)))
        XCTAssertLessThanOrEqual(description.utf8.count, 65_024)
        boundary["description"] = String(repeating: "d", count: 64_001)
        XCTAssertThrowsError(try request(["tools": [boundary]])) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool) }
        let responses = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: .responses, models: provider.models)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request(["tools": definitions], provider: responses).body) as? [String: Any])
        XCTAssertEqual(body["tools"] as? NSArray, definitions as NSArray)
    }
    func testChatToolIdentityDescriptionsPreserveColdReasoningAndFilteredCompletedHistory() throws {
        let chrome: [String: Any] = ["type": "function", "name": "computer_v2_tabs", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        let browser: [String: Any] = ["type": "function", "name": "browser_tabs", "description": "List built-in tabs.", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        let definitions: [[String: Any]] = [["type": "namespace", "name": "functions", "tools": [chrome, browser]]]
        let oldHistory: [[String: Any]] = [
            ["role": "user", "content": "Previous controlled request"],
            ["type": "function_call", "call_id": "old_chrome", "name": "computer_v2_tabs", "namespace": "functions", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "old_chrome", "output": "Old completion retained"],
            ["role": "user", "content": "Use browser_tabs now"],
        ]
        let initial = try request(["tools": definitions, "input": oldHistory])
        let thinking = "Private fixture continuation names computa_tool_1."
        let reply = try decode(["role": "assistant", "reasoning": thinking, "tool_calls": [["id": "built_in", "type": "function", "function": ["name": "computa_tool_1", "arguments": "{}"]]]], finish: "tool_calls", request: initial)
        let items = try XCTUnwrap(reply.response["output"] as? [[String: Any]])
        let retainedData = try JSONSerialization.data(withJSONObject: items)
        XCTAssertFalse(String(decoding: retainedData, as: UTF8.self).contains(thinking))
        let restoredItems = try XCTUnwrap(JSONSerialization.jsonObject(with: retainedData) as? [[String: Any]])
        let input = oldHistory + restoredItems + [["type": "function_call_output", "call_id": "built_in", "output": "Fixture tabs"], ["role": "user", "content": "Continue"]]
        let raw: [String: Any] = ["model": initial.localModelID, "instructions": "Use browser_tabs.", "input": input, "tools": definitions, "stream": true, "store": false]
        let cold = try APIModelResponseCodec.prepare(JSONSerialization.data(withJSONObject: raw), selection: .init(provider: provider, model: provider.models[0]), threadID: taskID,
                                                    capsules: APIReasoningCapsules(key: Data(repeating: 7, count: 32)))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: cold.body) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let calls = messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }
        XCTAssertEqual(calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, ["computa_tool_0", "computa_tool_1"])
        XCTAssertEqual(calls.compactMap { $0["id"] as? String }, ["old_chrome", "built_in"])
        XCTAssertEqual(messages.compactMap { $0["tool_call_id"] as? String }, ["old_chrome", "built_in"])
        XCTAssertEqual(messages.compactMap { $0["reasoning"] as? String }, [thinking])
        XCTAssertEqual(cold.allowedTools, ["computa_tool_1"])
        let emitted = try wireFunctions(cold)
        XCTAssertEqual(emitted.count, 1)
        let description = try XCTUnwrap(emitted.first?["description"] as? String)
        XCTAssertTrue(description.hasPrefix("Native tool: functions.browser_tabs.\n"))
        XCTAssertTrue(description.contains("Callable API function: computa_tool_1."))
        XCTAssertFalse(description.contains("computa_tool_0"))
        XCTAssertEqual(emitted as NSArray, try wireFunctions(initial) as NSArray)
        for alias in ["computa_tool_0", "browser_tabs", "functions.browser_tabs"] {
            XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "new_call", "type": "function", "function": ["name": alias, "arguments": "{}"]]]], finish: "tool_calls", request: cold)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool)
            }
        }
    }
    func testResumedChromeHistoryIsPreservedButNotOfferedOrCallable() throws {
        let chrome: [String: Any] = ["type": "function", "name": "computer_v2_tabs", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        let builtin: [String: Any] = ["type": "function", "name": "browser_tabs", "parameters": ["type": "object", "properties": ["cursor": ["type": "string"]], "additionalProperties": false]]
        let history: [[String: Any]] = [
            ["type": "message", "role": "user", "content": "Previous synthetic browser request"],
            ["type": "function_call", "call_id": "historical_chrome", "name": "computer_v2_tabs", "namespace": "functions", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "historical_chrome", "output": "Chrome was unavailable; no read dispatched"],
            ["type": "function_call", "call_id": "historical_builtin", "name": "browser_tabs", "namespace": "functions", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "historical_builtin", "output": "Synthetic built-in inventory"],
            ["type": "message", "role": "user", "content": "Use the built-in browser now"],
        ]
        let prepared = try request(["tools": [["type": "namespace", "name": "functions", "tools": [chrome, builtin]]], "input": history])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let active = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(active.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }.count, 1)
        XCTAssertEqual(prepared.tools.map(\.name), ["browser_tabs"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let old = try XCTUnwrap(messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.first?.first)
        let oldName = try XCTUnwrap((old["function"] as? [String: Any])?["name"] as? String)
        XCTAssertEqual(oldName, "computa_tool_0")
        XCTAssertEqual(prepared.tools.first?.wireName, "computa_tool_1")
        let builtinHistory = messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }
            .first { $0["id"] as? String == "historical_builtin" }
        XCTAssertEqual((builtinHistory?["function"] as? [String: Any])?["name"] as? String, "computa_tool_1")
        XCTAssertTrue(messages.contains { $0["content"] as? String == "Chrome was unavailable; no read dispatched" })
        XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "new_chrome", "type": "function", "function": ["name": oldName, "arguments": "{}"]]]], finish: "tool_calls", request: prepared))
        XCTAssertThrowsError(try request(["tools": [chrome], "tool_choice": ["type": "function", "name": "computer_v2_tabs"]]))
    }

    func testResponsesProviderAlsoHidesRetainedChromeDefinitionsWithoutRewritingHistory() throws {
        let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
                                      wireAPI: .responses, models: provider.models)
        let chrome: [String: Any] = ["type": "function", "name": "computer_v2_tabs", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        let builtin: [String: Any] = ["type": "function", "name": "browser_read", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        let history: [[String: Any]] = [["type": "function_call", "call_id": "historical", "name": "computer_v2_tabs", "arguments": "{}"], ["type": "function_call_output", "call_id": "historical", "output": "not connected"]]
        let prepared = try request(["tools": [chrome, builtin], "input": history], provider: p)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["browser_read"])
        XCTAssertEqual((body["input"] as? [[String: Any]])?.first?["name"] as? String, "computer_v2_tabs")
        XCTAssertEqual(prepared.tools.map(\.name), ["browser_read"])
    }

    func testStructuredRolesNamespacesAndCustomToolsRoundTripWithoutWebsiteEnvelope() throws {
        let prepared = try request(["input": [["role": "developer", "content": [["type": "input_text", "text": "Developer instructions"]]], ["role": "user", "content": "Use tools"]]])
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let messages = try XCTUnwrap(wire["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "developer", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, "Use the native tools.")
        XCTAssertFalse(String(decoding: prepared.body, as: UTF8.self).contains("COMPUTA"))
        let reply = try decode(["role": "assistant", "content": NSNull(), "tool_calls": [
            ["id": "call-read", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":\"/tmp/a\"}"]],
            ["id": "call-patch", "type": "function", "function": ["name": "computa_tool_1", "arguments": "{\"input\":\"*** Begin Patch\\n*** End Patch\"}"]]
        ]], finish: "tool_calls", request: prepared)
        let items = try XCTUnwrap(reply.response["output"] as? [[String: Any]])
        XCTAssertEqual(items[0]["namespace"] as? String, "files"); XCTAssertEqual(items[0]["name"] as? String, "read")
        XCTAssertEqual(items[1]["type"] as? String, "custom_tool_call")
        XCTAssertEqual(items[1]["input"] as? String, "*** Begin Patch\n*** End Patch")
        let next = try request(["input": [["role": "user", "content": "Use tools"]] + items + [
            ["type": "function_call_output", "call_id": "call-read", "output": "contents"],
            ["type": "custom_tool_call_output", "call_id": "call-patch", "output": [["type": "input_text", "text": "ok"]]]
        ]])
        let nextWire = try XCTUnwrap(JSONSerialization.jsonObject(with: next.body) as? [String: Any])
        let nextMessages = try XCTUnwrap(nextWire["messages"] as? [[String: Any]])
        XCTAssertEqual(nextMessages.compactMap { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool"])
        XCTAssertEqual((nextMessages[2]["tool_calls"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(nextMessages[3]["tool_call_id"] as? String, "call-read")
        XCTAssertEqual(nextMessages[4]["tool_call_id"] as? String, "call-patch")
    }
    func testToolArgumentsUnknownNamesDuplicateIDsAndIncompleteRepliesNeverProduceCalls() throws {
        for call in [
            ["id": "a", "type": "function", "function": ["name": "unoffered", "arguments": "{}"]],
            ["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":true}"]],
            ["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":\"ok\",\"extra\":1}"]],
            ["id": "a", "type": "function", "function": ["name": "computa_tool_1", "arguments": "{\"input\":\"x\",\"command\":\"bad\"}"]]
        ] { XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [call]], finish: "tool_calls")) }
        let call: [String: Any] = ["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":\"ok\"}"]]
        XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [call, call]], finish: "tool_calls"))
        XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [call]], finish: "length"))
        XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [call]], finish: "tool_calls", request: request(["tool_choice": "none"])))
        XCTAssertThrowsError(try decode(["role": "assistant", "content": "done"], request: request(["tool_choice": "required"])))
        XCTAssertThrowsError(try decode(["role": "assistant", "content": "done"], model: "different-model"))
    }
    func testCustomGrammarContractSurvivesFunctionWrappingAndNativeResponsesRemainUnchanged() throws {
        // The pinned engine's apply_patch custom format defines these sentinels;
        // its short description alone does not provide them to the model.
        let grammar = #"""
        start: begin_patch hunk+ end_patch
        begin_patch: "*** Begin Patch" LF
        end_patch: "*** End Patch" LF?
        hunk: "*** Add File: " /(.+)/ LF ("+" /(.*)/ LF)+
        %import common.LF
        """#
        let original = "This is a FREEFORM tool, so do not wrap the patch in JSON."
        let patch: [String: Any] = ["type": "custom", "name": "apply_patch", "description": original,
                                    "format": ["type": "grammar", "syntax": "lark", "definition": grammar]]
        let regex: [String: Any] = ["type": "custom", "name": "version_text", "format": ["type": "grammar", "syntax": "regex", "definition": #"v[0-9]+\.[0-9]+"#]]
        let nativeTools: [[String: Any]] = [["type": "namespace", "name": "editing", "tools": [patch]], regex]
        let prepared = try request(["tools": nativeTools])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let wireTools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let wrapped = try XCTUnwrap(wireTools[0]["function"] as? [String: Any])
        let description = try XCTUnwrap(wrapped["description"] as? String)
        XCTAssertTrue(description.hasPrefix("Native tool: editing.apply_patch.\n"))
        XCTAssertTrue(description.contains("Callable API function: computa_tool_0.\n"))
        XCTAssertTrue(description.hasSuffix(prepared.tools[0].description))
        XCTAssertTrue(prepared.tools[0].description.hasPrefix(original))
        XCTAssertTrue(description.hasSuffix(grammar))
        XCTAssertTrue(description.contains("decoded input string is passed unchanged"))
        XCTAssertTrue(description.contains("transport wrapper")); XCTAssertTrue(description.contains("native lark grammar"))
        XCTAssertTrue(((wireTools[1]["function"] as? [String: Any])?["description"] as? String ?? "").contains(#"v[0-9]+\.[0-9]+"#))
        let payload = "*** Begin Patch\n*** Add File: sample.txt\n+verbatim 🙂\n*** End Patch\n"
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["input": payload]), as: UTF8.self)
        let reply = try decode(["role": "assistant", "tool_calls": [["id": "patch-grammar", "type": "function", "function": ["name": "computa_tool_0", "arguments": arguments]]]], finish: "tool_calls", request: prepared)
        let output = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first)
        XCTAssertEqual(output["type"] as? String, "custom_tool_call"); XCTAssertEqual(output["namespace"] as? String, "editing")
        XCTAssertEqual(output["name"] as? String, "apply_patch"); XCTAssertEqual(output["input"] as? String, payload)
        let responses = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: .responses, models: provider.models)
        let nativeBody = try XCTUnwrap(JSONSerialization.jsonObject(with: request(["tools": nativeTools], provider: responses).body) as? [String: Any])
        XCTAssertEqual(nativeBody["tools"] as? NSArray, nativeTools as NSArray)
        let semantic = try request(["tools": nativeTools], toolNaming: .semantic)
        let semanticFunction = try XCTUnwrap(wireFunctions(semantic).first)
        let semanticDescription = try XCTUnwrap(semanticFunction["description"] as? String)
        let semanticAlias = try XCTUnwrap(semanticFunction["name"] as? String)
        XCTAssertTrue(semanticAlias.hasPrefix("apply_patch__"))
        XCTAssertTrue(semanticDescription.hasSuffix(prepared.tools[0].description))
        XCTAssertTrue(semanticDescription.hasSuffix(grammar))
        XCTAssertEqual(semanticFunction["parameters"] as? NSDictionary, wrapped["parameters"] as? NSDictionary)
        let semanticReply = try decode(["role": "assistant", "tool_calls": [["id": "semantic-patch", "type": "function", "function": ["name": semanticAlias, "arguments": arguments]]]], finish: "tool_calls", request: semantic)
        let semanticOutput = try XCTUnwrap((semanticReply.response["output"] as? [[String: Any]])?.first)
        XCTAssertEqual(semanticOutput["namespace"] as? String, "editing")
        XCTAssertEqual(semanticOutput["input"] as? String, payload)
    }
    func testCustomInputArgumentGuidancePreservesRawStringsAndNativeFunctionSchemas() throws {
        let ordinaryParameters: [String: Any] = ["type": "object", "properties": ["input": ["type": "string", "description": "Native function's own input contract"]], "required": ["input"], "additionalProperties": false]
        let custom: [String: Any] = ["type": "custom", "name": "literal_document", "format": ["type": "text"]]
        let ordinary: [String: Any] = ["type": "function", "name": "inspect_document", "parameters": ordinaryParameters]
        let definitions = [custom, ordinary]
        // Even JSON-shaped and patch-shaped strings stay literal; this descriptive
        // metadata does not parse, fix, double-encode or loosen custom input.
        let payloads = ["line one\nquote: \"hello\"; slash: \\; 🌍\n", "{\"native_text\":true}", "*** Begin Patch: wrong.txt\n*** End Patch\n*** End Patch"]
        for naming in [APIModelResponseCodec.ToolNaming.legacy, .semantic] {
            let prepared = try request(["tools": definitions], toolNaming: naming)
            let functions = try wireFunctions(prepared)
            let parameters = try XCTUnwrap(functions[0]["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
            let input = try XCTUnwrap(properties["input"] as? [String: Any])
            XCTAssertEqual(Set(parameters.keys), ["type", "properties", "required", "additionalProperties"])
            XCTAssertEqual(Set(properties.keys), ["input"])
            XCTAssertEqual(input["type"] as? String, "string")
            XCTAssertEqual(parameters["required"] as? [String], ["input"])
            XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
            let description = try XCTUnwrap(input["description"] as? String)
            XCTAssertTrue(description.contains("exact text or grammar contract"))
            XCTAssertTrue(description.contains("delimiters and newlines"))
            XCTAssertTrue(description.contains("Encode the contents once as this JSON string"))
            XCTAssertFalse(description.contains("apply_patch"), "This is the generic custom-tool transport, not a patch-only schema.")
            XCTAssertLessThan(description.utf8.count, 320)
            XCTAssertEqual(functions[1]["parameters"] as? NSDictionary, ordinaryParameters as NSDictionary)
            let alias = try XCTUnwrap(functions[0]["name"] as? String)
            for (index, payload) in payloads.enumerated() {
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["input": payload]), as: UTF8.self)
                let reply = try decode(["role": "assistant", "tool_calls": [["id": "literal-\(index)", "type": "function", "function": ["name": alias, "arguments": arguments]]]], finish: "tool_calls", request: prepared)
                let output = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first)
                XCTAssertEqual(output["type"] as? String, "custom_tool_call")
                XCTAssertEqual(output["name"] as? String, "literal_document")
                XCTAssertEqual(output["input"] as? String, payload)
            }
            for invalid: [String: Any] in [["input": ["nested": "object"]], ["input": "literal", "extra": true]] {
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)
                XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "invalid", "type": "function", "function": ["name": alias, "arguments": arguments]]]], finish: "tool_calls", request: prepared)) {
                    XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
                }
            }
        }
        let responses = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: .responses, models: provider.models)
        let nativeBody = try XCTUnwrap(JSONSerialization.jsonObject(with: request(["tools": definitions], provider: responses).body) as? [String: Any])
        XCTAssertEqual(nativeBody["tools"] as? NSArray, definitions as NSArray)
    }
    func testCustomFormatValidationRejectsUnknownMalformedAndOversizedContracts() throws {
        func tool(_ format: Any?) -> [String: Any] {
            var value: [String: Any] = ["type": "custom", "name": "text_tool"]
            if let format { value["format"] = format }; return value
        }
        for format: Any? in [nil, ["type": "text"]] {
            let prepared = try request(["tools": [tool(format)]])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            let function = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
            XCTAssertTrue((function["description"] as? String ?? "").contains("native tool accepts raw text"))
        }
        let invalid: [Any] = [NSNull(), "text", ["type": "unknown"], ["type": "text", "definition": "ignored"],
            ["type": "grammar", "syntax": "lark"], ["type": "grammar", "syntax": "unknown", "definition": "start: /.+/"],
            ["type": "grammar", "syntax": "lark", "definition": 42], ["type": "grammar", "syntax": "lark", "definition": " \n "],
            ["type": "grammar", "syntax": "lark", "definition": "start: /.+/", "ignored": true],
            ["type": "grammar", "syntax": "regex", "definition": String(repeating: "🙂", count: 4_097)]]
        for format in invalid {
            XCTAssertThrowsError(try request(["tools": [tool(format)]])) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool) }
        }
        let boundary = ["type": "grammar", "syntax": "regex", "definition": String(repeating: "a", count: 16_384)]
        XCTAssertNoThrow(try request(["tools": [tool(boundary)]]))
        var oversized = tool(boundary); oversized["description"] = String(repeating: "a", count: 64_000)
        XCTAssertThrowsError(try request(["tools": [oversized]])) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool) }
    }
    func testReasoningCapsuleRoundTripsAcrossCodecRecreationAndRejectsDifferentBindings() throws {
        let reply = try decode(["role": "assistant", "content": NSNull(), "reasoning": "PRIVATE_REASONING", "tool_calls": [["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":\"ok\"}"]]]], finish: "tool_calls")
        let items = try XCTUnwrap(reply.response["output"] as? [[String: Any]])
        XCTAssertEqual(items[0]["type"] as? String, "reasoning")
        XCTAssertEqual((items[0]["summary"] as? [Any])?.count, 0)
        let encoded = try APIModelResponseCodec.encode(reply, stream: true)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE_REASONING"))
        let next = try request(["input": [["role": "user", "content": "read"]] + items + [["type": "function_call_output", "call_id": "a", "output": "contents"]]])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: next.body) as? [String: Any])
        XCTAssertEqual((body["messages"] as? [[String: Any]])?[2]["reasoning"] as? String, "PRIVATE_REASONING")
        let id = try XCTUnwrap(items[0]["id"] as? String), encrypted = try XCTUnwrap(items[0]["encrypted_content"] as? String)
        let recreated = try APIReasoningCapsules(key: Data(repeating: 7, count: 32))
        XCTAssertEqual(try recreated.open(encrypted, itemID: id, providerID: provider.id, modelID: provider.models[0].id, baseURL: provider.baseURL, threadID: taskID).reasoning, "PRIVATE_REASONING")
        for (p, m, u, t) in [("other", "fixture-model", provider.baseURL, taskID), (provider.id, "other", provider.baseURL, taskID), (provider.id, "fixture-model", URL(string: "https://different.invalid/v1")!, taskID), (provider.id, "fixture-model", provider.baseURL, UUID().uuidString)] {
            XCTAssertThrowsError(try recreated.open(encrypted, itemID: id, providerID: p, modelID: m, baseURL: u, threadID: t))
        }
        XCTAssertThrowsError(try APIReasoningCapsules(key: Data(repeating: 8, count: 32)).open(encrypted, itemID: id, providerID: provider.id, modelID: provider.models[0].id, baseURL: provider.baseURL, threadID: taskID))
        XCTAssertThrowsError(try recreated.open(String(encrypted.dropLast(4)) + "AAAA", itemID: id, providerID: provider.id, modelID: provider.models[0].id, baseURL: provider.baseURL, threadID: taskID))
        XCTAssertThrowsError(try APIReasoningCapsules(key: Data()))
    }
    func testActualSSEDeltasAndInterleavedToolsRetainIDsUsageAndReasoning() throws {
        let chunks: [[String: Any]] = [
            ["choices": [["index": 0, "delta": ["role": "assistant", "reasoning": "private "], "finish_reason": NSNull()]]],
            ["choices": [["index": 0, "delta": ["reasoning": "thinking", "content": "I "], "finish_reason": NSNull()]]],
            ["choices": [["index": 0, "delta": ["content": "will read", "tool_calls": [["index": 0, "id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":"]]]], "finish_reason": NSNull()]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"ok\"}"]]]], "finish_reason": NSNull()]]],
            ["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]],
            ["choices": [], "usage": ["prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30]]
        ]
        var wire = Data()
        for chunk in chunks {
            var object = chunk; object["id"] = "remote-stream"; object["model"] = "fixture-model"
            wire.append(Data("data: ".utf8)); wire.append(try JSONSerialization.data(withJSONObject: object)); wire.append(Data("\n\n".utf8))
        }
        let incomplete = wire; wire.append(Data("data: [DONE]\n\n".utf8))
        let reply = try APIModelResponseCodec.decode(.init(body: wire, contentType: "text/event-stream"), request: request())
        XCTAssertEqual(reply.textDeltas, ["I ", "will read"])
        XCTAssertEqual(reply.argumentDeltas, [["{\"path\":", "\"ok\"}"]])
        XCTAssertEqual((reply.response["usage"] as? [String: Any])?["total_tokens"] as? Int, 30)
        let encoded = String(decoding: try APIModelResponseCodec.encode(reply, stream: true), as: UTF8.self)
        XCTAssertTrue(encoded.contains("response.function_call_arguments.delta")); XCTAssertTrue(encoded.contains("response.completed"))
        XCTAssertFalse(encoded.contains("private thinking"))
        XCTAssertThrowsError(try APIModelResponseCodec.decode(.init(body: incomplete, contentType: "text/event-stream"), request: request()))
    }
    func testSchemaValidCommandWithShellSyntaxErrorRemainsVerbatim() throws {
        let command = #"sed -n '1,200p' "/fixture/helper.py"}"#
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["cmd": command], options: [.sortedKeys]), as: UTF8.self)
        let prepared = try request(["tools": [["type": "function", "name": "exec_fixture", "parameters": [
            "type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]]]])
        let reply = try decode(["role": "assistant", "tool_calls": [["id": "literal-command", "type": "function",
            "function": ["name": "computa_tool_0", "arguments": arguments]]]], finish: "tool_calls", request: prepared)
        let item = try XCTUnwrap((reply.response["output"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["arguments"] as? String, arguments)
        let encoded = String(decoding: try APIModelResponseCodec.encode(reply, stream: true), as: UTF8.self)
        let events = try encoded.components(separatedBy: "\n\n").compactMap { event -> [String: Any]? in
            guard let line = event.components(separatedBy: "\n").first(where: { $0.hasPrefix("data: ") }) else { return nil }
            let payload = String(line.dropFirst(6)); if payload == "[DONE]" { return nil }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        }
        XCTAssertEqual(events.filter { $0["type"] as? String == "response.function_call_arguments.delta" }
            .compactMap { $0["delta"] as? String }.joined(), arguments)
        let done = try XCTUnwrap(events.first { $0["type"] as? String == "response.function_call_arguments.done" })
        XCTAssertEqual(done["arguments"] as? String, arguments)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["cmd"] as? String, command, "Schema validation does not repair or reinterpret shell strings")
    }
    func testFinalTextBoundaryPreservesJSONEscapesAndEmitsOnlyFiniteMetadata() throws {
        let expected = "RAW-RESPONSE\u{2011}SENTINEL e\u{301}\n"
        let prepared = try request(["input": [["role": "user", "content": "PRIVATE_REQUEST_SENTINEL"]]])
        let envelope: [String: Any] = ["model": "fixture-model", "choices": [["index": 0,
            "message": ["role": "assistant", "content": expected, "reasoning": "PRIVATE_REASONING_SENTINEL"], "finish_reason": "stop"]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            .replacingOccurrences(of: "\u{2011}", with: "\\u2011")
        let reply = try APIModelResponseCodec.decode(.init(body: Data(json.utf8), contentType: "application/json"), request: prepared)
        for stream in [false, true] {
            let encoded = try APIModelResponseCodec.encode(reply, stream: stream)
            let facts = try XCTUnwrap(APIModelResponseCodec.finalTextDiagnostic(reply, encoded: encoded, stream: stream))
            XCTAssertEqual(facts.kind, "api_final_text_v1")
            XCTAssertEqual(facts.responseID, reply.response["id"] as? String)
            XCTAssertEqual(facts.modelID, prepared.localModelID); XCTAssertEqual(facts.providerID, "fixture")
            XCTAssertEqual(facts.upstream, facts.decoded); XCTAssertEqual(facts.decoded, facts.serialized)
            XCTAssertEqual(facts.upstream.utf8Bytes, expected.utf8.count)
            XCTAssertEqual(facts.upstream.unicodeScalars, expected.unicodeScalars.count)
            XCTAssertEqual(facts.upstream.hyphenMinusCount, 1); XCTAssertEqual(facts.upstream.nonBreakingHyphenCount, 1)
            XCTAssertTrue(facts.upstreamMatchesDecoded); XCTAssertTrue(facts.decodedMatchesSerialized)
            XCTAssertEqual(facts.streamDeltasMatchSerialized, stream ? true : nil)
            XCTAssertEqual(facts.completedMatchesSerialized, stream ? true : nil)
            let data = try JSONEncoder().encode(facts), log = String(decoding: data, as: UTF8.self)
            XCTAssertLessThanOrEqual(data.count, 2_048)
            for forbidden in ["RAW-RESPONSE", "SENTINEL", "PRIVATE_REQUEST", "PRIVATE_REASONING", "encrypted_content", "textDeltas", "reasoning", "remote1"] {
                XCTAssertFalse(log.contains(forbidden))
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["kind", "responseID", "modelID", "providerID", "upstream", "decoded", "serialized",
                "upstreamMatchesDecoded", "decodedMatchesSerialized"] + (stream ? ["streamDeltasMatchSerialized", "completedMatchesSerialized"] : [])))
            for field in ["upstream", "decoded", "serialized"] {
                let shape = try XCTUnwrap(object[field] as? [String: Any])
                XCTAssertEqual(Set(shape.keys), ["utf8Bytes", "unicodeScalars", "hyphenMinusCount", "nonBreakingHyphenCount"])
            }
        }
    }
    func testFinalTextBoundaryChecksActualSSEMessageBytesAgainstSourceAndDeltas() throws {
        let fragments = ["RAW-", "RESPONSE\u{2011}", "SENTINEL e\u{301}\n"]
        var wire = Data()
        for (index, text) in fragments.enumerated() {
            var delta: [String: Any] = ["content": text]
            if index == 0 { delta["role"] = "assistant"; delta["reasoning"] = "PRIVATE_REASONING_SENTINEL" }
            let row: [String: Any] = ["id": "remote-final", "model": "fixture-model", "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]]
            wire.append(Data("data: ".utf8)); wire.append(try JSONSerialization.data(withJSONObject: row)); wire.append(Data("\n\n".utf8))
        }
        let terminal: [String: Any] = ["id": "remote-final", "model": "fixture-model", "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]
        wire.append(Data("data: ".utf8)); wire.append(try JSONSerialization.data(withJSONObject: terminal)); wire.append(Data("\n\ndata: [DONE]\n\n".utf8))
        let reply = try APIModelResponseCodec.decode(.init(body: wire, contentType: "text/event-stream"), request: request())
        XCTAssertEqual(reply.textDeltas, fragments)
        let encoded = try APIModelResponseCodec.encode(reply, stream: true)
        let facts = try XCTUnwrap(APIModelResponseCodec.finalTextDiagnostic(reply, encoded: encoded, stream: true))
        XCTAssertEqual(facts.upstream.hyphenMinusCount, 1); XCTAssertEqual(facts.upstream.nonBreakingHyphenCount, 1)
        XCTAssertTrue(facts.decodedMatchesSerialized); XCTAssertEqual(facts.streamDeltasMatchSerialized, true)
        var changed = String(decoding: encoded, as: UTF8.self).components(separatedBy: "\n\n"), edits = 0
        for index in changed.indices where changed[index].hasPrefix("event: response.output_item.done\n") {
            let lines = changed[index].components(separatedBy: "\n")
            var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].dropFirst(6).utf8)) as? [String: Any])
            var item = try XCTUnwrap(row["item"] as? [String: Any])
            guard item["type"] as? String == "message" else { continue }
            var content = try XCTUnwrap(item["content"] as? [[String: Any]])
            content[0]["text"] = fragments.joined().replacingOccurrences(of: "-", with: "\u{2011}")
            item["content"] = content; row["item"] = item
            changed[index] = lines[0] + "\ndata: " + String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self); edits += 1
        }
        XCTAssertEqual(edits, 1)
        let mismatch = try XCTUnwrap(APIModelResponseCodec.finalTextDiagnostic(reply, encoded: Data(changed.joined(separator: "\n\n").utf8), stream: true))
        XCTAssertEqual(mismatch.serialized.hyphenMinusCount, 0); XCTAssertEqual(mismatch.serialized.nonBreakingHyphenCount, 2)
        XCTAssertTrue(mismatch.upstreamMatchesDecoded); XCTAssertFalse(mismatch.decodedMatchesSerialized)
        XCTAssertEqual(mismatch.streamDeltasMatchSerialized, false); XCTAssertEqual(mismatch.completedMatchesSerialized, false)
        XCTAssertEqual(reply.textDeltas, fragments)
    }
    func testFinalTextBoundaryOmitsToolsMalformedAndOverBudgetDiagnostics() throws {
        let tool = try decode(["role": "assistant", "content": "COMMENTARY_SENTINEL", "tool_calls": [["id": "read", "type": "function",
            "function": ["name": "computa_tool_0", "arguments": "{\"path\":\"fixture\"}"]]]], finish: "tool_calls")
        XCTAssertNil(APIModelResponseCodec.finalTextDiagnostic(tool, encoded: try APIModelResponseCodec.encode(tool, stream: true), stream: true))
        let final = try decode(["role": "assistant", "content": "exact-final"])
        for stream in [false, true] {
            XCTAssertNil(APIModelResponseCodec.finalTextDiagnostic(final, encoded: Data("invalid".utf8), stream: stream))
            XCTAssertNil(APIModelResponseCodec.finalTextDiagnostic(final, encoded: Data(repeating: 0, count: APIProviderHTTPClient.maximumResponseBytes + 1), stream: stream))
        }
        let largeText = String(repeating: "a", count: 2_000_001)
        let large = try decode(["role": "assistant", "content": largeText])
        XCTAssertEqual(large.response["output_text"] as? String, largeText)
        XCTAssertNil(APIModelResponseCodec.finalTextDiagnostic(large, encoded: try APIModelResponseCodec.encode(large, stream: false), stream: false))
    }
    func testImageContentAndUnsupportedModalityAreExplicit() throws {
        let input: [[String: Any]] = [["role": "user", "content": [["type": "input_text", "text": "inspect"], ["type": "input_image", "image_url": "data:image/png;base64,AA==", "detail": "original"]]]]
        let prepared = try request(["input": input])
        XCTAssertTrue(String(decoding: prepared.body, as: UTF8.self).contains("image_url"))
        let noImages = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: .chatCompletions, models: [.init(id: "fixture-model", name: "Fixture", supportsImages: false)])
        XCTAssertThrowsError(try request(["input": input], provider: noImages))
        XCTAssertThrowsError(try request(["input": [["role": "user", "content": [["type": "input_audio", "data": "AA=="]]]]]))
        XCTAssertThrowsError(try request(["previous_response_id": "remote"])); XCTAssertThrowsError(try request(["store": true]))
    }
    func testNativeResponsesAdapterValidatesOutputAndKeepsNamespace() throws {
        let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: .responses, models: provider.models)
        let prepared = try request(provider: p)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual(wire["stream"] as? Bool, false); XCTAssertEqual(wire["model"] as? String, "fixture-model")
        let data = try JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed", "model": "fixture-model", "output": [["id": "fc1", "type": "function_call", "status": "completed", "call_id": "c1", "name": "read", "namespace": "files", "arguments": "{\"path\":\"ok\"}"]]])
        let reply = try APIModelResponseCodec.decode(.init(body: data, contentType: "application/json"), request: prepared)
        XCTAssertEqual((reply.response["output"] as? [[String: Any]])?.first?["namespace"] as? String, "files")
    }
    func testMalformedHistoryCannotReassignOrReplayCallIdentifiers() throws {
        XCTAssertThrowsError(try request(["input": [["type": "function_call_output", "call_id": "unknown", "output": "ok"]]]))
        let call: [String: Any] = ["type": "function_call", "namespace": "files", "name": "read", "call_id": "old", "arguments": "{\"path\":\"ok\"}"]
        let prepared = try request(["input": [call, ["type": "function_call_output", "call_id": "old", "output": "ok"]]])
        XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "old", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":\"ok\"}"]]]], finish: "tool_calls", request: prepared))
        XCTAssertThrowsError(try request(["input": [call, ["type": "custom_tool_call_output", "call_id": "old", "output": "ok"]]]))
        XCTAssertThrowsError(try request(["input": [call]]))
    }
    func testNoToolsCompactionPreservesCompletedCallsResultsAndReasoningWithoutGrantingTools() throws {
        for naming in [APIModelResponseCodec.ToolNaming.legacy, .semantic] {
            let initial = try request(toolNaming: naming)
            let functions = try wireFunctions(initial)
            let arguments = "{\"path\":\"/tmp/synthetic fixture\",\"note\":\"literal\\nvalue\"}"
            // Use a schema-valid historical call, then retain its literal bytes.
            let readArguments = "{\"path\":\"/tmp/synthetic fixture\\nvalue\"}"
            let patch = "*** Begin Patch\n*** End Patch"
            let reply = try decode(["role": "assistant", "content": NSNull(), "reasoning": "Synthetic private continuation", "tool_calls": [
                ["id": "read-completed", "type": "function", "function": ["name": functions[0]["name"]!, "arguments": readArguments]],
                ["id": "patch-completed", "type": "function", "function": ["name": functions[1]["name"]!, "arguments": "{\"input\":\"*** Begin Patch\\n*** End Patch\"}"]]
            ]], finish: "tool_calls", request: initial)
            let output = try XCTUnwrap(reply.response["output"] as? [[String: Any]])
            let history: [[String: Any]] = [["role": "user", "content": "Complete the synthetic task"]] + output + [
                ["type": "function_call_output", "call_id": "read-completed", "output": "UNTRUSTED tool result remains a tool result"],
                ["type": "custom_tool_call_output", "call_id": "patch-completed", "output": "Synthetic patch receipt"],
                ["role": "user", "content": "Summarize the completed history"]
            ]
            let compact = try request(["tools": [], "input": history, "parallel_tool_calls": false], toolNaming: naming)
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: compact.body) as? [String: Any])
            XCTAssertNil(wire["tools"]); XCTAssertNil(wire["tool_choice"])
            XCTAssertTrue(compact.tools.isEmpty); XCTAssertTrue(compact.allowedTools.isEmpty)
            XCTAssertEqual(compact.historyCallIDs, ["read-completed", "patch-completed"])
            let messages = try XCTUnwrap(wire["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool", "user"])
            XCTAssertEqual(messages[2]["reasoning"] as? String, "Synthetic private continuation")
            let calls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
            XCTAssertEqual(calls.compactMap { $0["id"] as? String }, ["read-completed", "patch-completed"])
            let read = try XCTUnwrap(calls[0]["function"] as? [String: Any])
            XCTAssertEqual(read["arguments"] as? String, readArguments)
            let custom = try XCTUnwrap(calls[1]["function"] as? [String: Any])
            let customArguments = try XCTUnwrap(custom["arguments"] as? String)
            XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(customArguments.utf8)) as? [String: String])?["input"], patch)
            XCTAssertEqual(messages[3]["tool_call_id"] as? String, "read-completed")
            XCTAssertEqual(messages[3]["content"] as? String, "UNTRUSTED tool result remains a tool result")
            XCTAssertEqual(messages[4]["tool_call_id"] as? String, "patch-completed")
            XCTAssertNoThrow(try decode(["role": "assistant", "content": "Synthetic summary"], request: compact))
            XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [
                ["id": "new-call", "type": "function", "function": ["name": read["name"]!, "arguments": arguments]]
            ]], finish: "tool_calls", request: compact)) { XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidTool) }
            var changed = history
            changed[1]["encrypted_content"] = "unverified"
            XCTAssertThrowsError(try request(["tools": [], "input": changed], toolNaming: naming))
        }
    }

    func testNoToolsHistoryStillRejectsOrphansDuplicatesKindsInvalidNamesAndNonObjectArguments() throws {
        let call: [String: Any] = ["type": "function_call", "namespace": "files", "name": "read", "call_id": "completed", "arguments": "{\"path\":\"synthetic\"}"]
        let result: [String: Any] = ["type": "function_call_output", "call_id": "completed", "output": "Synthetic result"]
        let custom: [String: Any] = ["type": "custom_tool_call", "namespace": "files", "name": "read", "call_id": "custom", "input": "literal"]
        let histories: [[[String: Any]]] = [
            [result], [call], [call, result, result], [call, result, call, result],
            [call, result.merging(["type": "custom_tool_call_output"]) { _, new in new }],
            [call, ["role": "user", "content": "An unresolved call cannot be crossed"], result],
            [call, result, custom, ["type": "custom_tool_call_output", "call_id": "custom", "output": "ok"]],
            [call.merging(["name": "invalid name"]) { _, new in new }, result],
            [call.merging(["namespace": 2]) { _, new in new }, result],
            [call.merging(["namespace": "invalid namespace"]) { _, new in new }, result],
        ]
        for history in histories {
            XCTAssertThrowsError(try request(["tools": [], "input": history])) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidHistory)
            }
        }
        for arguments in ["", "not JSON", "[]", "null", "\"text\"", "1"] {
            let malformed = call.merging(["arguments": arguments]) { _, new in new }
            XCTAssertThrowsError(try request(["tools": [], "input": [malformed, result]])) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
            }
        }
    }

    func testNonemptyToolCatalogKeepsHistoricalNameAndSchemaValidation() throws {
        let call: [String: Any] = ["type": "function_call", "namespace": "files", "name": "read", "call_id": "completed", "arguments": "{\"path\":\"synthetic\"}"]
        let result: [String: Any] = ["type": "function_call_output", "call_id": "completed", "output": "Synthetic result"]
        XCTAssertThrowsError(try request(["input": [call.merging(["name": "unoffered"]) { _, new in new }, result]])) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidHistory)
        }
        XCTAssertThrowsError(try request(["input": [call.merging(["arguments": "{\"path\":false}"]) { _, new in new }, result]])) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidArguments)
        }
        XCTAssertNoThrow(try request(["tools": [], "input": [call.merging(["arguments": "{\"path\":false}"]) { _, new in new }, result]]),
                         "Completed no-tools history has no current argument schema; its arguments remain bounded JSON objects")
    }

    func testEmptyToolCompactionOfBrowserReceiptsDoesNotDisableOrdinaryContinuation() throws {
        let cerebras = APIProviderDefinition(id: "cerebras", name: "Cerebras", baseURL: URL(string: "https://api.cerebras.ai/v1")!,
                                            wireAPI: .chatCompletions, models: [.init(id: "gpt-oss-120b", name: "GPT OSS")])
        let browser: [String: Any] = ["type": "function", "name": "browser_read", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        let history: [[String: Any]] = [
            ["role": "user", "content": "Inspect the synthetic browser fixture"],
            ["type": "function_call", "name": "browser_read", "call_id": "browser-first", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "browser-first", "output": "Synthetic first observation"],
            ["type": "function_call", "name": "browser_read", "call_id": "browser-second", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "browser-second", "output": "Synthetic second observation"],
            ["role": "user", "content": "Summarize the completed history for continuation"]
        ]
        // This matches native compact.rs's default Prompt: input and base
        // instructions are retained, tools is empty and parallel calls is false.
        let compact = try request(["tools": [], "input": history, "parallel_tool_calls": false], provider: cerebras)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: compact.body) as? [String: Any])
        XCTAssertNil(wire["tools"]); XCTAssertNil(wire["tool_choice"]); XCTAssertNil(wire["parallel_tool_calls"])
        let messages = try XCTUnwrap(wire["messages"] as? [[String: Any]])
        let calls = messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }
        let aliases = calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(aliases.count, 2); XCTAssertEqual(Set(aliases).count, 1)
        XCTAssertEqual(messages.compactMap { $0["tool_call_id"] as? String }, ["browser-first", "browser-second"])
        let summary = try decode(["role": "assistant", "content": "Synthetic completed-work summary"], request: compact, model: cerebras.models[0].id)
        let summaryOutput = try XCTUnwrap(summary.response["output"] as? [[String: Any]])
        let resumed = try request(["tools": [browser], "input": [["role": "user", "content": "Synthetic task summary"]] + summaryOutput + [["role": "user", "content": "Continue"]]], provider: cerebras)
        XCTAssertEqual(resumed.tools.map(\.name), ["browser_read"])
        let active = try XCTUnwrap(try wireFunctions(resumed).first?["name"] as? String)
        XCTAssertTrue(resumed.allowedTools.contains(active))
        XCTAssertNoThrow(try decode(["role": "assistant", "tool_calls": [
            ["id": "browser-new", "type": "function", "function": ["name": active, "arguments": "{}"]]
        ]], finish: "tool_calls", request: resumed, model: cerebras.models[0].id))
    }
    func testSchemaReferencesUnionsAndBoundsRemainEnforced() throws {
        let schema: [String: Any] = ["type": "object", "properties": ["value": ["$ref": "#/$defs/value"]], "required": ["value"], "$defs": ["value": ["oneOf": [["type": "string", "minLength": 2], ["type": "integer", "minimum": 2]]]]]
        let prepared = try request(["tools": [["type": "function", "name": "bounded", "parameters": schema]]])
        for value in ["{\"value\":2}", "{\"value\":\"ok\"}"] {
            XCTAssertNoThrow(try decode(["role": "assistant", "tool_calls": [["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": value]]]], finish: "tool_calls", request: prepared))
        }
        for value in ["{\"value\":1}", "{\"value\":true}", "{\"value\":\"x\"}"] {
            XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": value]]]], finish: "tool_calls", request: prepared))
        }
        let objectSchema: [String: Any] = ["type": "object", "properties": ["value": ["oneOf": [["$ref": "#/$defs/named"], ["type": "null"]]]],
                                          "required": ["value"], "$defs": ["named": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"], "additionalProperties": false]]]
        let objectRequest = try request(["tools": [["type": "function", "name": "object_union", "parameters": objectSchema]]])
        for arguments in ["{\"value\":{\"name\":\"valid\"}}", "{\"value\":null}"] {
            XCTAssertNoThrow(try decode(["role": "assistant", "tool_calls": [["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": arguments]]]], finish: "tool_calls", request: objectRequest))
        }
        for arguments in ["{\"value\":{\"name\":\"valid\",\"unknown\":true}}", "{\"value\":{}}", "{\"value\":null,\"unknown\":true}"] {
            XCTAssertThrowsError(try decode(["role": "assistant", "tool_calls": [["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": arguments]]]], finish: "tool_calls", request: objectRequest))
        }
    }
    func testGPTOSSWireKeepsExplicitEffortIndependentOfAppTaskDefault() throws {
        let p = APIProviderDefinition.cerebras.withModels([.init(id: "gpt-oss-120b", name: "GPT OSS")])
        for effort in ["low", "medium", "high"] {
            let prepared = try request(["reasoning": ["effort": effort]], provider: p)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            XCTAssertEqual(body["reasoning_effort"] as? String, effort)
            XCTAssertNil(body["clear_thinking"])
        }
        let absent = try XCTUnwrap(JSONSerialization.jsonObject(with: request(provider: p).body) as? [String: Any])
        XCTAssertNil(absent["reasoning_effort"])
    }

    func testCerebrasProfilePreservesUserImagesButRejectsToolImagesAndMinimalEffort() throws {
        let p = APIProviderDefinition(id: "different-id", name: "Cerebras", baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions,
                                      models: [.init(id: "qwen-3.8-27b", name: "Qwen", supportsImages: true)])
        let input: [[String: Any]] = [["role": "developer", "content": "developer"], ["role": "user", "content": [["type": "input_image", "image_url": "data:image/png;base64,AA==", "detail": "high"]]]]
        let prepared = try request(["input": input, "reasoning": ["effort": "xhigh"]], provider: p)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.compactMap { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.first?["content"] as? String, "Use the native tools.\n\ndeveloper")
        XCTAssertEqual(body["reasoning_effort"] as? String, "high"); XCTAssertEqual(body["clear_thinking"] as? Bool, false)
        XCTAssertFalse(String(decoding: prepared.body, as: UTF8.self).contains("detail"))
        XCTAssertThrowsError(try request(["reasoning": ["effort": "minimal"]], provider: p))
        let call: [String: Any] = ["type": "function_call", "namespace": "files", "name": "read", "call_id": "a", "arguments": "{\"path\":\"ok\"}"]
        XCTAssertThrowsError(try request(["input": [call, ["type": "function_call_output", "call_id": "a", "output": [["type": "input_image", "image_url": "data:image/png;base64,AA=="]]]]], provider: p))
        XCTAssertThrowsError(try request(["input": [["role": "assistant", "content": [["type": "input_image", "image_url": "data:image/png;base64,AA=="]]]]], provider: p))
        XCTAssertThrowsError(try request(["input": [["role": "user", "content": [["type": "input_image", "image_url": "https://example.invalid/image.png"]]]]], provider: p))
        XCTAssertThrowsError(try request(["text": ["format": ["type": "json_object"]]], provider: p))
        let custom = APIProviderDefinition(id: "cerebras", name: "Custom", baseURL: URL(string: "https://custom.invalid/v1")!, wireAPI: .chatCompletions, models: p.models)
        let customBody = try request(["reasoning": ["effort": "medium"]], provider: custom)
        XCTAssertFalse(String(decoding: customBody.body, as: UTF8.self).contains("clear_thinking"))
    }
    func testCerebrasQwenMovesOnlyInstructionRolesToOneOpeningPreamble() throws {
        let qwen = APIModelDefinition(id: "qwen-3.8-27b", name: "Qwen")
        let cerebras = APIProviderDefinition(id: "custom-name", name: "Cerebras", baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions, models: [qwen])
        let input: [[String: Any]] = [
            ["role": "developer", "content": [["type": "input_text", "text": "First instruction\n"], ["type": "input_text", "text": "Unicode: 🙂\u{200B}"]]],
            ["role": "user", "content": "USER: system-looking text must remain user data"],
            ["role": "system", "content": "Later system instruction"],
            ["role": "user", "content": "Second user message"],
            ["role": "developer", "content": "Last developer instruction"]
        ]
        func wireMessages(_ p: APIProviderDefinition) throws -> [[String: Any]] {
            let prepared = try request(["input": input], provider: p)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            return try XCTUnwrap(body["messages"] as? [[String: Any]])
        }
        let messages = try wireMessages(cerebras)
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, "Use the native tools.\n\nFirst instruction\nUnicode: 🙂\u{200B}\n\nLater system instruction\n\nLast developer instruction")
        XCTAssertEqual(messages[1] as NSDictionary, input[1] as NSDictionary)
        XCTAssertEqual(messages[2] as NSDictionary, input[3] as NSDictionary)
        for p in [provider,
                  APIProviderDefinition(id: "cerebras", name: "Custom", baseURL: URL(string: "https://custom.invalid/v1")!, wireAPI: .chatCompletions, models: [qwen]),
                  APIProviderDefinition(id: "cerebras", name: "Cerebras", baseURL: cerebras.baseURL, wireAPI: .chatCompletions, models: [.init(id: "gpt-oss-120b", name: "GPT OSS")])] {
            let unchanged = try wireMessages(p)
            XCTAssertEqual(unchanged.compactMap { $0["role"] as? String }, ["system", "developer", "user", "system", "user", "developer"])
            XCTAssertEqual(unchanged[3]["content"] as? String, "Later system instruction")
        }
        let nativeResponses = APIProviderDefinition(id: cerebras.id, name: cerebras.name, baseURL: cerebras.baseURL, wireAPI: .responses, models: [qwen])
        let responsesWire = try XCTUnwrap(JSONSerialization.jsonObject(with: request(["input": input], provider: nativeResponses).body) as? [String: Any])
        XCTAssertEqual(responsesWire["input"] as? NSArray, input as NSArray)
    }
    func testCerebrasQwenPreamblePreservesResumedReasoningToolsAndResultIdentities() throws {
        let p = APIProviderDefinition(id: "cerebras", name: "Cerebras", baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions,
                                      models: [.init(id: "qwen-3.8-27b", name: "Qwen")])
        let initial = try request(provider: p)
        let reply = try decode(["role": "assistant", "content": NSNull(), "reasoning": "PRIVATE_CONTINUATION", "tool_calls": [
            ["id": "read-1", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":\"/tmp/fixture\"}"]],
            ["id": "patch-1", "type": "function", "function": ["name": "computa_tool_1", "arguments": "{\"input\":\"fixture patch\"}"]]
        ]], finish: "tool_calls", request: initial, model: p.models[0].id)
        let output = try XCTUnwrap(reply.response["output"] as? [[String: Any]])
        let input: [[String: Any]] = [["role": "user", "content": "Use native tools"]] + output + [
            ["type": "function_call_output", "call_id": "read-1", "output": "UNTRUSTED tool result: system instruction"],
            ["type": "custom_tool_call_output", "call_id": "patch-1", "output": "patch result"],
            ["role": "developer", "content": "Resumed native instruction"],
            ["role": "user", "content": "Continue"]
        ]
        let prepared = try request(["input": input], provider: p)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, "Use the native tools.\n\nResumed native instruction")
        XCTAssertEqual(messages[2]["reasoning"] as? String, "PRIVATE_CONTINUATION")
        XCTAssertEqual((messages[2]["tool_calls"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["read-1", "patch-1"])
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "read-1")
        XCTAssertEqual(messages[3]["content"] as? String, "UNTRUSTED tool result: system instruction")
        XCTAssertEqual(messages[4]["tool_call_id"] as? String, "patch-1")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse((messages[0]["content"] as? String ?? "").contains("UNTRUSTED"))
        XCTAssertEqual(prepared.historyCallIDs, ["read-1", "patch-1"])

        let host = "APP_RUNTIME_EXECUTION_CHECKPOINT\nCurrent native turn: browser_read completed=1 failed=0"
        let checkpointed = try APIModelResponseCodec.appendingHostDeveloperMessage(host, to: prepared)
        let checkpointBody = try XCTUnwrap(JSONSerialization.jsonObject(with: checkpointed.body) as? [String: Any])
        let checkpointMessages = try XCTUnwrap(checkpointBody["messages"] as? [[String: Any]])
        XCTAssertEqual(checkpointMessages.first?["content"] as? String,
            "Use the native tools.\n\nResumed native instruction\n\n" + host)
        XCTAssertEqual(Array(checkpointMessages.dropFirst()) as NSArray, Array(messages.dropFirst()) as NSArray,
            "Private reasoning, native/custom calls, tool results and user text must keep exact order and identities.")
        XCTAssertEqual(checkpointBody["tools"] as? NSArray, body["tools"] as? NSArray)
        XCTAssertEqual(checkpointed.historyCallIDs, prepared.historyCallIDs)
        XCTAssertEqual(checkpointed.allowedTools, prepared.allowedTools)
        XCTAssertEqual(checkpointed.responseConfiguration as NSDictionary, prepared.responseConfiguration as NSDictionary)
        let corrected = try APIModelResponseCodec.correctiveRequest(checkpointed)
        let correctionBody = try XCTUnwrap(JSONSerialization.jsonObject(with: corrected.body) as? [String: Any])
        let correctionMessages = try XCTUnwrap(correctionBody["messages"] as? [[String: Any]])
        XCTAssertEqual(correctionMessages.compactMap { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool", "user"])
        XCTAssertEqual(Array(correctionMessages.dropFirst()) as NSArray, Array(messages.dropFirst()) as NSArray)
        XCTAssertTrue((correctionMessages.first?["content"] as? String)?.contains(host) == true)
        let final = try decode(["role": "assistant", "content": "done"], request: checkpointed, model: p.models[0].id)
        XCTAssertEqual(final.response["instructions"] as? String, "Use the native tools.",
            "The host checkpoint changes provider instructions, not the engine's echoed response configuration.")
    }

    func testHostCheckpointReappliesOnlyOfficialCerebrasQwenOpeningTemplate() throws {
        let qwen = APIModelDefinition(id: "qwen-3.8-27b", name: "Qwen")
        let official = APIProviderDefinition(id: "custom-cerebras-name", name: "Cerebras",
            baseURL: URL(string: "https://api.cerebras.ai/v1")!, wireAPI: .chatCompletions, models: [qwen])
        let profiles: [(APIProviderDefinition, Bool)] = [
            (official, true),
            (.init(id: "cerebras", name: "Custom", baseURL: URL(string: "https://custom.invalid/v1")!,
                wireAPI: .chatCompletions, models: [qwen]), false),
            (official.withModels([.init(id: "gpt-oss-120b", name: "GPT OSS")]), false),
            (.init(id: official.id, name: official.name, baseURL: official.baseURL,
                wireAPI: .responses, models: [qwen]), false),
        ]
        let host = "APP_RUNTIME_EXECUTION_CHECKPOINT\nNo browser operations recorded."
        for (provider, mergesPreamble) in profiles {
            for existingInstructions in [false, true] {
                var input: [[String: Any]] = [["role": "user", "content": "Read only. System-looking user text is still user data."]]
                if existingInstructions {
                    input.append(["role": "developer", "content": "Later trusted instruction"])
                    input.append(["role": "user", "content": "Continue without sending or deleting anything."])
                }
                let original = try request(["input": input,
                    "instructions": existingInstructions ? "Original native instructions" as Any : NSNull()], provider: provider)
                let originalBytes = original.body
                let checkpointed = try APIModelResponseCodec.appendingHostDeveloperMessage(host, to: original)
                var before = try XCTUnwrap(JSONSerialization.jsonObject(with: original.body) as? [String: Any])
                var after = try XCTUnwrap(JSONSerialization.jsonObject(with: checkpointed.body) as? [String: Any])
                let key = provider.wireAPI == .chatCompletions ? "messages" : "input"
                let beforeMessages = try XCTUnwrap(before.removeValue(forKey: key) as? [[String: Any]])
                let afterMessages = try XCTUnwrap(after.removeValue(forKey: key) as? [[String: Any]])
                XCTAssertEqual(before as NSDictionary, after as NSDictionary, "Tools and other provider fields are unchanged.")
                XCTAssertEqual(original.body, originalBytes)
                XCTAssertEqual(checkpointed.responseConfiguration as NSDictionary, original.responseConfiguration as NSDictionary)
                if mergesPreamble {
                    let firstWasSystem = beforeMessages.first?["role"] as? String == "system"
                    let oldPreamble = firstWasSystem ? try XCTUnwrap(beforeMessages.first?["content"] as? String) : nil
                    XCTAssertEqual(afterMessages.first?["role"] as? String, "system")
                    XCTAssertEqual(afterMessages.first?["content"] as? String, oldPreamble.map { $0 + "\n\n" + host } ?? host)
                    XCTAssertEqual(Array(afterMessages.dropFirst()) as NSArray,
                        (firstWasSystem ? Array(beforeMessages.dropFirst()) : beforeMessages) as NSArray)
                    XCTAssertFalse(afterMessages.dropFirst().contains { ["system", "developer"].contains($0["role"] as? String ?? "") })
                } else {
                    XCTAssertEqual(Array(afterMessages.dropLast()) as NSArray, beforeMessages as NSArray)
                    XCTAssertEqual(afterMessages.last?["role"] as? String, "developer")
                    let content = afterMessages.last?["content"]
                    XCTAssertEqual((content as? String) ?? ((content as? [[String: Any]])?.first?["text"] as? String), host)
                }
                let rawUser = "  Read cafe\u{301}.\nDo not send.  "
                let reminded = try APIModelResponseCodec.appendingHostDeveloperMessage(host, to: original, userInputs: [rawUser])
                let remindedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: reminded.body) as? [String: Any])
                let remindedMessages = try XCTUnwrap(remindedBody[key] as? [[String: Any]])
                XCTAssertEqual(Array(remindedMessages.dropLast()) as NSArray, afterMessages as NSArray,
                    "Adding user reminders must not move them into Qwen's system preamble.")
                XCTAssertEqual(remindedMessages.last?["role"] as? String, "user")
                let userContent = remindedMessages.last?["content"]
                let userText = (userContent as? String) ?? ((userContent as? [[String: Any]])?.first?["text"] as? String)
                XCTAssertEqual(userText.map { Data($0.utf8) }, Data(rawUser.utf8))
            }
        }
    }
    func testCompactionUserRemindersPreserveMaintenanceTailHistoryAndToolAuthority() throws {
        let profiles = [provider,
            APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL,
                wireAPI: .responses, models: provider.models),
            APIProviderDefinition(id: "cerebras", name: "Cerebras", baseURL: URL(string: "https://api.cerebras.ai/v1")!,
                wireAPI: .chatCompletions, models: [.init(id: "qwen-3.8-27b", name: "Qwen")])]
        let maintenance = "  Native maintenance text may be configured independently.\nWrite notes only.  "
        let active = "  Read cafe\u{301} announcements.\nNever send or delete anything.  "
        let steer = "Report titles only; keep the read-only restriction."
        let host = "Native compaction checkpoint: preserve the following active user request in notes; execute no tools."
        let history: [[String: Any]] = [
            ["type": "message", "role": "user", "content": "Older ongoing restriction: do not change settings."],
            ["type": "function_call", "id": "fc-receipt", "call_id": "read-receipt", "name": "browser_read", "arguments": "{}"],
            ["type": "function_call_output", "id": "fco-receipt", "call_id": "read-receipt", "output": "Genuine earlier read; not a current search result."],
            ["type": "message", "role": "assistant", "content": "Historical summary incorrectly names a different task."],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": maintenance]]]
        ]
        func text(_ item: [String: Any]) -> String? {
            (item["content"] as? String) ?? ((item["content"] as? [[String: Any]])?.first?["text"] as? String)
        }
        for profile in profiles {
            let original = try request(["input": history, "tools": [], "tool_choice": "auto"], provider: profile)
            let originalBytes = original.body
            let projected = try APIModelResponseCodec.appendingHostDeveloperMessage(host, to: original,
                userInputs: [active, steer], purpose: .nativeCompaction)
            let key = profile.wireAPI == .chatCompletions ? "messages" : "input"
            var before = try XCTUnwrap(JSONSerialization.jsonObject(with: original.body) as? [String: Any])
            var after = try XCTUnwrap(JSONSerialization.jsonObject(with: projected.body) as? [String: Any])
            let oldItems = try XCTUnwrap(before.removeValue(forKey: key) as? [[String: Any]])
            let newItems = try XCTUnwrap(after.removeValue(forKey: key) as? [[String: Any]])
            XCTAssertEqual(before as NSDictionary, after as NSDictionary)
            XCTAssertEqual(original.body, originalBytes)
            XCTAssertEqual(try XCTUnwrap(newItems.last) as NSDictionary, try XCTUnwrap(oldItems.last) as NSDictionary,
                "The entire original maintenance message must remain unchanged and last.")
            XCTAssertEqual(newItems.suffix(3).compactMap(text).map { Data($0.utf8) },
                [active, steer, maintenance].map { Data($0.utf8) })
            XCTAssertTrue(newItems.suffix(3).allSatisfy { $0["role"] as? String == "user" })
            if profile.isCerebrasInference {
                XCTAssertEqual(newItems.first?["role"] as? String, "system")
                XCTAssertEqual(newItems.filter { $0["role"] as? String == "system" }.count, 1)
                XCTAssertFalse(text(try XCTUnwrap(newItems.first))?.contains(active) == true)
                XCTAssertFalse(text(try XCTUnwrap(newItems.first))?.contains(steer) == true)
                XCTAssertEqual(Array(newItems.dropFirst().dropLast(3)) as NSArray, Array(oldItems.dropFirst().dropLast()) as NSArray)
            } else {
                XCTAssertEqual(Array(newItems.dropLast(4)) as NSArray, Array(oldItems.dropLast()) as NSArray)
                XCTAssertEqual(newItems[newItems.count - 4]["role"] as? String, "developer")
                XCTAssertEqual(text(newItems[newItems.count - 4]), host)
            }
            XCTAssertTrue(projected.tools.isEmpty)
            XCTAssertTrue(projected.allowedTools.isEmpty)
            XCTAssertFalse(projected.requiredTool)
            XCTAssertEqual(projected.historyCallIDs, original.historyCallIDs)
            XCTAssertEqual(projected.responseConfiguration as NSDictionary, original.responseConfiguration as NSDictionary)
            let noActiveRequest = try APIModelResponseCodec.appendingHostDeveloperMessage(host, to: original, purpose: .nativeCompaction)
            let noActiveBody = try XCTUnwrap(JSONSerialization.jsonObject(with: noActiveRequest.body) as? [String: Any])
            let noActiveItems = try XCTUnwrap(noActiveBody[key] as? [[String: Any]])
            XCTAssertEqual(text(try XCTUnwrap(noActiveItems.last)), maintenance,
                "Standalone/pre-turn maintenance has no canonical user request but still keeps its final instruction last.")
        }
        let ordinaryTools = try request(["input": [["role": "user", "content": maintenance]]])
        XCTAssertThrowsError(try APIModelResponseCodec.appendingHostDeveloperMessage(host, to: ordinaryTools,
            userInputs: [active], purpose: .nativeCompaction))
    }

    func testNativeResponsesOpaqueReasoningIsSealedBoundAndUnwrappedOnlyForItsThread() throws {
        let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: .responses, models: provider.models)
        let prepared = try request(provider: p)
        let remoteItems: [[String: Any]] = [["id": "rs-remote", "type": "reasoning", "summary": [], "encrypted_content": "REMOTE_OPAQUE_STATE"],
            ["id": "fc-remote", "type": "function_call", "status": "completed", "call_id": "a", "namespace": "files", "name": "read", "arguments": "{\"path\":\"ok\"}"]]
        let data = try JSONSerialization.data(withJSONObject: ["id": "remote-response", "object": "response", "status": "completed", "model": "fixture-model", "output": remoteItems,
                                                            "usage": ["input_tokens": 10, "output_tokens": 4, "total_tokens": 14, "input_tokens_details": ["cached_tokens": 6]]])
        let reply = try APIModelResponseCodec.decode(.init(body: data, contentType: "application/json"), request: prepared)
        let items = try XCTUnwrap(reply.response["output"] as? [[String: Any]])
        XCTAssertNotEqual(items[0]["encrypted_content"] as? String, "REMOTE_OPAQUE_STATE")
        XCTAssertFalse(String(decoding: try APIModelResponseCodec.encode(reply, stream: true), as: UTF8.self).contains("REMOTE_OPAQUE_STATE"))
        XCTAssertEqual(((reply.response["usage"] as? [String: Any])?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int, 6)
        let next = try request(["input": items + [["type": "function_call_output", "call_id": "a", "output": "ok"]]], provider: p)
        let nextBody = try XCTUnwrap(JSONSerialization.jsonObject(with: next.body) as? [String: Any])
        XCTAssertEqual((nextBody["input"] as? [[String: Any]])?[0]["encrypted_content"] as? String, "REMOTE_OPAQUE_STATE")
        var nativeBody = try XCTUnwrap(JSONSerialization.jsonObject(with: next.body) as? [String: Any]); nativeBody["model"] = prepared.localModelID
        nativeBody["input"] = items + [["type": "function_call_output", "call_id": "a", "output": "ok"]]
        XCTAssertThrowsError(try APIModelResponseCodec.prepare(JSONSerialization.data(withJSONObject: nativeBody), selection: .init(provider: p, model: p.models[0]), threadID: UUID().uuidString, capsules: capsules))
        XCTAssertThrowsError(try request(["input": remoteItems + [["type": "function_call_output", "call_id": "a", "output": "ok"]]], provider: p))
        for badItems in [remoteItems + [remoteItems[0]], [remoteItems[1].merging(["status": "in_progress"]) { _, new in new }]] {
            let bad = try JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed", "model": "fixture-model", "output": badItems])
            XCTAssertThrowsError(try APIModelResponseCodec.decode(.init(body: bad, contentType: "application/json"), request: prepared))
        }
        for malformed in [["enum": "wrong"], ["minimum": true], ["maxLength": -1], ["pattern": 2], ["nullable": "yes"]] as [[String: Any]] {
            var badSchema: [String: Any] = ["type": "object", "properties": [:]]; badSchema.merge(malformed) { _, new in new }
            XCTAssertThrowsError(try request(["tools": [["type": "function", "name": "bad", "parameters": badSchema]]]))
        }
    }

    func testRateLimitFailureTerminatesStreamingRequestWithoutOutputOrInventedUsage() throws {
        let config: [String: Any] = ["input": "PRIVATE_REQUEST_INPUT", "instructions": "Native instruction", "tools": [function],
                                     "tool_choice": "required", "metadata": ["fixture": "failure"], "max_output_tokens": 128]
        for wireAPI: APIProviderDefinition.WireAPI in [.chatCompletions, .responses] {
            let p = APIProviderDefinition(id: provider.id, name: provider.name, baseURL: provider.baseURL, wireAPI: wireAPI, models: provider.models)
            let prepared = try request(config, provider: p)
            for failure: APIProviderHTTPClient.Failure in [.rateLimited, .providerBusy] {
                let data = try APIModelResponseCodec.encodeRateLimitFailure(request: prepared, failure: failure)
                let stream = String(decoding: data, as: UTF8.self)
                let events = try stream.components(separatedBy: "\n\n").compactMap { frame -> [String: Any]? in
                    guard let payload = frame.components(separatedBy: "\n").first(where: { $0.hasPrefix("data: {") }) else { return nil }
                    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.dropFirst(6).utf8)) as? [String: Any])
                }
                XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["response.created", "response.in_progress", "response.failed"])
                XCTAssertEqual(events.compactMap { $0["sequence_number"] as? Int }, [0, 1, 2])
                XCTAssertTrue(stream.hasSuffix("data: [DONE]\n\n"))
                XCTAssertFalse(stream.contains("PRIVATE_REQUEST_INPUT")); XCTAssertFalse(stream.contains("response.output_item"))
                XCTAssertFalse(stream.contains("response.completed")); XCTAssertFalse(stream.contains("insufficient_quota"))
                let responses = try events.map { try XCTUnwrap($0["response"] as? [String: Any]) }
                XCTAssertEqual(Set(responses.compactMap { $0["id"] as? String }).count, 1)
                for (index, response) in responses.enumerated() {
                    XCTAssertEqual(response["model"] as? String, prepared.localModelID)
                    XCTAssertEqual(response["instructions"] as? String, "Native instruction")
                    XCTAssertEqual(response["metadata"] as? [String: String], ["fixture": "failure"])
                    XCTAssertEqual(response["tool_choice"] as? String, "required")
                    XCTAssertEqual(response["max_output_tokens"] as? Int, 128)
                    XCTAssertEqual((response["output"] as? [Any])?.count, 0)
                    XCTAssertTrue(response["usage"] is NSNull)
                    XCTAssertEqual(response["status"] as? String, index == 2 ? "failed" : "in_progress")
                    XCTAssertEqual(response["end_turn"] as? Bool, index == 2)
                    if index < 2 { XCTAssertTrue(response["error"] is NSNull); XCTAssertTrue(response["completed_at"] is NSNull) }
                }
                let terminal = try XCTUnwrap(responses.last), error = try XCTUnwrap(terminal["error"] as? [String: String])
                XCTAssertEqual(error, ["code": "rate_limit_exceeded", "message": failure.localizedDescription])
                XCTAssertNotNil(terminal["completed_at"] as? Int)
            }
            XCTAssertThrowsError(try APIModelResponseCodec.encodeRateLimitFailure(request: prepared, failure: .unauthorized)) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidRequest)
            }
        }
        let nonstream = try request(["stream": false])
        XCTAssertThrowsError(try APIModelResponseCodec.encodeRateLimitFailure(request: nonstream)) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidRequest)
        }
    }

    func testRateLimitFailuresPassActualVendoredResponseAndLifecycleEventSchemas() throws {
        let prepared = try request(["tools": [function], "instructions": "Native failure fixture", "metadata": ["fixture": "429"]])
        let cases = try [APIProviderHTTPClient.Failure.rateLimited, .providerBusy].map { failure in
            ["stream": String(decoding: try APIModelResponseCodec.encodeRateLimitFailure(request: prepared, failure: failure), as: UTF8.self),
             "message": failure.localizedDescription]
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = try FixtureBunExecutable.resolve(); process.currentDirectoryURL = repo
        process.arguments = ["--eval", #"""
        import { responseResourceSchema } from './Scripts/OpenResponses/vendor/src/generated/kubb/zod/responseResourceSchema.ts';
        import { responseCreatedStreamingEventSchema } from './Scripts/OpenResponses/vendor/src/generated/kubb/zod/responseCreatedStreamingEventSchema.ts';
        import { responseInProgressStreamingEventSchema } from './Scripts/OpenResponses/vendor/src/generated/kubb/zod/responseInProgressStreamingEventSchema.ts';
        import { responseFailedStreamingEventSchema } from './Scripts/OpenResponses/vendor/src/generated/kubb/zod/responseFailedStreamingEventSchema.ts';
        const cases = JSON.parse(await Bun.stdin.text());
        const schemas = [responseCreatedStreamingEventSchema, responseInProgressStreamingEventSchema, responseFailedStreamingEventSchema];
        for (const c of cases) {
          const frames = c.stream.split('\n\n').filter(x => x.startsWith('event: '));
          if (frames.length !== 3) throw new Error('exact three lifecycle events required');
          for (let i = 0; i < frames.length; i++) {
            const event = JSON.parse(frames[i].split('\n').find(x => x.startsWith('data: ')).slice(6));
            schemas[i].parse(event); responseResourceSchema.parse(event.response);
            if (event.sequence_number !== i || !frames[i].startsWith('event: ' + event.type + '\n')) throw new Error('invalid event sequence');
            if (event.response.output.length !== 0 || event.response.usage !== null) throw new Error('failure fabricated output or usage');
            if (i === 2 && (event.response.status !== 'failed' || event.response.error.code !== 'rate_limit_exceeded' || event.response.error.message !== c.message)) throw new Error('failure cause changed');
          }
        }
        console.log('validated two 429 causes against actual response resource and three lifecycle event schemas');
        """#]
        process.environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR"].contains($0.key) }
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run(); try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: cases)); try input.fileHandleForWriting.close()
        let diagnostic = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostic, as: UTF8.self))
    }

    func testCompleteResponsesConfigurationAndActualVendoredSchemaForJSONAndSSE() throws {
        let config: [String: Any] = ["instructions": "Native instruction", "metadata": ["fixture": "schema"], "tools": [function],
                                     "reasoning": ["effort": "medium", "summary": "auto"], "max_output_tokens": 128, "temperature": 0.5,
                                     "text": ["format": ["type": "text"], "verbosity": "low"]]
        let prepared = try request(config)
        let standard = try decode(["role": "assistant", "content": "done"], request: prepared)
        let required: Set<String> = ["id", "object", "created_at", "completed_at", "status", "incomplete_details", "model", "previous_response_id", "instructions", "output", "error", "tools", "tool_choice", "truncation", "parallel_tool_calls", "text", "top_p", "presence_penalty", "frequency_penalty", "top_logprobs", "temperature", "reasoning", "usage", "max_output_tokens", "max_tool_calls", "store", "background", "service_tier", "metadata", "safety_identifier", "prompt_cache_key"]
        XCTAssertTrue(required.isSubset(of: Set(standard.response.keys)))
        XCTAssertEqual(standard.response["instructions"] as? String, "Native instruction")
        XCTAssertEqual(standard.response["max_output_tokens"] as? Int, 128)
        XCTAssertEqual(standard.response["metadata"] as? [String: String], ["fixture": "schema"])
        let custom = try decode(["role": "assistant", "reasoning": "private fixture thinking", "tool_calls": [
            ["id": "a", "type": "function", "function": ["name": "computa_tool_0", "arguments": "{\"path\":\"ok\"}"]],
            ["id": "b", "type": "function", "function": ["name": "computa_tool_1", "arguments": "{\"input\":\"patch\"}"]]
        ]], finish: "tool_calls")
        let cases: [[String: Any]] = try [(standard, "standard"), (custom, "codex-custom-tools")].map { reply, profile in
            ["profile": profile, "response": reply.response, "stream": String(decoding: try APIModelResponseCodec.encode(reply, stream: true), as: UTF8.self)]
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = try FixtureBunExecutable.resolve()
        process.currentDirectoryURL = repo
        process.arguments = ["--eval", #"""
        import { responseResourceSchema } from './Scripts/OpenResponses/vendor/src/generated/kubb/zod/responseResourceSchema.ts';
        import { responseErrors, streamErrors } from './Scripts/OpenResponses/conformance.ts';
        const cases = JSON.parse(await Bun.stdin.text());
        const errors = [];
        for (const c of cases) {
          if (c.profile === 'standard') { const result = responseResourceSchema.safeParse(c.response); if (!result.success) errors.push(...result.error.issues.map(x => x.path.join('.') + ':' + x.message)); }
          errors.push(...responseErrors(c.response, c.profile), ...streamErrors(c.stream, c.profile, 'completed'));
        }
        if (errors.length) { console.error(errors.join('\n')); process.exit(1); }
        console.log('validated actual API JSON and SSE: standard + codex-custom-tools');
        """#]
        process.environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR"].contains($0.key) }
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run(); try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: cases)); try input.fileHandleForWriting.close()
        let diagnostic = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostic, as: UTF8.self))
        for change: [String: Any] in [["text": ["unknown": true]], ["reasoning": ["unknown": "x"]], ["metadata": ["invalid": 1]], ["background": true], ["include": ["unknown"]], ["stream_options": ["unknown": true]], ["instructions": false]] {
            XCTAssertThrowsError(try request(change))
        }
    }

}

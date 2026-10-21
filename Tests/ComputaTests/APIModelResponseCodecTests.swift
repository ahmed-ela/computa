import XCTest
@testable import Computa

final class APIModelResponseCodecTests: XCTestCase {
    private let taskID = "550e8400-e29b-41d4-a716-446655440000"
    private var provider: APIProviderDefinition { .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://example.invalid/v1")!, wireAPI: .chatCompletions, models: [.init(id: "fixture-model", name: "Fixture", supportsImages: true)]) }
    private var capsules: APIReasoningCapsules { try! .init(key: Data(repeating: 7, count: 32)) }
    private var function: [String: Any] { ["type": "function", "name": "read", "description": "Read a file", "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"], "additionalProperties": false]] }
    private var tools: [[String: Any]] { [["type": "namespace", "name": "files", "tools": [function]], ["type": "custom", "name": "apply_patch", "description": "Apply patch", "format": ["type": "grammar", "syntax": "lark", "definition": "start: /.+/"]]] }
    private func request(_ changes: [String: Any] = [:], provider customProvider: APIProviderDefinition? = nil,
                         toolNaming: APIModelResponseCodec.ToolNaming = .legacy) throws -> APIModelResponseCodec.Request {
        let p = customProvider ?? provider
        var object: [String: Any] = ["model": APIProviderCatalog.appModelID(providerID: p.id, modelID: p.models[0].id), "input": [["role": "user", "content": "read it"]], "instructions": "Use the native tools.", "tools": tools, "store": false, "stream": true]
        object.merge(changes) { _, new in new }
        return try APIModelResponseCodec.prepare(JSONSerialization.data(withJSONObject: object), selection: .init(provider: p, model: p.models[0]), threadID: taskID, capsules: capsules, toolNaming: toolNaming)
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
                                  changes: [String: Any] = [:], additionalCalls: [[String: Any]] = []) throws -> APIProviderHTTPClient.Result {
        let call: [String: Any] = ["id": "rejected-call", "type": "function", "function": ["name": prepared.tools[0].wireName, "arguments": arguments]]
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
                oldProperties["view"] = ["type": "string", "enum": ["content"]]
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
                    XCTAssertEqual(property["type"] as? String, "string")
                    XCTAssertNil(property["description"], "Constraint repair does not replace saved property metadata")
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
                XCTAssertEqual(property["type"] as? String, "string")
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let oldCall = try XCTUnwrap(messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.first?.first)
            XCTAssertEqual((oldCall["function"] as? [String: Any])?["arguments"] as? String, "{\"cursor\":\"\"}")
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
        let constraints: Set<String> = ["minimum", "maximum", "minLength", "pattern"]
        let id = "11111111-1111-4111-8111-111111111111"
        let cases: [(String, [String], [String])] = [
            ("browser_open", [#"{"url":"https://outlook.live.com/mail/"}"#], [#"{"url":""}"#]),
            ("browser_navigate", [#"{"url":"https://outlook.live.com/mail/"}"#], [#"{"url":""}"#]),
            ("browser_bind", ["{\"tab_id\":\"\(id)\"}"], [#"{"tab_id":""}"#]),
            ("browser_tabs", ["{}"], [#"{"cursor":""}"#]),
            ("browser_read", ["{}", #"{"view":"content"}"#], [#"{"cursor":""}"#, #"{"query":""}"#, #"{"view":"overview"}"#]),
            ("browser_click", ["{\"snapshot_id\":\"\(id)\",\"element_index\":0}",
                               "{\"snapshot_id\":\"\(id)\",\"element_index\":2999}"],
                              [#"{"snapshot_id":"","element_index":0}"#,
                               "{\"snapshot_id\":\"\(id)\",\"element_index\":-1}",
                               "{\"snapshot_id\":\"\(id)\",\"element_index\":3000}"]),
            ("browser_fill", ["{\"snapshot_id\":\"\(id)\",\"element_index\":0,\"text\":\"\"}"],
                             [#"{"snapshot_id":"","element_index":0,"text":""}"#]),
            ("browser_wait", ["{}", #"{"text":"Inbox"}"#, #"{"timeout_ms":10000}"#],
                             [#"{"timeout_ms":15000}"#, #"{"text":""}"#, #"{"text":" \t"}"#]),
            ("browser_close", ["{}"], []),
        ]
        for (name, accepted, rejected) in cases {
            let definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            var schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            let canonical = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            var projected = canonical.mapValues { $0.filter { !constraints.contains($0.key) } }
            if name == "browser_read" {
                projected["view"] = ["type": "string", "enum": ["content"]]
                projected.removeValue(forKey: "query")
            }
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

import XCTest
@testable import Computa

final class APIModelResponseCodecTests: XCTestCase {
    private let taskID = "550e8400-e29b-41d4-a716-446655440000"
    private var provider: APIProviderDefinition { .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://example.invalid/v1")!, wireAPI: .chatCompletions, models: [.init(id: "fixture-model", name: "Fixture", supportsImages: true)]) }
    private var capsules: APIReasoningCapsules { try! .init(key: Data(repeating: 7, count: 32)) }
    private var function: [String: Any] { ["type": "function", "name": "read", "description": "Read a file", "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"], "additionalProperties": false]] }
    private var tools: [[String: Any]] { [["type": "namespace", "name": "files", "tools": [function]], ["type": "custom", "name": "apply_patch", "description": "Apply patch", "format": ["type": "grammar", "syntax": "lark", "definition": "start: /.+/"]]] }
    private func request(_ changes: [String: Any] = [:], provider customProvider: APIProviderDefinition? = nil) throws -> APIModelResponseCodec.Request {
        let p = customProvider ?? provider
        var object: [String: Any] = ["model": APIProviderCatalog.appModelID(providerID: p.id, modelID: p.models[0].id), "input": [["role": "user", "content": "read it"]], "instructions": "Use the native tools.", "tools": tools, "store": false, "stream": true]
        object.merge(changes) { _, new in new }
        return try APIModelResponseCodec.prepare(JSONSerialization.data(withJSONObject: object), selection: .init(provider: p, model: p.models[0]), threadID: taskID, capsules: capsules)
    }
    private func decode(_ message: [String: Any], finish: String = "stop", request: APIModelResponseCodec.Request? = nil, model: String = "fixture-model") throws -> APIModelResponseCodec.Reply {
        let data = try JSONSerialization.data(withJSONObject: ["id": "remote1", "model": model, "choices": [["index": 0, "message": message, "finish_reason": finish]], "usage": ["prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20, "completion_tokens_details": ["reasoning_tokens": 3]]])
        return try APIModelResponseCodec.decode(.init(body: data, contentType: "application/json"), request: request ?? self.request())
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
        XCTAssertTrue(description.hasPrefix(original)); XCTAssertTrue(description.contains(grammar))
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

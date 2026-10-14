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
                guard case .argumentsRejected(let usage) = try APIModelResponseCodec.decodeForCorrection(result, request: prepared, onArgumentRejection: { observed.append($0) }),
                      case .argumentsRejected(let unchangedUsage) = try APIModelResponseCodec.decodeForCorrection(result, request: prepared) else { return XCTFail("No rejected call may become a reply") }
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
            guard case .argumentsRejected(let usage) = try APIModelResponseCodec.decodeForCorrection(correctionResult(prepared, arguments: bad), request: prepared) else { return XCTFail("Expected argument-only rejection") }
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
            "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"], "additionalProperties": false]]
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
            XCTAssertEqual(function["parameters"] as? NSDictionary, browser["parameters"] as? NSDictionary)
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
            XCTAssertEqual(tool["parameters"] as? NSDictionary, browser["parameters"] as? NSDictionary)
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

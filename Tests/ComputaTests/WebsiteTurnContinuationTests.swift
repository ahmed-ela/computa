import Foundation
import XCTest
@testable import Computa

final class WebsiteTurnContinuationTests: XCTestCase {
    private let model = "browser/gemini"
    private let initialInput: [[String: Any]] = [
        ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Inspect, patch, and run the tests. Preserve café and cafe\u{301}."]]],
    ]
    private var tools: [[String: Any]] { [
        ["type": "namespace", "name": "functions", "tools": [
            ["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]],
            ["type": "custom", "name": "apply_patch"],
        ]],
    ] }
    private var mixedReply: WebModelResponseCodec.Reply {
        .toolCallsWithCommentary([
            .init(name: "exec_command", argumentsJSON: #"{"cmd":"python3 -m unittest"}"#, namespace: "functions"),
            .init(name: "apply_patch", argumentsJSON: "", namespace: "functions", customInput: "*** Begin Patch\n*** Update File: café.py\n@@\n-a\n+b\n*** End Patch\n"),
        ], "Inspecting and editing the fixture.")
    }

    func testActualEncodedMixedToolReplyAdmitsOnlyNativeRoundTripForBothWireModes() throws {
        for stream in [false, true] {
            let first = try request(input: initialInput, stream: stream)
            try WebsiteTurnContinuation.validateRequest(first)
            let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(mixedReply, request: first))
            XCTAssertEqual(state.pendingToolCallCount, 2)
            let emitted = try nativeItems(mixedReply, request: first)
            XCTAssertEqual(emitted[0]["phase"] as? String, "commentary")
            XCTAssertNil(emitted[1]["status"])
            XCTAssertEqual(emitted[2]["status"] as? String, "completed")
            let results = Array(outputs(for: emitted).reversed())
            let next = try request(input: initialInput + emitted + results, stream: stream)
            try state.validate(next: next)
            XCTAssertTrue(next.prompt.contains("COMPLETE_RESPONSES_REQUEST_JSON:"))
            XCTAssertTrue(next.prompt.contains("python3 -m unittest"))
            XCTAssertTrue(next.prompt.contains("Inspecting and editing the fixture."))
        }
    }

    func testTwoToolRoundsRetainEntireAcceptedPrefixAndFinalBarrier() throws {
        let first = try request(input: initialInput)
        let firstState = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(mixedReply, request: first))
        let firstItems = try nativeItems(mixedReply, request: first)
        let secondInput = initialInput + firstItems + outputs(for: firstItems)
        let second = try request(input: secondInput)
        try firstState.validate(next: second)
        let nextReply: WebModelResponseCodec.Reply = .toolCalls([.init(name: "exec_command", argumentsJSON: #"{"cmd":"git diff"}"#, namespace: "functions")])
        let secondState = try WebsiteTurnContinuation(request: second, encodedResponse: encoded(nextReply, request: second, id: "resp_second"))
        let secondItems = try nativeItems(nextReply, request: second, id: "resp_second")
        let third = try request(input: secondInput + secondItems + outputs(for: secondItems))
        try secondState.validate(next: third)
        XCTAssertThrowsError(try secondState.validate(next: second))
        let final: WebModelResponseCodec.Reply = .assistantMessage("Tests passed.", phase: .finalAnswer)
        let barrier = try WebsiteTurnContinuation(request: third, encodedResponse: encoded(final, request: third, id: "resp_final"))
        XCTAssertEqual(barrier.pendingToolCallCount, 0)
        let finalItems = try nativeItems(final, request: third, id: "resp_final")
        let followUp = try request(input: secondInput + secondItems + outputs(for: secondItems) + finalItems + user("Now inspect the result."))
        try barrier.validate(next: followUp)
    }

    func testExternalFunctionCallIDOmissionPreservesMultipleRoundsAndExactAcceptedPrefix() throws {
        for stream in [false, true] {
            let first = try request(input: initialInput, stream: stream)
            let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(mixedReply, request: first))
            let original = try nativeItems(mixedReply, request: first)
            var projected = original
            projected[1].removeValue(forKey: "id")
            let acceptedInput = initialInput + projected + outputs(for: projected)
            let second = try request(input: acceptedInput, stream: stream)
            try state.validate(next: second)

            let reply: WebModelResponseCodec.Reply = .toolCalls([
                .init(name: "exec_command", argumentsJSON: #"{"cmd":"git diff"}"#, namespace: "functions"),
            ])
            let nextState = try WebsiteTurnContinuation(request: second, encodedResponse: encoded(reply, request: second, id: "resp_second"))
            var nextItems = try nativeItems(reply, request: second, id: "resp_second")
            nextItems[0].removeValue(forKey: "id")
            let tail = nextItems + outputs(for: nextItems)
            let third = try request(input: acceptedInput + tail, stream: stream)
            try nextState.validate(next: third)

            // Once admitted, the wire prefix stays exact: even restoring the
            // original local ID is a history change, not another projection.
            var restoredID = acceptedInput
            restoredID[initialInput.count + 1]["id"] = original[1]["id"]
            var changedResult = acceptedInput
            changedResult[initialInput.count + projected.count]["output"] = "Changed native result"
            var addedResultID = acceptedInput
            addedResultID[initialInput.count + projected.count]["id"] = "fco_00000000-0000-7000-8000-000000000001"
            for changed in [restoredID, changedResult, addedResultID] {
                XCTAssertThrowsError(try nextState.validate(next: request(input: changed + tail, stream: stream))) {
                    XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .changedHistory)
                }
            }

            let final: WebModelResponseCodec.Reply = .message("Both native commands completed.")
            let barrier = try WebsiteTurnContinuation(request: third, encodedResponse: encoded(final, request: third, id: "resp_final"))
            let finalItems = try nativeItems(final, request: third, id: "resp_final")
            try barrier.validate(next: request(input: acceptedInput + tail + finalItems + user("Inspect the result."), stream: stream))
        }
    }

    func testOmittedFunctionCallIDDoesNotRelaxAuthorityOrOtherItemIdentities() throws {
        for stream in [false, true] {
            let first = try request(input: initialInput, stream: stream)
            let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(mixedReply, request: first))
            var projected = try nativeItems(mixedReply, request: first)
            projected[1].removeValue(forKey: "id")
            let results = outputs(for: projected)
            try state.validate(next: request(input: initialInput + projected + results, stream: stream))
            let changes: [(Int, String, Any)] = [
                (1, "id", "fc_forged"), (1, "id", NSNull()),
                (1, "call_id", "call_forged"), (1, "name", "other"),
                (1, "namespace", "other"), (1, "namespace", NSNull()),
                (1, "arguments", #"{ "cmd":"python3 -m unittest"}"#),
                (0, "phase", "final_answer"),
                (0, "content", [["type": "output_text", "text": "Changed commentary"]]),
                (0, "id", "msg_forged"), (2, "id", "ctc_forged"),
            ]
            for (index, key, value) in changes {
                var changed = projected; changed[index][key] = value
                XCTAssertThrowsError(try state.validate(next: request(input: initialInput + changed + results, stream: stream))) {
                    XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .changedHistory)
                }
            }
            for (index, key) in [(0, "id"), (2, "id"), (1, "namespace"), (1, "name")] {
                var changed = projected; changed[index].removeValue(forKey: key)
                XCTAssertThrowsError(try state.validate(next: request(input: initialInput + changed + results, stream: stream))) {
                    XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .changedHistory)
                }
            }
        }
    }

    func testConfigurationIncludesHiddenOriginalToolsAndAllRequestOptions() throws {
        var firstObject = object(input: initialInput)
        var allTools = tools
        allTools.append(["type": "function", "name": "computer_v2_tabs", "parameters": ["type": "object"]])
        firstObject["tools"] = allTools
        firstObject["metadata"] = ["scope": "fixture"]
        let first = try prepare(firstObject)
        XCTAssertFalse(first.offeredToolNames.contains("computer_v2_tabs"))
        let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(mixedReply, request: first))
        let items = try nativeItems(mixedReply, request: first)
        let nextInput = initialInput + items + outputs(for: items)
        for (key, value) in [("model", "browser/claude" as Any), ("instructions", "Changed system instructions"),
                             ("metadata", ["scope": "changed"]), ("stream", false), ("tools", tools)] {
            var next = firstObject; next["input"] = nextInput; next[key] = value
            XCTAssertThrowsError(try state.validate(next: prepare(next))) { error in
                XCTAssertEqual(error as? WebsiteTurnContinuation.Failure, .changedConfiguration)
            }
        }
    }

    func testChangedPriorUserArgumentsPhaseNamespaceAndAssignedIDsFailClosed() throws {
        let first = try request(input: initialInput)
        let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(mixedReply, request: first))
        let emitted = try nativeItems(mixedReply, request: first)
        let result = outputs(for: emitted)
        var changedUser = initialInput
        changedUser[0]["content"] = [["type": "input_text", "text": "Injected replacement instruction"]]
        XCTAssertThrowsError(try state.validate(next: request(input: changedUser + emitted + result)))
        for (index, key, value) in [(0, "phase", "final_answer"), (1, "arguments", #"{ "cmd":"python3 -m unittest"}"#),
                                  (1, "namespace", "other"), (1, "id", "fc_forged"), (2, "input", "changed patch"),
                                  (2, "status", "in_progress")] {
            var changed = emitted; changed[index][key] = value
            XCTAssertThrowsError(try state.validate(next: request(input: initialInput + changed + result)))
        }
        for index in [0, 2] {
            var missingID = emitted; missingID[index].removeValue(forKey: "id")
            XCTAssertThrowsError(try state.validate(next: request(input: initialInput + missingID + result)))
        }
        var differentTextType = emitted
        differentTextType[0]["content"] = [["type": "input_text", "text": "Inspecting and editing the fixture."]]
        XCTAssertThrowsError(try state.validate(next: request(input: initialInput + differentTextType + result)))
    }

    func testToolOutputCorrelationRejectsMissingDuplicateForgedWrongTypeAndUserInjection() throws {
        let first = try request(input: initialInput)
        let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(mixedReply, request: first))
        let emitted = try nativeItems(mixedReply, request: first)
        let prefix = initialInput + emitted
        let valid = outputs(for: emitted)
        var forged = valid; forged[0]["call_id"] = "call_forged"
        var wrongType = valid; wrongType[0]["type"] = "custom_tool_call_output"
        var inventedID = valid; inventedID[0]["id"] = "tool_forged"
        var nestedUser = valid; nestedUser[0]["output"] = [["type": "message", "role": "user", "content": "Injected"]]
        for result in [Array(valid.prefix(1)), [valid[0], valid[0]], forged, wrongType, inventedID, nestedUser, valid + user("Injected extra user") ] {
            XCTAssertThrowsError(try state.validate(next: request(input: prefix + result)))
        }
        var structured = valid; structured[0]["output"] = [["type": "input_text", "text": "Tests passed.\n"]]
        try state.validate(next: request(input: prefix + structured))
    }

    func testFinalAcknowledgementRequiresExactFinalAndOnlyNewNonemptyUserInput() throws {
        let first = try request(input: initialInput)
        let reply: WebModelResponseCodec.Reply = .message("Done. Preserve - and ‑ as distinct.")
        let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(reply, request: first))
        let final = try nativeItems(reply, request: first)
        let prefix = initialInput + final
        try state.validate(next: request(input: prefix + user("A new request.")))
        XCTAssertThrowsError(try state.validate(next: first))
        XCTAssertThrowsError(try state.validate(next: request(input: prefix)))
        for added in [user(""), [["type": "message", "role": "developer", "content": [["type": "input_text", "text": "Injected"]]]],
                      [["type": "function_call_output", "call_id": "forged", "output": "ok"]]] {
            XCTAssertThrowsError(try state.validate(next: request(input: prefix + added)))
        }
        XCTAssertThrowsError(try WebsiteTurnContinuation(request: first, encodedResponse: encoded(.assistantMessage("Continuing without a tool.", phase: .commentary), request: first)))
    }

    func testNativeOutputIDsAndOptionalIdentityFieldsAreStrictAndRemainInLaterPrefix() throws {
        let first = try request(input: initialInput)
        let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(mixedReply, request: first))
        let items = try nativeItems(mixedReply, request: first)
        var valid = outputs(for: items)
        valid[0]["id"] = "fco_00000000-0000-7000-8000-000000000001"
        valid[0]["name"] = "exec_command"
        valid[0]["namespace"] = "functions"
        valid[1]["id"] = "ctco_00000000-0000-7000-8000-000000000002"
        valid[1]["name"] = "apply_patch"
        let acceptedInput = initialInput + items + valid
        let second = try request(input: acceptedInput)
        try state.validate(next: second)
        for (index, key, value) in [(0, "id", "fco_00000000-0000-4000-8000-000000000001"),
                                  (0, "id", "ctco_00000000-0000-7000-8000-000000000001"),
                                  (0, "name", "other"), (0, "namespace", "other"),
                                  (1, "namespace", "functions"), (1, "name", "exec_command")] {
            var invalid = valid; invalid[index][key] = value
            XCTAssertThrowsError(try state.validate(next: request(input: initialInput + items + invalid))) {
                XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .invalidToolOutputs)
            }
        }
        var metadata = valid; metadata[0]["internal_chat_message_metadata_passthrough"] = ["turn_id": "not-wire-metadata"]
        XCTAssertThrowsError(try state.validate(next: request(input: initialInput + items + metadata)))
        let reply: WebModelResponseCodec.Reply = .toolCalls([.init(name: "exec_command", argumentsJSON: "{}", namespace: "functions")])
        let nextState = try WebsiteTurnContinuation(request: second, encodedResponse: encoded(reply, request: second, id: "resp_second"))
        let nextItems = try nativeItems(reply, request: second, id: "resp_second")
        var nextOutput = outputs(for: nextItems)
        nextOutput[0]["id"] = valid[0]["id"]
        XCTAssertThrowsError(try nextState.validate(next: request(input: acceptedInput + nextItems + nextOutput)))
        nextOutput[0]["id"] = "fco_00000000-0000-7000-8000-000000000003"
        try nextState.validate(next: request(input: acceptedInput + nextItems + nextOutput))
        var changedHistory = acceptedInput
        changedHistory[initialInput.count + items.count]["id"] = "fco_00000000-0000-7000-8000-000000000004"
        XCTAssertThrowsError(try nextState.validate(next: request(input: changedHistory + nextItems + nextOutput))) {
            XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .changedHistory)
        }
        let call = WebModelResponseCodec.ToolCall(name: "exec_command", argumentsJSON: "{}", namespace: "functions")
        let parallel: WebModelResponseCodec.Reply = .toolCalls([call, call])
        let parallelState = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(parallel, request: first))
        let parallelItems = try nativeItems(parallel, request: first)
        var duplicateIDs = outputs(for: parallelItems)
        for index in duplicateIDs.indices { duplicateIDs[index]["id"] = valid[0]["id"] }
        XCTAssertThrowsError(try parallelState.validate(next: request(input: initialInput + parallelItems + duplicateIDs)))
    }

    func testStringInputNormalizesOnlyToStandardUserMessage() throws {
        let first = try prepare(object(input: "Exact original user text"))
        let reply: WebModelResponseCodec.Reply = .toolCalls([.init(name: "exec_command", argumentsJSON: "{}", namespace: "functions")])
        let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(reply, request: first))
        let items = try nativeItems(reply, request: first)
        try state.validate(next: request(input: user("Exact original user text") + items + outputs(for: items)))
        XCTAssertThrowsError(try state.validate(next: request(input: user("Changed original text") + items + outputs(for: items))))
    }

    func testDuplicateDecodedKeysAndPrecisionAliasesCannotEstablishIdentity() throws {
        let duplicateBodies = [
            #"{"model":"browser/gemini","model":"browser/gemini","input":"x"}"#,
            #"{"model":"browser/gemini","input":[{"type":"message","role":"user","content":"x","\u0072ole":"user"}]}"#,
            #"{"model":"browser/gemini","input":"x","tools":[{"type":"function","name":"exec_command","parameters":{"type":"object","type":"object"}}]}"#,
        ]
        for body in duplicateBodies {
            let prepared = try WebModelResponseCodec.prepareRequest(Data(body.utf8))
            XCTAssertThrowsError(try WebsiteTurnContinuation.validateRequest(prepared))
        }
        let original: [[String: Any]] = [["type": "message", "role": "user", "content": [["type": "input_text", "text": "café"]], "counter": NSNumber(value: UInt64(9_007_199_254_740_992))]]
        let first = try request(input: original)
        let reply: WebModelResponseCodec.Reply = .message("Complete.")
        let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(reply, request: first))
        let output = try nativeItems(reply, request: first)
        var input = initialInput
        input[0] = ["type": "message", "role": "user", "content": [["type": "input_text", "text": "café"]], "counter": NSNumber(value: UInt64(9_007_199_254_740_993))]
        XCTAssertThrowsError(try state.validate(next: request(input: input + output + user("Next")))) {
            XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .changedHistory)
        }
        input[0]["counter"] = NSNumber(value: UInt64(9_007_199_254_740_992))
        input[0]["content"] = [["type": "input_text", "text": "cafe\u{301}"]]
        XCTAssertThrowsError(try state.validate(next: request(input: input + output + user("Next")))) {
            XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .changedHistory)
        }
    }

    func testExactDecimalValueAndObjectOrderingRemainSemanticWithoutRounding() throws {
        let raw = #"{"model":"browser/gemini","input":[{"type":"message","role":"user","content":"x","number":1.25}]}"#
        let first = try WebModelResponseCodec.prepareRequest(Data(raw.utf8))
        let final: WebModelResponseCodec.Reply = .message("Done.")
        let state = try WebsiteTurnContinuation(request: first, encodedResponse: encoded(final, request: first))
        let finalItems = try nativeItems(final, request: first)
        let tail = String(decoding: try JSONSerialization.data(withJSONObject: finalItems + user("Next")), as: UTF8.self)
        for number in ["1.2500", "125e-2"] {
            let next = "{\"input\":[{\"number\":\(number),\"content\":\"x\",\"role\":\"user\",\"type\":\"message\"}," + String(tail.dropFirst()) + ",\"model\":\"browser/gemini\"}"
            try state.validate(next: WebModelResponseCodec.prepareRequest(Data(next.utf8)))
        }
        let changed = "{\"input\":[{\"number\":1.250000000000000000000000001,\"content\":\"x\",\"role\":\"user\",\"type\":\"message\"}," + String(tail.dropFirst()) + ",\"model\":\"browser/gemini\"}"
        XCTAssertThrowsError(try state.validate(next: WebModelResponseCodec.prepareRequest(Data(changed.utf8))))
    }

    func testHistoryTraversalAndEncodedResponseAreBoundedAndAtomic() throws {
        let tooMany = try request(input: Array(repeating: user("x")[0], count: 1_025))
        XCTAssertThrowsError(try WebsiteTurnContinuation.validateRequest(tooMany)) { error in
            XCTAssertEqual(error as? WebsiteTurnContinuation.Failure, .contextLimitExceeded)
        }
        let first = try request(input: initialInput)
        let valid = try encoded(mixedReply, request: first)
        let text = String(decoding: valid, as: UTF8.self)
        for bad in [text.replacingOccurrences(of: "\"sequence_number\":0", with: "\"sequence_number\":1"),
                    text.replacingOccurrences(of: "data: [DONE]\n\n", with: ""), text + "data: [DONE]\n\n"] {
            XCTAssertThrowsError(try WebsiteTurnContinuation(request: first, encodedResponse: Data(bad.utf8)))
        }
        XCTAssertThrowsError(try WebsiteTurnContinuation(request: first, encodedResponse: Data(repeating: 32, count: 1_024 * 1_024 + 1)))
        let nested = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        let deep = try WebModelResponseCodec.prepareRequest(Data("{\"model\":\"browser/gemini\",\"input\":[{\"value\":\(nested)}]}".utf8))
        XCTAssertThrowsError(try WebsiteTurnContinuation.validateRequest(deep))
    }

    private func user(_ text: String) -> [[String: Any]] { [["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]] }
    private func object(input: Any, stream: Bool = true) -> [String: Any] {
        ["model": model, "input": input, "instructions": "Use only the offered native tools.", "stream": stream, "tools": tools]
    }
    private func prepare(_ object: [String: Any]) throws -> WebModelResponseCodec.Request {
        try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    private func request(input: [[String: Any]], stream: Bool = true) throws -> WebModelResponseCodec.Request { try prepare(object(input: input, stream: stream)) }
    private func encoded(_ reply: WebModelResponseCodec.Reply, request: WebModelResponseCodec.Request, id: String = "resp_first") throws -> Data {
        try request.stream ? WebModelResponseCodec.streamData(for: reply, request: request, responseID: id, createdAt: 1)
            : WebModelResponseCodec.completedResponse(for: reply, request: request, responseID: id, createdAt: 1)
    }
    private func nativeItems(_ reply: WebModelResponseCodec.Reply, request: WebModelResponseCodec.Request, id: String = "resp_first") throws -> [[String: Any]] {
        let data = try WebModelResponseCodec.completedResponse(for: reply, request: request, responseID: id, createdAt: 1)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(response["output"] as? [[String: Any]]).map { item in
            var result = item
            if ["message", "function_call"].contains(item["type"] as? String ?? "") { result.removeValue(forKey: "status") }
            if var content = item["content"] as? [[String: Any]] {
                for index in content.indices { content[index].removeValue(forKey: "annotations") }
                result["content"] = content
            }
            return result
        }
    }
    private func outputs(for items: [[String: Any]]) -> [[String: Any]] {
        items.compactMap { item in
            guard let type = item["type"] as? String, type != "message", let callID = item["call_id"] as? String else { return nil }
            return ["type": type == "function_call" ? "function_call_output" : "custom_tool_call_output", "call_id": callID, "output": "Native result: 2 tests passed. Preserve - / _ and café."]
        }
    }
}

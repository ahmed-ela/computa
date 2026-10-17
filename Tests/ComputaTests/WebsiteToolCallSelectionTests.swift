import Foundation
import XCTest
@testable import Computa

final class WebsiteToolCallSelectionTests: XCTestCase {
    private let initialInput: [[String: Any]] = [
        ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Run the tests, then use their result to decide the next action."]]],
    ]
    private var tools: [[String: Any]] { [
        ["type": "namespace", "name": "functions", "tools": [
            ["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]],
            ["type": "function", "name": "browser_read", "parameters": ["type": "object", "properties": [:]]],
            ["type": "custom", "name": "apply_patch"],
        ]],
    ] }
    private let first = WebModelResponseCodec.ToolCall(name: "exec_command", argumentsJSON: #"{"cmd":"python3 -m unittest"}"#, namespace: "functions")
    private let later = WebModelResponseCodec.ToolCall(name: "exec_command", argumentsJSON: #"{"cmd":"python3 flight_helper.py"}"#, namespace: "functions")

    func testSelectsOnlyFirstCallAndRetainsExactCommentaryAndArguments() throws {
        let commentary = "  Inspecting cafe\u{301}; next action depends on the result. 🌍\n"
        let result = try WebsiteToolCallSelection.select(validatedReply: .toolCallsWithCommentary([first, later], commentary), singleAction: true)
        guard case let .toolCallsWithCommentary(calls, text) = result.reply else { return XCTFail("Expected commentary and one call") }
        XCTAssertEqual(calls, [first])
        XCTAssertEqual(Array(text.utf8), Array(commentary.utf8))
        XCTAssertEqual(Array(calls[0].argumentsJSON.utf8), Array(first.argumentsJSON.utf8))
        try assertMetadata(result, proposed: 2, selected: 1, notSelected: 1)
    }

    func testCustomPatchInputRemainsLiteralAndLaterCallsAreAbsent() throws {
        let patch = "*** Begin Patch\n*** Update File: cafe\u{301}.py\n@@\n-old\n+\"literal; && \\n\" 🌍\n*** End Patch\n"
        let custom = WebModelResponseCodec.ToolCall(name: "apply_patch", argumentsJSON: "", namespace: "functions", customInput: patch)
        let result = try WebsiteToolCallSelection.select(validatedReply: .toolCalls([custom, first]), singleAction: true)
        guard case let .toolCalls(calls) = result.reply else { return XCTFail("Expected one custom call") }
        XCTAssertEqual(calls, [custom])
        XCTAssertEqual(Array(try XCTUnwrap(calls[0].customInput).utf8), Array(patch.utf8))
        try assertMetadata(result, proposed: 2, selected: 1, notSelected: 1)
    }

    func testMessagesPhasesAndWhitespaceRemainExactWithZeroCallAccounting() throws {
        let text = "  Literal café and cafe\u{301}, quoted `;` and \\n.\n"
        let replies: [WebModelResponseCodec.Reply] = [
            .message(text), .assistantMessage(text, phase: .commentary), .assistantMessage(text, phase: .finalAnswer),
        ]
        for reply in replies {
            let result = try WebsiteToolCallSelection.select(validatedReply: reply, singleAction: true)
            XCTAssertEqual(result.reply, reply)
            switch result.reply {
            case let .message(value), let .assistantMessage(value, _):
                XCTAssertEqual(Array(value.utf8), Array(text.utf8))
            default: XCTFail("Message was converted into an action")
            }
            try assertMetadata(result, proposed: 0, selected: 0, notSelected: 0)
        }
    }

    func testDisabledSelectionLeavesOriginalBatchAndMetadataUnchanged() throws {
        for reply in [WebModelResponseCodec.Reply.toolCalls([first, later]), .toolCallsWithCommentary([first, later], "Both proposed.")] {
            let result = try WebsiteToolCallSelection.select(validatedReply: reply, singleAction: false)
            XCTAssertEqual(result.reply, reply)
            XCTAssertEqual(result.proposedCount, 2)
            XCTAssertEqual(result.selectedCount, 2)
            XCTAssertEqual(result.notSelectedCount, 0)
            XCTAssertNil(result.metadataValue)
        }
    }

    func testEnabledSelectionRetainsNativeBatchLimitBeforeTakingPrefix() throws {
        let boundary = try WebsiteToolCallSelection.select(validatedReply: .toolCalls(Array(repeating: first, count: 64)), singleAction: true)
        XCTAssertEqual(boundary.reply, .toolCalls([first]))
        try assertMetadata(boundary, proposed: 64, selected: 1, notSelected: 63)
        for calls in [[], Array(repeating: first, count: 65)] as [[WebModelResponseCodec.ToolCall]] {
            for reply in [WebModelResponseCodec.Reply.toolCalls(calls), .toolCallsWithCommentary(calls, "Plan")] {
                XCTAssertThrowsError(try WebsiteToolCallSelection.select(validatedReply: reply, singleAction: true)) {
                    XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .invalidResponse)
                }
            }
        }
        let disabled = try WebsiteToolCallSelection.select(validatedReply: .toolCalls(Array(repeating: first, count: 65)), singleAction: false)
        XCTAssertEqual(disabled.selectedCount, 65)
        XCTAssertNil(disabled.metadataValue)
    }

    func testWholeEnvelopeMustValidateBeforeSelectionIncludingInvalidTail() throws {
        let valid: [String: Any] = ["name": "functions.exec_command", "arguments": ["cmd": "python3 -m unittest"]]
        let invalidTails: [[String: Any]] = [
            ["name": "functions.unoffered", "arguments": [:]],
            ["name": "functions.exec_command", "arguments": ["not an object"]],
            ["name": "functions.exec_command", "arguments": [:], "input": "ambiguous"],
            ["name": "functions.apply_patch", "input": 1],
        ]
        let request = try prepare()
        for tail in invalidTails {
            let text = try envelope(calls: [valid, tail])
            XCTAssertThrowsError(try parseAndSelect(text, request: request))
        }
        let validBatch = try envelope(calls: [valid, valid])
        for (options, expected) in [
            (["parallel_tool_calls": false] as [String: Any], WebModelResponseCodec.Failure.parallelToolCallsUnsupported),
            (["max_tool_calls": 1] as [String: Any], .toolCallLimitExceeded),
            (["tool_choice": "none"] as [String: Any], .rejectedToolChoice),
        ] {
            XCTAssertThrowsError(try parseAndSelect(validBatch, request: prepare(options: options))) {
                XCTAssertEqual($0 as? WebModelResponseCodec.Failure, expected)
            }
        }
        let forced = try prepare(options: ["tool_choice": ["type": "function", "name": "functions.exec_command"]])
        let forbiddenTail = try envelope(calls: [valid, ["name": "functions.browser_read", "arguments": [:]]])
        XCTAssertThrowsError(try parseAndSelect(forbiddenTail, request: forced)) {
            XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .rejectedToolChoice)
        }
        XCTAssertThrowsError(try parseAndSelect(validBatch + "\nUntrusted trailing prose", request: request))
    }

    func testBothWireModesEmitOnlySelectedCallAndTrustedFiniteMetadata() throws {
        let selection = try WebsiteToolCallSelection.select(validatedReply: .toolCallsWithCommentary([first, later], "Running the tests."), singleAction: true)
        let request = try prepare(options: ["metadata": ["computa_website_tool_selection": "untrusted caller value"]])
        let response = try completed(selection, request: request)
        let stream = try WebModelResponseCodec.streamData(for: selection.reply, request: request,
            responseID: "resp_selection", createdAt: 123, websiteToolSelection: selection.metadataValue)
        let events = try streamEvents(stream)
        let streamed = try XCTUnwrap(events.last?["response"] as? [String: Any])
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        XCTAssertEqual(output.map { $0["type"] as? String }, ["message", "function_call"])
        XCTAssertEqual(output[1]["name"] as? String, "exec_command")
        XCTAssertEqual(output[1]["arguments"] as? String, first.argumentsJSON)
        XCTAssertEqual(output[1]["call_id"] as? String, "call_selection_0")
        XCTAssertEqual(try canonical(output), try canonical(try XCTUnwrap(streamed["output"])))
        XCTAssertFalse(String(decoding: stream, as: UTF8.self).contains("flight_helper.py"))
        XCTAssertFalse(String(decoding: stream, as: UTF8.self).contains("call_selection_1"))
        for value in [response, streamed] {
            XCTAssertEqual((value["metadata"] as? [String: Any])?["computa_website_tool_selection"] as? String, selection.metadataValue)
            XCTAssertTrue(value["usage"] is NSNull)
            XCTAssertEqual(value["end_turn"] as? Bool, false)
        }
    }

    func testBothWireModesKeepSelectedCustomInputExact() throws {
        let patch = "*** Begin Patch\n*** Update File: café.py\n@@\n-old\n+literal \\n \"quotes\" ; &&\n*** End Patch\n"
        let custom = WebModelResponseCodec.ToolCall(name: "apply_patch", argumentsJSON: "", namespace: "functions", customInput: patch)
        let selection = try WebsiteToolCallSelection.select(validatedReply: .toolCalls([custom, later]), singleAction: true)
        let request = try prepare()
        let ordinary = try completed(selection, request: request)
        let events = try streamEvents(WebModelResponseCodec.streamData(for: selection.reply, request: request,
            responseID: "resp_selection", createdAt: 123, websiteToolSelection: selection.metadataValue))
        let streamed = try XCTUnwrap(events.last?["response"] as? [String: Any])
        for response in [ordinary, streamed] {
            let output = try XCTUnwrap(response["output"] as? [[String: Any]])
            XCTAssertEqual(output.count, 1)
            XCTAssertEqual(output[0]["type"] as? String, "custom_tool_call")
            XCTAssertEqual(output[0]["namespace"] as? String, "functions")
            XCTAssertEqual(Array(try XCTUnwrap(output[0]["input"] as? String).utf8), Array(patch.utf8))
            XCTAssertNil(output[0]["arguments"])
        }
        XCTAssertEqual(try canonical(try XCTUnwrap(ordinary["output"])), try canonical(try XCTUnwrap(streamed["output"])))
    }

    func testNativeContinuationRequiresOnlySelectedResultAndRejectsForgedTail() throws {
        for stream in [false, true] {
            let request = try prepare(options: ["stream": stream])
            let selection = try WebsiteToolCallSelection.select(validatedReply: .toolCalls([first, later]), singleAction: true)
            let bytes = try encoded(selection, request: request)
            let state = try WebsiteTurnContinuation(request: request, encodedResponse: bytes)
            XCTAssertEqual(state.pendingToolCallCount, 1)
            let emitted = try nativeItems(selection, request: request)
            let result: [[String: Any]] = [["type": "function_call_output", "call_id": "call_selection_0",
                                          "output": "Tests failed.\nProcess exited with code 1\n"]]
            let next = try prepare(input: initialInput + emitted + result, options: ["stream": stream])
            try state.validate(next: next)
            XCTAssertThrowsError(try state.validate(next: prepare(input: initialInput + emitted, options: ["stream": stream])))
            let forged: [[String: Any]] = [["type": "function_call_output", "call_id": "call_selection_1", "output": "Invented helper success"]]
            for results in [forged, result + forged] {
                XCTAssertThrowsError(try state.validate(next: prepare(input: initialInput + emitted + results, options: ["stream": stream]))) {
                    XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .invalidToolOutputs)
                }
            }
            var rewritten = emitted
            rewritten[0]["arguments"] = later.argumentsJSON
            XCTAssertThrowsError(try state.validate(next: prepare(input: initialInput + rewritten + result, options: ["stream": stream]))) {
                XCTAssertEqual($0 as? WebsiteTurnContinuation.Failure, .changedHistory)
            }
            // Selecting a later inference is stateless: it never drains the
            // previous tail. A final message remains a final message.
            let final = try WebsiteToolCallSelection.select(validatedReply: .message("Tests failed; no helper was run."), singleAction: true)
            XCTAssertEqual(final.reply, .message("Tests failed; no helper was run."))
            XCTAssertEqual(final.selectedCount, 0)
        }
    }

    private func assertMetadata(_ selection: WebsiteToolCallSelection.Selection, proposed: Int, selected: Int,
                                notSelected: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(selection.proposedCount, proposed, file: file, line: line)
        XCTAssertEqual(selection.selectedCount, selected, file: file, line: line)
        XCTAssertEqual(selection.notSelectedCount, notSelected, file: file, line: line)
        let value = try XCTUnwrap(selection.metadataValue, file: file, line: line)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any], file: file, line: line)
        XCTAssertEqual(Set(fields.keys), ["policy", "version", "proposedCount", "selectedCount", "notSelectedCount"], file: file, line: line)
        XCTAssertEqual(fields["policy"] as? String, "single_action_per_inference", file: file, line: line)
        XCTAssertEqual(fields["version"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(fields["proposedCount"] as? Int, proposed, file: file, line: line)
        XCTAssertEqual(fields["selectedCount"] as? Int, selected, file: file, line: line)
        XCTAssertEqual(fields["notSelectedCount"] as? Int, notSelected, file: file, line: line)
    }

    private func prepare(input: [[String: Any]]? = nil, options: [String: Any] = [:]) throws -> WebModelResponseCodec.Request {
        var object: [String: Any] = ["model": "browser/chatgpt", "input": input ?? initialInput, "tools": tools]
        object.merge(options) { _, supplied in supplied }
        return try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: object))
    }

    private func envelope(calls: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": calls]), as: UTF8.self)
    }

    private func parseAndSelect(_ text: String, request: WebModelResponseCodec.Request) throws -> WebsiteToolCallSelection.Selection {
        let validated = try WebModelResponseCodec.parseEmbeddedReply(text, request: request)
        return try WebsiteToolCallSelection.select(validatedReply: validated, singleAction: true)
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func completed(_ selection: WebsiteToolCallSelection.Selection, request: WebModelResponseCodec.Request) throws -> [String: Any] {
        let data = try WebModelResponseCodec.completedResponse(for: selection.reply, request: request,
            responseID: "resp_selection", createdAt: 123, websiteToolSelection: selection.metadataValue)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encoded(_ selection: WebsiteToolCallSelection.Selection, request: WebModelResponseCodec.Request) throws -> Data {
        try request.stream
            ? WebModelResponseCodec.streamData(for: selection.reply, request: request, responseID: "resp_selection", websiteToolSelection: selection.metadataValue)
            : WebModelResponseCodec.completedResponse(for: selection.reply, request: request, responseID: "resp_selection", websiteToolSelection: selection.metadataValue)
    }

    private func nativeItems(_ selection: WebsiteToolCallSelection.Selection, request: WebModelResponseCodec.Request) throws -> [[String: Any]] {
        var items = try XCTUnwrap(try completed(selection, request: request)["output"] as? [[String: Any]])
        for index in items.indices {
            if items[index]["type"] as? String != "custom_tool_call" { items[index].removeValue(forKey: "status") }
        }
        return items
    }

    private func streamEvents(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n").filter {
            !$0.isEmpty && $0 != "data: [DONE]"
        }.map { record in
            let lines = record.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 2)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].dropFirst(6).utf8)) as? [String: Any])
        }
    }
}

import Foundation
import XCTest
@testable import Computa

final class WebModelResponseCodecTests: XCTestCase {
    private let function: [String: Any] = [
        "type": "function", "name": "computer_v2_snapshot", "description": "Read a bound app",
        "parameters": ["type": "object", "properties": ["view": ["type": "string"]], "required": ["view"]],
    ]

    private func request(tools: [[String: Any]]? = nil) throws -> WebModelResponseCodec.Request {
        try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: [
            "model": "web-chatgpt", "input": "Read the app", "tools": tools ?? [function],
        ]))
    }

    private func events(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { record in
            let lines = record.components(separatedBy: "\n")
            let payload = try XCTUnwrap(lines.first(where: { $0.hasPrefix("data: ") }))
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.dropFirst(6).utf8)) as? [String: Any])
            XCTAssertEqual(lines.first, "event: \(event["type"] as? String ?? "")")
            return event
        }
    }

    func testEntireOriginalRequestSurvivesIncludingRolesSchemasAndToolOutputs() throws {
        let original = #"{"model":"web-gemini","instructions":"Keep every constraint","input":[{"role":"developer","content":[{"type":"input_text","text":"Use only observed targets"}]},{"role":"user","content":"Read résumé 🌍"},{"type":"function_call","name":"computer_v2_snapshot","call_id":"call_original","arguments":"{\"view\":\"content\"}"},{"type":"function_call_output","call_id":"call_original","output":"  exact tool output\nnext line  "}],"tools":[{"type":"function","name":"computer_v2_snapshot","description":"Never guess references","parameters":{"type":"object","properties":{"view":{"enum":["content","overview"]}},"required":["view"],"additionalProperties":false}}],"parallel_tool_calls":false,"tool_choice":"auto"}"#
        let prepared = try WebModelResponseCodec.prepareRequest(Data(original.utf8))
        XCTAssertTrue(prepared.prompt.hasSuffix(original))
        XCTAssertEqual(prepared.model, "web-gemini")
        XCTAssertEqual(prepared.offeredToolNames, ["computer_v2_snapshot"])
        XCTAssertTrue(prepared.prompt.contains("exactly one JSON object"))
    }

    func testRejectsTooLargeRequestWithoutTruncatingOrSubmitting() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "web-chatgpt", "input": String(repeating: "🌍", count: 41_000),
        ])
        XCTAssertThrowsError(try WebModelResponseCodec.prepareRequest(body)) { error in
            guard case let .promptTooLarge(actual, maximum) = error as? WebModelResponseCodec.Failure else {
                return XCTFail("Expected an explicit context limit error")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 163_840)
            XCTAssertTrue(error.localizedDescription.contains("No context was truncated or submitted"))
        }
    }

    func testLimitIncludesBridgeInstructionsAndSchemas() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "web-chatgpt", "input": String(repeating: "x", count: 163_500),
        ])
        XCTAssertLessThan(body.count, WebModelResponseCodec.maximumPromptBytes)
        XCTAssertThrowsError(try WebModelResponseCodec.prepareRequest(body)) { error in
            guard case .promptTooLarge = error as? WebModelResponseCodec.Failure else {
                return XCTFail("The full prompt, including the protocol instructions, must fit")
            }
        }
    }

    func testRejectsMissingContextAndMalformedRequestShapes() {
        let fixtures: [(String, WebModelResponseCodec.Failure)] = [
            ("not JSON", .invalidRequest), ("[]", .invalidRequest),
            (#"{"input":"hello"}"#, .missingModel),
            (#"{"model":" ","input":"hello"}"#, .missingModel),
            (#"{"model":"web-chatgpt","input":false}"#, .missingInput),
            (#"{"model":"web-chatgpt","input":[],"previous_response_id":"resp_old"}"#, .previousResponseUnsupported),
            (#"{"model":"web-chatgpt","input":[],"instructions":{}}"#, .invalidRequest),
            (#"{"model":"web-chatgpt","input":[],"tools":{}}"#, .invalidTools),
            (#"{"model":"web-chatgpt","input":[],"tools":[{"type":"web_search"}]}"#, .unsupportedToolType),
        ]
        for (body, expected) in fixtures {
            XCTAssertThrowsError(try WebModelResponseCodec.prepareRequest(Data(body.utf8))) {
                XCTAssertEqual($0 as? WebModelResponseCodec.Failure, expected)
            }
        }
    }

    func testNestedMessageImageContentIsRejectedBeforePromptPreparation() throws {
        for messageType in [nil, "message"] as [String?] {
            var message: [String: Any] = [
                "role": "user", "content": [
                    ["type": "input_text", "text": "Read this screenshot"],
                    ["type": "input_image", "image_url": "data:image/png;base64,aW1hZ2U=", "detail": "high"],
                ],
            ]
            if let messageType { message["type"] = messageType }
            let data = try JSONSerialization.data(withJSONObject: ["model": "browser/chatgpt", "input": [message]])
            XCTAssertThrowsError(try WebModelResponseCodec.prepareRequest(data)) { error in
                XCTAssertEqual(error as? WebModelResponseCodec.Failure, .unsupportedModality(.image))
                XCTAssertTrue(error.localizedDescription.contains("No prompt was submitted"))
            }
        }
    }

    func testNestedMessageAudioContentRejectsAPIAndCodexRepresentations() throws {
        for audio in [
            ["type": "input_audio", "input_audio": ["data": "YXVkaW8=", "format": "wav"]],
            ["type": "input_audio", "audio_url": "data:audio/wav;base64,YXVkaW8="],
        ] as [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: [
                "model": "browser/gemini", "input": [
                    ["type": "message", "role": "user", "content": [audio]],
                ],
            ])
            XCTAssertThrowsError(try WebModelResponseCodec.prepareRequest(data)) { error in
                XCTAssertEqual(error as? WebModelResponseCodec.Failure, .unsupportedModality(.audio))
                XCTAssertTrue(error.localizedDescription.contains("No prompt was submitted"))
            }
        }
    }

    func testStructuredToolImageAndAudioOutputsAreRejected() throws {
        for itemType in ["function_call_output", "custom_tool_call_output"] {
            for (partType, modality) in [
                ("input_image", WebModelResponseCodec.Modality.image), ("input_audio", .audio),
            ] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "model": "browser/chatgpt", "input": [[
                        "type": itemType, "call_id": "observed_call", "output": [
                            ["type": "input_text", "text": "Structured observation"], ["type": partType],
                        ],
                    ]],
                ])
                XCTAssertThrowsError(try WebModelResponseCodec.prepareRequest(data)) {
                    XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .unsupportedModality(modality))
                }
            }
        }
    }

    func testQuotedModalityExamplesRemainTextAndArePreservedExactly() throws {
        let imageExample = #"{"type":"input_image","image_url":"data:image/png;base64,example"}"#
        let audioExample = #"{"type":"input_audio","input_audio":{"data":"example","format":"wav"}}"#
        let body: [String: Any] = [
            "model": "browser/chatgpt", "instructions": "Explain input_image and input_audio schemas",
            "input": [
                ["role": "user", "content": imageExample],
                ["type": "message", "role": "user", "content": [
                    ["type": "input_text", "text": audioExample, "quoted_example": ["type": "input_image"]],
                ]],
                ["type": "function_call", "name": "computer_v2_snapshot", "arguments": imageExample, "call_id": "example_call"],
                ["type": "function_call_output", "call_id": "example_call", "output": audioExample],
                ["type": "function_call_output", "call_id": "other_call", "output": [
                    ["type": "input_text", "text": imageExample, "quoted_example": ["type": "input_audio"]],
                ]],
            ],
            "metadata": ["type": "input_image"],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let prepared = try WebModelResponseCodec.prepareRequest(data)
        XCTAssertTrue(prepared.prompt.hasSuffix(String(decoding: data, as: UTF8.self)))
        let plain = try JSONSerialization.data(withJSONObject: ["model": "browser/chatgpt", "input": audioExample])
        XCTAssertNoThrow(try WebModelResponseCodec.prepareRequest(plain))
    }

    func testOrdinaryTextCodeAndUnrelatedJSONRemainFinalMessages() throws {
        let prepared = try request()
        for text in ["  Hello 🌍\n ", "```swift\nlet x = 1\n```", #"{"type":"report","text":"keep this JSON"}"#, #"{"answer":42}"#] {
            XCTAssertEqual(try WebModelResponseCodec.parseReply(text, request: prepared), .message(text))
        }
        XCTAssertEqual(try WebModelResponseCodec.parseReply(#"{"type":"message","text":" exact\nanswer "}"#, request: prepared), .message(" exact\nanswer "))
    }

    func testFencedToolEnvelopeBecomesOfferedToolWithJSONArguments() throws {
        let prepared = try request()
        let text = "```JSON\n" + #"{"type":"tool_calls","calls":[{"name":"computer_v2_snapshot","arguments":{"view":"content","path":"https://example.com/α","nested":{"x":[true,null,3]}}}]}"# + "\n```"
        guard case let .toolCalls(calls) = try WebModelResponseCodec.parseReply(text, request: prepared) else {
            return XCTFail("Expected a tool request")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "computer_v2_snapshot")
        XCTAssertNil(calls[0].namespace)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[0].argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(args["view"] as? String, "content")
        XCTAssertEqual(args["path"] as? String, "https://example.com/α")
        XCTAssertNotNil(args["nested"])
    }

    func testArgumentSchemaValidationStaysInExistingHarness() throws {
        // The codec only checks offered names and JSON object shape; the real
        // local tool contract is responsible for argument semantics.
        let prepared = try request()
        guard case let .toolCalls(calls) = try WebModelResponseCodec.parseReply(
            #"{"type":"tool_calls","calls":[{"name":"computer_v2_snapshot","arguments":{}}]}"#, request: prepared
        ) else { return XCTFail("Expected a tool request") }
        XCTAssertEqual(calls[0].argumentsJSON, "{}")
    }

    func testUnknownMalformedAndStringEncodedToolCallsFailClosed() throws {
        let prepared = try request()
        let fixtures: [(String, WebModelResponseCodec.Failure)] = [
            (#"{"type":"tool_calls","calls":[{"name":"shell","arguments":{}}]}"#, .unknownTool("shell")),
            (#"{"type":"tool_calls","calls":[{"name":"computer_v2_snapshot","arguments":"{}"}]}"#, .argumentsMustBeObject),
            (#"{"type":"tool_calls","calls":[{"name":"computer_v2_snapshot","arguments":[]}]}"#, .argumentsMustBeObject),
            (#"{"type":"tool_calls","calls":[]}"#, .malformedEnvelope),
            (#"{"type":"tool_calls","calls":[{}]}"#, .malformedEnvelope),
            (#"{"type":"tool_calls","calls": [{"name":"computer_v2_snapshot""#, .malformedEnvelope),
            (#"{'type':'tool_calls','calls':[]}"#, .malformedEnvelope),
            (" \n ", .emptyReply),
        ]
        for (text, expected) in fixtures {
            XCTAssertThrowsError(try WebModelResponseCodec.parseReply(text, request: prepared)) {
                XCTAssertEqual($0 as? WebModelResponseCodec.Failure, expected)
            }
        }
    }

    func testAnyBadParallelCallRejectsEntireReply() throws {
        let prepared = try request()
        XCTAssertThrowsError(try WebModelResponseCodec.parseReply(
            #"{"type":"tool_calls","calls":[{"name":"computer_v2_snapshot","arguments":{}},{"name":"invented","arguments":{}}]}"#,
            request: prepared
        )) { XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .unknownTool("invented")) }
    }

    func testNamespaceCallsRoundTripAsSeparateWireNameAndNamespace() throws {
        let prepared = try request(tools: [["type": "namespace", "name": "functions", "tools": [function]]])
        XCTAssertEqual(prepared.offeredToolNames, ["functions.computer_v2_snapshot"])
        let reply = try WebModelResponseCodec.parseReply(
            #"{"type":"tool_calls","calls":[{"name":"functions.computer_v2_snapshot","arguments":{"view":"content"}}]}"#,
            request: prepared
        )
        let emitted = try events(WebModelResponseCodec.streamData(for: reply, request: prepared, responseID: "resp_namespace", createdAt: 123))
        let done = try XCTUnwrap(emitted.first(where: { $0["type"] as? String == "response.output_item.done" })?["item"] as? [String: Any])
        XCTAssertEqual(done["name"] as? String, "computer_v2_snapshot")
        XCTAssertEqual(done["namespace"] as? String, "functions")
    }

    func testDuplicateToolAliasesAreRejected() throws {
        XCTAssertThrowsError(try request(tools: [function, function])) {
            XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .invalidTools)
        }
        let collision = ["type": "function", "name": "functions.computer_v2_snapshot", "parameters": ["type": "object"]] as [String: Any]
        XCTAssertThrowsError(try request(tools: [collision, ["type": "namespace", "name": "functions", "tools": [function]]])) {
            XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .invalidTools)
        }
    }

    func testMessageStreamHasCompleteOrderedEventsAndExactText() throws {
        let prepared = try request()
        let text = "  Hello 🌍\nnext line\u{2028}last  "
        let emitted = try events(WebModelResponseCodec.streamData(for: .message(text), request: prepared, responseID: "resp_fixture", createdAt: 123))
        XCTAssertEqual(emitted.map { $0["type"] as? String }, [
            "response.created", "response.in_progress", "response.output_item.added", "response.content_part.added",
            "response.output_text.delta", "response.output_text.done", "response.content_part.done", "response.output_item.done", "response.completed",
        ])
        XCTAssertEqual(emitted.compactMap { $0["sequence_number"] as? Int }, Array(0..<emitted.count))
        XCTAssertEqual(emitted[4]["delta"] as? String, text)
        XCTAssertEqual(emitted[5]["text"] as? String, text)
        for index in [3, 4, 5, 6] {
            XCTAssertEqual(emitted[index]["item_id"] as? String, "msg_fixture")
            XCTAssertEqual(emitted[index]["output_index"] as? Int, 0)
            XCTAssertEqual(emitted[index]["content_index"] as? Int, 0)
        }
        let final = try XCTUnwrap(emitted.last?["response"] as? [String: Any])
        XCTAssertEqual(final["id"] as? String, "resp_fixture")
        XCTAssertEqual(final["model"] as? String, "web-chatgpt")
        XCTAssertEqual(final["created_at"] as? Int, 123)
        XCTAssertEqual(final["status"] as? String, "completed")
        XCTAssertEqual(final["output_text"] as? String, text)
        XCTAssertEqual(final["end_turn"] as? Bool, true)
        XCTAssertTrue(final["usage"] is NSNull, "The website has no verified token counts")
        let output = try XCTUnwrap(final["output"] as? [[String: Any]])
        let done = try XCTUnwrap(emitted[7]["item"] as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: output[0]).isEqual(to: done))
        let content = try XCTUnwrap(output[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, text)
    }

    func testParallelFunctionCallsHaveUniqueIDsConsistentArgumentsAndCompletedItems() throws {
        let prepared = try request()
        let reply = try WebModelResponseCodec.parseReply(
            #"{"type":"tool_calls","calls":[{"name":"computer_v2_snapshot","arguments":{"view":"overview"}},{"name":"computer_v2_snapshot","arguments":{"view":"content"}}]}"#,
            request: prepared
        )
        let emitted = try events(WebModelResponseCodec.streamData(for: reply, request: prepared, responseID: "resp_calls", createdAt: 123))
        XCTAssertEqual(emitted.map { $0["type"] as? String }, [
            "response.created", "response.in_progress", "response.output_item.added", "response.function_call_arguments.delta",
            "response.function_call_arguments.done", "response.output_item.done", "response.output_item.added",
            "response.function_call_arguments.delta", "response.function_call_arguments.done", "response.output_item.done", "response.completed",
        ])
        let final = try XCTUnwrap(emitted.last?["response"] as? [String: Any])
        XCTAssertEqual(final["end_turn"] as? Bool, false)
        XCTAssertEqual(final["output_text"] as? String, "")
        let output = try XCTUnwrap(final["output"] as? [[String: Any]])
        XCTAssertEqual(Set(output.compactMap { $0["call_id"] as? String }).count, 2)
        XCTAssertEqual(Set(output.compactMap { $0["id"] as? String }).count, 2)
        for (index, start) in [2, 6].enumerated() {
            let pending = try XCTUnwrap(emitted[start]["item"] as? [String: Any])
            let done = try XCTUnwrap(emitted[start + 3]["item"] as? [String: Any])
            XCTAssertEqual(pending["arguments"] as? String, "")
            XCTAssertEqual(pending["status"] as? String, "in_progress")
            XCTAssertEqual(done["status"] as? String, "completed")
            XCTAssertEqual(emitted[start + 1]["delta"] as? String, done["arguments"] as? String)
            XCTAssertEqual(emitted[start + 2]["arguments"] as? String, done["arguments"] as? String)
            XCTAssertEqual(emitted[start + 1]["item_id"] as? String, done["id"] as? String)
            XCTAssertEqual(emitted[start + 2]["call_id"] as? String, done["call_id"] as? String)
            XCTAssertEqual(emitted[start + 3]["output_index"] as? Int, index)
            XCTAssertTrue(NSDictionary(dictionary: output[index]).isEqual(to: done))
        }
    }

    func testNonStreamingResponseSharesTheSameStableOutputContract() throws {
        let prepared = try request()
        let emitted = try events(WebModelResponseCodec.streamData(for: .message("done"), request: prepared, responseID: "resp_stable", createdAt: 123))
        let streamFinal = try XCTUnwrap(emitted.last?["response"] as? [String: Any])
        let ordinary = try XCTUnwrap(JSONSerialization.jsonObject(with: WebModelResponseCodec.completedResponse(
            for: .message("done"), request: prepared, responseID: "resp_stable", createdAt: 123
        )) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: ordinary).isEqual(to: streamFinal))
    }
}

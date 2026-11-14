import Foundation
import XCTest
@testable import Computa

final class QwenWebsiteResponseFormatTests: XCTestCase {
    func testOnlyQwenRequestsCodePayloadWhilePreservingAuthorityAndOriginalRequest() throws {
        let providers = ["qwen", "kimi", "claude", "gemini", "chatgpt", "groq"]
        for provider in providers {
            let choice: WebsiteModelChoice
            switch provider {
            case "qwen": choice = .init(provider: provider, key: "Qwen3.8-Max", label: "Qwen3.8-Max")
            case "kimi": choice = syntheticKimiChoice
            case "chatgpt": choice = syntheticChatGPTChoice
            default: choice = .init(provider: provider, key: "fixture", label: "Fixture")
            }
            let raw = try requestData(choice.modelID)
            let request = try WebModelResponseCodec.prepareRequest(raw)
            XCTAssertEqual(request.continuationRequest, raw)
            XCTAssertEqual(request.offeredToolNames, ["exec_command"])
            XCTAssertFalse(request.prompt.contains("Return exactly one raw JSON object."))
            XCTAssertTrue(request.prompt.contains("Return exactly one fenced JSON code block labelled json."))
            XCTAssertEqual(request.prompt.contains(ComputaAgentInstructions.codePayloadResponseBoundary), provider == "qwen")
            XCTAssertTrue(request.prompt.contains("This website does not execute calls."))
        }
    }

    func testQwenCodePayloadAndLegacyPlainJSONPreserveLiteralToolArgumentsWithoutRepair() throws {
        let command = "printf '%s' 'report-`x`-**y**.txt'\n    # café 😀 \\n"
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let choice = WebsiteModelChoice(provider: "qwen", key: label, label: label)
            let original = try requestData(choice.modelID)
            let request = try WebModelResponseCodec.prepareRequest(original)
            let data = try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [[
                "name": "exec_command", "arguments": ["cmd": command]
            ]]])
            let payload = String(decoding: data, as: UTF8.self)
            // Both DOM paths supply their complete literal JSON payload.
            guard case let .toolCalls(calls) = try WebModelResponseCodec.parseEmbeddedReply(payload, request: request) else {
                return XCTFail("Expected one allowed function call")
            }
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(calls[0].argumentsJSON.utf8)), ["cmd": command])
            XCTAssertEqual(request.continuationRequest, original)
            XCTAssertLessThan(request.prompt.utf8.count, WebModelResponseCodec.maximumPromptBytes)
            for invalid in ["Outside\n" + payload, payload + "\nOutside", payload + payload, "{\"type\":\"tool_calls\","] {
                XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(invalid, request: request))
            }
            let denied = try WebModelResponseCodec.prepareRequest(requestData(choice.modelID, toolChoice: "none"))
            XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(payload, request: denied))
        }
    }

    func testRawQwenEnvelopeKeepsWholeResponseParsingAndToolPolicy() throws {
        let choice = WebsiteModelChoice(provider: "qwen", key: "Qwen3.8-Max", label: "Qwen3.8-Max")
        let request = try WebModelResponseCodec.prepareRequest(requestData(choice.modelID))
        let valid = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf fixture"}}]}"#
        XCTAssertNoThrow(try WebModelResponseCodec.parseEmbeddedReply(valid, request: request))
        for invalid in ["Explanation before\n" + valid, valid + "\nExplanation after",
                        #"{"type":"tool_calls","calls":[{"name":"unoffered","arguments":{"cmd":"printf fixture"}}]}"#,
                        #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":"printf fixture"}]}"#] {
            XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(invalid, request: request))
        }
        let denied = try WebModelResponseCodec.prepareRequest(requestData(choice.modelID, toolChoice: "none"))
        XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(valid, request: denied))
    }

    private func requestData(_ model: String, toolChoice: String = "auto") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model,
            "instructions": "Only propose actions using the offered tool; preserve user permissions.",
            "input": "Read the synthetic fixture only.", "tool_choice": toolChoice,
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object",
                "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]]]
        ] as [String: Any])
    }
}

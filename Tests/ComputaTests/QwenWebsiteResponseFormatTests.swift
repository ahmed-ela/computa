import Foundation
import XCTest
@testable import Computa

final class QwenWebsiteResponseFormatTests: XCTestCase {
    func testOnlyQwenRequestsRawEnvelopeWhilePreservingAuthorityAndOriginalRequest() throws {
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
            XCTAssertEqual(request.prompt.contains("Return exactly one raw JSON object."), provider == "qwen")
            XCTAssertEqual(request.prompt.contains("Return exactly one fenced JSON code block labelled json."), provider != "qwen")
            XCTAssertTrue(request.prompt.contains("This website does not execute calls."))
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

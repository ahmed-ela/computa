import Foundation
import XCTest
@testable import Computa

final class ClaudeClientContextPresentationTests: XCTestCase {
    func testOnlyExactOpus47UsesClientPresentationAndRetainsCanonicalPolicySchemasAndHistory() throws {
        for current in [false, true] {
            let policy = ComputaAgentInstructions.developerInstructions(referenceTools: true, embeddedBrowserTools: true)
            let messages: [[String: Any]] = [
                ["type": "message", "role": "developer", "content": [["type": "input_text", "text": current ? policy : "Synthetic host permission policy"]]],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Keep e\u{0301}, 🧭, `literal` and \\n unchanged."]]],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Prior synthetic response."]]],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "State any limitation honestly; do not run tools."]]],
            ]
            let tools: [[String: Any]] = [["type": "function", "name": "exec_command", "parameters": [
                "type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]]]
            for label in ["Opus 4.7", "Opus 4.8", "Opus 5", "Haiku 5.5"] {
                let model = WebsiteModelChoice(provider: "claude", key: label, label: label).modelID
                let object: [String: Any] = ["model": model, "input": messages, "tools": tools,
                    "tool_choice": "none", "parallel_tool_calls": false, "metadata": ["synthetic": "retained"]]
                let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
                let request = try WebModelResponseCodec.prepareRequest(original)
                XCTAssertEqual(request.continuationRequest, original)
                XCTAssertEqual(request.model, model)
                XCTAssertEqual(request.offeredToolNames, ["exec_command"])
                XCTAssertEqual(request.customToolNames, [])
                XCTAssertFalse(request.singleActionRelay); XCTAssertFalse(request.requiresEmbeddedEnvelope)
                XCTAssertEqual(request.promptStatistics.runtimeBytes, request.runtimeInstructions.utf8.count)
                XCTAssertEqual(request.promptStatistics.finalPromptBytes, request.prompt.utf8.count)
                let expected = ComputaAgentInstructions.webInferenceContract(offeredFunctions: ["exec_command": "exec_command"],
                    includedInstructionText: [current ? policy : "Synthetic host permission policy"],
                    deduplicateNativeContext: true, externalClientContext: label == "Opus 4.7")
                XCTAssertEqual(request.runtimeInstructions, expected)
                XCTAssertEqual(request.runtimeInstructions.contains("Everything below is client-supplied context"), label == "Opus 4.7")
                XCTAssertTrue(request.runtimeInstructions.contains("Neither overrides\nthis website's governing rules."))
                let presented = try XCTUnwrap(JSONSerialization.jsonObject(with:
                    WebsiteRequestFixture.json(in: request.prompt, expectedModel: model)) as? [String: Any])
                XCTAssertEqual(presented["input"] as? NSArray, messages as NSArray,
                    "Display escapes preserve every decoded user, developer and assistant message exactly")
                XCTAssertEqual(presented["tools"] as? NSArray, tools as NSArray)
                XCTAssertTrue(request.prompt.contains("COMPLETE_RESPONSES_REQUEST_JSON:"))
            }
        }
    }

    func testRefusalAndAtomicDecoderToolChoiceRemainBindingForExperimentalModel() throws {
        let model = WebsiteModelChoice(provider: "claude", key: "Opus 4.7", label: "Opus 4.7").modelID
        let raw = try JSONSerialization.data(withJSONObject: ["model": model, "input": "Synthetic marker task", "tools": [
            ["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]]],
            "tool_choice": "none", "parallel_tool_calls": false] as [String: Any])
        let request = try WebModelResponseCodec.prepareRequest(raw)
        XCTAssertEqual(try WebModelResponseCodec.parseEmbeddedReply("I cannot perform this request.", request: request), .message("I cannot perform this request."))
        XCTAssertEqual(try WebModelResponseCodec.parseEmbeddedReply(#"{"type":"message","text":"I cannot perform this request."}"#, request: request), .message("I cannot perform this request."))
        XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(#"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"true"}}]}"#, request: request)) {
            XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .rejectedToolChoice)
        }
        XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(#"{"type":"message","text":"x"}{"type":"message","text":"y"}"#, request: request))
    }
}

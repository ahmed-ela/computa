import Foundation
import XCTest
@testable import Computa

final class DeepSeekWebsiteResponseFormatTests: XCTestCase {
    func testRawModeEnvelopePreservesToolsAndWholeResponseRejection() throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let choice = WebsiteModeChoice(deepSeekMode: mode)
            let raw = try requestData(choice)
            let request = try WebModelResponseCodec.prepareRequest(raw)
            XCTAssertEqual(request.continuationRequest, raw)
            XCTAssertEqual(request.offeredToolNames, ["exec_command"])
            XCTAssertTrue(request.prompt.contains("Return exactly one raw JSON object."))
            XCTAssertTrue(request.prompt.contains("This website does not execute calls."))
            XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: choice.requestID)?.modeChoice, choice)
            let valid = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf fixture"}}]}"#
            XCTAssertNoThrow(try WebModelResponseCodec.parseEmbeddedReply(valid, request: request))
            for invalid in ["Intro\n" + valid, valid + "\nAfterword",
                            valid.replacingOccurrences(of: "exec_command", with: "unoffered_tool")] {
                XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(invalid, request: request))
            }
            let denied = try WebModelResponseCodec.prepareRequest(requestData(choice, toolChoice: "none"))
            XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(valid, request: denied))
        }
    }

    func testCompletedAndEveryStreamResponseCarryOnlyHonestModeProof() throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let choice = WebsiteModeChoice(deepSeekMode: mode)
            let request = try WebModelResponseCodec.prepareRequest(requestData(choice))
            let evidence = try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": [
                "selected": choice.dictionary, "source": "website_mode_toggle", "backendModel": NSNull(), "search": false]],
                intent: .mode(choice))
            let reply = try WebModelResponseCodec.parseEmbeddedReply(#"{"type":"message","text":"Synthetic mode reply"}"#, request: request)
            let completed = try WebModelResponseCodec.completedResponse(for: reply, request: request, websiteSelectionEvidence: evidence)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: completed) as? [String: Any])
            try assertModeResponse(response, choice: choice)
            let stream = try WebModelResponseCodec.streamData(for: reply, request: request, websiteSelectionEvidence: evidence)
            let lines = String(decoding: stream, as: UTF8.self).components(separatedBy: "\n")
            var responseEvents = 0
            for line in lines where line.hasPrefix("data: {") {
                let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
                if let response = event["response"] as? [String: Any] {
                    responseEvents += 1; try assertModeResponse(response, choice: choice)
                }
            }
            XCTAssertEqual(responseEvents, 3)
            XCTAssertFalse(String(decoding: completed + stream, as: UTF8.self).contains("PRIVATE_BACKEND_CANARY"))
        }
    }

    func testExistingNamedModelMetadataRemainsTypedAndConflictingProofArgumentsAreRejected() throws {
        let choice = WebsiteModeChoice(deepSeekMode: .chat)
        var original = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData(choice)) as? [String: Any])
        original["model"] = "browser/claude"
        let request = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: original))
        let reply = try WebModelResponseCodec.parseEmbeddedReply(#"{"type":"message","text":"fixture"}"#, request: request)
        let model = try WebsiteModelEvidence.parse(["selected": ["key": "fixture", "label": "Fixture"],
            "source": "selected_model_indicator", "verification": "website_selection"], provider: "claude")
        let mode = try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": ["selected": choice.dictionary,
            "source": "website_mode_toggle", "backendModel": NSNull(), "search": false]], intent: .mode(choice))
        XCTAssertThrowsError(try WebModelResponseCodec.completedResponse(for: reply, request: request,
            websiteModelEvidence: model, websiteSelectionEvidence: mode))
        XCTAssertThrowsError(try WebModelResponseCodec.streamData(for: reply, request: request,
            websiteModelEvidence: model, websiteSelectionEvidence: mode))
        let bytes = try WebModelResponseCodec.completedResponse(for: reply, request: request, websiteModelEvidence: model)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let metadata = try XCTUnwrap(response["metadata"] as? [String: Any])
        XCTAssertNil(metadata["computa_website_mode"])
        XCTAssertEqual(try WebsiteModelEvidence.parse(metadata["computa_website_model"], provider: "claude"), model)
    }

    func testPublicServerRejectsDefaultsAliasesAndUnknownModesBeforeAnyTransportOperation() async throws {
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        let transport = DeepSeekAdmissionSpy()
        await server.configureEmbeddedTransport(transport)
        for (index, model) in ["browser/deepseek", "browser/deepseek/mode/Chat", "browser/deepseek/mode/pro",
                              "browser/deepseek/mode/chat/extra", "browser/qwen/mode/chat"].enumerated() {
            var request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData(WebsiteModeChoice(deepSeekMode: .chat))) as? [String: Any])
            request["model"] = model
            do {
                _ = try await server.fixtureInfer(JSONSerialization.data(withJSONObject: request), taskID: "invalid-deepseek-\(index)")
                XCTFail("Invalid mode identity must not reach the transport")
            } catch { }
        }
        let operations = await transport.operations()
        XCTAssertEqual(operations, [])
    }

    private func assertModeResponse(_ response: [String: Any], choice: WebsiteModeChoice,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(response["model"] as? String, choice.requestID, file: file, line: line)
        let metadata = try XCTUnwrap(response["metadata"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(metadata["client_tag"] as? String, "fixture", file: file, line: line)
        XCTAssertNil(metadata["computa_website_model"], file: file, line: line)
        let proof = try WebsiteModeEvidence.parse(metadata["computa_website_mode"], provider: "deepseek", expected: choice)
        XCTAssertTrue(proof.dictionary["backendModel"] is NSNull, file: file, line: line)
        XCTAssertEqual(proof.dictionary["search"] as? Bool, false, file: file, line: line)
    }

    private func requestData(_ choice: WebsiteModeChoice, toolChoice: String = "auto") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": choice.requestID, "input": "Read the synthetic fixture only.",
            "instructions": "Use only the offered tool and preserve user permissions.", "tool_choice": toolChoice,
            "metadata": ["client_tag": "fixture", "computa_website_model": "PRIVATE_BACKEND_CANARY", "computa_website_mode": "PRIVATE_BACKEND_CANARY"],
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object",
                "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]]]
        ] as [String: Any])
    }
}

private actor DeepSeekAdmissionSpy: WebModelTransport {
    private var ledger: [String] = []
    func operations() -> [String] { ledger }
    func request(operation: String, params: Data) async throws -> Data {
        ledger.append(operation)
        throw WebModelServer.Failure.invalidRequest
    }
}

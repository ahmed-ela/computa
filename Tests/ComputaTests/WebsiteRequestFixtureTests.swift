import Foundation
import XCTest
@testable import Computa

final class WebsiteRequestFixtureTests: XCTestCase {
    func testExactProviderFramePreservesJSONBytesAndRejectsMalformedOrCrossProviderFences() throws {
        let chat = #"{"model":"browser/chatgpt","input":"hello","metadata":{"x":"first","x":"last"}}"#
        let gemini = chat.replacingOccurrences(of: "browser/chatgpt", with: "browser/gemini")
        func prompt(_ frame: String) -> String {
            "prefix\nCOMPLETE_RESPONSES_REQUEST_JSON:\n" + frame + "\nEND_COMPLETE_RESPONSES_REQUEST_JSON.\nsuffix"
        }
        XCTAssertEqual(try WebsiteRequestFixture.json(in: prompt("```\n" + chat + "\n```")), Data(chat.utf8))
        XCTAssertEqual(try WebsiteRequestFixture.json(in: prompt(gemini)), Data(gemini.utf8))
        for badFrame in [chat, "```json\n" + chat + "\n```", "```\r\n" + chat + "\r\n```",
                         "````\n" + chat + "\n````", "```\n" + chat, chat + "\n```",
                         " ```\n" + chat + "\n```", "```\n" + chat + "\n``` ",
                         "```\n" + gemini + "\n```"] {
            XCTAssertThrowsError(try WebsiteRequestFixture.json(in: prompt(badFrame)))
        }
        let valid = prompt("```\n" + chat + "\n```")
        XCTAssertThrowsError(try WebsiteRequestFixture.json(in: valid, expectedModel: "browser/claude"))
        XCTAssertThrowsError(try WebsiteRequestFixture.json(in: valid + "\nEND_COMPLETE_RESPONSES_REQUEST_JSON."))
        XCTAssertThrowsError(try WebsiteRequestFixture.json(in: "COMPLETE_RESPONSES_REQUEST_JSON:\n" + valid))
    }

    func testWorkflowFixtureReadsFencedRequestAndRetainsExactNativeInputValues() throws {
        let input = [["role": "user", "content": "Read café 🌍 and literal \\u0060\n```"]]
        for model in [syntheticChatGPTModelID, "browser/gemini"] {
            let raw = try JSONSerialization.data(withJSONObject: ["model": model, "input": input])
            let prepared = try WebModelResponseCodec.prepareRequest(raw)
            let fixture = try InferenceRequest(params: JSONSerialization.data(withJSONObject: ["prompt": prepared.prompt]))
            XCTAssertEqual(fixture.input as NSArray, input as NSArray)
            XCTAssertEqual(fixture.prepared.model, model)
            XCTAssertEqual(fixture.prepared.continuationRequest,
                try WebsiteRequestFixture.json(in: prepared.prompt, expectedModel: model))
        }
    }
}

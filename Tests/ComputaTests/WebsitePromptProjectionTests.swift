import Foundation
import XCTest
@testable import Computa

final class WebsitePromptProjectionTests: XCTestCase {
    func testCompactionPreservesLexemesEscapesDuplicateKeysAndLiteralWhitespace() throws {
        let source = #"""
          {
            "model" : "browser/chatgpt", "input" : "  café 🌍\t\n\r ",
            "number": 9007199254740993, "number" : -0.00e+12,
            "grammar" : "start: /[\\s\\S]*/; \"quoted\" \\u005f \/",
            "nested" : [ { "a" : true }, null ]
          }
        """#
        let expected = #"{"model":"browser/chatgpt","input":"  café 🌍\t\n\r ","number":9007199254740993,"number":-0.00e+12,"grammar":"start: /[\\s\\S]*/; \"quoted\" \\u005f \/","nested":[{"a":true},null]}"#
        let result = WebsitePromptProjection.compactValidatedJSON(source)
        XCTAssertEqual(result.json, expected)
        XCTAssertLessThan(result.json.utf8.count, source.utf8.count)
        XCTAssertEqual(result.sourceBytes, source.utf8.count)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(source.utf8)) as? NSDictionary)
        XCTAssertEqual(WebsitePromptProjection.compactValidatedJSON(result.json).json, result.json)
    }

    func testComponentAccountingIncludesEscapedKeysNestedPunctuationAndEveryStructuralByte() {
        let input = #""input":[{"role":"user","content":"private_CANARY, : { }"}]"#
        let tools = #""\u0074ools":[{"name":"a_b","parameters":{"type":"object"}}]"#
        let instructions = #""instructions":"private_CANARY""#
        let source = "{\n" + [input, tools, instructions, #""metadata":{"tools":"not top-level"}"#].joined(separator: ",\n") + "\n}"
        let result = WebsitePromptProjection.compactValidatedJSON(source)
        XCTAssertEqual(result.components.inputJSONBytes, input.utf8.count)
        XCTAssertEqual(result.components.toolsJSONBytes, tools.utf8.count)
        XCTAssertEqual(result.components.instructionsJSONBytes, instructions.utf8.count)
        XCTAssertEqual(result.components.otherJSONBytes, #""metadata":{"tools":"not top-level"}"#.utf8.count + 5)
        XCTAssertEqual(result.components.inputJSONBytes + result.components.toolsJSONBytes
            + result.components.instructionsJSONBytes + result.components.otherJSONBytes, result.json.utf8.count)
        XCTAssertEqual(WebsitePromptProjection.compactValidatedJSON("{}").components,
                       .init(inputJSONBytes: 0, toolsJSONBytes: 0, instructionsJSONBytes: 0, otherJSONBytes: 2))
    }

    func testStatisticsReconcilePresentedRequestFramingAndContractsWithoutContent() throws {
        let projection = WebsitePromptProjection.compactValidatedJSON(#"{ "input": "private_CANARY", "tools": [] }"#)
        let statistics = projection.statistics(originalRequestBytes: 100, presentedRequestBytes: 80,
            runtimeBytes: 20, requestContextBytes: 30, currentUserBytes: 40, responseContractBytes: 50, finalPromptBytes: 230)
        XCTAssertEqual(statistics.framingBytes, 10)
        XCTAssertEqual(statistics.outerContractBytes, 150)
        XCTAssertEqual(statistics.presentedRequestBytes + statistics.runtimeBytes + statistics.requestContextBytes
            + statistics.currentUserBytes + statistics.responseContractBytes + statistics.framingBytes, statistics.finalPromptBytes)
        let encoded = try JSONEncoder().encode(statistics)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private_CANARY"))
        XCTAssertFalse(statistics.diagnostic.contains("private_CANARY"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Int])
        XCTAssertEqual(fields.count, 15)
        XCTAssertEqual(fields["originalRequestBytes"], 100)
        XCTAssertEqual(fields["compactRequestBytes"], projection.json.utf8.count)
        XCTAssertTrue(fields.values.allSatisfy { $0 >= 0 })
    }

    func testLongUnicodeStringAndCustomGrammarKeepEveryByte() {
        let value = String(repeating: "é_🌍 ", count: 8_000)
        let source = "{ \"input\" : \"" + value + "\", \"tools\" : [] }"
        let result = WebsitePromptProjection.compactValidatedJSON(source)
        XCTAssertEqual(result.json, "{\"input\":\"" + value + "\",\"tools\":[]}")
        XCTAssertEqual(result.components.inputJSONBytes, value.utf8.count + 10)
        XCTAssertEqual(result.components.toolsJSONBytes, 10)
    }
}

import Foundation
import XCTest
@testable import Computa

final class WebsitePromptProjectionTests: XCTestCase {
    func testNativeInputAppendPreservesEveryRetainedLexemeForArrayEmptyAndStringInput() throws {
        let item: [String: Any] = ["type":"function_call_output","call_id":"native","output":"new"]
        let encoded = #"{"call_id":"native","output":"new","type":"function_call_output"}"#
        let cases: [(String,String)] = [
            (#"{ "input" : [{"role":"user","content":"\u0061\/\uD83D\uDE00"} ],"foreign":1.2300e-4,"zero":-0.00e+12 }"#,
             #"{ "input" : [{"role":"user","content":"\u0061\/\uD83D\uDE00"} ,"# + encoded + #"],"foreign":1.2300e-4,"zero":-0.00e+12 }"#),
            (#"{"input":[ ],"foreign":9007199254740993}"#,#"{"input":[ "# + encoded + #"],"foreign":9007199254740993}"#),
            (#"{"\u0069nput":"\u0061\/","foreign":-0.00e+12}"#,
             #"{"\u0069nput":[{"role":"user","content":"\u0061\/"},"# + encoded + #"],"foreign":-0.00e+12}"#),
        ]
        for (source,expected) in cases {
            let result = try WebsitePromptProjection.appendingInputItems([item],to:Data(source.utf8))
            XCTAssertEqual(result,Data(expected.utf8))
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with:result))
        }
    }

    func testNativeInputAppendRejectsMissingWrongOrDuplicateInputWithoutChangingSource() throws {
        let item: [String: Any] = ["type":"function_call_output","call_id":"native","output":"new"]
        for source in [#"{}"#,#"{"input":null}"#,#"{"input":{}}"#,#"{"input":1}"#,
                       #"{"input":[],"input":[]}"#,#"{"input":[],"\u0069nput":"other"}"#,#"{"input":[]"#] {
            XCTAssertThrowsError(try WebsitePromptProjection.appendingInputItems([item],to:Data(source.utf8)))
        }
        XCTAssertThrowsError(try WebsitePromptProjection.appendingInputItems([],to:Data(#"{"input":[]}"#.utf8)))
    }

    func testAPIOnlyOmissionRemovesExactlyTheDeclaredTopLevelFieldsAtEveryPosition() throws {
        let omitted = ["include", "reasoning", "client_metadata", "prompt_cache_key", "metadata", "safety_identifier",
            "stream", "stream_options", "store", "background", "service_tier"]
        for key in omitted {
            let member = "\"\(key)\":{\"private_transport_value\":true}"
            for source in ["{\(member),\"input\":\"task\",\"tools\":[]}",
                           "{\"input\":\"task\",\(member),\"tools\":[]}",
                           "{\"input\":\"task\",\"tools\":[],\(member)}"] {
                XCTAssertEqual(WebsitePromptProjection.omittingAPIOnlyTopLevelFields(source), #"{"input":"task","tools":[]}"#, key)
            }
        }
        let members = omitted.map { "\"\($0)\":null" }.joined(separator: ",")
        XCTAssertEqual(WebsitePromptProjection.omittingAPIOnlyTopLevelFields("{" + members + "}"), "{}")
        XCTAssertEqual(WebsitePromptProjection.omittingAPIOnlyTopLevelFields("{\"input\":\"task\"," + members + "}"), #"{"input":"task"}"#)
    }

    func testAPIOnlyOmissionPreservesNestedNamesAndEveryRetainedLexeme() throws {
        let source = #"{"reasoning":{"summary":"auto"},"input":[{"role":"user","content":"reasoning.encrypted_content, \"reasoning\": { }, \\u005f café 🌍"},{"type":"function_call_output","output":"private_CANARY include client_metadata"}],"\u0072easoning":null,"tools":[{"parameters":{"properties":{"reasoning":{"type":"string"},"include":{"enum":["reasoning.encrypted_content"]}}},"number":9007199254740993,"fraction":1.2300e-4}],"foreign":-0.00e+12,"foreign":true,"metadata":{"removed":true}}"#
        let expected = #"{"input":[{"role":"user","content":"reasoning.encrypted_content, \"reasoning\": { }, \\u005f café 🌍"},{"type":"function_call_output","output":"private_CANARY include client_metadata"}],"tools":[{"parameters":{"properties":{"reasoning":{"type":"string"},"include":{"enum":["reasoning.encrypted_content"]}}},"number":9007199254740993,"fraction":1.2300e-4}],"foreign":-0.00e+12,"foreign":true}"#
        let projected = WebsitePromptProjection.omittingAPIOnlyTopLevelFields(source)
        XCTAssertEqual(Data(projected.utf8), Data(expected.utf8))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(projected.utf8)))
    }

    func testAPIOnlyOmissionIsByteIdenticalWhenAbsentAndLeavesOtherControlsUntouched() {
        for source in [" {} \n", #" { "input" : "\u0061", "temperature":1.0,"max_output_tokens":1024,"max_tool_calls":2,"text":{"verbosity":"low"},"unknown":{"metadata":true} } "#] {
            XCTAssertEqual(Data(WebsitePromptProjection.omittingAPIOnlyTopLevelFields(source).utf8), Data(source.utf8))
        }
        let source = "\u{FEFF} { \"metadata\":null, \"input\" : \"task\" } \n"
        XCTAssertEqual(WebsitePromptProjection.omittingAPIOnlyTopLevelFields(source), "\u{FEFF} { \"input\" : \"task\" } \n")
    }

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

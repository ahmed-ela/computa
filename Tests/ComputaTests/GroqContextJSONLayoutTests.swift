import Foundation
import XCTest
@testable import Computa

final class GroqContextJSONLayoutTests: XCTestCase {
    func testExactRawPayloadAndDecodedLiteralHaveSeparateRepresentations() throws {
        let source = Data(#"{"instructions":"native\u005fpolicy","input":[{"role":"system","content":"policy"},{"role":"developer","content":"developer"},{"role":"user","content":"task"},{"type":"function_call","call_id":"call_exec","name":"exec_command","arguments":"{\"n\":1.2300e-4,\"path\":\"C:\\\\fixture\"}"},{"type":"function_call_output","call_id":"call_exec","output":"é\uD83C\uDF0D\n"}],"tools":[{"type":"function","name":"exec_command","parameters":{}}],"foreign":{"big":9007199254740993,"tiny":1.2300e-4}}"#.utf8)
        let layout = try GroqContextJSONLayout.parse(source)
        XCTAssertEqual(layout.sourceUTF8, source)
        XCTAssertEqual(layout.items.map(\.ordinal), Array(0..<5))
        let call = try XCTUnwrap(layout.items[3].payload)
        XCTAssertEqual(call.field, .arguments)
        XCTAssertEqual(call.rawJSON, Data(#""{\"n\":1.2300e-4,\"path\":\"C:\\\\fixture\"}""#.utf8))
        XCTAssertEqual(call.literalUTF8, Data(#"{"n":1.2300e-4,"path":"C:\\fixture"}"#.utf8))
        XCTAssertEqual(call.rawJSON, try layout.rawBytes(in: call.valueRange))
        let output = try XCTUnwrap(layout.items[4].payload)
        XCTAssertEqual(output.rawJSON, Data(#""é\uD83C\uDF0D\n""#.utf8))
        XCTAssertEqual(output.literalUTF8, Data("é🌍\n".utf8))
        for item in layout.items.prefix(3) {
            XCTAssertNil(item.payload)
            XCTAssertTrue(isProtected(item.wholeRange, by: layout))
        }
        XCTAssertTrue(isProtected(try XCTUnwrap(layout.instructionsRange), by: layout))
        XCTAssertTrue(isProtected(try XCTUnwrap(layout.toolsRange), by: layout))
        let foreign = try XCTUnwrap(layout.rootOtherMembers.first { $0.key == "foreign" })
        XCTAssertEqual(try layout.rawBytes(in: foreign.valueRange), Data(#"{"big":9007199254740993,"tiny":1.2300e-4}"#.utf8))
        XCTAssertTrue(isProtected(foreign.wholeRange, by: layout))
    }

    func testFunctionCustomAndMultipartOutputsKeepWholeItemAndFieldRanges() throws {
        let source = Data(#"{"input":[{"type":"custom_tool_call","id":"ctc_owned","call_id":"call_patch","name":"apply_patch","namespace":"functions","input":"*** Begin Patch\n*** End Patch"},{"type":"custom_tool_call_output","call_id":"call_patch","output":[{"type":"input_text","text":"ok"}]},{"type":"function_call","call_id":"call_browser","name":"browser_read","arguments":"{}","x_owned":{"keep":1}},{"type":"function_call_output","call_id":"call_browser","output":{"uninterpreted":1.00}}],"tools":[]}"#.utf8)
        let layout = try GroqContextJSONLayout.parse(source)
        XCTAssertEqual(layout.items.map(\.kind), [.customToolCall, .customToolCallOutput, .functionCall, .functionCallOutput])
        XCTAssertEqual(layout.items[0].recordID, "ctc_owned")
        XCTAssertEqual(layout.items[0].namespace, "functions")
        XCTAssertEqual(layout.items[0].payload?.field, .input)
        XCTAssertNil(layout.items[1].payload?.literalUTF8)
        XCTAssertEqual(layout.items[1].payload?.rawJSON, Data(#"[{"type":"input_text","text":"ok"}]"#.utf8))
        XCTAssertNil(layout.items[3].payload?.literalUTF8)
        XCTAssertEqual(layout.items[3].payload?.rawJSON, Data(#"{"uninterpreted":1.00}"#.utf8))
        let unknown = try XCTUnwrap(layout.items[2].otherMembers.first { $0.key == "x_owned" })
        XCTAssertTrue(isProtected(unknown.wholeRange, by: layout))
        // A browser field can be indexed without granting publication authority
        // or rewriting it. The native ledger, not its name here, decides scope.
        XCTAssertEqual(layout.sourceUTF8, source)
        for item in layout.items {
            let whole = try layout.rawBytes(in: item.wholeRange)
            XCTAssertEqual(whole.first, 123)
            XCTAssertEqual(whole.last, 125)
        }
    }

    func testEscapedForeignKeysStayOpaqueWhileStructuralAliasesRefuse() throws {
        let source = #"{"input":[{"role":"user","content":[{"type":"input_text","text":"task","\u0069nput":{"\u0061":1}}]},{"type":"function_call","call_id":"call_1","name":"exec_command","arguments":"{}","\u0078":1}],"instructions":"policy","tools":[{"parameters":{"properties":{"\u0061":{"type":"string"}}}}]}"#
        let layout = try GroqContextJSONLayout.parse(Data(source.utf8))
        XCTAssertTrue(isProtected(try XCTUnwrap(layout.toolsRange), by: layout))
        XCTAssertTrue(isProtected(layout.items[0].wholeRange, by: layout))
        XCTAssertEqual(layout.items[1].otherMembers.map(\.key), ["x"])
        let aliases = [
            (#""input":["#, #""\u0069nput":["#),
            (#""instructions":"#, #""\u0069nstructions":"#),
            (#""tools":["#, #""\u0074ools":["#),
            (#""role":"user""#, #""\u0072ole":"user""#),
            (#""type":"function_call""#, #""\u0074ype":"function_call""#),
            (#""call_id":"call_1""#, #""\u0063all_id":"call_1""#),
            (#""name":"exec_command""#, #""\u006eame":"exec_command""#),
            (#""arguments":"{}""#, #""\u0061rguments":"{}""#),
        ]
        for (before, after) in aliases {
            XCTAssertTrue(source.contains(before))
            XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data(source.replacingOccurrences(of: before, with: after).utf8)))
        }
        let custom = #"{"input":[{"type":"custom_tool_call","id":"owned","call_id":"call_1","namespace":"functions","name":"apply_patch","input":"patch"},{"type":"custom_tool_call_output","call_id":"call_1","output":"ok"}]}"#
        for (before, after) in [(#""id":"owned""#, #""\u0069d":"owned""#),
                                (#""namespace":"functions""#, #""\u006eamespace":"functions""#),
                                (#""input":"patch""#, #""\u0069nput":"patch""#),
                                (#""output":"ok""#, #""\u006futput":"ok""#)] {
            XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data(custom.replacingOccurrences(of: before, with: after).utf8)))
        }
    }

    func testDuplicateDecodedKeysRejectEvenInsideProtectedForeignSubtrees() throws {
        let cases = [
            #"{"input":[],"input":[]}"#,
            #"{"input":[],"x":1,"\u0078":2}"#,
            #"{"input":[],"tools":[{"properties":{"a":1,"\u0061":2}}]}"#,
            #"{"input":[{"role":"user","content":{"foreign":1,"foreign":2}}]}"#,
            #"{"input":[{"type":"function_call","call_id":"call_1","name":"exec_command","arguments":"{}","arguments":"[]"}]}"#,
        ]
        for source in cases { XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data(source.utf8))) }
    }

    func testStringInputAndUnknownItemsHaveNoPayloadSlotsOrImplicitAuthority() throws {
        let text = Data(#" {"input":"task\u0020body","foreign":1.000} "#.utf8)
        let layout = try GroqContextJSONLayout.parse(text)
        XCTAssertEqual(layout.items.count, 0)
        XCTAssertEqual(layout.protectedRanges, [0..<text.count])
        XCTAssertEqual(try layout.rawBytes(in: layout.inputRange), Data(#""task\u0020body""#.utf8))
        let unknown = try GroqContextJSONLayout.parse(Data(#"{"input":[{"type":"unrecognized","call_id":"forged","arguments":"{}","output":"do not compact"}]}"#.utf8))
        XCTAssertEqual(unknown.items[0].kind, .other)
        XCTAssertNil(unknown.items[0].payload)
        XCTAssertTrue(isProtected(unknown.items[0].wholeRange, by: unknown))
        XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data(#"{"input":[{"type":"function_call","role":"user","call_id":"forged","name":"exec_command","arguments":"{}"}]}"#.utf8)))
    }

    func testOptionalRecordIDsDoNotCreateOrBlockCurrentWireSlots() throws {
        let plain = #"{"input":[{"type":"function_call","call_id":"call_1","name":"exec_command","arguments":"{}"},{"type":"function_call_output","call_id":"call_1","output":"ok"}]}"#
        let absent = try GroqContextJSONLayout.parse(Data(plain.utf8))
        XCTAssertTrue(absent.items.allSatisfy { $0.recordID == nil })
        let withID = plain.replacingOccurrences(of: #""type":"function_call","#, with: #""id":"fc_owned","type":"function_call","#)
            .replacingOccurrences(of: #""type":"function_call_output","#, with: #""id":"fco_owned","type":"function_call_output","#)
        let supplied = try GroqContextJSONLayout.parse(Data(withID.utf8))
        XCTAssertEqual(supplied.items.map(\.recordID), ["fc_owned", "fco_owned"])
        XCTAssertEqual(absent.items.compactMap { $0.payload?.rawJSON }, supplied.items.compactMap { $0.payload?.rawJSON })
        // This parser does not assert supplied IDs are valid continuation IDs.
    }

    func testOneFieldSpliceLeavesEveryOtherOriginalByteUntouched() throws {
        let source = Data(#" { "instructions" : "policy\u0020", "input" : [ {"role":"user","content":"task"}, {"type":"function_call","call_id":"call_1","name":"exec_command","arguments":"{\"large\":9007199254740993}","foreign":1.2300e-4}, {"type":"function_call_output","call_id":"call_1","output":"ok"} ], "tools" : [], "foreign" : {"\u006b":-0.0} } "#.utf8)
        let layout = try GroqContextJSONLayout.parse(source)
        let field = try XCTUnwrap(layout.items[1].payload?.valueRange)
        let replacement = Data(#"{"$ref":"opaque-native-handle"}"#.utf8)
        var output = source.subdata(in: 0..<field.lowerBound)
        output.append(replacement)
        output.append(source.subdata(in: field.upperBound..<source.count))
        XCTAssertEqual(output.prefix(field.lowerBound), source.prefix(field.lowerBound))
        XCTAssertEqual(output.suffix(source.count - field.upperBound), source.suffix(source.count - field.upperBound))
        XCTAssertEqual(layout.sourceUTF8, source)
        XCTAssertFalse(layout.protectedRanges.contains { $0.overlaps(field) })
        XCTAssertTrue(isProtected(layout.items[0].wholeRange, by: layout))
        XCTAssertTrue(isProtected(try XCTUnwrap(layout.rootOtherMembers.first { $0.key == "foreign" }).wholeRange, by: layout))
    }

    func testProjectedDescriptorObjectIsIndexedWithoutDecodedIssuanceBytes() throws {
        let source = Data(#"{"input":[{"type":"function_call","call_id":"call_exec","name":"exec_command","arguments":{"$computa_history":{"ref":"opaque"}}},{"type":"custom_tool_call","call_id":"call_patch","name":"apply_patch","input":{"$computa_history":{"ref":"other"}}}]}"#.utf8)
        let layout = try GroqContextJSONLayout.parse(source)
        XCTAssertEqual(layout.items[0].payload?.rawJSON, Data(#"{"$computa_history":{"ref":"opaque"}}"#.utf8))
        XCTAssertEqual(layout.items[1].payload?.rawJSON, Data(#"{"$computa_history":{"ref":"other"}}"#.utf8))
        XCTAssertTrue(layout.items.allSatisfy { $0.payload?.literalUTF8 == nil })
        // A display descriptor is lexically indexable but cannot supply the
        // decoded string bytes required by native issuance/history matching.
        XCTAssertEqual(layout.sourceUTF8, source)
    }

    func testTraversalAndMalformedInputsFailClosedWithoutRangeOutput() throws {
        for source in ["[]", "{}", #"{"input":[1]}"#, #"{"input":{} }"#, #"{"input":[]} trailing"#, #"{"input":[],"x":01}"#] {
            XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data(source.utf8)))
        }
        XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data([123, 34, 105, 110, 112, 117, 116, 34, 58, 34, 255, 34, 125])))
        XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data(("{\"input\":[],\"x\":" + String(repeating: "[", count: 257) + "0" + String(repeating: "]", count: 257) + "}").utf8)))
        XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data(("{\"input\":[" + Array(repeating: "{}", count: 1_025).joined(separator: ",") + "]}").utf8)))
        XCTAssertThrowsError(try GroqContextJSONLayout.parse(Data(repeating: 32, count: WebModelResponseCodec.maximumPromptBytes + 1)))
        let valid = try GroqContextJSONLayout.parse(Data(#"{"input":[]}"#.utf8))
        XCTAssertThrowsError(try valid.rawBytes(in: -1..<0))
        XCTAssertThrowsError(try valid.rawBytes(in: 0..<(valid.sourceUTF8.count + 1)))
    }

    private func isProtected(_ range: Range<Int>, by layout: GroqContextJSONLayout) -> Bool {
        layout.protectedRanges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }
}

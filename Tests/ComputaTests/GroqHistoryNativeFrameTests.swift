import Foundation
import XCTest
@testable import Computa

final class GroqHistoryNativeFrameTests: XCTestCase {
    func testExactExecAndPatchPairsUseSameSourceRangesAndOptionalIDs() throws {
        let bytes = Data(#"{"input":[{"type":"function_call","call_id":"call_e","name":"exec_command","arguments":"{\"n\":1.2300e-4}"},{"type":"function_call_output","call_id":"call_e","output":"A\u002DB"},{"type":"custom_tool_call","id":"observed-custom-id","call_id":"call_p","name":"apply_patch","namespace":"functions","input":"patch\n"},{"type":"custom_tool_call_output","id":"observed-result-id","call_id":"call_p","output":[{"type":"input_text","text":"ok"}]}],"tools":[]}"#.utf8)
        let layout = try GroqContextJSONLayout.parse(bytes), frame = try GroqHistoryNativeFrame(layout: layout)
        XCTAssertEqual(frame.history.sourceUTF8, bytes)
        XCTAssertEqual(frame.history.pairs.map(\.callID), ["call_e", "call_p"])
        XCTAssertEqual(frame.olderCallIDs, ["call_e"])
        let exec = frame.history.pairs[0], patch = frame.history.pairs[1]
        XCTAssertEqual(exec.kind, .execCommand); XCTAssertEqual(patch.kind, .applyPatch)
        XCTAssertEqual(exec.argumentUTF8, Data(#"{"n":1.2300e-4}"#.utf8))
        XCTAssertEqual(patch.argumentUTF8, Data("patch\n".utf8)); XCTAssertEqual(patch.namespace, "functions")
        XCTAssertEqual(bytes.subdata(in: exec.argumentValueRange), layout.items[0].payload?.rawJSON)
        XCTAssertEqual(bytes.subdata(in: exec.outputValueRange), Data(#""A\u002DB""#.utf8))
        XCTAssertEqual(bytes.subdata(in: patch.outputValueRange), layout.items[3].payload?.rawJSON)
    }

    func testLatestResultAcrossAllToolsIsExcludedButUnknownToolsNeverBecomePairs() throws {
        let bytes = Data(#"{"input":[{"type":"function_call","call_id":"e","name":"exec_command","arguments":"{}"},{"type":"function_call_output","call_id":"e","output":"done"},{"type":"function_call","call_id":"b","name":"browser_read","arguments":"{}"},{"type":"function_call_output","call_id":"b","output":"current observation"},{"type":"function_call","call_id":"r","name":"computa_read_context","arguments":"{}"},{"type":"function_call_output","call_id":"r","output":"read bytes"}]}"#.utf8)
        let frame = try GroqHistoryNativeFrame(layout: GroqContextJSONLayout.parse(bytes))
        XCTAssertEqual(frame.history.pairs.map(\.callID), ["e"])
        XCTAssertEqual(frame.olderCallIDs, ["e"])
        let only = try GroqHistoryNativeFrame(layout: GroqContextJSONLayout.parse(Data(#"{"input":[{"type":"function_call","call_id":"e","name":"exec_command","arguments":"{}"},{"type":"function_call_output","call_id":"e","output":"newest"}]}"#.utf8)))
        XCTAssertEqual(only.history.pairs.count, 1); XCTAssertTrue(only.olderCallIDs.isEmpty)
    }

    func testPendingCallsAreNotCompletionAndNonStringArgumentsCannotMintPairs() throws {
        let pending = try GroqHistoryNativeFrame(layout: GroqContextJSONLayout.parse(Data(#"{"input":[{"type":"function_call","call_id":"e","name":"exec_command","arguments":"{}"}]}"#.utf8)))
        XCTAssertTrue(pending.history.pairs.isEmpty); XCTAssertTrue(pending.olderCallIDs.isEmpty)
        let descriptor = Data(#"{"input":[{"type":"function_call","call_id":"e","name":"exec_command","arguments":{"$computa_history":{"ref":"opaque"}}},{"type":"function_call_output","call_id":"e","output":"ok"}]}"#.utf8)
        XCTAssertThrowsError(try GroqHistoryNativeFrame(layout: GroqContextJSONLayout.parse(descriptor))) {
            XCTAssertEqual($0 as? GroqHistoryNativeFrame.Failure, .nonLiteralArguments)
        }
    }

    func testDuplicateOrOrphanOrOutOfOrderOrMismatchedKindsAndNamesRefuse() throws {
        let call = #"{"type":"function_call","call_id":"e","name":"exec_command","arguments":"{}"}"#
        let output = #"{"type":"function_call_output","call_id":"e","output":"ok"}"#
        let cases = [call + "," + call, output, output + "," + call, call + "," + output + "," + output,
            call + "," + output.replacingOccurrences(of: "function_call_output", with: "custom_tool_call_output"),
            call + "," + output.replacingOccurrences(of: #""output":"#, with: #""name":"browser_read","output":"#),
            call + "," + output.replacingOccurrences(of: #""output":"#, with: #""namespace":"foreign","output":"#)]
        for items in cases {
            XCTAssertThrowsError(try GroqHistoryNativeFrame(layout: GroqContextJSONLayout.parse(Data(("{\"input\":[" + items + "]}").utf8))))
        }
    }

    func testForeignNamespaceAndWrongNativeToolKindsStayInlineWithoutNormalization() throws {
        let bytes = Data(#"{"input":[{"type":"function_call","call_id":"e","name":"exec_command","namespace":"foreign","arguments":"{}"},{"type":"function_call_output","call_id":"e","output":"ok"},{"type":"function_call","call_id":"p","name":"apply_patch","arguments":"{}"},{"type":"function_call_output","call_id":"p","output":"ok"},{"type":"function_call","call_id":"q","name":"functions.exec_command","arguments":"{}"},{"type":"function_call_output","call_id":"q","output":"ok"}]}"#.utf8)
        let frame = try GroqHistoryNativeFrame(layout: GroqContextJSONLayout.parse(bytes))
        XCTAssertTrue(frame.history.pairs.isEmpty); XCTAssertTrue(frame.olderCallIDs.isEmpty)
        XCTAssertEqual(frame.history.sourceUTF8, bytes)
    }
}

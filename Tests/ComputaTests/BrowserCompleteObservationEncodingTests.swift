import Foundation
import AutomationCore
import XCTest
@testable import Computa

final class BrowserCompleteObservationEncodingTests: XCTestCase {
    private let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000227")!

    func testInvalidEventFeedbackUsesOnlyPublishedUTF8LabelSpansAndFitsActualEnvelope() throws {
        let url = URL(string: "http://localhost/form")!, label = "UNEXPOSED_PREFIXe\u{301}🙂\\\"TAIL"
        let committedDocumentID = UUID()
        let fragment = "e\u{301}🙂\\\"", start = "UNEXPOSED_PREFIX".utf8.count
        let element = BrowserTabElement(index: 0, backendNodeID: 1, role: "AXTextField", label: label,
            value: "PRIVATE_VALUE", isEnabled: true, supportsPress: false, supportsSetText: true)
        func page(loader: String = "native", field: SemanticReadField = .label, begin: Int = start,
                  end: Int = start + fragment.utf8.count, commit: UUID? = committedDocumentID) -> BrowserInputFeedback.PublishedPage {
            let receipt = SemanticReadReceipt(id: snapshotID, sourceID: UUID(), targetGeneration: "native",
                consistency: .immutableCapture, view: .overview, query: nil, subtreeNodeID: nil,
                selectedElementCount: 1, selectedFieldCount: 2, sourceTruncated: false, fieldTruncated: true,
                outputTruncated: true, exposures: [.init(nodeID: "backend:1", field: field, startUTF8: begin,
                    endUTF8: end, totalUTF8: label.utf8.count, kind: .control, provenance: .main)])
            return .init(loaderID: loader, documentURL: url, elements: [element], receipt: receipt, committedDocumentID: commit)
        }
        let feedback = BrowserInputFeedback(loaderID: "native", documentURL: url,
            fields: [.init(backendNodeID: 1, issues: [.valueMissing])], truncated: false, committedDocumentID: committedDocumentID)
        let encoding = BrowserCompleteObservation.Encoding.input(wasFill: false, receipt: cue(wasFill: false), feedback: feedback)
        let encoded = try encoding.encode("published fragment", snapshotID: snapshotID, page: page())
        let body = try object(encoded), info = try XCTUnwrap(body["input_feedback"] as? [String: Any])
        let fields = try XCTUnwrap(info["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(fields.first?["label"] as? String).utf8), Array(fragment.utf8))
        XCTAssertEqual(fields.first?["partial"] as? Bool, true)
        XCTAssertEqual(fields.first?["issues"] as? [String], ["value_missing"])
        XCTAssertEqual(body["result_verified"] as? Bool, false)
        for hidden in ["UNEXPOSED_PREFIX", "TAIL", "PRIVATE_VALUE", "backendNodeID"] { XCTAssertFalse(encoded.contains(hidden)) }
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(encoded, actionReceipt: cue(wasFill: false)), 0)
        for unexposed in [page(loader: "different"), page(field: .value), page(begin: start + 4), page(commit: UUID()), page(commit: nil)] {
            let value = feedback.presentation(page: unexposed)
            XCTAssertEqual((value["fields"] as? [[String: Any]])?.count, 0)
            XCTAssertEqual(value["fields_omitted"] as? Bool, true)
        }
        let unknownCommit = BrowserInputFeedback(loaderID: "native", documentURL: url,
            fields: feedback.fields, truncated: false)
        XCTAssertEqual((unknownCommit.presentation(page: page())["fields"] as? [[String: Any]])?.count, 0,
                       "An unknown original committed document cannot acquire labels from a later observation")
        let fill = try BrowserCompleteObservation.Encoding.input(wasFill: true, receipt: cue(wasFill: true), feedback: feedback)
            .encode("page", snapshotID: snapshotID, page: page())
        XCTAssertNil(try object(fill)["input_feedback"], "Only an actual click carries these events")
        let available = 4_096 - rawBytes(encoded, receipt: cue(wasFill: false))
        let boundary = try encoding.encode(String(repeating: "x", count: available) + "published fragment", snapshotID: snapshotID, page: page())
        XCTAssertEqual(rawBytes(boundary, receipt: cue(wasFill: false)), 4_096)
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(boundary, actionReceipt: cue(wasFill: false)), 0)
    }

    func testInputEnvelopePreservesSendAndSentRowsAndDispatchOnlyMeaningThroughWireEscaping() throws {
        // Build226's generic head/tail excerpt dropped the Send message row
        // while leaving the Sent navigation token. The complete producer must
        // preserve both associations verbatim, including nested JSON escaping.
        let send = #"10 AXButton semantic_role=button label="Send message" actions=["AXPress"] click_ref="bclick_00000000-0000-0000-0000-000000000010""#
        let sent = #"11 AXLink semantic_role=link label="Sent" actions=["AXPress"] click_ref="bclick_00000000-0000-0000-0000-000000000011""#
        let page = "READ source=immutable matches=12 shown=12 output_truncated=0\n"
            + "9 AXTextArea value=\"e\u{301} 🙂 \\\" exact\\nfield\"\n" + send + "\n" + sent
        for wasFill in [false, true] {
            let receipt = cue(wasFill: wasFill)
            let encoding = BrowserCompleteObservation.Encoding.input(wasFill: wasFill, receipt: receipt)
            let envelope = try encoding.encode(page, snapshotID: snapshotID)
            let wire = try serializedParts(envelope, receipt: receipt)
            let items = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [[String: String]])
            XCTAssertEqual(items.count, 3)
            XCTAssertEqual(items[0]["text"], BrowserCompleteObservation.marker)
            XCTAssertEqual(items[1]["text"], receipt)
            let body = try object(XCTUnwrap(items[2]["text"]))
            XCTAssertEqual(body["dispatched"] as? Bool, true)
            XCTAssertEqual(body["no_replay"] as? Bool, true)
            XCTAssertEqual(body["result_verified"] as? Bool, false)
            XCTAssertEqual(body["input_kind"] as? String, wasFill ? "fill" : "click")
            let observation = try XCTUnwrap(body["current_observation"] as? [String: Any])
            XCTAssertEqual(observation["status"] as? String, "available")
            XCTAssertEqual(observation["snapshot_id"] as? String, snapshotID.uuidString)
            XCTAssertEqual(Array(try XCTUnwrap(observation["text"] as? String).utf8), Array(page.utf8))
            XCTAssertTrue(try XCTUnwrap(observation["text"] as? String).contains(send))
            XCTAssertTrue(try XCTUnwrap(observation["text"] as? String).contains(sent))
            if wasFill {
                XCTAssertTrue(try XCTUnwrap(body["next"] as? String).contains("no Enter or submit click"))
            }
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(envelope, actionReceipt: receipt), 0)
            XCTAssertLessThanOrEqual(wire.count, 4_608)
        }
    }

    func testReadAndInputEnvelopesIncludeEveryItemAndSeparatorAtTheExistingRawBoundary() throws {
        for wasFill in [false, true] {
            let receipt = cue(wasFill: wasFill)
            let encoding = BrowserCompleteObservation.Encoding.input(wasFill: wasFill, receipt: receipt)
            let empty = try encoding.encode("", snapshotID: snapshotID)
            let available = 4_096 - rawBytes(empty, receipt: receipt)
            XCTAssertGreaterThan(available, 0)
            let exact = try encoding.encode(String(repeating: "x", count: available), snapshotID: snapshotID)
            XCTAssertEqual(rawBytes(exact, receipt: receipt), 4_096)
            XCTAssertLessThanOrEqual(try serializedParts(exact, receipt: receipt).count, 4_608)
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(exact, actionReceipt: receipt), 0)
            let over = try encoding.encode(String(repeating: "x", count: available + 1), snapshotID: snapshotID)
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(over, actionReceipt: receipt), 1)
        }
        let readAvailable = 4_096 - BrowserCompleteObservation.marker.utf8.count - 1
        let read = String(repeating: "x", count: readAvailable)
        XCTAssertEqual(try BrowserCompleteObservation.Encoding.read.encode(read, snapshotID: snapshotID), read)
        XCTAssertNil(BrowserCompleteObservation.Encoding.read.actionReceipt)
        XCTAssertEqual(rawBytes(read, receipt: nil), 4_096)
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(read), 0)
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(read + "x"), 1)
    }

    func testSerializedLimitIncludesBothEscapingLayersEvenWhenRawTextFits() throws {
        let receipt = cue(wasFill: true)
        let encoding = BrowserCompleteObservation.Encoding.input(wasFill: true, receipt: receipt)
        let page = String(repeating: "\\", count: 1_200) + "e\u{301} 🙂 \"\n\t\u{0001}"
        let envelope = try encoding.encode(page, snapshotID: snapshotID)
        let serialized = try serializedParts(envelope, receipt: receipt)
        XCTAssertLessThanOrEqual(rawBytes(envelope, receipt: receipt), 4_096)
        XCTAssertGreaterThan(serialized.count, 4_608)
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(envelope, actionReceipt: receipt),
                       serialized.count - 4_608)
        let body = try object(envelope)
        let observation = try XCTUnwrap(body["current_observation"] as? [String: Any])
        XCTAssertEqual(Array(try XCTUnwrap(observation["text"] as? String).utf8), Array(page.utf8))
    }

    func testInputReferenceReservationCoversNestedEscapingOfBothReferenceKinds() throws {
        let receipt = cue(wasFill: true)
        let encoding = BrowserCompleteObservation.Encoding.input(wasFill: true, receipt: receipt)
        let row = #"0 AXTextField label="quoted \" é 🙂""#
        let suffixes = [
            #" click_ref="bclick_00000000-0000-0000-0000-000000000010""#,
            #" fill_ref="bfill_00000000-0000-0000-0000-000000000011""#,
        ]
        let base = try encoding.encode(row, snapshotID: snapshotID)
        for suffix in suffixes {
            let published = try encoding.encode(row + suffix, snapshotID: snapshotID)
            XCTAssertLessThanOrEqual(rawBytes(published, receipt: receipt) - rawBytes(base, receipt: receipt), 64)
            XCTAssertLessThanOrEqual(try serializedParts(published, receipt: receipt).count
                                    - serializedParts(base, receipt: receipt).count, 64)
        }
        let published = try encoding.encode(row + suffixes.joined(), snapshotID: snapshotID)
        XCTAssertLessThanOrEqual(try serializedParts(published, receipt: receipt).count
                                - serializedParts(base, receipt: receipt).count, 128)
        let padding = String(repeating: "x", count: 4_096 - rawBytes(base, receipt: receipt) - 100)
        let nearBoundary = try encoding.encode(padding + row, snapshotID: snapshotID)
        let nearBoundaryPublished = try encoding.encode(padding + row + suffixes.joined(), snapshotID: snapshotID)
        XCTAssertGreaterThan(try BrowserCompleteObservation.excessBytes(nearBoundaryPublished, actionReceipt: receipt), 0)
        XCTAssertGreaterThanOrEqual(try BrowserCompleteObservation.excessBytes(nearBoundary, referenceReserve: 128,
                                                                              actionReceipt: receipt),
                                    try BrowserCompleteObservation.excessBytes(nearBoundaryPublished, actionReceipt: receipt))
    }

    private func cue(wasFill: Bool) -> String {
        wasFill
            ? #"{"dispatched":true,"kind":"fill","label":"Message","outcome":"unverified","partial":false}"#
            : #"{"dispatched":true,"kind":"click","label":"Send message","outcome":"unverified","partial":false}"#
    }

    private func rawBytes(_ text: String, receipt: String?) -> Int {
        let texts = [BrowserCompleteObservation.marker] + (receipt.map { [$0] } ?? []) + [text]
        return texts.reduce(texts.count - 1) { $0 + $1.utf8.count }
    }

    private func serializedParts(_ text: String, receipt: String?) throws -> Data {
        let texts = [BrowserCompleteObservation.marker] + (receipt.map { [$0] } ?? []) + [text]
        return try JSONSerialization.data(withJSONObject: texts.map { ComputerReadPublication.text($0) }, options: [.sortedKeys])
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

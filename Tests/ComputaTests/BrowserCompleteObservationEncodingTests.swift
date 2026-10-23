import Foundation
import XCTest
@testable import Computa

final class BrowserCompleteObservationEncodingTests: XCTestCase {
    private let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000227")!

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

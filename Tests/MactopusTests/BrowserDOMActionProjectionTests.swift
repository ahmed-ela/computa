import Foundation
import XCTest
@testable import Mactopus

final class BrowserDOMActionProjectionTests: XCTestCase {
    private let url = URL(string: "https://example.test/#inbox")!
    private func raw() -> [String: Any] {
        ["strings": ["main", url.absoluteString, "pointer", "visible", "flex", "auto"],
         "documents": [["frameId": 0, "documentURL": 1,
            "nodes": ["backendNodeId": [10, 20, 30], "isClickable": ["index": [1]]],
            "layout": ["nodeIndex": [0, 0, 1, 2],
                       "styles": [[2, 3, 4, 5], [], [2, 3, 4, 5], []],
                       "bounds": [[0, 0, 10, 10], [0, 0, 10, 10], [0, 20, 10, 10], [0, 0, 0, 0]]],
         ]]]
    }
    private func parse(_ value: [String: Any]) throws -> BrowserDOMActionProjection {
        try BrowserDOMActionProjection.parse(value, frameID: "main", url: url)
    }
    private func changeDocument(_ value: [String: Any], _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var value = value
        var documents = value["documents"] as! [[String: Any]]
        edit(&documents[0]); value["documents"] = documents
        return value
    }
    func testRawProjectionSupportsFragmentsEmptyStylesAndExactNodesOnly() throws {
        let value = try parse(raw())
        XCTAssertEqual(value.clickable, [20])
        XCTAssertEqual(value.pointer, [10, 20])
        XCTAssertFalse(value.truncated)
    }
    func testProjectedAndRawEvidenceAgree() throws {
        let value = try parse(["mactopusClickability": [
            "frameId": "main", "documentURL": url.absoluteString,
            "clickableBackendNodeIds": [20], "pointerBackendNodeIds": [10, 20],
            "sourceTruncated": false, "sourceNodeCount": 3,
        ]])
        let expected = try parse(raw())
        XCTAssertEqual(value.clickable, expected.clickable)
        XCTAssertEqual(value.pointer, expected.pointer)
    }
    func testHiddenZeroAreaOrPointerEventsNoneCannotGrantPointerCandidate() throws {
        for (slot, replacement) in [(0, "default"), (1, "hidden"), (2, "none"), (3, "none")] {
            var value = raw()
            var strings = value["strings"] as! [String]
            strings[slot + 2] = replacement; value["strings"] = strings
            XCTAssertTrue(try parse(value).pointer.isEmpty)
            XCTAssertEqual(try parse(value).clickable, [20], "Direct click listener provenance remains separate")
        }
        let zero = changeDocument(raw()) { doc in
            var layout = doc["layout"] as! [String: Any]
            layout["bounds"] = Array(repeating: [0, 0, 0, 10], count: 4); doc["layout"] = layout
        }
        XCTAssertTrue(try parse(zero).pointer.isEmpty)
    }
    func testMalformedBoundsStylesAndIdentityFailClosed() throws {
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["frameId"] = 1 }, { $0["documentURL"] = 0 },
            { $0["nodes"] = ["backendNodeId": [10, 10, 30]] },
            { $0["nodes"] = ["backendNodeId": [10, true, 30]] },
            { $0["nodes"] = ["backendNodeId": [10, 20, 30], "isClickable": ["index": [1, 1]]] },
            { $0["nodes"] = ["backendNodeId": [10, 20, 30], "isClickable": ["index": [1], "value": [false]]] },
            { $0["nodes"] = ["backendNodeId": [10, 20, 30], "isClickable": ["index": [3]]] },
            { $0["layout"] = ["nodeIndex": [0], "styles": [[2]], "bounds": [[0, 0, 10, 10]]] },
            { $0["layout"] = ["nodeIndex": [0], "styles": [[2, 3, 4, 999]], "bounds": [[0, 0, 10, 10]]] },
            { $0["layout"] = ["nodeIndex": [0], "styles": [[2, 3, 4, 5]], "bounds": [[0, 0, Double.infinity, 10]]] },
        ]
        for edit in edits { XCTAssertThrowsError(try parse(changeDocument(raw(), edit))) }
        var duplicate = raw()
        let docs = duplicate["documents"] as! [[String: Any]]
        duplicate["documents"] = docs + docs
        XCTAssertThrowsError(try parse(duplicate))
    }
    func testSubframeEvidenceIsNotPromotedToMainFrame() throws {
        var value = raw()
        var docs = value["documents"] as! [[String: Any]]
        var child = docs[0]; child["frameId"] = 5
        child["nodes"] = ["backendNodeId": [999], "isClickable": ["index": [0]]]
        docs.insert(child, at: 0); value["documents"] = docs
        XCTAssertEqual(try parse(value).clickable, [20])
    }
    func testProjectedDuplicatesInvalidCountsAndBooleansFailClosed() throws {
        let valid: [String: Any] = ["frameId": "main", "documentURL": url.absoluteString,
            "clickableBackendNodeIds": [20], "pointerBackendNodeIds": [10],
            "sourceTruncated": false, "sourceNodeCount": 3]
        for (key, value) in [("clickableBackendNodeIds", [20, 20] as Any),
                             ("pointerBackendNodeIds", [true] as Any),
                             ("sourceNodeCount", 1 as Any), ("sourceNodeCount", 100_001 as Any),
                             ("sourceTruncated", 0 as Any), ("frameId", "other" as Any)] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try parse(["mactopusClickability": invalid]))
        }
    }
}

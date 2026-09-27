import Foundation
import XCTest
@testable import AutomationCore

final class SemanticReadRequestTests: XCTestCase {
    func testOmittedViewDefaultsToAllButRemainsDistinctFromExplicitAll() {
        let omitted = SemanticReadRequest()
        XCTAssertNil(omitted.requestedView)
        XCTAssertEqual(omitted.view, .all)
        let explicit = SemanticReadRequest(view: .all)
        XCTAssertEqual(explicit.requestedView, .all)
        XCTAssertEqual(explicit.view, .all)
        XCTAssertNotEqual(omitted, explicit)
    }

    func testCursorMayOmitOrRepeatOnlyMatchingOriginalFilters() {
        let original = SemanticReadRequest(query: "known text", view: .content)
        let cursor = UUID().uuidString
        for request in [
            SemanticReadRequest(cursor: cursor),
            SemanticReadRequest(view: .content, cursor: cursor),
            SemanticReadRequest(query: "known text", cursor: cursor),
            SemanticReadRequest(query: "  known text\n", view: .content, cursor: cursor),
        ] {
            XCTAssertTrue(request.continues(original))
        }
        for request in [
            SemanticReadRequest(query: "different text", cursor: cursor),
            SemanticReadRequest(query: "KNOWN TEXT", cursor: cursor),
            SemanticReadRequest(query: "", cursor: cursor),
            SemanticReadRequest(view: .all, cursor: cursor),
            SemanticReadRequest(view: .links, cursor: cursor),
            SemanticReadRequest(view: .headings, cursor: cursor),
        ] {
            XCTAssertFalse(request.continues(original))
        }
    }

    func testImplicitAllCanBeRepeatedButAbsentQueryCannotBeReplaced() {
        let original = SemanticReadRequest()
        let cursor = UUID().uuidString
        XCTAssertTrue(SemanticReadRequest(view: .all, cursor: cursor).continues(original))
        XCTAssertFalse(SemanticReadRequest(query: "", cursor: cursor).continues(original))
        XCTAssertFalse(SemanticReadRequest(query: "new query", cursor: cursor).continues(original))
        XCTAssertFalse(SemanticReadRequest(view: .content, cursor: cursor).continues(original))
    }

    func testContinuationCannotAddAnySubtreeSelectorOrOmitItsCursor() {
        let original = SemanticReadRequest(view: .headings)
        let cursor = UUID().uuidString
        let snapshot = UUID()
        for request in [
            SemanticReadRequest(view: .headings),
            SemanticReadRequest(cursor: cursor, snapshotID: snapshot),
            SemanticReadRequest(cursor: cursor, elementIndex: 0),
            SemanticReadRequest(cursor: cursor, snapshotID: snapshot, elementIndex: 0),
        ] {
            XCTAssertFalse(request.continues(original))
        }
        // A retained subtree may continue, but the caller cannot borrow its
        // snapshot/index to redirect a cursor into a newly requested subtree.
        XCTAssertTrue(SemanticReadRequest(cursor: cursor).continues(
            .init(view: .headings, snapshotID: snapshot, elementIndex: 0)))
    }
}

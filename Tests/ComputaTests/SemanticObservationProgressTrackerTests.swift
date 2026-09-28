import XCTest
@testable import Computa

final class SemanticObservationProgressTrackerTests: XCTestCase {
    private let first = "11111111-1111-4111-8111-111111111111"
    private let second = "22222222-2222-4222-8222-222222222222"
    private let third = "33333333-3333-4333-8333-333333333333"

    func testFreshSnapshotIDsDoNotDisguiseUnchangedObservation() {
        var tracker = SemanticObservationProgressTracker()
        let original = snapshot(id: first)
        XCTAssertEqual(tracker.observe(text: original), original)
        let retry = snapshot(id: second)
        XCTAssertEqual(tracker.observe(text: retry), retry + "\n" + SemanticObservationProgressTracker.notice)
        XCTAssertTrue(tracker.observe(text: snapshot(id: third)).contains("NO_PROGRESS:"))
    }

    func testAlternatingRecentObservationsCannotAvoidNotice() {
        var tracker = SemanticObservationProgressTracker()
        let a = snapshot(id: first, text: "Alpha")
        let b = snapshot(id: second, text: "Beta")
        XCTAssertEqual(tracker.observe(text: a), a)
        XCTAssertEqual(tracker.observe(text: b), b)
        XCTAssertTrue(tracker.observe(text: snapshot(id: third, text: "Alpha")).contains("NO_PROGRESS:"))
        XCTAssertTrue(tracker.observe(text: snapshot(id: first, text: "Beta")).contains("NO_PROGRESS:"))
    }

    func testCursorCapabilityChangesAreNotContentProgress() {
        var tracker = SemanticObservationProgressTracker()
        let initial = "READ view=content offset=0 shown=1 next_cursor=\(first)\n" + snapshot(id: first)
        let retry = "READ view=content offset=0 shown=1 next_cursor=\(second)\n" + snapshot(id: second)
        XCTAssertEqual(tracker.observe(text: initial), initial)
        XCTAssertTrue(tracker.observe(text: retry).contains("NO_PROGRESS:"))
    }

    func testLegitimatelyAdvancingRepeatedLabelPagesAreProgress() {
        var tracker = SemanticObservationProgressTracker()
        for (offset, id) in [first, second, third].enumerated() {
            let page = "READ view=content offset=\(offset) shown=1 next_cursor=\(id)\n" + snapshot(id: id)
            XCTAssertEqual(tracker.observe(text: page), page)
        }
    }

    func testNativeCoverageAndCursorExhaustionRemainSignificant() {
        var tracker = SemanticObservationProgressTracker()
        for (coverage, cursor, id) in [(100, first, first), (200, second, second), (200, "-", third)] {
            let page = "SEMANTIC_READ view=all visited=\(coverage) matched=1 shown=1 next_cursor=\(cursor)\n" + snapshot(id: id)
            XCTAssertEqual(tracker.observe(text: page), page)
        }
    }

    func testDocumentScopeAndEpochRemainSignificant() {
        var tracker = SemanticObservationProgressTracker()
        let pages = [
            "READ view=content scope_node=1 offset=0 source_truncated=1",
            "READ view=content scope_node=2 offset=0 source_truncated=1",
            "READ view=headings scope_node=2 offset=0 source_truncated=1",
            "READ view=headings scope_node=2 offset=0 source_truncated=0",
        ].map { $0 + "\n" + snapshot(id: first) }
        for page in pages { XCTAssertEqual(tracker.observe(text: page), page) }
        let epochA = snapshot(id: first, extraHeader: " document_epoch=\(first)")
        let epochB = snapshot(id: second, extraHeader: " document_epoch=\(second)")
        XCTAssertEqual(tracker.observe(text: epochA), epochA)
        XCTAssertEqual(tracker.observe(text: epochB), epochB)
    }

    func testRawNodeDataAndQuotedHeaderValuesAreNeverNormalized() {
        var tracker = SemanticObservationProgressTracker()
        let firstNode = snapshot(id: first, text: "snapshot_id=\(first)")
        let secondNode = snapshot(id: second, text: "snapshot_id=\(second)")
        XCTAssertEqual(tracker.observe(text: firstNode), firstNode)
        XCTAssertEqual(tracker.observe(text: secondNode), secondNode)
        let firstTitle = snapshot(id: first, extraHeader: " title=\"Escaped \\\" title snapshot_id=\(first) end\"")
        let secondTitle = snapshot(id: second, extraHeader: " title=\"Escaped \\\" title snapshot_id=\(second) end\"")
        XCTAssertEqual(tracker.observe(text: firstTitle), firstTitle)
        XCTAssertEqual(tracker.observe(text: secondTitle), secondTitle)
    }

    func testOnlyRecognizedVolatileMetadataFieldsAreNormalized() {
        var tracker = SemanticObservationProgressTracker()
        let firstObservation = "WINDOW_CAPTURE capture_id=\(first) window=7\n" + snapshot(id: first)
        let retry = "WINDOW_CAPTURE capture_id=\(second) window=7\n" + snapshot(id: second)
        XCTAssertEqual(tracker.observe(text: firstObservation), firstObservation)
        XCTAssertTrue(tracker.observe(text: retry).contains("NO_PROGRESS:"))
        let differentWindow = "WINDOW_CAPTURE capture_id=\(third) window=8\n" + snapshot(id: third)
        XCTAssertEqual(tracker.observe(text: differentWindow), differentWindow)
        let arbitraryTextA = "Page content snapshot_id=\(first)"
        let arbitraryTextB = "Page content snapshot_id=\(second)"
        XCTAssertEqual(tracker.observe(text: arbitraryTextA), arbitraryTextA)
        XCTAssertEqual(tracker.observe(text: arbitraryTextB), arbitraryTextB)
    }

    func testBoundedHistoryEvictsOldObservationsAndResetAllowsFreshTurn() {
        var tracker = SemanticObservationProgressTracker(historyLimit: 2)
        let a = snapshot(id: first, text: "Alpha")
        let b = snapshot(id: first, text: "Beta")
        let c = snapshot(id: first, text: "Gamma")
        XCTAssertEqual(tracker.observe(text: a), a)
        XCTAssertEqual(tracker.observe(text: b), b)
        XCTAssertEqual(tracker.observe(text: c), c)
        XCTAssertEqual(tracker.observe(text: a), a)
        XCTAssertTrue(tracker.observe(text: a).contains("NO_PROGRESS:"))
        tracker.reset()
        XCTAssertEqual(tracker.observe(text: a), a)
        XCTAssertEqual(SemanticObservationProgressTracker(historyLimit: 0).historyLimit, 1)
        XCTAssertEqual(SemanticObservationProgressTracker(historyLimit: .max).historyLimit, 64)
    }

    func testNoticeOffersReadRecoveryWithoutClaimingSuccessOrNewChat() {
        let notice = SemanticObservationProgressTracker.notice
        for guidance in ["content", "headings", "links", "subtree", "next_cursor", "snapshot_id", "element_index"] {
            XCTAssertTrue(notice.contains(guidance))
        }
        XCTAssertFalse(notice.contains("new chat"))
        XCTAssertFalse(notice.contains("Succeeded"))
        XCTAssertTrue(notice.contains("Missing text is not proof of absence"))
        XCTAssertLessThanOrEqual(notice.count, 500)
    }

    private func snapshot(id: String, text: String = "A repeated title", extraHeader: String = "") -> String {
        "AXSNAPSHOT id=\(id) pid=42 shown=1 total=1 source_truncated=0 output_truncated=0\(extraHeader)\n"
            + "#1 role=\"AXHeading\" label=\"\(text)\" actions=[]"
    }
}

import XCTest
@testable import Computa

final class BrowserTurnExecutionCheckpointTests: XCTestCase {
    func testChronologyCannotBePromotedToSearchOrPermissionEvidence() {
        var checkpoint = BrowserTurnExecutionCheckpoint()
        XCTAssertTrue(checkpoint.text.contains("No browser operations"))
        checkpoint.record(callID: "open", tool: "browser_open", succeeded: true)
        checkpoint.record(callID: "read", tool: "browser_read", succeeded: true)
        XCTAssertTrue(checkpoint.text.contains("browser_open: completed=1 failed=0"))
        XCTAssertTrue(checkpoint.text.contains("browser_read: completed=1 failed=0"))
        XCTAssertFalse(checkpoint.text.contains("browser_fill:"))
        XCTAssertTrue(checkpoint.text.contains("Existing page state may predate this turn"))
        XCTAssertTrue(checkpoint.text.contains("counts never establish site results or their absence"))
    }

    func testPublicationFailureDoesNotReclassifyExecutedInputOrDoubleCount() {
        var checkpoint = BrowserTurnExecutionCheckpoint()
        checkpoint.record(callID: "same", tool: "browser_click", succeeded: true)
        checkpoint.record(callID: "same", tool: "browser_click", succeeded: false)
        checkpoint.record(callID: "another", tool: "browser_click", succeeded: false)
        checkpoint.record(callID: "invented", tool: "browser_search_succeeded", succeeded: true)
        XCTAssertTrue(checkpoint.text.contains("browser_click: completed=1 failed=1"))
        XCTAssertFalse(checkpoint.text.contains("browser_search_succeeded"))
        XCTAssertTrue(checkpoint.text.contains("failed operation may have dispatched input"))
        XCTAssertTrue(BrowserTurnExecutionCheckpoint().text.contains("No browser operations"))
    }

    func testBoundedCheckpointNeverClaimsExhaustiveCountsAfterCapacity() {
        var checkpoint = BrowserTurnExecutionCheckpoint()
        for id in 0..<4_100 { checkpoint.record(callID: String(id), tool: "browser_read", succeeded: true) }
        XCTAssertTrue(checkpoint.text.contains("bounded lower counts"))
        XCTAssertTrue(checkpoint.text.contains("completed=4096 failed=0"))
        XCTAssertLessThan(checkpoint.text.utf8.count, 4_096)
    }
}

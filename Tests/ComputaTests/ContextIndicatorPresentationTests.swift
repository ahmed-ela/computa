import XCTest
@testable import Computa

final class ContextIndicatorPresentationTests: XCTestCase {
    func testUnknownIsNotReportedAsZero() {
        let result = ContextIndicatorPresentation(usage: nil, compaction: nil)
        XCTAssertNil(result.fraction)
        XCTAssertEqual(result.label, "Context —")
        XCTAssertEqual(result.accessibilityValue, "Usage not available")
    }

    func testMeasuredZeroIsDifferentFromUnknown() {
        let result = ContextIndicatorPresentation(usage: usage(0), compaction: nil)
        XCTAssertEqual(result.fraction, 0)
        XCTAssertEqual(result.label, "0% context")
        XCTAssertTrue(result.accessibilityValue.contains("0 of 8192"))
    }

    func testUsesMeasuredWindowAndClampsOverfullRing() {
        let half = ContextIndicatorPresentation(usage: usage(4096), compaction: nil)
        XCTAssertEqual(half.fraction, 0.5)
        XCTAssertEqual(half.label, "50% context")
        XCTAssertFalse(half.needsAttention)
        let overfull = ContextIndicatorPresentation(usage: usage(9000), compaction: nil)
        XCTAssertEqual(overfull.fraction, 1)
        XCTAssertTrue(overfull.needsAttention)
        XCTAssertTrue(overfull.accessibilityValue.contains("9000 of 8192"))
    }

    func testMissingWindowDoesNotInventCapacity() {
        let result = ContextIndicatorPresentation(usage: usage(4000, window: nil), compaction: nil)
        XCTAssertNil(result.fraction)
        XCTAssertEqual(result.label, "Context —")
    }

    func testRunningCompactionSuppressesStalePercentage() {
        let result = ContextIndicatorPresentation(usage: usage(8000), compaction: .running)
        XCTAssertNil(result.fraction)
        XCTAssertEqual(result.label, "Compacting context…")
        XCTAssertEqual(result.accessibilityValue, "Compacting")
    }

    func testCompactedWithoutMeasurementStaysUnknown() {
        let result = ContextIndicatorPresentation(usage: nil, compaction: .completed)
        XCTAssertNil(result.fraction)
        XCTAssertTrue(result.detail.contains("was compacted"))
        XCTAssertFalse(result.label.contains("0%"))
    }

    func testFailureIsVisibleAndDoesNotPretendToHaveReclaimedTokens() {
        let result = ContextIndicatorPresentation(usage: usage(7000), compaction: .failed(message: "Disconnected"))
        XCTAssertEqual(result.fraction, Double(7000) / 8192)
        XCTAssertTrue(result.needsAttention)
        XCTAssertTrue(result.detail.contains("Disconnected"))
    }

    private func usage(_ count: Int, window: Int? = 8192) -> RuntimeContextUsage {
        RuntimeContextUsage(usedTokens: count, contextWindow: window, inputTokens: count,
            outputTokens: 0, turnID: "turn", measuredAt: .now)
    }
}

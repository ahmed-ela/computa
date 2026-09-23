import XCTest
@testable import LocalCodex

final class AppServerCompletedToolItemContractTests: XCTestCase {
    func testDynamicToolFailureUsesSuccessFlagAndReturnedMessage() {
        let item: [String: Any] = [
            "type": "dynamicToolCall",
            "tool": "computer",
            "status": "completed",
            "success": false,
            "contentItems": [
                ["type": "inputText", "text": "Accessibility permission is not granted."],
            ],
        ]

        XCTAssertEqual(AppServerCompletedToolItemContract.status(for: item), .failed)
        XCTAssertEqual(
            AppServerCompletedToolItemContract.summary(for: item, name: "computer"),
            "Accessibility permission is not granted."
        )
    }

    func testProtocolFailureAndDeclineStatusesAreFailures() {
        XCTAssertEqual(
            AppServerCompletedToolItemContract.status(for: ["status": "failed"]),
            .failed
        )
        XCTAssertEqual(
            AppServerCompletedToolItemContract.status(for: ["status": "declined"]),
            .failed
        )
    }

    func testSuccessfulDynamicToolCompletionStaysSuccessful() {
        let item: [String: Any] = [
            "status": "completed",
            "success": true,
        ]

        XCTAssertEqual(AppServerCompletedToolItemContract.status(for: item), .succeeded)
        XCTAssertEqual(
            AppServerCompletedToolItemContract.summary(for: item, name: "computer"),
            "computer completed"
        )
    }

    func testSemanticTextLimitMatchesAccessibilityMaximum() {
        XCTAssertEqual(ComputerToolContract.maximumSemanticTextLength, 4_096)
    }

    func testComputerToolFiniteNumbersRejectBooleansAndNonFiniteValues() {
        XCTAssertEqual(ComputerToolArgumentContract.finiteDouble(NSNumber(value: 12.5)), 12.5)
        XCTAssertNil(ComputerToolArgumentContract.finiteDouble(true))
        XCTAssertNil(ComputerToolArgumentContract.finiteDouble(Double.infinity))
        XCTAssertNil(ComputerToolArgumentContract.finiteDouble("12.5"))
    }

    func testComputerToolIntegersRejectBooleansAndFractions() {
        XCTAssertEqual(ComputerToolArgumentContract.exactInt64(NSNumber(value: 42)), 42)
        XCTAssertEqual(ComputerToolArgumentContract.exactInt64(NSNumber(value: 42.0)), 42)
        XCTAssertNil(ComputerToolArgumentContract.exactInt64(false))
        XCTAssertNil(ComputerToolArgumentContract.exactInt64(NSNumber(value: 42.5)))
        XCTAssertNil(ComputerToolArgumentContract.exactInt64(Double.nan))
    }

    func testComputerToolModifierArrayRejectsMalformedPresentValues() {
        XCTAssertEqual(ComputerToolArgumentContract.optionalStringArray(nil), [])
        XCTAssertEqual(
            ComputerToolArgumentContract.optionalStringArray(["command", "shift"]),
            ["command", "shift"]
        )
        XCTAssertNil(ComputerToolArgumentContract.optionalStringArray("command"))
        XCTAssertNil(ComputerToolArgumentContract.optionalStringArray(["command", 1] as [Any]))
    }
}

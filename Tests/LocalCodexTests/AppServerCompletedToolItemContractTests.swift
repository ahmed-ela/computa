import AutomationCore
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

    func testAccessibilityTargetCarriesVerifiedChromeBundleIdentity() {
        let chrome = RunningApplicationInfo(
            processIdentifier: 820,
            bundleIdentifier: "com.google.Chrome",
            localizedName: "Google Chrome",
            activationPolicy: .regular,
            isActive: true,
            isHidden: false,
            isTerminated: false
        )
        let other = RunningApplicationInfo(
            processIdentifier: 821,
            bundleIdentifier: "example.other",
            localizedName: "Other",
            activationPolicy: .regular,
            isActive: false,
            isHidden: false,
            isTerminated: false
        )

        XCTAssertEqual(
            ComputerToolContract.accessibilityTarget(
                processIdentifier: 820,
                runningApplications: [other, chrome]
            ),
            AccessibilityApplicationTarget(
                processIdentifier: 820,
                bundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome"
            )
        )
        XCTAssertNil(
            ComputerToolContract.accessibilityTarget(
                processIdentifier: 822,
                runningApplications: [other, chrome]
            )
        )
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

    func testComputerToolParametersRejectPresentStringInsteadOfSilentlyUsingEmptyObject() throws {
        XCTAssertThrowsError(
            try ComputerToolArgumentContract.parameters(
                in: ["parameters": #"{"pid":820}"#]
            )
        ) { error in
            XCTAssertEqual(
                error as? ComputerToolArgumentContract.ValidationError,
                .parametersMustBeObject
            )
            XCTAssertTrue(error.localizedDescription.contains("JSON object"))
        }
        XCTAssertEqual(try ComputerToolArgumentContract.parameters(in: [:]).count, 0)
        let parameters = try ComputerToolArgumentContract.parameters(
            in: ["parameters": ["process_id": 820]]
        )
        XCTAssertEqual(parameters["process_id"] as? Int, 820)
    }

    func testComputerToolCanonicalProcessIDRemainsValid() throws {
        XCTAssertEqual(
            try ComputerToolArgumentContract.requiredProcessID(["process_id": 820]),
            820
        )
    }

    func testComputerToolNumericPIDAliasIsValidWhenCanonicalKeyIsAbsent() throws {
        XCTAssertEqual(
            try ComputerToolArgumentContract.requiredProcessID(["pid": 820]),
            820
        )
    }

    func testComputerToolPIDAliasRejectsInvalidNumericValues() {
        let invalidValues: [Any] = [
            true,
            NSNumber(value: 820.5),
            NSNumber(value: 0),
            NSNumber(value: -1),
            NSNumber(value: Int64(Int32.max) + 1),
            "820",
        ]
        for value in invalidValues {
            XCTAssertThrowsError(
                try ComputerToolArgumentContract.requiredProcessID(["pid": value])
            ) { error in
                XCTAssertEqual(
                    error as? ComputerToolArgumentContract.ValidationError,
                    .invalidProcessID
                )
            }
        }
    }

    func testComputerToolBothProcessIDKeysAreRejectedEvenWhenEqual() {
        for alias in [820, 821] {
            XCTAssertThrowsError(
                try ComputerToolArgumentContract.requiredProcessID([
                    "process_id": 820,
                    "pid": alias,
                ])
            ) { error in
                XCTAssertEqual(
                    error as? ComputerToolArgumentContract.ValidationError,
                    .ambiguousProcessID
                )
            }
        }
    }
}

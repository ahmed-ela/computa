import Foundation
import XCTest
@testable import AutomationCore

final class AccessibilitySnapshotTextFormatterTests: XCTestCase {
    func testModelDefaultPreservesActionableSnapshotFields() throws {
        let snapshotID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let snapshot = makeSnapshot(
            id: snapshotID,
            elements: [
                makeElement(
                    index: 0,
                    role: "AXApplication",
                    title: "Browser",
                    frame: WindowFrame(x: 0, y: 10.5, width: 1440, height: 900),
                    isEnabled: true,
                    isFocused: true,
                    actions: ["AXRaise"]
                ),
                makeElement(
                    index: 1,
                    parentIndex: 0,
                    role: "AXButton",
                    subrole: "AXCloseButton",
                    title: "Close",
                    value: "ready",
                    frame: WindowFrame(x: 14, y: 24, width: 18, height: 18),
                    isEnabled: false,
                    isFocused: false,
                    actions: ["AXPress", "AXShowMenu"],
                    isValueSettable: true
                ),
            ]
        )

        let output = snapshot.formattedForModel()

        XCTAssertTrue(output.contains("AXSNAPSHOT id=00000000-0000-0000-0000-000000000123"))
        XCTAssertTrue(output.contains("pid=4242 app=\"Example App\" bundle=\"example.app\" root=0"))
        XCTAssertTrue(output.contains("shown=2 total=2 source_truncated=0 output_truncated=0"))
        XCTAssertTrue(output.contains(
            "#0 parent=- role=\"AXApplication\" label=\"Browser\" value=- "
                + "frame=[0,10.5,1440,900] enabled=1 focused=1 "
                + "actions=[\"AXRaise\"] settable=0"
        ))
        XCTAssertTrue(output.contains(
            "#1 parent=0 role=\"AXButton/AXCloseButton\" label=\"Close\" value=\"ready\" "
                + "frame=[14,24,18,18] enabled=0 focused=0 "
                + "actions=[\"AXPress\",\"AXShowMenu\"] settable=1"
        ))
    }

    func testFormatterBoundsElementsFieldsAndActionsAndReportsTruncation() {
        let snapshot = makeSnapshot(
            elements: (0 ..< 4).map { index in
                makeElement(
                    index: index,
                    parentIndex: index == 0 ? nil : 0,
                    role: "AXButton",
                    title: "Long\nbutton label \(index)",
                    value: "oversized value",
                    actions: ["AXPress", "AXShowMenu"]
                )
            }
        )
        let formatter = AccessibilitySnapshotTextFormatter(
            elementLimit: 2,
            fieldCharacterLimit: 8,
            actionLimit: 1,
            outputCharacterLimit: 10_000
        )

        let output = formatter.format(snapshot)

        XCTAssertTrue(output.contains("shown=2 total=4 source_truncated=0 output_truncated=1"))
        XCTAssertTrue(output.contains("label=\"Long bu…\""))
        XCTAssertTrue(output.contains("value=\"oversiz…\""))
        XCTAssertTrue(output.contains("actions=[\"AXPress\"]"))
        XCTAssertTrue(output.contains("#1 parent=0"))
        XCTAssertFalse(output.contains("#2 parent=0"))
        XCTAssertFalse(output.contains("\nbutton"))
    }

    func testFormatterReportsSourceTruncationWithoutOutputTruncation() {
        let snapshot = makeSnapshot(
            elements: [makeElement(index: 0, role: "AXApplication")],
            wasTruncated: true
        )

        let output = snapshot.formattedForModel()

        XCTAssertTrue(output.contains("source_truncated=1 output_truncated=0"))
    }

    func testOutputCharacterBudgetDropsWholeElementsAndKeepsMetadata() {
        let snapshot = makeSnapshot(
            elements: (0 ..< 20).map { index in
                makeElement(
                    index: index,
                    parentIndex: index == 0 ? nil : 0,
                    role: "AXStaticText",
                    title: String(repeating: "x", count: 80)
                )
            }
        )
        let formatter = AccessibilitySnapshotTextFormatter(
            elementLimit: 20,
            fieldCharacterLimit: 80,
            outputCharacterLimit: 512
        )

        let output = formatter.format(snapshot)

        XCTAssertLessThanOrEqual(output.count, 512)
        XCTAssertTrue(output.hasPrefix("AXSNAPSHOT id="))
        XCTAssertTrue(output.contains("pid=4242"))
        XCTAssertTrue(output.contains("total=20"))
        XCTAssertTrue(output.contains("output_truncated=1"))
    }

    func testRelevantElementOrderingKeepsLateActionableControlsWithinBudget() {
        var elements = (0 ..< 24).map { index in
            makeElement(
                index: index,
                parentIndex: index == 0 ? nil : 0,
                role: index == 0 ? "AXWindow" : "AXStaticText",
                title: index == 0 ? nil : "Verbose passive content \(index)",
                value: index == 0 ? nil : "A value that must not outrank an actionable control"
            )
        }
        elements.append(makeElement(
            index: 24,
            parentIndex: 0,
            role: "AXButton",
            title: "Complete computer-use test",
            actions: ["AXPress"]
        ))
        let snapshot = makeSnapshot(elements: elements)
        let formatter = AccessibilitySnapshotTextFormatter(
            elementLimit: 25,
            fieldCharacterLimit: 80,
            outputCharacterLimit: 700,
            prioritizesRelevantElements: true
        )

        let output = formatter.format(snapshot)

        XCTAssertTrue(output.contains("#0 parent=-"))
        XCTAssertTrue(output.contains("#24 parent=0 role=\"AXButton\""))
        XCTAssertTrue(output.contains("Complete computer-use test"))
        XCTAssertTrue(output.contains("output_truncated=1"))
    }

    func testPreferredTextAndCompactLinesSurfaceMatchingControl() {
        var elements = [makeElement(index: 0, role: "AXWindow")]
        elements += (1 ... 20).map { index in
            makeElement(
                index: index,
                parentIndex: 0,
                role: "AXButton",
                title: "Earlier button \(index)",
                actions: ["AXPress"]
            )
        }
        elements.append(makeElement(
            index: 21,
            parentIndex: 0,
            role: "AXButton",
            title: "Unique target",
            actions: ["AXPress"]
        ))
        let formatter = AccessibilitySnapshotTextFormatter(
            elementLimit: 22,
            fieldCharacterLimit: 80,
            outputCharacterLimit: 512,
            prioritizesRelevantElements: true,
            preferredText: "unique target",
            usesCompactElementLines: true
        )

        let output = formatter.format(makeSnapshot(elements: elements))

        XCTAssertTrue(output.contains("#21 role=\"AXButton\" label=\"Unique target\""))
        XCTAssertFalse(output.contains("parent="))
        XCTAssertFalse(output.contains("frame="))
        XCTAssertFalse(output.contains("enabled="))
    }

    func testPreferredTextSurfacesLatePassiveValueAheadOfActionableControls() {
        var elements = [makeElement(index: 0, role: "AXWindow")]
        elements += (1 ... 24).map { index in
            makeElement(
                index: index,
                parentIndex: 0,
                role: "AXButton",
                title: "Toolbar action \(index)",
                actions: ["AXPress"]
            )
        }
        elements.append(makeElement(
            index: 25,
            parentIndex: 0,
            role: "AXStaticText",
            value: "LOCALCODEX_CHROME_OK"
        ))
        let formatter = AccessibilitySnapshotTextFormatter(
            elementLimit: 26,
            fieldCharacterLimit: 80,
            outputCharacterLimit: 512,
            prioritizesRelevantElements: true,
            preferredText: "  localcodex_chrome_ok  ",
            usesCompactElementLines: true
        )

        let output = formatter.format(makeSnapshot(elements: elements))

        XCTAssertEqual(formatter.preferredText, "localcodex_chrome_ok")
        XCTAssertTrue(output.contains(
            "#25 role=\"AXStaticText\" label=- value=\"LOCALCODEX_CHROME_OK\""
        ))
        XCTAssertTrue(output.contains("output_truncated=1"))
    }

    func testModelDefaultUsesCompactLimits() {
        let formatter = AccessibilitySnapshotTextFormatter.modelDefault

        XCTAssertEqual(formatter.elementLimit, 120)
        XCTAssertEqual(formatter.fieldCharacterLimit, 96)
        XCTAssertEqual(formatter.actionLimit, 6)
        XCTAssertEqual(formatter.outputCharacterLimit, 12_000)
        XCTAssertFalse(formatter.prioritizesRelevantElements)
        XCTAssertNil(formatter.preferredText)
        XCTAssertFalse(formatter.usesCompactElementLines)
    }

    private func makeSnapshot(
        id: UUID = UUID(),
        elements: [AccessibilityTreeElement],
        wasTruncated: Bool = false
    ) -> AccessibilityTreeSnapshot {
        AccessibilityTreeSnapshot(
            id: id,
            application: AccessibilityApplicationTarget(
                processIdentifier: 4_242,
                bundleIdentifier: "example.app",
                applicationName: "Example App"
            ),
            limits: .agentDefault,
            rootIndex: elements.first?.index,
            elements: elements,
            wasTruncated: wasTruncated
        )
    }

    private func makeElement(
        index: Int,
        parentIndex: Int? = nil,
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        frame: WindowFrame? = nil,
        isEnabled: Bool? = nil,
        isFocused: Bool? = nil,
        actions: [String] = [],
        isValueSettable: Bool = false
    ) -> AccessibilityTreeElement {
        AccessibilityTreeElement(
            index: index,
            parentIndex: parentIndex,
            childIndices: [],
            depth: parentIndex == nil ? 0 : 1,
            role: role,
            subrole: subrole,
            title: title,
            elementDescription: nil,
            help: nil,
            identifier: nil,
            value: value,
            frame: frame,
            isEnabled: isEnabled,
            isFocused: isFocused,
            supportedActions: actions,
            isValueSettable: isValueSettable
        )
    }
}

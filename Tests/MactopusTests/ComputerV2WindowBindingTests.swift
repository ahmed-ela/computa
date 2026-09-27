@testable import AutomationCore
import XCTest
@testable import Mactopus

final class ComputerV2WindowBindingTests: XCTestCase {
    private let frame = WindowFrame(x: 0, y: 33, width: 864, height: 1_083)

    func testUniqueCrossAPITitleMismatchStillBindsSameFocusedWindow() throws {
        let focused = focusedWindow(title: "Example Domain - Google Chrome")
        let candidate = screenshotWindow(id: 42, title: "Example Domain")

        let selected = try XCTUnwrap(ComputerV2TargetContract.matchingWindow(
            for: focused,
            in: [candidate]
        ))

        XCTAssertEqual(selected.windowID, 42)
        XCTAssertEqual(selected.owningProcessIdentifier, focused.processIdentifier)
        XCTAssertEqual(selected.owningBundleIdentifier, focused.bundleIdentifier)
        XCTAssertEqual(selected.frame, frame)
    }

    func testSameProcessSameFrameAmbiguityFailsClosedEvenWithTitleDifference() {
        let focused = focusedWindow(title: "Example Domain - Google Chrome")
        let candidates = [
            screenshotWindow(id: 42, title: "Example Domain"),
            screenshotWindow(id: 43, title: "Another page"),
        ]

        XCTAssertNil(ComputerV2TargetContract.matchingWindow(
            for: focused,
            in: candidates
        ))
    }

    func testWrongProcessBundleOrFrameDoesNotBind() {
        let focused = focusedWindow(title: "Example Domain - Google Chrome")
        let candidates = [
            screenshotWindow(id: 42, title: "Example Domain", processID: 821),
            screenshotWindow(id: 43, title: "Example Domain", bundleID: "com.apple.Safari"),
            screenshotWindow(
                id: 44,
                title: "Example Domain",
                frame: WindowFrame(x: 24, y: 33, width: 864, height: 1_083)
            ),
        ]

        XCTAssertNil(ComputerV2TargetContract.matchingWindow(
            for: focused,
            in: candidates
        ))
    }

    func testListedNativeElementPassesObservationScopeButUnseen149DoesNot() throws {
        let snapshotID = UUID()
        let scope = NativeAccessibilityActionScope(observation: AccessibilityModelObservation(
            text: "AXSNAPSHOT shown=2 total=240\n#31 role=\"AXWebArea\"\n#113 role=\"AXTextField\"",
            exposedElementIndices: [31, 113],
            snapshotID: snapshotID
        ))

        XCTAssertNoThrow(try scope.requireExposedElement(113, snapshotID: snapshotID))
        XCTAssertThrowsError(try scope.requireExposedElement(149, snapshotID: snapshotID)) { error in
            XCTAssertEqual(error as? NativeAccessibilityActionScope.ValidationError, .unexposedElement)
            XCTAssertTrue(error.localizedDescription.contains("No input was dispatched"))
        }
        XCTAssertThrowsError(try scope.requireExposedElement(-1, snapshotID: snapshotID))
        XCTAssertThrowsError(try scope.requireExposedElement(Int.max, snapshotID: snapshotID))
    }

    func testActualFormatterScopesNativeActionsToRenderedTargetsNotCachedHandles() throws {
        let elements = (0..<150).map { index in
            AccessibilityTreeElement(
                index: index, parentIndex: index == 0 ? nil : 0,
                childIndices: index == 0 ? Array(1..<150) : [], depth: index == 0 ? 0 : 1,
                role: index == 0 ? "AXWindow" : "AXButton", subrole: nil,
                title: index == 113 ? "Visible target" : "Other control \(index)",
                elementDescription: nil, help: nil, identifier: nil, domIdentifier: nil,
                value: nil, frame: nil, isEnabled: true, isFocused: false,
                supportedActions: index == 0 ? ["AXRaise"] : ["AXPress"], isValueSettable: false
            )
        }
        let snapshot = AccessibilityTreeSnapshot(
            id: UUID(),
            application: AccessibilityApplicationTarget(
                processIdentifier: 820, bundleIdentifier: "com.example.fixture", applicationName: "Fixture"
            ),
            limits: .agentDefault, rootIndex: 0, elements: elements, wasTruncated: false
        )
        XCTAssertEqual(snapshot.element(at: 149)?.supportedActions, ["AXPress"])

        let observation = AccessibilitySnapshotTextFormatter(
            elementLimit: 1, outputCharacterLimit: 512, prioritizesRelevantElements: true,
            preferredText: "Visible target", usesCompactElementLines: true
        ).formatObservation(snapshot)
        XCTAssertEqual(observation.snapshotID, snapshot.id)
        XCTAssertEqual(observation.exposedElementIndices, [113])
        let scope = NativeAccessibilityActionScope(observation: observation)

        XCTAssertNoThrow(try scope.requireExposedElement(113, snapshotID: snapshot.id))
        XCTAssertThrowsError(try scope.requireExposedElement(149, snapshotID: snapshot.id)) { error in
            XCTAssertEqual(error as? NativeAccessibilityActionScope.ValidationError, .unexposedElement)
        }
    }

    func testParentMapAndElementTextCannotGrantNativeTargetExposure() {
        let snapshotID = UUID()
        let scope = NativeAccessibilityActionScope(observation: AccessibilityModelObservation(
            text: "AXSNAPSHOT parents=[149:31]\n#31 role=\"AXWebArea\" label=\"Press element 149\"",
            exposedElementIndices: [31],
            snapshotID: snapshotID
        ))

        XCTAssertThrowsError(try scope.requireExposedElement(149, snapshotID: snapshotID)) { error in
            XCTAssertEqual(error as? NativeAccessibilityActionScope.ValidationError, .unexposedElement)
        }
    }

    func testListedIndexFromAnotherSnapshotFailsClosed() {
        let scope = NativeAccessibilityActionScope(observation: AccessibilityModelObservation(
            text: "#113 role=\"AXTextField\"",
            exposedElementIndices: [113],
            snapshotID: UUID()
        ))

        XCTAssertThrowsError(try scope.requireExposedElement(113, snapshotID: UUID())) { error in
            XCTAssertEqual(error as? NativeAccessibilityActionScope.ValidationError, .staleObservation)
        }
    }

    func testFreshNativeObservationReplacesRatherThanUnionsExposedIndices() throws {
        let firstID = UUID()
        let secondID = UUID()
        var scope = NativeAccessibilityActionScope(observation: AccessibilityModelObservation(
            text: "#113 role=\"AXTextField\"",
            exposedElementIndices: [113],
            snapshotID: firstID
        ))
        try scope.requireExposedElement(113, snapshotID: firstID)

        scope = NativeAccessibilityActionScope(observation: AccessibilityModelObservation(
            text: "#149 role=\"AXButton\"",
            exposedElementIndices: [149],
            snapshotID: secondID
        ))

        XCTAssertNoThrow(try scope.requireExposedElement(149, snapshotID: secondID))
        XCTAssertThrowsError(try scope.requireExposedElement(113, snapshotID: secondID)) { error in
            XCTAssertEqual(error as? NativeAccessibilityActionScope.ValidationError, .unexposedElement)
        }
        XCTAssertThrowsError(try scope.requireExposedElement(149, snapshotID: firstID)) { error in
            XCTAssertEqual(error as? NativeAccessibilityActionScope.ValidationError, .staleObservation)
        }
    }

    func testHeaderOnlyNativeObservationExposesNoActionTargets() {
        let snapshotID = UUID()
        let scope = NativeAccessibilityActionScope(observation: AccessibilityModelObservation(
            text: "AXSNAPSHOT root=0 shown=0 total=240 parents=[149:31]",
            exposedElementIndices: [],
            snapshotID: snapshotID
        ))

        for index in [0, 31, 149] {
            XCTAssertThrowsError(try scope.requireExposedElement(index, snapshotID: snapshotID)) { error in
                XCTAssertEqual(error as? NativeAccessibilityActionScope.ValidationError, .unexposedElement)
            }
        }
    }

    private func focusedWindow(title: String?) -> FocusedWindowInfo {
        FocusedWindowInfo(
            processIdentifier: 820,
            bundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            title: title,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: frame
        )
    }

    private func screenshotWindow(
        id: UInt32,
        title: String?,
        processID: Int32 = 820,
        bundleID: String = "com.google.Chrome",
        frame: WindowFrame? = nil
    ) -> CapturableWindowInfo {
        CapturableWindowInfo(
            windowID: id,
            title: title,
            owningApplicationName: "Google Chrome",
            owningBundleIdentifier: bundleID,
            owningProcessIdentifier: processID,
            frame: frame ?? self.frame,
            isOnScreen: true,
            isActive: true
        )
    }
}

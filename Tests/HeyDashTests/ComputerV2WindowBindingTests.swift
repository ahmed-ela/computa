import AutomationCore
import XCTest
@testable import HeyDash

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

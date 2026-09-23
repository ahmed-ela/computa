import Foundation
import XCTest
@testable import AutomationCore

final class WindowHitTestVerifierTests: XCTestCase {
    private let targetID: UInt32 = 41
    private let targetFrame = WindowFrame(x: -100, y: 50, width: 500, height: 400)

    func testAcceptsUncoveredPointWithFrontWindowElsewhere() throws {
        try verify(
            points: [ScreenPoint(x: 100, y: 100)],
            windows: [window(12, x: 300, y: 300, width: 50, height: 50), target]
        )
    }

    func testRejectsFrontWindowCoveringPoint() {
        assertError(.obscuredByWindow(12)) {
            try verify(
                points: [ScreenPoint(x: 100, y: 100)],
                windows: [window(12, x: 90, y: 90, width: 30, height: 30), target]
            )
        }
    }

    func testRejectsOverlayEvenIfItsIdentifierIsUnavailable() {
        assertError(.obscuredByWindow(nil)) {
            try verify(
                points: [ScreenPoint(x: 100, y: 100)],
                windows: [WindowHitTestDescriptor(
                    windowID: nil,
                    frame: WindowFrame(x: 90, y: 90, width: 30, height: 30)
                ), target]
            )
        }
    }

    func testRejectsDragPathCrossingFrontWindowWithClearEndpoints() {
        assertError(.obscuredByWindow(12)) {
            try verify(
                points: [ScreenPoint(x: 10, y: 100), ScreenPoint(x: 200, y: 100)],
                windows: [window(12, x: 90, y: 90, width: 30, height: 30), target]
            )
        }
    }

    func testAcceptsDragPathThatDoesNotCrossFrontWindow() throws {
        try verify(
            points: [ScreenPoint(x: 10, y: 100), ScreenPoint(x: 200, y: 100)],
            windows: [window(12, x: 90, y: 120, width: 30, height: 30), target]
        )
    }

    func testRejectsMissingOrInvalidTargetGeometry() {
        assertError(.expectedWindowMissing(targetID)) {
            try verify(points: [ScreenPoint(x: 100, y: 100)], windows: [])
        }
        assertError(.expectedWindowGeometryUnavailable(targetID)) {
            try verify(
                points: [ScreenPoint(x: 100, y: 100)],
                windows: [WindowHitTestDescriptor(windowID: targetID, frame: nil)]
            )
        }
    }

    func testRejectsPointOutsideExpectedWindow() {
        assertError(.pointOutsideExpectedWindow(targetID)) {
            try verify(points: [ScreenPoint(x: 400, y: 100)], windows: [target])
        }
    }

    func testFailsClosedForUnknownFrontWindowGeometryButIgnoresBehindIt() throws {
        let unknown = WindowHitTestDescriptor(windowID: 12, frame: nil)
        assertError(.frontWindowGeometryUnavailable) {
            try verify(points: [ScreenPoint(x: 100, y: 100)], windows: [unknown, target])
        }
        try verify(points: [ScreenPoint(x: 100, y: 100)], windows: [target, unknown])
    }

    func testZeroAreaFrontWindowCannotIntercept() throws {
        try verify(
            points: [ScreenPoint(x: 100, y: 100)],
            windows: [window(12, x: 100, y: 100, width: 0, height: 10), target]
        )
    }

    func testRejectsEmptyOrNonfinitePoints() {
        assertError(.noActionPoints) {
            try verify(points: [], windows: [target])
        }
        assertError(.invalidActionPoint) {
            try verify(points: [ScreenPoint(x: .nan, y: 100)], windows: [target])
        }
    }

    private var target: WindowHitTestDescriptor {
        WindowHitTestDescriptor(windowID: targetID, frame: targetFrame)
    }

    private func window(
        _ id: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> WindowHitTestDescriptor {
        WindowHitTestDescriptor(
            windowID: id,
            frame: WindowFrame(x: x, y: y, width: width, height: height)
        )
    }

    private func verify(
        points: [ScreenPoint],
        windows: [WindowHitTestDescriptor]
    ) throws {
        try WindowHitTestReducer.verify(
            expectedWindowID: targetID,
            points: points,
            windowsFrontToBack: windows
        )
    }

    private func assertError(
        _ expected: WindowHitTestError,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body()) { error in
            XCTAssertEqual(error as? WindowHitTestError, expected)
        }
    }
}

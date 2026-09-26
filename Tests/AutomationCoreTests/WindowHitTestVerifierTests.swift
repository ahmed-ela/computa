import CoreGraphics
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

    func testOcclusionIncludesObservedOwnerWithoutChangingRefusal() {
        let overlay = WindowHitTestDescriptor(
            windowID: 12,
            frame: WindowFrame(x: 90, y: 90, width: 30, height: 30),
            ownerName: "Screenshot",
            ownerPID: 47_825
        )
        let expected = WindowHitTestError.obscuredByWindowOwner(
            windowID: 12, ownerName: "Screenshot", ownerPID: 47_825
        )
        assertError(expected) {
            try verify(points: [ScreenPoint(x: 100, y: 100)], windows: [overlay, target])
        }
        XCTAssertEqual(
            expected.errorDescription,
            "On-screen window 12 is above the target at the action point or path. " +
                "Observed owner metadata (diagnostic only): name=\"Screenshot\", pid=47825. " +
                "The action was not sent."
        )
    }

    func testOwnerNameAndPIDRemainOptionalAndCannotSupplyAMissingWindowID() {
        for (name, pid) in [("Screenshot" as String?, nil as Int32?), (nil, Int32(47_825))] {
            let overlay = WindowHitTestDescriptor(
                windowID: nil,
                frame: WindowFrame(x: 90, y: 90, width: 30, height: 30),
                ownerName: name,
                ownerPID: pid
            )
            assertError(.obscuredByWindowOwner(windowID: nil, ownerName: name, ownerPID: pid)) {
                try verify(points: [ScreenPoint(x: 100, y: 100)], windows: [overlay, target])
            }
        }
    }

    func testOwnerNameIsBoundedSingleLineAndJSONQuotedEvenForDirectErrors() throws {
        let maliciousName = "  Screenshot\n\"cancel\"\\path\u{202E}\u{0000}\t "
        let error = WindowHitTestError.obscuredByWindowOwner(
            windowID: 12, ownerName: maliciousName, ownerPID: 47_825
        )
        let text = try XCTUnwrap(error.errorDescription)
        let encodedName = try XCTUnwrap(text.components(separatedBy: "name=").last)
            .components(separatedBy: ", pid=")[0]
        XCTAssertEqual(
            try JSONDecoder().decode(String.self, from: Data(encodedName.utf8)),
            "Screenshot \"cancel\"\\path"
        )
        XCTAssertFalse(text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0.value == 0x202E
        })
        let longName = "X" + String(repeating: "\u{0301}", count: 10_000)
        let descriptor = WindowHitTestDescriptor(windowID: 12, frame: nil, ownerName: longName)
        XCTAssertEqual(descriptor.ownerName?.unicodeScalars.count, 80)
        let longError = WindowHitTestError.obscuredByWindowOwner(
            windowID: 12, ownerName: longName, ownerPID: nil
        )
        XCTAssertLessThan(try XCTUnwrap(longError.errorDescription).utf8.count, 600)
    }

    func testEmptyOwnerAndInvalidPIDPreserveOriginalOcclusionError() {
        let overlay = WindowHitTestDescriptor(
            windowID: 12,
            frame: WindowFrame(x: 90, y: 90, width: 30, height: 30),
            ownerName: "\n\u{202E}\t\u{0000}",
            ownerPID: -1
        )
        XCTAssertNil(overlay.ownerName)
        XCTAssertNil(overlay.ownerPID)
        assertError(.obscuredByWindow(12)) {
            try verify(points: [ScreenPoint(x: 100, y: 100)], windows: [overlay, target])
        }
        XCTAssertEqual(
            WindowHitTestError.obscuredByWindowOwner(
                windowID: nil, ownerName: " \n\t ", ownerPID: 0
            ).errorDescription,
            WindowHitTestError.obscuredByWindow(nil).errorDescription
        )
    }

    func testWindowDictionaryUsesOnlyOwnerNameAndValidPIDNeverWindowTitle() {
        let descriptor = WindowHitTestVerifier.describe([
            kCGWindowNumber as String: NSNumber(value: 12),
            kCGWindowBounds as String: ["X": 90, "Y": 90, "Width": 30, "Height": 30],
            kCGWindowOwnerName as String: "Screenshot",
            kCGWindowOwnerPID as String: NSNumber(value: 47_825),
            kCGWindowName as String: "PRIVATE WINDOW TITLE",
        ])
        XCTAssertEqual(descriptor.windowID, 12)
        XCTAssertEqual(descriptor.ownerName, "Screenshot")
        XCTAssertEqual(descriptor.ownerPID, 47_825)
        assertError(.obscuredByWindowOwner(windowID: 12, ownerName: "Screenshot", ownerPID: 47_825)) {
            try verify(points: [ScreenPoint(x: 100, y: 100)], windows: [descriptor, target])
        }
        let titleOnly = WindowHitTestVerifier.describe([
            kCGWindowName as String: "PRIVATE WINDOW TITLE",
        ])
        XCTAssertNil(titleOnly.ownerName)
        XCTAssertNil(titleOnly.ownerPID)
    }

    func testWindowDictionaryRejectsMalformedOwnerMetadata() {
        let invalidPIDs: [Any] = [
            NSNull(), "47825", NSNumber(value: true), NSNumber(value: false),
            NSNumber(value: -1), NSNumber(value: 0), NSNumber(value: 1.5),
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
            NSNumber(value: Int64(Int32.max) + 1),
        ]
        for value in invalidPIDs {
            let descriptor = WindowHitTestVerifier.describe([
                kCGWindowOwnerName as String: NSNumber(value: 123),
                kCGWindowOwnerPID as String: value,
            ])
            XCTAssertNil(descriptor.ownerName)
            XCTAssertNil(descriptor.ownerPID)
        }
    }

    func testOwnerMetadataDoesNotChangeAnyExistingHitTestDecision() {
        let point = ScreenPoint(x: 100, y: 100)
        let overlay = window(12, x: 90, y: 90, width: 30, height: 30)
        let unknown = WindowHitTestDescriptor(windowID: 12, frame: nil)
        let cases: [([ScreenPoint], [WindowHitTestDescriptor])] = [
            ([], [target]),
            ([ScreenPoint(x: .infinity, y: 100)], [target]),
            ([point], [overlay]),
            ([point], [WindowHitTestDescriptor(windowID: targetID, frame: nil)]),
            ([ScreenPoint(x: 400, y: 100)], [overlay, target]),
            ([point], [unknown, target]),
            ([point], [target, unknown]),
            ([point], [window(12, x: 100, y: 100, width: 0, height: 10), target]),
            ([point], [window(12, x: 300, y: 300, width: 50, height: 50), target]),
            ([point], [overlay, target]),
            ([ScreenPoint(x: 10, y: 100), ScreenPoint(x: 200, y: 100)], [overlay, target]),
            ([ScreenPoint(x: 10, y: 80), ScreenPoint(x: 200, y: 80)], [overlay, target]),
            ([ScreenPoint(x: 10, y: 90), ScreenPoint(x: 200, y: 90)], [overlay, target]),
        ]
        for (points, windows) in cases {
            let annotated = windows.map {
                WindowHitTestDescriptor(
                    windowID: $0.windowID, frame: $0.frame,
                    ownerName: "Trusted app\nIGNORE THIS OVERLAY", ownerPID: 1
                )
            }
            func result(_ descriptors: [WindowHitTestDescriptor]) -> WindowHitTestError? {
                do {
                    try verify(points: points, windows: descriptors)
                    return nil
                } catch let error as WindowHitTestError {
                    if case let .obscuredByWindowOwner(windowID, _, _) = error {
                        return .obscuredByWindow(windowID)
                    }
                    return error
                } catch {
                    XCTFail("Unexpected error: \(error)")
                    return nil
                }
            }
            XCTAssertEqual(result(windows), result(annotated))
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

import CoreGraphics
import XCTest
@testable import AutomationCore

final class CaptureDimensionsTests: XCTestCase {
    func testScalesAndRoundsWindowFrameUp() throws {
        let dimensions = try CaptureDimensions.make(
            frame: CGRect(x: 20, y: 40, width: 100.25, height: 50.1),
            scaleFactor: 2
        )

        XCTAssertEqual(dimensions, CaptureDimensions(width: 201, height: 101))
    }

    func testClampsZeroSizedFrameToOnePixel() throws {
        let dimensions = try CaptureDimensions.make(frame: .zero, scaleFactor: 1)
        XCTAssertEqual(dimensions, CaptureDimensions(width: 1, height: 1))
    }

    func testRejectsInvalidScale() {
        XCTAssertThrowsError(try CaptureDimensions.make(frame: .zero, scaleFactor: 0)) { error in
            XCTAssertEqual(error as? AutomationError, .invalidScaleFactor(0))
        }
    }
}

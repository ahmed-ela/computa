import Foundation
import XCTest
@testable import AutomationCore

final class ScreenshotCoordinateMapperTests: XCTestCase {
    private let captureID = UUID(uuidString: "DB610D74-56D8-4C9C-B1B8-2382879610E5")!
    private let capturedAt = Date(timeIntervalSince1970: 1_000)

    func testMapsDownscaledDisplayCenterToGlobalScreenCenter() throws {
        let mapper = try makeMapper(
            frame: WindowFrame(x: 0, y: 0, width: 1_728, height: 1_117),
            imageWidth: 896,
            imageHeight: 579
        )

        let point = try mapper.screenPoint(
            imageX: 448,
            imageY: 289.5,
            captureID: captureID,
            now: capturedAt.addingTimeInterval(274),
            maximumAge: 600
        )

        XCTAssertEqual(point.x, 864, accuracy: 0.000_001)
        XCTAssertEqual(point.y, 558.5, accuracy: 0.000_001)
    }

    func testAccountsForNegativeGlobalDisplayOrigin() throws {
        let mapper = try makeMapper(
            frame: WindowFrame(x: -1_920, y: 120, width: 1_920, height: 1_080),
            imageWidth: 960,
            imageHeight: 540
        )

        let point = try mapper.screenPoint(
            imageX: 480,
            imageY: 270,
            captureID: captureID,
            now: capturedAt,
            maximumAge: 600
        )

        XCTAssertEqual(point, ScreenPoint(x: -960, y: 660))
    }

    func testMapsFocusedWindowImageWithinItsScreenFrame() throws {
        // ScreenCaptureKit may round the window's point dimensions when it
        // produces an image, so use the actual returned pixel dimensions.
        let windowFrame = WindowFrame(x: -610, y: 120, width: 401, height: 301)
        let mapper = try makeMapper(
            frame: windowFrame,
            imageWidth: 402,
            imageHeight: 302
        )

        let point = try mapper.screenPoint(
            imageX: 201,
            imageY: 151,
            captureID: captureID,
            now: capturedAt,
            maximumAge: 600
        )

        XCTAssertEqual(mapper.frame, windowFrame)
        XCTAssertEqual(point.x, -409.5, accuracy: 0.000_001)
        XCTAssertEqual(point.y, 270.5, accuracy: 0.000_001)
    }

    func testRejectsInvalidFramesAndImageDimensions() {
        let invalidFrames = [
            WindowFrame(x: .nan, y: 0, width: 100, height: 100),
            WindowFrame(x: 0, y: .infinity, width: 100, height: 100),
            WindowFrame(x: 0, y: 0, width: 0, height: 100),
            WindowFrame(x: 0, y: 0, width: 100, height: -1),
            WindowFrame(
                x: Double.greatestFiniteMagnitude,
                y: 0,
                width: Double.greatestFiniteMagnitude,
                height: 100
            ),
        ]
        for frame in invalidFrames {
            XCTAssertThrowsError(try makeMapper(frame: frame)) { error in
                XCTAssertEqual(error as? ScreenshotCoordinateError, .invalidFrame)
            }
        }
        XCTAssertThrowsError(try makeMapper(imageWidth: 0)) { error in
            XCTAssertEqual(
                error as? ScreenshotCoordinateError,
                .invalidImageDimensions(width: 0, height: 100)
            )
        }
        XCTAssertThrowsError(try makeMapper(imageHeight: -1)) { error in
            XCTAssertEqual(
                error as? ScreenshotCoordinateError,
                .invalidImageDimensions(width: 100, height: -1)
            )
        }
    }

    func testRejectsNonfiniteAndOutOfBoundsImagePoints() throws {
        let mapper = try makeMapper()
        let invalidPoints: [(Double, Double)] = [
            (-0.1, 0), (0, -0.1), (100, 0), (0, 100),
            (.nan, 0), (.infinity, 0), (0, -.infinity),
        ]
        for (x, y) in invalidPoints {
            XCTAssertThrowsError(try mapper.screenPoint(
                imageX: x,
                imageY: y,
                captureID: captureID,
                now: capturedAt,
                maximumAge: 600
            )) { error in
                XCTAssertEqual(error as? ScreenshotCoordinateError, .invalidImagePoint)
            }
        }
    }

    func testRejectsWrongCaptureIDAndStaleOrFutureCapture() throws {
        let mapper = try makeMapper()
        XCTAssertThrowsError(try mapper.screenPoint(
            imageX: 50,
            imageY: 50,
            captureID: UUID(),
            now: capturedAt,
            maximumAge: 600
        )) { error in
            XCTAssertEqual(error as? ScreenshotCoordinateError, .captureIdentifierMismatch)
        }
        for now in [
            capturedAt.addingTimeInterval(-1),
            capturedAt.addingTimeInterval(601),
        ] {
            XCTAssertThrowsError(try mapper.screenPoint(
                imageX: 50,
                imageY: 50,
                captureID: captureID,
                now: now,
                maximumAge: 600
            )) { error in
                XCTAssertEqual(error as? ScreenshotCoordinateError, .staleCapture)
            }
        }
    }

    func testRejectsInvalidMaximumAgeAndCaptureTime() throws {
        let mapper = try makeMapper()
        for maximumAge in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try mapper.screenPoint(
                imageX: 50,
                imageY: 50,
                captureID: captureID,
                now: capturedAt,
                maximumAge: maximumAge
            )) { error in
                XCTAssertEqual(error as? ScreenshotCoordinateError, .invalidMaximumAge)
            }
        }
        XCTAssertThrowsError(try makeMapper(
            capturedAt: Date(timeIntervalSince1970: .infinity)
        )) { error in
            XCTAssertEqual(error as? ScreenshotCoordinateError, .invalidCaptureTime)
        }
    }

    private func makeMapper(
        frame: WindowFrame = WindowFrame(x: 0, y: 0, width: 100, height: 100),
        imageWidth: Int = 100,
        imageHeight: Int = 100,
        capturedAt: Date? = nil
    ) throws -> ScreenshotCoordinateMapper {
        try ScreenshotCoordinateMapper(
            frame: frame,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            captureID: captureID,
            capturedAt: capturedAt ?? self.capturedAt
        )
    }
}

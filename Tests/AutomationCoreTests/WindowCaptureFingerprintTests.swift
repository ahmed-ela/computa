import CoreGraphics
import XCTest
@testable import AutomationCore

final class WindowCaptureFingerprintTests: XCTestCase {
    func testIdenticalPixelsProduceTheSameFingerprint() throws {
        let first = try WindowCaptureFingerprint.make(from: image(color: red))
        let second = try WindowCaptureFingerprint.make(from: image(color: red))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.width, 2)
        XCTAssertEqual(first.height, 2)
        XCTAssertEqual(first.sha256Hex.count, 64)
    }

    func testChangedPixelsProduceDifferentFingerprint() throws {
        let first = try WindowCaptureFingerprint.make(from: image(color: red))
        let second = try WindowCaptureFingerprint.make(from: image(color: blue))

        XCTAssertNotEqual(first, second)
    }

    func testRowPaddingDoesNotChangeFingerprint() throws {
        let tightlyPacked = try WindowCaptureFingerprint.make(from: image(color: red, bytesPerRow: 8))
        let padded = try WindowCaptureFingerprint.make(from: image(color: red, bytesPerRow: 16))

        XCTAssertEqual(tightlyPacked, padded)
    }

    func testCropDetectsOnlyChangesInsideTheTargetNeighborhood() throws {
        let region = CGRect(x: 1, y: 1, width: 2, height: 2)
        let baseline = try WindowCaptureFingerprint.make(from: image(color: red, size: 4), pixelRegion: region)
        let changedOutside = try WindowCaptureFingerprint.make(
            from: image(color: red, size: 4, changedPixel: CGPoint(x: 3, y: 3)),
            pixelRegion: region
        )
        let changedInside = try WindowCaptureFingerprint.make(
            from: image(color: red, size: 4, changedPixel: CGPoint(x: 1, y: 1)),
            pixelRegion: region
        )

        XCTAssertEqual(baseline, changedOutside)
        XCTAssertNotEqual(baseline, changedInside)
        XCTAssertEqual(baseline.pixelRegion, region)
        XCTAssertEqual(baseline.width, 4)
        XCTAssertEqual(baseline.height, 4)
    }

    func testCropRejectsFractionalAndOutOfBoundsCoordinates() {
        let source = image(color: red)
        for region in [
            CGRect(x: 0.5, y: 0, width: 1, height: 1),
            CGRect(x: 2, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: 0, height: 1)
        ] {
            XCTAssertThrowsError(try WindowCaptureFingerprint.make(from: source, pixelRegion: region)) { error in
                XCTAssertEqual(error as? WindowCaptureFingerprintError, .invalidPixelRegion)
            }
        }
    }

    func testInvalidDimensionsAndOversizedImageFailClosed() {
        XCTAssertThrowsError(try WindowCaptureFingerprint.validatedBufferSize(width: 0, height: 2)) { error in
            XCTAssertEqual(
                error as? WindowCaptureFingerprintError,
                .invalidDimensions(width: 0, height: 2)
            )
        }
        XCTAssertThrowsError(try WindowCaptureFingerprint.validatedBufferSize(width: Int.max, height: 2)) { error in
            XCTAssertEqual(
                error as? WindowCaptureFingerprintError,
                .imageTooLarge(width: Int.max, height: 2)
            )
        }
        XCTAssertThrowsError(try WindowCaptureFingerprint.validatedBufferSize(width: 8_192, height: 8_192)) { error in
            XCTAssertEqual(
                error as? WindowCaptureFingerprintError,
                .imageTooLarge(width: 8_192, height: 8_192)
            )
        }
    }

    private func image(
        color: CGColor,
        bytesPerRow: Int = 8,
        size: Int = 2,
        changedPixel: CGPoint? = nil
    ) -> CGImage {
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: max(bytesPerRow, size * 4),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if let changedPixel {
            context.setFillColor(blue)
            context.fill(CGRect(x: changedPixel.x, y: changedPixel.y, width: 1, height: 1))
        }
        return context.makeImage()!
    }

    private var red: CGColor { CGColor(red: 1, green: 0, blue: 0, alpha: 1) }
    private var blue: CGColor { CGColor(red: 0, green: 0, blue: 1, alpha: 1) }
}

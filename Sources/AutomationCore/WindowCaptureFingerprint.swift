import CoreGraphics
import CryptoKit
import Foundation

public enum WindowCaptureFingerprintError: Error, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case imageTooLarge(width: Int, height: Int)
    case invalidPixelRegion
    case croppingFailed
    case normalizationFailed
}

/// An exact-content fingerprint of a captured window image.
///
/// Core Graphics images can encode the same pixels with different row strides,
/// channel orders, or color spaces. Redrawing into one sRGB RGBA8 bitmap avoids
/// treating those encoding details as a change to the window's visible pixels.
/// A mismatch means the caller must obtain a fresh observation before acting.
public struct WindowCaptureFingerprint: Equatable, Sendable {
    /// Dimensions of the uncropped source image.
    public let width: Int
    public let height: Int
    /// The exact, integral pixel region used for the fingerprint.
    public let pixelRegion: CGRect
    public let sha256Hex: String

    // Bounded so a malformed or unexpectedly large capture cannot allocate an
    // unbounded normalization bitmap. This accommodates a full 6K display.
    static let maximumPixelCount = 33_554_432

    public static func make(from image: CGImage) throws -> WindowCaptureFingerprint {
        try make(
            from: image,
            pixelRegion: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
    }

    /// Fingerprints an exact crop in source-image pixel coordinates. Use the
    /// same pixel region in each capture when checking whether the intended
    /// action target changed during an approval delay.
    public static func make(from image: CGImage, pixelRegion: CGRect) throws -> WindowCaptureFingerprint {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw WindowCaptureFingerprintError.invalidDimensions(width: sourceWidth, height: sourceHeight)
        }
        let region = try validatedPixelRegion(pixelRegion, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let (bytesPerRow, byteCount) = try validatedBufferSize(width: region.width, height: region.height)
        guard let croppedImage = image.cropping(
            to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        ), croppedImage.width == region.width, croppedImage.height == region.height else {
            throw WindowCaptureFingerprintError.croppingFailed
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WindowCaptureFingerprintError.normalizationFailed
        }

        var pixels = [UInt8](repeating: 0, count: byteCount)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: region.width,
                height: region.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw WindowCaptureFingerprintError.normalizationFailed
            }
            context.interpolationQuality = .none
            context.draw(
                croppedImage,
                in: CGRect(x: 0, y: 0, width: region.width, height: region.height)
            )
        }

        var hasher = SHA256()
        // Domain separation and fixed-width dimensions make the digest
        // unambiguous even if images of different shapes have the same bytes.
        hasher.update(data: Data("LocalCodex.WindowCaptureFingerprint.v2".utf8))
        for component in [sourceWidth, sourceHeight, region.x, region.y, region.width, region.height] {
            hasher.update(data: withUnsafeBytes(of: UInt64(component).bigEndian) { Data($0) })
        }
        pixels.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            hasher.update(data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: bytes.count, deallocator: .none))
        }
        let sha256Hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return WindowCaptureFingerprint(
            width: sourceWidth,
            height: sourceHeight,
            pixelRegion: CGRect(x: region.x, y: region.y, width: region.width, height: region.height),
            sha256Hex: sha256Hex
        )
    }

    private static func validatedPixelRegion(
        _ rectangle: CGRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) throws -> (x: Int, y: Int, width: Int, height: Int) {
        let values = [rectangle.origin.x, rectangle.origin.y, rectangle.width, rectangle.height]
        guard values.allSatisfy({ $0.isFinite && $0.rounded(.towardZero) == $0 }),
              rectangle.origin.x >= 0,
              rectangle.origin.y >= 0,
              rectangle.width > 0,
              rectangle.height > 0,
              rectangle.origin.x <= Double(sourceWidth),
              rectangle.origin.y <= Double(sourceHeight),
              rectangle.width <= Double(sourceWidth),
              rectangle.height <= Double(sourceHeight) else {
            throw WindowCaptureFingerprintError.invalidPixelRegion
        }
        let x = Int(rectangle.origin.x)
        let y = Int(rectangle.origin.y)
        let width = Int(rectangle.width)
        let height = Int(rectangle.height)
        guard width <= sourceWidth - x, height <= sourceHeight - y else {
            throw WindowCaptureFingerprintError.invalidPixelRegion
        }
        return (x, y, width, height)
    }

    static func validatedBufferSize(width: Int, height: Int) throws -> (bytesPerRow: Int, byteCount: Int) {
        guard width > 0, height > 0 else {
            throw WindowCaptureFingerprintError.invalidDimensions(width: width, height: height)
        }
        guard width <= maximumPixelCount / height,
              width <= Int.max / 4 else {
            throw WindowCaptureFingerprintError.imageTooLarge(width: width, height: height)
        }
        let bytesPerRow = width * 4
        guard height <= Int.max / bytesPerRow else {
            throw WindowCaptureFingerprintError.imageTooLarge(width: width, height: height)
        }
        return (bytesPerRow, bytesPerRow * height)
    }
}

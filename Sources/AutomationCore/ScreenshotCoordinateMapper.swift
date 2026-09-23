import Foundation

/// Maps a point in a captured image back to the global screen coordinate space.
///
/// Retain only the mapper for the most recent capture. Replacing it after a new
/// observation or action invalidates earlier capture IDs without relying on
/// model-supplied display geometry.
public struct ScreenshotCoordinateMapper: Sendable {
    public let captureID: UUID
    public let capturedAt: Date
    public let frame: WindowFrame
    public let imageWidth: Int
    public let imageHeight: Int

    public init(
        frame: WindowFrame,
        imageWidth: Int,
        imageHeight: Int,
        captureID: UUID,
        capturedAt: Date
    ) throws {
        guard frame.x.isFinite,
              frame.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0,
              (frame.x + frame.width).isFinite,
              (frame.y + frame.height).isFinite
        else {
            throw ScreenshotCoordinateError.invalidFrame
        }
        guard imageWidth > 0, imageHeight > 0 else {
            throw ScreenshotCoordinateError.invalidImageDimensions(
                width: imageWidth,
                height: imageHeight
            )
        }
        guard capturedAt.timeIntervalSince1970.isFinite else {
            throw ScreenshotCoordinateError.invalidCaptureTime
        }

        self.frame = frame
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.captureID = captureID
        self.capturedAt = capturedAt
    }

    /// `imageX` and `imageY` are continuous image coordinates in the half-open
    /// bounds `[0, imageWidth)` and `[0, imageHeight)` respectively.
    /// `maximumAge` is explicit because a local model may take minutes between
    /// receiving a screenshot and proposing a click.
    public func screenPoint(
        imageX: Double,
        imageY: Double,
        captureID: UUID,
        now: Date = Date(),
        maximumAge: TimeInterval
    ) throws -> ScreenPoint {
        guard captureID == self.captureID else {
            throw ScreenshotCoordinateError.captureIdentifierMismatch
        }
        guard maximumAge.isFinite, maximumAge > 0 else {
            throw ScreenshotCoordinateError.invalidMaximumAge
        }
        guard now.timeIntervalSince1970.isFinite else {
            throw ScreenshotCoordinateError.invalidCaptureTime
        }
        let age = now.timeIntervalSince(capturedAt)
        guard age.isFinite, age >= 0, age <= maximumAge else {
            throw ScreenshotCoordinateError.staleCapture
        }
        guard imageX.isFinite,
              imageY.isFinite,
              imageX >= 0,
              imageY >= 0,
              imageX < Double(imageWidth),
              imageY < Double(imageHeight)
        else {
            throw ScreenshotCoordinateError.invalidImagePoint
        }

        let x = frame.x + imageX * (frame.width / Double(imageWidth))
        let y = frame.y + imageY * (frame.height / Double(imageHeight))
        guard x.isFinite, y.isFinite else {
            throw ScreenshotCoordinateError.invalidMappedPoint
        }
        return ScreenPoint(x: x, y: y)
    }
}

public enum ScreenshotCoordinateError: Error, Equatable, LocalizedError, Sendable {
    case invalidFrame
    case invalidImageDimensions(width: Int, height: Int)
    case invalidCaptureTime
    case invalidMaximumAge
    case captureIdentifierMismatch
    case staleCapture
    case invalidImagePoint
    case invalidMappedPoint

    public var errorDescription: String? {
        switch self {
        case .invalidFrame:
            return "The captured screen frame is invalid. Capture a fresh screenshot."
        case .invalidImageDimensions:
            return "The captured image dimensions are invalid. Capture a fresh screenshot."
        case .invalidCaptureTime:
            return "The capture timestamp is invalid. Capture a fresh screenshot."
        case .invalidMaximumAge:
            return "The maximum capture age must be a positive, finite number of seconds."
        case .captureIdentifierMismatch, .staleCapture:
            return "This screenshot is no longer current. Capture a fresh screenshot."
        case .invalidImagePoint:
            return "The requested point is outside the captured image."
        case .invalidMappedPoint:
            return "The requested point could not be mapped to a finite screen position."
        }
    }
}

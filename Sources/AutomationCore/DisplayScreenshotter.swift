@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

public struct CapturableDisplayInfo: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let frame: WindowFrame
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool

    public init(
        displayID: UInt32,
        frame: WindowFrame,
        pixelWidth: Int,
        pixelHeight: Int,
        isMain: Bool
    ) {
        self.displayID = displayID
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
    }
}

public struct DisplayCaptureLimits: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case maximumWidth
        case maximumHeight
        case maximumPixelCount
    }

    public static let agentDefault = DisplayCaptureLimits(
        validatedMaximumWidth: 2_560,
        maximumHeight: 1_600,
        maximumPixelCount: 4_096_000
    )

    public let maximumWidth: Int
    public let maximumHeight: Int
    public let maximumPixelCount: Int

    public init(
        maximumWidth: Int = 2_560,
        maximumHeight: Int = 1_600,
        maximumPixelCount: Int = 4_096_000
    ) throws {
        guard (1 ... 8_192).contains(maximumWidth) else {
            throw DisplayScreenshotError.invalidLimit(name: "maximumWidth", value: maximumWidth)
        }
        guard (1 ... 8_192).contains(maximumHeight) else {
            throw DisplayScreenshotError.invalidLimit(name: "maximumHeight", value: maximumHeight)
        }
        guard (1 ... 33_554_432).contains(maximumPixelCount) else {
            throw DisplayScreenshotError.invalidLimit(
                name: "maximumPixelCount",
                value: maximumPixelCount
            )
        }
        self.init(
            validatedMaximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            maximumPixelCount: maximumPixelCount
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumWidth: container.decode(Int.self, forKey: .maximumWidth),
            maximumHeight: container.decode(Int.self, forKey: .maximumHeight),
            maximumPixelCount: container.decode(Int.self, forKey: .maximumPixelCount)
        )
    }

    private init(
        validatedMaximumWidth: Int,
        maximumHeight: Int,
        maximumPixelCount: Int
    ) {
        maximumWidth = validatedMaximumWidth
        self.maximumHeight = maximumHeight
        self.maximumPixelCount = maximumPixelCount
    }
}

public enum DisplayScreenshotError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimit(name: String, value: Int)
    case invalidDisplayDimensions(width: Int, height: Int)
    case displayNotFound(UInt32?)

    public var errorDescription: String? {
        switch self {
        case let .invalidLimit(name, value):
            return "Display capture limit '\(name)' has an invalid value: \(value)."
        case let .invalidDisplayDimensions(width, height):
            return "Display dimensions must be positive; received \(width)x\(height)."
        case let .displayNotFound(displayID):
            if let displayID {
                return "No ScreenCaptureKit display was found for display ID \(displayID)."
            }
            return "ScreenCaptureKit did not report a main or fallback display."
        }
    }
}

struct DisplayCaptureDimensions: Equatable, Sendable {
    let width: Int
    let height: Int

    static func make(
        sourceWidth: Int,
        sourceHeight: Int,
        limits: DisplayCaptureLimits
    ) throws -> DisplayCaptureDimensions {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw DisplayScreenshotError.invalidDisplayDimensions(
                width: sourceWidth,
                height: sourceHeight
            )
        }

        let sourcePixelCount = Double(sourceWidth) * Double(sourceHeight)
        let scale = min(
            1,
            Double(limits.maximumWidth) / Double(sourceWidth),
            Double(limits.maximumHeight) / Double(sourceHeight),
            sqrt(Double(limits.maximumPixelCount) / sourcePixelCount)
        )

        var width = max(1, Int((Double(sourceWidth) * scale).rounded(.down)))
        var height = max(1, Int((Double(sourceHeight) * scale).rounded(.down)))
        while Int64(width) * Int64(height) > Int64(limits.maximumPixelCount) {
            if width >= height, width > 1 {
                width -= 1
            } else if height > 1 {
                height -= 1
            } else {
                break
            }
        }
        return DisplayCaptureDimensions(width: width, height: height)
    }
}

@MainActor
protocol DisplayCaptureRuntime: AnyObject {
    func displays() async throws -> [CapturableDisplayInfo]
    func capture(
        displayID: UInt32,
        width: Int,
        height: Int,
        showsCursor: Bool
    ) async throws -> CGImage
}

@MainActor
final class SystemDisplayCaptureRuntime: DisplayCaptureRuntime {
    func displays() async throws -> [CapturableDisplayInfo] {
        let content = try await SCShareableContent.current
        return content.displays.map(Self.describe)
    }

    func capture(
        displayID: UInt32,
        width: Int,
        height: Int,
        showsCursor: Bool
    ) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DisplayScreenshotError.displayNotFound(displayID)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    private static func describe(_ display: SCDisplay) -> CapturableDisplayInfo {
        CapturableDisplayInfo(
            displayID: display.displayID,
            frame: WindowFrame(
                x: display.frame.origin.x,
                y: display.frame.origin.y,
                width: display.frame.width,
                height: display.frame.height
            ),
            pixelWidth: display.width,
            pixelHeight: display.height,
            isMain: CGDisplayIsMain(display.displayID) != 0
        )
    }
}

/// ScreenCaptureKit-backed capture of an entire display, downscaled as needed
/// to stay within explicit width, height, and total-pixel limits.
///
/// Both discovery and capture preflight Screen Recording access without ever
/// presenting a permission prompt.
@MainActor
public final class DisplayScreenshotter {
    private let runtime: any DisplayCaptureRuntime
    private let screenRecordingCheck: () -> Bool

    public init() {
        runtime = SystemDisplayCaptureRuntime()
        screenRecordingCheck = { CGPreflightScreenCaptureAccess() }
    }

    init(
        runtime: any DisplayCaptureRuntime,
        screenRecordingCheck: @escaping () -> Bool
    ) {
        self.runtime = runtime
        self.screenRecordingCheck = screenRecordingCheck
    }

    public func availableDisplays() async throws -> [CapturableDisplayInfo] {
        try requirePermission()
        return try await runtime.displays().sorted { left, right in
            if left.isMain != right.isMain {
                return left.isMain
            }
            return left.displayID < right.displayID
        }
    }

    /// Captures the requested display, or the main display when `displayID` is
    /// `nil`. The complete display is aspect-fit into `limits`; it is never
    /// cropped to meet the bounds.
    public func captureDisplay(
        displayID: UInt32? = nil,
        limits: DisplayCaptureLimits = .agentDefault,
        showsCursor: Bool = false
    ) async throws -> CGImage {
        try requirePermission()
        let displays = try await runtime.displays()
        let display: CapturableDisplayInfo?
        if let displayID {
            display = displays.first(where: { $0.displayID == displayID })
        } else {
            display = displays.first(where: \.isMain) ?? displays.min(by: { $0.displayID < $1.displayID })
        }
        guard let display else {
            throw DisplayScreenshotError.displayNotFound(displayID)
        }

        let dimensions = try DisplayCaptureDimensions.make(
            sourceWidth: display.pixelWidth,
            sourceHeight: display.pixelHeight,
            limits: limits
        )
        return try await runtime.capture(
            displayID: display.displayID,
            width: dimensions.width,
            height: dimensions.height,
            showsCursor: showsCursor
        )
    }

    private func requirePermission() throws {
        guard screenRecordingCheck() else {
            throw AutomationError.permissionNotGranted(.screenRecording)
        }
    }
}

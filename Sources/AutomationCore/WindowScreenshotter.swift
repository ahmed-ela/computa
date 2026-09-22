@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

public struct CapturableWindowInfo: Codable, Equatable, Sendable {
    public let windowID: UInt32
    public let title: String?
    public let owningApplicationName: String?
    public let owningBundleIdentifier: String?
    public let owningProcessIdentifier: Int32?
    public let frame: WindowFrame
    public let isOnScreen: Bool
    public let isActive: Bool

    public init(
        windowID: UInt32,
        title: String?,
        owningApplicationName: String?,
        owningBundleIdentifier: String?,
        owningProcessIdentifier: Int32?,
        frame: WindowFrame,
        isOnScreen: Bool,
        isActive: Bool
    ) {
        self.windowID = windowID
        self.title = title
        self.owningApplicationName = owningApplicationName
        self.owningBundleIdentifier = owningBundleIdentifier
        self.owningProcessIdentifier = owningProcessIdentifier
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.isActive = isActive
    }
}

struct CaptureDimensions: Equatable {
    let width: Int
    let height: Int

    static func make(frame: CGRect, scaleFactor: Double) throws -> CaptureDimensions {
        guard scaleFactor.isFinite, scaleFactor > 0 else {
            throw AutomationError.invalidScaleFactor(scaleFactor)
        }
        return CaptureDimensions(
            width: max(1, Int((frame.width * scaleFactor).rounded(.up))),
            height: max(1, Int((frame.height * scaleFactor).rounded(.up)))
        )
    }
}

/// ScreenCaptureKit-backed window discovery and capture.
///
/// Every method first checks `CGPreflightScreenCaptureAccess()`. If permission
/// is absent, it fails without calling an API that can initiate a TCC prompt.
@MainActor
public final class WindowScreenshotter {
    private let screenRecordingCheck: () -> Bool

    public init() {
        screenRecordingCheck = { CGPreflightScreenCaptureAccess() }
    }

    init(screenRecordingCheck: @escaping () -> Bool) {
        self.screenRecordingCheck = screenRecordingCheck
    }

    public func availableWindows(onScreenOnly: Bool = true) async throws -> [CapturableWindowInfo] {
        let content = try await shareableContent()
        return content.windows
            .filter { !onScreenOnly || $0.isOnScreen }
            .map(Self.describe)
            .sorted { left, right in
                let leftOwner = left.owningApplicationName ?? ""
                let rightOwner = right.owningApplicationName ?? ""
                if leftOwner.caseInsensitiveCompare(rightOwner) == .orderedSame {
                    return left.windowID < right.windowID
                }
                return leftOwner.caseInsensitiveCompare(rightOwner) == .orderedAscending
            }
    }

    public func captureWindow(
        windowID: CGWindowID,
        scaleFactor: Double = 2.0,
        showsCursor: Bool = false
    ) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw AutomationError.windowNotFound(windowID)
        }

        let dimensions = try CaptureDimensions.make(frame: window.frame, scaleFactor: scaleFactor)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.showsCursor = showsCursor

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard screenRecordingCheck() else {
            throw AutomationError.permissionNotGranted(.screenRecording)
        }
        return try await SCShareableContent.current
    }

    private static func describe(_ window: SCWindow) -> CapturableWindowInfo {
        CapturableWindowInfo(
            windowID: window.windowID,
            title: window.title,
            owningApplicationName: window.owningApplication?.applicationName,
            owningBundleIdentifier: window.owningApplication?.bundleIdentifier,
            owningProcessIdentifier: window.owningApplication?.processID,
            frame: WindowFrame(
                x: window.frame.origin.x,
                y: window.frame.origin.y,
                width: window.frame.width,
                height: window.frame.height
            ),
            isOnScreen: window.isOnScreen,
            isActive: window.isActive
        )
    }
}

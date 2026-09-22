import ApplicationServices
import CoreGraphics

public enum PermissionGrant: String, Codable, Sendable {
    case granted
    case notGranted = "not-granted"
}

public struct AutomationPermissionSnapshot: Codable, Equatable, Sendable {
    public let accessibility: PermissionGrant
    public let screenRecording: PermissionGrant

    public init(accessibility: PermissionGrant, screenRecording: PermissionGrant) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }
}

/// Reads the current TCC state without presenting either permission prompt.
///
/// A `notGranted` result deliberately combines "not yet requested" and "denied":
/// Apple's preflight APIs do not distinguish those states without entering a
/// permission-request flow.
public struct PermissionInspector {
    private let accessibilityCheck: () -> Bool
    private let screenRecordingCheck: () -> Bool

    public init() {
        accessibilityCheck = { AXIsProcessTrusted() }
        screenRecordingCheck = { CGPreflightScreenCaptureAccess() }
    }

    init(
        accessibilityCheck: @escaping () -> Bool,
        screenRecordingCheck: @escaping () -> Bool
    ) {
        self.accessibilityCheck = accessibilityCheck
        self.screenRecordingCheck = screenRecordingCheck
    }

    public func current() -> AutomationPermissionSnapshot {
        AutomationPermissionSnapshot(
            accessibility: accessibilityCheck() ? .granted : .notGranted,
            screenRecording: screenRecordingCheck() ? .granted : .notGranted
        )
    }
}

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

/// The native permission boundary used by the app's user-facing onboarding UI.
///
/// Status reads never prompt. The two request methods are intentionally separate
/// so callers must name the exact permission a direct user action requested.
public protocol AutomationPermissionClient {
    func current() -> AutomationPermissionSnapshot
    func requestAccessibility() -> AutomationPermissionSnapshot
    func requestScreenRecording() -> AutomationPermissionSnapshot
}

/// Reads the current TCC state without presenting either permission prompt.
///
/// A `notGranted` result deliberately combines "not yet requested" and "denied":
/// Apple's preflight APIs do not distinguish those states without entering a
/// permission-request flow.
public struct PermissionInspector: AutomationPermissionClient {
    private let accessibilityCheck: () -> Bool
    private let screenRecordingCheck: () -> Bool
    private let accessibilityRequest: () -> Bool
    private let screenRecordingRequest: () -> Bool

    public init() {
        accessibilityCheck = { AXIsProcessTrusted() }
        screenRecordingCheck = { CGPreflightScreenCaptureAccess() }
        accessibilityRequest = {
            // The imported kAXTrustedCheckOptionPrompt global is not annotated
            // for Swift 6 concurrency. Its documented CFString value is stable.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        screenRecordingRequest = { CGRequestScreenCaptureAccess() }
    }

    init(
        accessibilityCheck: @escaping () -> Bool,
        screenRecordingCheck: @escaping () -> Bool,
        accessibilityRequest: @escaping () -> Bool = { false },
        screenRecordingRequest: @escaping () -> Bool = { false }
    ) {
        self.accessibilityCheck = accessibilityCheck
        self.screenRecordingCheck = screenRecordingCheck
        self.accessibilityRequest = accessibilityRequest
        self.screenRecordingRequest = screenRecordingRequest
    }

    public func current() -> AutomationPermissionSnapshot {
        AutomationPermissionSnapshot(
            accessibility: accessibilityCheck() ? .granted : .notGranted,
            screenRecording: screenRecordingCheck() ? .granted : .notGranted
        )
    }

    /// Requests Accessibility access. Call only in response to an explicit user
    /// action; routine status checks must continue to use `current()`.
    public func requestAccessibility() -> AutomationPermissionSnapshot {
        _ = accessibilityRequest()
        return current()
    }

    /// Requests Screen Recording access. Call only in response to an explicit
    /// user action; routine status checks must continue to use `current()`.
    public func requestScreenRecording() -> AutomationPermissionSnapshot {
        _ = screenRecordingRequest()
        return current()
    }
}

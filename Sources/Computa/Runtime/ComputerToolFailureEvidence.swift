import AutomationCore
import Foundation

/// Reasons the host can establish for an unsuccessful read. Only the enum
/// values enter durable diagnostics, never window titles or model text.
enum NativeInspectionFailure: String, Codable, CaseIterable {
    case noWindow = "no_accessible_window"
    case accessibilityRead = "accessibility_read_failed"
    case screenCapture = "screen_capture_permission_denied"

    var tool: String {
        switch self {
        case .noWindow: "computer_v2_open"
        case .accessibilityRead: "computer_v2_snapshot"
        case .screenCapture: "computer_v2_capture"
        }
    }

    init?(tool: String, error: Error) {
        if case let ApplicationWindowReadError.windowSelectionUnavailable(detail) = error,
           detail.reason == .noSelectedWindow {
            self = .noWindow
        } else if case AutomationError.accessibilityFailure = error {
            self = .accessibilityRead
        } else if case AutomationError.permissionNotGranted(.screenRecording) = error {
            self = .screenCapture
        } else { return nil }
        guard tool == self.tool else { return nil }
    }

    var message: String {
        switch self {
        case .noWindow: "Kolmogor couldn’t find an accessible window to inspect. Open the window you want checked, then try again."
        case .accessibilityRead: "macOS couldn’t read the requested window’s controls. Bring the window into view and try again."
        case .screenCapture: "macOS denied the screen capture. To allow screenshots, enable Screen Recording for Kolmogor in System Settings."
        }
    }
}

/// Describe the native failure we actually measured, without turning an unknown
/// cause into a website, permission, or policy diagnosis. This is evidence for
/// the model, not a replacement for approval, policy, or execution checks.
enum ComputerToolFailureEvidence {
    /// An exhausted native activation cannot be repaired by model retries.
    static func terminalMessage(for error: Error) -> String? {
        guard let native = error as? ComputerInputError,
              case .applicationActivationFailed = native else { return nil }
        return native.localizedDescription + " The cause is unknown. Further computer actions are blocked for this turn. "
            + "Bring the intended app to the foreground, then try again."
    }

    static func text(for error: Error, tool: String? = nil) -> String {
        // Recovery guidance must describe the active tool surface. This does
        // not reinterpret permission denials or change backend admission.
        if let continuation = error as? ComputerReadContinuation.Failure {
            return continuation.localizedDescription
        }
        if let policy = error as? ComputerInteractionPolicy.Violation {
            return policy.localizedDescription
        }
        if tool == ComputerV2ToolContract.Tool.pointer.rawValue,
           let validation = error as? ComputerV2ToolContract.ValidationError,
           case let .missing(field) = validation,
           ["x", "y", "capture_id", "delta_x", "delta_y"].contains(field) {
            return error.localizedDescription + ". No input was dispatched. "
                + "Every pointer action requires capture_id, x, y; scroll also requires delta_x, delta_y. "
                + "Use a fresh screenshot's exact capture_id and image pixels over the intended scroll region; "
                + "an AX snapshot ID is not a capture ID. If only text is missing, try computer_v2_snapshot(query=<short literal text>) first."
        }
        guard let native = error as? ComputerInputError,
              case let .applicationActivationFailed(processIdentifier) = native else {
            // Preserve real permission denials and all other errors verbatim.
            return error.localizedDescription
        }
        let evidence: [String: Any] = [
            "type": "native_tool_failure",
            "error": ["code": "application_activation_failed", "message": native.localizedDescription],
            "process_id": processIdentifier,
            "cause": "undetermined",
            "website_status": "not_observed",
            "action_outcome": "not_confirmed",
            "next_step": "Do not retry this failed action. Tell the user the app could not be activated and its cause is unknown. "
                + "If needed, ask the user to focus the app before a new attempt. "
                + "This error neither identifies nor rules out a website, network, permission, or policy cause. "
                + "Do not name any of those as the cause or claim they are not the cause.",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return native.localizedDescription
        }
        return text
    }
}

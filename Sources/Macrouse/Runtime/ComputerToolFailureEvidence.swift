import AutomationCore
import Foundation

/// Describe the native failure we actually measured, without turning an unknown
/// cause into a website, permission, or policy diagnosis. This is evidence for
/// the model, not a replacement for approval, policy, or execution checks.
enum ComputerToolFailureEvidence {
    static var navigationRecoveryDescription: String {
        ExistingChromeError.navigationRecoveryRequired.localizedDescription
    }

    static let navigationRecoveryNextStep =
        "Do not retry this failed navigation or open another tab. Any tab already created was left open. "
        + "Further computer actions are blocked for this turn. Tell the user navigation was not confirmed. "
        + "Do not claim that Enter was sent, that navigation completed, or that a website or policy blocked it."

    static var navigationRecoveryTerminalMessage: String {
        navigationRecoveryDescription + " Further computer actions are blocked for this turn to avoid creating duplicate tabs. "
            + "Any tab already created was left open; navigation was not confirmed."
    }

    /// An exhausted native activation is not something model reasoning can
    /// repair. A retained partial navigation likewise must not be retried as a
    /// fresh open. Report either as an app diagnostic and end this action turn.
    static func terminalMessage(for error: Error) -> String? {
        if let chrome = error as? ExistingChromeError, chrome == .navigationRecoveryRequired {
            return navigationRecoveryTerminalMessage
        }
        guard let native = error as? ComputerInputError,
              case .applicationActivationFailed = native else { return nil }
        return native.localizedDescription + " The cause is unknown. Further computer actions are blocked for this turn. "
            + "Bring the intended app to the foreground, then try again."
    }

    static func text(for error: Error, tool: String? = nil) -> String {
        if let chrome = error as? ExistingChromeError, chrome == .navigationRecoveryRequired {
            let evidence: [String: Any] = [
                "type": "native_tool_failure",
                "error": ["code": "chrome_navigation_recovery_required", "message": navigationRecoveryDescription],
                "cause": "undetermined",
                "website_status": "not_observed",
                "action_outcome": "navigation_not_confirmed",
                "tab_state": "preserved_if_created",
                "retry_policy": "stop_for_turn",
                "next_step": navigationRecoveryNextStep,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return navigationRecoveryDescription
            }
            return text
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

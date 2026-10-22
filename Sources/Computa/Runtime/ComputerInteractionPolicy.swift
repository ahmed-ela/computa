import Foundation

/// Authority owned by the host, not a tool argument or a model instruction.
/// Approval mode is deliberately independent: Full Access can auto-approve an
/// allowed action, but cannot grant foreground or global-input capability.
enum ComputerInteractionPolicy: String, Codable, CaseIterable, Sendable {
    case backgroundOnly
    case foregroundAllowed

    static let `default`: Self = .backgroundOnly

    enum Violation: Error, Equatable, LocalizedError {
        case foregroundUnavailable
        case legacyMutationUnavailable

        var errorDescription: String? {
            switch self {
            case .foregroundUnavailable:
                return "Background-only computer use cannot activate apps, navigate by native open, raise windows, or send global keyboard/pointer input. Use the bound native app's supported background AX actions. For authorized webpage work use the offered browser_* tools in Computa's built-in browser. A screenshot is observation only, not input permission. If the requested native action is unavailable, report that limitation; do not repeat, change the requested surface, or try another foreground path. Full Access does not elevate this host policy."
            case .legacyMutationUnavailable:
                return "Legacy computer mutations are unavailable in background-only mode. Bind an already-running native app with computer_v2_open without activation, then use its supported background AX actions. Webpages use the offered browser_* tools and their own bindings/cursors. Do not retry with legacy, pointer, keyboard, or app-activation tools; do not substitute another surface for the user's requested target. No mutation was dispatched."
            }
        }
    }

    func requireForeground() throws {
        guard self == .foregroundAllowed else { throw Violation.foregroundUnavailable }
    }

    /// Call after argument validation and before approvals or any operation with
    /// side effects. Filtering model-visible tools is only a usability aid.
    func requireV2(_ call: ComputerV2ToolContract.ValidatedCall) throws {
        guard self == .backgroundOnly else { return }
        if call.tool.requiresGlobalInput { throw Violation.foregroundUnavailable }
        switch call.tool {
        case .open:
            guard call.activationMode == .none,
                  call.arguments["url"] == nil else {
                throw Violation.foregroundUnavailable
            }
        case .ax:
            if call.arguments["ax_action"] as? String == "AXRaise" {
                throw Violation.foregroundUnavailable
            }
        default:
            break
        }
    }

    /// Older chats may still issue legacy tools. Deny their mutation routes
    /// rather than silently translating them to a foreground implementation.
    /// Unknown computer actions fail closed, while unrelated tool namespaces
    /// remain the responsibility of their own policies.
    func requireLegacy(tool: String, arguments: [String: Any]) throws {
        guard self == .backgroundOnly else { return }
        if tool == "computer" {
            switch arguments["action"] as? String {
            case "permission_status", "apps", "snapshot", "capture": return
            default: throw Violation.legacyMutationUnavailable
            }
        }
        guard tool.hasPrefix("desktop_") else { return }
        switch tool {
        case "desktop_permission_status", "desktop_list_apps", "desktop_focused_window",
             "desktop_snapshot_app", "desktop_list_windows", "desktop_capture_window",
             "desktop_capture_display":
            return
        default:
            throw Violation.legacyMutationUnavailable
        }
    }
}

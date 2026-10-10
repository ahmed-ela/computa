import Foundation

/// Selects the engine's terminal/file sandbox and native approval behavior.
/// macOS privacy grants and browser/computer tool validation remain authoritative.
enum AccessMode: String, CaseIterable, Identifiable, Sendable {
    case askEveryTime
    case fullAccess

    var id: String { rawValue }

    var label: String {
        switch self {
        case .askEveryTime:
            "Ask every time"
        case .fullAccess:
            "Full access"
        }
    }

    // Thread start/resume uses a kebab-case mode; turn/start uses a tagged
    // camelCase policy. Keep both forms together so loaded threads cannot retain
    // Full access after the user selects Ask for their next turn.
    var sandboxMode: String {
        self == .fullAccess ? "danger-full-access" : "workspace-write"
    }

    var approvalPolicy: String {
        self == .fullAccess ? "never" : "on-request"
    }

    var sandboxPolicy: [String: Any] {
        if self == .fullAccess { return ["type": "dangerFullAccess"] }
        return [
            "type": "workspaceWrite",
            "writableRoots": [String](),
            "networkAccess": false,
            "excludeTmpdirEnvVar": false,
            "excludeSlashTmp": false,
        ]
    }
}

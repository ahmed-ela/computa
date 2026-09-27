import Foundation

/// Controls only how Mactopus answers approval requests emitted by the runtime.
/// Tool validation, macOS privacy grants, and other enforcement layers remain
/// authoritative in every mode.
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
}

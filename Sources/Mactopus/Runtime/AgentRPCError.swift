import CoreFoundation
import Foundation

/// Preserve the server's structured failure for reconciliation without inferring
/// retry safety from display text. This type never retries or replays a request.
struct AgentRPCError: LocalizedError, Equatable, Sendable {
    let code: Int64?
    let message: String
    /// JSON null and an absent data field remain distinguishable.
    let data: Data?

    init(object: [String: Any]) {
        if let number = object["code"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            let candidate = number.int64Value
            code = NSNumber(value: candidate).compare(number) == .orderedSame ? candidate : nil
        } else {
            code = nil
        }
        message = (object["message"] as? String) ?? "Codex App Server request failed."
        data = object["data"].flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys])
        }
    }

    var errorDescription: String? { message }
}

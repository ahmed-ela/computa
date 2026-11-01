import Foundation

/// Negative-only native evidence captured after an actual Claude remount failure.
/// It cannot inspect a page, preserve its lifetime, or supply model/response proof.
enum ClaudeRemountHostDiagnostic {
    private static let booleans: Set<String> = ["attached", "hidden", "window", "visible", "occluded"]
    private static let dimensions: Set<String> = ["width", "height", "visibleWidth", "visibleHeight", "hostWidth", "hostHeight"]

    static func record(observation: [String: Any], action: String, sequence: Int,
                       sessionID: String, tabID: UUID, generation: UUID,
                       snapshot: () throws -> String) -> String? {
        guard ["inspect", "verifyModel"].contains(action), (1...1_000).contains(sequence),
              let session = UUID(uuidString: sessionID),
              ["model_unverified", "model_mismatch"].contains(observation["error"] as? String ?? ""),
              let diagnostic = observation["modelDiagnostic"] as? [String: Any],
              diagnostic["kind"] as? String == "model_picker_structure",
              diagnostic["provider"] as? String == "claude",
              let stage = diagnostic["readStage"] as? String,
              ["trigger_remount_timeout", "trigger_remount_rejected"].contains(stage),
              let context = diagnostic["readContext"] as? [String: Any],
              context["scope"] as? String == "action_precheck", context["action"] as? String == action,
              let native = try? snapshot(), let host = hostProjection(native) else { return nil }
        let value: [String: Any] = ["kind": "claude_remount_host_v1", "provider": "claude",
            "sessionID": session.uuidString.lowercased(), "tabID": tabID.uuidString.lowercased(),
            "generation": generation.uuidString.lowercased(), "action": action,
            "sequence": sequence, "stage": stage, "host": host]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              data.count <= 1_024 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Consume only the existing native snapshot's fixed geometry/visibility
    /// fields. Additional phase/counter fields never become diagnostic content.
    private static func hostProjection(_ snapshot: String) -> [String: Any]? {
        guard !snapshot.isEmpty, snapshot.utf8.count <= 2_048 else { return nil }
        var result: [String: Any] = [:]
        for part in snapshot.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0]), value = String(pair[1])
            guard booleans.contains(key) || dimensions.contains(key) else { continue }
            guard result[key] == nil else { return nil }
            if booleans.contains(key) {
                guard value == "true" || value == "false" else { return nil }
                result[key] = value == "true"
            } else {
                guard let number = Int(value), String(number) == value, (0...16_384).contains(number) else { return nil }
                result[key] = number
            }
        }
        return Set(result.keys) == booleans.union(dimensions) ? result : nil
    }
}

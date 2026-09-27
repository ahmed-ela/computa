import Foundation

/// A bounded record of something the assistant actually said in a completed
/// user turn. The caller must establish the live turn's identity and successful
/// completion before using the initializer; this type never invents an answer.
struct CompactionAssistantEvidence: Equatable, Sendable {
    static let maximumUTF8Bytes = 2_048
    static let maximumHydratedTurns = 8

    private static let excerptHeader = "[Historical completed assistant reply; excerpt]\n"
    private static let excerptOmission = "\n[... middle omitted ...]\n"

    let text: String

    init?(completedAssistantText original: String) {
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard original.utf8.count > Self.maximumUTF8Bytes else {
            text = original
            return
        }

        let labels = Self.excerptHeader.utf8.count + Self.excerptOmission.utf8.count
        let available = Self.maximumUTF8Bytes - labels
        let first = Self.validUTF8Prefix(original, maximumBytes: available / 2)
        let last = Self.validUTF8Suffix(original, maximumBytes: available - available / 2)
        text = Self.excerptHeader + first + Self.excerptOmission + last
    }

    /// No original item IDs, tool calls, internal metadata, or capabilities are
    /// replayed. The evidence stays assistant text, never higher-priority input.
    var responseItem: [String: Any] {
        ["type": "message", "role": "assistant",
         "content": [["type": "output_text", "text": text]]]
    }

    /// `initialTurnsPage` must have been requested with `sortDirection: desc`
    /// and `itemsView: full`. Legacy `thread.turns` is chronological. Both paths
    /// inspect only a bounded recent window and never read a rollout file.
    static func latestCompletedUserTurn(inResumeResponse response: [String: Any], excludingTurnIDs: Set<String> = []) -> Self? {
        if let error = response["error"], !(error is NSNull) { return nil }
        guard let result = response["result"] as? [String: Any] else { return nil }

        if let rawPage = result["initialTurnsPage"], !(rawPage is NSNull) {
            guard let page = rawPage as? [String: Any],
                  let turns = page["data"] as? [[String: Any]] else { return nil }
            return latestCompletedUserTurn(inNewestFirstTurns: Array(turns.prefix(maximumHydratedTurns)), excludingTurnIDs: excludingTurnIDs)
        }
        guard let thread = result["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]] else { return nil }
        return latestCompletedUserTurn(inNewestFirstTurns: Array(turns.suffix(maximumHydratedTurns).reversed()), excludingTurnIDs: excludingTurnIDs)
    }

    private static func latestCompletedUserTurn(inNewestFirstTurns turns: [[String: Any]], excludingTurnIDs: Set<String>) -> Self? {
        for turn in turns {
            guard let status = turn["status"] as? String else { return nil }
            // An active turn is not a safe source for an idle preflight.
            guard status != "inProgress" else { return nil }
            guard status == "completed" else { continue }
            guard let turnID = turn["id"] as? String, !turnID.isEmpty,
                  turn["error"] == nil || turn["error"] is NSNull,
                  turn["itemsView"] == nil || turn["itemsView"] as? String == "full",
                  let items = turn["items"] as? [[String: Any]] else { return nil }
            guard items.contains(where: isActualUserMessage) else { continue }
            // App-owned outcome failures override nominal provider completion.
            guard !excludingTurnIDs.contains(turnID) else { return nil }

            // A native automatic compaction may share the user's turn. Only a
            // later assistant reply is eligible; the compaction summary is not.
            let start = items.lastIndex { $0["type"] as? String == "contextCompaction" }
                .map { $0 + 1 } ?? 0
            for item in items.dropFirst(start).reversed() {
                guard item["type"] as? String == "agentMessage" else { continue }
                if let phase = item["phase"], !(phase is NSNull), phase as? String != "final_answer" {
                    continue
                }
                guard let itemID = item["id"] as? String, !itemID.isEmpty,
                      let text = item["text"] as? String else { return nil }
                if let evidence = Self(completedAssistantText: text) { return evidence }
            }
            // Do not substitute an older answer when the newest completed user
            // turn has no eligible final answer (or only a summary/tool result).
            return nil
        }
        return nil
    }

    private static func isActualUserMessage(_ item: [String: Any]) -> Bool {
        guard item["type"] as? String == "userMessage",
              let id = item["id"] as? String, !id.isEmpty,
              let content = item["content"] as? [[String: Any]] else { return false }
        return content.contains { input in
            switch input["type"] as? String {
            case "text":
                guard let text = input["text"] as? String else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "image":
                return nonemptyString(input["url"]) || nonemptyString(input["fileId"])
            case "audio": return nonemptyString(input["url"])
            case "localImage", "localAudio", "skill", "mention": return nonemptyString(input["path"])
            default: return false
            }
        }
    }

    private static func nonemptyString(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validUTF8Prefix(_ text: String, maximumBytes: Int) -> String {
        var bytes = Array(text.utf8.prefix(maximumBytes))
        while let _ = bytes.last {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }

    private static func validUTF8Suffix(_ text: String, maximumBytes: Int) -> String {
        var bytes = Array(text.utf8.suffix(maximumBytes))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeFirst()
        }
        return ""
    }
}

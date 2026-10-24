import Foundation

/// Host execution chronology only. This deliberately cannot accept page text,
/// arguments, targets, or model-authored summaries as evidence of site results.
struct BrowserTurnExecutionCheckpoint: Sendable {
    private struct Counts: Sendable {
        var completed = 0
        var failed = 0
    }
    private var calls: Set<String> = []
    private var counts: [String: Counts] = [:]
    private var saturated = false

    /// A call that executed successfully remains successful even if publishing
    /// its RPC response later failed. These counts do not claim model exposure.
    mutating func record(callID: String, tool: String, succeeded: Bool) {
        guard EmbeddedBrowserTools.names.contains(tool), !calls.contains(callID) else { return }
        guard calls.count < 4_096 else { saturated = true; return }
        calls.insert(callID)
        if succeeded { counts[tool, default: Counts()].completed += 1 }
        else { counts[tool, default: Counts()].failed += 1 }
    }

    var text: String {
        let operations = counts.isEmpty ? "No browser operations are recorded for this native turn."
            : counts.keys.sorted().map { tool in
                let value = counts[tool]!
                return "\(tool): completed=\(value.completed) failed=\(value.failed)"
            }.joined(separator: "\n")
        return """
        Operations in this native turn only\(saturated ? " (bounded lower counts; recording limit reached)" : ""):
        \(operations)
        These are host tool execution counts, not proof that output was read or a website search succeeded. A failed operation may have dispatched input; never replay uncertain input. Earlier attempts and summaries do not add current operations. Existing page state may predate this turn. Read actual current tool observations to establish content, relevance and outcome; counts never establish site results or their absence.
        """
    }
}

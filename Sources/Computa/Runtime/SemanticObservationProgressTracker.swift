import CryptoKit
import Foundation

/// A bounded, turn-local reminder that repeated reads did not reveal new facts.
/// This never suppresses observations, invalidates action IDs, or executes an
/// action. The runtime resets it after a successful mutation, binding change,
/// and turn boundary. Use it for semantic observations, not screenshot metadata
/// alone: identical capture metadata cannot establish identical image pixels.
struct SemanticObservationProgressTracker: Sendable {
    static let notice = """
    NO_PROGRESS: Same semantic content/coverage seen recently. Use computer_v2_snapshot with view=content, headings or links; expand an observed subtree with snapshot_id+element_index; or follow next_cursor. Retry loading pages only when new evidence may appear. Missing text is not proof of absence. Do not repeat a mutation or open another tab to recover. Original action IDs still require normal freshness checks.
    """

    let historyLimit: Int
    private var recentFingerprints = [Data]()

    init(historyLimit: Int = 12) {
        self.historyLimit = min(max(historyLimit, 1), 64)
    }

    /// Preserves the returned observation byte-for-byte and appends only a
    /// strategy hint on recurrence, including A/B/A alternation. Retaining only
    /// digests keeps history bounded without retaining private page content.
    mutating func observe(text: String) -> String {
        let fingerprint = Data(SHA256.hash(data: Data(Self.normalized(text).utf8)))
        let repeated = recentFingerprints.contains(fingerprint)
        recentFingerprints.append(fingerprint)
        if recentFingerprints.count > historyLimit {
            recentFingerprints.removeFirst(recentFingerprints.count - historyLimit)
        }
        return repeated ? text + "\n" + Self.notice : text
    }

    mutating func reset() {
        recentFingerprints.removeAll(keepingCapacity: true)
    }

    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: "\n").map(normalizedLine).joined(separator: "\n")
    }

    private static func normalizedLine(_ line: String) -> String {
        let header = line.prefix(while: { $0 != " " && $0 != "\t" })
        let observationHeaders: Set<Substring> = [
            "AXSNAPSHOT", "WINDOW_CAPTURE", "DISPLAY_CAPTURE", "SYNCHRONIZED_AX",
            "POST_ACTION_SYNCHRONIZED_AX", "SEMANTIC_READ", "READ", "NATIVE_AX",
        ]
        guard observationHeaders.contains(header) else { return line }
        // IDs are normalized only in recognized metadata and only outside
        // quoted values. A title/value containing "snapshot_id=..." is data.
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        let pattern = "(?:^|[ \\t])(id|snapshot_id|capture_id|next_cursor)=(\(uuid))(?=$|[ \\t])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let source = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: source.length))
        let result = NSMutableString(string: line)
        for match in matches.reversed() {
            let field = source.substring(with: match.range(at: 1))
            guard field != "id" || header == "AXSNAPSHOT",
                  field != "next_cursor" || header == "READ" || header == "SEMANTIC_READ",
                  outsideQuotedField(source.substring(to: match.range(at: 1).location)) else { continue }
            // A next_cursor is a random continuation capability, not page
            // content. Preserve its availability, and all offset/visited/
            // scope/view/coverage metadata, so advancing pages remain distinct.
            result.replaceCharacters(in: match.range(at: 2), with: field == "next_cursor" ? "<available>" : "<observation-id>")
        }
        return result as String
    }

    private static func outsideQuotedField(_ prefix: String) -> Bool {
        var quoted = false
        var escaped = false
        for character in prefix {
            if escaped { escaped = false }
            else if character == "\\", quoted { escaped = true }
            else if character == "\"" { quoted.toggle() }
        }
        return !quoted
    }
}

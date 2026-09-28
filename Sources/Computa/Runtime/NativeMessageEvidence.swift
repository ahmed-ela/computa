import Foundation

/// A native accessibility tree can prove a displayed value or selection, but
/// ordinary AX prose does not certify message direction, ordering, or coverage.
/// Keep this requirement outside model history so compaction cannot erase it.
struct NativeMessageEvidence: Sendable {
    let requiresLatestIncoming: Bool
    private(set) var observedNativeRead = false

    init(prompt: String) {
        let text = prompt.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
        let latest = Self.matches(#"\b(latest|last|newest|most\s+recent)\b"#, text)
        let message = Self.matches(#"\b(messages?|emails?|e-mails?|texts?|communications?|dms?)\b"#, text)
        let incoming = Self.matches(#"\b(incoming|received|receive|receiving)\b|\bsent\s+(?:to\s+)?(?:me|us)\b|\b(?:i|we)\s+(?:got|received)\b"#, text)
        // A sender is requested, but never infer who it is from model text or
        // match particular applications/contact names. Exclude self/outgoing.
        let fromOther = Self.matches(#"\b(?:messages?|emails?|e-mails?|texts?|communications?|dms?)\s+from\s+(?!(?:me|myself|us|ourselves)\b)\S"#, text)
        requiresLatestIncoming = latest && message && (incoming || fromOther)
    }

    mutating func observeNativeRead() {
        observedNativeRead = true
    }

    var completionDiagnostic: String? {
        guard requiresLatestIncoming, observedNativeRead else { return nil }
        return "The latest incoming message could not be verified. Native accessibility text does not certify the sender, incoming direction, message ordering, or coverage of the latest-message boundary. A displayed row, preview, selection, or changed detail pane is not sufficient evidence of the latest received message. You can continue in this chat."
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

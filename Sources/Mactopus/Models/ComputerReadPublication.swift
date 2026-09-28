import AutomationCore
import Foundation

/// Typed, host-only metadata travels with the exact text result being returned.
/// A verification loop may read several snapshots but publish only its last one;
/// retaining a snapshot in a session is therefore not evidence of exposure.
enum ComputerReadPublication {
    private static let receiptKey = "_hostSemanticReadReceipt"

    struct Prepared {
        let contentItems: [[String: Any]]
        let evidence: ComputerReadEvidence
    }

    static func text(_ text: String, receipt: SemanticReadReceipt? = nil) -> [String: Any] {
        var item: [String: Any] = ["type": "inputText", "text": text]
        if let receipt { item[receiptKey] = receipt }
        return item
    }

    /// Prepare transactionally. The caller commits `evidence` only after the
    /// response was successfully enqueued. Neither page text nor model prose
    /// can manufacture the typed receipt, and it never crosses the wire.
    static func prepare(_ items: [[String: Any]], evidence original: ComputerReadEvidence) throws -> Prepared {
        var evidence = original
        var output: [[String: Any]] = []
        for var item in items {
            let receipt = item.removeValue(forKey: receiptKey) as? SemanticReadReceipt
            if let receipt, item["type"] as? String == "inputText", item["text"] is String {
                try evidence.observe(receipt)
            }
            output.append(item)
        }
        if evidence.hasEvidence, !output.isEmpty,
           output.allSatisfy({ $0["type"] as? String == "inputText" }) {
            // The pinned native compactor copies fitting text blocks in order.
            // Its minimum 256-byte cap reserves 128 bytes, leaving 128 for the
            // first block of an image-free result, even on repeated passes.
            // Keep this block within that bound on later action/error results.
            // This is
            // historical read coverage, never a replayed action or capability.
            let summary = evidence.compactSummary()
            precondition(summary.utf8.count <= 128)
            output.insert(text(summary), at: 0)
        }
        return Prepared(contentItems: output, evidence: evidence)
    }

    static func historicalItem(_ evidence: ComputerReadEvidence) -> [String: Any]? {
        guard evidence.hasEvidence else { return nil }
        return ["type": "message", "role": "assistant", "content": [[
            "type": "output_text",
            "text": "[Historical host read coverage; no current references or action authority]\n"
                + evidence.checkpointText(),
        ]]]
    }
}

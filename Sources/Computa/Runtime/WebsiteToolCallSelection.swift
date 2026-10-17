import Foundation

/// Selects native output only after the caller validates the entire website
/// envelope and request tool policy. Unselected proposals are never queued.
enum WebsiteToolCallSelection {
    struct Selection: Equatable, Sendable {
        let reply: WebModelResponseCodec.Reply
        let proposedCount: Int
        let selectedCount: Int
        let notSelectedCount: Int
        /// Finite relay accounting, not evidence of execution or permission.
        let metadataValue: String?
    }

    static func select(validatedReply: WebModelResponseCodec.Reply, singleAction: Bool) throws -> Selection {
        let calls: [WebModelResponseCodec.ToolCall]
        switch validatedReply {
        case .message, .assistantMessage:
            calls = []
        case let .toolCalls(value), let .toolCallsWithCommentary(value, _):
            // Preserve the native continuation's existing 64-call boundary
            // before selecting a prefix; an oversized batch is not rescued.
            if singleAction, value.isEmpty || value.count > 64 {
                throw WebsiteTurnContinuation.Failure.invalidResponse
            }
            calls = value
        }

        guard singleAction else {
            return Selection(reply: validatedReply, proposedCount: calls.count,
                             selectedCount: calls.count, notSelectedCount: 0, metadataValue: nil)
        }

        let selectedReply: WebModelResponseCodec.Reply
        switch validatedReply {
        case .message, .assistantMessage:
            selectedReply = validatedReply
        case .toolCalls:
            selectedReply = .toolCalls([calls[0]])
        case let .toolCallsWithCommentary(_, commentary):
            selectedReply = .toolCallsWithCommentary([calls[0]], commentary)
        }
        let selectedCount = calls.isEmpty ? 0 : 1
        let notSelectedCount = calls.count - selectedCount
        let metadata: [String: Any] = [
            "policy": "single_action_per_inference", "version": 1,
            "proposedCount": calls.count, "selectedCount": selectedCount,
            "notSelectedCount": notSelectedCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        return Selection(reply: selectedReply, proposedCount: calls.count,
                         selectedCount: selectedCount, notSelectedCount: notSelectedCount,
                         metadataValue: String(decoding: data, as: UTF8.self))
    }
}

import Foundation

public enum SemanticReadView: String, CaseIterable, Codable, Sendable {
    case all, overview, content, headings, links
}

/// Discovery is independent of knowing the requested text in advance. A cursor
/// is opaque and carries the original view/query; it cannot be repurposed.
public struct SemanticReadRequest: Equatable, Sendable {
    public let query: String?
    public let requestedView: SemanticReadView?
    public var view: SemanticReadView { requestedView ?? .all }
    public let cursor: String?
    public let snapshotID: UUID?
    public let elementIndex: Int?

    public init(query: String? = nil, view: SemanticReadView? = nil, cursor: String? = nil,
                snapshotID: UUID? = nil, elementIndex: Int? = nil) {
        self.query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestedView = view
        self.cursor = cursor
        self.snapshotID = snapshotID
        self.elementIndex = elementIndex
    }

    /// A cursor owns its filters. Repeating a matching filter is harmless;
    /// changing it or requesting a different subtree is never normalized away.
    public func continues(_ original: SemanticReadRequest) -> Bool {
        cursor != nil && snapshotID == nil && elementIndex == nil
            && (requestedView == nil || requestedView == original.view)
            && (query == nil || query == original.query)
    }
}

public struct AccessibilitySemanticReadResult: Sendable {
    public let snapshot: AccessibilityTreeSnapshot
    public let observation: AccessibilityModelObservation

    public init(snapshot: AccessibilityTreeSnapshot, observation: AccessibilityModelObservation) {
        self.snapshot = snapshot
        self.observation = observation
    }
}

public enum SemanticReadError: LocalizedError {
    case staleCursor
    case invalidRequest
    case unexposedSubtree
    case unsupportedProgressiveRead
    case unsupportedOverview
    case outputBudgetTooSmall

    public var errorDescription: String? {
        switch self {
        case .staleCursor: "The semantic-read cursor is stale or belongs to another observation. Start a fresh read."
        case .invalidRequest: "A cursor continues its original view/query; omit filters or repeat exactly the original filters. Start a fresh read to change filters or subtree."
        case .unexposedSubtree: "Subtree expansion requires an element shown in the current snapshot; do not guess indices."
        case .unsupportedOverview: "The overview view is browser-only. For a native app use all, content, headings, or links."
        case .unsupportedProgressiveRead: "This native backend does not support progressive reads."
        case .outputBudgetTooSmall: "The retained semantic record does not fit this output budget. Read a narrower view or subtree."
        }
    }
}

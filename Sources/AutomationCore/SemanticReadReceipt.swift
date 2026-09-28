import Foundation

/// Exact already-budgeted rows available for a host-owned reference presentation.
/// This metadata does not issue references, grant action authority, or add read
/// coverage. The caller must publish it with the matching observation.
public struct SemanticReadPresentation: Equatable, Sendable {
    /// Row address replacement and fixed menu guidance are separately reserved.
    public static let rowMetadataByteReserve = 220
    public static let fixedMetadataByteReserve = 512

    public let snapshotID: UUID
    public let rows: [SemanticReadPresentedRow]
    /// Final transformed output must fit this UTF-8 bound without clipping.
    public let maximumOutputBytes: Int

    public init(snapshotID: UUID, rows: [SemanticReadPresentedRow], maximumOutputBytes: Int = 16_384) {
        self.snapshotID = snapshotID
        self.rows = rows
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public struct SemanticReadPresentedRow: Equatable, Sendable {
    public let index: Int
    /// The exact retained formatter row, including any field fragments.
    public let text: String
    public let actions: [String]
    public let settable: Bool
    public let followLink: Bool
    /// The exposed row may be selected for a scoped read. This is not proof
    /// that it is a valid result region for an action postcondition.
    public let region: Bool
    public let regionChanged: Bool
    /// Direct parent only when it also has an unambiguous published row.
    public let parentIndex: Int?

    public init(index: Int, text: String, actions: [String], settable: Bool,
                followLink: Bool, region: Bool, regionChanged: Bool = false, parentIndex: Int? = nil) {
        self.index = index
        self.text = text
        self.actions = actions
        self.settable = settable
        self.followLink = followLink
        self.region = region
        self.regionChanged = regionChanged
        self.parentIndex = parentIndex
    }
}

/// Host-created evidence for exactly the body field bytes exposed by a read.
/// It carries no cursor or action authority and is not a semantic truth claim.
public enum SemanticReadConsistency: String, Codable, Equatable, Sendable {
    case immutableCapture, liveValidatedPage, unknown
}

public enum SemanticReadField: String, Codable, Equatable, Sendable {
    case label, value, linkURL
}

public enum SemanticReadContentKind: String, Codable, Equatable, Sendable {
    case readable, control, navigation, metadata, unknown
}

public enum SemanticReadProvenance: String, Codable, Equatable, Sendable {
    case main, article, navigation, complementary, banner, contentinfo, unknown
}

/// Half-open UTF-8 offsets in one original, unescaped captured field. An empty
/// field is exposed as 0..<0 with totalUTF8 == 0. A field never seen in output
/// must not be added merely because the host captured its underlying source.
public struct SemanticReadFieldExposure: Codable, Equatable, Sendable {
    public let nodeID: String
    public let field: SemanticReadField
    public let startUTF8: Int
    public let endUTF8: Int
    public let totalUTF8: Int
    public let kind: SemanticReadContentKind
    public let provenance: SemanticReadProvenance

    public init(nodeID: String, field: SemanticReadField, startUTF8: Int, endUTF8: Int,
                totalUTF8: Int, kind: SemanticReadContentKind, provenance: SemanticReadProvenance) {
        self.nodeID = nodeID; self.field = field
        self.startUTF8 = startUTF8; self.endUTF8 = endUTF8; self.totalUTF8 = totalUTF8
        self.kind = kind; self.provenance = provenance
    }
}

public struct SemanticReadReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let targetGeneration: String
    public let consistency: SemanticReadConsistency
    public let view: SemanticReadView
    public let query: String?
    public let subtreeNodeID: String?
    public let selectedElementCount: Int?
    public let selectedFieldCount: Int?
    public let sourceTruncated: Bool
    /// Remaining body field tails only; header metadata clipping is separate.
    public let fieldTruncated: Bool
    public let outputTruncated: Bool
    public let exposures: [SemanticReadFieldExposure]

    public init(id: UUID, sourceID: UUID, targetGeneration: String, consistency: SemanticReadConsistency,
                view: SemanticReadView, query: String?, subtreeNodeID: String?,
                selectedElementCount: Int?, selectedFieldCount: Int?, sourceTruncated: Bool,
                fieldTruncated: Bool, outputTruncated: Bool, exposures: [SemanticReadFieldExposure]) {
        self.id = id; self.sourceID = sourceID; self.targetGeneration = targetGeneration
        self.consistency = consistency; self.view = view; self.query = query; self.subtreeNodeID = subtreeNodeID
        self.selectedElementCount = selectedElementCount; self.selectedFieldCount = selectedFieldCount
        self.sourceTruncated = sourceTruncated; self.fieldTruncated = fieldTruncated
        self.outputTruncated = outputTruncated; self.exposures = exposures
    }
}

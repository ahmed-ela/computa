import AutomationCore
import CryptoKit
import Foundation

/// A bounded record of published host reads. Only immutable captures can
/// accumulate field spans. Neither completion nor structural kind establishes
/// relevance, truth, an exhaustive document search, or input authority.
struct ComputerReadEvidence: Codable, Equatable, Sendable {
    enum Failure: Error, LocalizedError {
        case invalidReceipt, conflictingReceipt, invalidCheckpoint
        var errorDescription: String? { "Read coverage evidence is invalid or inconsistent; coverage remains unverified." }
    }

    struct Statistics: Equatable, Sendable {
        let scopes: Int
        let capturedSelectionsComplete: Int
        let partialScopes: Int
        let unknownScopes: Int
        let sourceTruncatedScopes: Int
        let outputTruncatedScopes: Int
        let fieldIncompleteScopes: Int
        let exposedFields: Int
        let completeFields: Int
        let exposedUTF8: Int
        let readableFields: Int
        let controlFields: Int
        let navigationFields: Int
        let metadataFields: Int
        let unknownFields: Int
        let historyDropped: Bool
    }

    private static let maximumScopes = 16
    private static let maximumReceipts = 256
    private static let maximumFieldsPerScope = 1_024
    private static let maximumFields = 4_096
    private static let maximumRangesPerField = 32
    private static let maximumFieldBytes = 16 * 1_024 * 1_024

    private struct Span: Codable, Equatable, Sendable {
        var start: Int
        var end: Int
    }
    private struct Field: Codable, Equatable, Sendable {
        let total: Int
        let kind: SemanticReadContentKind
        let provenance: SemanticReadProvenance
        var spans: [Span]
        var complete: Bool { total == 0 || spans == [Span(start: 0, end: total)] }
        var exposedBytes: Int { spans.reduce(0) { $0 + $1.end - $1.start } }
    }
    private struct Scope: Codable, Equatable, Sendable {
        let consistency: SemanticReadConsistency
        let selectedElements: Int?
        let selectedFields: Int?
        let sourceTruncated: Bool
        var outputTruncated: Bool
        var fieldTruncated: Bool
        var fields: [String: Field]
        var bodyComplete: Bool {
            selectedFields.map { $0 == fields.count && fields.values.allSatisfy(\.complete) } == true
        }
        var capturedComplete: Bool { consistency == .immutableCapture && bodyComplete && !outputTruncated }
        var fieldsIncomplete: Bool {
            fields.values.contains { !$0.complete } || (fieldTruncated && !bodyComplete)
        }
    }
    private struct ScopeIdentity: Encodable {
        let source: UUID
        let targetGeneration: String
        let consistency: SemanticReadConsistency
        let view: SemanticReadView
        let query: String?
        let subtree: String?
        // Each live-validated page stands alone, even if the backend reuses a
        // source ID. It cannot be combined into a fictitious immutable tree.
        let livePage: UUID?
    }
    private struct FieldIdentity: Encodable {
        let node: String
        let field: SemanticReadField
    }

    private var scopes: [String: Scope] = [:]
    private var receiptDigests: [String: String] = [:]
    private(set) var historyDropped = false

    init() {}

    var hasEvidence: Bool { !scopes.isEmpty || historyDropped }

    mutating func observe(_ receipt: SemanticReadReceipt) throws {
        try Self.validate(receipt)
        let receiptKey = try Self.fingerprint(receipt.id)
        let digest = try Self.fingerprint(receipt)
        if let prior = receiptDigests[receiptKey] {
            guard prior == digest else { throw Failure.conflictingReceipt }
            return
        }
        let key = try Self.fingerprint(ScopeIdentity(source: receipt.sourceID,
            targetGeneration: receipt.targetGeneration, consistency: receipt.consistency,
            view: receipt.view, query: receipt.query, subtree: receipt.subtreeNodeID,
            livePage: receipt.consistency == .immutableCapture ? nil : receipt.id))
        guard receiptDigests.count < Self.maximumReceipts,
              scopes[key] != nil || scopes.count < Self.maximumScopes else {
            historyDropped = true; return
        }
        var scope = scopes[key] ?? Scope(consistency: receipt.consistency,
            selectedElements: receipt.selectedElementCount, selectedFields: receipt.selectedFieldCount,
            sourceTruncated: receipt.sourceTruncated, outputTruncated: receipt.outputTruncated,
            fieldTruncated: receipt.fieldTruncated, fields: [:])
        guard scope.selectedElements == receipt.selectedElementCount,
              scope.selectedFields == receipt.selectedFieldCount,
              scope.sourceTruncated == receipt.sourceTruncated else { throw Failure.conflictingReceipt }
        for exposure in receipt.exposures {
            let fieldKey = try Self.fingerprint(FieldIdentity(node: exposure.nodeID, field: exposure.field))
            var field = scope.fields[fieldKey] ?? Field(total: exposure.totalUTF8,
                kind: exposure.kind, provenance: exposure.provenance, spans: [])
            guard field.total == exposure.totalUTF8, field.kind == exposure.kind,
                  field.provenance == exposure.provenance else { throw Failure.conflictingReceipt }
            field.spans = Self.merged(field.spans + [Span(start: exposure.startUTF8, end: exposure.endUTF8)])
            guard field.spans.count <= Self.maximumRangesPerField else { historyDropped = true; return }
            scope.fields[fieldKey] = field
        }
        guard scope.selectedFields.map({ scope.fields.count <= $0 }) ?? true else { throw Failure.conflictingReceipt }
        let otherFields = scopes.filter { $0.key != key }.values.reduce(0) { $0 + $1.fields.count }
        guard scope.fields.count <= Self.maximumFieldsPerScope,
              otherFields + scope.fields.count <= Self.maximumFields else { historyDropped = true; return }
        scope.outputTruncated = receipt.outputTruncated
        scope.fieldTruncated = receipt.fieldTruncated
        // Publish atomically: malformed/conflicting or over-budget pages never
        // partially advance evidence and cannot erase previously retained gaps.
        scopes[key] = scope
        receiptDigests[receiptKey] = digest
    }

    var statistics: Statistics {
        let values = Array(scopes.values)
        let fields = values.flatMap { $0.fields.values }
        let complete = values.filter(\.capturedComplete).count
        let visible = fields.filter { $0.exposedBytes > 0 }
        return Statistics(scopes: values.count, capturedSelectionsComplete: complete,
            partialScopes: values.filter { !$0.capturedComplete || $0.sourceTruncated }.count,
            unknownScopes: values.filter { $0.consistency != .immutableCapture || $0.selectedFields == nil }.count,
            sourceTruncatedScopes: values.filter(\.sourceTruncated).count,
            outputTruncatedScopes: values.filter(\.outputTruncated).count,
            fieldIncompleteScopes: values.filter(\.fieldsIncomplete).count,
            exposedFields: fields.count, completeFields: fields.filter(\.complete).count,
            exposedUTF8: fields.reduce(0) { $0 + $1.exposedBytes },
            readableFields: visible.filter { $0.kind == .readable }.count,
            controlFields: visible.filter { $0.kind == .control }.count,
            navigationFields: visible.filter { $0.kind == .navigation }.count,
            metadataFields: visible.filter { $0.kind == .metadata }.count,
            unknownFields: visible.filter { $0.kind == .unknown }.count,
            historyDropped: historyDropped)
    }

    /// Fixed vocabulary and bounded counters only. No source identity, URL,
    /// query, text, action or continuation token is emitted or persisted here.
    func compactSummary() -> String {
        let s = statistics
        return "READ_COVERAGE scopes=\(s.scopes) captured=\(s.capturedSelectionsComplete) partial=\(s.partialScopes) unknown=\(s.unknownScopes) source_cut=\(s.sourceTruncatedScopes) output_cut=\(s.outputTruncatedScopes) field_cut=\(s.fieldIncompleteScopes) dropped=\(s.historyDropped ? 1 : 0)"
    }

    func checkpointText() -> String {
        let s = statistics
        return compactSummary() + "\n"
            + "Scoped body field occurrences=\(s.exposedFields), fully exposed=\(s.completeFields), scoped exposed UTF8 bytes=\(s.exposedUTF8). "
            + "Observed kinds: readable=\(s.readableFields), control=\(s.controlFields), navigation=\(s.navigationFields), metadata=\(s.metadataFields), unknown=\(s.unknownFields). "
            + "Captured counts cover only an immutable observation's exact view/query/subtree selection. They never establish a full live document, exhaustive search, semantic truth, relevance, or an action outcome. "
            + "Live/unknown sources remain partial. Source, output and field gaps are separate; dropped history means additional coverage is unknown."
    }

    private static func merged(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else { result.append(span) }
        }
        return result
    }

    private static func fingerprint<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ receipt: SemanticReadReceipt) throws {
        let counts = [receipt.selectedElementCount, receipt.selectedFieldCount].compactMap { $0 }
        guard !receipt.targetGeneration.isEmpty, receipt.targetGeneration.utf8.count <= 2_048,
              (receipt.query?.utf8.count ?? 0) <= 8_192,
              (receipt.subtreeNodeID?.utf8.count ?? 0) <= 2_048,
              counts.allSatisfy({ (0...100_000).contains($0) }), receipt.exposures.count <= 4_096 else { throw Failure.invalidReceipt }
        for exposure in receipt.exposures {
            guard !exposure.nodeID.isEmpty, exposure.nodeID.utf8.count <= 2_048,
                  exposure.startUTF8 >= 0, exposure.endUTF8 >= exposure.startUTF8,
                  exposure.totalUTF8 >= exposure.endUTF8, exposure.totalUTF8 <= maximumFieldBytes,
                  exposure.totalUTF8 != 0 || exposure.startUTF8 == 0 && exposure.endUTF8 == 0 else { throw Failure.invalidReceipt }
        }
        if let fields = receipt.selectedFieldCount, let elements = receipt.selectedElementCount {
            guard fields <= elements * 3 else { throw Failure.invalidReceipt }
        }
    }

    private enum CodingKeys: String, CodingKey { case scopes, receiptDigests, historyDropped }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scopes = try values.decode([String: Scope].self, forKey: .scopes)
        receiptDigests = try values.decode([String: String].self, forKey: .receiptDigests)
        historyDropped = try values.decode(Bool.self, forKey: .historyDropped)
        let digestIsValid: (String) -> Bool = { $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard scopes.count <= Self.maximumScopes, receiptDigests.count <= Self.maximumReceipts,
              scopes.keys.allSatisfy(digestIsValid), receiptDigests.keys.allSatisfy(digestIsValid),
              receiptDigests.values.allSatisfy(digestIsValid),
              scopes.values.reduce(0, { $0 + $1.fields.count }) <= Self.maximumFields,
              scopes.isEmpty == receiptDigests.isEmpty else { throw Failure.invalidCheckpoint }
        for scope in scopes.values {
            let counts = [scope.selectedElements, scope.selectedFields].compactMap { $0 }
            guard counts.allSatisfy({ (0...100_000).contains($0) }), scope.fields.count <= Self.maximumFieldsPerScope,
                  scope.fields.keys.allSatisfy(digestIsValid),
                  scope.selectedFields.map({ scope.fields.count <= $0 }) ?? true else { throw Failure.invalidCheckpoint }
            if let fields = scope.selectedFields, let elements = scope.selectedElements {
                guard fields <= elements * 3 else { throw Failure.invalidCheckpoint }
            }
            for field in scope.fields.values {
                guard (0...Self.maximumFieldBytes).contains(field.total), !field.spans.isEmpty,
                      field.spans.count <= Self.maximumRangesPerField,
                      field.spans.allSatisfy({ $0.start >= 0 && $0.end >= $0.start && $0.end <= field.total }),
                      field.spans == Self.merged(field.spans) else { throw Failure.invalidCheckpoint }
            }
        }
    }
}

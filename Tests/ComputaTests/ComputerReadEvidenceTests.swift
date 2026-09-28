import AutomationCore
import Foundation
import XCTest
@testable import Computa

final class ComputerReadEvidenceTests: XCTestCase {
    private let source = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func exposure(_ start: Int, _ end: Int, total: Int = 10,
                          node: String = "PRIVATE_NODE", field: SemanticReadField = .label,
                          kind: SemanticReadContentKind = .readable,
                          provenance: SemanticReadProvenance = .main) -> SemanticReadFieldExposure {
        SemanticReadFieldExposure(nodeID: node, field: field, startUTF8: start,
            endUTF8: end, totalUTF8: total, kind: kind, provenance: provenance)
    }

    private func receipt(_ exposures: [SemanticReadFieldExposure], id: UUID = UUID(),
                         sourceID: UUID? = nil, generation: String = "PRIVATE_TARGET_GENERATION",
                         consistency: SemanticReadConsistency = .immutableCapture,
                         view: SemanticReadView = .content, query: String? = nil, subtree: String? = nil,
                         elements: Int? = 1, fields: Int? = 1,
                         sourceCut: Bool = false, fieldCut: Bool = false, outputCut: Bool = false) -> SemanticReadReceipt {
        SemanticReadReceipt(id: id, sourceID: sourceID ?? source, targetGeneration: generation,
            consistency: consistency, view: view, query: query, subtreeNodeID: subtree,
            selectedElementCount: elements, selectedFieldCount: fields, sourceTruncated: sourceCut,
            fieldTruncated: fieldCut, outputTruncated: outputCut, exposures: exposures)
    }

    func testOnlyExactPublishedSpansAccumulateAndOverlapsDoNotDoubleCount() throws {
        var ledger = ComputerReadEvidence()
        try ledger.observe(receipt([exposure(0, 4)], fieldCut: true, outputCut: true))
        try ledger.observe(receipt([exposure(2, 6)], fieldCut: true, outputCut: true))
        XCTAssertEqual(ledger.statistics.exposedUTF8, 6)
        XCTAssertEqual(ledger.statistics.completeFields, 0)
        XCTAssertEqual(ledger.statistics.fieldIncompleteScopes, 1)
        try ledger.observe(receipt([exposure(6, 10)]))
        XCTAssertEqual(ledger.statistics.exposedUTF8, 10)
        XCTAssertEqual(ledger.statistics.completeFields, 1)
        XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 1)
        XCTAssertEqual(ledger.statistics.fieldIncompleteScopes, 0)
    }

    func testCapturedButUnprintedFieldsAndMissingMiddleNeverBecomeComplete() throws {
        var ledger = ComputerReadEvidence()
        try ledger.observe(receipt([exposure(0, 3), exposure(7, 10)], fields: 2))
        XCTAssertEqual(ledger.statistics.exposedFields, 1)
        XCTAssertEqual(ledger.statistics.exposedUTF8, 6)
        XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 0)
        XCTAssertEqual(ledger.statistics.partialScopes, 1)
        try ledger.observe(receipt([exposure(3, 7)], fields: 2))
        XCTAssertEqual(ledger.statistics.completeFields, 1)
        XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 0)
    }

    func testCaptureGenerationViewQueryAndSubtreeAreIndependentScopes() throws {
        let variants: [SemanticReadReceipt] = [
            receipt([exposure(5, 10)], sourceID: UUID()),
            receipt([exposure(5, 10)], generation: "PRIVATE_CHANGED_GENERATION"),
            receipt([exposure(5, 10)], view: .headings),
            receipt([exposure(5, 10)], query: "PRIVATE_QUERY"),
            receipt([exposure(5, 10)], subtree: "PRIVATE_SUBTREE"),
            receipt([exposure(5, 10)], query: ""),
        ]
        for other in variants {
            var ledger = ComputerReadEvidence()
            try ledger.observe(receipt([exposure(0, 5)], fieldCut: true))
            try ledger.observe(other)
            XCTAssertEqual(ledger.statistics.scopes, 2)
            XCTAssertEqual(ledger.statistics.completeFields, 0)
            XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 0)
        }
    }

    func testLiveValidatedPagesNeverMergeOrCertifyAnImmutableCapture() throws {
        for consistency in [SemanticReadConsistency.liveValidatedPage, .unknown] {
            var ledger = ComputerReadEvidence()
            try ledger.observe(receipt([exposure(0, 5)], consistency: consistency))
            try ledger.observe(receipt([exposure(5, 10)], consistency: consistency))
            try ledger.observe(receipt([exposure(0, 10)], consistency: consistency))
            XCTAssertEqual(ledger.statistics.scopes, 3)
            XCTAssertEqual(ledger.statistics.completeFields, 1)
            XCTAssertEqual(ledger.statistics.unknownScopes, 3)
            XCTAssertEqual(ledger.statistics.partialScopes, 3)
            XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 0)
        }
    }

    func testSourceOutputAndFieldIncompletenessStaySeparate() throws {
        var sourceCut = ComputerReadEvidence()
        try sourceCut.observe(receipt([exposure(0, 10)], sourceCut: true))
        XCTAssertEqual(sourceCut.statistics.capturedSelectionsComplete, 1)
        XCTAssertEqual(sourceCut.statistics.partialScopes, 1)
        XCTAssertEqual(sourceCut.statistics.sourceTruncatedScopes, 1)
        XCTAssertEqual(sourceCut.statistics.fieldIncompleteScopes, 0)
        XCTAssertEqual(sourceCut.statistics.outputTruncatedScopes, 0)
        var outputCut = ComputerReadEvidence()
        try outputCut.observe(receipt([exposure(0, 10)], outputCut: true))
        XCTAssertEqual(outputCut.statistics.outputTruncatedScopes, 1)
        XCTAssertEqual(outputCut.statistics.fieldIncompleteScopes, 0)
        XCTAssertEqual(outputCut.statistics.capturedSelectionsComplete, 0)
        var fieldCut = ComputerReadEvidence()
        try fieldCut.observe(receipt([exposure(0, 5)], fieldCut: true))
        XCTAssertEqual(fieldCut.statistics.fieldIncompleteScopes, 1)
        XCTAssertEqual(fieldCut.statistics.outputTruncatedScopes, 0)
        XCTAssertEqual(fieldCut.statistics.capturedSelectionsComplete, 0)
    }

    func testZeroMatchSelectionAndUnknownCountsNeverBecomeSemanticProof() throws {
        var ledger = ComputerReadEvidence()
        try ledger.observe(receipt([], query: "PRIVATE_QUERY", elements: 0, fields: 0))
        XCTAssertEqual(ledger.statistics.readableFields, 0)
        XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 1)
        XCTAssertTrue(ledger.checkpointText().contains("never establish"))
        try ledger.observe(receipt([exposure(0, 10)], sourceID: UUID(), elements: nil, fields: nil))
        XCTAssertEqual(ledger.statistics.unknownScopes, 1)
        XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 1)
    }

    func testStructuralMainControlsDoNotCountAsReadableFields() throws {
        var ledger = ComputerReadEvidence()
        try ledger.observe(receipt([
            exposure(0, 10, node: "control", kind: .control, provenance: .main),
            exposure(0, 10, node: "sidebar", kind: .navigation, provenance: .navigation),
            exposure(0, 10, node: "body", kind: .readable, provenance: .unknown),
            exposure(0, 10, node: "meta", kind: .metadata),
        ], elements: 4, fields: 4))
        XCTAssertEqual(ledger.statistics.controlFields, 1)
        XCTAssertEqual(ledger.statistics.navigationFields, 1)
        XCTAssertEqual(ledger.statistics.readableFields, 1)
        XCTAssertEqual(ledger.statistics.metadataFields, 1)
    }

    func testEmptyFieldsAndFieldNamesRemainDistinct() throws {
        var ledger = ComputerReadEvidence()
        try ledger.observe(receipt([exposure(0, 0, total: 0), exposure(0, 10, field: .value)], fields: 2))
        XCTAssertEqual(ledger.statistics.completeFields, 2)
        XCTAssertEqual(ledger.statistics.readableFields, 1)
        XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 1)
    }

    func testDuplicateReceiptIsIdempotentAndConflictingReplayIsRejectedAtomically() throws {
        var ledger = ComputerReadEvidence()
        let first = receipt([exposure(0, 5)], fieldCut: true)
        try ledger.observe(first)
        let before = ledger
        try ledger.observe(first)
        XCTAssertEqual(ledger, before)
        XCTAssertThrowsError(try ledger.observe(receipt([exposure(5, 10)], id: first.id)))
        XCTAssertEqual(ledger, before)
    }

    func testConflictingCaptureFactsAndInvalidSpanCannotPartiallyAdvanceCoverage() throws {
        var ledger = ComputerReadEvidence()
        try ledger.observe(receipt([exposure(0, 5)], fieldCut: true))
        let before = ledger
        for invalid in [receipt([exposure(5, 10)], fields: 2),
                        receipt([exposure(5, 10)], sourceCut: true),
                        receipt([exposure(5, 10, total: 11)]),
                        receipt([exposure(5, 10, kind: .control)]),
                        receipt([exposure(5, 10), exposure(-1, 1, node: "invalid")])] {
            XCTAssertThrowsError(try ledger.observe(invalid))
            XCTAssertEqual(ledger, before)
        }
    }

    func testCheckpointRoundTripPreservesPartialCoverageWithoutPrivateIdentifiers() throws {
        var ledger = ComputerReadEvidence()
        let page = receipt([exposure(0, 5)], query: "PRIVATE_QUERY", subtree: "PRIVATE_SUBTREE", fieldCut: true, outputCut: true)
        try ledger.observe(page)
        let encoded = try JSONEncoder().encode(ledger)
        let serialized = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(serialized.contains("PRIVATE"))
        XCTAssertFalse(serialized.contains(source.uuidString))
        XCTAssertFalse(serialized.contains(page.id.uuidString))
        var restored = try JSONDecoder().decode(ComputerReadEvidence.self, from: encoded)
        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.statistics.partialScopes, 1)
        try restored.observe(receipt([exposure(5, 10)], query: "PRIVATE_QUERY", subtree: "PRIVATE_SUBTREE"))
        XCTAssertEqual(restored.statistics.capturedSelectionsComplete, 1)
        for text in [restored.checkpointText(), restored.compactSummary()] {
            XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains("http"))
            XCTAssertFalse(text.contains("cursor=")); XCTAssertFalse(text.contains("action_id"))
        }
        let receiptData = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(SemanticReadReceipt.self, from: receiptData), page)
    }

    func testCapacityDropsAreExplicitBoundedAndDoNotEvictKnownPartialEvidence() throws {
        var ledger = ComputerReadEvidence()
        for _ in 0..<20 {
            try ledger.observe(receipt([exposure(0, 5)], sourceID: UUID(), fieldCut: true, outputCut: true))
        }
        XCTAssertTrue(ledger.hasEvidence)
        XCTAssertTrue(ledger.historyDropped)
        XCTAssertEqual(ledger.statistics.scopes, 16)
        XCTAssertEqual(ledger.statistics.partialScopes, 16)
        XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 0)
        XCTAssertLessThanOrEqual(ledger.compactSummary().utf8.count, 128)
        XCTAssertTrue(ledger.compactSummary().contains("dropped=1"))
        let restored = try JSONDecoder().decode(ComputerReadEvidence.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.statistics, ledger.statistics)
    }

    func testReceiptCapacityCannotCreateCoverageFromAnUnretainedPage() throws {
        var ledger = ComputerReadEvidence()
        for _ in 0..<256 { try ledger.observe(receipt([exposure(0, 5)], fieldCut: true)) }
        try ledger.observe(receipt([exposure(5, 10)]))
        XCTAssertTrue(ledger.historyDropped)
        XCTAssertEqual(ledger.statistics.exposedUTF8, 5)
        XCTAssertEqual(ledger.statistics.capturedSelectionsComplete, 0)
    }

    func testOversizedFieldPopulationAndFragmentationRemainUnknown() throws {
        var ledger = ComputerReadEvidence()
        let many = (0..<1_025).map { exposure(0, 10, node: "node-\($0)") }
        try ledger.observe(receipt(many, elements: 1_025, fields: 1_025))
        XCTAssertTrue(ledger.historyDropped)
        XCTAssertEqual(ledger.statistics.scopes, 0)
        XCTAssertTrue(ledger.hasEvidence)
        var fragments = ComputerReadEvidence()
        for index in 0..<33 {
            try fragments.observe(receipt([exposure(index * 2, index * 2 + 1, total: 100)], fieldCut: true))
        }
        XCTAssertTrue(fragments.historyDropped)
        XCTAssertEqual(fragments.statistics.exposedUTF8, 32)
        XCTAssertEqual(fragments.statistics.capturedSelectionsComplete, 0)
    }

    func testMalformedCheckpointCannotRestoreImpossibleSpans() throws {
        var ledger = ComputerReadEvidence()
        try ledger.observe(receipt([exposure(0, 5)], fieldCut: true))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var scopes = try XCTUnwrap(object["scopes"] as? [String: [String: Any]])
        let scopeKey = try XCTUnwrap(scopes.keys.first)
        var scope = try XCTUnwrap(scopes[scopeKey])
        var fields = try XCTUnwrap(scope["fields"] as? [String: [String: Any]])
        let fieldKey = try XCTUnwrap(fields.keys.first)
        fields[fieldKey]?["spans"] = [["start": 0, "end": 20]]
        scope["fields"] = fields; scopes[scopeKey] = scope; object["scopes"] = scopes
        XCTAssertThrowsError(try JSONDecoder().decode(ComputerReadEvidence.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}

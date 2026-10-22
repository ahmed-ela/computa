import Foundation
import XCTest
@testable import Computa

final class ComputerExecutionSafetyTests: XCTestCase {
    func testHistoricalReceiptLookupIsBoundedAndSeparateFromLiveVerification() throws {
        XCTAssertEqual(try ComputerOutcomeToolContract.validateOperationID(["operation_id": "action"]), "action")
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(["operation_id": "action"]))
        for invalid in [["operation_id": ""], ["operation_id": "\nforged"],
            ["operation_id": String(repeating: "x", count: 257)], ["operation_id": "action", "verified": true]] as [[String: Any]] {
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validateOperationID(invalid))
        }
        var ledger = ComputerActionEvidence(turnID: "current-turn")
        try ledger.recordObservation(id: "before", targetID: "tab", properties: ["value": "before"])
        try ledger.begin(operationID: "verified", tool: "computer_v2_ax", targetID: "tab", requiresVerification: true)
        try ledger.recordDispatch(operationID: "verified", state: .dispatched)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["value": "after"])
        _ = try ledger.verify(operationID: "verified", observationID: "after", property: "value", expectedValue: "after")
        let frozen = ledger
        let status = try XCTUnwrap(ComputerOutcomeToolContract.historicalStatus(operationID: "verified", evidence: ledger, activeTurnID: "current-turn"))
        XCTAssertTrue(status.contains("status=original_property_verified live_observation=false"))
        XCTAssertFalse(status.contains("VERIFIED_PROPERTY"))
        XCTAssertFalse(status.contains("snapshot_id="))
        XCTAssertLessThan(status.utf8.count, 1_024)
        XCTAssertEqual(ledger, frozen, "A lookup cannot rewrite the receipt or ledger.")
        XCTAssertNil(ComputerOutcomeToolContract.historicalStatus(operationID: "verified", evidence: ledger, activeTurnID: "other-turn"))
        XCTAssertNil(ComputerOutcomeToolContract.historicalStatus(operationID: "unknown", evidence: ledger, activeTurnID: "current-turn"))
        let unrelatedTaskLedger = ComputerActionEvidence(turnID: "current-turn")
        XCTAssertNil(ComputerOutcomeToolContract.historicalStatus(operationID: "verified", evidence: unrelatedTaskLedger, activeTurnID: "current-turn"))
    }

    func testHistoricalNotPerformedRequiresTypedPredispatchEvidenceWithoutEffects() throws {
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.begin(operationID: "rejected", tool: "computer_v2_ax", targetID: "tab", requiresVerification: true)
        try ledger.recordPreflightRejection(operationID: "rejected", kind: .freshObservationRequired,
            code: "missing_reference", message: "Not performed")
        let frozen = ledger
        let status = try XCTUnwrap(ComputerOutcomeToolContract.historicalStatus(operationID: "rejected", evidence: ledger, activeTurnID: "turn"))
        XCTAssertTrue(status.contains("status=not_performed live_observation=false"))
        XCTAssertEqual(ledger, frozen)
        XCTAssertNotNil(ledger.completionDiagnostic, "Historical status alone does not correct the prerequisite.")
        for (id, dispatch) in [("ordinary", ComputerActionEvidence.DispatchState.notDispatched),
                               ("uncertain", .unknown), ("dispatched", .dispatched)] {
            try ledger.begin(operationID: id, tool: "computer_v2_ax", targetID: "tab", requiresVerification: true)
            try ledger.recordFailure(operationID: id, code: "ordinary_failure", message: "No typed rejection", dispatch: dispatch)
            XCTAssertNil(ComputerOutcomeToolContract.historicalStatus(operationID: id, evidence: ledger, activeTurnID: "turn"))
        }
    }

    func testVerificationAcceptsOnlyFiniteObservedPropertyContract() throws {
        var arguments = fixture()
        let value = try ComputerOutcomeToolContract.validate(arguments)
        XCTAssertEqual(value.operationID, "action-1")
        XCTAssertEqual(value.property, "element:7:value")
        XCTAssertEqual(value.expected, "requested query")
        arguments["property"] = "document_url"
        arguments.removeValue(forKey: "element_index")
        arguments["expected"] = "https://example.test/results"
        XCTAssertEqual(try ComputerOutcomeToolContract.validate(arguments).property, "document_url")
    }

    func testModelBooleanCannotDeclareVerificationOrWholeTaskSuccess() throws {
        for injected in ["verified", "success", "task_complete", "empty_result"] {
            var arguments = fixture()
            arguments[injected] = true
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        }
        var arguments = fixture()
        arguments["property"] = "task_complete"
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        arguments = fixture()
        arguments["expected"] = true
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
    }

    func testElementIndexRejectsBooleansFractionsAndNonfiniteValues() throws {
        let invalid: [Any] = [true, false, "7", -1, 1.25, Double.infinity, Double.nan, NSNull()]
        for index in invalid {
            var arguments = fixture()
            arguments["element_index"] = index
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments), "Rejected index: \(index)")
        }
        var arguments = fixture()
        arguments.removeValue(forKey: "element_index")
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        arguments = fixture()
        arguments["property"] = "document_url"
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
    }

    func testMissingAndMalformedReferencesOrExpectationsFailClosed() throws {
        for field in ["operation_id", "snapshot_id", "property", "expected"] {
            var arguments = fixture()
            arguments.removeValue(forKey: field)
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        }
        for expected in ["", " \n\t", String(repeating: "x", count: 2_049)] {
            var arguments = fixture()
            arguments["expected"] = expected
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        }
        for snapshot in ["", "made-up", "1"] {
            var arguments = fixture()
            arguments["snapshot_id"] = snapshot
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        }
    }

    func testPublishedSchemaRejectsAdditionalPropertiesAndHasNoSuccessFlag() throws {
        XCTAssertEqual(ComputerOutcomeToolContract.spec["type"] as? String, "function")
        XCTAssertTrue(ComputerV2ToolContract.specs.allSatisfy { $0["type"] as? String == ComputerOutcomeToolContract.spec["type"] as? String }, "Bundled App Server rejects mixed canonical and legacy tool declarations.")
        let schema = try XCTUnwrap(ComputerOutcomeToolContract.spec["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["operation_id", "snapshot_id", "property", "element_index", "expected"])
        XCTAssertEqual(ComputerOutcomeToolContract.name, "computer_v2_verify")
    }

    func testChangingOpaqueCapabilitiesDoesNotResetRetryBudget() {
        let one = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: [
            "snapshot_id": "one", "capture_id": "capture-one", "cursor": "page-one",
            "element_index": 7, "text": "requested query",
        ])
        let two = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: [
            "snapshot_id": "two", "capture_id": "capture-two", "cursor": "page-two",
            "element_index": 7, "text": "requested query",
        ])
        XCTAssertEqual(one, two)
        var guardrail = ComputerUnchangedAttemptGuard()
        XCTAssertFalse(guardrail.failed(key: one))
        XCTAssertFalse(guardrail.failed(key: two))
        XCTAssertTrue(guardrail.failed(key: one))
    }

    func testActionAndTextRemainPartOfRetryIdentity() {
        let base: [String: Any] = ["snapshot_id": "one", "element_index": 7, "text": "snapshot_id=literal user text"]
        let key = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: base)
        var differentText = base
        differentText["text"] = "another query"
        XCTAssertNotEqual(key, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: differentText))
        XCTAssertNotEqual(key, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_ax", arguments: base))
        XCTAssertTrue(key.contains("snapshot_id=literal user text"))
    }

    func testObservedStableControlIdentitySurvivesSnapshotReindexing() {
        let first: [String: Any] = ["snapshot_id": "one", "element_index": 7, "text": "query"]
        let later: [String: Any] = ["snapshot_id": "two", "element_index": 22, "text": "query"]
        let key = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: first, observedElementIdentity: "node:50")
        XCTAssertEqual(key, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: later, observedElementIdentity: "node:50"))
        XCTAssertNotEqual(key, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: later, observedElementIdentity: "node:51"))
    }

    func testOnlySuccessfulMatchingOperationResetsItsRetryBudget() {
        var guardrail = ComputerUnchangedAttemptGuard()
        XCTAssertFalse(guardrail.failed(key: "failed-input"))
        XCTAssertFalse(guardrail.failed(key: "failed-input"))
        guardrail.succeeded(key: "unrelated-snapshot")
        XCTAssertTrue(guardrail.failed(key: "failed-input"))
        guardrail.succeeded(key: "failed-input")
        XCTAssertFalse(guardrail.failed(key: "failed-input"))
    }

    private func fixture() -> [String: Any] {
        ["operation_id": "action-1", "snapshot_id": "D56814BA-CF94-44BB-938F-1008A315D982",
         "property": "value", "element_index": 7, "expected": "requested query"]
    }
}

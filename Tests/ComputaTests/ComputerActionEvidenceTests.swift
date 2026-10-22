import Foundation
import XCTest
@testable import AutomationCore
@testable import Computa

final class ComputerActionEvidenceTests: XCTestCase {
    func testForegroundEffectsAreNotHiddenByUndispatchedInputAndSurviveCheckpoint() throws {
        var ledger = try mutation()
        try ledger.recordForegroundEffect(operationID: "input", effect: .activationRequested)
        try ledger.recordForegroundEffect(operationID: "input", effect: .activationCompleted)
        try ledger.recordFailure(operationID: "input", code: "window_changed", message: "Window changed", dispatch: .notDispatched)
        XCTAssertEqual(ledger.operations.first?.dispatch, .notDispatched)
        XCTAssertEqual(ledger.operations.first?.foregroundEffect, .activationCompleted)
        XCTAssertTrue(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "set-query", nextTargetID: "tab"))
        XCTAssertTrue(try ledger.checkpointText().contains("foreground_effect=activation_completed"))
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: ledger.turnID), ledger)
        XCTAssertThrowsError(try ledger.recordPreflightRejection(operationID: "input", kind: .freshObservationRequired,
            code: "stale", message: "Not a side-effect-free rejection"))
    }

    func testAXFocusTransitionRetainsUnknownActionOutcome() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .unknown)
        try ledger.recordForegroundEffect(operationID: "input", effect: .changedDuringAX)
        try ledger.recordFailure(operationID: "input", code: "focus_changed", message: "Attribution unknown")
        XCTAssertEqual(ledger.operations.first?.dispatch, .unknown)
        XCTAssertNotNil(ledger.completionDiagnostic)
        XCTAssertTrue(try ledger.checkpointText().contains("focus_changed_during_ax_attribution_unknown"))
    }

    func testDispatchAndObservationAloneDoNotVerifyTaskOutcome() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["node:17:value": "query"])
        XCTAssertNotNil(ledger.completionDiagnostic)
        let proof = try ledger.verify(operationID: "input", observationID: "after",
                                      property: "node:17:value", expectedValue: "query")
        XCTAssertEqual(proof.property, "node:17:value")
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertTrue(try ledger.checkpointText().contains("does not verify arbitrary task claims"))
    }

    func testInputValueDoesNotProveSearchResultsOrEmptyState() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["node:17:value": "query"])
        XCTAssertThrowsError(try ledger.verify(operationID: "input", observationID: "after",
                                               property: "node:20:text", expectedValue: "No matching results")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .propertyMismatch)
        }
        XCTAssertNotNil(ledger.completionDiagnostic)
    }

    func testFreshSameTargetInspectionAllowsDistinctIntentWithoutResolvingOutcome() throws {
        for state in [ComputerActionEvidence.DispatchState.dispatched, .unknown] {
            var ledger = try mutation()
            try ledger.recordDispatch(operationID: "input", state: state)
            try ledger.recordObservation(id: "after", targetID: "tab", properties: [:])
            let beforeAdmission = ledger
            XCTAssertFalse(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "different-stable-intent", nextTargetID: "tab"))
            XCTAssertEqual(ledger, beforeAdmission, "Input admission is read-only; observation is not outcome proof.")
            XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["input"])
            XCTAssertNil(ledger.operations.first?.verification)
            XCTAssertNotNil(ledger.completionDiagnostic)
        }
    }

    func testInputAdmissionRejectsMatchingUnknownIntentAndDifferentTargetAfterInspection() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .unknown)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: [:])
        for key: String? in ["set-query", nil, "", "  "] {
            XCTAssertTrue(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: key, nextTargetID: "tab"))
        }
        for target: String? in ["other-tab", nil, ""] {
            XCTAssertTrue(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "different-stable-intent", nextTargetID: target))
        }
        var unknownIntent = ComputerActionEvidence(turnID: "turn")
        try unknownIntent.begin(operationID: "input", tool: "computer_v2_click", targetID: "tab")
        try unknownIntent.recordDispatch(operationID: "input", state: .dispatched)
        try unknownIntent.recordObservation(id: "after", targetID: "tab", properties: [:])
        XCTAssertTrue(unknownIntent.blocksFurtherInput(operationID: "input", nextRecoveryKey: "different-stable-intent", nextTargetID: "tab"))
    }

    func testInputAdmissionRejectsPreActionRetainedAndWrongTargetObservations() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        XCTAssertTrue(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "different-stable-intent", nextTargetID: "tab"),
                      "The baseline read predates dispatch.")
        try ledger.recordObservation(id: "retained-page", targetID: "tab", properties: [:], isLive: false)
        XCTAssertTrue(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "different-stable-intent", nextTargetID: "tab"))
        try ledger.recordObservation(id: "wrong-target", targetID: "other-tab", properties: [:])
        XCTAssertTrue(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "different-stable-intent", nextTargetID: "tab"))
        try ledger.recordObservation(id: "before-failure", targetID: "tab", properties: [:])
        try ledger.recordFailure(operationID: "input", code: "reply_lost", message: "Delivery unknown", dispatch: .unknown)
        XCTAssertTrue(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "different-stable-intent", nextTargetID: "tab"),
                      "Observation must follow the latest uncertainty boundary.")
    }

    func testInputAdmissionDoesNotBlockUndispatchedOrResolvedOperationsAndUnknownReceiptFailsClosed() throws {
        var ledger = try mutation()
        XCTAssertFalse(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "set-query", nextTargetID: "tab"))
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.verify(operationID: "input", observationID: "after", property: "node:17:value", expectedValue: "query")
        XCTAssertFalse(ledger.blocksFurtherInput(operationID: "input", nextRecoveryKey: "set-query", nextTargetID: "tab"))
        XCTAssertTrue(ledger.blocksFurtherInput(operationID: "unknown", nextRecoveryKey: "different-stable-intent", nextTargetID: "tab"))
    }

    func testWrongTargetAndPreActionObservationsCannotVerify() throws {
        var ledger = try mutation()
        try ledger.recordObservation(id: "too-early", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        XCTAssertThrowsError(try ledger.verify(operationID: "input", observationID: "too-early",
                                               property: "node:17:value", expectedValue: "query")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .staleObservation)
        }
        try ledger.recordObservation(id: "wrong-tab", targetID: "other-tab", properties: ["node:17:value": "query"])
        XCTAssertThrowsError(try ledger.verify(operationID: "input", observationID: "wrong-tab",
                                               property: "node:17:value", expectedValue: "query")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .wrongTarget)
        }
    }

    func testReusingSnapshotIDAndRetainedPaginationCannotRefreshProof() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        XCTAssertThrowsError(try ledger.recordObservation(id: "before", targetID: "tab", properties: ["node:17:value": "query"]))
        try ledger.recordObservation(id: "page", targetID: "tab", properties: ["node:17:value": "query"], isLive: false)
        XCTAssertThrowsError(try ledger.verify(operationID: "input", observationID: "page",
                                               property: "node:17:value", expectedValue: "query")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .staleObservation)
        }
    }

    func testStaticPageLabelDoesNotVerifyMutation() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["node:1:text": "Mailbox"])
        XCTAssertThrowsError(try ledger.verify(operationID: "input", observationID: "after",
                                               property: "node:1:text", expectedValue: "Mailbox")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .unchangedProperty)
        }
        XCTAssertNotNil(ledger.completionDiagnostic)
    }

    func testPreviouslyUnseenStaticTextCannotProveAChangeAfterProgressiveRead() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.recordObservation(id: "expanded-after", targetID: "tab", properties: [
            "node:200:text": "Existing text omitted by the earlier partial read",
            "node:17:value": "query",
        ])
        XCTAssertThrowsError(try ledger.verify(operationID: "input", observationID: "expanded-after",
            property: "node:200:text", expectedValue: "Existing text omitted by the earlier partial read")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .missingBaseline)
        }
        XCTAssertNotNil(ledger.completionDiagnostic)
        try ledger.verify(operationID: "input", observationID: "expanded-after",
                          property: "node:17:value", expectedValue: "query")
        XCTAssertNil(ledger.completionDiagnostic, "The known empty field changing to the requested value remains verifiable.")
    }

    func testPropertyDroppedFromBoundedBaselineCannotBeTreatedAsNew() throws {
        var ledger = ComputerActionEvidence(turnID: "turn")
        let properties = Dictionary(uniqueKeysWithValues: (0 ..< 150).map { (String(format: "node:%03d:text", $0), "Existing text") })
        try ledger.recordObservation(id: "before", targetID: "tab", properties: properties)
        try ledger.begin(operationID: "press", tool: "computer_v2_ax", targetID: "tab")
        try ledger.recordDispatch(operationID: "press", state: .dispatched)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["node:149:text": "Existing text"])
        XCTAssertThrowsError(try ledger.verify(operationID: "press", observationID: "after",
                                               property: "node:149:text", expectedValue: "Existing text")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .missingBaseline)
        }
        XCTAssertNotNil(ledger.completionDiagnostic)
    }

    func testFailedPreDispatchCannotBeClearedByObservingAlreadyExistingContent() throws {
        var ledger = try mutation()
        try ledger.recordFailure(operationID: "input", code: "field_unavailable", message: "Field missing", dispatch: .notDispatched)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["node:17:value": "query"])
        XCTAssertThrowsError(try ledger.verify(operationID: "input", observationID: "after",
                                               property: "node:17:value", expectedValue: "query")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .invalidTransition)
        }
        XCTAssertTrue(try XCTUnwrap(ledger.completionDiagnostic).contains("failed operation"))
    }

    func testUnknownDeliveryCanBeReconciledWithoutRepeatingMutation() throws {
        var ledger = try mutation()
        try ledger.recordFailure(operationID: "input", code: "response_lost", message: "Reply timed out", dispatch: .unknown)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.verify(operationID: "input", observationID: "after", property: "node:17:value", expectedValue: "query")
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(ledger.operations.count, 1)
        XCTAssertEqual(ledger.operations[0].dispatch, .unknown)
        XCTAssertEqual(ledger.operations[0].failureCode, "response_lost")
    }

    func testVerifiedRecoveryRequiresSameOperationAndTarget() throws {
        for mismatch in ["key", "target", "none"] {
            var ledger = try mutation()
            try ledger.recordFailure(operationID: "input", code: "stale", message: "Stale", dispatch: .notDispatched)
            let target = mismatch == "target" ? "other-tab" : "tab"
            try ledger.begin(operationID: "retry", tool: "set_text", targetID: target,
                             recoveryKey: mismatch == "key" ? "other-query" : "set-query",
                             baselineProperties: ["node:17:value": ""])
            try ledger.recordDispatch(operationID: "retry", state: .dispatched)
            try ledger.recordObservation(id: "after", targetID: target, properties: ["node:17:value": "query"])
            try ledger.verify(operationID: "retry", observationID: "after", property: "node:17:value", expectedValue: "query")
            if mismatch == "none" {
                try ledger.recover(failedOperationID: "input", with: "retry")
                XCTAssertNil(ledger.completionDiagnostic)
            } else {
                XCTAssertThrowsError(try ledger.recover(failedOperationID: "input", with: "retry"))
                XCTAssertNotNil(ledger.completionDiagnostic)
            }
        }
    }

    func testSuccessfulReadCanResolveSameFailedReadButNotMutation() throws {
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.begin(operationID: "read-1", tool: "snapshot", targetID: "tab", recoveryKey: "read", requiresVerification: false)
        try ledger.recordFailure(operationID: "read-1", code: "temporary", message: "Read unavailable", dispatch: .notDispatched)
        try ledger.begin(operationID: "read-2", tool: "snapshot", targetID: "tab", recoveryKey: "read", requiresVerification: false)
        try ledger.recordDispatch(operationID: "read-2", state: .dispatched)
        try ledger.recover(failedOperationID: "read-1", with: "read-2")
        XCTAssertNil(ledger.completionDiagnostic)

        try ledger.begin(operationID: "mutation", tool: "set_text", targetID: "tab", recoveryKey: "read")
        try ledger.recordFailure(operationID: "mutation", code: "failed", message: "Mutation failed", dispatch: .notDispatched)
        try ledger.begin(operationID: "read-3", tool: "snapshot", targetID: "tab", recoveryKey: "read", requiresVerification: false)
        try ledger.recordDispatch(operationID: "read-3", state: .dispatched)
        XCTAssertThrowsError(try ledger.recover(failedOperationID: "mutation", with: "read-3"))
    }

    func testVerifiedDirectTextRecoversUndispatchedFocusOnSameEditableField() throws {
        var ledger = try focusAlternative()
        XCTAssertNotNil(ledger.completionDiagnostic)
        try ledger.recoverUndispatchedFocus(failedOperationID: "focus", with: "fill")
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(ledger.operations.first?.recoveredBy, "fill")
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testFocusAlternativeRejectsDifferentFieldTargetAndNonValueProof() throws {
        for (target, property) in [("other-tab", "node:17:value"), ("tab", "node:18:value"), ("tab", "node:17:text")] {
            var ledger = try focusAlternative(successorTarget: target, property: property)
            XCTAssertThrowsError(try ledger.recoverUndispatchedFocus(failedOperationID: "focus", with: "fill")) {
                XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .invalidRecovery)
            }
            XCTAssertNotNil(ledger.completionDiagnostic)
        }
    }

    func testFocusAlternativeCannotClearDispatchedOrUnknownPress() throws {
        for state in [ComputerActionEvidence.DispatchState.dispatched, .unknown] {
            var ledger = try focusAlternative(failedDispatch: state)
            XCTAssertThrowsError(try ledger.recoverUndispatchedFocus(failedOperationID: "focus", with: "fill"))
            XCTAssertNotNil(ledger.completionDiagnostic)
        }
    }

    func testFocusAlternativeRejectsWrongOperationAndMissingObservedFocusKey() throws {
        for (failedTool, successorTool, key, hasFailure) in [
            ("computer_v2_pointer", "computer_v2_set_text", "focus:node:17", true),
            ("computer_v2_ax", "computer_v2_type", "focus:node:17", true),
            ("computer_v2_ax", "computer_v2_set_text", "unrelated:node:17", true),
            ("computer_v2_ax", "computer_v2_set_text", "focus:", true),
            ("computer_v2_ax", "computer_v2_set_text", "focus:node:17", false),
        ] {
            var ledger = try focusAlternative(failedTool: failedTool, successorTool: successorTool,
                                              focusKey: key, hasFailure: hasFailure)
            XCTAssertThrowsError(try ledger.recoverUndispatchedFocus(failedOperationID: "focus", with: "fill"))
            XCTAssertNotNil(ledger.completionDiagnostic)
        }
    }

    func testRestoredFocusRecoveryRevalidatesFiniteAlternative() throws {
        var ledger = try focusAlternative()
        try ledger.recoverUndispatchedFocus(failedOperationID: "focus", with: "fill")
        let data = try ledger.checkpointData()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["dispatch", "tool", "recoveryKey", "targetID"] {
            var object = original
            var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
            operations[0][field] = field == "dispatch" ? "dispatched" : "different"
            object["operations"] = operations
            XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"))
        }
    }

    func testCheckpointRetainsUnresolvedFailureAcrossRestoreAndRejectsWrongTurn() throws {
        var ledger = try mutation()
        try ledger.recordFailure(operationID: "input", code: "failed", message: "Failure", dispatch: .notDispatched)
        let data = try ledger.checkpointData()
        let restored = try ComputerActionEvidence.restore(data, turnID: "turn")
        XCTAssertEqual(restored, ledger)
        XCTAssertNotNil(restored.completionDiagnostic)
        XCTAssertThrowsError(try ComputerActionEvidence.restore(data, turnID: "other-turn"))
        let text = try restored.checkpointText()
        XCTAssertTrue(text.contains("status=failed"))
        XCTAssertFalse(text.contains("Mailbox"), "Compaction checkpoint must not repeat page content.")
    }

    func testBoundPrunesResolvedReceiptsButNeverUnresolvedFailures() throws {
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.begin(operationID: "failed", tool: "set_text", targetID: "tab")
        try ledger.recordFailure(operationID: "failed", code: "failed", message: "Failure")
        for index in 0 ..< 100 {
            let id = "read-\(index)"
            try ledger.begin(operationID: id, tool: "snapshot", targetID: "tab", requiresVerification: false)
            try ledger.recordDispatch(operationID: id, state: .dispatched)
        }
        XCTAssertEqual(ledger.operations.count, ComputerActionEvidence.maximumOperations)
        XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["failed"])

        var full = ComputerActionEvidence(turnID: "turn")
        for index in 0 ..< ComputerActionEvidence.maximumOperations {
            try full.begin(operationID: "pending-\(index)", tool: "set_text", targetID: "tab")
        }
        XCTAssertThrowsError(try full.begin(operationID: "overflow", tool: "set_text", targetID: "tab"))
        XCTAssertEqual(full.operations.count, ComputerActionEvidence.maximumOperations)
    }

    func testOversizedPropertiesAreNotTruncatedIntoMatchingValues() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.recordObservation(id: "after", targetID: "tab", properties: ["node:17:value": String(repeating: "a", count: 10_000)])
        XCTAssertThrowsError(try ledger.verify(operationID: "input", observationID: "after",
                                               property: "node:17:value", expectedValue: String(repeating: "a", count: 8_192)))
        XCTAssertNotNil(ledger.completionDiagnostic)
    }

    func testUnboundAXRejectionIsCorrectedByFreshBoundObservationWithoutPretendingItRan() throws {
        var ledger = try preflight(kind: .bindingRequired, target: "native:unbound")
        XCTAssertNotNil(ledger.completionDiagnostic)
        try freshRead(&ledger)
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
            correction: .freshBoundObservation(observationID: "observed", targetID: "tab")), 1)
        XCTAssertNil(ledger.completionDiagnostic)
        let rejected = try XCTUnwrap(ledger.operations.first)
        XCTAssertEqual(rejected.dispatch, .notDispatched)
        XCTAssertEqual(rejected.failureCode, "preflight_rejected")
        XCTAssertEqual(rejected.preflightCorrection?.successorOperationID, "read")
        XCTAssertNil(rejected.verification)
        XCTAssertNil(rejected.recoveredBy)
        XCTAssertTrue(try ledger.checkpointText().contains("preflight_corrected_not_performed"))
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)

        // A repaired binding is not evidence that a subsequently requested
        // action worked: that new action retains its normal verification debt.
        try ledger.begin(operationID: "fresh-action", tool: "computer_v2_ax", targetID: "tab", recoveryKey: "press")
        try ledger.recordDispatch(operationID: "fresh-action", state: .dispatched)
        XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["fresh-action"])
        try ledger.recordObservation(id: "changed", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.verify(operationID: "fresh-action", observationID: "changed", property: "node:17:value", expectedValue: "query")
        XCTAssertNil(ledger.completionDiagnostic)
    }

    func testInvalidCursorCombinationCorrectsWithSuccessfulSameTargetReadDespiteDifferentIntentKeys() throws {
        var ledger = try preflight(kind: .invalidArguments, tool: "computer_v2_snapshot", key: "cursor-plus-view", requiresVerification: false)
        try freshRead(&ledger, key: "cursor-alone", isLive: false)
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read", correction: .validatedArguments), 1)
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertNil(ledger.operations.first?.verification, "Accepted pagination arguments do not prove a changed page or search result.")
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testInvalidArgumentsCorrectionRequiresSameToolAndTarget() throws {
        for (tool, target) in [("computer_v2_apps", "tab"), ("computer_v2_snapshot", "other-tab")] {
            var ledger = try preflight(kind: .invalidArguments, tool: "computer_v2_snapshot", requiresVerification: false)
            try freshRead(&ledger, target: target, tool: tool)
            XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read", correction: .validatedArguments), 0)
            XCTAssertNotNil(ledger.completionDiagnostic)
        }
    }

    func testUnboundSchemaRejectionCorrectsAfterSameToolFreshTargetRestoration() throws {
        var ledger = try preflight(kind: .invalidArguments, tool: "computer_v2_snapshot",
            target: "unbound-placeholder", requiresVerification: false, targetWasUnbound: true)
        try freshRead(&ledger, target: "restored-tab")
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read", correction: .validatedArguments), 1)
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(ledger.operations.first?.targetID, "unbound-placeholder")
        XCTAssertEqual(ledger.operations.first?.dispatch, .notDispatched)
        XCTAssertNil(ledger.operations.first?.verification)
        XCTAssertEqual(ledger.operations.first?.preflightCorrection?.observationTargetID, "restored-tab")
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testUnboundSchemaCorrectionRequiresFreshTargetProofAndSameTool() throws {
        for scenario in ["retained", "no-observation", "other-tool", "no-host-fact"] {
            var ledger = try preflight(kind: .invalidArguments, tool: "computer_v2_snapshot",
                target: "unbound-placeholder", requiresVerification: false, targetWasUnbound: scenario != "no-host-fact")
            if scenario == "no-observation" {
                try ledger.begin(operationID: "read", tool: "computer_v2_snapshot", targetID: "restored-tab", requiresVerification: false)
                try ledger.recordDispatch(operationID: "read", state: .dispatched)
            } else {
                try freshRead(&ledger, target: "restored-tab", tool: scenario == "other-tool" ? "computer_v2_apps" : "computer_v2_snapshot",
                              isLive: scenario != "retained")
            }
            XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read", correction: .validatedArguments), 0, scenario)
            XCTAssertNotNil(ledger.completionDiagnostic, scenario)
        }
    }

    func testUnboundSchemaMutationCannotInferIdentityFromVerifiedReplacement() throws {
        var ledger = try preflight(kind: .invalidArguments, target: "unbound-placeholder", targetWasUnbound: true)
        try ledger.begin(operationID: "valid-action", tool: "computer_v2_ax", targetID: "restored-tab",
                         baselineProperties: ["node:17:value": ""])
        try ledger.recordDispatch(operationID: "valid-action", state: .dispatched)
        try ledger.recordObservation(id: "changed", targetID: "restored-tab", properties: ["node:17:value": "query"])
        XCTAssertThrowsError(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "valid-action", correction: .validatedArguments))
        try ledger.verify(operationID: "valid-action", observationID: "changed", property: "node:17:value", expectedValue: "query")
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "valid-action", correction: .validatedArguments), 0)
        XCTAssertNotNil(ledger.completionDiagnostic)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testUnboundHostFactCannotReclassifyUncertainInputOrOtherRejectionKinds() throws {
        for dispatch in [ComputerActionEvidence.DispatchState.unknown, .dispatched] {
            var ledger = try mutation()
            try ledger.recordFailure(operationID: "input", code: "uncertain", message: "Effect uncertain", dispatch: dispatch)
            let before = ledger
            XCTAssertThrowsError(try ledger.recordPreflightRejection(operationID: "input", kind: .invalidArguments,
                code: "schema", message: "Wrong classification", targetWasUnbound: true))
            XCTAssertEqual(ledger, before)
        }
        for kind in [ComputerActionEvidence.PreflightRejection.bindingRequired, .freshObservationRequired] {
            XCTAssertThrowsError(try preflight(kind: kind, targetWasUnbound: true))
        }
    }

    func testUnboundSchemaCheckpointRejectsWrongKindMissingFlagAndMissingTargetProof() throws {
        var ledger = try preflight(kind: .invalidArguments, tool: "computer_v2_snapshot",
            target: "unbound-placeholder", requiresVerification: false, targetWasUnbound: true)
        try freshRead(&ledger)
        try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read", correction: .validatedArguments)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
        for scenario in ["wrong-kind", "missing-flag", "false-flag", "missing-proof"] {
            var object = original
            var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
            if scenario == "wrong-kind" { operations[0]["preflightRejection"] = "bindingRequired" }
            if scenario == "missing-flag" { operations[0].removeValue(forKey: "preflightTargetWasUnbound") }
            if scenario == "false-flag" { operations[0]["preflightTargetWasUnbound"] = false }
            if scenario == "missing-proof" {
                var receipt = try XCTUnwrap(operations[0]["preflightCorrection"] as? [String: Any])
                for key in ["observationID", "observationTargetID", "observationSequence"] { receipt.removeValue(forKey: key) }
                operations[0]["preflightCorrection"] = receipt
            }
            object["operations"] = operations
            XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"), scenario)
        }
    }

    func testInvalidMutationArgumentsNeedVerifiedReplacementBeforeCorrection() throws {
        var ledger = try preflight(kind: .invalidArguments, key: "same-input")
        try ledger.begin(operationID: "valid-action", tool: "computer_v2_ax", targetID: "tab",
                         recoveryKey: "same-input", baselineProperties: ["node:17:value": ""])
        try ledger.recordDispatch(operationID: "valid-action", state: .dispatched)
        XCTAssertThrowsError(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "valid-action", correction: .validatedArguments))
        try ledger.recordObservation(id: "changed", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.verify(operationID: "valid-action", observationID: "changed", property: "node:17:value", expectedValue: "query")
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "valid-action", correction: .validatedArguments), 1)
        XCTAssertNil(ledger.completionDiagnostic)
    }

    func testInvalidMutationCorrectionRequiresExactKnownBoundIntentAfterCompaction() throws {
        let documentScope = String(repeating: "a", count: 64)
        for scenario in ["same", "different-key", "different-target", "missing-key", "missing-successor-key", "unbound", "different-document", "missing-scope", "missing-successor-scope"] {
            var ledger = try preflight(kind: .invalidArguments,
                key: scenario == "missing-key" ? nil : "same-input", targetWasUnbound: scenario == "unbound",
                recoveryScope: scenario == "missing-scope" ? nil : documentScope)
            ledger = try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn")
            let target = scenario == "different-target" ? "other-tab" : "tab"
            try ledger.begin(operationID: "valid-action", tool: "computer_v2_ax", targetID: target,
                recoveryKey: scenario == "missing-successor-key" ? nil : scenario == "different-key" ? "other-input" : "same-input",
                baselineProperties: ["node:17:value": ""],
                recoveryScope: scenario == "missing-successor-scope" ? nil : scenario == "different-document" ? String(repeating: "b", count: 64) : documentScope)
            try ledger.recordDispatch(operationID: "valid-action", state: .dispatched)
            try ledger.recordObservation(id: "changed", targetID: target, properties: ["node:17:value": "query"])
            try ledger.verify(operationID: "valid-action", observationID: "changed", property: "node:17:value", expectedValue: "query")
            XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "valid-action",
                correction: .validatedArguments), scenario == "same" ? 1 : 0, scenario)
            let original = try XCTUnwrap(ledger.operations.first)
            XCTAssertEqual(original.dispatch, .notDispatched, scenario)
            XCTAssertNil(original.verification, scenario)
            XCTAssertEqual(original.preflightCorrection != nil, scenario == "same", scenario)
            XCTAssertEqual(ledger.completionDiagnostic == nil, scenario == "same", scenario)
            XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger, scenario)
            if scenario == "same" {
                XCTAssertTrue(try ledger.checkpointText().contains("preflight_corrected_not_performed"))
            }
        }
    }

    func testMutationCorrectionCheckpointRejectsForgedActionIdentity() throws {
        let scope = String(repeating: "a", count: 64)
        var ledger = try preflight(kind: .invalidArguments, key: "same-input",
                                   recoveryScope: scope)
        try ledger.begin(operationID: "valid-action", tool: "computer_v2_ax", targetID: "tab",
                         recoveryKey: "same-input", baselineProperties: ["node:17:value": ""], recoveryScope: scope)
        try ledger.recordDispatch(operationID: "valid-action", state: .dispatched)
        try ledger.recordObservation(id: "changed", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.verify(operationID: "valid-action", observationID: "changed", property: "node:17:value", expectedValue: "query")
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "valid-action", correction: .validatedArguments), 1)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
        for scenario in ["different-key", "missing-key", "unbound", "different-scope", "missing-scope"] {
            var object = original
            var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
            if scenario == "different-key" { operations[0]["recoveryKey"] = "other-input" }
            if scenario == "missing-key" { operations[0].removeValue(forKey: "recoveryKey") }
            if scenario == "unbound" { operations[0]["preflightTargetWasUnbound"] = true }
            if scenario == "different-scope" { operations[0]["recoveryScope"] = String(repeating: "b", count: 64) }
            if scenario == "missing-scope" { operations[0].removeValue(forKey: "recoveryScope") }
            object["operations"] = operations
            XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"), scenario)
        }
    }

    func testOrdinaryAndUndispatchedFocusRecoveryRequireSameDocumentScope() throws {
        let scope = String(repeating: "a", count: 64)
        for mode in ["ordinary", "focus"] {
            for scenario in ["legacy", "same", "different", "missing-failed", "missing-successor"] {
                let failedScope: String? = ["legacy", "missing-failed"].contains(scenario) ? nil : scope
                let successorScope: String? = ["legacy", "missing-successor"].contains(scenario) ? nil
                    : scenario == "different" ? String(repeating: "b", count: 64) : scope
                let shouldRecover = ["legacy", "same"].contains(scenario)
                var ledger: ComputerActionEvidence
                let failedID: String
                let successorID: String
                if mode == "focus" {
                    ledger = try focusAlternative(failedScope: failedScope, successorScope: successorScope)
                    failedID = "focus"
                    successorID = "fill"
                } else {
                    ledger = try mutation(recoveryScope: failedScope)
                    failedID = "input"
                    successorID = "replacement"
                    try ledger.recordFailure(operationID: failedID, code: "unavailable", message: "Not dispatched", dispatch: .notDispatched)
                    try ledger.begin(operationID: successorID, tool: "set_text", targetID: "tab", recoveryKey: "set-query",
                                     baselineProperties: ["node:17:value": ""], recoveryScope: successorScope)
                    try ledger.recordDispatch(operationID: successorID, state: .dispatched)
                    try ledger.recordObservation(id: "changed", targetID: "tab", properties: ["node:17:value": "query"])
                    try ledger.verify(operationID: successorID, observationID: "changed", property: "node:17:value", expectedValue: "query")
                }
                ledger = try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn")
                if shouldRecover {
                    if mode == "focus" { try ledger.recoverUndispatchedFocus(failedOperationID: failedID, with: successorID) }
                    else { try ledger.recover(failedOperationID: failedID, with: successorID) }
                    XCTAssertNil(ledger.completionDiagnostic, "\(mode) \(scenario)")
                    XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
                    var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
                    operations[0]["recoveryScope"] = String(repeating: "c", count: 64)
                    object["operations"] = operations
                    XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"))
                } else {
                    if mode == "focus" {
                        XCTAssertThrowsError(try ledger.recoverUndispatchedFocus(failedOperationID: failedID, with: successorID))
                    } else { XCTAssertThrowsError(try ledger.recover(failedOperationID: failedID, with: successorID)) }
                    XCTAssertEqual(ledger.unresolvedOperations.map(\.id), [failedID], "\(mode) \(scenario)")
                }
            }
        }
    }

    func testRecoveryScopeRequiresBoundedHostHashAndNeverAppearsInGuidance() throws {
        for scope in ["", "PRIVATE_URL", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            var ledger = ComputerActionEvidence(turnID: "turn")
            let before = ledger
            XCTAssertThrowsError(try ledger.begin(operationID: "input", tool: "computer_v2_ax", targetID: "tab", recoveryScope: scope))
            XCTAssertEqual(ledger, before)
        }
        let scope = String(repeating: "a", count: 64)
        let ledger = try preflight(kind: .invalidArguments, key: "input", recoveryScope: scope)
        XCTAssertFalse(try ledger.checkpointText().contains(scope))
        XCTAssertFalse(try XCTUnwrap(ledger.completionDiagnostic).contains(scope))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
        var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
        operations[0]["recoveryScope"] = "PRIVATE_UNBOUNDED_SCOPE"
        object["operations"] = operations
        XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"))
    }

    func testStatusAppsAndBindingAloneCannotCorrectMissingBinding() throws {
        for tool in ["computer_v2_status", "computer_v2_apps", "computer_v2_open"] {
            var ledger = try preflight(kind: .bindingRequired, target: "native:unbound")
            try freshRead(&ledger, tool: tool)
            XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read", correction: .validatedArguments), 0)
            XCTAssertThrowsError(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
                correction: .freshBoundObservation(observationID: "observed", targetID: "tab")))
            XCTAssertNotNil(ledger.completionDiagnostic)
        }
    }

    func testPreflightFreshReadCorrectionRejectsRetainedWrongTargetAndMissingObservation() throws {
        for scenario in ["retained", "wrong-target", "missing", "predates-read"] {
            var ledger = try preflight(kind: .bindingRequired, target: "native:unbound")
            if scenario == "predates-read" {
                try ledger.recordObservation(id: "too-early", targetID: "tab", properties: [:])
            }
            try freshRead(&ledger, isLive: scenario != "retained")
            let observationID = scenario == "missing" ? "not-observed" : scenario == "predates-read" ? "too-early" : "observed"
            XCTAssertThrowsError(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
                correction: .freshBoundObservation(observationID: observationID, targetID: scenario == "wrong-target" ? "other-tab" : "tab")))
            XCTAssertNotNil(ledger.completionDiagnostic)
        }
    }

    func testStaleReferenceCorrectionRequiresFreshObservationOfSameTarget() throws {
        for target in ["tab", "other-tab"] {
            var ledger = try preflight(kind: .freshObservationRequired)
            try freshRead(&ledger, target: target)
            let count = try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
                correction: .freshBoundObservation(observationID: "observed", targetID: target))
            XCTAssertEqual(count, target == "tab" ? 1 : 0)
            XCTAssertEqual(ledger.completionDiagnostic == nil, target == "tab")
        }
    }


    func testScopedReadCorrectionRequiresCompleteLiveReadAndPreservesUndispatchedReceipt() throws {
        let scope = String(repeating: "a", count: 64)
        var ledger = try preflight(kind: .freshObservationRequired, requiredReadScope: scope)
        ledger = try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn")
        XCTAssertNotNil(ledger.completionDiagnostic)
        try freshRead(&ledger, readScope: scope, sourceComplete: true)
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
            correction: .freshBoundObservation(observationID: "observed", targetID: "tab")), 1)
        let rejected = try XCTUnwrap(ledger.operations.first)
        XCTAssertEqual(rejected.dispatch, .notDispatched)
        XCTAssertEqual(rejected.failureCode, "preflight_rejected")
        XCTAssertNil(rejected.verification)
        XCTAssertEqual(rejected.requiredReadScope, scope)
        XCTAssertEqual(rejected.preflightCorrection?.observationReadScope, scope)
        XCTAssertEqual(rejected.preflightCorrection?.observationSourceComplete, true)
        XCTAssertNil(ledger.completionDiagnostic)
        let checkpoint = try ledger.checkpointText()
        XCTAssertTrue(checkpoint.contains("preflight_corrected_not_performed"))
        XCTAssertFalse(checkpoint.contains(scope))
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testScopedReadCorrectionRejectsOtherMissingPartialAndRetainedScopes() throws {
        let scope = String(repeating: "a", count: 64)
        for scenario in ["other-scope", "missing-scope", "partial", "retained", "other-target"] {
            var ledger = try preflight(kind: .freshObservationRequired, requiredReadScope: scope)
            let target = scenario == "other-target" ? "other-tab" : "tab"
            try freshRead(&ledger, target: target, isLive: scenario != "retained",
                          readScope: scenario == "missing-scope" ? nil : scenario == "other-scope" ? String(repeating: "b", count: 64) : scope,
                          sourceComplete: scenario != "partial")
            if scenario == "retained" {
                XCTAssertThrowsError(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
                    correction: .freshBoundObservation(observationID: "observed", targetID: target)))
            } else {
                XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
                    correction: .freshBoundObservation(observationID: "observed", targetID: target)), 0, scenario)
            }
            XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["rejected"], scenario)
            XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
        }
    }

    func testScopedReadCannotBeReplacedByVerifiedSameIntentAction() throws {
        let scope = String(repeating: "a", count: 64)
        var ledger = try preflight(kind: .freshObservationRequired, key: "same-intent", requiredReadScope: scope)
        try ledger.begin(operationID: "replacement", tool: "computer_v2_ax", targetID: "tab",
                         recoveryKey: "same-intent", baselineProperties: ["node:17:value": ""])
        try ledger.recordDispatch(operationID: "replacement", state: .dispatched)
        try ledger.recordObservation(id: "changed", targetID: "tab", properties: ["node:17:value": "query"],
                                     readScope: scope, sourceComplete: true)
        try ledger.verify(operationID: "replacement", observationID: "changed", property: "node:17:value", expectedValue: "query")
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "replacement", correction: .validatedArguments), 0)
        XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["rejected"])
    }

    func testScopedCompleteReadCannotClearUnclassifiedOrUncertainFailure() throws {
        let scope = String(repeating: "a", count: 64)
        for dispatch in [ComputerActionEvidence.DispatchState.notDispatched, .unknown, .dispatched] {
            var ledger = try mutation()
            try ledger.recordFailure(operationID: "input", code: "failed", message: "Unclassified failure", dispatch: dispatch)
            try freshRead(&ledger, readScope: scope, sourceComplete: true)
            XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
                correction: .freshBoundObservation(observationID: "observed", targetID: "tab")), 0)
            XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["input"])
            XCTAssertEqual(ledger.operations.first?.dispatch, dispatch)
        }
    }

    func testScopedCorrectionCheckpointRechecksScopeAndCompletenessAfterObservationEviction() throws {
        let scope = String(repeating: "a", count: 64)
        for evict in [false, true] {
            var ledger = try preflight(kind: .freshObservationRequired, requiredReadScope: scope)
            try freshRead(&ledger, readScope: scope, sourceComplete: true)
            try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
                correction: .freshBoundObservation(observationID: "observed", targetID: "tab"))
            if evict {
                for index in 0 ..< ComputerActionEvidence.maximumObservations {
                    try ledger.recordObservation(id: "later-\(index)", targetID: "tab", properties: [:])
                }
            }
            XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
            for scenario in ["wrong-required", "invalid-required", "wrong-kind", "receipt-scope", "receipt-scope-missing", "receipt-partial", "receipt-complete-missing", "receipt-kind", "receipt-sequence"] {
                var object = original
                var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
                if scenario == "wrong-required" { operations[0]["requiredReadScope"] = String(repeating: "b", count: 64) }
                else if scenario == "invalid-required" { operations[0]["requiredReadScope"] = "PRIVATE_SCOPE" }
                else if scenario == "wrong-kind" { operations[0]["preflightRejection"] = "invalidArguments" }
                else {
                    var receipt = try XCTUnwrap(operations[0]["preflightCorrection"] as? [String: Any])
                    if scenario == "receipt-scope" { receipt["observationReadScope"] = String(repeating: "b", count: 64) }
                    if scenario == "receipt-scope-missing" { receipt.removeValue(forKey: "observationReadScope") }
                    if scenario == "receipt-partial" { receipt["observationSourceComplete"] = false }
                    if scenario == "receipt-complete-missing" { receipt.removeValue(forKey: "observationSourceComplete") }
                    if scenario == "receipt-kind" { receipt["kind"] = "validatedArguments" }
                    if scenario == "receipt-sequence" { receipt["observationSequence"] = 99999 }
                    operations[0]["preflightCorrection"] = receipt
                }
                object["operations"] = operations
                XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"), "\(scenario), evicted=\(evict)")
            }
            if !evict {
                for scenario in ["scope", "partial", "retained", "missing"] {
                    var object = original
                    var observations = try XCTUnwrap(object["observations"] as? [[String: Any]])
                    if scenario == "scope" { observations[0]["readScope"] = String(repeating: "b", count: 64) }
                    if scenario == "partial" { observations[0]["sourceComplete"] = false }
                    if scenario == "retained" { observations[0]["isLive"] = false }
                    object["observations"] = scenario == "missing" ? [] : observations
                    XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"), scenario)
                }
            }
        }
    }

    func testReadScopeRequiresHostHashAndFreshObservationRejection() throws {
        for scope in ["", "PRIVATE_SCOPE", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(try preflight(kind: .freshObservationRequired, requiredReadScope: scope))
            var ledger = ComputerActionEvidence(turnID: "turn")
            let before = ledger
            XCTAssertThrowsError(try ledger.recordObservation(id: "read", targetID: "tab", properties: [:], readScope: scope, sourceComplete: true))
            XCTAssertEqual(ledger, before)
        }
        for kind in [ComputerActionEvidence.PreflightRejection.invalidArguments, .bindingRequired, .pendingAction] {
            XCTAssertThrowsError(try preflight(kind: kind, requiredReadScope: String(repeating: "a", count: 64)))
        }
    }

    func testUnknownAndDispatchedEffectsCannotBeReclassifiedOrClearedByPreflightRecovery() throws {
        for dispatch in [ComputerActionEvidence.DispatchState.dispatched, .unknown] {
            var ledger = try mutation()
            try ledger.recordFailure(operationID: "input", code: "delivery_failed", message: "Effect uncertain", dispatch: dispatch)
            let before = ledger
            XCTAssertThrowsError(try ledger.recordPreflightRejection(operationID: "input", kind: .bindingRequired,
                code: "preflight_rejected", message: "Not allowed to rewrite an uncertain effect"))
            XCTAssertEqual(ledger, before)
            try freshRead(&ledger)
            XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
                correction: .freshBoundObservation(observationID: "observed", targetID: "tab")), 0)
            XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["input"])
            XCTAssertEqual(ledger.operations.first?.dispatch, dispatch)
            XCTAssertNotNil(ledger.completionDiagnostic)
        }
    }

    func testStaleReferenceCanRecoverThroughVerifiedExactReplacementUsingAlreadyCurrentSnapshot() throws {
        for key in ["same-intent", "other-intent"] {
            var ledger = try preflight(kind: .freshObservationRequired, key: "same-intent")
            try ledger.begin(operationID: "replacement", tool: "computer_v2_ax", targetID: "tab",
                             recoveryKey: key, baselineProperties: ["node:17:value": ""])
            try ledger.recordDispatch(operationID: "replacement", state: .dispatched)
            try ledger.recordObservation(id: "changed", targetID: "tab", properties: ["node:17:value": "query"])
            try ledger.verify(operationID: "replacement", observationID: "changed", property: "node:17:value", expectedValue: "query")
            let count = try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "replacement", correction: .validatedArguments)
            XCTAssertEqual(count, key == "same-intent" ? 1 : 0)
            XCTAssertEqual(ledger.completionDiagnostic == nil, key == "same-intent")
            XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
        }
    }

    func testUnclassifiedUndispatchedFailureRemainsConservative() throws {
        var ledger = try mutation()
        try ledger.recordFailure(operationID: "input", code: "failed", message: "Not classified at a trusted preflight boundary", dispatch: .notDispatched)
        try freshRead(&ledger)
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
            correction: .freshBoundObservation(observationID: "observed", targetID: "tab")), 0)
        XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["input"])
    }

    func testCorrectedPreflightDoesNotEraseAnIndependentOriginalUncertainFailure() throws {
        var ledger = try preflight(kind: .bindingRequired, target: "native:unbound")
        try ledger.begin(operationID: "uncertain", tool: "computer_v2_ax", targetID: "tab", recoveryKey: "press")
        try ledger.recordFailure(operationID: "uncertain", code: "original_delivery_timeout", message: "Original dispatch uncertainty", dispatch: .unknown)
        try freshRead(&ledger)
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
            correction: .freshBoundObservation(observationID: "observed", targetID: "tab")), 1)
        XCTAssertEqual(ledger.unresolvedOperations.map(\.id), ["uncertain"])
        XCTAssertEqual(ledger.unresolvedOperations.first?.failureCode, "original_delivery_timeout")
        XCTAssertEqual(ledger.unresolvedOperations.first?.failureMessage, "Original dispatch uncertainty")
        XCTAssertNotNil(ledger.completionDiagnostic)
    }

    func testRejectedReceiptCannotLaterBecomeDispatchedOrUseOrdinaryRecovery() throws {
        var ledger = try preflight(kind: .invalidArguments, tool: "computer_v2_snapshot", key: "read", requiresVerification: false)
        XCTAssertThrowsError(try ledger.recordDispatch(operationID: "rejected", state: .dispatched))
        XCTAssertThrowsError(try ledger.recordFailure(operationID: "rejected", code: "changed", message: "Changed", dispatch: .unknown))
        try freshRead(&ledger, key: "read")
        XCTAssertThrowsError(try ledger.recover(failedOperationID: "rejected", with: "read"))
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read", correction: .validatedArguments), 1)
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read", correction: .validatedArguments), 0)
        XCTAssertEqual(ledger.operations.first?.dispatch, .notDispatched)
    }

    func testPreflightRejectionWithoutCorrectionSurvivesCompactionAsUnresolved() throws {
        let ledger = try preflight(kind: .bindingRequired, target: "native:unbound")
        let restored = try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn")
        XCTAssertNotNil(restored.completionDiagnostic)
        XCTAssertEqual(restored.unresolvedOperations.map(\.id), ["rejected"])
        XCTAssertTrue(try restored.checkpointText().contains("preflight_rejection=bindingRequired"))
    }

    func testCorrectedPreflightReceiptRemainsValidAfterObservationCacheEviction() throws {
        var ledger = try preflight(kind: .bindingRequired, target: "native:unbound")
        try freshRead(&ledger)
        try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
            correction: .freshBoundObservation(observationID: "observed", targetID: "tab"))
        for index in 0 ... ComputerActionEvidence.maximumObservations {
            try ledger.recordObservation(id: "later-\(index)", targetID: "tab", properties: [:])
        }
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
        XCTAssertNil(ledger.completionDiagnostic)
    }

    func testRestoredPreflightCorrectionRejectsForgedDispatchOrObservationFacts() throws {
        var ledger = try preflight(kind: .bindingRequired, target: "native:unbound")
        try freshRead(&ledger)
        try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
            correction: .freshBoundObservation(observationID: "observed", targetID: "tab"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
        for scenario in ["dispatch", "missing-kind", "successor", "target", "sequence"] {
            var object = original
            var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
            if scenario == "dispatch" { operations[0]["dispatch"] = "unknown" }
            else if scenario == "missing-kind" { operations[0].removeValue(forKey: "preflightRejection") }
            else {
                var receipt = try XCTUnwrap(operations[0]["preflightCorrection"] as? [String: Any])
                if scenario == "successor" { receipt["successorOperationID"] = "rejected" }
                if scenario == "target" { receipt["observationTargetID"] = "other-tab" }
                if scenario == "sequence" { receipt["observationSequence"] = 0 }
                operations[0]["preflightCorrection"] = receipt
            }
            object["operations"] = operations
            XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"))
        }
    }

    func testUndispatchedSnapshotCanAdoptItsRuntimeRestoredTargetBeforeSuccess() throws {
        var ledger = try preflight(kind: .bindingRequired, target: "native:unbound")
        try ledger.begin(operationID: "read", tool: "computer_v2_snapshot", targetID: "native:unbound", requiresVerification: false)
        try ledger.retargetUndispatchedRead(operationID: "read", targetID: "tab")
        try ledger.recordDispatch(operationID: "read", state: .dispatched)
        try ledger.recordObservation(id: "observed", targetID: "tab", properties: [:])
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
            correction: .freshBoundObservation(observationID: "observed", targetID: "tab")), 1)
        XCTAssertEqual(ledger.operations.first?.targetID, "native:unbound", "The rejected AX receipt must not be retargeted.")
        XCTAssertEqual(ledger.operations.last?.targetID, "tab")
        XCTAssertNil(ledger.completionDiagnostic)
    }

    func testRetargetCannotRewriteMutationFailureOrDeliveredRead() throws {
        for scenario in ["mutation", "failed", "dispatched", "unknown"] {
            var ledger = ComputerActionEvidence(turnID: "turn")
            try ledger.begin(operationID: "request", tool: scenario == "mutation" ? "computer_v2_ax" : "computer_v2_snapshot",
                             targetID: "old", requiresVerification: scenario == "mutation")
            if scenario == "failed" {
                try ledger.recordFailure(operationID: "request", code: "failed", message: "Read failed", dispatch: .notDispatched)
            } else if scenario == "dispatched" || scenario == "unknown" {
                try ledger.recordDispatch(operationID: "request", state: scenario == "dispatched" ? .dispatched : .unknown)
            }
            let before = ledger
            XCTAssertThrowsError(try ledger.retargetUndispatchedRead(operationID: "request", targetID: "new"))
            XCTAssertEqual(ledger, before)
        }
    }

    func testArmedPlanSurvivesCheckpointAndRuntimeVerifiesWithoutModelVerifyCall() throws {
        let fixture = try plannedMutation()
        var ledger = try ComputerActionEvidence.restore(fixture.ledger.checkpointData(), turnID: "turn")
        try ledger.recordDispatch(operationID: "planned", state: .dispatched)
        XCTAssertNotNil(ledger.completionDiagnostic, "Dispatch alone remains insufficient.")
        XCTAssertEqual(try ledger.beginPlannedVerificationAttempt(operationID: "planned"), 1)
        let after = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        let receipt = try ledger.verifyNativePlanned(operationID: "planned", observationID: after.snapshot.id.uuidString,
                                               scope: fixture.scope, observation: after)
        XCTAssertEqual(receipt.property, fixture.plan.property)
        XCTAssertEqual(receipt.expectedValue, "query")
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(ledger.operations.count, 1, "Verification does not execute a second action.")
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.outcome, .verified)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
        XCTAssertTrue(try ledger.checkpointText().contains("does not verify arbitrary task claims"))
    }

    func testArmOnlyBeforeMutationDispatchAndCannotReplacePlan() throws {
        let fixture = try plannedMutation()
        var armed = fixture.ledger
        XCTAssertThrowsError(try armed.armNativeVerification(operationID: "planned", plan: fixture.plan))
        for scenario in ["read", "not-required", "wrong-target", "dispatched", "unknown", "failed"] {
            var ledger = ComputerActionEvidence(turnID: "turn")
            try ledger.begin(operationID: "action", tool: scenario == "read" ? "computer_v2_snapshot" : "computer_v2_set_text",
                             targetID: scenario == "wrong-target" ? "other-target" : fixture.target,
                             requiresVerification: scenario != "not-required")
            if scenario == "dispatched" || scenario == "unknown" {
                try ledger.recordDispatch(operationID: "action", state: scenario == "unknown" ? .unknown : .dispatched)
            } else if scenario == "failed" {
                try ledger.recordFailure(operationID: "action", code: "rejected", message: "Rejected", dispatch: .notDispatched)
            }
            let before = ledger
            XCTAssertThrowsError(try ledger.armNativeVerification(operationID: "action", plan: fixture.plan), scenario)
            XCTAssertEqual(ledger, before, scenario)
        }
    }

    func testLegacyVerifyCannotOverrideAnyArmedPostcondition() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordDispatch(operationID: "planned", state: .dispatched)
        let after = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: fixture.target,
                                     properties: ["node:17:value": "query", "document_url": "https://example.test/elsewhere"])
        for property in [fixture.plan.property, "document_url"] {
            XCTAssertThrowsError(try ledger.verify(operationID: "planned", observationID: after.snapshot.id.uuidString,
                                                   property: property, expectedValue: "query")) {
                XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .plannedVerificationRequired)
            }
        }
        XCTAssertNil(ledger.operations[0].verification)
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.attempts, 0)
    }

    func testReadOnlyAttemptBudgetSurvivesCompactionAndNeverReplaysUnknownDelivery() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordFailure(operationID: "planned", code: "reply_lost", message: "Dispatch may have happened", dispatch: .unknown)
        for attempt in 1 ... ComputerActionEvidence.maximumPlannedVerificationAttempts {
            XCTAssertEqual(try ledger.beginPlannedVerificationAttempt(operationID: "planned"), attempt)
            try ledger.recordPlannedVerificationReadFailure(operationID: "planned")
            ledger = try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn")
            XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.outcome, .observationUnavailable)
        }
        XCTAssertThrowsError(try ledger.beginPlannedVerificationAttempt(operationID: "planned")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .verificationAttemptsExhausted)
        }
        XCTAssertEqual(ledger.operations.count, 1)
        XCTAssertEqual(ledger.operations[0].dispatch, .unknown)
        XCTAssertEqual(ledger.operations[0].failureCode, "reply_lost")
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.remainingAttempts, 0)
        XCTAssertNotNil(ledger.completionDiagnostic)
        XCTAssertTrue(try ledger.checkpointText().contains("verification_reads=3/3"))
    }

    func testMismatchRemainsPendingThenBoundedFreshReadCanVerify() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordDispatch(operationID: "planned", state: .dispatched)
        try ledger.beginPlannedVerificationAttempt(operationID: "planned")
        let unchanged = plannedObservation(scope: fixture.scope, value: "")
        try ledger.recordObservation(id: unchanged.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        XCTAssertThrowsError(try ledger.verifyNativePlanned(operationID: "planned", observationID: unchanged.snapshot.id.uuidString,
                                                      scope: fixture.scope, observation: unchanged))
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.outcome, .postconditionMismatch)
        XCTAssertNotNil(ledger.completionDiagnostic)
        ledger = try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn")
        try ledger.beginPlannedVerificationAttempt(operationID: "planned")
        let changed = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: changed.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        try ledger.verifyNativePlanned(operationID: "planned", observationID: changed.snapshot.id.uuidString,
                                 scope: fixture.scope, observation: changed)
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.attempts, 2)
        XCTAssertNil(ledger.completionDiagnostic)
    }

    func testPlannedVerificationRequiresReadAfterAttemptBoundaryAndSingleInFlightRead() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordDispatch(operationID: "planned", state: .dispatched)
        let old = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: old.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        try ledger.beginPlannedVerificationAttempt(operationID: "planned")
        XCTAssertThrowsError(try ledger.beginPlannedVerificationAttempt(operationID: "planned")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .invalidTransition)
        }
        XCTAssertThrowsError(try ledger.verifyNativePlanned(operationID: "planned", observationID: old.snapshot.id.uuidString,
                                                      scope: fixture.scope, observation: old)) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .staleObservation)
        }
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.attempts, 1)
        XCTAssertNil(ledger.operations[0].verification)
    }

    func testPlannedVerificationRejectsWrongTargetRetainedPageAndMismatchedSnapshotID() throws {
        for scenario in ["target", "retained", "snapshot-id"] {
            let fixture = try plannedMutation()
            var ledger = fixture.ledger
            try ledger.recordDispatch(operationID: "planned", state: .dispatched)
            try ledger.beginPlannedVerificationAttempt(operationID: "planned")
            let after = plannedObservation(scope: fixture.scope, value: "query", isLive: scenario != "retained")
            let observationID = scenario == "snapshot-id" ? UUID().uuidString : after.snapshot.id.uuidString
            try ledger.recordObservation(id: observationID,
                targetID: scenario == "target" ? "another-tab" : fixture.target,
                properties: [:], isLive: scenario != "retained")
            XCTAssertThrowsError(try ledger.verifyNativePlanned(operationID: "planned", observationID: observationID,
                                                          scope: fixture.scope, observation: after), scenario)
            XCTAssertNil(ledger.operations[0].verification, scenario)
            XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.outcome, .postconditionMismatch, scenario)
        }
    }

    func testPlanBaselineReservedSeparatelyFromProgressivePropertyCap() throws {
        let scope = plannedScope()
        let target = scope.evidenceTargetID
        let before = plannedObservation(scope: scope, value: "")
        let plan = try XCTUnwrap(NativeActionVerification.compile(action: .setText("query"), elementIndex: 1,
                                                                  observation: before, scope: scope))
        var properties = Dictionary(uniqueKeysWithValues: (0 ..< 140).map { (String(format: "a%03d", $0), "noise") })
        properties["node:17:value"] = ""
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.recordObservation(id: before.snapshot.id.uuidString, targetID: target, properties: properties)
        try ledger.begin(operationID: "planned", tool: "computer_v2_set_text", targetID: target)
        XCTAssertNil(ledger.operations[0].baselineProperties?["node:17:value"])
        try ledger.armNativeVerification(operationID: "planned", plan: plan)
        try ledger.recordDispatch(operationID: "planned", state: .dispatched)
        try ledger.beginPlannedVerificationAttempt(operationID: "planned")
        let after = plannedObservation(scope: scope, value: "query")
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: target, properties: properties)
        try ledger.verifyNativePlanned(operationID: "planned", observationID: after.snapshot.id.uuidString, scope: scope, observation: after)
        XCTAssertNil(ledger.completionDiagnostic, "The reserved plan verifies the actual runtime snapshot, not an absent general-cache property.")
    }

    func testUnresolvedPlanBlocksNextMutationEvenForDistinctIntentAfterObservation() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordDispatch(operationID: "planned", state: .dispatched)
        let after = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        XCTAssertTrue(ledger.blocksFurtherInput(operationID: "planned", nextRecoveryKey: "unrelated-click", nextTargetID: fixture.target))
        XCTAssertNotNil(ledger.completionDiagnostic)
    }

    func testPlannedClearingOfNonemptyValueHasValidCheckpointButLegacyEmptyProofRemainsForbidden() throws {
        let scope = plannedScope()
        let before = plannedObservation(scope: scope, value: "old value")
        let plan = try XCTUnwrap(NativeActionVerification.compile(action: .setText(""), elementIndex: 1,
                                                                  observation: before, scope: scope))
        let target = plan.scope.evidenceTargetID
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.begin(operationID: "clear", tool: "computer_v2_set_text", targetID: target)
        try ledger.armNativeVerification(operationID: "clear", plan: plan)
        try ledger.recordDispatch(operationID: "clear", state: .dispatched)
        try ledger.beginPlannedVerificationAttempt(operationID: "clear")
        let after = plannedObservation(scope: scope, value: "")
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: target, properties: [:])
        try ledger.verifyNativePlanned(operationID: "clear", observationID: after.snapshot.id.uuidString, scope: scope, observation: after)
        XCTAssertEqual(ledger.operations[0].verification?.expectedValue, "")
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
        var legacy = try mutation()
        try legacy.recordDispatch(operationID: "input", state: .dispatched)
        try legacy.recordObservation(id: "after", targetID: "tab", properties: ["node:17:value": ""])
        XCTAssertThrowsError(try legacy.verify(operationID: "input", observationID: "after", property: "node:17:value", expectedValue: ""))
    }

    func testUnknownDeliveryCanSatisfyArmedPlanByReadOnlyObservation() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordFailure(operationID: "planned", code: "reply_lost", message: "Delivery unknown", dispatch: .unknown)
        try ledger.beginPlannedVerificationAttempt(operationID: "planned")
        let after = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        try ledger.verifyNativePlanned(operationID: "planned", observationID: after.snapshot.id.uuidString,
                                 scope: fixture.scope, observation: after)
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(ledger.operations.count, 1)
        XCTAssertEqual(ledger.operations[0].dispatch, .unknown)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testPlannedRecoveryCannotSubstituteLegacyVerifiedDifferentOutcome() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordFailure(operationID: "planned", code: "reply_lost", message: "Delivery unknown", dispatch: .unknown)
        try ledger.begin(operationID: "different", tool: "computer_v2_set_text", targetID: fixture.target,
                         recoveryKey: "set-query", baselineProperties: ["node:17:value": ""])
        try ledger.recordDispatch(operationID: "different", state: .dispatched)
        try ledger.recordObservation(id: "changed", targetID: fixture.target, properties: ["node:17:value": "different"])
        try ledger.verify(operationID: "different", observationID: "changed", property: "node:17:value", expectedValue: "different")
        XCTAssertThrowsError(try ledger.recover(failedOperationID: "planned", with: "different")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .invalidRecovery)
        }
        XCTAssertNil(ledger.operations[0].recoveredBy)
    }

    func testRestoredPlanRejectsForgedBudgetScopeOrReceipt() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordDispatch(operationID: "planned", state: .dispatched)
        try ledger.beginPlannedVerificationAttempt(operationID: "planned")
        let after = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        try ledger.verifyNativePlanned(operationID: "planned", observationID: after.snapshot.id.uuidString,
                                 scope: fixture.scope, observation: after)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
        for scenario in ["budget", "negative-budget", "scope", "plan-missing", "progress-missing", "receipt", "sequence", "state"] {
            var object = original
            var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
            if scenario == "scope" { operations[0]["targetID"] = "another-tab" }
            else if scenario == "plan-missing" { operations[0].removeValue(forKey: "nativeVerificationPlan") }
            else if scenario == "progress-missing" { operations[0].removeValue(forKey: "plannedVerificationProgress") }
            else if scenario == "receipt" {
                var receipt = try XCTUnwrap(operations[0]["verification"] as? [String: Any])
                receipt["expectedValue"] = "different"
                operations[0]["verification"] = receipt
            } else {
                var progress = try XCTUnwrap(operations[0]["plannedVerificationProgress"] as? [String: Any])
                if scenario == "budget" { progress["attempts"] = 4 }
                if scenario == "negative-budget" { progress["attempts"] = -1 }
                if scenario == "sequence" { progress["attemptAfterSequence"] = 0 }
                if scenario == "state" { progress["outcome"] = "pending" }
                operations[0]["plannedVerificationProgress"] = progress
            }
            object["operations"] = operations
            XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"), scenario)
        }
    }

    func testBlockedInputLinksOriginalProofWithoutPretendingRejectedInputRan() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordDispatch(operationID: "planned", state: .unknown)
        try ledger.begin(operationID: "blocked", tool: "computer_v2_ax", targetID: fixture.target)
        try ledger.recordPendingActionRejection(operationID: "blocked", pendingOperationID: "planned")
        ledger = try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn")
        XCTAssertEqual(ledger.unresolvedOperations.count, 2)
        try ledger.beginPlannedVerificationAttempt(operationID: "planned")
        let after = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        try ledger.verifyNativePlanned(operationID: "planned", observationID: after.snapshot.id.uuidString,
                                 scope: fixture.scope, observation: after)
        let rejected = ledger.operations[1]
        XCTAssertEqual(rejected.pendingActionRejection?.resolution, .verified)
        XCTAssertEqual(rejected.pendingActionRejection?.resolutionObservationID, after.snapshot.id.uuidString)
        XCTAssertEqual(rejected.dispatch, .notDispatched)
        XCTAssertEqual(rejected.preflightRejection, .pendingAction)
        XCTAssertEqual(rejected.failureCode, "pending_action_rejected")
        XCTAssertNil(rejected.verification)
        XCTAssertNil(rejected.recoveredBy)
        XCTAssertTrue(rejected.isResolved)
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
        XCTAssertTrue(try ledger.checkpointText().contains("pending_action_resolved_not_performed"))
    }

    func testLinkedRetryDiagnosticsCountOriginalOnceAndReportBlockedInputsSeparately() throws {
        let fixture = try plannedMutation()
        var ledger = fixture.ledger
        try ledger.recordDispatch(operationID: "planned", state: .dispatched)
        for id in ["blocked-one", "blocked-two"] {
            try ledger.begin(operationID: id, tool: "computer_v2_ax", targetID: fixture.target)
            try ledger.recordPendingActionRejection(operationID: id, pendingOperationID: "planned")
        }
        XCTAssertEqual(ledger.unresolvedOperations.count, 3, "All requests remain in audit evidence.")
        XCTAssertEqual(ledger.unresolvedOutcomeOperations.map(\.id), ["planned"])
        XCTAssertEqual(ledger.unresolvedBlockedInputCount, 2)
        let diagnostic = try XCTUnwrap(ledger.completionDiagnostic)
        XCTAssertTrue(diagnostic.contains("1 operation(s) remain unresolved"))
        XCTAssertTrue(diagnostic.contains("2 subsequent input request(s) were blocked before dispatch"))
        XCTAssertFalse(diagnostic.contains("failed operation(s)"), "A pre-input block is not a failed dispatched effect.")
        let checkpoint = try ledger.checkpointText()
        for id in ["planned", "blocked-one", "blocked-two"] {
            XCTAssertEqual(checkpoint.split(separator: "\n").filter { $0.hasPrefix("operation=\(id) ") }.count, 1,
                           "A blocked retry must not be repeated as an independent unresolved-effect line.")
        }
        XCTAssertEqual(checkpoint.components(separatedBy: "status=blocked_by_pending_action").count - 1, 2)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn").completionDiagnostic, diagnostic)
        try ledger.beginPlannedVerificationAttempt(operationID: "planned")
        let fresh = plannedObservation(scope: fixture.scope, value: "query")
        try ledger.recordObservation(id: fresh.snapshot.id.uuidString, targetID: fixture.target, properties: [:])
        try ledger.verifyNativePlanned(operationID: "planned", observationID: fresh.snapshot.id.uuidString, scope: fixture.scope, observation: fresh)
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertTrue(ledger.unresolvedOutcomeOperations.isEmpty)
        XCTAssertEqual(ledger.unresolvedBlockedInputCount, 0)
        XCTAssertEqual(try ledger.checkpointText().components(separatedBy: "status=pending_action_resolved_not_performed").count - 1, 2)
    }

    func testLinkedRetrySummaryDoesNotHideIndependentPreflightFailure() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .unknown)
        try ledger.begin(operationID: "blocked", tool: "computer_v2_ax", targetID: "tab")
        try ledger.recordPendingActionRejection(operationID: "blocked", pendingOperationID: "input")
        try ledger.begin(operationID: "bad-read", tool: "computer_v2_snapshot", targetID: "tab", requiresVerification: false)
        try ledger.recordPreflightRejection(operationID: "bad-read", kind: .invalidArguments,
            code: "invalid_cursor", message: "Invalid cursor combination")
        let diagnostic = try XCTUnwrap(ledger.completionDiagnostic)
        XCTAssertTrue(diagnostic.contains("2 operation(s) remain unresolved"))
        XCTAssertTrue(diagnostic.contains("including 1 failed operation(s)"))
        XCTAssertTrue(diagnostic.contains("1 subsequent input request(s) were blocked before dispatch"))
        XCTAssertEqual(ledger.unresolvedOutcomeOperations.map(\.id), ["input", "bad-read"])
        try ledger.recordObservation(id: "changed", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.verify(operationID: "input", observationID: "changed", property: "node:17:value", expectedValue: "query")
        XCTAssertEqual(ledger.unresolvedOutcomeOperations.map(\.id), ["bad-read"])
        XCTAssertEqual(ledger.unresolvedBlockedInputCount, 0)
        XCTAssertTrue(try XCTUnwrap(ledger.completionDiagnostic).contains("including 1 failed operation(s)"))
    }

    func testPendingActionRejectionCannotBeDispatchedOrClearedByUnrelatedRead() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.begin(operationID: "blocked", tool: "computer_v2_ax", targetID: "tab")
        try ledger.recordPendingActionRejection(operationID: "blocked", pendingOperationID: "input")
        XCTAssertThrowsError(try ledger.recordDispatch(operationID: "blocked", state: .dispatched))
        XCTAssertThrowsError(try ledger.recordFailure(operationID: "blocked", code: "other", message: "Cannot reclassify"))
        try freshRead(&ledger)
        XCTAssertEqual(try ledger.recoverPreflightRejections(afterSuccessfulOperationID: "read",
            correction: .freshBoundObservation(observationID: "observed", targetID: "tab")), 0)
        XCTAssertNil(ledger.operations[1].pendingActionRejection?.resolution)
        XCTAssertNotNil(ledger.completionDiagnostic)
        try ledger.recordObservation(id: "verified", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.verify(operationID: "input", observationID: "verified", property: "node:17:value", expectedValue: "query")
        XCTAssertTrue(ledger.operations[1].isResolved)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testPendingActionLinkRejectsCyclesTargetsAndEffectfulRequests() throws {
        for scenario in ["self", "future", "target", "dispatched", "unknown", "effect", "failed", "read", "chain"] {
            var ledger = try mutation()
            try ledger.recordDispatch(operationID: "input", state: .dispatched)
            try ledger.begin(operationID: "blocked", tool: "computer_v2_ax",
                             targetID: scenario == "target" ? "other-tab" : "tab", requiresVerification: scenario != "read")
            if scenario == "dispatched" || scenario == "unknown" {
                try ledger.recordDispatch(operationID: "blocked", state: scenario == "unknown" ? .unknown : .dispatched)
            } else if scenario == "effect" {
                try ledger.recordForegroundEffect(operationID: "blocked", effect: .activationRequested)
            } else if scenario == "failed" {
                try ledger.recordFailure(operationID: "blocked", code: "failed", message: "Unknown delivery", dispatch: .notDispatched)
            }
            if scenario == "future" { try ledger.begin(operationID: "future", tool: "computer_v2_ax", targetID: "tab") }
            if scenario == "chain" {
                try ledger.recordPendingActionRejection(operationID: "blocked", pendingOperationID: "input")
                try ledger.begin(operationID: "chained", tool: "computer_v2_ax", targetID: "tab")
            }
            let original = scenario == "self" || scenario == "chain" ? "blocked" : scenario == "future" ? "future" : "input"
            let rejected = scenario == "chain" ? "chained" : "blocked"
            let before = ledger
            XCTAssertThrowsError(try ledger.recordPendingActionRejection(operationID: rejected, pendingOperationID: original), scenario)
            XCTAssertEqual(ledger, before, scenario)
        }
        var ledger = try mutation()
        XCTAssertThrowsError(try ledger.recordPreflightRejection(operationID: "input", kind: .pendingAction,
            code: "pending_action_rejected", message: "No original reference"))
    }

    func testPendingLinkCheckpointRejectsForgedResolutionCycleAndEffectElision() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.begin(operationID: "blocked", tool: "computer_v2_ax", targetID: "tab")
        try ledger.recordPendingActionRejection(operationID: "blocked", pendingOperationID: "input")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
        for scenario in ["cycle", "missing-original", "target", "dispatched", "foreground", "resolved", "missing-link", "wrong-kind", "sequence", "failure"] {
            var object = original
            var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
            if scenario == "target" { operations[1]["targetID"] = "other-tab" }
            else if scenario == "dispatched" { operations[1]["dispatch"] = "dispatched" }
            else if scenario == "foreground" { operations[1]["foregroundEffect"] = "activation_requested" }
            else if scenario == "missing-link" { operations[1].removeValue(forKey: "pendingActionRejection") }
            else if scenario == "wrong-kind" { operations[1]["preflightRejection"] = "invalidArguments" }
            else if scenario == "failure" { operations[1]["failureCode"] = "some_other_failure" }
            else {
                var receipt = try XCTUnwrap(operations[1]["pendingActionRejection"] as? [String: Any])
                if scenario == "cycle" { receipt["pendingOperationID"] = "blocked" }
                if scenario == "missing-original" { receipt["pendingOperationID"] = "missing" }
                if scenario == "sequence" { receipt["rejectionSequence"] = 0 }
                if scenario == "resolved" { receipt["resolution"] = "verified"; receipt["resolutionObservationID"] = "fake" }
                operations[1]["pendingActionRejection"] = receipt
            }
            object["operations"] = operations
            XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"), scenario)
        }
    }

    func testPruningPreservesOriginalUntilItsPendingLinkIsRemoved() throws {
        var ledger = try mutation()
        try ledger.recordDispatch(operationID: "input", state: .dispatched)
        try ledger.begin(operationID: "blocked", tool: "computer_v2_ax", targetID: "tab")
        try ledger.recordPendingActionRejection(operationID: "blocked", pendingOperationID: "input")
        try ledger.recordObservation(id: "verified", targetID: "tab", properties: ["node:17:value": "query"])
        try ledger.verify(operationID: "input", observationID: "verified", property: "node:17:value", expectedValue: "query")
        for index in 0 ..< 70 {
            try ledger.begin(operationID: "read-\(index)", tool: "computer_v2_snapshot", targetID: "tab", requiresVerification: false)
            try ledger.recordDispatch(operationID: "read-\(index)", state: .dispatched)
            XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
        }
        XCTAssertNil(ledger.completionDiagnostic)
    }

    func testNativeSelectionPlanVerifiesFreshStateWithoutModelFollowupAndSurvivesCheckpoint() throws {
        let fixture = try nativePlannedMutation(selected: false)
        var ledger = try ComputerActionEvidence.restore(fixture.ledger.checkpointData(), turnID: "turn")
        try ledger.recordDispatch(operationID: "native", state: .dispatched)
        try ledger.beginPlannedVerificationAttempt(operationID: "native")
        let after = nativePlannedObservation(token: fixture.token, selected: true)
        try ledger.recordObservation(id: after.snapshot.id.uuidString, targetID: fixture.scope.evidenceTargetID, properties: [:])
        XCTAssertThrowsError(try ledger.verify(operationID: "native", observationID: after.snapshot.id.uuidString,
                                               property: fixture.plan.property, expectedValue: "true")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .plannedVerificationRequired)
        }
        let proof = try ledger.verifyNativePlanned(operationID: "native", observationID: after.snapshot.id.uuidString,
                                                  scope: fixture.scope, observation: after)
        XCTAssertEqual(proof.expectedValue, "true")
        XCTAssertNil(ledger.operations[0].alreadySatisfied)
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.attempts, 1)
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testAlreadySelectedUsesFreshNoOpReceiptNeverDispatchedChangedOutcome() throws {
        let fixture = try nativePlannedMutation(selected: true)
        var ledger = fixture.ledger
        XCTAssertThrowsError(try ledger.recordDispatch(operationID: "native", state: .unknown))
        XCTAssertThrowsError(try ledger.recordNativeAlreadySatisfied(operationID: "native", scope: fixture.scope,
                                                                     observation: fixture.before))
        let fresh = nativePlannedObservation(token: fixture.token, selected: true)
        try ledger.recordObservation(id: fresh.snapshot.id.uuidString, targetID: fixture.scope.evidenceTargetID, properties: [:])
        let receipt = try ledger.recordNativeAlreadySatisfied(operationID: "native", scope: fixture.scope, observation: fresh)
        XCTAssertEqual(receipt.expectedValue, "true")
        XCTAssertEqual(ledger.operations[0].dispatch, .notDispatched)
        XCTAssertNil(ledger.operations[0].verification)
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.outcome, .alreadySatisfied)
        XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.attempts, 0)
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
        XCTAssertTrue(try ledger.checkpointText().contains("already_satisfied_not_performed"))
        XCTAssertThrowsError(try ledger.recordDispatch(operationID: "native", state: .dispatched))
    }

    func testAlreadySelectedChangingBeforeFreshReadDoesNotSkipActionWithFalseProof() throws {
        let fixture = try nativePlannedMutation(selected: true)
        var ledger = fixture.ledger
        let changed = nativePlannedObservation(token: fixture.token, selected: false)
        try ledger.recordObservation(id: changed.snapshot.id.uuidString, targetID: fixture.scope.evidenceTargetID, properties: [:])
        XCTAssertThrowsError(try ledger.recordNativeAlreadySatisfied(operationID: "native", scope: fixture.scope, observation: changed))
        XCTAssertNil(ledger.operations[0].alreadySatisfied)
        XCTAssertEqual(ledger.operations[0].dispatch, .notDispatched)
        XCTAssertNotNil(ledger.completionDiagnostic)
    }

    func testNoOpRejectsSupersededMatchingObservationAndWrongScope() throws {
        let fixture = try nativePlannedMutation(selected: true)
        var ledger = fixture.ledger
        let matching = nativePlannedObservation(token: fixture.token, selected: true)
        try ledger.recordObservation(id: matching.snapshot.id.uuidString, targetID: fixture.scope.evidenceTargetID, properties: [:])
        let otherScope = NativeActionVerification.Scope(evidenceTargetID: "native:other", processIdentifier: 123, bundleIdentifier: "test.fixture")
        XCTAssertThrowsError(try ledger.recordNativeAlreadySatisfied(operationID: "native", scope: otherScope, observation: matching))
        let later = nativePlannedObservation(token: fixture.token, selected: false)
        try ledger.recordObservation(id: later.snapshot.id.uuidString, targetID: fixture.scope.evidenceTargetID, properties: [:])
        XCTAssertThrowsError(try ledger.recordNativeAlreadySatisfied(operationID: "native", scope: fixture.scope, observation: matching)) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .staleObservation)
        }
        XCTAssertNil(ledger.operations[0].alreadySatisfied)
    }

    func testNativeReadBudgetPersistsUnknownEffectsAcrossCompaction() throws {
        let fixture = try nativePlannedMutation(selected: false)
        var ledger = fixture.ledger
        try ledger.recordFailure(operationID: "native", code: "ack_lost", message: "Delivery uncertain", dispatch: .unknown)
        for attempt in 1 ... 3 {
            XCTAssertEqual(try ledger.beginPlannedVerificationAttempt(operationID: "native"), attempt)
            if attempt == 2 {
                let unchanged = nativePlannedObservation(token: fixture.token, selected: false)
                try ledger.recordObservation(id: unchanged.snapshot.id.uuidString, targetID: fixture.scope.evidenceTargetID, properties: [:])
                XCTAssertThrowsError(try ledger.verifyNativePlanned(operationID: "native", observationID: unchanged.snapshot.id.uuidString,
                                                                    scope: fixture.scope, observation: unchanged))
                XCTAssertEqual(ledger.operations[0].plannedVerificationProgress?.outcome, .postconditionMismatch)
            } else { try ledger.recordPlannedVerificationReadFailure(operationID: "native") }
            ledger = try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn")
        }
        XCTAssertThrowsError(try ledger.beginPlannedVerificationAttempt(operationID: "native")) {
            XCTAssertEqual($0 as? ComputerActionEvidence.Failure, .verificationAttemptsExhausted)
        }
        XCTAssertEqual(ledger.operations.count, 1)
        XCTAssertEqual(ledger.operations[0].dispatch, .unknown)
        XCTAssertNotNil(ledger.completionDiagnostic)
    }

    func testNativeVerificationRejectsWrongTargetRetainedAndPredatingAttemptReads() throws {
        for scenario in ["target", "retained", "predates-attempt", "replacement-token"] {
            let fixture = try nativePlannedMutation(selected: false)
            var ledger = fixture.ledger
            try ledger.recordDispatch(operationID: "native", state: .dispatched)
            let after = nativePlannedObservation(token: scenario == "replacement-token" ? UUID() : fixture.token,
                                                  selected: true, isLive: scenario != "retained")
            if scenario != "predates-attempt" { try ledger.beginPlannedVerificationAttempt(operationID: "native") }
            try ledger.recordObservation(id: after.snapshot.id.uuidString,
                targetID: scenario == "target" ? "native:other" : fixture.scope.evidenceTargetID, properties: [:],
                isLive: scenario != "retained")
            if scenario == "predates-attempt" { try ledger.beginPlannedVerificationAttempt(operationID: "native") }
            XCTAssertThrowsError(try ledger.verifyNativePlanned(operationID: "native", observationID: after.snapshot.id.uuidString,
                                                                scope: fixture.scope, observation: after), scenario)
            XCTAssertNil(ledger.operations[0].verification, scenario)
        }
    }

    func testNativePlansCannotBeRearmedOrAddedAfterDispatch() throws {
        let native = try nativePlannedMutation(selected: false)
        var ledger = native.ledger
        XCTAssertThrowsError(try ledger.armNativeVerification(operationID: "native", plan: native.plan))
        var late = ComputerActionEvidence(turnID: "turn")
        try late.begin(operationID: "late", tool: "computer_v2_ax", targetID: native.scope.evidenceTargetID)
        try late.recordDispatch(operationID: "late", state: .unknown)
        XCTAssertThrowsError(try late.armNativeVerification(operationID: "late", plan: native.plan))
    }

    func testLinkedBlockedInputCanResolveByOriginalFreshNoOpReceipt() throws {
        let fixture = try nativePlannedMutation(selected: true)
        var ledger = fixture.ledger
        try ledger.begin(operationID: "blocked", tool: "computer_v2_ax", targetID: fixture.scope.evidenceTargetID)
        try ledger.recordPendingActionRejection(operationID: "blocked", pendingOperationID: "native")
        let fresh = nativePlannedObservation(token: fixture.token, selected: true)
        try ledger.recordObservation(id: fresh.snapshot.id.uuidString, targetID: fixture.scope.evidenceTargetID, properties: [:])
        try ledger.recordNativeAlreadySatisfied(operationID: "native", scope: fixture.scope, observation: fresh)
        XCTAssertEqual(ledger.operations[1].pendingActionRejection?.resolution, .alreadySatisfied)
        XCTAssertTrue(ledger.operations.allSatisfy { $0.dispatch == .notDispatched && $0.verification == nil })
        XCTAssertNil(ledger.completionDiagnostic)
        XCTAssertEqual(try ComputerActionEvidence.restore(ledger.checkpointData(), turnID: "turn"), ledger)
    }

    func testRetiredCheckpointFieldsCannotBeSilentlyDiscarded() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: mutation().checkpointData()) as? [String: Any])
        for key in ["verificationPlan", "preflightIssue"] {
            var object = original
            var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
            operations[0][key] = ["retired": true]
            object["operations"] = operations
            XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"), key)
        }
    }

    func testNativeCheckpointRejectsScopeTamperingRetiredPlansAndNoOpEffectElision() throws {
        let fixture = try nativePlannedMutation(selected: true)
        var ledger = fixture.ledger
        let fresh = nativePlannedObservation(token: fixture.token, selected: true)
        try ledger.recordObservation(id: fresh.snapshot.id.uuidString, targetID: fixture.scope.evidenceTargetID, properties: [:])
        try ledger.recordNativeAlreadySatisfied(operationID: "native", scope: fixture.scope, observation: fresh)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.checkpointData()) as? [String: Any])
        for scenario in ["scope", "retired-plan", "dispatch", "foreground", "missing-plan", "missing-receipt", "baseline-id", "old-sequence", "expected", "progress"] {
            var object = original
            var operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
            if scenario == "scope" { operations[0]["targetID"] = "other-target" }
            else if scenario == "retired-plan" { operations[0]["verificationPlan"] = ["retired": true] }
            else if scenario == "dispatch" { operations[0]["dispatch"] = "dispatched" }
            else if scenario == "foreground" { operations[0]["foregroundEffect"] = "activation_completed" }
            else if scenario == "missing-plan" { operations[0].removeValue(forKey: "nativeVerificationPlan") }
            else if scenario == "missing-receipt" { operations[0].removeValue(forKey: "alreadySatisfied") }
            else if scenario == "progress" {
                var progress = try XCTUnwrap(operations[0]["plannedVerificationProgress"] as? [String: Any])
                progress["outcome"] = "verified"; operations[0]["plannedVerificationProgress"] = progress
            } else {
                var receipt = try XCTUnwrap(operations[0]["alreadySatisfied"] as? [String: Any])
                if scenario == "baseline-id" { receipt["observationID"] = fixture.plan.baselineSnapshotID.uuidString }
                if scenario == "old-sequence" { receipt["observationSequence"] = 0 }
                if scenario == "expected" { receipt["expectedValue"] = "false" }
                operations[0]["alreadySatisfied"] = receipt
            }
            object["operations"] = operations
            XCTAssertThrowsError(try ComputerActionEvidence.restore(JSONSerialization.data(withJSONObject: object), turnID: "turn"), scenario)
        }
    }

    private func nativePlannedObservation(token: UUID, selected: Bool, isLive: Bool = true) -> NativeActionVerification.Observation {
        let root = AccessibilityTreeElement(index: 0, parentIndex: nil, childIndices: [1], depth: 0,
            role: "AXWindow", subrole: nil, title: "Fixture", elementDescription: nil, help: nil,
            identifier: "window", domIdentifier: nil, value: nil, frame: nil, isEnabled: true, isFocused: false,
            supportedActions: [], isValueSettable: false)
        let row = AccessibilityTreeElement(index: 1, parentIndex: 0, childIndices: [], depth: 1,
            role: "AXRow", subrole: nil, title: "Contact A", elementDescription: nil, help: nil,
            identifier: nil, domIdentifier: nil, value: nil, frame: nil, isEnabled: true, isFocused: false,
            supportedActions: ["AXPress"], isValueSettable: false, isSelected: selected, evidenceIdentity: token)
        let snapshot = AccessibilityTreeSnapshot(id: UUID(), application: .init(processIdentifier: 123, bundleIdentifier: "test.fixture"),
            limits: .agentDefault, rootIndex: 0, elements: [root, row], wasTruncated: false)
        return .init(snapshot: snapshot, exposedIndices: [0, 1], isLive: isLive)
    }

    private func nativePlannedMutation(selected: Bool) throws -> (ledger: ComputerActionEvidence, scope: NativeActionVerification.Scope,
        plan: NativeActionVerification.Plan, token: UUID, before: NativeActionVerification.Observation) {
        let scope = NativeActionVerification.Scope(evidenceTargetID: "native:fixture:123", processIdentifier: 123,
                                                   bundleIdentifier: "test.fixture")
        let token = UUID(), before = nativePlannedObservation(token: token, selected: selected)
        let plan = try XCTUnwrap(NativeActionVerification.compile(action: .press, elementIndex: 1, observation: before, scope: scope))
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.recordObservation(id: before.snapshot.id.uuidString, targetID: scope.evidenceTargetID, properties: [:])
        try ledger.begin(operationID: "native", tool: "computer_v2_ax", targetID: scope.evidenceTargetID, recoveryKey: "select-contact")
        try ledger.armNativeVerification(operationID: "native", plan: plan)
        return (ledger, scope, plan, token, before)
    }

    private func plannedScope() -> NativeActionVerification.Scope {
        .init(evidenceTargetID: "native:fixture:123", processIdentifier: 123, bundleIdentifier: "test.fixture")
    }

    private func plannedObservation(scope: NativeActionVerification.Scope, value: String,
                                    isLive: Bool = true) -> NativeActionVerification.Observation {
        let root = AccessibilityTreeElement(index: 0, parentIndex: nil, childIndices: [1], depth: 0,
            role: "AXWindow", subrole: nil, title: "Fixture", elementDescription: nil, help: nil,
            identifier: "window", domIdentifier: nil, value: nil, frame: nil, isEnabled: true, isFocused: false,
            supportedActions: [], isValueSettable: false)
        let field = AccessibilityTreeElement(index: 1, parentIndex: 0, childIndices: [], depth: 1,
            role: "AXTextField", subrole: nil, title: "Query", elementDescription: nil, help: nil,
            identifier: "query", domIdentifier: nil, value: value, frame: nil, isEnabled: true, isFocused: false,
            supportedActions: [], isValueSettable: true)
        let snapshot = AccessibilityTreeSnapshot(id: UUID(),
            application: .init(processIdentifier: scope.processIdentifier, bundleIdentifier: scope.bundleIdentifier),
            limits: .agentDefault, rootIndex: 0, elements: [root, field], wasTruncated: false)
        return .init(snapshot: snapshot, exposedIndices: [0, 1], isLive: isLive)
    }

    private func plannedMutation() throws -> (ledger: ComputerActionEvidence, scope: NativeActionVerification.Scope,
                                             plan: NativeActionVerification.Plan, target: String) {
        let scope = plannedScope(), target = scope.evidenceTargetID
        let before = plannedObservation(scope: scope, value: "")
        let plan = try XCTUnwrap(NativeActionVerification.compile(action: .setText("query"), elementIndex: 1,
                                                                 observation: before, scope: scope))
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.recordObservation(id: before.snapshot.id.uuidString, targetID: target, properties: ["node:17:value": ""])
        try ledger.begin(operationID: "planned", tool: "computer_v2_set_text", targetID: target, recoveryKey: "set-query")
        try ledger.armNativeVerification(operationID: "planned", plan: plan)
        return (ledger, scope, plan, target)
    }

    private func preflight(kind: ComputerActionEvidence.PreflightRejection, tool: String = "computer_v2_ax",
                           target: String = "tab", key: String? = nil, requiresVerification: Bool = true,
                           targetWasUnbound: Bool = false, requiredReadScope: String? = nil,
                           recoveryScope: String? = nil) throws -> ComputerActionEvidence {
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.begin(operationID: "rejected", tool: tool, targetID: target, recoveryKey: key,
                         requiresVerification: requiresVerification, recoveryScope: recoveryScope)
        try ledger.recordPreflightRejection(operationID: "rejected", kind: kind, code: "preflight_rejected",
                                           message: "Rejected before dispatch", targetWasUnbound: targetWasUnbound,
                                           requiredReadScope: requiredReadScope)
        return ledger
    }

    private func freshRead(_ ledger: inout ComputerActionEvidence, target: String = "tab", tool: String = "computer_v2_snapshot",
                           key: String? = nil, isLive: Bool = true, readScope: String? = nil, sourceComplete: Bool = false) throws {
        try ledger.begin(operationID: "read", tool: tool, targetID: target, recoveryKey: key, requiresVerification: false)
        try ledger.recordDispatch(operationID: "read", state: .dispatched)
        try ledger.recordObservation(id: "observed", targetID: target, properties: ["node:17:value": ""], isLive: isLive,
                                     readScope: readScope, sourceComplete: sourceComplete)
    }

    private func mutation(recoveryScope: String? = nil) throws -> ComputerActionEvidence {
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.recordObservation(id: "before", targetID: "tab", properties: ["node:17:value": "", "node:1:text": "Mailbox"])
        try ledger.begin(operationID: "input", tool: "set_text", targetID: "tab", recoveryKey: "set-query", recoveryScope: recoveryScope)
        return ledger
    }

    private func focusAlternative(failedTool: String = "computer_v2_ax", successorTool: String = "computer_v2_set_text",
                                  focusKey: String = "focus:node:17", failedDispatch: ComputerActionEvidence.DispatchState = .notDispatched,
                                  successorTarget: String = "tab", property: String = "node:17:value",
                                  hasFailure: Bool = true, failedScope: String? = nil,
                                  successorScope: String? = nil) throws -> ComputerActionEvidence {
        var ledger = ComputerActionEvidence(turnID: "turn")
        try ledger.begin(operationID: "focus", tool: failedTool, targetID: "tab", recoveryKey: focusKey,
                         baselineProperties: ["node:17:value": ""], recoveryScope: failedScope)
        if hasFailure {
            try ledger.recordFailure(operationID: "focus", code: "unsupported_focus", message: "No input dispatched", dispatch: failedDispatch)
        }
        try ledger.begin(operationID: "fill", tool: successorTool, targetID: successorTarget,
                         recoveryKey: "distinct-text-entry-operation", baselineProperties: [property: ""], recoveryScope: successorScope)
        try ledger.recordDispatch(operationID: "fill", state: .dispatched)
        try ledger.recordObservation(id: "filled", targetID: successorTarget, properties: [property: "query"])
        try ledger.verify(operationID: "fill", observationID: "filled", property: property, expectedValue: "query")
        return ledger
    }
}

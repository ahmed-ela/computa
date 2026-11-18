import Foundation
import XCTest
@testable import Computa

@MainActor
final class KimiModelEvidenceDiagnosticTests: XCTestCase {
    private let reasons = ["model_evidence_selection_pending", "model_evidence_unbound", "model_evidence_picker_open",
        "model_evidence_trigger_replaced", "model_evidence_label_changed"]

    private func observation(_ reason: String = "model_evidence_trigger_replaced", stage: String = "canonical_first_hash") -> [String: Any] {
        var packet: [String: Any] = ["version": 1, "reason": reason, "stage": stage, "required": true,
            "submitted": true, "firstBodyBound": false, "selectionPending": false, "boundSelectionPresent": true,
            "pickerClosed": true, "triggerSameNode": true, "boundTriggerConnected": true, "labelMatches": true]
        switch reason {
        case "model_evidence_selection_pending": packet["selectionPending"] = true
        case "model_evidence_unbound":
            packet["boundSelectionPresent"] = false; packet["triggerSameNode"] = false
            packet["boundTriggerConnected"] = false; packet["labelMatches"] = false
        case "model_evidence_picker_open": packet["pickerClosed"] = false
        case "model_evidence_trigger_replaced": packet["triggerSameNode"] = false; packet["boundTriggerConnected"] = false
        case "model_evidence_label_changed": packet["labelMatches"] = false
        default: break
        }
        return ["error": "model_unverified", "detail": reason, "modelEvidenceDiagnostic": packet]
    }

    func testFinitePredicatesAndCallPathsPreserveTheRejectedCategoryWithoutPublishingPrivateContent() throws {
        for reason in reasons {
            for stage in ["action", "optimistic_first", "canonical_first_hash", "prepare_recheck", "insert_recheck"] {
                var observed = observation(reason, stage: stage)
                observed["text"] = "PRIVATE_BODY_CANARY"; observed["url"] = "https://private.invalid/PRIVATE_ID"
                let text = try XCTUnwrap(EmbeddedWebModelTransport.kimiModelEvidenceDiagnostic(observed, provider: .kimi))
                let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                XCTAssertEqual(packet["reason"] as? String, reason); XCTAssertEqual(packet["stage"] as? String, stage)
                XCTAssertFalse(text.contains("PRIVATE")); XCTAssertLessThanOrEqual(text.utf8.count, 640)
                XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(observed, provider: .kimi, action: "inspect"),
                    "action=inspect error=model_unverified detail=\(reason)")
                for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .kimi {
                    XCTAssertNil(EmbeddedWebModelTransport.kimiModelEvidenceDiagnostic(observed, provider: provider))
                }
            }
        }
    }

    func testMalformedPrivateAndMissingFieldsAreDropped() throws {
        let original = observation(), packet = try XCTUnwrap(original["modelEvidenceDiagnostic"] as? [String: Any])
        let changes: [(String, Any)] = [("version", true), ("version", 2), ("reason", "PRIVATE_REASON"),
            ("stage", "PRIVATE_STAGE"), ("required", false), ("required", 1), ("submitted", 0), ("submitted", false),
            ("firstBodyBound", "true"), ("selectionPending", 0), ("boundSelectionPresent", NSNull()),
            ("pickerClosed", "false"), ("triggerSameNode", true), ("boundTriggerConnected", "false"),
            ("labelMatches", 0), ("prompt", "PRIVATE_BODY_CANARY")]
        for (key, value) in changes {
            var invalid = packet; invalid[key] = value
            var observed = original; observed["modelEvidenceDiagnostic"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.kimiModelEvidenceDiagnostic(observed, provider: .kimi), key)
        }
        for key in packet.keys {
            var invalid = packet; invalid.removeValue(forKey: key)
            var observed = original; observed["modelEvidenceDiagnostic"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.kimiModelEvidenceDiagnostic(observed, provider: .kimi), key)
        }
        for (key, value) in [("error", "document_changed" as Any), ("error", NSNull() as Any),
            ("detail", "model_evidence_label_changed" as Any), ("detail", "PRIVATE" as Any)] {
            var observed = original; observed[key] = value
            XCTAssertNil(EmbeddedWebModelTransport.kimiModelEvidenceDiagnostic(observed, provider: .kimi))
        }
    }

    func testDisjunctPriorityAndStageConsistencyCannotBeRewrittenByDiagnosticMetadata() throws {
        for reason in reasons {
            var observed = observation(reason)
            var packet = try XCTUnwrap(observed["modelEvidenceDiagnostic"] as? [String: Any])
            if reason == "model_evidence_selection_pending" { packet["selectionPending"] = false }
            else { packet["selectionPending"] = true }
            observed["modelEvidenceDiagnostic"] = packet
            XCTAssertNil(EmbeddedWebModelTransport.kimiModelEvidenceDiagnostic(observed, provider: .kimi), reason)
        }
        var observed = observation(stage: "optimistic_first")
        var packet = try XCTUnwrap(observed["modelEvidenceDiagnostic"] as? [String: Any])
        packet["firstBodyBound"] = true; observed["modelEvidenceDiagnostic"] = packet
        XCTAssertNil(EmbeddedWebModelTransport.kimiModelEvidenceDiagnostic(observed, provider: .kimi))
        observed = observation(stage: "action"); packet = try XCTUnwrap(observed["modelEvidenceDiagnostic"] as? [String: Any])
        packet["firstBodyBound"] = true; packet["submitted"] = false; observed["modelEvidenceDiagnostic"] = packet
        XCTAssertNil(EmbeddedWebModelTransport.kimiModelEvidenceDiagnostic(observed, provider: .kimi))
    }
}

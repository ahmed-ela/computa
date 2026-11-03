import Foundation
import XCTest
@testable import Computa

@MainActor
final class QwenFirstUserBindingDiagnosticTests: XCTestCase {
    private let stages: [String: [String]] = [
        "provisional_admission": ["action_not_inspect", "native_grant_missing", "cleanup_inspection", "insertion_missing", "preparation_missing", "send_missing", "model_missing", "selection_pending", "deletion_started", "binding_not_authorized", "expected_fingerprint_present", "marker_invalid", "marker_mismatch", "marker_suffix", "model_choice_mismatch", "submitted_fingerprint_invalid", "submitted_fingerprint_mismatch", "predicate_changed", "submission_unclaimed", "first_already_bound", "canonical_already_bound"],
        "initial_response_admission": ["action_not_inspect", "native_grant_missing", "cleanup_inspection", "insertion_missing", "preparation_missing", "send_missing", "model_missing", "selection_pending", "deletion_started", "binding_not_authorized", "expected_fingerprint_present", "marker_invalid", "marker_mismatch", "marker_suffix", "model_choice_mismatch", "submitted_fingerprint_invalid", "submitted_fingerprint_mismatch", "predicate_changed"],
        "initial_response_body": ["user_count", "answer_count", "first_missing", "full_prompt_mismatch", "counts_not_array", "counts_empty", "counts_limit", "counts_invalid", "one_user_not_expected", "predicate_changed"],
        "initial_response_digest": ["hash_input_invalid", "submitted_fingerprint_mismatch"],
        "binding_digest": ["hash_input_invalid"],
        "binding": ["first_not_submitted", "first_prompt_mismatch", "first_marker_invalid", "first_marker_mismatch", "first_marker_suffix", "first_changed_after_hash", "first_pinned_node_changed", "first_pinned_hash_mismatch", "first_expected_hash_mismatch", "first_binding_not_authorized", "first_disappeared"],
    ]
    private func observation(_ stage: String = "binding", _ reason: String = "first_prompt_mismatch") -> [String: Any] {
        ["error": "conversation_changed", "detail": "first_user_message",
         "qwenFirstUserBindingDiagnostic": ["version": 1, "stage": stage, "reason": reason]]
    }
    func testEveryAllowedStageReasonAppearsOnlyInFiniteAdapterFailureMetadata() {
        for (stage, reasons) in stages {
            for reason in reasons {
                var value = observation(stage, reason)
                value["text"] = "PRIVATE_BODY"; value["url"] = "https://private.invalid/PRIVATE_ID"
                let expected = "firstUserStage=\(stage) firstUserReason=\(reason)"
                XCTAssertEqual(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value, provider: .qwen), expected)
                let log = EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(value, provider: .qwen, action: "inspect")
                XCTAssertEqual(log, "action=inspect error=conversation_changed detail=first_user_message " + expected)
                XCTAssertFalse(log?.contains("PRIVATE") ?? true); XCTAssertLessThan(log?.utf8.count ?? 1_000, 256)
                for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .qwen {
                    XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value, provider: provider))
                }
            }
        }
    }
    func testUnknownCrossStageMissingExtraAndMalformedFieldsCannotReachLogs() {
        let base = observation()
        let invalid: [[String: Any]] = [
            ["version": 2, "stage": "binding", "reason": "first_prompt_mismatch"],
            ["version": true, "stage": "binding", "reason": "first_prompt_mismatch"],
            ["version": 1, "stage": "PRIVATE_STAGE", "reason": "first_prompt_mismatch"],
            ["version": 1, "stage": "binding", "reason": "PRIVATE_REASON"],
            ["version": 1, "stage": "binding", "reason": "full_prompt_mismatch"],
            ["version": 1, "stage": "initial_response_body", "reason": "first_prompt_mismatch"],
            ["version": 1, "stage": "binding"],
            ["version": 1, "reason": "first_prompt_mismatch"],
            ["version": 1, "stage": "binding", "reason": "first_prompt_mismatch", "text": "PRIVATE_BODY"],
            ["version": 1, "stage": true, "reason": "first_prompt_mismatch"],
            ["version": 1, "stage": "binding", "reason": NSNull()]
        ]
        for packet in invalid {
            var value = base; value["qwenFirstUserBindingDiagnostic"] = packet
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value, provider: .qwen))
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(value, provider: .qwen, action: "inspect"),
                           "action=inspect error=conversation_changed detail=first_user_message")
        }
        for (key, changed) in [("error", "document_changed"), ("detail", "response_scope")] {
            var value = base; value[key] = changed
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value, provider: .qwen))
        }
    }
}

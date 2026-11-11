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
        "display_scope": ["held_claim_ineligible", "display_grant_missing"],
        "display_observation": ["user_count_expectation", "composer_not_ready", "initial_not_collapsed", "initial_empty_no_pending_answer", "initial_prefix_mismatch", "initial_length_mismatch", "recollapsed", "preview_prefix_mismatch", "preview_length_mismatch", "not_collapsed"],
        "display_held": ["presentation_missing", "route_changed", "user_id_changed", "answer_id_changed", "pin_count_changed", "body_changed", "control_changed", "user_ancestry_changed", "answer_ancestry_changed"],
        "display_completed": ["presentation_missing", "route_changed", "user_id_changed", "answer_id_changed", "pin_count_changed", "body_changed", "control_changed", "user_ancestry_changed", "answer_ancestry_changed", "recollapsed", "full_text_changed"],
        "display_preclick": ["presentation_missing", "route_changed", "user_id_changed", "answer_id_changed", "pin_count_changed", "body_changed", "control_changed", "user_ancestry_changed", "answer_ancestry_changed", "not_collapsed", "preview_changed", "composer_not_empty", "composer_changed"],
        "display_hit": ["disabled", "invalid_geometry", "outside_viewport", "occluded"],
        "display_preclick_hit": ["disabled", "invalid_geometry", "outside_viewport", "occluded"],
        "display_reveal_hit": ["disabled", "invalid_geometry", "outside_viewport", "occluded", "occluded_ancestor", "occluded_unrelated", "occluded_descendant", "occluded_none", "occluded_mixed", "scroll_failed"],
        "display_settlement": ["render_binding_changed", "render_deadline"],
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
    func testCoverEvidenceIsFiniteAndRestrictedToRejectedQwenInspection() {
        let good = ["phase":"settled", "probe":"grid", "clip":"reduced", "hits":"several", "scope":"composer", "anchor":"fixed"]
        let bare = "firstUserStage=display_reveal_hit firstUserReason=occluded_unrelated"
        func observe(_ cover: [String:Any], stage: String = "display_reveal_hit", reason: String = "occluded_unrelated",
                     action: String = "inspect", provider: EmbeddedWebModelTransport.Provider = .qwen) -> String {
            var row = observation(stage, reason); row["qwenDisplayCover"] = cover
            return EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(row, provider: provider, action: action) ?? ""
        }
        XCTAssertTrue(observe(good).hasSuffix(bare + " displayCover phase=settled probe=grid clip=reduced hits=several scope=composer anchor=fixed"))
        var witness = good; witness["phase"] = "revealed"; witness["probe"] = "witness"; witness["clip"] = "unmeasured"; witness["hits"] = "one"
        XCTAssertTrue(observe(witness).contains("displayCover phase=revealed probe=witness"))
        for key in good.keys {
            var absent = good; absent.removeValue(forKey:key); XCTAssertTrue(observe(absent).hasSuffix(bare))
            for bad: Any in [2, true, NSNull(), "PRIVATE", ["PRIVATE"]] {
                var fields:[String:Any] = good; fields[key] = bad
                XCTAssertTrue(observe(fields).hasSuffix(bare)); XCTAssertFalse(observe(fields).contains("PRIVATE"))
            }
        }
        for (field, value) in [("clip","reduced"),("hits","several"),("scope","mixed"),("anchor","mixed"),("extra","PRIVATE")] {
            var bad = witness; bad[field]=value; XCTAssertTrue(observe(bad).hasSuffix(bare))
        }
        XCTAssertFalse(observe(good, action:"submit").contains("displayCover"))
        XCTAssertFalse(observe(good, provider:.deepseek).contains("displayCover"))
        XCTAssertFalse(observe(good, reason:"occluded_ancestor").contains("displayCover"))
        XCTAssertFalse(observe(good, stage:"display_settlement", reason:"render_deadline").contains("displayCover"))
    }

    func testCompletedDisplayUUIDChangePublishesOnlyFiniteRelationsForThatExactRejection() {
        let facts = ["point":"id_candidate", "spelling":"different_uuid", "pins":"same", "body":"exact",
                     "display":"expanded", "reply":"settled_now", "responseIdentity":"held"]
        func summarize(_ extras: [String: Any], stage: String = "display_completed", reason: String = "user_id_changed") -> String? {
            var row = observation(stage, reason)
            row["qwenFirstUserBindingDiagnostic"] = ["version":1,"stage":stage,"reason":reason,"change":extras]
            return EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(row, provider: .qwen)
        }
        XCTAssertEqual(summarize(facts), "firstUserStage=display_completed firstUserReason=user_id_changed point=id_candidate spelling=different_uuid pins=same body=exact display=expanded reply=settled_now responseIdentity=held")
        for key in facts.keys {
            var unknown = facts; unknown[key] = "PRIVATE_IDENTIFIER"
            XCTAssertNil(summarize(unknown))
            unknown.removeValue(forKey: key); XCTAssertNil(summarize(unknown))
        }
        XCTAssertNil(summarize(facts.merging(["url":"PRIVATE_URL"]) { $1 }))
        XCTAssertNil(summarize(facts, stage: "display_held"))
        XCTAssertNil(summarize(facts, reason: "answer_id_changed"))
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

    func testRejectedAncestryMetadataKeepsOnlyBoundedSlotsAndComparisonBranches() throws {
        func row(_ facts: [String: Any]) -> [String: Any] {
            ["error":"conversation_changed", "detail":"first_user_message", "qwenFirstUserBindingDiagnostic":
                ["version":1, "stage":"display_held", "reason":"answer_ancestry_changed", "ancestry":facts]]
        }
        for path in ["claim", "witness"] {
            for (index, slot) in [(7,"assistant_root"),(8,"assistant_turn"),(9,"response_content")] {
                let facts: [String: Any] = ["path":path,"branch":"pins","index":index,"count":10,"slot":slot,
                    "previous":"object","current":"object","comparison":false]
                let value = row(facts)
                let text = try XCTUnwrap(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value, provider:.qwen))
                XCTAssertTrue(text.hasSuffix("ancestry path=\(path) branch=pins index=\(index) count=10 slot=\(slot) previous=object current=object comparison=false"))
                XCTAssertLessThan(text.utf8.count,512)
                for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .qwen {
                    XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value,provider:provider))
                }
            }
        }
        for branch in ["comparison_scope","comparison_prior"] {
            let facts: [String: Any] = ["path":"witness","branch":branch,"index":NSNull(),"count":NSNull(),"slot":"none",
                "previous":"unknown","current":"unknown","comparison":true]
            XCTAssertTrue(try XCTUnwrap(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(row(facts),provider:.qwen)).contains("index=none count=none"))
        }
    }

    private var rootComparisonAncestry: [String: Any] {
        ["path": "witness", "branch": "pins", "index": 11, "count": 14, "slot": "assistant_root",
         "previous": "object", "current": "object", "comparison": true]
    }

    private func ancestryObservation(_ facts: [String: Any], stage: String = "display_held") -> [String: Any] {
        ["error": "conversation_changed", "detail": "first_user_message", "qwenFirstUserBindingDiagnostic":
            ["version": 1, "stage": stage, "reason": "answer_ancestry_changed", "ancestry": facts]]
    }

    func testComparisonContinuityLogsOnlyFourFiniteFactsAndPreservesOriginalFormat() {
        let base = "firstUserStage=display_held firstUserReason=answer_ancestry_changed ancestry path=witness branch=pins index=11 count=14 slot=assistant_root previous=object current=object comparison=true"
        XCTAssertEqual(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(
            ancestryObservation(rootComparisonAncestry), provider: .qwen), base)
        for (priorResponse, oldRootDetached, assistantTurnMatches, pairRootMatches) in [
            ("first_card", true, true, false), ("second_card", true, false, true), ("detached", false, true, true)
        ] {
            var facts = rootComparisonAncestry
            facts["continuity"] = [
                "oldRootDetached": NSNumber(value: oldRootDetached), "priorResponse": priorResponse,
                "assistantTurnMatches": assistantTurnMatches, "pairRootMatches": pairRootMatches
            ] as [String: Any]
            let value = ancestryObservation(facts)
            let expected = base + " continuity oldRootDetached=\(oldRootDetached) priorResponse=\(priorResponse) assistantTurnMatches=\(assistantTurnMatches) pairRootMatches=\(pairRootMatches)"
            XCTAssertEqual(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value, provider: .qwen), expected)
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(value, provider: .qwen, action: "inspect"),
                           "action=inspect error=conversation_changed detail=first_user_message " + expected)
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value, provider: .deepseek))
        }
    }

    func testMalformedOrMisplacedComparisonContinuityKeepsOriginalFailure() {
        let good: [String: Any] = [
            "oldRootDetached": true, "priorResponse": "second_card", "assistantTurnMatches": true, "pairRootMatches": true
        ]
        func reject(_ facts: [String: Any], stage: String = "display_held") {
            let value = ancestryObservation(facts, stage: stage)
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value, provider: .qwen))
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(value, provider: .qwen, action: "inspect"),
                           "action=inspect error=conversation_changed detail=first_user_message")
        }
        var facts = rootComparisonAncestry
        for key in good.keys {
            var missing = good
            missing.removeValue(forKey: key)
            facts["continuity"] = missing
            reject(facts)
            for invalid: Any in [1, 0, NSNull(), "PRIVATE"] {
                facts["continuity"] = good.merging([key: invalid]) { _, new in new }
                reject(facts)
            }
        }
        facts["continuity"] = NSNull()
        reject(facts)
        facts["continuity"] = good.merging(["extra": "PRIVATE"]) { _, new in new }
        reject(facts)
        facts["continuity"] = good.merging(["priorResponse": "first_card"]) { _, new in new }
        reject(facts)
        facts["continuity"] = good.merging(["priorResponse": "detached"]) { _, new in new }
        reject(facts)
        facts["continuity"] = good
        for changes: [String: Any] in [
            ["path": "claim"], ["comparison": false], ["previous": "null"], ["current": "undefined"],
            ["index": 12, "slot": "assistant_turn"], ["index": 13, "slot": "response_content"],
            ["branch": "comparison_scope", "index": NSNull(), "count": NSNull(),
             "slot": "none", "previous": "unknown", "current": "unknown"],
            ["branch": "comparison_prior", "index": NSNull(), "count": NSNull(),
             "slot": "none", "previous": "unknown", "current": "unknown"],
            ["extra": "PRIVATE"]
        ] {
            reject(facts.merging(changes) { _, new in new })
        }
        reject(facts, stage: "display_completed")
    }

    func testMalformedAncestryCannotReplaceOriginalFailureOrLeakPrivateFields() {
        let good: [String: Any] = ["path":"claim","branch":"pins","index":9,"count":10,"slot":"response_content",
            "previous":"object","current":"object","comparison":false]
        func observe(_ facts: [String: Any], stage: String = "display_held", reason: String = "answer_ancestry_changed") -> [String: Any] {
            ["error":"conversation_changed","detail":"first_user_message","qwenFirstUserBindingDiagnostic":
                ["version":1,"stage":stage,"reason":reason,"ancestry":facts]]
        }
        let mutations: [[String: Any]] = [["path":"PRIVATE"],["branch":"PRIVATE"],["index":true],["count":true],
            ["count":24],["index":6],["index":10],["slot":"assistant_root"],["previous":"PRIVATE_BODY"],
            ["current":"https://private.invalid"],["comparison":1],["PRIVATE":"PRIVATE_BODY"],
            ["branch":"comparison_prior"],["index":NSNull()]]
        for mutation in mutations {
            let value = observe(good.merging(mutation) { _,new in new })
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(value,provider:.qwen))
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(value,provider:.qwen,action:"inspect"),
                "action=inspect error=conversation_changed detail=first_user_message")
        }
        for key in good.keys {
            var missing=good;missing.removeValue(forKey:key)
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(observe(missing),provider:.qwen))
        }
        XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(observe(good,stage:"display_completed"),provider:.qwen))
        XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserBindingDiagnostic(observe(good,reason:"body_changed"),provider:.qwen))
        let error = EmbeddedWebModelTransport.Failure.ownershipFailure(.javaScriptFirstUser)
        XCTAssertEqual(error.diagnosticCode,"website_ownership_unverified")
        XCTAssertEqual(error.requiredAction,"inspect_website")
    }
}

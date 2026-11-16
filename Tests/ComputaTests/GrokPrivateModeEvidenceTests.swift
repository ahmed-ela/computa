import Foundation
import XCTest
@testable import Computa

final class GrokPrivateModeEvidenceTests: XCTestCase {
    private let owner = UUID().uuidString
    private let generation = UUID()
    private let fingerprint = String(repeating: "a", count: 64)

    private func packet(submitted: Bool = false) -> [String: Any] {
        ["version": 1, "source": submitted ? "submitted_private_provenance" : "current_private_control",
         "ownerToken": owner, "documentGeneration": generation.uuidString, "url": "https://grok.com/",
         "sequence": submitted ? 1 : 0, "enteredBeforeSend": true, "sendClaimed": submitted,
         "contradictoryModeObserved": false]
    }

    func testPrivateEvidenceRequiresClosedTypedOwnerGenerationAndRoot() throws {
        XCTAssertNotNil(GrokPrivateModeEvidence.parse(packet(), ownerToken: owner, generation: generation))
        XCTAssertNotNil(GrokPrivateModeEvidence.parse(packet(submitted: true), ownerToken: owner, generation: generation))
        XCTAssertNil(GrokPrivateModeEvidence.parse(packet(), ownerToken: UUID().uuidString, generation: generation))
        XCTAssertNil(GrokPrivateModeEvidence.parse(packet(), ownerToken: owner, generation: UUID()))
        for key in packet().keys {
            var missing = packet(); missing.removeValue(forKey: key)
            XCTAssertNil(GrokPrivateModeEvidence.parse(missing, ownerToken: owner, generation: generation), key)
        }
        let changes: [(String, Any)] = [("version", true), ("version", 1.5), ("version", "1"),
            ("sequence", false), ("sequence", 1), ("sendClaimed", 0), ("sendClaimed", true),
            ("enteredBeforeSend", 1), ("enteredBeforeSend", false), ("contradictoryModeObserved", 0),
            ("contradictoryModeObserved", true), ("source", "unknown"), ("extra", false),
            ("url", "https://grok.com/c/foreign"), ("url", "https://grok.com/?private=true"),
            ("url", "https://grok.com/#private"), ("url", "https://grok.com:443/")]
        for (key, value) in changes {
            var changed = packet(); changed[key] = value
            XCTAssertNil(GrokPrivateModeEvidence.parse(changed, ownerToken: owner, generation: generation), key)
        }
    }

    func testSubmittedProvenanceCannotCreateNativeSendAuthority() throws {
        let ready = try XCTUnwrap(GrokPrivateModeEvidence.parse(packet(), ownerToken: owner, generation: generation))
        let submitted = try XCTUnwrap(GrokPrivateModeEvidence.parse(packet(submitted: true), ownerToken: owner, generation: generation))
        XCTAssertNil(GrokPrivateSubmission(ready: submitted, outboundFingerprint: fingerprint))
        XCTAssertNil(GrokPrivateSubmission(ready: ready, outboundFingerprint: "short"))
        XCTAssertNil(GrokPrivateSubmission(ready: ready, outboundFingerprint: fingerprint + "\n"))
        var proof = try XCTUnwrap(GrokPrivateSubmission(ready: ready, outboundFingerprint: fingerprint))
        XCTAssertFalse(proof.accepts(submitted, sequence: 1))
        for (token, gen, url, hash) in [(UUID().uuidString, generation, "https://grok.com/", fingerprint),
            (owner, UUID(), "https://grok.com/", fingerprint), (owner, generation, "https://grok.com/c/foreign", fingerprint),
            (owner, generation, "https://grok.com/", String(repeating: "b", count: 64))] {
            XCTAssertFalse(proof.claim(ownerToken: token, generation: gen, url: url, outboundFingerprint: hash))
            XCTAssertFalse(proof.claimed)
        }
        XCTAssertTrue(proof.claim(ownerToken: owner, generation: generation, url: "https://grok.com/", outboundFingerprint: fingerprint))
        XCTAssertFalse(proof.claim(ownerToken: owner, generation: generation, url: "https://grok.com/", outboundFingerprint: fingerprint))
        XCTAssertTrue(proof.accepts(submitted, sequence: 1))
        XCTAssertFalse(proof.accepts(ready, sequence: 1))
        XCTAssertFalse(proof.accepts(submitted, sequence: 0))
        XCTAssertFalse(proof.accepts(submitted, sequence: 2))
        let foreignOwner = UUID().uuidString
        let foreign = try XCTUnwrap(GrokPrivateModeEvidence.parse(packet(submitted: true).merging(["ownerToken": foreignOwner]) { _, new in new },
            ownerToken: foreignOwner, generation: generation))
        XCTAssertFalse(proof.accepts(foreign, sequence: 1))
    }

    private func freshPacket(_ stage: String) -> [String: Any] {
        ["grokFreshStart": ["version": 1, "stage": stage]]
    }

    func testFreshStartReadinessIsClosedNegativeOnlyAndLoggedOncePerPair() throws {
        let path = "https://grok.com/c/11111111-abcd-4333-8444-555555555555"
        var lease = try XCTUnwrap(GrokFreshStartPreparation(url: path, owner: owner, generation: generation))
        var unique = 0
        for target in ["toggle", "new_chat"] {
            for reason in ["disabled", "invalid_geometry", "outside_viewport", "occluded"] {
                let value: [String: Any] = ["grokFreshStart": ["version": 1, "stage": "pending",
                    "readiness": ["target": target, "reason": reason]]]
                let observed = try XCTUnwrap(GrokFreshStartPreparation.parse(value))
                XCTAssertTrue(lease.accept(observed, action: .inspect))
                if lease.newlyObservedReadiness(observed) != nil { unique += 1 }
                XCTAssertNil(lease.newlyObservedReadiness(observed))
                XCTAssertEqual(lease.nextAction(), .inspect)
                XCTAssertFalse(lease.expanded); XCTAssertFalse(lease.newChatClaimed); XCTAssertFalse(lease.verified)
                for stage in ["sidebar_closed", "new_chat_ready", "sidebar_requested", "new_chat_requested", "root_observed"] {
                    XCTAssertNil(GrokFreshStartPreparation.parse(["grokFreshStart": ["version": 1, "stage": stage,
                        "readiness": ["target": target, "reason": reason]]]))
                }
                var later = try XCTUnwrap(GrokFreshStartPreparation(url: path, owner: owner, generation: generation))
                XCTAssertTrue(later.accept(freshPacket("new_chat_ready"), action: .inspect))
                XCTAssertEqual(later.nextAction(), .newChat)
                XCTAssertFalse(later.accept(observed, action: .verify), "Readiness can only delay initial Inspect")
            }
        }
        XCTAssertEqual(unique, 8)
        for fields: Any in [["target": "unknown", "reason": "occluded"], ["target": "toggle", "reason": "private text"],
            ["target": "toggle", "reason": "occluded", "url": "https://example.test/private"],
            ["target": "toggle"], NSNull(), true] {
            XCTAssertNil(GrokFreshStartPreparation.parse(["grokFreshStart": ["version": 1, "stage": "pending", "readiness": fields]]))
        }
    }

    func testFreshStartFailureDiagnosticKeepsOnlyClosedCategories() {
        XCTAssertEqual(GrokFreshStartPreparation.failureDiagnostic(error: "document_changed", detail: "fresh_start_action_unverified"),
            "error=document_changed detail=fresh_start_action_unverified")
        XCTAssertEqual(GrokFreshStartPreparation.failureDiagnostic(error: "composer_not_empty", detail: nil),
            "error=composer_not_empty detail=absent")
        for raw: Any in ["private page text", "https://grok.com/c/private?rid=secret", 123, true, ["document_changed"], NSNull()] {
            XCTAssertEqual(GrokFreshStartPreparation.failureDiagnostic(error: raw, detail: raw), "error=unknown detail=unknown")
        }
    }

    func testFreshStartRouteAllowsOnlyPinnedMonotonicResponseID() throws {
        let path = "https://grok.com/c/11111111-abcd-4333-8444-555555555555"
        let rid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        for raw in [path, path + "?rid=" + rid] { XCTAssertNotNil(GrokFreshStartPreparation.Route(raw)) }
        for raw in [path + "/", path + "?", path + "#", path + "?rid=x", path + "?rid=" + rid + "&x=1",
            path + "?rid=" + rid + "&rid=" + rid, path + "\n", path.uppercased(), "https://grok.com:443" + URL(string: path)!.path] {
            XCTAssertNil(GrokFreshStartPreparation.Route(raw), raw)
        }
        for invalid in [path, path + "?rid=ffffffff-bbbb-4ccc-8ddd-eeeeeeeeeeee", "https://grok.com/", path + "#x"] {
            var lease = try XCTUnwrap(GrokFreshStartPreparation(url: path, owner: owner, generation: generation))
            XCTAssertTrue(lease.observe(path + "?rid=" + rid))
            XCTAssertFalse(lease.observe(invalid))
            XCTAssertFalse(lease.observe(path + "?rid=" + rid), "An invalid excursion stays failed")
        }
    }

    func testFreshStartClaimsAreSingleAndRootReceiptHasNoInferenceAuthority() throws {
        let path = "https://grok.com/c/11111111-abcd-4333-8444-555555555555"
        var lease = try XCTUnwrap(GrokFreshStartPreparation(url: path, owner: owner, generation: generation))
        XCTAssertEqual(lease.nextAction(), .inspect)
        XCTAssertTrue(lease.accept(freshPacket("sidebar_closed"), action: .inspect))
        XCTAssertEqual(lease.nextAction(), .expand)
        XCTAssertTrue(lease.expanded)
        XCTAssertNil(lease.nextAction(), "Lost expansion acknowledgement cannot replay the action")
        XCTAssertTrue(lease.failed)
        lease = try XCTUnwrap(GrokFreshStartPreparation(url: path, owner: owner, generation: generation))
        XCTAssertTrue(lease.accept(freshPacket("new_chat_ready"), action: .inspect))
        XCTAssertEqual(lease.nextAction(), .newChat)
        XCTAssertEqual(lease.nextAction(), .verify, "Even without acknowledgement, the next action is read-only")
        XCTAssertTrue(lease.accept(freshPacket("new_chat_requested"), action: .newChat))
        XCTAssertTrue(lease.observe(GrokPrivateModeEvidence.root))
        XCTAssertTrue(lease.accept(freshPacket("root_observed"), action: .verify))
        XCTAssertTrue(lease.verified)
        XCTAssertNil(lease.nextAction())
        XCTAssertFalse(lease.observe(path))
        XCTAssertFalse(lease.observe(GrokPrivateModeEvidence.root))
    }

    func testFreshStartReceiptRejectsForgedStageOpenFieldsAndEarlyRoot() throws {
        let path = "https://grok.com/c/11111111-abcd-4333-8444-555555555555"
        let invalid: [[String: Any]] = [[:], ["grokFreshStart": ["version": true, "stage": "pending"]],
            ["grokFreshStart": ["version": 1.5, "stage": "pending"]],
            ["grokFreshStart": ["version": 1, "stage": "pending", "text": "invented"]],
            ["grokFreshStart": ["version": 1, "stage": "unknown"]],
            freshPacket("pending").merging(["temporary": true]) { _, new in new }, freshPacket("root_observed")]
        for value in invalid {
            var lease = try XCTUnwrap(GrokFreshStartPreparation(url: path, owner: owner, generation: generation))
            XCTAssertFalse(lease.accept(value, action: .inspect))
            XCTAssertTrue(lease.failed)
        }
        var lease = try XCTUnwrap(GrokFreshStartPreparation(url: path, owner: owner, generation: generation))
        XCTAssertFalse(lease.observe(GrokPrivateModeEvidence.root), "Unclaimed route transition cannot prove navigation")
    }

    @MainActor
    func testInitialHydrationReceiptCarriesNoPositiveAuthority() {
        let value: [String: Any] = ["grokInitialHydrationPending": true, "pending": true, "composer": false]
        XCTAssertTrue(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(value))
        for key in value.keys {
            var missing = value; missing.removeValue(forKey: key)
            XCTAssertFalse(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(missing))
            var number = value; number[key] = key == "composer" ? 0 : 1
            XCTAssertFalse(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(number))
            var inverted = value; inverted[key] = key == "composer"
            XCTAssertFalse(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(inverted))
        }
        for key in ["url", "temporary", "modelEvidence", "grokPrivateEvidence", "firstUserFingerprint", "text", "answerComplete"] {
            var extra = value; extra[key] = true
            XCTAssertFalse(EmbeddedWebModelTransport.isGrokInitialHydrationObservation(extra), key)
        }
    }

    @MainActor
    func testComposerDiagnosticOnlyRetainsClosedActionAndBranchNames() {
        let actions = ["inspect", "discoverModels", "selectModel", "verifyModel", "enableTemporary",
            "prepare", "insert", "sendReady", "submit", "stop"]
        let details = ["initial_editor_ambiguous", "initial_editor_invalid", "initial_action_ambiguous",
            "initial_action_invalid", "editor_missing", "editor_ambiguous", "editor_authored", "action_missing",
            "action_ambiguous", "action_authored", "action_invalid", "editor_not_fresh", "editor_hit_test"]
        for action in actions {
            for detail in details {
                XCTAssertEqual(EmbeddedWebModelTransport.grokComposerFailureDiagnostic(action: action, detail: detail),
                    "composer_unavailable; action=\(action); detail=\(detail)")
            }
            for detail: Any in ["private page contents", "https://grok.com/c/private", 42, ["editor_missing"], NSNull()] {
                XCTAssertEqual(EmbeddedWebModelTransport.grokComposerFailureDiagnostic(action: action, detail: detail),
                    "composer_unavailable; action=\(action); detail=unknown")
            }
        }
        XCTAssertNil(EmbeddedWebModelTransport.grokComposerFailureDiagnostic(action: "unknown private action", detail: "editor_missing"))
    }

    @MainActor
    func testPrivateFailureDiagnosticOnlyRetainsClosedProviderActionErrorAndDetail() {
        let details = ["private_control_missing", "private_control_shape", "private_control_hit_disabled",
            "private_control_hit_invalid_geometry", "private_control_hit_outside_viewport", "private_control_hit_occluded"]
        for error in ["temporary_mode_unavailable", "temporary_mode_unverified"] {
            for action in ["inspect", "discoverModels", "selectModel", "verifyModel", "enableTemporary",
                "prepare", "insert", "sendReady", "submit", "stop"] {
                for detail in details {
                    XCTAssertEqual(EmbeddedWebModelTransport.grokPrivateFailureDiagnostic(["error": error, "detail": detail], provider: .grok, action: action),
                        "action=\(action) error=\(error) detail=\(detail)")
                }
                XCTAssertEqual(EmbeddedWebModelTransport.grokPrivateFailureDiagnostic(["error": error], provider: .grok, action: action),
                    "action=\(action) error=\(error) detail=absent")
                for detail: Any in ["private page text", "https://grok.com/c/private?rid=secret", 1, true, NSNull(), ["private_control_missing"], String(repeating: "x", count: 10_000)] {
                    XCTAssertEqual(EmbeddedWebModelTransport.grokPrivateFailureDiagnostic(["error": error, "detail": detail,
                        "url": "https://example.test/private", "text": "PRIVATE"], provider: .grok, action: action),
                        "action=\(action) error=\(error) detail=unknown")
                }
            }
        }
        let valid: [String: Any] = ["error": "temporary_mode_unavailable", "detail": "private_control_hit_occluded"]
        for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .grok {
            XCTAssertNil(EmbeddedWebModelTransport.grokPrivateFailureDiagnostic(valid, provider: provider, action: "enableTemporary"))
        }
        XCTAssertNil(EmbeddedWebModelTransport.grokPrivateFailureDiagnostic(valid, provider: .grok, action: "private action text"))
        for error: Any in ["private error text", "composer_unavailable", 1, NSNull()] {
            XCTAssertNil(EmbeddedWebModelTransport.grokPrivateFailureDiagnostic(["error": error], provider: .grok, action: "enableTemporary"))
        }
    }

    @MainActor
    func testModelAdapterDiagnosticOnlyRetainsClosedProviderActionErrorAndDetail() {
        let actions = ["inspect", "discoverModels", "selectModel", "verifyModel", "enableTemporary",
            "prepare", "insert", "sendReady", "submit", "stop"]
        let errors = ["model_unverified", "model_mismatch", "model_unavailable", "unknown_action"]
        let details = ["model_trigger_missing", "model_trigger_hidden", "model_trigger_ambiguous",
            "model_trigger_shape", "model_trigger_label", "model_trigger_choice", "model_menu_ambiguous",
            "model_menu_authored", "model_expansion_invalid", "model_collapsed_menu_present", "model_rows_unavailable",
            "model_rows_empty", "model_row_choice", "model_row_checked", "model_row_authored", "model_rows_duplicate",
            "model_checked_count", "model_checked_disabled", "model_checked_label", "model_enabled_count",
            "model_pinned_changed", "model_action_unknown", "model_intent_invalid", "model_operation_changed",
            "model_open_not_closed", "model_trigger_replaced", "model_target_count", "model_selection_changed",
            "model_guard_contradiction", "model_observed_changed", "model_pilot_unavailable", "model_choices_empty",
            "model_verify_missing", "model_required_missing", "model_initial_trigger_ambiguous",
            "model_initial_trigger_invalid", "model_initial_menu_present", "model_closing_trigger_replaced",
            "model_closing_menu_replaced", "model_closing_selection_changed", "model_closing_shape"]
            + ["model_open_hit_", "model_option_hit_"].flatMap { prefix in
                ["disabled", "invalid_geometry", "outside_viewport", "occluded"].map { prefix + $0 }
            }
        for action in actions {
            for error in errors {
                for detail in details {
                    XCTAssertEqual(EmbeddedWebModelTransport.grokModelFailureDiagnostic(["error": error, "detail": detail], provider: .grok, action: action),
                        "action=\(action) error=\(error) detail=\(detail)")
                }
                XCTAssertEqual(EmbeddedWebModelTransport.grokModelFailureDiagnostic(["error": error], provider: .grok, action: action),
                    "action=\(action) error=\(error) detail=absent")
                for detail: Any in ["PRIVATE_PAGE_TEXT", "https://grok.com/c/private", 42, true, NSNull(), ["model_trigger_missing"], String(repeating: "x", count: 10_000)] {
                    XCTAssertEqual(EmbeddedWebModelTransport.grokModelFailureDiagnostic(["error": error, "detail": detail,
                        "url": "PRIVATE_URL", "modelEvidence": ["selected": "PRIVATE_MODEL"]], provider: .grok, action: action),
                        "action=\(action) error=\(error) detail=unknown")
                }
            }
        }
        let valid: [String: Any] = ["error": "model_unverified", "detail": "model_trigger_missing"]
        for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .grok {
            XCTAssertNil(EmbeddedWebModelTransport.grokModelFailureDiagnostic(valid, provider: provider, action: "selectModel"))
        }
        XCTAssertNil(EmbeddedWebModelTransport.grokModelFailureDiagnostic(valid, provider: .grok, action: "PRIVATE_ACTION"))
        for error: Any in ["PRIVATE_ERROR", "composer_unavailable", 1, true, NSNull()] {
            XCTAssertNil(EmbeddedWebModelTransport.grokModelFailureDiagnostic(["error": error], provider: .grok, action: "selectModel"))
        }
    }

    @MainActor
    func testNativeModelDiagnosticOnlyRetainsClosedFailureStagesAndProofShapes() {
        let actions = ["inspect", "discoverModels", "selectModel", "verifyModel", "enableTemporary",
            "prepare", "insert", "sendReady", "submit", "stop", "cleanup", "other"]
        let stages = ["initial_hydration", "loading_selection_state", "invalid_pending", "selection_parse",
            "evidence_mismatch", "pinned_selection", "after_await"]
        let observations: [([String: Any], String)] = [
            ([:], "evidence=absent selected=absent modePresent=false responsePresent=false"),
            (["modelEvidence": NSNull()], "evidence=null selected=absent modePresent=false responsePresent=false"),
            (["modelEvidence": "PRIVATE_PROOF"], "evidence=other selected=absent modePresent=false responsePresent=false"),
            (["modelEvidence": ["selected": ["key": "PRIVATE_MODEL", "label": "PRIVATE_LABEL"], "response": "PRIVATE_REPLY"],
              "modeEvidence": "PRIVATE_MODE", "text": "PRIVATE_TEXT", "url": "PRIVATE_URL"],
             "evidence=object selected=object modePresent=true responsePresent=true"),
            (["modelEvidence": ["selected": NSNull()]], "evidence=object selected=null modePresent=false responsePresent=false"),
            (["modelEvidence": ["selected": ["PRIVATE_MODEL"]]], "evidence=object selected=other modePresent=false responsePresent=false")]
        for action in actions {
            for stage in stages {
                for failure in [EmbeddedWebModelTransport.Failure.modelUnverified, .modelMismatch] {
                    for (observation, shape) in observations {
                        let error = failure == .modelUnverified ? "model_unverified" : "model_mismatch"
                        let result = EmbeddedWebModelTransport.grokNativeModelFailureDiagnostic(observation, provider: .grok,
                            action: action, stage: stage, failure: failure)
                        XCTAssertEqual(result, "action=\(action) error=\(error) stage=\(stage) " + shape)
                        XCTAssertFalse(result?.contains("PRIVATE") == true)
                        XCTAssertLessThanOrEqual(result?.utf8.count ?? 0, 256)
                    }
                }
            }
        }
        for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .grok {
            XCTAssertNil(EmbeddedWebModelTransport.grokNativeModelFailureDiagnostic([:], provider: provider,
                action: "selectModel", stage: "selection_parse", failure: .modelUnverified))
        }
        XCTAssertNil(EmbeddedWebModelTransport.grokNativeModelFailureDiagnostic([:], provider: .grok,
            action: "PRIVATE_ACTION", stage: "selection_parse", failure: .modelUnverified))
        XCTAssertNil(EmbeddedWebModelTransport.grokNativeModelFailureDiagnostic([:], provider: .grok,
            action: "selectModel", stage: "PRIVATE_STAGE", failure: .modelUnverified))
        for failure in [EmbeddedWebModelTransport.Failure.temporaryUnverified, .modelUnavailable, .editorFailure("PRIVATE_ERROR")] {
            XCTAssertNil(EmbeddedWebModelTransport.grokNativeModelFailureDiagnostic([:], provider: .grok,
                action: "selectModel", stage: "selection_parse", failure: failure))
        }
    }

    @MainActor
    func testInitialEditorDiagnosticRejectsOpenFieldsAndKeepsOverlappingFailures() {
        let valid: [String: Any] = ["version": 1, "tag": "div", "editable": true, "role": true, "label": true,
            "connected": true, "rects": false, "displayNone": true, "visibilityHidden": false,
            "hiddenAncestor": true, "inertAncestor": false, "ariaHiddenAncestor": false, "disabled": false, "ariaDisabled": false]
        let reason = "initial_editor_no_rects"
        let rendered = EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(valid, action: "inspect", detail: reason)
        XCTAssertNotNil(rendered)
        XCTAssertTrue(rendered?.contains("rects=false displayNone=true") == true)
        XCTAssertTrue(rendered?.contains("hiddenAncestor=true") == true)
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(missing, action: "inspect", detail: reason), key)
        }
        for (key, value): (String, Any) in [("extra", "private text"), ("tag", "private DOM tag"), ("rects", 0),
            ("editable", "true"), ("version", true), ("version", 1.5)] {
            var invalid = valid; invalid[key] = value
            XCTAssertNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(invalid, action: "inspect", detail: reason), key)
        }
        XCTAssertNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(valid, action: "submit", detail: reason))
        XCTAssertNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(valid, action: "inspect", detail: "initial_editor_disabled"))
        var textarea = valid; textarea["tag"] = "textarea"
        XCTAssertNotNil(EmbeddedWebModelTransport.grokInitialEditorFailureDiagnostic(textarea, action: "inspect", detail: "initial_editor_tag_textarea"))
    }

    @MainActor
    func testUnexpectedGrokRouteDiagnosticDistinguishesLiteralRootAndClosedRouteShapes() throws {
        let uuid = "11111111-abcd-4333-8444-555555555555"
        let cases: [(String, [String])] = [
            ("https://grok.com/", ["literal=root_with_slash", "path=root", "segments=0", "query=absent"]),
            ("https://grok.com", ["literal=implicit_slash", "path=root", "segments=0"]),
            ("https://grok.com/?", ["literal=other", "query=empty"]),
            ("https://grok.com/?PRIVATE_KEY=PRIVATE_VALUE", ["literal=other", "query=present"]),
            ("https://grok.com/#PRIVATE_FRAGMENT", ["literal=other", "fragment=true"]),
            ("https://grok.com/c/" + uuid, ["path=saved_c", "segments=2", "tokenUUID=lower"]),
            ("https://grok.com/c/" + uuid.uppercased(), ["tokenUUID=upper"]),
            ("https://grok.com/c/" + uuid.replacingOccurrences(of: "abcd", with: "AbCd"), ["tokenUUID=mixed"]),
            ("https://grok.com/c/PRIVATE_TOKEN/PRIVATE_SUFFIX", ["path=saved_c", "segments=3plus", "tokenUUID=other"]),
            ("https://grok.com/c/", ["path=saved_c", "segments=1", "tokenUUID=absent"]),
            ("https://grok.com/PRIVATE_PATH", ["path=other", "segments=1", "tokenUUID=absent"]),
            ("http://grok.com/", ["scheme=http", "host=expected", "literal=other"]),
            ("private+scheme://grok.com/", ["scheme=other", "host=expected"]),
            ("https://PRIVATE_HOST.invalid/", ["host=other"]),
            ("https://grok.com:443/", ["port=https_default", "literal=other"]),
            ("https://grok.com:444/", ["port=other"]),
            ("https://PRIVATE_USER:PRIVATE_PASSWORD@grok.com/", ["userInfo=true"]),
        ]
        for (raw, expected) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            let before = EmbeddedWebModelTransport.Provider.grok.accepts(raw)
            let result = EmbeddedWebModelTransport.unexpectedGrokRouteDiagnostic(url)
            for field in expected { XCTAssertTrue(result.split(separator: " ").contains(Substring(field)), field) }
            XCTAssertEqual(EmbeddedWebModelTransport.Provider.grok.accepts(raw), before)
            XCTAssertEqual(before, raw == "https://grok.com/", "Diagnostics never change exact-root admission")
            XCTAssertLessThanOrEqual(result.utf8.count, 256)
            for forbidden in ["PRIVATE", uuid, "grok.com", "https://", "http://", "abcd", "555555"] {
                XCTAssertFalse(result.contains(forbidden), forbidden)
            }
        }
    }

    @MainActor
    func testUnexpectedGrokRouteDiagnosticNeverRetainsPathQueryOrTokenData() throws {
        let schemas: [String: Set<String>] = ["scheme": ["absent", "https", "http", "other"],
            "host": ["absent", "expected", "other"], "port": ["absent", "https_default", "other"],
            "literal": ["absent", "root_with_slash", "implicit_slash", "other"], "userInfo": ["true", "false"],
            "path": ["absent", "root", "saved_c", "other"], "segments": ["0", "1", "2", "3plus"],
            "tokenUUID": ["absent", "lower", "upper", "mixed", "other", "oversized"],
            "query": ["absent", "empty", "present"], "fragment": ["true", "false"]]
        let inputs: [URL?] = [nil, URL(string: "https://grok.com/c/" + String(repeating: "X", count: 4096)),
            URL(string: "https://grok.com/c/%31%31%31%31%31%31%31%31-abcd-4333-8444-555555555555?SECRET_KEY=SECRET_VALUE#SECRET_FRAGMENT"),
            URL(string: "https://grok.com/SECRET_PATH/SECRET_SUBPATH?" + String(repeating: "SECRET", count: 1000))]
        for url in inputs {
            let result = EmbeddedWebModelTransport.unexpectedGrokRouteDiagnostic(url)
            let fields = Dictionary(uniqueKeysWithValues: result.split(separator: " ").map { field in
                let pair = field.split(separator: "=", maxSplits: 1); return (String(pair[0]), String(pair[1]))
            })
            XCTAssertEqual(Set(fields.keys), Set(schemas.keys))
            for (key, value) in fields { XCTAssertTrue(schemas[key]?.contains(value) == true) }
            XCTAssertLessThanOrEqual(result.utf8.count, 256)
            for forbidden in ["SECRET", String(repeating: "X", count: 32), "11111111", "%31", "grok.com"] {
                XCTAssertFalse(result.contains(forbidden))
            }
        }
        XCTAssertTrue(EmbeddedWebModelTransport.unexpectedGrokRouteDiagnostic(nil).contains("literal=absent"))
    }

    @MainActor
    func testOnlyExactPrivateRootIsAdmitted() {
        let provider = EmbeddedWebModelTransport.Provider.grok
        XCTAssertTrue(provider.lifecycle == .temporary)
        XCTAssertTrue(provider.accepts("https://grok.com/"))
        XCTAssertTrue(provider.acceptsUnboundStart(URL(string: "https://grok.com/")!))
        XCTAssertFalse(provider.acceptsTemporaryToggle(URL(string: "https://grok.com/")!))
        XCTAssertNil(provider.savedConversationPolicy)
        for url in ["https://grok.com", "https://grok.com:443/", "https://grok.com/?private=true",
            "https://grok.com/#private", "https://grok.com/c/123?rid=123", "https://www.grok.com/", "https://chat.groq.com/"] {
            XCTAssertFalse(provider.accepts(url), url)
            XCTAssertNil(provider.conversationURL(url), url)
        }
    }
}

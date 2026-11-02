import XCTest
@testable import Computa

final class SavedAdapterFailureDiagnosticTests: XCTestCase {
    @MainActor func testOnlyExplicitSavedConversationProvidersProduceFailureDiagnostics() {
        for provider in EmbeddedWebModelTransport.Provider.allCases {
            let diagnostic = EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "document_changed", "detail": "composer"], provider: provider, action: "inspect")
            XCTAssertEqual(diagnostic != nil, [EmbeddedWebModelTransport.Provider.kimi, .qwen, .deepseek].contains(provider), provider.rawValue)
        }
    }

    @MainActor func testModelAndModeActionsUseOnlyTheirProviderFiniteIdentifiers() {
        let cases: [(EmbeddedWebModelTransport.Provider, String, String, String)] = [
            (.kimi, "discoverModels", "model_unverified", "more_checked_count"),
            (.qwen, "verifyModel", "model_unverified", "model_menu"),
            (.qwen, "inspect", "conversation_changed", "response_actions"),
            (.deepseek, "discoverModes", "mode_unverified", "mode_toggle"),
            (.deepseek, "selectMode", "mode_mismatch", "search_control"),
            (.deepseek, "verifyMode", "mode_unverified", "deepthink_control_label"),
            (.deepseek, "inspect", "composer_unavailable", "composer_scope"),
        ]
        for (provider, action, error, detail) in cases {
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": error, "detail": detail], provider: provider, action: action),
                "action=\(action) error=\(error) detail=\(detail)")
        }
        XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
            ["error": "mode_unverified", "detail": "mode_toggle"], provider: .qwen, action: "selectMode"),
            "action=other error=other detail=other")
        XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
            ["error": "model_unverified", "detail": "more_binding"], provider: .deepseek, action: "selectModel"),
            "action=other error=model_unverified detail=other")
    }

    @MainActor func testQwenDiscoveryReasonsRemainFiniteAndNeverIncludePageValues() throws {
        let details = ["initial_picker_not_closed", "initial_model_label", "initial_menu_present", "picker_expanded_invalid",
            "picker_menu_shape", "picker_menu_collapsed", "picker_menu_missing", "picker_menu_binding", "picker_menu_replaced",
            "model_choice_invalid", "model_option_disabled", "model_selected_invalid", "model_selected_contradiction",
            "model_choices_empty", "model_choices_duplicate", "model_checked_count", "picker_selected_label",
            "selection_binding", "selection_target", "picker_not_closed", "model_target_missing"]
            + ["picker_open", "picker_verify", "model_option", "picker_close"].flatMap { stage in
                ["disabled", "invalid_geometry", "outside_viewport", "occluded"].map { stage + "_" + $0 }
            }
        for detail in details {
            let diagnostic = try XCTUnwrap(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "model_unverified", "detail": detail, "label": "PRIVATE_PAGE_CANARY",
                 "url": "https://private.invalid/PRIVATE_PAGE_CANARY"], provider: .qwen, action: "discoverModels"))
            XCTAssertEqual(diagnostic, "action=discoverModels error=model_unverified detail=\(detail)")
            XCTAssertLessThan(diagnostic.utf8.count, 160)
            XCTAssertFalse(diagnostic.contains("PRIVATE_PAGE_CANARY"))
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "model_unverified", "detail": detail + " PRIVATE_PAGE_CANARY"], provider: .qwen, action: "discoverModels"),
                "action=discoverModels error=model_unverified detail=other")
        }
        XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
            ["error": "model_unverified", "detail": "picker_menu_shape"], provider: .deepseek, action: "discoverModes"),
            "action=discoverModes error=model_unverified detail=other")
    }

    @MainActor func testInternalSelectionActionsMapToFiniteDeepSeekModeDiagnostics() {
        let provider = EmbeddedWebModelTransport.Provider.deepseek
        for (internalAction, adapterAction) in [("discoverModels", "discoverModes"),
                                                ("selectModel", "selectMode"), ("verifyModel", "verifyMode")] {
            XCTAssertEqual(provider.selectionAdapterAction(internalAction), adapterAction)
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "mode_unverified", "detail": "mode_toggle"], provider: provider,
                action: provider.selectionAdapterAction(internalAction)),
                "action=\(adapterAction) error=mode_unverified detail=mode_toggle")
        }
    }

    @MainActor func testDeepSeekModeBindingFailureStagesRemainFiniteAndProviderScoped() {
        for detail in ["mode_named_input", "mode_unbound", "search_selected", "deepthink_replaced", "search_replaced", "mode_choice_changed"] {
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "mode_unverified", "detail": detail], provider: .deepseek, action: "inspect"),
                "action=inspect error=mode_unverified detail=\(detail)")
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "mode_unverified", "detail": detail], provider: .qwen, action: "inspect"),
                "action=inspect error=other detail=other")
        }
    }

    @MainActor func testDeepSeekFirstUserFailureDetailsDoNotExposePromptTextOrRelaxOtherProviders() {
        for detail in ["first_root_hidden", "first_id_invalid", "first_container_children", "first_wrapper_children", "first_container_text", "first_root_text", "first_not_submitted", "first_prompt_mismatch", "first_marker_invalid", "first_marker_mismatch", "first_marker_suffix", "first_changed_after_hash", "first_pinned_node_changed", "first_pinned_hash_mismatch", "first_expected_hash_mismatch", "first_binding_not_authorized", "first_disappeared"] {
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "conversation_changed", "detail": detail], provider: .deepseek, action: "inspect"),
                "action=inspect error=conversation_changed detail=\(detail)")
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "conversation_changed", "detail": detail], provider: .qwen, action: "inspect"),
                "action=inspect error=conversation_changed detail=other")
        }
    }

    @MainActor func testDeepSeekFirstUserClassificationAcceptsOnlyExactFiniteAliases() {
        let details = ["first_root_hidden", "first_id_invalid", "first_container_children", "first_wrapper_children",
            "first_container_text", "first_root_text", "first_not_submitted", "first_prompt_mismatch",
            "first_marker_invalid", "first_marker_mismatch", "first_marker_suffix", "first_changed_after_hash",
            "first_pinned_node_changed", "first_pinned_hash_mismatch", "first_expected_hash_mismatch",
            "first_binding_not_authorized", "first_disappeared"]
        for detail in details {
            for provider in EmbeddedWebModelTransport.Provider.allCases {
                XCTAssertEqual(EmbeddedWebModelTransport.isDeepSeekFirstUserFailure(
                    ["error": "conversation_changed", "detail": detail], provider: provider), provider == .deepseek)
            }
            for error in ["document_changed", "model_unverified", "PRIVATE_PAGE_CANARY"] {
                XCTAssertFalse(EmbeddedWebModelTransport.isDeepSeekFirstUserFailure(
                    ["error": error, "detail": detail], provider: .deepseek))
            }
            XCTAssertFalse(EmbeddedWebModelTransport.isDeepSeekFirstUserFailure(
                ["error": "conversation_changed", "detail": detail + " PRIVATE_PAGE_CANARY"], provider: .deepseek))
        }
        let malformed: [Any] = ["first_unknown", "first_user_message", true, ["private": "PRIVATE_PAGE_CANARY"]]
        for detail in malformed {
            XCTAssertFalse(EmbeddedWebModelTransport.isDeepSeekFirstUserFailure(
                ["error": "conversation_changed", "detail": detail], provider: .deepseek))
        }
        XCTAssertFalse(EmbeddedWebModelTransport.isDeepSeekFirstUserFailure(["error": "conversation_changed"], provider: .deepseek))
    }

    private func nullDeepSeekModeObservation() -> [String: Any] {
        ["modeEvidence": NSNull(), "modeObservationDiagnostic": ["version": 1, "reason": "deepthink_replaced", "required": false,
            "boundSelectionPresent": true, "boundMode": "chat", "deepThinkSelected": false, "searchSelected": false,
            "deepThinkSameNode": false, "searchSameNode": true, "modeMatches": true,
            "deepThinkWasConnected": false, "searchWasConnected": true,
            "composerSameNode": true, "composerWasConnected": true, "firstBodyBound": false]]
    }

    @MainActor func testDeepSeekNullAndRequiredModeDiagnosticsPreserveFiniteFailureReason() throws {
        let original = nullDeepSeekModeObservation()
        let raw = try XCTUnwrap(EmbeddedWebModelTransport.deepSeekModeObservationDiagnostic(original, provider: .deepseek))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(value["reason"] as? String, "deepthink_replaced")
        XCTAssertEqual(value["modeMatches"] as? Bool, true)
        XCTAssertEqual(value["searchSelected"] as? Bool, false)
        XCTAssertLessThanOrEqual(raw.utf8.count, 768)
        var required = original; var packet = try XCTUnwrap(original["modeObservationDiagnostic"] as? [String: Any])
        packet["required"] = true; required["modeObservationDiagnostic"] = packet
        required["error"] = "mode_unverified"; required["detail"] = "deepthink_replaced"
        XCTAssertNotNil(EmbeddedWebModelTransport.deepSeekModeObservationDiagnostic(required, provider: .deepseek))
        XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(required, provider: .deepseek, action: "inspect"),
                       "action=inspect error=mode_unverified detail=deepthink_replaced")
        required["detail"] = "search_replaced"
        XCTAssertNil(EmbeddedWebModelTransport.deepSeekModeObservationDiagnostic(required, provider: .deepseek))
        for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .deepseek {
            XCTAssertNil(EmbeddedWebModelTransport.deepSeekModeObservationDiagnostic(original, provider: provider))
        }
        var positive = original; positive["modeEvidence"] = ["selected": ["key": "chat", "label": "Chat"]]
        XCTAssertNil(EmbeddedWebModelTransport.deepSeekModeObservationDiagnostic(positive, provider: .deepseek))
    }

    @MainActor func testDeepSeekModeObservationRejectsPrivateFieldsMalformedFlagsAndContradictoryReasons() throws {
        let original = nullDeepSeekModeObservation()
        let packet = try XCTUnwrap(original["modeObservationDiagnostic"] as? [String: Any])
        let changes: [(String, Any)] = [("version", true), ("version", 2), ("reason", "PRIVATE_CANARY"),
            ("reason", "search_replaced"), ("boundMode", "PRIVATE_CANARY"), ("boundMode", "absent"),
            ("required", 0), ("deepThinkSelected", "false"), ("searchSelected", true),
            ("deepThinkSameNode", true), ("modeMatches", NSNull()), ("url", "https://private.invalid/PRIVATE_CANARY")]
        for (key, value) in changes {
            var invalid = packet; invalid[key] = value
            var observed = original; observed["modeObservationDiagnostic"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.deepSeekModeObservationDiagnostic(observed, provider: .deepseek), key)
        }
        for key in packet.keys {
            var invalid = packet; invalid.removeValue(forKey: key)
            var observed = original; observed["modeObservationDiagnostic"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.deepSeekModeObservationDiagnostic(observed, provider: .deepseek), key)
        }
        var observed = original
        observed["text"] = "PRIVATE_CANARY"; observed["url"] = "https://private.invalid/PRIVATE_CANARY"
        XCTAssertFalse(try XCTUnwrap(EmbeddedWebModelTransport.deepSeekModeObservationDiagnostic(observed, provider: .deepseek)).contains("PRIVATE_CANARY"))
    }

    private func firstContainerFailure() -> [String: Any] {
        ["error": "conversation_changed", "detail": "first_container_children",
         "firstContainerDiagnostic": ["version": 1, "containerChildren": 2, "wrapperChildren": 1, "bodyChildren": 0,
             "rootEqualsBody": true, "containerEqualsBody": true, "rootEmpty": false,
             "containerEmpty": false, "bodyEmpty": false, "childrenOmitted": false,
             "children": [["tag": "DIV", "children": 1, "empty": false, "containsBody": true],
                          ["tag": "BUTTON", "children": 0, "empty": true, "containsBody": false]]]]
    }

    @MainActor func testDeepSeekFirstContainerMetadataIsFiniteFailureOnlyAndProviderScoped() throws {
        let observed = firstContainerFailure()
        let records = try XCTUnwrap(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(observed, provider: .deepseek))
        XCTAssertEqual(records.count, 3)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[0].utf8)) as? [String: Any])
        XCTAssertEqual(summary["containerChildren"] as? Int, 2)
        XCTAssertEqual(summary["rootEqualsBody"] as? Bool, true)
        for record in records { XCTAssertLessThanOrEqual(record.utf8.count, 512) }
        for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .deepseek {
            XCTAssertNil(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(observed, provider: provider))
        }
        for (key, value) in [("error", "document_changed"), ("detail", "first_container_text")] {
            var other = observed; other[key] = value
            XCTAssertNil(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(other, provider: .deepseek))
        }
        var textMismatch = observed
        var packet = try XCTUnwrap(observed["firstContainerDiagnostic"] as? [String: Any])
        packet["rootEqualsBody"] = false; packet["containerEqualsBody"] = false
        textMismatch["firstContainerDiagnostic"] = packet
        let mismatch = try XCTUnwrap(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(textMismatch, provider: .deepseek))
        XCTAssertTrue(mismatch[0].contains("\"containerEqualsBody\":false"))
        XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(textMismatch, provider: .deepseek, action: "inspect"),
                       "action=inspect error=conversation_changed detail=first_container_children")
        XCTAssertTrue(EmbeddedWebModelTransport.isDeepSeekFirstUserFailure(textMismatch, provider: .deepseek))
    }

    @MainActor func testDeepSeekFirstContainerMetadataRejectsPrivateAndMalformedPacketFields() throws {
        let original = firstContainerFailure()
        let packet = try XCTUnwrap(original["firstContainerDiagnostic"] as? [String: Any])
        let changes: [(String, Any)] = [("version", true), ("version", 2), ("containerChildren", true),
            ("containerChildren", 1), ("containerChildren", 17), ("containerChildren", 2.5), ("wrapperChildren", -1),
            ("bodyChildren", 1), ("rootEqualsBody", 1), ("containerEqualsBody", "true"), ("bodyEmpty", NSNull()),
            ("childrenOmitted", true), ("private", "PRIVATE_PAGE_CANARY"), ("children", [])]
        for (key, value) in changes {
            var malformed = packet; malformed[key] = value
            var observed = original; observed["firstContainerDiagnostic"] = malformed
            XCTAssertNil(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(observed, provider: .deepseek), key)
        }
        let children = try XCTUnwrap(packet["children"] as? [[String: Any]])
        for (key, value) in [("tag", "PRIVATE_PAGE_CANARY" as Any), ("tag", "div" as Any), ("children", true as Any),
                              ("children", 17 as Any), ("empty", 0 as Any), ("containsBody", "true" as Any),
                              ("url", "https://private.invalid/PRIVATE_PAGE_CANARY" as Any)] {
            var rows = children; rows[1][key] = value
            var malformed = packet; malformed["children"] = rows
            var observed = original; observed["firstContainerDiagnostic"] = malformed
            XCTAssertNil(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(observed, provider: .deepseek), key)
        }
        for key in packet.keys {
            var malformed = packet; malformed.removeValue(forKey: key)
            var observed = original; observed["firstContainerDiagnostic"] = malformed
            XCTAssertNil(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(observed, provider: .deepseek), key)
        }
        var capped = packet
        capped["containerChildren"] = 16; capped["wrapperChildren"] = 16; capped["childrenOmitted"] = true
        capped["children"] = [children[0], children[1], children[1], children[1]]
        var observed = original; observed["firstContainerDiagnostic"] = capped
        XCTAssertEqual(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(observed, provider: .deepseek)?.count, 5)
        observed["text"] = "PRIVATE_PAGE_CANARY"; observed["url"] = "https://private.invalid/PRIVATE_PAGE_CANARY"
        let records = try XCTUnwrap(EmbeddedWebModelTransport.deepSeekFirstContainerDiagnosticRecords(observed, provider: .deepseek))
        XCTAssertFalse(records.joined().contains("PRIVATE_PAGE_CANARY"))
    }

    @MainActor func testPrivateOrMalformedValuesNeverEnterTheDiagnosticAndOutputRemainsBounded() throws {
        let privateValues = ["PRIVATE_PAGE_CANARY", "https://private.invalid/?token=PRIVATE_PAGE_CANARY",
            "model_unverified\nPRIVATE_PAGE_CANARY", String(repeating: "PRIVATE_PAGE_CANARY", count: 512)]
        for provider in [EmbeddedWebModelTransport.Provider.kimi, .qwen, .deepseek] {
            for value in privateValues {
                let diagnostic = try XCTUnwrap(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                    ["error": value, "detail": value, "text": value, "url": value, "exception": value],
                    provider: provider, action: value))
                XCTAssertEqual(diagnostic, "action=other error=other detail=other")
                XCTAssertLessThan(diagnostic.utf8.count, 160)
                XCTAssertFalse(diagnostic.contains("PRIVATE_PAGE_CANARY"))
            }
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "document_changed", "detail": ["private": "PRIVATE_PAGE_CANARY"]], provider: provider, action: "inspect"),
                "action=inspect error=document_changed detail=absent")
            XCTAssertNil(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(["pending": true], provider: provider, action: "inspect"))
            XCTAssertNil(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(["error": true], provider: provider, action: "inspect"))
        }
    }

    @MainActor func testKimiMoreReasonsAreExactFiniteLabelsAndRemainProviderScoped() throws {
        for detail in ["more_trigger_changed", "more_label_changed", "more_aria_links_changed", "more_center_changed",
                       "more_center_occluded", "more_point_outside", "more_event_coordinates",
                       "more_event_point_outside", "more_event_point_occluded", "more_initial_expansion", "more_close_policy"] {
            let diagnostic = try XCTUnwrap(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "model_unverified", "detail": detail], provider: .kimi, action: "discoverModels"))
            XCTAssertEqual(diagnostic, "action=discoverModels error=model_unverified detail=\(detail)")
            XCTAssertLessThan(diagnostic.utf8.count, 160)
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "model_unverified", "detail": detail], provider: .qwen, action: "discoverModels"),
                "action=discoverModels error=model_unverified detail=other")
        }
        for detail in ["more_center_changed_PRIVATE_PAGE_CANARY", "more_trigger_changed https://private.invalid",
                       "more_aria_links_changed\nPRIVATE_PAGE_CANARY"] {
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "model_unverified", "detail": detail], provider: .kimi, action: "discoverModels"),
                "action=discoverModels error=model_unverified detail=other")
        }
    }

    @MainActor func testKimiPickerCloseReasonsAreFiniteAndProviderScoped() {
        for detail in ["picker_menu_ambiguous", "picker_menu_labelledby", "picker_menu_scope", "picker_menu_expansion",
                       "option_close_binding", "option_close_selection"] {
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error":"model_unverified", "detail":detail], provider:.kimi, action:"inspect"),
                "action=inspect error=model_unverified detail=\(detail)")
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error":"model_unverified", "detail":detail], provider:.qwen, action:"inspect"),
                "action=inspect error=model_unverified detail=other")
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error":"model_unverified", "detail":detail + " PRIVATE_PAGE_CANARY"], provider:.kimi, action:"inspect"),
                "action=inspect error=model_unverified detail=other")
        }
    }

    @MainActor func testKimiCompatibilityEntryPointKeepsTheExistingFiniteResult() {
        let value: [String: Any] = ["error": "model_unverified", "detail": "picker_close_occluded"]
        XCTAssertEqual(EmbeddedWebModelTransport.kimiAdapterFailureDiagnostic(value, action: "discoverModels"),
            "action=discoverModels error=model_unverified detail=picker_close_occluded")
        XCTAssertEqual(EmbeddedWebModelTransport.kimiAdapterFailureDiagnostic(value, action: "discoverModels"),
            EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(value, provider: .kimi, action: "discoverModels"))
    }
    @MainActor func testKimiEditorHitReasonsAreFiniteAndProviderScoped() {
        for reason in ["disabled", "invalid_geometry", "outside_viewport", "ancestor_limit", "ancestor_changed", "outside_clip", "occluded"] {
            let detail = "editor_hit_" + reason
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "composer_unavailable", "detail": detail], provider: .kimi, action: "sendReady"),
                "action=sendReady error=composer_unavailable detail=\(detail)")
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "composer_unavailable", "detail": detail], provider: .qwen, action: "sendReady"),
                "action=sendReady error=composer_unavailable detail=other")
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "composer_unavailable", "detail": detail + " PRIVATE_CANARY"], provider: .kimi, action: "sendReady"),
                "action=sendReady error=composer_unavailable detail=other")
        }
    }

    @MainActor func testDeepSeekRemountPendingIsExactNegativeCanonicalReceipt() {
        let url = "https://chat.deepseek.com/a/chat/s/11111111-abcd-4333-8444-555555555555"
        let valid: [String: Any] = ["deepSeekComposerHandoffPending": true, "url": url,
            "sessionLifecycle": "saved_conversation_delete", "temporary": false]
        XCTAssertTrue(EmbeddedWebModelTransport.isDeepSeekComposerHandoffPendingObservation(valid, url: url))
        for (key, value) in [("deepSeekComposerHandoffPending", 1 as Any), ("temporary", 0 as Any),
            ("text", "" as Any), ("modeEvidence", NSNull() as Any), ("userCount", 0 as Any),
            ("url", "https://chat.deepseek.com/" as Any), ("sessionLifecycle", "temporary" as Any)] {
            var invalid = valid; invalid[key] = value
            XCTAssertFalse(EmbeddedWebModelTransport.isDeepSeekComposerHandoffPendingObservation(invalid, url: url), key)
        }
        XCTAssertFalse(EmbeddedWebModelTransport.isDeepSeekComposerHandoffPendingObservation(valid,
            url: url.replacingOccurrences(of: "11111111", with: "22222222")))
        for detail in ["composer_handoff_ineligible", "composer_handoff_binding", "composer_handoff_changed"] {
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "mode_unverified", "detail": detail], provider: .deepseek, action: "inspect"),
                "action=inspect error=mode_unverified detail=\(detail)")
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "mode_unverified", "detail": detail], provider: .qwen, action: "inspect"),
                "action=inspect error=other detail=other")
        }
    }

    @MainActor func testKimiFirstUserReasonsRetainExactOwnershipClassificationAndFiniteLogging() {
        let details = ["first_body_count", "first_root_hidden", "first_root_id_invalid", "first_turn_link_mismatch", "first_body_shape",
            "first_submission_unclaimed", "first_insertion_missing", "first_full_echo_mismatch", "first_marker_invalid",
            "first_marker_mismatch", "first_marker_suffix", "first_changed_during_hash", "first_pinned_identity_changed",
            "first_pinned_fingerprint_mismatch", "first_expected_fingerprint_mismatch", "first_binding_not_authorized", "first_disappeared"]
        for detail in details {
            let error = detail == "first_body_count" ? "document_changed" : "conversation_changed"
            let observed: [String: Any] = ["error": error, "detail": detail, "text": "PRIVATE_CANARY"]
            XCTAssertTrue(EmbeddedWebModelTransport.isKimiFirstUserFailure(observed, provider: .kimi))
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(observed, provider: .kimi, action: "inspect"),
                "action=inspect error=\(error) detail=\(detail)")
            for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .kimi {
                XCTAssertFalse(EmbeddedWebModelTransport.isKimiFirstUserFailure(observed, provider: provider))
            }
            for other in ["model_unverified", "composer_unavailable", detail == "first_body_count" ? "conversation_changed" : "document_changed"] {
                XCTAssertFalse(EmbeddedWebModelTransport.isKimiFirstUserFailure(["error": other, "detail": detail], provider: .kimi))
            }
        }
        let malformed: [Any] = ["first_unknown", "first_full_echo_mismatch PRIVATE_CANARY", true, ["private": "PRIVATE_CANARY"]]
        for detail in malformed {
            XCTAssertFalse(EmbeddedWebModelTransport.isKimiFirstUserFailure(["error": "conversation_changed", "detail": detail], provider: .kimi))
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(
                ["error": "conversation_changed", "detail": detail], provider: .kimi, action: "inspect"),
                "action=inspect error=conversation_changed detail=\(detail is String ? "other" : "absent")")
        }
    }

}

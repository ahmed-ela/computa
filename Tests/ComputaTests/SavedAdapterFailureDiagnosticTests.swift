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
                       "more_center_occluded", "more_initial_expansion", "more_close_policy"] {
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

    @MainActor func testKimiCompatibilityEntryPointKeepsTheExistingFiniteResult() {
        let value: [String: Any] = ["error": "model_unverified", "detail": "picker_close_occluded"]
        XCTAssertEqual(EmbeddedWebModelTransport.kimiAdapterFailureDiagnostic(value, action: "discoverModels"),
            "action=discoverModels error=model_unverified detail=picker_close_occluded")
        XCTAssertEqual(EmbeddedWebModelTransport.kimiAdapterFailureDiagnostic(value, action: "discoverModels"),
            EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(value, provider: .kimi, action: "discoverModels"))
    }
}

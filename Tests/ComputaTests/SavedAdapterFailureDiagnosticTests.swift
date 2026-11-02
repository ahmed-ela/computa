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

    @MainActor func testKimiCompatibilityEntryPointKeepsTheExistingFiniteResult() {
        let value: [String: Any] = ["error": "model_unverified", "detail": "picker_close_occluded"]
        XCTAssertEqual(EmbeddedWebModelTransport.kimiAdapterFailureDiagnostic(value, action: "discoverModels"),
            "action=discoverModels error=model_unverified detail=picker_close_occluded")
        XCTAssertEqual(EmbeddedWebModelTransport.kimiAdapterFailureDiagnostic(value, action: "discoverModels"),
            EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(value, provider: .kimi, action: "discoverModels"))
    }
}

import CoreFoundation
import Foundation
import XCTest
@testable import Computa

final class WebsiteModeEvidenceTests: XCTestCase {
    private let chat = WebsiteModeChoice(deepSeekMode: .chat)
    private let deepthink = WebsiteModeChoice(deepSeekMode: .deepthink)

    private func raw(_ choice: WebsiteModeChoice) -> [String: Any] {
        ["selected": choice.dictionary, "source": "website_mode_toggle", "backendModel": NSNull(), "search": false]
    }

    func testBothObservedModesKeepExplicitUnknownBackendAndSearchOffAfterRoundTrip() throws {
        for choice in [chat, deepthink] {
            let evidence = try WebsiteModeEvidence.parse(raw(choice), provider: "deepseek", expected: choice)
            XCTAssertEqual(evidence.selected, choice)
            let bytes = try JSONSerialization.data(withJSONObject: evidence.dictionary)
            let restored = try JSONSerialization.jsonObject(with: bytes)
            XCTAssertEqual(try WebsiteModeEvidence.parse(restored, provider: "deepseek", expected: choice), evidence)
            XCTAssertTrue(evidence.dictionary["backendModel"] is NSNull)
            XCTAssertEqual(evidence.dictionary["source"] as? String, "website_mode_toggle")
            XCTAssertNil(evidence.dictionary["response"])
            XCTAssertNil(evidence.dictionary["verification"])
            let search = try XCTUnwrap(evidence.dictionary["search"] as? NSNumber)
            XCTAssertEqual(CFGetTypeID(search), CFBooleanGetTypeID())
            XCTAssertFalse(search.boolValue)
        }
    }

    func testModesRequireExactNamesAndDistinctTypedTransportIdentity() {
        for choice in [chat, deepthink] {
            XCTAssertEqual(WebsiteModeChoice.parse(requestID: choice.requestID), choice)
            XCTAssertEqual(WebsiteModeChoice.parse(choice.dictionary, provider: "deepseek"), choice)
            XCTAssertNil(WebsiteModeChoice.parse(choice.dictionary, provider: "qwen"))
            XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: choice.requestID)?.modeChoice, choice)
            XCTAssertEqual(WebsiteModelCatalog.selection(for: choice.requestID)?.modeChoice, choice)
            XCTAssertNil(WebsiteModelCatalog.selection(for: choice.requestID)?.choice)
            XCTAssertEqual(WebsiteModelCatalog.option(for: choice, available: true).available, true)
        }
        XCTAssertTrue(WebsiteModelCatalog.providers.contains("deepseek"))
        for id in ["browser/deepseek", "browser/deepseek/mode/Chat", "browser/deepseek/mode/deepthink ",
                   "browser/deepseek/mode/%63hat", "browser/deepseek/mode/chat/", "browser/deepseek/choice/chat",
                   "browser/qwen/mode/chat", "browser/deepseek/mode/chat?search=false"] {
            XCTAssertNil(WebsiteModeChoice.parse(requestID: id), id)
        }
        for selection in [["key": "chat", "label": "DeepThink"],
                                        ["key": "deepthink", "label": "DeepSeek V3"],
                                        ["key": "Chat", "label": "Chat"],
                                        ["key": "chat", "label": "Chat", "model": "invented"],
                                        ["key": "chat"], ["key": 0, "label": "Chat"]] as [[String: Any]] {
            XCTAssertNil(WebsiteModeChoice.parse(selection, provider: "deepseek"))
        }
    }

    func testMissingExtraPrivateAndFalselyAttestedModeFieldsAreRejected() throws {
        let original = raw(chat)
        var invalid: [Any?] = [nil, NSNull(), [], "Chat", [:]]
        for key in original.keys {
            var missing = original; missing.removeValue(forKey: key); invalid.append(missing)
        }
        let changes: [[String: Any]] = [
            ["source": "model_picker_label"], ["source": "selected_model_indicator"],
            ["source": "website_mode_toggle "], ["backendModel": "DeepSeek V3"],
            ["backendModel": false], ["search": true], ["search": 0], ["search": "false"], ["search": NSNull()],
            ["verification": "response_reported"], ["response": ["model": "invented"]],
            ["pageText": "PRIVATE_CANARY_NEVER_RETAIN"], ["selected": ["key": "chat", "label": "DeepThink"]]
        ]
        invalid += changes.map { original.merging($0) { _, new in new } }
        for item in invalid {
            XCTAssertThrowsError(try WebsiteModeEvidence.parse(item, provider: "deepseek", expected: chat))
        }
        XCTAssertThrowsError(try WebsiteModeEvidence.parse(original, provider: "claude", expected: chat))
    }

    func testModeMismatchIsDistinctAndCannotRepairSearchOrPinnedMode() throws {
        XCTAssertThrowsError(try WebsiteModeEvidence.parse(raw(deepthink), provider: "deepseek", expected: chat)) {
            guard case WebsiteModeEvidence.Failure.mismatch = $0 else { return XCTFail("Wrong failure: \($0)") }
        }
        let first = try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": raw(chat)], intent: .mode(chat))
        let changed = try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": raw(deepthink)], intent: .mode(deepthink))
        XCTAssertFalse(first.isSameResolvedSelection(as: changed))
        var searchEnabled = raw(chat); searchEnabled["search"] = true
        XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": searchEnabled], intent: .mode(chat)))
        XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": raw(deepthink)], intent: .mode(chat))) {
            guard case WebsiteSelectionEvidence.Failure.mismatch = $0 else { return XCTFail("Wrong failure: \($0)") }
        }
    }

    func testProofKindsCannotBeSwappedOrCombinedIncludingNullForeignFields() throws {
        let choice = WebsiteModelChoice(provider: "claude", key: "fixture-model", label: "Fixture Model")
        let model: [String: Any] = ["selected": ["key": choice.key, "label": choice.label],
                                   "verification": "website_selection", "source": "selected_model_indicator"]
        let nativeModel = try WebsiteModelEvidence.parse(model, provider: "claude", expected: choice)
        let typedModel = try WebsiteSelectionEvidence.parse(snapshot: ["modelEvidence": model], intent: .model(choice))
        XCTAssertEqual(typedModel, .model(nativeModel))
        XCTAssertTrue(typedModel.isSameResolvedSelection(as: .model(nativeModel)))
        let typedMode = try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": raw(chat)], intent: .mode(chat))
        XCTAssertFalse(typedMode.isSameResolvedSelection(as: typedModel))
        for opposite in [model, NSNull()] as [Any] {
            XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": raw(chat), "modelEvidence": opposite], intent: .mode(chat)))
        }
        for opposite in [raw(chat), NSNull()] as [Any] {
            XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modelEvidence": model, "modeEvidence": opposite], intent: .model(choice)))
        }
        XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modelEvidence": model], intent: .mode(chat)))
        XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": raw(chat)], intent: .model(choice)))
        let fakeModel = WebsiteModelChoice(provider: "deepseek", key: "chat", label: "Chat")
        XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modelEvidence": model], intent: .model(fakeModel)))
        var changedModel = model; changedModel["selected"] = ["key": "other", "label": "Other"]
        XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modelEvidence": changedModel], intent: .model(choice))) {
            guard case WebsiteSelectionEvidence.Failure.mismatch = $0 else { return XCTFail("Wrong failure: \($0)") }
        }
    }

    func testModeDispatchUsesOnlyExplicitModeActionsAndExpectedChoice() {
        let intent = WebsiteSelectionIntent.mode(deepthink)
        XCTAssertEqual(intent.provider, "deepseek")
        XCTAssertEqual(intent.discoveryAction, "discoverModes")
        XCTAssertEqual(intent.selectAction, "selectMode")
        XCTAssertEqual(intent.verifyAction, "verifyMode")
        XCTAssertEqual(Set(intent.expectedAdapterInput.keys), ["expectedModeChoice"])
        XCTAssertEqual(intent.expectedAdapterInput["expectedModeChoice"] as? [String: String], deepthink.dictionary)
        XCTAssertEqual(Set(intent.selectAdapterInput.keys), ["modeChoice"])
        XCTAssertEqual(intent.selectAdapterInput["modeChoice"] as? [String: String], deepthink.dictionary)
        let choice = WebsiteModelChoice(provider: "claude", key: "fixture", label: "Fixture")
        let old = WebsiteSelectionIntent.model(choice)
        XCTAssertEqual([old.discoveryAction, old.selectAction, old.verifyAction], ["discoverModels", "selectModel", "verifyModel"])
        XCTAssertEqual(Set(old.expectedAdapterInput.keys), ["expectedModelChoice"])
        XCTAssertEqual(Set(old.selectAdapterInput.keys), ["modelChoice"])
    }

    func testModeResponseMetadataCannotRetainAClientFabricatedBackendClaim() throws {
        let evidence = try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": raw(chat)], intent: .mode(chat))
        let metadata = evidence.responseMetadata(preserving: ["client_tag": "preserved",
            "computa_website_model": ["backendModel": "PRIVATE_CANARY_NEVER_RETAIN"],
            "computa_website_mode": ["backendModel": "invented"]])
        XCTAssertEqual(metadata["client_tag"] as? String, "preserved")
        XCTAssertNil(metadata["computa_website_model"])
        XCTAssertEqual(evidence.snapshotField, "modeEvidence")
        XCTAssertEqual(evidence.responseMetadataField, "computa_website_mode")
        XCTAssertEqual(try WebsiteModeEvidence.parse(metadata["computa_website_mode"], provider: "deepseek", expected: chat).selected, chat)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_CANARY")); XCTAssertFalse(encoded.contains("invented"))
    }
    func testModeStartEncodingIsCanonicalAndCannotCarryProviderModelAliases() throws {
        for choice in [chat, deepthink] {
            XCTAssertEqual(WebsiteModeChoice.parse(choice.canonicalJSONString), choice)
            for invalid in [" " + choice.canonicalJSONString, choice.canonicalJSONString + "\n",
                            choice.canonicalJSONString.replacingOccurrences(of: "deepseek", with: "qwen"),
                            choice.canonicalJSONString.replacingOccurrences(of: "Chat", with: "DeepSeek V3"),
                            #"{"provider":"deepseek","key":"chat","label":"Chat","backendModel":"invented"}"#] {
                if invalid != choice.canonicalJSONString { XCTAssertNil(WebsiteModeChoice.parse(invalid)) }
            }
        }
        XCTAssertFalse(WebsiteModelChoice(provider: "deepseek", key: "chat", label: "Chat").isValid)
    }

    func testOldDefaultModelProofStillResolvesButCannotAcceptAnInjectedModeProof() throws {
        let rawModel: [String: Any] = ["selected": ["key": "fixture", "label": "Fixture"],
            "verification": "website_selection", "source": "selected_model_indicator"]
        let original = try WebsiteModelEvidence.parse(rawModel, provider: "claude")
        XCTAssertEqual(try WebsiteSelectionEvidence.parse(snapshot: ["modelEvidence": rawModel], provider: "claude",
            expectedModel: nil, expectedMode: nil), .model(original))
        XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modelEvidence": rawModel, "modeEvidence": NSNull()],
            provider: "claude", expectedModel: nil, expectedMode: nil))
        XCTAssertThrowsError(try WebsiteSelectionEvidence.parse(snapshot: ["modeEvidence": raw(chat)], provider: "deepseek",
            expectedModel: nil, expectedMode: nil), "A page cannot resolve an implicit DeepSeek mode")
    }

}

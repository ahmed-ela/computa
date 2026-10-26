import Foundation
import XCTest
@testable import Computa

final class ChatGPTChatSelectionTests: XCTestCase {
    func testFiveChatPresetsRoundTripAndRequireExplicitInferenceChoice() throws {
        for power in WebsiteModelChoice.ChatGPTPower.allCases {
            let choice = preset(power)
            XCTAssertTrue(choice.isSelectable)
            XCTAssertEqual(choice.isObservedChoice, power != .pro)
            XCTAssertEqual(WebsiteModelChoice.parse(try XCTUnwrap(choice.canonicalJSONString)), choice)
            XCTAssertEqual(WebsiteModelCatalog.choice(for: choice.modelID), choice)
            XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: choice.modelID)?.choice, choice)
        }
        XCTAssertNotNil(WebsiteModelCatalog.selection(for: "browser/chatgpt"))
        XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: "browser/chatgpt"))
        for provider in ["gemini", "claude"] {
            XCTAssertNotNil(WebsiteModelCatalog.inferenceSelection(for: "browser/" + provider))
            let choice = WebsiteModelChoice(provider: provider, key: "Latest", label: "Latest")
            XCTAssertTrue(choice.isSelectable)
            XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: choice.modelID)?.choice, choice)
        }
    }

    func testFamilyAndMalformedPresetIDsRemainHistoricalButCannotBeAdmitted() {
        let retired = [
            WebsiteModelChoice(provider: "chatgpt", key: "GPT-6", label: "GPT-6"),
            WebsiteModelChoice(provider: "chatgpt", key: "GPT-5.6 Sol", label: "GPT-5.6 Sol"),
            WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Latest"),
            WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/unknown", label: "Unknown"),
            WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "High"),
            WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/pro", label: "GPT-5.6 Sol Pro"),
            WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/pro", label: "GPT-6Pro"),
        ]
        for choice in retired {
            XCTAssertTrue(choice.isValid)
            XCTAssertTrue(choice.isRetired)
            XCTAssertEqual(WebsiteModelCatalog.choice(for: choice.modelID), choice)
            XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: choice.modelID))
            XCTAssertEqual(WebsiteModelCatalog.option(for: choice).available, false)
        }
    }

    func testPriorCacheDropsOnlyChatEntriesAndDoesNotInventFreshAvailability() throws {
        for oldKey in [WebsiteModelCatalog.priorPreferenceKey, WebsiteModelCatalog.legacyPreferenceKey] {
            let preferences = isolatedTestPreferences()
            let others = [WebsiteModelChoice(provider: "gemini", key: "3.1 Pro", label: "3.1 Pro"),
                          WebsiteModelChoice(provider: "claude", key: "Sonnet 5.5", label: "Sonnet 5.5")]
            let old = WebsiteModelChoice(provider: "chatgpt", key: "GPT-6", label: "GPT-6")
            preferences.set(try JSONEncoder().encode([old, preset(.medium)] + others), forKey: oldKey)
            XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), others)
            let saved = try XCTUnwrap(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
            XCTAssertEqual(try JSONDecoder().decode([WebsiteModelChoice].self, from: saved), others)
            XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), others)
            XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), saved)
        }
    }

    func testObservedProFamilyLabelDoesNotPinTheNextInferenceToThatFamily() throws {
        let six = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/pro", label: "GPT-6 Pro")
        let seven = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/pro", label: "GPT-7 Pro")
        let intent = preset(.pro)
        XCTAssertTrue(six.isObservedChoice)
        XCTAssertTrue(seven.isObservedChoice)
        XCTAssertFalse(intent.isObservedChoice)
        XCTAssertEqual(WebsiteModelCatalog.option(for: intent).available, false)
        XCTAssertNoThrow(try WebsiteModelCatalog.validateObserved([seven], provider: "chatgpt"))
        XCTAssertThrowsError(try WebsiteModelCatalog.validateObserved([intent], provider: "chatgpt"))
        XCTAssertEqual(six.modelID, seven.modelID)
        XCTAssertEqual(six.canonicalJSONString, seven.canonicalJSONString)
        XCTAssertEqual(WebsiteModelCatalog.choice(for: six.modelID)?.label, "Pro")
        XCTAssertEqual(WebsiteModelChoice.parse(try XCTUnwrap(six.canonicalJSONString))?.label, "Pro")
        let preferences = isolatedTestPreferences()
        WebsiteModelCatalog.save([seven], to: preferences)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [seven])
        XCTAssertTrue(WebsiteModelCatalog.option(for: seven).label.contains("GPT-7 Pro"))
        let selected = try XCTUnwrap(WebsiteModelCatalog.inferenceSelection(for: six.modelID)?.choice)
        XCTAssertNoThrow(try WebsiteModelEvidence.parse(evidence(selected, family: "GPT-7", offered: ["GPT-7", "GPT-6"]),
                                                      provider: "chatgpt", expected: selected))
        WebsiteModelCatalog.save([intent, preset(.medium)], to: preferences)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [preset(.medium)],
                       "An inference intent cannot create cached Pro availability")
        preferences.set(try JSONEncoder().encode([intent, preset(.medium)]), forKey: WebsiteModelCatalog.preferenceKey)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [preset(.medium)])
        let pruned = try XCTUnwrap(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
        XCTAssertEqual(try JSONDecoder().decode([WebsiteModelChoice].self, from: pruned), [preset(.medium)])
    }

    func testMigrationDoesNotHideDuplicateRetiredEntries() throws {
        let preferences = isolatedTestPreferences()
        let old = WebsiteModelChoice(provider: "chatgpt", key: "GPT-6", label: "GPT-6")
        let original = try JSONEncoder().encode([old, old])
        preferences.set(original, forKey: WebsiteModelCatalog.priorPreferenceKey)
        XCTAssertTrue(WebsiteModelCatalog.load(from: preferences).isEmpty)
        XCTAssertNil(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
        XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.priorPreferenceKey), original)
        let observed = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/pro", label: "GPT-6 Pro")
        let duplicatedPro = try JSONEncoder().encode([preset(.pro), observed])
        preferences.set(duplicatedPro, forKey: WebsiteModelCatalog.preferenceKey)
        XCTAssertTrue(WebsiteModelCatalog.load(from: preferences).isEmpty,
                      "Pruning a policy intent must not hide a duplicate raw Pro key")
        XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), duplicatedPro)
        WebsiteModelCatalog.save([preset(.pro), observed], to: preferences)
        XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), duplicatedPro)
    }

    func testHighestFamilyUsesNumericComponentsAndRejectsAmbiguousOrSuffixedMenus() {
        XCTAssertEqual(WebsiteModelCatalog.highestOfferedPlainGPTFamily(["GPT-9.9", "GPT-10", "GPT-6"]), "GPT-10")
        XCTAssertEqual(WebsiteModelCatalog.highestOfferedPlainGPTFamily(["GPT-6.9", "GPT-6.10"]), "GPT-6.10")
        XCTAssertEqual(WebsiteModelCatalog.highestOfferedPlainGPTFamily(["GPT-999999999999999999999", "GPT-10"]), "GPT-999999999999999999999")
        for invalid in [[], ["GPT-6", "GPT-6"], ["GPT-6", "GPT-6.0"], ["GPT-6", "GPT-5.6 Sol"],
                        ["GPT-06"], ["GPT-0"], ["GPT-6."], ["GPT-6.01"], ["GPT-6..1"], ["GPT-6 Work"],
                        ["Latest"], ["GPT-６"], ["GPT-6\n"], [String(repeating: "9", count: 129)]] {
            XCTAssertNil(WebsiteModelCatalog.highestOfferedPlainGPTFamily(invalid), "\(invalid)")
        }
        XCTAssertNil(WebsiteModelCatalog.highestOfferedPlainGPTFamily((1...33).map { "GPT-\($0)" }))
    }

    func testChatEvidenceBindsBothDimensionsAndPreservesWeakerWebsiteVerification() throws {
        for power in WebsiteModelChoice.ChatGPTPower.allCases {
            let choice = preset(power)
            let raw = evidence(choice, family: "GPT-6", offered: ["GPT-6", "GPT-5.5"])
            let parsed = try WebsiteModelEvidence.parse(raw, provider: "chatgpt", expected: choice)
            XCTAssertEqual(parsed.chatSelection?.family.label, "GPT-6")
            XCTAssertEqual(parsed.chatSelection?.power.key, power.rawValue)
            XCTAssertEqual(parsed.verification, "website_selection")
            XCTAssertNil(parsed.response)
            XCTAssertEqual(try WebsiteModelEvidence.parse(parsed.dictionary, provider: "chatgpt", expected: choice), parsed)
        }
    }

    func testStableMediumIdentityCannotHideResolvedFamilyOrPowerDrift() throws {
        let choice = preset(.medium)
        let first = try WebsiteModelEvidence.parse(evidence(choice, family: "GPT-6", offered: ["GPT-6", "GPT-5.5"]), provider: "chatgpt", expected: choice)
        let lowerAdded = try WebsiteModelEvidence.parse(evidence(choice, family: "GPT-6", offered: ["GPT-5.5", "GPT-6", "GPT-4"]), provider: "chatgpt", expected: choice)
        XCTAssertTrue(first.isSameResolvedSelection(as: lowerAdded))
        let changedFamily = try WebsiteModelEvidence.parse(evidence(choice, family: "GPT-7", offered: ["GPT-7", "GPT-6"]), provider: "chatgpt", expected: choice)
        XCTAssertFalse(first.isSameResolvedSelection(as: changedFamily))
        let changedPower = try WebsiteModelEvidence.parse(evidence(preset(.high), family: "GPT-6", offered: ["GPT-6"]), provider: "chatgpt", expected: preset(.high))
        XCTAssertFalse(first.isSameResolvedSelection(as: changedPower))
    }

    func testMissingMalformedAndContradictoryChatContextCannotAuthorizeThePreset() {
        let choice = preset(.medium)
        let good = evidence(choice, family: "GPT-6", offered: ["GPT-6", "GPT-5.5"])
        var missing = good; missing.removeValue(forKey: "chatSelection")
        var wrongSource = good; wrongSource["source"] = "checked_model_option"
        var privateField = good; privateField["private"] = "PRIVATE_CANARY"
        for raw in [missing, wrongSource, privateField,
                    evidence(choice, family: "GPT-5.5", offered: ["GPT-6", "GPT-5.5"]),
                    evidence(choice, family: "GPT-6", offered: ["GPT-6", "GPT-6.0"])] {
            XCTAssertThrowsError(try WebsiteModelEvidence.parse(raw, provider: "chatgpt", expected: choice))
        }
        for (field, badValue) in [("family", ["key": "GPT-6", "label": "GPT-7"]),
                                  ("power", ["key": "high", "label": "High"]),
                                  ("power", ["key": "medium", "label": "High"])] {
            var raw = good
            var context = raw["chatSelection"] as! [String: Any]
            context[field] = badValue; raw["chatSelection"] = context
            XCTAssertThrowsError(try WebsiteModelEvidence.parse(raw, provider: "chatgpt", expected: choice))
        }
        var raw = good; var context = raw["chatSelection"] as! [String: Any]
        context["automaticFamily"] = ["policy": "site_latest", "offered": ["GPT-6"]]
        raw["chatSelection"] = context
        XCTAssertThrowsError(try WebsiteModelEvidence.parse(raw, provider: "chatgpt", expected: choice))
        raw = good
        raw["verification"] = "response_reported"
        raw["response"] = ["key": choice.key, "label": choice.label, "source": "response_attribute"]
        XCTAssertThrowsError(try WebsiteModelEvidence.parse(raw, provider: "chatgpt", expected: choice),
                             "Echoed synthetic preset metadata cannot attest the backend family and power")
    }

    private func preset(_ power: WebsiteModelChoice.ChatGPTPower) -> WebsiteModelChoice {
        WebsiteModelChoice(provider: "chatgpt", key: power.modelKey, label: power.label)
    }

    private func evidence(_ choice: WebsiteModelChoice, family: String, offered: [String]) -> [String: Any] {
        let power = choice.chatGPTPower!
        return ["selected": ["key": choice.key, "label": choice.label], "source": "selected_model_indicator",
                "verification": "website_selection", "chatSelection": ["family": ["key": family, "label": family],
                    "power": ["key": power.rawValue, "label": power.label],
                    "automaticFamily": ["policy": "highest_offered_plain_gpt", "offered": offered]]]
    }
}

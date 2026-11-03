import Foundation
import XCTest
@testable import Computa

final class WebsiteModelCatalogTests: XCTestCase {
    func testSharedInferenceFixturesUseSelectableChoicesForEveryNamedProvider() {
        for provider in namedWebsiteModelProviders {
            XCTAssertNotNil(WebsiteModelCatalog.inferenceSelection(for: syntheticWebsiteModelID(provider)), provider)
            for intent in ["fixture-old", "fixture-new", "fixture-fast"] {
                let choice = syntheticWebsiteChoice(provider: provider, key: intent, label: "Fixture Choice")
                XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: choice.modelID)?.choice, choice, provider)
            }
        }
    }

    func testPublicDeepSeekUsesTypedModeIdentitiesInsteadOfNamedChoicesOrDefaults() throws {
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        for kind in WebsiteModeChoice.DeepSeekMode.allCases {
            let mode = WebsiteModeChoice(deepSeekMode: kind)
            XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: mode.requestID)?.modeChoice, mode)
            XCTAssertNil(WebsiteModelCatalog.choice(for: mode.requestID))
            XCTAssertEqual(LocalModelCatalog.webProvider(for: mode.requestID), "deepseek")
            XCTAssertEqual(configuration.modelProvider(for: mode.requestID), "web_browser")
            XCTAssertNoThrow(try configuration.validateSelectedModel(mode.requestID))
            XCTAssertEqual(LocalThreadContext.forModel(mode.requestID), .webBrowser)
            XCTAssertEqual(LocalModelCatalog.option(for: mode.requestID)?.label,
                "DeepSeek / \(mode.label) · Built-in browser")
            XCTAssertFalse(WebsiteModelChoice(provider: "deepseek", key: mode.key, label: mode.label).isValid)
        }
        XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: "browser/deepseek"))
        XCTAssertNil(LocalModelCatalog.option(for: "browser/deepseek"))
    }

    func testGroqUsesObservedChoicesWithoutSeedingOrAliasingAnotherProvider() throws {
        let preferences = isolatedTestPreferences()
        XCTAssertTrue(WebsiteModelCatalog.load(from: preferences).isEmpty)
        XCTAssertEqual(WebsiteModelCatalog.providerLabel("groq"), "Groq")
        XCTAssertEqual(LocalModelCatalog.groqBrowserModelID, "browser/groq")
        XCTAssertFalse(LocalModelCatalog.options.contains { WebsiteModelCatalog.choice(for: $0.id)?.provider == "groq" },
                       "Groq model names must come from observed website discovery")
        let groq = WebsiteModelChoice(provider: "groq", key: "fixture/vendor-model", label: "Fixture Model / Exact label")
        let claude = WebsiteModelChoice(provider: "claude", key: groq.key, label: groq.label)
        XCTAssertNoThrow(try WebsiteModelCatalog.validateObserved([groq], provider: "groq"))
        XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: groq.modelID)?.choice, groq)
        XCTAssertNotEqual(groq.modelID, claude.modelID)
        WebsiteModelCatalog.save([claude, groq], to: preferences)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [claude, groq])
        XCTAssertEqual(WebsiteModelCatalog.option(for: groq).label, "Groq / Fixture Model / Exact label · Built-in browser")
        XCTAssertEqual(WebsiteModelCatalog.option(for: groq, available: false).available, false)
        XCTAssertThrowsError(try WebsiteModelCatalog.validateObserved([groq, groq], provider: "groq"))
        XCTAssertThrowsError(try WebsiteModelCatalog.validateObserved([claude], provider: "groq"))
        for malformed in ["browser/Groq", "browser/groq-like", "browser/groq/", groq.modelID + "=", groq.modelID + "/extra"] {
            XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: malformed), malformed)
        }
    }

    func testPriorCatalogDropsUnprovenChatGPTAndClaudeChoicesBeforeGuardedRefresh() throws {
        let preferences = isolatedTestPreferences()
        let normalLabelAlsoOfferedInWork = WebsiteModelChoice(provider: "chatgpt", key: "GPT-5.5", label: "GPT-5.5")
        let others = [WebsiteModelChoice(provider: "gemini", key: "3.1 Pro", label: "3.1 Pro"),
                      WebsiteModelChoice(provider: "claude", key: "Sonnet 5.5", label: "Sonnet 5.5")]
        preferences.set(try JSONEncoder().encode([normalLabelAlsoOfferedInWork] + others), forKey: WebsiteModelCatalog.legacyPreferenceKey)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [others[0]])
        XCTAssertNotNil(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
        WebsiteModelCatalog.save([normalLabelAlsoOfferedInWork] + others, to: preferences)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), others,
                       "A family-only choice no longer proves a Chat power preset")
    }

    func testV3ClaudeRequiresFreshRowsWhileChatPresetsAndOtherProvidersSurvive() throws {
        let preferences = isolatedTestPreferences()
        let fable = WebsiteModelChoice(provider: "claude", key: "Fable 5.1", label: "Fable 5.1")
        let opus = WebsiteModelChoice(provider: "claude", key: "Opus 5", label: "Opus 5")
        let others = [WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium"),
                      WebsiteModelChoice(provider: "groq", key: "test", label: "Test")]
        let prior = try JSONEncoder().encode([fable, opus] + others)
        preferences.set(prior, forKey: WebsiteModelCatalog.priorSelectableRowsPreferenceKey)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), others)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), others)
        XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.priorSelectableRowsPreferenceKey), prior)
        XCTAssertEqual(WebsiteModelCatalog.choice(for: fable.modelID), fable)
        XCTAssertEqual(WebsiteModelCatalog.option(for: fable, available: false).available, false)
        WebsiteModelCatalog.save(others + [fable, opus], to: preferences)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), others + [fable, opus])
    }

    func testLegacyCatalogValidationCannotBeHiddenByProductMigration() throws {
        let preferences = isolatedTestPreferences()
        let duplicate = WebsiteModelChoice(provider: "chatgpt", key: "same", label: "Same")
        let raw = try JSONEncoder().encode([duplicate, duplicate])
        preferences.set(raw, forKey: WebsiteModelCatalog.legacyPreferenceKey)
        XCTAssertTrue(WebsiteModelCatalog.load(from: preferences).isEmpty)
        XCTAssertNil(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
        XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.legacyPreferenceKey), raw)
    }

    func testConcreteChoicesRoundTripWithoutARegisteredOrGuessedModelList() throws {
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        for provider in namedWebsiteModelProviders {
            let choice = provider == "chatgpt"
                ? WebsiteModelChoice(provider: provider, key: "chat/latest/medium", label: "Medium")
                : provider == "kimi" ? WebsiteModelChoice(provider: provider, key: "k28-instant", label: "Instant")
                : provider == "qwen" ? syntheticWebsiteChoice(provider: provider, key: "fixture", label: "Fixture")
                : WebsiteModelChoice(provider: provider, key: "fixture-key/with-symbols", label: "Fixture Model 東京 👋")
            XCTAssertTrue(choice.isValid)
            XCTAssertEqual(WebsiteModelCatalog.choice(for: choice.modelID), choice)
            XCTAssertEqual(WebsiteModelCatalog.selection(for: choice.modelID)?.provider, provider)
            XCTAssertEqual(WebsiteModelChoice.parse(try XCTUnwrap(choice.canonicalJSONString)), choice)
            XCTAssertEqual(LocalModelCatalog.webProvider(for: choice.modelID), provider)
            XCTAssertEqual(configuration.modelProvider(for: choice.modelID), "web_browser")
            XCTAssertNoThrow(try configuration.validateSelectedModel(choice.modelID))
            XCTAssertEqual(LocalThreadContext.forModel(choice.modelID), .webBrowser)
            XCTAssertFalse(LocalModelCatalog.supportsHeadlessMLX(choice.modelID))
            XCTAssertFalse(LocalModelCatalog.supportsResidentVisualGrounding(choice.modelID))
            XCTAssertEqual(LocalModelCatalog.option(for: choice.modelID)?.label,
                "\(WebsiteModelCatalog.providerLabel(provider)) / \(choice.label) · Built-in browser")
        }
    }

    func testLegacyIDsKeepExplicitDefaultSemanticsAndOriginalPersistenceIDs() {
        for provider in namedWebsiteModelProviders {
            let id = "browser/\(provider)"
            XCTAssertEqual(WebsiteModelCatalog.selection(for: id)?.provider, provider)
            XCTAssertNil(WebsiteModelCatalog.choice(for: id))
            XCTAssertEqual(LocalModelCatalog.option(for: id)?.id, id)
            XCTAssertTrue(LocalModelCatalog.option(for: id)?.label.contains("Website default") == true)
        }
    }

    func testIdentityDistinguishesExactKeysLabelsAndProviders() {
        let original = WebsiteModelChoice(provider: "chatgpt", key: "fixture-fast", label: "Fixture Fast")
        let variants = [
            WebsiteModelChoice(provider: "chatgpt", key: "fixture-pro", label: "Fixture Fast"),
            WebsiteModelChoice(provider: "chatgpt", key: "fixture-fast", label: "Fixture Pro"),
            WebsiteModelChoice(provider: "gemini", key: "fixture-fast", label: "Fixture Fast"),
        ]
        XCTAssertEqual(Set(variants.map(\.modelID) + [original.modelID]).count, 4)
    }

    func testMalformedAndNoncanonicalIDsNeverRouteToLocalInference() throws {
        let valid = WebsiteModelChoice(provider: "chatgpt", key: "fixture", label: "Fixture").modelID
        let prefix = "browser/chatgpt/choice/"
        let invalid = [
            "browser/unknown", "browser/chatgpt/", "browser/chatgpt/choice", prefix,
            valid + "=", valid + "/extra", valid.replacingOccurrences(of: "chatgpt", with: "ChatGPT"),
            prefix + "a+", prefix + "%7B", prefix + "_", prefix + String(repeating: "a", count: 769),
            prefix + encoded("{\"key\":\"fixture\",\"label\":\"Fixture\",\"extra\":true}"),
            prefix + encoded("{ \"key\":\"fixture\",\"label\":\"Fixture\"}"),
            prefix + encoded("{\"key\":\"other\",\"key\":\"fixture\",\"label\":\"Fixture\"}"),
            prefix + encoded("{\"label\":\"Fixture\",\"key\":\"fixture\"}"),
            prefix + encoded("{\"key\":1,\"label\":\"Fixture\"}"),
        ]
        for id in invalid {
            XCTAssertNil(WebsiteModelCatalog.selection(for: id), id)
            XCTAssertFalse(LocalModelCatalog.isWebBrowser(id), id)
            XCTAssertThrowsError(try CodexAppServerRuntime.Configuration.localQwen.validateSelectedModel(id), id)
        }
        XCTAssertFalse(LocalModelCatalog.isWebBrowser("browser/chatgpt-like"))
    }

    func testChoiceBoundsRejectControlsAndNoncanonicalUnicodeWithoutTruncation() {
        let invalidFields = ["", " padded", "padded ", "line\nbreak", "nul\0value", String(repeating: "é", count: 65), "e\u{301}"]
        for value in invalidFields {
            XCTAssertFalse(WebsiteModelChoice(provider: "claude", key: value, label: "Fixture").isValid)
            XCTAssertFalse(WebsiteModelChoice(provider: "claude", key: "fixture", label: value).isValid)
        }
        XCTAssertTrue(WebsiteModelChoice(provider: "claude", key: String(repeating: "é", count: 64), label: String(repeating: "a", count: 128)).isValid)
        XCTAssertFalse(WebsiteModelChoice(provider: "unknown", key: "fixture", label: "Fixture").isValid)
    }

    func testChoiceJSONRequiresCanonicalExactFieldsAndCorrectTypes() throws {
        let choice = WebsiteModelChoice(provider: "gemini", key: "fixture", label: "Fixture")
        let canonical = try XCTUnwrap(choice.canonicalJSONString)
        XCTAssertEqual(WebsiteModelChoice.parse(canonical), choice)
        for invalid in [" " + canonical, canonical + " ", "[]", "{}", "null",
            "{\"provider\":\"gemini\",\"key\":\"fixture\",\"label\":\"Fixture\"}",
            "{\"provider\":\"gemini\",\"key\":\"fixture\",\"label\":\"Fixture\",\"extra\":true}",
            "{\"key\":\"fixture\",\"label\":1,\"provider\":\"gemini\"}", String(repeating: "x", count: 1_025)] {
            XCTAssertNil(WebsiteModelChoice.parse(invalid))
        }
    }

    func testObservedMenusRejectDuplicatesCrossProviderAndUnboundedChoices() throws {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "fixture", label: "Fixture")
        XCTAssertNoThrow(try WebsiteModelCatalog.validate([choice], provider: "chatgpt"))
        for invalid in [[], [choice, choice], [choice, WebsiteModelChoice(provider: "chatgpt", key: "other", label: "Fixture")],
            [choice, WebsiteModelChoice(provider: "chatgpt", key: "fixture", label: "Other")],
            [WebsiteModelChoice(provider: "claude", key: "fixture", label: "Fixture")],
            (0..<33).map { WebsiteModelChoice(provider: "chatgpt", key: "key-\($0)", label: "Label \($0)") }] {
            XCTAssertThrowsError(try WebsiteModelCatalog.validate(invalid, provider: "chatgpt"))
        }
    }

    func testObservedMenuCachePersistsExactChoicesAndRejectsCorruptData() throws {
        let preferences = isolatedTestPreferences()
        let choices = namedWebsiteModelProviders.map {  $0 == "chatgpt" ? WebsiteModelChoice(provider: $0, key: "chat/latest/medium", label: "Medium")
                : $0 == "kimi" ? WebsiteModelChoice(provider: $0, key: "k28-instant", label: "Instant")
                : $0 == "qwen" ? syntheticWebsiteChoice(provider: $0, key: "fixture", label: "Fixture")
                : WebsiteModelChoice(provider: $0, key: "fixture-key", label: "Fixture Label") }
        WebsiteModelCatalog.save(choices, to: preferences)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), choices)
        for invalid in [Data("{}".utf8), Data("[{}]".utf8), try JSONEncoder().encode([choices[0], choices[0]]),
            Data(repeating: 65, count: 100 * 1_024 + 1)] {
            preferences.set(invalid, forKey: WebsiteModelCatalog.preferenceKey)
            XCTAssertTrue(WebsiteModelCatalog.load(from: preferences).isEmpty)
        }
    }

    func testRetiredLatestRemainsParseableForHistoryButCannotBecomeSelectable() throws {
        for choice in retiredLatestChoices {
            XCTAssertTrue(choice.isValid)
            XCTAssertTrue(choice.isRetired)
            XCTAssertFalse(choice.isSelectable)
            XCTAssertEqual(WebsiteModelCatalog.choice(for: choice.modelID), choice)
            XCTAssertEqual(WebsiteModelCatalog.selection(for: choice.modelID)?.provider, "chatgpt")
            XCTAssertEqual(WebsiteModelChoice.parse(try XCTUnwrap(choice.canonicalJSONString)), choice)
            for available in [true, false] {
                let option = WebsiteModelCatalog.option(for: choice, available: available)
                XCTAssertEqual(option.id, choice.modelID)
                XCTAssertEqual(option.available, false)
                XCTAssertTrue(option.detail.contains("removed"))
            }
        }
        for provider in ["gemini", "claude", "groq"] {
            let choice = WebsiteModelChoice(provider: provider, key: "Latest", label: "Latest")
            XCTAssertFalse(choice.isRetired, "Retirement applies only to the requested ChatGPT family")
            XCTAssertTrue(choice.isSelectable)
        }
        XCTAssertFalse(WebsiteModelChoice(provider: "chatgpt", key: "Latest-preview", label: "Latest preview").isSelectable)
        XCTAssertFalse(WebsiteModelChoice(provider: "unknown", key: "fixture", label: "Fixture").isSelectable)
    }

    func testLoadingValidRawLatestCachePrunesItsPersistedEntryWithoutChangingOtherProviders() throws {
        let retained = [WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium"),
                        WebsiteModelChoice(provider: "gemini", key: "3.1 Pro", label: "3.1 Pro"),
                        WebsiteModelChoice(provider: "claude", key: "Sonnet 5.5", label: "Sonnet 5.5")]
        for retired in retiredLatestChoices {
            let preferences = isolatedTestPreferences()
            preferences.set(try JSONEncoder().encode([retired] + retained), forKey: WebsiteModelCatalog.preferenceKey)
            XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), retained)
            let stored = try XCTUnwrap(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
            XCTAssertEqual(try JSONDecoder().decode([WebsiteModelChoice].self, from: stored), retained)
            XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), retained)
            XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), stored,
                           "Loading an already pruned cache must not rewrite its contents")
        }
        let preferences = isolatedTestPreferences()
        preferences.set(try JSONEncoder().encode([retiredLatestChoices[0]]), forKey: WebsiteModelCatalog.preferenceKey)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), [])
        let stored = try XCTUnwrap(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
        XCTAssertEqual(try JSONDecoder().decode([WebsiteModelChoice].self, from: stored), [])
    }

    func testSavingFiltersRetiredChatGPTChoicesAndPreservesOtherProviderLatestIdentities() throws {
        let retained = [WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium"),
                        WebsiteModelChoice(provider: "gemini", key: "Latest", label: "Latest"),
                        WebsiteModelChoice(provider: "claude", key: "Latest", label: "Latest")]
        for retired in retiredLatestChoices {
            let preferences = isolatedTestPreferences()
            WebsiteModelCatalog.save([retired] + retained, to: preferences)
            let stored = try XCTUnwrap(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
            XCTAssertEqual(try JSONDecoder().decode([WebsiteModelChoice].self, from: stored), retained)
            XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), retained)
        }
    }

    func testRetirementCannotHideInvalidDuplicateOrOversizedRawCaches() throws {
        let latest = retiredLatestChoices[0]
        let baseline = [WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/medium", label: "Medium")]
        let invalidLists = [
            [latest, latest],
            [latest, WebsiteModelChoice(provider: "chatgpt", key: "other-key", label: "Latest")],
            [latest, WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Other label")],
            [WebsiteModelChoice(provider: "chatgpt", key: "", label: "Latest")],
            [latest] + (0..<32).map { WebsiteModelChoice(provider: "chatgpt", key: "key-\($0)", label: "Label \($0)") },
        ]
        for invalid in invalidLists {
            let preferences = isolatedTestPreferences()
            let raw = try JSONEncoder().encode(invalid)
            preferences.set(raw, forKey: WebsiteModelCatalog.preferenceKey)
            XCTAssertTrue(WebsiteModelCatalog.load(from: preferences).isEmpty)
            XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), raw,
                           "A rejected raw cache cannot be silently repaired by filtering retired entries")
            WebsiteModelCatalog.save(baseline, to: preferences)
            let valid = try XCTUnwrap(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
            WebsiteModelCatalog.save(invalid, to: preferences)
            XCTAssertEqual(preferences.data(forKey: WebsiteModelCatalog.preferenceKey), valid,
                           "A rejected save must not overwrite the previous valid catalog")
        }
    }

    func testPinnedLongestPrefixAdmissionRetainsPatchAndTerminalForFutureChoices() throws {
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: ComputaModelToolCatalog.catalogData()) as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        // This is the reviewed pinned engine's metadata lookup contract. Live
        // qualification separately observes actual offered tools for new IDs.
        for provider in WebsiteModelCatalog.providers {
            let ids: [String]
            if provider == "deepseek" {
                ids = WebsiteModeChoice.DeepSeekMode.allCases.map { WebsiteModeChoice(deepSeekMode: $0).requestID }
            } else {
                ids = [WebsiteModelChoice(provider: provider, key: "never-listed-before-launch", label: "Fixture Future Model").modelID]
                    + (provider == "qwen" ? ["Qwen3.7-Plus", "Qwen3.8-Max"].map {
                        WebsiteModelChoice(provider: provider, key: $0, label: $0).modelID
                    } : [])
            }
            for id in ids {
                XCTAssertFalse(models.contains { $0["slug"] as? String == id })
                let matches = models.filter { id.hasPrefix($0["slug"] as? String ?? "\0") }
                    .sorted { ($0["slug"] as? String ?? "").count > ($1["slug"] as? String ?? "").count }
                let metadata = try XCTUnwrap(matches.first, id)
                XCTAssertEqual(metadata["slug"] as? String, "browser/\(provider)")
                XCTAssertEqual(metadata["apply_patch_tool_type"] as? String, "freeform")
                XCTAssertEqual(metadata["shell_type"] as? String, "unified_exec")
                XCTAssertEqual(metadata["visibility"] as? String, "none")
            }
        }
        // Internal engine-prefix metadata must not manufacture a selectable
        // default or bypass the exact named-choice / typed-mode admission.
        for provider in ["qwen", "deepseek"] {
            XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: "browser/" + provider))
        }
        XCTAssertNil(LocalModelCatalog.option(for: "browser/deepseek"))
    }

    private func encoded(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private var retiredLatestChoices: [WebsiteModelChoice] {
        [WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Latest"),
         WebsiteModelChoice(provider: "chatgpt", key: "Latest", label: "Current label"),
         WebsiteModelChoice(provider: "chatgpt", key: "current-key", label: "Latest")]
    }
}

import Foundation
import XCTest
@testable import Computa

final class WebsiteModelCatalogTests: XCTestCase {
    func testConcreteChoicesRoundTripWithoutARegisteredOrGuessedModelList() throws {
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        for provider in WebsiteModelCatalog.providers {
            let choice = WebsiteModelChoice(provider: provider, key: "fixture-key/with-symbols", label: "Fixture Model 東京 👋")
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
        for provider in WebsiteModelCatalog.providers {
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
        let choices = WebsiteModelCatalog.providers.map { WebsiteModelChoice(provider: $0, key: "fixture-key", label: "Fixture Label") }
        WebsiteModelCatalog.save(choices, to: preferences)
        XCTAssertEqual(WebsiteModelCatalog.load(from: preferences), choices)
        for invalid in [Data("{}".utf8), Data("[{}]".utf8), try JSONEncoder().encode([choices[0], choices[0]]),
            Data(repeating: 65, count: 100 * 1_024 + 1)] {
            preferences.set(invalid, forKey: WebsiteModelCatalog.preferenceKey)
            XCTAssertTrue(WebsiteModelCatalog.load(from: preferences).isEmpty)
        }
    }

    func testPinnedLongestPrefixAdmissionRetainsPatchAndTerminalForFutureChoices() throws {
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: ComputaModelToolCatalog.catalogData()) as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        // This is the reviewed pinned engine's metadata lookup contract. Live
        // qualification separately observes actual offered tools for new IDs.
        for provider in WebsiteModelCatalog.providers {
            let id = WebsiteModelChoice(provider: provider, key: "never-listed-before-launch", label: "Fixture Future Model").modelID
            XCTAssertFalse(models.contains { $0["slug"] as? String == id })
            let matches = models.filter { id.hasPrefix($0["slug"] as? String ?? "\0") }
                .sorted { ($0["slug"] as? String ?? "").count > ($1["slug"] as? String ?? "").count }
            let metadata = try XCTUnwrap(matches.first)
            XCTAssertEqual(metadata["slug"] as? String, "browser/\(provider)")
            XCTAssertEqual(metadata["apply_patch_tool_type"] as? String, "freeform")
            XCTAssertEqual(metadata["shell_type"] as? String, "unified_exec")
        }
    }

    private func encoded(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

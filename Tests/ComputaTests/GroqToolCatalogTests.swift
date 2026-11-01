import Foundation
import XCTest
@testable import Computa

final class GroqToolCatalogTests: XCTestCase {
    func testLoaderRecognizesOnlyExactNativeDeclarationAndNamespace() throws {
        let loader = canonicalLoader()
        XCTAssertTrue(GroqToolCatalog.isRegisteredLoader([loader]))
        XCTAssertTrue(GroqToolCatalog.isRegisteredLoader([["type": "namespace", "name": "functions", "tools": [loader]]]))
        XCTAssertFalse(GroqToolCatalog.isRegisteredLoader([["type": "namespace", "name": "foreign", "tools": [loader]]]))
        XCTAssertFalse(GroqToolCatalog.isRegisteredLoader([loader, loader]))
        var dual = loader
        dual["inputSchema"] = loader["parameters"]
        XCTAssertTrue(GroqToolCatalog.isRegisteredLoader([dual]))
        var schema = try XCTUnwrap(loader["parameters"] as? [String: Any])
        for invalid in [true, 0, NSNull(), "false"] as [Any] {
            schema["additionalProperties"] = invalid
            dual["inputSchema"] = schema
            XCTAssertFalse(GroqToolCatalog.isRegisteredLoader([dual]))
        }
        var custom = loader; custom["type"] = "custom"
        XCTAssertFalse(GroqToolCatalog.isRegisteredLoader([custom]))
        var changed = loader
        schema = try XCTUnwrap(loader["parameters"] as? [String: Any]); schema["required"] = ["names"]
        changed["parameters"] = schema
        XCTAssertFalse(GroqToolCatalog.isRegisteredLoader([changed]))
    }

    func testLoadPreservesCompleteInventoryAndReplacesOnlyPresentationSelection() throws {
        var catalog = GroqToolCatalog()
        let scope = makeScope()
        let seed = try makeSeed()
        let initial = try catalog.prepare(scope: scope, seed: seed)
        XCTAssertEqual(initial.selectedNames, [GroqToolCatalog.name])
        XCTAssertEqual(Set(initial.inventory.map(\.name)), seed.callableNames)
        let receipt = try catalog.load(scope: scope, arguments: args(initial, ["exec_command", "foreign.patch"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["catalog_revision", "loaded", "available", "execution"])
        XCTAssertEqual(object["execution"] as? Bool, false)
        XCTAssertEqual(object["available"] as? String, "next_request")
        XCTAssertEqual(object["loaded"] as? [String], ["exec_command", "foreign.patch"])
        XCTAssertLessThan(receipt.count, 300)
        let loaded = try catalog.prepare(scope: scope, seed: seed)
        XCTAssertEqual(loaded.revision, initial.revision)
        XCTAssertEqual(loaded.inventory, initial.inventory)
        XCTAssertEqual(loaded.selectedNames, [GroqToolCatalog.name, "exec_command", "foreign.patch"])
        XCTAssertEqual(loaded.inventory.first { $0.name == "foreign.patch" }?.isCustom, true)
        _ = try catalog.load(scope: scope, arguments: args(loaded, ["browser_tabs"]))
        let replaced = try catalog.prepare(scope: scope, seed: seed)
        XCTAssertEqual(replaced.selectedNames, [GroqToolCatalog.name, "browser_tabs"])
        XCTAssertEqual(replaced.inventory, initial.inventory)
        // Storage holds only a selection; the original schemas/grammar are not
        // reconstructed, abbreviated or substituted by a familiar tool name.
        XCTAssertEqual(seed.registeredDefinitionsJSON, try makeSeed().registeredDefinitionsJSON)
    }

    func testNamespacedLoaderAndSameLocalNamesRemainDistinct() throws {
        var catalog = GroqToolCatalog()
        let definitions: [[String: Any]] = [
            ["type": "namespace", "name": "functions", "tools": [canonicalLoader(), function("read")]],
            ["type": "namespace", "name": "foreign", "tools": [function("read")]],
        ]
        let names: Set<String> = ["functions." + GroqToolCatalog.name, "functions.read", "foreign.read"]
        let seed = GroqToolCatalog.Seed(registeredDefinitionsJSON: try encode(definitions),
            callableNames: names, allowedNames: names, preloadNames: [], toolChoiceJSON: try encode("auto"))
        let scope = makeScope(), initial = try catalog.prepare(scope: scope, seed: seed)
        XCTAssertEqual(initial.selectedNames, ["functions." + GroqToolCatalog.name])
        XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(initial, ["read"])))
        _ = try catalog.load(scope: scope, arguments: args(initial, ["foreign.read"]))
        XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed).selectedNames,
                       ["functions." + GroqToolCatalog.name, "foreign.read"])
    }

    func testPreviewCopyDoesNotChangeCommittedSelectionUntilAssigned() throws {
        var catalog = GroqToolCatalog()
        let scope = makeScope(), seed = try makeSeed()
        let baseline = try catalog.prepare(scope: scope, seed: seed)
        _ = try catalog.load(scope: scope, arguments: args(baseline, ["exec_command"]))
        let committed = try catalog.prepare(scope: scope, seed: seed)
        var preview = catalog
        _ = try preview.load(scope: scope, arguments: args(baseline, ["browser_tabs"]))
        XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), committed)
        XCTAssertEqual(try preview.prepare(scope: scope, seed: seed).selectedNames, [GroqToolCatalog.name, "browser_tabs"])
        catalog = preview
        XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed).selectedNames, [GroqToolCatalog.name, "browser_tabs"])
    }

    func testRejectedPreparationRevisionPreservesPreviouslyLoadedCatalog() throws {
        let scope = makeScope()
        var request: [String: Any] = ["model": scope.modelID, "input": "Read the synthetic fixture.",
            "tools": [canonicalLoader(), function("fixture_small")], "tool_choice": "auto"]
        let seed = try XCTUnwrap(WebModelResponseCodec.prepareRequest(encode(request)).groqToolCatalogSeed)
        var catalog = GroqToolCatalog()
        let initial = try catalog.prepare(scope: scope, seed: seed)
        let load = try args(initial, ["fixture_small"])
        _ = try catalog.load(scope: scope, arguments: load)
        let committed = try catalog.prepare(scope: scope, seed: seed)

        // A different valid policy changes the revision before final prompt
        // admission. Exercise that boundary without retrying a terminal turn.
        request["tool_choice"] = "required"
        request["input"] = String(repeating: "capacity ", count: 7_000)
        let data = try encode(request)
        let changedSeed = try XCTUnwrap(WebModelResponseCodec.prepareRequest(data).groqToolCatalogSeed)
        var candidate = catalog
        let changed = try candidate.prepare(scope: scope, seed: changedSeed)
        XCTAssertNotEqual(changed.revision, committed.revision)
        let projected = try WebModelResponseCodec.prepareRequest(data, groqToolCatalogProjection: changed)
        XCTAssertThrowsError(try WebModelResponseCodec.validateGroqPromptBudget(model: projected.model, prompt: projected.prompt)) {
            XCTAssertEqual(WebModelServer.errorPresentation(for: $0).code, "website_prompt_budget_exceeded")
        }
        XCTAssertThrowsError(try candidate.load(scope: scope, arguments: load)) {
            XCTAssertEqual($0 as? GroqToolCatalog.Failure, .staleRevision)
        }
        // Discarding the rejected candidate preserves both original revision
        // and loaded selection; the exact previous receipt remains usable.
        _ = try catalog.load(scope: scope, arguments: load)
        XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), committed)
    }

    func testInvalidLoadsAreAtomicAndCannotLoadUncallableOrDisallowedTools() throws {
        var catalog = GroqToolCatalog()
        let scope = makeScope()
        let seed = try makeSeed(callable: [GroqToolCatalog.name, "exec_command", "browser_tabs"],
                                allowed: [GroqToolCatalog.name, "exec_command", "foreign.patch"])
        let initial = try catalog.prepare(scope: scope, seed: seed)
        _ = try catalog.load(scope: scope, arguments: args(initial, ["exec_command"]))
        let loaded = try catalog.prepare(scope: scope, seed: seed)
        let invalid: [Any] = [
            [:], ["catalog_revision": initial.revision],
            ["catalog_revision": initial.revision, "names": []],
            ["catalog_revision": initial.revision, "names": ["exec_command", "exec_command"]],
            ["catalog_revision": initial.revision, "names": [1]],
            ["catalog_revision": initial.revision, "names": ["exec_command"], "execute": true],
            ["catalog_revision": initial.revision, "names": ["browser_tabs"]],
            ["catalog_revision": initial.revision, "names": ["foreign.patch"]],
            ["catalog_revision": initial.revision, "names": [GroqToolCatalog.name]],
            ["catalog_revision": String(repeating: "0", count: 64), "names": ["exec_command"]],
            ["catalog_revision": initial.revision.uppercased(), "names": ["exec_command"]],
            ["catalog_revision": initial.revision, "names": ["a", "b", "c", "d", "e"]],
            ["catalog_revision": initial.revision, "names": [String(repeating: "x", count: 4_097)]],
        ]
        for value in invalid {
            XCTAssertThrowsError(try catalog.load(scope: scope, arguments: encode(value)))
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), loaded)
        }
    }

    func testEveryScopeComponentAndCatalogRevisionPreventsBorrowedSelection() throws {
        let scope = makeScope(), seed = try makeSeed()
        let alternatives = [
            makeScope(task: UUID().uuidString.lowercased(), base: scope),
            makeScope(thread: UUID().uuidString.lowercased(), base: scope),
            makeScope(turn: UUID().uuidString.lowercased(), base: scope),
            makeScope(generation: UUID(), base: scope),
            makeScope(preparation: UUID(), base: scope),
            makeScope(model: WebsiteModelChoice(provider: "groq", key: "other", label: "Other").modelID, base: scope),
        ]
        for other in alternatives {
            var catalog = GroqToolCatalog()
            let initial = try catalog.prepare(scope: scope, seed: seed)
            _ = try catalog.load(scope: scope, arguments: args(initial, ["exec_command"]))
            XCTAssertThrowsError(try catalog.load(scope: other, arguments: args(initial, ["browser_tabs"])))
            XCTAssertEqual(try catalog.prepare(scope: other, seed: seed).selectedNames, initial.selectedNames)
        }
        var catalog = GroqToolCatalog()
        let original = try catalog.prepare(scope: scope, seed: seed)
        _ = try catalog.load(scope: scope, arguments: args(original, ["exec_command"]))
        var definitions = try XCTUnwrap(JSONSerialization.jsonObject(with: seed.registeredDefinitionsJSON) as? [[String: Any]])
        definitions[1]["description"] = "Changed exact contract"
        let changes = [
            GroqToolCatalog.Seed(registeredDefinitionsJSON: try encode(definitions), callableNames: seed.callableNames,
                allowedNames: seed.allowedNames, preloadNames: [], toolChoiceJSON: seed.toolChoiceJSON),
            try makeSeed(allowed: [GroqToolCatalog.name, "browser_tabs"]),
            try makeSeed(callable: [GroqToolCatalog.name, "browser_tabs"]),
            try makeSeed(policy: "required"), try makeSeed(preload: ["browser_tabs"]),
        ]
        for changed in changes {
            let fresh = try catalog.prepare(scope: scope, seed: changed)
            XCTAssertNotEqual(fresh.revision, original.revision)
            XCTAssertEqual(fresh.selectedNames, try GroqToolCatalog.baseline(for: changed).selectedNames)
            XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(original, ["browser_tabs"])))
        }
    }

    func testForcedChoiceAndDisabledLoaderRemainRestrictedByOriginalPolicy() throws {
        var catalog = GroqToolCatalog()
        let scope = makeScope()
        let seed = try makeSeed(allowed: ["exec_command"], preload: ["exec_command"],
                                policy: ["type": "function", "name": "exec_command"])
        let projection = try catalog.prepare(scope: scope, seed: seed)
        XCTAssertEqual(projection.selectedNames, ["exec_command"])
        XCTAssertEqual(projection.inventory.first { $0.name == GroqToolCatalog.name }?.allowed, false)
        XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(projection, ["browser_tabs"])))
        XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(projection, ["exec_command"])),
                             "Even an otherwise allowed target cannot authorize a disallowed loader call")
        let none = try makeSeed(allowed: [], policy: "none")
        XCTAssertTrue(try catalog.prepare(scope: scope, seed: none).selectedNames.isEmpty)
        XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(try GroqToolCatalog.baseline(for: none), ["exec_command"])))
    }

    func testProjectionCannotForgeInventoryRevisionSelectionOrPreloads() throws {
        let seed = try makeSeed(preload: ["exec_command"]), base = try GroqToolCatalog.baseline(for: seed)
        let forged = [
            GroqToolCatalog.Projection(revision: String(repeating: "f", count: 64), inventory: base.inventory, selectedNames: base.selectedNames),
            GroqToolCatalog.Projection(revision: base.revision, inventory: [], selectedNames: base.selectedNames),
            GroqToolCatalog.Projection(revision: base.revision, inventory: base.inventory, selectedNames: [GroqToolCatalog.name]),
            GroqToolCatalog.Projection(revision: base.revision, inventory: base.inventory, selectedNames: base.selectedNames.union(["invented"])),
        ]
        for projection in forged { XCTAssertThrowsError(try GroqToolCatalog.validate(projection, for: seed)) }
        let allowed = GroqToolCatalog.Projection(revision: base.revision, inventory: base.inventory,
            selectedNames: base.selectedNames.union(["foreign.patch"]))
        XCTAssertNoThrow(try GroqToolCatalog.validate(allowed, for: seed))
        XCTAssertThrowsError(try GroqToolCatalog.baseline(for: makeSeed(preload: ["invented"])))
    }

    func testRemovalAndMalformedScopeCannotRetainOrCreateAuthority() throws {
        var catalog = GroqToolCatalog()
        let scope = makeScope(), seed = try makeSeed()
        let initial = try catalog.prepare(scope: scope, seed: seed)
        _ = try catalog.load(scope: scope, arguments: args(initial, ["exec_command"]))
        catalog.remove(taskID: scope.taskID)
        XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(initial, ["exec_command"])))
        XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), initial)
        catalog.removeAll()
        XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(initial, ["exec_command"])))
        for bad in [makeScope(task: "not-a-uuid", base: scope), makeScope(task: scope.taskID.uppercased(), base: scope),
                    makeScope(model: "browser/groq", base: scope),
                    makeScope(model: WebsiteModelChoice(provider: "claude", key: "Haiku", label: "Haiku").modelID, base: scope)] {
            XCTAssertThrowsError(try catalog.prepare(scope: bad, seed: seed))
        }
    }

    func testRegistrationPersistsOnlyExactHomeThreadModelAndDoesNotMigrateLegacy() throws {
        let suite = "GroqRegistrationTests-" + UUID().uuidString
        let first = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { first.removePersistentDomain(forName: suite) }
        let model = makeScope().modelID, thread = UUID().uuidString
        XCTAssertFalse(GroqToolThreadRegistration.contains(codexHome: "/fixture", threadID: thread, modelID: model, defaults: first))
        GroqToolThreadRegistration.remember(codexHome: "/fixture", threadID: thread, modelID: model, defaults: first)
        let resumed = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(GroqToolThreadRegistration.contains(codexHome: "/fixture", threadID: thread, modelID: model, defaults: resumed))
        for (home, savedThread, savedModel) in [
            ("/foreign", thread, model), ("/fixture", UUID().uuidString, model),
            ("/fixture", thread, WebsiteModelChoice(provider: "groq", key: "other", label: "Other").modelID),
            ("/fixture", thread, "browser/groq"), ("/fixture", thread, "browser/claude"),
        ] {
            XCTAssertFalse(GroqToolThreadRegistration.contains(codexHome: home, threadID: savedThread, modelID: savedModel, defaults: resumed))
        }
        GroqToolThreadRegistration.remember(codexHome: "/fixture", threadID: "legacy", modelID: "browser/groq", defaults: resumed)
        XCTAssertEqual(resumed.stringArray(forKey: GroqToolThreadRegistration.preferenceKey)?.count, 1)
        let saved = try XCTUnwrap(resumed.stringArray(forKey: GroqToolThreadRegistration.preferenceKey)?.first)
        XCTAssertEqual(saved.count, 64)
        XCTAssertFalse(saved.contains(thread)); XCTAssertFalse(saved.contains("fixture"))
    }

    private func canonicalLoader() -> [String: Any] {
        var value = GroqToolCatalog.specification
        value["parameters"] = value.removeValue(forKey: "inputSchema")
        return value
    }
    private func function(_ name: String) -> [String: Any] {
        ["type": "function", "name": name, "description": "Exact function " + name,
         "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]]
    }
    private func makeSeed(callable: Set<String>? = nil, allowed: Set<String>? = nil,
                          preload: Set<String> = [], policy: Any = "auto") throws -> GroqToolCatalog.Seed {
        let definitions: [[String: Any]] = [canonicalLoader(), function("exec_command"), function("browser_tabs"),
            ["type": "namespace", "name": "foreign", "tools": [["type": "custom", "name": "patch",
                "description": "Exact custom grammar e\u{0301} 🧭\nInstructions remain in the complete schema.",
                "format": ["type": "text"]]]]]
        let all: Set<String> = [GroqToolCatalog.name, "exec_command", "browser_tabs", "foreign.patch"]
        return GroqToolCatalog.Seed(registeredDefinitionsJSON: try encode(definitions), callableNames: callable ?? all,
            allowedNames: allowed ?? all, preloadNames: preload, toolChoiceJSON: try encode(policy))
    }
    private func makeScope(task: String? = nil, thread: String? = nil, turn: String? = nil,
                           generation: UUID? = nil, preparation: UUID? = nil, model: String? = nil,
                           base: GroqToolCatalog.Scope? = nil) -> GroqToolCatalog.Scope {
        GroqToolCatalog.Scope(taskID: task ?? base?.taskID ?? UUID().uuidString.lowercased(),
            threadID: thread ?? base?.threadID ?? UUID().uuidString.lowercased(),
            turnID: turn ?? base?.turnID ?? UUID().uuidString.lowercased(),
            runtimeGeneration: generation ?? base?.runtimeGeneration ?? UUID(),
            preparationID: preparation ?? base?.preparationID ?? UUID(),
            modelID: model ?? base?.modelID ?? WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID)
    }
    private func args(_ projection: GroqToolCatalog.Projection, _ names: [String]) throws -> Data {
        try encode(["catalog_revision": projection.revision, "names": names])
    }
    private func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
}

import Foundation
import XCTest
@testable import Computa

final class GroqToolCatalogTests: XCTestCase {
    func testValidBudgetSubsetsAreLargestFirstAndNeverValidateOnlyPartOfARequest() throws {
        let names = ["tool_d", "tool_c", "tool_b", "tool_a"]
        let definitions = [canonicalLoader()] + names.map(function)
        let allowed = Set(names + [GroqToolCatalog.name])
        let seed = GroqToolCatalog.Seed(registeredDefinitionsJSON: try encode(definitions),
            callableNames: allowed, allowedNames: allowed, preloadNames: [], toolChoiceJSON: try encode("auto"))
        var catalog = GroqToolCatalog()
        let scope = makeScope(), baseline = try catalog.prepare(scope: scope, seed: seed)
        var staged = catalog
        let load = try staged.previewLoad(scope: scope, arguments: args(baseline,names), lastOfferedNames: [])
        let alternatives = try load.smallerArguments().map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let subsets = try alternatives.map { try XCTUnwrap($0["names"] as? [String]) }
        XCTAssertEqual(subsets.count,14)
        XCTAssertEqual(subsets.map(\.count),[3,3,3,3,2,2,2,2,2,2,1,1,1,1])
        XCTAssertEqual(subsets.first,["tool_d","tool_c","tool_b"])
        XCTAssertEqual(subsets[1],["tool_d","tool_c","tool_a"])
        XCTAssertEqual(subsets.last,["tool_a"])
        XCTAssertEqual(Set(subsets.map { $0.joined(separator:",") }).count,14)
        XCTAssertTrue(alternatives.allSatisfy { $0["catalog_revision"] as? String == baseline.revision })
        XCTAssertTrue(subsets.allSatisfy { Set($0).isSubset(of:allowed) && !$0.isEmpty && $0.count<4 })
        for count in [0, GroqToolCatalog.maximumLoadedTools + 1] {
            let invalid = GroqToolCatalog.LoadPreview(receipt: Data(), budgetFailure: .selectionTooLarge,
                revision: baseline.revision, names: Array(repeating: "tool_d", count: count))
            XCTAssertThrowsError(try invalid.smallerArguments())
        }
        for invalid in [["tool_d","not_registered"],["tool_d","tool_d"],names+["not_registered"]] {
            XCTAssertThrowsError(try catalog.previewLoad(scope: scope, arguments: args(baseline,invalid), lastOfferedNames: []))
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed),baseline)
        }
        var smaller = catalog
        let selected = try smaller.previewLoad(scope: scope, arguments: args(baseline,["tool_c","tool_a"]), lastOfferedNames: [])
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with:selected.receipt(deferred:["tool_d","tool_b"])) as? [String:Any])
        XCTAssertEqual(receipt["loaded"] as? [String],["tool_a","tool_c"])
        XCTAssertEqual(receipt["deferred"] as? [String],["tool_b","tool_d"])
        XCTAssertEqual(receipt["execution"] as? Bool,false)
        XCTAssertEqual(receipt["catalog_revision"] as? String,baseline.revision)
        XCTAssertEqual(try catalog.prepare(scope:scope,seed:seed),baseline)
    }

    func testDisplayedSubsetContractCannotChangeCanonicalRegistrationOrSavedThreadMembership() throws {
        let canonical = GroqToolCatalog.specification
        XCTAssertEqual(canonical["description"] as? String,
            "Load exact schemas for 1–4 inventory names for the next request. Read-only; executes nothing. Replaces the previous loaded selection. Use the current catalog_revision.")
        let encodedCanonical = try encode(canonical), scope = makeScope(), seed = try makeSeed()
        let base = try GroqToolCatalog.baseline(for:seed)
        let suite = "GroqSubsetRegistration-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        GroqToolThreadRegistration.remember(codexHome:"/fixture",threadID:scope.threadID,modelID:scope.modelID,defaults:defaults)
        let marker = GroqToolThreadRegistration.marker(codexHome:"/fixture",threadID:scope.threadID,modelID:scope.modelID)
        let shown = try XCTUnwrap(base.displaySchemas([canonicalLoader()]).first)
        XCTAssertTrue((shown["description"] as? String)?.contains("fitting loaded subset and deferred names") == true)
        XCTAssertEqual(try encode(GroqToolCatalog.specification),encodedCanonical)
        XCTAssertEqual(GroqToolThreadRegistration.marker(codexHome:"/fixture",threadID:scope.threadID,modelID:scope.modelID),marker)
        XCTAssertTrue(GroqToolThreadRegistration.contains(codexHome:"/fixture",threadID:scope.threadID,modelID:scope.modelID,
            defaults:try XCTUnwrap(UserDefaults(suiteName:suite))))
        var foreign = canonicalLoader(); foreign["name"]="foreign_loader"
        XCTAssertEqual(try encode(base.displaySchemas([foreign]).first!),try encode(foreign))
        XCTAssertEqual(try encode(GroqToolCatalog.restoringRegisteredLoaderBounds(canonicalLoader())),try encode(canonicalLoader()))
    }

    func testBudgetRejectionHintsUseOnlyTheExactAdmittedOfferAndCurrentPolicy() throws {
        var catalog = GroqToolCatalog()
        let scope = makeScope()
        let seed = try makeSeed(allowed: [GroqToolCatalog.name, "exec_command", "foreign.patch"])
        let initial = try catalog.prepare(scope: scope, seed: seed)
        // First four read actions used exec; later direct-schema selection can change
        // at identical catalog revision as the request's history fills the budget.
        for (requested, offered, expected) in [
            (["foreign.patch", "exec_command"], ["exec_command", "private_other"], GroqToolCatalog.Failure.budgetWithOfferedSchemas(["exec_command"])),
            (["exec_command"], ["exec_command"], .budgetWithOfferedSchemas(["exec_command"])),
            (["exec_command"], [], .selectionTooLarge)
        ] {
            var staged = catalog
            let load = try staged.previewLoad(scope: scope, arguments: args(initial, requested), lastOfferedNames: Set(offered))
            XCTAssertEqual(load.budgetFailure, expected)
            XCTAssertFalse(load.budgetFailure.localizedDescription.contains("private_other"))
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), initial)
        }
        for names in [["exec_command", "browser_tabs"], ["exec_command", "private_other"]] {
            XCTAssertThrowsError(try catalog.previewLoad(scope: scope, arguments: args(initial,names), lastOfferedNames: Set(names))) { error in
                guard case .unavailableSelection = error as? GroqToolCatalog.Failure else { return XCTFail("Invalid membership") }
            }
        }
    }

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

    func testLoaderSchemaPublishesTheSameNameBoundsEnforcedAtRuntime() throws {
        let loader = canonicalLoader()
        let schema = try XCTUnwrap(loader["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let namesSchema = try XCTUnwrap(properties["names"] as? [String: Any])
        XCTAssertEqual(namesSchema["minItems"] as? Int, 1)
        XCTAssertEqual(namesSchema["maxItems"] as? Int, 4)
        XCTAssertEqual(namesSchema["uniqueItems"] as? Bool, true)
        // An old or weakened declaration cannot borrow the exact native loader.
        for key in ["minItems", "maxItems", "uniqueItems"] {
            var changedNames = namesSchema; changedNames.removeValue(forKey: key)
            var changedProperties = properties; changedProperties["names"] = changedNames
            var changedSchema = schema; changedSchema["properties"] = changedProperties
            var changedLoader = loader; changedLoader["parameters"] = changedSchema
            XCTAssertFalse(GroqToolCatalog.isRegisteredLoader([changedLoader]))
        }

        // Every requested name exists and is allowed, so the five-name rejection
        // proves the cardinality boundary rather than an unavailable-tool error.
        let names = ["fixture_a", "fixture_b", "fixture_c", "fixture_d", "fixture_e"]
        let definitions = [loader] + names.map(function)
        let all = Set(names + [GroqToolCatalog.name])
        let seed = GroqToolCatalog.Seed(registeredDefinitionsJSON: try encode(definitions),
            callableNames: all, allowedNames: all, preloadNames: [], toolChoiceJSON: try encode("auto"))
        let scope = makeScope()
        var catalog = GroqToolCatalog()
        let initial = try catalog.prepare(scope: scope, seed: seed)
        for valid in [Array(names.prefix(1)), Array(names.prefix(4))] {
            _ = try catalog.load(scope: scope, arguments: args(initial, valid))
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed).selectedNames,
                           Set(valid + [GroqToolCatalog.name]))
        }
        let accepted = try catalog.prepare(scope: scope, seed: seed)
        for invalid in [[], names, [names[0], names[0]]] as [[String]] {
            XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(initial, invalid))) {
                let reason: GroqToolCatalog.Failure = invalid.count == 5
                    ? .tooManyNames(count: 5, direct: [], loadable: Array(names.prefix(4)), ineligible: 0) : .invalidArguments
                XCTAssertEqual($0 as? GroqToolCatalog.Failure, reason)
            }
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), accepted)
        }
    }

    func testOversizedSelectionUsesAdmittedSchemasAndCurrentPolicyWithoutLoadingAnything() throws {
        let registration = [canonicalLoader()] + ["browser_open", "browser_bind", "computer_v2_read_page",
                                                  "computer_v2_fill", "computer_v2_press"].map(function)
        let loader = GroqToolCatalog.name
        let seed = GroqToolCatalog.Seed(registeredDefinitionsJSON: try encode(registration),
            callableNames: [loader, "browser_open", "browser_bind", "computer_v2_fill"],
            allowedNames: [loader, "browser_open", "browser_bind", "computer_v2_read_page", "computer_v2_press"],
            preloadNames: [], toolChoiceJSON: try encode("auto"))
        let scope = makeScope()
        var catalog = GroqToolCatalog()
        let initial = try catalog.prepare(scope: scope, seed: seed)
        let names = ["browser_bind", "browser_open", "computer_v2_read_page", "computer_v2_fill", "computer_v2_press"]
        let expected = GroqToolCatalog.Failure.tooManyNames(count: 5, direct: ["browser_open"], loadable: ["browser_bind"], ineligible: 3)
        for requested in [names, [names[1], names[0]] + Array(names.dropFirst(2)),
                          Array(names.prefix(4)) + ["DO_NOT_ECHO"]] {
            XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(initial, requested),
                lastOfferedNames: ["browser_open", "computer_v2_fill", "DO_NOT_ECHO"])) { error in
                XCTAssertEqual(error as? GroqToolCatalog.Failure, expected)
                for privateName in ["computer_v2_fill", "computer_v2_read_page", "computer_v2_press", "DO_NOT_ECHO"] {
                    XCTAssertFalse(error.localizedDescription.contains(privateName))
                }
            }
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), initial)
        }
        // No presumed directly callable schemas under the loaded-only budget fallback.
        XCTAssertThrowsError(try catalog.load(scope: scope, arguments: args(initial, names), lastOfferedNames: [loader])) {
            XCTAssertEqual($0 as? GroqToolCatalog.Failure, .tooManyNames(count: 5, direct: [], loadable: ["browser_bind", "browser_open"], ineligible: 3))
        }
        // Malformed, duplicate, stale and recursive loader requests disclose no suggestions.
        for (rev, badNames, expectedError) in [
            (initial.revision, names + ["browser_open"], GroqToolCatalog.Failure.invalidArguments),
            (String(repeating: "0", count: 64), names, .staleRevision),
            (initial.revision, names + [loader], .unavailableTool)
        ] {
            let data = try encode(["catalog_revision":rev, "names":badNames])
            XCTAssertThrowsError(try catalog.load(scope: scope, arguments: data, lastOfferedNames: ["browser_open"])) {
                XCTAssertEqual($0 as? GroqToolCatalog.Failure, expectedError)
            }
        }
        XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), initial)
    }

    func testOnlyExactPinnedEngineLoaderProjectionCanRestoreNativeBounds() throws {
        let complete = canonicalLoader()
        var schema = try XCTUnwrap(complete["parameters"] as? [String: Any])
        var properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        var names = try XCTUnwrap(properties["names"] as? [String: Any])
        names.removeValue(forKey: "maxItems")
        names.removeValue(forKey: "uniqueItems")
        properties["names"] = names; schema["properties"] = properties
        var projected = complete; projected["parameters"] = schema
        XCTAssertEqual(names["minItems"] as? Int, 1)
        XCTAssertTrue(GroqToolCatalog.isRegisteredLoader([projected]))
        XCTAssertTrue(GroqToolCatalog.isRegisteredLoader([["type": "namespace", "name": "functions", "tools": [projected]]]))
        XCTAssertEqual(try encode(GroqToolCatalog.restoringRegisteredLoaderBounds(projected)), try encode(complete))
        XCTAssertEqual(try encode(GroqToolCatalog.restoringRegisteredLoaderBounds(projected, namespace: "functions")), try encode(complete))
        XCTAssertEqual(try encode(GroqToolCatalog.restoringRegisteredLoaderBounds(projected, namespace: "foreign")), try encode(projected))

        var missingMinimum = names; missingMinimum.removeValue(forKey: "minItems")
        var changedMinimum = names; changedMinimum["minItems"] = 0
        var partialMaximum = names; partialMaximum["maxItems"] = 4
        var changedMaximum = names; changedMaximum["maxItems"] = 5; changedMaximum["uniqueItems"] = true
        var changedUniqueness = names; changedUniqueness["maxItems"] = 4; changedUniqueness["uniqueItems"] = false
        var unknownKeyword = names; unknownKeyword["unreviewed"] = true
        for changed in [missingMinimum, changedMinimum, partialMaximum, changedMaximum, changedUniqueness, unknownKeyword] {
            var changedProperties = properties; changedProperties["names"] = changed
            var changedSchema = schema; changedSchema["properties"] = changedProperties
            var changedDefinition = projected; changedDefinition["parameters"] = changedSchema
            XCTAssertFalse(GroqToolCatalog.isRegisteredLoader([changedDefinition]))
            XCTAssertEqual(try encode(GroqToolCatalog.restoringRegisteredLoaderBounds(changedDefinition)), try encode(changedDefinition),
                           "An unknown or changed contract must not be repaired into the native loader")
        }
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

    func testRejectedSelectionIdentifiesOnlyRegisteredOffendersAndKeepsPriorSelection() throws {
        let definitions = [canonicalLoader(), function("exec_command"), function("browser_read"),
                           function("browser_close"), function("fixture_denied")]
        let seed = GroqToolCatalog.Seed(registeredDefinitionsJSON: try encode(definitions),
            callableNames: [GroqToolCatalog.name, "exec_command", "fixture_denied"],
            allowedNames: [GroqToolCatalog.name, "exec_command"], preloadNames: [], toolChoiceJSON: try encode("auto"))
        let scope = makeScope()
        var catalog = GroqToolCatalog()
        let initial = try catalog.prepare(scope: scope, seed: seed)
        _ = try catalog.load(scope: scope, arguments: args(initial, ["exec_command"]))
        let accepted = try catalog.prepare(scope: scope, seed: seed)
        let unknown = "unknown_DO_NOT_ECHO_or_execute"
        let cases: [([String], GroqToolCatalog.Failure)] = [
            (["exec_command", "browser_read", "browser_close"],
             .unavailableSelection(unavailable: ["browser_close", "browser_read"], denied: [], unknownCount: 0, direct: [], loadable: ["exec_command"])),
            (["browser_read", "fixture_denied", unknown],
             .unavailableSelection(unavailable: ["browser_read"], denied: ["fixture_denied"], unknownCount: 1, direct: [], loadable: [])),
        ]
        for (names, expected) in cases {
            do {
                _ = try catalog.load(scope: scope, arguments: args(initial, names))
                XCTFail("Unavailable, denied or unknown names must reject the whole selection")
            } catch {
                XCTAssertEqual(error as? GroqToolCatalog.Failure, expected)
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("No tool was loaded or executed"))
                XCTAssertTrue(message.contains("current inventory"))
                XCTAssertFalse(message.contains(unknown))
                XCTAssertFalse(message.components(separatedBy: "Eligible requested names")[0].contains("exec_command"))
            }
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), accepted)
        }
    }

    func testMixedBrowserSelectionSeparatesCurrentlyOfferedFromLoadableAndPreservesPriorSelection() throws {
        let loader = GroqToolCatalog.name
        let prior = ["computer_v2_open", "computer_v2_read_page", "computer_v2_fill", "computer_v2_press"]
        let requested = ["browser_open", "browser_read", "browser_click", "browser_fill"]
        let definitions = [canonicalLoader()] + (prior + requested).map(function)
        let seed = GroqToolCatalog.Seed(registeredDefinitionsJSON: try encode(definitions),
            callableNames: Set(prior + [loader, "browser_open"]), allowedNames: Set(prior + requested + [loader]),
            preloadNames: [], toolChoiceJSON: try encode("auto"))
        var catalog = GroqToolCatalog()
        let scope = makeScope()
        let initial = try catalog.prepare(scope: scope, seed: seed)
        _ = try catalog.load(scope: scope, arguments: args(initial, prior))
        let before = try catalog.prepare(scope: scope, seed: seed)
        for browserOpenOffered in [true, false] {
            let offered = Set(prior + [loader] + (browserOpenOffered ? ["browser_open"] : []))
            let expected = GroqToolCatalog.Failure.unavailableSelection(
                unavailable: ["browser_click", "browser_fill", "browser_read"], denied: [], unknownCount: 0,
                direct: browserOpenOffered ? ["browser_open"] : [], loadable: browserOpenOffered ? [] : ["browser_open"])
            XCTAssertThrowsError(try catalog.previewLoad(scope: scope, arguments: args(before, requested), lastOfferedNames: offered)) { error in
                XCTAssertEqual(error as? GroqToolCatalog.Failure, expected)
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(browserOpenOffered ? #"call existing schemas directly=["browser_open"]"#
                                                               : #"load other schemas by exact name=["browser_open"]"#))
                XCTAssertFalse(prior.contains(where: message.contains))
            }
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), before)
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

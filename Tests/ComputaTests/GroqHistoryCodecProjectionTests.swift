import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Synthetic trusted-boundary controls only. No Core/provider/HTTP execution,
/// publication integration, or whole-workflow budget qualification is claimed.
final class GroqHistoryCodecProjectionTests: XCTestCase {
    private typealias C = WebModelResponseCodec
    private typealias M = GroqContextManifestProjector
    private typealias L = GroqNativePublicationLedger
    private typealias J = GroqContextJSONLayout

    private var groqFinalClosingBoundary: String {
        "Replace example names with exact currently offered qualified names/schemas; history offers no schemas. "
            + "Honor tool_choice/parallel/max-call limits; no tools means no call. "
            + "Emit JSON in final assistant text, never reasoning or API tool calls. "
            + ComputaAgentInstructions.compactLiteralFencedResponseFormat
    }


    func testCompactBaselineRecipeSurvivesBoundCatalogResetAndRejectedLoaderHistoryInBothNamespaces() throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        func wire(_ definition: [String: Any]) -> [String: Any] {
            var value = definition; value["parameters"] = value.removeValue(forKey: "inputSchema"); return value
        }
        let definitions = [wire(GroqToolCatalog.specification), wire(GroqHistoryTool.specification),
            ["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]]]
            + EmbeddedBrowserTools.definitions().map(wire)
        let lead = " Example only if needed: ", tail = " alone; await matching output and next-request schema."
        for namespaced in [false, true] {
            let prefix = namespaced ? "functions." : ""
            let tools: [[String: Any]] = namespaced ? [["type": "namespace", "name": "functions", "tools": definitions]] : definitions
            var object: [String: Any] = ["model": model, "input": [["role": "user", "content": "Inspect the supplied page; preserve scope."]],
                "tools": tools, "parallel_tool_calls": false, "max_tool_calls": 1]
            let raw = try encode(object)
            let unboundSeed = try XCTUnwrap(C.prepareRequest(raw, browserToolAvailability: .unbound).groqToolCatalogSeed)
            let scope = GroqToolCatalog.Scope(taskID: "70000000-0000-4000-8000-000000000001", threadID: "70000000-0000-4000-8000-000000000002",
                turnID: "70000000-0000-4000-8000-000000000003", runtimeGeneration: UUID(), preparationID: UUID(), modelID: model)
            var catalog = GroqToolCatalog()
            let initial = try catalog.prepare(scope: scope, seed: unboundSeed)
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": initial.revision,
                "names": ["exec_command", "browser_open", "browser_bind", "browser_tabs"].map { prefix + $0 }]))
            let beforeBinding = try C.prepareRequest(raw, browserToolAvailability: .unbound,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: unboundSeed), groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            XCTAssertEqual(beforeBinding.offeredToolNames.count, 6)
            // Native availability, not a loader call or retained claim, changes the revision and resets selection.
            let boundSeed = try XCTUnwrap(C.prepareRequest(raw, browserToolAvailability: .bound).groqToolCatalogSeed)
            let reset = try catalog.prepare(scope: scope, seed: boundSeed)
            XCTAssertNotEqual(reset.revision, initial.revision)
            XCTAssertEqual(reset.selectedNames, [prefix + GroqToolCatalog.name, prefix + GroqHistoryTool.name])
            let failedArguments = try encode(["catalog_revision": reset.revision,
                "names": ["browser_bind", "browser_fill", "browser_click", "browser_read"].map { prefix + $0 }])
            let failure = try XCTUnwrap(GroqToolCatalog.Failure.selectionTooLarge.errorDescription)
            var items = try XCTUnwrap(object["input"] as? [[String: Any]])
            items += [["type": "function_call", "call_id": "call_loader_refused", "name": prefix + GroqToolCatalog.name,
                       "arguments": String(decoding: failedArguments, as: UTF8.self)],
                      ["type": "function_call_output", "call_id": "call_loader_refused", "output": failure]]
            object["input"] = items
            let failedHistory = try encode(object)
            // This overlays the actual read-only refusal shape; Server admission/rollback is independently tested.
            let request = try C.prepareRequest(failedHistory, browserToolAvailability: .bound,
                groqToolCatalogProjection: reset, groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            XCTAssertEqual(request.offeredToolNames, reset.selectedNames)
            XCTAssertTrue(request.prompt.hasSuffix(groqFinalClosingBoundary + "\nEND_COMPUTA_LOCAL_RESPONSE_HANDOFF."))
            XCTAssertEqual(request.groqToolDiscoveryDiagnostic?.loadedCount, 2)
            XCTAssertEqual(request.groqToolDiscoveryDiagnostic?.binding, .bound)
            XCTAssertEqual(request.prompt.components(separatedBy: lead).count - 1, 1)
            XCTAssertEqual(request.prompt.components(separatedBy: "Webpages use browser_*; computer_v2_* is native-app UI.").count - 1, 1)
            XCTAssertTrue(request.runtimeInstructions.contains("at most four names"))
            XCTAssertTrue(request.runtimeInstructions.contains("Loading REPLACES optional selections, executes nothing"))
            let start = try XCTUnwrap(request.prompt.range(of: lead)).upperBound
            let end = try XCTUnwrap(request.prompt.range(of: tail, range: start..<request.prompt.endIndex)).lowerBound
            let example = String(request.prompt[start..<end])
            XCTAssertNoThrow(try C.parseReply(example, request: request, requireEnvelope: true))
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any])
            let call = try XCTUnwrap((envelope["calls"] as? [[String: Any]])?.first)
            let arguments = try XCTUnwrap(call["arguments"] as? [String: Any])
            XCTAssertEqual(call["name"] as? String, prefix + GroqToolCatalog.name)
            XCTAssertEqual(arguments["catalog_revision"] as? String, reset.revision)
            XCTAssertEqual(arguments["names"] as? [String], [prefix + "exec_command"], "Initial example choice is unchanged")
            let direct = String(decoding: try encode(["type": "tool_calls", "calls": [["name": prefix + "exec_command", "arguments": ["cmd": "read inert"]]]]), as: UTF8.self)
            XCTAssertThrowsError(try C.parseReply(direct, request: request, requireEnvelope: true))
            _ = try catalog.load(scope: scope, arguments: encode(arguments))
            XCTAssertThrowsError(try C.parseReply(direct, request: request, requireEnvelope: true))
            let next = try C.prepareRequest(failedHistory, browserToolAvailability: .bound,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: boundSeed), groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            XCTAssertNoThrow(try C.parseReply(direct, request: next, requireEnvelope: true))
            XCTAssertEqual(request.continuationRequest, failedHistory)
            XCTAssertEqual(request.toolCatalogDiagnostic.choice, .auto)
            XCTAssertFalse(request.toolCatalogDiagnostic.parallel); XCTAssertEqual(request.toolCatalogDiagnostic.maxToolCalls, 1)
            let shown = try J.parse(displayJSON(request)), original = try J.parse(failedHistory)
            XCTAssertEqual(shown.items.last?.payload?.rawJSON, original.items.last?.payload?.rawJSON)
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: boundSeed).selectedNames.count, 3)
        }
    }

    func testCompactBaselineRecipeUsesTheWholeNativeCounterAfterBoundLoaderRefusalWithoutDroppingPayload() throws {
        let f = try Fixture(output: String(repeating: "older completed literal café ", count: 200))
        var base = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
        var definitions = try XCTUnwrap(base["tools"] as? [[String: Any]])
        definitions += EmbeddedBrowserTools.definitions().map { value in
            var wire = value; wire["parameters"] = wire.removeValue(forKey: "inputSchema"); return wire
        }
        base["tools"] = definitions
        let seed = try XCTUnwrap(C.prepareRequest(encode(base), browserToolAvailability: .bound).groqToolCatalogSeed)
        let projection = try GroqToolCatalog.baseline(for: seed)
        let loaderArguments = String(decoding: try encode(["catalog_revision": projection.revision,
            "names": ["browser_bind", "browser_fill", "browser_click", "browser_read"]]), as: UTF8.self)
        let refusal = try XCTUnwrap(GroqToolCatalog.Failure.selectionTooLarge.errorDescription)
        func source(_ padding: Int) throws -> Data {
            var value = base, items = try XCTUnwrap(base["input"] as? [[String: Any]])
            items.append(["role": "user", "content": "Current exact task café / café 🙂" + String(repeating: " retained", count: padding)])
            items += [["type": "function_call", "call_id": "call_loader_refused", "name": GroqToolCatalog.name, "arguments": loaderArguments],
                      ["type": "function_call_output", "call_id": "call_loader_refused", "output": refusal]]
            value["input"] = items; return try encode(value)
        }
        func request(_ raw: Data) throws -> C.Request {
            try C.prepareRequest(raw, browserToolAvailability: .bound, groqToolCatalogProjection: projection,
                groqDirectTools: .loadedOnly, groqHistoryProjection: f.hook(raw), compactHistoryInventory: true)
        }
        // Exact old no-ordinary tutorial, used only as a fixed presentation comparator.
        let call = String(decoding: try encode(["type": "tool_calls", "calls": [["name": GroqToolCatalog.name,
            "arguments": ["catalog_revision": projection.revision, "names": ["exec_command"]]]]]), as: UTF8.self)
        let old = "Callable names for THIS response: [\"computa_load_tools\",\"computa_read_context\"]. Eligible unloaded inventory names are loadable with computa_load_tools; load needed schemas yourself, not user enablement. Webpages use browser_*; computer_v2_* is native-app UI. Before using an unloaded tool, request its schema with the loader alone and wait for the matching result. Do not call the unloaded tool in that response. Example only: if the task needs the tool named in this example, first return \(call). Then read its exact schema in the next request before supplying arguments. Choose needed available, allowed inventory names; loading does not execute them."
        func legacyPrompt(_ current: C.Request) throws -> String {
            let footer = try XCTUnwrap(current.prompt.range(of: "COMPUTA_LOCAL_RESPONSE_HANDOFF:", options: .backwards)).upperBound
            let start = try XCTUnwrap(current.prompt.range(of: "Callable: ", range: footer..<current.prompt.endIndex)).lowerBound
            let end = try XCTUnwrap(current.prompt.range(of: "\n" + groqFinalClosingBoundary + "\nEND_COMPUTA_LOCAL_RESPONSE_HANDOFF.", range: start..<current.prompt.endIndex)).lowerBound
            return String(current.prompt[..<start]) + old + String(current.prompt[end...])
        }
        var low = 0, high = C.groqMaximumBodyTokens
        XCTAssertGreaterThan(try GroqBodyTokenCounter.tokenCount(request(source(high)).prompt), C.groqMaximumBodyTokens)
        while low < high {
            let mid = (low + high + 1) / 2
            if try GroqBodyTokenCounter.tokenCount(request(source(mid)).prompt) <= C.groqMaximumBodyTokens { low = mid }
            else { high = mid - 1 }
        }
        let raw = try source(low), current = try request(raw)
        let actualUnits = try GroqBodyTokenCounter.tokenCount(current.prompt)
        let legacyUnits = try GroqBodyTokenCounter.tokenCount(legacyPrompt(current))
        XCTAssertLessThan(actualUnits, legacyUnits)
        XCTAssertLessThanOrEqual(actualUnits, C.groqMaximumBodyTokens)
        XCTAssertGreaterThan(legacyUnits, C.groqMaximumBodyTokens)
        let admitted = try C.prepareBudgetedGroqRequest(raw, availability: .bound, projection: projection,
            model: f.binding.scope.modelID, loadedOnly: true, compactHistoryInventory: true, historyProjection: f.hook(raw))
        XCTAssertEqual(admitted.units, actualUnits)
        XCTAssertEqual(admitted.request.prompt, current.prompt)
        XCTAssertEqual(current.continuationRequest, raw)
        XCTAssertEqual(current.groqToolCatalogSeed?.registeredDefinitionsJSON, seed.registeredDefinitionsJSON)
        XCTAssertEqual(current.offeredToolNames, projection.selectedNames)
        let plan = try XCTUnwrap(current.groqHistoryPlan)
        XCTAssertGreaterThan(plan.replacedFields, 0)
        let displayed = try J.parse(displayJSON(current)), original = try J.parse(raw)
        XCTAssertEqual(displayed.items.last?.payload?.rawJSON, original.items.last?.payload?.rawJSON)
        let failedCall = try XCTUnwrap(displayed.items.first { $0.callID == "call_loader_refused" && $0.kind == .functionCall })
        XCTAssertEqual(failedCall.payload?.literalUTF8, Data(loaderArguments.utf8))
        XCTAssertTrue(current.prompt.contains("No change or execution"))
        XCTAssertEqual(C.groqMaximumBodyTokens, 6_000)
        // This is a calibrated synthetic boundary test, not a replay or qualification of the live6115-unit request.
    }

    func testReplacedOptionalSelectionEmitsAValidatedBrowserEntryReloadForBothNativeNamespaces() throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        func wire(_ definition: [String: Any]) -> [String: Any] {
            var value = definition; value["parameters"] = value.removeValue(forKey: "inputSchema"); return value
        }
        let definitions: [[String: Any]] = [wire(GroqToolCatalog.specification), wire(GroqHistoryTool.specification),
            ["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]],
            ["type": "custom", "name": "apply_patch"]] + ComputerV2ToolContract.referenceSpecs(for: model).map(wire)
            + EmbeddedBrowserTools.definitions().map(wire)
        let lead = " Entry if needed: "
        let tail = "; await next-request schema. Load eligible names yourself; no user enablement. Webpages use browser_*; computer_v2_* is native-app UI."
        for namespaced in [false, true] {
            let prefix = namespaced ? "functions." : ""
            let tools: [[String: Any]] = namespaced ? [["type": "namespace", "name": "functions", "tools": definitions]] : definitions
            let raw = try encode(["model": model, "input": "Use the supplied website after coding.", "tools": tools,
                "parallel_tool_calls": true, "max_tool_calls": 2])
            let seed = try XCTUnwrap(C.prepareRequest(raw, browserToolAvailability: .unbound).groqToolCatalogSeed)
            let scope = GroqToolCatalog.Scope(taskID: "50000000-0000-4000-8000-000000000001", threadID: "50000000-0000-4000-8000-000000000002",
                turnID: "50000000-0000-4000-8000-000000000003", runtimeGeneration: UUID(), preparationID: UUID(), modelID: model)
            var catalog = GroqToolCatalog()
            let initial = try catalog.prepare(scope: scope, seed: seed)
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": initial.revision,
                "names": ["exec_command", "browser_open", "browser_bind", "browser_tabs"].map { prefix + $0 }]))
            let first = try C.prepareRequest(raw, browserToolAvailability: .unbound,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: seed), groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            XCTAssertEqual(first.groqToolDiscoveryDiagnostic?.loadedCount, 6)
            XCTAssertEqual(first.groqToolDiscoveryDiagnostic?.offeredEntryMask, 6)
            XCTAssertFalse(first.prompt.contains(lead))
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": initial.revision, "names": [prefix + "apply_patch"]]))
            let replaced = try C.prepareRequest(raw, browserToolAvailability: .unbound,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: seed), groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            XCTAssertEqual(replaced.offeredToolNames, Set([prefix + GroqToolCatalog.name, prefix + GroqHistoryTool.name, prefix + "apply_patch"]))
            XCTAssertEqual(replaced.groqToolDiscoveryDiagnostic?.loadedCount, 3)
            XCTAssertEqual(replaced.groqToolDiscoveryDiagnostic?.discoverableEntryMask, 6)
            XCTAssertEqual(replaced.groqToolDiscoveryDiagnostic?.offeredEntryMask, 0)
            XCTAssertEqual(replaced.prompt.components(separatedBy: lead).count, 2)
            let start = try XCTUnwrap(replaced.prompt.range(of: lead)).upperBound
            let end = try XCTUnwrap(replaced.prompt.range(of: tail, range: start..<replaced.prompt.endIndex)).lowerBound
            let example = String(replaced.prompt[start..<end])
            XCTAssertNoThrow(try C.parseReply(example, request: replaced, requireEnvelope: true))
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any])
            let calls = try XCTUnwrap(envelope["calls"] as? [[String: Any]])
            XCTAssertEqual(envelope["type"] as? String, "tool_calls"); XCTAssertEqual(calls.count, 1)
            let call = try XCTUnwrap(calls.first)
            XCTAssertEqual(call["name"] as? String, prefix + GroqToolCatalog.name)
            let arguments = try XCTUnwrap(call["arguments"] as? [String: Any])
            XCTAssertEqual(Set(arguments.keys), ["catalog_revision", "names"])
            XCTAssertEqual(arguments["catalog_revision"] as? String, initial.revision)
            XCTAssertEqual(arguments["names"] as? [String], [prefix + "browser_open"])
            let direct = String(decoding: try encode(["type": "tool_calls", "calls": [["name": prefix + "browser_open",
                "arguments": ["url": "http://127.0.0.1:4242/"]]]]), as: UTF8.self)
            XCTAssertThrowsError(try C.parseReply(direct, request: replaced, requireEnvelope: true))
            _ = try catalog.load(scope: scope, arguments: encode(arguments))
            // A load changes only the next request; it never mutates an already admitted response.
            XCTAssertThrowsError(try C.parseReply(direct, request: replaced, requireEnvelope: true))
            let reloaded = try C.prepareRequest(raw, browserToolAvailability: .unbound,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: seed), groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            XCTAssertNoThrow(try C.parseReply(direct, request: reloaded, requireEnvelope: true))
            XCTAssertEqual(reloaded.groqToolDiscoveryDiagnostic?.offeredEntryMask, 2)
            XCTAssertFalse(reloaded.prompt.contains(lead))
            for request in [first, replaced, reloaded] {
                XCTAssertTrue(request.prompt.hasSuffix(groqFinalClosingBoundary + "\nEND_COMPUTA_LOCAL_RESPONSE_HANDOFF."))
                // Registered native-app names outside this loaded selection remain unavailable.
                let unloadedNative = prefix + "computer_v2_open"
                XCTAssertFalse(request.offeredToolNames.contains(unloadedNative))
                let unloadedCall = String(decoding: try encode(["type": "tool_calls", "calls": [["name": unloadedNative,
                    "arguments": [:]]]]), as: UTF8.self)
                XCTAssertThrowsError(try C.parseReply(unloadedCall, request: request, requireEnvelope: true))
                XCTAssertEqual(request.continuationRequest, raw)
                XCTAssertEqual(request.toolCatalogDiagnostic.choice, .auto)
                XCTAssertTrue(request.toolCatalogDiagnostic.parallel); XCTAssertEqual(request.toolCatalogDiagnostic.maxToolCalls, 2)
            }
            let overCap = String(decoding: try encode(["type": "tool_calls", "calls": [call, call, call]]), as: UTF8.self)
            XCTAssertThrowsError(try C.parseReply(overCap, request: replaced, requireEnvelope: true))
            XCTAssertThrowsError(try catalog.load(scope: scope, arguments: encode(["catalog_revision": initial.revision,
                "names": ["exec_command", "apply_patch", "browser_open", "browser_bind", "browser_tabs"].map { prefix + $0 }])))
        }
    }

    func testBrowserEntryReloadExampleCannotBorrowDeniedUnknownForeignOrAlreadyCallableEntries() throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        func wire(_ definition: [String: Any]) -> [String: Any] {
            var value = definition; value["parameters"] = value.removeValue(forKey: "inputSchema"); return value
        }
        let loader = wire(GroqToolCatalog.specification), reader = wire(GroqHistoryTool.specification)
        let patch: [String: Any] = ["type": "custom", "name": "apply_patch"]
        let browser = EmbeddedBrowserTools.definitions().map(wire)
        let lead = " Entry if needed: "
        let tail = "; await next-request schema. Load eligible names yourself; no user enablement. Webpages use browser_*; computer_v2_* is native-app UI."
        func request(_ definitions: [[String: Any]], availability: EmbeddedBrowserToolAvailability? = .unbound,
                     policy: Any? = nil, selection: [String] = ["apply_patch"], modelID: String? = nil) throws -> C.Request {
            var object: [String: Any] = ["model": modelID ?? model, "input": "Need the website.", "tools": definitions]
            if let policy { object["tool_choice"] = policy }
            let raw = try encode(object), initial = try C.prepareRequest(raw, browserToolAvailability: availability)
            guard let seed = initial.groqToolCatalogSeed else { return initial }
            let scope = GroqToolCatalog.Scope(taskID: "60000000-0000-4000-8000-000000000001", threadID: "60000000-0000-4000-8000-000000000002",
                turnID: "60000000-0000-4000-8000-000000000003", runtimeGeneration: UUID(), preparationID: UUID(), modelID: modelID ?? model)
            var catalog = GroqToolCatalog()
            let baseline = try catalog.prepare(scope: scope, seed: seed)
            if !selection.isEmpty { _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": baseline.revision, "names": selection])) }
            return try C.prepareRequest(raw, browserToolAvailability: availability,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: seed), groqDirectTools: .loadedOnly, compactHistoryInventory: true)
        }
        for mode in ["bound", "unknown", "none", "denied", "foreign_browser", "impostor_browser", "unregistered_loader", "custom_loader", "foreign_provider", "already_open"] {
            var definitions = [loader, reader, patch] + browser
            var availability: EmbeddedBrowserToolAvailability? = .unbound
            var policy: Any?, selected = ["apply_patch"], modelID: String?
            switch mode {
            case "bound": availability = .bound
            case "unknown": availability = nil
            case "none": policy = "none"; selected = []
            case "denied": policy = ["type": "allowed_tools", "tools": [GroqToolCatalog.name, GroqHistoryTool.name, "apply_patch"].map { ["type": $0 == "apply_patch" ? "custom" : "function", "name": $0] }]
            case "foreign_browser": definitions = [loader, reader, patch, ["type": "namespace", "name": "foreign", "tools": browser]]
            case "impostor_browser": definitions = [loader, reader, patch,
                ["type": "function", "name": "browser_open", "parameters": ["type": "object", "properties": [:]]], ["type": "custom", "name": "browser_bind"]]
            case "unregistered_loader": var fake = loader; fake["parameters"] = ["type": "object", "properties": [:]]; definitions = [fake, reader, patch] + browser
            case "custom_loader": definitions = [["type": "custom", "name": GroqToolCatalog.name], reader, patch] + browser
            case "foreign_provider": modelID = "browser/claude"
            case "already_open": selected = ["browser_open"]
            default: break
            }
            let value = try request(definitions, availability: availability, policy: policy, selection: selected, modelID: modelID)
            XCTAssertFalse(value.prompt.contains(lead), mode)
        }
        // A permitted native bind is the fallback only when open is excluded by tool_choice.
        let bindPolicy: [String: Any] = ["type": "allowed_tools", "tools": [GroqToolCatalog.name, GroqHistoryTool.name, "apply_patch", "browser_bind"].map { ["type": $0 == "apply_patch" ? "custom" : "function", "name": $0] }]
        let bind = try request([loader, reader, patch] + browser, policy: bindPolicy)
        let start = try XCTUnwrap(bind.prompt.range(of: lead)).upperBound
        let end = try XCTUnwrap(bind.prompt.range(of: tail, range: start..<bind.prompt.endIndex)).lowerBound
        let example = String(bind.prompt[start..<end])
        XCTAssertNoThrow(try C.parseReply(example, request: bind, requireEnvelope: true))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any])
        let calls = try XCTUnwrap(envelope["calls"] as? [[String: Any]])
        let arguments = try XCTUnwrap(calls.first?["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["names"] as? [String], ["browser_bind"])
        XCTAssertEqual(bind.toolCatalogDiagnostic.choice, .allowedAuto)
    }

    func testGroqToolDiscoveryDiagnosticTracksTheExactFourSelectionAndSelfServiceEntryWithoutChangingAuthority() throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        func wire(_ definition: [String: Any]) -> [String: Any] {
            var result = definition; result["parameters"] = result.removeValue(forKey: "inputSchema"); return result
        }
        let local = ComputerV2ToolContract.referenceSpecs(for: model).filter {
            ["computer_v2_open", "computer_v2_fill"].contains($0["name"] as? String ?? "")
        }.map(wire)
        let exec: [String: Any] = ["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]]
        let definitions = [wire(GroqToolCatalog.specification), wire(GroqHistoryTool.specification), exec,
            ["type": "custom", "name": "apply_patch"]] + local + EmbeddedBrowserTools.definitions().map(wire)
        for namespaced in [false, true] {
            let prefix = namespaced ? "functions." : ""
            let tools: [[String: Any]] = namespaced ? [["type": "namespace", "name": "functions", "tools": definitions]] : definitions
            let raw = try encode(["model": model, "input": "PRIVATE_DIAGNOSTIC https://private.invalid/", "tools": tools])
            let seed = try XCTUnwrap(C.prepareRequest(raw, browserToolAvailability: .unbound).groqToolCatalogSeed)
            let scope = GroqToolCatalog.Scope(taskID: "40000000-0000-4000-8000-000000000001", threadID: "40000000-0000-4000-8000-000000000002",
                turnID: "40000000-0000-4000-8000-000000000003", runtimeGeneration: UUID(), preparationID: UUID(), modelID: model)
            var catalog = GroqToolCatalog()
            let initial = try catalog.prepare(scope: scope, seed: seed)
            let exactFour = ["apply_patch", "exec_command", "computer_v2_open", "computer_v2_fill"].map { prefix + $0 }
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": initial.revision, "names": exactFour]))
            let selected = try catalog.prepare(scope: scope, seed: seed)
            let request = try C.prepareRequest(raw, browserToolAvailability: .unbound, groqToolCatalogProjection: selected,
                groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            let d = try XCTUnwrap(request.groqToolDiscoveryDiagnostic)
            XCTAssertEqual(d.binding, .unbound); XCTAssertEqual(d.revisionSHA256, initial.revision)
            XCTAssertEqual(d.loadedCount, 6); XCTAssertEqual(d.unloadedDiscoverableCount, 3)
            XCTAssertTrue(d.loaderOffered); XCTAssertEqual(d.discoverableEntryMask, 6); XCTAssertEqual(d.offeredEntryMask, 0)
            XCTAssertEqual(request.offeredToolNames, Set(exactFour + [prefix + GroqToolCatalog.name, prefix + GroqHistoryTool.name]))
            XCTAssertEqual(request.continuationRequest, raw)
            XCTAssertEqual(d.requestPromptSHA256, SHA256.hash(data: Data(request.prompt.utf8)).map { String(format: "%02x", $0) }.joined())
            let encoded = try JSONEncoder().encode(d)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(Set(fields.keys), ["binding", "revisionSHA256", "loadedCount", "unloadedDiscoverableCount", "loaderOffered",
                "discoverableEntryMask", "offeredEntryMask", "requestPromptSHA256"])
            let finite = String(decoding: encoded, as: UTF8.self) + d.logFields
            for forbidden in ["PRIVATE_DIAGNOSTIC", "private.invalid", "browser_open", "computer_v2_fill", "arguments", "parameters"] {
                XCTAssertFalse(finite.contains(forbidden))
            }
            XCTAssertLessThan(d.logFields.utf8.count, 512)
            XCTAssertFalse(request.prompt.contains("groqToolDiscovery")); XCTAssertFalse(request.prompt.contains("requestPromptSHA256"))
            XCTAssertEqual(request.toolCatalogDiagnostic.offeredCount, 6)
            XCTAssertEqual(request.toolCatalogDiagnostic.offeredBrowserMask, 0)
            let readReply = try encode(["type": "tool_calls", "calls": [["name": prefix + "browser_read", "arguments": [:]]]])
            XCTAssertThrowsError(try C.parseReply(String(decoding: readReply, as: UTF8.self), request: request, requireEnvelope: true))
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": selected.revision, "names": [prefix + "browser_open"]]))
            let entry = try C.prepareRequest(raw, browserToolAvailability: .unbound,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: seed), groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            let e = try XCTUnwrap(entry.groqToolDiscoveryDiagnostic)
            XCTAssertTrue(e.loaderOffered); XCTAssertEqual(e.loadedCount, 3); XCTAssertEqual(e.unloadedDiscoverableCount, 6)
            XCTAssertEqual(e.discoverableEntryMask, 6); XCTAssertEqual(e.offeredEntryMask, 2)
            XCTAssertEqual(entry.continuationRequest, raw)
            let boundSeed = try XCTUnwrap(C.prepareRequest(raw, browserToolAvailability: .bound).groqToolCatalogSeed)
            let boundCatalog = try catalog.prepare(scope: scope, seed: boundSeed)
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": boundCatalog.revision,
                "names": ["browser_read", "browser_click", "browser_fill", "browser_close"].map { prefix + $0 }]))
            let bound = try C.prepareRequest(raw, browserToolAvailability: .bound,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: boundSeed), groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            let b = try XCTUnwrap(bound.groqToolDiscoveryDiagnostic)
            XCTAssertEqual(b.binding, .bound); XCTAssertEqual(b.loadedCount, 6); XCTAssertEqual(b.unloadedDiscoverableCount, 10)
            XCTAssertTrue(b.loaderOffered); XCTAssertEqual(b.discoverableEntryMask, 6); XCTAssertEqual(b.offeredEntryMask, 0)
            XCTAssertNoThrow(try C.parseReply(String(decoding: readReply, as: UTF8.self), request: bound, requireEnvelope: true))
            XCTAssertEqual(bound.continuationRequest, raw)
        }
    }

    func testGroqToolDiscoveryDiagnosticRespectsNoneAndCannotBorrowForeignOrImpostorCapabilities() throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        func wire(_ definition: [String: Any]) -> [String: Any] {
            var result = definition; result["parameters"] = result.removeValue(forKey: "inputSchema"); return result
        }
        let loader = wire(GroqToolCatalog.specification), browser = EmbeddedBrowserTools.definitions().map(wire)
        let raw = try encode(["model": model, "input": "PRIVATE input", "tools": [loader] + browser, "tool_choice": "none"])
        let seed = try XCTUnwrap(C.prepareRequest(raw, browserToolAvailability: .unbound).groqToolCatalogSeed)
        let none = try C.prepareRequest(raw, browserToolAvailability: .unbound,
            groqToolCatalogProjection: GroqToolCatalog.baseline(for: seed), compactHistoryInventory: true)
        let n = try XCTUnwrap(none.groqToolDiscoveryDiagnostic)
        XCTAssertEqual(n.binding, .unbound); XCTAssertEqual(n.loadedCount, 0); XCTAssertEqual(n.unloadedDiscoverableCount, 0)
        XCTAssertFalse(n.loaderOffered); XCTAssertEqual(n.discoverableEntryMask, 0); XCTAssertEqual(n.offeredEntryMask, 0)
        XCTAssertEqual(none.toolCatalogDiagnostic.choice, .none); XCTAssertEqual(none.continuationRequest, raw)
        XCTAssertThrowsError(try C.parseReply(#"{"type":"tool_calls","calls":[{"name":"computa_load_tools","arguments":{}}]}"#,
            request: none, requireEnvelope: true))
        var impostor = loader; impostor["parameters"] = ["type": "object", "properties": [:]]
        for tools in [[impostor] + browser, [["type": "custom", "name": GroqToolCatalog.name]] + browser,
                      [["type": "namespace", "name": "foreign", "tools": [loader] + browser]]] {
            let data = try encode(["model": model, "input": "PRIVATE foreign", "tools": tools])
            let request = try C.prepareRequest(data, browserToolAvailability: .unbound)
            XCTAssertNil(request.groqToolCatalogSeed); XCTAssertNil(request.groqToolDiscoveryDiagnostic)
            XCTAssertEqual(request.continuationRequest, data)
        }
        for foreign in ["browser/claude", "browser/chatgpt"] {
            let data = try encode(["model": foreign, "input": "PRIVATE foreign", "tools": [loader] + browser])
            let request = try C.prepareRequest(data, browserToolAvailability: .unbound)
            XCTAssertNil(request.groqToolDiscoveryDiagnostic)
            XCTAssertEqual(request.continuationRequest, data)
        }
        let fakeEntries: [[String: Any]] = [["type": "function", "name": "browser_open", "parameters": ["type": "object", "properties": [:]]],
            ["type": "custom", "name": "browser_bind"]]
        let fakeRaw = try encode(["model": model, "input": "Do not trust tool names.", "tools": [loader] + fakeEntries])
        let fakeSeed = try XCTUnwrap(C.prepareRequest(fakeRaw, browserToolAvailability: .unbound).groqToolCatalogSeed)
        let baseline = try GroqToolCatalog.baseline(for: fakeSeed)
        let projection = GroqToolCatalog.Projection(revision: baseline.revision, inventory: baseline.inventory,
            selectedNames: baseline.selectedNames.union(["browser_open", "browser_bind"]))
        let fake = try C.prepareRequest(fakeRaw, browserToolAvailability: .unbound, groqToolCatalogProjection: projection)
        let f = try XCTUnwrap(fake.groqToolDiscoveryDiagnostic)
        XCTAssertTrue(f.loaderOffered); XCTAssertEqual(f.discoverableEntryMask, 0); XCTAssertEqual(f.offeredEntryMask, 0)
        XCTAssertEqual(fake.continuationRequest, fakeRaw)
    }

    func testLoadedComputerSelectionKeepsBrowserEntrySelfServiceWithoutGrantingUnloadedSchemas() throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        let localNames = ["exec_command", "computer_v2_open", "computer_v2_fill", "computer_v2_read_page"]
        var loader = GroqToolCatalog.specification, reader = GroqHistoryTool.specification
        loader["parameters"] = loader.removeValue(forKey: "inputSchema")
        reader["parameters"] = reader.removeValue(forKey: "inputSchema")
        let computers = ComputerV2ToolContract.referenceSpecs(for: model).filter { localNames.contains($0["name"] as? String ?? "") }.map { value in
            var wire = value; wire["parameters"] = wire.removeValue(forKey: "inputSchema"); return wire
        }
        let browser = EmbeddedBrowserTools.definitions().map { value in
            var wire = value; wire["parameters"] = wire.removeValue(forKey: "inputSchema"); return wire
        }
        let exec: [String: Any] = ["type": "function", "name": "exec_command", "parameters": ["type": "object",
            "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]]
        for namespaced in [false, true] {
            let prefix = namespaced ? "functions." : ""
            let definitions = [loader, reader, exec] + computers + browser
            let tools: [[String: Any]] = namespaced ? [["type": "namespace", "name": "functions", "tools": definitions]] : definitions
            let data = try encode(["model": model, "instructions": "Keep native scope and permissions.", "input": "Inspect the synthetic webpage.",
                "tools": tools, "parallel_tool_calls": false])
            let seed = try XCTUnwrap(C.prepareRequest(data, browserToolAvailability: .unbound).groqToolCatalogSeed)
            let scope = GroqToolCatalog.Scope(taskID: "40000000-0000-4000-8000-000000000001", threadID: "40000000-0000-4000-8000-000000000002",
                turnID: "40000000-0000-4000-8000-000000000003", runtimeGeneration: UUID(), preparationID: UUID(), modelID: model)
            var catalog = GroqToolCatalog()
            let initial = try catalog.prepare(scope: scope, seed: seed)
            let selected = Set(localNames.map { prefix + $0 })
            let receipt = try catalog.load(scope: scope, arguments: encode(["catalog_revision": initial.revision, "names": selected.sorted()]),
                lastOfferedNames: initial.selectedNames)
            let receiptObject = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
            XCTAssertEqual(Set(try XCTUnwrap(receiptObject["loaded"] as? [String])), selected)
            XCTAssertEqual(receiptObject["execution"] as? Bool, false)
            let loaded = try catalog.prepare(scope: scope, seed: seed)
            let request = try C.prepareRequest(data, browserToolAvailability: .unbound, groqToolCatalogProjection: loaded,
                groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            let open = prefix + "browser_open", load = prefix + GroqToolCatalog.name
            XCTAssertEqual(request.offeredToolNames, selected.union([load, prefix + GroqHistoryTool.name]))
            XCTAssertTrue(loaded.loaderChoices.contains(open)); XCTAssertFalse(loaded.loaderChoices.contains(prefix + "browser_read"))
            XCTAssertFalse(request.offeredToolNames.contains(open)); XCTAssertTrue(request.offeredToolNames.contains(load))
            XCTAssertTrue(request.prompt.contains(" Entry if needed: " + String(decoding: try encode(["type": "tool_calls", "calls": [["name": load, "arguments": ["catalog_revision": initial.revision, "names": [open]]]]]), as: UTF8.self)))
            XCTAssertTrue(request.prompt.contains("Load eligible names yourself; no user enablement."))
            XCTAssertTrue(request.prompt.contains("Webpages use browser_*; computer_v2_* is native-app UI."))
            let openReply = String(decoding: try encode(["type": "tool_calls", "calls": [["name": open,
                "arguments": ["url": "http://127.0.0.1:62341/"]]]]), as: UTF8.self)
            XCTAssertThrowsError(try C.parseReply(openReply, request: request, requireEnvelope: true)) {
                XCTAssertEqual($0 as? C.Failure, .unknownTool(open))
            }
            XCTAssertThrowsError(try catalog.load(scope: scope, arguments: encode(["catalog_revision": loaded.revision,
                "names": [prefix + "browser_read"]]), lastOfferedNames: request.offeredToolNames)) {
                guard case .unavailableSelection = $0 as? GroqToolCatalog.Failure else { return XCTFail("Deferred page tools must remain unavailable until bind") }
            }
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), loaded)
            let loadReply = String(decoding: try encode(["type": "tool_calls", "calls": [["name": load,
                "arguments": ["catalog_revision": loaded.revision, "names": [open]]]]]), as: UTF8.self)
            XCTAssertNoThrow(try C.parseReply(loadReply, request: request, requireEnvelope: true))
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": loaded.revision, "names": [open]]), lastOfferedNames: request.offeredToolNames)
            let next = try C.prepareRequest(data, browserToolAvailability: .unbound, groqToolCatalogProjection: catalog.prepare(scope: scope, seed: seed),
                groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            XCTAssertEqual(next.offeredToolNames, [load, prefix + GroqHistoryTool.name, open])
            XCTAssertNoThrow(try C.parseReply(openReply, request: next, requireEnvelope: true))
            XCTAssertEqual(next.continuationRequest, data); XCTAssertEqual(request.continuationRequest, data)
            XCTAssertEqual(next.groqToolCatalogSeed?.registeredDefinitionsJSON, seed.registeredDefinitionsJSON)
            XCTAssertTrue(next.prompt.contains("Webpages use browser_*; computer_v2_* is native-app UI."), "A loaded native browser entry still differs from native-app UI")
            let deferred = "Registered page tools await successful open/bind"
            XCTAssertTrue(request.prompt.contains(deferred)); XCTAssertTrue(next.prompt.contains(deferred))
            XCTAssertTrue(next.prompt.contains("Then load only offered, allowed schemas with current catalog_revision."))
            XCTAssertTrue(next.prompt.contains("Do not call deferred tools now; respect actual denials."))
            XCTAssertEqual(next.prompt.components(separatedBy: "Webpages use browser_*; computer_v2_* is native-app UI.").count - 1, 1)
            let fullUnbound = try C.prepareRequest(data, browserToolAvailability: .unbound)
            let fullBound = try C.prepareRequest(data, browserToolAvailability: .bound)
            XCTAssertTrue(fullUnbound.runtimeInstructions.contains("COMPUTA_DEFERRED_BROWSER_CAPABILITIES:"))
            XCTAssertFalse(fullUnbound.offeredToolNames.contains(prefix + "browser_read"))
            XCTAssertTrue(fullBound.offeredToolNames.contains(prefix + "browser_read"))
            XCTAssertFalse(fullBound.runtimeInstructions.contains("COMPUTA_DEFERRED_BROWSER_CAPABILITIES:"))
            XCTAssertEqual(fullUnbound.continuationRequest, data); XCTAssertEqual(fullBound.continuationRequest, data)
            // Only the trusted native availability change refreshes eligibility;
            // loading/open arguments above did not pretend to bind a real page.
            let boundSeed = try XCTUnwrap(fullBound.groqToolCatalogSeed)
            let boundCatalog = try catalog.prepare(scope: scope, seed: boundSeed)
            XCTAssertTrue(boundCatalog.loaderChoices.contains(prefix + "browser_read"))
            let pageNames = ["browser_read", "browser_fill", "browser_click", "browser_close"].map { prefix + $0 }
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": boundCatalog.revision, "names": pageNames]),
                lastOfferedNames: boundCatalog.selectedNames)
            let bound = try C.prepareRequest(data, browserToolAvailability: .bound,
                groqToolCatalogProjection: catalog.prepare(scope: scope, seed: boundSeed), groqDirectTools: .loadedOnly,
                compactHistoryInventory: true)
            XCTAssertEqual(bound.offeredToolNames, Set(pageNames).union([load, prefix + GroqHistoryTool.name]))
            XCTAssertFalse(bound.prompt.contains(deferred)); XCTAssertTrue(bound.prompt.contains("Current browser state: native page bound."))
            XCTAssertEqual(bound.continuationRequest, data)
            let readReply = String(decoding: try encode(["type": "tool_calls", "calls": [["name": prefix + "browser_read", "arguments": [:]]]]), as: UTF8.self)
            XCTAssertNoThrow(try C.parseReply(readReply, request: bound, requireEnvelope: true))
            var denied = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            denied["tool_choice"] = "none"
            let deniedData = try encode(denied), deniedSeed = try XCTUnwrap(C.prepareRequest(deniedData, browserToolAvailability: .unbound).groqToolCatalogSeed)
            let noLoader = try C.prepareRequest(deniedData, browserToolAvailability: .unbound, groqToolCatalogProjection: GroqToolCatalog.baseline(for: deniedSeed),
                groqDirectTools: .loadedOnly, compactHistoryInventory: true)
            XCTAssertFalse(noLoader.prompt.contains("load needed schemas yourself, not user enablement"))
            XCTAssertFalse(noLoader.prompt.contains("Webpages use browser_*; computer_v2_* is native-app UI."))
        }
    }

    func testPackedGroqDeferredBrowserHintRequiresRegisteredPagesAndPermittedNativeEntry() throws {
        let f = try Fixture()
        let browser = EmbeddedBrowserTools.definitions().map { value in
            var wire = value; wire["parameters"] = wire.removeValue(forKey: "inputSchema"); return wire
        }
        let entries = browser.filter { ["browser_open", "browser_bind"].contains($0["name"] as? String ?? "") }
        var foreignRead = try XCTUnwrap(browser.first { $0["name"] as? String == "browser_read" })
        foreignRead["parameters"] = ["type": "object", "properties": ["foreign": ["type": "string"]], "additionalProperties": false]
        var foreignOpen = try XCTUnwrap(browser.first { $0["name"] as? String == "browser_open" })
        foreignOpen["parameters"] = ["type": "object", "properties": ["foreign": ["type": "string"]], "additionalProperties": false]
        for mode in ["native", "entry_only", "foreign_page", "foreign_entry", "foreign_namespace", "none", "allowed_native_only", "allowed_entry_only", "unknown_state", "bound"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
            let originalTools = try XCTUnwrap(object["tools"] as? [[String: Any]])
            let additions: [[String: Any]]
            switch mode {
            case "entry_only": additions = entries
            case "foreign_page": additions = entries + [foreignRead]
            case "foreign_entry": additions = [foreignOpen] + browser.filter { $0["name"] as? String == "browser_read" }
            case "foreign_namespace": additions = [["type": "namespace", "name": "foreign", "tools": browser]]
            default: additions = browser
            }
            object["tools"] = originalTools + additions
            if mode == "none" { object["tool_choice"] = "none" }
            if mode == "allowed_native_only" || mode == "allowed_entry_only" {
                let last = mode == "allowed_entry_only" ? "browser_open" : "exec_command"
                object["tool_choice"] = ["type": "allowed_tools", "tools": [GroqToolCatalog.name, GroqHistoryTool.name, last].map {
                    ["type": "function", "name": $0]
                }]
            }
            let data = try encode(object)
            let availability: EmbeddedBrowserToolAvailability? = mode == "unknown_state" ? nil : mode == "bound" ? .bound : .unbound
            let native = try C.prepareRequest(data, browserToolAvailability: availability)
            let seed = try XCTUnwrap(native.groqToolCatalogSeed), projection = try GroqToolCatalog.baseline(for: seed)
            let packed: C.Request
            if mode == "none" {
                XCTAssertThrowsError(try C.prepareRequest(data, browserToolAvailability: availability,
                    groqToolCatalogProjection: projection, groqDirectTools: .loadedOnly,
                    groqHistoryProjection: f.hook(data), compactHistoryInventory: true)) {
                    XCTAssertEqual($0 as? C.Failure, .invalidToolChoice)
                }
                packed = try C.prepareRequest(data, browserToolAvailability: availability,
                    groqToolCatalogProjection: projection, groqDirectTools: .loadedOnly,
                    compactHistoryInventory: true)
                XCTAssertNil(packed.groqHistoryPlan, "Denied tools cannot activate the historical reader")
            } else {
                packed = try C.prepareRequest(data, browserToolAvailability: availability,
                    groqToolCatalogProjection: projection, groqDirectTools: .loadedOnly,
                    groqHistoryProjection: f.hook(data), compactHistoryInventory: true)
                let plan = try XCTUnwrap(packed.groqHistoryPlan)
                XCTAssertGreaterThan(plan.replacedFields, 0, mode)
            }
            XCTAssertEqual(packed.continuationRequest, data, mode)
            XCTAssertEqual(packed.groqToolCatalogSeed?.registeredDefinitionsJSON, seed.registeredDefinitionsJSON, mode)
            let expectsDeferred = mode == "native" || mode == "allowed_entry_only"
            XCTAssertEqual(packed.prompt.contains("Registered page tools await successful open/bind"), expectsDeferred, mode)
            XCTAssertEqual(packed.prompt.contains("without user enablement"), expectsDeferred, mode)
            if expectsDeferred {
                XCTAssertTrue(packed.prompt.contains("Supplied URL: first load browser_open."))
                XCTAssertTrue(packed.prompt.contains("Webpages use browser_*; computer_v2_* is native-app UI."))
                XCTAssertFalse(projection.loaderChoices.contains("browser_read"))
                let scope = GroqToolCatalog.Scope(taskID: f.binding.scope.taskID, threadID: f.binding.scope.threadID,
                    turnID: f.binding.scope.turnID, runtimeGeneration: f.binding.scope.runtimeGeneration,
                    preparationID: f.binding.scope.preparationID, modelID: f.binding.scope.modelID)
                var catalog = GroqToolCatalog(); let initial = try catalog.prepare(scope: scope, seed: seed)
                XCTAssertThrowsError(try catalog.load(scope: scope, arguments: encode(["catalog_revision": initial.revision,
                    "names": ["browser_read"]]), lastOfferedNames: packed.offeredToolNames))
                XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), initial)
                if mode == "allowed_entry_only" {
                    XCTAssertTrue(packed.prompt.contains("tool_choice and permissions still govern"))
                    let bound = try C.prepareRequest(data, browserToolAvailability: .bound)
                    let boundSeed = try XCTUnwrap(bound.groqToolCatalogSeed)
                    let boundCatalog = try catalog.prepare(scope: scope, seed: boundSeed)
                    for name in ["browser_read", "browser_fill", "browser_click"] {
                        XCTAssertFalse(boundCatalog.loaderChoices.contains(name))
                        XCTAssertThrowsError(try catalog.load(scope: scope,
                            arguments: encode(["catalog_revision": boundCatalog.revision, "names": [name]]),
                            lastOfferedNames: bound.offeredToolNames))
                        XCTAssertEqual(try catalog.prepare(scope: scope, seed: boundSeed), boundCatalog)
                    }
                    let read = #"{"type":"tool_calls","calls":[{"name":"browser_read","arguments":{}}]}"#
                    XCTAssertThrowsError(try C.parseReply(read, request: bound, requireEnvelope: true))
                }
            }
            if mode == "none" || mode == "allowed_native_only" || mode == "foreign_entry" || mode == "foreign_namespace" {
                XCTAssertFalse(packed.prompt.contains("Current browser state: unbound."), mode)
            }
            // Projection never makes a deferred/unloaded browser read callable.
            if mode != "bound" {
                let read = #"{"type":"tool_calls","calls":[{"name":"browser_read","arguments":{}}]}"#
                XCTAssertThrowsError(try C.parseReply(read, request: packed, requireEnvelope: true))
            }
        }
    }

    func testKnownNativeRuntimeDedupUsesTrustedBlocksAndPreservesCanonicalRequestAndPayloads() throws {
        let f = try Fixture(output: "Inert historical result"), base = ComputaAgentInstructions.groqReviewedNativeBase(referenceTools: true)
        let policy = ComputaAgentInstructions.developerInstructions(referenceTools: true, embeddedBrowserTools: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
        let foreign = "Unknown native permission/environment policy remains exact.\n"
        object["instructions"] = foreign + base
        var input = try XCTUnwrap(object["input"] as? [[String: Any]])
        input[0]["content"] = policy; object["input"] = input
        let data = try encode(object), compact = try f.request(data: data, compactHistoryInventory: true)
        let legacy = try f.request(data: data, compactHistoryInventory: false)
        XCTAssertEqual(compact.continuationRequest, data); XCTAssertEqual(legacy.continuationRequest, data)
        XCTAssertEqual(compact.offeredToolNames, legacy.offeredToolNames); XCTAssertEqual(compact.customToolNames, legacy.customToolNames)
        XCTAssertEqual(compact.groqToolCatalogSeed?.registeredDefinitionsJSON, legacy.groqToolCatalogSeed?.registeredDefinitionsJSON)
        XCTAssertEqual(try C.completedResponse(for: .message("Inert answer"), request: compact, responseID: "resp_same", createdAt: 1),
            try C.completedResponse(for: .message("Inert answer"), request: legacy, responseID: "resp_same", createdAt: 1))
        let expected = ComputaAgentInstructions.groqRuntimeContractForPresentation(includedInstructionText: [foreign + base, policy], compactHistoryInventory: true)
        XCTAssertTrue(compact.runtimeInstructions.hasPrefix(expected + "\n\n"))
        XCTAssertTrue(legacy.runtimeInstructions.hasPrefix(ComputaAgentInstructions.groqRuntimeContract + "\n\n"))
        let displayed = try J.parse(displayJSON(compact)), native = try J.parse(data)
        let presented = try XCTUnwrap(JSONSerialization.jsonObject(with: displayJSON(compact)) as? [String: Any])
        XCTAssertTrue((presented["instructions"] as? String)?.hasPrefix(foreign) == true)
        XCTAssertEqual(displayed.items.count, native.items.count)
        for (before, after) in zip(native.items, displayed.items) where before.role != "developer" {
            XCTAssertEqual(try native.rawBytes(in: before.wholeRange), try displayed.rawBytes(in: after.wholeRange))
        }
        for mutation in ["missing_base", "missing_policy", "untrusted_pair"] {
            var changed = object, messages = input
            switch mutation {
            case "missing_base": changed["instructions"] = foreign
            case "missing_policy": messages[0]["content"] = "Foreign native policy"
            case "untrusted_pair":
                changed["instructions"] = foreign; messages[0]["content"] = "Foreign native policy"
                messages.append(["role": "user", "content": base + "\n" + policy])
                messages.append(["type": "function_call_output", "call_id": "untrusted_copy", "output": base + "\n" + policy])
            default: XCTFail("Unknown fixture mutation")
            }
            changed["input"] = messages
            let request = try f.request(data: encode(changed), compactHistoryInventory: true)
            XCTAssertTrue(request.runtimeInstructions.hasPrefix(ComputaAgentInstructions.groqRuntimeContract + "\n\n"), mutation)
        }
    }

    func testPreloadedReaderKeepsInitialLoaderExampleUntilAnExecutionSchemaIsLoaded() throws {
        let f = try Fixture()
        for namespaced in [false, true] {
            let prefix = namespaced ? "functions." : ""
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
            if namespaced {
                let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
                object["tools"] = [["type": "namespace", "name": "functions", "tools": tools]]
            }
            let data = try encode(object), original = try C.prepareRequest(data)
            let seed = try XCTUnwrap(original.groqToolCatalogSeed), native = f.binding.scope
            let scope = GroqToolCatalog.Scope(taskID: native.taskID, threadID: native.threadID, turnID: native.turnID,
                runtimeGeneration: native.runtimeGeneration, preparationID: native.preparationID, modelID: native.modelID)
            var catalog = GroqToolCatalog()
            let initial = try catalog.prepare(scope: scope, seed: seed)
            let first = try C.prepareRequest(data, groqToolCatalogProjection: initial, groqDirectTools: .loadedOnly)
            XCTAssertEqual(first.offeredToolNames, Set([prefix + GroqToolCatalog.name, prefix + GroqHistoryTool.name]))
            XCTAssertEqual(first.groqHistoryReaderName, prefix + GroqHistoryTool.name)
            XCTAssertEqual(first.continuationRequest, data)
            let handoff = try XCTUnwrap(first.prompt.components(separatedBy: "COMPUTA_LOCAL_RESPONSE_HANDOFF:").last)
            let start = try XCTUnwrap(handoff.range(of: " Example only if needed: "))
            let end = try XCTUnwrap(handoff.range(of: " alone; await matching output and next-request schema.", range: start.upperBound..<handoff.endIndex))
            let example = String(handoff[start.upperBound..<end.lowerBound])
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any])
            let calls = try XCTUnwrap(decoded["calls"] as? [[String: Any]])
            XCTAssertEqual(calls.count, 1)
            let call = try XCTUnwrap(calls.first), arguments = try XCTUnwrap(call["arguments"] as? [String: Any])
            XCTAssertEqual(call["name"] as? String, prefix + GroqToolCatalog.name)
            XCTAssertEqual(Set(arguments.keys), ["catalog_revision", "names"])
            XCTAssertEqual(arguments["catalog_revision"] as? String, initial.revision)
            XCTAssertEqual(arguments["names"] as? [String], [prefix + "exec_command"])
            XCTAssertNoThrow(try C.parseReply(example, request: first, requireEnvelope: true))
            let exec = String(decoding: try encode(["type": "tool_calls", "calls": [["name": prefix + "exec_command",
                "arguments": ["cmd": "read inert source"]]]]), as: UTF8.self)
            XCTAssertThrowsError(try C.parseReply(exec, request: first, requireEnvelope: true)) {
                XCTAssertEqual($0 as? C.Failure, .unknownTool(prefix + "exec_command"))
            }
            // Use the actual native read-only catalog transition, not a forged
            // selectedNames value. Loading this schema executes no command.
            let receipt = try catalog.load(scope: scope, arguments: encode(arguments), lastOfferedNames: first.offeredToolNames)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
            XCTAssertEqual(value["execution"] as? Bool, false)
            let loaded = try C.prepareRequest(data, groqToolCatalogProjection: catalog.prepare(scope: scope, seed: seed), groqDirectTools: .loadedOnly)
            XCTAssertTrue(loaded.offeredToolNames.contains(prefix + "exec_command"))
            XCTAssertEqual(loaded.groqHistoryReaderName, prefix + GroqHistoryTool.name)
            XCTAssertEqual(loaded.continuationRequest, data)
            let direct = try XCTUnwrap(loaded.prompt.components(separatedBy: "COMPUTA_LOCAL_RESPONSE_HANDOFF:").last)
            XCTAssertTrue(direct.contains("Call listed tools directly."))
            XCTAssertFalse(direct.contains(" Example only if needed: "))
            XCTAssertNoThrow(try C.parseReply(exec, request: loaded, requireEnvelope: true))
        }
    }

    func testTypedPublishedProjectionPreservesExactContinuationPayloadsAndSelectedSchemas() throws {
        let f = try Fixture()
        let request = try f.request(history: f.hook())
        let plan = try XCTUnwrap(request.groqHistoryPlan)
        XCTAssertGreaterThan(plan.replacedFields, 0)
        XCTAssertEqual(request.continuationRequest, f.source)
        XCTAssertEqual(request.groqHistoryReaderName, GroqHistoryTool.name)
        XCTAssertFalse(request.groqHistoryPreviewOnly)
        XCTAssertEqual(request.offeredToolNames, Set([GroqToolCatalog.name, GroqHistoryTool.name]))
        let original = try J.parse(f.source), displayed = try J.parse(displayJSON(request))
        for id in ["call_old", "call_latest"] {
            let before = try XCTUnwrap(original.items.first { $0.callID == id && $0.kind == .functionCall }?.payload)
            let after = try XCTUnwrap(displayed.items.first { $0.callID == id && $0.kind == .functionCall }?.payload)
            XCTAssertEqual(after.rawJSON, before.rawJSON)
        }
        let latest = try XCTUnwrap(original.items.last?.payload)
        XCTAssertEqual(displayed.items.last?.payload?.rawJSON, latest.rawJSON)
        let sourceUser = try XCTUnwrap(original.items.first { $0.role == "user" })
        let displayUser = try XCTUnwrap(displayed.items.first { $0.role == "user" })
        XCTAssertEqual(try original.rawBytes(in: sourceUser.wholeRange), try displayed.rawBytes(in: displayUser.wholeRange))
        let old = try XCTUnwrap(original.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload)
        let value = try XCTUnwrap(displayed.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload)
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: value.rawJSON) as? [String: Any])
        XCTAssertEqual(Set(descriptor.keys), ["$computa_history"])
        let ref = try XCTUnwrap(descriptor["$computa_history"] as? String)
        XCTAssertEqual(ref.utf8.count, 22)
        let arguments = try encode(["ref": ref])
        let issued = try M.issueLookupCall(f.reader, binding: f.binding, contextNonce: f.nonce,
            nativeHTTPSourceSHA256: plan.snapshot.nativeHTTPSourceSHA256, callID: "read_codec_old_output",
            qualifiedName: GroqHistoryTool.name, arguments: arguments)
        let read = try M.prepareRead(plan.snapshot, issued: issued, maximumBytes: 64)
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: read.responseData) as? [String: Any])
        XCTAssertEqual(Set(identity.keys), ["context_revision", "ref", "source_call_id", "source_name", "source_kind",
            "field", "value_encoding", "whole_bytes", "whole_sha256", "start_byte", "end_byte", "utf8_fragment",
            "next_ref", "historical_only", "action_authority"])
        XCTAssertEqual(identity["context_revision"] as? String, plan.snapshot.contextRevision)
        XCTAssertEqual(identity["ref"] as? String, ref)
        XCTAssertEqual(identity["source_call_id"] as? String, "call_old")
        XCTAssertEqual(identity["source_name"] as? String, "exec_command")
        XCTAssertEqual(identity["source_kind"] as? String, "function")
        XCTAssertEqual(identity["field"] as? String, "output")
        XCTAssertEqual(identity["value_encoding"] as? String, "json")
        XCTAssertEqual(identity["whole_bytes"] as? Int, old.rawJSON.count)
        XCTAssertEqual(identity["whole_sha256"] as? String, sha(old.rawJSON))
        XCTAssertEqual(identity["historical_only"] as? Bool, true)
        XCTAssertEqual(identity["action_authority"] as? Bool, false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: displayJSON(request)) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let reader = try XCTUnwrap(tools.first { $0["name"] as? String == GroqHistoryTool.name })
        XCTAssertEqual(try encode(try XCTUnwrap(reader["parameters"])), try encode(GroqHistoryTool.argumentSchema))
        XCTAssertThrowsError(try C.parseReply(#"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"unloaded"}}]}"#,
            request: request, requireEnvelope: true)) { error in
            XCTAssertEqual(error as? C.Failure, .unknownTool("exec_command"))
        }
    }

    func testNativeHistoryLiteralBoundaryPreservesProjectionAndFullPromptBudget() throws {
        let f = try Fixture(), hook = try f.hook()
        let admitted = try C.prepareBudgetedGroqRequest(f.source, availability: nil,
            projection: f.catalog(), model: f.binding.scope.modelID, loadedOnly: true, historyProjection: hook)
        let request = admitted.request, plan = try XCTUnwrap(request.groqHistoryPlan)
        let inline = try f.request()
        let boundary = ComputaAgentInstructions.compactLiteralFencedResponseFormat
        let oldLine = #"One fenced json object; no outside prose. Message/refusal/clarification: {"type":"message","text":"answer"} ends the turn; requested exact/JSON/plain formats apply to decoded text. Use tool_calls for the next unverified step within authorized scope."#
        let messageLine = try XCTUnwrap(request.prompt.split(separator: "\n").first { $0.hasPrefix("Message/refusal/clarification: ") }).description
        XCTAssertTrue(request.prompt.hasSuffix(groqFinalClosingBoundary + "\nEND_COMPUTA_LOCAL_RESPONSE_HANDOFF."))
        // Replace only the compact format words with the older full format;
        // current names/limits/final-channel rules remain in both whole prompts.
        let legacyPrompt = request.prompt.replacingOccurrences(of: messageLine, with: oldLine)
            .replacingOccurrences(of: " " + boundary + "\nEND_COMPUTA_LOCAL_RESPONSE_HANDOFF.", with: "\nEND_COMPUTA_LOCAL_RESPONSE_HANDOFF.")
        XCTAssertGreaterThan(plan.replacedFields, 0)
        XCTAssertTrue(plan.isCurrent())
        XCTAssertTrue(request.prompt.contains("\nGROQ_CONTEXT_MANIFEST_V1:\n```\n"))
        XCTAssertEqual(request.prompt.components(separatedBy: boundary).count - 1, 1)
        XCTAssertEqual(request.continuationRequest, f.source)
        XCTAssertEqual(request.offeredToolNames, inline.offeredToolNames)
        XCTAssertEqual(request.customToolNames, inline.customToolNames)
        XCTAssertEqual(request.groqToolCatalogSeed?.registeredDefinitionsJSON, inline.groqToolCatalogSeed?.registeredDefinitionsJSON)
        XCTAssertEqual(request.groqToolCatalogSeed?.allowedNames, inline.groqToolCatalogSeed?.allowedNames)
        XCTAssertEqual(try C.completedResponse(for: .message("inert"), request: request, responseID: "resp_fixed", createdAt: 1),
            try C.completedResponse(for: .message("inert"), request: inline, responseID: "resp_fixed", createdAt: 1))
        let original = try J.parse(f.source), displayed = try J.parse(displayJSON(request))
        XCTAssertEqual(displayed.items.last?.payload?.rawJSON, original.items.last?.payload?.rawJSON)
        let sourceUser = try XCTUnwrap(original.items.first { $0.role == "user" })
        let displayUser = try XCTUnwrap(displayed.items.first { $0.role == "user" })
        XCTAssertEqual(try original.rawBytes(in: sourceUser.wholeRange), try displayed.rawBytes(in: displayUser.wholeRange))
        XCTAssertEqual(admitted.units, try GroqBodyTokenCounter.tokenCount(request.prompt))
        XCTAssertLessThanOrEqual(admitted.units, try GroqBodyTokenCounter.tokenCount(legacyPrompt))
        XCTAssertLessThanOrEqual(admitted.units, C.groqMaximumBodyTokens)
        XCTAssertEqual(request.promptStatistics.finalPromptBytes, request.prompt.utf8.count)
    }

    func testManifestContractAndLabelAreIncludedInFullProductionAdmission() throws {
        let f = try Fixture()
        let inline = try f.request()
        let admitted = try C.prepareBudgetedGroqRequest(f.source, availability: nil,
            projection: f.catalog(), model: f.binding.scope.modelID, loadedOnly: true, historyProjection: f.hook())
        let request = admitted.request
        XCTAssertTrue(request.prompt.contains("\nGROQ_CONTEXT_MANIFEST_V1:\n```\n"))
        XCTAssertTrue(request.prompt.contains("END_GROQ_CONTEXT_MANIFEST_V1."))
        XCTAssertTrue(request.currentUserInstructions.contains("GROQ_CONTEXT_MANIFEST_V1.input[1]"))
        XCTAssertFalse(request.currentUserInstructions.contains("COMPLETE_RESPONSES_REQUEST_JSON"))
        XCTAssertTrue(request.prompt.contains("NOT a complete Responses request"))
        XCTAssertTrue(request.prompt.contains("value_encoding=json"))
        XCTAssertTrue(request.prompt.contains("whole_bytes/whole_sha256"))
        XCTAssertTrue(request.prompt.contains("alone"), "The reader's single-pair budget preview requires reader-only replies")
        XCTAssertGreaterThan(request.promptStatistics.requestContextBytes, inline.promptStatistics.requestContextBytes)
        XCTAssertEqual(request.promptStatistics.finalPromptBytes, request.prompt.utf8.count)
        XCTAssertEqual(request.promptStatistics.originalRequestBytes, f.source.count)
        XCTAssertEqual(admitted.units, try GroqBodyTokenCounter.tokenCount(request.prompt))
        XCTAssertLessThanOrEqual(admitted.units, C.groqMaximumBodyTokens)
        XCTAssertNotNil(request.groqHistoryPlan)
    }

    func testNativeHistoryLoaderEnumFlagPreservesNativeConfigurationPolicyAndBackendValidation() throws {
        let f = try Fixture(), legacy = try f.request(), explicitLegacy = try f.request(compactHistoryInventory: false)
        let compact = try f.request(compactHistoryInventory: true)
        XCTAssertEqual(explicitLegacy.prompt, legacy.prompt)
        XCTAssertEqual(compact.continuationRequest, legacy.continuationRequest)
        XCTAssertEqual(compact.offeredToolNames, legacy.offeredToolNames)
        XCTAssertEqual(compact.customToolNames, legacy.customToolNames)
        XCTAssertEqual(compact.groqToolCatalogSeed?.registeredDefinitionsJSON, legacy.groqToolCatalogSeed?.registeredDefinitionsJSON)
        XCTAssertEqual(compact.groqToolCatalogSeed?.allowedNames, legacy.groqToolCatalogSeed?.allowedNames)
        let nativeA = try C.completedResponse(for: .message("inert"), request: legacy, responseID: "resp_fixed", createdAt: 1)
        let nativeB = try C.completedResponse(for: .message("inert"), request: compact, responseID: "resp_fixed", createdAt: 1)
        XCTAssertEqual(nativeA, nativeB, "Display mode cannot change native response configuration or schemas")
        let displayedA = try loaderDefinition(displayJSON(legacy)), displayedB = try loaderDefinition(displayJSON(compact))
        XCTAssertEqual(displayedA["description"] as? String, displayedB["description"] as? String)
        let schemaA = try XCTUnwrap(displayedA["parameters"] as? [String: Any])
        let schemaB = try XCTUnwrap(displayedB["parameters"] as? [String: Any])
        let propertiesA = try XCTUnwrap(schemaA["properties"] as? [String: Any])
        let propertiesB = try XCTUnwrap(schemaB["properties"] as? [String: Any])
        let namesA = try XCTUnwrap(propertiesA["names"] as? [String: Any])
        let namesB = try XCTUnwrap(propertiesB["names"] as? [String: Any])
        XCTAssertNotNil((namesA["items"] as? [String: Any])?["enum"])
        XCTAssertEqual(try encode(try XCTUnwrap(namesB["items"])), try encode(["type": "string"]))
        XCTAssertEqual(namesB["minItems"] as? Int, 1); XCTAssertEqual(namesB["maxItems"] as? Int, 4)
        XCTAssertEqual(namesB["uniqueItems"] as? Bool, true); XCTAssertEqual(schemaB["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schemaB["required"] as? [String], ["catalog_revision", "names"])
        let projection = try f.catalog()
        let scope = GroqToolCatalog.Scope(taskID: f.binding.scope.taskID, threadID: f.binding.scope.threadID,
            turnID: f.binding.scope.turnID, runtimeGeneration: f.binding.scope.runtimeGeneration,
            preparationID: f.binding.scope.preparationID, modelID: f.binding.scope.modelID)
        let seed = try XCTUnwrap(legacy.groqToolCatalogSeed)
        for names in [["unregistered"], [GroqToolCatalog.name], ["exec_command", "exec_command"], []] {
            let args = try encode(["catalog_revision": projection.revision, "names": names])
            let envelope = String(decoding: try encode(["type": "tool_calls", "calls": [["name": GroqToolCatalog.name,
                "arguments": try JSONSerialization.jsonObject(with: args)]]]), as: UTF8.self)
            // The display enum was never codec/native admission. Both modes
            // retain the same response parser, then the actual loader refuses.
            XCTAssertEqual(try C.parseReply(envelope, request: legacy, requireEnvelope: true),
                try C.parseReply(envelope, request: compact, requireEnvelope: true))
            for _ in [legacy, compact] {
                var catalog = GroqToolCatalog()
                let before = try catalog.prepare(scope: scope, seed: seed)
                XCTAssertThrowsError(try catalog.previewLoad(scope: scope, arguments: args, lastOfferedNames: legacy.offeredToolNames))
                XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), before)
            }
        }
        for request in [legacy, compact] {
            XCTAssertThrowsError(try C.parseReply(#"{"type":"tool_calls","calls":[{"name":"unoffered","arguments":{}}]}"#,
                request: request, requireEnvelope: true)) { XCTAssertEqual($0 as? C.Failure, .unknownTool("unoffered")) }
        }
    }

    func testNativeHistoryLoaderEnumFlagMatchesActualBudgetAndCountOnlyPreviewRendering() throws {
        let f = try Fixture(output: "small result")
        let budgeted = try C.prepareBudgetedGroqRequest(f.source, availability: nil,
            projection: f.catalog(), model: f.binding.scope.modelID, loadedOnly: true, compactHistoryInventory: true)
        XCTAssertEqual(budgeted.request.prompt, try f.request(compactHistoryInventory: true).prompt)
        let projector = try f.projector(f.source), native = try J.parse(f.source)
        let host = try append([
            ["type": "function_call", "call_id": "preview_loader", "name": GroqToolCatalog.name,
             "arguments": #"{"catalog_revision":"inert","names":["exec_command"]}"#],
            ["type": "function_call_output", "call_id": "preview_loader", "output": "literal count-only receipt"]
        ], to: f.source)
        let hostLayout = try J.parse(host), full = try toolsSHA(native)
        let history: C.GroqHistoryProjection = { candidate in
            .preview(try projector.projectPreview(candidateLayout: candidate, hostPreviewLayout: hostLayout,
                fullSchemaSHA256: full, selectedSchemaSHA256: toolsSHA(candidate)))
        }
        let preview = try f.request(data: host, history: history, compactHistoryInventory: true)
        XCTAssertTrue(preview.groqHistoryPreviewOnly); XCTAssertNil(preview.groqHistoryPlan)
        let shown = try loaderDefinition(displayJSON(preview))
        let schema = try XCTUnwrap(shown["parameters"] as? [String: Any])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        let names = try XCTUnwrap(props["names"] as? [String: Any])
        XCTAssertEqual(try encode(try XCTUnwrap(names["items"])), try encode(["type": "string"]))
        XCTAssertEqual(preview.continuationRequest, host)
    }

    func testZeroReferenceInlinePlanPreservesLegacyPromptAndSnapshot() throws {
        let f = try Fixture()
        let unchanged = try f.request()
        let inline = try f.request(history: f.hook(inline: true))
        XCTAssertEqual(inline.prompt, unchanged.prompt)
        XCTAssertEqual(inline.promptStatistics, unchanged.promptStatistics)
        XCTAssertEqual(inline.continuationRequest, unchanged.continuationRequest)
        XCTAssertTrue(inline.prompt.contains("\nCOMPLETE_RESPONSES_REQUEST_JSON:\n```\n"))
        XCTAssertFalse(inline.prompt.contains("NOT a complete Responses request"))
        let retained = try XCTUnwrap(inline.groqHistoryPlan)
        XCTAssertEqual(retained.replacedFields, 0)
        XCTAssertEqual(retained.savedJSONBytes, 0)
        XCTAssertEqual(retained.snapshot.contextRevision, try f.request(history: f.hook()).groqHistoryPlan?.snapshot.contextRevision)
        XCTAssertFalse(inline.groqHistoryPreviewOnly)
        let small = try Fixture(output: "small result")
        let unreferenced = try small.request(history: small.hook())
        XCTAssertEqual(unreferenced.groqHistoryPlan?.replacedFields, 0)
        XCTAssertEqual(unreferenced.prompt, try small.request().prompt)
    }

    func testNativeHistoryDiscoveryListsOnlyUnloadedRowsWithoutChangingCanonicalOrCallableSchemas() throws {
        let f = try Fixture(), native = f.binding.scope
        let original = try C.prepareRequest(f.source), seed = try XCTUnwrap(original.groqToolCatalogSeed)
        let scope = GroqToolCatalog.Scope(taskID: native.taskID, threadID: native.threadID, turnID: native.turnID,
            runtimeGeneration: native.runtimeGeneration, preparationID: native.preparationID, modelID: native.modelID)
        var catalog = GroqToolCatalog()
        func inventory(_ request: C.Request) throws -> [String: Any] {
            let runtime = request.runtimeInstructions
            let start = try XCTUnwrap(runtime.range(of: "GROQ_NATIVE_TOOL_INVENTORY:\n"))
            let fence = try XCTUnwrap(runtime.range(of: "```\n", range: start.upperBound..<runtime.endIndex))
            let end = try XCTUnwrap(runtime.range(of: "\n```", range: fence.upperBound..<runtime.endIndex))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(runtime[fence.upperBound..<end.lowerBound].utf8)) as? [String: Any])
        }
        for loadedExec in [false, true] {
            var projection = try catalog.prepare(scope: scope, seed: seed)
            if loadedExec {
                _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": projection.revision, "names": ["exec_command"]]))
                projection = try catalog.prepare(scope: scope, seed: seed)
            }
            let legacy = try C.prepareRequest(f.source, groqToolCatalogProjection: projection, groqDirectTools: .loadedOnly)
            let compact = try C.prepareRequest(f.source, groqToolCatalogProjection: projection, groqDirectTools: .loadedOnly,
                compactHistoryInventory: true)
            let old = try inventory(legacy), displayed = try inventory(compact)
            let oldRows = try XCTUnwrap(old["inventory"] as? [[String]])
            let rows = try XCTUnwrap(displayed["inventory"] as? [[String]])
            XCTAssertTrue(oldRows.allSatisfy { $0.count == 3 }, "Legacy discovery preserves purpose summaries")
            XCTAssertTrue(rows.allSatisfy { $0.count == 2 }, "Native-history rows keep exact names and kinds")
            let expectedRows = projection.discoverable.filter { !projection.selectedNames.contains($0.name) }
                .map { [$0.name, $0.isCustom ? "custom" : "function"] }
            XCTAssertEqual(rows, expectedRows)
            let unloaded = Set(rows.compactMap(\.first)), loaded = Set(try XCTUnwrap(displayed["loaded"] as? [String]))
            let all = Set(projection.discoverable.map(\.name))
            XCTAssertEqual(Set(oldRows.compactMap(\.first)), all)
            XCTAssertTrue(unloaded.isDisjoint(with: loaded))
            XCTAssertEqual(unloaded.union(loaded), all)
            XCTAssertEqual(loaded, projection.selectedNames)
            XCTAssertTrue(loaded.contains(GroqToolCatalog.name)); XCTAssertTrue(loaded.contains(GroqHistoryTool.name))
            XCTAssertEqual(unloaded.contains("exec_command"), !loadedExec)
            XCTAssertEqual(displayed["catalog_revision"] as? String, projection.revision)
            XCTAssertTrue(compact.runtimeInstructions.contains("Rows [name,kind] are unloaded discovery;"))
            XCTAssertTrue(legacy.runtimeInstructions.contains("Rows [name,purpose,kind] are discovery;"))
            XCTAssertFalse(legacy.runtimeInstructions.contains("are unloaded discovery;"))
            for request in [legacy, compact] {
                XCTAssertTrue(request.runtimeInstructions.contains("only loaded tools have callable schemas"))
                XCTAssertTrue(request.runtimeInstructions.contains("current catalog_revision and at most four names"))
                XCTAssertTrue(request.runtimeInstructions.contains("Loading REPLACES optional selections, executes nothing"))
                XCTAssertTrue(request.runtimeInstructions.contains("wait for the next request's schema before calling them"))
            }
            XCTAssertEqual(compact.continuationRequest, f.source)
            XCTAssertEqual(legacy.continuationRequest, f.source)
            XCTAssertEqual(compact.offeredToolNames, legacy.offeredToolNames)
            XCTAssertEqual(compact.groqToolCatalogSeed?.registeredDefinitionsJSON, seed.registeredDefinitionsJSON)
            XCTAssertEqual(try catalog.prepare(scope: scope, seed: seed), projection)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: displayJSON(compact)) as? [String: Any])
            let schemas = try XCTUnwrap(body["tools"] as? [[String: Any]])
            XCTAssertEqual(Set(schemas.compactMap { $0["name"] as? String }), loaded)
            if loadedExec {
                let actualExec = try XCTUnwrap(schemas.first { $0["name"] as? String == "exec_command" })
                let full = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
                let fullTools = try XCTUnwrap(full["tools"] as? [[String: Any]])
                let originalExec = try XCTUnwrap(fullTools.first { $0["name"] as? String == "exec_command" })
                XCTAssertEqual(try encode(actualExec), try encode(originalExec))
            } else {
                let unoffered = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"not loaded"}}]}"#
                XCTAssertThrowsError(try C.parseReply(unoffered, request: compact, requireEnvelope: true)) {
                    XCTAssertEqual($0 as? C.Failure, .unknownTool("exec_command"))
                }
                let handoff = try XCTUnwrap(compact.prompt.components(separatedBy: "COMPUTA_LOCAL_RESPONSE_HANDOFF:").last)
                let start = try XCTUnwrap(handoff.range(of: " Example only if needed: "))
                let end = try XCTUnwrap(handoff.range(of: " alone; await matching output and next-request schema.", range: start.upperBound..<handoff.endIndex))
                XCTAssertNoThrow(try C.parseReply(String(handoff[start.upperBound..<end.lowerBound]), request: compact, requireEnvelope: true))
            }
            // Response configuration is native data, not website discovery prose.
            XCTAssertEqual(try C.completedResponse(for: .message("Inert inventory."), request: compact, responseID: "resp_inventory", createdAt: 123),
                try C.completedResponse(for: .message("Inert inventory."), request: legacy, responseID: "resp_inventory", createdAt: 123))
        }
    }

    func testCountOnlyPreviewRetainsNoPlanAndKeepsNewTailLiteral() throws {
        let f = try Fixture(), projector = try f.projector(f.source)
        let native = try J.parse(f.source), full = try toolsSHA(native)
        let preview = try append([
            ["type": "function_call", "call_id": "call_preview", "name": GroqToolCatalog.name,
             "arguments": #"{"catalog_revision":"synthetic","names":["exec_command"]}"#],
            ["type": "function_call_output", "call_id": "call_preview", "output": "EXACT_NATIVE_PREVIEW_RESULT"]
        ], to: f.source)
        let host = try J.parse(preview)
        let hook: C.GroqHistoryProjection = { candidate in
            .preview(try projector.projectPreview(candidateLayout: candidate, hostPreviewLayout: host,
                fullSchemaSHA256: full, selectedSchemaSHA256: toolsSHA(candidate)))
        }
        let request = try f.request(data: preview, history: hook)
        XCTAssertNil(request.groqHistoryPlan)
        XCTAssertTrue(request.groqHistoryPreviewOnly)
        XCTAssertEqual(request.continuationRequest, preview)
        let actual = try J.parse(displayJSON(request))
        for (expected, displayed) in zip(host.items.dropFirst(native.items.count), actual.items.dropFirst(native.items.count)) {
            XCTAssertEqual(try host.rawBytes(in: expected.wholeRange), try actual.rawBytes(in: displayed.wholeRange))
        }
        XCTAssertEqual(actual.items.count, host.items.count)
        XCTAssertTrue(request.prompt.contains("GROQ_CONTEXT_MANIFEST_V1:\n```"))
    }

    func testProjectionRejectsWrongProviderModeAndUnavailableReaderWithoutWeakeningPolicy() throws {
        let f = try Fixture()
        let forbidden: C.GroqHistoryProjection = { _ in throw Probe.callbackInvoked }
        XCTAssertThrowsError(try C.prepareBudgetedGroqRequest(f.source, availability: nil,
            projection: f.catalog(), model: f.binding.scope.modelID, loadedOnly: false, historyProjection: forbidden)) {
            XCTAssertEqual($0 as? C.Failure, .invalidTools)
        }
        for (mode, compact) in [(C.GroqDirectToolSet.standard, false), (.loadedOnly, true)] {
            XCTAssertThrowsError(try C.prepareRequest(f.source, groqToolCatalogProjection: f.catalog(),
                groqDirectTools: mode, compactGroqLoaderHistory: compact, groqHistoryProjection: forbidden)) {
                XCTAssertEqual($0 as? C.Failure, .invalidTools)
            }
        }
        var foreign = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
        foreign["model"] = WebsiteModelChoice(provider: "qwen", key: "Qwen3.7-Plus", label: "Qwen3.7-Plus").modelID
        XCTAssertThrowsError(try C.prepareRequest(encode(foreign), groqToolCatalogProjection: f.catalog(), groqHistoryProjection: forbidden)) {
            XCTAssertEqual($0 as? C.Failure, .invalidTools)
        }
        for bad in [try Fixture(includeReader: false), try Fixture(readerDescription: "Foreign reader description"), try Fixture(toolChoice: "none")] {
            XCTAssertNil(try bad.request().groqHistoryReaderName)
            XCTAssertThrowsError(try bad.request(history: bad.hook())) { error in
                XCTAssertEqual(error as? C.Failure, .invalidToolChoice)
            }
            let projector = try bad.projector(bad.source), full = try toolsSHA(J.parse(bad.source))
            let preview: C.GroqHistoryProjection = { candidate in
                .preview(try projector.project(candidateLayout: candidate, fullSchemaSHA256: full,
                    selectedSchemaSHA256: toolsSHA(candidate)).renderedJSON)
            }
            XCTAssertThrowsError(try bad.request(history: preview)) { error in
                XCTAssertEqual(error as? C.Failure, .invalidToolChoice)
            }
        }
        let denied = try Fixture(output: "small", toolChoice: "none")
        let noCall = try denied.request(history: denied.hook())
        XCTAssertNil(noCall.groqHistoryReaderName)
        XCTAssertEqual(try C.parseReply(#"{"type":"message","text":"No tool requested."}"#,
            request: noCall, requireEnvelope: true), .message("No tool requested."))
    }

    func testModestByteSavingsCanStillExceedTokenBudgetWhileInlineFits() throws {
        // The shorter ref-only descriptor needs a smaller low-token literal to
        // retain this real byte-savings/whole-prompt-token counterexample.
        let f = try Fixture(output: String(repeating: "a", count: 256))
        var low = 0, high = C.groqMaximumBodyTokens
        // Only calibrate an inert CURRENT USER string with the unchanged exact
        // tokenizer. No token estimate or fitted production limit is substituted.
        let upper = try f.request(data: f.frame(userPadding: high))
        XCTAssertGreaterThan(try GroqBodyTokenCounter.tokenCount(upper.prompt), C.groqMaximumBodyTokens)
        while low < high {
            let mid = (low + high + 1) / 2
            let request = try f.request(data: f.frame(userPadding: mid))
            if try GroqBodyTokenCounter.tokenCount(request.prompt) <= C.groqMaximumBodyTokens { low = mid }
            else { high = mid - 1 }
        }
        let data = try f.frame(userPadding: low)
        let inline = try C.prepareBudgetedGroqRequest(data, availability: nil, projection: f.catalog(data),
            model: f.binding.scope.modelID, loadedOnly: true)
        let projected = try f.request(data: data, history: f.hook(data))
        let plan = try XCTUnwrap(projected.groqHistoryPlan)
        XCTAssertGreaterThan(plan.savedJSONBytes, 0)
        XCTAssertGreaterThan(projected.promptStatistics.requestContextBytes, inline.request.promptStatistics.requestContextBytes)
        let projectedUnits = try GroqBodyTokenCounter.tokenCount(projected.prompt)
        XCTAssertLessThanOrEqual(inline.units, C.groqMaximumBodyTokens)
        XCTAssertGreaterThan(projectedUnits, C.groqMaximumBodyTokens)
        XCTAssertThrowsError(try C.prepareBudgetedGroqRequest(data, availability: nil,
            projection: f.catalog(data), model: f.binding.scope.modelID, loadedOnly: true, historyProjection: f.hook(data))) {
            XCTAssertEqual($0 as? C.Failure, .groqPromptBudgetExceeded(actualTokens: projectedUnits,
                maximumTokens: 6_000, reservedTokens: 2_000))
        }
    }

    private enum Probe: Error { case callbackInvoked, fixtureNativeFact }

    func testRefOnlyReaderSchemaAndArgumentsKeepFullNativeResponseProof() throws {
        let f = try Fixture(), request = try f.request(history: f.hook())
        let plan = try XCTUnwrap(request.groqHistoryPlan)
        let schema = GroqHistoryTool.argumentSchema
        XCTAssertEqual(Set(try XCTUnwrap(schema["properties"] as? [String: Any]).keys), ["ref"])
        XCTAssertEqual(schema["required"] as? [String], ["ref"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let layout = try J.parse(displayJSON(request))
        let payload = try XCTUnwrap(layout.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload)
        let wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.rawJSON) as? [String: Any])
        XCTAssertEqual(Set(wrapper.keys), ["$computa_history"])
        let ref = try XCTUnwrap(wrapper["$computa_history"] as? String)
        let arguments = try encode(["ref": ref])
        let issued = try M.issueLookupCall(f.reader, binding: f.binding, contextNonce: f.nonce,
            nativeHTTPSourceSHA256: plan.snapshot.nativeHTTPSourceSHA256, callID: "read_ref_only_codec",
            qualifiedName: GroqHistoryTool.name, arguments: arguments)
        let read = try M.prepareRead(plan.snapshot, issued: issued, maximumBytes: 64)
        let full = try XCTUnwrap(JSONSerialization.jsonObject(with: read.responseData) as? [String: Any])
        XCTAssertEqual(Set(full.keys), ["context_revision", "ref", "source_call_id", "source_name", "source_kind",
            "field", "value_encoding", "whole_bytes", "whole_sha256", "start_byte", "end_byte", "utf8_fragment",
            "next_ref", "historical_only", "action_authority"])
        XCTAssertEqual(full["context_revision"] as? String, plan.snapshot.contextRevision)
        XCTAssertEqual(full["ref"] as? String, ref)
        XCTAssertEqual(full["source_call_id"] as? String, "call_old")
        XCTAssertEqual(full["historical_only"] as? Bool, true); XCTAssertEqual(full["action_authority"] as? Bool, false)
        let legacy = try encode(["context_revision": plan.snapshot.contextRevision, "ref": ref])
        XCTAssertThrowsError(try M.issueLookupCall(f.reader, binding: f.binding, contextNonce: f.nonce,
            nativeHTTPSourceSHA256: plan.snapshot.nativeHTTPSourceSHA256, callID: "read_old_protocol",
            qualifiedName: GroqHistoryTool.name, arguments: legacy)) { XCTAssertEqual($0 as? M.Failure, .arguments) }
    }

    func testCompactNativeCallIDsRequireExplicitNativeFlagAndExactAllowedReader() throws {
        let f = try Fixture(), reply = C.Reply.toolCalls([.init(name: "exec_command", argumentsJSON: #"{"cmd":"inert"}"#, namespace: nil)])
        let responseID = "resp_0123456789abcdef0123456789abcdef"
        let legacy = try nativeIDRequest(f, compact: false), profile = try nativeIDRequest(f, compact: true)
        XCTAssertEqual(try callIDs(reply, request: legacy, responseID: responseID), ["call_0123456789abcdef0123456789abcdef_0"])
        XCTAssertNotEqual(try callIDs(reply, request: profile, responseID: responseID), try callIDs(reply, request: legacy, responseID: responseID))
        for bad in [try Fixture(includeReader: false), try Fixture(readerDescription: "Foreign reader description")] {
            XCTAssertEqual(try callIDs(reply, request: nativeIDRequest(bad, compact: true), responseID: responseID),
                ["call_0123456789abcdef0123456789abcdef_0"])
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
        object["tool_choice"] = ["type": "function", "name": "exec_command"]
        let deniedReader = try nativeIDRequest(f, compact: true, source: encode(object))
        XCTAssertNil(deniedReader.groqHistoryReaderName)
        XCTAssertEqual(try callIDs(reply, request: deniedReader, responseID: responseID), ["call_0123456789abcdef0123456789abcdef_0"])
        object["tool_choice"] = "auto"; object["model"] = "browser/chatgpt"
        let otherProvider = try C.prepareRequest(encode(object), compactHistoryInventory: true)
        XCTAssertEqual(try callIDs(reply, request: otherProvider, responseID: responseID), ["call_0123456789abcdef0123456789abcdef_0"])
        object["model"] = f.binding.scope.modelID; object["compactHistoryInventory"] = true
        let modelHintOnly = try C.prepareRequest(encode(object))
        XCTAssertEqual(try callIDs(reply, request: modelHintOnly, responseID: responseID), ["call_0123456789abcdef0123456789abcdef_0"])
        XCTAssertEqual(try callIDs(reply, request: legacy, responseID: "unprefixed_response"), ["call_unprefixed_response_0"])
    }

    func testCompactNativeCallIDsAreDeterministicAndSharedByEveryEncoderAndStaging() throws {
        let f = try Fixture(), profile = try nativeIDRequest(f, compact: true), legacy = try nativeIDRequest(f, compact: false)
        let reply = mixedIDReply, responseID = "resp_0123456789abcdef0123456789abcdef"
        let staged = C.nativeOutputItems(for: reply, request: profile, responseID: responseID)
        let body = try C.completedResponse(for: reply, request: profile, responseID: responseID, createdAt: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let completed = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertEqual(try encode(completed), try encode(staged))
        let events = try nativeIDEvents(C.streamData(for: reply, request: profile, responseID: responseID, createdAt: 1))
        let done = try events.filter { $0["type"] as? String == "response.output_item.done" }.map {
            try XCTUnwrap($0["item"] as? [String: Any])
        }
        XCTAssertEqual(try encode(done), try encode(staged))
        let streamCompleted = try XCTUnwrap(events.last?["response"] as? [String: Any])
        XCTAssertEqual(try encode(try XCTUnwrap(streamCompleted["output"])), try encode(staged))
        for event in events where event["call_id"] != nil {
            let index = try XCTUnwrap(event["output_index"] as? Int)
            XCTAssertEqual(event["call_id"] as? String, staged[index]["call_id"] as? String)
        }
        let ids = staged.compactMap { $0["call_id"] as? String }
        XCTAssertEqual(ids.count, 2); XCTAssertEqual(Set(ids).count, 2)
        for (index, id) in ids.enumerated() {
            XCTAssertTrue(id.hasPrefix("call_")); XCTAssertEqual(id.utf8.count, 27)
            let token = String(id.dropFirst(5))
            let raw = try XCTUnwrap(Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="))
            XCTAssertEqual(raw.count, 16)
            let canonical = raw.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(token, canonical)
            var source = Data()
            for part in [Data(responseID.utf8), Data(String(index).utf8)] {
                source.append(Data("\(part.count):".utf8)); source.append(part)
            }
            XCTAssertEqual(raw, Data(SHA256.hash(data: source).prefix(16)))
        }
        XCTAssertEqual(try callIDs(reply, request: profile, responseID: responseID), ids)
        let other = try callIDs(reply, request: profile, responseID: responseID + "_different")
        XCTAssertTrue(Set(ids).isDisjoint(with: other))
        let old = C.nativeOutputItems(for: reply, request: legacy, responseID: responseID)
        XCTAssertEqual(old.compactMap { $0["call_id"] as? String }, ["call_0123456789abcdef0123456789abcdef_0", "call_0123456789abcdef0123456789abcdef_1"])
        var normalized = staged
        for index in normalized.indices {
            if old[index]["call_id"] != nil { normalized[index]["call_id"] = old[index]["call_id"] }
        }
        XCTAssertEqual(try encode(normalized), try encode(old), "Record IDs/message/content/args/type/name/namespace are unchanged")
        XCTAssertEqual(object["id"] as? String, responseID)
        var namespacedSource = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
        namespacedSource["tools"] = [["type": "namespace", "name": "functions", "tools": try XCTUnwrap(namespacedSource["tools"])]]
        let namespacedRequest = try nativeIDRequest(f, compact: true, source: encode(namespacedSource))
        let namespacedReply = C.Reply.toolCallsWithCommentary([
            .init(name: "exec_command", argumentsJSON: #"{"cmd":"read inert"}"#, namespace: "functions"),
            .init(name: "apply_patch", argumentsJSON: "", namespace: "functions", customInput: "inert literal patch"),
        ], "Inert progress.")
        let namespacedItems = C.nativeOutputItems(for: namespacedReply, request: namespacedRequest, responseID: responseID)
        XCTAssertEqual(try callIDs(namespacedReply, request: namespacedRequest, responseID: responseID), ids)
        XCTAssertTrue(namespacedItems.filter { $0["call_id"] != nil }.allSatisfy { $0["namespace"] as? String == "functions" })
    }

    func testCompactNativeIDsRequireExactContinuationAndTypedIssuedCompletionScope() throws {
        let f = try Fixture(), reply = mixedIDReply, responseID = "resp_0123456789abcdef0123456789abcdef"
        for stream in [false, true] {
            let request = try nativeIDRequest(f, compact: true, stream: stream)
            let encoded = try stream ? C.streamData(for: reply, request: request, responseID: responseID, createdAt: 1)
                : C.completedResponse(for: reply, request: request, responseID: responseID, createdAt: 1)
            let barrier = try WebsiteTurnContinuation(request: request, encodedResponse: encoded)
            XCTAssertEqual(barrier.pendingToolCallCount, 2)
            let items = C.nativeOutputItems(for: reply, request: request, responseID: responseID)
            let calls = items.filter { $0["call_id"] != nil }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.continuationRequest) as? [String: Any])
            let oldInput = try XCTUnwrap(object["input"] as? [[String: Any]])
            let results = try calls.reversed().map { call -> [String: Any] in
                let custom = call["type"] as? String == "custom_tool_call"
                return ["type": custom ? "custom_tool_call_output" : "function_call_output",
                    "call_id": try XCTUnwrap(call["call_id"] as? String), "output": custom ? "Native patch completed" : "Native command exit0"]
            }
            object["input"] = oldInput + items + results
            let nextData = try encode(object), next = try C.prepareRequest(nextData)
            try barrier.validate(next: next)
            var changed = object, changedResults = results
            changedResults[0]["call_id"] = "call_0123456789abcdef0123456789abcdef_1"
            changed["input"] = oldInput + items + changedResults
            XCTAssertThrowsError(try barrier.validate(next: C.prepareRequest(encode(changed))))
            let owner = L.makeOwner(), installed = try owner.ledger.installScope(owner.authority, binding: f.binding)
            let issued = try calls.map { call -> L.IssuedCall in
                let custom = call["type"] as? String == "custom_tool_call"
                return .init(callID: try XCTUnwrap(call["call_id"] as? String), kind: custom ? .applyPatch : .execCommand,
                    name: try XCTUnwrap(call["name"] as? String), namespace: call["namespace"] as? String,
                    argumentUTF8: Data(try XCTUnwrap(call[custom ? "input" : "arguments"] as? String).utf8))
            }
            let ticket = try owner.ledger.stageIssuedResponse(owner.authority, scope: installed.0, current: f.binding,
                responseID: responseID, encodedResponseSHA256: sha(encoded), calls: issued)
            for call in issued {
                XCTAssertTrue(installed.1.recordCompleted(current: f.binding.scope, itemID: call.callID,
                    terminal: call.kind == .applyPatch ? .patch(status: .completed) : .command(status: .completed, exitCode: 0)))
            }
            XCTAssertTrue(owner.ledger.commitHTTPWrite(owner.authority, ticket: ticket, current: f.binding))
            let frame = try GroqHistoryNativeFrame(layout: J.parse(nextData))
            let publications = owner.ledger.reconcileValidatedHistory(owner.authority, scope: installed.0,
                current: f.binding, history: frame.history)
            XCTAssertEqual(publications.count, 2)
            let fields = publications.compactMap { owner.ledger.literal(owner.authority, publication: $0, current: f.binding, field: .output) }
            XCTAssertEqual(Set(fields.map(\.callID)), Set(issued.map(\.callID)))
            let wrong = L.Binding(scope: f.binding.scope, transportGeneration: UUID())
            XCTAssertTrue(owner.ledger.reconcileValidatedHistory(owner.authority, scope: installed.0, current: wrong, history: frame.history).isEmpty)
        }
    }

    private var mixedIDReply: C.Reply {
        .toolCallsWithCommentary([
            .init(name: "exec_command", argumentsJSON: #"{"cmd":"read inert"}"#, namespace: nil),
            .init(name: "apply_patch", argumentsJSON: "", namespace: nil, customInput: "*** Begin Patch\n*** Add File: /inert/file\n+inert\n*** End Patch\n"),
        ], "Inert progress.")
    }
    private func callIDs(_ reply: C.Reply, request: C.Request, responseID: String) throws -> [String] {
        let body = try C.completedResponse(for: reply, request: request, responseID: responseID, createdAt: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(object["output"] as? [[String: Any]]).compactMap { $0["call_id"] as? String }
    }
    private func nativeIDRequest(_ f: Fixture, compact: Bool, stream: Bool = false, source: Data? = nil) throws -> C.Request {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source ?? f.source) as? [String: Any])
        object["stream"] = stream
        let data = try encode(object), original = try C.prepareRequest(data)
        guard let seed = original.groqToolCatalogSeed else { return try C.prepareRequest(data, compactHistoryInventory: compact) }
        let scope = GroqToolCatalog.Scope(taskID: f.binding.scope.taskID, threadID: f.binding.scope.threadID,
            turnID: f.binding.scope.turnID, runtimeGeneration: f.binding.scope.runtimeGeneration,
            preparationID: f.binding.scope.preparationID, modelID: original.model)
        var catalog = GroqToolCatalog()
        let initial = try catalog.prepare(scope: scope, seed: seed)
        let desired = ["exec_command", "apply_patch"].compactMap { local in
            seed.callableNames.intersection(seed.allowedNames).sorted().first { $0 == local || $0 == "functions." + local }
        }.filter { !initial.selectedNames.contains($0) }
        if !desired.isEmpty { _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": initial.revision, "names": desired])) }
        let loaded = try catalog.prepare(scope: scope, seed: seed)
        return try C.prepareRequest(data, groqToolCatalogProjection: loaded, groqDirectTools: .loadedOnly,
            compactHistoryInventory: compact)
    }

    private final class Fixture {
        let ledger: L, authority: L.ServerAuthority, handle: L.ScopeHandle, writer: L.CompletionWriter
        let binding: L.Binding, nonce: UUID, reader: M.ReaderAuthority
        let calls: [L.IssuedCall], source: Data
        private let output: String, includeReader: Bool, readerDescription: String?, toolChoice: String

        init(output: String = String(repeating: "Literal café é🙂 `\\n` ", count: 400), includeReader: Bool = true,
             readerDescription: String? = nil, toolChoice: String = "auto") throws {
            let owner = L.makeOwner(), nonce = UUID()
            let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
            let scope = L.Scope(taskID: "20000000-0000-4000-8000-000000000001",
                threadID: "20000000-0000-4000-8000-000000000002", turnID: "20000000-0000-4000-8000-000000000003",
                runtimeGeneration: UUID(), preparationID: UUID(), modelID: model, coreGeneration: UUID())
            let binding = L.Binding(scope: scope, transportGeneration: UUID())
            let installed = try owner.ledger.installScope(owner.authority, binding: binding)
            let calls = [L.IssuedCall(callID: "call_old", kind: .execCommand, name: "exec_command", namespace: nil,
                argumentUTF8: Data(#"{"cmd":"read inert source","inert_number":1.2300e+04}"#.utf8)),
                L.IssuedCall(callID: "call_latest", kind: .execCommand, name: "exec_command", namespace: nil,
                    argumentUTF8: Data(#"{"cmd":"latest inert read"}"#.utf8))]
            let ticket = try owner.ledger.stageIssuedResponse(owner.authority, scope: installed.0, current: binding,
                responseID: "resp_synthetic_boundary", encodedResponseSHA256: sha(Data("synthetic encoded response".utf8)), calls: calls)
            guard owner.ledger.commitHTTPWrite(owner.authority, ticket: ticket, current: binding),
                  calls.allSatisfy({ installed.1.recordCompleted(current: scope, itemID: $0.callID,
                    terminal: .command(status: .completed, exitCode: 0)) }) else { throw Probe.fixtureNativeFact }
            let declaration = try encode(GroqHistoryTool.specification)
            let reader = try M.makeReaderAuthority(binding: binding, contextNonce: nonce,
                registeredName: GroqHistoryTool.name, registrationSHA256: sha(declaration))
            self.ledger = owner.ledger; authority = owner.authority; handle = installed.0; writer = installed.1
            self.binding = binding; self.nonce = nonce; self.reader = reader; self.calls = calls
            self.output = output; self.includeReader = includeReader; self.readerDescription = readerDescription; self.toolChoice = toolChoice
            source = try Self.frame(model: model, calls: calls, output: output, includeReader: includeReader,
                readerDescription: readerDescription, toolChoice: toolChoice, userPadding: 0)
        }

        func frame(userPadding: Int) throws -> Data {
            try Self.frame(model: binding.scope.modelID, calls: calls, output: output, includeReader: includeReader,
                readerDescription: readerDescription, toolChoice: toolChoice, userPadding: userPadding)
        }
        private static func frame(model: String, calls: [L.IssuedCall], output: String,
            includeReader: Bool, readerDescription: String?, toolChoice: String, userPadding: Int) throws -> Data {
            var loader = GroqToolCatalog.specification
            loader["parameters"] = loader.removeValue(forKey: "inputSchema")
            var reader = GroqHistoryTool.specification
            reader["parameters"] = reader.removeValue(forKey: "inputSchema")
            if let readerDescription { reader["description"] = readerDescription }
            var tools: [[String: Any]] = [loader]
            if includeReader { tools.append(reader) }
            tools += [["type": "function", "name": "exec_command", "description": "Read inert synthetic source.",
                "parameters": ["type": "object", "properties": ["cmd": ["type": "string"], "inert_number": ["type": "number"]],
                    "required": ["cmd"], "additionalProperties": false]],
                ["type": "custom", "name": "apply_patch", "description": "Apply inert synthetic patch.", "format": ["type": "text"]]]
            var items: [[String: Any]] = [["role": "developer", "content": "Keep the complete current native policy."],
                ["role": "user", "content": "Exact user café / café 🙂 with literal \\u0061 and `text`." + String(repeating: " retained", count: userPadding)]]
            for (index, call) in calls.enumerated() {
                items.append(["type": "function_call", "call_id": call.callID, "name": call.name,
                    "arguments": String(decoding: call.argumentUTF8, as: UTF8.self)])
                items.append(["type": "function_call_output", "call_id": call.callID,
                    "output": index == 0 ? output : "LATEST_NATIVE_OBSERVATION_INLINE"])
            }
            return try encode(["model": model, "instructions": "Keep all native governing instructions.",
                "input": items, "tools": tools, "tool_choice": toolChoice, "stream": false])
        }
        func catalog(_ data: Data? = nil) throws -> GroqToolCatalog.Projection {
            let seed = try XCTUnwrap(C.prepareRequest(data ?? source).groqToolCatalogSeed)
            return try GroqToolCatalog.baseline(for: seed)
        }
        func request(data: Data? = nil, history: C.GroqHistoryProjection? = nil,
            compactHistoryInventory: Bool = false) throws -> C.Request {
            let raw = data ?? source
            return try C.prepareRequest(raw, groqToolCatalogProjection: catalog(raw), groqDirectTools: .loadedOnly,
                groqHistoryProjection: history, compactHistoryInventory: compactHistoryInventory)
        }
        func projector(_ data: Data) throws -> M {
            let layout = try J.parse(data)
            let pairs = try calls.map { call -> L.HistoryPair in
                let argument = try XCTUnwrap(layout.items.first { $0.callID == call.callID && $0.kind == .functionCall }?.payload)
                let output = try XCTUnwrap(layout.items.first { $0.callID == call.callID && $0.kind == .functionCallOutput }?.payload)
                return .init(callID: call.callID, kind: call.kind, name: call.name, namespace: call.namespace,
                    argumentUTF8: call.argumentUTF8, argumentValueRange: argument.valueRange, outputValueRange: output.valueRange)
            }
            let publications = ledger.reconcileValidatedHistory(authority, scope: handle, current: binding,
                history: .init(sourceUTF8: data, pairs: pairs))
            let fields = publications.flatMap { publication in [L.Field.arguments, .input, .output].compactMap {
                ledger.literal(authority, publication: publication, current: binding, field: $0)
            } }
            return try M(binding: binding, contextNonce: nonce, nativeLayout: layout, eligibleFields: fields,
                previous: nil, readerAuthority: reader)
        }
        func hook(_ data: Data? = nil, inline: Bool = false) throws -> C.GroqHistoryProjection {
            let raw = data ?? source, projector = try projector(raw), full = try toolsSHA(J.parse(raw))
            return { candidate in
                let plan = try projector.project(candidateLayout: candidate,
                    fullSchemaSHA256: full, selectedSchemaSHA256: toolsSHA(candidate))
                return .planned(inline ? M.Plan(renderedJSON: candidate.sourceUTF8, snapshot: plan.snapshot,
                    replacedFields: 0, savedJSONBytes: 0) : plan)
            }
        }
    }
}

private func loaderDefinition(_ source: Data) throws -> [String: Any] {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
    let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
    let flat = tools.flatMap { ($0["type"] as? String == "namespace" ? $0["tools"] as? [[String: Any]] : nil) ?? [$0] }
    return try XCTUnwrap(flat.first { $0["name"] as? String == GroqToolCatalog.name })
}

private func nativeIDEvents(_ stream: Data) throws -> [[String: Any]] {
    try String(decoding: stream, as: UTF8.self).split(separator: "\n").compactMap { line in
        guard line.hasPrefix("data: "), line != "data: [DONE]" else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
    }
}

private func encode(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
}
private func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
private func toolsSHA(_ layout: GroqContextJSONLayout) throws -> String {
    sha(try layout.rawBytes(in: XCTUnwrap(layout.toolsRange)))
}
private func displayJSON(_ request: WebModelResponseCodec.Request) throws -> Data {
    let label = request.prompt.contains("\nGROQ_CONTEXT_MANIFEST_V1:\n```\n")
        ? GroqContextManifestProjector.label : "COMPLETE_RESPONSES_REQUEST_JSON"
    let start = try XCTUnwrap(request.prompt.range(of: label + ":\n```\n"))
    let tail = request.prompt[start.upperBound...]
    let end = try XCTUnwrap(tail.range(of: "\n```\nEND_" + label + "."))
    return Data(tail[..<end.lowerBound].utf8)
}
private func append(_ items: [[String: Any]], to source: Data) throws -> Data {
    let layout = try GroqContextJSONLayout.parse(source), closing = layout.inputRange.upperBound - 1
    var result = source.subdata(in: 0..<closing)
    result.append(44)
    let encoded = try encode(items)
    result.append(encoded.dropFirst().dropLast())
    result.append(source.subdata(in: closing..<source.count))
    return result
}

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
            let start = try XCTUnwrap(handoff.range(of: "first return "))
            let end = try XCTUnwrap(handoff.range(of: ". Then read", range: start.upperBound..<handoff.endIndex))
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
            XCTAssertFalse(direct.contains("Example only:"))
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
                let start = try XCTUnwrap(handoff.range(of: "first return "))
                let end = try XCTUnwrap(handoff.range(of: ". Then read", range: start.upperBound..<handoff.endIndex))
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

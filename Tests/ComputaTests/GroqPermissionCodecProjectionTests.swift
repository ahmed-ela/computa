import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Pure codec routing and lexical-preservation controls. These do not execute
/// commands, grant permissions, count tokens, or qualify a provider workflow.
final class GroqPermissionCodecProjectionTests: XCTestCase {
    private typealias C = WebModelResponseCodec
    private typealias P = GroqNativePermissionPresentation
    private typealias J = GroqContextJSONLayout
    private enum Location: CaseIterable { case instructions, systemString, developerParts }
    private let sandbox = "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`. Editing files in other directories requires approval. Network access is restricted."

    func testExactPermissionUnitUsesAllTrustedCodecLocationsWithoutChangingNativeRequest() throws {
        XCTAssertEqual(Data(P.fullSource.utf8).count, 3661)
        XCTAssertEqual(hash(Data(P.fullSource.utf8)), "85541a9738741407642b3c39bbe3781fbf8bb42f628d50e562c87738ab192b3a")
        XCTAssertEqual(hash(Data(P.compactSource.utf8)), "f306874f724edaa783a30df0593f228b6031e78a91c73502e51b6802482cbce2")
        for location in Location.allCases {
            let governing = "Foreign governing prefix café\n" + envelope(suffix: "Unknown native suffix stays exact.\n")
            let data = try encode(frame(location: location, governing: governing))
            for mode in [C.GroqDirectToolSet.loadedOnly, .standard] {
                let compact = try request(data, nativeFlag: true, mode: mode)
                let legacy = try request(data, nativeFlag: false, mode: mode)
                let presented = try object(display(compact))
                XCTAssertEqual(try governingText(presented, location), governing.replacingOccurrences(of: P.fullSource, with: P.compactSource))
                XCTAssertEqual(try governingText(object(display(legacy)), location), governing)
                XCTAssertTrue(compact.usesNativeGroqHistoryPresentation)
                XCTAssertFalse(legacy.usesNativeGroqHistoryPresentation)
                XCTAssertEqual(compact.continuationRequest, data)
                XCTAssertEqual(legacy.continuationRequest, data)
                XCTAssertEqual(compact.offeredToolNames, legacy.offeredToolNames)
                XCTAssertEqual(compact.customToolNames, legacy.customToolNames)
                XCTAssertEqual(compact.groqToolCatalogSeed?.registeredDefinitionsJSON, legacy.groqToolCatalogSeed?.registeredDefinitionsJSON)
                XCTAssertEqual(try C.completedResponse(for: .message("Inert final"), request: compact, responseID: "resp_permission", createdAt: 1),
                    try C.completedResponse(for: .message("Inert final"), request: legacy, responseID: "resp_permission", createdAt: 1))
                XCTAssertEqual(compact.promptStatistics.finalPromptBytes, compact.prompt.utf8.count)
            }
        }
    }

    func testNativeFlagProviderAndExactAllowedReaderAreAllRequired() throws {
        let policy = envelope()
        let normal = try encode(frame(governing: policy))
        let defaultRequest = try request(normal, nativeFlag: nil)
        let disabled = try request(normal, nativeFlag: false)
        XCTAssertEqual(defaultRequest.prompt, disabled.prompt, "Omitting the native option must preserve its legacy default")
        XCTAssertFalse(defaultRequest.usesNativeGroqHistoryPresentation)
        var variants: [[String: Any]] = []
        var absent = frame(governing: policy)
        absent["tools"] = try XCTUnwrap(absent["tools"] as? [[String: Any]]).filter { $0["name"] as? String != GroqHistoryTool.name }
        variants.append(absent)
        var foreign = frame(governing: policy)
        var foreignTools = try XCTUnwrap(foreign["tools"] as? [[String: Any]])
        let readerIndex = try XCTUnwrap(foreignTools.firstIndex { $0["name"] as? String == GroqHistoryTool.name })
        foreignTools[readerIndex]["description"] = "Foreign reader description"; foreign["tools"] = foreignTools
        variants.append(foreign)
        var denied = frame(governing: policy)
        denied["tool_choice"] = ["type": "function", "name": "fixture_read"]
        variants.append(denied)
        var otherProvider = frame(governing: policy)
        otherProvider["model"] = WebsiteModelChoice(provider: "qwen", key: "Qwen3.7-Plus", label: "Qwen3.7-Plus").modelID
        variants.append(otherProvider)
        for value in variants {
            let raw = try encode(value), prepared = try request(raw, nativeFlag: true)
            XCTAssertFalse(prepared.usesNativeGroqHistoryPresentation)
            XCTAssertEqual(try governingText(object(display(prepared)), .instructions), policy)
            XCTAssertEqual(prepared.continuationRequest, raw)
        }
        var bodyHint = frame(governing: policy)
        bodyHint["compactHistoryInventory"] = true
        let hinted = try request(encode(bodyHint), nativeFlag: nil)
        XCTAssertFalse(hinted.usesNativeGroqHistoryPresentation)
        XCTAssertEqual(try governingText(object(display(hinted)), .instructions), policy)
    }

    func testUserToolAndForeignOrAmbiguousGoverningCopiesCannotBorrowRewriting() throws {
        let exact = envelope()
        for trusted in [false, true] {
            var value = frame(governing: trusted ? exact : "Foreign native governing text", toolDescription: exact)
            value["input"] = [
                ["type": "function_call", "call_id": "inert_completed", "name": "fixture_read", "arguments": "{}"],
                ["type": "function_call_output", "call_id": "inert_completed", "output": exact],
                ["role": "user", "content": exact]
            ]
            let raw = try encode(value), prepared = try request(raw, nativeFlag: true)
            let shown = try object(display(prepared)), messages = try XCTUnwrap(shown["input"] as? [[String: Any]])
            XCTAssertEqual(messages.last?["content"] as? String, exact)
            XCTAssertEqual(messages.first { $0["type"] as? String == "function_call_output" }?["output"] as? String, exact)
            let tools = try XCTUnwrap(shown["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.first { $0["name"] as? String == "fixture_read" }?["description"] as? String, exact)
            XCTAssertEqual(shown["instructions"] as? String, trusted ? exact.replacingOccurrences(of: P.fullSource, with: P.compactSource) : "Foreign native governing text")
            XCTAssertEqual(prepared.continuationRequest, raw)
        }
        let changed = P.fullSource.replacingOccurrences(of: "Commands are run", with: "Commands can run")
        let invalid = [envelope(unit: changed), envelope(unit: String(P.fullSource.dropLast())), exact + exact,
            "<permissions instructions>" + exact, exact + "</permissions instructions>"]
        for policy in invalid {
            let prepared = try request(encode(frame(governing: policy)), nativeFlag: true)
            XCTAssertEqual(try governingText(object(display(prepared)), .instructions), policy)
        }
        var duplicated = frame(governing: exact)
        duplicated["input"] = [["role": "system", "content": exact], ["role": "user", "content": "Inert task"]]
        let duplicateRequest = try request(encode(duplicated), nativeFlag: true)
        let duplicateDisplay = try object(display(duplicateRequest))
        XCTAssertEqual(duplicateDisplay["instructions"] as? String, exact)
        XCTAssertEqual(try governingText(duplicateDisplay, .systemString), exact)
    }

    func testUnknownJSONLexemesAroundTheExactUnitStayByteExact() throws {
        let governing = "Foreign_prefix café / cafe\u{301} 🙂\n" + envelope(suffix: "Unknown native suffix.\n") + "Foreign_suffix"
        var value = frame(governing: governing)
        value["foreign_number"] = 12300
        let encoded = String(decoding: try encode(value), as: UTF8.self)
        let lexical = encoded.replacingOccurrences(of: "Foreign_prefix", with: #"Foreign\u005fprefix"#)
            .replacingOccurrences(of: "Foreign_suffix", with: #"Foreign\u005fsuffix"#)
            .replacingOccurrences(of: #""foreign_number":12300"#, with: #""foreign_number":1.2300e+04"#)
        let raw = Data(lexical.utf8), compact = try request(raw, nativeFlag: true), legacy = try request(raw, nativeFlag: false)
        let before = try J.parse(display(legacy)), after = try J.parse(display(compact))
        let oldToken = try before.rawBytes(in: XCTUnwrap(before.instructionsRange))
        let newToken = try after.rawBytes(in: XCTUnwrap(after.instructionsRange))
        let fullBody = try encode(P.fullSource).dropFirst().dropLast(), compactBody = try encode(P.compactSource).dropFirst().dropLast()
        let range = try XCTUnwrap(oldToken.range(of: Data(fullBody)))
        XCTAssertNil(oldToken.range(of: Data(fullBody), in: range.upperBound..<oldToken.count))
        var expected = oldToken; expected.replaceSubrange(range, with: compactBody)
        XCTAssertEqual(newToken, expected, "Only the exact pinned unit may change, without reencoding its containing JSON string")
        XCTAssertTrue(String(decoding: newToken, as: UTF8.self).contains(#"Foreign\u005fprefix"#))
        XCTAssertTrue(String(decoding: newToken, as: UTF8.self).contains(#"Foreign\u005fsuffix"#))
        let oldNumber = try XCTUnwrap(before.rootOtherMembers.first { $0.key == "foreign_number" })
        let newNumber = try XCTUnwrap(after.rootOtherMembers.first { $0.key == "foreign_number" })
        XCTAssertEqual(try before.rawBytes(in: oldNumber.valueRange), Data("1.2300e+04".utf8))
        XCTAssertEqual(try after.rawBytes(in: newNumber.valueRange), try before.rawBytes(in: oldNumber.valueRange))
        let oldUser = try XCTUnwrap(before.items.first { $0.role == "user" })
        let newUser = try XCTUnwrap(after.items.first { $0.role == "user" })
        XCTAssertEqual(try before.rawBytes(in: oldUser.wholeRange), try after.rawBytes(in: newUser.wholeRange))
        XCTAssertEqual(compact.continuationRequest, raw)
    }

    private func envelope(unit: String = P.fullSource, suffix: String = "") -> String {
        "<permissions instructions>\n" + sandbox + "\n" + unit + suffix + "</permissions instructions>"
    }
    private func frame(location: Location = .instructions, governing: String, toolDescription: String = "Read inert fixture data.") -> [String: Any] {
        var loader = GroqToolCatalog.specification, reader = GroqHistoryTool.specification
        loader["parameters"] = loader.removeValue(forKey: "inputSchema")
        reader["parameters"] = reader.removeValue(forKey: "inputSchema")
        let fixture: [String: Any] = ["type": "function", "name": "fixture_read", "description": toolDescription,
            "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
        var messages: [[String: Any]] = []
        var result: [String: Any] = ["model": WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID,
            "instructions": "Foreign native governing text", "tools": [loader, reader, fixture], "tool_choice": "auto", "stream": false]
        switch location {
        case .instructions: result["instructions"] = governing
        case .systemString: messages.append(["role": "system", "content": governing])
        case .developerParts: messages.append(["type": "message", "role": "developer", "content": [
            ["type": "input_text", "text": "Other trusted text"], ["type": "text", "text": governing]]])
        }
        messages.append(["role": "user", "content": "Exact inert user café / cafe\u{301} 🙂"])
        result["input"] = messages
        return result
    }
    private func request(_ data: Data, nativeFlag: Bool?, mode: C.GroqDirectToolSet = .loadedOnly) throws -> C.Request {
        let original = try C.prepareRequest(data)
        guard let seed = original.groqToolCatalogSeed else {
            if let nativeFlag { return try C.prepareRequest(data, compactHistoryInventory: nativeFlag) }
            return try C.prepareRequest(data)
        }
        let scope = GroqToolCatalog.Scope(taskID: "30000000-0000-4000-8000-000000000001",
            threadID: "30000000-0000-4000-8000-000000000002", turnID: "30000000-0000-4000-8000-000000000003",
            runtimeGeneration: UUID(), preparationID: UUID(), modelID: original.model)
        var catalog = GroqToolCatalog(), projection = try catalog.prepare(scope: scope, seed: seed)
        if !projection.selectedNames.contains("fixture_read"), seed.allowedNames.contains("fixture_read"),
           projection.selectedNames.contains(GroqToolCatalog.name) {
            _ = try catalog.load(scope: scope, arguments: encode(["catalog_revision": projection.revision, "names": ["fixture_read"]]),
                lastOfferedNames: projection.selectedNames)
            projection = try catalog.prepare(scope: scope, seed: seed)
        }
        if let nativeFlag {
            return try C.prepareRequest(data, groqToolCatalogProjection: projection, groqDirectTools: mode, compactHistoryInventory: nativeFlag)
        }
        return try C.prepareRequest(data, groqToolCatalogProjection: projection, groqDirectTools: mode)
    }
    private func governingText(_ value: [String: Any], _ location: Location) throws -> String {
        switch location {
        case .instructions: return try XCTUnwrap(value["instructions"] as? String)
        case .systemString:
            let input = try XCTUnwrap(value["input"] as? [[String: Any]])
            return try XCTUnwrap(input.first { $0["role"] as? String == "system" }?["content"] as? String)
        case .developerParts:
            let input = try XCTUnwrap(value["input"] as? [[String: Any]])
            let parts = try XCTUnwrap(input.first { $0["role"] as? String == "developer" }?["content"] as? [[String: Any]])
            return try XCTUnwrap(parts.last?["text"] as? String)
        }
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func display(_ request: C.Request) throws -> Data {
        for label in ["COMPLETE_RESPONSES_REQUEST_JSON", "GROQ_CONTEXT_MANIFEST_V1"] {
            for delimiter in ["```\n", ""] {
                guard let start = request.prompt.range(of: "\n" + label + ":\n" + delimiter) else { continue }
                let tail = request.prompt[start.upperBound...]
                let endMarker = delimiter.isEmpty ? "\nEND_" + label + "." : "\n```\nEND_" + label + "."
                let end = try XCTUnwrap(tail.range(of: endMarker))
                return Data(tail[..<end.lowerBound].utf8)
            }
        }
        XCTFail("The codec did not publish a known request frame")
        throw C.Failure.invalidRequest
    }
}

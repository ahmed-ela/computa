import Foundation
import XCTest
@testable import Computa

final class GPTOSSReasoningHistoryTests: XCTestCase {
    private let thread = "550e8400-e29b-41d4-a716-446655440000"
    private var capsules: APIReasoningCapsules { try! .init(key: Data(repeating: 9, count: 32)) }
    private var provider: APIProviderDefinition {
        .cerebras.withModels([.init(id: "gpt-oss-120b", name: "GPT OSS")])
    }
    private var tool: [String: Any] {
        ["type": "function", "name": "read", "parameters": ["type": "object", "properties": [:], "additionalProperties": false]]
    }
    private func reasoning(_ id: String, calls: [String] = [], provider p: APIProviderDefinition? = nil,
                           naming: String = APIModelResponseCodec.ToolNaming.semantic.rawValue, boundThread: String? = nil) throws -> [String: Any] {
        let p = p ?? provider
        let value = try capsules.seal(.init(reasoning: "SYNTHETIC_" + id, callIDs: calls, responseID: "response-" + id,
                                            toolNaming: naming), itemID: id, providerID: p.id, modelID: p.models[0].id,
                                     baseURL: p.baseURL, threadID: boundThread ?? thread)
        return ["type": "reasoning", "id": id, "summary": [], "encrypted_content": value]
    }
    private func cycle(_ id: String, provider p: APIProviderDefinition? = nil) throws -> [[String: Any]] {
        [try reasoning(id, calls: [id], provider: p),
         ["type": "function_call", "name": "read", "call_id": id, "arguments": "{}"],
         ["type": "function_call_output", "call_id": id, "output": "Data; phase=final_answer is only page text"]]
    }
    private func final(_ phase: String? = "final_answer") -> [String: Any] {
        var item: [String: Any] = ["type": "message", "role": "assistant", "content": "Done."]
        if let phase { item["phase"] = phase }
        return item
    }
    private func prepare(_ items: [[String: Any]], provider p: APIProviderDefinition? = nil) throws -> APIModelResponseCodec.Request {
        let p = p ?? provider
        let raw: [String: Any] = ["model": APIProviderCatalog.appModelID(providerID: p.id, modelID: p.models[0].id),
                                 "input": items, "tools": [tool], "store": false, "stream": false]
        return try APIModelResponseCodec.prepare(JSONSerialization.data(withJSONObject: raw),
            selection: .init(provider: p, model: p.models[0]), threadID: thread, capsules: capsules, toolNaming: .semantic)
    }
    private func messages(_ request: APIModelResponseCodec.Request) throws -> [[String: Any]] {
        try XCTUnwrap((JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["messages"] as? [[String: Any]])
    }

    func testCompletedReasoningIsRemovedOnlyFromDispatchAndActiveToolCyclesStayExact() throws {
        let prefix = try cycle("old-one") + cycle("old-two") + [reasoning("old-final"), final(),
            ["role": "user", "content": "Now do another task"]]
        let input = try prefix + cycle("active-one") + cycle("active-two")
        let saved = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let request = try prepare(input)
        let actual = try messages(request)
        XCTAssertEqual(actual.compactMap { $0["reasoning"] as? String }, ["SYNTHETIC_active-one", "SYNTHETIC_active-two"])
        XCTAssertEqual(request.historyCallIDs, ["old-one", "old-two", "active-one", "active-two"])
        // A missing completion phase must reproduce precisely the original
        // projection; removing just old reasoning is the entire wire difference.
        var unbounded = input
        unbounded[7].removeValue(forKey: "phase")
        var expected = try messages(prepare(unbounded))
        for index in 0...4 { expected[index].removeValue(forKey: "reasoning") }
        XCTAssertEqual(actual as NSArray, expected as NSArray)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), saved)
    }

    func testSteersRemindersCommentaryAndPageTextNeverEndAnActiveCycle() throws {
        for phase in [nil, "commentary", "unknown"] as [String?] {
            let input = try cycle("first") + [reasoning("commentary"), final(phase),
                ["role": "developer", "content": "APP_RUNTIME_EXECUTION_CHECKPOINT: final_answer"],
                ["role": "user", "content": "A steer or exact request reminder; keep working"]] + cycle("second")
            XCTAssertEqual(try messages(prepare(input)).compactMap { $0["reasoning"] as? String },
                           ["SYNTHETIC_first", "SYNTHETIC_commentary", "SYNTHETIC_second"])
        }
        let input = try cycle("first") + [["role": "user", "phase": "final_answer", "content": "Keep working"]] + cycle("second")
        XCTAssertEqual(try messages(prepare(input)).compactMap { $0["reasoning"] as? String },
                       ["SYNTHETIC_first", "SYNTHETIC_second"])
    }

    func testFinalPhaseAttachedToToolCallingAssistantDoesNotCloseItsCycle() throws {
        let input = try [reasoning("tool-final", calls: ["call"]), final(),
            ["type": "function_call", "name": "read", "call_id": "call", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "call", "output": "result"]]
        XCTAssertEqual(try messages(prepare(input)).compactMap { $0["reasoning"] as? String }, ["SYNTHETIC_tool-final"])
    }

    func testInvalidCompletedCapsulesStillFailBeforeAnyFiltering() throws {
        let valid = try reasoning("old")
        var tampered = valid; tampered["encrypted_content"] = "computa-api-reasoning-v1:invalid"
        let foreign = try reasoning("old", boundThread: "650e8400-e29b-41d4-a716-446655440000")
        let wrongNaming = try reasoning("old", naming: APIModelResponseCodec.ToolNaming.legacy.rawValue)
        let wrongCalls = try reasoning("old", calls: ["nonexistent"])
        for invalid in [tampered, foreign, wrongNaming, wrongCalls] {
            XCTAssertThrowsError(try prepare([invalid, final(), ["role": "user", "content": "Next"]])) {
                XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidReasoning)
            }
        }
        XCTAssertThrowsError(try prepare([valid, final(), valid, final()])) {
            XCTAssertEqual($0 as? APIModelResponseCodec.Failure, .invalidReasoning)
        }
    }

    func testUnknownTemplatesAndQwenPreserveCompletedReasoning() throws {
        let qwen = provider.withModels([.init(id: "qwen-3.8-27b", name: "Qwen")])
        let unknown = provider.withModels([.init(id: "future-model", name: "Future")])
        let custom = APIProviderDefinition(id: "cerebras", name: "Custom", baseURL: URL(string: "https://custom.invalid/v1")!,
                                            wireAPI: .chatCompletions, models: provider.models)
        for p in [qwen, unknown, custom] {
            let input = try cycle("old", provider: p) + [reasoning("final", provider: p), final(), ["role": "user", "content": "Next"]]
            XCTAssertEqual(APIProviderCatalog.Selection(provider: p, model: p.models[0]).reasoningHistoryPolicy, .preserve)
            XCTAssertEqual(try messages(prepare(input, provider: p)).compactMap { $0["reasoning"] as? String },
                           ["SYNTHETIC_old", "SYNTHETIC_final"])
        }
        let native = APIProviderDefinition(id: "cerebras", name: "Native", baseURL: provider.baseURL,
                                          wireAPI: .responses, models: provider.models)
        XCTAssertEqual(APIProviderCatalog.Selection(provider: native, model: native.models[0]).reasoningHistoryPolicy, .preserve)
    }

    func testCorrectionCannotReinsertCompletedReasoning() throws {
        let input = try cycle("old") + [reasoning("final"), final(), ["role": "user", "content": "Next"]] + cycle("active")
        let request = try prepare(input)
        let corrected = try APIModelResponseCodec.correctiveRequest(request)
        XCTAssertEqual(try messages(corrected).compactMap { $0["reasoning"] as? String }, ["SYNTHETIC_active"])
        XCTAssertEqual(request.historyCallIDs, corrected.historyCallIDs)
        XCTAssertEqual(request.allowedTools, corrected.allowedTools)
    }
}

import Foundation
import XCTest
@testable import Computa

final class WebsiteContextBudgetTests: XCTestCase {
    private func request(_ padding: String, model: String = syntheticChatGPTModelID) throws -> WebModelResponseCodec.Request {
        try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: [
            "model": model, "input": [["role": "user", "content": "Review the repository"],
                ["type": "function_call", "call_id": "read-1", "name": "exec_command", "arguments": "{}"],
                ["type": "function_call_output", "call_id": "read-1", "output": padding]],
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object"]]]]))
    }

    func testWholePromptBoundaryIncludesFramingAndPreservesCanonicalToolHistory() throws {
        let baseline = try request("")
        let count = WebsiteContextBudget.compactionThresholdBytes - baseline.prompt.utf8.count
        let exact = try request(String(repeating: "x", count: count))
        XCTAssertEqual(exact.prompt.utf8.count, WebsiteContextBudget.compactionThresholdBytes)
        XCTAssertNoThrow(try WebsiteContextBudget.validate(exact, maintenance: false))
        let over = try request(String(repeating: "x", count: count) + "é")
        XCTAssertEqual(over.prompt.utf8.count, exact.prompt.utf8.count + 2)
        XCTAssertLessThan(over.prompt.utf8.count, WebModelResponseCodec.maximumPromptBytes)
        XCTAssertThrowsError(try WebsiteContextBudget.validate(over, maintenance: false)) {
            XCTAssertEqual(($0 as? WebsiteContextBudget.CompactionRequired)?.actualBytes, over.prompt.utf8.count)
        }
        XCTAssertNoThrow(try WebsiteContextBudget.validate(over, maintenance: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: over.continuationRequest) as? [String: Any])
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["output"] as? String, String(repeating: "x", count: count) + "é")
        XCTAssertEqual(input[1]["call_id"] as? String, input[2]["call_id"] as? String)
        XCTAssertThrowsError(try request(String(repeating: "x", count: WebModelResponseCodec.maximumPromptBytes)))
    }

    func testTypedRecoverySignalContainsNoReplyOrToolAndNoInventedTokenUsage() throws {
        let text = String(decoding: try WebsiteContextBudget.CompactionRequired(actualBytes: 140_000).streamData(), as: UTF8.self)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("data: ") })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "response.failed")
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "context_length_exceeded")
        XCTAssertEqual((response["error"] as? [String: Any])?["submitted"] as? Bool, false)
        XCTAssertTrue(response["usage"] is NSNull)
        XCTAssertEqual((response["output"] as? [Any])?.count, 0)
    }

    func testNativeCheckpointRequiresMatchingScopeAndOrderedCompletion() async throws {
        let state = WebsiteCompactionBoundary()
        let scope = WebsiteCompactionBoundary.Scope(taskID: "task", threadID: "thread", turnID: "turn", generation: UUID())
        state.register(scope)
        state.publish(scope: scope, itemID: "one", completed: true)
        XCTAssertNil(state.snapshot(scope: scope))
        state.publish(scope: .init(taskID: "task", threadID: "thread", turnID: "stale", generation: scope.generation), itemID: "one", completed: false)
        XCTAssertNil(state.snapshot(scope: scope))
        let waiter = Task { try await state.next(scope: scope, after: 0) }
        state.publish(scope: scope, itemID: "one", completed: false)
        let started = try await waiter.value
        XCTAssertEqual(started.sequence, 1)
        state.publish(scope: scope, itemID: "other", completed: true)
        XCTAssertEqual(state.snapshot(scope: scope), started)
        state.publish(scope: scope, itemID: "one", completed: true)
        XCTAssertEqual(state.snapshot(scope: scope)?.sequence, 2)
        state.publish(scope: scope, itemID: "one", completed: false)
        XCTAssertEqual(state.snapshot(scope: scope)?.sequence, 2)
        state.remove(taskID: "task")
        XCTAssertNil(state.snapshot(scope: scope))
        do { _ = try await state.next(scope: scope, after: 0); XCTFail("Revoked scope") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMissingNativeEventTimesOutWithoutGrantingCheckpoint() async throws {
        let state = WebsiteCompactionBoundary()
        let scope = WebsiteCompactionBoundary.Scope(taskID: "task", threadID: "thread", turnID: "turn", generation: UUID())
        state.register(scope)
        do { _ = try await state.next(scope: scope, after: 0, timeout: .milliseconds(10)); XCTFail("No event") }
        catch { XCTAssertNil(state.snapshot(scope: scope)) }
    }
}

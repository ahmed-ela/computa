import Foundation
import XCTest

@testable import Computa

final class CodexImportStoreTests: XCTestCase {
    func testLongHistoryRetainsFullTranscriptAndSendsRecentContext() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try CodexImportStore(directory: url)
        let old = String(repeating: "previously ", count: 60_000)
        let items = [old, "recent fact"].enumerated().map { n, text in
            ["turnId": "turn", "item": ["type": "agentMessage", "id": String(n), "text": text]] as [String: Any]
        }
        let snapshot = CodexImportStore.Snapshot(
            title: "Long", model: "gpt",
            pages: [
                try JSONSerialization.data(withJSONObject: ["data": items])
            ])
        let local = try db.accepted(owner: "A", source: "id", snapshot: snapshot)
        let context = try db.begin("question", submission: UUID(), chat: local, model: "gpt")
        XCTAssertTrue(context.contains("Earlier messages omitted"))
        XCTAssertTrue(context.contains("recent fact"))
        XCTAssertFalse(context.contains("previously"))
        let page = try db.page(local, cursor: nil, ascending: true)
        let first = (page["data"] as? [[String: Any]])?.first?["item"] as? [String: Any]
        XCTAssertEqual(first?["text"] as? String, old)
    }
    func testAccountIsolationAtomicImportAndIndependentHistoryAfterRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try CodexImportStore(directory: url)
        let entries = (0..<70).map { i -> [String: Any] in
            ["turnId": "t\(i)", "item": ["type": "agentMessage", "id": "a", "text": "answer \(i)"]]
        }
        let output: [String: Any] = [
            "turnId": "t69", "item": ["type": "commandExecution", "id": "tool", "aggregatedOutput": "retained output"],
        ]
        func snapshot(_ rows: [[String: Any]], model: String = "gpt") throws -> CodexImportStore.Snapshot {
            .init(title: "Same title", model: model, pages: [try JSONSerialization.data(withJSONObject: ["data": rows])])
        }
        XCTAssertThrowsError(try first.accepted(owner: "A", source: "bad", snapshot: snapshot([entries[0], entries[0]])))
        XCTAssertTrue(try first.list().isEmpty)
        let local = try first.accepted(owner: "A", source: "source", snapshot: snapshot(entries + [output]))
        let second = try CodexImportStore(directory: url)
        XCTAssertNotEqual(try second.accepted(owner: "B", source: "source", snapshot: snapshot([entries[1]])), local)
        XCTAssertEqual(
            try second.accepted(owner: "A", source: "source", snapshot: snapshot([entries[0]], model: "changed elsewhere")), local
        )
        var cursor: String?
        var all: [[String: Any]] = []
        repeat {
            let page = try second.page(local, cursor: cursor, ascending: true)
            all += try XCTUnwrap(page["data"] as? [[String: Any]])
            cursor = page["nextCursor"] as? String
        } while cursor != nil
        XCTAssertEqual(all.count, 71)
        XCTAssertEqual((all.last?["item"] as? [String: Any])?["aggregatedOutput"] as? String, "retained output")
        do {
            let lease = try first.lease(local)
            XCTAssertThrowsError(try second.lease(local))
            withExtendedLifetime(lease) {}
        }
        XCTAssertNoThrow(try second.lease(local))
        try first.select("gemini", id: local, expected: "gpt")
        XCTAssertThrowsError(try second.select("stale", id: local, expected: "gpt"))
        let turn = UUID()
        let handoff = try first.begin("continue", submission: turn, chat: local, model: "gemini")
        XCTAssertTrue(handoff.contains("answer 69"))
        XCTAssertFalse(handoff.contains("retained output"))
        XCTAssertThrowsError(try second.begin("continue", submission: turn, chat: local, model: "gemini"))
        try first.finish(
            turn, chat: local, model: "gemini", result: .success(.init(session: "verified", model: "gemini", text: "local reply"))
        )
        let reopened = try CodexImportStore(directory: url)
        XCTAssertEqual(try reopened.selectedModel(local), "gemini")
        let page = try reopened.page(local, cursor: nil, ascending: false)
        let item = (page["data"] as? [[String: Any]])?.first?["item"] as? [String: Any]
        XCTAssertEqual(item?["text"] as? String, "local reply")
    }
}

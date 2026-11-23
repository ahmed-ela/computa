import Foundation
import XCTest
@testable import Computa

@MainActor
final class AgentRestartTests: XCTestCase {
    func testSavingTwiceAndRacingTwoReadersDispatchesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentRestartStore(directory: directory)
        let receipt = AgentRestartStore.Receipt(threadID: "thread", turnID: "turn", model: "model",
            accessMode: .askEveryTime, requestDigest: AgentRestartStore.digest("private text"))
        for _ in 0..<25 {
            try store.save(receipt)
            try store.save(receipt)
            XCTAssertEqual(try store.pending(), [receipt])
            let claims = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<2 { group.addTask { try store.claim(receipt) } }
                var count = 0
                for try await claimed in group where claimed { count += 1 }
                return count
            }
            XCTAssertEqual(claims, 1)
        }
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testOnlyTheExactInterruptedTurnWithSettledToolsCanResume() throws {
        let user: [String: Any] = ["type": "userMessage"]
        func turn(_ id: String, _ status: String, _ extra: [[String: Any]] = []) -> [String: Any] {
            ["id": id, "status": status, "items": [user] + extra]
        }
        func eligible(_ turns: [[String: Any]], rejected: Set<String> = []) throws -> String? {
            let wire = try JSONSerialization.data(withJSONObject: ["result": ["thread": ["turns": turns]]])
            return try AppServerThreadHistoryContract.restartInterruptedTurnID(from: wire, rejectedTurns: rejected)
        }
        let settled = turn("one", "interrupted", [["type": "fileChange", "status": "completed"]])
        XCTAssertEqual(try eligible([settled]), "one")
        XCTAssertNil(try eligible([settled], rejected: ["one"]))
        XCTAssertNil(try eligible([settled, turn("two", "completed")]))
        for status in ["completed", "failed", "inProgress"] { XCTAssertNil(try eligible([turn("one", status)])) }
        for item in [["type": "commandExecution", "status": "inProgress"], ["type": "dynamicToolCall", "status": "failed"],
                     ["type": "agentMessage", "phase": "final_answer"], ["type": "unknownAction"]] {
            XCTAssertNil(try eligible([turn("one", "interrupted", [item])]))
        }
    }

    func testContinuationPreservesConfirmedRenameAndRequiresCompleteBoundedEvidence() throws {
        var entry = TimelineEntry(id: "rename", kind: .tool, title: "File edit", body: "",
            toolEvent: .init(name: "apply_patch", summary: "Renamed file", status: .succeeded, input: ""),
            fileChanges: [.init(path: "old.txt", kind: "update", movePath: "new.txt", diff: "private diff")])
        let text = try XCTUnwrap(AgentRestartStore.continuation(for: [entry][...]))
        XCTAssertTrue(text.contains(#""paths":["old.txt","new.txt"]"#))
        XCTAssertFalse(text.contains("private diff"))
        XCTAssertNil(AgentRestartStore.continuation(for: Array(repeating: entry, count: 65)[...]))
        entry.toolEvent?.summary = String(repeating: "é", count: 5_000)
        XCTAssertNil(AgentRestartStore.continuation(for: [entry][...]))
        entry.toolEvent?.summary = "Renamed file"
        entry.toolEvent?.status = .running
        XCTAssertNil(AgentRestartStore.continuation(for: [entry][...]))
    }

    func testColdStartupResumesIndependentChatsOnceAndLeavesUncertainOrStaleWorkAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentRestartStore(directory: root)
        let digest = AgentRestartStore.digest("original scoped request")
        var tasks = [AgentTask]()
        for name in ["first", "second", "stopped", "finished", "newer turn", "other model", "different request", "changed access"] {
            let id = UUID().uuidString
            var task = AgentTask(id: id, runtimeThreadID: id, title: name, summary: "", status: name == "finished" ? .completed : .waiting,
                workspace: "/synthetic", model: "model", entries: [.init(kind: .user, title: "You",
                    body: name == "different request" ? "different request" : "original scoped request", turnID: "turn")])
            task.restartInterruptedTurnID = name == "stopped" ? nil : name == "newer turn" ? "another turn" : "turn"
            tasks.append(task)
            try store.save(.init(threadID: id, turnID: "turn", model: name == "other model" ? "old model" : task.model,
                accessMode: name == "changed access" ? .askEveryTime : .fullAccess, requestDigest: digest))
        }
        let runtime = RestartTestRuntime(store: store, rows: tasks)
        let preferences = isolatedTestPreferences()
        preferences.set("fullAccess", forKey: "HeyDash.accessMode")
        for _ in 0..<2 {
            let state = AppState(tasks: [], runtime: runtime, preferences: preferences)
            await state.startRuntime()
            _ = await state.shutdownRuntime()
        }
        let submissions = await runtime.submissions
        XCTAssertEqual(Set(submissions.map(\.id)), Set(tasks.prefix(2).map(\.id)))
        XCTAssertEqual(submissions.count, 2)
        XCTAssertTrue(submissions.allSatisfy { $0.prompt == AgentRestartStore.continuation && $0.authority == "original scoped request" })
        XCTAssertTrue(try store.pending().isEmpty)
    }
}

private actor RestartTestRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Restart fixture"
    nonisolated let restartStore: AgentRestartStore?
    let rows: [AgentTask]
    var submissions: [(id: String, prompt: String, authority: String?)] = []

    init(store: AgentRestartStore, rows: [AgentTask]) { self.restartStore = store; self.rows = rows }
    func loadTasks() async throws -> [AgentTask] { rows }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID id: String, modelID: String) async throws {
        submissions.append((id, prompt, AgentRestartStore.originalRequest))
    }
    func submit(prompt: String, toTaskID id: String, modelID: String, accessMode: AccessMode) async throws {
        try await submit(prompt: prompt, toTaskID: id, modelID: modelID)
    }
    func interrupt(taskID: String) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

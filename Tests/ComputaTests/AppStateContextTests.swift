import XCTest
@testable import Computa

@MainActor
final class AppStateContextTests: XCTestCase {
    func testContextIsPerTaskAndUnknownTaskEventsAreIgnored() {
        let state = fixture().state
        state.apply(.contextUsageUpdated(taskID: "a", usage: usage(4000)))
        state.apply(.contextUsageUpdated(taskID: "b", usage: usage(2000)))
        state.apply(.contextUsageUpdated(taskID: "unknown", usage: usage(3000)))
        XCTAssertEqual(state.contextUsageByTask["a"]?.usedTokens, 4000)
        XCTAssertEqual(state.contextUsageByTask["b"]?.usedTokens, 2000)
        XCTAssertNil(state.contextUsageByTask["unknown"])
        state.apply(.contextUsageUpdated(taskID: "a", usage: nil))
        XCTAssertNil(state.contextUsageByTask["a"])
        XCTAssertNotNil(state.contextUsageByTask["b"])
    }

    func testCompactionBlocksQueueAndSteerUntilEnclosingTurnCompletes() async throws {
        let (state, runtime) = fixture()
        state.apply(.taskStatusChanged(taskID: "a", status: .running))
        state.activeTurnTaskIDs.insert("a")
        XCTAssertTrue(state.canSteer(taskID: "a"))
        state.apply(.contextCompactionChanged(taskID: "a", state: .running))
        XCTAssertTrue(state.isBusy(taskID: "a"))
        XCTAssertFalse(state.canSteer(taskID: "a"))
        _ = await state.submitOrQueue(prompt: "Next", toTaskID: "a")
        state.apply(.contextCompactionChanged(taskID: "a", state: .completed))
        try await Task.sleep(for: .milliseconds(15))
        let before = await runtime.submissions
        XCTAssertTrue(before.isEmpty)
        state.apply(.taskStatusChanged(taskID: "a", status: .completed))
        try await waitForSubmission(runtime)
        let after = await runtime.submissions
        XCTAssertEqual(after, ["Next"])
    }

    func testCompactionFailurePausesQueueEvenIfLateCompletionArrives() async throws {
        let (state, runtime) = fixture()
        state.apply(.taskStatusChanged(taskID: "a", status: .running))
        state.activeTurnTaskIDs.insert("a")
        state.apply(.contextCompactionChanged(taskID: "a", state: .running))
        _ = await state.submitOrQueue(prompt: "Keep me", toTaskID: "a")
        state.apply(.contextCompactionChanged(taskID: "a", state: .failed(message: "No summary")))
        state.apply(.taskStatusChanged(taskID: "a", status: .completed))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(state.pausedQueueTaskIDs.contains("a"))
        XCTAssertEqual(state.queuedPrompts["a"]?.map(\.text), ["Keep me"])
        let calls = await runtime.submissions
        XCTAssertTrue(calls.isEmpty)
    }

    func testDisconnectInvalidatesMeasurementAndUnblocksFailedCompaction() {
        let state = fixture().state
        state.apply(.contextUsageUpdated(taskID: "a", usage: usage(7000)))
        state.apply(.contextCompactionChanged(taskID: "a", state: .running))
        state.apply(.connectionChanged(.disconnected))
        XCTAssertTrue(state.contextUsageByTask.isEmpty)
        guard case .failed = state.compactionStateByTask["a"] else {
            return XCTFail("Disconnected compaction must not remain running")
        }
        XCTAssertFalse(state.isBusy(taskID: "a"))
    }

    func testModelChangeClearsOldMeasurementAndCompactionState() {
        let state = fixture().state
        state.apply(.contextUsageUpdated(taskID: "a", usage: usage(4000)))
        state.apply(.contextCompactionChanged(taskID: "a", state: .completed))
        XCTAssertTrue(state.setTaskModel("lmstudio-community/Qwen3.5-9B-MLX-4bit", taskID: "a"))
        XCTAssertNil(state.contextUsageByTask["a"])
        XCTAssertNil(state.compactionStateByTask["a"])
    }

    func testSnapshotPrunesRemovedTasksAndShutdownClearsMeasurements() async {
        let state = fixture().state
        state.apply(.contextUsageUpdated(taskID: "a", usage: usage(1000)))
        state.apply(.contextUsageUpdated(taskID: "b", usage: usage(2000)))
        state.apply(.contextCompactionChanged(taskID: "a", state: .completed))
        state.replaceTasks(with: state.tasks.filter { $0.id == "b" })
        XCTAssertNil(state.contextUsageByTask["a"])
        XCTAssertNil(state.compactionStateByTask["a"])
        XCTAssertNotNil(state.contextUsageByTask["b"])
        _ = await state.shutdownRuntime()
        XCTAssertTrue(state.contextUsageByTask.isEmpty)
        XCTAssertTrue(state.compactionStateByTask.isEmpty)
    }

    func testUnknownCompactionCannotBlockOtherTasksOrPauseTheirQueues() {
        let state = fixture().state
        state.apply(.contextCompactionChanged(taskID: "missing", state: .running))
        state.apply(.contextCompactionChanged(taskID: "missing", state: .failed(message: "Unknown")))
        XCTAssertTrue(state.compactionStateByTask.isEmpty)
        XCTAssertTrue(state.pausedQueueTaskIDs.isEmpty)
        XCTAssertFalse(state.isBusy(taskID: "a"))
    }

    private func fixture() -> (state: AppState, runtime: ContextRecordingRuntime) {
        let runtime = ContextRecordingRuntime()
        let tasks = ["a", "b"].map {
            AgentTask(id: $0, title: $0, summary: "", status: .completed,
                workspace: "/tmp", model: "lmstudio-community/Qwen3.5-4B-MLX-4bit")
        }
        return (AppState(tasks: tasks, runtime: runtime, preferences: isolatedTestPreferences()), runtime)
    }

    private func usage(_ count: Int) -> RuntimeContextUsage {
        .init(usedTokens: count, contextWindow: 8192, inputTokens: count,
            outputTokens: 0, turnID: "turn-a", measuredAt: .now)
    }

    private func waitForSubmission(_ runtime: ContextRecordingRuntime) async throws {
        for _ in 0..<100 {
            if await !runtime.submissions.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Queued prompt did not resume after completed compaction turn")
    }
}

private actor ContextRecordingRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Context test"
    private(set) var submissions: [String] = []
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func loadTasks() async throws -> [AgentTask] { [] }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {
        submissions.append(prompt)
    }
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

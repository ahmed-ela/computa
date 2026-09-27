import XCTest
@testable import Mactopus

@MainActor
final class AppStateActivityMetadataTests: XCTestCase {
    func testOneLogicalTurnOwnsReasoningCommentaryToolsSystemAndFinalAnswer() async throws {
        let state = makeState()
        let accepted = await state.submit(prompt: "Complete a task", toTaskID: "first")
        XCTAssertTrue(accepted)
        let owner = try XCTUnwrap(state.selectedTask?.entries.first?.id)
        XCTAssertEqual(state.selectedTask?.entries.first?.activityGroupID, owner)
        XCTAssertEqual(WebUISnapshot(state: state).tasks.first?.activeActivityGroupID, owner)
        state.apply(.taskStatusChanged(taskID: "first", status: .running))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Plan a step"))
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "comment", phase: "commentary"))
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "comment", delta: "Checking it"))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "comment", kind: .assistant, title: "Mactopus", body: "Checking it now"
        )))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "tool", kind: .tool, title: "Inspect", body: "Success"
        )))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "system", kind: .system, title: "Notice", body: "Runtime notice"
        )))
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "answer", phase: "final_answer"))
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "answer", delta: "The answer"))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "thought", kind: .reasoning, title: "Thought", body: "Completed plan"
        )))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "answer", kind: .assistant, title: "Mactopus", body: "The final answer"
        )))
        state.apply(.taskStatusChanged(taskID: "first", status: .completed))

        let entries = try XCTUnwrap(state.selectedTask?.entries)
        XCTAssertTrue(entries.allSatisfy { $0.activityGroupID == owner })
        XCTAssertEqual(entries.first { $0.id == "comment" }?.assistantPhase, "commentary")
        XCTAssertEqual(entries.first { $0.id == "answer" }?.assistantPhase, "final_answer")
        XCTAssertTrue(entries.filter { $0.kind != .assistant }.allSatisfy { $0.assistantPhase == nil })
        XCTAssertNotNil(entries.last?.workedForSeconds)
        XCTAssertEqual(entries.filter { $0.workedForSeconds != nil }.count, 1)
        XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeActivityGroupID)
    }

    func testExplicitPhaseBeforeDuringAndAtCompletionReconcilesWithoutTextGuessing() async throws {
        let state = makeState()
        _ = await state.submit(prompt: "Answer", toTaskID: "first")
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "answer", phase: "commentary"))
        XCTAssertEqual(state.selectedTask?.entries.count, 1, "Metadata alone must not create a blank row.")
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "answer", delta: "A completed final answer"))
        XCTAssertEqual(state.selectedTask?.entries.last?.assistantPhase, "commentary")
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "answer", phase: "final_answer"))
        XCTAssertEqual(WebUISnapshot(state: state).tasks.first?.entries.last?.assistantPhase, "final_answer")
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "answer", kind: .assistant, title: "Mactopus", body: "Authoritative answer", assistantPhase: "commentary"
        )))
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "answer", phase: "final_answer"))
        XCTAssertEqual(state.selectedTask?.entries.last?.assistantPhase, "commentary", "Late metadata cannot relabel a finalized item.")
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "unclassified", delta: "This is the final answer."))
        XCTAssertNil(state.selectedTask?.entries.last?.assistantPhase, "Prose does not establish protocol phase.")
    }

    func testInvalidPhasesAreIgnoredAndNonAssistantEntriesCannotCarryThem() async {
        let state = makeState()
        _ = await state.submit(prompt: "Answer", toTaskID: "first")
        for invalid in ["", "final", "analysis", "FINAL_ANSWER", " final_answer "] {
            state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "answer", phase: invalid))
        }
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "answer", delta: "Text"))
        XCTAssertNil(state.selectedTask?.entries.last?.assistantPhase)
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "answer", phase: "commentary"))
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "answer", phase: "analysis"))
        XCTAssertEqual(state.selectedTask?.entries.last?.assistantPhase, "commentary")
        XCTAssertNil(TimelineEntry(kind: .reasoning, title: "Thought", body: "Text", assistantPhase: "final_answer").assistantPhase)
        XCTAssertNil(TimelineEntry(kind: .assistant, title: "Answer", body: "Text", assistantPhase: "guessed").assistantPhase)
    }

    func testDiscardInvalidatesPhaseOnlyItemsAndNextTurnGetsNewOwnership() async throws {
        let state = makeState()
        _ = await state.submit(prompt: "First", toTaskID: "first")
        let firstOwner = try XCTUnwrap(state.activeActivityGroupID(for: "first"))
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "abandoned", phase: "commentary"))
        state.apply(.assistantMessagesDiscarded(taskID: "first"))
        state.apply(.taskStatusChanged(taskID: "first", status: .waiting))
        XCTAssertNil(state.activeActivityGroupID(for: "first"))
        _ = await state.submit(prompt: "Next", toTaskID: "first")
        let secondOwner = try XCTUnwrap(state.activeActivityGroupID(for: "first"))
        XCTAssertNotEqual(firstOwner, secondOwner)
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "abandoned", phase: "final_answer"))
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "abandoned", delta: "Late old output"))
        XCTAssertFalse(state.selectedTask?.entries.contains { $0.id == "abandoned" } == true)
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "fresh", phase: "final_answer"))
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "fresh", delta: "New output"))
        XCTAssertEqual(state.selectedTask?.entries.last?.activityGroupID, secondOwner)
        XCTAssertEqual(state.selectedTask?.entries.last?.assistantPhase, "final_answer")
        XCTAssertEqual(state.selectedTask?.entries.first?.activityGroupID, firstOwner)
    }

    func testGroupsAndPhasesAreIsolatedAcrossTasksWithoutMigratingHistory() async throws {
        let historical = TimelineEntry(id: "old", kind: .assistant, title: "Old", body: "Historical answer")
        let state = makeState(tasks: [task("first", entries: [historical]), task("second")])
        _ = await state.submit(prompt: "First task", toTaskID: "first")
        _ = await state.submit(prompt: "Second task", toTaskID: "second")
        let first = try XCTUnwrap(state.activeActivityGroupID(for: "first"))
        let second = try XCTUnwrap(state.activeActivityGroupID(for: "second"))
        XCTAssertNotEqual(first, second)
        state.apply(.assistantMessagePhaseUpdated(taskID: "first", itemID: "same", phase: "commentary"))
        state.apply(.assistantMessagePhaseUpdated(taskID: "second", itemID: "same", phase: "final_answer"))
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "same", delta: "First"))
        state.apply(.assistantMessageDelta(taskID: "second", itemID: "same", delta: "Second"))
        XCTAssertEqual(state.tasks.first?.entries.last?.activityGroupID, first)
        XCTAssertEqual(state.tasks.last?.entries.last?.activityGroupID, second)
        XCTAssertEqual(state.tasks.first?.entries.last?.assistantPhase, "commentary")
        XCTAssertEqual(state.tasks.last?.entries.last?.assistantPhase, "final_answer")
        XCTAssertEqual(state.tasks.first?.entries.first, historical)
        XCTAssertNil(state.tasks.first?.entries.first?.activityGroupID)
    }

    func testSteerKeepsOriginalGroupEvenIfCompletionArrivesBeforeAcknowledgment() async throws {
        let runtime = ActivityMetadataRuntime()
        let state = makeState(runtime: runtime)
        _ = await state.submit(prompt: "Original", toTaskID: "first")
        let owner = try XCTUnwrap(state.activeActivityGroupID(for: "first"))
        state.apply(.taskStatusChanged(taskID: "first", status: .running))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Thinking"))
        _ = await state.submitOrQueue(prompt: "Refine it", toTaskID: "first")
        let queued = try XCTUnwrap(state.queuedPrompts["first"]?.first)
        await runtime.holdNextSteer()
        XCTAssertTrue(state.canSteer(taskID: "first"))
        let delivery = Task { await state.steerQueuedPrompt(taskID: "first", id: queued.id) }
        for _ in 0..<100 {
            if await runtime.hasPendingSteer { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = await runtime.hasPendingSteer
        XCTAssertTrue(held)
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "thought", kind: .reasoning, title: "Thought", body: "Thought done"
        )))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "answer", kind: .assistant, title: "Mactopus", body: "Final answer", assistantPhase: "final_answer"
        )))
        state.apply(.taskStatusChanged(taskID: "first", status: .completed))
        XCTAssertNil(state.activeActivityGroupID(for: "first"))
        await runtime.finishSteer()
        let accepted = await delivery.value
        XCTAssertTrue(accepted)
        let entries = try XCTUnwrap(state.selectedTask?.entries)
        XCTAssertEqual(entries.filter { $0.kind == .user }.map(\.body), ["Original", "Refine it"])
        XCTAssertTrue(entries.allSatisfy { $0.activityGroupID == owner })
        XCTAssertNotNil(entries.first { $0.id == "answer" }?.workedForSeconds)
    }

    private func makeState(tasks: [AgentTask]? = nil, runtime: ActivityMetadataRuntime = ActivityMetadataRuntime()) -> AppState {
        AppState(tasks: tasks ?? [task("first")], runtime: runtime, preferences: isolatedTestPreferences())
    }

    private func task(_ id: String, entries: [TimelineEntry] = []) -> AgentTask {
        AgentTask(id: id, title: id, summary: "", status: .draft,
                  workspace: "/tmp", model: LocalModelCatalog.defaultModelID, entries: entries)
    }
}

private actor ActivityMetadataRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Activity metadata test"
    private var holdSteer = false
    private var pendingSteer: CheckedContinuation<Void, Never>?
    var hasPendingSteer: Bool { pendingSteer != nil }
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func steer(prompt: String, toTaskID taskID: AgentTask.ID) async throws {
        if holdSteer {
            holdSteer = false
            await withCheckedContinuation { pendingSteer = $0 }
        }
    }
    func holdNextSteer() { holdSteer = true }
    func finishSteer() { pendingSteer?.resume(); pendingSteer = nil }
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

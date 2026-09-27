import XCTest
@testable import Mactopus

@MainActor
final class AppStateReasoningStreamingTests: XCTestCase {
    func testCumulativeReasoningUpdatesOneEntryImmediatelyAndFinalizesInPlace() throws {
        let state = AppState(tasks: [task("first")], preferences: isolatedTestPreferences())
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: " \n"))
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "  Checking\n"))
        let first = try XCTUnwrap(WebUISnapshot(state: state).tasks.first?.entries.first)
        XCTAssertEqual(first.kind, "reasoning")
        XCTAssertTrue(first.isStreaming)
        XCTAssertEqual(first.body, "  Checking\n")

        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "  Checking\nnext step"))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "  Checking\nnext step"))
        XCTAssertEqual(state.selectedTask?.entries.count, 1)
        XCTAssertEqual(state.selectedTask?.entries.first?.body, "  Checking\nnext step")
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "thought", kind: .reasoning, title: "Thought", body: "Authoritative completed thought",
            timestamp: Date(timeIntervalSince1970: first.timestamp + 5)
        )))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Late replacement"))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "thought", kind: .reasoning, title: "Thought", body: "Duplicate completion"
        )))
        let final = try XCTUnwrap(WebUISnapshot(state: state).tasks.first?.entries.first)
        XCTAssertEqual(state.selectedTask?.entries.count, 1)
        XCTAssertEqual(final.body, "Authoritative completed thought")
        XCTAssertEqual(final.timestamp, first.timestamp)
        XCTAssertFalse(final.isStreaming)
        XCTAssertNil(final.workedForSeconds)
    }

    func testDiscardedReasoningCannotReturnAndDoesNotDiscardPublicAnswer() {
        let state = AppState(tasks: [task("first")], preferences: isolatedTestPreferences())
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "saved", kind: .reasoning, title: "Thought", body: "Completed earlier"
        )))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "partial", text: "Incomplete thought"))
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "answer", delta: "Public answer"))
        state.apply(.reasoningMessagesDiscarded(taskID: "first"))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "partial", text: "Late thought"))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "partial", kind: .reasoning, title: "Thought", body: "Late final"
        )))
        XCTAssertEqual(state.selectedTask?.entries.map(\.id), ["saved", "answer"])
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "new-thought", text: "A fresh item"))
        XCTAssertEqual(state.selectedTask?.entries.last?.body, "A fresh item")
        XCTAssertTrue(state.selectedTask?.entries.last?.isStreaming == true)
    }

    func testPublicAnswerPausesThinkingWithoutFinalizingReasoningOrTurn() async throws {
        var initial = task("first")
        initial.status = .draft
        let state = AppState(tasks: [initial], runtime: ReasoningStateRuntime(), preferences: isolatedTestPreferences())
        let submitted = await state.submit(prompt: "Think then answer", toTaskID: "first")
        XCTAssertTrue(submitted)
        state.apply(.taskStatusChanged(taskID: "first", status: .running))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Checking"))
        let timestamp = try XCTUnwrap(state.selectedTask?.entries.first { $0.id == "thought" }?.timestamp)
        XCTAssertTrue(state.selectedTask?.entries.first { $0.id == "thought" }?.isStreaming == true)

        state.apply(.assistantMessageDelta(taskID: "first", itemID: "answer", delta: "Public text"))
        XCTAssertFalse(state.selectedTask?.entries.first { $0.id == "thought" }?.isStreaming ?? true)
        XCTAssertEqual(state.selectedTask?.status, .running)
        XCTAssertNotNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
        XCTAssertTrue(state.selectedTask?.entries.allSatisfy { $0.workedForSeconds == nil } == true)

        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Checking another step"))
        XCTAssertTrue(state.selectedTask?.entries.first { $0.id == "thought" }?.isStreaming == true)
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "answer", kind: .assistant, title: "Mactopus", body: "Final public answer"
        )))
        XCTAssertFalse(state.selectedTask?.entries.first { $0.id == "thought" }?.isStreaming ?? true)
        XCTAssertTrue(state.selectedTask?.entries.allSatisfy { $0.workedForSeconds == nil } == true)

        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "thought", kind: .reasoning, title: "Thought", body: "Authoritative final thought"
        )))
        let thoughts = try XCTUnwrap(state.selectedTask?.entries.filter { $0.id == "thought" })
        XCTAssertEqual(thoughts.count, 1)
        XCTAssertEqual(thoughts.first?.body, "Authoritative final thought")
        XCTAssertEqual(thoughts.first?.timestamp, timestamp)
        XCTAssertFalse(thoughts.first?.isStreaming ?? true)
        XCTAssertNil(thoughts.first?.workedForSeconds)
        state.apply(.taskStatusChanged(taskID: "first", status: .completed))
        XCTAssertNotNil(state.selectedTask?.entries.first { $0.id == "answer" }?.workedForSeconds)
        XCTAssertNil(state.selectedTask?.entries.first { $0.id == "thought" }?.workedForSeconds)
    }

    func testReasoningIsTaskIsolatedAndCannotOverwritePublicAnswer() {
        let state = AppState(tasks: [task("first"), task("second")], preferences: isolatedTestPreferences())
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "same-id", text: "First thought"))
        state.apply(.reasoningMessageUpdated(taskID: "second", itemID: "same-id", text: "Second thought"))
        state.apply(.assistantMessageDelta(taskID: "first", itemID: "answer", delta: "Real answer"))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "answer", text: "Must not overwrite"))
        state.apply(.reasoningMessagesDiscarded(taskID: "second"))
        XCTAssertEqual(state.tasks.first?.entries.map(\.body), ["First thought", "Real answer"])
        XCTAssertTrue(state.tasks.last?.entries.isEmpty == true)
    }

    func testReasoningNeverReceivesPublicAnswerDuration() async {
        for hasAnswer in [false, true] {
            var initial = task("first")
            initial.status = .draft
            let state = AppState(tasks: [initial], runtime: ReasoningStateRuntime(), preferences: isolatedTestPreferences())
            let submitted = await state.submit(prompt: "Think then answer", toTaskID: "first")
            XCTAssertTrue(submitted)
            state.apply(.taskStatusChanged(taskID: "first", status: .running))
            state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Considering"))
            state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
                id: "thought", kind: .reasoning, title: "Thought", body: "Considered", workedForSeconds: 99
            )))
            if hasAnswer {
                state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
                    id: "answer", kind: .assistant, title: "Mactopus", body: "Public answer"
                )))
            }
            state.apply(.taskStatusChanged(taskID: "first", status: .completed))
            XCTAssertNil(state.selectedTask?.entries.first { $0.kind == .reasoning }?.workedForSeconds)
            XCTAssertEqual(state.selectedTask?.entries.filter { $0.workedForSeconds != nil }.count, hasAnswer ? 1 : 0)
            XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
        }
    }

    func testTerminalStatusesDropOnlyUnfinishedReasoning() {
        for status in [TaskStatus.waiting, .completed, .draft] {
            let state = AppState(tasks: [task("first")], preferences: isolatedTestPreferences())
            state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
                id: "saved", kind: .reasoning, title: "Thought", body: "Completed"
            )))
            state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "partial", text: "Incomplete"))
            state.apply(.taskStatusChanged(taskID: "first", status: status))
            XCTAssertEqual(state.selectedTask?.entries.map(\.id), ["saved"])
            state.apply(.taskStatusChanged(taskID: "first", status: .running))
            state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "partial", text: "Late"))
            XCTAssertEqual(state.selectedTask?.entries.map(\.id), ["saved"])
        }
    }

    func testRuntimeDisconnectFailureAndShutdownRemoveUnfinishedReasoning() async {
        for connection in [RuntimeConnectionState.disconnected, .failed(message: "Test failure")] {
            let state = AppState(tasks: [task("first")], preferences: isolatedTestPreferences())
            state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Partial"))
            state.apply(.connectionChanged(connection))
            XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
        }
        let state = AppState(tasks: [task("first")], preferences: isolatedTestPreferences())
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Partial"))
        _ = await state.shutdownRuntime()
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "another", text: "Late"))
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
    }

    func testTaskReplacementClearsDraftOwnershipAndLateUpdates() {
        let initial = task("first")
        let state = AppState(tasks: [initial], preferences: isolatedTestPreferences())
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "old", text: "Partial"))
        state.apply(.taskUpserted(initial))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "old", text: "Late"))
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "new", text: "Next partial"))
        state.apply(.tasksSnapshot([initial]))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "new", text: "Late"))
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
    }

    func testUnknownIdleAndBlankReasoningDoNotCreatePlaceholderRows() {
        var initial = task("first")
        initial.status = .completed
        let state = AppState(tasks: [initial], preferences: isolatedTestPreferences())
        state.apply(.reasoningMessageUpdated(taskID: "missing", itemID: "thought", text: "Text"))
        state.apply(.reasoningMessageUpdated(taskID: "first", itemID: "thought", text: "Text"))
        state.apply(.timelineEntryAppended(taskID: "first", entry: TimelineEntry(
            id: "blank", kind: .reasoning, title: "Thought", body: " \n"
        )))
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
    }

    private func task(_ id: String) -> AgentTask {
        AgentTask(id: id, title: id, summary: "", status: .running,
                  workspace: "/tmp", model: LocalModelCatalog.defaultModelID)
    }
}

private struct ReasoningStateRuntime: AgentRuntimeClient {
    let providerName = "Reasoning state test"
    func loadTasks() async throws -> [AgentTask] { [] }
    func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

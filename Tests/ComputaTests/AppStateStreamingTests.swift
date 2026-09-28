import XCTest
@testable import Computa

final class AppStateStreamingTests: XCTestCase {
    @MainActor
    func testChunksAreVisibleImmediatelyInOneStableEntryWithExactWhitespace() throws {
        let task = makeTask(id: "first")
        let state = AppState(tasks: [task], preferences: isolatedTestPreferences())
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "reply", delta: ""))
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)

        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "reply", delta: "  Hello"))
        let first = try XCTUnwrap(WebUISnapshot(state: state).tasks.first?.entries.first)
        XCTAssertEqual(first.body, "  Hello")
        XCTAssertNil(first.workedForSeconds)

        for chunk in ["\n", "\n", "  world", "! 👋", "\n"] {
            state.apply(.assistantMessageDelta(taskID: task.id, itemID: "reply", delta: chunk))
        }
        let snapshot = WebUISnapshot(state: state)
        XCTAssertEqual(snapshot.tasks.first?.entries.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.entries.first?.body, "  Hello\n\n  world! 👋\n")
        XCTAssertEqual(snapshot.tasks.first?.entries.first?.timestamp, first.timestamp)
        XCTAssertEqual(snapshot.selectedEntryID, "reply")
        XCTAssertEqual(state.selectedTask?.status, .running)
    }

    @MainActor
    func testAuthoritativeCompletionReplacesDraftAndLateEventsCannotRewriteIt() async throws {
        var task = makeTask(id: "first")
        task.status = .draft
        let state = AppState(
            tasks: [task], runtime: StreamingTestRuntime(), preferences: isolatedTestPreferences()
        )
        let submitted = await state.submit(prompt: "Say hello", toTaskID: task.id)
        XCTAssertTrue(submitted)
        state.apply(.taskStatusChanged(taskID: task.id, status: .running))
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "reply", delta: "Partial text"))
        let draft = try XCTUnwrap(state.selectedTask?.entries.last)
        state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
            id: "reply", kind: .assistant, title: "Computa", body: "Full authoritative answer",
            timestamp: draft.timestamp.addingTimeInterval(5)
        )))
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "reply", delta: " stale"))
        state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
            id: "reply", kind: .assistant, title: "Computa", body: "Duplicate final"
        )))

        let replies = try XCTUnwrap(state.selectedTask?.entries.filter { $0.kind == .assistant })
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.body, "Full authoritative answer")
        XCTAssertEqual(replies.first?.timestamp, draft.timestamp)
        XCTAssertNil(replies.first?.workedForSeconds)
        state.apply(.taskStatusChanged(taskID: task.id, status: .completed))
        XCTAssertNotNil(state.selectedTask?.entries.last?.workedForSeconds)
        XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
    }

    @MainActor
    func testDiscardRemovesOnlyDraftsAndDoesNotAllowThemToReappear() {
        var task = makeTask(id: "first")
        task.entries = [TimelineEntry(id: "history", kind: .assistant, title: "Computa", body: "Saved")]
        let state = AppState(tasks: [task], preferences: isolatedTestPreferences())
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "accepted", delta: "Accepted"))
        state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
            id: "accepted", kind: .assistant, title: "Computa", body: "Accepted"
        )))
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "discarded", delta: "Unverified"))
        state.apply(.assistantMessagesDiscarded(taskID: task.id))
        XCTAssertEqual(state.selectedTask?.entries.map(\.id), ["history", "accepted"])
        XCTAssertEqual(state.selectedEntryID, "accepted")

        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "discarded", delta: " late"))
        state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
            id: "discarded", kind: .assistant, title: "Computa", body: "Late final"
        )))
        // A managed retry may stream a new item while the same turn is active.
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "retry", delta: "New attempt"))
        XCTAssertEqual(state.selectedTask?.entries.map(\.id), ["history", "accepted", "retry"])
        XCTAssertEqual(state.selectedTask?.entries.last?.body, "New attempt")
    }

    @MainActor
    func testDraftsAreIsolatedByTaskEvenWhenItemIDsMatch() {
        let first = makeTask(id: "first")
        let second = makeTask(id: "second")
        let state = AppState(tasks: [first, second], preferences: isolatedTestPreferences())
        state.apply(.assistantMessageDelta(taskID: first.id, itemID: "reply", delta: "First"))
        state.apply(.assistantMessageDelta(taskID: second.id, itemID: "reply", delta: "Second"))
        state.apply(.assistantMessagesDiscarded(taskID: first.id))
        XCTAssertTrue(state.tasks.first?.entries.isEmpty == true)
        XCTAssertEqual(state.tasks.last?.entries.first?.body, "Second")
        state.selectTask(second.id)
        XCTAssertEqual(WebUISnapshot(state: state).tasks.last?.entries.first?.body, "Second")
        state.apply(.timelineEntryAppended(taskID: second.id, entry: TimelineEntry(
            id: "reply", kind: .assistant, title: "Computa", body: "Second final"
        )))
        XCTAssertEqual(state.selectedTask?.entries.count, 1)
        XCTAssertEqual(state.selectedTask?.entries.first?.body, "Second final")
    }

    @MainActor
    func testTerminalStatusesRemoveUnfinishedOutputWithoutTimingIt() async {
        for terminalStatus in [TaskStatus.waiting, .completed, .draft] {
            var task = makeTask(id: "first")
            task.status = .draft
            let state = AppState(
                tasks: [task], runtime: StreamingTestRuntime(), preferences: isolatedTestPreferences()
            )
            let submitted = await state.submit(prompt: "Answer", toTaskID: task.id)
            XCTAssertTrue(submitted)
            state.apply(.taskStatusChanged(taskID: task.id, status: .running))
            state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
                id: "commentary", kind: .assistant, title: "Computa", body: "Looking into it"
            )))
            state.apply(.assistantMessageDelta(taskID: task.id, itemID: "unfinished", delta: "Incomplete"))
            state.apply(.taskStatusChanged(taskID: task.id, status: terminalStatus))
            XCTAssertFalse(state.selectedTask?.entries.contains { $0.id == "unfinished" } == true)
            XCTAssertTrue(state.selectedTask?.entries.allSatisfy { $0.workedForSeconds == nil } == true)
            XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
            state.apply(.assistantMessageDelta(taskID: task.id, itemID: "late-new", delta: "Late"))
            XCTAssertFalse(state.selectedTask?.entries.contains { $0.id == "late-new" } == true)

            // A stale chunk cannot return in a later turn of the same chat.
            state.apply(.taskStatusChanged(taskID: task.id, status: .running))
            state.apply(.assistantMessageDelta(taskID: task.id, itemID: "unfinished", delta: "Late"))
            XCTAssertFalse(state.selectedTask?.entries.contains { $0.id == "unfinished" } == true)
        }
    }

    @MainActor
    func testWhitespaceItemBeforeToolContinuationFinalizesWithoutLosingTurnDuration() async throws {
        for completedWhitespace in ["\n\n", ""] {
            var task = makeTask(id: "first")
            task.status = .draft
            let state = AppState(
                tasks: [task], runtime: StreamingTestRuntime(), preferences: isolatedTestPreferences()
            )
            let firstSubmitted = await state.submit(prompt: "First attempt", toTaskID: task.id)
            XCTAssertTrue(firstSubmitted)
            state.apply(.taskStatusChanged(taskID: task.id, status: .running))
            state.apply(.assistantMessageDelta(taskID: task.id, itemID: "cancelled", delta: "Unfinished"))
            state.apply(.assistantMessagesDiscarded(taskID: task.id))
            state.apply(.taskStatusChanged(taskID: task.id, status: .waiting))

            let secondSubmitted = await state.submit(prompt: "Check status, then answer", toTaskID: task.id)
            XCTAssertTrue(secondSubmitted)
            state.apply(.taskStatusChanged(taskID: task.id, status: .running))
            state.apply(.assistantMessageDelta(taskID: task.id, itemID: "before-tool", delta: "\n\n"))
            state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
                id: "before-tool", kind: .assistant, title: "Computa", body: completedWhitespace
            )))
            state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
                id: "status-tool", kind: .tool, title: "computer_v2_status", body: "Succeeded"
            )))
            state.apply(.assistantMessageDelta(taskID: task.id, itemID: "final", delta: "\n\nSTREAM_"))
            state.apply(.assistantMessageDelta(taskID: task.id, itemID: "final", delta: "TOOL_OK"))
            state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
                id: "final", kind: .assistant, title: "Computa", body: "\n\nSTREAM_TOOL_OK"
            )))
            state.apply(.taskStatusChanged(taskID: task.id, status: .completed))

            let snapshot = WebUISnapshot(state: state)
            let entries = try XCTUnwrap(snapshot.tasks.first?.entries)
            XCTAssertFalse(entries.contains { $0.id == "cancelled" })
            XCTAssertEqual(entries.filter { $0.id == "final" }.count, 1)
            XCTAssertEqual(entries.last?.body, "\n\nSTREAM_TOOL_OK")
            XCTAssertNotNil(entries.last?.workedForSeconds)
            XCTAssertTrue(entries.dropLast().allSatisfy { $0.workedForSeconds == nil })
            XCTAssertNil(snapshot.tasks.first?.activeTurnStartedAt)
        }
    }

    @MainActor
    func testRuntimeFailureAndDisconnectionDiscardDraftsAcrossTasks() {
        for connection in [RuntimeConnectionState.disconnected, .failed(message: "Test failure")] {
            let state = AppState(
                tasks: [makeTask(id: "first"), makeTask(id: "second")],
                preferences: isolatedTestPreferences()
            )
            state.apply(.assistantMessageDelta(taskID: "first", itemID: "one", delta: "Partial one"))
            state.apply(.assistantMessageDelta(taskID: "second", itemID: "two", delta: "Partial two"))
            state.apply(.connectionChanged(connection))
            XCTAssertTrue(state.tasks.allSatisfy { $0.entries.isEmpty })
            XCTAssertTrue(state.tasks.allSatisfy { $0.status == .waiting })
            state.apply(.assistantMessageDelta(taskID: "first", itemID: "one", delta: "Late"))
            XCTAssertTrue(state.tasks.allSatisfy { $0.entries.isEmpty })
        }
    }

    @MainActor
    func testShutdownDiscardsDraftAndRejectsSubsequentChunks() async {
        let task = makeTask(id: "first")
        let state = AppState(tasks: [task], preferences: isolatedTestPreferences())
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "reply", delta: "Partial"))
        let report = await state.shutdownRuntime()
        XCTAssertTrue(report.succeeded)
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "new", delta: "Late"))
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
    }

    @MainActor
    func testTaskReplacementClearsDraftOwnershipAndPreservesAuthoritativeHistory() {
        let task = makeTask(id: "first")
        let state = AppState(tasks: [task], preferences: isolatedTestPreferences())
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "upserted", delta: "Partial"))
        state.apply(.taskUpserted(task))
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "upserted", delta: "Late"))
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)

        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "snapshot", delta: "Partial"))
        var restored = task
        restored.entries = [TimelineEntry(
            id: "snapshot", kind: .assistant, title: "Computa", body: "Authoritative saved answer"
        )]
        state.apply(.tasksSnapshot([restored]))
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "snapshot", delta: "Late"))
        XCTAssertEqual(state.selectedTask?.entries.count, 1)
        XCTAssertEqual(state.selectedTask?.entries.first?.body, "Authoritative saved answer")
        state.apply(.assistantMessagesDiscarded(taskID: task.id))
        XCTAssertEqual(state.selectedTask?.entries.first?.body, "Authoritative saved answer")
    }

    @MainActor
    func testIdleAndUnknownTasksDoNotAcceptStreamingOutput() {
        var task = makeTask(id: "idle")
        task.status = .completed
        let state = AppState(tasks: [task], preferences: isolatedTestPreferences())
        state.apply(.assistantMessageDelta(taskID: "missing", itemID: "reply", delta: "Text"))
        state.apply(.assistantMessageDelta(taskID: task.id, itemID: "reply", delta: "Text"))
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
    }

    private func makeTask(id: String) -> AgentTask {
        AgentTask(
            id: id, title: id, summary: "", status: .running,
            workspace: "/tmp", model: LocalModelCatalog.defaultModelID
        )
    }
}

private struct StreamingTestRuntime: AgentRuntimeClient {
    let providerName = "Streaming test"
    func loadTasks() async throws -> [AgentTask] { [] }
    func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

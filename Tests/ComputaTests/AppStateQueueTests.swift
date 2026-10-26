import Foundation
import XCTest
@testable import Computa

@MainActor
final class AppStateQueueTests: XCTestCase {
    private let taskID = "queue-task"

    func testBusyTaskQueuesTrimmedMessagesWithoutSendingOrChangingTranscript() async {
        let (state, runtime) = fixture(running: true)
        let accepted = await state.submitOrQueue(prompt: "  First\nfollow-up  ", toTaskID: taskID)
        let secondAccepted = await state.submitOrQueue(prompt: "Second", toTaskID: taskID)
        XCTAssertTrue(accepted)
        XCTAssertTrue(secondAccepted)
        XCTAssertEqual(queueText(state), ["First\nfollow-up", "Second"])
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
        let calls = await runtime.submissions
        XCTAssertTrue(calls.isEmpty)
    }

    func testQueuedTurnClockStartsAtDispatchNotWhileWaitingInQueue() async throws {
        let (state, runtime) = fixture(running: true)
        let accepted = await state.submitOrQueue(prompt: "Next answer", toTaskID: taskID)
        XCTAssertTrue(accepted)
        XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)

        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        try await waitForSubmissionCount(1, runtime: runtime)
        let startedAt = try XCTUnwrap(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
        XCTAssertGreaterThan(startedAt, 0)

        state.apply(.timelineEntryAppended(taskID: taskID, entry: TimelineEntry(
            kind: .assistant, title: "Computa", body: "Next answer is ready."
        )))
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        XCTAssertNotNil(state.selectedTask?.entries.last?.workedForSeconds)
        XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
    }

    func testInvalidAndUnknownTaskInputNeverEntersQueue() async {
        let (state, runtime) = fixture()
        for text in ["", " \n ", String(repeating: "x", count: 200_001)] {
            let accepted = await state.submitOrQueue(prompt: text, toTaskID: taskID)
            XCTAssertFalse(accepted)
        }
        let unknownAccepted = await state.submitOrQueue(prompt: "Hello", toTaskID: "missing")
        XCTAssertFalse(unknownAccepted)
        XCTAssertTrue(state.queuedPrompts.isEmpty)
        let calls = await runtime.submissions
        XCTAssertTrue(calls.isEmpty)
    }

    func testIdleSubmissionDrainsImmediatelyAndKeepsNextMessageQueued() async {
        let (state, runtime) = fixture()
        let accepted = await state.submitOrQueue(prompt: "First", toTaskID: taskID)
        XCTAssertTrue(accepted)
        XCTAssertEqual(userText(state), ["First"])
        XCTAssertTrue(queueText(state).isEmpty)
        XCTAssertTrue(state.activeTurnTaskIDs.contains(taskID))
        _ = await state.submitOrQueue(prompt: "Second", toTaskID: taskID)
        XCTAssertEqual(queueText(state), ["Second"])
        let calls = await runtime.submissions
        XCTAssertEqual(calls.map(\.prompt), ["First"])
    }

    func testCompletedTurnsDrainOneMessageAtATimeInFIFOOrder() async throws {
        let (state, runtime) = fixture(running: true)
        for text in ["First", "Second", "Third"] {
            _ = await state.submitOrQueue(prompt: text, toTaskID: taskID)
        }
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        try await waitForSubmissionCount(1, runtime: runtime)
        await settleScheduledWork()
        XCTAssertEqual(queueText(state), ["Second", "Third"])
        XCTAssertEqual(userText(state), ["First"])

        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        try await waitForSubmissionCount(2, runtime: runtime)
        await settleScheduledWork()
        XCTAssertEqual(queueText(state), ["Third"])
        let calls = await runtime.submissions
        XCTAssertEqual(calls.map(\.prompt), ["First", "Second"])
    }

    func testRepeatedCompletionBeforeScheduledDrainCannotDispatchTwice() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "First", toTaskID: taskID)
        _ = await state.submitOrQueue(prompt: "Second", toTaskID: taskID)
        for _ in 0..<5 {
            state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        }
        try await waitForSubmissionCount(1, runtime: runtime)
        await settleScheduledWork()
        let calls = await runtime.submissions
        XCTAssertEqual(calls.map(\.prompt), ["First"])
        XCTAssertEqual(queueText(state), ["Second"])
    }

    func testWaitingAndFailedPauseQueueUntilExplicitResume() async throws {
        for status in [TaskStatus.waiting, .failed] {
            let (state, runtime) = fixture(running: true)
            _ = await state.submitOrQueue(prompt: "Follow-up", toTaskID: taskID)
            state.apply(.taskStatusChanged(taskID: taskID, status: status))
            await settleScheduledWork()
            XCTAssertEqual(state.selectedTask?.status, status)
            XCTAssertFalse(state.isBusy(taskID: taskID))
            XCTAssertFalse(state.activeTurnTaskIDs.contains(taskID))
            XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
            let before = await runtime.submissions
            XCTAssertTrue(before.isEmpty)
            let resumed = await state.resumeQueue(taskID: taskID)
            XCTAssertTrue(resumed)
            try await waitForSubmissionCount(1, runtime: runtime)
            XCTAssertTrue(queueText(state).isEmpty)
        }
    }

    func testStopPausesQueueEvenIfRuntimeLaterReportsCompleted() async {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Keep this unsent", toTaskID: taskID)
        let stopped = await state.interrupt(taskID: taskID)
        XCTAssertTrue(stopped)
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        await settleScheduledWork()
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        XCTAssertEqual(queueText(state), ["Keep this unsent"])
        let calls = await runtime.submissions
        let stops = await runtime.interruptions
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(stops, [taskID])
    }

    func testEditingHeadHoldsFIFOAndSavingDispatchesOnlyEditedMessage() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Original", toTaskID: taskID)
        _ = await state.submitOrQueue(prompt: "Later", toTaskID: taskID)
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        XCTAssertTrue(state.beginQueueEdit(taskID: taskID, id: first.id))
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        await settleScheduledWork()
        let before = await runtime.submissions
        XCTAssertTrue(before.isEmpty)
        XCTAssertFalse(state.editQueuedPrompt(taskID: taskID, id: first.id, prompt: " \n "))
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.status, .editing)
        XCTAssertTrue(state.editQueuedPrompt(taskID: taskID, id: first.id, prompt: "  Revised  "))
        try await waitForSubmissionCount(1, runtime: runtime)
        await settleScheduledWork()
        let after = await runtime.submissions
        XCTAssertEqual(after.map(\.prompt), ["Revised"])
        XCTAssertEqual(queueText(state), ["Later"])
    }

    func testCancelEditPreservesOriginalAndReleasesHead() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Original", toTaskID: taskID)
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        XCTAssertTrue(state.beginQueueEdit(taskID: taskID, id: first.id))
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        XCTAssertTrue(state.cancelQueueEdit(taskID: taskID, id: first.id))
        try await waitForSubmissionCount(1, runtime: runtime)
        let calls = await runtime.submissions
        XCTAssertEqual(calls.map(\.prompt), ["Original"])
    }

    func testReorderAndDeleteChangePendingOrderOnly() async throws {
        let (state, runtime) = fixture(running: true)
        for text in ["First", "Second", "Third"] {
            _ = await state.submitOrQueue(prompt: text, toTaskID: taskID)
        }
        let items = try XCTUnwrap(state.queuedPrompts[taskID])
        XCTAssertTrue(state.moveQueuedPrompt(taskID: taskID, id: items[2].id, beforeID: items[0].id))
        XCTAssertEqual(queueText(state), ["Third", "First", "Second"])
        XCTAssertTrue(state.moveQueuedPrompt(taskID: taskID, id: items[0].id, beforeID: nil))
        XCTAssertEqual(queueText(state), ["Third", "Second", "First"])
        XCTAssertFalse(state.moveQueuedPrompt(taskID: taskID, id: items[0].id, beforeID: "missing"))
        XCTAssertFalse(state.moveQueuedPrompt(taskID: taskID, id: items[0].id, beforeID: items[0].id))
        XCTAssertTrue(state.deleteQueuedPrompt(taskID: taskID, id: items[1].id))
        XCTAssertEqual(queueText(state), ["Third", "First"])
        XCTAssertTrue(userText(state).isEmpty)
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        try await waitForSubmissionCount(1, runtime: runtime)
        let calls = await runtime.submissions
        XCTAssertEqual(calls.map(\.prompt), ["Third"])
    }

    func testSendingPromptCannotBeEditedDeletedMovedOrSteered() async throws {
        let (state, runtime) = fixture()
        await runtime.holdNextSubmission()
        let delivery = Task { await state.submitOrQueue(prompt: "In flight", toTaskID: taskID) }
        try await waitForSubmissionCount(1, runtime: runtime)
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        XCTAssertEqual(first.status, .sending)
        _ = await state.submitOrQueue(prompt: "Later", toTaskID: taskID)
        let last = try XCTUnwrap(state.queuedPrompts[taskID]?.last)
        XCTAssertFalse(state.beginQueueEdit(taskID: taskID, id: first.id))
        XCTAssertFalse(state.editQueuedPrompt(taskID: taskID, id: first.id, prompt: "Changed"))
        XCTAssertFalse(state.deleteQueuedPrompt(taskID: taskID, id: first.id))
        XCTAssertFalse(state.moveQueuedPrompt(taskID: taskID, id: first.id, beforeID: nil))
        XCTAssertFalse(state.moveQueuedPrompt(taskID: taskID, id: last.id, beforeID: first.id))
        let steered = await state.steerQueuedPrompt(taskID: taskID, id: first.id)
        XCTAssertFalse(steered)
        await runtime.finishSubmission()
        let accepted = await delivery.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(queueText(state), ["Later"])
    }

    func testSubmissionFailureRetainsFailedPromptAndPausesUntilResume() async throws {
        let (state, runtime) = fixture()
        await runtime.rejectNextSubmission()
        let accepted = await state.submitOrQueue(prompt: "Recoverable", toTaskID: taskID)
        XCTAssertTrue(accepted, "Accepted means saved in queue, not acknowledged by transport.")
        XCTAssertEqual(queueText(state), ["Recoverable"])
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.status, .failed)
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.deliveryUncertain, true)
        XCTAssertFalse(state.canChangeModel(for: taskID))
        XCTAssertNotNil(state.queuedPrompts[taskID]?.first?.error)
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        _ = await state.submitOrQueue(prompt: "Later", toTaskID: taskID)
        await settleScheduledWork()
        let before = await runtime.submissions
        XCTAssertEqual(before.count, 1)
        let resumed = await state.resumeQueue(taskID: taskID)
        XCTAssertTrue(resumed)
        try await waitForSubmissionCount(2, runtime: runtime)
        XCTAssertEqual(queueText(state), ["Later"])
        let after = await runtime.submissions
        XCTAssertEqual(after.map(\.prompt), ["Recoverable", "Recoverable"])
    }

    func testQueueDrainRemainsBoundToOriginalTaskWhenSelectionChanges() async throws {
        let (state, runtime) = fixture(running: true)
        let other = makeTask(id: "other-task")
        state.tasks.append(other)
        _ = await state.submitOrQueue(prompt: "For original task", toTaskID: taskID)
        state.selectTask(other.id)
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        try await waitForSubmissionCount(1, runtime: runtime)
        await settleScheduledWork()
        let calls = await runtime.submissions
        XCTAssertEqual(calls.first?.taskID, taskID)
        XCTAssertEqual(state.selectedTaskID, other.id)
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
        XCTAssertEqual(userText(state), ["For original task"])
    }

    func testKnownPreflightRejectionAllowsModelChangeButRequiresManualResume() async throws {
        let (state, runtime) = fixture()
        await runtime.rejectNextSubmissionBeforeDispatch()
        _ = await state.submitOrQueue(prompt: "Keep this message", toTaskID: taskID)
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.status, .failed)
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.deliveryUncertain, false)
        XCTAssertTrue(state.canChangeModel(for: taskID))
        XCTAssertTrue(state.setTaskModel("lmstudio-community/Qwen3.5-9B-MLX-4bit", taskID: taskID))
        await settleScheduledWork()
        let before = await runtime.submissions
        XCTAssertEqual(before.count, 1, "Changing the model must not replay the saved message.")
        XCTAssertEqual(queueText(state), ["Keep this message"])
        let resumed = await state.resumeQueue(taskID: taskID)
        XCTAssertTrue(resumed)
        try await waitForSubmissionCount(2, runtime: runtime)
        let after = await runtime.submissions
        XCTAssertEqual(after.last?.modelID, "lmstudio-community/Qwen3.5-9B-MLX-4bit")
        XCTAssertTrue(queueText(state).isEmpty)
    }

    func testQueuedMessageAfterDefinitiveFailureStillPreventsRetargeting() async {
        let (state, runtime) = fixture()
        await runtime.rejectNextSubmissionBeforeDispatch()
        _ = await state.submitOrQueue(prompt: "Rejected", toTaskID: taskID)
        _ = await state.submitOrQueue(prompt: "Pending", toTaskID: taskID)
        XCTAssertFalse(state.canChangeModel(for: taskID))
        XCTAssertEqual(queueText(state), ["Rejected", "Pending"])
    }

    func testRejectedChatSelectionRetainsQueueThroughDiscoveryUntilExplicitResume() async throws {
        let family = WebsiteModelChoice(provider: "chatgpt", key: "GPT-6", label: "GPT-6")
        for rejectedModel in ["browser/chatgpt", family.modelID] {
            let initiallyRunning = rejectedModel != "browser/chatgpt"
            let historic = TimelineEntry(kind: .assistant, title: "Recorded answer", body: "Keep this history", turnID: "historic-turn")
            let task = AgentTask(id: taskID, title: "Saved Chat selection", summary: "", status: initiallyRunning ? .running : .draft,
                                 workspace: "/tmp", model: rejectedModel, entries: [historic])
            let preferences = isolatedTestPreferences()
            preferences.set(rejectedModel, forKey: "LocalCodex.defaultModelID")
            let runtime = QueueControlledRuntime()
            await runtime.validateWebsiteSelectionsBeforeDispatch()
            let state = AppState(tasks: [task], runtime: runtime, preferences: preferences, websiteModelDiscovery: { provider in
                provider == "chatgpt" ? [syntheticChatGPTChoice]
                    : [WebsiteModelChoice(provider: provider, key: "fixture", label: "Fixture")]
            })
            state.connectionState = .connected(provider: runtime.providerName)
            if initiallyRunning { state.activeTurnTaskIDs.insert(taskID) }
            let accepted = await state.submitOrQueue(prompt: "Keep this rejected message", toTaskID: taskID)
            XCTAssertTrue(accepted)
            if initiallyRunning {
                XCTAssertEqual(state.selectedTask?.model, family.modelID, "An active/queued historic identity must not migrate before its dispatch boundary")
                state.apply(.taskStatusChanged(taskID: taskID, status: .waiting))
                await settleScheduledWork()
                let attempts = await runtime.modelValidationAttempts
                XCTAssertTrue(attempts.isEmpty, "Pausing the historic queue must not dispatch it")
                let resumed = await state.resumeQueue(taskID: taskID)
                XCTAssertTrue(resumed)
            }
            let failed = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
            XCTAssertEqual(failed.status, .failed)
            XCTAssertEqual(failed.deliveryUncertain, false)
            XCTAssertTrue(state.canChangeModel(for: taskID))
            XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
            XCTAssertEqual(state.selectedTask?.entries.last?.title, "Prompt was not delivered")
            XCTAssertEqual(state.selectedTask?.entries.first, historic)
            let rejectedAttempts = await runtime.modelValidationAttempts
            let rejectedSubmissions = await runtime.submissions
            XCTAssertEqual(rejectedAttempts.map(\.modelID), [rejectedModel])
            XCTAssertTrue(rejectedSubmissions.isEmpty, "Actual configuration validation must reject before accepting a submission")

            await state.refreshWebsiteModels()
            await settleScheduledWork()
            XCTAssertEqual(state.selectedTask?.model, syntheticChatGPTModelID)
            XCTAssertEqual(state.defaultModel, syntheticChatGPTModelID)
            XCTAssertEqual(state.queuedPrompts[taskID]?.first, failed, "Discovery must preserve the failed queued message")
            XCTAssertEqual(state.selectedTask?.entries.first, historic)
            XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
            let afterDiscovery = await runtime.modelValidationAttempts
            XCTAssertEqual(afterDiscovery, rejectedAttempts, "Discovery and migration cannot replay the prompt")

            let resumed = await state.resumeQueue(taskID: taskID)
            XCTAssertTrue(resumed)
            let recovered = await runtime.submissions
            let finalAttempts = await runtime.modelValidationAttempts
            XCTAssertEqual(finalAttempts.map(\.modelID), [rejectedModel, syntheticChatGPTModelID])
            XCTAssertEqual(recovered, [.init(prompt: failed.text, taskID: taskID, modelID: syntheticChatGPTModelID)])
            XCTAssertTrue(queueText(state).isEmpty)
        }
    }

    func testLegacyFailedQueueWithoutDeliveryClassificationRemainsFenced() {
        let (state, _) = fixture()
        var legacy = QueuedPrompt(id: "legacy", text: "Uncertain")
        legacy.status = .failed
        state.queuedPrompts[taskID] = [legacy]
        XCTAssertFalse(state.canChangeModel(for: taskID))
    }

    func testQueuedMessagesPreventModelChangesEvenWhenPausedAndIdle() async throws {
        let (state, _) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Pending", toTaskID: taskID)
        state.apply(.taskStatusChanged(taskID: taskID, status: .waiting))
        XCTAssertFalse(state.canChangeModel(for: taskID))
        XCTAssertFalse(state.setTaskModel("lmstudio-community/Qwen3.5-9B-MLX-4bit", taskID: taskID))
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        XCTAssertTrue(state.deleteQueuedPrompt(taskID: taskID, id: first.id))
        XCTAssertTrue(state.canChangeModel(for: taskID))
    }

    func testShutdownPreventsScheduledQueueDrainResumeAndNewInput() async {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Pending", toTaskID: taskID)
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        _ = await state.shutdownRuntime()
        await settleScheduledWork()
        let resumed = await state.resumeQueue(taskID: taskID)
        let accepted = await state.submitOrQueue(prompt: "New", toTaskID: taskID)
        XCTAssertFalse(resumed)
        XCTAssertFalse(accepted)
        XCTAssertEqual(queueText(state), ["Pending"])
        let calls = await runtime.submissions
        XCTAssertTrue(calls.isEmpty)
    }

    func testSteeringChangesTranscriptAndRemovesPromptOnlyAfterAcknowledgment() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Use blue", toTaskID: taskID)
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        await runtime.holdNextSteer()
        let steering = Task { await state.steerQueuedPrompt(taskID: taskID, id: first.id) }
        try await waitForSteerCount(1, runtime: runtime)
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.status, .sending)
        XCTAssertTrue(userText(state).isEmpty)
        XCTAssertFalse(state.canSteer(taskID: taskID))
        let duplicate = await state.steerQueuedPrompt(taskID: taskID, id: first.id)
        XCTAssertFalse(duplicate)
        await runtime.finishSteer()
        let accepted = await steering.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(userText(state), ["Use blue"])
        XCTAssertTrue(queueText(state).isEmpty)
        XCTAssertTrue(state.activeTurnTaskIDs.contains(taskID))
        let starts = await runtime.submissions
        let stops = await runtime.interruptions
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(stops.isEmpty)
    }

    func testFailedSteerKeepsMessageAndPausesWithoutAppendingUserEntry() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Use blue", toTaskID: taskID)
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        await runtime.rejectNextSteer()
        let accepted = await state.steerQueuedPrompt(taskID: taskID, id: first.id)
        XCTAssertFalse(accepted)
        XCTAssertEqual(queueText(state), ["Use blue"])
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.status, .failed)
        XCTAssertNotNil(state.queuedPrompts[taskID]?.first?.error)
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        XCTAssertTrue(userText(state).isEmpty)
    }

    func testCompletionDuringSteerAcknowledgmentWaitsThenDrainsRemainingPrompt() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Steer now", toTaskID: taskID)
        _ = await state.submitOrQueue(prompt: "Next turn", toTaskID: taskID)
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        await runtime.holdNextSteer()
        let steering = Task { await state.steerQueuedPrompt(taskID: taskID, id: first.id) }
        try await waitForSteerCount(1, runtime: runtime)
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        await settleScheduledWork()
        let before = await runtime.submissions
        XCTAssertTrue(before.isEmpty)
        await runtime.finishSteer()
        let accepted = await steering.value
        XCTAssertTrue(accepted)
        try await waitForSubmissionCount(1, runtime: runtime)
        await settleScheduledWork()
        let after = await runtime.submissions
        XCTAssertEqual(after.map(\.prompt), ["Next turn"])
        XCTAssertEqual(userText(state), ["Steer now", "Next turn"])
        XCTAssertTrue(queueText(state).isEmpty)
    }

    func testBridgeSteerClaimsSynchronouslyBeforeImmediateCompletionCanDrain() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Steer this", toTaskID: taskID)
        _ = await state.submitOrQueue(prompt: "Following turn", toTaskID: taskID)
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        await runtime.holdNextSteer()

        XCTAssertTrue(state.requestSteerQueuedPrompt(taskID: taskID, id: first.id))
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.status, .sending)
        XCTAssertFalse(state.requestSteerQueuedPrompt(taskID: taskID, id: first.id))
        // No await occurs between the bridge claim and the completion event.
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        XCTAssertTrue(state.isBusy(taskID: taskID))
        try await waitForSteerCount(1, runtime: runtime)
        await settleScheduledWork()
        let before = await runtime.submissions
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(queueText(state), ["Steer this", "Following turn"])
        XCTAssertTrue(userText(state).isEmpty)

        await runtime.finishSteer()
        try await waitForSubmissionCount(1, runtime: runtime)
        await settleScheduledWork()
        let steers = await runtime.steers
        let starts = await runtime.submissions
        XCTAssertEqual(steers.map(\.prompt), ["Steer this"])
        XCTAssertEqual(starts.map(\.prompt), ["Following turn"])
        XCTAssertEqual(userText(state), ["Steer this", "Following turn"])
        XCTAssertTrue(queueText(state).isEmpty)
    }

    func testFailedSteerAfterCompletionDoesNotSilentlyRetryAsANewTurn() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Steer now", toTaskID: taskID)
        _ = await state.submitOrQueue(prompt: "Next turn", toTaskID: taskID)
        let first = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        await runtime.holdNextSteer()
        let steering = Task { await state.steerQueuedPrompt(taskID: taskID, id: first.id) }
        try await waitForSteerCount(1, runtime: runtime)
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        await runtime.finishSteer(failing: true)
        let accepted = await steering.value
        XCTAssertFalse(accepted)
        await settleScheduledWork()
        XCTAssertEqual(queueText(state), ["Steer now", "Next turn"])
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        XCTAssertTrue(userText(state).isEmpty)
        let calls = await runtime.submissions
        XCTAssertTrue(calls.isEmpty)
    }

    func testConnectionFailurePausesPendingMessages() async {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Pending", toTaskID: taskID)
        state.apply(.connectionChanged(.failed(message: "Disconnected")))
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        await settleScheduledWork()
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        let calls = await runtime.submissions
        XCTAssertTrue(calls.isEmpty)
    }

    func testWebAcceptanceQueuesSynchronouslyAndReturnsMatchingReceipt() {
        let (state, _) = fixture(running: true)
        XCTAssertTrue(state.acceptPrompt(prompt: "  Pending  ", taskID: taskID, requestID: "request-1"))
        XCTAssertEqual(queueText(state), ["Pending"])
        XCTAssertEqual(state.promptReceipts.count, 1)
        XCTAssertEqual(state.promptReceipts.last?.id, "request-1")
        XCTAssertEqual(state.promptReceipts.last?.taskID, taskID)
        XCTAssertEqual(state.promptReceipts.last?.accepted, true)
        XCTAssertTrue(userText(state).isEmpty)
    }

    func testSameWebRequestIDAndPayloadAcknowledgesWithoutDuplicateQueueItem() {
        let (state, _) = fixture(running: true)
        for _ in 0..<3 {
            XCTAssertTrue(state.acceptPrompt(prompt: "Pending", taskID: taskID, requestID: "same"))
        }
        XCTAssertEqual(queueText(state), ["Pending"])
        XCTAssertEqual(state.promptReceipts.count, 1)
        XCTAssertEqual(state.promptReceipts.last?.accepted, true)
        XCTAssertEqual(state.promptReceipts.last?.revision, 3, "A repeated acknowledgment must bypass snapshot content deduplication")
    }

    func testReusedWebRequestIDCannotChangePromptOrTask() {
        let (state, _) = fixture(running: true)
        state.tasks.append(makeTask(id: "other-task"))
        XCTAssertTrue(state.acceptPrompt(prompt: "Original", taskID: taskID, requestID: "same"))
        XCTAssertFalse(state.acceptPrompt(prompt: "Changed", taskID: taskID, requestID: "same"))
        XCTAssertEqual(state.promptReceipts.last?.accepted, false)
        XCTAssertFalse(state.acceptPrompt(prompt: "Original", taskID: "other-task", requestID: "same"))
        XCTAssertEqual(state.promptReceipts.last?.accepted, false)
        XCTAssertEqual(state.promptReceipts.last?.taskID, "other-task")
        XCTAssertEqual(queueText(state), ["Original"])
        XCTAssertTrue(state.queuedPrompts["other-task", default: []].isEmpty)
        XCTAssertTrue(state.acceptPrompt(prompt: "Original", taskID: taskID, requestID: "same"))
        XCTAssertEqual(queueText(state), ["Original"])
    }

    func testInvalidWebPromptsAndShutdownHaveRejectedReceipts() async {
        let (state, _) = fixture(running: true)
        let invalid: [(prompt: String, taskID: String, requestID: String)] = [
            (" \n ", taskID, "empty"),
            (String(repeating: "😀", count: 50_001), taskID, "too-many-utf8-bytes"),
            ("Valid text", "missing", "missing-task"),
        ]
        for item in invalid {
            XCTAssertFalse(state.acceptPrompt(prompt: item.prompt, taskID: item.taskID, requestID: item.requestID))
            XCTAssertEqual(state.promptReceipts.last?.id, item.requestID)
            XCTAssertEqual(state.promptReceipts.last?.accepted, false)
        }
        _ = await state.shutdownRuntime()
        XCTAssertFalse(state.acceptPrompt(prompt: "After shutdown", taskID: taskID, requestID: "stopped"))
        XCTAssertEqual(state.promptReceipts.last?.id, "stopped")
        XCTAssertEqual(state.promptReceipts.last?.accepted, false)
        XCTAssertTrue(state.queuedPrompts.isEmpty)
    }

    func testDisconnectedTaskBecomesIdleButQueueRequiresExplicitResume() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Pending", toTaskID: taskID)
        state.apply(.connectionChanged(.disconnected))
        XCTAssertEqual(state.selectedTask?.status, .waiting)
        XCTAssertFalse(state.activeTurnTaskIDs.contains(taskID))
        XCTAssertFalse(state.isBusy(taskID: taskID))
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        await settleScheduledWork()
        let before = await runtime.submissions
        XCTAssertTrue(before.isEmpty)
        let resumed = await state.resumeQueue(taskID: taskID)
        XCTAssertTrue(resumed)
        try await waitForSubmissionCount(1, runtime: runtime)
        XCTAssertTrue(queueText(state).isEmpty)
    }

    func testSteeringAndQueueDrainWaitWhileApprovalResolutionSettles() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Pending", toTaskID: taskID)
        let item = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        state.resolvingApprovalIDs.insert("approval-settling")
        XCTAssertFalse(state.canSteer(taskID: taskID))
        let steered = await state.steerQueuedPrompt(taskID: taskID, id: item.id)
        XCTAssertFalse(steered)
        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        XCTAssertTrue(state.isBusy(taskID: taskID))
        await settleScheduledWork()
        let submissions = await runtime.submissions
        let steers = await runtime.steers
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertTrue(steers.isEmpty)
        XCTAssertEqual(queueText(state), ["Pending"])
    }

    func testAssistantArrivingBeforeSteerAcknowledgmentStaysAfterUserInTranscript() async throws {
        let (state, runtime) = fixture(running: true)
        _ = await state.submitOrQueue(prompt: "Use blue", toTaskID: taskID)
        let item = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        await runtime.holdNextSteer()
        let steering = Task { await state.steerQueuedPrompt(taskID: taskID, id: item.id) }
        try await waitForSteerCount(1, runtime: runtime)
        state.apply(.timelineEntryAppended(taskID: taskID, entry: TimelineEntry(
            kind: .assistant, title: "Computa", body: "Using blue now."
        )))
        XCTAssertTrue(userText(state).isEmpty)
        await runtime.finishSteer()
        let accepted = await steering.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(state.selectedTask?.entries.map(\.body), ["Use blue", "Using blue now."])
        XCTAssertEqual(state.selectedTask?.entries.map(\.kind), [.user, .assistant])
    }

    private func fixture(running: Bool = false) -> (AppState, QueueControlledRuntime) {
        let runtime = QueueControlledRuntime()
        let state = AppState(tasks: [makeTask(id: taskID, running: running)], runtime: runtime, preferences: isolatedTestPreferences())
        if running { state.activeTurnTaskIDs.insert(taskID) }
        state.connectionState = .connected(provider: runtime.providerName)
        return (state, runtime)
    }

    private func makeTask(id: String, running: Bool = false) -> AgentTask {
        AgentTask(id: id, title: id, summary: "", status: running ? .running : .draft,
                  workspace: "/tmp", model: "lmstudio-community/Qwen3.5-4B-MLX-4bit")
    }

    private func queueText(_ state: AppState) -> [String] {
        state.queuedPrompts[taskID, default: []].map(\.text)
    }

    private func userText(_ state: AppState) -> [String] {
        state.tasks.first(where: { $0.id == taskID })?.entries
            .filter { $0.kind == .user }.map(\.body) ?? []
    }

    private func waitForSubmissionCount(_ count: Int, runtime: QueueControlledRuntime) async throws {
        try await waitUntil { await runtime.submissions.count >= count }
    }

    private func waitForSteerCount(_ count: Int, runtime: QueueControlledRuntime) async throws {
        try await waitUntil { await runtime.steers.count >= count }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected fake-runtime call was not observed within one second.")
        throw QueueControlledRuntime.Failure()
    }

    private func settleScheduledWork() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private actor QueueControlledRuntime: AgentRuntimeClient {
    struct Call: Equatable, Sendable {
        let prompt: String
        let taskID: String
        var modelID: String = ""
    }
    struct Failure: LocalizedError {
        var errorDescription: String? { "Controlled transport rejection" }
    }
    nonisolated let providerName = "Queue test runtime"
    private(set) var submissions = [Call]()
    private(set) var modelValidationAttempts = [Call]()
    private(set) var steers = [Call]()
    private(set) var interruptions = [String]()
    private var shouldHoldSubmission = false
    private var shouldRejectSubmission = false
    private var shouldRejectBeforeDispatch = false
    private var validatesWebsiteSelection = false
    private var shouldHoldSteer = false
    private var shouldRejectSteer = false
    private var submissionContinuation: CheckedContinuation<Void, Error>?
    private var steerContinuation: CheckedContinuation<Void, Error>?

    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }

    func holdNextSubmission() { shouldHoldSubmission = true }
    func rejectNextSubmission() { shouldRejectSubmission = true }
    func rejectNextSubmissionBeforeDispatch() { shouldRejectBeforeDispatch = true }
    func validateWebsiteSelectionsBeforeDispatch() { validatesWebsiteSelection = true }
    func holdNextSteer() { shouldHoldSteer = true }
    func rejectNextSteer() { shouldRejectSteer = true }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {
        let call = Call(prompt: prompt, taskID: taskID, modelID: modelID)
        if validatesWebsiteSelection {
            modelValidationAttempts.append(call)
            try CodexAppServerRuntime.Configuration.localQwen.validateSelectedModel(modelID)
        }
        submissions.append(call)
        if shouldRejectBeforeDispatch {
            shouldRejectBeforeDispatch = false
            throw WebModelServer.Failure.embeddedRequired
        }
        if shouldRejectSubmission {
            shouldRejectSubmission = false
            throw Failure()
        }
        if shouldHoldSubmission {
            shouldHoldSubmission = false
            try await withCheckedThrowingContinuation { submissionContinuation = $0 }
        }
    }

    func steer(prompt: String, toTaskID taskID: AgentTask.ID) async throws {
        steers.append(Call(prompt: prompt, taskID: taskID))
        if shouldRejectSteer {
            shouldRejectSteer = false
            throw Failure()
        }
        if shouldHoldSteer {
            shouldHoldSteer = false
            try await withCheckedThrowingContinuation { steerContinuation = $0 }
        }
    }

    func finishSubmission(failing: Bool = false) {
        let continuation = submissionContinuation
        submissionContinuation = nil
        if failing { continuation?.resume(throwing: Failure()) }
        else { continuation?.resume() }
    }

    func finishSteer(failing: Bool = false) {
        let continuation = steerContinuation
        steerContinuation = nil
        if failing { continuation?.resume(throwing: Failure()) }
        else { continuation?.resume() }
    }

    func interrupt(taskID: AgentTask.ID) async throws { interruptions.append(taskID) }
    func resolveApproval(requestID: String, approved: Bool) async throws { }
}

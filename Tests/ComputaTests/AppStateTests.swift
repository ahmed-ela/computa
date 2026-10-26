import AutomationCore
import XCTest
@testable import Computa

final class AppStateTests: XCTestCase {
    @MainActor
    func testAdvancedInterfaceDetailsAreOptIn() {
        let state = AppState(tasks: [], preferences: isolatedTestPreferences())
        XCTAssertFalse(state.isInspectorPresented)
        XCTAssertFalse(state.showToolPayloads)

        state.isInspectorPresented = true
        state.showToolPayloads = true
        let snapshot = WebUISnapshot(state: state)
        XCTAssertTrue(snapshot.isInspectorPresented)
        XCTAssertTrue(snapshot.showToolPayloads)
    }

    func testLocalQwenConfigurationFitsAConstrainedLocalContext() {
        let configuration = CodexAppServerRuntime.Configuration.localQwen

        XCTAssertEqual(configuration.modelProvider, "lmstudio")
        XCTAssertEqual(configuration.model, "lmstudio-community/Qwen3.5-4B-MLX-4bit")
        XCTAssertEqual(configuration.reasoningEffort, "medium")
        XCTAssertLessThan(configuration.baseInstructions.utf8.count, 1_024)
        XCTAssertTrue(configuration.codexHomePath.hasSuffix("/LocalCodex/CodexHome"))
        XCTAssertNotEqual(
            configuration.codexHomePath,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .path
        )
    }

    func testLocalThreadConfigUsesModelSpecificContextLimits() {
        let expectedLimits: [(modelID: String, window: Int, compactLimit: Int)] = [
            ("mlx-community/Qwen3.8-27B-4bit", 4096, 3072),
            ("lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit", 4096, 3072),
            ("lmstudio-community/Qwen3.5-9B-MLX-4bit", 16384, 12288),
            ("lmstudio-community/Qwen3.5-4B-MLX-4bit", 16384, 12288),
            ("unlisted/model", 4096, 3072),
        ]

        for limits in expectedLimits {
            let config = CodexAppServerRuntime.localThreadConfig(for: limits.modelID)
            XCTAssertEqual(config["model_context_window"] as? Int, limits.window, limits.modelID)
            XCTAssertEqual(
                config["model_auto_compact_token_limit"] as? Int,
                limits.compactLimit,
                limits.modelID
            )
            XCTAssertEqual(config["web_search"] as? String, "disabled", limits.modelID)
        }
    }

    func testLoadedThreadCanSwitchOnlyBetweenModelsWithTheSameContextLimits() {
        let constrainedModel = "mlx-community/Qwen3.8-27B-4bit"
        let constrained = LocalThreadContext.forModel(constrainedModel)
        let nineB = LocalThreadContext.forModel("lmstudio-community/Qwen3.5-9B-MLX-4bit")
        let computerUse = LocalThreadContext.forModel("lmstudio-community/Qwen3.5-4B-MLX-4bit")

        XCTAssertEqual(nineB, computerUse)
        XCTAssertTrue(nineB.supportsModelSwitch(to: "lmstudio-community/Qwen3.5-9B-MLX-4bit"))
        XCTAssertTrue(computerUse.supportsModelSwitch(to: "lmstudio-community/Qwen3.5-4B-MLX-4bit"))
        XCTAssertTrue(nineB.supportsModelSwitch(to: "lmstudio-community/Qwen3.5-4B-MLX-4bit"))
        XCTAssertTrue(computerUse.supportsModelSwitch(to: "lmstudio-community/Qwen3.5-9B-MLX-4bit"))
        XCTAssertFalse(computerUse.supportsModelSwitch(to: constrainedModel))
        XCTAssertFalse(constrained.supportsModelSwitch(to: "lmstudio-community/Qwen3.5-4B-MLX-4bit"))
        XCTAssertFalse(constrained.supportsModelSwitch(to: "lmstudio-community/Qwen3.5-9B-MLX-4bit"))
        XCTAssertFalse(nineB.supportsModelSwitch(to: constrainedModel))
        // A still-loaded legacy 8K context is not silently relabeled 16K.
        // Cold resume after restarting the owned runtime applies the new config
        // to the same persisted thread, without requiring a new user task.
        XCTAssertFalse(LocalThreadContext.expanded.supportsModelSwitch(to: "lmstudio-community/Qwen3.5-4B-MLX-4bit"))
        XCTAssertFalse(LocalThreadContext.expanded.supportsModelSwitch(to: "lmstudio-community/Qwen3.5-9B-MLX-4bit"))
    }

    @MainActor
    func testSubmittingComposerAppendsLocalUserEntry() async {
        let state = AppState(tasks: [
            AgentTask(
                title: "Test task",
                summary: "Before",
                status: .draft,
                workspace: "/tmp",
                model: "Test model"
            )
        ], preferences: isolatedTestPreferences())

        state.composerText = "  Inspect the workspace  "

        let submitted = await state.submitComposer()

        XCTAssertTrue(submitted)
        XCTAssertEqual(state.selectedTask?.entries.count, 1)
        XCTAssertEqual(state.selectedTask?.entries.first?.body, "Inspect the workspace")
        XCTAssertEqual(state.selectedTask?.status, .waiting)
        XCTAssertTrue(state.composerText.isEmpty)
    }

    @MainActor
    func testTurnDurationBelongsOnlyToFinalReplyAndStopsAtCompletion() async throws {
        let runtime = ModelRecordingRuntime(recorder: ModelSubmissionRecorder())
        let task = AgentTask(
            id: "timed-task", title: "Timed", summary: "", status: .draft,
            workspace: "/tmp", model: LocalModelCatalog.defaultModelID
        )
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())

        let submitted = await state.submit(prompt: "Explain the result", toTaskID: task.id)
        XCTAssertTrue(submitted)
        let startedAt = try XCTUnwrap(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
        XCTAssertGreaterThan(startedAt, 0)
        state.apply(.taskStatusChanged(taskID: task.id, status: .running))
        state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
            kind: .assistant, title: "Computa", body: "Intermediate thought"
        )))
        state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
            kind: .assistant, title: "Computa", body: "Final answer"
        )))
        state.apply(.taskStatusChanged(taskID: task.id, status: .completed))

        let replies = try XCTUnwrap(state.selectedTask?.entries.filter { $0.kind == .assistant })
        XCTAssertNil(replies.first?.workedForSeconds)
        let duration = try XCTUnwrap(replies.last?.workedForSeconds)
        XCTAssertGreaterThanOrEqual(duration, 0)
        XCTAssertLessThan(duration, 10)
        XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
        XCTAssertEqual(WebUISnapshot(state: state).tasks.first?.entries.last?.workedForSeconds, duration)

        state.apply(.taskStatusChanged(taskID: task.id, status: .completed))
        XCTAssertEqual(state.selectedTask?.entries.last?.workedForSeconds, duration)
    }

    @MainActor
    func testTurnDurationIsNotShownForFailedOrAnswerlessTurns() async {
        let runtime = ModelRecordingRuntime(recorder: ModelSubmissionRecorder())
        let task = AgentTask(
            id: "timed-task", title: "Timed", summary: "", status: .draft,
            workspace: "/tmp", model: LocalModelCatalog.defaultModelID
        )
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())

        let firstSubmitted = await state.submit(prompt: "First", toTaskID: task.id)
        XCTAssertTrue(firstSubmitted)
        state.apply(.timelineEntryAppended(taskID: task.id, entry: TimelineEntry(
            kind: .assistant, title: "Computa", body: "Unverified reply"
        )))
        state.apply(.taskStatusChanged(taskID: task.id, status: .waiting))
        XCTAssertNil(state.selectedTask?.entries.last?.workedForSeconds)
        XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)

        let secondSubmitted = await state.submit(prompt: "Second", toTaskID: task.id)
        XCTAssertTrue(secondSubmitted)
        state.apply(.taskStatusChanged(taskID: task.id, status: .completed))
        XCTAssertNil(state.selectedTask?.entries.last?.workedForSeconds)
        XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
    }

    @MainActor
    func testRuntimeDisconnectClearsLiveTurnClockWithoutInventingACompletion() async {
        let runtime = ModelRecordingRuntime(recorder: ModelSubmissionRecorder())
        let task = AgentTask(
            id: "timed-task", title: "Timed", summary: "", status: .draft,
            workspace: "/tmp", model: LocalModelCatalog.defaultModelID
        )
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())
        let submitted = await state.submit(prompt: "Answer me", toTaskID: task.id)
        XCTAssertTrue(submitted)
        state.apply(.taskStatusChanged(taskID: task.id, status: .running))
        XCTAssertNotNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)

        state.apply(.connectionChanged(.failed(message: "Runtime disconnected")))
        XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
        XCTAssertTrue(state.selectedTask?.entries.allSatisfy { $0.workedForSeconds == nil } == true)
    }

    @MainActor
    func testWhitespaceOnlyPromptDoesNotAppendEntry() async {
        let state = AppState(preferences: isolatedTestPreferences())
        let originalCount = state.selectedTask?.entries.count

        state.composerText = "  \n "

        let submitted = await state.submitComposer()

        XCTAssertFalse(submitted)
        XCTAssertEqual(state.selectedTask?.entries.count, originalCount)
    }

    @MainActor
    func testExplicitPromptTargetDoesNotFollowLaterSelection() async {
        let first = AgentTask(
            id: "first",
            title: "First",
            summary: "",
            status: .draft,
            workspace: "/tmp/first",
            model: "Test model"
        )
        let second = AgentTask(
            id: "second",
            title: "Second",
            summary: "",
            status: .draft,
            workspace: "/tmp/second",
            model: "Test model"
        )
        let state = AppState(tasks: [first, second], preferences: isolatedTestPreferences())
        state.selectTask(second.id)

        let submitted = await state.submit(prompt: "For the first task", toTaskID: first.id)

        XCTAssertTrue(submitted)
        XCTAssertEqual(state.tasks.first(where: { $0.id == first.id })?.entries.last?.body, "For the first task")
        XCTAssertTrue(state.tasks.first(where: { $0.id == second.id })?.entries.isEmpty == true)
        XCTAssertEqual(state.selectedTaskID, second.id)
    }

    @MainActor
    func testCreatingTaskSelectsNewDraft() {
        let state = AppState(tasks: [], preferences: isolatedTestPreferences())

        state.createTask()

        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.selectedTask?.status, .draft)
        XCTAssertEqual(state.selectedTask?.model, state.defaultModel)
    }

    @MainActor
    func testSelectedModelIsPassedToRuntimeWithoutChangingOtherTasks() async throws {
        let recorder = ModelSubmissionRecorder()
        let state = AppState(tasks: [], runtime: ModelRecordingRuntime(recorder: recorder), preferences: isolatedTestPreferences())
        state.createTask()
        let firstTaskID = try XCTUnwrap(state.selectedTaskID)
        let fourBID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let nineBID = "lmstudio-community/Qwen3.5-9B-MLX-4bit"

        XCTAssertTrue(state.setTaskModel(fourBID, taskID: firstTaskID))
        let submitted = await state.submit(prompt: "Use the selected model", toTaskID: firstTaskID)
        XCTAssertTrue(submitted)
        let submission = await recorder.lastSubmission()
        XCTAssertEqual(submission?.taskID, firstTaskID)
        XCTAssertEqual(submission?.modelID, fourBID)

        state.createTask()
        let secondTaskID = try XCTUnwrap(state.selectedTaskID)
        XCTAssertTrue(state.setTaskModel(nineBID, taskID: secondTaskID))
        let secondSubmitted = await state.submit(prompt: "Use the other small model", toTaskID: secondTaskID)
        XCTAssertTrue(secondSubmitted)
        let secondSubmission = await recorder.lastSubmission()
        XCTAssertEqual(secondSubmission?.taskID, secondTaskID)
        XCTAssertEqual(secondSubmission?.modelID, nineBID)

        state.createTask()
        XCTAssertEqual(state.selectedTask?.model, LocalModelCatalog.defaultModelID)
        XCTAssertFalse(state.setTaskModel("unlisted/model", taskID: firstTaskID))
    }

    func testCatalogIncludesBothQwen35MLX4BitModels() {
        let expectedIDs = [
            "lmstudio-community/Qwen3.5-9B-MLX-4bit",
            "lmstudio-community/Qwen3.5-4B-MLX-4bit",
        ]

        for modelID in expectedIDs {
            let option = LocalModelCatalog.option(for: modelID)
            XCTAssertNotNil(option)
            XCTAssertFalse(option?.highMemory ?? true)
        }
        XCTAssertEqual(LocalModelCatalog.defaultModelID, "lmstudio-community/Qwen3.5-4B-MLX-4bit")
    }

    func testResidentVisualGroundingIsLimitedToModelsWithMemoryHeadroom() {
        XCTAssertTrue(LocalModelCatalog.supportsResidentVisualGrounding(
            "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        ))
        XCTAssertTrue(LocalModelCatalog.supportsResidentVisualGrounding(
            "lmstudio-community/Qwen3.5-9B-MLX-4bit"
        ))
        XCTAssertFalse(LocalModelCatalog.supportsResidentVisualGrounding(
            "mlx-community/Qwen3.8-27B-4bit"
        ))
        XCTAssertFalse(LocalModelCatalog.supportsResidentVisualGrounding(
            "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit"
        ))
    }

    @MainActor
    func testComputaRetainsLegacyModelPreference() throws {
        let suiteName = "ComputaTests.LegacyPreference.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let modelID = "mlx-community/Qwen3.8-27B-4bit"
        preferences.set(modelID, forKey: "LocalCodex.defaultModelID")

        let state = AppState(tasks: [], preferences: preferences)
        XCTAssertEqual(state.defaultModel, modelID)
        state.createTask()
        XCTAssertEqual(state.selectedTask?.model, modelID)
    }

    @MainActor
    func testDefaultModelSelectionPersistsForNewTasks() throws {
        let suiteName = "ComputaTests.ModelSelection.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let alternateID = "lmstudio-community/Qwen3.5-9B-MLX-4bit"

        let state = AppState(tasks: [], preferences: preferences)
        XCTAssertTrue(state.setDefaultModel(alternateID))
        state.createTask()
        XCTAssertEqual(state.selectedTask?.model, alternateID)

        let reopened = AppState(tasks: [], preferences: preferences)
        XCTAssertEqual(reopened.defaultModel, alternateID)
        XCTAssertFalse(reopened.setDefaultModel("unlisted/model"))
        XCTAssertEqual(reopened.defaultModel, alternateID)
    }

    @MainActor
    func testModelCannotChangeDuringActiveTurn() throws {
        let state = AppState(tasks: [], preferences: isolatedTestPreferences())
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let alternateID = try XCTUnwrap(LocalModelCatalog.options.last?.id)

        state.activeTurnTaskIDs.insert(taskID)
        XCTAssertFalse(state.setTaskModel(alternateID, taskID: taskID))
        XCTAssertFalse(WebUISnapshot(state: state).tasks.first?.modelSelectable ?? true)

        state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        XCTAssertTrue(state.setTaskModel(alternateID, taskID: taskID))
        XCTAssertTrue(WebUISnapshot(state: state).tasks.first?.modelSelectable ?? false)
    }

    @MainActor
    func testPermissionInitializationAndRefreshNeverRequestAccess() {
        let permissions = PermissionClientRecorder()
        let state = AppState(tasks: [], permissionClient: permissions, preferences: isolatedTestPreferences())

        state.refreshAutomationPermissions()

        XCTAssertEqual(permissions.currentCalls, 2)
        XCTAssertEqual(permissions.accessibilityRequestCalls, 0)
        XCTAssertEqual(permissions.screenRecordingRequestCalls, 0)
    }

    @MainActor
    func testExplicitPermissionRequestsStaySeparateAndRefreshState() {
        let permissions = PermissionClientRecorder()
        let state = AppState(tasks: [], permissionClient: permissions, preferences: isolatedTestPreferences())

        state.requestAccessibilityPermission()
        XCTAssertEqual(state.automationPermissions.accessibility, .granted)
        XCTAssertEqual(state.automationPermissions.screenRecording, .notGranted)

        state.requestScreenRecordingPermission()
        XCTAssertEqual(state.automationPermissions.accessibility, .granted)
        XCTAssertEqual(state.automationPermissions.screenRecording, .granted)
        XCTAssertEqual(permissions.accessibilityRequestCalls, 1)
        XCTAssertEqual(permissions.screenRecordingRequestCalls, 1)
    }

    @MainActor
    func testInjectedRuntimeReplacesSampleSnapshot() async {
        let liveTask = AgentTask(
            id: "thread-live-1",
            title: "Live app-server thread",
            summary: "Loaded through the swappable runtime boundary",
            status: .running,
            workspace: "/tmp/live",
            model: "Local provider"
        )
        let state = AppState(
            tasks: SampleData.tasks,
            runtime: StubRuntime(tasks: [liveTask]),
            preferences: isolatedTestPreferences()
        )

        await state.startRuntime()

        XCTAssertEqual(state.tasks.map(\.id), ["thread-live-1"])
        XCTAssertEqual(state.selectedTaskID, "thread-live-1")
        XCTAssertEqual(state.connectionState, .connected(provider: "Stub runtime"))
    }

    @MainActor
    func testStartupHistoryKeepsNewDraftPromptModelAndWebSelection() async throws {
        let restored = startupTask("saved")
        let gate = StartupTaskLoadGate()
        let state = AppState(tasks: [], runtime: HeldStartupRuntime(tasks: [restored], gate: gate),
                             preferences: isolatedTestPreferences())
        let startup = Task { await state.startRuntime() }
        await gate.waitUntilLoading()

        state.createTask()
        let firstDraftID = try XCTUnwrap(state.selectedTaskID)
        state.createTask()
        let draftID = try XCTUnwrap(state.selectedTaskID)
        let modelID = "lmstudio-community/Qwen3.5-9B-MLX-4bit"
        XCTAssertTrue(state.setTaskModel(modelID, taskID: draftID))
        let prompt = "Keep this unsent draft exactly.\nSecond line."
        state.composerText = prompt
        // The web composer stores text by task ID; restoration must keep the
        // same selected ID as well as the native composer's pending text.
        let webDrafts = [draftID: prompt]

        await gate.release()
        await startup.value

        XCTAssertEqual(state.tasks.map(\.id), [draftID, firstDraftID, restored.id])
        XCTAssertEqual(state.selectedTaskID, draftID)
        XCTAssertEqual(state.selectedTask?.model, modelID)
        XCTAssertEqual(state.selectedTask?.status, .draft)
        XCTAssertEqual(state.composerText, prompt)
        XCTAssertEqual(webDrafts[try XCTUnwrap(WebUISnapshot(state: state).selectedTaskID)], prompt)
        XCTAssertTrue(state.selectedTask?.entries.isEmpty == true)
        XCTAssertTrue(state.queuedPrompts.isEmpty)
        let submissions = await gate.submissions
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(state.connectionState, .connected(provider: "Held startup"))

        // Reconciliation applies only to the initial load. An authoritative
        // subsequent snapshot still removes tasks and their selection.
        state.apply(.tasksSnapshot([restored]))
        XCTAssertEqual(state.tasks, [restored])
        XCTAssertEqual(state.selectedTaskID, restored.id)
    }

    @MainActor
    func testStartupHistoryPreservesExistingSelectionAndHydratesUnchangedTasks() async {
        let first = startupTask("first")
        let second = startupTask("second")
        var hydratedSecond = second
        hydratedSecond.entries = [.init(kind: .assistant, title: "Saved reply", body: "Saved history")]
        let gate = StartupTaskLoadGate()
        let state = AppState(tasks: [first, second],
                             runtime: HeldStartupRuntime(tasks: [first, hydratedSecond], gate: gate),
                             preferences: isolatedTestPreferences())
        let startup = Task { await state.startRuntime() }
        await gate.waitUntilLoading()
        state.selectTask(second.id)
        state.composerText = "A follow-up for the selected task"
        await gate.release()
        await startup.value

        XCTAssertEqual(state.tasks, [first, hydratedSecond])
        XCTAssertEqual(state.selectedTaskID, second.id)
        XCTAssertEqual(state.selectedEntryID, hydratedSecond.entries.last?.id)
        XCTAssertEqual(state.composerText, "A follow-up for the selected task")
    }

    @MainActor
    func testStartupHistoryDoesNotOverwriteModelEditOrExplicitDeselection() async {
        let edited = startupTask("edited")
        let restored = startupTask("restored")
        let gate = StartupTaskLoadGate()
        let state = AppState(tasks: [edited],
                             runtime: HeldStartupRuntime(tasks: [edited, restored], gate: gate),
                             preferences: isolatedTestPreferences())
        let startup = Task { await state.startRuntime() }
        await gate.waitUntilLoading()
        let modelID = "lmstudio-community/Qwen3.5-9B-MLX-4bit"
        XCTAssertTrue(state.setTaskModel(modelID, taskID: edited.id))
        state.selectTask(nil)
        await gate.release()
        await startup.value

        XCTAssertEqual(state.tasks.map(\.id), [edited.id, restored.id])
        XCTAssertEqual(state.tasks.first?.model, modelID)
        XCTAssertNil(state.selectedTaskID)
        XCTAssertNil(state.selectedEntryID)
    }

    @MainActor
    func testStartupHistoryPreservesCreateThenDeselectFromEmptyBaseline() async throws {
        let restored = startupTask("saved")
        let gate = StartupTaskLoadGate()
        let state = AppState(tasks: [], runtime: HeldStartupRuntime(tasks: [restored], gate: gate),
                             preferences: isolatedTestPreferences())
        let startup = Task { await state.startRuntime() }
        await gate.waitUntilLoading()
        state.createTask()
        let draftID = try XCTUnwrap(state.selectedTaskID)
        state.selectTask(nil)
        await gate.release()
        await startup.value

        XCTAssertEqual(state.tasks.map(\.id), [draftID, restored.id])
        XCTAssertNil(state.selectedTaskID)
        XCTAssertNil(state.selectedEntryID)
        XCTAssertNil(WebUISnapshot(state: state).selectedTaskID)
        XCTAssertEqual(state.connectionState, .connected(provider: "Held startup"))
    }

    @MainActor
    func testNewerAuthoritativeSnapshotSupersedesStartupEvenWithEmptyBaseline() async {
        let removed = startupTask("removed")
        let newer = startupTask("newer")
        for baseline in [[], [removed]] {
            let gate = StartupTaskLoadGate()
            let state = AppState(tasks: baseline,
                                 runtime: HeldStartupRuntime(tasks: [removed], gate: gate),
                                 preferences: isolatedTestPreferences())
            let startup = Task { await state.startRuntime() }
            await gate.waitUntilLoading()
            // The existing authoritative snapshot path can remove a task that
            // was never in the startup baseline; it must still stay removed.
            state.apply(.tasksSnapshot([newer]))
            state.createTask()
            let expected = state.tasks
            let selected = state.selectedTaskID
            state.composerText = "Typed after the newer snapshot"
            await gate.release()
            await startup.value

            XCTAssertEqual(state.tasks, expected)
            XCTAssertEqual(state.selectedTaskID, selected)
            XCTAssertEqual(state.composerText, "Typed after the newer snapshot")
            XCTAssertFalse(state.tasks.contains { $0.id == removed.id })
            XCTAssertEqual(state.connectionState, .connected(provider: "Held startup"))
        }
    }

    @MainActor
    func testStartupHistoryPreservesNewTaskStreamingDraftOwnership() async throws {
        let restored = startupTask("saved")
        let gate = StartupTaskLoadGate()
        let state = AppState(tasks: [], runtime: HeldStartupRuntime(tasks: [restored], gate: gate),
                             preferences: isolatedTestPreferences())
        let startup = Task { await state.startRuntime() }
        await gate.waitUntilLoading()
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        state.apply(.taskStatusChanged(taskID: taskID, status: .running))
        state.apply(.assistantMessageDelta(taskID: taskID, itemID: "reply", delta: "First"))
        state.apply(.reasoningMessageUpdated(taskID: taskID, itemID: "reasoning", text: "Working"))
        await gate.release()
        await startup.value
        state.apply(.assistantMessageDelta(taskID: taskID, itemID: "reply", delta: " second"))
        state.apply(.reasoningMessageUpdated(taskID: taskID, itemID: "reasoning", text: "Still working"))

        XCTAssertEqual(state.selectedTaskID, taskID)
        XCTAssertEqual(state.selectedTask?.entries.first(where: { $0.id == "reply" })?.body, "First second")
        XCTAssertEqual(state.selectedTask?.entries.first(where: { $0.id == "reasoning" })?.body, "Still working")
        XCTAssertEqual(state.tasks.last, restored)
    }

    @MainActor
    func testCancelledStartupCannotApplyLateHistory() async {
        let initial = startupTask("initial")
        let gate = StartupTaskLoadGate()
        let state = AppState(tasks: [initial],
                             runtime: HeldStartupRuntime(tasks: [startupTask("late")], gate: gate),
                             preferences: isolatedTestPreferences())
        let startup = Task { await state.startRuntime() }
        await gate.waitUntilLoading()
        startup.cancel()
        await gate.release()
        await startup.value

        XCTAssertEqual(state.tasks, [initial])
        XCTAssertEqual(state.selectedTaskID, initial.id)
        XCTAssertNotEqual(state.connectionState, .connected(provider: "Held startup"))
    }

    @MainActor
    func testShutdownStartupCannotApplyLateHistory() async {
        let initial = startupTask("initial")
        let gate = StartupTaskLoadGate()
        let state = AppState(tasks: [initial],
                             runtime: HeldStartupRuntime(tasks: [startupTask("late")], gate: gate),
                             preferences: isolatedTestPreferences())
        let startup = Task { await state.startRuntime() }
        await gate.waitUntilLoading()
        _ = await state.shutdownRuntime()
        await gate.release()
        await startup.value

        XCTAssertEqual(state.tasks, [initial])
        XCTAssertEqual(state.selectedTaskID, initial.id)
        XCTAssertEqual(state.connectionState, .disconnected)
    }

    private func startupTask(_ id: String) -> AgentTask {
        AgentTask(id: id, title: id, summary: "Saved task", status: .completed,
                  workspace: "No workspace selected", model: LocalModelCatalog.defaultModelID)
    }

    @MainActor
    func testRejectedTurnKeepsConnectedTransportAndMarksTaskFailedWithoutClaimingNonDelivery() async {
        let task = AgentTask(
            id: "thread-live-2",
            title: "Offline model",
            summary: "Before",
            status: .draft,
            workspace: "/tmp/live",
            model: "Local provider"
        )
        let state = AppState(tasks: [task], runtime: RejectingRuntime(tasks: [task]), preferences: isolatedTestPreferences())
        await state.startRuntime()
        state.composerText = "Try the local model"

        let submitted = await state.submitComposer()

        XCTAssertTrue(submitted, "The native queue retains the accepted prompt even when delivery fails")
        XCTAssertEqual(state.queuedPrompts[task.id]?.first?.status, .failed)
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(task.id))
        XCTAssertEqual(state.connectionState, .connected(provider: "Rejecting runtime"))
        XCTAssertEqual(state.selectedTask?.status, .failed)
        XCTAssertEqual(state.selectedTask?.entries.last?.title, "Agent error")
        XCTAssertEqual(state.queuedPrompts[task.id]?.first?.deliveryUncertain, true,
                       "A generic runtime error does not prove that delivery never occurred")
    }

    @MainActor
    func testCancelledSubmissionRemainsWaitingAndRequiresExplicitQueueRecovery() async {
        let task = AgentTask(id: "cancelled-submission", title: "Cancelled", summary: "Before",
                             status: .draft, workspace: "/tmp", model: "Local provider")
        let runtime = RejectingRuntime(tasks: [task], cancelSubmission: true)
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())
        await state.startRuntime()

        let accepted = await state.submitOrQueue(prompt: "Cancel this submission", toTaskID: task.id)

        XCTAssertTrue(accepted, "The accepted local prompt is retained for explicit recovery")
        XCTAssertEqual(state.selectedTask?.status, .waiting)
        XCTAssertEqual(state.selectedTask?.entries.last?.title, "Prompt delivery unconfirmed")
        XCTAssertEqual(state.queuedPrompts[task.id]?.first?.status, .failed)
        XCTAssertEqual(state.queuedPrompts[task.id]?.first?.deliveryUncertain, true,
                       "Cancellation alone cannot prove the remote turn was never accepted")
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(task.id))
        XCTAssertFalse(state.activeTurnTaskIDs.contains(task.id))
        XCTAssertFalse(state.isBusy(taskID: task.id))
        XCTAssertEqual(state.connectionState, .connected(provider: runtime.providerName))
    }

    @MainActor
    func testStopTargetsOnlyRunningTaskAndWaitsForAuthoritativeStatus() async {
        let first = AgentTask(
            id: "thread-running",
            title: "Running task",
            summary: "Before",
            status: .running,
            workspace: "/tmp/first",
            model: "Local provider"
        )
        let second = AgentTask(
            id: "thread-inactive",
            title: "Waiting task",
            summary: "Before",
            status: .waiting,
            workspace: "/tmp/second",
            model: "Local provider"
        )
        let recorder = InterruptionRecorder()
        let state = AppState(
            tasks: [first, second],
            runtime: InterruptionRecordingRuntime(recorder: recorder),
            preferences: isolatedTestPreferences()
        )
        let approval = ActionApprovalRequest(
            id: "pending-for-first",
            taskID: first.id,
            kind: .computerUse,
            title: "Pending action",
            summary: "Before stop",
            details: "Native decision"
        )
        state.apply(.approvalRequested(approval))

        let inactiveStop = await state.interrupt(taskID: second.id)
        let runningStop = await state.interrupt(taskID: first.id)
        XCTAssertFalse(inactiveStop)
        XCTAssertTrue(runningStop)
        XCTAssertEqual(state.tasks.first?.status, .running)
        XCTAssertTrue(state.interruptingTaskIDs.contains(first.id))
        let duplicateStop = await state.interrupt(taskID: first.id)
        let recordedTaskIDs = await recorder.recordedTaskIDs()
        XCTAssertFalse(duplicateStop)
        XCTAssertEqual(recordedTaskIDs, [first.id])

        state.apply(.taskStatusChanged(taskID: first.id, status: .waiting))
        XCTAssertFalse(state.interruptingTaskIDs.contains(first.id))
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertEqual(state.tasks.first?.status, .waiting)
    }

    @MainActor
    func testFailedStopCanBeRetriedAndDoesNotChangeTaskStatus() async {
        let task = AgentTask(
            id: "thread-stop-failure",
            title: "Running task",
            summary: "Before",
            status: .running,
            workspace: "/tmp/workspace",
            model: "Local provider"
        )
        let recorder = InterruptionRecorder()
        let state = AppState(
            tasks: [task],
            runtime: InterruptionRecordingRuntime(recorder: recorder, shouldFail: true),
            preferences: isolatedTestPreferences()
        )

        let firstStop = await state.interrupt(taskID: task.id)
        XCTAssertFalse(firstStop)
        XCTAssertFalse(state.interruptingTaskIDs.contains(task.id))
        XCTAssertEqual(state.selectedTask?.status, .running)
        XCTAssertEqual(state.selectedTask?.entries.last?.title, "Could not stop task")
        XCTAssertTrue(state.selectedTask?.entries.last?.body.contains("Stop request was rejected") == true)
        let retryStop = await state.interrupt(taskID: task.id)
        let recordedTaskIDs = await recorder.recordedTaskIDs()
        XCTAssertFalse(retryStop)
        XCTAssertEqual(recordedTaskIDs, [task.id, task.id])
    }

    @MainActor
    func testApprovalRequestCanBeAllowedOnceThroughRuntime() async {
        let task = AgentTask(
            id: "thread-approval",
            title: "Approval",
            summary: "Waiting",
            status: .running,
            workspace: "/tmp/live",
            model: "Local provider"
        )
        let recorder = ApprovalRecorder()
        let state = AppState(
            tasks: [task],
            runtime: ApprovalRecordingRuntime(tasks: [task], recorder: recorder),
            preferences: isolatedTestPreferences()
        )
        await state.startRuntime()
        let request = ActionApprovalRequest(
            id: "approval-1",
            taskID: task.id,
            kind: .command,
            title: "Run this command?",
            summary: "swift test",
            details: "/tmp/live"
        )
        state.apply(.approvalRequested(request))

        await state.resolveApproval(request, approved: true)

        XCTAssertTrue(state.pendingApprovals.isEmpty)
        let resolution = await recorder.lastResolution()
        XCTAssertEqual(resolution?.requestID, "approval-1")
        XCTAssertEqual(resolution?.approved, true)
    }

    @MainActor
    func testApprovalGateIsRemovedForAMainRunLoopTurnBeforeRuntimeResolution() async {
        let task = AgentTask(
            id: "thread-approval-ordering",
            title: "Approval ordering",
            summary: "Waiting",
            status: .running,
            workspace: "/tmp/live",
            model: "Local provider"
        )
        let recorder = ApprovalInvocationRecorder()
        let probe = ApprovalInvocationProbe()
        let runtime = ApprovalObservingRuntime(
            tasks: [task],
            recorder: recorder,
            observation: { requestID in
                probe.observe(requestID: requestID)
            }
        )
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())
        probe.state = state
        await state.startRuntime()
        let request = ActionApprovalRequest(
            id: "approval-ordering-1",
            taskID: task.id,
            kind: .computerUse,
            title: "Control Chrome?",
            summary: "Press the exact button",
            details: "AXPress"
        )
        state.apply(.approvalRequested(request))
        DispatchQueue.main.async {
            probe.queuedMainTurnDidRun = true
        }

        await state.resolveApproval(request, approved: true)

        let invocation = await recorder.lastInvocation()
        XCTAssertEqual(invocation?.requestID, request.id)
        XCTAssertEqual(invocation?.approved, true)
        XCTAssertEqual(invocation?.observation.requestWasPending, false)
        XCTAssertEqual(invocation?.observation.queuedMainTurnDidRun, true)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertTrue(state.resolvingApprovalIDs.isEmpty)
    }

    @MainActor
    func testApprovalResolutionFailureRestoresRequestAndRecordsFailure() async {
        let task = AgentTask(
            id: "thread-approval-error",
            title: "Approval failure",
            summary: "Waiting",
            status: .running,
            workspace: "/tmp/live",
            model: "Local provider"
        )
        let recorder = ApprovalInvocationRecorder()
        let probe = ApprovalInvocationProbe()
        let runtime = ApprovalObservingRuntime(
            tasks: [task],
            recorder: recorder,
            shouldFail: true,
            observation: { requestID in
                probe.observe(requestID: requestID)
            }
        )
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())
        probe.state = state
        await state.startRuntime()
        let request = ActionApprovalRequest(
            id: "approval-error-1",
            taskID: task.id,
            kind: .command,
            title: "Run this command?",
            summary: "swift test",
            details: "/tmp/live"
        )
        state.apply(.approvalRequested(request))

        await state.resolveApproval(request, approved: true)

        let invocation = await recorder.lastInvocation()
        XCTAssertEqual(invocation?.observation.requestWasPending, false)
        XCTAssertEqual(state.pendingApprovals, [request])
        XCTAssertTrue(state.resolvingApprovalIDs.isEmpty)
        XCTAssertEqual(state.tasks[0].entries.last?.title, "Approval could not be resolved")
        XCTAssertEqual(state.tasks[0].entries.last?.body, "The approval response could not be delivered.")
    }

    @MainActor
    func testResolvedApprovalIsNotRestoredWhenRuntimeThenThrows() async {
        let task = AgentTask(
            id: "thread-approval-resolved-before-error",
            title: "Approval",
            summary: "Waiting",
            status: .running,
            workspace: "/tmp/live",
            model: "Local provider"
        )
        let recorder = ApprovalInvocationRecorder()
        let probe = ApprovalInvocationProbe()
        let runtime = ApprovalObservingRuntime(
            tasks: [task],
            recorder: recorder,
            shouldFail: true,
            observation: { requestID in
                probe.state?.apply(.approvalResolved(requestID: requestID))
                return probe.observe(requestID: requestID)
            }
        )
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())
        probe.state = state
        await state.startRuntime()
        let request = ActionApprovalRequest(
            id: "approval-resolved-before-error-1",
            taskID: task.id,
            kind: .computerUse,
            title: "Control Chrome?",
            summary: "Press the exact button",
            details: "AXPress"
        )
        state.apply(.approvalRequested(request))

        await state.resolveApproval(request, approved: true)

        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertTrue(state.resolvingApprovalIDs.isEmpty)
        XCTAssertEqual(state.tasks[0].entries.last?.title, "Approval could not be resolved")
    }

    @MainActor
    func testResolvedOrReplacedApprovalCannotBeSentLate() async {
        let task = AgentTask(
            id: "thread-approval-stale",
            title: "Approval",
            summary: "Waiting",
            status: .running,
            workspace: "/tmp/live",
            model: "Local provider"
        )
        let recorder = ApprovalRecorder()
        let state = AppState(
            tasks: [task],
            runtime: ApprovalRecordingRuntime(tasks: [task], recorder: recorder),
            preferences: isolatedTestPreferences()
        )
        await state.startRuntime()
        let staleRequest = ActionApprovalRequest(
            id: "approval-reused",
            taskID: task.id,
            kind: .command,
            title: "Old command",
            summary: "old",
            details: "/tmp/old"
        )
        let replacement = ActionApprovalRequest(
            id: staleRequest.id,
            taskID: task.id,
            kind: .command,
            title: "New command",
            summary: "new",
            details: "/tmp/new"
        )
        state.apply(.approvalRequested(staleRequest))
        state.apply(.approvalResolved(requestID: staleRequest.id))
        state.apply(.approvalRequested(replacement))

        await state.resolveApproval(staleRequest, approved: true)

        XCTAssertEqual(state.pendingApprovals, [replacement])
        let resolution = await recorder.lastResolution()
        XCTAssertNil(resolution)
    }
}

private final class PermissionClientRecorder: AutomationPermissionClient {
    private var snapshot = AutomationPermissionSnapshot(
        accessibility: .notGranted,
        screenRecording: .notGranted
    )

    private(set) var currentCalls = 0
    private(set) var accessibilityRequestCalls = 0
    private(set) var screenRecordingRequestCalls = 0

    func current() -> AutomationPermissionSnapshot {
        currentCalls += 1
        return snapshot
    }

    func requestAccessibility() -> AutomationPermissionSnapshot {
        accessibilityRequestCalls += 1
        snapshot = AutomationPermissionSnapshot(
            accessibility: .granted,
            screenRecording: snapshot.screenRecording
        )
        return snapshot
    }

    func requestScreenRecording() -> AutomationPermissionSnapshot {
        screenRecordingRequestCalls += 1
        snapshot = AutomationPermissionSnapshot(
            accessibility: snapshot.accessibility,
            screenRecording: .granted
        )
        return snapshot
    }
}

private struct StubRuntime: AgentRuntimeClient {
    let tasks: [AgentTask]
    let providerName = "Stub runtime"

    func loadTasks() async throws -> [AgentTask] {
        tasks
    }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}

    func interrupt(taskID: AgentTask.ID) async throws {}

    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

private actor StartupTaskLoadGate {
    private var loading = false
    private var released = false
    private var loadingWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var submissions = 0

    func holdLoad() async {
        loading = true
        loadingWaiters.forEach { $0.resume() }
        loadingWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilLoading() async {
        guard !loading else { return }
        await withCheckedContinuation { loadingWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func recordSubmission() { submissions += 1 }
}

private struct HeldStartupRuntime: AgentRuntimeClient {
    let tasks: [AgentTask]
    let gate: StartupTaskLoadGate
    let providerName = "Held startup"

    func loadTasks() async throws -> [AgentTask] {
        await gate.holdLoad()
        return tasks
    }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { $0.finish() }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {
        await gate.recordSubmission()
    }

    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

private struct RejectingRuntime: AgentRuntimeClient {
    struct TurnRejected: LocalizedError {
        var errorDescription: String? { "The local model is unavailable." }
    }

    let tasks: [AgentTask]
    var cancelSubmission = false
    let providerName = "Rejecting runtime"

    func loadTasks() async throws -> [AgentTask] { tasks }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {
        if cancelSubmission { throw CancellationError() }
        throw TurnRejected()
    }

    func interrupt(taskID: AgentTask.ID) async throws {}

    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

private actor InterruptionRecorder {
    private var IDs: [AgentTask.ID] = []

    func record(taskID: AgentTask.ID) {
        IDs.append(taskID)
    }

    func recordedTaskIDs() -> [AgentTask.ID] {
        IDs
    }
}

private struct InterruptionRecordingRuntime: AgentRuntimeClient {
    struct StopRejected: LocalizedError {
        var errorDescription: String? { "Stop request was rejected." }
    }

    let recorder: InterruptionRecorder
    var shouldFail = false
    let providerName = "Interruption recording runtime"

    func loadTasks() async throws -> [AgentTask] { [] }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}

    func interrupt(taskID: AgentTask.ID) async throws {
        await recorder.record(taskID: taskID)
        if shouldFail { throw StopRejected() }
    }

    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

private actor ApprovalRecorder {
    private var resolution: (requestID: String, approved: Bool)?

    func record(requestID: String, approved: Bool) {
        resolution = (requestID, approved)
    }

    func lastResolution() -> (requestID: String, approved: Bool)? {
        resolution
    }
}

private struct ApprovalRecordingRuntime: AgentRuntimeClient {
    let tasks: [AgentTask]
    let recorder: ApprovalRecorder
    let providerName = "Approval recording runtime"

    func loadTasks() async throws -> [AgentTask] { tasks }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}

    func interrupt(taskID: AgentTask.ID) async throws {}

    func resolveApproval(requestID: String, approved: Bool) async throws {
        await recorder.record(requestID: requestID, approved: approved)
    }
}

private struct ApprovalInvocationObservation: Equatable, Sendable {
    let requestWasPending: Bool
    let queuedMainTurnDidRun: Bool
}

private struct ApprovalInvocation: Equatable, Sendable {
    let requestID: String
    let approved: Bool
    let observation: ApprovalInvocationObservation
}

private actor ApprovalInvocationRecorder {
    private var invocation: ApprovalInvocation?

    func record(_ newInvocation: ApprovalInvocation) {
        invocation = newInvocation
    }

    func lastInvocation() -> ApprovalInvocation? {
        invocation
    }
}

@MainActor
private final class ApprovalInvocationProbe {
    weak var state: AppState?
    var queuedMainTurnDidRun = false

    func observe(requestID: String) -> ApprovalInvocationObservation {
        ApprovalInvocationObservation(
            requestWasPending: state?.pendingApprovals.contains(where: { $0.id == requestID }) ?? true,
            queuedMainTurnDidRun: queuedMainTurnDidRun
        )
    }
}

private struct ApprovalObservingRuntime: AgentRuntimeClient {
    struct ResolutionRejected: LocalizedError {
        var errorDescription: String? { "The approval response could not be delivered." }
    }

    let tasks: [AgentTask]
    let recorder: ApprovalInvocationRecorder
    let shouldFail: Bool
    let observation: @MainActor @Sendable (String) -> ApprovalInvocationObservation
    let providerName = "Approval observing runtime"

    init(
        tasks: [AgentTask],
        recorder: ApprovalInvocationRecorder,
        shouldFail: Bool = false,
        observation: @escaping @MainActor @Sendable (String) -> ApprovalInvocationObservation
    ) {
        self.tasks = tasks
        self.recorder = recorder
        self.shouldFail = shouldFail
        self.observation = observation
    }

    func loadTasks() async throws -> [AgentTask] { tasks }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}

    func interrupt(taskID: AgentTask.ID) async throws {}

    func resolveApproval(requestID: String, approved: Bool) async throws {
        let observedState = await observation(requestID)
        await recorder.record(
            ApprovalInvocation(
                requestID: requestID,
                approved: approved,
                observation: observedState
            )
        )
        if shouldFail {
            throw ResolutionRejected()
        }
    }
}

private actor ModelSubmissionRecorder {
    private var submission: (taskID: AgentTask.ID, modelID: String)?

    func record(taskID: AgentTask.ID, modelID: String) {
        submission = (taskID, modelID)
    }

    func lastSubmission() -> (taskID: AgentTask.ID, modelID: String)? {
        submission
    }
}

private struct ModelRecordingRuntime: AgentRuntimeClient {
    let recorder: ModelSubmissionRecorder
    let providerName = "Model recording runtime"

    func loadTasks() async throws -> [AgentTask] { [] }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {
        await recorder.record(taskID: taskID, modelID: modelID)
    }

    func interrupt(taskID: AgentTask.ID) async throws {}

    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

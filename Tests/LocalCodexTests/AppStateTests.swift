import AutomationCore
import XCTest
@testable import LocalCodex

final class AppStateTests: XCTestCase {
    func testLocalQwenConfigurationFitsAConstrainedLocalContext() {
        let configuration = CodexAppServerRuntime.Configuration.localQwen

        XCTAssertEqual(configuration.modelProvider, "lmstudio")
        XCTAssertEqual(configuration.model, "mlx-community/Qwen3.8-27B-4bit")
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
        ])

        state.composerText = "  Inspect the workspace  "

        let submitted = await state.submitComposer()

        XCTAssertTrue(submitted)
        XCTAssertEqual(state.selectedTask?.entries.count, 1)
        XCTAssertEqual(state.selectedTask?.entries.first?.body, "Inspect the workspace")
        XCTAssertEqual(state.selectedTask?.status, .waiting)
        XCTAssertTrue(state.composerText.isEmpty)
    }

    @MainActor
    func testWhitespaceOnlyPromptDoesNotAppendEntry() async {
        let state = AppState()
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
        let state = AppState(tasks: [first, second])
        state.selectTask(second.id)

        let submitted = await state.submit(prompt: "For the first task", toTaskID: first.id)

        XCTAssertTrue(submitted)
        XCTAssertEqual(state.tasks.first(where: { $0.id == first.id })?.entries.last?.body, "For the first task")
        XCTAssertTrue(state.tasks.first(where: { $0.id == second.id })?.entries.isEmpty == true)
        XCTAssertEqual(state.selectedTaskID, second.id)
    }

    @MainActor
    func testCreatingTaskSelectsNewDraft() {
        let state = AppState(tasks: [])

        state.createTask()

        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.selectedTask?.status, .draft)
        XCTAssertEqual(state.selectedTask?.model, state.defaultModel)
    }

    @MainActor
    func testPermissionInitializationAndRefreshNeverRequestAccess() {
        let permissions = PermissionClientRecorder()
        let state = AppState(tasks: [], permissionClient: permissions)

        state.refreshAutomationPermissions()

        XCTAssertEqual(permissions.currentCalls, 2)
        XCTAssertEqual(permissions.accessibilityRequestCalls, 0)
        XCTAssertEqual(permissions.screenRecordingRequestCalls, 0)
    }

    @MainActor
    func testExplicitPermissionRequestsStaySeparateAndRefreshState() {
        let permissions = PermissionClientRecorder()
        let state = AppState(tasks: [], permissionClient: permissions)

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
            runtime: StubRuntime(tasks: [liveTask])
        )

        await state.startRuntime()

        XCTAssertEqual(state.tasks.map(\.id), ["thread-live-1"])
        XCTAssertEqual(state.selectedTaskID, "thread-live-1")
        XCTAssertEqual(state.connectionState, .connected(provider: "Stub runtime"))
    }

    @MainActor
    func testRejectedTurnKeepsConnectedTransportAndReturnsTaskToWaiting() async {
        let task = AgentTask(
            id: "thread-live-2",
            title: "Offline model",
            summary: "Before",
            status: .draft,
            workspace: "/tmp/live",
            model: "Local provider"
        )
        let state = AppState(tasks: [task], runtime: RejectingRuntime(tasks: [task]))
        await state.startRuntime()
        state.composerText = "Try the local model"

        let submitted = await state.submitComposer()

        XCTAssertFalse(submitted)
        XCTAssertEqual(state.connectionState, .connected(provider: "Rejecting runtime"))
        XCTAssertEqual(state.selectedTask?.status, .waiting)
        XCTAssertEqual(state.selectedTask?.entries.last?.title, "Prompt was not delivered")
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
            runtime: ApprovalRecordingRuntime(tasks: [task], recorder: recorder)
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
        let state = AppState(tasks: [task], runtime: runtime)
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
        let state = AppState(tasks: [task], runtime: runtime)
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
        let state = AppState(tasks: [task], runtime: runtime)
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
            runtime: ApprovalRecordingRuntime(tasks: [task], recorder: recorder)
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

    func submit(prompt: String, toTaskID taskID: AgentTask.ID) async throws {}

    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

private struct RejectingRuntime: AgentRuntimeClient {
    struct TurnRejected: LocalizedError {
        var errorDescription: String? { "The local model is unavailable." }
    }

    let tasks: [AgentTask]
    let providerName = "Rejecting runtime"

    func loadTasks() async throws -> [AgentTask] { tasks }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID) async throws {
        throw TurnRejected()
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

    func submit(prompt: String, toTaskID taskID: AgentTask.ID) async throws {}

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

    func submit(prompt: String, toTaskID taskID: AgentTask.ID) async throws {}

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

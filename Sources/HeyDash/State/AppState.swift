import AutomationCore
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    @ObservationIgnored private let runtime: (any AgentRuntimeClient)?
    @ObservationIgnored private var runtimeShutdown: Task<RuntimeShutdownReport, Never>?
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private let permissionClient: any AutomationPermissionClient
    @ObservationIgnored private let preferences: UserDefaults
    // Keep the persisted key across the HeyDash rename.
    private static let defaultModelPreferenceKey = "LocalCodex.defaultModelID"
    private static let accessModePreferenceKey = "HeyDash.accessMode"

    var tasks: [AgentTask]
    var selectedTaskID: AgentTask.ID?
    var selectedEntryID: TimelineEntry.ID?
    var composerText = ""
    var isInspectorPresented = false
    var presentedSheet: SheetDestination? {
        didSet {
            if presentedSheet != nil, approvalGateBlocksInteraction {
                presentedSheet = nil
            }
        }
    }

    var appearance: AppAppearance = .system
    var defaultModel: String
    var showToolPayloads = false
    var connectionState: RuntimeConnectionState = .disconnected
    var automationPermissions: AutomationPermissionSnapshot
    var contextUsageByTask: [AgentTask.ID: RuntimeContextUsage] = [:]
    var compactionStateByTask: [AgentTask.ID: RuntimeCompactionState] = [:]
    private(set) var accessMode: AccessMode = .askEveryTime
    var automaticApprovalError: String?
    var pendingApprovals: [ActionApprovalRequest] = [] {
        didSet { dismissSettingsIfApprovalBlocksInteraction() }
    }
    var resolvingApprovalIDs: Set<String> = [] {
        didSet { dismissSettingsIfApprovalBlocksInteraction() }
    }
    var activeTurnTaskIDs: Set<AgentTask.ID> = []
    var interruptingTaskIDs: Set<AgentTask.ID> = []
    var queuedPrompts: [AgentTask.ID: [QueuedPrompt]] = [:]
    var pausedQueueTaskIDs: Set<AgentTask.ID> = []
    var promptReceipts: [PromptReceipt] = []
    @ObservationIgnored private var promptReceiptRevision: UInt64 = 0
    @ObservationIgnored private var acceptedPromptRequests: [String: (taskID: String, digest: Data)] = [:]
    private var dispatchingQueueTaskIDs: Set<AgentTask.ID> = []
    private var steeringTaskIDs: Set<AgentTask.ID> = []
    @ObservationIgnored private var resolvedDuringApprovalAttemptIDs: Set<String> = []
    @ObservationIgnored private var approvalAttemptRequests: [String: ActionApprovalRequest] = [:]
    @ObservationIgnored private var approvalRequestsAwaitingResolvedEvents: [String: [ActionApprovalRequest]] = [:]
    @ObservationIgnored private var latestApprovalRequestsByID: [String: ActionApprovalRequest] = [:]
    @ObservationIgnored private var approvalIDsRequiringManualReview: Set<String> = []
    @ObservationIgnored private var automaticApprovalAttemptedRequests: Set<ActionApprovalRequest> = []
    @ObservationIgnored private var accessModeGeneration: UInt64 = 0

    init(
        tasks: [AgentTask] = SampleData.tasks,
        runtime: (any AgentRuntimeClient)? = nil,
        permissionClient: any AutomationPermissionClient = PermissionInspector(),
        preferences: UserDefaults = .standard
    ) {
        self.runtime = runtime
        self.permissionClient = permissionClient
        self.preferences = preferences
        let storedAccessMode = preferences.object(forKey: Self.accessModePreferenceKey) as? String
        accessMode = storedAccessMode.flatMap(AccessMode.init(rawValue:)) ?? .askEveryTime
        let storedModel = preferences.string(forKey: Self.defaultModelPreferenceKey)
        defaultModel = storedModel.flatMap(LocalModelCatalog.option(for:))?.id
            ?? LocalModelCatalog.defaultModelID
        automationPermissions = permissionClient.current()
        self.tasks = tasks
        selectedTaskID = tasks.first?.id
        selectedEntryID = tasks.first?.entries.last?.id
    }

    var selectedTask: AgentTask? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    var selectedEntry: TimelineEntry? {
        guard let selectedEntryID else { return nil }
        return selectedTask?.entries.first { $0.id == selectedEntryID }
    }

    /// Full access never presents or focuses the native approval card. A failed
    /// automatic delivery stays pending until the user switches back to Ask.
    var presentedApproval: ActionApprovalRequest? {
        guard accessMode == .askEveryTime, resolvingApprovalIDs.isEmpty else { return nil }
        return pendingApprovals.first
    }

    var approvalGateBlocksInteraction: Bool {
        accessMode == .askEveryTime
            && (!pendingApprovals.isEmpty || !resolvingApprovalIDs.isEmpty)
    }

    func selectTask(_ id: AgentTask.ID?) {
        selectedTaskID = id
        selectedEntryID = selectedTask?.entries.last?.id
    }

    /// Remember the native user's choice across launches. Missing or invalid
    /// preferences start in Ask; the web bridge cannot change this preference.
    @discardableResult
    func setAccessMode(_ mode: AccessMode) -> Bool {
        guard !isShuttingDown, accessMode != mode else { return false }
        let approvalWasPresented = presentedApproval != nil
        accessMode = mode
        preferences.set(mode.rawValue, forKey: Self.accessModePreferenceKey)
        accessModeGeneration &+= 1
        automaticApprovalAttemptedRequests.removeAll()
        automaticApprovalError = nil
        dismissSettingsIfApprovalBlocksInteraction()
        if mode == .fullAccess {
            claimPendingAutomaticApprovals(settlePresentedApproval: approvalWasPresented)
        }
        return true
    }

    /// Settings must never cover or disable the native controls for an Ask-mode
    /// approval. Keep this guard in state so native commands and bridge actions
    /// cannot reopen Settings while an approval is pending or settling.
    @discardableResult
    func presentSettings() -> Bool {
        guard !approvalGateBlocksInteraction else {
            presentedSheet = nil
            return false
        }
        presentedSheet = .settings
        return true
    }

    private func dismissSettingsIfApprovalBlocksInteraction() {
        if approvalGateBlocksInteraction {
            presentedSheet = nil
        }
    }

    func createTask() {
        let task = AgentTask(
            title: "Untitled task",
            summary: "A new local task",
            status: .draft,
            workspace: "No workspace selected",
            model: defaultModel
        )
        tasks.insert(task, at: 0)
        selectedTaskID = task.id
        selectedEntryID = nil
        composerText = ""
    }

    @discardableResult
    func setDefaultModel(_ modelID: String) -> Bool {
        guard LocalModelCatalog.option(for: modelID) != nil else { return false }
        defaultModel = modelID
        preferences.set(modelID, forKey: Self.defaultModelPreferenceKey)
        return true
    }

    @discardableResult
    func setTaskModel(_ modelID: String, taskID: AgentTask.ID) -> Bool {
        guard LocalModelCatalog.option(for: modelID) != nil,
              let index = tasks.firstIndex(where: { $0.id == taskID }),
              canChangeModel(for: taskID)
        else { return false }
        tasks[index].model = modelID
        contextUsageByTask.removeValue(forKey: taskID)
        compactionStateByTask.removeValue(forKey: taskID)
        return true
    }

    func canChangeModel(for taskID: AgentTask.ID) -> Bool {
        tasks.contains(where: { $0.id == taskID })
            && !isBusy(taskID: taskID)
            && queuedPrompts[taskID, default: []].isEmpty
    }

    func isBusy(taskID: AgentTask.ID) -> Bool {
        tasks.contains(where: { $0.id == taskID && $0.status == .running })
            || activeTurnTaskIDs.contains(taskID)
            || compactionStateByTask[taskID] == .running
            || pendingApprovals.contains(where: { $0.taskID == nil || $0.taskID == taskID })
            || !resolvingApprovalIDs.isEmpty
            || steeringTaskIDs.contains(taskID)
    }

    func canSteer(taskID: AgentTask.ID) -> Bool {
        runtime != nil && !isShuttingDown
            && tasks.contains(where: { $0.id == taskID && $0.status == .running })
            && activeTurnTaskIDs.contains(taskID)
            && compactionStateByTask[taskID] != .running
            && !interruptingTaskIDs.contains(taskID)
            && !steeringTaskIDs.contains(taskID)
            && !pendingApprovals.contains(where: { $0.taskID == nil || $0.taskID == taskID })
            && resolvingApprovalIDs.isEmpty
    }

    /// Stop is a human UI action for a running task. The App Server owns the
    /// resulting status; keep it running here until its turn event arrives.
    @discardableResult
    func interrupt(taskID: AgentTask.ID) async -> Bool {
        guard let runtime,
              tasks.contains(where: { $0.id == taskID && $0.status == .running }),
              !interruptingTaskIDs.contains(taskID)
        else { return false }

        interruptingTaskIDs.insert(taskID)
        pausedQueueTaskIDs.insert(taskID)
        do {
            try await runtime.interrupt(taskID: taskID)
            return true
        } catch {
            interruptingTaskIDs.remove(taskID)
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return false }
            let failure = TimelineEntry(
                kind: .system,
                title: "Could not stop task",
                body: error.localizedDescription
            )
            tasks[index].entries.append(failure)
            if selectedTaskID == taskID {
                selectedEntryID = failure.id
            }
            return false
        }
    }

    func refreshAutomationPermissions() {
        automationPermissions = permissionClient.current()
    }

    /// This is only called by the native bridge for the matching Settings
    /// button. Model/runtime code has no permission-request action.
    func requestAccessibilityPermission() {
        automationPermissions = permissionClient.requestAccessibility()
    }

    /// This is only called by the native bridge for the matching Settings
    /// button. Model/runtime code has no permission-request action.
    func requestScreenRecordingPermission() {
        automationPermissions = permissionClient.requestScreenRecording()
    }

    @ObservationIgnored private var approvalAttemptTaskIDs: [String: AgentTask.ID] = [:]
    @ObservationIgnored private var invalidatedApprovalAttemptIDs: Set<String> = []

    private enum ApprovalResolutionOrigin {
        case user
        case automatic(generation: UInt64, settlePresentedApproval: Bool)
    }

    private struct ApprovalResolutionAttempt {
        let request: ActionApprovalRequest
        let approved: Bool
        let originalIndex: Int
        let origin: ApprovalResolutionOrigin
    }

    private enum ApprovalClaimResult {
        case claimed(ApprovalResolutionAttempt)
        case rejected(reason: String)
    }

    @discardableResult
    func resolveApproval(
        _ request: ActionApprovalRequest,
        approved: Bool,
        settlePresentation: (@MainActor () async throws -> Void)? = nil
    ) async -> ApprovalResolutionResult {
        switch claimApproval(request, approved: approved, origin: .user) {
        case .rejected(let reason):
            return .init(requestID: request.id, status: .notAttempted, reason: reason)
        case .claimed(let attempt):
            return await deliverApproval(attempt, settlePresentation: settlePresentation)
        }
    }

    private func claimApproval(
        _ request: ActionApprovalRequest,
        approved: Bool,
        origin: ApprovalResolutionOrigin
    ) -> ApprovalClaimResult {
        guard runtime != nil else { return .rejected(reason: "runtime_missing") }
        guard !isShuttingDown else { return .rejected(reason: "runtime_shutting_down") }
        guard !resolvingApprovalIDs.contains(request.id) else {
            return .rejected(reason: "resolution_in_flight")
        }
        guard let approvalIndex = pendingApprovals.firstIndex(of: request) else {
            return .rejected(reason: "exact_request_not_pending")
        }

        resolvingApprovalIDs.insert(request.id)
        approvalAttemptTaskIDs[request.id] = request.taskID
        approvalAttemptRequests[request.id] = request
        latestApprovalRequestsByID[request.id] = request
        invalidatedApprovalAttemptIDs.remove(request.id)
        resolvedDuringApprovalAttemptIDs.remove(request.id)
        pendingApprovals.remove(at: approvalIndex)
        return .claimed(ApprovalResolutionAttempt(
            request: request,
            approved: approved,
            originalIndex: approvalIndex,
            origin: origin
        ))
    }

    private func deliverApproval(
        _ attempt: ApprovalResolutionAttempt,
        settlePresentation: (@MainActor () async throws -> Void)?
    ) async -> ApprovalResolutionResult {
        let request = attempt.request
        defer {
            resolvingApprovalIDs.remove(request.id)
            approvalAttemptTaskIDs.removeValue(forKey: request.id)
            if approvalAttemptRequests[request.id] == request {
                approvalAttemptRequests.removeValue(forKey: request.id)
            }
            invalidatedApprovalAttemptIDs.remove(request.id)
            resolvedDuringApprovalAttemptIDs.remove(request.id)
            for taskID in queuedPrompts.keys { scheduleQueueDrain(taskID: taskID) }
            claimPendingAutomaticApprovals()
        }

        @MainActor func restoreIfStillPending() -> Bool {
            guard !isShuttingDown,
                  !invalidatedApprovalAttemptIDs.contains(request.id),
                  !resolvedDuringApprovalAttemptIDs.contains(request.id),
                  !pendingApprovals.contains(where: { $0.id == request.id }) else { return false }
            pendingApprovals.insert(request, at: min(attempt.originalIndex, pendingApprovals.endIndex))
            return true
        }

        switch attempt.origin {
        case .user:
            // Preserve native approval-overlay teardown before resuming computer
            // input. The injected operation is only a deterministic test seam.
            do {
                if let settlePresentation {
                    try await settlePresentation()
                } else {
                    await nextMainRunLoopTurn()
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
            } catch {
                return .init(
                    requestID: request.id, status: .notAttempted,
                    reason: "presentation_settle_failed: \(error.localizedDescription)",
                    requestRestored: restoreIfStillPending(),
                    resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
                )
            }
        case .automatic(let generation, let settlePresentedApproval):
            guard accessMode == .fullAccess, generation == accessModeGeneration else {
                return .init(
                    requestID: request.id, status: .notAttempted,
                    reason: "access_mode_changed_before_delivery",
                    requestRestored: restoreIfStillPending(),
                    resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
                )
            }
            do {
                if settlePresentedApproval {
                    await nextMainRunLoopTurn()
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
            } catch {
                return .init(
                    requestID: request.id, status: .notAttempted,
                    reason: "automatic_resolution_cancelled_before_delivery",
                    requestRestored: restoreIfStillPending(),
                    resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
                )
            }
        }

        if case .automatic(let generation, _) = attempt.origin,
           !(accessMode == .fullAccess && generation == accessModeGeneration) {
            return .init(
                requestID: request.id, status: .notAttempted,
                reason: "access_mode_changed_before_delivery",
                requestRestored: restoreIfStillPending(),
                resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
            )
        }

        guard !isShuttingDown,
              !invalidatedApprovalAttemptIDs.contains(request.id),
              !resolvedDuringApprovalAttemptIDs.contains(request.id),
              approvalAttemptRequests[request.id] == request,
              !pendingApprovals.contains(where: { $0.id == request.id }) else {
            return .init(
                requestID: request.id, status: .notAttempted,
                reason: "request_invalidated_or_superseded_before_delivery",
                resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
            )
        }

        let dispatchStartedAt = DispatchTime.now().uptimeNanoseconds
        approvalRequestsAwaitingResolvedEvents[request.id, default: []].append(request)
        do {
            guard let runtime else {
                return .init(requestID: request.id, status: .notAttempted, reason: "runtime_missing")
            }
            try await runtime.resolveApproval(requestID: request.id, approved: attempt.approved)
            return .init(
                requestID: request.id, status: .delivered, reason: "runtime_returned_success",
                approved: attempt.approved, dispatchStartedAt: dispatchStartedAt,
                resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
            )
        } catch {
            let eventObserved = resolvedDuringApprovalAttemptIDs.contains(request.id)
            if case .automatic = attempt.origin {
                // Once an automatic delivery reaches the runtime and fails, its
                // outcome is uncertain. A later mode-generation change must not
                // turn restoration into another automatic approved=true attempt.
                automaticApprovalAttemptedRequests.insert(request)
                approvalIDsRequiringManualReview.insert(request.id)
            }
            let restored = restoreIfStillPending()
            if let taskID = request.taskID,
               let index = tasks.firstIndex(where: { $0.id == taskID }) {
                let failure = TimelineEntry(
                    kind: .system,
                    title: "Approval could not be resolved",
                    body: error.localizedDescription
                )
                tasks[index].entries.append(failure)
                selectedEntryID = failure.id
            }
            if case .automatic = attempt.origin,
               accessMode == .fullAccess,
               !isShuttingDown,
               restored {
                automaticApprovalError = "Full access could not approve “\(request.title)”. Switch to Ask every time to review and retry."
            }
            // In particular, approvalResolved followed by an error is NOT proof
            // that this caller's approved=true/false decision was delivered.
            return .init(
                requestID: request.id, status: .failed, reason: error.localizedDescription,
                dispatchStartedAt: dispatchStartedAt, requestRestored: restored,
                resolvedEventObserved: eventObserved
            )
        }
    }

    /// Claims every eligible request synchronously so Full access never flashes or
    /// focuses the native approval UI. Failures and reused IDs remain pending for
    /// explicit human review, without an automatic retry loop.
    private func claimPendingAutomaticApprovals(settlePresentedApproval: Bool = false) {
        guard accessMode == .fullAccess, !isShuttingDown else { return }
        let generation = accessModeGeneration
        for request in pendingApprovals where !automaticApprovalAttemptedRequests.contains(request) {
            automaticApprovalAttemptedRequests.insert(request)

            if approvalIDsRequiringManualReview.contains(request.id) {
                automaticApprovalError = "Full access did not retry an approval whose prior response is ambiguous. Switch to Ask every time to review it."
                continue
            }

            if approvalRequestsAwaitingResolvedEvents[request.id]?.isEmpty == false {
                approvalIDsRequiringManualReview.insert(request.id)
                automaticApprovalError = "Full access did not approve a request whose approval ID still has an unresolved prior response. Switch to Ask every time to review it."
                continue
            }

            if let inFlight = approvalAttemptRequests[request.id] {
                if inFlight != request {
                    approvalIDsRequiringManualReview.insert(request.id)
                    automaticApprovalError = "Full access did not approve a replacement request that reused an in-flight approval ID. Switch to Ask every time to review it."
                }
                continue
            }

            switch claimApproval(
                request,
                approved: true,
                origin: .automatic(
                    generation: generation,
                    settlePresentedApproval: settlePresentedApproval
                )
            ) {
            case .rejected(let reason):
                automaticApprovalError = "Full access could not claim “\(request.title)” (\(reason)). Switch to Ask every time to review it."
            case .claimed(let attempt):
                Task { @MainActor [weak self] in
                    _ = await self?.deliverApproval(attempt, settlePresentation: nil)
                }
            }
        }
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// Starts listening to the injected runtime. With no runtime installed the
    /// sample store remains fully local and this method is a no-op.
    func startRuntime() async {
        guard !isShuttingDown, let runtime else { return }
        connectionState = .connecting

        do {
            let snapshot = try await runtime.loadTasks()
            guard !isShuttingDown else { return }
            replaceTasks(with: snapshot)
            connectionState = .connected(provider: runtime.providerName)

            for await event in runtime.events() {
                guard !Task.isCancelled, !isShuttingDown else { return }
                apply(event)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isShuttingDown else { return }
            apply(.connectionChanged(.failed(message: error.localizedDescription)))
        }
    }

    func shutdownRuntime() async -> RuntimeShutdownReport {
        if let runtimeShutdown { return await runtimeShutdown.value }
        isShuttingDown = true
        invalidatedApprovalAttemptIDs.formUnion(resolvingApprovalIDs)
        pendingApprovals.removeAll()
        automaticApprovalAttemptedRequests.removeAll()
        latestApprovalRequestsByID.removeAll()
        approvalIDsRequiringManualReview.removeAll()
        approvalRequestsAwaitingResolvedEvents.removeAll()
        pausedQueueTaskIDs.formUnion(queuedPrompts.keys)
        let runtime = self.runtime
        let task = Task {
            await runtime?.shutdown() ?? RuntimeShutdownReport(issues: [])
        }
        runtimeShutdown = task
        let report = await task.value
        pendingApprovals.removeAll()
        resolvingApprovalIDs.removeAll()
        approvalAttemptTaskIDs.removeAll()
        approvalAttemptRequests.removeAll()
        approvalRequestsAwaitingResolvedEvents.removeAll()
        latestApprovalRequestsByID.removeAll()
        approvalIDsRequiringManualReview.removeAll()
        automaticApprovalAttemptedRequests.removeAll()
        automaticApprovalError = nil
        activeTurnTaskIDs.removeAll()
        interruptingTaskIDs.removeAll()
        contextUsageByTask.removeAll()
        compactionStateByTask.removeAll()
        connectionState = .disconnected
        return report
    }

    func replaceTasks(with newTasks: [AgentTask]) {
        let priorSelection = selectedTaskID
        tasks = newTasks
        selectedTaskID = newTasks.contains(where: { $0.id == priorSelection })
            ? priorSelection
            : newTasks.first?.id
        selectedEntryID = selectedTask?.entries.last?.id
        interruptingTaskIDs.formIntersection(
            Set(newTasks.filter { $0.status == .running }.map(\.id))
        )
        let liveTaskIDs = Set(newTasks.map(\.id))
        contextUsageByTask = contextUsageByTask.filter { liveTaskIDs.contains($0.key) }
        compactionStateByTask = compactionStateByTask.filter { liveTaskIDs.contains($0.key) }
    }

    func apply(_ event: AgentRuntimeEvent) {
        switch event {
        case .tasksSnapshot(let snapshot):
            replaceTasks(with: snapshot)

        case .taskUpserted(let task):
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            } else {
                tasks.insert(task, at: 0)
            }

        case .timelineEntryAppended(let taskID, let entry):
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[index].entries.append(entry)
            tasks[index].updatedAt = entry.timestamp
            if selectedTaskID == taskID {
                selectedEntryID = entry.id
            }

        case .taskStatusChanged(let taskID, let status):
            if status == .running,
               case .failed? = compactionStateByTask[taskID] {
                compactionStateByTask.removeValue(forKey: taskID)
            }
            if status != .running {
                for (requestID, owner) in approvalAttemptTaskIDs where owner == taskID {
                    invalidatedApprovalAttemptIDs.insert(requestID)
                }
            }
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[index].status = status
            tasks[index].updatedAt = .now
            if status != .running {
                activeTurnTaskIDs.remove(taskID)
                interruptingTaskIDs.remove(taskID)
                pendingApprovals.removeAll { $0.taskID == taskID }
                automaticApprovalAttemptedRequests = automaticApprovalAttemptedRequests.filter {
                    $0.taskID != taskID
                }
                if status == .completed {
                    scheduleQueueDrain(taskID: taskID)
                } else if !queuedPrompts[taskID, default: []].isEmpty {
                    pausedQueueTaskIDs.insert(taskID)
                }
            }

        case .contextUsageUpdated(let taskID, let usage):
            guard tasks.contains(where: { $0.id == taskID }) else { return }
            if let usage {
                contextUsageByTask[taskID] = usage
            } else {
                contextUsageByTask.removeValue(forKey: taskID)
            }

        case .contextCompactionChanged(let taskID, let state):
            guard tasks.contains(where: { $0.id == taskID }) else { return }
            compactionStateByTask[taskID] = state
            if case .failed = state {
                pausedQueueTaskIDs.insert(taskID)
            }

        case .approvalRequested(let request):
            if let latest = latestApprovalRequestsByID[request.id] {
                let isCurrentDuplicate = latest == request
                    && (pendingApprovals.contains(request)
                        || approvalAttemptRequests[request.id] == request
                        || approvalRequestsAwaitingResolvedEvents[request.id]?.contains(request) == true)
                guard !isCurrentDuplicate else { return }

                latestApprovalRequestsByID[request.id] = request
                approvalIDsRequiringManualReview.insert(request.id)
                if let index = pendingApprovals.firstIndex(where: { $0.id == request.id }) {
                    pendingApprovals[index] = request
                } else {
                    pendingApprovals.append(request)
                }
                if accessMode == .fullAccess {
                    // A reused ID cannot prove that resolving the ID would approve
                    // the payload we inspected. Require an explicit mode change and
                    // human review instead of silently approving the replacement.
                    automaticApprovalAttemptedRequests.insert(request)
                    automaticApprovalError = "Full access did not approve a request that reused an approval ID. Switch to Ask every time to review it."
                }
                return
            }

            latestApprovalRequestsByID[request.id] = request
            guard !pendingApprovals.contains(where: { $0.id == request.id }) else { return }
            pendingApprovals.append(request)
            claimPendingAutomaticApprovals()

        case .approvalResolved(let requestID):
            let eventRequest: ActionApprovalRequest?
            if var waiting = approvalRequestsAwaitingResolvedEvents[requestID], !waiting.isEmpty {
                eventRequest = waiting.removeFirst()
                if waiting.isEmpty {
                    approvalRequestsAwaitingResolvedEvents.removeValue(forKey: requestID)
                } else {
                    approvalRequestsAwaitingResolvedEvents[requestID] = waiting
                }
            } else {
                eventRequest = approvalAttemptRequests[requestID]
            }

            if let eventRequest {
                pendingApprovals.removeAll { $0 == eventRequest }
                automaticApprovalAttemptedRequests.remove(eventRequest)
            } else {
                pendingApprovals.removeAll { $0.id == requestID }
                automaticApprovalAttemptedRequests = automaticApprovalAttemptedRequests.filter {
                    $0.id != requestID
                }
            }
            if resolvingApprovalIDs.contains(requestID),
               eventRequest == approvalAttemptRequests[requestID] {
                resolvedDuringApprovalAttemptIDs.insert(requestID)
            }

        case .connectionChanged(let state):
            connectionState = state
            if case .failed = state {
                invalidateApprovalsForDisconnectedRuntime()
                invalidateContextForDisconnectedRuntime()
                activeTurnTaskIDs.removeAll()
                interruptingTaskIDs.removeAll()
                pausedQueueTaskIDs.formUnion(queuedPrompts.keys)
                markDisconnectedTurnsWaiting()
            } else if case .disconnected = state {
                invalidateApprovalsForDisconnectedRuntime()
                invalidateContextForDisconnectedRuntime()
                pausedQueueTaskIDs.formUnion(queuedPrompts.keys)
                activeTurnTaskIDs.removeAll()
                interruptingTaskIDs.removeAll()
                markDisconnectedTurnsWaiting()
            }
        }
    }

    @discardableResult
    func submitComposer() async -> Bool {
        let original = composerText
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let selectedTaskID else {
            return false
        }
        let accepted = await submitOrQueue(prompt: prompt, toTaskID: selectedTaskID)
        if accepted && composerText == original { composerText = "" }
        return accepted
    }

    /// Submits immutable prompt and task values captured at the UI boundary.
    /// This prevents selection or composer changes from retargeting a queued turn.
    @discardableResult
    func submit(prompt rawPrompt: String, toTaskID taskID: AgentTask.ID) async -> Bool {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              !isShuttingDown,
              let index = tasks.firstIndex(where: { $0.id == taskID }),
              !isBusy(taskID: taskID)
        else {
            return false
        }

        let entry = TimelineEntry(
            kind: .user,
            title: "You",
            body: prompt
        )
        tasks[index].entries.append(entry)
        tasks[index].summary = prompt
        tasks[index].status = .waiting
        tasks[index].updatedAt = .now
        if selectedTaskID == taskID {
            selectedEntryID = entry.id
        }

        if let runtime {
            let modelID = tasks[index].model
            activeTurnTaskIDs.insert(taskID)
            do {
                try await runtime.submit(prompt: prompt, toTaskID: taskID, modelID: modelID)
            } catch {
                activeTurnTaskIDs.remove(taskID)
                if case .connected = connectionState {
                    // A rejected turn (for example, a missing local model) does
                    // not mean the App Server transport itself disconnected.
                } else {
                    apply(.connectionChanged(.failed(message: error.localizedDescription)))
                }
                guard let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
                    return false
                }
                tasks[currentIndex].status = .waiting
                let failure = TimelineEntry(
                    kind: .system,
                    title: "Prompt was not delivered",
                    body: error.localizedDescription
                )
                tasks[currentIndex].entries.append(failure)
                if selectedTaskID == taskID {
                    selectedEntryID = failure.id
                }
                return false
            }
        }

        return true
    }

    /// Accept once into native state, before any asynchronous transport work.
    /// The task ID is captured by the composer; selection never retargets it.
    @discardableResult
    func submitOrQueue(prompt rawPrompt: String, toTaskID taskID: AgentTask.ID) async -> Bool {
        guard enqueuePrompt(prompt: rawPrompt, taskID: taskID) else { return false }
        await drainQueue(taskID: taskID)
        return true
    }

    /// The web composer waits for this receipt before clearing its draft. A
    /// retransmitted request ID can acknowledge the same prompt, never send twice.
    @discardableResult
    func acceptPrompt(prompt: String, taskID: String, requestID: String) -> Bool {
        guard !requestID.isEmpty, requestID.utf8.count <= 128 else { return false }
        let digest = Data(SHA256.hash(data: Data(prompt.utf8)))
        let accepted: Bool
        if let prior = acceptedPromptRequests[requestID] {
            accepted = prior.taskID == taskID && prior.digest == digest
        } else {
            accepted = enqueuePrompt(prompt: prompt, taskID: taskID)
            if accepted { acceptedPromptRequests[requestID] = (taskID, digest) }
        }
        promptReceipts.removeAll { $0.id == requestID }
        promptReceiptRevision &+= 1
        promptReceipts.append(PromptReceipt(id: requestID, taskID: taskID, accepted: accepted, revision: promptReceiptRevision))
        if promptReceipts.count > 64 { promptReceipts.removeFirst(promptReceipts.count - 64) }
        if accepted { scheduleQueueDrain(taskID: taskID) }
        return accepted
    }

    private func enqueuePrompt(prompt rawPrompt: String, taskID: String) -> Bool {
        guard let prompt = validatedPrompt(rawPrompt), !isShuttingDown,
              tasks.contains(where: { $0.id == taskID }) else { return false }
        if queuedPrompts[taskID, default: []].isEmpty && !isBusy(taskID: taskID) {
            pausedQueueTaskIDs.remove(taskID)
        }
        queuedPrompts[taskID, default: []].append(QueuedPrompt(text: prompt))
        return true
    }

    private func markDisconnectedTurnsWaiting() {
        for index in tasks.indices where tasks[index].status == .running {
            tasks[index].status = .waiting
        }
    }

    private func invalidateApprovalsForDisconnectedRuntime() {
        invalidatedApprovalAttemptIDs.formUnion(resolvingApprovalIDs)
        pendingApprovals.removeAll()
        latestApprovalRequestsByID.removeAll()
        approvalIDsRequiringManualReview.removeAll()
        automaticApprovalAttemptedRequests.removeAll()
        automaticApprovalError = nil
    }

    private func invalidateContextForDisconnectedRuntime() {
        contextUsageByTask.removeAll()
        let interruptedTaskIDs = compactionStateByTask.compactMap { taskID, state in
            state == .running ? taskID : nil
        }
        for taskID in interruptedTaskIDs {
            compactionStateByTask[taskID] = .failed(
                message: "The runtime disconnected before context compaction was confirmed."
            )
        }
    }

    @discardableResult
    func beginQueueEdit(taskID: String, id: String) -> Bool {
        guard let index = editableQueueIndex(taskID: taskID, id: id) else { return false }
        queuedPrompts[taskID]?[index].status = .editing
        return true
    }

    @discardableResult
    func editQueuedPrompt(taskID: String, id: String, prompt: String) -> Bool {
        guard let text = validatedPrompt(prompt),
              let index = editableQueueIndex(taskID: taskID, id: id) else { return false }
        queuedPrompts[taskID]?[index].text = text
        queuedPrompts[taskID]?[index].status = .queued
        queuedPrompts[taskID]?[index].error = nil
        scheduleQueueDrain(taskID: taskID)
        return true
    }

    @discardableResult
    func cancelQueueEdit(taskID: String, id: String) -> Bool {
        guard let index = editableQueueIndex(taskID: taskID, id: id),
              queuedPrompts[taskID]?[index].status == .editing else { return false }
        let restoredStatus: QueuedPrompt.Status = queuedPrompts[taskID]?[index].error == nil ? .queued : .failed
        queuedPrompts[taskID]?[index].status = restoredStatus
        scheduleQueueDrain(taskID: taskID)
        return true
    }

    @discardableResult
    func deleteQueuedPrompt(taskID: String, id: String) -> Bool {
        guard let index = editableQueueIndex(taskID: taskID, id: id) else { return false }
        queuedPrompts[taskID]?.remove(at: index)
        scheduleQueueDrain(taskID: taskID)
        return true
    }

    @discardableResult
    func moveQueuedPrompt(taskID: String, id: String, beforeID: String?) -> Bool {
        guard let index = editableQueueIndex(taskID: taskID, id: id), id != beforeID,
              var items = queuedPrompts[taskID] else { return false }
        if let beforeID {
            guard items.contains(where: { $0.id == beforeID && $0.status != .sending }) else { return false }
        }
        let item = items.remove(at: index)
        let destination = beforeID.flatMap { target in items.firstIndex { $0.id == target } } ?? items.endIndex
        items.insert(item, at: destination)
        queuedPrompts[taskID] = items
        scheduleQueueDrain(taskID: taskID)
        return true
    }

    @discardableResult
    func resumeQueue(taskID: String) async -> Bool {
        guard !isShuttingDown, tasks.contains(where: { $0.id == taskID }),
              !dispatchingQueueTaskIDs.contains(taskID), !steeringTaskIDs.contains(taskID)
        else { return false }
        pausedQueueTaskIDs.remove(taskID)
        for index in queuedPrompts[taskID, default: []].indices
            where queuedPrompts[taskID]?[index].status == .failed {
            queuedPrompts[taskID]?[index].status = .queued
            queuedPrompts[taskID]?[index].error = nil
        }
        await drainQueue(taskID: taskID)
        return true
    }

    @discardableResult
    func steerQueuedPrompt(taskID: String, id: String) async -> Bool {
        guard let submission = claimSteer(taskID: taskID, id: id) else { return false }
        return await deliverSteer(submission)
    }

    /// Reserve synchronously when the bridge receives the human's action. A
    /// completion cannot dispatch this prompt as a new turn before steering runs.
    @discardableResult
    func requestSteerQueuedPrompt(taskID: String, id: String) -> Bool {
        guard let submission = claimSteer(taskID: taskID, id: id) else { return false }
        Task { @MainActor [weak self] in await self?.deliverSteer(submission) }
        return true
    }

    private struct SteerSubmission {
        let taskID: String
        let item: QueuedPrompt
        let transcriptPosition: Int
        let submittedAt: Date
    }

    private func claimSteer(taskID: String, id: String) -> SteerSubmission? {
        guard canSteer(taskID: taskID),
              let index = editableQueueIndex(taskID: taskID, id: id),
              let item = queuedPrompts[taskID]?[index], item.status == .queued else { return nil }
        steeringTaskIDs.insert(taskID)
        queuedPrompts[taskID]?[index].status = .sending
        return SteerSubmission(taskID: taskID, item: item,
            transcriptPosition: tasks.first(where: { $0.id == taskID })?.entries.count ?? 0,
            submittedAt: .now)
    }

    private func deliverSteer(_ submission: SteerSubmission) async -> Bool {
        let taskID = submission.taskID
        let item = submission.item
        let id = item.id
        defer { steeringTaskIDs.remove(taskID) }
        guard let runtime, !isShuttingDown else {
            failQueuedPrompt(taskID: taskID, id: id, message: "Steering was cancelled before delivery.")
            return false
        }
        do {
            try await runtime.steer(prompt: item.text, toTaskID: taskID)
            queuedPrompts[taskID]?.removeAll { $0.id == id }
            if let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) {
                let entry = TimelineEntry(kind: .user, title: "You", body: item.text, timestamp: submission.submittedAt)
                tasks[taskIndex].entries.insert(entry, at: min(submission.transcriptPosition, tasks[taskIndex].entries.count))
                tasks[taskIndex].updatedAt = .now
                if selectedTaskID == taskID { selectedEntryID = entry.id }
            }
            // A completion can arrive while the steering acknowledgement is in
            // flight. Resume the queue only after acceptance has been resolved.
            if tasks.first(where: { $0.id == taskID })?.status == .completed {
                scheduleQueueDrain(taskID: taskID)
            }
            return true
        } catch {
            failQueuedPrompt(taskID: taskID, id: id, message: "Steering was not confirmed. Review the conversation before resending. \(error.localizedDescription)")
            return false
        }
    }

    private func validatedPrompt(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf8.count <= 200_000 ? text : nil
    }

    private func editableQueueIndex(taskID: String, id: String) -> Int? {
        guard !isShuttingDown, tasks.contains(where: { $0.id == taskID }) else { return nil }
        return queuedPrompts[taskID]?.firstIndex { $0.id == id && $0.status != .sending }
    }

    private func scheduleQueueDrain(taskID: String) {
        Task { @MainActor [weak self] in await self?.drainQueue(taskID: taskID) }
    }

    private func drainQueue(taskID: String) async {
        guard !isShuttingDown, !isBusy(taskID: taskID),
              !dispatchingQueueTaskIDs.contains(taskID),
              !pausedQueueTaskIDs.contains(taskID),
              let item = queuedPrompts[taskID]?.first, item.status == .queued else { return }
        dispatchingQueueTaskIDs.insert(taskID)
        queuedPrompts[taskID]?[0].status = .sending
        let delivered = await submit(prompt: item.text, toTaskID: taskID)
        if delivered {
            queuedPrompts[taskID]?.removeAll { $0.id == item.id }
        } else {
            failQueuedPrompt(taskID: taskID, id: item.id, message: "Delivery was not confirmed. Review the conversation before resending.")
        }
        dispatchingQueueTaskIDs.remove(taskID)
        if delivered, tasks.first(where: { $0.id == taskID })?.status == .completed {
            scheduleQueueDrain(taskID: taskID)
        }
    }

    private func failQueuedPrompt(taskID: String, id: String, message: String) {
        if let index = queuedPrompts[taskID]?.firstIndex(where: { $0.id == id }) {
            queuedPrompts[taskID]?[index].status = .failed
            queuedPrompts[taskID]?[index].error = message
        }
        pausedQueueTaskIDs.insert(taskID)
    }
}

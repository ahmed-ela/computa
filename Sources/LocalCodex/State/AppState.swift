import AutomationCore
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    @ObservationIgnored private let runtime: (any AgentRuntimeClient)?
    @ObservationIgnored private let permissionClient: any AutomationPermissionClient
    @ObservationIgnored private let preferences: UserDefaults
    private static let defaultModelPreferenceKey = "LocalCodex.defaultModelID"

    var tasks: [AgentTask]
    var selectedTaskID: AgentTask.ID?
    var selectedEntryID: TimelineEntry.ID?
    var composerText = ""
    var isInspectorPresented = true
    var presentedSheet: SheetDestination?

    var appearance: AppAppearance = .system
    var defaultModel: String
    var showToolPayloads = true
    var connectionState: RuntimeConnectionState = .disconnected
    var automationPermissions: AutomationPermissionSnapshot
    var pendingApprovals: [ActionApprovalRequest] = []
    var resolvingApprovalIDs: Set<String> = []
    var activeTurnTaskIDs: Set<AgentTask.ID> = []
    var interruptingTaskIDs: Set<AgentTask.ID> = []
    @ObservationIgnored private var resolvedDuringApprovalAttemptIDs: Set<String> = []

    init(
        tasks: [AgentTask] = SampleData.tasks,
        runtime: (any AgentRuntimeClient)? = nil,
        permissionClient: any AutomationPermissionClient = PermissionInspector(),
        preferences: UserDefaults = .standard
    ) {
        self.runtime = runtime
        self.permissionClient = permissionClient
        self.preferences = preferences
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

    func selectTask(_ id: AgentTask.ID?) {
        selectedTaskID = id
        selectedEntryID = selectedTask?.entries.last?.id
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
        return true
    }

    func canChangeModel(for taskID: AgentTask.ID) -> Bool {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return false }
        return task.status != .running
            && !activeTurnTaskIDs.contains(taskID)
            && !pendingApprovals.contains(where: { $0.taskID == taskID })
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

    func resolveApproval(_ request: ActionApprovalRequest, approved: Bool) async {
        guard let runtime,
              let approvalIndex = pendingApprovals.firstIndex(of: request),
              !resolvingApprovalIDs.contains(request.id)
        else {
            return
        }
        resolvingApprovalIDs.insert(request.id)
        defer {
            resolvingApprovalIDs.remove(request.id)
            resolvedDuringApprovalAttemptIDs.remove(request.id)
        }

        // Remove the exact request before resuming the runtime. Computer-use
        // continuations may immediately activate another app, so the native
        // approval gate must no longer be present when that happens.
        pendingApprovals.remove(at: approvalIndex)
        await nextMainRunLoopTurn()
        // SwiftUI commits the removal asynchronously after observing the state
        // change. Leave a small bounded interval for the native button event,
        // view teardown, and AppKit activation bookkeeping to finish before a
        // computer-use continuation can transfer focus to another process.
        try? await Task.sleep(for: .milliseconds(100))

        do {
            try await runtime.resolveApproval(requestID: request.id, approved: approved)
        } catch {
            // A transport failure leaves the decision unresolved. Restore the
            // request for retry unless a newer request with the same ID arrived
            // while the runtime call was in flight.
            if !resolvedDuringApprovalAttemptIDs.contains(request.id),
               !pendingApprovals.contains(where: { $0.id == request.id }) {
                pendingApprovals.insert(request, at: min(approvalIndex, pendingApprovals.endIndex))
            }
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
        guard let runtime else { return }
        connectionState = .connecting

        do {
            let snapshot = try await runtime.loadTasks()
            replaceTasks(with: snapshot)
            connectionState = .connected(provider: runtime.providerName)

            for await event in runtime.events() {
                guard !Task.isCancelled else { return }
                apply(event)
            }
        } catch is CancellationError {
            return
        } catch {
            connectionState = .failed(message: error.localizedDescription)
        }
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
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[index].status = status
            tasks[index].updatedAt = .now
            if status != .running {
                activeTurnTaskIDs.remove(taskID)
                interruptingTaskIDs.remove(taskID)
                pendingApprovals.removeAll { $0.taskID == taskID }
            }

        case .approvalRequested(let request):
            guard !pendingApprovals.contains(where: { $0.id == request.id }) else { return }
            pendingApprovals.append(request)

        case .approvalResolved(let requestID):
            pendingApprovals.removeAll { $0.id == requestID }
            if resolvingApprovalIDs.contains(requestID) {
                resolvedDuringApprovalAttemptIDs.insert(requestID)
            }

        case .connectionChanged(let state):
            connectionState = state
            if case .failed = state {
                activeTurnTaskIDs.removeAll()
                interruptingTaskIDs.removeAll()
            }
        }
    }

    @discardableResult
    func submitComposer() async -> Bool {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let selectedTaskID, canChangeModel(for: selectedTaskID) else {
            return false
        }
        composerText = ""
        return await submit(prompt: prompt, toTaskID: selectedTaskID)
    }

    /// Submits immutable prompt and task values captured at the UI boundary.
    /// This prevents selection or composer changes from retargeting a queued turn.
    @discardableResult
    func submit(prompt rawPrompt: String, toTaskID taskID: AgentTask.ID) async -> Bool {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              let index = tasks.firstIndex(where: { $0.id == taskID }),
              canChangeModel(for: taskID)
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
                    connectionState = .failed(message: error.localizedDescription)
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
}

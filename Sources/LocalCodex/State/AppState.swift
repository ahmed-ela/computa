import AutomationCore
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    @ObservationIgnored private let runtime: (any AgentRuntimeClient)?

    var tasks: [AgentTask]
    var selectedTaskID: AgentTask.ID?
    var selectedEntryID: TimelineEntry.ID?
    var composerText = ""
    var isInspectorPresented = true
    var presentedSheet: SheetDestination?

    var appearance: AppAppearance = .system
    var defaultModel = "Qwen3.8-27B 4-bit"
    var showToolPayloads = true
    var connectionState: RuntimeConnectionState = .disconnected
    var automationPermissions = PermissionInspector().current()
    var pendingApprovals: [ActionApprovalRequest] = []
    var resolvingApprovalIDs: Set<String> = []

    init(
        tasks: [AgentTask] = SampleData.tasks,
        runtime: (any AgentRuntimeClient)? = nil
    ) {
        self.runtime = runtime
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

    func refreshAutomationPermissions() {
        automationPermissions = PermissionInspector().current()
    }

    func resolveApproval(_ request: ActionApprovalRequest, approved: Bool) async {
        guard let runtime,
              pendingApprovals.contains(request),
              !resolvingApprovalIDs.contains(request.id)
        else {
            return
        }
        resolvingApprovalIDs.insert(request.id)
        defer { resolvingApprovalIDs.remove(request.id) }

        do {
            try await runtime.resolveApproval(requestID: request.id, approved: approved)
            pendingApprovals.removeAll { $0.id == request.id }
        } catch {
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

        case .approvalRequested(let request):
            guard !pendingApprovals.contains(where: { $0.id == request.id }) else { return }
            pendingApprovals.append(request)

        case .approvalResolved(let requestID):
            pendingApprovals.removeAll { $0.id == requestID }

        case .connectionChanged(let state):
            connectionState = state
        }
    }

    @discardableResult
    func submitComposer() async -> Bool {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let selectedTaskID else {
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
              let index = tasks.firstIndex(where: { $0.id == taskID })
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
            do {
                try await runtime.submit(prompt: prompt, toTaskID: taskID)
            } catch {
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

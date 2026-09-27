import AutomationCore
import Foundation

struct WebUISnapshot: Codable, Equatable, Sendable {
    var revision: UInt64 = 0
    let selectedTaskID: String?
    let selectedEntryID: String?
    let tasks: [WebTaskSnapshot]
    let pendingApprovalCount: Int
    let connection: WebConnectionSnapshot
    let permissions: WebPermissionSnapshot
    let appearance: String
    let accessMode: String
    let defaultModel: String
    let modelOptions: [LocalModelOption]
    let showToolPayloads: Bool
    let isInspectorPresented: Bool
    let isSettingsPresented: Bool
    let promptReceipts: [PromptReceipt]

    @MainActor
    init(state: AppState) {
        selectedTaskID = state.selectedTaskID
        selectedEntryID = state.selectedEntryID
        tasks = state.tasks.map { task in
            WebTaskSnapshot(
                task,
                includeEntries: task.id == state.selectedTaskID,
                includeToolPayloads: state.showToolPayloads,
                modelSelectable: state.canChangeModel(for: task.id),
                queuedPrompts: task.id == state.selectedTaskID ? state.queuedPrompts[task.id, default: []] : [],
                queuePaused: state.pausedQueueTaskIDs.contains(task.id),
                canSteer: state.canSteer(taskID: task.id),
                isBusy: state.isBusy(taskID: task.id),
                activeTurnStartedAt: state.activeTurnStartedAt(for: task.id),
                activeActivityGroupID: state.activeActivityGroupID(for: task.id)
            )
        }
        pendingApprovalCount = state.approvalGateBlocksInteraction
            ? Set(state.pendingApprovals.map(\.id)).union(state.resolvingApprovalIDs).count
            : 0
        connection = WebConnectionSnapshot(state.connectionState)
        permissions = WebPermissionSnapshot(state.automationPermissions)
        appearance = state.appearance.rawValue
        accessMode = state.accessMode.rawValue
        defaultModel = state.defaultModel
        modelOptions = LocalModelCatalog.options
        showToolPayloads = state.showToolPayloads
        isInspectorPresented = state.isInspectorPresented
        isSettingsPresented = state.presentedSheet == .settings
        promptReceipts = state.promptReceipts
    }
}

struct WebTaskSnapshot: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let summary: String
    let status: String
    let statusTone: String
    let updatedAt: TimeInterval
    let workspace: String
    let model: String
    let modelSelectable: Bool
    let queuedPrompts: [QueuedPrompt]
    let queuePaused: Bool
    let canSteer: Bool
    let isBusy: Bool
    let activeTurnStartedAt: TimeInterval?
    let activeActivityGroupID: String?
    let branch: String?
    let entries: [WebEntrySnapshot]

    init(
        _ task: AgentTask,
        includeEntries: Bool = true,
        includeToolPayloads: Bool = true,
        modelSelectable: Bool = true,
        queuedPrompts: [QueuedPrompt] = [],
        queuePaused: Bool = false,
        canSteer: Bool = false,
        isBusy: Bool = false,
        activeTurnStartedAt: TimeInterval? = nil,
        activeActivityGroupID: String? = nil
    ) {
        id = task.id
        title = task.title
        summary = task.summary
        status = task.status.label
        statusTone = task.status.webTone
        updatedAt = task.updatedAt.timeIntervalSince1970
        workspace = task.workspace
        model = task.model
        self.modelSelectable = modelSelectable
        self.queuedPrompts = queuedPrompts
        self.queuePaused = queuePaused
        self.canSteer = canSteer
        self.isBusy = isBusy
        self.activeTurnStartedAt = activeTurnStartedAt
        self.activeActivityGroupID = activeActivityGroupID
        branch = task.branch
        entries = includeEntries
            ? task.entries.map { WebEntrySnapshot($0, includeToolPayload: includeToolPayloads) }
            : []
    }
}

struct WebEntrySnapshot: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let title: String
    let body: String
    let timestamp: TimeInterval
    let workedForSeconds: TimeInterval?
    let isStreaming: Bool
    let activityGroupID: String?
    let assistantPhase: String?
    let tool: WebToolSnapshot?

    init(_ entry: TimelineEntry, includeToolPayload: Bool = true) {
        id = entry.id
        kind = entry.kind.rawValue
        title = entry.title
        body = entry.body
        timestamp = entry.timestamp.timeIntervalSince1970
        workedForSeconds = entry.workedForSeconds
        isStreaming = entry.isStreaming
        activityGroupID = entry.activityGroupID
        assistantPhase = entry.kind == .assistant ? TimelineEntry.validAssistantPhase(entry.assistantPhase) : nil
        tool = entry.toolEvent.map { WebToolSnapshot($0, includePayload: includeToolPayload) }
    }
}

struct WebToolSnapshot: Codable, Equatable, Sendable {
    let name: String
    let summary: String
    let status: String
    let tone: String
    let input: String
    let output: String?
    let duration: TimeInterval?

    init(_ tool: ToolEvent, includePayload: Bool = true) {
        name = tool.name
        summary = tool.summary
        status = tool.status.label
        tone = tool.status.webTone
        input = includePayload ? tool.input : ""
        output = includePayload ? tool.output : nil
        duration = tool.duration
    }
}

struct WebConnectionSnapshot: Codable, Equatable, Sendable {
    let state: String
    let label: String
    let tone: String

    init(_ connection: RuntimeConnectionState) {
        label = connection.label
        switch connection {
        case .disconnected:
            state = "disconnected"
            tone = "orange"
        case .connecting:
            state = "connecting"
            tone = "blue"
        case .connected:
            state = "connected"
            tone = "green"
        case .failed:
            state = "failed"
            tone = "red"
        }
    }
}

struct WebPermissionSnapshot: Codable, Equatable, Sendable {
    let accessibility: String
    let screenRecording: String

    init(_ permissions: AutomationPermissionSnapshot) {
        accessibility = permissions.accessibility.webLabel
        screenRecording = permissions.screenRecording.webLabel
    }
}

private extension TaskStatus {
    var webTone: String {
        switch self {
        case .running: "blue"
        case .waiting: "orange"
        case .completed: "green"
        case .draft: "neutral"
        }
    }
}

private extension ToolRunStatus {
    var webTone: String {
        switch self {
        case .running: "blue"
        case .succeeded: "green"
        case .needsApproval: "orange"
        case .failed: "red"
        }
    }
}

private extension PermissionGrant {
    var webLabel: String {
        switch self {
        case .granted: "Granted"
        case .notGranted: "Not granted"
        }
    }
}

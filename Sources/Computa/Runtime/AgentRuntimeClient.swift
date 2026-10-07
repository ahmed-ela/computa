import Foundation

/// The UI's only knowledge of an agent backend. A future app-server adapter can
/// translate thread and item notifications into these domain events without
/// leaking JSON-RPC details into SwiftUI views.
protocol AgentRuntimeClient: Sendable {
    var providerName: String { get }

    func loadTasks() async throws -> [AgentTask]
    func events() -> AsyncStream<AgentRuntimeEvent>
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws
    func configureWorkspace(path: String, forTaskID taskID: AgentTask.ID) async throws
    func steer(prompt: String, toTaskID taskID: AgentTask.ID) async throws
    func compact(taskID: AgentTask.ID) async throws
    func interrupt(taskID: AgentTask.ID) async throws
    func retryWebsiteSessionCleanup(taskID: AgentTask.ID) async -> WebsiteSessionCleanupReceipt
    func resolveApproval(requestID: String, approved: Bool) async throws
    func connectChrome(_ request: ChromeConnectionRequest) async throws
    func disconnectChrome() async
    func configureEmbeddedWebModelTransport(_ transport: any WebModelTransport) async
    func shutdown() async -> RuntimeShutdownReport
}

/// An empty issue list means the runtime observed its owned cleanup complete.
struct RuntimeShutdownReport: Equatable, Sendable {
    let issues: [String]
    var succeeded: Bool { issues.isEmpty }
}

extension AgentRuntimeClient {
    func retryWebsiteSessionCleanup(taskID: AgentTask.ID) async -> WebsiteSessionCleanupReceipt {
        WebsiteSessionCleanupReceipt(taskID: taskID, runtimeGeneration: UUID(), outcome: .unconfirmed,
            reason: .unsupportedRuntime, trigger: .manual)
    }
    func configureWorkspace(path: String, forTaskID taskID: AgentTask.ID) async throws {
        throw AgentRuntimeCapabilityError.workspaceSelectionUnsupported
    }
    /// Steering must be explicitly implemented by an adapter. Falling back to
    /// submit or interrupt would silently change the meaning of the user's input.
    func steer(prompt: String, toTaskID taskID: AgentTask.ID) async throws {
        throw AgentRuntimeCapabilityError.steeringUnsupported
    }

    func compact(taskID: AgentTask.ID) async throws {
        throw AgentRuntimeCapabilityError.compactionUnsupported
    }

    func connectChrome(_ request: ChromeConnectionRequest) async throws {
        throw AgentRuntimeCapabilityError.chromeConnectionUnsupported
    }

    func disconnectChrome() async {}

    func configureEmbeddedWebModelTransport(_ transport: any WebModelTransport) async {}

    /// Resource-free adapters can keep the default; the production runtime
    /// explicitly implements shutdown for its owned processes and capabilities.
    func shutdown() async -> RuntimeShutdownReport {
        RuntimeShutdownReport(issues: [])
    }
}

enum AgentRuntimeCapabilityError: LocalizedError, Equatable {
    case steeringUnsupported
    case compactionUnsupported
    case chromeConnectionUnsupported
    case workspaceSelectionUnsupported

    var errorDescription: String? {
        switch self {
        case .steeringUnsupported:
            "This runtime does not support steering an active turn. Your message was not sent."
        case .compactionUnsupported:
            "This runtime does not support context compaction."
        case .chromeConnectionUnsupported:
            "This runtime does not support connecting to your existing Chrome session."
        case .workspaceSelectionUnsupported:
            "This runtime does not support choosing a project folder."
        }
    }
}

enum AgentRuntimeEvent: Sendable {
    case websiteSessionCleanupUpdated(WebsiteSessionCleanupReceipt)
    case tasksSnapshot([AgentTask])
    case taskUpserted(AgentTask)
    case timelineEntryAppended(taskID: AgentTask.ID, entry: TimelineEntry)
    case turnDiffUpdated(taskID: AgentTask.ID, turnID: String, diff: String)
    case assistantMessageDelta(taskID: AgentTask.ID, itemID: String, delta: String)
    case assistantMessagePhaseUpdated(taskID: AgentTask.ID, itemID: String, phase: String)
    case assistantMessagesDiscarded(taskID: AgentTask.ID)
    case reasoningMessageUpdated(taskID: AgentTask.ID, itemID: String, text: String)
    case reasoningMessagesDiscarded(taskID: AgentTask.ID)
    case taskStatusChanged(taskID: AgentTask.ID, status: TaskStatus)
    case contextUsageUpdated(taskID: AgentTask.ID, usage: RuntimeContextUsage?)
    case contextCompactionChanged(taskID: AgentTask.ID, state: RuntimeCompactionState)
    case approvalRequested(ActionApprovalRequest)
    case approvalResolved(requestID: String)
    case connectionChanged(RuntimeConnectionState)
    case chromeConnectionChanged(connectionID: UUID, state: ChromeConnectionState)
}

enum RuntimeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(provider: String)
    case failed(message: String)

    var label: String {
        switch self {
        case .disconnected:
            "Runtime disconnected"
        case .connecting:
            "Connecting to runtime"
        case .connected(let provider):
            "Connected to \(provider)"
        case .failed:
            "Runtime connection failed"
        }
    }
}

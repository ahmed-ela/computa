import Foundation

/// The UI's only knowledge of an agent backend. A future app-server adapter can
/// translate thread and item notifications into these domain events without
/// leaking JSON-RPC details into SwiftUI views.
protocol AgentRuntimeClient: Sendable {
    var providerName: String { get }

    func loadTasks() async throws -> [AgentTask]
    func events() -> AsyncStream<AgentRuntimeEvent>
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws
    func interrupt(taskID: AgentTask.ID) async throws
    func resolveApproval(requestID: String, approved: Bool) async throws
}

enum AgentRuntimeEvent: Sendable {
    case tasksSnapshot([AgentTask])
    case taskUpserted(AgentTask)
    case timelineEntryAppended(taskID: AgentTask.ID, entry: TimelineEntry)
    case taskStatusChanged(taskID: AgentTask.ID, status: TaskStatus)
    case approvalRequested(ActionApprovalRequest)
    case approvalResolved(requestID: String)
    case connectionChanged(RuntimeConnectionState)
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

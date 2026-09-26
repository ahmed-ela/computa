import Foundation

/// The UI's only knowledge of an agent backend. A future app-server adapter can
/// translate thread and item notifications into these domain events without
/// leaking JSON-RPC details into SwiftUI views.
protocol AgentRuntimeClient: Sendable {
    var providerName: String { get }

    func loadTasks() async throws -> [AgentTask]
    func events() -> AsyncStream<AgentRuntimeEvent>
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws
    func steer(prompt: String, toTaskID taskID: AgentTask.ID) async throws
    func compact(taskID: AgentTask.ID) async throws
    func interrupt(taskID: AgentTask.ID) async throws
    func resolveApproval(requestID: String, approved: Bool) async throws
    func connectChrome(_ request: ChromeConnectionRequest) async throws
    func disconnectChrome() async
    func shutdown() async -> RuntimeShutdownReport
}

/// An empty issue list means the runtime observed its owned cleanup complete.
struct RuntimeShutdownReport: Equatable, Sendable {
    let issues: [String]
    var succeeded: Bool { issues.isEmpty }
}

extension AgentRuntimeClient {
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

    var errorDescription: String? {
        switch self {
        case .steeringUnsupported:
            "This runtime does not support steering an active turn. Your message was not sent."
        case .compactionUnsupported:
            "This runtime does not support context compaction."
        case .chromeConnectionUnsupported:
            "This runtime does not support connecting to your existing Chrome session."
        }
    }
}

enum AgentRuntimeEvent: Sendable {
    case tasksSnapshot([AgentTask])
    case taskUpserted(AgentTask)
    case timelineEntryAppended(taskID: AgentTask.ID, entry: TimelineEntry)
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

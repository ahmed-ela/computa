import Foundation

/// A single manual-compaction operation. Core owns suspension, timers and the
/// continuation; this reducer retains an early result until Core installs its
/// waiter. Every event must belong to this operation and server generation.
struct CompactionBarrier: Sendable {
    enum Failure: LocalizedError, Equatable, Sendable {
        case cancelled
        case timedOut
        case disconnected
        case rpcFailed(String)
        case turnFailed
        case protocolViolation(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "Context maintenance was stopped. Queued messages remain paused."
            case .timedOut: "Context maintenance timed out. Reconnect before continuing."
            case .disconnected: "The runtime disconnected before context maintenance finished."
            case .rpcFailed(let message), .protocolViolation(let message): message
            case .turnFailed: "Context compaction did not finish successfully. The pending prompt was not sent."
            }
        }
    }

    let id: UUID
    let generation: UUID
    private(set) var turnID: String?
    private(set) var result: Result<Void, Failure>?
    private var hasAcknowledgement = false
    private var hasCompletedItem = false
    private var hasSuccessfulTurn = false

    init(id: UUID = UUID(), generation: UUID) {
        self.id = id
        self.generation = generation
    }

    func isCurrent(operationID: UUID, generation: UUID) -> Bool {
        id == operationID && self.generation == generation
    }

    /// Returns whether state changed, including a newly recorded failure.
    @discardableResult
    mutating func bindTurn(_ turnID: String, operationID: UUID, generation: UUID) -> Bool {
        guard accepts(operationID, generation) else { return false }
        guard !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result = .failure(.protocolViolation("Compaction turn identity is empty."))
            return true
        }
        if let existing = self.turnID {
            guard existing != turnID else { return false }
            result = .failure(.protocolViolation("Compaction turn identity changed before completion."))
            return true
        }
        self.turnID = turnID
        return true
    }

    /// Caller must validate the exact compaction item before forwarding this
    /// event. An item completion alone never proves the enclosing turn succeeded.
    @discardableResult
    mutating func itemCompleted(turnID: String, operationID: UUID, generation: UUID) -> Bool {
        guard accepts(operationID, generation), self.turnID == turnID, !hasCompletedItem else { return false }
        hasCompletedItem = true
        resolveIfReady()
        return true
    }

    @discardableResult
    mutating func terminal(turnID: String, succeeded: Bool, operationID: UUID, generation: UUID) -> Bool {
        guard accepts(operationID, generation), self.turnID == turnID else { return false }
        guard succeeded else {
            result = .failure(.turnFailed)
            return true
        }
        guard !hasSuccessfulTurn else { return false }
        hasSuccessfulTurn = true
        resolveIfReady()
        return true
    }

    @discardableResult
    mutating func acknowledged(operationID: UUID, generation: UUID) -> Bool {
        guard accepts(operationID, generation), !hasAcknowledgement else { return false }
        hasAcknowledgement = true
        resolveIfReady()
        return true
    }

    @discardableResult
    mutating func fail(_ failure: Failure, operationID: UUID, generation: UUID) -> Bool {
        guard accepts(operationID, generation) else { return false }
        result = .failure(failure)
        return true
    }

    @discardableResult
    mutating func cancel(operationID: UUID, generation: UUID) -> Bool {
        fail(.cancelled, operationID: operationID, generation: generation)
    }

    @discardableResult
    mutating func timeout(operationID: UUID, generation: UUID) -> Bool {
        fail(.timedOut, operationID: operationID, generation: generation)
    }

    @discardableResult
    mutating func disconnect(operationID: UUID, generation: UUID) -> Bool {
        fail(.disconnected, operationID: operationID, generation: generation)
    }

    private func accepts(_ operationID: UUID, _ generation: UUID) -> Bool {
        isCurrent(operationID: operationID, generation: generation) && result == nil
    }

    private mutating func resolveIfReady() {
        guard result == nil, turnID != nil, hasAcknowledgement, hasCompletedItem, hasSuccessfulTurn else { return }
        result = .success(())
    }
}

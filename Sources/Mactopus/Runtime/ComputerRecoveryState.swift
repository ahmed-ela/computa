import Foundation

/// Turn-local browser recovery facts, independent of revoked browser handles.
/// The host supplies failure categories and successful recovery observations;
/// model arguments, replacement candidate tokens, and elapsed time do not
/// clear a failure. This type neither performs recovery nor retries an action.
struct ComputerRecoveryState: Sendable {
    struct Target: Hashable, Sendable {
        let connectionGeneration: UUID
        let targetID: String
    }

    enum Recovery: String, Sendable {
        case refreshInventory
        case targetAvailable
        case newConnection
    }

    struct Failure: Equatable, Sendable {
        enum Code: String, Sendable {
            case inventoryRequired
            case staleInventory
            case targetBusy
            case targetUnavailable
            case connectionLost
            case operationRejected
        }

        let code: Code
        /// Native diagnostic only, never arbitrary page/extension error text.
        let message: String
        let recovery: Recovery
        let target: Target?
        let connectionGeneration: UUID?

        init(code: Code, message: String, recovery: Recovery,
             target: Target? = nil, connectionGeneration: UUID? = nil) {
            self.code = code
            self.message = message
            self.recovery = recovery
            self.target = target
            self.connectionGeneration = target?.connectionGeneration ?? connectionGeneration
        }
    }

    struct Rejection: Error, LocalizedError, Equatable, Sendable {
        let failure: Failure
        let deniedAttempts: Int
        let shouldStop: Bool

        var errorDescription: String? {
            let next: String
            switch failure.recovery {
            case .refreshInventory:
                next = "Refresh the tab inventory before binding again."
            case .targetAvailable:
                next = "A fresh inventory must show this exact tab is available before binding it again. Other available tabs remain usable."
            case .newConnection:
                next = "The user must reconnect Chrome before further browser operations."
            }
            return failure.message + " No browser operation was dispatched. " + next
                + (shouldStop ? " Repeated requests made no recovery progress; stop this computer-use attempt and report the original failure." : "")
        }
    }

    private struct Entry: Sendable {
        let failure: Failure
        var deniedAttempts = 0
    }

    private var entries = [Entry]()
    private(set) var latestFailure: Failure?
    let rejectionLimit: Int

    init(rejectionLimit: Int = 2) {
        self.rejectionLimit = max(1, rejectionLimit)
    }

    var unresolvedFailures: [Failure] { entries.map(\.failure) }
    var hasPendingRecovery: Bool { !entries.isEmpty }

    mutating func record(_ failure: Failure) {
        // Rejected retries and secondary missing-context errors must not
        // replace the original cause or reset its no-progress budget.
        if entries.contains(where: {
            $0.failure.recovery == .newConnection
                && Self.sameConnection($0.failure.connectionGeneration, failure.connectionGeneration)
        }) { return }
        if entries.contains(where: {
            $0.failure.recovery == failure.recovery
                && $0.failure.target == failure.target
                && $0.failure.connectionGeneration == failure.connectionGeneration
        }) { return }
        latestFailure = failure
        entries.append(Entry(failure: failure))
    }

    mutating func admitInventory(connectionGeneration: UUID?) -> Rejection? {
        guard let index = entries.firstIndex(where: {
            $0.failure.recovery == .newConnection
                && Self.sameConnection($0.failure.connectionGeneration, connectionGeneration)
        }) else { return nil }
        return reject(index)
    }

    mutating func admitBind(target: Target?) -> Rejection? {
        // A lost connection takes precedence over stale inventory or one busy
        // target, retaining its explanation even after context cleanup.
        if let index = entries.firstIndex(where: {
            $0.failure.recovery == .newConnection
                && Self.sameConnection($0.failure.connectionGeneration, target?.connectionGeneration)
        }) { return reject(index) }
        guard let index = entries.firstIndex(where: {
            switch $0.failure.recovery {
            case .newConnection: return false
            case .refreshInventory:
                return Self.sameConnection($0.failure.connectionGeneration, target?.connectionGeneration)
                    && ($0.failure.target == nil || $0.failure.target == target)
            case .targetAvailable:
                return target != nil && $0.failure.target == target
            }
        }) else { return nil }
        return reject(index)
    }

    /// Call only after a fresh successful inventory, never a cursor replay.
    /// Availability is a positive native observation; unknown/absent targets
    /// do not establish that a competing debugger released a busy target.
    mutating func inventoryRefreshed(connectionGeneration: UUID, availableTargets: Set<String>) {
        entries.removeAll { entry in
            guard Self.sameConnection(entry.failure.connectionGeneration, connectionGeneration) else { return false }
            switch entry.failure.recovery {
            case .refreshInventory: return true
            case .targetAvailable:
                guard let target = entry.failure.target else { return false }
                return availableTargets.contains(target.targetID)
            case .newConnection: return false
            }
        }
    }

    /// Call only after the native connection workflow has approved and
    /// established a new generation, never in response to a model claim.
    mutating func connected(generation: UUID) {
        entries.removeAll {
            $0.failure.recovery == .newConnection && $0.failure.connectionGeneration != generation
        }
    }

    private mutating func reject(_ index: Int) -> Rejection {
        entries[index].deniedAttempts = min(rejectionLimit, entries[index].deniedAttempts + 1)
        let entry = entries[index]
        return Rejection(failure: entry.failure, deniedAttempts: entry.deniedAttempts,
                         shouldStop: entry.deniedAttempts >= rejectionLimit)
    }

    private static func sameConnection(_ first: UUID?, _ second: UUID?) -> Bool {
        first == nil || second == nil || first == second
    }
}

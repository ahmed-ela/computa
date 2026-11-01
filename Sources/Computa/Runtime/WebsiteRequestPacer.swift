import Foundation

/// Serializes website submissions under a local rolling-budget policy. This is not a
/// quota receipt: requests made outside Computa can still exhaust an account.
/// A permit spans the actual Send await; each reserved cost expires one interval
/// after it returns, even on failure. Waiting never dispatches or replays a request.
actor WebsiteRequestPacer {
    private struct Waiter {
        let id: UUID
        let cost: Int
        let continuation: CheckedContinuation<UUID, Error>
    }
    private struct Charge {
        let cost: Int
        let expires: ContinuousClock.Instant
    }
    enum Failure: Error { case invalidCost }

    private let interval: Duration
    private let budget: Int
    private var active: (id: UUID, cost: Int)?
    private var charges: [Charge] = []
    private var waiters: [Waiter] = []
    private var wakeTask: Task<Void, Never>?

    init(interval: Duration = .seconds(65), budget: Int = 8_000) {
        self.interval = max(.zero, interval)
        self.budget = max(1, budget)
    }

    #if DEBUG
    func waitingCountForTesting() -> Int { waiters.count }
    #endif

    func acquire(cost: Int = 8_000) async throws -> UUID {
        guard cost > 0, cost <= budget else { throw Failure.invalidCost }
        try Task.checkCancellation()
        let id = UUID()
        let permit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, cost: cost, continuation: continuation))
                grantIfReady()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        do { try Task.checkCancellation() }
        catch { release(permit); throw error }
        return permit
    }

    func release(_ permit: UUID) {
        guard let held = active, held.id == permit else { return }
        active = nil
        charges.append(Charge(cost: held.cost, expires: ContinuousClock.now + interval))
        grantIfReady()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        if waiters.isEmpty { wakeTask?.cancel(); wakeTask = nil }
        grantIfReady()
    }

    private func grantIfReady() {
        guard active == nil, let first = waiters.first else { return }
        let now = ContinuousClock.now
        charges.removeAll { $0.expires <= now }
        if charges.reduce(0, { $0 + $1.cost }) + first.cost > budget,
           let deadline = charges.first?.expires {
            guard wakeTask == nil else { return }
            wakeTask = Task {
                do { try await ContinuousClock().sleep(until: deadline) }
                catch { return }
                self.wakeTask = nil
                self.grantIfReady()
            }
            return
        }
        wakeTask?.cancel()
        wakeTask = nil
        let waiter = waiters.removeFirst()
        active = (waiter.id, waiter.cost)
        waiter.continuation.resume(returning: waiter.id)
    }
}

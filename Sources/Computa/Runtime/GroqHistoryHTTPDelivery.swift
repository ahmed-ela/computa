import Foundation

/// One native HTTP write, identified by object identity. Root keeps its exact
/// immutable binding/tickets beside this object and rechecks them after wait.
/// Delivery is a fact only; it grants no action or publication authority.
final class GroqHistoryHTTPDelivery: @unchecked Sendable {
    enum Failure: Error, Equatable, Sendable { case revoked, deadline, bounds }
    private enum State { case pending, delivered, revoked(Failure) }
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private var state = State.pending
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var deadlineTask: Task<Void, Never>?
    private static let maximumWaiters = 64

    convenience init() { self.init(deadline: ContinuousClock.now + .seconds(5)) }
    private init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    func wait() async throws { try await wait(didPark: nil) }

    @discardableResult
    func deliver() -> Bool { finish(.delivered) }
    func revoke() { _ = finish(.revoked(.revoked)) }

    #if DEBUG
    /// Pure native test configuration, never an endpoint or model parameter.
    static func forTesting(timeout: Duration) -> GroqHistoryHTTPDelivery {
        .init(deadline: ContinuousClock.now + min(timeout, .seconds(5)))
    }
    func waitForTesting(didPark: @escaping @Sendable () -> Void) async throws {
        try await wait(didPark: didPark)
    }
    #endif

    private func wait(didPark: (@Sendable () -> Void)?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                install(id, continuation: continuation, didPark: didPark)
            }
        } onCancel: { self.cancel(id) }
        try Task.checkCancellation()
    }

    private func install(_ id: UUID, continuation: CheckedContinuation<Void, Error>, didPark: (@Sendable () -> Void)?) {
        var immediate: Result<Void, Error>?
        var expired: [CheckedContinuation<Void, Error>] = []
        var timer: Task<Void, Never>?
        lock.lock()
        do {
            try Task.checkCancellation()
            switch state {
            case .delivered: immediate = .success(())
            case .revoked(let reason): immediate = .failure(reason)
            case .pending:
                if ContinuousClock.now >= deadline {
                    state = .revoked(.deadline)
                    expired = Array(waiters.values); waiters.removeAll()
                    timer = deadlineTask; deadlineTask = nil
                    immediate = .failure(Failure.deadline)
                } else {
                    guard waiters.count < Self.maximumWaiters else { throw Failure.bounds }
                    waiters[id] = continuation
                    if deadlineTask == nil {
                        let deadline = self.deadline
                        deadlineTask = Task.detached { [weak self] in
                            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                            _ = self?.finish(.revoked(.deadline))
                        }
                    }
                }
            }
        } catch { immediate = .failure(error) }
        lock.unlock()
        timer?.cancel()
        for waiter in expired { waiter.resume(throwing: Failure.deadline) }
        if let immediate { continuation.resume(with: immediate) }
        else { didPark?() }
    }

    private func cancel(_ id: UUID) {
        lock.lock(); let waiter = waiters.removeValue(forKey: id); lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }
    private func finish(_ requested: State) -> Bool {
        let result: Result<Void, Error>
        let delivered: Bool
        lock.lock()
        guard case .pending = state else { lock.unlock(); return false }
        switch requested {
        case .pending: lock.unlock(); return false
        case .delivered:
            if ContinuousClock.now >= deadline {
                state = .revoked(.deadline); result = .failure(Failure.deadline); delivered = false
            } else { state = .delivered; result = .success(()); delivered = true }
        case .revoked(let reason): state = requested; result = .failure(reason); delivered = false
        }
        let pending = Array(waiters.values); waiters.removeAll()
        let timer = deadlineTask; deadlineTask = nil
        lock.unlock()
        timer?.cancel()
        for waiter in pending { waiter.resume(with: result) }
        return delivered
    }
}

import Foundation

/// Native-only handoff. The response is derived from the same opaque receipt,
/// so Core cannot accidentally publish independently reconstructed tool text.
struct GroqHistoryReadExecution: Sendable {
    let publication: GroqHistoryReadPublication
    var responseData: Data { publication.responseData }
}

/// One actual reader RPC write, not a model assertion or a mutable actor task.
/// Server stores this box before returning it to Core. A racing next HTTP frame
/// can wait for the synchronous Core commit without awaiting a Server callback.
final class GroqHistoryReadPublication: @unchecked Sendable {
    enum Failure: Error, Equatable, Sendable { case scope, aborted, deadline, capacity }
    private enum State {
        case pending
        case published(GroqContextManifestProjector.PublishedLookup)
        case aborted(Failure)
    }
    let responseData: Data
    private let snapshot: GroqContextManifestProjector.Snapshot
    private let proposal: GroqContextManifestProjector.ReadProposal
    private let authority: GroqContextManifestProjector.ReaderAuthority
    private let writer: GroqNativePublicationLedger.CompletionWriter
    private let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private var state = State.pending
    private var waiters: [UUID: CheckedContinuation<GroqContextManifestProjector.PublishedLookup, Error>] = [:]
    private var deadlineTask: Task<Void, Never>?

    /// Called only by the current registered Server context after native read
    /// preparation. None of these capabilities is decoded from model JSON.
    init(snapshot: GroqContextManifestProjector.Snapshot,
        proposal: GroqContextManifestProjector.ReadProposal,
        authority: GroqContextManifestProjector.ReaderAuthority,
        writer: GroqNativePublicationLedger.CompletionWriter) throws {
        guard snapshot.isCurrent(), writer.isCurrent(current: snapshot.binding.scope),
              proposal.responseData.count <= 32 * 1_024,
              String(data: proposal.responseData, encoding: .utf8) != nil else { throw Failure.scope }
        self.snapshot = snapshot; self.proposal = proposal; self.authority = authority; self.writer = writer
        responseData = proposal.responseData
        deadline = ContinuousClock.now + .seconds(5)
        let expiration = deadline
        deadlineTask = Task.detached { [weak self] in
            do { try await ContinuousClock().sleep(until: expiration) } catch { return }
            self?.abortIfPending(reason: .deadline)
        }
    }

    /// Core calls again after every actor hop and immediately before the pipe
    /// write. Published/expired receipts cannot be used for a second response.
    func isCurrent(currentScope: GroqNativePublicationLedger.Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .pending = state, snapshot.binding.scope == currentScope,
              ContinuousClock.now < deadline else { return false }
        return live()
    }

    /// MUST follow the actual successful sendResponse pipe write with no await.
    /// A false result after that write requires Core to revoke the whole writer;
    /// it must not send another response or replay the reader call.
    @discardableResult
    func commitAfterRPCWrite(responseData actual: Data) -> Bool {
        var receivers: [CheckedContinuation<GroqContextManifestProjector.PublishedLookup, Error>] = []
        var result: Result<GroqContextManifestProjector.PublishedLookup, Error> = .failure(Failure.scope)
        var committed = false
        lock.lock()
        if case .pending = state {
            if ContinuousClock.now >= deadline {
                state = .aborted(.deadline); result = .failure(Failure.deadline)
            } else if actual != responseData || !live() {
                state = .aborted(.scope)
            } else {
                do {
                    let publication = try GroqContextManifestProjector.commitLookupPublication(authority,
                        ticket: proposal.publicationTicket, binding: snapshot.binding,
                        contextNonce: snapshot.contextNonce, responseData: actual)
                    state = .published(publication); result = .success(publication); committed = true
                } catch { state = .aborted(.scope) }
            }
            receivers = Array(waiters.values); waiters.removeAll()
            deadlineTask?.cancel(); deadlineTask = nil
        }
        lock.unlock()
        for receiver in receivers { receiver.resume(with: result) }
        return committed
    }

    func abortIfPending() { abortIfPending(reason: .aborted) }

    /// Root rechecks its full current actor binding before importing this value.
    /// The kernel independently checks its transitive native origins as well.
    func publishedLookup() -> GroqContextManifestProjector.PublishedLookup? {
        lock.lock(); defer { lock.unlock() }
        guard case .published(let value) = state, live() else { return nil }
        return value
    }

    /// Creation-time five-second deadline is shared by all waiters. No polling,
    /// deadline renewal, model request or event-observer installation occurs.
    func waitForPublication() async throws -> GroqContextManifestProjector.PublishedLookup {
        let id = UUID()
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<GroqContextManifestProjector.PublishedLookup, Error>) in
                registerWaiter(id: id, continuation: continuation)
            }
        } onCancel: { self.cancelWaiter(id) }
        try Task.checkCancellation()
        guard let value = publishedLookup() else { throw Failure.scope }
        return value
    }

    private func live() -> Bool {
        writer.isCurrent(current: snapshot.binding.scope) && snapshot.isCurrent()
    }
    private func registerWaiter(id: UUID,
        continuation: CheckedContinuation<GroqContextManifestProjector.PublishedLookup, Error>) {
        var immediate: Result<GroqContextManifestProjector.PublishedLookup, Error>?
        lock.lock()
        if Task.isCancelled { immediate = .failure(CancellationError()) }
        else {
            switch state {
            case .published(let value): immediate = live() ? .success(value) : .failure(Failure.scope)
            case .aborted(let reason): immediate = .failure(reason)
            case .pending:
                if !live() { immediate = .failure(Failure.scope) }
                else if ContinuousClock.now >= deadline { immediate = .failure(Failure.deadline) }
                else if waiters.count >= 16 { immediate = .failure(Failure.capacity) }
                else { waiters[id] = continuation }
            }
        }
        lock.unlock()
        if let immediate { continuation.resume(with: immediate) }
    }
    private func cancelWaiter(_ id: UUID) {
        lock.lock(); let continuation = waiters.removeValue(forKey: id); lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
    private func abortIfPending(reason: Failure) {
        var receivers: [CheckedContinuation<GroqContextManifestProjector.PublishedLookup, Error>] = []
        lock.lock()
        if case .pending = state {
            state = .aborted(reason); receivers = Array(waiters.values); waiters.removeAll()
            deadlineTask?.cancel(); deadlineTask = nil
        }
        lock.unlock()
        for receiver in receivers { receiver.resume(throwing: reason) }
    }
}

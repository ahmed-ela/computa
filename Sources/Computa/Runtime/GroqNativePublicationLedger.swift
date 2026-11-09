import CryptoKit
import Foundation

/// In-memory provenance only. This type neither executes tools nor validates an
/// inference/HTTP caller. Its native owner must apply those existing fences
/// before every call; no authority or receipt is decoded from model JSON.
final class GroqNativePublicationLedger: @unchecked Sendable {
    struct Scope: Equatable, Sendable {
        let taskID: String
        let threadID: String
        let turnID: String
        let runtimeGeneration: UUID
        let preparationID: UUID
        let modelID: String
        let coreGeneration: UUID
    }
    struct Binding: Equatable, Sendable {
        let scope: Scope
        let transportGeneration: UUID
    }
    struct ServerAuthority: Sendable {
        fileprivate let owner: UUID
        fileprivate init(owner: UUID) { self.owner = owner }
    }
    struct ScopeHandle: Sendable {
        fileprivate let owner: UUID
        fileprivate let epoch: UUID
        fileprivate init(owner: UUID, epoch: UUID) { self.owner = owner; self.epoch = epoch }
    }
    struct CompletionWriter: Sendable {
        fileprivate let ledger: GroqNativePublicationLedger
        fileprivate let owner: UUID
        fileprivate let epoch: UUID
        fileprivate init(ledger: GroqNativePublicationLedger, owner: UUID, epoch: UUID) {
            self.ledger = ledger; self.owner = owner; self.epoch = epoch
        }
        @discardableResult
        func recordCompleted(current: Scope, itemID: String, terminal: Terminal) -> Bool {
            ledger.recordCompleted(self, current: current, itemID: itemID, terminal: terminal)
        }
        func isCurrent(current: Scope) -> Bool { ledger.isCurrent(self, current: current) }
        func revoke(reason: Revocation) { ledger.revokeCompletionWriter(self, reason: reason) }
    }
    struct Ticket: Sendable {
        fileprivate let owner: UUID
        fileprivate let epoch: UUID
        fileprivate let id: UUID
        fileprivate init(owner: UUID, epoch: UUID, id: UUID) {
            self.owner = owner; self.epoch = epoch; self.id = id
        }
    }
    struct PublishedPair: Sendable {
        fileprivate let owner: UUID
        fileprivate let epoch: UUID
        fileprivate let id: UUID
        fileprivate init(owner: UUID, epoch: UUID, id: UUID) {
            self.owner = owner; self.epoch = epoch; self.id = id
        }
    }
    enum Kind: Equatable, Sendable { case execCommand, applyPatch }
    enum Field: Equatable, Sendable { case arguments, input, output }
    enum CommandStatus: Equatable, Sendable { case completed, failed, declined, inProgress }
    enum PatchStatus: Equatable, Sendable { case completed, failed, declined, inProgress }
    enum Terminal: Equatable, Sendable {
        case command(status: CommandStatus, exitCode: Int?)
        case patch(status: PatchStatus)
        fileprivate func succeeds(for kind: Kind) -> Bool {
            switch (kind, self) {
            case (.execCommand, .command(.completed, let exit)): exit == 0
            case (.applyPatch, .patch(.completed)): true
            default: false
            }
        }
    }
    enum Revocation: CaseIterable, Sendable {
        case turnChanged, modelChanged, transportChanged, stopped, compaction, shutdown, nativeContextChanged
    }
    enum Refusal: Error, Equatable { case authority, scope, bounds, duplicate, shape }
    enum NativeFactWaitFailure: Error, Equatable, Sendable { case scope, unknownCall, bounds, deadline }
    /// Construct ONLY from the server's already validated, actually encoded
    /// reply's native output items. These values alone convey no authority.
    struct IssuedCall: Sendable {
        let callID: String
        let kind: Kind
        let name: String
        let namespace: String?
        let argumentUTF8: Data
    }
    /// Ranges belong to the same authenticated continuation Data, AFTER ordinary
    /// continuation validation and the strict raw layout scanner. Decoded string
    /// bytes match issuance; actual value TOKEN bytes are retained verbatim.
    struct HistoryPair: Sendable {
        let callID: String
        let kind: Kind
        let name: String
        let namespace: String?
        let argumentUTF8: Data
        let argumentValueRange: Range<Int>
        let outputValueRange: Range<Int>
    }
    struct ValidatedHistory: Sendable {
        let sourceUTF8: Data
        let pairs: [HistoryPair]
    }
    struct LiteralField: Sendable {
        fileprivate let ledger: GroqNativePublicationLedger
        fileprivate let owner: UUID
        fileprivate let epoch: UUID
        fileprivate let publicationID: UUID
        let scope: Scope
        let callID: String
        let kind: Kind
        let name: String
        let namespace: String?
        let field: Field
        let rawJSONValue: Data
        let sha256: String
        let byteCount: Int
        let nativeHTTPSourceSHA256: String
        let valueRange: Range<Int>?
        fileprivate init(ledger: GroqNativePublicationLedger, owner: UUID, epoch: UUID, publicationID: UUID, scope: Scope,
            callID: String, kind: Kind, name: String, namespace: String?, field: Field,
            rawJSONValue: Data, sha256: String, nativeHTTPSourceSHA256: String, valueRange: Range<Int>) {
            self.ledger = ledger; self.owner = owner; self.epoch = epoch; self.publicationID = publicationID; self.scope = scope
            self.callID = callID; self.kind = kind; self.name = name; self.namespace = namespace; self.field = field
            self.rawJSONValue = rawJSONValue; self.sha256 = sha256; self.byteCount = rawJSONValue.count
            self.nativeHTTPSourceSHA256 = nativeHTTPSourceSHA256; self.valueRange = valueRange
        }
        /// Identity comparison only. The native owner must still resolve under
        /// its current binding; this does not revive a revoked snapshot.
        func isSameEpoch(as other: Self) -> Bool { owner == other.owner && epoch == other.epoch }
        /// Live provenance only, never action authority. HTTP framing/ranges may
        /// advance, but this exact field must remain in the successful native call.
        func isCurrent() -> Bool { ledger.isCurrent(self) }
    }

    static let maximumScopes = 16
    static let maximumCalls = 128
    static let maximumLiteralBytes = 160 * 1_024
    static let maximumRetainedBytes = 4 * 1_048_576
    static let maximumHTTPBytes = 160 * 1_024
    static let maximumNativeFactWaiters = 64
    private enum WriteState: Equatable { case staged, committed, aborted }
    private final class Response {
        let id = UUID()
        let responseID: String
        let encodedSHA256: String
        var state = WriteState.staged
        init(responseID: String, encodedSHA256: String) {
            self.responseID = responseID; self.encodedSHA256 = encodedSHA256
        }
    }
    private final class Call {
        let issued: IssuedCall
        let response: Response
        var terminal: Terminal?
        var invalid = false
        var publicationID: UUID?
        var argumentToken: Data?
        var outputToken: Data?
        var httpSourceSHA256: String?
        var argumentRange: Range<Int>?
        var outputRange: Range<Int>?
        init(issued: IssuedCall, response: Response) { self.issued = issued; self.response = response }
    }
    private final class Epoch {
        let id = UUID()
        let binding: Binding
        var responses: [UUID: Response] = [:]
        var responseIDs = Set<String>()
        var calls: [String: Call] = [:]
        var publications: [UUID: String] = [:]
        var retainedBytes = 0
        init(binding: Binding) { self.binding = binding }
    }
    private final class NativeFactWaiter {
        let epoch: UUID
        let callIDs: [String]
        let continuation: CheckedContinuation<Void, Error>
        var deadlineTask: Task<Void, Never>?
        init(epoch: UUID, callIDs: [String], continuation: CheckedContinuation<Void, Error>) {
            self.epoch = epoch; self.callIDs = callIDs; self.continuation = continuation
        }
    }
    private let owner = UUID()
    private let lock = NSLock()
    private var epochs: [UUID: Epoch] = [:]
    private var taskEpochs: [String: UUID] = [:]
    private var nativeFactWaiters: [UUID: NativeFactWaiter] = [:]
    private init() {}

    static func makeOwner() -> (ledger: GroqNativePublicationLedger, authority: ServerAuthority) {
        let ledger = GroqNativePublicationLedger()
        return (ledger, ServerAuthority(owner: ledger.owner))
    }

    /// Atomic native registration returns a completion-only writer to Core.
    /// Reinstalling a task revokes its old epoch, even if visible IDs match.
    func installScope(_ authority: ServerAuthority, binding: Binding) throws -> (ScopeHandle, CompletionWriter) {
        var revoked: [NativeFactWaiter] = []
        lock.lock(); defer { lock.unlock(); Self.resume(revoked, with: .failure(NativeFactWaitFailure.scope)) }
        guard authority.owner == owner else { throw Refusal.authority }
        guard [binding.scope.taskID, binding.scope.threadID, binding.scope.turnID].allSatisfy({ Self.canonicalUUID($0) }),
              Self.boundedID(binding.scope.modelID) else { throw Refusal.scope }
        if let old = taskEpochs[binding.scope.taskID] {
            epochs.removeValue(forKey: old); revoked = takeWaiters(epoch: old)
        }
        guard epochs.count < Self.maximumScopes else { throw Refusal.bounds }
        let epoch = Epoch(binding: binding)
        epochs[epoch.id] = epoch; taskEpochs[binding.scope.taskID] = epoch.id
        return (ScopeHandle(owner: owner, epoch: epoch.id), CompletionWriter(ledger: self, owner: owner, epoch: epoch.id))
    }

    /// Stage before HTTP publication; only commitHTTPWrite can make it eligible.
    /// An unknown/failed/dynamic browser tool is never represented by IssuedCall.
    func stageIssuedResponse(_ authority: ServerAuthority, scope: ScopeHandle, current: Binding,
        responseID: String, encodedResponseSHA256: String, calls: [IssuedCall]) throws -> Ticket {
        lock.lock(); defer { lock.unlock() }
        guard let epoch = checked(authority, scope, current) else { throw Refusal.scope }
        guard Self.boundedID(responseID), Self.digest(encodedResponseSHA256), !calls.isEmpty,
              calls.count <= Self.maximumCalls, epoch.calls.count + calls.count <= Self.maximumCalls,
              epoch.responses.count < Self.maximumCalls else { throw Refusal.bounds }
        guard !epoch.responseIDs.contains(responseID), Set(calls.map(\.callID)).count == calls.count,
              calls.allSatisfy({ epoch.calls[$0.callID] == nil }) else { throw Refusal.duplicate }
        guard calls.allSatisfy({ Self.valid($0) }) else { throw Refusal.shape }
        let bytes = calls.reduce(0) { $0 + $1.argumentUTF8.count }
        guard bytes <= Self.maximumRetainedBytes - epoch.retainedBytes else { throw Refusal.bounds }
        let response = Response(responseID: responseID, encodedSHA256: encodedResponseSHA256)
        epoch.responses[response.id] = response; epoch.responseIDs.insert(responseID)
        for call in calls { epoch.calls[call.callID] = Call(issued: call, response: response) }
        epoch.retainedBytes += bytes
        return Ticket(owner: owner, epoch: epoch.id, id: response.id)
    }

    /// Invoke only after the actual HTTP write succeeds, under the same fresh
    /// native binding. An early native completion remains staged until now.
    func commitHTTPWrite(_ authority: ServerAuthority, ticket: Ticket, current: Binding) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let epoch = checked(authority, ticket, current), let response = epoch.responses[ticket.id],
              response.state == .staged else { return false }
        response.state = .committed
        return true
    }

    func abortHTTPWrite(_ authority: ServerAuthority, ticket: Ticket, current: Binding) {
        var aborted: [NativeFactWaiter] = []
        lock.lock(); defer { lock.unlock(); Self.resume(aborted, with: .failure(NativeFactWaitFailure.scope)) }
        guard let epoch = checked(authority, ticket, current), let response = epoch.responses[ticket.id],
              response.state != .aborted else { return }
        response.state = .aborted
        for call in epoch.calls.values where call.response === response { invalidate(call, in: epoch) }
        let ids = Set(epoch.calls.filter { $0.value.response === response }.map(\.key))
        aborted = takeWaiters(epoch: epoch.id, touching: ids)
    }

    /// Core calls only after its existing native item/current-turn guards. No
    /// stdout, formatted output or model-complete boolean enters this method.
    @discardableResult
    private func recordCompleted(_ writer: CompletionWriter, current: Scope, itemID: String, terminal: Terminal) -> Bool {
        var settled: [NativeFactWaiter] = []
        lock.lock(); defer { lock.unlock(); Self.resume(settled, with: .success(())) }
        guard writer.owner == owner, let epoch = epochs[writer.epoch], epoch.binding.scope == current,
              taskEpochs[current.taskID] == epoch.id, let call = epoch.calls[itemID], !call.invalid,
              call.response.state != .aborted else { return false }
        guard call.terminal == nil else {
            invalidate(call, in: epoch); settled = takeChangedFactWaiters(in: epoch); return false
        }
        call.terminal = terminal
        if !terminal.succeeds(for: call.issued.kind) { invalidate(call, in: epoch) }
        settled = takeChangedFactWaiters(in: epoch)
        return true
    }

    /// Snapshot only: unknown historical IDs do not become native-issued calls.
    /// Caller removes settled facts before each subsequent event-driven wait.
    /// matchingIDs must be physically matched older pairs from the authenticated
    /// HTTP layout; this ledger does not infer that permission from tool names.
    func unsettledIssuedCallIDs(_ authority: ServerAuthority, scope: ScopeHandle, current: Binding,
        matchingIDs: [String]) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let epoch = checked(authority, scope, current) else { throw NativeFactWaitFailure.scope }
        guard matchingIDs.count <= 1_024, Set(matchingIDs).count == matchingIDs.count else { throw NativeFactWaitFailure.bounds }
        let known = matchingIDs.filter { epoch.calls[$0] != nil }
        guard known.allSatisfy({ epoch.calls[$0]?.response.state != .aborted }) else { throw NativeFactWaitFailure.scope }
        return known.filter { epoch.calls[$0]?.terminal == nil }
    }

    /// Wait for ANY new fact among known native-issued IDs, never execution or success.
    /// Existing typed failed/uncertain facts settle normally and remain INLINE.
    /// Caller first tries the normal budget, waits only for older matching fields
    /// still unsettled, and reuses ONE overall deadline across local rebuilds.
    /// One deadline task and one native event subscription; no polling/replay.
    func waitForAnyNativeCompletion(_ authority: ServerAuthority, scope: ScopeHandle, current: Binding,
        callIDs: [String], until: ContinuousClock.Instant) async throws {
        try await waitForAnyNativeCompletion(authority, scope: scope, current: current,
            callIDs: callIDs, until: until, didPark: nil)
    }
    #if DEBUG
    /// A zero-data deterministic unit-test barrier, not a runtime endpoint.
    func waitForAnyNativeCompletionForTesting(_ authority: ServerAuthority, scope: ScopeHandle, current: Binding,
        callIDs: [String], until: ContinuousClock.Instant, didPark: @escaping @Sendable () -> Void) async throws {
        try await waitForAnyNativeCompletion(authority, scope: scope, current: current,
            callIDs: callIDs, until: until, didPark: didPark)
    }
    #endif
    private func waitForAnyNativeCompletion(_ authority: ServerAuthority, scope: ScopeHandle, current: Binding,
        callIDs: [String], until: ContinuousClock.Instant, didPark: (@Sendable () -> Void)?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                installWaiter(id: id, authority: authority, scope: scope, current: current,
                    callIDs: callIDs, until: until, continuation: continuation, didPark: didPark)
            }
        } onCancel: {
            self.finishWaiter(id, with: .failure(CancellationError()))
        }
        try Task.checkCancellation()
        try recheckNativeWait(authority, scope: scope, current: current, callIDs: callIDs)
    }
    private func installWaiter(id: UUID, authority: ServerAuthority, scope: ScopeHandle, current: Binding,
        callIDs: [String], until: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>,
        didPark: (@Sendable () -> Void)?) {
        var immediate: Result<Void, Error>?
        lock.lock()
        do {
            try Task.checkCancellation()
            let epoch = try checkedWaitScope(authority, scope: scope, current: current, callIDs: callIDs)
            if callIDs.isEmpty || callIDs.contains(where: { epoch.calls[$0]?.terminal != nil }) { immediate = .success(()) }
            else {
                guard nativeFactWaiters.count < Self.maximumNativeFactWaiters else { throw NativeFactWaitFailure.bounds }
                let deadline = min(until, ContinuousClock.now + .seconds(5))
                guard deadline > ContinuousClock.now else { throw NativeFactWaitFailure.deadline }
                let waiter = NativeFactWaiter(epoch: epoch.id, callIDs: callIDs, continuation: continuation)
                nativeFactWaiters[id] = waiter
                waiter.deadlineTask = Task.detached { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    self?.finishWaiter(id, with: .failure(NativeFactWaitFailure.deadline))
                }
            }
        } catch { immediate = .failure(error) }
        lock.unlock()
        if let immediate { continuation.resume(with: immediate) }
        else { didPark?() }
    }
    private func recheckNativeWait(_ authority: ServerAuthority, scope: ScopeHandle, current: Binding, callIDs: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try checkedWaitScope(authority, scope: scope, current: current, callIDs: callIDs)
    }
    private func checkedWaitScope(_ authority: ServerAuthority, scope: ScopeHandle, current: Binding,
        callIDs: [String]) throws -> Epoch {
        guard let epoch = checked(authority, scope, current) else { throw NativeFactWaitFailure.scope }
        guard callIDs.count <= Self.maximumCalls, Set(callIDs).count == callIDs.count else { throw NativeFactWaitFailure.bounds }
        guard callIDs.allSatisfy({ epoch.calls[$0] != nil }) else { throw NativeFactWaitFailure.unknownCall }
        guard callIDs.allSatisfy({ epoch.calls[$0]?.response.state != .aborted }) else { throw NativeFactWaitFailure.scope }
        return epoch
    }
    private func finishWaiter(_ id: UUID, with result: Result<Void, Error>) {
        lock.lock(); let waiter = nativeFactWaiters.removeValue(forKey: id); lock.unlock()
        if let waiter { Self.resume([waiter], with: result) }
    }
    /// Locked helpers. Every continuation is removed exactly once before resume.
    private func takeWaiters(epoch: UUID, touching callIDs: Set<String>? = nil) -> [NativeFactWaiter] {
        let ids: [UUID] = nativeFactWaiters.compactMap { id, waiter in
            guard waiter.epoch == epoch else { return nil }
            if let callIDs, !waiter.callIDs.contains(where: { callIDs.contains($0) }) { return nil }
            return id
        }
        return ids.compactMap { nativeFactWaiters.removeValue(forKey: $0) }
    }
    private func takeChangedFactWaiters(in epoch: Epoch) -> [NativeFactWaiter] {
        let ids: [UUID] = nativeFactWaiters.compactMap { id, waiter in
            waiter.epoch == epoch.id && waiter.callIDs.contains(where: { epoch.calls[$0]?.terminal != nil }) ? id : nil
        }
        return ids.compactMap { nativeFactWaiters.removeValue(forKey: $0) }
    }
    private static func resume(_ waiters: [NativeFactWaiter], with result: Result<Void, Error>) {
        for waiter in waiters { waiter.deadlineTask?.cancel(); waiter.continuation.resume(with: result) }
    }

    /// Optional compression provenance; every unmatched/refused item stays INLINE.
    /// The caller must authenticate/validate ordinary continuation BEFORE this.
    func reconcileValidatedHistory(_ authority: ServerAuthority, scope: ScopeHandle, current: Binding,
        history: ValidatedHistory) -> [PublishedPair] {
        lock.lock(); defer { lock.unlock() }
        guard let epoch = checked(authority, scope, current), history.sourceUTF8.count <= Self.maximumHTTPBytes,
              history.pairs.count <= Self.maximumCalls,
              Set(history.pairs.map(\.callID)).count == history.pairs.count else { return [] }
        let sourceSHA256 = Self.sha(history.sourceUTF8)
        var result: [PublishedPair] = []
        for pair in history.pairs {
            guard let call = epoch.calls[pair.callID], !call.invalid, call.response.state == .committed,
                  call.terminal?.succeeds(for: call.issued.kind) == true else { continue }
            guard pair.kind == call.issued.kind, pair.name == call.issued.name,
                  pair.namespace == call.issued.namespace, pair.argumentUTF8 == call.issued.argumentUTF8,
                  let argument = Self.token(history.sourceUTF8, pair.argumentValueRange),
                  let output = Self.token(history.sourceUTF8, pair.outputValueRange),
                  pair.argumentValueRange.upperBound <= pair.outputValueRange.lowerBound,
                  let string = try? JSONSerialization.jsonObject(with: argument, options: [.fragmentsAllowed]) as? String,
                  Data(string.utf8) == pair.argumentUTF8 else { invalidate(call, in: epoch); continue }
            if let id = call.publicationID {
                guard call.argumentToken == argument, call.outputToken == output else {
                    invalidate(call, in: epoch); continue
                }
                call.httpSourceSHA256 = sourceSHA256
                call.argumentRange = pair.argumentValueRange; call.outputRange = pair.outputValueRange
                result.append(PublishedPair(owner: owner, epoch: epoch.id, id: id)); continue
            }
            let bytes = argument.count + output.count
            guard bytes <= Self.maximumRetainedBytes - epoch.retainedBytes else { continue }
            let id = UUID()
            call.argumentToken = argument; call.outputToken = output; call.publicationID = id
            call.httpSourceSHA256 = sourceSHA256
            call.argumentRange = pair.argumentValueRange; call.outputRange = pair.outputValueRange
            epoch.publications[id] = pair.callID; epoch.retainedBytes += bytes
            result.append(PublishedPair(owner: owner, epoch: epoch.id, id: id))
        }
        return result
    }

    /// Resolve again at projection time, under the current binding. Opaque handles
    /// are not self-attesting snapshots; revocation/duplicate completion kills them.
    func literal(_ authority: ServerAuthority, publication: PublishedPair, current: Binding, field: Field) -> LiteralField? {
        lock.lock(); defer { lock.unlock() }
        guard authority.owner == owner, publication.owner == owner, let epoch = epochs[publication.epoch],
              epoch.binding == current, taskEpochs[current.scope.taskID] == epoch.id,
              let callID = epoch.publications[publication.id], let call = epoch.calls[callID], !call.invalid,
              call.publicationID == publication.id, call.response.state == .committed,
              call.terminal?.succeeds(for: call.issued.kind) == true,
              let sourceSHA256 = call.httpSourceSHA256 else { return nil }
        let bytes: Data?
        let range: Range<Int>?
        switch (call.issued.kind, field) {
        case (_, .output): bytes = call.outputToken; range = call.outputRange
        case (.execCommand, .arguments), (.applyPatch, .input): bytes = call.argumentToken; range = call.argumentRange
        default: bytes = nil; range = nil
        }
        guard let bytes, let range else { return nil }
        return LiteralField(ledger: self, owner: owner, epoch: epoch.id, publicationID: publication.id, scope: current.scope,
            callID: callID, kind: call.issued.kind, name: call.issued.name, namespace: call.issued.namespace,
            field: field, rawJSONValue: bytes, sha256: Self.sha(bytes), nativeHTTPSourceSHA256: sourceSHA256, valueRange: range)
    }

    func revoke(_ authority: ServerAuthority, scope: ScopeHandle, reason: Revocation) {
        var revoked: [NativeFactWaiter] = []
        lock.lock(); defer { lock.unlock(); Self.resume(revoked, with: .failure(NativeFactWaitFailure.scope)) }
        guard authority.owner == owner, scope.owner == owner, let epoch = epochs.removeValue(forKey: scope.epoch) else { return }
        if taskEpochs[epoch.binding.scope.taskID] == epoch.id { taskEpochs.removeValue(forKey: epoch.binding.scope.taskID) }
        revoked = takeWaiters(epoch: epoch.id)
    }
    func revokeAll(_ authority: ServerAuthority, reason: Revocation) {
        var revoked: [NativeFactWaiter] = []
        lock.lock(); defer { lock.unlock(); Self.resume(revoked, with: .failure(NativeFactWaitFailure.scope)) }
        guard authority.owner == owner else { return }
        epochs.removeAll(); taskEpochs.removeAll()
        revoked = Array(nativeFactWaiters.values); nativeFactWaiters.removeAll()
    }
    private func revokeCompletionWriter(_ writer: CompletionWriter, reason: Revocation) {
        var revoked: [NativeFactWaiter] = []
        lock.lock(); defer { lock.unlock(); Self.resume(revoked, with: .failure(NativeFactWaitFailure.scope)) }
        guard writer.owner == owner, let epoch = epochs.removeValue(forKey: writer.epoch) else { return }
        if taskEpochs[epoch.binding.scope.taskID] == epoch.id { taskEpochs.removeValue(forKey: epoch.binding.scope.taskID) }
        revoked = takeWaiters(epoch: epoch.id)
    }
    private func isCurrent(_ writer: CompletionWriter, current: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard writer.owner == owner, let epoch = epochs[writer.epoch], epoch.binding.scope == current,
              taskEpochs[current.taskID] == epoch.id else { return false }
        return true
    }
    private func isCurrent(_ field: LiteralField) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard field.owner == owner, let epoch = epochs[field.epoch], epoch.binding.scope == field.scope,
              taskEpochs[field.scope.taskID] == epoch.id,
              let callID = epoch.publications[field.publicationID], callID == field.callID,
              let call = epoch.calls[callID], !call.invalid, call.publicationID == field.publicationID,
              call.response.state == .committed, call.terminal?.succeeds(for: call.issued.kind) == true,
              call.issued.kind == field.kind, call.issued.name == field.name,
              call.issued.namespace == field.namespace else { return false }
        let token: Data?
        switch (field.kind, field.field) {
        case (_, .output): token = call.outputToken
        case (.execCommand, .arguments), (.applyPatch, .input): token = call.argumentToken
        default: token = nil
        }
        // The native HTTP source/range belongs to the snapshot's original layout.
        // Reconciliation may advance framing while retaining the exact token.
        return token == field.rawJSONValue
    }

    private func checked(_ authority: ServerAuthority, _ scope: ScopeHandle, _ binding: Binding) -> Epoch? {
        guard authority.owner == owner, scope.owner == owner, let epoch = epochs[scope.epoch],
              epoch.binding == binding, taskEpochs[binding.scope.taskID] == epoch.id else { return nil }
        return epoch
    }
    private func checked(_ authority: ServerAuthority, _ ticket: Ticket, _ binding: Binding) -> Epoch? {
        guard ticket.owner == owner else { return nil }
        return checked(authority, ScopeHandle(owner: owner, epoch: ticket.epoch), binding)
    }
    private func invalidate(_ call: Call, in epoch: Epoch) {
        call.invalid = true
        if let id = call.publicationID { epoch.publications.removeValue(forKey: id) }
        epoch.retainedBytes -= (call.argumentToken?.count ?? 0) + (call.outputToken?.count ?? 0)
        call.argumentToken = nil; call.outputToken = nil; call.publicationID = nil
        call.httpSourceSHA256 = nil; call.argumentRange = nil; call.outputRange = nil
    }
    private static func valid(_ call: IssuedCall) -> Bool {
        boundedID(call.callID) && call.namespace.map({ $0 == "functions" }) != false
            && call.name == (call.kind == .execCommand ? "exec_command" : "apply_patch")
            && !call.argumentUTF8.isEmpty && call.argumentUTF8.count <= maximumLiteralBytes
            && String(data: call.argumentUTF8, encoding: .utf8) != nil
    }
    private static func boundedID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0") }
    private static func canonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    private static func digest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func token(_ data: Data, _ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= data.count, !range.isEmpty,
              range.count <= maximumLiteralBytes else { return nil }
        return data.subdata(in: range)
    }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

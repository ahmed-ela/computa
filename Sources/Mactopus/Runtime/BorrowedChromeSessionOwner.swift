import AutomationCore
import Foundation

/// The production adapter is admitted only by ChromeDebuggingConnection. This
/// seam lets lifecycle tests use an inert transport, never a real user profile.
protocol BorrowedChromeSessionTransport: BrowserTabTransport {
    var generation: UUID { get }
    func validateConnection() async throws
    func listCandidates() async throws -> [BorrowedChromeTabCandidate]
    func attach(targetID: String) async throws -> BrowserTarget
    func detach(target: BrowserTarget) async throws
    func shutdown() async
}

extension BorrowedChromeDevToolsTransport: BorrowedChromeSessionTransport { }

struct BorrowedChromeApplicationIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let executableURL: URL
}

/// Synchronous turn revocation also fences every pending/bound mutation, not
/// just the next actor read. Children are registered before attach can suspend.
final class BorrowedChromeTurnLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var children = [UUID: BrowserTabLifetime]()

    func check() throws {
        try lock.withLock { guard valid else { throw BrowserTabBrokerError.handleMissing } }
    }

    func revoke() {
        lock.withLock {
            valid = false
            for child in children.values { child.revoke() }
            children.removeAll()
        }
    }

    fileprivate func register(_ child: BrowserTabLifetime, id: UUID) throws {
        try lock.withLock {
            guard valid else { child.revoke(); throw BrowserTabBrokerError.handleMissing }
            children[id] = child
        }
    }

    fileprivate func remove(_ id: UUID) { lock.withLock { _ = children.removeValue(forKey: id) } }
}

/// Host-created capabilities; neither model arguments nor titles/URLs grant a
/// turn, connection or target identity. A host can revoke immediately before
/// scheduling actor cleanup, just as it can revoke BrowserTabBinding.lifetime.
struct BorrowedChromeTurn: Sendable {
    let taskKey: String
    let turnID: String
    let lifetime: BorrowedChromeTurnLifetime
    fileprivate let ownerID: UUID
    fileprivate let nonce: UUID
}

struct BorrowedChromeInventoryItem: Equatable, Sendable {
    let candidateToken: UUID
    let title: String
    let url: URL
    let availability: BorrowedChromeTabCandidate.Availability

    init(candidateToken: UUID, title: String, url: URL,
         availability: BorrowedChromeTabCandidate.Availability = .unknown) {
        self.candidateToken = candidateToken
        self.title = title
        self.url = url
        self.availability = availability
    }
}

struct BorrowedChromeInventoryPage: Equatable, Sendable {
    let items: [BorrowedChromeInventoryItem]
    let nextCursor: UUID?
    let totalCount: Int
}

enum BorrowedChromeSessionOwnerError: Error, LocalizedError, Equatable {
    case disconnected
    case invalidApplication
    case invalidTurn
    case invalidCandidate
    case invalidCursor
    case invalidPageSize
    case capacityExceeded
    case invalidInventory
    case runtimeRecoveryInProgress
    case runtimeRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "The authorized Chrome connection is no longer available. Restore it through the existing connection flow before requesting tabs."
        case .invalidApplication:
            return "The Chrome application identity could not be validated. Use the native Chrome connection flow; do not substitute another application."
        case .invalidTurn:
            return "This browser capability does not belong to the active turn. Obtain a fresh tab inventory in the current turn."
        case .invalidCandidate:
            return "That candidate_token does not belong to this turn's current tab inventory. Refresh computer_v2_tabs and select an observed candidate_token."
        case .invalidCursor:
            return "Invalid tab-inventory cursor. Use only a next_cursor returned by computer_v2_tabs in the current turn's current inventory, not a page-content cursor from computer_v2_snapshot or a prior-turn cursor. Call computer_v2_tabs without cursor for a fresh inventory, then use its returned next_cursor. No tab was attached or changed by this rejected read."
        case .invalidPageSize:
            return "Invalid tab-inventory page_size. Use an integer from 1 through 100."
        case .capacityExceeded:
            return "The browser session's bounded inventory or operation capacity was exceeded. No complete inventory is established by this failure; do not claim that unreturned tabs are absent."
        case .invalidInventory:
            return "Chrome returned a tab inventory that failed validation. Refresh the inventory before selecting a tab; do not invent a replacement candidate token."
        case .runtimeRecoveryInProgress:
            return "The browser runtime is recovering. Wait for recovery to complete before requesting a fresh tab inventory; do not replay input."
        case .runtimeRecoveryFailed:
            return "The browser runtime could not recover safely. Restore the authorized Chrome connection before requesting a fresh tab inventory; do not replay input."
        }
    }
}

/// This fence is deliberately not actor-isolated: runtime failure must revoke
/// already-issued mutation permits before scheduling any asynchronous cleanup.
private final class BorrowedChromeAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var recovery: UUID?
    private var lifetimes = [UUID: BorrowedChromeTurnLifetime]()

    func check() throws {
        try lock.withLock {
            guard !closed else { throw BorrowedChromeSessionOwnerError.disconnected }
            guard recovery == nil else { throw BorrowedChromeSessionOwnerError.runtimeRecoveryInProgress }
        }
    }

    func register(_ lifetime: BorrowedChromeTurnLifetime, nonce: UUID) throws {
        try lock.withLock {
            guard !closed else { throw BorrowedChromeSessionOwnerError.disconnected }
            guard recovery == nil else { throw BorrowedChromeSessionOwnerError.runtimeRecoveryInProgress }
            lifetimes[nonce] = lifetime
        }
    }

    func remove(_ nonce: UUID) { lock.withLock { _ = lifetimes.removeValue(forKey: nonce) } }

    func suspend() throws -> UUID {
        try lock.withLock {
            guard !closed else { throw BorrowedChromeSessionOwnerError.disconnected }
            if let recovery { return recovery }
            let token = UUID()
            recovery = token
            for lifetime in lifetimes.values { lifetime.revoke() }
            lifetimes.removeAll()
            return token
        }
    }

    func require(_ token: UUID) throws {
        try lock.withLock {
            guard !closed else { throw BorrowedChromeSessionOwnerError.disconnected }
            guard recovery == token else { throw BorrowedChromeSessionOwnerError.runtimeRecoveryFailed }
        }
    }

    func resume(_ token: UUID) throws {
        try lock.withLock {
            guard !closed else { throw BorrowedChromeSessionOwnerError.disconnected }
            guard recovery == token else { throw BorrowedChromeSessionOwnerError.runtimeRecoveryFailed }
            recovery = nil
        }
    }

    func close() {
        lock.withLock {
            closed = true
            recovery = nil
            for lifetime in lifetimes.values { lifetime.revoke() }
            lifetimes.removeAll()
        }
    }
}

/// Owns a connection and its attached protocol sessions, NEVER the browser,
/// process, profile, window or user tabs. There is no activate/close API here.
actor BorrowedChromeSessionOwner {
    private struct InventoryEntry {
        let token: UUID
        let candidate: BorrowedChromeTabCandidate
        let bytes: Int
    }

    private struct Inventory {
        let entries: [InventoryEntry]
        let bytes: Int
        var cursors: [UUID: Int] = [:]
    }

    private struct Reservation {
        let id: UUID
        let turnNonce: UUID
        let lifetime: BrowserTabLifetime
        var target: BrowserTarget?
        var binding: BrowserTabBinding?
        var releaseTask: Task<Void, Error>?
    }

    nonisolated let application: BorrowedChromeApplicationIdentity
    nonisolated let generation: UUID
    private nonisolated let admission = BorrowedChromeAdmission()
    private let ownerID = UUID()
    private let transport: any BorrowedChromeSessionTransport
    private let broker: BrowserTabSessionBroker
    private let consent: ChromeDebuggingConsent
    private let verifyIdentity: @Sendable () throws -> Void
    private var turns = [UUID: BorrowedChromeTurn]()
    private var inventories = [UUID: Inventory]()
    private var reservations = [String: Reservation]()
    private var operations = [UUID: UUID]()
    private var closed = false
    private var shutdownTask: Task<Void, Never>?
    private var recoveryToken: UUID?
    private var recoveredToken: UUID?
    private var recoveryWaiter: CheckedContinuation<Void, Error>?
    private var recoveryWork: Task<Void, Never>?
    private var recoveryDeadline: Task<Void, Never>?

    /// Internal dependency seam. Real callers use connect(), which captures the
    /// exact PID/launch/listener/file authority rather than trusting this label.
    init(
        application: BorrowedChromeApplicationIdentity,
        transport: any BorrowedChromeSessionTransport,
        consent: ChromeDebuggingConsent,
        verifyIdentity: @escaping @Sendable () throws -> Void
    ) throws {
        guard application.processIdentifier > 0,
              application.bundleIdentifier == "com.google.Chrome",
              application.executableURL.isFileURL,
              application.executableURL.path.hasPrefix("/") else {
            throw BorrowedChromeSessionOwnerError.invalidApplication
        }
        try consent.check()
        try verifyIdentity()
        self.application = application
        self.transport = transport
        self.consent = consent
        self.verifyIdentity = verifyIdentity
        generation = transport.generation
        broker = BrowserTabSessionBroker(
            transport: transport, browserGeneration: transport.generation, ownership: .borrowed
        )
    }

    deinit {
        consent.revoke()
        for turn in turns.values { turn.lifetime.revoke() }
        for reservation in reservations.values { reservation.lifetime.revoke() }
        if shutdownTask == nil {
            let broker = broker, transport = transport
            Task { await broker.invalidateAll(); await transport.shutdown() }
        }
    }

    static func connect(
        application: BorrowedChromeApplicationIdentity,
        explicitlyApprovedUserDataDirectory: URL,
        consent: ChromeDebuggingConsent
    ) async throws -> BorrowedChromeSessionOwner {
        guard application.bundleIdentifier == "com.google.Chrome" else {
            throw BorrowedChromeSessionOwnerError.invalidApplication
        }
        let authority = try ChromeDebuggingConnectionAuthority.bind(
            processIdentifier: application.processIdentifier,
            expectedExecutableURL: application.executableURL,
            explicitlyApprovedUserDataDirectory: explicitlyApprovedUserDataDirectory,
            consent: consent
        )
        let transport = try await ChromeDebuggingConnection.connect(authority: authority)
        do {
            try Task.checkCancellation()
            return try BorrowedChromeSessionOwner(
                application: application, transport: transport, consent: consent,
                verifyIdentity: { try authority.validate() }
            )
        } catch {
            await transport.shutdown()
            throw error
        }
    }

    func beginTurn(taskKey: String, turnID: String) throws -> BorrowedChromeTurn {
        try checkOwner()
        guard Self.validScope(taskKey), Self.validScope(turnID) else {
            throw BorrowedChromeSessionOwnerError.invalidTurn
        }
        guard !turns.values.contains(where: { $0.taskKey == taskKey }) else {
            throw BrowserTabBrokerError.operationInProgress
        }
        guard turns.count < 16, operations.count < 16 else {
            throw BorrowedChromeSessionOwnerError.capacityExceeded
        }
        let turn = BorrowedChromeTurn(
            taskKey: taskKey, turnID: turnID, lifetime: BorrowedChromeTurnLifetime(), ownerID: ownerID, nonce: UUID()
        )
        try admission.register(turn.lifetime, nonce: turn.nonce)
        turns[turn.nonce] = turn
        return turn
    }

    /// No cursor refreshes the inventory and invalidates all prior candidate
    /// and cursor tokens for this turn. Overflow rejects the whole inventory.
    func listTabs(
        turn: BorrowedChromeTurn, cursor: UUID? = nil, pageSize: Int = 25
    ) async throws -> BorrowedChromeInventoryPage {
        guard (1...100).contains(pageSize) else { throw BorrowedChromeSessionOwnerError.invalidPageSize }
        let operation = try beginOperation(turn)
        defer { endOperation(turn, operation) }
        do {
            try await checkConnection(turn)
            if let cursor {
                guard let index = inventories[turn.nonce]?.cursors[cursor] else {
                    throw BorrowedChromeSessionOwnerError.invalidCursor
                }
                return try page(turn, start: index, size: pageSize)
            }
            inventories.removeValue(forKey: turn.nonce)
            let candidates = try await transport.listCandidates()
            try checkTurn(turn)
            guard candidates.count <= 2_048 else { throw BorrowedChromeSessionOwnerError.capacityExceeded }
            var identifiers = Set<String>()
            var entries = [InventoryEntry]()
            var bytes = 0
            for candidate in candidates {
                guard Self.validTargetID(candidate.targetID),
                      candidate.title.utf8.count <= 16_384,
                      candidate.url.absoluteString.utf8.count <= 16_384,
                      ["http", "https", "file"].contains(candidate.url.scheme ?? ""),
                      identifiers.insert(candidate.targetID).inserted else {
                    throw BorrowedChromeSessionOwnerError.invalidInventory
                }
                let entryBytes = Self.metadataBytes(candidate)
                bytes += entryBytes
                guard bytes + retainedMetadataBytes <= 1_048_576 else {
                    throw BorrowedChromeSessionOwnerError.capacityExceeded
                }
                entries.append(InventoryEntry(token: UUID(), candidate: candidate, bytes: entryBytes))
            }
            guard candidates.count + retainedTargetCount <= 2_048 else {
                throw BorrowedChromeSessionOwnerError.capacityExceeded
            }
            inventories[turn.nonce] = Inventory(entries: entries, bytes: bytes)
            return try page(turn, start: 0, size: pageSize)
        } catch {
            await discardIfConnectionFailed(error)
            throw error
        }
    }

    /// Host-only lookup in the current inventory. Titles and URLs never become
    /// identities, and an invented or pre-refresh token cannot resolve here.
    func observedCandidate(turn: BorrowedChromeTurn, candidateToken: UUID) throws -> BorrowedChromeTabCandidate {
        try checkTurn(turn)
        guard let candidate = inventories[turn.nonce]?.entries.first(where: { $0.token == candidateToken })?.candidate else {
            throw BorrowedChromeSessionOwnerError.invalidCandidate
        }
        return candidate
    }

    /// Host-only continuation lookup after a new inventory. Exact target IDs
    /// avoid substituting a similarly named tab or another signed-in account.
    func continuationCandidate(turn: BorrowedChromeTurn, targetID: String) throws -> BorrowedChromeInventoryItem? {
        try checkTurn(turn)
        guard let inventory = inventories[turn.nonce] else { throw BorrowedChromeSessionOwnerError.invalidCursor }
        guard let entry = inventory.entries.first(where: { $0.candidate.targetID == targetID }) else { return nil }
        return .init(candidateToken: entry.token, title: entry.candidate.title, url: entry.candidate.url,
                     availability: entry.candidate.availability)
    }

    /// Use only with a newly completed listTabs refresh, not as a live probe.
    func availableTargetIDs(turn: BorrowedChromeTurn) throws -> Set<String> {
        try checkTurn(turn)
        guard let inventory = inventories[turn.nonce] else { throw BorrowedChromeSessionOwnerError.invalidCursor }
        return Set(inventory.entries.compactMap { $0.candidate.availability == .available ? $0.candidate.targetID : nil })
    }

    func bind(turn: BorrowedChromeTurn, candidateToken: UUID) async throws -> BrowserTabBinding {
        let operation = try beginOperation(turn)
        defer { endOperation(turn, operation) }
        guard let candidate = inventories[turn.nonce]?.entries.first(where: { $0.token == candidateToken })?.candidate else {
            throw BorrowedChromeSessionOwnerError.invalidCandidate
        }
        if let existing = reservations[candidate.targetID] {
            guard existing.turnNonce == turn.nonce, let binding = existing.binding else {
                throw BrowserTabBrokerError.operationInProgress
            }
            do {
                try await checkConnection(turn)
                try binding.lifetime.check()
                return binding
            } catch {
                // Reusing a handle must observe connection death just like a
                // fresh attachment or cached inventory read, revoking every
                // capability on this connection before returning the error.
                await discardIfConnectionFailed(error)
                throw error
            }
        }
        guard reservations.count < 16, retainedTargetCount < 2_048 else {
            throw BorrowedChromeSessionOwnerError.capacityExceeded
        }
        let id = UUID(), lifetime = BrowserTabLifetime()
        try turn.lifetime.register(lifetime, id: id)
        // Reserve BEFORE the first suspension. Failed competing callers must
        // never attach, then detach a session another task already owns.
        reservations[candidate.targetID] = Reservation(id: id, turnNonce: turn.nonce, lifetime: lifetime)
        var attachedTarget: BrowserTarget?
        var publishedBinding: BrowserTabBinding?
        do {
            return try await withTaskCancellationHandler {
                try await checkConnection(turn)
                let prior = reservations.filter { $0.value.turnNonce == turn.nonce && $0.value.id != id }
                for (targetID, reservation) in prior {
                    try await release(targetID: targetID, reservation: reservation, taskKey: turn.taskKey)
                }
                try checkReservation(turn, targetID: candidate.targetID, id: id)
                let target = try await transport.attach(targetID: candidate.targetID)
                attachedTarget = target
                try checkReservation(turn, targetID: candidate.targetID, id: id)
                guard target.targetID == candidate.targetID, target.webSocketURL == nil,
                      target.attachedSession?.connectionGeneration == generation,
                      target.instanceToken == target.attachedSession?.incarnation.uuidString else {
                    throw BrowserTabBrokerError.targetReplaced
                }
                guard retainedMetadataBytes + Self.metadataBytes(target) <= 1_048_576 else {
                    throw BorrowedChromeSessionOwnerError.capacityExceeded
                }
                reservations[candidate.targetID]?.target = target
                let binding = try await broker.bindBorrowed(
                    taskKey: turn.taskKey, processIdentifier: application.processIdentifier,
                    target: target, lifetime: lifetime
                )
                publishedBinding = binding
                try checkReservation(turn, targetID: candidate.targetID, id: id)
                reservations[candidate.targetID]?.binding = binding
                return binding
            } onCancel: { lifetime.revoke() }
        } catch {
            lifetime.revoke()
            if let binding = publishedBinding { try? await broker.revoke(taskKey: turn.taskKey, binding: binding) }
            if let reservation = reservations[candidate.targetID], reservation.id == id {
                var cleanup = reservation
                // Even a cancelled attach can return its exact session after
                // turn revocation. Keep its reservation until cleanup finishes.
                cleanup.target = cleanup.target ?? attachedTarget
                try? await release(targetID: candidate.targetID, reservation: cleanup, taskKey: turn.taskKey)
            }
            await discardIfConnectionFailed(error)
            throw error
        }
    }

    func snapshot(
        turn: BorrowedChromeTurn, binding: BrowserTabBinding, query: String? = nil
    ) async throws -> BrowserTabObservation {
        try await snapshot(turn: turn, binding: binding, read: SemanticReadRequest(query: query))
    }

    func snapshot(
        turn: BorrowedChromeTurn, binding: BrowserTabBinding, read: SemanticReadRequest
    ) async throws -> BrowserTabObservation {
        try await withBinding(turn, binding: binding) {
            try await self.broker.snapshot(
                taskKey: turn.taskKey, binding: binding, bundleIdentifier: self.application.bundleIdentifier, read: read
            )
        }
    }

    func perform(
        turn: BorrowedChromeTurn, binding: BrowserTabBinding, snapshot: BrowserTabSnapshot,
        elementIndex: Int, action: String, verificationPlan: BrowserActionVerification.Plan? = nil
    ) async throws {
        try await withBinding(turn, binding: binding) {
            try await self.broker.perform(
                taskKey: turn.taskKey, binding: binding, snapshot: snapshot, elementIndex: elementIndex, action: action,
                verificationPlan: verificationPlan
            )
        }
    }

    func setText(
        turn: BorrowedChromeTurn, binding: BrowserTabBinding, snapshot: BrowserTabSnapshot,
        elementIndex: Int, text: String, verificationPlan: BrowserActionVerification.Plan? = nil
    ) async throws {
        try await withBinding(turn, binding: binding) {
            try await self.broker.setText(
                taskKey: turn.taskKey, binding: binding, snapshot: snapshot, elementIndex: elementIndex, text: text,
                verificationPlan: verificationPlan
            )
        }
    }

    func revoke(turn: BorrowedChromeTurn) async {
        guard turn.ownerID == ownerID, turns[turn.nonce]?.lifetime === turn.lifetime else { return }
        turn.lifetime.revoke()
        admission.remove(turn.nonce)
        turns.removeValue(forKey: turn.nonce)
        inventories.removeValue(forKey: turn.nonce)
        let owned = reservations.filter { $0.value.turnNonce == turn.nonce }
        for reservation in owned.values { reservation.lifetime.revoke() }
        for (targetID, reservation) in owned where reservation.target != nil {
            try? await release(targetID: targetID, reservation: reservation, taskKey: turn.taskKey)
        }
        // A target-less reservation belongs to a suspended attach. Its original
        // operation alone releases it when the exact returned session is known.
    }

    func disconnect() async {
        invalidate()
        await shutdownTask?.value
    }

    nonisolated func suspendForRuntimeRecovery() throws -> UUID {
        try admission.suspend()
    }

    /// Drain host tasks as well as actor reservations. A cancelled attach may
    /// still return an exact session; it must finish its detach before reuse.
    /// The deadline closes this owner rather than waiting forever on a broken
    /// peer. It never restarts the wire or replays a mutation.
    func quiesceForRuntimeRecovery(
        _ token: UUID,
        timeout: Duration = .seconds(15),
        drainHostWork: @escaping @Sendable () async -> Void
    ) async throws {
        try admission.require(token)
        guard recoveryToken == nil, recoveredToken == nil else {
            throw BorrowedChromeSessionOwnerError.runtimeRecoveryInProgress
        }
        recoveryToken = token
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                recoveryWaiter = continuation
                recoveryDeadline = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.failRuntimeRecovery(token)
                }
                recoveryWork = Task { [weak self] in
                    await drainHostWork()
                    await self?.finishRuntimeQuiescence(token)
                }
            }
        } onCancel: {
            Task { await self.failRuntimeRecovery(token) }
        }
    }

    /// Only the host owning the same connection attempt can reopen admission,
    /// after it has checked identity again following quiescence's suspension.
    func resumeAfterRuntimeRecovery(_ token: UUID) throws {
        try checkOwner(checkAdmission: false)
        try admission.require(token)
        guard recoveredToken == token, turns.isEmpty, operations.isEmpty, reservations.isEmpty else {
            throw BorrowedChromeSessionOwnerError.runtimeRecoveryFailed
        }
        try admission.resume(token)
        recoveredToken = nil
    }

    private func finishRuntimeQuiescence(_ token: UUID) async {
        do {
            try admission.require(token)
            guard recoveryToken == token else { return }
            for turn in Array(turns.values) {
                await revoke(turn: turn)
                try admission.require(token)
                guard recoveryToken == token else { return }
            }
            guard turns.isEmpty, operations.isEmpty, reservations.isEmpty else {
                throw BorrowedChromeSessionOwnerError.runtimeRecoveryFailed
            }
            inventories.removeAll()
            try await transport.validateConnection()
            try admission.require(token)
            guard recoveryToken == token else { return }
            try checkOwner(checkAdmission: false)
            recoveredToken = token
            recoveryToken = nil
            recoveryDeadline?.cancel()
            recoveryDeadline = nil
            recoveryWork = nil
            let waiter = recoveryWaiter
            recoveryWaiter = nil
            waiter?.resume()
        } catch {
            failRuntimeRecovery(token)
        }
    }

    private func failRuntimeRecovery(_ token: UUID) {
        guard recoveryToken == token || recoveredToken == token else { return }
        invalidate()
    }

    private func withBinding<T: Sendable>(
        _ turn: BorrowedChromeTurn, binding: BrowserTabBinding,
        operation: () async throws -> T
    ) async throws -> T {
        let ticket = try beginOperation(turn)
        defer { endOperation(turn, ticket) }
        do {
            try requireBinding(turn, binding)
            try await checkConnection(turn)
            try requireBinding(turn, binding)
            let result = try await operation()
            try requireBinding(turn, binding)
            return result
        } catch {
            await discardIfConnectionFailed(error)
            throw error
        }
    }

    private func requireBinding(_ turn: BorrowedChromeTurn, _ binding: BrowserTabBinding) throws {
        try checkTurn(turn)
        guard let reservation = reservations[binding.targetID], reservation.turnNonce == turn.nonce,
              let current = reservation.binding, current.handle == binding.handle,
              current.targetInstanceToken == binding.targetInstanceToken,
              current.lifetime === binding.lifetime, binding.taskKey == turn.taskKey,
              binding.browserGeneration == generation, binding.processIdentifier == application.processIdentifier,
              binding.ownership == .borrowed else { throw BrowserTabBrokerError.handleMissing }
        try binding.lifetime.check()
    }

    private func release(targetID: String, reservation: Reservation, taskKey: String) async throws {
        guard let current = reservations[targetID], current.id == reservation.id else { return }
        reservation.lifetime.revoke()
        let cleanup: Task<Void, Error>
        if let existing = current.releaseTask {
            cleanup = existing
        } else {
            let broker = broker, transport = transport
            cleanup = Task {
                if let binding = reservation.binding { try? await broker.revoke(taskKey: taskKey, binding: binding) }
                // Cancellation of the action must not cancel its exact detach.
                if let target = reservation.target { try await transport.detach(target: target) }
            }
            // Publish before awaiting so revoke and a late failure share one
            // exact-session detach, not two racing cleanup attempts.
            reservations[targetID]?.releaseTask = cleanup
        }
        do {
            try await cleanup.value
            if reservations[targetID]?.id == reservation.id { reservations.removeValue(forKey: targetID) }
            turns[reservation.turnNonce]?.lifetime.remove(reservation.id)
        } catch {
            // Uncertain detach cannot release the lease for reuse. Tear down
            // only this connection, which releases its sessions, not user tabs.
            await disconnect()
            throw error
        }
    }

    private func page(_ turn: BorrowedChromeTurn, start: Int, size: Int) throws -> BorrowedChromeInventoryPage {
        try checkTurn(turn)
        guard var inventory = inventories[turn.nonce], start >= 0, start <= inventory.entries.count else {
            throw BorrowedChromeSessionOwnerError.invalidCursor
        }
        let limit = min(start + size, inventory.entries.count)
        var end = start
        var items = [BorrowedChromeInventoryItem]()
        // UUID text has a fixed JSON size. Reserve the exact continuation
        // envelope while growing the prefix; publish a cursor only afterward.
        let sizingCursor = UUID()
        while end < limit {
            let entry = inventory.entries[end]
            let item = BorrowedChromeInventoryItem(
                candidateToken: entry.token, title: entry.candidate.title, url: entry.candidate.url,
                availability: entry.candidate.availability
            )
            let proposed = BorrowedChromeInventoryPage(
                items: items + [item], nextCursor: end + 1 < inventory.entries.count ? sizingCursor : nil,
                totalCount: inventory.entries.count
            )
            guard try BorrowedChromeInventoryPresentation.fits(proposed) else { break }
            items.append(item)
            end += 1
        }
        guard !items.isEmpty || inventory.entries.isEmpty else {
            throw BorrowedChromeSessionOwnerError.capacityExceeded
        }
        let cursor: UUID?
        if end < inventory.entries.count {
            cursor = inventory.cursors.first(where: { $0.value == end })?.key ?? UUID()
            inventory.cursors[cursor!] = end
        } else { cursor = nil }
        let result = BorrowedChromeInventoryPage(items: items, nextCursor: cursor, totalCount: inventory.entries.count)
        guard try BorrowedChromeInventoryPresentation.fits(result) else {
            throw BorrowedChromeSessionOwnerError.capacityExceeded
        }
        inventories[turn.nonce] = inventory
        return result
    }

    private func checkOwner(checkAdmission: Bool = true) throws {
        try Task.checkCancellation()
        guard !closed else { throw BorrowedChromeSessionOwnerError.disconnected }
        do { try consent.check(); try verifyIdentity() }
        catch { invalidate(); throw error }
        if checkAdmission { try admission.check() }
    }

    private func checkTurn(_ turn: BorrowedChromeTurn) throws {
        try checkOwner()
        guard turn.ownerID == ownerID, let current = turns[turn.nonce],
              current.taskKey == turn.taskKey, current.turnID == turn.turnID,
              current.lifetime === turn.lifetime else { throw BorrowedChromeSessionOwnerError.invalidTurn }
        try turn.lifetime.check()
    }

    private func checkConnection(_ turn: BorrowedChromeTurn) async throws {
        try checkTurn(turn)
        try await transport.validateConnection()
        try checkTurn(turn)
    }

    private func checkReservation(_ turn: BorrowedChromeTurn, targetID: String, id: UUID) throws {
        try checkTurn(turn)
        guard let reservation = reservations[targetID], reservation.id == id else {
            throw BrowserTabBrokerError.handleMissing
        }
        try reservation.lifetime.check()
    }

    private func beginOperation(_ turn: BorrowedChromeTurn) throws -> UUID {
        try checkTurn(turn)
        guard operations[turn.nonce] == nil else { throw BrowserTabBrokerError.operationInProgress }
        // Revocation invalidates results immediately, but suspended requests
        // keep their slot until completion. Restarting turns cannot accumulate
        // unbounded abandoned inventory/attach continuations.
        guard operations.count < 16 else { throw BorrowedChromeSessionOwnerError.capacityExceeded }
        let id = UUID()
        operations[turn.nonce] = id
        return id
    }

    private func endOperation(_ turn: BorrowedChromeTurn, _ id: UUID) {
        if operations[turn.nonce] == id { operations.removeValue(forKey: turn.nonce) }
    }

    private func discardIfConnectionFailed(_ original: Error) async {
        guard !closed, !(original is CancellationError), !Task.isCancelled else { return }
        do { try await transport.validateConnection(); try checkOwner(checkAdmission: false) }
        catch { await disconnect() }
    }

    private func invalidate() {
        guard !closed else { return }
        closed = true
        admission.close()
        recoveryToken = nil
        recoveredToken = nil
        recoveryDeadline?.cancel()
        recoveryDeadline = nil
        recoveryWork?.cancel()
        recoveryWork = nil
        let waiter = recoveryWaiter
        recoveryWaiter = nil
        waiter?.resume(throwing: BorrowedChromeSessionOwnerError.runtimeRecoveryFailed)
        consent.revoke()
        for turn in turns.values { turn.lifetime.revoke() }
        for reservation in reservations.values { reservation.lifetime.revoke() }
        turns.removeAll()
        inventories.removeAll()
        reservations.removeAll()
        operations.removeAll()
        let broker = broker, transport = transport
        shutdownTask = Task { await broker.invalidateAll(); await transport.shutdown() }
    }

    private var retainedMetadataBytes: Int {
        inventories.values.reduce(0) { $0 + $1.bytes }
            + reservations.values.reduce(0) { $0 + ($1.target.map(Self.metadataBytes) ?? 0) }
    }

    private var retainedTargetCount: Int {
        inventories.values.reduce(0) { $0 + $1.entries.count } + reservations.count
    }

    private static func metadataBytes(_ candidate: BorrowedChromeTabCandidate) -> Int {
        // Includes conservative fixed token/cursor/index bookkeeping overhead.
        256 + candidate.targetID.utf8.count + candidate.title.utf8.count + candidate.url.absoluteString.utf8.count
    }

    private static func metadataBytes(_ target: BrowserTarget) -> Int {
        512 + target.targetID.utf8.count + target.title.utf8.count + target.url.absoluteString.utf8.count
    }

    private static func validScope(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 32 }
    }

    private static func validTargetID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

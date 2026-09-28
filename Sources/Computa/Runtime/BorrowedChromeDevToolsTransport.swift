import Foundation

struct BorrowedChromeTabCandidate: Equatable, Sendable {
    enum Availability: String, Sendable {
        case available, busy, unknown
    }

    let targetID: String
    let title: String
    let url: URL
    let availability: Availability

    init(targetID: String, title: String, url: URL, availability: Availability = .unknown) {
        self.targetID = targetID
        self.title = title
        self.url = url
        self.availability = availability
    }
}

/// Fixed operation metadata only. Do not retain command parameters, target or
/// session identities, page contents, URLs, or the debugging endpoint in errors.
struct BorrowedChromeCommandTimeout: Error, Equatable, LocalizedError, Sendable {
    enum Stage: String, Sendable {
        case inventory
        case attachment
        case targetValidation = "target validation"
        case documentObservation = "document observation or action"
        case detachment
    }

    let stage: Stage
    let method: String

    var errorDescription: String? {
        BrowserCDPConnectionError.deadlineExceeded.localizedDescription
            + " Stage: \(stage.rawValue); command: \(method)."
            + " The connection was closed and the request was not replayed; its old tab inventory is no longer valid."
    }
}

/// Adapter only: the host must first obtain explicit debugging consent and
/// validate an endpoint against the exact running browser PID/launch identity.
/// This class never discovers endpoints, changes browser settings, or adopts a
/// browser into the process/profile-owning ChromeTabBroker.
actor BorrowedChromeDevToolsTransport: BrowserTabTransport {
    private let connection: BrowserCDPConnection
    nonisolated let generation: UUID
    private let verifyBrowser: @Sendable () throws -> Void
    private let requirePermission: @Sendable () throws -> Void
    private var attached = [String: BrowserTarget]()
    private var attaching = Set<String>()
    private var eventDrain: Task<Void, Never>?
    private var isClosed = false
    private let operations = BrowserCDPDocumentOperations()

    init(
        connection: BrowserCDPConnection,
        generation: UUID,
        verifyBrowser: @escaping @Sendable () throws -> Void,
        requirePermission: @escaping @Sendable () throws -> Void = requireBrowserAccessibilityPermission
    ) {
        self.connection = connection
        self.generation = generation
        self.verifyBrowser = verifyBrowser
        self.requirePermission = requirePermission
    }

    deinit { eventDrain?.cancel() }

    /// Checks the reader's terminal state directly rather than relying on the
    /// asynchronous diagnostic event drain to invalidate cached host metadata.
    func validateConnection() async throws {
        try checkBrowser()
        try await connection.checkConnection()
        try checkBrowser()
    }

    func listCandidates() async throws -> [BorrowedChromeTabCandidate] {
        try checkBrowser()
        let data = try await command(method: "Target.getTargets", stage: .inventory)
        try checkBrowser()
        let result = try decode(data)
        guard let infos = result["targetInfos"] as? [[String: Any]], infos.count <= 2_048 else {
            throw BrowserTabBrokerError.malformedDevToolsResponse("the browser target list is missing or too large")
        }
        var identifiers = Set<String>()
        var candidates = [BorrowedChromeTabCandidate]()
        for info in infos where info["type"] as? String == "page" {
            let candidate = try parseCandidate(info)
            guard identifiers.insert(candidate.targetID).inserted else {
                throw BrowserTabBrokerError.malformedDevToolsResponse("duplicate browser target identity")
            }
            if allowedDocument(candidate.url) { candidates.append(candidate) }
        }
        return candidates
    }

    /// Exact target ID selection only. Never select or recover by matching URL
    /// or title: multiple user tabs may have identical visible metadata.
    func attach(targetID: String) async throws -> BrowserTarget {
        try checkBrowser()
        try requirePermission()
        guard Self.validID(targetID) else {
            throw BrowserTabBrokerError.malformedDevToolsResponse("invalid selected target ID")
        }
        if attached[targetID] != nil {
            guard let current = try await target(id: targetID) else { throw BrowserTabBrokerError.targetClosed }
            return current
        }
        guard attached.count + attaching.count < 16 else {
            throw BrowserTabBrokerError.browserUnavailable("too many borrowed target sessions")
        }
        guard attaching.insert(targetID).inserted else { throw BrowserTabBrokerError.operationInProgress }
        defer { attaching.remove(targetID) }
        let info = try await targetInfo(targetID)
        guard allowedDocument(info.url) else { throw BrowserTabBrokerError.unsupportedAction("binding this document scheme") }
        let params = try JSONSerialization.data(withJSONObject: ["targetId": targetID, "flatten": true])
        do {
            let data = try await command(
                method: "Target.attachToTarget", params: params, stage: .attachment
            )
            let result = try decode(data)
            guard let sessionID = result["sessionId"] as? String, Self.validID(sessionID) else {
                throw BrowserTabBrokerError.malformedDevToolsResponse("attach returned no session identity")
            }
            try await connection.checkSession(sessionID)
            try checkBrowser()
            let identity = BrowserAttachedSession(
                connectionGeneration: generation, sessionID: sessionID, incarnation: UUID()
            )
            let target = BrowserTarget(targetID: targetID, title: info.title, url: info.url, attachedSession: identity)
            attached[targetID] = target
            guard let current = try await self.target(id: targetID) else { throw BrowserTabBrokerError.targetClosed }
            return current
        } catch {
            // An interrupted attach may already have created a session whose
            // reply was not received. Close this connection to detach every
            // session it owns; never reconnect/retry the uncertain request.
            await shutdown()
            throw error
        }
    }

    func target(id: String) async throws -> BrowserTarget? {
        try checkBrowser()
        guard let existing = attached[id], let session = existing.attachedSession else { return nil }
        try await connection.checkSession(session.sessionID)
        let info = try await targetInfo(id)
        try await connection.checkSession(session.sessionID)
        try checkBrowser()
        guard attached[id]?.attachedSession == session else { throw BrowserTabBrokerError.targetReplaced }
        guard allowedDocument(info.url) else { throw BrowserTabBrokerError.staleDocument }
        let refreshed = BrowserTarget(targetID: id, title: info.title, url: info.url, attachedSession: session)
        attached[id] = refreshed
        return refreshed
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        let channel = try await channel(for: target)
        let result = try await operations.observe(target: target, socket: channel)
        try await requireCurrent(target)
        return result
    }

    func press(
        target: BrowserTarget, backendNodeID: Int64,
        document: BrowserDocumentObservation, permit: BrowserMutationPermit
    ) async throws {
        let channel = try await channel(for: target)
        try await operations.press(
            target: target, backendNodeID: backendNodeID, document: document,
            permit: permit, socket: channel
        )
        do { try await requireCurrent(target) }
        catch { throw BrowserMutationFailure(dispatchState: .dispatched, underlyingError: error) }
    }

    func setText(
        target: BrowserTarget, backendNodeID: Int64, text: String,
        document: BrowserDocumentObservation, permit: BrowserMutationPermit
    ) async throws {
        let channel = try await channel(for: target)
        try await operations.setText(
            target: target, backendNodeID: backendNodeID, text: text,
            document: document, permit: permit, socket: channel
        )
        do { try await requireCurrent(target) }
        catch { throw BrowserMutationFailure(dispatchState: .dispatched, underlyingError: error) }
    }

    func detach(target: BrowserTarget) async throws {
        guard let session = target.attachedSession, attached[target.targetID]?.attachedSession == session else {
            throw BrowserTabBrokerError.targetReplaced
        }
        attached.removeValue(forKey: target.targetID)
        await connection.invalidateSession(session.sessionID)
        let params = try JSONSerialization.data(withJSONObject: ["sessionId": session.sessionID])
        let connection = self.connection, verifyBrowser = self.verifyBrowser
        let cleanup = Task {
            do {
                return try await connection.command(method: "Target.detachFromTarget", params: params, beforeEnqueue: verifyBrowser)
            } catch BrowserCDPConnectionError.deadlineExceeded {
                throw BorrowedChromeCommandTimeout(stage: .detachment, method: "Target.detachFromTarget")
            }
        }
        do { _ = try await cleanup.value }
        catch {
            // Local authority is already revoked. If Chrome-side release is
            // uncertain, tear down this connection instead of abandoning an
            // attached session we can no longer account for.
            await shutdown()
            throw error
        }
    }

    func shutdown() async {
        isClosed = true
        attached.removeAll()
        eventDrain?.cancel()
        eventDrain = nil
        await connection.close()
    }

    func createTarget(url: URL) throws -> BrowserTarget { throw BrowserTabBrokerError.ownershipMismatch }
    func activateTarget(id: String) throws { throw BrowserTabBrokerError.ownershipMismatch }
    func closeTarget(target: BrowserTarget) throws { throw BrowserTabBrokerError.ownershipMismatch }

    private func checkBrowser() throws {
        try Task.checkCancellation()
        guard !isClosed else { throw BrowserTabBrokerError.browserGenerationChanged }
        try verifyBrowser()
        try requirePermission()
        startEventDrain()
    }

    private func startEventDrain() {
        guard eventDrain == nil else { return }
        let events = connection.events
        eventDrain = Task { [weak self] in
            // The connection reader applies detach/destruction fences before
            // yielding. This consumer prevents unneeded diagnostic events from
            // accumulating; it is not the source of authorization state.
            do {
                for try await _ in events {
                    guard self != nil, !Task.isCancelled else { return }
                }
            } catch { }
            await self?.connectionEnded()
        }
    }

    private func connectionEnded() {
        isClosed = true
        attached.removeAll()
    }

    private func enqueueValidation() -> @Sendable () throws -> Void {
        let verifyBrowser = self.verifyBrowser, requirePermission = self.requirePermission
        return { try verifyBrowser(); try requirePermission() }
    }

    private func command(
        method: String, params: Data = Data("{}".utf8), stage: BorrowedChromeCommandTimeout.Stage
    ) async throws -> Data {
        do {
            return try await connection.command(method: method, params: params, beforeEnqueue: enqueueValidation())
        } catch BrowserCDPConnectionError.deadlineExceeded {
            throw BorrowedChromeCommandTimeout(stage: stage, method: method)
        }
    }

    private func channel(for target: BrowserTarget) async throws -> AttachedBrowserDocumentChannel {
        try requirePermission()
        try await requireCurrent(target)
        guard let session = target.attachedSession else { throw BrowserTabBrokerError.ownershipMismatch }
        let verifyBrowser = self.verifyBrowser, requirePermission = self.requirePermission
        return AttachedBrowserDocumentChannel(
            connection: connection, sessionID: session.sessionID,
            validate: { try verifyBrowser(); try requirePermission() },
            verifyBrowser: verifyBrowser
        )
    }

    private func requireCurrent(_ target: BrowserTarget) async throws {
        guard let session = target.attachedSession, session.connectionGeneration == generation,
              target.webSocketURL == nil,
              attached[target.targetID]?.attachedSession == session,
              target.instanceToken == session.incarnation.uuidString else {
            throw BrowserTabBrokerError.targetReplaced
        }
        guard let current = try await self.target(id: target.targetID), current.attachedSession == session else {
            throw BrowserTabBrokerError.targetReplaced
        }
    }

    private func targetInfo(_ id: String) async throws -> BorrowedChromeTabCandidate {
        let params = try JSONSerialization.data(withJSONObject: ["targetId": id])
        let data = try await command(method: "Target.getTargetInfo", params: params, stage: .targetValidation)
        try checkBrowser()
        guard let info = try decode(data)["targetInfo"] as? [String: Any] else {
            throw BrowserTabBrokerError.malformedDevToolsResponse("missing selected target info")
        }
        let candidate = try parseCandidate(info)
        guard candidate.targetID == id else { throw BrowserTabBrokerError.targetReplaced }
        return candidate
    }

    private func parseCandidate(_ info: [String: Any]) throws -> BorrowedChromeTabCandidate {
        guard info["type"] as? String == "page", let id = info["targetId"] as? String, Self.validID(id),
              let rawURL = info["url"] as? String, rawURL.utf8.count <= 16_384,
              let url = URL(string: rawURL), let title = info["title"] as? String, title.utf8.count <= 16_384 else {
            throw BrowserTabBrokerError.malformedDevToolsResponse("invalid page target metadata")
        }
        let availability: BorrowedChromeTabCandidate.Availability
        if let attached = info["attached"] as? Bool { availability = attached ? .busy : .available }
        else { availability = .unknown }
        return BorrowedChromeTabCandidate(targetID: id, title: title, url: url, availability: availability)
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserTabBrokerError.malformedDevToolsResponse("invalid browser command result")
        }
        return object
    }

    private func allowedDocument(_ url: URL) -> Bool { ["http", "https", "file"].contains(url.scheme ?? "") }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

/// All document commands, including remote-object cleanup, are bound to this
/// original session. No URL lookup, implicit reattachment or global input.
private struct AttachedBrowserDocumentChannel: BrowserDocumentChannel {
    let connection: BrowserCDPConnection
    let sessionID: String
    let validate: @Sendable () throws -> Void
    let verifyBrowser: @Sendable () throws -> Void

    func request(method: String, params: Data, permit: BrowserMutationPermit?) async throws -> Data {
        try validate()
        try await connection.checkSession(sessionID)
        do {
            return try await connection.command(
                method: method, params: params, sessionID: sessionID, permit: permit, beforeEnqueue: validate
            )
        } catch BrowserCDPConnectionError.deadlineExceeded {
            throw BorrowedChromeCommandTimeout(stage: .documentObservation, method: method)
        }
    }

    func invalidate() async {
        await connection.invalidateSession(sessionID)
        do {
            let params = try JSONSerialization.data(withJSONObject: ["sessionId": sessionID])
            let cleanup = Task {
                try await connection.command(method: "Target.detachFromTarget", params: params, beforeEnqueue: verifyBrowser)
            }
            _ = try await cleanup.value
        } catch {
            await connection.close()
        }
    }
}

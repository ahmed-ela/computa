import Foundation

struct ExtensionChromeAdmission: Sendable {
    let link: ExtensionChromeLink
    let installationID: String
    let pairingToken: String
    let bridgeEpoch: String
    var supportsTemporaryTabs = false

    func check() throws { try link.checkPeerIdentity() }

    func connect(request: ChromeConnectionRequest) async throws -> BorrowedChromeSessionOwner {
        try request.consent.check()
        try check()
        guard request.application.processIdentifier == link.chromePID else { throw ChromeBridgeIPC.Failure.identity }
        let transport = ExtensionChromeTransport(admission: self, consent: request.consent)
        do {
            try await transport.authorize()
            return try BorrowedChromeSessionOwner(application: request.application, transport: transport,
                consent: request.consent, verifyIdentity: {
                    try request.consent.check(); try self.check()
                })
        } catch { await transport.shutdown(); throw error }
    }
}

/// Alternate transport, not a browser-level CDP impersonator. The existing
/// session broker still owns target/document checks and every mutation permit.
actor ExtensionChromeTransport: BorrowedChromeSessionTransport {
    nonisolated let generation = UUID()
    private let admission: ExtensionChromeAdmission
    private let consent: ChromeDebuggingConsent
    private var attached: [String: BrowserTarget] = [:]
    private var attaching = Set<String>()
    private var closed = false
    private var temporaryTabsSupported = false
    private var temporaryTabsAuthorized = false
    private var temporaryReceipts = [UUID: TemporaryChromeTabReceipt]()
    private let operations = BrowserCDPDocumentOperations()

    init(admission: ExtensionChromeAdmission, consent: ChromeDebuggingConsent) {
        self.admission = admission; self.consent = consent
    }

    func authorize() async throws {
        var parameters: [String: Any] = ["installationId": admission.installationID,
                                        "pairingToken": admission.pairingToken]
        temporaryTabsAuthorized = consent.allowsTemporaryTabs && admission.supportsTemporaryTabs
        if temporaryTabsAuthorized { parameters["temporaryTabsVersion"] = 1 }
        _ = try await send("authorizeSession", parameters)
        try await validateConnection()
    }

    func validateConnection() async throws {
        let value = try await send("ping")
        guard value["generation"] as? String == generation.uuidString,
              value["bridgeEpoch"] as? String == admission.bridgeEpoch else { throw ChromeBridgeIPC.Failure.identity }
        temporaryTabsSupported = (value["capabilities"] as? [String: Any])?["temporaryTabsVersion"] as? Int == 1
    }

    func supportsTemporaryTabs() async throws -> Bool {
        try await validateConnection()
        return consent.allowsTemporaryTabs && temporaryTabsAuthorized && temporaryTabsSupported
    }

    func createTemporary(sourceTargetID: String, expectedSourceURL: URL,
                         taskNonce: UUID, permit: BrowserMutationPermit) async throws -> TemporaryChromeTabReceipt {
        try consent.check(); try admission.check()
        guard consent.allowsTemporaryTabs else { throw BorrowedChromeSessionOwnerError.temporaryTabsConsentRequired }
        guard temporaryTabsAuthorized && temporaryTabsSupported else { throw ChromeBridgeIPC.Failure.unsupportedCommand }
        guard !closed, temporaryReceipts.count < 16 else { throw ChromeBridgeIPC.Failure.closed }
        let params = try JSONSerialization.data(withJSONObject: ["sourceTargetID": sourceTargetID,
            "expectedSourceURL": expectedSourceURL.absoluteString, "taskNonce": taskNonce.uuidString])
        // Parse/retain the exact receipt before post-response authority checks.
        // If cancellation/revocation arrived while Chrome created it, cleanup
        // must still know precisely which extension-owned tab was created.
        let reply = try await admission.link.request(operation: "createTemporary", params: params,
                                                    generation: generation.uuidString, permit: permit, consent: consent)
        guard let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let rawLease = result["leaseToken"] as? String, let lease = UUID(uuidString: rawLease),
              let rawNonce = result["taskNonce"] as? String, UUID(uuidString: rawNonce) == taskNonce else {
            await shutdown(); throw ChromeBridgeIPC.Failure.invalidFrame
        }
        let candidate: BorrowedChromeTabCandidate
        do { candidate = try Self.candidate(result) }
        catch { await shutdown(); throw error }
        guard candidate.targetID != sourceTargetID, temporaryReceipts[lease] == nil else {
            await shutdown(); throw ChromeBridgeIPC.Failure.invalidFrame
        }
        let receipt = TemporaryChromeTabReceipt(leaseToken: lease, taskNonce: taskNonce, candidate: candidate)
        temporaryReceipts[lease] = receipt
        do {
            try consent.check(); try admission.check(); try Task.checkCancellation()
            guard !closed else { throw ChromeBridgeIPC.Failure.closed }
            guard candidate.url == expectedSourceURL, candidate.availability != .busy else {
                throw BorrowedChromeSessionOwnerError.workspaceSourceChanged
            }
            return receipt
        } catch {
            // Task cancellation must not cancel the exact cleanup request.
            _ = await Task { try? await self.releaseTemporary(receipt) }.value
            throw error
        }
    }

    @discardableResult func releaseTemporary(_ receipt: TemporaryChromeTabReceipt) async throws -> TemporaryChromeTabRelease {
        guard temporaryReceipts[receipt.leaseToken] == receipt else { return .alreadyReleased }
        temporaryReceipts.removeValue(forKey: receipt.leaseToken)
        // A held receipt retains cleanup authority after model/turn/consent
        // revocation. The extension independently checks generation, adoption,
        // task nonce and lease identity. Never accept an arbitrary target ID.
        let params = try JSONSerialization.data(withJSONObject: ["leaseToken": receipt.leaseToken.uuidString,
                                                                "taskNonce": receipt.taskNonce.uuidString])
        let reply = try await admission.link.request(operation: "releaseTemporary", params: params,
                                                      generation: generation.uuidString)
        guard let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
              result["released"] as? Bool == true, let closed = result["closed"] as? Bool,
              let retained = result["retained"] as? Bool, closed != retained else {
            throw ChromeBridgeIPC.Failure.invalidFrame
        }
        return closed ? .closed : .retained
    }

    func listCandidates() async throws -> [BorrowedChromeTabCandidate] {
        let result = try await send("inventory")
        guard let values = result["candidates"] as? [[String: Any]], values.count <= 2_048 else {
            throw ChromeBridgeIPC.Failure.invalidFrame
        }
        var identifiers = Set<String>()
        return try values.map {
            let candidate = try Self.candidate($0)
            guard identifiers.insert(candidate.targetID).inserted else { throw ChromeBridgeIPC.Failure.invalidFrame }
            return candidate
        }
    }

    func attach(targetID: String) async throws -> BrowserTarget {
        guard attached.count + attaching.count < 16, attached[targetID] == nil,
              attaching.insert(targetID).inserted else { throw BrowserTabBrokerError.operationInProgress }
        defer { attaching.remove(targetID) }
        let result = try await send("attach", ["targetID": targetID])
        let info = try Self.candidate(result)
        guard info.targetID == targetID, let token = result["attachmentToken"] as? String,
              UUID(uuidString: token) != nil else { throw ChromeBridgeIPC.Failure.invalidFrame }
        let session = BrowserAttachedSession(connectionGeneration: generation, sessionID: token, incarnation: UUID())
        let target = BrowserTarget(targetID: targetID, title: info.title, url: info.url, attachedSession: session)
        attached[targetID] = target
        return target
    }

    func target(id: String) async throws -> BrowserTarget? {
        guard let old = attached[id], let session = old.attachedSession else { return nil }
        try await admission.link.checkAttachment(session.sessionID)
        guard let current = try await listCandidates().first(where: { $0.targetID == id }) else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard attached[id]?.attachedSession == session else { throw BrowserTabBrokerError.targetReplaced }
        return BrowserTarget(targetID: id, title: current.title, url: current.url, attachedSession: session)
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        let channel = try await channel(target)
        let result = try await operations.observe(target: target, socket: channel)
        try await requireCurrent(target)
        return result
    }
    func press(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
               permit: BrowserMutationPermit) async throws {
        let channel = try await channel(target)
        try await operations.press(target: target, backendNodeID: backendNodeID, document: document,
                                   permit: permit, socket: channel)
        do { try await requireCurrent(target) }
        catch { throw BrowserMutationFailure(dispatchState: .dispatched, underlyingError: error) }
    }
    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
                 permit: BrowserMutationPermit) async throws {
        let channel = try await channel(target)
        try await operations.setText(target: target, backendNodeID: backendNodeID, text: text,
                                     document: document, permit: permit, socket: channel)
        do { try await requireCurrent(target) }
        catch { throw BrowserMutationFailure(dispatchState: .dispatched, underlyingError: error) }
    }
    func detach(target: BrowserTarget) async throws {
        guard let session = target.attachedSession, attached[target.targetID]?.attachedSession == session else {
            throw BrowserTabBrokerError.targetReplaced
        }
        attached.removeValue(forKey: target.targetID)
        if await attachmentWasRevoked(session.sessionID) { return }
        do { _ = try await send("detach", ["attachmentToken": session.sessionID]) }
        catch {
            // User adoption explicitly retires an attachment before notifying
            // native code. That exact-token event is already cleanup evidence,
            // not a reason to revoke unrelated tabs/the remembered connection.
            if await attachmentWasRevoked(session.sessionID) { return }
            await shutdown(); throw error
        }
    }

    private func attachmentWasRevoked(_ token: String) async -> Bool {
        do {
            try await admission.link.check()
            do { try await admission.link.checkAttachment(token); return false }
            catch { try await admission.link.check(); return true }
        } catch { return false }
    }
    func shutdown() async {
        guard !closed else { return }
        closed = true; attached.removeAll()
        for receipt in Array(temporaryReceipts.values) { _ = try? await releaseTemporary(receipt) }
        // Close the authenticated link. Native host signals appDisconnected
        // and extension invalidates its generation before reattachment.
        await admission.link.close()
    }
    func createTarget(url: URL) throws -> BrowserTarget { throw BrowserTabBrokerError.ownershipMismatch }
    func activateTarget(id: String) throws { throw BrowserTabBrokerError.ownershipMismatch }
    func closeTarget(target: BrowserTarget) throws { throw BrowserTabBrokerError.ownershipMismatch }

    private func channel(_ target: BrowserTarget) async throws -> ExtensionDocumentChannel {
        try await requireCurrent(target)
        return ExtensionDocumentChannel(transport: self, target: target)
    }
    private func requireCurrent(_ target: BrowserTarget) async throws {
        try consent.check(); try admission.check()
        guard !closed, attached[target.targetID]?.attachedSession == target.attachedSession,
              let session = target.attachedSession else { throw BrowserTabBrokerError.targetReplaced }
        try await admission.link.checkAttachment(session.sessionID)
        try consent.check()
        guard !closed, attached[target.targetID]?.attachedSession == session else {
            throw BrowserTabBrokerError.targetReplaced
        }
    }
    fileprivate func command(target: BrowserTarget, method: String, params: Data,
                             permit: BrowserMutationPermit?) async throws -> Data {
        try await requireCurrent(target)
        guard let session = target.attachedSession,
              let parameters = try JSONSerialization.jsonObject(with: params) as? [String: Any] else {
            throw ChromeBridgeIPC.Failure.invalidFrame
        }
        let value = try JSONSerialization.data(withJSONObject: ["attachmentToken": session.sessionID,
                                                                "method": method, "params": parameters])
        let result = try await admission.link.request(operation: "command", params: value,
            generation: generation.uuidString, permit: permit, consent: consent)
        try await requireCurrent(target)
        return result
    }
    private func send(_ operation: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try consent.check(); try admission.check()
        guard !closed else { throw ChromeBridgeIPC.Failure.closed }
        let data = try JSONSerialization.data(withJSONObject: params)
        let reply = try await admission.link.request(operation: operation, params: data,
                                                     generation: generation.uuidString, consent: consent)
        try consent.check()
        guard !closed, let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw ChromeBridgeIPC.Failure.invalidFrame
        }
        return object
    }
    private static func candidate(_ value: [String: Any]) throws -> BorrowedChromeTabCandidate {
        guard let id = value["targetID"] as? String, !id.isEmpty, id.utf8.count <= 256,
              let title = value["title"] as? String, title.utf8.count <= 32_768,
              let rawURL = value["url"] as? String, rawURL.utf8.count <= 32_768,
              let url = URL(string: rawURL), ["https", "http"].contains(url.scheme ?? "") else {
            throw ChromeBridgeIPC.Failure.invalidFrame
        }
        let availability: BorrowedChromeTabCandidate.Availability
        if let rawAvailability = value["availability"] {
            guard let raw = rawAvailability as? String,
                  let parsed = BorrowedChromeTabCandidate.Availability(rawValue: raw) else {
                throw ChromeBridgeIPC.Failure.invalidFrame
            }
            availability = parsed
        } else {
            // Older paired extensions cannot prove a busy tab became free.
            availability = .unknown
        }
        return .init(targetID: id, title: title, url: url, availability: availability)
    }
}

private actor ExtensionDocumentChannel: BrowserDocumentChannel {
    let transport: ExtensionChromeTransport
    let target: BrowserTarget
    private var valid = true
    init(transport: ExtensionChromeTransport, target: BrowserTarget) { self.transport = transport; self.target = target }
    func request(method: String, params: Data, permit: BrowserMutationPermit?) async throws -> Data {
        guard valid else { throw ChromeBridgeIPC.Failure.closed }
        return try await transport.command(target: target, method: method, params: params, permit: permit)
    }
    func invalidate() { valid = false }
}

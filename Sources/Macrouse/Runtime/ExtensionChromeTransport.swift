import Foundation

struct ExtensionChromeAdmission: Sendable {
    let link: ExtensionChromeLink
    let installationID: String
    let pairingToken: String
    let bridgeEpoch: String

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
    private let operations = BrowserCDPDocumentOperations()

    init(admission: ExtensionChromeAdmission, consent: ChromeDebuggingConsent) {
        self.admission = admission; self.consent = consent
    }

    func authorize() async throws {
        _ = try await send("authorizeSession", ["installationId": admission.installationID,
                                                 "pairingToken": admission.pairingToken])
        try await validateConnection()
    }

    func validateConnection() async throws {
        let value = try await send("ping")
        guard value["generation"] as? String == generation.uuidString,
              value["bridgeEpoch"] as? String == admission.bridgeEpoch else { throw ChromeBridgeIPC.Failure.identity }
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
        try await requireCurrent(target)
    }
    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
                 permit: BrowserMutationPermit) async throws {
        let channel = try await channel(target)
        try await operations.setText(target: target, backendNodeID: backendNodeID, text: text,
                                     document: document, permit: permit, socket: channel)
        try await requireCurrent(target)
    }
    func detach(target: BrowserTarget) async throws {
        guard let session = target.attachedSession, attached[target.targetID]?.attachedSession == session else {
            throw BrowserTabBrokerError.targetReplaced
        }
        attached.removeValue(forKey: target.targetID)
        do { _ = try await send("detach", ["attachmentToken": session.sessionID]) }
        catch { await shutdown(); throw error }
    }
    func shutdown() async {
        guard !closed else { return }
        closed = true; attached.removeAll()
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
            generation: generation.uuidString, permit: permit)
        try await requireCurrent(target)
        return result
    }
    private func send(_ operation: String, _ params: [String: String] = [:]) async throws -> [String: Any] {
        try consent.check(); try admission.check()
        guard !closed else { throw ChromeBridgeIPC.Failure.closed }
        let data = try JSONSerialization.data(withJSONObject: params)
        let reply = try await admission.link.request(operation: operation, params: data, generation: generation.uuidString)
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
        return .init(targetID: id, title: title, url: url)
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

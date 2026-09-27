import AppKit
import Darwin
import Foundation
import Observation
import Security

/// Pure authorization fence, deliberately independent of IPC and Keychain so
/// identity and revocation races are deterministic in tests. A duplicated
/// installation is quarantined for this coordinator's lifetime: dropping one
/// conflicting link is not evidence that the remaining profile is the right one.
struct ChromeExtensionAuthorityGuard {
    struct PairingAttempt {
        fileprivate let revision: UUID
        let linkID: UUID
        let installationID: String
        let bridgeEpoch: String
        let nonce: String
        let token: String
    }

    private var revision = UUID()
    private var conflictedInstallations = Set<String>()

    mutating func revoke() { revision = UUID() }

    mutating func quarantineConflicts(_ hellos: [UUID: ChromeExtensionHello]) -> Set<UUID> {
        let grouped = Dictionary(grouping: hellos.keys) { hellos[$0]!.installationId }
        let conflicts = grouped.filter { $0.value.count > 1 }
        if !conflicts.isEmpty { revoke() }
        conflictedInstallations.formUnion(conflicts.keys)
        return Set(hellos.keys.filter { conflictedInstallations.contains(hellos[$0]!.installationId) })
    }

    func requireUnique(id: UUID, hello: ChromeExtensionHello, hellos: [UUID: ChromeExtensionHello]) throws {
        guard hello.valid, !conflictedInstallations.contains(hello.installationId),
              let current = hellos[id], current.installationId == hello.installationId,
              current.bridgeEpoch == hello.bridgeEpoch,
              hellos.values.filter({ $0.installationId == hello.installationId }).count == 1 else {
            throw ChromeBridgeIPC.Failure.identity
        }
    }

    func beginPairing(id: UUID, hello: ChromeExtensionHello, token: String,
                      hellos: [UUID: ChromeExtensionHello]) throws -> PairingAttempt {
        try requireUnique(id: id, hello: hello, hellos: hellos)
        guard hellos[id] == hello, hello.event == "pairRequested", !hello.paired,
              let nonce = hello.pairingNonce else { throw ChromeBridgeIPC.Failure.identity }
        return PairingAttempt(revision: revision, linkID: id, installationID: hello.installationId,
                              bridgeEpoch: hello.bridgeEpoch, nonce: nonce, token: token)
    }

    func validate(_ attempt: PairingAttempt, hellos: [UUID: ChromeExtensionHello]) throws {
        guard revision == attempt.revision, let current = hellos[attempt.linkID],
              current.installationId == attempt.installationID, current.bridgeEpoch == attempt.bridgeEpoch else {
            throw ChromeBridgeIPC.Failure.identity
        }
        try requireUnique(id: attempt.linkID, hello: current, hellos: hellos)
        // approvePair emits its new hello before its response. Depending on
        // actor scheduling, either the exact proposal or its matching success
        // may be visible here; an unrelated token, nonce or epoch is never valid.
        let originalProposal = current.event == "pairRequested" && !current.paired
            && current.pairingNonce == attempt.nonce
        let matchingSuccess = current.paired && !current.suspended && current.pairingToken == attempt.token
        guard originalProposal || matchingSuccess else { throw ChromeBridgeIPC.Failure.identity }
    }
}

/// A native-only pairing surface. A hello/pairRequested is a proposal, not
/// authorization. Only a matching saved Keychain grant or native user action
/// can produce a ChromeConnectionRequest.
@MainActor @Observable
final class BrowserExtensionCoordinator {
    private(set) var status = "Browser extension not connected"
    private(set) var pairingAvailable = false
    private(set) var automaticallyAuthorized = false
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let onAdmission: @MainActor (ChromeConnectionRequest) -> Bool
    @ObservationIgnored private let onRevocation: @MainActor () -> Void
    @ObservationIgnored private var server: ChromeBridgeListener?
    @ObservationIgnored private var links: [UUID: ExtensionChromeLink] = [:]
    @ObservationIgnored private var hellos: [UUID: ChromeExtensionHello] = [:]
    @ObservationIgnored private var pairedLink: UUID?
    @ObservationIgnored private var authorizing = Set<UUID>()
    @ObservationIgnored private var pendingPairings: [UUID: (ExtensionChromeLink, String, String)] = [:]
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var authority = ChromeExtensionAuthorityGuard()
    static let enabledKey = "Macndash.chromeExtension.enabled"
    private static let installationKey = "Macndash.chromeExtension.installationID"

    init(preferences: UserDefaults, onAdmission: @escaping @MainActor (ChromeConnectionRequest) -> Bool,
         onRevocation: @escaping @MainActor () -> Void) {
        self.preferences = preferences; self.onAdmission = onAdmission; self.onRevocation = onRevocation
    }

    var enabled: Bool { preferences.bool(forKey: Self.enabledKey) }

    func start() {
        guard server == nil, !stopped else { return }
        do {
            // Fail visibly before creating a listener on unsupported ad-hoc
            // builds. Local inference/native AX do not require bridge signing.
            _ = try ChromeBridgeIPC.ownAppleSigningTeam(forPeerIdentifier: ChromeBridgeIPC.hostIdentifier)
            let listener = try ChromeBridgeListener { [weak self] socket, chromePID in
                Task { @MainActor in
                    guard let self, !self.stopped, self.links.count < 4 else { socket.close(); return }
                    let link = ExtensionChromeLink(socket: socket, chromePID: chromePID) { [weak self] event in
                        Task { @MainActor in self?.receive(event) }
                    }
                    self.links[link.id] = link
                    await link.start()
                }
            }
            server = listener
            listener.start()
        } catch { status = "Browser bridge unavailable: \(error.localizedDescription)" }
    }

    private func receive(_ event: ExtensionChromeLinkEvent) {
        guard !stopped else { return }
        switch event {
        case .hello(let id, let hello):
            guard links[id] != nil else { return }
            let previous = hellos[id]
            hellos[id] = hello
            let conflicts = authority.quarantineConflicts(hellos)
            if !conflicts.isEmpty {
                if let pairedLink, conflicts.contains(pairedLink) {
                    self.pairedLink = nil; automaticallyAuthorized = false
                    onRevocation()
                }
                pairingAvailable = false
                status = "Browser profile identity conflict — no access granted"
                for conflict in conflicts {
                    if let link = links[conflict] { Task { await link.close() } }
                }
                return
            }
            if let previous, previous.bridgeEpoch != hello.bridgeEpoch
                || previous.installationId != hello.installationId
                || (!previous.suspended && hello.suspended)
                || (previous.paired && !hello.paired) {
                authority.revoke()
            }
            pairingAvailable = hellos.values.contains { $0.event == "pairRequested" && $0.pairingNonce != nil }
            if hello.suspended || !hello.paired {
                if pairedLink == id {
                    pairedLink = nil; automaticallyAuthorized = false
                    onRevocation()
                }
                if hello.suspended { status = "Browser access paused in Chrome"; return }
            }
            if hello.paired, enabled, preferences.string(forKey: Self.installationKey) == hello.installationId,
               let expected = ChromeExtensionPairingStore.load(hello.installationId),
               let supplied = hello.pairingToken, expected == supplied,
               pairedLink == nil, !authorizing.contains(id) {
                authorizeSaved(id: id, hello: hello, token: expected)
            } else if hello.event == "pairRequested" {
                status = "Extension ready — approve pairing in Mactopus"
            } else if pairedLink == nil {
                status = "Open the Mactopus extension and choose Pair"
            }
        case .detached:
            // The adapter checks exact attachment tokens; no reattach/replay.
            break
        case .disconnected(let id):
            // A pending pairing reply cannot write a saved grant after its
            // original peer has gone away, even if the same ID reconnects.
            if authorizing.contains(id) || pairedLink == id { authority.revoke() }
            links.removeValue(forKey: id); hellos.removeValue(forKey: id); authorizing.remove(id)
            if pairedLink == id {
                pairedLink = nil; automaticallyAuthorized = false
                status = "Browser extension reconnecting"
                onRevocation()
            }
            pairingAvailable = hellos.values.contains { $0.event == "pairRequested" }
        }
    }

    func approvePairing() async throws {
        guard !stopped, authorizing.isEmpty else { throw ChromeBridgeIPC.Failure.unavailable }
        let candidates = hellos.filter { $0.value.event == "pairRequested" && $0.value.pairingNonce != nil }
        guard candidates.count == 1, let (id, hello) = candidates.first, let link = links[id],
              let nonce = hello.pairingNonce else { throw ChromeBridgeIPC.Failure.identity }
        authorizing.insert(id)
        defer { authorizing.remove(id) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChromeBridgeIPC.Failure.configuration }
        let token = Data(bytes).base64EncodedString()
        let attempt = try authority.beginPairing(id: id, hello: hello, token: token, hellos: hellos)
        pendingPairings[id] = (link, hello.installationId, token)
        defer { pendingPairings.removeValue(forKey: id) }
        let parameters = try JSONSerialization.data(withJSONObject: ["installationId": hello.installationId,
            "pairingNonce": nonce, "pairingToken": token])
        _ = try await link.request(operation: "approvePair", params: parameters, generation: UUID().uuidString)
        guard !stopped, links[id] === link else { throw ChromeBridgeIPC.Failure.closed }
        try authority.validate(attempt, hellos: hellos)
        try ChromeExtensionPairingStore.save(token, installationID: hello.installationId)
        preferences.set(hello.installationId, forKey: Self.installationKey)
        preferences.set(true, forKey: Self.enabledKey)
        pairingAvailable = false
        try publish(id: id, hello: hello, token: token)
    }

    private func authorizeSaved(id: UUID, hello: ChromeExtensionHello, token: String) {
        do { try publish(id: id, hello: hello, token: token) }
        catch { status = error.localizedDescription }
    }

    private func publish(id: UUID, hello: ChromeExtensionHello, token: String) throws {
        guard let link = links[id], !stopped else { throw ChromeBridgeIPC.Failure.closed }
        try authority.requireUnique(id: id, hello: hello, hellos: hellos)
        let target = try NativeChromeConnectionTarget.prepare()
        guard target.application.processIdentifier == link.chromePID else { throw ChromeBridgeIPC.Failure.identity }
        let admission = ExtensionChromeAdmission(link: link, installationID: hello.installationId,
            pairingToken: token, bridgeEpoch: hello.bridgeEpoch)
        try admission.check()
        pairedLink = id; automaticallyAuthorized = true
        status = "Browser extension authorized"
        let accepted = onAdmission(ChromeConnectionRequest(application: target.application, userDataDirectory: target.userDataDirectory,
            consent: ChromeDebuggingConsent(approvedByUser: true), extensionAdmission: admission))
        if !accepted { pairedLink = nil; automaticallyAuthorized = false; status = "Browser authorized — reconnect when tasks are idle" }
    }

    func reconnectSaved() {
        guard enabled, pairedLink == nil else { return }
        for (id, hello) in hellos where hello.paired && !hello.suspended {
            guard preferences.string(forKey: Self.installationKey) == hello.installationId,
                  let token = ChromeExtensionPairingStore.load(hello.installationId), token == hello.pairingToken else { continue }
            authorizeSaved(id: id, hello: hello, token: token)
            return
        }
    }

    @discardableResult
    func forget() -> Task<Void, Never> {
        authority.revoke()
        let installation = preferences.string(forKey: Self.installationKey)
        let token = installation.flatMap { ChromeExtensionPairingStore.load($0) }
        let paired = pairedLink.flatMap { links[$0] }
            ?? links.first { hellos[$0.key]?.installationId == installation }?.value
        let closing = Array(links.values)
        var revocations = Array(pendingPairings.values)
        if let installation, let token, let paired { revocations.append((paired, installation, token)) }
        if let installation { ChromeExtensionPairingStore.forget(installation) }
        preferences.removeObject(forKey: Self.installationKey)
        preferences.set(false, forKey: Self.enabledKey)
        pairedLink = nil; automaticallyAuthorized = false; pairingAvailable = false
        status = "Browser authorization removed"
        return Task {
            for (paired, installation, token) in revocations {
                guard let params = try? JSONSerialization.data(withJSONObject: ["installationId": installation, "pairingToken": token]) else { continue }
                // Revocation only, also valid while suspended. Local authority
                // is already removed, even when Chrome cannot acknowledge it.
                _ = try? await paired.request(operation: "revokePair", params: params, generation: UUID().uuidString)
            }
            for link in closing { await link.close() }
        }
    }

    func stop() {
        authority.revoke()
        stopped = true
        server?.stop(); server = nil
        for link in links.values { Task { await link.close() } }
        links.removeAll(); hellos.removeAll()
    }
}

private final class ChromeBridgeListener: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private let onAccept: @Sendable (ChromeBridgeSocket, Int32) -> Void

    init(onAccept: @escaping @Sendable (ChromeBridgeSocket, Int32) -> Void) throws {
        try ChromeBridgeIPC.prepareDirectory()
        let path = ChromeBridgeIPC.socketPath
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else { throw ChromeBridgeIPC.Failure.identity }
            if let active = try? ChromeBridgeIPC.connect() { Darwin.close(active); throw ChromeBridgeIPC.Failure.unavailable }
            guard unlink(path) == 0 else { throw ChromeBridgeIPC.Failure.unavailable }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ChromeBridgeIPC.Failure.unavailable }
        do {
            ChromeBridgeIPC.configure(descriptor)
            var address = try ChromeBridgeIPC.address(path: path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 4) == 0 else { throw ChromeBridgeIPC.Failure.unavailable }
            fd = descriptor; self.onAccept = onAccept
        } catch { Darwin.close(descriptor); throw error }
    }
    func start() {
        DispatchQueue(label: "mactopus.browser-bridge.accept").async { [self] in
            while !lock.withLock({ stopped }) {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                let socket = ChromeBridgeSocket(fd: client)
                do {
                    let peer = try ChromeBridgeIPC.peerPID(client)
                    try ChromeBridgeIPC.validateCode(pid: peer, identifier: ChromeBridgeIPC.hostIdentifier)
                    let chromePID = try ChromeBridgeIPC.verifiedChromeParent(of: peer)
                    onAccept(socket, chromePID)
                } catch { socket.close() }
            }
        }
    }
    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }
    deinit { Darwin.close(fd) }
}

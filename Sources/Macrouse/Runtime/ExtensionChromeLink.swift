import Foundation
import LocalAuthentication
import Security

struct ChromeExtensionHello: Decodable, Sendable, Equatable {
    let version: Int
    let event: String
    let installationId: String
    let extensionId: String
    let bridgeEpoch: String
    let paired: Bool
    let suspended: Bool
    let pairingToken: String?
    let pairingNonce: String?

    var valid: Bool {
        version == 1 && ["hello", "pairRequested"].contains(event)
            && UUID(uuidString: installationId) != nil && UUID(uuidString: bridgeEpoch) != nil
            && extensionId == ChromeBridgeIdentity.extensionID
            && (pairingToken == nil || pairingToken!.utf8.count <= 256)
            && (pairingNonce == nil || UUID(uuidString: pairingNonce!) != nil)
    }
}

enum ExtensionChromeLinkEvent: Sendable {
    case hello(UUID, ChromeExtensionHello)
    case detached(UUID, String)
    case disconnected(UUID)
}

/// Bounded request ledger shared by setup and the extension transport. No
/// request is replayed after cancellation/timeout or a native-port replacement.
actor ExtensionChromeLink {
    nonisolated let id = UUID()
    nonisolated let chromePID: Int32
    private let socket: ChromeBridgeSocket
    private let event: @Sendable (ExtensionChromeLinkEvent) -> Void
    private var pending: [String: (String, CheckedContinuation<Data, Error>, Task<Void, Never>)] = [:]
    private var closed = false
    private var hello: ChromeExtensionHello?
    private var detachedTokens = Set<String>()
    private var reader: Task<Void, Never>?
    private let readQueue = DispatchQueue(label: "macrouse.extension.socket-reader")

    init(socket: ChromeBridgeSocket, chromePID: Int32, event: @escaping @Sendable (ExtensionChromeLinkEvent) -> Void) {
        self.socket = socket; self.chromePID = chromePID; self.event = event
    }

    deinit { socket.close(); reader?.cancel() }

    func start() {
        guard reader == nil else { return }
        reader = Task { [weak self, socket, readQueue] in
            do {
                while !Task.isCancelled {
                    let data: Data? = try await withCheckedThrowingContinuation { continuation in
                        readQueue.async {
                            do { continuation.resume(returning: try ChromeBridgeIPC.readFrame(socket.fd)) }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                    guard let data else { break }
                    guard let self else { return }
                    try await self.receive(data)
                }
            } catch { }
            await self?.close()
        }
    }

    func check() throws {
        guard !closed else { throw ChromeBridgeIPC.Failure.closed }
        try checkPeerIdentity()
    }

    nonisolated func checkPeerIdentity() throws {
        try socket.check()
        try ChromeBridgeIPC.validateCode(pid: chromePID, identifier: "com.google.Chrome", team: "EQHXZ8M8AV")
    }

    func checkAttachment(_ token: String) throws {
        try check()
        guard !detachedTokens.contains(token) else { throw ChromeBridgeIPC.Failure.closed }
    }

    func request(operation: String, params: Data = Data("{}".utf8), generation: String,
                 permit: BrowserMutationPermit? = nil) async throws -> Data {
        try check()
        try Task.checkCancellation()
        guard pending.count < 32,
              let object = try JSONSerialization.jsonObject(with: params) as? [String: Any] else {
            throw ChromeBridgeIPC.Failure.invalidFrame
        }
        let requestID = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "id": requestID, "generation": generation,
            "operation": operation, "params": object
        ])
        guard data.count <= ChromeBridgeIPC.maximumFrame else { throw ChromeBridgeIPC.Failure.invalidFrame }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await self?.expire(requestID)
                }
                pending[requestID] = (generation, continuation, deadline)
                var writeAttempted = false
                do {
                    try Task.checkCancellation()
                    let send = { writeAttempted = true; try self.socket.send(data) }
                    if let permit { try permit.commit(send) }
                    else { try send() }
                } catch {
                    pending.removeValue(forKey: requestID)?.2.cancel()
                    continuation.resume(throwing: error)
                    if writeAttempted { close(error: error) }
                }
            }
        } onCancel: { [weak self, socket] in
            // A potentially delivered action is uncertain. Closing the link
            // revokes all old extension attachments instead of replaying it.
            socket.close()
            Task { await self?.close() }
        }
    }

    private func expire(_ requestID: String) {
        guard pending[requestID] != nil else { return }
        close(error: ChromeBridgeIPC.Failure.deadline)
    }

    private func receive(_ data: Data) throws {
        guard !closed, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["version"] as? Int == 1 else { throw ChromeBridgeIPC.Failure.invalidFrame }
        if let eventName = value["event"] as? String {
            if eventName == "hello" || eventName == "pairRequested" {
                let incoming = try JSONDecoder().decode(ChromeExtensionHello.self, from: data)
                guard incoming.valid else { throw ChromeBridgeIPC.Failure.identity }
                if let hello {
                    guard hello.installationId == incoming.installationId, hello.bridgeEpoch == incoming.bridgeEpoch else {
                        throw ChromeBridgeIPC.Failure.identity
                    }
                }
                hello = incoming
                event(.hello(id, incoming))
            } else if eventName == "detached", let token = value["attachmentToken"] as? String {
                guard detachedTokens.count < 4_096 else { throw ChromeBridgeIPC.Failure.invalidFrame }
                detachedTokens.insert(token)
                event(.detached(id, token))
            } else { throw ChromeBridgeIPC.Failure.invalidFrame }
            return
        }
        guard let requestID = value["id"] as? String,
              let item = pending[requestID], value["generation"] as? String == item.0,
              let ok = value["ok"] as? Bool else { throw ChromeBridgeIPC.Failure.invalidFrame }
        pending.removeValue(forKey: requestID)
        item.2.cancel()
        if ok, let result = value["result"], JSONSerialization.isValidJSONObject(result) {
            item.1.resume(returning: try JSONSerialization.data(withJSONObject: result))
        } else {
            // Do not propagate arbitrary extension error strings/page content.
            item.1.resume(throwing: ChromeBridgeIPC.Failure.rejected)
            let code = (value["error"] as? [String: Any])?["code"] as? String
            if Self.revokesConnection(errorCode: code) { close(error: ChromeBridgeIPC.Failure.rejected) }
        }
    }

    nonisolated static func revokesConnection(errorCode: String?) -> Bool {
        // Ordinary stale-element/unsupported-operation errors do not revoke a
        // pairing. Session authority loss or an uncertain timeout does.
        errorCode == nil || ["unauthorized", "revoked", "chrome_timeout", "duplicate_request",
            "duplicate_generation", "capacity_exceeded", "invalid_inventory", "response_too_large"].contains(errorCode!)
    }

    func close(error: Error = ChromeBridgeIPC.Failure.closed) {
        guard !closed else { return }
        closed = true
        socket.close()
        reader?.cancel(); reader = nil
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.2.cancel(); request.1.resume(throwing: error) }
        event(.disconnected(id))
    }
}

enum ChromeExtensionPairingStore {
    private static let service = "com.ahmedelamin.LocalCodex.ChromeBridgePairing.v1"
    static func load(_ installationID: String) -> String? {
        var result: CFTypeRef?
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: installationID,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, installationID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: installationID]
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let update = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if update == errSecItemNotFound {
            var insertion = query.merging(attrs) { _, new in new }
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw ChromeBridgeIPC.Failure.configuration }
        } else if update != errSecSuccess { throw ChromeBridgeIPC.Failure.configuration }
    }
    static func forget(_ installationID: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: installationID] as CFDictionary)
    }
}

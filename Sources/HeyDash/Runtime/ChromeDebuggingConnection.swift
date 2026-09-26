import AutomationCore
import Foundation

/// Host-only admission combining explicit user consent, the selected endpoint
/// file generation and the exact ordinary Chrome process/listener. This is not
/// a model tool, endpoint discovery, or permission-changing API.
struct ChromeDebuggingConnectionAuthority: Sendable {
    let endpoint: URL
    private let consent: ChromeDebuggingConsent
    private let validateIdentity: @Sendable () throws -> Void

    // Dependency seam for deterministic tests; production uses bind below.
    init(endpoint: URL, consent: ChromeDebuggingConsent, validateIdentity: @escaping @Sendable () throws -> Void) {
        self.endpoint = endpoint
        self.consent = consent
        self.validateIdentity = validateIdentity
    }

    static func bind(
        processIdentifier: Int32, expectedExecutableURL: URL,
        explicitlyApprovedUserDataDirectory: URL, consent: ChromeDebuggingConsent
    ) throws -> Self {
        let file = try ChromeDebuggingEndpointFile.read(
            explicitlyApprovedUserDataDirectory: explicitlyApprovedUserDataDirectory, consent: consent
        )
        return try consent.withApproval {
            guard let port = file.endpoint.port.flatMap(UInt16.init(exactly:)) else {
                throw ChromeDebuggingEndpointError.invalidContents
            }
            let process = try ChromeDebuggingProcessBinding.bind(
                processIdentifier: processIdentifier, expectedExecutableURL: expectedExecutableURL, port: port
            )
            try file.validateIdentity()
            return Self(endpoint: file.endpoint, consent: consent) {
                try file.validateIdentity()
                try process.validate()
            }
        }
    }

    func validate() throws { try withVerifiedIdentity {} }

    /// Only bounded synchronous file/syscall checks and enqueue are admitted.
    /// No actor hops or callbacks into consent are allowed under this lock.
    /// Kernel reads remain snapshots, not an atomic WebSocket peer credential.
    func withVerifiedIdentity<T>(_ operation: () throws -> T) throws -> T {
        try consent.withApproval {
            try validateIdentity()
            return try operation()
        }
    }
}

enum ChromeDebuggingConnection {
    /// Performs one non-mutating protocol handshake before publishing the
    /// adapter. Failure closes only this connection; it never reconnects,
    /// changes Chrome settings, or closes/activates any user tab.
    static func connect(
        authority: ChromeDebuggingConnectionAuthority,
        requirePermission: @escaping @Sendable () throws -> Void = requireBrowserAccessibilityPermission,
        configuration: BrowserCDPConnection.Configuration = .init(),
        makeWire: @Sendable (URL) throws -> any BrowserCDPWire = { try URLSessionBrowserCDPWire(endpoint: $0) }
    ) async throws -> BorrowedChromeDevToolsTransport {
        try Task.checkCancellation()
        let base = try authority.withVerifiedIdentity {
            try requirePermission()
            try URLSessionBrowserCDPWire.validate(endpoint: authority.endpoint)
            return try makeWire(authority.endpoint)
        }
        let wire = ChromeDebuggingBoundWire(base: base, authority: authority)
        let connection = BrowserCDPConnection(wire: wire, configuration: configuration)
        do {
            let reply = try await connection.command(method: "Browser.getVersion", beforeEnqueue: requirePermission)
            try Task.checkCancellation()
            try authority.validate()
            try requirePermission()
            guard let version = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let product = version["product"] as? String, product.utf8.count <= 256,
                  product.hasPrefix("Chrome/") || product.hasPrefix("HeadlessChrome/"),
                  let protocolVersion = version["protocolVersion"] as? String,
                  !protocolVersion.isEmpty, protocolVersion.utf8.count <= 32 else {
                throw BrowserCDPConnectionError.malformedMessage
            }
            return BorrowedChromeDevToolsTransport(
                connection: connection, generation: UUID(), verifyBrowser: { try authority.validate() },
                requirePermission: requirePermission
            )
        } catch {
            await connection.close()
            throw error
        }
    }
}

/// Consent and attribution cover every actual enqueue, including cleanup, and
/// every inbound message. A failed check tears down this wire, with no retry.
/// The wrapped wire's completion must not synchronously reenter the authority.
final class ChromeDebuggingBoundWire: BrowserCDPWire, @unchecked Sendable {
    private let base: any BrowserCDPWire
    private let authority: ChromeDebuggingConnectionAuthority
    private let lock = NSLock()
    private var closed = false

    init(base: any BrowserCDPWire, authority: ChromeDebuggingConnectionAuthority) {
        self.base = base
        self.authority = authority
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        do {
            try authority.withVerifiedIdentity {
                try lock.withLock {
                    guard !closed else { throw BrowserCDPConnectionError.closed }
                    base.enqueue(data, completion: completion)
                }
            }
        } catch {
            close()
            completion(.failure(error))
        }
    }

    func receive() async throws -> Data {
        do {
            try authority.validate()
            let data = try await base.receive()
            try authority.validate()
            return data
        } catch {
            close()
            throw error
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            base.close()
        }
    }

    deinit { close() }
}

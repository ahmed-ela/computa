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

/// Fixed admission stages only. Never retain an endpoint, profile, peer message
/// or arbitrary transport error in a value that can reach the native UI.
enum ChromeDebuggingAdmissionError: Error, Equatable, LocalizedError, Sendable {
    case openingTimedOut
    case openingFailed
    case handshakeTimedOut
    case handshakeFailed

    var errorDescription: String? {
        switch self {
        case .openingTimedOut:
            "Timed out waiting for Chrome to open the debugging connection. Chrome may still be waiting for approval."
        case .openingFailed:
            "Chrome did not open the debugging connection. Check Chrome before connecting again."
        case .handshakeTimedOut:
            "Chrome opened the connection but did not respond to the initial browser check in time."
        case .handshakeFailed:
            "Chrome opened the connection, but the initial browser check failed."
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
        openingTimeout: Duration = URLSessionBrowserCDPWire.defaultOpeningTimeout,
        sleepForOpeningDeadline: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        makeWire: (@Sendable (URL) throws -> any BrowserCDPWire)? = nil
    ) async throws -> BorrowedChromeDevToolsTransport {
        try Task.checkCancellation()
        guard openingTimeout > .zero, openingTimeout <= URLSessionBrowserCDPWire.defaultOpeningTimeout else {
            throw BrowserCDPConnectionError.invalidRequest
        }
        let base: any BrowserCDPWire = try authority.withVerifiedIdentity {
            try requirePermission()
            try URLSessionBrowserCDPWire.validate(endpoint: authority.endpoint)
            if let makeWire { return try makeWire(authority.endpoint) }
            return try URLSessionBrowserCDPWire(endpoint: authority.endpoint, openingTimeout: openingTimeout)
        }
        let wire = ChromeDebuggingBoundWire(base: base, authority: authority)
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await wire.waitUntilOpen() }
                    group.addTask {
                        try await sleepForOpeningDeadline(openingTimeout)
                        try Task.checkCancellation()
                        throw ChromeDebuggingAdmissionError.openingTimedOut
                    }
                    defer { group.cancelAll() }
                    do { _ = try await group.next() }
                    catch {
                        // Closing also wakes a silent transport's opening wait,
                        // so structured cleanup cannot outlive the deadline.
                        wire.close()
                        throw error
                    }
                }
            } onCancel: { wire.close() }
            try Task.checkCancellation()
            try authority.validate()
            try requirePermission()
        } catch {
            wire.close()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let endpoint = error as? ChromeDebuggingEndpointError { throw endpoint }
            if error as? ChromeDebuggingAdmissionError == .openingTimedOut
                || error as? BrowserCDPConnectionError == .deadlineExceeded {
                throw ChromeDebuggingAdmissionError.openingTimedOut
            }
            throw ChromeDebuggingAdmissionError.openingFailed
        }

        // Only an open WebSocket starts the ordinary 15-second command timer.
        // A slow human approval never consumes the browser protocol deadline.
        let connection = BrowserCDPConnection(wire: wire, configuration: configuration)
        do {
            return try await withTaskCancellationHandler {
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
            } onCancel: { wire.close() }
        } catch {
            await connection.close()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let endpoint = error as? ChromeDebuggingEndpointError { throw endpoint }
            if error as? BrowserCDPConnectionError == .deadlineExceeded {
                throw ChromeDebuggingAdmissionError.handshakeTimedOut
            }
            throw ChromeDebuggingAdmissionError.handshakeFailed
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

    func waitUntilOpen() async throws {
        do {
            try authority.validate()
            try await base.waitUntilOpen()
            try Task.checkCancellation()
            try authority.validate()
        } catch {
            close()
            throw error
        }
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

import CoreFoundation
import Foundation

/// `enqueue` must synchronously submit exactly once or fail. It must not defer
/// submission into another task: mutation permits guard this actual boundary.
protocol BrowserCDPWire: Sendable {
    func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void)
    func receive() async throws -> Data
    func close()
}

struct BrowserCDPEvent: Equatable, Sendable {
    let method: String
    let params: Data
    let sessionID: String?
}

enum BrowserCDPConnectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidRequest
    case requestLimit
    case closed
    case transportFailed
    case deadlineExceeded
    case malformedMessage
    case messageTooLarge
    case unexpectedResponse
    case sessionMismatch
    case commandRejected(Int)
    case eventOverflow
    case cancelledRequestLimit
    case sessionInvalidated
    case targetDestroyed
    case identityLimit

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The browser debugging endpoint is not an explicit loopback browser WebSocket."
        case .invalidRequest: "The browser debugging request is invalid."
        case .requestLimit: "Too many browser debugging requests are pending."
        case .closed: "The browser debugging connection is closed."
        case .transportFailed: "The browser debugging connection failed."
        case .deadlineExceeded: "The browser debugging request timed out; its outcome may be unknown."
        case .malformedMessage: "The browser debugging connection received a malformed message."
        case .messageTooLarge: "The browser debugging message exceeded its size limit."
        case .unexpectedResponse: "The browser debugging response does not match a pending request."
        case .sessionMismatch: "The browser debugging response belongs to a different target session."
        case .commandRejected(let code): "The browser rejected a debugging command (code \(code))."
        case .eventOverflow: "The browser debugging event consumer fell behind; observation authority was revoked."
        case .cancelledRequestLimit: "Too many cancelled browser requests remain unresolved."
        case .sessionInvalidated: "The browser target session was detached or invalidated."
        case .targetDestroyed: "The browser target was destroyed before attachment completed."
        case .identityLimit: "The browser connection exceeded its lifecycle identity limit."
        }
    }
}

/// A browser-level, flattened-session CDP connection. This object neither
/// discovers endpoints nor launches/activates Chrome. Its owner supplies the
/// already-authorized endpoint and consumes the one bounded event stream.
actor BrowserCDPConnection {
    struct Configuration: Sendable {
        var maximumPendingRequests = 32
        var maximumMessageBytes = 4 * 1_024 * 1_024
        var maximumBufferedEvents = 128
        var maximumCancelledRequests = 128
        var maximumLifecycleIdentities = 1_024
        var requestTimeout: Duration = .seconds(15)
    }

    private struct Pending {
        let sessionID: String?
        let continuation: CheckedContinuation<Data, Error>
        let cancellation: BrowserCDPCancellation
        let deadline: Task<Void, Never>
        let attachmentTargetID: String?
    }

    private struct Cancelled {
        let sessionID: String?
    }

    nonisolated let events: AsyncThrowingStream<BrowserCDPEvent, Error>
    private let eventContinuation: AsyncThrowingStream<BrowserCDPEvent, Error>.Continuation
    private let wire: any BrowserCDPWire
    private let configuration: Configuration
    private var pending: [Int: Pending] = [:]
    // A cancelled, already-enqueued request can reply once. Unknown/duplicate
    // IDs are never ignored. Exhaustion disconnects instead of dropping identity.
    private var cancelled: [Int: Cancelled] = [:]
    private var nextID = 1
    private var receiver: Task<Void, Never>?
    private var terminalError: BrowserCDPConnectionError?
    private var invalidatedSessions = Set<String>()
    private var destroyedTargets = Set<String>()
    private var sessionTargets: [String: String] = [:]

    init(wire: any BrowserCDPWire, configuration: Configuration = Configuration()) {
        precondition(configuration.maximumPendingRequests > 0)
        precondition(configuration.maximumMessageBytes > 0)
        precondition(configuration.maximumBufferedEvents > 0)
        precondition(configuration.maximumCancelledRequests > 0)
        precondition(configuration.maximumLifecycleIdentities > 0)
        precondition(configuration.requestTimeout > .zero)
        self.wire = wire
        self.configuration = configuration
        let stream = AsyncThrowingStream<BrowserCDPEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(configuration.maximumBufferedEvents)
        )
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        receiver?.cancel()
        wire.close()
        eventContinuation.finish()
        for request in pending.values {
            request.deadline.cancel()
            request.continuation.resume(throwing: BrowserCDPConnectionError.closed)
        }
    }

    func command(
        method: String,
        params: Data = Data("{}".utf8),
        sessionID: String? = nil,
        permit: BrowserMutationPermit? = nil,
        beforeEnqueue: @escaping @Sendable () throws -> Void = {}
    ) async throws -> Data {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        if let sessionID { try checkSession(sessionID) }
        guard pending.count < configuration.maximumPendingRequests else {
            throw BrowserCDPConnectionError.requestLimit
        }
        guard Self.isMethod(method), params.count <= configuration.maximumMessageBytes,
              sessionID.map(Self.isSessionID) ?? true,
              let parameters = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
              nextID <= 9_007_199_254_740_991 else {
            throw BrowserCDPConnectionError.invalidRequest
        }
        let id = nextID
        nextID += 1
        var envelope: [String: Any] = ["id": id, "method": method, "params": parameters]
        if let sessionID { envelope["sessionId"] = sessionID }
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard data.count <= configuration.maximumMessageBytes else {
            throw BrowserCDPConnectionError.messageTooLarge
        }
        let cancellation = BrowserCDPCancellation()
        let attachmentTargetID = method == "Target.attachToTarget" ? parameters["targetId"] as? String : nil
        startReceiverIfNeeded()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    if let terminalError { throw terminalError }
                    if let sessionID { try checkSession(sessionID) }
                    try cancellation.check()
                    try Task.checkCancellation()
                    let timeout = configuration.requestTimeout
                    let deadline = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        await self?.expire(id: id)
                    }
                    pending[id] = Pending(
                        sessionID: sessionID, continuation: continuation,
                        cancellation: cancellation, deadline: deadline,
                        attachmentTargetID: attachmentTargetID
                    )
                    let wire = self.wire
                    let enqueue = {
                        if let sessionID { try self.checkSession(sessionID) }
                        try cancellation.enqueue {
                            try beforeEnqueue()
                            wire.enqueue(data) { result in
                                Task { await self.sendFinished(id: id, result: result) }
                            }
                        }
                    }
                    if let permit { try permit.commit(enqueue) } else { try enqueue() }
                } catch {
                    pending.removeValue(forKey: id)?.deadline.cancel()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(id: id) }
        }
    }

    func close() {
        disconnect(.closed)
    }

    /// Local lifecycle fence, not a network ping or a reconnection attempt.
    func checkConnection() throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
    }

    /// This is a revocation fence, not proof that an arbitrary session exists.
    /// The owner must obtain the session from an exact authorized attachment.
    func checkSession(_ sessionID: String) throws {
        if let terminalError { throw terminalError }
        guard Self.isSessionID(sessionID) else { throw BrowserCDPConnectionError.invalidRequest }
        guard !invalidatedSessions.contains(sessionID) else {
            throw BrowserCDPConnectionError.sessionInvalidated
        }
    }

    /// Immediately revokes local authority. Detaching the Chrome-side resource
    /// is separately owned by the adapter and never reattaches implicitly.
    func invalidateSession(_ sessionID: String) {
        guard terminalError == nil else { return }
        invalidatedSessions.insert(sessionID)
        sessionTargets.removeValue(forKey: sessionID)
        guard lifecycleWithinLimit() else { return }
        let affected = pending.filter { $0.value.sessionID == sessionID }
        for (id, request) in affected {
            pending.removeValue(forKey: id)
            request.deadline.cancel()
            request.continuation.resume(throwing: BrowserCDPConnectionError.sessionInvalidated)
            if request.cancellation.wasEnqueued {
                cancelled[id] = Cancelled(sessionID: request.sessionID)
            }
        }
        if cancelled.count > configuration.maximumCancelledRequests { disconnect(.cancelledRequestLimit) }
    }

    private func startReceiverIfNeeded() {
        guard receiver == nil else { return }
        let wire = wire
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await wire.receive()
                    guard let self else { wire.close(); return }
                    if !(await self.accept(message)) { return }
                }
            } catch {
                await self?.disconnect(.transportFailed)
            }
        }
    }

    private func sendFinished(id: Int, result: Result<Void, Error>) {
        guard terminalError == nil else { return }
        if case .failure = result {
            // A failed send may still have reached the peer. Never retry it.
            disconnect(.transportFailed)
        }
    }

    private func cancel(id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.continuation.resume(throwing: CancellationError())
        if request.cancellation.wasEnqueued {
            guard cancelled.count < configuration.maximumCancelledRequests else {
                disconnect(.cancelledRequestLimit)
                return
            }
            cancelled[id] = Cancelled(sessionID: request.sessionID)
        }
    }

    private func expire(id: Int) {
        guard pending[id] != nil else { return }
        // A timeout is an unknown outcome, not permission to replay a mutation.
        disconnect(.deadlineExceeded)
    }

    private func accept(_ data: Data) -> Bool {
        guard terminalError == nil else { return false }
        do {
            guard data.count <= configuration.maximumMessageBytes else {
                throw BrowserCDPConnectionError.messageTooLarge
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BrowserCDPConnectionError.malformedMessage
            }
            let sessionID: String?
            if let raw = object["sessionId"] {
                guard let value = raw as? String, Self.isSessionID(value) else {
                    throw BrowserCDPConnectionError.malformedMessage
                }
                sessionID = value
            } else { sessionID = nil }
            if let rawID = object["id"] {
                guard let id = Self.requestID(rawID), object["method"] == nil,
                      (object["result"] != nil) != (object["error"] != nil) else {
                    throw BrowserCDPConnectionError.malformedMessage
                }
                let result: Result<Data, BrowserCDPConnectionError>
                if let error = object["error"] {
                    guard let error = error as? [String: Any],
                          let code = Self.integer(error["code"]),
                          error["message"] is String else {
                        throw BrowserCDPConnectionError.malformedMessage
                    }
                    // Do not expose arbitrary peer messages, which may include
                    // page content, request arguments or endpoint credentials.
                    result = .failure(.commandRejected(code))
                } else {
                    guard let value = object["result"] as? [String: Any] else {
                        throw BrowserCDPConnectionError.malformedMessage
                    }
                    result = .success(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
                }
                if let prior = cancelled[id] {
                    guard prior.sessionID == sessionID else { throw BrowserCDPConnectionError.sessionMismatch }
                    cancelled.removeValue(forKey: id)
                    return true
                }
                guard let request = pending[id] else { throw BrowserCDPConnectionError.unexpectedResponse }
                guard request.sessionID == sessionID else { throw BrowserCDPConnectionError.sessionMismatch }
                if let targetID = request.attachmentTargetID, case .success(let bytes) = result {
                    guard let attachment = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          let attachedSession = attachment["sessionId"] as? String,
                          Self.isSessionID(attachedSession) else {
                        throw BrowserCDPConnectionError.malformedMessage
                    }
                    if destroyedTargets.contains(targetID) || invalidatedSessions.contains(attachedSession) {
                        invalidateSession(attachedSession)
                        guard terminalError == nil else { return false }
                        pending.removeValue(forKey: id)
                        request.deadline.cancel()
                        request.continuation.resume(throwing: BrowserCDPConnectionError.targetDestroyed)
                        return terminalError == nil
                    }
                    guard sessionTargets[attachedSession].map({ $0 == targetID }) ?? true else {
                        throw BrowserCDPConnectionError.sessionMismatch
                    }
                    sessionTargets[attachedSession] = targetID
                    guard lifecycleWithinLimit() else { return false }
                }
                pending.removeValue(forKey: id)
                request.deadline.cancel()
                if request.cancellation.isCancelled {
                    request.continuation.resume(throwing: CancellationError())
                } else {
                    request.continuation.resume(with: result.mapError { $0 as Error })
                }
            } else {
                guard object["result"] == nil, object["error"] == nil,
                      let method = object["method"] as? String, Self.isMethod(method) else {
                    throw BrowserCDPConnectionError.malformedMessage
                }
                let params: [String: Any]
                if let raw = object["params"] {
                    guard let value = raw as? [String: Any] else {
                        throw BrowserCDPConnectionError.malformedMessage
                    }
                    params = value
                } else { params = [:] }
                // Lifecycle authority is updated before publishing the event.
                // A delayed consumer cannot let the next response resurrect it.
                if method == "Target.detachedFromTarget" {
                    guard let detached = params["sessionId"] as? String, Self.isSessionID(detached) else {
                        throw BrowserCDPConnectionError.malformedMessage
                    }
                    invalidateSession(detached)
                } else if method == "Target.targetDestroyed" || method == "Target.targetCrashed" {
                    guard let target = params["targetId"] as? String, Self.isSessionID(target) else {
                        throw BrowserCDPConnectionError.malformedMessage
                    }
                    destroyedTargets.insert(target)
                    guard lifecycleWithinLimit() else { return false }
                    for session in sessionTargets.filter({ $0.value == target }).map(\.key) {
                        invalidateSession(session)
                    }
                } else if method == "Target.attachedToTarget" {
                    guard let attached = params["sessionId"] as? String, Self.isSessionID(attached),
                          let info = params["targetInfo"] as? [String: Any],
                          let target = info["targetId"] as? String, Self.isSessionID(target) else {
                        throw BrowserCDPConnectionError.malformedMessage
                    }
                    if destroyedTargets.contains(target) || invalidatedSessions.contains(attached) {
                        invalidateSession(attached)
                    } else {
                        guard sessionTargets[attached].map({ $0 == target }) ?? true else {
                            throw BrowserCDPConnectionError.sessionMismatch
                        }
                        sessionTargets[attached] = target
                        guard lifecycleWithinLimit() else { return false }
                    }
                }
                guard terminalError == nil else { return false }
                let event = BrowserCDPEvent(
                    method: method,
                    params: try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
                    sessionID: sessionID
                )
                switch eventContinuation.yield(event) {
                case .enqueued: break
                case .dropped: throw BrowserCDPConnectionError.eventOverflow
                case .terminated: throw BrowserCDPConnectionError.closed
                @unknown default: throw BrowserCDPConnectionError.eventOverflow
                }
            }
            return true
        } catch let error as BrowserCDPConnectionError {
            disconnect(error)
        } catch {
            disconnect(.malformedMessage)
        }
        return false
    }

    private func disconnect(_ error: BrowserCDPConnectionError) {
        guard terminalError == nil else { return }
        terminalError = error
        wire.close()
        receiver?.cancel()
        receiver = nil
        let abandoned = pending
        pending.removeAll()
        cancelled.removeAll()
        for request in abandoned.values {
            request.deadline.cancel()
            request.continuation.resume(throwing: error)
        }
        eventContinuation.finish(throwing: error)
    }

    @discardableResult
    private func lifecycleWithinLimit() -> Bool {
        guard invalidatedSessions.count + destroyedTargets.count + sessionTargets.count
                <= configuration.maximumLifecycleIdentities else {
            disconnect(.identityLimit)
            return false
        }
        return true
    }

    private static func requestID(_ value: Any) -> Int? {
        guard let value = integer(value), value > 0, value <= 9_007_199_254_740_991 else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= -9_007_199_254_740_991, double <= 9_007_199_254_740_991 else { return nil }
        return value.intValue
    }

    private static func isMethod(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 128 && pieces.count == 2 && pieces.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }
    }

    private static func isSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

/// Locking here closes the cancellation-vs-synchronous-enqueue gap without
/// holding a lock across a response, actor hop or network await.
private final class BrowserCDPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var enqueued = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    var wasEnqueued: Bool { lock.withLock { enqueued } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        try lock.withLock { if cancelled { throw CancellationError() } }
    }
    func enqueue(_ operation: () throws -> Void) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try operation()
            enqueued = true
        }
    }
}

/// Explicit-endpoint wire only. Discovery and user consent belong to the owner.
final class URLSessionBrowserCDPWire: BrowserCDPWire, @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var closed = false

    init(endpoint: URL, maximumMessageBytes: Int = 4 * 1_024 * 1_024) throws {
        try Self.validate(endpoint: endpoint)
        guard maximumMessageBytes > 0 else { throw BrowserCDPConnectionError.invalidRequest }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 0
        session = URLSession(configuration: configuration, delegate: BrowserCDPNoRedirectDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: endpoint)
        task.maximumMessageSize = maximumMessageBytes
        task.resume()
    }

    static func validate(endpoint: URL) throws {
        guard endpoint.scheme == "ws", ["127.0.0.1", "::1", "[::1]"].contains(endpoint.host ?? ""),
              let port = endpoint.port, (1...65_535).contains(port),
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.absoluteString.utf8.count <= 1_024 else {
            throw BrowserCDPConnectionError.invalidEndpoint
        }
        let prefix = "/devtools/browser/"
        guard endpoint.path.hasPrefix(prefix) else { throw BrowserCDPConnectionError.invalidEndpoint }
        let token = endpoint.path.dropFirst(prefix.count)
        guard !token.isEmpty, token.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.percentEncodedPath == endpoint.path else {
            throw BrowserCDPConnectionError.invalidEndpoint
        }
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        lock.withLock {
            guard !closed else { completion(.failure(BrowserCDPConnectionError.closed)); return }
            guard let text = String(data: data, encoding: .utf8) else {
                completion(.failure(BrowserCDPConnectionError.invalidRequest)); return
            }
            task.send(.string(text)) { error in
                if error != nil { completion(.failure(BrowserCDPConnectionError.transportFailed)) }
                else { completion(.success(())) }
            }
        }
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: throw BrowserCDPConnectionError.malformedMessage
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
    }

    deinit { close() }
}

/// A loopback endpoint must not redirect the debugger connection to another
/// process, host or path. Consent and process attribution cover only the
/// original validated endpoint, never an HTTP Location supplied by a peer.
private final class BrowserCDPNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

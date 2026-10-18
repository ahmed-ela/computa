import Foundation
@preconcurrency import WebKit

/// The source interface deliberately has no mutation operation. Cookie objects
/// stay in memory; neither their values nor identifying names enter diagnostics.
@MainActor protocol ChatGPTInferenceCookieSource: AnyObject {
    func read(_ completion: @escaping @MainActor ([HTTPCookie]) -> Void)
}

@MainActor protocol ChatGPTInferenceCookieDestination: ChatGPTInferenceCookieSource {
    func set(_ cookie: HTTPCookie, completion: @escaping @MainActor () -> Void)
}

@MainActor final class ChatGPTWKInferenceCookieStore: ChatGPTInferenceCookieDestination {
    // Retain the whole store through an issued callback, including after the
    // caller times out, cancels or shuts its browser down.
    private let store: WKWebsiteDataStore
    init(_ store: WKWebsiteDataStore) { self.store = store }
    func read(_ completion: @escaping @MainActor ([HTTPCookie]) -> Void) {
        store.httpCookieStore.getAllCookies(completion)
    }
    func set(_ cookie: HTTPCookie, completion: @escaping @MainActor () -> Void) {
        store.httpCookieStore.setCookie(cookie, completionHandler: completion)
    }
}

/// One fresh inference store, seeded once. A deadline ends the caller's wait,
/// but an issued WebKit callback retains this operation's reservation until it
/// actually returns. No callback after failure may issue another read or write.
@MainActor final class ChatGPTInferenceCookieSeed {
    struct Summary: Equatable {
        let sourceCookieCount: Int
        let eligibleCookieCount: Int
        let excludedConversationCookieCount: Int
        let seededCookieCount: Int
        let estimatedCookieHeaderUTF8Bytes: Int?
    }
    struct Selection {
        let cookies: [HTTPCookie]
        let eligibleCookieCount: Int
        let excludedConversationCookieCount: Int
    }
    enum Failure: Error, LocalizedError, Equatable {
        case unavailable, bounds, invalidSource, destinationNotEmpty, verificationFailed, deadline
        var errorDescription: String? {
            "The private ChatGPT browser profile could not be prepared. No website prompt was submitted."
        }
    }

    private let source: any ChatGPTInferenceCookieSource
    private let destination: any ChatGPTInferenceCookieDestination
    private var continuation: CheckedContinuation<Void, any Error>?
    private var pending: UUID?
    private var timer: Task<Void, Never>?
    private var terminal: (any Error)?
    private var started = false
    private var drained = false
    private var deadline: ContinuousClock.Instant = .now
    private var isCurrent: @MainActor () -> Bool = { false }
    private var onDrained: @MainActor () -> Void = {}
    private var selected: [HTTPCookie] = []
    private let cancellation = CookieSeedCancellation()
    private var selectionCounts: Summary?
    private(set) var verifiedSummary: Summary?
    /// Retained only in memory for an optional consume-once preloaded page.
    private(set) var verifiedSourceCookies: [HTTPCookie]?
    var hasFailedCallerAwaitingCallback: Bool { terminal != nil && pending != nil && !drained }

    init(source: any ChatGPTInferenceCookieSource, destination: any ChatGPTInferenceCookieDestination) {
        self.source = source; self.destination = destination
    }

    func run(until deadline: ContinuousClock.Instant, isCurrent: @escaping @MainActor () -> Bool,
             onDrained: @escaping @MainActor () -> Void) async throws {
        guard !started else { throw Failure.unavailable }
        started = true; self.deadline = deadline; self.isCurrent = isCurrent; self.onDrained = onDrained
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do { try check() } catch { fail(error); return }
                timer = Task { @MainActor [self] in
                    do { try await Task.sleep(until: deadline) } catch { return }
                    fail(Failure.deadline)
                }
                readSource()
            }
        } onCancel: {
            self.cancellation.cancel()
            Task { @MainActor [self] in fail(CancellationError()) }
        }
    }

    func cancel() { fail(CancellationError()) }

    private func check() throws {
        try Task.checkCancellation()
        if cancellation.isCancelled { throw CancellationError() }
        guard terminal == nil, isCurrent() else { throw Failure.unavailable }
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
    }

    private func fail(_ error: any Error) {
        guard terminal == nil, !drained else { return }
        terminal = error
        timer?.cancel(); timer = nil
        let waiter = continuation; continuation = nil
        waiter?.resume(throwing: error)
        drainIfPossible()
    }

    private func drainIfPossible() {
        guard pending == nil, !drained else { return }
        drained = true; timer?.cancel(); timer = nil
        selected.removeAll()
        let callback = onDrained
        onDrained = {}; isCurrent = { false }
        callback()
    }

    private func receive(_ ticket: UUID, action: () throws -> Void) {
        guard pending == ticket else { return }
        pending = nil
        if terminal != nil { drainIfPossible(); return }
        do { try check(); try action() } catch { fail(error) }
    }

    private func readSource() {
        let ticket = UUID(); pending = ticket
        source.read { [self] cookies in
            receive(ticket) {
                let selection = try Self.select(cookies, now: Date())
                selected = selection.cookies
                selectionCounts = Summary(sourceCookieCount: cookies.count, eligibleCookieCount: selection.eligibleCookieCount,
                    excludedConversationCookieCount: selection.excludedConversationCookieCount, seededCookieCount: selected.count,
                    estimatedCookieHeaderUTF8Bytes: ChatGPTProfileCookieBudget.estimate(cookies: selected)?.estimatedCookieHeaderUTF8Bytes)
                readEmptyDestination()
            }
        }
    }

    private func readEmptyDestination() {
        do { try check() } catch { fail(error); return }
        let ticket = UUID(); pending = ticket
        destination.read { [self] cookies in
            receive(ticket) {
                guard cookies.isEmpty else { throw Failure.destinationNotEmpty }
                write(index: 0)
            }
        }
    }

    private func write(index: Int) {
        do { try check() } catch { fail(error); return }
        guard index < selected.count else { verify(); return }
        let ticket = UUID(); pending = ticket
        // Preserve the original native object and every attribute. There is no
        // reconstruction from name/value strings and no mutation of the source.
        destination.set(selected[index]) { [self] in receive(ticket) { write(index: index + 1) } }
    }

    private func verify() {
        let ticket = UUID(); pending = ticket
        destination.read { [self] cookies in
            receive(ticket) {
                guard cookies.count == selected.count else { throw Failure.verificationFailed }
                var remaining = cookies
                for expected in selected {
                    guard let index = remaining.firstIndex(where: { Self.sameCookie(expected, $0) }) else { throw Failure.verificationFailed }
                    remaining.remove(at: index)
                }
                try check()
                verifiedSummary = selectionCounts
                verifiedSourceCookies = selected
                let waiter = continuation; continuation = nil
                drainIfPossible()
                waiter?.resume()
            }
        }
    }

    /// Creation metadata may legitimately change when WebKit stores a cookie.
    /// Authentication/policy attributes and all string bytes must survive;
    /// Unicode-equivalent but byte-different values do not establish equality.
    fileprivate static func sameCookie(_ left: HTTPCookie, _ right: HTTPCookie) -> Bool {
        func equal(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
        return equal(left.domain, right.domain) && equal(left.path, right.path) && equal(left.name, right.name)
            && equal(left.value, right.value) && left.isSecure == right.isSecure && left.isHTTPOnly == right.isHTTPOnly
            && left.isSessionOnly == right.isSessionOnly && left.expiresDate == right.expiresDate
            && left.version == right.version && left.portList == right.portList && left.sameSitePolicy == right.sameSitePolicy
    }

    /// Fixed ChatGPT DNS scope only. Unknown conversation-like names or paths
    /// are not classified as conversation cookies. No auth-name allowlist is
    /// guessed: all other eligible ChatGPT cookies retain their exact objects.
    static func select(_ cookies: [HTTPCookie], now: Date) throws -> Selection {
        guard cookies.count <= 4_096, now.timeIntervalSince1970.isFinite else { throw Failure.bounds }
        var bytes = 0, identities = Set<Data>(), selected: [HTTPCookie] = []
        var eligible = 0, excluded = 0
        for cookie in cookies {
            for field in [cookie.domain, cookie.path, cookie.name, cookie.value] {
                let count = field.utf8.prefix(65_537).count
                guard count <= 65_536, bytes <= 1_048_576 - count else { throw Failure.bounds }
                bytes += count
            }
            guard !cookie.domain.contains("\0"), !cookie.path.contains("\0"), !cookie.name.contains("\0"),
                  cookie.properties != nil else { throw Failure.invalidSource }
            let identity = Data((cookie.domain + "\0" + cookie.path + "\0" + cookie.name).utf8)
            guard identities.insert(identity).inserted else { throw Failure.invalidSource }
            if let expiry = cookie.expiresDate {
                guard expiry.timeIntervalSince1970.isFinite else { throw Failure.invalidSource }
                if expiry <= now { continue }
            }
            var host = cookie.domain.lowercased()
            if host.hasPrefix(".") { host.removeFirst() }
            guard host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") else { continue }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.utf8.count <= 253, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }), cookie.path.hasPrefix("/") else { throw Failure.invalidSource }
            eligible += 1
            let conversation = ChatGPTTemporaryConversationCookies.canonicalID(name: cookie.name, prefix: "conv_key_") != nil
                || ChatGPTTemporaryConversationCookies.canonicalID(name: cookie.name, prefix: "history_off_") != nil
            if host == "chatgpt.com", cookie.path == "/", conversation {
                excluded += 1
                continue
            }
            guard selected.count < 512 else { throw Failure.bounds }
            selected.append(cookie)
        }
        return Selection(cookies: selected, eligibleCookieCount: eligible, excludedConversationCookieCount: excluded)
    }
}

/// One bounded read-only claim check. A timed-out/cancelled callback retains
/// its reservation until arrival, but can never issue another operation.
@MainActor final class ChatGPTInferenceCookieValidation {
    private let source: any ChatGPTInferenceCookieSource
    private let cancellation = CookieSeedCancellation()
    private var continuation: CheckedContinuation<Bool, any Error>?
    private var timer: Task<Void, Never>?
    private var terminal = false, pending = false, started = false
    private var onDrained: @MainActor () -> Void = {}
    var hasFailedCallerAwaitingCallback: Bool { terminal && pending }

    init(source: any ChatGPTInferenceCookieSource) { self.source = source }

    func cancel() { cancellation.cancel(); finish(.failure(CancellationError())) }

    func run(expected: [HTTPCookie], until deadline: ContinuousClock.Instant,
             isCurrent: @escaping @MainActor () -> Bool, onDrained: @escaping @MainActor () -> Void) async throws -> Bool {
        guard !started else { throw ChatGPTInferenceCookieSeed.Failure.unavailable }
        started = true; self.onDrained = onDrained
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled, !cancellation.isCancelled else { finish(.failure(CancellationError())); return }
                guard isCurrent(), ContinuousClock.now < deadline else {
                    finish(.failure(ChatGPTInferenceCookieSeed.Failure.unavailable)); return
                }
                pending = true
                timer = Task { @MainActor [self] in
                    do { try await Task.sleep(until: deadline) } catch { return }
                    finish(.failure(ChatGPTInferenceCookieSeed.Failure.deadline))
                }
                source.read { [self] cookies in
                    guard pending else { return }
                    pending = false
                    if terminal { drain(); return }
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        guard isCurrent(), ContinuousClock.now < deadline else { throw ChatGPTInferenceCookieSeed.Failure.unavailable }
                        let actual = try ChatGPTInferenceCookieSeed.select(cookies, now: Date()).cookies
                        var remaining = actual
                        var matches = expected.count == actual.count
                        for cookie in expected where matches {
                            guard let index = remaining.firstIndex(where: { ChatGPTInferenceCookieSeed.sameCookie(cookie, $0) }) else {
                                matches = false; break
                            }
                            remaining.remove(at: index)
                        }
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        guard isCurrent(), ContinuousClock.now < deadline else { throw ChatGPTInferenceCookieSeed.Failure.unavailable }
                        finish(.success(matches))
                    } catch { finish(.failure(error)) }
                }
            }
        } onCancel: {
            self.cancellation.cancel()
            Task { @MainActor [self] in finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Bool, any Error>) {
        guard !terminal else { return }
        terminal = true; timer?.cancel(); timer = nil
        let waiter = continuation; continuation = nil
        waiter?.resume(with: result)
        if !pending { drain() }
    }

    private func drain() {
        let callback = onDrained
        onDrained = {}
        callback()
    }
}

/// Cancellation may arrive off the main actor before its handler task runs.
/// Every native callback sees this latch before it can chain another operation.
private final class CookieSeedCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

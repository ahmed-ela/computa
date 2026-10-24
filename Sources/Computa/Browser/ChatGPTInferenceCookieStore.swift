import Foundation
import OSLog
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
        let ignoredOutOfScopeDuplicateCount: Int
    }
    enum Failure: Error, LocalizedError, Equatable {
        case unavailable, bounds, invalidSource, destinationNotEmpty, verificationFailed, deadline
        var errorDescription: String? {
            "The private ChatGPT browser profile could not be prepared. No website prompt was submitted."
        }
    }
    /// Closed diagnostic data only. Counts saturate at the existing limit plus
    /// one; no cookie string, identity, source index or arbitrary error is kept.
    struct FailureDiagnostic: Equatable, Sendable {
        enum Phase: String, Sendable { case admission, sourceRead = "source_read", sourceSelection = "source_selection", destinationEmpty = "destination_empty", write, verify }
        enum Code: String, Sendable { case unavailable, bounds, invalidSource = "invalid_source", destinationNotEmpty = "destination_not_empty", verificationFailed = "verification_failed", deadline, cancelled, unknown }
        enum Reason: String, Sendable {
            case unavailable, deadline, cancelled, unknown
            case sourceCount = "source_count_bound", clock = "nonfinite_clock", fieldBytes = "field_byte_bound", totalBytes = "total_byte_bound"
            case invalidFields = "invalid_fields", duplicateIdentity = "duplicate_identity", nonfiniteExpiry = "nonfinite_expiry"
            case invalidScopeFields = "invalid_scope_fields", selectedCount = "selected_count_bound"
            case destinationNotEmpty = "destination_not_empty", verificationCount = "verification_count_mismatch", verificationAttributes = "verification_attributes_mismatch"
        }
        enum Comparison: String, Sendable { case uniqueIdentity = "unique_identity", singleRemaining = "single_remaining" }
        // Bit positions: domain, path, name, value, secure, HTTPOnly, session,
        // expiry, version, ports, SameSite. The mask carries no attribute value.
        let phase: Phase
        let code: Code
        let reason: Reason
        let sourceCount: Int?
        let eligibleCount: Int?
        let selectedCount: Int?
        let destinationCount: Int?
        let completedWrites: Int
        let measuredFieldBytes: Int?
        let attributeMismatchMask: Int?
        let comparison: Comparison?

        init(phase: Phase, code: Code, reason: Reason, sourceCount: Int? = nil, eligibleCount: Int? = nil,
             selectedCount: Int? = nil, destinationCount: Int? = nil, completedWrites: Int = 0, measuredFieldBytes: Int? = nil,
             attributeMismatchMask: Int? = nil, comparison: Comparison? = nil) {
            self.phase = phase; self.code = code; self.reason = reason
            self.sourceCount = sourceCount.map { min(max($0, 0), 4_097) }
            self.eligibleCount = eligibleCount.map { min(max($0, 0), 4_097) }
            self.selectedCount = selectedCount.map { min(max($0, 0), 513) }
            self.destinationCount = destinationCount.map { min(max($0, 0), 4_097) }
            self.completedWrites = min(max(completedWrites, 0), 512)
            self.measuredFieldBytes = measuredFieldBytes.map { min(max($0, 0), 1_048_577) }
            self.attributeMismatchMask = attributeMismatchMask.map { $0 & 2_047 }
            self.comparison = comparison
        }

        var record: String {
            "cookieSeedFailure version=1 phase=\(phase.rawValue) code=\(code.rawValue) reason=\(reason.rawValue) sourceCount=\(sourceCount ?? -1) eligibleCount=\(eligibleCount ?? -1) selectedCount=\(selectedCount ?? -1) destinationCount=\(destinationCount ?? -1) completedWrites=\(completedWrites) measuredFieldBytes=\(measuredFieldBytes ?? -1) attributeMismatchMask=\(attributeMismatchMask ?? -1) comparison=\(comparison?.rawValue ?? "unavailable")"
        }
        static func code(for error: any Error) -> Code {
            if error is CancellationError { return .cancelled }
            switch error as? Failure {
            case .unavailable: return .unavailable
            case .bounds: return .bounds
            case .invalidSource: return .invalidSource
            case .destinationNotEmpty: return .destinationNotEmpty
            case .verificationFailed: return .verificationFailed
            case .deadline: return .deadline
            case nil: return .unknown
            }
        }
    }
    private static let failureLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "InferenceCookieSeed")

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
    private var diagnosticPhase: FailureDiagnostic.Phase = .admission
    private var diagnosticReason: FailureDiagnostic.Reason?
    private var sourceCount: Int?
    private var destinationCount: Int?
    private var completedWrites = 0
    private var selectionFailure: FailureDiagnostic?
    private var verificationMismatch: (mask: Int, comparison: FailureDiagnostic.Comparison)?
    private(set) var failureDiagnostic: FailureDiagnostic?
    #if DEBUG
    var failureDiagnosticObserverForTesting: ((FailureDiagnostic) -> Void)?
    #endif
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
        let code = FailureDiagnostic.code(for: error)
        let reason: FailureDiagnostic.Reason = diagnosticReason ?? (code == .cancelled ? .cancelled : code == .deadline ? .deadline : code == .unavailable ? .unavailable : .unknown)
        let diagnostic = selectionFailure ?? FailureDiagnostic(phase: diagnosticPhase, code: code, reason: reason,
            sourceCount: sourceCount, eligibleCount: selectionCounts?.eligibleCookieCount,
            selectedCount: selectionCounts?.seededCookieCount, destinationCount: destinationCount, completedWrites: completedWrites,
            attributeMismatchMask: verificationMismatch?.mask, comparison: verificationMismatch?.comparison)
        failureDiagnostic = diagnostic
        Self.failureLog.error("\(diagnostic.record, privacy: .public)")
        #if DEBUG
        failureDiagnosticObserverForTesting?(diagnostic)
        #endif
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
        diagnosticPhase = .sourceRead
        let ticket = UUID(); pending = ticket
        source.read { [self] cookies in
            receive(ticket) {
                diagnosticPhase = .sourceSelection; sourceCount = cookies.count
                let selection = try Self.select(cookies, now: Date(), onFailure: { self.selectionFailure = $0 })
                Self.failureLog.notice("cookieSeedSelection version=1 sourceCount=\(cookies.count) eligibleCount=\(selection.eligibleCookieCount) selectedCount=\(selection.cookies.count) ignoredOutOfScopeDuplicateCount=\(selection.ignoredOutOfScopeDuplicateCount)")
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
        diagnosticPhase = .destinationEmpty
        let ticket = UUID(); pending = ticket
        destination.read { [self] cookies in
            receive(ticket) {
                destinationCount = cookies.count
                guard cookies.isEmpty else { diagnosticReason = .destinationNotEmpty; throw Failure.destinationNotEmpty }
                write(index: 0)
            }
        }
    }

    private func write(index: Int) {
        do { try check() } catch { fail(error); return }
        guard index < selected.count else { verify(); return }
        diagnosticPhase = .write
        let ticket = UUID(); pending = ticket
        // Preserve the original native object and every attribute. There is no
        // reconstruction from name/value strings and no mutation of the source.
        destination.set(selected[index]) { [self] in receive(ticket) { completedWrites += 1; write(index: index + 1) } }
    }

    private func verify() {
        diagnosticPhase = .verify
        let ticket = UUID(); pending = ticket
        destination.read { [self] cookies in
            receive(ticket) {
                destinationCount = cookies.count
                guard cookies.count == selected.count else { diagnosticReason = .verificationCount; throw Failure.verificationFailed }
                var remaining = cookies
                for expected in selected {
                    guard let index = remaining.firstIndex(where: { Self.sameCookie(expected, $0) }) else {
                        verificationMismatch = Self.attributeMismatch(expected, remaining: remaining)
                        diagnosticReason = .verificationAttributes; throw Failure.verificationFailed
                    }
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

    private static func attributeMismatch(_ expected: HTTPCookie, remaining: [HTTPCookie]) -> (mask: Int, comparison: FailureDiagnostic.Comparison)? {
        func equal(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
        let matches = remaining.filter { equal(expected.domain, $0.domain) && equal(expected.path, $0.path) && equal(expected.name, $0.name) }
        let actual: HTTPCookie, comparison: FailureDiagnostic.Comparison
        if matches.count == 1 { actual = matches[0]; comparison = .uniqueIdentity }
        else if remaining.count == 1 { actual = remaining[0]; comparison = .singleRemaining }
        else { return nil }
        let differences = [!equal(expected.domain, actual.domain), !equal(expected.path, actual.path),
            !equal(expected.name, actual.name), !equal(expected.value, actual.value), expected.isSecure != actual.isSecure,
            expected.isHTTPOnly != actual.isHTTPOnly, expected.isSessionOnly != actual.isSessionOnly,
            expected.expiresDate != actual.expiresDate, expected.version != actual.version,
            expected.portList != actual.portList, expected.sameSitePolicy != actual.sameSitePolicy]
        let mask = differences.enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) }
        return (mask, comparison)
    }

    /// Fixed ChatGPT DNS scope only. Unknown conversation-like names or paths
    /// are not classified as conversation cookies. No auth-name allowlist is
    /// guessed: all other eligible ChatGPT cookies retain their exact objects.
    static func select(_ cookies: [HTTPCookie], now: Date, onFailure: ((FailureDiagnostic) -> Void)? = nil) throws -> Selection {
        var bytes = 0, identities = Set<Data>(), selected: [HTTPCookie] = []
        var eligible = 0, excluded = 0, ignoredOutOfScopeDuplicates = 0
        func reject(_ failure: Failure, _ reason: FailureDiagnostic.Reason) -> Failure {
            onFailure?(FailureDiagnostic(phase: .sourceSelection, code: FailureDiagnostic.code(for: failure), reason: reason,
                sourceCount: cookies.count, eligibleCount: eligible, selectedCount: selected.count, measuredFieldBytes: bytes))
            return failure
        }
        guard cookies.count <= 4_096 else { throw reject(.bounds, .sourceCount) }
        guard now.timeIntervalSince1970.isFinite else { throw reject(.bounds, .clock) }
        for cookie in cookies {
            for field in [cookie.domain, cookie.path, cookie.name, cookie.value] {
                let count = field.utf8.prefix(65_537).count
                guard count <= 65_536 else { throw reject(.bounds, .fieldBytes) }
                guard bytes <= 1_048_576 - count else { throw reject(.bounds, .totalBytes) }
                bytes += count
            }
            guard !cookie.domain.contains("\0"), !cookie.path.contains("\0"), !cookie.name.contains("\0"),
                  cookie.properties != nil else { throw reject(.invalidSource, .invalidFields) }
            var host = cookie.domain.lowercased()
            if host.hasPrefix(".") { host.removeFirst() }
            let inScope = host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
            let identity = Data((cookie.domain + "\0" + cookie.path + "\0" + cookie.name).utf8)
            if !identities.insert(identity).inserted {
                // The shared source contains unrelated websites. Their identity
                // ambiguity cannot affect this fresh ChatGPT-only destination.
                // Keep in-scope rejection before expiry, as in the original policy.
                guard !inScope else { throw reject(.invalidSource, .duplicateIdentity) }
                ignoredOutOfScopeDuplicates += 1
            }
            if let expiry = cookie.expiresDate {
                guard expiry.timeIntervalSince1970.isFinite else { throw reject(.invalidSource, .nonfiniteExpiry) }
                if expiry <= now { continue }
            }
            guard inScope else { continue }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.utf8.count <= 253, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }), cookie.path.hasPrefix("/") else { throw reject(.invalidSource, .invalidScopeFields) }
            eligible += 1
            let conversation = ChatGPTTemporaryConversationCookies.canonicalID(name: cookie.name, prefix: "conv_key_") != nil
                || ChatGPTTemporaryConversationCookies.canonicalID(name: cookie.name, prefix: "history_off_") != nil
            if host == "chatgpt.com", cookie.path == "/", conversation {
                excluded += 1
                continue
            }
            guard selected.count < 512 else { throw reject(.bounds, .selectedCount) }
            selected.append(cookie)
        }
        return Selection(cookies: selected, eligibleCookieCount: eligible, excludedConversationCookieCount: excluded,
            ignoredOutOfScopeDuplicateCount: ignoredOutOfScopeDuplicates)
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

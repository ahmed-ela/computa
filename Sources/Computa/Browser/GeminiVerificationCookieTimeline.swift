import Foundation
import WebKit

/// Read-only, store-lifetime observations. Neither a sample nor its absence is
/// cookie transmission evidence or permission to resume a blocked website.
@MainActor
final class GeminiVerificationCookieTimeline: NSObject, WKHTTPCookieStoreObserver {
    enum Trigger: String, CaseIterable, Encodable, Sendable {
        case initial, storeChanged, navigationSettled, challengeSettled, modelClosed, shutdownRequested

        fileprivate var reservesLifecycleBudget: Bool {
            switch self {
            case .initial, .challengeSettled, .modelClosed, .shutdownRequested: true
            case .storeChanged, .navigationSettled: false
            }
        }
    }

    struct Event: Encodable, Sendable {
        enum Phase: String, Encodable, Sendable { case intent, requested, sample, gap, stopped }
        enum Status: String, Encodable, Sendable { case pending, available, unavailable }
        enum Reason: String, Encodable, Sendable {
            case deadlineExceeded, supersededByStoreChange, lateCallbackDiscarded, stopped
            case readBudgetExhausted, logBudgetExhausted, coalesced, invalidClock
        }
        let kind = "gemini_verification_cookie_timeline_v1"
        let evidence = "callback_time_native_metadata_not_request_cookie_proof"
        let sequence: Int
        let read: Int?
        let triggers: [Trigger]
        let phase: Phase
        let status: Status
        let reason: Reason?
        let coalescedTriggerCount: Int
        let duplicateSamplesSuppressed: Int
        let metadata: GeminiVerificationCookieDiagnostic.TimelineSnapshot?
    }

    struct Limits: Sendable {
        var windowSeconds: TimeInterval = 60
        var readTimeoutSeconds: TimeInterval = 2
        var regularReads = 12
        var lifecycleReads = 3
        var shutdownReads = 1
        var regularEvents = 32
        var lifecycleEvents = 8
        var shutdownEvents = 4
    }

    typealias Callback = @MainActor @Sendable ([HTTPCookie]) -> Void
    typealias Reader = @MainActor @Sendable (@escaping Callback) -> Void
    typealias Cancellation = @MainActor @Sendable () -> Void
    typealias Scheduler = @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Cancellation

    private struct Budget {
        var regular: [TimeInterval] = [], lifecycle: [TimeInterval] = [], shutdown: [TimeInterval] = []

        mutating func consume(at now: TimeInterval, window: TimeInterval, triggers: [Trigger],
                              regularLimit: Int, lifecycleLimit: Int, shutdownLimit: Int) -> Bool {
            regular.removeAll { now - $0 >= window }
            lifecycle.removeAll { now - $0 >= window }
            shutdown.removeAll { now - $0 >= window }
            if regular.count < regularLimit { regular.append(now); return true }
            if triggers.contains(.shutdownRequested), shutdown.count < shutdownLimit {
                shutdown.append(now); return true
            }
            if triggers.contains(where: \.reservesLifecycleBudget), lifecycle.count < lifecycleLimit {
                lifecycle.append(now); return true
            }
            return false
        }
    }

    @MainActor private final class Ticket {
        let id: Int
        let triggers: [Trigger]
        let revision: Int
        var cancelDeadline: Cancellation?
        var completed = false
        var timedOut = false
        init(id: Int, triggers: [Trigger], revision: Int) {
            self.id = id; self.triggers = triggers; self.revision = revision
        }
    }

    private let store: WKHTTPCookieStore
    private let sink: @MainActor @Sendable (Event) -> Void
    private let reader: Reader
    private let now: @MainActor @Sendable () -> Date
    private let uptime: @MainActor @Sendable () -> TimeInterval
    private let schedule: Scheduler
    private let limits: Limits
    private var started = false
    private var stopped = false
    private var inFlight: Ticket?
    private var pending: Set<Trigger> = []
    private var coalesced = 0
    private var revision = 0
    private var readSequence = 0
    private var eventSequence = 0
    private var reads = Budget(), events = Budget()
    private var lastSnapshot: GeminiVerificationCookieDiagnostic.TimelineSnapshot?
    private var suppressedDuplicates = 0
    private var lastBudgetGap: TimeInterval?
    private var lastUptime: TimeInterval?
    private var invalidClockReported = false
    private var shutdownIntentReported = false

    init(store: WKHTTPCookieStore, sink: @escaping @MainActor @Sendable (Event) -> Void,
         limits: Limits = Limits(), reader: Reader? = nil,
         now: @escaping @MainActor @Sendable () -> Date = { Date() },
         uptime: @escaping @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduler: Scheduler? = nil) {
        precondition(limits.windowSeconds.isFinite && limits.windowSeconds > 0)
        precondition(limits.readTimeoutSeconds.isFinite && limits.readTimeoutSeconds > 0)
        precondition([limits.regularReads, limits.lifecycleReads, limits.shutdownReads,
                      limits.regularEvents, limits.lifecycleEvents, limits.shutdownEvents].allSatisfy { $0 >= 0 && $0 <= 128 })
        self.store = store; self.sink = sink; self.limits = limits
        self.reader = reader ?? { completion in store.getAllCookies(completion) }
        self.now = now; self.uptime = uptime
        self.schedule = scheduler ?? { delay, action in
            let task = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        }
        super.init()
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        store.add(self)
        observe(.initial)
    }

    func observe(_ trigger: Trigger) {
        guard started, !stopped else { return }
        if trigger == .storeChanged { revision += 1 }
        pending.insert(trigger)
        if trigger == .shutdownRequested, !shutdownIntentReported {
            shutdownIntentReported = true
            // Record the boundary even when an earlier native read never returns
            // before termination. This is an intent, not a new read or snapshot.
            emit(read: nil, triggers: [.shutdownRequested], phase: .intent, status: .pending)
        }
        if inFlight != nil { coalesced = min(255, coalesced + 1); return }
        drain()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard cookieStore === store else { return }
        observe(.storeChanged)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if started { store.remove(self) }
        let ticket = inFlight
        let stoppedTriggers = ordered(pending.union(ticket?.triggers ?? []))
        ticket?.cancelDeadline?()
        inFlight = nil
        pending.removeAll()
        lastSnapshot = nil
        // One final finite record even if a burst exhausted the rolling budget.
        publish(read: ticket?.id, triggers: stoppedTriggers, phase: .stopped,
                status: .unavailable, reason: .stopped)
    }

    private func currentUptime() -> TimeInterval? {
        let value = uptime()
        guard value.isFinite, value >= 0, lastUptime.map({ value >= $0 }) ?? true else {
            if !invalidClockReported {
                invalidClockReported = true
                publish(read: inFlight?.id, triggers: ordered(pending), phase: .gap,
                        status: .unavailable, reason: .invalidClock)
            }
            return nil
        }
        lastUptime = value
        return value
    }

    private func drain() {
        guard started, !stopped, inFlight == nil, !pending.isEmpty, let time = currentUptime() else { return }
        let triggers = ordered(pending)
        guard reads.consume(at: time, window: limits.windowSeconds, triggers: triggers,
                            regularLimit: limits.regularReads, lifecycleLimit: limits.lifecycleReads,
                            shutdownLimit: limits.shutdownReads) else {
            budgetGap(.readBudgetExhausted, triggers: triggers, at: time)
            return // Retain one pending set; another real trigger can retry after the window. No polling.
        }
        pending.removeAll()
        if coalesced > 0 {
            emit(read: nil, triggers: triggers, phase: .gap, status: .unavailable, reason: .coalesced)
            coalesced = 0
        }
        readSequence += 1
        let ticket = Ticket(id: readSequence, triggers: triggers, revision: revision)
        inFlight = ticket
        emit(read: ticket.id, triggers: triggers, phase: .requested, status: .pending)
        guard !stopped, inFlight === ticket else { return }
        ticket.cancelDeadline = schedule(limits.readTimeoutSeconds) { [weak self, weak ticket] in
            guard let self, let ticket, self.inFlight === ticket, !ticket.completed, !ticket.timedOut, !self.stopped else { return }
            ticket.timedOut = true
            self.emit(read: ticket.id, triggers: ticket.triggers, phase: .sample,
                      status: .unavailable, reason: .deadlineExceeded)
            // The permit remains held until WebKit calls back. A timeout cannot
            // manufacture cancellation of a native getAllCookies operation.
        }
        reader { [weak self, ticket] cookies in self?.received(cookies, for: ticket) }
    }

    private func received(_ cookies: [HTTPCookie], for ticket: Ticket) {
        guard !ticket.completed else { return }
        ticket.completed = true
        ticket.cancelDeadline?()
        ticket.cancelDeadline = nil
        guard !stopped, inFlight === ticket else { return }
        inFlight = nil
        if ticket.timedOut {
            emit(read: ticket.id, triggers: ticket.triggers, phase: .gap,
                 status: .unavailable, reason: .lateCallbackDiscarded)
        } else if ticket.revision != revision {
            emit(read: ticket.id, triggers: ticket.triggers, phase: .sample,
                 status: .unavailable, reason: .supersededByStoreChange)
        } else {
            let snapshot = GeminiVerificationCookieDiagnostic.timeline(cookies, now: now())
            if snapshot.status == .available, ticket.triggers == [.storeChanged], snapshot == lastSnapshot {
                suppressedDuplicates = min(255, suppressedDuplicates + 1)
            } else {
                lastSnapshot = snapshot.status == .available ? snapshot : nil
                emit(read: ticket.id, triggers: ticket.triggers, phase: .sample,
                     status: snapshot.status == .available ? .available : .unavailable, metadata: snapshot)
            }
        }
        drain()
    }

    private func ordered(_ triggers: Set<Trigger>) -> [Trigger] { Trigger.allCases.filter(triggers.contains) }

    private func emit(read: Int?, triggers: [Trigger], phase: Event.Phase, status: Event.Status,
                      reason: Event.Reason? = nil,
                      metadata: GeminiVerificationCookieDiagnostic.TimelineSnapshot? = nil) {
        guard let time = currentUptime() else { return }
        guard events.consume(at: time, window: limits.windowSeconds, triggers: triggers,
                             regularLimit: limits.regularEvents, lifecycleLimit: limits.lifecycleEvents,
                             shutdownLimit: limits.shutdownEvents) else {
            budgetGap(.logBudgetExhausted, triggers: triggers, at: time)
            return
        }
        publish(read: read, triggers: triggers, phase: phase, status: status, reason: reason, metadata: metadata)
    }

    private func budgetGap(_ reason: Event.Reason, triggers: [Trigger], at time: TimeInterval) {
        guard lastBudgetGap.map({ time - $0 >= limits.windowSeconds }) ?? true else { return }
        lastBudgetGap = time
        // One reserved gap record per window, separate from ordinary samples.
        publish(read: nil, triggers: triggers, phase: .gap, status: .unavailable, reason: reason)
    }

    private func publish(read: Int?, triggers: [Trigger], phase: Event.Phase, status: Event.Status,
                         reason: Event.Reason? = nil,
                         metadata: GeminiVerificationCookieDiagnostic.TimelineSnapshot? = nil) {
        eventSequence += 1
        let event = Event(sequence: eventSequence, read: read, triggers: triggers, phase: phase,
                          status: status, reason: reason, coalescedTriggerCount: coalesced,
                          duplicateSamplesSuppressed: suppressedDuplicates, metadata: metadata)
        suppressedDuplicates = 0
        sink(event)
    }
}

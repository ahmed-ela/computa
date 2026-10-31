import WebKit
import XCTest
@testable import Computa

@MainActor
final class GeminiVerificationCookieTimelineTests: XCTestCase {
    private typealias Timeline = GeminiVerificationCookieTimeline

    @MainActor private final class Harness {
        @MainActor final class Deadline {
            let action: @MainActor @Sendable () -> Void
            var cancelled = false
            init(_ action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
        }
        let store = WKWebsiteDataStore.nonPersistent()
        var callbacks: [Timeline.Callback] = []
        var deadlines: [Deadline] = []
        var events: [Timeline.Event] = []
        var time: TimeInterval = 100
        var date = Date(timeIntervalSince1970: 1_800_000_000)

        func make(limits: Timeline.Limits = .init()) -> Timeline {
            Timeline(store: store.httpCookieStore, sink: { self.events.append($0) }, limits: limits,
                     reader: { self.callbacks.append($0) }, now: { self.date }, uptime: { self.time },
                     scheduler: { delay, action in
                XCTAssertEqual(delay, limits.readTimeoutSeconds)
                let deadline = Deadline(action)
                self.deadlines.append(deadline)
                return { deadline.cancelled = true }
            })
        }
    }

    @MainActor private final class Signal {
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?
        func fire() { finish(true) }
        private func finish(_ value: Bool) {
            guard result == nil else { return }
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }
        func wait(seconds: Double) async -> Bool {
            if let result { return result }
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                self.finish(false)
            }
            defer { timeout.cancel() }
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    @MainActor private final class CookieObserverSpy: NSObject, WKHTTPCookieStoreObserver {
        let expectedStore: WKHTTPCookieStore
        var callbacks = 0
        var sameStoreCallbacks = 0
        init(store: WKHTTPCookieStore) { expectedStore = store }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            callbacks += 1
            if cookieStore === expectedStore { sameStoreCallbacks += 1 }
        }
    }

    @MainActor private final class LocalDocumentDelegate: NSObject, WKNavigationDelegate {
        let settled = Signal()
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settled.fire() }
    }

    func testOneReadAndOneCoalescedFollowupPreserveLifecycleTriggersAndRejectDuplicates() throws {
        let h = Harness(), timeline = h.make()
        defer { timeline.stop() }
        timeline.start(); timeline.start()
        XCTAssertEqual(h.callbacks.count, 1)
        XCTAssertEqual(h.events.map(\.phase), [.requested])
        timeline.observe(.navigationSettled)
        timeline.observe(.modelClosed)
        timeline.observe(.navigationSettled)
        XCTAssertEqual(h.callbacks.count, 1)
        h.callbacks[0]([])
        XCTAssertEqual(h.callbacks.count, 2)
        XCTAssertTrue(h.deadlines[0].cancelled)
        let gap = try XCTUnwrap(h.events.first { $0.reason == .coalesced })
        XCTAssertEqual(gap.coalescedTriggerCount, 3)
        XCTAssertEqual(gap.triggers, [.navigationSettled, .modelClosed])
        XCTAssertNil(gap.metadata)
        h.callbacks[1]([])
        let count = h.events.count
        h.callbacks[0]([]); h.callbacks[1]([]); h.deadlines[0].action()
        XCTAssertEqual(h.events.count, count)
        XCTAssertEqual(h.callbacks.count, 2)
        XCTAssertEqual(h.events.filter { $0.status == .available }.count, 2)
        let foreign = WKWebsiteDataStore.nonPersistent()
        timeline.cookiesDidChange(in: foreign.httpCookieStore)
        XCTAssertEqual(h.callbacks.count, 2)
    }

    func testChangedStoreSupersedesAnOutstandingSnapshotWithoutPublishingStaleCounts() throws {
        let h = Harness(), timeline = h.make()
        defer { timeline.stop() }
        timeline.start()
        for _ in 0..<100 { timeline.cookiesDidChange(in: h.store.httpCookieStore) }
        XCTAssertEqual(h.callbacks.count, 1)
        h.callbacks[0]([try exemption(now: h.date)])
        XCTAssertEqual(h.callbacks.count, 2)
        XCTAssertEqual(h.events.first { $0.phase == .sample }?.reason, .supersededByStoreChange)
        XCTAssertTrue(h.events.allSatisfy { $0.metadata == nil })
        h.callbacks[1]([])
        let current = try XCTUnwrap(h.events.last?.metadata)
        XCTAssertEqual(current.status, .available)
        XCTAssertTrue(try XCTUnwrap(current.scopes).allSatisfy { $0.counts.exemptionFuture == 0 })
    }

    func testDeadlineDoesNotReleaseNativePermitAndLateDataCannotBecomeAvailable() throws {
        let h = Harness(), timeline = h.make()
        defer { timeline.stop() }
        timeline.start()
        h.deadlines[0].action(); h.deadlines[0].action()
        XCTAssertEqual(h.events.filter { $0.reason == .deadlineExceeded }.count, 1)
        XCTAssertNil(h.events.last?.metadata)
        timeline.observe(.modelClosed); timeline.observe(.shutdownRequested)
        XCTAssertEqual(h.callbacks.count, 1, "Timeout cannot start another native cookie read")
        h.callbacks[0]([try exemption(now: h.date)])
        XCTAssertEqual(h.callbacks.count, 2)
        XCTAssertTrue(h.events.contains { $0.reason == .lateCallbackDiscarded && $0.metadata == nil })
        XCTAssertFalse(h.events.contains { $0.status == .available })
        h.callbacks[1]([])
        XCTAssertEqual(h.events.last?.triggers, [.modelClosed, .shutdownRequested])
        XCTAssertEqual(h.events.last?.status, .available)
    }

    func testStopCancelsWorkAndLateCallbacksNeverPublishCookieMetadata() throws {
        let h = Harness(), timeline = h.make()
        timeline.start(); timeline.observe(.shutdownRequested)
        timeline.stop(); timeline.stop()
        XCTAssertTrue(h.deadlines[0].cancelled)
        XCTAssertEqual(h.events.last?.phase, .stopped)
        XCTAssertEqual(h.events.last?.triggers, [.initial, .shutdownRequested])
        XCTAssertEqual(h.events.filter { $0.phase == .intent && $0.triggers == [.shutdownRequested] }.count, 1)
        XCTAssertNil(h.events.first { $0.phase == .intent }?.read, "An intent does not claim a native read was dispatched")
        XCTAssertNil(h.events.last?.metadata)
        let count = h.events.count
        h.callbacks[0]([try exemption(now: h.date)])
        h.deadlines[0].action()
        timeline.start(); timeline.observe(.initial); timeline.cookiesDidChange(in: h.store.httpCookieStore)
        XCTAssertEqual(h.events.count, count)
        XCTAssertEqual(h.callbacks.count, 1)
        XCTAssertFalse(h.events.contains { $0.status == .available })
    }

    func testReadBudgetReservesLifecycleAndShutdownCapacityAndOnlyRealTriggersResumeWork() {
        let h = Harness()
        var limits = Timeline.Limits()
        limits.regularReads = 1; limits.lifecycleReads = 1; limits.shutdownReads = 1
        let timeline = h.make(limits: limits)
        defer { timeline.stop() }
        timeline.start(); h.callbacks[0]([])
        for _ in 0..<100 { timeline.observe(.storeChanged) }
        XCTAssertEqual(h.callbacks.count, 1)
        XCTAssertEqual(h.events.filter { $0.reason == .readBudgetExhausted }.count, 1)
        timeline.observe(.modelClosed)
        XCTAssertEqual(h.callbacks.count, 2)
        h.callbacks[1]([])
        timeline.observe(.challengeSettled)
        XCTAssertEqual(h.callbacks.count, 2)
        timeline.observe(.shutdownRequested)
        XCTAssertEqual(h.callbacks.count, 3)
        h.callbacks[2]([])
        h.time += limits.windowSeconds
        XCTAssertEqual(h.callbacks.count, 3, "Elapsed time itself never polls or initiates a read")
        timeline.observe(.storeChanged)
        XCTAssertEqual(h.callbacks.count, 4)
        h.callbacks[3]([])
    }

    func testLogBudgetHasIndependentBoundaryReservesAndOneExplicitGapPerWindow() {
        let h = Harness()
        var limits = Timeline.Limits()
        limits.regularEvents = 2; limits.lifecycleEvents = 2; limits.shutdownEvents = 3
        let timeline = h.make(limits: limits)
        defer { timeline.stop() }
        timeline.start(); h.callbacks[0]([])
        timeline.observe(.navigationSettled); h.callbacks[1]([])
        timeline.observe(.navigationSettled); h.callbacks[2]([])
        XCTAssertEqual(h.events.filter { $0.reason == .logBudgetExhausted }.count, 1)
        timeline.observe(.modelClosed); h.callbacks[3]([])
        XCTAssertEqual(h.events.last?.triggers, [.modelClosed])
        XCTAssertEqual(h.events.last?.status, .available)
        timeline.observe(.shutdownRequested); h.callbacks[4]([])
        XCTAssertEqual(h.events.last?.triggers, [.shutdownRequested])
        XCTAssertEqual(h.events.last?.status, .available)
        XCTAssertEqual(h.events.count, 8)
    }

    func testOnlyUnchangedStoreNotificationsAreDeduplicatedAndEveryBoundaryStillSamples() throws {
        let h = Harness(), timeline = h.make()
        defer { timeline.stop() }
        timeline.start(); h.callbacks[0]([])
        timeline.observe(.storeChanged); h.callbacks[1]([])
        XCTAssertEqual(h.events.filter { $0.status == .available }.count, 1)
        timeline.observe(.navigationSettled)
        XCTAssertEqual(h.events.last?.duplicateSamplesSuppressed, 1)
        h.callbacks[2]([])
        XCTAssertEqual(h.events.filter { $0.status == .available }.count, 2)
        timeline.observe(.modelClosed)
        h.callbacks[3]([try exemption(now: h.date)])
        let data = try JSONEncoder().encode(h.events)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["PRIVATE_FIXTURE_COOKIE_VALUE", "GOOGLE_ABUSE_EXEMPTION", "google.com", "http:", "https:"] {
            XCTAssertFalse(text.contains(secret))
        }
        for event in h.events { XCTAssertLessThanOrEqual(try JSONEncoder().encode(event).count, 8_192) }
        XCTAssertTrue(text.contains("callback_time_native_metadata_not_request_cookie_proof"))
        XCTAssertEqual(try XCTUnwrap(h.events.last?.metadata?.scopes).count, 7)
    }

    func testInvalidMonotonicClockCannotStartUnboundedReadsOrInventZeroCounts() {
        let h = Harness(), timeline = h.make()
        defer { timeline.stop() }
        timeline.start(); h.callbacks[0]([])
        h.time = .nan
        for _ in 0..<20 { timeline.observe(.navigationSettled) }
        XCTAssertEqual(h.callbacks.count, 1)
        XCTAssertEqual(h.events.filter { $0.reason == .invalidClock }.count, 1)
        XCTAssertNil(h.events.last?.metadata)
    }

    func testExplicitLifecycleSampleFindsSyntheticPageMutationWithoutRequiringObserverDelivery() async throws {
        let h = Harness(), configuration = WKWebViewConfiguration()
        let store = h.store
        configuration.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: configuration)
        let cookieStore = store.httpCookieStore
        let spy = CookieObserverSpy(store: cookieStore), initial = Signal(), lifecycleSample = Signal()
        cookieStore.add(spy)
        let timeline = Timeline(store: cookieStore, sink: {
            h.events.append($0)
            if $0.status == .available { initial.fire() }
            if $0.triggers.contains(.navigationSettled), $0.status == .available,
               $0.metadata?.scopes?.first?.counts.exemptionFuture == 1,
               $0.metadata?.scopes?.first?.remainingLifetime.upToOneMinute == 1 { lifecycleSample.fire() }
        })
        defer { timeline.stop(); cookieStore.remove(spy); view.stopLoading(); view.navigationDelegate = nil }
        timeline.start()
        let initiallyRead = await initial.wait(seconds: 5)
        XCTAssertTrue(initiallyRead, diagnostic("initial blank-store callback", events: h.events, spy: spy))
        let cookie = try exemption(now: Date())
        await withCheckedContinuation { continuation in
            cookieStore.setCookie(cookie) { continuation.resume() }
        }
        let observed = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let roundTrip = GeminiVerificationCookieDiagnostic.timeline(observed, now: Date())
        XCTAssertNil(view.url)
        XCTAssertFalse(view.isLoading)
        XCTAssertFalse(store.isPersistent)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.value, cookie.value, "The observer must leave the synthetic cookie unchanged")
        XCTAssertEqual(roundTrip.scopes?.first?.counts.exemptionFuture, 1)

        // A local HTML document activates the normal WebKit document lifecycle
        // without a network navigation or any Google/app-profile access.
        let delegate = LocalDocumentDelegate()
        view.navigationDelegate = delegate
        let localURL = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        view.loadHTMLString("<!doctype html><p>Local cookie observer fixture</p>", baseURL: localURL)
        let documentSettled = await delegate.settled.wait(seconds: 5)
        XCTAssertTrue(documentSettled, diagnostic("local document settlement", events: h.events, spy: spy))
        XCTAssertEqual(view.url, localURL)
        XCTAssertFalse(view.isLoading)
        // Real lifecycle sampling is required even when WebKit does not deliver
        // observer callbacks. Only this local, nonpersistent page is mutated.
        let changed = try await script(view, """
            document.cookie = 'GOOGLE_ABUSE_EXEMPTION=PRIVATE_FIXTURE_COOKIE_VALUE_2; Domain=google.com; Path=/; Max-Age=45; Secure; SameSite=Lax';
            return document.cookie.split(';').map(part => part.trim()).includes('GOOGLE_ABUSE_EXEMPTION=PRIVATE_FIXTURE_COOKIE_VALUE_2');
            """)
        XCTAssertTrue(changed, "The local synthetic document must observe its own cookie write")
        timeline.observe(.navigationSettled)
        let sampled = await lifecycleSample.wait(seconds: 5)
        let result = diagnostic("explicit lifecycle snapshot after page mutation", events: h.events, spy: spy)
        XCTAssertTrue(sampled, result)
        XCTAssertEqual(spy.sameStoreCallbacks, spy.callbacks, result)
        let preserved = try await script(view, """
            return document.cookie.split(';').map(part => part.trim()).includes('GOOGLE_ABUSE_EXEMPTION=PRIVATE_FIXTURE_COOKIE_VALUE_2');
            """)
        XCTAssertTrue(preserved, "A read-only lifecycle snapshot must preserve the synthetic page cookie")
        XCTAssertEqual(view.url, localURL)
        XCTAssertFalse(view.isLoading)

        // Dispatch one real read and stop synchronously before its callback can
        // return. A single native barrier lets that pending callback drain.
        timeline.observe(.modelClosed)
        timeline.stop()
        let stoppedCount = h.events.count
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { _ in continuation.resume() }
        }
        await Task.yield()
        XCTAssertEqual(h.events.count, stoppedCount)
        XCTAssertEqual(h.events.last?.phase, .stopped)
    }

    private func exemption(now: Date, lifetime: TimeInterval = 3_600,
                           value: String = "PRIVATE_FIXTURE_COOKIE_VALUE") throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.name: "GOOGLE_ABUSE_EXEMPTION", .value: value,
            .domain: ".google.com", .path: "/", .secure: "TRUE", .expires: now.addingTimeInterval(lifetime)]))
    }

    private func script(_ view: WKWebView, _ body: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let flag = value as? Bool { continuation.resume(returning: flag) }
                    else { continuation.resume(throwing: NSError(domain: "CookieTimelineFixtureResult", code: 1)) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func diagnostic(_ stage: String, events: [Timeline.Event], spy: CookieObserverSpy,
                            roundTrip: GeminiVerificationCookieDiagnostic.TimelineSnapshot? = nil) -> String {
        // Only already-sanitized projections enter the failure log. This
        // distinguishes missing notifications from native cookie normalization.
        let eventSummary = events.suffix(8).map { event in
            "sequence=\(event.sequence) phase=\(event.phase.rawValue) status=\(event.status.rawValue) triggers=\(event.triggers.map(\.rawValue)) reason=\(event.reason?.rawValue ?? "none") gemini=\(scopeSummary(event.metadata))"
        }.joined(separator: "; ")
        return "\(stage): spyCallbacks=\(spy.callbacks) sameStoreCallbacks=\(spy.sameStoreCallbacks); \(eventSummary); nativeRoundTripGemini=\(scopeSummary(roundTrip))"
    }

    private func scopeSummary(_ snapshot: GeminiVerificationCookieDiagnostic.TimelineSnapshot?) -> String {
        guard let scope = snapshot?.scopes?.first else { return "unavailable" }
        guard let data = try? JSONEncoder().encode(scope), data.count <= 1_024 else { return "projection_unavailable" }
        return String(decoding: data, as: UTF8.self)
    }
}

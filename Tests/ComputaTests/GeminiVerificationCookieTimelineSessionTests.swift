import AutomationCore
import WebKit
import XCTest
@testable import Computa

@MainActor
final class GeminiVerificationCookieTimelineSessionTests: XCTestCase {
    private typealias Event = GeminiVerificationCookieTimeline.Event

    func testInitialSharedStoreSamplePrecedesNavigationAndGrantsNoAuthority() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        var events: [Event] = [], recoveryCandidates = 0
        session.setGeminiCookieTimelineSinkForTesting { events.append($0) }
        session.onHumanVerificationRecoveryCandidate = { _ in recoveryCandidates += 1 }
        session.recordHumanVerificationRequired(provider: "gemini")
        let checkpoints = session.savedHumanVerificationCheckpointIDs
        let human = try session.createTab(), model = try session.createUnloadedModelTabForTesting()
        let humanView = try XCTUnwrap(session.webView(for: human)), modelView = try XCTUnwrap(session.webView(for: model))
        let generations = [session.documentGeneration(for: human), session.documentGeneration(for: model)]
        try await wait { events.contains { $0.phase == .sample && $0.triggers.contains(.initial) && $0.status == .available } }
        XCTAssertTrue(humanView.configuration.websiteDataStore === modelView.configuration.websiteDataStore)
        XCTAssertFalse(humanView.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(events.filter { $0.phase == .requested && $0.triggers.contains(.initial) }.count, 1)
        let initial = try XCTUnwrap(events.first { $0.phase == .sample && $0.triggers.contains(.initial) })
        XCTAssertEqual(try XCTUnwrap(initial.metadata?.scopes).count, 7)
        XCTAssertTrue(try XCTUnwrap(initial.metadata?.scopes).allSatisfy { $0.counts.scopedGoogleCookies == 0 })
        XCTAssertFalse(events.contains { $0.triggers.contains(.navigationSettled) || $0.triggers.contains(.challengeSettled) })
        for view in [humanView, modelView] { XCTAssertNil(view.url); XCTAssertFalse(view.isLoading) }
        XCTAssertEqual([session.documentGeneration(for: human), session.documentGeneration(for: model)], generations)
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs, checkpoints)
        XCTAssertTrue(session.humanVerificationRecoveryReports.isEmpty)
        XCTAssertEqual(recoveryCandidates, 0)
        XCTAssertEqual(session.tabs.map(\.id), [human, model])
    }

    func testModelClosureSamplesRetainedSharedStoreWithoutChangingSyntheticCookies() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        var events: [Event] = []
        session.setGeminiCookieTimelineSinkForTesting { events.append($0) }
        let human = try session.createTab(), humanView = try XCTUnwrap(session.webView(for: human))
        let humanGeneration = session.documentGeneration(for: human)
        let store = humanView.configuration.websiteDataStore.httpCookieStore
        try await wait(stage: "model_close_initial", events: { events }) { events.contains { $0.phase == .sample && $0.status == .available } }
        let cookie = try exemption()
        await set(cookie, in: store)
        // Native setter completion/readback establish fixture setup. Observer
        // delivery for native writes is tested separately from view cleanup.
        let baseline = await read(store)
        XCTAssertEqual(baseline.count, 1)
        XCTAssertEqual(baseline.first?.value, cookie.value)
        XCTAssertEqual(GeminiVerificationCookieDiagnostic.project(baseline, destination: .geminiApp, now: Date()).counts?.exemptionFuture, 1)
        let model = try session.createUnloadedModelTabForTesting(), modelView = try XCTUnwrap(session.webView(for: model))
        XCTAssertTrue(modelView.configuration.websiteDataStore === humanView.configuration.websiteDataStore)
        let localURL = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        modelView.loadHTMLString("<!doctype html><p>Local cookie lifecycle fixture</p>", baseURL: localURL)
        try await wait(stage: "model_close_local_document", events: { events }) { !modelView.isLoading && modelView.url == localURL }
        try await wait(stage: "model_close_navigation_sample", events: { events }) { events.contains { $0.triggers.contains(.navigationSettled) && self.geminiFutureCount($0) == 1 } }
        let checkpoints = session.savedHumanVerificationCheckpointIDs
        let closedBefore = events.filter { $0.triggers.contains(.modelClosed) }.count
        session.closeTab(model)
        try await wait(stage: "model_close_closed_sample", events: { events }) { events.contains { $0.phase == .sample && $0.triggers.contains(.modelClosed) && self.geminiFutureCount($0) == 1 } }
        XCTAssertGreaterThan(events.filter { $0.triggers.contains(.modelClosed) }.count, closedBefore)
        XCTAssertNil(session.webView(for: model))
        XCTAssertEqual(session.tabs.map(\.id), [human])
        XCTAssertEqual(session.documentGeneration(for: human), humanGeneration)
        XCTAssertNil(humanView.url)
        XCTAssertFalse(humanView.isLoading)
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs, checkpoints)
        XCTAssertTrue(session.humanVerificationRecoveryReports.isEmpty)
        let retained = await read(store)
        diagnostic(stage: "model_close_readback", events: events, cookies: retained)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.name, cookie.name)
        XCTAssertEqual(retained.first?.value, cookie.value, "Only synthetic fixture values are compared; observation cannot mutate them")
        XCTAssertEqual(retained.first?.expiresDate, baseline.first?.expiresDate)
    }

    func testIsolatedChatGPTClosureDoesNotTriggerSharedStoreModelClosedObservation() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        var events: [Event] = []
        session.setGeminiCookieTimelineSinkForTesting { events.append($0) }
        let human = try session.createTab(), humanView = try XCTUnwrap(session.webView(for: human))
        let shared = humanView.configuration.websiteDataStore
        try await wait(stage: "isolated_close_initial", events: { events }) { events.contains { $0.phase == .sample && $0.status == .available } }
        let cookie = try exemption()
        await set(cookie, in: shared.httpCookieStore)
        let baseline = await read(shared.httpCookieStore)
        XCTAssertEqual(baseline.count, 1)
        XCTAssertEqual(baseline.first?.value, cookie.value)
        XCTAssertEqual(GeminiVerificationCookieDiagnostic.project(baseline, destination: .geminiApp, now: Date()).counts?.exemptionFuture, 1)
        let isolated = try session.createUnloadedModelTabForTesting(isolatedChatGPTProfile: true)
        let isolatedView = try XCTUnwrap(session.webView(for: isolated))
        XCTAssertTrue(isolatedView.configuration.websiteDataStore !== shared)
        XCTAssertFalse(isolatedView.configuration.websiteDataStore.isPersistent)
        XCTAssertNil(isolatedView.url)
        session.closeTab(isolated)
        let retained = await read(shared.httpCookieStore)
        diagnostic(stage: "isolated_close_readback", events: events, cookies: retained)
        await Task.yield()
        XCTAssertFalse(events.contains { $0.triggers.contains(.modelClosed) })
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.value, cookie.value)
        XCTAssertEqual(session.tabs.map(\.id), [human])
        XCTAssertTrue(session.humanVerificationRecoveryReports.isEmpty)
    }

    func testImmediateShutdownPreservesIntentAndSuppressesLateAvailableCounts() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        var events: [Event] = []
        session.setGeminiCookieTimelineSinkForTesting { events.append($0) }
        session.recordHumanVerificationRequired(provider: "gemini")
        let checkpoints = session.savedHumanVerificationCheckpointIDs
        let human = try session.createTab(), view = try XCTUnwrap(session.webView(for: human))
        let store = view.configuration.websiteDataStore.httpCookieStore
        // Remain on the main actor without suspension so the initial async
        // native callback cannot finish before the shutdown intent is recorded.
        session.observeGeminiCookieShutdownRequested()
        let intent = try XCTUnwrap(events.first { $0.phase == .intent && $0.triggers == [.shutdownRequested] })
        XCTAssertNil(intent.read, "An intent is not a claim that a native read was dispatched")
        XCTAssertNil(intent.metadata)
        session.shutdown()
        let stopped = try XCTUnwrap(events.last)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertTrue(stopped.triggers.contains(.shutdownRequested))
        XCTAssertGreaterThan(stopped.sequence, intent.sequence)
        let eventCount = events.count
        _ = await read(store)
        await Task.yield()
        XCTAssertEqual(events.count, eventCount)
        XCTAssertFalse(events.contains { $0.sequence > stopped.sequence && $0.status == .available })
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs, checkpoints)
        XCTAssertTrue(session.humanVerificationRecoveryReports.isEmpty)
    }

    func testAppStateShutdownRecordsIntentBeforeStoppingTheBrowserOnce() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        var events: [Event] = []
        session.setGeminiCookieTimelineSinkForTesting { events.append($0) }
        let state = AppState(tasks: [], runtime: nil, permissionClient: TimelineFixturePermissions(),
            preferences: isolatedTestPreferences(), browserSession: session, cookieMaintenanceOnlyLaunch: false,
            cookieMaintenanceRunner: { _ in XCTFail("Shutdown observation cannot start cookie maintenance") })
        session.recordHumanVerificationRequired(provider: "gemini")
        let checkpoints = session.savedHumanVerificationCheckpointIDs
        let human = try session.createTab(), view = try XCTUnwrap(session.webView(for: human))
        let store = view.configuration.websiteDataStore.httpCookieStore
        let report = await state.shutdownRuntime()
        XCTAssertTrue(report.succeeded)
        let intent = try XCTUnwrap(events.first { $0.phase == .intent && $0.triggers.contains(.shutdownRequested) })
        let stopped = try XCTUnwrap(events.first { $0.phase == .stopped })
        XCTAssertLessThan(intent.sequence, stopped.sequence)
        XCTAssertNil(intent.read)
        XCTAssertNil(intent.metadata)
        _ = await read(store)
        let count = events.count
        let repeated = await state.shutdownRuntime()
        XCTAssertTrue(repeated.succeeded)
        XCTAssertEqual(events.count, count)
        XCTAssertEqual(events.filter { $0.phase == .intent && $0.triggers.contains(.shutdownRequested) }.count, 1)
        XCTAssertFalse(events.contains { $0.sequence > stopped.sequence && $0.status == .available })
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs, checkpoints)
        XCTAssertTrue(session.humanVerificationRecoveryReports.isEmpty)
    }

    private func geminiFutureCount(_ event: Event) -> Int? {
        event.metadata?.scopes?.first { $0.destination == .geminiApp }?.counts.exemptionFuture
    }

    private func exemption() throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.name: "GOOGLE_ABUSE_EXEMPTION", .value: "SYNTHETIC_SESSION_TIMELINE_COOKIE",
            .domain: ".google.com", .path: "/", .secure: "TRUE", .expires: Date().addingTimeInterval(3_600)]))
    }

    private func set(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    private func read(_ store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func diagnostic(stage: String, events: [Event], cookies: [HTTPCookie]? = nil) {
        struct Summary: Encodable {
            let phase: Event.Phase
            let status: Event.Status
            let triggers: [GeminiVerificationCookieTimeline.Trigger]
            let reason: Event.Reason?
            let scope: GeminiVerificationCookieDiagnostic.TimelineScope?
        }
        struct Diagnostic: Encodable {
            let stage: String
            let events: [Summary]
            let readback: GeminiVerificationCookieDiagnostic.Snapshot?
        }
        let summaries = events.suffix(8).map { Summary(phase: $0.phase, status: $0.status, triggers: $0.triggers,
            reason: $0.reason, scope: $0.metadata?.scopes?.first { $0.destination == .geminiApp }) }
        let record = Diagnostic(stage: stage, events: summaries,
            readback: cookies.map { GeminiVerificationCookieDiagnostic.project($0, destination: .geminiApp, now: Date()) })
        if let data = try? JSONEncoder().encode(record), data.count <= 8_192 {
            print("GEMINI_TIMELINE_SESSION_FIXTURE " + String(decoding: data, as: UTF8.self))
        }
    }

    private func wait(stage: String = "unspecified", events: @MainActor () -> [Event] = { [] },
                      _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { diagnostic(stage: stage, events: events()) }
        XCTAssertTrue(condition(), "Local cookie timeline did not reach its expected lifecycle boundary: \(stage)", file: file, line: line)
    }
}

private struct TimelineFixturePermissions: AutomationPermissionClient {
    func current() -> AutomationPermissionSnapshot { .init(accessibility: .notGranted, screenRecording: .notGranted) }
    func requestAccessibility() -> AutomationPermissionSnapshot { current() }
    func requestScreenRecording() -> AutomationPermissionSnapshot { current() }
}

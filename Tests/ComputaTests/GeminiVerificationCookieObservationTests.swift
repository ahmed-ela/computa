import WebKit
import XCTest
@testable import Computa

@MainActor
final class GeminiVerificationCookieObservationTests: XCTestCase {
    @MainActor private final class Reader {
        typealias Callback = @MainActor @Sendable ([HTTPCookie]) -> Void
        var stores: [WKHTTPCookieStore] = []
        var callbacks: [Callback] = []
        var events: [EmbeddedBrowserSession.GeminiVerificationCookieObservation] = []
        func install(on session: EmbeddedBrowserSession) {
            session.setGeminiCookieObservationForTesting(reader: { store, completion in
                self.stores.append(store); self.callbacks.append(completion)
            }, sink: { self.events.append($0) })
        }
    }

    func testHumanAndModelReadTheExactSharedStoreWithoutChangingGatesOrNavigating() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let reader = Reader(); reader.install(on: session)
        session.recordHumanVerificationRequired(provider: "gemini")
        let checkpoints = session.savedHumanVerificationCheckpointIDs
        let human = try session.createTab(), model = try session.createUnloadedModelTabForTesting()
        let humanView = try XCTUnwrap(session.webView(for: human)), modelView = try XCTUnwrap(session.webView(for: model))
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app?private_query=DO_NOT_LOG"))
        let navigation = try await loadFixture(humanView, at: url)
        try await wait { reader.callbacks.count == 1 }
        let humanGeneration = session.documentGeneration(for: human)
        let callback = reader.callbacks.removeFirst()
        XCTAssertEqual(reader.events.map(\.status), [.pending], "No callback is unknown, not available-zero")
        callback([])
        XCTAssertEqual(reader.events.last?.status, .available)
        XCTAssertEqual(reader.events.last?.metadata?.counts?.scopedGoogleCookies, 0)
        callback([])
        humanView.navigationDelegate?.webView?(humanView, didFinish: navigation)
        await Task.yield()
        XCTAssertEqual(reader.events.count, 2, "A duplicate callback/completion cannot publish a second observation")
        _ = try await loadFixture(modelView, at: url)
        try await wait { reader.callbacks.count == 1 }
        let modelGeneration = session.documentGeneration(for: model)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "GOOGLE_ABUSE_EXEMPTION", .value: "PRIVATE_COOKIE_VALUE",
            .domain: ".google.com", .path: "/", .expires: Date().addingTimeInterval(3_600)]))
        reader.callbacks.removeFirst()([cookie])
        XCTAssertEqual(reader.events.filter { $0.phase == .callback }.map(\.role), [.human, .model])
        XCTAssertTrue(reader.events.allSatisfy(\.sharedStore))
        XCTAssertTrue(reader.stores[0] === humanView.configuration.websiteDataStore.httpCookieStore)
        XCTAssertTrue(reader.stores[1] === modelView.configuration.websiteDataStore.httpCookieStore)
        XCTAssertTrue(reader.stores[0] === reader.stores[1])
        XCTAssertEqual(reader.events.last?.metadata?.counts?.exemptionFuture, 1)
        let serialized = String(decoding: try JSONEncoder().encode(reader.events), as: UTF8.self)
        for secret in ["PRIVATE_COOKIE_VALUE", "GOOGLE_ABUSE_EXEMPTION", "private_query", "DO_NOT_LOG", "https:", ".google.com"] {
            XCTAssertFalse(serialized.contains(secret))
        }
        XCTAssertTrue(serialized.contains("callback_time_native_metadata_not_request_cookie_proof"))
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs, checkpoints)
        XCTAssertTrue(session.humanVerificationRecoveryReports.isEmpty)
        XCTAssertEqual(session.documentGeneration(for: human), humanGeneration)
        XCTAssertEqual(session.documentGeneration(for: model), modelGeneration)
        XCTAssertEqual(humanView.url, url); XCTAssertEqual(modelView.url, url)
        XCTAssertFalse(humanView.isLoading); XCTAssertFalse(modelView.isLoading)
        XCTAssertEqual(session.tabs.map(\.id), [human, model])
    }

    func testOnlyExactDestinationsObserveAndAnIsolatedStoreIsReportedHonestly() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let reader = Reader(); reader.install(on: session)
        let id = try session.createUnloadedModelTabForTesting(isolatedChatGPTProfile: true)
        let view = try XCTUnwrap(session.webView(for: id))
        let urls = ["https://google.com/sorry", "https://google.com/sorry/", "https://google.com/sorry/index",
                    "https://www.google.com/sorry", "https://www.google.com/sorry/", "https://www.google.com/sorry/index"]
        for address in urls {
            _ = try await loadFixture(view, at: XCTUnwrap(URL(string: address)))
            try await wait { reader.callbacks.count == 1 }
            reader.callbacks.removeFirst()([])
            XCTAssertEqual(reader.events.last?.status, .available)
            XCTAssertEqual(reader.events.last?.sharedStore, false)
        }
        let count = reader.stores.count
        for address in ["https://example.invalid/app", "https://google.com/search?q=private", "https://gemini.google.com/app/other"] {
            _ = try await loadFixture(view, at: XCTUnwrap(URL(string: address)))
        }
        XCTAssertEqual(reader.stores.count, count)
        XCTAssertTrue(session.savedHumanVerificationProviders.isEmpty, "Model diagnostics cannot create a human checkpoint")
    }

    func testLateCallbacksPublishUnavailableWithoutCookieCountsOrRecoveryAuthority() async throws {
        for fault in ["closed", "newDocument", "provisional", "failed", "toolBorrow", "toolMutation", "shutdown"] {
            let session = EmbeddedBrowserSession(persistent: false)
            defer { session.shutdown() }
            let reader = Reader(); reader.install(on: session)
            session.recordHumanVerificationRequired(provider: "gemini")
            let checkpoints = session.savedHumanVerificationCheckpointIDs
            let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
            _ = try await loadFixture(view, at: XCTUnwrap(URL(string: "https://gemini.google.com/app")))
            try await wait { reader.callbacks.count == 1 }
            let callback = reader.callbacks.removeFirst()
            switch fault {
            case "closed": session.closeTab(id)
            case "newDocument": _ = try await loadFixture(view, at: XCTUnwrap(URL(string: "https://example.invalid/local")))
            case "provisional": view.navigationDelegate?.webView?(view, didStartProvisionalNavigation: nil)
            case "failed":
                view.navigationDelegate?.webView?(view, didStartProvisionalNavigation: nil)
                view.navigationDelegate?.webView?(view, didFailProvisionalNavigation: nil,
                    withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
            case "toolBorrow": try session.markHumanDocumentUsedByTool(tabID: id, generation: XCTUnwrap(session.documentGeneration(for: id)))
            case "toolMutation": _ = try session.prepareToolMutation(tabID: id, generation: XCTUnwrap(session.documentGeneration(for: id)))
            case "shutdown": session.shutdown()
            default: XCTFail("Unknown stale callback fixture")
            }
            callback([])
            XCTAssertEqual(reader.events.last?.phase, .callback, fault)
            XCTAssertEqual(reader.events.last?.status, .unavailable, fault)
            XCTAssertNotNil(reader.events.last?.reason, fault)
            XCTAssertNil(reader.events.last?.metadata, "Stale data cannot appear as available-zero: \(fault)")
            XCTAssertEqual(reader.events.count, 2, fault)
            XCTAssertEqual(session.savedHumanVerificationCheckpointIDs, checkpoints, fault)
            XCTAssertTrue(session.humanVerificationRecoveryReports.isEmpty, fault)
        }
    }

    func testObservationBudgetIsSessionWideAndAllowsOnlyOneReadPerGeneration() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let reader = Reader(); reader.install(on: session)
        let first = try session.createTab(), second = try session.createTab()
        let views = try [XCTUnwrap(session.webView(for: first)), XCTUnwrap(session.webView(for: second))]
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        for index in 0..<(EmbeddedBrowserSession.geminiCookieObservationLimit + 2) {
            let view = views[index % 2]
            let navigation = try await loadFixture(view, at: url)
            view.navigationDelegate?.webView?(view, didFinish: navigation)
            await Task.yield()
            if index < EmbeddedBrowserSession.geminiCookieObservationLimit {
                try await wait { reader.callbacks.count == 1 }
                reader.callbacks.removeFirst()([])
            }
        }
        XCTAssertEqual(reader.stores.count, EmbeddedBrowserSession.geminiCookieObservationLimit)
        XCTAssertEqual(reader.events.count, 2 * EmbeddedBrowserSession.geminiCookieObservationLimit)
        XCTAssertEqual(reader.events.filter { $0.phase == .requested }.map(\.request), Array(1...EmbeddedBrowserSession.geminiCookieObservationLimit))
        XCTAssertTrue(session.savedHumanVerificationProviders.isEmpty)
    }

    private func loadFixture(_ view: WKWebView, at url: URL) async throws -> WKNavigation {
        let navigation = try XCTUnwrap(view.loadHTMLString("<!doctype html><title>Local metadata fixture</title><p>Fixture</p>", baseURL: url))
        try await wait { !view.isLoading && view.url == url }
        await Task.yield()
        return navigation
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Local WebKit fixture did not reach its expected native boundary")
    }
}

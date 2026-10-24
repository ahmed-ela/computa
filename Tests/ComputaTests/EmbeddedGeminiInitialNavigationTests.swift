import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedGeminiInitialNavigationTests: XCTestCase {
    func testProvisionalCheckpointPollWaitsWithoutAdapterThenRequiresFreshGeminiReadiness() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        let revision = try fixture.browser.modelChangeRevision(for: fixture.id)
        for _ in 0..<2 {
            let waiting = try await fixture.poll()
            XCTAssertEqual(waiting["state"] as? String, "loading")
            XCTAssertEqual(waiting["sequence"] as? Int, 0)
            XCTAssertNil(waiting["modelProofContext"])
            XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
            try await fixture.assertNoAdapterOrInput()
        }
        // Native callbacks, not a second load/retry, settle this same navigation.
        fixture.settle(url: Fixture.gemini)
        let changed = try await fixture.transport.waitForChange(sessionToken: fixture.token,
            after: revision, until: .now + .seconds(1))
        XCTAssertNotNil(changed)
        let empty = try await fixture.poll()
        XCTAssertEqual(empty["state"] as? String, "loading", "Settling is not composer/model/mode proof")
        XCTAssertNil(empty["modelEvidence"])
        let ownerBound = try await fixture.evaluate("return typeof globalThis.__computaModelOwner === 'string';", isolated: true)
        XCTAssertEqual(ownerBound as? Bool, true, "Only the allowed settled page reaches ordinary adapter inspection")
        do { _ = try await fixture.call("webProviderSend", ["sessionToken": fixture.token, "prompt": "Must not send"]); XCTFail("No readiness proof") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
        XCTAssertEqual(fixture.createdCount, 1)
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testCommittedUnfinishedCheckpointWaitsThenSettledCheckpointBlocksAndDisposesOnlyUntouchedView() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        _ = try await fixture.poll()
        fixture.delegate.webView?(fixture.view, didCommit: fixture.navigation)
        XCTAssertTrue(fixture.view.isLoading)
        let waiting = try await fixture.poll()
        XCTAssertEqual(waiting["state"] as? String, "loading")
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
        try await fixture.assertNoAdapterOrInput()
        // Completion, rather than commit alone, ends this initial-only grace.
        fixture.view.fixtureLoading = false
        fixture.delegate.webView?(fixture.view, didFinish: fixture.navigation)
        await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
        try await fixture.assertNoAdapterOrInput()
        let checkpoint = try XCTUnwrap(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"])
        let finished = try await fixture.call("webProviderFinish", ["sessionToken": fixture.token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertEqual(finished["state"] as? String, "finished")
        XCTAssertNil(fixture.browser.webView(for: fixture.id))
        XCTAssertEqual(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
        XCTAssertEqual(fixture.createdCount, 1)
    }

    func testProvisionalCheckpointKeepsOriginalDeadlineAndCancellationWithoutAdapter() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        _ = try await fixture.poll()
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await fixture.poll()
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation must not wait or inspect") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.transport.setTimeoutsForTesting(preparation: .milliseconds(1), response: .seconds(300))
        let revision = try fixture.browser.modelChangeRevision(for: fixture.id)
        _ = try await fixture.transport.waitForChange(sessionToken: fixture.token, after: revision,
            until: .now + .seconds(5))
        await fixture.assertPollFailure(.preparationDeadline)
        try await fixture.assertNoAdapterOrInput()
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty, "An unsettled timeout is not a committed checkpoint")
        XCTAssertNotNil(fixture.browser.webView(for: fixture.id))
        XCTAssertEqual(fixture.createdCount, 1)
    }

    func testFailedUnknownAndForeignNavigationNeverEnterCheckpointWait() async throws {
        for kind in ["failed", "uncommitted_finish", "foreign", "signin", "closed"] {
            let fixture = try await Fixture.make()
            defer { fixture.shutdown() }
            _ = try await fixture.poll()
            let expected: EmbeddedWebModelTransport.Failure
            switch kind {
            case "failed":
                fixture.delegate.webView?(fixture.view, didFailProvisionalNavigation: fixture.navigation,
                    withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                expected = .humanVerificationRequired(.gemini)
            case "uncommitted_finish":
                fixture.delegate.webView?(fixture.view, didFinish: fixture.navigation)
                expected = .humanVerificationRequired(.gemini)
            case "foreign":
                fixture.view.fixtureURL = URL(string: "https://example.test/sorry/")!
                expected = .unexpectedPage(.gemini)
            case "signin":
                fixture.view.fixtureURL = URL(string: "https://accounts.google.com/ServiceLogin")!
                expected = .signInRequired
            default:
                fixture.browser.closeTab(fixture.id)
                expected = .staleSession
            }
            await fixture.assertPollFailure(expected)
            if kind != "closed" { try await fixture.assertNoAdapterOrInput() }
            XCTAssertEqual(fixture.createdCount, 1)
        }
    }

    func testCurrentNativeGenerationIgnoresStaleCommitAndRejectsWrongViewFacts() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        let old = fixture.navigation
        let oldGeneration = fixture.browser.documentGeneration(for: fixture.id)
        // A new local navigation supplies another real WKNavigation identity.
        let next = try XCTUnwrap(fixture.view.loadHTMLString(Fixture.html, baseURL: Fixture.gemini))
        fixture.delegate.webView?(fixture.view, didStartProvisionalNavigation: next)
        XCTAssertNotEqual(fixture.browser.documentGeneration(for: fixture.id), oldGeneration)
        fixture.delegate.webView?(fixture.view, didCommit: old)
        fixture.delegate.webView?(fixture.view, didFinish: old)
        XCTAssertTrue(fixture.browser.hasUncommittedModelNavigation(tabID: fixture.id, view: fixture.view))
        XCTAssertFalse(fixture.browser.hasUncommittedModelNavigation(tabID: fixture.id, view: fixture.humanView))
        let waiting = try await fixture.poll()
        XCTAssertEqual(waiting["state"] as? String, "loading")
        XCTAssertNil(waiting["modelProofContext"])
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
        fixture.delegate.webView?(fixture.view, didCommit: next)
        let committedWaiting = try await fixture.poll()
        XCTAssertEqual(committedWaiting["state"] as? String, "loading")
        try await fixture.assertNoAdapterOrInput()
        fixture.view.fixtureLoading = false
        fixture.delegate.webView?(fixture.view, didFinish: next)
        await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
        XCTAssertNotNil(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertEqual(fixture.createdCount, 1)
    }


    func testCommittedInitialCheckpointCanReturnOnNewNativeNavigationWithoutGrantingReadiness() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        _ = try await fixture.poll()
        let deadline = try XCTUnwrap(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token))
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: fixture.navigation)
        fixture.delegate.webView?(fixture.view, didCommit: fixture.navigation)
        let waiting = try await fixture.poll()
        XCTAssertEqual(waiting["state"] as? String, "loading")
        try await fixture.assertNoAdapterOrInput()
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
        let checkpointGeneration = fixture.browser.documentGeneration(for: fixture.id)
        try await fixture.beginLocalNavigation(url: Fixture.gemini)
        XCTAssertNotEqual(fixture.browser.documentGeneration(for: fixture.id), checkpointGeneration)
        fixture.settle(url: Fixture.gemini)
        let normalRead = try await fixture.poll()
        XCTAssertEqual(normalRead["state"] as? String, "loading", "Native return is not website readiness")
        // The ordinary admitted inspect binds its current native generation.
        // A binding alone is not selected-model, submission or response proof.
        let context = try XCTUnwrap(normalRead["modelProofContext"] as? [String: Any])
        XCTAssertEqual(context["documentGeneration"] as? String, fixture.browser.documentGeneration(for: fixture.id)?.uuidString)
        XCTAssertEqual(context["sequence"] as? Int, 0)
        XCTAssertEqual(context["responseCount"] as? Int, 0)
        XCTAssertEqual(context["baselineResponseCount"] as? Int, 0)
        XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
        XCTAssertEqual(context["submittedPromptFingerprint"] as? String, "")
        XCTAssertNil(normalRead["modelEvidence"])
        XCTAssertNil(normalRead["productModeEvidence"])
        XCTAssertNil(normalRead["completionEvidence"])
        XCTAssertEqual(normalRead["text"] as? String, "")
        XCTAssertEqual(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token), deadline)
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
        let bound = try await fixture.evaluate("return typeof globalThis.__computaModelOwner === 'string';", isolated: true)
        XCTAssertEqual(bound as? Bool, true)
        do { _ = try await fixture.call("webProviderSend", ["sessionToken": fixture.token, "prompt": "Must not send"]); XCTFail("No readiness proof") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
        try await fixture.assertNoInput()
        XCTAssertEqual(fixture.createdCount, 1, "No new provider tab or automatic navigation retry")
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testSettlementDeadlineIsStickyAcrossPollsAndNativeGenerationsAndCannotBeRenewed() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        XCTAssertTrue(fixture.transport.setInitialCheckpointSettlementTimeoutForTesting(.seconds(20)))
        let before = ContinuousClock.now
        _ = try await fixture.poll()
        let after = ContinuousClock.now
        let deadline = try XCTUnwrap(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token))
        XCTAssertLessThanOrEqual(deadline - after, .seconds(3))
        XCTAssertGreaterThan(deadline - before, .seconds(2))
        XCTAssertFalse(fixture.transport.setInitialCheckpointSettlementTimeoutForTesting(.seconds(3)), "An active window cannot renew its timeout")
        let generation = fixture.browser.documentGeneration(for: fixture.id)
        try await fixture.beginLocalNavigation(url: Fixture.checkpoint)
        XCTAssertNotEqual(fixture.browser.documentGeneration(for: fixture.id), generation)
        for _ in 0..<3 {
            _ = try await fixture.poll()
            XCTAssertEqual(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token), deadline)
            fixture.browser.notifyModelSessionChange(tabID: fixture.id)
        }
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
        try await fixture.assertNoAdapterOrInput()
    }

    func testNativeWaitWakesAtSingleSettlementBudgetAndLogsExpiryOnlyOnce() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        XCTAssertTrue(fixture.transport.setInitialCheckpointSettlementTimeoutForTesting(.milliseconds(40)))
        var diagnostics: [[String: Any]] = []
        fixture.transport.setInitialCheckpointSettlementObserverForTesting { diagnostics.append($0) }
        fixture.delegate.webView?(fixture.view, didCommit: fixture.navigation)
        _ = try await fixture.poll()
        let deadline = try XCTUnwrap(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token))
        // Native KVO may wake a waiter sooner; every wake still keeps the same
        // deadline. There is no network navigation or provider adapter work.
        let outer = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline, ContinuousClock.now < outer {
            let revision = try fixture.browser.modelChangeRevision(for: fixture.id)
            _ = try await fixture.transport.waitForChange(sessionToken: fixture.token, after: revision, until: .now + .seconds(5))
        }
        XCTAssertLessThan(ContinuousClock.now, outer, "The five-second caller wait must be capped by the settlement budget")
        await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
        let gate = try XCTUnwrap(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"])
        await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
        XCTAssertEqual(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"], gate)
        XCTAssertEqual(diagnostics.compactMap { $0["phase"] as? String }, ["wait_started", "budget_expired"])
        for record in diagnostics {
            let bytes = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
            XCTAssertLessThanOrEqual(bytes.count, 768)
            let encoded = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(encoded.contains("https://"))
            XCTAssertFalse(encoded.contains(fixture.token))
            XCTAssertFalse(encoded.contains(fixture.id.uuidString))
            XCTAssertEqual(record["kind"] as? String, "gemini_initial_checkpoint_settlement_v1")
            XCTAssertEqual(record["routeClass"] as? String, "google_verification")
            XCTAssertEqual(record["maximumMilliseconds"] as? Int, 3_000)
            XCTAssertEqual(record["originalPreparationDeadlineRetained"] as? Bool, true)
            XCTAssertEqual(record["committed"] as? Bool, true)
        }
        try await fixture.assertNoAdapterOrInput()
        XCTAssertEqual(fixture.createdCount, 1)
    }

    func testFailedFinishedNotLoadingAndTerminatedNativeStatesBlockWithoutWaiting() async throws {
        for kind in ["failed", "finished", "not_loading", "terminated"] {
            let fixture = try await Fixture.make()
            defer { fixture.shutdown() }
            fixture.delegate.webView?(fixture.view, didCommit: fixture.navigation)
            switch kind {
            case "failed":
                fixture.delegate.webView?(fixture.view, didFail: fixture.navigation,
                    withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
            case "finished":
                fixture.delegate.webView?(fixture.view, didFinish: fixture.navigation)
            case "not_loading":
                fixture.view.fixtureLoading = false
            default:
                fixture.delegate.webViewWebContentProcessDidTerminate?(fixture.view)
            }
            await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
            XCTAssertNil(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token), "Ineligible native facts cannot start a window")
            try await fixture.assertNoAdapterOrInput()
            XCTAssertEqual(fixture.createdCount, 1)
        }
    }

    func testAnyEarlierGeminiCommitOrOrdinaryAdapterReadForbidsCheckpointSettlement() async throws {
        for inspect in [false, true] {
            let fixture = try await Fixture.make()
            defer { fixture.shutdown() }
            // A prior real Gemini commit is sticky across later generations.
            fixture.settle(url: Fixture.gemini)
            if inspect { _ = try await fixture.poll() }
            try await fixture.beginLocalNavigation(url: Fixture.checkpoint)
            fixture.delegate.webView?(fixture.view, didCommit: fixture.navigation)
            let facts = try XCTUnwrap(fixture.browser.modelNavigationDiagnostic(tabID: fixture.id, view: fixture.view))
            XCTAssertTrue(facts.geminiDocumentCommitObserved)
            XCTAssertTrue(facts.viewLoading && facts.navigationPending)
            await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
            XCTAssertNil(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token))
            // The fresh checkpoint document must never acquire a model owner.
            try await fixture.assertNoAdapterOrInput()
            XCTAssertEqual(fixture.createdCount, 1)
        }
    }

    func testSavedProviderGateWinsDuringSettlementAndDoesNotRenewCheckpointIdentity() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        var diagnostics: [[String: Any]] = []
        fixture.transport.setInitialCheckpointSettlementObserverForTesting { diagnostics.append($0) }
        _ = try await fixture.poll()
        fixture.browser.recordHumanVerificationRequired(provider: "gemini")
        let gate = try XCTUnwrap(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"])
        await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
        XCTAssertEqual(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"], gate)
        XCTAssertEqual(diagnostics.compactMap { $0["phase"] as? String }, ["wait_started", "authority_rejected"])
        try await fixture.assertNoAdapterOrInput()
    }

    func testCancellationAndStaleViewCannotDispatchOrRenewInitialWindow() async throws {
        for close in [false, true] {
            let fixture = try await Fixture.make()
            defer { fixture.shutdown() }
            _ = try await fixture.poll()
            let deadline = fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token)
            if close {
                fixture.browser.closeTab(fixture.id)
                await fixture.assertPollFailure(.staleSession)
            } else {
                let revision = try fixture.browser.modelChangeRevision(for: fixture.id)
                let task = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await fixture.transport.waitForChange(sessionToken: fixture.token, after: revision, until: .now + .seconds(5))
                }
                do { _ = try await task.value; XCTFail("Cancelled native wait must stop") }
                catch { XCTAssertTrue(error is CancellationError) }
                try await fixture.assertNoAdapterOrInput()
            }
            XCTAssertEqual(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token), deadline)
            XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
            XCTAssertEqual(fixture.createdCount, 1)
        }
    }


    func testProvisionalProviderReturnPermanentlyEndsSingleWindowBeforeAnyGeminiCommit() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        var diagnostics: [[String: Any]] = []
        fixture.transport.setInitialCheckpointSettlementObserverForTesting { diagnostics.append($0) }
        _ = try await fixture.poll()
        let deadline = fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token)
        // Valid route observation is not a commit or readiness proof. Even so,
        // this one initial checkpoint exception is retired permanently.
        fixture.view.fixtureURL = Fixture.gemini
        let waiting = try await fixture.poll()
        XCTAssertEqual(waiting["state"] as? String, "loading")
        let facts = try XCTUnwrap(fixture.browser.modelNavigationDiagnostic(tabID: fixture.id, view: fixture.view))
        XCTAssertFalse(facts.geminiDocumentCommitObserved)
        XCTAssertTrue(facts.viewLoading && facts.navigationPending)
        try await fixture.assertNoAdapterOrInput()
        fixture.view.fixtureURL = Fixture.checkpoint
        await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
        XCTAssertEqual(fixture.transport.initialCheckpointSettlementDeadlineForTesting(sessionToken: fixture.token), deadline)
        XCTAssertEqual(diagnostics.compactMap { $0["phase"] as? String }, ["wait_started", "provider_route_observed"])
        try await fixture.assertNoAdapterOrInput()
    }

    func testUnknownRouteEndsGraceAndUsesExistingUnavailablePageChecksWithoutAdapter() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        var diagnostics: [[String: Any]] = []
        fixture.transport.setInitialCheckpointSettlementObserverForTesting { diagnostics.append($0) }
        _ = try await fixture.poll()
        fixture.view.fixtureUnknownURL = true
        fixture.view.fixtureLoading = false
        fixture.delegate.webView?(fixture.view, didFinish: fixture.navigation)
        // Preserve the pre-existing bounded initial-read failure policy; the
        // settlement exception has ended and cannot be restarted on unknown.
        for _ in 0..<3 {
            let unchanged = try await fixture.poll()
            XCTAssertEqual(unchanged["state"] as? String, "loading")
            try await fixture.assertNoAdapterOrInput()
        }
        await fixture.assertPollFailure(.pageUnavailable)
        XCTAssertEqual(diagnostics.compactMap { $0["phase"] as? String }, ["wait_started", "foreign_route_observed"])
        XCTAssertEqual(diagnostics.last?["routeClass"] as? String, "unknown")
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty, "Unknown is not Google verification proof")
        try await fixture.assertNoAdapterOrInput()
    }

    func testExplicitCancelEndsGraceOnceAndClosesOnlyTheUntouchedOwnedView() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        var diagnostics: [[String: Any]] = []
        fixture.transport.setInitialCheckpointSettlementObserverForTesting { diagnostics.append($0) }
        _ = try await fixture.poll()
        try await fixture.assertNoAdapterOrInput()
        let result = try await fixture.call("webProviderCancel", ["sessionToken": fixture.token])
        XCTAssertEqual(result["cleanup"] as? String, "not_created")
        XCTAssertEqual(result["state"] as? String, "finished")
        XCTAssertEqual(diagnostics.compactMap { $0["phase"] as? String }, ["wait_started", "cancelled"])
        XCTAssertNil(fixture.browser.webView(for: fixture.id))
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
        XCTAssertNotNil(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"], "Existing abort-only cleanup gate still applies")
        XCTAssertEqual(fixture.createdCount, 1)
    }

    /// Only URL/loading are controlled. Real local WebContent, the browser's
    /// actual delegate callbacks and transport Poll remain in the test path.
    /// This models navigation ordering; it does not claim a Google redirect.
    @MainActor private final class NavigationView: WKWebView {
        var fixtureURL: URL?
        var fixtureLoading: Bool?
        var fixtureUnknownURL = false
        override var url: URL? { fixtureUnknownURL ? nil : fixtureURL ?? super.url }
        override var isLoading: Bool { fixtureLoading ?? super.isLoading }
        var nativeLoading: Bool { super.isLoading }
    }

    @MainActor private final class Fixture {
        static let gemini = URL(string: "https://gemini.google.com/app")!
        static let checkpoint = URL(string: "https://www.google.com/sorry/index")!
        static let html = """
        <!doctype html><html><body><p>Local empty Gemini readiness fixture</p><script>
        window.fixtureInputCount = 0; window.fixtureClickCount = 0;
        document.addEventListener('input', () => window.fixtureInputCount++);
        document.addEventListener('click', () => window.fixtureClickCount++);
        window.fixtureReady = true;
        </script></body></html>
        """
        let browser = EmbeddedBrowserSession(persistent: false)
        let humanID: UUID
        let humanView: WKWebView
        let window: NSWindow
        let host: EmbeddedModelRenderContainer
        var transport: EmbeddedWebModelTransport!
        var id: UUID!
        var view: NavigationView!
        var delegate: WKNavigationDelegate!
        var navigation: WKNavigation!
        var token = ""
        var createdCount = 0

        init() throws {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            host = EmbeddedModelRenderContainer(session: browser)
            host.frame = window.contentView!.bounds
            window.contentView = host
            browser.installModelRenderHost(host)
            window.orderBack(nil)
            humanID = try browser.createTab()
            humanView = try XCTUnwrap(browser.webView(for: humanID))
            transport = EmbeddedWebModelTransport(browser: browser, createTabForTesting: { [unowned self] _ in
                self.id = try self.browser.createUnloadedModelTabForTesting { configuration in
                    NavigationView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
                }
                self.view = try XCTUnwrap(self.browser.webView(for: self.id) as? NavigationView)
                self.delegate = try XCTUnwrap(self.view.navigationDelegate)
                self.view.navigationDelegate = nil
                self.navigation = try XCTUnwrap(self.view.loadHTMLString(Self.html, baseURL: Self.gemini))
                self.createdCount += 1
                return self.id
            })
        }

        static func make() async throws -> Fixture {
            let fixture = try Fixture()
            let start = try await fixture.call("webProviderStart", ["provider": "gemini"])
            fixture.token = try XCTUnwrap(start["sessionToken"] as? String)
            let deadline = ContinuousClock.now + .seconds(10)
            while fixture.view.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(fixture.view.isLoading)
            let ready = try await fixture.evaluate("return window.fixtureReady === true;")
            XCTAssertEqual(ready as? Bool, true)
            fixture.view.fixtureURL = checkpoint
            fixture.view.fixtureLoading = true
            fixture.delegate.webView?(fixture.view, didStartProvisionalNavigation: fixture.navigation)
            XCTAssertTrue(fixture.browser.hasUncommittedModelNavigation(tabID: fixture.id, view: fixture.view))
            return fixture
        }

        // A new local WebContent load supplies an actual WKNavigation identity.
        // No external request, provider page, retry or app runtime is exercised.
        func beginLocalNavigation(url: URL) async throws {
            view.fixtureURL = url
            view.fixtureLoading = true
            navigation = try XCTUnwrap(view.loadHTMLString(Self.html, baseURL: Self.gemini))
            delegate.webView?(view, didStartProvisionalNavigation: navigation)
            let deadline = ContinuousClock.now + .seconds(10)
            while view.nativeLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(view.nativeLoading)
            let ready = try await evaluate("return window.fixtureReady === true;")
            XCTAssertEqual(ready as? Bool, true)
        }

        func settle(url: URL) {
            view.fixtureURL = url
            delegate.webView?(view, didCommit: navigation)
            view.fixtureLoading = false
            delegate.webView?(view, didFinish: navigation)
        }

        func call(_ operation: String, _ params: [String: String]) async throws -> [String: Any] {
            let result = try await transport.request(operation: operation, params: JSONSerialization.data(withJSONObject: params))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        }

        func poll() async throws -> [String: Any] { try await call("webProviderPoll", ["sessionToken": token]) }

        func evaluate(_ script: String, isolated: Bool = false) async throws -> Any {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                view.callAsyncJavaScript(script, arguments: [:], in: nil,
                    in: isolated ? .world(name: "computa-chatgpt-model-v1") : .page) { result in
                    switch result {
                    case .success(let value):
                        do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) }
                        catch { continuation.resume(throwing: error) }
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
            return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        }

        func assertNoAdapterOrInput(file: StaticString = #filePath, line: UInt = #line) async throws {
            let untouched = try await evaluate("return globalThis.__computaModelOwner === undefined;", isolated: true)
            XCTAssertEqual(untouched as? Bool, true, file: file, line: line)
            try await assertNoInput(file: file, line: line)
        }

        func assertNoInput(file: StaticString = #filePath, line: UInt = #line) async throws {
            let input = try await evaluate("return [window.fixtureInputCount, window.fixtureClickCount];")
            XCTAssertEqual(input as? [Int], [0, 0], file: file, line: line)
        }

        func assertPollFailure(_ expected: EmbeddedWebModelTransport.Failure, file: StaticString = #filePath, line: UInt = #line) async {
            do { _ = try await poll(); XCTFail("Expected \(expected)", file: file, line: line) }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expected, file: file, line: line) }
        }

        func shutdown() {
            browser.shutdown()
            host.detach()
            window.orderOut(nil)
            window.close()
        }
    }
}

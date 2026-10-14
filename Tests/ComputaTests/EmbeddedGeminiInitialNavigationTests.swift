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

    func testCommittedCheckpointStillBlocksWhileLoadingAndDisposesOnlyUntouchedView() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.shutdown() }
        _ = try await fixture.poll()
        fixture.delegate.webView?(fixture.view, didCommit: fixture.navigation)
        XCTAssertTrue(fixture.view.isLoading)
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
        await fixture.assertPollFailure(.humanVerificationRequired(.gemini))
        XCTAssertNotNil(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertEqual(fixture.createdCount, 1)
    }

    /// Only URL/loading are controlled. Real local WebContent, the browser's
    /// actual delegate callbacks and transport Poll remain in the test path.
    /// This models navigation ordering; it does not claim a Google redirect.
    @MainActor private final class NavigationView: WKWebView {
        var fixtureURL: URL?
        var fixtureLoading: Bool?
        override var url: URL? { fixtureURL ?? super.url }
        override var isLoading: Bool { fixtureLoading ?? super.isLoading }
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

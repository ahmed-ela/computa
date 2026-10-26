import AppKit
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedModelNavigationObservationTests: XCTestCase {
    func testGeminiCommitObservationPersistsForOwnedViewWhileRedirectResetsPerNavigation() throws {
        let fixture = try Fixture()
        defer { fixture.browser.shutdown() }
        let first = try fixture.start(url: URL(string: "https://gemini.google.com/app")!)
        XCTAssertFalse(try fixture.facts().geminiDocumentCommitObserved)
        let beforeRedirect = try fixture.facts()
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: first)
        let redirected = try fixture.facts()
        XCTAssertTrue(redirected.serverRedirectObservedInCurrentNavigation)
        XCTAssertEqual(redirected.generationCommitted, beforeRedirect.generationCommitted)
        XCTAssertEqual(redirected.generationFinished, beforeRedirect.generationFinished)
        XCTAssertEqual(redirected.navigationPending, beforeRedirect.navigationPending)
        XCTAssertEqual(redirected.settled, beforeRedirect.settled)
        fixture.delegate.webView?(fixture.view, didCommit: first)
        fixture.delegate.webView?(fixture.view, didFinish: first)
        XCTAssertTrue(try fixture.facts().geminiDocumentCommitObserved)
        XCTAssertTrue(try fixture.facts().serverRedirectObservedInCurrentNavigation)

        let second = try fixture.start(url: URL(string: "https://www.google.com/sorry/index")!)
        XCTAssertTrue(try fixture.facts().geminiDocumentCommitObserved)
        XCTAssertFalse(try fixture.facts().serverRedirectObservedInCurrentNavigation)
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: first)
        XCTAssertFalse(try fixture.facts().serverRedirectObservedInCurrentNavigation)
        fixture.delegate.webView?(fixture.view, didCommit: second)
        XCTAssertTrue(try fixture.facts().geminiDocumentCommitObserved)
        fixture.delegate.webViewWebContentProcessDidTerminate?(fixture.view)
        XCTAssertTrue(try fixture.facts().geminiDocumentCommitObserved, "Ever observed in this exact view survives navigation failure")
        XCTAssertFalse(try fixture.facts().serverRedirectObservedInCurrentNavigation)
        fixture.browser.closeTab(fixture.id)
        XCTAssertNil(fixture.browser.modelNavigationDiagnostic(tabID: fixture.id, view: fixture.view))
    }

    func testObservationCallbacksRequireExactViewNavigationAndCurrentGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.browser.shutdown() }
        let first = try fixture.start(url: URL(string: "https://gemini.google.com/app")!)
        let foreign = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let other = try XCTUnwrap(fixture.view.loadHTMLString("<p>Other local navigation</p>", baseURL: nil))
        for navigation in [nil, other] as [WKNavigation?] {
            fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: navigation)
            fixture.delegate.webView?(fixture.view, didCommit: navigation)
        }
        fixture.delegate.webView?(foreign, didReceiveServerRedirectForProvisionalNavigation: first)
        fixture.delegate.webView?(foreign, didCommit: first)
        XCTAssertFalse(try fixture.facts().geminiDocumentCommitObserved)
        XCTAssertFalse(try fixture.facts().serverRedirectObservedInCurrentNavigation)

        let oldGeneration = fixture.browser.documentGeneration(for: fixture.id)
        try fixture.browser.navigate(tabID: fixture.id, to: URL(string: "about:blank")!)
        XCTAssertNotEqual(fixture.browser.documentGeneration(for: fixture.id), oldGeneration)
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: first)
        fixture.delegate.webView?(fixture.view, didCommit: first)
        XCTAssertFalse(try fixture.facts().geminiDocumentCommitObserved)
        XCTAssertFalse(try fixture.facts().serverRedirectObservedInCurrentNavigation)

        let failed = try fixture.start(url: URL(string: "https://gemini.google.com/app")!)
        fixture.delegate.webView?(fixture.view, didFailProvisionalNavigation: failed,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: failed)
        fixture.delegate.webView?(fixture.view, didCommit: failed)
        XCTAssertFalse(try fixture.facts().geminiDocumentCommitObserved)
        XCTAssertFalse(try fixture.facts().serverRedirectObservedInCurrentNavigation)

        let committed = try fixture.start(url: URL(string: "https://www.google.com/sorry/index")!)
        fixture.delegate.webView?(fixture.view, didCommit: committed)
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: committed)
        XCTAssertFalse(try fixture.facts().serverRedirectObservedInCurrentNavigation, "A late callback is not a provisional redirect observation")
        fixture.delegate.webView?(fixture.view, didFinish: committed)
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: committed)
        XCTAssertFalse(try fixture.facts().serverRedirectObservedInCurrentNavigation)
    }

    func testGeminiCommitObservationRequiresTrustedAllowedRouteAndActualCommit() throws {
        let routes: [(String?, Bool)] = [
            ("https://gemini.google.com/app", true),
            ("https://gemini.google.com/u/2/app/fixture", true),
            ("https://www.google.com/sorry/index", false),
            ("https://gemini.google.com/signin", false),
            ("https://gemini.google.com.evil.invalid/app", false),
            ("http://gemini.google.com/app", false),
            ("https://user:secret@gemini.google.com/app", false),
            (nil, false),
        ]
        for (route, expected) in routes {
            let fixture = try Fixture()
            defer { fixture.browser.shutdown() }
            let navigation = try fixture.start(url: route.flatMap { URL(string: $0) })
            XCTAssertFalse(try fixture.facts().geminiDocumentCommitObserved)
            fixture.delegate.webView?(fixture.view, didCommit: navigation)
            XCTAssertEqual(try fixture.facts().geminiDocumentCommitObserved, expected)
        }
        let fixture = try Fixture()
        defer { fixture.browser.shutdown() }
        let navigation = try fixture.start(url: URL(string: "https://gemini.google.com/app")!)
        fixture.delegate.webView?(fixture.view, didFinish: navigation)
        XCTAssertFalse(try fixture.facts().geminiDocumentCommitObserved, "An allowed URL and finish without commit prove no observed commit")
    }

    func testNavigationObservationLogIsFiniteAndUnknownOwnershipHasNoPositiveFacts() throws {
        let fixture = try Fixture()
        defer { fixture.browser.shutdown() }
        let navigation = try fixture.start(url: URL(string: "https://gemini.google.com/app/PRIVATE_ROUTE?secret=PRIVATE_QUERY")!)
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: navigation)
        fixture.delegate.webView?(fixture.view, didCommit: navigation)
        let log = try fixture.facts().logDescription
        let fields = Dictionary(uniqueKeysWithValues: log.split(separator: " ").map { field in
            let parts = field.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), String(parts[1]))
        })
        XCTAssertEqual(Set(fields.keys), ["known", "viewLoading", "tabLoading", "navigationPending", "generationCommitted", "generationFinished", "navigationError", "settled", "geminiDocumentCommitObserved", "serverRedirectObservedInCurrentNavigation"])
        XCTAssertTrue(fields.values.allSatisfy { $0 == "true" || $0 == "false" })
        XCTAssertEqual(fields["geminiDocumentCommitObserved"], "true")
        XCTAssertEqual(fields["serverRedirectObservedInCurrentNavigation"], "true")
        XCTAssertLessThan(log.utf8.count, 512)
        for secret in ["PRIVATE_ROUTE", "PRIVATE_QUERY", "https", fixture.id.uuidString] {
            XCTAssertFalse(log.contains(secret))
        }
        let humanID = try fixture.browser.createTab()
        let human = try XCTUnwrap(fixture.browser.webView(for: humanID))
        XCTAssertNil(fixture.browser.modelNavigationDiagnostic(tabID: fixture.id, view: human))
        XCTAssertNil(fixture.browser.modelNavigationDiagnostic(tabID: humanID, view: human))
        let unknown = EmbeddedBrowserSession.ModelNavigationDiagnostic.unknownLogDescription
        XCTAssertTrue(unknown.contains("geminiDocumentCommitObserved=unknown"))
        XCTAssertTrue(unknown.contains("serverRedirectObservedInCurrentNavigation=unknown"))
        XCTAssertFalse(unknown.contains("=true"))
        fixture.browser.shutdown()
        fixture.delegate.webView?(fixture.view, didReceiveServerRedirectForProvisionalNavigation: navigation)
        fixture.delegate.webView?(fixture.view, didCommit: navigation)
        XCTAssertNil(fixture.browser.modelNavigationDiagnostic(tabID: fixture.id, view: fixture.view))
    }

    /// Real local WKNavigation identities with controlled native URL reporting.
    /// These tests exercise delegate bookkeeping, not a real Google redirect.
    @MainActor private final class ObservationView: WKWebView {
        var observedURL: URL?
        override var url: URL? { observedURL }
    }

    @MainActor private final class Fixture {
        let browser = EmbeddedBrowserSession(persistent: false)
        let id: UUID
        let view: ObservationView
        let delegate: any WKNavigationDelegate

        init() throws {
            id = try browser.createUnloadedModelTabForTesting { configuration in
                ObservationView(frame: .zero, configuration: configuration)
            }
            view = try XCTUnwrap(browser.webView(for: id) as? ObservationView)
            delegate = try XCTUnwrap(view.navigationDelegate)
            view.navigationDelegate = nil
        }

        func start(url: URL?) throws -> WKNavigation {
            view.observedURL = url
            let navigation = try XCTUnwrap(view.loadHTMLString("<p>Local navigation observation fixture</p>", baseURL: nil))
            delegate.webView?(view, didStartProvisionalNavigation: navigation)
            return navigation
        }

        func facts() throws -> EmbeddedBrowserSession.ModelNavigationDiagnostic {
            try XCTUnwrap(browser.modelNavigationDiagnostic(tabID: id, view: view))
        }
    }
}

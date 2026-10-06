import AppKit
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedBrowserSessionTests: XCTestCase {
    func testStartsEmptyAndCreatesBlankTabWithoutLoadingAHomepage() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(session.selectedTabID)
        let id = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: id))
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.selectedTabID, id)
        XCTAssertEqual(session.tabs[0].title, "New tab")
        XCTAssertNil(session.tabs[0].url)
        XCTAssertNil(view.url)
        XCTAssertFalse(view.isLoading)
        XCTAssertFalse(session.tabs[0].isLoading)
        XCTAssertFalse(session.tabs[0].canGoBack)
        XCTAssertFalse(session.tabs[0].canGoForward)
    }

    func testViewsHaveSeparateConfigurationWithoutPrivilegedScriptsOrDefaultProfile() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let otherSession = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown(); otherSession.shutdown() }
        let first = try XCTUnwrap(session.webView(for: session.createTab()))
        let second = try XCTUnwrap(session.webView(for: session.createTab()))
        let other = try XCTUnwrap(otherSession.webView(for: otherSession.createTab()))
        XCTAssertFalse(first.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(first.configuration.websiteDataStore === second.configuration.websiteDataStore)
        XCTAssertFalse(first.configuration.websiteDataStore === other.configuration.websiteDataStore)
        XCTAssertFalse(first.configuration.userContentController === second.configuration.userContentController)
        XCTAssertTrue(first.configuration.userContentController.userScripts.isEmpty)
        XCTAssertNil(first.configuration.urlSchemeHandler(forURLScheme: "localcodex-app"))
        XCTAssertFalse(first.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertNotNil(first.navigationDelegate)
        XCTAssertNotNil(first.uiDelegate)
    }

    func testNonpersistentSessionDoesNotCreateProductionProfilePreference() throws {
        let suite = "Computa.EmbeddedBrowser.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = EmbeddedBrowserSession(persistent: false, defaults: defaults)
        defer { session.shutdown() }
        _ = try session.createTab()
        XCTAssertNil(defaults.string(forKey: EmbeddedBrowserSession.profileDefaultsKey))
    }

    func testUnselectedCreationAndSelectionPreserveStableTabAndDocumentIdentities() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let first = try session.createTab()
        let document = session.tabs[0].documentID
        let view = session.webView(for: first)
        let second = try session.createTab(select: false)
        XCTAssertEqual(session.selectedTabID, first)
        session.selectTab(second)
        session.selectTab(first)
        XCTAssertEqual(session.selectedTabID, first)
        XCTAssertEqual(session.tabs[0].documentID, document)
        XCTAssertTrue(session.webView(for: first) === view)
    }

    func testFirstInactiveTabDoesNotAcquireSelectionAndClosingItLeavesInventoryEmpty() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let first = try session.createTab(select: false)
        let second = try session.createTab(select: false)
        XCTAssertNil(session.selectedTabID)
        XCTAssertEqual(session.tabs.map(\.id), [first, second])
        XCTAssertNil(session.webView(for: first)?.superview)
        XCTAssertNil(session.webView(for: second)?.superview)
        session.closeTab(first)
        XCTAssertNil(session.selectedTabID)
        session.closeTab(second)
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(session.selectedTabID)
    }

    func testTabCapRejectsWithoutAllocatingOrChangingSelection() throws {
        let session = EmbeddedBrowserSession(persistent: false, maximumTabs: 2)
        defer { session.shutdown() }
        _ = try session.createTab()
        let selected = try session.createTab()
        XCTAssertThrowsError(try session.createTab()) {
            XCTAssertEqual($0 as? EmbeddedBrowserSession.Failure, .tabLimit(2))
        }
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertEqual(session.selectedTabID, selected)
        XCTAssertNotNil(session.errorMessage)
        session.closeTab(selected)
        XCTAssertNoThrow(try session.createTab())
        XCTAssertNil(session.errorMessage)
    }

    func testClosingTabDetachesViewClearsDelegatesAndIgnoresLateCallbacks() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let first = try session.createTab()
        let last = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: last))
        let delegate = try XCTUnwrap(view.navigationDelegate)
        let host = NSView()
        host.addSubview(view)
        session.closeTab(last)
        XCTAssertNil(session.webView(for: last))
        XCTAssertNil(view.superview)
        XCTAssertNil(view.navigationDelegate)
        XCTAssertNil(view.uiDelegate)
        XCTAssertEqual(session.selectedTabID, first)
        delegate.webViewWebContentProcessDidTerminate?(view)
        delegate.webView?(view, didFinish: nil)
        XCTAssertNil(session.errorMessage)
        XCTAssertNil(session.tabs[0].error)
        XCTAssertEqual(session.tabs.map(\.id), [first])
    }

    func testClosingMiddleSelectedTabChoosesNextThenPreviousWithoutCreatingTabs() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let a = try session.createTab(), b = try session.createTab(), c = try session.createTab()
        session.selectTab(b)
        session.closeTab(b)
        XCTAssertEqual(session.selectedTabID, c)
        session.closeTab(c)
        XCTAssertEqual(session.selectedTabID, a)
        session.closeTab(a)
        XCTAssertNil(session.selectedTabID)
        XCTAssertTrue(session.tabs.isEmpty)
        session.closeTab(a)
        XCTAssertTrue(session.tabs.isEmpty)
    }

    func testInvalidNavigationAndCreationDoNotReplaceCurrentTabOrDocument() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab()
        let document = session.tabs[0].documentID
        for address in ["file:///tmp/example.html", "javascript:alert(1)", "data:text/html,hello", "mailto:test@example.com"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertThrowsError(try session.navigate(tabID: id, to: url))
            XCTAssertThrowsError(try session.createTab(url: url))
            XCTAssertEqual(session.tabs.map(\.id), [id])
            XCTAssertEqual(session.tabs[0].documentID, document)
            XCTAssertNil(session.webView(for: id)?.url)
            XCTAssertEqual(session.selectedTabID, id)
        }
    }

    func testNavigationAndStopInvalidateDocumentIdentityWithoutChangingTabIdentity() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab()
        let before = session.tabs[0].documentID
        try session.navigate(tabID: id, to: XCTUnwrap(URL(string: "about:blank")))
        let afterNavigation = session.tabs[0].documentID
        XCTAssertNotEqual(before, afterNavigation)
        session.stop(tabID: id)
        XCTAssertNotEqual(afterNavigation, session.tabs[0].documentID)
        XCTAssertEqual(session.tabs[0].id, id)
        XCTAssertFalse(session.tabs[0].isLoading)
    }

    func testProcessTerminationReportsRecoverableErrorWithoutReloadingOrNewTab() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: id))
        let previousDocument = session.tabs[0].documentID
        view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view)
        XCTAssertNotEqual(previousDocument, session.tabs[0].documentID)
        XCTAssertTrue(session.tabs[0].error?.contains("Reload this tab to recover; no action was replayed") == true)
        XCTAssertEqual(session.errorMessage, session.tabs[0].error)
        XCTAssertFalse(session.tabs[0].isLoading)
        XCTAssertNil(view.url)
        XCTAssertEqual(session.tabs.map(\.id), [id])
    }

    func testShutdownIsIdempotentAndSessionCannotBeReused() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let id = try session.createTab()
        session.shutdown()
        session.shutdown()
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(session.selectedTabID)
        XCTAssertNil(session.webView(for: id))
        XCTAssertThrowsError(try session.createTab()) {
            XCTAssertEqual($0 as? EmbeddedBrowserSession.Failure, .sessionClosed)
        }
        XCTAssertThrowsError(try session.navigate(tabID: id, to: URL(string: "about:blank")!)) {
            XCTAssertEqual($0 as? EmbeddedBrowserSession.Failure, .sessionClosed)
        }
    }

    func testClosedWebViewIsReleasedAfterCallbacksDrain() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        weak var releasedView: WKWebView?
        try autoreleasepool {
            let id = try session.createTab()
            releasedView = session.webView(for: id)
            XCTAssertNotNil(releasedView)
            session.closeTab(id)
        }
        for _ in 0..<40 where releasedView != nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(releasedView, "Closed tabs must not stay retained by the browser owner, observers or delegates")
    }

    func testAppShutdownReleasesAllOwnedTabs() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        _ = try session.createTab()
        _ = try session.createTab()
        _ = await state.shutdownRuntime()
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertThrowsError(try session.createTab())
    }

    func testAddressNormalizationAddsHTTPSAndPreservesExplicitWebAddresses() throws {
        for (input, expected) in [
            ("example.com", "https://example.com"),
            ("  https://example.com/path?q=1  ", "https://example.com/path?q=1"),
            ("localhost:5181", "https://localhost:5181"),
            ("example.com:443/path?q=1", "https://example.com:443/path?q=1"),
            ("example.com?hello=world", "https://example.com?hello=world"),
            ("example.com/?next=https://example.org", "https://example.com/?next=https://example.org"),
            ("[::1]:5181", "https://[::1]:5181"),
            ("http://127.0.0.1:5181", "http://127.0.0.1:5181"),
            ("about:blank", "about:blank"),
        ] {
            XCTAssertEqual(try EmbeddedBrowserURLPolicy.normalize(input).absoluteString, expected)
        }
    }

    func testAddressNormalizationSearchesWordsAndEncodesQueriesWithoutLosingCharacters() throws {
        for input in ["hello", "search for papers", "site:example.com", "site:example.com cats", "Rust: ownership guide", "compare https://example.com and https://example.org", "C++ & Swift #1", "café 東京", "  two words  "] {
            let url = try EmbeddedBrowserURLPolicy.normalize(input)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "www.google.com")
            XCTAssertEqual(url.path, "/search")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "q", value: input.trimmingCharacters(in: .whitespacesAndNewlines))])
        }
        XCTAssertTrue(try EmbeddedBrowserURLPolicy.normalize("C++ & Swift #1").absoluteString.contains("C%2B%2B"))
    }

    func testAddressNormalizationStillRejectsExternalSchemesAndInvalidAddresses() throws {
        for input in ["", "  ", "javascript:alert(1)", "javascript:alert('hello world')", "file:///tmp/test", "data:text/html,x", "mailto:user@example.com", "about:config", "https://user:secret@example.com", "https://", "https://example.com:70000", "example.com:abc"] {
            XCTAssertThrowsError(try EmbeddedBrowserURLPolicy.normalize(input), input)
        }
    }

    func testWebsiteNavigationDoesNotUseSearchFallback() throws {
        for input in ["javascript:alert(1)", "file:///tmp/test", "data:text/html,x", "custom:search"] {
            XCTAssertThrowsError(try EmbeddedBrowserURLPolicy.validate(XCTUnwrap(URL(string: input))), input)
        }
    }
}

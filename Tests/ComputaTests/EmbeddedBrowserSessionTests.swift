import AppKit
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedBrowserSessionTests: XCTestCase {
    func testCommittedDocumentIdentityIgnoresCancelledProvisionalNavigationAndRejectsStaleOrModelReads() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        let delegate = try XCTUnwrap(view.navigationDelegate)
        // Use real WebKit navigation tokens with synchronous native delegate
        // callbacks. Detaching avoids asynchronous page-load races in this test.
        view.navigationDelegate = nil
        let initialGeneration = try XCTUnwrap(session.documentGeneration(for: id))
        XCTAssertNil(session.committedHumanDocumentID(for: id, generation: initialGeneration))
        let first = try XCTUnwrap(view.loadHTMLString("<main>First document</main>", baseURL: nil))
        delegate.webView?(view, didStartProvisionalNavigation: first)
        let firstGeneration = try XCTUnwrap(session.documentGeneration(for: id))
        XCTAssertNil(session.committedHumanDocumentID(for: id, generation: firstGeneration))
        delegate.webView?(view, didCommit: first)
        let firstID = try XCTUnwrap(session.committedHumanDocumentID(for: id, generation: firstGeneration))
        delegate.webView?(view, didFinish: first)
        let provisional = try XCTUnwrap(view.loadHTMLString("<main>Never committed</main>", baseURL: nil))
        delegate.webView?(view, didStartProvisionalNavigation: provisional)
        let provisionalGeneration = try XCTUnwrap(session.documentGeneration(for: id))
        XCTAssertNotEqual(firstGeneration, provisionalGeneration)
        XCTAssertNil(session.committedHumanDocumentID(for: id, generation: firstGeneration))
        XCTAssertEqual(session.committedHumanDocumentID(for: id, generation: provisionalGeneration), firstID)
        delegate.webView?(view, didFailProvisionalNavigation: provisional,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertEqual(session.committedHumanDocumentID(for: id, generation: provisionalGeneration), firstID,
                       "Cancelled provisional navigation must not refund failures on the old document")
        let replacement = try XCTUnwrap(view.loadHTMLString("<main>Replacement</main>", baseURL: nil))
        delegate.webView?(view, didStartProvisionalNavigation: replacement)
        let replacementGeneration = try XCTUnwrap(session.documentGeneration(for: id))
        XCTAssertEqual(session.committedHumanDocumentID(for: id, generation: replacementGeneration), firstID)
        delegate.webView?(view, didCommit: replacement)
        let replacementID = try XCTUnwrap(session.committedHumanDocumentID(for: id, generation: replacementGeneration))
        XCTAssertNotEqual(replacementID, firstID)
        delegate.webView?(view, didCommit: replacement)
        XCTAssertEqual(session.committedHumanDocumentID(for: id, generation: replacementGeneration), replacementID)
        XCTAssertNil(session.committedHumanDocumentID(for: id, generation: provisionalGeneration))
        let modelID = try session.createUnloadedModelTabForTesting()
        let modelView = try XCTUnwrap(session.webView(for: modelID)), modelDelegate = try XCTUnwrap(modelView.navigationDelegate)
        modelView.navigationDelegate = nil
        let modelNavigation = try XCTUnwrap(modelView.loadHTMLString("<main>Inference</main>", baseURL: nil))
        modelDelegate.webView?(modelView, didStartProvisionalNavigation: modelNavigation)
        modelDelegate.webView?(modelView, didCommit: modelNavigation)
        XCTAssertNil(session.committedHumanDocumentID(for: modelID, generation: try XCTUnwrap(session.documentGeneration(for: modelID))))
        session.closeTab(id)
        XCTAssertNil(session.committedHumanDocumentID(for: id, generation: replacementGeneration))
    }

    func testWebInspectorOptInIsPerTabAndPreservesTheBrowserDocument() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let firstID = try session.createTab()
        let secondID = try session.createTab(select: false)
        let first = try XCTUnwrap(session.webView(for: firstID))
        let second = try XCTUnwrap(session.webView(for: secondID))
        let generation = session.documentGeneration(for: firstID)
        XCTAssertFalse(first.isInspectable)
        XCTAssertFalse(second.isInspectable)
        XCTAssertTrue(session.canInspect(tabID: firstID))
        try session.setWebInspectorEnabled(true, for: firstID)
        XCTAssertTrue(first.isInspectable)
        XCTAssertTrue(try XCTUnwrap(session.humanTab(id: firstID)).isWebInspectorEnabled)
        XCTAssertFalse(second.isInspectable)
        XCTAssertEqual(session.selectedTabID, firstID)
        XCTAssertEqual(session.documentGeneration(for: firstID), generation)
        XCTAssertNil(first.url)
        XCTAssertTrue(first.configuration.userContentController.userScripts.isEmpty)
        try session.setWebInspectorEnabled(false, for: firstID)
        XCTAssertFalse(first.isInspectable)
        XCTAssertFalse(try XCTUnwrap(session.humanTab(id: firstID)).isWebInspectorEnabled)
        session.closeTab(firstID)
        XCTAssertFalse(session.canInspect(tabID: firstID))
        XCTAssertThrowsError(try session.setWebInspectorEnabled(true, for: firstID)) {
            XCTAssertEqual($0 as? EmbeddedBrowserSession.Failure, .tabClosed)
        }
    }

    func testWebInspectorCannotBeEnabledForInferenceOrToolOwnedViews() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let modelID = try session.createUnloadedModelTabForTesting()
        let toolID = try session.createToolTab(url: XCTUnwrap(URL(string: "about:blank")))
        for id in [modelID, toolID] {
            let view = try XCTUnwrap(session.webView(for: id))
            XCTAssertFalse(session.canInspect(tabID: id))
            XCTAssertThrowsError(try session.setWebInspectorEnabled(true, for: id))
            XCTAssertFalse(view.isInspectable)
            try session.setWebInspectorEnabled(false, for: id)
            XCTAssertFalse(view.isInspectable)
        }
    }

    func testWebInspectorIsRevokedBeforeToolMutationAndDoesNotResumeAfterReplacement() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: id))
        try await loadPopupFixture(view)
        let generation = try XCTUnwrap(session.documentGeneration(for: id))
        try session.setWebInspectorEnabled(true, for: id)
        XCTAssertTrue(view.isInspectable)
        _ = try session.prepareToolMutation(tabID: id, generation: generation)
        XCTAssertFalse(view.isInspectable)
        XCTAssertFalse(try XCTUnwrap(session.humanTab(id: id)).isWebInspectorEnabled)
        XCTAssertFalse(session.canInspect(tabID: id))
        XCTAssertThrowsError(try session.setWebInspectorEnabled(true, for: id))
        XCTAssertEqual(session.documentGeneration(for: id), generation)
        let ready = try await script(view, "return !!document.getElementById('ready');")
        XCTAssertEqual(ready, Data("true".utf8))
        try await loadPopupFixture(view)
        XCTAssertTrue(session.canInspect(tabID: id), "A committed replacement releases the tool's old document")
        XCTAssertFalse(view.isInspectable, "Inspection requires another explicit opt-in")
        try session.setWebInspectorEnabled(true, for: id)
        session.closeTab(id)
        XCTAssertFalse(view.isInspectable, "Retaining the detached WebView cannot retain inspection access")
    }

    func testWebInspectorDoesNotPropagateToPopupsAndShutdownRevokesHeldViews() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let openerID = try session.createTab()
        let opener = try XCTUnwrap(session.webView(for: openerID))
        defer { session.shutdown() }
        try await loadPopupFixture(opener)
        try session.setWebInspectorEnabled(true, for: openerID)
        _ = try await script(opener, "document.getElementById('blank-link').click(); return true;")
        try await waitForPopupCount(2, session: session)
        let childID = try XCTUnwrap(session.tabs.first(where: { $0.id != openerID })).id
        let child = try XCTUnwrap(session.webView(for: childID))
        XCTAssertTrue(opener.isInspectable)
        XCTAssertFalse(child.isInspectable)
        try session.setWebInspectorEnabled(true, for: childID)
        session.shutdown()
        XCTAssertFalse(opener.isInspectable)
        XCTAssertFalse(child.isInspectable)
        XCTAssertFalse(session.canInspect(tabID: childID))
        XCTAssertThrowsError(try session.setWebInspectorEnabled(true, for: childID)) {
            XCTAssertEqual($0 as? EmbeddedBrowserSession.Failure, .sessionClosed)
        }
    }

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
        XCTAssertTrue(first.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertNotNil(first.navigationDelegate)
        XCTAssertNotNil(first.uiDelegate)
    }

    func testOnlyInferenceViewsDisableInactiveSchedulingBeforeConstruction() throws {
        let platformDefault = WKWebViewConfiguration().preferences.inactiveSchedulingPolicy
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let humanID = try session.createTab()
        let human = try XCTUnwrap(session.webView(for: humanID))
        var constructionPolicy: WKPreferences.InactiveSchedulingPolicy?
        var constructionHasNoScripts = false
        let modelID = try session.createUnloadedModelTabForTesting { configuration in
            constructionPolicy = configuration.preferences.inactiveSchedulingPolicy
            constructionHasNoScripts = configuration.userContentController.userScripts.isEmpty
            return WKWebView(frame: .zero, configuration: configuration)
        }
        let model = try XCTUnwrap(session.webView(for: modelID))
        let toolID = try session.createToolTab(url: XCTUnwrap(URL(string: "about:blank")))
        let tool = try XCTUnwrap(session.webView(for: toolID))
        let laterHuman = try XCTUnwrap(session.webView(for: session.createTab(select: false)))

        XCTAssertEqual(constructionPolicy, WKPreferences.InactiveSchedulingPolicy.none)
        XCTAssertEqual(model.configuration.preferences.inactiveSchedulingPolicy, .none)
        for view in [human, tool, laterHuman] {
            XCTAssertEqual(view.configuration.preferences.inactiveSchedulingPolicy, platformDefault,
                           "Model scheduling must not change the platform policy for human or tool tabs")
            XCTAssertFalse(view.configuration.preferences === model.configuration.preferences)
        }
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertFalse(model.isInspectable)
        XCTAssertFalse(model.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(tool.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(human.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(constructionHasNoScripts)
        // The production completion observer is installed only after the
        // inference view exists. It must never enter human or tool views.
        let scripts = model.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(try XCTUnwrap(scripts.first).source.contains(EmbeddedBrowserSession.responseCompletionName))
        XCTAssertTrue(try XCTUnwrap(scripts.first).isForMainFrameOnly)
        for view in [human, tool, laterHuman] {
            XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        }
    }

    func testAsyncBlankPopupPreservesOpenerAndSharedConfigurationAndClosesOnlyChild() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = host
        defer { session.shutdown(); window.close() }
        let openerID = try session.createTab()
        let opener = try XCTUnwrap(session.webView(for: openerID))
        try session.presentTab(openerID, in: host)
        try await loadPopupFixture(opener)
        let document = session.documentGeneration(for: openerID)
        _ = try await script(opener, """
        window.receipts = [];
        window.addEventListener('message', event => {
          if (event.source === window.fixtureChild && event.data === 'popup-finished') window.receipts.push(event.data);
        });
        setTimeout(() => {
          window.fixtureChild = window.open('', 'computa-auth-fixture');
          if (window.fixtureChild) {
            window.fixtureChild.document.write('<!doctype html><p id="popup-ready">Popup fixture</p>');
            window.fixtureChild.document.close();
          }
        }, 30);
        return true;
        """)
        try await waitForPopupCount(2, session: session)
        let childTab = try XCTUnwrap(session.tabs.first(where: { $0.id != openerID }))
        let child = try XCTUnwrap(session.webView(for: childTab.id))
        XCTAssertNil(session.errorMessage)
        XCTAssertNil(session.tabs.first(where: { $0.id == openerID })?.error)
        session.detachPresentedTab(openerID, from: host)
        try session.presentTab(childTab.id, in: host)
        XCTAssertTrue(childTab.isPopup)
        XCTAssertEqual(session.selectedTabID, childTab.id)
        XCTAssertTrue(child.configuration.websiteDataStore === opener.configuration.websiteDataStore)
        XCTAssertTrue(child.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(child.configuration.userContentController.userScripts.isEmpty)
        XCTAssertNil(child.configuration.urlSchemeHandler(forURLScheme: "localcodex-app"))
        let childReady = try await script(child, "return !!document.getElementById('popup-ready') && !!window.opener;")
        XCTAssertEqual(childReady, Data("true".utf8))
        _ = try await script(child, "window.opener.postMessage('popup-finished', window.opener.location.origin); return true;")
        let deadline = ContinuousClock.now + .seconds(5)
        var received = false
        while ContinuousClock.now < deadline {
            received = (try? await script(opener, "return window.receipts.length === 1;")) == Data("true".utf8)
            if received { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(received, "The real popup must deliver its completion to the unchanged opener")
        _ = try await script(child, "setTimeout(() => window.close(), 0); return true;")
        try await waitForPopupCount(1, session: session)
        XCTAssertEqual(session.selectedTabID, openerID)
        XCTAssertTrue(session.webView(for: openerID) === opener)
        XCTAssertEqual(session.documentGeneration(for: openerID), document)
        XCTAssertNil(session.webView(for: childTab.id))
        XCTAssertNil(child.uiDelegate)
        XCTAssertNil(child.navigationDelegate)
        let closed = try await script(opener, "return window.fixtureChild.closed && !!document.getElementById('ready');")
        XCTAssertEqual(closed, Data("true".utf8))
    }

    func testTargetBlankPopupAndCloseCallbacksPreserveOpenerAndBackgroundSelection() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let openerID = try session.createTab()
        let opener = try XCTUnwrap(session.webView(for: openerID))
        try await loadPopupFixture(opener)
        _ = try await script(opener, "document.getElementById('blank-link').click(); return true;")
        try await waitForPopupCount(2, session: session)
        let firstID = try XCTUnwrap(session.tabs.first(where: { $0.id != openerID })).id
        let first = try XCTUnwrap(session.webView(for: firstID))
        let firstDelegate = try XCTUnwrap(first.uiDelegate)
        XCTAssertTrue(session.tabs.first(where: { $0.id == firstID })?.isPopup == true)
        firstDelegate.webViewDidClose?(opener)
        opener.uiDelegate?.webViewDidClose?(opener)
        XCTAssertEqual(session.tabs.count, 2, "Wrong-view and ordinary-tab close callbacks have no child authority")
        _ = try await script(opener, "window.otherChild = window.open('about:blank', 'second-popup'); return !!window.otherChild;")
        try await waitForPopupCount(3, session: session)
        let secondID = try XCTUnwrap(session.tabs.last).id
        let second = try XCTUnwrap(session.webView(for: secondID))
        session.selectTab(openerID)
        firstDelegate.webViewDidClose?(first)
        XCTAssertEqual(session.selectedTabID, openerID, "Closing a background child cannot switch tabs")
        firstDelegate.webViewDidClose?(second)
        XCTAssertNotNil(session.webView(for: secondID), "A late child delegate cannot close another tab")
        session.closeTab(openerID)
        XCTAssertNotNil(session.webView(for: secondID), "Closing the opener leaves its human child usable")
        session.selectTab(secondID)
        second.uiDelegate?.webViewDidClose?(second)
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(session.selectedTabID)
    }

    func testPopupCapAndInferenceOwnershipRejectWithoutReplacingTabs() async throws {
        let session = EmbeddedBrowserSession(persistent: false, maximumTabs: 2)
        defer { session.shutdown() }
        let openerID = try session.createTab()
        let opener = try XCTUnwrap(session.webView(for: openerID))
        try await loadPopupFixture(opener)
        let selected = try session.createTab()
        let generation = session.documentGeneration(for: openerID)
        let rejected = try await script(opener, "return window.open('about:blank', 'over-cap') === null;")
        XCTAssertEqual(rejected, Data("true".utf8))
        XCTAssertEqual(session.tabs.map(\.id), [openerID, selected])
        XCTAssertEqual(session.selectedTabID, selected)
        XCTAssertEqual(session.documentGeneration(for: openerID), generation)
        XCTAssertTrue(session.tabs[0].error?.contains("up to 2 tabs") == true)

        let modelSession = EmbeddedBrowserSession(persistent: false)
        defer { modelSession.shutdown() }
        let humanID = try modelSession.createTab()
        let modelID = try modelSession.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        let model = try XCTUnwrap(modelSession.webView(for: modelID))
        try await loadPopupFixture(model)
        XCTAssertFalse(model.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        let modelRejected = try await script(model, "return window.open('about:blank', 'model-popup') === null;")
        XCTAssertEqual(modelRejected, Data("true".utf8))
        model.uiDelegate?.webViewDidClose?(model)
        XCTAssertEqual(modelSession.tabs.map(\.id), [humanID, modelID])
        XCTAssertEqual(modelSession.selectedTabID, humanID)
        XCTAssertTrue(modelSession.webView(for: modelID) === model)
    }

    private func loadPopupFixture(_ view: WKWebView) async throws {
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.loadHTMLString("<p id='ready'>Opener fixture</p><a id='blank-link' href='about:blank' target='_blank'>New tab</a>",
                            baseURL: URL(string: "https://popup.example.test/"))
        let deadline = ContinuousClock.now + .seconds(5)
        var ready = false
        while ContinuousClock.now < deadline {
            if !view.isLoading {
                ready = (try? await script(view, "return !!document.getElementById('ready');")) == Data("true".utf8)
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(ready)
    }

    private func waitForPopupCount(_ count: Int, session: EmbeddedBrowserSession) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while session.tabs.count != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(session.tabs.count, count, "Browser error: \(session.errorMessage ?? session.tabs.compactMap(\.error).first ?? "none")")
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

    func testFullDocumentGenerationChangesForNavigationButNotSPARoutes() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: id))
        let initial = session.documentGeneration(for: id)
        view.loadHTMLString("<p id='ready'>Ready</p>", baseURL: URL(string: "https://example.test/"))
        let deadline = ContinuousClock.now + .seconds(10)
        var loaded = false
        while ContinuousClock.now < deadline {
            if !view.isLoading, (try? await script(view, "return !!document.getElementById('ready');")) == Data("true".utf8) {
                loaded = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(loaded)
        let document = session.documentGeneration(for: id)
        XCTAssertNotEqual(initial, document)
        _ = try await script(view, "history.pushState({}, '', '/spa-route#fragment'); return true;")
        _ = try await script(view, "history.replaceState({}, '', '/another-route'); return true;")
        XCTAssertEqual(session.documentGeneration(for: id), document)
        XCTAssertEqual(view.url?.path, "/another-route")
        try session.navigate(tabID: id, to: XCTUnwrap(URL(string: "about:blank")))
        XCTAssertNotEqual(session.documentGeneration(for: id), document, "Native full navigation must invalidate before WebKit starts")
    }

    func testModelChangeRecordedBeforeWaitDoesNotLoseTheWakeup() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false)
        try session.installModelChangeSignal(tabID: id, ownerToken: UUID().uuidString,
                                             world: .world(name: "computa-model-test"))
        let before = try session.modelChangeRevision(for: id)
        // This is a native navigation signal; it arrives before the waiter is registered.
        session.stop(tabID: id)
        let after = try await session.waitForModelChange(tabID: id, after: before, until: .now + .seconds(5))
        XCTAssertGreaterThan(after, before)
        XCTAssertNotNil(session.webView(for: id))
    }

    func testModelNavigationDiagnosticsTrackActualProvisionalCommitAndFinish() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(session.webView(for: id))
        let initial = try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view))
        XCTAssertFalse(initial.generationCommitted)
        XCTAssertFalse(initial.generationFinished)
        XCTAssertFalse(initial.settled, "An idle unloaded view is not a finished document")
        let delegate = try XCTUnwrap(view.navigationDelegate)
        let observer = ModelNavigationDiagnosticFixture(delegate: delegate) {
            session.modelNavigationDiagnostic(tabID: id, view: view)
        }
        view.navigationDelegate = observer
        defer { view.navigationDelegate = delegate }
        view.loadHTMLString("<p>Local navigation diagnostic fixture</p>", baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while observer.finished == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let provisional = try XCTUnwrap(observer.provisional)
        XCTAssertTrue(provisional.navigationPending)
        XCTAssertFalse(provisional.generationCommitted)
        XCTAssertFalse(provisional.generationFinished)
        XCTAssertFalse(provisional.settled)
        let committed = try XCTUnwrap(observer.committed)
        XCTAssertTrue(committed.navigationPending)
        XCTAssertTrue(committed.generationCommitted)
        XCTAssertFalse(committed.generationFinished)
        XCTAssertFalse(committed.settled)
        let finished = try XCTUnwrap(observer.finished)
        XCTAssertFalse(finished.navigationPending)
        XCTAssertTrue(finished.generationCommitted)
        XCTAssertTrue(finished.generationFinished)
        XCTAssertFalse(finished.navigationError)
        XCTAssertTrue(try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view)).settled)
        XCTAssertTrue(session.humanTabs.isEmpty)
    }

    func testModelNavigationDiagnosticsRejectFailedOrUncommittedFinish() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(session.webView(for: id))
        let delegate = try XCTUnwrap(view.navigationDelegate)
        // Drive the real delegate with local WebKit navigation identities;
        // no asynchronous navigation callbacks can race this fixture.
        view.navigationDelegate = nil
        for committed in [false, true] {
            let navigation = try XCTUnwrap(view.loadHTMLString("<p>Local failure</p>", baseURL: nil))
            delegate.webView?(view, didStartProvisionalNavigation: navigation)
            if committed { delegate.webView?(view, didCommit: navigation) }
            let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                  userInfo: [NSLocalizedDescriptionKey: "PRIVATE_NAVIGATION_ERROR_CANARY"])
            if committed { delegate.webView?(view, didFail: navigation, withError: failure) }
            else { delegate.webView?(view, didFailProvisionalNavigation: navigation, withError: failure) }
            let result = try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view))
            XCTAssertEqual(result.generationCommitted, committed)
            XCTAssertFalse(result.generationFinished)
            XCTAssertTrue(result.navigationError, "Cancellation is not a successful finish")
            XCTAssertFalse(result.navigationPending)
            XCTAssertFalse(result.settled)
            XCTAssertFalse(result.logDescription.contains("PRIVATE_NAVIGATION_ERROR_CANARY"))
        }
        let uncommitted = try XCTUnwrap(view.loadHTMLString("<p>No commit callback</p>", baseURL: nil))
        delegate.webView?(view, didStartProvisionalNavigation: uncommitted)
        delegate.webView?(view, didFinish: uncommitted)
        let result = try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view))
        XCTAssertFalse(result.generationCommitted)
        XCTAssertFalse(result.generationFinished)
        XCTAssertFalse(result.navigationError)
        XCTAssertFalse(result.settled)
    }

    func testModelNavigationDiagnosticsResetAndIgnoreStaleCallbacks() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(session.webView(for: id))
        let delegate = try XCTUnwrap(view.navigationDelegate)
        view.navigationDelegate = nil
        let first = try XCTUnwrap(view.loadHTMLString("<p>First</p>", baseURL: nil))
        delegate.webView?(view, didStartProvisionalNavigation: first)
        delegate.webView?(view, didCommit: first)
        delegate.webView?(view, didFinish: first)
        XCTAssertTrue(try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view)).generationFinished)
        let oldGeneration = session.documentGeneration(for: id)
        try session.navigate(tabID: id, to: XCTUnwrap(URL(string: "about:blank")))
        XCTAssertNotEqual(session.documentGeneration(for: id), oldGeneration)
        let prepared = try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view))
        XCTAssertFalse(prepared.generationCommitted, "Reset occurs synchronously before didStart")
        XCTAssertFalse(prepared.generationFinished)
        delegate.webView?(view, didCommit: first)
        delegate.webView?(view, didFinish: first)
        XCTAssertEqual(session.modelNavigationDiagnostic(tabID: id, view: view), prepared)
        let second = try XCTUnwrap(view.loadHTMLString("<p>Second</p>", baseURL: nil))
        delegate.webView?(view, didStartProvisionalNavigation: second)
        let current = try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view))
        delegate.webView?(view, didCommit: first)
        delegate.webView?(view, didFail: first, withError: NSError(domain: NSURLErrorDomain, code: -1000))
        XCTAssertEqual(session.modelNavigationDiagnostic(tabID: id, view: view), current)
        delegate.webView?(view, didCommit: second)
        delegate.webView?(view, didFinish: second)
        XCTAssertTrue(try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view)).generationFinished)
        for terminate in [false, true] {
            if terminate { delegate.webViewWebContentProcessDidTerminate?(view) }
            else { session.stop(tabID: id) }
            delegate.webView?(view, didCommit: second)
            delegate.webView?(view, didFinish: second)
            let reset = try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view))
            XCTAssertFalse(reset.generationCommitted)
            XCTAssertFalse(reset.generationFinished)
            XCTAssertFalse(reset.navigationPending)
            XCTAssertFalse(reset.settled)
        }
    }

    func testModelNavigationDiagnosticsRequireExactPrivateViewAndContainOnlyFacts() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createUnloadedModelTabForTesting()
        let otherID = try session.createUnloadedModelTabForTesting()
        let humanID = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: id))
        let other = try XCTUnwrap(session.webView(for: otherID))
        let human = try XCTUnwrap(session.webView(for: humanID))
        XCTAssertNil(session.modelNavigationDiagnostic(tabID: id, view: other))
        XCTAssertNil(session.modelNavigationDiagnostic(tabID: humanID, view: human))
        XCTAssertNil(session.modelNavigationDiagnostic(tabID: UUID(), view: view))
        let facts = try XCTUnwrap(session.modelNavigationDiagnostic(tabID: id, view: view))
        XCTAssertEqual(facts.logDescription, "known=true viewLoading=false tabLoading=false navigationPending=false generationCommitted=false generationFinished=false navigationError=false settled=false geminiDocumentCommitObserved=false serverRedirectObservedInCurrentNavigation=false")
        XCTAssertEqual(EmbeddedBrowserSession.ModelNavigationDiagnostic.unknownLogDescription,
                       "known=false viewLoading=unknown tabLoading=unknown navigationPending=unknown generationCommitted=unknown generationFinished=unknown navigationError=unknown settled=unknown geminiDocumentCommitObserved=unknown serverRedirectObservedInCurrentNavigation=unknown")
        session.closeTab(id)
        XCTAssertNil(session.modelNavigationDiagnostic(tabID: id, view: view))
        XCTAssertNotNil(session.modelNavigationDiagnostic(tabID: otherID, view: other))
        session.shutdown()
        XCTAssertNil(session.modelNavigationDiagnostic(tabID: otherID, view: other))
    }

    func testModelRenderHostAttachesFixedViewportWithoutChangingHumanSelectionOrFocus() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 800),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { session.shutdown(); window.close() }
        let host = EmbeddedModelRenderContainer(session: session)
        host.frame = NSRect(x: 0, y: 0, width: 1_100, height: 800)
        window.contentView = host
        session.installModelRenderHost(host)
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        host.addSubview(input)
        XCTAssertTrue(window.makeFirstResponder(input))
        let keyWindow = NSApplication.shared.keyWindow
        let humanID = try session.createTab()
        let modelID = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        let model = try XCTUnwrap(session.webView(for: modelID))
        XCTAssertTrue(model.superview === host)
        XCTAssertTrue(model.window === window)
        XCTAssertFalse(model.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(model.frame.size, NSSize(width: 1_024, height: 768))
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertTrue(window.firstResponder === input)
        XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)
        XCTAssertNil(host.hitTest(NSPoint(x: 10, y: 10)))
        // Exercise the fixed adapter's actual focus path, rather than asking
        // NSWindow to perform an explicit native focus change the app never makes.
        model.loadHTMLString("<!doctype html><input id='model-editor'>", baseURL: URL(string: "https://chatgpt.com/"))
        let deadline = ContinuousClock.now + .seconds(10)
        var loaded = false
        while ContinuousClock.now < deadline {
            if !model.isLoading,
               (try? await script(model, "return !!document.getElementById('model-editor');")) == Data("true".utf8) {
                loaded = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(loaded)
        session.captureModelNativeFocus(tabID: modelID)
        let focused = try await script(model, "document.getElementById('model-editor').focus(); return document.activeElement === document.getElementById('model-editor');")
        XCTAssertEqual(focused, Data("true".utf8))
        // The DOM editor can focus without changing AppKit's human responder.
        await Task.yield()
        XCTAssertTrue(window.firstResponder === input)
        XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)
        session.installModelRenderHost(host)
        XCTAssertTrue(model.superview === host)
        XCTAssertTrue(window.firstResponder === input)
        session.closeTab(modelID)
        XCTAssertNil(model.superview)
        XCTAssertNil(model.window)
        XCTAssertEqual(session.tabs.map(\.id), [humanID])
        XCTAssertTrue(window.firstResponder === input)
    }

    func testModelPresentationIsRejectedAndKeepsExactViewInPrivateBackingHost() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let backing = EmbeddedModelRenderContainer(session: session)
        session.installModelRenderHost(backing)
        let human = try session.createTab()
        let id = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        let model = try XCTUnwrap(session.webView(for: id))
        let generation = session.documentGeneration(for: id)
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        let second = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 700))
        XCTAssertThrowsError(try session.presentTab(id, in: first)) {
            XCTAssertEqual($0 as? EmbeddedBrowserSession.Failure, .modelTabPrivate)
        }
        XCTAssertThrowsError(try session.presentTab(id, in: second)) {
            XCTAssertEqual($0 as? EmbeddedBrowserSession.Failure, .modelTabPrivate)
        }
        session.detachPresentedTab(id, from: first)
        session.detachPresentedTab(id, from: second)
        XCTAssertTrue(model.superview === backing)
        XCTAssertTrue(first.subviews.isEmpty)
        XCTAssertTrue(second.subviews.isEmpty)
        XCTAssertEqual(model.frame.size, NSSize(width: 1_024, height: 768))
        XCTAssertTrue(session.webView(for: id) === model)
        XCTAssertEqual(session.documentGeneration(for: id), generation)
        XCTAssertEqual(session.selectedTabID, human)
        XCTAssertNil(session.errorMessage, "Private presentation rejection cannot become a human Browser error")
        XCTAssertEqual(session.humanTabs.map(\.id), [human])
        session.detachPresentedTab(id, from: second)
        XCTAssertTrue(model.superview === backing)
    }

    func testModelDOMFocusAndNavigationPreserveNativeTextFieldEditorAndUnsentSelection() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 800),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { session.shutdown(); window.close() }
        let host = EmbeddedModelRenderContainer(session: session)
        host.frame = NSRect(x: 0, y: 0, width: 1_100, height: 800)
        window.contentView = host
        session.installModelRenderHost(host)
        let field = NSTextField(string: "UNSENT human address sentinel")
        field.frame = NSRect(x: 20, y: 20, width: 480, height: 24)
        field.isEditable = true
        field.isSelectable = true
        host.addSubview(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor, "Exercise the shared editor used by native text fields, not a standalone NSTextView")
        XCTAssertTrue(field.currentEditor() === editor)
        let selectedRange = NSRange(location: 7, length: 5)
        editor.setSelectedRange(selectedRange)
        let sentinel = editor.string
        let keyWindow = NSApplication.shared.keyWindow
        let humanID = try session.createTab()
        let modelID = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        let model = try XCTUnwrap(session.webView(for: modelID))

        for document in 0..<3 {
            session.captureModelNativeFocus(tabID: modelID)
            model.loadHTMLString("""
                <!doctype html><title>Field editor fixture \(document)</title>
                <textarea id="model-editor" autofocus></textarea>
                """, baseURL: URL(string: "https://chatgpt.com/"))
            let deadline = ContinuousClock.now + .seconds(10)
            var loaded = false
            while ContinuousClock.now < deadline {
                if !model.isLoading,
                   (try? await script(model, "return !!document.getElementById('model-editor');")) == Data("true".utf8) {
                    loaded = true; break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(loaded)
            session.captureModelNativeFocus(tabID: modelID)
            let domFocused = try await script(model, "document.getElementById('model-editor').focus(); return document.activeElement === document.getElementById('model-editor');")
            XCTAssertEqual(domFocused, Data("true".utf8))
            session.restoreModelNativeFocus(tabID: modelID)
            try await Task.sleep(for: .milliseconds(50))
            let activeEditor = try XCTUnwrap(window.firstResponder as? NSTextView,
                                             "Background DOM focus must preserve the native field's editing owner")
            XCTAssertTrue(activeEditor.isFieldEditor)
            XCTAssertTrue(field.currentEditor() === activeEditor)
            XCTAssertEqual(activeEditor.string, sentinel)
            XCTAssertEqual(field.stringValue, sentinel)
            XCTAssertEqual(activeEditor.selectedRange(), selectedRange)
            XCTAssertEqual(session.selectedTabID, humanID)
            XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)
        }
    }

    func testModelFocusRestorationPreservesHumanEditsAndSelectionMadeAfterCapture() async throws {
        let fixture = try await makeFieldEditorFocusFixture()
        defer { fixture.session.shutdown(); fixture.window.close() }
        let editor = try XCTUnwrap(fixture.field.currentEditor() as? NSTextView)
        fixture.session.captureModelNativeFocus(tabID: fixture.modelID)
        let latest = "LATEST human input after the asynchronous capture"
        editor.insertText(latest, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let selection = NSRange(location: 9, length: 8)
        editor.setSelectedRange(selection)
        try await focusModelEditor(fixture.model, session: fixture.session, tabID: fixture.modelID)
        let restored = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        XCTAssertTrue(restored.isFieldEditor)
        XCTAssertTrue(fixture.field.currentEditor() === restored)
        XCTAssertEqual(restored.string, latest, "A stale captured buffer cannot overwrite a newer human edit")
        XCTAssertEqual(restored.selectedRange(), selection)
    }

    func testModelFocusRestorationRespectsHumanSwitchToAnotherEditingControl() async throws {
        let fixture = try await makeFieldEditorFocusFixture()
        defer { fixture.session.shutdown(); fixture.window.close() }
        fixture.session.captureModelNativeFocus(tabID: fixture.modelID)
        let other = NSTextField(string: "Human intentionally selected another control")
        other.frame = NSRect(x: 20, y: 60, width: 480, height: 24)
        fixture.host.addSubview(other)
        other.selectText(nil)
        let otherEditor = try XCTUnwrap(other.currentEditor() as? NSTextView)
        let selection = NSRange(location: 6, length: 4)
        otherEditor.setSelectedRange(selection)
        fixture.session.restoreModelNativeFocus(tabID: fixture.modelID)
        XCTAssertTrue(fixture.window.firstResponder === otherEditor,
                      "A restoration request must respect an explicit newer human focus destination")
        // Complete the same asynchronous operation without taking a new native
        // focus receipt: the explicit human destination is the latest owner.
        try await focusModelEditor(fixture.model, session: fixture.session, tabID: fixture.modelID)
        let restored = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        XCTAssertTrue(other.currentEditor() === restored)
        XCTAssertNil(fixture.field.currentEditor())
        XCTAssertEqual(restored.string, other.stringValue)
        XCTAssertEqual(restored.selectedRange(), selection)
    }

    func testDetachedCapturedFieldCannotBeRestoredOrMovedIntoAnotherWindow() async throws {
        let fixture = try await makeFieldEditorFocusFixture()
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                                   styleMask: [], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let otherHost = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        otherWindow.contentView = otherHost
        defer { fixture.session.shutdown(); fixture.window.close(); otherWindow.close() }
        let keyWindow = NSApplication.shared.keyWindow
        fixture.session.captureModelNativeFocus(tabID: fixture.modelID)
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        fixture.field.removeFromSuperview()
        XCTAssertNil(fixture.field.window)
        try await focusModelEditor(fixture.model, session: fixture.session, tabID: fixture.modelID)
        XCTAssertNil(fixture.field.currentEditor(), "A detached original field is no longer an admissible focus destination")
        otherHost.addSubview(fixture.field)
        XCTAssertTrue(fixture.field.window === otherWindow)
        try await focusModelEditor(fixture.model, session: fixture.session, tabID: fixture.modelID)
        XCTAssertNil(fixture.field.currentEditor(), "An old focus receipt must not reenter a control now owned by another window")
        XCTAssertFalse(otherWindow.isVisible)
        XCTAssertFalse(otherWindow.isKeyWindow)
        XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)
    }

    func testSecureNativeFieldReentryPreservesItsBufferAndSelection() async throws {
        let fixture = try await makeFieldEditorFocusFixture(secure: true)
        defer { fixture.session.shutdown(); fixture.window.close() }
        XCTAssertTrue(fixture.field is NSSecureTextField)
        let editor = try XCTUnwrap(fixture.field.currentEditor() as? NSTextView)
        let expected = editor.string
        let selection = NSRange(location: 2, length: 3)
        editor.setSelectedRange(selection)
        fixture.session.captureModelNativeFocus(tabID: fixture.modelID)
        try await focusModelEditor(fixture.model, session: fixture.session, tabID: fixture.modelID)
        let restored = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        XCTAssertTrue(fixture.field.currentEditor() === restored)
        // Compare a synthetic fixture value without putting secure text in a
        // failure message or requesting a production plaintext snapshot.
        XCTAssertTrue(restored.string == expected, "The synthetic secure buffer must remain unchanged")
        XCTAssertEqual(restored.selectedRange(), selection)
    }

    private func makeFieldEditorFocusFixture(secure: Bool = false) async throws -> (
        session: EmbeddedBrowserSession, window: NSWindow, host: EmbeddedModelRenderContainer,
        field: NSTextField, modelID: UUID, model: WKWebView
    ) {
        let session = EmbeddedBrowserSession(persistent: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 800),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        do {
            let host = EmbeddedModelRenderContainer(session: session)
            host.frame = NSRect(x: 0, y: 0, width: 1_100, height: 800)
            window.contentView = host
            session.installModelRenderHost(host)
            let field: NSTextField = secure ? NSSecureTextField(string: "Synthetic secure fixture buffer")
                : NSTextField(string: "Original unsent human input")
            field.frame = NSRect(x: 20, y: 20, width: 480, height: 24)
            host.addSubview(field)
            let modelID = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
            let model = try XCTUnwrap(session.webView(for: modelID))
            model.loadHTMLString("<!doctype html><textarea id='model-editor'></textarea>",
                                 baseURL: URL(string: "https://chatgpt.com/"))
            let deadline = ContinuousClock.now + .seconds(10)
            var loaded = false
            while ContinuousClock.now < deadline {
                if !model.isLoading,
                   (try? await script(model, "return !!document.getElementById('model-editor');")) == Data("true".utf8) {
                    loaded = true; break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(loaded)
            field.selectText(nil)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            XCTAssertTrue(editor.isFieldEditor)
            XCTAssertTrue(window.firstResponder === editor)
            return (session, window, host, field, modelID, model)
        } catch {
            session.shutdown()
            window.close()
            throw error
        }
    }

    private func focusModelEditor(_ view: WKWebView, session: EmbeddedBrowserSession, tabID: UUID) async throws {
        let focused = try await script(view, "document.getElementById('model-editor').focus(); return document.activeElement === document.getElementById('model-editor');")
        XCTAssertEqual(focused, Data("true".utf8))
        session.restoreModelNativeFocus(tabID: tabID)
        try await Task.sleep(for: .milliseconds(50))
    }

    func testModelCreationSelectionNavigationFailureAndClosePreserveHumanError() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let humanID = try session.createTab()
        let humanView = try XCTUnwrap(session.webView(for: humanID))
        let rejectedURL = try XCTUnwrap(URL(string: "file:///tmp/computa-never-loaded.html"))
        XCTAssertThrowsError(try session.navigate(tabID: humanID, to: rejectedURL))
        let humanError = try XCTUnwrap(session.errorMessage)
        let humanDocument = session.documentGeneration(for: humanID)

        let modelID = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        let model = try XCTUnwrap(session.webView(for: modelID))
        XCTAssertEqual(session.humanTabs.map(\.id), [humanID])
        XCTAssertEqual(session.tabs.map(\.id), [humanID, modelID], "Private sessions remain internally owned until verified cleanup")
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertEqual(session.errorMessage, humanError)
        session.selectTab(modelID)
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertEqual(session.errorMessage, humanError)
        XCTAssertThrowsError(try session.presentTab(modelID, in: NSView())) {
            XCTAssertEqual($0 as? EmbeddedBrowserSession.Failure, .modelTabPrivate)
        }
        XCTAssertEqual(session.errorMessage, humanError)

        try session.navigate(tabID: modelID, to: XCTUnwrap(URL(string: "about:blank")))
        XCTAssertEqual(session.errorMessage, humanError, "Starting private navigation cannot clear the selected human's error")
        XCTAssertThrowsError(try session.navigate(tabID: modelID, to: rejectedURL))
        model.navigationDelegate?.webViewWebContentProcessDidTerminate?(model)
        XCTAssertEqual(session.errorMessage, humanError)
        XCTAssertEqual(session.humanTabs.first?.error, humanError)
        XCTAssertTrue(session.tabs.first(where: { $0.id == modelID })?.error?.contains("web content process stopped") == true)
        XCTAssertEqual(session.documentGeneration(for: humanID), humanDocument)
        XCTAssertTrue(session.webView(for: humanID) === humanView)
        XCTAssertNil(humanView.url)

        session.closeTab(modelID)
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertEqual(session.errorMessage, humanError)
        XCTAssertEqual(session.tabs.map(\.id), [humanID])
    }

    func testModelWorkPreservesHumanCreationErrorWithoutAttachingItToHumanTab() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let humanID = try session.createTab()
        let rejectedURL = try XCTUnwrap(URL(string: "file:///tmp/computa-never-loaded.html"))
        XCTAssertThrowsError(try session.createTab(url: rejectedURL))
        let humanError = try XCTUnwrap(session.errorMessage)
        XCTAssertNil(session.humanTabs.first?.error)
        let modelID = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        XCTAssertEqual(session.errorMessage, humanError)
        XCTAssertThrowsError(try session.createModelTab(url: rejectedURL))
        XCTAssertEqual(session.errorMessage, humanError)
        session.selectTab(modelID)
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertEqual(session.errorMessage, humanError)
        session.closeTab(modelID)
        XCTAssertEqual(session.errorMessage, humanError, "Cleanup of a private tab cannot dismiss a separate human action error")
        XCTAssertEqual(session.humanTabs.map(\.id), [humanID])
    }

    func testClosingHumanTabsNeverSelectsARetainedPrivateModelSession() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let first = try session.createTab()
        let model = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        let second = try session.createTab()
        session.selectTab(first)
        session.closeTab(first)
        XCTAssertEqual(session.selectedTabID, second, "Selection skips the private model tab between human tabs")
        session.closeTab(second)
        XCTAssertTrue(session.humanTabs.isEmpty)
        XCTAssertEqual(session.tabs.map(\.id), [model])
        XCTAssertNil(session.selectedTabID, "Retained inference cleanup must not expose its website in an empty Browser pane")
        XCTAssertNil(session.errorMessage)
        session.selectTab(model)
        XCTAssertNil(session.selectedTabID)
        XCTAssertNil(session.errorMessage)
        let replacement = try session.createTab()
        XCTAssertEqual(session.selectedTabID, replacement)
        XCTAssertEqual(session.humanTabs.map(\.id), [replacement])
        session.closeTab(model)
        XCTAssertEqual(session.selectedTabID, replacement)
    }

    func testModelRenderHostReplacementPreservesViewsAndShutdownRemovesThem() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let first = EmbeddedModelRenderContainer(session: session)
        let second = EmbeddedModelRenderContainer(session: session)
        session.installModelRenderHost(first)
        let id = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        let model = try XCTUnwrap(session.webView(for: id))
        session.installModelRenderHost(second)
        session.installModelRenderHost(first)
        session.installModelRenderHost(second)
        XCTAssertTrue(model.superview === first, "Other WindowGroup updates must preserve the designated live render host")
        first.detach()
        XCTAssertTrue(model.superview === second)
        second.detach()
        XCTAssertNil(model.superview)
        XCTAssertNotNil(session.webView(for: id), "Unmounting a workspace is not authority to destroy a model session")
        session.installModelRenderHost(second)
        XCTAssertTrue(model.superview === second)
        session.shutdown()
        XCTAssertNil(model.superview)
        XCTAssertTrue(second.subviews.isEmpty)
        XCTAssertNil(session.webView(for: id))
    }

    func testModelChangeWaitCancellationKeepsTheOwnedTab() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false)
        try session.installModelChangeSignal(tabID: id, ownerToken: UUID().uuidString,
                                             world: .world(name: "computa-model-test"))
        let revision = try session.modelChangeRevision(for: id)
        let waiter = Task { try await session.waitForModelChange(tabID: id, after: revision, until: .now + .seconds(30)) }
        await Task.yield()
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("A cancelled wait must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNotNil(session.webView(for: id))
        XCTAssertEqual(try session.modelChangeRevision(for: id), revision)
    }

    func testModelChangeWaitDeadlineAndTabClosureAreDistinct() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false)
        try session.installModelChangeSignal(tabID: id, ownerToken: UUID().uuidString,
                                             world: .world(name: "computa-model-test"))
        let revision = try session.modelChangeRevision(for: id)
        let unchanged = try await session.waitForModelChange(tabID: id, after: revision, until: .now + .milliseconds(25))
        XCTAssertEqual(unchanged, revision, "Only the deadline elapsed; no page change was reported")
        let waiter = Task { try await session.waitForModelChange(tabID: id, after: revision, until: .now + .seconds(30)) }
        await Task.yield()
        session.closeTab(id)
        do { _ = try await waiter.value; XCTFail("Closing the owned tab must wake its waiter") }
        catch { XCTAssertEqual(error as? EmbeddedBrowserSession.Failure, .tabClosed) }
    }

    func testNativeChannelDeadlineCannotInventChangeOrConsumeTheNextWaiter() async throws {
        let channel = EmbeddedModelChangeChannel(ownerToken: UUID().uuidString)
        defer { channel.close() }
        let before = try channel.currentRevision()
        let deadline = ContinuousClock.now + .milliseconds(50)
        let expired = try await channel.wait(after: before, until: deadline)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now, deadline, "A deadline-only wake must never return early")
        XCTAssertEqual(expired, before, "Timer expiry is not a page mutation")
        XCTAssertEqual(try channel.currentRevision(), before)
        let alreadyExpired = try await channel.wait(after: before, until: deadline)
        XCTAssertEqual(alreadyExpired, before)

        let next = Task { try await channel.wait(after: before, until: .now + .seconds(5)) }
        await Task.yield()
        channel.signal()
        let nextRevision = try await next.value
        XCTAssertEqual(nextRevision, before + 1, "An expired wait cannot consume a subsequent real signal")
        XCTAssertEqual(try channel.currentRevision(), before + 1)

        let cancelled = Task { try await channel.wait(after: before + 1, until: .now + .seconds(5)) }
        await Task.yield()
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation must terminate its own waiter") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try channel.currentRevision(), before + 1, "Cancelling a waiter must not invent a mutation")

        let afterCancellation = Task { try await channel.wait(after: before + 1, until: .now + .seconds(5)) }
        await Task.yield()
        channel.signal()
        let afterCancellationRevision = try await afterCancellation.value
        XCTAssertEqual(afterCancellationRevision, before + 2,
                       "A cancelled waiter must be removed and resumed only once")
        XCTAssertEqual(try channel.currentRevision(), before + 2)
    }

    func testNativeDOMSignalBatchingDoesNotDependOnWebsiteTimers() async throws {
        let channel = EmbeddedModelChangeChannel(ownerToken: UUID().uuidString)
        let before = try channel.currentRevision()
        for _ in 0..<500 { channel.signalDOMChange() }
        let first = try await channel.wait(after: before, until: .now + .seconds(2))
        XCTAssertEqual(first, before + 1, "A burst produces one native wake")
        let settled = try await channel.wait(after: first, until: .now + .milliseconds(150))
        XCTAssertEqual(settled, first, "The native timer is one-shot, never recurring polling")
        for _ in 0..<500 { channel.signalDOMChange() }
        let second = try await channel.wait(after: first, until: .now + .seconds(2))
        XCTAssertEqual(second, first + 1, "A later actual change starts a fresh batch")
        channel.close()
    }

    func testNativeNavigationSignalBypassesPendingDOMBatch() async throws {
        let channel = EmbeddedModelChangeChannel(ownerToken: UUID().uuidString)
        defer { channel.close() }
        channel.signalDOMChange()
        channel.signal()
        XCTAssertEqual(try channel.currentRevision(), 1, "Native navigation/profile changes wake synchronously")
        let after = try await channel.wait(after: 1, until: .now + .seconds(2))
        XCTAssertEqual(after, 2)
    }

    func testClosingNativeChannelCancelsDOMBatchAndResumesWaiterOnce() async throws {
        let channel = EmbeddedModelChangeChannel(ownerToken: UUID().uuidString)
        let waiting = Task { try await channel.wait(after: 0, until: .now + .seconds(2)) }
        await Task.yield()
        channel.signalDOMChange()
        channel.close()
        do { _ = try await waiting.value; XCTFail("Closed channel must reject the pending read") }
        catch { XCTAssertEqual(error as? EmbeddedBrowserSession.Failure, .tabClosed) }
        channel.signalDOMChange()
        channel.signal()
        XCTAssertThrowsError(try channel.currentRevision())
    }

    func testModelNotificationHandlerIsPrivateAndAcceptsOnlyItsExactReceipt() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false)
        let humanID = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: id))
        let humanView = try XCTUnwrap(session.webView(for: humanID))
        let token = UUID().uuidString
        let world = WKContentWorld.world(name: "computa-model-test")
        try session.installModelChangeSignal(tabID: id, ownerToken: token, world: world)
        view.loadHTMLString("<p id='ready'>Ready</p>", baseURL: URL(string: "https://chatgpt.com/?temporary-chat=true"))
        let deadline = ContinuousClock.now + .seconds(10)
        var loaded = false
        while ContinuousClock.now < deadline {
            if !view.isLoading, (try? await script(view, "return !!document.getElementById('ready');")) == Data("true".utf8) {
                loaded = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(loaded)
        let hidden = "return !window.webkit?.messageHandlers?.computaChatGPTSignal;"
        let pageHidden = try await script(view, hidden)
        let humanHidden = try await script(humanView, hidden, world: world)
        XCTAssertEqual(pageHidden, Data("true".utf8), "The website page world receives no native handler")
        XCTAssertEqual(humanHidden, Data("true".utf8), "Human tabs receive no model handler")
        // Drain earlier native load/KVO callbacks before recording this receipt.
        await Task.yield()
        let before = try session.modelChangeRevision(for: id)
        let invalid = "window.webkit.messageHandlers.computaChatGPTSignal.postMessage({ownerToken: '\(UUID().uuidString)', kind: 'dom_changed'}); window.webkit.messageHandlers.computaChatGPTSignal.postMessage({ownerToken: '\(token)', kind: 'dom_changed', text: 'not allowed'}); return true;"
        _ = try await script(view, invalid, world: world)
        let ignored = try await session.waitForModelChange(tabID: id, after: before, until: .now + .milliseconds(100))
        XCTAssertEqual(ignored, before)
        _ = try await script(view, "window.webkit.messageHandlers.computaChatGPTSignal.postMessage({ownerToken: '\(token)', kind: 'dom_changed'}); return true;", world: world)
        let after = try await session.waitForModelChange(tabID: id, after: before, until: .now + .seconds(2))
        XCTAssertGreaterThan(after, before)
    }

    func testModelNotificationsPinClaudeAndGeminiOriginsRatherThanTrustingAnotherProvider() async throws {
        for host in ["claude.ai", "gemini.google.com"] {
            let session = EmbeddedBrowserSession(persistent: false)
            defer { session.shutdown() }
            let id = try session.createTab(select: false)
            let view = try XCTUnwrap(session.webView(for: id))
            let token = UUID().uuidString
            let world = WKContentWorld.world(name: "computa-origin-test-\(host)")
            try session.installModelChangeSignal(tabID: id, ownerToken: token, world: world, originHost: host)
            let receipt = "window.webkit.messageHandlers.computaChatGPTSignal.postMessage({ownerToken: '\(token)', kind: 'dom_changed'}); return true;"
            for origin in [host, "chatgpt.com"] {
                view.loadHTMLString("<p id='ready'>Ready</p>", baseURL: URL(string: "https://\(origin)/"))
                let deadline = ContinuousClock.now + .seconds(10)
                var loaded = false
                while ContinuousClock.now < deadline {
                    if !view.isLoading, (try? await script(view, "return document.getElementById('ready')?.textContent;")) == Data("\"Ready\"".utf8) {
                        loaded = true; break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(loaded)
                // Let native navigation/KVO signals settle; only the fixed
                // private-world DOM receipt is under test below.
                try await Task.sleep(for: .milliseconds(150))
                let before = try session.modelChangeRevision(for: id)
                _ = try await script(view, receipt, world: world)
                let after = try await session.waitForModelChange(tabID: id, after: before, until: .now + .milliseconds(150))
                if origin == host { XCTAssertGreaterThan(after, before) }
                else { XCTAssertEqual(after, before, "Another supported provider cannot wake this provider's session") }
            }
        }
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false)
        XCTAssertThrowsError(try session.installModelChangeSignal(tabID: id, ownerToken: UUID().uuidString,
                                                                 world: .world(name: "invalid-origin"), originHost: "example.com"))
        XCTAssertThrowsError(try session.modelChangeRevision(for: id), "An unsupported origin must not install a channel")
    }

    func testModelDiagnosticsRejectForeignAndLateReceiptsWithoutWakingTheChannel() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false)
        let human = try XCTUnwrap(session.webView(for: session.createTab()))
        let view = try XCTUnwrap(session.webView(for: id))
        let owner = UUID().uuidString, operation = UUID()
        let world = WKContentWorld.world(name: "computa-diagnostic-test")
        try session.installModelChangeSignal(tabID: id, ownerToken: owner, world: world)
        try await loadDiagnosticFixture(view, host: "chatgpt.com")
        try session.beginModelDiagnostic(tabID: id, ownerToken: owner, operationID: operation)
        let hidden = "return !window.webkit?.messageHandlers?.computaModelDiagnostic;"
        let pageHidden = try await script(view, hidden)
        let humanHidden = try await script(human, hidden, world: world)
        XCTAssertEqual(pageHidden, Data("true".utf8))
        XCTAssertEqual(humanHidden, Data("true".utf8))
        let revision = try session.modelChangeRevision(for: id)
        let invalid = """
        const handler = window.webkit.messageHandlers.computaModelDiagnostic;
        const valid = {ownerToken: '\(owner)', operationID: '\(operation.uuidString)', phase: 'first_user_hash'};
        for (const body of [{...valid, ownerToken: '\(UUID().uuidString)'},
          {...valid, operationID: '\(UUID().uuidString)'}, {...valid, phase: 'PRIVATE_RAW_PAGE_CANARY'},
          {...valid, text: 'PRIVATE_RAW_PAGE_CANARY'}, {...valid, operationID: null},
          {ownerToken: valid.ownerToken, phase: valid.phase}]) handler.postMessage(body);
        return true;
        """
        _ = try await script(view, invalid, world: world)
        let rejected = session.modelDiagnosticSnapshot(tabID: id)
        XCTAssertTrue(rejected.contains("phases=not_started"))
        XCTAssertTrue(rejected.contains("diagnosticsReceived=6 diagnosticsAccepted=0 diagnosticRejected=payload"))
        XCTAssertTrue(rejected.contains("generationCurrent=true originCurrent=true"))
        let receipt = "window.webkit.messageHandlers.computaModelDiagnostic.postMessage({ownerToken: '\(owner)', operationID: '\(operation.uuidString)', phase: 'first_user_hash'}); return true;"
        _ = try await script(view, receipt, world: world)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("phases=first_user_hash"))
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("diagnosticsReceived=7 diagnosticsAccepted=1"))
        let after = try await session.waitForModelChange(tabID: id, after: revision, until: .now + .milliseconds(100))
        XCTAssertEqual(after, revision, "Diagnostics cannot wake an inference or authorize an action")
        session.endModelDiagnostic(tabID: id, operationID: UUID())
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("active=true"))
        let next = UUID()
        try session.beginModelDiagnostic(tabID: id, ownerToken: owner, operationID: next)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("diagnosticsReceived=0 diagnosticsAccepted=0 diagnosticRejected=none"))
        XCTAssertEqual(session.modelDiagnosticSnapshot(tabID: id, operationID: operation), "state=superseded")
        session.endModelDiagnostic(tabID: id, operationID: operation)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("active=true"), "Ending an older operation cannot cancel the newer diagnostic")
        _ = try await script(view, receipt, world: world)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("phases=not_started"), "A late callback cannot contaminate the next operation")
        let nextReceipt = receipt.replacingOccurrences(of: operation.uuidString, with: next.uuidString)
        let childFixture = DiagnosticChildFrameFixture()
        view.configuration.userContentController.add(childFixture, name: "fixtureFrame")
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "fixtureFrame") }
        // The production delegate must load the frame while its independent
        // native message handler continues to reject child-frame authority.
        let navigationDelegate = view.navigationDelegate
        _ = try await script(view, "const frame = document.createElement('iframe'); frame.srcdoc = '<script>window.webkit.messageHandlers.fixtureFrame.postMessage(\"ready\")<\\/script>'; document.body.appendChild(frame); return true;")
        let childDeadline = ContinuousClock.now + .seconds(5)
        while childFixture.frame == nil, ContinuousClock.now < childDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let frame = try XCTUnwrap(childFixture.frame, "The controlled child frame must actually load")
        XCTAssertNil(session.tabs.first(where: { $0.id == id })?.error)
        _ = try await script(view, nextReceipt, world: world, frame: frame)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("phases=not_started"), "A same-origin child frame has no diagnostic authority")
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("diagnosticRejected=frame"))
        view.navigationDelegate = navigationDelegate
        view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view)
        _ = try await script(view, nextReceipt, world: world)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("phases=not_started"), "A changed generation invalidates the diagnostic operation")
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("generationCurrent=false originCurrent=true"))
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("diagnosticRejected=generation"))
        session.closeTab(id)
        XCTAssertEqual(session.modelDiagnosticSnapshot(tabID: id), "state=closed")
    }

    func testModelDiagnosticsPinOriginsAndBoundPhaseHistoryAndNativeGeometry() async throws {
        for host in ["chatgpt.com", "claude.ai", "gemini.google.com"] {
            let session = EmbeddedBrowserSession(persistent: false)
            defer { session.shutdown() }
            let id = try session.createTab(select: false)
            let view = try XCTUnwrap(session.webView(for: id))
            let owner = UUID().uuidString, world = WKContentWorld.world(name: "computa-diagnostic-\(host)")
            try session.installModelChangeSignal(tabID: id, ownerToken: owner, world: world, originHost: host)
            for origin in [host, "foreign.example.test"] {
                try await loadDiagnosticFixture(view, host: origin)
                let operation = UUID()
                try session.beginModelDiagnostic(tabID: id, ownerToken: owner, operationID: operation)
                let phases = EmbeddedBrowserSession.ModelAdapterPhase.allCases.map(\.rawValue)
                let encoded = try String(decoding: JSONSerialization.data(withJSONObject: phases), as: UTF8.self)
                _ = try await script(view, "for (const phase of \(encoded)) window.webkit.messageHandlers.computaModelDiagnostic.postMessage({ownerToken: '\(owner)', operationID: '\(operation.uuidString)', phase}); return true;", world: world)
                let snapshot = session.modelDiagnosticSnapshot(tabID: id)
                if origin == host {
                    XCTAssertTrue(snapshot.contains("phases=" + phases.suffix(8).joined(separator: ",")))
                    XCTAssertFalse(snapshot.contains("adapter_entry"))
                    XCTAssertTrue(snapshot.contains("diagnosticsReceived=9 diagnosticsAccepted=9 diagnosticRejected=none"))
                } else {
                    XCTAssertTrue(snapshot.contains("phases=not_started"))
                    XCTAssertTrue(snapshot.contains("diagnosticsReceived=9 diagnosticsAccepted=0 diagnosticRejected=origin"))
                    XCTAssertTrue(snapshot.contains("originCurrent=false"))
                }
                XCTAssertLessThan(snapshot.utf8.count, 1_024)
                XCTAssertFalse(snapshot.contains(host))
                XCTAssertFalse(snapshot.contains(owner))
                XCTAssertFalse(snapshot.contains(operation.uuidString))
                XCTAssertFalse(snapshot.contains("PRIVATE_RAW_PAGE_CANARY"))
                session.endModelDiagnostic(tabID: id, operationID: operation)
            }
        }
    }

    func testModelClockUsesNativeDeadlineWhenWebsiteTimersNeverRun() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false), owner = UUID().uuidString, operation = UUID()
        let view = try XCTUnwrap(session.webView(for: id)), world = WKContentWorld.world(name: "computa-clock-test")
        try session.installModelChangeSignal(tabID: id, ownerToken: owner, world: world)
        try await loadDiagnosticFixture(view, host: "chatgpt.com")
        try session.beginModelDiagnostic(tabID: id, ownerToken: owner, operationID: operation)
        let hidden = try await script(view, "return !window.webkit?.messageHandlers?.computaModelClock;")
        XCTAssertEqual(hidden, Data("true".utf8), "The page world has no clock handler")
        _ = try await script(view, "window.webkit.messageHandlers.computaModelDiagnostic.postMessage({ownerToken: '\(owner)', operationID: '\(operation.uuidString)', phase: 'model_wait'}); globalThis.setTimeout = () => { throw new Error('website timer must not run'); }; return true;", world: world)
        let revision = try session.modelChangeRevision(for: id), began = ContinuousClock.now
        let elapsed = try await script(view, "return await window.webkit.messageHandlers.computaModelClock.postMessage({ownerToken: '\(owner)', operationID: '\(operation.uuidString)', milliseconds: 100});", world: world)
        XCTAssertEqual(elapsed, Data("true".utf8))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(80))
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
        XCTAssertEqual(try session.modelChangeRevision(for: id), revision)
        let snapshot = session.modelDiagnosticSnapshot(tabID: id)
        let ageField = try XCTUnwrap(snapshot.split(separator: " ").first { $0.hasPrefix("phaseAgeMs=") })
        let age = try XCTUnwrap(Int(ageField.dropFirst("phaseAgeMs=".count)))
        XCTAssertGreaterThanOrEqual(age, 80)
        XCTAssertLessThanOrEqual(age, 45_000)
        XCTAssertTrue(snapshot.contains("clocksPending=0"))
        XCTAssertFalse(snapshot.contains(owner))
        XCTAssertFalse(snapshot.contains("PRIVATE_RAW_PAGE_CANARY"))
        session.endModelDiagnostic(tabID: id, operationID: operation)
    }

    func testModelClockRejectsInvalidReceiptsAndCancelsExactlyOnceOnSupersedeAndClose() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false), owner = UUID().uuidString, operation = UUID()
        let view = try XCTUnwrap(session.webView(for: id)), world = WKContentWorld.world(name: "computa-clock-scope-test")
        try session.installModelChangeSignal(tabID: id, ownerToken: owner, world: world)
        try await loadDiagnosticFixture(view, host: "chatgpt.com")
        try session.beginModelDiagnostic(tabID: id, ownerToken: owner, operationID: operation)
        let invalid = """
        const valid = {ownerToken: '\(owner)', operationID: '\(operation.uuidString)', milliseconds: 100};
        const bodies = [-1, 0, 0.5, 10001, true, '100', null].map(milliseconds => ({...valid, milliseconds}));
        bodies.push({...valid, ownerToken: '\(UUID().uuidString)'}, {...valid, operationID: '\(UUID().uuidString)'},
          {...valid, pageText: 'PRIVATE_RAW_PAGE_CANARY'}, {ownerToken: valid.ownerToken, operationID: valid.operationID});
        let rejected = 0;
        for (const body of bodies) {
          try { await window.webkit.messageHandlers.computaModelClock.postMessage(body); }
          catch (error) { if(error.message === 'model_clock_rejected') rejected++; }
        }
        return rejected === bodies.length;
        """
        let invalidRejected = try await script(view, invalid, world: world)
        XCTAssertEqual(invalidRejected, Data("true".utf8))
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("clocksPending=0"))
        _ = try await script(view, "globalThis.clockReplies = 0; for(let index = 0; index < 33; index++) window.webkit.messageHandlers.computaModelClock.postMessage({ownerToken: '\(owner)', operationID: '\(operation.uuidString)', milliseconds: 5000}).then(() => globalThis.clockReplies++, () => globalThis.clockReplies++); return true;", world: world)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("clocksPending=32"), "Pending native clocks are bounded")
        let next = UUID()
        try session.beginModelDiagnostic(tabID: id, ownerToken: owner, operationID: next)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("clocksPending=0"))
        let superseded = try await script(view, "return globalThis.clockReplies;", world: world)
        XCTAssertEqual(superseded, Data("33".utf8))
        _ = try await script(view, "window.webkit.messageHandlers.computaModelClock.postMessage({ownerToken: '\(owner)', operationID: '\(next.uuidString)', milliseconds: 5000}).then(() => globalThis.clockReplies++, () => globalThis.clockReplies++); return true;", world: world)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("clocksPending=1"))
        session.closeTab(id)
        let closed = try await script(view, "return globalThis.clockReplies;", world: world)
        XCTAssertEqual(closed, Data("34".utf8))
        XCTAssertEqual(session.modelDiagnosticSnapshot(tabID: id), "state=closed")
    }

    func testModelClockPinsProviderMainFrameAndDocumentGeneration() async throws {
        for host in ["chatgpt.com", "claude.ai", "gemini.google.com"] {
            let session = EmbeddedBrowserSession(persistent: false)
            defer { session.shutdown() }
            let id = try session.createTab(select: false), owner = UUID().uuidString
            let view = try XCTUnwrap(session.webView(for: id)), world = WKContentWorld.world(name: "computa-clock-origin-\(host)")
            try session.installModelChangeSignal(tabID: id, ownerToken: owner, world: world, originHost: host)
            for origin in [host, "foreign.example.test"] {
                try await loadDiagnosticFixture(view, host: origin)
                let operation = UUID()
                try session.beginModelDiagnostic(tabID: id, ownerToken: owner, operationID: operation)
                let receipt = "try { await window.webkit.messageHandlers.computaModelClock.postMessage({ownerToken: '\(owner)', operationID: '\(operation.uuidString)', milliseconds: 1}); return 'expired'; } catch(error) { return error.message; }"
                let result = try await script(view, receipt, world: world)
                XCTAssertEqual(result, Data("\"\(origin == host ? "expired" : "model_clock_rejected")\"".utf8))
                session.endModelDiagnostic(tabID: id, operationID: operation)
            }
        }
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab(select: false), owner = UUID().uuidString, operation = UUID()
        let view = try XCTUnwrap(session.webView(for: id)), world = WKContentWorld.world(name: "computa-clock-frame-test")
        let human = try XCTUnwrap(session.webView(for: session.createTab()))
        try session.installModelChangeSignal(tabID: id, ownerToken: owner, world: world)
        let humanHidden = try await script(human, "return !window.webkit?.messageHandlers?.computaModelClock;", world: world)
        XCTAssertEqual(humanHidden, Data("true".utf8))
        try await loadDiagnosticFixture(view, host: "chatgpt.com")
        try session.beginModelDiagnostic(tabID: id, ownerToken: owner, operationID: operation)
        let receipt = "try { await window.webkit.messageHandlers.computaModelClock.postMessage({ownerToken: '\(owner)', operationID: '\(operation.uuidString)', milliseconds: 100}); return 'expired'; } catch(error) { return error.message; }"
        let childFixture = DiagnosticChildFrameFixture()
        view.configuration.userContentController.add(childFixture, name: "fixtureFrame")
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "fixtureFrame") }
        let navigationDelegate = view.navigationDelegate
        _ = try await script(view, "const frame = document.createElement('iframe'); frame.srcdoc = '<script>window.webkit.messageHandlers.fixtureFrame.postMessage(\"ready\")<\\/script>'; document.body.appendChild(frame); return true;")
        let deadline = ContinuousClock.now + .seconds(5)
        while childFixture.frame == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let frame = try XCTUnwrap(childFixture.frame)
        XCTAssertNil(session.tabs.first(where: { $0.id == id })?.error)
        let childResult = try await script(view, receipt, world: world, frame: frame)
        XCTAssertEqual(childResult, Data("\"model_clock_rejected\"".utf8))
        _ = try await script(view, "globalThis.clockResult = null; window.webkit.messageHandlers.computaModelClock.postMessage({ownerToken: '\(owner)', operationID: '\(operation.uuidString)', milliseconds: 100}).then(() => globalThis.clockResult = 'expired', error => globalThis.clockResult = error.message); return true;", world: world)
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("clocksPending=1"))
        view.navigationDelegate = navigationDelegate
        view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view)
        try await Task.sleep(for: .milliseconds(150))
        let staleReply = try await script(view, "return globalThis.clockResult;", world: world)
        XCTAssertEqual(staleReply, Data("\"model_clock_cancelled\"".utf8))
        let staleReceipt = try await script(view, receipt, world: world)
        XCTAssertEqual(staleReceipt, Data("\"model_clock_rejected\"".utf8))
        XCTAssertTrue(session.modelDiagnosticSnapshot(tabID: id).contains("clocksPending=0"))
    }

    private func loadDiagnosticFixture(_ view: WKWebView, host: String) async throws {
        view.loadHTMLString("<p id='ready'>PRIVATE_RAW_PAGE_CANARY</p>", baseURL: URL(string: "https://\(host)/"))
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !view.isLoading, (try? await script(view, "return !!document.getElementById('ready');")) == Data("true".utf8) {
                try await Task.sleep(for: .milliseconds(150))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The local diagnostic fixture did not load")
    }

    private func script(_ view: WKWebView, _ body: String, world: WKContentWorld = .page, frame: WKFrameInfo? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: [:], in: frame, in: world) { result in
                switch result {
                case .success(let value):
                    do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) }
                    catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
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

    func testSrcdocNavigationRequiresSubframeWithinValidWebDocument() throws {
        let srcdoc = try XCTUnwrap(URL(string: "about:srcdoc"))
        for parent in ["https://example.test/", "http://localhost:5181/"] {
            let document = try XCTUnwrap(URL(string: parent))
            XCTAssertNoThrow(try EmbeddedBrowserURLPolicy.validateNavigation(srcdoc, isMainFrame: false, mainDocumentURL: document))
            XCTAssertThrowsError(try EmbeddedBrowserURLPolicy.validateNavigation(srcdoc, isMainFrame: true, mainDocumentURL: document))
        }
        for parent in [nil, "about:blank", "file:///tmp/page.html", "https://user:secret@example.test/", "https://example.test:70000/"] as [String?] {
            XCTAssertThrowsError(try EmbeddedBrowserURLPolicy.validateNavigation(srcdoc, isMainFrame: false, mainDocumentURL: parent.flatMap(URL.init(string:))))
        }
        XCTAssertThrowsError(try EmbeddedBrowserURLPolicy.validate(srcdoc))
        XCTAssertThrowsError(try EmbeddedBrowserURLPolicy.normalize("about:srcdoc"))
        for address in ["about:srcdoc#other", "about:config", "file:///tmp/page.html", "javascript:alert(1)", "data:text/html,hello", "custom:page"] {
            XCTAssertThrowsError(try EmbeddedBrowserURLPolicy.validateNavigation(XCTUnwrap(URL(string: address)), isMainFrame: false, mainDocumentURL: URL(string: "https://example.test/")))
        }
        XCTAssertNoThrow(try EmbeddedBrowserURLPolicy.validateNavigation(XCTUnwrap(URL(string: "https://example.test/path")), isMainFrame: true, mainDocumentURL: nil))
    }

    func testNavigationRejectionDiagnosticsNeverIncludePageOrCredentialData() {
        let inputs = ["about:srcdoc": "about_srcdoc", "about:blank": "about_blank", "about:config": "about_other",
                      "blob:https://example.com/private-identifier": "blob", "data:text/html,private-content": "data",
                      "file:///private/name": "file", "javascript:secret()": "javascript",
                      "https://user:password@example.com/private?token=secret": "https", "custom:secret": "other"]
        XCTAssertEqual(EmbeddedBrowserURLPolicy.diagnosticAddressKind(nil), "missing")
        for (input, expected) in inputs {
            XCTAssertEqual(EmbeddedBrowserURLPolicy.diagnosticAddressKind(URL(string: input)), expected)
        }
    }

    func testWebsiteNavigationDoesNotUseSearchFallback() throws {
        for input in ["javascript:alert(1)", "file:///tmp/test", "data:text/html,x", "custom:search"] {
            XCTAssertThrowsError(try EmbeddedBrowserURLPolicy.validate(XCTUnwrap(URL(string: input))), input)
        }
    }
}

@MainActor
private final class ModelNavigationDiagnosticFixture: NSObject, WKNavigationDelegate {
    let delegate: any WKNavigationDelegate
    let snapshot: () -> EmbeddedBrowserSession.ModelNavigationDiagnostic?
    var provisional: EmbeddedBrowserSession.ModelNavigationDiagnostic?
    var committed: EmbeddedBrowserSession.ModelNavigationDiagnostic?
    var finished: EmbeddedBrowserSession.ModelNavigationDiagnostic?

    init(delegate: any WKNavigationDelegate, snapshot: @escaping () -> EmbeddedBrowserSession.ModelNavigationDiagnostic?) {
        self.delegate = delegate
        self.snapshot = snapshot
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        delegate.webView?(webView, didStartProvisionalNavigation: navigation)
        provisional = snapshot()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        delegate.webView?(webView, didCommit: navigation)
        committed = snapshot()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate.webView?(webView, didFinish: navigation)
        finished = snapshot()
    }
}

@MainActor
private final class DiagnosticChildFrameFixture: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if !message.frameInfo.isMainFrame, message.body as? String == "ready" { frame = message.frameInfo }
    }
}

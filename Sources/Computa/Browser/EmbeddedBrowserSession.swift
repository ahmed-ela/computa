import AppKit
import Foundation
import Observation
import WebKit

@MainActor @Observable
final class EmbeddedBrowserTab: Identifiable {
    let id: UUID
    fileprivate(set) var title = "New tab"
    fileprivate(set) var url: URL?
    fileprivate(set) var isLoading = false
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false
    fileprivate(set) var documentID = UUID()
    fileprivate(set) var error: String?

    fileprivate init(id: UUID = UUID()) { self.id = id }
}

/// Browser views are independent of the privileged Octane UI WebView and Chrome.
/// The view host may detach a view when hidden; only close/shutdown destroys its session.
@MainActor @Observable
final class EmbeddedBrowserSession {
    enum Failure: Error, LocalizedError, Equatable {
        case tabLimit(Int)
        case tabClosed
        case sessionClosed

        var errorDescription: String? {
            switch self {
            case .tabLimit(let limit): "This browser allows up to \(limit) tabs. Close a tab before opening another."
            case .tabClosed: "That browser tab is no longer open."
            case .sessionClosed: "This browser session has ended."
            }
        }
    }

    private(set) var tabs: [EmbeddedBrowserTab] = []
    private(set) var selectedTabID: UUID?
    private(set) var errorMessage: String?
    let maximumTabs: Int

    @ObservationIgnored private var websiteDataStore: WKWebsiteDataStore?
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private let profileID: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var isShutdown = false
    static let profileDefaultsKey = "Computa.EmbeddedBrowser.ProfileIdentifier.v1"

    private final class Entry {
        let tab: EmbeddedBrowserTab
        let view: WKWebView
        let delegate: EmbeddedBrowserDelegate
        var observations: [NSKeyValueObservation] = []
        var navigation: WKNavigation?

        init(tab: EmbeddedBrowserTab, view: WKWebView, delegate: EmbeddedBrowserDelegate) {
            self.tab = tab
            self.view = view
            self.delegate = delegate
        }
    }

    /// `persistent: false` makes an isolated, nonpersistent test/private session.
    /// An explicit profile ID avoids reading or writing the production preference in tests.
    init(persistent: Bool = true, maximumTabs: Int = 8, profileID: UUID? = nil, defaults: UserDefaults = .standard) {
        self.maximumTabs = max(1, min(maximumTabs, 32))
        self.persistent = persistent
        self.profileID = profileID
        self.defaults = defaults
    }

    private func dataStore() -> WKWebsiteDataStore {
        if let websiteDataStore { return websiteDataStore }
        let store: WKWebsiteDataStore
        if persistent {
            let identifier: UUID
            if let profileID {
                identifier = profileID
            } else if let existing = defaults.string(forKey: Self.profileDefaultsKey).flatMap(UUID.init(uuidString:)) {
                identifier = existing
            } else {
                identifier = UUID()
                defaults.set(identifier.uuidString, forKey: Self.profileDefaultsKey)
            }
            store = WKWebsiteDataStore(forIdentifier: identifier)
        } else {
            store = .nonPersistent()
        }
        websiteDataStore = store
        return store
    }

    @discardableResult
    func createTab(url: URL? = nil, select: Bool = true) throws -> UUID {
        do {
            guard !isShutdown else { throw Failure.sessionClosed }
            guard tabs.count < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
            if let url { try EmbeddedBrowserURLPolicy.validate(url) }

            let tab = EmbeddedBrowserTab()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore()
            // This fresh controller has no native script handlers, scripts, or UI resource scheme.
            configuration.userContentController = WKUserContentController()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let view = WKWebView(frame: .zero, configuration: configuration)
            let delegate = EmbeddedBrowserDelegate(session: self, tabID: tab.id)
            view.navigationDelegate = delegate
            view.uiDelegate = delegate
            view.allowsBackForwardNavigationGestures = true
            let entry = Entry(tab: tab, view: view, delegate: delegate)
            entries[tab.id] = entry
            tabs.append(tab)
            // Inactive creation stays inactive even when inventory is empty.
            // Human '+' uses the default true. Inactive creation must not
            // acquire selection as an incidental consequence of being first.
            if select { selectedTabID = tab.id }
            observe(entry)
            errorMessage = nil
            // Empty tabs intentionally do not load a homepage or trigger any network request.
            if let url { try navigate(tabID: tab.id, to: url) }
            return tab.id
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func selectTab(_ id: UUID) {
        guard entries[id] != nil else { errorMessage = Failure.tabClosed.localizedDescription; return }
        selectedTabID = id
        errorMessage = entries[id]?.tab.error
    }

    func closeTab(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id), let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        entry.tab.documentID = UUID()
        entry.delegate.invalidate()
        entry.observations.forEach { $0.invalidate() }
        entry.observations.removeAll()
        entry.navigation = nil
        entry.view.navigationDelegate = nil
        entry.view.uiDelegate = nil
        entry.view.stopLoading()
        entry.view.removeFromSuperview()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        errorMessage = selectedTabID.flatMap { entries[$0]?.tab.error }
    }

    func navigate(tabID: UUID, to url: URL) throws {
        do {
            let entry = try entry(tabID)
            try EmbeddedBrowserURLPolicy.validate(url)
            prepareNavigation(entry)
            entry.navigation = entry.view.load(URLRequest(url: url))
        } catch {
            report(error.localizedDescription, tabID: tabID)
            throw error
        }
    }

    func goBack(tabID: UUID) {
        guard let entry = entries[tabID], entry.view.canGoBack else { return }
        prepareNavigation(entry)
        entry.navigation = entry.view.goBack()
    }

    func goForward(tabID: UUID) {
        guard let entry = entries[tabID], entry.view.canGoForward else { return }
        prepareNavigation(entry)
        entry.navigation = entry.view.goForward()
    }

    func reload(tabID: UUID) {
        guard let entry = entries[tabID], entry.view.url != nil else { return }
        prepareNavigation(entry)
        entry.navigation = entry.view.reload()
    }

    func stop(tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        entry.navigation = nil
        entry.tab.documentID = UUID()
        entry.view.stopLoading()
        entry.tab.isLoading = false
    }

    func webView(for id: UUID) -> WKWebView? { entries[id]?.view }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for id in tabs.map(\.id) { closeTab(id) }
        websiteDataStore = nil
    }

    private func entry(_ id: UUID) throws -> Entry {
        guard !isShutdown else { throw Failure.sessionClosed }
        guard let entry = entries[id] else { throw Failure.tabClosed }
        return entry
    }

    private func prepareNavigation(_ entry: Entry) {
        entry.tab.documentID = UUID()
        entry.tab.error = nil
        entry.tab.isLoading = true
        errorMessage = nil
    }

    private func observe(_ entry: Entry) {
        let id = entry.tab.id
        let refresh: @Sendable () -> Void = { [weak self, weak view = entry.view] in
            Task { @MainActor in
                guard let self, let view, self.entries[id]?.view === view else { return }
                self.refresh(id, view: view)
            }
        }
        entry.observations = [
            entry.view.observe(\.title, options: [.new]) { _, _ in refresh() },
            entry.view.observe(\.url, options: [.new]) { _, _ in refresh() },
            entry.view.observe(\.isLoading, options: [.new]) { _, _ in refresh() },
            entry.view.observe(\.canGoBack, options: [.new]) { _, _ in refresh() },
            entry.view.observe(\.canGoForward, options: [.new]) { _, _ in refresh() },
        ]
    }

    private func refresh(_ id: UUID, view: WKWebView) {
        guard let entry = entries[id], entry.view === view else { return }
        let title = view.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        entry.tab.title = title.isEmpty ? (view.url?.host ?? "New tab") : String(title.prefix(512))
        // Includes history.pushState/fragment navigation. This is intentionally conservative;
        // a document identity is not proof that arbitrary DOM content has remained unchanged.
        if entry.tab.url != view.url { entry.tab.documentID = UUID() }
        entry.tab.url = view.url
        entry.tab.isLoading = view.isLoading
        entry.tab.canGoBack = view.canGoBack
        entry.tab.canGoForward = view.canGoForward
    }

    fileprivate func owns(_ view: WKWebView, tabID: UUID) -> Bool { entries[tabID]?.view === view }

    fileprivate func report(_ message: String, tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        entry.tab.error = message
        if selectedTabID == tabID { errorMessage = message }
    }

    fileprivate func started(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view else { return }
        prepareNavigation(entry)
        entry.navigation = navigation
        refresh(tabID, view: view)
    }

    fileprivate func completed(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID, error: Error? = nil) {
        guard let entry = entries[tabID], entry.view === view, entry.navigation === navigation else { return }
        entry.navigation = nil
        refresh(tabID, view: view)
        entry.tab.isLoading = false
        if let error, (error as NSError).code != NSURLErrorCancelled {
            report("The page could not load. \(error.localizedDescription)", tabID: tabID)
        }
    }

    fileprivate func terminated(_ view: WKWebView, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view else { return }
        entry.navigation = nil
        entry.tab.documentID = UUID()
        entry.tab.isLoading = false
        report("The web content process stopped. Reload this tab to recover; no action was replayed.", tabID: tabID)
    }
}

@MainActor
private final class EmbeddedBrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var session: EmbeddedBrowserSession?
    private let tabID: UUID

    init(session: EmbeddedBrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }
    func invalidate() { session = nil }

    private func deny(_ message: String, view: WKWebView) {
        guard session?.owns(view, tabID: tabID) == true else { return }
        session?.report(message, tabID: tabID)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard session?.owns(webView, tabID: tabID) == true else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload {
            deny("Downloads are not enabled. No file was saved.", view: webView)
            decisionHandler(.cancel)
            return
        }
        do {
            guard let url = navigationAction.request.url else { throw EmbeddedBrowserURLPolicy.Rejection.invalidAddress }
            try EmbeddedBrowserURLPolicy.validate(url)
            decisionHandler(.allow)
        } catch {
            deny(error.localizedDescription, view: webView)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard session?.owns(webView, tabID: tabID) == true else { decisionHandler(.cancel); return }
        do {
            guard let url = navigationResponse.response.url else { throw EmbeddedBrowserURLPolicy.Rejection.invalidAddress }
            try EmbeddedBrowserURLPolicy.validate(url)
        } catch {
            deny(error.localizedDescription, view: webView)
            decisionHandler(.cancel)
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        guard navigationResponse.canShowMIMEType, !disposition.lowercased().contains("attachment") else {
            deny("Downloads are not enabled. No file was saved.", view: webView)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        session?.started(webView, navigation: navigation, tabID: tabID)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        session?.completed(webView, navigation: navigation, tabID: tabID)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        session?.completed(webView, navigation: navigation, tabID: tabID, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        session?.completed(webView, navigation: navigation, tabID: tabID, error: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { session?.terminated(webView, tabID: tabID) }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        deny("Downloads are not enabled. The download was cancelled.", view: webView)
        download.cancel { _ in }
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        deny("Downloads are not enabled. The download was cancelled.", view: webView)
        download.cancel { _ in }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Do not repurpose WebKit's supplied configuration or silently load into the user's tab.
        deny("This page requested another window. Pop-up windows are not enabled; the current tab was preserved.", view: webView)
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        deny("Camera and microphone access are not enabled for this browser.", view: webView)
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        deny("File selection is not enabled. No files were shared with this page.", view: webView)
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        deny("A page alert was dismissed. This browser does not open modal page dialogs.", view: webView)
        completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        deny("A page confirmation was declined. This browser does not open modal page dialogs.", view: webView)
        completionHandler(false)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        deny("A page input dialog was declined. No input was submitted.", view: webView)
        completionHandler(nil)
    }
}

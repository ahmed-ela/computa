import AppKit
import Foundation
import Observation
import WebKit

@MainActor @Observable
final class EmbeddedBrowserTab: Identifiable {
    let id: UUID
    let isPopup: Bool
    fileprivate(set) var title = "New tab"
    fileprivate(set) var url: URL?
    fileprivate(set) var isLoading = false
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false
    fileprivate(set) var documentID = UUID()
    /// Invalidates full-document navigation receipts; SPA route changes preserve it.
    fileprivate(set) var documentGeneration = UUID()
    fileprivate(set) var error: String?

    fileprivate init(id: UUID = UUID(), isPopup: Bool = false) { self.id = id; self.isPopup = isPopup }
}

/// Browser views are independent of the privileged Octane UI WebView and Chrome.
/// Human views may detach when hidden; inference views return to a render host.
/// Only close/shutdown destroys either session.
@MainActor @Observable
final class EmbeddedBrowserSession {
    enum Failure: Error, LocalizedError, Equatable {
        case tabLimit(Int)
        case tabClosed
        case sessionClosed
        case modelTabPrivate
        case modelPopupUnsupported
        case popupProfileMismatch

        var errorDescription: String? {
            switch self {
            case .tabLimit(let limit): "This browser allows up to \(limit) tabs, including background model sessions. Close a browser tab before opening another; restart Computa if only retained model sessions remain."
            case .tabClosed: "That browser tab is no longer open."
            case .sessionClosed: "This browser session has ended."
            case .modelTabPrivate: "Model sessions run privately in the background. Open a regular browser tab to visit the website."
            case .modelPopupUnsupported: "Pop-up windows are not enabled for model inference pages."
            case .popupProfileMismatch: "The requested pop-up did not preserve this browser's sign-in profile."
            }
        }
    }

    private(set) var tabs: [EmbeddedBrowserTab] = []
    /// The human browser never exposes an inference page, including a retained
    /// session whose website cleanup could not be confirmed.
    var humanTabs: [EmbeddedBrowserTab] { tabs.filter { entries[$0.id]?.isModelOwned == false } }
    private(set) var selectedTabID: UUID?
    private(set) var errorMessage: String?
    let maximumTabs: Int

    @ObservationIgnored private var websiteDataStore: WKWebsiteDataStore?
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private let profileID: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var resolvedProfileID: UUID?
    @ObservationIgnored private var transientHumanVerificationCheckpoints: [String: UUID] = [:]
    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private weak var modelRenderHost: NSView?
    @ObservationIgnored private var modelRenderHosts: [ModelRenderHostReference] = []
    @ObservationIgnored private var isShutdown = false
    static let profileDefaultsKey = "Computa.EmbeddedBrowser.ProfileIdentifier.v1"

    private final class ModelRenderHostReference {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private final class Entry {
        let tab: EmbeddedBrowserTab
        let view: WKWebView
        let delegate: EmbeddedBrowserDelegate
        let isModelOwned: Bool
        let popupOpenerTabID: UUID?
        weak var presentationHost: NSView?
        var observations: [NSKeyValueObservation] = []
        var navigation: WKNavigation?
        var preparedDocumentNavigation = false
        var modelChanges: EmbeddedModelChangeChannel?
        var modelSignalWorld: WKContentWorld?
        var modelSignalOriginHost: String?
        // Model generations also invalidate on provisional loads. Human
        // checkpoint observations advance only for a committed document.
        var humanCommittedDocumentID = UUID()
        var humanCommittedNavigation: WKNavigation?
        // Ephemeral deduplication only; neither URL nor document identity is persisted.
        var humanCheckpointDocumentID: UUID?
        var humanCheckpointURL: URL?

        init(tab: EmbeddedBrowserTab, view: WKWebView, delegate: EmbeddedBrowserDelegate, isModelOwned: Bool,
             popupOpenerTabID: UUID? = nil) {
            self.tab = tab
            self.view = view
            self.delegate = delegate
            self.isModelOwned = isModelOwned
            self.popupOpenerTabID = popupOpenerTabID
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

    /// Resolve once for both WebKit and saved checkpoints, even if preferences
    /// change while this browser instance is alive. Private sessions never call this.
    private func persistentProfileIdentifier() -> UUID {
        precondition(persistent)
        if let resolvedProfileID { return resolvedProfileID }
        let identifier: UUID
        if let profileID {
            identifier = profileID
        } else if let existing = defaults.string(forKey: Self.profileDefaultsKey).flatMap(UUID.init(uuidString:)) {
            identifier = existing
        } else {
            identifier = UUID()
            defaults.set(identifier.uuidString, forKey: Self.profileDefaultsKey)
        }
        resolvedProfileID = identifier
        return identifier
    }

    var savedHumanVerificationCheckpointIDs: [String: UUID] {
        guard persistent else { return transientHumanVerificationCheckpoints }
        return EmbeddedHumanVerificationStore(defaults: defaults, profileID: persistentProfileIdentifier()).load()
    }

    var savedHumanVerificationProviders: Set<String> { Set(savedHumanVerificationCheckpointIDs.keys) }

    /// Re-observing a saved gate in the model transport does not make it newer.
    func recordHumanVerificationRequired(provider: String) {
        recordHumanVerificationRequired(provider: provider, renewObservation: false)
    }

    private func recordHumanVerificationRequired(provider: String, renewObservation: Bool) {
        guard EmbeddedHumanVerificationStore.providers.contains(provider) else { return }
        var checkpoints = savedHumanVerificationCheckpointIDs
        guard renewObservation || checkpoints[provider] == nil else { return }
        checkpoints[provider] = UUID()
        saveHumanVerificationCheckpoints(checkpoints)
    }

    func clearHumanVerificationRequired(provider: String) {
        guard EmbeddedHumanVerificationStore.providers.contains(provider) else { return }
        var checkpoints = savedHumanVerificationCheckpointIDs
        guard checkpoints.removeValue(forKey: provider) != nil else { return }
        saveHumanVerificationCheckpoints(checkpoints)
    }

    private func saveHumanVerificationCheckpoints(_ checkpoints: [String: UUID]) {
        if persistent {
            EmbeddedHumanVerificationStore(defaults: defaults, profileID: persistentProfileIdentifier()).save(checkpoints)
        } else {
            transientHumanVerificationCheckpoints = checkpoints
        }
        for entry in entries.values where entry.isModelOwned { signalModelChange(entry) }
    }

    private func dataStore() -> WKWebsiteDataStore {
        if let websiteDataStore { return websiteDataStore }
        let store: WKWebsiteDataStore
        if persistent {
            store = WKWebsiteDataStore(forIdentifier: persistentProfileIdentifier())
        } else {
            store = .nonPersistent()
        }
        websiteDataStore = store
        return store
    }

    @discardableResult
    func createTab(url: URL? = nil, select: Bool = true) throws -> UUID {
        try createTab(url: url, select: select, modelOwned: false)
    }

    private func createTab(url: URL? = nil, select: Bool, modelOwned: Bool) throws -> UUID {
        do {
            guard !isShutdown else { throw Failure.sessionClosed }
            guard tabs.count < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
            if let url { try EmbeddedBrowserURLPolicy.validate(url) }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore()
            // This fresh controller has no native script handlers, scripts, or UI resource scheme.
            configuration.userContentController = WKUserContentController()
            // OAuth can open a window after an asynchronous response, beyond
            // the original click's gesture. Human popups still use the tab cap
            // and navigation policy; inference-owned pages cannot open them.
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = !modelOwned
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let entry = try registerTab(configuration: configuration, select: select, modelOwned: modelOwned)
            // Empty tabs intentionally do not load a homepage or trigger any network request.
            if let url { try navigate(tabID: entry.tab.id, to: url) }
            return entry.tab.id
        } catch {
            if !modelOwned { errorMessage = error.localizedDescription }
            throw error
        }
    }

    private func registerTab(configuration: WKWebViewConfiguration, select: Bool, modelOwned: Bool,
                             popupOpenerTabID: UUID? = nil) throws -> Entry {
        guard !isShutdown else { throw Failure.sessionClosed }
        guard tabs.count < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
        let tab = EmbeddedBrowserTab(isPopup: popupOpenerTabID != nil)
        let view = modelOwned ? EmbeddedModelWebView(frame: .zero, configuration: configuration)
            : WKWebView(frame: .zero, configuration: configuration)
        let delegate = EmbeddedBrowserDelegate(session: self, tabID: tab.id)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.allowsBackForwardNavigationGestures = true
        let entry = Entry(tab: tab, view: view, delegate: delegate, isModelOwned: modelOwned,
                          popupOpenerTabID: popupOpenerTabID)
        entries[tab.id] = entry
        tabs.append(tab)
        // Inactive creation stays inactive, including the first inference tab.
        if select { selectedTabID = tab.id }
        observe(entry)
        if !modelOwned { errorMessage = nil }
        return entry
    }

    fileprivate func createPopup(from source: WKWebView, tabID: UUID,
                                 configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        guard let opener = entries[tabID], opener.view === source else { return nil }
        do {
            guard !opener.isModelOwned else { throw Failure.modelPopupUnsupported }
            // window.open('', name) supplies an empty relative URL rather than
            // nil/about:blank. WebKit owns that initial blank document.
            if let url, !url.absoluteString.isEmpty { try EmbeddedBrowserURLPolicy.validate(url) }
            guard configuration.websiteDataStore === source.configuration.websiteDataStore else {
                throw Failure.popupProfileMismatch
            }
            // WebKit owns this configuration, opener and initial navigation.
            // Return synchronously without replacing settings or loading again.
            return try registerTab(configuration: configuration, select: true, modelOwned: false,
                                   popupOpenerTabID: tabID).view
        } catch {
            report(error.localizedDescription, tabID: tabID)
            return nil
        }
    }

    fileprivate func closePopup(_ view: WKWebView, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view, !entry.isModelOwned,
              entry.popupOpenerTabID != nil else { return }
        closeTab(tabID)
    }

    func selectTab(_ id: UUID) {
        guard let entry = entries[id] else { errorMessage = Failure.tabClosed.localizedDescription; return }
        guard !entry.isModelOwned else { return }
        selectedTabID = id
        errorMessage = entry.tab.error
    }

    func closeTab(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id), let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let humanIndex = tabs.prefix(index).filter { entries[$0.id]?.isModelOwned == false }.count
        entry.tab.documentID = UUID()
        entry.tab.documentGeneration = UUID()
        entry.modelChanges?.close()
        if let world = entry.modelSignalWorld {
            entry.view.configuration.userContentController.removeScriptMessageHandler(forName: Self.modelSignalName, contentWorld: world)
        }
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
            if let opener = entry.popupOpenerTabID, entries[opener]?.isModelOwned == false { selectedTabID = opener }
            else {
                let remaining = humanTabs
                selectedTabID = remaining.isEmpty ? nil : remaining[min(humanIndex, remaining.count - 1)].id
            }
        }
        if !entry.isModelOwned { errorMessage = selectedTabID.flatMap { entries[$0]?.tab.error } }
    }

    func navigate(tabID: UUID, to url: URL) throws {
        do {
            let entry = try entry(tabID)
            try EmbeddedBrowserURLPolicy.validate(url)
            prepareNavigation(entry, replacesDocument: true)
            (entry.view as? EmbeddedModelWebView)?.captureNativeFocus()
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
        prepareNavigation(entry, replacesDocument: true)
        entry.navigation = entry.view.reload()
    }

    func stop(tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        entry.navigation = nil
        entry.preparedDocumentNavigation = false
        entry.tab.documentID = UUID()
        entry.tab.documentGeneration = UUID()
        entry.view.stopLoading()
        entry.tab.isLoading = false
        signalModelChange(entry)
    }

    func webView(for id: UUID) -> WKWebView? { entries[id]?.view }

    func captureModelNativeFocus(tabID: UUID) {
        (entries[tabID]?.view as? EmbeddedModelWebView)?.captureNativeFocus()
    }

    func restoreModelNativeFocus(tabID: UUID) {
        (entries[tabID]?.view as? EmbeddedModelWebView)?.restoreNativeFocus()
    }

    /// The SwiftUI workspace keeps this host attached even when Browser or
    /// Settings is hidden. It is a render surface, never an input destination.
    func installModelRenderHost(_ host: NSView) {
        modelRenderHosts.removeAll { $0.view == nil }
        if !modelRenderHosts.contains(where: { $0.view === host }) { modelRenderHosts.append(ModelRenderHostReference(host)) }
        // WindowGroup shares this session. Updating another window must not
        // move live pages away from a surviving designated render host.
        if modelRenderHost == nil { modelRenderHost = modelRenderHosts.first?.view }
        for entry in entries.values where entry.isModelOwned && entry.presentationHost == nil {
            mountModelView(entry)
        }
    }

    func removeModelRenderHost(_ host: NSView) {
        modelRenderHosts.removeAll { $0.view == nil || $0.view === host }
        if modelRenderHost === host {
            modelRenderHost = modelRenderHosts.first?.view
            for entry in entries.values where entry.isModelOwned && entry.presentationHost == nil {
                if modelRenderHost != nil { mountModelView(entry) }
                else if entry.view.superview === host { entry.view.removeFromSuperview() }
            }
        }
    }

    func presentTab(_ id: UUID, in host: NSView) throws {
        let entry = try entry(id)
        guard !entry.isModelOwned else { throw Failure.modelTabPrivate }
        entry.presentationHost = host
        entry.view.removeFromSuperview()
        entry.view.frame = host.bounds
        entry.view.autoresizingMask = [.width, .height]
        (entry.view as? EmbeddedModelWebView)?.captureNativeFocus(in: host.window)
        host.addSubview(entry.view)
    }

    func detachPresentedTab(_ id: UUID, from host: NSView) {
        guard let entry = entries[id], entry.presentationHost === host else { return }
        entry.presentationHost = nil
        if entry.view.superview === host { entry.view.removeFromSuperview() }
        if entry.isModelOwned { mountModelView(entry) }
    }

    private func mountModelView(_ entry: Entry) {
        guard let host = modelRenderHost else { return }
        if entry.view.superview !== host { entry.view.removeFromSuperview() }
        entry.view.autoresizingMask = []
        entry.view.frame = NSRect(x: 0, y: 0, width: 1_024, height: 768)
        (entry.view as? EmbeddedModelWebView)?.captureNativeFocus(in: host.window)
        if entry.view.superview !== host { host.addSubview(entry.view) }
    }

    func documentGeneration(for id: UUID) -> UUID? { entries[id]?.tab.documentGeneration }

    static let modelSignalName = "computaChatGPTSignal"

    /// Only inference-owned views receive this notification-only private-world handler.
    func installModelChangeSignal(tabID: UUID, ownerToken: String, world: WKContentWorld,
                                  originHost: String = "chatgpt.com") throws {
        let entry = try entry(tabID)
        guard UUID(uuidString: ownerToken) != nil, entry.modelChanges == nil,
              ["chatgpt.com", "claude.ai", "gemini.google.com"].contains(originHost) else { throw Failure.tabClosed }
        entry.modelChanges = EmbeddedModelChangeChannel(ownerToken: ownerToken)
        entry.modelSignalWorld = world
        entry.modelSignalOriginHost = originHost
        entry.view.configuration.userContentController.add(EmbeddedModelSignalHandler(session: self, tabID: tabID),
                                                           contentWorld: world, name: Self.modelSignalName)
    }

    func modelChangeRevision(for id: UUID) throws -> UInt64 {
        guard let channel = try entry(id).modelChanges else { throw Failure.tabClosed }
        return try channel.currentRevision()
    }

    /// Native profile state can invalidate an inference without a DOM change.
    /// This only wakes its existing notification channel; it grants no page authority.
    func notifyModelSessionChange(tabID: UUID) {
        entries[tabID]?.modelChanges?.signal()
    }

    func waitForModelChange(tabID: UUID, after revision: UInt64,
                            until deadline: ContinuousClock.Instant) async throws -> UInt64 {
        guard let channel = try entry(tabID).modelChanges else { throw Failure.tabClosed }
        return try await channel.wait(after: revision, until: deadline)
    }

    fileprivate func receivedModelSignal(_ message: WKScriptMessage, tabID: UUID) {
        guard let entry = entries[tabID], message.webView === entry.view, message.frameInfo.isMainFrame,
              let channel = entry.modelChanges,
              let body = message.body as? [String: String], body.count == 2, Set(body.keys) == ["ownerToken", "kind"],
              body["ownerToken"] == channel.ownerToken, body["kind"] == "dom_changed" else { return }
        let origin = message.frameInfo.securityOrigin
        guard origin.`protocol` == "https", origin.host == entry.modelSignalOriginHost,
              origin.port == 0 || origin.port == 443 else { return }
        channel.signal()
    }

    private func signalModelChange(_ entry: Entry) { entry.modelChanges?.signal() }

    /// Model pages share the sign-in profile, but never reuse a human's tab.
    func createModelTab(url: URL) throws -> UUID {
        try createModelTab(initialURL: url)
    }

    #if DEBUG
    /// Fixtures load one local document themselves. Starting about:blank first
    /// would leave two competing provisional navigations in the same WebView.
    func createUnloadedModelTabForTesting() throws -> UUID {
        try createModelTab(initialURL: nil)
    }
    #endif

    private func createModelTab(initialURL: URL?) throws -> UUID {
        let id = try createTab(select: false, modelOwned: true)
        do {
            guard let view = webView(for: id) else { throw Failure.tabClosed }
            view.frame = NSRect(x: 0, y: 0, width: 1_024, height: 768)
            if let entry = entries[id] { mountModelView(entry) }
            if let initialURL { try navigate(tabID: id, to: initialURL) }
            return id
        } catch {
            closeTab(id)
            throw error
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for id in tabs.map(\.id) { closeTab(id) }
        modelRenderHost = nil
        modelRenderHosts.removeAll()
        websiteDataStore = nil
    }

    private func entry(_ id: UUID) throws -> Entry {
        guard !isShutdown else { throw Failure.sessionClosed }
        guard let entry = entries[id] else { throw Failure.tabClosed }
        return entry
    }

    private func prepareNavigation(_ entry: Entry, replacesDocument: Bool = false) {
        entry.tab.documentID = UUID()
        entry.preparedDocumentNavigation = replacesDocument
        if replacesDocument { entry.tab.documentGeneration = UUID() }
        entry.tab.error = nil
        entry.tab.isLoading = true
        signalModelChange(entry)
        if selectedTabID == entry.tab.id { errorMessage = nil }
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

    private func refresh(_ id: UUID, view: WKWebView, committedNavigation: Bool = false) {
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
        // A provisional load can still expose the old page URL. Observe the
        // committed document or settled native URL without inspecting its DOM.
        if !entry.isModelOwned, committedNavigation || !view.isLoading {
            observeHumanVerificationCheckpoint(entry)
        }
        signalModelChange(entry)
    }

    private func observeHumanVerificationCheckpoint(_ entry: Entry) {
        guard let provider = EmbeddedHumanVerificationStore.provider(forTrustedHumanURL: entry.view.url) else {
            entry.humanCheckpointDocumentID = nil
            entry.humanCheckpointURL = nil
            return
        }
        guard entry.humanCheckpointDocumentID != entry.humanCommittedDocumentID
                || entry.humanCheckpointURL != entry.view.url else { return }
        entry.humanCheckpointDocumentID = entry.humanCommittedDocumentID
        entry.humanCheckpointURL = entry.view.url
        recordHumanVerificationRequired(provider: provider, renewObservation: true)
    }

    fileprivate func owns(_ view: WKWebView, tabID: UUID) -> Bool { entries[tabID]?.view === view }

    fileprivate func report(_ message: String, tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        entry.tab.error = message
        if selectedTabID == tabID { errorMessage = message }
    }

    fileprivate func started(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view else { return }
        // A native load/reload invalidates synchronously, before WebKit starts it.
        // Page-initiated full navigations advance here; pushState does not arrive here.
        let prepared = entry.preparedDocumentNavigation && entry.navigation === navigation
        prepareNavigation(entry)
        if !prepared { entry.tab.documentGeneration = UUID() }
        entry.navigation = navigation
        refresh(tabID, view: view)
    }

    fileprivate func completed(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID, error: Error? = nil) {
        guard let entry = entries[tabID], entry.view === view, entry.navigation === navigation else { return }
        entry.navigation = nil
        entry.preparedDocumentNavigation = false
        refresh(tabID, view: view)
        entry.tab.isLoading = false
        if let error, (error as NSError).code != NSURLErrorCancelled {
            report("The page could not load. \(error.localizedDescription)", tabID: tabID)
        }
    }

    fileprivate func committed(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view, entry.navigation === navigation else { return }
        if !entry.isModelOwned, let navigation, entry.humanCommittedNavigation !== navigation {
            entry.humanCommittedNavigation = navigation
            entry.humanCommittedDocumentID = UUID()
        }
        refresh(tabID, view: view, committedNavigation: true)
    }

    fileprivate func terminated(_ view: WKWebView, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view else { return }
        entry.navigation = nil
        entry.preparedDocumentNavigation = false
        entry.tab.documentID = UUID()
        entry.tab.documentGeneration = UUID()
        entry.tab.isLoading = false
        report("The web content process stopped. Reload this tab to recover; no action was replayed.", tabID: tabID)
        signalModelChange(entry)
    }
}

/// DOM focus is needed for the fixed editor adapter, but must never acquire
/// the application's native first responder, including during reparenting.
@MainActor
private final class EmbeddedModelWebView: WKWebView {
    private weak var focusWindow: NSWindow?
    private weak var focusResponder: NSResponder?
    private weak var focusField: NSTextField?
    private weak var focusFieldEditor: NSTextView?
    private var focusFieldText: String?
    private var focusFieldSelection: NSRange?
    private var restoringFocus = false

    override var acceptsFirstResponder: Bool { false }

    func captureNativeFocus(in targetWindow: NSWindow? = nil) {
        guard let target = targetWindow ?? window, let responder = target.firstResponder,
              !ownsResponder(responder) else { return }
        focusWindow = target
        focusResponder = responder
        NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
        focusField = nil
        focusFieldEditor = nil
        focusFieldText = nil
        focusFieldSelection = nil
        guard let editor = responder as? NSTextView, editor.isFieldEditor,
              let field = editingField(for: editor, in: target) else { return }
        // The window's shared editor detaches when WebKit takes native focus.
        // Keep its stable control and current editing buffer instead of trying
        // to make that detached editor a responder again.
        focusField = field
        focusFieldEditor = editor
        rememberFieldEditing()
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(fieldEditingChanged(_:)),
                                                   name: name, object: editor)
        }
    }

    func restoreNativeFocus() {
        guard !restoringFocus, let target = window, target === focusWindow,
              let current = target.firstResponder, ownsResponder(current) else { return }
        if let field = focusField {
            guard field.window === target, !field.isHiddenOrHasHiddenAncestor,
                  field.isEnabled, field.isEditable,
                  let selection = focusFieldSelection else { return }
            restoringFocus = true
            defer { restoringFocus = false }
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView,
                  target.firstResponder === editor else { return }
            if let text = focusFieldText, editor.string != text {
                // Reenter the normal editing path so SwiftUI's binding receives
                // the unsent buffer too. Restoring focus is not an undoable edit.
                let undo = editor.undoManager
                let undoWasEnabled = undo?.isUndoRegistrationEnabled == true
                if undoWasEnabled { undo?.disableUndoRegistration() }
                editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                if undoWasEnabled { undo?.enableUndoRegistration() }
            }
            let length = editor.textStorage?.length ?? 0
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            return
        }
        guard let responder = focusResponder, !ownsResponder(responder) else { return }
        // An old control detached during an await is no longer an admissible
        // focus destination; never redirect into another window.
        if let view = responder as? NSView, view.window !== target { return }
        if let responderWindow = responder as? NSWindow, responderWindow !== target { return }
        restoringFocus = true
        defer { restoringFocus = false }
        _ = target.makeFirstResponder(responder)
    }

    @objc private func fieldEditingChanged(_ notification: Notification) {
        guard !restoringFocus, let editor = notification.object as? NSTextView,
              editor === focusFieldEditor, let target = focusWindow,
              target === window, target.firstResponder === editor else { return }
        if focusField?.currentEditor() !== editor {
            // The human reused this window's shared editor for another field
            // during an awaited website action. Follow its exact current owner,
            // rather than restoring the earlier control over that newer choice.
            captureNativeFocus(in: target)
            return
        }
        rememberFieldEditing()
    }

    private func rememberFieldEditing() {
        guard let field = focusField, let editor = focusFieldEditor,
              field.window === focusWindow, field.currentEditor() === editor else { return }
        // A secure control retains its own contents. Never copy its plaintext
        // into a model view's focus snapshot or synthesize a password insertion.
        focusFieldText = field is NSSecureTextField ? nil : editor.string
        focusFieldSelection = editor.selectedRange()
    }

    private func editingField(for editor: NSTextView, in target: NSWindow) -> NSTextField? {
        if let field = editor.delegate as? NSTextField, field.window === target,
           field.currentEditor() === editor { return field }
        // SwiftUI may use a delegate proxy. Match the actual current editor in
        // this window, rather than guessing a control from its class or label.
        var pending = target.contentView.map { [$0] } ?? []
        var inspected = 0
        while let view = pending.popLast(), inspected < 2_048 {
            inspected += 1
            if let field = view as? NSTextField, field.currentEditor() === editor { return field }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    override func becomeFirstResponder() -> Bool {
        // NSWindow has already installed this responder at this point. A
        // refusal falls back to the window, clearing the human's input. Restore
        // the exact captured responder synchronously before another key event.
        restoreNativeFocus()
        return true
    }

    private func ownsResponder(_ responder: NSResponder) -> Bool {
        responder === self || (responder as? NSView)?.isDescendant(of: self) == true
    }
}

@MainActor
private final class EmbeddedModelSignalHandler: NSObject, WKScriptMessageHandler {
    private weak var session: EmbeddedBrowserSession?
    private let tabID: UUID

    init(session: EmbeddedBrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receivedModelSignal(message, tabID: tabID)
    }
}

/// Revision is recorded before inspection. A change between inspection and
/// registration returns immediately instead of disappearing into a missed wakeup.
@MainActor
private final class EmbeddedModelChangeChannel {
    let ownerToken: String
    private var revision: UInt64 = 0
    private var closed = false
    private struct Waiter {
        let continuation: CheckedContinuation<UInt64, Error>
        let timeout: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    init(ownerToken: String) { self.ownerToken = ownerToken }
    func currentRevision() throws -> UInt64 {
        guard !closed else { throw EmbeddedBrowserSession.Failure.tabClosed }
        return revision
    }

    func signal() {
        guard !closed else { return }
        guard revision < UInt64.max else { close(); return }
        revision += 1
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.timeout.cancel(); waiter.continuation.resume(returning: revision) }
    }

    func close() {
        closed = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: EmbeddedBrowserSession.Failure.tabClosed)
        }
    }

    func wait(after expected: UInt64, until deadline: ContinuousClock.Instant) async throws -> UInt64 {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !closed else { throw EmbeddedBrowserSession.Failure.tabClosed }
            if revision != expected || ContinuousClock.now >= deadline { return revision }
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timeout = Task {
                    do {
                        try await Task.sleep(until: deadline, clock: .continuous)
                        self.complete(id, cancelled: false)
                    } catch { }
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id, cancelled: true) }
        }
    }

    private func complete(_ id: UUID, cancelled: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        if cancelled { waiter.continuation.resume(throwing: CancellationError()) }
        else { waiter.continuation.resume(returning: revision) }
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
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        session?.committed(webView, navigation: navigation, tabID: tabID)
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
        session?.createPopup(from: webView, tabID: tabID, configuration: configuration,
                             url: navigationAction.request.url)
    }

    func webViewDidClose(_ webView: WKWebView) { session?.closePopup(webView, tabID: tabID) }

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

import SwiftUI
import WebKit

@MainActor
struct WebWorkspaceView: View {
    @Bindable var state: AppState
    @State private var showsAccessModeSettings = false

    @State private var sidebarPeeked = false
    @State private var launcherPresented = false
    @State private var editingBrowserID: UUID?
    @State private var addressFocusRequest = 0
    @State private var launcherChat: LauncherChat?

    private var commandPanelPresented: Bool { launcherPresented || editingBrowserID != nil }

    private func openBrowserAddress() {
        guard launcherAllowed, !launcherPresented, let id = state.primaryBrowserID else { return }
        editingBrowserID = id
        addressFocusRequest &+= 1
    }

    private func closeBrowserAddress() {
        let editedID = editingBrowserID
        editingBrowserID = nil
        guard launcherAllowed, editedID != nil, editedID == state.primaryBrowserID,
              let tabID = state.browserSession.selectedTabID, let page = state.browserSession.webView(for: tabID) else { return }
        page.window?.makeFirstResponder(page)
    }

    private var launcherAllowed: Bool {
        state.presentedSheet == nil && !showsAccessModeSettings && !state.isAPIProvidersPresented
            && !state.approvalGateBlocksInteraction
    }

    private func openLauncher() {
        guard launcherAllowed else { return }
        editingBrowserID = nil
        launcherPresented = true
    }

    private func launch(_ destination: NewTabDestination, text: String) {
        guard launcherPresented, launcherAllowed else { return }
        launcherPresented = false
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch destination {
        case .browser:
            guard let url = query.isEmpty ? EmbeddedBrowserURLPolicy.newTabURL : try? EmbeddedBrowserURLPolicy.searchURL(for: query) else { return }
            state.newWorkspaceBrowserTab(url: url)
        case .chat:
            if state.isReviewPresented { state.toggleReview() }
            state.createTask()
            guard let task = state.selectedTask else { return }
            // Accept against the new task before a second shortcut can change selection.
            var unsentDraft: String?
            if !query.isEmpty {
                let available = LocalModelOption.availableForNewPrompt(task.model, in: state.modelOptions)
                let accepted = available && state.acceptPrompt(prompt: query, taskID: task.id, requestID: task.id)
                if !accepted { unsentDraft = query }
            }
            launcherChat = LauncherChat(taskID: task.id, unsentDraft: unsentDraft)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            workspace(topInset: geometry.safeAreaInsets.top)
        }
        .focusedSceneValue(\.tabWorkspace, state)
        .onChange(of: state.isTaskSidebarCollapsed) { _, _ in sidebarPeeked = false }
        .onChange(of: state.primaryBrowserID) { _, current in
            if current != editingBrowserID { editingBrowserID = nil }
        }
        .onChange(of: commandPanelPresented) { _, presented in if presented { sidebarPeeked = false } }
        .onChange(of: launcherAllowed) { _, allowed in
            if !allowed {
                launcherPresented = false
                editingBrowserID = nil
                sidebarPeeked = false
            }
        }
    }

    private func workspace(topInset: CGFloat) -> some View {
        // Align the sidebar and any visible pane controls with the native title bar.
        let rowHeight = topInset > 0 ? topInset : 32
        let browserPrimary = state.primaryBrowserID != nil && state.shouldPresentBrowserPane
        let compact = state.isTaskSidebarCollapsed && !sidebarPeeked
        let sidebarWidth = compact ? SidebarRail.compactWidth : SidebarRail.expandedWidth
        var snapshot = WebUISnapshot(state: state, titlebarHeight: rowHeight)
        snapshot.isTaskSidebarPeeked = sidebarPeeked
        snapshot.launcherChat = launcherChat
        return ZStack(alignment: .center) {
            HSplitView {
                CodexWebView(
                    state: state,
                    snapshot: snapshot,
                    sidebarControlsEnabled: launcherAllowed && !commandPanelPresented,
                    setSidebarPeeked: { sidebarPeeked = $0 },
                    openTabLauncher: openLauncher,
                    openBrowserAddress: openBrowserAddress,
                    consumeLauncherChat: { id in
                        guard launcherChat?.taskID == id else { return false }
                        launcherChat = nil
                        return state.selectedTaskID == id && state.primaryBrowserID == nil && launcherAllowed && !launcherPresented
                    },
                    showAccessModeSettings: { showsAccessModeSettings = true }
                )
                .frame(minWidth: browserPrimary ? sidebarWidth : 600,
                       idealWidth: browserPrimary ? sidebarWidth : 640,
                       maxWidth: browserPrimary ? sidebarWidth : .infinity, maxHeight: .infinity)
                // Each split item has its own safe area. Let the web sidebar
                // paint behind the traffic lights using its actual width and theme.
                .ignoresSafeArea(.container, edges: .top)

                // External pages are sibling views, never children of the
                // privileged Octane document or its script-message bridge.
                // Hiding the pane preserves the session and every tab.
                if state.shouldPresentBrowserPane {
                    EmbeddedBrowserPane(
                        session: state.browserSession,
                        tabRowHeight: rowHeight,
                        usesSidebarTabs: browserPrimary,
                        showsNewTabButton: state.workspaceLayout.allowsBrowserSidePane,
                        titlebarTrailingInset: topInset > 0 && state.workspaceLayout.allowsBrowserSidePane ? BrowserTitlebarToggle.width : 0,
                        isInteractionBlocked: state.approvalGateBlocksInteraction,
                        canLoadModels: state.canRefreshWebsiteModels,
                        modelSetupStatus: state.websiteModelSetupStatus(for:),
                        onLoadModels: { id in Task { await state.loadSignedInModels(tabID: id) } },
                        canConfigureKimiProfile: state.canConfigureKimiProfile,
                        onSwitchKimiProfile: state.switchKimiSignInProfile(from:),
                        onClose: {
                            guard state.workspaceLayout.allowsBrowserSidePane else { return }
                            state.workspaceTabs.browserIsPrimary = false
                            state.isBrowserPresented = false
                        }
                    )
                    .frame(minWidth: 360, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    // When this pane opens, the chat already occupies the whole split.
                    // Give the new pane room above its minimum before growing the chat.
                    .layoutPriority(1)
                }
            }
            .allowsHitTesting(!state.approvalGateBlocksInteraction && !commandPanelPresented)
            .accessibilityHidden(state.approvalGateBlocksInteraction || commandPanelPresented)
            .disabled(state.approvalGateBlocksInteraction)

            if let editingBrowserID, launcherAllowed,
               let tab = state.browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID == editingBrowserID }) {
                ZStack(alignment: Alignment(horizontal: .center, vertical: .commandFieldCenter)) {
                    Color.black.opacity(0.10)
                        .onTapGesture(perform: closeBrowserAddress)
                        .alignmentGuide(.commandFieldCenter) { $0.height / 3 }
                    BrowserAddressPalette(state: state, tab: tab, focusRequest: addressFocusRequest, close: closeBrowserAddress)
                        .id(tab.id)
                }
            } else if launcherPresented && launcherAllowed {
                Color.black.opacity(0.10).onTapGesture { launcherPresented = false }
                WorkspaceTabLauncher(launch: launch, cancel: { launcherPresented = false })
            }

            // The web surface stays inert through approval settlement.
            if state.resolvingApprovalIDs.isEmpty,
               let request = state.presentedApproval {
                Color.black.opacity(0.16)
                    .onTapGesture { } // Outside clicks never resolve an approval.
                    .accessibilityHidden(true)

                NativeApprovalGate(
                    request: request,
                    remainingCount: max(0, state.pendingApprovals.count - 1),
                    isResolving: state.resolvingApprovalIDs.contains(request.id)
                ) { approved in
                    Task { @MainActor in
                        await state.resolveApproval(request, approved: approved)
                    }
                }
                .padding(24)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // WebKit reserves this part of the task sidebar. Keep its native
            // controls above the approval shield and outside the web bridge.
            if state.presentedSheet == nil {
                NativeRuntimeStatusBar(state: state, compact: compact)
                    .frame(maxWidth: compact ? 44 : 190, alignment: .leading)
                    .frame(height: 34)
            }
        }
        .ignoresSafeArea()
        // A detached WKWebView is not a visible WebKit page. Keep owned model
        // views attached and renderable without showing or focusing them.
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            EmbeddedModelRenderHost(session: state.browserSession)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear { state.browserSession.enableWorkspaceFavicons() }
        .onChange(of: state.presentedSheet) { _, sheet in
            if sheet != .settings { showsAccessModeSettings = false }
        }
        .alert("Couldn’t open a browser tab", isPresented: Binding(
            get: { state.browserTabOpenError != nil }, set: { if !$0 { state.browserTabOpenError = nil } }
        )) { Button("OK") { state.browserTabOpenError = nil } } message: {
            Text(state.browserTabOpenError ?? "")
        }
        .sheet(isPresented: $showsAccessModeSettings) {
            NativeAccessModeSettings(state: state)
        }
        .sheet(isPresented: Binding(get: { state.isAPIProvidersPresented && !state.approvalGateBlocksInteraction },
            set: { state.isAPIProvidersPresented = $0 })) {
            APIProviderSettingsView(settings: state.apiProviderSettings, alibabaSetupID: state.alibabaSetupID)
        }
    }
}

@MainActor
private struct CodexWebView: NSViewRepresentable {
    let state: AppState
    let snapshot: WebUISnapshot
    let sidebarControlsEnabled: Bool
    let setSidebarPeeked: (Bool) -> Void
    let openTabLauncher: () -> Void
    let openBrowserAddress: () -> Void
    let consumeLauncherChat: (String) -> Bool
    let showAccessModeSettings: () -> Void

    func makeCoordinator() -> WebBridge {
        WebBridge(state: state, consumeLauncherChat: consumeLauncherChat, showAccessModeSettings: showAccessModeSettings)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: WebBridge.handlerName)
        if WebBridge.diagnosticsEnabled {
            controller.addUserScript(WKUserScript(
                source: WebBridge.diagnosticBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            WebUIResourceSchemeHandler(),
            forURLScheme: WebUIResourceLocator.scheme
        )

        let webView = WindowConfiguredWebView(frame: .zero, configuration: configuration)
        webView.openTabLauncher = openTabLauncher
        webView.openBrowserAddress = openBrowserAddress
        webView.configureTitlebarControls(state: state)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
#if DEBUG
        webView.isInspectable = true
#endif
        webView.rail.onHover = setSidebarPeeked
        context.coordinator.attach(webView: webView)
        context.coordinator.update(snapshot: snapshot)

        if WebUIResourceLocator.indexURL != nil {
            webView.load(URLRequest(url: WebUIResourceLocator.appURL))
        } else {
            webView.loadHTMLString(Self.missingResourceHTML, baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let shell = webView as? WindowConfiguredWebView
        let compact = snapshot.isTaskSidebarCollapsed && !snapshot.isTaskSidebarPeeked
        let railWidth = compact ? SidebarRail.compactWidth : SidebarRail.expandedWidth
        shell?.trackSidebar(width: snapshot.isTaskSidebarCollapsed && sidebarControlsEnabled ? railWidth : 0)
        webView.needsLayout = true
        context.coordinator.update(snapshot: snapshot)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: WebBridge) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WebBridge.handlerName
        )
        webView.navigationDelegate = nil
    }

    private static let missingResourceHTML = """
    <!doctype html>
    <meta charset="utf-8">
    <style>
      body { font: 14px -apple-system; margin: 0; min-height: 100vh; display: grid;
             place-items: center; color: #555; background: #f8f8f7; }
      main { text-align: center; max-width: 420px; }
    </style>
    <main><h2>Kolmogor UI is unavailable</h2>
    <p>The bundled Octane assets could not be found. Rebuild WebUI before packaging the app.</p></main>
    """
}

@MainActor
private final class WindowConfiguredWebView: WKWebView {
    var openTabLauncher: (() -> Void)?
    var openBrowserAddress: (() -> Void)?
    let rail = SidebarRail()
    private var trackedWidth: CGFloat = 0
    private var railArea: NSTrackingArea?
    private var titlebarControls: [NSTitlebarAccessoryViewController] = []

    private weak var state: AppState?
    private let compose = NSButton()

    func configureTitlebarControls(state: AppState) {
        self.state = state
        titlebarControls = [accessory(.left, SidebarTitlebarToggle(state: state))]
        guard state.workspaceLayout.allowsBrowserSidePane else { return }
        titlebarControls.append(accessory(.right, BrowserTitlebarToggle(state: state)))
        compose.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        compose.imagePosition = .imageOnly
        compose.bezelStyle = .accessoryBarAction
        compose.showsBorderOnlyWhileMouseInside = true
        compose.setAccessibilityLabel("New chat")
        compose.identifier = .init("chat-new")
        compose.toolTip = "New chat (⇧⌘N)"
        compose.target = self
        compose.action = #selector(createChat)
        compose.isHidden = true
        addSubview(compose)
    }

    func trackSidebar(width: CGFloat) {
        guard width != trackedWidth else { return }
        trackedWidth = width
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // One tracking rectangle spans the list, title bar and Settings footer,
        // including the handoff from the trusted web view to a native browser tab.
        let rect = NSRect(x: bounds.minX, y: bounds.minY, width: min(trackedWidth, bounds.width), height: bounds.height)
        if railArea?.rect == rect { return }
        if let railArea { removeTrackingArea(railArea); self.railArea = nil }
        guard !rect.isEmpty else { return }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        if trackedWidth == SidebarRail.expandedWidth { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: rect, options: options, owner: rail, userInfo: nil)
        addTrackingArea(area)
        railArea = area
    }

    override func layout() {
        super.layout()
        guard let window, let state, compose.superview != nil else { return }
        compose.isHidden = !window.styleMask.contains(.titled) || state.presentedSheet != nil
            || (state.primaryBrowserID != nil && state.shouldPresentBrowserPane)
        compose.isEnabled = !state.approvalGateBlocksInteraction
        guard !compose.isHidden else { return }
        let height = window.frame.height - window.contentLayoutRect.maxY
        let top = (height > 0 ? height : 32) / 2 - 11
        let trailing = state.shouldPresentBrowserPane ? 6 : BrowserTitlebarToggle.width + 4
        compose.frame = NSRect(x: bounds.maxX - trailing - 28,
                               y: isFlipped ? bounds.minY + top : bounds.maxY - top - 22,
                               width: 28, height: 22)
    }

    @objc private func createChat() {
        guard let state, !state.approvalGateBlocksInteraction, state.presentedSheet == nil else { return }
        state.createTask()
        guard WebUIResourceLocator.contains(url) else { return }
        evaluateJavaScript("document.dispatchEvent(new Event('kolmogor-clear-chat-search'))")
    }

    private func accessory(_ edge: NSLayoutConstraint.Attribute, _ content: some View) -> NSTitlebarAccessoryViewController {
        let controller = NSTitlebarAccessoryViewController()
        let control = NSHostingView(rootView: content)
        control.setFrameSize(control.fittingSize)
        controller.view = control
        controller.layoutAttribute = edge
        return controller
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Route only the compose control through the chat pane; the rest of the title bar stays draggable.
        if compose.superview != nil, !compose.isHidden, let superview, compose.frame.contains(convert(point, from: superview)) { return compose }
        if let window, let superview, superview.convert(point, to: nil).y >= window.contentLayoutRect.maxY {
            return nil
        }
        return super.hitTest(point)
    }

    @objc private func handleBrowserAddressRequest(_ notification: Notification) { openBrowserAddress?() }

    @objc private func handleTabLauncherRequest(_ notification: Notification) {
        openTabLauncher?()
    }

    @objc private func windowResignedKey(_ notification: Notification) { rail.onHover(false) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: WorkspaceTabLauncher.requestNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: BrowserAddressPalette.requestNotification, object: window)
        }
        if let window, window !== newWindow, window.styleMask.contains(.titled) {
            for control in titlebarControls {
                if let index = window.titlebarAccessoryViewControllers.firstIndex(of: control) {
                    window.removeTitlebarAccessoryViewController(at: index)
                }
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBrowserAddressRequest(_:)),
                                               name: BrowserAddressPalette.requestNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(handleTabLauncherRequest(_:)),
                                               name: WorkspaceTabLauncher.requestNotification, object: window)
        window.title = "Kolmogor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 980, height: 640)
        guard window.styleMask.contains(.titled) else { return }
        for control in titlebarControls where !window.titlebarAccessoryViewControllers.contains(control) {
            window.addTitlebarAccessoryViewController(control)
        }
    }
}

private struct BrowserTitlebarToggle: View {
    static let width: CGFloat = 34
    #if SWIFT_PACKAGE
    // Command-line SwiftPM copies the SVG without compiling the asset catalog.
    private static let globe: Image = {
        guard let url = Bundle.module.url(forResource: "BrowserGlobe", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return Image(systemName: "globe") }
        return Image(nsImage: image)
    }()
    #else
    private static let globe = Image(decorative: "BrowserGlobe")
    #endif
    @Bindable var state: AppState

    var body: some View {
        Toggle(isOn: Binding(get: { state.isBrowserPresented && state.primaryBrowserID == nil },
                             set: { _ in state.toggleWorkspaceBrowser() })) {
            Self.globe
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(state.shouldPresentBrowserPane ? Color.accentColor : .secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Browser")
        .accessibilityIdentifier("browser-toggle")
        .help(state.primaryBrowserID != nil && state.selectedTaskID != nil ? "Show chat beside browser" : state.shouldPresentBrowserPane ? "Hide browser" : "Show browser")
        .disabled(state.presentedSheet != nil || state.approvalGateBlocksInteraction)
        .frame(width: Self.width, alignment: .leading)
    }
}

enum WebUIResourceLocator {
    static let scheme = "localcodex-app"
    static let host = "ui"
    static let appURL = URL(string: "\(scheme)://\(host)/index.html")!

    static var indexURL: URL? {
        candidateBundles.lazy.compactMap { bundle in
            bundle.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: "WebUI"
            )
        }.first
    }

    static func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == scheme && url.host == host && safeRelativePath(for: url) != nil
    }

    static func fileURL(for url: URL) -> URL? {
        guard contains(url),
              let root = indexURL?.deletingLastPathComponent().standardizedFileURL,
              let relativePath = safeRelativePath(for: url)
        else {
            return nil
        }

        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    private static func safeRelativePath(for url: URL) -> String? {
        let relativePath = String(url.path.drop(while: { $0 == "/" }))
        guard !relativePath.isEmpty,
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !relativePath.contains("\\")
        else {
            return nil
        }
        return relativePath
    }

    private static var candidateBundles: [Bundle] {
#if SWIFT_PACKAGE
        [Bundle.module, Bundle.main]
#else
        [Bundle.main]
#endif
    }
}

@MainActor
private final class WebUIResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let fileURL = WebUIResourceLocator.fileURL(for: url),
              let data = try? Data(contentsOf: fileURL)
        else {
            urlSchemeTask.didFailWithError(
                CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: urlSchemeTask.request.url as Any])
            )
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(for: fileURL.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: Self.isText(fileURL.pathExtension) ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html"
        case "js": "text/javascript"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }

    private static func isText(_ pathExtension: String) -> Bool {
        ["html", "js", "css", "json", "map", "svg"].contains(pathExtension.lowercased())
    }
}

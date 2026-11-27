import SwiftUI
import WebKit

@MainActor
struct WebWorkspaceView: View {
    @Bindable var state: AppState
    let windowTabs: WorkspaceTabs

    init(state: AppState, window: WorkspaceTabs? = nil) {
        self.state = state
        self.windowTabs = window ?? state.workspaceTabs
    }

    @State private var showsAccessModeSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var trafficLightClearance: CGFloat = 0
    @State private var sidebarPeeked = false
    @State private var launcherError: String?
    @State private var launcherPresented = false
    @State private var editingBrowserID: UUID?
    @State private var addressFocusRequest = 0

    private var commandPanelPresented: Bool { launcherPresented || editingBrowserID != nil }

    var sidebarCollapseBinding: Binding<Bool> {
        Binding(get: { windowTabs.isSidebarCollapsed }, set: { collapsed in
            state.workspaceWindows.withWindow(windowTabs) { state.isTaskSidebarCollapsed = collapsed }
        })
    }

    private func openBrowserAddress() {
        guard launcherAllowed, let id = state.addressableBrowserPage(in: windowTabs) else { return }
        launcherPresented = false
        editingBrowserID = id
        addressFocusRequest &+= 1
    }

    private func closeBrowserAddress() {
        let editedID = editingBrowserID
        editingBrowserID = nil
        guard launcherAllowed, let editedID, state.addressableBrowserPage(in: windowTabs) == editedID,
              let tab = state.browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID == editedID }) else { return }
        state.browserSession.focusPageAfterEditing(tab.id)
    }

    private var launcherAllowed: Bool {
        windowTabs.presentedSheet == nil && !showsAccessModeSettings && !windowTabs.isAPIProvidersPresented
            && !state.approvalGateBlocksInteraction
    }

    private func openLauncher() {
        guard launcherAllowed else { return }
        editingBrowserID = nil
        launcherError = nil
        launcherPresented = true
    }

    private func launch(_ destination: NewTabDestination, text: String) {
        guard launcherPresented, launcherAllowed, !windowTabs.isClosed else { return }
        state.workspaceWindows.withWindow(windowTabs) { openTab(destination, text: text) }
    }

    private func openTab(_ destination: NewTabDestination, text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch destination {
        case .browser:
            guard let url = query.isEmpty ? EmbeddedBrowserURLPolicy.newTabURL : try? EmbeddedBrowserURLPolicy.searchURL(for: query) else { return }
            launcherPresented = false
            state.newWorkspaceBrowserTab(url: url)
        case .agent:
            if state.isReviewPresented { state.toggleReview() }
            do {
                windowTabs.launcherChat = try state.launchNewAgent(prompt: query)
                launcherPresented = false
            } catch { launcherError = error.localizedDescription }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            state.workspaceWindows.withWindow(windowTabs) { workspace(topInset: geometry.safeAreaInsets.top) }
        }
        .onAppear { if windowTabs.showsDesktopChats { state.desktopSidebar?.attach(windowTabs) } }
        .onChange(of: windowTabs.showsDesktopChats) { _, visible in
            if visible { state.desktopSidebar?.attach(windowTabs) }
            else { state.desktopSidebar?.detach(windowTabs) }
        }
        .onDisappear { state.desktopSidebar?.detach(windowTabs) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.desktopSidebar?.becameActive()
        }
        .focusedSceneValue(\.tabWorkspace, state)
        .focusedSceneValue(\.workspaceSidebarCollapsed, launcherAllowed && !commandPanelPresented ? sidebarCollapseBinding : nil)
        .focusedSceneValue(\.browserPageCommandsAllowed, launcherAllowed && !commandPanelPresented)
        .onChange(of: windowTabs.isSidebarCollapsed) { _, _ in sidebarPeeked = false }
        .onChange(of: windowTabs.requestedBrowserAddress, initial: true) { _, requested in
            guard let requested else { return }
            windowTabs.requestedBrowserAddress = nil
            if requested == state.addressableBrowserPage(in: windowTabs) { openBrowserAddress() }
        }
        .onChange(of: windowTabs.launcherChat?.id) { _, request in
            if request != nil && windowTabs.showsNewAgent {
                launcherPresented = false
                editingBrowserID = nil
            }
        }
        .onChange(of: state.addressableBrowserPage(in: windowTabs)) { _, current in
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

    @ViewBuilder private func titlebarAddressEditor(at anchor: Anchor<CGRect>?) -> some View {
        if let anchor, launcherAllowed, let editingBrowserID,
           let tab = state.browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID == editingBrowserID }) {
            GeometryReader { geometry in
                let rect = geometry[anchor]
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: closeBrowserAddress)
                BrowserAddressPalette(state: state, window: windowTabs, tab: tab, focusRequest: addressFocusRequest,
                                      titlebarHeight: rect.height, close: closeBrowserAddress)
                    .id(tab.id)
                    .frame(width: rect.width)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    private func browserPane(rowHeight: CGFloat, topInset: CGFloat, browserPrimary: Bool, titlebarAddress: Bool, windowAddress: Bool, sidebarWidth: CGFloat) -> some View {
        let selectedPageID = state.displayedBrowserTab?.id
        let edit: (() -> Void)? = titlebarAddress && !windowAddress ? { self.openBrowserAddress() } : nil
        return EmbeddedBrowserPane(
            session: state.browserSession,
            tabRowHeight: rowHeight,
            usesSidebarTabs: browserPrimary,
            workspacePageID: browserPrimary ? selectedPageID : nil,
            workspace: (state, windowTabs),
            openTitlebarAddress: edit,
            reservesWindowTitlebar: windowAddress,
            showsNewTabButton: state.workspaceLayout.allowsBrowserSidePane,
            titlebarLeadingInset: titlebarAddress ? max(0, trafficLightClearance - sidebarWidth) : 0,
            titlebarTrailingInset: topInset > 0 && state.workspaceLayout.allowsBrowserSidePane ? BrowserTitlebarToggle.width : 0,
            isInteractionBlocked: state.approvalGateBlocksInteraction || commandPanelPresented,
            canLoadModels: state.canRefreshWebsiteModels,
            modelSetupStatus: state.websiteModelSetupStatus(for:),
            onLoadModels: { id in Task { await state.loadSignedInModels(tabID: id) } },
            canConfigureKimiProfile: state.canConfigureKimiProfile,
            onSwitchKimiProfile: state.switchKimiSignInProfile(from:),
            onCloseTab: { tab in state.workspaceWindows.withWindow(windowTabs) { state.closeWorkspaceTab(tab) } },
            onClose: {
                guard state.workspaceLayout.allowsBrowserSidePane else { return }
                windowTabs.browserIsPrimary = false
                state.workspaceWindows.withWindow(windowTabs) { state.isBrowserPresented = false }
            }
        )
    }

    @ViewBuilder
    private func workspacePanes(@ViewBuilder content: () -> some View) -> some View {
        if state.workspaceLayout.allowsBrowserSidePane {
            HSplitView(content: content)
        } else {
            // The mixed sidebar has a fixed width and draws its own edge below the title bar.
            HStack(spacing: 0, content: content)
        }
    }

    private func workspace(topInset: CGFloat) -> some View {
        // Align the sidebar and any visible pane controls with the native title bar.
        let rowHeight = topInset > 0 ? topInset : 32
        let browserPrimary = state.primaryBrowserID != nil && state.shouldPresentBrowserPane
        let titlebarAddress = browserPrimary && state.browserAddressPlacement == .titleBar
        let windowAddress = titlebarAddress && !state.workspaceLayout.allowsBrowserSidePane
        let compact = state.isTaskSidebarCollapsed && !sidebarPeeked
        let selectedPageID = state.displayedBrowserTab?.id
        let sidebarWidth = compact ? SidebarRailGeometry.compact.width : SidebarRail.expandedWidth
        var snapshot = WebUISnapshot(state: state, titlebarHeight: rowHeight)
        snapshot.trafficLightClearance = trafficLightClearance
        snapshot.isTaskSidebarPeeked = sidebarPeeked
        snapshot.canViewConversation = !windowTabs.showsDesktopChats && controlActiveState == .key && launcherAllowed && !commandPanelPresented
        return ZStack(alignment: .center) {
            workspacePanes {
                CodexWebView(
                    state: state, windowTabs: windowTabs,
                    snapshot: snapshot,
                    sidebarControlsEnabled: launcherAllowed && !commandPanelPresented,
                    setTrafficLightClearance: { trafficLightClearance = $0 },
                    setSidebarPeeked: { sidebarPeeked = $0 },
                    openTabLauncher: openLauncher,
                    openBrowserAddress: openBrowserAddress,
                    consumeLauncherChat: { id, request in
                        guard windowTabs.launcherChat?.taskID == id, windowTabs.launcherChat?.id == request else { return false }
                        windowTabs.launcherChat = nil
                        return windowTabs.presentedTaskID == id && !windowTabs.showsPrimaryBrowser && launcherAllowed && !commandPanelPresented
                    },
                    showAccessModeSettings: { showsAccessModeSettings = true }
                )
                .modifier(WorkspaceShellWidth(browserPrimary: browserPrimary, sidebarWidth: sidebarWidth))
                .animation(
                    browserPrimary && !reduceMotion ? .timingCurve(SidebarRail.transitionCurve, duration: SidebarRail.transitionDuration) : nil,
                    value: compact
                )
                // Each split item has its own safe area. Let the web sidebar
                // paint behind the traffic lights using its actual width and theme.
                .ignoresSafeArea(.container, edges: .top)

                // External pages are sibling views, never children of the
                // privileged Octane document or its script-message bridge.
                // Hiding the pane preserves the session and every tab.
                if state.shouldPresentBrowserPane {
                    browserPane(rowHeight: rowHeight, topInset: topInset, browserPrimary: browserPrimary, titlebarAddress: titlebarAddress, windowAddress: windowAddress, sidebarWidth: sidebarWidth)
                    .frame(minWidth: 360, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    // When this pane opens, the chat already occupies the whole split.
                    // Give the new pane room above its minimum before growing the chat.
                    .layoutPriority(1)
                }
            }
            .overlay(alignment: .top) {
                if windowAddress, let tab = state.displayedBrowserTab {
                    VStack(spacing: 0) {
                        BrowserTitlebarAddressControls(session: state.browserSession, tab: tab, rowHeight: rowHeight,
                                                       edit: openBrowserAddress)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.leading, trafficLightClearance)
                            .frame(height: rowHeight)
                        Divider()
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .allowsHitTesting(!state.approvalGateBlocksInteraction && !commandPanelPresented)
            .accessibilityHidden(state.approvalGateBlocksInteraction || commandPanelPresented)
            .disabled(state.approvalGateBlocksInteraction)
            .overlayPreferenceValue(BrowserAddressBounds.self) { anchor in
                if titlebarAddress { titlebarAddressEditor(at: anchor) }
            }

            if !titlebarAddress, let editingBrowserID, launcherAllowed,
               let tab = state.browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID == editingBrowserID }) {
                ZStack(alignment: Alignment(horizontal: .center, vertical: .commandFieldCenter)) {
                    Color.black.opacity(0.10)
                        .onTapGesture(perform: closeBrowserAddress)
                        .alignmentGuide(.commandFieldCenter) { $0.height / 3 }
                    BrowserAddressPalette(state: state, window: windowTabs, tab: tab, focusRequest: addressFocusRequest, close: closeBrowserAddress)
                        .id(tab.id)
                }
            } else if launcherPresented && launcherAllowed {
                Color.black.opacity(0.10).onTapGesture { launcherPresented = false }
                WorkspaceTabLauncher(library: ChromeProfileLibrary(profile: state.browserSession.workspaceProfileID),
                                     error: launcherError, protectFocus: { field, active in
                    if let selectedPageID { state.browserSession.protectCommandField(field, on: selectedPageID, active: active) }
                }, launch: launch, openPage: { url in
                    guard launcherPresented, launcherAllowed else { return }
                    launcherPresented = false
                    state.workspaceWindows.withWindow(windowTabs) { state.newWorkspaceBrowserTab(url: url) }
                }, cancel: { launcherPresented = false })
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
                    .frame(maxWidth: compact ? SidebarRailGeometry.compact.width : 190, alignment: .leading)
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
        .onChange(of: windowTabs.presentedSheet) { _, sheet in
            if sheet != .settings { showsAccessModeSettings = false }
        }
        .alert("Couldn’t open a browser tab", isPresented: Binding(
            get: { windowTabs.browserTabOpenError != nil }, set: { if !$0 { windowTabs.browserTabOpenError = nil } }
        )) { Button("OK") { windowTabs.browserTabOpenError = nil } } message: {
            Text(windowTabs.browserTabOpenError ?? "")
        }
        .sheet(isPresented: $showsAccessModeSettings) {
            NativeAccessModeSettings(state: state)
        }
        .sheet(isPresented: Binding(get: { windowTabs.isAPIProvidersPresented && !state.approvalGateBlocksInteraction },
            set: { windowTabs.isAPIProvidersPresented = $0 })) {
            APIProviderSettingsView(settings: state.apiProviderSettings, alibabaSetupID: state.alibabaSetupID)
        }
    }
}

// Lay out each intermediate split width. An implicit animation on the WebKit
// surface itself shifts its contents around the center as it resizes.
private nonisolated struct WorkspaceShellWidth: AnimatableModifier {
    let browserPrimary: Bool
    var sidebarWidth: CGFloat

    var animatableData: CGFloat {
        get { sidebarWidth }
        set { sidebarWidth = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(minWidth: browserPrimary ? sidebarWidth : 600,
                   idealWidth: browserPrimary ? sidebarWidth : 640,
                   maxWidth: browserPrimary ? sidebarWidth : .infinity,
                   maxHeight: .infinity, alignment: .leading)
            .transaction { if browserPrimary { $0.animation = nil } }
    }
}

@MainActor
private struct CodexWebView: NSViewRepresentable {
    let state: AppState
    let windowTabs: WorkspaceTabs
    let snapshot: WebUISnapshot
    let sidebarControlsEnabled: Bool
    let setTrafficLightClearance: (CGFloat) -> Void
    let setSidebarPeeked: (Bool) -> Void
    let openTabLauncher: () -> Void
    let openBrowserAddress: () -> Void
    let consumeLauncherChat: (String, UUID) -> Bool
    let showAccessModeSettings: () -> Void

    func makeCoordinator() -> WebBridge {
        WebBridge(state: state, window: windowTabs, consumeLauncherChat: consumeLauncherChat, showAccessModeSettings: showAccessModeSettings)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: WebBridge.handlerName)
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: WebBridge.conversationHandler)
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
        webView.windowTabs = windowTabs
        context.coordinator.onComposerReady = { [weak webView] request in
            webView?.deliverComposerInput(for: request)
        }
        webView.configureTitlebarControls(state: state, tabs: windowTabs)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
#if DEBUG
        webView.isInspectable = true
#endif
        webView.onTrafficLightClearance = setTrafficLightClearance
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
        let railWidth = compact ? snapshot.sidebarRail.width : SidebarRail.expandedWidth
        shell?.discardStaleComposerInput()
        shell?.sidebarWidth = railWidth
        shell?.trackSidebar(width: snapshot.isTaskSidebarCollapsed && sidebarControlsEnabled ? railWidth : 0)
        webView.needsLayout = true
        context.coordinator.update(snapshot: snapshot)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: WebBridge) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WebBridge.handlerName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebBridge.conversationHandler, contentWorld: .page)
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
    weak var windowTabs: WorkspaceTabs?
    var sidebarWidth = SidebarRail.expandedWidth
    var openTabLauncher: (() -> Void)?
    var openBrowserAddress: (() -> Void)?
    let rail = SidebarRail()
    var onTrafficLightClearance: ((CGFloat) -> Void)?
    private var lastTrafficLightClearance: CGFloat?

    // The native view can receive typing before the local document has painted its composer.
    // Keep those events in this window and deliver them once to the acknowledged focus request.
    private var pendingComposerRequest: UUID?
    private var pendingComposerInput: [NSEvent] = []

    private var composerFocusRequest: UUID? {
        guard let tabs = windowTabs, !tabs.isClosed, tabs.showsNewAgent,
              !tabs.showsDesktopChats, let request = tabs.launcherChat, request.taskID == tabs.presentedTaskID,
              tabs.presentedSheet == nil, !tabs.isAPIProvidersPresented, state?.approvalGateBlocksInteraction == false
        else { return nil }
        return request.id
    }

    func discardStaleComposerInput() {
        if pendingComposerRequest != composerFocusRequest {
            pendingComposerInput.removeAll()
            pendingComposerRequest = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let request = composerFocusRequest
        else { super.keyDown(with: event); return }
        discardStaleComposerInput()
        pendingComposerRequest = request
        pendingComposerInput.append(event)
    }

    override func keyUp(with event: NSEvent) {
        guard let request = pendingComposerRequest, composerFocusRequest == request,
              pendingComposerInput.contains(where: { $0.type == .keyDown && $0.keyCode == event.keyCode })
        else { super.keyUp(with: event); return }
        pendingComposerInput.append(event)
    }

    func deliverComposerInput(for request: UUID) {
        guard pendingComposerRequest == request else { return }
        let input = pendingComposerInput
        pendingComposerInput.removeAll()
        pendingComposerRequest = nil
        for event in input {
            if event.type == .keyDown { super.keyDown(with: event) }
            else { super.keyUp(with: event) }
        }
    }

    @objc private func titlebarDidChange(_ notification: Notification) { updateTrafficLightClearance() }

    private func updateTrafficLightClearance() {
        guard let window else { return }
        let frames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> CGRect? in
            guard let button = window.standardWindowButton(kind), button.window === window,
                  !button.isHiddenOrHasHiddenAncestor, !button.bounds.isEmpty else { return nil }
            return button.convert(button.bounds, to: nil)
        }
        // Reserve the window controls and their outer margin only in the browser toolbar.
        let clearance = (frames.map(\.maxX).max() ?? 0) + (frames.map(\.minX).min() ?? 0)
        guard clearance != lastTrafficLightClearance else { return }
        lastTrafficLightClearance = clearance
        // AppKit can lay out the title bar during a SwiftUI update.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, self.lastTrafficLightClearance == clearance else { return }
            self.onTrafficLightClearance?(clearance)
        }
    }

    private var trackedWidth: CGFloat = 0
    private var railArea: NSTrackingArea?
    private var titlebarControls: [NSTitlebarAccessoryViewController] = []

    private weak var state: AppState?
    private let compose = NSButton()

    func configureTitlebarControls(state: AppState, tabs: WorkspaceTabs) {
        self.state = state
        if !state.mixesBrowserTabsInSidebar {
            titlebarControls = [accessory(.left, SidebarTitlebarToggle(state: state, tabs: tabs))]
        }
        guard state.workspaceLayout.allowsBrowserSidePane else { return }
        titlebarControls.append(accessory(.right, BrowserTitlebarToggle(state: state, tabs: tabs)))
        compose.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        compose.imagePosition = .imageOnly
        compose.bezelStyle = .accessoryBarAction
        compose.showsBorderOnlyWhileMouseInside = true
        compose.setAccessibilityLabel("New agent")
        compose.identifier = .init("chat-new")
        compose.toolTip = "New agent (⇧⌘N)"
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
        updateTrafficLightClearance()
        guard let window, let state, let windowTabs, compose.superview != nil else { return }
        compose.isHidden = !window.styleMask.contains(.titled) || windowTabs.presentedSheet != nil || windowTabs.showsPrimaryBrowser
        compose.isEnabled = !state.approvalGateBlocksInteraction
        guard !compose.isHidden else { return }
        let height = window.frame.height - window.contentLayoutRect.maxY
        let top = (height > 0 ? height : 32) / 2 - 11
        let trailing = windowTabs.browserSidePaneOpen ? 6 : BrowserTitlebarToggle.width + 4
        compose.frame = NSRect(x: bounds.maxX - trailing - 28,
                               y: isFlipped ? bounds.minY + top : bounds.maxY - top - 22,
                               width: 28, height: 22)
    }

    @objc private func createChat() {
        guard let state, let windowTabs, !state.approvalGateBlocksInteraction, windowTabs.presentedSheet == nil else { return }
        _ = state.workspaceWindows.withWindow(windowTabs) { state.presentNewAgent() }
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
            lastTrafficLightClearance = nil
            NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
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
        NotificationCenter.default.addObserver(self, selector: #selector(titlebarDidChange(_:)),
                                               name: NSWindow.didUpdateNotification, object: window)
        if let state, let windowTabs {
            state.windowHosting.attach(window, tabs: windowTabs, sidebar: self, width: { [weak self] in self?.sidebarWidth ?? 0 })
        }
        window.title = "Kolmogor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 980, height: 640)
        guard window.styleMask.contains(.titled) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(titlebarDidChange(_:)),
                name: NSView.frameDidChangeNotification, object: button)
        }
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
    let state: AppState
    let tabs: WorkspaceTabs

    var body: some View {
        let showing = tabs.browserSidePaneOpen && !tabs.showsPrimaryBrowser
        Toggle(isOn: Binding(get: { showing }, set: { _ in
            state.workspaceWindows.withWindow(tabs) { state.toggleWorkspaceBrowser() }
        })) {
            Self.globe
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(showing ? Color.accentColor : .secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Browser")
        .accessibilityIdentifier("browser-toggle")
        .help(showing ? "Hide browser" : "Show browser")
        .disabled(tabs.presentedSheet != nil || state.approvalGateBlocksInteraction)
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

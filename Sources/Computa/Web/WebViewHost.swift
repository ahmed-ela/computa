import SwiftUI
import WebKit

@MainActor
struct WebWorkspaceView: View {
    @Bindable var state: AppState
    @State private var showsAccessModeSettings = false

    var body: some View {
        GeometryReader { geometry in
            workspace(topInset: geometry.safeAreaInsets.top)
        }
        .focusedSceneValue(\.tabWorkspace, state)
    }

    private func workspace(topInset: CGFloat) -> some View {
        // The web chat and native browser share one divider below the window controls.
        let rowHeight = topInset > 0 ? topInset : 32
        let browserPrimary = state.primaryBrowserID != nil && state.shouldPresentBrowserPane
        let sidebarWidth: CGFloat = state.isTaskSidebarCollapsed ? 72 : 230
        return ZStack(alignment: .center) {
            HSplitView {
                CodexWebView(
                    state: state,
                    snapshot: WebUISnapshot(state: state, titlebarHeight: rowHeight),
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
                        titlebarTrailingInset: topInset > 0 ? BrowserTitlebarToggle.width : 0,
                        isInteractionBlocked: state.approvalGateBlocksInteraction,
                        canLoadModels: state.canRefreshWebsiteModels,
                        modelSetupStatus: state.websiteModelSetupStatus(for:),
                        onLoadModels: { id in Task { await state.loadSignedInModels(tabID: id) } },
                        canConfigureKimiProfile: state.canConfigureKimiProfile,
                        onSwitchKimiProfile: state.switchKimiSignInProfile(from:),
                        onClose: {
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
            .allowsHitTesting(!state.approvalGateBlocksInteraction)
            .accessibilityHidden(state.approvalGateBlocksInteraction)
            .disabled(state.approvalGateBlocksInteraction)

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
                NativeRuntimeStatusBar(state: state)
                    .frame(maxWidth: state.isTaskSidebarCollapsed ? 72 : 190, alignment: .leading)
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
    let showAccessModeSettings: () -> Void

    func makeCoordinator() -> WebBridge {
        WebBridge(state: state, showAccessModeSettings: showAccessModeSettings)
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
        webView.configureTitlebarControls(state: state)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
#if DEBUG
        webView.isInspectable = true
#endif
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
    private var titlebarControls: [NSTitlebarAccessoryViewController] = []

    func configureTitlebarControls(state: AppState) {
        titlebarControls = [
            accessory(.left, SidebarTitlebarToggle(state: state)),
            accessory(.right, BrowserTitlebarToggle(state: state))
        ]
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
        // The web sidebar paints the title bar, but AppKit owns window dragging there.
        if let window, let superview, superview.convert(point, to: nil).y >= window.contentLayoutRect.maxY {
            return nil
        }
        return super.hitTest(point)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
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

private struct SidebarTitlebarToggle: View {
    @Bindable var state: AppState

    var body: some View {
        Button {
            state.isTaskSidebarCollapsed.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("task-sidebar-toggle")
        .accessibilityLabel(state.isTaskSidebarCollapsed ? "Expand chat sidebar" : "Collapse chat sidebar")
        .help(state.isTaskSidebarCollapsed ? "Expand chat sidebar" : "Collapse chat sidebar")
        .disabled(state.presentedSheet != nil || state.approvalGateBlocksInteraction)
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

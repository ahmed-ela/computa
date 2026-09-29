import SwiftUI
import WebKit

@MainActor
struct WebWorkspaceView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .center) {
                HSplitView {
                    CodexWebView(
                        state: state,
                        snapshot: WebUISnapshot(state: state)
                    )
                    .frame(minWidth: 600, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)

                    // External pages are sibling views, never children of the
                    // privileged Octane document or its script-message bridge.
                    // Hiding the pane preserves the session and every tab.
                    if state.shouldPresentBrowserPane {
                        EmbeddedBrowserPane(
                            session: state.browserSession,
                            isInteractionBlocked: state.approvalGateBlocksInteraction,
                            onClose: { state.isBrowserPresented = false }
                        )
                        .frame(minWidth: 360, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .allowsHitTesting(!state.approvalGateBlocksInteraction)
                .accessibilityHidden(state.approvalGateBlocksInteraction)
                .disabled(state.approvalGateBlocksInteraction)

                // The web surface stays inert through approval settlement.
                // The separate native mode menu remains a human-controlled way
                // to switch modes, including while an action awaits approval.
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
            Divider()
            NativeRuntimeStatusBar(state: state)
                .frame(height: 34)
        }
        .ignoresSafeArea()
    }
}

@MainActor
private struct CodexWebView: NSViewRepresentable {
    let state: AppState
    let snapshot: WebUISnapshot

    func makeCoordinator() -> WebBridge {
        WebBridge(state: state)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: WebBridge.handlerName)

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
    <main><h2>Computa UI is unavailable</h2>
    <p>The bundled Octane assets could not be found. Rebuild WebUI before packaging the app.</p></main>
    """
}

@MainActor
private final class WindowConfiguredWebView: WKWebView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.title = "Computa"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 980, height: 640)
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

import AppKit
import AuthenticationServices
import CryptoKit
import Security
import WebKit

/// Account pages live outside the agent browser and never receive its native message handlers.
@MainActor
final class WorkspaceAccountWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, ASWebAuthenticationPresentationContextProviding {
    static let shared = WorkspaceAccountWindow()
    private let origin = URL(string: "https://accounts.kolmogor.com")!
    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "55E68BF1-A880-4C3C-A0DE-039D23F04A84")!)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }
    private var web: WKWebView?
    private lazy var window: NSWindow = {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
        panel.title = "Kolmogor Workspace"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        return panel
    }()
    private var authentication: ASWebAuthenticationSession?
    private var activeAttempt: UUID?

    func open() {
        window.makeKeyAndOrderFront(nil)
        if web == nil {
            let view = makeWebView()
            web = view
            window.contentView = view
            view.load(URLRequest(url: origin))
        }
    }

    func windowWillClose(_ notification: Notification) {
        activeAttempt = nil
        authentication?.cancel()
        authentication = nil
        web?.stopLoading()
        window.contentView = nil
        web = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain, failure.code != NSURLErrorCancelled,
              window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t reach your workspace"
        alert.informativeText = "Check your internet connection, then try again."
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            if result == .alertFirstButtonReturn { self.web?.load(URLRequest(url: self.origin)) }
            else { self.window.close() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }

    private func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func signIn() {
        guard authentication == nil else { return }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { return }
        let verifier = encode(Data(random))
        let challenge = encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let start = origin.appending(path: "auth/google").appending(queryItems: [URLQueryItem(name: "challenge", value: challenge)])
        let attempt = UUID()
        activeAttempt = attempt
        // AuthenticationServices can deliver this completion on a background dispatch queue.
        let session = ASWebAuthenticationSession(url: start, callbackURLScheme: "kolmogor-account") { @Sendable [weak self] url, _ in
            Task { @MainActor in
                guard let self, self.activeAttempt == attempt else { return }
                self.activeAttempt = nil
                self.authentication = nil
                guard let url, url.scheme == "kolmogor-account", url.host == "complete",
                      let ticket = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ticket" })?.value,
                      ticket.wholeMatch(of: /[A-Za-z0-9_-]{43}/) != nil else { return }
                var request = URLRequest(url: self.origin.appending(path: "auth/redeem"))
                request.httpMethod = "POST"
                request.setValue(self.origin.absoluteString, forHTTPHeaderField: "Origin")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("ticket=\(ticket)&verifier=\(verifier)".utf8)
                self.web?.load(request)
                self.window.makeKeyAndOrderFront(nil)
            }
        }
        session.presentationContextProvider = self
        authentication = session
        if !session.start() {
            activeAttempt = nil
            authentication = nil
            let alert = NSAlert()
            alert.messageText = "Google sign-in could not open."
            alert.informativeText = "Check that a default web browser is available, then try again."
            alert.beginSheetModal(for: window)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, url.scheme == "https", url.port == nil,
              url.user == nil, url.password == nil else { return .cancel }
        if url.host == origin.host, action.targetFrame?.isMainFrame == true {
            if url.path == "/auth/google" {
                if action.navigationType == .linkActivated { signIn() }
                return .cancel
            }
            return .allow
        }
        if action.navigationType == .linkActivated, action.sourceFrame.isMainFrame,
           ["auth.openai.com", "chatgpt.com", "claude.ai", "platform.claude.com",
            "console.anthropic.com"].contains(url.host) {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}

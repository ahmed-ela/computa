import AppKit
import Foundation
import WebKit

@MainActor
final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let handlerName = "localCodex"
    static var diagnosticsEnabled: Bool {
        ProcessInfo.processInfo.environment["COMPUTA_WEBUI_DIAGNOSTICS"] == "1"
    }
    static let diagnosticBootstrapScript = """
    window.addEventListener('error', event => {
      window.webkit.messageHandlers.localCodex.postMessage({
        action: 'webClientFailure', kind: event.error?.name || 'ResourceError',
        line: Number(event.lineno || 0)
      });
    }, true);
    window.addEventListener('unhandledrejection', event => {
      window.webkit.messageHandlers.localCodex.postMessage({
        action: 'webClientFailure', kind: event.reason?.name || 'PromiseRejection', line: 0
      });
    });
    """

    private weak var state: AppState?
    private weak var webView: WKWebView?
    private var latestSnapshot: WebUISnapshot?
    private var latestContent: Data?
    private var nextRevision: UInt64 = 0
    private var pageIsReady = false
    private let openScreenRecordingSettings: (URL) -> Bool

    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!
    static let systemSettingsAppURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    init(
        state: AppState,
        openScreenRecordingSettings: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.state = state
        self.openScreenRecordingSettings = openScreenRecordingSettings
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        Self.diagnostic("attached frame=\(webView.frame) bounds=\(webView.bounds) safeArea=\(webView.safeAreaInsets)")
    }

    func update(snapshot baseSnapshot: WebUISnapshot) {
        var contentSnapshot = baseSnapshot
        contentSnapshot.revision = 0

        guard let content = try? Self.encoder.encode(contentSnapshot), content != latestContent else {
            return
        }

        latestContent = content
        nextRevision &+= 1
        var versionedSnapshot = baseSnapshot
        versionedSnapshot.revision = nextRevision
        latestSnapshot = versionedSnapshot
        Self.diagnostic("snapshot revision=\(nextRevision) tasks=\(versionedSnapshot.tasks.count) ready=\(pageIsReady)")
        pushLatestSnapshotIfReady()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        receive(message)
    }

    private func receive(_ message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              message.frameInfo.isMainFrame,
              message.webView === webView,
              WebUIResourceLocator.contains(webView?.url),
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else {
            return
        }

        guard let state else { return }

        switch action {
        case "ready":
            pageIsReady = true
            if let webView {
                Self.diagnostic("client ready frame=\(webView.frame) bounds=\(webView.bounds) safeArea=\(webView.safeAreaInsets)")
            }
            pushLatestSnapshotIfReady()

        case "webClientFailure":
            guard Self.diagnosticsEnabled else { return }
            let reported = body["kind"] as? String ?? "UnknownError"
            let allowed = ["Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError", "EvalError", "URIError", "AggregateError", "ResourceError", "PromiseRejection"]
            let kind = allowed.contains(reported) ? reported : "UnknownError"
            let line = body["line"] as? Int ?? 0
            Self.diagnostic("client failure kind=\(kind) line=\(line)")

        case "selectTask":
            guard let id = body["id"] as? String,
                  state.tasks.contains(where: { $0.id == id })
            else { return }
            state.selectTask(id)

        case "selectEntry":
            guard let id = body["id"] as? String,
                  state.selectedTask?.entries.contains(where: { $0.id == id }) == true
            else { return }
            state.selectedEntryID = id

        case "createTask":
            state.createTask()

        case "submitPrompt":
            guard let prompt = body["prompt"] as? String,
                  let taskID = body["taskID"] as? String,
                  let requestID = body["requestID"] as? String
            else { return }
            state.acceptPrompt(prompt: prompt, taskID: taskID, requestID: requestID)

        case "beginQueueEdit", "editQueuedPrompt", "cancelQueueEdit", "deleteQueuedPrompt", "moveQueuedPrompt", "steerQueuedPrompt":
            guard let taskID = body["taskID"] as? String,
                  let id = body["id"] as? String,
                  state.tasks.contains(where: { $0.id == taskID }) else { return }
            switch action {
            case "beginQueueEdit":
                state.beginQueueEdit(taskID: taskID, id: id)
            case "editQueuedPrompt":
                guard let prompt = body["prompt"] as? String else { return }
                state.editQueuedPrompt(taskID: taskID, id: id, prompt: prompt)
            case "cancelQueueEdit":
                state.cancelQueueEdit(taskID: taskID, id: id)
            case "deleteQueuedPrompt":
                state.deleteQueuedPrompt(taskID: taskID, id: id)
            case "moveQueuedPrompt":
                guard let before = body["beforeID"], before is String || before is NSNull else { return }
                state.moveQueuedPrompt(taskID: taskID, id: id, beforeID: before as? String)
            case "steerQueuedPrompt":
                state.requestSteerQueuedPrompt(taskID: taskID, id: id)
            default: break
            }

        case "resumeQueue":
            guard let taskID = body["taskID"] as? String,
                  state.tasks.contains(where: { $0.id == taskID }) else { return }
            Task { @MainActor [weak state] in await state?.resumeQueue(taskID: taskID) }

        case "interruptTask":
            guard let taskID = body["taskID"] as? String,
                  state.tasks.contains(where: { $0.id == taskID && $0.status == .running })
            else { return }
            // Pause before yielding: completion cannot start a queued message
            // between receipt of Stop and the asynchronous interrupt operation.
            state.pausedQueueTaskIDs.insert(taskID)
            Task { @MainActor [weak state] in
                await state?.interrupt(taskID: taskID)
            }

        case "toggleInspector":
            state.isInspectorPresented.toggle()

        case "toggleBrowser":
            guard !state.approvalGateBlocksInteraction else { return }
            state.isBrowserPresented.toggle()

        case "showSettings":
            state.refreshAutomationPermissions()
            state.presentedSheet = .settings

        case "dismissSettings":
            state.presentedSheet = nil

        case "setAppearance":
            guard let value = body["value"] as? String,
                  let appearance = AppAppearance(rawValue: value)
            else { return }
            state.appearance = appearance

        case "setDefaultModel":
            guard let modelID = body["modelID"] as? String else { return }
            state.setDefaultModel(modelID)

        case "setTaskModel":
            guard let modelID = body["modelID"] as? String,
                  let taskID = body["taskID"] as? String
            else { return }
            state.setTaskModel(modelID, taskID: taskID)

        case "setShowToolPayloads":
            guard let value = body["value"] as? Bool else { return }
            state.showToolPayloads = value

        case "refreshPermissions":
            state.refreshAutomationPermissions()

        case "requestAccessibilityPermission":
            state.requestAccessibilityPermission()

        case "requestScreenRecordingPermission":
            requestScreenRecordingPermission()

        default:
            return
        }
    }

    /// Only the human-operated Settings action reaches this method. Opening
    /// System Settings does not change TCC authorization; the user must grant it.
    func requestScreenRecordingPermission() {
        guard let state else { return }
        state.requestScreenRecordingPermission()
        guard state.automationPermissions.screenRecording == .notGranted else { return }
        if !openScreenRecordingSettings(Self.screenRecordingSettingsURL) {
            _ = openScreenRecordingSettings(Self.systemSettingsAppURL)
        }
    }

    private func pushLatestSnapshotIfReady() {
        guard pageIsReady, let snapshot = latestSnapshot, let webView else { return }

        do {
            let data = try Self.encoder.encode(snapshot)
            let object = try JSONSerialization.jsonObject(with: data)
            webView.callAsyncJavaScript(
                "window.__localCodexReceiveState?.(snapshot)",
                arguments: ["snapshot": object],
                in: nil,
                in: .page
            ) { [weak self] result in
                guard Self.diagnosticsEnabled else { return }
                switch result {
                case .success: Self.diagnostic("snapshot applied revision=\(snapshot.revision)")
                case .failure(let error):
                    let value = error as NSError
                    Self.diagnostic("snapshot failed domain=\(value.domain) code=\(value.code)")
                }
                self?.diagnosePage(webView)
            }
        } catch {
            assertionFailure("Could not send the Computa web snapshot: \(error)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.diagnostic("navigation finished trusted=\(WebUIResourceLocator.contains(webView.url)) frame=\(webView.frame) bounds=\(webView.bounds) safeArea=\(webView.safeAreaInsets)")
        diagnosePage(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let value = error as NSError
        Self.diagnostic("navigation failed domain=\(value.domain) code=\(value.code)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let value = error as NSError
        Self.diagnostic("provisional navigation failed domain=\(value.domain) code=\(value.code)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.diagnostic("web content process terminated")
    }

    private func diagnosePage(_ webView: WKWebView) {
        guard Self.diagnosticsEnabled else { return }
        webView.evaluateJavaScript("JSON.stringify({ready:document.readyState,rootNodes:document.getElementById('root')?.childNodes.length || 0,rootTextLength:document.getElementById('root')?.innerText.length || 0,appShell:!!document.querySelector('.app-shell'),receiver:typeof window.__localCodexReceiveState,width:innerWidth,height:innerHeight})") { value, error in
            if let value = value as? String { Self.diagnostic("page \(value)") }
            else if let error {
                let value = error as NSError
                Self.diagnostic("page probe failed domain=\(value.domain) code=\(value.code)")
            }
        }
    }

    private static func diagnostic(_ message: String) {
        guard diagnosticsEnabled else { return }
        NSLog("ComputaWebUI %@", message)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }

        if WebUIResourceLocator.contains(url) {
            return .allow
        }

        if url.scheme == "about" {
            return .allow
        }

        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

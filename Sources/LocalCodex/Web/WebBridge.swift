import AppKit
import Foundation
import WebKit

@MainActor
final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let handlerName = "localCodex"

    private weak var state: AppState?
    private weak var webView: WKWebView?
    private var latestSnapshot: WebUISnapshot?
    private var latestContent: Data?
    private var nextRevision: UInt64 = 0
    private var pageIsReady = false

    init(state: AppState) {
        self.state = state
    }

    func attach(webView: WKWebView) {
        self.webView = webView
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
            pushLatestSnapshotIfReady()

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
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.utf8.count <= 200_000,
                  let taskID = state.selectedTaskID,
                  state.tasks.contains(where: { $0.id == taskID })
            else { return }
            Task { @MainActor [weak state] in
                await state?.submit(prompt: prompt, toTaskID: taskID)
            }

        case "toggleInspector":
            state.isInspectorPresented.toggle()

        case "showSettings":
            state.presentedSheet = .settings

        case "dismissSettings":
            state.presentedSheet = nil

        case "setAppearance":
            guard let value = body["value"] as? String,
                  let appearance = AppAppearance(rawValue: value)
            else { return }
            state.appearance = appearance

        case "setShowToolPayloads":
            guard let value = body["value"] as? Bool else { return }
            state.showToolPayloads = value

        case "refreshPermissions":
            state.refreshAutomationPermissions()

        default:
            return
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
            ) { _ in }
        } catch {
            assertionFailure("Could not send the LocalCodex web snapshot: \(error)")
        }
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

import AppKit
import SwiftUI

/// Edits the address of one human browser tab. The new-tab launcher has a separate destination.
struct BrowserAddressPalette: View {
    static let requestNotification = Notification.Name("Kolmogor.EditBrowserAddress")

    static func request(in window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.post(name: requestNotification, object: window)
    }

    let state: AppState
    let tab: EmbeddedBrowserTab
    let focusRequest: Int
    let close: () -> Void
    @State private var text: String
    @State private var selectedIndex = 0
    @State private var error: String?
    @State private var imported = ChromeProfileLibrary.Results()

    init(state: AppState, tab: EmbeddedBrowserTab, focusRequest: Int, close: @escaping () -> Void) {
        self.state = state
        self.tab = tab
        self.focusRequest = focusRequest
        self.close = close
        _text = State(initialValue: tab.url?.absoluteString ?? "")
    }

    private enum Choice: Hashable {
        case navigate, switchTab(UUID), importedPage(URL), back, forward, reload
    }

    private struct Row: Identifiable {
        let id: Choice
        let title: String
        let symbol: String
    }

    private func rows(for text: String) -> [Row] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [Row] = []
        if !query.isEmpty {
            let url = try? EmbeddedBrowserURLPolicy.normalize(query)
            let search = url != nil && url == (try? EmbeddedBrowserURLPolicy.searchURL(for: query))
            rows.append(Row(id: .navigate, title: search ? "Search Google for “\(query)”" : "Go to \(query)",
                            symbol: search ? "magnifyingglass" : "arrow.up.right"))
        }
        func matches(_ candidate: String) -> Bool { query.isEmpty || candidate.localizedCaseInsensitiveContains(query) }
        for other in state.browserSession.workspaceBrowserTabs where other.id != tab.id {
            let title = other.title.isEmpty ? other.url?.host ?? "New tab" : other.title
            if matches(title) || matches(other.url?.absoluteString ?? "") {
                rows.append(Row(id: .switchTab(other.workspaceID), title: "Switch to \(title)", symbol: "rectangle.on.rectangle"))
            }
            if rows.count >= 5 { break }
        }
        if imported.query == text {
            for place in imported.entries {
                rows.append(Row(id: .importedPage(place.url), title: place.label, symbol: place.bookmark ? "bookmark" : "clock"))
            }
        }
        if tab.canGoBack && matches("Back") { rows.append(Row(id: .back, title: "Back", symbol: "chevron.left")) }
        if tab.canGoForward && matches("Forward") { rows.append(Row(id: .forward, title: "Forward", symbol: "chevron.right")) }
        let reload = tab.isLoading ? "Stop loading" : "Reload"
        if matches(reload) { rows.append(Row(id: .reload, title: reload, symbol: tab.isLoading ? "xmark" : "arrow.clockwise")) }
        return rows
    }

    var body: some View {
        let choices = rows(for: text)
        WorkspaceCommandPanel(width: 460) {
            WorkspaceCommandField(text: Binding(get: { text }, set: { value in
                text = value
                selectedIndex = 0
                error = nil
            }), placeholder: "Search or enter a website address",
                label: "Website address", identifier: "browser-address", focusRequest: focusRequest,
                move: { selectedIndex = min(max(0, selectedIndex + $0), max(0, choices.count - 1)) },
                submit: { value in
                    let current = rows(for: value)
                    if let row = current.dropFirst(value == text ? selectedIndex : 0).first { perform(row.id, value) }
                }, cancel: close)
        } choices: {
            if !choices.isEmpty { Divider() }
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, row in
                WorkspaceCommandRow(title: row.title, icon: Image(systemName: row.symbol), selected: selectedIndex == index) {
                    perform(row.id, text)
                }
            }
            if let error { Text(error).foregroundStyle(.secondary).padding(.horizontal, 8) }
        }
        .task(id: text) {
            let results = await ChromeProfileLibrary.Results.search(text, in: ChromeProfileLibrary(profile: state.browserSession.workspaceProfileID))
            if !Task.isCancelled { imported = results }
        }
        .onChange(of: choices.count) { _, count in selectedIndex = min(selectedIndex, max(0, count - 1)) }
    }

    private func perform(_ choice: Choice, _ input: String) {
        let session = state.browserSession
        guard state.primaryBrowserID == tab.workspaceID, session.selectedTabID == tab.id,
              !state.approvalGateBlocksInteraction, state.presentedSheet == nil else { close(); return }
        switch choice {
        case .navigate:
            do { try session.navigate(tabID: tab.id, to: EmbeddedBrowserURLPolicy.normalize(input)) }
            catch { self.error = error.localizedDescription; return }
        case .importedPage(let url):
            do { try session.navigate(tabID: tab.id, to: url) }
            catch { self.error = error.localizedDescription; return }
        case .switchTab(let id): state.selectWorkspaceTab(.browser(id))
        case .back: session.goBack(tabID: tab.id)
        case .forward: session.goForward(tabID: tab.id)
        case .reload: if tab.isLoading { session.stop(tabID: tab.id) } else { session.reload(tabID: tab.id) }
        }
        close()
    }
}

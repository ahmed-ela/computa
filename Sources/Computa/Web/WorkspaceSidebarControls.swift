import SwiftUI

@MainActor
final class SidebarRail: NSResponder {
    static let compactWidth: CGFloat = 44
    static let expandedWidth: CGFloat = 230
    var onHover: (Bool) -> Void = { _ in }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

struct SidebarTitlebarToggle: View {
    @Bindable var state: AppState

    var body: some View {
        let label = state.isTaskSidebarCollapsed ? "Expand chat sidebar" : "Collapse chat sidebar"
        Button { state.isTaskSidebarCollapsed.toggle() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("task-sidebar-toggle")
        .accessibilityLabel(label)
        .help(label)
        .disabled(state.presentedSheet != nil || state.approvalGateBlocksInteraction)
    }
}

/// The same session controls serve the sidebar title bar and the split browser pane.
struct BrowserHistoryButtons: View {
    let session: EmbeddedBrowserSession

    var body: some View {
        let selectedTab = session.selectedTabID.flatMap(session.humanTab(id:))
        HStack(spacing: 2) {
            Button {
                if let id = selectedTab?.id { session.goBack(tabID: id) }
            } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
            .disabled(selectedTab?.canGoBack != true)
            .help("Back")
            .accessibilityLabel("Back")

            Button {
                if let id = selectedTab?.id { session.goForward(tabID: id) }
            } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle()) }
            .disabled(selectedTab?.canGoForward != true)
            .help("Forward")
            .accessibilityLabel("Forward")

            Button {
                guard let tab = selectedTab else { return }
                if tab.isLoading { session.stop(tabID: tab.id) }
                else { session.reload(tabID: tab.id) }
            } label: {
                Image(systemName: selectedTab?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(selectedTab == nil || (selectedTab?.url == nil && selectedTab?.isLoading != true))
            .help(selectedTab?.isLoading == true ? "Stop loading" : "Reload")
            .accessibilityLabel(selectedTab?.isLoading == true ? "Stop loading" : "Reload")
        }
        .buttonStyle(.borderless)
    }
}

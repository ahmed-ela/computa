import SwiftUI

struct SidebarRailGeometry: Codable, Equatable, Sendable {
    let width: CGFloat
    let iconCenter: CGFloat

    // A borderless window or a web-only preview has no native traffic lights.
    static let fallback = Self(width: 44, iconCenter: 22)

    @MainActor
    static func measured(in window: NSWindow) -> Self? {
        func frame(_ kind: NSWindow.ButtonType) -> CGRect? {
            guard let button = window.standardWindowButton(kind), button.window === window,
                  !button.isHiddenOrHasHiddenAncestor, !button.bounds.isEmpty else { return nil }
            return button.convert(button.bounds, to: nil)
        }
        guard let red = frame(.closeButton), let yellow = frame(.miniaturizeButton), let green = frame(.zoomButton),
              red.minX >= 0, red.maxX <= yellow.minX, yellow.maxX <= green.minX else { return nil }
        return Self(width: green.maxX + red.minX, iconCenter: yellow.midX)
    }
}

@MainActor
final class SidebarRail: NSResponder {
    static let expandedWidth: CGFloat = 230
    static let transitionDuration: TimeInterval = 0.14
    static let transitionCurve = UnitCurve.bezier(
        startControlPoint: .init(x: 0.65, y: 0), endControlPoint: .init(x: 0.35, y: 1)
    )
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

struct BrowserHistoryButtons: View {
    let session: EmbeddedBrowserSession
    let selectedTab: EmbeddedBrowserTab?

    var body: some View {
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

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

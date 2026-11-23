import SwiftUI

@MainActor
final class SidebarRail: NSResponder {
    static let compactWidth: CGFloat = 44
    static let expandedWidth: CGFloat = 230
    var onHover: (Bool) -> Void = { _ in }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

@MainActor
final class SidebarTitlebarSearch: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let searchButton = NSButton()
    private let state: AppState
    private let changed: (String) -> Void
    private var lastQuery = ""

    init(state: AppState, changed: @escaping (String) -> Void) {
        self.state = state
        self.changed = changed
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 22))
        let toggle = NSHostingView(rootView: SidebarTitlebarToggle(state: state))
        toggle.frame = NSRect(x: 0, y: 0, width: 28, height: 22)
        addSubview(toggle)
        let label = state.mixesBrowserTabsInSidebar ? "Search tabs" : "Search chats"
        field.placeholderString = "Search"
        field.setAccessibilityLabel(label)
        field.identifier = .init("task-sidebar-search-field")
        field.controlSize = .small
        field.isBezeled = false
        field.drawsBackground = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.target = self
        field.action = #selector(queryChanged)
        field.frame = NSRect(x: 28, y: 1, width: 86, height: 20)
        addSubview(field)
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchButton.imagePosition = .imageOnly
        searchButton.bezelStyle = .accessoryBarAction
        searchButton.showsBorderOnlyWhileMouseInside = true
        searchButton.setAccessibilityLabel(label)
        searchButton.toolTip = "Search (⌘K)"
        searchButton.target = self
        searchButton.action = #selector(focusSearch)
        searchButton.frame = NSRect(x: 28, y: 0, width: 22, height: 22)
        addSubview(searchButton)
        update(compact: state.isTaskSidebarCollapsed, enabled: true)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        for control in subviews {
            control.setFrameOrigin(NSPoint(x: control.frame.minX, y: (bounds.height - control.frame.height) / 2))
        }
    }

    func update(compact: Bool, enabled: Bool) {
        field.isEnabled = enabled
        searchButton.isEnabled = enabled
        if compact, field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        field.isHidden = compact
        searchButton.isHidden = !compact
        let width = compact ? searchButton.frame.maxX : field.frame.maxX
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
    }

    @objc func focusSearch() {
        guard let window, field.isEnabled, state.presentedSheet == nil, !state.approvalGateBlocksInteraction else { return }
        if state.isTaskSidebarCollapsed { state.isTaskSidebarCollapsed = false }
        update(compact: false, enabled: true)
        window.makeFirstResponder(field)
    }

    func clear() {
        field.stringValue = ""
        queryChanged()
    }

    func controlTextDidChange(_ notification: Notification) { queryChanged() }

    func restoreQuery() { changed(field.stringValue) }

    @objc private func queryChanged() {
        guard lastQuery != field.stringValue else { return }
        lastQuery = field.stringValue
        restoreQuery()
    }
}

private struct SidebarTitlebarToggle: View {
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

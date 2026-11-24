import AppKit
import WebKit

/// The app owns this drag. Browser documents and the system pasteboard never receive
/// a tab handle. Coordinates are converted in each window's own point space.
@MainActor
final class WorkspaceWindowHosting: NSObject {
    @MainActor private final class Host {
        weak var window: NSWindow?
        weak var sidebar: WKWebView?
        let tabs: WorkspaceTabs
        let width: () -> CGFloat
        init(_ window: NSWindow, _ sidebar: WKWebView, _ tabs: WorkspaceTabs, width: @escaping () -> CGFloat) {
            self.window = window
            self.sidebar = sidebar
            self.tabs = tabs
            self.width = width
        }

        var sidebarFrame: CGRect? {
            guard let window, let sidebar, sidebar.window === window, !sidebar.isHiddenOrHasHiddenAncestor else { return nil }
            var rect = sidebar.visibleRect
            rect.size.width = min(rect.width, width())
            return window.convertToScreen(sidebar.convert(rect, to: nil))
        }

        func row(at point: CGPoint) async -> WorkspaceTabID? {
            guard let window, let sidebar else { return nil }
            let local = sidebar.convert(window.convertPoint(fromScreen: point), from: nil)
            let y = sidebar.isFlipped ? local.y : sidebar.bounds.height - local.y
            let result = try? await sidebar.callAsyncJavaScript("""
                const row = document.elementFromPoint(x, y)?.closest('.workspace-tab-row[draggable="true"]');
                if (!row) return null;
                const bounds = row.getBoundingClientRect();
                return [row.dataset.dragKind, row.dataset.dragId, y < bounds.top + bounds.height / 2 ? 'before' : 'after'];
                """, arguments: ["x": local.x, "y": y], in: nil, contentWorld: .page)
            guard let fields = result as? [String], fields.count == 3, let kind = WorkspaceTabID.Kind(rawValue: fields[0]) else { return nil }
            let row = WorkspaceTabID(kind: kind, id: fields[1])
            guard fields[2] == "after", let index = tabs.order.firstIndex(of: row) else { return row }
            return tabs.order.dropFirst(index + 1).first
        }
    }

    private enum Drag {
        case tab(WorkspaceTabID)
        case window(origin: CGPoint)
    }
    private struct PendingDetach {
        let tab: WorkspaceTabID
        let source: WorkspaceTabs
        let point: CGPoint
    }

    private weak var state: AppState?
    private var hosts: [UUID: Host] = [:]
    private var pending: [UUID: PendingDetach] = [:]
    var openScene: ((UUID) -> Void)?
    private var source: Host?
    private var drag: Drag?
    private var highlighted: Host?
    private var monitor: Any?
    private var releaseTimer: Timer?
    private var badge: NSPanel?

    init(state: AppState) {
        self.state = state
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive(_:)), name: NSApplication.didResignActiveNotification, object: nil)
    }

    func attach(_ window: NSWindow, tabs: WorkspaceTabs, sidebar: WKWebView, width: @escaping () -> CGFloat) {
        guard let state, !tabs.isClosed else { return }
        if hosts[tabs.id]?.sidebar === sidebar && hosts[tabs.id]?.window === window { return }
        let host = Host(window, sidebar, tabs, width: width)
        hosts[tabs.id] = host
        let center = NotificationCenter.default
        for (selector, name) in [(#selector(focused(_:)), NSWindow.didBecomeKeyNotification),
                                 (#selector(closed(_:)), NSWindow.willCloseNotification),
                                 (#selector(willMove(_:)), NSWindow.willMoveNotification)] {
            center.removeObserver(self, name: name, object: window)
            center.addObserver(self, selector: selector, name: name, object: window)
        }
        window.tabbingMode = .disallowed
        if tabs !== state.workspaceWindows.primary { window.isRestorable = false }
        if window.isKeyWindow { state.focusWorkspace(tabs) }
        if let move = pending.removeValue(forKey: tabs.id) {
            // Scene creation is asynchronous. Keep the original tab until there
            // is a real destination window, then recheck its ownership.
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, !tabs.isClosed else { return }
                if self.hosts[move.source.id]?.window?.isVisible == true,
                   state.transferTabs([move.tab], from: move.source, to: tabs) {
                    self.place(window, at: move.point)
                    self.closeIfEmpty(move.source)
                } else { window.close() }
            }
        }
    }

    func newWindow() {
        guard let state, let openScene else { return }
        openScene(state.workspaceWindows.createTemporary().id)
    }

    func bringForward(_ tabs: WorkspaceTabs) { hosts[tabs.id]?.window?.makeKeyAndOrderFront(nil) }

    func closeTabOrWindow(_ window: NSWindow?, inBrowserPane: Bool) {
        guard let state, let window, let host = host(for: window), window.attachedSheet == nil,
              !state.approvalGateBlocksInteraction, host.tabs.presentedSheet == nil, !host.tabs.isAPIProvidersPresented else { return }
        state.workspaceWindows.withWindow(host.tabs) {
            if let tab = state.commandTab(inBrowserPane: inBrowserPane) { state.closeWorkspaceTab(tab) }
        }
        if host.tabs.order.isEmpty { window.performClose(nil) }
    }

    private func host(for window: NSWindow) -> Host? {
        hosts.values.first { $0.window === window }
    }

    private func host(_ notification: Notification) -> Host? {
        guard let window = notification.object as? NSWindow else { return nil }
        return host(for: window)
    }

    @objc private func focused(_ note: Notification) {
        if let host = host(note) { state?.focusWorkspace(host.tabs) }
    }

    @objc private func closed(_ note: Notification) {
        guard let host = host(note), let window = host.window else { return }
        if source === host || highlighted === host { cancelDrag() }
        hosts.removeValue(forKey: host.tabs.id)
        NotificationCenter.default.removeObserver(self, name: nil, object: window)
        state?.discardTemporaryWindow(host.tabs)
    }

    func beginTabDrag(_ tab: WorkspaceTabID, from tabs: WorkspaceTabs, sidebar: WKWebView) {
        guard let state, let host = hosts[tabs.id], host.sidebar === sidebar,
              state.canTransferTabs(from: tabs, to: tabs), tabs.order.contains(tab),
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        track(.tab(tab), from: host)
        let title: String
        if tab.kind == .agent {
            title = state.tasks.first { $0.id == tab.id }.map { tabs.agent(for: $0)?.name ?? $0.title } ?? "Agent"
        } else {
            title = state.browserSession.workspaceBrowserTabs.first { $0.workspaceID.uuidString == tab.id }?.title ?? "Browser tab"
        }
        let label = NSTextField(labelWithString: title.isEmpty ? "Browser tab" : title)
        label.lineBreakMode = .byTruncatingTail
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: min(220, max(72, label.intrinsicContentSize.width + 24)), height: 28),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let bubble = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        bubble.material = .popover
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 7
        label.frame = bubble.bounds.insetBy(dx: 10, dy: 5)
        bubble.addSubview(label)
        panel.contentView = bubble
        badge = panel
        updateDrag(at: NSEvent.mouseLocation)
        panel.orderFront(nil)
    }

    @objc private func willMove(_ note: Notification) {
        guard drag == nil, NSEvent.pressedMouseButtons & 1 != 0, let host = host(note), let window = host.window,
              let state, !host.tabs.order.isEmpty, state.canTransferTabs(from: host.tabs, to: host.tabs) else { return }
        track(.window(origin: window.frame.origin), from: host)
    }

    private func track(_ type: Drag, from host: Host) {
        cancelDrag()
        source = host
        drag = type
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDragged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                self.cancelDrag()
                return nil
            }
            if event.type == .leftMouseUp { self.finishDrag(at: NSEvent.mouseLocation) }
            else if event.type == .leftMouseDragged { self.updateDrag(at: NSEvent.mouseLocation) }
            return event
        }
        // AppKit's titlebar move loop may consume mouseUp itself. Observe the
        // button only during this physical drag, including event-tracking mode.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 { self.finishDrag(at: NSEvent.mouseLocation) }
                else { self.updateDrag(at: NSEvent.mouseLocation) }
            }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func destination(at point: CGPoint) -> Host? {
        for window in NSApp.orderedWindows where window.isVisible && !window.isMiniaturized && !window.ignoresMouseEvents && window.frame.contains(point) {
            if case .window = drag, window === source?.window { continue }
            guard window.attachedSheet == nil, let host = host(for: window),
                  host.sidebarFrame?.contains(point) == true, let source, let state,
                  state.canTransferTabs(from: source.tabs, to: host.tabs) else { return nil }
            return host
        }
        return nil
    }

    private func updateDrag(at point: CGPoint) {
        badge?.setFrameTopLeftPoint(.init(x: point.x + 14, y: point.y - 8))
        let target = destination(at: point)
        if highlighted !== target {
            highlighted?.tabs.isDropTarget = false
            highlighted = target
            target?.tabs.isDropTarget = true
        }
    }

    private func finishDrag(at point: CGPoint) {
        guard let drag, let source, let state else { return }
        let target = destination(at: point)
        cancelDrag()
        if case .window(let origin) = drag {
            guard let target, target !== source, let window = source.window, window.frame.origin != origin else { return }
        }
        if let target {
            Task { @MainActor in
                let before = await target.row(at: point)
                guard self.hosts[source.tabs.id] === source, self.hosts[target.tabs.id] === target else { return }
                let tabs: [WorkspaceTabID]
                switch drag {
                case .tab(let tab): tabs = [tab]
                case .window: tabs = source.tabs.order
                }
                guard state.transferTabs(tabs, from: source.tabs, to: target.tabs, before: before) else { return }
                if target !== source { self.bringForward(target.tabs) }
                if case .window = drag { source.window?.close() }
                else { self.closeIfEmpty(source.tabs) }
            }
            return
        }
        guard case .tab(let tab) = drag, let openScene,
              state.canTransferTabs(from: source.tabs, to: source.tabs), source.tabs.order.contains(tab) else { return }
        let window = state.workspaceWindows.createTemporary()
        pending[window.id] = PendingDetach(tab: tab, source: source.tabs, point: point)
        openScene(window.id)
    }

    @objc private func resignedActive(_ note: Notification) { cancelDrag() }

    private func cancelDrag() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        releaseTimer?.invalidate()
        releaseTimer = nil
        badge?.orderOut(nil)
        badge = nil
        highlighted?.tabs.isDropTarget = false
        highlighted = nil
        drag = nil
        source = nil
    }

    private func closeIfEmpty(_ window: WorkspaceTabs) {
        if window !== state?.workspaceWindows.primary && window.order.isEmpty { hosts[window.id]?.window?.close() }
    }

    private func place(_ window: NSWindow, at point: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let area = screen.visibleFrame
        window.setFrameTopLeftPoint(.init(x: max(area.minX, min(point.x - 64, area.maxX - window.frame.width)),
                                          y: min(area.maxY, max(point.y + 12, area.minY + window.frame.height))))
    }
}

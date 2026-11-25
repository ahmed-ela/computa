import Foundation
import Observation

/// Window-local presentation over a single collection of live agents and WebKit pages.
/// Only the primary window participates in workspace restoration.
@MainActor @Observable
final class WorkspaceWindows {
    let primary: WorkspaceTabs
    private(set) var temporary: [WorkspaceTabs] = []
    private(set) var focused: WorkspaceTabs
    @TaskLocal private static var scope: WorkspaceTabs?

    init(defaults: UserDefaults) {
        let primary = WorkspaceTabs(defaults: defaults)
        self.primary = primary
        focused = primary
    }

    var all: [WorkspaceTabs] { [primary] + temporary }

    var current: WorkspaceTabs {
        if let scope = Self.scope, scope.family == primary.family { return scope }
        return focused
    }

    /// Bind snapshots, actions and their async continuations to the originating
    /// window. A key-window change must never retarget a pending UI operation.
    func withWindow<T>(_ window: WorkspaceTabs, _ body: () throws -> T) rethrows -> T {
        try Self.$scope.withValue(window, operation: body)
    }

    func focus(_ window: WorkspaceTabs) {
        guard window !== focused, all.contains(where: { $0 === window }) else { return }
        focused = window
    }

    func createTemporary() -> WorkspaceTabs {
        let window = WorkspaceTabs(temporaryFor: primary)
        window.isSidebarCollapsed = current.isSidebarCollapsed
        temporary.append(window)
        return window
    }

    func owner(of tab: WorkspaceTabID) -> WorkspaceTabs? {
        all.first { $0.order.contains(tab) }
    }

    func remove(_ window: WorkspaceTabs) {
        guard window !== primary else { return }
        temporary.removeAll { $0 === window }
        if focused === window { focused = primary }
        window.isClosed = true
    }
}

extension AppState {
    func focusWorkspace(_ window: WorkspaceTabs) {
        guard !window.isClosed else { return }
        workspaceWindows.focus(window)
        if let page = window.selectedPage, let tab = browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID == page }),
           browserSession.selectedTabID != tab.id, window.browserIsPrimary {
            browserSession.selectTab(tab.id)
        }
    }

    var displayedBrowserTab: EmbeddedBrowserTab? {
        guard let id = workspaceTabs.selectedPage else { return nil }
        return browserSession.workspaceBrowserTabs.first { $0.workspaceID == id }
    }

    func canTransferTabs(from source: WorkspaceTabs, to destination: WorkspaceTabs) -> Bool {
        !isShuttingDown && workspaceLayout == .mixedTabs && !approvalGateBlocksInteraction
            && !source.isClosed && !destination.isClosed && source.family == workspaceWindows.primary.family
            && destination.family == source.family && source.presentedSheet == nil && destination.presentedSheet == nil
            && !source.isAPIProvidersPresented && !destination.isAPIProvidersPresented
    }

    /// Move references in one MainActor transaction. Runtime turns, queue
    /// acknowledgments and live WebKit objects continue under their original IDs.
    @discardableResult
    func transferTabs(_ tabs: [WorkspaceTabID], from source: WorkspaceTabs, to destination: WorkspaceTabs,
                      before target: WorkspaceTabID? = nil) -> Bool {
        let moved = Set(tabs)
        guard canTransferTabs(from: source, to: destination), !tabs.isEmpty, moved.count == tabs.count,
              moved.isSubset(of: Set(source.order)), target.map(destination.order.contains) != false else { return false }
        let pins = moved.intersection(source.pinnedTabs)
        if source === destination {
            guard target.map(moved.contains) != true else { return false }
            source.removeTransferred(moved)
            source.insertTransferred(tabs, pinned: pins, before: target)
            saveWorkspace()
            return true
        }
        guard moved.isDisjoint(with: destination.order) else { return false }
        let sourceSelection = source.selection
        let nextIndex = sourceSelection.flatMap(source.order.firstIndex(of:)) ?? 0
        transferringWorkspaceTabs = true
        let movedDrafts = source.temporaryDraftIDs.filter { moved.contains(.agent($0)) }
        source.temporaryDraftIDs.subtract(movedDrafts)
        if destination !== workspaceWindows.primary { destination.temporaryDraftIDs.formUnion(movedDrafts) }
        source.removeTransferred(moved)
        destination.insertTransferred(tabs, pinned: pins, before: target)
        if let agent = source.selectedTaskID, moved.contains(.agent(agent)) {
            source.selectedTaskID = source.order.first { $0.kind == .agent }?.id
            source.selectedEntryID = nil
        }
        if let page = source.selectedPage, moved.contains(.browser(page)) {
            source.selectedPage = source.order.first { $0.kind == .browser }.flatMap { UUID(uuidString: $0.id) }
        }
        if let sourceSelection, moved.contains(sourceSelection) {
            if source.order.isEmpty { source.browserIsPrimary = false }
            else { selectTransferred(source.order[min(nextIndex, source.order.count - 1)], in: source) }
        }
        let incomingAgents = tabs.filter { $0.kind == .agent }
        if !incomingAgents.isEmpty {
            // A second transfer can arrive before WebKit acknowledges the first.
            var incoming = destination.draftHandoff?.drafts ?? [:]
            var outgoing = source.draftHandoff?.drafts ?? [:]
            for tab in incomingAgents {
                incoming[tab.id] = composerDrafts[tab.id] ?? ""
                outgoing[tab.id] = ""
            }
            destination.draftHandoff = .init(drafts: incoming)
            source.draftHandoff = .init(drafts: outgoing)
        }
        selectTransferred(sourceSelection.flatMap { moved.contains($0) ? $0 : nil } ?? tabs[0], in: destination)
        transferringWorkspaceTabs = false
        saveWorkspace()
        return true
    }

    private func selectTransferred(_ tab: WorkspaceTabID, in window: WorkspaceTabs) {
        workspaceWindows.withWindow(window) {
            switch tab.kind {
            case .agent:
                window.browserIsPrimary = false
                updateSelectedConversation(tab.id, acknowledging: false)
            case .browser:
                selectWorkspaceTab(tab)
            }
        }
    }

    func discardTemporaryWindow(_ window: WorkspaceTabs) {
        guard window !== workspaceWindows.primary, !window.isClosed else { return }
        let tabs = window.order
        let discardable = Set(tasks.filter {
            window.temporaryDraftIDs.contains($0.id) && $0.runtimeThreadID == nil && $0.entries.isEmpty
                && !isBusy(taskID: $0.id) && queuedPrompts[$0.id, default: []].isEmpty
        }.map(\.id))
        tasks.removeAll { discardable.contains($0.id) }
        for id in discardable { window.forgetDraftProfile(id); composerDrafts.removeValue(forKey: id) }
        window.reviewRefresh?.cancel()
        workspaceWindows.remove(window)
        window.removeTransferred(Set(tabs))
        for tab in tabs where tab.kind == .agent { composerDrafts.removeValue(forKey: tab.id) }
        for tab in tabs where tab.kind == .browser {
            if let page = browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID.uuidString == tab.id }) {
                browserSession.closeTab(page.id)
            }
        }
        saveWorkspace()
    }
}

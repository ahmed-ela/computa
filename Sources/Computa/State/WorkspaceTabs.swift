import Foundation
import Observation

/// A tab is a reference. Conversations and WebKit pages retain their own lifetimes.
struct WorkspaceTabID: Codable, Hashable, Sendable {
    enum Kind: String, Codable { case agent, browser }
    let kind: Kind
    let id: String

    static func agent(_ id: String) -> Self { Self(kind: .agent, id: id) }
    static func browser(_ id: UUID) -> Self { Self(kind: .browser, id: id.uuidString) }
}

@MainActor @Observable
final class WorkspaceTabs {
    private static let preferenceKey = "Computa.Workspace.OpenAgents.v1"
    private let defaults: UserDefaults
    private(set) var order: [WorkspaceTabID]
    private(set) var hasSavedAgents: Bool
    var browserIsPrimary = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.preferenceKey)
        hasSavedAgents = saved != nil
        var seen = Set<String>()
        order = (saved ?? []).filter { seen.insert($0).inserted }.map(WorkspaceTabID.agent)
    }

    func open(_ tab: WorkspaceTabID) {
        guard !order.contains(tab) else { return }
        order.insert(tab, at: 0)
        if tab.kind == .agent { saveAgents() }
    }

    func close(_ tab: WorkspaceTabID) {
        order.removeAll { $0 == tab }
        if tab.kind == .agent { saveAgents() }
    }

    func move(_ tab: WorkspaceTabID, to target: WorkspaceTabID) {
        guard tab != target, let from = order.firstIndex(of: tab), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(tab, at: to)
        saveAgents()
    }

    /// On upgrade, open the current conversation and any still-running agents.
    /// An explicitly empty saved workspace stays empty on the next launch.
    func initialAgent(in tasks: [AgentTask]) -> String? {
        guard !tasks.isEmpty else { return nil }
        let ids = Set(tasks.map(\.id))
        let hadOpenAgents = order.contains { $0.kind == .agent }
        let before = order
        order.removeAll { $0.kind == .agent && !ids.contains($0.id) }
        if !hasSavedAgents || (hadOpenAgents && !order.contains { $0.kind == .agent }) {
            let seed = tasks.filter { $0.id == tasks.first?.id || $0.status == .running }
            order.insert(contentsOf: seed.map { .agent($0.id) }, at: 0)
        }
        if order != before { saveAgents() }
        return order.first { $0.kind == .agent && ids.contains($0.id) }?.id
    }

    private func saveAgents() {
        let ids = order.filter { $0.kind == .agent }.map(\.id)
        if !hasSavedAgents || defaults.stringArray(forKey: Self.preferenceKey) != ids {
            defaults.set(ids, forKey: Self.preferenceKey)
        }
        hasSavedAgents = true
    }
}

extension AppState {
    var primaryBrowserID: UUID? {
        guard workspaceTabs.browserIsPrimary, let id = browserSession.selectedTabID,
              let tab = browserSession.workspaceBrowserTabs.first(where: { $0.id == id }) else { return nil }
        return tab.workspaceID
    }

    var openWorkspaceTabs: [WorkspaceTabID] {
        let agents = Set(tasks.map(\.id))
        let browsers = Set(browserSession.workspaceBrowserTabs.map { $0.workspaceID.uuidString })
        return workspaceTabs.order.filter { $0.kind == .agent ? agents.contains($0.id) : browsers.contains($0.id) }
    }

    func selectWorkspaceTab(_ tab: WorkspaceTabID) {
        guard !approvalGateBlocksInteraction, presentedSheet == nil else { return }
        switch tab.kind {
        case .agent:
            guard tasks.contains(where: { $0.id == tab.id }) else { return }
            selectTask(tab.id)
        case .browser:
            guard let id = UUID(uuidString: tab.id),
                  let page = browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID == id }) else { return }
            browserSession.selectTab(page.id)
            workspaceTabs.browserIsPrimary = true
        }
    }

    func newWorkspaceBrowserTab(url: URL? = nil) {
        guard !approvalGateBlocksInteraction, presentedSheet == nil else { return }
        do {
            let id = try browserSession.createTab(url: url)
            if let page = browserSession.humanTab(id: id) { selectWorkspaceTab(.browser(page.workspaceID)) }
        } catch {
            // The browser pane displays the session's creation error, including its tab limit.
            isBrowserPresented = true
        }
    }

    func closeWorkspaceTab(_ tab: WorkspaceTabID) {
        guard !approvalGateBlocksInteraction, presentedSheet == nil, openWorkspaceTabs.contains(tab) else { return }
        switch tab.kind {
        case .agent: removeWorkspaceTab(tab, wasSelected: primaryBrowserID == nil && selectedTaskID == tab.id)
        case .browser:
            if let page = browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID.uuidString == tab.id }) {
                browserSession.closeTab(page.id)
            }
        }
    }

    func removeWorkspaceTab(_ tab: WorkspaceTabID, wasSelected: Bool) {
        let index = workspaceTabs.order.firstIndex(of: tab) ?? 0
        workspaceTabs.close(tab)
        let remaining = openWorkspaceTabs
        let next = wasSelected && !remaining.isEmpty ? remaining[min(index, remaining.count - 1)] : nil
        if wasSelected { workspaceTabs.browserIsPrimary = false }
        if let next, next.kind == .agent {
            // A page can close itself. The visible, focused chat acknowledges its own completion.
            updateSelectedConversation(next.id, acknowledging: false)
            return
        }
        if tab.kind == .agent, selectedTaskID == tab.id {
            // Closing a tab preserves the transcript and any running turn.
            updateSelectedConversation(remaining.first { $0.kind == .agent }?.id, acknowledging: false)
        }
        if let next { selectWorkspaceTab(next) }
    }

    func toggleWorkspaceBrowser() {
        if primaryBrowserID != nil {
            workspaceTabs.browserIsPrimary = false
            isBrowserPresented = selectedTaskID != nil
        } else {
            isBrowserPresented.toggle()
        }
    }
}

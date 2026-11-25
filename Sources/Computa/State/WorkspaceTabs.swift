import Foundation
import Observation

enum WorkspaceLayout {
    case chatListWithSidePane
    case mixedTabsWithSidePane
    case mixedTabs

    var mixesBrowserTabs: Bool { self != .chatListWithSidePane }
    var allowsBrowserSidePane: Bool { self != .mixedTabs }
}

/// A tab is a reference. Conversations and WebKit pages retain their own lifetimes.
struct WorkspaceTabID: Codable, Hashable, Sendable {
    enum Kind: String, Codable { case agent, browser }
    let kind: Kind
    let id: String

    static func agent(_ id: String) -> Self { Self(kind: .agent, id: id) }
    static func browser(_ id: UUID) -> Self { Self(kind: .browser, id: id.uuidString) }
}

/// Relaunch metadata only. WebKit leases, runtime handles and message contents never cross launches.
struct SavedWorkspace: Codable, Equatable {
    struct Page: Codable, Equatable {
        let id: UUID
        let url: URL?
        let mobile: Bool
    }

    struct Draft: Codable, Equatable {
        let title: String
        let summary: String
        let workspace: String
        let model: String

        init(_ task: AgentTask) {
            title = task.title
            summary = task.summary
            workspace = task.workspace
            model = task.model
        }

        func task(id: String) -> AgentTask {
            AgentTask(id: id, title: title, summary: summary, status: .draft, workspace: workspace, model: model)
        }
    }

    struct Agent: Codable, Equatable {
        struct Conversation: Codable, Equatable {
            let id: String
            let title: String
        }
        var id = UUID()
        var name: String
        var instructions: String = ""
        var history: [Conversation] = []
    }

    // Keyed by the current conversation, initially the draft ID and then the bound thread ID.
    var agents: [String: Agent]? = nil
    var order: [WorkspaceTabID]
    var pinnedCount: Int? = nil
    var selectedAgent: String?
    var drafts: [String: Draft]
    var browserProfile: UUID?
    var pages: [Page]
    var selectedPage: UUID?
    var browserIsPrimary: Bool
    var showsBrowserPane: Bool
}

@MainActor @Observable
final class WorkspaceTabs {
    private static let legacyKey = "Computa.Workspace.OpenAgents.v1"
    private static let snapshotKey = "Computa.Workspace.OpenTabs.v2"
    let id = UUID()
    let family: UUID
    var isClosed = false
    var selectedTaskID: String? {
        didSet { if selectedTaskID != oldValue { onChange?() } }
    }
    var selectedEntryID: String?
    var selectedPage: UUID?
    var savedChatSelection: AppState.SavedChatSelection?
    var isSidebarCollapsed = false
    var presentedSheet: SheetDestination?
    var isAPIProvidersPresented = false
    var browserTabOpenError: String?
    var isReviewPresented = false
    var review: AppReviewState?
    @ObservationIgnored var reviewGeneration: UInt64 = 0
    @ObservationIgnored var reviewRefresh: Task<Void, Never>?
    struct DraftHandoff: Codable, Equatable, Sendable {
        var id = UUID()
        let drafts: [String: String]
    }
    var draftHandoff: DraftHandoff?
    var temporaryDraftIDs: Set<String> = []

    func forgetDraftProfile(_ id: String) { agents.removeValue(forKey: id.lowercased()) }
    var isDropTarget = false
    var selectionRevision: UInt64 = 0
    private let defaults: UserDefaults?
    @ObservationIgnored private(set) var saved: SavedWorkspace?
    @ObservationIgnored var onChange: (() -> Void)?
    private(set) var order: [WorkspaceTabID]
    // The prefix is the Pinned section. Shortcuts, selection and drag all use this same order.
    private(set) var pinnedCount = 0
    var pinnedTabs: ArraySlice<WorkspaceTabID> { order.prefix(pinnedCount) }
    @MainActor @Observable
    final class AgentProfiles {
        var entries: [String: SavedWorkspace.Agent]
        init(_ entries: [String: SavedWorkspace.Agent]) { self.entries = entries }
    }
    private let profiles: AgentProfiles
    private(set) var agents: [String: SavedWorkspace.Agent] {
        get { profiles.entries }
        set { profiles.entries = newValue }
    }
    enum ClosedTab {
        case agent(String)
        case browser(SavedWorkspace.Page, paneIndex: Int)

        var tab: WorkspaceTabID {
            switch self {
            case .agent(let id): .agent(id)
            case .browser(let page, _): .browser(page.id)
            }
        }
    }

    // Session-only history of explicit user closes. Closed pages retain no WebKit or tool handles.
    private(set) var recentlyClosed: [(content: ClosedTab, sectionIndex: Int, pinned: Bool)] = []
    private var hasSavedAgents: Bool
    var browserIsPrimary = false {
        didSet { if oldValue != browserIsPrimary { onChange?() } }
    }

    init(defaults: UserDefaults) {
        family = UUID()
        self.defaults = defaults
        let snapshot = defaults.data(forKey: Self.snapshotKey).flatMap { try? JSONDecoder().decode(SavedWorkspace.self, from: $0) }
        saved = snapshot
        profiles = AgentProfiles(snapshot?.agents ?? [:])
        let legacy = defaults.stringArray(forKey: Self.legacyKey)
        hasSavedAgents = snapshot != nil || legacy != nil
        var seen = Set<WorkspaceTabID>()
        let tabs = snapshot?.order ?? (legacy ?? []).map(WorkspaceTabID.agent)
        let boundary = max(0, min(snapshot?.pinnedCount ?? 0, tabs.count))
        let pins = tabs.prefix(boundary).filter { seen.insert($0).inserted }
        pinnedCount = pins.count
        order = pins + tabs.dropFirst(boundary).filter { seen.insert($0).inserted }
    }

    init(temporaryFor primary: WorkspaceTabs) {
        family = primary.family
        defaults = nil
        profiles = primary.profiles
        order = []
        hasSavedAgents = true
    }

    var selection: WorkspaceTabID? {
        if browserIsPrimary, let selectedPage { return .browser(selectedPage) }
        return selectedTaskID.map(WorkspaceTabID.agent)
    }

    /// Mutate both sides of a transfer before the primary snapshot is written.
    func removeTransferred(_ tabs: Set<WorkspaceTabID>) {
        pinnedCount -= pinnedTabs.filter(tabs.contains).count
        order.removeAll(where: tabs.contains)
        recentlyClosed.removeAll { tabs.contains($0.content.tab) }
        selectionRevision &+= 1
    }

    func insertTransferred(_ tabs: [WorkspaceTabID], pinned: Set<WorkspaceTabID>, before target: WorkspaceTabID?) {
        let index = target.flatMap { order.firstIndex(of: $0) } ?? order.count
        let pins = tabs.filter(pinned.contains)
        order.insert(contentsOf: tabs.filter { !pinned.contains($0) }, at: max(index, pinnedCount))
        order.insert(contentsOf: pins, at: min(index, pinnedCount))
        pinnedCount += pins.count
        let moved = Set(tabs)
        recentlyClosed.removeAll { moved.contains($0.content.tab) }
    }

    func save(_ snapshot: SavedWorkspace) {
        guard let defaults, saved != snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.snapshotKey)
        saved = snapshot
        hasSavedAgents = true
    }

    func rememberClose(_ content: ClosedTab) {
        guard let index = order.firstIndex(of: content.tab) else { return }
        recentlyClosed.removeAll { $0.content.tab == content.tab }
        if recentlyClosed.count == 32 { recentlyClosed.removeFirst() }
        let pinned = index < pinnedCount
        recentlyClosed.append((content, pinned ? index : index - pinnedCount, pinned))
    }

    func open(_ tab: WorkspaceTabID) {
        guard !order.contains(tab) else { return }
        // Both the explicit reopen command and opening a closed chat from Search consume its entry.
        let record = recentlyClosed.last { $0.content.tab == tab }
        recentlyClosed.removeAll { $0.content.tab == tab }
        if let record, record.pinned {
            order.insert(tab, at: min(record.sectionIndex, pinnedCount))
            pinnedCount += 1
        } else {
            order.insert(tab, at: min(pinnedCount + (record?.sectionIndex ?? 0), order.count))
        }
        onChange?()
    }

    func setPinned(_ tab: WorkspaceTabID, pinned: Bool) {
        guard let index = order.firstIndex(of: tab), (index < pinnedCount) != pinned else { return }
        order.remove(at: index)
        if !pinned { pinnedCount -= 1 }
        order.insert(tab, at: pinnedCount)
        if pinned { pinnedCount += 1 }
        onChange?()
    }

    func agent(for task: AgentTask) -> SavedWorkspace.Agent? {
        agents[(task.runtimeThreadID ?? task.id).lowercased()] ?? agents[task.id.lowercased()]
    }

    func setAgent(_ agent: SavedWorkspace.Agent, for task: AgentTask) {
        agents[(task.runtimeThreadID ?? task.id).lowercased()] = agent
        onChange?()
    }

    /// Repair the tab reference if the process exited between saving a thread binding and saving preferences.
    func restoreBinding(draft: String, thread: String) {
        guard draft != thread else { return }
        if let index = order.firstIndex(of: .agent(draft)) { order[index] = .agent(thread) }
        if saved?.selectedAgent == draft { saved?.selectedAgent = thread }
        saved?.drafts.removeValue(forKey: draft)
        bindAgent(draft: draft, thread: thread)
    }

    func bindAgent(draft: String, thread: String) {
        guard draft.lowercased() != thread.lowercased(), let agent = agents.removeValue(forKey: draft.lowercased()) else { return }
        agents[thread.lowercased()] = agent
    }

    func startConversation(after task: AgentTask, newID: String) {
        guard let index = order.firstIndex(of: .agent(task.id)) else { return }
        let previous = task.runtimeThreadID ?? task.id
        var agent = self.agent(for: task) ?? .init(name: task.title)
        agent.history.insert(.init(id: previous, title: task.title), at: 0)
        agents.removeValue(forKey: previous.lowercased())
        agents.removeValue(forKey: task.id.lowercased())
        agents[newID.lowercased()] = agent
        order[index] = .agent(newID)
        // AppState publishes selection and saves the complete replacement together.
    }

    func close(_ tab: WorkspaceTabID) {
        guard let index = order.firstIndex(of: tab) else { return }
        if index < pinnedCount { pinnedCount -= 1 }
        order.remove(at: index)
        onChange?()
    }

    func move(_ tab: WorkspaceTabID, to target: WorkspaceTabID) {
        guard tab != target, let from = order.firstIndex(of: tab), let to = order.firstIndex(of: target),
              (from < pinnedCount) == (to < pinnedCount) else { return }
        order.remove(at: from)
        order.insert(tab, at: to)
        onChange?()
    }

    /// On upgrade, open the current conversation and any still-running agents.
    /// An explicitly empty saved workspace stays empty on the next launch.
    func initialAgent(in tasks: [AgentTask]) -> String? {
        guard !tasks.isEmpty else { return nil }
        let ids = Set(tasks.map(\.id))
        var localForThread: [String: String] = [:]
        for task in tasks {
            localForThread[AgentTask.identityKey(task.id)] = task.id
            if let thread = task.runtimeThreadID { localForThread[AgentTask.identityKey(thread)] = task.id }
        }
        let hadOpenAgents = order.contains { $0.kind == .agent }
        var seen = Set<WorkspaceTabID>()
        func restored(_ tab: WorkspaceTabID) -> WorkspaceTabID? {
            let local = tab.kind == .browser || ids.contains(tab.id)
                ? tab : localForThread[AgentTask.identityKey(tab.id)].map(WorkspaceTabID.agent)
            guard let local, seen.insert(local).inserted else { return nil }
            return local
        }
        let pins = pinnedTabs.compactMap(restored)
        order = pins + order.dropFirst(pinnedCount).compactMap(restored)
        pinnedCount = pins.count
        if defaults != nil && (!hasSavedAgents || (hadOpenAgents && !order.contains { $0.kind == .agent })) {
            let seed = tasks.filter { $0.id == tasks.first?.id || $0.status == .running }
            order.insert(contentsOf: seed.map { .agent($0.id) }, at: pinnedCount)
        }
        if let selected = saved?.selectedAgent {
            let local = localForThread[AgentTask.identityKey(selected)] ?? selected
            if order.contains(.agent(local)) { return local }
        }
        return order.first { $0.kind == .agent }?.id
    }
}

extension AppState {
    var primaryBrowserID: UUID? {
        workspaceTabs.browserIsPrimary ? displayedBrowserTab?.workspaceID : nil
    }

    var openWorkspaceTabs: [WorkspaceTabID] {
        let agents = Set(tasks.map(\.id))
        if !mixesBrowserTabsInSidebar {
            return workspaceTabs.order.filter { $0.kind == .agent && agents.contains($0.id) }
        }
        let browsers = Set(browserSession.workspaceBrowserTabs.map { $0.workspaceID.uuidString })
        return workspaceTabs.order.filter { $0.kind == .agent ? agents.contains($0.id) : browsers.contains($0.id) }
    }

    enum TabDirection: Int { case previous = -1, next = 1 }

    var selectedWorkspaceTab: WorkspaceTabID? {
        primaryBrowserID.map(WorkspaceTabID.browser) ?? selectedTaskID.map(WorkspaceTabID.agent)
    }

    func commandTab(inBrowserPane: Bool) -> WorkspaceTabID? {
        guard inBrowserPane else { return selectedWorkspaceTab }
        return browserSession.workspaceBrowserTabs.first { $0.id == browserSession.selectedTabID }.map { .browser($0.workspaceID) }
    }

    func reloadableBrowserTabID(inBrowserPane: Bool) -> UUID? {
        guard shouldPresentBrowserPane, !approvalGateBlocksInteraction, presentedSheet == nil,
              inBrowserPane || primaryBrowserID != nil,
              let tab = browserSession.workspaceBrowserTabs.first(where: { $0.id == browserSession.selectedTabID }),
              tab.url != nil, !tab.isLoading else { return nil }
        return tab.id
    }

    func commandTabs(inBrowserPane: Bool) -> [WorkspaceTabID] {
        inBrowserPane ? browserSession.workspaceBrowserTabs.map { .browser($0.workspaceID) } : openWorkspaceTabs
    }

    func selectAdjacentWorkspaceTab(_ direction: TabDirection, inBrowserPane: Bool = false) {
        let tabs = commandTabs(inBrowserPane: inBrowserPane)
        guard let first = tabs.first, let last = tabs.last else { return }
        let current = commandTab(inBrowserPane: inBrowserPane)
        let target: WorkspaceTabID
        if let current, let index = tabs.firstIndex(of: current) {
            target = tabs[(index + direction.rawValue + tabs.count) % tabs.count]
        } else {
            target = direction == .next ? first : last
        }
        if target != current { selectWorkspaceTab(target) }
    }

    func selectWorkspaceTab(_ tab: WorkspaceTabID) {
        guard !approvalGateBlocksInteraction, presentedSheet == nil else { return }
        switch tab.kind {
        case .agent:
            guard tasks.contains(where: { $0.id == tab.id }) else { return }
            selectTask(tab.id)
        case .browser:
            guard workspaceTabs.order.contains(tab), let id = UUID(uuidString: tab.id),
                  let page = browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID == id }) else { return }
            browserSession.selectTab(page.id)
            if mixesBrowserTabsInSidebar {
                savedChatSelection = nil
                workspaceTabs.browserIsPrimary = true
            } else { isBrowserPresented = true }
        }
    }

    func newWorkspaceBrowserTab(url: URL = EmbeddedBrowserURLPolicy.newTabURL) {
        guard !workspaceTabs.isClosed, !approvalGateBlocksInteraction, presentedSheet == nil else { return }
        do {
            let id = try browserSession.createTab(url: url)
            if let page = browserSession.humanTab(id: id) { selectWorkspaceTab(.browser(page.workspaceID)) }
        } catch {
            presentBrowserTabOpenError(error)
        }
    }

    func closeWorkspaceTab(_ tab: WorkspaceTabID) {
        guard !workspaceTabs.isClosed, workspaceTabs.order.contains(tab), !approvalGateBlocksInteraction, presentedSheet == nil else { return }
        switch tab.kind {
        case .agent:
            guard openWorkspaceTabs.contains(tab) else { return }
            workspaceTabs.rememberClose(.agent(tab.id))
            removeWorkspaceTab(tab, wasSelected: primaryBrowserID == nil && selectedTaskID == tab.id)
        case .browser:
            if let page = browserSession.workspaceBrowserTabs.first(where: { $0.workspaceID.uuidString == tab.id }) {
                if let saved = browserSession.restorablePage(for: page),
                   let index = browserSession.workspaceBrowserTabs.firstIndex(where: { $0.id == page.id }) {
                    workspaceTabs.rememberClose(.browser(saved, paneIndex: index))
                }
                browserSession.closeTab(page.id)
            }
        }
    }

    private var lastClosedTab: WorkspaceTabs.ClosedTab? {
        workspaceTabs.recentlyClosed.last { record in
            switch record.content {
            case .agent(let id): tasks.contains { $0.id == id }
            case .browser: true
            }
        }?.content
    }

    var canReopenClosedTab: Bool {
        !approvalGateBlocksInteraction && presentedSheet == nil && lastClosedTab != nil
    }

    func reopenClosedTab() {
        guard canReopenClosedTab, let closed = lastClosedTab else { return }
        if case .browser(let page, let index) = closed {
            do {
                try browserSession.reopenWorkspacePage(page, at: index)
            } catch {
                // Creation failures leave the close record available for retry.
                presentBrowserTabOpenError(error)
                return
            }
        }
        selectWorkspaceTab(closed.tab)
    }

    func removeWorkspaceTab(_ tab: WorkspaceTabID, wasSelected: Bool) {
        let order = mixesBrowserTabsInSidebar ? workspaceTabs.order : openWorkspaceTabs
        let index = order.firstIndex(of: tab) ?? 0
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

    func presentBrowserTabOpenError(_ error: Error) {
        if workspaceLayout.allowsBrowserSidePane {
            isBrowserPresented = true  // This layout displays session errors inside the browser pane.
        } else {
            browserTabOpenError = error.localizedDescription
        }
    }

    func toggleWorkspaceBrowser() {
        guard workspaceLayout.allowsBrowserSidePane else { return }
        if primaryBrowserID != nil {
            workspaceTabs.browserIsPrimary = false
            isBrowserPresented = selectedTaskID != nil
        } else {
            isBrowserPresented.toggle()
        }
    }
}

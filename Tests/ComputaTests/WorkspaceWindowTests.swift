import AppKit
import WebKit
import XCTest
@testable import Computa

@MainActor
final class WorkspaceWindowTests: XCTestCase {
    func testNumberedShortcutsCountPinsAndUseTheLastTabOfTheActiveWindow() throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let tasks = (1...10).map { AgentTask(title: "Agent \($0)", summary: "", status: .draft, workspace: "", model: "local") }
        let state = AppState(tasks: tasks, preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let agents = tasks.map { WorkspaceTabID.agent($0.id) }
        for agent in agents { state.workspaceTabs.open(agent) }
        let pageID = try session.createTab()
        let page = WorkspaceTabID.browser(try XCTUnwrap(session.humanTab(id: pageID)).workspaceID)
        state.workspaceTabs.setPinned(page, pinned: true)
        state.workspaceTabs.setPinned(agents[3], pinned: true)

        var expected = [page, agents[3]] + agents.reversed().filter { $0 != agents[3] }
        XCTAssertEqual(state.openWorkspaceTabs, expected)
        for number in 1...8 {
            state.selectNumberedWorkspaceTab(number)
            XCTAssertEqual(state.selectedWorkspaceTab, expected[number - 1])
        }
        state.selectNumberedWorkspaceTab(9)
        XCTAssertEqual(state.selectedWorkspaceTab, agents[0])
        state.workspaceTabs.setPinned(page, pinned: false)
        expected.swapAt(0, 1)
        XCTAssertEqual(state.openWorkspaceTabs, expected)
        state.selectNumberedWorkspaceTab(1)
        XCTAssertEqual(state.selectedWorkspaceTab, agents[3])

        let detached = state.workspaceWindows.createTemporary()
        state.focusWorkspace(detached)
        state.selectNumberedWorkspaceTab(9)
        XCTAssertNil(state.selectedWorkspaceTab)
        state.createTask()
        let first = try XCTUnwrap(state.selectedWorkspaceTab)
        state.createTask()
        let second = try XCTUnwrap(state.selectedWorkspaceTab)
        XCTAssertEqual(state.openWorkspaceTabs, [second, first])
        state.selectNumberedWorkspaceTab(8)
        XCTAssertEqual(state.selectedWorkspaceTab, second)
        state.selectNumberedWorkspaceTab(9)
        XCTAssertEqual(state.selectedWorkspaceTab, first)
        state.presentedSheet = .settings
        state.selectNumberedWorkspaceTab(1)
        XCTAssertEqual(state.selectedWorkspaceTab, first)
        state.presentedSheet = nil

        state.focusWorkspace(state.workspaceWindows.primary)
        XCTAssertEqual(state.selectedWorkspaceTab, agents[3])
    }

    func testSidebarKeyboardCommandKeepsItsWindowAndOnlyPersistsThePrimaryRail() {
        let prefs = isolatedTestPreferences()
        let state = AppState(tasks: [], preferences: prefs)
        defer { state.browserSession.shutdown() }
        let primary = state.workspaceWindows.primary
        let secondary = state.workspaceWindows.createTemporary()
        let primaryCommand = WebWorkspaceView(state: state, window: primary).sidebarCollapseBinding
        let secondaryCommand = WebWorkspaceView(state: state, window: secondary).sidebarCollapseBinding

        state.focusWorkspace(secondary)
        primaryCommand.wrappedValue.toggle()
        XCTAssertTrue(primary.isSidebarCollapsed)
        XCTAssertFalse(secondary.isSidebarCollapsed)
        XCTAssertTrue(prefs.bool(forKey: "taskSidebarCollapsed"))

        state.focusWorkspace(primary)
        secondaryCommand.wrappedValue.toggle()
        secondaryCommand.wrappedValue.toggle()
        XCTAssertFalse(secondary.isSidebarCollapsed)
        XCTAssertTrue(primaryCommand.wrappedValue)
        XCTAssertTrue(prefs.bool(forKey: "taskSidebarCollapsed"))
        primaryCommand.wrappedValue.toggle()
        XCTAssertFalse(prefs.bool(forKey: "taskSidebarCollapsed"))
    }

    func testNewAgentDoesNotChangeSidebarSearchOrRestoredSelectionUntilFirstSend() throws {
        let prefs = isolatedTestPreferences()
        let browser = EmbeddedBrowserSession(profileID: UUID(), defaults: prefs)
        defer { browser.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: browser, workspaceLayout: .mixedTabs)
        state.createTask()
        let previous = try XCTUnwrap(state.selectedWorkspaceTab)
        let pageID = try browser.createTab()
        let page = WorkspaceTabID.browser(try XCTUnwrap(browser.humanTab(id: pageID)?.workspaceID))
        state.selectWorkspaceTab(page)
        let order = state.openWorkspaceTabs
        let saved = try XCTUnwrap(state.workspaceTabs.saved)
        let draft = state.presentNewAgent()
        for _ in 0..<5 {
            XCTAssertEqual(state.presentNewAgent().id, draft.id)
            let snapshot = WebUISnapshot(state: state)
            XCTAssertEqual(snapshot.newAgentDraft?.id, draft.id)
            XCTAssertEqual(snapshot.selectedTaskID, draft.id)
            XCTAssertFalse(snapshot.tasks.contains { $0.id == draft.id })
            XCTAssertFalse(snapshot.savedChats.contains { $0.id == draft.id })
            XCTAssertEqual(snapshot.workspaceOrder, order)
            XCTAssertNil(snapshot.primaryBrowserID)
            state.selectWorkspaceTab(page)
            XCTAssertNil(WebUISnapshot(state: state).newAgentDraft)
        }
        state.presentNewAgent()
        state.composerDrafts[draft.id] = "typed but unsent"
        state.saveAgentSettings(taskID: draft.id, name: "Review", instructions: "Use the fixture.")
        state.saveWorkspace()
        XCTAssertEqual(WorkspaceTabs(defaults: prefs).saved, saved)
        let afterRestart = WorkspaceTabs(defaults: prefs)
        XCTAssertEqual(afterRestart.saved?.selectedPage?.uuidString, page.id)
        XCTAssertNil(afterRestart.newAgentDraft)
        XCTAssertFalse(state.acceptPrompt(prompt: "   ", taskID: draft.id, requestID: "blank"))
        XCTAssertFalse(state.acceptPrompt(prompt: String(repeating: "x", count: 200_001), taskID: draft.id, requestID: "too-long"))
        XCTAssertEqual(state.openWorkspaceTabs, order)
        state.selectWorkspaceTab(previous)
        XCTAssertNil(WebUISnapshot(state: state).newAgentDraft)
        XCTAssertEqual(state.presentNewAgent().id, draft.id)
        XCTAssertEqual(state.composerText, "typed but unsent")
        XCTAssertTrue(state.acceptPrompt(prompt: "typed but unsent", taskID: draft.id, requestID: "first"))
        XCTAssertTrue(state.acceptPrompt(prompt: "typed but unsent", taskID: draft.id, requestID: "first"))
        XCTAssertFalse(state.acceptPrompt(prompt: "a different message", taskID: draft.id, requestID: "first"))
        XCTAssertEqual(state.workspaceTabs.agent(for: draft)?.name, "Review")
        XCTAssertEqual(state.openWorkspaceTabs, [.agent(draft.id)] + order)
        XCTAssertEqual(state.selectedWorkspaceTab, .agent(draft.id))
        XCTAssertNil(WebUISnapshot(state: state).newAgentDraft)
        XCTAssertEqual(state.queuedPromptsForDisplay(taskID: draft.id).count, 1)
        XCTAssertNil(state.composerDrafts[draft.id])
        XCTAssertNotEqual(state.presentNewAgent().id, draft.id)
    }

    func testUnsentComposerBelongsToItsWindowAndCloseLeavesActualTabsAlone() throws {
        let prefs = isolatedTestPreferences()
        let browser = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { browser.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: browser, workspaceLayout: .mixedTabs)
        let primary = state.workspaceWindows.primary
        let detached = state.workspaceWindows.createTemporary()
        let draft = state.presentNewAgent()
        state.workspaceWindows.withWindow(detached) {
            state.createTask()
            let previous = state.selectedWorkspaceTab
            let otherDraft = state.presentNewAgent()
            XCTAssertNotEqual(draft.id, otherDraft.id)
            XCTAssertFalse(state.acceptPrompt(prompt: "wrong window", taskID: draft.id, requestID: "foreign"))
            let window = showWindow(detached, state: state)
            defer { window.close() }
            state.windowHosting.closeTabOrWindow(window, inBrowserPane: false)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(state.selectedWorkspaceTab, previous)
            XCTAssertEqual(detached.recentlyClosed.count, 0)
            XCTAssertEqual(state.presentNewAgent().id, otherDraft.id)
        }
        state.workspaceWindows.withWindow(primary) {
            XCTAssertEqual(state.presentNewAgent().id, draft.id)
            XCTAssertTrue(primary.order.isEmpty)
        }
    }

    func testPinsFollowTabsThroughUndoBindingFreshContextAndWindowTransfers() throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(profileID: UUID(), defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let primary = state.workspaceWindows.primary, detached = state.workspaceWindows.createTemporary()
        state.createTask()
        let agent = try XCTUnwrap(state.selectedWorkspaceTab)
        let pageID = try session.createTab()
        let page = WorkspaceTabID.browser(try XCTUnwrap(session.humanTab(id: pageID)?.workspaceID))
        primary.setPinned(page, pinned: true)
        primary.setPinned(agent, pinned: true)
        state.createTask()
        let regular = try XCTUnwrap(state.selectedWorkspaceTab)
        XCTAssertEqual(primary.order, [page, agent, regular])
        primary.setPinned(page, pinned: true)
        primary.move(regular, to: page)
        XCTAssertEqual(primary.order, [page, agent, regular])
        XCTAssertEqual(primary.pinnedCount, 2)

        state.closeWorkspaceTab(page)
        XCTAssertEqual(Array(primary.pinnedTabs), [agent])
        state.reopenClosedTab()
        XCTAssertEqual(Array(primary.pinnedTabs), [page, agent])
        let reopened = try XCTUnwrap(session.workspaceBrowserTabs.first { .browser($0.workspaceID) == page })
        let view = try XCTUnwrap(session.webView(for: reopened.id))
        XCTAssertTrue(state.transferTabs([page, regular], from: primary, to: detached))
        XCTAssertEqual(Array(primary.pinnedTabs), [agent])
        XCTAssertEqual(Array(detached.pinnedTabs), [page])
        XCTAssertTrue(state.transferTabs(detached.order, from: detached, to: primary, before: agent))
        XCTAssertEqual(primary.order, [page, agent, regular])
        XCTAssertEqual(primary.pinnedCount, 2)
        XCTAssertTrue(view === session.webView(for: reopened.id))
        XCTAssertEqual(WorkspaceTabs(defaults: prefs).pinnedCount, 2)

        let task = try XCTUnwrap(state.tasks.first { $0.id == agent.id })
        primary.startConversation(after: task, newID: "fresh")
        XCTAssertEqual(Array(primary.pinnedTabs), [page, .agent("fresh")])
        primary.restoreBinding(draft: "fresh", thread: "bound")
        XCTAssertEqual(Array(primary.pinnedTabs), [page, .agent("bound")])
        primary.setPinned(page, pinned: false)
        XCTAssertEqual(Array(primary.pinnedTabs), [.agent("bound")])
        XCTAssertEqual(primary.order, [.agent("bound"), page, regular])
    }

    func testDetachedPinsRestoreInOrderAndReturnToPrimaryOnWindowClose() throws {
        let prefs = isolatedTestPreferences(), profile = UUID()
        let session = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let main = state.workspaceWindows.primary, detached = state.workspaceWindows.createTemporary()
        state.createTask()
        let original = try XCTUnwrap(main.selection)
        let selectedID = try session.createTab()
        let selected = try XCTUnwrap(session.humanTab(id: selectedID)?.workspaceID)
        state.selectWorkspaceTab(.browser(selected))
        main.setPinned(original, pinned: true)
        let (agent, page, regular) = try state.workspaceWindows.withWindow(detached) {
            state.createTask()
            let agent = try XCTUnwrap(detached.selection)
            state.saveAgentSettings(taskID: agent.id, name: "Pinned agent", instructions: "Remember the fixture.")
            state.createTask()
            let regular = try XCTUnwrap(detached.selection)
            let tabID = try session.createTab()
            let page = try XCTUnwrap(session.humanTab(id: tabID))
            _ = try session.createTab()
            detached.setPinned(.browser(page.workspaceID), pinned: true)
            detached.setPinned(agent, pinned: true)
            return (agent, page, regular)
        }
        let browser = WorkspaceTabID.browser(page.workspaceID)
        let expected = [original, browser, agent, .browser(selected)]
        XCTAssertEqual(main.order, [original, .browser(selected)])
        XCTAssertEqual(WorkspaceTabs(defaults: prefs).order, expected)
        detached.setPinned(agent, pinned: false)
        XCTAssertFalse(WorkspaceTabs(defaults: prefs).order.contains(agent))
        detached.setPinned(agent, pinned: true)

        let next = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        defer { next.shutdown() }
        let restored = AppState(tasks: [], preferences: prefs, browserSession: next, workspaceLayout: .mixedTabs)
        XCTAssertEqual(restored.workspaceTabs.order, expected)
        XCTAssertEqual(Array(restored.workspaceTabs.pinnedTabs), Array(expected.prefix(3)))
        XCTAssertEqual(restored.selectedWorkspaceTab, .browser(selected))
        XCTAssertFalse(restored.tasks.contains { $0.id == regular.id })
        let restoredAgent = try XCTUnwrap(restored.tasks.first { $0.id == agent.id })
        XCTAssertEqual(restored.workspaceTabs.agent(for: restoredAgent)?.name, "Pinned agent")

        let view = try XCTUnwrap(session.webView(for: page.id))
        state.composerDrafts[agent.id] = "Unsent text"
        state.discardTemporaryWindow(detached)
        XCTAssertEqual(main.order, expected)
        XCTAssertEqual(main.selection, .browser(selected))
        XCTAssertEqual(main.draftHandoff?.drafts[agent.id], "Unsent text")
        XCTAssertTrue(view === session.webView(for: page.id))
        XCTAssertEqual(Set(session.workspaceBrowserTabs.map(\.workspaceID)), [page.workspaceID, selected])
        XCTAssertFalse(state.tasks.contains { $0.id == regular.id })
        XCTAssertEqual(WorkspaceTabs(defaults: prefs).order, expected)
    }

    func testQuitCollectsOnlyStillOpenWindowsAndPreservesFocusedTab() async throws {
        let prefs = isolatedTestPreferences(), profile = UUID()
        let session = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let primary = state.workspaceWindows.primary
        let mainID = try session.createTab()
        let mainTab = WorkspaceTabID.browser(try XCTUnwrap(session.humanTab(id: mainID)).workspaceID)
        primary.setPinned(mainTab, pinned: true)
        let closed = state.workspaceWindows.createTemporary()
        let removed = try state.workspaceWindows.withWindow(closed) {
            state.createTask()
            return try XCTUnwrap(closed.selectedTaskID)
        }
        let closedHost = showWindow(closed, state: state)
        closedHost.close()
        XCTAssertTrue(closed.isClosed)
        let open = state.workspaceWindows.createTemporary()
        let (agent, page) = try state.workspaceWindows.withWindow(open) {
            state.createTask()
            let agent = try XCTUnwrap(open.selectedTaskID)
            let browserID = try session.createTab()
            let page = WorkspaceTabID.browser(try XCTUnwrap(session.humanTab(id: browserID)).workspaceID)
            state.selectWorkspaceTab(page)
            return (agent, page)
        }
        let openHost = showWindow(open, state: state)
        state.focusWorkspace(open)
        let expected = [mainTab] + open.order
        XCTAssertEqual(Set(open.order), [.agent(agent), page])
        state.prepareWorkspaceForQuit()
        // Cocoa can close a window while the application's runtime is shutting down.
        openHost.close()
        XCTAssertTrue(open.isClosed)
        _ = await state.shutdownRuntime()
        let nextBrowser = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        defer { nextBrowser.shutdown() }
        let next = AppState(tasks: [], preferences: prefs, browserSession: nextBrowser, workspaceLayout: .mixedTabs)
        XCTAssertEqual(next.workspaceTabs.order, expected)
        XCTAssertEqual(Array(next.workspaceTabs.pinnedTabs), [mainTab])
        XCTAssertEqual(next.selectedWorkspaceTab, page)
        XCTAssertTrue(next.tasks.contains { $0.id == agent })
        XCTAssertFalse(next.tasks.contains { $0.id == removed })
    }

    func testOnlyDetachedBrowserPinIsSelectedOnRestoreIntoEmptyPrimaryWindow() throws {
        let prefs = isolatedTestPreferences(), profile = UUID()
        let session = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let main = state.workspaceWindows.primary, detached = state.workspaceWindows.createTemporary()
        let id = try session.createTab()
        let page = WorkspaceTabID.browser(try XCTUnwrap(session.humanTab(id: id)?.workspaceID))
        main.setPinned(page, pinned: true)
        XCTAssertTrue(state.transferTabs([page], from: main, to: detached))
        XCTAssertTrue(main.order.isEmpty)
        let next = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        defer { next.shutdown() }
        let restored = AppState(tasks: [], preferences: prefs, browserSession: next, workspaceLayout: .mixedTabs)
        XCTAssertEqual(Array(restored.workspaceTabs.pinnedTabs), [page])
        XCTAssertEqual(restored.selectedWorkspaceTab, page)
    }

    func testCloseShortcutClosesOnlyItsLastTabAndWindow() throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let main = state.workspaceWindows.primary
        let other = state.workspaceWindows.createTemporary()
        state.createTask()
        let agent = try XCTUnwrap(state.selectedTaskID)
        state.apply(.taskStatusChanged(taskID: agent, status: .running))
        state.activeTurnTaskIDs.insert(agent)
        let first = try session.createTab()
        let firstPage = try XCTUnwrap(session.humanTab(id: first))
        state.selectWorkspaceTab(.browser(firstPage.workspaceID))
        let second = try state.workspaceWindows.withWindow(other) {
            let id = try session.createTab()
            let page = try XCTUnwrap(session.humanTab(id: id))
            state.selectWorkspaceTab(.browser(page.workspaceID))
            return page
        }
        let mainWindow = showWindow(main, state: state)
        let otherWindow = showWindow(other, state: state)
        defer { mainWindow.close(); otherWindow.close() }

        state.focusWorkspace(other)
        state.windowHosting.closeTabOrWindow(mainWindow, inBrowserPane: false)
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertEqual(main.order, [.agent(agent)])
        XCTAssertNil(session.humanTab(id: first))
        XCTAssertEqual(other.selection, .browser(second.workspaceID))

        state.windowHosting.closeTabOrWindow(mainWindow, inBrowserPane: false)
        XCTAssertFalse(mainWindow.isVisible)
        XCTAssertTrue(main.order.isEmpty)
        XCTAssertEqual(main.recentlyClosed.last?.content.tab, .agent(agent))
        XCTAssertTrue(otherWindow.isVisible)
        XCTAssertNotNil(session.humanTab(id: second.id))
        XCTAssertTrue(state.isBusy(taskID: agent))

        state.windowHosting.closeTabOrWindow(otherWindow, inBrowserPane: false)
        XCTAssertFalse(otherWindow.isVisible)
        XCTAssertTrue(other.isClosed)
        XCTAssertNil(session.humanTab(id: second.id))
    }

    func testCloseShortcutClosesAnEmptyWindowAndHonorsSettings() {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let tabs = state.workspaceWindows.primary
        let window = showWindow(tabs, state: state)
        defer { window.close() }
        XCTAssertTrue(tabs.order.isEmpty)
        tabs.presentedSheet = .settings
        state.windowHosting.closeTabOrWindow(window, inBrowserPane: false)
        XCTAssertTrue(window.isVisible)
        tabs.presentedSheet = nil
        state.windowHosting.closeTabOrWindow(window, inBrowserPane: false)
        XCTAssertFalse(window.isVisible)
    }

    private func showWindow(_ tabs: WorkspaceTabs, state: AppState) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let sidebar = WKWebView()
        window.contentView = sidebar
        state.windowHosting.attach(window, tabs: tabs, sidebar: sidebar, width: { 200 })
        window.orderBack(nil)
        return window
    }

    func testMoveLiveTabsAndMergePreservesPageStateAgentQueueAndPrimaryRestore() async throws {
        let defaults = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(defaults: defaults)
        defer { session.shutdown() }
        let runtime = QueueControlledRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: defaults, browserSession: session, workspaceLayout: .mixedTabs)
        state.createTask()
        let original = try XCTUnwrap(state.selectedTaskID)
        let pageID = try session.createTab()
        let page = try XCTUnwrap(session.humanTab(id: pageID))
        let ref = WorkspaceTabID.browser(page.workspaceID)
        let view = try XCTUnwrap(session.webView(for: pageID))
        _ = try await view.evaluateJavaScript("window.unsaved = 'before move'")
        state.selectWorkspaceTab(ref)
        state.createTask()
        let active = try XCTUnwrap(state.selectedTaskID)
        state.apply(.taskStatusChanged(taskID: active, status: .running))
        state.activeTurnTaskIDs.insert(active)
        _ = await state.submitOrQueue(prompt: "Still queued", toTaskID: active)
        let queued = try XCTUnwrap(state.queuedPrompts[active]?.first)
        XCTAssertTrue(state.beginQueueEdit(taskID: active, id: queued.id))
        state.updateQueueEditDraft(taskID: active, id: queued.id, text: "Uncommitted queue edit")
        state.composerDrafts[active] = "Unsent editor text"

        let windows = state.workspaceWindows
        let main = windows.primary, other = windows.createTemporary()
        XCTAssertTrue(state.transferTabs([ref], from: main, to: other))
        XCTAssertEqual(main.selection, .agent(active))
        XCTAssertEqual(other.selection, ref)
        XCTAssertEqual(main.saved?.pages, [])
        XCTAssertTrue(state.transferTabs([.agent(active)], from: main, to: other, before: ref))
        XCTAssertEqual(main.order, [.agent(original)])
        XCTAssertEqual(main.saved?.selectedAgent, original)
        XCTAssertEqual(other.order, [.agent(active), ref])
        XCTAssertEqual(other.draftHandoff?.drafts[active], "Unsent editor text")
        XCTAssertEqual(main.draftHandoff?.drafts[active], "")
        windows.withWindow(main) { state.closeWorkspaceTab(ref) }
        XCTAssertNotNil(session.webView(for: pageID), "A stale close from the previous window must not close the moved browser.")
        XCTAssertTrue(windows.focused === main)
        state.apply(.assistantMessageDelta(taskID: active, itemID: "live-reply", delta: "Still working"))
        XCTAssertEqual(other.selectedEntryID, "live-reply")
        XCTAssertNotEqual(main.selectedEntryID, "live-reply")
        windows.withWindow(other) {
            XCTAssertEqual(state.queuedPromptsForDisplay(taskID: active).map(\.text), ["Uncommitted queue edit"])
            XCTAssertEqual(state.queuedPrompts[active]?.map(\.text), ["Still queued"])
            XCTAssertTrue(state.cancelQueueEdit(taskID: active, id: queued.id))
            XCTAssertEqual(state.queuedPromptsForDisplay(taskID: active).map(\.text), ["Still queued"])
            state.selectWorkspaceTab(ref)
            state.createTask()
        }
        let newAgent = try XCTUnwrap(other.selectedTaskID)
        XCTAssertFalse(main.saved?.drafts.keys.contains(newAgent) ?? true)
        XCTAssertTrue(view === session.webView(for: pageID))
        let liveValue = try await view.evaluateJavaScript("window.unsaved") as? String
        XCTAssertEqual(liveValue, "before move")
        let sourceOrder = other.order
        XCTAssertTrue(state.transferTabs(sourceOrder, from: other, to: main, before: .agent(original)))
        state.discardTemporaryWindow(other)
        XCTAssertEqual(main.order, sourceOrder + [.agent(original)])
        XCTAssertEqual(main.selection, .agent(newAgent))
        XCTAssertEqual(state.queuedPrompts[active]?.map(\.text), ["Still queued"])
        XCTAssertTrue(view === session.webView(for: pageID))
        let restored = WorkspaceTabs(defaults: defaults)
        XCTAssertEqual(restored.order, main.order)
        XCTAssertEqual(restored.saved?.selectedAgent, newAgent)
        XCTAssertEqual(restored.saved?.pages.map(\.id), [page.workspaceID])
    }

    func testCloseTemporaryWindowDiscardsOnlyItsTabsAndCannotReplayStaleDrop() throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        state.createTask()
        let main = state.workspaceTabs, agent = try XCTUnwrap(main.selection)
        let a = state.workspaceWindows.createTemporary(), b = state.workspaceWindows.createTemporary()
        XCTAssertTrue(state.transferTabs([agent], from: main, to: a))
        let moving = try state.workspaceWindows.withWindow(a) {
            let id = try session.createTab()
            let tab = try XCTUnwrap(session.humanTab(id: id))
            state.selectWorkspaceTab(.browser(tab.workspaceID))
            return tab
        }
        let ref = WorkspaceTabID.browser(moving.workspaceID)
        XCTAssertTrue(state.transferTabs([ref], from: a, to: b))
        XCTAssertFalse(state.transferTabs([ref], from: a, to: main))
        XCTAssertEqual(a.selection, agent)
        state.workspaceWindows.withWindow(b) { state.createTask() }
        state.discardTemporaryWindow(a)
        XCTAssertNotNil(session.webView(for: moving.id))
        state.discardTemporaryWindow(b)
        XCTAssertNil(session.webView(for: moving.id))
        XCTAssertTrue(main.order.isEmpty)
        XCTAssertFalse(state.transferTabs([agent], from: a, to: main))
        XCTAssertTrue(WorkspaceTabs(defaults: prefs).order.isEmpty)
        XCTAssertTrue(main.saved?.pages.isEmpty == true)
        XCTAssertTrue(main.saved?.drafts.isEmpty == true)
        XCTAssertTrue(main.recentlyClosed.isEmpty)
    }

    func testTransferCancelsAtomicallyWhenDestinationBlockedOrTargetStale() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session, workspaceLayout: .mixedTabs)
        state.createTask()
        let main = state.workspaceTabs, tab = try XCTUnwrap(main.selection)
        let other = state.workspaceWindows.createTemporary()
        other.presentedSheet = .settings
        XCTAssertFalse(state.transferTabs([tab], from: main, to: other))
        other.presentedSheet = nil
        XCTAssertFalse(state.transferTabs([tab], from: main, to: other, before: .agent("stale")))
        XCTAssertFalse(state.transferTabs([tab, .agent("missing")], from: main, to: other))
        XCTAssertEqual(main.order, [tab])
        XCTAssertTrue(other.order.isEmpty)
    }
}

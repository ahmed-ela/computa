import AppKit
import WebKit
import XCTest
@testable import Computa

@MainActor
final class WorkspaceWindowTests: XCTestCase {
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

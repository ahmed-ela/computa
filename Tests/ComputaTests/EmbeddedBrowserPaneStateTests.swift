import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Computa

final class EmbeddedBrowserPaneStateTests: XCTestCase {
    @MainActor
    func testFaviconSpinnerHasATransparentCenterAndVisibleRim() throws {
        let index = try XCTUnwrap(WebUIResourceLocator.indexURL)
        let url = index.deletingLastPathComponent().appendingPathComponent("icons/favicon-loading.svg")
        let icon = try XCTUnwrap(NSImage(contentsOf: url))
        let pixels = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(icon.tiffRepresentation)))
        let centerY = pixels.pixelsHigh / 2
        let center = try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: centerY))
        let rim = try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide * 14 / 16, y: centerY))
        XCTAssertEqual(center.alphaComponent, 0)
        XCTAssertGreaterThan(rim.alphaComponent, 0.5)
    }

    @MainActor
    func testNewWorkspaceTabOpensGoogleAndExplicitLinkOpensItsDestination() throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(profileID: UUID(), defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session)

        state.newWorkspaceBrowserTab()
        let first = try XCTUnwrap(session.workspaceBrowserTabs.first?.workspaceID)
        XCTAssertNil(state.primaryBrowserID)
        XCTAssertTrue(state.shouldPresentBrowserPane)
        let link = try XCTUnwrap(URL(string: "https://example.test/article"))
        state.newWorkspaceBrowserTab(url: link)
        let second = try XCTUnwrap(session.humanTab(id: XCTUnwrap(session.selectedTabID))?.workspaceID)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(session.restorablePages.map(\.id), [first, second])
        XCTAssertEqual(session.restorablePages.map { $0.url?.absoluteString },
                       ["https://www.google.com/", link.absoluteString])
        XCTAssertEqual(state.commandTab(inBrowserPane: true), .browser(second))
        state.selectAdjacentWorkspaceTab(.previous, inBrowserPane: true)
        XCTAssertEqual(state.commandTab(inBrowserPane: true), .browser(first))
        state.closeWorkspaceTab(.browser(first))
        XCTAssertEqual(state.commandTabs(inBrowserPane: true), [.browser(second)])
        XCTAssertTrue(state.openWorkspaceTabs.isEmpty)
        XCTAssertTrue(WebUISnapshot(state: state).workspaceBrowsers.isEmpty)
    }

    @MainActor
    func testReloadTargetsOnlyTheSelectedVisibleWorkspacePage() async throws {
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>Reload fixture</title>")
        let url = try await site.start().appendingPathComponent("human/final")
        defer { site.stop() }
        let preferences = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: preferences)
        defer { session.shutdown() }
        let agent = AgentTask(title: "Agent", summary: "", status: .draft, workspace: "", model: "local")
        let state = AppState(tasks: [agent], preferences: preferences, browserSession: session, workspaceLayout: .mixedTabs)
        let id = try session.createTab(url: url)
        let tab = try XCTUnwrap(session.humanTab(id: id))
        let page = try XCTUnwrap(session.webView(for: id))
        state.selectWorkspaceTab(.browser(tab.workspaceID))
        let loaded = await waitForScriptBool(on: page, script: "document.title === 'Reload fixture' && document.readyState === 'complete'")
        XCTAssertTrue(loaded)
        XCTAssertEqual(state.reloadableBrowserTabID(inBrowserPane: false), id)

        state.selectTask(agent.id)
        XCTAssertNil(state.reloadableBrowserTabID(inBrowserPane: false))
        state.selectWorkspaceTab(.browser(tab.workspaceID))
        state.presentedSheet = .settings
        XCTAssertNil(state.reloadableBrowserTabID(inBrowserPane: true))
        state.presentedSheet = nil
        let blank = try session.createTab()
        state.selectWorkspaceTab(.browser(try XCTUnwrap(session.humanTab(id: blank)).workspaceID))
        XCTAssertNil(state.reloadableBrowserTabID(inBrowserPane: false))
        state.selectWorkspaceTab(.browser(tab.workspaceID))
        state.pendingApprovals = [.init(id: "gate", taskID: nil, kind: .computerUse, title: "Approve", summary: "", details: "")]
        XCTAssertNil(state.reloadableBrowserTabID(inBrowserPane: false))
    }

    @MainActor
    func testCycleWorkspaceTabsFollowsMixedOrderAndWraps() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let tasks = ["First", "Second", "History"].map {
            AgentTask(title: $0, summary: "", status: .draft, workspace: "", model: "local")
        }
        let state = AppState(tasks: tasks, preferences: isolatedTestPreferences(), browserSession: session, workspaceLayout: .mixedTabs)
        let first = WorkspaceTabID.agent(tasks[0].id)
        let second = WorkspaceTabID.agent(tasks[1].id)
        state.selectTask(tasks[1].id)
        let page = try session.createTab()
        let browser = WorkspaceTabID.browser(try XCTUnwrap(session.humanTab(id: page)).workspaceID)
        state.workspaceTabs.move(first, to: browser)
        XCTAssertEqual(state.openWorkspaceTabs, [first, browser, second])
        state.selectWorkspaceTab(first)
        for expected in [browser, second, first] {
            state.selectAdjacentWorkspaceTab(.next)
            XCTAssertEqual(state.selectedWorkspaceTab, expected)
        }
        for expected in [second, browser, first] {
            state.selectAdjacentWorkspaceTab(.previous)
            XCTAssertEqual(state.selectedWorkspaceTab, expected)
        }
        state.presentedSheet = .settings
        state.selectAdjacentWorkspaceTab(.next)
        XCTAssertEqual(state.selectedWorkspaceTab, first)
        state.presentedSheet = nil

        state.closeWorkspaceTab(browser)
        state.isTaskSidebarCollapsed = true
        state.selectAdjacentWorkspaceTab(.previous)
        XCTAssertEqual(state.selectedWorkspaceTab, second)
        state.closeWorkspaceTab(first)
        state.selectAdjacentWorkspaceTab(.next)
        XCTAssertEqual(state.selectedWorkspaceTab, second)
        state.closeWorkspaceTab(second)
        state.selectAdjacentWorkspaceTab(.previous)
        XCTAssertNil(state.selectedWorkspaceTab)
        XCTAssertTrue(state.openWorkspaceTabs.isEmpty)
    }

    @MainActor
    func testReopenRestoresBrowserAndAgentTabsInReverseCloseOrder() async throws {
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>Reopened page</title>")
        let origin = try await site.start()
        let url = try XCTUnwrap(URL(string: "human/final#article", relativeTo: origin)?.absoluteURL)
        defer { site.stop() }
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let task = AgentTask(title: "Active agent", summary: "", status: .running, workspace: "", model: "local")
        let state = AppState(tasks: [task], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let originalID = try session.createTab(url: url, requestsMobileSite: true)
        let original = try XCTUnwrap(session.humanTab(id: originalID))
        let originalView = try XCTUnwrap(session.webView(for: originalID))
        let second = try session.createTab()
        let secondBrowser = WorkspaceTabID.browser(try XCTUnwrap(session.humanTab(id: second)).workspaceID)
        let sidebar = state.openWorkspaceTabs
        let strip = session.workspaceBrowserTabs.map(\.workspaceID)
        let browser = WorkspaceTabID.browser(original.workspaceID)
        state.closeWorkspaceTab(browser)
        state.closeWorkspaceTab(secondBrowser)
        state.closeWorkspaceTab(.agent(task.id))
        state.reopenClosedTab()
        XCTAssertEqual(state.selectedWorkspaceTab, .agent(task.id))
        XCTAssertEqual(state.tasks.first { $0.id == task.id }?.status, .running)
        XCTAssertTrue(session.workspaceBrowserTabs.isEmpty)
        state.reopenClosedTab()
        XCTAssertEqual(state.selectedWorkspaceTab, secondBrowser)
        XCTAssertEqual(session.workspaceBrowserTabs.count, 1)
        state.reopenClosedTab()
        XCTAssertEqual(state.selectedWorkspaceTab, browser)
        XCTAssertEqual(state.openWorkspaceTabs, sidebar)
        XCTAssertEqual(session.workspaceBrowserTabs.map(\.workspaceID), strip)
        let restored = try XCTUnwrap(session.humanTab(id: XCTUnwrap(session.selectedTabID)))
        XCTAssertNotEqual(restored.id, originalID)
        XCTAssertTrue(restored.requestsMobileSite)
        let view = try XCTUnwrap(session.webView(for: restored.id))
        XCTAssertFalse(view === originalView)
        let loaded = await waitForScriptBool(on: view, script: "document.title === 'Reopened page' && location.hash === '#article'")
        XCTAssertTrue(loaded)
        XCTAssertEqual(view.url, url)
        XCTAssertFalse(state.canReopenClosedTab)
        state.reopenClosedTab()
        XCTAssertEqual(session.workspaceBrowserTabs.count, 2)
    }

    @MainActor
    func testReopenHonorsSheetAndRemainsAvailableAtAgentLimit() throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, maximumAgentTabs: 1, defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session)
        let id = try session.createTab(url: URL(string: "https://example.test/callback?code=private&state=flow"))
        let original = try XCTUnwrap(session.humanTab(id: id))
        state.closeWorkspaceTab(.browser(original.workspaceID))
        state.presentedSheet = .settings
        state.reopenClosedTab()
        XCTAssertTrue(session.workspaceBrowserTabs.isEmpty)
        XCTAssertFalse(state.canReopenClosedTab)
        state.presentedSheet = nil
        let tool = try session.createToolTab(url: XCTUnwrap(URL(string: "about:blank")))
        state.reopenClosedTab()
        XCTAssertFalse(state.canReopenClosedTab)
        XCTAssertEqual(session.workspaceBrowserTabs.count, 1)
        session.closeTab(tool)
        let reopened = try XCTUnwrap(session.humanTab(id: XCTUnwrap(session.selectedTabID)))
        XCTAssertEqual(reopened.workspaceID, original.workspaceID)
        XCTAssertNil(session.restorablePage(for: reopened)?.url)
        XCTAssertTrue(state.shouldPresentBrowserPane)
        XCTAssertFalse(state.canReopenClosedTab)
    }

    @MainActor
    func testCycleRevealsOffscreenTabAndPreservesComposerFocus() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let tasks = (1...150).map { AgentTask(title: "Agent \($0)", summary: "", status: .draft, workspace: "", model: "local") }
        let state = AppState(tasks: tasks, preferences: isolatedTestPreferences(), browserSession: session)
        for task in tasks.dropFirst() { state.selectTask(task.id) }

        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        await settleLayout(host)
        let chat = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }
            .first { $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil })
        let loaded = await waitForScriptBool(on: chat, script: "document.querySelector('.task-list')?.scrollHeight >= 150 * 28 && document.querySelectorAll('[data-tab-kind]').length < 80")
        XCTAssertTrue(loaded)
        _ = try await chat.evaluateJavaScript("document.querySelector('.composer-shell textarea').focus(); true")
        state.selectAdjacentWorkspaceTab(.previous)
        let revealed = await waitForScriptBool(on: chat, script: """
            (() => {
                const list = document.querySelector('.task-list');
                const row = list.querySelector('[aria-current="page"]');
                return row?.getAttribute('aria-label') === 'Agent 1' && list.scrollTop > 0
                    && row.getBoundingClientRect().bottom <= list.getBoundingClientRect().bottom + 1
                    && document.activeElement === document.querySelector('.composer-shell textarea');
            })()
            """)
        XCTAssertTrue(revealed)
    }

    @MainActor
    func testTwoWorkspaceWindowsKeepTheirOwnSidebarBrowserViewsAndUnsentDraft() async throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let windows = state.workspaceWindows
        let primary = windows.primary, detached = windows.createTemporary()
        state.createTask()
        let agent = try XCTUnwrap(primary.selection)
        let first = try session.createTab()
        let firstTab = try XCTUnwrap(session.humanTab(id: first))
        let second = try session.createTab()
        let secondTab = try XCTUnwrap(session.humanTab(id: second))
        state.selectWorkspaceTab(agent)
        XCTAssertTrue(state.transferTabs([.browser(secondTab.workspaceID)], from: primary, to: detached))

        func show(_ tabs: WorkspaceTabs) async throws -> (NSWindow, WKWebView) {
            let host = NSHostingView(rootView: WebWorkspaceView(state: state, window: tabs))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            await settleLayout(host)
            let shell = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
                $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
            })
            return (window, shell)
        }
        let (mainWindow, mainUI) = try await show(primary)
        defer { mainWindow.close() }
        let (otherWindow, otherUI) = try await show(detached)
        defer { otherWindow.close() }
        let mainReady = await waitForScriptBool(on: mainUI, script: "document.querySelectorAll('.workspace-tab-row').length === 2 && !!document.querySelector('#task-prompt')")
        let otherReady = await waitForScriptBool(on: otherUI, script: "document.querySelectorAll('.workspace-tab-row').length === 1 && !document.querySelector('#task-prompt')")
        XCTAssertTrue(mainReady && otherReady)
        _ = try await mainUI.evaluateJavaScript("""
            const field = document.querySelector('#task-prompt'); field.value = 'Keep my draft';
            field.dispatchEvent(new Event('input', {bubbles:true})); true
            """)
        for _ in 0..<100 where state.composerDrafts[agent.id] == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.composerDrafts[agent.id], "Keep my draft")
        windows.withWindow(primary) { state.selectWorkspaceTab(.browser(firstTab.workspaceID)) }
        for _ in 0..<100 where session.webView(for: first)?.window !== mainWindow || session.webView(for: second)?.window !== otherWindow {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(session.webView(for: first)?.window === mainWindow)
        XCTAssertTrue(session.webView(for: second)?.window === otherWindow)
        XCTAssertTrue(state.transferTabs([agent], from: primary, to: detached))
        let received = await waitForScriptBool(on: otherUI, script: "document.querySelector('#task-prompt')?.value === 'Keep my draft'")
        XCTAssertTrue(received)
        let mainStillBrowser = await waitForScriptBool(on: mainUI, script: "document.querySelectorAll('.workspace-tab-row').length === 1 && !document.querySelector('#task-prompt')")
        XCTAssertTrue(mainStillBrowser)
        XCTAssertEqual(primary.selection, .browser(firstTab.workspaceID))
        XCTAssertEqual(detached.selection, agent)
    }

    @MainActor
    func testSendNowInSecondQueueRowSteersOnlyThatPrompt() async throws {
        try await verifySecondQueueRow(afterFailure: false)
    }

    @MainActor
    func testSendNowInSecondQueueRowAfterErrorStartsOnlyThatPrompt() async throws {
        try await verifySecondQueueRow(afterFailure: true)
    }

    @MainActor
    private func verifySecondQueueRow(afterFailure: Bool) async throws {
        let runtime = QueueControlledRuntime()
        let task = AgentTask(title: "Queue fixture", summary: "", status: .running, workspace: "/tmp", model: "local")
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences(), browserSession: session)
        state.activeTurnTaskIDs.insert(task.id)
        state.connectionState = .connected(provider: runtime.providerName)
        for prompt in ["First", "Second", "Third"] { _ = await state.submitOrQueue(prompt: prompt, toTaskID: task.id) }
        if afterFailure {
            state.apply(.taskStatusChanged(taskID: task.id, status: .failed))
        }

        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        await settleLayout(host)
        let chat = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        let buttons = "Array.from(document.querySelectorAll('.queue-item-actions button[aria-label^=\"Send queued message\"]'))"
        let ready = await waitForScriptBool(on: chat, script: """
            (() => {
                const buttons = \(buttons);
                return buttons.length === 3 && buttons.every(b => !b.disabled && b.textContent.trim() === 'Send'
                    && b.firstElementChild?.tagName.toLowerCase() === 'svg' && b.getBoundingClientRect().width > 0);
            })()
            """)
        XCTAssertTrue(ready, "Expected an enabled Send button on each queued row")
        guard ready else { return }
        if afterFailure { await runtime.holdNextSubmission() }
        else { await runtime.holdNextSteer() }
        _ = try await chat.evaluateJavaScript(buttons + "[1].click(); true")
        let awaitingDelivery = await waitForScriptBool(on: chat, script: """
            document.querySelector('.queue-item-sending .queue-item-text')?.textContent === 'Second'
                && \(buttons).length === 2 && \(buttons).every(b => b.disabled)
            """)
        if afterFailure { await runtime.finishSubmission() }
        else { await runtime.finishSteer() }
        XCTAssertTrue(awaitingDelivery)
        let updated = await waitForScriptBool(on: chat, script: """
            Array.from(document.querySelectorAll('.queue-item-text'), row => row.textContent).join(',') === 'First,Third'
            """)
        XCTAssertTrue(updated)
        let steers = await runtime.steers
        let starts = await runtime.submissions
        XCTAssertEqual(steers.map(\.prompt), afterFailure ? [] : ["Second"])
        XCTAssertEqual(starts.map(\.prompt), afterFailure ? ["Second"] : [])
        XCTAssertEqual((afterFailure ? starts : steers).first?.taskID, task.id)
        XCTAssertEqual(state.pausedQueueTaskIDs.contains(task.id), afterFailure)
        XCTAssertEqual(state.selectedTask?.entries.filter { $0.kind == .user }.map(\.body), ["Second"])
    }

    @MainActor
    func testSearchAndReopenOldestSavedChatInWebKit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KolmogorSidebar-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SidebarHistoryAppServer.ts")
        let executable = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.executable = .fixture(path: executable.path)
        config.codexHomePath = root.path
        config.workspacePath = root.path
        let runtime = SelectableCodexRuntime(configuration: config)
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        let state = AppState(tasks: [], runtime: runtime, preferences: prefs, browserSession: session)
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); session.shutdown() }
        await settleLayout(host)
        let web = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }
            .first { $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil })
        func require(_ condition: String) async throws {
            let matched = await waitForScriptBool(on: web, script: condition)
            if !matched {
                let rows = try await web.evaluateJavaScript("document.querySelectorAll('.task-row').length")
                XCTFail("Condition failed: \(condition); connection=\(state.connectionState), tasks=\(state.tasks.count), saved=\(state.savedChats.count), rows=\(String(describing: rows))")
                throw CocoaError(.coderReadCorrupt)
            }
        }
        state.startRuntimeIfNeeded()
        do {
            try await require("!!document.querySelector('.task-row') && document.querySelectorAll('.task-row').length === 1")
            _ = try await web.evaluateJavaScript("const field = document.querySelector('#task-search'); field.value = 'Saved chat'; field.dispatchEvent(new Event('input', {bubbles:true})); true")
            try await require("document.querySelector('nav[aria-label=Chats]')?.scrollHeight >= 1717 * 28")
            XCTAssertEqual(state.tasks.count + state.savedChats.count, 1717)
            try await require("document.querySelectorAll('.task-row').length < 80")
            _ = try await web.evaluateJavaScript("const list = document.querySelector('.task-list'); list.scrollTop = list.scrollHeight; true")
            try await require("""
                (() => {
                  const list = document.querySelector('.task-list');
                  const row = list.querySelector('[aria-label="Saved chat 1717"]');
                  return row && row.getBoundingClientRect().bottom <= list.getBoundingClientRect().bottom + 1
                    && row.getBoundingClientRect().top >= list.getBoundingClientRect().top
                    && list.querySelectorAll('.task-row').length < 80;
                })()
                """)
            func reads() throws -> [Substring] {
                try String(contentsOf: root.appendingPathComponent("read-ids"), encoding: .utf8).split(separator: "\n")
            }
            XCTAssertEqual(try reads().count, 100)
            _ = try await web.evaluateJavaScript("document.querySelector('#task-search').focus(); true")
            try await require("document.activeElement?.id === 'task-search'")
            _ = try await web.evaluateJavaScript("""
                const search = document.querySelector('#task-search'); search.value = 'Saved chat 1717';
                search.dispatchEvent(new Event('input', {bubbles: true})); true
                """)
            try await require("document.querySelectorAll('.task-row').length === 1 && !document.querySelector('.workspace-close')")
            _ = try await web.evaluateJavaScript("document.querySelector('.task-row').click(); true")
            try await require("!!document.querySelector('.no-task-view[role=alert] button') && !document.querySelector('.composer-shell')")
            _ = try await web.evaluateJavaScript("document.querySelector('.no-task-view button').click(); true")
            try await require("document.querySelector('main.workspace')?.textContent.includes('Transcript for Saved chat 1717') === true")
            try await require("document.querySelectorAll('.task-row').length === 1 && !!document.querySelector('.task-row[aria-current=page]')")
            _ = try await web.evaluateJavaScript("document.querySelector('.workspace-close').click(); true")
            try await require("!!document.querySelector('.task-row:not([aria-current])') && !document.querySelector('.workspace-close')")
            _ = try await web.evaluateJavaScript("document.querySelector('.task-row').click(); true")
            try await require("document.querySelector('main.workspace')?.textContent.includes('Transcript for Saved chat 1717') === true")
            let opened = try XCTUnwrap(state.selectedTask)
            XCTAssertEqual(opened.title, "Saved chat 1717")
            let threadID = try XCTUnwrap(opened.runtimeThreadID)
            XCTAssertEqual(try reads().filter { $0 == threadID }.count, 2)
            XCTAssertEqual(try reads().count, 102)
        } catch {
            _ = await state.shutdownRuntime()
            throw error
        }
        _ = await state.shutdownRuntime()
    }

    @MainActor
    private func commandEditor(_ identifier: String, in host: NSView, window: NSWindow) async throws -> NSTextView {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let field = nativeViews(in: host).compactMap({ $0 as? NSTextField })
                .first(where: { $0.identifier?.rawValue == identifier }),
               let editor = field.currentEditor() as? NSTextView, editor === window.firstResponder {
                return editor
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The \(identifier) field did not receive keyboard focus")
        throw CocoaError(.coderInvalidValue)
    }

    @MainActor
    func testMixedTabsHideSidePaneControlsAndOpenProviderSetupAsATab() async throws {
        let prefs = isolatedTestPreferences()
        let task = AgentTask(title: "First chat", summary: "", status: .draft, workspace: "", model: "local")
        WorkspaceTabs(defaults: prefs).save(SavedWorkspace(order: [.agent(task.id)], selectedAgent: task.id,
            drafts: [:], pages: [], browserIsPrimary: false, showsBrowserPane: true))
        let session = EmbeddedBrowserSession(persistent: false, maximumAgentTabs: 1, defaults: prefs)
        let state = AppState(tasks: [task], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); session.shutdown() }
        await settleLayout(host)
        let web = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        let fullChat = """
            !!document.querySelector('#task-prompt') && innerWidth > 1000 &&
              !document.querySelector('[data-browser-primary], [data-browser-pane], [aria-label="New agent"], [aria-label="Toggle browser"]')
            """
        let restored = await waitForScriptBool(on: web, script: fullChat)
        XCTAssertTrue(restored)
        XCTAssertFalse(state.isBrowserPresented)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.allSatisfy(\.isHidden))
        XCTAssertFalse(nativeViews(in: host).contains { $0.identifier?.rawValue == "chat-new" })

        state.connectModelProvider(route: "browser/chatgpt")
        let setup = try XCTUnwrap(session.setupTab(for: .chatgpt))
        let showingSetup = await waitForScriptBool(on: web, script:
            "!!document.querySelector('[data-browser-primary=native] [data-tab-kind=browser][aria-current=page]') && innerWidth < 300")
        XCTAssertTrue(showingSetup)
        XCTAssertEqual(state.primaryBrowserID, setup.workspaceID)
        XCTAssertFalse(state.isBrowserPresented)
        let page = try XCTUnwrap(session.webView(for: setup.id))
        XCTAssertTrue(page.isDescendant(of: host))
        state.toggleWorkspaceBrowser()
        XCTAssertEqual(state.primaryBrowserID, setup.workspaceID)

        state.selectTask(task.id)
        let switched = await waitForScriptBool(on: web, script: fullChat)
        XCTAssertTrue(switched)
        XCTAssertFalse(state.shouldPresentBrowserPane)
        XCTAssertTrue(session.webView(for: setup.id) === page)

        state.newWorkspaceBrowserTab()
        XCTAssertNil(state.browserTabOpenError)
        let newPage = try XCTUnwrap(state.primaryBrowserID)
        XCTAssertNotEqual(newPage, setup.workspaceID)
        XCTAssertEqual(state.selectedWorkspaceTab, .browser(newPage))
    }

    @MainActor
    func testDirectNewItemCommandsFocusTheDestinationInTheCorrectWindow() async throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        func show(_ tabs: WorkspaceTabs, typeImmediately: Bool = false) async throws -> (NSWindow, NSView, WKWebView) {
            let host = NSHostingView(rootView: WebWorkspaceView(state: state, window: tabs))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1050, height: 700),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            let shell = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
                $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
            })
            if typeImmediately {
                // Send keys before the new WebKit process can acknowledge composer focus.
                XCTAssertNotNil(tabs.launcherChat)
                XCTAssertTrue(window.makeFirstResponder(shell))
                for (character, code): (String, UInt16) in [("a", 0), ("b", 11), ("c", 8)] {
                    for kind: NSEvent.EventType in [.keyDown, .keyUp] {
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
                        window.sendEvent(event)
                    }
                }
            }
            await settleLayout(host)
            let focused = await waitForScriptBool(on: shell, script: "document.activeElement?.id === 'task-prompt'")
            XCTAssertTrue(focused)
            if typeImmediately {
                let fullInput = await waitForScriptBool(on: shell, script: "document.activeElement?.value === 'abc'")
                XCTAssertTrue(fullInput, "A cold window should preserve every keystroke in order")
            }
            return (window, host, shell)
        }
        let primary = state.workspaceWindows.primary
        state.windowHosting.open(.window, from: nil) { XCTAssertTrue($0 === primary) }
        let originalDraft = try XCTUnwrap(primary.newAgentDraft?.task.id)
        let (main, host, shell) = try await show(primary)
        defer { main.close() }
        let type = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: main.windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        main.sendEvent(type)
        let typed = await waitForScriptBool(on: shell, script: "document.querySelector('#task-prompt')?.value === 'z'")
        XCTAssertTrue(typed)

        state.windowHosting.open(.browser, from: main) { _ in XCTFail("A browser tab belongs in the current window") }
        let editor = try await commandEditor("browser-address", in: host, window: main)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        let tabID = try XCTUnwrap(session.selectedTabID)
        let page = try XCTUnwrap(session.webView(for: tabID))
        XCTAssertEqual(page.url, EmbeddedBrowserURLPolicy.newTabURL)
        XCTAssertFalse(nativeViews(in: host).contains { $0.identifier?.rawValue == "workspace-tab-launcher" })
        XCTAssertEqual(editor.string, EmbeddedBrowserURLPolicy.newTabURL.absoluteString)
        // Reproduce WebKit taking the native responder after a navigation. Typing must
        // keep using the actual window responder, including an in-progress selection.
        XCTAssertFalse(page.acceptsFirstResponder)
        _ = main.makeFirstResponder(page)
        main.sendEvent(type)
        XCTAssertEqual(editor.string, "z")
        editor.insertText("123", replacementRange: editor.selectedRange())
        let selection = NSRange(location: 1, length: 2)
        editor.setSelectedRange(selection)
        _ = main.makeFirstResponder(page)
        XCTAssertTrue(main.firstResponder === editor)
        XCTAssertEqual(editor.string, "z123")
        XCTAssertEqual(editor.selectedRange(), selection)
        editor.selectAll(nil)
        let query = "C++ & train times"
        editor.insertText(query, replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(page.url, try EmbeddedBrowserURLPolicy.searchURL(for: query))
        await settleLayout(host)
        XCTAssertTrue(page.acceptsFirstResponder)
        XCTAssertTrue(main.firstResponder === page || (main.firstResponder as? NSView)?.isDescendant(of: page) == true)
        let oldBrowser = try XCTUnwrap(primary.selectedPage)
        XCTAssertEqual(primary.order, [.browser(oldBrowser)])

        var created: WorkspaceTabs?
        state.windowHosting.open(.window, from: main) { created = $0 }
        let other = try XCTUnwrap(created)
        XCTAssertFalse(other === primary)
        XCTAssertNotEqual(other.newAgentDraft?.task.id, originalDraft)
        let (otherWindow, otherHost, _) = try await show(other, typeImmediately: true)
        defer { otherWindow.close() }
        XCTAssertTrue(other.order.isEmpty)
        XCTAssertEqual(primary.selection, .browser(oldBrowser))

        state.windowHosting.open(.browser, from: otherWindow) { _ in XCTFail("Unexpected window") }
        _ = try await commandEditor("browser-address", in: otherHost, window: otherWindow)
        let otherPage = try XCTUnwrap(other.selectedPage)
        XCTAssertNotEqual(otherPage, oldBrowser)
        XCTAssertEqual(other.order, [.browser(otherPage)])
        XCTAssertEqual(primary.order, [.browser(oldBrowser)])
        main.makeKeyAndOrderFront(nil)
        main.makeFirstResponder(page)
        WorkspaceTabLauncher.request(in: main)
        _ = try await commandEditor("workspace-tab-launcher", in: host, window: main)
        state.windowHosting.open(.agent, from: main) { _ in XCTFail("New Agent belongs in the current window") }
        let returned = await waitForScriptBool(on: shell, script: "document.activeElement?.id === 'task-prompt' && document.activeElement.value === 'z'")
        XCTAssertTrue(returned)
        XCTAssertFalse(nativeViews(in: host).contains { $0.identifier?.rawValue == "workspace-tab-launcher" })
        XCTAssertEqual(primary.presentedTaskID, originalDraft)
        XCTAssertEqual(other.selection, .browser(otherPage))
        XCTAssertTrue(state.tasks.isEmpty)
        state.workspaceWindows.withWindow(primary) { XCTAssertTrue(state.presentSettings()) }
        let focusRequest = primary.launcherChat
        for command: WorkspaceWindowHosting.NewItem in [.browser, .agent, .window] {
            state.windowHosting.open(command, from: main) { _ in XCTFail("Shortcuts must respect the open settings sheet") }
        }
        XCTAssertEqual(primary.launcherChat, focusRequest)
        XCTAssertEqual(primary.order, [.browser(oldBrowser)])
        XCTAssertEqual(primary.presentedTaskID, originalDraft)
    }

    @MainActor
    func testNewTabRoutesKeyboardInputToGoogleOrTheNewChatsComposer() async throws {
        let prefs = isolatedTestPreferences()
        let browser = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        let runtime = TabLauncherRuntime()
        WebsiteModelCatalog.save([syntheticQwenChoice], to: prefs)
        let state = AppState(tasks: [], runtime: runtime, preferences: prefs,
                             browserSession: browser, workspaceLayout: .mixedTabs)
        state.connectionState = .connected(provider: runtime.providerName)
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); browser.shutdown() }
        await settleLayout(host)
        let web = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        func open() async throws -> NSTextView {
            let ready = await waitForScriptBool(on: web, script: "!!document.querySelector('button[aria-label=\"New tab\"]')")
            XCTAssertTrue(ready)
            _ = try await web.evaluateJavaScript("document.querySelector('button[aria-label=\"New tab\"]').click(); true")
            return try await commandEditor("workspace-tab-launcher", in: host, window: window)
        }
        func press(_ char: String, code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }

        _ = try await open()
        XCTAssertEqual(NewTabDestination.allCases.map(\.label), ["Browser", "Agent"])
        XCTAssertEqual(NewTabDestination.allCases.map(\.shortcutLabel), ["⌘T", "⇧⌘N"])
        let resources = try XCTUnwrap(WebUIResourceLocator.indexURL).deletingLastPathComponent()
        let agentIcon = try XCTUnwrap(NSImage(contentsOf: resources.appendingPathComponent("icons/agent.svg")))
        XCTAssertEqual(agentIcon.size, NSSize(width: 20, height: 20))
        try press("\r", code: 36)
        XCTAssertEqual(browser.webView(for: try XCTUnwrap(browser.selectedTabID))?.url, EmbeddedBrowserURLPolicy.newTabURL)
        XCTAssertTrue(state.tasks.isEmpty)

        let search = "C++ & coffee"
        let address = try await open()
        address.insertText(search, replacementRange: address.selectedRange())
        try press("\u{f701}", code: 125)
        try press("\u{f700}", code: 126)
        try press("\r", code: 36)
        let url = try XCTUnwrap(browser.webView(for: XCTUnwrap(browser.selectedTabID))?.url)
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "q", value: search)])
        XCTAssertTrue(state.tasks.isEmpty)

        _ = try await open()
        try press("\u{f701}", code: 125)
        try press("\r", code: 36)
        let empty = try XCTUnwrap(state.selectedTaskID)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertEqual(state.openWorkspaceTabs.map(\.kind), [.browser, .browser])
        let focused = await waitForScriptBool(on: web, script: "document.activeElement?.id === 'task-prompt'")
        XCTAssertTrue(focused)
        try press("z", code: 6)
        let typed = await waitForScriptBool(on: web, script: "document.querySelector('#task-prompt')?.value === 'z'")
        XCTAssertTrue(typed)

        _ = try await web.evaluateJavaScript("""
            window.webkit.messageHandlers.localCodex.postMessage({
                action: 'setTaskModel', taskID: '\(empty)', modelID: '\(syntheticQwenChoice.modelID)'
            }); true
            """)
        let picked = await waitForScriptBool(on: web, script: "document.querySelector('.model-selector-trigger')?.textContent.includes('Qwen3.7-Plus') === true")
        XCTAssertTrue(picked)

        let message = "Compare the two train routes"
        let input = try await open()
        input.insertText(message, replacementRange: input.selectedRange())
        try press("\u{f701}", code: 125)
        try press("\r", code: 36)
        let sent = try XCTUnwrap(state.selectedTaskID)
        XCTAssertNotEqual(sent, empty)
        let received = await waitForScriptBool(on: web, script: "document.querySelector('.user-message')?.textContent.includes('Compare the two train routes') === true")
        XCTAssertTrue(received)
        let calls = await runtime.submissions
        XCTAssertEqual(calls.map(\.id), [sent])
        XCTAssertEqual(calls.map(\.prompt), [message])
        XCTAssertEqual(calls.map(\.modelID), [syntheticQwenChoice.modelID])
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(browser.workspaceBrowserTabs.count, 2)
        XCTAssertEqual(state.presentNewAgent().id, empty)
        let preserved = await waitForScriptBool(on: web, script: "document.querySelector('#task-prompt')?.value === 'z'")
        XCTAssertTrue(preserved)
        _ = try await open()
        try press("\u{1b}", code: 53)
        XCTAssertEqual(state.selectedTaskID, empty)
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(browser.workspaceBrowserTabs.count, 2)

        await settleLayout(host)
        XCTAssertFalse(nativeViews(in: host).contains { $0.identifier?.rawValue == "workspace-tab-launcher" })

        // Leave the new chat before WebKit paints it. Submission is already bound to its ID.
        let quick = try await open()
        quick.insertText("Keep working", replacementRange: quick.selectedRange())
        try press("\u{f701}", code: 125)
        try press("\r", code: 36)
        let background = try XCTUnwrap(state.selectedTaskID)
        XCTAssertEqual(state.presentNewAgent().id, empty)
        for _ in 0..<100 where await runtime.submissions.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let completed = await runtime.submissions
        XCTAssertEqual(completed.map(\.id), [sent, background])
        XCTAssertEqual(completed.map(\.prompt), [message, "Keep working"])

        state.defaultModel = "browser/unavailable-fixture"
        let disconnected = try await open()
        disconnected.insertText("Save this draft", replacementRange: disconnected.selectedRange())
        try press("\u{f701}", code: 125)
        try press("\r", code: 36)
        XCTAssertEqual(disconnected.string, "Save this draft")
        XCTAssertEqual(state.composerDrafts[empty], "z")
        XCTAssertEqual(state.tasks.count, 2)
        try press("\u{1b}", code: 53)
        XCTAssertEqual(state.selectedTaskID, empty)
        let canSendDraft = await waitForScriptBool(on: web, script: """
            document.querySelector('#task-prompt')?.value === 'z'
                && document.querySelector('button[aria-label="Send prompt"]')?.disabled === false
            """)
        XCTAssertTrue(canSendDraft)
        _ = try await web.evaluateJavaScript("document.querySelector('button[aria-label=\"Send prompt\"]').click(); true")
        let sentDraft = await waitForScriptBool(on: web, script: """
            Array.from(document.querySelectorAll('.user-message')).some(row => row.textContent.includes('z'))
                && document.querySelector('#task-prompt')?.value === ''
            """)
        XCTAssertTrue(sentDraft)
        let finalCalls = await runtime.submissions
        XCTAssertEqual(finalCalls.map(\.id), [sent, background, empty])
        XCTAssertEqual(finalCalls.map(\.prompt), [message, "Keep working", "z"])
        XCTAssertEqual(state.openWorkspaceTabs.filter { $0.kind == .agent }.count, 3)
        XCTAssertNil(state.workspaceTabs.newAgentDraft)

    }

    @MainActor
    func testPinButtonsMoveAgentAndBrowserTabsAndRestoreTheSelectedTab() async throws {
        let prefs = isolatedTestPreferences(), profile = UUID()
        let browser = EmbeddedBrowserSession(profileID: profile, defaults: prefs)
        let state = AppState(tasks: [], preferences: prefs, browserSession: browser, workspaceLayout: .mixedTabs)
        state.createTask()
        let agent = try XCTUnwrap(state.selectedTaskID)
        let page = try XCTUnwrap(browser.humanTab(id: try browser.createTab())?.workspaceID)
        state.createTask()
        let selected = try XCTUnwrap(state.selectedTaskID)
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); browser.shutdown() }
        await settleLayout(host)
        let ui = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        func inspect(_ condition: String, line: UInt = #line) async throws {
            let matched = await waitForScriptBool(on: ui, script: condition)
            XCTAssertTrue(matched, condition, line: line)
            if !matched { throw CocoaError(.coderInvalidValue) }
        }
        func pressPin(_ tab: String) async throws {
            _ = try await ui.evaluateJavaScript("document.querySelector('[data-drag-id=\"\(tab)\"] .workspace-pin').click(); true")
        }
        try await inspect("document.querySelectorAll('.workspace-pin').length === 3 && !document.querySelector('.sidebar-section-heading')")
        try await inspect("Array.from(document.querySelectorAll('.workspace-pin')).every(button => getComputedStyle(button).pointerEvents === 'auto')")
        // Exercise the shipped row's secondary-click through the bridge, including the icon-only rail.
        let bridge = try XCTUnwrap(ui.navigationDelegate as? WebBridge)
        var menuTitles: [String] = []
        bridge.presentTabMenu = { menu in
            guard let item = menu.items.first else { return XCTFail("Missing pin action") }
            menuTitles.append(item.title)
            menu.performActionForItem(at: 0)
        }
        for compact in [true, false] {
            state.isTaskSidebarCollapsed = compact
            try await inspect(compact ? "!!document.querySelector('.agent-rail')" : "!document.querySelector('.agent-rail')")
            for id in [agent, page.uuidString] {
                for pinned in [true, false] {
                    let row = "document.querySelector('[data-drag-id=\"\(id)\"]')"
                    _ = try await ui.evaluateJavaScript("\(row).dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, cancelable:true, button:2}));true")
                    try await inspect("(\(row).dataset.pinned === 'true') === \(pinned)")
                    XCTAssertEqual(menuTitles.last, pinned ? "Pin Tab" : "Unpin Tab")
                    XCTAssertEqual(state.selectedWorkspaceTab, .agent(selected))
                }
            }
        }
        XCTAssertEqual(menuTitles.count, 8)
        try await pressPin(agent)
        try await inspect("document.querySelector('h2[data-section=pinned] .lucide-pin') && document.querySelectorAll('[data-pinned=true]').length === 1")
        try await inspect("""
            (() => {
                const divider = document.querySelector('[data-section=tabs]');
                const label = divider?.querySelector('span');
                return label && getComputedStyle(label).clipPath === 'inset(50%)'
                    && getComputedStyle(divider, '::before').height === '1px';
            })()
            """)
        try await pressPin(page.uuidString)
        try await inspect("document.querySelectorAll('[data-pinned=true] .lucide-pin-off').length === 2")
        XCTAssertEqual(state.openWorkspaceTabs, [.agent(agent), .browser(page), .agent(selected)])
        XCTAssertEqual(state.selectedWorkspaceTab, .agent(selected))

        try await pressPin(agent)
        try await inspect("document.querySelectorAll('[data-pinned=true]').length === 1")
        try await pressPin(page.uuidString)
        try await inspect("!document.querySelector('h2[data-section=pinned]')")
        try await pressPin(page.uuidString)
        try await inspect("document.querySelector('[data-pinned=true][data-drag-kind=browser]') !== null")
        try await pressPin(agent)
        try await inspect("document.querySelectorAll('[data-pinned=true]').length === 2")
        _ = await state.shutdownRuntime()

        let nextBrowser = EmbeddedBrowserSession(profileID: profile, defaults: prefs)
        defer { nextBrowser.shutdown() }
        let next = AppState(tasks: [], preferences: prefs, browserSession: nextBrowser, workspaceLayout: .mixedTabs)
        XCTAssertEqual(next.openWorkspaceTabs, [.browser(page), .agent(agent), .agent(selected)])
        XCTAssertEqual(WebUISnapshot(state: next).workspacePinnedCount, 2)
        XCTAssertEqual(next.selectedWorkspaceTab, .agent(selected))
        next.selectAdjacentWorkspaceTab(.next)
        XCTAssertEqual(next.selectedWorkspaceTab, .browser(page))
    }

    @MainActor
    func testUnpinnedArticleOpenedByWebsiteSurvivesQuitAndRetainsSelection() async throws {
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: """
            <title>Article</title><a href="/model/start" target="_blank">Read more</a>
            """)
        let root = try await site.start()
        defer { site.stop() }
        let prefs = isolatedTestPreferences(), profile = UUID()
        let session = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let parentID = try session.createTab(url: root.appendingPathComponent("human/final"))
        let parent = try XCTUnwrap(session.humanTab(id: parentID))
        let view = try XCTUnwrap(session.webView(for: parentID))
        let ready = await waitForScriptBool(on: view, script: "!!document.querySelector('a')")
        XCTAssertTrue(ready)
        _ = try await view.evaluateJavaScript("document.querySelector('a').click(); true")
        for _ in 0..<150 where session.workspaceBrowserTabs.count == 1 { try await Task.sleep(for: .milliseconds(20)) }
        let child = try XCTUnwrap(session.workspaceBrowserTabs.first { $0.isPopup })
        let article = try XCTUnwrap(session.webView(for: child.id))
        let loaded = await waitForScriptBool(on: article, script: "location.pathname === '/model/final' && document.title === 'Article'")
        XCTAssertTrue(loaded)
        _ = try await article.evaluateJavaScript("history.pushState({}, '', '#reading');true")
        let address = try XCTUnwrap(URL(string: "model/final#reading", relativeTo: root)?.absoluteURL)
        let childTab = WorkspaceTabID.browser(child.workspaceID)
        state.selectWorkspaceTab(childTab)
        for _ in 0..<150 where state.workspaceTabs.saved?.pages.first(where: { $0.id == child.workspaceID })?.url != address {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(state.workspaceTabs.saved?.pages.first(where: { $0.id == child.workspaceID })?.url, address)
        _ = await state.shutdownRuntime()

        let nextBrowser = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        defer { nextBrowser.shutdown() }
        let next = AppState(tasks: [], preferences: prefs, browserSession: nextBrowser, workspaceLayout: .mixedTabs)
        XCTAssertEqual(next.openWorkspaceTabs, [childTab, .browser(parent.workspaceID)])
        XCTAssertEqual(next.workspaceTabs.pinnedCount, 0)
        XCTAssertEqual(next.selectedWorkspaceTab, childTab)
        XCTAssertEqual(nextBrowser.restorablePages.first { $0.id == child.workspaceID }?.url, address)
    }

    @MainActor
    func testPinnedLinkAndScriptOpenedPagesRestoreWithoutSignInPopups() async throws {
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: """
            <title>Popup pin fixture</title>
            <a id="link" target="_blank" href="/human/start">Read article</a>
            """)
        let root = try await site.start()
        defer { site.stop() }
        let prefs = isolatedTestPreferences(), profile = UUID()
        let browser = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        let state = AppState(tasks: [], preferences: prefs, browserSession: browser, workspaceLayout: .mixedTabs)
        let openerID = try browser.createTab(url: root.appendingPathComponent("human/final"))
        let opener = try XCTUnwrap(browser.webView(for: openerID))
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); browser.shutdown() }
        await settleLayout(host)
        let ui = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        func check(_ view: WKWebView, _ expression: String, line: UInt = #line) async throws {
            let ok = await waitForScriptBool(on: view, script: expression)
            XCTAssertTrue(ok, expression, line: line)
            if !ok { throw CocoaError(.coderInvalidValue) }
        }
        func openChild(_ script: String) async throws -> EmbeddedBrowserTab {
            let previous = Set(browser.workspaceBrowserTabs.map(\.id))
            _ = try await opener.evaluateJavaScript(script + ";true")
            for _ in 0..<150 {
                if let child = browser.workspaceBrowserTabs.first(where: { !previous.contains($0.id) }) { return child }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CocoaError(.coderValueNotFound)
        }
        func pin(_ tab: EmbeddedBrowserTab) async throws {
            let row = "document.querySelector('[data-drag-id=\"\(tab.workspaceID)\"]')"
            try await check(ui, "!!\(row)?.querySelector('.workspace-pin')")
            _ = try await ui.evaluateJavaScript("\(row).querySelector('.workspace-pin').click();true")
            try await check(ui, "\(row)?.dataset.pinned === 'true'")
        }
        try await check(opener, "!!document.getElementById('link')")
        let direct = try XCTUnwrap(browser.humanTab(id: openerID))
        try await pin(direct)
        let link = try await openChild("document.getElementById('link').click()")
        try await pin(link)
        let script = try await openChild("const child = window.open('about:blank'); child.location.assign('/model/final#section')")
        try await pin(script)
        // Pin before a blank child has a destination. Only its first eligible committed URL is saved.
        let pending = try await openChild("window.open('about:blank')")
        try await pin(pending)
        XCTAssertNil(browser.restorablePage(for: pending, pinned: true))
        let pendingView = try XCTUnwrap(browser.webView(for: pending.id))
        _ = try await pendingView.evaluateJavaScript("location.assign('\(root.appendingPathComponent("human/final"))');true")
        try await check(pendingView, "document.title === 'Popup pin fixture'")
        XCTAssertEqual(browser.restorablePage(for: pending, pinned: true)?.url, root.appendingPathComponent("human/final"))
        let linkView = try XCTUnwrap(browser.webView(for: link.id))
        _ = try await linkView.evaluateJavaScript("history.pushState({}, '', '/callback?code=private&state=fixture');true")
        let login = try await openChild("window.open('/model/final#access_token=temporary')")
        let loginView = try XCTUnwrap(browser.webView(for: login.id))
        try await check(loginView, "document.title === 'Popup pin fixture'")
        _ = try await loginView.evaluateJavaScript("location.replace('/human/final');true")
        try await check(loginView, "location.pathname === '/human/final' && document.title === 'Popup pin fixture'")
        let loginRow = "document.querySelector('[data-drag-id=\"\(login.workspaceID)\"]')"
        try await check(ui, "\(loginRow)?.querySelector('.workspace-pin')?.title === 'Pin tab for this session'")
        try await pin(login)
        XCTAssertNil(browser.restorablePage(for: login, pinned: true))
        let scriptView = try XCTUnwrap(browser.webView(for: script.id))
        try await check(scriptView, "location.hash === '#section' && document.title === 'Popup pin fixture'")
        XCTAssertEqual(browser.restorablePage(for: script, pinned: true)?.url?.fragment, "section")
        let pins = [direct, link, script, pending].map { WorkspaceTabID.browser($0.workspaceID) }
        state.selectWorkspaceTab(pins[1])
        XCTAssertEqual(Array(state.workspaceTabs.pinnedTabs), pins + [.browser(login.workspaceID)])
        _ = await state.shutdownRuntime()

        let nextBrowser = try makePersistentBrowserTestSession(profileID: profile, defaults: prefs)
        defer { nextBrowser.shutdown() }
        let next = AppState(tasks: [], preferences: prefs, browserSession: nextBrowser, workspaceLayout: .mixedTabs)
        XCTAssertEqual(next.openWorkspaceTabs, pins)
        XCTAssertEqual(Array(next.workspaceTabs.pinnedTabs), pins)
        XCTAssertEqual(next.selectedWorkspaceTab, pins[1])
        let restored = Dictionary(uniqueKeysWithValues: nextBrowser.restorablePages.map { ($0.id, $0.url) })
        XCTAssertEqual(restored[link.workspaceID], root.appendingPathComponent("human/final"))
        XCTAssertEqual(restored[script.workspaceID], URL(string: "model/final#section", relativeTo: root)?.absoluteURL)
        XCTAssertNil(restored.index(forKey: login.workspaceID))
        XCTAssertFalse(nextBrowser.workspaceBrowserTabs.contains(where: \.isPopup))
    }

    @MainActor
    func testMixedSidebarFaviconSwitchingReorderAndHistory() async throws {
        let html = """
        <title>Cedar rail</title>
        <link rel="icon" href="/images/train.svg">
        <input id="reservation">
        """
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: html, iconPath: "/images/train.svg",
                                                iconDelay: .milliseconds(1000))
        let origin = try await site.start()
        defer { site.stop() }
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let task = AgentTask(title: "Trip agent", summary: "", status: .draft, workspace: "", model: "local")
        let history = (0..<1717).map {
            SavedChatSummary(id: "saved-\($0)", title: "Saved chat \($0)", workspace: "/fixture", updatedAt: Double($0))
        }
        let runtime = TabLauncherRuntime(history: WorkspaceHistory(tasks: [task], savedChats: history))
        let state = AppState(tasks: [task], runtime: runtime, preferences: prefs,
                             browserSession: session, workspaceLayout: .mixedTabsWithSidePane)
        state.startRuntimeIfNeeded()
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1110, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        await settleLayout(hosting)
        let chat = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        func requireDOM(_ script: String, line: UInt = #line) async throws {
            let ok = await waitForScriptBool(on: chat, script: script)
            XCTAssertTrue(ok, script, line: line)
            if !ok { throw CocoaError(.coderInvalidValue) }
        }
        try await requireDOM("!!document.querySelector('.composer-shell textarea') && document.querySelectorAll('.task-row').length === 1")
        let newTabPlus = """
        (() => { const icon = document.querySelector('button[aria-label="New tab"] svg.lucide-plus[aria-hidden="true"]');
          return icon?.getBoundingClientRect().width === 16; })()
        """
        try await requireDOM(newTabPlus)
        _ = try await chat.evaluateJavaScript("""
        const draft = document.querySelector('.composer-shell textarea'); draft.value='Return ticket';
        draft.dispatchEvent(new Event('input', { bubbles:true }));
        document.querySelector('button[aria-label="New tab"]').click(); true
        """)
        let field = try await commandEditor("workspace-tab-launcher", in: hosting, window: window)
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await requireDOM("!!document.querySelector('[data-browser-primary=native]') && innerWidth < 300 && getComputedStyle(document.querySelector('.workspace')).display === 'none'")
        let ref = try XCTUnwrap(state.primaryBrowserID)
        let id = try XCTUnwrap(session.selectedTabID)
        XCTAssertNotEqual(id, ref)
        let page = try XCTUnwrap(session.webView(for: id))
        try session.navigate(tabID: id, to: origin.appendingPathComponent("human/final"))
        try await requireDOM("""
        (() => {
          const spinner = document.querySelector('[data-tab-kind=browser] .site-favicon-spinner');
          return spinner && spinner.closest('button').textContent.includes('Cedar rail')
            && spinner.offsetWidth === 16
            && getComputedStyle(spinner).maskImage.includes('/icons/favicon-loading.svg')
            && getComputedStyle(spinner).animationName === (matchMedia('(prefers-reduced-motion: reduce)').matches ? 'none' : 'favicon-spin');
        })()
        """)
        try await requireDOM("""
        (() => { const row = document.querySelector('.workspace-tab-row [data-tab-kind=browser]');
          const icon = row?.querySelector('img'); return row?.getAttribute('aria-current') === 'page' &&
            row.textContent.includes('Cedar rail') && icon?.complete && icon.naturalWidth === 32; })()
        """)
        let data = try XCTUnwrap(session.humanTab(id: id)?.favicon)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 32)
        XCTAssertGreaterThan(bitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB)?.redComponent ?? 0, 0.95)
        _ = try await page.evaluateJavaScript("document.querySelector('input').value='B12'; history.pushState({}, '', '#seat'); true")
        _ = try await chat.evaluateJavaScript("document.querySelector('[data-tab-kind=agent]').click(); true")
        try await requireDOM("!document.querySelector('[data-browser-primary]') && document.querySelector('.composer-shell textarea')?.value === 'Return ticket' && innerWidth > 600")
        _ = try await chat.evaluateJavaScript("document.querySelector('[data-tab-kind=browser]').click(); true")
        try await requireDOM("!!document.querySelector('[data-browser-primary=native]')")
        let preserved = try await page.evaluateJavaScript("document.querySelector('input').value === 'B12' && location.hash === '#seat'") as? Bool
        XCTAssertEqual(preserved, true)
        XCTAssertTrue(session.webView(for: id) === page)
        state.toggleWorkspaceBrowser()
        XCTAssertNil(state.primaryBrowserID)
        XCTAssertTrue(state.shouldPresentBrowserPane)
        try await requireDOM("getComputedStyle(document.querySelector('.workspace')).display !== 'none' && innerWidth >= 600")
        state.selectWorkspaceTab(.browser(ref))
        try await requireDOM("!!document.querySelector('[data-browser-primary=native] .site-favicon') && innerWidth === 230")
        let lights = try trafficLightFrames(in: window)
        let railWidth: CGFloat = 44
        let expandedCenters = try await sidebarIconCenters(in: chat)
        let toggle = "#task-sidebar-toggle"
        try await requireDOM("!!document.querySelector('\(toggle)[aria-expanded=true] .lucide-panel-left-close')")
        _ = try await chat.evaluateJavaScript("document.querySelector('\(toggle)').click(); true")
        try await requireDOM("!!document.querySelector('.agent-rail .site-favicon') && innerWidth === \(railWidth)")
        try await requireDOM("!!document.querySelector('\(toggle)[aria-expanded=false] .lucide-panel-left-open')")
        try await requireDOM(newTabPlus)
        try await requireDOM("!document.querySelector('.workspace-close')")
        func hover(_ entered: Bool, expectedWidth: CGFloat) throws {
            let area = try XCTUnwrap(chat.trackingAreas.first { $0.owner is SidebarRail })
            XCTAssertEqual(area.rect.width, expectedWidth)
            XCTAssertEqual(area.rect.height, chat.bounds.height)
            let owner = try XCTUnwrap(area.owner as? SidebarRail)
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
            if entered { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
        }
        try await requireDOM("!!document.querySelector('.sidebar-search-icon') && !document.querySelector('#task-search')")
        try hover(true, expectedWidth: railWidth)
        try await requireDOM("innerWidth === 230 && !!document.querySelector('.workspace-close')")
        let peekedCenters = try await sidebarIconCenters(in: chat)
        XCTAssertEqual(peekedCenters, expandedCenters)
        try await requireDOM("!!document.querySelector('\(toggle)[aria-expanded=false] .lucide-panel-left-open')")
        XCTAssertTrue(prefs.bool(forKey: "taskSidebarCollapsed"))
        try await requireDOM("""
            (() => { const row = document.querySelector('.workspace-tab-row:has(.workspace-close)');
              return row.querySelector('.workspace-close').getBoundingClientRect().left >= row.querySelector('.task-row-title').getBoundingClientRect().right
                && getComputedStyle(document.querySelector('.new-task-button')).borderTopWidth === '0px'; })()
            """)
        try await requireDOM("!!document.querySelector('.sidebar-search-row #task-search')")
        try hover(false, expectedWidth: 230)
        try await requireDOM("innerWidth === \(railWidth) && !document.querySelector('.workspace-close')")
        XCTAssertTrue(state.isTaskSidebarCollapsed)
        for _ in 0..<3 {
            try hover(true, expectedWidth: railWidth)
            try await requireDOM("""
                innerWidth === 230 && document.querySelectorAll('.task-row').length === 2
                  && document.querySelectorAll('.workspace-tab-row').length < 80
                """)
            try hover(false, expectedWidth: 230)
            try await requireDOM("innerWidth === \(railWidth) && document.querySelectorAll('.agent-rail .task-row').length === 2")
        }
        let fieldPreserved = try await page.evaluateJavaScript("document.querySelector('input').value === 'B12' && location.hash === '#seat'") as? Bool
        XCTAssertEqual(fieldPreserved, true)
        XCTAssertTrue(session.webView(for: id) === page)
        let collapsedCenters = try await sidebarIconCenters(in: chat)
        XCTAssertEqual(collapsedCenters, expandedCenters)
        for (name, point) in collapsedCenters {
            XCTAssertEqual(point[0], railWidth / 2, accuracy: 0.5, name)
        }
        XCTAssertLessThan(chat.bounds.width, lights.green.maxX)
        let center = try XCTUnwrap(collapsedCenters["Trip agent"])
        let crop = WKSnapshotConfiguration()
        crop.rect = NSRect(x: center[0] - 10, y: center[1] - 10, width: 20, height: 20)
        let icon = try await chat.takeSnapshot(configuration: crop)
        let pixels = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(icon.tiffRepresentation)))
        let shades = (0..<pixels.pixelsHigh).flatMap { y in
            (0..<pixels.pixelsWide).compactMap { x in pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent }
        }
        XCTAssertGreaterThan(try XCTUnwrap(shades.max()) - XCTUnwrap(shades.min()), 0.2, "The idle agent must be painted in the compact rail")
        _ = try await chat.evaluateJavaScript("document.querySelector('\(toggle)').click(); true")
        try await requireDOM("!document.querySelector('.agent-rail') && innerWidth === 230")
        try await requireDOM("!!document.querySelector('\(toggle)[aria-expanded=true] .lucide-panel-left-close')")
        let reopenedCenters = try await sidebarIconCenters(in: chat)
        XCTAssertEqual(reopenedCenters, expandedCenters)
        state.isTaskSidebarCollapsed = true
        try await requireDOM("!!document.querySelector('.agent-rail')")
        _ = try await chat.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'k', metaKey:true, bubbles:true})); true")
        try await requireDOM("innerWidth === 230")
        try await requireDOM("document.activeElement?.id === 'task-search'")
        _ = try await chat.evaluateJavaScript("""
            const input = document.activeElement; input.value = 'Trip agent';
            input.dispatchEvent(new Event('input', {bubbles:true})); true
            """)
        try await requireDOM("document.querySelectorAll('[data-tab-kind]').length === 1")
        state.isTaskSidebarCollapsed = true
        try await requireDOM("innerWidth === \(railWidth) && document.querySelectorAll('.agent-rail .task-row').length === 1 && !!document.querySelector('.agent-rail [aria-label=\"Trip agent\"]')")
        _ = try await chat.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'k', metaKey:true, bubbles:true})); true")
        try await requireDOM("innerWidth === 230")
        try await requireDOM("document.activeElement?.id === 'task-search' && document.activeElement.value === 'Trip agent'")
        _ = try await chat.evaluateJavaScript("document.querySelector('.clear-search').click(); true")
        try await requireDOM("!!document.querySelector('.site-favicon') && innerWidth === 230")
        _ = try await chat.evaluateJavaScript("document.querySelector('[data-tab-kind=browser]').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowDown',altKey:true,bubbles:true})); true")
        try await requireDOM("document.querySelector('[data-tab-kind]')?.dataset.tabKind === 'agent'")
        state.closeWorkspaceTab(.agent(task.id))
        XCTAssertEqual(state.primaryBrowserID, ref)
        XCTAssertEqual(state.tasks.first?.id, task.id)
        try await requireDOM("!document.querySelector('[data-tab-kind=agent]')")
        _ = try await chat.evaluateJavaScript("const search = document.querySelector('#task-search'); search.value = 'Trip agent'; search.dispatchEvent(new Event('input', {bubbles:true})); true")
        try await requireDOM("!!document.querySelector('nav[aria-label=\"Tabs\"] :not([draggable=true]).workspace-tab-row [data-tab-kind=agent]')")
        _ = try await chat.evaluateJavaScript("document.querySelector('[data-tab-kind=agent]').click(); true")
        try await requireDOM("!!document.querySelector('nav[aria-label=\"Tabs\"] [draggable=true] [data-tab-kind=agent]') && !document.querySelector('[data-browser-primary]')")
        try await requireDOM("document.querySelector('.composer-shell textarea')?.value === 'Return ticket'")
        let tool = try session.createToolTab(url: origin.appendingPathComponent("model/final"))
        XCTAssertEqual(WebUISnapshot(state: state).workspaceBrowsers.map(\.id), [ref.uuidString])
        session.closeTab(tool)
        state.closeWorkspaceTab(.browser(ref))
        XCTAssertNil(session.webView(for: id))
        XCTAssertEqual(state.openWorkspaceTabs, [.agent(task.id)])
        state.closeWorkspaceTab(.agent(task.id))
        let restored = AppState(tasks: [task], preferences: prefs, browserSession: EmbeddedBrowserSession(persistent: false))
        XCTAssertTrue(restored.openWorkspaceTabs.isEmpty)
        XCTAssertEqual(restored.tasks.map(\.id), [task.id])

        try await requireDOM("!!document.querySelector('nav[aria-label=\"Tabs\"] :not([draggable=true]).workspace-tab-row [data-tab-kind=agent]:not([aria-current])')")
        _ = try await chat.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'k', metaKey:true, bubbles:true})); true")
        await settleLayout(hosting)
        try await requireDOM("document.activeElement?.id === 'task-search'")
        _ = try await chat.evaluateJavaScript("""
            const filter = document.activeElement; filter.value = 'An unmatched title';
            filter.dispatchEvent(new Event('input', {bubbles:true})); true
            """)
        try await requireDOM("!document.querySelector('[data-tab-kind]')")
        let taskCount = state.tasks.count
        let compose = try composeButton(in: chat)
        let composeRect = compose.convert(compose.bounds, to: nil)
        try await clickInWindow(at: NSPoint(x: composeRect.midX, y: composeRect.midY), window: window)
        try await requireDOM("document.activeElement?.id === 'task-prompt' && !document.querySelector('[data-tab-kind=agent][aria-current=page]')")
        try await requireDOM("document.querySelector('#task-search')?.value === ''")
        XCTAssertEqual(state.tasks.count, taskCount)
        let newAgent = try XCTUnwrap(state.selectedTaskID)
        XCTAssertNotEqual(newAgent, task.id)
        XCTAssertTrue(state.openWorkspaceTabs.isEmpty)
        XCTAssertTrue(session.workspaceBrowserTabs.isEmpty)
        _ = await state.shutdownRuntime()
    }

    @MainActor
    func testOpenAgentOrderRestoresIndependentlyOfBrowserSessionsAndHistory() throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let tasks = ["First", "Second", "Archived"].map { AgentTask(title: $0, summary: "", status: .draft, workspace: "", model: "local") }
        let state = AppState(tasks: tasks, preferences: prefs, browserSession: session)
        state.selectTask(tasks[1].id)
        state.newWorkspaceBrowserTab()
        state.workspaceTabs.move(.agent(tasks[0].id), to: .agent(tasks[1].id))
        let expected = [WorkspaceTabID.agent(tasks[0].id), .agent(tasks[1].id)]
        XCTAssertEqual(state.openWorkspaceTabs.filter { $0.kind == .agent }, expected)
        let restoredSession = EmbeddedBrowserSession(persistent: false)
        defer { restoredSession.shutdown() }
        let restored = AppState(tasks: [], preferences: prefs, browserSession: restoredSession)
        restored.replaceTasks(with: tasks)
        XCTAssertEqual(restored.openWorkspaceTabs, expected)
        XCTAssertEqual(restored.selectedTaskID, tasks[1].id)
        XCTAssertTrue(restored.tasks.contains { $0.id == tasks[2].id })
    }

    @MainActor
    func testMixedWorkspaceReopensPagesAndBindsChatToRestoredThread() async throws {
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>Workspace fixture</title>")
        let address = try await site.start().appendingPathComponent("human/final")
        defer { site.stop() }
        let prefs = isolatedTestPreferences(), profile = UUID()
        let session = EmbeddedBrowserSession(profileID: profile, defaults: prefs)
        let task = AgentTask(title: "Review", summary: "", status: .completed, workspace: "", model: "test")
        let state = AppState(tasks: [task], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabsWithSidePane)
        let thread = UUID().uuidString.lowercased()
        state.apply(.taskThreadBound(taskID: task.id, threadID: thread))
        let id = try session.createTab(url: address, requestsMobileSite: true)
        let page = try XCTUnwrap(session.humanTab(id: id))
        let view = try XCTUnwrap(session.webView(for: id))
        let loaded = await waitForScriptBool(on: view, script: "document.title === 'Workspace fixture'")
        XCTAssertTrue(loaded)
        _ = try await view.evaluateJavaScript("location.hash = 'seat'; true")
        let deadline = ContinuousClock.now + .seconds(5)
        while session.restorablePages.first?.url?.fragment != "seat", .now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(session.restorablePages.first?.url?.fragment, "seat")
        let blankID = try session.createTab()
        let blank = try XCTUnwrap(session.humanTab(id: blankID)?.workspaceID)
        state.selectWorkspaceTab(.browser(blank))
        state.createTask()
        let draft = try XCTUnwrap(state.selectedTaskID)
        state.workspaceTabs.move(.agent(task.id), to: .browser(blank))
        state.selectWorkspaceTab(.browser(page.workspaceID))
        state.toggleWorkspaceBrowser()
        state.selectTask(task.id)
        // Private runtime pages and explicitly closed human tabs are absent from the saved order.
        _ = try session.createModelTab(url: URL(string: "about:blank")!)
        _ = try session.createToolTab(url: URL(string: "about:blank")!)
        let closed = try session.createTab(select: false)
        session.closeTab(closed)
        let expectedOrder = state.openWorkspaceTabs.map { $0 == .agent(task.id) ? .agent(thread) : $0 }
        _ = await state.shutdownRuntime()

        let newSession = EmbeddedBrowserSession(profileID: profile, defaults: prefs)
        defer { newSession.shutdown() }
        let restored = AppState(tasks: [], preferences: prefs, browserSession: newSession, workspaceLayout: .mixedTabsWithSidePane)
        // Simulate browser callbacks while the app server is still reading history.
        let reopened = try XCTUnwrap(newSession.workspaceBrowserTabs.first { $0.workspaceID == page.workspaceID })
        newSession.selectTab(reopened.id)
        let history = AgentTask(id: thread, runtimeThreadID: thread, title: task.title, summary: "",
                                status: .completed, workspace: "", model: task.model)
        restored.replaceTasks(with: [history] + restored.tasks)
        XCTAssertEqual(restored.openWorkspaceTabs, expectedOrder)
        XCTAssertEqual(restored.selectedTaskID, thread)
        XCTAssertTrue(restored.tasks.contains { $0.id == draft && $0.status == .draft })
        XCTAssertNil(restored.primaryBrowserID)
        XCTAssertTrue(restored.shouldPresentBrowserPane)
        XCTAssertEqual(newSession.selectedTabID, reopened.id)
        XCTAssertNotEqual(reopened.id, id)
        XCTAssertFalse(reopened.isWebInspectorEnabled)
        XCTAssertTrue(reopened.requestsMobileSite)
        XCTAssertEqual(newSession.tabs.count, 2)
        let restoredView = try XCTUnwrap(newSession.webView(for: reopened.id))
        let restoredPageLoaded = await waitForScriptBool(on: restoredView, script: "document.title === 'Workspace fixture' && location.hash === '#seat'")
        XCTAssertTrue(restoredPageLoaded)
        restored.selectWorkspaceTab(.browser(blank))
        let next = EmbeddedBrowserSession(profileID: profile, defaults: prefs)
        defer { next.shutdown() }
        let nextState = AppState(tasks: [history], preferences: prefs, browserSession: next, workspaceLayout: .mixedTabsWithSidePane)
        XCTAssertEqual(nextState.primaryBrowserID, blank)
        XCTAssertEqual(nextState.openWorkspaceTabs, expectedOrder)

        // A saved primary page from the mixed layout reopens beside the same chat.
        let split = EmbeddedBrowserSession(profileID: profile, defaults: prefs)
        defer { split.shutdown() }
        let separate = AppState(tasks: [history], preferences: prefs, browserSession: split)
        XCTAssertNil(separate.primaryBrowserID)
        XCTAssertTrue(separate.shouldPresentBrowserPane)
        XCTAssertEqual(split.humanTab(id: try XCTUnwrap(split.selectedTabID))?.workspaceID, blank)
        XCTAssertEqual(separate.openWorkspaceTabs, expectedOrder.filter { $0.kind == .agent })
        XCTAssertEqual(separate.selectedTaskID, nextState.selectedTaskID)
        XCTAssertEqual(separate.workspaceTabs.order, expectedOrder)
        XCTAssertEqual(split.restorablePages.map(\.id), next.restorablePages.map(\.id))

    }

    @MainActor
    func testLegacyOrderMigratesAndClosedTabsStayClosed() throws {
        let prefs = isolatedTestPreferences()
        let tasks = ["alpha", "beta"].map {
            AgentTask(id: $0, title: $0, summary: "", status: .completed, workspace: "", model: "test")
        }
        prefs.set(["beta", "missing", "alpha", "beta"], forKey: "Computa.Workspace.OpenAgents.v1")
        prefs.set(Data([0xff]), forKey: "Computa.Workspace.OpenTabs.v2")
        let first = AppState(tasks: tasks, preferences: prefs)
        XCTAssertEqual(first.selectedTaskID, "beta")
        XCTAssertEqual(first.openWorkspaceTabs, [.agent("beta"), .agent("alpha")])
        first.closeWorkspaceTab(.agent("beta"))
        first.closeWorkspaceTab(.agent("alpha"))
        let next = AppState(tasks: tasks, preferences: prefs)
        XCTAssertTrue(next.openWorkspaceTabs.isEmpty)
        XCTAssertNil(next.selectedTaskID)
    }

    @MainActor
    func testRestoreRespectsProfileAndNeverLoadsCredentialRoutesOrPrivilegedSchemes() throws {
        let prefs = isolatedTestPreferences(), profile = UUID(), blank = UUID()
        let pages = ["file:///tmp/private", "https://user:secret@example.com", "https://example.com/#access_token=secret",
                     "https://example.com/?code=grant&state=test"].map {
            SavedWorkspace.Page(id: UUID(), url: URL(string: $0)!, mobile: false)
        }
        let record = SavedWorkspace(order: pages.map { .browser($0.id) } + [.browser(blank)], selectedAgent: nil,
            drafts: [:], browserProfile: profile, pages: pages + [.init(id: blank, url: nil, mobile: true)],
            selectedPage: blank, browserIsPrimary: true, showsBrowserPane: false)
        let other = EmbeddedBrowserSession(profileID: UUID(), defaults: prefs)
        defer { other.shutdown() }
        other.restoreWorkspacePages(record)
        XCTAssertTrue(other.tabs.isEmpty)
        let session = EmbeddedBrowserSession(profileID: profile, defaults: prefs)
        defer { session.shutdown() }
        session.restoreWorkspacePages(record)
        XCTAssertEqual(session.tabs.count, pages.count + 1)
        XCTAssertTrue(session.restorablePages.allSatisfy { $0.url == nil })
        XCTAssertEqual(session.restorablePages.last?.id, blank)
    }

    @MainActor
    func testDefaultFaviconAndClearingOnNavigationToSiteWithoutOne() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        session.enableWorkspaceFavicons()
        let withIcon = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>First</title>", iconPath: "/favicon.ico")
        // Allow same-origin images, but return a 404 for /favicon.ico.
        let withoutIcon = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>Second</title>",
                                                       iconPath: "/unused.svg")
        defer { withIcon.stop(); withoutIcon.stop() }
        let first = try await withIcon.start(), second = try await withoutIcon.start()
        let id = try session.createTab(url: first.appendingPathComponent("human/final"))
        let tab = try XCTUnwrap(session.humanTab(id: id))
        let deadline = ContinuousClock.now + .seconds(6)
        while tab.favicon == nil, .now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotNil(tab.favicon)
        XCTAssertTrue(withIcon.requests.contains { $0.path == "/favicon.ico" })
        try session.navigate(tabID: id, to: second.appendingPathComponent("human/final"))
        let page = try XCTUnwrap(session.webView(for: id))
        let loaded = await waitForScriptBool(on: page, script: "document.title === 'Second' && document.readyState === 'complete'")
        XCTAssertTrue(loaded)
        let noIconDeadline = ContinuousClock.now + .seconds(5)
        while .now < noIconDeadline,
              tab.isFaviconLoading || !withoutIcon.requests.contains(where: { $0.path == "/favicon.ico" }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(withoutIcon.requests.contains { $0.path == "/favicon.ico" })
        XCTAssertFalse(tab.isFaviconLoading)
        XCTAssertNil(tab.favicon)
    }

    @MainActor
    func testTitlebarSharesBrowserTabsAndSidebarAcrossPaneChanges() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let task = AgentTask(title: "Review the layout", summary: "", status: .draft, workspace: "/tmp/Fixture", model: "local")
        let state = AppState(tasks: [task], preferences: isolatedTestPreferences(), browserSession: session)
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        let first = try session.createTab()
        let second = try session.createTab()
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let frameView = try XCTUnwrap(hosting.superview)
        window.orderBack(nil)
        state.isBrowserPresented = false
        await settleLayout(hosting)
        let toggle = try XCTUnwrap(window.titlebarAccessoryViewControllers.first { $0.layoutAttribute == .right }?.view)
        let toggleCenter = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
        for expected in [true, false] {
            try await clickInWindow(at: toggleCenter, window: window)
            XCTAssertEqual(state.isBrowserPresented, expected)
        }
        for (width, presented) in [(1100, false), (980, true), (1280, true), (1280, false)] {
            window.setContentSize(NSSize(width: width, height: 740))
            state.isBrowserPresented = presented
            state.appearance = width == 980 ? .dark : .light
            await settleLayout(hosting)
            XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 2)
            let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.first { $0.layoutAttribute == .right })
            let frame = accessory.view.convert(accessory.view.bounds, to: nil)
            let trafficLight = close.convert(close.bounds, to: nil)
            XCTAssertEqual(accessory.layoutAttribute, .right)
            XCTAssertEqual(frame.midY, trafficLight.midY, accuracy: 3)
            XCTAssertEqual(frame.maxX, window.frame.width, accuracy: 12)

            let chat = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }
                .first { $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil })
            XCTAssertEqual(chat.convert(chat.bounds, to: nil).maxY, window.frame.height, accuracy: 1)
            let sidebarBehindLights = await waitForScriptBool(on: chat, script: """
                (() => {
                    const sidebar = document.querySelector('.sidebar');
                    const strip = sidebar?.querySelector('.window-drag-strip');
                    const list = sidebar?.querySelector('.task-list');
                    return !!sidebar?.closest('[data-native-sidebar-controls=true]') && !!strip && !!list
                        && !sidebar.querySelector('.window-drag-strip button, .primary-nav')
                        && sidebar.querySelector('#task-search').getBoundingClientRect().top >= strip.getBoundingClientRect().bottom
                        && getComputedStyle(strip).backgroundColor !== getComputedStyle(sidebar).backgroundColor
                        && getComputedStyle(strip).borderBottomWidth === '1px'
                        && strip.getBoundingClientRect().bottom <= list.getBoundingClientRect().top
                        && !sidebar.querySelector('[aria-label="New tab"], [data-tab-kind=browser]')
                        && document.documentElement.dataset.appearance === '\(state.appearance.rawValue)'
                        && sidebar && document.elementFromPoint(120, 12)?.closest('.sidebar') === sidebar
                        && sidebar.getBoundingClientRect().top === 0;
                })()
                """)
            XCTAssertTrue(sidebarBehindLights)
            let leading = try XCTUnwrap(window.titlebarAccessoryViewControllers.first { $0.layoutAttribute == .left }?.view)
            let leadingEnd = leading.convert(leading.bounds, to: nil).maxX
            let titleAligned = await waitForScriptBool(on: chat, script: """
                (() => {
                    const title = document.querySelector('.toolbar-title-block strong');
                    const row = title?.closest('header')?.getBoundingClientRect();
                    if (!row || title.textContent !== 'Review the layout') return false;
                    const text = title.getBoundingClientRect();
                    return text.left >= \(leadingEnd)
                        && Math.abs(row.bottom - 1 - \(window.frame.height - window.contentLayoutRect.maxY)) <= 1
                        && Math.abs((text.top + text.bottom) / 2 - \(window.frame.height - trafficLight.midY)) <= 2;
                })()
                """)
            XCTAssertTrue(titleAligned, "The chat title and its divider should line up with the native title bar")

            let blankTitlebar = NSPoint(x: 300, y: trafficLight.midY)
            let dragTarget = try XCTUnwrap(frameView.hitTest(frameView.convert(blankTitlebar, from: nil)))
            XCTAssertTrue(dragTarget.mouseDownCanMoveWindow)
            XCTAssertFalse(dragTarget === chat || dragTarget.isDescendant(of: chat))

            let compose = try composeButton(in: chat)
            let button = compose.convert(compose.bounds, to: nil)
            let chatFrame = chat.convert(chat.bounds, to: nil)
            XCTAssertFalse(compose.isHidden)
            XCTAssertEqual(button.midY, trafficLight.midY, accuracy: 3)
            if presented {
                XCTAssertEqual(button.maxX, chatFrame.maxX - 6, accuracy: 1)
            } else {
                XCTAssertLessThanOrEqual(button.maxX, frame.minX)
            }
            let count = state.tasks.count
            try await clickInWindow(at: NSPoint(x: button.midX, y: button.midY), window: window)
            XCTAssertEqual(state.tasks.count, count)
            XCTAssertEqual(state.selectedTaskID, state.workspaceTabs.newAgentDraft?.task.id)
            XCTAssertNotEqual(state.selectedTaskID, task.id)
            state.selectTask(task.id)

            guard presented else { continue }
            let split = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? NSSplitView }.first)
            let pane = try XCTUnwrap(split.arrangedSubviews.last)
            if width == 1280 {
                split.setPosition(760, ofDividerAt: 0)
                await settleLayout(hosting)
                let moved = compose.convert(compose.bounds, to: nil)
                XCTAssertEqual(moved.maxX, chat.convert(chat.bounds, to: nil).maxX - 6, accuracy: 1)
                XCTAssertLessThan(moved.maxX, pane.convert(pane.bounds, to: nil).minX)
            }
            let tabs = try XCTUnwrap(nativeViews(in: pane).compactMap { $0 as? NSScrollView }.first)
            let strip = tabs.convert(tabs.bounds, to: nil)
            XCTAssertEqual(strip.midY, trafficLight.midY, accuracy: 3)
            XCTAssertEqual(strip.minX, pane.convert(pane.bounds, to: nil).minX, accuracy: 10)
            XCTAssertLessThan(strip.maxX, frame.minX)
            let address = try XCTUnwrap(nativeViews(in: pane).compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "Search or enter a website address" })
            XCTAssertLessThanOrEqual(address.convert(address.bounds, to: nil).maxY, window.contentLayoutRect.maxY)

            if width == 980 {
                // Two tabs overflow the narrow strip. Select the first, add a tab,
                // and close the new tab at its scrolled-into-view trailing edge.
                try await clickInWindow(at: NSPoint(x: strip.minX + 44, y: trafficLight.midY), window: window)
                XCTAssertEqual(session.selectedTabID, first)
                try await clickInWindow(at: NSPoint(x: strip.maxX + 16, y: trafficLight.midY), window: window)
                XCTAssertEqual(session.humanTabs.count, 3)
                XCTAssertFalse([first, second].contains(try XCTUnwrap(session.selectedTabID)))
                try await clickInWindow(at: NSPoint(x: strip.maxX - 17, y: trafficLight.midY), window: window)
                XCTAssertEqual(session.humanTabs.map(\.id), [first, second])

                let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>Address field fixture</title>")
                let origin = try await site.start()
                defer { site.stop() }
                address.selectText(nil)
                let editor = try XCTUnwrap(address.currentEditor() as? NSTextView)
                editor.insertText(origin.appendingPathComponent("human/final").absoluteString,
                                  replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                let page = try XCTUnwrap(session.webView(for: try XCTUnwrap(session.selectedTabID)))
                let navigated = await waitForScriptBool(on: page, script: "document.title === 'Address field fixture'")
                XCTAssertTrue(navigated, "Return in the address pill should navigate the selected browser tab")
            }
        }
    }

    @MainActor
    func testAgentAddressKeepsSidebarRowsStillAndOpensGoogle() async throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(profileID: UUID(), defaults: prefs)
        let agent = AgentTask(title: "Keep this agent", summary: "", status: .draft, workspace: "", model: "local")
        let state = AppState(tasks: [agent], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        state.browserAddressPlacement = .sidebar
        state.selectTask(agent.id)
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); session.shutdown() }
        await settleLayout(host)
        let sidebar = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        let button = "document.querySelector('button.sidebar-address')"
        let geometry = "Array.from(document.querySelectorAll('.sidebar-address,.sidebar-search-row,.new-task-button,.task-list'), el => el.getBoundingClientRect().top)"
        for compact in [false, true] {
            state.isTaskSidebarCollapsed = compact
            state.selectTask(agent.id)
            let ready = await waitForScriptBool(on: sidebar, script: """
                \(button)?.ariaLabel === 'Open Google in a new tab' && \(button).textContent.trim() === ''
                && Boolean(document.querySelector('.sidebar-search-icon')) === \(compact)
                """)
            XCTAssertTrue(ready)
            let before = try await sidebar.evaluateJavaScript(geometry)
            let tabCount = session.workspaceBrowserTabs.count
            _ = try await sidebar.evaluateJavaScript("\(button).click(); true")
            let opened = await waitForScriptBool(on: sidebar, script: "\(button)?.ariaLabel === 'Website address'")
            XCTAssertTrue(opened)
            let after = try await sidebar.evaluateJavaScript(geometry)
            XCTAssertEqual(try XCTUnwrap(before as? [Double]), try XCTUnwrap(after as? [Double]))
            XCTAssertEqual(session.workspaceBrowserTabs.count, tabCount + 1)
            XCTAssertTrue(state.openWorkspaceTabs.contains(.agent(agent.id)))
            XCTAssertEqual(session.restorablePages.first { $0.id == state.primaryBrowserID }?.url?.host, "www.google.com")
        }
    }

    @MainActor
    func testAddressPlacementSwitchesInSettingsAndTitleBarEditsInPlace() async throws {
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>Address placement</title>")
        let origin = try await site.start()
        let url = origin.appendingPathComponent("human/final")
        let destination = origin.appendingPathComponent("model/final")
        defer { site.stop() }
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let id = try session.createTab(url: url)
        let page = try XCTUnwrap(session.webView(for: id))
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let tab = WorkspaceTabID.browser(try XCTUnwrap(session.humanTab(id: id)?.workspaceID))
        state.selectWorkspaceTab(tab)
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 730),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settleLayout(host)
        let shell = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        let ready = await waitForScriptBool(on: page, script: "document.title === 'Address placement'")
        XCTAssertTrue(ready)
        XCTAssertEqual(state.browserAddressPlacement, .titleBar)
        let light = try XCTUnwrap(window.standardWindowButton(.closeButton))
        // Hit the centers of the three 22-point toolbar buttons (2-point gaps, 8-point leading inset).
        let lights = try trafficLightFrames(in: window)
        func historyPoint(_ index: Int) -> NSPoint {
            let leading = lights.green.maxX + lights.red.minX
            return NSPoint(x: leading + 19 + CGFloat(index) * 24, y: light.convert(light.bounds, to: nil).midY)
        }
        for (width, collapsed) in [(1100, false), (850, true)] {
            window.setContentSize(.init(width: width, height: 730))
            state.isTaskSidebarCollapsed = collapsed
            await settleLayout(host)
            let lightY = light.convert(light.bounds, to: nil).midY
            let pageFrame = page.convert(page.bounds, to: nil)
            XCTAssertEqual(pageFrame.maxY, window.contentLayoutRect.maxY, accuracy: 3)
            try await clickInWindow(at: .init(x: pageFrame.midX, y: lightY), window: window, throughApplication: true)
            let editor = try await commandEditor("browser-address", in: host, window: window)
            let field = try XCTUnwrap(editor.delegate as? NSTextField)
            let frame = field.convert(field.bounds, to: nil)
            XCTAssertEqual(frame.midY, lightY, accuracy: 3)
            XCTAssertGreaterThan(frame.minX, historyPoint(2).x)
            XCTAssertLessThanOrEqual(frame.maxX, pageFrame.maxX)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: url.absoluteString.utf16.count))
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            await settleLayout(host)
        }
        BrowserAddressPalette.request(in: window)
        let editor = try await commandEditor("browser-address", in: host, window: window)
        editor.insertText(destination.absoluteString, replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let navigated = await waitForScriptBool(on: page, script: "location.pathname === '/model/final' && document.title === 'Address placement'")
        XCTAssertTrue(navigated)
        // Another window can own the global session selection while this window shows its own page.
        let otherWindow = state.workspaceWindows.createTemporary()
        let otherPageID = state.workspaceWindows.withWindow(otherWindow) { state.newWorkspaceBrowserTab(url: url) }
        XCTAssertNotNil(otherPageID)
        XCTAssertNotEqual(session.selectedTabID, id)
        XCTAssertEqual(state.selectedWorkspaceTab, tab)
        try await clickInWindow(at: historyPoint(0), window: window, throughApplication: true)
        let wentBack = await waitForScriptBool(on: page, script: "location.pathname === '/human/final'")
        XCTAssertTrue(wentBack)
        try await clickInWindow(at: historyPoint(1), window: window, throughApplication: true)
        let wentForward = await waitForScriptBool(on: page, script: "location.pathname === '/model/final' && document.title === 'Address placement'")
        XCTAssertTrue(wentForward)
        _ = try await page.evaluateJavaScript("window.beforeReload = true")
        try await clickInWindow(at: historyPoint(2), window: window, throughApplication: true)
        let reloaded = await waitForScriptBool(on: page, script: "location.pathname === '/model/final' && document.title === 'Address placement' && !window.beforeReload")
        XCTAssertTrue(reloaded)
        func choose(_ value: String) async throws {
            state.presentSettings()
            let picker = "document.querySelector('select[aria-label=\"Address bar location\"]')"
            let shown = await waitForScriptBool(on: shell, script: "!!\(picker)")
            XCTAssertTrue(shown)
            _ = try await shell.evaluateJavaScript("\(picker).value = '\(value)'; \(picker).dispatchEvent(new Event('change', { bubbles: true })); true")
            let changed = await waitForScriptBool(on: shell, script: "\(picker).value === '\(value)'")
            XCTAssertTrue(changed)
            for _ in 0..<100 where state.browserAddressPlacement.rawValue != value { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(state.browserAddressPlacement.rawValue, value)
            _ = try await shell.evaluateJavaScript("document.querySelector('[aria-label=\"Close settings\"]').click(); true")
            await settleLayout(host)
        }
        try await choose("sidebar")
        let restored = AppState(tasks: [], preferences: prefs, browserSession: EmbeddedBrowserSession(persistent: false), workspaceLayout: .mixedTabs)
        XCTAssertEqual(restored.browserAddressPlacement, .sidebar)
        restored.browserSession.shutdown()
        let inSidebar = await waitForScriptBool(on: shell, script: "!!document.querySelector('button.sidebar-address')")
        XCTAssertTrue(inSidebar)
        XCTAssertEqual(page.convert(page.bounds, to: nil).maxY, window.frame.height, accuracy: 1)
        try await choose("titleBar")
        let removed = await waitForScriptBool(on: shell, script: "!document.querySelector('button.sidebar-address')")
        XCTAssertTrue(removed)
        XCTAssertEqual(state.selectedWorkspaceTab, tab)
        XCTAssertTrue(session.webView(for: id) === page)
    }

    @MainActor
    func testSidebarAddressOpensCenteredSelectsReplacesAndNavigates() async throws {
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<!doctype html><title>Address selection</title><button>Top control</button>")
        let url = try await site.start().appendingPathComponent("human/final")
        defer { site.stop() }
        let session = EmbeddedBrowserSession(persistent: false, defaults: isolatedTestPreferences())
        let tab = try session.createTab(url: url)
        let page = try XCTUnwrap(session.webView(for: tab))
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session, workspaceLayout: .mixedTabs)
        state.browserAddressPlacement = .sidebar
        state.selectWorkspaceTab(.browser(try XCTUnwrap(session.humanTab(id: tab)?.workspaceID)))
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); session.shutdown() }
        let loaded = await waitForScriptBool(on: page, script: "document.title === 'Address selection'")
        XCTAssertTrue(loaded)
        window.makeFirstResponder(page)
        await settleLayout(host)
        let sidebar = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }
            .first { $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil })
        let toggle = "document.querySelector('#task-sidebar-toggle')"
        var expandedToggle: [Double]?
        let pill = "document.querySelector('button.sidebar-address')"
        func openAddress() async throws -> NSTextView {
            _ = try await sidebar.evaluateJavaScript("\(pill).click(); true")
            await settleLayout(host)
            let field = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "browser-address" })
            XCTAssertEqual(field.convert(field.bounds, to: nil).midX, window.frame.width / 2, accuracy: 24)
            XCTAssertEqual(field.convert(field.bounds, to: nil).midY, window.frame.height * 2 / 3, accuracy: 2)
            return try XCTUnwrap(field.currentEditor() as? NSTextView)
        }
        func selectedURL(_ editor: NSTextView, _ expected: URL, line: UInt = #line) {
            XCTAssertEqual(editor.string, expected.absoluteString, line: line)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: expected.absoluteString.utf16.count), line: line)
        }
        for (width, height, collapsed) in [(1100, 740, false), (980, 640, true), (1280, 820, false)] {
            window.setContentSize(NSSize(width: width, height: height))
            if state.isTaskSidebarCollapsed != collapsed {
                _ = try await sidebar.evaluateJavaScript("\(toggle).click(); true")
            }
            await settleLayout(host)
            let expectedWidth = collapsed ? 44 : 230
            let inSidebar = await waitForScriptBool(on: sidebar, script: """
                (() => {
                    const field = \(pill), filter = document.querySelector('.sidebar-search-row');
                    if (!field || !filter || !field.closest('.sidebar')) return false;
                    const rect = field.getBoundingClientRect();
                    return innerWidth === \(expectedWidth) && rect.top >= document.querySelector('.window-drag-strip').getBoundingClientRect().bottom - 1
                        && rect.bottom <= filter.getBoundingClientRect().top && rect.right <= innerWidth;
                })()
                """)
            XCTAssertTrue(inSidebar)
            XCTAssertEqual(state.isTaskSidebarCollapsed, collapsed)
            XCTAssertTrue(window.titlebarAccessoryViewControllers.allSatisfy(\.isHidden))
            let navigationLayout = await waitForScriptBool(on: sidebar, script: """
                (() => {
                    const strip = document.querySelector('.window-drag-strip');
                    const row = document.querySelector('.sidebar-controls-row');
                    const button = \(toggle), nav = row?.querySelector('.sidebar-browser-navigation');
                    if (!row || button?.parentElement !== row || strip.querySelector('button')) return false;
                    const r = row.getBoundingClientRect(), t = button.getBoundingClientRect();
                    if (r.top < strip.getBoundingClientRect().bottom || r.bottom > \(pill).getBoundingClientRect().top
                        || t.left !== r.left || Math.abs(t.left + t.width / 2 - 22) > 0.5) return false;
                    if (\(collapsed)) return !nav && row.querySelectorAll('button').length === 1;
                    if (innerWidth - r.right > 8) return false;
                    if (!nav) return false;
                    const n = nav.getBoundingClientRect();
                    return n.left > t.right && n.right === r.right && Math.abs((n.top+n.bottom-t.top-t.bottom)/2) <= 1
                        && Array.from(nav.querySelectorAll('button'), b => b.ariaLabel).join(',') === 'Back,Forward,Reload';
                })()
                """)
            XCTAssertTrue(navigationLayout)
            let position = try await sidebar.evaluateJavaScript("(() => {const r = \(toggle).getBoundingClientRect(); return [r.x, r.y]})()")
            let origin = try XCTUnwrap(position as? [Double])
            if let expandedToggle { XCTAssertEqual(origin, expandedToggle) }
            else { expandedToggle = origin }
            let pageFrame = page.convert(page.bounds, to: nil)
            XCTAssertEqual(pageFrame.maxY, window.frame.height, accuracy: 1)
            XCTAssertEqual(pageFrame.minY, 0, accuracy: 1)
            let point = NSPoint(x: pageFrame.minX + 25, y: pageFrame.maxY - 15)
            let root = try XCTUnwrap(host.superview)
            let hit = root.hitTest(root.convert(point, from: nil))
            XCTAssertTrue(hit === page || hit?.isDescendant(of: page) == true)
            let pageFillsWindow = await waitForScriptBool(on: page, script: """
                Math.abs(innerHeight - \(pageFrame.height)) <= 1 && document.elementFromPoint(25, 15)?.tagName === 'BUTTON'
                """)
            XCTAssertTrue(pageFillsWindow, "The reclaimed header is part of the interactive website viewport")
            let editor = try await openAddress()
            selectedURL(editor, url)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            await settleLayout(host)
            XCTAssertEqual(page.url, url)
        }
        let editor = try await openAddress()
        editor.moveRight(nil)
        XCTAssertEqual(editor.selectedRange().length, 0)
        BrowserAddressPalette.request(in: window) // The window-level ⌘L action.
        await settleLayout(host)
        selectedURL(editor, url)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        window.sendEvent(key)
        XCTAssertEqual(editor.string, "z")
        let destination = url.appendingPathComponent("next")
        editor.insertText(destination.absoluteString, replacementRange: NSRange(location: 0, length: 1))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let navigated = await waitForScriptBool(on: page, script: "location.pathname.endsWith('/next')")
        XCTAssertTrue(navigated)

        let command = try await openAddress()
        command.insertText("back", replacementRange: command.selectedRange())
        await settleLayout(host)
        let field = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "browser-address" })
        XCTAssertEqual(field.convert(field.bounds, to: nil).midY, window.frame.height * 2 / 3, accuracy: 2)
        command.doCommand(by: #selector(NSResponder.moveDown(_:)))
        await settleLayout(host)
        command.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let returned = await waitForScriptBool(on: page, script: "location.pathname.endsWith('/human/final')")
        XCTAssertTrue(returned, "Down and Return should execute the matching Back command")

        func clickNavigation(_ label: String) async throws {
            let control = "document.querySelector('.sidebar-browser-navigation button[aria-label=\"\(label)\"]:enabled')"
            let enabled = await waitForScriptBool(on: sidebar, script: "!!\(control)")
            XCTAssertTrue(enabled)
            _ = try await sidebar.evaluateJavaScript("\(control).click(); true")
        }
        try await clickNavigation("Forward")
        let wentForward = await waitForScriptBool(on: page, script: "location.pathname.endsWith('/next')")
        XCTAssertTrue(wentForward)
        try await clickNavigation("Back")
        let wentBack = await waitForScriptBool(on: page, script: "document.title === 'Address selection'")
        XCTAssertTrue(wentBack)
        _ = try await page.evaluateJavaScript("window.beforeReload = true")
        try await clickNavigation("Reload")
        let reloaded = await waitForScriptBool(on: page, script: "document.title === 'Address selection' && !window.beforeReload")
        XCTAssertTrue(reloaded)

        let other = try session.createTab(url: url.appendingPathComponent("alternate"))
        let otherPage = try XCTUnwrap(session.webView(for: other))
        let otherLoaded = await waitForScriptBool(on: otherPage, script: "location.pathname.endsWith('/alternate')")
        XCTAssertTrue(otherLoaded)
        let original = try XCTUnwrap(session.humanTab(id: tab))
        state.selectWorkspaceTab(.browser(original.workspaceID))
        await settleLayout(host)
        let switcher = try await openAddress()
        switcher.insertText("alternate", replacementRange: switcher.selectedRange())
        await settleLayout(host)
        switcher.doCommand(by: #selector(NSResponder.moveDown(_:)))
        await settleLayout(host)
        switcher.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(session.selectedTabID, other)
        state.selectWorkspaceTab(.browser(original.workspaceID))
        await settleLayout(host)

        let search = try await openAddress()
        search.insertText("cedar rail times", replacementRange: search.selectedRange())
        search.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        for _ in 0..<100 where page.url?.host != "www.google.com" { try await Task.sleep(for: .milliseconds(20)) }
        let request = try XCTUnwrap(page.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(session.selectedTabID, tab)
        XCTAssertEqual(request.host, "www.google.com")
        XCTAssertEqual(request.queryItems?.first { $0.name == "q" }?.value, "cedar rail times")
    }

    @MainActor
    func testAgentMenuStartsFreshAndOpensOriginalFromHistoryInWebKit() async throws {
        let threadID = UUID().uuidString.lowercased()
        let task = AgentTask(runtimeThreadID: threadID, title: "Earlier review", summary: "",
            status: .completed, workspace: "/tmp", model: LocalModelCatalog.defaultModelID,
            entries: [.init(kind: .assistant, title: "Kolmogor", body: "Original conversation marker")])
        let state = AppState(tasks: [task], preferences: isolatedTestPreferences())
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); state.browserSession.shutdown() }
        await settleLayout(host)
        let web = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        func require(_ expression: String) async throws {
            let matched = await waitForScriptBool(on: web, script: expression)
            XCTAssertTrue(matched, expression)
            if !matched { throw CocoaError(.coderInvalidValue) }
        }
        func choose(_ label: String) async throws {
            try await require("!!document.querySelector('[aria-label=\"Agent menu\"]')")
            _ = try await web.evaluateJavaScript("document.querySelector('[aria-label=\"Agent menu\"]').dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true})); true")
            let item = "[...document.querySelectorAll('[role=menuitem]')].find(item => item.textContent.trim() === '\(label)')"
            try await require("!!(\(item))")
            _ = try await web.evaluateJavaScript("(\(item)).click(); true")
        }
        try await choose("Agent settings")
        try await require("!!document.querySelector('dialog[open] input')")
        _ = try await web.evaluateJavaScript("""
            const nameField = document.querySelector('dialog input'); nameField.value = 'Release reviewer';
            nameField.dispatchEvent(new Event('input', {bubbles:true}));
            document.querySelector('dialog form').requestSubmit(); true
            """)
        try await require("document.querySelector('.toolbar-title-block strong')?.textContent === 'Release reviewer'")
        try await choose("Start fresh")
        try await require("!!document.querySelector('.empty-conversation') && !document.querySelector('main.workspace')?.textContent.includes('Original conversation marker')")
        XCTAssertNotEqual(state.selectedTaskID, task.id)
        try await choose("History")
        try await require("!!document.querySelector('dialog[open] .agent-history-list button')")
        _ = try await web.evaluateJavaScript("document.querySelector('.agent-history-list button').click(); true")
        try await require("document.querySelector('main.workspace')?.textContent.includes('Original conversation marker') === true")
        XCTAssertEqual(state.selectedTaskID, task.id)
    }

    @MainActor
    func testSidebarMovesThroughIntermediateWidthsInChatAndOnAWebpage() async throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let task = AgentTask(title: "Sidebar motion", summary: "", status: .draft, workspace: "", model: "fixture")
        let state = AppState(tasks: [task], preferences: prefs, browserSession: session, workspaceLayout: .mixedTabs)
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await settleLayout(host)
        let shell = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        let rail: CGFloat = 44

        func toggle(from start: CGFloat, to end: CGFloat) async throws {
            let ready = await waitForScriptBool(on: shell, script:
                "Math.abs(document.querySelector('.sidebar')?.getBoundingClientRect().width - \(start)) < 1")
            XCTAssertTrue(ready, "Start at the settled width \(start)")
            _ = try await shell.evaluateJavaScript("""
                (() => {
                    const sidebar = document.querySelector('.sidebar');
                    window.sidebarSamples = [];
                    const sample = () => {
                        const search = sidebar.querySelector('.sidebar-search-row svg').getBoundingClientRect();
                        const title = document.querySelector('.toolbar-title-block').getBoundingClientRect();
                        window.sidebarSamples.push([sidebar.getBoundingClientRect().width, search.left + search.width / 2, title.left, title.top]);
                    };
                    sample();
                    window.sidebarObserver = new ResizeObserver(sample);
                    window.sidebarObserver.observe(sidebar);
                    const shell = sidebar.closest('.app-shell');
                    window.sidebarTiming = [];
                    if (!shell.hasAttribute('data-browser-primary') && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
                        // Seek the actual CSS transition so a missed display frame cannot change the measured curve.
                        if (document.hidden) document.documentElement.setAttribute('data-page-visible', '');
                        const changed = new MutationObserver(() => {
                            changed.disconnect();
                            const transition = sidebar.getAnimations().find(a => a.transitionProperty === 'flex-basis');
                            if (transition) {
                                transition.pause();
                                const duration = transition.effect.getTiming().duration;
                                window.sidebarTiming.push(duration);
                                for (const fraction of [0.25, 0.5, 0.75]) {
                                    transition.currentTime = duration * fraction;
                                    sample();
                                    window.sidebarTiming.push(sidebar.getBoundingClientRect().width);
                                }
                                transition.finish();
                            }
                            if (document.hidden) document.documentElement.removeAttribute('data-page-visible');
                        });
                        changed.observe(shell, { attributes: true, attributeFilter: ['data-sidebar-collapsed'] });
                    }
                    document.querySelector('#task-sidebar-toggle').click();
                    return true;
                })()
                """)
            let settled = await waitForScriptBool(on: shell, script:
                "Math.abs(document.querySelector('.sidebar').getBoundingClientRect().width - \(end)) < 1")
            XCTAssertTrue(settled, "Finish at \(end)")
            let trace = try await shell.evaluateJavaScript("window.sidebarObserver.disconnect(); window.sidebarSamples")
            let samples = try XCTUnwrap(trace as? [[CGFloat]])
            let widths = samples.map { $0[0] }
            let searchX = try XCTUnwrap(samples.first?[1])
            XCTAssertTrue(samples.allSatisfy { abs($0[1] - searchX) <= 1 }, "Search should stay on its icon column: \(samples)")
            if state.primaryBrowserID == nil, let first = samples.first {
                XCTAssertTrue(samples.allSatisfy { $0[2] == first[2] && $0[3] == first[3] },
                              "The agent title should stay at its window position throughout the transition.")
            }
            let intermediate = widths.filter { $0 > min(start, end) + 1 && $0 < max(start, end) - 1 }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertTrue(intermediate.isEmpty, "Reduce Motion should snap to the final width: \(widths)")
            } else {
                XCTAssertFalse(intermediate.isEmpty, "The divider should travel between \(start) and \(end): \(widths)")
                if state.primaryBrowserID == nil {
                    let trace = try await shell.evaluateJavaScript("window.sidebarTiming")
                    let timing = try XCTUnwrap(trace as? [Double])
                    let duration = try XCTUnwrap(timing.first)
                    XCTAssertEqual(duration, 140, accuracy: 0.01)
                    XCTAssertEqual(duration, SidebarRail.transitionDuration * 1000, accuracy: 0.01)
                    let webPercent = timing.dropFirst().map { Int((100 * ($0 - start) / (end - start)).rounded()) }
                    let nativePercent = [0.25, 0.5, 0.75].map { Int((100 * SidebarRail.transitionCurve.value(at: $0)).rounded()) }
                    XCTAssertEqual(webPercent, [7, 50, 93])
                    XCTAssertEqual(nativePercent, webPercent)
                }
            }
        }

        try await toggle(from: 216, to: rail)
        try await toggle(from: rail, to: 216)
        let id = try session.createTab()
        let tab = try XCTUnwrap(session.humanTab(id: id))
        let page = try XCTUnwrap(session.webView(for: id))
        page.loadHTMLString("<input id='draft' value='Keep this edit'>", baseURL: nil)
        state.selectWorkspaceTab(.browser(tab.workspaceID))
        // The DOM cannot see movement of the WebKit surface inside its native split item.
        if #available(macOS 14.4, *) {
            let ready = await waitForScriptBool(on: shell, script: "!!document.querySelector('[data-browser-primary=native] .sidebar-search-row svg')")
            XCTAssertTrue(ready)
            _ = try await shell.evaluateJavaScript("""
                const marker = document.createElement('style');
                marker.textContent = '.sidebar-search-row svg { background: rgb(255,0,255) !important; }';
                document.head.appendChild(marker); true
                """)
            let capture = try await SidebarIconCapture(window: window)
            try await capture.start()
            do {
                let baseline = try await capture.waitForIcon()
                try await toggle(from: SidebarRail.expandedWidth, to: rail)
                try await toggle(from: rail, to: SidebarRail.expandedWidth)
                try await capture.stop()
                let samples = capture.positions
                XCTAssertGreaterThan(samples.count, 2)
                XCTAssertTrue(samples.allSatisfy { $0.map { abs($0 - baseline) <= 1 } == true },
                              "Search moved or disappeared in window coordinates: \(samples)")
            } catch {
                try? await capture.stop()
                throw error
            }
        } else {
            try await toggle(from: SidebarRail.expandedWidth, to: rail)
            try await toggle(from: rail, to: SidebarRail.expandedWidth)
        }
        XCTAssertTrue(session.webView(for: id) === page)
        let draft = try await page.evaluateJavaScript("document.querySelector('#draft').value") as? String
        XCTAssertEqual(draft, "Keep this edit")
    }

    @MainActor
    func testBothSidebarWidthsPreserveAgentRowsAndAnimateOnlyWorkingAgents() async throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let thread = UUID().uuidString.lowercased()
        let tasks = [
            AgentTask(title: "Inbox", summary: "", status: .draft, workspace: "", model: "local"),
            AgentTask(title: "Research", summary: "", status: .running, workspace: "", model: "local"),
            AgentTask(runtimeThreadID: thread, title: "Review", summary: "", status: .running, workspace: "", model: "local"),
            AgentTask(title: "Earlier", summary: "", status: .completed, workspace: "", model: "local"),
            AgentTask(title: "Failed", summary: "", status: .failed, workspace: "", model: "local")
        ] + (1...20).map { AgentTask(title: "Archived \($0)", summary: "", status: .completed, workspace: "", model: "local") }
        let state = AppState(tasks: tasks, preferences: prefs, browserSession: session)
        for task in tasks.reversed() { state.workspaceTabs.open(.agent(task.id)) }
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        await settleLayout(hosting)
        let chat = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }
            .first { $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil })
        let expanded = await waitForScriptBool(on: chat, script: """
            document.querySelectorAll('.task-row').length === 25 && document.querySelectorAll('.task-row .agent-status-icon').length === 25
                && !!document.querySelector('[aria-label="Archived 20"]') && !document.querySelector('.agent-rail')
                && !document.querySelector('.task-row-status, .task-row-unread')
            """)
        XCTAssertTrue(expanded)
        let titleFits = await waitForScriptBool(on: chat, script: """
            (() => {
                const row = document.querySelector('[aria-label="Research — Working"]');
                if (!row) return false;
                const title = row.querySelector('.task-row-title').getBoundingClientRect();
                const elapsed = row.querySelector('.task-row-elapsed').getBoundingClientRect();
                const inset = title.left - row.getBoundingClientRect().left;
                return inset > 0 && inset <= 48 && elapsed.left - title.left > 100 && title.right <= elapsed.left;
            })()
            """)
        XCTAssertTrue(titleFits)
        let rowPitch = try await chat.evaluateJavaScript("""
            (() => {
                const [first, second] = document.querySelectorAll('[data-tab-kind]');
                return second.getBoundingClientRect().top - first.getBoundingClientRect().top;
            })()
            """)
        XCTAssertEqual(rowPitch as? Double, 28)
        let expandedCenters = try await sidebarIconCenters(in: chat)
        let button = try XCTUnwrap(window.titlebarAccessoryViewControllers.first { $0.layoutAttribute == .left }?.view)
        let bounds = button.convert(button.bounds, to: nil)
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let light = zoom.convert(zoom.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(bounds.minX, light.maxX)
        XCTAssertLessThan(bounds.minX - light.maxX, 24)
        XCTAssertEqual(bounds.midY, light.midY, accuracy: 3)
        let toggle = NSPoint(x: bounds.minX + 14, y: bounds.midY)
        try await clickInWindow(at: toggle, window: window)
        XCTAssertTrue(state.isTaskSidebarCollapsed)
        let compactEnd = button.convert(button.bounds, to: nil).maxX
        let working = await waitForScriptBool(on: chat, script: """
            document.querySelectorAll('.agent-rail .task-row').length === 25
                && document.querySelectorAll('[data-agent-status="working"]').length === 2
                && document.querySelectorAll('.bot-sparkle-star').length === 50
                && getComputedStyle(document.querySelector('[data-agent-status=working] .bot-sparkle-pass')).animationName
                    === (matchMedia('(prefers-reduced-motion: reduce)').matches ? 'none' : 'bot-sparkle-pass')
                && document.querySelector('.sidebar').getBoundingClientRect().width === 44
                && document.querySelector('.toolbar-title-block').getBoundingClientRect().left >= \(compactEnd)
                && !document.querySelector('#task-search')
            """)
        XCTAssertTrue(working)
        let collapsedCenters = try await sidebarIconCenters(in: chat)
        XCTAssertEqual(collapsedCenters, expandedCenters)
        let motionMatches = try await chat.evaluateJavaScript("""
            (() => {
                const icon = document.querySelector('[data-agent-status="working"] .agent-status-icon');
                const pass = icon.querySelector('.bot-sparkle-pass');
                const [animation] = pass.getAnimations();
                const pose = selector => new DOMMatrix(getComputedStyle(pass.querySelector(selector)).transform);
                if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
                    return !animation && pose('.sparkle-front').e === 17.5;
                }
                animation.pause();
                try {
                    for (const [time, x, y] of [[0, 17.5, 17.5], [800, 16.703, 14.578], [1599, 14.5, 12.5]]) {
                        animation.currentTime = time;
                        const front = pose('.sparkle-front'), back = pose('.sparkle-back');
                        if (Math.abs(front.e - x) > .02 || Math.abs(front.f - y) > .02
                            || Math.abs(front.e + back.e - 32) > .01 || Math.abs(front.f + back.f - 30) > .01
                            || front.b || front.c || back.b || back.c
                            || (time === 0 ? front.a >= back.a : front.a <= back.a)) return false;
                    }
                    return true;
                } finally { animation.play(); }
            })()
            """) as? Bool
        XCTAssertEqual(motionMatches, true, "The stars should swap sizes and stay upright around a fixed midpoint.")
        let restored = AppState(tasks: [], preferences: prefs, browserSession: session)
        XCTAssertTrue(restored.isTaskSidebarCollapsed)

        _ = try await chat.evaluateJavaScript("document.querySelector('[aria-label=\"Research — Working\"]').click(); true")
        let selectedWorkingChat = await waitForScriptBool(on: chat, script: """
            document.querySelector('.toolbar-title-block strong')?.textContent === 'Research'
                && !!document.querySelector('.agent-rail [aria-current=page]')
            """)
        XCTAssertTrue(selectedWorkingChat)

        state.apply(.taskCompletionObserved(taskID: tasks[2].id, threadID: thread, turnID: UUID().uuidString.lowercased()))
        state.apply(.taskStatusChanged(taskID: tasks[2].id, status: .completed))
        let finished = await waitForScriptBool(on: chat, script: """
            document.querySelectorAll('.agent-rail .task-row').length === 25
                && document.querySelectorAll('[data-agent-status=working]').length === 1
                && document.querySelectorAll('.agent-rail [data-agent-status=ready] .task-row-unread').length === 1
            """)
        XCTAssertTrue(finished)
        XCTAssertTrue(state.hasUnreadCompletion(for: tasks[2].id))
        try await clickInWindow(at: toggle, window: window)
        let reopened = await waitForScriptBool(on: chat, script: """
            document.querySelectorAll('.task-row').length === 25 && document.querySelectorAll('.task-row .agent-status-icon').length === 25
                && !!document.querySelector('[aria-label="Review — Ready to read"] .task-row-unread')
            """)
        XCTAssertTrue(reopened)
        _ = try await chat.evaluateJavaScript("document.querySelector('.task-row-unread').closest('button').click(); true")
        let read = await waitForScriptBool(on: chat, script: """
            document.querySelector('.toolbar-title-block strong')?.textContent === 'Review' && !document.querySelector('.task-row-unread')
            """)
        XCTAssertTrue(read)
        XCTAssertFalse(state.hasUnreadCompletion(for: tasks[2].id))
        try await clickInWindow(at: toggle, window: window)
        let hasMagnifier = await waitForScriptBool(on: chat, script: "!!document.querySelector('.sidebar-search-icon')")
        XCTAssertTrue(hasMagnifier)
        _ = try await chat.evaluateJavaScript("document.querySelector('.sidebar-search-icon').click(); true")
        let searchFocused = await waitForScriptBool(on: chat, script: "document.activeElement?.id === 'task-search'")
        XCTAssertTrue(searchFocused)
        XCTAssertFalse(state.isTaskSidebarCollapsed)

        let scrollable = await waitForScriptBool(on: chat, script: """
            (() => { const list = document.querySelector('nav[aria-label="Chats"]');
                if (!list) return false;
                const offset = Math.min(150, list.scrollHeight - list.clientHeight);
                list.scrollTop = offset;
                return offset > 0 && list.scrollTop === offset;
            })()
            """)
        XCTAssertTrue(scrollable)
        if NSScroller.preferredScrollerStyle == .overlay {
            // A custom ::-webkit-scrollbar forces WebKit to reserve a permanent gutter.
            let overlays = try await chat.evaluateJavaScript("""
                (() => { const list = document.querySelector('.task-list');
                    return list.offsetWidth === list.clientWidth; })()
                """) as? Bool
            XCTAssertEqual(overlays, true)
        }
        let scrolledCenters = try await sidebarIconCenters(in: chat)
        try await clickInWindow(at: toggle, window: window)
        let historyCollapsed = await waitForScriptBool(on: chat, script: "!!document.querySelector('.agent-rail')")
        XCTAssertTrue(historyCollapsed)
        let collapsedHistoryCenters = try await sidebarIconCenters(in: chat)
        XCTAssertEqual(collapsedHistoryCenters, scrolledCenters)
        state.apply(.taskStatusChanged(taskID: tasks[1].id, status: .completed))
        let idle = await waitForScriptBool(on: chat, script: """
            !!document.querySelector('.agent-rail') && document.querySelectorAll('.agent-rail .agent-status-icon').length === 25 && !document.querySelector('[data-agent-status=working]') && getComputedStyle(document.querySelector('.agent-rail .bot-sparkle-pass')).animationName === 'none'
                && !!document.querySelector('[data-native-sidebar-controls=true]') && !document.querySelector('.sidebar [aria-label="New agent"]')
            """)
        XCTAssertTrue(idle)
    }

    @MainActor
    func testCompactSidebarWidthAndIconCenterStayFixedWhenTrafficLightsMove() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        state.isTaskSidebarCollapsed = true
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        await settleLayout(host)
        let chat = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }.first {
            $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil
        })
        func check() async throws {
            let lights = try trafficLightFrames(in: window)
            let aligned = await waitForScriptBool(on: chat, script: """
                (() => {
                  const rail = document.querySelector('.sidebar')?.getBoundingClientRect();
                  const icon = document.querySelector('.sidebar-search-icon svg')?.getBoundingClientRect();
                  return rail && icon && rail.right === 44 && rail.right < \(lights.green.maxX)
                    && Math.abs(icon.left + icon.width / 2 - 22) <= 0.5;
                })()
                """)
            XCTAssertTrue(aligned, "The collapsed sidebar should stay 44 points wide with Search centered at 22 points.")
        }
        try await check()
        let original = try trafficLightFrames(in: window)
        // Native title-bar relayout must leave the sidebar layout alone.
        for (kind, offset) in [(NSWindow.ButtonType.closeButton, CGFloat(2)), (.miniaturizeButton, 9), (.zoomButton, 12)] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            button.setFrameOrigin(NSPoint(x: button.frame.minX + offset, y: button.frame.minY))
        }
        let moved = try trafficLightFrames(in: window)
        XCTAssertEqual(moved.green.maxX - original.green.maxX, 12, accuracy: 0.5)
        XCTAssertEqual(moved.yellow.midX - original.yellow.midX, 9, accuracy: 0.5)
        try await check()
    }

    @MainActor
    private func trafficLightFrames(in window: NSWindow) throws -> (red: CGRect, yellow: CGRect, green: CGRect) {
        func rect(_ kind: NSWindow.ButtonType) throws -> CGRect {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            return button.convert(button.bounds, to: nil)
        }
        return try (rect(.closeButton), rect(.miniaturizeButton), rect(.zoomButton))
    }

    @MainActor
    private func sidebarIconCenters(in webView: WKWebView) async throws -> [String: [Double]] {
        let centers = try await webView.evaluateJavaScript("""
            (() => {
                const controls = document.querySelectorAll('.primary-nav button, [data-tab-kind], #task-sidebar-toggle, .sidebar-address');
                const icons = Array.from(controls, control => [control.id || control.getAttribute('aria-label'), control.firstElementChild]);
                icons.push(['Search', document.querySelector('.task-search > svg, .sidebar-search-icon > svg')]);
                return Object.fromEntries(icons.map(([label, icon]) => {
                    const rect = icon.getBoundingClientRect();
                    return [label, [rect.x + rect.width / 2, rect.y + rect.height / 2]];
                }));
            })()
            """)
        return try XCTUnwrap(centers as? [String: [Double]])
    }

    @MainActor
    private func composeButton(in webView: WKWebView) throws -> NSButton {
        try XCTUnwrap(nativeViews(in: webView).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "chat-new" })
    }

    @MainActor
    private func clickInWindow(at point: NSPoint, window: NSWindow, throughApplication: Bool = false) async throws {
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        // A native control can consume mouseUp in a tracking loop during mouseDown.
        NSApp.postEvent(events[1], atStart: true)
        if throughApplication {
            // Install the down event as NSApp.currentEvent, as in a running Mac application.
            NSApp.postEvent(events[0], atStart: true)
            let down = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast, inMode: .default, dequeue: true))
            NSApp.sendEvent(down)
        } else {
            window.sendEvent(events[0])
        }
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false),
           queued.windowNumber == window.windowNumber {
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            window.sendEvent(queued)
        }
        await settleLayout(try XCTUnwrap(window.contentView))
    }

    @MainActor
    func testBrowserViewportFollowsSplitPane() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        let id = try session.createTab()
        let web = try XCTUnwrap(session.webView(for: id))
        web.loadHTMLString("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
                body { margin: 0 }
                button { position: fixed; right: 0; bottom: 0 }
                @media (max-width: 480px) { nav { display: none } }
            </style>
            <nav>Desktop navigation</nav><button>Continue</button>
            """, baseURL: nil)
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 740),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        await settleLayout(hosting)
        state.isBrowserPresented = true
        await settleLayout(hosting)
        let split = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? NSSplitView }.first)
        let pane = try XCTUnwrap(split.arrangedSubviews.last)
        XCTAssertGreaterThanOrEqual(pane.bounds.width, 400, "Opening the pane should use the space available beside the chat")
        window.setContentSize(NSSize(width: 1440, height: 800))
        await settleLayout(hosting)
        for width: CGFloat in [360, 520, 730, 360] {
            split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 0)
            await settleLayout(hosting)
            XCTAssertEqual(pane.bounds.width, width, accuracy: 1)
            XCTAssertEqual(web.bounds.width, pane.bounds.width, accuracy: 1)
            XCTAssertEqual(web.visibleRect, web.bounds, "WebKit should only see the page area below the browser toolbar")
            let fits = await waitForScriptBool(on: web, script: """
                (() => {
                    const edge = document.querySelector('button')?.getBoundingClientRect();
                    return innerWidth === \(Int(width)) && visualViewport.width === innerWidth
                        && innerHeight === \(Int(web.bounds.height)) && edge?.right === innerWidth && edge.bottom === innerHeight
                        && document.elementFromPoint(innerWidth - 2, innerHeight - 2)?.tagName === 'BUTTON'
                        && (getComputedStyle(document.querySelector('nav')).display === 'none') === (innerWidth <= 480);
                })()
                """)
            XCTAssertTrue(fits, "The page should reflow with its controls inside the \(width)-point pane")
        }
    }

    @MainActor
    func testDesktopPageFitsAndReleasesScaleAsLayoutChanges() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab()
        let web = try XCTUnwrap(session.webView(for: id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 423, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = try XCTUnwrap(window.contentView)
        try session.presentTab(id, in: pane)
        web.loadHTMLString("""
            <!doctype html><style>
            body { margin: 0 } .desktop { min-width: 780px }
            header { display: flex; justify-content: space-between }
            section { width: 100%; overflow: auto } article { width: 1400px }
            </style><body class="desktop"><header><b>Inbox</b><button>Compose</button></header>
            <section><article>Horizontally scrollable content</article></section>
            """, baseURL: nil)
        let rightEdgeWorks = """
            (() => {
                const button = document.querySelector('button');
                if (!button) return false;
                const r = button.getBoundingClientRect();
                return Math.abs(r.right - innerWidth) < 2
                    && document.elementFromPoint(r.x + r.width/2, r.y + r.height/2) === button;
            })()
            """
        for width: CGFloat in [423, 360, 860, 520] {
            window.setContentSize(NSSize(width: width, height: 600))
            let fits = await waitForScriptBool(on: web, script: """
                Math.abs(innerWidth - \(Int(max(width, 780)))) <= 1 && \(rightEdgeWorks)
                """)
            XCTAssertTrue(fits, "Desktop controls should fit and receive pointer input at \(width) points")
        }

        _ = try await web.evaluateJavaScript("document.body.classList.remove('desktop')")
        let responsive = await waitForScriptBool(on: web, script:
            "innerWidth === 520 && \(rightEdgeWorks)")
        XCTAssertTrue(responsive, "A nested horizontal scroller should keep its own overflow at normal page scale")
        _ = try await web.evaluateJavaScript("document.body.classList.add('desktop')")
        let refitted = await waitForScriptBool(on: web, script: "Math.abs(innerWidth - 780) <= 1 && \(rightEdgeWorks)")
        XCTAssertTrue(refitted)

        let renderWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        renderWindow.isReleasedWhenClosed = false
        defer { renderWindow.close() }
        session.installModelRenderHost(try XCTUnwrap(renderWindow.contentView))
        let lease = try session.acquireToolRendering(tabID: id)
        let originalScale = await waitForScriptBool(on: web, script:
            "innerWidth === 1024 && getComputedStyle(document.documentElement).zoom === '1'")
        XCTAssertTrue(originalScale, "A background task should get its ordinary viewport and coordinates")
        session.releaseToolRendering(tabID: id, lease: lease)
        let presentedAgain = await waitForScriptBool(on: web, script: "Math.abs(innerWidth - 780) <= 1 && \(rightEdgeWorks)")
        XCTAssertTrue(presentedAgain)

        web.loadHTMLString("<!doctype html><style>body{margin:0}main{width:100vw}</style><main>Responsive</main>", baseURL: nil)
        let nextPageFits = await waitForScriptBool(on: web, script:
            "document.querySelector('main') && innerWidth === 520 && document.documentElement.scrollWidth === 520")
        XCTAssertTrue(nextPageFits, "The next page should choose its own layout at normal size")

        web.loadHTMLString("<!doctype html><style>html{zoom:.9}</style><p>New document</p>", baseURL: nil)
        let newPage = await waitForScriptBool(on: web, script:
            "innerWidth === 520 && document.querySelector('p') && Math.abs(parseFloat(getComputedStyle(document.documentElement).zoom) - .9) < .01")
        XCTAssertTrue(newPage, "Navigation should preserve the new document's own zoom")
    }

    @MainActor
    func testManualPageZoomOverridesAutomaticFitAndFollowsOnlyItsTab() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab()
        let web = try XCTUnwrap(session.webView(for: id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = try XCTUnwrap(window.contentView)
        try session.presentTab(id, in: pane)
        web.loadHTMLString("<!doctype html><style>body{margin:0;min-width:800px}</style><main>Wide page</main>", baseURL: nil)
        let fitted = await waitForScriptBool(on: web, script: "document.querySelector('main') && Math.abs(innerWidth - 800) <= 1")
        XCTAssertTrue(fitted)
        session.changePageZoom(.zoomIn, tabID: id)
        XCTAssertEqual(web.pageZoom, 0.67, accuracy: 0.001, "Start at the currently displayed scale")
        session.changePageZoom(.actualSize, tabID: id)
        window.setContentSize(NSSize(width: 560, height: 600))
        let actualSize = await waitForScriptBool(on: web, script: "innerWidth === 560 && document.body.scrollWidth >= 800")
        XCTAssertTrue(actualSize, "100% must survive a narrow pane and a fresh layout")
        session.changePageZoom(.zoomOut, tabID: id)
        XCTAssertEqual(web.pageZoom, 0.9, accuracy: 0.001)
        session.changePageZoom(.zoomIn, tabID: id)
        session.changePageZoom(.zoomIn, tabID: id)
        session.changePageZoom(.zoomIn, tabID: id)
        XCTAssertEqual(web.pageZoom, 1.25, accuracy: 0.001)

        let otherID = try session.createTab(requestsMobileSite: true)
        let other = try XCTUnwrap(session.webView(for: otherID))
        session.detachPresentedTab(id, from: pane)
        try session.presentTab(otherID, in: pane)
        XCTAssertEqual(other.pageZoom, 1)
        session.changePageZoom(.zoomOut, tabID: otherID)
        XCTAssertEqual(other.pageZoom, 0.9, accuracy: 0.001)
        session.detachPresentedTab(otherID, from: pane)
        try session.presentTab(id, in: pane)
        XCTAssertEqual(web.pageZoom, 1.25, accuracy: 0.001)
        web.loadHTMLString("<!doctype html><style>body{min-width:1000px}</style><p>New document</p>", baseURL: nil)
        let navigated = await waitForScriptBool(on: web, script: "document.querySelector('p') && innerWidth === 448")
        XCTAssertTrue(navigated, "Navigation must keep the tab's manual zoom")

        let renderWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        renderWindow.isReleasedWhenClosed = false
        defer { renderWindow.close() }
        session.installModelRenderHost(try XCTUnwrap(renderWindow.contentView))
        let lease = try session.acquireToolRendering(tabID: id)
        XCTAssertEqual(web.pageZoom, 1, "An agent borrows the ordinary unscaled viewport")
        session.changePageZoom(.zoomOut, tabID: id)
        XCTAssertEqual(web.pageZoom, 1)
        session.releaseToolRendering(tabID: id, lease: lease)
        XCTAssertEqual(web.pageZoom, 1.25, accuracy: 0.001)
    }

    func testPageZoomBoundsAndReset() {
        var scale: CGFloat = 1
        for _ in 0..<30 { scale = BrowserPageZoomCommand.zoomIn.scale(from: scale) }
        XCTAssertEqual(scale, 5)
        for _ in 0..<30 { scale = BrowserPageZoomCommand.zoomOut.scale(from: scale) }
        XCTAssertEqual(scale, 0.25)
        XCTAssertEqual(BrowserPageZoomCommand.actualSize.scale(from: scale), 1)
    }

    @MainActor
    func testFittedInboxUsesFullHeightAndCanScrollToItsLastRow() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let id = try session.createTab()
        let web = try XCTUnwrap(session.webView(for: id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 423, height: 527),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try session.presentTab(id, in: XCTUnwrap(window.contentView))
        web.loadHTMLString("""
            <!doctype html><style>
            html,body { margin:0; overflow:hidden } body { min-width:780px }
            main { display:flex; flex-direction:column } section { flex:1; overflow:auto }
            article { height:3000px } footer { height:32px }
            #css-viewport { position:absolute; top:0; width:1px; height:100dvh; visibility:hidden }
            </style><div id="css-viewport"></div><main><section><article></article><button>Last row</button></section><footer>Footer</footer></main>
            <script>
            const sizeInbox = () => document.querySelector('main').style.height = innerHeight + 'px';
            addEventListener('resize', sizeInbox); sizeInbox();
            </script>
            """, baseURL: nil)
        for (width, height) in [(423, 527), (423, 700), (360, 527), (850, 600)] {
            window.setContentSize(NSSize(width: width, height: height))
            let scale = min(1, Double(width) / 780)
            let reachesBottom = await waitForScriptBool(on: web, script: """
                (() => {
                    const section = document.querySelector('section'), footer = document.querySelector('footer');
                    if (!section || !footer) return false;
                    section.scrollTop = section.scrollHeight;
                    const row = document.querySelector('button'), r = row.getBoundingClientRect();
                    const cssHeight = document.querySelector('#css-viewport').getBoundingClientRect().height;
                    return Math.abs(innerHeight * \(scale) - \(height)) <= 1
                        && Math.abs(cssHeight * \(scale) - \(height)) <= 1
                        && Math.abs(footer.getBoundingClientRect().bottom * \(scale) - \(height)) <= 1
                        && document.elementFromPoint(20, innerHeight - 2) === footer && section.scrollTop > 0
                        && document.elementFromPoint(r.x + r.width/2, r.y + r.height/2) === row;
                })()
                """)
            XCTAssertTrue(reachesBottom, "Last row and footer should be reachable in a \(width) × \(height) pane")
        }
    }

    @MainActor
    func testSettingsOpensNativeAccessModeChooserAndYieldsToApproval() async throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: prefs, browserSession: session)
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 740),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        await settleLayout(hosting)
        let web = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }.first)
        let row = "document.querySelector('button[aria-label^=\"Change access mode:\"]')"
        let bridge = "window.webkit.messageHandlers.localCodex"
        let ready = await waitForScriptBool(on: web, script: "Boolean(document.querySelector('#root button'))")
        XCTAssertTrue(ready)
        _ = try await web.evaluateJavaScript("\(bridge).postMessage({action:'showAccessModeSettings'}); true")
        await settleLayout(hosting)
        XCTAssertNil(window.attachedSheet)

        XCTAssertTrue(state.presentSettings())
        let rowReady = await waitForScriptBool(on: web, script: "\(row)?.textContent === 'Ask every time'")
        XCTAssertTrue(rowReady)
        _ = try await web.evaluateJavaScript("""
            \(bridge).postMessage({action:'setAccessMode',value:'fullAccess'});
            \(bridge).postMessage({action:'showAccessModeSettings',value:'fullAccess'}); true
            """)
        await settleLayout(hosting)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(state.accessMode, .askEveryTime)

        _ = try await web.evaluateJavaScript("\(row).click()")
        let deadline = ContinuousClock.now + .seconds(4)
        while window.attachedSheet == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertEqual(state.accessMode, .askEveryTime, "Opening the chooser must not change access")

        let request = ActionApprovalRequest(id: "settings-test", taskID: nil, kind: .command,
                                            title: "Fixture", summary: "Fixture", details: "")
        state.apply(.approvalRequested(request))
        let dismissed = ContinuousClock.now + .seconds(4)
        while window.attachedSheet != nil, ContinuousClock.now < dismissed {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(window.attachedSheet)
        XCTAssertNil(state.presentedSheet)
        XCTAssertEqual(state.presentedApproval, request)
    }

    @MainActor
    func testInstalledCLIPickerLoadsSignedInModelsOnOpen() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_LIVE_CODEX_CLI"] == "1",
                          "Requires the installed signed-in Codex CLI.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaCLIPicker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.codexHomePath = root.path
        config.workspacePath = root.appendingPathComponent("Workspace").path
        let runtime = SelectableCodexRuntime(configuration: config)
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        let state = AppState(tasks: [], runtime: runtime, preferences: prefs, browserSession: session)
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close(); session.shutdown() }
        hosting.layoutSubtreeIfNeeded()
        state.startRuntimeIfNeeded()
        do {
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                if case .connected = state.connectionState { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            state.createTask()
            let web = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }.first)
            let trigger = "document.querySelector('.model-selector-trigger:not([disabled])')"
            let ready = await waitForScriptBool(on: web, script: "Boolean(" + trigger + ")")
            XCTAssertTrue(ready)
            _ = try await web.evaluateJavaScript(trigger + ".dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true}))")
            let provider = "document.querySelector('.model-provider-option[data-provider=codex]')"
            let listed = await waitForScriptBool(on: web, script: "Boolean(" + provider + ")")
            XCTAssertTrue(listed)
            _ = try await web.evaluateJavaScript(provider + ".click()")
            let radios = "document.querySelectorAll('.model-selector-submenu [role=menuitemradio]')"
            let loaded = await waitForScriptBool(on: web, script: radios + ".length > 0")
            XCTAssertTrue(loaded, state.installedCLIError ?? "Opening the provider should load its catalog")
            let labels = try await web.evaluateJavaScript("Array.from(" + radios + ", item => item.textContent.trim())") as? [String]
            XCTAssertEqual(labels, state.installedCLIOptions.map { String($0.label.dropFirst("Codex CLI / ".count)) })
            let liveModel = ProcessInfo.processInfo.environment["COMPUTA_LIVE_CODEX_CLI_MODEL"]
            let options = state.installedCLIOptions
            let index: Int
            if let liveModel {
                index = try XCTUnwrap(options.firstIndex { InstalledCodexCLI.slug($0.id) == liveModel }, "Requested model missing from picker")
            } else {
                index = try XCTUnwrap(options.indices.last)
            }
            let expected = options[index]
            print("Kolmogor picker models: " + (labels ?? []).joined(separator: ", "))
            _ = try await web.evaluateJavaScript("Array.from(" + radios + ")[\(index)].click()")
            let closed = await waitForScriptBool(on: web, script: "!document.querySelector('.model-selector-content')")
            XCTAssertTrue(closed)
            XCTAssertEqual(state.selectedTask?.model, expected.id)
            if liveModel != nil {
                _ = try await web.evaluateJavaScript("""
                    (() => {
                        const field = document.querySelector('textarea[aria-label="Task prompt"]');
                        Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(field, 'hi');
                        field.dispatchEvent(new Event('input', {bubbles: true}));
                    })()
                    """)
                let send = #"document.querySelector('button[aria-label="Send prompt"]:not(:disabled)')"#
                let enabled = await waitForScriptBool(on: web, script: "Boolean(" + send + ")")
                XCTAssertTrue(enabled)
                _ = try await web.evaluateJavaScript(send + ".click()")
                let deadline = ContinuousClock.now + .seconds(90)
                while state.selectedTask?.status != .completed, ContinuousClock.now < deadline {
                    if state.selectedTask?.status == .failed { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let task = try XCTUnwrap(state.selectedTask)
                XCTAssertEqual(task.status, .completed, task.entries.last?.body ?? "")
                XCTAssertEqual(task.model, expected.id)
                let reply = try XCTUnwrap(task.entries.last { $0.kind == .assistant && !$0.body.isEmpty })
                let rendered = await waitForScriptBool(on: web, script: "Boolean(document.querySelector('.assistant-message')?.innerText.trim())")
                XCTAssertTrue(rendered)
                print("Kolmogor live UI: \(expected.label) | user=hi | reply=\(reply.body)")
            }
        } catch { _ = await state.shutdownRuntime(); throw error }
        _ = await state.shutdownRuntime()
    }

    /// Use the shipping WebKit UI and native bridge with empty preferences and
    /// an ephemeral browser. Only provider authentication/discovery is simulated.
    @MainActor
    func testFirstLaunchProviderPickerConnectsAndSelectsOnlyAccountModels() async throws {
        let prefs = isolatedTestPreferences()
        let session = EmbeddedBrowserSession(persistent: false, defaults: prefs)
        defer { session.shutdown() }
        @MainActor final class Account {
            var signedIn = false
            var kimiSignedIn = false
        }
        let account = Account()
        let choice = syntheticWebsiteChoice(provider: "chatgpt", key: "new", label: "High")
        let state = AppState(tasks: [], preferences: prefs, browserSession: session, websiteModelDiscovery: { provider in
            if provider == "kimi", account.kimiSignedIn { return [syntheticKimiChoice] }
            guard account.signedIn, provider == "chatgpt" else { throw EmbeddedWebModelTransport.Failure.signInRequired }
            return [choice]
        }, websiteModeDiscovery: { _ in throw EmbeddedWebModelTransport.Failure.signInRequired })
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let web = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }.first)
        func requireDOM(_ expression: String, line: UInt = #line) async throws {
            let ready = await waitForScriptBool(on: web, script: expression)
            _ = try XCTUnwrap(ready ? true : nil, "Missing expected picker state: \(expression)", line: line)
        }
        func openMenu(_ provider: String) async throws {
            try await requireDOM("Boolean(document.querySelector('.model-selector-trigger:not([disabled])'))")
            _ = try await web.evaluateJavaScript("""
                document.querySelector('.model-selector-trigger').dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true}))
                """)
            let expectedProviders = ["ChatGPT", "Gemini", "Claude", "Grok", "Kimi", "Qwen", "DeepSeek", "Codex CLI"]
                + ProviderCLI.allCases.map(\.name)
            try await requireDOM("document.querySelectorAll('.model-provider-option').length === \(expectedProviders.count)")
            let names = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.model-provider-name'), e => e.textContent)")
            XCTAssertEqual(names as? [String], expectedProviders)
            _ = try await web.evaluateJavaScript("document.querySelector('.model-provider-option[data-provider=\"\(provider)\"]').click()")
            try await requireDOM("Boolean(document.querySelector('.model-selector-submenu'))")
        }
        try await openMenu("chatgpt")
        let submenu = "document.querySelector('.model-selector-submenu')"
        try await requireDOM("\(submenu)?.querySelector('[role=menuitem]')?.textContent === 'Sign in to ChatGPT' && !\(submenu)?.querySelector('[role=menuitemradio]')")
        _ = try await web.evaluateJavaScript("\(submenu).querySelector('[role=menuitem]').click()")
        try await requireDOM("!document.querySelector('.model-selector-content')")
        let deadline = ContinuousClock.now + .seconds(5)
        while session.setupTab(for: .chatgpt) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let tab = try XCTUnwrap(session.setupTab(for: .chatgpt))
        XCTAssertTrue(state.isBrowserPresented)
        XCTAssertNil(session.browserToolTab(id: tab.id))
        session.webView(for: tab.id)?.stopLoading()
        state.connectModelProvider(route: "browser/chatgpt")
        XCTAssertEqual(session.humanTabs.map(\.id), [tab.id])
        await state.loadSignedInModels(tabID: tab.id)
        guard case .signInRequired = state.websiteModelSetupStatus(for: "chatgpt") else { return XCTFail("Signed-out discovery offered models") }
        XCTAssertFalse(state.setDefaultModel(choice.modelID))

        account.signedIn = true
        state.isBrowserPresented = false
        try await openMenu("chatgpt")
        try await requireDOM("\(submenu)?.querySelector('[role=menuitem]:last-child')?.textContent === 'Check again'")
        _ = try await web.evaluateJavaScript("\(submenu).querySelector('[role=menuitem]:last-child').click()")
        try await requireDOM("\(submenu)?.querySelectorAll('[role=menuitemradio]').length === 1 && \(submenu)?.textContent.includes('High')")
        _ = try await web.evaluateJavaScript("\(submenu).querySelector('[role=menuitemradio]').click()")
        try await requireDOM("document.querySelector('.model-selector-trigger')?.textContent.includes('High')")
        XCTAssertEqual(state.websiteModelSetupStatus(for: "chatgpt"), .loaded(1))
        XCTAssertFalse(state.isBrowserPresented)
        XCTAssertEqual(session.humanTabs.map(\.id), [tab.id])
        XCTAssertEqual(state.defaultModel, choice.modelID)
        state.createTask()
        XCTAssertEqual(state.selectedTask?.model, choice.modelID)
        XCTAssertEqual(WebsiteModelCatalog.load(from: prefs), [choice])

        await state.refreshWebsiteModels(provider: "kimi")
        try await openMenu("kimi")
        let kimiAction = "\(submenu)?.querySelector('[role=menuitem]')"
        try await requireDOM("\(kimiAction)?.textContent === 'Sign in to Kimi'")
        _ = try await web.evaluateJavaScript("\(kimiAction).click()")
        try await requireDOM("!document.querySelector('.model-selector-content')")
        let kimiTab = try XCTUnwrap(session.setupTab(for: .kimi))
        session.webView(for: kimiTab.id)?.stopLoading()
        account.kimiSignedIn = true
        await state.loadSignedInModels(tabID: kimiTab.id)
        state.isBrowserPresented = false
        try await openMenu("kimi")
        try await requireDOM("\(submenu)?.querySelectorAll('[role=menuitemradio]').length === 1 && \(kimiAction)?.textContent === 'Manage Kimi sign-in'")
        _ = try await web.evaluateJavaScript("\(kimiAction).click()")
        try await requireDOM("!document.querySelector('.model-selector-content')")
        XCTAssertTrue(state.isBrowserPresented)
        XCTAssertEqual(session.selectedTabID, kimiTab.id)
        state.isBrowserPresented = false

        await state.refreshWebsiteModels(provider: "qwen")
        try await openMenu("qwen")
        try await requireDOM("\(submenu)?.querySelector('[role=menuitem]')?.textContent === 'Sign in to Qwen'")
    }

    /// Native task selection resets review to Last turn. Exercise the compiled
    /// Octane select as well as the native state, without desktop input.
    @MainActor
    func testReviewScopeSelectResetsWhenSwitchingTasks() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let tasks = ["review-first", "review-second"].map { id in
            AgentTask(id: id, title: id, summary: "", status: .draft,
                      workspace: "", model: "local")
        }
        let state = AppState(tasks: tasks, preferences: isolatedTestPreferences(), browserSession: session)
        state.isReviewPresented = true
        await state.refreshReview(taskID: tasks[0].id)
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 1080, height: 820)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let chat = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }.first)
        let selector = "document.querySelector('select[aria-label=\"Changes scope\"]')"
        let ready = await waitForScriptBool(on: chat, script: "\(selector)?.value === 'lastTurn'")
        XCTAssertTrue(ready)

        for scope in [FileReviewScope.unstaged, .staged, .branch, .commit] {
            // Match the user path: a native select edits its DOM value before
            // the asynchronous WebKit bridge delivers the scope to AppState.
            _ = try await chat.evaluateJavaScript("""
                (() => {
                    const select = \(selector);
                    select.value = '\(scope.rawValue)';
                    select.dispatchEvent(new Event('input', { bubbles: true }));
                    select.dispatchEvent(new Event('change', { bubbles: true }));
                })()
                """)
            let deadline = ContinuousClock.now + .seconds(5)
            while state.review?.scope != scope, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(state.review?.scope, scope, "The real web bridge must receive the selection")
            let selected = await waitForScriptBool(on: chat, script: "\(selector)?.value === '\(scope.rawValue)'")
            XCTAssertTrue(selected, "The select must reflect the native scope")
            state.selectTask(tasks[1].id)
            let reset = await waitForScriptBool(on: chat, script: "\(selector)?.value === 'lastTurn' && document.querySelector('.review-scope-note')?.textContent.includes('Recorded edits') === true")
            XCTAssertEqual(state.review?.scope, .lastTurn)
            XCTAssertTrue(reset, "Switching from \(scope.rawValue) must reset both the select and its explanation")
            // Native accessibility selection can deliver the select's commit
            // event without a separate input event. That must still reach the
            // current task, rather than leave DOM and native scope divergent.
            _ = try await chat.evaluateJavaScript("""
                (() => {
                    const select = \(selector);
                    select.value = '\(scope.rawValue)';
                    select.dispatchEvent(new Event('change', { bubbles: true }));
                })()
                """)
            let secondDeadline = ContinuousClock.now + .seconds(5)
            while state.review?.scope != scope, ContinuousClock.now < secondDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(state.review?.scope, scope, "The selection after switching must target the current task")
            state.selectTask(tasks[0].id)
            let restored = await waitForScriptBool(on: chat, script: "\(selector)?.value === 'lastTurn'")
            XCTAssertTrue(restored)
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    @MainActor
    func testSettingsFooterReservesOnlySidebarSpaceAtEachWidth() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [AgentTask(title: "Layout", summary: "", status: .draft, workspace: "", model: "local")],
                             preferences: isolatedTestPreferences(), browserSession: session)
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let chat = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }.first)
        for (width, sidebarWidth) in [(1280, 230), (900, 216), (640, 190)] {
            window.setContentSize(NSSize(width: width, height: 720))
            hosting.layoutSubtreeIfNeeded()
            let fits = await waitForScriptBool(on: chat, script: """
                (() => {
                    const sidebar = document.querySelector('.sidebar')?.getBoundingClientRect();
                    const list = document.querySelector('.task-list')?.getBoundingClientRect();
                    const composer = document.querySelector('.composer-zone')?.getBoundingClientRect();
                    return innerWidth === \(width) && innerHeight === 720 && sidebar?.width === \(sidebarWidth)
                        && sidebar.bottom - list?.bottom === 34 && composer?.bottom === innerHeight
                        && !!document.elementFromPoint(sidebar.right + 3, innerHeight - 2)?.closest('.workspace');
                })()
                """)
            XCTAssertTrue(fits, "The Settings footer should end at the sidebar edge at window width \(width)")
        }
    }

    /// Mounts the real shell offscreen, with synthetic chat data and an in-memory
    /// browser document. No runtime, account, external URL, or desktop input.
    @MainActor
    func testFullWorkspaceLayoutAndApprovalOverlayRenderOffscreen() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [AgentTask(title: "Browser workspace preview",
            summary: "Isolated rendering fixture", status: .draft, workspace: "", model: "local")],
            preferences: isolatedTestPreferences(), browserSession: session)
        let tabID = try session.createTab()
        let browser = try XCTUnwrap(session.webView(for: tabID))
        browser.loadHTMLString("""
            <!doctype html><meta charset="utf-8"><title>Local browser fixture</title>
            <style>body{font:16px -apple-system;margin:48px;color:#262626;background:#fff}
            p{color:#606060;line-height:1.6}button{padding:8px 12px}</style>
            <main><h1>Browser workspace</h1><p>This page is local test content.</p>
            <button>Fixture control</button><p>No account or network connection is used.</p></main>
            """, baseURL: nil)
        state.isBrowserPresented = true
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state).environment(\.colorScheme, .light))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let chat = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? WKWebView }
            .first { $0 !== browser })
        let chatReady = await waitForScriptBool(on: chat, script: "Boolean(document.querySelector('.task-toolbar'))")
        let browserReady = await waitForScriptBool(on: browser, script: "document.title === 'Local browser fixture'")
        XCTAssertTrue(chatReady, "Bundled Octane UI should render in the real shell")
        let toolbarButtons = try await chat.evaluateJavaScript("""
            Array.from(document.querySelectorAll('.task-toolbar button'), button =>
                button.getAttribute('aria-label') || button.textContent.trim())
            """) as? [String]
        let buttons = try XCTUnwrap(toolbarButtons)
        XCTAssertTrue(buttons.contains("New agent"), "Borderless workspaces use the chat header compose button")
        XCTAssertFalse(buttons.contains("Toggle browser"), "The window title bar owns the browser toggle")
        XCTAssertFalse(buttons.contains("Toggle inspector"))
        XCTAssertFalse(buttons.contains("Toggle changes"))
        XCTAssertTrue(browserReady, "The browser fixture is entirely in memory")
        hosting.layoutSubtreeIfNeeded()

        let chatFrame = chat.convert(chat.bounds, to: hosting)
        let browserFrame = browser.convert(browser.bounds, to: hosting)
        XCTAssertGreaterThanOrEqual(chatFrame.width, 599)
        XCTAssertGreaterThanOrEqual(browserFrame.width, 450, "The initial right pane should be close to half, not pinned to its minimum")
        XCTAssertGreaterThanOrEqual(browserFrame.minX, chatFrame.maxX - 1)
        XCTAssertGreaterThan(browserFrame.midX, hosting.bounds.midX)
        XCTAssertLessThanOrEqual(browserFrame.maxX, hosting.bounds.maxX + 1)
        XCTAssertGreaterThan(browserFrame.height, 600)
        XCTAssertEqual(chatFrame.height, hosting.bounds.height, accuracy: 1)
        let browserBottom = hosting.isFlipped ? browserFrame.maxY : browserFrame.minY
        let windowBottom = hosting.isFlipped ? hosting.bounds.maxY : hosting.bounds.minY
        XCTAssertEqual(browserBottom, windowBottom, accuracy: 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        let pageContainer = try XCTUnwrap(browser.superview)
        let pagePoint = browser.convert(NSPoint(x: browser.bounds.midX, y: browser.bounds.midY),
                                        to: pageContainer.superview)
        let unblockedHit = try XCTUnwrap(pageContainer.hitTest(pagePoint))
        XCTAssertTrue(unblockedHit === browser || unblockedHit.isDescendant(of: browser),
                      "Negative control: page input must reach WebKit before the approval shield")

        let environment = ProcessInfo.processInfo.environment
        let outputPath = environment["COMPUTA_BROWSER_WORKSPACE_RENDER_PATH"]
            ?? environment["TEST_RUNNER_COMPUTA_BROWSER_WORKSPACE_RENDER_PATH"]
        if let outputPath {
            let base = URL(fileURLWithPath: outputPath).deletingPathExtension()
            // NSView.cacheDisplay cannot paint WebKit's compositor-backed
            // content offscreen. Export each real web surface separately.
            try await writeWebSnapshot(chat, path: base.path + "-chat.png")
            try await writeWebSnapshot(browser, path: base.path + "-page.png")
            try writeWorkspacePNG(hosting, path: outputPath)
        }

        state.pendingApprovals = [.init(id: "offscreen-browser-gate", taskID: nil, kind: .computerUse,
            title: "Allow this fixture action?", summary: "Only this isolated preview is being tested.",
            details: "No browser input or desktop action will be dispatched.")]
        let chatInert = await waitForScriptBool(on: chat, script: "document.querySelector('.app-panels')?.inert === true")
        XCTAssertTrue(chatInert, "The privileged chat document must also become inert")
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        // Hidden windows do not publish SwiftUI's virtual AX button tree on
        // this OS. Verify the actual page hit-test boundary instead of guessing
        // button enablement from an unavailable tree or a cached image.
        if let outputPath {
            let base = URL(fileURLWithPath: outputPath).deletingPathExtension()
            try writeWorkspacePNG(hosting, path: base.path + "-approval.png")
        }
        XCTAssertEqual(state.presentedApproval?.id, "offscreen-browser-gate")
        let blockedHit = try XCTUnwrap(pageContainer.hitTest(pagePoint))
        XCTAssertTrue(blockedHit === pageContainer,
                      "The native page container must intercept input while an approval is pending")

        // Hit-testing is read-only; never click or perform an accessibility action.
        // The visual scrim covers even the far edge outside the centered card.
        let browserOutsideCard = NSPoint(x: browserFrame.maxX - 24, y: browserFrame.midY)
        if let hit = hosting.hitTest(hosting.convert(browserOutsideCard, to: hosting.superview)) {
            XCTAssertFalse(hit === browser || hit.isDescendant(of: browser),
                           "The approval overlay must prevent hits from reaching the browser")
        }
        if let responder = window.firstResponder as? NSView {
            XCTAssertFalse(responder === browser || responder.isDescendant(of: browser))
        }
        XCTAssertEqual(session.tabs.map(\.id), [tabID])
        XCTAssertEqual(session.selectedTabID, tabID)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    @MainActor
    func testPaneRendersOffscreenWithoutActivatingWindowOrNavigating() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let first = try session.createTab()
        let selected = try session.createTab()
        let hosting = NSHostingView(rootView: EmbeddedBrowserPane(session: session, onCloseTab: { _ in }, onClose: {})
            .environment(\.colorScheme, .light))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 3_000)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(session.tabs.map(\.id), [first, selected])
        XCTAssertEqual(session.selectedTabID, selected)
        XCTAssertNil(session.webView(for: selected)?.url)

        let environment = ProcessInfo.processInfo.environment
        if let path = environment["COMPUTA_BROWSER_PANE_RENDER_PATH"]
            ?? environment["TEST_RUNNER_COMPUTA_BROWSER_PANE_RENDER_PATH"] {
            XCTAssertTrue(path.hasPrefix("/"))
            XCTAssertEqual(URL(fileURLWithPath: path).pathExtension.lowercased(), "png")
            guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else { return }
            try png.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }

    /// Exercise the real split shell with both ownership classes present.
    /// The private page is rendered normally, behind the opaque workspace,
    /// while only the human page is mounted in the Browser pane.
    @MainActor
    func testPrivateModelStaysBehindRealWorkspaceAcrossHumanPanePresentation() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [AgentTask(title: "Background model fixture",
            summary: "Isolated browser ownership rendering", status: .draft, workspace: "", model: "local")],
            preferences: isolatedTestPreferences(), browserSession: session)
        let humanID = try session.createTab()
        let human = try XCTUnwrap(session.webView(for: humanID))
        human.loadHTMLString("""
            <!doctype html><title>Human browser fixture</title>
            <style>html,body{margin:0;min-height:100%;background:#fff}</style>
            <main id="human-page">Only the human page belongs in Browser.</main>
            """, baseURL: nil)
        let modelID = try session.createModelTab(url: XCTUnwrap(URL(string: "about:blank")))
        let model = try XCTUnwrap(session.webView(for: modelID))
        let privateLabel = "PRIVATE_MODEL_FIXTURE_MUST_NOT_BE_A_BROWSER_TAB"
        model.loadHTMLString("""
            <!doctype html><title>\(privateLabel)</title>
            <style>html,body{margin:0;min-height:100%;background:#ff00ff}</style>
            <input id="model-editor"><main>Private model rendering fixture</main>
            """, baseURL: URL(string: "https://chatgpt.com/"))
        state.isBrowserPresented = true
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state).environment(\.colorScheme, .light))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        defer { window.close() }
        let keyWindow = NSApplication.shared.keyWindow
        await settleLayout(hosting)
        let humanReady = await waitForScriptBool(on: human, script: "Boolean(document.getElementById('human-page'))")
        let modelReady = await waitForScriptBool(on: model, script: "document.title === '\(privateLabel)'")
        XCTAssertTrue(humanReady)
        XCTAssertTrue(modelReady)
        await settleLayout(hosting)
        let backing = try XCTUnwrap(model.superview as? EmbeddedModelRenderContainer)
        let humanContainer = try XCTUnwrap(human.superview)
        XCTAssertFalse(humanContainer === backing)
        XCTAssertTrue(human.isDescendant(of: hosting), "The actual selected human view is presented by the real Browser pane")
        XCTAssertTrue(model.isDescendant(of: hosting), "The private model remains a live rendered WebKit view in the existing window")
        XCTAssertFalse(model.isDescendant(of: humanContainer))
        XCTAssertTrue(model.window === window)
        XCTAssertFalse(model.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(model.frame.size, NSSize(width: 1_024, height: 768))
        XCTAssertEqual(session.humanTabs.map(\.id), [humanID])
        XCTAssertFalse(session.humanTabs.contains { $0.title == privateLabel }, "The Browser tab-strip data has no inference label")
        XCTAssertEqual(backing.accessibilityChildren()?.count ?? 0, 0,
                       "The native render host must not expose private model content through accessibility")
        XCTAssertNil(backing.hitTest(NSPoint(x: 20, y: 20)))
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)

        // cacheDisplay cannot include WebKit compositor layers in an unordered
        // window. Sample the native shell's backing opacity, and export actual
        // WebKit surfaces separately when a visual receipt is requested.
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        for fraction in [0.1, 0.5, 0.9] {
            let x = min(bitmap.pixelsWide - 1, Int(Double(bitmap.pixelsWide) * fraction))
            let y = min(bitmap.pixelsHigh - 1, Int(Double(bitmap.pixelsHigh) * 0.5))
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThanOrEqual(color.alphaComponent, 0.99, "Opaque shell coverage prevents the underlying model surface from showing through")
        }
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["COMPUTA_BACKGROUND_MODEL_RENDER_PATH"]
            ?? environment["TEST_RUNNER_COMPUTA_BACKGROUND_MODEL_RENDER_PATH"] {
            let base = URL(fileURLWithPath: path).deletingPathExtension()
            try writeWorkspacePNG(hosting, path: path)
            try await writeWebSnapshot(human, path: base.path + "-human.png")
            try await writeWebSnapshot(model, path: base.path + "-private-model.png")
        }

        let addressField = try XCTUnwrap(nativeViews(in: hosting).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && ($0.placeholderString == "Search or enter a website address"
                || $0.accessibilityIdentifier() == "browser-address") },
            "Use the real Browser address control's shared field editor")
        addressField.selectText(nil)
        let input = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(input.isFieldEditor)
        XCTAssertTrue(addressField.currentEditor() === input)
        let unsentAddress = "UNSENT browser address sentinel"
        input.insertText(unsentAddress, replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        let unsentSelection = NSRange(location: 7, length: 7)
        input.setSelectedRange(unsentSelection)
        XCTAssertEqual(input.string, unsentAddress)
        await Task.yield()
        session.captureModelNativeFocus(tabID: modelID)
        let modelFocused = await waitForScriptBool(on: model, script: "document.getElementById('model-editor').focus(); document.activeElement === document.getElementById('model-editor')")
        XCTAssertTrue(modelFocused)
        session.restoreModelNativeFocus(tabID: modelID)
        await Task.yield()
        let activeAddressEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(activeAddressEditor.isFieldEditor)
        XCTAssertTrue(addressField.currentEditor() === activeAddressEditor)
        XCTAssertEqual(activeAddressEditor.string, unsentAddress)
        XCTAssertEqual(activeAddressEditor.selectedRange(), unsentSelection)

        state.isBrowserPresented = false
        await settleLayout(hosting)
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertTrue(model.superview === backing)
        XCTAssertTrue(model.window === window)
        XCTAssertFalse(model.isHiddenOrHasHiddenAncestor)
        state.isBrowserPresented = true
        await settleLayout(hosting)
        XCTAssertTrue(human.isDescendant(of: hosting))
        XCTAssertFalse(model.isDescendant(of: try XCTUnwrap(human.superview)))
        XCTAssertTrue(model.superview === backing)
        XCTAssertEqual(session.selectedTabID, humanID)
        // Human hide/show is allowed to end editing; inference alone above is
        // the regression boundary that must preserve unsent text and focus.

        session.closeTab(humanID)
        await settleLayout(hosting)
        XCTAssertTrue(session.humanTabs.isEmpty)
        XCTAssertNil(session.selectedTabID)
        XCTAssertEqual(session.tabs.map(\.id), [modelID])
        XCTAssertTrue(model.superview === backing, "An empty human pane cannot adopt a retained inference view")
        XCTAssertNil(human.superview)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)
    }

    @MainActor
    func testOpeningAndHidingPaneDoesNotCreateOrDestroyTabs() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        XCTAssertFalse(state.isBrowserPresented)
        XCTAssertTrue(session.tabs.isEmpty)

        state.isBrowserPresented = true
        XCTAssertTrue(state.shouldPresentBrowserPane)
        XCTAssertTrue(session.tabs.isEmpty, "Showing UI must not start browsing implicitly")
        let first = try session.createTab()
        let second = try session.createTab()
        let firstView = try XCTUnwrap(session.webView(for: first))
        state.isBrowserPresented = false
        XCTAssertFalse(state.shouldPresentBrowserPane)
        XCTAssertEqual(session.tabs.map(\.id), [first, second])
        XCTAssertEqual(session.selectedTabID, second)
        state.isBrowserPresented = true
        XCTAssertTrue(session.webView(for: first) === firstView)
        XCTAssertNil(firstView.url, "Blank tabs must not make a network request")
    }

    @MainActor
    func testSettingsTemporarilyHidesPaneButPreservesSelectionAndPreference() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        let tabID = try session.createTab()
        state.isBrowserPresented = true
        state.presentedSheet = .settings
        XCTAssertFalse(state.shouldPresentBrowserPane)
        XCTAssertTrue(state.isBrowserPresented)
        XCTAssertEqual(session.selectedTabID, tabID)

        state.presentedSheet = nil
        XCTAssertTrue(state.shouldPresentBrowserPane)
        XCTAssertEqual(session.selectedTabID, tabID)
    }

    @MainActor
    func testApprovalBlocksWholeSurfaceWithoutClearingBrowserState() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        _ = try session.createTab()
        state.isBrowserPresented = true
        state.presentedSheet = .settings
        state.pendingApprovals = [.init(id: "gate", taskID: nil, kind: .computerUse,
            title: "Approve", summary: "Test", details: "")]
        XCTAssertTrue(state.approvalGateBlocksInteraction)
        XCTAssertNil(state.presentedSheet)
        XCTAssertTrue(state.shouldPresentBrowserPane)
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(WebUISnapshot(state: state).pendingApprovalCount, 1)
    }

    @MainActor
    func testSnapshotCarriesDisplayHandleWithoutNativeTabIDOrBrowserContents() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session, workspaceLayout: .mixedTabs)
        let tabID = try session.createTab()
        let tab = try XCTUnwrap(session.humanTab(id: tabID))
        state.selectWorkspaceTab(.browser(tab.workspaceID))
        let snapshot = WebUISnapshot(state: state)
        XCTAssertEqual(snapshot.primaryBrowserID, tab.workspaceID.uuidString)
        XCTAssertFalse(snapshot.isBrowserPresented)
        let encoded = try JSONEncoder().encode(snapshot)
        let body = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(snapshot.workspaceBrowsers.map(\.id), [try XCTUnwrap(session.humanTab(id: tabID)).workspaceID.uuidString])
        XCTAssertFalse(body.contains(tabID.uuidString))
        XCTAssertFalse(body.contains("browserSession"))
        XCTAssertEqual(try JSONDecoder().decode(WebUISnapshot.self, from: encoded), snapshot)
    }

    @MainActor
    func testSettingsChromeProfileImportAndOpenBookmarkFromNewTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 2"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>Imported article opened</title>")
        let address = try await site.start().appendingPathComponent("human/final")
        defer { site.stop() }
        let marks: [String: Any] = ["roots": ["bookmark_bar": ["type":"folder","children": [
            ["type": "url","name": "Migration Example","url": address.absoluteString]
        ]]]]
        try JSONSerialization.data(withJSONObject: marks).write(to: root.appendingPathComponent("Profile 2/Bookmarks"))
        let profile = UUID()
        let library = try XCTUnwrap(ChromeProfileLibrary(profile: profile))
        defer { try? FileManager.default.removeItem(at: library.database.deletingLastPathComponent()) }
        let session = EmbeddedBrowserSession(profileID: profile, defaults: isolatedTestPreferences())
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session, workspaceLayout: .mixedTabs)
        state.chromeImportSourceRoot = root
        state.presentedSheet = .settings
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        await settleLayout(host)
        let web = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? WKWebView }
            .first { $0.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil })
        let button = "Array.from(document.querySelectorAll('button')).find(el => el.textContent.trim() === 'Import from Chrome…')"
        let ready = await waitForScriptBool(on: web, script: "Boolean(" + button + ")")
        XCTAssertTrue(ready)
        _ = try await web.evaluateJavaScript(button + ".click(); true")
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(30)) }
        let panel = try XCTUnwrap(window.attachedSheet as? NSPanel)
        XCTAssertTrue(state.importingChromeProfile)
        XCTAssertEqual(panel.title, "Import from Chrome")
        window.endSheet(panel, returnCode: .cancel)
        for _ in 0..<100 where state.importingChromeProfile { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(state.importingChromeProfile)
        XCTAssertNil(state.chromeProfileImportStatus)
        let canImportAgain = await waitForScriptBool(on: web, script: button + "?.disabled === false")
        XCTAssertTrue(canImportAgain)
        _ = try await web.evaluateJavaScript(button + ".click(); true")
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(30)) }
        let importSheet = try XCTUnwrap(window.attachedSheet)
        let confirm = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: importSheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        importSheet.sendEvent(confirm)
        for _ in 0..<100 where state.importingChromeProfile { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(state.chromeProfileImportStatus, "Imported or updated 0 history entries and 1 bookmark.")
        guard window.attachedSheet == nil else { window.endSheet(importSheet); return }
        state.presentedSheet = nil
        await settleLayout(host)
        WorkspaceTabLauncher.request(in: window)
        let editor = try await commandEditor("workspace-tab-launcher", in: host, window: window)
        editor.insertText("Migration Example", replacementRange: editor.selectedRange())
        // The launcher debounces native disk lookup before presenting imported places.
        try await Task.sleep(for: .milliseconds(350))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let browser = try XCTUnwrap(session.webView(for: XCTUnwrap(session.selectedTabID)))
        let opened = await waitForScriptBool(on: browser, script: "document.title === 'Imported article opened'")
        XCTAssertTrue(opened)
        XCTAssertEqual(session.restorablePages.first?.url, address)

        try session.navigate(tabID: XCTUnwrap(session.selectedTabID), to: URL(string: "about:blank")!)
        let blank = await waitForScriptBool(on: browser, script: "location.href === 'about:blank'")
        XCTAssertTrue(blank)
        BrowserAddressPalette.request(in: window)
        await settleLayout(host)
        let field = try XCTUnwrap(nativeViews(in: host).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "browser-address" })
        let addressEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        addressEditor.insertText("Migration Example", replacementRange: addressEditor.selectedRange())
        try await Task.sleep(for: .milliseconds(350))
        addressEditor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        addressEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let reopened = await waitForScriptBool(on: browser, script: "document.title === 'Imported article opened'")
        XCTAssertTrue(reopened)
        XCTAssertEqual(session.workspaceBrowserTabs.count, 1)

    }

    @MainActor
    private func nativeViews(in root: NSView) -> [NSView] {
        var pending = [root]
        var result: [NSView] = []
        while let view = pending.popLast(), result.count < 2_048 {
            result.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    @MainActor
    private func settleLayout(_ hosting: NSView) async {
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        hosting.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func waitForScriptBool(on view: WKWebView, script: String) async -> Bool {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(script)) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor
    private func writeWorkspacePNG(_ view: NSView, path: String) throws {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
            XCTFail("The optional workspace render path must be an absolute PNG path")
            return
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 3_000)
        try png.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    @MainActor
    private func writeWebSnapshot(_ view: WKWebView, path: String) async throws {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
            XCTFail("The optional web render path must be an absolute PNG path")
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        configuration.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: configuration)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 3_000)
        try png.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }
}

private actor TabLauncherRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Keyboard test"
    private(set) var submissions: [(id: String, prompt: String, modelID: String)] = []
    let history: WorkspaceHistory
    init(history: WorkspaceHistory = WorkspaceHistory(tasks: [])) { self.history = history }
    func loadTasks() async throws -> [AgentTask] { history.tasks }
    func loadWorkspaceHistory(including threadIDs: Set<String>) async throws -> WorkspaceHistory { history }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: String, modelID: String) async throws {
        submissions.append((taskID, prompt, modelID))
    }
    func interrupt(taskID: String) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

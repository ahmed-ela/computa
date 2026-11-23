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
    func testSendNowInSecondQueueRowSteersOnlyThatPrompt() async throws {
        let runtime = QueueControlledRuntime()
        let task = AgentTask(title: "Queue fixture", summary: "", status: .running, workspace: "/tmp", model: "local")
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences(), browserSession: session)
        state.activeTurnTaskIDs.insert(task.id)
        for prompt in ["First", "Second", "Third"] { _ = await state.submitOrQueue(prompt: prompt, toTaskID: task.id) }

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
        XCTAssertTrue(ready)
        await runtime.holdNextSteer()
        _ = try await chat.evaluateJavaScript(buttons + "[1].click(); true")
        let awaitingDelivery = await waitForScriptBool(on: chat, script: """
            document.querySelector('.queue-item-sending .queue-item-text')?.textContent === 'Second'
                && \(buttons).length === 2 && \(buttons).every(b => b.disabled)
            """)
        await runtime.finishSteer()
        XCTAssertTrue(awaitingDelivery)
        let updated = await waitForScriptBool(on: chat, script: """
            Array.from(document.querySelectorAll('.queue-item-text'), row => row.textContent).join(',') === 'First,Third'
            """)
        XCTAssertTrue(updated)
        let steers = await runtime.steers
        XCTAssertEqual(steers.map(\.prompt), ["Second"])
        XCTAssertEqual(steers.first?.taskID, task.id)
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
    private func launcherEditor(in host: NSView, window: NSWindow) async throws -> NSTextView {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let field = nativeViews(in: host).compactMap({ $0 as? NSTextField })
                .first(where: { $0.identifier?.rawValue == "workspace-tab-launcher" }),
               let editor = field.currentEditor() as? NSTextView, editor === window.firstResponder {
                return editor
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The new-tab field did not receive keyboard focus")
        throw CocoaError(.coderInvalidValue)
    }

    @MainActor
    func testMixedTabsHideSidePaneControlsAndOpenProviderSetupAsATab() async throws {
        let prefs = isolatedTestPreferences()
        let task = AgentTask(title: "First chat", summary: "", status: .draft, workspace: "", model: "local")
        WorkspaceTabs(defaults: prefs).save(SavedWorkspace(order: [.agent(task.id)], selectedAgent: task.id,
            drafts: [:], pages: [], browserIsPrimary: false, showsBrowserPane: true))
        let session = EmbeddedBrowserSession(persistent: false, maximumTabs: 1, defaults: prefs)
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
        XCTAssertEqual(state.browserTabOpenError, EmbeddedBrowserSession.Failure.tabLimit(1).localizedDescription)
        XCTAssertEqual(state.selectedWorkspaceTab, .agent(task.id))
        state.browserTabOpenError = nil
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
            return try await launcherEditor(in: host, window: window)
        }
        func press(_ char: String, code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }

        _ = try await open()
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
        XCTAssertEqual(state.tasks.count, 2)
        XCTAssertEqual(browser.workspaceBrowserTabs.count, 2)
        state.selectTask(empty)
        let preserved = await waitForScriptBool(on: web, script: "document.querySelector('#task-prompt')?.value === 'z'")
        XCTAssertTrue(preserved)
        _ = try await open()
        try press("\u{1b}", code: 53)
        XCTAssertEqual(state.selectedTaskID, empty)
        XCTAssertEqual(state.tasks.count, 2)
        XCTAssertEqual(browser.workspaceBrowserTabs.count, 2)

        await settleLayout(host)
        XCTAssertFalse(nativeViews(in: host).contains { $0.identifier?.rawValue == "workspace-tab-launcher" })

        // Leave the new chat before WebKit paints it. Submission is already bound to its ID.
        let quick = try await open()
        quick.insertText("Keep working", replacementRange: quick.selectedRange())
        try press("\u{f701}", code: 125)
        try press("\r", code: 36)
        let background = try XCTUnwrap(state.selectedTaskID)
        state.selectTask(empty)
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
        let draftKept = await waitForScriptBool(on: web, script: """
            document.activeElement?.id === 'task-prompt' && document.activeElement.value === 'Save this draft'
                && document.querySelector('.composer-submit-status')?.textContent.includes('available model') === true
            """)
        XCTAssertTrue(draftKept)
        let finalCalls = await runtime.submissions
        XCTAssertEqual(finalCalls.count, 2)
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
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
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
        let iconURL = try XCTUnwrap(WebUIResourceLocator.indexURL?.deletingLastPathComponent()
            .appendingPathComponent("icons/new-browser-tab.svg"))
        XCTAssertNotNil(NSImage(contentsOf: iconURL))
        try await requireDOM("""
        (() => { const icon = document.querySelector('button[aria-label="New tab"] .new-browser-tab-icon');
          return icon && getComputedStyle(icon).maskImage.includes('/icons/new-browser-tab.svg')
            && icon.getBoundingClientRect().width === 16; })()
        """)
        _ = try await chat.evaluateJavaScript("""
        const draft = document.querySelector('.composer-shell textarea'); draft.value='Return ticket';
        draft.dispatchEvent(new Event('input', { bubbles:true }));
        document.querySelector('button[aria-label="New tab"]').click(); true
        """)
        let field = try await launcherEditor(in: hosting, window: window)
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
        let expandedCenters = try await sidebarIconCenters(in: chat)
        let toggle = "#task-sidebar-toggle"
        try await requireDOM("!!document.querySelector('\(toggle)[aria-expanded=true] .lucide-panel-left-close')")
        _ = try await chat.evaluateJavaScript("document.querySelector('\(toggle)').click(); true")
        try await requireDOM("!!document.querySelector('.agent-rail .site-favicon') && innerWidth === 44")
        try await requireDOM("!!document.querySelector('\(toggle)[aria-expanded=false] .lucide-panel-left-open')")
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
        try hover(true, expectedWidth: 44)
        try await requireDOM("innerWidth === 230 && !!document.querySelector('.workspace-close')")
        try await requireDOM("!!document.querySelector('\(toggle)[aria-expanded=false] .lucide-panel-left-open')")
        XCTAssertTrue(prefs.bool(forKey: "taskSidebarCollapsed"))
        try await requireDOM("""
            (() => { const row = document.querySelector('.workspace-tab-row:has(.workspace-close)');
              return row.querySelector('.workspace-close').getBoundingClientRect().left >= row.querySelector('.task-row-title').getBoundingClientRect().right
                && getComputedStyle(document.querySelector('.new-task-button')).borderTopWidth === '0px'; })()
            """)
        try await requireDOM("!!document.querySelector('.sidebar-search-row #task-search')")
        try hover(false, expectedWidth: 230)
        try await requireDOM("innerWidth === 44 && !document.querySelector('.workspace-close')")
        XCTAssertTrue(state.isTaskSidebarCollapsed)
        for _ in 0..<3 {
            try hover(true, expectedWidth: 44)
            try await requireDOM("""
                innerWidth === 230 && document.querySelectorAll('.task-row').length === 2
                  && document.querySelectorAll('.workspace-tab-row').length < 80
                """)
            try hover(false, expectedWidth: 230)
            try await requireDOM("innerWidth === 44 && document.querySelectorAll('.agent-rail .task-row').length === 2")
        }
        let fieldPreserved = try await page.evaluateJavaScript("document.querySelector('input').value === 'B12' && location.hash === '#seat'") as? Bool
        XCTAssertEqual(fieldPreserved, true)
        XCTAssertTrue(session.webView(for: id) === page)
        let collapsedCenters = try await sidebarIconCenters(in: chat)
        XCTAssertEqual(collapsedCenters.mapValues { $0.first }, expandedCenters.mapValues { $0.first })
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
        try await requireDOM("innerWidth === 44 && document.querySelectorAll('.agent-rail .task-row').length === 1 && !!document.querySelector('.agent-rail [aria-label=\"Trip agent\"]')")
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
        try await requireDOM("!!document.querySelector('[data-tab-kind=agent][aria-current=page]')")
        try await requireDOM("document.querySelector('#task-search')?.value === ''")
        XCTAssertEqual(state.tasks.count, taskCount + 1)
        let newAgent = try XCTUnwrap(state.selectedTaskID)
        XCTAssertNotEqual(newAgent, task.id)
        XCTAssertEqual(state.openWorkspaceTabs, [.agent(newAgent)])
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
            XCTAssertEqual(state.tasks.count, count + 1)
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
    func testSidebarAddressOpensCenteredSelectsReplacesAndNavigates() async throws {
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<!doctype html><title>Address selection</title><button>Top control</button>")
        let url = try await site.start().appendingPathComponent("human/final")
        defer { site.stop() }
        let session = EmbeddedBrowserSession(persistent: false, defaults: isolatedTestPreferences())
        let tab = try session.createTab(url: url)
        let page = try XCTUnwrap(session.webView(for: tab))
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session, workspaceLayout: .mixedTabs)
        state.selectWorkspaceTab(.browser(try XCTUnwrap(session.humanTab(id: tab)?.workspaceID)))
        let host = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
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
                        || t.left !== r.left || innerWidth - r.right > 8 || r.left > 8) return false;
                    if (\(collapsed)) return !nav && row.querySelectorAll('button').length === 1;
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
        let expanded = await waitForScriptBool(on: chat, script: "document.querySelectorAll('.task-row').length === 25 && document.querySelectorAll('.task-row .agent-status-icon').length === 25 && !!document.querySelector('[aria-label=\"Archived 20\"]') && !document.querySelector('.agent-rail')")
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
                && document.querySelectorAll('[data-agent-status=working]').length === 1 && !!document.querySelector('.agent-rail [data-agent-status=ready]')
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
    private func sidebarIconCenters(in webView: WKWebView) async throws -> [String: [Double]] {
        let centers = try await webView.evaluateJavaScript("""
            (() => {
                const icons = document.querySelectorAll('.primary-nav button > :first-child, [data-tab-kind=browser] > :first-child');
                return Object.fromEntries(Array.from(icons, icon => {
                    const rect = icon.getBoundingClientRect();
                    const label = icon.closest('[aria-label]')?.getAttribute('aria-label');
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
        let hosting = NSHostingView(rootView: EmbeddedBrowserPane(session: session, onClose: {})
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
        let editor = try await launcherEditor(in: host, window: window)
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

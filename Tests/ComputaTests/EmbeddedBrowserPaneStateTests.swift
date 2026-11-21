import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Computa

final class EmbeddedBrowserPaneStateTests: XCTestCase {
    @MainActor
    func testBrowserControlStaysAtTrailingEdgeOfTitlebarAcrossPaneChanges() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        let hosting = NSHostingView(rootView: WebWorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        for (width, presented) in [(1100, false), (980, true), (1280, false)] {
            window.setContentSize(NSSize(width: width, height: 740))
            state.isBrowserPresented = presented
            await settleLayout(hosting)
            XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
            let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.first)
            let frame = accessory.view.convert(accessory.view.bounds, to: nil)
            let trafficLight = close.convert(close.bounds, to: nil)
            XCTAssertEqual(accessory.layoutAttribute, .right)
            XCTAssertGreaterThanOrEqual(frame.width, 24)
            XCTAssertEqual(frame.midY, trafficLight.midY, accuracy: 3)
            XCTAssertEqual(frame.maxX, window.frame.width, accuracy: 12)
        }
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
            print("Computa picker models: " + (labels ?? []).joined(separator: ", "))
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
                print("Computa live UI: \(expected.label) | user=hi | reply=\(reply.body)")
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
    func testSnapshotCarriesOnlyPresentationFlagNotBrowserContents() throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        let tabID = try session.createTab()
        state.isBrowserPresented = true
        let snapshot = WebUISnapshot(state: state)
        XCTAssertTrue(snapshot.isBrowserPresented)
        let encoded = try JSONEncoder().encode(snapshot)
        let body = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(body.contains(tabID.uuidString))
        XCTAssertFalse(body.contains("browserSession"))
        XCTAssertEqual(try JSONDecoder().decode(WebUISnapshot.self, from: encoded), snapshot)
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

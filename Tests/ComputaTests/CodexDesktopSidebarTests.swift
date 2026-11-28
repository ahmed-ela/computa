import AppKit
import SQLite3
import SwiftUI
import WebKit
import XCTest
@testable import Computa

@MainActor
final class CodexDesktopSidebarTests: XCTestCase {
    private func officialExecutable() throws -> URL {
        guard let executable = CodexDesktopSidebarClient.installedExecutable() else {
            throw XCTSkip("The official Codex desktop application is required for this integration test.")
        }
        return executable
    }

    func testDesktopPresentationOrdersGroupsAndFiltersLegacyMembershipByHostAndAccount() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var db: OpaquePointer?
        let url = folder.appendingPathComponent(".codex-global-state.sqlite")
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let scope = "electron-owner-atoms:ab61c4b51dab23d76588ef7b58bdc06495501cebb89fa412b695c387dd337750"
        let sql = """
            CREATE TABLE settings (scope TEXT, key TEXT, value TEXT, PRIMARY KEY(scope,key));
            INSERT INTO settings VALUES
            ('\(scope)', 'sidebar-custom-sections-v3', '{
              "other-workspace":{"sections":[],"sectionOrder":[]},
              "fixture-workspace":{
                "sectionOrder":["custom:papers","pinned","chats","custom:another"],
                "collapsedSectionIds":["another"],
                "sections":[
                  {"id":"papers","name":"Research Papers","itemKeys":["codex:thread:local:a","chatgpt:thread:local:b","codex:thread:remote:c","codex:thread:local:archived"]},
                  {"id":"another","name":"Older name","hostSectionIds":{"local":"official-section"},"itemKeys":[]}
                ]
              }}'),
            ('\(scope)', 'sidebar-collapsed-sections-v1','{"pinned":true,"chats":false}'),
            ('\(scope)', 'flat-project-sidebar-preferences-v1','{"chatSortMode":"manual","manualSortVersion":1}'),
            ('\(scope)', 'codex-sidebar-chat-order-v1','{"threadIds":["c","b"]}');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        typealias Client = CodexDesktopSidebarClient
        func chats(_ ids: [String]) -> [Client.Chat] { ids.map { .init(id: $0, title: $0, updatedAt: 1) } }
        let sections: [Client.Section] = [
            .init(id: Client.pinnedID, name: "Pinned", chats: chats(["p"])),
            .init(id: "official-section", name: "Updated group", chats: chats(["s"])),
            .init(id: "recent", name: "Recent", chats: chats(["a", "b", "c"]))
        ]
        let owner = Client.Account(userID: "fixture-user", workspaceID: "fixture-workspace", type: "chatgpt", email: nil, workspaceName: nil)
        let layout = try CodexDesktopLayout.read(from: folder, account: owner)
        let presented = layout.arrange(sections)
        XCTAssertEqual(presented.map(\.isCollapsed), [false, true, false, true])
        XCTAssertEqual(presented.map(\.name), ["Research Papers", "Pinned", "Recent", "Updated group"])
        XCTAssertEqual(presented.map { $0.chats.map(\.id) }, [["a"], ["p"], ["c", "b"], ["s"]])
        let other = Client.Account(userID: "someone-else", workspaceID: "fixture-workspace", type: "chatgpt", email: nil, workspaceName: nil)
        XCTAssertEqual(try CodexDesktopLayout.read(from: folder, account: other).arrange(sections), sections)
    }

    func testDisclosureChoicesSurviveRelaunchAndFollowSourceChangesPerAccount() {
        typealias Client = CodexDesktopSidebarClient
        let prefs = isolatedTestPreferences()
        func makeSync() -> CodexSidebarSync {
            CodexSidebarSync(preferences: prefs) { preconditionFailure("State test does not attach a window") }
        }
        func catalog(_ user: String, renamed: Bool = false, collapsed: Bool = false) -> Client.Catalog {
            let account = Client.Account(userID: user, workspaceID: "fixture", type: "chatgpt", email: nil, workspaceName: nil)
            return .init(account: account, sections: [
                .init(id: "group", name: renamed ? "New name" : "Research", chats: [], isCollapsed: collapsed),
                .init(id: "recent", name: "Recent", chats: [], isCollapsed: true),
            ])
        }
        let first = makeSync()
        first.update(catalog("A"))
        first.setCollapsed(true, sectionID: "group")
        first.setCollapsed(false, sectionID: "recent")
        first.update(catalog("A", renamed: true))
        XCTAssertEqual(first.presentedSections.map(\.isCollapsed), [true, false])

        let reopened = makeSync()
        reopened.update(catalog("A"))
        XCTAssertEqual(reopened.presentedSections.map(\.isCollapsed), [true, false])
        reopened.update(catalog("B"))
        XCTAssertEqual(reopened.presentedSections.map(\.isCollapsed), [false, true])
        reopened.update(catalog("A", collapsed: true))
        reopened.update(catalog("A"))
        XCTAssertEqual(reopened.presentedSections.map(\.isCollapsed), [false, false])
        reopened.setCollapsed(true, sectionID: "recent")
        XCTAssertEqual(reopened.presentedSections.map(\.isCollapsed), [false, true])
    }

    func testMatchesIndependentOfficialDesktopList() async throws {
        guard let path = ProcessInfo.processInfo.environment["KOLMOGOR_SIDEBAR_REFERENCE"] else {
            throw XCTSkip("Set KOLMOGOR_SIDEBAR_REFERENCE to an opt-in current desktop list_threads reference.")
        }
        struct Reference: Decodable {
            let history: [String]
            let pinned: [String]
            let recent: [String]
            let groups: [String]
        }
        let ref = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let reader = CodexDesktopSidebarClient(executable: try officialExecutable(), home: home,
                                               codexHome: home.appendingPathComponent(".codex"))
        let catalog = try await reader.catalog()
        await reader.close()
        let sections = catalog.sections
        XCTAssertEqual(Set(sections.flatMap { $0.chats.map(\.id) }), Set(ref.history))
        XCTAssertEqual(sections.first { $0.name == "Pinned" }?.chats.map(\.id) ?? [], ref.pinned)
        XCTAssertEqual(sections.filter { $0.name != "Pinned" && $0.id != "recent" }.map(\.name), ref.groups)
        let recent = try XCTUnwrap(sections.first { $0.id == "recent" })
        XCTAssertEqual(Array(recent.chats.prefix(ref.recent.count)).map(\.id), ref.recent)
    }

    private func chatWindow(_ sync: CodexSidebarSync) async throws -> WKWebView {
        let browser = EmbeddedBrowserSession(persistent: false)
        addTeardownBlock { @MainActor in browser.shutdown() }
        let app = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: browser, desktopSidebar: sync)
        let host = NSHostingView(rootView: WebWorkspaceView(state: app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        addTeardownBlock { @MainActor in window.close() }
        var web: WKWebView?
        for _ in 0..<80 where web == nil {
            host.layoutSubtreeIfNeeded()
            func find(_ view: NSView) -> WKWebView? {
                if let wk = view as? WKWebView, wk.configuration.urlSchemeHandler(forURLScheme: WebUIResourceLocator.scheme) != nil { return wk }
                return view.subviews.lazy.compactMap(find).first
            }
            web = find(host)
            if web == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        return try XCTUnwrap(web)
    }

    private func waitFor(_ predicate: String, in view: WKWebView, seconds: Int = 30) async throws {
        let until = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < until {
            if (try? await view.evaluateJavaScript(predicate)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        let diagnostics = try? await view.evaluateJavaScript("""
            ({rows:document.querySelectorAll('[data-codex-entry]').length,
              composer:!!document.querySelector('textarea[aria-label="Message Codex"]'),
              model:document.querySelector('select[aria-label=\"Codex model\"]')?.value ?? null,
              error:document.querySelector('.composer-zone [role=alert], .desktop-model-notice, .desktop-reader [role=alert]')?.textContent ?? null})
            """)
        XCTFail("Conversation check failed: " + predicate + " · " + String(describing: diagnostics))
        throw CocoaError(.coderInvalidValue)
    }

    func testOpenBothEndsOfExistingLongDesktopChat() async throws {
        guard let path = ProcessInfo.processInfo.environment["KOLMOGOR_DESKTOP_HISTORY_ENDS"] else {
            throw XCTSkip("Set KOLMOGOR_DESKTOP_HISTORY_ENDS to an independent read-only history reference.")
        }
        struct Reference: Decodable { let thread: UUID; let first: [String]; let last: [String] }
        let ref = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let source = try XCTUnwrap(CodexSidebarSync.installed(preferences: isolatedTestPreferences()))
        let view = try await chatWindow(source)
        let scope = "document.querySelector('[aria-label=\"Codex desktop chats\"][aria-pressed]')"
        try await waitFor("!!\(scope)", in: view)
        _ = try await view.evaluateJavaScript("\(scope).click()")
        try await waitFor("!!document.querySelector('[data-desktop-section]')", in: view)
        let thread = ref.thread.uuidString.lowercased()
        _ = try await view.evaluateJavaScript("void window.webkit.messageHandlers.localCodex.postMessage({action:'openDesktopChat',id:'\(thread)'})")
        func visible(_ key: [String]) throws -> String {
            let pair = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
            return "Array.from(document.querySelectorAll('[data-codex-entry]')).some(e => e.dataset.codexEntry === JSON.stringify(\(pair)))"
        }
        try await waitFor(try visible(ref.last), in: view)
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('button')).find(b=>b.textContent==='Beginning').click()")
        try await waitFor(try visible(ref.first), in: view)
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('button')).find(b=>b.textContent==='Latest').click()")
        try await waitFor(try visible(ref.last), in: view)
        let mounted = try await view.evaluateJavaScript("document.querySelectorAll('[data-codex-entry]').length") as? Int
        XCTAssertLessThanOrEqual(try XCTUnwrap(mounted), 192)
    }

    func testSwitchModelOnOfficialDesktopAndReopenSameConversation() async throws {
        guard let root = ProcessInfo.processInfo.environment["KOLMOGOR_MODEL_PICKER_FIXTURE"] else {
            throw XCTSkip("Requires an isolated running Codex desktop and recording model endpoint.")
        }
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        let profile = folder.appendingPathComponent("profile")
        let id = try String(contentsOf: folder.appendingPathComponent("thread"), encoding: .utf8)
        let executable = try officialExecutable()
        let name = "gpt-6.1-sol"
        let picker = "document.querySelector('select[aria-label=\"Codex model\"]')"
        func openChat() async throws -> WKWebView {
            let sync = CodexSidebarSync(interval: .seconds(1), preferences: isolatedTestPreferences()) {
                CodexDesktopSidebarClient(executable: executable, home: folder, codexHome: profile)
            }
            let view = try await chatWindow(sync)
            let source = "document.querySelector('[aria-label=\"Codex desktop chats\"]')"
            try await waitFor("!!" + source, in: view)
            _ = try await view.evaluateJavaScript(source + ".click()")
            let row = "document.querySelector('[data-desktop-chat=\"\(id)\"] button')"
            try await waitFor("!!" + row, in: view)
            _ = try await view.evaluateJavaScript(row + ".click()")
            try await waitFor("!!" + picker, in: view)
            return view
        }
        let view = try await openChat()
        let transcript = "document.querySelector('.desktop-reader')?.textContent"
        try await waitFor("\(transcript)?.includes('PROBE-REPLY-1')", in: view)
        try await waitFor("\(picker).value === 'gpt-6.2-sol'", in: view)
        _ = try await view.evaluateJavaScript("""
          (() => { let field = \(picker); field.value = '\(name)'; field.dispatchEvent(new Event('change', {bubbles:true})); })()
          """)
        try await waitFor("\(picker).value === '\(name)' && !\(picker).disabled", in: view)
        // Let the background observer read the live owner after a switch but before
        // sending. Another app-server still sees the old model on disk here.
        try await Task.sleep(for: .milliseconds(5300))
        try await waitFor("\(picker).value === '\(name)' && \(picker).title === 'Current model in Codex'", in: view)
        let marker = "SWITCH_" + UUID().uuidString
        _ = try await view.evaluateJavaScript("""
          (() => { let f = document.querySelector('textarea[aria-label="Message Codex"]'); f.value = '\(marker)';
            f.dispatchEvent(new Event('input', {bubbles:true})); })()
          """)
        let send = "document.querySelector('[aria-label=\"Send to Codex\"]')"
        try await waitFor("!\(send).disabled", in: view)
        _ = try await view.evaluateJavaScript(send + ".click()")
        try await waitFor("\(transcript)?.includes('\(marker)') && \(transcript)?.includes('PROBE-REPLY-AFTER-SWITCH')", in: view, seconds: 60)
        // The recorder checks the model field on the wire and the prior reply in the request.
        let receipt = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: folder.appendingPathComponent("switch-receipt")))
        XCTAssertEqual(receipt["model"], name)
        XCTAssertEqual(receipt["prompt"], marker)
        XCTAssertEqual(receipt["hasOriginalReply"], "true")
        view.window?.close()
        try Data().write(to: folder.appendingPathComponent("reopen-desktop"))
        let ready = folder.appendingPathComponent("desktop-reopened")
        for _ in 0..<240 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(250)) }
        XCTAssertEqual(try String(contentsOf: ready, encoding: .utf8), id)
        let reopened = try await openChat()
        try await waitFor("\(picker).value === '\(name)' && \(transcript)?.includes('\(marker)') && \(transcript)?.includes('PROBE-REPLY-1') && \(transcript)?.includes('PROBE-REPLY-AFTER-SWITCH')", in: reopened)
    }

    // The external fixture provides an isolated Codex desktop and the loopback model.
    // Wake only that instance. The production path targets the installed app by bundle ID.
    func testRoundTripWithRunningOfficialDesktop() async throws {
        guard let root = ProcessInfo.processInfo.environment["KOLMOGOR_ISOLATED_DESKTOP_FIXTURE"] else {
            throw XCTSkip("Set KOLMOGOR_ISOLATED_DESKTOP_FIXTURE for the real desktop round trip.")
        }
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        let profile = folder.appendingPathComponent("profile")
        let electron = folder.appendingPathComponent("electron").path
        let id = try String(contentsOf: folder.appendingPathComponent("thread"), encoding: .utf8)
        let outgoing = "ROUND_" + UUID().uuidString.filter(\.isLetter).prefix(9).uppercased()
        let incoming = "ROUND_" + UUID().uuidString.filter(\.isLetter).prefix(9).uppercased()
        try Data(incoming.utf8).write(to: folder.appendingPathComponent("reply-from-codex"))
        try Data(outgoing.utf8).write(to: folder.appendingPathComponent("reply-from-kolmogor"))
        let executable = try officialExecutable()
        let sync = CodexSidebarSync(interval: .seconds(1), preferences: isolatedTestPreferences(), wake: { thread in
            XCTAssertEqual(thread.uuidString.lowercased(), id)
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            let app = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodexDesktopSidebarClient.bundleID))
            launch.arguments = ["-gn", "--env", "CODEX_HOME=" + profile.path, "--env", "CODEX_ELECTRON_USER_DATA_PATH=" + electron,
                                app.path, "--args", "--user-data-dir=" + electron, CodexSidebarSync.wakeURL(thread).absoluteString]
            try launch.run()
            launch.waitUntilExit()
            XCTAssertEqual(launch.terminationStatus, 0)
        }) { CodexDesktopSidebarClient(executable: executable, home: folder, codexHome: profile) }
        let view = try await chatWindow(sync)
        try await waitFor("!!document.querySelector('[aria-label=\"Codex desktop chats\"][aria-pressed]')", in: view)
        _ = try await view.evaluateJavaScript("document.querySelector('[aria-label=\"Codex desktop chats\"][aria-pressed]').click()")
        let row = "document.querySelector('[data-desktop-chat=\"\(id)\"] button')"
        try await waitFor("\(row)?.title === 'Kolmogor shared transcript qualification'", in: view)
        _ = try await view.evaluateJavaScript("\(row).click()")
        try await waitFor("document.querySelector('.desktop-reader')?.textContent.includes('ACK_ROUND_ONE')", in: view)
        _ = try await view.evaluateJavaScript("""
            (() => { const field = document.querySelector('textarea[aria-label="Message Codex"]');
              field.value = 'Reply for \(outgoing).'; field.dispatchEvent(new Event('input', {bubbles:true})); })()
            """)
        try await waitFor("document.querySelector('[aria-label=\"Send to Codex\"]')?.disabled === false", in: view)
        _ = try await view.evaluateJavaScript("document.querySelector('[aria-label=\"Send to Codex\"]').click()")
        try await waitFor("document.querySelector('.desktop-reader')?.textContent.includes('ACK_\(outgoing)')", in: view, seconds: 60)
        try Data().write(to: folder.appendingPathComponent("kolmogor-received"))
        try await waitFor("document.querySelector('.desktop-reader')?.textContent.includes('ACK_\(incoming)')", in: view, seconds: 180)
    }

    func testLiveChangesFromIndependentOfficialAppServerReachOpenWebKitWindow() async throws {
        let executable = try officialExecutable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"OPENAI_API_KEY":"sk-disposable-local-fixture"}"#.utf8).write(to: directory.appendingPathComponent("auth.json"))
        try Data("""
            openai_base_url = "http://127.0.0.1:1/v1"
            model = "gpt-6.2-sol"
            """.utf8).write(to: directory.appendingPathComponent("config.toml"))

        let writer = try AgentCLIConnection(executable: executable, arguments: InstalledCodexCLI.arguments,
            directory: directory, environment: ["HOME": directory.path, "CODEX_HOME": directory.path, "PATH": "/usr/bin:/bin"],
            codexProtocol: true) { _ in }
        addTeardownBlock { await writer.close() }

        @discardableResult
        func call(_ method: String, _ params: [String: any Sendable]) async throws -> [String: Any] {
            let bytes = try JSONSerialization.data(withJSONObject: params)
            let reply = try await writer.request(method, params: bytes, timeout: .seconds(12))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        }
        try await call("initialize", ["clientInfo": ["name": "sidebar_fixture", "version": "1"], "capabilities": ["experimentalApi": true]])
        try await writer.send(Data(#"{"method":"initialized"}"#.utf8))

        var wakes: [String] = []
        let sync = CodexSidebarSync(wake: { wakes.append($0.uuidString.lowercased()) }) {
            CodexDesktopSidebarClient(executable: executable, home: directory, codexHome: directory)
        }
        let view = try await chatWindow(sync)
        func expectDOM(_ script: String, _ reason: String, line: UInt = #line) async throws {
            let deadline = ContinuousClock.now + .seconds(16)
            while ContinuousClock.now < deadline {
                if (try? await view.evaluateJavaScript(script)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(80))
            }
            let dom = try? await view.evaluateJavaScript("Array.from(document.querySelectorAll('[data-desktop-chat],[data-desktop-section]'), e => e.dataset.desktopChat ?? e.dataset.desktopSection)")
            let ids = sync.catalog?.sections.flatMap { [$0.id] + $0.chats.map(\.id) } ?? []
            XCTFail("\(reason) · \(sync.error ?? "no source error") · catalog \(ids) · rendered \(String(describing: dom))", line: line)
            throw CocoaError(.coderInvalidValue)
        }
        try await expectDOM("!!document.querySelector('button[aria-label=\"Codex desktop chats\"]')", "Scope appears")
        _ = try await view.evaluateJavaScript("document.querySelector('button[aria-label=\"Codex desktop chats\"]').click()")
        try await expectDOM("!!document.querySelector('[data-desktop-section=recent]')", "Recent appears")

        func startChat(_ name: String) async throws -> String {
            let created = try await call("thread/start", ["cwd": directory.path, "model": "gpt-6.2-sol",
                                                          "approvalPolicy": "never", "sandbox": "read-only"])
            let id = try XCTUnwrap((created["thread"] as? [String: Any])?["id"] as? String)
            let message = [["type": "text", "text": name + " user message"]]
            let started = try await call("turn/start", ["threadId": id, "input": message])
            let turn = try XCTUnwrap((started["turn"] as? [String: Any])?["id"] as? String)
            try await expectDOM("!!document.querySelector('[data-desktop-chat=\"\(id)\"]')", "New chat appears automatically")
            _ = try? await call("turn/interrupt", ["threadId": id, "turnId": turn])
            try await call("thread/name/set", ["threadId": id, "name": name])
            return id
        }
        func section(_ name: String) async throws -> String {
            let result = try await call("threadSection/create", ["name": name])
            return try XCTUnwrap((result["section"] as? [String: Any])?["id"] as? String)
        }
        func expectOrder(_ ids: [String]) async throws {
            let encoded = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            try await expectDOM("""
                JSON.stringify(Array.from(document.querySelectorAll('[data-desktop-chat], [data-desktop-section]'),
                    e => e.dataset.desktopChat ?? e.dataset.desktopSection)) === JSON.stringify(\(encoded))
                """, "Expected section and chat order \(ids)")
        }
        func header(_ section: String) -> String {
            "document.querySelector('[data-desktop-section=\"\(section)\"] button')"
        }
        let first = try await startChat("First synthetic chat")
        let second = try await startChat("Second synthetic chat")
        let groups = try await call("threadSection/list", [:])
        let reserved = (groups["data"] as? [[String: Any]])?.first { $0["name"] as? String == "Pinned" }
        let pin = try XCTUnwrap(reserved?["id"] as? String)
        let group = try await section("Research Papers")
        try await call("thread/section/move", ["threadId": first, "sectionId": pin])
        try await call("thread/section/move", ["threadId": second, "sectionId": pin])
        try await expectOrder([pin, first, second, group, "recent"])
        _ = try await view.evaluateJavaScript("\(header(pin)).click()")
        try await expectOrder([pin, group, "recent"])
        _ = try await view.evaluateJavaScript("\(header(pin)).click()")
        try await expectOrder([pin, first, second, group, "recent"])
        try await call("thread/section/move", ["threadId": second, "sectionId": pin, "beforeThreadId": first])
        try await expectOrder([pin, second, first, group, "recent"])
        try await call("thread/section/move", ["threadId": second, "sectionId": group])
        try await expectOrder([pin, first, group, second, "recent"])
        let groupHeader = header(group)
        _ = try await view.evaluateJavaScript("\(groupHeader).click()")
        try await expectOrder([pin, first, group, "recent"])
        try await expectDOM("\(groupHeader).getAttribute('aria-expanded') === 'false'", "Group announces its collapsed state")
        try await call("threadSection/update", ["sectionId": group, "name": "Renamed research"])
        try await expectDOM("document.querySelector('[data-desktop-section=\"\(group)\"]')?.title === 'Renamed research'", "Group rename arrives")
        try await expectOrder([pin, first, group, "recent"])
        func search(_ term: String) async throws {
            let value = String(decoding: try JSONEncoder().encode(term), as: UTF8.self)
            _ = try await view.evaluateJavaScript("""
                (() => { const field = document.querySelector('#task-search'); field.value = \(value);
                    field.dispatchEvent(new Event('input', {bubbles: true})); })()
                """)
        }
        try await search("Second synthetic")
        try await expectOrder([group, second])
        try await search("")
        try await expectOrder([pin, first, group, "recent"])
        _ = try await view.evaluateJavaScript("\(groupHeader).dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight', bubbles:true}))")
        try await expectOrder([pin, first, group, second, "recent"])
        _ = try await view.evaluateJavaScript("document.querySelector('[data-desktop-chat=\"\(second)\"] button').click()")
        try await expectDOM("document.querySelector('[aria-label=\"Codex conversation\"]')?.textContent.includes('Second synthetic chat user message')", "Selected conversation opens")
        _ = try await view.evaluateJavaScript("""
            (() => {
                const f = document.querySelector('textarea[aria-label="Message Codex"]');
                f.value = 'Follow up from Kolmogor';
                f.dispatchEvent(new Event('input', {bubbles: true}));
            })()
            """)
        let picker = "document.querySelector('select[aria-label=\"Codex model\"]')"
        try await expectDOM("\(picker)?.value === 'gpt-6.2-sol'", "The picker reads the official thread model")
        _ = try await view.evaluateJavaScript("""
            (() => { const select = \(picker); select.value = 'gpt-6.1-sol';
                select.dispatchEvent(new Event('change', {bubbles:true})); })()
            """)
        try await expectDOM("document.querySelector('.desktop-model-notice')?.textContent.includes('Open in Codex')",
                            "A private writer requires a handoff")
        try await expectDOM("\(picker).value === 'gpt-6.2-sol' && document.querySelector('[aria-label=\"Send to Codex\"]').disabled && document.querySelector('textarea').value === 'Follow up from Kolmogor'",
                            "An unconfirmed switch keeps the previous model and the unsent draft")
        _ = try await view.evaluateJavaScript("""
            Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {
                writeText: async text => { window.copiedCodexDraft = text }
            }});
            Array.from(document.querySelectorAll('.desktop-model-notice button')).find(b => b.textContent === 'Copy draft').click()
            """)
        try await expectDOM("window.copiedCodexDraft === 'Follow up from Kolmogor' && document.querySelector('.desktop-model-notice').textContent.includes('Draft copied')",
                            "The explicit copy action transfers the draft without changing the Codex conversation")
        XCTAssertTrue(wakes.isEmpty)
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('.desktop-model-notice button')).find(b => b.textContent === 'Cancel').click()")
        try await expectDOM("!document.querySelector('[aria-label=\"Send to Codex\"]').disabled", "Composer is ready")
        _ = try await view.evaluateJavaScript("document.querySelector('[aria-label=\"Send to Codex\"]').click()")
        try await expectDOM("document.querySelector('.desktop-queue')?.textContent.includes('1 message queued')", "Codex acknowledged the queued reply")
        XCTAssertEqual(wakes, [second])
        // Deliver a stale change event after another message has been queued.
        // The native boundary must protect the queue even if the menu was open.
        _ = try await view.evaluateJavaScript("""
            (() => { const select = \(picker); select.value = 'gpt-6.1-sol';
                select.dispatchEvent(new Event('change', {bubbles:true})); })()
            """)
        try await expectDOM("Array.from(document.querySelectorAll('[role=alert]')).some(e => e.textContent.includes('queued messages'))",
                            "A pending submission prevents even a private-desktop model handoff")
        XCTAssertEqual(wakes, [second])
        let queued = try await call("thread/queue/list", ["threadId": second])
        let rows = try XCTUnwrap(queued["data"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual((rows.first?["input"] as? [[String: Any]])?.first?["text"] as? String, "Follow up from Kolmogor")
        _ = try await call("thread/queue/start", ["threadId": second, "queuedSubmissionId": try XCTUnwrap(rows.first?["id"] as? String)])
        try await expectDOM("document.querySelector('.desktop-reader')?.textContent.includes('Follow up from Kolmogor')", "The official writer consumed the submission in the same thread")
        try await call("thread/section/move", ["threadId": first, "sectionId": NSNull()])
        try await expectOrder([pin, group, second, "recent", first])
        _ = try await view.evaluateJavaScript("\(header("recent")).click()")
        try await expectOrder([pin, group, second, "recent"])
        _ = try await view.evaluateJavaScript("\(groupHeader).click()")
        try await expectOrder([pin, group, "recent"])
        try await expectDOM("document.querySelector('[aria-label=\"Codex conversation\"]')?.textContent.includes('Second synthetic chat user message')", "Collapsing the active conversation’s group keeps it open")
        _ = try await view.evaluateJavaScript("\(header("recent")).click()")
        try await expectOrder([pin, group, "recent", first])
        try await call("thread/archive", ["threadId": second])
        try await expectOrder([pin, group, "recent", first])
        try await expectDOM("!document.querySelector('[aria-label=\"Codex conversation\"]')", "Archived conversation closes")
        try await call("account/logout", [:])
        try await expectDOM("document.querySelector('nav[aria-label=\"Codex desktop chats\"]')?.textContent.includes('Sign in') && !document.querySelector('[data-desktop-chat]')", "External sign-out clears the catalog")
    }
}

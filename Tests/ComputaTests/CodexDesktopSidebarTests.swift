import AppKit
import SQLite3
import SwiftUI
import WebKit
import XCTest
@testable import Computa

@MainActor
final class CodexDesktopSidebarTests: XCTestCase {
    private func officialExecutable() throws -> URL {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodexDesktopSidebarClient.bundleID),
              let executable = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
                .map({ app.appendingPathComponent($0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
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

    private func chatWindow(_ sync: CodexSidebarSync, preferences: UserDefaults, runtime: (any AgentRuntimeClient)? = nil) async throws -> WKWebView {
        let browser = EmbeddedBrowserSession(persistent: false)
        addTeardownBlock { @MainActor in browser.shutdown() }
        let app = AppState(tasks: [], runtime: runtime, preferences: preferences, browserSession: browser, desktopSidebar: sync)
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
              model:document.querySelector('select[aria-label=\"Conversation model\"]')?.value ?? null,
              error:document.querySelector('.composer-zone [role=alert], .task-list [role=alert], .desktop-reader [role=alert], .task-list [role=status]')?.textContent ?? null})
            """)
        XCTFail("Conversation check failed: " + predicate + " · " + String(describing: diagnostics))
        throw CocoaError(.coderInvalidValue)
    }

    func testImportedWebsiteSelectionRequiresCurrentAccountChoiceAtSelectAndSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = isolatedTestPreferences()
        let source = try XCTUnwrap(CodexSidebarSync.installed(preferences: prefs, candidates: [], directory: root))
        let store = try CodexImportStore(directory: root)
        let id = try store.accepted(owner: "A", source: "S", snapshot: .init(title: "Example", model: "gpt", pages: []))
        let window = WorkspaceTabs(defaults: prefs)
        window.showsDesktopChats = true
        source.attach(window)
        source.open(id, in: window)
        let reader = try XCTUnwrap(window.desktopReader)
        let runtime = CodexAppServerRuntime(configuration: .localQwen)
        let choice = WebsiteModelChoice(provider: "gemini", key: "Flash", label: "Flash")
        let option = WebsiteModelCatalog.option(for: choice)
        let selection = ["thread": id, "selection": reader.request.uuidString, "model": option.id, "expected": "gpt"]
        do {
            _ = try await source.conversation("changeModel", body: selection, in: window, runtime: runtime)
            XCTFail("An unobserved account choice was selectable")
        } catch { XCTAssertEqual(try store.selectedModel(id), "gpt") }
        _ = try await source.conversation("changeModel", body: selection, in: window, runtime: runtime, websiteOptions: [option])
        let submission = ["thread": id, "selection": reader.request.uuidString, "expected": option.id,
                          "submission": UUID().uuidString, "text": "hello"]
        do {
            _ = try await source.conversation("send", body: submission, in: window, runtime: runtime, websiteOptions: [])
            XCTFail("An expired account choice reached submission")
        } catch {
            XCTAssertEqual(error.localizedDescription, CodexDesktopSidebarClient.Failure.unavailableModel.localizedDescription)
            XCTAssertEqual(try store.selectedModel(id), option.id)
            XCTAssertEqual((try store.page(id, cursor: nil, ascending: true)["data"] as? [[String: Any]])?.count, 0)
        }
    }

    /// Opt in with a synthetic, explicitly prepared official thread. Never select the user's active chat.
    func testRealImportAndProviderContinuation() async throws {
        guard let root = ProcessInfo.processInfo.environment["KOLMOGOR_IMPORT_LIVE"] else { throw XCTSkip("Requires a disposable signed-in conversation.") }
        struct Fixture: Decodable { let id: UUID; let wordA: String; let title: String }
        let folder = URL(fileURLWithPath: root)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: folder.appendingPathComponent("thread.json")))
        guard fixture.title.hasPrefix("Kolmogor model check "), fixture.wordA.range(of: #"^LANTERN-[0-9A-F]{8}$"#, options: .regularExpression) != nil
        else { throw CocoaError(.fileReadCorruptFile) }
        let profile = InstalledCodexCLI.userProfile
        let id = fixture.id.uuidString.lowercased()
        let runtime = SelectableCodexRuntime(configuration: .init(executable: .installedCLI(), installedCLIProfile: profile,
            modelProvider: "openai", model: "", workspacePath: folder.path, codexHomePath: folder.appendingPathComponent("kolmogor-runtime").path,
            baseInstructions: "", reasoningEffort: "medium"))
        addTeardownBlock { _ = await runtime.shutdown() }
        let copies = folder.appendingPathComponent("Copies")
        let restoring = ProcessInfo.processInfo.environment["KOLMOGOR_IMPORT_TEST_MODE"] == "reopen"
        let source = try XCTUnwrap(CodexSidebarSync.installed(preferences: isolatedTestPreferences(),
            candidates: restoring ? [] : InstalledCodexCLI.candidateURLs, directory: copies))
        let prefs = try XCTUnwrap(UserDefaults(suiteName:"Kolmogor.ImportQualification." + fixture.id.uuidString))
        let view = try await chatWindow(source, preferences:prefs, runtime:runtime)
        let scope = "document.querySelector('[aria-label=\"Imported chats\"]')"
        try await waitFor("!!" + scope, in: view)
        if !restoring {
            _ = try await view.evaluateJavaScript(scope + ".click()")
            for _ in 0..<2 {
                let browse = "document.querySelector('[title=\"Import from Codex\"]')"
                try await waitFor("!!" + browse, in: view)
                _ = try await view.evaluateJavaScript(browse + ".click()")
                let row = "document.querySelector('[data-desktop-chat=\"\(id)\"] button')"
                try await waitFor("!!" + row, in: view)
                _ = try await view.evaluateJavaScript(row + ".click()")
                try await waitFor("!!document.querySelector('textarea') && !!document.querySelector('.desktop-reader')", in: view)
                XCTAssertEqual(source.library.count, 1)
                XCTAssertNotEqual(source.library[0].id.lowercased(), id)
            }
            try Data(source.library[0].id.utf8).write(to: folder.appendingPathComponent("local-id"))
        } else {
            let local = try String(contentsOf: folder.appendingPathComponent("local-id"), encoding: .utf8)
            let row = "document.querySelector('[data-desktop-chat=\"\(local)\"] button')"
            try await waitFor("!!" + row, in: view)
            try await waitFor(row + ".getAttribute('aria-current') === 'page'", in:view)
        }
        let picker = "document.querySelector('select[aria-label=\"Conversation model\"]')"
        let body = "document.querySelector('.desktop-reader')?.innerText"
        try await waitFor("\(body)?.includes('\(fixture.wordA)') && !!\(picker)", in: view)
        let gemini = "cli/antigravity/model/gemini-3.8-flash", claude = "cli/claude/model/claude-sonnet-4-6"
        func select(_ value: String) async throws {
            _ = try await view.evaluateJavaScript("(() => { const p = \(picker); p.value = '\(value)'; p.dispatchEvent(new Event('change',{bubbles:true})); })()")
        }
        func awaitResult(_ predicate: String, seconds: Int = 120) async throws {
            let until = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < until {
                if (try? await view.evaluateJavaScript(predicate)) as? Bool == true { return }
                if let error = try? await view.evaluateJavaScript("document.querySelector('.composer-zone [role=alert], .desktop-reader [role=alert]')?.textContent"),
                   let reason = error as? String, !reason.isEmpty { throw NSError(domain: "RouterTest", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
                try await Task.sleep(for: .milliseconds(200))
            }
            try await waitFor(predicate, in: view, seconds: 1)
        }
        func load(_ provider: String, model: String) async throws {
            try await select("@" + provider)
            try await awaitResult("Array.from(\(picker).options).some(o=>o.value==='\(model)') && !\(picker).disabled")
        }
        let mode = ProcessInfo.processInfo.environment["KOLMOGOR_IMPORT_TEST_MODE"] ?? "closed"
        if mode == "reopen" {
            try await awaitResult("\(body)?.includes('\(fixture.wordA)-O-G-C') && \(body)?.includes('gemini-3.8-flash') && \(body)?.includes('claude-sonnet-4-6') && \(picker).value === '\(claude)'")
            return
        }
        try await load("codex", model: InstalledCodexCLI.prefix + "gpt-6.1-sol")
        try await load("antigravity", model: gemini)
        try await load("claude", model: claude)
        if mode == "catalog" { return }
        var answer = fixture.wordA
        for (model, suffix) in [(InstalledCodexCLI.prefix + "gpt-6.1-sol", "O"), (gemini, "G"), (claude, "C")] {
            try await select(model)
            try await awaitResult("\(picker).value === '\(model)' && !\(picker).disabled")
            let prompt = "Append -" + suffix + " to the previous assistant reply. Reply with the resulting marker only. Use no tools."
            let quoted = String(decoding: try JSONEncoder().encode(prompt), as: UTF8.self)
            _ = try await view.evaluateJavaScript("(() => { const f = document.querySelector('textarea[aria-label=\"Message imported chat\"]'); f.value = \(quoted); f.dispatchEvent(new Event('input',{bubbles:true})); })()")
            let send = "document.querySelector('[aria-label=\"Send to selected model\"]')"
            try await awaitResult("!\(send).disabled")
            _ = try await view.evaluateJavaScript(send + ".click()")
            answer += "-" + suffix
            try await awaitResult("\(body)?.includes('\(answer)')", seconds: 150)
            try Data(answer.utf8).write(to: folder.appendingPathComponent("receipt-" + suffix), options: .atomic)
        }
    }

}

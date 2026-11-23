import AppKit
import Security
import WebKit
import XCTest
@testable import Computa

final class BrowserSavedLoginTests: XCTestCase {
    private let site = "https://saved-login.example.invalid"

    private func vault() -> BrowserSavedLogins {
        let store = BrowserSavedLogins(servicePrefix: "test.kolmogor.logins." + UUID().uuidString + ".")
        let origins = [site, site + ":8443"]
        addTeardownBlock {
            for origin in origins {
                let query = [kSecClass as String: kSecClassGenericPassword as String,
                             kSecAttrService as String: store.servicePrefix + origin]
                SecItemDelete(query as CFDictionary)
            }
        }
        return store
    }

    private func export(_ content: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data(content.utf8).write(to: file, options: .withoutOverwriting)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    func testChromeExportPersistsExactValuesAndPreservesExistingLogins() throws {
        let store = vault()
        let csv = try export("\u{feff}" + """
        name,url,username,password,note
        One,https://SAVED-LOGIN.example.invalid:443/login,00017,"  00,a""b
        c  ",ignored
        Other,\(site):8443/login,,NULL,
        Duplicate,\(site)/elsewhere,00017,different,
        Unsafe,http://saved-login.example.invalid,case,skip,
        Userinfo,https://user@saved-login.example.invalid,case,skip,
        Incomplete,\(site)/,case,,
        """)
        let first = try store.importCSV(at: csv)
        XCTAssertEqual(first, .init(added: 2, existing: 1, skipped: 3))
        let reopened = BrowserSavedLogins(servicePrefix: store.servicePrefix)
        XCTAssertEqual(try reopened.accounts(for: site), ["00017"])
        XCTAssertEqual(try reopened.password(for: "00017", at: site), "  00,a\"b\nc  ")
        XCTAssertEqual(try reopened.password(for: "", at: site + ":8443"), "NULL")
        XCTAssertThrowsError(try reopened.password(for: "00017", at: site + ":8443"))
        XCTAssertEqual(try reopened.importCSV(at: csv), .init(added: 0, existing: 3, skipped: 3))
        XCTAssertEqual(try reopened.accounts(for: site + ".other.invalid"), [])
    }

    func testMalformedExportReturnsFixedError() throws {
        let store = vault()
        let invalid = try export("url,username,note\n\(site),fixture,synthetic-private-value")
        XCTAssertThrowsError(try store.importCSV(at: invalid)) {
            XCTAssertEqual($0.localizedDescription, BrowserSavedLogins.Failure.file.localizedDescription)
        }
        XCTAssertEqual(try store.accounts(for: site), [])
    }

    @MainActor
    func testSettingsImportAndFillIntoWebKitRequiresConsentAndCorrectDocument() async throws {
        let store = vault()
        let csv = try export("url,username,password\n\(site)/login,demo,fixture-only")
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let state = AppState(tasks: [], preferences: isolatedTestPreferences(), browserSession: session)
        let tabID = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: tabID))
        state.isBrowserPresented = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ChromeProfileLibrary(database: root.appendingPathComponent("destination/places.sqlite"))
        func run(choose: @escaping (NSWindow, [ChromeProfileLibrary.Profile]) async -> ChromeProfileImport.Selection?) async {
            await ChromeProfileImport.run(in: window, state: state, root: root, library: library, vault: store,
                                         chooseProfile: choose, chooseCSV: { _ in csv })
        }
        await run { _, _ in XCTFail("Settings required"); return nil }
        state.presentedSheet = .settings
        await run { _, _ in nil }
        XCTAssertNil(state.chromeProfileImportStatus)
        await run { _, profiles in
            XCTAssertTrue(state.importingChromeProfile)
            return .init(profile: profiles[0], categories: .init(history: false, bookmarks: false, passwords: true))
        }
        XCTAssertEqual(state.chromeProfileImportStatus, "Imported 1 saved login.")
        XCTAssertFalse(state.importingChromeProfile)

        state.presentedSheet = nil
        let html = """
        <form id="login"><input id="u" autocomplete="username"><input id="p" type="password" autocomplete="current-password">
        <button id="go">Sign in</button></form>
        <script>window.edits=0;window.submits=0;document.oninput=()=>edits++;document.onsubmit=e=>{e.preventDefault();submits++}</script>
        """
        func loadPage() async throws {
            view.loadHTMLString(html, baseURL: URL(string: site + "/login")!)
            for _ in 0..<120 {
                if !view.isLoading, (try? await view.evaluateJavaScript("document.getElementById('p') !== null && isSecureContext")) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("The local HTTPS fixture failed to load")
        }
        try await loadPage()
        let page = try XCTUnwrap(BrowserLoginControls.selectedPage(in: state))
        XCTAssertEqual(page.tabID, tabID)
        XCTAssertEqual(page.origin, site)
        state.presentedSheet = .settings
        XCTAssertNil(BrowserLoginControls.selectedPage(in: state))
        state.presentedSheet = nil
        func fill(choose: Bool = true, stalePage: Bool = false, auth: @escaping () async throws -> Bool) async throws {
            try await BrowserLoginControls.fillSelectedPage(in: window, selectedPage: { stalePage ? page : BrowserLoginControls.selectedPage(in: state) }, vault: store, choose: { accounts, origin, _ in
                XCTAssertEqual(origin, self.site)
                XCTAssertEqual(accounts, ["demo"])
                return choose ? accounts.first : nil
            }, authenticate: { _ in try await auth() })
        }
        try await fill(choose: false) { XCTFail("Cancel must skip authentication"); return false }
        try await fill { false }
        let blank = try await view.evaluateJavaScript("p.value === '' && u.value === '' && edits === 0")
        XCTAssertEqual(blank as? Bool, true)
        do {
            try await fill(stalePage: true) { try await loadPage(); return true }
            XCTFail("Replacing the document on the same origin must cancel the fill")
        } catch BrowserSavedLogins.Failure.form {}
        do {
            try await fill {
                _ = try session.createTab()
                return true
            }
            XCTFail("Switching tabs must cancel the fill")
        } catch BrowserSavedLogins.Failure.changed {}
        session.selectTab(tabID)
        for mutate in ["go.formAction = 'https://other.example.invalid/'", "p.autocomplete = 'new-password'",
                       "login.insertAdjacentHTML('beforeend','<input type=password>')"] {
            try await loadPage()
            _ = try await view.evaluateJavaScript(mutate + ";true")
            do { try await fill { true }; XCTFail("Ineligible form was filled") } catch BrowserSavedLogins.Failure.form {}
            let untouched = try await view.evaluateJavaScript("p.value === '' && edits === 0 && submits === 0")
            XCTAssertEqual(untouched as? Bool, true)
        }
        try await loadPage()
        try await fill { true }
        let filled = try await view.evaluateJavaScript("u.value === 'demo' && p.value === 'fixture-only' && edits === 2 && submits === 0")
        XCTAssertEqual(filled as? Bool, true)

    }
}

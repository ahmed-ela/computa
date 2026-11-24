import AppKit
import LocalAuthentication
import UniformTypeIdentifiers
import WebKit

@MainActor
enum BrowserLoginControls {
    static func chooseCSV(in window: NSWindow) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import Logins"
        panel.message = "Choose the CSV exported from Chrome Password Manager. Logins are stored in Kolmogor’s local Keychain items."
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    struct Page {
        let tabID: UUID
        let document: UUID
        let origin: String
        let view: WKWebView
    }

    static func selectedPage(in state: AppState) -> Page? {
        guard !state.approvalGateBlocksInteraction, state.presentedSheet == nil, state.shouldPresentBrowserPane,
              let id = state.workspaceTabs.browserIsPrimary ? state.displayedBrowserTab?.id : state.browserSession.selectedTabID,
              let tab = state.browserSession.workspaceBrowserTabs.first(where: { $0.id == id }),
              let view = state.browserSession.webView(for: id), !view.isLoading, view.hasOnlySecureContent,
              let origin = BrowserSavedLogins.origin(for: view.url) else { return nil }
        return Page(tabID: id, document: tab.documentID, origin: origin, view: view)
    }

    private static func chooseAccount(_ accounts: [String], _ origin: String, _ window: NSWindow) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Fill saved login for " + origin + "?"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for account in accounts {
            picker.menu?.addItem(NSMenuItem(title: account.isEmpty ? "(No username)" : account, action: nil, keyEquivalent: ""))
        }
        picker.selectItem(at: 0)
        alert.accessoryView = picker
        alert.addButton(withTitle: "Fill Login")
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
              accounts.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return accounts[picker.indexOfSelectedItem]
    }

    static func fill(in state: AppState, window: NSWindow) async {
        guard let profile = state.browserSession.workspaceProfileID else { return }
        let vault = BrowserSavedLogins.forProfile(profile)
        do {
            try await fillSelectedPage(in: window, selectedPage: {
                guard NSApp.isActive, window.isKeyWindow else { return nil }
                return selectedPage(in: state)
            }, vault: vault,
                choose: chooseAccount, authenticate: { origin in
                    try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                        localizedReason: "Fill your saved login for " + origin)
                })
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            return
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t fill saved login"
            alert.informativeText = (error as? BrowserSavedLogins.Failure)?.localizedDescription ?? "Verify your identity on this Mac and try again."
            await alert.beginSheetModal(for: window)
        }
    }

    static func fillSelectedPage(in window: NSWindow, selectedPage: () -> Page?, vault: BrowserSavedLogins,
                                 choose: ([String], String, NSWindow) async -> String?,
                                 authenticate: (String) async throws -> Bool) async throws {
        guard let page = selectedPage(), page.view.window === window else { return }
        let accounts = try vault.accounts(for: page.origin)
        guard !accounts.isEmpty else { throw BrowserSavedLogins.Failure.site }
        // The isolated world's marker belongs to this document, including during same-origin navigation.
        let marker = UUID().uuidString
        let marked = try await page.view.callAsyncJavaScript("""
            if (!isSecureContext || location.origin !== origin) return false;
            globalThis.kolmogorLoginRequest = marker;
            return true;
            """, arguments: ["origin": page.origin, "marker": marker], in: nil, contentWorld: .defaultClient)
        guard marked as? Bool == true else { throw BrowserSavedLogins.Failure.changed }
        guard let username = await choose(accounts, page.origin, window), accounts.contains(username),
              try await authenticate(page.origin) else { return }
        guard let current = selectedPage(), current.tabID == page.tabID, current.document == page.document,
              current.origin == page.origin, current.view === page.view, current.view.window === window,
              !current.view.isLoading, BrowserSavedLogins.origin(for: current.view.url) == page.origin else {
            throw BrowserSavedLogins.Failure.changed
        }
        let password = try vault.password(for: username, at: page.origin)
        let applied = try await page.view.callAsyncJavaScript("""
            if (window.top !== window || !isSecureContext || location.origin !== origin || globalThis.kolmogorLoginRequest !== marker) return false;
            delete globalThis.kolmogorLoginRequest;
            const visible = el => {
                if (el.disabled || el.readOnly || el.closest('[inert]')) return false;
                if (el.checkVisibility && !el.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return false;
                const style = getComputedStyle(el), rect = el.getBoundingClientRect();
                return style.visibility === 'visible' && style.opacity !== '0' && rect.width > 0 && rect.height > 0;
            };
            const fields = Array.from(document.querySelectorAll('input')).filter(visible);
            const passwords = fields.filter(el => el.type === 'password');
            if (passwords.length > 1 || passwords.some(el => el.autocomplete.split(/\\s+/).includes('new-password'))) return false;
            const secret = passwords[0];
            const candidates = fields.filter(el => ['text','email'].includes(el.type)
                && (!secret || (secret.form === el.form && (el.compareDocumentPosition(secret) & Node.DOCUMENT_POSITION_FOLLOWING)))
                && (el.type === 'email' || el.autocomplete.split(/\\s+/).includes('username')
                    || (secret && /^(user(name)?|email|login)$/i.test(el.name || el.id))));
            if ((!secret && (candidates.length !== 1 || !username)) || candidates.length > 1) return false;
            const user = candidates[0];
            if (user && user.value && user.value !== username) return false;
            if (!secret && user.autocomplete !== 'username' && !/sign.?in|log.?in/i.test(location.pathname + ' ' + (user.form?.id || ''))) return false;
            const form = (secret || user).form;
            if (form && new URL(form.action || location.href, location.href).origin !== origin) return false;
            if (form && Array.from(form.elements).some(el => el.hasAttribute('formaction')
                && new URL(el.formAction, location.href).origin !== origin)) return false;
            const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            if (user) set.call(user, username);
            if (secret) set.call(secret, password);
            for (const el of [user, secret].filter(Boolean)) {
                el.dispatchEvent(new Event('input', {bubbles:true}));
                el.dispatchEvent(new Event('change', {bubbles:true}));
            }
            return true;
            """, arguments: ["origin": page.origin, "marker": marker, "username": username, "password": password], in: nil, contentWorld: .defaultClient)
        guard applied as? Bool == true else { throw BrowserSavedLogins.Failure.form }
    }
}

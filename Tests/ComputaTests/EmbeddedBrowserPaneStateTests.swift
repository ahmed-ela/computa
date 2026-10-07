import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Computa

final class EmbeddedBrowserPaneStateTests: XCTestCase {
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

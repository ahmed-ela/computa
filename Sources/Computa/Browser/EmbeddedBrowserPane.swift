import AppKit
import SwiftUI
import WebKit

/// A presentation-only component. The injected session owns tab lifetimes, so
/// collapsing this pane or showing Settings never closes pages or loses logins.
@MainActor
struct EmbeddedBrowserPane: View {
    let session: EmbeddedBrowserSession
    var tabRowHeight: CGFloat = 32
    var usesSidebarTabs = false
    var workspacePageID: UUID?
    var openTitlebarAddress: (() -> Void)?
    var showsNewTabButton = true
    var titlebarLeadingInset: CGFloat = 0
    var titlebarTrailingInset: CGFloat = 0
    var isInteractionBlocked = false
    var canLoadModels = false
    var modelSetupStatus: (String) -> WebsiteModelSetupStatus = { _ in .unchecked }
    var onLoadModels: (UUID) -> Void = { _ in }
    var canConfigureKimiProfile = false
    var onSwitchKimiProfile: (UUID) -> Void = { _ in }
    let onCloseTab: (WorkspaceTabID) -> Void
    let onClose: () -> Void

    @State private var address = ""
    @State private var addressError: String?
    @FocusState private var addressFocused: Bool

    private var selectedTab: EmbeddedBrowserTab? {
        session.humanTabs.first { $0.id == (workspacePageID ?? session.selectedTabID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if openTitlebarAddress != nil || !usesSidebarTabs || showsNewTabButton {
                browserHeader
                Divider()
            }
            if !usesSidebarTabs {
                navigationBar
                Divider()
            }

            if let tab = selectedTab, let provider = tab.setupProvider,
               session.setupTab(for: provider)?.id == tab.id {
                let status = modelSetupStatus(provider.rawValue)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        switch status {
                        case .unchecked: Text("Check which models are available in your \(provider.displayName) account.")
                        case .checking:
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Checking \(provider.displayName)…")
                            }
                        case .loaded(let count): Text("\(count) options available in the model picker.")
                        case .signInRequired(let message), .failed(let message): Text(message).textSelection(.enabled)
                        }
                        if provider == .kimi {
                            Button(session.isKimiProfileTab(tab.id) ? "Use regular browser profile" : "Use separate Kimi profile") {
                                onSwitchKimiProfile(tab.id)
                            }
                            .buttonStyle(.link)
                            .disabled(!canConfigureKimiProfile || isInteractionBlocked)
                        }
                    }
                    Spacer()
                    if provider == .kimi || !status.isLoaded {
                        Button("Load models") { onLoadModels(tab.id) }
                            .disabled(!canLoadModels || status == .checking)
                    }
                    if status.isLoaded {
                        Button("Done") {
                            session.closeTab(tab.id)
                            onClose()
                        }
                    }
                }
                .font(.callout)
                .padding(10)
                Divider()
            }

            if let error = addressError ?? selectedTab?.error ?? (workspacePageID == nil ? session.errorMessage : nil) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(10)
                .background(.quaternary.opacity(0.4))
                .accessibilityIdentifier("browser-error")
                Divider()
            }

            if let tab = selectedTab, let webView = session.webView(for: tab.id) {
                ZStack {
                    EmbeddedBrowserPageHost(session: session, tabID: tab.id, webView: webView,
                                            isInteractionBlocked: isInteractionBlocked)
                    if tab.url == nil, !tab.isLoading, !tab.isPopup {
                        emptyPage(hasTab: true)
                    }
                }
            } else {
                emptyPage(hasTab: false)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("embedded-browser-pane")
        .focusedSceneValue(\.browserZoomTabID, selectedTab?.id)
        .focusedValue(\.browserPaneFocused, true)
        .focusedSceneValue(\.focusBrowserAddress, { addressFocused = true })
        .onAppear { synchronizeAddress() }
        .onChange(of: selectedTab?.id) { _, _ in
            addressError = nil
            address = selectedTab?.url?.absoluteString ?? ""
        }
        .onChange(of: selectedTab?.url) { _, _ in synchronizeAddress() }
        .onChange(of: addressFocused) { _, focused in
            if focused { selectAddressOnFirstClick() } else { synchronizeAddress() }
        }
        .onChange(of: isInteractionBlocked) { _, blocked in
            if blocked { addressFocused = false }
        }
    }

    private var browserHeader: some View {
        HStack(spacing: 4) {
            if !usesSidebarTabs { tabPicker }
            if let openTitlebarAddress, let tab = selectedTab {
                BrowserHistoryButtons(session: session, selectedTab: tab)
                Button(action: openTitlebarAddress) {
                    BrowserAddressPill(height: max(18, min(28, tabRowHeight - 4)), editing: false) {
                        Text(tab.url?.absoluteString ?? "Search or enter a website address")
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityLabel("Website address")
                .accessibilityValue(tab.url?.absoluteString ?? "")
                .help("Edit website address (⌘L)")
                .anchorPreference(key: BrowserAddressBounds.self, value: .bounds) { $0 }
            }

            if showsNewTabButton {
                Button { createTab() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .contextMenu {
                    Button("New Mobile Tab") { createTab(requestsMobileSite: true) }
                }
                .help("New browser tab. Control-click for a mobile tab.")
                .accessibilityLabel("New browser tab")
                .accessibilityIdentifier("browser-new-tab")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.leading, titlebarLeadingInset)
        // The globe is a native accessory at the trailing edge of this row.
        .padding(.trailing, titlebarTrailingInset)
        .frame(height: tabRowHeight)
    }

    private var tabPicker: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(session.workspaceBrowserTabs) { tab in
                        EmbeddedBrowserTabButton(
                            tab: tab,
                            selected: tab.id == session.selectedTabID,
                            isKimiProfile: session.isKimiProfileTab(tab.id),
                            onSelect: { session.selectTab(tab.id) },
                            onClose: { onCloseTab(.browser(tab.workspaceID)) }
                        )
                        .id(tab.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.selectedTabID) { _, id in
                if let id { scroll.scrollTo(id, anchor: .trailing) }
            }
            .onAppear {
                if let id = session.selectedTabID { scroll.scrollTo(id, anchor: .trailing) }
            }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            BrowserHistoryButtons(session: session, selectedTab: selectedTab)

            HStack(spacing: 7) {
                Image(systemName: addressFocused || address.isEmpty ? "magnifyingglass" : "globe")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search or enter a website address", text: $address)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit(navigate)
                    .onExitCommand { addressFocused = false }
                    .accessibilityLabel("Website address")
                    .accessibilityIdentifier("browser-address")
                if addressFocused {
                    Button(action: navigate) { Image(systemName: "arrow.right") }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Go to address")
                        .accessibilityLabel("Go to address")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.primary.opacity(0.055), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.secondary.opacity(addressFocused ? 0.7 : 0), lineWidth: 1.5).allowsHitTesting(false) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func emptyPage(hasTab: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "globe").font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(hasTab ? (selectedTab?.requestsMobileSite == true ? "New mobile tab" : "New tab") : "Your browser, inside Kolmogor")
                .font(.headline)
            Text("Search or enter a website address to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasTab {
                Button("New browser tab") { createTab() }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func selectAddressOnFirstClick() {
        // Preserve native drag/word selections and focus restored by an agent's background page.
        guard let click = NSApp.currentEvent, click.type == .leftMouseUp || click.type == .leftMouseDown,
              click.clickCount == 1, click.modifierFlags.isDisjoint(with: [.shift, .command, .option, .control]),
              let tab = selectedTab, let window = session.webView(for: tab.id)?.window, window === click.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField,
              editor.bounds.contains(editor.convert(click.locationInWindow, from: nil))
        else { return }
        // AppKit places the caret during mouse tracking, sometimes after SwiftUI reports focus.
        let addressAtClick = editor.string
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak editor, weak field] in
            MainActor.assumeIsolated {
                guard let editor, let field, field.currentEditor() === editor, editor.window?.firstResponder === editor,
                      editor.string == addressAtClick, editor.selectedRange().length == 0, !editor.hasMarkedText() else { return }
                editor.selectAll(nil)
            }
        }
    }

    private func synchronizeAddress() {
        guard !addressFocused else { return }
        // WebKit may not publish the provisional URL immediately. Keep the
        // explicitly submitted address visible until that observation arrives.
        guard selectedTab?.isLoading != true || selectedTab?.url != nil else { return }
        address = selectedTab?.url?.absoluteString ?? ""
    }

    private func createTab(requestsMobileSite: Bool = false) {
        guard !isInteractionBlocked else { return }
        do {
            _ = try session.createTab(url: EmbeddedBrowserURLPolicy.newTabURL, requestsMobileSite: requestsMobileSite)
            addressError = nil
            address = ""
            // Only an explicit human new-tab action changes editor focus.
            addressFocused = true
        } catch { addressError = error.localizedDescription }
    }

    private func navigate() {
        guard !isInteractionBlocked else { return }
        do {
            let url = try EmbeddedBrowserURLPolicy.normalize(address)
            if let id = selectedTab?.id {
                try session.navigate(tabID: id, to: url, fromAddressBar: true)
            } else {
                _ = try session.createTab(url: url)
            }
            addressError = nil
            addressFocused = false
        } catch { addressError = error.localizedDescription }
    }
}

@MainActor
func tabIconAsset(_ name: String, fallback: String) -> Image {
    guard let url = WebUIResourceLocator.indexURL?.deletingLastPathComponent().appendingPathComponent("icons/\(name).svg"),
          let image = NSImage(contentsOf: url) else { return Image(systemName: fallback) }
    return Image(nsImage: image)
}

private struct LoadingFavicon: View {
    private static let icon = tabIconAsset("favicon-loading", fallback: "circle.dashed")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        let rotate = visible && !reduceMotion
        Self.icon.renderingMode(.template).resizable().foregroundStyle(.secondary)
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(rotate ? .linear(duration: 1).repeatForever(autoreverses: false) : nil, value: rotate)
            .onAppear { visible = true }
            .accessibilityHidden(true)
    }
}

@MainActor
private struct EmbeddedBrowserTabButton: View {
    let tab: EmbeddedBrowserTab
    let selected: Bool
    let isKimiProfile: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var pageTitle: String { tab.title.isEmpty ? "New tab" : tab.title }
    private var displayTitle: String { isKimiProfile ? "Kimi sign-in" : pageTitle }
    private var tabIcon: String {
        if tab.requestsMobileSite { return "iphone" }
        return isKimiProfile ? "person.crop.circle" : "globe"
    }
    private var tabDescription: String {
        if tab.requestsMobileSite { return "Mobile tab, " + pageTitle }
        return isKimiProfile ? "Kimi sign-in, " + pageTitle : pageTitle
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if tab.isFaviconLoading {
                        LoadingFavicon().frame(width: 14, height: 14)
                    } else if let data = tab.favicon, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: tabIcon).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .help(tabDescription)
            .accessibilityLabel(tabDescription)
            .accessibilityValue(selected ? "Selected" : "")

            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .frame(width: 18, height: 24)
                .help("Close tab")
                .accessibilityLabel("Close \(isKimiProfile ? "Kimi sign-in tab" : tab.title.isEmpty ? "tab" : tab.title)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(width: 160, height: 26)
        .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(selected ? 0.12 : 0.04)))
        .accessibilityIdentifier("browser-tab-\(tab.id.uuidString)")
    }
}

/// Mount an existing tab without recreating its configuration or borrowing the
/// privileged UI's message handlers. The session, not this view, owns teardown.
@MainActor
private struct EmbeddedBrowserPageHost: NSViewRepresentable {
    let session: EmbeddedBrowserSession
    let tabID: UUID
    let webView: WKWebView
    let isInteractionBlocked: Bool

    func makeNSView(context: Context) -> EmbeddedBrowserPageContainer {
        let view = EmbeddedBrowserPageContainer()
        // AppKit can include the surrounding split pane in a child's visibleRect
        // unless the page host clips at its own bounds.
        view.clipsToBounds = true
        view.update(session: session, tabID: tabID, webView: webView, interactionBlocked: isInteractionBlocked)
        return view
    }

    func updateNSView(_ view: EmbeddedBrowserPageContainer, context: Context) {
        view.update(session: session, tabID: tabID, webView: webView, interactionBlocked: isInteractionBlocked)
    }

    static func dismantleNSView(_ view: EmbeddedBrowserPageContainer, coordinator: ()) {
        view.detach()
    }
}

@MainActor
private final class EmbeddedBrowserPageContainer: NSView {
    private weak var session: EmbeddedBrowserSession?
    private var mountedTabID: UUID?
    private weak var mountedWebView: WKWebView?
    private var interactionBlocked = false

    func update(session: EmbeddedBrowserSession, tabID: UUID, webView: WKWebView, interactionBlocked: Bool) {
        if mountedWebView !== webView {
            detach()
            self.session = session
            mountedTabID = tabID
            try? session.presentTab(tabID, in: self)
            mountedWebView = webView
        }
        self.interactionBlocked = interactionBlocked
        if interactionBlocked { relinquishPageFocus() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return interactionBlocked ? self : hit
    }

    override func keyDown(with event: NSEvent) {
        if !interactionBlocked { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if !interactionBlocked { super.keyUp(with: event) }
    }

    func detach() {
        relinquishPageFocus()
        if let mountedTabID { session?.detachPresentedTab(mountedTabID, from: self) }
        mountedWebView = nil
        mountedTabID = nil
        session = nil
    }

    private func relinquishPageFocus() {
        guard let responder = window?.firstResponder as? NSView,
              responder === mountedWebView || responder.isDescendant(of: self) else { return }
        // Approval settlement and human hide/switch can relinquish focus, but
        // ordinary browser rendering must not acquire it.
        window?.makeFirstResponder(nil)
    }
}

/// Nonhidden, fixed-size model pages remain in the application's existing
/// window behind the opaque workspace. No window creation or activation occurs.
@MainActor
struct EmbeddedModelRenderHost: NSViewRepresentable {
    let session: EmbeddedBrowserSession

    func makeNSView(context: Context) -> EmbeddedModelRenderContainer {
        let view = EmbeddedModelRenderContainer(session: session)
        session.installModelRenderHost(view)
        return view
    }

    func updateNSView(_ view: EmbeddedModelRenderContainer, context: Context) {
        session.installModelRenderHost(view)
    }

    static func dismantleNSView(_ view: EmbeddedModelRenderContainer, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class EmbeddedModelRenderContainer: NSView {
    private weak var session: EmbeddedBrowserSession?

    init(session: EmbeddedBrowserSession) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func detach() { session?.removeModelRenderHost(self) }
}

import AppKit
import SwiftUI
import WebKit

/// A presentation-only component. The injected session owns tab lifetimes, so
/// collapsing this pane or showing Settings never closes pages or loses logins.
@MainActor
struct EmbeddedBrowserPane: View {
    let session: EmbeddedBrowserSession
    var isInteractionBlocked = false
    let onClose: () -> Void

    @State private var address = ""
    @State private var addressError: String?
    @FocusState private var addressFocused: Bool

    private var selectedTab: EmbeddedBrowserTab? {
        session.tabs.first { $0.id == session.selectedTabID }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            navigationBar
            Divider()

            if let error = addressError ?? selectedTab?.error ?? session.errorMessage {
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
                    EmbeddedBrowserPageHost(webView: webView, isInteractionBlocked: isInteractionBlocked)
                    if tab.url == nil, !tab.isLoading {
                        emptyPage(hasTab: true)
                    }
                }
            } else {
                emptyPage(hasTab: false)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("embedded-browser-pane")
        .onAppear { synchronizeAddress() }
        .onChange(of: session.selectedTabID) { _, _ in
            addressError = nil
            address = selectedTab?.url?.absoluteString ?? ""
        }
        .onChange(of: selectedTab?.url) { _, _ in synchronizeAddress() }
        .onChange(of: addressFocused) { _, focused in
            if !focused { synchronizeAddress() }
        }
        .onChange(of: isInteractionBlocked) { _, blocked in
            if blocked { addressFocused = false }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(session.tabs) { tab in
                            EmbeddedBrowserTabButton(
                                tab: tab,
                                selected: tab.id == session.selectedTabID,
                                onSelect: { session.selectTab(tab.id) },
                                onClose: { session.closeTab(tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                .onChange(of: session.selectedTabID) { _, id in
                    if let id { scroll.scrollTo(id, anchor: .trailing) }
                }
                .onAppear {
                    if let id = session.selectedTabID { scroll.scrollTo(id, anchor: .trailing) }
                }
            }

            Button(action: createTab) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .keyboardShortcut("t", modifiers: .command)
            .help("New tab (⌘T)")
            .accessibilityLabel("New browser tab")
            .accessibilityIdentifier("browser-new-tab")

            Button(action: onClose) {
                Image(systemName: "sidebar.right")
                    .frame(width: 24, height: 24)
            }
            .help("Hide browser — tabs stay open")
            .accessibilityLabel("Hide browser")
            .accessibilityIdentifier("browser-hide")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 42)
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                if let id = selectedTab?.id { session.goBack(tabID: id) }
            } label: { Image(systemName: "chevron.left") }
            .disabled(selectedTab?.canGoBack != true)
            .help("Back")
            .accessibilityLabel("Back")

            Button {
                if let id = selectedTab?.id { session.goForward(tabID: id) }
            } label: { Image(systemName: "chevron.right") }
            .disabled(selectedTab?.canGoForward != true)
            .help("Forward")
            .accessibilityLabel("Forward")

            Button {
                guard let tab = selectedTab else { return }
                if tab.isLoading { session.stop(tabID: tab.id) }
                else { session.reload(tabID: tab.id) }
            } label: {
                Image(systemName: selectedTab?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .frame(width: 16)
            }
            .disabled(selectedTab == nil || (selectedTab?.url == nil && selectedTab?.isLoading != true))
            .help(selectedTab?.isLoading == true ? "Stop loading" : "Reload")
            .accessibilityLabel(selectedTab?.isLoading == true ? "Stop loading" : "Reload")

            TextField("Search or enter a website address", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit(navigate)
                .accessibilityLabel("Website address")
                .accessibilityIdentifier("browser-address")

            Button(action: navigate) { Image(systemName: "arrow.right") }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Go to address")
                .accessibilityLabel("Go to address")
        }
        .buttonStyle(.borderless)
        .padding(10)
    }

    private func emptyPage(hasTab: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "globe").font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(hasTab ? "New tab" : "Your browser, inside Computa")
                .font(.headline)
            Text("Search or enter a website address to get started.\nSign in here separately from Chrome.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasTab {
                Button("New tab", action: createTab)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func synchronizeAddress() {
        guard !addressFocused else { return }
        // WebKit may not publish the provisional URL immediately. Keep the
        // explicitly submitted address visible until that observation arrives.
        guard selectedTab?.isLoading != true || selectedTab?.url != nil else { return }
        address = selectedTab?.url?.absoluteString ?? ""
    }

    private func createTab() {
        guard !isInteractionBlocked else { return }
        do {
            _ = try session.createTab()
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
                try session.navigate(tabID: id, to: url)
            } else {
                _ = try session.createTab(url: url)
            }
            addressError = nil
            addressFocused = false
        } catch { addressError = error.localizedDescription }
    }
}

@MainActor
private struct EmbeddedBrowserTabButton: View {
    let tab: EmbeddedBrowserTab
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if tab.isLoading {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "globe").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(tab.title.isEmpty ? "New tab" : tab.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(tab.title.isEmpty ? "New tab" : tab.title)
            .accessibilityValue(selected ? "Selected" : "")

            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .frame(width: 18, height: 24)
                .help("Close tab")
                .accessibilityLabel("Close \(tab.title.isEmpty ? "tab" : tab.title)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(width: 160, height: 30)
        .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(selected ? 0.12 : 0.04)))
        .accessibilityIdentifier("browser-tab-\(tab.id.uuidString)")
    }
}

/// Mount an existing tab without recreating its configuration or borrowing the
/// privileged UI's message handlers. The session, not this view, owns teardown.
@MainActor
private struct EmbeddedBrowserPageHost: NSViewRepresentable {
    let webView: WKWebView
    let isInteractionBlocked: Bool

    func makeNSView(context: Context) -> EmbeddedBrowserPageContainer {
        let view = EmbeddedBrowserPageContainer()
        view.update(webView: webView, interactionBlocked: isInteractionBlocked)
        return view
    }

    func updateNSView(_ view: EmbeddedBrowserPageContainer, context: Context) {
        view.update(webView: webView, interactionBlocked: isInteractionBlocked)
    }

    static func dismantleNSView(_ view: EmbeddedBrowserPageContainer, coordinator: ()) {
        view.detach()
    }
}

@MainActor
private final class EmbeddedBrowserPageContainer: NSView {
    private weak var mountedWebView: WKWebView?
    private var interactionBlocked = false

    func update(webView: WKWebView, interactionBlocked: Bool) {
        if mountedWebView !== webView {
            detach()
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
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
        mountedWebView?.removeFromSuperview()
        mountedWebView = nil
    }

    private func relinquishPageFocus() {
        guard let responder = window?.firstResponder as? NSView,
              responder === mountedWebView || responder.isDescendant(of: self) else { return }
        // Approval settlement and human hide/switch can relinquish focus, but
        // ordinary browser rendering must not acquire it.
        window?.makeFirstResponder(nil)
    }
}

import AppKit
import AutomationCore
import SwiftUI
import WebKit
#if !SWIFT_PACKAGE
import Sparkle
#endif

/// Hosted XCTest launches the application entry point before running fixtures.
/// Its scene must never attach a second runtime to the user's production home.
enum ComputaLaunchMode: Equatable {
    case application
    case testHost

    static var current: Self {
        detect(environment: ProcessInfo.processInfo.environment,
               xctestClassLoaded: NSClassFromString("XCTestCase") != nil)
    }

    static func detect(environment: [String: String], xctestClassLoaded: Bool) -> Self {
        let markers = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        return xctestClassLoaded || markers.contains(where: { environment[$0] != nil })
            ? .testHost : .application
    }

    @MainActor
    func makeState(
        runtimeFactory: () -> any AgentRuntimeClient = { SelectableCodexRuntime() },
        preferencesFactory: () -> UserDefaults = { .standard },
        unreadCompletionStoreFactory: () -> ChatUnreadCompletionStore? = { .applicationDefault }
    ) -> AppState {
        switch self {
        case .application:
            let preferences = preferencesFactory()
            // Human tabs and owned ChatGPT inference tabs share this profile;
            // the privileged app UI remains in its separate WebView.
            let browser = EmbeddedBrowserSession(defaults: preferences)
            return AppState(tasks: [], runtime: runtimeFactory(), preferences: preferences,
                            unreadCompletionStore: unreadCompletionStoreFactory(),
                            browserSession: browser, desktopSidebar: CodexSidebarSync.installed())
        case .testHost:
            // A unique suite prevents even incidental test-host state changes
            // from reading or writing the application's saved access choice.
            let preferences = UserDefaults(suiteName: "Computa.XCTestHost.\(UUID().uuidString)")!
            return AppState(tasks: [], runtime: nil,
                            permissionClient: InertTestHostPermissions(), preferences: preferences)
        }
    }
}

private struct InertTestHostPermissions: AutomationPermissionClient {
    func current() -> AutomationPermissionSnapshot {
        .init(accessibility: .notGranted, screenRecording: .notGranted)
    }

    func requestAccessibility() -> AutomationPermissionSnapshot { current() }
    func requestScreenRecording() -> AutomationPermissionSnapshot { current() }
}

extension FocusedValues {
    @Entry var focusBrowserAddress: (() -> Void)?
    @Entry var browserPaneFocused: Bool?
    @Entry var browserPageCommandsAllowed: Bool?
    @Entry var browserZoomTabID: UUID?
    @Entry var workspaceSidebarCollapsed: Binding<Bool>?
    @Entry var tabWorkspace: AppState?
}

struct WorkspaceCommands: Commands {
    let state: AppState
    let isTestHost: Bool
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.focusBrowserAddress) private var focusBrowserAddress
    @FocusedValue(\.tabWorkspace) private var tabWorkspace
    @FocusedBinding(\.workspaceSidebarCollapsed) private var sidebarCollapsed

    @FocusedValue(\.browserPaneFocused) private var browserPaneFocused

    @FocusedValue(\.browserPageCommandsAllowed) private var browserPageCommandsAllowed

    @FocusedValue(\.browserZoomTabID) private var browserZoomTabID

    private var zoomTabID: UUID? {
        guard !workspaceUnavailable, browserPageCommandsAllowed == true,
              tabWorkspace?.mixesBrowserTabsInSidebar == true || usesBrowserShortcuts else { return nil }
        return browserZoomTabID
    }

    private func zoom(_ command: BrowserPageZoomCommand) {
        if let id = zoomTabID { tabWorkspace?.browserSession.changePageZoom(command, tabID: id) }
    }

    private var reloadTabID: UUID? {
        guard !workspaceUnavailable, browserPageCommandsAllowed == true else { return nil }
        return tabWorkspace?.reloadableBrowserTabID(inBrowserPane: usesBrowserShortcuts)
    }

    private var usesBrowserShortcuts: Bool {
        !state.mixesBrowserTabsInSidebar && state.shouldPresentBrowserPane
            && (browserPaneFocused == true || state.selectedWorkspaceTab == nil)
    }

    private var workspaceUnavailable: Bool {
        isTestHost || state.approvalGateBlocksInteraction || state.presentedSheet != nil
    }

    private func open(_ item: WorkspaceWindowHosting.NewItem) {
        state.windowHosting.open(item, from: NSApp.keyWindow ?? NSApp.mainWindow) { tabs in
            if tabs === state.workspaceWindows.primary { openWindow(id: "workspace") }
            else { openWindow(id: "workspace", value: tabs.id) }
        }
    }

    var body: some Commands {
        let tabs = state.commandTabs(inBrowserPane: usesBrowserShortcuts)
        CommandGroup(replacing: .newItem) {
            Button("New Window") { open(.window) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspaceUnavailable)
            Button("New Agent") { open(.agent) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspaceUnavailable)
            Button("New Browser Tab") { open(.browser) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(workspaceUnavailable)
        }
        CommandGroup(replacing: .saveItem) {
            if let tabWorkspace {
                Button("Close Tab") {
                    tabWorkspace.windowHosting.closeTabOrWindow(NSApp.keyWindow, inBrowserPane: usesBrowserShortcuts)
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(workspaceUnavailable || (!tabWorkspace.workspaceTabs.order.isEmpty
                    && !tabWorkspace.workspaceTabs.showsDesktopChats && !tabWorkspace.workspaceTabs.showsNewAgent && tabWorkspace.commandTab(inBrowserPane: usesBrowserShortcuts) == nil))
            }
            Button("Reopen Closed Tab") { state.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(isTestHost || !state.canReopenClosedTab)
            Button("Close Window") {
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("w", modifiers: tabWorkspace == nil ? .command : [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button(sidebarCollapsed == true ? "Expand Sidebar" : "Collapse Sidebar") {
                sidebarCollapsed?.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(isTestHost || sidebarCollapsed == nil)

            Button("Fill Saved Login…") {
                guard let tabWorkspace, let window = NSApp.keyWindow else { return }
                Task { @MainActor in await BrowserLoginControls.fill(in: tabWorkspace, window: window) }
            }
            .disabled(workspaceUnavailable || tabWorkspace.flatMap { BrowserLoginControls.selectedPage(in: $0) } == nil)
            Button("Reload Page") {
                if let id = reloadTabID { tabWorkspace?.browserSession.reload(tabID: id) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(reloadTabID == nil)
            Group {
                Button("Zoom In") { zoom(.zoomIn) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { zoom(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { zoom(.actualSize) }
                    .keyboardShortcut("0", modifiers: .command)
            }
            .disabled(zoomTabID == nil)
            Button("Focus Browser Address") {
                if tabWorkspace?.primaryBrowserID != nil { BrowserAddressPalette.request(in: NSApp.keyWindow) }
                else { focusBrowserAddress?() }
            }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(workspaceUnavailable || (tabWorkspace?.primaryBrowserID == nil && focusBrowserAddress == nil))
            Group {
                Button("Select Previous Workspace Tab") { state.selectAdjacentWorkspaceTab(.previous, inBrowserPane: usesBrowserShortcuts) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Select Next Workspace Tab") { state.selectAdjacentWorkspaceTab(.next, inBrowserPane: usesBrowserShortcuts) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
            }
            .disabled(workspaceUnavailable || tabs.isEmpty)
            Menu("Select Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Last Tab" : "Tab \(number)") {
                        tabWorkspace?.selectNumberedWorkspaceTab(number, inBrowserPane: usesBrowserShortcuts)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(number != 9 && number > tabs.count)
                }
            }
            .disabled(workspaceUnavailable || tabWorkspace == nil || browserPageCommandsAllowed != true || tabs.isEmpty)
        }
    }
}

@main
@MainActor
struct ComputaApp: App {
    @NSApplicationDelegateAdaptor(ComputaAppDelegate.self) private var appDelegate
    @State private var state: AppState
    #if !SWIFT_PACKAGE
    private let updates: ComputaUpdates?
    #endif
    private let launchMode: ComputaLaunchMode

    init() {
        let launchMode = ComputaLaunchMode.current
        self.launchMode = launchMode
        #if !SWIFT_PACKAGE
        updates = launchMode == .application && Bundle.main.bundleIdentifier == "com.ahmedelamin.LocalCodex"
            ? ComputaUpdates() : nil
        #endif
        let state = launchMode.makeState()
        _state = State(initialValue: state)
        appDelegate.state = state
    }

    var body: some Scene {
        WindowGroup("Kolmogor", id: "workspace", for: UUID.self) { $windowID in
            if launchMode == .testHost {
                Text("Kolmogor test host — application runtime disabled")
                    .padding()
                    .frame(minWidth: 480, minHeight: 120)
            } else {
                WorkspaceScene(state: state, id: windowID)
            }
        }
        .defaultSize(width: 1_280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            #if !SWIFT_PACKAGE
            CommandGroup(after: .appInfo) {
                if let updates { CheckForUpdatesButton(updates: updates) }
            }
            #endif
            WorkspaceCommands(state: state, isTestHost: launchMode == .testHost)

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    state.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(launchMode == .testHost || state.approvalGateBlocksInteraction)
            }
            #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
            CommandMenu("Model Diagnostics") {
                Toggle("Focus Next Synthetic Benchmark", isOn: Binding(
                    get: { state.browserSession.modelNativeFocusDiagnosticRequested },
                    set: { state.browserSession.setModelNativeFocusDiagnosticRequested($0) }
                ))
                .disabled(launchMode == .testHost || state.browserSession.modelNativeFocusDiagnosticTabID != nil)
                Button("Restore Model Focus") {
                    state.browserSession.cancelModelNativeFocusDiagnostic()
                }
                .disabled(launchMode == .testHost || state.browserSession.modelNativeFocusDiagnosticTabID == nil)
                Text("Focus diagnostic: \(state.browserSession.modelNativeFocusDiagnosticDisposition.rawValue)")
            }
            #endif
        }
    }
}

/// A nil scene value is the durable workspace. Explicit values are usable only
/// while their in-memory layouts exist; macOS cannot restore a discarded one.
private struct WorkspaceScene: View {
    let state: AppState
    let id: UUID?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var tabs: WorkspaceTabs? {
        guard let id else { return state.workspaceWindows.primary }
        return state.workspaceWindows.temporary.first { $0.id == id }
    }

    var body: some View {
        if let tabs {
            WebWorkspaceView(state: state, window: tabs)
                .preferredColorScheme(state.appearance.colorScheme)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    state.windowHosting.openScene = { openWindow(id: "workspace", value: $0) }
                    state.startRuntimeIfNeeded()
                }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

@MainActor
final class ComputaAppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    private var terminationStarted = false
    private var replied = false
    private var watchdog: Task<Void, Never>?
    // Keep the profile sessions registered until WebKit sees the UI process
    // close and flushes its cookies. This retains no pages and adds no delay.
    private var terminationBrowserProfiles: [WKWebsiteDataStore] = []

    func applicationDidBecomeActive(_ notification: Notification) {
        state?.recheckPendingCLIInstallations()
        if let state, state.workspaceWindows.all.contains(where: { $0.presentedSheet == .settings }) {
            state.refreshAutomationPermissions()
        }
    }

    func prepareBrowserProfilesForTermination() {
        terminationBrowserProfiles = state?.browserSession.persistentDataStoresForApplicationTermination ?? []
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        state?.prepareWorkspaceForQuit()
        prepareBrowserProfilesForTermination()

        watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            NSLog("Kolmogor cleanup deadline expired; normal termination is continuing.")
            finishTermination(sender)
        }
        Task { @MainActor in
            let report = await state?.shutdownRuntime()
            if let report, !report.succeeded {
                NSLog("Kolmogor shutdown incomplete: %@", report.issues.joined(separator: "; "))
            }
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ application: NSApplication) {
        guard !replied else { return }
        replied = true
        watchdog?.cancel()
        application.reply(toApplicationShouldTerminate: true)
    }
}

#if !SWIFT_PACKAGE
@MainActor
private final class ComputaUpdates: ObservableObject {
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheck = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }
}

private struct CheckForUpdatesButton: View {
    @ObservedObject var updates: ComputaUpdates

    var body: some View {
        Button("Check for Updates…", action: updates.controller.updater.checkForUpdates)
            .disabled(!updates.canCheck)
    }
}
#endif

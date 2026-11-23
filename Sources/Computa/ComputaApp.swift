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
                            browserSession: browser, workspaceLayout: .mixedTabs)
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
    @Entry var tabWorkspace: AppState?
}

private struct WorkspaceCommands: Commands {
    let state: AppState
    let isTestHost: Bool
    @FocusedValue(\.focusBrowserAddress) private var focusBrowserAddress
    @FocusedValue(\.tabWorkspace) private var tabWorkspace

    @FocusedValue(\.browserPaneFocused) private var browserPaneFocused

    private var usesBrowserShortcuts: Bool {
        !state.mixesBrowserTabsInSidebar && state.shouldPresentBrowserPane
            && (browserPaneFocused == true || state.selectedWorkspaceTab == nil)
    }

    private var workspaceUnavailable: Bool {
        isTestHost || state.approvalGateBlocksInteraction || state.presentedSheet != nil
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Agent") { state.createTask() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspaceUnavailable)
            Button("New Tab") { WorkspaceTabLauncher.request(in: NSApp.keyWindow) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(workspaceUnavailable)
        }
        CommandGroup(replacing: .saveItem) {
            if let tabWorkspace {
                Button("Close Tab") {
                    if let tab = tabWorkspace.commandTab(inBrowserPane: usesBrowserShortcuts) { tabWorkspace.closeWorkspaceTab(tab) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(workspaceUnavailable || tabWorkspace.commandTab(inBrowserPane: usesBrowserShortcuts) == nil)
            }
            Button("Close Window") {
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("w", modifiers: tabWorkspace == nil ? .command : [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
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
            .disabled(workspaceUnavailable || state.commandTabs(inBrowserPane: usesBrowserShortcuts).isEmpty)
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
        updates = launchMode == .application ? ComputaUpdates() : nil
        #endif
        let state = launchMode.makeState()
        _state = State(initialValue: state)
        appDelegate.state = state
    }

    var body: some Scene {
        WindowGroup {
            if launchMode == .testHost {
                Text("Kolmogor test host — application runtime disabled")
                    .padding()
                    .frame(minWidth: 480, minHeight: 120)
            } else {
                WebWorkspaceView(state: state)
                    .preferredColorScheme(state.appearance.colorScheme)
                    .frame(minWidth: 980, minHeight: 640)
                    .onAppear {
                        state.startRuntimeIfNeeded()
                    }
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
    }

    func prepareBrowserProfilesForTermination() {
        terminationBrowserProfiles = state?.browserSession.persistentDataStoresForApplicationTermination ?? []
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
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

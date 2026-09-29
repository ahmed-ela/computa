import AppKit
import AutomationCore
import SwiftUI

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
        runtimeFactory: () -> any AgentRuntimeClient = { CodexAppServerRuntime(configuration: .localQwen) },
        preferencesFactory: () -> UserDefaults = { .standard }
    ) -> AppState {
        switch self {
        case .application:
            let preferences = preferencesFactory()
            // The browser is owned by the UI only. Do not pass its profile or
            // WebViews to the agent runtime until that capability is qualified.
            let browser = EmbeddedBrowserSession(defaults: preferences)
            return AppState(tasks: [], runtime: runtimeFactory(), preferences: preferences,
                            browserSession: browser, enableChromeExtensionBridge: true)
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

@main
@MainActor
struct ComputaApp: App {
    @NSApplicationDelegateAdaptor(ComputaAppDelegate.self) private var appDelegate
    @State private var state: AppState
    private let launchMode: ComputaLaunchMode

    init() {
        let launchMode = ComputaLaunchMode.current
        self.launchMode = launchMode
        let state = launchMode.makeState()
        _state = State(initialValue: state)
        appDelegate.state = state
    }

    var body: some Scene {
        WindowGroup {
            if launchMode == .testHost {
                Text("Computa test host — application runtime disabled")
                    .padding()
                    .frame(minWidth: 480, minHeight: 120)
            } else {
                WebWorkspaceView(state: state)
                    .preferredColorScheme(state.appearance.colorScheme)
                    .frame(minWidth: 980, minHeight: 640)
                    .task {
                        await state.startRuntime()
                    }
            }
        }
        .defaultSize(width: 1_280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Task") {
                    state.createTask()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(launchMode == .testHost)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    state.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(launchMode == .testHost || state.approvalGateBlocksInteraction)
            }
        }
    }
}

@MainActor
final class ComputaAppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    private var terminationStarted = false
    private var replied = false
    private var watchdog: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true

        watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            NSLog("Computa cleanup deadline expired; normal termination is continuing.")
            finishTermination(sender)
        }
        Task { @MainActor in
            let report = await state?.shutdownRuntime()
            if let report, !report.succeeded {
                NSLog("Computa shutdown incomplete: %@", report.issues.joined(separator: "; "))
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

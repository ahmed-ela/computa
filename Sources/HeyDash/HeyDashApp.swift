import AppKit
import SwiftUI

@main
@MainActor
struct HeyDashApp: App {
    @NSApplicationDelegateAdaptor(HeyDashAppDelegate.self) private var appDelegate
    @State private var state: AppState

    init() {
        let runtime = CodexAppServerRuntime(configuration: .localQwen)
        let state = AppState(tasks: [], runtime: runtime)
        _state = State(initialValue: state)
        appDelegate.state = state
    }

    var body: some Scene {
        WindowGroup {
            WebWorkspaceView(state: state)
                .preferredColorScheme(state.appearance.colorScheme)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    await state.startRuntime()
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
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    state.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(state.approvalGateBlocksInteraction)
            }
        }
    }
}

@MainActor
final class HeyDashAppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    private var terminationStarted = false
    private var replied = false
    private var watchdog: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true

        watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            NSLog("HeyDash cleanup deadline expired; normal termination is continuing.")
            finishTermination(sender)
        }
        Task { @MainActor in
            let report = await state?.shutdownRuntime()
            if let report, !report.succeeded {
                NSLog("HeyDash shutdown incomplete: %@", report.issues.joined(separator: "; "))
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

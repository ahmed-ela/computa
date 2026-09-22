import SwiftUI

@main
@MainActor
struct LocalCodexApp: App {
    @State private var state: AppState

    init() {
        let runtime = CodexAppServerRuntime(configuration: .localQwen)
        _state = State(initialValue: AppState(tasks: [], runtime: runtime))
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
                    state.presentedSheet = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

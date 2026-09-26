import AppKit
import SwiftUI

/// This control is native-only: no JavaScript or model action grants browser
/// access, and Full access never confirms this alert on the user's behalf.
@MainActor
struct NativeChromeConnectionControl: View {
    @Bindable var state: AppState
    @State private var presentation: NativeChromeConnectionPresentation?

    var body: some View {
        Menu {
            if state.chromeDisconnecting {
                Text("Disconnecting from Chrome…")
            } else {
                switch state.chromeConnectionState {
                case .disconnected, .failed:
                    Button("Connect existing Chrome…", action: prepareConfirmation)
                        .disabled(!state.canConnectChrome)
                    if state.chromeConnectionRequiresIdleRuntime {
                        Text("Finish or stop running tasks before connecting.")
                    }
                case .connecting:
                    Text("Waiting for Chrome's connection approval…")
                    Button("Cancel connection") { state.disconnectChrome() }
                case .connected:
                    Text("Connected to your existing Chrome session")
                    if !state.remembersChromeConnection, let id = state.chromeConnectionID {
                        Button("Reconnect automatically…") { presentation = .remember(id) }
                            .disabled(!state.canRememberChromeConnection)
                    }
                    Button("Disconnect Chrome") { state.disconnectChrome() }
                }
            }
            if case .failed(let message) = state.chromeConnectionState {
                Divider()
                Button("Connection details…") { presentation = .unavailable(message) }
            }
            Divider()
            if state.remembersChromeConnection {
                Text("Reconnects automatically when HeyDash opens.")
                Button("Forget automatic connection") { state.forgetRememberedChromeConnection() }
            } else {
                Text("This connection lasts until HeyDash quits.")
            }
        } label: {
            Label(label, systemImage: "globe")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Only Connect is gated. Human revocation must remain reachable while
        // an Ask-mode action is awaiting approval or a connection is pending.
        .accessibilityLabel("Chrome connection")
        .accessibilityValue(label)
        .help("Explicitly connect or disconnect your existing Chrome session for background tab actions.")
        .alert(
            presentation?.title ?? "Chrome connection",
            isPresented: Binding(
                get: { presentation != nil },
                set: { if !$0 { presentation = nil } }
            ),
            presenting: presentation
        ) { item in
            switch item {
            case .confirm(let target):
                Button("Cancel", role: .cancel) { presentation = nil }
                Button("Connect once") {
                    presentation = nil
                    // Consent is created only by this explicit native action.
                    state.connectChrome(target.confirmedRequest())
                }
                .disabled(!state.canConnectChrome)
                Button("Connect & Remember") {
                    presentation = nil
                    state.connectChrome(target.confirmedRequest(), remember: true)
                }
                .disabled(!state.canConnectChrome)
            case .remember(let connectionID):
                Button("Cancel", role: .cancel) { presentation = nil }
                Button("Remember connection") {
                    presentation = nil
                    state.rememberChromeConnection(expectedID: connectionID)
                }
                .disabled(!state.canRememberChromeConnection || state.chromeConnectionID != connectionID)
            case .unavailable:
                Button("OK", role: .cancel) { presentation = nil }
            }
        } message: { item in
            Text(item.message)
        }
        .onChange(of: state.approvalGateBlocksInteraction) { _, blocked in
            if blocked { presentation = nil }
        }
        .onChange(of: state.canConnectChrome) { _, canConnect in
            if !canConnect, case .confirm? = presentation { presentation = nil }
        }
        .onChange(of: state.canRememberChromeConnection) { _, canRemember in
            if !canRemember, case .remember? = presentation { presentation = nil }
        }
        .onChange(of: state.presentedSheet) { _, sheet in
            if sheet != nil { presentation = nil }
        }
    }

    private var label: String {
        if state.chromeDisconnecting { return "Chrome disconnecting…" }
        switch state.chromeConnectionState {
        case .disconnected: return "Connect Chrome"
        case .connecting: return "Chrome connecting…"
        case .connected: return "Chrome connected"
        case .failed: return "Chrome unavailable"
        }
    }

    private func prepareConfirmation() {
        guard state.canConnectChrome else { return }
        do { presentation = .confirm(try NativeChromeConnectionTarget.prepare()) }
        catch { presentation = .unavailable(error.localizedDescription) }
    }
}

private enum NativeChromeConnectionPresentation {
    case confirm(NativeChromeConnectionTarget)
    case remember(UUID)
    case unavailable(String)

    var title: String {
        switch self {
        case .confirm: "Connect to your existing Chrome?"
        case .remember: "Remember this Chrome connection?"
        case .unavailable: "Chrome connection unavailable"
        }
    }

    var message: String {
        switch self {
        case .confirm:
            "HeyDash can read and interact with tabs in your signed-in Chrome session. Connecting does not navigate any tab. This background connection does not grant tab activation or closing.\n\nFrom Chrome's app-data directory, HeyDash reads only the connection file—not cookies or other profile files. macOS may separately request Chrome app-data access; Full Disk Access is not requested.\n\nConnect once lasts until HeyDash quits. Connect & Remember also authorizes reconnection to this same Chrome app and profile on future launches. Disconnect Chrome forgets that choice. Chrome must already be running; Chrome or macOS may still require approval. No debugging or permission setting is changed."
        case .remember:
            "Allow HeyDash to reconnect to this same Chrome app and profile whenever HeyDash opens? This gives future HeyDash sessions the same ability to read and interact with your signed-in tabs.\n\nHeyDash will resolve a fresh connection each time. It does not save a process, connection address, cookies or other profile contents, launch Chrome, or change Chrome/macOS permissions. Chrome may still ask for approval.\n\nDisconnect Chrome or Forget automatic connection removes this saved choice."
        case .unavailable(let message): message
        }
    }
}

/// Values gathered from NSWorkspace only. There is no launch, activation,
/// directory enumeration, alternate profile search, or connection-file read
/// before the native user confirms. The runtime validates the selected process,
/// executable, directory and live listener again at connection and each enqueue.
struct NativeChromeConnectionTarget: Sendable {
    let application: BorrowedChromeApplicationIdentity
    let userDataDirectory: URL

    @MainActor
    static func prepare() throws -> Self {
        try select(
            applications: NSWorkspace.shared.runningApplications.map {
                .init(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                      executableURL: $0.executableURL, isRegular: $0.activationPolicy == .regular,
                      isTerminated: $0.isTerminated)
            },
            userHomeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func select(
        applications: [NativeChromeRunningApplication], userHomeDirectory: URL
    ) throws -> Self {
        let matches = applications.filter {
            $0.bundleIdentifier == "com.google.Chrome" && $0.isRegular && !$0.isTerminated
        }
        guard !matches.isEmpty else { throw NativeChromeConnectionError.notRunning }
        guard matches.count == 1, let chrome = matches.first else {
            throw NativeChromeConnectionError.ambiguousApplication
        }
        guard chrome.processIdentifier > 0, let executable = chrome.executableURL,
              executable.isFileURL, executable.path.hasPrefix("/"),
              executable.lastPathComponent == "Google Chrome",
              userHomeDirectory.isFileURL, userHomeDirectory.path.hasPrefix("/"),
              userHomeDirectory.path != "/" else {
            throw NativeChromeConnectionError.invalidApplication
        }
        return Self(
            application: .init(processIdentifier: chrome.processIdentifier,
                               bundleIdentifier: "com.google.Chrome", executableURL: executable),
            userDataDirectory: userHomeDirectory
                .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        )
    }

    func confirmedRequest() -> ChromeConnectionRequest {
        .init(application: application, userDataDirectory: userDataDirectory,
              consent: ChromeDebuggingConsent(approvedByUser: true))
    }
}

struct NativeChromeRunningApplication: Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let executableURL: URL?
    let isRegular: Bool
    let isTerminated: Bool
}

enum NativeChromeConnectionError: LocalizedError {
    case notRunning
    case ambiguousApplication
    case invalidApplication

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Open your normal Google Chrome session first, then connect here. HeyDash does not launch a separate Chrome profile."
        case .ambiguousApplication:
            "More than one ordinary Google Chrome process is running. HeyDash cannot safely choose one. No connection was made."
        case .invalidApplication:
            "HeyDash could not identify the running Chrome executable or your default Chrome directory. No alternate profile will be searched."
        }
    }
}

import AppKit
import Foundation

/// The picker supplies a provider ID and an intent. Only native code chooses the executable and arguments.
enum ProviderCLISetup {
    enum Intent: String { case install, signIn }
    enum Failure: LocalizedError {
        case terminal, installer, cancelled, timedOut, command
        var errorDescription: String? {
            switch self {
            case .terminal: "Terminal could not open the provider setup."
            case .installer: "This installation is missing its provider setup tool."
            case .cancelled: "Setup was interrupted. Check the connection to continue."
            case .timedOut: "Setup is still unconfirmed. Finish in Terminal, then check the connection."
            case .command: "Setup did not finish. Terminal shows the provider’s message. You can retry in the model picker."
            }
        }
    }

    static func command(route: String, intent: Intent) async throws -> [String] {
        let provider = ProviderCLI.allCases.first { $0.route == route }
        guard provider != nil || route == InstalledCodexCLI.route else { throw Failure.installer }
        if intent == .install {
            #if SWIFT_PACKAGE
            let bundle = Bundle.module
            #else
            let bundle = Bundle.main
            #endif
            guard let installer = bundle.url(forResource: "install", withExtension: "sh", subdirectory: "ProviderSetup") else { throw Failure.installer }
            return ["/bin/sh", installer.path, provider?.rawValue ?? "codex"]
        }
        guard let provider else { return [try await InstalledCodexCLI.executable().path, "login"] }
        let name = provider == .claude ? "claude" : provider.executable
        guard let executable = ProviderCLI.locate(name) else { throw AgentCLIError.installationRequired("Install " + provider.name + " first.") }
        switch provider {
        case .claude, .opencode: return [executable.path, "auth", "login"]
        case .kimi: return [executable.path, "login"]
        case .qwen, .antigravity: return [executable.path]
        }
    }

    // A quoted word cannot turn a path from the user's home or an app bundle into a shell command.
    static func shellWord(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @MainActor static func run(route: String, intent: Intent) async throws {
        let arguments = try await command(route: route, intent: intent)
        try await runInTerminal(arguments: arguments)
    }

    @MainActor static func runInTerminal(arguments: [String]) async throws {
        try Task.checkCancellation()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw Failure.terminal }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("kolmogor-setup-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let script = directory.appendingPathComponent("Kolmogor Provider Setup.command")
        let result = directory.appendingPathComponent("result")
        let home = manager.homeDirectoryForCurrentUser
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let codexHome = configured.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home.appendingPathComponent(".codex").path
        let body = """
        #!/bin/sh
        umask 077
        export HOME=\(shellWord(home.path))
        export PATH=\(shellWord(ProviderCLI.directories(home: home).joined(separator: ":")))
        export CODEX_HOME=\(shellWord(codexHome))
        cd "$HOME" || exit 1
        \(arguments.map(shellWord).joined(separator: " "))
        status=$?
        printf '%s\\n' "$status" > \(shellWord(result.path + ".tmp")) && /bin/mv \(shellWord(result.path + ".tmp")) \(shellWord(result.path))
        exit "$status"
        """
        try Data(body.utf8).write(to: script, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init())
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let status = try? String(contentsOf: result, encoding: .utf8) {
                guard status == "0\n" else { throw Failure.command }
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure.timedOut
    }
}

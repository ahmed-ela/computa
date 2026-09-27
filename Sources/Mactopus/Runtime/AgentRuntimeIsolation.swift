import Foundation

/// App-owned process configuration, independent of the launching shell or Codex host.
/// This helper neither creates the private home nor edits or removes any policy.
enum AgentRuntimeIsolation {
    private static let inheritedKeys = [
        "TMPDIR", "LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES",
        "LC_MONETARY", "LC_NUMERIC", "LC_TIME",
    ]

    /// Use trusted, explicit home paths. Never derive either path from inherited HOME
    /// or CODEX_HOME. A caller may add its explicit local endpoint after sanitization.
    static func environment(
        inheriting inherited: [String: String],
        userHomePath: String,
        codexHomePath: String
    ) -> [String: String] {
        var result = [
            "HOME": userHomePath,
            "CODEX_HOME": codexHomePath,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for key in inheritedKeys {
            if let value = inherited[key] { result[key] = value }
        }
        return result
    }

    /// Keep app-owned instructions independent of ancestor project discovery.
    /// File-backed credentials stay in the explicitly supplied private CODEX_HOME.
    static let configurationArguments = [
        "-c", "project_root_markers=[]",
        "-c", "cli_auth_credentials_store=\"file\"",
        "-c", "mcp_oauth_credentials_store=\"file\"",
        "-c", "features.shell_snapshot=false",
        "-c", "features.shell_snapshot_v2=false",
        "-c", "allow_login_shell=false",
    ]

    /// A deterministic child of the private home, not the parent application's cwd.
    /// Directory creation belongs to the caller.
    static func workspaceURL(codexHomePath: String) -> URL {
        URL(fileURLWithPath: codexHomePath, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    /// HOME is scoped to the child process only. The native app and macOS user
    /// home are unchanged. This closes home-scoped skill discovery, which the
    /// engine can otherwise perform even with skills.include_instructions=false.
    static func processHomeURL(codexHomePath: String) -> URL {
        URL(fileURLWithPath: codexHomePath, isDirectory: true)
            .appendingPathComponent("ProcessHome", isDirectory: true)
    }
}

import Foundation

/// Agent Client Protocol over stdio. The publisher's CLI owns its login.
enum ProviderCLI: String, CaseIterable, Sendable, Codable {
    case antigravity, qwen, kimi, opencode, claude

    var name: String {
        switch self {
        case .antigravity: "Antigravity CLI"
        case .qwen: "Qwen Code"
        case .kimi: "Kimi Code"
        case .opencode: "OpenCode"
        case .claude: "Claude Code"
        }
    }

    var executable: String {
        switch self {
        case .antigravity: "agy"
        case .claude: "claude-agent-acp"
        default: rawValue
        }
    }

    var arguments: [String] {
        switch self {
        case .qwen: ["--acp"]
        case .claude: []
        default: ["acp"]
        }
    }

    var route: String { "cli/" + rawValue }
    var modelID: String { route + "/default" }

    init?(modelID: String) {
        let parts = modelID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "cli" else { return nil }
        guard (parts.count == 3 && parts[2] == "default") || (parts[2] == "model" && Self.slug(modelID) != nil) else { return nil }
        self.init(rawValue: String(parts[1]))
    }

    static func slug(_ id: String) -> String? {
        let parts = id.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "cli", parts[2] == "model", ProviderCLI(rawValue: String(parts[1])) != nil,
              !parts[3].isEmpty, parts[3].utf8.count <= 512, !parts[3].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return String(parts[3])
    }

    var option: LocalModelOption {
        LocalModelOption(id: modelID, label: name + " / CLI default",
                         detail: "Uses the model, account and tool permissions configured in " + name + ".", highMemory: false)
    }

    static var installed: [ProviderCLI] {
        allCases.filter { locate($0.executable) != nil && ($0 != .claude || locate("claude") != nil) }
    }

    static func directories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
         home.appendingPathComponent(".kimi-code/bin").path, "/usr/bin", "/bin"]
    }

    static func locate(_ executable: String, directories: [String] = directories()) -> URL? {
        directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(executable) }.first {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

/// Supports both ACP's current config controls and the earlier session model list.
struct AgentCLIModels {
    let configID: String?
    let entries: [(id: String, label: String)]

    init(session: [String: Any]) {
        let config = (session["configOptions"] as? [[String: Any]])?.first {
            $0["category"] as? String == "model" || $0["id"] as? String == "model"
        }
        func flatten(_ rows: [[String: Any]]) -> [(String, String)] {
            rows.flatMap { row -> [(String, String)] in
                if let group = row["options"] as? [[String: Any]] { return flatten(group) }
                guard let id = row["value"] as? String, !id.isEmpty else { return [] }
                return [(id, row["name"] as? String ?? id)]
            }
        }
        let modern = flatten(config?["options"] as? [[String: Any]] ?? [])
        if !modern.isEmpty, let id = config?["id"] as? String {
            configID = id
            entries = modern
        } else {
            configID = nil
            let legacy = session["models"] as? [String: Any]
            entries = (legacy?["availableModels"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["modelId"] as? String else { return nil }
                return (id, row["name"] as? String ?? id)
            }
        }
    }
}

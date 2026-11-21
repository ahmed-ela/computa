import Foundation

enum InstalledCodexCLI {
    static let route = "cli/codex"
    static let prefix = route + "/model/"

    enum Failure: LocalizedError {
        case missing, signedOut, invalidCatalog, unavailable, differentRuntime, busy
        var errorDescription: String? {
            switch self {
            case .missing: "Install Codex CLI, run codex login in Terminal, then check available models."
            case .signedOut: "Run codex login in Terminal, then check available models."
            case .invalidCatalog: "Codex CLI returned an unreadable model catalog. Update the CLI and check again."
            case .unavailable: "This model is unavailable in the current Codex CLI account. Check available models and select one."
            case .busy: "A message is already being submitted for this chat."
            case .differentRuntime: "Start a new chat to switch between Codex CLI and another provider."
            }
        }
    }

    static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin/codex").path,
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                     "/Applications/Codex.app/Contents/Resources/codex"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw Failure.missing }
        return URL(fileURLWithPath: path)
    }

    static func slug(_ id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let slug = String(id.dropFirst(prefix.count))
        guard !slug.isEmpty, slug.utf8.count <= 256, slug.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return slug
    }

    struct Page: Decodable {
        struct Model: Decodable {
            let model: String
            let displayName: String
            let description: String?
            let hidden: Bool
        }
        let data: [Model]
        let nextCursor: String?
    }

    static func models(isolation: isolated (any Actor)? = #isolation, page: (String?) async throws -> Page) async throws -> [LocalModelOption] {
        var cursor: String?
        var cursors = Set<String>()
        var seen = Set<String>()
        var options: [LocalModelOption] = []
        repeat {
            let result = try await page(cursor)
            for row in result.data where !row.hidden {
                let id = prefix + row.model
                guard slug(id) != nil, seen.insert(id).inserted else { continue }
                let label = row.displayName.isEmpty ? row.model : row.displayName
                options.append(LocalModelOption(id: id, label: "Codex CLI / " + label, detail: row.description ?? row.model, highMemory: false))
            }
            cursor = result.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw Failure.invalidCatalog }
        } while cursor != nil
        return options
    }

    static func unavailableTask(threadID: String, modelID: String, error: Error) -> AgentTask {
        AgentTask(id: threadID, runtimeThreadID: threadID, title: "Codex CLI chat",
                  summary: error.localizedDescription, status: .failed, updatedAt: .distantPast,
                  workspace: "", model: modelID,
                  entries: [TimelineEntry(kind: .system, title: "CLI history unavailable", body: error.localizedDescription)])
    }

    /// The installed CLI shares its login and history with Terminal. Only read
    /// threads that were created by Computa and recorded in its private index.
    struct Threads {
        let directory: URL
        init(home: String) {
            directory = URL(fileURLWithPath: home).appendingPathComponent("OwnedCLIThreads", isDirectory: true)
        }
        func save(threadID: String, modelID: String) throws {
            guard UUID(uuidString: threadID) != nil, InstalledCodexCLI.slug(modelID) != nil else { throw Failure.unavailable }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(modelID.utf8).write(to: directory.appendingPathComponent(threadID), options: .atomic)
        }
        func model(threadID: String) throws -> String? {
            guard UUID(uuidString: threadID) != nil else { return nil }
            do {
                let model = try String(contentsOf: directory.appendingPathComponent(threadID), encoding: .utf8)
                return InstalledCodexCLI.slug(model) == nil ? nil : model
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
        func entries() throws -> [String: String] {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
            var result: [String: String] = [:]
            for file in files where UUID(uuidString: file.lastPathComponent) != nil {
                result[file.lastPathComponent] = try model(threadID: file.lastPathComponent)
            }
            return result
        }
    }
}

import Darwin
import Foundation

/// Only quota data is passed to the composer; the RPC's account, plan, and credit details stay out of the web bridge.
enum CodexCLIUsage {
    struct Window: Codable, Equatable, Sendable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int?
    }

    struct Bucket: Codable, Equatable, Sendable {
        let id: String
        let label: String?
        let primary: Window?
        let secondary: Window?
    }

    struct Report: Sendable {
        var revision: UInt64 = 0
        var buckets: [Bucket]?
    }

    private struct WireBucket: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?

        func bucket(key: String? = nil) -> Bucket? {
            guard primary != nil || secondary != nil else { return nil }
            let id = key ?? limitId
            return Bucket(id: id.flatMap { $0.isEmpty ? nil : $0 } ?? "codex",
                          label: limitName, primary: primary, secondary: secondary)
        }
    }

    static func read(_ data: Data) throws -> [Bucket] {
        struct Result: Decodable {
            let rateLimits: WireBucket?
            let rateLimitsByLimitId: [String: WireBucket]?
        }
        struct Reply: Decodable { let result: Result }
        let result = try JSONDecoder().decode(Reply.self, from: data).result
        let buckets = result.rateLimitsByLimitId?.compactMap { key, value in value.bucket(key: key) } ?? []
        if !buckets.isEmpty { return buckets }
        return result.rateLimits?.bucket().map { [$0] } ?? []
    }

    static func notification(_ params: [String: Any]) -> Bucket? {
        struct Params: Decodable { let rateLimits: WireBucket }
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let message = try? JSONDecoder().decode(Params.self, from: data) else { return nil }
        return message.rateLimits.bucket()
    }

    /// Reads replace the account snapshot; notifications replace only their own bucket.
    /// A notification delivered during a read wins over the response for that bucket.
    struct Session {
        private(set) var report = Report()
        private(set) var readID: UUID?
        private var updatesDuringRead: [String: Bucket] = [:]

        mutating func beginRead() -> UUID {
            let id = UUID()
            readID = id
            updatesDuringRead.removeAll()
            return id
        }

        mutating func completeRead(_ id: UUID, buckets: [Bucket]?) -> Report {
            guard id == readID else { return report }
            var snapshot: [String: Bucket] = [:]
            for bucket in buckets ?? [] { snapshot[bucket.id] = bucket }
            snapshot.merge(updatesDuringRead) { _, newer in newer }
            readID = nil
            updatesDuringRead.removeAll()
            return publish(snapshot.isEmpty && buckets == nil ? nil : Array(snapshot.values))
        }

        mutating func apply(_ bucket: Bucket) -> Report {
            if readID != nil { updatesDuringRead[bucket.id] = bucket }
            return publish((report.buckets ?? []).filter { $0.id != bucket.id } + [bucket])
        }

        mutating func invalidate() -> Report {
            readID = nil
            updatesDuringRead.removeAll()
            return publish(nil)
        }

        private mutating func publish(_ buckets: [Bucket]?) -> Report {
            report = Report(revision: report.revision + 1, buckets: buckets?.sorted {
                if ($0.id == "codex") != ($1.id == "codex") { return $0.id == "codex" }
                return $0.id < $1.id
            })
            return report
        }
    }
}

enum InstalledCodexCLI {
    static let route = "cli/codex"
    static let prefix = route + "/model/"

    enum Failure: LocalizedError {
        case missing, incompatible, signedOut, invalidCatalog, unavailable, differentRuntime, busy
        var errorDescription: String? {
            switch self {
            case .missing: "Install Codex CLI, run codex login in Terminal, then check available models."
            case .incompatible: "No installed Codex CLI could provide Kolmogor’s app-server interface. Update Codex CLI and check available models."
            case .signedOut: "Run codex login in Terminal, then check available models."
            case .invalidCatalog: "Codex CLI returned an unreadable model catalog. Update the CLI and check again."
            case .unavailable: "This model is unavailable in the current Codex CLI account. Check available models and select one."
            case .busy: "A message is already being submitted for this chat."
            case .differentRuntime: "Start a new chat to switch between Codex CLI and another provider."
            }
        }
    }

    static let arguments = [
        "app-server", "--listen", "stdio://", "-c", "model_provider=\"openai\"",
        "-c", "project_root_markers=[]", "-c", "allow_login_shell=false",
        "-c", "mcp_servers={}", "-c", "features.hooks=false",
        "-c", "features.plugins=false", "-c", "features.apps=false",
    ]

    static var candidateURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".local/bin/codex").path,
                "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/Codex.app/Contents/Resources/codex"].map { URL(fileURLWithPath: $0) }
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
    /// threads that were created by Kolmogor and recorded in its private index.
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

extension InstalledCodexCLI {
    /// Probe in disposable homes. Only the selected server subsequently sees the user's CLI account.
    static func executable(candidates: [URL] = candidateURLs) async throws -> URL {
        var seen = Set<URL>()
        let paths = candidates.map { $0.resolvingSymlinksInPath() }.filter {
            seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0.path)
        }
        guard !paths.isEmpty else { throw Failure.missing }
        let best = await withTaskGroup(of: (Int, Version?).self) { group in
            for (index, path) in paths.enumerated() {
                group.addTask { (index, try? await probe(path)) }
            }
            var best: (index: Int, version: Version)?
            for await (index, version) in group {
                guard let version else { continue }
                if let best, best.version > version || (best.version == version && best.index < index) { continue }
                best = (index, version)
            }
            return best
        }
        try Task.checkCancellation()
        guard let best else { throw Failure.incompatible }
        return paths[best.index]
    }

    struct Version: Comparable {
        let core: [Int]
        let prerelease: [Substring]

        init?(_ text: Substring) {
            let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#
            guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
            let version = text.prefix { $0 != "+" }.split(separator: "-", maxSplits: 1)
            core = version[0].split(separator: ".").compactMap { Int($0) }
            prerelease = version.count == 2 ? version[1].split(separator: ".") : []
            guard core.count == 3, !prerelease.contains(where: {
                $0.count > 1 && $0.first == "0" && $0.allSatisfy(\.isNumber)
            }) else { return nil }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
            if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
            return lhs.prerelease.lexicographicallyPrecedes(rhs.prerelease) { a, b in
                let numeric = a.allSatisfy(\.isNumber), otherNumeric = b.allSatisfy(\.isNumber)
                if numeric != otherNumeric { return numeric }
                if numeric && a.count != b.count { return a.count < b.count }
                return a < b
            }
        }
    }

    private static func probe(_ path: URL) async throws -> Version {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaCLI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let input = Pipe(), output = Pipe()
        let reader = output.fileHandleForReading.fileDescriptor
        guard fcntl(reader, F_SETFL, O_NONBLOCK) == 0,
              fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.incompatible }
        let child = try OwnedChildProcess(executableURL: path, arguments: arguments + ["-c", "cli_auth_credentials_store=\"file\""],
            environment: AgentRuntimeIsolation.environment(inheriting: [:], userHomePath: home.path, codexHomePath: home.path),
            workingDirectory: home, inputDescriptor: input.fileHandleForReading.fileDescriptor,
            outputDescriptor: output.fileHandleForWriting.fileDescriptor)
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let version: Version
        do {
            version = try await probeProtocol(input.fileHandleForWriting, reader: reader)
        } catch {
            _ = await child.stop()
            throw error
        }
        guard await child.stop().succeeded else { throw Failure.incompatible }
        return version
    }

    private static func probeProtocol(_ writer: FileHandle, reader: Int32) async throws -> Version {
        let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"computa_probe","version":"1"},"capabilities":{"experimentalApi":true}}}"#
        try writer.write(contentsOf: Data((initialize + "\n").utf8))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var version: Version?, accountRead = false, modelsRead = false
        var buffer = Data(), total = 0
        var chunk = [UInt8](repeating: 0, count: 8192)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let count = Darwin.read(reader, &chunk, chunk.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            guard count > 0 else { throw Failure.incompatible }
            total += count
            guard total <= 256 * 1024 else { throw Failure.incompatible }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                guard let result = message["result"] as? [String: Any] else { throw Failure.incompatible }
                switch id {
                case 1:
                    guard version == nil, let agent = result["userAgent"] as? String,
                          let product = agent.split(separator: " ").first, let slash = product.firstIndex(of: "/"),
                          let reported = Version(product.suffix(from: product.index(after: slash))) else { throw Failure.incompatible }
                    version = reported
                    let requests = [
                        #"{"method":"initialized"}"#,
                        #"{"id":2,"method":"account/read","params":{}}"#,
                        #"{"id":3,"method":"model/list","params":{"limit":1,"includeHidden":false}}"#,
                    ]
                    try writer.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
                case 2:
                    accountRead = result["account"] is NSNull || result["account"] is [String: Any]
                case 3:
                    _ = try JSONDecoder().decode(Page.self, from: JSONSerialization.data(withJSONObject: result))
                    modelsRead = true
                default: break
                }
                if let version, accountRead, modelsRead { return version }
            }
        }
        throw Failure.incompatible
    }
}

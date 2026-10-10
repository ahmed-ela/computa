import CryptoKit
import Darwin
import Foundation

/// Git patches are retained here; the web view only supplies opaque selection IDs.
/// Every mutation checks the index, HEAD and dirty-file contents again before applying.
actor WorkspaceReviewService {
    private var snapshots: [String: RetainedReview] = [:]
    private var busy = false
    private let configurationEnvironment: [String: String]?
    private let commandConfiguration: ReviewCommandConfiguration

    /// Fixtures can supply private config files without changing user settings.
    /// Normal app calls inspect the user's effective Git configuration.
    init(configurationEnvironment: [String: String]? = nil,
         commandExecutableForTesting: URL? = nil, commandTimeoutForTesting: TimeInterval? = nil) {
        self.configurationEnvironment = configurationEnvironment
        commandConfiguration = ReviewCommandConfiguration(
            executable: commandExecutableForTesting ?? URL(fileURLWithPath: "/usr/bin/git"),
            timeout: commandTimeoutForTesting ?? 15
        )
    }

    func load(workspace: String, scope: FileReviewScope, reference: String? = nil,
              turnDiff: String? = nil, turnChanges: [AgentFileChange] = []) async throws -> FileReviewSnapshot {
        guard !busy else { throw FileReviewError.busy }
        busy = true
        defer { busy = false }
        let configurationEnvironment = configurationEnvironment
        let commandConfiguration = commandConfiguration
        let retained = try await Task.detached(priority: .userInitiated) {
            try ReviewGit.$commandConfiguration.withValue(commandConfiguration) {
                try ReviewGit.$configurationEnvironment.withValue(configurationEnvironment) {
                    try ReviewGit.load(workspace: workspace, scope: scope, reference: reference, turnDiff: turnDiff, turnChanges: turnChanges)
                }
            }
        }.value
        remember(retained)
        return retained.snapshot
    }

    func mutate(snapshotID: String, operation: FileReviewOperation, fileID: String? = nil,
                hunkID: String? = nil) async throws -> FileReviewSnapshot {
        guard !busy else { throw FileReviewError.busy }
        guard let retained = snapshots[snapshotID] else { throw FileReviewError.staleSnapshot }
        busy = true
        defer { busy = false }
        let configurationEnvironment = configurationEnvironment
        let commandConfiguration = commandConfiguration
        let updated = try await Task.detached(priority: .userInitiated) {
            try ReviewGit.$commandConfiguration.withValue(commandConfiguration) {
                try ReviewGit.$configurationEnvironment.withValue(configurationEnvironment) {
                    try ReviewGit.mutate(retained, operation: operation, fileID: fileID, hunkID: hunkID)
                }
            }
        }.value
        // A successful mutation consumes every older snapshot of this repository.
        snapshots = snapshots.filter { $0.value.snapshot.workspace != retained.snapshot.workspace }
        remember(updated)
        return updated.snapshot
    }

    func fileURL(snapshotID: String, fileID: String) throws -> URL {
        guard let review = snapshots[snapshotID],
              let file = review.snapshot.files.first(where: { $0.id == fileID }), !file.binary else {
            throw FileReviewError.invalidSelection
        }
        return try ReviewGit.containedURL(root: review.root, path: file.path, requireExisting: true)
    }

    private func remember(_ review: RetainedReview) {
        if snapshots.count >= 16 { snapshots.removeAll() }
        snapshots[review.snapshot.id] = review
    }
}

private struct RetainedReview: Sendable {
    let snapshot: FileReviewSnapshot
    let root: URL
    let patches: [String: RetainedPatch]
}

private struct RetainedPatch: Sendable {
    let data: Data
    let hunks: [String: Data]
}

private struct ReviewPath: Sendable {
    let path: String
    let previousPath: String?
    let status: String
}

private enum ReviewGit {
    @TaskLocal static var configurationEnvironment: [String: String]?
    @TaskLocal static var commandConfiguration = ReviewCommandConfiguration.production
    static let maximumFiles = 200
    static let maximumDisplayBytes = 1_048_576
    static let maximumSnapshotBytes = 4_194_304
    static let maximumCommandBytes = 16_777_216

    static func load(workspace: String, scope: FileReviewScope, reference: String?, turnDiff: String?,
                     turnChanges: [AgentFileChange] = []) throws -> RetainedReview {
        let root = URL(fileURLWithPath: workspace, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw FileReviewError.unavailable("Choose an existing workspace folder to review its files.")
        }
        if scope == .lastTurn {
            return try lastTurn(root: root, diff: turnDiff ?? "", changes: turnChanges)
        }
        let top = try git(root, ["rev-parse", "--show-toplevel"]).string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.path else {
            throw FileReviewError.unavailable("Choose the Git repository root to review its changes.")
        }
        let comparison = try comparisonArguments(root: root, scope: scope, reference: reference)
        for _ in 0..<2 {
            let revision = try fingerprint(root)
            let paths = try changedPaths(root: root, scope: scope, comparison: comparison.arguments)
            guard paths.count <= maximumFiles else {
                throw FileReviewError.unavailable("This review has more than \(maximumFiles) changed files. Narrow the changes before opening it.")
            }
            var files: [FileReviewFile] = []
            var patches: [String: RetainedPatch] = [:]
            var remainingDisplay = maximumSnapshotBytes
            for path in paths {
                let args: [String]
                if path.status == "untracked" {
                    args = ["diff", "--no-index", "--binary", "--no-ext-diff", "--no-textconv", "--", "/dev/null", path.path]
                } else {
                    args = ["diff", "--binary", "--no-ext-diff", "--no-textconv", "--find-renames"]
                        + comparison.arguments + ["--"] + [path.previousPath, path.path].compactMap { $0 }
                }
                let output = try git(root, args, allowedExitCodes: path.status == "untracked" ? [0, 1] : [0], allowTruncation: true)
                let id = digest(Data((scope.rawValue + "\u{0}" + (path.previousPath ?? "") + "\u{0}" + path.path).utf8))
                let budget = min(maximumDisplayBytes, remainingDisplay)
                let truncated = output.truncated || output.stdout.count > budget
                let data = output.stdout.prefix(max(0, budget))
                remainingDisplay -= data.count
                let parsed = parsePatch(output.stdout, fileID: id)
                let file = FileReviewFile(id: id, path: path.path, previousPath: path.previousPath, status: path.status,
                                          diff: String(decoding: data, as: UTF8.self), additions: parsed.additions,
                                          deletions: parsed.deletions, binary: parsed.binary, truncated: truncated,
                                          hunks: truncated ? [] : parsed.hunks)
                files.append(file)
                if !truncated, path.status != "unmerged", !output.stdout.isEmpty {
                    let hunkPatches = path.status == "modified" && !parsed.binary ? parsed.patches : [:]
                    patches[id] = RetainedPatch(data: output.stdout, hunks: hunkPatches)
                }
            }
            guard try fingerprint(root) == revision else { continue }
            let snapshot = FileReviewSnapshot(id: UUID().uuidString, workspace: root.path, scope: scope,
                                              reference: comparison.reference, revision: revision, files: files,
                                              canStage: scope == .unstaged, canUnstage: scope == .staged,
                                              canRevert: scope == .unstaged)
            return RetainedReview(snapshot: snapshot, root: root, patches: patches)
        }
        throw FileReviewError.staleSnapshot
    }

    static func mutate(_ review: RetainedReview, operation: FileReviewOperation, fileID: String?, hunkID: String?) throws -> RetainedReview {
        let supported = operation == .stage && review.snapshot.canStage
            || operation == .unstage && review.snapshot.canUnstage
            || operation == .revert && review.snapshot.canRevert
        guard supported, hunkID == nil || fileID != nil else { throw FileReviewError.unsupportedMutation }
        let selection = fileID.map { id in review.snapshot.files.filter { $0.id == id } } ?? review.snapshot.files
        guard !selection.isEmpty, fileID == nil || selection.count == 1 else { throw FileReviewError.invalidSelection }
        var payload = Data()
        for file in selection {
            guard let patch = review.patches[file.id], !file.truncated, file.status != "unmerged" else {
                throw FileReviewError.unsupportedMutation
            }
            if let hunkID {
                guard let hunk = patch.hunks[hunkID] else { throw FileReviewError.invalidSelection }
                payload.append(hunk)
            } else {
                payload.append(patch.data)
            }
        }
        guard !payload.isEmpty, payload.count <= maximumCommandBytes else { throw FileReviewError.unsupportedMutation }
        guard try fingerprint(review.root) == review.snapshot.revision else { throw FileReviewError.staleSnapshot }
        var args = ["apply", "--whitespace=nowarn"]
        if operation == .stage || operation == .unstage { args.append("--cached") }
        if operation == .unstage || operation == .revert { args.append("--reverse") }
        _ = try git(review.root, args + ["--check", "-"], input: payload)
        // Check again after Git's applicability check, before the actual write.
        guard try fingerprint(review.root) == review.snapshot.revision else { throw FileReviewError.staleSnapshot }
        _ = try git(review.root, args + ["-"], input: payload)
        return try load(workspace: review.root.path, scope: review.snapshot.scope, reference: review.snapshot.reference, turnDiff: nil)
    }

    static func containedURL(root: URL, path: String, requireExisting: Bool = false) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\u{0}"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == ".git" }) else {
            throw FileReviewError.invalidSelection
        }
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"), !requireExisting || FileManager.default.fileExists(atPath: url.path) else {
            throw FileReviewError.invalidSelection
        }
        return url
    }

    private static func comparisonArguments(root: URL, scope: FileReviewScope, reference: String?) throws -> (arguments: [String], reference: String?) {
        switch scope {
        case .unstaged: return ([], nil)
        case .staged: return (["--cached"], nil)
        case .branch:
            let ref = (reference ?? "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = try resolveCommit(root, ref)
            let base = try git(root, ["merge-base", "HEAD", commit]).string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validObjectID(base) else { throw FileReviewError.unavailable("That branch has no common base with HEAD.") }
            return ([base, "HEAD"], ref)
        case .commit:
            let ref = (reference ?? "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = try resolveCommit(root, ref)
            let parents = try git(root, ["rev-list", "--parents", "-n", "1", commit]).string.split(whereSeparator: \.isWhitespace)
            let parent = parents.count > 1 ? String(parents[1])
                : try git(root, ["hash-object", "-t", "tree", "--stdin"], input: Data()).string.trimmingCharacters(in: .whitespacesAndNewlines)
            return ([parent, commit], ref)
        case .lastTurn: return ([], nil)
        }
    }

    private static func resolveCommit(_ root: URL, _ reference: String) throws -> String {
        guard !reference.isEmpty, reference.utf8.count <= 512, !reference.contains("\u{0}") else {
            throw FileReviewError.unavailable("Enter a branch name or commit ID.")
        }
        let resolved = try git(root, ["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"])
            .string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validObjectID(resolved) else { throw FileReviewError.unavailable("The reference is not a commit.") }
        return resolved
    }

    private static func validObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func changedPaths(root: URL, scope: FileReviewScope, comparison: [String]) throws -> [ReviewPath] {
        let output = try git(root, ["diff", "--raw", "-z", "--no-abbrev", "--find-renames", "--no-ext-diff", "--no-textconv"] + comparison + ["--"]).stdout
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        var paths: [String: ReviewPath] = [:]
        var index = 0
        while index < fields.count, !fields[index].isEmpty {
            let header = String(decoding: fields[index], as: UTF8.self).split(separator: " ")
            guard header.count == 5, let code = header.last?.first, index + 1 < fields.count else {
                throw FileReviewError.unavailable("Git returned an unsupported change list.")
            }
            let firstPath = try utf8Path(Data(fields[index + 1]))
            index += 2
            let oldPath: String?
            let path: String
            if code == "R" || code == "C" {
                guard index < fields.count else { throw FileReviewError.invalidSelection }
                oldPath = firstPath
                path = try utf8Path(Data(fields[index]))
                index += 1
            } else { oldPath = nil; path = firstPath }
            let status: String
            switch code {
            case "A": status = "added"
            case "D": status = "deleted"
            case "R": status = "renamed"
            case "C": status = "copied"
            case "T": status = "typeChanged"
            case "U": status = "unmerged"
            default: status = "modified"
            }
            if paths[path]?.status != "unmerged" { paths[path] = ReviewPath(path: path, previousPath: oldPath, status: status) }
        }
        if scope == .unstaged {
            let untracked = try git(root, ["ls-files", "--others", "--exclude-standard", "-z"]).stdout
            for bytes in untracked.split(separator: 0) {
                let path = try utf8Path(Data(bytes))
                paths[path] = ReviewPath(path: path, previousPath: nil, status: "untracked")
            }
        }
        for path in paths.values {
            // Symlinks may appear in a diff, but neither review actions nor Open may escape the workspace.
            _ = try containedURL(root: root, path: path.path)
            if let old = path.previousPath { _ = try containedURL(root: root, path: old) }
        }
        return paths.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func utf8Path(_ data: Data) throws -> String {
        guard let path = String(data: data, encoding: .utf8), !path.isEmpty else {
            throw FileReviewError.unavailable("A changed filename cannot be displayed as UTF-8.")
        }
        return path
    }

    private static func fingerprint(_ root: URL) throws -> String {
        var hasher = SHA256()
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { throw FileReviewError.staleSnapshot }
        hasher.update(data: Data("root:\(rootInfo.st_dev):\(rootInfo.st_ino)".utf8))
        let gitDirectory = try git(root, ["rev-parse", "--absolute-git-dir"]).string.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitURL = URL(fileURLWithPath: gitDirectory, isDirectory: true).resolvingSymlinksInPath()
        var gitInfo = stat()
        guard lstat(gitURL.path, &gitInfo) == 0 else { throw FileReviewError.staleSnapshot }
        hasher.update(data: Data("git:\(gitURL.path):\(gitInfo.st_dev):\(gitInfo.st_ino)".utf8))
        let head = try git(root, ["rev-parse", "--verify", "HEAD"], allowedExitCodes: [0, 128]).stdout
        let index = try git(root, ["ls-files", "--stage", "-z"]).stdout
        let status = try git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).stdout
        hasher.update(data: head)
        hasher.update(data: index)
        hasher.update(data: status)
        let indexPath = try git(root, ["rev-parse", "--git-path", "index"]).string.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexURL = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        if let indexAttributes = try? FileManager.default.attributesOfItem(atPath: indexURL.path),
           let size = indexAttributes[.size] as? NSNumber {
            guard size.intValue <= 134_217_728 else { throw FileReviewError.unavailable("The Git index exceeds the review size limit.") }
            hasher.update(data: try Data(contentsOf: indexURL, options: .mappedIfSafe))
        } else {
            hasher.update(data: Data("no-index".utf8))
        }
        let fields = status.split(separator: 0, omittingEmptySubsequences: false)
        var offset = 0
        var budget = 536_870_912
        while offset < fields.count, !fields[offset].isEmpty {
            let field = Data(fields[offset])
            guard field.count >= 4 else { throw FileReviewError.unavailable("Git returned an unsupported working-tree status.") }
            let path = try utf8Path(field.dropFirst(3))
            try hashFile(root: root, path: path, hasher: &hasher, budget: &budget)
            let codes = Array(field.prefix(2))
            offset += 1
            if codes.contains(82) || codes.contains(67) {
                guard offset < fields.count else { throw FileReviewError.invalidSelection }
                let oldPath = try utf8Path(Data(fields[offset]))
                try hashFile(root: root, path: oldPath, hasher: &hasher, budget: &budget)
                offset += 1
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashFile(root: URL, path: String, hasher: inout SHA256, budget: inout Int) throws {
        // Read symlink text itself. Following it would read a different file than Git stages.
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              !path.split(separator: "/").contains(".git") else { throw FileReviewError.invalidSelection }
        let raw = root.appendingPathComponent(path).standardizedFileURL
        hasher.update(data: Data(path.utf8))
        var info = stat()
        guard lstat(raw.path, &info) == 0 else { hasher.update(data: Data("missing".utf8)); return }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: raw.path)
            hasher.update(data: Data(("symlink:" + destination).utf8))
            return
        }
        _ = try containedURL(root: root, path: path)
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            hasher.update(data: Data("nonregular:\(info.st_mode)".utf8)); return
        }
        guard info.st_size <= 134_217_728, info.st_size <= budget else {
            throw FileReviewError.unavailable("Changed files exceed the review size limit.")
        }
        hasher.update(data: Data("file:\(info.st_mode):\(info.st_size)".utf8))
        let handle = try FileHandle(forReadingFrom: raw)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            budget -= chunk.count
            guard budget >= 0 else { throw FileReviewError.unavailable("Changed files exceed the review size limit.") }
            hasher.update(data: chunk)
        }
    }

    private struct ParsedPatch {
        var additions = 0
        var deletions = 0
        var binary = false
        var hunks: [FileReviewHunk] = []
        var patches: [String: Data] = [:]
    }

    private static func parsePatch(_ data: Data, fileID: String) -> ParsedPatch {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result = ParsedPatch()
        result.binary = lines.contains { $0 == "GIT binary patch" || $0.hasPrefix("Binary files ") }
        let starts = lines.indices.filter { lines[$0].hasPrefix("@@ -") && !lines[$0].hasPrefix("@@@") }
        guard let first = starts.first else { return result }
        let prefix = lines[..<first].joined(separator: "\n") + "\n"
        for (ordinal, start) in starts.enumerated() {
            let end = ordinal + 1 < starts.count ? starts[ordinal + 1] : lines.count
            let body = lines[start..<end].joined(separator: "\n")
            let header = lines[start]
            let parts = header.split(separator: " ")
            guard parts.count >= 4,
                  let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
                  let new = Int(parts[2].dropFirst().split(separator: ",")[0]) else { continue }
            let id = digest(Data((fileID + "\u{0}\(ordinal)\u{0}" + body).utf8))
            result.hunks.append(FileReviewHunk(id: id, header: header, oldStart: old, newStart: new))
            result.patches[id] = Data((prefix + body + (body.hasSuffix("\n") ? "" : "\n")).utf8)
            for line in lines[(start + 1)..<end] {
                if line.hasPrefix("+") { result.additions += 1 }
                if line.hasPrefix("-") { result.deletions += 1 }
            }
        }
        return result
    }

    private static func lastTurn(root: URL, diff: String, changes: [AgentFileChange]) throws -> RetainedReview {
        guard diff.utf8.count <= maximumSnapshotBytes else {
            throw FileReviewError.unavailable("The last-turn diff exceeds the review size limit.")
        }
        let lines = diff.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].hasPrefix("diff --git ") }
        var files: [FileReviewFile] = []
        for (ordinal, start) in starts.enumerated() {
            let end = ordinal + 1 < starts.count ? starts[ordinal + 1] : lines.count
            let fileLines = Array(lines[start..<end])
            let patch = fileLines.joined(separator: "\n") + (end < lines.count ? "\n" : "")
            let old: String?
            let new: String?
            if let oldLine = fileLines.first(where: { $0.hasPrefix("--- ") }),
               let newLine = fileLines.first(where: { $0.hasPrefix("+++ ") }) {
                let oldSource = String(oldLine.dropFirst(4)), newSource = String(newLine.dropFirst(4))
                old = decodePatchPath(oldSource)
                new = decodePatchPath(newSource)
                guard old != nil || oldSource == "/dev/null", new != nil || newSource == "/dev/null" else {
                    throw FileReviewError.invalidSelection
                }
            } else if let from = fileLines.first(where: { $0.hasPrefix("rename from ") }),
                      let to = fileLines.first(where: { $0.hasPrefix("rename to ") }) {
                old = decodeGitPath(String(from.dropFirst(12)))
                new = decodeGitPath(String(to.dropFirst(10)))
            } else if let pair = try decodeDiffHeaderPaths(String(fileLines[0].dropFirst(11))) {
                old = fileLines.contains(where: { $0.hasPrefix("new file mode ") }) ? nil : pair.0
                new = fileLines.contains(where: { $0.hasPrefix("deleted file mode ") }) ? nil : pair.1
            } else {
                throw FileReviewError.unavailable("The last-turn diff contains an unsupported or ambiguous filename header.")
            }
            guard let path = new ?? old else { continue }
            _ = try containedURL(root: root, path: path)
            let previous = old != nil && new != nil && old != new ? old : nil
            if let previous { _ = try containedURL(root: root, path: previous) }
            let id = digest(Data(("lastTurn\u{0}\(ordinal)\u{0}" + path).utf8))
            let parsed = parsePatch(Data(patch.utf8), fileID: id)
            let truncated = patch.utf8.count > maximumDisplayBytes
            files.append(FileReviewFile(id: id, path: path, previousPath: previous,
                                        status: old == nil ? "added" : new == nil ? "deleted" : previous != nil ? "renamed" : "modified",
                                        diff: String(decoding: Data(patch.utf8).prefix(maximumDisplayBytes), as: UTF8.self),
                                        additions: parsed.additions, deletions: parsed.deletions, binary: parsed.binary,
                                        truncated: truncated, hunks: truncated ? [] : parsed.hunks))
        }
        // The caller supplies only successful completed native fileChange receipts
        // from this turn. A pure move has no content patch, so keep just that
        // recorded operation when the engine's aggregate omitted it.
        guard changes.count <= 2_000 else { throw FileReviewError.unavailable("The last-turn file-change receipt has too many entries.") }
        let aggregateFiles = files
        var recordedMoves = Set<String>()
        var metadataRevision = Data()
        var displayBytes = files.reduce(0) { $0 + $1.diff.utf8.count }
        for change in changes where change.kind == "update" && change.diff.isEmpty && change.movePath != nil {
            let from = try relativeRecordedPath(root: root, source: change.path)
            let to = try relativeRecordedPath(root: root, source: change.movePath!)
            guard from != to else { continue }
            guard !aggregateFiles.contains(where: {
                $0.path == from || $0.path == to || $0.previousPath == from || $0.previousPath == to
            }) else { continue }
            // Each completed move is a recorded operation. A later move may use
            // an earlier destination, including moving back to the original path.
            guard recordedMoves.insert(from + "\u{0}" + to).inserted else { continue }
            let id = digest(Data(("lastTurn\u{0}recordedMove\u{0}" + from + "\u{0}" + to).utf8))
            let metadata = "rename from \(quoteGitPath(from))\nrename to \(quoteGitPath(to))\n"
            guard files.count < maximumFiles, metadata.utf8.count <= maximumSnapshotBytes - displayBytes else {
                throw FileReviewError.unavailable("The last-turn diff exceeds the review size limit.")
            }
            displayBytes += metadata.utf8.count
            files.append(FileReviewFile(id: id, path: to, previousPath: from, status: "renamed", diff: metadata,
                                        additions: 0, deletions: 0, binary: false, truncated: false, hunks: []))
            metadataRevision.append(Data("\u{0}\(from.utf8.count):\(from)\u{0}\(to.utf8.count):\(to)".utf8))
        }
        guard files.count <= maximumFiles else { throw FileReviewError.unavailable("The last-turn diff has too many changed files.") }
        var revision = Data(diff.utf8)
        revision.append(metadataRevision)
        let snapshot = FileReviewSnapshot(id: UUID().uuidString, workspace: root.path, scope: .lastTurn,
                                          reference: nil, revision: digest(revision), files: files,
                                          canStage: false, canUnstage: false, canRevert: false)
        return RetainedReview(snapshot: snapshot, root: root, patches: [:])
    }

    private static func relativeRecordedPath(root: URL, source: String) throws -> String {
        guard !source.isEmpty, source.utf8.count <= 16_384, !source.contains("\u{0}"),
              !source.split(separator: "/").contains(".."), !source.split(separator: "/").contains(".git") else {
            throw FileReviewError.invalidSelection
        }
        let path: String
        if source.hasPrefix("/") {
            let url = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/") else { throw FileReviewError.invalidSelection }
            path = String(url.path.dropFirst(root.path.count + 1))
        } else {
            let url = try containedURL(root: root, path: source)
            path = String(url.path.dropFirst(root.path.count + 1))
        }
        _ = try containedURL(root: root, path: path)
        return path
    }

    private static func quoteGitPath(_ path: String) -> String {
        var quoted = "\""
        for byte in path.utf8 {
            switch byte {
            case 34: quoted += "\\\""
            case 92: quoted += "\\\\"
            case 9: quoted += "\\t"
            case 10: quoted += "\\n"
            case 13: quoted += "\\r"
            case 32...126: quoted += String(UnicodeScalar(byte))
            default: quoted += String(format: "\\%03o", byte)
            }
        }
        return quoted + "\""
    }

    /// Decode Git's C-quoted path form without treating patch text as a command.
    private static func decodePatchPath(_ source: String) -> String? {
        let source = source.hasSuffix("\t") ? String(source.dropLast()) : source
        if source == "/dev/null" { return nil }
        guard let decoded = decodeGitPath(source), decoded.hasPrefix("a/") || decoded.hasPrefix("b/") else { return nil }
        return String(decoded.dropFirst(2))
    }

    private static func decodeDiffHeaderPaths(_ source: String) throws -> (String, String)? {
        // The literal unquoted header is ambiguous when filenames contain spaces.
        // Only accept the equal-path form here; renames have explicit metadata.
        if source.hasPrefix("\"") {
            let bytes = Array(source.utf8)
            var index = 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    guard index + 2 < bytes.count, bytes[index + 1] == 32,
                          let a = decodePatchPath(String(decoding: bytes[...index], as: UTF8.self)),
                          let b = decodePatchPath(String(decoding: bytes[(index + 2)...], as: UTF8.self)) else { return nil }
                    return (a, b)
                }
                index += 1
            }
            return nil
        }
        var pairs: [(String, String)] = []
        for delimiter in [" b/", " \"b/"] {
            var search = source.startIndex..<source.endIndex
            while let separator = source.range(of: delimiter, range: search) {
                let a = decodePatchPath(String(source[..<separator.lowerBound]))
                let bPrefix = delimiter.contains("\"") ? "\"b/" : "b/"
                let b = decodePatchPath(bPrefix + String(source[separator.upperBound...]))
                if let a, let b { pairs.append((a, b)) }
                search = separator.upperBound..<source.endIndex
            }
        }
        if pairs.count == 1 { return pairs[0] }
        let equal = pairs.filter { $0.0 == $0.1 }
        if equal.count == 1 { return equal[0] }
        if pairs.count > 1 { throw FileReviewError.unavailable("The last-turn diff contains an ambiguous filename header.") }
        return nil
    }

    private static func decodeGitPath(_ source: String) -> String? {
        var bytes = Array(source.utf8)
        if bytes.first == 34, bytes.last == 34 {
            bytes = Array(bytes.dropFirst().dropLast())
            var decoded: [UInt8] = []
            var index = 0
            while index < bytes.count {
                if bytes[index] != 92 { decoded.append(bytes[index]); index += 1; continue }
                index += 1
                guard index < bytes.count else { return nil }
                let escaped = bytes[index]
                if (48...55).contains(escaped) {
                    var value = Int(escaped - 48)
                    var digits = 1
                    while digits < 3, index + 1 < bytes.count, (48...55).contains(bytes[index + 1]) {
                        index += 1; digits += 1; value = value * 8 + Int(bytes[index] - 48)
                    }
                    guard value <= 255 else { return nil }
                    decoded.append(UInt8(value))
                } else {
                    switch escaped {
                    case 116: decoded.append(9)
                    case 110: decoded.append(10)
                    case 114: decoded.append(13)
                    case 97: decoded.append(7)
                    case 98: decoded.append(8)
                    case 102: decoded.append(12)
                    case 118: decoded.append(11)
                    case 34, 92: decoded.append(escaped)
                    default: return nil
                    }
                }
                index += 1
            }
            bytes = decoded
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func git(_ root: URL, _ arguments: [String], input: Data? = nil,
                            allowedExitCodes: Set<Int32> = [0], allowTruncation: Bool = false) throws -> ReviewCommandResult {
        if let command = arguments.first, ["status", "diff", "apply"].contains(command) {
            try requireNoContentFilters(root)
        }
        let result = try ReviewGitCommand.run(root: root, arguments: arguments, input: input, limit: maximumCommandBytes,
                                              configuration: commandConfiguration)
        guard allowedExitCodes.contains(result.status) else {
            let error = String(decoding: result.stderr.prefix(2_048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileReviewError.commandFailed(error.isEmpty ? "Git could not complete that review operation." : error)
        }
        guard allowTruncation || !result.truncated else {
            throw FileReviewError.unavailable("Git output exceeds the review size limit.")
        }
        return result
    }

    private static func requireNoContentFilters(_ root: URL) throws {
        // --no-ext-diff/--no-textconv do not suppress clean/process conversion.
        // Inspect effective key names without reading worktree contents or
        // launching a filter. Disabling conversion would miscompare transformed
        // index blobs, so these repositories are explicitly unsupported here.
        let configuration = try ReviewGitCommand.run(root: root,
            arguments: ["config", "--null", "--name-only", "--list"], input: nil, limit: maximumCommandBytes,
            inspectConfiguration: true, configurationEnvironment: configurationEnvironment,
            configuration: commandConfiguration)
        guard configuration.status == 0, !configuration.truncated else {
            throw FileReviewError.unavailable("The repository's Git filter configuration could not be verified.")
        }
        let prefix = Array("filter.".utf8)
        let endings = [Array(".clean".utf8), Array(".process".utf8)]
        for key in configuration.stdout.split(separator: 0) {
            let lower = key.map { (65...90).contains($0) ? $0 + 32 : $0 }
            if lower.starts(with: prefix), endings.contains(where: { lower.suffix($0.count).elementsEqual($0) }) {
                throw FileReviewError.unavailable("Computa's file review cannot run this repository's configured Git clean or process filters. Use your configured Git client for this repository.")
            }
        }
    }
}

private struct ReviewCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
    let truncated: Bool
    var string: String { String(decoding: stdout, as: UTF8.self) }
}

private struct ReviewCommandConfiguration: Sendable {
    let executable: URL
    let timeout: TimeInterval
    static let production = Self(executable: URL(fileURLWithPath: "/usr/bin/git"), timeout: 15)
}

private struct ReviewOutputBuffer {
    private var data = Data()
    private var exceeded = false
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    mutating func append(_ chunk: Data) {
        let remaining = max(0, limit - data.count)
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining { exceeded = true }
    }
    func result() -> (Data, Bool) { (data, exceeded) }
}

private enum ReviewGitCommand {
    static func run(root: URL, arguments: [String], input: Data?, limit: Int,
                    inspectConfiguration: Bool = false, configurationEnvironment: [String: String]? = nil,
                    configuration: ReviewCommandConfiguration = .production) throws -> ReviewCommandResult {
        // Fixtures may shorten the deadline, but cannot relax production's 15s bound.
        guard configuration.timeout.isFinite, configuration.timeout > 0, configuration.timeout <= 15 else {
            throw FileReviewError.commandFailed("Invalid Git review deadline.")
        }
        let commandArguments = ["-c", "core.quotePath=true", "-c", "core.pager=cat", "-c", "diff.external=",
                                "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        if inspectConfiguration {
            // Config-only reads execute no filters. Include real global/system
            // keys so isolated commands cannot silently miscompare transformed
            // index contents whose driver lives outside repository config.
            for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("GIT_CONFIG") {
                environment[key] = value
            }
            if let configurationEnvironment {
                environment.merge(configurationEnvironment) { _, value in value }
            }
        } else {
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        let handles = [stdout.fileHandleForReading, stdout.fileHandleForWriting,
                       stderr.fileHandleForReading, stderr.fileHandleForWriting,
                       stdin.fileHandleForReading, stdin.fileHandleForWriting]
        defer { for handle in handles { try? handle.close() } }
        let outputFD = stdout.fileHandleForReading.fileDescriptor
        let errorFD = stderr.fileHandleForReading.fileDescriptor
        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        for descriptor in [outputFD, errorFD, inputFD] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        // Only this pipe's writer suppresses SIGPIPE; no host signal disposition changes.
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(configuration.timeout))
        let pid = try OwnedChildProcess.spawn(
            executableURL: configuration.executable, arguments: commandArguments, environment: environment,
            inputDescriptor: input == nil ? nil : stdin.fileHandleForReading.fileDescriptor,
            outputDescriptor: stdout.fileHandleForWriting.fileDescriptor,
            errorDescriptor: stderr.fileHandleForWriting.fileDescriptor
        )
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        var output = ReviewOutputBuffer(limit: limit), errors = ReviewOutputBuffer(limit: 16_384)
        var outputOpen = true, errorOpen = true, inputOpen = !(input?.isEmpty ?? true)
        if !inputOpen { try? stdin.fileHandleForWriting.close() }
        var inputOffset = 0, inputRejected = false, terminal = false
        var failure: Error?
        var bytes = [UInt8](repeating: 0, count: 65_536)
        do {
            while true {
                guard clock.now < deadline else {
                    throw FileReviewError.commandFailed(terminal && (outputOpen || errorOpen)
                        ? "Git review timed out while draining inherited pipes."
                        : "Git review timed out or was interrupted.")
                }
                if !terminal {
                    var information = siginfo_t()
                    let observed = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                    if observed == -1 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    terminal = information.si_pid == pid
                }
                if terminal && !outputOpen && !errorOpen && !inputOpen { break }
                var descriptors = [pollfd]()
                if outputOpen { descriptors.append(pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)) }
                if errorOpen { descriptors.append(pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)) }
                if inputOpen { descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)) }
                let polled = descriptors.withUnsafeMutableBufferPointer {
                    poll($0.baseAddress, nfds_t($0.count), 20)
                }
                if polled == -1 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                for descriptor in descriptors where descriptor.revents != 0 {
                    guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw POSIXError(.EBADF) }
                    if descriptor.fd == inputFD, inputOpen, let input {
                        let count = input.withUnsafeBytes {
                            Darwin.write(inputFD, $0.baseAddress!.advanced(by: inputOffset), min(65_536, input.count - inputOffset))
                        }
                        if count > 0 { inputOffset += count }
                        else if count == -1 && errno == EPIPE { inputRejected = true }
                        else if count == -1 && errno != EINTR && errno != EAGAIN {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        if inputOffset == input.count || inputRejected {
                            try? stdin.fileHandleForWriting.close()
                            inputOpen = false
                        }
                    } else {
                        // At most one chunk per ready stream keeps floods from starving the deadline.
                        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress!, $0.count) }
                        if count > 0 {
                            let chunk = Data(bytes.prefix(count))
                            if descriptor.fd == outputFD { output.append(chunk) }
                            else { errors.append(chunk) }
                        } else if count == 0 {
                            if descriptor.fd == outputFD {
                                try? stdout.fileHandleForReading.close(); outputOpen = false
                            } else { try? stderr.fileHandleForReading.close(); errorOpen = false }
                        } else if errno != EINTR && errno != EAGAIN {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    }
                }
            }
        } catch { failure = error }
        // No blocking readers/writer exist. Close our ends before bounded owned-group cleanup.
        for handle in handles { try? handle.close() }
        let cleanup = finishOwnedGroup(pid: pid, clock: clock)
        guard cleanup.issues.isEmpty, let status = cleanup.status else {
            throw FileReviewError.commandFailed("Git review cleanup could not be verified. " + cleanup.issues.joined(separator: " "))
        }
        if let failure { throw failure }
        guard (status & 0x7f) == 0 else { throw FileReviewError.commandFailed("Git review was interrupted.") }
        let exitCode = (status >> 8) & 0xff
        guard !inputRejected || exitCode != 0 else { throw FileReviewError.commandFailed("Git did not consume the review input.") }
        let (out, truncated) = output.result()
        let (err, _) = errors.result()
        return ReviewCommandResult(stdout: out, stderr: err, status: exitCode, truncated: truncated)
    }

    private static func finishOwnedGroup(pid: Int32, clock: ContinuousClock) -> (status: Int32?, issues: [String]) {
        guard pid > 1 else { return (nil, ["Refused an invalid owned child ID."]) }
        let deadline = clock.now.advanced(by: .seconds(2))
        // Verify the exclusively spawned root is still our unreaped child before
        // the final nonzero signal. Never signal a discovered or already-reaped PID.
        while true {
            var information = siginfo_t()
            if waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0 {
                guard information.si_pid == 0 || information.si_pid == pid else {
                    return (nil, ["Owned child observation returned an unexpected ID."])
                }
                break
            }
            let errorNumber = errno
            guard errorNumber == EINTR, clock.now < deadline else {
                return (nil, ["Owned child observation failed: errno=\(errorNumber)."])
            }
        }
        let signalled = Darwin.kill(-pid, SIGKILL)
        let signalError = signalled == -1 ? errno : 0
        var status: Int32?, groupGone = false, issues = [String]()
        repeat {
            if status == nil {
                var observedStatus: Int32 = 0
                let waited = waitpid(pid, &observedStatus, WNOHANG)
                if waited == pid, (observedStatus & 0x7f) != 0x7f { status = observedStatus }
                else if waited == -1, errno != EINTR {
                    issues.append("Owned child reap failed: errno=\(errno).")
                    break
                } else if waited != 0 && waited != -1 && waited != pid {
                    issues.append("Owned child wait returned an unexpected ID.")
                    break
                }
            }
            // After reaping, only absence probes are permitted. EPERM is not absence.
            let probe = Darwin.kill(-pid, 0)
            groupGone = probe == -1 && errno == ESRCH
            if status != nil && groupGone { break }
            _ = poll(nil, 0, 10)
        } while clock.now < deadline
        if status == nil { issues.append("Owned child did not finish within cleanup deadline.") }
        if !groupGone { issues.append("Owned process group absence was not verified.") }
        // A zombie-only group's EPERM is resolved only by successful reap + fresh ESRCH.
        if signalError != 0 && signalError != ESRCH && (signalError != EPERM || status == nil || !groupGone) {
            issues.append("Owned group signal failed: errno=\(signalError).")
        }
        return (status, issues)
    }
}

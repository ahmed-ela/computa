import CryptoKit
import Foundation

enum AppServerFileChangeContract {
    static let maximumDiffBytes = 2 * 1_024 * 1_024

    static func changes(_ value: Any?) -> [AgentFileChange]? {
        guard let values = value as? [[String: Any]], values.count <= 256 else { return nil }
        var paths = Set<String>()
        var bytes = 0
        var result = [AgentFileChange]()
        for value in values {
            guard let path = value["path"] as? String, !path.isEmpty, path.utf8.count <= 16_384,
                  !path.contains("\0"), paths.insert(path).inserted,
                  let kindObject = value["kind"] as? [String: Any],
                  let kind = kindObject["type"] as? String, ["add", "delete", "update"].contains(kind),
                  let diff = value["diff"] as? String, diff.utf8.count <= maximumDiffBytes else { return nil }
            let movePath: String?
            // Pinned App Server's enum variant field remains snake_case;
            // unlike its surrounding struct, rename_all applies to variants.
            guard kindObject["move_path"] == nil || kindObject["movePath"] == nil else { return nil }
            if let move = kindObject["move_path"] ?? kindObject["movePath"], !(move is NSNull) {
                guard kind == "update", let path = move as? String, !path.isEmpty,
                      path.utf8.count <= 16_384, !path.contains("\0") else { return nil }
                movePath = path
            } else { movePath = nil }
            bytes += diff.utf8.count
            guard bytes <= maximumDiffBytes else { return nil }
            // Pinned App Server appends display metadata to moved updates in
            // both live items and history. The typed movePath already carries
            // that operation; keep only the exact content-patch prefix. Byte
            // matching preserves Unicode and never repairs unknown diff text.
            let contentDiff: String
            if kind == "update", let movePath {
                let suffix = "\n\nMoved to: " + movePath
                if diff.utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8) {
                    contentDiff = String(decoding: diff.utf8.dropLast(suffix.utf8.count), as: UTF8.self)
                } else { contentDiff = diff }
            } else { contentDiff = diff }
            result.append(AgentFileChange(path: path, kind: kind, movePath: movePath, diff: contentDiff))
        }
        return result
    }

    static func entry(item: [String: Any], turnID: String, timestamp: Date = .now,
                      activityGroupID: String? = nil) -> TimelineEntry? {
        guard let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
              !turnID.isEmpty, turnID.utf8.count <= 512,
              let changes = changes(item["changes"]),
              let status = item["status"] as? String,
              ["inProgress", "completed", "failed", "declined"].contains(status) else { return nil }
        let prefix: String
        let runStatus: ToolRunStatus
        switch status {
        case "completed": prefix = "Changed"; runStatus = .succeeded
        case "failed": prefix = "File changes failed"; runStatus = .failed
        case "declined": prefix = "File changes declined"; runStatus = .failed
        default: prefix = "Proposed changes"; runStatus = .running
        }
        let count = changes.count
        let summary = "\(prefix): \(count) \(count == 1 ? "file" : "files")"
        let encoded = (try? JSONEncoder().encode(changes)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return TimelineEntry(id: id, kind: .tool, title: "File changes", body: summary, timestamp: timestamp,
            toolEvent: ToolEvent(name: "fileChange", summary: summary, status: runStatus,
                input: encoded, output: nil, duration: nil), activityGroupID: activityGroupID,
            fileChanges: changes, turnID: turnID)
    }
}

/// Tracks native item identity through patch streaming, approval and completion.
/// Streaming changes are proposals, never evidence a write succeeded.
struct AppServerFileChangeTranscript {
    private var entries = [String: TimelineEntry]()
    private var completed = Set<String>()

    func entry(itemID: String, turnID: String) -> TimelineEntry? {
        guard let entry = entries[itemID], entry.turnID == turnID else { return nil }
        return entry
    }

    var turnIDs: Set<String> { Set(entries.values.compactMap(\.turnID)) }

    mutating func receive(item: [String: Any], turnID: String, isCompleted: Bool) -> TimelineEntry? {
        guard let id = item["id"] as? String, !completed.contains(id),
              isCompleted == (item["status"] as? String != "inProgress"),
              entries[id] == nil || entries[id]?.turnID == turnID,
              var entry = AppServerFileChangeContract.entry(item: item, turnID: turnID) else { return nil }
        if let previous = entries[id] { entry.timestamp = previous.timestamp }
        entries[id] = entry
        if isCompleted { completed.insert(id) }
        return entry
    }

    mutating func patchUpdated(itemID: String, turnID: String, changes: Any?) -> TimelineEntry? {
        receive(item: ["id": itemID, "changes": changes ?? NSNull(), "status": "inProgress"],
                turnID: turnID, isCompleted: false)
    }

    mutating func finishUnconfirmed(turnID: String) -> [TimelineEntry] {
        let ids = entries.keys.filter { entries[$0]?.turnID == turnID && !completed.contains($0) }.sorted()
        return ids.compactMap { id in
            guard var entry = entries[id] else { return nil }
            entry.body = "File-change outcome unconfirmed"
            entry.toolEvent?.summary = entry.body
            entry.toolEvent?.status = .failed
            entry.toolEvent?.output = "The turn ended before the engine confirmed this patch's outcome. The displayed item is a proposal; review the files or the authoritative turn diff."
            entries[id] = entry
            return entry
        }
    }
}

/// Stores only engine-provided aggregate patch diffs. It neither reads source
/// files nor reconstructs an aggregate from proposed/failed item payloads.
struct AgentTurnDiffStore {
    private struct Record: Codable {
        let schemaVersion: Int
        let threadID: String
        var turns: [AgentTurnDiff]
    }
    let directory: URL

    func load(threadID: String) throws -> [AgentTurnDiff] {
        let url = try recordURL(threadID: threadID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1_024 * 1_024 else { throw StoreError.invalidRecord }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schemaVersion == 1, record.threadID == threadID, record.turns.count <= 256,
              Set(record.turns.map(\.id)).count == record.turns.count,
              record.turns.allSatisfy({ valid(turnID: $0.id, diff: $0.diff) }) else { throw StoreError.invalidRecord }
        return record.turns
    }

    func save(threadID: String, turnID: String, diff: String) throws {
        guard valid(turnID: turnID, diff: diff) else { throw StoreError.invalidRecord }
        var turns = try load(threadID: threadID)
        if let index = turns.firstIndex(where: { $0.id == turnID }) { turns[index].diff = diff }
        else { turns.append(AgentTurnDiff(id: turnID, diff: diff)) }
        if turns.count > 256 { turns.removeFirst(turns.count - 256) }
        var data = try JSONEncoder().encode(Record(schemaVersion: 1, threadID: threadID, turns: turns))
        while data.count > 16 * 1_024 * 1_024, turns.count > 1 {
            turns.removeFirst()
            data = try JSONEncoder().encode(Record(schemaVersion: 1, threadID: threadID, turns: turns))
        }
        guard data.count <= 16 * 1_024 * 1_024 else { throw StoreError.invalidRecord }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = try recordURL(threadID: threadID)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func recordURL(threadID: String) throws -> URL {
        guard !threadID.isEmpty, threadID.utf8.count <= 512 else { throw StoreError.invalidRecord }
        let key = SHA256.hash(data: Data(threadID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    private func valid(turnID: String, diff: String) -> Bool {
        !turnID.isEmpty && turnID.utf8.count <= 512 && diff.utf8.count <= AppServerFileChangeContract.maximumDiffBytes
    }

    enum StoreError: LocalizedError {
        case invalidRecord
        var errorDescription: String? { "The saved file-change diff exceeds its supported bounds or has an invalid identity." }
    }
}

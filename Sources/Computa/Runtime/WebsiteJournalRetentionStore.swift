import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Closed inference journals are history, not occupied live-session slots.
/// The archive commits exact bytes and identity indexes before removing a live
/// file. A pending operation is recovered under the same lock as both writers.
struct WebsiteJournalRetentionStore: Sendable {
    enum Failure: Error { case unavailable, capacity }
    struct Limits: Sendable {
        var activeTasks = 256
        var archiveBytes = 536_870_912
        var taskFiles = 2_048
        var taskBytes = 268_435_456
    }
    enum FaultPoint: String, Sendable { case committed, removedEvidence, removedCleanup }
    let cleanupDirectory: URL
    var limits = Limits()
    #if DEBUG
    var fault: (@Sendable (FaultPoint) throws -> Void)?
    #endif

    private var archiveURL: URL { cleanupDirectory.appendingPathComponent("closed-journals.sqlite") }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// No lock is held across an actor suspension, provider call, or UI action.
    func withWriterLock<T>(_ body: () throws -> T) throws -> T {
        try Self.directory(cleanupDirectory, create: true)
        let path = cleanupDirectory.appendingPathComponent(".journal-writer.lock")
        let fd = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// Called before native turn admission. Existing active turns are never
    /// evicted, even when their latest physical website session is closed.
    func admit(taskID: String, evidenceDirectory: URL, protectedTaskIDs: Set<String>) throws {
        try withWriterLock {
            try recover(evidenceDirectory: evidenceDirectory, protectedTaskIDs: protectedTaskIDs)
            let roots = [evidenceDirectory, cleanupDirectory]
            var inventories = try roots.map { try activeTasks($0) }
            guard inventories.allSatisfy({ $0.count <= limits.activeTasks }) else { throw Failure.capacity }
            guard inventories.contains(where: { !$0.contains(taskID) && $0.count >= limits.activeTasks }) else {
                try reserve(taskID, roots: roots); return
            }
            let candidates = inventories.reduce(Set<String>(), { $0.union($1) })
                .subtracting(protectedTaskIDs).subtracting([taskID]).sorted()
            for candidate in candidates {
                // A crash/cancellation before start_requested can leave only
                // empty reservations. No provider could start through this
                // server without first writing that durable record.
                if try discardEmptyReservation(candidate, roots: roots) {
                    inventories = try roots.map { try activeTasks($0) }
                    if inventories.allSatisfy({ $0.contains(taskID) || $0.count < limits.activeTasks }) {
                        try reserve(taskID, roots: roots); return
                    }
                    continue
                }
                // Invalid, uncertain or incomplete history remains in the live
                // set. It can never be made eligible by throwing it away.
                guard let bundle = try? eligible(candidate, evidenceDirectory: evidenceDirectory) else { continue }
                try archive(bundle, evidenceDirectory: evidenceDirectory)
                inventories = try roots.map { try activeTasks($0) }
                if inventories.allSatisfy({ $0.contains(taskID) || $0.count < limits.activeTasks }) {
                    try reserve(taskID, roots: roots); return
                }
            }
            throw Failure.capacity
        }
    }

    private func reserve(_ task: String, roots: [URL]) throws {
        guard Self.uuid(task) else { throw Failure.unavailable }
        for root in roots {
            let parent = root.appendingPathComponent("transactions")
            try Self.directory(parent.appendingPathComponent(task), create: true)
            try Self.sync(parent)
        }
    }

    private func discardEmptyReservation(_ task: String, roots: [URL]) throws -> Bool {
        let directories = roots.map { $0.appendingPathComponent("transactions/" + task) }.filter { Self.exists($0) }
        guard !directories.isEmpty else { return false }
        for directory in directories {
            try Self.directory(directory)
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { return false }
        }
        for directory in directories {
            try FileManager.default.removeItem(at: directory)
            try Self.sync(directory.deletingLastPathComponent())
        }
        return true
    }

    // These point lookups run under the caller's writer lock. They do not scan
    // historical tasks, and opening an absent archive never creates one.
    func archivedBytes(store: String, taskID: String, turnID: String) throws -> Data? {
        guard Self.uuid(taskID), Self.uuid(turnID), ["evidence", "cleanup"].contains(store) else { throw Failure.unavailable }
        return try database(create: false) { db in
            try query(db, "SELECT bytes FROM files WHERE store=? AND task=? AND turn=?", [store, taskID, turnID]).first?.first
        } ?? nil
    }

    func validateCleanupIdentity(_ receipt: WebsiteSessionCleanupReceipt) throws -> Bool {
        guard let inference = receipt.inferenceID else { return false }
        return try database(create: false) { db in
            let prior = try query(db, "SELECT bytes FROM receipts WHERE attempt=?", [receipt.attemptID]).first?.first
            if let prior {
                guard try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: prior) == receipt else { throw Failure.unavailable }
                return true
            }
            if !receipt.isTransactionLinked {
                guard try query(db, "SELECT binding FROM identities WHERE kind='inference' AND id=?", [inference]).isEmpty else { throw Failure.unavailable }
                return false
            }
            let binding = try Self.binding(receipt)
            for (kind, id) in [("inference", inference), ("token", receipt.sessionToken)].compactMap({ kind, id in id.map { (kind, $0) } }) {
                if let old = try query(db, "SELECT binding FROM identities WHERE kind=? AND id=?", [kind, id]).first?.first {
                    guard old == binding else { throw Failure.unavailable }
                }
            }
            return false
        } ?? false
    }

    func latestArchived() throws -> [WebsiteSessionCleanupReceipt] {
        try database(create: false) { db in
            try query(db, "SELECT bytes FROM latest ORDER BY timestamp DESC,task LIMIT 256", []).map {
                let row = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: $0[0])
                guard row.isValid, row.receiptSaved, row.outcome == .closed else { throw Failure.unavailable }
                return row
            }
        } ?? []
    }

    func isPending(taskID: String) throws -> Bool {
        try database(create: false) { db in
            !(try query(db, "SELECT task FROM operations WHERE state=0 AND task=?", [taskID])).isEmpty
        } ?? false
    }

    private struct File: Sendable {
        let store: String
        let turn: String
        let bytes: Data
        var hash: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }
    private struct Bundle {
        let task: String
        let files: [File]
        let receipts: [WebsiteSessionCleanupReceipt]
    }

    private func activeTasks(_ root: URL) throws -> Set<String> {
        try Self.directory(root, create: true)
        let transactions = root.appendingPathComponent("transactions")
        try Self.directory(transactions, create: true)
        let children = try FileManager.default.contentsOfDirectory(at: transactions, includingPropertiesForKeys: nil)
        guard children.count <= limits.activeTasks else { throw Failure.capacity }
        for child in children {
            guard Self.uuid(child.lastPathComponent) else { throw Failure.unavailable }
            try Self.directory(child)
        }
        return Set(children.map(\.lastPathComponent))
    }

    private func eligible(_ task: String, evidenceDirectory: URL) throws -> Bundle {
        var files: [File] = [], receipts: [WebsiteSessionCleanupReceipt] = [], evidence: [[String: Any]] = []
        var bytes = 0
        for (store, root) in [("evidence", evidenceDirectory), ("cleanup", cleanupDirectory)] {
            let directory = root.appendingPathComponent("transactions/" + task)
            try Self.directory(directory)
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard !entries.isEmpty, entries.count <= 1_024 else { throw Failure.unavailable }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let turn = entry.deletingPathExtension().lastPathComponent
                guard entry.pathExtension == "jsonl", Self.uuid(turn) else { throw Failure.unavailable }
                let data = try Self.read(entry, maximum: store == "evidence" ? 33_554_432 : 2_097_152)
                bytes += data.count
                guard bytes <= limits.taskBytes, files.count < limits.taskFiles, data.last == 10 else { throw Failure.unavailable }
                files.append(File(store: store, turn: turn, bytes: data))
                let lines = data.dropLast().split(separator: 10, omittingEmptySubsequences: false)
                guard !lines.isEmpty, lines.count <= (store == "evidence" ? 6_144 : 1_024) else { throw Failure.unavailable }
                for line in lines {
                    guard !line.isEmpty, line.count <= (store == "evidence" ? 4_096 : 2_048),
                          let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          row["taskID"] as? String == task, row["turnID"] as? String == turn else { throw Failure.unavailable }
                    if store == "evidence" { evidence.append(row) }
                    else {
                        let receipt = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: Data(line))
                        guard receipt.isValid, receipt.receiptSaved, receipt.isTransactionLinked else { throw Failure.unavailable }
                        receipts.append(receipt)
                    }
                }
            }
        }
        let groups = Dictionary(grouping: evidence) { $0["inferenceID"] as? String ?? "" }
        guard !groups.isEmpty, Set(receipts.compactMap(\.inferenceID)) == Set(groups.keys),
              Set(receipts.map(\.attemptID)).count == receipts.count else { throw Failure.unavailable }
        var tokenOwners: [String: String] = [:]
        let identity = ["taskID", "threadID", "turnID", "runtimeGeneration", "provider", "modelID", "inferenceID"]
        for (inference, rows) in groups {
            guard Self.uuid(inference), let first = rows.first,
                  rows.contains(where: { $0["phase"] as? String == "started" }),
                  rows.allSatisfy({ row in identity.allSatisfy { row[$0] as? String == first[$0] as? String } }),
                  ["threadID", "turnID", "runtimeGeneration"].allSatisfy({ Self.uuid(first[$0] as? String ?? "") }) else { throw Failure.unavailable }
            let tokens = Set(rows.compactMap { $0["sessionToken"] as? String })
            guard tokens.count == 1, let token = tokens.first, Self.uuid(token), tokenOwners[token] == nil else { throw Failure.unavailable }
            tokenOwners[token] = inference
            let matching = receipts.filter { $0.inferenceID == inference }
            let binding = try Self.binding(matching[0])
            guard matching.allSatisfy({ (try? Self.binding($0)) == binding }),
                  matching.allSatisfy({ receipt in
                      let encoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
                      return identity.allSatisfy { encoded?[$0] as? String == first[$0] as? String } && receipt.sessionToken == token
                  }), let closed = matching.last, closed.outcome == .closed,
                  rows.allSatisfy({ ($0["timestamp"] as? String).map { $0 <= closed.timestamp } == true || $0["phase"] as? String == "release_verified" }),
                  matching.allSatisfy({ $0.timestamp <= closed.timestamp }),
                  rows.contains(where: { $0["phase"] as? String == "failed" }) || rows.contains(where: {
                      $0["phase"] as? String == "release_verified" && $0["cleanupAttemptID"] as? String == closed.attemptID
                  }) else { throw Failure.unavailable }
        }
        // Summary-only unresolved evidence is not erased or contradicted by
        // archiving the transaction directories.
        let summary = cleanupDirectory.appendingPathComponent(task + ".jsonl")
        if Self.exists(summary) {
            let data = try Self.read(summary, maximum: 65_536)
            guard data.last == 10 else { throw Failure.unavailable }
            for line in data.split(separator: 10) {
                let receipt = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: Data(line))
                guard receipt.isValid, receipt.taskID == task else { throw Failure.unavailable }
                if receipt.outcome == .unconfirmed {
                    guard receipt.isTransactionLinked, receipts.contains(where: {
                        $0.outcome == .closed && $0.timestamp >= receipt.timestamp && (try? Self.binding($0)) == (try? Self.binding(receipt))
                    }) else { throw Failure.unavailable }
                }
            }
        }
        return Bundle(task: task, files: files, receipts: receipts)
    }

    private func archive(_ bundle: Bundle, evidenceDirectory: URL) throws {
        try database(create: true) { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                guard try query(db, "SELECT task FROM operations WHERE task=? AND state=0", [bundle.task]).isEmpty else { throw Failure.unavailable }
                try execute(db, "INSERT INTO operations(task,state,evidence_root,generation) VALUES(?,0,?,1) ON CONFLICT(task) DO UPDATE SET state=0,evidence_root=excluded.evidence_root,generation=operations.generation+1", [bundle.task, evidenceDirectory.path])
                for file in bundle.files {
                    try execute(db, "INSERT INTO files(store,task,turn,bytes,sha256,generation) VALUES(?,?,?,?,?,(SELECT generation FROM operations WHERE task=?))",
                                [file.store, bundle.task, file.turn, file.bytes, file.hash, bundle.task])
                    guard try query(db, "SELECT bytes FROM files WHERE store=? AND task=? AND turn=?", [file.store, bundle.task, file.turn]).first?.first == file.bytes else { throw Failure.unavailable }
                }
                for receipt in bundle.receipts {
                    let data = try JSONEncoder().encode(receipt), binding = try Self.binding(receipt)
                    try execute(db, "INSERT INTO receipts(attempt,bytes) VALUES(?,?)", [receipt.attemptID, data])
                    for (kind, id) in [("inference", receipt.inferenceID!), ("token", receipt.sessionToken!)] {
                        if let old = try query(db, "SELECT binding FROM identities WHERE kind=? AND id=?", [kind, id]).first?.first {
                            guard old == binding else { throw Failure.unavailable }
                        } else { try execute(db, "INSERT INTO identities(kind,id,binding) VALUES(?,?,?)", [kind, id, binding]) }
                    }
                }
                let latest = bundle.receipts.filter { $0.outcome == .closed }.max { ($0.timestamp, $0.attemptID) < ($1.timestamp, $1.attemptID) }!
                try execute(db, "INSERT INTO latest(task,timestamp,bytes) VALUES(?,?,?) ON CONFLICT(task) DO UPDATE SET timestamp=excluded.timestamp,bytes=excluded.bytes WHERE excluded.timestamp>=latest.timestamp",
                            [bundle.task, latest.timestamp, try JSONEncoder().encode(latest)])
                try execute(db, "COMMIT")
            } catch { try? execute(db, "ROLLBACK"); throw error }
        }
        #if DEBUG
        try fault?(.committed)
        #endif
        try recover(evidenceDirectory: evidenceDirectory, protectedTaskIDs: [])
    }

    private func recover(evidenceDirectory: URL, protectedTaskIDs: Set<String>) throws {
        try database(create: false) { db in
            let operations = try query(db, "SELECT task,evidence_root FROM operations WHERE state=0 LIMIT 2", [])
            guard operations.count <= 1 else { throw Failure.unavailable }
            for operation in operations {
                let task = String(decoding: operation[0], as: UTF8.self)
                guard Self.uuid(task), !protectedTaskIDs.contains(task), String(decoding: operation[1], as: UTF8.self) == evidenceDirectory.path else { throw Failure.unavailable }
                for (store, root) in [("evidence", evidenceDirectory), ("cleanup", cleanupDirectory)] {
                    let rows = try query(db, "SELECT turn,bytes,sha256 FROM files WHERE store=? AND task=? AND generation=(SELECT generation FROM operations WHERE task=?)", [store, task, task], maximumRows: limits.taskFiles)
                    guard !rows.isEmpty else { throw Failure.unavailable }
                    let directory = root.appendingPathComponent("transactions/" + task)
                    if Self.exists(directory) {
                        try Self.directory(directory)
                        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        let expected = Set(rows.map { String(decoding: $0[0], as: UTF8.self) + ".jsonl" })
                        guard Set(entries.map(\.lastPathComponent)).isSubset(of: expected) else { throw Failure.unavailable }
                        // Validate all remaining bytes before the first removal.
                        for row in rows {
                            let turn = String(decoding: row[0], as: UTF8.self)
                            guard Self.uuid(turn), SHA256.hash(data: row[1]).map({ String(format: "%02x", $0) }).joined() == String(decoding: row[2], as: UTF8.self) else { throw Failure.unavailable }
                            let file = directory.appendingPathComponent(turn + ".jsonl")
                            if Self.exists(file) { guard try Self.read(file, maximum: 33_554_432) == row[1] else { throw Failure.unavailable } }
                        }
                        for entry in entries { try FileManager.default.removeItem(at: entry) }
                        try Self.sync(directory)
                        try FileManager.default.removeItem(at: directory)
                        try Self.sync(directory.deletingLastPathComponent())
                    }
                    #if DEBUG
                    try fault?(store == "evidence" ? .removedEvidence : .removedCleanup)
                    #endif
                }
                try execute(db, "UPDATE operations SET state=1 WHERE task=? AND state=0", [task])
            }
        }
    }

    private static func binding(_ receipt: WebsiteSessionCleanupReceipt) throws -> Data {
        guard receipt.isTransactionLinked else { throw Failure.unavailable }
        return try JSONSerialization.data(withJSONObject: [receipt.taskID, receipt.threadID!, receipt.turnID!,
            receipt.runtimeGeneration, receipt.provider!.rawValue, receipt.route!.rawValue, receipt.modelID!,
            receipt.inferenceID!, receipt.sessionToken!], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func database<T>(create: Bool, _ body: (OpaquePointer) throws -> T) throws -> T? {
        try Self.directory(cleanupDirectory, create: create)
        if !Self.exists(archiveURL), !create { return nil }
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let path = URL(fileURLWithPath: archiveURL.path + suffix)
            if Self.exists(path) { _ = try Self.regularSize(path, maximum: limits.archiveBytes) }
        }
        var raw: OpaquePointer?
        // SQLite's NOFOLLOW also rejects ancestor aliases. The directory check
        // above has already verified the exact root-owned OS alias; expand
        // only that prefix, retaining NOFOLLOW for all application paths.
        let sqlitePath = archiveURL.path.hasPrefix("/var/") || archiveURL.path.hasPrefix("/tmp/")
            ? "/private" + archiveURL.path : archiveURL.path
        guard sqlite3_open_v2(sqlitePath, &raw, SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let db = raw else { if let raw { sqlite3_close(raw) }; throw Failure.unavailable }
        defer { sqlite3_close(db) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        try execute(db, "PRAGMA trusted_schema=OFF")
        try execute(db, "PRAGMA synchronous=FULL")
        try execute(db, "PRAGMA journal_mode=DELETE")
        let pageSize = try query(db, "PRAGMA page_size", []).first.flatMap { Int(String(decoding: $0[0], as: UTF8.self)) } ?? 0
        guard pageSize > 0 else { throw Failure.unavailable }
        try execute(db, "PRAGMA max_page_count=\(limits.archiveBytes / pageSize)")
        let version = try query(db, "PRAGMA user_version", []).first?.first
        if version == Data("0".utf8) {
            // An interrupted initial schema transaction leaves an empty file;
            // a foreign or future schema is never upgraded by guessing.
            guard try query(db, "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' LIMIT 1", []).isEmpty else { throw Failure.unavailable }
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try execute(db, "CREATE TABLE operations(task TEXT PRIMARY KEY,state INTEGER NOT NULL,evidence_root TEXT NOT NULL,generation INTEGER NOT NULL)")
                try execute(db, "CREATE TABLE files(store TEXT NOT NULL,task TEXT NOT NULL,turn TEXT NOT NULL,bytes BLOB NOT NULL,sha256 TEXT NOT NULL,generation INTEGER NOT NULL,PRIMARY KEY(store,task,turn))")
                try execute(db, "CREATE INDEX files_operation ON files(task,generation,store)")
                try execute(db, "CREATE TABLE receipts(attempt TEXT PRIMARY KEY,bytes BLOB NOT NULL)")
                try execute(db, "CREATE TABLE identities(kind TEXT NOT NULL,id TEXT NOT NULL,binding BLOB NOT NULL,PRIMARY KEY(kind,id))")
                try execute(db, "CREATE TABLE latest(task TEXT PRIMARY KEY,timestamp TEXT NOT NULL,bytes BLOB NOT NULL)")
                try execute(db, "PRAGMA user_version=1")
                try execute(db, "COMMIT")
                try Self.sync(cleanupDirectory)
            } catch { try? execute(db, "ROLLBACK"); throw error }
        }
        guard try query(db, "PRAGMA user_version", []).first?.first == Data("1".utf8) else { throw Failure.unavailable }
        return try body(db)
    }

    private func statement(_ db: OpaquePointer, _ sql: String, _ arguments: [Any]) throws -> OpaquePointer {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { throw Failure.unavailable }
        do {
            for (offset, argument) in arguments.enumerated() {
                let index = Int32(offset + 1), code: Int32
                if let bytes = argument as? Data { code = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), Self.transient) } }
                else if let text = argument as? String { code = sqlite3_bind_text(stmt, index, text, -1, Self.transient) }
                else { throw Failure.unavailable }
                guard code == SQLITE_OK else { throw Failure.unavailable }
            }
            return stmt
        } catch { sqlite3_finalize(stmt); throw error }
    }
    private func execute(_ db: OpaquePointer, _ sql: String, _ arguments: [Any] = []) throws {
        let stmt = try statement(db, sql, arguments); defer { sqlite3_finalize(stmt) }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW { result = sqlite3_step(stmt) }
        guard result == SQLITE_DONE else { throw Failure.unavailable }
    }
    private func query(_ db: OpaquePointer, _ sql: String, _ arguments: [Any], maximumRows: Int = 256) throws -> [[Data]] {
        let stmt = try statement(db, sql, arguments); defer { sqlite3_finalize(stmt) }
        var rows: [[Data]] = [], bytes = 0
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW, rows.count < maximumRows else { throw Failure.unavailable }
            var row: [Data] = []
            for column in 0..<sqlite3_column_count(stmt) {
                let count = Int(sqlite3_column_bytes(stmt, column)); bytes += count
                guard count >= 0, bytes <= limits.taskBytes else { throw Failure.unavailable }
                let pointer = sqlite3_column_blob(stmt, column)
                guard count == 0 || pointer != nil else { throw Failure.unavailable }
                row.append(count == 0 ? Data() : Data(bytes: pointer!, count: count))
            }
            rows.append(row)
        }
    }

    private static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    private static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 || errno != ENOENT }
    private static func directory(_ url: URL, create: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw Failure.unavailable }
        if create, !exists(url) {
            try directory(url.deletingLastPathComponent(), create: true)
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { if !exists(url) { throw error } }
        }
        var current = url
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0 else { throw Failure.unavailable }
            if info.st_mode & S_IFMT != S_IFDIR {
                // Foundation's temporaryDirectory uses macOS's root-owned
                // /var alias. Accept only these exact OS aliases, never an
                // application/journal symlink or an arbitrary ancestor link.
                let aliases = ["/var": "private/var", "/tmp": "private/tmp"]
                guard current != url, info.st_mode & S_IFMT == S_IFLNK, info.st_uid == 0,
                      let destination = aliases[current.path],
                      try [destination, "/" + destination].contains(FileManager.default.destinationOfSymbolicLink(atPath: current.path)) else { throw Failure.unavailable }
                try directory(URL(fileURLWithPath: "/" + destination))
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }
    private static func regularSize(_ url: URL, maximum: Int) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= maximum else { throw Failure.unavailable }
        return Int(info.st_size)
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let size = try regularSize(url, maximum: maximum)
        let data = try Data(contentsOf: url)
        guard data.count == size else { throw Failure.unavailable }
        return data
    }
    private static func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.unavailable }
    }
}

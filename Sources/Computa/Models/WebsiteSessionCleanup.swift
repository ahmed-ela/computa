import Foundation

/// A cleanup observation, never a model response or evidence of a past deletion.
struct WebsiteSessionCleanupReceipt: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case closed, noOwnedSession = "no_owned_session", unconfirmed }
    enum Reason: String, Codable, Sendable {
        case deleted, notCreated = "not_created", noOwnedSession = "no_owned_session", busy
        case shuttingDown = "shutting_down", runtimeChanged = "runtime_changed"
        case cleanupUnverified = "cleanup_unverified", unsupportedRuntime = "unsupported_runtime"
    }
    enum Provider: String, Codable, Sendable { case chatgpt, gemini, claude }
    enum Route: String, Codable, Sendable { case embedded, chrome }
    enum Trigger: String, Codable, Sendable { case automatic, manual, replacement, shutdown, inference }

    let schemaVersion: Int
    let attemptID: String
    let taskID: String
    let threadID: String?
    let turnID: String?
    /// Schema 2 identifies the one website transaction this observation retires.
    let inferenceID: String?
    let sessionToken: String?
    let runtimeGeneration: String
    let timestamp: String
    let outcome: Outcome
    let provider: Provider?
    let route: Route?
    let modelID: String?
    let reason: Reason
    let trigger: Trigger
    var receiptSaved: Bool

    init(taskID: String, threadID: String? = nil, turnID: String? = nil, runtimeGeneration: UUID, outcome: Outcome, provider: Provider? = nil,
         route: Route? = nil, modelID: String? = nil, reason: Reason, trigger: Trigger, receiptSaved: Bool = false,
         inferenceID: String? = nil, sessionToken: String? = nil) {
        schemaVersion = inferenceID == nil && sessionToken == nil ? 1 : 2
        attemptID = UUID().uuidString.lowercased()
        self.taskID = taskID.lowercased()
        self.threadID = threadID?.lowercased(); self.turnID = turnID?.lowercased()
        self.inferenceID = inferenceID?.lowercased(); self.sessionToken = sessionToken?.lowercased()
        self.runtimeGeneration = runtimeGeneration.uuidString.lowercased()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp = formatter.string(from: Date())
        self.outcome = outcome; self.provider = provider; self.route = route; self.modelID = modelID
        self.reason = reason; self.trigger = trigger; self.receiptSaved = receiptSaved
    }

    var isValid: Bool {
        guard [1, 2].contains(schemaVersion), UUID(uuidString: attemptID) != nil, UUID(uuidString: taskID) != nil,
              UUID(uuidString: runtimeGeneration) != nil, timestamp.utf8.count <= 32 else { return false }
        guard threadID == nil || UUID(uuidString: threadID!) != nil,
              turnID == nil || (threadID != nil && UUID(uuidString: turnID!) != nil) else { return false }
        if schemaVersion == 2 {
            guard let threadID, let turnID, let inferenceID, let sessionToken,
                  [attemptID, taskID, threadID, turnID, runtimeGeneration, inferenceID, sessionToken].allSatisfy(Self.canonicalUUID),
                  provider != nil, route != nil, modelID != nil, outcome != .noOwnedSession else { return false }
        } else if inferenceID != nil || sessionToken != nil || trigger == .inference { return false }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: timestamp) != nil else { return false }
        if let modelID {
            guard let provider, modelID == "browser/\(provider.rawValue)"
                || WebsiteModelCatalog.choice(for: modelID)?.provider == provider.rawValue else { return false }
        }
        switch outcome {
        case .closed: return provider != nil && route != nil && modelID != nil && [.deleted, .notCreated].contains(reason)
        case .noOwnedSession: return provider == nil && route == nil && modelID == nil && reason == .noOwnedSession
        case .unconfirmed: return ![.deleted, .notCreated, .noOwnedSession].contains(reason)
        }
    }

    var isTransactionLinked: Bool { schemaVersion == 2 && inferenceID != nil && sessionToken != nil }

    fileprivate static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

/// Full transaction proofs are append-only. The per-task file is a bounded UI
/// summary: it can evict rows only after their exact durable proof is verified.
/// The owning server serializes writes and retries an identical receipt after a
/// storage failure, without performing physical website cleanup a second time.
struct WebsiteSessionCleanupStore: Sendable {
    struct Limits: Sendable {
        var recordBytes = 2_048
        var summaryRecords = 64
        var summaryBytes = 65_536
        var summaryTasks = 256
        var transactionRecords = 1_024
        var transactionBytes = 2_097_152
        var transactionTasks = 256
        var transactionTurnsPerTask = 1_024
        var transactionFiles = 16_384
        var transactionDirectoryBytes = 134_217_728
        var archiveRecords = 16_384
        var archiveBytes = 16_777_216
        var archiveDirectoryBytes = 134_217_728
    }

    let directory: URL
    let limits: Limits

    init(directory: URL, limits: Limits = Limits()) { self.directory = directory; self.limits = limits }

    private var transactionsDirectory: URL { directory.appendingPathComponent("transactions", isDirectory: true) }
    private var archiveDirectory: URL { directory.appendingPathComponent("legacy-archive", isDirectory: true) }

    func save(_ receipt: WebsiteSessionCleanupReceipt) -> Bool {
        guard receipt.isValid, receipt.receiptSaved else { return false }
        if receipt.isTransactionLinked, !saveTransaction(receipt) { return false }
        let file = summaryFile(receipt.taskID)
        do {
            try prepareDirectory(directory)
            let existing = try records(file, taskID: receipt.taskID, maximumRecords: limits.summaryRecords, maximumBytes: limits.summaryBytes)
            if let saved = existing.first(where: { $0.attemptID == receipt.attemptID }) {
                guard saved == receipt else { return false }
                try synchronize(file); return true
            }
            if existing.isEmpty {
                if try summaryFiles().count >= limits.summaryTasks {
                    // The summary is a bounded UI cache. A transaction already
                    // has its exact synced/read-back proof, and latest() reads
                    // that journal even when no summary slot is available.
                    // Legacy observations still require their summary file.
                    return receipt.isTransactionLinked
                }
            }
            var retained = existing + [receipt], removed: [WebsiteSessionCleanupReceipt] = []
            var data = try encoded(retained)
            while retained.count > limits.summaryRecords || data.count > limits.summaryBytes {
                // A legacy-only store retains its original finite semantics;
                // compaction is enabled only by a verified new transaction.
                guard receipt.isTransactionLinked, retained.count > 1 else { return false }
                removed.append(retained.removeFirst())
                data = try encoded(retained)
            }
            for row in removed {
                if row.isTransactionLinked {
                    guard let turnID = row.turnID,
                          try transactionRecords(for: row.taskID, turnID: turnID).contains(row) else { return false }
                } else if !saveArchivedLegacy(row) { return false }
            }
            try write(data, to: file)
            return true
        } catch { return false }
    }

    /// Appends one transaction observation, or verifies an identical retry.
    /// A conflict, malformed existing proof or exceeded finite budget fails.
    func saveTransaction(_ receipt: WebsiteSessionCleanupReceipt) -> Bool {
        guard receipt.isValid, receipt.receiptSaved, receipt.isTransactionLinked,
              let turnID = receipt.turnID else { return false }
        let taskDirectory = transactionsDirectory.appendingPathComponent(receipt.taskID, isDirectory: true)
        let file = taskDirectory.appendingPathComponent(turnID + ".jsonl")
        do {
            try prepareDirectory(directory); try prepareDirectory(transactionsDirectory)
            let inventory = try transactionInventory()
            let taskExists = inventory.tasks.contains(receipt.taskID)
            guard taskExists || inventory.tasks.count < limits.transactionTasks else { return false }
            let taskFiles = inventory.files.filter { $0.deletingLastPathComponent().lastPathComponent == receipt.taskID }
            let fileExists = taskFiles.contains(file)
            guard fileExists || (taskFiles.count < limits.transactionTurnsPerTask && inventory.files.count < limits.transactionFiles) else { return false }
            try prepareDirectory(taskDirectory)
            let existing = try transactionRecords(for: receipt.taskID, turnID: turnID)
            if let saved = existing.first(where: { $0.attemptID == receipt.attemptID }) {
                guard saved == receipt else { return false }
                try synchronize(file); return true
            }
            if let first = existing.first {
                guard first.threadID == receipt.threadID, first.runtimeGeneration == receipt.runtimeGeneration else { return false }
            }
            // A fresh inference cannot adopt another session, nor can a token
            // be rebound to a different inference or causal native turn.
            for otherFile in inventory.files {
                let rows = try records(otherFile, taskID: otherFile.deletingLastPathComponent().lastPathComponent,
                    turnID: otherFile.deletingPathExtension().lastPathComponent,
                    maximumRecords: limits.transactionRecords, maximumBytes: limits.transactionBytes, requireTransactions: true)
                for row in rows {
                    if row.attemptID == receipt.attemptID { return false }
                    if row.inferenceID == receipt.inferenceID || row.sessionToken == receipt.sessionToken {
                        guard row.taskID == receipt.taskID, row.inferenceID == receipt.inferenceID, row.sessionToken == receipt.sessionToken,
                              row.turnID == receipt.turnID, row.threadID == receipt.threadID,
                              row.runtimeGeneration == receipt.runtimeGeneration, row.provider == receipt.provider,
                              row.route == receipt.route, row.modelID == receipt.modelID else { return false }
                    }
                }
            }
            guard existing.count < limits.transactionRecords else { return false }
            let data = try encoded(existing + [receipt])
            guard data.count <= limits.transactionBytes,
                  inventory.bytes - (try fileSize(file)) + data.count <= limits.transactionDirectoryBytes else { return false }
            try write(data, to: file)
            return true
        } catch { return false }
    }

    func transactionRecords(for taskID: String, turnID: String) throws -> [WebsiteSessionCleanupReceipt] {
        guard WebsiteSessionCleanupReceipt.canonicalUUID(taskID), WebsiteSessionCleanupReceipt.canonicalUUID(turnID) else { throw corrupt() }
        guard !isLink(directory), !isLink(transactionsDirectory) else { throw corrupt() }
        let taskDirectory = transactionsDirectory.appendingPathComponent(taskID, isDirectory: true)
        guard !isLink(taskDirectory) else { throw corrupt() }
        return try records(taskDirectory.appendingPathComponent(turnID + ".jsonl"), taskID: taskID, turnID: turnID,
            maximumRecords: limits.transactionRecords, maximumBytes: limits.transactionBytes, requireTransactions: true)
    }

    func archivedLegacyRecords(for taskID: String) throws -> [WebsiteSessionCleanupReceipt] {
        guard WebsiteSessionCleanupReceipt.canonicalUUID(taskID), !isLink(directory), !isLink(archiveDirectory) else { throw corrupt() }
        let rows = try records(archiveDirectory.appendingPathComponent(taskID + ".jsonl"), taskID: taskID,
            maximumRecords: limits.archiveRecords, maximumBytes: limits.archiveBytes)
        guard rows.allSatisfy({ !$0.isTransactionLinked }) else { throw corrupt() }
        return rows
    }

    func latest() -> [WebsiteSessionCleanupReceipt] {
        guard !isLink(directory), let files = try? summaryFiles(), files.count <= limits.summaryTasks,
              let inventory = try? transactionInventory() else { return [] }
        let taskIDs = Set(files.map { $0.deletingPathExtension().lastPathComponent }).union(inventory.tasks)
        return taskIDs.compactMap { taskID -> WebsiteSessionCleanupReceipt? in
            do {
                let summary = try records(summaryFile(taskID), taskID: taskID, maximumRecords: limits.summaryRecords, maximumBytes: limits.summaryBytes)
                var journal: [WebsiteSessionCleanupReceipt] = []
                for file in inventory.files where file.deletingLastPathComponent().lastPathComponent == taskID {
                    journal += try transactionRecords(for: taskID, turnID: file.deletingPathExtension().lastPathComponent)
                }
                // Empty-current-state and another transaction's closure cannot
                // erase an unresolved causal cleanup observation.
                let closed = Set(journal.filter { $0.outcome == .closed }.compactMap(\.inferenceID))
                if let unresolved = journal.filter({ $0.outcome == .unconfirmed && !closed.contains($0.inferenceID!) })
                    .max(by: { ($0.timestamp, $0.attemptID) < ($1.timestamp, $1.attemptID) }) { return unresolved }
                let latestJournal = journal.max { ($0.timestamp, $0.attemptID) < ($1.timestamp, $1.attemptID) }
                if let last = summary.last {
                    if last.outcome == .unconfirmed, let inferenceID = last.inferenceID,
                       let closure = journal.last(where: { $0.inferenceID == inferenceID && $0.outcome == .closed }) { return closure }
                    if let latestJournal, latestJournal.timestamp > last.timestamp { return latestJournal }
                    return last
                }
                return latestJournal
            } catch { return nil }
        }.sorted { ($0.timestamp, $0.attemptID) < ($1.timestamp, $1.attemptID) }
    }

    private func saveArchivedLegacy(_ receipt: WebsiteSessionCleanupReceipt) -> Bool {
        guard !receipt.isTransactionLinked else { return false }
        let taskID = receipt.taskID.lowercased()
        let file = archiveDirectory.appendingPathComponent(taskID + ".jsonl")
        do {
            try prepareDirectory(archiveDirectory)
            let files = try FileManager.default.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil)
            guard files.count <= limits.summaryTasks else { return false }
            var bytes = 0
            for entry in files {
                guard entry.pathExtension == "jsonl", WebsiteSessionCleanupReceipt.canonicalUUID(entry.deletingPathExtension().lastPathComponent) else { return false }
                let size = try fileSize(entry)
                guard size <= limits.archiveBytes else { return false }
                bytes += size
            }
            let existing = try archivedLegacyRecords(for: taskID)
            if let saved = existing.first(where: { $0.attemptID == receipt.attemptID }) {
                guard saved == receipt else { return false }
                try synchronize(file); return true
            }
            guard existing.count < limits.archiveRecords,
                  !existing.isEmpty || files.count < limits.summaryTasks else { return false }
            let data = try encoded(existing + [receipt])
            guard data.count <= limits.archiveBytes,
                  bytes - (try fileSize(file)) + data.count <= limits.archiveDirectoryBytes else { return false }
            try write(data, to: file)
            return true
        } catch { return false }
    }

    private func summaryFile(_ taskID: String) -> URL {
        directory.appendingPathComponent(taskID.lowercased() + ".jsonl")
    }

    private func summaryFiles() throws -> [URL] {
        guard !isLink(directory) else { throw corrupt() }
        if !FileManager.default.fileExists(atPath: directory.path) { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
            $0.pathExtension == "jsonl" && WebsiteSessionCleanupReceipt.canonicalUUID($0.deletingPathExtension().lastPathComponent)
        }
    }

    private func transactionInventory() throws -> (tasks: Set<String>, files: [URL], bytes: Int) {
        guard !isLink(directory), !isLink(transactionsDirectory) else { throw corrupt() }
        if !FileManager.default.fileExists(atPath: transactionsDirectory.path) { return ([], [], 0) }
        let tasks = try FileManager.default.contentsOfDirectory(at: transactionsDirectory, includingPropertiesForKeys: nil)
        guard tasks.count <= limits.transactionTasks else { throw corrupt() }
        var files: [URL] = [], bytes = 0, taskIDs = Set<String>()
        for task in tasks {
            guard WebsiteSessionCleanupReceipt.canonicalUUID(task.lastPathComponent), !isLink(task),
                  (try task.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw corrupt() }
            taskIDs.insert(task.lastPathComponent)
            let turns = try FileManager.default.contentsOfDirectory(at: task, includingPropertiesForKeys: nil)
            guard turns.count <= limits.transactionTurnsPerTask else { throw corrupt() }
            for file in turns {
                guard file.pathExtension == "jsonl", WebsiteSessionCleanupReceipt.canonicalUUID(file.deletingPathExtension().lastPathComponent) else { throw corrupt() }
                let size = try fileSize(file)
                guard size <= limits.transactionBytes else { throw corrupt() }
                bytes += size; files.append(file)
                guard files.count <= limits.transactionFiles, bytes <= limits.transactionDirectoryBytes else { throw corrupt() }
            }
        }
        return (taskIDs, files, bytes)
    }

    private func prepareDirectory(_ url: URL) throws {
        guard !isLink(url) else { throw corrupt() }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !isLink(url), (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw corrupt() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func isLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func fileSize(_ file: URL) throws -> Int {
        guard !isLink(file) else { throw corrupt() }
        if !FileManager.default.fileExists(atPath: file.path) { return 0 }
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize else { throw corrupt() }
        return size
    }

    private func records(_ file: URL, taskID: String, turnID: String? = nil,
                         maximumRecords: Int, maximumBytes: Int, requireTransactions: Bool = false) throws -> [WebsiteSessionCleanupReceipt] {
        guard !isLink(file) else { throw corrupt() }
        if !FileManager.default.fileExists(atPath: file.path) { return [] }
        guard try fileSize(file) <= maximumBytes else { throw corrupt() }
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, data.count <= maximumBytes, data.last == 0x0A else { throw corrupt() }
        let lines = data.dropLast().split(separator: 0x0A, omittingEmptySubsequences: false)
        guard lines.count <= maximumRecords else { throw corrupt() }
        let legacy: Set<String> = ["schemaVersion", "attemptID", "taskID", "threadID", "turnID", "runtimeGeneration", "timestamp", "outcome", "provider", "route", "modelID", "reason", "trigger", "receiptSaved"]
        var seen = Set<String>()
        let result = try lines.map { line in
            guard !line.isEmpty, line.count <= limits.recordBytes,
                  let raw = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  Set(raw.keys).isSubset(of: (raw["schemaVersion"] as? Int) == 2 ? legacy.union(["inferenceID", "sessionToken"]) : legacy) else { throw corrupt() }
            let value = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: Data(line))
            guard value.isValid, value.receiptSaved, value.taskID.lowercased() == taskID.lowercased(),
                  turnID == nil || value.turnID == turnID,
                  !requireTransactions || value.isTransactionLinked,
                  seen.insert(value.attemptID).inserted else { throw corrupt() }
            return value
        }
        if requireTransactions {
            var inferences: [String: WebsiteSessionCleanupReceipt] = [:], tokens: [String: String] = [:]
            for row in result {
                guard row.threadID == result.first?.threadID, row.runtimeGeneration == result.first?.runtimeGeneration else { throw corrupt() }
                let inferenceID = row.inferenceID!, token = row.sessionToken!
                if let previous = inferences[inferenceID] {
                    guard previous.sessionToken == token, previous.provider == row.provider,
                          previous.route == row.route, previous.modelID == row.modelID else { throw corrupt() }
                }
                if let previous = tokens[token], previous != inferenceID { throw corrupt() }
                inferences[inferenceID] = row; tokens[token] = inferenceID
            }
        }
        return result
    }

    private func encoded(_ receipts: [WebsiteSessionCleanupReceipt]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for receipt in receipts {
            let row = try encoder.encode(receipt)
            guard row.count <= limits.recordBytes else { throw corrupt() }
            data.append(row); data.append(0x0A)
        }
        return data
    }

    private func write(_ data: Data, to file: URL) throws {
        guard !isLink(file) else { throw corrupt() }
        try data.write(to: file, options: .atomic)
        try synchronize(file)
        guard try Data(contentsOf: file) == data else { throw corrupt() }
    }

    private func synchronize(_ file: URL) throws {
        guard !isLink(file), try fileSize(file) > 0 else { throw corrupt() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func corrupt() -> CocoaError { CocoaError(.fileReadCorruptFile) }
}

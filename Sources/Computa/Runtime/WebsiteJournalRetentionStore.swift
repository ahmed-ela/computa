import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Proven terminal inference journals need no live-session slots.
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
            let own = try query(db, "SELECT binding FROM identities WHERE kind='inference' AND id=?", [inference]).first?.first
            if let own { guard own == binding else { throw Failure.unavailable } }
            if let token = receipt.sessionToken,
               let old = try query(db, "SELECT binding FROM identities WHERE kind='token' AND id=?", [token]).first?.first,
               old != binding {
                let relation = try query(db, "SELECT binding FROM identities WHERE kind='retained_token_v1' AND id=?", [token]).first?.first
                guard own == binding, let relation,
                      try Self.retainedToken(relation, permits: binding, anchoredBy: old) else { throw Failure.unavailable }
            }
            return false
        } ?? false
    }

    func latestArchived() throws -> [WebsiteSessionCleanupReceipt] {
        try database(create: false) { db in
            let closed = try query(db, "SELECT bytes FROM latest ORDER BY timestamp DESC,task LIMIT 256", []).map {
                let row = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: $0[0])
                guard row.isValid, row.receiptSaved, row.outcome == .closed else { throw Failure.unavailable }
                return row
            }
            guard try !query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='precreation_latest'", []).isEmpty else {
                return closed
            }
            let rejected = try query(db, "SELECT bytes FROM precreation_latest ORDER BY timestamp DESC,task LIMIT 256", []).map {
                let row = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: $0[0])
                guard row.isValid, row.receiptSaved, row.isPrecreationRejectionLinked else { throw Failure.unavailable }
                return row
            }
            let sorted = (closed + rejected).sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                if $0.taskID != $1.taskID { return $0.taskID < $1.taskID }
                return $0.attemptID > $1.attemptID
            }
            var tasks = Set<String>()
            return Array(sorted.filter { tasks.insert($0.taskID).inserted }.prefix(256))
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
    private struct Identity {
        let kind: String
        let id: String
        let binding: Data
    }
    private struct Bundle {
        let task: String
        let files: [File]
        let receipts: [WebsiteSessionCleanupReceipt]
        let identities: [Identity]
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
                        guard receipt.isValid, receipt.receiptSaved,
                              receipt.isTransactionLinked || receipt.isPrecreationRejectionLinked else { throw Failure.unavailable }
                        if receipt.isPrecreationRejectionLinked {
                            guard Set(row.keys) == ["schemaVersion", "attemptID", "taskID", "threadID", "turnID", "inferenceID",
                                "runtimeGeneration", "timestamp", "outcome", "provider", "route", "modelID", "reason", "trigger",
                                "receiptSaved"] else { throw Failure.unavailable }
                        }
                        receipts.append(receipt)
                    }
                }
            }
        }
        let groups = Dictionary(grouping: evidence) { $0["inferenceID"] as? String ?? "" }
        guard !groups.isEmpty, Set(receipts.compactMap(\.inferenceID)).isSubset(of: Set(groups.keys)),
              Set(receipts.map(\.attemptID)).count == receipts.count else { throw Failure.unavailable }
        if receipts.contains(where: \.isPrecreationRejectionLinked) {
            let identities = try Self.precreationIdentities(groups, receipts: receipts)
            try Self.requireUnambiguous(files)
            try validateSummary(task, receipts: receipts, requireUnambiguous: true)
            return Bundle(task: task, files: files, receipts: receipts, identities: identities)
        }
        var tokenOwners: [String: [String]] = [:], identities: [Identity] = []
        var hasClosedCancellation = false
        let identity = ["taskID", "threadID", "turnID", "runtimeGeneration", "provider", "modelID", "inferenceID"]
        for (inference, rows) in groups {
            guard Self.uuid(inference), let first = rows.first,
                  rows.allSatisfy({ row in identity.allSatisfy { row[$0] as? String == first[$0] as? String } }),
                  ["threadID", "turnID", "runtimeGeneration"].allSatisfy({ Self.uuid(first[$0] as? String ?? "") }) else { throw Failure.unavailable }
            let tokens = Set(rows.compactMap { $0["sessionToken"] as? String })
            guard tokens.count == 1, let token = tokens.first, Self.uuid(token) else { throw Failure.unavailable }
            tokenOwners[token, default: []].append(inference)
        }
        let hasRetainedLease = tokenOwners.values.contains(where: { $0.count > 1 })
        if hasRetainedLease { try Self.requireUnambiguous(files) }
        for (token, inferences) in tokenOwners {
            if inferences.count > 1 {
                let members = Set(inferences)
                identities += try Self.retainedIdentities(evidence.filter { members.contains($0["inferenceID"] as? String ?? "") },
                    receipts: receipts.filter { members.contains($0.inferenceID ?? "") }, token: token)
                continue
            }
            // Each independent lease must supply its own terminal evidence
            // and bound cleanup receipt.
            let inference = inferences[0], rows = groups[inference]!, first = rows[0]
            let matching = receipts.filter { $0.inferenceID == inference }
            guard rows.contains(where: { $0["phase"] as? String == "started" }), let receipt = matching.first else { throw Failure.unavailable }
            let binding = try Self.binding(receipt)
            guard matching.allSatisfy({ (try? Self.binding($0)) == binding }),
                  matching.allSatisfy({ receipt in
                      let encoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
                      return identity.allSatisfy { encoded?[$0] as? String == first[$0] as? String } && receipt.sessionToken == token
                  }), let closed = matching.last, closed.outcome == .closed,
                  rows.allSatisfy({ ($0["timestamp"] as? String).map { $0 <= closed.timestamp } == true || $0["phase"] as? String == "release_verified" }),
                  matching.allSatisfy({ $0.timestamp <= closed.timestamp }) else { throw Failure.unavailable }
            let hasTerminalEvidence = rows.contains(where: { $0["phase"] as? String == "failed" ||
                ($0["phase"] as? String == "release_verified" && $0["cleanupAttemptID"] as? String == closed.attemptID) })
            if !hasTerminalEvidence {
                guard matching.count == 1, Self.isClosedCancellation(rows, receipt: closed) else { throw Failure.unavailable }
                hasClosedCancellation = true
            }
        }
        if hasClosedCancellation && !hasRetainedLease { try Self.requireUnambiguous(files) }
        for receipt in receipts {
            let binding = try Self.binding(receipt)
            identities.append(Identity(kind: "inference", id: receipt.inferenceID!, binding: binding))
            identities.append(Identity(kind: "token", id: receipt.sessionToken!, binding: binding))
        }
        try validateSummary(task, receipts: receipts, requireUnambiguous: hasRetainedLease || hasClosedCancellation)
        return Bundle(task: task, files: files, receipts: receipts, identities: identities)
    }

    /// Native cancellation can end an acquired lease without producing a
    /// failed or released response. Only the exact automatic cleanup of a
    /// temporary per-inference lease supplies closure for this phase shape.
    private static func isClosedCancellation(_ rows: [[String: Any]], receipt: WebsiteSessionCleanupReceipt) -> Bool {
        guard receipt.route == .embedded, receipt.trigger == .automatic, receipt.reason == .notCreated,
              receipt.cleanupDiagnostic == nil, let token = receipt.sessionToken, timestamp(receipt.timestamp),
              let preparation = rows.first?["preparationID"] as? String, uuid(preparation) else { return false }
        let phases = rows.compactMap { $0["phase"] as? String }
        guard phases.count == rows.count, phases == ["start_requested", "started", "cancelled"] ||
            phases == ["start_requested", "started", "submission_verified", "cancelled"] else { return false }
        let baseKeys: Set<String> = ["taskID", "threadID", "turnID", "runtimeGeneration", "preparationID", "provider",
            "modelID", "inferenceID", "schemaVersion", "phase", "timestamp", "sequence", "baselineResponseCount",
            "transactionMode", "transactionVersion", "transactionPolicyEstablished"]
        var previousTime: String?
        for (index, row) in rows.enumerated() {
            let phase = phases[index]
            var keys = baseKeys
            if index > 0 { keys.insert("sessionToken") }
            if phase == "cancelled" { keys.insert("errorCode") }
            if phase == "submission_verified" { keys.formUnion(["documentGeneration", "firstUserFingerprint", "modelEvidence", "responseCount"]) }
            guard Set(row.keys) == keys, row["preparationID"] as? String == preparation,
                  integer(row["schemaVersion"]) == 2, integer(row["sequence"]) == (index < 2 ? 0 : 1),
                  integer(row["baselineResponseCount"]) == 0, row["transactionMode"] as? String == "temporary_conversation_per_inference",
                  integer(row["transactionVersion"]) == 1, boolean(row["transactionPolicyEstablished"]) == true,
                  index == 0 || row["sessionToken"] as? String == token,
                  let time = row["timestamp"] as? String, timestamp(time), time <= receipt.timestamp,
                  previousTime.map({ $0 <= time }) ?? true else { return false }
            if phase == "cancelled", row["errorCode"] as? String != "internal_error" { return false }
            if phase == "submission_verified" {
                guard integer(row["responseCount"]) == 0,
                      let generation = row["documentGeneration"] as? String, uuid(generation),
                      let fingerprint = row["firstUserFingerprint"] as? String, hash(fingerprint),
                      let evidence = row["modelEvidence"] as? [String: Any], Set(evidence.keys) == ["selected", "source", "verification"],
                      let provider = receipt.provider,
                      (try? WebsiteModelEvidence.parse(evidence, provider: provider.rawValue)) != nil else { return false }
            }
            previousTime = time
        }
        return true
    }

    // Summary-only unresolved evidence remains live unless the same acquired
    // inference has a saved closure. A precreation receipt supplies no closure.
    private func validateSummary(_ task: String, receipts: [WebsiteSessionCleanupReceipt], requireUnambiguous: Bool) throws {
        let summary = cleanupDirectory.appendingPathComponent(task + ".jsonl")
        if Self.exists(summary) {
            let data = try Self.read(summary, maximum: 65_536)
            guard data.last == 10 else { throw Failure.unavailable }
            let precreation = receipts.filter(\.isPrecreationRejectionLinked)
            let attempts = Dictionary(uniqueKeysWithValues: precreation.map { ($0.attemptID, $0) })
            let inferences = Dictionary(uniqueKeysWithValues: precreation.compactMap { receipt in
                receipt.inferenceID.map { ($0, receipt) }
            })
            var seen = Set<String>()
            for line in data.split(separator: 10) {
                if requireUnambiguous { _ = try WebsiteTurnContinuation.canonicalValueDataForDigest(Data(line)) }
                let receipt = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: Data(line))
                guard receipt.isValid, receipt.taskID == task else { throw Failure.unavailable }
                if !precreation.isEmpty {
                    guard seen.insert(receipt.attemptID).inserted,
                          attempts[receipt.attemptID].map({ $0 == receipt }) ?? true,
                          inferences[receipt.inferenceID ?? ""].map({ $0 == receipt }) ?? true else {
                        throw Failure.unavailable
                    }
                }
                if receipt.outcome == .unconfirmed {
                    guard receipt.isTransactionLinked, receipts.contains(where: {
                        $0.outcome == .closed && $0.timestamp >= receipt.timestamp && (try? Self.binding($0)) == (try? Self.binding(receipt))
                    }) else { throw Failure.unavailable }
                }
            }
        }
    }

    private static func requireUnambiguous(_ files: [File]) throws {
        for file in files {
            for line in file.bytes.dropLast().split(separator: 10) {
                _ = try WebsiteTurnContinuation.canonicalValueDataForDigest(Data(line))
            }
        }
    }

    /// Only the native pre-Start rejection shape carries exact absence proof.
    /// A tokenless attempted Start by itself may still have acquired a session.
    private static func precreationIdentities(_ groups: [String: [[String: Any]]],
                                              receipts: [WebsiteSessionCleanupReceipt]) throws -> [Identity] {
        guard receipts.count == groups.count, Set(receipts.compactMap(\.inferenceID)).count == groups.count else {
            throw Failure.unavailable
        }
        let failureCodes: Set<String> = ["website_verification_required", "sign_in_required",
            "website_usage_limit", "local_website_session_capacity"]
        return try receipts.map { receipt in
            guard receipt.isPrecreationRejectionLinked, let inference = receipt.inferenceID, let thread = receipt.threadID,
                  let turn = receipt.turnID, let provider = receipt.provider, let model = receipt.modelID,
                  let rows = groups[inference], rows.count == 2, let preparation = rows[0]["preparationID"] as? String,
                  uuid(preparation), rows[0]["phase"] as? String == "start_requested",
                  rows[1]["phase"] as? String == "failed",
                  let failure = rows[1]["errorCode"] as? String,
                  failureCodes.contains(failure) || provider == .chatgpt && failure == "chatgpt_profile_preparation_failed",
                  let start = rows[0]["timestamp"] as? String, let end = rows[1]["timestamp"] as? String,
                  [start, receipt.timestamp, end].allSatisfy(timestamp), start <= receipt.timestamp, receipt.timestamp <= end else {
                throw Failure.unavailable
            }
            let scope = ["taskID": receipt.taskID, "threadID": thread, "turnID": turn, "provider": provider.rawValue,
                "modelID": model, "runtimeGeneration": receipt.runtimeGeneration, "inferenceID": inference, "preparationID": preparation]
            let keys = Set(scope.keys).union(["schemaVersion", "phase", "timestamp", "sequence", "baselineResponseCount",
                "transactionMode", "transactionVersion", "transactionPolicyEstablished"])
            guard Set(rows[0].keys) == keys, Set(rows[1].keys) == keys.union(["errorCode"]),
                  precreationPolicy(rows, provider: provider),
                  rows.allSatisfy({ row in
                      scope.allSatisfy { row[$0.key] as? String == $0.value }
                          && integer(row["schemaVersion"]) == 2 && integer(row["sequence"]) == 0
                          && integer(row["baselineResponseCount"]) == 0
                  }) else { throw Failure.unavailable }
            // The inference index rejects a later lease or altered receipt
            // for this identity. The attempt index still permits exact retries.
            let binding = try strings(["precreation_v1", receipt.taskID, thread, turn, receipt.runtimeGeneration,
                preparation, provider.rawValue, model, inference])
            return Identity(kind: "inference", id: inference, binding: binding)
        }
    }

    private static func precreationPolicy(_ rows: [[String: Any]], provider: WebsiteSessionCleanupReceipt.Provider) -> Bool {
        let perTurn = "temporary_conversation_per_turn", perInference = "temporary_conversation_per_inference"
        func matches(_ row: [String: Any], _ mode: String, _ version: Int, _ established: Bool = true) -> Bool {
            row["transactionMode"] as? String == mode && integer(row["transactionVersion"]) == version
                && boolean(row["transactionPolicyEstablished"]) == established
        }
        func both(_ mode: String, _ version: Int) -> Bool { rows.allSatisfy { matches($0, mode, version) } }
        switch provider {
        case .chatgpt:
            // Start records its requested policy. A rejected Start has no
            // lease capability, so the failure records capability_pending.
            return (matches(rows[0], perInference, 1) || matches(rows[0], perTurn, 2))
                && matches(rows[1], "capability_pending", 0, false)
        case .gemini: return both(perTurn, 2)
        case .claude: return both(perInference, 1) || both(perTurn, 2)
        case .groq: return both("explicit_clear_per_inference", 1)
        case .kimi, .qwen, .deepseek: return both("saved_conversation_delete_per_inference", 1)
        }
    }

    /// Only the exact successful v2 retained-lease serialization is admitted
    /// here. Failed, uncertain, incomplete or unfamiliar phase shapes stay live.
    /// This proves one physical close, not a cleanup receipt for every member.
    private static func retainedIdentities(_ rows: [[String: Any]], receipts: [WebsiteSessionCleanupReceipt],
                                           token: String) throws -> [Identity] {
        let groups = Dictionary(grouping: rows) { $0["inferenceID"] as? String ?? "" }
        var order: [String] = []
        for row in rows {
            let id = row["inferenceID"] as? String ?? ""
            if order.last != id { guard !order.contains(id) else { throw Failure.unavailable }; order.append(id) }
        }
        guard (2...1_024).contains(order.count), let first = rows.first, let finalID = order.last,
              let closed = receipts.last, !receipts.isEmpty,
              receipts.allSatisfy({ $0.inferenceID == finalID && $0.outcome == .closed && $0.route == .embedded && $0.trigger == .inference }),
              receipts.allSatisfy({ (try? binding($0)) == (try? binding(closed)) && $0.timestamp <= closed.timestamp }),
              closed.sessionToken == token else { throw Failure.unavailable }
        let scope = ["taskID", "threadID", "turnID", "runtimeGeneration", "preparationID", "provider", "modelID"]
        guard ["taskID", "threadID", "turnID", "runtimeGeneration", "preparationID"].allSatisfy({ uuid(first[$0] as? String ?? "") }),
              let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(closed)) as? [String: Any],
              scope.filter({ $0 != "preparationID" }).allSatisfy({ encoded[$0] as? String == first[$0] as? String }),
              timestamp(closed.timestamp) else { throw Failure.unavailable }
        var document: String?, fingerprint: String?, previousTime: String?
        for (offset, inference) in order.enumerated() {
            guard uuid(inference), let group = groups[inference] else { throw Failure.unavailable }
            let sequence = offset + 1
            let expected = [offset == 0 ? "start_requested" : "continuation_requested",
                offset == 0 ? "started" : "continued", "submission_verified", "complete",
                offset == order.count - 1 ? "release_verified" : "yield_verified"]
            guard group.count == 5, group.compactMap({ $0["phase"] as? String }) == expected else { throw Failure.unavailable }
            var completedSubmission: String?
            for (index, row) in group.enumerated() {
                guard scope.allSatisfy({ row[$0] as? String == first[$0] as? String }),
                      integer(row["schemaVersion"]) == 2, integer(row["transactionVersion"]) == 2,
                      boolean(row["transactionPolicyEstablished"]) == true,
                      row["transactionMode"] as? String == "temporary_conversation_per_turn",
                      integer(row["sequence"]) == (offset == 0 && index < 2 ? 0 : sequence),
                      integer(row["baselineResponseCount"]) == offset,
                      let time = row["timestamp"] as? String, timestamp(time), previousTime.map({ $0 <= time }) ?? true,
                      index == 4 && offset == order.count - 1 || time <= closed.timestamp,
                      row["sessionToken"] as? String == token || offset == 0 && index == 0 && row["sessionToken"] == nil,
                      row["errorCode"] == nil else { throw Failure.unavailable }
                previousTime = time
                if index < 2 {
                    guard ["documentGeneration", "firstUserFingerprint", "responseCount", "submittedPromptFingerprint"]
                        .allSatisfy({ row[$0] == nil }) else { throw Failure.unavailable }
                }
                if index >= 2 {
                    guard integer(row["responseCount"]) == (index == 2 ? offset : sequence),
                          let currentDocument = row["documentGeneration"] as? String, uuid(currentDocument),
                          let currentFingerprint = row["firstUserFingerprint"] as? String, hash(currentFingerprint),
                          document.map({ $0 == currentDocument }) ?? true,
                          fingerprint.map({ $0 == currentFingerprint }) ?? true else { throw Failure.unavailable }
                    document = currentDocument; fingerprint = currentFingerprint
                }
                if index >= 3 {
                    guard let submitted = row["submittedPromptFingerprint"] as? String, hash(submitted),
                          completedSubmission.map({ $0 == submitted }) ?? true else { throw Failure.unavailable }
                    completedSubmission = submitted
                } else if let submitted = row["submittedPromptFingerprint"] as? String {
                    guard submitted.isEmpty || hash(submitted) else { throw Failure.unavailable }
                }
                if offset == order.count - 1 && index == 4 {
                    guard row["cleanupAttemptID"] as? String == closed.attemptID, time >= closed.timestamp else { throw Failure.unavailable }
                } else { guard row["cleanupAttemptID"] == nil else { throw Failure.unavailable } }
            }
            guard group.allSatisfy({ row in
                guard let submitted = row["submittedPromptFingerprint"] as? String, !submitted.isEmpty else { return true }
                return submitted == completedSubmission
            }) else { throw Failure.unavailable }
        }
        guard let finalGroup = groups[finalID], let completed = finalGroup[3]["timestamp"] as? String,
              let released = finalGroup[4]["timestamp"] as? String,
              receipts.allSatisfy({ timestamp($0.timestamp) && completed <= $0.timestamp && $0.timestamp <= released }) else { throw Failure.unavailable }
        let final = try binding(closed)
        guard let parts = try JSONSerialization.jsonObject(with: final) as? [String], parts.count == 9 else { throw Failure.unavailable }
        var result = try order.map { inference -> Identity in
            var member = parts; member[7] = inference
            return Identity(kind: "inference", id: inference, binding: try strings(member))
        }
        // New tagged rows use the existing identities table. The ordinary token
        // row remains anchored to the actual final cleanup, never overwritten.
        let relation = ["retained_token_v1"] + Array(parts.prefix(7)) + [token] + order
        result.append(Identity(kind: "retained_token_v1", id: token, binding: try strings(relation)))
        return result
    }

    private static func retainedToken(_ data: Data, permits binding: Data, anchoredBy anchor: Data) throws -> Bool {
        guard let relation = try JSONSerialization.jsonObject(with: data) as? [String],
              (11...1_033).contains(relation.count), relation[0] == "retained_token_v1",
              let own = try JSONSerialization.jsonObject(with: binding) as? [String], own.count == 9 else { return false }
        let members = Array(relation.dropFirst(9))
        guard members.allSatisfy(uuid), Set(members).count == members.count,
              Array(relation[1...7]) == Array(own.prefix(7)), relation[8] == own[8], members.contains(own[7]),
              let final = members.last else { return false }
        var expected = own; expected[7] = final
        return try strings(expected) == anchor
    }

    private static func strings(_ values: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), NSNumber(value: integer) == number else { return nil }
        return integer
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func timestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
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
                    try execute(db, "INSERT INTO receipts(attempt,bytes) VALUES(?,?)", [receipt.attemptID, try JSONEncoder().encode(receipt)])
                }
                for identity in bundle.identities {
                    if let old = try query(db, "SELECT binding FROM identities WHERE kind=? AND id=?", [identity.kind, identity.id]).first?.first {
                        guard old == identity.binding else { throw Failure.unavailable }
                    } else { try execute(db, "INSERT INTO identities(kind,id,binding) VALUES(?,?,?)", [identity.kind, identity.id, identity.binding]) }
                }
                try archiveLatest(bundle, db: db)
                try execute(db, "COMMIT")
            } catch { try? execute(db, "ROLLBACK"); throw error }
        }
        #if DEBUG
        try fault?(.committed)
        #endif
        try recover(evidenceDirectory: evidenceDirectory, protectedTaskIDs: [])
    }

    private func archiveLatest(_ bundle: Bundle, db: OpaquePointer) throws {
        guard let latest = bundle.receipts.filter({ $0.outcome == .closed || $0.isPrecreationRejectionLinked })
            .max(by: { ($0.timestamp, $0.attemptID) < ($1.timestamp, $1.attemptID) }) else { throw Failure.unavailable }
        let table: String
        if latest.isPrecreationRejectionLinked {
            // Older app versions read only closed receipts from `latest`.
            try execute(db, "CREATE TABLE IF NOT EXISTS precreation_latest(task TEXT PRIMARY KEY,timestamp TEXT NOT NULL,bytes BLOB NOT NULL)")
            table = "precreation_latest"
        } else { table = "latest" }
        try execute(db, "INSERT INTO \(table)(task,timestamp,bytes) VALUES(?,?,?) ON CONFLICT(task) DO UPDATE SET timestamp=excluded.timestamp,bytes=excluded.bytes WHERE excluded.timestamp>=\(table).timestamp",
                    [bundle.task, latest.timestamp, try JSONEncoder().encode(latest)])
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

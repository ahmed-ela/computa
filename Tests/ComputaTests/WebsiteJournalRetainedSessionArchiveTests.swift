import Foundation
import SQLite3
import XCTest
@testable import Computa

final class WebsiteJournalRetainedSessionArchiveTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let evidence: URL
        let cleanup: URL
        let receipt: WebsiteSessionCleanupReceipt
        let inferences: [String]
        var rows: [[String: Any]]
        var retention: WebsiteJournalRetentionStore {
            var result = WebsiteJournalRetentionStore(cleanupDirectory: cleanup)
            result.limits.activeTasks = 1
            return result
        }
        var store: WebsiteSessionCleanupStore { WebsiteSessionCleanupStore(directory: cleanup) }
        var evidenceFile: URL { evidence.appendingPathComponent("transactions/" + receipt.taskID + "/" + receipt.turnID! + ".jsonl") }
        var cleanupFile: URL { cleanup.appendingPathComponent("transactions/" + receipt.taskID + "/" + receipt.turnID! + ".jsonl") }
    }
    private func id() -> String { UUID().uuidString.lowercased() }
    private func changed(_ receipt: WebsiteSessionCleanupReceipt, _ changes: [String: Any]) throws -> WebsiteSessionCleanupReceipt {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        for (key, value) in changes { object[key] = value }
        return try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func encoded(_ rows: [[String: Any]]) throws -> Data {
        var result = Data()
        for row in rows { result.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); result.append(10) }
        return result
    }
    private func write(_ fixture: Fixture) throws { try encoded(fixture.rows).write(to: fixture.evidenceFile) }
    private func fixture(members: Int = 3) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RetainedJournal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let evidence = root.appendingPathComponent("evidence"), cleanup = root.appendingPathComponent("cleanup")
        let task = id(), thread = id(), turn = id(), generation = UUID(), preparation = id(), token = id(), document = id()
        let inferences = (0..<members).map { _ in id() }
        let initial = WebsiteSessionCleanupReceipt(taskID: task, threadID: thread, turnID: turn,
            runtimeGeneration: generation, outcome: .closed, provider: .gemini, route: .embedded,
            modelID: "browser/gemini", reason: .notCreated, trigger: .inference, receiptSaved: true,
            inferenceID: inferences.last!, sessionToken: token)
        let close = String(format: "2026-11-09T00:00:%02d.500Z", members * 10 - 3)
        let receipt = try changed(initial, ["timestamp": close])
        XCTAssertTrue(WebsiteSessionCleanupStore(directory: cleanup).save(receipt))
        let directory = evidence.appendingPathComponent("transactions/" + task)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for (offset, inference) in inferences.enumerated() {
            let sequence = offset + 1
            let phases = [offset == 0 ? "start_requested" : "continuation_requested",
                offset == 0 ? "started" : "continued", "submission_verified", "complete",
                offset == members - 1 ? "release_verified" : "yield_verified"]
            for (index, phase) in phases.enumerated() {
                var row: [String: Any] = ["schemaVersion": 2, "taskID": task, "threadID": thread, "turnID": turn,
                    "runtimeGeneration": generation.uuidString.lowercased(), "preparationID": preparation,
                    "provider": "gemini", "modelID": "browser/gemini", "inferenceID": inference,
                    "phase": phase, "timestamp": String(format: "2026-11-09T00:00:%02d.000Z", rows.count * 2),
                    "transactionMode": "temporary_conversation_per_turn", "transactionVersion": 2,
                    "transactionPolicyEstablished": true, "sequence": offset == 0 && index < 2 ? 0 : sequence,
                    "baselineResponseCount": offset]
                if offset != 0 || index != 0 { row["sessionToken"] = token }
                if index >= 2 {
                    row["documentGeneration"] = document
                    row["firstUserFingerprint"] = String(repeating: "a", count: 64)
                    row["responseCount"] = index == 2 ? offset : sequence
                    row["submittedPromptFingerprint"] = index == 2 ? "" : String(repeating: String(sequence), count: 64)
                }
                if phase == "release_verified" { row["cleanupAttemptID"] = receipt.attemptID }
                rows.append(row)
            }
        }
        let result = Fixture(root: root, evidence: evidence, cleanup: cleanup, receipt: receipt, inferences: inferences, rows: rows)
        try write(result)
        return result
    }
    private func archive(_ fixture: Fixture) throws {
        try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.evidenceFile.path))
    }
    private func db(_ fixture: Fixture, _ sql: String) throws -> [[Data]] {
        var raw: OpaquePointer?
        let path = fixture.cleanup.appendingPathComponent("closed-journals.sqlite").path
        guard sqlite3_open(path, &raw) == SQLITE_OK, let handle = raw else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        var result: [[Data]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
            var row: [Data] = []
            for index in 0..<sqlite3_column_count(statement) {
                let count = Int(sqlite3_column_bytes(statement, index))
                if count == 0 { row.append(Data()) }
                else { row.append(Data(bytes: try XCTUnwrap(sqlite3_column_blob(statement, index)), count: count)) }
            }
            result.append(row)
        }
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func identity(_ fixture: Fixture, inference: String) throws -> Data {
        try XCTUnwrap(db(fixture, "SELECT binding FROM identities WHERE kind='inference' AND id='" + inference + "'").first?.first)
    }

    func testClosedRetainedChainArchivesExactFilesAndAllInferenceIdentitiesWithoutInventingReceipts() throws {
        let fixture = try fixture(), evidence = try Data(contentsOf: fixture.evidenceFile), cleanup = try Data(contentsOf: fixture.cleanupFile)
        try archive(fixture)
        let reopened = WebsiteJournalRetentionStore(cleanupDirectory: fixture.cleanup)
        let evidenceBytes = try reopened.withWriterLock { try reopened.archivedBytes(store: "evidence", taskID: fixture.receipt.taskID, turnID: fixture.receipt.turnID!) }
        let cleanupBytes = try reopened.withWriterLock { try reopened.archivedBytes(store: "cleanup", taskID: fixture.receipt.taskID, turnID: fixture.receipt.turnID!) }
        XCTAssertEqual(evidenceBytes, evidence); XCTAssertEqual(cleanupBytes, cleanup)
        XCTAssertEqual(try fixture.store.transactionRecords(for: fixture.receipt.taskID, turnID: fixture.receipt.turnID!), [fixture.receipt])
        XCTAssertTrue(fixture.store.latest().contains(fixture.receipt)); XCTAssertTrue(fixture.store.save(fixture.receipt))
        XCTAssertEqual(try db(fixture, "PRAGMA user_version"), [[Data("1".utf8)]])
        XCTAssertEqual(try db(fixture, "SELECT count(*) FROM receipts"), [[Data("1".utf8)]])
        XCTAssertEqual(try db(fixture, "SELECT count(*) FROM identities"), [[Data(String(fixture.inferences.count + 2).utf8)]])
        for inference in fixture.inferences {
            let binding = try XCTUnwrap(JSONSerialization.jsonObject(with: identity(fixture, inference: inference)) as? [String])
            XCTAssertEqual(binding, [fixture.receipt.taskID, fixture.receipt.threadID!, fixture.receipt.turnID!, fixture.receipt.runtimeGeneration,
                "gemini", "embedded", "browser/gemini", inference, fixture.receipt.sessionToken!])
        }
        let earlier = try changed(fixture.receipt, ["attemptID": id(), "inferenceID": fixture.inferences[0]])
        XCTAssertFalse(try reopened.withWriterLock { try reopened.validateCleanupIdentity(earlier) }, "Relation compatibility is not an invented cleanup receipt")
        XCTAssertFalse(fixture.store.save(earlier), "Archived native turns remain immutable")
        XCTAssertEqual(try fixture.store.transactionRecords(for: fixture.receipt.taskID, turnID: fixture.receipt.turnID!), [fixture.receipt])
    }

    func testRetainedIdentityExceptionRequiresOwnIndexRelationAndExactFinalTokenAnchor() throws {
        let fixture = try fixture(); try archive(fixture)
        let inference = fixture.inferences[0], own = try identity(fixture, inference: inference)
        let earlier = try changed(fixture.receipt, ["attemptID": id(), "inferenceID": inference])
        let relation = try XCTUnwrap(db(fixture, "SELECT binding FROM identities WHERE kind='retained_token_v1'").first?.first)
        _ = try db(fixture, "DELETE FROM identities WHERE kind='inference' AND id='" + inference + "'")
        XCTAssertThrowsError(try fixture.retention.withWriterLock { try fixture.retention.validateCleanupIdentity(earlier) })
        _ = try db(fixture, "INSERT INTO identities VALUES('inference','" + inference + "',X'" + hex(own) + "')")
        _ = try db(fixture, "DELETE FROM identities WHERE kind='retained_token_v1'")
        XCTAssertThrowsError(try fixture.retention.withWriterLock { try fixture.retention.validateCleanupIdentity(earlier) })
        _ = try db(fixture, "INSERT INTO identities VALUES('retained_token_v1','" + fixture.receipt.sessionToken! + "',X'" + hex(relation) + "')")
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: relation) as? [String]); values[values.count - 1] = id()
        let bad = try JSONSerialization.data(withJSONObject: values)
        _ = try db(fixture, "UPDATE identities SET binding=X'" + hex(bad) + "' WHERE kind='retained_token_v1'")
        XCTAssertThrowsError(try fixture.retention.withWriterLock { try fixture.retention.validateCleanupIdentity(earlier) })
    }

    func testArchivedRetainedMembersRejectAllCrossScopeOrUnknownIdentityRebindings() throws {
        let fixture = try fixture(); try archive(fixture)
        for field in ["taskID", "threadID", "turnID", "runtimeGeneration", "sessionToken", "inferenceID"] {
            var changes: [String: Any] = ["attemptID": id(), "inferenceID": fixture.inferences[0]]
            changes[field] = id()
            let foreign = try changed(fixture.receipt, changes)
            XCTAssertFalse(fixture.store.save(foreign), field)
        }
        for changes in [["attemptID": id(), "inferenceID": fixture.inferences[0], "provider": "chatgpt", "modelID": "browser/chatgpt"],
                        ["attemptID": id(), "inferenceID": fixture.inferences[0], "route": "chrome"]] {
            XCTAssertFalse(fixture.store.save(try changed(fixture.receipt, changes)))
        }
        let sameBindingNewAttempt = try changed(fixture.receipt, ["attemptID": id()])
        XCTAssertFalse(try fixture.retention.withWriterLock { try fixture.retention.validateCleanupIdentity(sameBindingNewAttempt) })
        XCTAssertFalse(fixture.store.save(sameBindingNewAttempt))
    }

    func testConflictingArchivedPhysicalTokenRollsBackEveryNewIndexAndRawFile() throws {
        let prior = try fixture(); try archive(prior)
        let next = try fixture()
        let colliding = try changed(next.receipt, ["sessionToken": prior.receipt.sessionToken!])
        var rows = next.rows
        for index in rows.indices where rows[index]["sessionToken"] != nil { rows[index]["sessionToken"] = prior.receipt.sessionToken! }
        let candidate = Fixture(root: next.root, evidence: next.evidence, cleanup: next.cleanup,
            receipt: colliding, inferences: next.inferences, rows: rows)
        try write(candidate)
        var rawReceipt = try JSONEncoder().encode(colliding); rawReceipt.append(10)
        try rawReceipt.write(to: candidate.cleanupFile)
        try rawReceipt.write(to: candidate.cleanup.appendingPathComponent(colliding.taskID + ".jsonl"))
        try FileManager.default.copyItem(at: prior.cleanup.appendingPathComponent("closed-journals.sqlite"),
            to: candidate.cleanup.appendingPathComponent("closed-journals.sqlite"))
        let original = try Data(contentsOf: candidate.evidenceFile)
        XCTAssertThrowsError(try candidate.retention.admit(taskID: id(), evidenceDirectory: candidate.evidence, protectedTaskIDs: []))
        XCTAssertEqual(try Data(contentsOf: candidate.evidenceFile), original)
        XCTAssertEqual(try Data(contentsOf: candidate.cleanupFile), rawReceipt)
        XCTAssertEqual(try db(candidate, "SELECT task FROM operations WHERE task='" + colliding.taskID + "'"), [])
        XCTAssertEqual(try db(candidate, "SELECT bytes FROM files WHERE task='" + colliding.taskID + "'"), [])
        XCTAssertEqual(try db(candidate, "SELECT bytes FROM receipts WHERE attempt='" + colliding.attemptID + "'"), [])
        XCTAssertEqual(try db(candidate, "SELECT bytes FROM latest WHERE task='" + colliding.taskID + "'"), [])
        for inference in candidate.inferences {
            XCTAssertEqual(try db(candidate, "SELECT binding FROM identities WHERE kind='inference' AND id='" + inference + "'"), [])
        }
        XCTAssertEqual(try candidate.store.transactionRecords(for: prior.receipt.taskID, turnID: prior.receipt.turnID!), [prior.receipt])
    }

    func testMalformedOrIncompleteRetainedChainsRemainLiveAtCapacity() throws {
        let mutations: [(String, (inout [[String: Any]]) -> Void)] = [
            ("metadata_document", { $0[5]["documentGeneration"] = self.id() }),
            ("metadata_count", { $0[5]["responseCount"] = 999 }),
            ("metadata_first_body", { $0[6]["firstUserFingerprint"] = String(repeating: "b", count: 64) }),
            ("metadata_submission", { $0[6]["submittedPromptFingerprint"] = String(repeating: "b", count: 64) }),
            ("missing_yield", { $0.remove(at: 4) }), ("missing_continued", { $0.remove(at: 6) }),
            ("missing_release", { $0.removeLast() }), ("duplicate_phase", { $0.insert($0[4], at: 5) }),
            ("unknown_phase", { $0[4]["phase"] = "finished" }),
            ("token", { $0[8]["sessionToken"] = self.id() }),
            ("document", { $0[8]["documentGeneration"] = self.id() }),
            ("first_body", { $0[8]["firstUserFingerprint"] = String(repeating: "b", count: 64) }),
            ("submission", { $0[8]["submittedPromptFingerprint"] = String(repeating: "b", count: 64) }),
            ("preparation", { $0[8]["preparationID"] = self.id() }),
            ("runtime", { $0[8]["runtimeGeneration"] = self.id() }),
            ("model", { $0[8]["modelID"] = "browser/chatgpt" }),
            ("sequence", { $0[6]["sequence"] = 3 }), ("sequence_bool", { $0[2]["sequence"] = true }),
            ("baseline_bool", { $0[6]["baselineResponseCount"] = true }),
            ("response_bool", { $0[3]["responseCount"] = true }),
            ("version_bool", { $0[2]["transactionVersion"] = true }),
            ("policy_integer", { $0[2]["transactionPolicyEstablished"] = 1 }),
            ("v1", { $0[2]["transactionVersion"] = 1 }),
            ("other_policy", { $0[2]["transactionMode"] = "temporary_conversation_per_inference" }),
            ("time", { $0[8]["timestamp"] = "2026-11-09T00:00:00.000Z" }),
            ("invalid_time", { $0[8]["timestamp"] = "not-a-date" }),
            ("failed", { $0[8]["phase"] = "failed"; $0[8]["errorCode"] = "provider_timeout" }),
            ("receipt_link", { $0[$0.count - 1]["cleanupAttemptID"] = self.id() })]
        for (name, mutation) in mutations {
            var fixture = try fixture(); mutation(&fixture.rows); try write(fixture)
            let before = try Data(contentsOf: fixture.evidenceFile), cleanup = try Data(contentsOf: fixture.cleanupFile)
            XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: []), name)
            XCTAssertEqual(try Data(contentsOf: fixture.evidenceFile), before, name)
            XCTAssertEqual(try Data(contentsOf: fixture.cleanupFile), cleanup, name)
        }
    }

    func testDuplicateEvidenceAndCleanupKeysCannotHideAnUncertainRetainedChain() throws {
        for store in ["evidence", "cleanup", "summary"] {
            for uncertainFirst in [false, true] {
                let fixture = try fixture()
                let file = store == "evidence" ? fixture.evidenceFile : store == "cleanup" ? fixture.cleanupFile
                    : fixture.cleanup.appendingPathComponent(fixture.receipt.taskID + ".jsonl")
                let original = try String(contentsOf: file, encoding: .utf8)
                let key = store == "evidence" ? "phase" : "outcome"
                let values = store == "evidence" ? ["failed", "yield_verified"] : ["unconfirmed", "closed"]
                let ordered = uncertainFirst ? values : Array(values.reversed())
                let needle = "\"\(key)\":\"\(values[1])\""
                let replacement = "\"\(key)\":\"\(ordered[0])\",\"\(key)\":\"\(ordered[1])\""
                XCTAssertTrue(original.contains(needle))
                let ambiguous = Data(original.replacingOccurrences(of: needle, with: replacement).utf8)
                try ambiguous.write(to: file)
                XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: []), store)
                XCTAssertEqual(try Data(contentsOf: file), ambiguous, store)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.evidenceFile.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cleanupFile.path))
            }
        }
    }

    func testUnconfirmedCleanupOrSummaryAndProtectedRetainedHistoryCannotBeRetired() throws {
        for mode in ["transaction", "earlier_summary", "protected"] {
            let fixture = try fixture()
            if mode == "transaction" {
                let unresolved = try changed(fixture.receipt, ["attemptID": id(), "timestamp": "2026-11-09T00:00:29.000Z", "outcome": "unconfirmed", "reason": "cleanup_unverified"])
                XCTAssertTrue(fixture.store.save(unresolved))
            } else if mode == "earlier_summary" {
                let unresolved = try changed(fixture.receipt, ["attemptID": id(), "inferenceID": fixture.inferences[0], "outcome": "unconfirmed", "reason": "cleanup_unverified"])
                var bytes = try JSONEncoder().encode(unresolved); bytes.append(10)
                try bytes.write(to: fixture.cleanup.appendingPathComponent(fixture.receipt.taskID + ".jsonl"))
            }
            let before = try Data(contentsOf: fixture.evidenceFile)
            XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence,
                protectedTaskIDs: mode == "protected" ? [fixture.receipt.taskID] : []), mode)
            XCTAssertEqual(try Data(contentsOf: fixture.evidenceFile), before)
        }
    }

    func testRetainedRetirementRecoversEveryExistingDurableBoundaryWithExactBytesAndIdentityIndexes() throws {
        for point in [WebsiteJournalRetentionStore.FaultPoint.committed, .removedEvidence, .removedCleanup] {
            let fixture = try fixture(), original = try Data(contentsOf: fixture.evidenceFile), incoming = id()
            let originalCleanup = try Data(contentsOf: fixture.cleanupFile)
            var interrupted = fixture.retention
            interrupted.fault = { if $0 == point { throw CocoaError(.fileWriteUnknown) } }
            XCTAssertThrowsError(try interrupted.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: []))
            try fixture.retention.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
            let archived = try fixture.retention.withWriterLock { try fixture.retention.archivedBytes(store: "evidence", taskID: fixture.receipt.taskID, turnID: fixture.receipt.turnID!) }
            XCTAssertEqual(archived, original)
            let archivedCleanup = try fixture.retention.withWriterLock { try fixture.retention.archivedBytes(store: "cleanup", taskID: fixture.receipt.taskID, turnID: fixture.receipt.turnID!) }
            XCTAssertEqual(archivedCleanup, originalCleanup)
            for inference in fixture.inferences { XCTAssertFalse(try identity(fixture, inference: inference).isEmpty) }
            XCTAssertTrue(fixture.store.save(fixture.receipt))
            XCTAssertEqual(try fixture.store.transactionRecords(for: fixture.receipt.taskID, turnID: fixture.receipt.turnID!), [fixture.receipt])
        }
    }
}

import Darwin
import Foundation
import SQLite3
import XCTest
@testable import Computa

final class WebsiteJournalRetentionStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let evidence: URL
        let cleanup: URL
        var retention: WebsiteJournalRetentionStore {
            var value = WebsiteJournalRetentionStore(cleanupDirectory: cleanup)
            value.limits.activeTasks = 2
            return value
        }
        var store: WebsiteSessionCleanupStore { WebsiteSessionCleanupStore(directory: cleanup) }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebsiteRetention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, evidence: root.appendingPathComponent("evidence"), cleanup: root.appendingPathComponent("cleanup"))
    }
    private func id() -> String { UUID().uuidString.lowercased() }
    @discardableResult
    private func closed(_ fixture: Fixture, task: String? = nil, failed: Bool = false) throws -> WebsiteSessionCleanupReceipt {
        let task = task ?? id(), thread = id(), turn = id(), inference = id(), token = id(), generation = UUID()
        var receipt = WebsiteSessionCleanupReceipt(taskID: task, threadID: thread, turnID: turn,
            runtimeGeneration: generation, outcome: .closed, provider: .chatgpt, route: .embedded,
            modelID: "browser/chatgpt", reason: .deleted, trigger: .inference, receiptSaved: true,
            inferenceID: inference, sessionToken: token)
        receipt.receiptSaved = true
        XCTAssertTrue(fixture.store.save(receipt))
        let directory = fixture.evidence.appendingPathComponent("transactions/" + task)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base: [String: Any] = ["schemaVersion": 2, "taskID": task, "threadID": thread, "turnID": turn,
            "inferenceID": inference, "sessionToken": token, "runtimeGeneration": generation.uuidString.lowercased(),
            "provider": "chatgpt", "modelID": "browser/chatgpt", "timestamp": receipt.timestamp]
        var bytes = Data()
        for phase in ["start_requested", "started", failed ? "failed" : "complete", failed ? "failed" : "release_verified"] {
            var row = base; row["phase"] = phase
            if phase == "release_verified" { row["cleanupAttemptID"] = receipt.attemptID }
            if phase == "failed" { row["errorCode"] = "provider_timeout" }
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); bytes.append(10)
        }
        try bytes.write(to: directory.appendingPathComponent(turn + ".jsonl"))
        return receipt
    }
    private func active(_ root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("transactions").path))
    }
    private func evidence(_ fixture: Fixture, _ receipt: WebsiteSessionCleanupReceipt) -> URL {
        fixture.evidence.appendingPathComponent("transactions/" + receipt.taskID + "/" + receipt.turnID! + ".jsonl")
    }

    private func writeEvidence(_ rows: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = Data()
        for row in rows {
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            bytes.append(10)
        }
        try bytes.write(to: url)
    }

    private func unacquired(_ fixture: Fixture, task: String? = nil, thread: String? = nil,
                            unresolved: Bool = false, timestamp: String? = nil,
                            provider: WebsiteSessionCleanupReceipt.Provider = .gemini,
                            failureCode: String = "website_verification_required") throws -> WebsiteSessionCleanupReceipt {
        let modelID = syntheticWebsiteModelID(provider.rawValue)
        var receipt = WebsiteSessionCleanupReceipt(taskID: task ?? id(), threadID: thread ?? id(), turnID: id(),
            runtimeGeneration: UUID(), outcome: unresolved ? .unconfirmed : .noOwnedSession,
            provider: provider, route: .embedded, modelID: modelID,
            reason: unresolved ? .cleanupUnverified : .notCreated, trigger: .inference, receiptSaved: true, inferenceID: id())
        if let timestamp {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            value["timestamp"] = timestamp
            receipt = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertTrue(fixture.store.save(receipt))
        let start: [String: Any] = ["schemaVersion": 2, "taskID": receipt.taskID, "threadID": receipt.threadID!,
            "turnID": receipt.turnID!, "inferenceID": receipt.inferenceID!, "preparationID": id(),
            "runtimeGeneration": receipt.runtimeGeneration, "provider": provider.rawValue, "modelID": modelID,
            "timestamp": receipt.timestamp, "phase": "start_requested", "transactionMode": "temporary_conversation_per_turn",
            "transactionVersion": 2, "transactionPolicyEstablished": true, "sequence": 0, "baselineResponseCount": 0]
        var failure = start
        failure["phase"] = "failed"
        failure["errorCode"] = failureCode
        if provider == .chatgpt {
            failure["transactionMode"] = "capability_pending"
            failure["transactionVersion"] = 0
            failure["transactionPolicyEstablished"] = false
        }
        try writeEvidence([start, failure], to: evidence(fixture, receipt))
        return receipt
    }

    func testOnlyChatGPTCanArchiveAnExactPrecreationProfileFailure() throws {
        let fixture = try fixture()
        let code = "chatgpt_profile_preparation_failed"
        let foreign = try unacquired(fixture, failureCode: code)
        let chat = try unacquired(fixture, provider: .chatgpt, failureCode: code)
        let raw = try Data(contentsOf: evidence(fixture, chat))
        let incoming = id()
        try fixture.retention.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
        XCTAssertEqual(try active(fixture.evidence), [foreign.taskID, incoming])
        XCTAssertEqual(try active(fixture.cleanup), [foreign.taskID, incoming])
        XCTAssertEqual(try fixture.retention.withWriterLock {
            try fixture.retention.archivedBytes(store: "evidence", taskID: chat.taskID, turnID: chat.turnID!)
        }, raw)
        XCTAssertEqual(try fixture.store.transactionRecords(for: chat.taskID, turnID: chat.turnID!), [chat])
    }

    func testPrecreationRejectionArchivesExactBytesAndKeepsUnconfirmedStartupLive() throws {
        let fixture = try fixture(), rejected = try unacquired(fixture), uncertain = try unacquired(fixture, unresolved: true)
        let rejectedEvidence = try Data(contentsOf: evidence(fixture, rejected))
        let uncertainEvidence = try Data(contentsOf: evidence(fixture, uncertain))
        let rejectedCleanup = fixture.cleanup.appendingPathComponent("transactions/" + rejected.taskID + "/" + rejected.turnID! + ".jsonl")
        let cleanupBytes = try Data(contentsOf: rejectedCleanup)
        XCTAssertEqual(rejected.schemaVersion, 4)
        XCTAssertEqual(uncertain.schemaVersion, 3)
        let incoming = id()
        XCTAssertThrowsError(try fixture.retention.admit(taskID: incoming, evidenceDirectory: fixture.evidence,
            protectedTaskIDs: [rejected.taskID]))
        try fixture.retention.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
        XCTAssertEqual(try active(fixture.evidence), [uncertain.taskID, incoming])
        XCTAssertEqual(try active(fixture.cleanup), [uncertain.taskID, incoming])
        XCTAssertEqual(try Data(contentsOf: evidence(fixture, uncertain)), uncertainEvidence)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedCleanup.path))
        let reopened = WebsiteJournalRetentionStore(cleanupDirectory: fixture.cleanup)
        try reopened.withWriterLock {
            XCTAssertEqual(try reopened.archivedBytes(store: "evidence", taskID: rejected.taskID, turnID: rejected.turnID!), rejectedEvidence)
            XCTAssertEqual(try reopened.archivedBytes(store: "cleanup", taskID: rejected.taskID, turnID: rejected.turnID!), cleanupBytes)
            XCTAssertEqual(try reopened.latestArchived(), [rejected])
        }
        XCTAssertEqual(try fixture.store.transactionRecords(for: rejected.taskID, turnID: rejected.turnID!), [rejected])
        XCTAssertEqual(try fixture.store.transactionRecords(for: uncertain.taskID, turnID: uncertain.turnID!), [uncertain])
        XCTAssertEqual(Set(fixture.store.latest().map(\.outcome)), [.unconfirmed, .noOwnedSession])
        XCTAssertTrue(fixture.store.save(rejected))
        for outcome: WebsiteSessionCleanupReceipt.Outcome in [.noOwnedSession, .closed] {
            let rebinding = WebsiteSessionCleanupReceipt(taskID: id(), threadID: id(), turnID: id(),
                runtimeGeneration: UUID(), outcome: outcome, provider: .gemini, route: .embedded,
                modelID: "browser/gemini", reason: outcome == .closed ? .deleted : .notCreated,
                trigger: .inference, receiptSaved: true, inferenceID: rejected.inferenceID,
                sessionToken: outcome == .closed ? id() : nil)
            XCTAssertFalse(fixture.store.save(rebinding), "An archived absence proof cannot be assigned to another attempt or lease")
        }
        XCTAssertEqual(try active(fixture.cleanup), [uncertain.taskID, incoming])
    }

    func testPrecreationArchiveKeepsClosedOnlyIndexCompatibleAndRecoversCommittedMove() throws {
        let fixture = try fixture(), older = try closed(fixture), protected = try unacquired(fixture, unresolved: true)
        try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: [protected.taskID])
        try fixture.retention.admit(taskID: older.taskID, evidenceDirectory: fixture.evidence, protectedTaskIDs: [protected.taskID])
        let rejected = try unacquired(fixture, task: older.taskID, thread: older.threadID, timestamp: "2099-01-01T00:00:00.000Z")
        let raw = try Data(contentsOf: evidence(fixture, rejected))
        var interrupted = fixture.retention
        interrupted.fault = { if $0 == .committed { throw CocoaError(.fileWriteUnknown) } }
        let incoming = id()
        XCTAssertThrowsError(try interrupted.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: [protected.taskID]))
        XCTAssertEqual(try Data(contentsOf: evidence(fixture, rejected)), raw)
        try fixture.retention.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: [protected.taskID])
        XCTAssertEqual(try active(fixture.evidence), [protected.taskID, incoming])
        XCTAssertEqual(try fixture.retention.withWriterLock { try fixture.retention.archivedBytes(store: "evidence",
            taskID: rejected.taskID, turnID: rejected.turnID!) }, raw)
        XCTAssertEqual(try fixture.retention.withWriterLock { try fixture.retention.latestArchived() }, [rejected])
        XCTAssertEqual(try fixture.store.transactionRecords(for: older.taskID, turnID: older.turnID!), [older])

        var database: OpaquePointer?
        let archive = fixture.cleanup.appendingPathComponent("closed-journals.sqlite")
        XCTAssertEqual(sqlite3_open_v2(archive.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT bytes FROM latest", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let stored = Data(bytes: try XCTUnwrap(sqlite3_column_blob(statement, 0)), count: Int(sqlite3_column_bytes(statement, 0)))
        XCTAssertEqual(try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: stored), older)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testPrecreationArchiveRejectsChangedOrUnconfirmedHistory() throws {
        for fault in ["scope", "policy", "session", "extra_phase", "duplicate_key", "unconfirmed_summary", "summary_mismatch", "mixed_receipts"] {
            let fixture = try fixture(), rejected = try unacquired(fixture), protected = try closed(fixture)
            let url = evidence(fixture, rejected)
            let original = try Data(contentsOf: url)
            var rows = try original.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
            switch fault {
            case "scope":
                rows[1]["preparationID"] = id()
                try writeEvidence(rows, to: url)
            case "policy":
                rows[1]["transactionMode"] = "temporary_conversation_per_inference"
                rows[1]["transactionVersion"] = 1
                try writeEvidence(rows, to: url)
            case "session":
                rows[1]["sessionToken"] = id()
                try writeEvidence(rows, to: url)
            case "extra_phase":
                var acquired = rows[0]
                acquired["phase"] = "started"
                rows.insert(acquired, at: 1)
                try writeEvidence(rows, to: url)
            case "duplicate_key":
                let duplicate = Data("{\"sequence\":0,".utf8) + original.dropFirst()
                try duplicate.write(to: url)
            case "unconfirmed_summary":
                let unresolved = WebsiteSessionCleanupReceipt(taskID: rejected.taskID, runtimeGeneration: UUID(),
                    outcome: .unconfirmed, reason: .cleanupUnverified, trigger: .manual, receiptSaved: true)
                XCTAssertTrue(fixture.store.save(unresolved))
            case "summary_mismatch":
                var summary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rejected)) as? [String: Any])
                summary["timestamp"] = "2099-01-01T00:00:00.000Z"
                try writeEvidence([summary], to: fixture.cleanup.appendingPathComponent(rejected.taskID + ".jsonl"))
            case "mixed_receipts":
                _ = try closed(fixture, task: rejected.taskID)
            default: XCTFail("Unknown fixture fault")
            }
            let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence,
                protectedTaskIDs: [protected.taskID]), fault)
            XCTAssertEqual(try Data(contentsOf: url), before, fault)
            XCTAssertTrue(try active(fixture.evidence).contains(rejected.taskID), fault)
            XCTAssertEqual(try fixture.store.transactionRecords(for: rejected.taskID, turnID: rejected.turnID!), [rejected], fault)
        }
    }

    func testClosedHistoryRollsOverWithoutIncreasingActiveCapacityAndSurvivesRestart() throws {
        let fixture = try fixture(), first = try closed(fixture, failed: true), second = try closed(fixture)
        let firstBytes = try Data(contentsOf: evidence(fixture, first)), secondBytes = try Data(contentsOf: evidence(fixture, second))
        let newTask = id()
        try fixture.retention.admit(taskID: newTask, evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
        XCTAssertEqual(try active(fixture.evidence).count, 2)
        XCTAssertEqual(try active(fixture.cleanup), try active(fixture.evidence))
        XCTAssertTrue(try active(fixture.cleanup).contains(newTask), "Both stores reserve admission before provider startup")
        let archived = try XCTUnwrap([first, second].first { !FileManager.default.fileExists(atPath: evidence(fixture, $0).path) })
        let reopened = WebsiteJournalRetentionStore(cleanupDirectory: fixture.cleanup)
        let raw = try reopened.withWriterLock { try reopened.archivedBytes(store: "evidence", taskID: archived.taskID, turnID: archived.turnID!) }
        XCTAssertEqual(raw, archived == first ? firstBytes : secondBytes)
        XCTAssertEqual(try fixture.store.transactionRecords(for: first.taskID, turnID: first.turnID!), [first])
        XCTAssertEqual(try fixture.store.transactionRecords(for: second.taskID, turnID: second.turnID!), [second])
        XCTAssertTrue(fixture.store.latest().contains(archived))
        XCTAssertTrue(fixture.store.save(archived), "Exact historical cleanup retry remains idempotent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidence(fixture, archived).path))
    }

    private func cancelledLease(_ fixture: Fixture, submitted: Bool = false, confirmed: Bool = true) throws
        -> (WebsiteSessionCleanupReceipt, [[String: Any]]) {
        let provider: WebsiteSessionCleanupReceipt.Provider = submitted ? .claude : .chatgpt
        let receipt = WebsiteSessionCleanupReceipt(taskID: id(), threadID: id(), turnID: id(), runtimeGeneration: UUID(),
            outcome: confirmed ? .closed : .unconfirmed, provider: provider, route: .embedded,
            modelID: syntheticWebsiteModelID(provider.rawValue), reason: confirmed ? .notCreated : .cleanupUnverified,
            trigger: .automatic, receiptSaved: true, inferenceID: id(), sessionToken: id())
        XCTAssertTrue(fixture.store.save(receipt))
        let requested: [String: Any] = ["schemaVersion": 2, "taskID": receipt.taskID, "threadID": receipt.threadID!,
            "turnID": receipt.turnID!, "inferenceID": receipt.inferenceID!, "preparationID": id(),
            "runtimeGeneration": receipt.runtimeGeneration, "provider": provider.rawValue, "modelID": receipt.modelID!,
            "timestamp": receipt.timestamp, "phase": "start_requested", "sequence": 0, "baselineResponseCount": 0,
            "transactionMode": "temporary_conversation_per_inference", "transactionVersion": 1, "transactionPolicyEstablished": true]
        var started = requested
        started["phase"] = "started"
        started["sessionToken"] = receipt.sessionToken!
        var cancelled = started
        cancelled["phase"] = "cancelled"
        cancelled["sequence"] = 1
        cancelled["errorCode"] = "internal_error"
        var rows = [requested, started]
        if submitted {
            var verified = started
            verified["phase"] = "submission_verified"
            verified["sequence"] = 1
            verified["responseCount"] = 0
            verified["documentGeneration"] = id()
            verified["firstUserFingerprint"] = String(repeating: "a", count: 64)
            verified["modelEvidence"] = ["selected": ["key": "Sonnet 5", "label": "Sonnet 5"],
                "verification": "website_selection", "source": "model_picker_label"] as [String: Any]
            rows.append(verified)
        }
        rows.append(cancelled)
        try writeEvidence(rows, to: evidence(fixture, receipt))
        return (receipt, rows)
    }

    func testExactlyClosedCancellationArchivesBeforeAndAfterVerifiedSubmission() throws {
        for submitted in [false, true] {
            let fixture = try fixture(), protected = try closed(fixture)
            let (cancelled, _) = try cancelledLease(fixture, submitted: submitted)
            let path = evidence(fixture, cancelled), bytes = try Data(contentsOf: path)
            let cleanupPath = fixture.cleanup.appendingPathComponent("transactions/\(cancelled.taskID)/\(cancelled.turnID!).jsonl")
            let cleanupBytes = try Data(contentsOf: cleanupPath)
            let incoming = id()
            try fixture.retention.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: [protected.taskID])
            XCTAssertEqual(try active(fixture.evidence), [protected.taskID, incoming])
            XCTAssertEqual(try active(fixture.cleanup), [protected.taskID, incoming])
            let reopened = WebsiteJournalRetentionStore(cleanupDirectory: fixture.cleanup)
            try reopened.withWriterLock {
                XCTAssertEqual(try reopened.archivedBytes(store: "evidence", taskID: cancelled.taskID, turnID: cancelled.turnID!), bytes)
                XCTAssertEqual(try reopened.archivedBytes(store: "cleanup", taskID: cancelled.taskID, turnID: cancelled.turnID!), cleanupBytes)
            }
            XCTAssertEqual(try fixture.store.transactionRecords(for: cancelled.taskID, turnID: cancelled.turnID!), [cancelled])
        }
    }

    func testCancellationWithoutExactTerminalEvidenceAndClosureStaysActive() throws {
        for fault in ["unconfirmed", "late", "token", "phase", "duplicate_key"] {
            let fixture = try fixture(), protected = try closed(fixture)
            let (cancelled, original) = try cancelledLease(fixture, confirmed: fault != "unconfirmed")
            let path = evidence(fixture, cancelled)
            var rows = original
            switch fault {
            case "late": rows[2]["timestamp"] = "2099-01-01T00:00:00.000Z"
            case "token": rows[2]["sessionToken"] = id()
            case "phase": rows.append(rows[2])
            case "duplicate_key":
                let bytes = try Data(contentsOf: path)
                try (Data("{\"sequence\":0,".utf8) + bytes.dropFirst()).write(to: path)
            default: break
            }
            if fault != "duplicate_key" { try writeEvidence(rows, to: path) }
            let before = try Data(contentsOf: path)
            XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence,
                protectedTaskIDs: [protected.taskID]), fault)
            XCTAssertEqual(try Data(contentsOf: path), before, fault)
            XCTAssertEqual(try active(fixture.evidence), [protected.taskID, cancelled.taskID], fault)
            XCTAssertEqual(try fixture.store.transactionRecords(for: cancelled.taskID, turnID: cancelled.turnID!), [cancelled], fault)
        }
    }

    func testProtectedAndUnconfirmedTasksAreNeverEvicted() throws {
        let fixture = try fixture(), first = try closed(fixture), second = try closed(fixture)
        XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence,
            protectedTaskIDs: [first.taskID, second.taskID]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(second)) as? [String: Any])
        object["attemptID"] = id(); object["outcome"] = "unconfirmed"; object["reason"] = "cleanup_unverified"
        object["timestamp"] = "2099-01-01T00:00:00.000Z"
        let unresolved = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(fixture.store.save(unresolved))
        XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: [first.taskID]))
        XCTAssertEqual(try active(fixture.evidence), [first.taskID, second.taskID])
        XCTAssertTrue(fixture.store.latest().contains(unresolved))
    }

    func testLaterUnconfirmedReceiptAtSameTimestampCannotBeArchivedOrHidden() throws {
        let fixture = try fixture(), first = try closed(fixture), second = try closed(fixture)
        let originalEvidence = try Data(contentsOf: evidence(fixture, second))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(second)) as? [String: Any])
        object["attemptID"] = id(); object["outcome"] = "unconfirmed"; object["reason"] = "cleanup_unverified"
        let unresolved = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(unresolved.timestamp, second.timestamp)
        XCTAssertTrue(fixture.store.save(unresolved))
        XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: [first.taskID]))
        XCTAssertEqual(try Data(contentsOf: evidence(fixture, second)), originalEvidence)
        XCTAssertEqual(try fixture.store.transactionRecords(for: second.taskID, turnID: second.turnID!), [second, unresolved])
        XCTAssertTrue(fixture.store.latest().contains(unresolved))
    }

    @MainActor
    func testRealCapacityAdmissionFailureProjectsFailedBeforeProviderDispatch() async throws {
        let fixture = try fixture(), first = try closed(fixture), second = try closed(fixture)
        let server = WebModelServer(), generation = UUID()
        await server.configureEvidenceDirectory(fixture.evidence)
        await server.configureCleanupReceipts(directory: fixture.cleanup, runtimeGeneration: generation) { _ in }
        await server.setJournalTaskLimitForTesting(2)
        for receipt in [first, second] {
            try await server.prepareInferenceTurn(taskID: receipt.taskID, threadID: receipt.threadID!,
                runtimeGeneration: generation, preparationID: UUID())
        }
        let incoming = id(), runtime = CapacityAdmissionRuntime(server: server, generation: generation)
        let task = AgentTask(id: incoming, title: "Capacity fixture", summary: "", status: .draft,
            workspace: fixture.root.path, model: "browser/chatgpt", entries: [])
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())
        state.connectionState = .connected(provider: runtime.providerName)
        let accepted = await state.submit(prompt: "Synthetic capacity check", toTaskID: incoming)
        XCTAssertFalse(accepted)
        XCTAssertEqual(state.tasks.first?.status, .failed)
        XCTAssertTrue(state.tasks.first?.entries.contains(where: { $0.title == "Agent error" && $0.body.contains("evidence could not be saved") }) == true)
        let dispatched = await runtime.dispatched
        XCTAssertEqual(dispatched, 0)
        XCTAssertEqual(try active(fixture.evidence), [first.taskID, second.taskID])
        _ = await server.shutdown()
    }

    func testInterruptedRetirementRecoversAtEachDurableBoundaryWithoutLosingBytes() throws {
        for point in [WebsiteJournalRetentionStore.FaultPoint.committed, .removedEvidence, .removedCleanup] {
            let fixture = try fixture(), first = try closed(fixture), second = try closed(fixture)
            let bytes = [first.taskID: try Data(contentsOf: evidence(fixture, first)), second.taskID: try Data(contentsOf: evidence(fixture, second))]
            var interrupted = fixture.retention
            interrupted.fault = { if $0 == point { throw CocoaError(.fileWriteUnknown) } }
            let incoming = id()
            XCTAssertThrowsError(try interrupted.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: []))
            try fixture.retention.admit(taskID: incoming, evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
            XCTAssertEqual(try active(fixture.evidence).count, 2)
            XCTAssertEqual(try active(fixture.cleanup), try active(fixture.evidence))
            for row in [first, second] {
                let archive = try fixture.retention.withWriterLock { try fixture.retention.archivedBytes(store: "evidence", taskID: row.taskID, turnID: row.turnID!) }
                XCTAssertEqual(try archive ?? Data(contentsOf: evidence(fixture, row)), bytes[row.taskID])
                XCTAssertEqual(try fixture.store.transactionRecords(for: row.taskID, turnID: row.turnID!), [row])
            }
        }
    }

    func testPendingRetirementRejectsChangedActiveBytesAndWriterCannotAppend() throws {
        let fixture = try fixture(), first = try closed(fixture), second = try closed(fixture)
        var interrupted = fixture.retention
        interrupted.fault = { if $0 == .committed { throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try interrupted.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: []))
        let pending = try XCTUnwrap([first, second].first { row in
            try fixture.retention.withWriterLock { try fixture.retention.isPending(taskID: row.taskID) }
        })
        XCTAssertFalse(fixture.store.save(pending), "A pending move cannot race a journal writer")
        let file = evidence(fixture, pending), original = try Data(contentsOf: file)
        try (original + Data("changed".utf8)).write(to: file)
        XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: []))
        XCTAssertEqual(try Data(contentsOf: file), original + Data("changed".utf8))
        try original.write(to: file)
        try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
    }

    func testArchivedIdentityCannotBeReboundAndNewUnresolvedStartupStillPersists() throws {
        let fixture = try fixture(), first = try closed(fixture), second = try closed(fixture)
        try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
        let archived = try XCTUnwrap([first, second].first { !FileManager.default.fileExists(atPath: evidence(fixture, $0).path) })
        for field in ["inferenceID", "sessionToken", "attemptID"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archived)) as? [String: Any])
            object["taskID"] = id(); object["threadID"] = id(); object["turnID"] = id()
            for identity in ["inferenceID", "sessionToken", "attemptID"] where identity != field { object[identity] = id() }
            let rebound = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertFalse(fixture.store.save(rebound), field)
        }
        let startup = WebsiteSessionCleanupReceipt(taskID: id(), threadID: id(), turnID: id(), runtimeGeneration: UUID(),
            outcome: .unconfirmed, provider: .chatgpt, route: .embedded, modelID: "browser/chatgpt", reason: .cleanupUnverified,
            trigger: .inference, receiptSaved: true, inferenceID: id())
        XCTAssertTrue(fixture.store.save(startup), "An archive must not prevent persistence of a new uncertain startup")
        XCTAssertTrue(fixture.store.latest().contains(startup))
    }

    func testReactivatedChatArchivesNewSegmentAndKeepsOldTurnImmutable() throws {
        let fixture = try fixture(), first = try closed(fixture), second = try closed(fixture)
        try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
        let old = try XCTUnwrap([first, second].first { !FileManager.default.fileExists(atPath: evidence(fixture, $0).path) })
        try fixture.retention.admit(taskID: old.taskID, evidenceDirectory: fixture.evidence, protectedTaskIDs: [])
        let next = try closed(fixture, task: old.taskID)
        // Force this exact task to be selected on the next rollover.
        let other = try active(fixture.evidence).subtracting([old.taskID])
        try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: other)
        XCTAssertEqual(try fixture.store.transactionRecords(for: old.taskID, turnID: old.turnID!), [old])
        XCTAssertEqual(try fixture.store.transactionRecords(for: next.taskID, turnID: next.turnID!), [next])
        XCTAssertTrue(fixture.store.save(old)); XCTAssertTrue(fixture.store.save(next))
    }

    func testWriterContentionSymlinkAndArchiveQuotaFailWithoutDeletingHistory() throws {
        let fixture = try fixture(), first = try closed(fixture), second = try closed(fixture)
        try fixture.retention.withWriterLock {
            XCTAssertThrowsError(try fixture.retention.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: []))
            XCTAssertFalse(fixture.store.save(first))
        }
        var constrained = fixture.retention; constrained.limits.archiveBytes = 4_096
        XCTAssertThrowsError(try constrained.admit(taskID: id(), evidenceDirectory: fixture.evidence, protectedTaskIDs: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence(fixture, first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence(fixture, second).path))
        let target = fixture.root.appendingPathComponent("unrelated"), link = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try WebsiteJournalRetentionStore(cleanupDirectory: link).withWriterLock {})
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
}

private actor CapacityAdmissionRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Capacity admission fixture"
    let server: WebModelServer
    let generation: UUID
    private(set) var dispatched = 0
    init(server: WebModelServer, generation: UUID) { self.server = server; self.generation = generation }
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: String, modelID: String) async throws {
        try await server.prepareInferenceTurn(taskID: taskID, threadID: UUID().uuidString.lowercased(),
            runtimeGeneration: generation, preparationID: UUID())
        dispatched += 1
    }
    func interrupt(taskID: String) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

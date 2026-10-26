import Darwin
import Foundation
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

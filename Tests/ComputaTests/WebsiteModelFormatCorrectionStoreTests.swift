import XCTest
import Darwin
@testable import Computa

final class WebsiteModelFormatCorrectionStoreTests: XCTestCase {
    private typealias Store = WebsiteModelFormatCorrectionStore
    private let task = "550e8400-e29b-41d4-a716-446655440000"
    private let thread = "550e8400-e29b-41d4-a716-446655440001"
    private let turn = "550e8400-e29b-41d4-a716-446655440002"

    private func root() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("ComputaWebsiteCorrection-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }
    private func claim(_ store: Store, taskID: String? = nil, turnID: String? = nil) throws -> Store.Ticket {
        try store.claim(taskID: taskID ?? task, threadID: thread, turnID: turnID ?? turn,
                        firstInferenceID: UUID(), firstSessionToken: UUID(), secondInferenceID: UUID())
    }
    private func files(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
    private func record(_ file: URL) throws -> Store.Record {
        try JSONDecoder().decode(Store.Record.self, from: Data(contentsOf: file))
    }
    private func rewrite(_ file: URL, _ transform: (inout [String: Any]) -> Void) throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        transform(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
    }

    func testLinkedThreePhaseJournalIsPrivateDurableFiniteAndImmutable() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
        let ticket = try claim(store)
        let first = try XCTUnwrap(files(directory).first), firstBytes = try Data(contentsOf: first)
        let cleanup = UUID(), secondToken = UUID()
        try store.recordClosed(ticket, cleanupAttemptID: cleanup)
        try store.finish(ticket, secondInferenceID: ticket.secondInferenceID, secondSessionToken: secondToken,
                         outcome: .responseValidated)
        let all = try files(directory), records = try all.map(record)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(records.map(\.phase)), [.claimed, .firstClosed, .finished])
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        let finished = try XCTUnwrap(records.first { $0.phase == .finished })
        XCTAssertEqual(finished.ticket, ticket); XCTAssertEqual(finished.cleanupAttemptID, cleanup)
        XCTAssertEqual(finished.secondInferenceID, ticket.secondInferenceID)
        XCTAssertEqual(finished.secondSessionToken, secondToken); XCTAssertTrue(finished.secondStarted)
        XCTAssertEqual(finished.outcome, .responseValidated)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for file in all {
            let bytes = try Data(contentsOf: file), value = try record(file)
            XCTAssertTrue(value.isValid); XCTAssertTrue(value.usageUnknown)
            XCTAssertLessThanOrEqual(bytes.count, Store.maximumRecordBytes)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let text = String(decoding: bytes, as: UTF8.self)
            for forbidden in ["prompt", "arguments", "reply", "http", "credential", "tool_schema", "inputTokens", "outputTokens"] {
                XCTAssertFalse(text.contains(forbidden))
            }
        }
        XCTAssertThrowsError(try store.recordClosed(ticket, cleanupAttemptID: cleanup))
        XCTAssertThrowsError(try store.finish(ticket, secondInferenceID: ticket.secondInferenceID,
                                             secondSessionToken: secondToken, outcome: .responseValidated))
        XCTAssertEqual(try files(directory).count, 3)
    }

    func testPermanentNativeTurnClaimSurvivesRestartTaskRemapAndUnfinishedCrash() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("correction")
        _ = try claim(Store(directory: directory))
        let restarted = Store(directory: directory)
        XCTAssertThrowsError(try claim(restarted))
        XCTAssertThrowsError(try claim(restarted, taskID: UUID().uuidString.lowercased()))
        _ = try claim(restarted, turnID: UUID().uuidString.lowercased())
        XCTAssertEqual(try files(directory).count, 2, "An independent native turn retains its own correction budget")
        XCTAssertTrue(try files(directory).allSatisfy { !$0.lastPathComponent.contains(task) })
    }

    func testConcurrentDifferentTasksCannotBothClaimTheSameNativeTurn() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
        let thread = self.thread, turn = self.turn
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try store.claim(taskID: UUID().uuidString.lowercased(), threadID: thread, turnID: turn,
                                            firstInferenceID: UUID(), firstSessionToken: UUID(), secondInferenceID: UUID())
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        XCTAssertEqual(winners, 1); XCTAssertEqual(try files(directory).count, 1)
    }

    func testSuccessfulAndInvalidJSONOutcomesRequireFirstCleanupAndExactFreshSecondSession() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
        let ticket = try claim(store), token = UUID()
        XCTAssertThrowsError(try store.finish(ticket, secondInferenceID: ticket.secondInferenceID,
                                             secondSessionToken: token, outcome: .responseValidated))
        XCTAssertThrowsError(try store.finish(ticket, secondInferenceID: nil, secondSessionToken: nil, outcome: .invalidJSON))
        try store.recordClosed(ticket, cleanupAttemptID: UUID())
        for (inference, session) in [(Optional(UUID()), Optional(token)), (nil, Optional(token)),
                                     (Optional(ticket.secondInferenceID), nil),
                                     (Optional(ticket.secondInferenceID), Optional(ticket.firstSessionToken))] {
            XCTAssertThrowsError(try store.finish(ticket, secondInferenceID: inference, secondSessionToken: session, outcome: .invalidJSON))
        }
        try store.finish(ticket, secondInferenceID: ticket.secondInferenceID, secondSessionToken: token, outcome: .invalidJSON)
        XCTAssertEqual(try files(directory).count, 3)
    }

    func testPreStartAbortIsDurableWithoutInventingSecondSessionOrCleanup() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
        for outcome in [Store.Outcome.failed, .cancelled, .timedOut, .budgetExhausted] {
            let ticket = try claim(store, turnID: UUID().uuidString.lowercased())
            try store.finish(ticket, secondInferenceID: nil, secondSessionToken: nil, outcome: outcome)
            XCTAssertThrowsError(try store.recordClosed(ticket, cleanupAttemptID: UUID()))
        }
        let finished = try files(directory).map(record).filter { $0.phase == .finished }
        XCTAssertEqual(finished.count, 4)
        XCTAssertTrue(finished.allSatisfy { !$0.secondStarted && $0.secondSessionToken == nil && $0.cleanupAttemptID == nil && $0.usageUnknown })
    }

    func testForgedTicketCannotCloseOrFinishTheClaim() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
        let ticket = try claim(store)
        let variants: [Store.Ticket] = [
            .init(id: UUID(), taskID: ticket.taskID, threadID: ticket.threadID, turnID: ticket.turnID,
                  firstInferenceID: ticket.firstInferenceID, firstSessionToken: ticket.firstSessionToken, secondInferenceID: ticket.secondInferenceID),
            .init(id: ticket.id, taskID: UUID().uuidString.lowercased(), threadID: ticket.threadID, turnID: ticket.turnID,
                  firstInferenceID: ticket.firstInferenceID, firstSessionToken: ticket.firstSessionToken, secondInferenceID: ticket.secondInferenceID),
            .init(id: ticket.id, taskID: ticket.taskID, threadID: ticket.threadID, turnID: ticket.turnID,
                  firstInferenceID: UUID(), firstSessionToken: ticket.firstSessionToken, secondInferenceID: ticket.secondInferenceID),
            .init(id: ticket.id, taskID: ticket.taskID, threadID: ticket.threadID, turnID: ticket.turnID,
                  firstInferenceID: ticket.firstInferenceID, firstSessionToken: UUID(), secondInferenceID: ticket.secondInferenceID),
            .init(id: ticket.id, taskID: ticket.taskID, threadID: ticket.threadID, turnID: ticket.turnID,
                  firstInferenceID: ticket.firstInferenceID, firstSessionToken: ticket.firstSessionToken, secondInferenceID: UUID())]
        for forged in variants {
            XCTAssertThrowsError(try store.recordClosed(forged, cleanupAttemptID: UUID()))
            XCTAssertThrowsError(try store.finish(forged, secondInferenceID: nil, secondSessionToken: nil, outcome: .failed))
        }
        XCTAssertEqual(try files(directory).count, 1)
    }

    func testUnknownDuplicateWrongTypeAndNoncanonicalRecordsDisableAllCorrection() throws {
        for mutation in 0..<7 {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
            let ticket = try claim(store), file = try XCTUnwrap(files(directory).first)
            if mutation == 0 {
                let text = try String(contentsOf: file, encoding: .utf8)
                try Data(("{\"usageUnknown\":true," + text.dropFirst()).utf8).write(to: file)
            } else {
                try rewrite(file) { object in
                    switch mutation {
                    case 1: object["unexpected"] = "PRIVATE_REPLY"
                    case 2: object["usageUnknown"] = false
                    case 3: object["schemaVersion"] = "1"
                    case 4: object["phase"] = "second_replayed"
                    case 5: object["cleanupAttemptID"] = NSNull()
                    default: object["threadID"] = self.thread.uppercased()
                    }
                }
            }
            XCTAssertThrowsError(try store.recordClosed(ticket, cleanupAttemptID: UUID()), "mutation \(mutation)")
            XCTAssertThrowsError(try claim(store, turnID: UUID().uuidString.lowercased()), "Corruption cannot issue a fresh budget")
            XCTAssertEqual(try files(directory).count, 1)
        }
    }

    func testUnsafeRecordTypesModesAndLinksAreRejectedWithoutFollowingOrBlocking() throws {
        for mutation in 0..<5 {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
            let ticket = try claim(store), file = try XCTUnwrap(files(directory).first)
            let original = try Data(contentsOf: file), target = root.appendingPathComponent("outside")
            try original.write(to: target)
            if mutation == 0 { XCTAssertEqual(chmod(file.path, 0o644), 0) }
            else if mutation == 1 { XCTAssertEqual(link(file.path, target.appendingPathExtension("hardlink").path), 0) }
            else {
                try FileManager.default.removeItem(at: file)
                if mutation == 2 { XCTAssertEqual(symlink(target.path, file.path), 0) }
                else if mutation == 3 { XCTAssertEqual(mkfifo(file.path, 0o600), 0) }
                else { try Data(repeating: 32, count: Store.maximumRecordBytes + 1).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0) }
            }
            XCTAssertThrowsError(try store.recordClosed(ticket, cleanupAttemptID: UUID()))
            XCTAssertEqual(try Data(contentsOf: target), original, "Outside content is never mutated")
        }
    }

    func testUnsafeDirectoryAndAncestorOrDecoratedURLCannotClaim() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        XCTAssertEqual(symlink(target.path, alias.path), 0)
        XCTAssertThrowsError(try claim(Store(directory: alias)))
        XCTAssertThrowsError(try claim(Store(directory: alias.appendingPathComponent("nested"))))
        XCTAssertTrue(try files(target).isEmpty)
        XCTAssertEqual(chmod(target.path, 0o755), 0)
        XCTAssertThrowsError(try claim(Store(directory: target)))
        for suffix in ["?query=1", "#fragment"] {
            let decorated = try XCTUnwrap(URL(string: target.absoluteString + suffix))
            XCTAssertThrowsError(try claim(Store(directory: decorated)))
        }
        XCTAssertThrowsError(try Store(directory: root.appendingPathComponent("fresh")).claim(
            taskID: task, threadID: thread.uppercased(), turnID: turn, firstInferenceID: UUID(),
            firstSessionToken: UUID(), secondInferenceID: UUID()))
    }

    func testMismatchedPhaseLinkAndOrphanedPhaseCannotAuthorizeAnotherCorrection() throws {
        for orphan in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
            let ticket = try claim(store)
            try store.recordClosed(ticket, cleanupAttemptID: UUID())
            let entries = try files(directory)
            let closed = try XCTUnwrap(entries.first { $0.lastPathComponent.contains("first_closed") })
            if orphan { try FileManager.default.removeItem(at: XCTUnwrap(entries.first { $0.lastPathComponent.contains("claimed") })) }
            else { try rewrite(closed) { $0["secondInferenceID"] = UUID().uuidString } }
            XCTAssertThrowsError(try store.finish(ticket, secondInferenceID: ticket.secondInferenceID,
                                                 secondSessionToken: UUID(), outcome: .responseValidated))
            XCTAssertThrowsError(try claim(store, turnID: UUID().uuidString.lowercased()))
        }
    }

    func testCapacityReservesClosureAndOutcomeBeforeGrantingAClaim() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("correction"), store = Store(directory: directory)
        let ticket = try claim(store), original = try XCTUnwrap(files(directory).first)
        let bytes = try Data(contentsOf: original)
        // Construct valid outstanding claims, not malformed filler. Each owns
        // two future slots, so capacity must stop new work before a close fails.
        for index in 1..<(Store.maximumRecords / 3) {
            let newTurn = String(format: "660e8400-e29b-41d4-a716-%012d", index)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["turnID"] = newTurn; object["correctionID"] = UUID().uuidString
            let newBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let file = directory.appendingPathComponent(thread + "-" + newTurn + ".claimed.json")
            try newBytes.write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        }
        XCTAssertThrowsError(try claim(store, turnID: UUID().uuidString.lowercased()))
        try store.recordClosed(ticket, cleanupAttemptID: UUID())
        try store.finish(ticket, secondInferenceID: ticket.secondInferenceID, secondSessionToken: UUID(), outcome: .responseValidated)
        XCTAssertEqual(try files(directory).count, Store.maximumRecords / 3 + 2)
    }
}

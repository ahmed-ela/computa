import Darwin
import Foundation
import XCTest
@testable import Computa

final class EmbeddedBrowserCleanupReceiptTests: XCTestCase {
    private let generation = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private func root() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(path) }
        let result = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("ComputaBrowserCleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return result
    }
    private func receipt(task: String = "embedded-browser-task", thread: String = "thread", turn: String = "turn-1",
                         report: EmbeddedBrowserCleanupReport? = nil) -> EmbeddedBrowserCleanupReceipt {
        .init(taskID: task, threadID: thread, turnID: turn, runtimeGeneration: generation,
              report: report ?? .init(targets: [.init(targetID: "owned-tab", instanceToken: "instance-1", trigger: .automatic, closed: true)]),
              timestamp: Date(timeIntervalSince1970: 1_800_000_000.125))
    }
    private func load(_ store: EmbeddedBrowserCleanupReceiptStore, _ value: EmbeddedBrowserCleanupReceipt) throws -> EmbeddedBrowserCleanupReceipt? {
        try store.load(taskID: value.taskID, threadID: value.threadID, turnID: value.turnID, runtimeGeneration: value.runtimeGeneration)
    }
    private func file(_ directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first { $0.pathExtension == "json" })
    }
    private func replace(_ file: URL, bytes: Data) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
    }

    func testExactPrivateImmutableReadbackAndIdenticalRetryDoNotPublishAgain() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("receipts"), store = EmbeddedBrowserCleanupReceiptStore(directory: directory)
        let value = receipt()
        XCTAssertNil(try load(store, value)); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(store.save(value))
        let record = try file(directory), bytes = try Data(contentsOf: record)
        let before = try FileManager.default.attributesOfItem(atPath: record.path)
        XCTAssertEqual(try load(store, value), value)
        XCTAssertEqual(try JSONDecoder().decode(EmbeddedBrowserCleanupReceipt.self, from: bytes), value)
        XCTAssertEqual(record.lastPathComponent.count, 69)
        XCTAssertNotNil(record.lastPathComponent.range(of: #"^[0-9a-f]{64}\.json$"#, options: .regularExpression))
        XCTAssertEqual((before[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(store.save(value))
        let after = try FileManager.default.attributesOfItem(atPath: record.path)
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber, before[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try Data(contentsOf: record), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        XCTAssertEqual(try load(EmbeddedBrowserCleanupReceiptStore(directory: directory), value), value)
    }

    func testConfiguredAppHomeResolvesMacOSAliasWithoutRelaxingReceiptDirectoryChecks() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.path.hasPrefix("/private/var/") ? String(root.path.dropFirst("/private".count)) : root.path
        let store = try XCTUnwrap(EmbeddedBrowserCleanupReceiptStore(codexHomePath: alias))
        XCTAssertEqual(store.directory.deletingLastPathComponent().path, root.path)
        let value = receipt()
        XCTAssertTrue(store.save(value)); XCTAssertEqual(try load(store, value), value)
        XCTAssertNil(EmbeddedBrowserCleanupReceiptStore(codexHomePath: root.appendingPathComponent("missing").path))
        XCTAssertNil(EmbeddedBrowserCleanupReceiptStore(codexHomePath: "relative/home"))
        XCTAssertNil(EmbeddedBrowserCleanupReceiptStore(codexHomePath: root.path + "\0ignored"))
    }

    func testConflictCannotReplaceReceiptAndEveryIdentityComponentIsIsolated() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("receipts"), store = EmbeddedBrowserCleanupReceiptStore(directory: directory), value = receipt()
        XCTAssertTrue(store.save(value)); let record = try file(directory), original = try Data(contentsOf: record)
        let failed = receipt(report: .init(targets: [.init(targetID: "owned-tab", instanceToken: "instance-1", trigger: .automatic, closed: false)], failures: [.ownedTargetCloseFailed]))
        XCTAssertFalse(store.save(failed))
        let later = EmbeddedBrowserCleanupReceipt(taskID: value.taskID, threadID: value.threadID, turnID: value.turnID,
            runtimeGeneration: generation, report: value.report, timestamp: value.timestamp.addingTimeInterval(1))
        XCTAssertFalse(store.save(later)); XCTAssertEqual(try Data(contentsOf: record), original)
        for other in [receipt(task: "other-task"), receipt(thread: "other-thread"), receipt(turn: "turn-2")] {
            XCTAssertNil(try load(store, other)); XCTAssertTrue(store.save(other)); XCTAssertEqual(try load(store, other), other)
        }
        XCTAssertNil(try store.load(taskID: value.taskID, threadID: value.threadID, turnID: value.turnID, runtimeGeneration: UUID()))
        XCTAssertEqual(try load(store, value), value)
    }

    func testFailedAndPendingReportsRemainFiniteEvidenceWithoutClaimingSettledCleanup() throws {
        let empty = EmbeddedBrowserCleanupReport()
        XCTAssertTrue(empty.isSettled); XCTAssertFalse(empty.wasUsed); XCTAssertTrue(empty.issues.isEmpty)
        XCTAssertTrue(EmbeddedBrowserCleanupReport(userBindingReleased: true).wasUsed)
        let report = EmbeddedBrowserCleanupReport(targets: [.init(targetID: "owned", instanceToken: "old-instance", trigger: .shutdown, closed: false)],
            pendingOperation: true, failures: [.bindingReleaseFailed, .ownedTargetCloseFailed, .historyLimit])
        XCTAssertFalse(report.isSettled); XCTAssertTrue(report.wasUsed); XCTAssertEqual(report.issues.count, 4)
        XCTAssertEqual(EmbeddedBrowserCleanupReport(pendingOperation: true).issues, ["A task browser operation is still pending."])
        XCTAssertEqual(EmbeddedBrowserCleanupReport(pendingOperation: true, failures: [.operationPending]).issues.count, 1)
        XCTAssertEqual(EmbeddedBrowserCleanupReport(failures: [.operationPending, .operationPending]).issues.count, 1)
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EmbeddedBrowserCleanupReceiptStore(directory: root.appendingPathComponent("receipts")), value = receipt(report: report)
        XCTAssertTrue(store.save(value)); XCTAssertEqual(try load(store, value), value)
        XCTAssertFalse(try XCTUnwrap(load(store, value)).report.isSettled)
        let bytes = try Data(contentsOf: file(store.directory))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "taskID", "threadID", "turnID", "runtimeGeneration", "timestamp", "report"])
        let rawReport = try XCTUnwrap(object["report"] as? [String: Any])
        XCTAssertEqual(Set(rawReport.keys), ["targets", "userBindingReleased", "pendingOperation", "failures"])
        let target = try XCTUnwrap((rawReport["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(target.keys), ["targetID", "instanceToken", "trigger", "closed"])
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["prompt", "reply", "url", "title", "credential", "http", "PRIVATE_CANARY"] { XCTAssertFalse(text.contains(forbidden)) }
        // An omitted redundant failure enum cannot turn an explicitly unclosed
        // target into settled cleanup or suppress its human issue.
        let unclosed = EmbeddedBrowserCleanupReport(targets: [.init(targetID: "unclosed", instanceToken: "instance-2", trigger: .automatic, closed: false)])
        XCTAssertFalse(unclosed.isSettled); XCTAssertTrue(unclosed.wasUsed)
        XCTAssertEqual(unclosed.issues, ["A task-created browser tab could not be confirmed closed."])
        let unclosedReceipt = receipt(turn: "turn-unclosed", report: unclosed)
        XCTAssertTrue(store.save(unclosedReceipt))
        let saved = try XCTUnwrap(load(store, unclosedReceipt))
        XCTAssertFalse(saved.report.isSettled); XCTAssertEqual(saved.report.issues, unclosed.issues)
    }

    func testInvalidSchemaUnknownPrivateFieldsControlsAndMalformedTypesReject() throws {
        let value = receipt(), encoded = try JSONEncoder().encode(value)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var variants: [[String: Any]] = []
        var changed = original; changed["schemaVersion"] = 2; variants.append(changed)
        changed = original; changed.removeValue(forKey: "schemaVersion"); variants.append(changed)
        changed = original; changed["prompt"] = "PRIVATE_CANARY"; variants.append(changed)
        for identity in ["", String(repeating: "x", count: 257), "task\nPRIVATE_CANARY", "task\0id", "task\u{2028}id"] {
            changed = original; changed["taskID"] = identity; variants.append(changed)
        }
        changed = original
        var report = try XCTUnwrap(changed["report"] as? [String: Any]); report["url"] = "PRIVATE_CANARY"
        changed["report"] = report; variants.append(changed)
        let mutations: [[String: Any]] = [["closed": "true"], ["trigger": "provider_text"], ["title": "PRIVATE_CANARY"], ["instanceToken": ""]]
        for mutation in mutations {
            changed = original; report = try XCTUnwrap(changed["report"] as? [String: Any])
            var targets = try XCTUnwrap(report["targets"] as? [[String: Any]])
            targets[0].merge(mutation) { _, new in new }; report["targets"] = targets; changed["report"] = report; variants.append(changed)
        }
        for object in variants {
            XCTAssertThrowsError(try JSONDecoder().decode(EmbeddedBrowserCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EmbeddedBrowserCleanupReceiptStore(directory: root.appendingPathComponent("receipts"))
        XCTAssertFalse(store.save(receipt(task: "bad\nidentity")))
        XCTAssertFalse(store.save(.init(taskID: value.taskID, threadID: value.threadID, turnID: value.turnID,
            runtimeGeneration: generation, report: value.report, timestamp: Date(timeIntervalSinceReferenceDate: .infinity))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testRecordAndDirectoryBoundsFailClosedWhileExistingIdenticalReceiptRemainsReadable() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EmbeddedBrowserCleanupReceiptStore(directory: root.appendingPathComponent("receipts"))
        let large = EmbeddedBrowserCleanupReport(targets: Array(repeating: .init(targetID: String(repeating: "x", count: 256),
            instanceToken: String(repeating: "y", count: 256), trigger: .replacement, closed: true), count: 128))
        XCTAssertGreaterThan(try JSONEncoder().encode(receipt(report: large)).count, 65_536)
        XCTAssertFalse(store.save(receipt(report: large))); XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        let value = receipt(); XCTAssertTrue(store.save(value))
        for index in 0..<(EmbeddedBrowserCleanupReceiptStore.maximumRecords - 1) {
            let descriptor = open(store.directory.appendingPathComponent("filler-\(index)").path, O_WRONLY | O_CREAT | O_EXCL, 0o400)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }; close(descriptor)
        }
        XCTAssertTrue(store.save(value)); XCTAssertEqual(try load(store, value), value)
        XCTAssertFalse(store.save(receipt(turn: "turn-new")))
        let extra = store.directory.appendingPathComponent("one-too-many")
        XCTAssertTrue(FileManager.default.createFile(atPath: extra.path, contents: Data(), attributes: [.posixPermissions: 0o400]))
        XCTAssertThrowsError(try load(store, value))
    }

    func testSymlinkAncestorsUnsafeDirectoryAndNonlocalURLCannotPublishOrRead() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let unsafe = root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        var directories = [alias, alias.appendingPathComponent("missing"), unsafe]
        var components = try XCTUnwrap(URLComponents(url: root.appendingPathComponent("decorated"), resolvingAgainstBaseURL: false))
        components.query = "PRIVATE_CANARY"; directories.append(try XCTUnwrap(components.url))
        components.query = nil; components.fragment = "PRIVATE_CANARY"; directories.append(try XCTUnwrap(components.url))
        components.fragment = nil; components.host = "foreign.invalid"; directories.append(try XCTUnwrap(components.url))
        for directory in directories {
            let store = EmbeddedBrowserCleanupReceiptStore(directory: directory)
            XCTAssertFalse(store.save(receipt())); XCTAssertThrowsError(try load(store, receipt()))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }

    func testWrongRecordTypesHardLinksTamperingAndDuplicateKeysNeverReturnReceipt() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EmbeddedBrowserCleanupReceiptStore(directory: root.appendingPathComponent("receipts")), value = receipt()
        XCTAssertTrue(store.save(value)); let record = try file(store.directory), bytes = try Data(contentsOf: record)
        let backup = root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: record, to: backup)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: backup)
        XCTAssertThrowsError(try load(store, value)); XCTAssertFalse(store.save(value))
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(link(backup.path, record.path), 0)
        XCTAssertThrowsError(try load(store, value)); XCTAssertFalse(store.save(value))
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(mkfifo(record.path, 0o400), 0)
        XCTAssertThrowsError(try load(store, value)); XCTAssertFalse(store.save(value))
        try FileManager.default.removeItem(at: record)
        try FileManager.default.moveItem(at: backup, to: record)
        let text = String(decoding: bytes, as: UTF8.self)
        try replace(record, bytes: Data(text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1").utf8))
        XCTAssertThrowsError(try load(store, value)); XCTAssertFalse(store.save(value))
        try replace(record, bytes: Data(repeating: 32, count: 65_537))
        XCTAssertThrowsError(try load(store, value)); XCTAssertFalse(store.save(value))
        try replace(record, bytes: bytes)
        XCTAssertEqual(try load(store, value), value)
        let misplaced = receipt(task: "foreign-task")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try replace(record, bytes: encoder.encode(misplaced))
        XCTAssertThrowsError(try load(store, value))
    }
}

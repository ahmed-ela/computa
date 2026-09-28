import AutomationCore
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Computa

final class NativeFailureEvidenceStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("evidence", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaNativeEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testRoundTripReloadAndPrivateHashedFilename() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let record = fixture(threadID: "../../outside/thread")
        XCTAssertEqual(try store.load(threadID: record.threadID), [])
        XCTAssertEqual(try store.append(record), record)
        let reloaded = try NativeFailureEvidenceStore(directory: directory)
        XCTAssertEqual(try reloaded.load(threadID: record.threadID), [record])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [fileURL(record.threadID).lastPathComponent])
        XCTAssertEqual(files.first?.count, 69)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL(record.threadID).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
        let data = try Data(contentsOf: fileURL(record.threadID))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["version", "threadID", "records"])
        let records = try XCTUnwrap(body["records"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(records.first).keys),
            ["threadID", "turnID", "callID", "toolName", "message", "diagnosticText", "timestamp"])
    }

    func testExactDuplicateRetainsFirstTimestampAndDoesNotRewriteEvidence() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let first = fixture()
        try store.append(first)
        let original = try Data(contentsOf: fileURL(first.threadID))
        let duplicate = fixture(timestamp: first.timestamp.addingTimeInterval(30))
        XCTAssertEqual(try store.append(duplicate), first)
        XCTAssertEqual(try store.load(threadID: first.threadID), [first])
        XCTAssertEqual(try Data(contentsOf: fileURL(first.threadID)), original)
    }

    func testNavigationRecoveryRoundTripsAlongsideLegacyActivationEvidence() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let activation = fixture()
        let recovery = navigationRecoveryFixture()
        try store.append(activation)
        try store.append(recovery)
        let original = try Data(contentsOf: fileURL(recovery.threadID))
        XCTAssertEqual(try store.append(recovery), recovery)
        XCTAssertEqual(try Data(contentsOf: fileURL(recovery.threadID)), original)
        let reloaded = try NativeFailureEvidenceStore(directory: directory)
        XCTAssertEqual(try reloaded.load(threadID: recovery.threadID), [activation, recovery])
        XCTAssertFalse(recovery.diagnosticText.contains("process_id"))
        XCTAssertFalse(recovery.diagnosticText.contains("https://"))
    }

    func testNavigationRecoverySchemaRejectsInventedStateUnknownFieldsAndInvalidTextTypes() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let activation = fixture()
        try store.append(activation)
        let original = try Data(contentsOf: fileURL(activation.threadID))
        let invalid = [
            navigationRecoveryFixture(toolName: "computer_v2_type"),
            navigationRecoveryFixture(message: " "),
            navigationRecoveryFixture(message: String(repeating: "x", count: 2_049)),
            try withDiagnostic(navigationRecoveryFixture()) { $0["process_id"] = 1234 },
            try withDiagnostic(navigationRecoveryFixture()) { $0["process_id"] = NSNull() },
            try withDiagnostic(navigationRecoveryFixture()) { $0["url"] = "https://private.invalid/secret" },
            try withDiagnostic(navigationRecoveryFixture()) { $0["dom"] = ["text": "private page"] },
            try withDiagnostic(navigationRecoveryFixture()) { $0["tab_state"] = "retained" },
            try withDiagnostic(navigationRecoveryFixture()) { $0["action_outcome"] = "enter_sent" },
            try withDiagnostic(navigationRecoveryFixture()) { $0["website_status"] = "blocked" },
            try withDiagnostic(navigationRecoveryFixture()) { $0["cause"] = "policy" },
            try withDiagnostic(navigationRecoveryFixture()) { $0["retry_policy"] = "retry" },
            try withDiagnostic(navigationRecoveryFixture()) { $0["next_step"] = ["url": "https://private.invalid"] },
            try withDiagnostic(navigationRecoveryFixture()) { $0["next_step"] = "" },
            try withDiagnostic(navigationRecoveryFixture()) {
                $0["error"] = ["code": "chrome_navigation_recovery_required", "message": true] as [String: Any]
            },
            try withDiagnostic(navigationRecoveryFixture()) {
                $0["error"] = ["code": "chrome_navigation_recovery_required", "message": String(repeating: "x", count: 2_049)]
            },
            try withDiagnostic(navigationRecoveryFixture()) {
                $0["error"] = ["code": "unknown_failure", "message": "Unknown failure"]
            },
            try withDiagnostic(navigationRecoveryFixture()) { $0.removeValue(forKey: "retry_policy") },
        ]
        for record in invalid {
            XCTAssertThrowsError(try store.append(record))
            XCTAssertEqual(try Data(contentsOf: fileURL(activation.threadID)), original)
        }
        XCTAssertEqual(try store.load(threadID: activation.threadID), [activation])
    }

    func testNavigationRecoveryHistoricalCopyRemainsReadableAfterWordingChanges() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let historical = try withDiagnostic(navigationRecoveryFixture(message: "Earlier app wording: navigation could not be confirmed.")) {
            $0["error"] = ["code": "chrome_navigation_recovery_required", "message": "Earlier navigation recovery diagnostic."]
            $0["next_step"] = "Earlier recovery guidance: stop this turn and retain any created tab."
        }
        try store.append(historical)
        let reloaded = try NativeFailureEvidenceStore(directory: directory)
        XCTAssertEqual(try reloaded.load(threadID: historical.threadID), [historical])
    }

    func testRuntimeOutcomeEvidenceReloadsAlongsideLegacyNativeFailure() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let legacy = fixture()
        let unverified = try outcomeFixture(kind: .unverified)
        let exhausted = try outcomeFixture(kind: .recoveryExhausted)
        try store.append(legacy)
        try store.append(unverified)
        try store.append(exhausted)
        let loaded = try NativeFailureEvidenceStore(directory: directory).load(threadID: "thread-1")
        XCTAssertEqual(loaded, [legacy, unverified, exhausted])
        for record in [unverified, exhausted] {
            XCTAssertFalse(record.diagnosticText.contains("https://"))
            XCTAssertFalse(record.diagnosticText.contains("query"))
            XCTAssertFalse(record.diagnosticText.contains("snapshot"))
            XCTAssertTrue(record.diagnosticText.contains("\"action_outcome\":\"unverified\""))
        }
    }

    func testRuntimeOutcomeSchemaRejectsModelProseInventedCauseAndInvalidCounts() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let valid = try outcomeFixture(kind: .unverified)
        let invalid = try [
            withDiagnostic(valid) { $0["unresolved_operations"] = true },
            withDiagnostic(valid) { $0["failed_operations"] = false },
            withDiagnostic(valid) { $0["failed_operations"] = 2.5 },
            withDiagnostic(valid) { $0["failed_operations"] = -1 },
            withDiagnostic(valid) { $0["failed_operations"] = 4 },
            withDiagnostic(valid) { $0["unresolved_operations"] = 0 },
            withDiagnostic(valid) { $0["unresolved_operations"] = 65 },
            withDiagnostic(valid) { $0["cause"] = "permission_denied" },
            withDiagnostic(valid) { $0["action_outcome"] = "search_empty" },
            withDiagnostic(valid) { $0["retry_policy"] = "retry" },
            withDiagnostic(valid) { $0["page_text"] = "unrelated mailbox email" },
            withDiagnostic(valid) { $0["next_step"] = "Model supplied instructions" },
            withDiagnostic(valid) { $0["error"] = ["code": "computer_outcome_unverified", "message": "I searched successfully"] },
        ]
        for record in invalid { XCTAssertThrowsError(try store.append(record)) }
        XCTAssertEqual(try store.load(threadID: valid.threadID), [])
        try store.append(valid)
        XCTAssertEqual(try store.load(threadID: valid.threadID), [valid])
    }

    func testRuntimeOutcomeBuilderRejectsInvalidCountsAndStoreRejectsWrongToolOrMessage() throws {
        for counts in [(0, 0), (65, 1), (1, 2), (1, -1)] {
            XCTAssertThrowsError(try ComputerOutcomeDiagnostic.make(kind: .unverified,
                unresolvedOperations: counts.0, failedOperations: counts.1))
        }
        let store = try NativeFailureEvidenceStore(directory: directory)
        let record = try outcomeFixture(kind: .unverified)
        let wrongTool = NativeFailureEvidenceStore.Record(threadID: record.threadID, turnID: record.turnID,
            callID: record.callID, toolName: "computer_v2_set_text", message: record.message,
            diagnosticText: record.diagnosticText, timestamp: record.timestamp)
        XCTAssertThrowsError(try store.append(wrongTool))
        let inventedMessage = NativeFailureEvidenceStore.Record(threadID: record.threadID, turnID: record.turnID,
            callID: record.callID, toolName: record.toolName, message: "I searched and found nothing.",
            diagnosticText: record.diagnosticText, timestamp: record.timestamp)
        XCTAssertThrowsError(try store.append(inventedMessage))
    }

    func testNavigationRecoveryCannotDisguiseAnActivationSchema() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let substitutedRecovery = try withDiagnostic(fixture()) {
            $0["error"] = ["code": "chrome_navigation_recovery_required", "message": ComputerToolFailureEvidence.navigationRecoveryDescription]
        }
        let substitutedActivation = try withDiagnostic(navigationRecoveryFixture()) {
            $0["error"] = ["code": "application_activation_failed", "message": "Application activation failed"]
        }
        XCTAssertThrowsError(try store.append(substitutedRecovery))
        XCTAssertThrowsError(try store.append(substitutedActivation))
        XCTAssertEqual(try store.load(threadID: "thread-1"), [])
    }

    func testConflictingCallIdentityFailsWithoutReplacingStoredEvidence() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let first = fixture()
        try store.append(first)
        for conflicting in [fixture(message: "A different native result."), fixture(processID: 4567), fixture(toolName: "computer_v2_type")] {
            XCTAssertThrowsError(try store.append(conflicting)) {
                XCTAssertEqual($0 as? NativeFailureEvidenceStore.StoreError, .identityConflict)
            }
        }
        XCTAssertEqual(try store.load(threadID: first.threadID), [first])
        let nextTurn = fixture(turnID: "another-turn")
        try store.append(nextTurn)
        XCTAssertEqual(try store.load(threadID: first.threadID), [first, nextTurn])
    }

    func testRecordBoundFailsWithoutEvictingEarlierCalls() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let records = (0..<NativeFailureEvidenceStore.maximumRecords).map { fixture(callID: "call-\($0)") }
        for record in records { try store.append(record) }
        XCTAssertThrowsError(try store.append(fixture(callID: "one-too-many"))) {
            XCTAssertEqual($0 as? NativeFailureEvidenceStore.StoreError, .capacityExceeded)
        }
        XCTAssertEqual(try store.load(threadID: "thread-1"), records)
    }

    func testSerializedByteBoundFailsWithoutEvictionOrPartialWrite() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        var records = [NativeFailureEvidenceStore.Record]()
        var reachedByteBound = false
        for index in 0..<NativeFailureEvidenceStore.maximumRecords {
            let record = try withDiagnostic(fixture(callID: "large-\(index)", message: String(repeating: "x", count: 1_800))) {
                $0["next_step"] = String(repeating: "safe diagnostic detail ", count: 230)
            }
            do {
                try store.append(record)
                records.append(record)
            } catch NativeFailureEvidenceStore.StoreError.capacityExceeded {
                reachedByteBound = true
                break
            }
        }
        XCTAssertTrue(reachedByteBound)
        XCTAssertFalse(records.isEmpty)
        XCTAssertLessThan(records.count, NativeFailureEvidenceStore.maximumRecords)
        XCTAssertEqual(try store.load(threadID: "thread-1"), records)
        XCTAssertLessThanOrEqual(try Data(contentsOf: fileURL("thread-1")).count, NativeFailureEvidenceStore.maximumFileBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testMalformedOrUnexpectedDiagnosticFieldsAreRejectedBeforeWriting() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let invalid = [
            fixture(threadID: ""), fixture(callID: String(repeating: "x", count: 257)),
            fixture(turnID: "turn\ncontrol"), fixture(toolName: String(repeating: "x", count: 129)),
            fixture(message: " "), fixture(message: String(repeating: "x", count: 2_049)),
            fixture(diagnosticText: "not JSON"), fixture(diagnosticText: String(repeating: "x", count: 8_193)),
            try withDiagnostic(fixture()) { $0["arguments"] = ["text": "must not be persisted"] },
            try withDiagnostic(fixture()) { $0["cause"] = "invented cause" },
            try withDiagnostic(fixture()) { $0["process_id"] = true },
            try withDiagnostic(fixture()) { $0["process_id"] = -1 },
        ]
        for record in invalid { XCTAssertThrowsError(try store.append(record)) }
        XCTAssertEqual(try store.load(threadID: "thread-1"), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCorruptedUnknownFieldWrongThreadAndDuplicateStoredIdentityFailClosed() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let record = fixture()
        try store.append(record)
        let original = try Data(contentsOf: fileURL(record.threadID))
        let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var wrongThread = originalObject
        wrongThread["threadID"] = "other-thread"
        var extraField = originalObject
        extraField["prompt"] = "unexpected content must not be accepted"
        var duplicate = originalObject
        let records = try XCTUnwrap(originalObject["records"] as? [[String: Any]])
        duplicate["records"] = records + records
        var recordWithExtraField = try XCTUnwrap(records.first)
        recordWithExtraField["arguments"] = [:] as [String: String]
        var extraRecordField = originalObject
        extraRecordField["records"] = [recordWithExtraField]
        var futureVersion = originalObject
        futureVersion["version"] = 99
        let corruptions = try [wrongThread, extraField, duplicate, extraRecordField, futureVersion]
            .map { try JSONSerialization.data(withJSONObject: $0) } + [Data("{broken".utf8)]
        for bytes in corruptions {
            try writePrivate(bytes, at: fileURL(record.threadID))
            XCTAssertThrowsError(try store.load(threadID: record.threadID))
            XCTAssertThrowsError(try store.append(fixture(callID: "new-call")))
            XCTAssertEqual(try Data(contentsOf: fileURL(record.threadID)), bytes)
        }
    }

    func testOversizedExistingFileFailsBeforeDecoding() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let bytes = Data(repeating: 0x20, count: NativeFailureEvidenceStore.maximumFileBytes + 1)
        try writePrivate(bytes, at: fileURL("thread-1"))
        XCTAssertThrowsError(try store.load(threadID: "thread-1"))
        XCTAssertThrowsError(try store.append(fixture()))
        XCTAssertEqual(try Data(contentsOf: fileURL("thread-1")), bytes)
    }

    func testSymlinkRecordAndSymlinkDirectoryAreRejectedWithoutTouchingTargets() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let target = root.appendingPathComponent("untouched.txt")
        let bytes = Data("not an evidence file".utf8)
        try writePrivate(bytes, at: target)
        try FileManager.default.createSymbolicLink(at: fileURL("thread-1"), withDestinationURL: target)
        XCTAssertThrowsError(try store.load(threadID: "thread-1"))
        XCTAssertThrowsError(try store.append(fixture()))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        let alias = root.appendingPathComponent("evidence-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try NativeFailureEvidenceStore(directory: alias))
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("does-not-exist"))
        XCTAssertThrowsError(try NativeFailureEvidenceStore(directory: dangling))
    }

    func testNonRegularRecordAndInsecurePermissionsAreRejected() throws {
        let store = try NativeFailureEvidenceStore(directory: directory)
        let path = fileURL("thread-1")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.load(threadID: "thread-1"))
        XCTAssertThrowsError(try store.append(fixture()))
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(mkfifo(path.path, 0o600), 0)
        XCTAssertThrowsError(try store.load(threadID: "thread-1"))
        XCTAssertThrowsError(try store.append(fixture()))
        try FileManager.default.removeItem(at: path)
        try store.append(fixture())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertThrowsError(try store.load(threadID: "thread-1"))
        XCTAssertThrowsError(try store.append(fixture(callID: "new-call")))
    }

    private func fixture(threadID: String = "thread-1", turnID: String = "turn-1", callID: String = "call-1",
                         toolName: String = "computer_v2_open", message: String? = nil, processID: Int32 = 1234,
                         diagnosticText: String? = nil, timestamp: Date = Date(timeIntervalSinceReferenceDate: 123_456)) -> NativeFailureEvidenceStore.Record {
        let error = ComputerInputError.applicationActivationFailed(processIdentifier: processID)
        return .init(threadID: threadID, turnID: turnID, callID: callID, toolName: toolName,
            message: message ?? ComputerToolFailureEvidence.terminalMessage(for: error)!,
            diagnosticText: diagnosticText ?? ComputerToolFailureEvidence.text(for: error), timestamp: timestamp)
    }

    private func navigationRecoveryFixture(toolName: String = "computer_v2_open", message: String? = nil) -> NativeFailureEvidenceStore.Record {
        let error = ExistingChromeError.navigationRecoveryRequired
        return .init(threadID: "thread-1", turnID: "turn-navigation", callID: "call-navigation", toolName: toolName,
            message: message ?? ComputerToolFailureEvidence.terminalMessage(for: error)!,
            diagnosticText: ComputerToolFailureEvidence.text(for: error), timestamp: Date(timeIntervalSinceReferenceDate: 123_457))
    }

    private func outcomeFixture(kind: ComputerOutcomeDiagnostic.Kind) throws -> NativeFailureEvidenceStore.Record {
        let value = try ComputerOutcomeDiagnostic.make(kind: kind, unresolvedOperations: 3, failedOperations: 2)
        return .init(threadID: "thread-1", turnID: "turn-\(kind.rawValue)", callID: "call-\(kind.rawValue)",
                     toolName: kind == .unverified ? "computer_outcome" : "computer_v2_bind_tab",
                     message: value.message, diagnosticText: value.diagnosticText,
                     timestamp: Date(timeIntervalSinceReferenceDate: 123_458))
    }

    private func withDiagnostic(_ record: NativeFailureEvidenceStore.Record,
                                change: (inout [String: Any]) -> Void) throws -> NativeFailureEvidenceStore.Record {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.diagnosticText.utf8)) as? [String: Any])
        change(&value)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        return .init(threadID: record.threadID, turnID: record.turnID, callID: record.callID, toolName: record.toolName,
            message: record.message, diagnosticText: text, timestamp: record.timestamp)
    }

    private func fileURL(_ threadID: String) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(threadID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private func writePrivate(_ bytes: Data, at url: URL) throws {
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

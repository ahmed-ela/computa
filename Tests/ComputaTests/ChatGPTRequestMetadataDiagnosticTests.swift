import Darwin
import Foundation
import XCTest
@testable import Computa

final class ChatGPTRequestMetadataDiagnosticTests: XCTestCase {
    func testOnlyExplicitRequestMetadataPurposeConsumesOneCurrentUserPreparation() throws {
        let fixture = try MetadataDiagnosticArmFixture(); defer { fixture.remove() }
        XCTAssertNil(fixture.consume())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        try fixture.arm()
        XCTAssertNil(fixture.consume(isMaintenance: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.armFile.path), "Maintenance cannot consume the user's arm")
        let lease = try XCTUnwrap(fixture.consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.armFile.path))
        XCTAssertNil(fixture.consume())
        XCTAssertTrue(lease.isCurrent)
        XCTAssertGreaterThan(lease.remainingMilliseconds, 0)
        XCTAssertLessThanOrEqual(lease.remainingMilliseconds, 600_000)
        XCTAssertTrue(lease.matches(taskID: fixture.task, threadID: fixture.thread,
                                    turnID: fixture.turn, preparationID: fixture.preparation))
        for mismatch in ["task", "thread", "turn", "preparation"] {
            XCTAssertFalse(lease.matches(taskID: mismatch == "task" ? UUID() : fixture.task,
                                         threadID: mismatch == "thread" ? UUID() : fixture.thread,
                                         turnID: mismatch == "turn" ? UUID() : fixture.turn,
                                         preparationID: mismatch == "preparation" ? UUID() : fixture.preparation), mismatch)
        }
        lease.revoke()
        XCTAssertFalse(lease.isCurrent)
        XCTAssertFalse(lease.matches(taskID: fixture.task, threadID: fixture.thread,
                                     turnID: fixture.turn, preparationID: fixture.preparation))
    }

    func testWrongPurposeScopeExpiryAndAmbiguousArmRemainUnconsumed() throws {
        let fixture = try MetadataDiagnosticArmFixture(); defer { fixture.remove() }
        for (key, value) in [
            ("taskID", UUID().uuidString.lowercased()), ("threadID", UUID().uuidString.lowercased()),
            ("taskID", fixture.task.uuidString.uppercased()), ("provider", "gemini"),
            ("purpose", "inspector"), ("purpose", "request_metadata_v2"),
            ("expiresAt", MetadataDiagnosticArmFixture.timestamp(fixture.now)),
            ("expiresAt", MetadataDiagnosticArmFixture.timestamp(fixture.now.addingTimeInterval(601))),
            ("expiresAt", "2033-05-18T03:33:20+00:00"),
        ] {
            var fields = fixture.fields(); fields[key] = value
            try fixture.write(JSONSerialization.data(withJSONObject: fields))
            XCTAssertNil(fixture.consume(), key + ":" + value)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.armFile.path))
        }
        var fields = fixture.fields(); fields.removeValue(forKey: "purpose")
        try fixture.write(JSONSerialization.data(withJSONObject: fields)); XCTAssertNil(fixture.consume())
        fields = fixture.fields(); fields["PRIVATE_EXTRA_FIELD"] = "PRIVATE_VALUE"
        try fixture.write(JSONSerialization.data(withJSONObject: fields)); XCTAssertNil(fixture.consume())
        let valid = String(decoding: try JSONSerialization.data(withJSONObject: fixture.fields()), as: UTF8.self)
        try fixture.write(Data(("{\"purpose\":\"request_metadata_v1\"," + valid.dropFirst()).utf8))
        XCTAssertNil(fixture.consume(), "Duplicate JSON keys cannot arm diagnostics")
        try fixture.write(Data(repeating: 32, count: 513)); XCTAssertNil(fixture.consume())
    }

    func testArmRequiresPrivateRegularSingleLinkFileAndRealAncestors() throws {
        let fixture = try MetadataDiagnosticArmFixture(); defer { fixture.remove() }
        try fixture.arm()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.armFile.path)
        XCTAssertNil(fixture.consume())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.armFile.path)
        let hardlink = fixture.root.appendingPathComponent("hardlink")
        XCTAssertEqual(link(fixture.armFile.path, hardlink.path), 0); XCTAssertNil(fixture.consume())
        try FileManager.default.removeItem(at: hardlink)
        let linkedDirectory = fixture.root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: fixture.directory)
        XCTAssertNil(fixture.consume(directory: linkedDirectory))
        let moved = fixture.root.appendingPathComponent("original-arm")
        try FileManager.default.moveItem(at: fixture.armFile, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.armFile, withDestinationURL: moved)
        XCTAssertNil(fixture.consume())
        try FileManager.default.removeItem(at: fixture.armFile)
        try FileManager.default.createDirectory(at: fixture.armFile, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o600])
        XCTAssertNil(fixture.consume())
        try FileManager.default.removeItem(at: fixture.armFile)
        try fixture.arm()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        XCTAssertNil(fixture.consume())
    }

    func testConcurrentArmConsumersCannotEnrollTwoPreparations() throws {
        let fixture = try MetadataDiagnosticArmFixture(); defer { fixture.remove() }
        try fixture.arm()
        let recorder = MetadataDiagnosticLeaseRecorder()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let lease = fixture.consume() { recorder.append(lease) }
        }
        XCTAssertEqual(recorder.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.armFile.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testSnapshotRoundTripsOnlyFiniteFieldsAndPreservesPendingVersusHeaders() throws {
        var headers = row(ordinal: 2)
        headers["outcome"] = "headers"; headers["settledMs"] = 25.5; headers["status"] = 200
        var rejected = row(ordinal: 3)
        rejected["outcome"] = "rejected"; rejected["settledMs"] = 30; rejected["error"] = "type_error"
        let snapshot = try parse(root(rows: [row(), headers, rejected]))
        XCTAssertTrue(snapshot.active); XCTAssertFalse(snapshot.expired); XCTAssertEqual(snapshot.rowCount, 3)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encodedData) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["schemaVersion", "active", "expired", "rows"])
        let rows = try XCTUnwrap(value["rows"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["outcome"] as? String, "pending")
        XCTAssertTrue(rows[0]["status"] is NSNull); XCTAssertTrue(rows[0]["settledMs"] is NSNull)
        XCTAssertEqual(rows[1]["outcome"] as? String, "headers")
        XCTAssertEqual(rows[1]["status"] as? Int, 200)
        XCTAssertEqual(rows[2]["outcome"] as? String, "rejected")
        XCTAssertEqual(rows[2]["error"] as? String, "type_error")
        XCTAssertTrue(rows[2]["status"] is NSNull)
        XCTAssertEqual(Set(rows[0].keys), Set(row().keys))
        XCTAssertLessThanOrEqual(snapshot.encodedData.count, 8_192)
        var ended = root(rows: []); ended["active"] = false; ended["expired"] = true
        let expired = try parse(ended)
        XCTAssertFalse(expired.active); XCTAssertTrue(expired.expired); XCTAssertEqual(expired.rowCount, 0)
    }

    func testSnapshotRejectsRequestContentMissingFieldsAndDuplicateKeys() throws {
        for field in ["url", "headers", "cookie", "body", "responseText"] {
            var unsafe = row(); unsafe[field] = "PRIVATE_REQUEST_CONTENT"
            do { _ = try parse(root(rows: [unsafe])); XCTFail("Unexpected request content accepted") }
            catch { XCTAssertFalse(String(describing: error).contains("PRIVATE_REQUEST_CONTENT")) }
            var unsafeRoot = root(rows: []); unsafeRoot[field] = "PRIVATE_REQUEST_CONTENT"
            XCTAssertThrowsError(try parse(unsafeRoot))
        }
        for field in ["bodyBytes", "keepalive", "settledMs", "error"] {
            var incomplete = row(); incomplete.removeValue(forKey: field)
            XCTAssertThrowsError(try parse(root(rows: [incomplete])), field)
        }
        let valid = String(decoding: try JSONSerialization.data(withJSONObject: root(rows: [])), as: UTF8.self)
        XCTAssertThrowsError(try ChatGPTRequestMetadataSnapshot.parse(Data(("{\"schemaVersion\":1," + valid.dropFirst()).utf8)))
        let duplicateRow = "{\"ordinal\":1," + String(decoding: try JSONSerialization.data(withJSONObject: row()), as: UTF8.self).dropFirst()
        XCTAssertThrowsError(try ChatGPTRequestMetadataSnapshot.parse(Data(("{\"schemaVersion\":1,\"active\":true,\"expired\":false,\"rows\":[" + duplicateRow + "]}").utf8)))
    }

    func testSnapshotRejectsBooleanIntegersNonfiniteTimingAndInvalidEnums() throws {
        for (field, value) in [("schemaVersion", true), ("schemaVersion", 2), ("active", 1), ("expired", "false")] as [(String, Any)] {
            var invalid = root(rows: []); invalid[field] = value
            XCTAssertThrowsError(try parse(invalid), field)
        }
        let invalidFields: [(String, Any)] = [
            ("ordinal", true), ("ordinal", 0), ("ordinal", 9), ("ordinal", 1.5),
            ("bodyBytes", true), ("bodyBytes", -1), ("bodyBytes", 1_048_577),
            ("status", true), ("status", 99), ("status", 600), ("status", 200.5),
            ("startedMs", true), ("startedMs", -1), ("startedMs", 600_001),
            ("settledMs", 9), ("endpoint", "PRIVATE_ENDPOINT"), ("origin", "https://private.invalid"),
            ("method", "DELETE"), ("bodyType", "ReadableStream"), ("keepalive", true),
            ("duplex", "full"), ("outcome", "success"), ("error", "PRIVATE_ERROR"),
        ]
        for (field, value) in invalidFields {
            var invalid = row(); invalid[field] = value
            XCTAssertThrowsError(try parse(root(rows: [invalid])), field)
        }
        let data = try JSONSerialization.data(withJSONObject: root(rows: [row()]), options: [.sortedKeys])
        let raw = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"startedMs\":10", with: "\"startedMs\":NaN")
        XCTAssertNotEqual(raw, String(decoding: data, as: UTF8.self))
        XCTAssertThrowsError(try ChatGPTRequestMetadataSnapshot.parse(Data(raw.utf8)))
    }

    func testSnapshotBoundsRowsOrderingAndEncodedInputWithoutTruncating() throws {
        let eight = (1...8).map { row(ordinal: $0) }
        XCTAssertEqual(try parse(root(rows: eight)).rowCount, 8)
        XCTAssertThrowsError(try parse(root(rows: eight + [row(ordinal: 8)])))
        XCTAssertThrowsError(try parse(root(rows: [row(), row()])))
        XCTAssertThrowsError(try parse(root(rows: [row(ordinal: 2), row(ordinal: 1)])))
        let valid = try JSONSerialization.data(withJSONObject: root(rows: []))
        let oversized = valid + Data(repeating: 32, count: 8_193 - valid.count)
        XCTAssertEqual(oversized.count, 8_193)
        XCTAssertThrowsError(try ChatGPTRequestMetadataSnapshot.parse(oversized))
        XCTAssertThrowsError(try ChatGPTRequestMetadataSnapshot.parse(Data([0xff])))
    }

    func testSnapshotRejectsContradictoryLifecycleStatesAndUnobservedBodySizes() throws {
        var expiredActive = root(rows: []); expiredActive["expired"] = true
        XCTAssertThrowsError(try parse(expiredActive))
        let contradictions: [(String, [String: Any])] = [
            ("pending timing", ["settledMs": 20]),
            ("pending status", ["status": 200]),
            ("pending error", ["error": "type_error"]),
            ("headers without timing", ["outcome": "headers"]),
            ("headers with error", ["outcome": "headers", "settledMs": 20, "error": "abort"]),
            ("rejected without timing", ["outcome": "rejected", "error": "type_error"]),
            ("rejected with status", ["outcome": "rejected", "settledMs": 20, "status": 200, "error": "type_error"]),
            ("rejected without error", ["outcome": "rejected", "settledMs": 20]),
            ("sync throw without timing", ["outcome": "sync_throw", "error": "other"]),
            ("sync throw with status", ["outcome": "sync_throw", "settledMs": 20, "status": 200, "error": "other"]),
            ("sync throw without error", ["outcome": "sync_throw", "settledMs": 20]),
            ("blob known size", ["bodyType": "blob", "bodyBytes": 4]),
            ("stream known size", ["bodyType": "stream", "bodyBytes": 0]),
            ("unknown known size", ["bodyType": "unknown", "bodyBytes": 0]),
            ("none nonzero size", ["bodyType": "none", "bodyBytes": 1]),
        ]
        for (name, fields) in contradictions {
            let invalid = row().merging(fields, uniquingKeysWith: { _, replacement in replacement })
            XCTAssertThrowsError(try parse(root(rows: [invalid])), name)
        }
        XCTAssertThrowsError(try parse(root(rows: [row(), row(ordinal: 3)])), "Ordinal gaps are not a truncated history")
        var earlier = row(ordinal: 2); earlier["startedMs"] = 9
        XCTAssertThrowsError(try parse(root(rows: [row(), earlier])), "Later rows cannot start before earlier rows")
        var blob = row(); blob["bodyType"] = "blob"; blob["bodyBytes"] = NSNull()
        var overLimitString = row(ordinal: 2); overLimitString["bodyBytes"] = NSNull()
        XCTAssertEqual(try parse(root(rows: [blob, overLimitString])).rowCount, 2,
                       "Non-string bodies and bounded string counts preserve unknown size")
    }

    private func root(rows: [[String: Any]]) -> [String: Any] {
        ["schemaVersion": 1, "active": true, "expired": false, "rows": rows]
    }

    private func row(ordinal: Int = 1) -> [String: Any] {
        ["ordinal": ordinal, "endpoint": "conversation", "origin": "same", "method": "POST",
         "bodyType": "string", "bodyBytes": 55_369, "keepalive": "false", "duplex": "absent",
         "startedMs": 10, "settledMs": NSNull(), "outcome": "pending", "status": NSNull(), "error": "none"]
    }

    private func parse(_ value: [String: Any]) throws -> ChatGPTRequestMetadataSnapshot {
        try ChatGPTRequestMetadataSnapshot.parse(JSONSerialization.data(withJSONObject: value))
    }
}

private final class MetadataDiagnosticArmFixture: @unchecked Sendable {
    let root: URL, directory: URL, armFile: URL
    let task = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let thread = UUID(), turn = UUID(), preparation = UUID()
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    init() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("computa-request-metadata-" + UUID().uuidString)
        directory = root.appendingPathComponent("WebsiteRequestMetadataDiagnostics-v1")
        armFile = directory.appendingPathComponent("arm.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func fields() -> [String: String] {
        ["taskID": task.uuidString.lowercased(), "threadID": thread.uuidString.lowercased(), "provider": "chatgpt",
         "purpose": "request_metadata_v1", "expiresAt": Self.timestamp(now.addingTimeInterval(60))]
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    func write(_ bytes: Data) throws {
        try bytes.write(to: armFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armFile.path)
    }

    func arm() throws { try write(JSONSerialization.data(withJSONObject: fields())) }

    func consume(directory: URL? = nil, isMaintenance: Bool = false) -> ChatGPTRequestMetadataLease? {
        ChatGPTRequestMetadataLease.consume(directory: directory ?? self.directory, taskID: task,
                                            threadID: thread, turnID: turn, preparationID: preparation,
                                            isMaintenance: isMaintenance, now: now)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class MetadataDiagnosticLeaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [ChatGPTRequestMetadataLease] = []
    func append(_ lease: ChatGPTRequestMetadataLease) { lock.withLock { leases.append(lease) } }
    var count: Int { lock.withLock { leases.count } }
}

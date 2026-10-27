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
        XCTAssertFalse(lease.capturesDecodedEvents)
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
        for field in ["bodyBytes", "headerMetadata", "keepalive", "settledMs", "error"] {
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

    func testHeaderAggregatesRoundTripOnlyFiniteObservedInputFieldsAndUnknownIsDistinctFromZero() throws {
        var unknown = row(), observed = row(ordinal: 2), empty = row(ordinal: 3)
        unknown["headerMetadata"] = NSNull()
        observed["headerMetadata"] = header()
        empty["headerMetadata"] = header().merging(["count": 0, "nameUTF8Bytes": 0, "valueUTF8Bytes": 0, "maxValueUTF8Bytes": 0],
                                                   uniquingKeysWith: { _, value in value })
        let snapshot = try parse(root(rows: [unknown, observed, empty]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encodedData) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertTrue(rows[0]["headerMetadata"] is NSNull)
        let finite = try XCTUnwrap(rows[1]["headerMetadata"] as? [String: Any])
        XCTAssertEqual(Set(finite.keys), Set(header().keys))
        XCTAssertEqual(finite["valueUTF8Bytes"] as? Int, 70_000)
        XCTAssertEqual((rows[2]["headerMetadata"] as? [String: Any])?["count"] as? Int, 0)
        XCTAssertNil(snapshot.profileCookieBudget)
        XCTAssertLessThanOrEqual(snapshot.encodedData.count, 8_192)
        var nativeHeaders = row(); nativeHeaders["headerMetadata"] = header().merging(["representation": "native_headers"],
                                                                                     uniquingKeysWith: { _, value in value })
        XCTAssertEqual(try parse(root(rows: [nativeHeaders])).rowCount, 1)
    }

    func testHeaderAggregateParserRejectsUnknownFieldsTypesBoundsAndContradictions() throws {
        let badFields: [(String, Any)] = [
            ("PRIVATE_HEADER_NAME", "PRIVATE_HEADER_VALUE"), ("representation", "wire"),
            ("count", true), ("count", -1), ("count", 257), ("count", 0.5),
            ("nameUTF8Bytes", true), ("nameUTF8Bytes", -1), ("nameUTF8Bytes", 1_048_577),
            ("valueUTF8Bytes", true), ("valueUTF8Bytes", 1_048_577),
            ("maxValueUTF8Bytes", true), ("maxValueUTF8Bytes", 70_001),
            ("invalidTokenName", 0), ("hasNUL", "false"), ("hasCRLF", NSNull()), ("hasNonLatin1", 1),
        ]
        for (field, value) in badFields {
            var invalid = row(); invalid["headerMetadata"] = header().merging([field: value], uniquingKeysWith: { _, value in value })
            XCTAssertThrowsError(try parse(root(rows: [invalid])), field)
        }
        for field in header().keys {
            var incomplete = header(); incomplete.removeValue(forKey: field)
            var invalid = row(); invalid["headerMetadata"] = incomplete
            XCTAssertThrowsError(try parse(root(rows: [invalid])), "missing " + field)
        }
        let contradictions: [[String: Any]] = [
            ["count": 0], ["count": 2, "nameUTF8Bytes": 1],
            ["valueUTF8Bytes": 70_001, "maxValueUTF8Bytes": 70_000], ["maxValueUTF8Bytes": 0],
            ["nameUTF8Bytes": 1_000_000, "valueUTF8Bytes": 70_000],
            ["count": 0, "nameUTF8Bytes": 0, "valueUTF8Bytes": 0, "maxValueUTF8Bytes": 0, "hasNUL": true],
            ["count": 1, "nameUTF8Bytes": 0, "valueUTF8Bytes": 0, "maxValueUTF8Bytes": 0, "invalidTokenName": true, "hasCRLF": true],
        ]
        for changes in contradictions {
            var invalid = row(); invalid["headerMetadata"] = header().merging(changes, uniquingKeysWith: { _, value in value })
            XCTAssertThrowsError(try parse(root(rows: [invalid])), String(describing: changes.keys))
        }
        for flag in ["invalidTokenName", "hasNUL", "hasCRLF", "hasNonLatin1"] {
            var invalid = row(); invalid["headerMetadata"] = header().merging(["representation": "native_headers", flag: true],
                                                                            uniquingKeysWith: { _, value in value })
            XCTAssertThrowsError(try parse(root(rows: [invalid])), "Native Headers cannot contain " + flag)
        }
        for value in ["PRIVATE", [], 0, false] as [Any] {
            var invalid = row(); invalid["headerMetadata"] = value
            XCTAssertThrowsError(try parse(root(rows: [invalid])))
        }
    }

    func testCookieEstimateIsNativeOnlyAndPersistedSeparatelyWithExplicitUnknown() throws {
        let fixture = try MetadataDiagnosticArmFixture(); defer { fixture.remove() }
        try fixture.arm()
        let lease = try XCTUnwrap(fixture.consume())
        let snapshot = try parse(root(rows: [row()]))
        XCTAssertNil(snapshot.profileCookieBudget)
        for field in ["nativeCookieBudget", "profileCookieBudget"] {
            var invalid = root(rows: []); invalid[field] = ["cookieCount": 0]
            XCTAssertThrowsError(try parse(invalid), "Page JSON cannot supply native profile metadata")
        }
        let unknownID = UUID()
        XCTAssertTrue(lease.persist(snapshot, inferenceID: unknownID, sessionToken: UUID()))
        let unknown = try persisted(inferenceID: unknownID, fixture: fixture)
        XCTAssertTrue(unknown["nativeCookieBudget"] is NSNull)
        XCTAssertEqual(unknown["purpose"] as? String, "request_metadata_v1")
        let budget = try XCTUnwrap(ChatGPTProfileCookieBudget.estimate(cookies: []))
        let attached = snapshot.attachingProfileCookieBudget(budget)
        XCTAssertNotNil(attached.profileCookieBudget)
        XCTAssertEqual(attached.encodedData, snapshot.encodedData, "Native estimates never become page JSON")
        let knownID = UUID()
        XCTAssertTrue(lease.persist(attached, inferenceID: knownID, sessionToken: UUID()))
        let known = try persisted(inferenceID: knownID, fixture: fixture)
        XCTAssertEqual((known["nativeCookieBudget"] as? [String: Any])?["source"] as? String, "profile_estimate")
        XCTAssertEqual((known["nativeCookieBudget"] as? [String: Any])?["cookieCount"] as? Int, 0)
        XCTAssertNil((known["diagnostic"] as? [String: Any])?["nativeCookieBudget"])
        XCTAssertFalse(lease.persist(attached, inferenceID: knownID, sessionToken: UUID()), "Sidecars cannot be overwritten")
    }

    func testDecodedCaptureRequiresItsExactExplicitPurposeAndCannotCrossPersistModes() throws {
        let v1 = try MetadataDiagnosticArmFixture(); defer { v1.remove() }
        try v1.arm()
        let v1Lease = try XCTUnwrap(v1.consume())
        let v2 = try MetadataDiagnosticArmFixture(purpose: "request_and_decoded_metadata_v2"); defer { v2.remove() }
        XCTAssertNil(v2.consume())
        try v2.arm()
        XCTAssertNil(v2.consume(isMaintenance: true))
        let v2Lease = try XCTUnwrap(v2.consume())
        XCTAssertTrue(v2Lease.capturesDecodedEvents)
        XCTAssertTrue(v2Lease.matches(taskID: v2.task, threadID: v2.thread, turnID: v2.turn, preparationID: v2.preparation))
        XCTAssertFalse(v2Lease.matches(taskID: v2.task, threadID: v2.thread, turnID: UUID(), preparationID: v2.preparation))
        XCTAssertFalse(v2Lease.matches(taskID: v2.task, threadID: v2.thread, turnID: v2.turn, preparationID: UUID()))
        XCTAssertNil(v2.consume(), "The new purpose has the same one-use claim")
        let old = try parse(root(rows: [])), decoded = try parse(decodedRoot())
        XCTAssertFalse(v1Lease.persist(decoded, inferenceID: UUID(), sessionToken: UUID()))
        XCTAssertFalse(v2Lease.persist(old, inferenceID: UUID(), sessionToken: UUID()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: v1.directory.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: v2.directory.path).isEmpty)
        let inference = UUID()
        XCTAssertTrue(v2Lease.persist(decoded, inferenceID: inference, sessionToken: UUID()))
        let persisted = try persisted(inferenceID: inference, fixture: v2)
        XCTAssertEqual(persisted["schemaVersion"] as? Int, 1, "The native wrapper schema remains unchanged")
        XCTAssertEqual(persisted["purpose"] as? String, "request_and_decoded_metadata_v2")
        XCTAssertEqual((persisted["diagnostic"] as? [String: Any])?["schemaVersion"] as? Int, 2)
        XCTAssertTrue(persisted["nativeCookieBudget"] is NSNull)
        v2Lease.revoke()
        XCTAssertFalse(v2Lease.isCurrent)
        XCTAssertFalse(v2Lease.persist(decoded, inferenceID: UUID(), sessionToken: UUID()))
    }

    func testDecodedPurposeReusesExactScopeExpiryAndPrivateArmGuards() throws {
        let fixture = try MetadataDiagnosticArmFixture(purpose: "request_and_decoded_metadata_v2"); defer { fixture.remove() }
        let invalid: [(String, String)] = [
            ("purpose", "request_and_decoded_metadata_v1"), ("purpose", "request_and_decoded_metadata_v2 "),
            ("taskID", UUID().uuidString.lowercased()), ("threadID", UUID().uuidString.lowercased()),
            ("provider", "claude"), ("expiresAt", MetadataDiagnosticArmFixture.timestamp(fixture.now)),
            ("expiresAt", MetadataDiagnosticArmFixture.timestamp(fixture.now.addingTimeInterval(601))),
        ]
        for (field, value) in invalid {
            try fixture.write(JSONSerialization.data(withJSONObject: fixture.fields().merging([field: value], uniquingKeysWith: { _, v in v })))
            XCTAssertNil(fixture.consume(), field)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.armFile.path))
        }
        let valid = String(decoding: try JSONSerialization.data(withJSONObject: fixture.fields()), as: UTF8.self)
        try fixture.write(Data(("{\"purpose\":\"request_and_decoded_metadata_v2\"," + valid.dropFirst()).utf8))
        XCTAssertNil(fixture.consume(), "The new purpose cannot bypass duplicate-key rejection")
        try fixture.arm()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.armFile.path)
        XCTAssertNil(fixture.consume())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.armFile.path)
        let linkedDirectory = fixture.root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: fixture.directory)
        XCTAssertNil(fixture.consume(directory: linkedDirectory))
        let hardlink = fixture.root.appendingPathComponent("hardlink")
        XCTAssertEqual(link(fixture.armFile.path, hardlink.path), 0)
        XCTAssertNil(fixture.consume())
        try FileManager.default.removeItem(at: hardlink)
        XCTAssertNotNil(fixture.consume())
    }

    func testDecodedLeaseCannotClaimOrPersistAfterItsOriginalDeadline() async throws {
        let fixture = try MetadataDiagnosticArmFixture(purpose: "request_and_decoded_metadata_v2"); defer { fixture.remove() }
        var fields = fixture.fields()
        fields["expiresAt"] = MetadataDiagnosticArmFixture.timestamp(fixture.now.addingTimeInterval(1))
        try fixture.write(JSONSerialization.data(withJSONObject: fields))
        let lease = try XCTUnwrap(fixture.consume())
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertFalse(lease.isCurrent)
        XCTAssertEqual(lease.remainingMilliseconds, 0)
        XCTAssertFalse(lease.claim(view: ObjectIdentifier(fixture)))
        XCTAssertFalse(lease.matches(taskID: fixture.task, threadID: fixture.thread, turnID: fixture.turn, preparationID: fixture.preparation))
        XCTAssertFalse(lease.persist(try parse(decodedRoot()), inferenceID: UUID(), sessionToken: UUID()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testDecodedSnapshotRoundTripsFiniteStatesProgramsAndExplicitUnknowns() throws {
        for state in ["pending", "unavailable", "installed", "restored", "superseded"] {
            let snapshot = try parse(decodedRoot(decoder: decoder().merging(["state": state], uniquingKeysWith: { _, v in v })))
            XCTAssertEqual(snapshot.schemaVersion, 2)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encodedData) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["schemaVersion", "active", "expired", "rows", "decoder"])
            XCTAssertEqual((object["decoder"] as? [String: Any])?["state"] as? String, state)
            XCTAssertLessThanOrEqual(snapshot.encodedData.count, 8_192)
        }
        for carrier in ["message", "reference", "reference_patch"] {
            for status in ["in_progress", "finished_successfully", "finished_partial", "other", "unknown"] {
                var program = lastProgram(); program["carrier"] = carrier; program["messageStatus"] = status
                let snapshot = try parse(decodedRoot(decoder: decoder(program: program)))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encodedData) as? [String: Any])
                let observed = try XCTUnwrap((object["decoder"] as? [String: Any])?["lastProgram"] as? [String: Any])
                XCTAssertEqual(observed["carrier"] as? String, carrier)
                XCTAssertEqual(observed["messageStatus"] as? String, status)
                XCTAssertEqual(observed["codeLength"] as? Int, 194)
            }
        }
        var unknown = lastProgram()
        unknown["codeLength"] = NSNull(); unknown["knownNullProgram"] = false
        unknown["emptyFallbackMarkdown"] = NSNull(); unknown["recovery"] = "unknown"
        unknown["recoveryLine"] = NSNull(); unknown["recoveryColumn"] = NSNull()
        XCTAssertNoThrow(try parse(decodedRoot(decoder: decoder(program: unknown))))
        for matches in [true, false] {
            var program = lastProgram(); program["conversationMatchesDocument"] = matches
            XCTAssertNoThrow(try parse(decodedRoot(decoder: decoder(program: program))))
        }
        var none = unknown; none["recovery"] = "none"
        XCTAssertNoThrow(try parse(decodedRoot(decoder: decoder(program: none))))
        XCTAssertEqual(try parse(root(rows: [])).schemaVersion, 1)
        var v1WithDecoder = root(rows: []); v1WithDecoder["decoder"] = decoder()
        XCTAssertThrowsError(try parse(v1WithDecoder), "v1 has exactly its original four keys")
    }

    func testDecodedSnapshotRejectsPrivateMissingDuplicateAndOversizedContent() throws {
        for field in ["code", "fallback", "text", "messageID", "conversationID", "url", "headers", "responseBody"] {
            for level in ["root", "decoder", "program"] {
                var object = decodedRoot(), capture = decoder(program: lastProgram()), program = lastProgram()
                if level == "root" { object[field] = "PRIVATE_DECODED_CONTENT" }
                if level == "decoder" { capture[field] = "PRIVATE_DECODED_CONTENT" }
                if level == "program" { program[field] = "PRIVATE_DECODED_CONTENT"; capture["lastProgram"] = program }
                if level != "root" { object["decoder"] = capture }
                do { _ = try parse(object); XCTFail("Unexpected decoded content accepted") }
                catch { XCTAssertFalse(String(describing: error).contains("PRIVATE_DECODED_CONTENT")) }
            }
        }
        for key in decoder().keys {
            var value = decoder(); value.removeValue(forKey: key)
            XCTAssertThrowsError(try parse(decodedRoot(decoder: value)), key)
        }
        for key in lastProgram().keys {
            var value = lastProgram(); value.removeValue(forKey: key)
            XCTAssertThrowsError(try parse(decodedRoot(decoder: decoder(program: value))), key)
        }
        let valid = String(decoding: try JSONSerialization.data(withJSONObject: decodedRoot(decoder: decoder(program: lastProgram())), options: [.sortedKeys]), as: UTF8.self)
        for (needle, replacement) in [("\"state\":\"installed\"", "\"state\":\"installed\",\"state\":\"installed\""),
                                      ("\"codeLength\":194", "\"codeLength\":194,\"codeLength\":194")] {
            let duplicate = valid.replacingOccurrences(of: needle, with: replacement)
            XCTAssertNotEqual(valid, duplicate)
            XCTAssertThrowsError(try ChatGPTRequestMetadataSnapshot.parse(Data(duplicate.utf8)))
        }
        let bytes = Data(valid.utf8)
        XCTAssertThrowsError(try ChatGPTRequestMetadataSnapshot.parse(bytes + Data(repeating: 32, count: 8_193 - bytes.count)))
        var missing = decodedRoot(); missing.removeValue(forKey: "decoder")
        XCTAssertThrowsError(try parse(missing))
    }

    func testDecodedSnapshotRejectsTypesBoundsEnumsAndContradictoryCardinality() throws {
        for field in ["completionCalls", "programObservations", "recoveredNullObservations"] {
            for value in [true, -1, 65_536, 0.5, "1", NSNull()] as [Any] {
                var capture = decoder(); capture[field] = value
                XCTAssertThrowsError(try parse(decodedRoot(decoder: capture)), field)
            }
        }
        let badProgram: [(String, Any)] = [
            ("elapsedMs", true), ("elapsedMs", -1), ("elapsedMs", 600_001), ("elapsedMs", NSNull()),
            ("carrier", "PRIVATE_CARRIER"), ("messageStatus", "complete"),
            ("codeLength", true), ("codeLength", -1), ("codeLength", 1_048_577), ("codeLength", 194.5),
            ("knownNullProgram", 1), ("knownNullProgram", NSNull()),
            ("emptyFallbackMarkdown", 0), ("emptyFallbackMarkdown", "true"),
            ("conversationMatchesDocument", 1), ("conversationMatchesDocument", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            ("recovery", "PRIVATE_RECOVERY"), ("recoveryLine", true), ("recoveryLine", 0),
            ("recoveryLine", 1_048_577), ("recoveryColumn", 1.5), ("recoveryColumn", 0), ("recoveryColumn", 1_048_577),
        ]
        for (field, value) in badProgram {
            var program = lastProgram(); program[field] = value
            XCTAssertThrowsError(try parse(decodedRoot(decoder: decoder(program: program))), field)
        }
        let contradictions: [[String: Any]] = [["completionCalls": 0], ["programObservations": 0], ["recoveredNullObservations": 2]]
        for changes in contradictions {
            let value = decoder(program: lastProgram()).merging(changes, uniquingKeysWith: { _, v in v })
            XCTAssertThrowsError(try parse(decodedRoot(decoder: value)))
        }
        var noLast = decoder(); noLast["programObservations"] = 1; noLast["completionCalls"] = 1
        XCTAssertThrowsError(try parse(decodedRoot(decoder: noLast)))
        for length in [NSNull(), 193, 195] as [Any] {
            var program = lastProgram(); program["codeLength"] = length
            XCTAssertThrowsError(try parse(decodedRoot(decoder: decoder(program: program))))
        }
        var none = lastProgram(); none["recovery"] = "none"
        XCTAssertThrowsError(try parse(decodedRoot(decoder: decoder(program: none))))
        var state = decoder(); state["state"] = "complete"
        XCTAssertThrowsError(try parse(decodedRoot(decoder: state)))
        var version = decodedRoot(); version["schemaVersion"] = 3
        XCTAssertThrowsError(try parse(version))
        var maximum = lastProgram()
        maximum["elapsedMs"] = 600_000; maximum["codeLength"] = 1_048_576; maximum["knownNullProgram"] = false
        maximum["recoveryLine"] = 1_048_576; maximum["recoveryColumn"] = 1_048_576
        let maximumCounts: [String: Any] = ["completionCalls": 65_535, "programObservations": 65_535, "recoveredNullObservations": 65_535]
        XCTAssertNoThrow(try parse(decodedRoot(decoder: decoder(program: maximum).merging(maximumCounts, uniquingKeysWith: { _, v in v }))))
    }

    func testDecodedStreamCountersRejectPrivateFieldsTypesAndImpossibleCounts() throws {
        let baseline = decoder()
        let stream = try XCTUnwrap(baseline["stream"] as? [String: Any])
        for key in stream.keys {
            var missing = stream; missing.removeValue(forKey: key)
            var value = baseline; value["stream"] = missing
            XCTAssertThrowsError(try parse(decodedRoot(decoder: value)), key)
        }
        for (key, value) in [("errorEvents", true), ("inputMessages", -1), ("assistantMessages", 65_536),
                             ("nonemptyTextMessages", 1), ("opaqueMessages", 1), ("decoderInstances", 17),
                             ("decoderOverflow", 1), ("decoderOverflow", true), ("text", "PRIVATE")] as [(String, Any)] {
            var changed = stream; changed[key] = value
            var capture = baseline; capture["stream"] = changed
            XCTAssertThrowsError(try parse(decodedRoot(decoder: capture)), key)
        }
        var withThrow = stream; withThrow["originalThrows"] = 1; withThrow["decoderInstances"] = 1
        var capture = baseline; capture["stream"] = withThrow
        XCTAssertNoThrow(try parse(decodedRoot(decoder: capture)), "An original throw need not produce a decoded return")
    }

    private func decodedRoot(decoder: [String: Any]? = nil) -> [String: Any] {
        ["schemaVersion": 2, "active": true, "expired": false, "rows": [], "decoder": decoder ?? self.decoder()]
    }

    private func decoder(program: [String: Any]? = nil) -> [String: Any] {
        ["state": "installed", "completionCalls": program == nil ? 0 : 1,
         "programObservations": program == nil ? 0 : 1, "recoveredNullObservations": program == nil ? 0 : 1,
         "lastProgram": program.map { $0 as Any } ?? NSNull(), "stream": ["inputMessages": 0, "assistantMessages": 0, "nonemptyTextMessages": 0, "opaqueMessages": 0, "mainTerminals": 0, "messageTerminals": 0, "errorEvents": 0, "originalThrows": 0, "decoderInstances": 0, "decoderOverflow": false]]
    }

    private func lastProgram() -> [String: Any] {
        ["elapsedMs": 25.5, "carrier": "reference", "messageStatus": "finished_successfully", "codeLength": 194,
         "knownNullProgram": true, "emptyFallbackMarkdown": true,
         "conversationMatchesDocument": NSNull(),
         "recovery": "unterminated_braced_value_recovered_parse", "recoveryLine": 1, "recoveryColumn": 1]
    }

    private func persisted(inferenceID: UUID, fixture: MetadataDiagnosticArmFixture) throws -> [String: Any] {
        let path = fixture.directory.appendingPathComponent("request-metadata-" + inferenceID.uuidString.lowercased() + ".json")
        let data = try Data(contentsOf: path)
        XCTAssertLessThanOrEqual(data.count, 9_216)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func header() -> [String: Any] {
        ["representation": "record", "count": 1, "nameUTF8Bytes": 13, "valueUTF8Bytes": 70_000, "maxValueUTF8Bytes": 70_000,
         "invalidTokenName": false, "hasNUL": false, "hasCRLF": false, "hasNonLatin1": false]
    }

    private func root(rows: [[String: Any]]) -> [String: Any] {
        ["schemaVersion": 1, "active": true, "expired": false, "rows": rows]
    }

    private func row(ordinal: Int = 1) -> [String: Any] {
        ["ordinal": ordinal, "endpoint": "conversation", "origin": "same", "method": "POST",
         "bodyType": "string", "bodyBytes": 55_369, "keepalive": "false", "duplex": "absent",
         "headerMetadata": NSNull(),
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
    let purpose: String

    init(purpose: String = "request_metadata_v1") throws {
        self.purpose = purpose
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
         "purpose": purpose, "expiresAt": Self.timestamp(now.addingTimeInterval(60))]
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

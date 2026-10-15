import XCTest
import Darwin
@testable import Computa

final class APIModelCorrectionTests: XCTestCase {
    private let id = "550e8400-e29b-41d4-a716-446655440000"
    private let usage = APIModelCorrectionUsage(inputTokens: 120, outputTokens: 80, totalTokens: 200,
                                               cachedInputTokens: 40, reasoningOutputTokens: 20)
    private func root() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(path) }
        let url = URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent("ComputaCorrection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func records(_ directory: URL) throws -> [APIModelCorrectionAccounting.Record] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(APIModelCorrectionAccounting.Record.self, from: Data(contentsOf: $0)) }
    }
    func testJSONCorrectionEligibilityScopesCreatedLexemesToEnvelopeAndPreservesNestedDuplicateAndCounterGuards() throws {
        // Matches the documented response shape without requiring a provider ID.
        let documented = Data(#"{"created":1775679664,"time_info":{"queue_time":0.000630072,"prompt_time":0.006339716,"completion_time":0.01440533,"total_time":0.022999626968,"created":1775679664.285658}}"#.utf8)
        XCTAssertTrue(APIModelCorrectionJSON.isUnambiguous(documented))
        XCTAssertNil(APIModelCorrectionJSON.rejectionDiagnostic(documented))
        for raw in [#"{"created":1775679664.0,"time_info":{"created":1775679664.285658}}"#,
                    #"{"created":1e0}"#, #"{"created":-0}"#,
                    #"{"created":1775679664,"time_info":{"created":1.5,"created":2.5}}"#,
                    #"{"created":1775679664,"metadata":{"prompt_tokens":1.5}}"#,
                    #"{"created":1775679664,"metadata":{"index":0.0}}"#] {
            XCTAssertFalse(APIModelCorrectionJSON.isUnambiguous(Data(raw.utf8)))
            XCTAssertNotNil(APIModelCorrectionJSON.rejectionDiagnostic(Data(raw.utf8)))
        }
        let escaped = Data(#"{"\u0063reated":1775679664,"time_info":{"\u0063reated":1775679664.285658}}"#.utf8)
        XCTAssertTrue(APIModelCorrectionJSON.isUnambiguous(escaped))
    }
    func testJSONRejectionDiagnosticsDistinguishDuplicateKeysAndIntegerLexemesWithoutValues() throws {
        let cases: [(String, APIModelCorrectionJSON.RejectionDiagnostic.Reason, APIModelCorrectionJSON.RejectionDiagnostic.KeyCategory)] = [
            (#"{"created":1.0}"#, .integerLexeme, .createdTimestamp),
            (#"{"created":1e0}"#, .integerLexeme, .createdTimestamp),
            (#"{"index":-0}"#, .integerLexeme, .choiceIndex),
            (#"{"total_tokens":1.5}"#, .integerLexeme, .usageCounter),
            (#"{"created":12345678901234567}"#, .integerLength, .createdTimestamp),
            (#"{"created":1,"\u0063reated":1}"#, .duplicateKey, .createdTimestamp),
            (#"{"PRIVATE_KEY_URL_SECRET":1,"PRIVATE_KEY_URL_SECRET":2}"#, .duplicateKey, .other)]
        for (raw, reason, keyCategory) in cases {
            let data = Data(raw.utf8)
            XCTAssertFalse(APIModelCorrectionJSON.isUnambiguous(data))
            let diagnostic = try XCTUnwrap(APIModelCorrectionJSON.rejectionDiagnostic(data))
            XCTAssertEqual(diagnostic.reason, reason); XCTAssertEqual(diagnostic.keyCategory, keyCategory)
            XCTAssertFalse(APIModelCorrectionJSON.isUnambiguous(data), "Observation cannot change admission")
            let encoded = try JSONEncoder().encode(diagnostic), text = String(decoding: encoded, as: UTF8.self)
            XCTAssertLessThanOrEqual(encoded.count, 128)
            XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: encoded) as! [String: Any]).keys), ["reason", "keyCategory"])
            for privateValue in ["PRIVATE", "12345678901234567", "1.00000000000000001", "URL", "SECRET", "http"] { XCTAssertFalse(text.contains(privateValue)) }
        }
        // Strings containing tool arguments remain opaque, including inner
        // duplicate keys and decimals that would fail the outer scanner.
        let opaque = Data(#"{"created":1,"index":0,"arguments":"{\"PRIVATE_KEY\":1,\"PRIVATE_KEY\":2,\"created\":1.0}"}"#.utf8)
        XCTAssertTrue(APIModelCorrectionJSON.isUnambiguous(opaque)); XCTAssertNil(APIModelCorrectionJSON.rejectionDiagnostic(opaque))
    }
    func testJSONRejectionDiagnosticsPreserveDepthNodeSizeAndFoundationBounds() throws {
        let maximumNodes = Data(("[" + Array(repeating: "0", count: 16_383).joined(separator: ",") + "]").utf8)
        XCTAssertTrue(APIModelCorrectionJSON.isUnambiguous(maximumNodes)); XCTAssertNil(APIModelCorrectionJSON.rejectionDiagnostic(maximumNodes))
        let tooManyNodes = Data(("[" + Array(repeating: "0", count: 16_384).joined(separator: ",") + "]").utf8)
        let depth64 = Data((String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64)).utf8)
        XCTAssertTrue(APIModelCorrectionJSON.isUnambiguous(depth64)); XCTAssertNil(APIModelCorrectionJSON.rejectionDiagnostic(depth64))
        let depth65 = Data((String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8)
        let oversized = Data(repeating: 32, count: APIProviderHTTPClient.maximumResponseBytes + 1)
        for (data, reason) in [(tooManyNodes, APIModelCorrectionJSON.RejectionDiagnostic.Reason.nodeLimit),
                               (depth65, .depthLimit), (oversized, .dataLimit), (Data("PRIVATE_INVALID_JSON".utf8), .foundationJSON)] {
            XCTAssertFalse(APIModelCorrectionJSON.isUnambiguous(data))
            let diagnostic = try XCTUnwrap(APIModelCorrectionJSON.rejectionDiagnostic(data))
            XCTAssertEqual(diagnostic.reason, reason); XCTAssertEqual(diagnostic.keyCategory, .none)
            XCTAssertFalse(APIModelCorrectionJSON.isUnambiguous(data))
        }
    }
    func testFirstKnownUsageIsDurableAndSecondAbsentIsUnknownAfterCancellation() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("APIModelCorrectionUsage-v1"), store = APIModelCorrectionAccounting(directory: directory)
        let ticket = try store.begin(taskID: id, threadID: id, turnID: id, firstUsage: usage)
        let firstFile = directory.appendingPathComponent(ticket.id.uuidString.lowercased() + ".first_received.json")
        let firstBytes = try Data(contentsOf: firstFile)
        XCTAssertEqual(try records(directory).count, 1)
        if directory.path.hasPrefix("/private/var/") {
            XCTAssertNotEqual(directory.path, directory.standardizedFileURL.path,
                              "Foundation's spelling change must not revoke an already-owned physical directory")
        }
        XCTAssertThrowsError(try store.finish(ticket, claimed: true, usage: nil, outcome: .cancelled), "An unclaimed second request cannot be recorded as claimed")
        try store.claimed(ticket)
        try store.finish(ticket, claimed: true, usage: nil, outcome: .cancelled)
        let all = try records(directory), final = try XCTUnwrap(all.first { $0.phase == "finished" })
        XCTAssertEqual(all.count, 3); XCTAssertEqual(final.firstUsage, usage)
        XCTAssertNil(final.secondUsage); XCTAssertTrue(final.secondUsageUnknown)
        XCTAssertEqual(final.outcome, .cancelled); XCTAssertTrue(final.secondRequestClaimed)
        XCTAssertEqual(try Data(contentsOf: firstFile), firstBytes)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file), attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertLessThanOrEqual(bytes.count, 2_048); XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o400)
            let text = String(decoding: bytes, as: UTF8.self)
            for forbidden in ["prompt", "arguments", "http", "credential", "reasoning_text", "tool_schema"] { XCTAssertFalse(text.contains(forbidden)) }
        }
    }
    func testCompletedCorrectionPreservesSeparateKnownUsageAndExclusiveTerminalRecord() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal"), store = APIModelCorrectionAccounting(directory: directory)
        let ticket = try store.begin(taskID: id, threadID: id, turnID: id, firstUsage: usage)
        try store.claimed(ticket); try store.finish(ticket, claimed: true, usage: usage, outcome: .responseValidated)
        let final = try XCTUnwrap(records(directory).first { $0.phase == "finished" })
        XCTAssertEqual(final.secondUsage, usage); XCTAssertFalse(final.secondUsageUnknown)
        XCTAssertEqual(try final.firstUsage.adding(XCTUnwrap(final.secondUsage)).totalTokens, 400)
        let file = directory.appendingPathComponent(ticket.id.uuidString.lowercased() + ".finished.json"), before = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.finish(ticket, claimed: true, usage: nil, outcome: .cancelled))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertThrowsError(try usage.adding(.init(inputTokens: Int.max, outputTokens: 0, totalTokens: Int.max, cachedInputTokens: 0, reasoningOutputTokens: 0)))
    }
    func testRecoveredFirstValidationIsDurableBeforeSecondClaimAndRetainedInAllPhases() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal"), store = APIModelCorrectionAccounting(directory: directory)
        let observed = APIModelResponseCodec.ArgumentValidationDiagnostic(reason: .schemaMismatch,
            schemaFailures: [.init(toolIndex: 0, constraint: .typeMismatch)], callCount: 2, rejectedCount: 1,
            envelopeShapeValid: true, unambiguousJSON: true, streamShapeAndUsageValid: true, knownUsage: true, correctionEligible: true)
        let finite = try XCTUnwrap(APIModelCorrectionAccounting.FirstValidation(observed))
        let ticket = try store.begin(taskID: id, threadID: id, turnID: id, firstUsage: usage, firstValidation: finite)
        let firstFile = directory.appendingPathComponent(ticket.id.uuidString.lowercased() + ".first_received.json")
        let firstBytes = try Data(contentsOf: firstFile)
        XCTAssertEqual(try JSONDecoder().decode(APIModelCorrectionAccounting.Record.self, from: firstBytes).firstValidation, finite)
        try store.claimed(ticket); try store.finish(ticket, claimed: true, usage: usage, outcome: .responseValidated)
        let all = try records(directory)
        XCTAssertEqual(all.count, 3); XCTAssertTrue(all.allSatisfy { $0.schemaVersion == 2 && $0.firstValidation == finite })
        XCTAssertEqual(try Data(contentsOf: firstFile), firstBytes)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let raw = try Data(contentsOf: file), text = String(decoding: raw, as: UTF8.self)
            XCTAssertLessThanOrEqual(raw.count, 2_048)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
            for forbidden in ["prompt", "arguments", "cmd", "PRIVATE", "schema_path", "wireName", "http"] { XCTAssertFalse(text.contains(forbidden)) }
        }
        let forged = APIModelCorrectionAccounting.Ticket(id: ticket.id, taskID: id, threadID: id, turnID: id, firstUsage: usage)
        XCTAssertThrowsError(try store.claimed(forged), "Dropping observed diagnostic cannot match the original immutable first record")
    }
    func testFirstValidationRejectsPrivateFieldsUnknownValuesAndUnboundedCounts() throws {
        let observed = APIModelResponseCodec.ArgumentValidationDiagnostic(reason: .schemaMismatch,
            schemaFailures: [.init(toolIndex: 0, constraint: .typeMismatch)], callCount: 2, rejectedCount: 1,
            envelopeShapeValid: true, unambiguousJSON: true, streamShapeAndUsageValid: true, knownUsage: true, correctionEligible: true)
        let finite = try XCTUnwrap(APIModelCorrectionAccounting.FirstValidation(observed))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(finite)) as? [String: Any])
        var variants: [[String: Any]] = []
        var value = object; value["prompt"] = "PRIVATE_CANARY"; variants.append(value)
        value = object; value["reason"] = "PRIVATE_CANARY"; variants.append(value)
        value = object; value["callCount"] = 129; variants.append(value)
        value = object; value["rejectedCount"] = 3; variants.append(value)
        value = object; value["schemaFailures"] = Array(repeating: ["toolIndex": 0, "constraint": "type_mismatch"], count: 3); variants.append(value)
        value = object; value["schemaFailures"] = [["toolIndex": 128, "constraint": "type_mismatch"]]; variants.append(value)
        value = object; value["schemaFailures"] = [["toolIndex": 0, "constraint": "type_mismatch", "path": "PRIVATE_CANARY"]]; variants.append(value)
        for variant in variants {
            XCTAssertThrowsError(try JSONDecoder().decode(APIModelCorrectionAccounting.FirstValidation.self,
                from: JSONSerialization.data(withJSONObject: variant)))
        }
        let invalid = APIModelResponseCodec.ArgumentValidationDiagnostic(reason: .invalidJSON, callCount: 129, rejectedCount: 1,
            envelopeShapeValid: true, unambiguousJSON: true, streamShapeAndUsageValid: true, knownUsage: true, correctionEligible: true)
        XCTAssertNil(APIModelCorrectionAccounting.FirstValidation(invalid))
    }
    func testLegacyCorrectionRecordStaysVersionOneAndUnknownRecordFieldsFailClosed() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = APIModelCorrectionAccounting(directory: root.appendingPathComponent("journal"))
        _ = try store.begin(taskID: id, threadID: id, turnID: id, firstUsage: usage)
        let value = try XCTUnwrap(records(store.directory).first), raw = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(value.schemaVersion, 1); XCTAssertNil(value.firstValidation); XCTAssertNil(object["firstValidation"])
        object["prompt"] = "PRIVATE_CANARY"
        XCTAssertThrowsError(try JSONDecoder().decode(APIModelCorrectionAccounting.Record.self,
            from: JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "prompt"); object["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(APIModelCorrectionAccounting.Record.self,
            from: JSONSerialization.data(withJSONObject: object)), "Version2 requires its finite projection")
        object["schemaVersion"] = 1
        var usage = try XCTUnwrap(object["firstUsage"] as? [String: Any]); usage["prompt"] = "PRIVATE_CANARY"; object["firstUsage"] = usage
        XCTAssertThrowsError(try JSONDecoder().decode(APIModelCorrectionAccounting.Record.self,
            from: JSONSerialization.data(withJSONObject: object)), "Usage metadata cannot hide private extra fields")
    }
    func testAccountingRejectsSymlinkDirectoryAncestorUnsafeModeAndNoncanonicalIdentity() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        for directory in [alias, alias.appendingPathComponent("child")] {
            XCTAssertThrowsError(try APIModelCorrectionAccounting(directory: directory).begin(taskID: id, threadID: id, turnID: id, firstUsage: usage))
        }
        let unsafe = root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try APIModelCorrectionAccounting(directory: unsafe).begin(taskID: id, threadID: id, turnID: id, firstUsage: usage))
        let store = APIModelCorrectionAccounting(directory: root.appendingPathComponent("valid"))
        var decorated = try XCTUnwrap(URLComponents(url: root.appendingPathComponent("decorated"), resolvingAgainstBaseURL: false))
        decorated.query = "not_directory_metadata"
        XCTAssertThrowsError(try APIModelCorrectionAccounting(directory: XCTUnwrap(decorated.url)).begin(taskID: id, threadID: id, turnID: id, firstUsage: usage))
        decorated.query = nil; decorated.fragment = "not_directory_metadata"
        XCTAssertThrowsError(try APIModelCorrectionAccounting(directory: XCTUnwrap(decorated.url)).begin(taskID: id, threadID: id, turnID: id, firstUsage: usage))
        decorated.fragment = nil; decorated.host = "foreign.invalid"
        XCTAssertThrowsError(try APIModelCorrectionAccounting(directory: XCTUnwrap(decorated.url)).begin(taskID: id, threadID: id, turnID: id, firstUsage: usage))
        for invalid in ["../../private", id.uppercased(), "PRIVATE_SECRET"] {
            XCTAssertThrowsError(try store.begin(taskID: invalid, threadID: id, turnID: id, firstUsage: usage))
        }
        XCTAssertThrowsError(try store.begin(taskID: id, threadID: id, turnID: id,
            firstUsage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 0, cachedInputTokens: 0, reasoningOutputTokens: 0)))
    }
    func testChangedFirstReceiptForgedTicketAndWrongFileTypesNeverAuthorizeSecondClaim() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("journal"), store = APIModelCorrectionAccounting(directory: directory)
        let ticket = try store.begin(taskID: id, threadID: id, turnID: id, firstUsage: usage)
        let forged = APIModelCorrectionAccounting.Ticket(id: ticket.id, taskID: id, threadID: id, turnID: id,
            firstUsage: .init(inputTokens: 0, outputTokens: 0, totalTokens: 0, cachedInputTokens: 0, reasoningOutputTokens: 0))
        XCTAssertThrowsError(try store.claimed(forged))
        let first = directory.appendingPathComponent(ticket.id.uuidString.lowercased() + ".first_received.json")
        let backup = root.appendingPathComponent("backup"); try FileManager.default.moveItem(at: first, to: backup)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: backup)
        XCTAssertThrowsError(try store.claimed(ticket))
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(mkfifo(first.path, 0o600), 0)
        XCTAssertThrowsError(try store.claimed(ticket), "O_NONBLOCK and regular-file checks prevent a FIFO hang")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(ticket.id.uuidString.lowercased() + ".second_claimed.json").path))
    }
}

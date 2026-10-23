import Darwin
import Foundation
import XCTest
@testable import Computa

final class APIRejectedRequestCaptureTests: XCTestCase {
    func testProjectionInspectsExactOutgoingBytesAndReportsOnlyFiniteMetadata() throws {
        let provider = APIProviderDefinition(id: "fixture", name: "Fixture", baseURL: URL(string: "https://private.example/v1")!,
            wireAPI: .chatCompletions, models: [.init(id: "PRIVATE_MODEL", name: "Fixture")])
        let host = "PRIVATE_POLICY\nAuthorization: Bearer PRIVATE_KEY", input = "  PRIVATE_USER cafe\u{301}\nhttps://private.example/mail  "
        let expected = APIProviderHTTPClient.RequestProjectionExpectation(provider: provider, modelID: "PRIVATE_MODEL",
            hostMessage: host, userInputs: [input], userInputRevision: 7, checkpointRevision: 3)
        let original: [[String: Any]] = [["role": "assistant", "content": "PRIVATE_OLD_REFUSAL"],
            ["role": "developer", "content": host], ["role": "user", "content": input]]
        func inspect(_ messages: [[String: Any]]) throws -> APIProviderHTTPClient.RequestProjectionDiagnostic {
            expected.inspect(try JSONSerialization.data(withJSONObject: ["messages": messages, "tools": [["name": "PRIVATE_TOOL"]]]))
        }
        let report = try inspect(original)
        XCTAssertEqual(report.hostBytesAtExpectedPosition, true); XCTAssertEqual(report.hostRoleIsDeveloper, true)
        XCTAssertEqual(report.activeInputBytesAtTail, true); XCTAssertEqual(report.activeInputRolesAreUser, true)
        XCTAssertEqual(report.userInputRevision, 7); XCTAssertEqual(report.checkpointRevision, 3)
        XCTAssertEqual(report.messageCount, 3); XCTAssertEqual(report.toolCount, 1)
        var changed = original; changed[2]["content"] = input.precomposedStringWithCanonicalMapping
        XCTAssertEqual(try inspect(changed).activeInputBytesAtTail, false, "Unicode normalization cannot hide changed user bytes")
        changed = original; changed[1]["role"] = "user"
        XCTAssertEqual(try inspect(changed).hostRoleIsDeveloper, false)
        changed = original; changed[1]["content"] = "Stale policy"
        XCTAssertEqual(try inspect(changed).hostBytesAtExpectedPosition, false)
        changed = original; changed.swapAt(1, 2)
        XCTAssertEqual(try inspect(changed).activeInputBytesAtTail, false)
        XCTAssertEqual(try inspect(changed).hostBytesAtExpectedPosition, false)
        changed = original; changed[2]["role"] = "assistant"
        XCTAssertEqual(try inspect(changed).activeInputRolesAreUser, false)
        XCTAssertNil(expected.inspect(Data("not-json".utf8)).activeInputBytesAtTail)
        XCTAssertEqual(expected.inspect(Data(repeating: 65, count: 2_000_002)).bodyBytes, 2_000_001)
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for forbidden in ["PRIVATE", "Authorization", "Bearer", "https://", "private.example", "cafe", "sha256", "hash"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertLessThan(try JSONEncoder().encode(report).count, 2_048)
    }

    func testProjectionArmSkipsMaintenanceAndForeignAdmissionAndPublishesOneExclusiveFiniteRecord() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), turn = UUID()
        try fixture.arm(task: task, thread: thread, projection: true)
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread,
            turnID: turn, ordinaryInference: false))
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: UUID(), threadID: thread, turnID: turn))
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: UUID(), turnID: turn))
        XCTAssertTrue(fixture.exists(fixture.armFile))
        let ticket = try XCTUnwrap(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: turn))
        XCTAssertEqual(ticket.mode, .projection); XCTAssertFalse(fixture.exists(fixture.armFile))
        ticket.capture(APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: Data("PRIVATE_REJECTION".utf8), modelID: "PRIVATE_MODEL", key: "PRIVATE_KEY"))
        XCTAssertFalse(fixture.exists(fixture.output))
        let provider = APIProviderDefinition(id: "fixture", name: "Fixture", baseURL: URL(string: "http://localhost:8123")!, wireAPI: .chatCompletions, models: [])
        let expected = APIProviderHTTPClient.RequestProjectionExpectation(provider: provider, modelID: "fixture",
            hostMessage: "private host", userInputs: ["private user"], userInputRevision: 0, checkpointRevision: 0)
        let body = try JSONSerialization.data(withJSONObject: ["messages": [["role": "developer", "content": "private host"], ["role": "user", "content": "private user"]]])
        ticket.captureProjection(.init(httpStatus: 200, request: expected.inspect(body)), decodeOutcome: .responseValidated)
        let output = fixture.directory.appendingPathComponent("request-projection.json"), bytes = try Data(contentsOf: output)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(record["turnID"] as? String, turn.uuidString.lowercased())
        XCTAssertEqual(record["decodeOutcome"] as? String, "response_validated")
        XCTAssertEqual(record["taskOutcomeVerified"] as? Bool, false)
        XCTAssertEqual(record["automaticReplay"] as? Bool, false)
        XCTAssertLessThanOrEqual(bytes.count, APIRejectedRequestCapture.maximumRecordBytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        ticket.captureProjection(.init(httpStatus: 201, request: expected.inspect(nil)), decodeOutcome: .decodeFailed)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        try fixture.arm(task: task, thread: thread, projection: true)
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: UUID()))
        XCTAssertTrue(fixture.exists(fixture.armFile)); XCTAssertFalse(fixture.exists(fixture.output))
    }

    func testProjectionArmRejectsUnknownDuplicateOrAdditionalModeFields() throws {
        for extra in [#""mode":"unknown""#, #""mode":"projection","mode":"projection""#, #""mode":"projection","output":"private-path""#] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(), thread = UUID()
            try fixture.write(Data("{\"taskID\":\"\(task)\",\"threadID\":\"\(thread)\",\(extra)}".utf8), to: fixture.armFile)
            XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: UUID()))
            XCTAssertTrue(fixture.exists(fixture.armFile))
        }
    }

    func testManuallyArmedDispositionPreservesFullRecordAndEscapedDiagnosticBounds() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), turn = UUID(), observations = DispositionRecorder()
        try fixture.arm(task: task, thread: thread)
        let ticket = try XCTUnwrap(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: turn,
            onDisposition: { observations.append($0) }))
        let escaped = "PRIVATE_PRIMARY_REASON " + String(repeating: "\u{0}🙂", count: 400)
        let body = try JSONSerialization.data(withJSONObject: ["error": ["message": escaped, "type": escaped]])
        let diagnostic = APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: body, modelID: "fixture-model", key: "fixture-secret")
        XCTAssertEqual(diagnostic.envelope, "wrapped_object")
        XCTAssertTrue(diagnostic.error?.message?.hasPrefix("PRIVATE_PRIMARY_REASON ") == true)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(diagnostic).count, 7_168)
        ticket.capture(diagnostic)
        let bytes = try Data(contentsOf: fixture.output)
        XCTAssertLessThanOrEqual(bytes.count, APIRejectedRequestCapture.maximumRecordBytes)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? NSDictionary
        XCTAssertEqual(record["diagnostic"] as? NSDictionary, original, "Observability must not change the private wire record")
        XCTAssertEqual(record["taskID"] as? String, task.uuidString.lowercased())
        XCTAssertEqual(record["threadID"] as? String, thread.uuidString.lowercased())
        XCTAssertEqual(record["turnID"] as? String, turn.uuidString.lowercased())
        XCTAssertEqual(observations.values.map(\.disposition), [.armConsumed, .captureStarted, .published])
        XCTAssertNil(observations.values[1].byteCount)
        XCTAssertEqual(observations.values.last?.byteCount, bytes.count)
        let finite = String(decoding: try JSONEncoder().encode(observations.values), as: UTF8.self)
        for privateValue in ["PRIVATE", "fixture-secret", task.uuidString.lowercased(), thread.uuidString.lowercased(), turn.uuidString.lowercased(), fixture.directory.path] {
            XCTAssertFalse(finite.contains(privateValue))
        }
        ticket.capture(diagnostic)
        XCTAssertEqual(observations.values.last?.disposition, .alreadyUsed)
        XCTAssertEqual(try Data(contentsOf: fixture.output), bytes)
    }

    func testArmedCaptureObservesDirectoryReplacementWithoutPublishingIntoEitherDirectory() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), turn = UUID(), observations = DispositionRecorder()
        try fixture.arm(task: task, thread: thread)
        let ticket = try XCTUnwrap(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: turn,
            onDisposition: { observations.append($0) }))
        let moved = fixture.root.appendingPathComponent("replaced-private-directory")
        try FileManager.default.moveItem(at: fixture.directory, to: moved)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let diagnostic = APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: Data(#"{"message":"PRIVATE_REASON"}"#.utf8), modelID: "fixture-model", key: "fixture-secret")
        ticket.capture(diagnostic)
        XCTAssertEqual(observations.values.map(\.disposition), [.armConsumed, .captureStarted, .directoryChanged])
        XCTAssertGreaterThan(try XCTUnwrap(observations.values.last?.byteCount), 0)
        XCTAssertFalse(fixture.exists(fixture.output))
        XCTAssertFalse(fixture.exists(moved.appendingPathComponent("rejected-request.json")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testArmedCaptureObservesExclusivePublicationFailureAndPreservesExistingOutput() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), turn = UUID(), observations = DispositionRecorder()
        try fixture.arm(task: task, thread: thread)
        let ticket = try XCTUnwrap(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: turn,
            onDisposition: { observations.append($0) }))
        let preserved = Data("PRIVATE_EXISTING_OUTPUT".utf8)
        try fixture.write(preserved, to: fixture.output)
        let diagnostic = APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: Data(#"{"message":"PRIVATE_REASON"}"#.utf8), modelID: "fixture-model", key: "fixture-secret")
        ticket.capture(diagnostic)
        XCTAssertEqual(observations.values.map(\.disposition), [.armConsumed, .captureStarted, .renameFailed])
        XCTAssertEqual(try Data(contentsOf: fixture.output), preserved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["rejected-request.json"], "The temporary output must still be cleaned up")
    }

    func testCaptureOversizeDispositionKeepsExistingLimitAndPublishesNothing() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), turn = UUID(), observations = DispositionRecorder()
        try fixture.arm(task: task, thread: thread)
        let ticket = try XCTUnwrap(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: turn,
            onDisposition: { observations.append($0) }))
        // Directly construct an over-limit fixture. Production HTTP diagnostics
        // already have their independent 7168-byte guard; it is unchanged.
        let diagnostic = APIProviderHTTPClient.RejectionDiagnostic(httpStatus: 400, modelID: "fixture-model", envelope: "bare_object",
            error: .init(message: String(repeating: "\u{0}", count: 4_000), type: nil, code: nil, param: nil), details: [], requestSummary: nil)
        ticket.capture(diagnostic)
        XCTAssertEqual(observations.values.map(\.disposition), [.armConsumed, .captureStarted, .recordTooLarge])
        XCTAssertEqual(observations.values.last?.byteCount, APIRejectedRequestCapture.maximumRecordBytes + 1, "8193 is only a bounded over-limit sentinel")
        XCTAssertFalse(fixture.exists(fixture.output))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testUnarmedMalformedAndForeignAdmissionCannotEmitCaptureDispositions() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), turn = UUID(), observations = DispositionRecorder()
        let observer: APIRejectedRequestCapture.DispositionObserver = { observations.append($0) }
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: nil, taskID: task, threadID: thread, turnID: turn, onDisposition: observer))
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: turn, onDisposition: observer))
        try fixture.arm(task: task, thread: thread)
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: UUID(), threadID: thread, turnID: turn, onDisposition: observer))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.armFile.path)
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: turn, onDisposition: observer))
        XCTAssertTrue(observations.values.isEmpty)
        XCTAssertTrue(fixture.exists(fixture.armFile)); XCTAssertFalse(fixture.exists(fixture.output))
    }

    private final class DispositionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var retained: [APIRejectedRequestCapture.Observation] = []
        func append(_ value: APIRejectedRequestCapture.Observation) { lock.withLock { retained.append(value) } }
        var values: [APIRejectedRequestCapture.Observation] { lock.withLock { retained } }
    }

    func testBareWrappedAndStringErrorsHaveSameFiniteClassification() throws {
        let fields = ["param": "messages[0].content", "message": "fixture-secret"]
        let envelopes: [[String: Any]] = [fields, ["error": fields]]
        for object in envelopes {
            XCTAssertEqual(APIProviderHTTPClient.rejectedRequest(status: 400, body: try JSONSerialization.data(withJSONObject: object)), .invalidMessages)
        }
        XCTAssertEqual(APIProviderHTTPClient.rejectedRequest(status: 400, body: try JSONSerialization.data(withJSONObject: ["error": "Unsupported parameter: 'tools'."])), .invalidTools)
        XCTAssertEqual(APIProviderHTTPClient.rejectedRequest(status: 400, body: try JSONSerialization.data(withJSONObject: ["error": ["message": "unknown"], "param": "tools"])), .invalidRequest)
    }

    func testDiagnosticRedactsSecretsAndOmitsRawBodyValidationInputAndContext() throws {
        let key = "actual-fixture-key-123"
        let message = "Unsupported tools: \(key); csk-otherSecret_456 Bearer another-secret\nAuthorization: basic hidden-secret"
        let object: [String: Any] = ["error": ["message": message, "type": "validation_error", "param": "tools",
            "detail": [["loc": ["body", "tools", 0, "private-name"], "msg": message, "type": "invalid_schema",
                        "input": "INPUT_MUST_NOT_BE_CAPTURED", "ctx": ["value": "CTX_MUST_NOT_BE_CAPTURED"]]],
            "request": "REQUEST_MUST_NOT_BE_CAPTURED"], "headers": ["Authorization": key]]
        let request: [String: Any] = ["n": 1, "stream": true, "reasoning_effort": "medium", "max_completion_tokens": 65_000, "parallel_tool_calls": false, "clear_thinking": false,
            "messages": [["role": "system", "content": "PRIVATE_PROMPT"], ["role": "user", "content": ""]],
            "tools": [["type": "function", "function": ["name": "PRIVATE_TOOL_NAME", "description": "PRIVATE_DESCRIPTION", "parameters":
                ["type": "object", "properties": ["PRIVATE_PROPERTY": ["type": "string", "enum": ["PRIVATE_VALUE"]]], "required": ["PRIVATE_PROPERTY"]]]]]]
        let diagnostic = APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: try JSONSerialization.data(withJSONObject: object), modelID: "fixture-model", key: key, requestBody: try JSONSerialization.data(withJSONObject: request))
        let data = try JSONEncoder().encode(diagnostic), text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(diagnostic.envelope, "wrapped_object"); XCTAssertEqual(diagnostic.httpStatus, 400)
        XCTAssertEqual(diagnostic.details.first?.param, "tools")
        XCTAssertEqual(diagnostic.requestSummary?.options.maxCompletionTokens, 65_000)
        XCTAssertEqual(diagnostic.requestSummary?.options.stream, true)
        XCTAssertEqual(diagnostic.requestSummary?.messageRoleCounts["system"], 1)
        XCTAssertEqual(diagnostic.requestSummary?.emptyContentCount, 1)
        XCTAssertEqual(diagnostic.requestSummary?.totalTextUTF8Bytes, "PRIVATE_PROMPT".utf8.count)
        XCTAssertEqual(diagnostic.requestSummary?.toolCount, 1)
        XCTAssertEqual(diagnostic.requestSummary?.schemaKeywordCounts["type"], 2)
        XCTAssertEqual(diagnostic.requestSummary?.schemaKeywordCounts["enum"], 1)
        XCTAssertTrue(text.contains("Unsupported tools")); XCTAssertTrue(text.contains("[REDACTED]"))
        for forbidden in [key, "csk-otherSecret_456", "another-secret", "hidden-secret", "Authorization", "INPUT_MUST_NOT_BE_CAPTURED", "CTX_MUST_NOT_BE_CAPTURED", "REQUEST_MUST_NOT_BE_CAPTURED", "private-name", "PRIVATE_PROMPT", "PRIVATE_TOOL_NAME", "PRIVATE_DESCRIPTION", "PRIVATE_PROPERTY", "PRIVATE_VALUE"] {
            XCTAssertFalse(text.contains(forbidden), "Unexpected capture of \(forbidden)")
        }
        let large = String(repeating: "\u{0}🙂", count: 400)
        let bounded = APIProviderHTTPClient.rejectionDiagnostic(status: 422, body: try JSONSerialization.data(withJSONObject: ["message": large, "type": large, "param": large]), modelID: "fixture-model", key: key)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(bounded).count, 7_168)
        XCTAssertLessThanOrEqual(bounded.error?.message?.utf8.count ?? 0, 2_048)
    }

    func testExactArmIsConsumedBeforeResponseAndPublishesOnlyOnce() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), turn = UUID()
        try fixture.arm(task: task, thread: thread)
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: nil, taskID: task, threadID: thread, turnID: turn))
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: UUID(), threadID: thread, turnID: turn))
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: UUID(), turnID: turn))
        XCTAssertTrue(fixture.exists(fixture.armFile))
        let ticket = try XCTUnwrap(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: turn))
        XCTAssertFalse(fixture.exists(fixture.armFile)); XCTAssertFalse(fixture.exists(fixture.output))
        let diagnostic = APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: Data(#"{"message":"invalid tools: schema"}"#.utf8), modelID: "fixture-model", key: "fixture-secret")
        ticket.capture(diagnostic)
        let data = try Data(contentsOf: fixture.output)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(record["taskID"] as? String, task.uuidString.lowercased())
        XCTAssertEqual(record["threadID"] as? String, thread.uuidString.lowercased())
        XCTAssertEqual(record["turnID"] as? String, turn.uuidString.lowercased())
        XCTAssertEqual(record["automaticReplay"] as? Bool, false)
        XCTAssertLessThanOrEqual(data.count, 8_192)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.output.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        ticket.capture(diagnostic); XCTAssertEqual(try Data(contentsOf: fixture.output), data)
        XCTAssertNil(APIRejectedRequestCapture.consume(directory: fixture.directory, taskID: task, threadID: thread, turnID: UUID()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["rejected-request.json"])
    }

    func testMalformedPermissionsLinksAndExistingOutputCannotArmCapture() throws {
        for kind in ["wrong_keys", "duplicate", "permissions", "directory_permissions", "arm_link", "directory_link", "hardlink", "fifo", "output"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(), thread = UUID(), turn = UUID()
            try fixture.arm(task: task, thread: thread)
            var directory = fixture.directory
            switch kind {
            case "wrong_keys": try fixture.write(Data("{\"taskID\":\"\(task)\",\"threadID\":\"\(thread)\",\"all\":true}".utf8), to: fixture.armFile)
            case "duplicate": try fixture.write(Data("{\"taskID\":\"\(task)\",\"taskID\":\"\(task)\",\"threadID\":\"\(thread)\"}".utf8), to: fixture.armFile)
            case "permissions": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.armFile.path)
            case "directory_permissions": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
            case "arm_link":
                let target = fixture.root.appendingPathComponent("original.json")
                try FileManager.default.moveItem(at: fixture.armFile, to: target)
                try FileManager.default.createSymbolicLink(at: fixture.armFile, withDestinationURL: target)
            case "directory_link":
                directory = fixture.root.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.directory)
            case "hardlink": XCTAssertEqual(link(fixture.armFile.path, fixture.root.appendingPathComponent("alias").path), 0)
            case "fifo": try FileManager.default.removeItem(at: fixture.armFile); XCTAssertEqual(mkfifo(fixture.armFile.path, 0o600), 0)
            case "output": try fixture.write(Data("preserved".utf8), to: fixture.output)
            default: XCTFail("unknown case")
            }
            XCTAssertNil(APIRejectedRequestCapture.consume(directory: directory, taskID: task, threadID: thread, turnID: turn), kind)
            if kind == "output" { XCTAssertEqual(try Data(contentsOf: fixture.output), Data("preserved".utf8)) }
            else { XCTAssertFalse(fixture.exists(fixture.output)) }
        }
    }

    private struct Fixture {
        let root: URL
        var directory: URL { root.appendingPathComponent("diagnostics") }
        var armFile: URL { directory.appendingPathComponent("arm.json") }
        var output: URL { directory.appendingPathComponent("rejected-request.json") }
        init() throws {
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
            defer { free(resolved) }
            root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent("ComputaAPIRejection-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func arm(task: UUID, thread: UUID, projection: Bool = false) throws {
            var value = ["taskID": task.uuidString, "threadID": thread.uuidString]
            if projection { value["mode"] = "projection" }
            try write(JSONSerialization.data(withJSONObject: value), to: armFile)
        }
        func write(_ data: Data, to url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

import Darwin
import Foundation
import XCTest
@testable import Computa

final class APIRejectedRequestCaptureTests: XCTestCase {
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
        func arm(task: UUID, thread: UUID) throws { try write(JSONSerialization.data(withJSONObject: ["taskID": task.uuidString, "threadID": thread.uuidString]), to: armFile) }
        func write(_ data: Data, to url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

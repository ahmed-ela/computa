import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Computa

final class ClaudeOpus47FirstRequestCaptureTests: XCTestCase {
    func testExactSyntheticCaseCapturesNativeContextAndCanonicalServerOutboundBytesOnce() throws {
        for form in 0...2 {
            let f = try ClaudeOpus47FirstRequestCaptureFixture(); defer { f.remove() }
            let request = try f.request(policyForm: form); try f.arm()
            let scope = try XCTUnwrap(f.scope(request))
            XCTAssertTrue(f.capture(scope, request: request))
            let record = try f.record(), retained = try Data(contentsOf: f.output)
            XCTAssertEqual(record["schemaVersion"] as? Int, 3)
            XCTAssertEqual(record["purpose"] as? String, ClaudeRequestCapture.clientFirstRequestPurpose)
            XCTAssertEqual(record["nonce"] as? String, f.nonce.uuidString.lowercased())
            XCTAssertEqual(record["caseNonce"] as? String, f.nonce.uuidString.lowercased())
            XCTAssertEqual(record["stage"] as? String, "before_insert")
            XCTAssertEqual(record["diagnosticOnly"] as? Bool, true)
            XCTAssertEqual(record["submissionVerified"] as? Bool, false)
            XCTAssertEqual(record["automaticReplay"] as? Bool, false)
            XCTAssertEqual(record["canonicalRequest"] as? String, String(decoding: request.continuationRequest, as: UTF8.self))
            XCTAssertEqual(record["canonicalRequestSHA256"] as? String, f.hash(request.continuationRequest))
            XCTAssertEqual(record["serverPrompt"] as? String, request.prompt)
            XCTAssertEqual(record["outbound"] as? String, f.outbound(request))
            XCTAssertEqual(record["outboundSHA256"] as? String, f.hash(Data(f.outbound(request).utf8)))
            for (key, value) in [("taskID", f.context.taskID), ("threadID", f.context.threadID), ("turnID", f.context.turnID),
                                 ("inferenceID", f.context.inferenceID), ("runtimeGeneration", f.context.runtimeGeneration),
                                 ("preparationID", f.context.preparationID), ("sessionToken", f.context.sessionToken), ("documentGeneration", f.generation)] {
                XCTAssertEqual(record[key] as? String, value.uuidString.lowercased())
            }
            var mode = stat(); XCTAssertEqual(lstat(f.output.path, &mode), 0)
            XCTAssertEqual(mode.st_mode & 0o7777, 0o600); XCTAssertEqual(mode.st_nlink, 1)
            XCTAssertFalse(f.exists(f.armFile)); XCTAssertLessThanOrEqual(retained.count, 2_000_000)
            XCTAssertFalse(f.capture(scope, request: request))
            try f.arm(); XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request))
            XCTAssertEqual(try Data(contentsOf: f.output), retained)
        }
    }

    func testForeignLegacyOrAmbiguousArmCannotCaptureOrConsumeTheControlledCase() throws {
        let f = try ClaudeOpus47FirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request()
        var variants: [[String: Any]] = []
        for key in ["taskID", "threadID", "turnID", "inferenceID", "runtimeGeneration", "preparationID", "nonce"] {
            var value = f.fields(); value[key] = UUID().uuidString.lowercased(); variants.append(value)
        }
        for (key, invalid) in [("schemaVersion", true as Any), ("schemaVersion", 2),
                               ("purpose", ClaudeRequestCapture.firstRequestPurpose), ("trigger", "first_user_request"),
                               ("modelID", ClaudeRequestCapture.firstRequestModel), ("expiresAt", f.timestamp(f.now)),
                               ("expiresAt", f.timestamp(f.now.addingTimeInterval(601))), ("userPromptSHA256", String(repeating: "0", count: 64)),
                               ("captureEverything", true)] {
            var value = f.fields(); value[key] = invalid; variants.append(value)
        }
        variants += f.fields().keys.map { key in var value = f.fields(); value.removeValue(forKey: key); return value }
        for value in variants {
            try f.arm(value); let before = try Data(contentsOf: f.armFile)
            XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request))
            XCTAssertEqual(try Data(contentsOf: f.armFile), before); XCTAssertFalse(f.exists(f.output))
        }
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: f.fields()), as: UTF8.self)
        try f.write(Data(("{\"schemaVersion\":3," + raw.dropFirst()).utf8), to: f.armFile)
        XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request)); XCTAssertFalse(f.exists(f.output))
    }

    func testScopeRequiresFreshExactSyntheticShapeAndNativeSessionWithoutChangingLegacyModelGate() throws {
        let f = try ClaudeOpus47FirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request()
        XCTAssertNil(f.scope(request, isNewThread: false)); XCTAssertNil(f.scope(request, isMaintenance: true)); XCTAssertNil(f.scope(request, isFirstInference: false))
        XCTAssertNil(f.scope(try f.request(model: ClaudeRequestCapture.firstRequestModel)))
        let history = try f.request(input: f.input() + [f.message("assistant", "Unrelated synthetic history")]); try f.arm()
        XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(history)), request: history)); XCTAssertFalse(f.exists(f.output))
        let scope = try XCTUnwrap(f.scope(request))
        XCTAssertFalse(scope.capture(prompt: request.prompt, outbound: f.outbound(request), modelID: request.model,
            sessionToken: UUID().uuidString, documentGeneration: f.generation, marker: f.marker, nativeFirstFresh: true, now: f.now))
        XCTAssertTrue(f.exists(f.armFile)); XCTAssertFalse(f.exists(f.output))
        let legacy = try ClaudeFirstRequestCaptureFixture(); defer { legacy.remove() }; let old = try legacy.request(); try legacy.arm()
        XCTAssertTrue(legacy.capture(try XCTUnwrap(legacy.scope(old)), request: old))
        XCTAssertEqual(try legacy.record()["schemaVersion"] as? Int, 2)
    }

    func testRevokedOrCancelledScopeCannotPublishAndNoDirectoryIsCreated() async throws {
        let f = try ClaudeOpus47FirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request(); try f.arm()
        let scope = try XCTUnwrap(f.scope(request))
        XCTAssertFalse(scope.capture(prompt: request.prompt, outbound: f.outbound(request), modelID: request.model,
            sessionToken: f.context.sessionToken.uuidString, documentGeneration: f.generation, marker: f.marker,
            nativeFirstFresh: true, now: f.now, beforeArmClaimForTesting: { scope.revoke() }))
        XCTAssertFalse(f.exists(f.output))
        try f.arm(); let cancelled = try XCTUnwrap(f.scope(request))
        let result = await Task { withUnsafeCurrentTask { $0?.cancel() }; return f.capture(cancelled, request: request) }.value
        XCTAssertFalse(result); XCTAssertFalse(f.exists(f.output))
        try FileManager.default.removeItem(at: f.directory)
        XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request)); XCTAssertFalse(f.exists(f.directory))
    }
}

struct ClaudeOpus47FirstRequestCaptureFixture: Sendable {
    let root: URL
    let now: Date
    let nonce = UUID(), generation = UUID()
    // Native firstUserMarker uses UUID.uuidString without case normalization.
    let marker = "ABCDEF12-3456-4789-ABCD-0123456789AB"
    let context: ClaudeRequestCapture.Context
    var baseDirectory: URL { root.appendingPathComponent(ClaudeRequestCapture.directoryName) }
    var directory: URL { baseDirectory.appendingPathComponent(ClaudeRequestCapture.clientFirstRequestSubdirectory) }
    var armFile: URL { directory.appendingPathComponent("arm.json") }
    var output: URL { directory.appendingPathComponent("request.json") }
    var userText: String { ClaudeRequestCapture.clientSyntheticUserText(nonce: nonce) }

    init(sessionToken: UUID = UUID(), now: Date = Date(timeIntervalSince1970: 2_000_000_000)) throws {
        root = try websiteBenchmarkTemporaryDirectory().appendingPathComponent("claude-client-first-" + UUID().uuidString)
        self.now = now
        context = .init(taskID: UUID(), threadID: UUID(), turnID: UUID(), runtimeGeneration: UUID(),
            preparationID: UUID(), inferenceID: UUID(), sessionToken: sessionToken, modelID: ClaudeRequestCapture.clientFirstRequestModel)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func message(_ role: String, _ text: String) -> [String: Any] {
        ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
    }
    func input(policyForm: Int = 1) -> [[String: Any]] {
        let policy = ComputaAgentInstructions.runtimeInteractionPolicy()
        var user = message("user", userText + (policyForm == 1 ? "\n" + policy : ""))
        if policyForm == 2 { user["content"] = [["type": "input_text", "text": userText], ["type": "input_text", "text": policy]] }
        return [message("developer", "Synthetic native developer policy"),
            message("user", "<environment_context><cwd>/tmp/computa-empty-fixture</cwd><shell>zsh</shell></environment_context>"), user]
    }
    func request(policyForm: Int = 1, input: [[String: Any]]? = nil, model: String? = nil,
                 extra: [String: Any] = [:], stringInput: String? = nil) throws -> WebModelResponseCodec.Request {
        var fields: [String: Any] = ["model": model ?? context.modelID,
            "instructions": "Synthetic governing permission text e\u{0301}, 🧭, \\n.",
            "input": stringInput as Any? ?? (input ?? self.input(policyForm: policyForm)),
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]]],
            "tool_choice": "auto", "parallel_tool_calls": false]
        fields.merge(extra) { _, value in value }
        return try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: fields,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
    }
    func scope(_ request: WebModelResponseCodec.Request, isNewThread: Bool = true, isMaintenance: Bool = false,
               isFirstInference: Bool = true) -> ClaudeRequestCapture.FirstRequestScope? {
        .init(directory: baseDirectory, context: context, request: request, prompt: request.prompt,
            isNewThread: isNewThread, isMaintenance: isMaintenance, isFirstInference: isFirstInference)
    }
    func outbound(_ request: WebModelResponseCodec.Request) -> String { request.prompt + "\n\nComputa session marker: " + marker }
    func capture(_ scope: ClaudeRequestCapture.FirstRequestScope, request: WebModelResponseCodec.Request) -> Bool {
        scope.capture(prompt: request.prompt, outbound: outbound(request), modelID: request.model,
            sessionToken: context.sessionToken.uuidString, documentGeneration: generation, marker: marker, nativeFirstFresh: true, now: now)
    }
    func fields() -> [String: Any] {
        ["schemaVersion": 3, "purpose": ClaudeRequestCapture.clientFirstRequestPurpose, "nonce": nonce.uuidString.lowercased(),
         "taskID": context.taskID.uuidString.lowercased(), "turnID": context.turnID.uuidString.lowercased(),
         "modelID": context.modelID, "trigger": "first_client_context_marker",
         "threadID": context.threadID.uuidString.lowercased(), "inferenceID": context.inferenceID.uuidString.lowercased(),
         "runtimeGeneration": context.runtimeGeneration.uuidString.lowercased(), "preparationID": context.preparationID.uuidString.lowercased(), "userPromptSHA256": hash(Data(userText.utf8)),
         "expiresAt": timestamp(now.addingTimeInterval(300))]
    }
    func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    func arm(_ fields: [String: Any]? = nil) throws { try write(JSONSerialization.data(withJSONObject: fields ?? self.fields()), to: armFile) }
    func write(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    }
    func record() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]) }
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

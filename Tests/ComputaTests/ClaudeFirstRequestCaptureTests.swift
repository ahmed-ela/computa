import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Computa

final class ClaudeFirstRequestCaptureTests: XCTestCase {
    func testExactFirstRequestPreservesCanonicalServerAndOutboundBytesForAllNativePolicyForms() throws {
        for form in 0...2 {
            let f = try ClaudeFirstRequestCaptureFixture(); defer { f.remove() }
            let request = try f.request(policyForm: form)
            try f.arm()
            let arm = try Data(contentsOf: f.armFile)
            XCTAssertFalse(ClaudeRequestCapture.capture(directory: f.directory, context: f.context,
                request: request, prompt: request.prompt, now: f.now), "Legacy capture cannot consume the new arm")
            XCTAssertEqual(try Data(contentsOf: f.armFile), arm)
            let scope = try XCTUnwrap(f.scope(request))
            XCTAssertTrue(f.capture(scope, request: request))
            let record = try f.record(), bytes = try Data(contentsOf: f.output)
            XCTAssertEqual(record["schemaVersion"] as? Int, 2)
            XCTAssertEqual(record["stage"] as? String, "before_insert")
            XCTAssertEqual(record["submissionVerified"] as? Bool, false)
            XCTAssertEqual(record["automaticReplay"] as? Bool, false)
            XCTAssertNil(record["triggerCallID"])
            XCTAssertTrue((record["canonicalRequest"] as? String).map { Data($0.utf8) == request.continuationRequest } == true)
            XCTAssertTrue((record["serverPrompt"] as? String)?.utf8.elementsEqual(request.prompt.utf8) == true)
            XCTAssertTrue((record["outbound"] as? String)?.utf8.elementsEqual(f.outbound(request).utf8) == true)
            XCTAssertEqual(record["canonicalRequestSHA256"] as? String, f.hash(request.continuationRequest))
            XCTAssertEqual(record["serverPromptSHA256"] as? String, f.hash(Data(request.prompt.utf8)))
            XCTAssertEqual(record["outboundSHA256"] as? String, f.hash(Data(f.outbound(request).utf8)))
            XCTAssertEqual(record["outboundCanonicalSHA256"] as? String, EmbeddedWebModelTransport.outboundFingerprint(f.outbound(request)))
            XCTAssertEqual(record["outboundUTF8Bytes"] as? Int, f.outbound(request).utf8.count)
            XCTAssertEqual(record["outboundUTF16Count"] as? Int, f.outbound(request).utf16.count)
            XCTAssertEqual(record["userPromptSHA256"] as? String, f.hash(Data(f.userText.utf8)))
            XCTAssertEqual(record["sessionToken"] as? String, f.context.sessionToken.uuidString.lowercased())
            XCTAssertEqual(record["documentGeneration"] as? String, f.generation.uuidString.lowercased())
            XCTAssertEqual(record["inferenceID"] as? String, f.context.inferenceID.uuidString.lowercased())
            XCTAssertEqual(record["marker"] as? String, f.marker)
            let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: request.continuationRequest) as? [String: Any])
            XCTAssertTrue((canonical["instructions"] as? String)?.utf8.elementsEqual("Synthetic governing permission text e\u{0301}, 🧭, \\n.".utf8) == true)
            XCTAssertTrue(request.prompt.contains("Synthetic native developer policy"))
            var info = stat(); XCTAssertEqual(lstat(f.output.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, 0o600); XCTAssertEqual(info.st_nlink, 1)
            XCTAssertEqual(info.st_uid, geteuid()); XCTAssertFalse(f.exists(f.armFile))
            XCTAssertFalse(f.capture(scope, request: request))
            try f.arm()
            XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request))
            XCTAssertEqual(try Data(contentsOf: f.output), bytes, "Rearming cannot overwrite retained evidence")
            guard case .message(let text) = try WebModelResponseCodec.parseEmbeddedReply(
                #"{"type":"message","text":"I cannot perform this request."}"#, request: request) else {
                return XCTFail("Capture must preserve a valid refusal")
            }
            XCTAssertEqual(text, "I cannot perform this request.")
            XCTAssertEqual(try WebModelResponseCodec.parseEmbeddedReply("I cannot perform this request.", request: request),
                .message("I cannot perform this request."))
            XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(#"{"type":"message""#, request: request))
        }
    }

    func testNativeScopeRequiresNewOrdinaryFirstInferenceAndExactOpus5() throws {
        let f = try ClaudeFirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request()
        XCTAssertNil(f.scope(request, isNewThread: false)); XCTAssertNil(f.scope(request, isMaintenance: true))
        XCTAssertNil(f.scope(request, isFirstInference: false))
        XCTAssertNil(ClaudeRequestCapture.FirstRequestScope(directory: nil, context: f.context, request: request,
            prompt: request.prompt, isNewThread: true, isMaintenance: false, isFirstInference: true))
        for model in ["browser/claude", WebsiteModelChoice(provider: "claude", key: "Opus 4.8", label: "Opus 4.8").modelID,
                      WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID] {
            XCTAssertNil(f.scope(try f.request(model: model)))
        }
        let scope = try XCTUnwrap(f.scope(request))
        XCTAssertFalse(f.capture(scope, request: request))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).isEmpty)
        try f.arm(); scope.revoke()
        XCTAssertFalse(f.capture(scope, request: request)); XCTAssertTrue(f.exists(f.armFile))
    }

    func testFirstArmRejectsIdentitySchemaPurposeDigestExpiryAndAmbiguityWithoutClaiming() throws {
        let f = try ClaudeFirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request()
        let mutations: [(String, Any)] = [("schemaVersion", true), ("schemaVersion", 1),
            ("purpose", ClaudeRequestCapture.purpose), ("trigger", "after_browser_tabs"),
            ("nonce", f.nonce.uuidString.uppercased()), ("nonce", UUID().uuidString.lowercased()),
            ("taskID", UUID().uuidString.lowercased()), ("turnID", UUID().uuidString.lowercased()),
            ("modelID", "browser/claude"), ("userPromptSHA256", String(repeating: "0", count: 64)),
            ("userPromptSHA256", f.hash(Data(f.userText.utf8)).uppercased()),
            ("expiresAt", f.timestamp(f.now)), ("expiresAt", f.timestamp(f.now.addingTimeInterval(601)))]
        var cases = mutations.map { key, value in var fields = f.fields(); fields[key] = value; return fields }
        cases += f.fields().keys.map { key in var fields = f.fields(); fields.removeValue(forKey: key); return fields }
        var extra = f.fields(); extra["captureEverything"] = true; cases.append(extra)
        for fields in cases {
            try f.arm(fields); let before = try Data(contentsOf: f.armFile)
            XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request))
            XCTAssertEqual(try Data(contentsOf: f.armFile), before); XCTAssertFalse(f.exists(f.output))
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: f.fields()), as: UTF8.self)
        try f.write(Data(("{\"schemaVersion\":2," + text.dropFirst()).utf8), to: f.armFile)
        XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request))
    }

    func testSyntheticShapeRejectsHistoryContinuationsExtraUsersAndChangedPolicy() throws {
        let f = try ClaudeFirstRequestCaptureFixture(); defer { f.remove() }; let base = f.input()
        let cases: [[[String: Any]]] = [
            base + [f.message("user", "Extra actual task")], [f.message("user", "Earlier task")] + base,
            [f.message("assistant", "Earlier response")] + base,
            base + [["type": "function_call", "call_id": "old", "name": "exec_command", "arguments": "{}"]],
            base + [["type": "function_call_output", "call_id": "old", "output": "earlier result"]],
            [base[0], f.message("user", "<environment_context><cwd>/tmp</cwd><shell>zsh</shell><secret>history</secret></environment_context>"), base[2]],
            [base[0], base[1], f.message("user", f.userText + "\nchanged policy")],
            [base[0], base[1], f.message("user", " " + f.userText)],
            [base[0], base[1], f.message("user", f.userText + "\n")],
            [base[0], base[1], ["role": "user", "content": f.userText]],
        ]
        for input in cases {
            let request = try f.request(input: input); try f.arm()
            XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request))
            XCTAssertTrue(f.exists(f.armFile)); XCTAssertFalse(f.exists(f.output))
        }
        for key in ["conversation", "conversation_id", "response_id"] {
            let request = try f.request(extra: [key: "prior"]); try f.arm()
            XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request), key)
        }
        let stringInput = try f.request(stringInput: f.userText); try f.arm()
        XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(stringInput)), request: stringInput))
        XCTAssertThrowsError(try f.request(extra: ["previous_response_id": "prior"]))
        XCTAssertFalse(WebsiteBenchmarkCaptureLease.matchesSyntheticRequest(try f.request(), nonce: f.nonce),
            "Sharing the pure shape helper cannot widen the legacy Instant model gate")
    }

    func testNativeCaptureRejectsWrongSessionModelPromptMarkerFreshnessAndSuffix() throws {
        let f = try ClaudeFirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request(); try f.arm()
        let scope = try XCTUnwrap(f.scope(request))
        let cases: [(String, String, String, String, String, Bool)] = [
            (request.prompt, f.outbound(request), "browser/claude", f.context.sessionToken.uuidString, f.marker, true),
            (request.prompt, f.outbound(request), request.model, UUID().uuidString, f.marker, true),
            (request.prompt + "changed", f.outbound(request), request.model, f.context.sessionToken.uuidString, f.marker, true),
            (request.prompt, request.prompt, request.model, f.context.sessionToken.uuidString, f.marker, true),
            (request.prompt, f.outbound(request) + "extra", request.model, f.context.sessionToken.uuidString, f.marker, true),
            (request.prompt, f.outbound(request), request.model, f.context.sessionToken.uuidString, f.marker.lowercased(), true),
            (request.prompt, f.outbound(request), request.model, f.context.sessionToken.uuidString, f.marker, false),
        ]
        for (prompt, outbound, model, session, marker, fresh) in cases {
            XCTAssertFalse(scope.capture(prompt: prompt, outbound: outbound, modelID: model, sessionToken: session,
                documentGeneration: f.generation, marker: marker, nativeFirstFresh: fresh, now: f.now))
            XCTAssertTrue(f.exists(f.armFile)); XCTAssertFalse(f.exists(f.output))
        }
        XCTAssertTrue(f.capture(scope, request: request))
    }

    func testPrivatePublisherRejectsUnsafeFilesAndDoesNotCreateMissingDirectories() throws {
        for mode in ["directory_mode", "arm_mode", "arm_hardlink", "arm_symlink"] {
            let f = try ClaudeFirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request(); try f.arm()
            switch mode {
            case "directory_mode": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
            case "arm_mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.armFile.path)
            case "arm_hardlink": XCTAssertEqual(link(f.armFile.path, f.root.appendingPathComponent("linked").path), 0)
            default:
                let original = f.root.appendingPathComponent("original")
                try FileManager.default.moveItem(at: f.armFile, to: original)
                try FileManager.default.createSymbolicLink(at: f.armFile, withDestinationURL: original)
            }
            XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request), mode)
            XCTAssertFalse(f.exists(f.output), mode)
        }
        let f = try ClaudeFirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request()
        try FileManager.default.removeItem(at: f.directory)
        XCTAssertFalse(f.capture(try XCTUnwrap(f.scope(request)), request: request)); XCTAssertFalse(f.exists(f.directory))
    }

    func testRevocationAndCancellationCannotPublishOrRearm() async throws {
        let f = try ClaudeFirstRequestCaptureFixture(); defer { f.remove() }; let request = try f.request(); try f.arm()
        let scope = try XCTUnwrap(f.scope(request))
        XCTAssertFalse(scope.capture(prompt: request.prompt, outbound: f.outbound(request), modelID: request.model,
            sessionToken: f.context.sessionToken.uuidString, documentGeneration: f.generation, marker: f.marker,
            nativeFirstFresh: true, now: f.now, beforeArmClaimForTesting: { scope.revoke() }))
        XCTAssertFalse(f.exists(f.output)); XCTAssertFalse(f.exists(f.armFile))
        try f.arm(); let cancelled = try XCTUnwrap(f.scope(request))
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return f.capture(cancelled, request: request)
        }.value
        XCTAssertFalse(result); XCTAssertTrue(f.exists(f.armFile)); XCTAssertFalse(f.exists(f.output))
    }
}

struct ClaudeFirstRequestCaptureFixture: Sendable {
    let root: URL
    let now: Date
    let nonce = UUID(), generation = UUID()
    // Native firstUserMarker uses UUID.uuidString without case normalization.
    let marker = "ABCDEF12-3456-4789-ABCD-0123456789AB"
    let context: ClaudeRequestCapture.Context
    var directory: URL { root.appendingPathComponent(ClaudeRequestCapture.directoryName) }
    var armFile: URL { directory.appendingPathComponent("arm.json") }
    var output: URL { directory.appendingPathComponent("request.json") }
    var userText: String { ClaudeRequestCapture.syntheticUserText(nonce: nonce) }

    init(sessionToken: UUID = UUID(), now: Date = Date(timeIntervalSince1970: 2_000_000_000)) throws {
        root = try websiteBenchmarkTemporaryDirectory().appendingPathComponent("claude-first-" + UUID().uuidString)
        self.now = now
        context = .init(taskID: UUID(), threadID: UUID(), turnID: UUID(), runtimeGeneration: UUID(),
            preparationID: UUID(), inferenceID: UUID(), sessionToken: sessionToken, modelID: ClaudeRequestCapture.firstRequestModel)
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
        .init(directory: directory, context: context, request: request, prompt: request.prompt,
            isNewThread: isNewThread, isMaintenance: isMaintenance, isFirstInference: isFirstInference)
    }
    func outbound(_ request: WebModelResponseCodec.Request) -> String { request.prompt + "\n\nComputa session marker: " + marker }
    func capture(_ scope: ClaudeRequestCapture.FirstRequestScope, request: WebModelResponseCodec.Request) -> Bool {
        scope.capture(prompt: request.prompt, outbound: outbound(request), modelID: request.model,
            sessionToken: context.sessionToken.uuidString, documentGeneration: generation, marker: marker, nativeFirstFresh: true, now: now)
    }
    func fields() -> [String: Any] {
        ["schemaVersion": 2, "purpose": ClaudeRequestCapture.firstRequestPurpose, "nonce": nonce.uuidString.lowercased(),
         "taskID": context.taskID.uuidString.lowercased(), "turnID": context.turnID.uuidString.lowercased(),
         "modelID": context.modelID, "trigger": "first_user_request", "userPromptSHA256": hash(Data(userText.utf8)),
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

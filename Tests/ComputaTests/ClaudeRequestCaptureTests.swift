import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Computa

final class ClaudeRequestCaptureTests: XCTestCase {
    func testExactPostTabsCapturePreservesCanonicalBytesFinalPromptCatalogAndBindings() throws {
        let f = try Fixture(); defer { f.remove() }
        let request = try f.request()
        // Capture the actual passed prompt, including an ordinary local suffix,
        // rather than reconstructing it from canonical history.
        let prompt = request.prompt + "\nExact diagnostic text: e\u{0301}, 🧭, \\n and <>&."
        try f.arm()
        XCTAssertTrue(f.capture(request, prompt: prompt))
        let record = try f.record()
        XCTAssertEqual(record["canonicalRequest"] as? String, String(decoding: request.continuationRequest, as: UTF8.self))
        XCTAssertEqual(Data(try XCTUnwrap(record["canonicalRequest"] as? String).utf8), request.continuationRequest)
        XCTAssertEqual(record["prompt"] as? String, prompt)
        XCTAssertEqual(record["canonicalRequestSHA256"] as? String, hash(request.continuationRequest))
        XCTAssertEqual(record["promptSHA256"] as? String, hash(Data(prompt.utf8)))
        XCTAssertEqual(record["canonicalRequestUTF8Bytes"] as? Int, request.continuationRequest.count)
        XCTAssertEqual(record["promptUTF8Bytes"] as? Int, prompt.utf8.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let catalogData = try encoder.encode(request.toolCatalogDiagnostic)
        XCTAssertEqual(record["toolCatalog"] as? NSDictionary, try JSONSerialization.jsonObject(with: catalogData) as? NSDictionary)
        XCTAssertEqual(record["toolCatalogSHA256"] as? String, hash(catalogData))
        for (key, id) in [("taskID", f.context.taskID), ("threadID", f.context.threadID), ("turnID", f.context.turnID),
                          ("runtimeGeneration", f.context.runtimeGeneration), ("preparationID", f.context.preparationID),
                          ("inferenceID", f.context.inferenceID), ("sessionToken", f.context.sessionToken), ("nonce", f.nonce)] {
            XCTAssertEqual(record[key] as? String, id.uuidString.lowercased(), key)
        }
        XCTAssertEqual(record["modelID"] as? String, f.context.modelID)
        XCTAssertEqual(record["stage"] as? String, "pre_send")
        XCTAssertEqual(record["submissionVerified"] as? Bool, false)
        XCTAssertEqual(record["automaticReplay"] as? Bool, false)
        XCTAssertEqual(record["triggerCallID"] as? String, "call_tabs")
        XCTAssertEqual(try f.permissions(f.output), 0o600)
        XCTAssertFalse(f.exists(f.armFile))
        let first = try Data(contentsOf: f.output)
        XCTAssertFalse(f.capture(request, prompt: "later inference"))
        XCTAssertEqual(try Data(contentsOf: f.output), first)
        // The diagnostic helper cannot alter parsing or repair malformed output.
        let valid = #"{"type":"tool_calls","calls":[{"name":"browser_read","arguments":{}}]}"#
        guard case .toolCalls = try WebModelResponseCodec.parseReply(valid, request: request, requireEnvelope: true) else {
            return XCTFail("The valid argumentless browser read must remain valid")
        }
        XCTAssertThrowsError(try WebModelResponseCodec.parseReply(
            #"{"type":"tool_calls","calls":[{"name":"browser_read","arguments":"{}"}]}"#,
            request: request, requireEnvelope: true)) {
                XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .argumentsMustBeObject)
        }
    }

    func testUnarmedUnconfiguredAndEarlierInferencesDoNotConsumeExactArm() throws {
        let f = try Fixture(); defer { f.remove() }
        let request = try f.request()
        XCTAssertFalse(f.capture(request))
        XCTAssertFalse(ClaudeRequestCapture.capture(directory: nil, context: f.context, request: request, prompt: request.prompt))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).isEmpty)
        try f.arm()
        let arm = try Data(contentsOf: f.armFile)
        XCTAssertFalse(f.capture(try f.request(history: [["role": "user", "content": "Open the fixture"]])))
        XCTAssertEqual(try Data(contentsOf: f.armFile), arm)
        XCTAssertTrue(f.capture(request), "Only the later immediate post-tabs inference claims the arm")
    }

    func testPostFillCaptureRequiresItsOwnPurposeAndExactImmediateOutput() throws {
        let f = try Fixture(); defer { f.remove() }
        var history = f.history()
        history[1] = ["type": "function_call", "name": "browser_fill", "call_id": "call_fill",
                      "arguments": #"{"fill_ref":"field_current","text":"INV-FIXTURE"}"#]
        history[2] = ["type": "function_call_output", "call_id": "call_fill",
                      "output": "Fill dispatched; current observation contains INV-FIXTURE."]
        let request = try f.request(history: history)
        var fields = f.fields(); fields["trigger"] = "after_browser_fill"
        try f.arm(fields)
        XCTAssertFalse(f.capture(request), "A tabs-purpose arm must not authorize a fill capture")
        fields["purpose"] = "claude_post_browser_fill_request_v1"
        try f.arm(fields)
        let arm = try Data(contentsOf: f.armFile)
        XCTAssertFalse(f.capture(try f.request()), "An earlier tabs output must leave the fill arm intact")
        for invalid in [history + [["role": "user", "content": "browser_fill call_fill"]],
                        [history[0], history[1], history[1], history[2]]] {
            XCTAssertFalse(f.capture(try f.request(history: invalid)))
            XCTAssertEqual(try Data(contentsOf: f.armFile), arm)
        }
        let prompt = request.prompt + "\nExact post-fill handoff."
        XCTAssertTrue(f.capture(request, prompt: prompt))
        let record = try f.record()
        XCTAssertEqual(record["purpose"] as? String, "claude_post_browser_fill_request_v1")
        XCTAssertEqual(record["trigger"] as? String, "after_browser_fill")
        XCTAssertEqual(record["triggerCallID"] as? String, "call_fill")
        XCTAssertEqual(record["prompt"] as? String, prompt)
        XCTAssertEqual(record["canonicalRequest"] as? String, String(decoding: request.continuationRequest, as: UTF8.self))
        XCTAssertEqual(record["submissionVerified"] as? Bool, false)
        XCTAssertEqual(record["automaticReplay"] as? Bool, false)
        XCTAssertEqual(try f.permissions(f.output), 0o600)
        XCTAssertFalse(f.exists(f.armFile))
        let captured = try Data(contentsOf: f.output)
        XCTAssertFalse(f.capture(request))
        XCTAssertEqual(try Data(contentsOf: f.output), captured)
    }

    func testArmRequiresExactTaskTurnModelPurposeSchemaTriggerAndBoundedExpiry() throws {
        let f = try Fixture(); defer { f.remove() }
        let request = try f.request()
        let mutations: [(String, Any)] = [
            ("schemaVersion", true), ("schemaVersion", 2), ("purpose", "other"),
            ("nonce", f.nonce.uuidString.uppercased()), ("nonce", "not-an-id"),
            ("taskID", UUID().uuidString.lowercased()), ("turnID", UUID().uuidString.lowercased()),
            ("modelID", WebsiteModelChoice(provider: "claude", key: "Sonnet 5.5", label: "Sonnet 5.5").modelID),
            ("trigger", "before_first_send"), ("expiresAt", f.timestamp(f.now)),
            ("expiresAt", f.timestamp(f.now.addingTimeInterval(601))), ("expiresAt", "2033-05-18T03:33:20+00:00"),
        ]
        for (key, value) in mutations {
            var fields = f.fields(); fields[key] = value; try f.arm(fields)
            let before = try Data(contentsOf: f.armFile)
            XCTAssertFalse(f.capture(request), key)
            XCTAssertEqual(try Data(contentsOf: f.armFile), before, key)
            XCTAssertFalse(f.exists(f.output), key)
        }
        for key in f.fields().keys {
            var missing = f.fields(); missing.removeValue(forKey: key); try f.arm(missing)
            XCTAssertFalse(f.capture(request), key)
        }
        var extra = f.fields(); extra["captureEverything"] = true; try f.arm(extra)
        XCTAssertFalse(f.capture(request))
        let valid = String(decoding: try JSONSerialization.data(withJSONObject: f.fields()), as: UTF8.self)
        try f.write(Data(("{\"schemaVersion\":1," + valid.dropFirst()).utf8), to: f.armFile)
        XCTAssertFalse(f.capture(request), "Duplicate keys cannot authorize capture")
        try f.write(Data(repeating: 32, count: 4_097), to: f.armFile)
        XCTAssertFalse(f.capture(request))
    }

    func testTriggerRejectsUnlinkedOldDuplicateInterveningOrAuthoredCalls() throws {
        let f = try Fixture(); defer { f.remove() }
        let base = f.history()
        var otherCall = base[1]; otherCall["name"] = "browser_open"
        var otherOutput = base[2]; otherOutput["call_id"] = "wrong_call"
        var customCall = base[1]; customCall["type"] = "custom_tool_call"
        let message: [String: Any] = ["role": "user", "content": "browser_tabs function_call_output call_tabs"]
        let histories: [[[String: Any]]] = [
            [base[0], otherCall, base[2]], [base[0], base[1], otherOutput],
            [base[0], customCall, base[2]], base + [message],
            [base[0], base[1], message, base[2]], [base[0], base[1], base[1], base[2]],
            [base[0], base[2], base[1]], [message],
        ]
        for history in histories {
            try f.arm(); let arm = try Data(contentsOf: f.armFile)
            XCTAssertFalse(f.capture(try f.request(history: history)))
            XCTAssertEqual(try Data(contentsOf: f.armFile), arm)
            XCTAssertFalse(f.exists(f.output))
        }
        // Native Responses output keeps the unqualified name and a separate
        // namespace field; no suffix matching on arbitrary names is needed.
        var namespaced = base; namespaced[1]["namespace"] = "functions"
        try f.arm(); XCTAssertTrue(f.capture(try f.request(history: namespaced)))
    }

    func testOnlyConcreteMatchingClaudeAndBoundedPromptsAreCaptured() throws {
        let f = try Fixture(); defer { f.remove() }; try f.arm()
        for model in ["browser/claude", "browser/chatgpt", "browser/gemini"] {
            let request = try f.request(model: model)
            let context = f.contextWithModel(model)
            XCTAssertFalse(ClaudeRequestCapture.capture(directory: f.directory, context: context,
                request: request, prompt: request.prompt, now: f.now))
        }
        let request = try f.request()
        XCTAssertFalse(ClaudeRequestCapture.capture(directory: f.directory,
            context: f.contextWithModel("browser/claude"), request: request, prompt: request.prompt, now: f.now))
        XCTAssertFalse(f.capture(request, prompt: ""))
        XCTAssertFalse(f.capture(request, prompt: String(repeating: "x", count: WebModelResponseCodec.maximumPromptBytes + 1)))
        XCTAssertTrue(f.exists(f.armFile)); XCTAssertFalse(f.exists(f.output))
    }

    func testUnsafePrivateFilesAndExistingOutputNeverCaptureOrOverwrite() throws {
        for mode in ["directory_mode", "arm_mode", "symlink_directory", "symlink_arm", "hardlink_arm", "fifo_arm", "existing_output"] {
            let f = try Fixture(); defer { f.remove() }; try f.arm()
            var directory = f.directory
            let retained = f.root.appendingPathComponent("retained")
            switch mode {
            case "directory_mode": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
            case "arm_mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.armFile.path)
            case "symlink_directory":
                directory = f.root.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: f.directory)
            case "symlink_arm":
                try FileManager.default.moveItem(at: f.armFile, to: retained)
                try FileManager.default.createSymbolicLink(at: f.armFile, withDestinationURL: retained)
            case "hardlink_arm": XCTAssertEqual(link(f.armFile.path, retained.path), 0)
            case "fifo_arm": try FileManager.default.removeItem(at: f.armFile); XCTAssertEqual(mkfifo(f.armFile.path, 0o600), 0)
            case "existing_output": try f.write(Data("retain prior private evidence".utf8), to: f.output)
            default: XCTFail("Unknown fixture")
            }
            let request = try f.request()
            XCTAssertFalse(ClaudeRequestCapture.capture(directory: directory, context: f.context,
                request: request, prompt: request.prompt, now: f.now), mode)
            XCTAssertTrue(f.exists(f.armFile), mode)
            if mode == "existing_output" { XCTAssertEqual(try Data(contentsOf: f.output), Data("retain prior private evidence".utf8)) }
            else { XCTAssertFalse(f.exists(f.output), mode) }
        }
        let f = try Fixture(); defer { f.remove() }; let request = try f.request()
        let absent = f.root.appendingPathComponent("absent")
        XCTAssertFalse(ClaudeRequestCapture.capture(directory: absent, context: f.context,
            request: request, prompt: request.prompt, now: f.now))
        XCTAssertFalse(f.exists(absent))
    }

    func testReplacedArmCannotAuthorizeCaptureAndReplacementIsPreserved() throws {
        let f = try Fixture(); defer { f.remove() }; try f.arm(); let request = try f.request()
        var fields = f.fields(); fields["taskID"] = UUID().uuidString.lowercased()
        let replacement = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        XCTAssertFalse(ClaudeRequestCapture.capture(directory: f.directory, context: f.context,
            request: request, prompt: request.prompt, now: f.now, beforeArmClaimForTesting: {
                do { try FileManager.default.removeItem(at: f.armFile); try f.write(replacement, to: f.armFile) }
                catch { XCTFail("Could not replace fixture arm: \(error)") }
            }))
        XCTAssertEqual(try Data(contentsOf: f.armFile), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["arm.json"])
    }

    func testPublicationRacePreservesExistingEvidenceAndConsumesOnlyTheMatchingArm() throws {
        let f = try Fixture(); defer { f.remove() }; try f.arm(); let request = try f.request()
        let retained = Data("existing private evidence created after the initial check".utf8)
        XCTAssertFalse(ClaudeRequestCapture.capture(directory: f.directory, context: f.context,
            request: request, prompt: request.prompt, now: f.now, beforeArmClaimForTesting: {
                do { try f.write(retained, to: f.output) }
                catch { XCTFail("Could not create deterministic publication race: \(error)") }
            }))
        XCTAssertEqual(try Data(contentsOf: f.output), retained)
        XCTAssertFalse(f.exists(f.armFile), "A claimed attempt is one-shot even when publication fails")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["request.json"])
        try FileManager.default.removeItem(at: f.output)
        XCTAssertFalse(f.capture(request), "A write failure must not silently rearm a later inference")
        XCTAssertFalse(f.exists(f.output))
    }

    func testConcurrentAttemptsPublishExactlyOneCompleteRecord() throws {
        let f = try Fixture(); defer { f.remove() }; try f.arm(); let request = try f.request()
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in results.add(f.capture(request)) }
        XCTAssertEqual(results.successes, 1)
        XCTAssertEqual(try f.record()["prompt"] as? String, request.prompt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["request.json"])
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private struct Fixture: Sendable {
        let root: URL
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let nonce = UUID()
        let context = ClaudeRequestCapture.Context(taskID: UUID(), threadID: UUID(), turnID: UUID(), runtimeGeneration: UUID(),
            preparationID: UUID(), inferenceID: UUID(), sessionToken: UUID(),
            modelID: WebsiteModelChoice(provider: "claude", key: "Haiku 5.5", label: "Haiku 5.5").modelID)
        var directory: URL { root.appendingPathComponent(ClaudeRequestCapture.directoryName) }
        var armFile: URL { directory.appendingPathComponent("arm.json") }
        var output: URL { directory.appendingPathComponent("request.json") }
        init() throws {
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
            defer { free(resolved) }
            root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent("ClaudeRequest-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func history() -> [[String: Any]] {
            [["role": "user", "content": "Inspect fixture only. Exact e\u{0301}, 🧭, \\n and <>&."],
             ["type": "function_call", "name": "browser_tabs", "call_id": "call_tabs", "arguments": "{}"],
             ["type": "function_call_output", "call_id": "call_tabs", "output": [["type": "input_text", "text": "bound_current_turn\nprivate exact fixture output"]]]]
        }
        func request(history: [[String: Any]]? = nil, model: String? = nil) throws -> WebModelResponseCodec.Request {
            let tools = EmbeddedBrowserTools.definitions().map { definition in
                var tool = definition; tool["parameters"] = tool.removeValue(forKey: "inputSchema"); return tool
            }
            let data = try JSONSerialization.data(withJSONObject: ["model": model ?? context.modelID,
                "input": history ?? self.history(), "tools": tools, "tool_choice": "auto", "parallel_tool_calls": false],
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return try WebModelResponseCodec.prepareRequest(data, browserToolAvailability: .bound)
        }
        func contextWithModel(_ model: String) -> ClaudeRequestCapture.Context {
            .init(taskID: context.taskID, threadID: context.threadID, turnID: context.turnID,
                  runtimeGeneration: context.runtimeGeneration, preparationID: context.preparationID,
                  inferenceID: context.inferenceID, sessionToken: context.sessionToken, modelID: model)
        }
        func fields() -> [String: Any] {
            ["schemaVersion": 1, "purpose": ClaudeRequestCapture.purpose, "nonce": nonce.uuidString.lowercased(),
             "taskID": context.taskID.uuidString.lowercased(), "turnID": context.turnID.uuidString.lowercased(),
             "modelID": context.modelID, "trigger": "after_browser_tabs", "expiresAt": timestamp(now.addingTimeInterval(300))]
        }
        func timestamp(_ date: Date) -> String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            f.timeZone = TimeZone(secondsFromGMT: 0); return f.string(from: date)
        }
        func arm(_ fields: [String: Any]? = nil) throws {
            try write(JSONSerialization.data(withJSONObject: fields ?? self.fields(), options: [.sortedKeys]), to: armFile)
        }
        func write(_ bytes: Data, to path: URL) throws {
            guard FileManager.default.createFile(atPath: path.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        func capture(_ request: WebModelResponseCodec.Request, prompt: String? = nil) -> Bool {
            ClaudeRequestCapture.capture(directory: directory, context: context, request: request, prompt: prompt ?? request.prompt, now: now)
        }
        func record() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]) }
        func permissions(_ url: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    var successes: Int { lock.lock(); defer { lock.unlock() }; return values.filter { $0 }.count }
}

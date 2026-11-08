import Darwin
import Foundation
import XCTest
@testable import Computa

final class WebModelRejectedReplyCaptureTests: XCTestCase {

    func testChatGPTRenderedToolSourceRejectionCapturesOnlyForExactOptInWithoutReplay() async throws {
        let reply = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf 'one space'"}}]}"#
        for mode in ["no_arm", "other_task", "exact_task", "unconfigured"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(), thread = UUID()
            if mode != "no_arm" { try fixture.arm(mode == "other_task" ? UUID() : task) }
            let transport = RejectedReplyTransport(reply: reply)
            let storage = fixture.root.appendingPathComponent("state")
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: mode == "unconfigured" ? nil : fixture.directory, storageDirectory: storage)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport,
                defaultChatChoice: syntheticChatGPTChoice))
            let input = try encoded(["model": syntheticChatGPTModelID, "input": "request-only-secret",
                "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object"]]], "stream": true])
            var emitted: Data?
            do { emitted = try await server.fixtureInfer(input, taskID: task.uuidString, threadID: thread.uuidString); XCTFail("Rendered tool text must remain rejected") }
            catch {
                guard case .toolTextUnverified(.renderedFallback) = error as? WebModelServer.Failure else { return XCTFail("Unexpected source rejection: \(error)") }
                XCTAssertEqual(WebModelServer.errorPresentation(for: error).status, "400 Bad Request")
            }
            XCTAssertNil(emitted)
            let beforeCleanup = await transport.operations()
            XCTAssertEqual(beforeCleanup, ["webProviderStart", "webProviderSend", "webProviderPoll"])
            if mode == "exact_task" {
                let value = try fixture.record()
                XCTAssertEqual(value["replyText"] as? String, reply, "This is the rejected rendered reply, not a claim about authored bytes")
                XCTAssertEqual(value["taskID"] as? String, task.uuidString.lowercased())
                XCTAssertEqual(value["threadID"] as? String, thread.uuidString.lowercased())
                XCTAssertEqual(value["provider"] as? String, "chatgpt")
                XCTAssertEqual(value["automaticReplay"] as? Bool, false)
                let diagnostic = try XCTUnwrap(value["diagnostic"] as? [String: Any])
                XCTAssertEqual(Set(diagnostic.keys), ["reason", "sourceReason", "utf8Bytes"])
                XCTAssertEqual(diagnostic["reason"] as? String, "website_tool_text_unverified")
                XCTAssertEqual(diagnostic["sourceReason"] as? String, "rendered_fallback")
                XCTAssertEqual(diagnostic["utf8Bytes"] as? Int, reply.utf8.count)
                XCTAssertEqual(try fixture.permissions(fixture.output), 0o600)
                XCTAssertFalse(fixture.exists(fixture.armFile))
                let saved = String(decoding: try Data(contentsOf: fixture.output), as: UTF8.self)
                XCTAssertFalse(saved.contains("request-only-secret")); XCTAssertFalse(saved.contains("metadata-content-secret"))
            } else {
                XCTAssertFalse(fixture.exists(fixture.output), mode)
                XCTAssertEqual(fixture.exists(fixture.armFile), mode != "no_arm", mode)
            }
            let issues = await server.fixtureFinish(taskID: task.uuidString)
            XCTAssertTrue(issues.isEmpty)
            let operations = await transport.operations()
            XCTAssertEqual(operations, ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"])
            XCTAssertFalse(fixture.exists(storage.appendingPathComponent("evidence/format-corrections-v1")))
            _ = await server.shutdown()
        }
    }
    func testCallShapeFailuresCaptureExactReplyWithoutReleasingValidPrefixOrCorrecting() async throws {
        let invalidFunctions = [
            #"{"name":"exec_command","arguments":"{\"cmd\":\"printf private\"}"}"#,
            #"{"name":"exec_command","arguments":null}"#,
            #"{"name":"exec_command","arguments":[]}"#,
            #"{"name":"exec_command"}"#,
        ]
        let invalidCustoms = [
            #"{"name":"apply_patch","input":{"patch":"private"}}"#,
            #"{"name":"apply_patch","input":null}"#,
        ]
        for stream in [false, true] {
            for call in invalidFunctions {
                try await assertCallShapeFailure(call, custom: false, mode: "exact_task", stream: stream)
            }
            for call in invalidCustoms {
                try await assertCallShapeFailure(call, custom: true, mode: "exact_task", stream: stream)
            }
        }
    }

    func testUnsupportedCallFieldsRejectEntireBatchWithoutCorrectionOrDispatch() async throws {
        for call in [
            #"{"name":"exec_command","arguments":{"cmd":"printf private"},"private-extra":true}"#,
            #"{"name":"apply_patch","input":"private literal patch","private-extra":true}"#,
            #"{"name":"apply_patch","arguments":{}}"#
        ] {
            let reply = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf private"}},"# + call + "]}"
            for stream in [false, true] {
                try await assertRejectedReplyFailure(reply, expected: .unsupportedCallFields,
                    reason: "unsupported_call_fields", mode: "exact_task", stream: stream)
            }
        }
    }

    func testCallShapeCaptureOptInAndWriteFailuresPreserveOriginalErrorAndNoReplay() async throws {
        for mode in ["no_arm", "other_task", "unsafe_arm", "unconfigured", "existing_record"] {
            try await assertCallShapeFailure(#"{"name":"exec_command","arguments":null}"#,
                                             custom: false, mode: mode, stream: true)
            try await assertCallShapeFailure(#"{"name":"apply_patch","input":null}"#,
                                             custom: true, mode: mode, stream: true)
        }
    }

    private func assertCallShapeFailure(_ invalidCall: String, custom: Bool, mode: String, stream: Bool) async throws {
        let reply = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf reply-only-private"}},"# + invalidCall + "]}"
        try await assertRejectedReplyFailure(reply,
            expected: custom ? .customInputMustBeString : .argumentsMustBeObject,
            reason: custom ? "invalid_custom_call_shape" : "invalid_function_call_shape", mode: mode, stream: stream)
    }

    func testBrowserReadAndEmptyReplyFailuresCaptureExactlyWithoutReleaseOrCorrection() async throws {
        let calls = [
            #"{"name":"browser_read","arguments":{"cursor":null}}"#,
            #"{"name":"browser_continue","arguments":{"cursor":""}}"#,
            #"{"name":"browser_continue","arguments":{"cursor":"issued","view":"all"}}"#,
        ]
        for stream in [false, true] {
            for call in calls {
                try await assertRejectedReplyFailure(browserReply(call), expected: .invalidBrowserReadArguments,
                    reason: "invalid_browser_read_arguments", mode: "exact_task", stream: stream,
                    additionalTools: browserTools())
            }
            for reply in [" \t\n\u{00a0}\r\n", ""] {
                try await assertRejectedReplyFailure(reply, expected: reply.isEmpty ? nil : .emptyReply,
                    reason: "empty_reply", mode: "exact_task", stream: stream)
            }
        }
    }

    func testBrowserReadAndEmptyReplyCaptureFailuresPreserveOriginalRejection() async throws {
        for mode in ["no_arm", "other_task", "unsafe_arm", "unconfigured", "existing_record"] {
            try await assertRejectedReplyFailure(browserReply(#"{"name":"browser_read","arguments":{"cursor":null}}"#),
                expected: .invalidBrowserReadArguments, reason: "invalid_browser_read_arguments",
                mode: mode, stream: true, additionalTools: browserTools())
            for reply in [" \t\r\n", ""] {
                try await assertRejectedReplyFailure(reply, expected: reply.isEmpty ? nil : .emptyReply,
                    reason: "empty_reply", mode: mode, stream: true)
            }
        }
    }

    private func browserReply(_ call: String) -> String {
        #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf reply-only-private"}},"# + call + "]}"
    }

    private func browserTools() throws -> [[String: Any]] {
        try ["browser_read", "browser_continue"].map { name in
            var tool = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            tool["parameters"] = tool.removeValue(forKey: "inputSchema")
            tool["type"] = "function"
            return tool
        }
    }

    // A nil codec failure denotes the pre-existing providerFailed error for a
    // literal empty snapshot string, before the codec is entered.
    private func assertRejectedReplyFailure(_ reply: String, expected: WebModelResponseCodec.Failure?,
        reason: String, mode: String, stream: Bool, additionalTools: [[String: Any]] = []) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), turn = UUID()
        let choice = WebsiteModelChoice(provider: "claude", key: "Haiku 5.5", label: "Haiku 5.5")
        let label = "\(reason)/\(mode)/stream=\(stream): \(reply.debugDescription)"
        if mode != "no_arm" { try fixture.arm(mode == "other_task" ? UUID() : task) }
        if mode == "unsafe_arm" {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.armFile.path)
        }
        let oldRecord = Data("previous private evidence must remain unchanged".utf8)
        if mode == "existing_record" { try fixture.writeArm(oldRecord, to: fixture.output) }
        let armBefore = try fixture.exists(fixture.armFile) ? Data(contentsOf: fixture.armFile) : nil
        // Even diagnostic metadata eligible for invalid-JSON correction cannot
        // turn these rejected replies into a corrective inference.
        let metadata: [String: Any] = ["preCount": 1, "codeCount": 1, "literalCodeValidJSON": true,
            "literalCodeKnownEnvelopeType": "tool_calls", "selectedExtraction": "rendered_fallback",
            "extractionReason": "outside_content", "unknown": "metadata-content-secret"]
        let transport = RejectedReplyTransport(reply: reply, codeStructure: try encoded(metadata))
        let storage = fixture.root.appendingPathComponent("state")
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
            rejectedReplyDirectory: mode == "unconfigured" ? nil : fixture.directory, storageDirectory: storage)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport, defaultClaudeChoice: choice))
        let input = try encoded(["model": choice.modelID, "input": "request-only-secret", "stream": stream,
            "tools": [["type": "function", "name": "exec_command", "description": "schema-only-secret",
                       "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]],
                      ["type": "custom", "name": "apply_patch", "format": ["type": "text"]]] + additionalTools])
        var released: Data?
        do {
            released = try await server.fixtureInfer(input, taskID: task.uuidString,
                threadID: thread.uuidString, turnID: turn.uuidString)
            XCTFail("The entire reply must remain rejected: \(label)")
        } catch {
            if let expected {
                XCTAssertEqual(error as? WebModelResponseCodec.Failure, expected, label)
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription, label)
                XCTAssertEqual(WebModelServer.errorPresentation(for: error).code, "invalid_model_output", label)
            } else {
                guard case .providerFailed = error as? WebModelServer.Failure else {
                    XCTFail("The original providerFailed error must survive capture: \(label): \(error)"); return
                }
                XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.providerFailed.localizedDescription, label)
            }
        }
        XCTAssertNil(released, "Neither streaming bytes nor the earlier valid tool call may be released: \(label)")
        let beforeCleanup = await transport.operations()
        XCTAssertEqual(beforeCleanup, ["webProviderStart", "webProviderSend", "webProviderPoll"], label)
        let journal = storage.appendingPathComponent("evidence/transactions/\(task.uuidString.lowercased())/\(turn.uuidString.lowercased()).jsonl")
        let records = try Data(contentsOf: journal).split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(records.filter { $0["phase"] as? String == "failed" }.count, 1, label)
        XCTAssertFalse(records.contains { ["complete", "release_verified"].contains($0["phase"] as? String ?? "") }, label)
        XCTAssertFalse(fixture.exists(storage.appendingPathComponent("evidence/format-corrections-v1")), label)
        if mode == "exact_task" {
            let record = try fixture.record()
            XCTAssertEqual(record["replyText"] as? String, reply, label)
            XCTAssertEqual(record["taskID"] as? String, task.uuidString.lowercased(), label)
            XCTAssertEqual(record["threadID"] as? String, thread.uuidString.lowercased(), label)
            XCTAssertEqual(record["provider"] as? String, "claude", label)
            XCTAssertEqual(record["modelID"] as? String, choice.modelID, label)
            XCTAssertEqual(record["automaticReplay"] as? Bool, false, label)
            for key in ["inferenceID", "sessionToken", "documentGeneration"] {
                XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(record[key] as? String)), "\(label): \(key)")
            }
            XCTAssertEqual(record["sequence"] as? Int, 1, label)
            let diagnostic = try XCTUnwrap(record["diagnostic"] as? [String: Any])
            XCTAssertEqual(Set(diagnostic.keys), ["reason", "utf8Bytes"], label)
            XCTAssertEqual(diagnostic["reason"] as? String, reason, label)
            XCTAssertEqual(diagnostic["utf8Bytes"] as? Int, reply.utf8.count, label)
            let capture = String(decoding: try Data(contentsOf: fixture.output), as: UTF8.self)
            for secret in ["request-only-secret", "schema-only-secret", "metadata-content-secret"] {
                XCTAssertFalse(capture.contains(secret), label)
            }
            XCTAssertEqual(try fixture.permissions(fixture.output), 0o600, label)
            XCTAssertFalse(fixture.exists(fixture.armFile), label)
        } else {
            if mode == "existing_record" { XCTAssertEqual(try Data(contentsOf: fixture.output), oldRecord, label) }
            else { XCTAssertFalse(fixture.exists(fixture.output), label) }
            let armAfter = try fixture.exists(fixture.armFile) ? Data(contentsOf: fixture.armFile) : nil
            XCTAssertEqual(armAfter, armBefore, label)
        }
        let issues = await server.fixtureFinish(taskID: task.uuidString)
        XCTAssertTrue(issues.isEmpty, label)
        let finalOperations = await transport.operations()
        XCTAssertEqual(finalOperations, beforeCleanup + ["webProviderFinish"], label)
        XCTAssertFalse(fixture.exists(storage.appendingPathComponent("evidence/format-corrections-v1")), label)
        _ = await server.shutdown()
    }

    func testUnsupportedChatGPTProseCapturesOnlyForExactOptInAndPreservesTerminalFailure() async throws {
        let reply = "Hello, this is ordinary synthetic prose with a planet called Blue Meadow."
        for mode in ["no_arm", "other_task", "exact_task", "unconfigured"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(), thread = UUID()
            if mode != "no_arm" { try fixture.arm(mode == "other_task" ? UUID() : task) }
            let transport = RejectedReplyTransport(reply: reply)
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: mode == "unconfigured" ? nil : fixture.directory)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport,
                defaultChatChoice: syntheticChatGPTChoice))
            let input = try encoded(["model": syntheticChatGPTModelID, "input": "request-only-secret",
                                     "tools": [], "tool_choice": "none", "stream": false])
            do {
                _ = try await server.fixtureInfer(input, taskID: task.uuidString, threadID: thread.uuidString)
                XCTFail("Private capture must not admit the rejected prose")
            } catch {
                XCTAssertEqual(error as? WebModelResponseCodec.Failure, .unsupportedWebsiteResponse, mode)
                XCTAssertEqual(WebModelServer.errorPresentation(for: error).code, "unsupported_website_response", mode)
            }
            let beforeCleanup = await transport.operations()
            XCTAssertEqual(beforeCleanup, ["webProviderStart", "webProviderSend", "webProviderPoll"], mode)
            if mode == "exact_task" {
                let value = try fixture.record()
                XCTAssertEqual(value["replyText"] as? String, reply)
                XCTAssertEqual(value["taskID"] as? String, task.uuidString.lowercased())
                XCTAssertEqual(value["threadID"] as? String, thread.uuidString.lowercased())
                XCTAssertEqual(value["provider"] as? String, "chatgpt")
                XCTAssertEqual(value["automaticReplay"] as? Bool, false)
                let diagnostic = try XCTUnwrap(value["diagnostic"] as? [String: Any])
                XCTAssertEqual(diagnostic["reason"] as? String, "unsupported_website_response")
                XCTAssertEqual(diagnostic["utf8Bytes"] as? Int, reply.utf8.count)
                XCTAssertEqual(try fixture.permissions(fixture.output), 0o600)
                XCTAssertFalse(fixture.exists(fixture.armFile))
                XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.output), as: UTF8.self).contains("request-only-secret"))
            } else {
                XCTAssertFalse(fixture.exists(fixture.output), mode)
                XCTAssertEqual(fixture.exists(fixture.armFile), mode != "no_arm", mode)
            }
            let issues = await server.fixtureFinish(taskID: task.uuidString)
            XCTAssertTrue(issues.isEmpty, mode)
            let operations = await transport.operations()
            XCTAssertEqual(operations, ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"],
                           "Capture must not resend or change the existing terminal cleanup handoff: \(mode)")
            _ = await server.shutdown()
        }
    }

    func testPrivateCapturePreservesFiniteFinalWidgetAncestryWithoutUnknownContent() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID()
        try fixture.arm(task)
        let metadata: [String: Any] = [
            "preCount": 1, "codeCount": 1, "codeTextLength": 129, "outsideTextLength": 4,
            "outsideTruncated": false, "preParentTags": ["div", "div", "div"],
            "literalCodeValidJSON": true, "literalCodeKnownEnvelopeType": "tool_calls",
            "selectedExtraction": "rendered_fallback", "extractionReason": "outside_content",
            "outsideNodes": [["kind": "json", "textLength": 4, "text": "metadata-content-secret",
                              "ancestors": [["tag": "div", "classes": ["flex", "truncate"],
                                              "preDescendants": 1, "copyControls": 1,
                                              "text": "metadata-content-secret"]]]],
            "unknown": "metadata-content-secret",
        ]
        let transport = RejectedReplyTransport(reply: "JSON\n{}", codeStructure: try JSONSerialization.data(withJSONObject: metadata))
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, rejectedReplyDirectory: fixture.directory)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        await assertMalformed(server, task: task, thread: thread)
        let value = try fixture.record()
        let structure = try XCTUnwrap(value["codeStructure"] as? [String: Any])
        let nodes = try XCTUnwrap(structure["outsideNodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0]["kind"] as? String, "json")
        XCTAssertEqual(structure["literalCodeValidJSON"] as? Bool, true)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.output), as: UTF8.self).contains("metadata-content-secret"))
        XCTAssertFalse(fixture.exists(fixture.armFile))
        let operations = await transport.operations()
        XCTAssertEqual(operations.filter { $0 == "webProviderSend" }.count, 1)
        _ = await server.shutdown()
    }

    func testEmbeddedPlainFinalTextUsesMessageOutputWithoutReplayOrDiagnosticCapture() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), reply = "marker-plain-final-fixture"
        try fixture.arm(task)
        let transport = RejectedReplyTransport(reply: reply)
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, rejectedReplyDirectory: fixture.directory)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        let bytes = try await server.fixtureInfer(request, taskID: task.uuidString)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0]["type"] as? String, "message")
        let content = try XCTUnwrap(output[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, reply)
        let operations = await transport.operations()
        XCTAssertEqual(operations.filter { $0 == "webProviderSend" }.count, 1)
        XCTAssertFalse(fixture.exists(fixture.output))
        XCTAssertTrue(fixture.exists(fixture.armFile))
        let cleanup = await server.fixtureFinish(taskID: task.uuidString)
        XCTAssertTrue(cleanup.isEmpty)
        _ = await server.shutdown()
    }

    func testValidRefusalsAndEmptyMessageDoNotCaptureOrCorrect() async throws {
        let refusal = "I cannot help with that request."
        for (reply, text) in [(refusal, refusal),
                              (#"{"type":"message","text":"I cannot help with that request."}"#, refusal),
                              (#"{"type":"message","text":""}"#, "")] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(), choice = WebsiteModelChoice(provider: "claude", key: "Haiku 5.5", label: "Haiku 5.5")
            try fixture.arm(task)
            let arm = try Data(contentsOf: fixture.armFile)
            let transport = RejectedReplyTransport(reply: reply)
            let storage = fixture.root.appendingPathComponent("state")
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: fixture.directory, storageDirectory: storage)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport, defaultClaudeChoice: choice))
            let input = try encoded(["model": choice.modelID, "input": "request-only-secret", "tools": [], "stream": false])
            let bytes = try await server.fixtureInfer(input, taskID: task.uuidString)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let output = try XCTUnwrap(response["output"] as? [[String: Any]])
            XCTAssertEqual(output.count, 1)
            XCTAssertEqual(output.first?["type"] as? String, "message")
            let content = try XCTUnwrap(output.first?["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["text"] as? String, text)
            XCTAssertFalse(fixture.exists(fixture.output))
            XCTAssertEqual(try Data(contentsOf: fixture.armFile), arm)
            XCTAssertFalse(fixture.exists(storage.appendingPathComponent("evidence/format-corrections-v1")))
            let operations = await transport.operations()
            XCTAssertEqual(operations, ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"])
            let cleanup = await server.fixtureFinish(taskID: task.uuidString)
            XCTAssertTrue(cleanup.isEmpty)
            _ = await server.shutdown()
        }
    }

    func testMissingTextAndUnverifiedSnapshotsDoNotCaptureRejectedReply() async throws {
        for mutation in RejectedReplySnapshotMutationTransport.Mutation.allCases {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(), choice = WebsiteModelChoice(provider: "claude", key: "Haiku 5.5", label: "Haiku 5.5")
            try fixture.arm(task)
            let arm = try Data(contentsOf: fixture.armFile)
            // Without the outer mutation, this exact whitespace would be captured.
            let transport = RejectedReplyTransport(reply: " \t\r\n")
            let storage = fixture.root.appendingPathComponent("state")
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: fixture.directory, storageDirectory: storage)
            let prepared = WebsiteInferenceFixtureTransport(transport, defaultClaudeChoice: choice)
            await server.configureEmbeddedTransport(RejectedReplySnapshotMutationTransport(base: prepared, mutation: mutation))
            let input = try encoded(["model": choice.modelID, "input": "request-only-secret", "tools": [], "stream": true])
            var released: Data?
            do {
                released = try await server.fixtureInfer(input, taskID: task.uuidString)
                XCTFail("An invalid snapshot must remain rejected: \(mutation)")
            } catch {
                switch (mutation, error as? WebModelServer.Failure) {
                case (.missingText, .providerFailed), (.nonStringText, .providerFailed),
                     (.oppositeStartPolicy, .invalidRequest), (.invalidProof, .invalidRequest), (.invalidModel, .modelUnverified): break
                default: XCTFail("Unexpected rejection for \(mutation): \(error)")
                }
            }
            XCTAssertNil(released)
            XCTAssertFalse(fixture.exists(fixture.output))
            XCTAssertEqual(try Data(contentsOf: fixture.armFile), arm)
            XCTAssertFalse(fixture.exists(storage.appendingPathComponent("evidence/format-corrections-v1")))
            let operations = await transport.operations()
            let expected = mutation == .oppositeStartPolicy ? ["webProviderStart"] : ["webProviderStart", "webProviderSend", "webProviderPoll"]
            XCTAssertEqual(operations, expected, "Unexpected operation sequence for \(mutation)")
            let cleanup = await server.fixtureFinish(taskID: task.uuidString)
            XCTAssertTrue(cleanup.isEmpty)
            _ = await server.shutdown()
        }
    }

    func testUnofferedToolKeepsOriginalRejectionAndCapturesOnlyWithExactTaskArm() async throws {
        let reply = #"{"type":"tool_calls","calls":[{"name":"unoffered_fixture_tool","arguments":{}}]}"#
        for armed in [false, true] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(), transport = RejectedReplyTransport(reply: reply)
            if armed { try fixture.arm(task) }
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self, rejectedReplyDirectory: fixture.directory)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
            do { _ = try await server.fixtureInfer(request, taskID: task.uuidString); XCTFail("An unoffered tool must remain rejected") }
            catch { XCTAssertEqual(error as? WebModelResponseCodec.Failure,.unknownTool("unoffered_fixture_tool")) }
            let operations = await transport.operations()
            XCTAssertEqual(operations.filter { $0 == "webProviderSend" }.count,1,"Diagnostics must not replay inference")
            if armed {
                let value = try fixture.record()
                XCTAssertEqual(value["replyText"] as? String,reply)
                XCTAssertEqual(value["taskID"] as? String,task.uuidString.lowercased())
                XCTAssertEqual(value["automaticReplay"] as? Bool,false)
                let diagnostic = try XCTUnwrap(value["diagnostic"] as? [String:Any])
                XCTAssertEqual(diagnostic["reason"] as? String,"unoffered_tool")
                XCTAssertEqual(diagnostic["utf8Bytes"] as? Int,reply.utf8.count)
                XCTAssertFalse(fixture.exists(fixture.armFile))
                XCTAssertEqual(try fixture.permissions(fixture.output),0o600)
            } else { XCTAssertFalse(fixture.exists(fixture.output),"A configured directory alone cannot capture reply content") }
            let cleanup = await server.fixtureFinish(taskID: task.uuidString)
            XCTAssertTrue(cleanup.isEmpty)
            _ = await server.shutdown()
        }
    }

    func testMalformedReplyCapturesExactInputOnceWithoutDispatchOrReplay() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), thread = UUID(), reply = "Rejected prose with JSON-looking text { and escaped \\\n🙂"
        try fixture.arm(task)
        let transport = RejectedReplyTransport(reply: reply)
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, rejectedReplyDirectory: fixture.directory)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        await assertMalformed(server, task: task, thread: thread)
        let value = try fixture.record()
        XCTAssertEqual(value["replyText"] as? String, reply)
        XCTAssertEqual(value["taskID"] as? String, task.uuidString.lowercased())
        XCTAssertEqual(value["threadID"] as? String, thread.uuidString.lowercased())
        XCTAssertEqual(value["provider"] as? String, "claude")
        XCTAssertEqual(value["modelID"] as? String, "browser/claude")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(value["inferenceID"] as? String)))
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(value["sessionToken"] as? String)))
        XCTAssertEqual(value["automaticReplay"] as? Bool, false)
        let diagnostic = try XCTUnwrap(value["diagnostic"] as? [String: Any])
        XCTAssertEqual(diagnostic["reason"] as? String, "invalid_json")
        XCTAssertEqual(diagnostic["utf8Bytes"] as? Int, reply.utf8.count)
        let structure = try XCTUnwrap(value["codeStructure"] as? [String: Any])
        XCTAssertEqual(Set(structure.keys), ["preCount", "codeCount", "outsideTruncated", "literalCodeValidJSON",
                                               "literalCodeKnownEnvelopeType", "selectedExtraction", "extractionReason"])
        XCTAssertEqual(structure["selectedExtraction"] as? String, "rendered_fallback")
        let bytes = try Data(contentsOf: fixture.output)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("request-only-secret"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("metadata-content-secret"))
        XCTAssertEqual(try fixture.permissions(fixture.directory), 0o700)
        XCTAssertEqual(try fixture.permissions(fixture.output), 0o600)
        XCTAssertFalse(fixture.exists(fixture.armFile))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["rejected-reply.json"])
        let firstOperations = await transport.operations()
        XCTAssertEqual(firstOperations.filter { $0 == "webProviderSend" }.count, 1)
        try FileManager.default.removeItem(at: fixture.output)
        let cleanupIssues = await server.fixtureFinish(taskID: task.uuidString)
        XCTAssertEqual(cleanupIssues, [], "The failed lease must close before a new explicit inference")
        await assertMalformed(server, task: task, thread: thread)
        XCTAssertFalse(fixture.exists(fixture.output), "An already-consumed arm cannot capture a later explicit inference")
        let secondOperations = await transport.operations()
        XCTAssertEqual(secondOperations.filter { $0 == "webProviderSend" }.count, 2)
        _ = await server.shutdown()
    }

    func testCaptureRemainsDisabledWithoutConfigurationAndForSuccessfulReplies() async throws {
        for configured in [false, true] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let task = UUID(); try fixture.arm(task)
            let transport = RejectedReplyTransport(reply: configured ? #"{"type":"message","text":"OK"}"# : "invalid {")
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: configured ? fixture.directory : nil)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
            if configured { _ = try await server.fixtureInfer(request, taskID: task.uuidString) }
            else { await assertMalformed(server, task: task) }
            XCTAssertTrue(fixture.exists(fixture.armFile))
            XCTAssertFalse(fixture.exists(fixture.output))
            _ = await server.shutdown()
        }
    }

    func testArmIsExactTaskScopedAndRejectsMalformedOrExtendedInstructions() throws {
        let task = UUID()
        for arm in [Data("not JSON".utf8), try encoded(["taskID": "not-a-uuid"]),
                    try encoded(["taskID": UUID().uuidString]), try encoded(["taskID": task.uuidString, "captureAll": true]),
                    try encoded(["taskID": [task.uuidString]]), Data(repeating: 0x20, count: 513),
                    Data("{\"taskID\":\"\(UUID().uuidString)\",\"taskID\":\"\(task.uuidString)\"}".utf8)] {
            let fixture = try Fixture(); defer { fixture.remove() }
            try fixture.writeArm(arm)
            XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task)))
            XCTAssertTrue(fixture.exists(fixture.armFile))
            XCTAssertFalse(fixture.exists(fixture.output))
        }
    }

    func testUTF8LimitPreservesExactBoundaryAndRejectsOverflowBeforeConsumingArm() throws {
        let task = UUID()
        for size in [220_000, 220_001] {
            let fixture = try Fixture(); defer { fixture.remove() }; try fixture.arm(task)
            let reply = String(repeating: "🙂", count: 55_000) + (size == 220_001 ? "x" : "")
            XCTAssertEqual(reply.utf8.count, size)
            let result = WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task, reply: reply))
            XCTAssertEqual(result, size == 220_000)
            if result { XCTAssertEqual(try fixture.record()["replyText"] as? String, reply) }
            else { XCTAssertTrue(fixture.exists(fixture.armFile)); XCTAssertFalse(fixture.exists(fixture.output)) }
        }
    }

    func testUnsafeDirectoryAndArmPermissionsAreRejectedWithoutRepair() throws {
        let task = UUID()
        for (directoryMode, armMode) in [(0o755, 0o600), (0o700, 0o644), (0o700, 0o640), (0o700, 0o400)] {
            let fixture = try Fixture(); defer { fixture.remove() }; try fixture.arm(task)
            try FileManager.default.setAttributes([.posixPermissions: directoryMode], ofItemAtPath: fixture.directory.path)
            try FileManager.default.setAttributes([.posixPermissions: armMode], ofItemAtPath: fixture.armFile.path)
            XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task)))
            XCTAssertEqual(try fixture.permissions(fixture.directory), directoryMode)
            XCTAssertEqual(try fixture.permissions(fixture.armFile), armMode)
            XCTAssertFalse(fixture.exists(fixture.output))
        }
    }

    func testMaximumEscapedReplyAndConcurrentCapturesPublishOneCompleteRecord() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(); try fixture.arm(task)
        let reply = String(repeating: "\u{0}", count: WebModelRejectedReplyCapture.maximumReplyBytes)
        let bytes = try record(task, reply: reply)
        XCTAssertGreaterThan(bytes.count, WebModelRejectedReplyCapture.maximumReplyBytes)
        let results = LockedCaptureResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.add(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: bytes))
        }
        XCTAssertEqual(results.successCount(), 1)
        XCTAssertEqual(try fixture.record()["replyText"] as? String, reply)
        XCTAssertEqual(try Data(contentsOf: fixture.output), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["rejected-reply.json"])
        XCTAssertFalse(fixture.exists(fixture.armFile))
    }

    func testSymlinkedDirectoryAncestorArmAndOutputAreRejected() throws {
        let task = UUID()
        for kind in ["directory", "ancestor", "arm", "output"] {
            let fixture = try Fixture(); defer { fixture.remove() }; try fixture.arm(task)
            var captureDirectory = fixture.directory
            let link = fixture.root.appendingPathComponent("linked")
            if kind == "directory" {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
                captureDirectory = link
            } else if kind == "ancestor" {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
                captureDirectory = link.appendingPathComponent("diagnostics")
            } else {
                let target = fixture.root.appendingPathComponent("external.json")
                try fixture.writeArm(try encoded(["taskID": task.uuidString]), to: target)
                let path = kind == "arm" ? fixture.armFile : fixture.output
                if kind == "arm" { try FileManager.default.removeItem(at: path) }
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            }
            XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: captureDirectory, taskID: task, record: try record(task)))
            XCTAssertTrue(fixture.exists(fixture.armFile))
            if kind == "arm" || kind == "output" {
                XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("external.json")), try encoded(["taskID": task.uuidString]))
            }
        }
    }

    func testHardLinkedArmAndNonRegularArmDoNotAuthorizeCaptureOrBlock() throws {
        let task = UUID()
        for kind in ["hardlink", "fifo", "directory"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            if kind == "hardlink" {
                try fixture.arm(task)
                XCTAssertEqual(link(fixture.armFile.path, fixture.root.appendingPathComponent("arm-alias").path), 0)
            } else if kind == "fifo" { XCTAssertEqual(mkfifo(fixture.armFile.path, 0o600), 0) }
            else { try FileManager.default.createDirectory(at: fixture.armFile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let start = ContinuousClock.now
            XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task)))
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
            XCTAssertFalse(fixture.exists(fixture.output))
        }
    }

    func testExistingRecordAndAbsentDirectoryAreNeverReplacedOrCreated() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(); try fixture.arm(task)
        let prior = Data("previous private evidence".utf8)
        try fixture.writeArm(prior, to: fixture.output)
        XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task)))
        XCTAssertEqual(try Data(contentsOf: fixture.output), prior)
        XCTAssertTrue(fixture.exists(fixture.armFile))
        let missing = fixture.root.appendingPathComponent("not-provisioned")
        XCTAssertFalse(WebModelRejectedReplyCapture.capture(directory: missing, taskID: task, record: try record(task)))
        XCTAssertFalse(fixture.exists(missing))
    }

    func testUnsafeCapturePreservesOriginalMalformedErrorAndOneSend() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(); try fixture.arm(task)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.armFile.path)
        let transport = RejectedReplyTransport(reply: "original invalid reply {")
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self, rejectedReplyDirectory: fixture.directory)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        await assertMalformed(server, task: task)
        XCTAssertFalse(fixture.exists(fixture.output))
        let operations = await transport.operations()
        XCTAssertEqual(operations.filter { $0 == "webProviderSend" }.count, 1)
        _ = await server.shutdown()
    }

    func testArmReplacementDuringClaimIsPreservedAndCannotAuthorizeCapture() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), replacement = UUID(); try fixture.arm(task)
        let captured = WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task), beforeArmClaimForTesting: {
            do { try FileManager.default.removeItem(at: fixture.armFile); try fixture.arm(replacement) }
            catch { XCTFail("Could not establish deterministic arm replacement: \(error)") }
        })
        XCTAssertFalse(captured)
        XCTAssertFalse(fixture.exists(fixture.output))
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.armFile)) as? [String: String])
        XCTAssertEqual(restored, ["taskID": replacement.uuidString.lowercased()])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["arm.json"])
    }

    func testSameInodeArmRewriteWithRestoredMtimeIsPreservedAndRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let task = UUID(), replacement = UUID(); try fixture.arm(task)
        let replacementBytes = try encoded(["taskID": replacement.uuidString.lowercased()])
        let captured = WebModelRejectedReplyCapture.capture(directory: fixture.directory, taskID: task, record: try record(task), beforeArmClaimForTesting: {
            let descriptor = open(fixture.armFile.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { XCTFail("Could not open deterministic same-inode rewrite"); return }
            defer { close(descriptor) }
            var original = stat()
            guard fstat(descriptor, &original) == 0 else { XCTFail("Could not inspect arm before rewriting"); return }
            XCTAssertEqual(ftruncate(descriptor, 0), 0)
            let count = replacementBytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            XCTAssertEqual(count, replacementBytes.count)
            let times = [original.st_atimespec, original.st_mtimespec]
            XCTAssertEqual(times.withUnsafeBufferPointer { futimens(descriptor, $0.baseAddress) }, 0)
        })
        XCTAssertFalse(captured)
        XCTAssertFalse(fixture.exists(fixture.output))
        XCTAssertEqual(try Data(contentsOf: fixture.armFile), replacementBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["arm.json"])
    }

    private var request: Data {
        Data(#"{"model":"browser/claude","input":"request-only-secret","tools":[],"stream":false}"#.utf8)
    }

    private func assertMalformed(_ server: WebModelServer, task: UUID, thread: UUID? = nil) async {
        do { _ = try await server.fixtureInfer(request, taskID: task.uuidString, threadID: thread?.uuidString); XCTFail("A malformed reply must remain rejected") }
        catch {
            guard case let .malformedReply(diagnostic) = error as? WebModelServer.Failure else { XCTFail("Original malformed failure must survive capture: \(error)"); return }
            XCTAssertEqual(diagnostic.reason, .invalidJSON)
        }
    }

    private func encoded(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func record(_ task: UUID, reply: String = "invalid rejected text") throws -> Data {
        try encoded(["taskID": task.uuidString.lowercased(), "replyText": reply])
    }

    private struct Fixture {
        let root: URL
        var directory: URL { root.appendingPathComponent("diagnostics") }
        var armFile: URL { directory.appendingPathComponent("arm.json") }
        var output: URL { directory.appendingPathComponent("rejected-reply.json") }
        init() throws {
            // Foundation canonicalizes /private/var back to its /var alias on
            // macOS. Use the actual POSIX path to test the no-symlink contract.
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
            defer { free(resolved) }
            root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent("ComputaRejectedReply-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func arm(_ task: UUID) throws { try writeArm(JSONSerialization.data(withJSONObject: ["taskID": task.uuidString.lowercased()])) }
        func writeArm(_ bytes: Data, to url: URL? = nil) throws {
            let path = url ?? armFile
            guard FileManager.default.createFile(atPath: path.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        func permissions(_ url: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue }
        func record() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor RejectedReplyTransport: WebModelTransport {
    let reply: String
    let codeStructure: Data?
    private var token = UUID().uuidString
    private var calls: [String] = []
    init(reply: String, codeStructure: Data? = nil) { self.reply = reply; self.codeStructure = codeStructure }
    func operations() -> [String] { calls }
    func request(operation: String, params: Data) async throws -> Data {
        calls.append(operation)
        var value: [String: Any] = ["sessionToken": token]
        switch operation {
        case "webProviderStart": token = UUID().uuidString; value["sessionToken"] = token; value["state"] = "ready"
        case "webProviderSend": value["state"] = "running"
        case "webProviderPoll":
            value["state"] = "complete"; value["text"] = reply; value["sequence"] = 1
            if let codeStructure {
                value["completionEvidence"] = ["codeStructure": try JSONSerialization.jsonObject(with: codeStructure)]
                break
            }
            value["completionEvidence"] = ["codeStructure": ["preCount": 0, "codeCount": 0, "outsideTruncated": false,
                "literalCodeValidJSON": NSNull(), "literalCodeKnownEnvelopeType": NSNull(), "selectedExtraction": "rendered_fallback",
                "extractionReason": "missing_pre", "codeTextLength": -1, "outsideTextLength": 220_002,
                "outsideNodes": [["text": "metadata-content-secret"]], "classes": ["metadata-content-secret"], "unknown": "metadata-content-secret"]]
        case "webProviderFinish", "webProviderCancel": value["state"] = "finished"; value["cleanup"] = "not_created"
        default: throw CocoaError(.featureUnsupported)
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(value))
    }
}

// Mutate only after the fixture has supplied its normal proof, so it cannot
// repair the deliberately invalid completed snapshot before the server sees it.
private struct RejectedReplySnapshotMutationTransport: WebModelTransport {
    enum Mutation: CaseIterable, Sendable { case oppositeStartPolicy, missingText, nonStringText, invalidProof, invalidModel }
    let base: any WebModelTransport
    let mutation: Mutation
    func start(params: Data, admission: WebModelStartAdmission,
               authorization: ChatGPTRequestMetadataLease?) async throws -> Data {
        let bytes = try await base.start(params: params, admission: admission, authorization: authorization)
        guard mutation == .oppositeStartPolicy else { return bytes }
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        if admission.retainClaudeTurn {
            snapshot.removeValue(forKey: "turnContinuationCapability")
            snapshot["freshSessionSubmissionCapability"] = "fresh_session_submission_v1"
        } else {
            snapshot.removeValue(forKey: "freshSessionSubmissionCapability")
            snapshot["turnContinuationCapability"] = "per_submission_ownership_v1"
        }
        return try JSONSerialization.data(withJSONObject: snapshot)
    }

    func request(operation: String, params: Data) async throws -> Data {
        let bytes = try await base.request(operation: operation, params: params)
        guard operation == "webProviderPoll",
              var snapshot = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              snapshot["state"] as? String == "complete" else { return bytes }
        switch mutation {
        case .oppositeStartPolicy: return bytes
        case .missingText: snapshot.removeValue(forKey: "text")
        case .nonStringText: snapshot["text"] = 42
        case .invalidProof:
            var context = snapshot["modelProofContext"] as? [String: Any] ?? [:]
            context["firstUserFingerprint"] = "invalid"
            snapshot["modelProofContext"] = context
        case .invalidModel: snapshot.removeValue(forKey: "modelEvidence")
        }
        return try JSONSerialization.data(withJSONObject: snapshot)
    }
}

private final class LockedCaptureResults: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    func add(_ result: Bool) { lock.lock(); defer { lock.unlock() }; if result { successes += 1 } }
    func successCount() -> Int { lock.lock(); defer { lock.unlock() }; return successes }
}

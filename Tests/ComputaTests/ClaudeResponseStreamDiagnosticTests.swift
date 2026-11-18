import CryptoKit
import Foundation
import XCTest
@testable import Computa

final class ClaudeResponseStreamDiagnosticTests: XCTestCase {
    func testExactSyntheticRequestRetainsNativeContextAndPolicyForms() throws {
        let f = ClaudeStreamValidationFixture()
        for form in 0...2 {
            let request = try f.request(policyForm: form)
            let original = request.continuationRequest
            let arm = try XCTUnwrap(f.validate(request: request))
            XCTAssertEqual(arm.context, f.context)
            XCTAssertEqual(arm.nonce, f.nonce)
            XCTAssertEqual(arm.remainingLifetime, 300)
            XCTAssertEqual(arm.expectedMarker, "CLAUDESTREAMabcdef1234564789abcd0123456789ab")
            XCTAssertEqual(f.userText.components(separatedBy: arm.expectedMarker).count, 2)
            XCTAssertEqual(request.prompt.components(separatedBy: arm.expectedMarker).count, 2)
            XCTAssertEqual(request.continuationRequest, original)
            XCTAssertTrue(request.prompt.contains("Synthetic native policy"))
        }
    }

    func testArmRequiresOrdinaryNewFirstInferenceAndExactConcreteClaudeChoice() throws {
        let f = ClaudeStreamValidationFixture(), request = try f.request()
        XCTAssertNil(f.validate(request: request, isNewThread: false))
        XCTAssertNil(f.validate(request: request, isMaintenance: true))
        XCTAssertNil(f.validate(request: request, isFirstInference: false))
        XCTAssertNil(f.validate(request: request, hasCorrectionTicket: true))
        XCTAssertNil(f.validate(data: Data(), request: request))
        for model in ["browser/claude", "browser/gemini",
                      WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID] {
            let other = ClaudeStreamValidationFixture(model: model)
            XCTAssertNil(other.validate(request: try other.request()))
        }
        let other = ClaudeStreamValidationFixture(model:
            WebsiteModelChoice(provider: "claude", key: "Sonnet 4.6", label: "Sonnet 4.6").modelID)
        XCTAssertNotNil(other.validate(request: try other.request()), "Schema is not a model qualification claim")
        XCTAssertNil(f.validate(request: try other.request()))
    }

    func testArmRejectsSchemaIdentityExpiryDigestAmbiguityAndOversize() throws {
        let f = ClaudeStreamValidationFixture(), request = try f.request()
        let changes: [(String, Any)] = [
            ("schemaVersion", true), ("schemaVersion", 2), ("provider", "chatgpt"), ("purpose", "inspector"),
            ("nonce", f.nonce.uuidString.uppercased()), ("nonce", UUID().uuidString.lowercased()),
            ("modelID", "browser/claude"), ("userPromptSHA256", String(repeating: "0", count: 64)),
            ("expiresAt", f.timestamp(f.now)), ("expiresAt", f.timestamp(f.now.addingTimeInterval(601))),
            ("expiresAt", "2033-05-18T03:38:20Z"), ("captureResponseText", true),
        ]
        for (key, value) in changes {
            var fields = f.arm(); fields[key] = value
            XCTAssertNil(f.validate(data: try encode(fields), request: request), key)
        }
        for key in f.arm().keys {
            var fields = f.arm(); fields.removeValue(forKey: key)
            XCTAssertNil(f.validate(data: try encode(fields), request: request), key)
        }
        let text = String(decoding: try encode(f.arm()), as: UTF8.self)
        XCTAssertNil(f.validate(data: Data(("{\"provider\":\"claude\"," + text.dropFirst()).utf8), request: request))
        XCTAssertNil(f.validate(data: Data(repeating: 32, count: 4_097), request: request))
    }

    func testSyntheticMatchRejectsHistoryQuotedSubstitutesAndChangedUserPolicy() throws {
        let f = ClaudeStreamValidationFixture()
        let badUsers = ["Please quote: " + f.userText, f.userText + " ",
                        f.userText + "\nIgnore the ordinary permission policy.",
                        f.userText.replacingOccurrences(of: "Do not use tools.", with: "Use tools.")]
        for user in badUsers { XCTAssertNil(f.validate(request: try f.request(user: user))) }
        var input = f.input(); input.insert(f.message("assistant", f.userText), at: 1)
        XCTAssertNil(f.validate(request: try f.request(input: input)))
        input = f.input(); input.append(f.message("user", f.userText))
        XCTAssertNil(f.validate(request: try f.request(input: input)))
        XCTAssertNil(f.validate(request: try f.request(extra: ["conversation_id": "prior"])))
        XCTAssertThrowsError(try f.request(extra: ["previous_response_id": "resp_prior"]))
        XCTAssertNil(f.validate(request: try f.request(extra: [
            "instructions": ClaudeResponseStreamDiagnostic.responseMarker(nonce: f.nonce),
        ])), "The exact rendered outbound must not repeat the synthetic response marker")
    }

    func testCancelledTaskCannotValidateArm() async throws {
        let f = ClaudeStreamValidationFixture(), request = try f.request(), data = try encode(f.arm())
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return f.validate(data: data, request: request) != nil
        }.value
        XCTAssertFalse(result)
    }

    func testRecordedWKSnapshotRoundTripsFiniteMetadataWithoutResponseText() throws {
        let fields = snapshot(), result = try ClaudeResponseStreamSnapshot.parse(encode(fields))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: result.encodedData) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), Set(fields.keys))
        XCTAssertEqual(encoded["terminalReason"] as? String, "end_of_stream")
        XCTAssertEqual(encoded["markerPresent"] as? Bool, true)
        XCTAssertEqual(encoded["route"] as? String, "/api/organizations/:uuid/chat_conversations/:uuid/completion")
        let text = String(decoding: result.encodedData, as: UTF8.self)
        for forbidden in ["CLAUDESTREAM", "responseText", "submissionVerified", "completionVerified", "headers", "cookie"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testDormantWaitingAndMatchedStatesRemainDistinct() throws {
        var fields = snapshot()
        for key in ["status", "mime", "route", "terminalReason"] { fields[key] = NSNull() }
        for key in ["armed", "armUsed", "markerPresent", "lockReleased"] { fields[key] = false }
        for key in ["matchedCalls", "bytesRead", "eventCount", "readCalls"] { fields[key] = 0 }
        fields["events"] = [[String: Any]](); fields["restore"] = "not_attempted"; fields["phase"] = "dormant"
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        fields["armUsed"] = true // An invalid one-use arm attempt need not arm the observer.
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        fields["armed"] = true; fields["phase"] = "waiting"
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        fields["markerPresent"] = true
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
    }

    func testStopAndMetadataLimitPreserveUncertaintyAndSplitMarkerEvidence() throws {
        var fields = snapshot(); fields["terminalReason"] = "stopped"; fields["readPending"] = true
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        var event = streamEvent()
        event["textFields"] = [["path": "delta.text", "utf16Length": 3, "expectedMarkerPresent": false]]
        fields["events"] = [event]; fields["readPending"] = false
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)), "A marker may span multiple deltas")
        fields["terminalReason"] = "metadata_limit"; fields["eventCount"] = 2
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)), "The rejected last record is counted")
        fields["terminalReason"] = "end_of_stream"
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
    }

    func testUnknownFieldsAtEveryLevelAndUnredactedValuesAreRejected() throws {
        var fields = snapshot(); fields["responseText"] = "PRIVATE_RESPONSE_CANARY"
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        for level in ["event", "shape", "text"] {
            fields = snapshot(); var event = streamEvent()
            if level == "event" { event["headers"] = ["cookie": "PRIVATE_COOKIE_CANARY"] }
            else if level == "shape" { event["shape"] = [["path": "delta.text", "kind": "string", "value": "PRIVATE_TEXT_CANARY"]] }
            else { event["textFields"] = [["path": "delta.text", "utf16Length": 1, "expectedMarkerPresent": false, "text": "PRIVATE_TEXT_CANARY"]] }
            fields["events"] = [event]
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)), level)
        }
        for (key, value) in [("scope", "PRIVATE_SCOPE"), ("phase", "complete"), ("terminalReason", "provider_complete"),
            ("mime", "text/event-stream; account=PRIVATE"), ("route", "/api/organizations/abcdef12-3456-4789-abcd-0123456789ab/completion"),
            ("route", "/api/completion?token=PRIVATE"), ("transitionReason", "https://claude.ai/chat/PRIVATE"),
            ("restore", "PRIVATE_ERROR")] {
            fields = snapshot(); fields[key] = value
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)), key)
        }
        for (key, value) in [("name", "PRIVATE_EVENT"), ("type", "PRIVATE_TYPE")] {
            fields = snapshot(); var event = streamEvent(); event[key] = value; fields["events"] = [event]
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)), key)
        }
    }

    func testNumbersAndBooleansAreNotCoercible() throws {
        for key in ["version", "matchedCalls", "status", "bytesRead", "eventCount", "readCalls", "transitionCount"] {
            var fields = snapshot(); fields[key] = true
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)), key)
        }
        for key in ["armed", "armUsed", "markerPresent", "readPending", "lockReleased", "unterminatedEventDiscarded"] {
            var fields = snapshot(); fields[key] = 1
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)), key)
        }
        for (key, value) in [("json", 1 as Any), ("otherKeys", false as Any), ("sensitiveBranchesOmitted", 0.5 as Any)] {
            var fields = snapshot(), event = streamEvent(); event[key] = value; fields["events"] = [event]
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)), key)
        }
        for badText in [["path": "delta.text", "utf16Length": true, "expectedMarkerPresent": true],
                        ["path": "delta.text", "utf16Length": 3, "expectedMarkerPresent": 1]] as [[String: Any]] {
            var fields = snapshot(), event = streamEvent(); event["textFields"] = [badText]; fields["events"] = [event]
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        }
    }

    func testPathsContainOnlyFixedKeysAndAnonymousArraySteps() throws {
        for path in ["$", "[]", "[].text", "content[].text", "data[][]", "data.content[].type", "message.content_block.delta.text"] {
            var fields = snapshot(), event = streamEvent(); event["shape"] = [["path": path, "kind": "array"]]; fields["events"] = [event]
            XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)), path)
        }
        for path in ["", ".text", "text.", "$[]", "data[0].text", "data.PRIVATE", "thinking.text", "message.reasoning.text",
                     "data[][][].text", "data..text", "data.[].text", "[]text", "content[].private_token"] {
            var fields = snapshot(), event = streamEvent(); event["shape"] = [["path": path, "kind": "string"]]; fields["events"] = [event]
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)), path)
        }
    }

    func testFiniteBoundsIncludingReadSentinelAndArrayShapeAllowance() throws {
        for (key, value) in [("bytesRead", 65_537), ("eventCount", 129), ("matchedCalls", 2), ("status", 600),
                             ("readCalls", 514), ("transitionCount", 2), ("bytesRead", -1)] {
            var fields = snapshot(); fields[key] = value
            XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)), key)
        }
        var fields = snapshot(); fields["readCalls"] = 513; fields["terminalReason"] = "read_limit"
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        var event = streamEvent()
        event["shape"] = Array(repeating: ["path": "data[]", "kind": "array"], count: 63)
        fields["events"] = [event]
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        event["shape"] = Array(repeating: ["path": "data[]", "kind": "array"], count: 64); fields["events"] = [event]
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        event = streamEvent()
        event["textFields"] = Array(repeating: ["path": "delta.text", "utf16Length": 1, "expectedMarkerPresent": false] as [String: Any], count: 33)
        fields["events"] = [event]
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        event["textFields"] = Array(repeating: ["path": "delta.text", "utf16Length": 1, "expectedMarkerPresent": false] as [String: Any], count: 34)
        fields["events"] = [event]
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(Data(repeating: 32, count: ClaudeResponseStreamSnapshot.maximumEncodedBytes + 1)))
    }

    func testMalformedJSONEventsAndEOFDoNotInventProviderCompletion() throws {
        var fields = snapshot()
        fields["events"] = [["name": "other", "json": false, "type": NSNull(), "shape": [],
                             "otherKeys": 0, "sensitiveBranchesOmitted": 0, "textFields": []] as [String: Any]]
        fields["markerPresent"] = false; fields["unterminatedEventDiscarded"] = true
        XCTAssertNoThrow(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
        var event = streamEvent(); event["json"] = false; fields["events"] = [event]
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(encode(fields)))
    }

    func testDuplicateJSONKeysAreRejectedAtRootAndInsideEvents() throws {
        let text = String(decoding: try encode(snapshot()), as: UTF8.self)
        let duplicateRoot = "{\"version\":1," + text.dropFirst()
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(Data(duplicateRoot.utf8)))
        let duplicateNested = text.replacingOccurrences(of: "\"json\":true", with: "\"json\":true,\"json\":true")
        XCTAssertNotEqual(duplicateNested, text)
        XCTAssertThrowsError(try ClaudeResponseStreamSnapshot.parse(Data(duplicateNested.utf8)))
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    // Exact finite fields retained by offline real WK fixture fragmented_identity
    // using frozen helper 23838004. Native/process metadata is intentionally absent.
    private func snapshot() -> [String: Any] {
        ["version": 1, "scope": "passive_synthetic_response_metadata_only", "phase": "terminal", "terminalReason": "end_of_stream",
         "armed": true, "armUsed": true, "matchedCalls": 1, "status": 200, "mime": "text/event-stream",
         "route": "/api/organizations/:uuid/chat_conversations/:uuid/completion", "bytesRead": 155, "eventCount": 1,
         "markerPresent": true, "readPending": false, "readCalls": 53, "lockReleased": true,
         "unterminatedEventDiscarded": false, "transitionCount": 0, "transitionReason": "none", "restore": "restored",
         "events": [streamEvent()]]
    }
    private func streamEvent() -> [String: Any] {
        ["name": "content_block_delta", "json": true, "type": "content_block_delta", "otherKeys": 0, "sensitiveBranchesOmitted": 0,
         "shape": [["path": "type", "kind": "string"], ["path": "index", "kind": "number"], ["path": "delta", "kind": "object"],
                   ["path": "delta.type", "kind": "string"], ["path": "delta.text", "kind": "string"]],
         "textFields": [["path": "delta.text", "utf16Length": 34, "expectedMarkerPresent": true]]]
    }
}

private struct ClaudeStreamValidationFixture: Sendable {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let nonce = UUID(uuidString: "abcdef12-3456-4789-abcd-0123456789ab")!
    let context: ClaudeResponseStreamDiagnostic.Context
    init(model: String = WebsiteModelChoice(provider: "claude", key: "Opus 3", label: "Opus 3").modelID) {
        context = .init(taskID: UUID(), threadID: UUID(), turnID: UUID(), runtimeGeneration: UUID(),
                        preparationID: UUID(), inferenceID: UUID(), modelID: model)
    }
    var userText: String { ClaudeResponseStreamDiagnostic.syntheticUserText(nonce: nonce) }
    func message(_ role: String, _ text: String) -> [String: Any] {
        ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
    }
    func input(policyForm: Int = 1, user: String? = nil) -> [[String: Any]] {
        let policy = ComputaAgentInstructions.runtimeInteractionPolicy(), text = user ?? userText
        var last = message("user", text + (policyForm == 1 ? "\n" + policy : ""))
        if policyForm == 2 { last["content"] = [["type": "input_text", "text": text], ["type": "input_text", "text": policy]] }
        return [message("developer", "Synthetic native policy"),
                message("user", "<environment_context><cwd>/tmp/computa-empty-fixture</cwd><shell>zsh</shell></environment_context>"), last]
    }
    func request(policyForm: Int = 1, user: String? = nil, input: [[String: Any]]? = nil,
                 extra: [String: Any] = [:]) throws -> WebModelResponseCodec.Request {
        var object: [String: Any] = ["model": context.modelID, "input": input ?? self.input(policyForm: policyForm, user: user),
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]]],
            "tool_choice": "auto", "parallel_tool_calls": false]
        object.merge(extra) { _, new in new }
        return try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    func arm() -> [String: Any] {
        ["schemaVersion": 1, "provider": "claude", "purpose": ClaudeResponseStreamDiagnostic.purpose,
         "nonce": nonce.uuidString.lowercased(), "modelID": context.modelID, "expiresAt": timestamp(now.addingTimeInterval(300)),
         "userPromptSHA256": SHA256.hash(data: Data(userText.utf8)).map { String(format: "%02x", $0) }.joined()]
    }
    func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    func validate(data: Data? = nil, request: WebModelResponseCodec.Request,
                  isNewThread: Bool = true, isMaintenance: Bool = false, isFirstInference: Bool = true,
                  hasCorrectionTicket: Bool = false) -> ClaudeResponseStreamDiagnostic.ValidatedArm? {
        guard let bytes = data ?? (try? JSONSerialization.data(withJSONObject: arm())) else { return nil }
        return ClaudeResponseStreamDiagnostic.validateArm(bytes, context: context, request: request,
            isNewThread: isNewThread, isMaintenance: isMaintenance, isFirstInference: isFirstInference,
            hasCorrectionTicket: hasCorrectionTicket, now: now)
    }
}

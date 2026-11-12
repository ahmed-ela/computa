import CryptoKit
import Foundation
import XCTest
@testable import Computa

final class ClaudeFormatCorrectionTests: XCTestCase {
    private let choice = WebsiteModelChoice(provider: "claude", key: "Sonnet 4.6", label: "Sonnet 4.6")
    private let user: [String: Any] = ["role": "user", "content": "Read the synthetic file and report its observed value."]
    private let valid = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"cat \"/tmp/synthetic fixture.py\"","workdir":"/tmp"}}]}"#
    private var malformed: String { "I need to read the current file before making any edits.\n\n\u{E056}\njson\n" + valid }
    private var duplicateMalformed: String {
        let close = #"{"type":"tool_calls","calls":[{"name":"browser_close","arguments":{}}]}"#
        return "\u{E056}\njson\n" + close + "\nI need to review the observed output first.\n\u{E056}\njson\n" + close
    }

    private var isolatedMalformed: String {
        "\u{E056}\njson\n" + #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf rejected-one"}}},{"name":"exec_command","arguments":{"cmd":"printf rejected-two"}}},{"name":"exec_command","arguments":{"cmd":"printf rejected-three"}}]}"#
    }

    private var rejectedShape: [String: Any] {
        ["preCount": 2, "codeCount": 2, "codeTextLength": 0, "outsideTextLength": 4_086,
         "outsideTruncated": false, "preParentTags": ["div"], "literalCodeValidJSON": NSNull(),
         "repeatedIdenticalToolCalls": false, "isolatedJSONCodeBlock": NSNull(),
         "literalCodeKnownEnvelopeType": NSNull(), "selectedExtraction": "rendered_fallback",
         "extractionReason": "multiple_pre"]
    }

    private func rejectionEvent(_ structure: [String: Any], provider: String = "claude",
                                ownership: Bool = true, model: Bool = true,
                                state: String = "complete", bytes: Int = 4_086) -> String? {
        WebModelServer.claudeMalformedReplyShapeDiagnostic(provider: provider, ownershipVerified: ownership,
            modelVerified: model, inferenceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            diagnostic: .init(reason: .invalidJSON, utf8Bytes: bytes, fenced: false),
            snapshot: ["state": state, "text": "PRIVATE_REPLY_CANARY",
                       "completionEvidence": ["codeStructure": structure]])
    }

    func testClaudeRejectedShapeKeepsDecisionFieldsBelowLogLimitWithoutAncestryOrContent() throws {
        var structure = rejectedShape
        let parent: [String: Any] = ["tag": "private-element", "classes": Array(repeating: "PRIVATE_CLASS_CANARY", count: 6),
            "preDescendants": 2, "copyControls": 2]
        structure["outsideNodes"] = Array(repeating: ["kind": "other", "textLength": 70,
            "text": "PRIVATE_NODE_CANARY", "ancestors": Array(repeating: parent, count: 4)] as [String: Any], count: 2)
        structure["replyText"] = "PRIVATE_EXTRA_CANARY"
        let full = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedCodeStructure(structure))
        XCTAssertGreaterThan(full.utf8.count, 1_024, "Reproduce the observed unified-log truncation risk")
        let event = try XCTUnwrap(rejectionEvent(structure))
        XCTAssertLessThanOrEqual(event.utf8.count, 768)
        XCTAssertTrue(event.hasPrefix("claudeRejectedReplyShape "))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.dropFirst("claudeRejectedReplyShape ".count).utf8)) as? [String: Any])
        var expected = rejectedShape
        expected.removeValue(forKey: "preParentTags")
        expected.merge(["version": 1, "inference": "00000000-0000-4000-8000-000000000001",
                        "reason": "invalid_json", "replyBytes": 4_086, "jsonFenced": false]) { _, new in new }
        XCTAssertEqual(fields as NSDictionary, expected as NSDictionary)
        for omitted in ["PRIVATE", "private-element", "outsideNodes", "ancestors", "classes", "preParentTags", "replyText"] {
            XCTAssertFalse(event.contains(omitted), omitted)
        }
        XCTAssertEqual(rejectionEvent(structure), event, "Projection is deterministic and does not mutate evidence")
        XCTAssertEqual(structure["replyText"] as? String, "PRIVATE_EXTRA_CANARY")
    }

    func testClaudeRejectedShapeRequiresCurrentVerifiedClaudeCompletionAndFiniteStructure() throws {
        for provider in ["chatgpt", "groq", "claude ", "Claude"] { XCTAssertNil(rejectionEvent(rejectedShape, provider: provider)) }
        XCTAssertNil(rejectionEvent(rejectedShape, ownership: false))
        XCTAssertNil(rejectionEvent(rejectedShape, model: false))
        XCTAssertNil(rejectionEvent(rejectedShape, state: "running"))
        XCTAssertNil(rejectionEvent(rejectedShape, bytes: -1))
        XCTAssertNil(rejectionEvent(rejectedShape, bytes: WebModelRejectedReplyCapture.maximumReplyBytes + 1))
        XCTAssertNil(rejectionEvent([:]))
        let invalid: [(String, Any)] = [("kind", "groq_literal_profile_v1"), ("preCount", true),
            ("codeCount", 1_001), ("outsideTextLength", 220_002), ("outsideTruncated", 0),
            ("literalCodeValidJSON", 1), ("repeatedIdenticalToolCalls", "false"), ("isolatedJSONCodeBlock", 0),
            ("literalCodeKnownEnvelopeType", "PRIVATE_TYPE"), ("selectedExtraction", "PRIVATE_EXTRACTION"),
            ("extractionReason", "PRIVATE_REASON")]
        for (key, value) in invalid {
            var structure = rejectedShape; structure[key] = value
            XCTAssertNil(rejectionEvent(structure), key)
        }
    }

    func testClaudeRejectedShapePreservesBooleanNullAndAbsentFactsAndWorstCaseBound() throws {
        let keys = ["literalCodeValidJSON", "repeatedIdenticalToolCalls", "isolatedJSONCodeBlock"]
        for value in [true, false, NSNull()] as [Any] {
            var structure = rejectedShape
            structure["preCount"] = 1_000; structure["codeCount"] = 1_000
            structure["codeTextLength"] = 220_001; structure["outsideTextLength"] = 220_001
            structure["literalCodeKnownEnvelopeType"] = "tool_calls"
            structure["extractionReason"] = "unknown_envelope_type"
            for key in keys { structure[key] = value }
            let event = try XCTUnwrap(rejectionEvent(structure, bytes: WebModelRejectedReplyCapture.maximumReplyBytes))
            XCTAssertLessThanOrEqual(event.utf8.count, 768)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.dropFirst("claudeRejectedReplyShape ".count).utf8)) as? [String: Any])
            for key in keys { XCTAssertEqual(fields[key] as? NSObject, value as? NSObject, key) }
        }
        var historical = rejectedShape
        for key in keys { historical.removeValue(forKey: key) }
        let event = try XCTUnwrap(rejectionEvent(historical))
        for key in keys { XCTAssertFalse(event.contains(key), "Missing evidence must not become false or null") }
    }

    private func request(_ input: [[String: Any]]? = nil, model: String? = nil, toolChoice: String = "auto") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model ?? choice.modelID, "stream": false,
            "input": input ?? [user], "tool_choice": toolChoice,
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object",
                "properties": ["cmd": ["type": "string"], "workdir": ["type": "string"]], "required": ["cmd"]]]]])
    }
    private func server(_ base: FormatCorrectionFixtureTransport, root: URL? = nil,
                        mutation: String? = nil, mutationStart: Int = 1,
                        duplicateReply: String? = nil, isolatedReply: String? = nil,
                        modelChoice: WebsiteModelChoice? = nil) async throws -> WebModelServer {
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
            storageDirectory: try root ?? canonicalFormatCorrectionFixtureRoot())
        await server.configureEmbeddedTransport(ClaudeCorrectionProofFixtureTransport(
            WebsiteInferenceFixtureTransport(base, defaultClaudeChoice: modelChoice ?? choice), mutation: mutation,
            mutationStart: mutationStart, duplicateReply: duplicateReply, isolatedReply: isolatedReply))
        return server
    }
    private func duplicateRequest() throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: request()) as? [String: Any])
        var tools = try XCTUnwrap(value["tools"] as? [[String: Any]])
        tools.append(["type": "function", "name": "browser_close", "parameters": ["type": "object",
            "properties": ["tab_id": ["type": "string"]]]])
        value["tools"] = tools
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func reject(_ server: WebModelServer, input: Data? = nil, task: String,
                        thread: String? = nil, turn: String? = nil) async throws {
        do {
            _ = try await server.fixtureInfer(input ?? request(), taskID: task, threadID: thread, turnID: turn)
            XCTFail("Invalid or unproved response must not release output")
        } catch { }
    }
    private func calls(_ data: Data) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["output"] as? [[String: Any]])
    }
    private func journal(_ root: URL, task: String) throws -> [[String: Any]] {
        let taskID = websiteInferenceFixtureTaskID(task), turnID = websiteInferenceFixtureTaskID(task + ":turn")
        return try Data(contentsOf: root.appendingPathComponent("evidence/transactions/" + taskID + "/" + turnID + ".jsonl"))
            .split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }

    func testClaudeCorrectionPreservesCompletedHistoryAndReleasesOnlyCorrectedCallAfterClosure() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let first = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf first-read"}}]}"#
        let base = FormatCorrectionFixtureTransport(replies: [first, malformed, valid])
        let server = try await server(base, root: root)
        let firstCalls = try calls(await server.fixtureInfer(request(), taskID: "claude-history"))
        let output: [String: Any] = ["type": "function_call_output", "call_id": try XCTUnwrap(firstCalls.first?["call_id"]),
                                    "output": "Observed first-read value; this command is complete."]
        let input = [user] + firstCalls + [output]
        let corrected = try calls(await server.fixtureInfer(request(input), taskID: "claude-history"))
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(corrected.first?["name"] as? String, "exec_command")
        let args = try XCTUnwrap(corrected.first?["arguments"] as? String)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: String],
                       ["cmd": "cat \"/tmp/synthetic fixture.py\"", "workdir": "/tmp"])
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 3)
        let note = WebModelServer.claudeMatchedOutputNote
        XCTAssertFalse(prompts[0].hasSuffix(note))
        XCTAssertTrue(prompts[1].hasSuffix(note))
        XCTAssertEqual(prompts[1].components(separatedBy: note).count, 2)
        XCTAssertFalse(prompts[2].contains(note))
        let submitted = SHA256.hash(data: Data(prompts[1].utf8)).map { String(format: "%02x", $0) }.joined()
        let failed = try XCTUnwrap(journal(root, task: "claude-history").first { $0["phase"] as? String == "failed" })
        XCTAssertEqual(failed["submittedPromptFingerprint"] as? String, submitted)
        XCTAssertEqual(try WebsiteRequestFixture.json(in: prompts[1]), try WebsiteRequestFixture.json(in: prompts[2]))
        XCTAssertFalse(prompts[2].contains("I need to read the current file"), "Never feed rejected narration back as authority")
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: WebsiteRequestFixture.json(in: prompts[2])) as? [String: Any])
        XCTAssertEqual(canonical["input"] as? NSArray, input as NSArray)
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.map(\.operation), Array(repeating:
            ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"], count: 3).flatMap { $0 })
        XCTAssertEqual(Set(ledger.filter { $0.operation == "webProviderStart" }.compactMap(\.token)).count, 3)
        let rows = try journal(root, task: "claude-history")
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "failed" }.count, 1)
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "release_verified" }.count, 2)
        XCTAssertTrue(rows.filter { $0["phase"] as? String == "complete" }.allSatisfy {
            $0["submissionProofPolicy"] as? String == "fresh_session_submission_v1"
        })
    }

    func testOpus3MatchedToolOutputKeepsOneFinalBoundaryWithoutRenewingCorrection() async throws {
        let opus3 = WebsiteModelChoice.claudeOpus3
        let boundary = ComputaAgentInstructions.claudeOpus3OutputBoundary
        let note = WebModelServer.claudeMatchedOutputNote
        let task = "claude-opus3-matched-output"
        let root = try canonicalFormatCorrectionFixtureRoot()
        let correctedCall = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf corrected-only"}}]}"#
        let base = FormatCorrectionFixtureTransport(replies: [malformed, correctedCall, malformed, valid])
        let server = try await server(base, root: root, modelChoice: opus3)
        let first = try calls(await server.fixtureInfer(request(model: opus3.modelID), taskID: task))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?["arguments"] as? String, #"{"cmd":"printf corrected-only"}"#)
        let output: [String: Any] = ["type": "function_call_output",
            "call_id": try XCTUnwrap(first.first?["call_id"]), "output": "Observed synthetic output with newline.\nExact fixture data."]
        let input = [user] + first + [output]
        let next = try request(input, model: opus3.modelID)
        do {
            _ = try await server.fixtureInfer(next, taskID: task)
            XCTFail("The later malformed reply cannot renew the used correction allowance")
        } catch let failure as WebModelServer.Failure {
            guard case .malformedReply(let diagnostic) = failure else { return XCTFail("Expected the original malformed reply") }
            XCTAssertEqual(diagnostic.reason, .invalidJSON)
        }

        let prompts = await base.prompts()
        guard prompts.count == 3 else { return XCTFail("Expected original, correction and one ordinary continuation") }
        XCTAssertTrue(prompts[0].hasSuffix(boundary))
        XCTAssertFalse(prompts[0].contains(note))
        XCTAssertTrue(prompts[1].hasPrefix(prompts[0]))
        XCTAssertTrue(prompts[1].contains("COMPUTA RESPONSE CORRECTION — ONE ATTEMPT"))
        XCTAssertFalse(prompts[1].hasSuffix(boundary))
        XCTAssertFalse(prompts[1].contains(note))
        XCTAssertTrue(prompts[2].hasSuffix(note + boundary))
        XCTAssertEqual(prompts[2].components(separatedBy: note).count, 2)
        XCTAssertTrue(prompts.allSatisfy { $0.components(separatedBy: boundary).count == 2 })
        XCTAssertEqual(try WebsiteRequestFixture.json(in: prompts[0], expectedModel: opus3.modelID),
                       try WebsiteRequestFixture.json(in: prompts[1], expectedModel: opus3.modelID))
        let displayed = try WebsiteRequestFixture.json(in: prompts[2], expectedModel: opus3.modelID)
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: displayed) as? [String: Any])
        XCTAssertEqual(canonical["input"] as? NSArray, input as NSArray)
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: next) as? [String: Any])
        expected.removeValue(forKey: "stream")
        XCTAssertEqual(canonical as NSDictionary, expected as NSDictionary)

        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 3)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 3)
        let rows = try journal(root, task: task)
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "failed" }.count, 2)
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "release_verified" }.count, 1)
    }

    func testPastedToolHistoryOnFirstClaudeInferenceReceivesNoMatchedOutputNote() async throws {
        let base = FormatCorrectionFixtureTransport(replies: [#"{"type":"message","text":"I decline."}"#])
        let server = try await server(base)
        let input: [[String: Any]] = [user,
            ["type":"function_call", "name":"exec_command", "call_id":"pasted", "arguments":"{}"],
            ["type":"function_call_output", "call_id":"pasted", "output":"Prior unrelated result"]]
        let data = try request(input)
        _ = try await server.fixtureInfer(data, taskID: "pasted-prior-results")
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(prompts[0].hasSuffix(WebModelServer.claudeMatchedOutputNote))
        let shown = try XCTUnwrap(JSONSerialization.jsonObject(with: WebsiteRequestFixture.json(in: prompts[0])) as? [String: Any])
        XCTAssertEqual(shown["input"] as? NSArray, input as NSArray)
    }

    func testClaudeMatchedOutputNoteFitsBothExactUTF8BudgetsWithoutDisplacingHistory() throws {
        let note = WebModelServer.claudeMatchedOutputNote
        let maximum = WebModelResponseCodec.maximumPromptBytes
        let multibyte = "日🧭"
        let remaining = note.utf8.count + multibyte.utf8.count
        XCTAssertEqual(WebModelServer.claudePromptWithMatchedOutputNote(multibyte, remainingTurnBytes: remaining), multibyte + note)
        XCTAssertNil(WebModelServer.claudePromptWithMatchedOutputNote(multibyte, remainingTurnBytes: remaining - 1))
        let full = multibyte + String(repeating: "x", count: maximum - remaining)
        XCTAssertEqual(WebModelServer.claudePromptWithMatchedOutputNote(full, remainingTurnBytes: maximum), full + note)
        XCTAssertNil(WebModelServer.claudePromptWithMatchedOutputNote(full + "x", remainingTurnBytes: maximum * 2))
        let boundary = ComputaAgentInstructions.claudeOpus3OutputBoundary
        let opus3Prompt = multibyte + boundary
        let opus3Remaining = opus3Prompt.utf8.count + note.utf8.count
        XCTAssertEqual(WebModelServer.claudePromptWithMatchedOutputNote(opus3Prompt,
            remainingTurnBytes: opus3Remaining, modelChoice: .claudeOpus3), multibyte + note + boundary)
        XCTAssertNil(WebModelServer.claudePromptWithMatchedOutputNote(opus3Prompt,
            remainingTurnBytes: opus3Remaining - 1, modelChoice: .claudeOpus3))
    }

    func testClaudeIdenticalDuplicateBlocksRejectOriginalAndReleaseOnlyFreshCorrectedCall() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let corrected = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf corrected-only"}}]}"#
        let base = FormatCorrectionFixtureTransport(replies: [duplicateMalformed, corrected])
        let server = try await server(base, root: root, duplicateReply: duplicateMalformed)
        let requestBytes = try duplicateRequest()
        let prepared = try WebModelResponseCodec.prepareRequest(requestBytes)
        XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(duplicateMalformed, request: prepared)) {
            XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .malformedEnvelope)
        }
        let output = try calls(await server.fixtureInfer(requestBytes, taskID: "claude-identical-blocks"))
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?["arguments"] as? String, #"{"cmd":"printf corrected-only"}"#)
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(try WebsiteRequestFixture.json(in: prompts[0]), try WebsiteRequestFixture.json(in: prompts[1]))
        XCTAssertFalse(prompts[1].contains("I need to review the observed output first."))
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.map(\.operation), Array(repeating:
            ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"], count: 2).flatMap { $0 })
        let rows = try journal(root, task: "claude-identical-blocks")
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "failed" }.count, 1)
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "release_verified" }.count, 1)
        let rejectedID = rows.first { $0["phase"] as? String == "failed" }?["inferenceID"] as? String
        XCTAssertFalse(rows.contains { $0["inferenceID"] as? String == rejectedID && ["complete", "release_verified"].contains($0["phase"] as? String ?? "") })
    }

    func testClaudeDuplicateCorrectionRequiresStrictEvidenceAndFreshProof() async throws {
        for mutation in ["duplicate_missing", "duplicate_false", "duplicate_null", "duplicate_numeric", "duplicate_string",
                         "duplicate_pre", "duplicate_code", "raw_extraction", "other_reason", "missing", "prompt", "model"] {
            let base = FormatCorrectionFixtureTransport(replies: [duplicateMalformed, valid])
            let server = try await server(base, mutation: mutation, duplicateReply: duplicateMalformed)
            try await reject(server, input: duplicateRequest(), task: "claude-duplicate-evidence-" + mutation)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1, mutation)
            XCTAssertLessThanOrEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1, mutation)
        }
    }

    func testClaudeDuplicateCorrectionAcceptsRefusalAndCannotRequestThirdReply() async throws {
        for refuses in [true, false] {
            let refusal = #"{"type":"message","text":"I cannot perform this request."}"#
            let base = FormatCorrectionFixtureTransport(replies: [duplicateMalformed, refuses ? refusal : duplicateMalformed, valid])
            let server = try await server(base, duplicateReply: duplicateMalformed)
            let task = "claude-duplicate-second-\(refuses)"
            if refuses {
                let response = try calls(await server.fixtureInfer(duplicateRequest(), taskID: task))
                XCTAssertEqual(response.count, 1)
                XCTAssertEqual(response.first?["type"] as? String, "message")
                XCTAssertTrue(String(describing: response).contains("I cannot perform this request."))
            } else { try await reject(server, input: duplicateRequest(), task: task) }
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 2)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, refuses ? 2 : 1)
            if !refuses {
                // infer rejects the second malformed reply without renewing
                // correction. Its terminal session is closed by the task's
                // normal finish path, which fixtureInfer does not invoke.
                let issues = await server.fixtureFinish(taskID: task)
                XCTAssertTrue(issues.isEmpty)
                let secondToken = try XCTUnwrap(ledger.last { $0.operation == "webProviderStart" }?.token)
                let receipts = await server.latestCleanupReceipts()
                XCTAssertTrue(receipts.contains { $0.sessionToken == secondToken && $0.outcome == .closed && $0.receiptSaved })
            }
            let finishedLedger = await base.ledger()
            XCTAssertEqual(finishedLedger.filter { $0.operation == "webProviderFinish" }.count, 2)
            XCTAssertEqual(finishedLedger.filter { $0.operation == "webProviderSend" }.count, 2, "Cleanup cannot request a third response")
        }
    }

    func testClaudeIsolatedMalformedJSONPreservesCompletedHistoryAndCorrectsOnlyOnce() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let first = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf first-read"}}]}"#
        let base = FormatCorrectionFixtureTransport(replies: [first, isolatedMalformed, valid])
        let server = try await server(base, root: root, isolatedReply: isolatedMalformed)
        let firstCalls = try calls(await server.fixtureInfer(request(), taskID: "claude-isolated-history"))
        let output: [String: Any] = ["type": "function_call_output", "call_id": try XCTUnwrap(firstCalls.first?["call_id"]),
                                    "output": "Observed first-read value; this command is complete."]
        let input = [user] + firstCalls + [output]
        let corrected = try calls(await server.fixtureInfer(request(input), taskID: "claude-isolated-history"))
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(corrected.first?["name"] as? String, "exec_command")
        let args = try XCTUnwrap(corrected.first?["arguments"] as? String)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: String],
                       ["cmd": "cat \"/tmp/synthetic fixture.py\"", "workdir": "/tmp"])
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(try WebsiteRequestFixture.json(in: prompts[1]), try WebsiteRequestFixture.json(in: prompts[2]))
        XCTAssertFalse(prompts[2].contains("printf rejected-one"), "Never feed rejected narration back as authority")
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: WebsiteRequestFixture.json(in: prompts[2])) as? [String: Any])
        XCTAssertEqual(canonical["input"] as? NSArray, input as NSArray)
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.map(\.operation), Array(repeating:
            ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"], count: 3).flatMap { $0 })
        XCTAssertEqual(Set(ledger.filter { $0.operation == "webProviderStart" }.compactMap(\.token)).count, 3)
        let rows = try journal(root, task: "claude-isolated-history")
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "failed" }.count, 1)
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "release_verified" }.count, 2)
        XCTAssertTrue(rows.filter { $0["phase"] as? String == "complete" }.allSatisfy {
            $0["submissionProofPolicy"] as? String == "fresh_session_submission_v1"
        })
    }

    func testClaudeIsolatedMalformedJSONRejectsOriginalAndReleasesOnlyFreshCorrectedCall() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let corrected = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf corrected-only"}}]}"#
        let base = FormatCorrectionFixtureTransport(replies: [isolatedMalformed, corrected])
        let server = try await server(base, root: root, isolatedReply: isolatedMalformed)
        let requestBytes = try request()
        let prepared = try WebModelResponseCodec.prepareRequest(requestBytes)
        XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(isolatedMalformed, request: prepared)) {
            XCTAssertEqual($0 as? WebModelResponseCodec.Failure, .malformedEnvelope)
        }
        let output = try calls(await server.fixtureInfer(requestBytes, taskID: "claude-isolated-block"))
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?["arguments"] as? String, #"{"cmd":"printf corrected-only"}"#)
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(try WebsiteRequestFixture.json(in: prompts[0]), try WebsiteRequestFixture.json(in: prompts[1]))
        XCTAssertFalse(prompts[1].contains("printf rejected-one"))
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.map(\.operation), Array(repeating:
            ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"], count: 2).flatMap { $0 })
        let rows = try journal(root, task: "claude-isolated-block")
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "failed" }.count, 1)
        XCTAssertEqual(rows.filter { $0["phase"] as? String == "release_verified" }.count, 1)
        let rejectedID = rows.first { $0["phase"] as? String == "failed" }?["inferenceID"] as? String
        XCTAssertFalse(rows.contains { $0["inferenceID"] as? String == rejectedID && ["complete", "release_verified"].contains($0["phase"] as? String ?? "") })
    }

    func testClaudeIsolatedMalformedJSONRequiresStrictEvidenceAndFreshProof() async throws {
        for mutation in ["isolated_missing", "isolated_false", "isolated_null", "isolated_numeric", "isolated_string",
                         "isolated_array", "isolated_pre", "isolated_code", "isolated_valid", "isolated_valid_numeric", "isolated_reason",
                         "raw_extraction", "missing", "prompt", "model"] {
            let base = FormatCorrectionFixtureTransport(replies: [isolatedMalformed, valid])
            let server = try await server(base, mutation: mutation, isolatedReply: isolatedMalformed)
            try await reject(server, input: request(), task: "claude-isolated-evidence-" + mutation)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1, mutation)
            XCTAssertLessThanOrEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1, mutation)
        }
    }

    func testClaudeIsolatedMalformedJSONCorrectionAcceptsRefusalAndCannotRequestThirdReply() async throws {
        for refuses in [true, false] {
            let refusal = #"{"type":"message","text":"I cannot perform this request."}"#
            let base = FormatCorrectionFixtureTransport(replies: [isolatedMalformed, refuses ? refusal : isolatedMalformed, valid])
            let server = try await server(base, isolatedReply: isolatedMalformed)
            let task = "claude-isolated-second-\(refuses)"
            if refuses {
                let response = try calls(await server.fixtureInfer(request(), taskID: task))
                XCTAssertEqual(response.count, 1)
                XCTAssertEqual(response.first?["type"] as? String, "message")
                XCTAssertTrue(String(describing: response).contains("I cannot perform this request."))
            } else { try await reject(server, input: request(), task: task) }
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 2)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, refuses ? 2 : 1)
            if !refuses {
                // infer rejects the second malformed reply without renewing
                // correction. Its terminal session is closed by the task's
                // normal finish path, which fixtureInfer does not invoke.
                let issues = await server.fixtureFinish(taskID: task)
                XCTAssertTrue(issues.isEmpty)
                let secondToken = try XCTUnwrap(ledger.last { $0.operation == "webProviderStart" }?.token)
                let receipts = await server.latestCleanupReceipts()
                XCTAssertTrue(receipts.contains { $0.sessionToken == secondToken && $0.outcome == .closed && $0.receiptSaved })
            }
            let finishedLedger = await base.ledger()
            XCTAssertEqual(finishedLedger.filter { $0.operation == "webProviderFinish" }.count, 2)
            XCTAssertEqual(finishedLedger.filter { $0.operation == "webProviderSend" }.count, 2, "Cleanup cannot request a third response")
        }
    }

    func testClaudeMissingForeignOrMalformedFreshProofNeverCorrectsOrReleases() async throws {
        for mutation in ["capability", "continuation", "missing", "string", "extra", "token", "document", "sequence",
                         "booleanSequence", "baseline", "count", "firstUser", "prompt", "early", "model", "forged_diagnostic"] {
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
            let server = try await server(base, mutation: mutation)
            try await reject(server, task: "claude-proof-" + mutation)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1, mutation)
            XCTAssertLessThanOrEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1, mutation)
            let receipts = await server.latestCleanupReceipts()
            XCTAssertFalse(receipts.contains { $0.outcome == .closed }, "No successful output release for " + mutation)
        }
    }

    func testClaudeBareProviderRemainsLegacyAndCannotSpendCorrection() async throws {
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let server = try await server(base)
        try await reject(server, input: request(model: "browser/claude"), task: "claude-bare")
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
        let legacy = FormatCorrectionFixtureTransport(replies: [#"{"type":"message","text":"Legacy observed answer"}"#])
        let legacyServer = try await self.server(legacy)
        let result = try await legacyServer.fixtureInfer(request(model: "browser/claude"), taskID: "claude-bare-valid")
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("Legacy observed answer"))
    }

    func testClaudeRefusalRendererSchemaAndUnknownToolsDoNotCorrect() async throws {
        let replies = ["I cannot perform that request.", #"{"type":"tool_calls","calls":[]}"#,
                       #"{"type":"tool_calls","calls":[{"name":"unoffered","arguments":{}}]}"#,
                       #"{"type":"message","text":"Cannot comply with the requested tool policy."}"#]
        for (index, reply) in replies.enumerated() {
            let base = FormatCorrectionFixtureTransport(replies: [reply, valid])
            let server = try await server(base)
            if index == 0 {
                let response = try await server.fixtureInfer(request(), taskID: "claude-nonformat-\(index)")
                XCTAssertTrue(String(decoding: response, as: UTF8.self).contains(reply),
                              "Ordinary prose refusal retains the existing non-action message compatibility")
            } else {
                try await reject(server, input: request(toolChoice: index == 3 ? "required" : "auto"), task: "claude-nonformat-\(index)")
            }
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1, "Only demonstrated formatting failure is eligible")
        }
        let renderer = FormatCorrectionFixtureTransport(replies: [valid], pollFailures: [1: .responseRenderingFailed])
        let renderingServer = try await server(renderer)
        try await reject(renderingServer, task: "claude-renderer")
        let rendererLedger = await renderer.ledger()
        XCTAssertEqual(rendererLedger.filter { $0.operation == "webProviderSend" }.count, 1)
        let refusal = FormatCorrectionFixtureTransport(replies: [#"{"type":"message","text":"I cannot comply with that request."}"#])
        let refusalServer = try await server(refusal)
        let result = try await refusalServer.fixtureInfer(request(), taskID: "claude-refusal")
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("I cannot comply"))
        let refusalLedger = await refusal.ledger()
        XCTAssertEqual(refusalLedger.filter { $0.operation == "webProviderSend" }.count, 1)
    }

    func testClaudeInvalidJSONWithUnqualifiedCodeStructureCannotCorrect() async throws {
        for mutation in ["no_diagnostic", "multiple_pre", "boolean_pre", "numeric_valid", "message_literal", "raw_extraction", "other_reason"] {
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
            let server = try await server(base, mutation: mutation)
            try await reject(server, task: "claude-diagnostic-" + mutation)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1, mutation)
        }
    }

    func testClaudeCorrectionConsumesNormalInferenceBudgetAcrossFreshPages() async throws {
        let base = FormatCorrectionFixtureTransport(replies: [malformed] + Array(repeating: valid, count: 16))
        let server = try await server(base)
        var input = [user]
        for _ in 0..<15 {
            let output = try calls(await server.fixtureInfer(request(input), taskID: "claude-budget"))
            input += output + [["type": "function_call_output", "call_id": try XCTUnwrap(output.first?["call_id"]), "output": "Observed fixture value"]]
        }
        do { _ = try await server.fixtureInfer(request(input), taskID: "claude-budget"); XCTFail("Correction must consume its ordinary inference slot") }
        catch { guard case .turnLimit = error as? WebModelServer.Failure else { return XCTFail("Expected unchanged turn budget") } }
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 16)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 16)
        let prompts = await base.prompts()
        XCTAssertGreaterThan(prompts[1].utf8.count, prompts[0].utf8.count, "Charge the correction reminder as actual prompt bytes")
        XCTAssertLessThanOrEqual(prompts.reduce(0) { $0 + $1.utf8.count }, WebModelServer.maximumTurnPromptUTF8Bytes)
    }

    func testClaudeCorrectionRequiresClosedSavedOriginalAndCurrentTransport() async throws {
        for kind in ["close", "save", "transport"] {
            let root = try canonicalFormatCorrectionFixtureRoot()
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid], cleanupFails: kind == "close")
            let server = try await server(base, root: root)
            if kind == "save" {
                await base.setFirstFinishHook {
                    let directory = root.appendingPathComponent("cleanup")
                    try? FileManager.default.removeItem(at: directory)
                    try? Data("unavailable".utf8).write(to: directory)
                }
            } else if kind == "transport" {
                await base.setFirstFinishHook {
                    await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(
                        FormatCorrectionFixtureTransport(replies: []),
                        defaultClaudeChoice: WebsiteModelChoice(provider: "claude", key: "Sonnet 4.6", label: "Sonnet 4.6")))
                }
            }
            try await reject(server, task: "claude-barrier-" + kind)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1, kind)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1, kind)
        }
    }

    func testClaudeCorrectionDeadlineIncludesFirstSendCleanupAndSecondStart() async throws {
        for phase in ["send", "cleanup", "start"] {
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid],
                cleanupDelay: phase == "cleanup" ? .milliseconds(100) : .zero,
                firstSendDelay: phase == "send" ? .milliseconds(100) : .zero,
                secondStartDelay: phase == "start" ? .milliseconds(100) : .zero)
            let server = try await server(base)
            await server.setTimeoutsForTesting(readiness: .seconds(1), response: .milliseconds(50))
            try await reject(server, task: "claude-deadline-" + phase)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1, phase)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, phase == "start" ? 2 : 1, phase)
        }
    }

    func testClaudeOrdinaryNextRoundHasFreshDeadlineButSecondMalformedResponseCannotRetry() async throws {
        let base = FormatCorrectionFixtureTransport(replies: [valid, malformed, malformed, valid])
        let server = try await server(base)
        await server.setTimeoutsForTesting(readiness: .seconds(1), response: .milliseconds(200))
        let first = try calls(await server.fixtureInfer(request(), taskID: "claude-deadline-round"))
        try await Task.sleep(for: .milliseconds(250))
        let input = [user] + first + [["type": "function_call_output", "call_id": try XCTUnwrap(first.first?["call_id"]), "output": "Observed value"]]
        try await reject(server, input: request(input), task: "claude-deadline-round")
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 3,
                       "An ordinary round gets its own deadline, but its malformed correction cannot renew the one-shot claim")
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 3)
    }

    func testClaudeSecondAttemptRequiresSameModelAndExactFreshProof() async throws {
        for mutation in ["model", "prompt", "missing", "continuation"] {
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
            let server = try await server(base, mutation: mutation, mutationStart: 2)
            try await reject(server, task: "claude-second-" + mutation)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 2)
            XCTAssertLessThanOrEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 2)
        }
    }

    func testClaudeCorrectionDoesNotRenewClaimAfterSubsequentRoundOrRestart() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid, malformed, valid])
        let server = try await server(base, root: root)
        let first = try calls(await server.fixtureInfer(request(), taskID: "claude-once", threadID: "same-thread", turnID: "same-turn"))
        let input = [user] + first + [["type": "function_call_output", "call_id": try XCTUnwrap(first.first?["call_id"]), "output": "Observed value"]]
        try await reject(server, input: request(input), task: "claude-once", thread: "same-thread", turn: "same-turn")
        let before = await base.ledger()
        XCTAssertEqual(before.filter { $0.operation == "webProviderSend" }.count, 3)
        _ = await server.shutdown()
        let afterRestart = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let reopened = try await self.server(afterRestart, root: root)
        try await reject(reopened, task: "remapped-task", thread: "same-thread", turn: "same-turn")
        let after = await afterRestart.ledger()
        XCTAssertEqual(after.filter { $0.operation == "webProviderSend" }.count, 1)
    }

    func testClaudeClosedHistoryAndAmbiguousHandoffCannotReplayActions() async throws {
        for ambiguity in [false, true] {
            let root = try canonicalFormatCorrectionFixtureRoot()
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid, valid])
            let server = try await server(base, root: root)
            let task = "claude-handoff-\(ambiguity)"
            let first = try calls(await server.fixtureInfer(request(), taskID: task))
            let input = [user] + first + [["type": "function_call_output", "call_id": try XCTUnwrap(first.first?["call_id"]), "output": "Observed value"]]
            if ambiguity {
                let accepted = try XCTUnwrap(journal(root, task: task).first { $0["phase"] as? String == "complete" }?["inferenceID"] as? String)
                await server.invalidateHandoffForTesting(taskID: websiteInferenceFixtureTaskID(task), inferenceID: try XCTUnwrap(UUID(uuidString: accepted)))
            }
            try await reject(server, input: request(ambiguity ? input : [user]), task: task)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 2)
        }
    }

    func testClaudeCorrectionCancellationFinishesClosureWithoutSecondStart() async throws {
        let gate = FormatCorrectionGate()
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let server = try await server(base)
        await base.setFirstFinishHook { await gate.pause() }
        let bytes = try request()
        let operation = Task { try await server.fixtureInfer(bytes, taskID: "claude-cancel") }
        for _ in 0..<1_000 {
            if await gate.isPaused() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await gate.isPaused() else {
            XCTFail("Correction must reach the real cleanup barrier")
            await gate.release(); _ = await server.fixtureCancel(taskID: "claude-cancel"); _ = try? await operation.value; return
        }
        let cancellation = Task { await server.fixtureCancel(taskID: "claude-cancel") }
        for _ in 0..<1_000 {
            if await server.isRetiringForTesting(taskID: websiteInferenceFixtureTaskID("claude-cancel")) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let retiring = await server.isRetiringForTesting(taskID: websiteInferenceFixtureTaskID("claude-cancel"))
        XCTAssertTrue(retiring)
        await gate.release()
        do { _ = try await operation.value; XCTFail("Cancelled correction must not publish") } catch { }
        _ = await cancellation.value
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, 1)
    }
}

private actor ClaudeCorrectionProofFixtureTransport: WebModelTransport {
    let base: any WebModelTransport
    let mutation: String?
    let mutationStart: Int
    let duplicateReply: String?
    let isolatedReply: String?
    var starts = 0
    init(_ base: any WebModelTransport, mutation: String?, mutationStart: Int, duplicateReply: String?, isolatedReply: String?) {
        self.base = base; self.mutation = mutation; self.mutationStart = mutationStart; self.duplicateReply = duplicateReply; self.isolatedReply = isolatedReply
    }
    func request(operation: String, params: Data) async throws -> Data {
        let bytes = try await base.request(operation: operation, params: params)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        if value["state"] as? String == "complete", let text = value["text"] as? String,
           let range = text.range(of: "\njson\n"),
           let literal = text[range.upperBound...].data(using: .utf8),
           let envelope = try? JSONSerialization.jsonObject(with: literal) as? [String: Any] {
            value["completionEvidence"] = ["codeStructure": ["preCount": 1, "literalCodeValidJSON": true,
                "literalCodeKnownEnvelopeType": envelope["type"] as? String ?? "unknown",
                "extractionReason": "outside_content", "selectedExtraction": "rendered_fallback"]]
        }
        // Synthetic transport evidence; real DOM derivation is independently
        // covered by the adapter and native WebKit extraction regressions.
        if value["state"] as? String == "complete", let duplicateReply, value["text"] as? String == duplicateReply {
            value["completionEvidence"] = ["codeStructure": ["preCount": 2, "codeCount": 2,
                "repeatedIdenticalToolCalls": true, "extractionReason": "multiple_pre", "selectedExtraction": "rendered_fallback"]]
        }
        if value["state"] as? String == "complete", let isolatedReply, value["text"] as? String == isolatedReply {
            value["completionEvidence"] = ["codeStructure": ["preCount": 1, "codeCount": 1,
                "isolatedJSONCodeBlock": true, "literalCodeValidJSON": false,
                "extractionReason": "invalid_json", "selectedExtraction": "rendered_fallback"]]
        }
        if operation == "webProviderStart" { starts += 1 }
        guard starts == mutationStart, let mutation else { return try JSONSerialization.data(withJSONObject: value) }
        if operation == "webProviderStart" {
            if mutation == "capability" { value.removeValue(forKey: "freshSessionSubmissionCapability") }
            if mutation == "continuation" { value["turnContinuationCapability"] = "per_submission_ownership_v1" }
            if mutation == "model" { value["modelEvidence"] = ["selected": ["key": "Sonnet 5", "label": "Sonnet 5"], "source": "model_picker_label", "verification": "website_selection"] }
        }
        if operation == "webProviderSend", mutation == "early" { value["freshSessionSubmissionProof"] = [:] as [String: String] }
        if operation == "webProviderPoll", value["state"] as? String == "complete" {
            var completion = value["completionEvidence"] as? [String: Any] ?? [:]
            var structure = completion["codeStructure"] as? [String: Any] ?? [:]
            switch mutation {
            case "no_diagnostic": value.removeValue(forKey: "completionEvidence")
            case "multiple_pre": structure["preCount"] = 2
            case "boolean_pre": structure["preCount"] = true
            case "numeric_valid": structure["literalCodeValidJSON"] = 1
            case "message_literal": structure["literalCodeKnownEnvelopeType"] = "message"
            case "raw_extraction": structure["selectedExtraction"] = "raw_code"
            case "other_reason": structure["extractionReason"] = "invalid_json"
            case "isolated_missing": structure.removeValue(forKey: "isolatedJSONCodeBlock")
            case "isolated_false": structure["isolatedJSONCodeBlock"] = false
            case "isolated_null": structure["isolatedJSONCodeBlock"] = NSNull()
            case "isolated_numeric": structure["isolatedJSONCodeBlock"] = 1
            case "isolated_string": structure["isolatedJSONCodeBlock"] = "true"
            case "isolated_array": structure["isolatedJSONCodeBlock"] = [true]
            case "isolated_pre": structure["preCount"] = 2
            case "isolated_code": structure["codeCount"] = 2
            case "isolated_valid": structure["literalCodeValidJSON"] = true
            case "isolated_valid_numeric": structure["literalCodeValidJSON"] = 0
            case "isolated_reason": structure["extractionReason"] = "outside_content"
            case "duplicate_missing": structure.removeValue(forKey: "repeatedIdenticalToolCalls")
            case "duplicate_false": structure["repeatedIdenticalToolCalls"] = false
            case "duplicate_null": structure["repeatedIdenticalToolCalls"] = NSNull()
            case "duplicate_numeric": structure["repeatedIdenticalToolCalls"] = 1
            case "duplicate_string": structure["repeatedIdenticalToolCalls"] = "true"
            case "duplicate_pre": structure["preCount"] = true
            case "duplicate_code": structure["codeCount"] = 1
            default: break
            }
            if mutation != "no_diagnostic" { completion["codeStructure"] = structure; value["completionEvidence"] = completion }
            var proof = value["freshSessionSubmissionProof"] as? [String: Any] ?? [:]
            switch mutation {
            case "missing", "forged_diagnostic": value.removeValue(forKey: "freshSessionSubmissionProof")
            case "string": value["freshSessionSubmissionProof"] = "not a native proof"
            case "extra": proof["untrusted"] = true
            case "token": proof["sessionToken"] = UUID().uuidString
            case "document": proof["documentGeneration"] = UUID().uuidString
            case "sequence": proof["sequence"] = 2
            case "booleanSequence": proof["sequence"] = true
            case "baseline": proof["baselineResponseCount"] = 1
            case "count": proof["responseCount"] = 2
            case "firstUser": proof["firstUserFingerprint"] = String(repeating: "0", count: 64)
            case "prompt": proof["submittedPromptFingerprint"] = String(repeating: "0", count: 64)
            default: break
            }
            if !["missing", "string", "forged_diagnostic"].contains(mutation) { value["freshSessionSubmissionProof"] = proof }
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

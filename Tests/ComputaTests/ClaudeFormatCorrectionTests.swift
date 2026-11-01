import Foundation
import XCTest
@testable import Computa

final class ClaudeFormatCorrectionTests: XCTestCase {
    private let choice = WebsiteModelChoice(provider: "claude", key: "Sonnet 4.6", label: "Sonnet 4.6")
    private let user: [String: Any] = ["role": "user", "content": "Read the synthetic file and report its observed value."]
    private let valid = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"cat \"/tmp/synthetic fixture.py\"","workdir":"/tmp"}}]}"#
    private var malformed: String { "I need to read the current file before making any edits.\n\n\u{E056}\njson\n" + valid }

    private func request(_ input: [[String: Any]]? = nil, model: String? = nil, toolChoice: String = "auto") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model ?? choice.modelID, "stream": false,
            "input": input ?? [user], "tool_choice": toolChoice,
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object",
                "properties": ["cmd": ["type": "string"], "workdir": ["type": "string"]], "required": ["cmd"]]]]])
    }
    private func server(_ base: FormatCorrectionFixtureTransport, root: URL? = nil,
                        mutation: String? = nil, mutationStart: Int = 1) async throws -> WebModelServer {
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
            storageDirectory: try root ?? canonicalFormatCorrectionFixtureRoot())
        await server.configureEmbeddedTransport(ClaudeCorrectionProofFixtureTransport(
            WebsiteInferenceFixtureTransport(base, defaultClaudeChoice: choice), mutation: mutation, mutationStart: mutationStart))
        return server
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
    var starts = 0
    init(_ base: any WebModelTransport, mutation: String?, mutationStart: Int) {
        self.base = base; self.mutation = mutation; self.mutationStart = mutationStart
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

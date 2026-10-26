import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import Computa

final class WebsiteModelFormatCorrectionTests: XCTestCase {
    private let malformed = "Synthetic observed result\n{\"type\":\"tool_calls\",\"calls\":[{\"name\":\"exec_command\",\"arguments\":{\"cmd\":\"fixture\"}}]}"
    private let valid = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"fixture"}}]}"#

    func testNativeEmailCardIsTerminalWithoutCorrectionOrReleasedContent() async throws {
        let card = "Hello\n\nReconnect email\ncourse-staff@example.invalid\nHi course staff,\nJust wanted to say hi!\n\nAdd a clear reason for writing"
        let root = try canonicalFormatCorrectionFixtureRoot()
        let base = FormatCorrectionFixtureTransport(replies: [card, valid])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        let bytes = try JSONSerialization.data(withJSONObject: ["model": syntheticChatGPTModelID, "stream": false,
            "input": "Draft an email here only; do not send it or use tools.", "tools": [], "tool_choice": "none"])
        do {
            _ = try await server.fixtureInfer(bytes, taskID: "email-card-terminal")
            XCTFail("Native website card text must not become a Computa final answer")
        } catch {
            XCTAssertEqual(error as? WebModelResponseCodec.Failure, .unsupportedWebsiteResponse)
            XCTAssertEqual(WebModelServer.errorPresentation(for: error).code, "unsupported_website_response")
        }
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.map(\.operation), ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"])
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 1, "Uncertain website-native actions must never be replayed by a format correction")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence/format-corrections-v1").path))
        let journal = try transactionJournal(root: root, task: "email-card-terminal")
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "failed" }.count, 1)
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "release_verified" }.count, 0)
    }

    func testNativeCardAfterLocalActionDoesNotCorrectOrReplayEitherAction() async throws {
        let card = "Reconnect email\nHi course staff\nMake the greeting more professional"
        let root = try canonicalFormatCorrectionFixtureRoot()
        let base = FormatCorrectionFixtureTransport(replies: [valid, card, valid])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        var input: [[String: Any]] = [["role": "user", "content": "Use the offered fixture command once, then summarize."]]
        let first = try await server.fixtureInfer(request(input: input), taskID: "card-after-action")
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let calls = try XCTUnwrap(response["output"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["name"] as? String, "exec_command")
        input += calls + [["type": "function_call_output", "call_id": try XCTUnwrap(calls.first?["call_id"] as? String),
            "output": "Observed fixture command finished once."]]
        let bytes = try request(input: input)
        do {
            _ = try await server.fixtureInfer(bytes, taskID: "card-after-action")
            XCTFail("A card reply cannot release another response or replay the completed command")
        } catch {
            XCTAssertEqual(WebModelServer.errorPresentation(for: error).code, "unsupported_website_response")
        }
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 2, "Only the first action and one rejected inference; no correction")
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: canonicalRequestBytes(in: prompts[1])) as? [String: Any])
        let retained = try XCTUnwrap(canonical["input"] as? [[String: Any]])
        XCTAssertEqual(retained.count, 3)
        XCTAssertEqual(retained[1]["call_id"] as? String, input[1]["call_id"] as? String)
        XCTAssertEqual(retained[2]["output"] as? String, "Observed fixture command finished once.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence/format-corrections-v1").path))
        let journal = try transactionJournal(root: root, task: "card-after-action")
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "release_verified" }.count, 1,
            "Only the original call was released; the rejected card dispatched no action")
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 2)
    }

    func testChatInvalidJSONClosesOriginalBeforeOneFreshFormatCorrection() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        let output = try await server.fixtureInfer(request(), taskID: "format-positive")
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let calls = try XCTUnwrap(response["output"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["name"] as? String, "exec_command")
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.map(\.operation), ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish",
            "webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"])
        let starts = ledger.filter { $0.operation == "webProviderStart" }
        XCTAssertEqual(Set(starts.compactMap(\.token)).count, 2)
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].hasPrefix(prompts[0]))
        XCTAssertFalse(prompts[1].contains("Synthetic observed result"), "Rejected text is not copied into corrective instructions")
        let task = websiteInferenceFixtureTaskID("format-positive")
        let turn = websiteInferenceFixtureTaskID("format-positive:turn")
        let receipts = try WebsiteSessionCleanupStore(directory: root.appendingPathComponent("cleanup"))
            .transactionRecords(for: task, turnID: turn)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(receipts.allSatisfy { $0.receiptSaved && $0.outcome == .closed })
        let journal = try Data(contentsOf: root.appendingPathComponent("evidence/transactions/" + task + "/" + turn + ".jsonl"))
            .split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        let rejection = try XCTUnwrap(journal.first { $0["phase"] as? String == "failed" && $0["errorCode"] as? String == "malformed_website_reply" })
        let accepted = try XCTUnwrap(journal.first { $0["phase"] as? String == "complete" })
        XCTAssertEqual(rejection["modelEvidence"] as? NSDictionary, accepted["modelEvidence"] as? NSDictionary)
        XCTAssertEqual((rejection["productModeEvidence"] as? [String: Any])?["mode"] as? String, "chat")
        XCTAssertEqual(rejection["responseCount"] as? Int, 1)
        XCTAssertEqual((rejection["firstUserFingerprint"] as? String)?.count, 64)
        XCTAssertEqual(rejection["submittedPromptFingerprint"] as? String,
            SHA256.hash(data: Data(prompts[0].utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "failed" }.count, 1)
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "complete" }.count, 1)
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "release_verified" }.count, 1)
    }

    func testChatSecondInvalidJSONAndRemappedTaskCannotRenewCorrection() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let base = FormatCorrectionFixtureTransport(replies: [malformed, malformed, malformed, valid])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        await assertRejected(server, task: "format-once", thread: "stable-thread", turn: "stable-turn")
        let first = await base.ledger()
        XCTAssertEqual(first.filter { $0.operation == "webProviderSend" }.count, 2)
        _ = await server.fixtureFinish(taskID: "format-once")
        // A fresh native task/preparation in the same thread+turn may not buy
        // another correction, even after the first exact session is closed.
        await assertRejected(server, task: "remapped-task", thread: "stable-thread", turn: "stable-turn")
        let after = await base.ledger()
        XCTAssertEqual(after.filter { $0.operation == "webProviderSend" }.count, 3)
        XCTAssertEqual(after.filter { $0.operation == "webProviderStart" }.count, 3)
    }

    func testChatCorrectionClaimSurvivesServerRestart() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let first = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(first, defaultChatChoice: syntheticChatGPTChoice))
        _ = try await server.fixtureInfer(request(), taskID: "before-restart", threadID: "persisted-thread", turnID: "persisted-turn")
        _ = await server.shutdown()
        let second = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let restarted = try await makeServer(storageDirectory: root)
        await restarted.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(second, defaultChatChoice: syntheticChatGPTChoice))
        await assertRejected(restarted, task: "after-restart", thread: "persisted-thread", turn: "persisted-turn")
        let ledger = await second.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
    }

    func testChatCorrectionDoesNotApplyToSchemaPolicyOrUnknownTools() async throws {
        let replies = [#"{"type":"tool_calls","calls":[{"name":"unoffered","arguments":{}}]}"#,
            #"{"type":"tool_calls","calls":"invalid"}"#,
            #"{"type":"message","text":"forbidden by required tool choice"}"#]
        for (index, reply) in replies.enumerated() {
            let base = FormatCorrectionFixtureTransport(replies: [reply, valid])
            let server = try await makeServer()
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: request()) as? [String: Any])
            if index == 2 { object["tool_choice"] = "required" }
            do {
                _ = try await server.fixtureInfer(JSONSerialization.data(withJSONObject: object), taskID: "not-format-\(index)")
                XCTFail("A format correction must not repair tool policy or envelope schema")
            } catch { }
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
        }
    }

    func testChatCorrectionRequiresDurableOriginalClosure() async throws {
        for persistFailure in [false, true] {
            let root = try canonicalFormatCorrectionFixtureRoot()
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid], cleanupFails: !persistFailure)
            let server = try await makeServer(storageDirectory: root)
            if persistFailure {
                await base.setFirstFinishHook {
                    let cleanup = root.appendingPathComponent("cleanup")
                    try? FileManager.default.removeItem(at: cleanup)
                    try? Data("blocked".utf8).write(to: cleanup)
                }
            }
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            await assertRejected(server, task: "close-barrier")
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
        }
    }

    func testChatCorrectionDeadlineIncludesOriginalCleanupAndDoesNotRenew() async throws {
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid], cleanupDelay: .milliseconds(100))
        let server = try await makeServer()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        await server.setTimeoutsForTesting(readiness: .seconds(1), response: .milliseconds(50))
        await assertRejected(server, task: "format-deadline")
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, 1,
            "Cleanup must finish even after the response deadline expires")
    }

    func testChatCorrectionDeadlineBeginsBeforeOriginalSendAndBoundsCorrectiveStart() async throws {
        for delayFirstSend in [true, false] {
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid],
                firstSendDelay: delayFirstSend ? .milliseconds(100) : .zero,
                secondStartDelay: delayFirstSend ? .zero : .milliseconds(100))
            let server = try await makeServer()
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            await server.setTimeoutsForTesting(readiness: .seconds(1), response: .milliseconds(50))
            await assertRejected(server, task: "original-deadline-\(delayFirstSend)")
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, delayFirstSend ? 1 : 2)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderPoll" }.count, delayFirstSend ? 0 : 1)
        }
    }

    func testChatCorrectionExcludesMaintenanceAndRetainedLeases() async throws {
        for maintenance in [true, false] {
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
            let server = try await makeServer()
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            if maintenance {
                let task = websiteInferenceFixtureTaskID("excluded"), thread = websiteInferenceFixtureTaskID("excluded:thread")
                let preparation = UUID(uuidString: websiteInferenceFixtureTaskID("excluded:preparation"))!
                try await server.prepareInferenceTurn(taskID: task, threadID: thread, runtimeGeneration: websiteInferenceFixtureGeneration,
                    preparationID: preparation, isMaintenance: true)
            } else { await server.retainChatGPTConversationForTesting() }
            await assertRejected(server, task: "excluded")
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
        }
    }

    func testCorrectedResponseCannotRenewAmbiguousHTTPHandoff() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid, valid])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        let data = try await server.fixtureInfer(request(), taskID: "format-ambiguous")
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try XCTUnwrap(response["output"] as? [[String: Any]])
        let task = websiteInferenceFixtureTaskID("format-ambiguous"), turn = websiteInferenceFixtureTaskID("format-ambiguous:turn")
        let journal = try Data(contentsOf: root.appendingPathComponent("evidence/transactions/" + task + "/" + turn + ".jsonl"))
            .split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        let accepted = try XCTUnwrap(journal.first { $0["phase"] as? String == "complete" }?["inferenceID"] as? String)
        await server.invalidateHandoffForTesting(taskID: task, inferenceID: try XCTUnwrap(UUID(uuidString: accepted)))
        let next: [[String: Any]] = [["role": "user", "content": "Use the offered fixture command"]] + calls + [
            ["type": "function_call_output", "call_id": try XCTUnwrap(calls.first?["call_id"] as? String), "output": "Observed result"]]
        do { _ = try await server.fixtureInfer(request(input: next), taskID: "format-ambiguous"); XCTFail("An ambiguous output cannot be replayed") }
        catch { }
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 2)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 2)
    }

    func testChatCorrectionRefusesChangedTransportAfterOriginalClosure() async throws {
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let server = try await makeServer()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        await base.setFirstFinishHook {
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(
                FormatCorrectionFixtureTransport(replies: []), defaultChatChoice: syntheticChatGPTChoice))
        }
        await assertRejected(server, task: "format-drift")
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, 1)
    }

    func testChatCorrectionKeepsResolvedFamilyPinnedBeforeSecondSend() async throws {
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid], mismatchesSecondModel: true)
        let server = try await makeServer()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        await assertRejected(server, task: "format-model-drift")
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 2)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
    }

    func testChatCorrectiveResponseStillRequiresModelProductAndOwnershipProof() async throws {
        for mutation in ["model", "work", "proof", "context"] {
            let base = FormatCorrectionFixtureTransport(replies: [malformed, valid], secondResponseMutation: mutation)
            let server = try await makeServer()
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            if mutation == "context" {
                await base.setSecondPollHook {
                    await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(
                        FormatCorrectionFixtureTransport(replies: []), defaultChatChoice: syntheticChatGPTChoice))
                }
            }
            await assertRejected(server, task: "second-proof-\(mutation)")
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 2)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 2)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, 1,
                "Only the rejected original is closed internally; invalid corrective output is not released")
        }
    }

    func testChatCorrectionCancellationWaitsForOriginalClosureAndForbidsSecondStart() async throws {
        let gate = FormatCorrectionGate()
        let base = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let server = try await makeServer()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        await base.setFirstFinishHook { await gate.pause() }
        let input = try request()
        let operation = Task { try await server.fixtureInfer(input, taskID: "format-cancel") }
        for _ in 0..<1_000 {
            if await gate.isPaused() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await gate.isPaused() else {
            XCTFail("The fully proved original rejection must reach its cleanup barrier")
            await gate.release()
            _ = await server.fixtureCancel(taskID: "format-cancel")
            _ = try? await operation.value
            return
        }
        let cancellation = Task { await server.fixtureCancel(taskID: "format-cancel") }
        // Wait until cancellation has revoked the active context, rather than
        // relying on task scheduling before releasing the cleanup callback.
        for _ in 0..<1_000 {
            if await server.isRetiringForTesting(taskID: websiteInferenceFixtureTaskID("format-cancel")) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let retiring = await server.isRetiringForTesting(taskID: websiteInferenceFixtureTaskID("format-cancel"))
        XCTAssertTrue(retiring)
        await gate.release()
        do { _ = try await operation.value; XCTFail("A cancelled correction must not return output") } catch { }
        let issues = await cancellation.value
        XCTAssertTrue(issues.isEmpty)
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, 1)
    }

    func testChatCorrectionConsumesTheExistingNativeTurnInferenceBudget() async throws {
        let base = FormatCorrectionFixtureTransport(replies: [malformed] + Array(repeating: valid, count: 16))
        let server = try await makeServer()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        var input: [[String: Any]] = [["role": "user", "content": "Use the offered fixture command"]]
        for _ in 0..<15 {
            let data = try await server.fixtureInfer(request(input: input), taskID: "format-budget")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let calls = try XCTUnwrap(object["output"] as? [[String: Any]])
            input += calls + [["type": "function_call_output", "call_id": try XCTUnwrap(calls.first?["call_id"] as? String), "output": "Observed fixture result"]]
        }
        do { _ = try await server.fixtureInfer(request(input: input), taskID: "format-budget"); XCTFail("The correction must consume a normal inference slot") }
        catch { guard case .turnLimit = error as? WebModelServer.Failure else { return XCTFail("Expected the unchanged turn limit") } }
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 16)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 16)
    }

    func testUnavailableCorrectionStoreDoesNotAffectOrdinaryFirstInference() async throws {
        for reply in [valid, malformed] {
            let root = try canonicalFormatCorrectionFixtureRoot()
            let base = FormatCorrectionFixtureTransport(replies: [reply, valid])
            let server = try await makeServer(storageDirectory: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("evidence"), withIntermediateDirectories: true)
            try Data("blocked".utf8).write(to: root.appendingPathComponent("evidence/format-corrections-v1"))
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            if reply == valid { _ = try await server.fixtureInfer(request(), taskID: "store-unavailable") }
            else { await assertRejected(server, task: "store-unavailable") }
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
        }
    }

    func testRendererFailureClosesExactSessionBeforeOneFreshInference() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let base = FormatCorrectionFixtureTransport(replies: ["UNACCEPTED_RENDERER_CONTENT", valid],
            pollFailures: [1: .responseRenderingFailed])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        let output = try await server.fixtureInfer(request(), taskID: "renderer-positive")
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let calls = try XCTUnwrap(response["output"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["name"] as? String, "exec_command")
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.map(\.operation), ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish",
            "webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"])
        XCTAssertEqual(Set(ledger.filter { $0.operation == "webProviderStart" }.compactMap(\.token)).count, 2)
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].hasPrefix(prompts[0]))
        XCTAssertTrue(prompts[1].contains("The website could not render the previous reply"))
        XCTAssertFalse(prompts[1].contains("rejected as invalid JSON"))
        XCTAssertFalse(prompts[1].contains("UNACCEPTED_RENDERER_CONTENT"))
        let task = websiteInferenceFixtureTaskID("renderer-positive"), turn = websiteInferenceFixtureTaskID("renderer-positive:turn")
        let records = try WebsiteSessionCleanupStore(directory: root.appendingPathComponent("cleanup"))
            .transactionRecords(for: task, turnID: turn)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.receiptSaved && $0.outcome == .closed })
        let journal = try transactionJournal(root: root, task: "renderer-positive")
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "failed" }.count, 1)
        XCTAssertEqual(journal.first { $0["phase"] as? String == "failed" }?["errorCode"] as? String,
            "website_response_rendering_failed")
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "complete" }.count, 1)
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "release_verified" }.count, 1)
        let corrections = try correctionRecords(root: root)
        XCTAssertEqual(corrections.count, 3)
        XCTAssertTrue(corrections.allSatisfy { $0.reason == .rendererFailure })
    }

    func testRendererAndInvalidJSONShareOneAllowanceInEitherOrder() async throws {
        for order in ["renderer-renderer", "renderer-json", "json-renderer"] {
            let errors: [Int: EmbeddedWebModelTransport.Failure] = order == "renderer-renderer"
                ? [1: .responseRenderingFailed, 2: .responseRenderingFailed]
                : order == "renderer-json" ? [1: .responseRenderingFailed] : [2: .responseRenderingFailed]
            let root = try canonicalFormatCorrectionFixtureRoot()
            let base = FormatCorrectionFixtureTransport(replies: [malformed, malformed, valid], pollFailures: errors)
            let server = try await makeServer(storageDirectory: root)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            await assertRejected(server, task: order)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 2, order)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, 1, order)
            let records = try correctionRecords(root: root)
            XCTAssertEqual(records.count, 3)
            XCTAssertEqual(records.first?.reason, order == "json-renderer" ? .invalidJSON : .rendererFailure)
            XCTAssertFalse(try transactionJournal(root: root, task: order).contains { $0["phase"] as? String == "release_verified" })
        }
    }

    func testRendererRecoveryPreservesFulfilledBrowserFillAndNextRequestExactlyOnce() async throws {
        let fill = #"{"type":"tool_calls","calls":[{"name":"browser_fill","arguments":{"ref":"field-fixture","text":"fixture@example.test"}}]}"#
        let click = #"{"type":"tool_calls","calls":[{"name":"browser_click","arguments":{"ref":"submit-fixture"}}]}"#
        let root = try canonicalFormatCorrectionFixtureRoot()
        let base = FormatCorrectionFixtureTransport(replies: [fill, "UNACCEPTED_RENDERER_CONTENT", click,
            #"{"type":"message","text":"Observed fixture receipt."}"#], pollFailures: [2: .responseRenderingFailed])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        let tools: [[String: Any]] = [
            ["type": "function", "name": "browser_fill", "parameters": ["type": "object", "properties":
                ["ref": ["type": "string"], "text": ["type": "string"]]]],
            ["type": "function", "name": "browser_click", "parameters": ["type": "object", "properties": ["ref": ["type": "string"]]]]]
        var input: [[String: Any]] = [["role": "user", "content": "Fill the fixture and submit it once."]]
        var releasedNames: [String] = []
        for expected in ["browser_fill", "browser_click"] {
            let bytes = try JSONSerialization.data(withJSONObject: ["model": syntheticChatGPTModelID, "stream": false,
                "input": input, "tools": tools])
            let output = try await server.fixtureInfer(bytes, taskID: "renderer-after-fill")
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
            let calls = try XCTUnwrap(response["output"] as? [[String: Any]])
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?["name"] as? String, expected)
            if expected == "browser_fill" {
                let arguments = try XCTUnwrap(calls.first?["arguments"] as? String)
                let literal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String])
                XCTAssertEqual(literal, ["ref": "field-fixture", "text": "fixture@example.test"])
            }
            releasedNames += calls.compactMap { $0["name"] as? String }
            input += calls + [["type": "function_call_output", "call_id": try XCTUnwrap(calls.first?["call_id"] as? String),
                "output": expected == "browser_fill" ? "Observed exact field value fixture@example.test" : "Observed fixture receipt"]]
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["model": syntheticChatGPTModelID, "stream": false,
            "input": input, "tools": tools])
        _ = try await server.fixtureInfer(bytes, taskID: "renderer-after-fill")
        XCTAssertEqual(releasedNames, ["browser_fill", "browser_click"], "Rejected inference has no released tool call ID")
        let prompts = await base.prompts()
        XCTAssertEqual(prompts.count, 4)
        let failedCanonical = try canonicalRequestBytes(in: prompts[1])
        XCTAssertEqual(try canonicalRequestBytes(in: prompts[2]), failedCanonical,
            "The correction must preserve the complete admitted next request byte for byte")
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: failedCanonical) as? [String: Any])
        let history = try XCTUnwrap(canonical["input"] as? [[String: Any]])
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[1]["name"] as? String, "browser_fill")
        XCTAssertEqual(history[1]["arguments"] as? String, input[1]["arguments"] as? String)
        XCTAssertEqual(history[2]["call_id"] as? String, input[2]["call_id"] as? String)
        XCTAssertEqual(history[2]["output"] as? String, "Observed exact field value fixture@example.test")
        XCTAssertFalse(prompts[2].contains("UNACCEPTED_RENDERER_CONTENT"))
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 4)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, 4)
        let journal = try transactionJournal(root: root, task: "renderer-after-fill")
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "failed" }.count, 1)
        XCTAssertEqual(journal.filter { $0["phase"] as? String == "release_verified" }.count, 3)
    }

    func testRendererClaimSurvivesRestartAndTaskRemapWithoutRenewingAllowance() async throws {
        let root = try canonicalFormatCorrectionFixtureRoot()
        let first = FormatCorrectionFixtureTransport(replies: ["ignored", valid], pollFailures: [1: .responseRenderingFailed])
        let server = try await makeServer(storageDirectory: root)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(first, defaultChatChoice: syntheticChatGPTChoice))
        _ = try await server.fixtureInfer(request(), taskID: "renderer-before-restart", threadID: "stable-renderer-thread", turnID: "stable-renderer-turn")
        _ = await server.shutdown()
        let second = FormatCorrectionFixtureTransport(replies: [malformed, valid])
        let restarted = try await makeServer(storageDirectory: root)
        await restarted.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(second, defaultChatChoice: syntheticChatGPTChoice))
        await assertRejected(restarted, task: "renderer-remapped", thread: "stable-renderer-thread", turn: "stable-renderer-turn")
        let ledger = await second.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
    }

    func testRendererRecoveryRequiresCleanupPersistenceDeadlineAndCurrentContext() async throws {
        for scenario in ["cleanup-failed", "receipt-missing", "deadline", "transport", "maintenance", "retained", "missing-proof", "model"] {
            let root = try canonicalFormatCorrectionFixtureRoot()
            let base = FormatCorrectionFixtureTransport(replies: ["ignored", valid], cleanupFails: scenario == "cleanup-failed",
                cleanupDelay: scenario == "deadline" ? .milliseconds(100) : .zero,
                mismatchesSecondModel: scenario == "model", pollFailures: [1: .responseRenderingFailed],
                firstSendMutation: scenario == "missing-proof" ? "proof" : nil)
            let server = try await makeServer(storageDirectory: root)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            if scenario == "receipt-missing" {
                await base.setFirstFinishHook {
                    let directory = root.appendingPathComponent("cleanup")
                    try? FileManager.default.removeItem(at: directory)
                    try? Data("blocked".utf8).write(to: directory)
                }
            } else if scenario == "transport" {
                await base.setFirstFinishHook {
                    await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(
                        FormatCorrectionFixtureTransport(replies: []), defaultChatChoice: syntheticChatGPTChoice))
                }
            } else if scenario == "deadline" {
                await server.setTimeoutsForTesting(readiness: .seconds(1), response: .milliseconds(50))
            } else if scenario == "retained" { await server.retainChatGPTConversationForTesting() }
            else if scenario == "maintenance" {
                let task = websiteInferenceFixtureTaskID(scenario), thread = websiteInferenceFixtureTaskID(scenario + ":thread")
                let preparation = UUID(uuidString: websiteInferenceFixtureTaskID(scenario + ":preparation"))!
                try await server.prepareInferenceTurn(taskID: task, threadID: thread, runtimeGeneration: websiteInferenceFixtureGeneration,
                    preparationID: preparation, isMaintenance: true)
            }
            await assertRejected(server, task: scenario)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1, scenario)
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, scenario == "model" ? 2 : 1, scenario)
        }
    }

    func testRendererRecoveryCancellationFinishesCleanupWithoutStartingAgain() async throws {
        let gate = FormatCorrectionGate()
        let base = FormatCorrectionFixtureTransport(replies: ["ignored", valid], pollFailures: [1: .responseRenderingFailed])
        let server = try await makeServer()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
        await base.setFirstFinishHook { await gate.pause() }
        let data = try request()
        let operation = Task { try await server.fixtureInfer(data, taskID: "renderer-cancel") }
        addTeardownBlock { operation.cancel(); await gate.release() }
        for _ in 0..<1_000 {
            if await gate.isPaused() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await gate.isPaused() else { return XCTFail("Renderer recovery must reach exact cleanup barrier") }
        let cancellation = Task { await server.fixtureCancel(taskID: "renderer-cancel") }
        for _ in 0..<1_000 {
            if await server.isRetiringForTesting(taskID: websiteInferenceFixtureTaskID("renderer-cancel")) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let retiring = await server.isRetiringForTesting(taskID: websiteInferenceFixtureTaskID("renderer-cancel"))
        XCTAssertTrue(retiring)
        await gate.release()
        do { _ = try await operation.value; XCTFail("Cancelled recovery cannot release output") } catch { }
        let issues = await cancellation.value
        XCTAssertTrue(issues.isEmpty)
        let ledger = await base.ledger()
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1)
        XCTAssertEqual(ledger.filter { $0.operation == "webProviderFinish" }.count, 1)
    }

    func testRendererRecoveryConsumesUnchangedInferenceAndCumulativePromptBudgets() async throws {
        for byteLimit in [false, true] {
            let base = FormatCorrectionFixtureTransport(replies: Array(repeating: valid, count: 20),
                pollFailures: [1: .responseRenderingFailed])
            let server = try await makeServer()
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            let task = "renderer-budget-\(byteLimit)"
            var input: [[String: Any]] = [["role": "user", "content": "Use the offered fixture command"]]
            var accepted = 0, reached = false
            for _ in 0..<18 {
                let data = try request(input: input)
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                object["client_metadata"] = ["x-codex-turn-metadata": try websiteInferenceFixtureMetadata(taskID: task)]
                let nextPromptBytes = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: object)).prompt.utf8.count
                do {
                    let output = try await server.fixtureInfer(data, taskID: task)
                    accepted += 1
                    let response = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
                    let calls = try XCTUnwrap(response["output"] as? [[String: Any]])
                    input += calls + [["type": "function_call_output", "call_id": try XCTUnwrap(calls.first?["call_id"] as? String),
                        "output": byteLimit ? String(repeating: "A", count: 10_000) : "Observed fixture result"]]
                } catch {
                    XCTAssertEqual(WebModelServer.errorPresentation(for: error).code, "website_turn_limit")
                    let prompts = await base.prompts()
                    XCTAssertEqual(prompts.count, accepted + 1, "The failed renderer inference spends one normal slot")
                    XCTAssertTrue(byteLimit
                        ? prompts.reduce(0) { $0 + $1.utf8.count } + nextPromptBytes > WebModelServer.maximumTurnPromptUTF8Bytes
                        : prompts.count == WebModelServer.maximumTurnInferences)
                    reached = true
                    break
                }
            }
            XCTAssertTrue(reached)
        }
    }

    func testOnlyExactRendererFailureFromResponsePollCanRecover() async throws {
        for (index, failure) in [EmbeddedWebModelTransport.Failure.responseFailed(.chatgpt),
            .ownershipFailure(.javaScriptSubmission), .modelUnavailable, .signInRequired, .humanVerificationRequired(.chatgpt), .deadline].enumerated() {
            let base = FormatCorrectionFixtureTransport(replies: ["ignored", valid], pollFailures: [1: failure])
            let server = try await makeServer()
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            await assertRejected(server, task: "generic-failure-\(index)")
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderSend" }.count, 1)
        }
        for operation in ["webProviderStart", "webProviderSend"] {
            let base = FormatCorrectionFixtureTransport(replies: [valid], earlyRendererFailureOperation: operation)
            let server = try await makeServer()
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(base, defaultChatChoice: syntheticChatGPTChoice))
            await assertRejected(server, task: "early-renderer-" + operation)
            let ledger = await base.ledger()
            XCTAssertEqual(ledger.filter { $0.operation == "webProviderStart" }.count, 1)
        }
    }

    private func canonicalRequestBytes(in prompt: String) throws -> Data {
        try WebsiteRequestFixture.json(in: prompt)
    }
    private func correctionRecords(root: URL) throws -> [WebsiteModelFormatCorrectionStore.Record] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("evidence/format-corrections-v1"), includingPropertiesForKeys: nil)
            .map { try JSONDecoder().decode(WebsiteModelFormatCorrectionStore.Record.self, from: Data(contentsOf: $0)) }
    }
    private func transactionJournal(root: URL, task: String) throws -> [[String: Any]] {
        let taskID = websiteInferenceFixtureTaskID(task), turnID = websiteInferenceFixtureTaskID(task + ":turn")
        return try Data(contentsOf: root.appendingPathComponent("evidence/transactions/" + taskID + "/" + turnID + ".jsonl"))
            .split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }

    private func makeServer(storageDirectory: URL? = nil) async throws -> WebModelServer {
        let root = try storageDirectory ?? canonicalFormatCorrectionFixtureRoot()
        return try await makeWebsiteInferenceFixtureServer(testCase: self, storageDirectory: root)
    }

    private func assertRejected(_ server: WebModelServer, task: String, thread: String? = nil, turn: String? = nil) async {
        do {
            _ = try await server.fixtureInfer(request(), taskID: task, threadID: thread, turnID: turn)
            XCTFail("This request must not release a response")
        } catch { }
    }

    private func request(input: [[String: Any]] = [["role": "user", "content": "Use the offered fixture command"]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": syntheticChatGPTModelID, "stream": false,
            "input": input,
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]]]])
    }
}

private actor FormatCorrectionFixtureTransport: WebModelTransport {
    struct Entry: Sendable { let operation: String; let token: String? }
    private var entries: [Entry] = []
    private var sentPrompts: [String] = []
    private var replies: [String]
    private var active: [String: String] = [:]
    private let cleanupFails: Bool
    private let cleanupDelay: Duration
    private let mismatchesSecondModel: Bool
    private let secondResponseMutation: String?
    private let firstSendDelay: Duration
    private let secondStartDelay: Duration
    private let pollFailures: [Int: EmbeddedWebModelTransport.Failure]
    private let firstSendMutation: String?
    private let earlyRendererFailureOperation: String?
    private var starts = 0
    private var finishes = 0
    private var firstFinishHook: (@Sendable () async -> Void)?
    private var secondPollHook: (@Sendable () async -> Void)?
    init(replies: [String], cleanupFails: Bool = false, cleanupDelay: Duration = .zero, mismatchesSecondModel: Bool = false,
         secondResponseMutation: String? = nil, firstSendDelay: Duration = .zero, secondStartDelay: Duration = .zero,
         pollFailures: [Int: EmbeddedWebModelTransport.Failure] = [:], firstSendMutation: String? = nil,
         earlyRendererFailureOperation: String? = nil) {
        self.replies = replies; self.cleanupFails = cleanupFails; self.cleanupDelay = cleanupDelay
        self.mismatchesSecondModel = mismatchesSecondModel
        self.secondResponseMutation = secondResponseMutation
        self.firstSendDelay = firstSendDelay; self.secondStartDelay = secondStartDelay
        self.pollFailures = pollFailures; self.firstSendMutation = firstSendMutation
        self.earlyRendererFailureOperation = earlyRendererFailureOperation
    }
    func setFirstFinishHook(_ hook: @escaping @Sendable () async -> Void) { firstFinishHook = hook }
    func setSecondPollHook(_ hook: @escaping @Sendable () async -> Void) { secondPollHook = hook }
    func ledger() -> [Entry] { entries }
    func prompts() -> [String] { sentPrompts }
    func request(operation: String, params: Data) async throws -> Data {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        var snapshot: [String: Any]
        if operation == "webProviderStart" {
            starts += 1
            if starts == 2, secondStartDelay > .zero { try await Task.sleep(for: secondStartDelay) }
            let token = UUID().uuidString.lowercased()
            active[token] = ""
            entries.append(.init(operation: operation, token: token))
            if earlyRendererFailureOperation == operation { throw EmbeddedWebModelTransport.Failure.responseRenderingFailed }
            snapshot = ["sessionToken": token, "state": "ready"]
            if starts == 2, mismatchesSecondModel {
                let other = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/high", label: "High")
                snapshot["modelEvidence"] = ["selected": ["key": other.key, "label": other.label],
                    "source": "selected_model_indicator", "verification": "website_selection", "chatSelection": syntheticChatSelection(other)!]
            }
        } else {
            let token = try XCTUnwrap(input["sessionToken"])
            guard active[token] != nil else { throw WebModelServer.Failure.invalidRequest }
            entries.append(.init(operation: operation, token: token))
            switch operation {
            case "webProviderSend":
                if earlyRendererFailureOperation == operation { throw EmbeddedWebModelTransport.Failure.responseRenderingFailed }
                sentPrompts.append(try XCTUnwrap(input["prompt"]))
                if sentPrompts.count == 1, firstSendDelay > .zero { try await Task.sleep(for: firstSendDelay) }
                active[token] = replies.isEmpty ? #"{"type":"message","text":"fallback"}"# : replies.removeFirst()
                snapshot = ["state": "running"]
            case "webProviderPoll":
                // Fault injection is after a fully admitted Send and only at
                // response polling, matching the native typed-error contract.
                if starts == 2 { await secondPollHook?() }
                if let failure = pollFailures[sentPrompts.count] { throw failure }
                snapshot = ["state": "complete", "text": active[token]!]
            case "webProviderFinish", "webProviderCancel":
                finishes += 1
                if finishes == 1 { await firstFinishHook?() }
                if cleanupDelay > .zero { try await Task.sleep(for: cleanupDelay) }
                if cleanupFails { snapshot = ["cleanup": "failed"] }
                else { active.removeValue(forKey: token); snapshot = ["cleanup": "not_created"] }
            default: throw WebModelServer.Failure.invalidRequest
            }
        }
        var prepared = syntheticPreparedWebsiteSnapshot(snapshot)
        if operation == "webProviderSend", sentPrompts.count == 1, firstSendMutation == "proof" {
            prepared["modelProofContext"] = ["submittedPromptFingerprint": String(repeating: "0", count: 64)]
        }
        if starts == 2, operation == "webProviderPoll" {
            switch secondResponseMutation {
            case "work": prepared["productModeEvidence"] = ["product": "chatgpt", "mode": "work", "source": "composer_mode_control", "temporaryTransition": "acknowledged"]
            case "proof": prepared["modelProofContext"] = ["submittedPromptFingerprint": String(repeating: "0", count: 64)]
            case "model":
                let other = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/high", label: "High")
                prepared["modelEvidence"] = ["selected": ["key": other.key, "label": other.label], "source": "selected_model_indicator",
                    "verification": "website_selection", "chatSelection": syntheticChatSelection(other)!]
            default: break
            }
        }
        return try JSONSerialization.data(withJSONObject: prepared)
    }
}

private actor FormatCorrectionGate {
    private var paused = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        if released { return }
        paused = true
        await withCheckedContinuation { waiter = $0 }
    }
    func isPaused() -> Bool { paused }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

/// Foundation deliberately rewrites /private/var to /var on this host, even
/// after resolvingSymlinksInPath. Match the production store's physical path.
func canonicalFormatCorrectionFixtureRoot() throws -> URL {
    guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        .appendingPathComponent("format-fixture-" + UUID().uuidString, isDirectory: true)
}

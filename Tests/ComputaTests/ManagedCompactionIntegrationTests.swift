import Foundation
import XCTest
@testable import Computa

/// Exercises production Core over real child-process JSON-RPC, but never loads
/// a model, invokes a dynamic tool, or interacts with the user's desktop.
@MainActor
final class ManagedCompactionIntegrationTests: XCTestCase {
    func testLifecycleBeforeAcknowledgementPreservesEvidenceAndSerializesNextTurn() async throws {
        try await withHarness(scenario: "normal") { harness in
            try await harness.completeBaseline()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("injection barrier") { harness.markerExists("injection-waiting") }
            XCTAssertFalse(attempt.finished)
            XCTAssertEqual(harness.audit.completedTurns, 1, "Maintenance must not complete the pending user task.")
            XCTAssertEqual(harness.audit.compactionsCompleted, 0, "Logical compaction includes the durable history append.")
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))

            try harness.release("release-injection")
            try await self.waitFor("accepted second submission") { attempt.finished }
            XCTAssertTrue(attempt.accepted, attempt.error ?? "Submission failed.")
            try await self.waitFor("second real turn completion") { harness.audit.completedTurns == 2 }
            XCTAssertEqual(harness.audit.compactionsCompleted, 1)
            XCTAssertTrue(harness.audit.contextFailures.isEmpty)
            XCTAssertEqual(harness.audit.assistantReplies, ["ACTUAL_PRIOR_REPLY", "NEW_REPLY"])

            let trace = try harness.trace()
            let compact = try XCTUnwrap(trace.messages.first { $0.method == "thread/compact/start" })
            let compactAck = try XCTUnwrap(trace.messages.first { $0.direction == .serverToClient && $0.identifier == compact.identifier && $0.object["result"] != nil })
            let maintenanceTerminal = try XCTUnwrap(trace.messages.first { message in
                guard message.method == "turn/completed", let params = message.object["params"] as? [String: Any],
                      let turn = params["turn"] as? [String: Any] else { return false }
                return turn["id"] as? String == "maintenance-turn"
            })
            XCTAssertLessThan(maintenanceTerminal.sequence, compactAck.sequence)
            let injection = try XCTUnwrap(trace.messages.first { $0.method == "thread/inject_items" })
            let injectionAck = try XCTUnwrap(trace.messages.first { $0.direction == .serverToClient && $0.identifier == injection.identifier && $0.object["result"] != nil })
            let starts = trace.messages.filter { $0.method == "turn/start" }
            XCTAssertEqual(starts.count, 2)
            XCTAssertLessThan(compactAck.sequence, injection.sequence)
            XCTAssertLessThan(injection.sequence, injectionAck.sequence)
            XCTAssertLessThan(injectionAck.sequence, try XCTUnwrap(starts.last).sequence)
            let params = try XCTUnwrap(injection.object["params"] as? [String: Any])
            let items = try XCTUnwrap(params["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(Set(try XCTUnwrap(items.first).keys), ["type", "role", "content"])
            XCTAssertEqual(items.first?["role"] as? String, "assistant")
            XCTAssertEqual(items.first?["content"] as? [[String: String]], [["type": "output_text", "text": "ACTUAL_PRIOR_REPLY"]])
            XCTAssertFalse(trace.messages.contains { $0.method == "item/tool/call" })
        }
    }

    func testStopWhileInjectionAcknowledgementIsPendingNeverStartsUserTurn() async throws {
        try await withHarness(scenario: "stop") { harness in
            try await harness.completeBaseline()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("held injection") { harness.markerExists("injection-waiting") }
            try await harness.runtime.interrupt(taskID: harness.taskID)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            XCTAssertEqual(harness.audit.completedTurns, 1)
            try harness.release("release-injection")
            try await self.waitFor("cancelled pending submission") { attempt.finished }
            XCTAssertFalse(attempt.accepted)
            XCTAssertNotNil(attempt.error)
            try await self.waitFor("waiting terminal") { harness.audit.lastStatus == .waiting }
            XCTAssertEqual(harness.audit.completedTurns, 1)
            XCTAssertEqual(harness.audit.compactionsCompleted, 0)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            let trace = try harness.trace()
            XCTAssertEqual(trace.messages.filter { $0.method == "thread/inject_items" }.count, 1)
            XCTAssertEqual(trace.messages.filter { $0.method == "turn/start" }.count, 1)
        }
    }

    func testDisconnectWhileWaitingForCompactionTerminalReleasesSubmission() async throws {
        try await withHarness(scenario: "disconnect") { harness in
            try await harness.completeBaseline()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("compaction waiting for terminal") { harness.markerExists("compaction-waiting") }
            XCTAssertFalse(attempt.finished)
            XCTAssertEqual(harness.audit.completedTurns, 1)
            try harness.release("disconnect-now")
            try await self.waitFor("disconnected submission") { attempt.finished }
            XCTAssertFalse(attempt.accepted)
            XCTAssertNotNil(attempt.error)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            try await self.waitFor("observable disconnection failure") { !harness.audit.contextFailures.isEmpty }
            let trace = try harness.trace()
            XCTAssertEqual(trace.messages.filter { $0.method == "thread/compact/start" }.count, 1)
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/inject_items" })
            XCTAssertEqual(trace.messages.filter { $0.method == "turn/start" }.count, 1)
        }
    }

    func testMissingCompactionItemCompletionFailsWithoutInjectionOrPromptDelivery() async throws {
        try await withHarness(scenario: "missing-item") { harness in
            try await harness.completeBaseline()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("missing-item rejection") { attempt.finished }
            XCTAssertFalse(attempt.accepted)
            XCTAssertNotNil(attempt.error)
            try await self.waitFor("context failure") { !harness.audit.contextFailures.isEmpty }
            XCTAssertEqual(harness.audit.completedTurns, 1)
            XCTAssertEqual(harness.audit.compactionsCompleted, 0)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            let trace = try harness.trace()
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/inject_items" })
            XCTAssertEqual(trace.messages.filter { $0.method == "turn/start" }.count, 1)
        }
    }

    func testMeasuredUsageBelowThresholdDoesNotCompact() async throws {
        try await withHarness(scenario: "below-threshold") { harness in
            try await harness.completeBaseline()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("below-threshold second submission") { attempt.finished }
            XCTAssertTrue(attempt.accepted, attempt.error ?? "Submission failed.")
            try await self.waitFor("below-threshold second completion") { harness.audit.completedTurns == 2 }
            let trace = try harness.trace()
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/compact/start" })
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/inject_items" })
            XCTAssertEqual(trace.messages.filter { $0.method == "turn/start" }.count, 2)
        }
    }

    func testMeasuredUsageExactlyAtThresholdCompactsBeforeNextTurn() async throws {
        try await withHarness(scenario: "at-threshold") { harness in
            try await harness.completeBaseline()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("at-threshold injection") { harness.markerExists("injection-waiting") }
            XCTAssertEqual(harness.audit.completedTurns, 1)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            try harness.release("release-injection")
            try await self.waitFor("at-threshold submission") { attempt.finished }
            XCTAssertTrue(attempt.accepted, attempt.error ?? "Submission failed.")
            try await self.waitFor("at-threshold completion") { harness.audit.completedTurns == 2 }
            let trace = try harness.trace()
            XCTAssertEqual(trace.messages.filter { $0.method == "thread/compact/start" }.count, 1)
            XCTAssertEqual(trace.messages.filter { $0.method == "thread/inject_items" }.count, 1)
        }
    }

    func testMalformedAcknowledgementDuringActiveMaintenanceRetiresRuntime() async throws {
        try await withHarness(scenario: "malformed-ack") { harness in
            try await harness.completeBaseline()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("malformed acknowledgement rejection") { attempt.finished }
            XCTAssertFalse(attempt.accepted)
            XCTAssertNotNil(attempt.error)
            try await self.waitFor("retired runtime") { harness.audit.connectionFailed }
            XCTAssertEqual(harness.audit.completedTurns, 1)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            let trace = try harness.trace()
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/inject_items" })
            XCTAssertEqual(trace.messages.filter { $0.method == "turn/start" }.count, 1)
        }
    }

    func testUnsolicitedMaintenanceActionsAreDeniedWithoutApprovalThenContinuationSucceeds() async throws {
        try await withHarness(scenario: "unsolicited-maintenance-actions") { harness in
            try await harness.completeBaseline()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("denied maintenance actions and held injection") {
                harness.markerExists("maintenance-denials-received") && harness.markerExists("injection-waiting")
            }
            XCTAssertFalse(attempt.finished)
            XCTAssertEqual(harness.audit.approvalRequests, 0)
            XCTAssertEqual(harness.audit.completedTurns, 1)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))

            let traceBeforeRelease = try harness.trace()
            let statusDenial = try XCTUnwrap(traceBeforeRelease.messages.first {
                $0.direction == .clientToServer && $0.identifier == "string:maintenance-status" && $0.method == nil
            })
            let statusResult = try XCTUnwrap(statusDenial.object["result"] as? [String: Any])
            XCTAssertEqual(statusResult["success"] as? Bool, false)
            let content = try XCTUnwrap(statusResult["contentItems"] as? [[String: String]])
            XCTAssertEqual(content, [["type": "inputText", "text": "Tools cannot run during context maintenance."]])
            let commandDenial = try XCTUnwrap(traceBeforeRelease.messages.first {
                $0.direction == .clientToServer && $0.identifier == "string:maintenance-command" && $0.method == nil
            })
            XCTAssertEqual((commandDenial.object["result"] as? [String: String])?["decision"], "decline")
            let injection = try XCTUnwrap(traceBeforeRelease.messages.first { $0.method == "thread/inject_items" })
            XCTAssertLessThan(statusDenial.sequence, injection.sequence)
            XCTAssertLessThan(commandDenial.sequence, injection.sequence)

            try harness.release("release-injection")
            try await self.waitFor("accepted continuation") { attempt.finished }
            XCTAssertTrue(attempt.accepted, attempt.error ?? "Submission failed.")
            try await self.waitFor("continuation completion") { harness.audit.completedTurns == 2 }
            XCTAssertEqual(harness.audit.approvalRequests, 0)
            XCTAssertEqual(harness.audit.compactionsCompleted, 1)
            XCTAssertTrue(harness.audit.contextFailures.isEmpty)
            XCTAssertEqual(harness.audit.assistantReplies, ["ACTUAL_PRIOR_REPLY", "NEW_REPLY"])
            let finalTrace = try harness.trace()
            XCTAssertEqual(finalTrace.messages.filter { $0.method == "thread/inject_items" }.count, 1)
            XCTAssertEqual(finalTrace.messages.filter { $0.method == "turn/start" }.count, 2)
        }
    }

    func testColdResumeBuffersHighUsageBeforeAcknowledgementThenCompacts() async throws {
        try await assertResumedMaintenance(scenario: "resume-early-high", expectedMeasuredTokens: 6_200)
    }

    func testColdResumeWaitsForDelayedSameTurnHighUsageThenCompacts() async throws {
        try await assertResumedMaintenance(scenario: "resume-delayed-high", expectedMeasuredTokens: 6_200)
    }

    func testColdResumeWrongTurnUsageDoesNotSuppressConservativeCompaction() async throws {
        try await assertResumedMaintenance(scenario: "resume-wrong-turn", expectedMeasuredTokens: nil)
    }

    func testColdResumeAbsentUsageConservativelyCompactsWithUnknownContext() async throws {
        try await assertResumedMaintenance(scenario: "resume-missing", expectedMeasuredTokens: nil)
    }

    func testColdResumeInvalidUsageConservativelyCompactsWithUnknownContext() async throws {
        try await assertResumedMaintenance(scenario: "resume-invalid", expectedMeasuredTokens: nil)
    }

    func testColdResumeMissingPersistedModelDoesNotTrustShortUsage() async throws {
        try await assertResumedMaintenance(scenario: "resume-missing-model", expectedMeasuredTokens: nil)
    }

    func testLargeAssistantFrameSplitAcrossWritesIsDeliveredExactlyOnce() async throws {
        try await assertFragmentedAssistant(closeOutput: false)
    }

    func testLargeAssistantFrameAndTurnTerminalAreDeliveredBeforeImmediateEOF() async throws {
        try await assertFragmentedAssistant(closeOutput: true)
    }

    private func assertFragmentedAssistant(closeOutput: Bool) async throws {
        try await withHarness(scenario: closeOutput ? "fragmented-output-eof" : "fragmented-output") { harness in
            let expected = "FRAGMENTED_REPLY_START\n" + String(repeating: "0123456789abcdef", count: 8_192) + "\nFRAGMENTED_REPLY_END"
            XCTAssertGreaterThan(expected.utf8.count, 128 * 1_024)
            _ = try await harness.runtime.loadTasks()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("fragmented submission acceptance") { attempt.finished }
            XCTAssertTrue(attempt.accepted, attempt.error ?? "Submission failed.")
            try await self.waitFor("fragmented turn terminal") {
                harness.audit.completedTurns == 1 && (!closeOutput || harness.audit.connectionFailed)
            }
            XCTAssertEqual(harness.audit.assistantReplies, [expected])
            XCTAssertEqual(harness.audit.completedTurns, 1)
            XCTAssertTrue(harness.audit.contextFailures.isEmpty)
            XCTAssertEqual(harness.audit.approvalRequests, 0)
            XCTAssertEqual(harness.audit.lastMeasuredTokens, 6_200)
            let assistantEvent = try XCTUnwrap(harness.audit.transportEventOrder.firstIndex(of: "assistant"))
            let completedEvent = try XCTUnwrap(harness.audit.transportEventOrder.firstIndex(of: "completed"))
            XCTAssertLessThan(assistantEvent, completedEvent)
            if closeOutput {
                let failureEvent = try XCTUnwrap(harness.audit.transportEventOrder.firstIndex(of: "connectionFailed"))
                XCTAssertLessThan(completedEvent, failureEvent, "EOF must not overtake queued stdout data or its final terminal.")
            } else {
                XCTAssertFalse(harness.audit.connectionFailed)
            }
            let trace = try harness.trace()
            XCTAssertTrue(trace.parseFailures.isEmpty, "A split JSON-RPC frame must reassemble without malformed fragments.")
            let completedItems = trace.messages.filter { message in
                guard message.direction == .serverToClient, message.method == "item/completed",
                      let params = message.object["params"] as? [String: Any],
                      let item = params["item"] as? [String: Any] else { return false }
                return item["id"] as? String == "large-assistant"
            }
            XCTAssertEqual(completedItems.count, 1)
            let assistant = try XCTUnwrap(completedItems.first)
            let params = try XCTUnwrap(assistant.object["params"] as? [String: Any])
            let item = try XCTUnwrap(params["item"] as? [String: Any])
            XCTAssertEqual(item["text"] as? String, expected)
            let terminals = trace.messages.filter { $0.direction == .serverToClient && $0.method == "turn/completed" }
            XCTAssertEqual(terminals.count, 1)
            XCTAssertLessThan(assistant.sequence, try XCTUnwrap(terminals.first).sequence)
        }
    }

    func testColdResumeKnownShortHistoryDoesNotCompact() async throws {
        try await withHarness(scenario: "resume-short") { harness in
            try await harness.loadResumedTask()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("short resumed submission") { attempt.finished }
            XCTAssertTrue(attempt.accepted, attempt.error ?? "Submission failed.")
            try await self.waitFor("short resumed completion") { harness.audit.completedTurns == 1 }
            XCTAssertEqual(harness.audit.assistantReplies, ["NEW_REPLY"])
            XCTAssertEqual(harness.audit.compactionsCompleted, 0)
            XCTAssertTrue(harness.audit.contextFailures.isEmpty)
            XCTAssertTrue(harness.audit.measuredTokenEvents.contains(3_100))
            let trace = try harness.trace()
            XCTAssertEqual(trace.messages.filter { $0.method == "thread/resume" }.count, 1)
            XCTAssertEqual(trace.messages.filter { $0.method == "turn/start" }.count, 1)
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/start" })
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/compact/start" })
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/inject_items" })
        }
    }

    func testStopDuringColdResumePreventsCompactionAndPromptDelivery() async throws {
        try await withHarness(scenario: "resume-stop") { harness in
            try await harness.loadResumedTask()
            let attempt = harness.startSecondSubmission()
            try await self.waitFor("held resume acknowledgement") { harness.markerExists("resume-waiting") }
            XCTAssertFalse(attempt.finished)
            XCTAssertEqual(harness.audit.completedTurns, 0)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            try await harness.runtime.interrupt(taskID: harness.taskID)
            try harness.release("release-resume")
            try await self.waitFor("cancelled resumed submission") { attempt.finished }
            XCTAssertFalse(attempt.accepted)
            XCTAssertNotNil(attempt.error)
            XCTAssertEqual(harness.audit.completedTurns, 0)
            XCTAssertEqual(harness.audit.compactionsCompleted, 0)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            let trace = try harness.trace()
            XCTAssertEqual(trace.messages.filter { $0.method == "thread/resume" }.count, 1)
            XCTAssertFalse(trace.messages.contains { $0.method == "turn/start" })
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/compact/start" })
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/inject_items" })
        }
    }

    private func assertResumedMaintenance(scenario: String, expectedMeasuredTokens: Int?) async throws {
        try await withHarness(scenario: scenario) { harness in
            try await harness.loadResumedTask()
            let attempt = harness.startSecondSubmission()
            // The external fixture marker alone does not synchronize the
            // MainActor event pump. Core yields resumed usage before the
            // compaction-running event on one FIFO stream; observing both
            // barriers proves the audit consumed that preceding usage event.
            try await self.waitFor("resumed injection and audited compaction barrier") {
                harness.markerExists("injection-waiting") && harness.audit.compactionsStarted > 0
            }
            XCTAssertFalse(attempt.finished)
            XCTAssertEqual(harness.audit.completedTurns, 0, "Resume and maintenance are not completed user turns.")
            XCTAssertEqual(harness.audit.compactionsCompleted, 0)
            XCTAssertFalse(harness.markerExists("second-user-turn-started"))
            if let expectedMeasuredTokens {
                XCTAssertTrue(harness.audit.measuredTokenEvents.contains(expectedMeasuredTokens))
            } else {
                XCTAssertTrue(harness.audit.measuredTokenEvents.isEmpty, "Unproven resumed usage must leave context unknown.")
                XCTAssertNil(harness.audit.lastMeasuredTokens)
            }
            try harness.release("release-injection")
            try await self.waitFor("resumed continuation accepted") { attempt.finished }
            XCTAssertTrue(attempt.accepted, attempt.error ?? "Submission failed.")
            try await self.waitFor("resumed new user turn completed") { harness.audit.completedTurns == 1 }
            XCTAssertEqual(harness.audit.compactionsCompleted, 1)
            XCTAssertEqual(harness.audit.assistantReplies, ["NEW_REPLY"])
            XCTAssertTrue(harness.audit.contextFailures.isEmpty)
            XCTAssertEqual(harness.audit.approvalRequests, 0)

            let trace = try harness.trace()
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/start" })
            let resumes = trace.messages.filter { $0.method == "thread/resume" }
            XCTAssertEqual(resumes.count, 1)
            let resume = try XCTUnwrap(resumes.first)
            let resumeParams = try XCTUnwrap(resume.object["params"] as? [String: Any])
            XCTAssertEqual(resumeParams["threadId"] as? String, "fixture-thread")
            XCTAssertEqual(resumeParams["model"] as? String, harness.modelID)
            let page = try XCTUnwrap(resumeParams["initialTurnsPage"] as? [String: Any])
            XCTAssertEqual(page["limit"] as? Int, 3)
            XCTAssertEqual(page["sortDirection"] as? String, "desc")
            XCTAssertEqual(page["itemsView"] as? String, "full")
            let resumeAck = try XCTUnwrap(trace.messages.first {
                $0.direction == .serverToClient && $0.identifier == resume.identifier && $0.object["result"] != nil
            })
            let compact = try XCTUnwrap(trace.messages.first { $0.method == "thread/compact/start" })
            XCTAssertLessThan(resumeAck.sequence, compact.sequence)
            XCTAssertEqual(trace.messages.filter { $0.method == "thread/compact/start" }.count, 1)
            let injection = try XCTUnwrap(trace.messages.first { $0.method == "thread/inject_items" })
            let injectionAck = try XCTUnwrap(trace.messages.first {
                $0.direction == .serverToClient && $0.identifier == injection.identifier && $0.object["result"] != nil
            })
            let starts = trace.messages.filter { $0.method == "turn/start" }
            XCTAssertEqual(starts.count, 1)
            XCTAssertLessThan(compact.sequence, injection.sequence)
            XCTAssertLessThan(injectionAck.sequence, try XCTUnwrap(starts.first).sequence)
            let params = try XCTUnwrap(injection.object["params"] as? [String: Any])
            let items = try XCTUnwrap(params["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?["role"] as? String, "assistant")
            XCTAssertEqual(items.first?["content"] as? [[String: String]], [["type": "output_text", "text": "ACTUAL_PRIOR_REPLY"]])
            if expectedMeasuredTokens != nil {
                let usage = try XCTUnwrap(trace.messages.first { message in
                    guard message.method == "thread/tokenUsage/updated",
                          let params = message.object["params"] as? [String: Any] else { return false }
                    return params["turnId"] as? String == "resume-prior-turn"
                })
                XCTAssertLessThan(usage.sequence, compact.sequence)
                if scenario == "resume-delayed-high" { XCTAssertLessThan(resumeAck.sequence, usage.sequence) }
                else { XCTAssertLessThan(usage.sequence, resumeAck.sequence) }
            }
        }
    }

    private func withHarness(scenario: String, body: (Harness) async throws -> Void) async throws {
        try XCTSkipUnless((try? FixtureBunExecutable.resolve()) != nil,
            "The deterministic App Server fixture requires the installed Bun executable.")
        let harness = try Harness(scenario: scenario)
        do {
            try await body(harness)
            let report = await harness.runtime.shutdown()
            harness.eventTask?.cancel()
            for attempt in harness.attemptTasks { attempt.cancel() }
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "\n"))
            if report.succeeded && (testRun?.totalFailureCount ?? 0) == 0 {
                try FileManager.default.removeItem(at: harness.root)
            } else {
                // This one isolated fixture contains only bounded synthetic
                // protocol data. Keep it when XCTAssert records a nonthrowing
                // failure so the causal trace is not lost during cleanup.
                print("managedCompactionFailedFixture=\(harness.root.path) scenario=\(scenario)")
            }
        } catch {
            _ = await harness.runtime.shutdown()
            harness.eventTask?.cancel()
            for attempt in harness.attemptTasks { attempt.cancel() }
            print("managedCompactionFailedFixture=\(harness.root.path) scenario=\(scenario)")
            throw error
        }
    }

    private func waitFor(_ description: String, condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure(message: "Timed out waiting for \(description).")
    }

    private struct FixtureFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    private final class SubmissionAttempt {
        var finished = false
        var accepted = false
        var error: String?
    }

    @MainActor
    private final class Harness {
        let root: URL
        let runtime: CodexAppServerRuntime
        let taskID: String
        let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let baselineExpectedTokens: Int
        let audit = Audit()
        var eventTask: Task<Void, Never>?
        var attemptTasks = [Task<Void, Never>]()

        init(scenario: String) throws {
            taskID = scenario.hasPrefix("resume-") ? "fixture-thread" : "managed-compaction-task"
            baselineExpectedTokens = scenario == "below-threshold" ? 6_143 : scenario == "at-threshold" ? 6_144 : 6_200
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaManagedCompaction-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ManagedCompactionAppServer.ts")
            let executable = root.appendingPathComponent("fixture-app-server.ts")
            try FileManager.default.copyItem(at: fixture, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try Data(scenario.utf8).write(to: root.appendingPathComponent("scenario"))
            var configuration = CodexAppServerRuntime.Configuration.localQwen
            configuration.executable = .fixture(path: executable.path)
            configuration.codexHomePath = root.path
            configuration.workspacePath = root.path
            configuration.model = modelID
            // This deterministic fixture emits 6,143 / 6,144 / 6,200-token
            // receipts to test the below / at / above-threshold barriers.
            // Keep that explicit synthetic boundary independent of the
            // shipping model's context budget; live gates check defaults.
            configuration.autoCompactLimitOverride = 6_144
            configuration.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
            runtime = CodexAppServerRuntime(configuration: configuration, visualGrounder: NoModelVisualGrounder())
            eventTask = Task { [weak self, runtime] in
                for await event in runtime.events() {
                    guard let self else { return }
                    self.audit.record(event, taskID: self.taskID)
                }
            }
        }

        func completeBaseline() async throws {
            _ = try await runtime.loadTasks()
            try await runtime.submit(prompt: "FIRST_SYNTHETIC_PROMPT", toTaskID: taskID, modelID: modelID)
            for _ in 0..<800 {
                if audit.completedTurns == 1 {
                    XCTAssertEqual(audit.lastMeasuredTokens, baselineExpectedTokens)
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw FixtureFailure(message: "The deterministic baseline did not complete.")
        }

        func loadResumedTask() async throws {
            let tasks = try await runtime.loadTasks()
            XCTAssertEqual(tasks.map(\.id), [taskID])
            XCTAssertEqual(tasks.first?.model, modelID)
            XCTAssertEqual(audit.completedTurns, 0)
        }

        func startSecondSubmission() -> SubmissionAttempt {
            let attempt = SubmissionAttempt()
            let task = Task {
                do {
                    try await runtime.submit(prompt: "SECOND_SYNTHETIC_PROMPT", toTaskID: taskID, modelID: modelID)
                    attempt.accepted = true
                } catch {
                    attempt.error = error.localizedDescription
                }
                attempt.finished = true
            }
            attemptTasks.append(task)
            return attempt
        }

        func markerExists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }

        func release(_ name: String) throws {
            try Data("release".utf8).write(to: root.appendingPathComponent(name))
        }

        func trace() throws -> AppServerWireTrace {
            let trace = try AppServerWireTrace.load(root.appendingPathComponent("protocol.jsonl"))
            XCTAssertTrue(trace.parseFailures.isEmpty)
            return trace
        }
    }

    @MainActor
    private final class Audit {
        var completedTurns = 0
        var compactionsStarted = 0
        var compactionsCompleted = 0
        var lastMeasuredTokens: Int?
        var measuredTokenEvents = [Int]()
        var lastStatus: TaskStatus?
        var contextFailures = [String]()
        var assistantReplies = [String]()
        var connectionFailed = false
        var approvalRequests = 0
        var transportEventOrder = [String]()

        func record(_ event: AgentRuntimeEvent, taskID: String) {
            switch event {
            case .taskStatusChanged(let owner, let status) where owner == taskID:
                lastStatus = status
                if status == .completed {
                    completedTurns += 1
                    transportEventOrder.append("completed")
                }
            case .contextUsageUpdated(let owner, let usage) where owner == taskID:
                if let usage {
                    lastMeasuredTokens = usage.usedTokens
                    measuredTokenEvents.append(usage.usedTokens)
                }
            case .contextCompactionChanged(let owner, let state) where owner == taskID:
                switch state {
                case .completed: compactionsCompleted += 1
                case .failed(let message): contextFailures.append(message)
                case .running: compactionsStarted += 1
                }
            case .timelineEntryAppended(let owner, let entry) where owner == taskID:
                if entry.kind == .assistant {
                    assistantReplies.append(entry.body)
                    transportEventOrder.append("assistant")
                }
            case .approvalRequested:
                approvalRequests += 1
                XCTFail("A deterministic no-tool fixture must never request desktop approval.")
            case .connectionChanged(.failed):
                connectionFailed = true
                transportEventOrder.append("connectionFailed")
            default: break
            }
        }
    }

    private struct NoModelVisualGrounder: VisualGroundingClient {
        func prepare() async throws {}
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw FixtureFailure(message: "No grounding is allowed in a transport-only test.")
        }
        func shutdown() async -> [String] { [] }
    }
}

import Darwin
import Foundation
import XCTest
@testable import Computa

/// Real owned child-process JSON-RPC, using explicit filesystem barriers so
/// incremental delivery is established before the fixture can finish a reply.
@MainActor
final class RuntimeStreamingTests: XCTestCase {
    func testHistoryTitlesPreserveExplicitNamesAndUseOnlyTheFirstVisibleUserPrompt() throws {
        let prompt = "APP_RUNTIME_literal 🧭 café"
        let history: [String: Any] = ["result": ["thread": ["turns": [
            ["id": "first-turn", "status": "completed", "items": [
                ["id": "first-user", "type": "userMessage", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "text", "text": "APP_RUNTIME_INTERACTION_POLICY: PRIVATE_POLICY_CANARY"]
                ]]
            ]],
            ["id": "later-turn", "status": "completed", "items": [
                ["id": "later-user", "type": "userMessage", "content": [
                    ["type": "text", "text": "Later prompts cannot rename the initial chat"]
                ]]
            ]]
        ]]]]
        let entries = try AppServerThreadHistoryContract.entries(from: JSONSerialization.data(withJSONObject: history))
        let projected = AppServerThreadHistoryContract.displayTitle(name: nil,
            preview: prompt + "APP_RUNTIME_INTERACTION_POLICY: PRIVATE_POLICY_CANARY", entries: entries)
        XCTAssertEqual(projected, prompt)
        XCTAssertFalse(projected.contains("PRIVATE_POLICY_CANARY"))
        XCTAssertEqual(AppServerThreadHistoryContract.displayTitle(name: "  My explicit saved name 🧭  ",
            preview: "Different preview", entries: entries), "My explicit saved name 🧭")
        let long = " \n" + String(repeating: "é🧭", count: 50) + "\t"
        let longEntries = [TimelineEntry(kind: .user, title: "You", body: long)]
        XCTAssertEqual(AppServerThreadHistoryContract.displayTitle(name: nil, preview: "Wrong preview", entries: longEntries),
            String(long.prefix(72)).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(AppServerThreadHistoryContract.displayTitle(name: nil, preview: "  Saved preview  "), "Saved preview")
        XCTAssertEqual(AppServerThreadHistoryContract.displayTitle(name: "  ", preview: nil), "Untitled task")
    }

    func testAssistantPhasesUseOnlyExplicitAuthoritativeMetadataAndPrecedeText() async throws {
        try await withHarness(scenario: "phase-contract") { harness in
            try await harness.submit()
            try await self.waitFor("pre-delta phase fence") { harness.audit.measuredTokens == 1_000 }
            XCTAssertEqual(harness.audit.phases.map { "\($0.itemID):\($0.text)" }, ["commentary:commentary"])
            XCTAssertTrue(harness.audit.deltas.isEmpty, "Phase must be available before the first text delta.")
            XCTAssertTrue(harness.audit.assistant.isEmpty)
            try harness.release("release-phase-text")
            try await self.waitFor("phase terminal fence") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.phases.map { "\($0.itemID):\($0.text)" }, [
                "commentary:commentary", "final:final_answer", "completed-only:final_answer",
            ])
            XCTAssertEqual(harness.audit.assistant.map(\.assistantPhase), [
                "commentary", "final_answer", "final_answer", nil, nil, nil, nil,
            ])
            XCTAssertEqual(harness.audit.assistant.map(\.id), [
                "commentary", "final", "completed-only", "null-phase", "unknown-phase", "numeric-phase", "missing-phase",
            ])
        }
    }

    func testReasoningStreamsBeforeAnswerWithExactIdentityIndexedContentAndSingleFinal() async throws {
        try await withHarness(scenario: "reasoning-progress") { harness in
            try await harness.submit()
            try await self.waitFor("first reasoning update") { harness.audit.reasoningUpdates.count == 1 }
            XCTAssertEqual(harness.audit.reasoningUpdates.map(\.text), ["Consider "])
            XCTAssertEqual(harness.audit.reasoningUpdates.map(\.itemID), ["reasoning-item"])
            XCTAssertTrue(harness.audit.deltas.isEmpty)
            XCTAssertTrue(harness.audit.assistant.isEmpty)
            XCTAssertTrue(harness.audit.reasoning.isEmpty)
            XCTAssertEqual(harness.audit.status, .running)
            XCTAssertFalse(try harness.trace().messages.contains { $0.method == "item/completed" })

            try harness.release("release-reasoning")
            try await self.waitFor("reasoning terminal fence") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.reasoningUpdates.map(\.text), [
                "Consider ", "Consider facts", "Consider facts\n\nCheck facts.",
            ])
            XCTAssertEqual(harness.audit.reasoning.map(\.body), ["Consider facts\n\nCheck facts."])
            XCTAssertEqual(harness.audit.reasoning.map(\.id), ["reasoning-item"])
            XCTAssertEqual(harness.audit.assistant.map(\.body), ["Public answer."])
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Public answer"])
            XCTAssertEqual(harness.audit.status, .completed)
        }
    }

    func testSummaryPartsAccumulateByIndexWithoutDuplicatingRawContentOrEmptyPlaceholder() async throws {
        try await withHarness(scenario: "reasoning-summary") { harness in
            try await harness.submit()
            try await self.waitFor("summary completion") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.reasoningUpdates.map(\.text), [
                "Second", "First\n\nSecond", "First continued\n\nSecond",
            ])
            XCTAssertEqual(harness.audit.reasoning.map(\.body), ["First continued\n\nSecond", ""])
            XCTAssertEqual(harness.audit.assistant.map(\.body), ["Public answer."])
            XCTAssertFalse(harness.audit.reasoning.contains { $0.body == "Reasoning completed." })
        }
    }

    func testTextArrivesBeforeCompletionAndRejectsUncorrelatedOrDuplicateFrames() async throws {
        try await withHarness(scenario: "progress") { harness in
            try await harness.submit()
            try await self.waitFor("first incremental text") { harness.audit.deltas.count == 1 }
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Hello"])
            XCTAssertEqual(harness.audit.deltas.map(\.itemID), ["streamed-answer"])
            XCTAssertTrue(harness.audit.assistant.isEmpty)
            XCTAssertEqual(harness.audit.status, .running)
            XCTAssertFalse(harness.markerExists("item-completed-sent"))
            XCTAssertFalse(try harness.trace().messages.contains { $0.method == "item/completed" })

            try harness.release("release-item")
            try await self.waitFor("item completion fence") { harness.audit.measuredTokens == 1_000 }
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Hello", " world"])
            XCTAssertEqual(harness.audit.assistant.map(\.body), ["Hello world."], "The completed text is authoritative, not appended to its deltas.")
            XCTAssertEqual(harness.audit.assistant.map(\.id), ["streamed-answer"])
            XCTAssertEqual(harness.audit.status, .running)
            XCTAssertFalse(try harness.trace().messages.contains { $0.method == "turn/completed" })

            try harness.release("release-terminal")
            try await self.waitFor("terminal and late-frame fence") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.status, .completed)
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Hello", " world"])
            XCTAssertEqual(harness.audit.assistant.map(\.body), ["Hello world."])
        }
    }

    func testRecoverableErrorKeepsStreamingSameMessageWithoutFalseTerminal() async throws {
        try await withHarness(scenario: "retry") { harness in
            try await harness.submit()
            try await self.waitFor("retry diagnostic") { harness.audit.systemTitles.contains("Model connection retrying") }
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Before "])
            XCTAssertEqual(harness.audit.status, .running)
            let discardsBeforeRetry = harness.audit.discardCount
            try harness.release("release-retry")
            try await self.waitFor("retry completion") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Before ", "after retry"])
            XCTAssertEqual(harness.audit.assistant.map(\.body), ["Before after retry."])
            XCTAssertEqual(harness.audit.status, .completed)
            XCTAssertEqual(harness.audit.discardCount, discardsBeforeRetry)
        }
    }

    func testBlankCompletionReconcilesDraftBeforeToolContinuationAndPreservesDuration() async throws {
        for (scenario, completedText) in [("whitespace-tool", "\n\n"), ("empty-tool", "")] {
            try await withHarness(scenario: scenario) { harness in
                let state = AppState(tasks: [AgentTask(
                    id: harness.taskID, title: "Streaming", summary: "", status: .draft,
                    workspace: harness.root.path, model: harness.modelID
                )], runtime: harness.runtime, preferences: isolatedTestPreferences())
                harness.audit.state = state
                let submitted = await state.submit(prompt: "Synthetic streaming check", toTaskID: harness.taskID)
                XCTAssertTrue(submitted)
                try await self.waitFor("blank item completion fence") { harness.audit.measuredTokens == 1_000 }
                XCTAssertEqual(harness.audit.assistant.map(\.body), [completedText])
                XCTAssertEqual(state.selectedTask?.entries.last?.id, "before-tool")
                XCTAssertEqual(state.selectedTask?.entries.last?.body, completedText)
                XCTAssertNotNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)

                try harness.release("release-tool-answer")
                try await self.waitFor("tool continuation terminal fence") { harness.audit.measuredTokens == 1_001 }
                XCTAssertEqual(state.selectedTask?.status, .completed)
                XCTAssertEqual(harness.audit.assistant.map(\.body), [completedText, "\n\nSTREAM_TOOL_OK"])
                XCTAssertEqual(state.selectedTask?.entries.last?.body, "\n\nSTREAM_TOOL_OK")
                XCTAssertNotNil(state.selectedTask?.entries.last?.workedForSeconds)
                XCTAssertNil(WebUISnapshot(state: state).tasks.first?.activeTurnStartedAt)
                XCTAssertEqual(state.selectedTask?.entries.filter { $0.workedForSeconds != nil }.count, 1)
            }
        }
    }

    func testTerminalErrorDiscardsPartialTextAndRejectsLateProse() async throws {
        try await withHarness(scenario: "terminal-error") { harness in
            try await harness.submit()
            try await self.waitFor("partial text before failure") { harness.audit.deltas.count == 1 }
            let discardsBeforeError = harness.audit.discardCount
            let reasoningDiscardsBeforeError = harness.audit.reasoningDiscardCount
            try harness.release("release-error")
            try await self.waitFor("terminal error fence") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.status, .waiting)
            XCTAssertTrue(harness.audit.systemTitles.contains("Agent error"))
            XCTAssertGreaterThan(harness.audit.discardCount, discardsBeforeError)
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Unfinished text"])
            XCTAssertTrue(harness.audit.assistant.isEmpty)
            XCTAssertEqual(harness.audit.reasoningUpdates.map(\.text), ["Unfinished local reasoning"])
            XCTAssertGreaterThan(harness.audit.reasoningDiscardCount, reasoningDiscardsBeforeError)
            XCTAssertTrue(harness.audit.reasoning.isEmpty)
        }
    }

    func testRetryWithReplacementItemDiscardsAbandonedDraftBeforeNewDeltas() async throws {
        try await withHarness(scenario: "retry-new-item") { harness in
            try await harness.submit()
            try await self.waitFor("replacement retry diagnostic") { harness.audit.systemTitles.contains("Model connection retrying") }
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Abandoned draft"])
            XCTAssertEqual(harness.audit.status, .running)
            let eventOffset = harness.audit.streamingEvents.count
            let discardCount = harness.audit.discardCount
            try harness.release("release-retry")
            try await self.waitFor("abandoned-frame fence") { harness.audit.measuredTokens == 1_000 }
            XCTAssertEqual(harness.audit.discardCount, discardCount + 1)
            XCTAssertEqual(Array(harness.audit.streamingEvents.dropFirst(eventOffset)), [
                "discard", "delta:replacement-answer:Replacement",
            ], "The old draft must be cleared before replacement text becomes visible.")
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Abandoned draft", "Replacement"])
            XCTAssertTrue(harness.audit.assistant.isEmpty, "An abandoned item's late completion must not resurrect its text.")

            try harness.release("release-terminal")
            try await self.waitFor("replacement completion") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.status, .completed)
            XCTAssertEqual(harness.audit.assistant.map(\.id), ["replacement-answer"])
            XCTAssertEqual(harness.audit.assistant.map(\.body), ["Replacement complete."])
            XCTAssertEqual(harness.audit.phases.map { "\($0.itemID):\($0.text)" }, [
                "streamed-answer:commentary", "replacement-answer:final_answer",
            ], "Abandoned item metadata must not resurrect or reclassify a replacement stream.")
        }
    }

    func testInterruptedStreamIsDiscardedAndNextTurnCanStream() async throws {
        try await withHarness(scenario: "interrupt") { harness in
            try await harness.submit()
            try await self.waitFor("partial text before stop") { harness.audit.deltas.count == 1 }
            let discardsBeforeStop = harness.audit.discardCount
            let reasoningDiscardsBeforeStop = harness.audit.reasoningDiscardCount
            try await harness.runtime.interrupt(taskID: harness.taskID)
            try await self.waitFor("interrupted stream fence") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.status, .waiting)
            XCTAssertGreaterThan(harness.audit.discardCount, discardsBeforeStop)
            XCTAssertTrue(harness.audit.assistant.isEmpty)
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Unfinished text"])
            XCTAssertEqual(harness.audit.reasoningUpdates.map(\.text), ["Unfinished local reasoning"])
            XCTAssertGreaterThan(harness.audit.reasoningDiscardCount, reasoningDiscardsBeforeStop)
            XCTAssertTrue(harness.audit.reasoning.isEmpty)

            try await harness.submit()
            try await self.waitFor("fresh turn completion") { harness.audit.measuredTokens == 1_002 }
            XCTAssertEqual(harness.audit.status, .completed)
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Unfinished text", "New turn"])
            XCTAssertEqual(harness.audit.assistant.map(\.body), ["New turn completed."])
            XCTAssertEqual(harness.audit.reasoningUpdates.map(\.text), ["Unfinished local reasoning"])
        }
    }

    func testCompactionAndContextStoppedTurnsNeverStreamMaintenanceOrLateText() async throws {
        try await withHarness(scenario: "context-stop") { harness in
            try await harness.submit()
            try await self.waitFor("partial text before compaction") { harness.audit.deltas.count == 1 }
            let discardsBeforeStop = harness.audit.discardCount
            try harness.release("release-context-stop")
            try await self.waitFor("context stop terminal") { harness.audit.status == .waiting }
            XCTAssertTrue(harness.audit.systemTitles.contains("Context limit reached"))
            XCTAssertGreaterThan(harness.audit.discardCount, discardsBeforeStop)
            XCTAssertEqual(harness.audit.deltas.map(\.text), ["Unfinished text"])
            XCTAssertTrue(harness.audit.assistant.isEmpty)
            XCTAssertEqual(harness.audit.reasoningUpdates.map(\.text), ["Unfinished local reasoning"])
            XCTAssertTrue(harness.audit.reasoning.isEmpty)
            XCTAssertEqual(try harness.trace().messages.filter { $0.method == "turn/interrupt" }.count, 1)
            XCTAssertTrue(harness.audit.phases.isEmpty)
        }
    }

    func testManagedCompactionDoesNotPublishAssistantDeltas() async throws {
        try await withHarness(scenario: "managed-compaction") { harness in
            try await harness.submit()
            try await self.waitFor("baseline completion") { harness.audit.status == .completed }
            let maintenance = Task { try await harness.runtime.compact(taskID: harness.taskID) }
            do {
                try await self.waitFor("held maintenance output") { harness.markerExists("maintenance-delta-sent") }
                try harness.release("release-maintenance")
                try await maintenance.value
                try await self.waitFor("maintenance completed event") { harness.audit.compactionsCompleted == 1 }
                XCTAssertEqual(harness.audit.deltas.map(\.text), ["Baseline"])
                XCTAssertEqual(harness.audit.assistant.map(\.body), ["Baseline."])
                XCTAssertTrue(harness.audit.approvals.isEmpty)
                let deniedData = try Data(contentsOf: harness.root.appendingPathComponent("response-command-maintenance"))
                let denied = try XCTUnwrap(JSONSerialization.jsonObject(with: deniedData) as? [String: Any])
                XCTAssertEqual((denied["result"] as? [String: Any])?["decision"] as? String, "decline")
                XCTAssertTrue(harness.audit.reasoningUpdates.isEmpty)
                XCTAssertTrue(harness.audit.reasoning.isEmpty)
                XCTAssertEqual(harness.audit.phases.map { "\($0.itemID):\($0.text)" }, ["streamed-answer:final_answer"])
            } catch {
                maintenance.cancel()
                throw error
            }
        }
    }

    func testCommandOutputStreamsIntoOneToolRowAndAuthoritativeExitCompletesIt() async throws {
        try await withHarness(scenario: "command-progress") { harness in
            let state = AppState(tasks: [AgentTask(id: harness.taskID, title: "CLI", summary: "",
                status: .draft, workspace: harness.root.path, model: harness.modelID)], runtime: harness.runtime,
                preferences: isolatedTestPreferences())
            harness.audit.state = state
            try await harness.submit()
            try await self.waitFor("command output fence") { harness.audit.measuredTokens == 1_000 }
            let running = try XCTUnwrap(harness.audit.commands.last)
            XCTAssertEqual(running.toolEvent?.status, .running)
            XCTAssertTrue(running.toolEvent?.output?.contains("first output") == true)
            XCTAssertTrue(running.toolEvent?.input.contains("/private/fixture") == true)
            XCTAssertEqual(state.tasks.first?.entries.filter { $0.toolEvent?.name == "commandExecution" }.count, 1)
            try harness.release("release-command")
            try await self.waitFor("command completion fence") { harness.audit.measuredTokens == 1_001 }
            let final = try XCTUnwrap(harness.audit.commands.last)
            XCTAssertEqual(final.toolEvent?.status, .succeeded)
            XCTAssertEqual(final.toolEvent?.output, "authoritative output\nExit code: 0")
            XCTAssertEqual(final.toolEvent?.duration, 0.125)
            XCTAssertEqual(state.tasks.first?.entries.filter { $0.toolEvent?.name == "commandExecution" }.count, 1)
            XCTAssertFalse(harness.audit.commands.contains { $0.toolEvent?.output?.contains("WRONG_TURN") == true
                || $0.toolEvent?.output?.contains("UNKNOWN_ITEM") == true
                || $0.toolEvent?.output?.contains("DUPLICATE_FINAL") == true
                || $0.toolEvent?.output?.contains("AFTER_") == true })
        }
    }

    func testCommandApprovalsRequireExactActiveTurnAndRetainAcceptDeclineDecisions() async throws {
        for approved in [false, true] {
            try await withHarness(scenario: "command-approval") { harness in
                try await harness.submit()
                try await self.waitFor("only current command approval") { harness.audit.approvals.count == 1 }
                XCTAssertEqual(harness.audit.approvals[0].kind, .command)
                XCTAssertEqual(harness.audit.approvals[0].summary, "printf fixture")
                try await harness.runtime.resolveApproval(requestID: harness.audit.approvals[0].id, approved: approved)
                try await self.waitFor("command approval completion") { harness.audit.measuredTokens == 1_001 }
                for name in ["command-wrong-turn", "command-wrong-thread", "command-missing-turn"] {
                    let data = try Data(contentsOf: harness.root.appendingPathComponent("response-" + name))
                    let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    XCTAssertEqual((response["result"] as? [String: Any])?["decision"] as? String, "decline")
                }
                let final = try XCTUnwrap(harness.audit.commands.last)
                XCTAssertEqual(final.toolEvent?.status, approved ? .succeeded : .failed)
                XCTAssertTrue(final.toolEvent?.output?.contains(approved ? "Exit code: 0" : "Declined") == true)
                XCTAssertEqual(harness.audit.approvals.count, 1)
            }
        }
    }

    func testStopAndDisconnectRetireCommandOutputWithoutInventingAnExitCode() async throws {
        for scenario in ["command-stop", "command-disconnect"] {
            try await withHarness(scenario: scenario) { harness in
                try await harness.submit()
                try await self.waitFor("running command") { harness.audit.measuredTokens == 1_000 }
                if scenario == "command-stop" {
                    try await harness.runtime.interrupt(taskID: harness.taskID)
                    try await self.waitFor("stopped command fence") { harness.audit.measuredTokens == 1_001 }
                    XCTAssertTrue(harness.markerExists("terminated-4321"))
                    XCTAssertTrue(harness.markerExists("terminated-4322"))
                    XCTAssertFalse(harness.markerExists("terminated-9999"))
                    try await self.waitFor("host cleanup confirmation") { harness.audit.systemTitles.contains("Command cleanup") }
                } else {
                    try harness.release("release-command")
                    try await self.waitFor("disconnected command") {
                        harness.audit.commands.last?.toolEvent?.output?.contains("Runtime disconnected") == true
                    }
                }
                let final = try XCTUnwrap(harness.audit.commands.last)
                XCTAssertEqual(final.toolEvent?.status, .failed)
                XCTAssertTrue(final.toolEvent?.output?.contains("unconfirmed") == true)
                XCTAssertFalse(final.toolEvent?.output?.contains("Exit code: 0") == true)
                XCTAssertFalse(harness.audit.commands.contains { $0.toolEvent?.output?.contains("AFTER_STOP") == true })
                XCTAssertTrue(harness.audit.approvals.isEmpty)
            }
        }
    }

    func testGracefulShutdownCleansOnlyOwnedCommandSessionsAcrossInventoryPages() async throws {
        try await withHarness(scenario: "command-shutdown") { harness in
            try await harness.submit()
            try await self.waitFor("running shutdown commands") { harness.audit.measuredTokens == 1_000 }
            let report = await harness.runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            XCTAssertTrue(harness.markerExists("terminated-4321"))
            XCTAssertTrue(harness.markerExists("terminated-4322"))
            XCTAssertFalse(harness.markerExists("terminated-9999"))
            XCTAssertTrue(harness.audit.approvals.isEmpty)
            XCTAssertFalse(harness.audit.commands.contains { $0.toolEvent?.output?.contains("AFTER_STOP") == true })
        }
    }

    func testTerminalCommandFailureCleansOwnedSessionBeforePublishingWaiting() async throws {
        for scenario in ["command-terminal-error", "command-terminal-failed", "command-terminal-interrupted"] {
            try await withHarness(scenario: scenario) { harness in
                try await harness.submit()
                try await self.waitFor("running command") { harness.audit.measuredTokens == 1_000 }
                XCTAssertEqual(harness.audit.status, .running)
                XCTAssertFalse(harness.markerExists("command-cleanup-requested"), "Retrying and foreign-turn errors cannot revoke a command")
                try harness.release("release-command-failure")
                try await self.waitFor("terminal error processed") { harness.audit.measuredTokens == 1_001 }
                try await self.waitFor("cleanup admission or premature idle") {
                    harness.markerExists("command-cleanup-requested") || harness.audit.status == .waiting
                }
                XCTAssertEqual(harness.audit.status, .running, "A terminal error must await owned command cleanup before exposing an idle task")
                let requested = harness.markerExists("command-cleanup-requested")
                XCTAssertTrue(requested, "Terminal errors must inventory surviving native exec_command sessions")
                XCTAssertFalse(harness.markerExists("terminated-4321"))
                if requested {
                    do { try await harness.submit(); XCTFail("New input must wait for failed-turn command cleanup") }
                    catch { XCTAssertTrue(error.localizedDescription.contains("command cleanup")) }
                }
                try harness.release("release-command-cleanup")
                if requested {
                    try await self.waitFor("terminal command cleanup") { harness.audit.systemTitles.contains("Command cleanup") }
                    try await self.waitFor("waiting after command cleanup") { harness.audit.status == .waiting }
                    XCTAssertTrue(harness.markerExists("terminated-4321"))
                    XCTAssertFalse(harness.markerExists("terminated-4322"))
                    XCTAssertFalse(harness.markerExists("terminated-9999"))
                    XCTAssertFalse(harness.audit.commands.contains { $0.toolEvent?.output?.contains("Exit code: 0") == true })
                    let trace = try harness.trace()
                    XCTAssertEqual(trace.messages.filter { $0.method == "thread/backgroundTerminals/terminate" }.count, 1,
                        "An error followed by turn/completed must not terminate twice")
                }
            }
        }
    }

    func testCompactionCannotSupersedeHeldFailedTurnCommandCleanup() async throws {
        try await withHarness(scenario: "command-terminal-error") { harness in
            try await harness.submit()
            try await self.waitFor("running command") { harness.audit.measuredTokens == 1_000 }
            try harness.release("release-command-failure")
            try await self.waitFor("held failed-turn cleanup") { harness.markerExists("command-cleanup-requested") }
            XCTAssertEqual(harness.audit.status, .running)
            // If admission regresses, keep the artificial maintenance finite so
            // the negative test can record the unexpected RPC and shut down.
            try harness.release("release-maintenance")
            do {
                try await harness.runtime.compact(taskID: harness.taskID)
                XCTFail("Compaction must wait for failed-turn command cleanup")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("command cleanup"), error.localizedDescription)
            }
            XCTAssertFalse(try harness.trace().messages.contains { $0.method == "thread/compact/start" },
                "Rejected maintenance cannot replace the failed turn's cleanup identity")
            try harness.release("release-command-cleanup")
            try await self.waitFor("cleanup completion") { harness.audit.status == .waiting }
        }
    }

    func testFailedTurnCommandCleanupPreservesSuccessfulPriorTurnSession() async throws {
        try await withHarness(scenario: "command-terminal-prior") { harness in
            try await harness.submit()
            try await self.waitFor("successful background turn") { harness.audit.measuredTokens == 1_001 }
            XCTAssertFalse(harness.markerExists("command-cleanup-requested"))
            try await harness.submit()
            try await self.waitFor("new turn command") { harness.audit.measuredTokens == 1_002 }
            try harness.release("release-command-failure")
            try await self.waitFor("failed-turn inventory held") { harness.markerExists("command-cleanup-requested") }
            XCTAssertEqual(harness.audit.status, .running)
            try harness.release("release-command-cleanup")
            try await self.waitFor("failed-turn cleanup done") { harness.audit.status == .waiting }
            XCTAssertTrue(harness.markerExists("terminated-4322"))
            XCTAssertFalse(harness.markerExists("terminated-4321"), "The failed turn cannot terminate a successful earlier turn's background session")
            XCTAssertFalse(harness.markerExists("terminated-9999"))
            try await harness.runtime.interrupt(taskID: harness.taskID)
            XCTAssertTrue(harness.markerExists("terminated-4321"), "Explicit task Stop can still clean the earlier owned session")
        }
    }

    func testUnconfirmedFailedTurnCommandCleanupIsReportedBeforeWaitingAndCanRetryStop() async throws {
        try await withHarness(scenario: "command-terminal-refused") { harness in
            try await harness.submit()
            try await self.waitFor("running command") { harness.audit.measuredTokens == 1_000 }
            try harness.release("release-command-failure")
            try await self.waitFor("held cleanup") { harness.markerExists("command-cleanup-requested") }
            XCTAssertEqual(harness.audit.status, .running)
            try harness.release("release-command-cleanup")
            try await self.waitFor("unconfirmed cleanup") { harness.audit.status == .waiting }
            XCTAssertTrue(harness.audit.systemTitles.contains("Command cleanup unconfirmed"))
            XCTAssertFalse(harness.audit.systemTitles.contains("Command cleanup"))
            XCTAssertFalse(harness.markerExists("terminated-4321"))
            try await harness.runtime.interrupt(taskID: harness.taskID)
            XCTAssertTrue(harness.markerExists("terminated-4321"))
            XCTAssertFalse(harness.markerExists("terminated-4322"))
            XCTAssertFalse(harness.markerExists("terminated-9999"))
        }
    }

    func testTerminalCommandNotificationWaitsForInFlightStopCleanupResult() async throws {
        for scenario in ["command-terminal-stop", "command-terminal-stop-refused"] {
            try await withHarness(scenario: scenario) { harness in
                try await harness.submit()
                try await self.waitFor("running command") { harness.audit.measuredTokens == 1_000 }
                let stop = Task { try await harness.runtime.interrupt(taskID: harness.taskID) }
                try await self.waitFor("Stop inventory held after terminal notification") {
                    harness.markerExists("command-cleanup-requested") && harness.audit.measuredTokens == 1_001
                }
                XCTAssertEqual(harness.audit.status, .running)
                try harness.release("release-command-cleanup")
                if scenario.hasSuffix("refused") {
                    do { try await stop.value; XCTFail("Stop must report the unconfirmed cleanup") }
                    catch { XCTAssertTrue(error.localizedDescription.contains("termination")) }
                    try await self.waitFor("terminal cleanup failure") { harness.audit.status == .waiting }
                    XCTAssertTrue(harness.audit.systemTitles.contains("Command cleanup unconfirmed"))
                    XCTAssertFalse(harness.markerExists("terminated-4321"))
                } else {
                    try await stop.value
                    try await self.waitFor("terminal cleanup success") { harness.audit.status == .waiting }
                    XCTAssertTrue(harness.audit.systemTitles.contains("Command cleanup"))
                    XCTAssertTrue(harness.markerExists("terminated-4321"))
                }
                XCTAssertEqual(try harness.trace().messages.filter { $0.method == "thread/backgroundTerminals/terminate" }.count, 1)
                XCTAssertFalse(harness.markerExists("terminated-4322"))
                XCTAssertFalse(harness.markerExists("terminated-9999"))
            }
        }
    }

    func testCompletedTurnPreservesOwnedBackgroundCommandForLaterStop() async throws {
        try await withHarness(scenario: "command-background") { harness in
            try await harness.submit()
            try await self.waitFor("completed background turn") { harness.audit.measuredTokens == 1_001 }
            XCTAssertEqual(harness.audit.commands.last?.toolEvent?.status, .running)
            try await harness.runtime.interrupt(taskID: harness.taskID)
            try await self.waitFor("completed-turn cleanup presentation") { harness.audit.systemTitles.contains("Command cleanup") }
            XCTAssertEqual(harness.audit.commands.last?.toolEvent?.status, .failed)
            XCTAssertTrue(harness.audit.commands.last?.toolEvent?.output?.contains("final exit status unconfirmed") == true)
            XCTAssertTrue(harness.markerExists("terminated-4321"))
            XCTAssertFalse(harness.markerExists("terminated-4322"))
            XCTAssertFalse(harness.markerExists("terminated-9999"))
        }
    }

    func testOwnedCommandCompletionSurvivesTurnEndNewTurnAndCompaction() async throws {
        for scenario in ["command-late-completion", "command-late-new-turn", "command-compaction"] {
            try await withHarness(scenario: scenario) { harness in
                try await harness.submit()
                try await self.waitFor("background turn completed") { harness.audit.measuredTokens == 1_001 }
                if scenario == "command-late-new-turn" {
                    try await harness.submit()
                    try await self.waitFor("successor turn completed") { harness.audit.measuredTokens == 1_002 }
                }
                if scenario == "command-compaction" {
                    let maintenance = Task { try await harness.runtime.compact(taskID: harness.taskID) }
                    try await self.waitFor("owned exit during compaction") { harness.audit.commands.last?.toolEvent?.status == .succeeded }
                    try harness.release("release-maintenance")
                    try await maintenance.value
                    XCTAssertTrue(harness.audit.commands.last?.toolEvent?.output?.contains("compaction-time output") == true)
                    XCTAssertTrue(harness.audit.approvals.isEmpty)
                } else {
                    try harness.release("release-late-command")
                    try await self.waitFor("delayed owned completion") { harness.audit.commands.last?.toolEvent?.output?.contains("Exit code: 7") == true }
                    XCTAssertEqual(harness.audit.commands.last?.toolEvent?.status, .failed)
                    XCTAssertFalse(harness.audit.commands.contains { $0.toolEvent?.output?.contains("UNOWNED_LATE") == true })
                }
                XCTAssertEqual(Set(harness.audit.commands.map(\.id)), ["command-item"])
            }
        }
    }

    func testStopCleansOwnedSessionsWhenTurnFinishesBeforeInterruptReply() async throws {
        try await withHarness(scenario: "command-raced-stop") { harness in
            try await harness.submit()
            try await self.waitFor("racing running command") { harness.audit.measuredTokens == 1_000 }
            try await harness.runtime.interrupt(taskID: harness.taskID)
            XCTAssertTrue(harness.markerExists("terminated-4321"))
            XCTAssertFalse(harness.markerExists("terminated-4322"))
            XCTAssertFalse(harness.markerExists("terminated-9999"))
            XCTAssertFalse(harness.audit.commands.contains { $0.toolEvent?.status == .succeeded })
        }
    }

    func testCommandTranscriptBoundsUTF8AndNeverTreatsUnknownExitAsSuccess() throws {
        var transcript = AppServerCommandTranscript()
        let item: [String: Any] = ["id": "command", "type": "commandExecution", "command": "fixture",
                                   "cwd": "/tmp", "status": "inProgress"]
        XCTAssertEqual(transcript.receive(item: item, completed: false)?.toolEvent?.status, .running)
        let output = String(repeating: "é", count: 20_000)
        let clipped = try XCTUnwrap(transcript.append(itemID: "command", delta: output))
        XCTAssertTrue(clipped.toolEvent?.output?.contains("Output truncated") == true)
        XCTAssertLessThan(clipped.toolEvent!.output!.utf8.count, AppServerCommandTranscript.maximumOutputBytes + 128)
        XCTAssertNil(transcript.append(itemID: "command", delta: "discarded"))
        var done = item; done["status"] = "completed"; done["exitCode"] = true
        let final = try XCTUnwrap(transcript.receive(item: done, completed: true))
        XCTAssertEqual(final.toolEvent?.status, .failed)
        XCTAssertTrue(final.toolEvent?.output?.contains("Exit status unavailable") == true)
        XCTAssertNil(transcript.receive(item: done, completed: true))
        XCTAssertNil(transcript.append(itemID: "command", delta: "late"))
        for (status, exit) in [("completed", 7), ("failed", 0), ("unknown", 0)] {
            var other = AppServerCommandTranscript(); var failed = item
            failed["status"] = status; failed["exitCode"] = exit
            XCTAssertEqual(other.receive(item: failed, completed: true)?.toolEvent?.status, .failed)
        }
    }

    @MainActor
    private final class Audit {
        struct Delta {
            let itemID: String
            let text: String
        }
        var deltas = [Delta]()
        var phases = [Delta]()
        var assistant = [TimelineEntry]()
        var commands = [TimelineEntry]()
        var approvals = [ActionApprovalRequest]()
        var reasoning = [TimelineEntry]()
        var reasoningUpdates = [Delta]()
        var reasoningDiscardCount = 0
        var systemTitles = [String]()
        var discardCount = 0
        var status: TaskStatus?
        var measuredTokens: Int?
        var compactionsCompleted = 0
        var streamingEvents = [String]()
        var state: AppState?

        func record(_ event: AgentRuntimeEvent, taskID: String) {
            state?.apply(event)
            switch event {
            case .assistantMessagePhaseUpdated(let id, let itemID, let phase) where id == taskID:
                phases.append(Delta(itemID: itemID, text: phase))
            case .reasoningMessageUpdated(let id, let itemID, let text) where id == taskID:
                reasoningUpdates.append(Delta(itemID: itemID, text: text))
            case .reasoningMessagesDiscarded(let id) where id == taskID:
                reasoningDiscardCount += 1
            case .assistantMessageDelta(let id, let itemID, let delta) where id == taskID:
                deltas.append(Delta(itemID: itemID, text: delta))
                streamingEvents.append("delta:\(itemID):\(delta)")
            case .assistantMessagesDiscarded(let id) where id == taskID:
                discardCount += 1
                streamingEvents.append("discard")
            case .timelineEntryAppended(let id, let entry) where id == taskID:
                if entry.kind == .assistant { assistant.append(entry) }
                if entry.toolEvent?.name == "commandExecution" { commands.append(entry) }
                if entry.kind == .reasoning { reasoning.append(entry) }
                if entry.kind == .system { systemTitles.append(entry.title) }
            case .approvalRequested(let request) where request.taskID == taskID:
                approvals.append(request)
            case .taskStatusChanged(let id, let value) where id == taskID:
                status = value
            case .contextUsageUpdated(let id, let usage) where id == taskID:
                measuredTokens = usage?.usedTokens
            case .contextCompactionChanged(let id, .completed) where id == taskID:
                compactionsCompleted += 1
            default: break
            }
        }
    }

    @MainActor
    private final class Harness {
        let taskID: String
        let modelID: String
        let root: URL
        let rootDevice: dev_t
        let rootInode: ino_t
        let runtime: CodexAppServerRuntime
        let audit = Audit()
        var eventTask: Task<Void, Never>?

        init(scenario: String, websiteModel: Bool = false) throws {
            taskID = websiteModel ? UUID().uuidString.lowercased() : "streaming-task"
            modelID = websiteModel
                ? WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID
                : "lmstudio-community/Qwen3.5-4B-MLX-4bit"
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ComputaStreaming-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            var identity = stat()
            guard root.path.withCString({ Darwin.lstat($0, &identity) }) == 0,
                  (identity.st_mode & S_IFMT) == S_IFDIR else { throw POSIXError(.EINVAL) }
            rootDevice = identity.st_dev
            rootInode = identity.st_ino
            print("fixtureOwned kind=runtime_streaming path=\(root.path) device=\(rootDevice) inode=\(rootInode)")
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/StreamingAppServer.ts")
            let fixture = root.appendingPathComponent("fixture.ts")
            if websiteModel {
                var script = try String(contentsOf: source, encoding: .utf8)
                let thread = "const threadId = 'streaming-thread';"
                let turn = "const turnId = currentTurn = `streaming-turn-${++turnCount}`;"
                guard script.components(separatedBy: thread).count == 2,
                      script.components(separatedBy: turn).count == 2 else {
                    throw NSError(domain: "StreamingFixtureShape", code: 1)
                }
                script = script.replacingOccurrences(of: "#!/usr/bin/env bun\n", with: "#!/usr/bin/env bun\nimport { randomUUID } from 'node:crypto';\n")
                    .replacingOccurrences(of: thread, with: "const threadId = randomUUID();")
                    .replacingOccurrences(of: turn, with: "const turnId = currentTurn = (++turnCount, randomUUID());")
                try Data(script.utf8).write(to: fixture)
            } else { try FileManager.default.copyItem(at: source, to: fixture) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
            try Data(scenario.utf8).write(to: root.appendingPathComponent("scenario"))
            var configuration = CodexAppServerRuntime.Configuration.localQwen
            configuration.executable = .fixture(path: fixture.path)
            configuration.codexHomePath = root.path
            configuration.workspacePath = root.path
            configuration.model = modelID
            configuration.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
            runtime = CodexAppServerRuntime(configuration: configuration, visualGrounder: NoModelVisualGrounder())
            eventTask = Task { [weak self, runtime] in
                for await event in runtime.events() {
                    guard let self else { return }
                    self.audit.record(event, taskID: self.taskID)
                }
            }
        }

        func submit(prompt: String = "Synthetic text-only streaming check. Do not use tools.") async throws {
            try await runtime.submit(prompt: prompt, toTaskID: taskID, modelID: modelID)
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

        func removeFixtureAfterVerifiedShutdown() -> String? {
            var identity = stat()
            guard root.path.withCString({ Darwin.lstat($0, &identity) }) == 0,
                  (identity.st_mode & S_IFMT) == S_IFDIR,
                  identity.st_dev == rootDevice, identity.st_ino == rootInode else {
                return "Fixture identity changed; refusing removal of \(root.path)."
            }
            return OwnedProfileCleanup.removeAndVerify(root, operations: .live)
        }
    }

    private struct NoModelVisualGrounder: VisualGroundingClient {
        func prepare() async throws {}
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw NSError(domain: "NoGroundingInStreamingFixture", code: 1)
        }
        func shutdown() async -> [String] { [] }
    }

    private func withHarness(scenario: String, websiteModel: Bool = false, _ body: (Harness) async throws -> Void) async throws {
        let failuresBefore = testRun?.failureCount ?? 0
        let harness = try Harness(scenario: scenario, websiteModel: websiteModel)
        do {
            _ = try await harness.runtime.loadTasks()
            try await body(harness)
            let report = await harness.runtime.shutdown()
            harness.eventTask?.cancel()
            await harness.eventTask?.value
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            guard report.succeeded, (testRun?.failureCount ?? 0) == failuresBefore else {
                print("fixtureCleanupPreserved kind=runtime_streaming path=\(harness.root.path) reason=test_or_shutdown_failed")
                return
            }
            if let issue = harness.removeFixtureAfterVerifiedShutdown() {
                XCTFail("Fixture cleanup failed: \(String(issue.prefix(1_024)))")
            } else {
                print("fixtureCleanupVerified kind=runtime_streaming path=\(harness.root.path) device=\(harness.rootDevice) inode=\(harness.rootInode)")
            }
        } catch {
            let report = await harness.runtime.shutdown()
            harness.eventTask?.cancel()
            await harness.eventTask?.value
            print("fixtureCleanupPreserved kind=runtime_streaming path=\(harness.root.path) shutdownVerified=\(report.succeeded) reason=\(String(error.localizedDescription.prefix(512)))")
            throw error
        }
    }

    private func waitFor(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(label)")
        throw NSError(domain: "RuntimeStreamingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }
}

// A website-free admission probe. Reaching this transport proves the real
// WebModelServer accepted the exact native thread/turn context. A failed owned
// startup and exact-token cleanup avoid authorizing any website action.
private struct InitialNameProbeTransport: WebModelTransport {
    let root: URL
    private let token = UUID().uuidString.lowercased()
    init(root: URL) { self.root = root }
    func request(operation: String, params: Data) async throws -> Data {
        if operation == "webProviderStart" {
            try Data("admitted".utf8).write(to: root.appendingPathComponent("website-transport-entered"))
            return try JSONSerialization.data(withJSONObject: ["sessionToken": token, "state": "failed"])
        }
        guard ["webProviderCancel", "webProviderFinish"].contains(operation),
              let args = try JSONSerialization.jsonObject(with: params) as? [String: String],
              args["sessionToken"] == token else { throw WebModelServer.Failure.invalidRequest }
        return try JSONSerialization.data(withJSONObject: ["cleanup": "not_created"])
    }
}

import Foundation
import XCTest
@testable import Mactopus

/// Real owned child-process JSON-RPC, using explicit filesystem barriers so
/// incremental delivery is established before the fixture can finish a reply.
@MainActor
final class RuntimeStreamingTests: XCTestCase {
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
                XCTAssertTrue(harness.audit.reasoningUpdates.isEmpty)
                XCTAssertTrue(harness.audit.reasoning.isEmpty)
                XCTAssertEqual(harness.audit.phases.map { "\($0.itemID):\($0.text)" }, ["streamed-answer:final_answer"])
            } catch {
                maintenance.cancel()
                throw error
            }
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
                if entry.kind == .reasoning { reasoning.append(entry) }
                if entry.kind == .system { systemTitles.append(entry.title) }
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
        let taskID = "streaming-task"
        let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let root: URL
        let runtime: CodexAppServerRuntime
        let audit = Audit()
        var eventTask: Task<Void, Never>?

        init(scenario: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusStreaming-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/StreamingAppServer.ts")
            let fixture = root.appendingPathComponent("fixture.ts")
            try FileManager.default.copyItem(at: source, to: fixture)
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

        func submit() async throws {
            try await runtime.submit(prompt: "Synthetic text-only streaming check. Do not use tools.", toTaskID: taskID, modelID: modelID)
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

    private struct NoModelVisualGrounder: VisualGroundingClient {
        func prepare() async throws {}
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw NSError(domain: "NoGroundingInStreamingFixture", code: 1)
        }
        func shutdown() async -> [String] { [] }
    }

    private func withHarness(scenario: String, _ body: (Harness) async throws -> Void) async throws {
        let harness = try Harness(scenario: scenario)
        do {
            _ = try await harness.runtime.loadTasks()
            try await body(harness)
            let report = await harness.runtime.shutdown()
            harness.eventTask?.cancel()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        } catch {
            _ = await harness.runtime.shutdown()
            harness.eventTask?.cancel()
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

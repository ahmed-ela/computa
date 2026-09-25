import Foundation
import XCTest
@testable import HeyDash

/// Explicit opt-in only. Uses synthetic text in an isolated Codex home and
/// never clicks, types, changes permissions, or modifies an existing thread.
@MainActor
final class RuntimeContextLiveTests: XCTestCase {
    func testProductionAutoCompactionPreservesCanaryAndContinuesReadOnlyToolUse() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_AUTO_COMPACTION_TEST"] == "1",
            "Set HEYDASH_LIVE_AUTO_COMPACTION_TEST=1 to test the real production compaction threshold.")
        try await runFixture(manual: false)
    }

    func testManualCompactionConfirmsLifecycleAndRetainsCanary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_MANUAL_COMPACTION_TEST"] == "1",
            "Set HEYDASH_LIVE_MANUAL_COMPACTION_TEST=1 to test explicit native compaction.")
        try await runFixture(manual: true)
    }

    func testUncompactedControlRetainsCanaryAfterReadOnlyToolUse() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_CONTEXT_BASELINE_TEST"] == "1",
            "Set HEYDASH_LIVE_CONTEXT_BASELINE_TEST=1 for the identical no-compaction model-quality control.")
        try await runFixture(manual: true, baseline: true)
    }

    func testOversizedRetainedInputStopsWithoutCompactionLoop() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_OVERSIZED_CONTEXT_TEST"] == "1",
            "Set HEYDASH_LIVE_OVERSIZED_CONTEXT_TEST=1 to verify bounded failure on oversized retained user input.")
        let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeyDashOversizedContext-\(UUID().uuidString)")
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.model = modelID
        configuration.codexHomePath = root.path
        configuration.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
        let runtime = CodexAppServerRuntime(configuration: configuration)
        let taskID = "oversized-context"
        let audit = Audit()
        audit.acceptExpectedContextFailure = true
        let eventTask = Task { @MainActor in
            for await event in runtime.events() {
                audit.record(event, taskID: taskID)
                if case .approvalRequested(let request) = event {
                    audit.failures.append("Unexpected approval request in oversized read-only fixture: \(request.title)")
                    try? await runtime.resolveApproval(requestID: request.id, approved: false)
                }
            }
        }
        defer { eventTask.cancel() }
        do {
            _ = try await runtime.loadTasks()
            try await send("Reply only READY; do not use tools.", runtime: runtime, audit: audit, taskID: taskID, modelID: modelID)
            let priorCompleted = audit.completedTurns
            let padding = String(repeating: "alpha beta gamma delta. ", count: 2_000)
            try await runtime.submit(prompt: "Disposable retained-input boundary fixture: \(padding) Reply only READ. Do not use tools.",
                toTaskID: taskID, modelID: modelID)
            try await waitUntil("oversized input first terminal", audit: audit) {
                audit.lastStatus == .waiting || audit.completedTurns > priorCompleted
            }
            if audit.contextFailures.isEmpty {
                audit.lastStatus = nil
                do {
                    try await runtime.submit(prompt: "Reply only CONTINUED. Do not use tools.", toTaskID: taskID, modelID: modelID)
                } catch {
                    // A preflight compaction fails the pending submission before
                    // turn/start; native in-turn fallback reports asynchronously.
                    // Both must still prove the exact correlated stop below.
                    try await waitUntil("failed preflight context guard", audit: audit) {
                        !audit.contextFailures.isEmpty && audit.lastStatus == .waiting
                    }
                }
            }
            try await waitUntil("context guard correlated interrupt terminal", audit: audit) {
                !audit.contextFailures.isEmpty && audit.lastStatus == .waiting
            }
            XCTAssertLessThanOrEqual(audit.compactionsStarted, 3)
            XCTAssertFalse(audit.contextFailures.isEmpty)
            XCTAssertEqual(audit.lastStatus, .waiting)
            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded)
            let trace = try AppServerWireTrace.load(root.appendingPathComponent("protocol.jsonl"))
            XCTAssertTrue(trace.messages.contains { $0.method == "turn/interrupt" })
            XCTAssertLessThanOrEqual(trace.messages.filter { $0.method == "thread/compact/start" }.count, 1)
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/inject_items" },
                "Failed oversized maintenance cannot restore history or admit another prompt.")
            XCTAssertLessThanOrEqual(trace.messages.filter { $0.method == "turn/start" }.count, 2)
            print("oversizedContextFailedClosed=true\ncompactionsStarted=\(audit.compactionsStarted)\nprotocolTrace=\(root.path)/protocol.jsonl")
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    private func runFixture(manual: Bool, baseline: Bool = false) async throws {
        let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeyDashContextLive-\(UUID().uuidString)", isDirectory: true)
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.model = modelID
        configuration.codexHomePath = root.path
        configuration.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
        // Intentionally no autoCompactLimitOverride: this proves the shipping
        // 6,144 / 8,192 policy rather than an artificially lowered test trigger.
        print("contextFixtureMode=\(baseline ? "uncompacted-control" : manual ? "manual" : "production-auto")\nprotocolTrace=\(root.path)/protocol.jsonl")
        let runtime = CodexAppServerRuntime(configuration: configuration)
        let audit = Audit()
        let taskID = "context-fixture-\(UUID().uuidString)"
        let eventTask = Task { @MainActor in
            for await event in runtime.events() {
                audit.record(event, taskID: taskID)
                if case .approvalRequested(let request) = event {
                    audit.failures.append("Unexpected approval request in read-only fixture: \(request.title)")
                    try? await runtime.resolveApproval(requestID: request.id, approved: false)
                }
            }
        }
        defer { eventTask.cancel() }
        do {
            _ = try await runtime.loadTasks()
            let canary = "HD_KEEP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try await send("Remember this important retention key for this task: \(canary). "
                + "Preserve this exact key in any future context summary. Reply only KEY_SAVED; do not use tools.",
                runtime: runtime, audit: audit, taskID: taskID, modelID: modelID)

            if baseline {
                // Same retention/tool instructions, without summarization: this
                // separates model instruction-following from compaction defects.
            } else if manual {
                try await runtime.compact(taskID: taskID)
                try await waitUntil("manual compaction lifecycle", audit: audit) {
                    audit.compactionsCompleted > 0 && audit.lastStatus == .completed
                }
            } else {
                for round in 1...3 where audit.compactionsCompleted == 0 {
                    // Keep user messages short: native compaction intentionally
                    // retains user input. Disposable assistant output can shrink.
                    try await send("For benchmark round \(round), generate exactly 120 numbered lines. Each line must contain ten plain words describing a fictional park. "
                        + "This generated text is disposable. Keep the original retention key in memory but do not repeat it here. Do not use tools.",
                        runtime: runtime, audit: audit, taskID: taskID, modelID: modelID)
                }
                // A native pre-turn trigger may begin on the following request.
                if audit.compactionsCompleted == 0 {
                    try await send("Keep the original retention key. Reply only CONTINUE_READY; do not use tools.",
                        runtime: runtime, audit: audit, taskID: taskID, modelID: modelID)
                }
                XCTAssertGreaterThan(audit.compactionsCompleted, 0, "Production native auto-compaction did not trigger.")
                guard audit.compactionsCompleted > 0 else { throw Failure("Auto-compaction was not observed.") }
            }

            let precedingToolCount = audit.successfulStatusTools
            let precedingAssistantCount = audit.assistantMessages.count
            try await send("Call computer_v2_status exactly once with empty arguments {}. Do not use other tools. "
                + "After the result, reply with only the exact retention key recorded in my first user message.",
                runtime: runtime, audit: audit, taskID: taskID, modelID: modelID)
            XCTAssertEqual(audit.successfulStatusTools - precedingToolCount, 1,
                "The continuation must execute the requested status tool exactly once.")
            let retained = audit.assistantMessages.dropFirst(precedingAssistantCount).contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == canary
            }
            XCTAssertTrue(retained, "The original canary was not retained exactly after compaction.")
            guard retained, audit.successfulStatusTools - precedingToolCount == 1 else {
                throw Failure("Compaction did not preserve the canary and continue read-only tool use.")
            }
            XCTAssertFalse(audit.measurements.isEmpty, "No authoritative runtime token usage arrived.")
            if !manual {
                guard let after = audit.measurementsAfterCompaction.map(\.usedTokens).min(),
                      let before = audit.maximumBeforeCompaction else { throw Failure("Missing before/after compaction measurements.") }
                XCTAssertLessThan(after, before, "Real measured context did not shrink after automatic compaction.")
                guard after < before else { throw Failure("Automatic compaction did not reduce measured context.") }
            }
            XCTAssertTrue(audit.measurements.allSatisfy {
                guard let window = $0.contextWindow else { return false }
                return window > 0 && window <= 8_192
            }, "Use the runtime's effective window; it may reserve part of the configured8K.")
            XCTAssertLessThanOrEqual(audit.compactionsCompleted, 3, "Unexpected repeated compaction churn in the bounded fixture.")
            XCTAssertTrue(audit.failures.isEmpty, audit.failures.joined(separator: "\n"))

            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "\n"))
            let trace = try AppServerWireTrace.load(root.appendingPathComponent("protocol.jsonl"))
            XCTAssertTrue(trace.parseFailures.isEmpty)
            let toolCalls = trace.messages.filter { $0.method == "item/tool/call" }
            XCTAssertEqual(toolCalls.count, 1, "The fixture must not invoke any additional dynamic tools.")
            XCTAssertEqual((toolCalls.first?.object["params"] as? [String: Any])?["tool"] as? String,
                "computer_v2_status")
            let starts = trace.messages.filter { $0.method == "thread/start" }
            let config = (starts.first?.object["params"] as? [String: Any])?["config"] as? [String: Any]
            XCTAssertNil((starts.first?.object["params"] as? [String: Any])?["developerInstructions"])
            XCTAssertNil(config?["compact_prompt"])
            XCTAssertEqual(config?["model_context_window"] as? Int, 8_192)
            XCTAssertEqual(config?["model_auto_compact_token_limit"] as? Int, 6_144)
            let manualRequests = trace.messages.filter { $0.method == "thread/compact/start" }
            let preservedHistory = trace.messages.filter { $0.method == "thread/inject_items" }
            if baseline {
                XCTAssertEqual(manualRequests.count, 0)
                XCTAssertEqual(preservedHistory.count, 0)
            } else {
                // Automatic idle preflight uses the native compact RPC before
                // admitting the unchanged prompt. Native in-turn fallback is
                // still enabled, but cannot race this durable history append.
                XCTAssertGreaterThanOrEqual(manualRequests.count, 1)
                XCTAssertEqual(preservedHistory.count, manualRequests.count)
                if manual { XCTAssertEqual(manualRequests.count, 1) }
                for injection in preservedHistory {
                    let params = injection.object["params"] as? [String: Any]
                    let items = params?["items"] as? [[String: Any]]
                    XCTAssertEqual(items?.count, 1)
                    XCTAssertEqual(items?.first?["role"] as? String, "assistant")
                    let content = items?.first?["content"] as? [[String: Any]]
                    XCTAssertEqual(content?.first?["type"] as? String, "output_text")
                    XCTAssertLessThanOrEqual((content?.first?["text"] as? String)?.utf8.count ?? Int.max, 2_048)
                }
            }
            if baseline { XCTAssertEqual(audit.compactionsStarted, 0) }
            let proof = "mode=\(baseline ? "uncompacted-control" : manual ? "manual" : "production-auto")\n"
                + "compactionsStarted=\(audit.compactionsStarted)\ncompactionsCompleted=\(audit.compactionsCompleted)\n"
                + "contextMeasurements=\(audit.measurements.map(\.usedTokens))\n"
                + "effectiveContextWindows=\(audit.measurements.compactMap(\.contextWindow))\n"
                + "maximumBeforeCompaction=\(audit.maximumBeforeCompaction ?? 0)\n"
                + "measuredAfterCompaction=\(audit.measurementsAfterCompaction.map(\.usedTokens))\n"
                + "continuedReadOnlyToolCalls=\(audit.successfulStatusTools - precedingToolCount)\n"
                + "retentionCanaryVerified=\(retained)\nprotocolTrace=\(root.path)/protocol.jsonl\n"
            let attachment = XCTAttachment(string: proof)
            attachment.name = "HeyDash context compaction evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
            print(proof)
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    private func send(_ prompt: String, runtime: CodexAppServerRuntime, audit: Audit,
                      taskID: String, modelID: String) async throws {
        let completed = audit.completedTurns
        audit.lastStatus = nil
        try await runtime.submit(prompt: prompt, toTaskID: taskID, modelID: modelID)
        try await waitUntil("completed model turn", audit: audit) { audit.completedTurns > completed }
    }

    private func waitUntil(_ description: String, audit: Audit, condition: () -> Bool) async throws {
        for _ in 0..<1_200 {
            if !audit.failures.isEmpty { throw Failure(audit.failures.joined(separator: "\n")) }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure("Timed out waiting for \(description).")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }


    private final class Audit {
        var measurements = [RuntimeContextUsage]()
        var compactionsStarted = 0
        var compactionsCompleted = 0
        var compactionInProgress = false
        var completedTurns = 0
        var successfulStatusTools = 0
        var assistantMessages = [String]()
        var failures = [String]()
        var contextFailures = [String]()
        var acceptExpectedContextFailure = false
        var maximumBeforeCompaction: Int?
        var measurementsAfterCompaction = [RuntimeContextUsage]()
        var lastStatus: TaskStatus?

        func record(_ event: AgentRuntimeEvent, taskID: String) {
            switch event {
            case .contextUsageUpdated(let owner, let usage) where owner == taskID:
                if let usage {
                    measurements.append(usage)
                    if compactionsStarted == 0 { maximumBeforeCompaction = max(maximumBeforeCompaction ?? 0, usage.usedTokens) }
                    if compactionsCompleted > 0 { measurementsAfterCompaction.append(usage) }
                }
            case .contextCompactionChanged(let owner, let phase) where owner == taskID:
                switch phase {
                case .running:
                    // Manual submission announces the reservation before the
                    // correlated native item starts. Count one phase, not both.
                    if !compactionInProgress { compactionsStarted += 1 }
                    compactionInProgress = true
                    if compactionsStarted > 3 { failures.append("Compaction exceeded the fixture's bounded attempt count.") }
                case .completed:
                    compactionInProgress = false
                    compactionsCompleted += 1
                case .failed(let message):
                    compactionInProgress = false
                    contextFailures.append(message)
                    if !acceptExpectedContextFailure { failures.append(message) }
                }
            case .taskStatusChanged(let owner, let status) where owner == taskID:
                lastStatus = status
                if status == .completed { completedTurns += 1 }
                if status == .waiting, !(acceptExpectedContextFailure && !contextFailures.isEmpty) {
                    failures.append("Turn failed or was interrupted.")
                }
            case .timelineEntryAppended(let owner, let entry) where owner == taskID:
                if entry.kind == .assistant { assistantMessages.append(entry.body) }
                if entry.toolEvent?.name == "computer_v2_status", entry.toolEvent?.status == .succeeded {
                    successfulStatusTools += 1
                }
                if entry.kind == .system, entry.title == "Agent error" { failures.append(entry.body) }
            case .connectionChanged(.failed(let message)):
                failures.append(message)
            default: break
            }
        }
    }
}

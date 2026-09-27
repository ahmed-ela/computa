import Foundation
import Darwin
import XCTest
@testable import Mactopus

/// Explicit opt-in only. Uses synthetic text in an isolated Codex home and
/// never clicks, types, changes permissions, or modifies an existing thread.
@MainActor
final class RuntimeContextLiveTests: XCTestCase {
    private var liveConfiguration: CodexAppServerRuntime.Configuration {
        let configuration = ProcessInfo.processInfo.environment["HEYDASH_LIVE_OWNED_MLX_TEST"] == "1"
            ? CodexAppServerRuntime.Configuration.localQwen
            : CodexAppServerRuntime.Configuration.externalLocalQwen
        print("contextFixtureBackend=\(configuration.effectiveBackend.rawValue)")
        return configuration
    }

    func testResourceGuardDiskBoundary() {
        let limit = FixtureResources.minimumFreeDiskBytes
        XCTAssertNil(FixtureResources(freeDiskBytes: limit, swapUsedBytes: 0, pressure: 1).stopReason(baselineSwap: 0))
        XCTAssertEqual(FixtureResources(freeDiskBytes: limit - 1, swapUsedBytes: 0, pressure: 1).stopReason(baselineSwap: 0),
            "free disk below 1.5 GiB")
    }

    func testResourceGuardSwapGrowthBoundaryAndDecrease() {
        let baseline: UInt64 = 1_024
        let limit = baseline + FixtureResources.maximumSwapGrowthBytes
        XCTAssertNil(FixtureResources(freeDiskBytes: .max, swapUsedBytes: limit, pressure: 1).stopReason(baselineSwap: baseline))
        XCTAssertEqual(FixtureResources(freeDiskBytes: .max, swapUsedBytes: limit + 1, pressure: 1).stopReason(baselineSwap: baseline),
            "swap grew by more than 2 GiB")
        XCTAssertNil(FixtureResources(freeDiskBytes: .max, swapUsedBytes: 0, pressure: 1).stopReason(baselineSwap: baseline))
    }

    func testResourceGuardCriticalPressureAndUnknownPressureFailClosed() {
        XCTAssertNil(FixtureResources(freeDiskBytes: .max, swapUsedBytes: 0, pressure: 2).stopReason(baselineSwap: 0))
        XCTAssertEqual(FixtureResources(freeDiskBytes: .max, swapUsedBytes: 0, pressure: 4).stopReason(baselineSwap: 0),
            "critical memory pressure")
        XCTAssertEqual(FixtureResources(freeDiskBytes: .max, swapUsedBytes: 0, pressure: 0).stopReason(baselineSwap: 0),
            "unrecognized memory pressure level")
    }

    func testResourceGuardSamplingFailureIsSanitized() {
        XCTAssertThrowsError(try FixtureResources.read(filesystemPath: "/Mactopus-missing-filesystem-\(UUID().uuidString)")) {
            XCTAssertEqual($0.localizedDescription, "free disk measurement unavailable")
        }
    }

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusOversizedContext-\(UUID().uuidString)")
        var configuration = liveConfiguration
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
            let context = LocalThreadContext.forModel(modelID)
            let padding = String(repeating: "alpha beta gamma delta. ", count: 2_000 * context.contextWindow / 8_192)
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
            .appendingPathComponent("MactopusContextLive-\(UUID().uuidString)", isDirectory: true)
        var configuration = liveConfiguration
        configuration.model = modelID
        configuration.codexHomePath = root.path
        configuration.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
        // Intentionally no autoCompactLimitOverride: this proves the shipping
        // model policy rather than an artificially lowered test trigger.
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
        var resourceGuardTask: Task<Void, Never>?
        defer {
            resourceGuardTask?.cancel()
            eventTask.cancel()
        }
        do {
            if !manual && !baseline {
                resourceGuardTask = try startResourceGuard(runtime: runtime, audit: audit, taskID: taskID,
                    filesystemPath: root.deletingLastPathComponent().path)
            }
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
                let context = LocalThreadContext.forModel(modelID)
                let maximumWarmupRounds = 3 * context.contextWindow / 8_192
                var warmupEvidence = [String]()
                for round in 1...maximumWarmupRounds where audit.compactionsCompleted == 0 {
                    // Keep user messages short: native compaction intentionally
                    // retains user input. Disposable assistant output can shrink.
                    let precedingAssistantCount = audit.assistantMessages.count
                    try await send("For benchmark round \(round), generate exactly 120 numbered lines. Each line must contain ten plain words describing a fictional park. "
                        + "This generated text is disposable. Keep the original retention key in memory but do not repeat it here. Do not use tools.",
                        runtime: runtime, audit: audit, taskID: taskID, modelID: modelID)
                    let generatedText = audit.assistantMessages.dropFirst(precedingAssistantCount).joined(separator: "\n")
                    let numberedLines = generatedText.components(separatedBy: .newlines).filter {
                        $0.trimmingCharacters(in: .whitespaces).range(of: "^[0-9]+[.)]\\s+", options: .regularExpression) != nil
                    }.count
                    let measured = audit.measurements.last
                    let evidence = "warmupRound=\(round) requestedNumberedLines=120 generatedNumberedLines=\(numberedLines) "
                        + "generatedCharacters=\(generatedText.count) measuredInputTokens=\(measured?.inputTokens ?? -1) "
                        + "measuredOutputTokens=\(measured?.outputTokens ?? -1) measuredContextTokens=\(measured?.usedTokens ?? -1)"
                    warmupEvidence.append(evidence)
                    print(evidence)
                    if numberedLines == 0, let measured,
                       measured.usedTokens < context.autoCompactTokenLimit,
                       audit.compactionsCompleted == 0 {
                        throw Failure("Production auto-compaction was not exercised: the warmup generated none of the requested numbered lines and remains below the shipping threshold. Stop instead of repeating a nonproductive workload; inspect the saved model response. "
                            + "shippingThreshold=\(context.autoCompactTokenLimit)\n" + evidence)
                    }
                }
                // A native pre-turn trigger may begin on the following request.
                if audit.compactionsCompleted == 0 {
                    try await send("Keep the original retention key. Reply only CONTINUE_READY; do not use tools.",
                        runtime: runtime, audit: audit, taskID: taskID, modelID: modelID)
                }
                guard audit.compactionsCompleted > 0 else {
                    let maximumMeasured = audit.maximumBeforeCompaction ?? 0
                    let diagnosis = maximumMeasured < context.autoCompactTokenLimit
                        ? "Production auto-compaction was not exercised: the model-generated workload remained below the shipping threshold. An underfilled or refused workload is not evidence of a compaction failure; inspect the saved model responses."
                        : "Production auto-compaction was not observed despite a reported context footprint at or above the shipping threshold."
                    throw Failure(diagnosis + " maximumMeasuredContextTokens=\(maximumMeasured) shippingThreshold=\(context.autoCompactTokenLimit)\n"
                        + warmupEvidence.joined(separator: "\n"))
                }
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
                return window > 0 && window <= LocalThreadContext.forModel(modelID).contextWindow
            }, "Use the runtime's effective window; it may reserve part of the configured model budget.")
            XCTAssertLessThanOrEqual(audit.compactionsCompleted, 3, "Unexpected repeated compaction churn in the bounded fixture.")
            XCTAssertTrue(audit.failures.isEmpty, audit.failures.joined(separator: "\n"))

            resourceGuardTask?.cancel()
            await resourceGuardTask?.value
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
            let context = LocalThreadContext.forModel(modelID)
            XCTAssertEqual(config?["model_context_window"] as? Int, context.contextWindow)
            XCTAssertEqual(config?["model_auto_compact_token_limit"] as? Int, context.autoCompactTokenLimit)
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
            attachment.name = "Mactopus context compaction evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
            print(proof)
        } catch {
            if audit.resourceGuardTripped {
                // Let the watchdog's bounded interrupt grace finish before the
                // same runtime's idempotent shutdown; never wait on the RPC.
                await resourceGuardTask?.value
            } else {
                resourceGuardTask?.cancel()
            }
            _ = await runtime.shutdown()
            throw error
        }
    }

    private func startResourceGuard(runtime: CodexAppServerRuntime, audit: Audit, taskID: String,
                                    filesystemPath: String) throws -> Task<Void, Never> {
        let baseline = try FixtureResources.read(filesystemPath: filesystemPath)
        print(baseline.metricLine(sample: 0, baselineSwap: baseline.swapUsedBytes))
        if let reason = baseline.stopReason(baselineSwap: baseline.swapUsedBytes) {
            throw Failure("Resource guard refused the live fixture before inference: \(reason).")
        }
        return Task { @MainActor in
            var sampleIndex = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                sampleIndex += 1
                let reason: String?
                do {
                    let sample = try FixtureResources.read(filesystemPath: filesystemPath)
                    reason = sample.stopReason(baselineSwap: baseline.swapUsedBytes)
                    // Check every two seconds, but emit routine numeric metrics
                    // only every ten seconds. A trip always prints immediately.
                    if sampleIndex.isMultiple(of: 5) || reason != nil {
                        print(sample.metricLine(sample: sampleIndex, baselineSwap: baseline.swapUsedBytes))
                    }
                } catch {
                    reason = "resource sampling failed: \(error.localizedDescription)"
                }
                guard let reason else { continue }
                audit.resourceGuardTripped = true
                audit.failures.append("Resource guard stopped only this live fixture: \(reason).")
                print("resourceGuardTripped=true reason=\(reason)")
                // This unstructured RPC task may wait on an unresponsive server.
                // It must never delay shutdown. Stop owns only this fixture's
                // runtime and its child process group, not LM Studio or Chrome.
                let interrupt = Task { try? await runtime.interrupt(taskID: taskID) }
                try? await Task.sleep(for: .seconds(1))
                let report = await runtime.shutdown()
                interrupt.cancel()
                print("resourceGuardOwnedRuntimeShutdownSucceeded=\(report.succeeded)")
                return
            }
        }
    }

    private struct FixtureResources {
        static let minimumFreeDiskBytes: UInt64 = 1_536 * 1_024 * 1_024
        static let maximumSwapGrowthBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
        let freeDiskBytes: UInt64
        let swapUsedBytes: UInt64
        let pressure: Int32

        static func read(filesystemPath: String) throws -> Self {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfFileSystem(forPath: filesystemPath)
            } catch {
                throw Failure("free disk measurement unavailable")
            }
            guard let free = attributes[.systemFreeSize] as? NSNumber else {
                throw Failure("free disk measurement unavailable")
            }
            var swap = xsw_usage()
            var swapSize = MemoryLayout<xsw_usage>.size
            guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0,
                  swapSize == MemoryLayout<xsw_usage>.size else {
                throw Failure("swap measurement unavailable")
            }
            var pressure: Int32 = 0
            var pressureSize = MemoryLayout<Int32>.size
            guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0,
                  pressureSize == MemoryLayout<Int32>.size else {
                throw Failure("memory pressure measurement unavailable")
            }
            return Self(freeDiskBytes: free.uint64Value, swapUsedBytes: swap.xsu_used, pressure: pressure)
        }

        func stopReason(baselineSwap: UInt64) -> String? {
            if freeDiskBytes < Self.minimumFreeDiskBytes { return "free disk below 1.5 GiB" }
            if swapUsedBytes > baselineSwap, swapUsedBytes - baselineSwap > Self.maximumSwapGrowthBytes {
                return "swap grew by more than 2 GiB"
            }
            // Darwin memory-pressure levels match DISPATCH_MEMORYPRESSURE_*:
            // 1 normal, 2 warning, 4 critical. Unknown values fail closed.
            if pressure & 4 != 0 { return "critical memory pressure" }
            if pressure != 1 && pressure != 2 { return "unrecognized memory pressure level" }
            return nil
        }

        func metricLine(sample: Int, baselineSwap: UInt64) -> String {
            "resourceGuardSample=\(sample) freeDiskBytes=\(freeDiskBytes) swapUsedBytes=\(swapUsedBytes) "
                + "baselineSwapBytes=\(baselineSwap) pressureLevel=\(pressure)"
        }
    }

    private func send(_ prompt: String, runtime: CodexAppServerRuntime, audit: Audit,
                      taskID: String, modelID: String) async throws {
        guard audit.failures.isEmpty else { throw Failure(audit.failures.joined(separator: "\n")) }
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
        var resourceGuardTripped = false
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

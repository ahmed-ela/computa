import Foundation
import XCTest
@testable import Computa

/// Opt-in real inference, serial only. Synthetic text, two fresh runtime owners,
/// one isolated persistent Codex home, and exactly one read-only status call.
@MainActor
final class RuntimeContextResumeLiveTests: XCTestCase {
    func testColdResumeCompactionRestoresActualAssistantHistoryAndRetainsCanary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_CONTEXT_RESUME_TEST"] == "1",
            "Use TEST_RUNNER_HEYDASH_LIVE_CONTEXT_RESUME_TEST=1 with xcodebuild for the cold-resume gate.")
        let model = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputaContextResumeLive-\(UUID().uuidString)", isDirectory: true)
        let firstTraceURL = root.appendingPathComponent("before-shutdown.jsonl")
        let resumedTraceURL = root.appendingPathComponent("after-resume.jsonl")
        var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
        configuration.model = model
        configuration.codexHomePath = root.path
        configuration.protocolTracePath = firstTraceURL.path
        let canary = "HD_KEEP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let firstTaskID = "resume-fixture-\(UUID().uuidString)"
        let first = CodexAppServerRuntime(configuration: configuration, visualGrounder: ResumeReadOnlyGrounder())
        let firstAudit = Audit(taskID: firstTaskID)
        let firstPump = pump(first, audit: firstAudit)
        defer { firstPump.cancel() }
        print("coldResumeFixtureRoot=\(root.path)")

        let originalAcknowledgement: String
        let threadID: String
        do {
            let initialTasks = try await first.loadTasks()
            XCTAssertTrue(initialTasks.isEmpty, "The new isolated home must contain no prior tasks.")
            try await send("Remember this important retention key for this task: \(canary). "
                + "Preserve this exact key in any future context summary. Reply only KEY_SAVED; do not use tools.",
                runtime: first, audit: firstAudit, model: model)
            originalAcknowledgement = try XCTUnwrap(firstAudit.assistantMessages.last)
            XCTAssertEqual(originalAcknowledgement.trimmingCharacters(in: .whitespacesAndNewlines), "KEY_SAVED")
            guard originalAcknowledgement.trimmingCharacters(in: .whitespacesAndNewlines) == "KEY_SAVED" else {
                throw Failure("The actual baseline assistant did not produce the requested acknowledgment.")
            }
            let report = await first.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "\n"))
            guard report.succeeded else { throw Failure("First runtime did not shut down cleanly.") }
            firstPump.cancel()
            let trace = try AppServerWireTrace.load(firstTraceURL)
            XCTAssertTrue(trace.parseFailures.isEmpty)
            let start = try singleRequest("thread/start", in: trace)
            let reply = try reply(to: start, in: trace)
            let thread = try XCTUnwrap((reply.object["result"] as? [String: Any])?["thread"] as? [String: Any])
            threadID = try XCTUnwrap(thread["id"] as? String)
            guard !threadID.isEmpty else { throw Failure("Missing persisted thread identity.") }
            XCTAssertFalse(trace.messages.contains { $0.method == "item/tool/call" })
            XCTAssertFalse(trace.messages.contains { $0.method == "thread/compact/start" || $0.method == "thread/inject_items" })
        } catch {
            _ = await first.shutdown()
            throw error
        }

        // A different Core and App Server process must hydrate from persisted
        // bounded thread/resume data; no first-runtime memory is transferred.
        configuration.protocolTracePath = resumedTraceURL.path
        let resumed = CodexAppServerRuntime(configuration: configuration, visualGrounder: ResumeReadOnlyGrounder())
        let audit = Audit(taskID: threadID)
        let resumedPump = pump(resumed, audit: audit)
        defer { resumedPump.cancel() }
        do {
            let tasks = try await resumed.loadTasks()
            XCTAssertEqual(tasks.map(\.id), [threadID])
            guard tasks.contains(where: { $0.id == threadID }) else { throw Failure("Persisted task was not recovered.") }
            try await resumed.compact(taskID: threadID)
            try await waitUntil("cold-resume compaction", audit: audit) {
                audit.compactionsCompleted == 1 && audit.completedTurns == 1
            }
            let assistantCount = audit.assistantMessages.count
            try await send("Call computer_v2_status exactly once with empty arguments {}. Do not use other tools. "
                + "After the result, reply with only the exact retention key recorded in my first user message.",
                runtime: resumed, audit: audit, model: model)
            let final = audit.assistantMessages.dropFirst(assistantCount).last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(final, canary, "The resumed/compacted conversation must retain the original exact key.")
            XCTAssertEqual(audit.successfulStatusCalls, 1)
            XCTAssertEqual(audit.compactionsCompleted, 1)
            guard final == canary, audit.successfulStatusCalls == 1 else {
                throw Failure("Cold-resume compaction failed exact recall or read-only tool continuation.")
            }
            let report = await resumed.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "\n"))
            let trace = try AppServerWireTrace.load(resumedTraceURL)
            try verifyResumeWire(trace, threadID: threadID, originalAcknowledgement: originalAcknowledgement)
            let proof = "coldResumeVerified=true\noriginalAssistantAcknowledgementReused=true\n"
                + "exactCanaryRetained=true\nstatusToolCalls=1\ncompactions=1\n"
                + "firstProtocolTrace=\(firstTraceURL.path)\nresumedProtocolTrace=\(resumedTraceURL.path)\n"
            let attachment = XCTAttachment(string: proof)
            attachment.name = "Computa cold-resume compaction evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
            print(proof)
        } catch {
            _ = await resumed.shutdown()
            throw error
        }
    }

    private func verifyResumeWire(_ trace: AppServerWireTrace, threadID: String, originalAcknowledgement: String) throws {
        XCTAssertTrue(trace.parseFailures.isEmpty)
        XCTAssertFalse(trace.messages.contains { $0.method == "thread/start" })
        let resume = try singleRequest("thread/resume", in: trace)
        let parameters = try XCTUnwrap(resume.object["params"] as? [String: Any])
        XCTAssertEqual(parameters["threadId"] as? String, threadID)
        XCTAssertEqual(parameters["excludeTurns"] as? Bool, true)
        let page = try XCTUnwrap(parameters["initialTurnsPage"] as? [String: Any])
        XCTAssertEqual(page["limit"] as? Int, 3)
        XCTAssertEqual(page["sortDirection"] as? String, "desc")
        XCTAssertEqual(page["itemsView"] as? String, "full")
        let resumeReply = try reply(to: resume, in: trace)
        let compact = try singleRequest("thread/compact/start", in: trace)
        let compactReply = try reply(to: compact, in: trace)
        let injection = try singleRequest("thread/inject_items", in: trace)
        let injectionReply = try reply(to: injection, in: trace)
        let userTurn = try singleRequest("turn/start", in: trace)
        XCTAssertLessThan(resumeReply.sequence, compact.sequence)
        XCTAssertLessThan(compactReply.sequence, injection.sequence)
        XCTAssertLessThan(injectionReply.sequence, userTurn.sequence)
        let injectionParameters = try XCTUnwrap(injection.object["params"] as? [String: Any])
        XCTAssertEqual(injectionParameters["threadId"] as? String, threadID)
        let items = try XCTUnwrap(injectionParameters["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(Set(item.keys), ["type", "role", "content"])
        XCTAssertEqual(item["type"] as? String, "message")
        XCTAssertEqual(item["role"] as? String, "assistant")
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "output_text")
        XCTAssertEqual(content.first?["text"] as? String, originalAcknowledgement,
            "Injection must contain the original actual assistant output, not a fabricated reply.")

        let started = try XCTUnwrap(trace.messages.first { message in
            guard message.method == "item/started", let values = message.object["params"] as? [String: Any],
                  let item = values["item"] as? [String: Any] else { return false }
            return item["type"] as? String == "contextCompaction"
        })
        let values = try XCTUnwrap(started.object["params"] as? [String: Any])
        let turnID = try XCTUnwrap(values["turnId"] as? String)
        let compactionItemID = try XCTUnwrap((values["item"] as? [String: Any])?["id"] as? String)
        let turnStarted = try XCTUnwrap(trace.messages.first {
            let params = $0.object["params"] as? [String: Any]
            return $0.method == "turn/started" && params?["threadId"] as? String == threadID
                && (params?["turn"] as? [String: Any])?["id"] as? String == turnID
        })
        let completed = try XCTUnwrap(trace.messages.first {
            let params = $0.object["params"] as? [String: Any]
            let item = params?["item"] as? [String: Any]
            return $0.method == "item/completed" && params?["threadId"] as? String == threadID
                && params?["turnId"] as? String == turnID && item?["id"] as? String == compactionItemID
                && item?["type"] as? String == "contextCompaction"
        })
        let terminal = try XCTUnwrap(trace.messages.first {
            let params = $0.object["params"] as? [String: Any]
            let turn = params?["turn"] as? [String: Any]
            return $0.method == "turn/completed" && params?["threadId"] as? String == threadID
                && turn?["id"] as? String == turnID && turn?["status"] as? String == "completed"
                && (turn?["error"] == nil || turn?["error"] is NSNull)
        })
        XCTAssertLessThan(compact.sequence, turnStarted.sequence)
        XCTAssertLessThan(turnStarted.sequence, started.sequence)
        XCTAssertLessThan(started.sequence, completed.sequence)
        XCTAssertLessThan(completed.sequence, terminal.sequence)
        XCTAssertLessThan(terminal.sequence, injection.sequence)
        let calls = trace.messages.filter { $0.method == "item/tool/call" }
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        let arguments = try XCTUnwrap(call.object["params"] as? [String: Any])
        XCTAssertEqual(arguments["tool"] as? String, "computer_v2_status")
        let decodedArguments = try object(arguments["arguments"])
        XCTAssertTrue(decodedArguments.isEmpty)
        let result = try XCTUnwrap(trace.messages.first {
            $0.direction == .clientToServer && $0.method == nil && $0.identifier == call.identifier && $0.sequence > call.sequence
        })
        XCTAssertEqual((result.object["result"] as? [String: Any])?["success"] as? Bool, true)
        XCTAssertLessThan(userTurn.sequence, call.sequence)
        let statusTurnID = try XCTUnwrap(arguments["turnId"] as? String)
        let statusCallID = try XCTUnwrap(arguments["callId"] as? String)
        let statusItem = try XCTUnwrap(trace.messages.first {
            let params = $0.object["params"] as? [String: Any]
            let item = params?["item"] as? [String: Any]
            return $0.method == "item/completed" && params?["threadId"] as? String == threadID
                && params?["turnId"] as? String == statusTurnID && item?["id"] as? String == statusCallID
                && item?["success"] as? Bool == true && $0.sequence > result.sequence
        })
        let statusTerminal = try XCTUnwrap(trace.messages.first {
            let params = $0.object["params"] as? [String: Any]
            let turn = params?["turn"] as? [String: Any]
            return $0.method == "turn/completed" && params?["threadId"] as? String == threadID
                && turn?["id"] as? String == statusTurnID && turn?["status"] as? String == "completed"
                && (turn?["error"] == nil || turn?["error"] is NSNull)
        })
        XCTAssertLessThan(statusItem.sequence, statusTerminal.sequence)
        XCTAssertNotEqual(statusTurnID, turnID)
        XCTAssertEqual(trace.messages.filter { $0.method == "turn/completed" }.count, 2)
        let forbiddenTypes = Set(["commandExecution", "mcpToolCall", "webSearch"])
        XCTAssertFalse(trace.messages.contains {
            let item = ($0.object["params"] as? [String: Any])?["item"] as? [String: Any]
            return $0.method == "item/completed" && forbiddenTypes.contains(item?["type"] as? String ?? "")
        })
    }

    private func singleRequest(_ method: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let requests = trace.messages.filter { $0.direction == .clientToServer && $0.method == method }
        guard requests.count == 1, let request = requests.first else { throw Failure("Expected exactly one \(method) request.") }
        return request
    }

    private func reply(to request: AppServerWireTrace.Message, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let reply = try XCTUnwrap(trace.messages.first {
            $0.direction == .serverToClient && $0.method == nil && $0.identifier == request.identifier && $0.sequence > request.sequence
        })
        guard reply.object["result"] is [String: Any], reply.object["error"] == nil || reply.object["error"] is NSNull else {
            throw Failure("RPC \(request.method ?? "unknown") did not succeed.")
        }
        return reply
    }

    private func object(_ value: Any?) throws -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func pump(_ runtime: CodexAppServerRuntime, audit: Audit) -> Task<Void, Never> {
        Task { @MainActor in
            for await event in runtime.events() {
                if Task.isCancelled { return }
                audit.record(event)
                if case .approvalRequested(let request) = event {
                    audit.failures.append("Unexpected approval in read-only resume fixture: \(request.title)")
                    try? await runtime.resolveApproval(requestID: request.id, approved: false)
                }
            }
        }
    }

    private func send(_ prompt: String, runtime: CodexAppServerRuntime, audit: Audit, model: String) async throws {
        let count = audit.completedTurns
        try await runtime.submit(prompt: prompt, toTaskID: audit.taskID, modelID: model)
        try await waitUntil("completed inference", audit: audit) { audit.completedTurns > count }
    }

    private func waitUntil(_ label: String, audit: Audit, condition: () -> Bool) async throws {
        for _ in 0..<1_200 {
            if !audit.failures.isEmpty { throw Failure(audit.failures.joined(separator: "\n")) }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Timed out waiting for \(label).")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class Audit {
        let taskID: String
        var completedTurns = 0
        var compactionsCompleted = 0
        var successfulStatusCalls = 0
        var assistantMessages = [String]()
        var failures = [String]()
        init(taskID: String) { self.taskID = taskID }
        func record(_ event: AgentRuntimeEvent) {
            switch event {
            case .taskStatusChanged(let owner, let status) where owner == taskID:
                if status == .completed { completedTurns += 1 }
                if status == .waiting { failures.append("Turn interrupted or failed.") }
            case .contextCompactionChanged(let owner, let state) where owner == taskID:
                if case .completed = state { compactionsCompleted += 1 }
                if case .failed(let message) = state { failures.append(message) }
            case .timelineEntryAppended(let owner, let entry) where owner == taskID:
                if entry.kind == .assistant { assistantMessages.append(entry.body) }
                if let tool = entry.toolEvent {
                    if tool.name == "computer_v2_status", tool.status == .succeeded { successfulStatusCalls += 1 }
                    else { failures.append("Unexpected tool or failed status: \(tool.name)") }
                }
                if entry.kind == .system, entry.title == "Agent error" { failures.append(entry.body) }
            case .connectionChanged(.failed(let message)): failures.append(message)
            default: break
            }
        }
    }
}

private struct ResumeReadOnlyGrounder: VisualGroundingClient {
    func prepare() async throws {}
    func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
        throw VisualGroundingError.protocolViolation("Visual grounding is outside this read-only cold-resume fixture.")
    }
    func shutdown() async -> [String] { [] }
}

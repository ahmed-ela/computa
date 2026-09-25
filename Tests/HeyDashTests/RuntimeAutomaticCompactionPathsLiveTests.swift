import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HeyDash

/// Real model / real App Server / production HeyDash Core. The test-only stdio
/// wrapper replaces status execution with synthetic read-only output and blocks
/// every other server request. This is not a production desktop-broker test.
@MainActor
final class RuntimeAutomaticCompactionPathsLiveTests: XCTestCase {
    private let model = "lmstudio-community/Qwen3.5-4B-MLX-4bit"

    func testColdAutomaticCompactionPrecedesUnchangedSubmissionAndRetainsCanary() async throws {
        try requireOptIn("HEYDASH_LIVE_COLD_AUTO_CONTEXT_TEST")
        let root = try fixtureRoot("ColdAuto")
        let canary = "HD_KEEP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let originalTask = "cold-auto-\(UUID().uuidString)"
        let before = try makeRuntime(root: root, phase: "before", payload: "small")
        let beforeAudit = Audit(taskID: originalTask)
        let beforePump = pump(before, audit: beforeAudit)
        defer { beforePump.cancel() }
        let threadID: String
        let priorMeasuredTokens: Int
        do {
            let existing = try await before.loadTasks()
            try require(existing.isEmpty, "A cold fixture must start with an empty isolated home.")
            try await send(retentionPrompt(canary), runtime: before, audit: beforeAudit)
            try require(beforeAudit.finalReply == "KEY_SAVED", "The first real assistant acknowledgment must match.")
            // Stop at the first measured >=6,144 footprint, before another warm
            // submission could preflight it. User messages stay short and all
            // generated filler is genuine disposable assistant output.
            // Smaller batches reduce overshoot without weakening the measured
            // threshold/headroom requirements or the final exact-key assertion.
            for round in 1...5 {
                if beforeAudit.lastUsage?.usedTokens ?? 0 >= 6_144 { break }
                try await send("Write chapter \(round) of a fictional story about a walk through a peaceful park, roughly 800 words. "
                    + "This generated story is disposable background. "
                    + "Keep the original retention key but do not repeat it here. Do not use tools.",
                    runtime: before, audit: beforeAudit)
            }
            let usage = try XCTUnwrap(beforeAudit.lastUsage, "The cold starting footprint must be measured, not estimated.")
            priorMeasuredTokens = usage.usedTokens
            try require(usage.usedTokens >= 6_144, "The fixture did not reach the production automatic threshold.")
            try require(usage.usedTokens < (usage.contextWindow ?? 0),
                "This fixture must start with usable headroom, not an already oversized history.")
            try await shutDown(before)
            beforePump.cancel()
            let trace = try readTrace(root, phase: "before")
            let start = try exactlyOne("thread/start", in: trace)
            let reply = try rpcReply(to: start, in: trace)
            threadID = try XCTUnwrap(((reply.object["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String)
            try requireToolAudit(root, phase: "before", expectedCalls: 0)
        } catch {
            _ = await before.shutdown()
            throw error
        }

        // A new Core/process receives no first-runtime usage/evidence state.
        let after = try makeRuntime(root: root, phase: "after", payload: "small")
        let afterAudit = Audit(taskID: threadID)
        let afterPump = pump(after, audit: afterAudit)
        defer { afterPump.cancel() }
        do {
            let tasks = try await after.loadTasks()
            try require(tasks.map(\.id) == [threadID], "Cold runtime did not recover exactly the fixture thread.")
            let prompt = recallPrompt
            // No compact() call: automatic cold-submission behavior is the gate.
            try await send(prompt, runtime: after, audit: afterAudit)
            try require(afterAudit.finalReply == canary, "Cold automatic compaction changed the exact retention key.")
            try require(afterAudit.statusTools == 1, "Expected exactly one completed synthetic status call.")
            try require(afterAudit.compactions > 0, "Cold automatic compaction did not occur.")
            try await shutDown(after)
            let trace = try readTrace(root, phase: "after")
            try require(!trace.messages.contains { $0.method == "thread/start" }, "Cold resume must not create a replacement thread.")
            let resume = try exactlyOne("thread/resume", in: trace)
            let compact = try exactlyOne("thread/compact/start", in: trace)
            let injection = try exactlyOne("thread/inject_items", in: trace)
            let user = try exactlyOne("turn/start", in: trace)
            let params = try XCTUnwrap(user.object["params"] as? [String: Any])
            let input = try XCTUnwrap(params["input"] as? [[String: Any]])
            try require(input.count == 1 && input.first?["text"] as? String == prompt,
                "The user prompt must remain unchanged, with no hidden retry or helper prompt.")
            try require(try rpcReply(to: resume, in: trace).sequence < compact.sequence, "Resume must precede automatic maintenance.")
            try require(try rpcReply(to: compact, in: trace).sequence < injection.sequence, "Compaction acknowledgment must precede restoration.")
            try require(try rpcReply(to: injection, in: trace).sequence < user.sequence, "Durable restoration must precede user submission.")
            try verifyCompactionLifecycle(trace, beforeSequence: injection.sequence)
            try requireToolAudit(root, phase: "after", expectedCalls: 1)
            try verifyOnlySyntheticStatus(trace, root: root, phase: "after")
            attach("coldAutomaticVerified=true\nstartingMeasuredTokens=\(priorMeasuredTokens)\n"
                + "exactCanaryRetained=true\nsyntheticStatusCalls=1\nfixtureRoot=\(root.path)")
        } catch {
            _ = await after.shutdown()
            throw error
        }
    }

    func testNativeWithinTurnCompactionAfterBoundedToolResultRetainsCanaryWithoutRepeatedAction() async throws {
        try requireOptIn("HEYDASH_LIVE_WITHIN_TURN_CONTEXT_TEST")
        let root = try fixtureRoot("WithinTurn")
        let taskID = "within-turn-\(UUID().uuidString)"
        let canary = "HD_KEEP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let runtime = try makeRuntime(root: root, phase: "within", payload: "bounded-observation")
        let audit = Audit(taskID: taskID)
        let events = pump(runtime, audit: audit)
        defer { events.cancel() }
        do {
            let tasks = try await runtime.loadTasks()
            try require(tasks.isEmpty, "The within-turn fixture must start isolated.")
            try await send(retentionPrompt(canary), runtime: runtime, audit: audit)
            try require(audit.finalReply == "KEY_SAVED", "The real first acknowledgment must match.")
            // App Server bounds the synthetic tool result before adding it to
            // model context. A short real assistant reply provides enough
            // existing history for that bounded result to cross the threshold.
            // The following measured gate still forbids pre-turn compaction.
            try await send("Generate exactly 40 numbered lines. Each line must contain ten plain words describing a fictional park. "
                + "This generated text is disposable. Keep the original retention key but do not repeat it here. Do not use tools.",
                runtime: runtime, audit: audit)
            let before = try XCTUnwrap(audit.lastUsage)
            try require(before.usedTokens < 6_144 && audit.compactions == 0,
                "This gate must begin below the native automatic threshold, without preflight compaction.")
            try await send(recallPrompt, runtime: runtime, audit: audit)
            try require(audit.finalReply == canary, "The within-turn continuation must return the complete exact key.")
            try require(audit.statusTools == 1, "The observed action must not be repeated after native compaction.")
            try require(audit.compactions == 1, "Expected one native within-turn compaction, not zero or churn.")
            try await shutDown(runtime)
            let trace = try readTrace(root, phase: "within")
            try require(!trace.messages.contains { $0.method == "thread/compact/start" || $0.method == "thread/inject_items" },
                "A managed idle or injected-history path cannot stand in for native within-turn compaction.")
            let starts = trace.messages.filter { $0.method == "turn/start" }
            try require(starts.count == 3, "Only retention, warmup, and recall turns are permitted; no hidden retries.")
            let user = try XCTUnwrap(starts.last)
            let response = try rpcReply(to: user, in: trace)
            let turnID = try XCTUnwrap(((response.object["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String)
            let status = try exactlyOneCompletedItem("dynamicToolCall", in: trace)
            let compactStart = try exactlyOneItem("item/started", type: "contextCompaction", in: trace)
            let compactEnd = try exactlyOneCompletedItem("contextCompaction", in: trace)
            for item in [status, compactStart, compactEnd] {
                try require((item.object["params"] as? [String: Any])?["turnId"] as? String == turnID,
                    "Status and compaction must belong to the exact same user turn.")
            }
            try require(status.sequence < compactStart.sequence && compactStart.sequence < compactEnd.sequence,
                "The tool result must cause compaction inside the active turn.")
            let terminal = try terminal(turnID: turnID, in: trace)
            try require(compactEnd.sequence < terminal.sequence, "Continuation must complete after native compaction.")
            try requireToolAudit(root, phase: "within", expectedCalls: 1)
            try verifyOnlySyntheticStatus(trace, root: root, phase: "within")
            attach("nativeWithinTurnVerified=true\npreTurnMeasuredTokens=\(before.usedTokens)\n"
                + "exactCanaryRetained=true\nsyntheticStatusCalls=1\nfixtureRoot=\(root.path)")
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    private var recallPrompt: String {
        "Call computer_v2_status exactly once with empty arguments {}. Do not use other tools. "
            + "After the result, reply with only the exact retention key recorded in my first user message."
    }

    func testNativeWithinTurnCompactionPreservesUnseenImageForRealQwen() async throws {
        try requireOptIn("HEYDASH_LIVE_WITHIN_TURN_IMAGE_CONTEXT_TEST")
        let root = try fixtureRoot("WithinTurnImage")
        let palette: [(String, [CGFloat])] = [("red", [1, 0, 0]), ("green", [0, 1, 0]),
            ("blue", [0, 0, 1]), ("yellow", [1, 1, 0]), ("cyan", [0, 1, 1]), ("magenta", [1, 0, 1])]
        let colors = Array(palette.shuffled().prefix(4))
        let expected = colors.map(\.0).joined(separator: ",")
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 512, height: 160,
            bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 512, height: 160))
        for (index, color) in colors.enumerated() {
            canvas.setFillColor(CGColor(red: color.1[0], green: color.1[1], blue: color.1[2], alpha: 1))
            canvas.fill(CGRect(x: CGFloat(14 + index * 128), y: 30, width: 100, height: 100))
        }
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), nil)
        try require(CGImageDestinationFinalize(destination), "Synthetic PNG encoding failed.")
        let bytes = png as Data
        try require(bytes.count < 512 * 1024, "Synthetic PNG exceeds its fixture limit.")
        let imageSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let imageURL = root.appendingPathComponent("status-image.png")
        try bytes.write(to: imageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
        let runtime = try makeRuntime(root: root, phase: "within", payload: "bounded-image")
        let audit = Audit(taskID: "within-image-\(UUID().uuidString)")
        let events = pump(runtime, audit: audit)
        defer { events.cancel() }
        do {
            let tasks = try await runtime.loadTasks()
            try require(tasks.isEmpty, "The image fixture must start isolated.")
            try await send("Reply only IMAGE_FIXTURE_READY. Do not use tools.", runtime: runtime, audit: audit)
            try require(audit.finalReply == "IMAGE_FIXTURE_READY", "The initial acknowledgment must match.")
            try await send("Generate exactly 40 numbered lines. Each line must contain ten plain words describing a fictional park. "
                + "This generated text is disposable. Do not use tools.", runtime: runtime, audit: audit)
            let before = try XCTUnwrap(audit.lastUsage)
            try require(before.usedTokens < 6_144 && audit.compactions == 0,
                "The image gate must begin below the shipping threshold without preflight compaction.")
            let prompt = "Call computer_v2_status exactly once with empty arguments {}. Do not use other tools. "
                + "Its synthetic result includes an image with four solid colored squares. "
                + "Read the colors left to right and reply only four lowercase color names separated by commas, with no spaces. "
                + "The possible color names are red, green, blue, yellow, cyan, magenta."
            try require(!prompt.contains(expected), "The expected image answer must not be supplied as text.")
            try await send(prompt, runtime: runtime, audit: audit)
            try require(audit.finalReply == expected, "Qwen did not correctly read the unseen image after compaction.")
            try require(audit.statusTools == 1 && audit.compactions == 1,
                "Exactly one status call and one native within-turn compaction are required.")
            try await shutDown(runtime)
            let trace = try readTrace(root, phase: "within")
            try require(!trace.messages.contains { $0.method == "thread/compact/start" || $0.method == "thread/inject_items" },
                "An idle compaction or history injection cannot substitute for native mid-turn image retention.")
            let starts = trace.messages.filter { $0.method == "turn/start" }
            try require(starts.count == 3, "Only acknowledgment, warmup, and image turns are permitted.")
            let user = try XCTUnwrap(starts.last)
            let response = try rpcReply(to: user, in: trace)
            let turnID = try XCTUnwrap(((response.object["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String)
            let status = try exactlyOneCompletedItem("dynamicToolCall", in: trace)
            let compactStart = try exactlyOneItem("item/started", type: "contextCompaction", in: trace)
            let compactEnd = try exactlyOneCompletedItem("contextCompaction", in: trace)
            for item in [status, compactStart, compactEnd] {
                try require((item.object["params"] as? [String: Any])?["turnId"] as? String == turnID,
                    "Image result and compaction must belong to the exact same user turn.")
            }
            let done = try terminal(turnID: turnID, in: trace)
            try require(status.sequence < compactStart.sequence && compactStart.sequence < compactEnd.sequence
                && compactEnd.sequence < done.sequence,
                "The image result must precede native compaction and successful continuation.")
            try requireToolAudit(root, phase: "within", expectedCalls: 1)
            try verifyOnlySyntheticStatus(trace, root: root, phase: "within", imageSHA256: imageSHA256)
            let rollout = try RolloutPrimitiveTrace.loadLatest(in: root.path)
            try require(rollout.parseFailures.isEmpty && rollout.functionCalls.count == 1,
                "The isolated native rollout must contain exactly one actual tool call.")
            let lines = String(decoding: try Data(contentsOf: rollout.rolloutURL), as: UTF8.self).split(separator: "\n")
            let records = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let checkpoints = records.filter { $0["type"] as? String == "compacted" }
            try require(checkpoints.count == 1, "Exactly one durable replacement checkpoint is required.")
            let checkpoint = try XCTUnwrap(checkpoints.first?["payload"] as? [String: Any])
            let history = try XCTUnwrap(checkpoint["replacement_history"] as? [[String: Any]])
            let outputs = history.filter { $0["type"] as? String == "function_call_output" }
            try require(outputs.count == 1 && outputs.first?["call_id"] as? String == rollout.functionCalls.first?.callID,
                "The retained image must belong to the original exact status call.")
            let content = try XCTUnwrap(outputs.first?["output"] as? [[String: Any]])
            let images = content.filter { $0["type"] as? String == "input_image" }
            try require(images.count == 1, "The latest image must survive exactly once in replacement history.")
            try verifyImage(try XCTUnwrap(images.first?["image_url"] as? String), digest: imageSHA256)
            attach("nativeWithinTurnImageVerified=true\npreTurnMeasuredTokens=\(before.usedTokens)\n"
                + "unseenColorOrderCorrect=true\nretainedImageSHA256=\(imageSHA256)\nsyntheticStatusCalls=1\nfixtureRoot=\(root.path)")
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    private func retentionPrompt(_ canary: String) -> String {
        "Remember this important retention key for this task: \(canary). "
            + "Preserve this exact key in any future context summary. Reply only KEY_SAVED; do not use tools."
    }

    private func requireOptIn(_ name: String) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment[name] == "1",
            "Opt in with TEST_RUNNER_\(name)=1; serial live inference only.")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/Users/ahmedelamin/.bun/bin/bun"),
            "The no-desktop live wrapper requires the installed Bun executable.")
    }

    private func fixtureRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeyDash\(name)Live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReadOnlyLiveCompactionProxy.ts")
        let executable = root.appendingPathComponent("read-only-live-proxy.ts")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        print("automaticPathFixtureRoot=\(root.path)")
        return root
    }

    private func makeRuntime(root: URL, phase: String, payload: String) throws -> CodexAppServerRuntime {
        let artifact = try HeyDashRuntimeArtifact.resolve()
        let fixture: [String: String] = ["executable": artifact.executableURL.path,
                                       "payload": payload, "auditName": phase]
        try JSONSerialization.data(withJSONObject: fixture).write(to: root.appendingPathComponent("read-only-proxy.json"))
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.executable = .fixture(path: root.appendingPathComponent("read-only-live-proxy.ts").path)
        config.codexHomePath = root.path
        config.protocolTracePath = root.appendingPathComponent("\(phase)-protocol.jsonl").path
        config.model = model
        // Shipping context window/threshold and standing workspace policies stay
        // unchanged. Root/operator controls the actual LM Studio hard capacity.
        return CodexAppServerRuntime(configuration: config, visualGrounder: NoDesktopGrounder())
    }

    private func pump(_ runtime: CodexAppServerRuntime, audit: Audit) -> Task<Void, Never> {
        Task { @MainActor in
            for await event in runtime.events() {
                if Task.isCancelled { return }
                audit.record(event)
                if case .approvalRequested(let request) = event {
                    audit.failures.append("An interactive request escaped the read-only wrapper.")
                    try? await runtime.resolveApproval(requestID: request.id, approved: false)
                }
            }
        }
    }

    private func send(_ prompt: String, runtime: CodexAppServerRuntime, audit: Audit) async throws {
        let before = audit.completedTurns
        let attempt = SubmissionAttempt()
        let submission = Task {
            do {
                try await runtime.submit(prompt: prompt, toTaskID: audit.taskID, modelID: model)
                attempt.result = .success(())
            } catch {
                attempt.result = .failure(error)
            }
        }
        do {
            for _ in 0..<1_200 {
                try require(Date.now.timeIntervalSince(audit.startedAt) < 300,
                    "The entire bounded automatic-context fixture exceeded five minutes.")
                try require(audit.failures.isEmpty, audit.failures.joined(separator: "\n"))
                if case .failure(let error) = attempt.result { throw error }
                if audit.completedTurns > before, attempt.result != nil {
                    await submission.value
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw Failure("Timed out waiting for the bounded automatic-context turn.")
        } catch {
            submission.cancel()
            _ = await runtime.shutdown()
            await submission.value
            throw error
        }
    }

    private func shutDown(_ runtime: CodexAppServerRuntime) async throws {
        let report = await runtime.shutdown()
        try require(report.succeeded, "Fixture shutdown failed: \(report.issues.joined(separator: "; "))")
    }

    private func readTrace(_ root: URL, phase: String) throws -> AppServerWireTrace {
        let trace = try AppServerWireTrace.load(root.appendingPathComponent("\(phase)-protocol.jsonl"))
        try require(trace.parseFailures.isEmpty, "Protocol trace contains malformed records.")
        let configs = trace.messages.filter { $0.method == "thread/start" || $0.method == "thread/resume" }
        for request in configs {
            let params = try XCTUnwrap(request.object["params"] as? [String: Any])
            let config = try XCTUnwrap(params["config"] as? [String: Any])
            try require(config["model_context_window"] as? Int == 8_192
                && config["model_auto_compact_token_limit"] as? Int == 6_144,
                "The live path must use the shipping context policy.")
            try require(config["compact_prompt"] == nil && params["developerInstructions"] == nil,
                "Experimental instructions cannot substitute for the shipping native compactor.")
        }
        return trace
    }

    private func exactlyOne(_ method: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let values = trace.messages.filter { $0.direction == .clientToServer && $0.method == method }
        try require(values.count == 1, "Expected exactly one \(method), got \(values.count).")
        return try XCTUnwrap(values.first)
    }

    private func rpcReply(to request: AppServerWireTrace.Message, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let values = trace.messages.filter { $0.direction == .serverToClient && $0.method == nil
            && $0.identifier == request.identifier && $0.sequence > request.sequence }
        try require(values.count == 1, "RPC acknowledgment must be unique.")
        let response = try XCTUnwrap(values.first)
        try require(response.object["result"] is [String: Any]
            && (response.object["error"] == nil || response.object["error"] is NSNull), "RPC did not succeed.")
        return response
    }

    private func exactlyOneItem(_ method: String, type: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let values = trace.messages.filter {
            let params = $0.object["params"] as? [String: Any]
            return $0.method == method && (params?["item"] as? [String: Any])?["type"] as? String == type
        }
        try require(values.count == 1, "Expected exactly one \(method) \(type), got \(values.count).")
        return try XCTUnwrap(values.first)
    }

    private func exactlyOneCompletedItem(_ type: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        try exactlyOneItem("item/completed", type: type, in: trace)
    }

    private func terminal(turnID: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let values = trace.messages.filter {
            let params = $0.object["params"] as? [String: Any]
            return $0.method == "turn/completed" && (params?["turn"] as? [String: Any])?["id"] as? String == turnID
        }
        try require(values.count == 1, "Expected one exact-turn terminal, without retries.")
        let terminal = try XCTUnwrap(values.first)
        let turn = try XCTUnwrap((terminal.object["params"] as? [String: Any])?["turn"] as? [String: Any])
        try require(turn["status"] as? String == "completed" && (turn["error"] == nil || turn["error"] is NSNull),
            "The exact user/maintenance turn must finish successfully.")
        return terminal
    }

    private func verifyCompactionLifecycle(_ trace: AppServerWireTrace, beforeSequence: Int) throws {
        let start = try exactlyOneItem("item/started", type: "contextCompaction", in: trace)
        let end = try exactlyOneCompletedItem("contextCompaction", in: trace)
        let params = try XCTUnwrap(start.object["params"] as? [String: Any])
        let ended = try XCTUnwrap(end.object["params"] as? [String: Any])
        let turnID = try XCTUnwrap(params["turnId"] as? String)
        try require(ended["turnId"] as? String == turnID
            && (params["item"] as? [String: Any])?["id"] as? String == (ended["item"] as? [String: Any])?["id"] as? String,
            "Compaction item and turn identity must match.")
        let done = try terminal(turnID: turnID, in: trace)
        try require(start.sequence < end.sequence && end.sequence < done.sequence && done.sequence < beforeSequence,
            "Successful native lifecycle must precede history append and prompt delivery.")
    }

    private func toolAudit(_ root: URL, phase: String) throws -> [[String: Any]] {
        let bytes = try Data(contentsOf: root.appendingPathComponent("\(phase)-tool-audit.jsonl"))
        return try String(decoding: bytes, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func requireToolAudit(_ root: URL, phase: String, expectedCalls: Int) throws {
        let records = try toolAudit(root, phase: phase)
        try require(!records.contains { ["blocked", "proxy-error"].contains($0["kind"] as? String ?? "") },
            "The model attempted an unrequested, interactive, malformed, or repeated action.")
        try require(records.filter { $0["kind"] as? String == "status" }.count == expectedCalls,
            "The synthetic executor's exact call count did not match.")
    }

    private func verifyOnlySyntheticStatus(_ trace: AppServerWireTrace, root: URL, phase: String, imageSHA256: String? = nil) throws {
        try require(!trace.messages.contains { $0.method == "item/tool/call" },
            "No dynamic tool request may reach HeyDash's real desktop executor in this fixture.")
        let status = try exactlyOneCompletedItem("dynamicToolCall", in: trace)
        let params = try XCTUnwrap(status.object["params"] as? [String: Any])
        let item = try XCTUnwrap(params["item"] as? [String: Any])
        let call = try XCTUnwrap(toolAudit(root, phase: phase).first { $0["kind"] as? String == "status" })
        try require(item["tool"] as? String == "computer_v2_status" && item["success"] as? Bool == true
            && item["id"] as? String == call["callId"] as? String
            && params["turnId"] as? String == call["turnId"] as? String,
            "Native completed status result must match the intercepted call exactly.")
        let content = try XCTUnwrap(item["contentItems"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        try require(content.count == (imageSHA256 == nil ? 1 : 2) && content.first?["type"] as? String == "inputText"
            && output["fixture"] as? String == "synthetic read-only status; no desktop was inspected or changed"
            && text.utf8.count == call["payloadBytes"] as? Int,
            "Completed status content must be the exact bounded synthetic result, not a desktop observation.")
        if let imageSHA256 {
            try require(content.last?["type"] as? String == "inputImage" && call["imageSHA256"] as? String == imageSHA256,
                "The completed synthetic image must match the independently recorded fixture hash.")
            try verifyImage(try XCTUnwrap(content.last?["imageUrl"] as? String), digest: imageSHA256)
        }
        let forbidden = Set(["commandExecution", "fileChange", "mcpToolCall", "webSearch"])
        try require(!trace.messages.contains {
            let item = ($0.object["params"] as? [String: Any])?["item"] as? [String: Any]
            return $0.method == "item/completed" && forbidden.contains(item?["type"] as? String ?? "")
        }, "Unexpected built-in action appeared in a read-only fixture.")
    }

    private func verifyImage(_ url: String, digest: String) throws {
        let prefix = "data:image/png;base64,"
        try require(url.hasPrefix(prefix) && url.utf8.count < 700_000, "Expected one bounded inline PNG fixture.")
        let bytes = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst(prefix.count))))
        try require(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == digest,
            "The image bytes changed or disappeared across the native compaction boundary.")
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private func attach(_ evidence: String) {
        let value = XCTAttachment(string: evidence)
        value.name = "Automatic compaction path evidence (synthetic tool executor)"
        value.lifetime = .keepAlways
        add(value)
        print(evidence)
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @MainActor
    private final class SubmissionAttempt {
        var result: Result<Void, Error>?
    }

    @MainActor
    private final class Audit {
        let taskID: String
        let startedAt = Date.now
        var completedTurns = 0
        var compactions = 0
        var statusTools = 0
        var assistantMessages = [String]()
        var lastUsage: RuntimeContextUsage?
        var failures = [String]()
        var finalReply: String? { assistantMessages.last?.trimmingCharacters(in: .whitespacesAndNewlines) }
        init(taskID: String) { self.taskID = taskID }
        func record(_ event: AgentRuntimeEvent) {
            switch event {
            case .taskStatusChanged(let owner, let status) where owner == taskID:
                if status == .completed { completedTurns += 1 }
                if status == .waiting { failures.append("The user turn failed or was interrupted.") }
            case .contextUsageUpdated(let owner, let value) where owner == taskID:
                lastUsage = value
            case .contextCompactionChanged(let owner, let phase) where owner == taskID:
                if case .completed = phase { compactions += 1 }
                if case .failed(let message) = phase { failures.append(message) }
            case .timelineEntryAppended(let owner, let entry) where owner == taskID:
                if entry.kind == .assistant { assistantMessages.append(entry.body) }
                if let tool = entry.toolEvent {
                    if tool.name == "computer_v2_status", tool.status == .succeeded { statusTools += 1 }
                    else { failures.append("Unexpected tool or failed status: \(tool.name)") }
                }
                if entry.kind == .system, entry.title == "Agent error" { failures.append(entry.body) }
            case .connectionChanged(.failed(let message)): failures.append(message)
            default: break
            }
        }
    }

    private struct NoDesktopGrounder: VisualGroundingClient {
        func prepare() async throws {}
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw Failure("Visual grounding is forbidden in this synthetic read-only fixture.")
        }
        func shutdown() async -> [String] { [] }
    }
}

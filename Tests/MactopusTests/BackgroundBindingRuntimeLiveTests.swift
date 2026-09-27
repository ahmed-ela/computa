import AppKit
import ApplicationServices
import AutomationCore
import CoreGraphics
import Foundation
import XCTest
@testable import Mactopus

/// Explicit opt-in: real App Server + owned MLX + Qwen, not a driver-only gate.
/// The synthetic fixture must already be running; this test never launches it.
@MainActor
final class BackgroundBindingRuntimeLiveTests: XCTestCase {
    private let bundleID = "com.heydash.background-probe"
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @MainActor
    private final class Audit {
        var handled = Set<String>()
        var approvedOpen = false
        var approvedPress = false
        var failure: String?
        var samples = [[String: Any]]()
        var previousTime: UInt64?
        var maximumGapMS = 0.0
        var initialPID: Int32?
        var initialPoint: CGPoint?
        var initialClipboard: Int?

        func sample(target: NSRunningApplication) throws {
            let now = DispatchTime.now().uptimeNanoseconds
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let point = CGEvent(source: nil)?.location, point.x.isFinite, point.y.isFinite else {
                throw Failure("Foreground/pointer metadata unavailable.")
            }
            let clipboard = NSPasteboard.general.changeCount
            if let previousTime { maximumGapMS = max(maximumGapMS, Double(now - previousTime) / 1_000_000) }
            previousTime = now
            samples.append([
                "monotonic_ns": now, "unix_ms": Date().timeIntervalSince1970 * 1_000,
                "foreground_pid": pid, "pointer_x": point.x, "pointer_y": point.y,
                "clipboard_change_count": clipboard, "target_active": target.isActive,
            ])
            guard !target.isTerminated, !target.isActive, pid != target.processIdentifier else {
                throw Failure("Fixture became active or exited; background gate stopped.")
            }
            if let initialPID, let initialPoint, let initialClipboard {
                guard pid == initialPID, point == initialPoint, clipboard == initialClipboard else {
                    throw Failure("Foreground, pointer or clipboard changed during the scored interval.")
                }
            } else { initialPID = pid; initialPoint = point; initialClipboard = clipboard }
        }
    }

    func testProductionQwenBindsAndPressesWithoutActivation() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["HEYDASH_LIVE_BACKGROUND_BINDING_RUNTIME_TEST"] == "1"
                || environment["TEST_RUNNER_HEYDASH_LIVE_BACKGROUND_BINDING_RUNTIME_TEST"] == "1",
            "Opt in with TEST_RUNNER_HEYDASH_LIVE_BACKGROUND_BINDING_RUNTIME_TEST=1; fixture must already be inactive."
        )
        guard AXIsProcessTrusted() else { throw Failure("Accessibility permission is required; no permission prompt was requested.") }
        guard PermissionInspector().current().screenRecording == .granted else {
            throw Failure("Screen Recording permission is required for the read-only image; no permission prompt was requested.")
        }
        let expectedURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work/HeyDashBackgroundIntegration-20260925/HeyDash Background Probe.app")
            .resolvingSymlinksInPath().standardizedFileURL
        let matches = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
        guard matches.count == 1, let target = matches.first,
              target.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == expectedURL else {
            throw Failure("Exactly one already-running repository-owned synthetic fixture is required. No launch was attempted.")
        }
        let window = try ApplicationWindowReader().selectedWindowObservation(
            processIdentifier: target.processIdentifier, expectedBundleIdentifier: bundleID
        ).identity
        let oracle = try AccessibilitySession(target: AccessibilityApplicationTarget(
            processIdentifier: target.processIdentifier, bundleIdentifier: bundleID
        ), windowIdentity: window)
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        guard configuration.effectiveBackend == .headlessMLX else { throw Failure("This gate requires app-owned headless MLX.") }
        try configuration.validateSelectedModel(modelID)
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("MactopusBackgroundBinding-\(UUID().uuidString)", isDirectory: true).path
        let wireURL = URL(fileURLWithPath: configuration.codexHomePath).appendingPathComponent("app-server-wire.jsonl")
        configuration.protocolTracePath = wireURL.path
        let state = AppState(tasks: [], runtime: CodexAppServerRuntime(configuration: configuration), preferences: isolatedTestPreferences())
        let runtimeTask = Task { await state.startRuntime() }
        defer { runtimeTask.cancel() }
        let audit = Audit()
        var report: [String: Any] = [
            "gate": "production_qwen_background_binding", "status": "failed", "model": modelID,
            "backend": configuration.effectiveBackend.rawValue, "fixture_pid": target.processIdentifier,
            "protocol_trace": wireURL.path,
            "sampling": "50ms requested boundary sampling, not a syscall trace or concurrent-human-input stress test",
        ]
        defer {
            report["boundary_samples"] = audit.samples
            report["maximum_boundary_sample_gap_ms"] = audit.maximumGapMS
            emit(report)
        }
        do {
            try await waitUntil {
                if case .failed(let message) = state.connectionState { throw Failure(message) }
                if case .connected = state.connectionState { return true }
                return false
            }
            guard state.accessMode == .askEveryTime else { throw Failure("Isolated preferences did not default to ask-every-time.") }
            state.createTask()
            let taskID = try XCTUnwrap(state.selectedTaskID)
            guard state.setTaskModel(modelID, taskID: taskID) else { throw Failure("Could not select Qwen 4B.") }
            let before = try counts(oracle, window: window)
            report["before"] = before
            try audit.sample(target: target)
            let observer = monitor(state, taskID: taskID, target: target, audit: audit)
            defer { observer.cancel() }
            let start = DispatchTime.now().uptimeNanoseconds
            report["start_unix_ms"] = Date().timeIntervalSince1970 * 1_000
            let submitted = await state.submit(prompt: """
                Test the already-running synthetic app com.heydash.background-probe without interrupting the foreground app. Use exactly this sequence and no other tools:
                1. computer_v2_open with {"bundle_id":"com.heydash.background-probe","activation":"none"}.
                2. computer_v2_capture with {} once. Inspect the returned read-only image; it grants no pointer-input authority.
                3. computer_v2_snapshot with {}. Find the observed Native +1 button supporting AXPress.
                4. computer_v2_ax exactly once, using that returned snapshot_id and button element_index, with ax_action "AXPress". Never repeat the mutation.
                5. computer_v2_snapshot with {"query":"Native:"} to verify the actual resulting counter.
                Reply only HEYDASH_BACKGROUND_BINDING_OK:<N>, replacing <N> with the Native count you actually read after the press. Do not calculate it from the previous count. Do not activate, take additional captures, click coordinates, type, use the clipboard or any other app/tool. On failure, report failure instead of the marker.
                """, toTaskID: taskID)
            guard submitted else { throw Failure("Production prompt was not submitted.") }
            try await waitUntil(timeoutSeconds: 180) {
                if let failure = audit.failure { throw Failure(failure) }
                if case .failed(let message) = state.connectionState { throw Failure(message) }
                return state.tasks.first(where: { $0.id == taskID })?.status == .completed
            }
            observer.cancel()
            try audit.sample(target: target)
            report["total_ms"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            report["end_unix_ms"] = Date().timeIntervalSince1970 * 1_000
            if let failure = audit.failure { throw Failure(failure) }
            guard audit.approvedOpen && audit.approvedPress else { throw Failure("Both exact scoped approvals were not observed.") }
            let after = try counts(oracle, window: window)
            report["after"] = after
            guard after[0] == before[0] + 1, Array(after.dropFirst()) == Array(before.dropFirst()) else {
                throw Failure("Independent AX readback did not show exactly one Native increment with other fixture state unchanged.")
            }
            let completed = try XCTUnwrap(state.tasks.first(where: { $0.id == taskID }))
            guard completed.model == modelID,
                  completed.entries.last(where: { $0.kind == .assistant })?.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "HEYDASH_BACKGROUND_BINDING_OK:\(after[0])" else {
                throw Failure("Qwen did not return the exact independently verified post-action Native count.")
            }
            let trace = try AppServerWireTrace.load(wireURL)
            report["tool_receipts"] = try validateWire(trace, nativeCount: after[0])
            try audit.sample(target: target)
            report["status"] = "passed"
            await shutdown(state, report: &report)
        } catch {
            report["error"] = error.localizedDescription
            await shutdown(state, report: &report)
            throw error
        }
    }

    private func monitor(_ state: AppState, taskID: AgentTask.ID, target: NSRunningApplication, audit: Audit) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                while !Task.isCancelled {
                    try audit.sample(target: target)
                    for request in state.pendingApprovals where audit.handled.insert(request.id).inserted {
                        let details = object(request.details) ?? [:]
                        let arguments = object(details["model_arguments"]) ?? [:]
                        let resolved = object(details["resolved_target"]) ?? [:]
                        let common = request.taskID == taskID && request.kind == .computerUse
                        let open = common && !audit.approvedOpen && !audit.approvedPress
                            && request.title == "Allow an application action?"
                            && request.summary == "Bind running \(bundleID) without activation"
                            && Set(details.keys) == ["bundle_id", "activation"]
                            && details["bundle_id"] as? String == bundleID && details["activation"] as? String == "none"
                        let press = common && audit.approvedOpen && !audit.approvedPress
                            && request.title == "Allow a desktop action?" && request.summary == "AXPress on Native +1"
                            && Set(details.keys) == ["model_arguments", "resolved_target"]
                            && Set(resolved.keys) == ["bundle_id", "process_id"]
                            && resolved["bundle_id"] as? String == bundleID
                            && (resolved["process_id"] as? NSNumber)?.int32Value == target.processIdentifier
                            && Set(arguments.keys) == ["snapshot_id", "element_index", "ax_action"]
                            && UUID(uuidString: arguments["snapshot_id"] as? String ?? "") != nil
                            && (arguments["element_index"] as? Int).map { $0 >= 0 } == true
                            && arguments["ax_action"] as? String == "AXPress"
                        if open { audit.approvedOpen = true }
                        if press { audit.approvedPress = true }
                        await state.resolveApproval(request, approved: open || press)
                        guard open || press else { throw Failure("Unexpected approval was declined: \(request.summary)") }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch is CancellationError { return }
            catch { audit.failure = error.localizedDescription }
        }
    }

    private func counts(_ oracle: AccessibilitySession, window: ApplicationWindowIdentity) throws -> [Int] {
        guard try window.isStillSelected() else { throw Failure("Oracle window changed.") }
        let elements = try oracle.snapshot().elements.filter { $0.role == "AXStaticText" && $0.identifier == "probe-result" }
        guard try window.isStillSelected(), elements.count == 1,
              let value = elements.first?.value ?? elements.first?.title else { throw Failure("Exact fixture result AX element is unavailable.") }
        let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let parts = normalized.split(separator: " ")
        guard parts.count == 7, parts[0] == "Native:", parts[2] == "Pixel:", parts[4] == "Input", parts[5] == "chars:",
              let native = Int(parts[1]), let pixel = Int(parts[3]), let input = Int(parts[6]) else {
            throw Failure("Malformed fixture counter; no inferred count was used.")
        }
        return [native, pixel, input]
    }

    private func validateWire(_ trace: AppServerWireTrace, nativeCount: Int) throws -> [[String: Any]] {
        guard trace.parseFailures.isEmpty else { throw Failure("Raw wire trace contains parse failures.") }
        let calls = trace.messages.filter { $0.direction == .serverToClient && $0.method == "item/tool/call" }
        let expected = ["computer_v2_open", "computer_v2_capture", "computer_v2_snapshot", "computer_v2_ax", "computer_v2_snapshot"]
        guard calls.count == expected.count else { throw Failure("Expected five raw tool calls, received \(calls.count).") }
        var resultTexts = [String]()
        var receipts = [[String: Any]]()
        var identity: (thread: String, turn: String)?
        var usedCallIDs = Set<String>()
        for (index, call) in calls.enumerated() {
            guard let params = object(call.object["params"]), params["tool"] as? String == expected[index],
                  let arguments = object(params["arguments"]), let requestID = call.identifier,
                  let callID = params["callId"] as? String, !callID.isEmpty, usedCallIDs.insert(callID).inserted,
                  let thread = params["threadId"] as? String, !thread.isEmpty,
                  let turn = params["turnId"] as? String, !turn.isEmpty else { throw Failure("Unexpected raw tool or missing identity.") }
            if let identity, identity.thread != thread || identity.turn != turn { throw Failure("Tool calls crossed task/turn boundaries.") }
            identity = (thread, turn)
            let response = try XCTUnwrap(trace.messages.first {
                $0.direction == .clientToServer && $0.method == nil && $0.identifier == requestID && $0.sequence > call.sequence
            })
            let result = try XCTUnwrap(object(response.object["result"]))
            guard result["success"] as? Bool == true, let content = result["contentItems"] as? [[String: Any]],
                  !content.isEmpty, content.allSatisfy({
                      $0["type"] as? String == "inputText" || (index == 1 && $0["type"] as? String == "inputImage")
                  }) else {
                throw Failure("Native tool failed or returned unexpected content in the actual client response.")
            }
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            func lifecycle(_ method: String, _ status: String) -> AppServerWireTrace.Message? {
                trace.messages.first { message in
                    guard message.direction == .serverToClient, message.method == method,
                          let parameters = object(message.object["params"]), parameters["threadId"] as? String == thread,
                          parameters["turnId"] as? String == turn, let item = object(parameters["item"]) else { return false }
                    return item["type"] as? String == "dynamicToolCall" && item["id"] as? String == callID
                        && item["status"] as? String == status && (method != "item/completed" || item["success"] as? Bool == true)
                }
            }
            guard let started = lifecycle("item/started", "inProgress"), started.sequence < call.sequence,
                  let completed = lifecycle("item/completed", "completed"), completed.sequence > response.sequence else {
                throw Failure("Raw tool lifecycle was incomplete or out of order.")
            }
            switch index {
            case 0:
                guard Set(arguments.keys) == ["bundle_id", "activation"], arguments["bundle_id"] as? String == bundleID,
                      arguments["activation"] as? String == "none", text.contains("NATIVE_BINDING activation=none") else {
                    throw Failure("Raw bind did not use the non-activating contract.")
                }
            case 1:
                let images = content.filter { $0["type"] as? String == "inputImage" }
                guard arguments.isEmpty, images.count == 1,
                      let imageURL = images.first?["imageUrl"] as? String, imageURL.hasPrefix("data:image/png;base64,"),
                      let png = Data(base64Encoded: String(imageURL.dropFirst("data:image/png;base64,".count))),
                      png.starts(with: [0x89, 0x50, 0x4E, 0x47]),
                      text.hasPrefix("IMAGE_OBSERVATION observation_id="), text.contains("input_authority=none"),
                      !text.contains("WINDOW_CAPTURE"), !text.contains("capture_id=") else {
                    throw Failure("Background image did not have a PNG and observation-only authority.")
                }
            case 2:
                guard arguments.isEmpty, text.hasPrefix("NATIVE_AX scope=bound_window activation=none.") else {
                    throw Failure("Initial observation was not a background AX snapshot.")
                }
            case 3:
                guard Set(arguments.keys) == ["snapshot_id", "element_index", "ax_action"],
                      let snapshotID = arguments["snapshot_id"] as? String, UUID(uuidString: snapshotID) != nil,
                      let elementIndex = arguments["element_index"] as? Int, arguments["ax_action"] as? String == "AXPress",
                      resultTexts[2].contains("AXSNAPSHOT id=\(snapshotID) "),
                      resultTexts[2].split(separator: "\n").contains(where: {
                          $0.hasPrefix("#\(elementIndex) ") && $0.contains("label=\"Native +1\"")
                              && $0.contains("role=\"AXButton\"") && $0.contains("\"AXPress\"")
                      }), text.hasPrefix("Requested AXPress on Native +1.\n"), text.contains("action_dispatched=true") else {
                    throw Failure("AXPress lacked current observed element provenance or dispatch evidence.")
                }
            default:
                guard Set(arguments.keys) == ["query"], arguments["query"] as? String == "Native:",
                      text.hasPrefix("NATIVE_AX scope=bound_window activation=none."),
                      text.contains("Native: \(nativeCount) Pixel:") else {
                    throw Failure("Final model-visible AX snapshot did not contain the independently verified count.")
                }
            }
            resultTexts.append(text)
            receipts.append(["tool": expected[index], "call_id": callID, "arguments": arguments,
                             "started_sequence": started.sequence, "call_sequence": call.sequence,
                             "response_sequence": response.sequence, "completed_sequence": completed.sequence])
        }
        guard let identity else { throw Failure("No production turn identity was recorded.") }
        let starts = trace.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }
        guard starts.count == 1, let start = starts.first, let startParams = object(start.object["params"]),
              startParams["model"] as? String == modelID, startParams["threadId"] as? String == identity.thread,
              trace.messages.contains(where: { message in
                  guard message.direction == .serverToClient, message.method == "turn/completed",
                        let params = object(message.object["params"]), params["threadId"] as? String == identity.thread,
                        let turn = object(params["turn"]) else { return false }
                  return turn["id"] as? String == identity.turn && turn["status"] as? String == "completed"
                      && (turn["error"] == nil || turn["error"] is NSNull)
              }) else { throw Failure("Actual Qwen 4B start or successful matching turn terminal was absent.") }
        let publicText = trace.messages.compactMap { message -> String? in
            guard message.direction == .serverToClient, message.method == "item/agentMessage/delta",
                  let params = object(message.object["params"]), params["threadId"] as? String == identity.thread,
                  params["turnId"] as? String == identity.turn else { return nil }
            return params["delta"] as? String
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard publicText == "HEYDASH_BACKGROUND_BINDING_OK:\(nativeCount)" else {
            throw Failure("Actual public text deltas did not reconstruct the independently verified marker.")
        }
        return receipts
    }

    private func waitUntil(timeoutSeconds: Double = 30, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Timed out waiting for the bounded production runtime gate.")
    }

    private func shutdown(_ state: AppState, report: inout [String: Any]) async {
        let outcome = await state.shutdownRuntime()
        report["shutdown_succeeded"] = outcome.succeeded
        XCTAssertTrue(outcome.succeeded, outcome.issues.joined(separator: "\n"))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:1237/health")!)
            report["owned_listener_released"] = false
            XCTFail("Owned MLX listener remained after awaited shutdown.")
        } catch let error as URLError {
            report["owned_listener_released"] = error.code == .cannotConnectToHost
            XCTAssertEqual(error.code, .cannotConnectToHost)
        } catch { XCTFail("Could not verify owned listener release: \(error.localizedDescription)") }
        if !outcome.succeeded || report["owned_listener_released"] as? Bool != true { report["status"] = "failed" }
    }

    private func object(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private func emit(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { XCTFail("Could not encode background production proof."); return }
        let attachment = XCTAttachment(string: text)
        attachment.name = "Mactopus production Qwen non-activating binding proof"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("HEYDASH_BACKGROUND_BINDING_RUNTIME_LIVE=\(text)")
    }
}

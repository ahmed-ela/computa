import AppKit
import Foundation
import XCTest
@testable import Mactopus

/// Opt-in production approval gate. Run serially, with no other local inference:
/// TEST_RUNNER_HEYDASH_LIVE_ACCESS_MODE_TEST=1 xcodebuild -project Mactopus.xcodeproj \
///   -scheme Mactopus -configuration Debug -derivedDataPath .build/Mactopus \
///   -destination 'platform=macOS,arch=arm64' \
///   -only-testing:MactopusTests/AccessModeLiveTests/testAskFullAskUsesProductionApprovalDispatch test
/// Xcode removes TEST_RUNNER_ when forwarding the flag to the test host.
/// Only three Calculator launch/activate actions are permitted; no click, type,
/// screenshot, browser navigation, permission changes, or existing-thread edits.
@MainActor
final class AccessModeLiveTests: XCTestCase {
    private let bundleID = "com.apple.calculator"
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
    private let toolName = "computer_v2_open"

    func testAskFullAskUsesProductionApprovalDispatch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_ACCESS_MODE_TEST"] == "1",
            "Opt in with TEST_RUNNER_HEYDASH_LIVE_ACCESS_MODE_TEST=1 when invoking xcodebuild.")
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw Failure("Calculator must already be installed; this fixture will not install it.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MactopusAccessModeLive-\(UUID().uuidString)", isDirectory: true)
        let traceURL = root.appendingPathComponent("protocol.jsonl")
        var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
        configuration.model = modelID
        configuration.codexHomePath = root.path
        configuration.protocolTracePath = traceURL.path
        let runtime = CodexAppServerRuntime(configuration: configuration)
        // Live fixtures must never inherit or overwrite the user's persisted
        // Full/Ask choice in the signed application's standard preferences.
        let preferences = isolatedTestPreferences()
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences)
        let audit = Audit()

        // Feed real runtime events unchanged through the same AppState.apply
        // boundary used by startRuntime. The fixture only withholds unexpected
        // approvals, before Full access can claim them; it never approves or
        // substitutes a valid request on AppState's behalf.
        let eventTask = Task { @MainActor in
            do {
                state.replaceTasks(with: try await runtime.loadTasks())
                state.apply(.connectionChanged(.connected(provider: runtime.providerName)))
                for await event in runtime.events() {
                    if Task.isCancelled { return }
                    if case .approvalRequested(let request) = event {
                        guard audit.failures.isEmpty,
                              isPermitted(request, audit: audit) else {
                            audit.failures.append("Unexpected, duplicate, or unsafe approval: \(request.title) / \(request.summary)")
                            try? await runtime.resolveApproval(requestID: request.id, approved: false)
                            continue
                        }
                        audit.requests.append(request)
                    }
                    state.apply(event)
                    audit.record(event)
                    if state.accessMode == .fullAccess,
                       state.presentedApproval != nil || state.approvalGateBlocksInteraction {
                        audit.failures.append("Full access exposed a manual approval gate while handling a runtime event.")
                    }
                }
            } catch {
                audit.failures.append("Runtime event pump failed: \(error.localizedDescription)")
            }
        }
        addTeardownBlock { @MainActor in
            // Also executes on timeout/assertion/throw, releasing pending
            // approvals and owned App Server children without touching LM Studio.
            let report = await state.shutdownRuntime()
            eventTask.cancel()
            _ = await eventTask.result
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        }

        try await waitUntil("runtime connection", state: state, audit: audit, seconds: 30) {
            if case .connected = state.connectionState { return true }
            return false
        }
        XCTAssertEqual(state.accessMode, .askEveryTime)

        for (index, mode) in [AccessMode.askEveryTime, .fullAccess, .askEveryTime].enumerated() {
            if state.accessMode != mode {
                guard state.setAccessMode(mode) else { throw Failure("Could not select \(mode.rawValue).") }
            }
            XCTAssertEqual(state.accessMode, mode)
            state.createTask()
            let taskID = try XCTUnwrap(state.selectedTaskID)
            if try task(in: state, id: taskID).model != modelID {
                guard state.setTaskModel(modelID, taskID: taskID) else { throw Failure("4B model is not selectable.") }
            }
            XCTAssertEqual(try task(in: state, id: taskID).model, modelID)
            audit.activeTaskID = taskID
            audit.taskIDs.append(taskID)
            let token = "HD_ACCESS_\(index)_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let submitted = await state.submit(prompt: """
                Call computer_v2_open exactly once with {"bundle_id":"com.apple.calculator"}. Do not use any other tool, URL, application, click, typing, or screenshot. When this one tool succeeds, reply only \(token). If it fails or is declined, report failure and do not retry.
                """, toTaskID: taskID)
            guard submitted else { throw Failure("The \(mode.rawValue) fixture prompt was not submitted.") }

            try await waitUntil("\(mode.rawValue) approval request", state: state, audit: audit, seconds: 120) {
                audit.requests.contains { $0.taskID == taskID }
            }
            let request = try XCTUnwrap(audit.requests.first { $0.taskID == taskID })
            if mode == .askEveryTime {
                XCTAssertEqual(state.presentedApproval, request)
                XCTAssertTrue(state.approvalGateBlocksInteraction)
                XCTAssertEqual(state.pendingApprovals, [request])
                // Leave the request pending across several event-loop turns.
                // Both transcript and raw transport must remain uncompleted.
                try await Task.sleep(for: .milliseconds(300))
                try validateHealthy(state: state, audit: audit)
                let pending = try task(in: state, id: taskID)
                XCTAssertTrue(pending.entries.compactMap(\.toolEvent).allSatisfy { $0.status != .succeeded })
                XCTAssertFalse(audit.resolvedIDs.contains(request.id))
                XCTAssertFalse(audit.completedTaskIDs.contains(taskID))
                XCTAssertEqual(state.presentedApproval, request)
                try verifyNoResultBeforeManualApproval(traceURL, callIndex: index)

                let result = await state.resolveApproval(request, approved: true)
                guard result.delivered, result.approved == true else {
                    throw Failure("Explicit native approval was not delivered: \(result.reason)")
                }
                audit.manualDecisionIDs.append(request.id)
            } else {
                // No test resolveApproval call is made for the permitted Full
                // access request: only production AppState can release it.
                XCTAssertNil(state.presentedApproval)
                XCTAssertFalse(state.approvalGateBlocksInteraction)
                XCTAssertTrue(state.pendingApprovals.isEmpty)
            }

            try await waitUntil("\(mode.rawValue) successful turn completion", state: state, audit: audit, seconds: 120) {
                audit.completedTaskIDs.contains(taskID)
            }
            let completed = try task(in: state, id: taskID)
            let calls = completed.entries.compactMap(\.toolEvent)
            XCTAssertEqual(calls.count, 1, "Each fresh task must execute exactly one tool.")
            let call = try XCTUnwrap(calls.first)
            XCTAssertEqual(call.name, toolName)
            XCTAssertEqual(call.status, .succeeded)
            let item = try XCTUnwrap(object(call.input))
            XCTAssertTrue(isExactCalculatorArguments(object(item["arguments"])))
            XCTAssertEqual(completed.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines), token)
            XCTAssertEqual(audit.requests.filter { $0.taskID == taskID }.count, 1)
            XCTAssertTrue(audit.resolvedIDs.contains(request.id))
            XCTAssertTrue(state.pendingApprovals.isEmpty)
            XCTAssertFalse(state.approvalGateBlocksInteraction)
            XCTAssertFalse(state.isBusy(taskID: taskID))
            XCTAssertNil(state.automaticApprovalError)
        }

        XCTAssertEqual(audit.requests.count, 3)
        XCTAssertEqual(audit.manualDecisionIDs, [audit.requests[0].id, audit.requests[2].id])
        XCTAssertEqual(state.accessMode, .askEveryTime)
        let report = await state.shutdownRuntime()
        XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        try verifyCompletedWire(traceURL)
        let proof = "askFullAskVerified=true\nmanualDecisions=2\nautomaticDecisions=1\n"
            + "successfulCalculatorOpenCalls=3\nunexpectedApprovals=0\nmodel=\(modelID)\nprotocolTrace=\(traceURL.path)\n"
        let attachment = XCTAttachment(string: proof)
        attachment.name = "Mactopus production access-mode evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(proof)
    }

    private func isPermitted(_ request: ActionApprovalRequest, audit: Audit) -> Bool {
        request.taskID != nil && request.taskID == audit.activeTaskID
            && request.kind == .computerUse
            && request.title == "Allow an application action?"
            && request.summary == "Launch or activate \(bundleID)"
            && isExactCalculatorArguments(object(request.details))
            && !audit.requests.contains { $0.taskID == request.taskID }
    }

    private func isExactCalculatorArguments(_ value: [String: Any]?) -> Bool {
        guard let value else { return false }
        return Set(value.keys) == ["bundle_id"] && value["bundle_id"] as? String == bundleID
    }

    private func verifyNoResultBeforeManualApproval(_ url: URL, callIndex: Int) throws {
        let trace = try AppServerWireTrace.load(url)
        guard trace.parseFailures.isEmpty else { throw Failure("Malformed pending-approval wire trace.") }
        let calls = trace.messages.filter { $0.direction == .serverToClient && $0.method == "item/tool/call" }
        guard calls.count == callIndex + 1, let call = calls.last, let requestID = call.identifier else {
            throw Failure("Expected exactly one new raw tool request awaiting manual approval.")
        }
        guard !trace.messages.contains(where: {
            $0.direction == .clientToServer && $0.method == nil && $0.identifier == requestID
                && $0.sequence > call.sequence
        }) else { throw Failure("The raw tool result was sent before explicit Ask-mode approval.") }
    }

    private func verifyCompletedWire(_ url: URL) throws {
        let trace = try AppServerWireTrace.load(url)
        guard trace.parseFailures.isEmpty else { throw Failure("Malformed completed wire trace.") }
        let calls = trace.messages.filter { $0.direction == .serverToClient && $0.method == "item/tool/call" }
        guard calls.count == 3 else { throw Failure("Expected exactly three raw Calculator-open calls.") }
        var turns = Set<String>()
        for call in calls {
            guard let params = call.object["params"] as? [String: Any],
                  params["tool"] as? String == toolName,
                  isExactCalculatorArguments(object(params["arguments"])),
                  let turnID = params["turnId"] as? String,
                  let callID = params["callId"] as? String,
                  let requestID = call.identifier,
                  let response = trace.messages.first(where: {
                      $0.direction == .clientToServer && $0.method == nil && $0.identifier == requestID
                          && $0.sequence > call.sequence
                  }), let result = response.object["result"] as? [String: Any],
                  result["success"] as? Bool == true,
                  trace.messages.contains(where: { message in
                      guard message.direction == .serverToClient, message.method == "item/completed",
                            let values = message.object["params"] as? [String: Any],
                            let item = values["item"] as? [String: Any] else { return false }
                      return values["turnId"] as? String == turnID && item["id"] as? String == callID
                          && item["success"] as? Bool == true && message.sequence > response.sequence
                  }) else { throw Failure("A raw Calculator call lacked a matching successful result/completion.") }
            turns.insert(turnID)
        }
        XCTAssertEqual(turns.count, 3, "Each access-mode gate must be a distinct real turn.")
        let starts = trace.messages.filter { $0.direction == .clientToServer && $0.method == "thread/start" }
        XCTAssertEqual(starts.count, 3)
        XCTAssertTrue(starts.allSatisfy { ($0.object["params"] as? [String: Any])?["model"] as? String == modelID })
    }

    private func task(in state: AppState, id: String) throws -> AgentTask {
        guard let task = state.tasks.first(where: { $0.id == id }) else { throw Failure("Fixture task disappeared.") }
        return task
    }

    private func object(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func validateHealthy(state: AppState, audit: Audit) throws {
        if let failure = audit.failures.first { throw Failure(failure) }
        if case .failed(let message) = state.connectionState { throw Failure(message) }
        if let message = state.automaticApprovalError { throw Failure(message) }
    }

    private func waitUntil(_ description: String, state: AppState, audit: Audit,
                           seconds: Int, condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 20) {
            try validateHealthy(state: state, audit: audit)
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("Timed out waiting for \(description).")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class Audit {
        var activeTaskID: String?
        var taskIDs = [String]()
        var requests = [ActionApprovalRequest]()
        var resolvedIDs = Set<String>()
        var manualDecisionIDs = [String]()
        var completedTaskIDs = Set<String>()
        var failures = [String]()

        func record(_ event: AgentRuntimeEvent) {
            switch event {
            case .approvalResolved(let id): resolvedIDs.insert(id)
            case .taskStatusChanged(let id, let status) where taskIDs.contains(id):
                if status == .completed { completedTaskIDs.insert(id) }
                if status == .waiting { failures.append("A fixture turn failed or was interrupted.") }
            case .timelineEntryAppended(let id, let entry) where taskIDs.contains(id):
                if let tool = entry.toolEvent, tool.name != "computer_v2_open" {
                    failures.append("Model deviated from the Calculator-only fixture: \(tool.name).")
                }
            default: break
            }
        }
    }
}

import AppKit
import Foundation
import XCTest
@testable import Computa

/// Opt-in production approval gate. Run serially, with no other local inference:
/// TEST_RUNNER_HEYDASH_LIVE_ACCESS_MODE_TEST=1 xcodebuild -project Computa.xcodeproj \
///   -scheme Computa -configuration Debug -derivedDataPath .build/Computa \
///   -destination 'platform=macOS,arch=arm64' \
///   -only-testing:ComputaTests/AccessModeLiveTests/testAskFullAskUsesProductionApprovalDispatch test
/// Xcode removes TEST_RUNNER_ when forwarding the flag to the test host.
/// Only three Calculator launch/activate actions are permitted; no click, type,
/// screenshot, browser navigation, permission changes, or existing-thread edits.
@MainActor
final class AccessModeLiveTests: XCTestCase {
    private let bundleID = "com.apple.calculator"
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
    private let toolName = "computer_v2_open"

    /// Scripted inference, actual bundled engine and actual outside-workspace
    /// writes. No local model, website, GUI or existing workflow fixture is used.
    func testFullAccessWritesOutsideWorkspaceAndAskRestoresBoundaryOnSameThread() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_WORKFLOW_ENGINE_TEST"] == "1",
            "Set COMPUTA_WORKFLOW_ENGINE_TEST=1 for the bundled engine permission boundary.")
        _ = try ComputaRuntimeArtifact.resolve()
        let failuresBefore = testRun?.failureCount ?? 0
        // A temporary-directory sibling would be writable in Ask's default
        // policy. Use a fresh owned cache root outside the allowed temp roots.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ComputaPermissionBoundary-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let sibling = root.appendingPathComponent("Sibling", isDirectory: true)
        for directory in [project, sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let traceURL = root.appendingPathComponent("protocol.jsonl")
        let model = syntheticChatGPTModelID
        let taskID = UUID().uuidString
        let transport = PermissionBoundaryTransport(project: project, sibling: sibling)
        var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
        configuration.model = model
        configuration.codexHomePath = root.appendingPathComponent("AgentHome").path
        configuration.workspacePath = project.path
        configuration.protocolTracePath = traceURL.path
        let runtime = CodexAppServerRuntime(configuration: configuration)
        var completed = 0
        var running = false
        var errors = [String]()
        var approvals = [ActionApprovalRequest]()
        let observer = Task { @MainActor in
            for await event in runtime.events() {
                switch event {
                case .taskStatusChanged(let id, let status) where id == taskID:
                    if status == .running { running = true }
                    if running && status == .completed { completed += 1; running = false }
                    if status == .waiting || status == .failed { errors.append("The permission fixture turn failed or stopped.") }
                case .timelineEntryAppended(let id, let entry) where id == taskID:
                    if entry.title == "Agent error" { errors.append(entry.body) }
                case .connectionChanged(.failed(let message)): errors.append(message)
                case .approvalRequested(let request):
                    approvals.append(request)
                    if request.taskID != taskID || request.kind != .command
                        || !request.summary.contains(sibling.path) {
                        errors.append("Unexpected permission fixture approval.")
                    }
                    // No approval is granted by this fixture, even unexpectedly.
                    do { try await runtime.resolveApproval(requestID: request.id, approved: false) }
                    catch { errors.append(error.localizedDescription) }
                default: break
                }
            }
        }
        var failure: Error?
        do {
            await runtime.configureEmbeddedWebModelTransport(transport)
            for (index, mode) in [AccessMode.fullAccess, .askEveryTime].enumerated() {
                try await runtime.submit(prompt: "Run only the owned permission boundary fixture.",
                    toTaskID: taskID, modelID: model, accessMode: mode)
                for _ in 0..<4_500 {
                    if completed == index + 1 || !errors.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try WorkflowBenchmarkFailure.require(errors.isEmpty, errors.joined(separator: "; "))
                try WorkflowBenchmarkFailure.require(completed == index + 1, "Permission fixture exceeded its 90-second deadline.")
                if mode == .fullAccess {
                    XCTAssertTrue(approvals.isEmpty, "Full must execute without an engine approval request")
                    XCTAssertEqual(try String(contentsOf: sibling.appendingPathComponent("full.txt"), encoding: .utf8), "FULL_BOUNDARY")
                }
            }
            XCTAssertFalse(approvals.isEmpty, "Ask must request explicit approval for the escalated outside write")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("ask.txt").path))
            let receipt = await transport.receipt()
            XCTAssertEqual(receipt.steps, 5)
            XCTAssertEqual(receipt.starts, 5)
            XCTAssertEqual(receipt.closed, 5, "Every scripted inference must close its exact website lease")
            XCTAssertEqual(receipt.results.count, 3)
            let trace = try AppServerWireTrace.load(traceURL)
            XCTAssertEqual(trace.parseFailures, [])
            let starts = trace.messages.filter { $0.direction == .clientToServer && $0.method == "thread/start" }
            let turns = trace.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }
            XCTAssertEqual(starts.count, 1, "Switching access mode must reuse the existing thread")
            XCTAssertEqual(turns.count, 2)
            try WorkflowBenchmarkFailure.require(starts.count == 1 && turns.count == 2 && receipt.results.count == 3,
                "The real engine did not execute the finite two-turn permission scenario")
            let params = try turns.map { try XCTUnwrap($0.object["params"] as? [String: Any]) }
            let threadID = try XCTUnwrap(params.first?["threadId"] as? String)
            XCTAssertFalse(threadID.isEmpty)
            XCTAssertTrue(params.allSatisfy { $0["threadId"] as? String == threadID })
            XCTAssertEqual(params[0]["approvalPolicy"] as? String, "never")
            XCTAssertEqual(params[0]["sandboxPolicy"] as? NSDictionary, ["type": "dangerFullAccess"] as NSDictionary)
            XCTAssertEqual(params[1]["approvalPolicy"] as? String, "on-request")
            XCTAssertEqual(params[1]["sandboxPolicy"] as? NSDictionary, [
                "type": "workspaceWrite", "writableRoots": [String](), "networkAccess": false,
                "excludeTmpdirEnvVar": false, "excludeSlashTmp": false,
            ] as NSDictionary)
            let defaultResult = receipt.results[1]
            let defaultCallID = defaultResult.callID
            let askReply = try XCTUnwrap(trace.messages.first {
                $0.direction == .serverToClient && $0.method == nil && $0.identifier == turns[1].identifier
            })
            let askTurnID = try XCTUnwrap(((askReply.object["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String)
            let outsidePath = sibling.appendingPathComponent("ask.txt").path
            // A sandbox-denied spawn may return the native tool's completed
            // output without publishing a commandExecution item. matchingOutput
            // already binds this result to the exact offered call and arguments.
            let outputLines = defaultResult.output.components(separatedBy: "\n")
            let failedNativeOutput = defaultResult.workdir == project.path
                && defaultResult.command?.contains(outsidePath) == true
                && defaultResult.output.hasPrefix("Chunk ID: ")
                && outputLines.contains { line in
                    let prefix = "Process exited with code "
                    guard line.hasPrefix(prefix), let exit = Int(line.dropFirst(prefix.count)) else { return false }
                    return exit > 0
                }
                && defaultResult.output.contains(outsidePath)
                && ["permission denied", "operation not permitted", "sandbox denied"]
                    .contains { defaultResult.output.localizedCaseInsensitiveContains($0) }
            let failedOutsideCommand = trace.messages.contains { message in
                guard message.direction == .serverToClient, message.method == "item/completed",
                      let values = message.object["params"] as? [String: Any],
                      values["threadId"] as? String == threadID, values["turnId"] as? String == askTurnID,
                      let item = values["item"] as? [String: Any],
                      item["type"] as? String == "commandExecution", item["id"] as? String == defaultCallID,
                      item["cwd"] as? String == project.path,
                      (item["command"] as? String)?.contains(outsidePath) == true,
                      let exit = item["exitCode"] as? Int, exit > 0,
                      let output = item["aggregatedOutput"] as? String, output.contains(outsidePath) else { return false }
                return ["permission denied", "operation not permitted", "sandbox denied"]
                    .contains { output.localizedCaseInsensitiveContains($0) }
            }
            let declinedOutsideCommand = trace.messages.contains { request in
                guard request.direction == .serverToClient,
                      request.method == "item/commandExecution/requestApproval",
                      let values = request.object["params"] as? [String: Any],
                      values["threadId"] as? String == threadID, values["turnId"] as? String == askTurnID,
                      values["itemId"] as? String == defaultCallID, values["cwd"] as? String == project.path,
                      (values["command"] as? String)?.contains(outsidePath) == true,
                      defaultResult.output.localizedCaseInsensitiveContains("rejected by user"),
                      let id = request.identifier else { return false }
                return trace.messages.contains { response in
                    response.direction == .clientToServer && response.method == nil && response.identifier == id
                        && response.sequence > request.sequence
                        && (response.object["result"] as? [String: Any])?["decision"] as? String == "decline"
                }
            }
            XCTAssertTrue(failedNativeOutput || failedOutsideCommand || declinedOutsideCommand,
                "Normal Ask must return the exact native call's sandbox failure or receive a matching native decline")
            let explicitApproval = trace.messages.filter {
                $0.direction == .serverToClient && $0.method == "item/commandExecution/requestApproval"
                    && ($0.object["params"] as? [String: Any])?["itemId"] as? String == receipt.results[2].callID
            }
            XCTAssertEqual(explicitApproval.count, 1, "The escalated Ask call must request its own native approval")
            let id = try XCTUnwrap(explicitApproval.first?.identifier)
            let decision = try XCTUnwrap(trace.messages.first {
                $0.direction == .clientToServer && $0.method == nil && $0.identifier == id
            })
            XCTAssertEqual((decision.object["result"] as? [String: Any])?["decision"] as? String, "decline")
        } catch { failure = error }
        let shutdown = await runtime.shutdown()
        observer.cancel()
        _ = await observer.result
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
        if failure != nil || (testRun?.failureCount ?? 0) > failuresBefore {
            let receipt = await transport.receipt()
            for (index, result) in receipt.results.enumerated() {
                let diagnostic: [String: Any] = ["index": index, "callID": result.callID,
                    "name": result.name, "output": String(result.output.prefix(2_000))]
                if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
                    print("permissionBoundaryToolResult " + String(decoding: data, as: UTF8.self))
                }
            }
            // Preserve bounded, fixture-only raw evidence in the retained test
            // log before deleting the owned root. This works under SwiftPM too.
            if let bytes = try? Data(contentsOf: traceURL) {
                let tail = Data(bytes.suffix(32 * 1_024))
                print("permissionBoundaryFailure traceBytes=\(bytes.count) retainedTailBytes=\(tail.count) traceTailBase64=\(tail.base64EncodedString())")
            } else { print("permissionBoundaryFailure traceUnavailable=true") }
        }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError,
                  !FileManager.default.fileExists(atPath: root.path) else { throw error }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        if let failure { throw failure }
        try WorkflowBenchmarkFailure.require((testRun?.failureCount ?? 0) == failuresBefore,
            "Permission boundary assertions failed")
        print("fullOutsideWrite=true fullEngineApprovals=0 askOutsideWrites=0 askApprovalDeclined=true sameThread=true fixtureRemoved=true")
    }

    func testAskFullAskUsesProductionApprovalDispatch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_ACCESS_MODE_TEST"] == "1",
            "Opt in with TEST_RUNNER_HEYDASH_LIVE_ACCESS_MODE_TEST=1 when invoking xcodebuild.")
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw Failure("Calculator must already be installed; this fixture will not install it.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputaAccessModeLive-\(UUID().uuidString)", isDirectory: true)
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
        attachment.name = "Computa production access-mode evidence"
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
        let startTurns = trace.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }
        XCTAssertEqual(startTurns.count, 3)
        for (index, mode) in [AccessMode.askEveryTime, .fullAccess, .askEveryTime].enumerated() {
            guard starts.indices.contains(index), startTurns.indices.contains(index),
                  let params = starts[index].object["params"] as? [String: Any],
                  let id = starts[index].identifier,
                  let reply = trace.messages.first(where: {
                      $0.direction == .serverToClient && $0.method == nil && $0.identifier == id
                  }), let result = reply.object["result"] as? [String: Any],
                  let sandbox = result["sandbox"] as? [String: Any],
                  let turn = startTurns[index].object["params"] as? [String: Any],
                  let turnSandbox = turn["sandboxPolicy"] as? [String: Any] else {
                throw Failure("Actual engine did not acknowledge the selected execution policy.")
            }
            let policy = mode == .fullAccess ? "never" : "on-request"
            let type = mode == .fullAccess ? "dangerFullAccess" : "workspaceWrite"
            XCTAssertEqual(params["sandbox"] as? String, mode == .fullAccess ? "danger-full-access" : "workspace-write")
            XCTAssertEqual(result["approvalPolicy"] as? String, policy)
            XCTAssertEqual(sandbox["type"] as? String, type)
            XCTAssertEqual(turn["approvalPolicy"] as? String, policy)
            XCTAssertEqual(turnSandbox["type"] as? String, type)
            if mode == .askEveryTime { XCTAssertEqual(turnSandbox["networkAccess"] as? Bool, false) }
        }
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
                if status == .waiting || status == .failed { failures.append("A fixture turn failed or was interrupted.") }
            case .timelineEntryAppended(let id, let entry) where taskIDs.contains(id):
                if let tool = entry.toolEvent, tool.name != "computer_v2_open" {
                    failures.append("Model deviated from the Calculator-only fixture: \(tool.name).")
                }
            default: break
            }
        }
    }
}

/// Only inference is synthetic: exact emitted arguments and their matching
/// engine outputs are checked using the shared workflow parser.
private actor PermissionBoundaryTransport: WebModelTransport {
    struct Receipt: Sendable {
        var steps = 0
        var starts = 0
        var closed = 0
        var results = [ObservedToolResult]()
    }
    private let project: URL
    private let sibling: URL
    private var token: String?
    private var generation = ""
    private var submitted = false
    private var reply = ""
    private var pending: ExpectedCall?
    private var value = Receipt()
    init(project: URL, sibling: URL) { self.project = project; self.sibling = sibling }
    func receipt() -> Receipt { value }

    func request(operation: String, params: Data) throws -> Data {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        var result: [String: Any]
        if operation != "webProviderStart" {
            try WorkflowBenchmarkFailure.require(token != nil && input["sessionToken"] == token,
                "Permission inference lost its exact lease")
        }
        switch operation {
        case "webProviderStart":
            try WorkflowBenchmarkFailure.require(token == nil, "Overlapping permission inference leases")
            token = UUID().uuidString; generation = UUID().uuidString; submitted = false
            value.starts += 1
            result = ["state": "ready"]
        case "webProviderSend":
            try WorkflowBenchmarkFailure.require(!submitted, "Repeated permission inference submission")
            submitted = true
            reply = try nextReply(InferenceRequest(params: params))
            result = ["state": "running"]
        case "webProviderPoll": result = ["state": "complete", "text": reply]
        case "webProviderFinish", "webProviderCancel": result = ["cleanup": "not_created"]
        default: throw WorkflowBenchmarkFailure("Unexpected permission inference operation: \(operation)")
        }
        result["sessionToken"] = token
        result["sequence"] = submitted ? 1 : 0
        result["modelProofContext"] = ["documentGeneration": generation,
            "sequence": submitted ? 1 : 0, "baselineResponseCount": 0,
            "responseCount": result["state"] as? String == "complete" ? 1 : 0,
            "firstUserFingerprint": submitted ? String(repeating: "a", count: 64) : ""]
        if ["webProviderFinish", "webProviderCancel"].contains(operation) {
            value.closed += 1; token = nil
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(result, modelChoice: syntheticChatGPTChoice))
    }

    private func nextReply(_ request: InferenceRequest) throws -> String {
        if let pending {
            let actual = try request.matchingOutput(pending)
            value.results.append(actual)
            if value.steps == 1 {
                try WorkflowBenchmarkFailure.require(actual.output.contains("Process exited with code 0"),
                    "Full access did not execute the actual outside write: \(actual.output.prefix(500))")
            } else {
                try WorkflowBenchmarkFailure.require(!actual.output.contains("Process exited with code 0")
                    && !FileManager.default.fileExists(atPath: sibling.appendingPathComponent("ask.txt").path),
                    "Ask allowed the outside write without explicit approval")
                try WorkflowBenchmarkFailure.require(["denied", "rejected", "declined", "not permitted"]
                    .contains { actual.output.localizedCaseInsensitiveContains($0) },
                    "The actual outside-write failure was not a permission denial: \(actual.output.prefix(500))")
            }
        }
        let step = value.steps
        value.steps += 1
        if step == 1 || step == 4 {
            pending = nil
            return #"{"type":"message","text":"PERMISSION_BOUNDARY_OK"}"#
        }
        try WorkflowBenchmarkFailure.require([0, 2, 3].contains(step), "Unexpected permission inference replay")
        let name = try request.tool("exec_command")
        let path = sibling.appendingPathComponent(step == 0 ? "full.txt" : "ask.txt").path
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var arguments: [String: Any] = ["cmd": "/usr/bin/printf '\(step == 0 ? "FULL_BOUNDARY" : "ASK_BOUNDARY")' > " + quoted,
            "workdir": project.path, "yield_time_ms": 10000, "max_output_tokens": 2000]
        if step == 3 {
            arguments["sandbox_permissions"] = "require_escalated"
            arguments["justification"] = "Write only the owned permission fixture marker outside its project."
        }
        pending = .function(name: name, arguments: arguments)
        return String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls",
            "calls": [["name": name, "arguments": arguments]]]), as: UTF8.self)
    }
}

import AppKit
import AutomationCore
import Foundation
import XCTest
@testable import HeyDash

@MainActor
final class LocalQwenLiveTests: XCTestCase {
    // These historical file-URL Chrome fixtures exercise the persisted V1
    // contract. They are intentionally unavailable to new V2 threads.
    private var chromeFixtureSupported: Bool { false }

    private enum ChromeComputerPath {
        case semantic
        case visual
    }

    private struct FixtureRun {
        let url: URL
        let completionToken: String
    }

    private struct RecordedComputerCall {
        let item: [String: Any]
        let arguments: [String: Any]
        let status: ToolRunStatus
        let parseFailure: String?

        var action: String? {
            arguments["action"] as? String
        }

        var parameters: [String: Any] {
            arguments["parameters"] as? [String: Any] ?? [:]
        }
    }

    private struct RecordedV2Call {
        let tool: String
        let item: [String: Any]
        let arguments: [String: Any]
        let status: ToolRunStatus

        var outputText: String {
            (item["contentItems"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "inputText" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
    }

    private struct StrictApprovalDecision {
        let approved: Bool
        let action: String
        let reason: String
    }

    private final class StrictApprovalAudit {
        var approvedActions = [String]()
        var unexpectedRequests = [String]()
        var resolvingRejectedRequest = false
        var handledRequestIDs = Set<String>()
        var calculatorDisplayBefore: AccessibilityTreeElement?
    }

    private struct LiveTestFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    func testProductionRuntimeCompletesLocalQwenTurn() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_TEST"] == "1",
            "Set LOCALCODEX_LIVE_MODEL_TEST=1 to run against the loaded LM Studio model."
        )

        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexLiveTest-\(UUID().uuidString)", isDirectory: true)
            .path

        let runtime = CodexAppServerRuntime(configuration: configuration)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let eventTask = Task { await state.startRuntime() }
        defer { eventTask.cancel() }

        try await waitForRuntimeConnection(state: state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let selectedModelID = try selectLiveModelIfRequested(in: state, taskID: taskID)
        let submitted = await state.submit(
            prompt: "Reply with exactly LOCAL_QWEN_OK and do not use tools.",
            toTaskID: taskID
        )
        guard submitted else {
            throw LiveTestFailure(
                message: "Local Qwen prompt was not submitted. \(diagnostics(for: state))"
            )
        }

        try await waitUntil("completed inference turn", state: state, attempts: 240) {
            guard let task = state.tasks.first(where: { $0.id == taskID }) else { return false }
            return task.status == .completed
                && task.entries.contains {
                    $0.kind == .assistant
                        && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == "LOCAL_QWEN_OK"
                }
        }

        let completedTask = try XCTUnwrap(state.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(completedTask.status, .completed)
        XCTAssertEqual(completedTask.model, selectedModelID)
        XCTAssertEqual(
            completedTask.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "LOCAL_QWEN_OK"
        )

        let webSnapshot = WebUISnapshot(state: state)
        let webTask = try XCTUnwrap(webSnapshot.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(webTask.status, "Completed")
        XCTAssertEqual(webTask.model, selectedModelID)
        XCTAssertEqual(
            webTask.entries.last(where: { $0.kind == "assistant" })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "LOCAL_QWEN_OK"
        )
    }

    func testProductionRuntimeExecutesReadOnlyComputerTool() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_TEST"] == "1",
            "Set LOCALCODEX_LIVE_MODEL_TEST=1 to run against the selected LM Studio model."
        )

        let (state, eventTask, codexHomePath, protocolTracePath) = await makeLiveState()
        defer { eventTask.cancel() }

        try await waitForRuntimeConnection(state: state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let selectedModelID = try selectLiveModelIfRequested(in: state, taskID: taskID)
        let submitted = await state.submit(
            prompt: "Call computer_v2_status exactly once with empty arguments {}. After its result, reply with exactly LOCAL_COMPUTER_TOOL_OK. You must use that tool and no other tool.",
            toTaskID: taskID
        )
        guard submitted else {
            throw LiveTestFailure(
                message: "Read-only computer prompt was not submitted. \(diagnostics(for: state))"
            )
        }

        try await waitUntil("computer-tool inference turn", state: state, attempts: 1_600) {
            guard let task = state.tasks.first(where: { $0.id == taskID }) else { return false }
            return task.status == .completed
                && task.entries.contains(where: {
                    $0.toolEvent?.name == ComputerV2ToolContract.Tool.status.rawValue
                        && $0.toolEvent?.status == .succeeded
                })
                && task.entries.contains {
                    $0.kind == .assistant
                        && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == "LOCAL_COMPUTER_TOOL_OK"
                }
        }
        let completedTask = try XCTUnwrap(state.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(completedTask.model, selectedModelID)
        XCTAssertEqual(
            completedTask.entries.compactMap(\.toolEvent).map(\.name),
            [ComputerV2ToolContract.Tool.status.rawValue]
        )

        _ = try await waitForRolloutPrimitiveTrace(
            in: codexHomePath,
            expectedActions: [ComputerV2ToolContract.Tool.status.rawValue],
            completionToken: "LOCAL_COMPUTER_TOOL_OK",
            v2StatusOnly: true
        )
        let wireTrace = try await waitForAppServerWireTrace(
            at: protocolTracePath,
            expectedActions: [ComputerV2ToolContract.Tool.status.rawValue],
            completionToken: "LOCAL_COMPUTER_TOOL_OK",
            v2StatusOnly: true
        )
        assertLiveModelInWireTrace(wireTrace, expectedModelID: selectedModelID)
    }

    /// An opt-in, non-browser V2 gate: the model must request an approved app
    /// open, then read the bound app's AX tree before returning the token.
    /// This does not claim to test pointer input or visual Chrome control.
    func testProductionRuntimeObservesBoundCalculatorWithV2() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_SEMANTIC_COMPUTER_TEST"] == "1",
            "Set LOCALCODEX_LIVE_SEMANTIC_COMPUTER_TEST=1 to run the safe Calculator V2 gate."
        )
        guard PermissionInspector().current().accessibility == .granted else {
            throw LiveTestFailure(message: "The opted-in Calculator mutation gate requires Accessibility access.")
        }
        let calculatorBundleID = "com.apple.calculator"
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: calculatorBundleID) != nil else {
            throw LiveTestFailure(message: "The opted-in Calculator mutation gate requires Calculator on this Mac.")
        }

        let (state, eventTask, codexHomePath, protocolTracePath) = await makeLiveState()
        defer { eventTask.cancel() }
        try await waitForRuntimeConnection(state: state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let selectedModelID = try selectLiveModelIfRequested(in: state, taskID: taskID)
        let completionToken = "LOCALCODEX_CALCULATOR_V2_OK_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        let approvalAudit = StrictApprovalAudit()
        let approvalTask = startStrictCalculatorApprovalLoop(
            state: state,
            taskID: taskID,
            bundleID: calculatorBundleID,
            audit: approvalAudit
        )
        defer { approvalTask.cancel() }

        let submitted = await state.submit(
            prompt: """
            Call computer_v2_open with exactly {"bundle_id":"\(calculatorBundleID)"}. Then call computer_v2_snapshot with exactly {"query":"Calculator"}. Read the snapshot result and confirm its AXSNAPSHOT header identifies the Calculator bundle. Only after that observation, reply with exactly \(completionToken). Use exactly those two tools in that order; do not use any other tools or mutate Calculator.
            """,
            toTaskID: taskID
        )
        guard submitted else {
            throw LiveTestFailure(
                message: "Calculator V2 prompt was not submitted. \(diagnostics(for: state))"
            )
        }

        let completedTask = try await waitForCompletedTask(
            "Calculator V2 semantic turn",
            state: state,
            taskID: taskID,
            audit: approvalAudit,
            attempts: 3_600
        )
        XCTAssertEqual(completedTask.model, selectedModelID)
        XCTAssertEqual(approvalAudit.approvedActions, ["open"])
        XCTAssertTrue(
            approvalAudit.unexpectedRequests.isEmpty,
            approvalAudit.unexpectedRequests.joined(separator: "\n")
        )
        let calls = try recordedV2Calls(in: completedTask)
        let expectedTools = [
            ComputerV2ToolContract.Tool.open.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
        ]
        XCTAssertEqual(
            completedTask.entries.compactMap(\.toolEvent).map(\.name),
            expectedTools,
            "No extra tool may run during the Calculator gate."
        )
        XCTAssertEqual(calls.map(\.tool), expectedTools)
        XCTAssertTrue(calls.allSatisfy { $0.status == .succeeded })
        XCTAssertEqual(calls.first?.arguments["bundle_id"] as? String, calculatorBundleID)
        XCTAssertEqual(Set(calls.first?.arguments.keys.map { $0 } ?? []), ["bundle_id"])
        XCTAssertEqual(calls.last?.arguments["query"] as? String, "Calculator")
        XCTAssertEqual(Set(calls.last?.arguments.keys.map { $0 } ?? []), ["query"])

        let openText = try XCTUnwrap(calls.first?.outputText)
        let openPID = try XCTUnwrap(
            processIdentifier(inOpenOutput: openText),
            "The V2 open output did not expose a processIdentifier."
        )
        XCTAssertTrue(openText.contains("\"bundleIdentifier\""))
        XCTAssertTrue(openText.contains(calculatorBundleID))
        XCTAssertEqual(
            NSRunningApplication(processIdentifier: openPID)?.bundleIdentifier,
            calculatorBundleID
        )
        let snapshotText = try XCTUnwrap(calls.last?.outputText)
        XCTAssertTrue(snapshotText.contains("AXSNAPSHOT id="))
        XCTAssertTrue(snapshotText.contains("pid=\(openPID) "))
        XCTAssertTrue(snapshotText.contains("bundle=\"\(calculatorBundleID)\""))
        XCTAssertEqual(
            completedTask.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            completionToken
        )

        let rollout = try await waitForCalculatorV2RolloutTrace(
            in: codexHomePath,
            bundleID: calculatorBundleID,
            processID: openPID,
            completionToken: completionToken
        )
        XCTAssertEqual(rollout.functionCalls.map(\.name), expectedTools)
        let wireTrace = try await waitForCalculatorV2WireTrace(
            at: protocolTracePath,
            bundleID: calculatorBundleID,
            processID: openPID
        )
        assertLiveModelInWireTrace(wireTrace, expectedModelID: selectedModelID)
    }

    /// A transport-level cancellation gate with no computer actions.
    func testProductionRuntimeInterruptsActiveTurn() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_INTERRUPT_TEST"] == "1",
            "Set LOCALCODEX_LIVE_INTERRUPT_TEST=1 to run the App Server interrupt gate."
        )
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexInterruptTest-\(UUID().uuidString)", isDirectory: true)
            .path
        let protocolTracePath = URL(fileURLWithPath: configuration.codexHomePath, isDirectory: true)
            .appendingPathComponent("app-server-wire.jsonl")
        configuration.protocolTracePath = protocolTracePath.path
        let runtime = CodexAppServerRuntime(configuration: configuration)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let eventTask = Task { await state.startRuntime() }
        defer { eventTask.cancel() }
        try await waitForRuntimeConnection(state: state)
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        _ = try selectLiveModelIfRequested(in: state, taskID: taskID)
        let submitted = await state.submit(
            prompt: "Write every integer from 1 to 10000, one per line. Do not use tools.",
            toTaskID: taskID
        )
        XCTAssertTrue(submitted)
        try await waitUntil("active turn", state: state, attempts: 40) {
            state.tasks.first(where: { $0.id == taskID })?.status == .running
        }
        try await runtime.interrupt(taskID: taskID)
        try await waitUntil("interrupted turn", state: state, attempts: 120) {
            state.tasks.first(where: { $0.id == taskID })?.status == .waiting
        }
        let trace = try AppServerWireTrace.load(protocolTracePath)
        XCTAssertTrue(trace.parseFailures.isEmpty)
        let interruptRequest = try XCTUnwrap(trace.messages.first { message in
            message.direction == .clientToServer && message.method == "turn/interrupt"
        })
        let requestID = interruptRequest.object["id"] as? NSNumber
        XCTAssertTrue(trace.messages.contains { message in
            message.direction == .serverToClient
                && (message.object["id"] as? NSNumber) == requestID
                && message.object["result"] != nil
        })
        XCTAssertTrue(trace.messages.contains { message in
            guard message.method == "turn/completed",
                  let turn = (message.object["params"] as? [String: Any])?["turn"] as? [String: Any]
            else { return false }
            return turn["status"] as? String == "interrupted"
        })
        XCTAssertFalse(trace.messages.contains { $0.method == "item/tool/call" })
    }

    /// A combined screenshot/AX gate. The image and semantic snapshot must be
    /// returned by one capture, and the only mutation allowed is AXPress on 1.
    func testProductionRuntimeUsesCombinedCalculatorCaptureWithV2() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_COMBINED_CAPTURE_TEST"] == "1",
            "Set LOCALCODEX_LIVE_COMBINED_CAPTURE_TEST=1 to run this combined observation gate."
        )
        try XCTSkipUnless(
            PermissionInspector().current().accessibility == .granted
                && PermissionInspector().current().screenRecording == .granted,
            "The live test host needs Accessibility and Screen Recording access."
        )
        let calculatorBundleID = "com.apple.calculator"
        try XCTSkipUnless(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: calculatorBundleID) != nil,
            "Calculator is unavailable on this Mac."
        )

        let (state, eventTask, _, protocolTracePath) = await makeLiveState()
        defer { eventTask.cancel() }
        try await waitForRuntimeConnection(state: state)
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let selectedModelID = try selectLiveModelIfRequested(in: state, taskID: taskID)
        let completionToken = "LOCALCODEX_COMBINED_CAPTURE_OK_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        let approvalAudit = StrictApprovalAudit()
        let approvalTask = startStrictCalculatorMutationApprovalLoop(
            state: state,
            taskID: taskID,
            bundleID: calculatorBundleID,
            audit: approvalAudit,
            combinedCapture: true
        )
        defer { approvalTask.cancel() }

        let submitted = await state.submit(
            prompt: """
            Use exactly four tools in order: computer_v2_open with {"bundle_id":"\(calculatorBundleID)"}; computer_v2_capture with {"include_accessibility":true}; computer_v2_ax with the snapshot_id and element_index for the Calculator button labeled 1 in the returned AX snapshot and ax_action "AXPress"; computer_v2_snapshot with {"query":"Edit field"}. Do not use image coordinates. Verify the final display changed, then reply with exactly \(completionToken). Do not use other tools or press any other button.
            """,
            toTaskID: taskID
        )
        guard submitted else {
            throw LiveTestFailure(message: "Combined Calculator prompt was not submitted.")
        }
        let task = try await waitForCompletedTask(
            "combined Calculator capture turn",
            state: state,
            taskID: taskID,
            audit: approvalAudit,
            attempts: 3_600
        )
        let expectedTools = ["computer_v2_open", "computer_v2_capture", "computer_v2_ax", "computer_v2_snapshot"]
        let calls = try recordedV2Calls(in: task)
        XCTAssertEqual(task.model, selectedModelID)
        XCTAssertEqual(calls.map(\.tool), expectedTools)
        XCTAssertEqual(approvalAudit.approvedActions, ["open", "ax"])
        XCTAssertTrue(approvalAudit.unexpectedRequests.isEmpty)
        XCTAssertTrue(calls.allSatisfy { $0.status == .succeeded })
        guard calls.count == 4 else {
            throw LiveTestFailure(message: "The combined capture turn did not make four V2 calls.")
        }
        XCTAssertTrue(calls[1].outputText.contains("SYNCHRONIZED_AX"))
        XCTAssertNotNil(snapshotIdentifier(inText: calls[1].outputText))
        XCTAssertTrue((calls[1].item["contentItems"] as? [[String: Any]] ?? []).contains {
            $0["type"] as? String == "inputImage"
                && ($0["imageUrl"] as? String)?.hasPrefix("data:image/png;base64,") == true
        })
        XCTAssertNotEqual(
            snapshotIdentifier(inText: calls[1].outputText),
            snapshotIdentifier(inText: calls[3].outputText)
        )
        XCTAssertEqual(
            task.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            completionToken
        )
        let openPID = try XCTUnwrap(processIdentifier(inOpenOutput: calls[0].outputText))
        let displayBefore = try XCTUnwrap(approvalAudit.calculatorDisplayBefore)
        try await waitForCalculatorDigitOneDisplayTransition(
            from: displayBefore,
            processIdentifier: openPID
        )
        let wireTrace = try AppServerWireTrace.load(URL(fileURLWithPath: protocolTracePath))
        XCTAssertTrue(wireTrace.parseFailures.isEmpty)
        XCTAssertTrue(wireTrace.messages.contains { message in
            message.direction == .clientToServer
                && message.method == "thread/start"
        })
        XCTAssertTrue(wireTrace.messages.contains { message in
            message.direction == .serverToClient
                && message.method == "item/tool/call"
                && (message.object["params"] as? [String: Any])?["tool"] as? String
                    == "computer_v2_capture"
        })
    }

    /// An opt-in V2 semantic mutation gate. Only a Calculator launch/activate
    /// and one AXPress on the observed digit-1 button can be approved. The
    /// result is checked through a new, test-owned Accessibility session;
    /// neither the assistant's answer nor its snapshot alone is proof.
    func testProductionRuntimePressesCalculatorDigitOneWithV2() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_CALCULATOR_MUTATION_TEST"] == "1",
            "Set LOCALCODEX_LIVE_CALCULATOR_MUTATION_TEST=1 to run the Calculator V2 mutation gate."
        )
        try XCTSkipUnless(
            PermissionInspector().current().accessibility == .granted,
            "The live test host does not have Accessibility access."
        )
        let calculatorBundleID = "com.apple.calculator"
        try XCTSkipUnless(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: calculatorBundleID) != nil,
            "Calculator is unavailable on this Mac."
        )

        let (state, eventTask, codexHomePath, protocolTracePath) = await makeLiveState()
        defer { eventTask.cancel() }
        try await waitForRuntimeConnection(state: state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let selectedModelID = try selectLiveModelIfRequested(in: state, taskID: taskID)
        let completionToken = "LOCALCODEX_CALCULATOR_DIGIT_ONE_V2_OK_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        let approvalAudit = StrictApprovalAudit()
        let approvalTask = startStrictCalculatorMutationApprovalLoop(
            state: state,
            taskID: taskID,
            bundleID: calculatorBundleID,
            audit: approvalAudit
        )
        defer { approvalTask.cancel() }

        let submitted = await state.submit(
            prompt: """
            Use exactly four tools, in this order: computer_v2_open with {"bundle_id":"\(calculatorBundleID)"}; computer_v2_snapshot with {"query":"1"}; computer_v2_ax with the snapshot_id and element_index for the observed Calculator button labeled 1, ax_action "AXPress"; then computer_v2_snapshot with {"query":"Edit field"}. Read the fresh final snapshot and verify the display changed after pressing 1. Reply with exactly \(completionToken) only after that verification. Do not use any other tools or press any other button.
            """,
            toTaskID: taskID
        )
        guard submitted else {
            throw LiveTestFailure(
                message: "Calculator V2 mutation prompt was not submitted. \(diagnostics(for: state))"
            )
        }

        let completedTask = try await waitForCompletedTask(
            "Calculator V2 digit-one mutation turn",
            state: state,
            taskID: taskID,
            audit: approvalAudit,
            attempts: 3_600
        )
        let expectedTools = [
            ComputerV2ToolContract.Tool.open.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
            ComputerV2ToolContract.Tool.ax.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
        ]
        XCTAssertEqual(completedTask.model, selectedModelID)
        XCTAssertEqual(approvalAudit.approvedActions, ["open", "ax"])
        XCTAssertTrue(
            approvalAudit.unexpectedRequests.isEmpty,
            approvalAudit.unexpectedRequests.joined(separator: "\n")
        )
        XCTAssertEqual(completedTask.entries.compactMap(\.toolEvent).map(\.name), expectedTools)
        let calls = try recordedV2Calls(in: completedTask)
        XCTAssertEqual(calls.map(\.tool), expectedTools)
        XCTAssertTrue(calls.allSatisfy { $0.status == .succeeded })
        guard calls.count == 4 else {
            throw LiveTestFailure(message: "Calculator did not perform exactly four V2 calls.")
        }
        let openPID = try XCTUnwrap(processIdentifier(inOpenOutput: calls[0].outputText))
        let snapshotID = try XCTUnwrap(snapshotIdentifier(inText: calls[1].outputText))
        let digitOneIndex = try XCTUnwrap(
            calculatorDigitOneButtonIndex(in: calls[1].outputText),
            "The model's inspected AX snapshot did not contain one digit-1 button with AXPress."
        )
        let expectedArguments: [[String: Any]] = [
            ["bundle_id": calculatorBundleID],
            ["query": "1"],
            [
                "snapshot_id": snapshotID,
                "element_index": digitOneIndex,
                "ax_action": SemanticAXAction.press.rawValue,
            ],
            ["query": "Edit field"],
        ]
        for (index, call) in calls.enumerated() {
            XCTAssertTrue(
                NSDictionary(dictionary: call.arguments).isEqual(to: expectedArguments[index]),
                "V2 call \(index) did not have the exact approved arguments."
            )
        }
        XCTAssertEqual(
            NSRunningApplication(processIdentifier: openPID)?.bundleIdentifier,
            calculatorBundleID
        )
        XCTAssertTrue(calls[1].outputText.contains("pid=\(openPID) "))
        XCTAssertTrue(calls[1].outputText.contains("bundle=\"\(calculatorBundleID)\""))
        XCTAssertTrue(calls[3].outputText.contains("pid=\(openPID) "))
        XCTAssertTrue(calls[3].outputText.contains("bundle=\"\(calculatorBundleID)\""))
        XCTAssertNotEqual(snapshotIdentifier(inText: calls[3].outputText), snapshotID)
        XCTAssertTrue(
            calls[3].outputText.contains("value=\"1\"") ||
                calls[3].outputText.contains("label=\"Edit field\""),
            "The model's final snapshot did not expose the Calculator display."
        )
        XCTAssertEqual(
            completedTask.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            completionToken
        )

        let displayBefore = try XCTUnwrap(
            approvalAudit.calculatorDisplayBefore,
            "No independent pre-action Calculator display observation was recorded."
        )
        try await waitForCalculatorDigitOneDisplayTransition(
            from: displayBefore,
            processIdentifier: openPID
        )
        let rollout = try await waitForCalculatorV2MutationRolloutTrace(
            in: codexHomePath,
            expectedArguments: expectedArguments,
            processID: openPID,
            bundleID: calculatorBundleID,
            completionToken: completionToken
        )
        let wireTrace = try await waitForCalculatorV2MutationWireTrace(
            at: protocolTracePath,
            expectedArguments: expectedArguments,
            expectedCallIDs: rollout.functionCalls.map(\.callID),
            processID: openPID,
            bundleID: calculatorBundleID
        )
        assertLiveModelInWireTrace(wireTrace, expectedModelID: selectedModelID)
    }

    func testProductionRuntimeControlsChromeFixture() async throws {
        try XCTSkipUnless(
            chromeFixtureSupported,
            "The legacy file-URL Chrome fixture is blocked and is not a V2 computer-use gate."
        )
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_COMPUTER_TEST"] == "1",
            "Set LOCALCODEX_LIVE_COMPUTER_TEST=1 after granting the test host Accessibility access."
        )
        try XCTSkipUnless(
            PermissionInspector().current().accessibility == .granted,
            "The live test host does not have Accessibility access."
        )
        try XCTSkipUnless(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil,
            "Google Chrome is not installed."
        )

        let (state, eventTask, codexHomePath, protocolTracePath) = await makeLiveState()
        defer { eventTask.cancel() }

        try await waitForRuntimeConnection(state: state)

        let fixture = try uniqueFixtureRun(label: "semantic")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let selectedModelID = try selectLiveModelIfRequested(in: state, taskID: taskID)
        let approvalAudit = StrictApprovalAudit()
        let approvalTask = startStrictApprovalLoop(
            state: state,
            taskID: taskID,
            fixture: fixture,
            path: .semantic,
            audit: approvalAudit
        )
        defer { approvalTask.cancel() }
        let submitted = await state.submit(
            prompt: """
            Use computer action open to open com.google.Chrome at \(fixture.url.absoluteString). From the returned process_id, use computer action snapshot with query "Complete computer-use test". Invoke AXPress on that button with computer action ax. Take a fresh computer snapshot with query "\(fixture.completionToken)" and verify the page contains that exact value. Reply with exactly \(fixture.completionToken) only after verification. Use exactly this semantic action order: open, snapshot, ax, snapshot. Do not use coordinates or any other computer action.
            """,
            toTaskID: taskID
        )
        guard submitted else {
            throw LiveTestFailure(
                message: "Semantic Chrome prompt was not submitted. \(diagnostics(for: state))"
            )
        }

        let completedTask = try await waitForCompletedTask(
            "Chrome computer-use turn",
            state: state,
            taskID: taskID,
            audit: approvalAudit,
            attempts: 3_600
        )
        XCTAssertEqual(completedTask.model, selectedModelID)
        let calls = recordedComputerCalls(in: completedTask)
        try assertComputerCalls(
            calls,
            actions: ["open", "snapshot", "ax", "snapshot"],
            state: state
        )
        XCTAssertEqual(approvalAudit.approvedActions, ["open", "ax"])
        XCTAssertTrue(approvalAudit.unexpectedRequests.isEmpty, approvalAudit.unexpectedRequests.joined(separator: "\n"))
        XCTAssertEqual(calls.first?.parameters["bundle_id"] as? String, "com.google.Chrome")
        XCTAssertEqual(calls.first?.parameters["url"] as? String, fixture.url.absoluteString)

        let openProcessID = try XCTUnwrap(
            calls.first.flatMap(returnedProcessIdentifier),
            "The completed open transcript did not contain its returned processIdentifier."
        )
        XCTAssertEqual(processIdentifier(in: calls[1].parameters), openProcessID)
        XCTAssertEqual(calls[1].parameters["query"] as? String, "Complete computer-use test")
        XCTAssertEqual(processIdentifier(in: calls[2].parameters), openProcessID)
        XCTAssertEqual(calls[2].parameters["ax_action"] as? String, SemanticAXAction.press.rawValue)
        XCTAssertEqual(
            calls[2].parameters["snapshot_id"] as? String,
            returnedSnapshotIdentifier(in: calls[1])
        )
        XCTAssertEqual(processIdentifier(in: calls[3].parameters), openProcessID)
        XCTAssertEqual(calls[3].parameters["query"] as? String, fixture.completionToken)
        XCTAssertEqual(
            completedTask.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            fixture.completionToken
        )

        // The assistant knows the expected token from the prompt, so its final
        // message is not proof that the browser action actually happened.
        // Verify the unique post-action page state through a fresh, test-owned
        // Accessibility session bound to the exact Chrome process returned by
        // this run, independent of the runtime cache and the model response.
        try await waitForChromeAccessibilityValue(
            fixture.completionToken,
            processIdentifier: openProcessID
        )
        _ = try await waitForRolloutPrimitiveTrace(
            in: codexHomePath,
            expectedActions: ["open", "snapshot", "ax", "snapshot"],
            completionToken: fixture.completionToken
        )
        let wireTrace = try await waitForAppServerWireTrace(
            at: protocolTracePath,
            expectedActions: ["open", "snapshot", "ax", "snapshot"],
            completionToken: fixture.completionToken
        )
        assertLiveModelInWireTrace(wireTrace, expectedModelID: selectedModelID)
    }

    func testProductionRuntimeVisuallyControlsChromeFixture() async throws {
        try XCTSkipUnless(
            chromeFixtureSupported,
            "The legacy file-URL Chrome fixture is blocked and is not a V2 computer-use gate."
        )
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_VISUAL_COMPUTER_TEST"] == "1",
            "Set LOCALCODEX_LIVE_VISUAL_COMPUTER_TEST=1 after granting the test host computer-use permissions."
        )
        let permissions = PermissionInspector().current()
        try XCTSkipUnless(
            permissions.accessibility == .granted,
            "The live test host does not have Accessibility access."
        )
        try XCTSkipUnless(
            permissions.screenRecording == .granted,
            "The live test host does not have Screen Recording access."
        )
        try XCTSkipUnless(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil,
            "Google Chrome is not installed."
        )

        let (state, eventTask, codexHomePath, protocolTracePath) = await makeLiveState()
        defer { eventTask.cancel() }

        try await waitForRuntimeConnection(state: state)

        let fixture = try uniqueFixtureRun(label: "visual")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let selectedModelID = try selectLiveModelIfRequested(in: state, taskID: taskID)
        let approvalAudit = StrictApprovalAudit()
        let approvalTask = startStrictApprovalLoop(
            state: state,
            taskID: taskID,
            fixture: fixture,
            path: .visual,
            audit: approvalAudit
        )
        defer { approvalTask.cancel() }
        let submitted = await state.submit(
            prompt: """
            Open com.google.Chrome at \(fixture.url.absoluteString) and keep its returned process_id. Capture the display exactly once. From that image, locate the purple "Complete computer-use test" button and use computer action click at its screen coordinates with that process_id. Do not use ax, set_text, or another capture. Then use one snapshot with query "\(fixture.completionToken)" on the same process_id. Reply exactly \(fixture.completionToken) only if the snapshot contains that exact value. Required action order: open, capture, click, snapshot. Do not use any other computer action.
            """,
            toTaskID: taskID
        )
        guard submitted else {
            throw LiveTestFailure(
                message: "Visual Chrome prompt was not submitted. \(diagnostics(for: state))"
            )
        }

        let completedTask = try await waitForCompletedTask(
            "visual Chrome computer-use turn",
            state: state,
            taskID: taskID,
            audit: approvalAudit,
            attempts: 3_600
        )
        XCTAssertEqual(completedTask.model, selectedModelID)
        let calls = recordedComputerCalls(in: completedTask)
        try assertComputerCalls(
            calls,
            actions: ["open", "capture", "click", "snapshot"],
            state: state
        )
        XCTAssertEqual(approvalAudit.approvedActions, ["open", "click"])
        XCTAssertTrue(approvalAudit.unexpectedRequests.isEmpty, approvalAudit.unexpectedRequests.joined(separator: "\n"))
        XCTAssertEqual(
            calls.filter { $0.action == "capture" }.count,
            1,
            "The visual smoke test must put exactly one screenshot in the 4K context."
        )
        XCTAssertEqual(calls.first?.parameters["bundle_id"] as? String, "com.google.Chrome")
        XCTAssertEqual(calls.first?.parameters["url"] as? String, fixture.url.absoluteString)

        let openProcessID = try XCTUnwrap(
            calls.first.flatMap(returnedProcessIdentifier),
            "The completed open transcript did not contain its returned processIdentifier."
        )
        let clickProcessID = calls.first(where: { $0.action == "click" })
            .flatMap { processIdentifier(in: $0.parameters) }
        let snapshotProcessID = calls.first(where: { $0.action == "snapshot" })
            .flatMap { processIdentifier(in: $0.parameters) }
        XCTAssertEqual(clickProcessID, openProcessID)
        XCTAssertEqual(snapshotProcessID, openProcessID)
        XCTAssertNotNil(calls.first(where: { $0.action == "click" })?.parameters["x"] as? NSNumber)
        XCTAssertNotNil(calls.first(where: { $0.action == "click" })?.parameters["y"] as? NSNumber)
        XCTAssertEqual(
            calls.first(where: { $0.action == "snapshot" })?.parameters["query"] as? String,
            fixture.completionToken
        )
        XCTAssertEqual(
            completedTask.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            fixture.completionToken
        )

        // The transcript and final answer are model-controlled, so confirm the
        // unique browser state in the exact Chrome process opened for this run.
        try await waitForChromeAccessibilityValue(
            fixture.completionToken,
            processIdentifier: openProcessID
        )
        _ = try await waitForRolloutPrimitiveTrace(
            in: codexHomePath,
            expectedActions: ["open", "capture", "click", "snapshot"],
            completionToken: fixture.completionToken,
            requiresScreenshotOutput: true
        )
        let wireTrace = try await waitForAppServerWireTrace(
            at: protocolTracePath,
            expectedActions: ["open", "capture", "click", "snapshot"],
            completionToken: fixture.completionToken,
            requiresScreenshotOutput: true
        )
        assertLiveModelInWireTrace(wireTrace, expectedModelID: selectedModelID)
    }

    func testUniqueFixtureRunEmbedsTokenWithoutFileURLQuery() throws {
        let fixture = try uniqueFixtureRun(label: "unit")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.url.deletingLastPathComponent()
            )
        }

        XCTAssertNil(URLComponents(url: fixture.url, resolvingAgainstBaseURL: false)?.query)
        let source = try String(contentsOf: fixture.url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("const embeddedCompletionToken = \"\(fixture.completionToken)\";")
        )
        XCTAssertFalse(source.contains("const embeddedCompletionToken = null;"))
    }

    func testRecordedComputerCallsKeepEveryStatusAndParseFailure() throws {
        let openItem: [String: Any] = [
            "type": "dynamicToolCall",
            "tool": "computer",
            "status": "completed",
            "success": true,
            "arguments": [
                "action": "open",
                "parameters": [
                    "bundle_id": "com.google.Chrome",
                    "url": "file:///tmp/fixture.html?run=unique",
                ],
            ],
            "contentItems": [[
                "type": "inputText",
                "text": "{\n  \"processIdentifier\" : 42\n}\nApplication action completed.",
            ]],
        ]
        let captureItem: [String: Any] = [
            "type": "dynamicToolCall",
            "tool": "computer",
            "status": "completed",
            "success": true,
            "arguments": #"{"action":"capture","parameters":{"shows_cursor":true}}"#,
        ]
        let clickItem: [String: Any] = [
            "type": "dynamicToolCall",
            "tool": "computer",
            "status": "failed",
            "success": false,
            "arguments": [
                "action": "click",
                "parameters": ["process_id": 42, "x": 100, "y": 200],
            ],
        ]
        var entries = try [
            (openItem, ToolRunStatus.succeeded),
            (captureItem, ToolRunStatus.succeeded),
            (clickItem, ToolRunStatus.failed),
        ].map { item, status in
            TimelineEntry(
                kind: .tool,
                title: "computer",
                body: "computer completed",
                toolEvent: ToolEvent(
                    name: "computer",
                    summary: "computer completed",
                    status: status,
                    input: try jsonString(item),
                    output: nil,
                    duration: nil
                )
            )
        }
        entries.append(
            TimelineEntry(
                kind: .tool,
                title: "computer",
                body: "malformed transcript item",
                toolEvent: ToolEvent(
                    name: "computer",
                    summary: "computer failed",
                    status: .failed,
                    input: "not JSON",
                    output: nil,
                    duration: nil
                )
            )
        )
        let task = AgentTask(
            title: "Transcript parser fixture",
            summary: "",
            status: .completed,
            workspace: "/tmp",
            model: "test",
            entries: entries
        )

        let calls = recordedComputerCalls(in: task)
        XCTAssertEqual(calls.map { $0.action ?? "<unparsed>" }, ["open", "capture", "click", "<unparsed>"])
        XCTAssertEqual(calls.map { $0.status.rawValue }, ["succeeded", "succeeded", "failed", "failed"])
        XCTAssertNil(calls[0].parseFailure)
        XCTAssertNotNil(calls[3].parseFailure)
        XCTAssertEqual(returnedProcessIdentifier(in: calls[0]), 42)
        XCTAssertEqual(processIdentifier(in: calls[2].parameters), 42)
    }

    func testStrictApprovalPolicyChecksURLSequenceSnapshotAndProcess() throws {
        let fixture = FixtureRun(
            url: try XCTUnwrap(URL(string: "file:///tmp/fixture.html?completion_token=unique")),
            completionToken: "LOCALCODEX_CHROME_OK_UNIQUE"
        )
        let taskID = "task"
        let openRequest = ActionApprovalRequest(
            id: "open",
            taskID: taskID,
            kind: .computerUse,
            title: "Allow an application action?",
            summary: "Open com.google.Chrome at \(fixture.url.absoluteString)",
            details: try jsonString([
                "bundle_id": "com.google.Chrome",
                "url": fixture.url.absoluteString,
            ])
        )
        XCTAssertTrue(
            strictApprovalDecision(
                request: openRequest,
                expectedTaskID: taskID,
                fixture: fixture,
                path: .semantic,
                approvedMutationCount: 0,
                completedCalls: []
            ).approved
        )

        let wrongURLRequest = ActionApprovalRequest(
            id: "wrong-open",
            taskID: taskID,
            kind: .computerUse,
            title: "Allow an application action?",
            summary: "Open com.google.Chrome at file:///tmp/wrong.html",
            details: try jsonString([
                "bundle_id": "com.google.Chrome",
                "url": "file:///tmp/wrong.html",
            ])
        )
        XCTAssertFalse(
            strictApprovalDecision(
                request: wrongURLRequest,
                expectedTaskID: taskID,
                fixture: fixture,
                path: .semantic,
                approvedMutationCount: 0,
                completedCalls: []
            ).approved
        )

        let snapshotID = UUID().uuidString
        let completedCalls = [
            RecordedComputerCall(
                item: ["contentItems": [[
                    "type": "inputText",
                    "text": "{\"processIdentifier\":42}",
                ]]],
                arguments: [
                    "action": "open",
                    "parameters": [
                        "bundle_id": "com.google.Chrome",
                        "url": fixture.url.absoluteString,
                    ],
                ],
                status: .succeeded,
                parseFailure: nil
            ),
            RecordedComputerCall(
                item: ["contentItems": [[
                    "type": "inputText",
                    "text": """
                    AXSNAPSHOT id=\(snapshotID) pid=42
                    #7 role="AXButton" label="Complete computer-use test" value=- actions=["AXPress"] settable=0
                    """,
                ]]],
                arguments: [
                    "action": "snapshot",
                    "parameters": [
                        "process_id": 42,
                        "query": "Complete computer-use test",
                    ],
                ],
                status: .succeeded,
                parseFailure: nil
            ),
        ]
        let axRequest = ActionApprovalRequest(
            id: "ax",
            taskID: taskID,
            kind: .computerUse,
            title: "Allow a desktop action?",
            summary: "AXPress on Complete computer-use test",
            details: try jsonString([
                "action": SemanticAXAction.press.rawValue,
                "ax_action": SemanticAXAction.press.rawValue,
                "process_id": 42,
                "snapshot_id": snapshotID,
                "element_index": 7,
            ])
        )
        XCTAssertTrue(
            strictApprovalDecision(
                request: axRequest,
                expectedTaskID: taskID,
                fixture: fixture,
                path: .semantic,
                approvedMutationCount: 1,
                completedCalls: completedCalls
            ).approved
        )

        let wrongSemanticTargetRequest = ActionApprovalRequest(
            id: "wrong-semantic-target",
            taskID: taskID,
            kind: .computerUse,
            title: axRequest.title,
            summary: "AXPress on Back",
            details: axRequest.details
        )
        XCTAssertFalse(
            strictApprovalDecision(
                request: wrongSemanticTargetRequest,
                expectedTaskID: taskID,
                fixture: fixture,
                path: .semantic,
                approvedMutationCount: 1,
                completedCalls: completedCalls
            ).approved
        )

        let wrongProcessRequest = ActionApprovalRequest(
            id: "wrong-pid",
            taskID: taskID,
            kind: .computerUse,
            title: axRequest.title,
            summary: axRequest.summary,
            details: try jsonString([
                "action": SemanticAXAction.press.rawValue,
                "ax_action": SemanticAXAction.press.rawValue,
                "process_id": 99,
                "snapshot_id": snapshotID,
                "element_index": 7,
            ])
        )
        XCTAssertFalse(
            strictApprovalDecision(
                request: wrongProcessRequest,
                expectedTaskID: taskID,
                fixture: fixture,
                path: .semantic,
                approvedMutationCount: 1,
                completedCalls: completedCalls
            ).approved
        )

        let visualCalls = [
            completedCalls[0],
            RecordedComputerCall(
                item: [:],
                arguments: ["action": "capture", "parameters": [:]],
                status: .succeeded,
                parseFailure: nil
            ),
        ]
        let clickRequest = ActionApprovalRequest(
            id: "click",
            taskID: taskID,
            kind: .computerUse,
            title: "Allow computer input?",
            summary: "Click at (100.0, 200.0)",
            details: try jsonString([
                "action": "click",
                "process_id": 42,
                "x": 100,
                "y": 200,
            ])
        )
        let fixtureButtonFrame = WindowFrame(x: 90, y: 190, width: 20, height: 20)
        XCTAssertTrue(
            strictApprovalDecision(
                request: clickRequest,
                expectedTaskID: taskID,
                fixture: fixture,
                path: .visual,
                approvedMutationCount: 1,
                completedCalls: visualCalls,
                fixtureButtonFrameOverride: fixtureButtonFrame
            ).approved
        )

        let outOfButtonClickRequest = ActionApprovalRequest(
            id: "click-outside-button",
            taskID: taskID,
            kind: .computerUse,
            title: clickRequest.title,
            summary: "Click at (500.0, 500.0)",
            details: try jsonString([
                "action": "click",
                "process_id": 42,
                "x": 500,
                "y": 500,
            ])
        )
        XCTAssertFalse(
            strictApprovalDecision(
                request: outOfButtonClickRequest,
                expectedTaskID: taskID,
                fixture: fixture,
                path: .visual,
                approvedMutationCount: 1,
                completedCalls: visualCalls,
                fixtureButtonFrameOverride: fixtureButtonFrame
            ).approved
        )

        let extraKeyClickRequest = ActionApprovalRequest(
            id: "click-extra",
            taskID: taskID,
            kind: .computerUse,
            title: clickRequest.title,
            summary: clickRequest.summary,
            details: try jsonString([
                "action": "click",
                "process_id": 42,
                "x": 100,
                "y": 200,
                "text": "unexpected",
            ])
        )
        XCTAssertFalse(
            strictApprovalDecision(
                request: extraKeyClickRequest,
                expectedTaskID: taskID,
                fixture: fixture,
                path: .visual,
                approvedMutationCount: 1,
                completedCalls: visualCalls,
                fixtureButtonFrameOverride: fixtureButtonFrame
            ).approved
        )
    }

    func testReadOnlyV2RolloutPrimitiveContract() {
        let callID = "call_v2_status"
        let trace = RolloutPrimitiveTrace(
            rolloutURL: URL(fileURLWithPath: "/tmp/rollout-v2-status.jsonl"),
            dynamicTools: ComputerV2ToolContract.specs,
            functionCalls: [
                .init(callID: callID, name: ComputerV2ToolContract.Tool.status.rawValue, arguments: [:]),
            ],
            functionCallOutputs: [
                .init(callID: callID, output: "{\"accessibility\":\"granted\"}"),
            ],
            assistantMessages: ["LOCAL_COMPUTER_TOOL_OK"],
            parseFailures: []
        )

        XCTAssertNil(rolloutPrimitiveFailure(
            trace,
            expectedActions: [ComputerV2ToolContract.Tool.status.rawValue],
            completionToken: "LOCAL_COMPUTER_TOOL_OK",
            requiresScreenshotOutput: false,
            v2StatusOnly: true
        ))
        let malformedCall = RolloutPrimitiveTrace(
            rolloutURL: trace.rolloutURL,
            dynamicTools: trace.dynamicTools,
            functionCalls: [
                .init(callID: callID, name: ComputerV2ToolContract.Tool.status.rawValue, arguments: ["action": "permission_status"]),
            ],
            functionCallOutputs: trace.functionCallOutputs,
            assistantMessages: trace.assistantMessages,
            parseFailures: []
        )
        XCTAssertNotNil(rolloutPrimitiveFailure(
            malformedCall,
            expectedActions: [ComputerV2ToolContract.Tool.status.rawValue],
            completionToken: "LOCAL_COMPUTER_TOOL_OK",
            requiresScreenshotOutput: false,
            v2StatusOnly: true
        ))
    }

    func testReadOnlyV2AppServerWireContract() throws {
        let tool = ComputerV2ToolContract.Tool.status.rawValue
        func message(
            _ sequence: Int,
            _ direction: AppServerWireTrace.Direction,
            _ object: [String: Any]
        ) throws -> AppServerWireTrace.Message {
            let wireData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                + Data([0x0A])
            return .init(sequence: sequence, direction: direction, wireData: wireData, object: object)
        }

        let messages = try [
            message(1, .clientToServer, [
                "id": 1, "method": "thread/start",
                "params": ["dynamicTools": ComputerV2ToolContract.specs],
            ]),
            message(2, .serverToClient, [
                "method": "item/started",
                "params": ["item": [
                    "type": "dynamicToolCall", "id": "call_v2_status", "status": "inProgress",
                ]],
            ]),
            message(3, .serverToClient, [
                "id": 2, "method": "item/tool/call",
                "params": [
                    "tool": tool, "arguments": [:], "callId": "call_v2_status",
                    "threadId": "thread_1", "turnId": "turn_1",
                ],
            ]),
            message(4, .clientToServer, [
                "id": 2, "result": [
                    "success": true,
                    "contentItems": [["type": "inputText", "text": "Accessibility granted"]],
                ],
            ]),
            message(5, .serverToClient, [
                "method": "item/completed",
                "params": ["item": [
                    "type": "dynamicToolCall", "id": "call_v2_status",
                    "status": "completed", "success": true,
                    "contentItems": [["type": "inputText", "text": "Accessibility granted"]],
                ]],
            ]),
        ]
        let trace = AppServerWireTrace(messages: messages, parseFailures: [])

        XCTAssertNil(appServerWireFailure(
            trace,
            expectedActions: [tool],
            completionToken: "LOCAL_COMPUTER_TOOL_OK",
            requiresScreenshotOutput: false,
            v2StatusOnly: true
        ))
        let missingLifecycle = AppServerWireTrace(messages: Array(messages.dropLast()), parseFailures: [])
        XCTAssertNotNil(appServerWireFailure(
            missingLifecycle,
            expectedActions: [tool],
            completionToken: "LOCAL_COMPUTER_TOOL_OK",
            requiresScreenshotOutput: false,
            v2StatusOnly: true
        ))
    }

    func testCalculatorV2ApprovalAllowsOnlyFirstExactOpen() throws {
        let taskID = "calculator-task"
        let bundleID = "com.apple.calculator"
        let exact = ActionApprovalRequest(
            id: "open",
            taskID: taskID,
            kind: .computerUse,
            title: "Allow an application action?",
            summary: "Launch or activate \(bundleID)",
            details: try jsonString(["bundle_id": bundleID])
        )
        XCTAssertTrue(strictCalculatorOpenApprovalDecision(
            exact,
            taskID: taskID,
            bundleID: bundleID,
            approvedMutationCount: 0,
            hasNoPriorComputerCalls: true
        ))
        XCTAssertFalse(strictCalculatorOpenApprovalDecision(
            exact,
            taskID: taskID,
            bundleID: bundleID,
            approvedMutationCount: 1,
            hasNoPriorComputerCalls: true
        ))
        XCTAssertFalse(strictCalculatorOpenApprovalDecision(
            exact,
            taskID: taskID,
            bundleID: bundleID,
            approvedMutationCount: 0,
            hasNoPriorComputerCalls: false
        ))

        let redirected = ActionApprovalRequest(
            id: "redirected",
            taskID: taskID,
            kind: .computerUse,
            title: exact.title,
            summary: exact.summary,
            details: try jsonString([
                "bundle_id": bundleID,
                "url": "https://example.com",
            ])
        )
        XCTAssertFalse(strictCalculatorOpenApprovalDecision(
            redirected,
            taskID: taskID,
            bundleID: bundleID,
            approvedMutationCount: 0,
            hasNoPriorComputerCalls: true
        ))
    }

    func testCalculatorV2MutationApprovalRequiresObservedDigitOne() throws {
        let taskID = "calculator-task"
        let bundleID = "com.apple.calculator"
        let snapshotID = UUID().uuidString
        let calls = [
            RecordedV2Call(
                tool: ComputerV2ToolContract.Tool.open.rawValue,
                item: ["contentItems": [[
                    "type": "inputText",
                    "text": "{\"processIdentifier\":42,\"bundleIdentifier\":\"\(bundleID)\"}",
                ]]],
                arguments: ["bundle_id": bundleID],
                status: .succeeded
            ),
            RecordedV2Call(
                tool: ComputerV2ToolContract.Tool.snapshot.rawValue,
                item: ["contentItems": [[
                    "type": "inputText",
                    "text": """
                    AXSNAPSHOT id=\(snapshotID) pid=42 app="Calculator" bundle="\(bundleID)" root=0 shown=2 total=2
                    #7 role="AXButton" label="1" value=- actions=["AXPress"] settable=0
                    """,
                ]]],
                arguments: ["query": "1"],
                status: .succeeded
            ),
        ]
        func request(index: Int, action: String = "AXPress") throws -> ActionApprovalRequest {
            ActionApprovalRequest(
                id: "digit-one",
                taskID: taskID,
                kind: .computerUse,
                title: "Allow a desktop action?",
                summary: "AXPress on 1",
                details: try jsonString([
                    "model_arguments": [
                        "snapshot_id": snapshotID,
                        "element_index": index,
                        "ax_action": action,
                    ],
                    "resolved_target": ["bundle_id": bundleID, "process_id": 42],
                ])
            )
        }
        XCTAssertTrue(strictCalculatorMutationApprovalDecision(
            try request(index: 7),
            taskID: taskID,
            bundleID: bundleID,
            approvedMutationCount: 1,
            completedCalls: calls
        ).approved)
        XCTAssertFalse(strictCalculatorMutationApprovalDecision(
            try request(index: 8),
            taskID: taskID,
            bundleID: bundleID,
            approvedMutationCount: 1,
            completedCalls: calls
        ).approved)
        XCTAssertFalse(strictCalculatorMutationApprovalDecision(
            try request(index: 7, action: "AXShowMenu"),
            taskID: taskID,
            bundleID: bundleID,
            approvedMutationCount: 1,
            completedCalls: calls
        ).approved)
        XCTAssertFalse(strictCalculatorMutationApprovalDecision(
            try request(index: 7),
            taskID: taskID,
            bundleID: bundleID,
            approvedMutationCount: 2,
            completedCalls: calls
        ).approved)
    }

    private func selectLiveModelIfRequested(in state: AppState, taskID: AgentTask.ID) throws -> String {
        let modelID = ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_ID"]
            ?? LocalModelCatalog.defaultModelID
        guard LocalModelCatalog.option(for: modelID) != nil else {
            throw LiveTestFailure(message: "LOCALCODEX_LIVE_MODEL_ID is not a catalog model: \(modelID)")
        }
        guard state.setTaskModel(modelID, taskID: taskID) else {
            throw LiveTestFailure(message: "Could not select the requested live model for the new task.")
        }
        return modelID
    }

    private func recordedV2Calls(in task: AgentTask) throws -> [RecordedV2Call] {
        try task.entries.compactMap { entry in
            guard let event = entry.toolEvent,
                  event.name.hasPrefix("computer_v2_") || entry.toolEvent?.name == "computer"
            else { return nil }
            guard let item = jsonObject(from: event.input),
                  item["tool"] as? String == event.name,
                  let arguments = jsonObject(from: item["arguments"])
            else {
                throw LiveTestFailure(
                    message: "Malformed V2 computer transcript item for \(event.name)."
                )
            }
            return RecordedV2Call(
                tool: event.name,
                item: item,
                arguments: arguments,
                status: event.status
            )
        }
    }

    private func processIdentifier(inOpenOutput text: String) -> Int32? {
        guard let expression = try? NSRegularExpression(
            pattern: #""processIdentifier"\s*:\s*(\d+)"#
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int32(text[valueRange])
    }

    private func snapshotIdentifier(inText text: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"AXSNAPSHOT id=([0-9A-Fa-f-]{36})"#
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              UUID(uuidString: String(text[valueRange])) != nil
        else { return nil }
        return String(text[valueRange])
    }

    private func calculatorDigitOneButtonIndex(in text: String) -> Int? {
        let candidates = text.split(separator: "\n").compactMap { line -> Int? in
            guard line.contains("role=\"AXButton\" label=\"1\""),
                  line.contains("\"AXPress\""),
                  line.first == "#",
                  let space = line.firstIndex(of: " ")
            else { return nil }
            return Int(line[line.index(after: line.startIndex)..<space])
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func calculatorDisplayElement(
        in snapshot: AccessibilityTreeSnapshot
    ) -> AccessibilityTreeElement? {
        let candidates = snapshot.elements.filter { element in
            element.role == "AXStaticText"
                && element.elementDescription == "Edit field"
                && element.value != nil
                && element.frame != nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func testOwnedCalculatorDisplay(processIdentifier: Int32) -> AccessibilityTreeElement? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.bundleIdentifier == "com.apple.calculator",
              !application.isTerminated,
              let limits = try? AccessibilityTreeLimits(
                  maxDepth: 16,
                  maxElements: 1_000,
                  maxChildrenPerElement: 200,
                  maxActionsPerElement: 32,
                  maxTextLength: 1_024
              )
        else { return nil }
        let session = AccessibilitySession(
            processIdentifier: processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        )
        guard let snapshot = try? session.snapshot(limits: limits) else { return nil }
        return calculatorDisplayElement(in: snapshot)
    }

    private func normalizedCalculatorInteger(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty,
              value.allSatisfy({ $0.isNumber || $0 == "," || $0 == " " })
        else { return nil }
        return digits
    }

    private func calculatorDisplayTransitionMatches(
        before: AccessibilityTreeElement,
        after: AccessibilityTreeElement
    ) -> Bool {
        guard before.role == after.role,
              before.elementDescription == after.elementDescription,
              before.frame != nil,
              after.frame != nil,
              let previous = normalizedCalculatorInteger(before.value),
              let actual = normalizedCalculatorInteger(after.value),
              previous != actual
        else { return false }
        let expected = previous == "0" ? "1" : previous + "1"
        return actual == expected
    }

    private func waitForCalculatorDigitOneDisplayTransition(
        from before: AccessibilityTreeElement,
        processIdentifier: Int32,
        attempts: Int = 80
    ) async throws {
        var lastValue = "unavailable"
        for _ in 0..<attempts {
            if let after = testOwnedCalculatorDisplay(processIdentifier: processIdentifier) {
                lastValue = after.value ?? "nil"
                if calculatorDisplayTransitionMatches(before: before, after: after) {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LiveTestFailure(
            message: "Independent Calculator display did not append digit 1 after AXPress. "
                + "Before=\(String(reflecting: before.value)); after=\(String(reflecting: lastValue))."
        )
    }

    private func startStrictCalculatorMutationApprovalLoop(
        state: AppState,
        taskID: AgentTask.ID,
        bundleID: String,
        audit: StrictApprovalAudit,
        combinedCapture: Bool = false
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for request in state.pendingApprovals
                where !audit.handledRequestIDs.contains(request.id) {
                    audit.handledRequestIDs.insert(request.id)
                    let calls = state.tasks.first(where: { $0.id == taskID })
                        .flatMap { try? recordedV2Calls(in: $0) } ?? []
                    let decision = strictCalculatorMutationApprovalDecision(
                        request,
                        taskID: taskID,
                        bundleID: bundleID,
                        approvedMutationCount: audit.approvedActions.count,
                        completedCalls: calls,
                        combinedCapture: combinedCapture
                    )
                    var approved = decision.approved
                    if approved && decision.action == "ax" {
                        let processID = calls.first.flatMap {
                            processIdentifier(inOpenOutput: $0.outputText)
                        }
                        let display = processID.flatMap {
                            testOwnedCalculatorDisplay(processIdentifier: $0)
                        }
                        if let display,
                           normalizedCalculatorInteger(display.value) != nil {
                            audit.calculatorDisplayBefore = display
                        } else {
                            approved = false
                        }
                    }
                    if approved {
                        audit.approvedActions.append(decision.action)
                    } else {
                        audit.unexpectedRequests.append(
                            "Declined unexpected Calculator \(decision.action) approval \(request.id): \(decision.reason)"
                        )
                        audit.resolvingRejectedRequest = true
                    }
                    await state.resolveApproval(request, approved: approved)
                    if !approved {
                        audit.resolvingRejectedRequest = false
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    private func strictCalculatorMutationApprovalDecision(
        _ request: ActionApprovalRequest,
        taskID: AgentTask.ID,
        bundleID: String,
        approvedMutationCount: Int,
        completedCalls: [RecordedV2Call],
        combinedCapture: Bool = false
    ) -> StrictApprovalDecision {
        func reject(_ action: String, _ reason: String) -> StrictApprovalDecision {
            StrictApprovalDecision(approved: false, action: action, reason: reason)
        }
        guard request.taskID == taskID,
              request.kind == .computerUse
        else { return reject("unknown", "request did not target this computer-use task") }
        if approvedMutationCount == 0 {
            let approved = strictCalculatorOpenApprovalDecision(
                request,
                taskID: taskID,
                bundleID: bundleID,
                approvedMutationCount: 0,
                hasNoPriorComputerCalls: completedCalls.isEmpty
            )
            return StrictApprovalDecision(
                approved: approved,
                action: "open",
                reason: approved ? "exact Calculator open" : "not the exact first Calculator open"
            )
        }
        let secondTool = combinedCapture
            ? ComputerV2ToolContract.Tool.capture.rawValue
            : ComputerV2ToolContract.Tool.snapshot.rawValue
        guard approvedMutationCount == 1,
              completedCalls.map(\.tool) == [
                  ComputerV2ToolContract.Tool.open.rawValue, secondTool,
              ],
              completedCalls.allSatisfy({ $0.status == .succeeded }),
              completedCalls[0].arguments.count == 1,
              completedCalls[0].arguments["bundle_id"] as? String == bundleID,
              completedCalls[1].arguments.count == 1,
              (combinedCapture
                  ? completedCalls[1].arguments["include_accessibility"] as? Bool == true
                  : completedCalls[1].arguments["query"] as? String == "1"),
              let processID = processIdentifier(inOpenOutput: completedCalls[0].outputText),
              let snapshotID = snapshotIdentifier(inText: completedCalls[1].outputText),
              completedCalls[1].outputText.contains("pid=\(processID) "),
              completedCalls[1].outputText.contains("bundle=\"\(bundleID)\""),
              (!combinedCapture || completedCalls[1].outputText.contains("SYNCHRONIZED_AX")),
              let digitOneIndex = calculatorDigitOneButtonIndex(in: completedCalls[1].outputText)
        else { return reject("ax", "the exact open and inspected digit-1 snapshot were absent") }
        let details = jsonObject(from: request.details)
        let modelArguments = jsonObject(from: details?["model_arguments"])
        let target = jsonObject(from: details?["resolved_target"])
        guard request.title == "Allow a desktop action?",
              request.summary == "AXPress on 1",
              Set(details?.keys.map { $0 } ?? []) == ["model_arguments", "resolved_target"],
              Set(modelArguments?.keys.map { $0 } ?? []) == [
                  "snapshot_id", "element_index", "ax_action",
              ],
              modelArguments?["snapshot_id"] as? String == snapshotID,
              (modelArguments?["element_index"] as? NSNumber)?.intValue == digitOneIndex,
              modelArguments?["ax_action"] as? String == SemanticAXAction.press.rawValue,
              Set(target?.keys.map { $0 } ?? []) == ["bundle_id", "process_id"],
              target?["bundle_id"] as? String == bundleID,
              (target?["process_id"] as? NSNumber)?.int32Value == processID
        else { return reject("ax", "approval was not AXPress on the inspected digit-1 button") }
        return StrictApprovalDecision(approved: true, action: "ax", reason: "exact digit-1 press")
    }

    private func waitForCalculatorV2MutationRolloutTrace(
        in codexHomePath: String,
        expectedArguments: [[String: Any]],
        processID: Int32,
        bundleID: String,
        completionToken: String,
        attempts: Int = 80
    ) async throws -> RolloutPrimitiveTrace {
        var lastFailure = "The rollout file has not appeared yet."
        for _ in 0..<attempts {
            do {
                let trace = try RolloutPrimitiveTrace.loadLatest(in: codexHomePath)
                if let failure = calculatorV2MutationRolloutFailure(
                    trace,
                    expectedArguments: expectedArguments,
                    processID: processID,
                    bundleID: bundleID,
                    completionToken: completionToken
                ) {
                    lastFailure = failure
                } else { return trace }
            } catch { lastFailure = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LiveTestFailure(message: "Calculator mutation rollout did not converge: \(lastFailure)")
    }

    private func calculatorV2MutationRolloutFailure(
        _ trace: RolloutPrimitiveTrace,
        expectedArguments: [[String: Any]],
        processID: Int32,
        bundleID: String,
        completionToken: String
    ) -> String? {
        let tools = [
            ComputerV2ToolContract.Tool.open.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
            ComputerV2ToolContract.Tool.ax.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
        ]
        let registered = trace.dynamicTools.compactMap { $0["name"] as? String }
        let expectedRegistered = ComputerV2ToolContract.Tool.allCases.map(\.rawValue)
        guard trace.parseFailures.isEmpty,
              registered.count == expectedRegistered.count,
              Set(registered) == Set(expectedRegistered),
              trace.dynamicTools.allSatisfy({ $0["type"] as? String == "function" }),
              trace.functionCalls.map(\.name) == tools,
              trace.functionCalls.count == expectedArguments.count
        else { return "The persisted rollout did not register/call the exact V2 sequence" }
        for (index, call) in trace.functionCalls.enumerated() {
            guard NSDictionary(dictionary: call.arguments).isEqual(to: expectedArguments[index]) else {
                return "Persisted V2 call \(index) arguments differed"
            }
        }
        let callIDs = trace.functionCalls.map(\.callID)
        guard Set(callIDs).count == tools.count,
              trace.functionCallOutputs.map(\.callID) == callIDs,
              let open = trace.output(for: callIDs[0]) as? String,
              processIdentifier(inOpenOutput: open) == processID,
              open.contains(bundleID),
              let firstSnapshot = trace.output(for: callIDs[1]) as? String,
              firstSnapshot.contains("pid=\(processID) "),
              firstSnapshot.contains("bundle=\"\(bundleID)\""),
              let ax = trace.output(for: callIDs[2]) as? String,
              ax.contains("Requested AXPress"),
              let finalSnapshot = trace.output(for: callIDs[3]) as? String,
              finalSnapshot.contains("pid=\(processID) "),
              finalSnapshot.contains("bundle=\"\(bundleID)\""),
              snapshotIdentifier(inText: firstSnapshot) != snapshotIdentifier(inText: finalSnapshot)
        else { return "Persisted V2 call IDs or bound Calculator outputs differed" }
        let final = trace.assistantMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        return final == completionToken ? nil : "Persisted final answer did not match the completion token"
    }

    private func waitForCalculatorV2MutationWireTrace(
        at path: String,
        expectedArguments: [[String: Any]],
        expectedCallIDs: [String],
        processID: Int32,
        bundleID: String,
        attempts: Int = 80
    ) async throws -> AppServerWireTrace {
        var lastFailure = "The raw App Server trace has not appeared yet."
        for _ in 0..<attempts {
            do {
                let trace = try AppServerWireTrace.load(URL(fileURLWithPath: path))
                if let failure = calculatorV2MutationWireFailure(
                    trace,
                    expectedArguments: expectedArguments,
                    expectedCallIDs: expectedCallIDs,
                    processID: processID,
                    bundleID: bundleID
                ) {
                    lastFailure = failure
                } else { return trace }
            } catch { lastFailure = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LiveTestFailure(message: "Calculator mutation wire trace did not converge: \(lastFailure)")
    }

    private func calculatorV2MutationWireFailure(
        _ trace: AppServerWireTrace,
        expectedArguments: [[String: Any]],
        expectedCallIDs: [String],
        processID: Int32,
        bundleID: String
    ) -> String? {
        guard !trace.messages.isEmpty,
              trace.parseFailures.isEmpty,
              trace.messages.map(\.sequence) == Array(1 ... trace.messages.count),
              trace.messages.allSatisfy({
                  $0.object["jsonrpc"] == nil
                      && $0.wireData.last == 0x0A
                      && !$0.wireData.dropLast().contains(0x0A)
              }),
              let threadStart = trace.messages.first(where: {
                  $0.direction == .clientToServer && $0.method == "thread/start"
              }),
              let startParams = threadStart.object["params"] as? [String: Any],
              let specs = startParams["dynamicTools"] as? [[String: Any]]
        else { return "Raw V2 App Server NDJSON or thread/start was malformed" }
        let expectedRegistered = ComputerV2ToolContract.Tool.allCases.map(\.rawValue)
        let registered = specs.compactMap { $0["name"] as? String }
        guard registered.count == expectedRegistered.count,
              Set(registered) == Set(expectedRegistered)
        else { return "Raw thread/start did not register the exact V2 tool set" }
        let tools = [
            ComputerV2ToolContract.Tool.open.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
            ComputerV2ToolContract.Tool.ax.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
        ]
        let calls = trace.messages.filter {
            $0.direction == .serverToClient && $0.method == "item/tool/call"
        }
        guard calls.count == tools.count,
              expectedArguments.count == tools.count,
              expectedCallIDs.count == tools.count,
              calls.compactMap({ ($0.object["params"] as? [String: Any])?["tool"] as? String }) == tools
        else { return "Raw V2 tool order differed" }
        var firstThreadID: String?
        var firstTurnID: String?
        for (index, call) in calls.enumerated() {
            guard let params = call.object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any],
                  NSDictionary(dictionary: arguments).isEqual(to: expectedArguments[index]),
                  let callID = params["callId"] as? String,
                  callID == expectedCallIDs[index],
                  let threadID = params["threadId"] as? String,
                  !threadID.isEmpty,
                  let turnID = params["turnId"] as? String,
                  !turnID.isEmpty,
                  let requestID = call.identifier
            else { return "Raw V2 call \(index) identity or arguments differed" }
            if firstThreadID == nil { firstThreadID = threadID }
            if firstTurnID == nil { firstTurnID = turnID }
            guard threadID == firstThreadID, turnID == firstTurnID else {
                return "V2 calls were not in one bound thread and turn"
            }
            guard let started = trace.messages.first(where: { message in
                guard message.direction == .serverToClient,
                      message.method == "item/started",
                      let p = message.object["params"] as? [String: Any],
                      let item = p["item"] as? [String: Any]
                else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "inProgress"
            }),
            let response = trace.messages.first(where: {
                $0.direction == .clientToServer
                    && $0.method == nil
                    && $0.identifier == requestID
                    && $0.sequence > call.sequence
            }), let result = response.object["result"] as? [String: Any],
            result["success"] as? Bool == true,
            let content = result["contentItems"] as? [[String: Any]],
            let output = content.first(where: { $0["type"] as? String == "inputText" })?["text"] as? String,
            let completed = trace.messages.first(where: { message in
                guard message.direction == .serverToClient,
                      message.method == "item/completed",
                      let p = message.object["params"] as? [String: Any],
                      let item = p["item"] as? [String: Any]
                else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "completed"
                    && item["success"] as? Bool == true
            }), started.sequence < response.sequence,
            completed.sequence > response.sequence
            else { return "Raw V2 call \(index) lacked its complete lifecycle" }
            if index == 0 {
                guard processIdentifier(inOpenOutput: output) == processID,
                      output.contains(bundleID)
                else { return "Raw open response lost bound Calculator identity" }
            } else if index == 1 || index == 3 {
                guard output.contains("AXSNAPSHOT id="),
                      output.contains("pid=\(processID) "),
                      output.contains("bundle=\"\(bundleID)\"")
                else { return "Raw snapshot response lost bound Calculator identity" }
            } else if !output.contains("Requested AXPress") {
                return "Raw AXPress response did not report the approved action"
            }
        }
        return nil
    }

    private func startStrictCalculatorApprovalLoop(
        state: AppState,
        taskID: AgentTask.ID,
        bundleID: String,
        audit: StrictApprovalAudit
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for request in state.pendingApprovals
                where !audit.handledRequestIDs.contains(request.id) {
                    audit.handledRequestIDs.insert(request.id)
                    let hasNoPriorComputerCalls: Bool
                    if let task = state.tasks.first(where: { $0.id == taskID }),
                       let calls = try? recordedV2Calls(in: task) {
                        hasNoPriorComputerCalls = calls.isEmpty
                    } else {
                        hasNoPriorComputerCalls = false
                    }
                    let approved = strictCalculatorOpenApprovalDecision(
                        request,
                        taskID: taskID,
                        bundleID: bundleID,
                        approvedMutationCount: audit.approvedActions.count,
                        hasNoPriorComputerCalls: hasNoPriorComputerCalls
                    )
                    if approved {
                        audit.approvedActions.append("open")
                    } else {
                        audit.unexpectedRequests.append(
                            "Declined unexpected Calculator approval \(request.id): \(request.summary)"
                        )
                        audit.resolvingRejectedRequest = true
                    }
                    await state.resolveApproval(request, approved: approved)
                    if !approved {
                        audit.resolvingRejectedRequest = false
                        return
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }

    private func strictCalculatorOpenApprovalDecision(
        _ request: ActionApprovalRequest,
        taskID: AgentTask.ID,
        bundleID: String,
        approvedMutationCount: Int,
        hasNoPriorComputerCalls: Bool
    ) -> Bool {
        let details = jsonObject(from: request.details)
        return request.taskID == taskID
            && request.kind == .computerUse
            && approvedMutationCount == 0
            && hasNoPriorComputerCalls
            && request.title == "Allow an application action?"
            && request.summary == "Launch or activate \(bundleID)"
            && details?["bundle_id"] as? String == bundleID
            && Set(details?.keys.map { $0 } ?? []) == ["bundle_id"]
    }

    private func waitForCalculatorV2RolloutTrace(
        in codexHomePath: String,
        bundleID: String,
        processID: Int32,
        completionToken: String,
        attempts: Int = 80
    ) async throws -> RolloutPrimitiveTrace {
        var lastFailure = "The rollout file has not appeared yet."
        for _ in 0..<attempts {
            do {
                let trace = try RolloutPrimitiveTrace.loadLatest(in: codexHomePath)
                if let failure = calculatorV2RolloutFailure(
                    trace,
                    bundleID: bundleID,
                    processID: processID,
                    completionToken: completionToken
                ) {
                    lastFailure = failure
                } else {
                    return trace
                }
            } catch {
                lastFailure = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LiveTestFailure(message: "Calculator V2 rollout did not converge: \(lastFailure)")
    }

    private func calculatorV2RolloutFailure(
        _ trace: RolloutPrimitiveTrace,
        bundleID: String,
        processID: Int32,
        completionToken: String
    ) -> String? {
        guard trace.parseFailures.isEmpty else {
            return "Rollout parse failures: \(trace.parseFailures.joined(separator: "; "))"
        }
        let registered = trace.dynamicTools.compactMap { $0["name"] as? String }
        let expectedRegistered = ComputerV2ToolContract.Tool.allCases.map(\.rawValue)
        guard registered.count == expectedRegistered.count,
              Set(registered) == Set(expectedRegistered),
              trace.dynamicTools.allSatisfy({ $0["type"] as? String == "function" })
        else { return "The rollout did not register the exact V2 tool set" }
        guard trace.functionCalls.map(\.name) == [
            ComputerV2ToolContract.Tool.open.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
        ], trace.functionCalls.count == 2,
        Set(trace.functionCalls[0].arguments.keys) == ["bundle_id"],
        trace.functionCalls[0].arguments["bundle_id"] as? String == bundleID,
        Set(trace.functionCalls[1].arguments.keys) == ["query"],
        trace.functionCalls[1].arguments["query"] as? String == "Calculator"
        else { return "The rollout V2 call order or arguments did not match Calculator open and snapshot" }
        let callIDs = trace.functionCalls.map(\.callID)
        guard Set(callIDs).count == 2,
              trace.functionCallOutputs.map(\.callID) == callIDs,
              let openOutput = trace.output(for: callIDs[0]) as? String,
              processIdentifier(inOpenOutput: openOutput) == processID,
              openOutput.contains(bundleID),
              let snapshotOutput = trace.output(for: callIDs[1]) as? String,
              snapshotOutput.contains("AXSNAPSHOT id="),
              snapshotOutput.contains("pid=\(processID) "),
              snapshotOutput.contains("bundle=\"\(bundleID)\"")
        else { return "The rollout outputs did not preserve the bound Calculator identity" }
        let finalText = trace.assistantMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        guard finalText == completionToken else {
            return "Rollout final text was \(String(reflecting: finalText))"
        }
        return nil
    }

    private func waitForCalculatorV2WireTrace(
        at path: String,
        bundleID: String,
        processID: Int32,
        attempts: Int = 80
    ) async throws -> AppServerWireTrace {
        let url = URL(fileURLWithPath: path)
        var lastFailure = "The wire trace has not appeared yet."
        for _ in 0..<attempts {
            do {
                let trace = try AppServerWireTrace.load(url)
                if let failure = calculatorV2WireFailure(
                    trace,
                    bundleID: bundleID,
                    processID: processID
                ) {
                    lastFailure = failure
                } else {
                    return trace
                }
            } catch {
                lastFailure = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LiveTestFailure(message: "Calculator V2 wire trace did not converge: \(lastFailure)")
    }

    private func calculatorV2WireFailure(
        _ trace: AppServerWireTrace,
        bundleID: String,
        processID: Int32
    ) -> String? {
        guard !trace.messages.isEmpty,
              trace.parseFailures.isEmpty,
              trace.messages.map(\.sequence) == Array(1 ... trace.messages.count),
              trace.messages.allSatisfy({
                  $0.object["jsonrpc"] == nil
                      && $0.wireData.last == 0x0A
                      && !$0.wireData.dropLast().contains(0x0A)
              })
        else { return "The raw App Server trace had malformed NDJSON frames" }
        guard let start = trace.messages.first(where: {
            $0.direction == .clientToServer && $0.method == "thread/start"
        }), let params = start.object["params"] as? [String: Any],
        let specs = params["dynamicTools"] as? [[String: Any]]
        else { return "The raw thread/start frame did not register dynamic tools" }
        let expectedRegistered = ComputerV2ToolContract.Tool.allCases.map(\.rawValue)
        let registered = specs.compactMap { $0["name"] as? String }
        guard registered.count == expectedRegistered.count,
              Set(registered) == Set(expectedRegistered)
        else { return "The raw thread/start frame did not register the exact V2 tool set" }
        let calls = trace.messages.filter {
            $0.direction == .serverToClient && $0.method == "item/tool/call"
        }
        let expectedTools = [
            ComputerV2ToolContract.Tool.open.rawValue,
            ComputerV2ToolContract.Tool.snapshot.rawValue,
        ]
        guard calls.count == 2,
              calls.compactMap({ ($0.object["params"] as? [String: Any])?["tool"] as? String }) == expectedTools
        else { return "The raw App Server tool calls did not follow Calculator open and snapshot" }

        for (index, call) in calls.enumerated() {
            guard let params = call.object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any],
                  let callID = params["callId"] as? String, !callID.isEmpty,
                  let threadID = params["threadId"] as? String, !threadID.isEmpty,
                  let turnID = params["turnId"] as? String, !turnID.isEmpty,
                  let requestID = call.identifier
            else { return "Raw V2 call \(index) lacked identity or arguments" }
            if index == 0 {
                guard Set(arguments.keys) == ["bundle_id"],
                      arguments["bundle_id"] as? String == bundleID
                else { return "Raw V2 open arguments changed" }
            } else {
                guard Set(arguments.keys) == ["query"],
                      arguments["query"] as? String == "Calculator"
                else { return "Raw V2 snapshot arguments changed" }
            }
            guard let started = trace.messages.first(where: { message in
                guard message.direction == .serverToClient,
                      message.method == "item/started",
                      let notification = message.object["params"] as? [String: Any],
                      let item = notification["item"] as? [String: Any]
                else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "inProgress"
            }),
            let response = trace.messages.first(where: {
                $0.direction == .clientToServer
                    && $0.method == nil
                    && $0.identifier == requestID
                    && $0.sequence > call.sequence
            }), let result = response.object["result"] as? [String: Any],
            result["success"] as? Bool == true,
            let content = result["contentItems"] as? [[String: Any]],
            let output = content.first(where: { $0["type"] as? String == "inputText" })?["text"] as? String,
            let completed = trace.messages.first(where: { message in
                guard message.direction == .serverToClient,
                      message.method == "item/completed",
                      let notification = message.object["params"] as? [String: Any],
                      let item = notification["item"] as? [String: Any]
                else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "completed"
                    && item["success"] as? Bool == true
            }), started.sequence < response.sequence,
            completed.sequence > response.sequence
            else { return "Raw V2 call \(index) lacked the complete matching App Server lifecycle" }
            if index == 0 {
                guard processIdentifier(inOpenOutput: output) == processID,
                      output.contains(bundleID)
                else { return "Raw V2 open response lost Calculator identity" }
            } else {
                guard output.contains("AXSNAPSHOT id="),
                      output.contains("pid=\(processID) "),
                      output.contains("bundle=\"\(bundleID)\"")
                else { return "Raw V2 snapshot response lost Calculator identity" }
            }
        }
        return nil
    }

    private func assertLiveModelInWireTrace(
        _ trace: AppServerWireTrace,
        expectedModelID: String
    ) {
        for method in ["thread/start", "turn/start"] {
            let requests = trace.messages.filter { message in
                message.direction == .clientToServer && message.method == method
            }
            XCTAssertEqual(requests.count, 1, "Expected exactly one \(method) request")
            let modelID = (requests.first?.object["params"] as? [String: Any])?["model"] as? String
            XCTAssertEqual(modelID, expectedModelID, "\(method) did not use the selected live model")
        }
    }

    private func makeLiveState() async -> (AppState, Task<Void, Never>, String, String) {
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexLiveTest-\(UUID().uuidString)", isDirectory: true)
            .path
        let protocolTracePath = URL(fileURLWithPath: configuration.codexHomePath, isDirectory: true)
            .appendingPathComponent("app-server-wire.jsonl")
            .path
        configuration.protocolTracePath = protocolTracePath
        let runtime = CodexAppServerRuntime(configuration: configuration)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let eventTask = Task { await state.startRuntime() }
        return (state, eventTask, configuration.codexHomePath, protocolTracePath)
    }

    private func uniqueFixtureRun(label: String) throws -> FixtureRun {
        let templateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ComputerUseFixture.html")
        let runID = UUID().uuidString.lowercased()
        let completionToken = "LOCALCODEX_CHROME_OK_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        let marker = "const embeddedCompletionToken = null;"
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        guard template.contains(marker) else {
            throw LiveTestFailure(message: "Chrome fixture does not contain its token marker.")
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexChromeFixture-\(label)-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        let fixtureURL = fixtureDirectory.appendingPathComponent("ComputerUseFixture.html")
        let generated = template.replacingOccurrences(
            of: marker,
            with: "const embeddedCompletionToken = \"\(completionToken)\";"
        )
        try generated.write(to: fixtureURL, atomically: true, encoding: .utf8)

        return FixtureRun(
            url: fixtureURL,
            completionToken: completionToken
        )
    }

    private func startStrictApprovalLoop(
        state: AppState,
        taskID: AgentTask.ID,
        fixture: FixtureRun,
        path: ChromeComputerPath,
        audit: StrictApprovalAudit
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for request in state.pendingApprovals
                where !audit.handledRequestIDs.contains(request.id) {
                    audit.handledRequestIDs.insert(request.id)
                    let calls = state.tasks.first(where: { $0.id == taskID })
                        .map(recordedComputerCalls) ?? []
                    let decision = strictApprovalDecision(
                        request: request,
                        expectedTaskID: taskID,
                        fixture: fixture,
                        path: path,
                        approvedMutationCount: audit.approvedActions.count,
                        completedCalls: calls
                    )

                    if decision.approved {
                        audit.approvedActions.append(decision.action)
                    } else {
                        audit.unexpectedRequests.append(
                            "Declined \(decision.action) request \(request.id): \(decision.reason)"
                        )
                        audit.resolvingRejectedRequest = true
                    }
                    await state.resolveApproval(request, approved: decision.approved)
                    if !decision.approved {
                        audit.resolvingRejectedRequest = false
                        return
                    }
                }

                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }

    private func strictApprovalDecision(
        request: ActionApprovalRequest,
        expectedTaskID: AgentTask.ID,
        fixture: FixtureRun,
        path: ChromeComputerPath,
        approvedMutationCount: Int,
        completedCalls: [RecordedComputerCall],
        fixtureButtonFrameOverride: WindowFrame? = nil
    ) -> StrictApprovalDecision {
        func reject(_ action: String, _ reason: String) -> StrictApprovalDecision {
            StrictApprovalDecision(approved: false, action: action, reason: reason)
        }

        guard request.taskID == expectedTaskID else {
            return reject("unknown", "request targeted a different task")
        }
        guard request.kind == .computerUse else {
            return reject("unknown", "request was not a computer-use approval")
        }
        guard let details = jsonObject(from: request.details) else {
            return reject("unknown", "request details were not a JSON object")
        }

        if approvedMutationCount == 0 {
            guard completedCalls.isEmpty else {
                return reject("open", "computer calls occurred before the initial open approval")
            }
            guard request.title == "Allow an application action?",
                  request.summary == "Open com.google.Chrome at \(fixture.url.absoluteString)",
                  Set(details.keys) == Set(["bundle_id", "url"]),
                  details["bundle_id"] as? String == "com.google.Chrome",
                  details["url"] as? String == fixture.url.absoluteString
            else {
                return reject("open", "initial mutation was not the exact approved Chrome fixture URL")
            }
            return StrictApprovalDecision(approved: true, action: "open", reason: "exact fixture open")
        }

        guard approvedMutationCount == 1 else {
            let action = details["action"] as? String ?? "unknown"
            return reject(action, "the path permits exactly two mutations")
        }

        let requiredPrefix = path == .semantic
            ? ["open", "snapshot"]
            : ["open", "capture"]
        if let prefixFailure = computerCallFailure(
            completedCalls,
            expectedActions: requiredPrefix
        ) {
            return reject(details["action"] as? String ?? "unknown", prefixFailure)
        }
        guard completedCalls[0].parameters["bundle_id"] as? String == "com.google.Chrome",
              completedCalls[0].parameters["url"] as? String == fixture.url.absoluteString,
              let processID = returnedProcessIdentifier(in: completedCalls[0])
        else {
            return reject("unknown", "completed open call did not match this fixture or return a process")
        }

        switch path {
        case .semantic:
            guard processIdentifier(in: completedCalls[1].parameters) == processID,
                  completedCalls[1].parameters["query"] as? String == "Complete computer-use test",
                  let snapshotID = returnedSnapshotIdentifier(in: completedCalls[1])
            else {
                return reject("ax", "semantic snapshot did not match the returned Chrome process and button query")
            }
            guard request.title == "Allow a desktop action?",
                  request.summary == "AXPress on Complete computer-use test",
                  Set(details.keys) == Set([
                      "action", "ax_action", "process_id", "snapshot_id", "element_index",
                  ]),
                  details["action"] as? String == SemanticAXAction.press.rawValue,
                  details["ax_action"] as? String == SemanticAXAction.press.rawValue,
                  processIdentifier(in: details) == processID,
                  details["snapshot_id"] as? String == snapshotID,
                  let index = details["element_index"] as? NSNumber,
                  index.intValue >= 0,
                  snapshotOutputContainsFixtureButton(
                      at: index.intValue,
                      in: completedCalls[1]
                  )
            else {
                return reject("ax", "second mutation was not AXPress on the exact inspected fixture button")
            }
            return StrictApprovalDecision(approved: true, action: "ax", reason: "exact semantic press")

        case .visual:
            guard request.title == "Allow computer input?",
                  Set(details.keys) == Set(["action", "process_id", "x", "y"]),
                  details["action"] as? String == "click",
                  processIdentifier(in: details) == processID,
                  let x = details["x"] as? NSNumber,
                  let y = details["y"] as? NSNumber,
                  x.doubleValue.isFinite,
                  y.doubleValue.isFinite
            else {
                return reject("click", "second mutation was not a finite click for the returned Chrome process")
            }
            guard request.summary == "Click at (\(x.doubleValue), \(y.doubleValue))" else {
                return reject("click", "click summary did not match its exact coordinates")
            }
            let buttonFrame = fixtureButtonFrameOverride
                ?? testOwnedFixtureButtonFrame(processIdentifier: processID)
            guard let buttonFrame,
                  buttonFrame.width > 0,
                  buttonFrame.height > 0,
                  x.doubleValue >= buttonFrame.x,
                  x.doubleValue <= buttonFrame.x + buttonFrame.width,
                  y.doubleValue >= buttonFrame.y,
                  y.doubleValue <= buttonFrame.y + buttonFrame.height
            else {
                return reject("click", "click point was outside the exact fixture button")
            }
            return StrictApprovalDecision(approved: true, action: "click", reason: "exact visual click")
        }
    }

    private func snapshotOutputContainsFixtureButton(
        at index: Int,
        in call: RecordedComputerCall
    ) -> Bool {
        guard let contentItems = call.item["contentItems"] as? [[String: Any]] else {
            return false
        }
        let expectedLinePrefix = "#\(index) role=\"AXButton\" label=\"Complete computer-use test\""
        return contentItems.contains { item in
            item["type"] as? String == "inputText"
                && (item["text"] as? String)?.contains(expectedLinePrefix) == true
        }
    }

    private func testOwnedFixtureButtonFrame(processIdentifier: Int32) -> WindowFrame? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.bundleIdentifier == "com.google.Chrome",
              !application.isTerminated,
              let limits = try? AccessibilityTreeLimits(
                  maxDepth: 16,
                  maxElements: 1_000,
                  maxChildrenPerElement: 200,
                  maxActionsPerElement: 32,
                  maxTextLength: 1_024
              )
        else {
            return nil
        }

        let session = AccessibilitySession(
            processIdentifier: processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        )
        guard let snapshot = try? session.snapshot(limits: limits) else {
            return nil
        }
        return snapshot.elements.first(where: { element in
            element.role == "AXButton"
                && element.title == "Complete computer-use test"
                && element.supportedActions.contains(SemanticAXAction.press.rawValue)
        })?.frame
    }

    private func recordedComputerCalls(in task: AgentTask) -> [RecordedComputerCall] {
        task.entries.compactMap { entry in
            guard let toolEvent = entry.toolEvent,
                  toolEvent.name == "computer"
            else { return nil }
            guard let item = jsonObject(from: toolEvent.input) else {
                return RecordedComputerCall(
                    item: [:],
                    arguments: [:],
                    status: toolEvent.status,
                    parseFailure: "computer transcript input was not a JSON object"
                )
            }
            guard let arguments = jsonObject(from: item["arguments"]) else {
                return RecordedComputerCall(
                    item: item,
                    arguments: [:],
                    status: toolEvent.status,
                    parseFailure: "computer transcript arguments were not a JSON object or JSON string"
                )
            }
            return RecordedComputerCall(
                item: item,
                arguments: arguments,
                status: toolEvent.status,
                parseFailure: nil
            )
        }
    }

    private func assertComputerCalls(
        _ calls: [RecordedComputerCall],
        actions: [String],
        state: AppState
    ) throws {
        if let failure = computerCallFailure(calls, expectedActions: actions) {
            throw LiveTestFailure(message: "\(failure). \(diagnostics(for: state))")
        }
    }

    private func computerCallFailure(
        _ calls: [RecordedComputerCall],
        expectedActions: [String]
    ) -> String? {
        let actualActions = calls.map { $0.action ?? "<unparsed>" }
        guard actualActions == expectedActions else {
            return "Expected computer calls \(expectedActions), received \(actualActions)"
        }
        let parseFailures = calls.compactMap(\.parseFailure)
        guard parseFailures.isEmpty else {
            return "Computer transcript parse failures: \(parseFailures.joined(separator: "; "))"
        }
        let statuses = calls.map { $0.status.rawValue }
        guard statuses.allSatisfy({ $0 == ToolRunStatus.succeeded.rawValue }) else {
            return "Expected every computer call to succeed, received statuses \(statuses)"
        }
        return nil
    }

    private func jsonObject(from value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        guard let text = value as? String,
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func processIdentifier(in parameters: [String: Any]) -> Int32? {
        guard let number = parameters["process_id"] as? NSNumber,
              number.int64Value >= Int64(Int32.min),
              number.int64Value <= Int64(Int32.max)
        else { return nil }
        return number.int32Value
    }

    private func returnedProcessIdentifier(in call: RecordedComputerCall) -> Int32? {
        guard let contentItems = call.item["contentItems"] as? [[String: Any]],
              let expression = try? NSRegularExpression(
                  pattern: #""processIdentifier"\s*:\s*(\d+)"#
              )
        else { return nil }

        for item in contentItems where item["type"] as? String == "inputText" {
            guard let text = item["text"] as? String else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  match.numberOfRanges == 2,
                  let processIDRange = Range(match.range(at: 1), in: text),
                  let processID = Int32(text[processIDRange])
            else { continue }
            return processID
        }
        return nil
    }

    private func returnedSnapshotIdentifier(in call: RecordedComputerCall) -> String? {
        guard let contentItems = call.item["contentItems"] as? [[String: Any]],
              let expression = try? NSRegularExpression(
                  pattern: #"AXSNAPSHOT id=([0-9A-Fa-f-]{36})"#
              )
        else { return nil }

        for item in contentItems where item["type"] as? String == "inputText" {
            guard let text = item["text"] as? String else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  match.numberOfRanges == 2,
                  let identifierRange = Range(match.range(at: 1), in: text),
                  UUID(uuidString: String(text[identifierRange])) != nil
            else { continue }
            return String(text[identifierRange])
        }
        return nil
    }

    private func waitForRuntimeConnection(
        state: AppState,
        attempts: Int = 80
    ) async throws {
        for _ in 0..<attempts {
            switch state.connectionState {
            case .connected:
                return
            case .failed(let message):
                throw LiveTestFailure(message: "Runtime connection failed: \(message)")
            case .connecting, .disconnected:
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LiveTestFailure(
            message: "Timed out waiting for runtime connection. \(diagnostics(for: state))"
        )
    }

    private func waitUntil(
        _ operation: String,
        state: AppState,
        attempts: Int = 80,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }

        XCTFail("Timed out waiting for \(operation). \(diagnostics(for: state))")
    }

    private func waitForCompletedTask(
        _ operation: String,
        state: AppState,
        taskID: AgentTask.ID,
        audit: StrictApprovalAudit,
        attempts: Int
    ) async throws -> AgentTask {
        var observedRunning = false
        var consecutiveWaitingPolls = 0

        for _ in 0..<attempts {
            if let unexpected = audit.unexpectedRequests.first {
                if audit.resolvingRejectedRequest {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch is CancellationError {
                        throw LiveTestFailure(
                            message: "Unexpected approval request during \(operation): \(unexpected). \(diagnostics(for: state))"
                        )
                    }
                    continue
                }
                throw LiveTestFailure(
                    message: "Unexpected approval request during \(operation): \(unexpected). \(diagnostics(for: state))"
                )
            }
            if case .failed(let message) = state.connectionState {
                throw LiveTestFailure(
                    message: "Runtime failed during \(operation): \(message). \(diagnostics(for: state))"
                )
            }

            guard let task = state.tasks.first(where: { $0.id == taskID }) else {
                throw LiveTestFailure(message: "Task \(taskID) disappeared during \(operation).")
            }
            switch task.status {
            case .completed:
                return task
            case .running:
                observedRunning = true
                consecutiveWaitingPolls = 0
            case .waiting:
                consecutiveWaitingPolls += 1
                let hasTerminalFailure = task.entries.contains {
                    $0.kind == .system
                        && ["Agent error", "Prompt was not delivered"].contains($0.title)
                }
                if observedRunning || hasTerminalFailure || consecutiveWaitingPolls >= 40 {
                    throw LiveTestFailure(
                        message: "Task stopped in Waiting during \(operation). \(diagnostics(for: state))"
                    )
                }
            case .draft:
                consecutiveWaitingPolls = 0
            }

            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                if let unexpected = audit.unexpectedRequests.first {
                    throw LiveTestFailure(
                        message: "Unexpected approval request during \(operation): \(unexpected). \(diagnostics(for: state))"
                    )
                }
                throw CancellationError()
            }
        }

        throw LiveTestFailure(
            message: "Timed out waiting for \(operation). \(diagnostics(for: state))"
        )
    }

    private func waitForRolloutPrimitiveTrace(
        in codexHomePath: String,
        expectedActions: [String],
        completionToken: String,
        requiresScreenshotOutput: Bool = false,
        v2StatusOnly: Bool = false,
        attempts: Int = 80
    ) async throws -> RolloutPrimitiveTrace {
        var lastObservation = "The rollout file has not appeared yet."

        for _ in 0..<attempts {
            do {
                let trace = try RolloutPrimitiveTrace.loadLatest(in: codexHomePath)
                if let failure = rolloutPrimitiveFailure(
                    trace,
                    expectedActions: expectedActions,
                    completionToken: completionToken,
                    requiresScreenshotOutput: requiresScreenshotOutput,
                    v2StatusOnly: v2StatusOnly
                ) {
                    lastObservation = failure
                } else {
                    return trace
                }
            } catch {
                lastObservation = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw LiveTestFailure(
            message: "The persisted model/API primitive trace did not converge: \(lastObservation)"
        )
    }

    private func rolloutPrimitiveFailure(
        _ trace: RolloutPrimitiveTrace,
        expectedActions: [String],
        completionToken: String,
        requiresScreenshotOutput: Bool,
        v2StatusOnly: Bool = false
    ) -> String? {
        guard trace.parseFailures.isEmpty else {
            return "Rollout parse failures: \(trace.parseFailures.joined(separator: "; "))"
        }
        if v2StatusOnly {
            let registeredNames = trace.dynamicTools.compactMap { $0["name"] as? String }
            let expectedNames = ComputerV2ToolContract.Tool.allCases.map(\.rawValue)
            guard expectedActions == [ComputerV2ToolContract.Tool.status.rawValue],
                  registeredNames.count == expectedNames.count,
                  Set(registeredNames) == Set(expectedNames),
                  trace.dynamicTools.allSatisfy({ $0["type"] as? String == "function" }),
                  trace.functionCalls.map(\.name) == expectedActions,
                  trace.functionCalls.allSatisfy({ $0.arguments.isEmpty })
            else {
                return "The rollout did not register V2 tools and call computer_v2_status once with empty arguments"
            }
        } else {
            guard trace.dynamicTools.count == 1,
                  let computerTool = trace.dynamicTools.first,
                  computerTool["type"] as? String == "function",
                  computerTool["name"] as? String == "computer",
                  let schema = computerTool["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any],
                  let action = properties["action"] as? [String: Any],
                  let actionNames = action["enum"] as? [String],
                  expectedActions.allSatisfy(actionNames.contains)
            else {
                return "session_meta.dynamic_tools did not contain the expected computer schema"
            }

            let actualActions = trace.functionCalls.map { $0.action ?? "<unparsed>" }
            guard actualActions == expectedActions,
                  trace.functionCalls.allSatisfy({ $0.name == "computer" })
            else {
                return "Expected primitive computer calls \(expectedActions), received \(actualActions)"
            }
        }

        let callIDs = trace.functionCalls.map(\.callID)
        guard Set(callIDs).count == callIDs.count else {
            return "Primitive function_call call_id values were not unique: \(callIDs)"
        }
        let outputCallIDs = trace.functionCallOutputs.map(\.callID)
        guard outputCallIDs == callIDs else {
            return "function_call_output call_id order \(outputCallIDs) did not match calls \(callIDs)"
        }

        if let snapshotIndex = expectedActions.lastIndex(of: "snapshot") {
            let snapshotCallID = trace.functionCalls[snapshotIndex].callID
            guard let output = trace.output(for: snapshotCallID) as? String,
                  output.contains(completionToken)
            else {
                return "The final snapshot function_call_output did not contain \(completionToken)"
            }
        }

        let finalText = trace.assistantMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        guard finalText == completionToken else {
            return "Primitive assistant output was \(String(reflecting: finalText)); expected \(completionToken)"
        }

        if requiresScreenshotOutput {
            guard let captureIndex = expectedActions.firstIndex(of: "capture"),
                  captureIndex < trace.functionCalls.count,
                  let content = trace.output(
                      for: trace.functionCalls[captureIndex].callID
                  ) as? [[String: Any]],
                  let image = content.first(where: { $0["type"] as? String == "input_image" }),
                  let imageURL = image["image_url"] as? String,
                  imageURL.hasPrefix("data:image/png;base64,"),
                  let png = Data(base64Encoded: String(imageURL.dropFirst("data:image/png;base64,".count))),
                  png.starts(with: [0x89, 0x50, 0x4E, 0x47])
            else {
                return "The capture function_call_output did not contain a valid PNG input_image primitive"
            }
        }

        return nil
    }

    private func waitForAppServerWireTrace(
        at path: String,
        expectedActions: [String],
        completionToken: String,
        requiresScreenshotOutput: Bool = false,
        v2StatusOnly: Bool = false,
        attempts: Int = 80
    ) async throws -> AppServerWireTrace {
        let url = URL(fileURLWithPath: path)
        var lastObservation = "The App Server wire trace has not appeared yet."

        for _ in 0..<attempts {
            do {
                let trace = try AppServerWireTrace.load(url)
                if let failure = appServerWireFailure(
                    trace,
                    expectedActions: expectedActions,
                    completionToken: completionToken,
                    requiresScreenshotOutput: requiresScreenshotOutput,
                    v2StatusOnly: v2StatusOnly
                ) {
                    lastObservation = failure
                } else {
                    return trace
                }
            } catch {
                lastObservation = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw LiveTestFailure(
            message: "The raw App Server NDJSON trace did not converge: \(lastObservation)"
        )
    }

    private func appServerWireFailure(
        _ trace: AppServerWireTrace,
        expectedActions: [String],
        completionToken: String,
        requiresScreenshotOutput: Bool,
        v2StatusOnly: Bool = false
    ) -> String? {
        guard trace.parseFailures.isEmpty else {
            return "Wire parse failures: \(trace.parseFailures.joined(separator: "; "))"
        }
        guard trace.messages.map(\.sequence) == Array(1 ... trace.messages.count) else {
            return "Wire sequence numbers were not contiguous"
        }
        guard trace.messages.allSatisfy({ message in
            message.object["jsonrpc"] == nil
                && message.wireData.last == 0x0A
                && !message.wireData.dropLast().contains(0x0A)
        }) else {
            return "A recorded message was not one exact newline-delimited App Server frame"
        }

        guard let threadStart = trace.messages.first(where: {
            $0.direction == .clientToServer && $0.method == "thread/start"
        }),
        let threadParams = threadStart.object["params"] as? [String: Any],
        let dynamicTools = threadParams["dynamicTools"] as? [[String: Any]]
        else {
            return "The raw thread/start frame did not register dynamic tools"
        }
        if v2StatusOnly {
            let registeredNames = dynamicTools.compactMap { $0["name"] as? String }
            let expectedNames = ComputerV2ToolContract.Tool.allCases.map(\.rawValue)
            guard expectedActions == [ComputerV2ToolContract.Tool.status.rawValue],
                  registeredNames.count == expectedNames.count,
                  Set(registeredNames) == Set(expectedNames)
            else {
                return "The raw thread/start frame did not register the exact V2 computer tools"
            }
        } else {
            guard dynamicTools.count == 1,
                  dynamicTools[0]["name"] as? String == "computer"
            else {
                return "The raw thread/start frame did not register exactly one computer dynamic tool"
            }
        }

        let calls = trace.messages.filter { message in
            guard message.direction == .serverToClient,
                  message.method == "item/tool/call",
                  let params = message.object["params"] as? [String: Any]
            else { return false }
            let toolName = params["tool"] as? String
            return v2StatusOnly
                ? toolName?.hasPrefix("computer_v2_") == true
                : toolName == "computer"
        }
        let actualActions = calls.map { message -> String in
            guard let params = message.object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any]
            else { return "<unparsed>" }
            return v2StatusOnly
                ? (params["tool"] as? String ?? "<unparsed>")
                : (arguments["action"] as? String ?? "<unparsed>")
        }
        guard actualActions == expectedActions else {
            return "Expected raw item/tool/call actions \(expectedActions), received \(actualActions)"
        }
        if v2StatusOnly, calls.contains(where: { message in
            guard let params = message.object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any]
            else { return true }
            return !arguments.isEmpty
        }) {
            return "computer_v2_status did not have empty raw arguments"
        }

        for (index, call) in calls.enumerated() {
            guard let params = call.object["params"] as? [String: Any],
                  let callID = params["callId"] as? String,
                  !callID.isEmpty,
                  let threadID = params["threadId"] as? String,
                  !threadID.isEmpty,
                  let turnID = params["turnId"] as? String,
                  !turnID.isEmpty,
                  let requestID = call.identifier
            else {
                return "item/tool/call \(index) lacked its primitive call/thread/turn/request identity"
            }

            guard let response = trace.messages.first(where: {
                $0.direction == .clientToServer
                    && $0.method == nil
                    && $0.identifier == requestID
                    && $0.sequence > call.sequence
            }),
            let result = response.object["result"] as? [String: Any],
            result["success"] as? Bool == true,
            let responseContent = result["contentItems"] as? [[String: Any]],
            !responseContent.isEmpty
            else {
                return "item/tool/call \(callID) had no matching successful raw client response"
            }

            guard let started = trace.messages.first(where: { message in
                guard message.direction == .serverToClient,
                      message.method == "item/started",
                      let notification = message.object["params"] as? [String: Any],
                      let item = notification["item"] as? [String: Any]
                else { return false }
                return item["type"] as? String == "dynamicToolCall"
                    && item["id"] as? String == callID
                    && item["status"] as? String == "inProgress"
            }), started.sequence < response.sequence else {
                return "The raw stream lacked item/started for dynamic tool call \(callID)"
            }

            guard let completed = trace.messages.first(where: { message in
                guard message.direction == .serverToClient,
                      message.method == "item/completed",
                      let notification = message.object["params"] as? [String: Any],
                      let item = notification["item"] as? [String: Any]
                else { return false }
                return item["type"] as? String == "dynamicToolCall"
                    && item["id"] as? String == callID
                    && item["status"] as? String == "completed"
                    && item["success"] as? Bool == true
                    && (item["contentItems"] as? [[String: Any]])?.isEmpty == false
            }), completed.sequence > response.sequence else {
                return "The raw stream lacked successful item/completed for dynamic tool call \(callID)"
            }

            if expectedActions[index] == "snapshot",
               index == expectedActions.lastIndex(of: "snapshot") {
                guard responseContent.contains(where: { item in
                    item["type"] as? String == "inputText"
                        && (item["text"] as? String)?.contains(completionToken) == true
                }) else {
                    return "The final raw snapshot client response did not contain \(completionToken)"
                }
            }

            if requiresScreenshotOutput, expectedActions[index] == "capture" {
                guard let image = responseContent.first(where: {
                    $0["type"] as? String == "inputImage"
                }),
                let imageURL = image["imageUrl"] as? String,
                imageURL.hasPrefix("data:image/png;base64,"),
                let png = Data(base64Encoded: String(imageURL.dropFirst("data:image/png;base64,".count))),
                png.starts(with: [0x89, 0x50, 0x4E, 0x47])
                else {
                    return "The raw capture response did not contain a valid PNG inputImage"
                }
            }
        }

        return nil
    }

    private func waitForChromeAccessibilityValue(
        _ expectedValue: String,
        processIdentifier: Int32,
        attempts: Int = 80
    ) async throws {
        let limits = try AccessibilityTreeLimits(
            maxDepth: 16,
            maxElements: 1_000,
            maxChildrenPerElement: 200,
            maxActionsPerElement: 32,
            maxTextLength: 1_024
        )
        var lastObservation = "Chrome pid \(processIdentifier) was not running."

        for _ in 0..<attempts {
            if let application = NSRunningApplication(processIdentifier: processIdentifier),
               application.bundleIdentifier == "com.google.Chrome",
               !application.isTerminated {
                do {
                    let session = AccessibilitySession(
                        processIdentifier: processIdentifier,
                        bundleIdentifier: application.bundleIdentifier,
                        applicationName: application.localizedName
                    )
                    let snapshot = try session.snapshot(limits: limits)
                    if snapshot.elements.contains(where: {
                        accessibilityText(of: $0).contains(expectedValue)
                    }) {
                        return
                    }

                    let formatter = AccessibilitySnapshotTextFormatter(
                        elementLimit: limits.maxElements,
                        fieldCharacterLimit: 96,
                        actionLimit: 6,
                        outputCharacterLimit: 2_000,
                        prioritizesRelevantElements: true,
                        preferredText: expectedValue,
                        usesCompactElementLines: true
                    )
                    lastObservation = snapshot.formattedForModel(using: formatter)
                } catch {
                    lastObservation = "Chrome pid \(processIdentifier): \(error)"
                }
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        throw LiveTestFailure(
            message: "Chrome pid \(processIdentifier) never exposed the exact Accessibility value "
                + "\(String(reflecting: expectedValue)). Last observation: \(lastObservation)"
        )
    }

    private func accessibilityText(of element: AccessibilityTreeElement) -> [String] {
        [
            element.title,
            element.elementDescription,
            element.help,
            element.identifier,
            element.value,
        ]
        .compactMap { value in
            guard let value else { return nil }
            return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    private func diagnostics(for state: AppState) -> String {
        let tasks = state.tasks.map { task in
            let entries = task.entries.map { "\($0.kind.rawValue):\($0.body)" }.joined(separator: " | ")
            return "\(task.id)=\(task.status.rawValue)[\(entries)]"
        }.joined(separator: "; ")
        return "connection=\(state.connectionState.label); tasks=\(tasks)"
    }
}

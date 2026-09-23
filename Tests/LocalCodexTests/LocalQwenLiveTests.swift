import AppKit
import AutomationCore
import Foundation
import XCTest
@testable import LocalCodex

@MainActor
final class LocalQwenLiveTests: XCTestCase {
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

    private struct StrictApprovalDecision {
        let approved: Bool
        let action: String
        let reason: String
    }

    private final class StrictApprovalAudit {
        var approvedActions = [String]()
        var unexpectedRequests = [String]()
        var handledRequestIDs = Set<String>()
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
        let state = AppState(tasks: [], runtime: runtime)
        let eventTask = Task { await state.startRuntime() }
        defer { eventTask.cancel() }

        try await waitForRuntimeConnection(state: state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
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
        XCTAssertEqual(
            completedTask.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "LOCAL_QWEN_OK"
        )

        let webSnapshot = WebUISnapshot(state: state)
        let webTask = try XCTUnwrap(webSnapshot.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(webTask.status, "Completed")
        XCTAssertEqual(
            webTask.entries.last(where: { $0.kind == "assistant" })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "LOCAL_QWEN_OK"
        )
    }

    func testProductionRuntimeExecutesReadOnlyComputerTool() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_TEST"] == "1",
            "Set LOCALCODEX_LIVE_MODEL_TEST=1 to run against the loaded LM Studio model."
        )

        let (state, eventTask, codexHomePath, protocolTracePath) = await makeLiveState()
        defer { eventTask.cancel() }

        try await waitForRuntimeConnection(state: state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let submitted = await state.submit(
            prompt: "Call computer exactly once with action permission_status. After its result, reply with exactly LOCAL_COMPUTER_TOOL_OK. You must use that tool and no other tool.",
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
                && task.entries.contains(where: { $0.kind == .tool })
                && task.entries.contains {
                    $0.kind == .assistant
                        && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == "LOCAL_COMPUTER_TOOL_OK"
                }
        }

        _ = try await waitForRolloutPrimitiveTrace(
            in: codexHomePath,
            expectedActions: ["permission_status"],
            completionToken: "LOCAL_COMPUTER_TOOL_OK"
        )
        _ = try await waitForAppServerWireTrace(
            at: protocolTracePath,
            expectedActions: ["permission_status"],
            completionToken: "LOCAL_COMPUTER_TOOL_OK"
        )
    }

    func testProductionRuntimeControlsChromeFixture() async throws {
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
        _ = try await waitForAppServerWireTrace(
            at: protocolTracePath,
            expectedActions: ["open", "snapshot", "ax", "snapshot"],
            completionToken: fixture.completionToken
        )
    }

    func testProductionRuntimeVisuallyControlsChromeFixture() async throws {
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
        _ = try await waitForAppServerWireTrace(
            at: protocolTracePath,
            expectedActions: ["open", "capture", "click", "snapshot"],
            completionToken: fixture.completionToken,
            requiresScreenshotOutput: true
        )
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
        let state = AppState(tasks: [], runtime: runtime)
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
                    }
                    await state.resolveApproval(request, approved: decision.approved)
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

            try await Task.sleep(for: .milliseconds(250))
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
                    requiresScreenshotOutput: requiresScreenshotOutput
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
        requiresScreenshotOutput: Bool
    ) -> String? {
        guard trace.parseFailures.isEmpty else {
            return "Rollout parse failures: \(trace.parseFailures.joined(separator: "; "))"
        }
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
                    requiresScreenshotOutput: requiresScreenshotOutput
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
        requiresScreenshotOutput: Bool
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
        let dynamicTools = threadParams["dynamicTools"] as? [[String: Any]],
        dynamicTools.count == 1,
        dynamicTools[0]["name"] as? String == "computer"
        else {
            return "The raw thread/start frame did not register exactly one computer dynamic tool"
        }

        let calls = trace.messages.filter { message in
            guard message.direction == .serverToClient,
                  message.method == "item/tool/call",
                  let params = message.object["params"] as? [String: Any]
            else { return false }
            return params["tool"] as? String == "computer"
        }
        let actualActions = calls.map { message -> String in
            guard let params = message.object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any]
            else { return "<unparsed>" }
            return arguments["action"] as? String ?? "<unparsed>"
        }
        guard actualActions == expectedActions else {
            return "Expected raw item/tool/call actions \(expectedActions), received \(actualActions)"
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
            }), started.sequence < call.sequence else {
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

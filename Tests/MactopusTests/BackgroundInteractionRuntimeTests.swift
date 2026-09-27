import Foundation
import XCTest
@testable import Mactopus

/// Production Core and child-process JSON-RPC, not policy-helper unit tests.
/// Targets and observations are deliberately nonexistent. The owned-browser
/// launch seam also throws before spawn. These tests never use the live UI.
@MainActor
final class BackgroundInteractionRuntimeTests: XCTestCase {
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
    private let taskID = "background-policy-task"
    private let staleID = "11111111-1111-4111-8111-111111111111"
    private let absentApp = "com.example.MactopusBackgroundSentinel"

    private actor GrounderAudit: VisualGroundingClient {
        var prepares = 0
        var grounds = 0
        var browserLaunches = 0
        func prepare() async throws { prepares += 1 }
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            grounds += 1
            throw NSError(domain: "NoLiveGroundingInPolicyFixture", code: 1)
        }
        func refuseBrowserLaunch() throws {
            browserLaunches += 1
            throw NSError(domain: "NoLiveBrowserInPolicyFixture", code: 1)
        }
        func shutdown() async -> [String] { [] }
    }

    private final class Audit {
        var status: TaskStatus?
        var approvals = 0
        var entries = [TimelineEntry]()
        var deltas = [String]()
        var compactions = 0
        var assistant: [String] { entries.filter { $0.kind == .assistant }.map(\.body) }
        func beginTurn() { status = nil }
    }

    func testDefaultRuntimeRejectsForegroundV2RoutesBeforeApprovalOrGrounder() async throws {
        let points: [String: Any] = ["capture_id": staleID, "x": 1, "y": 1]
        let cases: [(String, [String: Any])] = [
            ("computer_v2_open", ["bundle_id": absentApp, "activation": "foreground"]),
            ("computer_v2_open", ["bundle_id": absentApp, "url": "https://example.com/inert"]),
            ("computer_v2_open", ["bundle_id": "com.google.Chrome", "browser_mode": "isolated", "url": "https://example.com/inert"]),
            ("computer_v2_ax", ["snapshot_id": staleID, "element_index": 1, "ax_action": "AXRaise"]),
            ("computer_v2_click", points),
            ("computer_v2_pointer", points.merging(["action": "move"]) { _, new in new }),
            ("computer_v2_pointer", points.merging(["action": "double_click"]) { _, new in new }),
            ("computer_v2_pointer", points.merging(["action": "right_click"]) { _, new in new }),
            ("computer_v2_pointer", points.merging(["action": "scroll", "delta_x": 0, "delta_y": 1]) { _, new in new }),
            ("computer_v2_keypress", ["key": "enter", "modifiers": []]),
            ("computer_v2_type", ["text": "MUST_NOT_TYPE"]),
            ("computer_v2_ground_click", ["capture_id": staleID, "target": "Synthetic control"]),
        ]
        try await withHarness { runtime, root, audit, grounder in
            for (index, item) in cases.enumerated() {
                try await self.submit(["tool": item.0, "arguments": item.1], runtime: runtime, audit: audit)
                try await self.waitFor { audit.status == .waiting && self.rowCount(root) == index + 1 }
                let row = try XCTUnwrap(self.rows(root).last)
                XCTAssertEqual(row["tool"] as? String, item.0)
                XCTAssertEqual(row["success"] as? Bool, false)
                XCTAssertTrue((row["text"] as? String)?.lowercased().contains("background-only") == true,
                              "Expected the host policy to deny \(item.0) before app binding or OS input: \(row)")
                XCTAssertTrue((row["text"] as? String)?.contains("dispatch=not_dispatched") == true)
            }
            try self.assertNoUnsupportedAnswer(audit)
            XCTAssertEqual(audit.approvals, 0, "Even an auto-approving controller cannot grant a foreground capability.")
            let prepares = await grounder.prepares, grounds = await grounder.grounds, launches = await grounder.browserLaunches
            XCTAssertEqual(prepares, 0)
            XCTAssertEqual(grounds, 0)
            XCTAssertEqual(launches, 0)
            let specs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("specs.json"))) as? [[String: Any]])
            let names = Set(specs.compactMap { $0["name"] as? String })
            for tool in ["computer_v2_click", "computer_v2_pointer", "computer_v2_keypress", "computer_v2_type", "computer_v2_ground_click"] {
                XCTAssertFalse(names.contains(tool), "Unsupported tools should also be absent from model-visible specs.")
            }
            try await self.verifyNextTurn(runtime: runtime, audit: audit)
        }
    }

    func testLegacyMutationAliasesCannotEvadeDefaultBackgroundPolicy() async throws {
        let arguments: [String: Any] = ["process_id": Int32.max, "snapshot_id": staleID, "element_index": 1]
        let cases: [(String, [String: Any])] = [
            ("desktop_open_application", ["bundle_id": absentApp]),
            ("desktop_perform_action", arguments.merging(["action": "AXPress"]) { _, new in new }),
            ("desktop_set_text", arguments.merging(["text": "MUST_NOT_SET"]) { _, new in new }),
            ("desktop_input", ["process_id": Int32.max, "action": "click", "x": 1, "y": 1]),
            ("computer", ["action": "open", "parameters": ["bundle_id": absentApp]]),
            ("computer", ["action": "ax", "parameters": arguments.merging(["ax_action": "AXRaise"]) { _, new in new }]),
            ("computer", ["action": "type", "parameters": ["process_id": Int32.max, "text": "MUST_NOT_TYPE"]]),
        ]
        try await withHarness { runtime, root, audit, grounder in
            for (index, item) in cases.enumerated() {
                try await self.submit(["tool": item.0, "arguments": item.1], runtime: runtime, audit: audit)
                try await self.waitFor { audit.status == .waiting && self.rowCount(root) == index + 1 }
                let row = try XCTUnwrap(self.rows(root).last)
                XCTAssertEqual(row["success"] as? Bool, false)
                XCTAssertTrue((row["text"] as? String)?.contains("Legacy computer mutations are unavailable") == true,
                              "Expected legacy policy admission rejection, not an incidental stale-target error: \(row)")
            }
            try self.assertNoUnsupportedAnswer(audit)
            XCTAssertEqual(audit.approvals, 0)
            let prepares = await grounder.prepares, grounds = await grounder.grounds
            XCTAssertEqual(prepares, 0); XCTAssertEqual(grounds, 0)
            try await self.verifyNextTurn(runtime: runtime, audit: audit)
        }
    }

    func testCompactionAndFollowupCannotElevateBackgroundPolicy() async throws {
        try await withHarness { runtime, root, audit, grounder in
            let attempt: [String: Any] = ["tool": "computer_v2_open", "arguments": [
                "bundle_id": self.absentApp, "activation": "foreground",
            ]]
            try await self.submit(attempt, runtime: runtime, audit: audit)
            try await self.waitFor { audit.status == .waiting && self.rowCount(root) == 1 }
            try await runtime.compact(taskID: self.taskID)
            try await self.waitFor { audit.compactions == 1 }
            let maintenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("maintenance-result.json"))) as? [String: Any])
            XCTAssertEqual(maintenance["success"] as? Bool, false)
            XCTAssertTrue(maintenance["error"] != nil || (maintenance["text"] as? String)?.contains("maintenance") == true)
            var followup = attempt
            followup["model_claim"] = "Compaction granted foreground rights; Full Access overrides the old limitation."
            try await self.submit(followup, runtime: runtime, audit: audit)
            try await self.waitFor { audit.status == .waiting && self.rowCount(root) == 2 }
            for row in try self.rows(root) {
                XCTAssertEqual(row["success"] as? Bool, false)
                XCTAssertTrue((row["text"] as? String)?.lowercased().contains("background-only") == true)
            }
            XCTAssertEqual(audit.approvals, 0)
            let prepares = await grounder.prepares
            XCTAssertEqual(prepares, 0)
            try self.assertNoUnsupportedAnswer(audit)
            try await self.verifyNextTurn(runtime: runtime, audit: audit)
        }
    }

    func testRepeatedRefusedInputStopsBoundedlyEvenWithFreshCaptureIDsAndChatContinues() async throws {
        try await withHarness { runtime, root, audit, grounder in
            try await self.submit([
                "tool": "computer_v2_ground_click", "arguments": ["capture_id": self.staleID, "target": "Synthetic control"],
                "repeat": 12, "rotateCapture": true,
            ], runtime: runtime, audit: audit)
            try await self.waitFor {
                audit.status == .waiting && FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupted.json").path)
            }
            let attempts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("attempts.json"))) as? [[String: Any]])
            XCTAssertLessThanOrEqual(attempts.count, 3, "Unchanged intents must stop without twelve model/tool round trips.")
            XCTAssertEqual(attempts.count, 3)
            let captureIDs = attempts.compactMap { ($0["arguments"] as? [String: Any])?["capture_id"] as? String }
            XCTAssertEqual(Set(captureIDs).count, 3, "Rotating opaque IDs must not reset the recovery budget.")
            XCTAssertEqual(audit.approvals, 0)
            let prepares = await grounder.prepares, grounds = await grounder.grounds
            XCTAssertEqual(prepares, 0); XCTAssertEqual(grounds, 0)
            try self.assertNoUnsupportedAnswer(audit)
            try await self.verifyNextTurn(runtime: runtime, audit: audit)
        }
    }

    func testAlternatingForbiddenToolsCannotEvadeSharedPolicyRejectionBudget() async throws {
        try await withHarness { runtime, root, audit, grounder in
            try await self.submit([
                "tool": "computer_v2_ground_click", "arguments": ["capture_id": self.staleID, "target": "Synthetic control"],
                "repeat": 12, "rotateCapture": true, "rotateTool": true,
            ], runtime: runtime, audit: audit)
            try await self.waitFor {
                audit.status == .waiting && FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupted.json").path)
            }
            let attempts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("attempts.json"))) as? [[String: Any]])
            XCTAssertEqual(attempts.compactMap { $0["tool"] as? String }, [
                "computer_v2_ground_click", "computer_v2_type", "computer_v2_open",
            ], "Rephrasing the target or switching input tool must not evade the shared policy budget.")
            XCTAssertEqual(audit.approvals, 0)
            let prepares = await grounder.prepares, grounds = await grounder.grounds
            XCTAssertEqual(prepares, 0); XCTAssertEqual(grounds, 0)
            try self.assertNoUnsupportedAnswer(audit)
            try await self.verifyNextTurn(runtime: runtime, audit: audit)
        }
    }

    private func submit(_ plan: [String: Any], runtime: CodexAppServerRuntime, audit: Audit) async throws {
        audit.beginTurn()
        let data = try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])
        try await runtime.submit(prompt: String(decoding: data, as: UTF8.self), toTaskID: taskID, modelID: modelID)
    }

    private func verifyNextTurn(runtime: CodexAppServerRuntime, audit: Audit) async throws {
        try await submit(["marker": "NEXT_TURN_OK"], runtime: runtime, audit: audit)
        try await waitFor { audit.status == .completed && audit.assistant.contains("NEXT_TURN_OK") }
        try assertNoUnsupportedAnswer(audit)
        XCTAssertEqual(audit.approvals, 0)
    }

    private func assertNoUnsupportedAnswer(_ audit: Audit) throws {
        XCTAssertFalse(audit.assistant.contains { $0.contains("UNSUPPORTED_") }, "Late model claims cannot turn a refusal into success.")
        XCTAssertFalse(audit.deltas.contains { $0.contains("UNSUPPORTED_") }, "Unsupported success must not leak through streaming.")
    }

    private func rows(_ root: URL) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results.json"))) as? [[String: Any]])
    }

    private func rowCount(_ root: URL) -> Int { (try? rows(root).count) ?? 0 }

    private func withHarness(_ body: (CodexAppServerRuntime, URL, Audit, GrounderAudit) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusBackgroundPolicy-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BackgroundInteractionAppServer.ts")
        let executable = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        XCTAssertEqual(configuration.computerInteractionPolicy, .backgroundOnly)
        configuration.executable = .fixture(path: executable.path)
        configuration.codexHomePath = root.path
        configuration.workspacePath = workspace.path
        configuration.model = modelID
        configuration.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
        let grounder = GrounderAudit()
        let broker = ChromeTabBroker(willLaunchBrowser: { try await grounder.refuseBrowserLaunch() })
        let runtime = CodexAppServerRuntime(configuration: configuration, browserBroker: broker, visualGrounder: grounder)
        let audit = Audit()
        let events = Task {
            for await event in runtime.events() {
                switch event {
                case .taskStatusChanged(_, let status): audit.status = status
                case .timelineEntryAppended(_, let entry): audit.entries.append(entry)
                case .assistantMessageDelta(_, _, let text): audit.deltas.append(text)
                case .contextCompactionChanged(_, let state): if state == .completed { audit.compactions += 1 }
                case .approvalRequested(let request):
                    // Same answer policy as Full Access, deliberately not a
                    // foreground grant. A rejected tool must never reach here.
                    audit.approvals += 1
                    try? await runtime.resolveApproval(requestID: request.id, approved: true)
                default: break
                }
            }
        }
        do {
            _ = try await runtime.loadTasks()
            try await body(runtime, root, audit, grounder)
            let shutdown = await runtime.shutdown()
            events.cancel()
            XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
        } catch {
            _ = await runtime.shutdown()
            events.cancel()
            throw error
        }
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "BackgroundInteractionRuntimeTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for deterministic background-policy transport evidence"])
    }
}

import AutomationCore
import Foundation
import XCTest
@testable import Mactopus

/// Actual production Core, turn tracking, tool validation, approval and routing
/// over an owned JSON-RPC fixture and inert borrowed adapter. No real Chrome,
/// model, filesystem permissions, desktop input or system settings are used.
@MainActor
final class BorrowedChromeRuntimeRoutingTests: XCTestCase {
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"

    /// Real model and bundled App Server; only browser state is simulated.
    /// This measures use of the runtime's verification contract, not live
    /// Chrome/Gmail behavior, native input or desktop noninterference.
    func testRealQwen4BUsesOutcomeVerificationOnInertBorrowedTab() async throws {
        try await runRealQwenOutcomeGate(followup: false)
    }

    func testRealQwen4BContinuesOnExactBorrowedTabWithFreshReferencesAndOneVerifiedPress() async throws {
        try await runRealQwenOutcomeGate(followup: true)
    }

    private func runRealQwenOutcomeGate(followup: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless((environment["MACROUSE_QWEN_OUTCOME_GATE"]
                           ?? environment["TEST_RUNNER_MACROUSE_QWEN_OUTCOME_GATE"]) == "1",
                          "Reserve the inference lane and opt in to the real 4B inert outcome gate.")
        let portFree = try await outcomeGatePortIsFree()
        try XCTSkipUnless(portFree, "Port 1237 is occupied; this test never adopts or stops an unrelated model server.")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusQwenOutcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent("runtime-home"), workspace = root.appendingPathComponent("workspace")
        for directory in [home, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let traceURL = home.appendingPathComponent("app-server-wire.jsonl")
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.codexHomePath = home.path
        config.workspacePath = workspace.path
        config.protocolTracePath = traceURL.path
        config.model = modelID
        XCTAssertTrue(config.isBundled)
        XCTAssertEqual(config.effectiveBackend, .headlessMLX)
        XCTAssertEqual(config.computerInteractionPolicy, .backgroundOnly,
                       "The real-model gates must qualify the production background-only default.")
        let connector = BorrowedRuntimeConnector()
        let runtime = CodexAppServerRuntime(configuration: config, visualGrounder: NoModelGrounder(),
                                           borrowedChromeConnector: { try await connector.connect($0) })
        let taskID = followup ? "qwen-inert-continuation" : "qwen-inert-outcome"
        let request = request()
        let audit = OutcomeGateAudit(taskID: taskID, permitsMutation: !followup)
        let events = Task {
            for await event in runtime.events() {
                switch event {
                case .taskStatusChanged(let id, let status) where id == taskID:
                    audit.status = status
                case .timelineEntryAppended(let id, let entry) where id == taskID:
                    audit.observe(entry)
                case .approvalRequested(let approval):
                    let approved = audit.approve(approval)
                    try? await runtime.resolveApproval(requestID: approval.id, approved: approved)
                    if !approved { try? await runtime.interrupt(taskID: taskID) }
                default: break
                }
            }
        }
        var failure: Error?
        var observedCounts: BorrowedRuntimeTransport.Counts?
        var connectionCount: Int?
        let start = Date()
        print("MACROUSE_QWEN_OUTCOME_ARTIFACT_DIR=\(root.path)")
        do {
            _ = try await runtime.loadTasks()
            try await runtime.connectChrome(request)
            if followup {
                try await runtime.submit(prompt: """
                    Use the background Chrome tab tools only. In the already connected session,
                    use a tab at https://example.com/inert and read its current counter value.
                    Only inspect it and tell me the value. Do not click or change anything yet.
                    Leave all tabs and text fields unchanged. Keep Chrome in the background.
                    """, toTaskID: taskID, modelID: modelID)
                try await waitForOutcomeGate(audit)
                let entry = try await connector.entry(request.id)
                let before = await entry.transport.counts()
                guard audit.status == .completed, audit.denied.isEmpty,
                      before.presses == 0, before.text.isEmpty, before.forbidden == 0,
                      before.attachIDs.count == 1, audit.approvedPresses == 0 else {
                    throw OutcomeGateFailure(message: "The first continuation turn did not complete a read-only binding/inspection.")
                }
                XCTAssertTrue(audit.entries.contains { $0.toolEvent?.name == "computer_v2_snapshot" && $0.toolEvent?.status == .succeeded })
                try await waitForAsync { await entry.transport.counts().detaches == 1 }
                XCTAssertNoThrow(try request.consent.check())
                audit.beginContinuationMutationTurn()
                try await runtime.submit(prompt: """
                    Now increase that counter exactly once and verify that Count is 1 before answering.
                    Report the value you observed. Leave the text fields and other tabs unchanged.
                    """, toTaskID: taskID, modelID: modelID)
            } else {
                try await runtime.submit(prompt: """
                Use the background Chrome tab tools only. In the already connected session,
                use a tab at https://example.com/inert. Increase its counter exactly once.
                Verify that Count is 1 before answering, and report the value you observed.
                Leave the text fields and other tabs unchanged. Keep Chrome in the background.
                """, toTaskID: taskID, modelID: modelID)
            }
            try await waitForOutcomeGate(audit)
            let entry = try await connector.entry(request.id)
            observedCounts = await entry.transport.counts()
            connectionCount = await connector.count
            XCTAssertEqual(audit.status, .completed, "A waiting/unverified turn does not pass the real-model gate.")
            XCTAssertTrue(audit.denied.isEmpty, audit.denied.joined(separator: "; "))
            XCTAssertTrue(audit.unexpectedTools.isEmpty, audit.unexpectedTools.joined(separator: "; "))
            XCTAssertEqual(audit.approvedPresses, 1)
            XCTAssertEqual(observedCounts?.presses, 1)
            XCTAssertEqual(observedCounts?.text, "")
            XCTAssertEqual(observedCounts?.forbidden, 0)
            XCTAssertEqual(observedCounts?.attachIDs.count, followup ? 2 : 1)
            if followup {
                XCTAssertEqual(Set(observedCounts?.attachIDs ?? []).count, 1,
                    "An identically titled tab on the same URL must not substitute for the original exact target.")
                XCTAssertEqual(connectionCount, 1, "Both turns must reuse the single authorized connection.")
                XCTAssertNoThrow(try request.consent.check())
                XCTAssertEqual(observedCounts?.shutdowns, 0, "Turn rollover must not disconnect the browser owner.")
            }
            XCTAssertTrue(audit.entries.contains { $0.kind == .assistant && !$0.body.isEmpty })
            XCTAssertTrue(audit.transcript.contains {
                ["computer_v2_ax", ComputerOutcomeToolContract.name].contains($0["tool"] ?? "")
                    && $0["status"] == ToolRunStatus.succeeded.rawValue
                    && ($0["text"] ?? "").contains("VERIFIED_PROPERTY operation_id=")
            }, "The runtime must confirm the declared result; the model's final claim alone is insufficient.")
            try assertOutcomeGateWire(traceURL, followup: followup)
        } catch { failure = error }

        let shutdown = await runtime.shutdown()
        events.cancel()
        XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
        var listenerGone = false
        do { listenerGone = try await outcomeGatePortIsFree() }
        catch { if failure == nil { failure = error } }
        XCTAssertTrue(listenerGone, "The owned MLX listener must be absent after shutdown; no process is forcibly removed by this test.")
        let counts = observedCounts
        let report: [String: Any] = [
            "model": modelID, "production_core": true, "bundled_app_server": true,
            "real_model": true, "simulated_browser_transport": true, "real_chrome": false,
            "continuation_gate": followup, "expected_user_turns": followup ? 2 : 1,
            "connection_count": connectionCount ?? -1,
            "attached_target_ids": counts?.attachIDs ?? [],
            "gmail_tested": false, "scripted_tool_plan": false, "prompt_names_verify_tool": false,
            "elapsed_seconds": Date().timeIntervalSince(start),
            "status": audit.status?.rawValue ?? "unknown", "approved_presses": audit.approvedPresses,
            "denied_approvals": audit.denied, "unexpected_tools": audit.unexpectedTools,
            "tools": audit.tools, "transcript": audit.transcript,
            "presses": counts?.presses ?? -1, "text": counts?.text ?? "unobserved",
            "forbidden_operations": counts?.forbidden ?? -1,
            "runtime_shutdown_verified": shutdown.succeeded, "owned_listener_gone": listenerGone,
            "failure": failure?.localizedDescription ?? "none",
            "xctest_failures": testRun?.totalFailureCount ?? 0,
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        let reportURL = root.appendingPathComponent("report.json")
        try reportData.write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        let attachment = XCTAttachment(data: reportData, uniformTypeIdentifier: "public.json")
        attachment.name = followup ? "Real 4B inert two-turn continuation gate" : "Real 4B inert outcome verification gate"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MACROUSE_QWEN_OUTCOME_REPORT=\(reportURL.path)")
        if let failure { throw failure }
    }

    private func waitForOutcomeGate(_ audit: OutcomeGateAudit) async throws {
        for _ in 0 ..< 2_400 {
            if audit.status == .completed || audit.status == .waiting || !audit.denied.isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw OutcomeGateFailure(message: "Real 4B verification gate timed out after 240 seconds in one turn.")
    }

    func testProductionToolLifecycleUsesBorrowedOwnerAndNeverGlobalInput() async throws {
        // Exercise the borrowed binding's own narrower capability boundary,
        // independently of the host-wide background-only denial budget. Even
        // a foreground-capable host must never send global input to this tab.
        try await withHarness(mode: "full", interactionPolicy: .foregroundAllowed) { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Inert borrowed browser workflow", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .waiting, "The deliberately rejected requests remain unresolved even though both supported actions were verified.")
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 16)
            XCTAssertEqual(rows.prefix(12).compactMap { $0["success"] as? Bool },
                           [true, true, true, true, false, true, true, true, true, true, true, true])
            XCTAssertEqual(rows.suffix(4).compactMap { $0["success"] as? Bool }, Array(repeating: false, count: 4))
            let verified = rows.filter { $0["tool"] as? String == "computer_v2_verify" }
            XCTAssertEqual(verified.count, 2)
            XCTAssertTrue(verified.allSatisfy { $0["success"] as? Bool == true })
            XCTAssertEqual(audit.approvals, 2, "Read-only inventory/attachment must not request desktop-action approval")
            let entry = try await connector.entry(request.id)
            try await self.waitForAsync { await entry.transport.counts().detaches == 1 }
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.attachIDs, ["target-1"])
            XCTAssertEqual(counts.presses, 1)
            XCTAssertEqual(counts.text, "HDé7 東京 👋")
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(counts.shutdowns, 0, "Turn completion detaches sessions but keeps the explicitly connected browser connection")
            let fresh = try await entry.owner.beginTurn(taskKey: "task", turnID: "after-completion")
            await entry.owner.revoke(turn: fresh)
            let specs = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("specs.json"))) as? [[String: Any]]
            XCTAssertTrue(specs?.contains { $0["name"] as? String == "computer_v2_tabs" } == true)
            XCTAssertTrue(specs?.contains { $0["name"] as? String == "computer_v2_bind_tab" } == true)
        }
    }

    func testToolsWithoutNativeConnectionFailWithoutCallingConnector() async throws {
        try await withHarness(mode: "no-connection") { runtime, root, audit, connector in
            try await runtime.submit(prompt: "List tabs without consent", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .waiting, "A missing connection is not a successful browser task.")
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["success"] as? Bool, false)
            let diagnostic = try XCTUnwrap(rows.first?["text"] as? String)
            XCTAssertTrue(diagnostic.contains("not evidence that macOS computer-use permission was denied"))
            XCTAssertTrue(diagnostic.contains("Do not retry computer_v2_tabs"))
            XCTAssertTrue(diagnostic.contains("Connect Chrome menu"))
            let calls = await connector.count
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(audit.approvals, 0)
        }
    }

    func testNamedSiteMismatchIsRejectedBeforeAttachmentDespiteMisleadingTitle() async throws {
        try await withHarness(mode: "wrong-site") { runtime, root, audit, connector in
            await connector.setCandidateMetadata(url: URL(string: "https://github.com/fixture/repository")!, title: "Gmail inbox")
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Search Gmail for my flight.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .waiting || audit.status == .completed }
            XCTAssertEqual(audit.status, .waiting)
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.last?["success"] as? Bool, false)
            XCTAssertTrue((rows.last?["text"] as? String)?.contains("does not match the requested Gmail site") == true)
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.attachIDs, [], "The unrelated site's page must not be attached or read.")
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertFalse(audit.entries.contains { $0.body.contains("WRONG_SITE_SUCCESS_MUST_NOT_APPEAR") })
        }
    }

    func testBackgroundChromeOnlyRejectsNativeOpenBeforeApprovalOrDispatch() async throws {
        try await withHarness(mode: "background-open") { runtime, root, audit, connector in
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Inspect the existing tab.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .waiting || audit.status == .completed }
            XCTAssertEqual(audit.status, .waiting)
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["success"] as? Bool, false)
            XCTAssertTrue((rows.first?["text"] as? String)?.contains("outside the requested scope") == true)
            XCTAssertEqual(audit.approvals, 0, "Reject native fallback before the native action approval boundary.")
            let count = await connector.count
            XCTAssertEqual(count, 0)
            XCTAssertFalse(audit.entries.contains { $0.body.contains("FOREGROUND_FALLBACK_SUCCESS_MUST_NOT_APPEAR") })
        }
    }

    func testRepeatedBindsStopWithOriginalConnectionCauseAndTheNextTurnStillWorks() async throws {
        try await withHarness(mode: "repeated-bind") { runtime, root, audit, connector in
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Inspect a tab.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupted").path)
                && audit.status == .waiting }
            let attempted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("attempted-tools.json"))) as? [String])
            XCTAssertEqual(attempted, ["computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_bind_tab"])
            let rows = try self.results(root)
            XCTAssertGreaterThanOrEqual(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { $0["success"] as? Bool == false })
            XCTAssertTrue(rows.allSatisfy { ($0["text"] as? String)?.contains("not connected") == true })
            XCTAssertFalse(rows.contains { ($0["text"] as? String)?.contains("No current borrowed Chrome inventory") == true })
            XCTAssertTrue(audit.entries.contains { $0.title == "Native action stopped" && $0.body.contains("not connected") })
            XCTAssertFalse(audit.entries.contains { $0.body.contains("LATE_SEARCH_SUCCESS_MUST_NOT_APPEAR") })
            XCTAssertEqual(audit.approvals, 0)
            let count = await connector.count
            XCTAssertEqual(count, 0)

            audit.status = nil
            try await runtime.submit(prompt: "Reply without computer tools.", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed && audit.entries.contains { $0.body == "NEXT_TURN_OK" } }
            XCTAssertEqual(audit.status, .completed, "A bounded failed attempt must not make the chat unusable.")
        }
    }

    func testFollowupRestoresExactConnectedTabButRejectsOldAXBeforeOneVerifiedFreshAction() async throws {
        try await withHarness(mode: "followup-binding-recovery") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Inspect https://example.com/inert before increasing its counter.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            XCTAssertEqual(try self.results(root).count, 3)
            let connection = try await connector.entry(request.id)
            try await self.waitForAsync { await connection.transport.counts().detaches == 1 }
            XCTAssertNoThrow(try request.consent.check())

            audit.status = nil
            try await runtime.submit(prompt: "yes", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 8)
            let followup = Array(rows.dropFirst(3))
            XCTAssertEqual(followup.compactMap { $0["tool"] as? String },
                           ["computer_v2_ax", "computer_v2_snapshot", "computer_v2_ax", "computer_v2_snapshot", "computer_v2_verify"],
                           "The model does not need to repeat inventory and binding just to continue the same authorized task.")
            XCTAssertEqual(followup.compactMap { $0["success"] as? Bool }, [false, true, true, true, true])
            XCTAssertTrue((followup.first?["text"] as? String)?.contains("preflight_rejection=bindingRequired") == true)
            guard followup.count == 5 else { return }
            XCTAssertTrue((followup[2]["text"] as? String)?.contains("preflight_corrected_not_performed") == true,
                          "Automatic post-action proof must resolve the prior rejection before any optional model verification.")
            XCTAssertTrue((followup[2]["text"] as? String)?.contains("No unresolved action receipts.") == true)
            XCTAssertTrue((followup.last?["text"] as? String)?.contains("VERIFIED_PROPERTY operation_id=borrowed-call-102") == true)
            XCTAssertEqual(audit.status, .completed, "The recovered preflight failure must not poison the final answer.")
            XCTAssertTrue(audit.entries.contains { $0.kind == .assistant && $0.body == "FOLLOWUP_RECOVERY_COMPLETE" })
            XCTAssertFalse(audit.entries.contains { $0.title == "Outcome not verified" })
            try await self.waitForAsync { await connection.transport.counts().detaches == 2 }
            let counts = await connection.transport.counts()
            XCTAssertEqual(counts.attachIDs, ["target-0", "target-0"], "Identical title/URL on another tab must not replace the original target.")
            XCTAssertEqual(counts.presses, 1, "The previous turn's AX capability must never be replayed.")
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(counts.shutdowns, 0)
            XCTAssertEqual(audit.approvals, 1, "Only the one fresh mutation requires action approval; restoration is read-only.")
            let connections = await connector.count
            XCTAssertEqual(connections, 1, "Continuation must reuse the existing authorized connection, not ask to connect again.")
        }
    }

    func testFollowupForDifferentSiteDoesNotSilentlyRestorePreviousTab() async throws {
        try await withHarness(mode: "followup-scope-change") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Inspect https://example.com/inert.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            let connection = try await connector.entry(request.id)
            try await self.waitForAsync { await connection.transport.counts().detaches == 1 }

            audit.status = nil
            try await runtime.submit(prompt: "Now inspect https://github.com/fixture/repository using background Chrome only.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 4)
            XCTAssertEqual(rows.last?["success"] as? Bool, false)
            XCTAssertTrue((rows.last?["text"] as? String)?.contains("previous tab cannot safely be resumed") == true)
            let counts = await connection.transport.counts()
            XCTAssertEqual(counts.attachIDs, ["target-0"], "No second attachment or replacement is allowed for a scope mismatch.")
            XCTAssertEqual(counts.presses, 0)
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertFalse(audit.entries.contains { $0.body.contains("WRONG_CONTINUATION_MUST_NOT_APPEAR") })
            XCTAssertNoThrow(try request.consent.check(), "A changed request should not revoke the remembered connection itself.")
        }
    }

    func testFollowupRejectsOriginNavigationDuringAttachmentBeforeExposingPageContent() async throws {
        try await withHarness(mode: "followup-origin-race") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            // Intentionally no named site: this must exercise the retained
            // exact-origin guard, not a request's service-name scope filter.
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Inspect the existing tab.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            let connection = try await connector.entry(request.id)
            try await self.waitForAsync { await connection.transport.counts().detaches == 1 }
            await connection.transport.navigateOnNextAttach(to: URL(string: "https://different.example/private")!)

            audit.status = nil
            try await runtime.submit(prompt: "yes", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 4)
            XCTAssertEqual(rows.last?["success"] as? Bool, false)
            let resultText = rows.last?["text"] as? String ?? ""
            XCTAssertTrue(resultText.contains("changed site while it was being reacquired"))
            XCTAssertFalse(resultText.contains("DIFFERENT_ORIGIN_PRIVATE_CONTENT"))
            XCTAssertFalse(audit.entries.contains { $0.body.contains("DIFFERENT_ORIGIN_PRIVATE_CONTENT") })
            XCTAssertFalse(audit.entries.contains { $0.body.contains("WRONG_ORIGIN_CONTENT_MUST_NOT_APPEAR") })
            try await self.waitForAsync { await connection.transport.counts().detaches == 2 }
            let counts = await connection.transport.counts()
            XCTAssertEqual(counts.attachIDs, ["target-0", "target-0"], "Inventory looked safe; origin changed only during the second attachment.")
            XCTAssertEqual(counts.presses, 0)
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertNoThrow(try request.consent.check())
        }
    }

    func testMalformedFirstFollowupReadRecoversAfterValidatedReadRestoresActualTarget() async throws {
        try await withHarness(mode: "followup-unbound-schema") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Inspect the existing tab.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            let connection = try await connector.entry(request.id)
            try await self.waitForAsync { await connection.transport.counts().detaches == 1 }

            audit.status = nil
            try await runtime.submit(prompt: "yes", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let followup = Array(try self.results(root).dropFirst(3))
            XCTAssertEqual(followup.compactMap { $0["tool"] as? String }, ["computer_v2_snapshot", "computer_v2_snapshot"])
            XCTAssertEqual(followup.compactMap { $0["success"] as? Bool }, [false, true])
            XCTAssertTrue((followup.first?["text"] as? String)?.contains("preflight_rejection=invalidArguments") == true)
            XCTAssertTrue((followup.last?["text"] as? String)?.contains("observation=live") == true)
            XCTAssertEqual(audit.status, .completed, "Accepted final completion proves the schema rejection no longer leaves unresolved debt.")
            XCTAssertTrue(audit.entries.contains { $0.kind == .assistant && $0.body == "FOLLOWUP_SCHEMA_RECOVERY_COMPLETE" })
            XCTAssertFalse(audit.entries.contains { $0.title == "Outcome not verified" })
            let counts = await connection.transport.counts()
            XCTAssertEqual(counts.attachIDs, ["target-0", "target-0"])
            XCTAssertEqual(counts.presses, 0)
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.approvals, 0)
            let connections = await connector.count
            XCTAssertEqual(connections, 1)
        }
    }

    func testFailedBrowserToolSuppressesAnInventedSuccessfulSearchAnswer() async throws {
        try await withHarness(mode: "false-search-final") { runtime, root, audit, _ in
            try await runtime.submit(prompt: "Search my email for a flight.", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .waiting || audit.status == .completed }
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertEqual(try self.results(root).first?["success"] as? Bool, false)
            XCTAssertFalse(audit.entries.contains { $0.body.contains("HALLUCINATED_SEARCH") })
            let diagnostics = audit.entries.filter { $0.title == "Outcome not verified" }
            XCTAssertEqual(diagnostics.count, 1, "Publish one app-authored diagnostic, not one per final/completion event.")
            XCTAssertTrue(diagnostics.first?.body.contains("does not establish") == true)
            XCTAssertTrue(diagnostics.first?.body.contains("search found no results") == true)
        }
    }

    func testVerifiedSearchFieldAloneCannotProduceCompletedSearchOrEmptyResult() async throws {
        try await withHarness(mode: "search-fill-no-submit") { runtime, root, audit, connector in
            await connector.setTextRole("searchbox")
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Search my email for United flight.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 4)
            XCTAssertTrue(rows.allSatisfy { $0["success"] as? Bool == true }, "Filling and verifying a field may succeed while the search itself remains incomplete.")
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.text, "United flight")
            XCTAssertEqual(counts.presses, 0, "No search was submitted.")
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertFalse(audit.entries.contains { $0.body.contains("SEARCH_FILL_FALSE_NEGATIVE") })
            XCTAssertTrue(audit.entries.contains { $0.kind == .system && $0.title == "Outcome not verified" })
        }
    }

    func testObservedReadAndVerifiedPressCompleteWithoutAnUnrelatedFailure() async throws {
        try await withHarness(mode: "positive-read-press") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Increase the counter once and verify the count.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 6)
            XCTAssertTrue(rows.allSatisfy { $0["success"] as? Bool == true })
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.presses, 1)
            XCTAssertEqual(counts.text, "")
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.approvals, 1)
            XCTAssertEqual(audit.status, .completed)
            XCTAssertTrue(audit.entries.contains { $0.kind == .assistant && $0.body == "VERIFIED_ACTION_COMPLETE" })
            XCTAssertFalse(audit.entries.contains { $0.title == "Outcome not verified" })
        }
    }

    func testRuntimeVerifiesDeclaredBrowserResultWithoutAModelVerificationCall() async throws {
        try await runAutomaticVerification(mode: "runtime-verify-immediate", observedValues: ["1"])
    }

    func testRuntimeRetriesDelayedReadOnlyObservationWithoutRepeatingInput() async throws {
        try await runAutomaticVerification(mode: "runtime-verify-delayed", delayedReads: 2, observedValues: ["0", "0", "1"])
    }

    func testRuntimeReconcilesUnknownDispatchReplyWithoutRepeatingCommittedPress() async throws {
        try await runAutomaticVerification(mode: "runtime-verify-unknown-reply", unknownReply: true, observedValues: ["1"])
    }

    func testRuntimeGatesWrongOutcomeAfterThreeReadOnlyAttemptsWithoutRepeatingInput() async throws {
        try await runAutomaticVerification(mode: "runtime-verify-wrong-result", wrongResult: true, observedValues: ["0", "0", "0"])
    }

    func testRuntimeRejectsUnplannedBrowserPressBeforeApprovalOrDispatch() async throws {
        try await runAutomaticVerification(mode: "runtime-verify-no-plan", observedValues: [])
    }

    func testRuntimeVerificationSurvivesCompactionLifecycleBetweenDispatchAndObservation() async throws {
        try await runAutomaticVerification(mode: "runtime-verify-compaction", observedValues: ["1"], injectCompaction: true)
    }

    func testRuntimeCancellationDuringVerificationDoesNotReplayInputPublishLateProofOrPoisonNextTurn() async throws {
        try await withHarness(mode: "runtime-verify-cancel") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            let entry = try await connector.entry(request.id)
            let observationGate = BorrowedRuntimeConnectGate()
            await entry.transport.configureVerification(delayedReads: 0, wrongResult: false, unknownReply: false,
                                                        firstReadGate: observationGate, dispatchMarker: nil)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Increase the counter exactly once and verify Count is 1.",
                                     toTaskID: "task", modelID: self.modelID)
            do {
                try await self.waitForAsync { await observationGate.isPaused }
            } catch {
                await observationGate.release()
                throw error
            }
            let suspended = await entry.transport.counts()
            XCTAssertEqual(suspended.presses, 1)
            XCTAssertEqual(suspended.postPressObservations, 1)
            XCTAssertEqual(suspended.observedValues, [])
            XCTAssertEqual(try self.results(root).count, 3, "The model has received no post-action result before Stop.")

            // Stop cancels/revokes first and then drains the in-flight tool.
            // The inert adapter deliberately returns late, after observing
            // cancellation, to prove the old result cannot become evidence.
            let interruption = Task { try await runtime.interrupt(taskID: "task") }
            do {
                try await self.waitForAsync { await observationGate.cancellationRequested }
            } catch {
                await observationGate.release()
                _ = try? await interruption.value
                throw error
            }
            await observationGate.release()
            try await interruption.value
            try await self.waitFor { audit.status == .waiting }
            try await self.waitForAsync { await entry.transport.counts().detaches == 1 }

            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.presses, 1, "Stop must not retry an action whose dispatch already committed.")
            XCTAssertEqual(counts.postPressObservations, 1, "Cancelled verification must not spend another read attempt.")
            XCTAssertEqual(counts.text, "")
            XCTAssertEqual(counts.forbidden, 0, "No user tab may be created, activated, or closed.")
            XCTAssertEqual(counts.shutdowns, 0, "Stopping a turn preserves the authorized browser connection.")
            XCTAssertEqual(counts.attachIDs, ["target-0"])
            XCTAssertEqual(audit.approvals, 1)
            XCTAssertEqual(try self.results(root).count, 3, "A cancelled late read must not emit a tool-success response.")
            XCTAssertFalse(audit.entries.contains { $0.body.contains("CANCELLED_VERIFICATION_FALSE_SUCCESS_MUST_NOT_APPEAR") })
            XCTAssertFalse(audit.entries.contains { $0.toolEvent?.name == "computer_v2_ax" && $0.toolEvent?.status == .succeeded })
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupted").path))
            XCTAssertNoThrow(try request.consent.check())
            let candidates = try await entry.transport.listCandidates()
            XCTAssertEqual(candidates.map(\.targetID), ["target-0", "target-1"])

            audit.status = nil
            try await runtime.submit(prompt: "Reply briefly without using tools.", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed, "Cancelled verification must not force a new chat.")
            XCTAssertTrue(audit.entries.contains { $0.kind == .assistant && $0.body == "NEXT_TURN_OK" })
            XCTAssertFalse(audit.entries.contains { $0.body.contains("CANCELLED_VERIFICATION_FALSE_SUCCESS_MUST_NOT_APPEAR") })
            let afterFollowup = await entry.transport.counts()
            XCTAssertEqual(afterFollowup.presses, 1)
            XCTAssertEqual(afterFollowup.postPressObservations, 1)
            let connectionCount = await connector.count
            XCTAssertEqual(connectionCount, 1)
        }
    }

    private func runAutomaticVerification(
        mode: String, delayedReads: Int = 0, wrongResult: Bool = false,
        unknownReply: Bool = false, observedValues: [String], injectCompaction: Bool = false
    ) async throws {
        try await withHarness(mode: mode) { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            let entry = try await connector.entry(request.id)
            let observationGate = injectCompaction ? BorrowedRuntimeConnectGate() : nil
            await entry.transport.configureVerification(
                delayedReads: delayedReads, wrongResult: wrongResult, unknownReply: unknownReply,
                firstReadGate: observationGate,
                dispatchMarker: injectCompaction ? root.appendingPathComponent("press-dispatched") : nil
            )
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Increase the counter exactly once and verify Count is 1.",
                                     toTaskID: "task", modelID: self.modelID)
            if let observationGate {
                do {
                    try await self.waitFor { audit.compactions == [.running, .completed] }
                    let suspended = await entry.transport.counts()
                    XCTAssertEqual(suspended.presses, 1, "Compaction must occur after mutation, not before it.")
                    XCTAssertEqual(suspended.postPressObservations, 1)
                    XCTAssertEqual(suspended.observedValues, [], "The first post-dispatch read remains suspended until Core consumed both lifecycle events.")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("compaction-injected").path))
                    XCTAssertEqual(try self.results(root).count, 3, "No mutation result has been delivered to the fixture model yet.")
                } catch {
                    await observationGate.release()
                    throw error
                }
                await observationGate.release()
            }
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, [
                "computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_snapshot", "computer_v2_ax",
            ], "The scripted model must neither verify nor request post-action snapshots nor replay input.")
            let counts = await entry.transport.counts()
            let noPlan = mode == "runtime-verify-no-plan"
            let succeeds = !wrongResult && !noPlan
            XCTAssertEqual(counts.presses, noPlan ? 0 : 1)
            XCTAssertEqual(counts.postPressObservations, observedValues.count,
                           "Verification is bounded to three read-only attempts after one input dispatch.")
            XCTAssertEqual(counts.observedValues, observedValues)
            XCTAssertEqual(counts.text, "")
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.approvals, noPlan ? 0 : 1)
            XCTAssertEqual(counts.attachIDs, ["target-0"])
            let resultText = rows.last?["text"] as? String ?? ""
            if succeeds {
                XCTAssertEqual(rows.last?["success"] as? Bool, true)
                XCTAssertTrue(resultText.contains("VERIFIED_PROPERTY operation_id=borrowed-call-3"))
                XCTAssertTrue(resultText.contains("No unresolved action receipts."))
                XCTAssertEqual(audit.status, .completed)
                XCTAssertTrue(audit.entries.contains { $0.kind == .assistant && $0.body == "RUNTIME_AUTOMATIC_VERIFICATION_COMPLETE" })
                XCTAssertFalse(audit.entries.contains { $0.title == "Outcome not verified" })
            } else {
                XCTAssertEqual(audit.status, .waiting)
                XCTAssertFalse(audit.entries.contains { $0.body.contains("FALSE_SUCCESS_MUST_NOT_APPEAR") })
                XCTAssertEqual(audit.entries.filter { $0.title == "Outcome not verified" }.count, 1)
                XCTAssertFalse(resultText.contains("VERIFIED_PROPERTY"))
                if noPlan {
                    XCTAssertEqual(rows.last?["success"] as? Bool, false)
                    XCTAssertTrue(resultText.contains("requires postcondition before input"))
                    XCTAssertTrue(resultText.contains("dispatch=not_dispatched"))
                } else {
                    XCTAssertTrue(resultText.contains("VERIFICATION_PENDING"))
                    XCTAssertTrue(resultText.contains("dispatch=dispatched"))
                }
            }
            if injectCompaction {
                // This is production Core's handling of a forced protocol
                // lifecycle, not a claim that a real LLM compactor was run.
                XCTAssertEqual(audit.compactions, [.running, .completed])
            }
        }
    }

    func testUndispatchedEditableFieldFocusRecoversAfterVerifiedDirectText() async throws {
        try await withHarness(mode: "editable-focus-recovery") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Enter Recovered direct text in the Text field and verify its value.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, [
                "computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_snapshot", "computer_v2_ax", "computer_v2_set_text",
            ])
            XCTAssertEqual(rows.compactMap { $0["success"] as? Bool }, [true, true, true, false, true])
            XCTAssertTrue((rows.last?["text"] as? String)?.contains("No unresolved action receipts.") == true,
                          "Exact field-value proof should resolve the unnecessary undispatched focus prerequisite.")
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.text, "Recovered direct text")
            XCTAssertEqual(counts.presses, 0)
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.approvals, 1, "The rejected focus request must not ask for approval; only direct text entry does.")
            XCTAssertEqual(audit.status, .completed)
            XCTAssertTrue(audit.entries.contains { $0.kind == .assistant && $0.body == "DIRECT_TEXT_RECOVERY_COMPLETE" })
            XCTAssertFalse(audit.entries.contains { $0.title == "Outcome not verified" })
        }
    }

    func testUndispatchedStaleTextRecoversAfterSameFieldIsVerifiedWithFreshSnapshot() async throws {
        try await withHarness(mode: "stale-text-recovery") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Use the background Chrome tab tools only. Enter Recovered current text in the Text field and verify its value.",
                                     toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, [
                "computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_snapshot", "computer_v2_snapshot",
                "computer_v2_set_text", "computer_v2_set_text",
            ])
            XCTAssertEqual(rows.compactMap { $0["success"] as? Bool }, [true, true, true, true, false, true])
            guard rows.count == 6 else { return }
            XCTAssertTrue((rows[4]["text"] as? String)?.contains("snapshot is missing or stale") == true)
            XCTAssertTrue((rows[5]["text"] as? String)?.contains("No unresolved action receipts.") == true,
                          "A verified retry with the current capability should recover only the matching same-field intent.")
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.text, "Recovered current text")
            XCTAssertEqual(counts.presses, 0)
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(audit.approvals, 1, "Stale admission must fail before approval or input dispatch.")
            XCTAssertEqual(audit.status, .completed)
            XCTAssertTrue(audit.entries.contains { $0.kind == .assistant && $0.body == "STALE_TEXT_RECOVERY_COMPLETE" })
            XCTAssertFalse(audit.entries.contains { $0.title == "Outcome not verified" })
        }
    }

    func testUnsupportedBrowserCapabilitiesFailBeforeApprovalAndPreserveSnapshotForSupportedAction() async throws {
        // AXRaise must reach the browser's action-admission boundary here, not
        // be short-circuited by the production background-only host policy.
        // The original six rejections and both verified actions remain required.
        try await withHarness(mode: "unsupported-actions", interactionPolicy: .foregroundAllowed) { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Check capability admission without extra approvals", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .waiting, "Unsupported action requests do not become verified because other actions succeed.")
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 15)
            guard rows.count == 15 else { return }
            XCTAssertEqual(rows[3...8].compactMap { $0["success"] as? Bool }, Array(repeating: false, count: 6))
            XCTAssertTrue(rows[3...8].allSatisfy { ($0["text"] as? String)?.contains("No approval or action was requested") == true })
            XCTAssertTrue((rows[3]["text"] as? String)?.contains("computer_v2_set_text directly") == true)
            let verified = rows.filter { $0["tool"] as? String == "computer_v2_verify" }
            XCTAssertEqual(verified.count, 2)
            XCTAssertTrue(verified.allSatisfy { $0["success"] as? Bool == true }, "Rejected admissions must not poison valid action proof.")
            XCTAssertEqual(audit.approvals, 2, "Only the supported text entry and button press require approval; six rejected requests never ask.")
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.presses, 1)
            XCTAssertEqual(counts.text, "Supported direct text")
            XCTAssertEqual(counts.forbidden, 0)
        }
    }

    func testModelFailureDrainsOldBrowserTurnButPreservesSingleAuthorizedConnection() async throws {
        try await withHarness(mode: "inventory-hold") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold after listing", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            let entry = try await connector.entry(request.id)
            try await runtime.failServerAndDrainChromeForFixture()
            XCTAssertNoThrow(try request.consent.check())
            let fresh = try await entry.owner.beginTurn(taskKey: "task", turnID: "after-model-failure")
            _ = try await entry.owner.listTabs(turn: fresh)
            await entry.owner.revoke(turn: fresh)
            // Repeated model failures do not manufacture new native browser
            // connection attempts or carry a stale turn into the next model.
            try await runtime.failServerAndDrainChromeForFixture()
            let counts = await entry.transport.counts()
            let connections = await connector.count
            XCTAssertEqual(connections, 1)
            XCTAssertEqual(counts.shutdowns, 0)
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertFalse(audit.chrome.contains { $0.0 == request.id && $0.1 == .disconnected })
            await runtime.disconnectChrome()
            let afterDisconnect = await entry.transport.counts()
            XCTAssertEqual(afterDisconnect.shutdowns, 1)
            XCTAssertThrowsError(try request.consent.check())
        }
    }

    func testInterruptRevokesInventoryOnlyTurnWithoutClosingUserResources() async throws {
        try await withHarness(mode: "inventory-hold") { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold after listing", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            try await runtime.interrupt(taskID: "task")
            let entry = try await connector.entry(request.id)
            let fresh = try await entry.owner.beginTurn(taskKey: "task", turnID: "after-interrupt")
            await entry.owner.revoke(turn: fresh)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.attachIDs, [])
            XCTAssertEqual(counts.detaches, 0)
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(counts.shutdowns, 0)
        }
    }

    func testActiveTurnCannotGrantOrReplaceNativeConnection() async throws {
        try await withHarness(mode: "inventory-hold") { runtime, root, _, connector in
            let first = self.request()
            try await runtime.connectChrome(first)
            try await runtime.submit(prompt: "Hold after listing", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            let denied = self.request()
            do { try await runtime.connectChrome(denied); XCTFail("A model-active runtime cannot grant a native connection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("idle")) }
            XCTAssertThrowsError(try denied.consent.check())
            XCTAssertNoThrow(try first.consent.check())
            let count = await connector.count
            XCTAssertEqual(count, 1)
            try await runtime.interrupt(taskID: "task")
        }
    }

    func testPendingNativeHandshakeBlocksTurnAndCompactionAdmission() async throws {
        try await withHarness(mode: "full") { runtime, _, _, connector in
            let request = self.request(), gate = BorrowedRuntimeConnectGate()
            await connector.holdNext(gate)
            let connection = Task { try await runtime.connectChrome(request) }
            await gate.waitForArrival()
            do {
                try await runtime.submit(prompt: "Must not start", toTaskID: "task", modelID: self.modelID)
                XCTFail("Prompt admission must wait for native connection")
            } catch { XCTAssertTrue(error.localizedDescription.contains("native Chrome connection")) }
            do { try await runtime.compact(taskID: "task"); XCTFail("Compaction must not start") }
            catch { XCTAssertTrue(error.localizedDescription.contains("native Chrome connection")) }
            connection.cancel()
            XCTAssertThrowsError(try request.consent.check())
            await gate.release()
            do { try await connection.value; XCTFail("Cancelled connection cannot publish") }
            catch { XCTAssertTrue(error is CancellationError) }
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.shutdowns, 1)
        }
    }

    func testLateCancelledConnectionCannotCloseReplacementConnection() async throws {
        try await withHarness(mode: "full") { runtime, _, audit, connector in
            let old = self.request(), fresh = self.request(), gate = BorrowedRuntimeConnectGate()
            await connector.holdNext(gate)
            let first = Task { try await runtime.connectChrome(old) }
            await gate.waitForArrival()
            let second = Task { try await runtime.connectChrome(fresh) }
            try await self.waitFor { audit.chrome.contains { $0.0 == fresh.id && $0.1 == .connecting } }
            XCTAssertThrowsError(try old.consent.check())
            await gate.release()
            do { try await first.value; XCTFail("Old connection result cannot publish") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await second.value
            let oldEntry = try await connector.entry(old.id), freshEntry = try await connector.entry(fresh.id)
            XCTAssertNoThrow(try fresh.consent.check())
            let oldCounts = await oldEntry.transport.counts(), freshCounts = await freshEntry.transport.counts()
            XCTAssertEqual(oldCounts.shutdowns, 1)
            XCTAssertEqual(freshCounts.shutdowns, 0)
            try await self.waitFor { audit.chrome.contains { $0.0 == fresh.id && $0.1 == .connected } }
            XCTAssertFalse(audit.chrome.contains { $0.0 == old.id && $0.1 == .connected })
        }
    }

    func testDisconnectIsAvailableDuringActiveTurnAndRevokesExactOwner() async throws {
        try await withHarness(mode: "inventory-hold") { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold after listing", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            await runtime.disconnectChrome()
            XCTAssertThrowsError(try request.consent.check())
            let entry = try await connector.entry(request.id)
            do { _ = try await entry.owner.beginTurn(taskKey: "task", turnID: "new"); XCTFail("Owner must be disconnected") }
            catch { XCTAssertEqual(error as? BorrowedChromeSessionOwnerError, .disconnected) }
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.shutdowns, 1)
            XCTAssertEqual(counts.forbidden, 0)
            try await runtime.interrupt(taskID: "task")
        }
    }

    func testConnectionErrorsAreRedactedBeforeEventsAndThrownMessage() async throws {
        try await withHarness(mode: "full") { runtime, _, audit, connector in
            await connector.failNext()
            let request = self.request()
            do { try await runtime.connectChrome(request); XCTFail("Must fail") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains("secret-endpoint"))
                XCTAssertFalse(error.localizedDescription.contains("private-profile"))
            }
            try await self.waitFor { audit.chrome.contains { id, state in
                if case .failed = state { return id == request.id }; return false
            } }
            for (_, state) in audit.chrome {
                if case .failed(let message) = state {
                    XCTAssertFalse(message.contains("secret-endpoint"))
                    XCTAssertFalse(message.contains("private-profile"))
                }
            }
            XCTAssertThrowsError(try request.consent.check())
        }
    }

    func testBorrowedDisconnectPreservesCoexistingOwnedBindingUntilInterrupt() async throws {
        let owned = try await BorrowedRuntimeOwnedFixture.make()
        try await withHarness(mode: "inventory-hold", browserBroker: owned.broker) { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold inventory beside owned binding", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            try await runtime.installOwnedBrowserBindingForFixture(taskID: "task", binding: owned.binding)
            await runtime.disconnectChrome()
            XCTAssertNoThrow(try owned.binding.lifetime.check())
            let before = await owned.transport.closedTargets
            XCTAssertEqual(before, [])
            try await runtime.interrupt(taskID: "task")
            XCTAssertThrowsError(try owned.binding.lifetime.check())
            let after = await owned.transport.closedTargets
            XCTAssertEqual(after, [owned.binding.targetID])
            let borrowed = try await connector.entry(request.id)
            let counts = await borrowed.transport.counts()
            XCTAssertEqual(counts.shutdowns, 1)
            XCTAssertEqual(counts.forbidden, 0)
        }
    }

    func testInterruptCleansBorrowedInventoryAndIndependentOwnedBinding() async throws {
        let owned = try await BorrowedRuntimeOwnedFixture.make()
        try await withHarness(mode: "inventory-hold", browserBroker: owned.broker) { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold inventory beside owned binding", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            try await runtime.installOwnedBrowserBindingForFixture(taskID: "task", binding: owned.binding)
            try await runtime.interrupt(taskID: "task")
            XCTAssertThrowsError(try owned.binding.lifetime.check())
            let closed = await owned.transport.closedTargets
            XCTAssertEqual(closed, [owned.binding.targetID])
            let borrowed = try await connector.entry(request.id)
            let fresh = try await borrowed.owner.beginTurn(taskKey: "task", turnID: "after-both-cleaned")
            await borrowed.owner.revoke(turn: fresh)
            let counts = await borrowed.transport.counts()
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(counts.shutdowns, 0)
        }
    }

    func testUnknownCandidatePreservesCoexistingOwnedBindingAndSnapshot() async throws {
        let owned = try await BorrowedRuntimeOwnedFixture.make()
        try await withHarness(mode: "invalid-owned-hold", browserBroker: owned.broker) { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Reject an unobserved candidate", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            try await runtime.installOwnedBrowserBindingForFixture(taskID: "task", binding: owned.binding)
            let before = try await runtime.browserStateForFixture(taskID: "task")
            XCTAssertNotNil(before.1)
            try Data("ready".utf8).write(to: root.appendingPathComponent("try-invalid-token"))
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("invalid-token-result.json").path) }
            let after = try await runtime.browserStateForFixture(taskID: "task")
            XCTAssertEqual(before.0, after.0)
            XCTAssertEqual(before.1, after.1)
            XCTAssertNoThrow(try owned.binding.lifetime.check())
            let closed = await owned.transport.closedTargets
            XCTAssertEqual(closed, [])
            let borrowed = try await connector.entry(request.id)
            let counts = await borrowed.transport.counts()
            XCTAssertEqual(counts.attachIDs, [])
            XCTAssertEqual(counts.forbidden, 0)
            try await runtime.interrupt(taskID: "task")
        }
    }

    private final class Audit {
        var status: TaskStatus?
        var approvals = 0
        var chrome = [(UUID, ChromeConnectionState)]()
        var entries = [TimelineEntry]()
        var compactions = [RuntimeCompactionState]()
    }

    private struct OutcomeGateFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class OutcomeGateAudit {
        let taskID: String
        var status: TaskStatus?
        var entries = [TimelineEntry](), tools = [String](), unexpectedTools = [String](), denied = [String]()
        var transcript = [[String: String]](), approvedPresses = 0
        private var snapshotID: String?, tabHandle: String?, documentEpoch: String?, buttonIndex: Int?, counterIndex: Int?
        private var permitsMutation: Bool

        init(taskID: String, permitsMutation: Bool = true) {
            self.taskID = taskID
            self.permitsMutation = permitsMutation
        }

        func beginContinuationMutationTurn() {
            status = nil
            permitsMutation = true
            // Approval cannot borrow prior-turn observation capabilities even
            // if a model repeats them. A fresh second-turn read is required.
            snapshotID = nil
            tabHandle = nil
            documentEpoch = nil
            buttonIndex = nil
            counterIndex = nil
        }

        func observe(_ entry: TimelineEntry) {
            entries.append(entry)
            guard let tool = entry.toolEvent, tool.status != .running else { return }
            tools.append(tool.name)
            let object = Self.object(tool.input)
            let text = (object?["contentItems"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            transcript.append(["tool": tool.name, "status": tool.status.rawValue, "text": text])
            if !["computer_v2_status", "computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_snapshot", "computer_v2_ax", ComputerOutcomeToolContract.name].contains(tool.name) {
                unexpectedTools.append(tool.name)
            }
            guard tool.status == .succeeded, text.contains("url=\"https://example.com/inert\""),
                  let snapshot = Self.match("AXSNAPSHOT id=([0-9A-Fa-f-]+)", text) else { return }
            snapshotID = snapshot
            tabHandle = Self.match("tab_handle=([0-9A-Fa-f-]+)", text)
            documentEpoch = Self.match("document_epoch=([0-9A-Fa-f-]+)", text)
            buttonIndex = text.split(separator: "\n").compactMap { line -> Int? in
                guard line.contains("label=\"Increment\""), line.contains("actions=[\"AXPress\"]") else { return nil }
                return Self.match("^#([0-9]+)", String(line)).flatMap(Int.init)
            }.first
            counterIndex = text.split(separator: "\n").compactMap { line -> Int? in
                guard line.contains("label=\"Count\""), line.contains("value=\"0\"") else { return nil }
                return Self.match("^#([0-9]+)", String(line)).flatMap(Int.init)
            }.first
        }

        func approve(_ request: ActionApprovalRequest) -> Bool {
            func reject() -> Bool { denied.append(request.title + ": " + request.summary); return false }
            guard permitsMutation, request.kind == .computerUse, request.taskID == taskID,
                  request.summary == "AXPress on Increment", approvedPresses == 0,
                  let details = Self.object(request.details),
                  let target = details["resolved_target"] as? [String: Any],
                  let arguments = details["model_arguments"] as? [String: Any],
                  target["bundle_id"] as? String == "com.google.Chrome",
                  (target["process_id"] as? NSNumber)?.int32Value == 4242,
                  target["observed_page_url"] as? String == "https://example.com/inert",
                  let snapshotID, let tabHandle, let documentEpoch, let buttonIndex, let counterIndex,
                  target["tab_handle"] as? String == tabHandle,
                  target["document_epoch"] as? String == documentEpoch,
                  arguments["snapshot_id"] as? String == snapshotID,
                  (arguments["element_index"] as? NSNumber)?.intValue == buttonIndex,
                  arguments["ax_action"] as? String == "AXPress",
                  Set(arguments.keys) == ["snapshot_id", "element_index", "ax_action", "postcondition"],
                  let postcondition = arguments["postcondition"] as? [String: Any],
                  Set(postcondition.keys) == ["kind", "element_index", "expected"],
                  postcondition["kind"] as? String == "value",
                  (postcondition["element_index"] as? NSNumber)?.intValue == counterIndex,
                  postcondition["expected"] as? String == "1" else { return reject() }
            approvedPresses += 1
            self.snapshotID = nil
            return true
        }

        private static func object(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }

        static func match(_ pattern: String, _ text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func outcomeGatePortIsFree() async throws -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:1237/health")!)
            return false
        } catch let error as URLError where error.code == .cannotConnectToHost { return true }
    }

    private func assertOutcomeGateWire(_ url: URL, followup: Bool = false) throws {
        let trace = try AppServerWireTrace.load(url)
        XCTAssertTrue(trace.parseFailures.isEmpty, trace.parseFailures.joined(separator: "; "))
        func result(for call: AppServerWireTrace.Message) -> [String: Any]? {
            trace.messages.first {
                $0.direction == .clientToServer && $0.method == nil
                    && $0.identifier == call.identifier && $0.sequence > call.sequence
            }?.object["result"] as? [String: Any]
        }
        let calls = trace.messages.filter { $0.direction == .serverToClient && $0.method == "item/tool/call" }
        let presses = calls.filter { ($0.object["params"] as? [String: Any])?["tool"] as? String == "computer_v2_ax" }
        let successfulPresses = presses.filter { result(for: $0)?["success"] as? Bool == true }
        if followup {
            XCTAssertEqual(successfulPresses.count, 1,
                "Rejected stale-reference requests may recover, but exactly one successful press is permitted.")
        } else {
            XCTAssertEqual(presses.count, 1, "Exactly one press request must originate from the real model.")
        }
        let press = try XCTUnwrap(followup ? successfulPresses.first : presses.first)
        let pressID = try XCTUnwrap((press.object["params"] as? [String: Any])?["callId"] as? String)
        if followup {
            let starts = trace.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }
            XCTAssertEqual(starts.count, 2, "This must be two user turns in one existing task, not a scripted single-turn plan.")
            // Compaction may legitimately add maintenance-turn lifecycle
            // events. Identify user turns by their exact turn/start RPCs.
            let turnIDs = starts.compactMap { request -> String? in
                guard let response = trace.messages.first(where: {
                    $0.direction == .serverToClient && $0.method == nil
                        && $0.identifier == request.identifier && $0.sequence > request.sequence
                }), let result = response.object["result"] as? [String: Any],
                   let turn = result["turn"] as? [String: Any] else { return nil }
                return turn["id"] as? String
            }
            XCTAssertEqual(turnIDs.count, 2)
            XCTAssertEqual(Set(turnIDs).count, 2)
            guard starts.count == 2, turnIDs.count == 2 else {
                throw OutcomeGateFailure(message: "Continuation wire must contain exactly two distinct user turns.")
            }
            let secondInput = ((starts[1].object["params"] as? [String: Any])?["input"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertTrue(secondInput.contains("Now increase that counter exactly once"))
            XCTAssertFalse(secondInput.contains("https://example.com/inert"),
                "The follow-up must rely on retained target context, not a newly supplied URL.")
            let firstCalls = calls.filter { ($0.object["params"] as? [String: Any])?["turnId"] as? String == turnIDs[0] }
            XCTAssertTrue(firstCalls.contains { ($0.object["params"] as? [String: Any])?["tool"] as? String == "computer_v2_bind_tab" })
            XCTAssertFalse(firstCalls.contains { ($0.object["params"] as? [String: Any])?["tool"] as? String == "computer_v2_ax" })
            let pressParams = try XCTUnwrap(press.object["params"] as? [String: Any])
            XCTAssertEqual(pressParams["turnId"] as? String, turnIDs[1])
            let pressArguments = try XCTUnwrap(pressParams["arguments"] as? [String: Any])
            let pressSnapshot = try XCTUnwrap(pressArguments["snapshot_id"] as? String)
            func successfulSnapshotIDs(turnID: String, before sequence: Int) -> Set<String> {
                Set(calls.filter {
                    let params = $0.object["params"] as? [String: Any]
                    return params?["turnId"] as? String == turnID
                        && params?["tool"] as? String == "computer_v2_snapshot" && $0.sequence < sequence
                }.compactMap { call in
                    guard let value = result(for: call), value["success"] as? Bool == true else { return nil }
                    let text = (value["contentItems"] as? [[String: Any]] ?? [])
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    return OutcomeGateAudit.match("AXSNAPSHOT id=([0-9A-Fa-f-]+)", text)
                })
            }
            let firstSnapshots = successfulSnapshotIDs(turnID: turnIDs[0], before: press.sequence)
            let secondSnapshots = successfulSnapshotIDs(turnID: turnIDs[1], before: press.sequence)
            XCTAssertFalse(firstSnapshots.isEmpty)
            XCTAssertTrue(firstSnapshots.isDisjoint(with: secondSnapshots))
            XCTAssertFalse(firstSnapshots.contains(pressSnapshot))
            XCTAssertTrue(secondSnapshots.contains(pressSnapshot),
                "The only executed press must reference a successful fresh snapshot from the second turn.")
            let completed = trace.messages.filter { $0.direction == .serverToClient && $0.method == "turn/completed" }
            for id in turnIDs {
                XCTAssertTrue(completed.contains {
                    let turn = ($0.object["params"] as? [String: Any])?["turn"] as? [String: Any]
                    return turn?["id"] as? String == id && turn?["status"] as? String == "completed"
                })
            }
        }
        let verifications = calls.filter { ($0.object["params"] as? [String: Any])?["tool"] as? String == ComputerOutcomeToolContract.name }
        let automaticallyVerified = (result(for: press)?["contentItems"] as? [[String: Any]] ?? [])
            .contains { ($0["text"] as? String)?.contains("VERIFIED_PROPERTY operation_id=\(pressID)") == true }
        let matched = verifications.contains { call in
            guard let params = call.object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any],
                  arguments["operation_id"] as? String == pressID,
                  arguments["property"] as? String == "value", arguments["expected"] as? String == "1",
                  let response = trace.messages.first(where: {
                      $0.direction == .clientToServer && $0.method == nil
                          && $0.identifier == call.identifier && $0.sequence > call.sequence
                  }), let result = response.object["result"] as? [String: Any], result["success"] as? Bool == true,
                  let content = result["contentItems"] as? [[String: Any]] else { return false }
            return content.contains { ($0["text"] as? String)?.contains("VERIFIED_PROPERTY operation_id=\(pressID)") == true }
        }
        XCTAssertTrue(automaticallyVerified || matched,
                      "Verification must cite the dispatched operation and receive runtime confirmation of Count=1, without requiring another model call.")
    }

    private struct NoModelGrounder: VisualGroundingClient {
        func prepare() async throws { }
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw NSError(domain: "NoGrounderInBorrowedFixture", code: 1)
        }
        func shutdown() async -> [String] { [] }
    }

    private func request() -> ChromeConnectionRequest {
        ChromeConnectionRequest(
            application: .init(processIdentifier: 4242, bundleIdentifier: "com.google.Chrome",
                               executableURL: URL(fileURLWithPath: "/fixture/Google Chrome")),
            userDataDirectory: URL(fileURLWithPath: "/fixture/private-profile"),
            consent: ChromeDebuggingConsent(approvedByUser: true)
        )
    }

    private func results(_ root: URL) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results.json"))) as? [[String: Any]])
    }

    private func withHarness(
        mode: String,
        browserBroker: ChromeTabBroker = ChromeTabBroker(),
        interactionPolicy: ComputerInteractionPolicy = .backgroundOnly,
        body: (CodexAppServerRuntime, URL, Audit, BorrowedRuntimeConnector) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusBorrowedRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BorrowedChromeRuntimeAppServer.ts")
        let executable = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.executable = .fixture(path: executable.path)
        config.codexHomePath = root.path
        config.computerInteractionPolicy = interactionPolicy
        let connector = BorrowedRuntimeConnector()
        let runtime = CodexAppServerRuntime(configuration: config, browserBroker: browserBroker, visualGrounder: NoModelGrounder(),
                                           borrowedChromeConnector: { try await connector.connect($0) })
        let audit = Audit()
        let events = Task {
            for await event in runtime.events() {
                switch event {
                case .taskStatusChanged(_, let status): audit.status = status
                case .chromeConnectionChanged(let id, let state): audit.chrome.append((id, state))
                case .timelineEntryAppended(_, let entry): audit.entries.append(entry)
                case .contextCompactionChanged(_, let state): audit.compactions.append(state)
                case .approvalRequested(let request):
                    audit.approvals += 1
                    try? await runtime.resolveApproval(requestID: request.id, approved: true)
                default: break
                }
            }
        }
        do {
            _ = try await runtime.loadTasks()
            try await body(runtime, root, audit, connector)
            let report = await runtime.shutdown()
            events.cancel()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        } catch {
            _ = await runtime.shutdown()
            events.cancel()
            throw error
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Borrowed runtime fixture timed out", code: 1)
    }

    private func waitForAsync(_ condition: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Borrowed cleanup fixture timed out", code: 1)
    }
}

private struct BorrowedRuntimeOwnedFixture: Sendable {
    let broker: ChromeTabBroker
    let binding: BrowserTabBinding
    let transport: BorrowedRuntimeOwnedTransport

    static func make() async throws -> Self {
        let generation = UUID(), transport = BorrowedRuntimeOwnedTransport()
        let sessions = BrowserTabSessionBroker(transport: transport, browserGeneration: generation, ownership: .owned)
        let binding = try await sessions.open(taskKey: "task", processIdentifier: 5555,
                                             url: URL(string: "https://example.com/inert-owned")!)
        let initial = ChromeTabBroker.BrowserProcess(
            process: BorrowedRuntimeOwnedChild(), dataDirectory: URL(fileURLWithPath: "/not-created/borrowed-runtime-owned-fixture"),
            generation: generation, transport: SystemChromeDevToolsTransport(port: 1), sessions: sessions
        )
        return Self(broker: ChromeTabBroker(initialBrowser: initial, removeProfile: { _ in nil }),
                    binding: binding, transport: transport)
    }
}

private struct BorrowedRuntimeOwnedChild: BrowserOwnedChild {
    let processIdentifier: Int32 = 5555
    let isRunning = true
    func stop() async -> OwnedChildProcess.StopResult { .init(rootReaped: true, groupGone: true, issues: []) }
}

private actor BorrowedRuntimeOwnedTransport: BrowserTabTransport {
    private var target: BrowserTarget?
    private(set) var closedTargets = [String]()
    func createTarget(url: URL) -> BrowserTarget {
        let created = BrowserTarget(targetID: "owned-inert-target", instanceToken: UUID().uuidString,
                                    title: "Owned inert fixture", url: url, webSocketURL: nil)
        target = created
        return created
    }
    func target(id: String) -> BrowserTarget? { target?.targetID == id ? target : nil }
    func activateTarget(id: String) { }
    func closeTarget(target: BrowserTarget) throws {
        guard self.target == target else { throw BrowserTabBrokerError.targetReplaced }
        closedTargets.append(target.targetID)
        self.target = nil
    }
    func observe(target: BrowserTarget) -> BrowserDocumentObservation {
        .init(loaderID: "owned-loader", title: target.title, url: target.url, nodes: [])
    }
    func press(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
               permit: BrowserMutationPermit) throws { throw BrowserTabBrokerError.unsupportedAction("inert owned press") }
    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
                 permit: BrowserMutationPermit) throws { throw BrowserTabBrokerError.unsupportedAction("inert owned text") }
}

private actor BorrowedRuntimeConnectGate {
    private var arrived = false
    private(set) var cancellationRequested = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    var isPaused: Bool { arrived && pending != nil }
    func pause() async {
        arrived = true
        arrival?.resume(); arrival = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending = $0 }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
    }
    private func observeCancellation() { cancellationRequested = true }
    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}

private actor BorrowedRuntimeConnector {
    struct Entry: Sendable {
        let owner: BorrowedChromeSessionOwner
        let transport: BorrowedRuntimeTransport
    }
    private(set) var count = 0
    private var entries = [UUID: Entry]()
    private var gate: BorrowedRuntimeConnectGate?
    private var shouldFail = false
    private var candidateURL = URL(string: "https://example.com/inert")!
    private var candidateTitle = "Identical fixture tabs"
    private var textRole = "textbox"
    func setCandidateMetadata(url: URL, title: String) { candidateURL = url; candidateTitle = title }
    func setTextRole(_ role: String) { textRole = role }
    func holdNext(_ gate: BorrowedRuntimeConnectGate) { self.gate = gate }
    func failNext() { shouldFail = true }
    func connect(_ request: ChromeConnectionRequest) async throws -> BorrowedChromeSessionOwner {
        count += 1
        if shouldFail {
            shouldFail = false
            throw NSError(domain: "private-profile secret-endpoint", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ws://secret-endpoint /private-profile"])
        }
        let transport = BorrowedRuntimeTransport(consent: request.consent, url: candidateURL, candidateTitle: candidateTitle, textRole: textRole)
        let owner = try BorrowedChromeSessionOwner(application: request.application, transport: transport,
            consent: request.consent, verifyIdentity: { try request.consent.check() })
        entries[request.id] = Entry(owner: owner, transport: transport)
        let pendingGate = gate
        gate = nil
        await pendingGate?.pause()
        // Deliberately return late even if cancelled, to exercise ownership
        // cleanup of an already-created exact connection.
        return owner
    }
    func entry(_ id: UUID) throws -> Entry {
        guard let value = entries[id] else { throw NSError(domain: "Missing inert connection", code: 1) }
        return value
    }
}

private actor BorrowedRuntimeTransport: BorrowedChromeSessionTransport {
    struct Counts: Sendable {
        let attachIDs: [String]
        let detaches: Int
        let shutdowns: Int
        let presses: Int
        let forbidden: Int
        let text: String
        let postPressObservations: Int
        let observedValues: [String]
    }
    nonisolated let generation = UUID()
    private let consent: ChromeDebuggingConsent
    private var targets = [String: BrowserTarget]()
    private var attachIDs = [String]()
    private var detaches = 0, shutdowns = 0, presses = 0, forbidden = 0
    private var text = "", closed = false
    private var url: URL
    private var nextAttachURL: URL?
    private var navigatedOnAttach = false
    private let candidateTitle: String
    private let textRole: String
    private var delayedReads = 0, postPressObservations = 0
    private var wrongResult = false, unknownReply = false
    private var observedValues = [String]()
    private var firstReadGate: BorrowedRuntimeConnectGate?
    private var dispatchMarker: URL?
    init(consent: ChromeDebuggingConsent, url: URL = URL(string: "https://example.com/inert")!, candidateTitle: String = "Identical fixture tabs", textRole: String = "textbox") {
        self.consent = consent
        self.url = url
        self.candidateTitle = candidateTitle
        self.textRole = textRole
    }
    func counts() -> Counts {
        Counts(attachIDs: attachIDs, detaches: detaches, shutdowns: shutdowns,
               presses: presses, forbidden: forbidden, text: text,
               postPressObservations: postPressObservations, observedValues: observedValues)
    }
    func configureVerification(delayedReads: Int, wrongResult: Bool, unknownReply: Bool,
                               firstReadGate: BorrowedRuntimeConnectGate?, dispatchMarker: URL?) {
        self.delayedReads = delayedReads
        self.wrongResult = wrongResult
        self.unknownReply = unknownReply
        self.firstReadGate = firstReadGate
        self.dispatchMarker = dispatchMarker
    }
    func validateConnection() throws {
        try consent.check()
        if closed { throw BrowserTabBrokerError.browserGenerationChanged }
    }
    func listCandidates() throws -> [BorrowedChromeTabCandidate] {
        try validateConnection()
        return (0..<2).map { .init(targetID: "target-\($0)", title: candidateTitle, url: url) }
    }
    func navigateOnNextAttach(to url: URL) { nextAttachURL = url }
    func attach(targetID: String) throws -> BrowserTarget {
        try validateConnection()
        guard ["target-0", "target-1"].contains(targetID) else { throw BrowserTabBrokerError.targetClosed }
        if let existing = targets[targetID] { return existing }
        if let nextAttachURL {
            url = nextAttachURL
            self.nextAttachURL = nil
            navigatedOnAttach = true
        }
        let target = BrowserTarget(targetID: targetID, title: "Fixture", url: url,
            attachedSession: .init(connectionGeneration: generation, sessionID: UUID().uuidString, incarnation: UUID()))
        targets[targetID] = target
        attachIDs.append(targetID)
        return target
    }
    func target(id: String) throws -> BrowserTarget? { try validateConnection(); return targets[id] }
    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        try validateConnection()
        var renderedCount = String(presses)
        if presses > 0 {
            postPressObservations += 1
            let gate = firstReadGate
            firstReadGate = nil
            await gate?.pause()
            try validateConnection()
            if wrongResult || postPressObservations <= delayedReads { renderedCount = "0" }
            observedValues.append(renderedCount)
        }
        return BrowserDocumentObservation(loaderID: "inert-loader", title: "Fixture", url: url, nodes: [
            .init(backendNodeID: 1, role: "button", name: navigatedOnAttach ? "DIFFERENT_ORIGIN_PRIVATE_CONTENT" : "Increment", value: nil, isDisabled: false, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 2, role: textRole, name: "Text", value: text, isDisabled: false, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 3, role: "StaticText", name: "Count", value: renderedCount, isDisabled: false, isReadOnly: true, isIgnored: false),
            .init(backendNodeID: 4, role: "button", name: "Disabled button", value: nil, isDisabled: true, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 5, role: "textbox", name: "Disabled text", value: "", isDisabled: true, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 6, role: "textbox", name: "Read only text", value: "", isDisabled: false, isReadOnly: true, isIgnored: false)
        ])
    }
    func press(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
               permit: BrowserMutationPermit) throws {
        try validateConnection()
        try permit.commit { presses += 1 }
        if let dispatchMarker { try Data("yes".utf8).write(to: dispatchMarker) }
        if unknownReply {
            throw BrowserMutationFailure(dispatchState: .unknown,
                underlyingError: NSError(domain: "Inert lost mutation response", code: 1))
        }
    }
    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
                 permit: BrowserMutationPermit) throws {
        try validateConnection()
        try permit.commit { self.text = text }
    }
    func detach(target: BrowserTarget) throws {
        try validateConnection()
        guard targets[target.targetID]?.attachedSession == target.attachedSession else { throw BrowserTabBrokerError.targetReplaced }
        targets.removeValue(forKey: target.targetID)
        detaches += 1
    }
    func shutdown() { closed = true; shutdowns += 1; targets.removeAll() }
    func createTarget(url: URL) throws -> BrowserTarget { forbidden += 1; throw BrowserTabBrokerError.ownershipMismatch }
    func activateTarget(id: String) throws { forbidden += 1; throw BrowserTabBrokerError.ownershipMismatch }
    func closeTarget(target: BrowserTarget) throws { forbidden += 1; throw BrowserTabBrokerError.ownershipMismatch }
}

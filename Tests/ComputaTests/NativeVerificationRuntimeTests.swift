@testable import AutomationCore
import Foundation
import XCTest
@testable import Computa

/// The real runtime and native act/observe/verify path over a deterministic
/// JSON-RPC model fixture and target-scoped AX backend. No desktop is touched.
@MainActor
final class NativeVerificationRuntimeTests: XCTestCase {
    private let taskID = "native-verification-task"
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"

    func testSelectionIsVerifiedByRuntimeWithoutModelVerifyOrSecondInput() async throws {
        try await checkSelection(mode: "selection", expectedReads: 1)
    }

    func testDelayedRenderSpendsThreeReadsButDispatchesOnlyOnce() async throws {
        try await checkSelection(mode: "delayed", expectedReads: 3) { $0.delayedReads = 2 }
    }

    func testFullRetainedEvidenceVerifiesWhenCompactPresentationOmitsTarget() async throws {
        try await checkSelection(mode: "compact", expectedReads: 1) { $0.omitTargetAfterInput = true }
    }

    func testStableNativeObjectIdentitySurvivesPostActionIndexReordering() async throws {
        try await checkSelection(mode: "reordered", expectedReads: 1) { $0.reorderAfterInput = true }
    }

    func testUnknownDispatchAcknowledgementIsReconciledWithoutRepeatingInput() async throws {
        try await checkSelection(mode: "unknown", expectedReads: 1) { $0.loseAcknowledgement = true }
    }

    func testSeparateDetailPaneMustRenderObservedTargetIdentity() async throws {
        try await checkSelection(mode: "detail", expectedReads: 1)
    }

    func testUnplannedNativePressWithoutSelectionMetadataStopsBeforeApprovalOrDispatch() async throws {
        try await withHarness(mode: "no-plan") { runtime, root, audit, backend, background in
            backend.exposesSelection = false
            try await self.start(runtime, root: root, background: background)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.last?["success"] as? Bool, false)
            XCTAssertEqual(backend.actions, 0)
            XCTAssertEqual(backend.postInputReads, 0)
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertTrue(audit.assistant.isEmpty)
            let text = rows.last?["text"] as? String ?? ""
            XCTAssertTrue(text.contains("postcondition"))
            XCTAssertTrue(text.contains("dispatch=not_dispatched"))
        }
    }

    func testAlreadySelectedTargetNeedsNoApprovalOrInput() async throws {
        try await withHarness(mode: "already-selected") { runtime, root, audit, backend, background in
            backend.initiallySelected = true
            try await self.start(runtime, root: root, background: background)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, ["computer_v2_snapshot", "computer_v2_ax"])
            XCTAssertEqual(backend.actions, 0)
            XCTAssertEqual(backend.postInputReads, 0)
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertEqual(rows.last?["success"] as? Bool, true)
            XCTAssertTrue((rows.last?["text"] as? String ?? "").contains("ALREADY_SATISFIED"))
            XCTAssertEqual(audit.status, .completed)
            XCTAssertTrue(audit.assistant.contains("NATIVE_VERIFICATION_COMPLETE"))
        }
    }

    func testRepeatedSelectedTargetDoesNotDispatchAgainAfterFreshSnapshot() async throws {
        try await withHarness(mode: "duplicate") { runtime, root, audit, backend, background in
            try await self.start(runtime, root: root, background: background)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, [
                "computer_v2_snapshot", "computer_v2_ax", "computer_v2_snapshot", "computer_v2_ax",
            ])
            XCTAssertEqual(backend.actions, 1, "A new snapshot does not authorize replay of an already-satisfied selection.")
            XCTAssertEqual(audit.approvals, 1)
            XCTAssertTrue((rows[1]["text"] as? String ?? "").contains("VERIFIED_PROPERTY"))
            XCTAssertTrue((rows[3]["text"] as? String ?? "").contains("ALREADY_SATISFIED"))
            XCTAssertEqual(audit.status, .completed)
        }
    }

    func testSetValueUsesExactAutomaticPlanAndOneDispatch() async throws {
        try await withHarness(mode: "value") { runtime, root, audit, backend, background in
            try await self.start(runtime, root: root, background: background)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, ["computer_v2_snapshot", "computer_v2_set_text"])
            XCTAssertEqual(backend.actions, 0)
            XCTAssertEqual(backend.values, ["verified fixture value"])
            XCTAssertEqual(backend.postInputReads, 1)
            XCTAssertEqual(audit.approvals, 1)
            XCTAssertTrue((rows.last?["text"] as? String ?? "").contains("VERIFIED_PROPERTY operation_id=native-call-1"))
            XCTAssertEqual(audit.status, .completed)
        }
    }

    func testWrongPostActionStateExhaustsReadBudgetAndSuppressesClaimedSuccess() async throws {
        try await withHarness(mode: "wrong-result") { runtime, root, audit, backend, background in
            backend.neverSatisfy = true
            try await self.start(runtime, root: root, background: background)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(backend.actions, 1)
            XCTAssertEqual(backend.postInputReads, 3)
            XCTAssertEqual(backend.observedSelections, [false, false, false])
            XCTAssertEqual(audit.approvals, 1)
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertTrue(audit.assistant.isEmpty)
            let text = try self.results(root).last?["text"] as? String ?? ""
            XCTAssertTrue(text.contains("VERIFICATION_PENDING"))
            XCTAssertFalse(text.contains("VERIFIED_PROPERTY"))
            XCTAssertEqual(audit.entries.filter { $0.title == "Outcome not verified" }.count, 1)
            XCTAssertFalse(audit.entries.contains { $0.body.contains("NATIVE_FALSE_SUCCESS_MUST_NOT_APPEAR") })
        }
    }

    func testExhaustedVerificationBlocksDuplicateButStillAllowsReadOnlyInspection() async throws {
        try await withHarness(mode: "pending-duplicate") { runtime, root, audit, backend, background in
            backend.neverSatisfy = true
            try await self.start(runtime, root: root, background: background)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, [
                "computer_v2_snapshot", "computer_v2_ax", "computer_v2_snapshot", "computer_v2_ax", "computer_v2_snapshot",
            ])
            XCTAssertEqual(backend.actions, 1, "A fresh observation cannot authorize a duplicate of the unverified action.")
            XCTAssertEqual(backend.postInputReads, 5, "Three runtime verification reads plus two explicit inspections; no refreshed verification budget.")
            XCTAssertEqual(audit.approvals, 1)
            XCTAssertEqual(rows[2]["success"] as? Bool, true)
            XCTAssertEqual(rows[3]["success"] as? Bool, false)
            XCTAssertEqual(rows[4]["success"] as? Bool, true, "Read-only inspection remains available after blocked input.")
            let firstText = rows[1]["text"] as? String ?? ""
            XCTAssertTrue(firstText.contains("verification_reads=3/3"))
            let duplicateText = rows[3]["text"] as? String ?? ""
            XCTAssertTrue(duplicateText.contains("1 operation(s) remain unresolved."))
            XCTAssertTrue(duplicateText.contains("1 subsequent input request(s) were blocked before dispatch"))
            XCTAssertTrue(duplicateText.contains("pending_operation=native-call-1"))
            XCTAssertTrue(duplicateText.contains("operation=native-call-3 tool=computer_v2_ax dispatch=not_dispatched status=blocked_by_pending_action"))
            let pendingLines = duplicateText.components(separatedBy: "\n").filter {
                $0.hasPrefix("operation=") && ($0.contains(" status=unverified") || $0.contains(" status=failed"))
            }
            XCTAssertEqual(pendingLines.count, 1, "One action outcome is unknown; the blocked duplicate is separate pre-dispatch audit evidence.")
            XCTAssertTrue(pendingLines.first?.contains("operation=native-call-1") == true)
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertTrue(audit.assistant.isEmpty)
            XCTAssertEqual(audit.entries.filter { $0.title == "Outcome not verified" }.count, 1)
        }
    }

    func testNativeReadCannotCertifyLatestIncomingMessageFromUnstructuredAXText() async throws {
        try await withHarness(mode: "latest-incoming") { runtime, root, audit, backend, background in
            try await self.start(runtime, root: root, background: background,
                                 prompt: "Read the latest incoming message from the coordinator.")
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(try self.results(root).count, 1)
            XCTAssertEqual(backend.actions, 0)
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertTrue(audit.assistant.isEmpty)
            XCTAssertTrue(audit.entries.contains { $0.title == "Outcome not verified" && $0.body.contains("latest incoming message") })
            XCTAssertFalse(audit.entries.contains { $0.body.contains("UNSUPPORTED_LATEST_INCOMING_MUST_NOT_APPEAR") })
        }
    }

    func testGenericNativeReadIsNotIncorrectlyGatedAsLatestIncoming() async throws {
        try await withHarness(mode: "general-read") { runtime, root, audit, backend, background in
            try await self.start(runtime, root: root, background: background, prompt: "Read the selected row.")
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(try self.results(root).count, 1)
            XCTAssertEqual(backend.actions, 0)
            XCTAssertEqual(audit.status, .completed)
            XCTAssertEqual(audit.assistant, ["NATIVE_READ_COMPLETE"])
        }
    }

    func testCancellationBeforeVerificationReadBlocksLateProofAndKeepsChatUsable() async throws {
        let gate = NativeVerificationReadGate()
        try await withHarness(mode: "cancel", gate: gate) { runtime, root, audit, backend, background in
            try await self.start(runtime, root: root, background: background)
            do { try await self.waitForAsync { await gate.isPaused } }
            catch { await gate.release(); throw error }
            XCTAssertEqual(backend.actions, 1)
            XCTAssertEqual(backend.postInputReads, 0)
            XCTAssertEqual(try self.results(root).count, 1)
            let interrupt = Task { try await runtime.interrupt(taskID: self.taskID) }
            do { try await self.waitForAsync { await gate.cancellationRequested } }
            catch { await gate.release(); _ = try? await interrupt.value; throw error }
            await gate.release()
            try await interrupt.value
            try await self.waitFor { audit.status == .waiting }
            XCTAssertEqual(backend.actions, 1)
            XCTAssertEqual(backend.postInputReads, 0, "A revoked turn must not even begin the suspended observation.")
            XCTAssertEqual(try self.results(root).count, 1, "No late tool success is returned after cancellation.")
            XCTAssertEqual(audit.approvals, 1)
            XCTAssertTrue(audit.assistant.isEmpty)
            XCTAssertTrue(audit.deltas.isEmpty)
            XCTAssertFalse(audit.entries.contains { $0.toolEvent?.name == "computer_v2_ax" && $0.toolEvent?.status == .succeeded })
            XCTAssertThrowsError(try background.lifetime.check())
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupted").path))

            audit.status = nil
            try await runtime.submit(prompt: "Reply briefly without tools.", toTaskID: self.taskID, modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            XCTAssertEqual(audit.assistant, ["NEXT_TURN_OK"])
            XCTAssertFalse(audit.entries.contains { $0.body.contains("CANCELLED_NATIVE_FALSE_SUCCESS") })
            XCTAssertEqual(backend.actions, 1)
            XCTAssertEqual(backend.postInputReads, 0)
        }
    }

    private func checkSelection(mode: String, expectedReads: Int,
                                configure: (Backend) -> Void = { _ in }) async throws {
        try await withHarness(mode: mode) { runtime, root, audit, backend, background in
            configure(backend)
            try await self.start(runtime, root: root, background: background)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            let rows = try self.results(root)
            XCTAssertEqual(rows.map { $0["tool"] as? String }, ["computer_v2_snapshot", "computer_v2_ax"],
                           "The model neither rereads nor verifies: the production runtime owns the bounded recovery.")
            XCTAssertEqual(backend.actions, 1)
            XCTAssertEqual(backend.values, [])
            XCTAssertEqual(backend.postInputReads, expectedReads)
            XCTAssertEqual(backend.observedSelections.last, true)
            XCTAssertEqual(audit.approvals, 1)
            let text = rows.last?["text"] as? String ?? ""
            XCTAssertEqual(rows.last?["success"] as? Bool, true)
            XCTAssertTrue(text.contains("VERIFIED_PROPERTY operation_id=native-call-1"))
            XCTAssertTrue(text.contains("No unresolved action receipts."))
            XCTAssertEqual(audit.status, .completed)
            XCTAssertEqual(audit.assistant, ["NATIVE_VERIFICATION_COMPLETE"])
            XCTAssertFalse(audit.entries.contains { $0.title == "Outcome not verified" })
            if mode == "compact" {
                XCTAssertFalse(text.contains("#1 role="),
                               "The production compact verification response must actually omit the selected row.")
                XCTAssertTrue(text.contains("output_truncated=1"),
                              "Verification must use complete bounded source rather than claiming the compact page is complete.")
            }
            if mode == "reordered" {
                XCTAssertEqual(backend.lastRowIndex, 7, "The proven target must have moved from the baseline index.")
            }
        }
    }

    private func start(_ runtime: CodexAppServerRuntime, root: URL, background: NativeBackgroundAccessibility,
                       prompt: String = "Select the observed fixture conversation exactly once and verify its selection.") async throws {
        try await runtime.submit(prompt: prompt, toTaskID: taskID, modelID: modelID)
        try await waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) }
        try await runtime.installNativeBackgroundBindingForFixture(taskID: taskID,
            application: .init(processIdentifier: 123, bundleIdentifier: "com.example.native-verification", localizedName: "Fixture"),
            background: background)
        try Data("yes".utf8).write(to: root.appendingPathComponent("continue"))
    }

    private final class Backend: NativeBackgroundAccessibilityBackend {
        private enum Failure: Error { case invalidCapability }
        let windowIdentity = UUID(), rowIdentity = UUID(), fieldIdentity = UUID(), detailIdentity = UUID(), headingIdentity = UUID()
        let fillerIdentities = (0..<180).map { _ in UUID() }
        var initiallySelected = false, neverSatisfy = false, omitTargetAfterInput = false, reorderAfterInput = false
        var loseAcknowledgement = false, exposesSelection = true
        var delayedReads = 0
        private(set) var actions = 0, postInputReads = 0
        private(set) var values = [String](), observedSelections = [Bool]()
        private(set) var lastPresentedText: String?, lastRowIndex = 1
        private var capabilityValid = false
        var hasInput: Bool { actions > 0 || !values.isEmpty }

        func isStillSelected() throws -> Bool { true }
        func snapshot(limits: AccessibilityTreeLimits) throws -> AccessibilityTreeSnapshot {
            if hasInput { postInputReads += 1 }
            let selected = initiallySelected || (actions > 0 && !neverSatisfy && postInputReads > delayedReads)
            if hasInput { observedSelections.append(selected) }
            let row = hasInput && reorderAfterInput ? 7 : 1
            let field = hasInput && reorderAfterInput ? 8 : 2
            let detail = hasInput && reorderAfterInput ? 9 : 3
            let heading = hasInput && reorderAfterInput ? 10 : 4
            let fillers = hasInput && omitTargetAfterInput ? fillerIdentities.enumerated().map { offset, identity in
                // Matching buttons outrank a plain selected row in the actual
                // production formatter; all nodes still fit the host cap.
                element(index: 100 + offset, role: "AXButton", title: "Fixture conversation action \(offset)", identity: identity)
            } : []
            lastRowIndex = row
            capabilityValid = true
            return AccessibilityTreeSnapshot(id: UUID(),
                application: .init(processIdentifier: 123, bundleIdentifier: "com.example.native-verification", applicationName: "Fixture"),
                limits: limits, rootIndex: 0, elements: [
                    element(index: 0, role: "AXWindow", title: "Fixture window", children: [row, field, detail] + fillers.map(\.index), identity: windowIdentity),
                    element(index: row, role: "AXRow", title: "Fixture conversation", selected: exposesSelection ? selected : nil, identity: rowIdentity),
                    element(index: field, role: "AXTextField", title: "Fixture input", value: values.last ?? "", identity: fieldIdentity),
                    element(index: detail, role: "AXGroup", title: "Conversation detail", children: [heading], identity: detailIdentity),
                    element(index: heading, role: "AXStaticText", title: selected ? "Fixture conversation" : "Earlier conversation",
                            parent: detail, identity: headingIdentity),
                ] + fillers, wasTruncated: false)
        }
        private func element(index: Int, role: String, title: String, children: [Int] = [],
                             value: String? = nil, selected: Bool? = nil, parent: Int = 0, identity: UUID) -> AccessibilityTreeElement {
            AccessibilityTreeElement(index: index, parentIndex: index == 0 ? nil : parent, childIndices: children,
                depth: index == 0 ? 0 : parent == 0 ? 1 : 2, role: role, subrole: nil, title: title,
                elementDescription: nil, help: nil, identifier: nil, domIdentifier: nil, value: value,
                frame: nil, isEnabled: true, isFocused: false, supportedActions: role == "AXRow" ? ["AXPress"] : [],
                isValueSettable: role == "AXTextField", isSelected: selected, evidenceIdentity: identity)
        }
        func semanticRead(_ request: SemanticReadRequest, outputCharacterLimit: Int) throws -> AccessibilitySemanticReadResult {
            let captured = try snapshot(limits: .agentDefault)
            let exposed: Set<Int>? = hasInput && omitTargetAfterInput ? [0, 2] : nil
            let observation = AccessibilitySnapshotTextFormatter(elementLimit: 240, outputCharacterLimit: outputCharacterLimit,
                usesCompactElementLines: true, includedElementIndices: exposed, allowsRaise: false).formatObservation(captured)
            lastPresentedText = observation.text
            return AccessibilitySemanticReadResult(snapshot: captured, observation: observation)
        }
        func invalidateObservation() { capabilityValid = false }
        func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot,
                     beforeDispatch: () throws -> Void) throws {
            guard capabilityValid, snapshot.element(at: index)?.evidenceIdentity == rowIdentity, action == .press else {
                throw Failure.invalidCapability
            }
            try beforeDispatch()
            actions += 1
            if loseAcknowledgement { throw Failure.invalidCapability }
        }
        func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot,
                      beforeDispatch: () throws -> Void) throws {
            guard capabilityValid, snapshot.element(at: index)?.evidenceIdentity == fieldIdentity else { throw Failure.invalidCapability }
            try beforeDispatch()
            values.append(text)
        }
    }

    private final class Audit {
        var status: TaskStatus?
        var entries = [TimelineEntry](), deltas = [String]()
        var approvals = 0
        var assistant: [String] { entries.filter { $0.kind == .assistant }.map(\.body) }
    }
    private struct NoModelGrounder: VisualGroundingClient {
        func prepare() async throws {}
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw NSError(domain: "NoGroundingInNativeVerificationFixture", code: 1)
        }
        func shutdown() async -> [String] { [] }
    }
    private func withHarness(mode: String, gate: NativeVerificationReadGate? = nil,
                             body: (CodexAppServerRuntime, URL, Audit, Backend, NativeBackgroundAccessibility) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaNativeVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NativeVerificationAppServer.ts")
        let executable = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.executable = .fixture(path: executable.path)
        config.codexHomePath = root.path
        config.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
        config.computerInteractionPolicy = .backgroundOnly
        if let gate { config.fixtureBeforeNativeVerificationRead = { await gate.pauseOnce() } }
        let runtime = CodexAppServerRuntime(configuration: config, visualGrounder: NoModelGrounder())
        let backend = Backend()
        let background = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { 999 })
        let audit = Audit()
        let events = Task {
            for await event in runtime.events() {
                switch event {
                case .taskStatusChanged(_, let value): audit.status = value
                case .timelineEntryAppended(_, let entry): audit.entries.append(entry)
                case .assistantMessageDelta(_, _, let delta): audit.deltas.append(delta)
                case .approvalRequested(let request):
                    audit.approvals += 1
                    try? await runtime.resolveApproval(requestID: request.id, approved: true)
                default: break
                }
            }
        }
        do {
            _ = try await runtime.loadTasks()
            try await body(runtime, root, audit, backend, background)
            let report = await runtime.shutdown()
            events.cancel()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        } catch {
            await gate?.release()
            _ = await runtime.shutdown()
            events.cancel()
            throw error
        }
    }
    private func results(_ root: URL) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results.json"))) as? [[String: Any]])
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Native verification fixture timed out", code: 1)
    }
    private func waitForAsync(_ condition: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Native verification gate timed out", code: 1)
    }
}

private actor NativeVerificationReadGate {
    private var arrived = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var cancellationRequested = false
    var isPaused: Bool { arrived && pending != nil }
    func pauseOnce() async {
        guard !arrived else { return }
        arrived = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending = $0 }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
    }
    private func observeCancellation() { cancellationRequested = true }
    func release() { pending?.resume(); pending = nil }
}

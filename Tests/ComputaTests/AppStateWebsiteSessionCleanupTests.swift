import Foundation
import XCTest
@testable import Computa

@MainActor
final class AppStateWebsiteSessionCleanupTests: XCTestCase {
    private let taskID = "f485de43-a7d2-4b60-aef1-c9146c5e41e5"
    private let otherID = "7345336e-01a9-4fe5-995f-535e2af91684"

    func testClaimBlocksDuplicatesAndDeliveryKeepsFailureAndQueuePaused() async throws {
        let runtime = CleanupUIRuntime()
        let state = fixture(runtime: runtime)
        state.queuedPrompts[taskID] = [QueuedPrompt(text: "Unsent follow-up")]
        state.pausedQueueTaskIDs.insert(taskID)
        XCTAssertTrue(state.canRetryWebsiteSessionCleanup(taskID: taskID))
        XCTAssertTrue(WebUISnapshot(state: state).tasks[0].websiteSessionCleanupAvailable)
        XCTAssertTrue(state.requestWebsiteSessionCleanup(taskID: taskID))
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        XCTAssertTrue(state.isBusy(taskID: taskID))
        XCTAssertFalse(state.canChangeModel(for: taskID))
        let during = WebUISnapshot(state: state).tasks[0]
        XCTAssertTrue(during.websiteSessionCleanupInProgress)
        XCTAssertFalse(during.websiteSessionCleanupAvailable)
        let delivered = await state.submit(prompt: "Must not be delivered", toTaskID: taskID)
        XCTAssertFalse(delivered)
        try await wait { await runtime.calls.count == 1 }
        state.selectTask(otherID)
        let receipt = WebsiteSessionCleanupReceipt(taskID: taskID, runtimeGeneration: UUID(), outcome: .noOwnedSession,
            reason: .noOwnedSession, trigger: .manual, receiptSaved: true)
        await runtime.finish(receipt)
        try await wait { !state.websiteSessionCleanupTaskIDs.contains(self.taskID) }
        let calls = await runtime.calls
        let submissions = await runtime.submissions
        XCTAssertEqual(calls, [taskID])
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(state.tasks[0].status, .waiting)
        XCTAssertEqual(state.queuedPrompts[taskID]?.map(\.text), ["Unsent follow-up"])
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        XCTAssertEqual(state.tasks[0].entries.filter { $0.title == "Agent error" }.count, 1)
        let cleanup = try XCTUnwrap(state.tasks[0].entries.last)
        XCTAssertEqual(cleanup.title, "Website session cleanup")
        XCTAssertTrue(cleanup.body.contains("does not confirm whether an earlier website conversation was deleted"))
        XCTAssertTrue(cleanup.body.contains("No prompt was sent"))
        XCTAssertEqual(state.tasks[1].entries.count, 2)
        XCTAssertEqual(state.selectedTaskID, otherID)
        let final = WebUISnapshot(state: state).tasks[0]
        XCTAssertEqual(final.websiteSessionCleanupOutcome, "no_owned_session")
        XCTAssertEqual(final.websiteSessionCleanupReceiptSaved, true)
        XCTAssertFalse(final.websiteSessionCleanupAvailable)
        XCTAssertFalse(final.websiteSessionCleanupInProgress)
    }

    func testEligibilityRejectsActiveOrUnrelatedTasksBeforeAnyRuntimeCall() async {
        let runtime = CleanupUIRuntime()
        let state = fixture(runtime: runtime)
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: "missing"))
        for status in [TaskStatus.running, .completed, .draft] {
            state.tasks[0].status = status
            XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        }
        state.tasks[0].status = .waiting
        state.activeTurnTaskIDs.insert(taskID)
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        state.activeTurnTaskIDs.remove(taskID)
        state.compactionStateByTask[taskID] = .running
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        state.compactionStateByTask.removeValue(forKey: taskID)
        state.pendingApprovals = [.init(id: "approval", taskID: otherID, kind: .computerUse,
            title: "Approval", summary: "", details: "")]
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        state.pendingApprovals = []
        state.resolvingApprovalIDs.insert("approval")
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        state.resolvingApprovalIDs = []
        var queued = QueuedPrompt(text: "Already delivering")
        queued.status = .sending
        state.queuedPrompts[taskID] = [queued]
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        state.queuedPrompts[taskID] = []
        state.connectionState = .disconnected
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        state.connectionState = .connected(provider: runtime.providerName)
        state.tasks[0].model = "local/model"
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        state.tasks[0].model = "browser/claude"
        state.tasks[0].entries.append(.init(kind: .user, title: "You", body: "A later user message"))
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        let calls = await runtime.calls
        XCTAssertTrue(calls.isEmpty)
        let noRuntime = fixture()
        XCTAssertFalse(noRuntime.requestWebsiteSessionCleanup(taskID: taskID))
    }

    func testOriginalUnconfirmedReceiptSurvivesCurrentSelectorChangeWithoutRetargeting() async throws {
        let runtime = CleanupUIRuntime()
        let state = fixture(runtime: runtime)
        let original = WebsiteSessionCleanupReceipt(taskID: taskID, runtimeGeneration: UUID(), outcome: .unconfirmed,
            provider: .claude, route: .embedded, modelID: "browser/claude", reason: .cleanupUnverified,
            trigger: .automatic, receiptSaved: true)
        state.apply(.websiteSessionCleanupUpdated(original))
        state.tasks[0].model = "local/model"
        XCTAssertTrue(state.canRetryWebsiteSessionCleanup(taskID: taskID))
        XCTAssertEqual(WebUISnapshot(state: state).tasks[0].websiteSessionCleanupOutcome, "unconfirmed")
        XCTAssertTrue(state.requestWebsiteSessionCleanup(taskID: taskID))
        try await wait { await runtime.calls.count == 1 }
        let closed = WebsiteSessionCleanupReceipt(taskID: taskID, runtimeGeneration: UUID(), outcome: .closed,
            provider: .claude, route: .embedded, modelID: "browser/claude", reason: .deleted,
            trigger: .manual, receiptSaved: false)
        await runtime.finish(closed)
        try await wait { !state.websiteSessionCleanupTaskIDs.contains(self.taskID) }
        XCTAssertEqual(state.tasks[0].model, "local/model")
        XCTAssertEqual(state.tasks[0].status, .waiting)
        XCTAssertEqual(state.websiteSessionCleanupReceipts[taskID]?.provider, .claude)
        XCTAssertTrue(state.tasks[0].entries.last?.body.contains("owned website session is closed") == true)
        XCTAssertTrue(state.tasks[0].entries.last?.body.contains("receipt could not be saved locally") == true)
        XCTAssertFalse(state.canRetryWebsiteSessionCleanup(taskID: taskID))
        let submissions = await runtime.submissions
        XCTAssertTrue(submissions.isEmpty)
    }

    func testStaleMalformedAndUnknownReceiptsCannotAuthorizeRecoveryForANewTurn() throws {
        let state = fixture(runtime: CleanupUIRuntime())
        let receipt = WebsiteSessionCleanupReceipt(taskID: taskID, runtimeGeneration: UUID(), outcome: .unconfirmed,
            provider: .claude, route: .embedded, modelID: "browser/claude", reason: .cleanupUnverified,
            trigger: .automatic, receiptSaved: true)
        state.apply(.websiteSessionCleanupUpdated(receipt))
        state.tasks[0].entries.append(.init(kind: .user, title: "You", body: "New turn", timestamp: .now.addingTimeInterval(1)))
        state.tasks[0].model = "local/model"
        XCTAssertNil(state.currentWebsiteSessionCleanupReceipt(taskID: taskID))
        XCTAssertNil(WebUISnapshot(state: state).tasks[0].websiteSessionCleanupOutcome)
        XCTAssertFalse(state.canRetryWebsiteSessionCleanup(taskID: taskID))
        state.apply(.websiteSessionCleanupUpdated(.init(taskID: UUID().uuidString, runtimeGeneration: UUID(),
            outcome: .unconfirmed, reason: .cleanupUnverified, trigger: .automatic)))
        XCTAssertEqual(state.websiteSessionCleanupReceipts.count, 1)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        raw["modelID"] = "browser/gemini"
        let invalid = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self,
            from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertFalse(invalid.isValid)
        state.apply(.websiteSessionCleanupUpdated(invalid))
        XCTAssertEqual(state.websiteSessionCleanupReceipts[taskID], receipt)
        state.replaceTasks(with: state.tasks.filter { $0.id == otherID })
        XCTAssertTrue(state.websiteSessionCleanupReceipts.isEmpty)
    }

    func testReloadedThreadProjectsOriginalReceiptWithoutRecreatingOldTaskOwnership() async throws {
        let runtime = CleanupUIRuntime()
        let state = fixture(runtime: runtime)
        let receipt = WebsiteSessionCleanupReceipt(taskID: taskID, runtimeGeneration: UUID(), outcome: .unconfirmed,
            provider: .claude, route: .embedded, modelID: "browser/claude", reason: .cleanupUnverified,
            trigger: .automatic, receiptSaved: true)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        raw["threadID"] = otherID
        raw["turnID"] = UUID().uuidString.lowercased()
        let persisted = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self,
            from: JSONSerialization.data(withJSONObject: raw))
        // Receipt events can precede a reload snapshot. Retain and reproject
        // that observation when the UI switches to the persisted thread UUID.
        state.apply(.websiteSessionCleanupUpdated(persisted))
        XCTAssertEqual(state.websiteSessionCleanupReceipts[taskID], persisted)
        state.replaceTasks(with: [state.tasks[1]])
        state.tasks[0].model = "local/model"
        state.apply(.websiteSessionCleanupUpdated(persisted))
        XCTAssertEqual(state.websiteSessionCleanupReceipts[otherID]?.taskID, taskID)
        XCTAssertTrue(state.canRetryWebsiteSessionCleanup(taskID: otherID))
        XCTAssertFalse(state.requestWebsiteSessionCleanup(taskID: taskID))
        XCTAssertTrue(state.requestWebsiteSessionCleanup(taskID: otherID))
        try await wait { await runtime.calls.count == 1 }
        let calls = await runtime.calls
        XCTAssertEqual(calls, [otherID])
        await runtime.finish(.init(taskID: otherID, runtimeGeneration: UUID(), outcome: .noOwnedSession,
            reason: .noOwnedSession, trigger: .manual, receiptSaved: true))
        try await wait { !state.websiteSessionCleanupTaskIDs.contains(self.otherID) }
        XCTAssertEqual(state.websiteSessionCleanupReceipts[otherID]?.taskID, otherID)
        XCTAssertTrue(state.tasks[0].entries.last?.body.contains("currently has no owned website session") == true)
        let submissions = await runtime.submissions
        XCTAssertTrue(submissions.isEmpty)
    }

    func testReceiptReplayOrderCannotReplaceNewerThreadObservationWithOlderOwnerObservation() throws {
        let state = fixture(runtime: CleanupUIRuntime())
        state.replaceTasks(with: [state.tasks[1]])
        state.tasks[0].model = "local/model"
        let old = WebsiteSessionCleanupReceipt(taskID: taskID, runtimeGeneration: UUID(), outcome: .unconfirmed,
            provider: .claude, route: .embedded, modelID: "browser/claude", reason: .cleanupUnverified,
            trigger: .automatic, receiptSaved: true)
        let new = WebsiteSessionCleanupReceipt(taskID: otherID, runtimeGeneration: UUID(), outcome: .noOwnedSession,
            reason: .noOwnedSession, trigger: .manual, receiptSaved: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldTime = formatter.string(from: .now.addingTimeInterval(-1))
        let newTime = formatter.string(from: .now)
        func changed(_ receipt: WebsiteSessionCleanupReceipt, timestamp: String, threadID: String? = nil) throws -> WebsiteSessionCleanupReceipt {
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            raw["timestamp"] = timestamp
            if let threadID { raw["threadID"] = threadID }
            return try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        let older = try changed(old, timestamp: oldTime, threadID: otherID)
        let newer = try changed(new, timestamp: newTime)
        state.apply(.websiteSessionCleanupUpdated(newer))
        state.apply(.websiteSessionCleanupUpdated(older))
        XCTAssertEqual(state.websiteSessionCleanupReceipts[otherID], newer)
        XCTAssertFalse(state.canRetryWebsiteSessionCleanup(taskID: otherID))
        let equalTime = try changed(old, timestamp: newTime, threadID: otherID)
        state.apply(.websiteSessionCleanupUpdated(equalTime))
        XCTAssertEqual(state.websiteSessionCleanupReceipts[otherID], newer)
    }

    private func fixture(runtime: (any AgentRuntimeClient)? = nil) -> AppState {
        let tasks = [taskID, otherID].map { id in
            AgentTask(id: id, title: "Failed website task", summary: "", status: .waiting, workspace: "/tmp", model: "browser/claude",
                entries: [.init(kind: .user, title: "You", body: "Synthetic task", timestamp: .now.addingTimeInterval(-5)),
                          .init(kind: .system, title: "Agent error", body: "Malformed envelope")])
        }
        let state = AppState(tasks: tasks, runtime: runtime, preferences: isolatedTestPreferences())
        state.connectionState = .connected(provider: "Cleanup UI test")
        return state
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Cleanup UI operation did not settle")
    }
}

private actor CleanupUIRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Cleanup UI test"
    private(set) var calls: [String] = []
    private(set) var submissions: [String] = []
    private var reply: CheckedContinuation<WebsiteSessionCleanupReceipt, Never>?
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func loadTasks() async throws -> [AgentTask] { [] }
    func submit(prompt: String, toTaskID taskID: String, modelID: String) async throws { submissions.append(prompt) }
    func interrupt(taskID: String) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
    func retryWebsiteSessionCleanup(taskID: String) async -> WebsiteSessionCleanupReceipt {
        calls.append(taskID)
        return await withCheckedContinuation { reply = $0 }
    }
    func finish(_ receipt: WebsiteSessionCleanupReceipt) {
        reply?.resume(returning: receipt)
        reply = nil
    }
}

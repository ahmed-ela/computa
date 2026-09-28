import Foundation
import XCTest
@testable import Computa

@MainActor
final class AppStateApprovalResolutionTests: XCTestCase {
    func testMissingRuntimeAndMissingExactRequestAreObservableNoOps() async {
        let request = makeRequest()
        let local = AppState(tasks: [], runtime: nil, preferences: isolatedTestPreferences())
        local.pendingApprovals = [request]
        let noRuntime = await local.resolveApproval(request, approved: true, settlePresentation: {})
        XCTAssertEqual(noRuntime.status, .notAttempted)
        XCTAssertEqual(noRuntime.reason, "runtime_missing")
        XCTAssertEqual(local.pendingApprovals, [request])
        XCTAssertNil(noRuntime.approved)

        let runtime = ApprovalResolutionRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let missing = await state.resolveApproval(request, approved: true, settlePresentation: {})
        XCTAssertEqual(missing.status, .notAttempted)
        XCTAssertEqual(missing.reason, "exact_request_not_pending")
        let calls = await runtime.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testSuccessfulAcceptAndDeclineReturnTheDeliveredDecision() async throws {
        for approved in [true, false] {
            let runtime = ApprovalResolutionRuntime()
            let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
            let request = makeRequest()
            state.pendingApprovals = [request]
            let result = await state.resolveApproval(request, approved: approved, settlePresentation: {})
            XCTAssertTrue(result.delivered)
            XCTAssertEqual(result.approved, approved)
            XCTAssertEqual(result.requestID, request.id)
            XCTAssertLessThanOrEqual(try XCTUnwrap(result.dispatchStartedAt), result.returnedAt)
            XCTAssertFalse(result.requestRestored)
            XCTAssertTrue(state.pendingApprovals.isEmpty)
            XCTAssertTrue(state.resolvingApprovalIDs.isEmpty)
            let calls = await runtime.callCount()
            XCTAssertEqual(calls, 1)
        }
    }

    func testRuntimeFailureRestoresTheSameRequestForASuccessfulRetry() async {
        let runtime = ApprovalResolutionRuntime()
        await runtime.setHandler { _, _ in throw ApprovalResolutionTestError.failure }
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let request = makeRequest()
        state.pendingApprovals = [request]
        let failed = await state.resolveApproval(request, approved: true, settlePresentation: {})
        XCTAssertEqual(failed.status, .failed)
        XCTAssertFalse(failed.delivered)
        XCTAssertNil(failed.approved)
        XCTAssertTrue(failed.requestRestored)
        XCTAssertFalse(failed.resolvedEventObserved)
        XCTAssertEqual(state.pendingApprovals, [request])
        await runtime.setHandler(nil)
        let retry = await state.resolveApproval(request, approved: true, settlePresentation: {})
        XCTAssertTrue(retry.delivered)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        let calls = await runtime.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testResolvedEventThenRuntimeThrowDoesNotClaimDecisionDeliveryOrRestore() async {
        let runtime = ApprovalResolutionRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let request = makeRequest()
        state.pendingApprovals = [request]
        await runtime.setHandler { id, _ in
            await state.apply(.approvalResolved(requestID: id))
            throw ApprovalResolutionTestError.failure
        }
        let result = await state.resolveApproval(request, approved: true, settlePresentation: {})
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.resolvedEventObserved)
        XCTAssertFalse(result.delivered)
        XCTAssertNil(result.approved)
        XCTAssertFalse(result.requestRestored)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        let retry = await state.resolveApproval(request, approved: true, settlePresentation: {})
        XCTAssertEqual(retry.status, .notAttempted)
        let calls = await runtime.callCount()
        XCTAssertEqual(calls, 1)
        await runtime.setHandler(nil)
    }

    func testNewSameIDRequestIsNotOverwrittenByFailedAttemptRestoration() async {
        let runtime = ApprovalResolutionRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let old = makeRequest(details: "old")
        let newer = makeRequest(details: "new")
        state.pendingApprovals = [old]
        await runtime.setHandler { _, _ in
            await state.apply(.approvalRequested(newer))
            throw ApprovalResolutionTestError.failure
        }
        let result = await state.resolveApproval(old, approved: true, settlePresentation: {})
        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.requestRestored)
        XCTAssertEqual(state.pendingApprovals, [newer])
        await runtime.setHandler(nil)
        let retry = await state.resolveApproval(newer, approved: false, settlePresentation: {})
        XCTAssertTrue(retry.delivered)
        XCTAssertEqual(retry.approved, false)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
    }

    func testConcurrentSameIDResolutionIsANoOpNotASecondDelivery() async {
        let runtime = ApprovalResolutionRuntime()
        let pause = ApprovalResolutionPause()
        await runtime.setHandler { _, _ in await pause.suspend() }
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let request = makeRequest()
        state.pendingApprovals = [request]
        let first = Task { await state.resolveApproval(request, approved: true, settlePresentation: {}) }
        await pause.waitUntilEntered()
        let duplicate = await state.resolveApproval(request, approved: false, settlePresentation: {})
        XCTAssertEqual(duplicate.status, .notAttempted)
        XCTAssertEqual(duplicate.reason, "resolution_in_flight")
        XCTAssertNil(duplicate.approved)
        await pause.release()
        let delivered = await first.value
        XCTAssertTrue(delivered.delivered)
        XCTAssertEqual(delivered.approved, true)
        let calls = await runtime.callCount()
        XCTAssertEqual(calls, 1)
        await runtime.setHandler(nil)
    }

    func testTerminalTaskDuringPresentationSettlePreventsRuntimeDelivery() async throws {
        let runtime = ApprovalResolutionRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        state.apply(.taskStatusChanged(taskID: taskID, status: .running))
        let request = makeRequest(taskID: taskID)
        state.pendingApprovals = [request]
        let result = await state.resolveApproval(request, approved: true, settlePresentation: {
            state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
        })
        XCTAssertEqual(result.status, .notAttempted)
        XCTAssertFalse(result.requestRestored)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        let calls = await runtime.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testTerminalTaskDuringFailedRuntimeCallDoesNotResurrectApproval() async throws {
        let runtime = ApprovalResolutionRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        state.apply(.taskStatusChanged(taskID: taskID, status: .running))
        let request = makeRequest(taskID: taskID)
        state.pendingApprovals = [request]
        await runtime.setHandler { _, _ in
            await state.apply(.taskStatusChanged(taskID: taskID, status: .completed))
            throw ApprovalResolutionTestError.failure
        }
        let result = await state.resolveApproval(request, approved: true, settlePresentation: {})
        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.requestRestored)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        await runtime.setHandler(nil)
    }

    func testCancelledSettleRestoresWithoutAttemptingDelivery() async {
        let runtime = ApprovalResolutionRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let request = makeRequest()
        state.pendingApprovals = [request]
        let result = await state.resolveApproval(request, approved: true, settlePresentation: {
            throw CancellationError()
        })
        XCTAssertEqual(result.status, .notAttempted)
        XCTAssertTrue(result.requestRestored)
        XCTAssertNil(result.dispatchStartedAt)
        XCTAssertEqual(state.pendingApprovals, [request])
        XCTAssertTrue(state.resolvingApprovalIDs.isEmpty)
        let calls = await runtime.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testResolvedEventBeforeRuntimeCallIsNotDeliveryOfOurDecision() async {
        let runtime = ApprovalResolutionRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let request = makeRequest()
        state.pendingApprovals = [request]
        let result = await state.resolveApproval(request, approved: true, settlePresentation: {
            state.apply(.approvalResolved(requestID: request.id))
        })
        XCTAssertEqual(result.status, .notAttempted)
        XCTAssertTrue(result.resolvedEventObserved)
        XCTAssertNil(result.approved)
        XCTAssertFalse(result.requestRestored)
        let calls = await runtime.callCount()
        XCTAssertEqual(calls, 0)
    }

    private func makeRequest(taskID: AgentTask.ID? = nil, details: String = "fixture") -> ActionApprovalRequest {
        .init(id: "approval-test", taskID: taskID, kind: .computerUse,
              title: "Allow a desktop action?", summary: "AXPress on fixture", details: details)
    }
}

private enum ApprovalResolutionTestError: Error { case failure }

private actor ApprovalResolutionRuntime: AgentRuntimeClient {
    nonisolated let providerName = "approval test"
    private var calls = 0
    private var handler: (@Sendable (String, Bool) async throws -> Void)?

    func setHandler(_ value: (@Sendable (String, Bool) async throws -> Void)?) { handler = value }
    func callCount() -> Int { calls }
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {
        calls += 1
        if let handler { try await handler(requestID, approved) }
    }
}

private actor ApprovalResolutionPause {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            entryWaiter?.resume()
            entryWaiter = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

import XCTest
@testable import Computa

@MainActor
final class AppStateAccessModeTests: XCTestCase {
    private let accessModePreferenceKey = "HeyDash.accessMode"

    func testMissingPreferenceDefaultsToAskAndPresentsTheRequest() async {
        let runtime = AccessModeRuntime()
        let state = makeState(runtime: runtime)
        let request = makeRequest(id: "ask-default", kind: .command)

        XCTAssertTrue(state.presentSettings())
        XCTAssertEqual(state.presentedSheet?.rawValue, SheetDestination.settings.rawValue)
        state.apply(.approvalRequested(request))

        XCTAssertEqual(state.accessMode, .askEveryTime)
        XCTAssertEqual(state.presentedApproval, request)
        XCTAssertTrue(state.approvalGateBlocksInteraction)
        XCTAssertEqual(state.pendingApprovals, [request])
        XCTAssertNil(state.presentedSheet)
        XCTAssertFalse(state.presentSettings())
        state.presentedSheet = .settings
        XCTAssertNil(state.presentedSheet)
        let initialCalls = await runtime.recordedCalls()
        XCTAssertEqual(initialCalls, [])

    }

    func testUnknownOrMalformedPreferenceNeverEnablesFullAccess() {
        let invalidValues: [Any] = [
            "", "full", "Full access", "FULLACCESS", " fullAccess", "fullAccess ",
            "unknown", 1, 0, true, false, ["fullAccess"], ["mode": "fullAccess"],
        ]
        for value in invalidValues {
            let preferences = makePreferences()
            preferences.set(value, forKey: accessModePreferenceKey)
            let state = AppState(tasks: [], preferences: preferences)
            XCTAssertEqual(state.accessMode, .askEveryTime, "Rejected value: \(value)")
            let request = makeRequest(id: "malformed", kind: .computerUse)
            state.apply(.approvalRequested(request))
            XCTAssertEqual(state.presentedApproval, request, "Rejected value: \(value)")
            XCTAssertTrue(state.approvalGateBlocksInteraction)
        }
    }

    func testFullAccessPersistsAndRestoresFromAnotherPreferencesInstance() throws {
        let suiteName = "ComputaTests.AccessMode.Relaunch.\(UUID().uuidString)"
        let preferences = makePreferences(suiteName: suiteName)
        let state = AppState(tasks: [], preferences: preferences)
        XCTAssertNil(preferences.object(forKey: accessModePreferenceKey))
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        XCTAssertEqual(preferences.object(forKey: accessModePreferenceKey) as? String, "fullAccess")

        let reopenedPreferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reopened = AppState(tasks: [], preferences: reopenedPreferences)
        XCTAssertEqual(reopened.accessMode, .fullAccess)
        XCTAssertFalse(reopened.approvalGateBlocksInteraction)
    }

    func testPersistedFullAccessAutomaticallyApprovesTheFirstRequest() async throws {
        let preferences = makePreferences()
        preferences.set("fullAccess", forKey: accessModePreferenceKey)
        let runtime = AccessModeRuntime()
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences)
        let request = makeRequest(id: "first-after-relaunch", kind: .computerUse)
        state.apply(.approvalRequested(request))

        XCTAssertEqual(state.accessMode, .fullAccess)
        XCTAssertNil(state.presentedApproval)
        XCTAssertFalse(state.approvalGateBlocksInteraction)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        try await waitUntil { await runtime.recordedCalls().count == 1 }
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }
        let calls = await runtime.recordedCalls()
        XCTAssertEqual(calls, [.init(requestID: request.id, approved: true)])
    }

    func testDowngradingPersistsAskAndReopenedStateRequiresApproval() async throws {
        let suiteName = "ComputaTests.AccessMode.Downgrade.\(UUID().uuidString)"
        let preferences = makePreferences(suiteName: suiteName)
        preferences.set("fullAccess", forKey: accessModePreferenceKey)
        let state = AppState(tasks: [], preferences: preferences)
        XCTAssertTrue(state.setAccessMode(.askEveryTime))
        XCTAssertEqual(preferences.object(forKey: accessModePreferenceKey) as? String, "askEveryTime")

        let runtime = AccessModeRuntime()
        let reopenedPreferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reopened = AppState(tasks: [], runtime: runtime, preferences: reopenedPreferences)
        let request = makeRequest(id: "ask-after-relaunch", kind: .computerUse)
        reopened.apply(.approvalRequested(request))
        XCTAssertEqual(reopened.accessMode, .askEveryTime)
        XCTAssertEqual(reopened.presentedApproval, request)
        XCTAssertTrue(reopened.approvalGateBlocksInteraction)
        let calls = await runtime.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testShutdownRejectsModeChangesWithoutOverwritingSavedChoice() async {
        for initial in [AccessMode.askEveryTime, .fullAccess] {
            let preferences = makePreferences()
            preferences.set(initial.rawValue, forKey: accessModePreferenceKey)
            let state = AppState(tasks: [], preferences: preferences)
            let report = await state.shutdownRuntime()
            XCTAssertTrue(report.succeeded)
            let replacement: AccessMode = initial == .fullAccess ? .askEveryTime : .fullAccess
            XCTAssertFalse(state.setAccessMode(replacement))
            XCTAssertEqual(state.accessMode, initial)
            XCTAssertEqual(preferences.object(forKey: accessModePreferenceKey) as? String, initial.rawValue)
            XCTAssertEqual(AppState(tasks: [], preferences: preferences).accessMode, initial)
        }
    }

    func testMissingPreferenceRemainsAbsentUntilTheUserChangesMode() {
        let preferences = makePreferences()
        let state = AppState(tasks: [], preferences: preferences)
        XCTAssertEqual(state.accessMode, .askEveryTime)
        XCTAssertFalse(state.setAccessMode(.askEveryTime))
        XCTAssertNil(preferences.object(forKey: accessModePreferenceKey))
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        XCTAssertEqual(preferences.object(forKey: accessModePreferenceKey) as? String, "fullAccess")
    }

    func testFullAccessChoiceDoesNotLeakAcrossPreferenceDomains() {
        let selected = AppState(tasks: [], preferences: makePreferences())
        XCTAssertTrue(selected.setAccessMode(.fullAccess))
        let separate = AppState(tasks: [], preferences: makePreferences())
        XCTAssertEqual(separate.accessMode, .askEveryTime)
    }

    func testFullAccessClaimsEveryApprovalKindSynchronouslyIncludingNoTaskOwner() async throws {
        let runtime = AccessModeRuntime()
        let state = makeState(runtime: runtime)
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        let requests = [
            makeRequest(id: "command", kind: .command, taskID: "task-a"),
            makeRequest(id: "file", kind: .fileChange, taskID: "task-b"),
            makeRequest(id: "computer", kind: .computerUse, taskID: nil),
        ]

        for request in requests {
            state.apply(.approvalRequested(request))
        }

        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertNil(state.presentedApproval)
        XCTAssertFalse(state.approvalGateBlocksInteraction)
        XCTAssertEqual(state.resolvingApprovalIDs, Set(requests.map(\.id)))

        try await waitUntil { await runtime.recordedCalls().count == requests.count }
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }
        let calls = await runtime.recordedCalls()
        XCTAssertEqual(Set(calls.map(\.requestID)), Set(requests.map(\.id)))
        XCTAssertTrue(calls.allSatisfy { $0.approved })
    }

    func testSwitchingAskToFullClaimsAnExistingRequestWithoutPresentingIt() async throws {
        let runtime = AccessModeRuntime()
        let state = makeState(runtime: runtime)
        let request = makeRequest(id: "ask-to-full", kind: .computerUse)
        state.apply(.approvalRequested(request))
        XCTAssertEqual(state.presentedApproval, request)

        XCTAssertTrue(state.setAccessMode(.fullAccess))

        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertNil(state.presentedApproval)
        XCTAssertFalse(state.approvalGateBlocksInteraction)
        XCTAssertEqual(state.resolvingApprovalIDs, Set([request.id]))
        try await waitUntil { await runtime.recordedCalls().count == 1 }
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }
        let calls = await runtime.recordedCalls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.requestID, request.id)
        XCTAssertTrue(call.approved)
    }

    func testSwitchingFullToAskBeforeDispatchRestoresWithoutCallingRuntime() async throws {
        let runtime = AccessModeRuntime()
        let state = makeState(runtime: runtime)
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        let request = makeRequest(id: "cancel-auto", kind: .computerUse)
        state.apply(.approvalRequested(request))

        XCTAssertTrue(state.presentSettings())
        XCTAssertEqual(state.presentedSheet?.rawValue, SheetDestination.settings.rawValue)
        XCTAssertTrue(state.setAccessMode(.askEveryTime))
        XCTAssertNil(state.presentedSheet)
        XCTAssertFalse(state.presentSettings())
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }

        let calls = await runtime.recordedCalls()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(state.pendingApprovals, [request])
        XCTAssertEqual(state.presentedApproval, request)
        XCTAssertTrue(state.approvalGateBlocksInteraction)
    }

    func testSwitchingToAskDuringPresentedApprovalSettlePreventsDelivery() async throws {
        let runtime = AccessModeRuntime()
        let state = makeState(runtime: runtime)
        let request = makeRequest(id: "settling-downgrade", kind: .computerUse)
        state.apply(.approvalRequested(request))
        XCTAssertEqual(state.presentedApproval, request)
        XCTAssertTrue(state.setAccessMode(.fullAccess))

        // A request claimed from the visible Ask card observes the same teardown
        // delay as a manual decision. Downgrading during that delay must win.
        try await Task.sleep(for: .milliseconds(10))
        let beforeDowngrade = await runtime.recordedCalls()
        XCTAssertTrue(beforeDowngrade.isEmpty)
        XCTAssertTrue(state.setAccessMode(.askEveryTime))
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }

        let calls = await runtime.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(state.pendingApprovals, [request])
        XCTAssertEqual(state.presentedApproval, request)
    }

    func testSwitchingToAskDuringRuntimeCallDoesNotDuplicateOrUndoSuccess() async throws {
        let runtime = AccessModeRuntime()
        let pause = AccessModePause()
        await runtime.setHandler { _, _ in await pause.suspend() }
        let state = makeState(runtime: runtime)
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        let request = makeRequest(id: "in-flight", kind: .fileChange)
        state.apply(.approvalRequested(request))
        await pause.waitUntilEntered()

        XCTAssertTrue(state.presentSettings())
        XCTAssertEqual(state.presentedSheet?.rawValue, SheetDestination.settings.rawValue)
        XCTAssertTrue(state.setAccessMode(.askEveryTime))
        XCTAssertNil(state.presentedSheet)
        XCTAssertFalse(state.presentSettings())
        await pause.release()
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }

        let calls = await runtime.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertNil(state.presentedApproval)
        XCTAssertNil(state.automaticApprovalError)
    }

    func testAutomaticFailureRestoresOnceWithoutRetryAndAskRevealsIt() async throws {
        let runtime = AccessModeRuntime()
        await runtime.setHandler { _, _ in throw AccessModeTestError.rejected }
        let state = makeState(runtime: runtime)
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        let request = makeRequest(id: "failed-auto", kind: .command)
        state.apply(.approvalRequested(request))

        try await waitUntil { state.resolvingApprovalIDs.isEmpty }
        XCTAssertEqual(state.pendingApprovals, [request])
        XCTAssertNil(state.presentedApproval)
        XCTAssertFalse(state.approvalGateBlocksInteraction)
        XCTAssertNotNil(state.automaticApprovalError)
        let callsAfterFailure = await runtime.recordedCalls()
        XCTAssertEqual(callsAfterFailure.count, 1)

        try await Task.sleep(for: .milliseconds(30))
        let callsAfterSettle = await runtime.recordedCalls()
        XCTAssertEqual(callsAfterSettle.count, 1)
        XCTAssertTrue(state.presentSettings())
        XCTAssertEqual(state.presentedSheet?.rawValue, SheetDestination.settings.rawValue)
        XCTAssertTrue(state.setAccessMode(.askEveryTime))
        XCTAssertNil(state.presentedSheet)
        XCTAssertFalse(state.presentSettings())
        XCTAssertNil(state.automaticApprovalError)
        XCTAssertEqual(state.presentedApproval, request)
        XCTAssertTrue(state.approvalGateBlocksInteraction)
    }

    func testFullAskFullGenerationChurnCannotRetryAnUncertainAutomaticFailure() async throws {
        let runtime = AccessModeRuntime()
        let pause = AccessModePause()
        let failure = AccessModeFirstFailure()
        await runtime.setHandler { _, _ in try await failure.run(after: pause) }
        let state = makeState(runtime: runtime)
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        let request = makeRequest(id: "generation-churn", kind: .computerUse)
        state.apply(.approvalRequested(request))
        await pause.waitUntilEntered()

        XCTAssertTrue(state.setAccessMode(.askEveryTime))
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        await pause.release()
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }

        let calls = await runtime.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(state.pendingApprovals, [request])
        XCTAssertNil(state.presentedApproval)
        XCTAssertNotNil(state.automaticApprovalError)

        XCTAssertTrue(state.setAccessMode(.askEveryTime))
        XCTAssertEqual(state.presentedApproval, request)
    }

    func testChangedSameIDRequestNeverAutoApprovesAndDelayedOldResolutionPreservesIt() async throws {
        let runtime = AccessModeRuntime()
        let pause = AccessModePause()
        await runtime.setHandler { _, _ in await pause.suspend() }
        let state = makeState(runtime: runtime)
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        let old = makeRequest(id: "reused", kind: .command, details: "old payload")
        let replacement = makeRequest(id: old.id, kind: .command, details: "new payload")
        state.apply(.approvalRequested(old))
        await pause.waitUntilEntered()

        state.apply(.approvalRequested(replacement))
        XCTAssertEqual(state.pendingApprovals, [replacement])
        XCTAssertNotNil(state.automaticApprovalError)
        await pause.release()
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }
        let callsAfterOldResolution = await runtime.recordedCalls()
        XCTAssertEqual(callsAfterOldResolution.count, 1)

        // The old call's delayed event is correlated to the old payload and must
        // not discard the replacement merely because the runtime reused its ID.
        state.apply(.approvalResolved(requestID: old.id))
        XCTAssertEqual(state.pendingApprovals, [replacement])

        XCTAssertTrue(state.setAccessMode(.askEveryTime))
        XCTAssertEqual(state.presentedApproval, replacement)
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        try await Task.sleep(for: .milliseconds(30))
        let callsAfterModeReselection = await runtime.recordedCalls()
        XCTAssertEqual(callsAfterModeReselection.count, 1)
        XCTAssertEqual(state.pendingApprovals, [replacement])
        XCTAssertNotNil(state.automaticApprovalError)
    }

    func testDisconnectInvalidatesInFlightAutomaticApprovalWithoutRestoringOrRetrying() async throws {
        let runtime = AccessModeRuntime()
        let pause = AccessModePause()
        await runtime.setHandler { _, _ in
            await pause.suspend()
            throw AccessModeTestError.rejected
        }
        let state = makeState(runtime: runtime)
        XCTAssertTrue(state.setAccessMode(.fullAccess))
        let request = makeRequest(id: "disconnect", kind: .computerUse)
        state.apply(.approvalRequested(request))
        await pause.waitUntilEntered()

        state.apply(.connectionChanged(.failed(message: "Connection closed")))
        await pause.release()
        try await waitUntil { state.resolvingApprovalIDs.isEmpty }

        let callsAfterDisconnect = await runtime.recordedCalls()
        XCTAssertEqual(callsAfterDisconnect.count, 1)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertNil(state.presentedApproval)
        XCTAssertNil(state.automaticApprovalError)
        try await Task.sleep(for: .milliseconds(30))
        let callsAfterSettle = await runtime.recordedCalls()
        XCTAssertEqual(callsAfterSettle.count, 1)
    }

    private func makeState(runtime: AccessModeRuntime) -> AppState {
        AppState(tasks: [], runtime: runtime, preferences: makePreferences())
    }

    private func makePreferences(
        suiteName: String = "ComputaTests.AccessMode.\(UUID().uuidString)"
    ) -> UserDefaults {
        isolatedTestPreferences(suiteName: suiteName)
    }

    private func makeRequest(
        id: String,
        kind: ActionApprovalRequest.Kind,
        taskID: AgentTask.ID? = nil,
        details: String = "fixture"
    ) -> ActionApprovalRequest {
        .init(
            id: id,
            taskID: taskID,
            kind: kind,
            title: "Approve \(id)?",
            summary: "Approval fixture",
            details: details
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for approval state")
    }
}

private enum AccessModeTestError: Error {
    case rejected
}

private actor AccessModeRuntime: AgentRuntimeClient {
    struct Call: Equatable, Sendable {
        let requestID: String
        let approved: Bool
    }

    nonisolated let providerName = "Access mode test"
    private var calls: [Call] = []
    private var handler: (@Sendable (String, Bool) async throws -> Void)?

    func setHandler(_ value: (@Sendable (String, Bool) async throws -> Void)?) {
        handler = value
    }

    func recordedCalls() -> [Call] { calls }
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func interrupt(taskID: AgentTask.ID) async throws {}

    func resolveApproval(requestID: String, approved: Bool) async throws {
        calls.append(.init(requestID: requestID, approved: approved))
        if let handler {
            try await handler(requestID, approved)
        }
    }
}

private actor AccessModePause {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
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

private actor AccessModeFirstFailure {
    private var shouldFail = true

    func run(after pause: AccessModePause) async throws {
        guard shouldFail else { return }
        shouldFail = false
        await pause.suspend()
        throw AccessModeTestError.rejected
    }
}

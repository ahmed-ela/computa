import XCTest
@testable import Macrouse

/// No Chrome process, profile, WebSocket, native permission dialog or desktop
/// input is used here. Deliberately uncancellable fakes exercise late results.
@MainActor
final class AppStateChromeConnectionTests: XCTestCase {
    func testFullAccessNeverConnectsOrRestoresChromeConsent() async {
        let preferences = isolatedTestPreferences()
        preferences.set(AccessMode.fullAccess.rawValue, forKey: "HeyDash.accessMode")
        let runtime = ChromeConnectionRuntime()
        let state = makeState(runtime: runtime, preferences: preferences)
        XCTAssertEqual(state.accessMode, .fullAccess)
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        XCTAssertNil(state.chromeConnectionID)
        let calls = await runtime.recordedRequests()
        XCTAssertTrue(calls.isEmpty)
        state.apply(.chromeConnectionChanged(connectionID: UUID(), state: .connected))
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        let reopened = makeState(runtime: runtime, preferences: preferences)
        XCTAssertEqual(reopened.chromeConnectionState, .disconnected)
        XCTAssertNil(reopened.chromeConnectionID)
    }

    func testMissingAndRevokedConsentFailBeforeRuntimeEvenInFullAccess() async {
        for revoke in [false, true] {
            let runtime = ChromeConnectionRuntime()
            let state = makeState(runtime: runtime)
            state.setAccessMode(.fullAccess)
            let request = makeRequest(approved: revoke)
            if revoke { request.consent.revoke() }
            XCTAssertFalse(state.connectChrome(request))
            XCTAssertNil(state.chromeConnectionID)
            guard case .failed = state.chromeConnectionState else {
                return XCTFail("Expected a consent failure")
            }
            let calls = await runtime.recordedRequests()
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testSuccessfulConnectionUsesOriginalHostRequestAndDoesNotPersistIt() async throws {
        let preferences = isolatedTestPreferences()
        let runtime = ChromeConnectionRuntime()
        let state = makeState(runtime: runtime, preferences: preferences)
        let before = preferences.dictionaryRepresentation()
        let request = makeRequest()
        XCTAssertTrue(state.connectChrome(request))
        XCTAssertEqual(state.chromeConnectionID, request.id)
        XCTAssertEqual(state.chromeConnectionState, .connecting)
        try await waitUntil { state.chromeConnectionState == .connected }
        let calls = await runtime.recordedRequests()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, request.id)
        XCTAssertEqual(calls.first?.application, request.application)
        XCTAssertEqual(calls.first?.userDataDirectory, request.userDataDirectory)
        XCTAssertTrue(calls.first?.consent === request.consent)
        XCTAssertNoThrow(try request.consent.check())
        XCTAssertEqual(NSDictionary(dictionary: preferences.dictionaryRepresentation()),
                       NSDictionary(dictionary: before))
        state.disconnectChrome()
        XCTAssertThrowsError(try request.consent.check())
        try await waitUntil { !state.chromeDisconnecting }
    }

    func testRememberChoiceIsSavedOnlyAfterSuccessfulConnectionAndSurvivesShutdown() async throws {
        let preferences = isolatedTestPreferences()
        let pause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in await pause.suspend() }
        let state = makeState(runtime: runtime, preferences: preferences)
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request, remember: true))
        await pause.waitUntilEntered()
        XCTAssertFalse(state.remembersChromeConnection)
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))

        await pause.release()
        try await waitUntil { state.chromeConnectionState == .connected }
        XCTAssertTrue(state.remembersChromeConnection)
        XCTAssertNotNil(RememberedChromeConnection.load(from: preferences))
        let persisted = try XCTUnwrap(preferences.object(forKey: RememberedChromeConnection.preferenceKey))
        let report = await state.shutdownRuntime()
        XCTAssertTrue(report.succeeded)
        XCTAssertThrowsError(try request.consent.check())
        XCTAssertTrue(state.remembersChromeConnection)
        XCTAssertEqual(NSDictionary(dictionary: ["record": persisted]),
                       NSDictionary(dictionary: ["record": try XCTUnwrap(preferences.object(
                           forKey: RememberedChromeConnection.preferenceKey))]))
    }

    func testReopeningRestoresOnceUsingFreshProcessRequestAndConsent() async throws {
        let preferences = isolatedTestPreferences()
        let original = try await saveRememberedChoice(preferences: preferences)
        let target = try rememberedTarget(pid: 456)
        let runtime = ChromeConnectionRuntime()
        var resolutions = 0
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences,
                             chromeTargetProvider: { resolutions += 1; return target })
        XCTAssertTrue(state.remembersChromeConnection)
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        await state.startRuntime()
        XCTAssertEqual(state.chromeConnectionState, .connected)
        let requests = await runtime.recordedRequests()
        let restored = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(restored.application.processIdentifier, 456)
        XCTAssertEqual(restored.application.executableURL, original.application.executableURL)
        XCTAssertEqual(restored.userDataDirectory, original.userDataDirectory)
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertFalse(restored.consent === original.consent)
        XCTAssertThrowsError(try original.consent.check())
        XCTAssertNoThrow(try restored.consent.check())
        await state.startRuntime()
        XCTAssertEqual(resolutions, 1)
        let afterRestart = await runtime.recordedRequests()
        XCTAssertEqual(afterRestart.count, 1)
        _ = await state.shutdownRuntime()
    }

    func testExplicitDisconnectForgetsChoiceAndNextLaunchDoesNotRestore() async throws {
        let preferences = isolatedTestPreferences()
        let runtime = ChromeConnectionRuntime()
        let state = makeState(runtime: runtime, preferences: preferences)
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request, remember: true))
        try await waitUntil { state.chromeConnectionState == .connected }
        state.disconnectChrome()
        XCTAssertFalse(state.remembersChromeConnection)
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        XCTAssertNil(preferences.object(forKey: RememberedChromeConnection.preferenceKey))
        XCTAssertThrowsError(try request.consent.check())
        try await waitUntil { !state.chromeDisconnecting }

        let reopenedRuntime = ChromeConnectionRuntime()
        let reopened = AppState(tasks: [], runtime: reopenedRuntime, preferences: preferences,
                                chromeTargetProvider: { XCTFail("Forgotten scope must not resolve Chrome"); throw ChromeConnectionTestError.rejected })
        await reopened.startRuntime()
        let requests = await reopenedRuntime.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(reopened.remembersChromeConnection)
        _ = await state.shutdownRuntime()
        _ = await reopened.shutdownRuntime()
    }

    func testForgettingRememberChoiceDoesNotRevokeCurrentConnection() async throws {
        let preferences = isolatedTestPreferences()
        let state = makeState(runtime: ChromeConnectionRuntime(), preferences: preferences)
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request, remember: true))
        try await waitUntil { state.chromeConnectionState == .connected }
        state.forgetRememberedChromeConnection()
        XCTAssertFalse(state.remembersChromeConnection)
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        XCTAssertEqual(state.chromeConnectionState, .connected)
        XCTAssertEqual(state.chromeConnectionID, request.id)
        XCTAssertNoThrow(try request.consent.check())
        _ = await state.shutdownRuntime()
    }

    func testMissingOrMalformedChoiceNeverRestoresEvenInFullAccess() async throws {
        for malformed in [false, true] {
            let preferences = isolatedTestPreferences()
            preferences.set(AccessMode.fullAccess.rawValue, forKey: "HeyDash.accessMode")
            if malformed {
                preferences.set(Data("not a connection record".utf8),
                                forKey: RememberedChromeConnection.preferenceKey)
            }
            let runtime = ChromeConnectionRuntime()
            let state = AppState(tasks: [], runtime: runtime, preferences: preferences,
                                 chromeTargetProvider: { XCTFail("No valid choice grants resolution"); throw ChromeConnectionTestError.rejected })
            XCTAssertEqual(state.accessMode, .fullAccess)
            XCTAssertFalse(state.remembersChromeConnection)
            await state.startRuntime()
            XCTAssertEqual(state.chromeConnectionState, .disconnected)
            let requests = await runtime.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
            _ = await state.shutdownRuntime()
        }
    }

    func testMissingChromeDoesNotRestoreOrRetryAndRetainsRememberedChoice() async throws {
        let preferences = isolatedTestPreferences()
        _ = try await saveRememberedChoice(preferences: preferences)
        let runtime = ChromeConnectionRuntime()
        var resolutions = 0
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences,
                             chromeTargetProvider: { resolutions += 1; throw NativeChromeConnectionError.notRunning })
        await state.startRuntime()
        await state.startRuntime()
        XCTAssertEqual(resolutions, 1)
        XCTAssertTrue(state.remembersChromeConnection)
        XCTAssertNil(state.chromeConnectionID)
        let requests = await runtime.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNotNil(RememberedChromeConnection.load(from: preferences))
        _ = await state.shutdownRuntime()
    }

    func testChangedExecutableOrProfileScopeDoesNotRestore() async throws {
        let targets = [
            try rememberedTarget(executable: URL(fileURLWithPath: "/other/Google Chrome.app/Contents/MacOS/Google Chrome")),
            try rememberedTarget(home: URL(fileURLWithPath: "/Users/another-fixture")),
        ]
        for target in targets {
            let preferences = isolatedTestPreferences()
            _ = try await saveRememberedChoice(preferences: preferences)
            let runtime = ChromeConnectionRuntime()
            let state = AppState(tasks: [], runtime: runtime, preferences: preferences,
                                 chromeTargetProvider: { target })
            await state.startRuntime()
            XCTAssertNil(state.chromeConnectionID)
            XCTAssertTrue(state.remembersChromeConnection)
            let requests = await runtime.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
            _ = await state.shutdownRuntime()
        }
    }

    func testBusyStartupDoesNotRestoreLaterWhenTurnBecomesIdle() async throws {
        let preferences = isolatedTestPreferences()
        _ = try await saveRememberedChoice(preferences: preferences)
        let target = try rememberedTarget()
        let runtime = ChromeConnectionRuntime()
        var resolutions = 0
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences,
                             chromeTargetProvider: { resolutions += 1; return target })
        state.activeTurnTaskIDs.insert("inert-active-turn")
        await state.startRuntime()
        state.activeTurnTaskIDs.removeAll()
        await state.startRuntime()
        XCTAssertEqual(resolutions, 0)
        XCTAssertTrue(state.remembersChromeConnection)
        let requests = await runtime.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        _ = await state.shutdownRuntime()
    }

    func testDisconnectDuringTaskLoadingPreventsLateStartupRestore() async throws {
        let preferences = isolatedTestPreferences()
        _ = try await saveRememberedChoice(preferences: preferences)
        let pause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setLoadHandler { await pause.suspend(); return [] }
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences,
                             chromeTargetProvider: { XCTFail("Disconnect revoked saved choice before loading ended"); throw ChromeConnectionTestError.rejected })
        let startup = Task { await state.startRuntime() }
        await pause.waitUntilEntered()
        state.disconnectChrome()
        XCTAssertFalse(state.remembersChromeConnection)
        await pause.release()
        await startup.value
        let requests = await runtime.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        _ = await state.shutdownRuntime()
    }

    func testLateRememberedConnectionSuccessCannotUndoExplicitDisconnect() async throws {
        let preferences = isolatedTestPreferences()
        let pause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in await pause.suspend() }
        let state = makeState(runtime: runtime, preferences: preferences)
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request, remember: true))
        await pause.waitUntilEntered()
        state.disconnectChrome()
        state.apply(.chromeConnectionChanged(connectionID: request.id, state: .connected))
        await pause.release()
        try await waitUntil { !state.chromeDisconnecting }
        XCTAssertFalse(state.remembersChromeConnection)
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        XCTAssertThrowsError(try request.consent.check())
        _ = await state.shutdownRuntime()
    }

    func testFailedRememberedConnectionDoesNotSaveChoice() async throws {
        let preferences = isolatedTestPreferences()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in throw ChromeConnectionTestError.rejected }
        let state = makeState(runtime: runtime, preferences: preferences)
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request, remember: true))
        try await waitUntil { state.chromeConnectionID == nil && !state.chromeDisconnecting }
        XCTAssertFalse(state.remembersChromeConnection)
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        XCTAssertThrowsError(try request.consent.check())
        _ = await state.shutdownRuntime()
    }

    func testForgettingDuringPendingConnectionPreventsLatePreferenceWrite() async throws {
        let preferences = isolatedTestPreferences()
        let pause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in await pause.suspend() }
        let state = makeState(runtime: runtime, preferences: preferences)
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request, remember: true))
        await pause.waitUntilEntered()
        state.forgetRememberedChromeConnection()
        await pause.release()
        try await waitUntil { state.chromeConnectionState == .connected }
        XCTAssertFalse(state.remembersChromeConnection)
        XCTAssertNil(RememberedChromeConnection.load(from: preferences))
        XCTAssertNoThrow(try request.consent.check(), "Forgetting next-launch consent does not revoke the live connection")
        _ = await state.shutdownRuntime()
    }

    func testFailedStartupReconnectPreservesRememberedScopeWithoutRetrying() async throws {
        let preferences = isolatedTestPreferences()
        _ = try await saveRememberedChoice(preferences: preferences)
        let persisted = preferences.data(forKey: RememberedChromeConnection.preferenceKey)
        let target = try rememberedTarget(pid: 456)
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in throw ChromeConnectionTestError.rejected }
        let state = AppState(tasks: [], runtime: runtime, preferences: preferences,
                             chromeTargetProvider: { target })
        await state.startRuntime()
        try await waitUntil { !state.chromeDisconnecting }
        XCTAssertTrue(state.remembersChromeConnection)
        XCTAssertEqual(preferences.data(forKey: RememberedChromeConnection.preferenceKey), persisted)
        await state.startRuntime()
        let requests = await runtime.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertThrowsError(try XCTUnwrap(requests.first).consent.check())
        _ = await state.shutdownRuntime()
    }

    func testRememberCurrentConnectionRequiresIdleRuntimeAndExactConnectionIdentity() async throws {
        let preferences = isolatedTestPreferences()
        let state = makeState(runtime: ChromeConnectionRuntime(), preferences: preferences)
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request))
        try await waitUntil { state.chromeConnectionState == .connected }
        XCTAssertTrue(state.canRememberChromeConnection)
        XCTAssertFalse(state.rememberChromeConnection(expectedID: UUID()))
        state.activeTurnTaskIDs.insert("inert-active-turn")
        XCTAssertFalse(state.canRememberChromeConnection)
        XCTAssertFalse(state.rememberChromeConnection(expectedID: request.id))
        XCTAssertFalse(state.remembersChromeConnection)
        state.activeTurnTaskIDs.removeAll()
        XCTAssertTrue(state.rememberChromeConnection(expectedID: request.id))
        XCTAssertTrue(state.remembersChromeConnection)
        XCTAssertNotNil(RememberedChromeConnection.load(from: preferences))
        _ = await state.shutdownRuntime()
    }

    func testPromptWaitsForPendingConnectionWithoutMakingItsAdmissionBusy() async throws {
        let pause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in await pause.suspend() }
        let task = AgentTask(title: "Inert prompt", summary: "Test", status: .waiting,
                             workspace: "Test", model: LocalModelCatalog.defaultModelID)
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences())
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request, remember: true))
        await pause.waitUntilEntered()
        let delivery = Task { await state.submit(prompt: "Inert test prompt", toTaskID: task.id) }
        for _ in 0..<10 { await Task.yield() }
        let before = await runtime.recordedSubmissions()
        XCTAssertTrue(before.isEmpty)
        XCTAssertFalse(state.activeTurnTaskIDs.contains(task.id), "Connection admission must remain idle until connect completes")
        await pause.release()
        let delivered = await delivery.value
        XCTAssertTrue(delivered)
        let after = await runtime.recordedSubmissions()
        XCTAssertEqual(after, ["Inert test prompt"])
        XCTAssertEqual(state.chromeConnectionState, .connected)
        _ = await state.shutdownRuntime()
    }

    func testDisconnectRevokesBeforeRuntimeAndWaitsForOldConnectBeforeReconnect() async throws {
        let connectPause = ChromeConnectionPause()
        let disconnectPause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in await connectPause.suspend() }
        await runtime.setDisconnectHandler { await disconnectPause.suspend() }
        let state = makeState(runtime: runtime)
        let original = makeRequest()
        XCTAssertTrue(state.connectChrome(original))
        await connectPause.waitUntilEntered()

        state.disconnectChrome()
        XCTAssertThrowsError(try original.consent.check())
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        XCTAssertNil(state.chromeConnectionID)
        XCTAssertTrue(state.chromeDisconnecting)
        XCTAssertFalse(state.canConnectChrome)
        await disconnectPause.waitUntilEntered()
        let revocations = await runtime.disconnectRevocationChecks()
        XCTAssertEqual(revocations, [true])

        let premature = makeRequest()
        XCTAssertFalse(state.connectChrome(premature))
        XCTAssertThrowsError(try premature.consent.check())
        state.apply(.chromeConnectionChanged(connectionID: original.id, state: .connected))
        state.disconnectChrome()
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        await disconnectPause.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(state.chromeDisconnecting, "The uncancellable old connect is still pending")
        await connectPause.release()
        try await waitUntil { !state.chromeDisconnecting }
        let count = await runtime.disconnectCount()
        XCTAssertEqual(count, 1)

        await runtime.setConnectHandler(nil)
        await runtime.setDisconnectHandler(nil)
        let fresh = makeRequest()
        XCTAssertTrue(state.connectChrome(fresh))
        try await waitUntil { state.chromeConnectionState == .connected }
        state.apply(.chromeConnectionChanged(connectionID: original.id, state: .failed(message: "stale")))
        XCTAssertEqual(state.chromeConnectionState, .connected)
        XCTAssertEqual(state.chromeConnectionID, fresh.id)
        XCTAssertNoThrow(try fresh.consent.check())
        state.disconnectChrome()
        try await waitUntil { !state.chromeDisconnecting }
    }

    func testShutdownRevokesPendingConsentBeforeAnyAwaitAndRejectsNewRequests() async throws {
        let pause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in await pause.suspend() }
        let state = makeState(runtime: runtime)
        let original = makeRequest()
        XCTAssertTrue(state.connectChrome(original))
        await pause.waitUntilEntered()
        let shutdown = Task { await state.shutdownRuntime() }
        try await waitUntil { state.chromeDisconnecting }
        XCTAssertThrowsError(try original.consent.check())
        XCTAssertNil(state.chromeConnectionID)
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        let another = makeRequest()
        XCTAssertFalse(state.connectChrome(another))
        XCTAssertThrowsError(try another.consent.check())
        state.apply(.chromeConnectionChanged(connectionID: original.id, state: .connected))
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
        await pause.release()
        let report = await shutdown.value
        XCTAssertTrue(report.succeeded)
        XCTAssertFalse(state.canConnectChrome)
        let checks = await runtime.shutdownRevocationChecks()
        XCTAssertEqual(checks, [true])
    }

    func testFailedConnectRevokesAndCleansUpWithoutAutomaticRetry() async throws {
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in throw ChromeConnectionTestError.rejected }
        let state = makeState(runtime: runtime)
        let request = makeRequest()
        XCTAssertTrue(state.connectChrome(request))
        try await waitUntil {
            if case .failed = state.chromeConnectionState { return !state.chromeDisconnecting }
            return false
        }
        XCTAssertThrowsError(try request.consent.check())
        XCTAssertNil(state.chromeConnectionID)
        let calls = await runtime.recordedRequests()
        let disconnects = await runtime.disconnectCount()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(disconnects, 1)
        state.apply(.chromeConnectionChanged(connectionID: request.id, state: .connected))
        guard case .failed = state.chromeConnectionState else { return XCTFail("Stale success was accepted") }
    }

    func testCurrentTerminalEventRevokesConsentAndLateSuccessCannotReviveIt() async throws {
        for terminal in [ChromeConnectionState.disconnected, .failed(message: "Connection ended")] {
            let pause = ChromeConnectionPause()
            let runtime = ChromeConnectionRuntime()
            await runtime.setConnectHandler { _ in await pause.suspend() }
            let state = makeState(runtime: runtime)
            let request = makeRequest()
            XCTAssertTrue(state.connectChrome(request))
            await pause.waitUntilEntered()
            state.apply(.chromeConnectionChanged(connectionID: request.id, state: terminal))
            XCTAssertThrowsError(try request.consent.check())
            XCTAssertNil(state.chromeConnectionID)
            XCTAssertEqual(state.chromeConnectionState, terminal)
            state.apply(.chromeConnectionChanged(connectionID: request.id, state: .connected))
            await pause.release()
            try await waitUntil { !state.chromeDisconnecting }
            XCTAssertEqual(state.chromeConnectionState, terminal)
        }
    }

    func testProgressCannotRegressConnectedStateAndWrongIdentityCannotChangeIt() async throws {
        let runtime = ChromeConnectionRuntime()
        let state = makeState(runtime: runtime)
        let request = makeRequest()
        XCTAssertTrue(state.connectChrome(request))
        try await waitUntil { state.chromeConnectionState == .connected }
        state.apply(.chromeConnectionChanged(connectionID: request.id, state: .connecting))
        state.apply(.chromeConnectionChanged(connectionID: UUID(), state: .disconnected))
        state.apply(.chromeConnectionChanged(connectionID: UUID(), state: .failed(message: "stale")))
        XCTAssertEqual(state.chromeConnectionState, .connected)
        XCTAssertNoThrow(try request.consent.check())
        state.disconnectChrome()
        try await waitUntil { !state.chromeDisconnecting }
    }

    func testRevocationWhileConnectIsPendingRejectsAnOtherwiseSuccessfulReturn() async throws {
        let pause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in await pause.suspend() }
        let state = makeState(runtime: runtime)
        let request = makeRequest()
        XCTAssertTrue(state.connectChrome(request))
        await pause.waitUntilEntered()
        request.consent.revoke()
        await pause.release()
        try await waitUntil { state.chromeConnectionID == nil && !state.chromeDisconnecting }
        guard case .failed = state.chromeConnectionState else { return XCTFail("Revoked request was published") }
    }

    func testDuplicateStartDoesNotRevokeActiveConsentButRejectsAnotherRequest() async throws {
        let pause = ChromeConnectionPause()
        let runtime = ChromeConnectionRuntime()
        await runtime.setConnectHandler { _ in await pause.suspend() }
        let state = makeState(runtime: runtime)
        let original = makeRequest()
        XCTAssertTrue(state.connectChrome(original))
        await pause.waitUntilEntered()
        XCTAssertFalse(state.connectChrome(original))
        XCTAssertNoThrow(try original.consent.check())
        let other = makeRequest()
        XCTAssertFalse(state.connectChrome(other))
        XCTAssertThrowsError(try other.consent.check())
        await pause.release()
        try await waitUntil { state.chromeConnectionState == .connected }
        let calls = await runtime.recordedRequests()
        XCTAssertEqual(calls.count, 1)
        state.disconnectChrome()
        try await waitUntil { !state.chromeDisconnecting }
    }

    func testApprovalGateRejectsConnectionRatherThanAutoConfirmingIt() async {
        let runtime = ChromeConnectionRuntime()
        let state = makeState(runtime: runtime)
        state.apply(.approvalRequested(.init(id: "protected-action", taskID: nil, kind: .computerUse,
                                            title: "Approve?", summary: "Test", details: "Test")))
        XCTAssertTrue(state.approvalGateBlocksInteraction)
        let request = makeRequest()
        XCTAssertFalse(state.connectChrome(request))
        XCTAssertThrowsError(try request.consent.check())
        state.setAccessMode(.fullAccess)
        let requests = await runtime.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
    }

    func testFullAccessBusyRuntimeCannotGrantItselfChromeAccess() async {
        let makeBusy: [@MainActor (AppState) -> Void] = [
            { $0.tasks = [.init(title: "Busy fixture", summary: "Test", status: .running,
                               workspace: "Test", model: LocalModelCatalog.defaultModelID)] },
            { $0.activeTurnTaskIDs.insert("busy") },
            { $0.interruptingTaskIDs.insert("stopping") },
            { $0.compactionStateByTask["compacting"] = .running },
            { $0.resolvingApprovalIDs.insert("resolving") },
            { $0.queuedPrompts["scheduled"] = [.init(text: "Not dispatched yet")] },
        ]
        for prepare in makeBusy {
            let runtime = ChromeConnectionRuntime()
            let state = makeState(runtime: runtime)
            state.setAccessMode(.fullAccess)
            prepare(state)
            XCTAssertTrue(state.chromeConnectionRequiresIdleRuntime)
            XCTAssertFalse(state.canConnectChrome)
            let request = makeRequest()
            XCTAssertFalse(state.connectChrome(request))
            XCTAssertThrowsError(try request.consent.check())
            let calls = await runtime.recordedRequests()
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testDisconnectRemainsAvailableWhenConnectedRuntimeBecomesBusy() async throws {
        let runtime = ChromeConnectionRuntime()
        let state = makeState(runtime: runtime)
        let request = makeRequest()
        XCTAssertTrue(state.connectChrome(request))
        try await waitUntil { state.chromeConnectionState == .connected }
        state.activeTurnTaskIDs.insert("busy")
        state.disconnectChrome()
        XCTAssertThrowsError(try request.consent.check())
        XCTAssertNil(state.chromeConnectionID)
        try await waitUntil { !state.chromeDisconnecting }
        XCTAssertEqual(state.chromeConnectionState, .disconnected)
    }

    func testModelRuntimeFailureDoesNotRevokeIndependentBrowserAuthorization() async throws {
        for terminal in [RuntimeConnectionState.disconnected, .failed(message: "Runtime ended")] {
            let runtime = ChromeConnectionRuntime()
            let state = makeState(runtime: runtime)
            let request = makeRequest()
            XCTAssertTrue(state.connectChrome(request))
            try await waitUntil { state.chromeConnectionState == .connected }
            state.apply(.connectionChanged(terminal))
            XCTAssertNoThrow(try request.consent.check())
            XCTAssertEqual(state.chromeConnectionID, request.id)
            XCTAssertEqual(state.chromeConnectionState, .connected)
            let disconnects = await runtime.disconnectCount()
            XCTAssertEqual(disconnects, 0)
            // Only a browser-specific event (or explicit shutdown/disconnect)
            // revokes the grant and invalidates the connection UI.
            state.apply(.chromeConnectionChanged(connectionID: request.id, state: .disconnected))
            XCTAssertThrowsError(try request.consent.check())
            try await waitUntil { !state.chromeDisconnecting }
            XCTAssertEqual(state.chromeConnectionState, .disconnected)
        }
    }

    func testUnsupportedAdapterFailsClosedAndNoRuntimeRejectsWithoutRetainingConsent() async throws {
        let unsupported = AppState(tasks: [], runtime: ChromeUnsupportedRuntime(),
                                   preferences: isolatedTestPreferences())
        let request = makeRequest()
        XCTAssertTrue(unsupported.connectChrome(request))
        try await waitUntil { unsupported.chromeConnectionID == nil && !unsupported.chromeDisconnecting }
        XCTAssertEqual(unsupported.chromeConnectionState,
                       .failed(message: AgentRuntimeCapabilityError.chromeConnectionUnsupported.localizedDescription))
        XCTAssertThrowsError(try request.consent.check())
        let absent = AppState(tasks: [], preferences: isolatedTestPreferences())
        let unused = makeRequest()
        XCTAssertFalse(absent.connectChrome(unused))
        XCTAssertThrowsError(try unused.consent.check())
        XCTAssertFalse(absent.canConnectChrome)
    }

    func testNativeSelectionOnlyUsesExactRunningChromeAndDefaultDirectory() throws {
        let application = nativeApplication()
        let target = try NativeChromeConnectionTarget.select(
            applications: [nativeApplication(bundle: "com.google.Chrome.beta"), application],
            userHomeDirectory: URL(fileURLWithPath: "/Users/fixture-user", isDirectory: true)
        )
        XCTAssertEqual(target.application.processIdentifier, 123)
        XCTAssertEqual(target.application.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(target.userDataDirectory.path,
                       "/Users/fixture-user/Library/Application Support/Google/Chrome")
        let first = target.confirmedRequest()
        let second = target.confirmedRequest()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.consent === second.consent)
        first.consent.revoke()
        XCTAssertNoThrow(try second.consent.check())
        second.consent.revoke()
    }

    func testNativeSelectionRefusesMissingAmbiguousTerminatedOrInvalidApplications() {
        let home = URL(fileURLWithPath: "/Users/fixture-user")
        let invalidGroups: [[NativeChromeRunningApplication]] = [
            [], [nativeApplication(bundle: "org.chromium.Chromium")],
            [nativeApplication(regular: false)], [nativeApplication(terminated: true)],
            [nativeApplication(), nativeApplication()], [nativeApplication(pid: 0)],
            [nativeApplication(executable: URL(fileURLWithPath: "/fixture/not-chrome"))],
            [nativeApplication(executable: URL(string: "https://example.invalid/Google%20Chrome")!)],
        ]
        for applications in invalidGroups {
            XCTAssertThrowsError(try NativeChromeConnectionTarget.select(applications: applications,
                                                                         userHomeDirectory: home))
        }
        for invalidHome in [URL(fileURLWithPath: "/"), URL(string: "https://example.invalid/user")!] {
            XCTAssertThrowsError(try NativeChromeConnectionTarget.select(applications: [nativeApplication()],
                                                                         userHomeDirectory: invalidHome))
        }
    }

    private func makeState(runtime: ChromeConnectionRuntime, preferences: UserDefaults? = nil) -> AppState {
        AppState(tasks: [], runtime: runtime, preferences: preferences ?? isolatedTestPreferences())
    }

    private func rememberedTarget(
        pid: Int32 = 123,
        home: URL = URL(fileURLWithPath: "/Users/fixture-user"),
        executable: URL = URL(fileURLWithPath: "/fixture/Google Chrome.app/Contents/MacOS/Google Chrome")
    ) throws -> NativeChromeConnectionTarget {
        try NativeChromeConnectionTarget.select(applications: [nativeApplication(pid: pid, executable: executable)],
                                                userHomeDirectory: home)
    }

    private func saveRememberedChoice(preferences: UserDefaults) async throws -> ChromeConnectionRequest {
        let state = makeState(runtime: ChromeConnectionRuntime(), preferences: preferences)
        let request = try rememberedTarget().confirmedRequest()
        XCTAssertTrue(state.connectChrome(request, remember: true))
        try await waitUntil { state.chromeConnectionState == .connected }
        XCTAssertTrue(state.remembersChromeConnection)
        let report = await state.shutdownRuntime()
        XCTAssertTrue(report.succeeded)
        return request
    }

    private func makeRequest(approved: Bool = true) -> ChromeConnectionRequest {
        .init(application: .init(processIdentifier: 123, bundleIdentifier: "com.google.Chrome",
                                 executableURL: URL(fileURLWithPath: "/fixture/Google Chrome.app/Contents/MacOS/Google Chrome")),
              userDataDirectory: URL(fileURLWithPath: "/fixture/profile-never-read"),
              consent: ChromeDebuggingConsent(approvedByUser: approved))
    }

    private func nativeApplication(
        pid: Int32 = 123, bundle: String = "com.google.Chrome", regular: Bool = true,
        terminated: Bool = false,
        executable: URL = URL(fileURLWithPath: "/fixture/Google Chrome.app/Contents/MacOS/Google Chrome")
    ) -> NativeChromeRunningApplication {
        .init(processIdentifier: pid, bundleIdentifier: bundle, executableURL: executable,
              isRegular: regular, isTerminated: terminated)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for inert Chrome connection state")
        throw ChromeConnectionTestError.timedOut
    }
}

private enum ChromeConnectionTestError: Error {
    case rejected, timedOut
}

private actor ChromeConnectionRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Inert Chrome lifecycle test"
    private var requests: [ChromeConnectionRequest] = []
    private var disconnectedWhileRevoked: [Bool] = []
    private var shutdownWhileRevoked: [Bool] = []
    private var submissions: [String] = []
    private var connectHandler: (@Sendable (ChromeConnectionRequest) async throws -> Void)?
    private var disconnectHandler: (@Sendable () async -> Void)?
    private var loadHandler: (@Sendable () async throws -> [AgentTask])?

    func setConnectHandler(_ handler: (@Sendable (ChromeConnectionRequest) async throws -> Void)?) {
        connectHandler = handler
    }
    func setDisconnectHandler(_ handler: (@Sendable () async -> Void)?) { disconnectHandler = handler }
    func setLoadHandler(_ handler: (@Sendable () async throws -> [AgentTask])?) { loadHandler = handler }
    func recordedRequests() -> [ChromeConnectionRequest] { requests }
    func recordedSubmissions() -> [String] { submissions }
    func disconnectCount() -> Int { disconnectedWhileRevoked.count }
    func disconnectRevocationChecks() -> [Bool] { disconnectedWhileRevoked }
    func shutdownRevocationChecks() -> [Bool] { shutdownWhileRevoked }

    func connectChrome(_ request: ChromeConnectionRequest) async throws {
        requests.append(request)
        if let connectHandler { try await connectHandler(request) }
    }
    func disconnectChrome() async {
        disconnectedWhileRevoked.append(allRequestsRevoked)
        if let disconnectHandler { await disconnectHandler() }
    }
    func shutdown() async -> RuntimeShutdownReport {
        shutdownWhileRevoked.append(allRequestsRevoked)
        return .init(issues: [])
    }
    private var allRequestsRevoked: Bool {
        requests.allSatisfy {
            do { try $0.consent.check(); return false }
            catch { return true }
        }
    }
    func loadTasks() async throws -> [AgentTask] {
        if let loadHandler { return try await loadHandler() }
        return []
    }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws { submissions.append(prompt) }
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

private struct ChromeUnsupportedRuntime: AgentRuntimeClient {
    let providerName = "No Chrome capability"
    func loadTasks() async throws -> [AgentTask] { [] }
    func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

private actor ChromeConnectionPause {
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

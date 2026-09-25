import Foundation
import XCTest
@testable import HeyDash

final class BrowserTabSessionBrokerTests: XCTestCase {
    func testTaskScopedHandleRejectsCrossTaskSnapshot() async throws {
        let transport = FakeBrowserTabTransport()
        let generation = UUID()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: generation
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 41,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )

        do {
            _ = try await broker.snapshot(
                taskKey: "task-b",
                binding: binding,
                bundleIdentifier: "com.google.Chrome",
                query: "Mark this tab complete"
            )
            XCTFail("A cross-task browser handle must fail closed.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .crossTaskHandle)
        }
    }

    func testNavigationChangesEpochAndRejectsApprovedSnapshotBeforeInput() async throws {
        let transport = FakeBrowserTabTransport()
        let generation = UUID()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: generation
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 42,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observation = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )
        try await transport.navigate(
            targetID: binding.targetID,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a?next=1")),
            loaderID: "loader-2"
        )

        do {
            try await broker.perform(
                taskKey: "task-a",
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
            XCTFail("A stale document epoch must reject before input.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .staleDocument)
        }
        let stalePressCount = await transport.pressCount(targetID: binding.targetID)
        XCTAssertEqual(stalePressCount, 0)

        let refreshed = try await broker.snapshot(
            taskKey: "task-a",
            binding: observation.binding,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )
        XCTAssertNotEqual(
            refreshed.binding.documentEpoch,
            observation.binding.documentEpoch
        )
    }



    func testNewObservationInvalidatesPriorBrowserSnapshot() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 46,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let first = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )
        _ = try await broker.snapshot(
            taskKey: "task-a",
            binding: first.binding,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )

        do {
            try await broker.perform(
                taskKey: "task-a",
                binding: first.binding,
                snapshot: first.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
            XCTFail("A newer observation must invalidate the prior snapshot.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .staleSnapshot)
        }
        let pressCount = await transport.pressCount(targetID: binding.targetID)
        XCTAssertEqual(pressCount, 0)
    }

    func testClosedTargetRejectsBeforeInput() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 45,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        await transport.closeTarget(targetID: binding.targetID)

        do {
            _ = try await broker.snapshot(
                taskKey: "task-a",
                binding: binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
            XCTFail("A closed tab must reject before any input.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .targetClosed)
        }
    }

    func testClosedOrReusedTargetCannotResurrectHandle() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 43,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        try await transport.replaceTargetInstance(targetID: binding.targetID)

        do {
            _ = try await broker.snapshot(
                taskKey: "task-a",
                binding: binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
            XCTFail("A target-ID reuse must not resurrect the opaque handle.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .targetReplaced)
        }
    }

    func testExactBackgroundTargetMutatesWhileOtherTargetStaysForeground() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let bindingA = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 44,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observationA = try await broker.snapshot(
            taskKey: "task-a",
            binding: bindingA,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )
        let targetB = try await transport.createForegroundTarget(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        let foregroundBefore = await transport.activeTargetID()
        XCTAssertEqual(foregroundBefore, targetB.targetID)

        try await broker.perform(
            taskKey: "task-a",
            binding: observationA.binding,
            snapshot: observationA.snapshot,
            elementIndex: 0,
            action: "AXPress"
        )

        let tabAPressCount = await transport.pressCount(targetID: bindingA.targetID)
        let tabBPressCount = await transport.pressCount(targetID: targetB.targetID)
        let foregroundAfter = await transport.activeTargetID()
        XCTAssertEqual(tabAPressCount, 1)
        XCTAssertEqual(tabBPressCount, 0)
        XCTAssertEqual(foregroundAfter, targetB.targetID)
    }

    func testSnapshotRevocationNeverResurrectsHandle() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            try await fixture.broker.revoke(
                taskKey: "task-a",
                binding: fixture.observation.binding
            )
        }
        await assertBrowserError(.handleMissing) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
        }
        await assertBrowserError(.handleMissing) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
        }
        await fixture.assertNoInput()
    }

    func testRevocationCancelsBothActionsAcrossAwaits() async throws {
        for setText in [false, true] {
            for atDispatch in [false, true] {
                let fixture = try await BrowserBrokerTestFixture.make()
                let revoke: @Sendable () async throws -> Void = {
                    try await fixture.broker.revoke(
                        taskKey: "task-a",
                        binding: fixture.observation.binding
                    )
                }
                if atDispatch {
                    await fixture.transport.onNextMutation(revoke)
                } else {
                    await fixture.transport.onNextObservation(revoke)
                }
                await assertBrowserError(atDispatch ? .staleSnapshot : .handleMissing) {
                    try await fixture.act(setText: setText)
                }
                await fixture.assertNoInput()
            }
        }
    }

    func testLateReloadAndFragmentChangeRejectBothActions() async throws {
        for setText in [false, true] {
            for sameLoader in [false, true] {
                let fixture = try await BrowserBrokerTestFixture.make()
                let destination: URL
                if sameLoader {
                    destination = try XCTUnwrap(URL(string: "http://127.0.0.1/a#changed"))
                } else {
                    destination = fixture.observation.snapshot.documentURL
                }
                let loaderID = sameLoader
                    ? fixture.observation.snapshot.loaderID : "replacement-loader"
                await fixture.transport.onNextMutation {
                    try await fixture.transport.navigate(
                        targetID: fixture.observation.binding.targetID,
                        url: destination,
                        loaderID: loaderID
                    )
                }
                await assertBrowserError(.staleDocument) {
                    try await fixture.act(setText: setText)
                }
                await fixture.assertNoInput()
                let refreshed = try await fixture.broker.snapshot(
                    taskKey: "task-a",
                    binding: fixture.observation.binding,
                    bundleIdentifier: "com.google.Chrome",
                    query: nil
                )
                XCTAssertNotEqual(
                    refreshed.binding.documentEpoch,
                    fixture.observation.binding.documentEpoch
                )
            }
        }
    }

    func testOverlappingSnapshotFailsClosed() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            await assertBrowserError(.operationInProgress) {
                _ = try await fixture.broker.snapshot(
                    taskKey: "task-a",
                    binding: fixture.observation.binding,
                    bundleIdentifier: "com.google.Chrome",
                    query: nil
                )
            }
        }
        let refreshed = try await fixture.broker.snapshot(
            taskKey: "task-a",
            binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome",
            query: nil
        )
        XCTAssertNotEqual(refreshed.snapshot.id, fixture.observation.snapshot.id)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: false)
        }
        await fixture.assertNoInput()
    }

    func testFailedSnapshotInvalidatesPriorObservation() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            throw BrowserTabBrokerError.browserUnavailable("injected observation failure")
        }
        await assertBrowserError(.browserUnavailable("injected observation failure")) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
        }
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: false)
        }
        await fixture.assertNoInput()
    }

    func testCrossTaskMutationsRejectBeforeInput() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        for setText in [false, true] {
            await assertBrowserError(.crossTaskHandle) {
                try await fixture.act(setText: setText, taskKey: "task-b")
            }
        }
        await fixture.assertNoInput()
    }

    func testBackgroundSetTextIsSingleUseAndLeavesForegroundUntouched() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let targetB = try await fixture.transport.createForegroundTarget(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        try await fixture.act(setText: true)
        let valuesA = await fixture.transport.textValues(
            targetID: fixture.observation.binding.targetID
        )
        let valuesB = await fixture.transport.textValues(targetID: targetB.targetID)
        let foreground = await fixture.transport.activeTargetID()
        XCTAssertEqual(valuesA, ["updated"])
        XCTAssertTrue(valuesB.isEmpty)
        XCTAssertEqual(foreground, targetB.targetID)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: true)
        }
        let finalValuesA = await fixture.transport.textValues(
            targetID: fixture.observation.binding.targetID
        )
        XCTAssertEqual(finalValuesA, ["updated"])
    }

    func testReadOnlyTextIsNotAdvertisedOrMutated() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.makeTextReadOnly(
            targetID: fixture.observation.binding.targetID
        )
        await assertBrowserError(.elementChanged) {
            try await fixture.act(setText: true)
        }
        let refreshed = try await fixture.broker.snapshot(
            taskKey: "task-a",
            binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome",
            query: nil
        )
        let field = try XCTUnwrap(refreshed.snapshot.element(at: 1))
        XCTAssertFalse(field.supportsSetText)
        await assertBrowserError(.unsupportedAction("set text")) {
            try await fixture.broker.setText(
                taskKey: "task-a",
                binding: refreshed.binding,
                snapshot: refreshed.snapshot,
                elementIndex: 1,
                text: "not allowed"
            )
        }
        await fixture.assertNoInput()
    }

    func testMutationPermitRevocationAndSingleUse() throws {
        var sends = 0
        let revoked = BrowserMutationPermit()
        revoked.revoke()
        XCTAssertThrowsError(try revoked.commit { sends += 1 }) { error in
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        XCTAssertEqual(sends, 0)

        let committed = BrowserMutationPermit()
        try committed.commit { sends += 1 }
        XCTAssertThrowsError(try committed.commit { sends += 1 }) { error in
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        committed.revoke()
        XCTAssertEqual(sends, 1)
    }

    func testRevokingOneTaskClosesOnlyItsTargetAndPreservesOtherBinding() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let bindingB = try await fixture.broker.open(
            taskKey: "task-b",
            processIdentifier: 47,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        try await fixture.broker.revoke(taskKey: "task-a", binding: fixture.observation.binding)
        let closed = await fixture.transport.closedTargetIDs()
        XCTAssertEqual(closed, [fixture.observation.binding.targetID])
        let targetA = try await fixture.transport.target(id: fixture.observation.binding.targetID)
        XCTAssertNil(targetA)
        let observationB = try await fixture.broker.snapshot(
            taskKey: "task-b", binding: bindingB,
            bundleIdentifier: "com.google.Chrome", query: nil
        )
        try await fixture.broker.setText(
            taskKey: "task-b", binding: observationB.binding,
            snapshot: observationB.snapshot, elementIndex: 1, text: "B only"
        )
        let valuesB = await fixture.transport.textValues(targetID: bindingB.targetID)
        let foreground = await fixture.transport.activeTargetID()
        XCTAssertEqual(valuesB, ["B only"])
        XCTAssertEqual(foreground, bindingB.targetID)
        for setText in [false, true] {
            await assertBrowserError(.handleMissing) { try await fixture.act(setText: setText) }
        }
        await fixture.assertNoInput()
    }

    func testSynchronousRuntimeRevocationWinsBeforeActorCleanup() async throws {
        for setText in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            await fixture.transport.onNextMutation {
                fixture.observation.binding.lifetime.revoke()
            }
            await assertBrowserError(.staleSnapshot) {
                try await fixture.act(setText: setText)
            }
            await fixture.assertNoInput()
        }
    }

    func testRevocationDuringCreationClosesTheUnpublishedTarget() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID())
        let lifetime = BrowserTabLifetime()
        await transport.onNextCreation { lifetime.revoke() }
        await assertBrowserError(.handleMissing) {
            _ = try await broker.open(
                taskKey: "pending", processIdentifier: 48,
                url: URL(string: "http://127.0.0.1/pending")!,
                lifetime: lifetime
            )
        }
        let closed = await transport.closedTargetIDs()
        XCTAssertEqual(closed, ["target-1"])
        let target = try await transport.target(id: "target-1")
        let presses = await transport.pressCount(targetID: "target-1")
        let values = await transport.textValues(targetID: "target-1")
        XCTAssertNil(target)
        XCTAssertEqual(presses, 0)
        XCTAssertTrue(values.isEmpty)
    }

    func testSessionShutdownRevokesSuspendedMutationAndRejectsNewOpen() async throws {
        for setText in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            await fixture.transport.onNextObservation { await fixture.broker.invalidateAll() }
            await assertBrowserError(.handleMissing) {
                try await fixture.act(setText: setText)
            }
            await assertBrowserError(.handleMissing) {
                _ = try await fixture.broker.open(
                    taskKey: "later", processIdentifier: 47,
                    url: URL(string: "http://127.0.0.1/later")!
                )
            }
            await fixture.assertNoInput()
        }
    }

    func testFakeOracleRetainsInputHistoryAfterClose() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.act(setText: true)
        try await fixture.broker.revoke(taskKey: "task-a", binding: fixture.observation.binding)
        let values = await fixture.transport.textValues(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(values, ["updated"], "Closing a fake target must not erase evidence of input.")
    }

    func testSuccessfulPressWaitsForIndependentProofBeforeReturning() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let pause = BrowserPressBoundaryPause()
        let chrome = pressBoundaryBroker(fixture, pause: pause)
        let action = Task {
            try await chrome.perform(
                taskKey: fixture.observation.binding.taskKey, binding: fixture.observation.binding,
                snapshot: fixture.observation.snapshot, elementIndex: 0, action: "AXPress"
            )
            await pause.returned()
        }
        await pause.waitUntilEntered()
        let held = await pause.snapshot()
        XCTAssertEqual(held.events, ["proof_started"])
        XCTAssertEqual(held.handle, fixture.observation.binding.handle)
        XCTAssertEqual(held.snapshotID, fixture.observation.snapshot.id)
        let count = await fixture.transport.pressCount(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(count, 1)

        // The successful action consumed its snapshot before reaching the proof.
        // A retry cannot dispatch again or create a second proof callback.
        do {
            try await chrome.perform(
                taskKey: fixture.observation.binding.taskKey, binding: fixture.observation.binding,
                snapshot: fixture.observation.snapshot, elementIndex: 0, action: "AXPress"
            )
            XCTFail("A consumed snapshot must fail even while proof is suspended.")
        } catch {
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        await pause.release()
        try await action.value
        let completed = await pause.snapshot()
        XCTAssertEqual(completed.events, ["proof_started", "proof_completed", "press_returned"])
        let report = await chrome.shutdown()
        XCTAssertTrue(report.succeeded)
    }

    func testShutdownRevokesWhileReadOnlyPressProofIsSuspended() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let pause = BrowserPressBoundaryPause()
        let chrome = pressBoundaryBroker(fixture, pause: pause)
        let action = Task {
            try await chrome.perform(
                taskKey: fixture.observation.binding.taskKey, binding: fixture.observation.binding,
                snapshot: fixture.observation.snapshot, elementIndex: 0, action: "AXPress"
            )
        }
        await pause.waitUntilEntered()
        let report = await chrome.shutdown()
        XCTAssertTrue(report.succeeded)
        XCTAssertThrowsError(try fixture.observation.binding.lifetime.check())
        let held = await pause.snapshot()
        XCTAssertEqual(held.events, ["proof_started"])
        await pause.release()
        try await action.value // The earlier press happened; no second input is authorized.
        let count = await fixture.transport.pressCount(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(count, 1)
        let ownership = await chrome.ownership()
        XCTAssertNil(ownership)
        let repeated = await chrome.shutdown()
        XCTAssertEqual(repeated, report)
    }

    private func pressBoundaryBroker(
        _ fixture: BrowserBrokerTestFixture, pause: BrowserPressBoundaryPause
    ) -> ChromeTabBroker {
        let initial = ChromeTabBroker.BrowserProcess(
            process: BrowserPressBoundaryChild(processIdentifier: fixture.observation.binding.processIdentifier),
            dataDirectory: URL(fileURLWithPath: "/not-created/LocalCodexBrowserBroker-proof-test"),
            generation: fixture.observation.binding.browserGeneration,
            transport: SystemChromeDevToolsTransport(port: 1), sessions: fixture.broker
        )
        return ChromeTabBroker(
            initialBrowser: initial, removeProfile: { _ in nil },
            didPerformPress: { binding, snapshot in
                await pause.enter(handle: binding.handle, snapshotID: snapshot.id)
            }
        )
    }
}

private struct BrowserBrokerTestFixture: Sendable {
    let transport: FakeBrowserTabTransport
    let broker: BrowserTabSessionBroker
    let observation: BrowserTabObservation

    static func make() async throws -> BrowserBrokerTestFixture {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 47,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observation = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.google.Chrome",
            query: nil
        )
        return BrowserBrokerTestFixture(
            transport: transport,
            broker: broker,
            observation: observation
        )
    }

    func act(setText: Bool, taskKey: String = "task-a") async throws {
        if setText {
            try await broker.setText(
                taskKey: taskKey,
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 1,
                text: "updated"
            )
        } else {
            try await broker.perform(
                taskKey: taskKey,
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
        }
    }

    func assertNoInput(file: StaticString = #filePath, line: UInt = #line) async {
        let presses = await transport.pressCount(targetID: observation.binding.targetID)
        let values = await transport.textValues(targetID: observation.binding.targetID)
        XCTAssertEqual(presses, 0, file: file, line: line)
        XCTAssertTrue(values.isEmpty, file: file, line: line)
    }
}

private func assertBrowserError(
    _ expected: BrowserTabBrokerError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: @Sendable () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch let error as BrowserTabBrokerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private actor FakeBrowserTabTransport: BrowserTabTransport {
    private struct State {
        var target: BrowserTarget
        var document: BrowserDocumentObservation
        var pressCount = 0
        var textValues = [String]()
    }

    private var nextTarget = 1
    private var states = [String: State]()
    private var closedStates = [String: State]()
    private var closedIDs = [String]()
    private var nextCreationHook: (@Sendable () async throws -> Void)?
    private var foregroundTargetID: String?
    private var nextObservationHook: (@Sendable () async throws -> Void)?
    private var nextMutationHook: (@Sendable () async throws -> Void)?

    func onNextCreation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextCreationHook = hook
    }

    func closedTargetIDs() -> [String] { closedIDs }

    func onNextObservation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextObservationHook = hook
    }

    func onNextMutation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextMutationHook = hook
    }

    func createTarget(url: URL) async throws -> BrowserTarget {
        let targetID = "target-\(nextTarget)"
        nextTarget += 1
        let target = makeTarget(targetID: targetID, url: url, instance: UUID())
        states[targetID] = State(
            target: target,
            document: makeDocument(url: url, loaderID: "loader-\(targetID)")
        )
        let hook = nextCreationHook
        nextCreationHook = nil
        if let hook { try await hook() }
        return target
    }

    func target(id: String) async throws -> BrowserTarget? {
        states[id]?.target
    }

    func activateTarget(id: String) async throws {
        guard states[id] != nil else {
            throw BrowserTabBrokerError.targetClosed
        }
        foregroundTargetID = id
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        guard let state = states[target.targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard state.target.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        let hook = nextObservationHook
        nextObservationHook = nil
        if let hook { try await hook() }
        return state.document
    }

    func press(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        let hook = nextMutationHook
        nextMutationHook = nil
        if let hook { try await hook() }
        try permit.commit {
            var state = try stateForMutation(
                target: target, backendNodeID: backendNodeID, document: document
            )
            state.pressCount += 1
            states[target.targetID] = state
        }
    }

    func setText(
        target: BrowserTarget,
        backendNodeID: Int64,
        text: String,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        let hook = nextMutationHook
        nextMutationHook = nil
        if let hook { try await hook() }
        try permit.commit {
            var state = try stateForMutation(
                target: target, backendNodeID: backendNodeID, document: document
            )
            state.textValues.append(text)
            states[target.targetID] = state
        }
    }

    private func stateForMutation(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation
    ) throws -> State {
        guard let state = states[target.targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard state.target.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        guard state.document.loaderID == document.loaderID,
              state.document.url == document.url else {
            throw BrowserTabBrokerError.staleDocument
        }
        let approved = document.nodes.filter { $0.backendNodeID == backendNodeID }
        let current = state.document.nodes.filter { $0.backendNodeID == backendNodeID }
        guard approved.count == 1, current.count == 1 else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard current[0] == approved[0] else {
            throw BrowserTabBrokerError.elementChanged
        }
        return state
    }

    func navigate(targetID: String, url: URL, loaderID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.target = makeTarget(
            targetID: targetID,
            url: url,
            instanceToken: state.target.instanceToken
        )
        state.document = makeDocument(url: url, loaderID: loaderID)
        states[targetID] = state
    }

    func closeTarget(target: BrowserTarget) async throws {
        guard let current = states[target.targetID]?.target else { return }
        guard current.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        closeTarget(targetID: target.targetID)
    }

    func closeTarget(targetID: String) {
        if let state = states.removeValue(forKey: targetID) {
            closedStates[targetID] = state
            closedIDs.append(targetID)
        }
        if foregroundTargetID == targetID {
            foregroundTargetID = nil
        }
    }

    func replaceTargetInstance(targetID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.target = makeTarget(
            targetID: targetID,
            url: state.target.url,
            instance: UUID()
        )
        states[targetID] = state
    }

    func createForegroundTarget(url: URL) async throws -> BrowserTarget {
        let target = try await createTarget(url: url)
        try await activateTarget(id: target.targetID)
        return target
    }

    func pressCount(targetID: String) -> Int {
        (states[targetID] ?? closedStates[targetID])?.pressCount ?? 0
    }

    func activeTargetID() -> String? {
        foregroundTargetID
    }

    func textValues(targetID: String) -> [String] {
        (states[targetID] ?? closedStates[targetID])?.textValues ?? []
    }

    func makeTextReadOnly(targetID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.document = BrowserDocumentObservation(
            loaderID: state.document.loaderID,
            title: state.document.title,
            url: state.document.url,
            nodes: state.document.nodes.map { node in
                BrowserDocumentNode(
                    backendNodeID: node.backendNodeID,
                    role: node.role,
                    name: node.name,
                    value: node.value,
                    isDisabled: node.isDisabled,
                    isReadOnly: node.backendNodeID == 101 || node.isReadOnly,
                    isIgnored: node.isIgnored
                )
            }
        )
        states[targetID] = state
    }

    private func makeTarget(
        targetID: String,
        url: URL,
        instance: UUID
    ) -> BrowserTarget {
        makeTarget(
            targetID: targetID,
            url: url,
            instanceToken: "ws://fake/\(targetID)/\(instance.uuidString)"
        )
    }

    private func makeTarget(
        targetID: String,
        url: URL,
        instanceToken: String
    ) -> BrowserTarget {
        BrowserTarget(
            targetID: targetID,
            instanceToken: instanceToken,
            title: "Safe computer-use benchmark - Google Chrome",
            url: url,
            webSocketURL: URL(string: instanceToken)!
        )
    }

    private func makeDocument(
        url: URL,
        loaderID: String
    ) -> BrowserDocumentObservation {
        BrowserDocumentObservation(
            loaderID: loaderID,
            title: "Safe computer-use benchmark - Google Chrome",
            url: url,
            nodes: [
                BrowserDocumentNode(
                    backendNodeID: 100,
                    role: "button",
                    name: "Mark this tab complete",
                    value: nil,
                    isDisabled: false,
                    isReadOnly: false,
                    isIgnored: false
                ),
                BrowserDocumentNode(
                    backendNodeID: 101,
                    role: "textbox",
                    name: "Editable note",
                    value: "",
                    isDisabled: false,
                    isReadOnly: false,
                    isIgnored: false
                ),            ]
        )
    }
}

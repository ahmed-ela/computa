import Foundation
import XCTest
@testable import Computa

/// These are adapter-independent lifecycle tests, not an ordinary-Chrome live gate.
final class BrowserTabOwnershipTests: XCTestCase {
    func testBorrowedBindingDoesNotCreateActivateOrCloseTarget() async throws {
        let fixture = OwnershipFixture()
        let binding = try await fixture.bind()
        XCTAssertEqual(binding.ownership, .borrowed)
        try await fixture.broker.revoke(taskKey: "task", binding: binding)
        XCTAssertThrowsError(try binding.lifetime.check())
        await fixture.assertNoLifecycleMutation()
        let existing = try await fixture.transport.target(id: fixture.target.targetID)
        XCTAssertEqual(existing, fixture.target)
    }

    func testBorrowedModeRejectsCreationAndOwnedModeRejectsAdoption() async throws {
        let fixture = OwnershipFixture()
        await expectOwnershipError(.ownershipMismatch) {
            _ = try await fixture.broker.open(taskKey: "task", processIdentifier: 51, url: fixture.target.url)
        }
        let owned = BrowserTabSessionBroker(transport: fixture.transport, browserGeneration: UUID())
        await expectOwnershipError(.ownershipMismatch) {
            _ = try await owned.bindBorrowed(taskKey: "task", processIdentifier: 51, target: fixture.target)
        }
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedReplacementBindingRevokesOnlyOldCapability() async throws {
        let fixture = OwnershipFixture()
        let first = try await fixture.bind()
        let second = try await fixture.bind()
        XCTAssertNotEqual(first.handle, second.handle)
        XCTAssertThrowsError(try first.lifetime.check())
        XCTAssertNoThrow(try second.lifetime.check())
        await expectOwnershipError(.handleMissing) { _ = try await fixture.snapshot(first) }
        await expectOwnershipError(.operationInProgress) {
            _ = try await fixture.bind(taskKey: "other-task")
        }
        XCTAssertNoThrow(try second.lifetime.check())
        await fixture.assertNoLifecycleMutation()
    }

    func testConcurrentBorrowedBindReservesTargetBeforeFirstTransportAwait() async throws {
        let fixture = OwnershipFixture()
        let rejectedLifetime = BrowserTabLifetime()
        await fixture.transport.onTargetRead {
            await expectOwnershipError(.operationInProgress) {
                _ = try await fixture.bind(taskKey: "other-task", lifetime: rejectedLifetime)
            }
        }
        let binding = try await fixture.bind()
        XCTAssertNoThrow(try binding.lifetime.check())
        XCTAssertThrowsError(try rejectedLifetime.check())
        let reads = await fixture.transport.targetReadCount
        let observations = await fixture.transport.observationCount
        XCTAssertEqual(reads, 2, "Rejected overlap must not reach even its first target read.")
        XCTAssertEqual(observations, 1)
        await expectOwnershipError(.operationInProgress) {
            _ = try await fixture.bind(taskKey: "other-task")
        }
        await fixture.assertNoLifecycleMutation()
    }

    func testFailedBorrowedBindReleasesItsReservation() async throws {
        let fixture = OwnershipFixture()
        let lifetime = BrowserTabLifetime()
        await fixture.transport.onObservation {
            throw BrowserTabBrokerError.browserUnavailable("injected observation failure")
        }
        await expectOwnershipError(.browserUnavailable("injected observation failure")) {
            _ = try await fixture.bind(lifetime: lifetime)
        }
        XCTAssertThrowsError(try lifetime.check())
        let rebound = try await fixture.bind(taskKey: "other-task")
        XCTAssertEqual(rebound.taskKey, "other-task")
        XCTAssertNoThrow(try rebound.lifetime.check())
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedRevokeReleasesTargetForAnotherTask() async throws {
        let fixture = OwnershipFixture()
        let first = try await fixture.bind()
        await expectOwnershipError(.operationInProgress) {
            _ = try await fixture.bind(taskKey: "other-task")
        }
        try await fixture.broker.revoke(taskKey: first.taskKey, binding: first)
        let second = try await fixture.bind(taskKey: "other-task")
        XCTAssertNotEqual(first.handle, second.handle)
        XCTAssertThrowsError(try first.lifetime.check())
        XCTAssertNoThrow(try second.lifetime.check())
        // Stale cleanup cannot release a new task's reservation.
        await expectOwnershipError(.handleMissing) {
            try await fixture.broker.revoke(taskKey: first.taskKey, binding: first)
        }
        await expectOwnershipError(.operationInProgress) {
            _ = try await fixture.bind(taskKey: "third-task")
        }
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedReplacementDuringSnapshotNeverPublishesOrRetainsOldLease() async throws {
        let fixture = OwnershipFixture()
        let binding = try await fixture.bind()
        await fixture.transport.onObservation { await fixture.transport.replaceInstance() }
        await expectOwnershipError(.targetReplaced) { _ = try await fixture.snapshot(binding) }
        XCTAssertThrowsError(try binding.lifetime.check())
        await expectOwnershipError(.handleMissing) { _ = try await fixture.snapshot(binding) }
        // A transport fixture reinstates its old incarnation solely to make a
        // leaked reservation observable; the revoked handle must stay revoked.
        await fixture.transport.restoreTarget(fixture.target)
        let rebound = try await fixture.bind(taskKey: "other-task")
        XCTAssertNotEqual(rebound.handle, binding.handle)
        await expectOwnershipError(.handleMissing) { _ = try await fixture.snapshot(binding) }
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedClosureDuringSnapshotReleasesOldLease() async throws {
        let fixture = OwnershipFixture()
        let binding = try await fixture.bind()
        await fixture.transport.onObservation { await fixture.transport.removeUserTarget() }
        await expectOwnershipError(.targetClosed) { _ = try await fixture.snapshot(binding) }
        XCTAssertThrowsError(try binding.lifetime.check())
        await fixture.transport.restoreTarget(fixture.target)
        let rebound = try await fixture.bind(taskKey: "other-task")
        XCTAssertNoThrow(try rebound.lifetime.check())
        await fixture.assertNoLifecycleMutation()
    }

    func testSnapshotTargetRecheckCannotResurrectRevokedBinding() async throws {
        let fixture = OwnershipFixture()
        let binding = try await fixture.bind()
        await fixture.transport.onObservation {
            await fixture.transport.onTargetRead {
                try await fixture.broker.revoke(taskKey: binding.taskKey, binding: binding)
            }
        }
        await expectOwnershipError(.handleMissing) { _ = try await fixture.snapshot(binding) }
        let rebound = try await fixture.bind(taskKey: "other-task")
        XCTAssertThrowsError(try binding.lifetime.check())
        XCTAssertNoThrow(try rebound.lifetime.check())
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedURLCleanupAndShutdownNeverCloseUserTarget() async throws {
        let fixture = OwnershipFixture()
        let binding = try await fixture.bind()
        try await fixture.broker.closeTargets(urls: [fixture.target.url])
        _ = try await fixture.snapshot(binding)
        await fixture.broker.invalidateAll()
        try await fixture.broker.closeTargets(urls: [fixture.target.url])
        XCTAssertThrowsError(try binding.lifetime.check())
        await expectOwnershipError(.handleMissing) { _ = try await fixture.snapshot(binding) }
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedNavigationRejectsOldActionWithoutClosingOrRetargeting() async throws {
        let fixture = OwnershipFixture()
        let initial = try await fixture.snapshot(fixture.bind())
        await fixture.transport.navigate()
        await expectOwnershipError(.staleDocument) {
            try await fixture.press(initial)
        }
        let refreshed = try await fixture.snapshot(initial.binding)
        XCTAssertNotEqual(refreshed.binding.documentEpoch, initial.binding.documentEpoch)
        XCTAssertEqual(refreshed.binding.ownership, .borrowed)
        try await fixture.broker.revoke(taskKey: "task", binding: refreshed.binding)
        await fixture.assertNoLifecycleMutation()
        let mutations = await fixture.transport.mutationCount
        XCTAssertEqual(mutations, 0)
    }

    func testBorrowedTargetReuseInvalidatesHandleWithoutClosingReplacement() async throws {
        let fixture = OwnershipFixture()
        let binding = try await fixture.bind()
        await fixture.transport.replaceInstance()
        await expectOwnershipError(.targetReplaced) { _ = try await fixture.snapshot(binding) }
        XCTAssertThrowsError(try binding.lifetime.check())
        await expectOwnershipError(.handleMissing) { _ = try await fixture.snapshot(binding) }
        await fixture.broker.invalidateAll()
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedReplacementDuringBindNeverPublishesOrCloses() async throws {
        let fixture = OwnershipFixture()
        let lifetime = BrowserTabLifetime()
        await fixture.transport.onObservation { await fixture.transport.replaceInstance() }
        await expectOwnershipError(.targetReplaced) { _ = try await fixture.bind(lifetime: lifetime) }
        XCTAssertThrowsError(try lifetime.check())
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedAuthorizedActionRetainsOneUseSnapshotAndNeverCloses() async throws {
        let fixture = OwnershipFixture()
        let observation = try await fixture.snapshot(fixture.bind())
        try await fixture.press(observation)
        await expectOwnershipError(.staleSnapshot) { try await fixture.press(observation) }
        let mutations = await fixture.transport.mutationCount
        XCTAssertEqual(mutations, 1)
        try await fixture.broker.revoke(taskKey: "task", binding: observation.binding)
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedBindCancellationRevokesLocallyWithoutClosing() async throws {
        let fixture = OwnershipFixture()
        let lifetime = BrowserTabLifetime()
        await fixture.transport.onObservation {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let attempt = Task { try await fixture.bind(lifetime: lifetime) }
        do {
            _ = try await attempt.value
            XCTFail("Cancelled binding must not publish a handle.")
        } catch is CancellationError { }
        XCTAssertThrowsError(try lifetime.check())
        let rebound = try await fixture.bind(taskKey: "other-task")
        XCTAssertNoThrow(try rebound.lifetime.check())
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedShutdownDuringBindRevokesLocallyWithoutClosing() async throws {
        let fixture = OwnershipFixture()
        let lifetime = BrowserTabLifetime()
        await fixture.transport.onObservation { await fixture.broker.invalidateAll() }
        await expectOwnershipError(.handleMissing) { _ = try await fixture.bind(lifetime: lifetime) }
        XCTAssertThrowsError(try lifetime.check())
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedMutationCancellationAndRevokeNeverClose() async throws {
        let fixture = OwnershipFixture()
        let observation = try await fixture.snapshot(fixture.bind())
        await fixture.transport.onMutation {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let attempt = Task { try await fixture.press(observation) }
        do {
            try await attempt.value
            XCTFail("Cancelled mutation must not enqueue input.")
        } catch is CancellationError { }
        try await fixture.broker.revoke(taskKey: "task", binding: observation.binding)
        let mutations = await fixture.transport.mutationCount
        XCTAssertEqual(mutations, 0)
        await fixture.assertNoLifecycleMutation()
    }

    func testBorrowedRevocationDuringMutationCannotEnqueueOrClose() async throws {
        let fixture = OwnershipFixture()
        let observation = try await fixture.snapshot(fixture.bind())
        await fixture.transport.onMutation {
            try await fixture.broker.revoke(taskKey: "task", binding: observation.binding)
        }
        await expectOwnershipError(.staleSnapshot) { try await fixture.press(observation) }
        let mutations = await fixture.transport.mutationCount
        XCTAssertEqual(mutations, 0)
        await fixture.assertNoLifecycleMutation()
    }

    func testBindingOwnershipCannotBeForgedToGainCleanupAuthority() async throws {
        let fixture = OwnershipFixture()
        let binding = try await fixture.bind()
        let forged = BrowserTabBinding(
            handle: binding.handle, taskKey: binding.taskKey,
            browserGeneration: binding.browserGeneration, targetID: binding.targetID,
            targetInstanceToken: binding.targetInstanceToken,
            processIdentifier: binding.processIdentifier, documentEpoch: binding.documentEpoch,
            ownership: .owned, lifetime: binding.lifetime
        )
        await expectOwnershipError(.targetReplaced) {
            try await fixture.broker.revoke(taskKey: "task", binding: forged)
        }
        XCTAssertNoThrow(try binding.lifetime.check())
        try await fixture.broker.revoke(taskKey: "task", binding: binding)
        await fixture.assertNoLifecycleMutation()
    }

    func testOwnedDefaultStillCreatesActivatesAndClosesExactTarget() async throws {
        let fixture = OwnershipFixture(ownership: .owned)
        let broker = BrowserTabSessionBroker(transport: fixture.transport, browserGeneration: UUID())
        let binding = try await broker.open(
            taskKey: "task", processIdentifier: 51, url: fixture.target.url
        )
        XCTAssertEqual(binding.ownership, .owned)
        try await broker.revoke(taskKey: "task", binding: binding)
        let calls = await fixture.transport.lifecycleCalls
        XCTAssertEqual(calls, ["create", "activate:owned-target", "close:owned-target"])
        let borrowed = try await fixture.transport.target(id: fixture.target.targetID)
        XCTAssertNotNil(borrowed, "Owned cleanup must not select the user's same-URL tab.")
    }

    func testOwnedCancellationStillClosesCreatedTargetOnly() async throws {
        let fixture = OwnershipFixture(ownership: .owned)
        let lifetime = BrowserTabLifetime()
        await fixture.transport.onObservation { lifetime.revoke() }
        await expectOwnershipError(.handleMissing) {
            _ = try await fixture.broker.open(
                taskKey: "task", processIdentifier: 51, url: fixture.target.url, lifetime: lifetime
            )
        }
        let calls = await fixture.transport.lifecycleCalls
        XCTAssertEqual(calls, ["create", "activate:owned-target", "close:owned-target"])
        let borrowed = try await fixture.transport.target(id: fixture.target.targetID)
        XCTAssertNotNil(borrowed)
    }
}

private struct OwnershipFixture: Sendable {
    let target = BrowserTarget(
        targetID: "user-target", instanceToken: "user-instance", title: "User tab",
        url: URL(string: "https://example.test/existing")!,
        webSocketURL: URL(string: "ws://127.0.0.1/user-target")!
    )
    let transport: OwnershipTransport
    let broker: BrowserTabSessionBroker

    init(ownership: BrowserTabOwnership = .borrowed) {
        transport = OwnershipTransport(target: target)
        broker = BrowserTabSessionBroker(
            transport: transport, browserGeneration: UUID(), ownership: ownership
        )
    }

    func bind(
        taskKey: String = "task", lifetime: BrowserTabLifetime = BrowserTabLifetime()
    ) async throws -> BrowserTabBinding {
        try await broker.bindBorrowed(taskKey: taskKey, processIdentifier: 51, target: target, lifetime: lifetime)
    }

    func snapshot(_ binding: BrowserTabBinding) async throws -> BrowserTabObservation {
        try await broker.snapshot(taskKey: "task", binding: binding, bundleIdentifier: "com.google.Chrome", query: nil)
    }

    func press(_ observation: BrowserTabObservation) async throws {
        try await broker.perform(
            taskKey: "task", binding: observation.binding, snapshot: observation.snapshot,
            elementIndex: 0, action: "AXPress"
        )
    }

    func assertNoLifecycleMutation(file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await transport.lifecycleCalls
        XCTAssertTrue(calls.isEmpty, "Unexpected lifecycle transport calls: \(calls)", file: file, line: line)
    }
}

private actor OwnershipTransport: BrowserTabTransport {
    private var targets: [String: BrowserTarget]
    private var loaderID = "initial-document"
    private var targetReadHook: (@Sendable () async throws -> Void)?
    private var observationHook: (@Sendable () async throws -> Void)?
    private var mutationHook: (@Sendable () async throws -> Void)?
    private(set) var lifecycleCalls = [String]()
    private(set) var mutationCount = 0
    private(set) var targetReadCount = 0
    private(set) var observationCount = 0

    init(target: BrowserTarget) { targets = [target.targetID: target] }

    func onObservation(_ hook: @escaping @Sendable () async throws -> Void) { observationHook = hook }
    func onTargetRead(_ hook: @escaping @Sendable () async throws -> Void) { targetReadHook = hook }
    func onMutation(_ hook: @escaping @Sendable () async throws -> Void) { mutationHook = hook }
    func restoreTarget(_ target: BrowserTarget) { targets[target.targetID] = target }
    func removeUserTarget() { targets.removeValue(forKey: "user-target") }
    func navigate() { loaderID = "navigated-document" }
    func replaceInstance() {
        guard let prior = targets["user-target"] else { return }
        targets[prior.targetID] = BrowserTarget(
            targetID: prior.targetID, instanceToken: "replacement", title: prior.title,
            url: prior.url, webSocketURL: prior.webSocketURL
        )
    }

    func createTarget(url: URL) async throws -> BrowserTarget {
        lifecycleCalls.append("create")
        let target = BrowserTarget(
            targetID: "owned-target", instanceToken: "owned-instance", title: "Owned tab",
            url: url, webSocketURL: URL(string: "ws://127.0.0.1/owned-target")!
        )
        targets[target.targetID] = target
        return target
    }

    func target(id: String) async throws -> BrowserTarget? {
        targetReadCount += 1
        let hook = targetReadHook
        targetReadHook = nil
        try await hook?()
        return targets[id]
    }
    func activateTarget(id: String) async throws { lifecycleCalls.append("activate:\(id)") }
    func closeTarget(target: BrowserTarget) async throws {
        lifecycleCalls.append("close:\(target.targetID)")
        targets.removeValue(forKey: target.targetID)
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        observationCount += 1
        let hook = observationHook
        observationHook = nil
        try await hook?()
        return BrowserDocumentObservation(
            loaderID: loaderID, title: target.title, url: target.url,
            nodes: [BrowserDocumentNode(
                backendNodeID: 1, role: "button", name: "Synthetic action", value: nil,
                isDisabled: false, isReadOnly: false, isIgnored: false
            )]
        )
    }

    func press(
        target: BrowserTarget, backendNodeID: Int64,
        document: BrowserDocumentObservation, permit: BrowserMutationPermit
    ) async throws {
        let hook = mutationHook
        mutationHook = nil
        try await hook?()
        try permit.commit { mutationCount += 1 }
    }

    func setText(
        target: BrowserTarget, backendNodeID: Int64, text: String,
        document: BrowserDocumentObservation, permit: BrowserMutationPermit
    ) async throws {
        try await press(target: target, backendNodeID: backendNodeID, document: document, permit: permit)
    }
}

private func expectOwnershipError(
    _ expected: BrowserTabBrokerError,
    file: StaticString = #filePath, line: UInt = #line,
    operation: @Sendable () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? BrowserTabBrokerError, expected, file: file, line: line)
    }
}

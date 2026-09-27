import Darwin
import Foundation
import XCTest
@testable import Mactopus

@MainActor
final class ChromeTabBrokerFreshLaunchTests: XCTestCase {
    private let stopIssue = "SIGKILL failed for owned group 58201: result=-1 errno=\(EINVAL)"
    private let profileIssue = "injected profile-removal failure"

    func testPostSpawnStopAndProfileFailuresRetainOwnershipAndBlockRetry() async throws {
        let fixture = await makeFixture(
            result: .init(rootReaped: true, groupGone: true, issues: [stopIssue]),
            removalIssue: profileIssue
        )
        let error = await launchFailure(fixture.broker)
        XCTAssertTrue(error.contains("injected post-spawn launch failure"))
        XCTAssertTrue(error.contains(stopIssue))
        XCTAssertTrue(error.contains(profileIssue))
        let first = await fixture.audit.snapshot()
        let ownership = await fixture.broker.ownership()
        XCTAssertEqual(first.resolutions, 1)
        XCTAssertEqual(first.constructedIDs.count, 1)
        XCTAssertEqual(first.stoppedIDs, first.constructedIDs)
        XCTAssertEqual(first.ownershipAtFailure, ownership)
        XCTAssertEqual(ownership?.processGroupID, 58201)
        XCTAssertEqual(first.removedDirectories, [try XCTUnwrap(ownership?.profileDirectory)])

        let retry = await launchFailure(fixture.broker)
        XCTAssertTrue(retry.contains("prior owned cleanup is incomplete"))
        let afterRetry = await fixture.audit.snapshot()
        XCTAssertEqual(afterRetry, first)
        let retained = await fixture.broker.ownership()
        XCTAssertEqual(retained, ownership)

        let shutdown = await fixture.broker.shutdown()
        XCTAssertFalse(shutdown.succeeded)
        XCTAssertTrue(shutdown.issues.contains(stopIssue))
        XCTAssertTrue(shutdown.issues.contains(profileIssue))
        XCTAssertEqual(shutdown.ownership, [try XCTUnwrap(ownership)])
        let repeated = await fixture.broker.shutdown()
        XCTAssertEqual(repeated, shutdown)
    }

    func testPostSpawnStopFailureStillBlocksRetryAfterSuccessfulProfileRemoval() async throws {
        let fixture = await makeFixture(
            result: .init(rootReaped: true, groupGone: true, issues: [stopIssue]),
            removalIssue: nil
        )
        let error = await launchFailure(fixture.broker)
        XCTAssertTrue(error.contains(stopIssue))
        let first = await fixture.audit.snapshot()
        XCTAssertEqual(first.constructedIDs.count, 1)
        XCTAssertEqual(first.stoppedIDs, first.constructedIDs)
        XCTAssertEqual(first.removedDirectories.count, 1)
        let ownership = await fixture.broker.ownership()
        XCTAssertNotNil(ownership)
        let retry = await launchFailure(fixture.broker)
        XCTAssertTrue(retry.contains("prior owned cleanup is incomplete"))
        let afterRetry = await fixture.audit.snapshot()
        XCTAssertEqual(afterRetry, first)
        let report = await fixture.broker.shutdown()
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.issues.contains(stopIssue))
    }

    func testPostSpawnProfileFailureIsPreservedEvenWhenStopSucceeds() async throws {
        let fixture = await makeFixture(
            result: .init(rootReaped: true, groupGone: true, issues: []),
            removalIssue: profileIssue
        )
        let error = await launchFailure(fixture.broker)
        XCTAssertTrue(error.contains("injected post-spawn launch failure"))
        XCTAssertTrue(error.contains(profileIssue))
        let first = await fixture.audit.snapshot()
        XCTAssertEqual(first.constructedIDs.count, 1)
        XCTAssertEqual(first.stoppedIDs, first.constructedIDs)
        let retry = await launchFailure(fixture.broker)
        XCTAssertTrue(retry.contains("prior owned cleanup is incomplete"))
        let afterRetry = await fixture.audit.snapshot()
        XCTAssertEqual(afterRetry, first)
        let report = await fixture.broker.shutdown()
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.issues.contains(profileIssue))
    }

    func testPostSpawnMissingProcessProofNeverAttemptsProfileRemoval() async throws {
        let fixture = await makeFixture(
            result: .init(rootReaped: false, groupGone: false, issues: ["injected surviving group"]),
            removalIssue: profileIssue
        )
        let error = await launchFailure(fixture.broker)
        XCTAssertTrue(error.contains("injected surviving group"))
        XCTAssertFalse(error.contains(profileIssue)) // Removal must not have been attempted.
        let first = await fixture.audit.snapshot()
        XCTAssertEqual(first.constructedIDs.count, 1)
        XCTAssertEqual(first.stoppedIDs, first.constructedIDs)
        XCTAssertTrue(first.removedDirectories.isEmpty)
        let retry = await launchFailure(fixture.broker)
        XCTAssertTrue(retry.contains("prior owned cleanup is incomplete"))
        let afterRetry = await fixture.audit.snapshot()
        XCTAssertEqual(afterRetry, first)
        let report = await fixture.broker.shutdown()
        XCTAssertFalse(report.succeeded)
        let afterShutdown = await fixture.audit.snapshot()
        XCTAssertTrue(afterShutdown.removedDirectories.isEmpty)
    }

    func testPostSpawnSuccessfulCleanupAllowsFreshConstructionOnRetry() async throws {
        let fixture = await makeFixture(
            result: .init(rootReaped: true, groupGone: true, issues: []),
            removalIssue: nil
        )
        for _ in 0..<2 {
            let error = await launchFailure(fixture.broker)
            XCTAssertEqual(error, "injected post-spawn launch failure")
            let ownership = await fixture.broker.ownership()
            XCTAssertNil(ownership)
        }
        let calls = await fixture.audit.snapshot()
        XCTAssertEqual(calls.resolutions, 2)
        XCTAssertEqual(Set(calls.constructedIDs).count, 2)
        XCTAssertEqual(calls.stoppedIDs, calls.constructedIDs)
        XCTAssertEqual(calls.removedDirectories.count, 2)
        let report = await fixture.broker.shutdown()
        XCTAssertTrue(report.succeeded)
    }

    func testShutdownWhileDidSpawnIsSuspendedOwnsCleanupAndPreventsPublication() async throws {
        for incompleteStop in [false, true] {
            let pause = FreshLaunchPause()
            let result = OwnedChildProcess.StopResult(
                rootReaped: !incompleteStop, groupGone: !incompleteStop,
                issues: incompleteStop ? ["injected suspended-child stop failure"] : []
            )
            let broker = ChromeTabBroker(
                removeProfile: { directory in await pause.remove(directory) },
                launchOperations: .init(
                    resolveExecutable: { URL(fileURLWithPath: "/not-created/Google Chrome") },
                    createProfile: { _ in },
                    spawn: { _, _ in SuspendedLaunchChild(result: result, pause: pause) },
                    didSpawn: { child, directory in
                        guard let constructed = child as? SuspendedLaunchChild else {
                            throw FreshLaunchError.wrongChild
                        }
                        await pause.suspend(constructionID: constructed.constructionID, directory: directory)
                    }
                )
            )
            let launch = Task { try await broker.ensureBrowser() }
            await pause.waitUntilEntered()
            let owned = await broker.ownership()
            XCTAssertEqual(owned?.processGroupID, 59301)
            // Shutdown runs while the post-construction hook remains blocked.
            let shutdown = await broker.shutdown()
            XCTAssertEqual(shutdown.succeeded, !incompleteStop)
            XCTAssertEqual(shutdown.ownership.first, owned)
            let afterShutdown = await pause.snapshot()
            XCTAssertEqual(afterShutdown.stopCalls, 1)
            XCTAssertEqual(afterShutdown.removalCalls, incompleteStop ? 0 : 1)
            let disposed = await broker.ownership()
            XCTAssertNil(disposed)

            await pause.release()
            do {
                _ = try await launch.value
                XCTFail("A resumed startup must not publish a browser after shutdown.")
            } catch {
                if incompleteStop {
                    XCTAssertTrue(error.localizedDescription.contains("injected suspended-child stop failure"))
                } else {
                    XCTAssertEqual(error as? BrowserTabBrokerError, .handleMissing)
                }
            }
            let afterResume = await pause.snapshot()
            XCTAssertEqual(afterResume, afterShutdown) // No second stop or profile removal.
            let repeated = await broker.shutdown()
            XCTAssertEqual(repeated, shutdown)
            let retry = await launchFailure(broker)
            XCTAssertTrue(retry.contains("shut down"))
            let afterRetry = await pause.snapshot()
            XCTAssertEqual(afterRetry, afterShutdown)
            let finalOwnership = await broker.ownership()
            XCTAssertNil(finalOwnership)
        }
    }

    func testPreChildSpawnThrowAndProfileFailureAreBothRetainedAndBlockRetry() async throws {
        let audit = FreshLaunchAudit(removalIssue: profileIssue)
        let broker = ChromeTabBroker(
            removeProfile: { directory in await audit.remove(directory) },
            launchOperations: .init(
                resolveExecutable: { await audit.resolveExecutable() },
                createProfile: { _ in },
                spawn: { _, _ in throw FreshLaunchError.preSpawn },
                didSpawn: { _, _ in throw FreshLaunchError.wrongChild }
            )
        )
        let firstFailure = await launchFailure(broker)
        XCTAssertTrue(firstFailure.contains("injected pre-child spawn failure"))
        XCTAssertTrue(firstFailure.contains(profileIssue))
        let first = await audit.snapshot()
        XCTAssertEqual(first.resolutions, 1)
        XCTAssertTrue(first.constructedIDs.isEmpty)
        XCTAssertTrue(first.stoppedIDs.isEmpty)
        XCTAssertEqual(first.removedDirectories.count, 1)
        let ownership = await broker.ownership()
        XCTAssertNil(ownership) // A profile is retained, not an invented process identity.

        let retry = await launchFailure(broker)
        XCTAssertTrue(retry.contains("prior owned cleanup is incomplete"))
        let afterRetry = await audit.snapshot()
        XCTAssertEqual(afterRetry, first)
        let shutdown = await broker.shutdown()
        XCTAssertFalse(shutdown.succeeded)
        XCTAssertTrue(shutdown.issues.contains(profileIssue))
        let final = await audit.snapshot()
        XCTAssertEqual(final.removedDirectories.count, 2)
        XCTAssertTrue(final.stoppedIDs.isEmpty)
        let repeated = await broker.shutdown()
        XCTAssertEqual(repeated, shutdown)
        let afterRepeated = await audit.snapshot()
        XCTAssertEqual(afterRepeated, final)
    }

    private func makeFixture(
        result: OwnedChildProcess.StopResult, removalIssue: String?
    ) async -> FreshLaunchFixture {
        let audit = FreshLaunchAudit(removalIssue: removalIssue)
        let broker = ChromeTabBroker(
            // No seeded initialBrowser and no throwing willLaunchBrowser hook.
            removeProfile: { directory in await audit.remove(directory) },
            launchOperations: .init(
                resolveExecutable: { await audit.resolveExecutable() },
                createProfile: { _ in },
                spawn: { _, _ in
                    // Construct a NEW injected child inside the real launch branch.
                    // The live factory instead constructs OwnedChildProcess.
                    FreshlyConstructedChild(result: result, audit: audit)
                },
                didSpawn: { child, directory in
                    try await audit.failAfterSpawn(child: child, directory: directory)
                }
            )
        )
        await audit.observeOwnershipAtFailure { await broker.ownership() }
        return FreshLaunchFixture(broker: broker, audit: audit)
    }

    private func launchFailure(_ broker: ChromeTabBroker) async -> String {
        do {
            _ = try await broker.ensureBrowser()
            XCTFail("The post-spawn hook must throw before real DevTools I/O.")
            return "unexpected success"
        } catch {
            return error.localizedDescription
        }
    }
}

private struct FreshLaunchFixture: Sendable {
    let broker: ChromeTabBroker
    let audit: FreshLaunchAudit
}

private enum FreshLaunchError: Error, LocalizedError {
    case preSpawn
    case postSpawn
    case wrongChild
    case ownershipMissing

    var errorDescription: String? {
        switch self {
        case .preSpawn: "injected pre-child spawn failure"
        case .postSpawn: "injected post-spawn launch failure"
        case .wrongChild: "the launch factory did not construct the injected child"
        case .ownershipMissing: "fresh child ownership was not published before the post-spawn hook"
        }
    }
}

private actor FreshlyConstructedChild: BrowserOwnedChild {
    nonisolated let processIdentifier: Int32 = 58201
    nonisolated let isRunning = true
    nonisolated let constructionID = UUID()
    private let result: OwnedChildProcess.StopResult
    private let audit: FreshLaunchAudit

    init(result: OwnedChildProcess.StopResult, audit: FreshLaunchAudit) {
        self.result = result
        self.audit = audit
    }

    func stop() async -> OwnedChildProcess.StopResult {
        await audit.recordStop(constructionID)
        return result
    }
}

private actor FreshLaunchAudit {
    struct Snapshot: Equatable, Sendable {
        var resolutions = 0
        var constructedIDs = [UUID]()
        var stoppedIDs = [UUID]()
        var removedDirectories = [URL]()
        var ownershipAtFailure: ChromeTabBroker.Ownership?
    }

    private var recorded = Snapshot()
    private let removalIssue: String?
    private var ownershipProbe: (@Sendable () async -> ChromeTabBroker.Ownership?)?

    init(removalIssue: String?) { self.removalIssue = removalIssue }

    func observeOwnershipAtFailure(
        _ probe: @escaping @Sendable () async -> ChromeTabBroker.Ownership?
    ) {
        ownershipProbe = probe
    }

    func resolveExecutable() -> URL {
        recorded.resolutions += 1
        return URL(fileURLWithPath: "/not-created/Google Chrome")
    }

    func failAfterSpawn(child: any BrowserOwnedChild, directory: URL) async throws {
        guard let constructed = child as? FreshlyConstructedChild else {
            throw FreshLaunchError.wrongChild
        }
        recorded.constructedIDs.append(constructed.constructionID)
        // Clear the capturing closure before awaiting to avoid an ownership cycle.
        if let probe = ownershipProbe {
            ownershipProbe = nil
            let ownership = await probe()
            recorded.ownershipAtFailure = ownership
            guard ownership?.processGroupID == constructed.processIdentifier,
                  ownership?.profileDirectory == directory else {
                throw FreshLaunchError.ownershipMissing
            }
        }
        throw FreshLaunchError.postSpawn
    }

    func recordStop(_ id: UUID) { recorded.stoppedIDs.append(id) }

    func remove(_ directory: URL) -> String? {
        recorded.removedDirectories.append(directory)
        return removalIssue
    }

    func snapshot() -> Snapshot { recorded }
}

/// Continuation barriers, not sleeps, control the actual caller interleaving.
private actor FreshLaunchPause {
    struct Snapshot: Equatable, Sendable {
        var constructionID: UUID?
        var directory: URL?
        var stopCalls = 0
        var removalCalls = 0
    }
    private var recorded = Snapshot()
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend(constructionID: UUID, directory: URL) async {
        recorded.constructionID = constructionID
        recorded.directory = directory
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

    func stopped() { recorded.stopCalls += 1 }
    func remove(_ directory: URL) -> String? {
        recorded.removalCalls += 1
        return nil
    }
    func snapshot() -> Snapshot { recorded }
}

private actor SuspendedLaunchChild: BrowserOwnedChild {
    nonisolated let processIdentifier: Int32 = 59301
    nonisolated let isRunning = true
    nonisolated let constructionID = UUID()
    private let result: OwnedChildProcess.StopResult
    private let pause: FreshLaunchPause

    init(result: OwnedChildProcess.StopResult, pause: FreshLaunchPause) {
        self.result = result
        self.pause = pause
    }

    func stop() async -> OwnedChildProcess.StopResult {
        await pause.stopped()
        return result
    }
}

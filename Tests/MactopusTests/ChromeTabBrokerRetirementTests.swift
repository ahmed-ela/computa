import Foundation
import XCTest
@testable import Mactopus

@MainActor
final class ChromeTabBrokerRetirementTests: XCTestCase {
    func testShutdownJoinsRetirementSuspendedInStop() async throws {
        let results: [OwnedChildProcess.StopResult] = [
            .init(rootReaped: true, groupGone: true, issues: []),
            .init(rootReaped: true, groupGone: true, issues: ["unexpected stop issue"]),
            .init(rootReaped: false, groupGone: false, issues: ["surviving group"]),
        ]
        for result in results {
            let audit = RetirementPause(holdStop: true, holdRemoval: false, firstRemovalIssue: nil)
            let broker = makeBroker(result: result, audit: audit)
            let start = Task { try await broker.ensureBrowser() }
            await audit.waitForStop()
            let observedOwnership = await broker.ownership()
            let ownership = try XCTUnwrap(observedOwnership)
            let shutdown = await broker.beginShutdown()
            await audit.releaseStop()
            let report = await shutdown.value
            await expectNoPublication(start)
            let counts = await audit.counts()
            XCTAssertEqual(counts.stops, 1)
            XCTAssertEqual(counts.removals, result.rootReaped && result.groupGone ? 1 : 0)
            XCTAssertEqual(counts.launches, 0)
            XCTAssertEqual(report.succeeded, result.succeeded)
            for issue in result.issues { XCTAssertTrue(report.issues.contains(issue)) }
            XCTAssertEqual(report.ownership, [ownership])
            let repeated = await broker.shutdown()
            XCTAssertEqual(repeated, report)
            let finalOwnership = await broker.ownership()
            XCTAssertNil(finalOwnership)
            do {
                _ = try await broker.ensureBrowser()
                XCTFail("A shut-down broker must not restart.")
            } catch {}
            let finalCounts = await audit.counts()
            XCTAssertEqual(finalCounts, counts)
        }
    }

    func testShutdownJoinsRetirementSuspendedInRemoval() async throws {
        let audit = RetirementPause(holdStop: false, holdRemoval: true, firstRemovalIssue: nil)
        let broker = makeBroker(result: .init(rootReaped: true, groupGone: true, issues: []), audit: audit)
        let start = Task { try await broker.ensureBrowser() }
        await audit.waitForRemoval()
        let shutdown = await broker.beginShutdown()
        await audit.releaseRemoval()
        let report = await shutdown.value
        await expectNoPublication(start)
        XCTAssertTrue(report.succeeded)
        let counts = await audit.counts()
        XCTAssertEqual(counts.stops, 1)
        XCTAssertEqual(counts.removals, 1)
        XCTAssertEqual(counts.launches, 0)
    }

    func testSequentialRemovalRetryRetainsTheFirstFailure() async throws {
        let issue = "first retirement profile removal failed"
        let audit = RetirementPause(holdStop: false, holdRemoval: true, firstRemovalIssue: issue)
        let broker = makeBroker(result: .init(rootReaped: true, groupGone: true, issues: []), audit: audit)
        let start = Task { try await broker.ensureBrowser() }
        await audit.waitForRemoval()
        let shutdown = await broker.beginShutdown()
        await audit.releaseRemoval()
        let report = await shutdown.value
        await expectNoPublication(start)
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.issues.contains(issue))
        let counts = await audit.counts()
        XCTAssertEqual(counts.stops, 1)
        XCTAssertEqual(counts.removals, 2)
        XCTAssertEqual(counts.maximumConcurrentRemovals, 1)
        let repeated = await broker.shutdown()
        XCTAssertEqual(repeated, report)
    }

    private func makeBroker(result: OwnedChildProcess.StopResult, audit: RetirementPause) -> ChromeTabBroker {
        let transport = SystemChromeDevToolsTransport(port: 1)
        let generation = UUID()
        let initial = ChromeTabBroker.BrowserProcess(
            process: RetirementChild(result: result, audit: audit),
            dataDirectory: URL(fileURLWithPath: "/not-created/LocalCodexBrowserBroker-retirement-test"),
            generation: generation, transport: transport,
            sessions: BrowserTabSessionBroker(transport: transport, browserGeneration: generation)
        )
        return ChromeTabBroker(
            initialBrowser: initial, removeProfile: { _ in await audit.remove() },
            willLaunchBrowser: {
                await audit.launched()
                throw RetirementTestError.unexpectedLaunch
            }
        )
    }

    private func expectNoPublication(_ start: Task<ChromeTabBroker.BrowserProcess, Error>) async {
        do {
            _ = try await start.value
            XCTFail("Retirement must not publish a replacement after shutdown.")
        } catch {}
    }
}

private enum RetirementTestError: Error { case unexpectedLaunch }

// No process, filesystem, network request, or wall-clock sleep occurs in these tests.
private actor RetirementChild: BrowserOwnedChild {
    nonisolated let processIdentifier: Int32 = 61401
    nonisolated let isRunning = false
    private let result: OwnedChildProcess.StopResult
    private let audit: RetirementPause
    init(result: OwnedChildProcess.StopResult, audit: RetirementPause) {
        self.result = result
        self.audit = audit
    }
    func stop() async -> OwnedChildProcess.StopResult {
        await audit.stopped()
        return result
    }
}

private actor RetirementPause {
    struct Counts: Equatable, Sendable {
        var stops = 0
        var removals = 0
        var launches = 0
        var maximumConcurrentRemovals = 0
    }
    private var value = Counts()
    private var concurrentRemovals = 0
    private let holdStop: Bool
    private let holdRemoval: Bool
    private let firstRemovalIssue: String?
    private var stopEntry: CheckedContinuation<Void, Never>?
    private var stopRelease: CheckedContinuation<Void, Never>?
    private var removalEntry: CheckedContinuation<Void, Never>?
    private var removalRelease: CheckedContinuation<Void, Never>?

    init(holdStop: Bool, holdRemoval: Bool, firstRemovalIssue: String?) {
        self.holdStop = holdStop
        self.holdRemoval = holdRemoval
        self.firstRemovalIssue = firstRemovalIssue
    }
    func stopped() async {
        value.stops += 1
        if holdStop {
            await withCheckedContinuation { continuation in
                stopRelease = continuation
                stopEntry?.resume()
                stopEntry = nil
            }
        } else {
            stopEntry?.resume()
            stopEntry = nil
        }
    }
    func waitForStop() async {
        if value.stops > 0 { return }
        await withCheckedContinuation { stopEntry = $0 }
    }
    func releaseStop() {
        stopRelease?.resume()
        stopRelease = nil
    }
    func remove() async -> String? {
        value.removals += 1
        let attempt = value.removals
        concurrentRemovals += 1
        value.maximumConcurrentRemovals = max(value.maximumConcurrentRemovals, concurrentRemovals)
        defer { concurrentRemovals -= 1 }
        if holdRemoval && attempt == 1 {
            await withCheckedContinuation { continuation in
                removalRelease = continuation
                removalEntry?.resume()
                removalEntry = nil
            }
        }
        return attempt == 1 ? firstRemovalIssue : nil
    }
    func waitForRemoval() async {
        if value.removals > 0 { return }
        await withCheckedContinuation { removalEntry = $0 }
    }
    func releaseRemoval() {
        removalRelease?.resume()
        removalRelease = nil
    }
    func launched() { value.launches += 1 }
    func counts() -> Counts { value }
}

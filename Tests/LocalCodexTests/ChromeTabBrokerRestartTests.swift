import Darwin
import Foundation
import XCTest
@testable import LocalCodex

@MainActor
final class ChromeTabBrokerRestartTests: XCTestCase {
    func testUnexpectedStopIssueBlocksActualRestartBeforeProfileRemovalOrLaunch() async throws {
        let issue = "SIGKILL failed for owned group 48101: result=-1 errno=\(EINVAL)"
        let fixture = makeFixture(.init(rootReaped: true, groupGone: true, issues: [issue]))
        for _ in 0..<2 {
            do {
                _ = try await fixture.broker.ensureBrowser()
                XCTFail("An unsuccessful stop must not permit replacement.")
            } catch let error as BrowserTabBrokerError {
                guard case .browserUnavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        let calls = await fixture.audit.calls()
        XCTAssertEqual(calls, [])
        let ownership = await fixture.broker.ownership()
        XCTAssertEqual(ownership?.processGroupID, 48101)
        XCTAssertEqual(ownership?.profileDirectory, fixture.directory)

        // Disposal may delete the now-safe profile, but must not erase EINVAL.
        let report = await fixture.broker.shutdown()
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.issues.contains(issue))
        let afterShutdown = await fixture.audit.calls()
        XCTAssertEqual(afterShutdown, ["remove"])
        let repeated = await fixture.broker.shutdown()
        XCTAssertEqual(report, repeated)
    }

    func testResolvedSignalDiagnosticsDoNotBlockSuccessfulRetirement() async throws {
        let fixture = makeFixture(.init(
            rootReaped: true, groupGone: true, issues: [],
            signalDiagnostics: ["SIGKILL returned EPERM; final postconditions verified"]
        ))
        do {
            _ = try await fixture.broker.ensureBrowser()
            XCTFail("The injected boundary must stop before any real Chrome launch.")
        } catch RestartTestError.launchBoundary {
            // Reaching this boundary proves the real caller authorized replacement.
        }
        let calls = await fixture.audit.calls()
        XCTAssertEqual(calls, ["remove", "launch"])
        let ownership = await fixture.broker.ownership()
        XCTAssertNil(ownership)
        let report = await fixture.broker.shutdown()
        XCTAssertTrue(report.succeeded)
    }

    func testMissingPostconditionsBlockRestartAndProfileDeletion() async throws {
        for (reaped, gone) in [(false, true), (true, false), (false, false)] {
            let fixture = makeFixture(.init(
                rootReaped: reaped, groupGone: gone, issues: ["incomplete owned cleanup"]
            ))
            do {
                _ = try await fixture.broker.ensureBrowser()
                XCTFail("Missing process proof must block replacement.")
            } catch let error as BrowserTabBrokerError {
                guard case .browserUnavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            let beforeShutdown = await fixture.audit.calls()
            XCTAssertTrue(beforeShutdown.isEmpty)
            let report = await fixture.broker.shutdown()
            XCTAssertFalse(report.succeeded)
            let afterShutdown = await fixture.audit.calls()
            XCTAssertTrue(afterShutdown.isEmpty)
        }
    }

    func testProfileRemovalFailureBlocksActualRestartAndRetainsOwnership() async throws {
        let fixture = makeFixture(
            .init(rootReaped: true, groupGone: true, issues: []),
            removalIssue: "profile absence is unverifiable"
        )
        do {
            _ = try await fixture.broker.ensureBrowser()
            XCTFail("Replacement must not start after a profile-cleanup failure.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .browserUnavailable("profile absence is unverifiable"))
        }
        let calls = await fixture.audit.calls()
        XCTAssertEqual(calls, ["remove"])
        let ownership = await fixture.broker.ownership()
        XCTAssertEqual(ownership?.profileDirectory, fixture.directory)
        let report = await fixture.broker.shutdown()
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.issues.contains("profile absence is unverifiable"))
    }

    func testShutdownDuringRetirementNeverReachesLaunchBoundary() async throws {
        let fixture = makeFixture(.init(rootReaped: true, groupGone: true, issues: []))
        await fixture.audit.onRemoval {
            // Request shutdown here, but do not await the disposal that is
            // itself waiting for this injected removal callback to return.
            _ = await fixture.broker.beginShutdown()
        }
        do {
            _ = try await fixture.broker.ensureBrowser()
            XCTFail("Shutdown must prevent replacement.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .handleMissing)
        }
        let calls = await fixture.audit.calls()
        XCTAssertFalse(calls.contains("launch"))
        let report = await fixture.broker.shutdown()
        XCTAssertTrue(report.succeeded)
    }

    private func makeFixture(
        _ result: OwnedChildProcess.StopResult,
        removalIssue: String? = nil
    ) -> RestartFixture {
        let directory = URL(fileURLWithPath: "/not-created/LocalCodexBrowserBroker-restart-test")
        let audit = RestartAudit(removalIssue: removalIssue)
        let process = RestartChild(result: result)
        let generation = UUID()
        // These objects are inert: invalidateAll() has no entries to revoke,
        // and the throwing launch boundary prevents discovery or network access.
        let transport = SystemChromeDevToolsTransport(port: 1)
        let initial = ChromeTabBroker.BrowserProcess(
            process: process, dataDirectory: directory, generation: generation,
            transport: transport,
            sessions: BrowserTabSessionBroker(transport: transport, browserGeneration: generation)
        )
        let broker = ChromeTabBroker(
            initialBrowser: initial,
            removeProfile: { _ in await audit.remove() },
            willLaunchBrowser: { try await audit.launch() }
        )
        return RestartFixture(broker: broker, audit: audit, directory: directory)
    }
}

private struct RestartFixture: Sendable {
    let broker: ChromeTabBroker
    let audit: RestartAudit
    let directory: URL
}

private enum RestartTestError: Error {
    case launchBoundary
}

private actor RestartChild: BrowserOwnedChild {
    nonisolated let processIdentifier: Int32 = 48101
    nonisolated let isRunning = false
    private let result: OwnedChildProcess.StopResult

    init(result: OwnedChildProcess.StopResult) { self.result = result }
    func stop() async -> OwnedChildProcess.StopResult { result }
}

private actor RestartAudit {
    private var recorded = [String]()
    private let removalIssue: String?
    private var removalHook: (@Sendable () async -> Void)?

    init(removalIssue: String?) { self.removalIssue = removalIssue }

    func onRemoval(_ hook: @escaping @Sendable () async -> Void) {
        removalHook = hook
    }

    func remove() async -> String? {
        recorded.append("remove")
        let hook = removalHook
        removalHook = nil
        if let hook { await hook() }
        return removalIssue
    }

    func launch() throws {
        recorded.append("launch")
        throw RestartTestError.launchBoundary
    }

    func calls() -> [String] { recorded }
}

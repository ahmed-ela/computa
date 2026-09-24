import Foundation
import XCTest

@MainActor
final class ReadOnlyForegroundVerifierTests: XCTestCase {
    private let address = "http://127.0.0.1/fixture?run=TEST&tab=B"

    func testTransientFocusStatesRecoverWithoutAnActivationDependency() async throws {
        let script = ForegroundScript([
            probe(focus: .notWindow),
            probe(focus: .applicationNotFocused),
            probe(focus: .windowNotFocused),
            exact(), exact(),
        ])
        let report = try await verify(script)
        XCTAssertTrue(report.activeTabPreserved)
        XCTAssertEqual(report.samples.map(\.probe.focus), [
            .notWindow, .applicationNotFocused, .windowNotFocused, .focused, .focused,
        ])
        XCTAssertEqual(script.reads, 5)
        XCTAssertEqual(script.delays.count, 4)
        XCTAssertEqual(report.mode, "read_only_active_tab_no_activation")
        XCTAssertEqual(script.reports.last, report)
        XCTAssertTrue(script.events.allSatisfy { ["read", "delay", "persist"].contains($0) })
    }

    func testTransientAXErrorAndAddressEvidenceAreRetained() async throws {
        var failedRead = exact()
        failedRead.focus = .unavailable
        failedRead.readError = "injected cannotComplete"
        failedRead.accessibilityErrorCode = -1
        let script = ForegroundScript([failedRead, exact(), exact()])
        let report = try await verify(script)
        XCTAssertTrue(report.activeTabPreserved)
        XCTAssertEqual(report.samples[0].probe, failedRead)
        XCTAssertEqual(script.reports[1].samples, [report.samples[0]])
        XCTAssertEqual(report.samples[0].probe.addressValues, [address])
    }

    func testMissingAndAmbiguousAddressesRequireFreshExactEvidence() async throws {
        var ambiguous = exact()
        ambiguous.addressFieldCount = 2
        ambiguous.exactAddressMatches = 2
        ambiguous.addressValues = [address, address]
        let script = ForegroundScript([probe(focus: .focused), ambiguous, exact(), exact()])
        let report = try await verify(script)
        XCTAssertTrue(report.activeTabPreserved)
        XCTAssertEqual(report.samples.map(\.probe.exactAddressMatches), [0, 2, 1, 1])
        XCTAssertEqual(report.consecutiveMatches, 2)
    }

    func testPersistentMissingAddressExhaustsTheFixedAttemptBudget() async throws {
        let script = ForegroundScript([probe(focus: .applicationNotFocused)])
        let report = try await verify(script)
        XCTAssertFalse(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .exhausted)
        XCTAssertEqual(report.samples.count, 20)
        XCTAssertEqual(script.reads, 20)
        XCTAssertEqual(script.delays.count, 19)
        XCTAssertEqual(script.reports.last, report)
    }

    func testKnownWrongForegroundAddressCannotBeHiddenByLaterB() async throws {
        var wrong = exact()
        wrong.exactAddressMatches = 0
        wrong.addressValues = ["http://127.0.0.1/fixture?run=TEST&tab=A"]
        let script = ForegroundScript([wrong, exact(), exact()])
        let report = try await verify(script)
        XCTAssertFalse(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .contradictoryAddress)
        XCTAssertEqual(script.reads, 1)
        XCTAssertTrue(script.delays.isEmpty)
        XCTAssertEqual(report.samples[0].probe.addressValues, wrong.addressValues)
    }

    func testInconclusiveProbeResetsConsecutiveMatches() async throws {
        let script = ForegroundScript([exact(), probe(focus: .windowNotFocused), exact(), exact()])
        let report = try await verify(script)
        XCTAssertTrue(report.activeTabPreserved)
        XCTAssertEqual(script.reads, 4)
        XCTAssertEqual(script.reports.map(\.consecutiveMatches), [0, 1, 0, 1, 2])
    }

    func testExactReadFinishingAfterDeadlineCannotPass() async throws {
        let script = ForegroundScript([exact(), exact()])
        script.readDuration = .seconds(3)
        let report = try await verify(script)
        XCTAssertFalse(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .deadlineExceeded)
        XCTAssertEqual(script.reads, 2)
        XCTAssertEqual(report.samples.count, 2)
        XCTAssertGreaterThanOrEqual(report.samples[1].finishedMilliseconds, 5_000)
    }

    func testDeadlineReachedDuringDelayPreventsAnotherRead() async throws {
        let script = ForegroundScript([probe(focus: .notWindow), exact(), exact()])
        script.extraDelay = .seconds(5)
        let report = try await verify(script)
        XCTAssertFalse(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .deadlineExceeded)
        XCTAssertEqual(script.reads, 1)
        XCTAssertEqual(script.delays.count, 1)
        XCTAssertEqual(script.reports.last, report)
    }

    func testMissingProcessAndNontransientErrorsFailWithoutRetry() async throws {
        for message in ["bound process missing", "Accessibility permission denied"] {
            var fatal = probe(focus: .unavailable)
            fatal.fatalError = message
            let script = ForegroundScript([fatal, exact(), exact()])
            let report = try await verify(script)
            XCTAssertFalse(report.activeTabPreserved)
            XCTAssertEqual(report.activeTabStatus, .fatalRead)
            XCTAssertEqual(report.samples[0].probe.fatalError, message)
            XCTAssertEqual(script.reads, 1)
            XCTAssertTrue(script.delays.isEmpty)
        }
    }

    func testCancellationPersistsItsTerminalEvidenceAndDoesNotRetry() async throws {
        let script = ForegroundScript([probe(focus: .notWindow), exact(), exact()])
        script.cancelDelay = true
        do {
            _ = try await verify(script)
            XCTFail("Cancellation must not become a successful verification.")
        } catch is CancellationError {}
        XCTAssertEqual(script.reads, 1)
        XCTAssertEqual(script.reports.last?.activeTabStatus, .cancelled)
        XCTAssertEqual(script.reports.last?.samples.count, 1)
    }

    func testEvidenceWriteFailurePropagatesBeforeAnotherRead() async throws {
        let script = ForegroundScript([exact(), exact()])
        script.failPersistenceAt = 2
        do {
            _ = try await verify(script)
            XCTFail("A failed evidence write must not be ignored.")
        } catch ForegroundScript.ScriptError.evidenceWrite {}
        XCTAssertEqual(script.reads, 1)
        XCTAssertTrue(script.delays.isEmpty)
        XCTAssertEqual(script.persistenceAttempts, 2)
    }

    func testEncodedEvidenceContainsEveryProbeAndTerminalOutcome() async throws {
        let script = ForegroundScript([probe(focus: .notWindow), exact(), exact()])
        let report = try await verify(script)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["mode"] as? String, "read_only_active_tab_no_activation")
        XCTAssertEqual(object["active_tab_status"] as? String, "confirmed")
        XCTAssertEqual(object["expected_address"] as? String, address)
        XCTAssertEqual(object["process_identifier"] as? Int, 48101)
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 3)
        let first = try XCTUnwrap(samples[0]["probe"] as? [String: Any])
        let last = try XCTUnwrap(samples[2]["probe"] as? [String: Any])
        XCTAssertEqual(first["focus"] as? String, "not_window")
        XCTAssertEqual(last["address_values"] as? [String], [address])
        XCTAssertEqual(last["exact_address_matches"] as? Int, 1)
        XCTAssertEqual(script.reports.count, 4) // Initial evidence, then every probe.
    }

    func testExactVisibleBPassesWhileChromeIsNotGloballyFrontmost() async throws {
        var otherApp = exact()
        otherApp.focus = .applicationNotFocused
        otherApp.frontmostReadAttempted = true
        otherApp.frontmostBefore = .init(processIdentifier: 61234, bundleIdentifier: "test.other.app")
        otherApp.frontmostAfter = otherApp.frontmostBefore
        let script = ForegroundScript([otherApp, otherApp])
        let report = try await verify(script)
        XCTAssertTrue(report.activeTabPreserved)
        XCTAssertEqual(report.globalApplicationFocus, .notFrontmostAtAllSamples)
        XCTAssertEqual(report.samples.map(\.probe.focus), [.applicationNotFocused, .applicationNotFocused])
        XCTAssertEqual(script.reads, 2)
        XCTAssertEqual(script.delays.count, 1)
        XCTAssertEqual(script.reports.last, report)
        XCTAssertTrue(script.events.allSatisfy { ["read", "delay", "persist"].contains($0) })
    }

    func testGlobalFocusVariationDoesNotResetExactTabMatches() async throws {
        var otherApp = exact()
        otherApp.focus = .applicationNotFocused
        let script = ForegroundScript([exact(), otherApp])
        let report = try await verify(script)
        XCTAssertTrue(report.activeTabPreserved)
        XCTAssertEqual(report.globalApplicationFocus, .mixed)
        XCTAssertEqual(report.consecutiveMatches, 2)
        XCTAssertEqual(script.reads, 2)
    }

    func testFocusReadFailureIsDiagnosticWhenIndependentTabEvidenceIsComplete() async throws {
        var unknown = exact()
        unknown.focus = .unavailable
        unknown.focusReadError = "injected focus-read failure"
        unknown.focusErrorCode = -99
        unknown.frontmostReadAttempted = true
        let script = ForegroundScript([unknown, unknown])
        let report = try await verify(script)
        XCTAssertTrue(report.activeTabPreserved)
        XCTAssertEqual(report.globalApplicationFocus, .unobserved)
        XCTAssertEqual(report.samples[0].probe.focusReadError, unknown.focusReadError)
        XCTAssertEqual(report.samples[0].probe.addressValues, [address])
    }

    func testWrongChromeAddressFailsEvenWhenAnotherAppIsFrontmost() async throws {
        var wrong = exact()
        wrong.focus = .applicationNotFocused
        wrong.exactAddressMatches = 0
        wrong.addressValues = ["http://127.0.0.1/fixture?run=TEST&tab=A"]
        let script = ForegroundScript([wrong, exact(), exact()])
        let report = try await verify(script)
        XCTAssertFalse(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .contradictoryAddress)
        XCTAssertEqual(report.globalApplicationFocus, .notFrontmostAtAllSamples)
        XCTAssertEqual(script.reads, 1)
    }

    func testBHiddenAfterAnExactProbeCannotBeHiddenByLaterRecovery() async throws {
        var hiddenB = exact()
        hiddenB.focus = .applicationNotFocused
        hiddenB.visibility.bObservedHidden = true
        hiddenB.visibility.latestBSequence = 14
        let script = ForegroundScript([exact(), hiddenB, exact(), exact()])
        let report = try await verify(script)
        XCTAssertFalse(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .contradictoryVisibility)
        XCTAssertEqual(script.reads, 2)
        XCTAssertEqual(report.samples.last?.probe.visibility.latestBSequence, 14)
        XCTAssertEqual(script.reports.last, report)
    }

    func testAVisibleIsAContradictionEvenWithoutAnAddressRead() async throws {
        var visibleA = probe(focus: .applicationNotFocused)
        visibleA.visibility.aObservedVisible = true
        let script = ForegroundScript([visibleA, exact(), exact()])
        let report = try await verify(script)
        XCTAssertFalse(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .contradictoryVisibility)
        XCTAssertEqual(script.reads, 1)
    }

    func testMissingAcknowledgedVisibilityNeverPassesOnAddressAndFocusAlone() async throws {
        for missingA in [false, true] {
            var missing = exact()
            if missingA {
                missing.visibility.aHiddenAcknowledged = false
            } else {
                missing.visibility.bVisibleAcknowledged = false
            }
            let script = ForegroundScript([missing])
            let report = try await verify(script)
            XCTAssertFalse(report.activeTabPreserved)
            XCTAssertEqual(report.activeTabStatus, .exhausted)
            XCTAssertEqual(report.samples.count, 20)
        }
    }

    func testAddressOutsideVerifiedChromeWindowIsNotSufficient() async throws {
        var unverifiedWindow = exact()
        unverifiedWindow.focus = .applicationNotFocused
        unverifiedWindow.isWindowSnapshot = false
        let script = ForegroundScript([unverifiedWindow])
        let report = try await verify(script)
        XCTAssertFalse(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .exhausted)
    }

    func testFrontmostPIDBundleAndIndependentOutcomesAreEncoded() async throws {
        var otherApp = exact()
        otherApp.focus = .applicationNotFocused
        otherApp.frontmostReadAttempted = true
        otherApp.frontmostBefore = .init(processIdentifier: 61234, bundleIdentifier: "test.other.app")
        otherApp.frontmostAfter = otherApp.frontmostBefore
        let report = try await verify(ForegroundScript([otherApp, otherApp]))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(report)) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? Int, 2)
        XCTAssertEqual(object["active_tab_status"] as? String, "confirmed")
        XCTAssertEqual(object["global_application_focus"] as? String, "not_frontmost_at_all_samples")
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        let first = try XCTUnwrap(samples[0]["probe"] as? [String: Any])
        let frontmost = try XCTUnwrap(first["frontmost_before"] as? [String: Any])
        XCTAssertEqual(frontmost["process_identifier"] as? Int, 61234)
        XCTAssertEqual(frontmost["bundle_identifier"] as? String, "test.other.app")
        let visibility = try XCTUnwrap(first["visibility"] as? [String: Any])
        XCTAssertEqual(visibility["a_hidden_acknowledged"] as? Bool, true)
        XCTAssertEqual(visibility["b_visible_acknowledged"] as? Bool, true)
    }

    func testExactAddressAndAcknowledgedVisibilityAcceptWindowNotFocused() async throws {
        var selectedB = exact()
        selectedB.focus = .windowNotFocused
        let script = ForegroundScript([selectedB, selectedB])
        let report = try await verify(script)
        XCTAssertTrue(report.activeTabPreserved)
        XCTAssertEqual(report.activeTabStatus, .confirmed)
        XCTAssertEqual(report.globalApplicationFocus, .frontmostAtAllSamples)
        XCTAssertEqual(script.reads, 2)
        XCTAssertEqual(script.delays.count, 1)
        XCTAssertTrue(script.events.allSatisfy { ["read", "delay", "persist"].contains($0) })
    }

    private func verify(_ script: ForegroundScript) async throws -> ReadOnlyForegroundVerifier.Report {
        try await ReadOnlyForegroundVerifier.verify(
            processIdentifier: 48101, expectedAddress: address, operations: script.operations()
        )
    }

    private func probe(focus: ReadOnlyForegroundVerifier.Focus) -> ReadOnlyForegroundVerifier.Probe {
        var result = ReadOnlyForegroundVerifier.Probe()
        result.focus = focus
        return result
    }

    private func exact() -> ReadOnlyForegroundVerifier.Probe {
        var result = probe(focus: .focused)
        result.snapshotIdentifier = "fresh-scripted-snapshot"
        result.isWindowSnapshot = true
        result.visibility = .init(aHiddenAcknowledged: true, bVisibleAcknowledged: true)
        result.addressFieldCount = 1
        result.exactAddressMatches = 1
        result.addressValues = [address]
        return result
    }
}

@MainActor
private final class ForegroundScript {
    enum ScriptError: Error { case evidenceWrite }

    private let probes: [ReadOnlyForegroundVerifier.Probe]
    private var time: Duration = .zero
    var reads = 0
    var delays = [Duration]()
    var reports = [ReadOnlyForegroundVerifier.Report]()
    var events = [String]()
    var readDuration: Duration = .zero
    var extraDelay: Duration = .zero
    var cancelDelay = false
    var failPersistenceAt: Int?
    var persistenceAttempts = 0

    init(_ probes: [ReadOnlyForegroundVerifier.Probe]) {
        precondition(!probes.isEmpty)
        self.probes = probes
    }

    func operations() -> ReadOnlyForegroundVerifier.Operations {
        .init(
            read: {
                self.events.append("read")
                let result = self.probes[min(self.reads, self.probes.count - 1)]
                self.reads += 1
                self.time += self.readDuration
                return result
            },
            now: { self.time },
            sleep: { duration in
                self.events.append("delay")
                self.delays.append(duration)
                if self.cancelDelay { throw CancellationError() }
                self.time += duration + self.extraDelay
            },
            persist: { report in
                self.events.append("persist")
                self.persistenceAttempts += 1
                if self.persistenceAttempts == self.failPersistenceAt {
                    throw ScriptError.evidenceWrite
                }
                self.reports.append(report)
            }
        )
    }
}

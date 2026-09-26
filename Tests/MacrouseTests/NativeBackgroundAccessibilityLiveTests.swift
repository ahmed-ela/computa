import AppKit
import ApplicationServices
import AutomationCore
import CoreGraphics
import Foundation
import XCTest
@testable import Macrouse

/// Opt-in system-backend gate against the already-running, repository-owned
/// synthetic fixture. Never launches/activates apps or sends global input.
@MainActor
final class NativeBackgroundAccessibilityLiveTests: XCTestCase {
    private let fixtureBundleID = "com.heydash.background-probe"

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct Element {
        let index: Int
        let role: String
        let label: String?
        let value: String?
        let actions: [String]
        let isSettable: Bool
    }

    private struct Counts {
        let native: Int
        let pixel: Int
    }

    @MainActor
    private final class BoundaryAudit {
        private let targetPID: Int32
        private var initialPID: Int32?
        private var initialPoint: CGPoint?
        private var initialPasteboardCount: Int?
        private var previousTime: UInt64?
        private(set) var rows = [[String: Any]]()
        private(set) var maximumGapMilliseconds = 0.0

        init(targetPID: Int32) { self.targetPID = targetPID }

        func sample(_ phase: String) throws {
            let time = DispatchTime.now().uptimeNanoseconds
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let point = CGEvent(source: nil)?.location,
                  point.x.isFinite, point.y.isFinite else {
                throw Failure("Could not read foreground/pointer metadata at a test boundary.")
            }
            let pasteboardCount = NSPasteboard.general.changeCount
            if let previousTime {
                maximumGapMilliseconds = max(maximumGapMilliseconds, Double(time - previousTime) / 1_000_000)
            }
            self.previousTime = time
            rows.append([
                "phase": phase, "monotonic_ns": time, "unix_ms": Date().timeIntervalSince1970 * 1_000, "frontmost_pid": pid,
                "pointer_x": point.x, "pointer_y": point.y,
                "pasteboard_change_count": pasteboardCount,
            ])
            guard pid != targetPID else { throw Failure("Fixture became OS foreground; background gate stopped.") }
            if let initialPID, let initialPoint, let initialPasteboardCount {
                guard pid == initialPID else { throw Failure("OS foreground changed during the background gate.") }
                guard point == initialPoint else { throw Failure("Physical cursor changed during the background gate.") }
                guard pasteboardCount == initialPasteboardCount else {
                    throw Failure("Clipboard change count changed during the background gate.")
                }
            } else {
                initialPID = pid
                initialPoint = point
                initialPasteboardCount = pasteboardCount
            }
        }
    }

    func testSystemBackendPressesAndSetsValueWithoutForegroundInput() async throws {
        let environment = ProcessInfo.processInfo.environment
        // Xcode removes TEST_RUNNER_ while forwarding environment into the host.
        try XCTSkipUnless(
            environment["HEYDASH_LIVE_BACKGROUND_AX_TEST"] == "1"
                || environment["TEST_RUNNER_HEYDASH_LIVE_BACKGROUND_AX_TEST"] == "1",
            "Opt in with TEST_RUNNER_HEYDASH_LIVE_BACKGROUND_AX_TEST=1; fixture must already be running in the background."
        )
        let started = DispatchTime.now().uptimeNanoseconds
        var report: [String: Any] = [
            "gate": "native_background_accessibility_system_backend",
            "version": 1,
            "status": "failed",
            "model_used": false,
            "launch_activate_terminate_calls": 0,
            "global_input_calls": 0,
            "sampling": "operation boundaries only; not a continuous event trace or concurrent human-input stress test",
            "fixture_bundle_id": fixtureBundleID,
            "start_unix_ms": Date().timeIntervalSince1970 * 1_000,
            "attempted_press_dispatches": 0,
            "attempted_set_value_dispatches": 0,
        ]
        var trials = [[String: Any]]()
        var audit: BoundaryAudit?
        defer {
            report["total_ms"] = milliseconds(since: started)
            report["end_unix_ms"] = Date().timeIntervalSince1970 * 1_000
            report["press_trials"] = trials
            if let audit {
                report["boundary_samples"] = audit.rows
                report["maximum_boundary_sample_gap_ms"] = audit.maximumGapMilliseconds
            }
            emit(report)
        }

        do {
            guard AXIsProcessTrusted() else { throw Failure("Accessibility is not granted to the test host; no permission prompt was requested.") }
            let expectedURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("work/HeyDashBackgroundProbe-20260925/HeyDash Background Probe.app")
                .resolvingSymlinksInPath().standardizedFileURL
            let matches = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == fixtureBundleID && !$0.isTerminated
            }
            guard matches.count == 1, let running = matches.first,
                  running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == expectedURL else {
                throw Failure("Exactly one already-running fixture at the repository-owned .app path is required; no launch was attempted.")
            }
            let pid = running.processIdentifier
            let boundary = BoundaryAudit(targetPID: pid)
            audit = boundary
            try boundary.sample("preflight")
            report["fixture_pid"] = pid
            let lifetime = NativeBackgroundLifetime()
            defer { lifetime.revoke() }
            let backend = try NativeBackgroundAccessibility(application: ActivatedApplication(
                processIdentifier: pid, bundleIdentifier: fixtureBundleID, localizedName: "HeyDash Background Probe"
            ), lifetime: lifetime)
            try boundary.sample("after_bind")
            report["bind_ms"] = milliseconds(since: started)

            var initialCounts: Counts?
            var finalCounts: Counts?
            for iteration in 1...5 {
                let trialStart = DispatchTime.now().uptimeNanoseconds
                try boundary.sample("press_\(iteration)_before_read")
                let readStart = DispatchTime.now().uptimeNanoseconds
                let observation = try backend.read(outputCharacterLimit: 12_000)
                let readMS = milliseconds(since: readStart)
                try boundary.sample("press_\(iteration)_after_read")
                let elements = try parseElements(observation.text)
                let before = try counts(in: elements)
                if let initialCounts {
                    guard before.native == initialCounts.native + iteration - 1,
                          before.pixel == initialCounts.pixel else {
                        throw Failure("Fixture counters changed between sequential trials.")
                    }
                } else {
                    initialCounts = before
                    report["initial_native_count"] = before.native
                    report["initial_pixel_count"] = before.pixel
                }
                let button = try unique(elements.filter {
                    $0.role == "AXButton" && $0.label == "Native +1" && $0.actions.contains("AXPress")
                }, purpose: "exact emitted Native +1 AXPress target")
                guard try backend.elementName(snapshotID: observation.snapshotID, index: button.index) == "Native +1" else {
                    throw Failure("The emitted button index did not resolve to the exact fixture target.")
                }
                try boundary.sample("press_\(iteration)_before_dispatch")
                let dispatchStart = DispatchTime.now().uptimeNanoseconds
                report["attempted_press_dispatches"] = iteration
                try backend.perform(snapshotID: observation.snapshotID, index: button.index, action: .press)
                let dispatchMS = milliseconds(since: dispatchStart)
                try boundary.sample("press_\(iteration)_after_dispatch")
                let verifyStart = DispatchTime.now().uptimeNanoseconds
                let verification = try await verifyCounts(
                    backend, expectedNative: before.native + 1, expectedPixel: before.pixel,
                    audit: boundary, phase: "press_\(iteration)"
                )
                finalCounts = verification.counts
                trials.append([
                    "iteration": iteration,
                    "snapshot_id": observation.snapshotID.uuidString,
                    "emitted_element_index": button.index,
                    "native_before": before.native,
                    "native_after": verification.counts.native,
                    "pixel_after": verification.counts.pixel,
                    "dispatch_count": 1,
                    "verification_reads": verification.reads,
                    "read_ms": readMS,
                    "dispatch_ms": dispatchMS,
                    "verification_ms": milliseconds(since: verifyStart),
                    "total_ms": milliseconds(since: trialStart),
                    "verified": true,
                ])
            }

            guard let initialCounts, let finalCounts,
                  finalCounts.native == initialCounts.native + 5,
                  finalCounts.pixel == initialCounts.pixel else {
                throw Failure("Five exact once-only counter increments were not verified.")
            }
            report["final_native_count"] = finalCounts.native
            report["final_pixel_count"] = finalCounts.pixel

            let valueStart = DispatchTime.now().uptimeNanoseconds
            try boundary.sample("set_value_before_read")
            let fieldObservation = try backend.read(outputCharacterLimit: 12_000)
            try boundary.sample("set_value_after_read")
            let field = try syntheticField(in: parseElements(fieldObservation.text))
            let marker = "HEYDASH_BACKGROUND_AX_OK"
            try boundary.sample("set_value_before_dispatch")
            let setterStart = DispatchTime.now().uptimeNanoseconds
            report["attempted_set_value_dispatches"] = 1
            try backend.setValue(snapshotID: fieldObservation.snapshotID, index: field.index, text: marker)
            let setterMS = milliseconds(since: setterStart)
            try boundary.sample("set_value_after_dispatch")
            let verifyValueStart = DispatchTime.now().uptimeNanoseconds
            var valueReads = 0
            while true {
                try boundary.sample("set_value_before_verify_\(valueReads + 1)")
                let observed = try backend.read(outputCharacterLimit: 12_000)
                valueReads += 1
                try boundary.sample("set_value_after_verify_\(valueReads)")
                let observedElements = try parseElements(observed.text)
                let observedField = try syntheticField(in: observedElements)
                let observedCounts = try counts(in: observedElements)
                guard observedCounts.native == finalCounts.native, observedCounts.pixel == finalCounts.pixel else {
                    throw Failure("setValue unexpectedly changed fixture button/pixel counters.")
                }
                if observedField.value == marker { break }
                guard milliseconds(since: verifyValueStart) < 1_000 else {
                    throw Failure("Direct AX setValue did not read back the exact synthetic marker within one second; no retry was sent.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            report["set_value"] = [
                "verified": true,
                "snapshot_id": fieldObservation.snapshotID.uuidString,
                "emitted_element_index": field.index,
                "marker": marker,
                "dispatch_count": 1,
                "verification_reads": valueReads,
                "dispatch_ms": setterMS,
                "total_ms": milliseconds(since: valueStart),
                "verification": "exact returned AXTextField value; no Return or global key event",
            ]
            try boundary.sample("completed")
            guard !running.isTerminated else { throw Failure("Fixture exited during the test.") }
            report["status"] = "passed"
            report["verified_press_trials"] = 5
            report["verified_set_value_trials"] = 1
        } catch {
            report["error"] = error.localizedDescription
            throw error
        }
    }

    private func verifyCounts(
        _ backend: NativeBackgroundAccessibility,
        expectedNative: Int,
        expectedPixel: Int,
        audit: BoundaryAudit,
        phase: String
    ) async throws -> (counts: Counts, reads: Int) {
        let started = DispatchTime.now().uptimeNanoseconds
        var reads = 0
        while true {
            try audit.sample("\(phase)_before_verify_\(reads + 1)")
            let observed = try backend.read(outputCharacterLimit: 12_000)
            reads += 1
            try audit.sample("\(phase)_after_verify_\(reads)")
            let result = try counts(in: parseElements(observed.text))
            guard result.pixel == expectedPixel, result.native <= expectedNative else {
                throw Failure("An AXPress changed the wrong counter or incremented more than once.")
            }
            if result.native == expectedNative { return (result, reads) }
            guard result.native == expectedNative - 1, milliseconds(since: started) < 1_000 else {
                throw Failure("AXPress did not increment exactly once within one second; no action retry was sent.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func syntheticField(in elements: [Element]) throws -> Element {
        try unique(elements.filter {
            $0.role == "AXTextField" && $0.isSettable
                && ["Synthetic input", "probe-synthetic-input"].contains($0.label ?? "")
        }, purpose: "exact emitted synthetic settable text field")
    }

    private func counts(in elements: [Element]) throws -> Counts {
        var matches = [Counts]()
        let expression = try NSRegularExpression(pattern: #"^Native: ([0-9]+) Pixel: ([0-9]+) Input chars: [0-9]+$"#)
        for element in elements where element.role == "AXStaticText" {
            // A label and value may both expose the same static text. Count the
            // element once; two separate matching elements are ambiguous.
            for text in Set([element.label, element.value].compactMap { $0 }) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                guard let match = expression.firstMatch(in: text, range: range),
                      let nativeRange = Range(match.range(at: 1), in: text),
                      let pixelRange = Range(match.range(at: 2), in: text),
                      let native = Int(text[nativeRange]), let pixel = Int(text[pixelRange]) else { continue }
                matches.append(Counts(native: native, pixel: pixel))
                break
            }
        }
        return try unique(matches, purpose: "exact emitted fixture result counter")
    }

    private func parseElements(_ observation: String) throws -> [Element] {
        let indexExpression = try NSRegularExpression(pattern: #"^#([0-9]+) "#)
        let fieldExpression = try NSRegularExpression(pattern: #"(?:^| )([a-z_]+)=("(?:[^"\\]|\\.)*"|\[[^\]]*\]|[^ ]+)"#)
        var result = [Element]()
        for substring in observation.split(separator: "\n") where substring.hasPrefix("#") {
            let line = String(substring)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = indexExpression.firstMatch(in: line, range: range),
                  let indexRange = Range(match.range(at: 1), in: line), let index = Int(line[indexRange]) else {
                throw Failure("Malformed emitted fixture element index.")
            }
            var fields = [String: String]()
            for match in fieldExpression.matches(in: line, range: range) {
                guard let key = Range(match.range(at: 1), in: line), let value = Range(match.range(at: 2), in: line) else { continue }
                guard fields.updateValue(String(line[value]), forKey: String(line[key])) == nil else {
                    throw Failure("Duplicate field in emitted fixture element.")
                }
            }
            func string(_ key: String) throws -> String? {
                guard let value = fields[key], value != "-" else { return nil }
                return try JSONDecoder().decode(String.self, from: Data(value.utf8))
            }
            guard let rawRole = try string("role"), let actions = fields["actions"] else {
                throw Failure("Fixture element is missing its emitted role/actions.")
            }
            result.append(Element(
                index: index, role: String(rawRole.split(separator: "/").first ?? ""),
                label: try string("label"), value: try string("value"),
                actions: try JSONDecoder().decode([String].self, from: Data(actions.utf8)),
                isSettable: fields["settable"] == "1"
            ))
        }
        guard Set(result.map(\.index)).count == result.count else { throw Failure("Ambiguous emitted fixture element indices.") }
        return result
    }

    private func unique<T>(_ items: [T], purpose: String) throws -> T {
        guard items.count == 1, let value = items.first else {
            throw Failure("Expected one \(purpose); found \(items.count). No guessed index was used.")
        }
        return value
    }

    private func milliseconds(since time: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - time) / 1_000_000
    }

    private func emit(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Background AX proof JSON could not be encoded.")
            return
        }
        let attachment = XCTAttachment(string: text)
        attachment.name = "Macrouse native background AX system-backend proof"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("HEYDASH_BACKGROUND_AX_LIVE=\(text)")
    }
}

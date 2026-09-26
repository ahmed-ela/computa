import AppKit
import ApplicationServices
import AutomationCore
import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import Macrouse

/// Fixture-only, explicit opt-in selected-window identity control. This tests
/// guarded AXPress, not a multiwindow background pixel/Unicode driver. No model,
/// global HID, synthetic activation/deactivation, permission request or retry.
@MainActor
final class BackgroundWindowRaceLiveTests: XCTestCase {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Instrumentation adapter over the same public AX session/identity used by
    /// the production system backend. Counters describe entered source paths,
    /// not intercepted OS calls; the receiver separately verifies the outcome.
    private final class CountingBackend: NativeBackgroundAccessibilityBackend {
        let identity: ApplicationWindowIdentity
        let session: AccessibilitySession
        var lastSnapshot: AccessibilityTreeSnapshot?
        var performCalls = 0
        var dispatchBoundaries = 0

        init(identity: ApplicationWindowIdentity, bundleID: String) throws {
            self.identity = identity
            session = try AccessibilitySession(target: AccessibilityApplicationTarget(
                processIdentifier: identity.processIdentifier, bundleIdentifier: bundleID), windowIdentity: identity)
        }
        func isStillSelected() throws -> Bool { try identity.isStillSelected() }
        func snapshot(limits: AccessibilityTreeLimits) throws -> AccessibilityTreeSnapshot {
            let value = try session.snapshot(limits: limits); lastSnapshot = value; return value
        }
        func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
            performCalls += 1
            try session.refreshAndPerform(action, at: index, in: snapshot) {
                try beforeDispatch()
                guard try self.identity.isStillSelected() else { throw Failure("Selected window changed at dispatch.") }
                self.dispatchBoundaries += 1
            }
        }
        func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
            throw Failure("This slice never dispatches text input.")
        }
    }

    func testStableAOrChangedSelectionRejectsBeforeAXDispatch() async throws {
        let env = ProcessInfo.processInfo.environment
        func setting(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        try XCTSkipUnless(setting("HEYDASH_LIVE_WINDOW_RACE_PROBE") == "1", "Fresh disposable two-window fixture and explicit opt-in required.")
        let mode = setting("HEYDASH_WINDOW_RACE_MODE") ?? ""
        guard ["stable_a", "switch_b"].contains(mode),
              let id = UUID(uuidString: setting("HEYDASH_WINDOW_RACE_RUN_ID") ?? "") else {
            throw Failure("Explicit stable_a/switch_b mode and fresh UUID required.")
        }
        let runID = id.uuidString.lowercased()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/HeyDashWindowRaceProbe-20260925")
        let expectedApp = root.appendingPathComponent("HeyDash Window Race Probe.app").standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(runID)
        let bundleID = "com.heydash.window-race-probe"
        var report: [String: Any] = ["gate": "fixture_selected_window_identity_race", "status": "failed",
            "run_id": runID, "mode": mode, "model_used": false,
            "perform_api_attempts": 0, "selection_rejected": false,
            "global_input_calls": 0, "activation_calls": 0, "deactivation_events": 0,
            "pointer_pairs": 0, "keyboard_pairs": 0,
            "start_unix_ms": Date().timeIntervalSince1970 * 1000]
        var samples = [[String: Any]]()
        var backend: CountingBackend?
        defer {
            report["end_unix_ms"] = Date().timeIntervalSince1970 * 1000
            report["samples"] = samples
            report["backend_perform_calls"] = backend?.performCalls ?? 0
            report["ax_dispatch_boundaries_entered"] = backend?.dispatchBoundaries ?? 0
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print("HEYDASH_WINDOW_RACE=" + text)
                let attachment = XCTAttachment(string: text); attachment.name = "Two-window identity race evidence"
                attachment.lifetime = .keepAlways; add(attachment)
                // Never overwrite an earlier trial report. Failure still emits
                // the XCTest attachment/stdout if the target path is unavailable.
                try? data.write(to: directory.appendingPathComponent("test-report.json"), options: .withoutOverwriting)
            }
        }
        do {
            guard AXIsProcessTrusted() else { throw Failure("Existing AX permission required; no prompt requested.") }
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
            guard apps.count == 1, let app = apps.first,
                  app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == expectedApp,
                  let launch = app.launchDate, !app.isActive else { throw Failure("Exact already-running inactive fixture required.") }
            let pid = app.processIdentifier
            guard let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  foreground != pid, let pointer = CGEvent(source: nil)?.location else { throw Failure("Foreground/pointer metadata unavailable.") }
            let clipboard = NSPasteboard.general.changeCount
            func sample(_ phase: String) throws {
                try Task.checkCancellation()
                let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let point = CGEvent(source: nil)?.location
                let changeCount = NSPasteboard.general.changeCount
                samples.append(["phase": phase, "unix_ms": Date().timeIntervalSince1970 * 1000,
                    "monotonic_ns": DispatchTime.now().uptimeNanoseconds, "frontmost_pid": current ?? -1,
                    "pointer_x": point?.x ?? -1, "pointer_y": point?.y ?? -1, "pasteboard_change_count": changeCount])
                guard current == foreground, point == pointer, changeCount == clipboard,
                      !app.isTerminated, !app.isActive, app.launchDate == launch, AXIsProcessTrusted() else {
                    throw Failure("Desktop, process generation or permission boundary changed; no further input.")
                }
            }
            func state() throws -> [String: Any] {
                let data = try Data(contentsOf: directory.appendingPathComponent("state.json"))
                guard data.count <= 32_768, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["run_id"] as? String == runID, value["mode"] as? String == mode,
                      value["receiver_instrumented"] as? Bool == true,
                      (value["pid"] as? NSNumber)?.int32Value == pid,
                      (value["launch_unix"] as? NSNumber)?.doubleValue == launch.timeIntervalSince1970,
                      let time = (value["unix_ms"] as? NSNumber)?.doubleValue, time.isFinite,
                      (0...1000).contains(Date().timeIntervalSince1970 * 1000 - time) else {
                    throw Failure("Stale or mismatched fixture state.")
                }
                return value
            }
            func window(_ name: String, in state: [String: Any]) throws -> [String: Any] {
                guard let all = state["windows"] as? [String: Any], Set(all.keys) == ["A", "B"],
                      let value = all[name] as? [String: Any], let raw = value["window_id"] as? NSNumber,
                      raw.int64Value > 0, raw.int64Value <= Int64(UInt32.max), raw.doubleValue == Double(raw.int64Value) else {
                    throw Failure("Both exact fixture windows must be present.")
                }
                let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, raw.uint32Value) as? [[String: Any]]
                guard rows?.count == 1, let row = rows?.first,
                      (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                      (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == raw.uint32Value else {
                    throw Failure("Fixture window ownership changed.")
                }
                return value
            }
            func requireCounters(_ value: [String: Any], native: Int) throws {
                guard (value["native_count"] as? NSNumber)?.intValue == native,
                      (value["pixel_count"] as? NSNumber)?.intValue == 0,
                      (value["text_characters"] as? NSNumber)?.intValue == 0,
                      (value["text_change_count"] as? NSNumber)?.intValue == 0 else {
                    throw Failure("Unexpected fixture mutation.")
                }
            }
            try sample("preflight")
            let initial = try state()
            guard initial["phase"] as? String == "awaiting_arm", initial["arm_nonce"] == nil else { throw Failure("Fresh, unarmed fixture required.") }
            let initialA = try window("A", in: initial), initialB = try window("B", in: initial)
            guard (initialA["window_id"] as? NSNumber) != (initialB["window_id"] as? NSNumber) else { throw Failure("Distinct A/B windows required.") }
            try requireCounters(initialA, native: 0); try requireCounters(initialB, native: 0)
            let binding = try RunningApplicationBinder().bind(bundleIdentifier: bundleID)
            guard binding.application.processIdentifier == pid, binding.window.info.title == "HeyDash Window Race A",
                  let frame = binding.window.info.frame, frame.width == 500, frame.height == 362,
                  try binding.window.identity.isStillSelected() else { throw Failure("Actual AX must select exact fixture A before arming.") }
            let counted = try CountingBackend(identity: binding.window.identity, bundleID: bundleID)
            backend = counted
            let lifetime = NativeBackgroundLifetime(); defer { lifetime.revoke() }
            let lane = NativeBackgroundAccessibility(backend: counted, lifetime: lifetime)
            let observation = try lane.read(outputCharacterLimit: 12_000)
            let candidates = counted.lastSnapshot?.elements.filter {
                $0.identifier == "window-race-button-A" && $0.role == "AXButton" && $0.supportedActions.contains("AXPress")
            } ?? []
            guard candidates.count == 1, let button = candidates.first,
                  observation.text.contains("#\(button.index) "),
                  try lane.elementName(snapshotID: observation.snapshotID, index: button.index) == "Window A +1" else {
                throw Failure("One freshly observed and exposed A button required.")
            }
            report["initial"] = initial; report["snapshot_id"] = observation.snapshotID.uuidString
            report["target_element_index"] = button.index
            try sample("before_arm")
            guard try binding.window.identity.isStillSelected() else { throw Failure("A changed before fixture scheduling.") }
            let nonce = UUID().uuidString.lowercased()
            var command = try JSONSerialization.data(withJSONObject: ["run_id": runID, "mode": mode,
                "nonce": nonce, "pid": pid, "launch_unix": launch.timeIntervalSince1970], options: [.sortedKeys])
            command.append(10)
            try command.write(to: directory.appendingPathComponent("arm.json"), options: .withoutOverwriting)
            report["arm_nonce"] = nonce
            let waitStart = DispatchTime.now().uptimeNanoseconds
            var prepared = [String: Any]()
            while true {
                try sample("wait_for_fixture_transition")
                prepared = try state()
                if prepared["phase"] as? String == "ready_for_dispatch", prepared["arm_nonce"] as? String == nonce { break }
                guard DispatchTime.now().uptimeNanoseconds - waitStart < 3_000_000_000 else { throw Failure("Fixture selection transition timed out; no target input.") }
                try await Task.sleep(for: .milliseconds(20))
            }
            try requireCounters(window("A", in: prepared), native: 0); try requireCounters(window("B", in: prepared), native: 0)
            let selection = try ApplicationWindowReader().selectedWindowObservation(processIdentifier: pid, expectedBundleIdentifier: bundleID)
            let expectedTitle = mode == "switch_b" ? "HeyDash Window Race B" : "HeyDash Window Race A"
            guard selection.info.title == expectedTitle else { throw Failure("Fixture did not establish the actual AX selection; no target input.") }
            let stillA = try binding.window.identity.isStillSelected()
            guard stillA == (mode == "stable_a") else { throw Failure("Retained A identity did not distinguish the actual selection.") }
            report["after_transition"] = prepared; report["retained_a_still_selected"] = stillA
            try sample("immediately_before_guarded_attempt")
            report["perform_api_attempts"] = 1
            var rejected = false
            do {
                try lane.perform(snapshotID: observation.snapshotID, index: button.index, action: .press)
            } catch NativeBackgroundAccessibility.Failure.targetChanged {
                rejected = true
            }
            report["selection_rejected"] = rejected
            guard rejected == (mode == "switch_b"), counted.performCalls == (mode == "stable_a" ? 1 : 0),
                  counted.dispatchBoundaries == (mode == "stable_a" ? 1 : 0) else {
                throw Failure("Unexpected attempted/rejected/dispatch accounting.")
            }
            // Delivery/return is not success. Read actual receiver counters;
            // the negative control remains under observation for at least250ms.
            let verifyStart = DispatchTime.now().uptimeNanoseconds
            var final = [String: Any]()
            while true {
                try sample("verify_receiver")
                final = try state()
                let a = try window("A", in: final), b = try window("B", in: final)
                try requireCounters(b, native: 0)
                let elapsed = DispatchTime.now().uptimeNanoseconds - verifyStart
                let expected = mode == "stable_a" ? 1 : 0
                let count = (a["native_count"] as? NSNumber)?.intValue
                if count == expected {
                    try requireCounters(a, native: expected)
                    if elapsed >= 250_000_000 { break }
                } else if mode == "switch_b" || count != 0 {
                    throw Failure("Wrong or duplicate A mutation.")
                }
                guard elapsed < 2_000_000_000 else { throw Failure("Receiver outcome did not verify; mutation was not retried.") }
                try await Task.sleep(for: .milliseconds(20))
            }
            report["final"] = final
            report["receiver_native_actions"] = mode == "stable_a" ? 1 : 0
            report["status"] = "passed_selected_window_guard_only"
        } catch {
            report["error"] = error.localizedDescription
            throw error
        }
    }
}

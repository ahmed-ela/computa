import AppKit
import ApplicationServices
@testable import AutomationCore
import CoreGraphics
import Darwin
import Foundation
import XCTest

/// Test-only unsupported AppKit event-semantics experiment. A matching event
/// was observed at our own passive receiver during Codex input. That does not
/// establish a supported API, safe rollback, or general third-party behavior.
/// Default sends one activation event only. A separate explicit opt-in adds
/// one pixel pair and optionally one Unicode pair to this fixture only. No
/// global post, permission prompt, or retry exists. An additional explicit
/// fixture-only option tests a constructed deactivation counterpart, not a
/// deactivation payload observed from Codex or a production rollback routine.
@MainActor
final class BackgroundActivationFeasibilityLiveTests: XCTestCase {
    func testObservedActivationEventToDisposableReceiver() async throws {
        let env = ProcessInfo.processInfo.environment
        func setting(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        try XCTSkipUnless(setting("HEYDASH_LIVE_UNSUPPORTED_ACTIVATION_PROBE") == "1",
                          "Explicit fixture-only unsupported-semantics opt-in required.")
        let inputMode = setting("HEYDASH_ACTIVATION_PROBE_INPUT") ?? "none"
        guard ["none", "pixel", "pixel_unicode", "prepared_pixel_unicode", "ax_prepared_pixel_unicode"].contains(inputMode) else { throw ProbeFailure("Unknown bounded input experiment.") }
        let cleanupMode = setting("HEYDASH_ACTIVATION_PROBE_CLEANUP") ?? "none"
        guard ["none", "deactivate_once"].contains(cleanupMode),
              cleanupMode == "none" || inputMode == "prepared_pixel_unicode" else {
            throw ProbeFailure("Cleanup experiment requires the explicit prepared pixel/Unicode mode.")
        }
        let runID = try XCTUnwrap(UUID(uuidString: setting("HEYDASH_ACTIVATION_PROBE_RUN_ID") ?? "")).uuidString.lowercased()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work/HeyDashFocusStateProbe-20260925")
        let expectedApp = root.appendingPathComponent("HeyDash Focus State Probe.app").standardizedFileURL.resolvingSymlinksInPath()
        let stateURL = root.appendingPathComponent(runID).appendingPathComponent("state.json")
        var report: [String: Any] = ["probe": "unsupported_observed_activation_event", "run_id": runID,
            "input_mode": inputMode, "cleanup_mode": cleanupMode, "deactivation_events": 0,
            "mouse_pairs": 0, "preparation_mouse_pairs": 0, "unicode_pairs": 0,
            "events_posted": 0, "global_posts": 0, "activation_api_calls": 0,
            "model_used": false, "start_unix_ms": Date().timeIntervalSince1970 * 1_000]
        var samples = [[String: Any]]()
        defer {
            report["end_unix_ms"] = Date().timeIntervalSince1970 * 1_000
            report["samples"] = samples
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print("HEYDASH_ACTIVATION_FEASIBILITY=" + text)
                let attachment = XCTAttachment(string: text)
                attachment.name = "Unsupported activation receiver evidence"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let bundleID = "com.heydash.focus-state-probe"
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
        XCTAssertEqual(apps.count, 1)
        let app = try XCTUnwrap(apps.first)
        XCTAssertEqual(app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath(), expectedApp)
        let launch = try XCTUnwrap(app.launchDate)
        let pid = app.processIdentifier
        XCTAssertTrue(AXIsProcessTrusted())
        XCTAssertTrue(CGPreflightPostEventAccess())
        let binding = try RunningApplicationBinder().bind(bundleIdentifier: bundleID)
        let foreground = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let pointer = try XCTUnwrap(CGEvent(source: nil)?.location)
        let clipboard = NSPasteboard.general.changeCount
        guard apps.count == 1, foreground != pid, !app.isActive,
              binding.application.processIdentifier == pid,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == expectedApp,
              AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw ProbeFailure("Initial target/permission boundary failed.") }

        func state() throws -> [String: Any] {
            let data = try Data(contentsOf: stateURL)
            guard data.count <= 32_768, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["run_id"] as? String == runID,
                  (value["pid"] as? NSNumber)?.int32Value == pid,
                  (value["launch_unix"] as? NSNumber)?.doubleValue == launch.timeIntervalSince1970,
                  value["receiver_instrumented"] as? Bool == true,
                  let time = (value["unix_ms"] as? NSNumber)?.doubleValue, time.isFinite,
                  (0...1_000).contains(Date().timeIntervalSince1970 * 1_000 - time) else {
                throw ProbeFailure("Stale or mismatched receiver evidence.")
            }
            return value
        }
        func sample(_ stage: String) throws {
            try Task.checkCancellation()
            let currentForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let currentPointer = CGEvent(source: nil)?.location
            let currentClipboard = NSPasteboard.general.changeCount
            samples.append(["stage": stage, "unix_ms": Date().timeIntervalSince1970 * 1_000,
                "monotonic_ns": DispatchTime.now().uptimeNanoseconds,
                "frontmost_pid": currentForeground ?? -1, "pointer_x": currentPointer?.x ?? -1,
                "pointer_y": currentPointer?.y ?? -1, "pasteboard_change_count": currentClipboard])
            guard currentForeground == foreground, currentPointer == pointer, currentClipboard == clipboard,
                  !app.isTerminated, !app.isActive, app.launchDate == launch,
                  try binding.window.identity.isStillSelected() else {
                throw ProbeFailure("Foreground/pointer/clipboard or target identity changed. No further input.")
            }
        }
        let initial = try state()
        guard initial["app_active"] as? Bool == false, initial["window_key"] as? Bool == false,
              (initial["pixel_count"] as? NSNumber)?.intValue == 0,
              (initial["text_characters"] as? NSNumber)?.intValue == 0,
              let id = initial["window_id"] as? NSNumber, id.int64Value > 0,
              id.int64Value <= Int64(UInt32.max), id.doubleValue == Double(id.int64Value) else {
            throw ProbeFailure("Fresh inactive synthetic receiver required.")
        }
        let windowID = CGWindowID(id.uint32Value)
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
        guard windows?.count == 1, let row = windows?.first,
              (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID,
              row[kCGWindowIsOnscreen as String] as? Bool == true else { throw ProbeFailure("Window ownership not confirmed.") }
        guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue, let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue, let height = (bounds["Height"] as? NSNumber)?.doubleValue,
              [x, y, width, height].allSatisfy(\.isFinite), width == 500, height == 362,
              let axFrame = binding.window.info.frame,
              axFrame.x == x, axFrame.y == y, axFrame.width == width, axFrame.height == height else {
            throw ProbeFailure("Exact synthetic fixture geometry required.")
        }
        let expectedFrame = CGRect(x: x, y: y, width: width, height: height)
        func validateInput(_ phase: String) throws -> [String: Any] {
            try sample(phase)
            let value = try state()
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
            guard rows?.count == 1, let row = rows?.first,
                  (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID,
                  row[kCGWindowIsOnscreen as String] as? Bool == true,
                  let currentBounds = row[kCGWindowBounds as String] as? NSDictionary,
                  currentBounds.isEqual(to: bounds),
                  (value["window_id"] as? NSNumber)?.uint32Value == windowID,
                  AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
                throw ProbeFailure("Pre-dispatch window geometry, ownership or permission changed.")
            }
            try Task.checkCancellation()
            return value
        }
        report["initial"] = initial
        // Exact type/subtype/flags/zero payload observed in the passive receiver.
        // No claim that undocumented flag/payload semantics generalize.
        let flags = NSEvent.ModifierFlags(rawValue: 786432)
        guard let native = NSEvent.otherEvent(with: .appKitDefined, location: .zero,
                    modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: Int(windowID), context: nil,
                    subtype: NSEvent.EventSubtype.applicationActivated.rawValue, data1: 0, data2: 0),
              let event = native.cgEvent, let readback = NSEvent(cgEvent: event),
              readback.type == .appKitDefined, readback.subtype == .applicationActivated,
              readback.windowNumber == Int(windowID), readback.modifierFlags == flags,
              readback.data1 == 0, readback.data2 == 0 else { throw ProbeFailure("Construction round trip failed; no event sent.") }
        event.setIntegerValueField(.eventSourceUserData, value: 0x48444641001)
        try sample("immediately_before_post")
        _ = try validateInput("final_activation_boundary")
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), !app.isTerminated, !app.isActive,
              app.launchDate == launch, try binding.window.identity.isStillSelected() else {
            throw ProbeFailure("Immediate pre-dispatch guard failed.")
        }
        event.postToPid(pid)
        report["events_posted"] = 1
        let start = DispatchTime.now().uptimeNanoseconds
        // Observe a bounded interval, without resending or assuming rollback.
        repeat {
            try sample("after_post")
            try await Task.sleep(for: .milliseconds(10))
        } while DispatchTime.now().uptimeNanoseconds - start < 500_000_000
        let activated = try state()
        report["after_activation"] = activated
        guard activated["running_application_active"] as? Bool == false,
              (activated["pixel_count"] as? NSNumber)?.intValue == 0,
              (activated["text_characters"] as? NSNumber)?.intValue == 0 else {
            throw ProbeFailure("Unexpected receiver mutation or OS activation.")
        }
        if inputMode != "none" {
            guard activated["app_active"] as? Bool == true else { throw ProbeFailure("Receiver did not accept activation; no pixel input.") }
            // This point is fixture geometry, not inferred third-party UI.
            // Title-bar preparation requires its own explicit mode below.
            let local = CGPoint(x: 250, y: 137.5)
            let screen = CGPoint(x: expectedFrame.minX + local.x, y: expectedFrame.maxY - local.y)
            guard let source = CGEventSource(stateID: .privateState),
                  let down = NSEvent.mouseEvent(with: .leftMouseDown, location: local, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowID), context: nil,
                        eventNumber: 1, clickCount: 1, pressure: 1)?.cgEvent,
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: local, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowID), context: nil,
                        eventNumber: 2, clickCount: 1, pressure: 0)?.cgEvent else { throw ProbeFailure("Mouse construction failed.") }
            typealias Setter = @convention(c) (CGEvent, CGPoint) -> Void
            typealias Getter = @convention(c) (CGEvent) -> CGPoint
            guard let library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW | RTLD_LOCAL) else {
                throw ProbeFailure("Experimental coordinate API unavailable.")
            }
            defer { dlclose(library) }
            guard let setter = dlsym(library, "CGEventSetWindowLocation"), let getter = dlsym(library, "CGEventGetWindowLocation") else {
                throw ProbeFailure("Experimental coordinate API unavailable.")
            }
            let setLocal = unsafeBitCast(setter, to: Setter.self)
            let getLocal = unsafeBitCast(getter, to: Getter.self)
            let topLeft = CGPoint(x: local.x, y: expectedFrame.height - local.y)
            for event in [down, up] {
                event.setSource(source)
                event.flags = []
                event.location = screen
                event.setIntegerValueField(.eventSourceUserData, value: 0x48444641001)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                setLocal(event, topLeft)
                guard getLocal(event) == topLeft, event.location == screen,
                      NSEvent(cgEvent: event)?.windowNumber == Int(windowID) else { throw ProbeFailure("Mouse coordinates changed during construction.") }
            }
            if inputMode == "ax_prepared_pixel_unicode" {
                // Test a public, element-addressed focus request as an
                // alternative to a title-bar click. No fallback if unsupported.
                // Reuse the retained verified identity instead of assuming an
                // app exposes exactly one AX window (it can expose panels).
                let window = try binding.window.identity.validatedWindowElement()
                var owner: pid_t = 0
                guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { throw ProbeFailure("AX owner changed.") }
                var settable = DarwinBoolean(false)
                let query = AXUIElementIsAttributeSettable(window, kAXFocusedAttribute as CFString, &settable)
                report["ax_focused_query_error"] = query.rawValue
                report["ax_focused_settable"] = settable.boolValue
                guard query == .success, settable.boolValue else { throw ProbeFailure("Window AXFocused is not settable; no fallback input.") }
                _ = try validateInput("immediately_before_ax_focus")
                let result = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                report["ax_focus_requests"] = 1
                report["ax_focus_error"] = result.rawValue
                try await Task.sleep(for: .milliseconds(150))
                let prepared = try validateInput("after_ax_focus")
                report["after_preparation"] = prepared
                guard result == .success, prepared["window_key"] as? Bool == true,
                      (prepared["pixel_count"] as? NSNumber)?.intValue == 0,
                      (prepared["text_characters"] as? NSNumber)?.intValue == 0 else {
                    throw ProbeFailure("AX focus did not establish local key state or changed fixture content.")
                }
            }
            if inputMode == "prepared_pixel_unicode" {
                // Separate, explicit mutation in the disposable fixture only.
                // A noninteractive center of this known title bar is not a
                // generally safe location for arbitrary third-party windows.
                let prepLocal = CGPoint(x: 250, y: 346)
                let prepScreen = CGPoint(x: expectedFrame.minX + prepLocal.x, y: expectedFrame.maxY - prepLocal.y)
                let prepTopLeft = CGPoint(x: prepLocal.x, y: expectedFrame.height - prepLocal.y)
                guard let prepDown = NSEvent.mouseEvent(with: .leftMouseDown, location: prepLocal, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowID), context: nil,
                            eventNumber: 3, clickCount: 1, pressure: 1)?.cgEvent,
                      let prepUp = NSEvent.mouseEvent(with: .leftMouseUp, location: prepLocal, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowID), context: nil,
                            eventNumber: 4, clickCount: 1, pressure: 0)?.cgEvent else { throw ProbeFailure("Preparation event allocation failed.") }
                for event in [prepDown, prepUp] {
                    event.setSource(source); event.flags = []; event.location = prepScreen
                    event.setIntegerValueField(.eventSourceUserData, value: 0x48444641001)
                    event.setIntegerValueField(.mouseEventClickState, value: 1)
                    setLocal(event, prepTopLeft)
                    guard getLocal(event) == prepTopLeft, event.location == prepScreen,
                          NSEvent(cgEvent: event)?.windowNumber == Int(windowID) else { throw ProbeFailure("Preparation coordinate mismatch.") }
                }
                _ = try validateInput("immediately_before_preparation_pair")
                postPair(prepDown, prepUp, to: pid)
                report["preparation_mouse_pairs"] = 1
                report["events_posted"] = 3
                try await Task.sleep(for: .milliseconds(150))
                let prepared = try validateInput("after_preparation_pair")
                report["after_preparation"] = prepared
                guard prepared["window_key"] as? Bool == true,
                      (prepared["pixel_count"] as? NSNumber)?.intValue == 0,
                      (prepared["text_characters"] as? NSNumber)?.intValue == 0 else {
                    throw ProbeFailure("Preparation did not establish local key state or changed fixture content.")
                }
            }
            _ = try validateInput("immediately_before_pixel_pair")
            postPair(down, up, to: pid)
            report["mouse_pairs"] = 1
            report["events_posted"] = inputMode == "prepared_pixel_unicode" ? 5 : 3
            try await Task.sleep(for: .milliseconds(150))
            let clicked = try validateInput("after_pixel_pair")
            report["after_pixel"] = clicked
            report["pixel_accepted"] = (clicked["pixel_count"] as? NSNumber)?.intValue == 1
            guard let acceptedPixels = (clicked["pixel_count"] as? NSNumber)?.intValue,
                  (0...1).contains(acceptedPixels),
                  (clicked["text_characters"] as? NSNumber)?.intValue == 0 else { throw ProbeFailure("Unexpected pixel side effect.") }
            if inputMode.hasSuffix("_unicode") {
                guard clicked["first_responder_is_synthetic_field"] as? Bool == true,
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw ProbeFailure("Expected synthetic field responder or keyboard events unavailable.")
                }
                for event in [down, up] { event.flags = []; event.setIntegerValueField(.eventSourceUserData, value: 0x48444641001) }
                let units = Array("HDé7".utf16)
                units.withUnsafeBufferPointer { buffer in
                    if let base = buffer.baseAddress { down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base) }
                }
                let immediatelyBefore = try validateInput("immediately_before_unicode_pair")
                guard immediatelyBefore["first_responder_is_synthetic_field"] as? Bool == true else {
                    throw ProbeFailure("Synthetic responder changed; no keyboard input.")
                }
                postPair(down, up, to: pid)
                report["unicode_pairs"] = 1
                report["events_posted"] = inputMode == "prepared_pixel_unicode" ? 7 : 5
                try await Task.sleep(for: .milliseconds(150))
                let typed = try validateInput("after_unicode_pair")
                report["unicode_exact"] = typed["marker_matches"]
            }
        }
        if cleanupMode == "deactivate_once" {
            let before = try validateInput("immediately_before_deactivation")
            report["before_deactivation"] = before
            guard before["app_active"] as? Bool == true,
                  before["window_key"] as? Bool == true,
                  before["marker_matches"] as? Bool == true,
                  (before["pixel_count"] as? NSNumber)?.intValue == 1,
                  (before["text_characters"] as? NSNumber)?.intValue == 4 else {
                throw ProbeFailure("Successful prepared action required before the separate cleanup experiment.")
            }
            // Unsupported, independently constructed counterpart. Codex's
            // actual deactivation fields/sequence have NOT been observed.
            guard let native = NSEvent.otherEvent(with: .appKitDefined, location: .zero,
                    modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: Int(windowID), context: nil,
                    subtype: NSEvent.EventSubtype.applicationDeactivated.rawValue, data1: 0, data2: 0),
                  let event = native.cgEvent, let roundTrip = NSEvent(cgEvent: event),
                  roundTrip.type == .appKitDefined, roundTrip.subtype == .applicationDeactivated,
                  roundTrip.windowNumber == Int(windowID), roundTrip.modifierFlags == flags,
                  roundTrip.data1 == 0, roundTrip.data2 == 0 else {
                throw ProbeFailure("Deactivation construction failed; no cleanup event posted.")
            }
            event.setIntegerValueField(.eventSourceUserData, value: 0x48444641001)
            _ = try validateInput("final_deactivation_boundary")
            let dispatchTime = Date().timeIntervalSince1970 * 1_000
            report["deactivation_dispatch_unix_ms"] = dispatchTime
            event.postToPid(pid)
            report["deactivation_events"] = 1
            report["events_posted"] = 8
            let cleanupStart = DispatchTime.now().uptimeNanoseconds
            // Event posting does not imply processing. Require fresh receiver
            // readback after a bounded, sampled observation interval.
            repeat {
                try sample("after_deactivation_post")
                try await Task.sleep(for: .milliseconds(10))
            } while DispatchTime.now().uptimeNanoseconds - cleanupStart < 500_000_000
            let after = try state()
            report["after_deactivation"] = after
            let evidenceData = try Data(contentsOf: stateURL.deletingLastPathComponent().appendingPathComponent("events.jsonl"))
            guard evidenceData.count <= 2_000_000, let evidenceText = String(data: evidenceData, encoding: .utf8) else {
                throw ProbeFailure("Receiver cleanup evidence unavailable or excessive.")
            }
            let deliveries = try evidenceText.split(separator: "\n").compactMap { line -> [String: Any]? in
                let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                guard let row, row["run_id"] as? String == runID,
                      (row["pid"] as? NSNumber)?.int32Value == pid,
                      row["stage"] as? String == "application_send_before",
                      (row["event_type"] as? NSNumber)?.intValue == Int(NSEvent.EventType.appKitDefined.rawValue),
                      (row["event_subtype"] as? NSNumber)?.intValue == Int(NSEvent.EventSubtype.applicationDeactivated.rawValue),
                      (row["event_window_id"] as? NSNumber)?.uint32Value == windowID,
                      (row["cg_source_user_data"] as? NSNumber)?.int64Value == 0x48444641001,
                      let time = (row["unix_ms"] as? NSNumber)?.doubleValue, time >= dispatchTime else { return nil }
                return row
            }
            report["tagged_deactivation_deliveries"] = deliveries.count
            guard deliveries.count == 1,
                  let deliveryTime = (deliveries.first?["unix_ms"] as? NSNumber)?.doubleValue,
                  let readbackTime = (after["unix_ms"] as? NSNumber)?.doubleValue, readbackTime > deliveryTime,
                  after["app_active"] as? Bool == false,
                  after["window_key"] as? Bool == false,
                  after["running_application_active"] as? Bool == false,
                  after["marker_matches"] as? Bool == true,
                  (after["pixel_count"] as? NSNumber)?.intValue == 1,
                  (after["text_characters"] as? NSNumber)?.intValue == 4,
                  (after["text_change_count"] as? NSNumber)?.intValue == (before["text_change_count"] as? NSNumber)?.intValue else {
                throw ProbeFailure("Constructed deactivation did not restore inactive/non-key state with unchanged content.")
            }
            report["cleanup_verified_in_fixture"] = true
        }
        let final = try state()
        report["final"] = final
        report["receiver_app_active"] = final["app_active"]
        report["receiver_window_key"] = final["window_key"]
        try sample("complete")
        report["status"] = "completed_experiment_not_production_capability"
    }

    private func postPair(_ down: CGEvent, _ up: CGEvent, to pid: Int32) {
        defer { up.postToPid(pid) }
        down.postToPid(pid)
    }

    private struct ProbeFailure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}

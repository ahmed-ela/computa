import AppKit
import ApplicationServices
import AutomationCore
import CoreGraphics
import Darwin
import Foundation
import XCTest

/// Feasibility only: public PID delivery with a separately opted-in non-public
/// OS window-coordinate experiment. Negative receiver results are data, not a
/// capability claim. Safety failures fail the test. No production/global fallback.
@MainActor
final class TargetedInputFeasibilityLiveTests: XCTestCase {
    private let bundleID = "com.heydash.targeted-input-probe"
    private let eventTag: Int64 = 0x48445954001
    private let marker = "HDé7"

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct State {
        let raw: [String: Any]
        func number(_ key: String) throws -> Double {
            guard let value = raw[key] as? NSNumber, value.doubleValue.isFinite else { throw Failure("Missing finite fixture field: \(key)") }
            return value.doubleValue
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = raw[key] as? Bool else { throw Failure("Missing fixture boolean: \(key)") }
            return value
        }
        func string(_ key: String) throws -> String {
            guard let value = raw[key] as? String else { throw Failure("Missing fixture string: \(key)") }
            return value
        }
        var frame: CGRect? {
            guard let bounds = raw["window_frame"] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    @MainActor
    private final class Audit {
        private var baseline: (Int32, CGPoint, Int)?
        private(set) var rows = [[String: Any]]()
        func sample(_ phase: String, excluding pid: Int32) throws {
            guard let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let pointer = CGEvent(source: nil)?.location else { throw Failure("Cannot observe safety metadata.") }
            let clipboard = NSPasteboard.general.changeCount
            rows.append(["phase": phase, "unix_ms": Date().timeIntervalSince1970 * 1_000,
                         "monotonic_ns": DispatchTime.now().uptimeNanoseconds, "frontmost_pid": foreground,
                         "pointer_x": pointer.x, "pointer_y": pointer.y, "pasteboard_change_count": clipboard])
            guard foreground != pid else { throw Failure("Safety failure: fixture became OS foreground.") }
            if let baseline {
                guard baseline.0 == foreground, baseline.1 == pointer, baseline.2 == clipboard else {
                    throw Failure("Safety failure: foreground, physical pointer, or clipboard changed. No more input will be sent.")
                }
            } else { baseline = (foreground, pointer, clipboard) }
        }
    }

    func testPublicPIDTargetedInputAgainstSyntheticReceiver() async throws {
        let env = ProcessInfo.processInfo.environment
        func setting(_ name: String) -> String? { env[name] ?? env["TEST_RUNNER_" + name] }
        try XCTSkipUnless(setting("HEYDASH_LIVE_TARGETED_INPUT_TEST") == "1",
                          "Requires explicit opt-in and an already-running synthetic receiver; no launch or permission request is made.")
        let audit = Audit()
        var report: [String: Any] = [
            "probe": "public_postToPid_feasibility", "status": "failed", "model_used": false,
            "start_unix_ms": Date().timeIntervalSince1970 * 1_000,
            "global_posts": 0, "activation_calls": 0, "event_taps": 0,
            "mouse_pairs_dispatched": 0, "keyboard_pairs_dispatched": 0,
            "interpretation": "A completed probe is not proof input was accepted. See delivery and mutation separately.",
        ]
        defer {
            report["end_unix_ms"] = Date().timeIntervalSince1970 * 1_000
            report["boundary_and_poll_samples"] = audit.rows
            emit(report)
        }
        do {
            let routing = setting("HEYDASH_TARGETED_INPUT_WINDOW_FIELDS") ?? "0"
            guard ["0", "1"].contains(routing) else { throw Failure("Window routing must be explicitly 0 or 1.") }
            report["explicit_window_fields"] = routing == "1"
            let factory = setting("HEYDASH_TARGETED_INPUT_FACTORY") ?? "coregraphics"
            guard ["coregraphics", "appkit"].contains(factory) else { throw Failure("Unknown public event factory.") }
            report["event_factory"] = factory
            let windowSPI = setting("HEYDASH_TARGETED_INPUT_WINDOW_LOCATION_SPI") ?? "0"
            guard ["0", "1"].contains(windowSPI), windowSPI != "1" || factory == "appkit" else {
                throw Failure("Experimental window-location SPI requires explicit opt-in and AppKit factory.")
            }
            report["experimental_window_location_spi"] = windowSPI == "1"
            if windowSPI == "1" { report["probe"] = "experimental_CoreGraphics_window_location_feasibility" }
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
                throw Failure("Existing AX and event-posting permissions are required; no permission request was made.")
            }
            guard let uuid = UUID(uuidString: setting("HEYDASH_TARGETED_INPUT_RUN_ID") ?? "") else {
                throw Failure("HEYDASH_TARGETED_INPUT_RUN_ID must match the fresh fixture run UUID.")
            }
            let runID = uuid.uuidString.lowercased()
            let directory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("work/HeyDashTargetedInputProbe-20260925", isDirectory: true)
            let expectedApp = directory.appendingPathComponent("HeyDash Targeted Input Probe.app")
                .resolvingSymlinksInPath().standardizedFileURL
            let stateURL = directory.appendingPathComponent(runID).appendingPathComponent("state.json")
            let candidates = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
            guard candidates.count == 1, let app = candidates.first,
                  app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == expectedApp,
                  let launchDate = app.launchDate, !app.isActive else {
                throw Failure("Exactly one inactive fixture at its repository-owned path is required.")
            }
            let pid = app.processIdentifier
            try audit.sample("before_bind", excluding: pid)
            let binding = try RunningApplicationBinder().bind(bundleIdentifier: bundleID)
            guard binding.application.processIdentifier == pid else { throw Failure("Bound PID did not match fixture.") }
            let initial = try readState(stateURL)
            let target = CGPoint(x: try initial.number("target_x"), y: try initial.number("target_y"))
            guard let initialFrame = initial.frame,
                  let observedFrame = binding.window.info.frame,
                  frame(observedFrame) == initialFrame, initialFrame.contains(target),
                  try initial.number("native_count") == 0, try initial.number("pixel_count") == 0,
                  try initial.number("text_characters") == 0, try initial.number("application_events") == 0,
                  try initial.flag("receiver_instrumented") else {
                throw Failure("A fresh, exact one-window fixture with matching AX/CG geometry is required.")
            }
            let windowID = try initial.number("window_id")
            guard windowID > 0, windowID <= Double(UInt32.max), windowID.rounded() == windowID else {
                throw Failure("Invalid fixture window ID.")
            }
            let mode = try initial.string("mode")
            guard ["raw", "prepared"].contains(mode) else { throw Failure("Unexpected fixture mode.") }
            report["run_id"] = runID
            report["mode"] = mode
            report["accepts_first_mouse"] = try initial.flag("accepts_first_mouse")
            report["fixture_pid"] = pid
            report["window_id"] = windowID
            report["initial_state"] = initial.raw

            func validate(_ phase: String) throws -> State {
                try Task.checkCancellation()
                try audit.sample(phase, excluding: pid)
                guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), !app.isTerminated,
                      app.launchDate == launchDate, !app.isActive,
                      try binding.window.identity.isStillSelected() else {
                    throw Failure("Fixture inactive state, process/window identity, cancellation or permission guard failed.")
                }
                let current = try readState(stateURL)
                let age = Date().timeIntervalSince1970 * 1_000 - (try current.number("unix_ms"))
                guard age >= 0, age <= 1_000, try current.string("run_id") == runID,
                      try current.string("bundle_id") == bundleID, try current.number("pid") == Double(pid),
                      try current.number("launch_unix") == launchDate.timeIntervalSince1970,
                      try current.number("window_id") == windowID, try current.string("mode") == mode,
                      try current.flag("receiver_instrumented"),
                      try current.flag("window_visible"), try !current.flag("window_miniaturized"),
                      current.frame == initialFrame,
                      try current.number("target_x") == target.x, try current.number("target_y") == target.y else {
                    throw Failure("Fixture manifest is stale or target geometry/identity changed.")
                }
                let selected = try ApplicationWindowReader().selectedWindowObservation(processIdentifier: pid, expectedBundleIdentifier: bundleID)
                guard selected.identity.isSameWindow(as: binding.window.identity),
                      selected.info.frame.map(frame) == initialFrame else { throw Failure("Exact AX window geometry changed.") }
                let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID)) as? [[String: Any]]
                guard let row = rows?.first, rows?.count == 1,
                      (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                      (row[kCGWindowNumber as String] as? NSNumber)?.doubleValue == windowID,
                      (row[kCGWindowIsOnscreen as String] as? Bool) == true,
                      let bounds = row[kCGWindowBounds as String] as? [String: Any],
                      State(raw: ["window_frame": bounds]).frame == initialFrame else {
                    throw Failure("Native window ownership or current on-screen frame could not be confirmed.")
                }
                try audit.sample(phase + "_ready", excluding: pid)
                try Task.checkCancellation()
                guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), !app.isTerminated,
                      !app.isActive, app.launchDate == launchDate,
                      try binding.window.identity.isStillSelected() else {
                    throw Failure("Final immediate pre-dispatch target/permission guard failed.")
                }
                return current
            }

            guard let source = CGEventSource(stateID: .privateState) else { throw Failure("Private source unavailable.") }
            func mouse(_ type: CGEventType) -> CGEvent? {
                if factory == "coregraphics" {
                    return CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)
                }
                let local = NSPoint(x: target.x - initialFrame.minX, y: initialFrame.maxY - target.y)
                let native = NSEvent.mouseEvent(
                    with: type == .leftMouseDown ? .leftMouseDown : .leftMouseUp,
                    location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: Int(windowID), context: nil, eventNumber: 1,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                )
                guard let event = native?.cgEvent else { return nil }
                event.setSource(source)
                event.location = target
                return event
            }
            guard let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw Failure("Could not allocate bounded input pairs; no input was sent.")
            }
            for event in [down, up, keyDown, keyUp] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            }
            for event in [down, up] { event.setIntegerValueField(.mouseEventClickState, value: 1) }
            if routing == "1" {
                for event in [down, up] {
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
                }
            }
            if windowSPI == "1" {
                // Test-only non-public OS primitive. Never used by production.
                // Verify setter/getter round trip before any event is posted.
                typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
                typealias GetWindowLocation = @convention(c) (CGEvent) -> CGPoint
                guard let library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW | RTLD_LOCAL) else {
                    throw Failure("Experimental CoreGraphics library unavailable; no input sent.")
                }
                defer { dlclose(library) }
                guard let setter = dlsym(library, "CGEventSetWindowLocation"),
                      let getter = dlsym(library, "CGEventGetWindowLocation") else {
                    throw Failure("Experimental window-coordinate symbols unavailable; no input sent.")
                }
                let setLocation = unsafeBitCast(setter, to: SetWindowLocation.self)
                let getLocation = unsafeBitCast(getter, to: GetWindowLocation.self)
                let topLeftLocal = CGPoint(x: target.x - initialFrame.minX, y: target.y - initialFrame.minY)
                for event in [down, up] {
                    setLocation(event, topLeftLocal)
                    guard getLocation(event) == topLeftLocal, event.location == target,
                          NSEvent(cgEvent: event)?.windowNumber == Int(windowID) else {
                        throw Failure("Window-coordinate round trip changed global coordinates/identity; no input sent.")
                    }
                }
                report["window_location_spi_readback"] = ["x": topLeftLocal.x, "y": topLeftLocal.y]
            }
            let units = Array(marker.utf16)
            units.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base) }
            }

            _ = try validate("before_pixel_pair")
            report["sent_mouse_window_number"] = NSEvent(cgEvent: down)?.windowNumber ?? -1
            report["sent_window_hint"] = down.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            report["sent_handler_window_hint"] = down.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
            let clickStart = DispatchTime.now().uptimeNanoseconds
            postBalancedPair(down, up, pid: pid)
            report["mouse_pairs_dispatched"] = 1
            try audit.sample("after_pixel_pair", excluding: pid)
            let afterClick = try await poll(stateURL, audit: audit, pid: pid, phase: "pixel") { state in
                try state.number("mouse_up_events") >= 1
            }
            report["pixel_observation_ms"] = elapsed(clickStart)
            report["pixel_raw_delivery"] = try afterClick.number("mouse_down_events") == 1 && afterClick.number("mouse_up_events") == 1
            report["pixel_accepted_mutation"] = try afterClick.number("pixel_count") == 1
            report["after_pixel_state"] = afterClick.raw

            let beforeText = try validate("before_text_pair")
            guard try beforeText.number("native_count") == 0,
                  try beforeText.number("pixel_count") <= 1, try beforeText.number("text_characters") == 0 else {
                throw Failure("Unexpected receiver mutation; no keyboard input will be sent.")
            }
            let textStart = DispatchTime.now().uptimeNanoseconds
            postBalancedPair(keyDown, keyUp, pid: pid)
            report["keyboard_pairs_dispatched"] = 1
            try audit.sample("after_text_pair", excluding: pid)
            let final = try await poll(stateURL, audit: audit, pid: pid, phase: "text") { state in
                try state.number("key_up_events") >= 1
            }
            report["text_observation_ms"] = elapsed(textStart)
            report["text_raw_delivery"] = try final.number("key_down_events") == 1 && final.number("key_up_events") == 1
            report["text_accepted_mutation"] = try final.flag("marker_matches")
            report["final_state"] = final.raw
            guard try final.number("native_count") == 0, try final.number("pixel_count") <= 1,
                  try final.number("mouse_down_events") <= 1, try final.number("mouse_up_events") <= 1,
                  try final.number("key_down_events") <= 1, try final.number("key_up_events") <= 1 else {
                throw Failure("Unexpected or duplicate receiver side effects.")
            }
            try audit.sample("completed", excluding: pid)
            guard try binding.window.identity.isStillSelected() else { throw Failure("Target changed during verification.") }
            report["status"] = "completed_feasibility_probe"
        } catch {
            report["failure"] = error.localizedDescription
            throw error
        }
    }

    // Once down is posted, always balance it to the same PID. No throwing code
    // or suspension occurs inside the pair; never redirect cleanup globally.
    private func postBalancedPair(_ down: CGEvent, _ up: CGEvent, pid: Int32) {
        defer { up.postToPid(pid) }
        down.postToPid(pid)
    }

    private func readState(_ url: URL) throws -> State {
        let data = try Data(contentsOf: url)
        guard data.count <= 32_768,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("Invalid bounded fixture manifest.") }
        return State(raw: raw)
    }

    private func poll(_ url: URL, audit: Audit, pid: Int32, phase: String,
                      complete: (State) throws -> Bool) async throws -> State {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            try Task.checkCancellation()
            try audit.sample(phase + "_poll", excluding: pid)
            let state = try readState(url)
            if try complete(state) || elapsed(start) >= 1_000 {
                // Give the receiver one bounded settling interval, never redispatch.
                try await Task.sleep(for: .milliseconds(100))
                try audit.sample(phase + "_settled", excluding: pid)
                return try readState(url)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func frame(_ value: WindowFrame) -> CGRect { CGRect(x: value.x, y: value.y, width: value.width, height: value.height) }
    private func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    private func emit(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print("HEYDASH_TARGETED_INPUT_FEASIBILITY=" + text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "Public PID-targeted input feasibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

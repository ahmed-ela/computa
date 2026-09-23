import AppKit
import AutomationCore
import Foundation
import XCTest

/// Opt-in, model-free Calculator action probe. Only Calculator is mutated,
/// and it is cleared before and after every measured trial. Timing excludes
/// app activation, setup clear, model inference, App Server, and approval UI.
@MainActor
final class DriverActionLatencyLiveTests: XCTestCase {
    private let bundleID = "com.apple.calculator"

    private struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func testCalculatorSemanticAndKnownCenterClick() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LOCALCODEX_DRIVER_ACTION_PROBE"] == "1",
            "Set LOCALCODEX_DRIVER_ACTION_PROBE=1 to opt in."
        )
        let repetitions = Int(environment["LOCALCODEX_DRIVER_ACTION_REPS"] ?? "6") ?? 0
        guard (1 ... 20).contains(repetitions) else {
            throw ProbeError(message: "LOCALCODEX_DRIVER_ACTION_REPS must be 1...20.")
        }
        let permissions = PermissionInspector().current()
        try XCTSkipUnless(permissions.accessibility == .granted, "Accessibility is not granted.")
        try XCTSkipUnless(
            permissions.screenRecording == .granted,
            "Screen Recording is required to bind the coordinate action to an exact window ID."
        )
        _ = NSApplication.shared
        let controller = ComputerInputController()
        let app = try await controller.launchOrActivateApplication(bundleIdentifier: bundleID)
        guard app.bundleIdentifier == bundleID else {
            throw ProbeError(message: "Calculator did not activate.")
        }
        defer { try? clearCalculator(processID: app.processIdentifier) }

        var failures = [String]()
        for repetition in 1 ... repetitions {
            for method in ["semantic", "known_center"] {
                do {
                    try clearCalculator(processID: app.processIdentifier)
                    let before = try observeCalculator(processID: app.processIdentifier)
                    guard displayValue(before.snapshot) == "0",
                          let one = uniqueButton("1", in: before.snapshot),
                          let oneFrame = one.frame,
                          oneFrame.width > 0, oneFrame.height > 0,
                          try before.session.focusState(in: before.snapshot) == .focused,
                          let focused = try FocusedWindowReader().focusedWindowObservation(),
                          focused.info.processIdentifier == app.processIdentifier,
                          focused.info.bundleIdentifier == bundleID,
                          let windowFrame = focused.info.frame else {
                        throw ProbeError(message: "Calculator baseline or focused digit-1 button is not valid.")
                    }
                    let point = ScreenPoint(
                        x: oneFrame.x + oneFrame.width / 2,
                        y: oneFrame.y + oneFrame.height / 2
                    )
                    guard point.x >= windowFrame.x,
                          point.y >= windowFrame.y,
                          point.x < windowFrame.x + windowFrame.width,
                          point.y < windowFrame.y + windowFrame.height,
                          try focused.identity.isStillFocused() else {
                        throw ProbeError(message: "The target is outside the focused Calculator window.")
                    }
                    let expectedWindowID: UInt32?
                    if method == "known_center" {
                        let windows = try await WindowScreenshotter().availableWindows()
                        expectedWindowID = try uniqueWindowID(
                            matching: focused.info,
                            in: windows
                        )
                    } else {
                        expectedWindowID = nil
                    }

                    let actionStart = DispatchTime.now().uptimeNanoseconds
                    if method == "semantic" {
                        // This is the V2-style refresh-and-rebind native
                        // action primitive, but without a user approval wait.
                        try before.session.refreshAndPerform(
                            .press, at: one.index, in: before.snapshot
                        )
                    } else {
                        // This measures motor input at an AX-derived exact
                        // center, not a model's visual target localization.
                        // Recheck the retained AX identity and actual z-order
                        // synchronously adjacent to the global input event.
                        guard let expectedWindowID,
                              try focused.identity.isStillFocused() else {
                            throw ProbeError(message: "Calculator lost exact window focus before click.")
                        }
                        try WindowHitTestVerifier().verifyUnobstructed(
                            expectedWindowID: expectedWindowID,
                            points: [point]
                        )
                        try controller.click(at: point)
                    }
                    let actionMS = milliseconds(since: actionStart)

                    let verifyStart = DispatchTime.now().uptimeNanoseconds
                    var finalDisplay: String?
                    for _ in 0 ..< 40 {
                        let after = try observeCalculator(processID: app.processIdentifier)
                        finalDisplay = displayValue(after.snapshot)
                        if finalDisplay == "1" { break }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    let verifyMS = milliseconds(since: verifyStart)
                    let passed = finalDisplay == "1"
                    emit([
                        "schema": "localcodex.driver-action.v1",
                        "case_id": method == "semantic"
                            ? "native.ax.press" : "native.known_center.click",
                        "driver": "localcodex.automationcore",
                        "repetition": repetition,
                        "success": passed,
                        "action_ms": actionMS,
                        "verification_ms": verifyMS,
                        "display_before": "0",
                        "display_after": finalDisplay ?? "missing",
                    ])
                    if !passed { failures.append("\(method) repetition \(repetition): display \(finalDisplay ?? "missing")") }
                } catch {
                    emit([
                        "schema": "localcodex.driver-action.v1",
                        "case_id": method == "semantic"
                            ? "native.ax.press" : "native.known_center.click",
                        "driver": "localcodex.automationcore",
                        "repetition": repetition,
                        "success": false,
                        "error": String(describing: error),
                    ])
                    failures.append("\(method) repetition \(repetition): \(error)")
                }
            }
        }
        try clearCalculator(processID: app.processIdentifier)
        let final = try observeCalculator(processID: app.processIdentifier)
        XCTAssertEqual(displayValue(final.snapshot), "0", "Calculator must be restored to clear state.")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func observeCalculator(processID: Int32) throws -> (
        session: AccessibilitySession, snapshot: AccessibilityTreeSnapshot
    ) {
        guard let focused = try FocusedWindowReader().focusedWindow(),
              focused.processIdentifier == processID,
              focused.bundleIdentifier == bundleID else {
            throw ProbeError(message: "Calculator lost focus.")
        }
        let session = AccessibilitySession(
            processIdentifier: processID,
            bundleIdentifier: bundleID
        )
        return (session, try session.snapshot(limits: .agentDefault))
    }

    private func clearCalculator(processID: Int32) throws {
        let observation = try observeCalculator(processID: processID)
        guard let clear = uniqueButton("All Clear", in: observation.snapshot)
                ?? uniqueButton("Clear", in: observation.snapshot),
              try observation.session.focusState(in: observation.snapshot) == .focused else {
            throw ProbeError(message: "Calculator All Clear is not uniquely focused.")
        }
        try observation.session.refreshAndPerform(
            .press, at: clear.index, in: observation.snapshot
        )
        let after = try observeCalculator(processID: processID)
        guard displayValue(after.snapshot) == "0" else {
            throw ProbeError(message: "Calculator did not clear to zero.")
        }
    }

    private func uniqueButton(
        _ label: String,
        in snapshot: AccessibilityTreeSnapshot
    ) -> AccessibilityTreeElement? {
        let matches = snapshot.elements.filter { element in
            element.role == "AXButton"
                && [element.title, element.elementDescription, element.identifier]
                    .contains(where: { $0 == label })
                && element.supportedActions.contains(SemanticAXAction.press.rawValue)
                && element.isEnabled != false
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func displayValue(_ snapshot: AccessibilityTreeSnapshot) -> String? {
        let candidates = snapshot.elements.filter { element in
            element.role != "AXButton"
                && [element.title, element.elementDescription, element.identifier]
                    .contains(where: { $0 == "Edit field" })
                && element.value != nil
        }
        return candidates.count == 1 ? candidates[0].value : nil
    }

    private func uniqueWindowID(
        matching focused: FocusedWindowInfo,
        in windows: [CapturableWindowInfo]
    ) throws -> UInt32 {
        guard let frame = focused.frame else {
            throw ProbeError(message: "Focused Calculator window has no frame.")
        }
        let matches = windows.filter { window in
            window.isOnScreen
                && window.owningProcessIdentifier == focused.processIdentifier
                && window.owningBundleIdentifier == focused.bundleIdentifier
                && sameFrame(window.frame, frame, tolerance: 8)
        }
        guard matches.count == 1, let windowID = matches.first?.windowID else {
            throw ProbeError(message: "Calculator has no unique ScreenCaptureKit window binding.")
        }
        return windowID
    }

    private func sameFrame(
        _ left: WindowFrame,
        _ right: WindowFrame,
        tolerance: Double
    ) -> Bool {
        [left.x, left.y, left.width, left.height,
         right.x, right.y, right.width, right.height].allSatisfy(\.isFinite)
            && abs(left.x - right.x) <= tolerance
            && abs(left.y - right.y) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func emit(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            XCTFail("Could not serialize Calculator driver action result.")
            return
        }
        print("DRIVER_ACTION_JSON \(line)")
    }
}

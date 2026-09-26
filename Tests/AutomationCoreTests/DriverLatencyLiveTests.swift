import AppKit
import AutomationCore
import CoreGraphics
import Foundation
import XCTest

/// Read-only primitive timings for the installed macOS driver. These do not
/// include model inference, App Server dispatch, native approvals, or V2's
/// post-approval target revalidation. Compare them only to equally direct
/// CUA primitive calls, not to a full agent turn.
@MainActor
final class DriverLatencyLiveTests: XCTestCase {
    private struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func testFocusedWindowReadPrimitives() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["LOCALCODEX_DRIVER_PROBE"] == "1",
            "Set LOCALCODEX_DRIVER_PROBE=1 to opt in to live read-only driver timings."
        )
        let bundleID = try XCTUnwrap(
            environment["LOCALCODEX_DRIVER_PROBE_BUNDLE_ID"],
            "Set LOCALCODEX_DRIVER_PROBE_BUNDLE_ID to the already-focused safe target."
        )
        try XCTSkipUnless(
            ["com.apple.calculator", "com.google.Chrome"].contains(bundleID),
            "This probe is limited to Calculator and Chrome."
        )
        let repetitions = Int(environment["LOCALCODEX_DRIVER_PROBE_REPS"] ?? "5") ?? 0
        guard (1 ... 30).contains(repetitions) else {
            throw ProbeError(message: "LOCALCODEX_DRIVER_PROBE_REPS must be 1...30.")
        }
        let expectedAX = environment["LOCALCODEX_DRIVER_PROBE_EXPECTED_AX"]
        let expectedChromeURL: String?
        if bundleID == "com.google.Chrome" {
            guard let rawURL = environment["LOCALCODEX_DRIVER_PROBE_EXPECTED_URL"],
                  let url = URL(string: rawURL),
                  url.scheme == "https", url.host == "example.com", url.path == "/",
                  expectedAX == "Example Domain" else {
                throw ProbeError(message: "Chrome probe requires the exact public example.com URL and Example Domain AX oracle.")
            }
            expectedChromeURL = rawURL
        } else {
            guard expectedAX == "Edit field" else {
                throw ProbeError(
                    message: "Calculator probe requires the exact non-button Edit field display oracle."
                )
            }
            expectedChromeURL = nil
        }
        let path = environment["LOCALCODEX_DRIVER_PROBE_PATH"] ?? "both"
        guard ["ax", "capture", "both"].contains(path) else {
            throw ProbeError(message: "LOCALCODEX_DRIVER_PROBE_PATH must be ax, capture, or both.")
        }
        let permissions = PermissionInspector().current()
        try XCTSkipUnless(permissions.accessibility == .granted, "Accessibility is not granted.")
        if path != "ax" {
            try XCTSkipUnless(permissions.screenRecording == .granted, "Screen Recording is not granted.")
            _ = NSApplication.shared
        }

        // Setup is intentionally outside every timed observation. The live
        // test can opt in to activating a known safe app when the host runner
        // starts with Macrouse or Codex as the foreground application.
        if environment["LOCALCODEX_DRIVER_PROBE_ACTIVATE"] == "1" {
            _ = try await ComputerInputController().launchOrActivateApplication(
                bundleIdentifier: bundleID
            )
        }

        let initial = try focusedWindow(expectedBundleID: bundleID)
        let processID = initial.processIdentifier
        try requireSafeChromePage(processID: processID, expectedURL: expectedChromeURL)
        let casePrefix = bundleID == "com.apple.calculator" ? "native" : "chrome"
        let screenshotter = WindowScreenshotter()
        let formatter = AccessibilitySnapshotTextFormatter(
            prioritizesRelevantElements: expectedAX != nil,
            preferredText: expectedAX,
            usesCompactElementLines: true
        )
        let warmups = 1
        var failures = [String]()

        for sample in 0 ..< (warmups + repetitions) {
            let isWarmup = sample < warmups
            let repetition = isWarmup ? 0 : sample - warmups + 1

            if path != "capture" { do {
                let before = try focusedWindow(expectedBundleID: bundleID, processID: processID)
                try requireSafeChromePage(processID: processID, expectedURL: expectedChromeURL)
                let started = DispatchTime.now().uptimeNanoseconds
                let snapshot = try AccessibilitySession(
                    processIdentifier: processID,
                    bundleIdentifier: bundleID
                ).snapshot(limits: .agentDefault)
                let rendered = formatter.format(snapshot)
                let elapsed = milliseconds(since: started)
                let after = try focusedWindow(expectedBundleID: bundleID, processID: processID)
                try requireSafeChromePage(processID: processID, expectedURL: expectedChromeURL)
                let hasExpectedElement = bundleID == "com.apple.calculator"
                    ? hasUniqueCalculatorDisplay(in: snapshot)
                    : expectedAX.map { expected in
                        snapshot.elements.contains { element in
                            [element.title, element.elementDescription, element.value]
                                .compactMap { $0 }
                                .contains { $0.localizedCaseInsensitiveContains(expected) }
                        }
                    } ?? true
                let passed = sameWindow(before, after)
                    && snapshot.application.processIdentifier == processID
                    && snapshot.rootIndex != nil
                    && !snapshot.elements.isEmpty
                    && rendered.hasPrefix("AXSNAPSHOT id=")
                    && hasExpectedElement
                emit([
                    "schema": "localcodex.driver-primitive.v1",
                    "case_id": "\(casePrefix).ax.read",
                    "driver": "localcodex.automationcore",
                    "phase": "snapshot+format",
                    "bundle_id": bundleID,
                    "process_id": processID,
                    "repetition": repetition,
                    "warmup": isWarmup,
                    "duration_ms": elapsed,
                    "success": passed,
                    "element_count": snapshot.elements.count,
                    "rendered_characters": rendered.count,
                    "source_truncated": snapshot.wasTruncated,
                    "expected_element_found": hasExpectedElement,
                ])
                if !passed { failures.append("\(casePrefix).ax.read repetition \(repetition)") }
            } catch {
                emitFailure(caseID: "\(casePrefix).ax.read", bundleID: bundleID,
                            processID: processID, repetition: repetition,
                            warmup: isWarmup, error: error)
                failures.append("\(casePrefix).ax.read repetition \(repetition): \(error)")
            } }

            if path != "ax" { do {
                let before = try focusedWindow(expectedBundleID: bundleID, processID: processID)
                try requireSafeChromePage(processID: processID, expectedURL: expectedChromeURL)
                let started = DispatchTime.now().uptimeNanoseconds
                let windows = try await screenshotter.availableWindows()
                guard let window = matchingWindow(for: before, in: windows) else {
                    throw ProbeError(message: "No unique ScreenCaptureKit match for focused window.")
                }
                let image = try await screenshotter.captureWindow(
                    windowID: window.windowID,
                    scaleFactor: 1,
                    showsCursor: false
                )
                let elapsed = milliseconds(since: started)
                let after = try focusedWindow(expectedBundleID: bundleID, processID: processID)
                try requireSafeChromePage(processID: processID, expectedURL: expectedChromeURL)
                let uniqueSamples = sampledColorCount(image)
                let passed = sameWindow(before, after)
                    && image.width > 0 && image.height > 0
                    && uniqueSamples > 1
                emit([
                    "schema": "localcodex.driver-primitive.v1",
                    "case_id": "\(casePrefix).capture",
                    "driver": "localcodex.automationcore",
                    "phase": "discover+window_capture",
                    "bundle_id": bundleID,
                    "process_id": processID,
                    "repetition": repetition,
                    "warmup": isWarmup,
                    "duration_ms": elapsed,
                    "success": passed,
                    "image_width": image.width,
                    "image_height": image.height,
                    "sampled_color_count": uniqueSamples,
                ])
                if !passed { failures.append("\(casePrefix).capture repetition \(repetition)") }
            } catch {
                emitFailure(caseID: "\(casePrefix).capture", bundleID: bundleID,
                            processID: processID, repetition: repetition,
                            warmup: isWarmup, error: error)
                failures.append("\(casePrefix).capture repetition \(repetition): \(error)")
            } }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func focusedWindow(
        expectedBundleID: String,
        processID: Int32? = nil
    ) throws -> FocusedWindowInfo {
        guard let focused = try FocusedWindowReader().focusedWindow(),
              focused.bundleIdentifier == expectedBundleID,
              processID == nil || focused.processIdentifier == processID,
              focused.frame != nil else {
            throw ProbeError(message: "The intended app/window is not focused.")
        }
        return focused
    }

    private func hasUniqueCalculatorDisplay(
        in snapshot: AccessibilityTreeSnapshot
    ) -> Bool {
        snapshot.elements.filter { element in
            element.role != "AXButton"
                && [element.title, element.elementDescription, element.identifier]
                    .contains(where: { $0 == "Edit field" })
                && element.value?.isEmpty == false
        }.count == 1
    }

    private func requireSafeChromePage(processID: Int32, expectedURL: String?) throws {
        guard let expectedURL else { return }
        guard let focused = try FocusedWindowReader().focusedWindow(),
              focused.processIdentifier == processID,
              focused.bundleIdentifier == "com.google.Chrome",
              focused.title?.localizedCaseInsensitiveContains("Example Domain") == true else {
            throw ProbeError(message: "The safe Example Domain Chrome window is not focused.")
        }
        let session = AccessibilitySession(
            processIdentifier: processID,
            bundleIdentifier: "com.google.Chrome"
        )
        let snapshot = try session.snapshot(limits: .agentDefault)
        guard try session.focusState(in: snapshot) == .focused else {
            throw ProbeError(message: "The expected Chrome AX window is not frontmost and focused.")
        }
        let addresses = snapshot.elements.filter { element in
            element.role == "AXTextField"
                && [element.title, element.elementDescription]
                    .contains(where: { $0 == "Address and search bar" })
                && chromeAddress(element.value, matches: expectedURL)
        }
        let headings = snapshot.elements.filter { element in
            element.role == "AXHeading"
                && [element.title, element.elementDescription, element.value]
                    .contains(where: { $0 == "Example Domain" })
                && hasAncestor(role: "AXWebArea", of: element, in: snapshot)
        }
        guard addresses.count == 1, headings.count == 1 else {
            throw ProbeError(message: "The focused Chrome page is not the exact safe example.com target.")
        }
    }

    private func chromeAddress(_ value: String?, matches expectedURL: String) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        return value == expectedURL || "https://\(value)" == expectedURL
    }

    private func hasAncestor(
        role: String,
        of element: AccessibilityTreeElement,
        in snapshot: AccessibilityTreeSnapshot
    ) -> Bool {
        var index = element.parentIndex
        while let current = index, let ancestor = snapshot.element(at: current) {
            if ancestor.role == role { return true }
            index = ancestor.parentIndex
        }
        return false
    }

    private func matchingWindow(
        for focused: FocusedWindowInfo,
        in windows: [CapturableWindowInfo]
    ) -> CapturableWindowInfo? {
        guard let frame = focused.frame else { return nil }
        let matches = windows.filter { window in
            window.isOnScreen
                && window.owningProcessIdentifier == focused.processIdentifier
                && window.owningBundleIdentifier == focused.bundleIdentifier
                && sameFrame(window.frame, frame, tolerance: 8)
        }
        if matches.count != 1 {
            let candidates = windows.filter {
                $0.isOnScreen
                    && $0.owningProcessIdentifier == focused.processIdentifier
                    && $0.owningBundleIdentifier == focused.bundleIdentifier
            }
            print("DRIVER_PROBE_MATCH focused_frame=\(frame) matching=\(matches.count) "
                + "candidate_frames=\(candidates.map(\.frame))")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func sameWindow(_ left: FocusedWindowInfo, _ right: FocusedWindowInfo) -> Bool {
        left.processIdentifier == right.processIdentifier
            && left.bundleIdentifier == right.bundleIdentifier
            && left.title == right.title
            && left.frame.flatMap { leftFrame in
                right.frame.map { sameFrame(leftFrame, $0, tolerance: 2) }
            } == true
    }

    private func sameFrame(_ left: WindowFrame, _ right: WindowFrame, tolerance: Double) -> Bool {
        [left.x, left.y, left.width, left.height,
         right.x, right.y, right.width, right.height].allSatisfy(\.isFinite)
            && abs(left.x - right.x) <= tolerance
            && abs(left.y - right.y) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }

    private func sampledColorCount(_ image: CGImage) -> Int {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var colors = Set<UInt32>()
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                let color = UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3])
                colors.insert(color)
            }
            return colors.count
        }
    }

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func emitFailure(
        caseID: String,
        bundleID: String,
        processID: Int32,
        repetition: Int,
        warmup: Bool,
        error: Error
    ) {
        emit([
            "schema": "localcodex.driver-primitive.v1",
            "case_id": caseID,
            "driver": "localcodex.automationcore",
            "bundle_id": bundleID,
            "process_id": processID,
            "repetition": repetition,
            "warmup": warmup,
            "success": false,
            "error": String(describing: error),
        ])
    }

    private func emit(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            XCTFail("Could not serialize driver probe result.")
            return
        }
        print("DRIVER_PROBE_JSON \(line)")
    }
}

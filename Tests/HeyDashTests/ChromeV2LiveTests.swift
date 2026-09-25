import AppKit
import ApplicationServices
import AutomationCore
import Foundation
import XCTest
@testable import HeyDash

/// Opt-in Chrome gates for the versioned computer contract. Read-only model
/// gates open a public URL. The separate deterministic focus gate also permits
/// one Cmd+L on that disposable tab. No blocked file fixtures or visual clicks.
@MainActor
final class ChromeV2LiveTests: XCTestCase {
    private let bundleID = "com.google.Chrome"
    private let snapshotQuery = "Example Domain"
    private let maxSnapshotCalls = 3

    private final class ApprovalAudit {
        var approvedOpen = false
        var unexpected = [String]()
        var handledIDs = Set<String>()
    }

    private struct GateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class ShutdownAudit {
        var report: RuntimeShutdownReport?
    }

    /// Read-only coverage probe of the current normal Chrome window. Default
    /// setup is passive; a separate opt-in may activate the exact existing PID
    /// once before retaining the measurement window. Never opens tabs, posts
    /// input, navigates, or prints page content.
    func testCurrentChromeOrdersAccessibilityCoverageReadOnly() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_CHROME_AX_COVERAGE_TEST"] == "1",
                          "Opt in with TEST_RUNNER_HEYDASH_LIVE_CHROME_AX_COVERAGE_TEST=1.")
        guard PermissionInspector().current().accessibility == .granted else {
            throw GateError(message: "Coverage preflight: Accessibility permission is not granted to the test host.")
        }
        guard let rawPID = ProcessInfo.processInfo.environment["HEYDASH_EXPECTED_CHROME_PID"],
              let expectedPID = Int32(rawPID), expectedPID > 0 else {
            throw GateError(message: "Coverage preflight: expected Chrome PID is missing or invalid.")
        }
        guard let running = NSRunningApplication(processIdentifier: expectedPID), !running.isTerminated else {
            throw GateError(message: "Coverage preflight: expected Chrome process is not running.")
        }
        guard running.bundleIdentifier == bundleID,
              running.bundleURL?.standardizedFileURL.path == "/Applications/Google Chrome.app",
              !running.isTerminated else {
            throw GateError(message: "Coverage preflight: expected process is not the normal installed Chrome application.")
        }
        if ProcessInfo.processInfo.environment["HEYDASH_AX_COVERAGE_ACTIVATE"] == "1" {
            let setupPIDs = runningChromePIDs()
            print("HEYDASH_CHROME_AX_COVERAGE_SETUP setup_activation=true")
            // Exactly one call to the existing bounded native activation path.
            // Its ordinary-profile check rejects substitutions; native errors
            // propagate unchanged, without a fixture retry or fallback launch.
            let activated = try await ExistingChromeController().activate(processIdentifier: expectedPID)
            guard activated.processIdentifier == expectedPID, runningChromePIDs() == setupPIDs else {
                throw GateError(message: "Coverage setup: exact existing Chrome identity changed during activation.")
            }
        }
        // XCTest may initially activate its inert host window. Give the human
        // operator a bounded chance to restore Chrome; the probe never does so.
        print("HEYDASH_CHROME_AX_COVERAGE_READY passive_focus_wait_seconds=15")
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedPID {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw GateError(message: "Coverage preflight: expected Chrome did not become foreground during the 15-second passive wait; no activation was attempted.")
            }
            guard !running.isTerminated else {
                throw GateError(message: "Coverage preflight: expected Chrome process exited during the passive wait.")
            }
            try await Task.sleep(for: min(.milliseconds(100), remaining))
        }
        guard PermissionInspector().current().accessibility == .granted else {
            throw GateError(message: "Coverage preflight: Accessibility permission changed during the passive wait.")
        }
        let anchor: FocusedWindowObservation
        do {
            guard let observation = try FocusedWindowReader().focusedWindowObservation() else {
                throw GateError(message: "Coverage preflight: the system reports no focused AX window.")
            }
            anchor = observation
        } catch let error as GateError {
            throw error
        } catch {
            throw GateError(message: "Coverage preflight: focused AX window lookup failed.")
        }
        guard anchor.info.processIdentifier == expectedPID else {
            throw GateError(message: "Coverage preflight: focused AX window belongs to a different process.")
        }
        guard (try? anchor.identity.isStillFocused()) == true else {
            throw GateError(message: "Coverage preflight: exact focused AX window identity could not be confirmed.")
        }
        let beforePIDs = runningChromePIDs()
        func verifyWindow() throws {
            guard runningChromePIDs() == beforePIDs,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID,
                  try anchor.identity.isStillFocused() else {
                throw GateError(message: "Coverage stopped because the exact retained Chrome window or process set changed.")
            }
        }
        func emit(_ row: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw GateError(message: "Coverage metrics could not be encoded.")
            }
            print("HEYDASH_CHROME_AX_COVERAGE \(text)")
        }
        func signals(_ text: String) -> [String: Bool] {
            let value = text.lowercased()
            return [
                "has_order_terms": value.contains("order"),
                "has_order_detail_terms": ["order placed", "track package", "buy it again", "return or replace"].contains(where: value.contains),
                "has_delivery_terms": ["arriving", "arrives", "delivered", "delivery", "shipped", "out for delivery"].contains(where: value.contains),
                "has_arrival_status_terms": ["arriving", "arrives", "delivered", "shipped", "out for delivery"].contains(where: value.contains),
            ]
        }
        func isOrdersAddress(_ value: String?) -> Bool {
            guard let value else { return false }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
                  let host = url.host?.lowercased(), host == "amazon.com" || host.hasSuffix(".amazon.com") else { return false }
            return ["/your-orders", "/orders", "/order-history"].contains(where: url.path.lowercased().contains)
        }
        let variants = [(16, 240), (16, 1_000), (24, 240), (24, 1_000), (32, 240), (32, 1_000), (16, 240)]
        for (pass, variant) in variants.enumerated() {
            try verifyWindow()
            let session = AccessibilitySession(processIdentifier: expectedPID, bundleIdentifier: bundleID,
                                               applicationName: "Google Chrome")
            let limits = try AccessibilityTreeLimits(maxDepth: variant.0, maxElements: variant.1,
                maxChildrenPerElement: 80, maxActionsPerElement: 12,
                maxTextLength: ComputerToolContract.maximumSemanticTextLength)
            let started = DispatchTime.now().uptimeNanoseconds
            let snapshot = try session.snapshot(limits: limits)
            let captureMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            try verifyWindow()
            guard try session.focusState(in: snapshot) == .focused else {
                throw GateError(message: "Coverage snapshot did not retain the exact focused window.")
            }
            let ordersAddress = snapshot.elements.contains {
                $0.role == "AXTextField" && $0.elementDescription == "Address and search bar" && isOrdersAddress($0.value)
            }
            guard ordersAddress else {
                throw GateError(message: "Coverage requires an observed Amazon Orders address in the current Chrome toolbar; no navigation was attempted.")
            }
            let formatter = AccessibilitySnapshotTextFormatter(elementLimit: limits.maxElements,
                fieldCharacterLimit: 72, actionLimit: 6, outputCharacterLimit: 3_000,
                prioritizesRelevantElements: true, usesCompactElementLines: true)
            let formatted = formatter.format(snapshot)
            let sourceText = snapshot.elements.flatMap { [$0.title, $0.elementDescription, $0.value, $0.help].compactMap { $0 } }.joined(separator: "\n")
            let documentElements = snapshot.elements.filter {
                $0.role == "AXWebArea" || $0.role == "AXDocument"
                    || hasAncestor(role: "AXWebArea", of: $0, in: snapshot)
                    || hasAncestor(role: "AXDocument", of: $0, in: snapshot)
            }
            let documentIndices = Set(documentElements.map(\.index))
            let documentSource = documentElements.flatMap { [$0.title, $0.elementDescription, $0.value, $0.help].compactMap { $0 } }.joined(separator: "\n")
            let documentFormatted = formatted.components(separatedBy: "\n").filter { line in
                guard line.hasPrefix("#"), let token = line.split(separator: " ").first,
                      let index = Int(token.dropFirst()) else { return false }
                return documentIndices.contains(index)
            }.joined(separator: "\n")
            var row: [String: Any] = [
                "phase": pass == variants.count - 1 ? "repeat_baseline" : "snapshot",
                "pass": pass + 1, "depth_limit": limits.maxDepth, "element_limit": limits.maxElements,
                "elements": snapshot.elements.count, "source_truncated": snapshot.wasTruncated,
                "max_observed_depth": snapshot.elements.map(\.depth).max() ?? 0,
                "elements_at_depth_limit": snapshot.elements.filter { $0.depth == limits.maxDepth }.count,
                "element_limit_reached": snapshot.elements.count == limits.maxElements,
                "web_area_count": snapshot.elements.filter { $0.role == "AXWebArea" }.count,
                "document_elements": documentElements.count,
                "link_count": snapshot.elements.filter { $0.role == "AXLink" }.count,
                "link_url_count": snapshot.elements.filter { $0.role == "AXLink" && $0.url != nil }.count,
                "formatted_link_url_count": formatted.components(separatedBy: "\n").filter { $0.contains(" url=\"") }.count,
                "formatted_characters": formatted.count,
                "formatted_lines": formatted.components(separatedBy: "\n").count - 1,
                "output_truncated": formatted.components(separatedBy: "\n").first?.contains("output_truncated=1") == true,
                "capture_ms": captureMilliseconds, "exact_window_verified": true, "orders_address_verified": true,
            ]
            for (key, value) in signals(sourceText) { row["source_" + key] = value }
            for (key, value) in signals(formatted) { row["formatted_" + key] = value }
            for (key, value) in signals(documentSource) { row["document_source_" + key] = value }
            for (key, value) in signals(documentFormatted) { row["document_formatted_" + key] = value }
            try verifyWindow()
            try emit(row)
        }

        // Count AXURL presence directly because the current snapshot data model
        // does not expose that attribute. No URL/label/title/value is logged.
        try verifyWindow()
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(expectedPID),
            kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
            let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            throw GateError(message: "Coverage could not retain the current Chrome AX window for URL-presence counts.")
        }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var seen: [AXUIElement] = []
        var urls = 0, links = 0, linksWithURL = 0, urlErrors = 0, childLimited = 0, maxDepth = 0
        var nonleafAtDepth = [16: 0, 24: 0, 32: 0]
        let started = DispatchTime.now().uptimeNanoseconds
        while seen.count < 1_000, let (element, depth) = stack.popLast() {
            if seen.count.isMultiple(of: 32) { try verifyWindow() }
            if seen.contains(where: { CFEqual($0, element) }) { continue }
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == expectedPID else {
                throw GateError(message: "Coverage encountered a changed AX element owner.")
            }
            seen.append(element)
            maxDepth = max(maxDepth, depth)
            var rawRole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success else {
                throw GateError(message: "Coverage encountered an unreadable AX role.")
            }
            let isLink = rawRole as? String == "AXLink"
            if isLink { links += 1 }
            var rawURL: CFTypeRef?
            let urlResult = AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &rawURL)
            if urlResult == .success, rawURL != nil {
                urls += 1
                if isLink { linksWithURL += 1 }
            } else if urlResult != .noValue && urlResult != .attributeUnsupported {
                urlErrors += 1
            }
            var childCount = 0
            let countResult = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &childCount)
            if countResult == .noValue || countResult == .attributeUnsupported { continue }
            guard countResult == .success else {
                throw GateError(message: "Coverage encountered an unreadable AX child count.")
            }
            if childCount > 0, nonleafAtDepth[depth] != nil { nonleafAtDepth[depth, default: 0] += 1 }
            guard depth < 32, childCount > 0 else { continue }
            if childCount > 80 { childLimited += 1 }
            var rawChildren: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0,
                min(childCount, 80), &rawChildren) == .success,
                let children = rawChildren as? [AXUIElement] else {
                throw GateError(message: "Coverage encountered an unreadable AX child batch.")
            }
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        try verifyWindow()
        var finalWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(expectedPID),
            kAXFocusedWindowAttribute as CFString, &finalWindow) == .success,
            let finalWindow, CFGetTypeID(finalWindow) == AXUIElementGetTypeID(), CFEqual(window, finalWindow) else {
            throw GateError(message: "Coverage's retained AX window changed during URL-presence traversal.")
        }
        try emit([
            "phase": "url_attribute_presence", "nodes": seen.count, "node_limit_reached": !stack.isEmpty,
            "max_observed_depth": maxDepth, "url_attribute_count": urls, "link_count": links,
            "links_with_url_attribute": linksWithURL, "url_attribute_errors": urlErrors,
            "child_limited_parent_count": childLimited,
            "nonleaf_nodes_at_depth_16": nonleafAtDepth[16, default: 0],
            "nonleaf_nodes_at_depth_24": nonleafAtDepth[24, default: 0],
            "nonleaf_nodes_at_depth_32": nonleafAtDepth[32, default: 0],
            "capture_ms": Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
            "exact_window_verified": true,
        ])
    }

    /// Test-only focus telemetry. Never records app names, window/control text,
    /// URLs, screenshots, or process identifiers; only known-target categories.
    @MainActor
    private final class FocusAudit {
        private let targetPID: Int32
        private let hostPID = ProcessInfo.processInfo.processIdentifier
        private let started = DispatchTime.now().uptimeNanoseconds
        private let file: FileHandle
        private var activationObserver: NSObjectProtocol?
        private var samples = 0
        private var stopped = false

        init(targetPID: Int32, directory: URL) throws {
            self.targetPID = targetPID
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("focus-audit.jsonl")
            try Data().write(to: url, options: .atomic)
            file = try FileHandle(forWritingTo: url)
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                Task { @MainActor [weak self] in
                    self?.record("workspace_activation", activatedPID: activatedPID)
                }
            }
            record("audit_started")
            print("HEYDASH_FOCUS_AUDIT_PATH \(url.path)")
        }

        func stop() {
            guard !stopped else { return }
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
            record("audit_stopped")
            stopped = true
            try? file.close()
        }

        private func category(_ pid: Int32?) -> String {
            guard let pid else { return "unknown" }
            return pid == targetPID ? "target_chrome" : pid == hostPID ? "heydash_host" : "other"
        }

        func record(
            _ phase: String, session: AccessibilitySession? = nil,
            snapshot: AccessibilityTreeSnapshot? = nil, error: Error? = nil,
            activatedPID: Int32? = nil
        ) {
            guard !stopped, samples < 500 else { return }
            samples += 1
            var row: [String: Any] = [
                "sample": samples,
                "elapsed_ms": (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
                "phase": phase,
                "workspace_frontmost": category(NSWorkspace.shared.frontmostApplication?.processIdentifier),
                "target_running": NSRunningApplication(processIdentifier: targetPID)?.isTerminated == false,
                "target_appkit_active": NSRunningApplication(processIdentifier: targetPID)?.isActive == true,
            ]
            if phase == "workspace_activation" { row["activated_application"] = category(activatedPID) }
            var frontmost: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(targetPID), kAXFrontmostAttribute as CFString, &frontmost
            )
            row["target_ax_frontmost_result"] = axResult.rawValue
            if axResult == .success, let flag = frontmost as? Bool { row["target_ax_frontmost"] = flag }
            do {
                row["system_focused_application"] = category(try FocusedWindowReader().focusedWindowIdentity()?.processIdentifier)
            } catch AutomationError.accessibilityFailure(_, let code) {
                row["system_focus_error_code"] = code
            } catch {
                row["system_focus_error"] = "other"
            }
            if let session, let snapshot {
                do { row["snapshot_focus_state"] = String(describing: try session.focusState(in: snapshot)) }
                catch AutomationError.accessibilityFailure(_, let code) { row["snapshot_focus_error_code"] = code }
                catch { row["snapshot_focus_error"] = "other" }
            }
            if let error {
                if let automationError = error as? AutomationError,
                   case .accessibilityFailure(_, let code) = automationError {
                    row["failure_ax_error_code"] = code
                } else {
                    row["failure_kind"] = "other"
                }
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                try file.write(contentsOf: data + Data([0x0a]))
                if let text = String(data: data, encoding: .utf8) { print("HEYDASH_FOCUS_AUDIT \(text)") }
            } catch {
                print("HEYDASH_FOCUS_AUDIT_WRITE_FAILED")
            }
        }
    }

    /// Deterministic transport, real production V2 native executor and approval
    /// dispatch. No model/owned App Server is involved. Only a disposable public
    /// tab is opened; the one approved input is Cmd+L after deliberate focus loss.
    func testNativeV2KeypressRestoresExactChromeAfterApprovalFocusLoss() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_NATIVE_CHROME_FOCUS_TEST"] == "1",
                          "Opt in with TEST_RUNNER_HEYDASH_LIVE_NATIVE_CHROME_FOCUS_TEST=1.")
        guard PermissionInspector().current().accessibility == .granted,
              let rawPID = ProcessInfo.processInfo.environment["HEYDASH_EXPECTED_CHROME_PID"],
              let expectedPID = Int32(rawPID), runningChromePIDs().contains(expectedPID) else {
            throw GateError(message: "Existing Chrome PID and granted test-host Accessibility are required.")
        }
        let beforePIDs = runningChromePIDs()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeyDashNativeChromeFocus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let focusAudit = try FocusAudit(targetPID: expectedPID, directory: root)
        defer { focusAudit.stop() }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NativeChromeFocusAppServer.ts")
        let executable = root.appendingPathComponent("native-focus-app-server.ts")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let pageURL = "https://example.com/?heydash_focus_id=\(UUID().uuidString)"
        try JSONSerialization.data(withJSONObject: ["pageURL": pageURL])
            .write(to: root.appendingPathComponent("native-focus.json"))
        let traceURL = root.appendingPathComponent("protocol.jsonl")
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.executable = .fixture(path: executable.path)
        config.codexHomePath = root.path
        config.protocolTracePath = traceURL.path
        let state = AppState(tasks: [], runtime: CodexAppServerRuntime(configuration: config),
                             preferences: isolatedTestPreferences())
        let focusWindow = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 360, height: 120),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        focusWindow.isReleasedWhenClosed = false
        focusWindow.title = "HeyDash native focus fixture"
        let focusWindowID = "heydash-native-focus-\(UUID().uuidString)"
        focusWindow.setAccessibilityIdentifier(focusWindowID)
        let focusLabel = NSTextField(labelWithString: "Harmless native focus verification")
        focusLabel.frame = NSRect(x: 20, y: 45, width: 320, height: 24)
        focusLabel.alignment = .center
        focusWindow.contentView?.addSubview(focusLabel)
        addTeardownBlock { @MainActor in focusWindow.close() }
        let events = Task { await state.startRuntime() }
        defer { events.cancel() }
        addTeardownBlock { @MainActor in
            let report = try await self.shutdownRuntimeBounded(state)
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            XCTAssertEqual(self.runningChromePIDs(), beforePIDs)
        }
        try await waitForConnection(state)
        XCTAssertEqual(state.accessMode, .askEveryTime)
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        focusAudit.record("native_before_submit")
        guard await state.submit(prompt: "Run the fixed public native-focus regression.", toTaskID: taskID) else {
            throw GateError(message: "The deterministic fixture turn was not accepted.")
        }
        var approvedOpen = false
        var approvedKey = false
        var pageReady = false
        var retainedWindow: FocusedWindowIdentity?
        var handled = Set<String>()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = Date().addingTimeInterval(40)
        do {
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("gate-failed").path) {
                    logNativeTabInventoryStructure(processID: expectedPID, phase: "failed_open_or_input")
                    throw GateError(message: "A production native tool failed in the deterministic fixture.")
                }
                if !pageReady, FileManager.default.fileExists(atPath: root.appendingPathComponent("opened").path) {
                    focusAudit.record("native_open_returned")
                    logNativeTabInventoryStructure(processID: expectedPID, phase: "opened_public_fixture")
                    try await verifyFocusedChromePage(processID: expectedPID, pageURL: pageURL, focusAudit: focusAudit)
                    try Data("ready".utf8).write(to: root.appendingPathComponent("page-ready"))
                    pageReady = true
                }
                for request in state.pendingApprovals where !handled.contains(request.id) {
                    handled.insert(request.id)
                    let details = jsonObject(request.details)
                    let tools = state.tasks.first(where: { $0.id == taskID })?.entries.compactMap(\.toolEvent) ?? []
                    var allowed = false
                    if !approvedOpen, tools.isEmpty,
                       request.taskID == taskID, request.kind == .computerUse,
                       request.title == "Allow an application action?",
                       request.summary == "Open \(bundleID) at \(pageURL)",
                       details?["bundle_id"] as? String == bundleID,
                       details?["url"] as? String == pageURL,
                       Set(details?.keys.map { $0 } ?? []) == ["bundle_id", "url"] {
                        approvedOpen = true
                        allowed = true
                    } else if approvedOpen, !approvedKey, pageReady,
                              tools.map(\.name) == ["computer_v2_open", "computer_v2_snapshot"],
                              tools.allSatisfy({ $0.status == .succeeded }),
                              request.taskID == taskID, request.kind == .computerUse,
                              request.title == "Allow computer input?", request.summary == "Press command+l",
                              let arguments = details?["model_arguments"] as? [String: Any],
                              Set(arguments.keys) == ["key", "modifiers"],
                              arguments["key"] as? String == "l",
                              arguments["modifiers"] as? [String] == ["command"],
                              let target = details?["resolved_target"] as? [String: Any],
                              (target["process_id"] as? NSNumber)?.int32Value == expectedPID,
                              target["bundle_id"] as? String == bundleID {
                        focusAudit.record("native_input_approval_pending")
                        try await verifyFocusedChromePage(processID: expectedPID, pageURL: pageURL, focusAudit: focusAudit)
                        let observation = try XCTUnwrap(FocusedWindowReader().focusedWindowObservation())
                        guard observation.info.processIdentifier == expectedPID,
                              try observation.identity.isSameFocusedUIElement(),
                              !nativeAddressBarIsFocused(processID: expectedPID, pageURL: pageURL) else {
                            throw GateError(message: "The baseline must be the fixture page, not an already-focused address bar.")
                        }
                        retainedWindow = observation.identity
                        try await focusOwnedFixtureWindow(focusWindow, identifier: focusWindowID,
                                                          previousChromeWindow: observation.identity)
                        focusAudit.record("native_owned_host_focus_proven")
                        approvedKey = true
                        allowed = true
                    }
                    _ = await state.resolveApproval(request, approved: allowed)
                    focusAudit.record(approvedKey ? "native_input_approval_resolved" : "native_open_approval_resolved")
                    if !allowed { throw GateError(message: "An unexpected native fixture approval was denied.") }
                }
                if let completed = state.tasks.first(where: { $0.id == taskID }), completed.status == .completed {
                    focusAudit.record("native_turn_completed")
                    let tools = completed.entries.compactMap(\.toolEvent)
                    // Input dispatch is not a synchronous browser state oracle.
                    // Read-only settling never repairs focus or repeats Cmd+L.
                    for _ in 0..<40 where !nativeAddressBarIsFocused(processID: expectedPID, pageURL: pageURL) {
                        guard let retainedWindow, try retainedWindow.isStillFocused() else {
                            throw GateError(message: "The fixture window changed while verifying native input.")
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    guard approvedOpen, approvedKey,
                          tools.map(\.name) == ["computer_v2_open", "computer_v2_snapshot", "computer_v2_keypress"],
                          tools.allSatisfy({ $0.status == .succeeded }),
                          let retainedWindow, try retainedWindow.isStillFocused(),
                          try !retainedWindow.isSameFocusedUIElement(),
                          nativeAddressBarIsFocused(processID: expectedPID, pageURL: pageURL) else {
                        throw GateError(message: "The exact native window and address-bar postcondition were not verified.")
                    }
                    let trace = try await waitForTrace(at: traceURL, expectedToolCount: 3)
                    try verifyNativeFocusLifecycle(trace)
                    XCTAssertEqual(runningChromePIDs(), beforePIDs)
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    print("HEYDASH_NATIVE_FOCUS_VERIFIED deterministic_transport=true production_native_executor=true real_model=false focus_loss_proven=true exact_window_restored=true address_bar_focused=true calls=3 elapsed_ms=\(elapsed) fixture_root=\(root.path)")
                    // Close only the still-focused nonce fixture tab. Never
                    // reactivate or close another tab during test cleanup.
                    guard try retainedWindow.isStillFocused(),
                          nativeAddressBarIsFocused(processID: expectedPID, pageURL: pageURL) else {
                        throw GateError(message: "The nonce tab changed before bounded cleanup.")
                    }
                    try ComputerInputController().pressKeyChord(KeyboardChord(keyCode: 13, modifiers: [.command]))
                    return
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw GateError(message: "The bounded native-focus regression timed out.")
        } catch {
            focusAudit.record("native_gate_failed", error: error)
            for request in state.pendingApprovals { _ = await state.resolveApproval(request, approved: false) }
            _ = await state.interrupt(taskID: taskID)
            // A failed fixture may leave its public tab open; never guess which
            // user tab to close or restore focus merely to clean it up.
            throw error
        }
    }

    /// Test setup only: take focus with this exact owned window while the real
    /// input approval is pending. Never repairs Chrome focus or simulates input.
    private func focusOwnedFixtureWindow(
        _ window: NSWindow, identifier: String, previousChromeWindow: FocusedWindowIdentity
    ) async throws {
        let hostPID = ProcessInfo.processInfo.processIdentifier
        func hostIsFocused() throws -> Bool {
            guard NSRunningApplication.current.isActive, window.isKeyWindow,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID else { return false }
            return try !previousChromeWindow.isStillFocused()
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        for _ in 0..<40 {
            if try hostIsFocused() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        // AppKit activation can be denied even for an owned visible window.
        // Resolve only the unique test-created identifier in this host's AX
        // windows; retain its handle before requesting bounded AX activation.
        guard AXIsProcessTrusted(), window.isVisible, window.windowNumber > 0 else {
            throw GateError(message: "The test host could not prepare its owned focus window.")
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        let host = AXUIElementCreateApplication(hostPID)
        guard let windows = attribute(host, kAXWindowsAttribute) as? [AXUIElement] else {
            throw GateError(message: "The test host's owned AX window list is unavailable.")
        }
        let matching = windows.filter { attribute($0, kAXIdentifierAttribute) as? String == identifier }
        guard matching.count == 1, let owned = matching.first else {
            throw GateError(message: "The exact owned test window could not be identified.")
        }
        func verifyOwnedTarget() throws {
            var owner: pid_t = 0
            guard AXIsProcessTrusted(), window.isVisible,
                  AXUIElementGetPid(owned, &owner) == .success, owner == hostPID,
                  attribute(owned, kAXRoleAttribute) as? String == "AXWindow",
                  attribute(owned, kAXIdentifierAttribute) as? String == identifier else {
                throw GateError(message: "The retained test focus window changed or permission was revoked.")
            }
        }
        try verifyOwnedTarget()
        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(owned, &rawActions) == .success,
              let actions = rawActions as? [String], actions.contains(kAXRaiseAction as String),
              AXUIElementPerformAction(owned, kAXRaiseAction as CFString) == .success else {
            throw GateError(message: "The owned test window could not be raised.")
        }
        try verifyOwnedTarget()
        guard AXUIElementSetAttributeValue(host, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success else {
            throw GateError(message: "The owned test host could not request foreground activation.")
        }
        for _ in 0..<80 {
            try verifyOwnedTarget()
            if try hostIsFocused(), let focused = attribute(host, kAXFocusedWindowAttribute),
               CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(owned, focused) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GateError(message: "The test host did not prove exact owned-window focus loss before approval.")
    }

    /// Test-only structural AX audit. Reads no labels, titles, URLs, text values,
    /// screenshots, or web descendants. The only value inspected is the selected
    /// boolean for candidate tabs. Keep the production inventory limits intact.
    private func logNativeTabInventoryStructure(processID: Int32, phase: String) {
        let knownRoles: Set<String> = [
            "AXApplication", "AXWindow", "AXGroup", "AXToolbar", "AXTabGroup", "AXTab",
            "AXRadioButton", "AXButton", "AXRow", "AXOutline", "AXScrollArea", "AXSplitGroup",
            "AXTextField", "AXWebArea", "AXDocument", "AXCheckBox", "AXMenuButton", "AXPopUpButton",
            "AXStaticText", "AXImage", "AXList", "AXCell", "AXLayoutArea", "AXGrowArea", "AXContentList",
        ]
        var payload: [String: Any] = ["phase": phase, "focused_exact_chrome": false]
        defer {
            if let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let text = String(data: bytes, encoding: .utf8) {
                print("HEYDASH_NATIVE_TAB_STRUCTURE \(text)")
            }
        }
        guard PermissionInspector().current().accessibility == .granted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              NSRunningApplication(processIdentifier: processID)?.bundleIdentifier == bundleID,
              let observation = try? FocusedWindowReader().focusedWindowObservation(),
              observation.info.processIdentifier == processID else { return }
        var attributeErrors: [String: Int] = [:]
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if result != .success && result != .noValue && result != .attributeUnsupported {
                attributeErrors["\(name):\(result.rawValue)", default: 0] += 1
            }
            return result == .success ? value : nil
        }
        guard let raw = attribute(AXUIElementCreateApplication(processID), kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        let window = unsafeBitCast(raw, to: AXUIElement.self)
        var queue: [(AXUIElement, [String])] = [(window, [])]
        var visited: [AXUIElement] = []
        var cursor = 0
        var histogram: [String: Int] = [:]
        var groupCount = 0
        var radioTabsInGroup = 0
        var selectedTabsInGroup = 0
        var ownershipFailures = 0
        var missingRoles = 0
        var duplicates = 0
        var maximumDepth = 0
        var limitReason = "none"
        var candidates: [[String: Any]] = []
        while cursor < queue.count {
            if cursor >= 512 { limitReason = "cursor_512"; break }
            let (element, ancestors) = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, element) }) { duplicates += 1; continue }
            visited.append(element)
            var owner: pid_t = 0
            if AXUIElementGetPid(element, &owner) != .success || owner != processID {
                ownershipFailures += 1
                continue
            }
            guard let rawRole = attribute(element, kAXRoleAttribute) as? String else {
                missingRoles += 1
                continue
            }
            let role = knownRoles.contains(rawRole) ? rawRole : "other"
            histogram[role, default: 0] += 1
            maximumDepth = max(maximumDepth, ancestors.count)
            if role == "AXWebArea" || role == "AXDocument" { continue }
            if role == "AXTabGroup" { groupCount += 1 }
            let inGroup = ancestors.contains("AXTabGroup")
            if ["AXTabGroup", "AXRadioButton", "AXTab", "AXRow"].contains(role) {
                let selected = role == "AXRadioButton" || role == "AXTab"
                    ? (attribute(element, kAXValueAttribute) as? NSNumber) == 1 : false
                if role == "AXRadioButton", inGroup {
                    radioTabsInGroup += 1
                    if selected { selectedTabsInGroup += 1 }
                }
                if candidates.count < 64 {
                    candidates.append(["role": role, "ancestors": ancestors,
                                       "has_tab_group_ancestor": inGroup, "selected": selected])
                }
            }
            guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            if !children.isEmpty && ancestors.count >= 20 { limitReason = "depth_20"; break }
            if queue.count + children.count > 512 { limitReason = "queue_512"; break }
            queue += children.map { ($0, ancestors + [role]) }
        }
        payload["focused_exact_chrome"] = (try? observation.identity.isStillFocused()) == true
        payload["role_counts"] = histogram
        payload["tab_group_count"] = groupCount
        payload["radio_tabs_in_groups"] = radioTabsInGroup
        payload["selected_tabs_in_groups"] = selectedTabsInGroup
        payload["visited_count"] = visited.count
        payload["queue_count"] = queue.count
        payload["maximum_depth"] = maximumDepth
        payload["ownership_failures"] = ownershipFailures
        payload["missing_roles"] = missingRoles
        payload["duplicate_nodes"] = duplicates
        payload["limit_reason"] = limitReason
        payload["attribute_errors"] = attributeErrors
        payload["candidate_structure"] = candidates
        payload["candidate_list_bounded_at"] = 64
    }

    private func nativeAddressBarIsFocused(processID: Int32, pageURL: String) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return false }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        let app = AXUIElementCreateApplication(processID)
        guard let raw = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let control = unsafeBitCast(raw, to: AXUIElement.self)
        guard attribute(control, kAXRoleAttribute) as? String == "AXTextField",
              attribute(control, kAXDescriptionAttribute) as? String == "Address and search bar",
              chromeAddress(attribute(control, kAXValueAttribute) as? String, matches: pageURL) else { return false }
        var current = control
        var toolbar = false
        for _ in 0..<24 {
            var owner: pid_t = 0
            guard AXUIElementGetPid(current, &owner) == .success, owner == processID else { return false }
            let role = attribute(current, kAXRoleAttribute) as? String
            if role == "AXWebArea" || role == "AXDocument" { return false }
            if role == "AXToolbar" { toolbar = true }
            if role == "AXWindow" { return toolbar }
            guard let parent = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }

    private func verifyNativeFocusLifecycle(_ trace: AppServerWireTrace) throws {
        XCTAssertTrue(trace.parseFailures.isEmpty)
        let calls = trace.messages.filter { $0.direction == .serverToClient && $0.method == "item/tool/call" }
        guard calls.count == 3 else { throw GateError(message: "Expected exactly three bounded native fixture calls.") }
        for (index, call) in calls.enumerated() {
            let params = try XCTUnwrap(call.object["params"] as? [String: Any])
            XCTAssertEqual(params["tool"] as? String, ["computer_v2_open", "computer_v2_snapshot", "computer_v2_keypress"][index])
            let callID = try XCTUnwrap(params["callId"] as? String)
            let reply = try XCTUnwrap(trace.messages.first {
                $0.direction == .clientToServer && $0.method == nil && $0.identifier == call.identifier && $0.sequence > call.sequence
            })
            let result = try XCTUnwrap(reply.object["result"] as? [String: Any])
            XCTAssertEqual(result["success"] as? Bool, true)
            if index == 2 {
                let content = try XCTUnwrap(result["contentItems"] as? [[String: Any]])
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                XCTAssertTrue(text.contains("POST_ACTION_OBSERVATION status=available action_dispatched=true"),
                              "The production input path did not return a usable fresh observation.")
                XCTAssertTrue(text.contains("AXSNAPSHOT id="))
                XCTAssertTrue(text.contains("focused=1"), "The fresh observation must expose the focused omnibox.")
            }
            let completion = try XCTUnwrap(trace.messages.first {
                guard $0.direction == .serverToClient, $0.method == "item/completed",
                      let item = ($0.object["params"] as? [String: Any])?["item"] as? [String: Any] else { return false }
                return item["id"] as? String == callID && item["success"] as? Bool == true && $0.sequence > reply.sequence
            })
            XCTAssertLessThan(reply.sequence, completion.sequence)
        }
    }

    /// Model-free primitive in the exact same signed HeyDash test host as the
    /// model gate. Never inspects the original tab: only the newly opened public
    /// nonce fixture is read, and only sanitized phase/PID proof is printed.
    func testExistingChromeNativeOpenPrimitive() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HEYDASH_LIVE_EXISTING_CHROME_PRIMITIVE"] == "1",
            "Set HEYDASH_LIVE_EXISTING_CHROME_PRIMITIVE=1 to opt in."
        )
        guard PermissionInspector().current().accessibility == .granted else {
            throw GateError(message: "The live test host does not have Accessibility access.")
        }
        let chromePIDsBefore = runningChromePIDs()
        guard let rawPID = ProcessInfo.processInfo.environment["HEYDASH_EXPECTED_CHROME_PID"],
              let expectedPID = Int32(rawPID), expectedPID > 0,
              chromePIDsBefore.contains(expectedPID) else {
            throw GateError(message: "HEYDASH_EXPECTED_CHROME_PID must identify an already-running Google Chrome process.")
        }
        defer {
            XCTAssertEqual(runningChromePIDs(), chromePIDsBefore,
                           "The native primitive must neither replace nor launch another Chrome process.")
        }
        let controller = ExistingChromeController(diagnostics: { diagnostic in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(diagnostic),
               let payload = String(data: data, encoding: .utf8) {
                print("HEYDASH_EXISTING_CHROME_DIAGNOSTIC \(payload)")
            }
        })
        let startedAt = DispatchTime.now().uptimeNanoseconds
        print("HEYDASH_EXISTING_CHROME_PRIMITIVE phase=activate expected_pid=\(expectedPID)")
        let activated = try await controller.open(url: nil)
        guard activated.processIdentifier == expectedPID, activated.bundleIdentifier == bundleID else {
            throw GateError(message: "Native activation did not reuse the exact expected Chrome PID.")
        }
        XCTAssertEqual(runningChromePIDs(), chromePIDsBefore)
        print("HEYDASH_EXISTING_CHROME_PRIMITIVE phase=activated actual_pid=\(activated.processIdentifier)")

        let pageURL = "https://example.com/?heydash_native_read_id=\(UUID().uuidString)"
        let url = try XCTUnwrap(URL(string: pageURL))
        print("HEYDASH_EXISTING_CHROME_PRIMITIVE phase=open_public_nonce expected_pid=\(expectedPID)")
        let opened = try await controller.open(url: url)
        guard opened.processIdentifier == expectedPID, opened.bundleIdentifier == bundleID else {
            throw GateError(message: "Native URL open did not reuse the exact expected Chrome PID.")
        }
        XCTAssertEqual(runningChromePIDs(), chromePIDsBefore)
        try await verifyFocusedChromePage(processID: expectedPID, pageURL: pageURL)
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        print("HEYDASH_EXISTING_CHROME_PRIMITIVE phase=verified actual_pid=\(expectedPID) heading_verified=true nonce_address_verified=true chrome_pid_set_unchanged=\(runningChromePIDs() == chromePIDsBefore) elapsed_ms=\(elapsedMilliseconds)")
    }

    func testBoundChromeReadOnlyV2WithSelectedModel() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_CHROME_V2_READ_TEST"] == "1",
            "Set LOCALCODEX_LIVE_CHROME_V2_READ_TEST=1 to opt in to the Chrome V2 gate."
        )
        let modelID = try XCTUnwrap(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_ID"],
            "Select one installed model explicitly with LOCALCODEX_LIVE_MODEL_ID."
        )
        guard LocalModelCatalog.option(for: modelID) != nil else {
            throw GateError(message: "The selected model is not in LocalModelCatalog.")
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw GateError(message: "Google Chrome is not installed.")
        }
        guard PermissionInspector().current().accessibility == .granted else {
            throw GateError(message: "The live test host does not have Accessibility access.")
        }
        let chromePIDsBeforeTurn = runningChromePIDs()
        let expectedChromePID: Int32?
        if let rawPID = ProcessInfo.processInfo.environment["HEYDASH_EXPECTED_CHROME_PID"] {
            guard let processID = Int32(rawPID), processID > 0,
                  chromePIDsBeforeTurn.contains(processID) else {
                throw GateError(message: "HEYDASH_EXPECTED_CHROME_PID must identify an already-running Google Chrome process.")
            }
            expectedChromePID = processID
        } else {
            expectedChromePID = nil
        }
        let pageURL = "https://example.com/?localcodex_read_id=\(UUID().uuidString)"

        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexChromeV2-\(UUID().uuidString)", isDirectory: true)
            .path
        let traceURL = URL(fileURLWithPath: configuration.codexHomePath, isDirectory: true)
            .appendingPathComponent("app-server-wire.jsonl")
        configuration.protocolTracePath = traceURL.path

        let focusAudit = try expectedChromePID.map {
            try FocusAudit(targetPID: $0, directory: URL(fileURLWithPath: configuration.codexHomePath, isDirectory: true))
        }
        defer { focusAudit?.stop() }

        let state = AppState(tasks: [], runtime: CodexAppServerRuntime(configuration: configuration), preferences: isolatedTestPreferences())
        let eventTask = Task { await state.startRuntime() }
        addTeardownBlock { @MainActor in
            // Runs on success, thrown validation failures, and model timeout.
            // Shut down only this fixture's runtime; the user's Chrome must survive.
            defer { eventTask.cancel() }
            do {
                let report = try await self.shutdownRuntimeBounded(state)
                XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            } catch {
                XCTFail("Chrome V2 runtime cleanup failed: \(error.localizedDescription)")
            }
            if let expectedChromePID {
                XCTAssertTrue(self.runningChromePIDs().contains(expectedChromePID),
                              "Runtime cleanup terminated the user's preexisting Chrome.")
                XCTAssertEqual(self.runningChromePIDs(), chromePIDsBeforeTurn,
                               "Runtime cleanup changed the set of existing Chrome processes.")
            }
        }
        try await waitForConnection(state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        XCTAssertTrue(state.setTaskModel(modelID, taskID: taskID))

        let audit = ApprovalAudit()
        let approvalTask = approveOnlyExpectedOpen(
            state: state, taskID: taskID, pageURL: pageURL, audit: audit
        )
        defer { approvalTask.cancel() }

        let token = "LOCALCODEX_CHROME_V2_READ_OK_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        focusAudit?.record("model_before_submit")
        let submitted = await state.submit(
            prompt: """
            Call computer_v2_open exactly once with {"bundle_id":"\(bundleID)","url":"\(pageURL)"}. Then call computer_v2_snapshot with exactly {"query":"\(snapshotQuery)"}. If the snapshot does not yet show an AXHeading for \(snapshotQuery), retry the same read-only snapshot until it does, using at most \(maxSnapshotCalls) snapshot calls total. Stop retrying when the heading appears. Confirm the final AXSNAPSHOT header identifies the bound Chrome bundle and process and its page heading says \(snapshotQuery). Only after that observation, reply with exactly \(token). If the heading never appears, report failure instead of the token. Use no other tools; do not click, type, or navigate elsewhere.
            """,
            toTaskID: taskID
        )
        guard submitted else { throw GateError(message: "The Chrome V2 prompt was not submitted.") }

        let completed = try await waitForCompletion(state, taskID: taskID, audit: audit, focusAudit: focusAudit)
        focusAudit?.record("model_turn_completed")
        XCTAssertEqual(completed.model, modelID)
        XCTAssertTrue(audit.approvedOpen)
        XCTAssertTrue(audit.unexpected.isEmpty, audit.unexpected.joined(separator: "\n"))
        let toolNames = completed.entries.compactMap(\.toolEvent).map(\.name)
        guard (2...(maxSnapshotCalls + 1)).contains(toolNames.count),
              toolNames == ["computer_v2_open"] + Array(
                repeating: "computer_v2_snapshot", count: toolNames.count - 1
              ) else {
            throw GateError(message: "Expected one Chrome open and one to \(maxSnapshotCalls) read-only snapshots; got \(toolNames).")
        }
        let calls = try completed.entries.compactMap {
            entry -> (name: String, arguments: [String: Any], output: String)? in
            guard let tool = entry.toolEvent else { return nil }
            guard let item = jsonObject(tool.input),
                  item["tool"] as? String == tool.name,
                  let arguments = jsonObject(item["arguments"]),
                  let content = item["contentItems"] as? [[String: Any]],
                  tool.status == .succeeded else {
                throw GateError(message: "Malformed or unsuccessful V2 transcript call: \(tool.name)")
            }
            let output = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (tool.name, arguments, output)
        }
        XCTAssertEqual(calls.map(\.name), toolNames)
        XCTAssertEqual(Set(calls[0].arguments.keys), ["bundle_id", "url"])
        XCTAssertEqual(calls[0].arguments["bundle_id"] as? String, bundleID)
        XCTAssertEqual(calls[0].arguments["url"] as? String, pageURL)
        let processID = try XCTUnwrap(processIdentifier(in: calls[0].output))
        XCTAssertEqual(NSRunningApplication(processIdentifier: processID)?.bundleIdentifier, bundleID)
        XCTAssertTrue(calls[0].output.contains("BROWSER_SESSION profile=existing"))
        XCTAssertFalse(calls[0].output.contains("BROWSER_TAB"))
        if let expectedChromePID {
            XCTAssertEqual(processID, expectedChromePID,
                           "The default open did not reuse the exact preexisting Chrome process.")
            XCTAssertEqual(runningChromePIDs(), chromePIDsBeforeTurn,
                           "The default open unexpectedly created or replaced a Chrome process.")
        }
        for snapshot in calls.dropFirst() {
            XCTAssertEqual(Set(snapshot.arguments.keys), ["query"])
            XCTAssertEqual(snapshot.arguments["query"] as? String, snapshotQuery)
            XCTAssertTrue(snapshot.output.contains("AXSNAPSHOT id="))
            XCTAssertTrue(snapshot.output.contains("pid=\(processID) "))
            XCTAssertTrue(snapshot.output.contains("bundle=\"\(bundleID)\""))
        }
        XCTAssertTrue(
            modelSnapshotHasPageHeading(try XCTUnwrap(calls.last).output),
            "The model's final snapshot did not expose the Example Domain page heading."
        )
        try await verifyFocusedChromePage(processID: processID, pageURL: pageURL, focusAudit: focusAudit)
        focusAudit?.record("model_final_page_verified")
        XCTAssertEqual(
            completed.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            token
        )

        let trace = try await waitForTrace(at: traceURL, expectedToolCount: calls.count)
        try assertWireLifecycle(
            trace, modelID: modelID, processID: processID, pageURL: pageURL,
            expectedCalls: calls
        )
        let shutdownReport = try await shutdownRuntimeBounded(state)
        XCTAssertTrue(shutdownReport.succeeded, shutdownReport.issues.joined(separator: "; "))
        if let expectedChromePID {
            XCTAssertTrue(runningChromePIDs().contains(expectedChromePID),
                          "The existing Chrome session must remain after runtime shutdown.")
            XCTAssertEqual(runningChromePIDs(), chromePIDsBeforeTurn)
        }
    }

    private func runningChromePIDs() -> Set<Int32> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier))
    }

    private func shutdownRuntimeBounded(_ state: AppState) async throws -> RuntimeShutdownReport {
        let audit = ShutdownAudit()
        let shutdown = Task { @MainActor in
            audit.report = await state.shutdownRuntime()
        }
        defer { shutdown.cancel() }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let report = audit.report { return report }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw GateError(message: "Runtime shutdown did not finish within 15 seconds.")
    }

    private func approveOnlyExpectedOpen(
        state: AppState,
        taskID: AgentTask.ID,
        pageURL: String,
        audit: ApprovalAudit
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for request in state.pendingApprovals
                where !audit.handledIDs.contains(request.id) {
                    audit.handledIDs.insert(request.id)
                    let details = jsonObject(request.details)
                    let noPriorTools = state.tasks.first(where: { $0.id == taskID })?
                        .entries.contains(where: { $0.toolEvent?.name.hasPrefix("computer_v2_") == true }) == false
                    let approved = !audit.approvedOpen && noPriorTools
                        && request.taskID == taskID
                        && request.kind == .computerUse
                        && request.title == "Allow an application action?"
                        && request.summary == "Open \(bundleID) at \(pageURL)"
                        && details?["bundle_id"] as? String == bundleID
                        && details?["url"] as? String == pageURL
                        && Set(details?.keys.map { $0 } ?? []) == ["bundle_id", "url"]
                    if approved {
                        audit.approvedOpen = true
                    } else {
                        audit.unexpected.append("Declined unexpected approval: \(request.summary)")
                    }
                    await state.resolveApproval(request, approved: approved)
                    if !approved { return }
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    private func waitForConnection(_ state: AppState) async throws {
        for _ in 0..<80 {
            switch state.connectionState {
            case .connected: return
            case .failed(let message): throw GateError(message: "Runtime connection failed: \(message)")
            case .connecting, .disconnected: break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "Timed out waiting for the App Server connection.")
    }

    private func waitForCompletion(
        _ state: AppState,
        taskID: AgentTask.ID,
        audit: ApprovalAudit,
        focusAudit: FocusAudit? = nil
    ) async throws -> AgentTask {
        let deadline = Date().addingTimeInterval(180)
        var loggedToolStates = Set<String>()
        while Date() < deadline {
            if let unexpected = audit.unexpected.first { throw GateError(message: unexpected) }
            if case .failed(let message) = state.connectionState {
                throw GateError(message: "App Server failed: \(message)")
            }
            guard let task = state.tasks.first(where: { $0.id == taskID }) else {
                throw GateError(message: "The Chrome V2 task disappeared.")
            }
            for (index, tool) in task.entries.compactMap(\.toolEvent).enumerated() {
                let phase = "model_tool_\(index + 1)_\(tool.status)"
                if loggedToolStates.insert(phase).inserted { focusAudit?.record(phase) }
            }
            if task.status == .completed { return task }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "Timed out waiting for the Chrome V2 turn.")
    }

    private func verifyFocusedChromePage(
        processID: Int32, pageURL: String, focusAudit: FocusAudit? = nil
    ) async throws {
        let limits = try AccessibilityTreeLimits(
            maxDepth: 16, maxElements: 1_000, maxChildrenPerElement: 200,
            maxActionsPerElement: 12, maxTextLength: 1_024
        )
        for attempt in 0..<20 {
            guard let running = NSRunningApplication(processIdentifier: processID),
                  running.bundleIdentifier == bundleID, !running.isTerminated else {
                throw GateError(message: "The bound Chrome process is no longer running.")
            }
            let session = AccessibilitySession(
                processIdentifier: processID,
                bundleIdentifier: bundleID,
                applicationName: running.localizedName
            )
            focusAudit?.record("verify_before_snapshot")
            let snapshot: AccessibilityTreeSnapshot
            do { snapshot = try session.snapshot(limits: limits) }
            catch {
                focusAudit?.record("verify_snapshot_failed", error: error)
                throw error
            }
            focusAudit?.record("verify_after_snapshot", session: session, snapshot: snapshot)
            guard try session.focusState(in: snapshot) == .focused else {
                focusAudit?.record("verify_focus_failed", session: session, snapshot: snapshot)
                throw GateError(message: "The bound Chrome window is no longer focused.")
            }

            let addressFields = snapshot.elements.filter {
                $0.role == "AXTextField" && chromeAddress($0.value, matches: pageURL)
            }
            let pageHeading = snapshot.elements.contains { element in
                let isHeading = element.role == "AXHeading"
                    || (element.role == "AXStaticText"
                        && hasAncestor(role: "AXHeading", of: element, in: snapshot))
                return isHeading
                    && [element.title, element.elementDescription, element.value]
                        .contains(where: { $0 == snapshotQuery })
                    && hasAncestor(role: "AXWebArea", of: element, in: snapshot)
            }
            if addressFields.count == 1 && pageHeading { return }
            if attempt < 19 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw GateError(
            message: "The focused Chrome AX window did not show the unique gate URL "
                + "in one address field and the Example Domain page heading."
        )
    }

    private func chromeAddress(_ value: String?, matches pageURL: String) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        // Chrome may omit the HTTPS scheme from the displayed address value.
        return value == pageURL || "https://\(value)" == pageURL
    }

    private func modelSnapshotHasPageHeading(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.contains("role=\"AXHeading\"")
                && line.contains("\"\(snapshotQuery)\"")
        }
    }

    private func hasAncestor(
        role: String,
        of element: AccessibilityTreeElement,
        in snapshot: AccessibilityTreeSnapshot
    ) -> Bool {
        var index = element.parentIndex
        while let currentIndex = index,
              let ancestor = snapshot.element(at: currentIndex) {
            if ancestor.role == role { return true }
            index = ancestor.parentIndex
        }
        return false
    }

    private func waitForTrace(
        at url: URL,
        expectedToolCount: Int
    ) async throws -> AppServerWireTrace {
        for _ in 0..<80 {
            if let trace = try? AppServerWireTrace.load(url),
               trace.messages.filter({ message in
                   guard message.direction == .serverToClient,
                         message.method == "item/completed",
                         let item = (message.object["params"] as? [String: Any])?["item"]
                            as? [String: Any] else { return false }
                   return item["type"] as? String == "dynamicToolCall"
               }).count >= expectedToolCount {
                return trace
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "The App Server wire trace did not complete.")
    }

    private func assertWireLifecycle(
        _ trace: AppServerWireTrace,
        modelID: String,
        processID: Int32,
        pageURL: String,
        expectedCalls: [(name: String, arguments: [String: Any], output: String)]
    ) throws {
        XCTAssertTrue(trace.parseFailures.isEmpty, trace.parseFailures.joined(separator: "\n"))
        XCTAssertEqual(trace.messages.map(\.sequence), Array(1...trace.messages.count))
        XCTAssertTrue(trace.messages.allSatisfy { $0.wireData.last == 0x0A })
        for method in ["thread/start", "turn/start"] {
            let requests = trace.messages.filter {
                $0.direction == .clientToServer && $0.method == method
            }
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(
                (requests.first?.object["params"] as? [String: Any])?["model"] as? String,
                modelID
            )
        }
        let start = try XCTUnwrap(trace.messages.first {
            $0.direction == .clientToServer && $0.method == "thread/start"
        })
        let startParams = try XCTUnwrap(start.object["params"] as? [String: Any])
        let registered = try XCTUnwrap(startParams["dynamicTools"] as? [[String: Any]])
        XCTAssertEqual(
            Set(registered.compactMap { $0["name"] as? String }),
            Set(ComputerV2ToolContract.Tool.allCases.map(\.rawValue))
        )
        let calls = trace.messages.filter {
            $0.direction == .serverToClient && $0.method == "item/tool/call"
        }
        XCTAssertEqual(calls.count, expectedCalls.count)
        guard calls.count == expectedCalls.count else { return }
        XCTAssertEqual(
            calls.compactMap { ($0.object["params"] as? [String: Any])?["tool"] as? String },
            expectedCalls.map(\.name)
        )
        for (index, call) in calls.enumerated() {
            let params = try XCTUnwrap(call.object["params"] as? [String: Any])
            let callID = try XCTUnwrap(params["callId"] as? String)
            let requestID = try XCTUnwrap(call.identifier)
            let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
            if index == 0 {
                XCTAssertEqual(Set(arguments.keys), ["bundle_id", "url"])
                XCTAssertEqual(arguments["bundle_id"] as? String, bundleID)
                XCTAssertEqual(arguments["url"] as? String, pageURL)
            } else {
                XCTAssertEqual(Set(arguments.keys), ["query"])
                XCTAssertEqual(arguments["query"] as? String, snapshotQuery)
            }
            let started = try XCTUnwrap(trace.messages.first { message in
                guard message.direction == .serverToClient,
                      message.method == "item/started",
                      let item = (message.object["params"] as? [String: Any])?["item"] as? [String: Any]
                else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "inProgress"
            })
            let response = try XCTUnwrap(trace.messages.first {
                $0.direction == .clientToServer && $0.method == nil
                    && $0.identifier == requestID && $0.sequence > call.sequence
            })
            let result = try XCTUnwrap(response.object["result"] as? [String: Any])
            XCTAssertEqual(result["success"] as? Bool, true)
            let content = try XCTUnwrap(result["contentItems"] as? [[String: Any]])
            let output = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertEqual(output, expectedCalls[index].output)
            if index == 0 {
                XCTAssertEqual(processIdentifier(in: output), processID)
                XCTAssertTrue(output.contains(bundleID))
            } else {
                XCTAssertTrue(output.contains("AXSNAPSHOT id="))
                XCTAssertTrue(output.contains("pid=\(processID) "))
                XCTAssertTrue(output.contains("bundle=\"\(bundleID)\""))
                if index == calls.count - 1 {
                    XCTAssertTrue(modelSnapshotHasPageHeading(output))
                }
            }
            let completed = try XCTUnwrap(trace.messages.first { message in
                guard message.direction == .serverToClient,
                      message.method == "item/completed",
                      let item = (message.object["params"] as? [String: Any])?["item"] as? [String: Any]
                else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "completed"
                    && item["success"] as? Bool == true
            })
            // App Server can emit the call request before item/started. Both
            // must precede our reply; completion must follow it.
            XCTAssertLessThan(started.sequence, response.sequence)
            XCTAssertLessThan(call.sequence, response.sequence)
            XCTAssertLessThan(response.sequence, completed.sequence)
        }
    }

    private func jsonObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String,
              let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func processIdentifier(in text: String) -> Int32? {
        guard let expression = try? NSRegularExpression(pattern: #""processIdentifier"\s*:\s*(\d+)"#),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int32(text[range])
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import AutomationCore
@testable import Mactopus

/// Explicitly authorized, ordinary-profile CDP gate. An external owner must
/// create a fresh loopback fixture tab first. This test never opens, activates,
/// navigates, replaces or closes tabs, and never changes Chrome permissions.
/// Desktop evidence is sampled at boundaries and while awaiting CDP replies,
/// not a continuous event trace or
/// a concurrent-human-input qualification. This is not an LLM/runtime gate.
@MainActor
final class BorrowedChromeOrdinaryLiveTests: XCTestCase {
    /// Separate read-only attribution gate: passing this is never reported as
    /// successful computer input, a connection, or a five-cycle fixture run.
    func testOrdinaryChromeAttributionBeforeConnection() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless((env["HEYDASH_ORDINARY_BORROWED_GATE"] ?? env["TEST_RUNNER_HEYDASH_ORDINARY_BORROWED_GATE"]) == "1",
                          "Explicit ordinary-Chrome access required.")
        guard let path = env["HEYDASH_ORDINARY_PROFILE_DIRECTORY"] ?? env["TEST_RUNNER_HEYDASH_ORDINARY_PROFILE_DIRECTORY"],
              path.hasPrefix("/") else { throw Failure("An explicitly approved profile directory is required.") }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated && $0.activationPolicy == .regular
        }
        guard apps.count == 1, let app = apps.first, let executable = app.executableURL else {
            throw Failure("Exactly one running ordinary Chrome main application is required.")
        }
        let consent = ChromeDebuggingConsent(approvedByUser: true)
        defer { consent.revoke() }
        do {
            let authority = try ChromeDebuggingConnectionAuthority.bind(
                processIdentifier: app.processIdentifier, expectedExecutableURL: executable,
                explicitlyApprovedUserDataDirectory: URL(fileURLWithPath: path, isDirectory: true), consent: consent
            )
            try authority.validate()
            print("HEYDASH_ORDINARY_PREFLIGHT_OK connection_attempts=0 tool_actions=0")
        } catch let error as ChromeDebuggingEndpointError {
            print("HEYDASH_ORDINARY_PREFLIGHT_ERROR endpoint=\(error) connection_attempts=0 tool_actions=0")
            throw error
        } catch let error as ChromeDebuggingProcessBindingError {
            print("HEYDASH_ORDINARY_PREFLIGHT_ERROR process=\(error) connection_attempts=0 tool_actions=0")
            throw error
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct DesktopState: Equatable {
        let foregroundPID: Int32
        let pointer: CGPoint
        let clipboardChangeCount: Int

        @MainActor static func read() throws -> Self {
            guard let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let pointer = CGEvent(source: nil)?.location,
                  pointer.x.isFinite, pointer.y.isFinite else {
                throw Failure("Desktop boundary metadata is unavailable.")
            }
            return Self(foregroundPID: foregroundPID, pointer: pointer,
                        clipboardChangeCount: NSPasteboard.general.changeCount)
        }
    }

    @MainActor
    private final class DesktopSampler {
        private let baseline: DesktopState
        private var task: Task<Void, Never>?
        private var previous: UInt64?
        private(set) var samples = 0
        private(set) var changedSamples = 0
        private(set) var readFailures = 0
        private(set) var maximumGapMS = 0.0

        init(baseline: DesktopState) { self.baseline = baseline }

        func start() {
            previous = DispatchTime.now().uptimeNanoseconds
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                    guard let self else { break }
                    let time = DispatchTime.now().uptimeNanoseconds
                    if let previous { maximumGapMS = max(maximumGapMS, Double(time - previous) / 1_000_000) }
                    previous = time
                    samples += 1
                    do { if try DesktopState.read() != baseline { changedSamples += 1 } }
                    catch { readFailures += 1 }
                }
            }
        }

        func stop() {
            guard task != nil else { return }
            if let previous {
                maximumGapMS = max(maximumGapMS, Double(DispatchTime.now().uptimeNanoseconds - previous) / 1_000_000)
            }
            task?.cancel()
            task = nil
        }
    }

    /// Retains identities only; the shared native reader skips web descendants
    /// and never fetches titles, labels, URLs, or text values from user tabs.
    private struct TabSelectionWitness {
        let window: AXUIElement
        let inventory: ExistingChromeTabInventory

        @MainActor static func read(processIdentifier: Int32) throws -> Self {
            let app = AXUIElementCreateApplication(processIdentifier)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw Failure("Chrome's background selected-window identity is unavailable.")
            }
            let window = unsafeBitCast(raw, to: AXUIElement.self)
            var owner: pid_t = 0
            guard AXUIElementGetPid(window, &owner) == .success, owner == processIdentifier else {
                throw Failure("Chrome's selected-window owner changed.")
            }
            return Self(window: window, inventory: try NativeChromeTabInventory.read(
                window: window, processIdentifier: processIdentifier
            ))
        }

        @MainActor func requireUnchanged(processIdentifier: Int32) throws {
            let current = try Self.read(processIdentifier: processIdentifier)
            guard CFEqual(window, current.window), inventory.isSame(as: current.inventory) else {
                throw Failure("Chrome's selected native window/tab inventory changed.")
            }
        }
    }

    func testFiveSerialOrdinaryChromeDOMCyclesPreserveDesktopAndTabs() async throws {
        let environment = ProcessInfo.processInfo.environment
        func setting(_ key: String) -> String? { environment[key] ?? environment["TEST_RUNNER_" + key] }
        try XCTSkipUnless(setting("HEYDASH_ORDINARY_BORROWED_GATE") == "1",
                          "Explicit existing-Chrome consent and a preexisting isolated fixture are required.")
        guard AXIsProcessTrusted() else { throw Failure("Existing Accessibility permission is required; none was requested.") }
        guard let fixtureString = setting("HEYDASH_ORDINARY_FIXTURE_URL"),
              let fixture = URL(string: fixtureString),
              let parts = URLComponents(url: fixture, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65_535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/heydash-fixture/"),
              UUID(uuidString: String(parts.path.dropFirst("/heydash-fixture/".count))) != nil,
              let profilePath = setting("HEYDASH_ORDINARY_PROFILE_DIRECTORY"), profilePath.hasPrefix("/") else {
            throw Failure("Supply the exact fresh UUID loopback fixture URL and explicitly approved absolute Chrome profile directory.")
        }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated && $0.activationPolicy == .regular
        }
        guard apps.count == 1, let app = apps.first,
              let executable = app.executableURL, let launch = app.launchDate else {
            throw Failure("Exactly one already-running ordinary Chrome main application is required.")
        }
        let pid = app.processIdentifier
        let consent = ChromeDebuggingConsent(approvedByUser: true)
        defer { consent.revoke() }
        var adapter: BorrowedChromeDevToolsTransport?
        var broker: BrowserTabSessionBroker?
        var attachedTarget: BrowserTarget?
        var sampler: DesktopSampler?
        var phase = "connection_authority"
        var samples = [[String: Any]]()
        var cycleMilliseconds = [Double]()
        var report: [String: Any] = [
            "gate": "ordinary_chrome_borrowed_cdp", "status": "failed", "model_used": false,
            "production_runtime_routing": false,
            "sampling": "operation boundaries and requested 10ms MainActor polling; not continuous OS-event evidence",
            "concurrent_human_input_tested": false, "global_input_calls": 0,
            "launch_activate_navigate_close_tab_calls": 0, "connection_attempts": 0,
            "completed_cycles": 0, "exact_unicode": false, "candidate_target_set_preserved": false,
            "selected_native_window_and_tab_preserved": false, "detached": false,
            "connection_closed": false, "start_unix_ms": Date().timeIntervalSince1970 * 1_000,
        ]
        defer {
            sampler?.stop()
            report["periodic_samples"] = sampler?.samples ?? 0
            report["periodic_changed_samples"] = sampler?.changedSamples ?? 0
            report["periodic_read_failures"] = sampler?.readFailures ?? 0
            report["periodic_maximum_gap_ms"] = sampler?.maximumGapMS ?? 0
            report["last_phase"] = phase
            report["boundary_samples"] = samples
            report["cycle_milliseconds"] = cycleMilliseconds
            report["end_unix_ms"] = Date().timeIntervalSince1970 * 1_000
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print("HEYDASH_ORDINARY_BORROWED=" + text)
                let attachment = XCTAttachment(string: text)
                attachment.name = "Ordinary Chrome borrowed transport redacted evidence"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        do {
            let authority = try ChromeDebuggingConnectionAuthority.bind(
                processIdentifier: pid, expectedExecutableURL: executable,
                explicitlyApprovedUserDataDirectory: URL(fileURLWithPath: profilePath, isDirectory: true),
                consent: consent
            )
            var configuration = BrowserCDPConnection.Configuration()
            // Only this opt-in gate admits time for Chrome's user-owned Allow
            // prompt. There is exactly one connection attempt and no retry.
            configuration.requestTimeout = .seconds(60)
            phase = "single_connection_handshake"
            report["connection_attempts"] = 1
            let transport = try await ChromeDebuggingConnection.connect(authority: authority, configuration: configuration)
            adapter = transport
            let sessionBroker = BrowserTabSessionBroker(
                transport: transport, browserGeneration: transport.generation, ownership: .borrowed
            )
            broker = sessionBroker

            phase = "wait_for_user_to_return_to_another_app"
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            while NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                try Task.checkCancellation()
                guard clock.now < deadline, !app.isTerminated, app.launchDate == launch else {
                    throw Failure("Chrome remained foreground or changed generation; no fixture action was attempted.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let baseline = try DesktopState.read()
            guard baseline.foregroundPID != pid else { throw Failure("Another app must remain foreground for this background gate.") }
            let periodic = DesktopSampler(baseline: baseline)
            sampler = periodic
            periodic.start()
            func sample(_ boundary: String) throws {
                try Task.checkCancellation()
                let current = try DesktopState.read()
                samples.append([
                    "phase": boundary, "monotonic_ns": DispatchTime.now().uptimeNanoseconds,
                    "frontmost_pid": current.foregroundPID, "pointer_x": current.pointer.x,
                    "pointer_y": current.pointer.y, "pasteboard_change_count": current.clipboardChangeCount,
                ])
                guard current == baseline, periodic.changedSamples == 0, periodic.readFailures == 0,
                      !app.isTerminated, app.launchDate == launch, !app.isActive,
                      AXIsProcessTrusted() else {
                    throw Failure("Desktop, process generation, or permission changed; no further fixture input.")
                }
            }

            phase = "baseline_native_tab_identity"
            try sample("before_native_tab_witness")
            let selection = try TabSelectionWitness.read(processIdentifier: pid)
            try sample("after_native_tab_witness")
            phase = "list_and_attach_exact_fixture"
            let candidates = try await transport.listCandidates()
            try sample("after_candidate_list")
            let matches = candidates.filter { $0.url == fixture }
            guard matches.count == 1, let candidate = matches.first else {
                throw Failure("Exactly one preexisting fixture URL is required; no target was created or navigated.")
            }
            let beforeIDs = Set(candidates.map(\.targetID))
            let target = try await transport.attach(targetID: candidate.targetID)
            attachedTarget = target
            guard target.url == fixture else { throw Failure("The attached target left the authorized fixture.") }
            try sample("after_attach")
            let taskKey = "ordinary-borrowed-fixture-" + UUID().uuidString
            var binding = try await sessionBroker.bindBorrowed(taskKey: taskKey, processIdentifier: pid, target: target)
            try sample("after_binding")

            for cycle in 1...5 {
                phase = "cycle_\(cycle)"
                try selection.requireUnchanged(processIdentifier: pid)
                try sample("cycle_\(cycle)_before")
                let started = clock.now
                var observation = try await sessionBroker.snapshot(
                    taskKey: taskKey, binding: binding, bundleIdentifier: "com.google.Chrome", query: nil
                )
                try sample("cycle_\(cycle)_after_snapshot")
                guard observation.snapshot.documentURL == fixture,
                      observation.snapshot.elements.contains(where: { $0.label == "Counter \(cycle - 1)" }),
                      let button = observation.snapshot.elements.first(where: {
                          $0.label == "Increment fixture counter" && $0.supportsPress
                      }) else { throw Failure("Fixture is not fresh or the expected counter/button is absent.") }
                try await sessionBroker.perform(taskKey: taskKey, binding: observation.binding, snapshot: observation.snapshot,
                                                elementIndex: button.index, action: "AXPress")
                try sample("cycle_\(cycle)_after_press")
                observation = try await sessionBroker.snapshot(
                    taskKey: taskKey, binding: observation.binding, bundleIdentifier: "com.google.Chrome", query: nil
                )
                try sample("cycle_\(cycle)_after_counter_read")
                guard observation.snapshot.documentURL == fixture,
                      observation.snapshot.elements.contains(where: { $0.label == "Counter \(cycle)" }),
                      let input = observation.snapshot.elements.first(where: {
                          $0.supportsSetText && $0.label.contains("Fixture Unicode value")
                      }) else { throw Failure("Expected counter increment or Unicode field was not verified.") }
                let text = "HDé7-\(cycle) 東京 👋"
                try await sessionBroker.setText(taskKey: taskKey, binding: observation.binding, snapshot: observation.snapshot,
                                               elementIndex: input.index, text: text)
                try sample("cycle_\(cycle)_after_set_text")
                observation = try await sessionBroker.snapshot(
                    taskKey: taskKey, binding: observation.binding, bundleIdentifier: "com.google.Chrome", query: nil
                )
                try sample("cycle_\(cycle)_after_unicode_read")
                guard observation.snapshot.documentURL == fixture,
                      observation.snapshot.elements.first(where: { $0.supportsSetText })?.value == text,
                      observation.snapshot.elements.contains(where: { $0.label == "Value \(text)" }) else {
                    throw Failure("Exact Unicode field value and input-event echo were not verified.")
                }
                binding = observation.binding
                let elapsed = started.duration(to: clock.now).components
                cycleMilliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                try selection.requireUnchanged(processIdentifier: pid)
                try sample("cycle_\(cycle)_after_native_tab_witness")
                report["completed_cycles"] = cycle
            }
            report["exact_unicode"] = true
            phase = "release_borrowed_session"
            try await sessionBroker.revoke(taskKey: taskKey, binding: binding)
            await sessionBroker.invalidateAll()
            try await transport.detach(target: target)
            attachedTarget = nil
            report["detached"] = true
            try sample("after_detach")
            let remaining = try await transport.listCandidates()
            try sample("after_final_candidate_list")
            guard Set(remaining.map(\.targetID)) == beforeIDs else {
                throw Failure("The browser's candidate target ID set changed.")
            }
            report["candidate_target_set_preserved"] = true
            try selection.requireUnchanged(processIdentifier: pid)
            report["selected_native_window_and_tab_preserved"] = true
            await transport.shutdown()
            report["connection_closed"] = true
            try sample("after_connection_close")
            guard !app.isTerminated, app.launchDate == launch else { throw Failure("Original Chrome process is no longer alive.") }
            report["original_chrome_alive"] = true
            periodic.stop()
            guard periodic.samples >= 2 else { throw Failure("Insufficient periodic desktop samples for this gate.") }
            report["desktop_unchanged_at_all_samples"] = true
            report["median_cycle_ms"] = cycleMilliseconds.sorted()[2]
            report["status"] = "passed"
            phase = "complete"
        } catch {
            await broker?.invalidateAll()
            if let adapter, let target = attachedTarget {
                do { try await adapter.detach(target: target); report["detached"] = true }
                catch { report["detached"] = false }
            }
            await adapter?.shutdown()
            report["connection_closed"] = true
            // Do not leak Chrome protocol error bodies or user tab metadata to
            // XCTest output. Phase + error type identify a failing boundary.
            report["error_category"] = String(describing: type(of: error))
            // These enums contain only fixed local cases/numeric protocol
            // codes, never peer text, profile paths or browser metadata.
            if let error = error as? ChromeDebuggingEndpointError { report["error_case"] = String(describing: error) }
            if let error = error as? ChromeDebuggingProcessBindingError { report["error_case"] = String(describing: error) }
            if let error = error as? BrowserCDPConnectionError { report["error_case"] = String(describing: error) }
            throw Failure("Ordinary Chrome fixture gate failed at \(phase); category \(String(describing: type(of: error))). See redacted boundary evidence.")
        }
    }
}

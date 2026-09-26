import ApplicationServices
import Foundation
import XCTest
@testable import AutomationCore

@MainActor
private final class RunningBindingFixture: RunningApplicationBindingRuntime, ApplicationWindowRuntime {
    static let ordinaryBundle = "com.example.fixture"
    let application = AXUIElementCreateApplication(61_000)
    var window = AXUIElementCreateApplication(61_001)
    var candidates = [state()]
    var arguments: [Int32: [String]] = [:]
    var permission = true
    var boundPID: Int32 = 77
    var discoveryReads = 0
    var windowReads = 0
    var argumentReads = [Int32]()
    var afterWindow: (() -> Void)?
    var onDiscovery: (() -> Void)?
    var windowFailure: Error?
    var cancellation: (() throws -> Void)?

    static func state(pid: Int32 = 77, bundle: String = ordinaryBundle, launch: Double? = 100, terminated: Bool = false) -> ApplicationWindowProcessState {
        ApplicationWindowProcessState(
            processIdentifier: pid, bundleIdentifier: bundle, applicationName: "Synthetic fixture",
            launchDate: launch.map(Date.init(timeIntervalSince1970:)), isTerminated: terminated
        )
    }

    func runningApplications(bundleIdentifier: String) throws -> [ApplicationWindowProcessState] {
        discoveryReads += 1
        onDiscovery?()
        return candidates
    }

    func chromeArguments(processIdentifier: Int32) throws -> [String]? {
        argumentReads.append(processIdentifier)
        return arguments[processIdentifier]
    }

    func binder() -> RunningApplicationBinder {
        RunningApplicationBinder(
            runtime: self,
            accessibilityCheck: { self.permission },
            cancellationCheck: {
                try Task.checkCancellation()
                try self.cancellation?()
            },
            resolveWindow: { pid, bundle in
                self.windowReads += 1
                if let error = self.windowFailure { throw error }
                self.boundPID = pid
                let observation = try self.windowObservation(pid: pid, bundle: bundle)
                self.afterWindow?()
                return observation
            }
        )
    }

    func windowObservation(pid: Int32 = 77, bundle: String = ordinaryBundle) throws -> ApplicationWindowObservation {
        boundPID = pid
        return try ApplicationWindowReader(accessibilityCheck: { self.permission }, runtime: self)
            .selectedWindowObservation(processIdentifier: pid, expectedBundleIdentifier: bundle)
    }

    func runningApplication(processIdentifier: Int32) throws -> ApplicationWindowProcessState? {
        candidates.first { $0.processIdentifier == processIdentifier && !$0.isTerminated }
    }

    func elements(processIdentifier: Int32) throws -> ApplicationWindowElements {
        ApplicationWindowElements(application: application, windows: [window], focusedWindow: window, mainWindow: window)
    }

    func processIdentifier(of element: AXUIElement) throws -> Int32 { boundPID }
    func role(of window: AXUIElement) throws -> String? { "AXWindow" }
    func metadata(of window: AXUIElement) throws -> ApplicationWindowMetadata {
        ApplicationWindowMetadata(title: "Synthetic window", subrole: "AXStandardWindow", frame: nil)
    }
}

final class RunningApplicationBindingTests: XCTestCase {
    @MainActor
    func testBindsOnlyExistingExactMatchAndReturnsSameWindowIdentity() throws {
        let fixture = RunningBindingFixture()
        fixture.candidates += [RunningBindingFixture.state(pid: 90, bundle: "com.example.unrelated")]
        let binding = try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
        XCTAssertEqual(binding.application.processIdentifier, 77)
        XCTAssertEqual(binding.application.bundleIdentifier, RunningBindingFixture.ordinaryBundle)
        XCTAssertTrue(try binding.window.identity.isStillSelected())
        XCTAssertEqual(fixture.discoveryReads, 2)
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertTrue(fixture.argumentReads.isEmpty)
        // The runtime interface has no launch, activation or input operation.
    }

    @MainActor
    func testAbsentAndTerminatedMatchesNeverResolveWindow() {
        for candidates in [[], [RunningBindingFixture.state(terminated: true)], [RunningBindingFixture.state(bundle: "com.example.other")]] {
            let fixture = RunningBindingFixture()
            fixture.candidates = candidates
            XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
                XCTAssertEqual($0 as? RunningApplicationBindingError, .notRunning)
            }
            XCTAssertEqual(fixture.windowReads, 0)
        }
    }

    @MainActor
    func testAmbiguousBundleFailsRatherThanSelectingFirst() {
        let fixture = RunningBindingFixture()
        fixture.candidates.append(RunningBindingFixture.state(pid: 78))
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertEqual($0 as? RunningApplicationBindingError, .ambiguousApplications(2))
        }
        XCTAssertEqual(fixture.windowReads, 0)
    }

    @MainActor
    func testInvalidTargetsAndUnknownProcessGenerationFailClosed() {
        for bundle in ["", " com.example.fixture", "com.example.fixture\n", String(repeating: "a", count: 256)] {
            let fixture = RunningBindingFixture()
            XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: bundle)) {
                XCTAssertEqual($0 as? RunningApplicationBindingError, .invalidBundleIdentifier)
            }
            XCTAssertEqual(fixture.discoveryReads, 0)
        }
        for candidate in [RunningBindingFixture.state(pid: 0), RunningBindingFixture.state(launch: nil)] {
            let fixture = RunningBindingFixture()
            fixture.candidates = [candidate]
            XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
                XCTAssertEqual($0 as? RunningApplicationBindingError, .processIdentityUnavailable)
            }
            XCTAssertEqual(fixture.windowReads, 0)
        }
    }

    @MainActor
    func testPermissionRequiredBeforeAnyDiscoveryAndRecheckedBeforePublication() {
        let fixture = RunningBindingFixture()
        fixture.permission = false
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertEqual($0 as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertEqual(fixture.discoveryReads, 0)
        fixture.permission = true
        fixture.afterWindow = { fixture.permission = false }
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertEqual($0 as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertEqual(fixture.windowReads, 1)
    }

    @MainActor
    func testPIDReuseDuringWindowResolutionCannotPublishBinding() {
        let fixture = RunningBindingFixture()
        fixture.afterWindow = { fixture.candidates = [RunningBindingFixture.state(launch: 200)] }
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertEqual($0 as? RunningApplicationBindingError, .targetChanged)
        }
    }

    @MainActor
    func testProcessReplacementAndNewAmbiguityDuringResolutionFailClosed() {
        for replacement in [[RunningBindingFixture.state(pid: 78)], [RunningBindingFixture.state(), RunningBindingFixture.state(pid: 78)]] {
            let fixture = RunningBindingFixture()
            fixture.afterWindow = { fixture.candidates = replacement }
            XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle))
            XCTAssertEqual(fixture.windowReads, 1)
        }
    }

    @MainActor
    func testWindowReplacementAfterObservationFailsFinalIdentityCheck() {
        let fixture = RunningBindingFixture()
        fixture.afterWindow = { fixture.window = AXUIElementCreateApplication(61_002) }
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertEqual($0 as? RunningApplicationBindingError, .targetChanged)
        }
    }

    @MainActor
    func testWindowResolverFailurePropagatesWithoutRetry() {
        let fixture = RunningBindingFixture()
        fixture.windowFailure = AutomationError.accessibilityFailure(operation: "synthetic", code: AXError.cannotComplete.rawValue)
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertEqual($0 as? AutomationError, fixture.windowFailure as? AutomationError)
        }
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertEqual(fixture.discoveryReads, 1)
    }

    @MainActor
    func testResolverCannotSubstituteAnotherApplicationObservation() throws {
        let fixture = RunningBindingFixture()
        let other = RunningBindingFixture()
        other.candidates = [RunningBindingFixture.state(pid: 88)]
        let observation = try other.windowObservation(pid: 88)
        let binder = RunningApplicationBinder(runtime: fixture, accessibilityCheck: { true }, resolveWindow: { _, _ in observation })
        XCTAssertThrowsError(try binder.bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertEqual($0 as? RunningApplicationBindingError, .targetChanged)
        }
    }

    @MainActor
    func testCancellationStopsBeforeDiscoveryAndAfterWindowRead() {
        let fixture = RunningBindingFixture()
        fixture.cancellation = { throw CancellationError() }
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(fixture.discoveryReads, 0)
        var canceled = false
        fixture.cancellation = { if canceled { throw CancellationError() } }
        fixture.afterWindow = { canceled = true }
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(fixture.discoveryReads, 1)
        XCTAssertEqual(fixture.windowReads, 1)
    }

    @MainActor
    func testCanceledTaskDoesNotDiscoverOrBind() async throws {
        let fixture = RunningBindingFixture()
        try await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: RunningBindingFixture.ordinaryBundle)) {
                XCTAssertTrue($0 is CancellationError)
            }
        }.value
        XCTAssertEqual(fixture.discoveryReads, 0)
        XCTAssertEqual(fixture.windowReads, 0)
    }

    @MainActor
    func testChromeUsesOrdinaryProcessBesideIsolatedInstance() throws {
        let fixture = RunningBindingFixture()
        fixture.candidates = [RunningBindingFixture.state(pid: 42, bundle: "com.google.Chrome"), RunningBindingFixture.state(pid: 43, bundle: "com.google.Chrome")]
        fixture.arguments = [42: ["chrome"], 43: ["chrome", "--user-data-dir=/tmp/synthetic"]]
        let binding = try fixture.binder().bind(bundleIdentifier: "com.google.Chrome")
        XCTAssertEqual(binding.application.processIdentifier, 42)
        XCTAssertEqual(fixture.argumentReads, [42, 43, 42, 43])
    }

    @MainActor
    func testChromeRejectsIsolatedUnknownAndAmbiguousCandidates() {
        for (arguments, failure): ([Int32: [String]], ExistingChromeError) in [
            ([42: ["chrome", "--remote-debugging-pipe"], 43: ["chrome", "--user-data-dir=/tmp/synthetic"]], .noOrdinaryBrowser),
            ([42: ["chrome"]], .processCannotBeInspected),
            ([42: ["chrome"], 43: ["chrome"]], .ambiguousOrdinaryBrowsers),
        ] {
            let fixture = RunningBindingFixture()
            fixture.candidates = [RunningBindingFixture.state(pid: 42, bundle: "com.google.Chrome"), RunningBindingFixture.state(pid: 43, bundle: "com.google.Chrome")]
            fixture.arguments = arguments
            XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: "com.google.Chrome")) {
                XCTAssertEqual($0 as? ExistingChromeError, failure)
            }
            XCTAssertEqual(fixture.windowReads, 0)
        }
    }

    @MainActor
    func testChromeProfileIsRevalidatedAfterWindowResolution() {
        let fixture = RunningBindingFixture()
        fixture.candidates = [RunningBindingFixture.state(pid: 42, bundle: "com.google.Chrome")]
        fixture.arguments = [42: ["chrome"]]
        fixture.afterWindow = { fixture.arguments[42] = ["chrome", "--remote-debugging-port=9222"] }
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: "com.google.Chrome")) {
            XCTAssertEqual($0 as? ExistingChromeError, .noOrdinaryBrowser)
        }
        XCTAssertEqual(fixture.windowReads, 1)
    }
}

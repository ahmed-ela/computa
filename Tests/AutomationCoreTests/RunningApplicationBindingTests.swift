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
    var permission = true
    var boundPID: Int32 = 77
    var discoveryReads = 0
    var windowReads = 0
    var afterWindow: (() -> Void)?
    var beforeWindow: (() -> Void)?
    var onDiscovery: (() -> Void)?
    var windowFailure: Error?
    var elementsFailure: Error?
    var cancellation: (() throws -> Void)?
    var retryWaits: [Duration] = []
    var onRetryWait: ((Duration) async throws -> Void)?

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

    func binder() -> RunningApplicationBinder {
        RunningApplicationBinder(
            runtime: self,
            accessibilityCheck: { self.permission },
            cancellationCheck: {
                try Task.checkCancellation()
                try self.cancellation?()
            },
            waitForWindowRetry: { delay in
                self.retryWaits.append(delay)
                try await self.onRetryWait?(delay)
            },
            resolveWindow: { pid, bundle in
                self.windowReads += 1
                self.beforeWindow?()
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
        if let error = elementsFailure { throw error }
        return ApplicationWindowElements(application: application, windows: [window], focusedWindow: window, mainWindow: window)
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
    func testBrowserApplicationUsesTheSameExactProcessPolicyAsOtherNativeApps() throws {
        let fixture = RunningBindingFixture()
        fixture.candidates = [RunningBindingFixture.state(pid: 42, bundle: "com.google.Chrome")]
        let binding = try fixture.binder().bind(bundleIdentifier: "com.google.Chrome")
        XCTAssertEqual(binding.application.processIdentifier, 42)
        XCTAssertEqual(fixture.windowReads, 1)
        fixture.candidates.append(RunningBindingFixture.state(pid: 43, bundle: "com.google.Chrome"))
        XCTAssertThrowsError(try fixture.binder().bind(bundleIdentifier: "com.google.Chrome")) {
            XCTAssertEqual($0 as? RunningApplicationBindingError, .ambiguousApplications(2))
        }
        XCTAssertEqual(fixture.windowReads, 1, "Ambiguity must fail before reading another window.")
    }

    @MainActor
    func testReadyBindingSucceedsImmediatelyWithoutWaiting() async throws {
        let fixture = RunningBindingFixture()
        let binding = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
        XCTAssertEqual(binding.application.processIdentifier, 77)
        XCTAssertTrue(try binding.window.identity.isStillSelected())
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertEqual(fixture.discoveryReads, 2)
        XCTAssertTrue(fixture.retryWaits.isEmpty)
    }

    @MainActor
    func testInitialWindowUnavailableSettlesWithoutActivationOrInput() async throws {
        let fixture = RunningBindingFixture()
        fixture.windowFailure = ApplicationWindowReadError.windowUnavailable
        fixture.onRetryWait = { _ in fixture.windowFailure = nil }
        let binding = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
        XCTAssertEqual(binding.application.processIdentifier, 77)
        XCTAssertEqual(fixture.windowReads, 2)
        XCTAssertEqual(fixture.retryWaits, [.milliseconds(150)])
        XCTAssertEqual(fixture.discoveryReads, 3)
    }

    @MainActor
    func testInitialAXCannotCompleteCanSucceedOnThirdRead() async throws {
        let fixture = RunningBindingFixture()
        fixture.windowFailure = AutomationError.accessibilityFailure(operation: "fixture", code: AXError.cannotComplete.rawValue)
        fixture.onRetryWait = { _ in
            if fixture.retryWaits.count == 2 { fixture.windowFailure = nil }
        }
        _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
        XCTAssertEqual(fixture.windowReads, 3)
        XCTAssertEqual(fixture.retryWaits, [.milliseconds(150), .milliseconds(300)])
        XCTAssertEqual(fixture.discoveryReads, 4)
    }

    @MainActor
    func testInitialTransientDiagnosticsAreRetried() async throws {
        for reason: ApplicationWindowAvailabilityDiagnostic.Reason in [.windowsNoValue, .windowsReturnedNoValue, .noSelectedWindow] {
            let fixture = RunningBindingFixture()
            fixture.windowFailure = ApplicationWindowReadError.windowSelectionUnavailable(.init(
                reason: reason, windowsCode: AXError.noValue.rawValue, windowCount: 0,
                focusedCode: AXError.noValue.rawValue, focusedPresent: false,
                mainCode: AXError.noValue.rawValue, mainPresent: false
            ))
            fixture.onRetryWait = { _ in fixture.windowFailure = nil }
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTAssertEqual(fixture.windowReads, 2)
            XCTAssertEqual(fixture.retryWaits, [.milliseconds(150)])
        }
    }

    @MainActor
    func testInitialRetryExhaustionReturnsOriginalErrorAfterExactlyThreeReads() async {
        let fixture = RunningBindingFixture()
        fixture.windowFailure = ApplicationWindowReadError.windowUnavailable
        do {
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTFail("Persistent unavailability must not produce a binding")
        } catch {
            XCTAssertEqual(error as? ApplicationWindowReadError, .windowUnavailable)
        }
        XCTAssertEqual(fixture.windowReads, 3)
        XCTAssertEqual(fixture.retryWaits, [.milliseconds(150), .milliseconds(300)])
        XCTAssertEqual(fixture.discoveryReads, 3)
    }

    @MainActor
    func testCancelledRetryWaitStopsWithoutAnotherRead() async {
        let fixture = RunningBindingFixture()
        fixture.windowFailure = ApplicationWindowReadError.windowUnavailable
        fixture.onRetryWait = { _ in throw CancellationError() }
        do {
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTFail("Cancellation must stop binding")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertEqual(fixture.discoveryReads, 1)
        XCTAssertEqual(fixture.retryWaits, [.milliseconds(150)])
    }

    @MainActor
    func testPermissionRevokedDuringRetryWaitStopsBeforeDiscoveryOrRead() async {
        let fixture = RunningBindingFixture()
        fixture.windowFailure = ApplicationWindowReadError.windowUnavailable
        fixture.onRetryWait = { _ in fixture.permission = false }
        do {
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTFail("Revoked Accessibility permission must stop binding")
        } catch {
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertEqual(fixture.discoveryReads, 1)
        XCTAssertEqual(fixture.retryWaits, [.milliseconds(150)])
    }

    @MainActor
    func testCancellationRecheckedAfterRetryWait() async {
        let fixture = RunningBindingFixture()
        var canceled = false
        fixture.windowFailure = ApplicationWindowReadError.windowUnavailable
        fixture.cancellation = { if canceled { throw CancellationError() } }
        fixture.onRetryWait = { _ in canceled = true }
        do {
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTFail("Cancellation must be rechecked even when the wait returns")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertEqual(fixture.discoveryReads, 1)
    }

    @MainActor
    func testPIDReuseOrReplacementDuringRetryCannotRebindNewProcess() async {
        for replacement in [RunningBindingFixture.state(launch: 200), RunningBindingFixture.state(pid: 78)] {
            let fixture = RunningBindingFixture()
            fixture.windowFailure = ApplicationWindowReadError.windowUnavailable
            fixture.onRetryWait = { _ in fixture.candidates = [replacement] }
            do {
                _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
                XCTFail("A retry must preserve the initial process generation")
            } catch {
                XCTAssertEqual(error as? RunningApplicationBindingError, .targetChanged)
            }
            XCTAssertEqual(fixture.windowReads, 1)
            XCTAssertEqual(fixture.discoveryReads, 2)
            XCTAssertEqual(fixture.retryWaits, [.milliseconds(150)])
        }
    }

    @MainActor
    func testNewAmbiguityDuringRetryStopsWithoutChoosingAnApplication() async {
        let fixture = RunningBindingFixture()
        fixture.windowFailure = ApplicationWindowReadError.windowUnavailable
        fixture.onRetryWait = { _ in fixture.candidates.append(RunningBindingFixture.state(pid: 78)) }
        do {
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTFail("An ambiguous target must not be guessed")
        } catch {
            XCTAssertEqual(error as? RunningApplicationBindingError, .ambiguousApplications(2))
        }
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertEqual(fixture.retryWaits, [.milliseconds(150)])
    }

    @MainActor
    func testInitialUnsupportedMalformedAndIdentityErrorsDoNotRetry() async {
        let diagnostic = ApplicationWindowAvailabilityDiagnostic(
            reason: .windowsUnsupported, windowsCode: AXError.attributeUnsupported.rawValue,
            windowCount: nil, focusedCode: nil, focusedPresent: false, mainCode: nil, mainPresent: false
        )
        for failure in [
            ApplicationWindowReadError.windowSelectionUnavailable(diagnostic), .invalidTarget,
            .applicationUnavailable, .applicationIdentityUnavailable, .applicationMismatch,
            .ambiguousWindows(2), .windowOwnershipMismatch, .invalidWindowRole, .observationChanged,
        ] {
            let fixture = RunningBindingFixture()
            fixture.windowFailure = failure
            do {
                _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
                XCTFail("Non-transient errors must not retry: \(failure)")
            } catch { XCTAssertEqual(error as? ApplicationWindowReadError, failure) }
            XCTAssertEqual(fixture.windowReads, 1)
            XCTAssertTrue(fixture.retryWaits.isEmpty)
        }
        for code in [AXError.attributeUnsupported, .illegalArgument, .invalidUIElement] {
            let fixture = RunningBindingFixture()
            let failure = AutomationError.accessibilityFailure(operation: "fixture", code: code.rawValue)
            fixture.windowFailure = failure
            do {
                _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
                XCTFail("Only AX cannotComplete is retryable")
            } catch { XCTAssertEqual(error as? AutomationError, failure) }
            XCTAssertEqual(fixture.windowReads, 1)
            XCTAssertTrue(fixture.retryWaits.isEmpty)
        }
    }

    @MainActor
    func testUnavailableFinalIdentityAfterObservationNeverStartsRetry() async {
        let fixture = RunningBindingFixture()
        fixture.afterWindow = { fixture.elementsFailure = ApplicationWindowReadError.windowUnavailable }
        do {
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTFail("Once an observation exists, loss of its identity is terminal")
        } catch { XCTAssertEqual(error as? ApplicationWindowReadError, .windowUnavailable) }
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertTrue(fixture.retryWaits.isEmpty)
    }

    @MainActor
    func testTransientAXFailureAfterObservationNeverStartsRetry() async {
        let fixture = RunningBindingFixture()
        let failure = AutomationError.accessibilityFailure(operation: "fixture", code: AXError.cannotComplete.rawValue)
        fixture.afterWindow = { fixture.elementsFailure = failure }
        do {
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTFail("A final identity guard must not be bypassed by retrying")
        } catch { XCTAssertEqual(error as? AutomationError, failure) }
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertTrue(fixture.retryWaits.isEmpty)
    }

    @MainActor
    func testChangedSelectedWindowAfterObservationNeverStartsRetry() async {
        let fixture = RunningBindingFixture()
        fixture.afterWindow = { fixture.window = AXUIElementCreateApplication(61_002) }
        do {
            _ = try await fixture.binder().bindWhenReady(bundleIdentifier: RunningBindingFixture.ordinaryBundle)
            XCTFail("Retry must never select a replacement window after observation")
        } catch { XCTAssertEqual(error as? RunningApplicationBindingError, .targetChanged) }
        XCTAssertEqual(fixture.windowReads, 1)
        XCTAssertTrue(fixture.retryWaits.isEmpty)
    }
}

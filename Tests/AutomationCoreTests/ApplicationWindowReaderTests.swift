import ApplicationServices
import Foundation
import XCTest
@testable import AutomationCore

@MainActor
private final class FakeApplicationWindowRuntime: ApplicationWindowRuntime {
    let application = AXUIElementCreateApplication(51_000)
    let first = AXUIElementCreateApplication(51_001)
    let second = AXUIElementCreateApplication(51_002)
    var process: ApplicationWindowProcessState? = ApplicationWindowProcessState(
        processIdentifier: 77, bundleIdentifier: "com.example.probe", applicationName: "Probe",
        launchDate: Date(timeIntervalSince1970: 100), isTerminated: false
    )
    var windows: [AXUIElement] = []
    var focused: AXUIElement?
    var main: AXUIElement?
    var availabilityCodes: (windows: Int32, focused: Int32, main: Int32)?
    var applicationOwner: Int32 = 77
    var windowOwner: Int32 = 77
    var windowRole: String? = "AXWindow"
    var selectedMetadata = ApplicationWindowMetadata(
        title: "Synthetic", subrole: "AXStandardWindow",
        frame: WindowFrame(x: 10, y: 20, width: 640, height: 480)
    )
    var failure: AutomationError?
    var beforeMetadata: (() -> Void)?
    var beforeProcessRead: (() -> Void)?
    var beforeElementsRead: (() -> Void)?
    var processReads = 0
    var elementsReads = 0
    var metadataReads = 0

    init() { windows = [first]; focused = first; main = first }

    func runningApplication(processIdentifier: Int32) throws -> ApplicationWindowProcessState? {
        processReads += 1
        beforeProcessRead?()
        return process
    }

    func elements(processIdentifier: Int32) throws -> ApplicationWindowElements {
        elementsReads += 1
        if let failure { throw failure }
        beforeElementsRead?()
        return ApplicationWindowElements(application: application, windows: windows, focusedWindow: focused,
                                         mainWindow: main, availabilityCodes: availabilityCodes)
    }

    func processIdentifier(of element: AXUIElement) throws -> Int32 {
        CFEqual(element, application) ? applicationOwner : windowOwner
    }

    func role(of window: AXUIElement) throws -> String? { windowRole }

    func metadata(of window: AXUIElement) throws -> ApplicationWindowMetadata {
        metadataReads += 1
        beforeMetadata?()
        return selectedMetadata
    }

    func reader(permission: @escaping () -> Bool = { true }) -> ApplicationWindowReader {
        ApplicationWindowReader(accessibilityCheck: permission, runtime: self)
    }

    func observation() throws -> ApplicationWindowObservation {
        try reader().selectedWindowObservation(processIdentifier: 77, expectedBundleIdentifier: "com.example.probe")
    }

    func changeProcess(pid: Int32 = 77, bundle: String? = "com.example.probe", launch: Date? = Date(timeIntervalSince1970: 100), terminated: Bool = false) {
        process = ApplicationWindowProcessState(
            processIdentifier: pid, bundleIdentifier: bundle, applicationName: "Probe", launchDate: launch, isTerminated: terminated
        )
    }
}

final class ApplicationWindowReaderTests: XCTestCase {
    @MainActor
    func testAppBoundObservationIsIndependentOfGlobalForegroundAndPreservesGlobalGuards() throws {
        let runtime = FakeApplicationWindowRuntime()
        let observation = try runtime.observation()
        XCTAssertEqual(observation.info.processIdentifier, 77)
        XCTAssertEqual(observation.info.title, "Synthetic")
        XCTAssertEqual(observation.selectionSource, .focusedWindow)
        var global: FocusedWindowElements? = FocusedWindowElements(processIdentifier: 77, window: runtime.first)
        let globalReader = FocusedWindowReader(accessibilityCheck: { true }, focusedElements: { global })
        let globalIdentity = try XCTUnwrap(globalReader.focusedWindowIdentity())
        XCTAssertTrue(observation.identity.isSameWindow(as: globalIdentity))
        XCTAssertTrue(try globalIdentity.isStillFocused())

        global = FocusedWindowElements(processIdentifier: 88, window: runtime.second)
        XCTAssertFalse(try globalIdentity.isStillFocused())
        XCTAssertFalse(try globalIdentity.isSameFocusedUIElement())
        XCTAssertTrue(try observation.identity.isStillSelected())
        let unrelated = try XCTUnwrap(globalReader.focusedWindowIdentity())
        XCTAssertFalse(observation.identity.isSameWindow(as: unrelated))
        global = nil
        XCTAssertTrue(try observation.identity.isStillSelected())
        XCTAssertFalse(try globalIdentity.isStillFocused())
    }

    @MainActor
    func testPermissionFailureStopsBeforeProcessOrAXReads() {
        let runtime = FakeApplicationWindowRuntime()
        XCTAssertThrowsError(try runtime.reader(permission: { false }).selectedWindowObservation(
            processIdentifier: 77, expectedBundleIdentifier: "com.example.probe"
        )) { XCTAssertEqual($0 as? AutomationError, .permissionNotGranted(.accessibility)) }
        XCTAssertEqual(runtime.processReads, 0)
        XCTAssertEqual(runtime.elementsReads, 0)
    }

    @MainActor
    func testRevokedPermissionInvalidatesRetainedIdentityBeforeAXRead() throws {
        let runtime = FakeApplicationWindowRuntime()
        var allowed = true
        let observation = try runtime.reader(permission: { allowed }).selectedWindowObservation(
            processIdentifier: 77, expectedBundleIdentifier: "com.example.probe"
        )
        let reads = runtime.elementsReads
        allowed = false
        XCTAssertThrowsError(try observation.identity.isStillSelected()) {
            XCTAssertEqual($0 as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertEqual(runtime.elementsReads, reads)
    }

    @MainActor
    func testPermissionRevokedDuringAXReadPreventsPublication() {
        let runtime = FakeApplicationWindowRuntime()
        var allowed = true
        runtime.beforeElementsRead = { allowed = false }
        XCTAssertThrowsError(try runtime.reader(permission: { allowed }).selectedWindowObservation(
            processIdentifier: 77, expectedBundleIdentifier: "com.example.probe"
        )) { XCTAssertEqual($0 as? AutomationError, .permissionNotGranted(.accessibility)) }
        XCTAssertEqual(runtime.metadataReads, 0)
    }

    @MainActor
    func testMissingFocusedWindowUsesMainWindowEvenWithMultipleWindows() throws {
        let runtime = FakeApplicationWindowRuntime()
        runtime.windows = [runtime.first, runtime.second]
        runtime.focused = nil
        runtime.main = runtime.second
        let observation = try runtime.observation()
        XCTAssertEqual(observation.selectionSource, .mainWindow)
        XCTAssertTrue(CFEqual(try observation.identity.validatedWindowElement(), runtime.second))
    }

    @MainActor
    func testFocusedWindowTakesPrecedenceOverMainWindow() throws {
        let runtime = FakeApplicationWindowRuntime()
        runtime.windows = [runtime.first, runtime.second]
        runtime.main = runtime.second
        let observation = try runtime.observation()
        XCTAssertEqual(observation.selectionSource, .focusedWindow)
        XCTAssertTrue(CFEqual(try observation.identity.validatedWindowElement(), runtime.first))
    }

    @MainActor
    func testOnlyWindowFallbackNeverGuessesAmongMultipleWindows() throws {
        let runtime = FakeApplicationWindowRuntime()
        runtime.focused = nil
        runtime.main = nil
        let observation = try runtime.observation()
        XCTAssertEqual(observation.selectionSource, .onlyWindow)
        runtime.windows = [runtime.first, runtime.second]
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .ambiguousWindows(2))
        }
        XCTAssertThrowsError(try observation.identity.isStillSelected())
    }

    @MainActor
    func testMissingAndDuplicateWindowsFailClosed() {
        let runtime = FakeApplicationWindowRuntime()
        runtime.focused = nil
        runtime.main = nil
        runtime.windows = []
        XCTAssertThrowsError(try runtime.observation()) {
            guard case let .windowSelectionUnavailable(diagnostic) = $0 as? ApplicationWindowReadError else {
                return XCTFail("Expected structural window availability diagnostic")
            }
            XCTAssertEqual(diagnostic.reason, .noSelectedWindow)
            XCTAssertEqual(diagnostic.windowCount, 0)
            XCTAssertNil(diagnostic.windowsCode)
            XCTAssertFalse(diagnostic.focusedPresent)
            XCTAssertFalse(diagnostic.mainPresent)
        }
        runtime.windows = [runtime.first, AXUIElementCreateApplication(51_001)]
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .ambiguousWindows(2))
        }
    }

    @MainActor
    func testSelectedWindowMustBeMemberOfExactApplicationWindowList() {
        let runtime = FakeApplicationWindowRuntime()
        runtime.focused = runtime.second
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .windowOwnershipMismatch)
        }
        XCTAssertEqual(runtime.metadataReads, 0)
    }

    @MainActor
    func testApplicationAndWindowPIDMismatchFailClosed() {
        let runtime = FakeApplicationWindowRuntime()
        runtime.applicationOwner = 88
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .applicationMismatch)
        }
        runtime.applicationOwner = 77
        runtime.windowOwner = 88
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .windowOwnershipMismatch)
        }
    }

    @MainActor
    func testApplicationMetadataMustMatchExactPIDAndBundle() {
        let runtime = FakeApplicationWindowRuntime()
        runtime.changeProcess(pid: 88)
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .applicationMismatch)
        }
        runtime.changeProcess(bundle: "com.example.other")
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .applicationMismatch)
        }
        XCTAssertEqual(runtime.elementsReads, 0)
    }

    @MainActor
    func testMissingLaunchIdentityOrTerminatedApplicationFailsClosed() {
        let runtime = FakeApplicationWindowRuntime()
        runtime.changeProcess(launch: nil)
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .applicationIdentityUnavailable)
        }
        runtime.changeProcess(terminated: true)
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .applicationUnavailable)
        }
        XCTAssertEqual(runtime.elementsReads, 0)
    }

    @MainActor
    func testNonWindowRootAndAXErrorsAreNotSilentlyDowngraded() {
        let runtime = FakeApplicationWindowRuntime()
        runtime.windowRole = "AXApplication"
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .invalidWindowRole)
        }
        runtime.failure = .accessibilityFailure(operation: "fixture", code: AXError.cannotComplete.rawValue)
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? AutomationError, runtime.failure)
        }
    }

    @MainActor
    func testFreshAXWrapperComparesEqualButReplacementWindowDoesNot() throws {
        let runtime = FakeApplicationWindowRuntime()
        let original = try runtime.observation()
        runtime.windows = [AXUIElementCreateApplication(51_001)]
        runtime.focused = AXUIElementCreateApplication(51_001)
        XCTAssertTrue(try original.identity.isStillSelected())
        XCTAssertTrue(original.identity.isSameWindow(as: try runtime.observation().identity))
        runtime.windows = [runtime.second]
        runtime.focused = runtime.second
        runtime.main = runtime.second
        XCTAssertFalse(try original.identity.isStillSelected())
        XCTAssertFalse(original.identity.isSameWindow(as: try runtime.observation().identity))
    }

    @MainActor
    func testProcessDeathAndPIDReuseInvalidateIdentity() throws {
        let runtime = FakeApplicationWindowRuntime()
        let identity = try runtime.observation().identity
        runtime.process = nil
        XCTAssertFalse(try identity.isStillSelected())
        runtime.changeProcess(launch: Date(timeIntervalSince1970: 200))
        XCTAssertFalse(try identity.isStillSelected())
        XCTAssertThrowsError(try identity.validatedWindowElement()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .observationChanged)
        }
    }

    @MainActor
    func testWindowChangeDuringMetadataReadPreventsMixedObservation() {
        let runtime = FakeApplicationWindowRuntime()
        runtime.beforeMetadata = {
            runtime.windows = [runtime.second]
            runtime.focused = runtime.second
            runtime.main = runtime.second
        }
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .observationChanged)
        }
    }

    @MainActor
    func testProcessGenerationChangeDuringMetadataReadPreventsPublication() {
        let runtime = FakeApplicationWindowRuntime()
        runtime.beforeMetadata = { runtime.changeProcess(launch: Date(timeIntervalSince1970: 200)) }
        XCTAssertThrowsError(try runtime.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .observationChanged)
        }
    }

    @MainActor
    func testFixedRootRuntimeReturnsExactWindowAndRejectsOtherPID() throws {
        let runtime = FakeApplicationWindowRuntime()
        let observation = try runtime.observation()
        let fixed = SystemAccessibilityTreeRuntime(
            fixedWindow: try observation.identity.validatedWindowElement(), processIdentifier: 77
        )
        let root = try fixed.applicationElement(processIdentifier: 77)
        XCTAssertTrue(CFEqual(root.storage, runtime.first))
        runtime.focused = runtime.second
        // The runtime cannot heuristically retarget a saved snapshot to another
        // window. The owner separately validates its retained window identity.
        XCTAssertTrue(CFEqual(try fixed.applicationElement(processIdentifier: 77).storage, runtime.first))
        XCTAssertThrowsError(try fixed.applicationElement(processIdentifier: 88)) {
            XCTAssertEqual($0 as? AutomationError, .staleAccessibilitySnapshot)
        }
    }

    @MainActor
    func testFixedRootSessionInitializerValidatesExactTargetAndCurrentIdentity() throws {
        let runtime = FakeApplicationWindowRuntime()
        let identity = try runtime.observation().identity
        let target = AccessibilityApplicationTarget(processIdentifier: 77, bundleIdentifier: "com.example.probe")
        let session = try AccessibilitySession(target: target, windowIdentity: identity)
        XCTAssertEqual(session.application, target)
        XCTAssertThrowsError(try AccessibilitySession(
            target: AccessibilityApplicationTarget(processIdentifier: 88, bundleIdentifier: "com.example.probe"), windowIdentity: identity
        )) { XCTAssertEqual($0 as? ApplicationWindowReadError, .applicationMismatch) }
        XCTAssertThrowsError(try AccessibilitySession(
            target: AccessibilityApplicationTarget(processIdentifier: 77), windowIdentity: identity
        )) { XCTAssertEqual($0 as? ApplicationWindowReadError, .applicationMismatch) }
        runtime.process = nil
        XCTAssertThrowsError(try AccessibilitySession(target: target, windowIdentity: identity)) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .observationChanged)
        }
    }

    @MainActor
    func testInvalidTargetIsRejectedBeforeAnyProviderRead() {
        let runtime = FakeApplicationWindowRuntime()
        for (pid, bundle) in [(Int32(0), "com.example.probe"), (77, "")] {
            XCTAssertThrowsError(try runtime.reader().selectedWindowObservation(processIdentifier: pid, expectedBundleIdentifier: bundle)) {
                XCTAssertEqual($0 as? ApplicationWindowReadError, .invalidTarget)
            }
        }
        XCTAssertEqual(runtime.processReads, 0)
    }

    @MainActor
    func testRawMissingWindowAttributePreservesEachCodeAndQueriesSelectionWithoutBinding() {
        let selected = AXUIElementCreateApplication(51_001)
        let cases: [(AXError, ApplicationWindowAvailabilityDiagnostic.Reason, Bool)] = [
            (.noValue, .windowsNoValue, true),
            (.attributeUnsupported, .windowsUnsupported, false),
            (.success, .windowsReturnedNoValue, true),
        ]
        for (code, reason, retryable) in cases {
            var reads: [String] = []
            let runtime = SystemApplicationWindowRuntime { _, attribute in
                reads.append(attribute as String)
                switch attribute as String {
                case kAXWindowsAttribute: return (code, nil)
                case kAXFocusedWindowAttribute: return (.success, selected)
                case kAXMainWindowAttribute: return (.noValue, nil)
                default: return (.attributeUnsupported, nil)
                }
            }
            XCTAssertThrowsError(try runtime.elements(processIdentifier: 77)) { error in
                guard let typed = error as? ApplicationWindowReadError,
                      case .windowSelectionUnavailable(let diagnostic) = typed else {
                    return XCTFail("Expected exact missing-window diagnostic")
                }
                XCTAssertEqual(diagnostic.reason, reason)
                XCTAssertEqual(diagnostic.windowsCode, code.rawValue)
                XCTAssertNil(diagnostic.windowCount)
                XCTAssertEqual(diagnostic.focusedCode, AXError.success.rawValue)
                XCTAssertTrue(diagnostic.focusedPresent)
                XCTAssertEqual(diagnostic.mainCode, AXError.noValue.rawValue)
                XCTAssertFalse(diagnostic.mainPresent)
                XCTAssertEqual(typed.permitsInitialReadRetry, retryable)
                XCTAssertTrue(typed.localizedDescription.contains("AXWindows_code=\(code.rawValue)"))
                XCTAssertFalse(typed.localizedDescription.contains("AXTitle"))
                XCTAssertFalse(typed.localizedDescription.contains("AXValue"))
            }
            XCTAssertEqual(reads, [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute])
        }
    }

    @MainActor
    func testRawWindowAttributeWrongTypesNeverFallBackToValidFocusedWindow() {
        let selected = AXUIElementCreateApplication(51_001)
        let malformedValues: [CFTypeRef] = ["private window title" as CFString, ["private window title"] as CFArray]
        for malformed in malformedValues {
            var reads: [String] = []
            let runtime = SystemApplicationWindowRuntime { _, attribute in
                reads.append(attribute as String)
                return attribute as String == kAXWindowsAttribute ? (.success, malformed) : (.success, selected)
            }
            XCTAssertThrowsError(try runtime.elements(processIdentifier: 77)) { error in
                XCTAssertEqual(error as? AutomationError,
                    .unexpectedAttributeType(attribute: kAXWindowsAttribute))
                XCTAssertFalse(error.localizedDescription.contains("private window title"))
            }
            XCTAssertEqual(reads, [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute])
        }
    }

    @MainActor
    func testRawSelectionWrongTypeRemainsAnErrorInsteadOfFallingBack() {
        let selected = AXUIElementCreateApplication(51_001)
        for malformedAttribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            let runtime = SystemApplicationWindowRuntime { _, attribute in
                if attribute as String == kAXWindowsAttribute { return (.success, [selected] as CFArray) }
                if attribute as String == malformedAttribute { return (.success, "private text" as CFString) }
                return (.success, selected)
            }
            XCTAssertThrowsError(try runtime.elements(processIdentifier: 77)) { error in
                XCTAssertEqual(error as? AutomationError, .unexpectedAttributeType(attribute: malformedAttribute))
                XCTAssertFalse(error.localizedDescription.contains("private text"))
            }
        }
    }

    @MainActor
    func testRawAXFailureRetainsOriginalCodeWithoutTreatingItAsMissingWindows() {
        for failedAttribute in [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            let selected = AXUIElementCreateApplication(51_001)
            let runtime = SystemApplicationWindowRuntime { _, attribute in
                if attribute as String == failedAttribute { return (.cannotComplete, nil) }
                if attribute as String == kAXWindowsAttribute { return (.success, [selected] as CFArray) }
                return (.success, selected)
            }
            XCTAssertThrowsError(try runtime.elements(processIdentifier: 77)) {
                XCTAssertEqual($0 as? AutomationError,
                    .accessibilityFailure(operation: "read app-bound \(failedAttribute)", code: AXError.cannotComplete.rawValue))
            }
        }
    }

    @MainActor
    func testRawEmptyWindowListDiagnosticPreservesSelectionStatuses() throws {
        let runtime = SystemApplicationWindowRuntime { _, attribute in
            switch attribute as String {
            case kAXWindowsAttribute: return (.success, [] as CFArray)
            case kAXFocusedWindowAttribute: return (.noValue, nil)
            default: return (.attributeUnsupported, nil)
            }
        }
        let elements = try runtime.elements(processIdentifier: 77)
        XCTAssertTrue(elements.windows.isEmpty)
        XCTAssertNil(elements.focusedWindow)
        XCTAssertNil(elements.mainWindow)
        let selection = FakeApplicationWindowRuntime()
        selection.windows = elements.windows
        selection.focused = elements.focusedWindow
        selection.main = elements.mainWindow
        selection.availabilityCodes = elements.availabilityCodes
        XCTAssertThrowsError(try selection.observation()) { error in
            guard let typed = error as? ApplicationWindowReadError,
                  case .windowSelectionUnavailable(let diagnostic) = typed else {
                return XCTFail("Expected an empty-list diagnostic")
            }
            XCTAssertEqual(diagnostic.reason, .noSelectedWindow)
            XCTAssertEqual(diagnostic.windowsCode, AXError.success.rawValue)
            XCTAssertEqual(diagnostic.windowCount, 0)
            XCTAssertEqual(diagnostic.focusedCode, AXError.noValue.rawValue)
            XCTAssertEqual(diagnostic.mainCode, AXError.attributeUnsupported.rawValue)
            XCTAssertFalse(diagnostic.focusedPresent)
            XCTAssertFalse(diagnostic.mainPresent)
            XCTAssertTrue(typed.permitsInitialReadRetry)
        }
    }

    @MainActor
    func testRawValidSelectionPreservesTheExactWindowAndStrictList() throws {
        let first = AXUIElementCreateApplication(51_001)
        let second = AXUIElementCreateApplication(51_002)
        let runtime = SystemApplicationWindowRuntime { _, attribute in
            switch attribute as String {
            case kAXWindowsAttribute: return (.success, [first] as CFArray)
            case kAXFocusedWindowAttribute: return (.success, second)
            default: return (.noValue, nil)
            }
        }
        let elements = try runtime.elements(processIdentifier: 77)
        XCTAssertEqual(elements.windows.count, 1)
        XCTAssertTrue(CFEqual(elements.windows[0], first))
        XCTAssertTrue(CFEqual(try XCTUnwrap(elements.focusedWindow), second))
        let selection = FakeApplicationWindowRuntime()
        selection.windows = elements.windows
        selection.focused = elements.focusedWindow
        selection.main = elements.mainWindow
        selection.availabilityCodes = elements.availabilityCodes
        XCTAssertThrowsError(try selection.observation()) {
            XCTAssertEqual($0 as? ApplicationWindowReadError, .windowOwnershipMismatch)
        }
    }

    func testOnlyInitialWindowAvailabilityErrorsPermitBoundedReadRetry() {
        XCTAssertTrue(ApplicationWindowReadError.windowUnavailable.permitsInitialReadRetry)
        for error in [ApplicationWindowReadError.applicationUnavailable, .applicationMismatch,
                      .applicationIdentityUnavailable, .ambiguousWindows(2), .windowOwnershipMismatch,
                      .invalidWindowRole, .observationChanged, .invalidTarget] {
            XCTAssertFalse(error.permitsInitialReadRetry)
        }
    }
}

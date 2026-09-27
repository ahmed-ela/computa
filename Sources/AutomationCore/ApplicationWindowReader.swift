import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum ApplicationWindowSelectionSource: String, Sendable {
    case focusedWindow
    case mainWindow
    case onlyWindow
}

/// Structural AX availability only. Never contains window titles, text, or
/// attributes from the contents of a personal application.
public struct ApplicationWindowAvailabilityDiagnostic: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case windowsNoValue = "windows_no_value"
        case windowsUnsupported = "windows_unsupported"
        case windowsReturnedNoValue = "windows_success_without_value"
        case noSelectedWindow = "empty_windows_without_selection"
    }

    public let reason: Reason
    public let windowsCode: Int32?
    public let windowCount: Int?
    public let focusedCode: Int32?
    public let focusedPresent: Bool
    public let mainCode: Int32?
    public let mainPresent: Bool

    var summary: String {
        func value(_ number: Int32?) -> String { number.map(String.init) ?? "unknown" }
        return "reason=\(reason.rawValue); AXWindows_code=\(value(windowsCode)); "
            + "window_count=\(windowCount.map(String.init) ?? "unknown"); "
            + "focused_code=\(value(focusedCode)); focused_present=\(focusedPresent); "
            + "main_code=\(value(mainCode)); main_present=\(mainPresent)"
    }
}

public enum ApplicationWindowReadError: Error, Equatable, LocalizedError, Sendable {
    case invalidTarget
    case applicationUnavailable
    case applicationIdentityUnavailable
    case applicationMismatch
    case windowUnavailable
    case windowSelectionUnavailable(ApplicationWindowAvailabilityDiagnostic)
    case ambiguousWindows(Int)
    case windowOwnershipMismatch
    case invalidWindowRole
    case observationChanged

    public var errorDescription: String? {
        switch self {
        case .invalidTarget: "An exact running application PID and bundle identifier are required."
        case .applicationUnavailable: "The selected application is no longer available."
        case .applicationIdentityUnavailable: "The selected application's launch identity cannot be verified."
        case .applicationMismatch: "The running application does not match the selected target."
        case .windowUnavailable: "The selected application has no verifiable selected window."
        case let .windowSelectionUnavailable(diagnostic):
            "The selected application has no verifiable selected window (\(diagnostic.summary)). No activation or input was sent."
        case let .ambiguousWindows(count): "The selected application's window is ambiguous (\(count) windows)."
        case .windowOwnershipMismatch: "The selected window does not belong to the exact application window list."
        case .invalidWindowRole: "The selected Accessibility element is not a window."
        case .observationChanged: "The application or selected window changed during observation."
        }
    }

    /// Applies only to bounded initial discovery, never input replay or a
    /// retained binding's revalidation. Unsupported attributes are not transient.
    public var permitsInitialReadRetry: Bool {
        switch self {
        case .windowUnavailable: true
        case .windowSelectionUnavailable(let diagnostic): diagnostic.reason != .windowsUnsupported
        default: false
        }
    }
}

/// A read-only observation of an exact application's selected window. It says
/// nothing about OS foreground focus and never authorizes global HID input.
public struct ApplicationWindowObservation: Sendable {
    public let info: FocusedWindowInfo
    public let identity: ApplicationWindowIdentity
    public let selectionSource: ApplicationWindowSelectionSource
}

/// Opaque app/window identity, separate from the global FocusedWindowIdentity.
/// AX references and their provider are accessed exclusively on the main actor.
public final class ApplicationWindowIdentity: @unchecked Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String

    private let launchDate: Date
    private let window: AXUIElement
    private let currentSelection: @MainActor () throws -> ApplicationWindowSelection?

    @MainActor
    fileprivate init(
        selection: ApplicationWindowSelection,
        currentSelection: @escaping @MainActor () throws -> ApplicationWindowSelection?
    ) {
        processIdentifier = selection.process.processIdentifier
        bundleIdentifier = selection.process.bundleIdentifier
        launchDate = selection.process.launchDate
        window = selection.window
        self.currentSelection = currentSelection
    }

    /// Rechecks launch identity, app-local selection, membership and AX identity.
    /// OS foreground changes do not affect this check. AX errors, ambiguity and
    /// ownership failures propagate; a replacement process/window returns false.
    @MainActor
    public func isStillSelected() throws -> Bool {
        guard let current = try currentSelection(),
              current.process.processIdentifier == processIdentifier,
              current.process.bundleIdentifier == bundleIdentifier,
              current.process.launchDate == launchDate else { return false }
        return CFEqual(window, current.window)
    }

    /// Identity comparison only, not a fresh validation or input authorization.
    @MainActor
    public func isSameWindow(as other: ApplicationWindowIdentity) -> Bool {
        processIdentifier == other.processIdentifier
            && bundleIdentifier == other.bundleIdentifier
            && launchDate == other.launchDate
            && CFEqual(window, other.window)
    }

    /// Bridge to a separately observed global-focus token. The global token's
    /// original isStillFocused/isSameFocusedUIElement guards remain mandatory
    /// before global mouse/keyboard input; this comparison cannot replace them.
    @MainActor
    public func isSameWindow(as foregroundIdentity: FocusedWindowIdentity) -> Bool {
        foregroundIdentity.representsWindow(processIdentifier: processIdentifier, window: window)
    }

    /// Only AutomationCore may pass the opaque reference to a fixed-root AX
    /// session. Callers must keep validating this identity around operations.
    @MainActor
    func validatedWindowElement() throws -> AXUIElement {
        guard try isStillSelected() else { throw ApplicationWindowReadError.observationChanged }
        return window
    }
}

struct ApplicationWindowProcessState {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let applicationName: String?
    let launchDate: Date?
    let isTerminated: Bool
}

struct ApplicationWindowElements {
    let application: AXUIElement
    let windows: [AXUIElement]
    let focusedWindow: AXUIElement?
    let mainWindow: AXUIElement?
    let availabilityCodes: (windows: Int32, focused: Int32, main: Int32)?

    init(application: AXUIElement, windows: [AXUIElement], focusedWindow: AXUIElement?,
         mainWindow: AXUIElement?,
         availabilityCodes: (windows: Int32, focused: Int32, main: Int32)? = nil) {
        self.application = application
        self.windows = windows
        self.focusedWindow = focusedWindow
        self.mainWindow = mainWindow
        self.availabilityCodes = availabilityCodes
    }
}

struct ApplicationWindowMetadata {
    let title: String?
    let subrole: String?
    let frame: WindowFrame?
}

fileprivate struct ApplicationWindowProcessIdentity: Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let launchDate: Date
}

fileprivate struct ApplicationWindowSelection {
    let process: ApplicationWindowProcessIdentity
    let applicationName: String?
    let window: AXUIElement
    let source: ApplicationWindowSelectionSource
}

@MainActor
protocol ApplicationWindowRuntime {
    func runningApplication(processIdentifier: Int32) throws -> ApplicationWindowProcessState?
    func elements(processIdentifier: Int32) throws -> ApplicationWindowElements
    func processIdentifier(of element: AXUIElement) throws -> Int32
    func role(of window: AXUIElement) throws -> String?
    func metadata(of window: AXUIElement) throws -> ApplicationWindowMetadata
}

@MainActor
public final class ApplicationWindowReader {
    private let accessibilityCheck: () -> Bool
    private let runtime: any ApplicationWindowRuntime

    public init() {
        accessibilityCheck = { AXIsProcessTrusted() }
        runtime = SystemApplicationWindowRuntime()
    }

    init(accessibilityCheck: @escaping () -> Bool, runtime: any ApplicationWindowRuntime) {
        self.accessibilityCheck = accessibilityCheck
        self.runtime = runtime
    }

    /// Observes a running app without activating it. Selection is the app's
    /// AXFocusedWindow, then AXMainWindow, then its sole AXWindows entry. Never
    /// guesses among multiple windows, consults global focus, or asks for TCC.
    public func selectedWindowObservation(
        processIdentifier: Int32,
        expectedBundleIdentifier: String
    ) throws -> ApplicationWindowObservation {
        guard processIdentifier > 0, !expectedBundleIdentifier.isEmpty else {
            throw ApplicationWindowReadError.invalidTarget
        }
        guard let selected = try readSelection(
            processIdentifier: processIdentifier,
            expectedBundleIdentifier: expectedBundleIdentifier
        ) else { throw ApplicationWindowReadError.applicationUnavailable }

        let metadata = try runtime.metadata(of: selected.window)
        // A metadata read may yield to another process even on the main actor.
        // Publish only if this exact process generation/window is still selected.
        guard let confirmed = try readSelection(
            processIdentifier: processIdentifier,
            expectedBundleIdentifier: expectedBundleIdentifier
        ), selected.process == confirmed.process, CFEqual(selected.window, confirmed.window) else {
            throw ApplicationWindowReadError.observationChanged
        }
        let identity = ApplicationWindowIdentity(selection: selected) { [self] in
            try readSelection(processIdentifier: processIdentifier, expectedBundleIdentifier: expectedBundleIdentifier)
        }
        return ApplicationWindowObservation(
            info: FocusedWindowInfo(
                processIdentifier: processIdentifier,
                bundleIdentifier: expectedBundleIdentifier,
                applicationName: selected.applicationName,
                title: metadata.title,
                role: kAXWindowRole as String,
                subrole: metadata.subrole,
                frame: metadata.frame
            ),
            identity: identity,
            selectionSource: selected.source
        )
    }

    private func readSelection(
        processIdentifier: Int32,
        expectedBundleIdentifier: String
    ) throws -> ApplicationWindowSelection? {
        guard accessibilityCheck() else { throw AutomationError.permissionNotGranted(.accessibility) }
        guard let before = try processState(processIdentifier, expectedBundleIdentifier) else { return nil }
        let elements = try runtime.elements(processIdentifier: processIdentifier)
        guard try runtime.processIdentifier(of: elements.application) == processIdentifier else {
            throw ApplicationWindowReadError.applicationMismatch
        }
        for (index, window) in elements.windows.enumerated() {
            guard try runtime.processIdentifier(of: window) == processIdentifier else {
                throw ApplicationWindowReadError.windowOwnershipMismatch
            }
            guard !elements.windows[..<index].contains(where: { CFEqual($0, window) }) else {
                throw ApplicationWindowReadError.ambiguousWindows(elements.windows.count)
            }
        }
        let window: AXUIElement
        let source: ApplicationWindowSelectionSource
        if let focused = elements.focusedWindow {
            window = focused
            source = .focusedWindow
        } else if let main = elements.mainWindow {
            window = main
            source = .mainWindow
        } else {
            guard !elements.windows.isEmpty else {
                throw ApplicationWindowReadError.windowSelectionUnavailable(.init(
                    reason: .noSelectedWindow, windowsCode: elements.availabilityCodes?.windows,
                    windowCount: 0, focusedCode: elements.availabilityCodes?.focused,
                    focusedPresent: false, mainCode: elements.availabilityCodes?.main, mainPresent: false
                ))
            }
            guard elements.windows.count == 1 else {
                throw ApplicationWindowReadError.ambiguousWindows(elements.windows.count)
            }
            window = elements.windows[0]
            source = .onlyWindow
        }
        guard try runtime.processIdentifier(of: window) == processIdentifier,
              elements.windows.contains(where: { CFEqual($0, window) }) else {
            throw ApplicationWindowReadError.windowOwnershipMismatch
        }
        guard try runtime.role(of: window) == kAXWindowRole as String else {
            throw ApplicationWindowReadError.invalidWindowRole
        }
        guard accessibilityCheck() else { throw AutomationError.permissionNotGranted(.accessibility) }
        guard let after = try processState(processIdentifier, expectedBundleIdentifier), before.identity == after.identity else {
            return nil
        }
        return ApplicationWindowSelection(
            process: before.identity, applicationName: before.name, window: window, source: source
        )
    }

    private func processState(
        _ processIdentifier: Int32,
        _ expectedBundleIdentifier: String
    ) throws -> (identity: ApplicationWindowProcessIdentity, name: String?)? {
        guard let state = try runtime.runningApplication(processIdentifier: processIdentifier), !state.isTerminated else {
            return nil
        }
        guard state.processIdentifier == processIdentifier, state.bundleIdentifier == expectedBundleIdentifier else {
            throw ApplicationWindowReadError.applicationMismatch
        }
        guard let launchDate = state.launchDate else { throw ApplicationWindowReadError.applicationIdentityUnavailable }
        return (ApplicationWindowProcessIdentity(
            processIdentifier: processIdentifier,
            bundleIdentifier: expectedBundleIdentifier,
            launchDate: launchDate
        ), state.applicationName)
    }
}

@MainActor
struct SystemApplicationWindowRuntime: ApplicationWindowRuntime {
    typealias AttributeReader = (AXUIElement, CFString) -> (code: AXError, value: CFTypeRef?)
    private let readAttribute: AttributeReader

    init(readAttribute: @escaping AttributeReader = { element, attribute in
        var value: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (code, value)
    }) {
        self.readAttribute = readAttribute
    }

    func runningApplication(processIdentifier: Int32) throws -> ApplicationWindowProcessState? {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return nil }
        return ApplicationWindowProcessState(
            processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
            applicationName: app.localizedName, launchDate: app.launchDate, isTerminated: app.isTerminated
        )
    }

    func elements(processIdentifier: Int32) throws -> ApplicationWindowElements {
        let application = AXUIElementCreateApplication(processIdentifier)
        // Read the three structural selection attributes independently so a
        // missing window list does not hide whether focused/main were exposed.
        // This is diagnostic only: a missing list still cannot bind a window.
        let windowsRead = readAttribute(application, kAXWindowsAttribute as CFString)
        let focusedRead = readAttribute(application, kAXFocusedWindowAttribute as CFString)
        let mainRead = readAttribute(application, kAXMainWindowAttribute as CFString)
        guard let rawWindows = try attributeValue(windowsRead, attribute: kAXWindowsAttribute as CFString) else {
            let reason: ApplicationWindowAvailabilityDiagnostic.Reason
            switch windowsRead.code {
            case .noValue: reason = .windowsNoValue
            case .attributeUnsupported: reason = .windowsUnsupported
            default: reason = .windowsReturnedNoValue
            }
            throw ApplicationWindowReadError.windowSelectionUnavailable(.init(
                reason: reason, windowsCode: windowsRead.code.rawValue, windowCount: nil,
                focusedCode: focusedRead.code.rawValue, focusedPresent: focusedRead.value != nil,
                mainCode: mainRead.code.rawValue, mainPresent: mainRead.value != nil
            ))
        }
        guard CFGetTypeID(rawWindows) == CFArrayGetTypeID(), let values = rawWindows as? [AnyObject] else {
            throw AutomationError.unexpectedAttributeType(attribute: kAXWindowsAttribute as String)
        }
        let windows = try values.map { value -> AXUIElement in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw AutomationError.unexpectedAttributeType(attribute: kAXWindowsAttribute as String)
            }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        return ApplicationWindowElements(
            application: application,
            windows: windows,
            focusedWindow: try elementValue(focusedRead, attribute: kAXFocusedWindowAttribute as CFString),
            mainWindow: try elementValue(mainRead, attribute: kAXMainWindowAttribute as CFString),
            availabilityCodes: (windowsRead.code.rawValue, focusedRead.code.rawValue, mainRead.code.rawValue)
        )
    }

    func processIdentifier(of element: AXUIElement) throws -> Int32 {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success else {
            throw AutomationError.accessibilityFailure(operation: "read app-bound AX element PID", code: result.rawValue)
        }
        return pid
    }

    func role(of window: AXUIElement) throws -> String? {
        try copyString(kAXRoleAttribute as CFString, from: window)
    }

    func metadata(of window: AXUIElement) throws -> ApplicationWindowMetadata {
        let rawPosition = try copyAttribute(kAXPositionAttribute as CFString, from: window)
        let rawSize = try copyAttribute(kAXSizeAttribute as CFString, from: window)
        if let rawPosition {
            guard CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                  AXValueGetType(unsafeDowncast(rawPosition, to: AXValue.self)) == .cgPoint else {
                throw AutomationError.unexpectedAttributeType(attribute: kAXPositionAttribute as String)
            }
        }
        if let rawSize {
            guard CFGetTypeID(rawSize) == AXValueGetTypeID(),
                  AXValueGetType(unsafeDowncast(rawSize, to: AXValue.self)) == .cgSize else {
                throw AutomationError.unexpectedAttributeType(attribute: kAXSizeAttribute as String)
            }
        }
        var frame: WindowFrame?
        if let rawPosition, let rawSize {
            guard CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else {
                throw AutomationError.unexpectedAttributeType(attribute: "app-bound window geometry")
            }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else {
                throw AutomationError.unexpectedAttributeType(attribute: "app-bound window geometry")
            }
            frame = WindowFrame(x: point.x, y: point.y, width: size.width, height: size.height)
        }
        return ApplicationWindowMetadata(
            title: try copyString(kAXTitleAttribute as CFString, from: window),
            subrole: try copyString(kAXSubroleAttribute as CFString, from: window), frame: frame
        )
    }

    private func elementValue(_ result: (code: AXError, value: CFTypeRef?), attribute: CFString) throws -> AXUIElement? {
        guard let value = try attributeValue(result, attribute: attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyString(_ attribute: CFString, from element: AXUIElement) throws -> String? {
        guard let value = try copyAttribute(attribute, from: element) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        return value as? String
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) throws -> CFTypeRef? {
        try attributeValue(readAttribute(element, attribute), attribute: attribute)
    }

    private func attributeValue(_ result: (code: AXError, value: CFTypeRef?), attribute: CFString) throws -> CFTypeRef? {
        switch result.code {
        case .success: return result.value
        case .noValue, .attributeUnsupported: return nil
        default: throw AutomationError.accessibilityFailure(operation: "read app-bound \(attribute)", code: result.code.rawValue)
        }
    }
}

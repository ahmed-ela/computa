import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct WindowFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct FocusedWindowInfo: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let applicationName: String?
    public let title: String?
    public let role: String?
    public let subrole: String?
    public let frame: WindowFrame?

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        applicationName: String?,
        title: String?,
        role: String?,
        subrole: String?,
        frame: WindowFrame?
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
    }
}

/// The window metadata and its AX identity are captured from the same focused
/// application/window lookup, so the identity cannot accidentally describe a
/// different window than `info`.
public struct FocusedWindowObservation: Sendable {
    public let info: FocusedWindowInfo
    public let identity: FocusedWindowIdentity
}

/// An opaque handle for comparing the actual focused AX window across an
/// asynchronous approval or screenshot capture. AX window metadata alone is
/// not an identity: a replacement window can have the same PID, title, and
/// frame. The element is only inspected on the main actor.
public final class FocusedWindowIdentity: @unchecked Sendable {
    public let processIdentifier: Int32

    private let window: AXUIElement
    private let focusedUIElement: AXUIElement?
    private let currentFocusedElements: @MainActor () throws -> FocusedWindowElements?

    @MainActor
    fileprivate init(
        processIdentifier: Int32,
        window: AXUIElement,
        focusedUIElement: AXUIElement?,
        currentFocusedElements: @escaping @MainActor () throws -> FocusedWindowElements?
    ) {
        self.processIdentifier = processIdentifier
        self.window = window
        self.focusedUIElement = focusedUIElement
        self.currentFocusedElements = currentFocusedElements
    }

    /// Returns false when focus is absent, moves to another process, or moves
    /// to a different AX window, even if its visible metadata is unchanged.
    /// AX read failures and revoked permission are propagated to fail closed.
    @MainActor
    public func isStillFocused() throws -> Bool {
        guard let current = try currentFocusedElements(),
              current.processIdentifier == processIdentifier else {
            return false
        }
        return CFEqual(window, current.window)
    }

    /// Keyboard input requires the exact focused AX control observed with the
    /// window. A missing control or a focus change fails closed.
    @MainActor
    public func isSameFocusedUIElement() throws -> Bool {
        guard let focusedUIElement,
              let current = try currentFocusedElements(),
              current.processIdentifier == processIdentifier,
              CFEqual(window, current.window),
              let currentFocusedUIElement = current.focusedUIElement else {
            return false
        }
        return CFEqual(focusedUIElement, currentFocusedUIElement)
    }

    /// Internal identity bridge only. This does not validate current global
    /// focus; callers must still use the unchanged input guards above.
    @MainActor
    func representsWindow(processIdentifier: Int32, window: AXUIElement) -> Bool {
        self.processIdentifier == processIdentifier && CFEqual(self.window, window)
    }
}

struct FocusedWindowElements {
    let processIdentifier: Int32
    let window: AXUIElement
    let focusedUIElement: AXUIElement?

    init(
        processIdentifier: Int32,
        window: AXUIElement,
        focusedUIElement: AXUIElement? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.window = window
        self.focusedUIElement = focusedUIElement
    }
}

@MainActor
public final class FocusedWindowReader {
    private let accessibilityCheck: () -> Bool
    private let focusedElements: () throws -> FocusedWindowElements?

    public init() {
        accessibilityCheck = { AXIsProcessTrusted() }
        focusedElements = { try Self.systemFocusedElements() }
    }

    init(accessibilityCheck: @escaping () -> Bool) {
        self.accessibilityCheck = accessibilityCheck
        focusedElements = { try Self.systemFocusedElements() }
    }

    init(
        accessibilityCheck: @escaping () -> Bool,
        focusedElements: @escaping () throws -> FocusedWindowElements?
    ) {
        self.accessibilityCheck = accessibilityCheck
        self.focusedElements = focusedElements
    }

    /// Returns metadata for the focused window, or `nil` when no application or
    /// window is focused. This method never asks macOS to grant Accessibility.
    public func focusedWindow() throws -> FocusedWindowInfo? {
        try focusedWindowObservation()?.info
    }

    /// Returns a focused-window identity together with the metadata observed
    /// from that very window. Retain the token through approval, then call
    /// `isStillFocused()` immediately before posting input.
    public func focusedWindowObservation() throws -> FocusedWindowObservation? {
        guard let elements = try readFocusedElements() else {
            return nil
        }

        let window = elements.window
        let processIdentifier = elements.processIdentifier
        let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
        let position = try copyPoint(attribute: kAXPositionAttribute as CFString, from: window)
        let size = try copySize(attribute: kAXSizeAttribute as CFString, from: window)
        let frame: WindowFrame?
        if let position, let size {
            frame = WindowFrame(
                x: position.x,
                y: position.y,
                width: size.width,
                height: size.height
            )
        } else {
            frame = nil
        }

        let info = FocusedWindowInfo(
            processIdentifier: processIdentifier,
            bundleIdentifier: runningApplication?.bundleIdentifier,
            applicationName: runningApplication?.localizedName,
            title: try copyString(attribute: kAXTitleAttribute as CFString, from: window),
            role: try copyString(attribute: kAXRoleAttribute as CFString, from: window),
            subrole: try copyString(attribute: kAXSubroleAttribute as CFString, from: window),
            frame: frame
        )
        return FocusedWindowObservation(
            info: info,
            identity: makeIdentity(for: elements)
        )
    }

    /// Captures only the opaque window identity when metadata is unnecessary.
    /// This still checks Accessibility permission and focused-window ownership.
    public func focusedWindowIdentity() throws -> FocusedWindowIdentity? {
        guard let elements = try readFocusedElements() else {
            return nil
        }
        return makeIdentity(for: elements)
    }

    private func makeIdentity(for elements: FocusedWindowElements) -> FocusedWindowIdentity {
        FocusedWindowIdentity(
            processIdentifier: elements.processIdentifier,
            window: elements.window,
            focusedUIElement: elements.focusedUIElement,
            currentFocusedElements: { [self] in try readFocusedElements() }
        )
    }

    private func readFocusedElements() throws -> FocusedWindowElements? {
        guard accessibilityCheck() else {
            throw AutomationError.permissionNotGranted(.accessibility)
        }
        return try focusedElements()
    }

    private static func systemFocusedElements() throws -> FocusedWindowElements? {
        let systemWide = AXUIElementCreateSystemWide()
        let application: AXUIElement
        var fallbackProcessIdentifier: pid_t?
        do {
            guard let focusedApplication = try copyElement(
                attribute: kAXFocusedApplicationAttribute as CFString,
                from: systemWide
            ) else {
                return nil
            }
            application = focusedApplication
        } catch AutomationError.accessibilityFailure(_, let code)
            where code == AXError.cannotComplete.rawValue {
            // On this macOS build the system-wide focused-application query
            // can return cannotComplete even when AX access is granted and
            // the target application's focused-window query succeeds. Use
            // AppKit's frontmost process as a narrowly checked fallback.
            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.isActive else {
                return nil
            }
            fallbackProcessIdentifier = frontmost.processIdentifier
            application = AXUIElementCreateApplication(frontmost.processIdentifier)
        }
        guard let window = try copyElement(
            attribute: kAXFocusedWindowAttribute as CFString,
            from: application
        ) else {
            return nil
        }

        var applicationPID: pid_t = 0
        try requireSuccess(
            AXUIElementGetPid(application, &applicationPID),
            operation: "read focused application PID"
        )
        var windowPID: pid_t = 0
        try requireSuccess(
            AXUIElementGetPid(window, &windowPID),
            operation: "read focused window PID"
        )
        guard applicationPID > 0, windowPID == applicationPID else {
            return nil
        }
        if let fallbackProcessIdentifier {
            guard applicationPID == fallbackProcessIdentifier,
                  let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.isActive,
                  frontmost.processIdentifier == fallbackProcessIdentifier else {
                return nil
            }
        }
        // A failed or unsupported focused-control query is represented as nil.
        // Window-only actions can continue, while keyboard input must reject it.
        let focusedUIElement = try? copyElement(
            attribute: kAXFocusedUIElementAttribute as CFString,
            from: application
        )
        var focusedPID: pid_t = 0
        let verifiedFocusedUIElement: AXUIElement?
        if let focusedUIElement,
           AXUIElementGetPid(focusedUIElement, &focusedPID) == .success,
           focusedPID == applicationPID {
            verifiedFocusedUIElement = focusedUIElement
        } else {
            verifiedFocusedUIElement = nil
        }
        return FocusedWindowElements(
            processIdentifier: applicationPID,
            window: window,
            focusedUIElement: verifiedFocusedUIElement
        )
    }

    private static func copyElement(attribute: CFString, from element: AXUIElement) throws -> AXUIElement? {
        guard let value = try Self.copyAttribute(attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyString(attribute: CFString, from element: AXUIElement) throws -> String? {
        guard let value = try Self.copyAttribute(attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        return value as? String
    }

    private func copyPoint(attribute: CFString, from element: AXUIElement) throws -> CGPoint? {
        guard let value = try Self.copyAttribute(attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        return point
    }

    private func copySize(attribute: CFString, from element: AXUIElement) throws -> CGSize? {
        guard let value = try Self.copyAttribute(attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        return size
    }

    private static func copyAttribute(_ attribute: CFString, from element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch result {
        case .success:
            return value
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw AutomationError.accessibilityFailure(
                operation: "read \(attribute)",
                code: result.rawValue
            )
        }
    }

    private static func requireSuccess(_ result: AXError, operation: String) throws {
        guard result == .success else {
            throw AutomationError.accessibilityFailure(operation: operation, code: result.rawValue)
        }
    }
}

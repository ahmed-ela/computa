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

@MainActor
public final class FocusedWindowReader {
    private let accessibilityCheck: () -> Bool

    public init() {
        accessibilityCheck = { AXIsProcessTrusted() }
    }

    init(accessibilityCheck: @escaping () -> Bool) {
        self.accessibilityCheck = accessibilityCheck
    }

    /// Returns metadata for the focused window, or `nil` when no application or
    /// window is focused. This method never asks macOS to grant Accessibility.
    public func focusedWindow() throws -> FocusedWindowInfo? {
        guard accessibilityCheck() else {
            throw AutomationError.permissionNotGranted(.accessibility)
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let application = try copyElement(
            attribute: kAXFocusedApplicationAttribute as CFString,
            from: systemWide
        ) else {
            return nil
        }
        guard let window = try copyElement(
            attribute: kAXFocusedWindowAttribute as CFString,
            from: application
        ) else {
            return nil
        }

        var processIdentifier: pid_t = 0
        let pidResult = AXUIElementGetPid(application, &processIdentifier)
        try requireSuccess(pidResult, operation: "read focused application PID")

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

        return FocusedWindowInfo(
            processIdentifier: processIdentifier,
            bundleIdentifier: runningApplication?.bundleIdentifier,
            applicationName: runningApplication?.localizedName,
            title: try copyString(attribute: kAXTitleAttribute as CFString, from: window),
            role: try copyString(attribute: kAXRoleAttribute as CFString, from: window),
            subrole: try copyString(attribute: kAXSubroleAttribute as CFString, from: window),
            frame: frame
        )
    }

    private func copyElement(attribute: CFString, from element: AXUIElement) throws -> AXUIElement? {
        guard let value = try copyAttribute(attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyString(attribute: CFString, from element: AXUIElement) throws -> String? {
        guard let value = try copyAttribute(attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: attribute as String)
        }
        return value as? String
    }

    private func copyPoint(attribute: CFString, from element: AXUIElement) throws -> CGPoint? {
        guard let value = try copyAttribute(attribute, from: element) else {
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
        guard let value = try copyAttribute(attribute, from: element) else {
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

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) throws -> CFTypeRef? {
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

    private func requireSuccess(_ result: AXError, operation: String) throws {
        guard result == .success else {
            throw AutomationError.accessibilityFailure(operation: operation, code: result.rawValue)
        }
    }
}

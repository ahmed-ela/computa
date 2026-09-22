import ApplicationServices
import CoreFoundation
import Foundation

public enum SemanticAXAction: String, CaseIterable, Codable, Sendable {
    case press = "AXPress"
    case increment = "AXIncrement"
    case decrement = "AXDecrement"
    case showMenu = "AXShowMenu"
    case confirm = "AXConfirm"
    case cancel = "AXCancel"
    case pick = "AXPick"
    case raise = "AXRaise"
}

protocol AXRuntime {
    func actionNames(for element: AXUIElement) throws -> [String]
    func perform(action: String, on element: AXUIElement) throws
    func isAttributeSettable(_ attribute: String, on element: AXUIElement) throws -> Bool
    func set(value: CFTypeRef, for attribute: String, on element: AXUIElement) throws
}

struct SystemAXRuntime: AXRuntime {
    func actionNames(for element: AXUIElement) throws -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        try requireSuccess(result, operation: "list supported actions")
        return names as? [String] ?? []
    }

    func perform(action: String, on element: AXUIElement) throws {
        let result = AXUIElementPerformAction(element, action as CFString)
        try requireSuccess(result, operation: "perform \(action)")
    }

    func isAttributeSettable(_ attribute: String, on element: AXUIElement) throws -> Bool {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable)
        try requireSuccess(result, operation: "check whether \(attribute) is settable")
        return isSettable.boolValue
    }

    func set(value: CFTypeRef, for attribute: String, on element: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        try requireSuccess(result, operation: "set \(attribute)")
    }

    private func requireSuccess(_ result: AXError, operation: String) throws {
        guard result == .success else {
            throw AutomationError.accessibilityFailure(operation: operation, code: result.rawValue)
        }
    }
}

/// Explicit, element-scoped Accessibility mutations.
///
/// This type never locates an element on its own and never prompts for TCC
/// access. The caller must supply an `AXUIElement` obtained through a separate,
/// user-authorized inspection flow.
public final class AXElementController {
    private let runtime: any AXRuntime
    private let accessibilityCheck: () -> Bool

    public init() {
        runtime = SystemAXRuntime()
        accessibilityCheck = { AXIsProcessTrusted() }
    }

    init(runtime: any AXRuntime, accessibilityCheck: @escaping () -> Bool) {
        self.runtime = runtime
        self.accessibilityCheck = accessibilityCheck
    }

    public func supportedActions(on element: AXUIElement) throws -> [String] {
        try requirePermission()
        return try runtime.actionNames(for: element)
    }

    public func perform(_ action: SemanticAXAction, on element: AXUIElement) throws {
        try requirePermission()
        let supported = try runtime.actionNames(for: element)
        guard supported.contains(action.rawValue) else {
            throw AutomationError.unsupportedAction(action.rawValue)
        }
        try runtime.perform(action: action.rawValue, on: element)
    }

    public func setValue(_ value: String, on element: AXUIElement) throws {
        try setRawValue(value as CFString, on: element)
    }

    public func setBooleanValue(_ value: Bool, on element: AXUIElement) throws {
        try setRawValue(value as CFBoolean, on: element)
    }

    public func setNumberValue(_ value: Double, on element: AXUIElement) throws {
        try setRawValue(value as CFNumber, on: element)
    }

    public func setRawValue(_ value: CFTypeRef, on element: AXUIElement) throws {
        try requirePermission()
        let attribute = kAXValueAttribute as String
        guard try runtime.isAttributeSettable(attribute, on: element) else {
            throw AutomationError.attributeNotSettable(attribute)
        }
        try runtime.set(value: value, for: attribute, on: element)
    }

    private func requirePermission() throws {
        guard accessibilityCheck() else {
            throw AutomationError.permissionNotGranted(.accessibility)
        }
    }
}

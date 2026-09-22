import Foundation

public enum AutomationPermission: String, Codable, Sendable {
    case accessibility
    case screenRecording = "screen-recording"
}

public enum AutomationError: Error, Equatable, LocalizedError, Sendable {
    case permissionNotGranted(AutomationPermission)
    case accessibilityFailure(operation: String, code: Int32)
    case unsupportedAction(String)
    case attributeNotSettable(String)
    case unexpectedAttributeType(attribute: String)
    case windowNotFound(UInt32)
    case invalidScaleFactor(Double)
    case invalidAccessibilityTreeLimit(name: String, value: Int)
    case staleAccessibilitySnapshot
    case accessibilityElementIndexNotFound(Int)
    case accessibilityValueTooLong(maximum: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .permissionNotGranted(permission):
            return "The \(permission.rawValue) permission is not granted."
        case let .accessibilityFailure(operation, code):
            return "Accessibility operation '\(operation)' failed with AXError code \(code)."
        case let .unsupportedAction(action):
            return "The accessibility element does not support action '\(action)'."
        case let .attributeNotSettable(attribute):
            return "Accessibility attribute '\(attribute)' is not settable."
        case let .unexpectedAttributeType(attribute):
            return "Accessibility attribute '\(attribute)' had an unexpected value type."
        case let .windowNotFound(windowID):
            return "No ScreenCaptureKit window was found for CGWindowID \(windowID)."
        case let .invalidScaleFactor(scale):
            return "Screenshot scale factor must be finite and greater than zero; received \(scale)."
        case let .invalidAccessibilityTreeLimit(name, value):
            return "Accessibility tree limit '\(name)' has an invalid value: \(value)."
        case .staleAccessibilitySnapshot:
            return "The Accessibility snapshot is stale. Capture a fresh snapshot before acting."
        case let .accessibilityElementIndexNotFound(index):
            return "Accessibility element index \(index) does not exist in this snapshot."
        case let .accessibilityValueTooLong(maximum, actual):
            return "Accessibility value contains \(actual) characters; the snapshot limit is \(maximum)."
        }
    }
}

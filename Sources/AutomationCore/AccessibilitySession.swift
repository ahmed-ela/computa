import ApplicationServices
import CoreFoundation
import CryptoKit
import Foundation

public struct AccessibilityApplicationTarget: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let applicationName: String?

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String? = nil,
        applicationName: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }

    public init(application: RunningApplicationInfo) {
        self.init(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        )
    }
}

public struct AccessibilityTreeLimits: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case maxDepth
        case maxElements
        case maxChildrenPerElement
        case maxActionsPerElement
        case maxTextLength
    }

    public static let agentDefault = AccessibilityTreeLimits(
        // Chromium exposes document controls below a relatively deep chain of
        // window, toolbar, web-area, and landmark groups. A depth of eight
        // reaches the web area but can stop immediately before its controls.
        // The element cap still bounds traversal cost for unusually deep apps.
        validatedMaxDepth: 16,
        maxElements: 400,
        maxChildrenPerElement: 80,
        maxActionsPerElement: 32,
        maxTextLength: 1_024
    )

    public let maxDepth: Int
    public let maxElements: Int
    public let maxChildrenPerElement: Int
    public let maxActionsPerElement: Int
    public let maxTextLength: Int

    public init(
        maxDepth: Int = 8,
        maxElements: Int = 400,
        maxChildrenPerElement: Int = 80,
        maxActionsPerElement: Int = 32,
        maxTextLength: Int = 1_024
    ) throws {
        guard (0 ... 32).contains(maxDepth) else {
            throw AutomationError.invalidAccessibilityTreeLimit(name: "maxDepth", value: maxDepth)
        }
        guard (1 ... 2_000).contains(maxElements) else {
            throw AutomationError.invalidAccessibilityTreeLimit(name: "maxElements", value: maxElements)
        }
        guard (1 ... 500).contains(maxChildrenPerElement) else {
            throw AutomationError.invalidAccessibilityTreeLimit(
                name: "maxChildrenPerElement",
                value: maxChildrenPerElement
            )
        }
        guard (1 ... 128).contains(maxActionsPerElement) else {
            throw AutomationError.invalidAccessibilityTreeLimit(
                name: "maxActionsPerElement",
                value: maxActionsPerElement
            )
        }
        guard (1 ... 4_096).contains(maxTextLength) else {
            throw AutomationError.invalidAccessibilityTreeLimit(name: "maxTextLength", value: maxTextLength)
        }

        self.init(
            validatedMaxDepth: maxDepth,
            maxElements: maxElements,
            maxChildrenPerElement: maxChildrenPerElement,
            maxActionsPerElement: maxActionsPerElement,
            maxTextLength: maxTextLength
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxDepth: container.decode(Int.self, forKey: .maxDepth),
            maxElements: container.decode(Int.self, forKey: .maxElements),
            maxChildrenPerElement: container.decode(Int.self, forKey: .maxChildrenPerElement),
            maxActionsPerElement: container.decode(Int.self, forKey: .maxActionsPerElement),
            maxTextLength: container.decode(Int.self, forKey: .maxTextLength)
        )
    }

    private init(
        validatedMaxDepth: Int,
        maxElements: Int,
        maxChildrenPerElement: Int,
        maxActionsPerElement: Int,
        maxTextLength: Int
    ) {
        maxDepth = validatedMaxDepth
        self.maxElements = maxElements
        self.maxChildrenPerElement = maxChildrenPerElement
        self.maxActionsPerElement = maxActionsPerElement
        self.maxTextLength = maxTextLength
    }
}

public enum AccessibilitySetValue: Codable, Equatable, Sendable {
    case text(String)
    case boolean(Bool)
    case number(Double)
}

public enum AccessibilitySnapshotFocusState: Equatable, Sendable {
    case notWindow
    case applicationNotFocused
    case windowNotFocused
    case focused
}

/// Local approval identity for destinations that may not be safe to display.
/// Never serialized into model-facing snapshot text or used for navigation.
public enum AccessibilityLinkDestinationIdentity: Codable, Equatable, Sendable {
    case sha256(String)
    case unverifiable
}

public struct AccessibilityTreeElement: Codable, Equatable, Sendable {
    public let index: Int
    public let parentIndex: Int?
    public let childIndices: [Int]
    public let depth: Int
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let elementDescription: String?
    public let help: String?
    public let identifier: String?
    public let domIdentifier: String?
    public let value: String?
    public let frame: WindowFrame?
    public let isEnabled: Bool?
    public let isFocused: Bool?
    public let supportedActions: [String]
    public let isValueSettable: Bool
    /// Exact observed destination, never a truncated or inferred URL.
    public let url: String?
    public let urlIdentity: AccessibilityLinkDestinationIdentity?
    public let isSelected: Bool?
    /// Host-only identity for the exact retained AX object in one session.
    /// It is not an element address and is omitted from model-facing text.
    public let evidenceIdentity: UUID?
    public let evidenceFieldsTruncated: Bool?

    init(
        index: Int,
        parentIndex: Int?,
        childIndices: [Int],
        depth: Int,
        role: String?,
        subrole: String?,
        title: String?,
        elementDescription: String?,
        help: String?,
        identifier: String?,
        domIdentifier: String?,
        value: String?,
        frame: WindowFrame?,
        isEnabled: Bool?,
        isFocused: Bool?,
        supportedActions: [String],
        isValueSettable: Bool,
        url: String? = nil,
        urlIdentity: AccessibilityLinkDestinationIdentity? = nil,
        isSelected: Bool? = nil,
        evidenceIdentity: UUID? = nil,
        evidenceFieldsTruncated: Bool? = nil
    ) {
        self.index = index
        self.parentIndex = parentIndex
        self.childIndices = childIndices
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.title = title
        self.elementDescription = elementDescription
        self.help = help
        self.identifier = identifier
        self.domIdentifier = domIdentifier
        self.value = value
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.supportedActions = supportedActions
        self.isValueSettable = isValueSettable
        self.url = url
        self.urlIdentity = urlIdentity
        self.isSelected = isSelected
        self.evidenceIdentity = evidenceIdentity
        self.evidenceFieldsTruncated = evidenceFieldsTruncated
    }
}

public struct AccessibilityTreeSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let application: AccessibilityApplicationTarget
    public let limits: AccessibilityTreeLimits
    public let rootIndex: Int?
    public let elements: [AccessibilityTreeElement]
    public let wasTruncated: Bool

    init(
        id: UUID,
        application: AccessibilityApplicationTarget,
        limits: AccessibilityTreeLimits,
        rootIndex: Int?,
        elements: [AccessibilityTreeElement],
        wasTruncated: Bool
    ) {
        self.id = id
        self.application = application
        self.limits = limits
        self.rootIndex = rootIndex
        self.elements = elements
        self.wasTruncated = wasTruncated
    }

    public func element(at index: Int) -> AccessibilityTreeElement? {
        guard elements.indices.contains(index), elements[index].index == index else {
            return nil
        }
        return elements[index]
    }
}

final class AccessibilityElementHandle {
    let storage: AnyObject

    init(_ storage: AnyObject) {
        self.storage = storage
    }
}

struct AccessibilityElementDescription {
    let role: String?
    let subrole: String?
    let title: String?
    let elementDescription: String?
    let help: String?
    let identifier: String?
    let domIdentifier: String?
    let value: String?
    let frame: WindowFrame?
    let isEnabled: Bool?
    let isFocused: Bool?
    let supportedActions: [String]
    let isValueSettable: Bool
    let wasTruncated: Bool
    var url: String? = nil
    var urlIdentity: AccessibilityLinkDestinationIdentity? = nil
    var isSelected: Bool? = nil
}

/// AXURL is observation data, not permission to navigate. Unsupported or
/// oversized destinations are omitted whole rather than made actionable by
/// truncating, repairing, resolving, or otherwise changing their spelling.
enum AccessibilityObservedLinkURL {
    static let maximumBytes = 2_048
    static let maximumIdentityBytes = 8_192

    static func validate(_ raw: AnyObject?) -> (value: String?, wasTruncated: Bool, identity: AccessibilityLinkDestinationIdentity?) {
        guard let raw else { return (nil, false, nil) }
        let rawText: CFString?
        if CFGetTypeID(raw) == CFURLGetTypeID() {
            rawText = CFURLGetString(unsafeDowncast(raw, to: CFURL.self))
        } else if CFGetTypeID(raw) == CFStringGetTypeID() {
            rawText = unsafeDowncast(raw, to: CFString.self)
        } else {
            rawText = nil
        }
        // Check UTF-16 length before bridging, then collect only a bounded UTF-8
        // prefix. Never allocate Data for an unbounded destination merely to hash it.
        guard let rawText, CFStringGetLength(rawText) <= maximumIdentityBytes else {
            return (nil, true, .unverifiable)
        }
        let text = rawText as String
        let bytes = Array(text.utf8.prefix(maximumIdentityBytes + 1))
        guard bytes.count <= maximumIdentityBytes else { return (nil, true, .unverifiable) }
        let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        let identity = AccessibilityLinkDestinationIdentity.sha256(digest)
        guard let value = validated(text) else { return (nil, true, identity) }
        return (value, false, identity)
    }

    static func validated(_ text: String?, maximumBytes: Int = AccessibilityObservedLinkURL.maximumBytes) -> String? {
        guard let text, !text.isEmpty, maximumBytes > 0,
              text.utf8.count <= min(maximumBytes, Self.maximumBytes),
              !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let decoded = text.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parsed = URL(string: text, encodingInvalidCharacters: false),
              let components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            return nil
        }
        return text
    }
}

struct AccessibilityChildBatch {
    let elements: [AccessibilityElementHandle]
    let wasTruncated: Bool
}

protocol AccessibilityTreeRuntime {
    func applicationElement(processIdentifier: Int32) throws -> AccessibilityElementHandle
    func applicationIsFrontmost(processIdentifier: Int32) throws -> Bool
    func focusedWindow(processIdentifier: Int32) throws -> AccessibilityElementHandle?
    func describe(
        _ element: AccessibilityElementHandle,
        limits: AccessibilityTreeLimits
    ) throws -> AccessibilityElementDescription
    func children(
        of element: AccessibilityElementHandle,
        limit: Int
    ) throws -> AccessibilityChildBatch
    func children(of element: AccessibilityElementHandle, offset: Int, limit: Int) throws -> AccessibilityChildBatch
    func representsSameElement(
        _ lhs: AccessibilityElementHandle,
        _ rhs: AccessibilityElementHandle
    ) -> Bool
    func identityHash(for element: AccessibilityElementHandle) -> Int
    func supportedActions(for element: AccessibilityElementHandle) throws -> [String]
    func perform(action: String, on element: AccessibilityElementHandle) throws
    func isValueSettable(on element: AccessibilityElementHandle) throws -> Bool
    func set(value: AccessibilitySetValue, on element: AccessibilityElementHandle) throws
}

extension AccessibilityTreeRuntime {
    // Existing test/backends remain source compatible. The system runtime
    // overrides this to fetch an offset directly without copying a prefix.
    func children(of element: AccessibilityElementHandle, offset: Int, limit: Int) throws -> AccessibilityChildBatch {
        let batch = try children(of: element, limit: offset + limit)
        return AccessibilityChildBatch(elements: Array(batch.elements.dropFirst(offset)), wasTruncated: batch.wasTruncated)
    }
}

struct SystemAccessibilityTreeRuntime: AccessibilityTreeRuntime {
    private let fixedWindow: AXUIElement?
    private let fixedProcessIdentifier: Int32?

    init() {
        fixedWindow = nil
        fixedProcessIdentifier = nil
    }

    init(fixedWindow: AXUIElement, processIdentifier: Int32) {
        self.fixedWindow = fixedWindow
        fixedProcessIdentifier = processIdentifier
    }

    func applicationElement(processIdentifier: Int32) throws -> AccessibilityElementHandle {
        if let fixedWindow {
            guard processIdentifier == fixedProcessIdentifier else {
                throw AutomationError.staleAccessibilitySnapshot
            }
            return AccessibilityElementHandle(fixedWindow)
        }
        let application = AXUIElementCreateApplication(processIdentifier)

        // Application children commonly begin with a very large menu bar. For
        // computer use that can exhaust a bounded preorder snapshot before the
        // actual document or browser content is reached. Prefer the app's
        // focused/main window as the observation root. Chromium can briefly
        // expose neither attribute while opening a new tab, so fall back to
        // its ordered AXWindows collection before traversing the application
        // menu tree. Retain the application element only for apps without a
        // window.
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = try copyAttribute(attribute, from: application),
               CFGetTypeID(window) == AXUIElementGetTypeID() {
                return AccessibilityElementHandle(window as AnyObject)
            }
        }
        if let windows = try copyAttribute(kAXWindowsAttribute, from: application) as? [AnyObject] {
            for window in windows where CFGetTypeID(window) == AXUIElementGetTypeID() {
                let accessibilityWindow = unsafeDowncast(window, to: AXUIElement.self)
                if try copyAttribute(kAXSubroleAttribute, from: accessibilityWindow) as? String
                    == kAXStandardWindowSubrole
                {
                    return AccessibilityElementHandle(window)
                }
            }
        }
        return AccessibilityElementHandle(application)
    }

    func applicationIsFrontmost(processIdentifier: Int32) throws -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        return try bool(attribute: kAXFrontmostAttribute, from: application) ?? false
    }

    func focusedWindow(processIdentifier: Int32) throws -> AccessibilityElementHandle? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let rawWindow = try copyAttribute(kAXFocusedWindowAttribute, from: application),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return AccessibilityElementHandle(rawWindow as AnyObject)
    }

    func describe(
        _ element: AccessibilityElementHandle,
        limits: AccessibilityTreeLimits
    ) throws -> AccessibilityElementDescription {
        let element = try axElement(from: element)
        let role = try boundedString(attribute: kAXRoleAttribute, from: element, limit: limits.maxTextLength)
        let subrole = try boundedString(attribute: kAXSubroleAttribute, from: element, limit: limits.maxTextLength)
        let title = try boundedString(attribute: kAXTitleAttribute, from: element, limit: limits.maxTextLength)
        let description = try boundedString(
            attribute: kAXDescriptionAttribute,
            from: element,
            limit: limits.maxTextLength
        )
        let help = try boundedString(attribute: kAXHelpAttribute, from: element, limit: limits.maxTextLength)
        let identifier = try boundedString(
            attribute: kAXIdentifierAttribute,
            from: element,
            limit: limits.maxTextLength
        )
        let domIdentifier: (value: String?, wasTruncated: Bool)
        if identifier.value == nil {
            domIdentifier = try boundedString(
                attribute: kAXDOMIdentifierAttribute,
                from: element,
                limit: limits.maxTextLength
            )
        } else {
            domIdentifier = (nil, false)
        }
        let value = try boundedValue(attribute: kAXValueAttribute, from: element, limit: limits.maxTextLength)
        let linkURL = role.value == "AXLink"
            ? AccessibilityObservedLinkURL.validate(try copyAttribute(kAXURLAttribute, from: element))
            : (value: nil, wasTruncated: false, identity: nil)
        let actions = try actionNames(for: element)
        let boundedActions = Array(actions.prefix(limits.maxActionsPerElement))

        return AccessibilityElementDescription(
            role: role.value,
            subrole: subrole.value,
            title: title.value,
            elementDescription: description.value,
            help: help.value,
            identifier: identifier.value,
            domIdentifier: domIdentifier.value,
            value: value.value,
            frame: try frame(of: element),
            isEnabled: try bool(attribute: kAXEnabledAttribute, from: element),
            isFocused: try bool(attribute: kAXFocusedAttribute, from: element),
            supportedActions: boundedActions,
            isValueSettable: try attributeIsSettable(kAXValueAttribute, on: element),
            wasTruncated: role.wasTruncated
                || subrole.wasTruncated
                || title.wasTruncated
                || description.wasTruncated
                || help.wasTruncated
                || identifier.wasTruncated
                || domIdentifier.wasTruncated
                || value.wasTruncated
                || actions.count > boundedActions.count
                || linkURL.wasTruncated,
            url: linkURL.value,
            urlIdentity: linkURL.identity,
            isSelected: try bool(attribute: kAXSelectedAttribute, from: element)
        )
    }

    func children(
        of element: AccessibilityElementHandle,
        limit: Int
    ) throws -> AccessibilityChildBatch {
        try children(of: element, offset: 0, limit: limit)
    }

    func children(of element: AccessibilityElementHandle, offset: Int, limit: Int) throws -> AccessibilityChildBatch {
        let element = try axElement(from: element)
        var count: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(
            element,
            kAXChildrenAttribute as CFString,
            &count
        )
        switch countResult {
        case .success:
            break
        case .attributeUnsupported, .noValue:
            return AccessibilityChildBatch(elements: [], wasTruncated: false)
        default:
            throw axFailure(countResult, operation: "count AXChildren")
        }

        let requestedCount = min(max(0, limit), max(0, count - offset))
        guard requestedCount > 0 else {
            return AccessibilityChildBatch(elements: [], wasTruncated: count > offset)
        }

        var values: CFArray?
        let copyResult = AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            offset,
            requestedCount,
            &values
        )
        try requireSuccess(copyResult, operation: "read AXChildren")

        let handles = (values as? [AnyObject] ?? []).compactMap { value -> AccessibilityElementHandle? in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return AccessibilityElementHandle(value)
        }
        return AccessibilityChildBatch(
            elements: handles,
            wasTruncated: count > offset + requestedCount || handles.count < requestedCount
        )
    }

    func representsSameElement(
        _ lhs: AccessibilityElementHandle,
        _ rhs: AccessibilityElementHandle
    ) -> Bool {
        guard
            CFGetTypeID(lhs.storage) == AXUIElementGetTypeID(),
            CFGetTypeID(rhs.storage) == AXUIElementGetTypeID()
        else {
            return false
        }
        return CFEqual(lhs.storage, rhs.storage)
    }

    func identityHash(for element: AccessibilityElementHandle) -> Int {
        Int(truncatingIfNeeded: CFHash(element.storage))
    }

    func supportedActions(for element: AccessibilityElementHandle) throws -> [String] {
        try actionNames(for: axElement(from: element))
    }

    func perform(action: String, on element: AccessibilityElementHandle) throws {
        let result = AXUIElementPerformAction(try axElement(from: element), action as CFString)
        try requireSuccess(result, operation: "perform \(action)")
    }

    func isValueSettable(on element: AccessibilityElementHandle) throws -> Bool {
        try attributeIsSettable(kAXValueAttribute, on: axElement(from: element))
    }

    func set(value: AccessibilitySetValue, on element: AccessibilityElementHandle) throws {
        let rawValue: CFTypeRef
        switch value {
        case let .text(text):
            rawValue = text as CFString
        case let .boolean(boolean):
            rawValue = boolean as CFBoolean
        case let .number(number):
            rawValue = number as CFNumber
        }
        let result = AXUIElementSetAttributeValue(
            try axElement(from: element),
            kAXValueAttribute as CFString,
            rawValue
        )
        try requireSuccess(result, operation: "set AXValue")
    }

    private func axElement(from handle: AccessibilityElementHandle) throws -> AXUIElement {
        guard CFGetTypeID(handle.storage) == AXUIElementGetTypeID() else {
            throw AutomationError.unexpectedAttributeType(attribute: "AXUIElement")
        }
        return unsafeDowncast(handle.storage, to: AXUIElement.self)
    }

    private func actionNames(for element: AXUIElement) throws -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyActionNames(element, &names)
        switch result {
        case .success:
            return names as? [String] ?? []
        case .attributeUnsupported, .noValue, .failure:
            // Some apps return the generic AX failure for optional action
            // metadata. Treat that element as having no actionable capability;
            // a mutation still requires a fresh, successful action check.
            return []
        default:
            throw axFailure(result, operation: "list supported actions")
        }
    }

    private func attributeIsSettable(_ attribute: String, on element: AXUIElement) throws -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        switch result {
        case .success:
            return settable.boolValue
        case .attributeUnsupported, .noValue, .failure:
            // A failed optional settable query must not make the element
            // writable or abort an otherwise useful read-only snapshot.
            return false
        default:
            throw axFailure(result, operation: "check whether \(attribute) is settable")
        }
    }

    private func frame(of element: AXUIElement) throws -> WindowFrame? {
        guard
            let positionValue = try copyAttribute(kAXPositionAttribute, from: element),
            let sizeValue = try copyAttribute(kAXSizeAttribute, from: element),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionAXValue = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue, to: AXValue.self)
        var point = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionAXValue, .cgPoint, &point),
            AXValueGetValue(sizeAXValue, .cgSize, &size),
            point.x.isFinite,
            point.y.isFinite,
            size.width.isFinite,
            size.height.isFinite
        else {
            return nil
        }
        return WindowFrame(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private func bool(attribute: String, from element: AXUIElement) throws -> Bool? {
        guard let value = try copyAttribute(attribute, from: element) else {
            return nil
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return unsafeDowncast(value, to: CFNumber.self) as NSNumber != 0
        }
        return nil
    }

    private func boundedString(
        attribute: String,
        from element: AXUIElement,
        limit: Int
    ) throws -> (value: String?, wasTruncated: Bool) {
        guard let value = try copyAttribute(attribute, from: element) else {
            return (nil, false)
        }
        guard CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String else {
            return (nil, false)
        }
        return bound(string, limit: limit)
    }

    private func boundedValue(
        attribute: String,
        from element: AXUIElement,
        limit: Int
    ) throws -> (value: String?, wasTruncated: Bool) {
        guard let value = try copyAttribute(attribute, from: element) else {
            return (nil, false)
        }

        let rendered: String?
        switch CFGetTypeID(value) {
        case CFStringGetTypeID():
            rendered = value as? String
        case CFBooleanGetTypeID():
            rendered = CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self)) ? "true" : "false"
        case CFNumberGetTypeID():
            rendered = String(describing: unsafeDowncast(value, to: CFNumber.self) as NSNumber)
        default:
            rendered = nil
        }
        guard let rendered else {
            return (nil, false)
        }
        return bound(rendered, limit: limit)
    }

    private func bound(_ value: String, limit: Int) -> (value: String?, wasTruncated: Bool) {
        guard value.count > limit else {
            return (value, false)
        }
        return (String(value.prefix(limit)), true)
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch result {
        case .success:
            return value
        case .attributeUnsupported, .noValue, .failure:
            // A generic AX failure on an optional descriptive attribute is
            // not permission to infer a value. Keep the element visible with
            // that field absent; mutation still re-reads target capabilities.
            return nil
        default:
            throw axFailure(result, operation: "read \(attribute)")
        }
    }

    private func requireSuccess(_ result: AXError, operation: String) throws {
        guard result == .success else {
            throw axFailure(result, operation: operation)
        }
    }

    private func axFailure(_ result: AXError, operation: String) -> AutomationError {
        .accessibilityFailure(operation: operation, code: result.rawValue)
    }
}

/// A serial, snapshot-scoped Accessibility session for one selected process.
///
/// Element indices are deterministic preorder positions within one snapshot.
/// Capturing a new snapshot invalidates the previous one. Every attempted
/// mutation invalidates the current snapshot, requiring the caller to inspect
/// fresh UI before issuing another action.
public final class AccessibilitySession {
    private struct ActiveSnapshot {
        let snapshot: AccessibilityTreeSnapshot
        let handles: [AccessibilityElementHandle]
    }

    public let application: AccessibilityApplicationTarget

    private let runtime: any AccessibilityTreeRuntime
    private let accessibilityCheck: () -> Bool
    private var activeSnapshot: ActiveSnapshot?
    private var progressiveRead: ProgressiveRead?
    private struct EvidenceHandle {
        let handle: AccessibilityElementHandle
        let identity: UUID
        var lastUse: UInt64
    }
    private var evidenceHandles: [Int: [EvidenceHandle]] = [:]
    private var evidenceHandleCount = 0
    private var evidenceSequence: UInt64 = 0
    private static let maximumEvidenceHandles = 4_096

    private func evidenceIdentity(for handle: AccessibilityElementHandle) -> UUID {
        if evidenceSequence == UInt64.max {
            // Exhaustion discards identity evidence; it never reuses a token.
            evidenceHandles.removeAll(); evidenceHandleCount = 0; evidenceSequence = 0
        }
        evidenceSequence += 1
        let hash = runtime.identityHash(for: handle)
        if let index = evidenceHandles[hash]?.firstIndex(where: { runtime.representsSameElement($0.handle, handle) }) {
            evidenceHandles[hash]![index].lastUse = evidenceSequence
            return evidenceHandles[hash]![index].identity
        }
        if evidenceHandleCount >= Self.maximumEvidenceHandles {
            let stale = Set(evidenceHandles.values.flatMap { $0 }.sorted { $0.lastUse < $1.lastUse }
                .prefix(Self.maximumEvidenceHandles / 4).map(\.identity))
            for key in Array(evidenceHandles.keys) {
                let retained = evidenceHandles[key]!.filter { !stale.contains($0.identity) }
                evidenceHandleCount -= evidenceHandles[key]!.count - retained.count
                if retained.isEmpty { evidenceHandles.removeValue(forKey: key) }
                else { evidenceHandles[key] = retained }
            }
        }
        let token = UUID()
        evidenceHandles[hash, default: []].append(.init(handle: handle, identity: token, lastUse: evidenceSequence))
        evidenceHandleCount += 1
        return token
    }

    public convenience init(application: RunningApplicationInfo) {
        self.init(target: AccessibilityApplicationTarget(application: application))
    }

    public convenience init(
        processIdentifier: Int32,
        bundleIdentifier: String? = nil,
        applicationName: String? = nil
    ) {
        self.init(
            target: AccessibilityApplicationTarget(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName
            )
        )
    }

    public init(target: AccessibilityApplicationTarget) {
        application = target
        runtime = SystemAccessibilityTreeRuntime()
        accessibilityCheck = { AXIsProcessTrusted() }
    }

    /// An opt-in exact-window root for app-bound observation/actions. The owner
    /// must validate windowIdentity around each operation and keep this session
    /// on the main actor. Existing global focus and HID guards are unchanged.
    @MainActor
    public init(target: AccessibilityApplicationTarget, windowIdentity: ApplicationWindowIdentity) throws {
        guard target.processIdentifier == windowIdentity.processIdentifier,
              target.bundleIdentifier == windowIdentity.bundleIdentifier else {
            throw ApplicationWindowReadError.applicationMismatch
        }
        let window = try windowIdentity.validatedWindowElement()
        application = target
        runtime = SystemAccessibilityTreeRuntime(fixedWindow: window, processIdentifier: target.processIdentifier)
        accessibilityCheck = { AXIsProcessTrusted() }
    }

    init(
        target: AccessibilityApplicationTarget,
        runtime: any AccessibilityTreeRuntime,
        accessibilityCheck: @escaping () -> Bool
    ) {
        application = target
        self.runtime = runtime
        self.accessibilityCheck = accessibilityCheck
    }

    public func snapshot(
        limits: AccessibilityTreeLimits = .agentDefault
    ) throws -> AccessibilityTreeSnapshot {
        activeSnapshot = nil
        progressiveRead = nil
        guard accessibilityCheck() else {
            throw AutomationError.permissionNotGranted(.accessibility)
        }

        let root = try runtime.applicationElement(processIdentifier: application.processIdentifier)
        let captured: ActiveSnapshot
        var initialRootRole: String?
        do {
            captured = try captureSnapshot(root: root, limits: limits, rootRole: &initialRootRole)
        } catch {
            // Chromium can detach a child while a loading page rebuilds its
            // tree. Retry the read once, never a mutation, and never publish a
            // partial tree. Only a positively identified, unchanged window is
            // a safe anchor; an application root or failed root description
            // cannot establish which window the second traversal would read.
            guard let failure = error as? AutomationError,
                  case let .accessibilityFailure(_, code) = failure,
                  code == AXError.invalidUIElement.rawValue,
                  initialRootRole == kAXWindowRole as String
            else {
                throw error
            }
            try requirePermission()
            let retryRoot = try runtime.applicationElement(processIdentifier: application.processIdentifier)
            guard runtime.representsSameElement(root, retryRoot) else {
                throw AutomationError.staleAccessibilitySnapshot
            }
            var retryRootRole: String?
            let retried = try captureSnapshot(root: retryRoot, limits: limits, rootRole: &retryRootRole)
            try requirePermission()
            let finalRoot = try runtime.applicationElement(processIdentifier: application.processIdentifier)
            guard retryRootRole == kAXWindowRole as String,
                  runtime.representsSameElement(root, finalRoot)
            else {
                throw AutomationError.staleAccessibilitySnapshot
            }
            captured = retried
        }
        activeSnapshot = captured
        return captured.snapshot
    }

    private func captureSnapshot(
        root: AccessibilityElementHandle,
        limits: AccessibilityTreeLimits,
        rootRole: inout String?
    ) throws -> ActiveSnapshot {
        var handles = [AccessibilityElementHandle]()
        var seenHandlesByHash = [Int: [AccessibilityElementHandle]]()
        var elements = [AccessibilityTreeElement]()
        var wasTruncated = false

        @discardableResult
        func visit(
            _ handle: AccessibilityElementHandle,
            parentIndex: Int?,
            depth: Int
        ) throws -> Int? {
            guard elements.count < limits.maxElements else {
                wasTruncated = true
                return nil
            }
            let identityHash = runtime.identityHash(for: handle)
            if seenHandlesByHash[identityHash, default: []].contains(where: {
                runtime.representsSameElement($0, handle)
            }) {
                return nil
            }

            let description = try runtime.describe(handle, limits: limits)
            if parentIndex == nil {
                rootRole = description.role
            }
            let index = elements.count
            handles.append(handle)
            seenHandlesByHash[identityHash, default: []].append(handle)
            elements.append(
                AccessibilityTreeElement(
                    index: index,
                    parentIndex: parentIndex,
                    childIndices: [],
                    depth: depth,
                    role: description.role,
                    subrole: description.subrole,
                    title: description.title,
                    elementDescription: description.elementDescription,
                    help: description.help,
                    identifier: description.identifier,
                    domIdentifier: description.domIdentifier,
                    value: description.value,
                    frame: description.frame,
                    isEnabled: description.isEnabled,
                    isFocused: description.isFocused,
                    supportedActions: description.supportedActions,
                    isValueSettable: description.isValueSettable,
                    url: description.url,
                    urlIdentity: description.urlIdentity,
                    isSelected: description.isSelected,
                    evidenceIdentity: evidenceIdentity(for: handle),
                    evidenceFieldsTruncated: description.wasTruncated
                )
            )
            wasTruncated = wasTruncated || description.wasTruncated

            let childLimit = depth < limits.maxDepth ? limits.maxChildrenPerElement : 0
            let childBatch = try runtime.children(of: handle, limit: childLimit)
            wasTruncated = wasTruncated || childBatch.wasTruncated

            var childIndices = [Int]()
            if depth < limits.maxDepth {
                for child in childBatch.elements {
                    guard elements.count < limits.maxElements else {
                        wasTruncated = true
                        break
                    }
                    if let childIndex = try visit(child, parentIndex: index, depth: depth + 1) {
                        childIndices.append(childIndex)
                    }
                }
            }

            let current = elements[index]
            elements[index] = AccessibilityTreeElement(
                index: current.index,
                parentIndex: current.parentIndex,
                childIndices: childIndices,
                depth: current.depth,
                role: current.role,
                subrole: current.subrole,
                title: current.title,
                elementDescription: current.elementDescription,
                help: current.help,
                identifier: current.identifier,
                domIdentifier: current.domIdentifier,
                value: current.value,
                frame: current.frame,
                isEnabled: current.isEnabled,
                isFocused: current.isFocused,
                supportedActions: current.supportedActions,
                isValueSettable: current.isValueSettable,
                url: current.url,
                urlIdentity: current.urlIdentity,
                isSelected: current.isSelected,
                evidenceIdentity: current.evidenceIdentity,
                evidenceFieldsTruncated: current.evidenceFieldsTruncated
            )
            return index
        }

        let rootIndex = try visit(root, parentIndex: nil, depth: 0)
        let id = UUID()
        let snapshot = AccessibilityTreeSnapshot(
            id: id,
            application: application,
            limits: limits,
            rootIndex: rootIndex,
            elements: elements,
            wasTruncated: wasTruncated
        )
        return ActiveSnapshot(
            snapshot: snapshot,
            handles: handles
        )
    }

    public func perform(
        _ action: SemanticAXAction,
        at index: Int,
        in snapshot: AccessibilityTreeSnapshot,
        beforeDispatch: () throws -> Void = {}
    ) throws {
        try requirePermission()
        let resolved = try resolve(index: index, snapshot: snapshot)
        activeSnapshot = nil
        guard resolved.element.supportedActions.contains(action.rawValue) else {
            throw AutomationError.unsupportedAction(action.rawValue)
        }
        let currentActions = try runtime.supportedActions(for: resolved.handle)
        guard currentActions.contains(action.rawValue) else {
            throw AutomationError.unsupportedAction(action.rawValue)
        }

        try beforeDispatch()
        try runtime.perform(action: action.rawValue, on: resolved.handle)
    }

    /// Reports whether the exact window retained by an approved snapshot is
    /// now the focused window of the focused application. Process activation
    /// alone is insufficient for Chromium, which can accept an Accessibility
    /// action for a background window without dispatching the page event.
    public func focusState(
        in snapshot: AccessibilityTreeSnapshot
    ) throws -> AccessibilitySnapshotFocusState {
        try requirePermission()
        guard let rootIndex = snapshot.rootIndex else {
            return .notWindow
        }
        let resolved = try resolve(index: rootIndex, snapshot: snapshot)
        guard resolved.element.role == kAXWindowRole as String else {
            return .notWindow
        }
        guard try runtime.applicationIsFrontmost(
            processIdentifier: application.processIdentifier
        ) else {
            return .applicationNotFocused
        }
        guard let focusedWindow = try runtime.focusedWindow(
            processIdentifier: application.processIdentifier
        ), runtime.representsSameElement(focusedWindow, resolved.handle) else {
            return .windowNotFocused
        }
        return .focused
    }

    /// Raises the exact window retained by the snapshot without invalidating
    /// its target handles. This is preparation for an already-approved
    /// mutation, not a replacement mutation or a label-based retarget.
    @discardableResult
    public func raiseSnapshotWindow(
        in snapshot: AccessibilityTreeSnapshot
    ) throws -> Bool {
        try requirePermission()
        guard let rootIndex = snapshot.rootIndex else {
            return false
        }
        let resolved = try resolve(index: rootIndex, snapshot: snapshot)
        guard resolved.element.role == kAXWindowRole as String else {
            return false
        }
        let action = kAXRaiseAction as String
        guard resolved.element.supportedActions.contains(action) else {
            throw AutomationError.unsupportedAction(action)
        }
        let currentActions = try runtime.supportedActions(for: resolved.handle)
        guard currentActions.contains(action) else {
            throw AutomationError.unsupportedAction(action)
        }
        try runtime.perform(action: action, on: resolved.handle)
        return true
    }

    /// Refreshes after an approval delay, securely rebinds the approved
    /// element, and performs the requested action on the current handle.
    public func refreshAndPerform(
        _ action: SemanticAXAction,
        at index: Int,
        in approvedSnapshot: AccessibilityTreeSnapshot,
        beforeDispatch: () throws -> Void = {}
    ) throws {
        let refreshed = try refreshTarget(at: index, in: approvedSnapshot)
        try perform(action, at: refreshed.index, in: refreshed.snapshot, beforeDispatch: beforeDispatch)
    }

    /// Refreshes after an approval delay, securely rebinds the approved
    /// element, and sets its value on the current handle.
    public func refreshAndSetValue(
        _ value: AccessibilitySetValue,
        at index: Int,
        in approvedSnapshot: AccessibilityTreeSnapshot,
        beforeDispatch: () throws -> Void = {}
    ) throws {
        let refreshed = try refreshTarget(at: index, in: approvedSnapshot)
        try setValue(value, at: refreshed.index, in: refreshed.snapshot, beforeDispatch: beforeDispatch)
    }

    /// Chromium can report success for a detached web node, so mutations must
    /// not use a cached child handle after native approval. Prefer exact AX
    /// identity in the fresh tree. If Chromium rebuilt the node, permit a
    /// logical rebind only through a complete stable AX/DOM identifier and a
    /// unique semantic match. Web controls must remain in the same document.
    /// Everything else fails closed as stale.
    func refreshTarget(
        at index: Int,
        in approvedSnapshot: AccessibilityTreeSnapshot
    ) throws -> (snapshot: AccessibilityTreeSnapshot, index: Int) {
        try requirePermission()
        let approved = try resolve(index: index, snapshot: approvedSnapshot)
        if progressiveRead != nil {
            return try refreshProgressiveTarget(at: index, in: approvedSnapshot)
        }
        guard let retainedSnapshot = activeSnapshot,
              let rootIndex = approvedSnapshot.rootIndex,
              retainedSnapshot.handles.indices.contains(rootIndex)
        else {
            throw AutomationError.staleAccessibilitySnapshot
        }
        let retainedRoot = retainedSnapshot.handles[rootIndex]
        let retainedTarget = approved.handle

        let refreshedSnapshot = try snapshot(limits: approvedSnapshot.limits)
        guard let refreshedActive = activeSnapshot,
              let refreshedRootIndex = refreshedSnapshot.rootIndex,
              refreshedActive.handles.indices.contains(refreshedRootIndex),
              runtime.representsSameElement(
                  retainedRoot,
                  refreshedActive.handles[refreshedRootIndex]
              )
        else {
            activeSnapshot = nil
            throw AutomationError.staleAccessibilitySnapshot
        }

        let identityMatches = refreshedSnapshot.elements.filter { candidate in
            guard refreshedActive.handles.indices.contains(candidate.index) else {
                return false
            }
            return runtime.representsSameElement(
                retainedTarget,
                refreshedActive.handles[candidate.index]
            )
        }
        if !identityMatches.isEmpty {
            guard identityMatches.count == 1,
                  let rebound = identityMatches.first,
                  hasSameApprovedSemantics(rebound, as: approved.element)
            else {
                activeSnapshot = nil
                throw AutomationError.staleAccessibilitySnapshot
            }
            return (refreshedSnapshot, rebound.index)
        }
        // A unique visible match is not a unique target when either bounded
        // traversal omitted nodes. In particular, another control with the
        // same identifier may be beyond maxElements, maxDepth, or child limits.
        // This restriction applies only to logical rebinds; a retained exact
        // AX identity remains safe in a partial tree.
        guard !approvedSnapshot.wasTruncated,
              !refreshedSnapshot.wasTruncated,
              application.bundleIdentifier != nil
        else {
            activeSnapshot = nil
            throw AutomationError.staleAccessibilitySnapshot
        }
        guard hasStableIdentifier(approved.element, limits: approvedSnapshot.limits) else {
            activeSnapshot = nil
            throw AutomationError.staleAccessibilitySnapshot
        }

        // A DOM identifier is scoped to its document, not to the whole Chrome
        // window. Keep the approved document's exact AX identity while its
        // child control is rebuilt; another tab may expose the same ID and
        // visible semantics. Chrome controls without a document ancestor may
        // use the exact-identity path above, but cannot be logically rebound.
        let approvedDocumentIndex = documentAncestorIndex(at: index, in: approvedSnapshot)
        let retainedDocument = approvedDocumentIndex.flatMap { documentIndex in
            retainedSnapshot.handles.indices.contains(documentIndex)
                ? retainedSnapshot.handles[documentIndex] : nil
        }
        if approvedDocumentIndex != nil && retainedDocument == nil {
            activeSnapshot = nil
            throw AutomationError.staleAccessibilitySnapshot
        }
        if (approved.element.domIdentifier != nil
            || application.bundleIdentifier?.hasPrefix("com.google.Chrome") == true),
           retainedDocument == nil {
            activeSnapshot = nil
            throw AutomationError.staleAccessibilitySnapshot
        }

        let logicalMatches = refreshedSnapshot.elements.filter { candidate in
            guard hasSameStableIdentifiers(
                candidate,
                as: approved.element,
                limits: approvedSnapshot.limits
            ), hasSameApprovedSemantics(candidate, as: approved.element) else {
                return false
            }
            guard let retainedDocument else {
                return true
            }
            guard let currentDocumentIndex = documentAncestorIndex(
                at: candidate.index,
                in: refreshedSnapshot
            ), refreshedActive.handles.indices.contains(currentDocumentIndex) else {
                return false
            }
            return runtime.representsSameElement(
                retainedDocument,
                refreshedActive.handles[currentDocumentIndex]
            )
        }
        guard logicalMatches.count == 1, let rebound = logicalMatches.first else {
            activeSnapshot = nil
            throw AutomationError.staleAccessibilitySnapshot
        }
        return (refreshedSnapshot, rebound.index)
    }

    public func setValue(
        _ value: AccessibilitySetValue,
        at index: Int,
        in snapshot: AccessibilityTreeSnapshot,
        beforeDispatch: () throws -> Void = {}
    ) throws {
        try requirePermission()
        let resolved = try resolve(index: index, snapshot: snapshot)
        activeSnapshot = nil
        guard resolved.element.isValueSettable else {
            throw AutomationError.attributeNotSettable(kAXValueAttribute as String)
        }
        if case let .text(text) = value, text.count > resolved.limits.maxTextLength {
            throw AutomationError.accessibilityValueTooLong(
                maximum: resolved.limits.maxTextLength,
                actual: text.count
            )
        }
        guard try runtime.isValueSettable(on: resolved.handle) else {
            throw AutomationError.attributeNotSettable(kAXValueAttribute as String)
        }

        try beforeDispatch()
        try runtime.set(value: value, on: resolved.handle)
    }

    public func invalidateSnapshot() {
        activeSnapshot = nil
        progressiveRead = nil
    }

    private func resolve(
        index: Int,
        snapshot: AccessibilityTreeSnapshot
    ) throws -> (
        element: AccessibilityTreeElement,
        handle: AccessibilityElementHandle,
        limits: AccessibilityTreeLimits
    ) {
        guard let activeSnapshot, activeSnapshot.snapshot == snapshot else {
            throw AutomationError.staleAccessibilitySnapshot
        }
        guard
            activeSnapshot.snapshot.elements.indices.contains(index),
            activeSnapshot.handles.indices.contains(index),
            activeSnapshot.snapshot.elements[index].index == index
        else {
            throw AutomationError.accessibilityElementIndexNotFound(index)
        }
        return (
            activeSnapshot.snapshot.elements[index],
            activeSnapshot.handles[index],
            activeSnapshot.snapshot.limits
        )
    }

    private func documentAncestorIndex(
        at index: Int,
        in snapshot: AccessibilityTreeSnapshot
    ) -> Int? {
        var ancestorIndex: Int? = index
        while let index = ancestorIndex, let ancestor = snapshot.element(at: index) {
            if ancestor.role == "AXWebArea" || ancestor.role == "AXDocument" {
                return index
            }
            ancestorIndex = ancestor.parentIndex
        }
        return nil
    }

    private func hasStableIdentifier(
        _ element: AccessibilityTreeElement,
        limits: AccessibilityTreeLimits
    ) -> Bool {
        let identifiers = [element.identifier, element.domIdentifier].compactMap { $0 }
        // The snapshot stores bounded strings without field-level truncation
        // flags. A value at the cutoff may be a prefix shared by two distinct
        // IDs, so only shorter values are safe as logical rebind keys.
        return !identifiers.isEmpty && identifiers.allSatisfy { value in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.count < limits.maxTextLength
        }
    }

    private func hasSameStableIdentifiers(
        _ candidate: AccessibilityTreeElement,
        as approved: AccessibilityTreeElement,
        limits: AccessibilityTreeLimits
    ) -> Bool {
        hasStableIdentifier(candidate, limits: limits)
            && candidate.identifier == approved.identifier
            && candidate.domIdentifier == approved.domIdentifier
    }

    private func hasSameApprovedSemantics(
        _ candidate: AccessibilityTreeElement,
        as approved: AccessibilityTreeElement
    ) -> Bool {
        candidate.role == approved.role
            && candidate.subrole == approved.subrole
            && candidate.title == approved.title
            && candidate.elementDescription == approved.elementDescription
            && candidate.help == approved.help
            && candidate.value == approved.value
            && candidate.url == approved.url
            && candidate.urlIdentity != .unverifiable
            && approved.urlIdentity != .unverifiable
            && candidate.urlIdentity == approved.urlIdentity
            && candidate.isEnabled == approved.isEnabled
            && candidate.isSelected == approved.isSelected
            && Set(candidate.supportedActions) == Set(approved.supportedActions)
            && candidate.isValueSettable == approved.isValueSettable
    }

    private func requirePermission() throws {
        guard accessibilityCheck() else {
            activeSnapshot = nil
            throw AutomationError.permissionNotGranted(.accessibility)
        }
    }
}

extension AccessibilitySession {
    private enum ReadWork {
        case node(AccessibilityElementHandle, parent: Int?, depth: Int)
        case children(parent: Int, offset: Int)
    }

    private final class ProgressiveRead {
        let request: SemanticReadRequest
        let window: AccessibilityElementHandle
        var cursorIssuedAt = Date()
        var work = [ReadWork]()
        var elements = [AccessibilityTreeElement]()
        var handles = [AccessibilityElementHandle]()
        var seen = [Int: [AccessibilityElementHandle]]()
        var pending = [Int]()
        var exposed = Set<Int>()
        var cursor: String?
        var snapshotID: UUID?
        var fieldsTruncated = false
        var sourceLimitReached = false
        var matched = 0
        var emittedCount = 0

        init(request: SemanticReadRequest, window: AccessibilityElementHandle) {
            self.request = request
            self.window = window
        }
    }

    /// Bounded source discovery plus bounded rendering. Unlike snapshot(), the
    /// read frontier survives a page: depth does not consume a fixed budget of
    /// meaningful content, and wide child collections can be enumerated. All
    /// retained data belongs to this exact window and is capped at 2,000 nodes.
    /// Only emitted lines authorize subtree expansion or a semantic action.
    public func read(read request: SemanticReadRequest = .init(), outputCharacterLimit: Int = 6_000,
                     allowsRaise: Bool = true, presentationRowByteReserve: Int = 0) throws -> AccessibilitySemanticReadResult {
        do {
            try requirePermission()
            guard request.requestedView != .overview else { throw SemanticReadError.unsupportedOverview }
            let state: ProgressiveRead
            if let cursor = request.cursor {
                guard let retained = progressiveRead, retained.cursor == cursor,
                      retained.snapshotID == activeSnapshot?.snapshot.id,
                      Date().timeIntervalSince(retained.cursorIssuedAt) <= 120 else { throw SemanticReadError.staleCursor }
                guard request.continues(retained.request) else { throw SemanticReadError.invalidRequest }
                try validateReadAnchor(retained)
                retained.cursor = nil // one-use, including a failed continuation
                state = retained
            } else {
                guard (request.snapshotID == nil) == (request.elementIndex == nil) else { throw SemanticReadError.invalidRequest }
                let window = try runtime.applicationElement(processIdentifier: application.processIdentifier)
                state = ProgressiveRead(request: request, window: window)
                if let id = request.snapshotID, let index = request.elementIndex {
                    guard let old = progressiveRead, old.snapshotID == id,
                          old.exposed.contains(index), let active = activeSnapshot,
                          active.snapshot.id == id, active.handles.indices.contains(index) else {
                        throw SemanticReadError.unexposedSubtree
                    }
                    try validateReadAnchor(old)
                    try validateReadMembership(indices: [index], state: old)
                    let path = try ancestorPath(to: index, in: active.snapshot)
                    // Preserve the source-observed ancestry so approval and
                    // descendant ownership cannot be borrowed from another card.
                    for oldIndex in path {
                        let parent = state.elements.isEmpty ? nil : state.elements.count - 1
                        let handle = active.handles[oldIndex]
                        let description = try runtime.describe(handle, limits: Self.progressiveLimits)
                        let inserted = appendReadElement(description, handle: handle, parent: parent,
                                                         depth: state.elements.count, state: state)
                        if oldIndex == index, matchesRead(state.elements[inserted], state: state) {
                            state.pending.append(inserted); state.matched += 1
                        }
                    }
                    state.work = [.children(parent: state.elements.count - 1, offset: 0)]
                } else {
                    state.work = [.node(window, parent: nil, depth: 0)]
                }
                progressiveRead = state
            }
            // Drain retained output before doing more OS work. A large source
            // can never silently skip records just because one output is short.
            let firstNewIndex = state.elements.count
            if state.pending.isEmpty {
                try advanceRead(state)
                try validateReadMembership(indices: Array(firstNewIndex..<state.elements.count), state: state,
                                           validateDescriptions: false)
            }
            try validateReadAnchor(state)
            // New nodes were just described and their attachment checked;
            // retained output needs a fresh description before being emitted.
            try validateReadMembership(indices: state.pending.prefix(120).filter { $0 < firstNewIndex }, state: state)
            let id = UUID()
            let snapshot = AccessibilityTreeSnapshot(id: id, application: application, limits: Self.progressiveLimits,
                rootIndex: state.elements.isEmpty ? nil : 0, elements: state.elements,
                wasTruncated: !state.work.isEmpty || state.fieldsTruncated || state.sourceLimitReached)
            let rendered = AccessibilitySnapshotTextFormatter(elementLimit: 120, fieldCharacterLimit: 256,
                actionLimit: 8, outputCharacterLimit: max(1_024, outputCharacterLimit - 500),
                usesCompactElementLines: true, includedElementIndices: Set(state.pending.prefix(120)),
                allowsRaise: allowsRaise, maximumAncestorDepth: 128,
                presentationRowByteReserve: presentationRowByteReserve)
                .formatObservation(snapshot, readRequest: state.request)
            let emitted = rendered.exposedElementIndices
            guard !emitted.isEmpty || state.pending.isEmpty else {
                // A pathological ancestry/field record must not produce an
                // endlessly reusable cursor that never emits a single node.
                throw SemanticReadError.outputBudgetTooSmall
            }
            let outputOffset = state.emittedCount
            state.emittedCount += emitted.count
            state.pending.removeAll { emitted.contains($0) }
            state.exposed = emitted
            state.snapshotID = id
            let hasMore = !state.pending.isEmpty || !state.work.isEmpty
            state.cursor = hasMore ? UUID().uuidString : nil
            state.cursorIssuedAt = Date()
            let queryStatus = state.request.query?.isEmpty == false
                ? (state.matched == 0 ? "no_matches_in_visited_source" : "matched") : "not_requested"
            let header = "SEMANTIC_READ view=\(state.request.view.rawValue) visited=\(state.elements.count) matched=\(state.matched) offset=\(outputOffset) shown=\(emitted.count) "
                + "source_truncated=\(snapshot.wasTruncated ? 1 : 0) output_truncated=\(state.pending.isEmpty ? 0 : 1) "
                + "field_truncated=\(rendered.readReceipt?.fieldTruncated == true ? 1 : 0) "
                + "source_limit_reached=\(state.sourceLimitReached ? 1 : 0) next_cursor=\(state.cursor ?? "-") query_status=\(queryStatus) consistency=live_validated_page\n"
            let receipt = rendered.readReceipt.map { body in
                SemanticReadReceipt(id: body.id, sourceID: body.sourceID, targetGeneration: body.targetGeneration,
                    consistency: .liveValidatedPage, view: body.view, query: body.query,
                    subtreeNodeID: body.subtreeNodeID, selectedElementCount: nil, selectedFieldCount: nil,
                    sourceTruncated: snapshot.wasTruncated, fieldTruncated: body.fieldTruncated,
                    outputTruncated: body.outputTruncated || !state.pending.isEmpty, exposures: body.exposures)
            }
            let observation = AccessibilityModelObservation(text: header + rendered.text,
                exposedElementIndices: emitted, snapshotID: id, readReceipt: receipt,
                presentation: rendered.presentation.map {
                    SemanticReadPresentation(snapshotID: $0.snapshotID, rows: $0.rows,
                        maximumOutputBytes: presentationRowByteReserve > 0 ? outputCharacterLimit : $0.maximumOutputBytes)
                })
            activeSnapshot = ActiveSnapshot(snapshot: snapshot, handles: state.handles)
            return AccessibilitySemanticReadResult(snapshot: snapshot, observation: observation)
        } catch {
            invalidateSnapshot()
            throw error
        }
    }

    private static var progressiveLimits: AccessibilityTreeLimits {
        // The depth field describes legacy refresh bounds only; progressive
        // traversal is iterative and bounded by visits, not recursive stack depth.
        try! AccessibilityTreeLimits(maxDepth: 32, maxElements: 2_000, maxChildrenPerElement: 80,
                                    maxActionsPerElement: 32, maxTextLength: 1_024)
    }

    private func advanceRead(_ state: ProgressiveRead) throws {
        var visited = 0
        var workCount = 0
        while !state.work.isEmpty, visited < 240, workCount < 1_000 {
            try Task.checkCancellation()
            try requirePermission()
            guard state.elements.count < 2_000 else {
                state.sourceLimitReached = true
                state.work.removeAll()
                break
            }
            workCount += 1
            switch state.work.removeLast() {
            case let .node(handle, parent, depth):
                let hash = runtime.identityHash(for: handle)
                if state.seen[hash, default: []].contains(where: { runtime.representsSameElement($0, handle) }) { continue }
                let description = try runtime.describe(handle, limits: Self.progressiveLimits)
                let index = appendReadElement(description, handle: handle, parent: parent, depth: depth, state: state)
                visited += 1
                if matchesRead(state.elements[index], state: state) {
                    state.pending.append(index); state.matched += 1
                }
                state.work.append(.children(parent: index, offset: 0))
            case let .children(parent, offset):
                let batch = try runtime.children(of: state.handles[parent], offset: offset, limit: 80)
                guard state.work.count + batch.elements.count + (batch.wasTruncated ? 1 : 0) <= 4_000 else {
                    state.sourceLimitReached = true
                    state.work.removeAll()
                    break
                }
                if batch.wasTruncated {
                    // An inconsistent AX provider must not produce an endless
                    // cursor returning no progress.
                    guard !batch.elements.isEmpty, offset < 2_000 else {
                        state.sourceLimitReached = true
                        continue
                    }
                    state.work.append(.children(parent: parent, offset: offset + batch.elements.count))
                }
                for child in batch.elements.reversed() {
                    state.work.append(.node(child, parent: parent, depth: state.elements[parent].depth + 1))
                }
            }
        }
    }

    @discardableResult
    private func appendReadElement(_ description: AccessibilityElementDescription,
                                   handle: AccessibilityElementHandle, parent: Int?, depth: Int,
                                   state: ProgressiveRead) -> Int {
        let index = state.elements.count
        state.handles.append(handle)
        state.seen[runtime.identityHash(for: handle), default: []].append(handle)
        state.fieldsTruncated = state.fieldsTruncated || description.wasTruncated
        state.elements.append(AccessibilityTreeElement(index: index, parentIndex: parent, childIndices: [], depth: depth,
            role: description.role, subrole: description.subrole, title: description.title,
            elementDescription: description.elementDescription, help: description.help, identifier: description.identifier,
            domIdentifier: description.domIdentifier, value: description.value, frame: description.frame,
            isEnabled: description.isEnabled, isFocused: description.isFocused, supportedActions: description.supportedActions,
            isValueSettable: description.isValueSettable, url: description.url, urlIdentity: description.urlIdentity,
            isSelected: description.isSelected, evidenceIdentity: evidenceIdentity(for: handle),
            evidenceFieldsTruncated: description.wasTruncated))
        if let parent { state.elements[parent] = replacingChildren(state.elements[parent], with: state.elements[parent].childIndices + [index]) }
        return index
    }

    private func replacingChildren(_ element: AccessibilityTreeElement, with children: [Int]) -> AccessibilityTreeElement {
        AccessibilityTreeElement(index: element.index, parentIndex: element.parentIndex, childIndices: children, depth: element.depth,
            role: element.role, subrole: element.subrole, title: element.title, elementDescription: element.elementDescription,
            help: element.help, identifier: element.identifier, domIdentifier: element.domIdentifier, value: element.value,
            frame: element.frame, isEnabled: element.isEnabled, isFocused: element.isFocused,
            supportedActions: element.supportedActions, isValueSettable: element.isValueSettable,
            url: element.url, urlIdentity: element.urlIdentity,
            isSelected: element.isSelected, evidenceIdentity: element.evidenceIdentity,
            evidenceFieldsTruncated: element.evidenceFieldsTruncated)
    }

    private func matchesRead(_ element: AccessibilityTreeElement, state: ProgressiveRead) -> Bool {
        let texts = [element.title, element.elementDescription, element.value, element.help, element.url].compactMap { $0 }
        let hasText = texts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let role = element.role ?? ""
        func hasAncestor(_ role: String) -> Bool {
            var parent = element.parentIndex
            var remaining = state.elements.count
            while let index = parent, state.elements.indices.contains(index), remaining > 0 {
                if state.elements[index].role == role { return true }
                parent = state.elements[index].parentIndex
                remaining -= 1
            }
            return false
        }
        let viewMatch: Bool
        switch state.request.view {
        case .all: viewMatch = true
        case .overview: viewMatch = false // Rejected before native observation.
        case .content: viewMatch = hasText && !["AXWindow", "AXApplication"].contains(role)
        case .headings: viewMatch = role == "AXHeading" || (hasText && hasAncestor("AXHeading"))
        case .links: viewMatch = role == "AXLink" || (hasText && hasAncestor("AXLink"))
        }
        guard viewMatch else { return false }
        guard let query = state.request.query, !query.isEmpty else { return true }
        return texts.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func validateReadAnchor(_ state: ProgressiveRead) throws {
        let current = try runtime.applicationElement(processIdentifier: application.processIdentifier)
        guard runtime.representsSameElement(current, state.window) else { throw SemanticReadError.staleCursor }
        // Detect navigation/window replacement instead of mixing one page's
        // retained output with a different page's unvisited descendants.
        for element in state.elements where element.index == 0 || ["AXWebArea", "AXDocument"].contains(element.role ?? "") {
            let current = try runtime.describe(state.handles[element.index], limits: Self.progressiveLimits)
            guard current.role == element.role, current.title == element.title,
                  current.value == element.value, current.url == element.url else { throw SemanticReadError.staleCursor }
        }
    }

    private func ancestorPath(to index: Int, in snapshot: AccessibilityTreeSnapshot) throws -> [Int] {
        var path = [Int]()
        var cursor: Int? = index
        while let next = cursor {
            guard let element = snapshot.element(at: next), !path.contains(next) else { throw AutomationError.staleAccessibilitySnapshot }
            path.append(next); cursor = element.parentIndex
        }
        guard path.last == snapshot.rootIndex else { throw AutomationError.staleAccessibilitySnapshot }
        return path.reversed()
    }

    /// Read capabilities are not permission to inspect detached AX handles.
    /// Validate shared ancestry edges once per parent, fetching only enough of
    /// each live child list to find the exact identities used by this page.
    private func validateReadMembership(indices: [Int], state: ProgressiveRead, validateDescriptions: Bool = true) throws {
        var required = [Int: Set<Int>]()
        var visited = Set<Int>()
        for index in indices {
            var current = index
            while state.elements.indices.contains(current), visited.insert(current).inserted,
                  let parent = state.elements[current].parentIndex {
                required[parent, default: []].insert(current)
                current = parent
            }
        }
        var inspected = 0
        for parent in required.keys.sorted() {
            var missing = required[parent] ?? []
            var offset = 0
            while !missing.isEmpty, inspected < 4_000 {
                let batch = try runtime.children(of: state.handles[parent], offset: offset, limit: 80)
                inspected += batch.elements.count
                missing = missing.filter { child in
                    !batch.elements.contains { runtime.representsSameElement($0, state.handles[child]) }
                }
                guard batch.wasTruncated, !batch.elements.isEmpty else { break }
                offset += batch.elements.count
            }
            guard missing.isEmpty else { throw SemanticReadError.staleCursor }
        }
        guard validateDescriptions else { return }
        for index in indices {
            let old = state.elements[index]
            let current = try runtime.describe(state.handles[index], limits: Self.progressiveLimits)
            guard current.role == old.role, current.title == old.title, current.value == old.value,
                  current.elementDescription == old.elementDescription, current.url == old.url else {
                throw SemanticReadError.staleCursor
            }
        }
    }

    private func refreshProgressiveTarget(at index: Int, in approved: AccessibilityTreeSnapshot) throws -> (snapshot: AccessibilityTreeSnapshot, index: Int) {
        guard let state = progressiveRead, state.snapshotID == approved.id, state.exposed.contains(index),
              let active = activeSnapshot else { throw AutomationError.staleAccessibilitySnapshot }
        try validateReadAnchor(state)
        let path = try ancestorPath(to: index, in: approved)
        // Revalidate exact membership down the retained path. Detached handles
        // or same-labelled controls in a different document cannot be rebound.
        var inspected = 0
        for (parent, child) in zip(path, path.dropFirst()) {
            var offset = 0
            var found = false
            while inspected < 2_000 {
                let batch = try runtime.children(of: active.handles[parent], offset: offset, limit: 80)
                inspected += batch.elements.count
                if batch.elements.contains(where: { runtime.representsSameElement($0, active.handles[child]) }) { found = true; break }
                guard batch.wasTruncated, !batch.elements.isEmpty else { break }
                offset += batch.elements.count
            }
            guard found else { invalidateSnapshot(); throw AutomationError.staleAccessibilitySnapshot }
        }
        let description = try runtime.describe(active.handles[index], limits: approved.limits)
        let old = approved.elements[index]
        let current = AccessibilityTreeElement(index: index, parentIndex: old.parentIndex, childIndices: old.childIndices, depth: old.depth,
            role: description.role, subrole: description.subrole, title: description.title, elementDescription: description.elementDescription,
            help: description.help, identifier: description.identifier, domIdentifier: description.domIdentifier, value: description.value,
            frame: description.frame, isEnabled: description.isEnabled, isFocused: description.isFocused,
            supportedActions: description.supportedActions, isValueSettable: description.isValueSettable,
            url: description.url, urlIdentity: description.urlIdentity,
            isSelected: description.isSelected, evidenceIdentity: evidenceIdentity(for: active.handles[index]),
            evidenceFieldsTruncated: description.wasTruncated)
        guard hasSameApprovedSemantics(current, as: old) else { invalidateSnapshot(); throw AutomationError.staleAccessibilitySnapshot }
        // The identity is exact and still attached. Never logically rebind a
        // progressive/partial tree, even when a stable label happens to match.
        return (approved, index)
    }
}

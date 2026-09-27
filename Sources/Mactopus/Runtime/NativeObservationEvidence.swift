import AutomationCore
import CryptoKit
import Foundation

/// Canonical retained AX properties for same-control verification. Array
/// indices remain observation-local addresses, never cross-snapshot identity.
/// The caller must separately validate the same bound native window/lifetime.
enum NativeObservationEvidence {
    enum Failure: Error, LocalizedError {
        case unexposedElement, missingProperty, unstableIdentity, unknownDocument

        var errorDescription: String? {
            switch self {
            case .unexposedElement: "Verification requires an element exposed in the current native observation."
            case .missingProperty: "That native element has no observed text/value property to verify."
            case .unstableIdentity: "This native element has no unique stable Accessibility identifier. Its array index cannot verify a changed outcome."
            case .unknownDocument: "The native element's document identity is unknown or ambiguous. Observe through the background browser tools when available."
            }
        }
    }

    static func properties(snapshot: AccessibilityTreeSnapshot, exposedIndices: Set<Int>) -> [String: String] {
        let context = Context(snapshot)
        var result = [String: String]()
        for element in snapshot.elements where exposedIndices.contains(element.index) {
            guard let identity = try? identity(element: element, context: context) else { continue }
            for field in ["text", "value", "selection"] {
                if let value = value(of: element, field: field) { result["native:\(identity):\(field)"] = value }
            }
        }
        return result
    }

    static func canonicalProperty(snapshot: AccessibilityTreeSnapshot, exposedIndices: Set<Int>,
                                  index: Int, field: String) throws -> String {
        let context = Context(snapshot)
        guard exposedIndices.contains(index), let element = snapshot.element(at: index),
              context.byIndex[index] != nil else { throw Failure.unexposedElement }
        guard value(of: element, field: field) != nil else { throw Failure.missingProperty }
        return "native:\(try identity(element: element, context: context)):\(field)"
    }

    private static func value(of element: AccessibilityTreeElement, field: String) -> String? {
        switch field {
        case "text": [element.title, element.elementDescription].compactMap { $0 }.first { !$0.isEmpty }
        case "value": element.value
        case "selection": element.isSelected.map { $0 ? "true" : "false" }
        default: nil
        }
    }

    private struct Context {
        let byIndex: [Int: AccessibilityTreeElement]
        let domCounts: [String: Int]
        let axCounts: [String: Int]

        init(_ snapshot: AccessibilityTreeSnapshot) {
            byIndex = Dictionary(grouping: snapshot.elements, by: \.index)
                .filter { $0.value.count == 1 }.mapValues { $0[0] }
            domCounts = Dictionary(grouping: snapshot.elements.compactMap(\.domIdentifier), by: { $0 }).mapValues(\.count)
            axCounts = Dictionary(grouping: snapshot.elements.compactMap(\.identifier), by: { $0 }).mapValues(\.count)
        }
    }

    private static func identity(element: AccessibilityTreeElement, context: Context) throws -> String {
        guard context.byIndex[element.index] != nil else { throw Failure.unexposedElement }
        let identifier: String
        if let token = element.evidenceIdentity {
            guard context.byIndex.values.filter({ $0.evidenceIdentity == token }).count == 1 else { throw Failure.unstableIdentity }
            identifier = "token:" + token.uuidString
        } else if let value = element.domIdentifier, !value.isEmpty,
           context.domCounts[value] == 1 {
            identifier = "dom:" + value
        } else if let value = element.identifier, !value.isEmpty,
                  context.axCounts[value] == 1 {
            identifier = "ax:" + value
        } else { throw Failure.unstableIdentity }

        // A reused identifier on another webpage is not the same control.
        // Native non-document controls use the caller's exact window guard.
        var current = element
        var seen = Set<Int>()
        var document = "native-window"
        while true {
            guard seen.count < 64, seen.insert(current.index).inserted else { throw Failure.unknownDocument }
            if current.role == "AXWebArea" || current.role == "AXDocument" {
                guard let url = current.url, !url.isEmpty, URL(string: url)?.scheme != nil else {
                    throw Failure.unknownDocument
                }
                document = url
                break
            }
            guard let parent = current.parentIndex else { break }
            guard let next = context.byIndex[parent] else { throw Failure.unknownDocument }
            current = next
        }
        // Hash delimiters via JSON framing; identifiers and document URLs may
        // contain arbitrary punctuation and must not collide by concatenation.
        let data = try JSONEncoder().encode([document, identifier])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

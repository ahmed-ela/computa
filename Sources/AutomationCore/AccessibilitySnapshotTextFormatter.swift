import Foundation

/// Produces a bounded, line-oriented accessibility snapshot for model input.
///
/// The default limits are intentionally smaller than ``AccessibilityTreeLimits``
/// because this representation is meant to share a model context with the
/// user's request and the desktop tool definitions.
public struct AccessibilitySnapshotTextFormatter: Equatable, Sendable {
    public static let modelDefault = AccessibilitySnapshotTextFormatter()

    public let elementLimit: Int
    public let fieldCharacterLimit: Int
    public let actionLimit: Int
    public let outputCharacterLimit: Int
    public let prioritizesRelevantElements: Bool
    public let preferredText: String?
    public let usesCompactElementLines: Bool

    public init(
        elementLimit: Int = 120,
        fieldCharacterLimit: Int = 96,
        actionLimit: Int = 6,
        outputCharacterLimit: Int = 12_000,
        prioritizesRelevantElements: Bool = false,
        preferredText: String? = nil,
        usesCompactElementLines: Bool = false
    ) {
        self.elementLimit = min(max(elementLimit, 0), 2_000)
        self.fieldCharacterLimit = min(max(fieldCharacterLimit, 1), 4_096)
        self.actionLimit = min(max(actionLimit, 0), 128)
        self.outputCharacterLimit = min(max(outputCharacterLimit, 512), 1_000_000)
        self.prioritizesRelevantElements = prioritizesRelevantElements
        self.preferredText = preferredText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.usesCompactElementLines = usesCompactElementLines
    }

    public func format(_ snapshot: AccessibilityTreeSnapshot) -> String {
        var formatWasTruncated = false
        let metadataFieldLimit = min(fieldCharacterLimit, 48)
        let app = quoted(
            snapshot.application.applicationName,
            characterLimit: metadataFieldLimit,
            truncated: &formatWasTruncated
        )
        let bundle = quoted(
            snapshot.application.bundleIdentifier,
            characterLimit: metadataFieldLimit,
            truncated: &formatWasTruncated
        )

        var selectedElements = Array(snapshot.elements.prefix(elementLimit))
        if prioritizesRelevantElements {
            selectedElements.sort { lhs, rhs in
                let lhsPriority = relevance(of: lhs, rootIndex: snapshot.rootIndex)
                let rhsPriority = relevance(of: rhs, rootIndex: snapshot.rootIndex)
                return lhsPriority == rhsPriority
                    ? lhs.index < rhs.index
                    : lhsPriority > rhsPriority
            }
        }
        let elementCandidates = selectedElements.map { element in
            elementLine(element, truncated: &formatWasTruncated)
        }
        if snapshot.elements.count > elementCandidates.count {
            formatWasTruncated = true
        }

        var elementLines = Array(elementCandidates)
        while true {
            let omittedByBudget = elementLines.count < elementCandidates.count
            let outputWasTruncated = formatWasTruncated || omittedByBudget
            let header = headerLine(
                snapshot: snapshot,
                app: app,
                bundle: bundle,
                shownElementCount: elementLines.count,
                outputWasTruncated: outputWasTruncated
            )
            let output = ([header] + elementLines).joined(separator: "\n")

            if output.count <= outputCharacterLimit || elementLines.isEmpty {
                return output
            }

            elementLines.removeLast()
        }
    }

    private func headerLine(
        snapshot: AccessibilityTreeSnapshot,
        app: String,
        bundle: String,
        shownElementCount: Int,
        outputWasTruncated: Bool
    ) -> String {
        let root = snapshot.rootIndex.map(String.init) ?? "-"
        return "AXSNAPSHOT id=\(snapshot.id.uuidString) "
            + "pid=\(snapshot.application.processIdentifier) "
            + "app=\(app) bundle=\(bundle) root=\(root) "
            + "shown=\(shownElementCount) total=\(snapshot.elements.count) "
            + "source_truncated=\(bit(snapshot.wasTruncated)) "
            + "output_truncated=\(bit(outputWasTruncated))"
    }

    private func elementLine(
        _ element: AccessibilityTreeElement,
        truncated: inout Bool
    ) -> String {
        let role = quoted(roleAndSubrole(for: element), truncated: &truncated)
        let label = quoted(label(for: element), truncated: &truncated)
        let value = quoted(element.value, truncated: &truncated)
        let actions = formatActions(element.supportedActions, truncated: &truncated)

        if usesCompactElementLines {
            let focused = element.isFocused == true ? " focused=1" : ""
            let screenFrame = element.frame.map { " screen_frame=\(format($0))" } ?? ""
            return "#\(element.index) role=\(role) label=\(label) value=\(value) "
                + "actions=\(actions) settable=\(bit(element.isValueSettable))\(focused)\(screenFrame)"
        }

        let parent = element.parentIndex.map(String.init) ?? "-"
        let frame = element.frame.map(format) ?? "-"
        let enabled = element.isEnabled.map(bit) ?? "-"
        let focused = element.isFocused.map(bit) ?? "-"

        return "#\(element.index) parent=\(parent) role=\(role) "
            + "label=\(label) value=\(value) frame=\(frame) "
            + "enabled=\(enabled) focused=\(focused) "
            + "actions=\(actions) settable=\(bit(element.isValueSettable))"
    }

    private func roleAndSubrole(for element: AccessibilityTreeElement) -> String? {
        switch (nonempty(element.role), nonempty(element.subrole)) {
        case (.some(let role), .some(let subrole)):
            return "\(role)/\(subrole)"
        case (.some(let role), .none):
            return role
        case (.none, .some(let subrole)):
            return subrole
        case (.none, .none):
            return nil
        }
    }

    private func relevance(
        of element: AccessibilityTreeElement,
        rootIndex: Int?
    ) -> Int {
        if element.index == rootIndex { return 10_000 }

        var score = 0
        let matchesPreferredText = preferredText.map { preferredText in
            !preferredText.isEmpty
                && searchableText(for: element).localizedCaseInsensitiveContains(preferredText)
        } ?? false
        if matchesPreferredText {
            score += 20_000
            // Chrome tab labels can appear as many matching radio buttons. A
            // matching page heading should survive a short output budget, while
            // matching action targets still take precedence over the heading.
            switch nonempty(element.role) {
            case "AXHeading":
                score += 3_000
            case "AXButton", "AXCheckBox", "AXComboBox", "AXLink", "AXMenuItem",
                 "AXPopUpButton", "AXSearchField", "AXSlider", "AXTextArea",
                 "AXTextField":
                score += 3_500
            default:
                break
            }
        }
        if label(for: element) != nil { score += 400 }
        if nonempty(element.value) != nil { score += 300 }
        if element.isFocused == true { score += 200 }
        if element.isValueSettable { score += 300 }
        if !element.supportedActions.isEmpty { score += 400 }

        switch nonempty(element.role) {
        case "AXButton", "AXCheckBox", "AXComboBox", "AXLink", "AXMenuItem",
             "AXPopUpButton", "AXRadioButton", "AXSearchField", "AXSlider",
             "AXTextArea", "AXTextField":
            score += 1_000
        case "AXHeading", "AXStaticText":
            score += 40
        default:
            break
        }
        return score
    }

    private func searchableText(for element: AccessibilityTreeElement) -> String {
        [
            element.role,
            element.subrole,
            element.title,
            element.elementDescription,
            element.help,
            element.identifier,
            element.domIdentifier,
            element.value,
        ]
        .compactMap(nonempty)
        .joined(separator: " ")
    }

    private func label(for element: AccessibilityTreeElement) -> String? {
        [
            element.title,
            element.elementDescription,
            element.identifier,
            element.domIdentifier,
            element.help,
        ]
            .compactMap(nonempty)
            .first
    }

    private func formatActions(
        _ actions: [String],
        truncated: inout Bool
    ) -> String {
        let shownActions = actions.prefix(actionLimit)
        if actions.count > shownActions.count {
            truncated = true
        }

        return "[" + shownActions.map { action in
            quoted(action, truncated: &truncated)
        }.joined(separator: ",") + "]"
    }

    private func quoted(_ value: String?, truncated: inout Bool) -> String {
        quoted(value, characterLimit: fieldCharacterLimit, truncated: &truncated)
    }

    private func quoted(
        _ value: String?,
        characterLimit: Int,
        truncated: inout Bool
    ) -> String {
        guard let value = nonempty(value) else {
            return "-"
        }

        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let clipped: String
        if normalized.count > characterLimit {
            clipped = String(normalized.prefix(max(0, characterLimit - 1))) + "…"
            truncated = true
        } else {
            clipped = normalized
        }

        let escaped = clipped
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func format(_ frame: WindowFrame) -> String {
        "[\(number(frame.x)),\(number(frame.y)),\(number(frame.width)),\(number(frame.height))]"
    }

    private func number(_ value: Double) -> String {
        guard value.isFinite else {
            return String(describing: value)
        }
        return String(
            format: "%.6g",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.allSatisfy(\.isWhitespace) else {
            return nil
        }
        return value
    }

    private func bit(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}

public extension AccessibilityTreeSnapshot {
    /// Returns compact model input while retaining stable element indices for
    /// follow-up accessibility actions.
    func formattedForModel(
        using formatter: AccessibilitySnapshotTextFormatter = .modelDefault
    ) -> String {
        formatter.format(self)
    }
}

import Foundation

/// A model-visible snapshot and the exact, unambiguous element identities
/// represented by its retained element lines. Header and ancestry references
/// provide context only; they do not make an element an exposed action target.
public struct AccessibilityModelObservation: Equatable, Sendable {
    public let text: String
    public let exposedElementIndices: Set<Int>
    public let snapshotID: UUID
    /// Host-only read evidence; absent for legacy full-tree observations.
    public let readReceipt: SemanticReadReceipt?
    public let presentation: SemanticReadPresentation?

    public init(text: String, exposedElementIndices: Set<Int>, snapshotID: UUID,
                readReceipt: SemanticReadReceipt? = nil, presentation: SemanticReadPresentation? = nil) {
        self.text = text
        self.exposedElementIndices = exposedElementIndices
        self.snapshotID = snapshotID
        self.readReceipt = readReceipt
        self.presentation = presentation
    }
}

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
    public let prioritizesFocusedDocument: Bool
    public let includedElementIndices: Set<Int>?
    public let allowsRaise: Bool
    public let maximumAncestorDepth: Int
    /// Reserved per retained row for a later typed reference presentation.
    /// Opting in also reserves the fixed guidance overhead and uses a UTF-8
    /// budget. Legacy callers keep the original character-budget contract.
    public let presentationRowByteReserve: Int

    public init(
        elementLimit: Int = 120,
        fieldCharacterLimit: Int = 96,
        actionLimit: Int = 6,
        outputCharacterLimit: Int = 12_000,
        prioritizesRelevantElements: Bool = false,
        preferredText: String? = nil,
        usesCompactElementLines: Bool = false,
        prioritizesFocusedDocument: Bool = false,
        includedElementIndices: Set<Int>? = nil,
        allowsRaise: Bool = true,
        maximumAncestorDepth: Int = 32,
        presentationRowByteReserve: Int = 0
    ) {
        self.elementLimit = min(max(elementLimit, 0), 2_000)
        self.fieldCharacterLimit = min(max(fieldCharacterLimit, 1), 4_096)
        self.actionLimit = min(max(actionLimit, 0), 128)
        self.outputCharacterLimit = min(max(outputCharacterLimit, 512), 1_000_000)
        self.prioritizesRelevantElements = prioritizesRelevantElements
        self.preferredText = preferredText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.usesCompactElementLines = usesCompactElementLines
        self.prioritizesFocusedDocument = prioritizesFocusedDocument
        self.includedElementIndices = includedElementIndices
        self.allowsRaise = allowsRaise
        self.maximumAncestorDepth = min(max(maximumAncestorDepth, 1), 128)
        self.presentationRowByteReserve = min(max(presentationRowByteReserve, 0), 1_024)
    }

    public func format(_ snapshot: AccessibilityTreeSnapshot) -> String {
        formatObservation(snapshot).text
    }

    public func formatObservation(_ snapshot: AccessibilityTreeSnapshot,
                                  readRequest: SemanticReadRequest? = nil) -> AccessibilityModelObservation {
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

        let boundedElements = Array(snapshot.elements.prefix(2_000))
        let observedByIndex = uniqueElementsByIndex(in: boundedElements)
        let documentElements = descendantIndices(in: boundedElements, observedByIndex: observedByIndex) {
            $0.role == "AXWebArea" || $0.role == "AXDocument"
        }
        var headingsByParent = [Int: [AccessibilityTreeElement]]()
        if usesCompactElementLines, snapshot.elements.count <= 2_000 {
            for element in boundedElements where element.role == "AXHeading" {
                if let parent = element.parentIndex { headingsByParent[parent, default: []].append(element) }
            }
        }
        let selectedElements = selectedElements(
            in: snapshot, bounded: boundedElements, observedByIndex: observedByIndex, documentElements: documentElements
        )
        let elementCandidates = selectedElements.map { element in
            let ancestry = usesCompactElementLines ? compactAncestryField(
                for: element, rootIndex: snapshot.rootIndex, observedByIndex: observedByIndex,
                truncated: &formatWasTruncated
            ) : (field: "", ancestors: [])
            let siblingHeading = usesCompactElementLines ? siblingHeadingField(
                for: element, rootIndex: snapshot.rootIndex, observedByIndex: observedByIndex,
                documentElements: documentElements, headingsByParent: headingsByParent, truncated: &formatWasTruncated
            ) : ""
            return (index: element.index,
                    line: elementLine(element, ancestry: ancestry.field, siblingHeading: siblingHeading, truncated: &formatWasTruncated),
                    ancestors: ancestry.ancestors)
        }
        var unambiguousCandidateIndices = Set(elementCandidates.compactMap { candidate in
            candidate.index >= 0 && observedByIndex[candidate.index] != nil ? candidate.index : nil
        })
        // Rendering and ancestry remain bounded to the original observation cap.
        // A duplicate beyond that cap still makes a rendered identity ambiguous;
        // scan only its index, without retaining or formatting additional nodes.
        for element in snapshot.elements.dropFirst(boundedElements.count) {
            unambiguousCandidateIndices.remove(element.index)
        }
        if includedElementIndices == nil && snapshot.elements.count > elementCandidates.count {
            formatWasTruncated = true
        }

        var elementLines = elementCandidates.map(\.line)
        var ancestorUseCounts = [Int: Int]()
        for candidate in elementCandidates {
            for index in candidate.ancestors { ancestorUseCounts[index, default: 0] += 1 }
        }
        let ancestorRecords = ancestorUseCounts.keys.sorted().compactMap { index -> (index: Int, text: String)? in
            guard let element = observedByIndex[index] else { return nil }
            return (index, "\(index):\(element.parentIndex.map(String.init) ?? "-")")
        }
        while true {
            let omittedByBudget = elementLines.count < elementCandidates.count
            let outputWasTruncated = formatWasTruncated || omittedByBudget
            let header = headerLine(
                snapshot: snapshot,
                app: app,
                bundle: bundle,
                shownElementCount: elementLines.count,
                outputWasTruncated: outputWasTruncated,
                parentMap: usesCompactElementLines
                    ? " parents=[\(ancestorRecords.filter { ancestorUseCounts[$0.index, default: 0] > 0 }.map(\.text).joined(separator: ","))]"
                    : ""
            )
            let output = ([header] + elementLines).joined(separator: "\n")

            let reservedBytes = elementLines.count * presentationRowByteReserve
                + (presentationRowByteReserve > 0 ? SemanticReadPresentation.fixedMetadataByteReserve : 0)
            let fitsBudget = presentationRowByteReserve > 0
                ? output.utf8.count + reservedBytes <= outputCharacterLimit
                : output.count <= outputCharacterLimit
            if fitsBudget || elementLines.isEmpty {
                let retainedCandidates = elementCandidates.prefix(elementLines.count).filter {
                    unambiguousCandidateIndices.contains($0.index)
                }
                let retainedIndices = Set(retainedCandidates.map(\.index))
                return AccessibilityModelObservation(
                    text: output,
                    exposedElementIndices: Set(elementCandidates.prefix(elementLines.count).compactMap { candidate in
                        unambiguousCandidateIndices.contains(candidate.index) ? candidate.index : nil
                    }),
                    snapshotID: snapshot.id,
                    readReceipt: readRequest.map { request in
                        let retained = elementCandidates.prefix(elementLines.count).compactMap { candidate in
                            unambiguousCandidateIndices.contains(candidate.index) ? observedByIndex[candidate.index] : nil
                        }
                        return readReceipt(snapshot: snapshot, request: request, elements: retained,
                                           observedByIndex: observedByIndex,
                                           outputTruncated: omittedByBudget || selectedElements.count < (includedElementIndices?.count ?? snapshot.elements.count))
                    },
                    presentation: .init(snapshotID: snapshot.id, rows: retainedCandidates.compactMap { candidate in
                        guard let element = observedByIndex[candidate.index] else { return nil }
                        let enabled = element.isEnabled != false
                        return SemanticReadPresentedRow(index: candidate.index, text: candidate.line,
                            actions: enabled ? presentedActions(element.supportedActions) : [],
                            settable: enabled && element.isValueSettable,
                            followLink: false, region: true,
                            parentIndex: element.parentIndex.flatMap {
                                retainedIndices.contains($0) && $0 != candidate.index ? $0 : nil
                            })
                    }, maximumOutputBytes: presentationRowByteReserve > 0 ? outputCharacterLimit : 16_384)
                )
            }

            let removed = elementCandidates[elementLines.count - 1]
            elementLines.removeLast()
            for index in removed.ancestors { ancestorUseCounts[index, default: 0] -= 1 }
        }
    }

    /// Receipt construction uses the retained body lines, never header/ancestry
    /// labels or captured-but-omitted elements. Live native pages cannot certify
    /// one immutable source, even after their traversal cursor is exhausted.
    private func readReceipt(snapshot: AccessibilityTreeSnapshot, request: SemanticReadRequest,
                             elements: [AccessibilityTreeElement],
                             observedByIndex: [Int: AccessibilityTreeElement],
                             outputTruncated: Bool) -> SemanticReadReceipt {
        var exposures = [SemanticReadFieldExposure]()
        var fieldTruncated = snapshot.elements.contains { $0.evidenceFieldsTruncated == true }
        for element in elements {
            let provenance = readProvenance(element, rootIndex: snapshot.rootIndex, observedByIndex: observedByIndex)
            let kind = readKind(element, provenance: provenance, rootIndex: snapshot.rootIndex,
                                observedByIndex: observedByIndex)
            // Identifier fallbacks are metadata even on a readable-text role.
            let labelIsIdentifier = nonempty(element.title) == nil && nonempty(element.elementDescription) == nil
                && (nonempty(element.identifier) != nil || nonempty(element.domIdentifier) != nil)
            for (field, text, fieldKind) in [
                (SemanticReadField.label, label(for: element), labelIsIdentifier ? .metadata : kind),
                (SemanticReadField.value, element.value, kind),
            ] {
                guard let text = nonempty(text) else { continue }
                let shown = exposedOriginalSpans(text)
                fieldTruncated = fieldTruncated || shown.clipped
                exposures += shown.spans.map { span in
                    SemanticReadFieldExposure(nodeID: String(element.index), field: field,
                        startUTF8: span.lowerBound, endUTF8: span.upperBound, totalUTF8: text.utf8.count,
                        kind: fieldKind, provenance: provenance)
                }
            }
            if element.role == "AXLink", let url = element.url {
                if let exact = AccessibilityObservedLinkURL.validated(url, maximumBytes: 512) {
                    exposures.append(.init(nodeID: String(element.index), field: .linkURL,
                        startUTF8: 0, endUTF8: exact.utf8.count, totalUTF8: exact.utf8.count,
                        kind: .navigation, provenance: provenance))
                } else { fieldTruncated = true }
            }
        }
        return SemanticReadReceipt(id: snapshot.id, sourceID: snapshot.id,
            targetGeneration: "native:\(snapshot.application.processIdentifier)", consistency: .liveValidatedPage,
            view: request.view, query: request.query, subtreeNodeID: request.elementIndex.map(String.init),
            selectedElementCount: nil, selectedFieldCount: nil, sourceTruncated: snapshot.wasTruncated,
            fieldTruncated: fieldTruncated, outputTruncated: outputTruncated, exposures: exposures)
    }

    /// The presentation folds whitespace. Only original bytes actually present
    /// in the normalized, clipped field count: invented join spaces and omitted
    /// whitespace never become a contiguous covered range. Escaping is reversible.
    private func exposedOriginalSpans(_ text: String) -> (spans: [Range<Int>], clipped: Bool) {
        var origins = [Range<Int>?]()
        var whitespace = [Range<Int>]()
        var whitespaceIsSingleSpace = false
        var offset = 0
        for character in text {
            let next = offset + String(character).utf8.count
            if character.isWhitespace {
                whitespace.append(offset..<next)
                whitespaceIsSingleSpace = whitespace.count == 1 && character == " "
            } else {
                if !origins.isEmpty && !whitespace.isEmpty {
                    origins.append(whitespaceIsSingleSpace ? whitespace[0] : nil)
                }
                whitespace.removeAll(keepingCapacity: true)
                whitespaceIsSingleSpace = false
                origins.append(offset..<next)
            }
            offset = next
        }
        let clipped = origins.count > fieldCharacterLimit
        let retained = clipped ? max(0, fieldCharacterLimit - 1) : origins.count
        var spans = [Range<Int>]()
        for origin in origins.prefix(retained) {
            guard let origin else { continue }
            if let last = spans.last, last.upperBound == origin.lowerBound {
                spans[spans.count - 1] = last.lowerBound..<origin.upperBound
            } else { spans.append(origin) }
        }
        return (spans, clipped)
    }

    private func readProvenance(_ element: AccessibilityTreeElement, rootIndex: Int?,
                                observedByIndex: [Int: AccessibilityTreeElement]) -> SemanticReadProvenance {
        guard case let .known(ancestors) = observedAncestry(for: element, rootIndex: rootIndex,
                                                          observedByIndex: observedByIndex) else { return .unknown }
        for index in [element.index] + ancestors {
            guard let node = observedByIndex[index] else { return .unknown }
            switch node.subrole {
            case "AXLandmarkMain": return .main
            case "AXLandmarkNavigation": return .navigation
            case "AXLandmarkComplementary": return .complementary
            case "AXLandmarkBanner": return .banner
            case "AXLandmarkContentInfo": return .contentinfo
            default: if node.role == "AXArticle" { return .article }
            }
        }
        return .unknown
    }

    private func readKind(_ element: AccessibilityTreeElement, provenance: SemanticReadProvenance,
                          rootIndex: Int?, observedByIndex: [Int: AccessibilityTreeElement]) -> SemanticReadContentKind {
        if provenance == .navigation || element.role == "AXLink" { return .navigation }
        let controls: Set<String> = ["AXButton", "AXCheckBox", "AXComboBox", "AXMenuItem", "AXPopUpButton",
            "AXRadioButton", "AXSearchField", "AXSlider", "AXTextField", "AXToolbar", "AXTabGroup"]
        if element.isValueSettable || !element.supportedActions.isEmpty
            || controls.contains(element.role ?? "") { return .control }
        if case let .known(ancestors) = observedAncestry(for: element, rootIndex: rootIndex,
                                                       observedByIndex: observedByIndex),
           ancestors.contains(where: { index in
               guard let parent = observedByIndex[index] else { return false }
               return controls.contains(parent.role ?? "") || parent.isValueSettable
           }) { return .control }
        switch element.role {
        case "AXStaticText", "AXHeading": return .readable
        case "AXWindow", "AXApplication", "AXWebArea", "AXDocument": return .metadata
        default: return .unknown
        }
    }

    private func selectedElements(
        in snapshot: AccessibilityTreeSnapshot,
        bounded: [AccessibilityTreeElement],
        observedByIndex: [Int: AccessibilityTreeElement],
        documentElements: Set<Int>
    ) -> [AccessibilityTreeElement] {
        if let includedElementIndices {
            return Array(bounded.filter { includedElementIndices.contains($0.index) }.prefix(elementLimit))
        }
        guard prioritizesRelevantElements else { return Array(snapshot.elements.prefix(elementLimit)) }

        let hasQuery = preferredText?.isEmpty == false
        let matchesPreferredText = preferredTextMatcher(in: bounded)
        // Search all bounded observations before applying the output count cap.
        // Without a document or a query, preserve native-app selection exactly.
        let candidates = documentElements.isEmpty && !hasQuery
            ? Array(bounded.prefix(elementLimit)) : bounded
        let mainElements = descendantIndices(in: bounded, observedByIndex: observedByIndex) { $0.subrole == "AXLandmarkMain" }
        let ordered = candidates.enumerated().map { offset, element in
            let priority = relevance(of: element, rootIndex: snapshot.rootIndex, documentElements: documentElements,
                                     matchesPreferredText: matchesPreferredText(element))
                + (documentElements.contains(element.index) && mainElements.contains(element.index) ? 2_000 : 0)
            return (element: element, priority: priority, offset: offset)
        }.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.element.index != rhs.element.index { return lhs.element.index < rhs.element.index }
            return lhs.offset < rhs.offset
        }.map(\.element)
        guard !documentElements.isEmpty else { return Array(ordered.prefix(elementLimit)) }

        let rootFrame = bounded.first { $0.index == snapshot.rootIndex && $0.role == "AXWindow" }?.frame
        func isDeemphasized(_ element: AccessibilityTreeElement) -> Bool {
            hasUnhelpfulGeometry(element.frame, windowFrame: rootFrame)
        }
        // Keep one document context in short post-action observations, not every
        // nested document and heading. Headings must share capacity with facts
        // and controls rather than exhaust the budget before either can appear.
        let representativeDocumentIndex = prioritizesFocusedDocument ? ordered.first {
            documentElements.contains($0.index) && !isDeemphasized($0)
                && ["AXWebArea", "AXDocument"].contains($0.role ?? "")
        }?.index : nil
        func isPinned(_ element: AccessibilityTreeElement) -> Bool {
            if element.index == snapshot.rootIndex || element.isFocused == true || matchesPreferredText(element) {
                return true
            }
            return element.index == representativeDocumentIndex
        }
        let pinned = ordered.filter(isPinned)
        let related = queryRelatedElements(
            in: ordered, excluding: Set(pinned.map(\.index)), rootIndex: snapshot.rootIndex,
            documentElements: documentElements, observedByIndex: observedByIndex, windowFrame: rootFrame,
            matchesPreferredText: matchesPreferredText
        )
        let relatedIndices = Set(related.map(\.index))
        let remaining = ordered.filter { !isPinned($0) && !relatedIndices.contains($0.index) }
        let document = remaining.filter { documentElements.contains($0.index) }
        let chrome = remaining.filter { !documentElements.contains($0.index) }
        // A flat action score lets navigation links exhaust the character budget
        // before any readable page text. Alternate both kinds, reusing all spare
        // capacity when one kind is absent. Never change AX identities or frames.
        let usefulDocument = interleavedDocumentElements(document.filter { !isDeemphasized($0) })
        let deemphasizedDocument = interleavedDocumentElements(document.filter(isDeemphasized))
        return Array((pinned + related + usefulDocument + chrome + deemphasizedDocument).prefix(elementLimit))
    }

    /// A literal title match alone can omit its sibling status while unrelated
    /// cards consume a short query budget. Reserve at most six related nodes:
    /// two facts and one action from each of two validated direct groups. Never
    /// search broader ancestors or treat a landmark/document as a card boundary.
    private func queryRelatedElements(
        in ordered: [AccessibilityTreeElement],
        excluding pinnedIndices: Set<Int>,
        rootIndex: Int?,
        documentElements: Set<Int>,
        observedByIndex: [Int: AccessibilityTreeElement],
        windowFrame: WindowFrame?,
        matchesPreferredText: (AccessibilityTreeElement) -> Bool
    ) -> [AccessibilityTreeElement] {
        guard preferredText?.isEmpty == false else { return [] }
        var groups = [Int]()
        for element in ordered where documentElements.contains(element.index) && matchesPreferredText(element) {
            guard let parentIndex = element.parentIndex, !groups.contains(parentIndex),
                  let parent = observedByIndex[parentIndex], parent.role == "AXGroup",
                  parent.subrole?.hasPrefix("AXLandmark") != true,
                  documentElements.contains(parentIndex),
                  case .known(_) = observedAncestry(for: element, rootIndex: rootIndex, observedByIndex: observedByIndex)
            else { continue }
            groups.append(parentIndex)
            if groups.count == 2 { break }
        }
        var facts = [AccessibilityTreeElement]()
        var actions = [AccessibilityTreeElement]()
        for group in groups {
            let siblings = ordered.filter {
                $0.parentIndex == group && observedByIndex[$0.index] != nil && !pinnedIndices.contains($0.index)
                    && !hasUnhelpfulGeometry($0.frame, windowFrame: windowFrame)
            }
            facts.append(contentsOf: siblings.filter {
                $0.role == "AXStaticText" && (label(for: $0) != nil || nonempty($0.value) != nil)
            }.prefix(2))
            actions.append(contentsOf: siblings.filter { $0.role != "AXStaticText" && isInteractive($0) }.prefix(1))
        }
        return facts + actions
    }

    private func isInteractive(_ element: AccessibilityTreeElement) -> Bool {
        !element.supportedActions.isEmpty || element.isValueSettable
            || ["AXButton", "AXCheckBox", "AXComboBox", "AXLink", "AXMenuItem",
                "AXPopUpButton", "AXRadioButton", "AXSearchField", "AXSlider",
                "AXTextArea", "AXTextField"].contains(element.role ?? "")
    }

    private func interleavedDocumentElements(_ elements: [AccessibilityTreeElement]) -> [AccessibilityTreeElement] {
        func isReadable(_ element: AccessibilityTreeElement) -> Bool {
            ["AXHeading", "AXStaticText"].contains(element.role ?? "")
                && (label(for: element) != nil || nonempty(element.value) != nil)
        }
        let headings = elements.filter { isReadable($0) && $0.role == "AXHeading" }
        let facts = elements.filter { isReadable($0) && $0.role != "AXHeading" }
        var readable = [AccessibilityTreeElement]()
        for offset in 0..<max(headings.count, facts.count) {
            if offset < headings.count { readable.append(headings[offset]) }
            if offset < facts.count { readable.append(facts[offset]) }
        }
        let interactive = elements.filter { !isReadable($0) && isInteractive($0) }
        let other = elements.filter { !isReadable($0) && !isInteractive($0) }
        var result = [AccessibilityTreeElement]()
        for offset in 0..<max(readable.count, interactive.count) {
            if offset < readable.count { result.append(readable[offset]) }
            if offset < interactive.count { result.append(interactive[offset]) }
        }
        return result + other
    }

    /// Geometry is only a ranking hint, not proof of AX visibility or occlusion.
    /// Unknown frames stay neutral; queried/focused controls bypass this hint.
    /// Low-ranked nodes remain selectable, including keyboard-only skip links.
    private func hasUnhelpfulGeometry(_ frame: WindowFrame?, windowFrame: WindowFrame?) -> Bool {
        guard let frame else { return false }
        guard frame.x.isFinite, frame.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 1, frame.height > 1 else { return true }
        guard let windowFrame, windowFrame.x.isFinite, windowFrame.y.isFinite,
              windowFrame.width.isFinite, windowFrame.height.isFinite,
              windowFrame.width > 0, windowFrame.height > 0 else { return false }
        let visibleWidth = min(frame.x + frame.width, windowFrame.x + windowFrame.width)
            - max(frame.x, windowFrame.x)
        let visibleHeight = min(frame.y + frame.height, windowFrame.y + windowFrame.height)
            - max(frame.y, windowFrame.y)
        return visibleWidth <= 1 || visibleHeight <= 1
    }

    private func headerLine(
        snapshot: AccessibilityTreeSnapshot,
        app: String,
        bundle: String,
        shownElementCount: Int,
        outputWasTruncated: Bool,
        parentMap: String
    ) -> String {
        let root = snapshot.rootIndex.map(String.init) ?? "-"
        return "AXSNAPSHOT id=\(snapshot.id.uuidString) "
            + "pid=\(snapshot.application.processIdentifier) "
            + "app=\(app) bundle=\(bundle) root=\(root) "
            + "shown=\(shownElementCount) total=\(snapshot.elements.count) "
            + "source_truncated=\(bit(snapshot.wasTruncated)) "
            + "output_truncated=\(bit(outputWasTruncated))\(parentMap)"
    }

    private func elementLine(
        _ element: AccessibilityTreeElement,
        ancestry: String,
        siblingHeading: String,
        truncated: inout Bool
    ) -> String {
        let role = quoted(roleAndSubrole(for: element), truncated: &truncated)
        let label = quoted(label(for: element), truncated: &truncated)
        let value = quoted(element.value, truncated: &truncated)
        let actions = formatActions(element.supportedActions, truncated: &truncated)
        let linkURL = observedLinkURLField(element, truncated: &truncated)

        if usesCompactElementLines {
            let labelField = label == "-" ? "" : " label=\(label)"
            let valueField = value == "-" ? "" : " value=\(value)"
            let settable = element.isValueSettable ? " settable=1" : ""
            let focused = element.isFocused == true ? " focused=1" : ""
            let selected = element.isSelected.map { " selected=\(bit($0))" } ?? ""
            let screenFrame = element.frame.map { " screen_frame=\(format($0))" } ?? ""
            return "#\(element.index) role=\(role)\(labelField)\(valueField) actions=\(actions)"
                + "\(settable)\(focused)\(selected)\(screenFrame)\(linkURL)\(siblingHeading)\(ancestry)"
        }

        let parent = element.parentIndex.map(String.init) ?? "-"
        let frame = element.frame.map(format) ?? "-"
        let enabled = element.isEnabled.map(bit) ?? "-"
        let focused = element.isFocused.map(bit) ?? "-"
        let selected = element.isSelected.map { " selected=\(bit($0))" } ?? ""

        return "#\(element.index) parent=\(parent) role=\(role) "
            + "label=\(label) value=\(value) frame=\(frame) "
            + "enabled=\(enabled) focused=\(focused)\(selected) "
            + "actions=\(actions) settable=\(bit(element.isValueSettable))\(linkURL)"
    }

    /// Expose only a direct structural sibling relationship, not an inferred
    /// semantic owner. The heading may be absent from the emitted line budget,
    /// but its exact ID and bounded source label remain available on the fact.
    private func siblingHeadingField(
        for element: AccessibilityTreeElement,
        rootIndex: Int?,
        observedByIndex: [Int: AccessibilityTreeElement],
        documentElements: Set<Int>,
        headingsByParent: [Int: [AccessibilityTreeElement]],
        truncated: inout Bool
    ) -> String {
        guard element.role == "AXStaticText", let parentIndex = element.parentIndex,
              let parent = observedByIndex[parentIndex], parent.role == "AXGroup",
              parent.subrole?.hasPrefix("AXLandmark") != true, documentElements.contains(parentIndex),
              case .known(_) = observedAncestry(for: element, rootIndex: rootIndex, observedByIndex: observedByIndex),
              let headings = headingsByParent[parentIndex], headings.count == 1,
              let heading = headings.first, observedByIndex[heading.index] != nil,
              let headingLabel = label(for: heading)
        else { return "" }
        return " sibling_heading=#\(heading.index):\(quoted(headingLabel, truncated: &truncated))"
    }

    /// The compact line may outlive its group lines after ranking/budgeting.
    /// Keep source-observed containment explicit so nearby cards cannot lend
    /// each other facts or controls. Common ancestor edges are rendered once
    /// in the header; an incomplete chain contributes no asserted parent path.
    private func compactAncestryField(
        for element: AccessibilityTreeElement,
        rootIndex: Int?,
        observedByIndex: [Int: AccessibilityTreeElement],
        truncated: inout Bool
    ) -> (field: String, ancestors: [Int]) {
        switch observedAncestry(for: element, rootIndex: rootIndex, observedByIndex: observedByIndex) {
        case .known(let ancestors):
            return (" parent=\(element.parentIndex.map(String.init) ?? "-")", ancestors)
        case .unknown:
            return (" parent=- ancestry_unknown=1", [])
        case .truncated:
            truncated = true
            return (" parent=- ancestry_truncated=1", [])
        }
    }

    private enum ObservedAncestry {
        case known([Int])
        case unknown
        case truncated
    }

    private func observedAncestry(
        for element: AccessibilityTreeElement,
        rootIndex: Int?,
        observedByIndex: [Int: AccessibilityTreeElement]
    ) -> ObservedAncestry {
        guard let rootIndex, observedByIndex[element.index] != nil else { return .unknown }
        var current = element
        var ancestors = [Int]()
        var visited: Set<Int> = [element.index]
        while true {
            if current.index == rootIndex {
                guard current.parentIndex == nil else { return .unknown }
                return .known(ancestors)
            }
            guard let parentIndex = current.parentIndex else { return .unknown }
            guard ancestors.count < maximumAncestorDepth else { return .truncated }
            guard let parent = observedByIndex[parentIndex],
                  visited.insert(parentIndex).inserted else { return .unknown }
            ancestors.append(parentIndex)
            current = parent
        }
    }

    /// A navigation destination must remain exact. Unlike display labels, an
    /// over-budget URL is omitted, never abbreviated into a different target.
    private func observedLinkURLField(
        _ element: AccessibilityTreeElement,
        truncated: inout Bool
    ) -> String {
        guard element.role == "AXLink", let raw = element.url else { return "" }
        guard let exact = AccessibilityObservedLinkURL.validated(raw, maximumBytes: 512) else {
            truncated = true
            return " url_omitted=1"
        }
        let escaped = exact.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return " url=\"\(escaped)\""
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

    private func uniqueElementsByIndex(in bounded: [AccessibilityTreeElement]) -> [Int: AccessibilityTreeElement] {
        var byIndex = [Int: AccessibilityTreeElement]()
        var duplicateIndices = Set<Int>()
        for element in bounded {
            if byIndex.updateValue(element, forKey: element.index) != nil {
                duplicateIndices.insert(element.index)
            }
        }
        for index in duplicateIndices { byIndex.removeValue(forKey: index) }
        return byIndex
    }

    /// Membership comes only from the observed parent chain, never a label or
    /// application name. Memoization bounds work to the snapshot's 2,000-node
    /// maximum; missing/duplicate parents and cycles do not establish ancestry.
    private func descendantIndices(
        in bounded: [AccessibilityTreeElement],
        observedByIndex byIndex: [Int: AccessibilityTreeElement],
        matching isAncestor: (AccessibilityTreeElement) -> Bool
    ) -> Set<Int> {
        var membership = [Int: Bool]()
        for element in bounded {
            var cursor = element.index
            var path = [Int]()
            var visited = Set<Int>()
            var belongsToDocument = false
            while let current = byIndex[cursor], path.count < byIndex.count {
                if let known = membership[cursor] {
                    belongsToDocument = known
                    break
                }
                guard visited.insert(cursor).inserted else { break }
                path.append(cursor)
                if isAncestor(current) {
                    belongsToDocument = true
                    break
                }
                guard let parent = current.parentIndex else { break }
                cursor = parent
            }
            for index in path { membership[index] = belongsToDocument }
        }
        return Set(membership.compactMap { $0.value ? $0.key : nil })
    }

    private func relevance(
        of element: AccessibilityTreeElement,
        rootIndex: Int?,
        documentElements: Set<Int>,
        matchesPreferredText: Bool
    ) -> Int {
        if element.index == rootIndex { return 10_000 }

        // Page controls must outrank tab/toolbar controls even when no query is
        // supplied. Keep the focused control above page content (for example an
        // omnibox after typing), and preserve native-app ranking without a
        // document. Explicit text matches below remain the strongest signal.
        var score = documentElements.contains(element.index) ? 3_000 : 0
        if element.isFocused == true, prioritizesFocusedDocument || !documentElements.isEmpty {
            score = max(score, 8_000)
        }
        if prioritizesFocusedDocument {
            // Short post-action observations should verify the changed field
            // and document before spending the budget on browser tab labels.
            switch nonempty(element.role) {
            case "AXHeading": score = max(score, 6_000)
            case "AXWebArea", "AXDocument": score = max(score, 5_000)
            default: break
            }
        }
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
        let hasLabel = label(for: element) != nil
        let hasValue = nonempty(element.value) != nil
        if documentElements.contains(element.index), ["AXHeading", "AXStaticText"].contains(element.role ?? "") {
            // AX providers expose the same readable page text through different
            // fields. Presence is one signal, not a preference for labels or a
            // double bonus when both fields happen to be populated.
            if hasLabel || hasValue { score += 400 }
        } else {
            // Preserve native-app and interactive-control relevance semantics.
            if hasLabel { score += 400 }
            if hasValue { score += 300 }
        }
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

    private func preferredTextMatcher(in elements: [AccessibilityTreeElement]) -> (AccessibilityTreeElement) -> Bool {
        guard let query = preferredText, !query.isEmpty else { return { _ in false } }
        let literal: (AccessibilityTreeElement) -> Bool = {
            self.searchableText(for: $0).localizedCaseInsensitiveContains(query)
        }
        // A typographic variant must not displace an existing literal match,
        // even when that match lies beyond the eventual output count/budget.
        if elements.contains(where: literal) { return literal }
        let key = normalizedQueryText(query)
        guard !key.isEmpty else { return { _ in false } }
        // Cache matching original fields, not indices: malformed duplicate IDs
        // must not transfer a match to a different element. Never normalize
        // identifiers, roles, URLs, or phrases assembled across separate fields.
        let fields = Set(elements.flatMap(readableQueryFields).filter {
            normalizedQueryText($0).localizedCaseInsensitiveContains(key)
        })
        return { self.readableQueryFields($0).contains(where: fields.contains) }
    }

    private func readableQueryFields(_ element: AccessibilityTreeElement) -> [String] {
        [element.title, element.elementDescription, element.help, element.value].compactMap(nonempty)
    }

    private func normalizedQueryText(_ value: String) -> String {
        var output = ""
        var spacePending = false
        for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.isWhitespace {
                spacePending = !output.isEmpty
                continue
            }
            if spacePending { output.append(" "); spacePending = false }
            switch scalar.value {
            case 0x2018, 0x2019: output.append("'")
            case 0x201C, 0x201D: output.append("\"")
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
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
        let executableActions = actions.filter {
            guard let action = SemanticAXAction(rawValue: $0) else { return false }
            return allowsRaise || action != .raise
        }
        let shownActions = executableActions.prefix(actionLimit)
        if executableActions.count > shownActions.count {
            truncated = true
        }

        return "[" + shownActions.map { action in
            quoted(action, truncated: &truncated)
        }.joined(separator: ",") + "]"
    }

    private func presentedActions(_ actions: [String]) -> [String] {
        Array(actions.filter {
            guard let action = SemanticAXAction(rawValue: $0) else { return false }
            return allowsRaise || action != .raise
        }.prefix(actionLimit)).filter { $0.count <= fieldCharacterLimit }
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

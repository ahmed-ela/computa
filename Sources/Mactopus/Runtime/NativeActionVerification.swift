import AutomationCore
import CryptoKit
import Foundation

/// Native postconditions are armed from observed controls before dispatch.
/// Labels/array positions never become cross-snapshot identity. Window and
/// session lifetime remain guarded by the native owner around every read.
enum NativeActionVerification {
    enum Action: Equatable, Sendable { case press, setText(String) }
    enum Kind: String, Codable, Equatable, Sendable {
        case selection, value
        case detailView = "detail_view"
        case regionText = "region_text"
    }
    struct Request: Codable, Equatable, Sendable {
        let kind: Kind
        let expected: String
        var elementIndex: Int? = nil
        var detailElementIndex: Int? = nil
    }
    struct Scope: Codable, Equatable, Sendable {
        let evidenceTargetID: String
        let processIdentifier: Int32
        var bundleIdentifier: String? = nil
    }
    struct Observation: Equatable, Sendable {
        let snapshot: AccessibilityTreeSnapshot
        let exposedIndices: Set<Int>
        let isLive: Bool
    }
    struct Anchor: Codable, Equatable, Sendable {
        let token: UUID?
        let identifier: String?
        let role: String
        let subrole: String?
        let document: String
        let semanticsFingerprint: String
        let includesValue: Bool
        var propertyKey: String {
            if let token { return "token:\(token.uuidString)" }
            return "stable:" + digest([document, identifier ?? "", role, subrole ?? ""])
        }
    }
    struct Plan: Codable, Equatable, Sendable {
        let kind: Kind
        let scope: Scope
        let expected: String
        let anchor: Anchor
        let actionAnchor: Anchor
        let baselineFingerprint: String
        let baselineSnapshotID: UUID
        let baselineSatisfied: Bool
        let presentationQuery: String?
        let actionSelectionBaseline: Bool?
        let detailBaselineMatched: Bool
        var alreadySatisfied: Bool { baselineSatisfied }
        var property: String { "native:\(anchor.propertyKey):\(kind.rawValue)" }

        func validate() throws { try NativeActionVerification.validate(self) }
        func evaluate(scope: Scope, observation: Observation) throws -> Proof {
            try NativeActionVerification.evaluate(self, scope: scope, observation: observation)
        }
        func revalidateBaseline(observation: Observation) throws {
            try NativeActionVerification.revalidateBaseline(self, observation: observation)
        }
        func actionElementIndex(in observation: Observation) throws -> Int {
            try validate(); try check(scope, observation)
            return try Graph(observation.snapshot).resolve(actionAnchor).index
        }
    }
    struct Proof: Codable, Equatable, Sendable {
        let property: String
        let expectedValue: String
        let observationID: UUID
    }
    enum Failure: Error, LocalizedError, Equatable {
        case invalidPlan, invalidRequest, wrongTarget, staleObservation, incompleteEvidence
        case unexposedElement, unstableIdentity, ambiguousIdentity, missingProperty
        case baselineChanged, postconditionNotObserved
        var errorDescription: String? {
            switch self {
            case .invalidPlan: return "The saved native verification plan is invalid."
            case .invalidRequest: return "The native postcondition does not match the observed target and result region."
            case .wrongTarget: return "The native verification process, document or bound scope changed."
            case .staleObservation: return "Native verification requires a fresh live observation. No action was repeated."
            case .incompleteEvidence: return "The native result evidence is incomplete; it cannot establish this postcondition."
            case .unexposedElement: return "The requested native verification target was not exposed in the current observation."
            case .unstableIdentity: return "The native control has no retained exact AX identity or unique stable identifier."
            case .ambiguousIdentity: return "The native verification identity or detail label is ambiguous."
            case .missingProperty: return "The native control did not expose the required selected state or value."
            case .baselineChanged: return "The native baseline changed before input. Observe again; no input was sent."
            case .postconditionNotObserved: return "The declared native postcondition was not observed. No action was repeated."
            }
        }
    }
    private static let maximumTextBytes = 8_192
    private static let regionRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXToolbar", "AXTable", "AXList", "AXOutline"]

    static func compile(request: Request? = nil, action: Action, elementIndex: Int,
                        observation: Observation, scope: Scope) throws -> Plan? {
        try check(scope, observation)
        let graph = try Graph(observation.snapshot)
        let selected = try exposed(elementIndex, observation, graph)
        guard selected.isEnabled != false else { throw Failure.invalidRequest }
        let inferred: Request?
        switch action {
        case .setText(let text): inferred = .init(kind: .value, expected: text, elementIndex: elementIndex)
        case .press: inferred = selected.isSelected.map { _ in .init(kind: .selection, expected: "true", elementIndex: elementIndex) }
        }
        guard let request = request ?? inferred else { return nil }
        let actionAnchor = try graph.anchor(selected, includeValue: action == .press)
        let target: AccessibilityTreeElement
        var expected = request.expected
        let baseline: String
        let satisfied: Bool
        var detailBaselineMatched = false
        switch request.kind {
        case .selection:
            guard action == .press, request.detailElementIndex == nil,
                  request.elementIndex == nil || request.elementIndex == elementIndex,
                  ["true", "false"].contains(expected) else { throw Failure.invalidRequest }
            target = selected
            guard let value = selected.isSelected else { throw Failure.missingProperty }
            baseline = value ? "true" : "false"; satisfied = baseline == expected
        case .value:
            guard request.detailElementIndex == nil else { throw Failure.invalidRequest }
            switch action {
            case .setText(let text):
                guard selected.isValueSettable, text == expected,
                      request.elementIndex == nil || request.elementIndex == elementIndex else { throw Failure.invalidRequest }
                target = selected
            case .press:
                guard let index = request.elementIndex else { throw Failure.invalidRequest }
                target = try exposed(index, observation, graph)
            }
            baseline = try graph.exactValue(target); satisfied = baseline == expected
        case .regionText:
            guard action == .press, request.detailElementIndex == nil, let index = request.elementIndex else { throw Failure.invalidRequest }
            target = try exposed(index, observation, graph)
            guard regionRoles.contains(target.role ?? "") else { throw Failure.invalidRequest }
            expected = canonical(expected)
            guard !expected.isEmpty else { throw Failure.invalidRequest }
            baseline = try graph.regionText(target); satisfied = baseline == expected
        case .detailView:
            guard action == .press, request.elementIndex == nil, let index = request.detailElementIndex else { throw Failure.invalidRequest }
            target = try exposed(index, observation, graph)
            guard regionRoles.contains(target.role ?? ""), !graph.isAncestor(target.index, of: selected.index),
                  !graph.isAncestor(selected.index, of: target.index), target.index != selected.index else { throw Failure.invalidRequest }
            try graph.requireComplete()
            expected = canonical(expected)
            guard !expected.isEmpty else { throw Failure.invalidRequest }
            try graph.requireUniqueTargetText(expected, target: selected, missing: .invalidRequest)
            let matches = try graph.detailMatches(expected, region: target)
            guard matches <= 1 else { throw Failure.ambiguousIdentity }
            baseline = try graph.regionText(target)
            detailBaselineMatched = matches == 1
            satisfied = matches == 1 && (selected.isSelected ?? true)
        }
        let resultAnchor = request.kind == .selection ? actionAnchor : try graph.anchor(target)
        let plan = Plan(kind: request.kind, scope: scope, expected: expected, anchor: resultAnchor,
            actionAnchor: actionAnchor, baselineFingerprint: fingerprint(baseline), baselineSnapshotID: observation.snapshot.id,
            baselineSatisfied: satisfied,
            presentationQuery: [target.title, target.elementDescription, selected.title, selected.elementDescription]
                .compactMap { $0 }.map(canonical).first { !$0.isEmpty && $0.utf8.count <= 512 },
            actionSelectionBaseline: request.kind == .detailView ? selected.isSelected : nil,
            detailBaselineMatched: detailBaselineMatched)
        try plan.validate()
        return plan
    }

    static func evaluate(_ plan: Plan, scope: Scope, observation: Observation) throws -> Proof {
        try plan.validate(); try check(scope, observation)
        guard plan.scope == scope else { throw Failure.wrongTarget }
        guard observation.snapshot.id != plan.baselineSnapshotID || plan.baselineSatisfied else { throw Failure.staleObservation }
        let graph = try Graph(observation.snapshot)
        let target = try graph.resolve(plan.anchor)
        let observed: String
        switch plan.kind {
        case .selection:
            guard let selected = target.isSelected else { throw Failure.missingProperty }
            observed = selected ? "true" : "false"
        case .value: observed = try graph.exactValue(target)
        case .regionText: observed = try graph.regionText(target)
        case .detailView:
            let actionTarget = try graph.resolve(plan.actionAnchor)
            try graph.requireUniqueTargetText(plan.expected, target: actionTarget, missing: .wrongTarget)
            if plan.actionSelectionBaseline != nil, actionTarget.isSelected != true { throw Failure.postconditionNotObserved }
            let matches = try graph.detailMatches(plan.expected, region: target)
            guard matches == 1 else { throw matches > 1 ? Failure.ambiguousIdentity : Failure.postconditionNotObserved }
            let rendered = try graph.regionText(target)
            let selectionChanged = plan.actionSelectionBaseline == false && actionTarget.isSelected == true
            guard plan.baselineSatisfied || selectionChanged || fingerprint(rendered) != plan.baselineFingerprint else { throw Failure.postconditionNotObserved }
            observed = plan.expected
        }
        guard observed == plan.expected else { throw Failure.postconditionNotObserved }
        if !plan.baselineSatisfied, plan.kind != .detailView,
           fingerprint(observed) == plan.baselineFingerprint { throw Failure.postconditionNotObserved }
        return Proof(property: plan.property, expectedValue: observed, observationID: observation.snapshot.id)
    }

    private static func revalidateBaseline(_ plan: Plan, observation: Observation) throws {
        try plan.validate(); try check(plan.scope, observation)
        let graph = try Graph(observation.snapshot)
        let actionTarget = try graph.resolve(plan.actionAnchor)
        if plan.kind == .detailView {
            try graph.requireUniqueTargetText(plan.expected, target: actionTarget, missing: .baselineChanged)
        }
        if let selected = plan.actionSelectionBaseline, actionTarget.isSelected != selected { throw Failure.baselineChanged }
        let target = try graph.resolve(plan.anchor)
        let baseline: String
        switch plan.kind {
        case .selection:
            guard let selected = target.isSelected else { throw Failure.missingProperty }
            baseline = selected ? "true" : "false"
        case .value: baseline = try graph.exactValue(target)
        case .regionText, .detailView: baseline = try graph.regionText(target)
        }
        guard fingerprint(baseline) == plan.baselineFingerprint else { throw Failure.baselineChanged }
    }

    private static func validate(_ plan: Plan) throws {
        guard validScope(plan.scope), plan.expected.utf8.count <= maximumTextBytes,
              (plan.presentationQuery?.utf8.count ?? 0) <= 512,
              plan.baselineFingerprint.count == 64,
              plan.baselineFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidPlan }
        for anchor in [plan.anchor, plan.actionAnchor] {
            guard (anchor.token != nil) != (anchor.identifier != nil), !anchor.role.isEmpty, anchor.role.utf8.count <= 256,
                  (anchor.subrole?.utf8.count ?? 0) <= 256, anchor.document.utf8.count <= 8_192,
                  anchor.semanticsFingerprint.count == 64,
                  !anchor.document.isEmpty, anchor.identifier.map({ !$0.isEmpty && $0.utf8.count <= 4_096 }) ?? true else { throw Failure.invalidPlan }
        }
        switch plan.kind {
        case .selection:
            guard ["true", "false"].contains(plan.expected), plan.anchor == plan.actionAnchor else { throw Failure.invalidPlan }
        case .value: break
        case .detailView, .regionText:
            guard !plan.expected.isEmpty, canonical(plan.expected) == plan.expected,
                  regionRoles.contains(plan.anchor.role) else { throw Failure.invalidPlan }
            if plan.kind == .detailView, plan.anchor == plan.actionAnchor { throw Failure.invalidPlan }
        }
        if plan.kind != .detailView {
            guard plan.baselineSatisfied == (plan.baselineFingerprint == fingerprint(plan.expected)),
                  plan.actionSelectionBaseline == nil, !plan.detailBaselineMatched else { throw Failure.invalidPlan }
        } else {
            guard plan.baselineSatisfied == (plan.detailBaselineMatched && (plan.actionSelectionBaseline ?? true)) else { throw Failure.invalidPlan }
        }
    }

    private static func check(_ scope: Scope, _ observation: Observation) throws {
        guard validScope(scope), observation.snapshot.application.processIdentifier == scope.processIdentifier,
              observation.snapshot.application.bundleIdentifier == scope.bundleIdentifier else { throw Failure.wrongTarget }
        guard observation.isLive else { throw Failure.staleObservation }
    }
    private static func validScope(_ scope: Scope) -> Bool {
        !scope.evidenceTargetID.isEmpty && scope.evidenceTargetID.utf8.count <= 256 && scope.processIdentifier > 0
            && (scope.bundleIdentifier?.utf8.count ?? 0) <= 256
    }
    private static func exposed(_ index: Int, _ observation: Observation, _ graph: Graph) throws -> AccessibilityTreeElement {
        guard observation.exposedIndices.contains(index), let element = graph.byIndex[index] else { throw Failure.unexposedElement }
        return element
    }
    private static func canonical(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func textFields(_ element: AccessibilityTreeElement) -> [String] {
        Array(Set([element.title, element.elementDescription, element.value].compactMap { $0 }.map(canonical).filter { !$0.isEmpty }))
    }
    private static func semantics(_ element: AccessibilityTreeElement, includesValue: Bool) -> String {
        digest([element.title ?? "", element.elementDescription ?? "", element.identifier ?? "", element.domIdentifier ?? ""]
            + (includesValue ? [element.value ?? ""] : []))
    }
    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func digest(_ values: [String]) -> String {
        fingerprint(String(data: (try? JSONEncoder().encode(values)) ?? Data(), encoding: .utf8) ?? "")
    }

    private struct Graph {
        let snapshot: AccessibilityTreeSnapshot
        let byIndex: [Int: AccessibilityTreeElement]
        init(_ snapshot: AccessibilityTreeSnapshot) throws {
            guard snapshot.elements.count <= 2_000 else { throw Failure.incompleteEvidence }
            var map: [Int: AccessibilityTreeElement] = [:]
            for element in snapshot.elements {
                guard element.index >= 0, map[element.index] == nil else { throw Failure.incompleteEvidence }
                map[element.index] = element
            }
            self.snapshot = snapshot; byIndex = map
        }
        func requireComplete() throws {
            guard !snapshot.wasTruncated, let root = snapshot.rootIndex, byIndex[root]?.parentIndex == nil,
                  snapshot.elements.filter({ $0.parentIndex == nil }).count == 1,
                  snapshot.elements.allSatisfy({ $0.evidenceFieldsTruncated != true }) else { throw Failure.incompleteEvidence }
            for element in snapshot.elements {
                guard Set(element.childIndices).count == element.childIndices.count else { throw Failure.incompleteEvidence }
                for child in element.childIndices { guard byIndex[child]?.parentIndex == element.index else { throw Failure.incompleteEvidence } }
                if let parent = element.parentIndex { guard byIndex[parent]?.childIndices.contains(element.index) == true else { throw Failure.incompleteEvidence } }
                _ = try document(of: element)
            }
        }
        func document(of element: AccessibilityTreeElement) throws -> String {
            var cursor = element; var seen = Set<Int>()
            while true {
                guard seen.insert(cursor.index).inserted, seen.count <= 128 else { throw Failure.incompleteEvidence }
                if cursor.role == "AXWebArea" || cursor.role == "AXDocument" {
                    guard let url = cursor.url, let parsed = URL(string: url), parsed.scheme != nil else { throw Failure.wrongTarget }
                    return url
                }
                guard let parent = cursor.parentIndex else {
                    guard snapshot.rootIndex == cursor.index else { throw Failure.incompleteEvidence }
                    return "native-window"
                }
                guard let next = byIndex[parent] else { throw Failure.incompleteEvidence }
                cursor = next
            }
        }
        func anchor(_ element: AccessibilityTreeElement, includeValue: Bool = false) throws -> Anchor {
            guard let role = element.role, !role.isEmpty else { throw Failure.unstableIdentity }
            guard element.evidenceFieldsTruncated != true else { throw Failure.incompleteEvidence }
            let document = try document(of: element)
            if let token = element.evidenceIdentity {
                guard snapshot.elements.filter({ $0.evidenceIdentity == token }).count == 1 else { throw Failure.ambiguousIdentity }
                return Anchor(token: token, identifier: nil, role: role, subrole: element.subrole, document: document,
                              semanticsFingerprint: semantics(element, includesValue: includeValue), includesValue: includeValue)
            }
            try requireComplete()
            guard let identifier = element.identifier, !identifier.isEmpty,
                  identifier.count < snapshot.limits.maxTextLength else { throw Failure.unstableIdentity }
            guard snapshot.elements.filter({ $0.identifier == identifier }).count == 1 else { throw Failure.ambiguousIdentity }
            return Anchor(token: nil, identifier: identifier, role: role, subrole: element.subrole, document: document,
                          semanticsFingerprint: semantics(element, includesValue: includeValue), includesValue: includeValue)
        }
        func resolve(_ anchor: Anchor) throws -> AccessibilityTreeElement {
            let matches: [AccessibilityTreeElement]
            if let token = anchor.token { matches = snapshot.elements.filter { $0.evidenceIdentity == token } }
            else {
                try requireComplete()
                matches = snapshot.elements.filter { $0.identifier == anchor.identifier }
            }
            guard matches.count == 1 else { throw matches.isEmpty ? Failure.unstableIdentity : Failure.ambiguousIdentity }
            let target = matches[0]
            guard target.evidenceFieldsTruncated != true else { throw Failure.incompleteEvidence }
            guard target.role == anchor.role, target.subrole == anchor.subrole, try document(of: target) == anchor.document,
                  semantics(target, includesValue: anchor.includesValue) == anchor.semanticsFingerprint else { throw Failure.wrongTarget }
            return target
        }
        func exactValue(_ element: AccessibilityTreeElement) throws -> String {
            guard let value = element.value else { throw Failure.missingProperty }
            guard element.evidenceFieldsTruncated != true, value.utf8.count <= maximumTextBytes,
                  element.evidenceFieldsTruncated == false || !snapshot.wasTruncated || value.count < snapshot.limits.maxTextLength else { throw Failure.incompleteEvidence }
            return value
        }
        func isAncestor(_ ancestor: Int, of index: Int) -> Bool {
            var current = byIndex[index]?.parentIndex; var seen = Set<Int>()
            while let value = current, seen.insert(value).inserted {
                if value == ancestor { return true }; current = byIndex[value]?.parentIndex
            }
            return false
        }
        func subtree(_ root: AccessibilityTreeElement) throws -> [AccessibilityTreeElement] {
            try requireComplete()
            var result: [AccessibilityTreeElement] = []; var pending = [root]; var seen = Set<Int>()
            while let element = pending.popLast() {
                guard seen.insert(element.index).inserted, seen.count <= 2_000 else { throw Failure.incompleteEvidence }
                result.append(element)
                for index in element.childIndices.reversed() {
                    guard let child = byIndex[index] else { throw Failure.incompleteEvidence }; pending.append(child)
                }
            }
            return result
        }
        func regionText(_ root: AccessibilityTreeElement) throws -> String {
            let leaves = try subtree(root).filter { $0.childIndices.isEmpty }
            let text = leaves.compactMap { element -> String? in
                [element.value, element.title, element.elementDescription].compactMap { $0 }.map(canonical).first { !$0.isEmpty }
            }.joined(separator: " ")
            guard text.utf8.count <= maximumTextBytes else { throw Failure.incompleteEvidence }
            return text
        }
        func detailMatches(_ expected: String, region: AccessibilityTreeElement) throws -> Int {
            // Exact rendered leaf fields only, not aggregate container names
            // duplicated from their children and never another list's label.
            try subtree(region).filter { $0.childIndices.isEmpty && textFields($0).contains(expected) }.count
        }
        func requireUniqueTargetText(_ expected: String, target: AccessibilityTreeElement, missing: Failure) throws {
            try requireComplete()
            // Virtualized lists may keep the row's AX object while replacing
            // its descendant label. Keep that exact observed label attached
            // to the intended row, and count duplicate rows even when their
            // names are exposed only by descendants, not the row itself.
            var matchingTargets = Set<Int>()
            for element in snapshot.elements where textFields(element).contains(expected) {
                var cursor: AccessibilityTreeElement? = element
                var seen = Set<Int>()
                while let current = cursor {
                    guard seen.insert(current.index).inserted, seen.count <= 128 else { throw Failure.incompleteEvidence }
                    if current.role == target.role { matchingTargets.insert(current.index) }
                    cursor = current.parentIndex.flatMap { byIndex[$0] }
                }
            }
            guard matchingTargets.contains(target.index) else { throw missing }
            guard matchingTargets.count == 1 else { throw Failure.ambiguousIdentity }
        }
    }
}

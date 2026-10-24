import CryptoKit
import Foundation

/// A bounded postcondition selected before input. Plans contain no executable
/// selectors and cannot retarget a mutation. Only the host can compile them
/// from the exact observed control and evaluate them against a fresh read.
enum BrowserActionVerification {
    enum Kind: String, Codable, Equatable, Sendable {
        case documentURL = "document_url"
        case value
        case regionText = "region_text"
        case regionChanged = "region_changed"
        case dialogOpened = "dialog_opened"
        case detailView = "detail_view"
    }

    enum Action: Equatable, Sendable { case press, setText(String) }

    struct Request: Codable, Equatable, Sendable {
        let kind: Kind
        var elementIndex: Int? = nil
        let expected: String
    }

    struct Scope: Codable, Equatable, Sendable {
        let browserGeneration: UUID
        let targetID: String
        let targetInstanceToken: String
        let tabHandle: UUID
        let documentEpoch: UUID
        let loaderID: String
        let documentURL: String
        /// BrowserDocumentObservation is produced from the main-frame
        /// capture; subframe identity is not inferred from matching text.
        let frame: String

        var evidenceTargetID: String { "browser:\(browserGeneration):\(targetID)" }
    }

    struct Sibling: Codable, Equatable, Sendable {
        let backendNodeID: Int64
        let role: String
        let nameFingerprint: String
    }

    struct Anchor: Codable, Equatable, Sendable {
        let backendNodeID: Int64
        let role: String
        let name: String
        let parentBackendNodeID: Int64?
        let parentRole: String?
        let parentNameFingerprint: String?
        let childPosition: Int?
        let siblings: [Sibling]?
        let childRoles: [String]
    }

    /// Main-frame identity retained for an absence-to-exposure predicate.
    /// AX exposure is not pixel visibility and carries no dialog content claim.
    struct DialogBaseline: Codable, Equatable, Sendable {
        let rootBackendNodeID: Int64
        let rootRole: String
    }

    struct Plan: Codable, Equatable, Sendable {
        let kind: Kind
        let expected: String
        let baselineFingerprint: String
        let scope: Scope
        let anchor: Anchor?
        let baselineSnapshotID: UUID
        let dialogBaseline: DialogBaseline?

        init(kind: Kind, expected: String, baselineFingerprint: String, scope: Scope,
             anchor: Anchor?, baselineSnapshotID: UUID, dialogBaseline: DialogBaseline? = nil) {
            self.kind = kind; self.expected = expected; self.baselineFingerprint = baselineFingerprint
            self.scope = scope; self.anchor = anchor; self.baselineSnapshotID = baselineSnapshotID
            self.dialogBaseline = dialogBaseline
        }

        var property: String {
            switch kind {
            case .documentURL: return "document_url"
            case .value: return "node:\(anchor?.backendNodeID ?? -1):value"
            case .regionText: return "planned:region_text:\(anchor?.backendNodeID ?? -1)"
            case .regionChanged: return "planned:region_changed:\(anchor?.backendNodeID ?? -1)"
            case .dialogOpened: return "planned:dialog_opened"
            case .detailView: return "planned:detail_view:heading"
            }
        }

        func validate() throws { try BrowserActionVerification.validate(self) }

        func evaluate(binding: BrowserTabBinding, snapshot: BrowserTabSnapshot) throws -> Proof {
            try BrowserActionVerification.evaluate(self, snapshot: snapshot, binding: binding)
        }

        func revalidateBaseline(binding: BrowserTabBinding, document: BrowserDocumentObservation) throws {
            try validate()
            try binding.lifetime.check()
            guard binding.browserGeneration == scope.browserGeneration, binding.targetID == scope.targetID,
                  binding.targetInstanceToken == scope.targetInstanceToken, binding.handle == scope.tabHandle else {
                throw Failure.wrongTarget
            }
            guard binding.documentEpoch == scope.documentEpoch else { throw Failure.wrongDocument }
            try revalidateBaseline(document: document)
        }

        /// Called again at the browser adapter's final observation. This
        /// narrows, but cannot eliminate, changes between separate browser reads
        /// and the event handler; it never authorizes another dispatch.
        func revalidateBaseline(document: BrowserDocumentObservation) throws {
            try BrowserActionVerification.revalidateBaseline(self, document: document)
        }
    }

    struct Proof: Codable, Equatable, Sendable {
        let property: String
        let expectedValue: String
        let observationID: UUID
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidPlan
        case invalidRequest
        case staleObservation
        case wrongTarget
        case wrongDocument
        case incompleteEvidence
        case ambiguousAnchor
        case missingAnchor
        case unsupportedRegion
        case baselineUnavailable
        case baselineAlreadySatisfied
        case dialogAlreadyOpen
        case baselineChanged
        case postconditionNotObserved

        var errorDescription: String? {
            switch self {
            case .invalidPlan: return "The saved browser verification plan is invalid."
            case .invalidRequest: return "The browser postcondition does not match the observed action target."
            case .staleObservation: return "Browser outcome verification requires a new live observation. No action was repeated."
            case .wrongTarget: return "The browser verification target changed. No action was repeated."
            case .wrongDocument: return "The browser document changed outside the planned postcondition."
            case .incompleteEvidence: return "The browser source evidence is incomplete; this cannot prove the postcondition."
            case .ambiguousAnchor: return "The browser verification anchor is ambiguous."
            case .missingAnchor: return "The browser verification anchor is unavailable."
            case .unsupportedRegion: return "Select an observed semantic container for region verification, not a text child."
            case .baselineUnavailable: return "The required browser pre-action evidence is unavailable. Do not repeat input."
            case .baselineAlreadySatisfied: return "The postcondition already held before input; it does not verify a changed outcome."
            case .dialogAlreadyOpen: return "A dialog already existed before input, so dialog_opened cannot establish a newly opened dialog."
            case .baselineChanged: return "The planned pre-action state changed before dispatch. Observe again; no input was sent."
            case .postconditionNotObserved: return "The planned browser postcondition has not been observed. No action was repeated."
            }
        }
    }

    /// Correlation only, captured before dispatch. A backend node number can
    /// be reused after navigation or target replacement. Neither fresh opaque
    /// snapshot IDs nor model arguments may define this document identity.
    static func recoveryScope(binding: BrowserTabBinding, snapshot: BrowserTabSnapshot) -> String? {
        guard snapshot.isLiveObservation, snapshot.tabHandle == binding.handle,
              snapshot.documentEpoch == binding.documentEpoch, !snapshot.loaderID.isEmpty,
              (try? binding.lifetime.check()) != nil else { return nil }
        let fields = [binding.browserGeneration.uuidString, binding.targetID,
                      binding.targetInstanceToken, binding.handle.uuidString,
                      binding.documentEpoch.uuidString, snapshot.loaderID,
                      snapshot.documentURL.absoluteString]
        guard let data = try? JSONEncoder().encode(fields) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let maximumTextBytes = 8_192
    private static let maximumNodes = 12_000
    private static let maximumAnchorChildren = 128
    private static let dialogOpenerRoles: Set<String> = ["button", "menuitem"]
    private static let dialogRoles: Set<String> = ["dialog", "alertdialog"]
    private static let regionRoles: Set<String> = [
        "status", "region", "alert", "log", "group", "tabpanel", "dialog", "article", "section", "form",
    ]

    /// A nil request derives only exact link navigation and exact field value.
    /// An arbitrary press has no inferred meaning and keeps its ordinary debt.
    static func compile(request: Request? = nil, action: Action, elementIndex: Int,
                        snapshot: BrowserTabSnapshot, binding: BrowserTabBinding) throws -> Plan? {
        try checkObservation(snapshot, binding: binding)
        guard let selected = snapshot.element(at: elementIndex), selected.isEnabled else {
            throw Failure.invalidRequest
        }
        let scope = observationScope(snapshot, binding: binding)
        let inferred: Request?
        switch action {
        case .setText(let value): inferred = Request(kind: .value, elementIndex: elementIndex, expected: value)
        case .press:
            inferred = observedDestination(selected, at: snapshot.documentURL).map {
                Request(kind: .documentURL, expected: $0)
            }
        }
        guard let request = request ?? inferred else { return nil }
        var expected = request.expected
        let baseline: String
        let anchor: Anchor?
        var dialogBaseline: DialogBaseline?
        switch request.kind {
        case .documentURL:
            guard action == .press, request.elementIndex == nil,
                  observedDestination(selected, at: snapshot.documentURL) == expected else {
                throw Failure.invalidRequest
            }
            baseline = scope.documentURL
            anchor = nil
        case .value:
            let valueElement: BrowserTabElement
            switch action {
            case .setText(let text):
                guard selected.supportsSetText, text == expected,
                      request.elementIndex == nil || request.elementIndex == elementIndex else { throw Failure.invalidRequest }
                valueElement = selected
            case .press:
                guard let index = request.elementIndex, let observed = snapshot.element(at: index) else {
                    throw Failure.invalidRequest
                }
                valueElement = observed
            }
            guard let previous = valueElement.value else { throw Failure.baselineUnavailable }
            baseline = previous
            anchor = exactAnchor(valueElement)
        case .regionText:
            guard action == .press, let index = request.elementIndex,
                  let region = snapshot.element(at: index) else { throw Failure.invalidRequest }
            let graph = try Graph(snapshot)
            let node = try graph.node(backendID: region.backendNodeID)
            guard regionRoles.contains(role(node)) else { throw Failure.unsupportedRegion }
            expected = canonical(expected)
            guard !expected.isEmpty else { throw Failure.invalidRequest }
            baseline = try graph.renderedText(node)
            anchor = try graph.anchor(node)
        case .regionChanged:
            guard action == .press, expected == "changed", let index = request.elementIndex,
                  index != elementIndex, let region = snapshot.element(at: index),
                  !region.supportsPress, !region.supportsSetText else { throw Failure.invalidRequest }
            let graph = try Graph(snapshot)
            let evidence = try graph.changedRegionBaseline(region)
            baseline = evidence.text
            anchor = evidence.anchor
        case .dialogOpened:
            guard action == .press, request.elementIndex == nil, expected == "opened",
                  selected.supportsPress, !selected.supportsSetText, selected.linkURL == nil,
                  dialogOpenerRoles.contains(elementRole(selected)) else { throw Failure.invalidRequest }
            let graph = try Graph(snapshot)
            let evidence = try graph.dialogOpeningBaseline(openerBackendID: selected.backendNodeID,
                                                          existingDialogFailure: .dialogAlreadyOpen)
            guard evidence.opener.role == elementRole(selected),
                  evidence.opener.name == canonical(selected.label) else { throw Failure.invalidRequest }
            dialogBaseline = evidence.root
            anchor = evidence.opener
            baseline = try dialogBaselineText(root: evidence.root, opener: evidence.opener)
        case .detailView:
            guard action == .press, request.elementIndex == nil else { throw Failure.invalidRequest }
            let graph = try Graph(snapshot)
            let selectedNode = try graph.node(backendID: selected.backendNodeID)
            expected = canonical(expected)
            guard !expected.isEmpty, try graph.containsObservedText(expected, under: selectedNode) else {
                throw Failure.invalidRequest
            }
            // Only a complete source can establish absence of the intended
            // detail heading before this action. Omitted pagination is fine.
            guard graph.headings(matching: expected).isEmpty else { throw Failure.baselineAlreadySatisfied }
            baseline = "heading_absent:" + scope.documentURL
            anchor = exactAnchor(selected)
        }
        if request.kind != .detailView && request.kind != .regionChanged && request.kind != .dialogOpened,
           baseline == expected { throw Failure.baselineAlreadySatisfied }
        let plan = Plan(kind: request.kind, expected: expected, baselineFingerprint: fingerprint(baseline),
            scope: scope, anchor: anchor, baselineSnapshotID: snapshot.id, dialogBaseline: dialogBaseline)
        try plan.validate()
        return plan
    }

    /// Display-only candidates from this captured source. This shares the
    /// compiler's complete-source, read-only text and stable-anchor checks;
    /// it never substitutes for compiling a plan or fresh mutation preflight.
    static func regionChangedCandidateBackendIDs(snapshot: BrowserTabSnapshot,
                                                 binding: BrowserTabBinding) -> Set<Int64> {
        guard (try? checkObservation(snapshot, binding: binding)) != nil,
              let graph = try? Graph(snapshot) else { return [] }
        let scope = observationScope(snapshot, binding: binding)
        return Set(snapshot.elements.compactMap { element in
            guard let evidence = try? graph.changedRegionBaseline(element) else { return nil }
            let plan = Plan(kind: .regionChanged, expected: "changed", baselineFingerprint: fingerprint(evidence.text),
                scope: scope, anchor: evidence.anchor, baselineSnapshotID: snapshot.id)
            guard (try? plan.validate()) != nil else { return nil }
            return element.backendNodeID
        })
    }

    private static func observationScope(_ snapshot: BrowserTabSnapshot, binding: BrowserTabBinding) -> Scope {
        Scope(browserGeneration: binding.browserGeneration, targetID: binding.targetID,
            targetInstanceToken: binding.targetInstanceToken, tabHandle: binding.handle,
            documentEpoch: snapshot.documentEpoch, loaderID: snapshot.loaderID,
            documentURL: snapshot.documentURL.absoluteString, frame: "main")
    }

    static func evaluate(_ plan: Plan, snapshot: BrowserTabSnapshot, binding: BrowserTabBinding) throws -> Proof {
        try plan.validate()
        try checkObservation(snapshot, binding: binding)
        guard snapshot.id != plan.baselineSnapshotID else { throw Failure.staleObservation }
        let scope = plan.scope
        guard binding.browserGeneration == scope.browserGeneration, binding.targetID == scope.targetID,
              binding.targetInstanceToken == scope.targetInstanceToken, binding.handle == scope.tabHandle else {
            throw Failure.wrongTarget
        }
        let observed: String
        switch plan.kind {
        case .documentURL:
            observed = snapshot.documentURL.absoluteString
        case .value:
            try checkSameDocument(scope, snapshot)
            let anchor = try requiredAnchor(plan)
            // Evidence may be outside the displayed pagination. Prefer the
            // complete source; visible values remain sufficient if omitted.
            if let document = snapshot.evidenceDocument {
                try checkDocumentMatches(document, snapshot)
                let matches = document.nodes.filter { $0.backendNodeID == anchor.backendNodeID && !$0.isIgnored }
                guard matches.count == 1 else { throw matches.isEmpty ? Failure.missingAnchor : Failure.ambiguousAnchor }
                guard role(matches[0]) == anchor.role, let value = matches[0].value else { throw Failure.missingAnchor }
                observed = value
            } else {
                let matches = snapshot.elements.filter { $0.backendNodeID == anchor.backendNodeID }
                guard matches.count == 1 else { throw matches.isEmpty ? Failure.missingAnchor : Failure.ambiguousAnchor }
                guard elementRole(matches[0]) == anchor.role, let value = matches[0].value else { throw Failure.missingAnchor }
                observed = value
            }
        case .regionText:
            try checkSameDocument(scope, snapshot)
            let graph = try Graph(snapshot)
            observed = try graph.renderedText(graph.resolve(try requiredAnchor(plan)))
        case .regionChanged:
            try checkSameDocument(scope, snapshot)
            let graph = try Graph(snapshot)
            observed = try graph.readOnlyRegionText(graph.resolveExactRegion(try requiredAnchor(plan)))
            guard plan.baselineFingerprint != fingerprint(observed) else { throw Failure.postconditionNotObserved }
            // This predicate proves changed displayed text only. It does not
            // assert a particular page, record, or whole-task outcome.
            return Proof(property: plan.property, expectedValue: "changed", observationID: snapshot.id)
        case .dialogOpened:
            try checkSameDocument(scope, snapshot)
            let graph = try Graph(snapshot)
            guard try graph.dialogRootIdentity() == plan.dialogBaseline else { throw Failure.wrongDocument }
            let dialogs = try graph.exposedMainFrameDialogs()
            guard dialogs.count == 1 else {
                throw dialogs.isEmpty ? Failure.postconditionNotObserved : Failure.ambiguousAnchor
            }
            // The opener may disappear or become inert while a modal is open.
            // Its pre-dispatch identity was already checked. This proves only
            // one newly AX-exposed semantic dialog in the same main document.
            return Proof(property: plan.property, expectedValue: "opened", observationID: snapshot.id)
        case .detailView:
            guard sameOrigin(snapshot.documentURL, URL(string: scope.documentURL)!) else { throw Failure.wrongDocument }
            guard snapshot.documentURL.absoluteString != scope.documentURL else { throw Failure.postconditionNotObserved }
            let graph = try Graph(snapshot)
            let matches = graph.headings(matching: plan.expected)
            guard matches.count == 1 else { throw matches.isEmpty ? Failure.postconditionNotObserved : Failure.ambiguousAnchor }
            observed = canonical(matches[0].name)
        }
        guard observed == plan.expected else { throw Failure.postconditionNotObserved }
        guard plan.baselineFingerprint != fingerprint(observed) else { throw Failure.baselineAlreadySatisfied }
        return Proof(property: plan.property, expectedValue: plan.expected, observationID: snapshot.id)
    }

    private static func revalidateBaseline(_ plan: Plan, document: BrowserDocumentObservation) throws {
        try plan.validate()
        guard document.loaderID == plan.scope.loaderID,
              document.url.absoluteString == plan.scope.documentURL else { throw Failure.wrongDocument }
        let baseline: String
        switch plan.kind {
        case .documentURL: baseline = document.url.absoluteString
        case .value:
            let anchor = try requiredAnchor(plan)
            let matches = document.nodes.filter { $0.backendNodeID == anchor.backendNodeID && !$0.isIgnored }
            guard matches.count == 1 else { throw matches.isEmpty ? Failure.missingAnchor : Failure.ambiguousAnchor }
            guard role(matches[0]) == anchor.role, let value = matches[0].value else { throw Failure.missingAnchor }
            baseline = value
        case .regionText, .regionChanged, .dialogOpened, .detailView:
            let snapshot = BrowserTabSnapshot(id: plan.baselineSnapshotID, tabHandle: plan.scope.tabHandle,
                documentEpoch: plan.scope.documentEpoch, loaderID: document.loaderID, documentURL: document.url,
                elements: [], formattedText: "", sourceTruncated: document.sourceTruncated, evidenceDocument: document)
            let graph = try Graph(snapshot)
            if plan.kind == .regionText {
                baseline = try graph.renderedText(graph.resolve(requiredAnchor(plan)))
            } else if plan.kind == .regionChanged {
                baseline = try graph.readOnlyRegionText(graph.resolveExactRegion(requiredAnchor(plan)))
            } else if plan.kind == .dialogOpened {
                let evidence = try graph.dialogOpeningBaseline(openerBackendID: requiredAnchor(plan).backendNodeID,
                                                              existingDialogFailure: .baselineChanged)
                baseline = try dialogBaselineText(root: evidence.root, opener: evidence.opener)
            } else {
                guard graph.headings(matching: plan.expected).isEmpty else { throw Failure.baselineChanged }
                baseline = "heading_absent:" + document.url.absoluteString
            }
        }
        guard fingerprint(baseline) == plan.baselineFingerprint else { throw Failure.baselineChanged }
    }

    private static func validate(_ plan: Plan) throws {
        guard validIdentity(plan.scope.targetID), validIdentity(plan.scope.targetInstanceToken),
              validIdentity(plan.scope.loaderID), plan.scope.frame == "main",
              validURL(plan.scope.documentURL), plan.expected.utf8.count <= maximumTextBytes,
              isFingerprint(plan.baselineFingerprint),
              plan.kind == .dialogOpened || plan.dialogBaseline == nil else { throw Failure.invalidPlan }
        switch plan.kind {
        case .documentURL:
            guard plan.anchor == nil, validURL(plan.expected),
                  plan.baselineFingerprint == fingerprint(plan.scope.documentURL) else { throw Failure.invalidPlan }
        case .value:
            guard let anchor = plan.anchor, anchor.backendNodeID > 0 else { throw Failure.invalidPlan }
            try validate(anchor)
        case .regionText:
            guard let anchor = plan.anchor, regionRoles.contains(anchor.role), !plan.expected.isEmpty,
                  canonical(plan.expected) == plan.expected else { throw Failure.invalidPlan }
            try validate(anchor)
        case .regionChanged:
            guard let anchor = plan.anchor, regionRoles.contains(anchor.role), plan.expected == "changed",
                  anchor.parentBackendNodeID != nil else { throw Failure.invalidPlan }
            try validate(anchor)
        case .dialogOpened:
            guard let anchor = plan.anchor, let root = plan.dialogBaseline,
                  plan.expected == "opened", dialogOpenerRoles.contains(anchor.role),
                  anchor.parentBackendNodeID != nil, root.rootBackendNodeID > 0,
                  ["rootwebarea", "webarea"].contains(root.rootRole),
                  plan.baselineFingerprint == fingerprint(try dialogBaselineText(root: root, opener: anchor)) else {
                throw Failure.invalidPlan
            }
            try validate(anchor)
        case .detailView:
            guard let anchor = plan.anchor, !plan.expected.isEmpty, canonical(plan.expected) == plan.expected,
                  plan.baselineFingerprint == fingerprint("heading_absent:" + plan.scope.documentURL) else { throw Failure.invalidPlan }
            try validate(anchor)
        }
    }

    private static func validate(_ anchor: Anchor) throws {
        guard anchor.backendNodeID > 0, validIdentity(anchor.role), anchor.name.utf8.count <= maximumTextBytes,
              anchor.childRoles.count <= maximumAnchorChildren, anchor.childRoles.allSatisfy(validIdentity) else {
            throw Failure.invalidPlan
        }
        let parentFields = [anchor.parentBackendNodeID != nil, anchor.parentRole != nil,
                            anchor.parentNameFingerprint != nil, anchor.childPosition != nil, anchor.siblings != nil]
        guard parentFields.allSatisfy({ $0 }) || parentFields.allSatisfy({ !$0 }) else { throw Failure.invalidPlan }
        if let parent = anchor.parentBackendNodeID, let siblings = anchor.siblings,
           let position = anchor.childPosition, let parentRole = anchor.parentRole,
           let parentName = anchor.parentNameFingerprint {
            guard parent > 0, parent != anchor.backendNodeID, validIdentity(parentRole), isFingerprint(parentName),
                  position >= 0, position <= siblings.count, siblings.count <= maximumAnchorChildren,
                  Set(siblings.map(\.backendNodeID)).count == siblings.count,
                  siblings.allSatisfy({ $0.backendNodeID > 0 && $0.backendNodeID != anchor.backendNodeID
                      && validIdentity($0.role) && isFingerprint($0.nameFingerprint) }) else { throw Failure.invalidPlan }
        }
    }

    private static func checkObservation(_ snapshot: BrowserTabSnapshot, binding: BrowserTabBinding) throws {
        guard snapshot.isLiveObservation else { throw Failure.staleObservation }
        try binding.lifetime.check()
        guard snapshot.tabHandle == binding.handle else { throw Failure.wrongTarget }
        guard snapshot.documentEpoch == binding.documentEpoch else { throw Failure.wrongDocument }
        guard validURL(snapshot.documentURL.absoluteString), !snapshot.loaderID.isEmpty else { throw Failure.incompleteEvidence }
    }

    private static func checkSameDocument(_ scope: Scope, _ snapshot: BrowserTabSnapshot) throws {
        guard snapshot.documentEpoch == scope.documentEpoch, snapshot.loaderID == scope.loaderID,
              snapshot.documentURL.absoluteString == scope.documentURL else { throw Failure.wrongDocument }
    }

    private static func checkDocumentMatches(_ document: BrowserDocumentObservation, _ snapshot: BrowserTabSnapshot) throws {
        guard document.loaderID == snapshot.loaderID, document.url == snapshot.documentURL else { throw Failure.wrongDocument }
    }

    private static func requiredAnchor(_ plan: Plan) throws -> Anchor {
        guard let anchor = plan.anchor else { throw Failure.invalidPlan }; return anchor
    }

    private static func exactAnchor(_ element: BrowserTabElement) -> Anchor {
        Anchor(backendNodeID: element.backendNodeID, role: elementRole(element), name: canonical(element.label),
               parentBackendNodeID: nil, parentRole: nil, parentNameFingerprint: nil,
               childPosition: nil, siblings: nil, childRoles: [])
    }

    /// Explicit follow-link admission is narrower than generic press inference.
    /// A root/custom node's incidental URL is never an observed semantic link.
    static func observedLinkDestination(_ element: BrowserTabElement, at url: URL) -> String? {
        guard elementRole(element) == "link", element.isEnabled, element.supportsPress,
              let destination = observedDestination(element, at: url),
              let scheme = URL(string: destination)?.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return destination
    }

    /// Shared structural validation for host-owned search evidence. This
    /// returns captured source nodes, never presentation/action capabilities.
    static func completeCapturedNodes(snapshot: BrowserTabSnapshot, maximumAncestorDepth: Int = 128) -> [BrowserDocumentNode]? {
        (try? Graph(snapshot, maximumAncestorDepth: maximumAncestorDepth))?.nodes
    }

    private static func observedDestination(_ element: BrowserTabElement, at url: URL) -> String? {
        guard element.supportsPress, let link = element.linkURL,
              let destination = URL(string: link, relativeTo: url)?.absoluteURL.absoluteString,
              validURL(destination) else { return nil }
        return destination
    }

    private static func validURL(_ value: String) -> Bool {
        guard value.utf8.count <= maximumTextBytes, let url = URL(string: value),
              ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return url.scheme == "file" || url.host?.isEmpty == false
    }

    private static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        let lhs = left.scheme?.lowercased(), rhs = right.scheme?.lowercased()
        guard lhs == rhs, left.host?.lowercased() == right.host?.lowercased() else { return false }
        // Detail-view inference is for a same-origin web application, not an
        // arbitrary file URL or a same-heading destination on another site.
        guard lhs == "https" || lhs == "http" else { return false }
        let defaultPort = lhs == "https" ? 443 : 80
        return (left.port ?? defaultPort) == (right.port ?? defaultPort)
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private struct DialogOpeningState: Encodable {
        let root: DialogBaseline
        let opener: Anchor
    }

    private static func dialogBaselineText(root: DialogBaseline, opener: Anchor) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(DialogOpeningState(root: root, opener: opener))
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidPlan }
        return text
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func canonical(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func containsBoundedPhrase(_ text: String, expected: String) -> Bool {
        guard !expected.isEmpty else { return false }
        var searchStart = text.startIndex
        let wordScalars = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "_"))
        while searchStart < text.endIndex,
              let match = text.range(of: expected, range: searchStart..<text.endIndex) {
            let previous = text[..<match.lowerBound].unicodeScalars.last
            let next = text[match.upperBound...].unicodeScalars.first
            if previous.map({ !wordScalars.contains($0) }) ?? true,
               next.map({ !wordScalars.contains($0) }) ?? true { return true }
            searchStart = match.upperBound
        }
        return false
    }
    private static func role(_ node: BrowserDocumentNode) -> String { node.role.lowercased() }
    private static func elementRole(_ element: BrowserTabElement) -> String { (element.semanticRole ?? element.role).lowercased() }

    /// Complete main-frame AX source, not a model-selected query/page. Graph
    /// checks protect absence and subtree claims against dangling IDs/cycles.
    private struct Graph {
        let nodes: [BrowserDocumentNode]
        let byID: [String: BrowserDocumentNode]

        init(_ snapshot: BrowserTabSnapshot, maximumAncestorDepth: Int = 128) throws {
            guard (1...128).contains(maximumAncestorDepth),
                  !snapshot.sourceTruncated, let document = snapshot.evidenceDocument, !document.sourceTruncated,
                  !document.nodes.isEmpty, document.nodes.count <= maximumNodes else { throw Failure.incompleteEvidence }
            try checkDocumentMatches(document, snapshot)
            var indexed: [String: BrowserDocumentNode] = [:]
            for node in document.nodes {
                guard let id = node.nodeID, !id.isEmpty, indexed[id] == nil else { throw Failure.incompleteEvidence }
                indexed[id] = node
            }
            for node in document.nodes {
                guard Set(node.childNodeIDs).count == node.childNodeIDs.count else { throw Failure.incompleteEvidence }
                for child in node.childNodeIDs {
                    guard let value = indexed[child], value.parentNodeID == node.nodeID else { throw Failure.incompleteEvidence }
                }
                if let parent = node.parentNodeID {
                    guard let value = indexed[parent], let id = node.nodeID, value.childNodeIDs.contains(id) else { throw Failure.incompleteEvidence }
                }
                var seen = Set<String>()
                var cursor: BrowserDocumentNode? = node
                while let current = cursor, let id = current.nodeID {
                    guard seen.insert(id).inserted, seen.count <= maximumAncestorDepth else { throw Failure.incompleteEvidence }
                    cursor = current.parentNodeID.flatMap { indexed[$0] }
                }
            }
            let roots = document.nodes.filter { $0.parentNodeID == nil }
            guard roots.count == 1, ["rootwebarea", "webarea"].contains(role(roots[0])) else { throw Failure.incompleteEvidence }
            nodes = document.nodes
            byID = indexed
        }

        func node(backendID: Int64) throws -> BrowserDocumentNode {
            let matches = nodes.filter { $0.backendNodeID == backendID && !$0.isIgnored }
            guard matches.count == 1 else { throw matches.isEmpty ? Failure.missingAnchor : Failure.ambiguousAnchor }
            return matches[0]
        }

        func dialogRootIdentity() throws -> DialogBaseline {
            guard let root = nodes.first(where: { $0.parentNodeID == nil }),
                  let backend = root.backendNodeID, backend > 0, !root.isIgnored,
                  try node(backendID: backend) == root else { throw Failure.incompleteEvidence }
            return DialogBaseline(rootBackendNodeID: backend, rootRole: role(root))
        }

        /// The capture covers the main document. Reject iframe/nested web-area ancestry
        /// rather than treating a matching role in a subframe as this dialog.
        private func isInMainFrame(_ node: BrowserDocumentNode) -> Bool {
            var cursor = node.parentNodeID.flatMap { byID[$0] }
            while let ancestor = cursor {
                if ancestor.parentNodeID == nil { return ["rootwebarea", "webarea"].contains(role(ancestor)) }
                if ["rootwebarea", "webarea", "iframe", "iframepresentational"].contains(role(ancestor)) { return false }
                cursor = ancestor.parentNodeID.flatMap { byID[$0] }
            }
            return false
        }

        func exposedMainFrameDialogs() throws -> [BrowserDocumentNode] {
            let dialogs = nodes.filter { !$0.isIgnored && dialogRoles.contains(role($0)) && isInMainFrame($0) }
            for dialog in dialogs {
                guard let backend = dialog.backendNodeID, backend > 0 else { throw Failure.incompleteEvidence }
                guard try node(backendID: backend) == dialog else { throw Failure.ambiguousAnchor }
            }
            return dialogs
        }

        func dialogOpeningBaseline(openerBackendID: Int64, existingDialogFailure: Failure) throws
            -> (root: DialogBaseline, opener: Anchor) {
            let root = try dialogRootIdentity()
            let opener = try node(backendID: openerBackendID)
            guard dialogOpenerRoles.contains(role(opener)), !opener.isDisabled, !opener.isEditable,
                  opener.linkURL == nil, isInMainFrame(opener) else { throw Failure.invalidRequest }
            let dialogs = try exposedMainFrameDialogs()
            guard dialogs.isEmpty else { throw existingDialogFailure }
            return (root, try anchor(opener, requiresStableParent: true))
        }

        func headings(matching text: String) -> [BrowserDocumentNode] {
            nodes.filter { !$0.isIgnored && role($0) == "heading" && canonical($0.name) == text }
        }

        func containsObservedText(_ expected: String, under root: BrowserDocumentNode) throws -> Bool {
            // Match an actually observed field or contiguous phrase in the
            // selected row's accessible name, never arbitrary page text.
            if containsBoundedPhrase(canonical(root.name), expected: expected) { return true }
            return try descendants(root).contains { !$0.isIgnored && canonical($0.name) == expected }
        }

        func descendants(_ root: BrowserDocumentNode) throws -> [BrowserDocumentNode] {
            var result: [BrowserDocumentNode] = []
            var pending = Array(root.childNodeIDs.reversed())
            while let id = pending.popLast() {
                guard let node = byID[id], result.count < maximumNodes else { throw Failure.incompleteEvidence }
                result.append(node)
                pending.append(contentsOf: node.childNodeIDs.reversed())
            }
            return result
        }

        func changedRegionBaseline(_ element: BrowserTabElement) throws -> (text: String, anchor: Anchor) {
            guard !element.supportsPress, !element.supportsSetText else { throw Failure.invalidRequest }
            let node = try node(backendID: element.backendNodeID)
            return (try readOnlyRegionText(node), try anchor(node, requiresStableParent: true))
        }

        /// A changed-region predicate cannot use an editable/control surface
        /// or its labels as the result. Require actual text from the complete
        /// source, rather than container names or omitted/over-budget tails.
        func readOnlyRegionText(_ root: BrowserDocumentNode) throws -> String {
            guard regionRoles.contains(role(root)), !root.isIgnored else { throw Failure.unsupportedRegion }
            let controls: Set<String> = ["button", "checkbox", "combobox", "searchbox", "textbox", "menu", "menubar",
                "menuitem", "menuitemcheckbox", "menuitemradio", "radio", "radiogroup", "switch", "tab", "tablist",
                "toolbar", "slider", "spinbutton", "listbox", "option", "tree", "treeitem", "link"]
            let region = [root] + (try descendants(root))
            guard !region.contains(where: { controls.contains(role($0)) || $0.isEditable || $0.isDOMClickable || $0.isFocusablePointer
                || $0.linkURL != nil }) else { throw Failure.unsupportedRegion }
            let text = try renderedText(root, textOnly: true)
            guard !text.isEmpty else { throw Failure.incompleteEvidence }
            return text
        }

        /// Unlike exact-text verification, "changed" must not accept a
        /// replacement container merely because its label/position resembles
        /// the old one. Keep the actual backend node and parent identity.
        func resolveExactRegion(_ anchor: Anchor) throws -> BrowserDocumentNode {
            let current = try node(backendID: anchor.backendNodeID)
            guard role(current) == anchor.role, let parentID = current.parentNodeID,
                  let parent = byID[parentID], parent.backendNodeID == anchor.parentBackendNodeID,
                  role(parent) == anchor.parentRole,
                  fingerprint(canonical(parent.name)) == anchor.parentNameFingerprint,
                  parent.childNodeIDs.firstIndex(of: current.nodeID ?? "") == anchor.childPosition else {
                throw Failure.missingAnchor
            }
            return current
        }

        func renderedText(_ root: BrowserDocumentNode, textOnly: Bool = false) throws -> String {
            var fragments: [String] = []
            var pending = [root]
            var count = 0
            var bytes = 0
            while let node = pending.popLast() {
                count += 1
                guard count <= maximumNodes else { throw Failure.incompleteEvidence }
                let textNode = ["statictext", "inlinetextbox"].contains(role(node))
                if !node.isIgnored && (textNode || (!textOnly && node.childNodeIDs.isEmpty)) {
                    let text = canonical(node.value ?? node.name)
                    if !text.isEmpty {
                        bytes += text.utf8.count + 1
                        guard bytes <= maximumTextBytes else { throw Failure.incompleteEvidence }
                        fragments.append(text)
                    }
                    // AX StaticText often repeats in InlineTextBox children.
                    // Its rendered name is one text fragment, not two.
                    if textNode { continue }
                }
                pending.append(contentsOf: node.childNodeIDs.reversed().compactMap { byID[$0] })
            }
            return fragments.joined(separator: " ")
        }

        func anchor(_ node: BrowserDocumentNode, requiresStableParent: Bool = false) throws -> Anchor {
            guard let backend = node.backendNodeID, backend > 0 else { throw Failure.baselineUnavailable }
            let children = try directChildren(node)
            guard children.count <= maximumAnchorChildren else { throw Failure.incompleteEvidence }
            var parentBackend: Int64?
            var parentRole: String?
            var parentName: String?
            var position: Int?
            var siblings: [Sibling]?
            if requiresStableParent || !canonical(node.name).isEmpty, let parentID = node.parentNodeID, let parent = byID[parentID],
               let parentID = parent.backendNodeID, let nodeID = node.nodeID,
               let childPosition = parent.childNodeIDs.firstIndex(of: nodeID),
               parent.childNodeIDs.count <= maximumAnchorChildren {
                let others = try directChildren(parent).filter { $0.nodeID != nodeID }
                if others.allSatisfy({ $0.backendNodeID != nil && ($0.backendNodeID ?? 0) > 0 }) {
                    parentBackend = parentID; parentRole = role(parent)
                    parentName = fingerprint(canonical(parent.name)); position = childPosition
                    siblings = others.map { Sibling(backendNodeID: $0.backendNodeID!, role: role($0), nameFingerprint: fingerprint(canonical($0.name))) }
                }
            }
            if requiresStableParent && parentBackend == nil { throw Failure.baselineUnavailable }
            return Anchor(backendNodeID: backend, role: role(node), name: canonical(node.name),
                          parentBackendNodeID: parentBackend, parentRole: parentRole,
                          parentNameFingerprint: parentName, childPosition: position,
                          siblings: siblings, childRoles: children.map(role))
        }

        func resolve(_ anchor: Anchor) throws -> BrowserDocumentNode {
            let exact = nodes.filter { $0.backendNodeID == anchor.backendNodeID && !$0.isIgnored }
            if !exact.isEmpty {
                guard exact.count == 1 else { throw Failure.ambiguousAnchor }
                guard role(exact[0]) == anchor.role else { throw Failure.missingAnchor }
                return exact[0]
            }
            // A replaced container is admitted only under the retained parent
            // with an unchanged sibling structure and unique named role.
            guard !anchor.name.isEmpty, let parentID = anchor.parentBackendNodeID,
                  let expectedSiblings = anchor.siblings, let expectedPosition = anchor.childPosition else { throw Failure.missingAnchor }
            let parent = try node(backendID: parentID)
            guard role(parent) == anchor.parentRole, fingerprint(canonical(parent.name)) == anchor.parentNameFingerprint else { throw Failure.missingAnchor }
            let children = try directChildren(parent)
            let candidates = children.filter { !$0.isIgnored && role($0) == anchor.role && canonical($0.name) == anchor.name }
            guard candidates.count == 1 else { throw candidates.isEmpty ? Failure.missingAnchor : Failure.ambiguousAnchor }
            let candidate = candidates[0]
            guard let candidateID = candidate.nodeID, children.firstIndex(where: { $0.nodeID == candidateID }) == expectedPosition,
                  try directChildren(candidate).map(role) == anchor.childRoles else { throw Failure.missingAnchor }
            let siblings = children.filter { $0.nodeID != candidateID }
            guard siblings.count == expectedSiblings.count else { throw Failure.missingAnchor }
            for (current, old) in zip(siblings, expectedSiblings) {
                guard current.backendNodeID == old.backendNodeID, role(current) == old.role,
                      fingerprint(canonical(current.name)) == old.nameFingerprint else { throw Failure.missingAnchor }
            }
            guard let id = candidate.backendNodeID, id > 0,
                  nodes.filter({ $0.backendNodeID == id && !$0.isIgnored }).count == 1 else { throw Failure.ambiguousAnchor }
            return candidate
        }

        private func directChildren(_ node: BrowserDocumentNode) throws -> [BrowserDocumentNode] {
            try node.childNodeIDs.map { id in guard let child = byID[id] else { throw Failure.incompleteEvidence }; return child }
        }
    }
}

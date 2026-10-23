import AppKit
import ApplicationServices
import AutomationCore
import Foundation

/// A complete browser observation, including its reference menu, must
/// fit atomically in the pinned runtime's existing latest-receipt budget.
enum BrowserCompleteObservation {
    static let marker = #"{"retention":"complete_browser_observation_v1"}"#
    static let maximumTextBytes = 4_096
    static let maximumSerializedItemsBytes = 4_608
    static let literalCopyGuidance = "Copy already observed identifiers, receipts, URLs and paths verbatim in inline code unless exact raw output is requested. Preserve original Unicode and whitespace: ASCII '-' (U+002D) must never become U+2011. Inline code changes presentation, not characters. This grants no new observation or action authority."

    static func footer(cursor: String?) throws -> String {
        var metadata: [String: Any] = [
            "consumed_by_admitted_input": true,
            "next_after_input": "Use current_observation or browser_read; never replay.",
            "references": "Refs from the same capture survive continuation within the 120-ref FIFO limit; fresh reads replace the menu.",
            "literal_copy_guidance": "Copy observed values verbatim, preserving Unicode and whitespace.",
        ]
        if let cursor { metadata["continuation"] = ["tool": "browser_read", "arguments": ["cursor": cursor]] }
        let bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
        return "\nBROWSER_ACTION_REFERENCES " + String(decoding: bytes, as: UTF8.self)
    }

    /// Size the actual post-input envelope before advancing a read cursor. A
    /// dispatch receipt remains separate from the observation through compaction.
    enum Encoding: Sendable {
        case read
        case input(wasFill: Bool, receipt: String, feedback: BrowserInputFeedback? = nil)

        var actionReceipt: String? {
            if case let .input(_, receipt, _) = self { return receipt }
            return nil
        }

        func encode(_ text: String, snapshotID: UUID, page: BrowserInputFeedback.PublishedPage? = nil) throws -> String {
            guard case let .input(wasFill, _, feedback) = self else { return text }
            let effect = wasFill
                ? "Fill dispatched; no Enter or submit click. Page handlers may react. Compare the complete field value before a distinct submit action."
                : "Click dispatched. If unchanged, wait/read."
            var result: [String: Any] = [
                "dispatched": true, "no_replay": true, "result_verified": false,
                "input_kind": wasFill ? "fill" : "click",
                "current_observation": ["status": "available", "view": "overview",
                    "snapshot_id": snapshotID.uuidString, "text": text],
                "action_references": ["consumed": true, "next": "current_observation"],
                "next": effect + " Recheck current labels/actions. Prior refs are consumed; do not repeat input. Verify a new outcome."
            ]
            if !wasFill, let feedback { result["input_feedback"] = feedback.presentation(page: page) }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func excessBytes(_ text: String, referenceReserve: Int = 0, actionReceipt: String? = nil) throws -> Int {
        let parts = [marker] + (actionReceipt.map { [$0] } ?? []) + [text]
        let items = parts.map { ["type": "inputText", "text": $0] }
        let serialized = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        return max(0, max(parts.reduce(parts.count - 1) { $0 + $1.utf8.count } + referenceReserve - maximumTextBytes,
                          serialized.count + referenceReserve - maximumSerializedItemsBytes))
    }
}

struct BrowserTarget: Equatable, Sendable {
    let targetID: String
    let instanceToken: String
    let title: String
    let url: URL
}

/// Passive HTML field constraints. These never establish whether a click
/// submitted a form, ran page handlers, or completed a requested action.
struct BrowserConstraintValidation: Codable, Equatable, Sendable {
    enum Issue: String, Codable, CaseIterable, Sendable {
        case valueMissing = "value_missing", typeMismatch = "type_mismatch"
        case patternMismatch = "pattern_mismatch", tooLong = "too_long", tooShort = "too_short"
        case rangeUnderflow = "range_underflow", rangeOverflow = "range_overflow"
        case stepMismatch = "step_mismatch", badInput = "bad_input", customError = "custom_error"
    }
    let required: Bool
    let candidate: Bool
    let valid: Bool
    let issues: [Issue]

    static func decode(_ raw: Any?) throws -> Self? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any],
              Set(object.keys) == ["required", "candidate", "valid", "issues"],
              let names = object["issues"] as? [String], names.count <= Issue.allCases.count,
              Set(names).count == names.count,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.valid == value.issues.isEmpty
        else {
            throw BrowserTabBrokerError.browserUnavailable("The built-in page returned invalid field constraint metadata.")
        }
        return value
    }

    var formattedMetadata: String {
        // No page strings occur here. The whole fixed-size suffix participates
        // in the row's existing byte budget, including on continued fragments.
        let names = Issue.allCases.filter { issues.contains($0) }.map(\.rawValue).joined(separator: ",")
        let state = !candidate ? "not_candidate" : valid ? "valid" : "invalid[\(names)]"
        return (required ? " required=true" : "") + " constraint=\(state)"
    }
}

/// Events observed during one dispatched click, not proof that submission or
/// any page-handler request did or did not occur. IDs never leave native code.
struct BrowserInputFeedback: Equatable, Sendable {
    struct Field: Codable, Equatable, Sendable {
        let backendNodeID: Int64
        let issues: [BrowserConstraintValidation.Issue]
    }
    let loaderID: String
    let documentURL: URL
    let fields: [Field]
    let truncated: Bool
    let committedDocumentID: UUID?

    init(loaderID: String, documentURL: URL, fields: [Field], truncated: Bool, committedDocumentID: UUID? = nil) {
        self.loaderID = loaderID; self.documentURL = documentURL
        self.fields = fields; self.truncated = truncated; self.committedDocumentID = committedDocumentID
    }

    struct PublishedPage: Sendable {
        let loaderID: String
        let documentURL: URL
        let elements: [BrowserTabElement]
        let receipt: SemanticReadReceipt
        let committedDocumentID: UUID?

        init(loaderID: String, documentURL: URL, elements: [BrowserTabElement], receipt: SemanticReadReceipt,
             committedDocumentID: UUID? = nil) {
            self.loaderID = loaderID; self.documentURL = documentURL
            self.elements = elements; self.receipt = receipt; self.committedDocumentID = committedDocumentID
        }

        init?(snapshot: BrowserTabSnapshot) {
            guard let receipt = snapshot.readReceipt, receipt.id == snapshot.id else { return nil }
            self.init(loaderID: snapshot.loaderID, documentURL: snapshot.documentURL,
                      elements: snapshot.elements, receipt: receipt,
                      committedDocumentID: snapshot.evidenceDocument?.committedDocumentID)
        }
    }

    /// Malformed optional feedback is discarded. It must never turn an already
    /// dispatched click into an apparent input failure or invite replay.
    static func decode(_ raw: Any?, document: BrowserDocumentObservation) -> Self? {
        guard let object = raw as? [String: Any], Set(object.keys) == ["fields", "truncated"],
              let rawFields = object["fields"] as? [[String: Any]], (1...3).contains(rawFields.count),
              rawFields.allSatisfy({ Set($0.keys) == ["backendNodeID", "issues"] }),
              let bytes = try? JSONSerialization.data(withJSONObject: object), bytes.count <= 2_048 else { return nil }
        struct Payload: Decodable { let fields: [Field]; let truncated: Bool }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: bytes),
              Set(payload.fields.map(\.backendNodeID)).count == payload.fields.count,
              payload.fields.allSatisfy({ field in
                  field.backendNodeID > 0 && !field.issues.isEmpty
                      && field.issues.count <= BrowserConstraintValidation.Issue.allCases.count
                      && Set(field.issues).count == field.issues.count
                      && document.nodes.contains { $0.backendNodeID == field.backendNodeID && $0.constraintValidation != nil }
              }) else { return nil }
        return .init(loaderID: document.loaderID, documentURL: document.url,
                     fields: payload.fields, truncated: payload.truncated, committedDocumentID: document.committedDocumentID)
    }

    func presentation(page: PublishedPage?) -> [String: Any] {
        var exposed: [[String: Any]] = []
        if let page, let committedDocumentID, page.committedDocumentID == committedDocumentID,
           page.loaderID == loaderID, page.documentURL == documentURL {
            for field in fields {
                guard let element = page.elements.first(where: { $0.backendNodeID == field.backendNodeID }) else { continue }
                let bytes = Array(element.label.utf8)
                guard let span = page.receipt.exposures.first(where: {
                    $0.nodeID == "backend:\(field.backendNodeID)" && $0.field == .label
                        && $0.totalUTF8 == bytes.count && $0.startUTF8 >= 0
                        && $0.endUTF8 >= $0.startUTF8 && $0.endUTF8 <= bytes.count
                        && ($0.startUTF8 < $0.endUTF8 || bytes.isEmpty && $0.startUTF8 == 0)
                }), let fragment = String(bytes: bytes[span.startUTF8..<span.endUTF8], encoding: .utf8) else { continue }
                var label = ""
                for character in fragment {
                    let candidate = label + String(character)
                    guard let encoded = try? JSONSerialization.data(withJSONObject: [candidate]), encoded.count <= 84 else { break }
                    label = candidate
                }
                exposed.append(["label": label,
                    "partial": span.startUTF8 != 0 || span.endUTF8 != bytes.count || !label.utf8.elementsEqual(fragment.utf8),
                    "issues": field.issues.map(\.rawValue)])
            }
        }
        return ["kind": "native_constraint_validation_observed", "during": "synchronous_click",
            "fields": exposed, "fields_omitted": truncated || exposed.count < fields.count,
            "next": "Native invalid events occurred during this click. Inspect current field constraints before a new action. Page handlers may still have acted; submission and delivery remain unverified. Do not replay."]
    }
}

struct BrowserDocumentNode: Equatable, Sendable {
    let backendNodeID: Int64?
    let role: String
    let name: String
    let value: String?
    let isDisabled: Bool
    let isReadOnly: Bool
    let isIgnored: Bool
    let nodeID: String?
    let parentNodeID: String?
    let childNodeIDs: [String]
    let linkURL: String?
    /// Browser-reported clickability for this exact backend node, never
    /// inferred from labels, CSS, descendants, or a clickable ancestor.
    let isDOMClickable: Bool
    /// An explicit backend veto overrides role-derived press support without
    /// hiding a readable link or pretending its enabled state is disabled.
    let isPressUnsupported: Bool
    /// An exact-node activation candidate checked by the transport: AX
    /// focusability plus visible positive rendered bounds and pointer cursor.
    /// This is not proof that pressing it completes any user-requested action.
    let isFocusablePointer: Bool
    /// Browser editable metadata, independent of role names. Used to keep
    /// contenteditable groups out of read-only result verification regions.
    let isEditable: Bool
    let constraintValidation: BrowserConstraintValidation?

    init(
        backendNodeID: Int64?, role: String, name: String, value: String?,
        isDisabled: Bool, isReadOnly: Bool, isIgnored: Bool,
        nodeID: String? = nil, parentNodeID: String? = nil,
        childNodeIDs: [String] = [], linkURL: String? = nil,
        isDOMClickable: Bool = false, isFocusablePointer: Bool = false,
        isEditable: Bool = false, isPressUnsupported: Bool = false,
        constraintValidation: BrowserConstraintValidation? = nil
    ) {
        self.backendNodeID = backendNodeID
        self.role = role
        self.name = name
        self.value = value
        self.isDisabled = isDisabled
        self.isReadOnly = isReadOnly
        self.isIgnored = isIgnored
        self.nodeID = nodeID
        self.parentNodeID = parentNodeID
        self.childNodeIDs = childNodeIDs
        self.linkURL = linkURL
        self.isDOMClickable = isDOMClickable
        self.isPressUnsupported = isPressUnsupported
        self.isFocusablePointer = isFocusablePointer
        self.isEditable = isEditable
        self.constraintValidation = constraintValidation
    }
}

struct BrowserDocumentObservation: Equatable, Sendable {
    enum SemanticReadiness: String, Equatable, Sendable {
        /// Observed semantics exist; this is not a match for the user's task.
        case ready
        case emptyAtDeadline = "empty_at_deadline"
    }
    let loaderID: String
    let title: String
    let url: URL
    let nodes: [BrowserDocumentNode]
    let sourceTruncated: Bool
    var sourceName = "embedded_webkit"
    /// Optional for other backends. An empty bounded observation is not proof
    /// that requested content is absent or that SPA initialization has ended.
    var semanticReadiness: SemanticReadiness? = nil
    /// Optional native identity from a committed document, never page JSON.
    /// Provisional-load invalidation and URL-only changes do not advance it.
    var committedDocumentID: UUID? = nil
    /// Host-only immutable plan carried to the final browser mutation preflight.
    /// Never accepted from a browser document or model response.
    var verificationPlan: BrowserActionVerification.Plan? = nil

    init(loaderID: String, title: String, url: URL, nodes: [BrowserDocumentNode], sourceTruncated: Bool = false) {
        self.loaderID = loaderID
        self.title = title
        self.url = url
        self.nodes = nodes
        self.sourceTruncated = sourceTruncated
    }
}

/// Readiness concerns the requested view, never whether its optional local
/// query matches. Query misses cannot become a reason to wait for site results.
enum BrowserReadReadiness: String, Equatable, Sendable {
    case semanticContent = "semantic_content"
    case content
}

/// A fresh read may settle native navigation before checking site scope. The
/// backend must invoke this gate after that wait and before reading page data.
typealias BrowserReadAuthorization = @Sendable (BrowserTarget) throws -> Void

protocol BrowserTabTransport: Sendable {
    func createTarget(url: URL) async throws -> BrowserTarget
    func target(id: String) async throws -> BrowserTarget?
    func activateTarget(id: String) async throws
    func closeTarget(target: BrowserTarget) async throws
    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation
    /// Fresh user reads may await semantic content. Binding, continuation and
    /// mutation preflight retain the immediate observation contract.
    func observeForRead(target: BrowserTarget) async throws -> BrowserDocumentObservation
    func observeForRead(target: BrowserTarget, readiness: BrowserReadReadiness) async throws -> BrowserDocumentObservation
    func observeForRead(target: BrowserTarget, readiness: BrowserReadReadiness,
                        authorization: @escaping BrowserReadAuthorization) async throws -> BrowserDocumentObservation
    func press(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws
    func pressWithFeedback(
        target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws -> BrowserInputFeedback?
    func setText(
        target: BrowserTarget,
        backendNodeID: Int64,
        text: String,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws
}

extension BrowserTabTransport {
    func pressWithFeedback(
        target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws -> BrowserInputFeedback? {
        try await press(target: target, backendNodeID: backendNodeID, document: document, permit: permit)
        return nil
    }
    func observeForRead(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        try await observe(target: target)
    }

    func observeForRead(target: BrowserTarget, readiness: BrowserReadReadiness) async throws -> BrowserDocumentObservation {
        try await observeForRead(target: target)
    }
}

/// Task-created targets are owned; existing built-in browser tabs are borrowed.
/// Releasing a borrowed binding never closes the user's tab.
enum BrowserTabOwnership: Equatable, Sendable {
    case owned
    case borrowed
}

struct BrowserTabBinding: Equatable, Sendable {
    let handle: UUID
    let taskKey: String
    let browserGeneration: UUID
    let targetID: String
    let targetInstanceToken: String
    let processIdentifier: Int32
    let documentEpoch: UUID
    let ownership: BrowserTabOwnership
    let lifetime: BrowserTabLifetime
    /// Host-only committed document identity; absent backends grant no refund.
    var committedDocumentID: UUID? = nil
}

/// Structural provenance, not a judgment that text answers the user's request.
/// Unknown includes missing, ambiguous, cyclic, or excessively deep ancestry.
enum BrowserContentScope: String, Equatable, Sendable {
    case main, article, navigation, complementary, banner, contentinfo, unknown

    var isDocumentContent: Bool { self == .main || self == .article }
}

struct BrowserTabElement: Equatable, Sendable {
    let index: Int
    let backendNodeID: Int64
    let role: String
    let label: String
    let value: String?
    let isEnabled: Bool
    let supportsPress: Bool
    let supportsSetText: Bool
    var isDOMClickable: Bool = false
    var isFocusablePointer: Bool = false
    var nodeID: String? = nil
    var parentNodeID: String? = nil
    var childNodeIDs: [String] = []
    var linkURL: String? = nil
    /// Preserve the source ARIA role separately from the compact native AX
    /// presentation. searchbox/textbox and region/status/listitem otherwise
    /// collapse to the same display roles and lose evidence-relevant meaning.
    var semanticRole: String? = nil
    var contentScope: BrowserContentScope = .unknown
    var contentKind: SemanticReadContentKind = .unknown
    var constraintValidation: BrowserConstraintValidation? = nil
}

/// Minted only by this broker from a bounded, emitted row. It identifies one
/// exposed target inside the retained immutable selection, never a whole page
/// or a model-supplied node. The controller publishes its opaque reference only
/// after the complete output fits; holding this value alone grants no input.
struct BrowserPublishedActionWitness: Equatable, Sendable {
    let sourceID: UUID
    let selectionID: UUID
    let snapshotID: UUID
    let bindingHandle: UUID
    let targetInstanceToken: String
    let committedDocumentID: UUID?
    let loaderID: String
    let documentEpoch: UUID
    let documentURL: URL
    let element: BrowserTabElement
    let label: String
    let exposures: [SemanticReadFieldExposure]
    fileprivate let selectedIndex: Int
    fileprivate let deadline: ContinuousClock.Instant

    func checkCaptureAge() throws {
        guard ContinuousClock.now < deadline else { throw BrowserTabBrokerError.staleSnapshot }
    }

    fileprivate init(sourceID: UUID, selectionID: UUID, snapshot: BrowserTabSnapshot,
                     binding: BrowserTabBinding, element: BrowserTabElement, label: String,
                     exposures: [SemanticReadFieldExposure], selectedIndex: Int,
                     deadline: ContinuousClock.Instant) {
        self.sourceID = sourceID; self.selectionID = selectionID; snapshotID = snapshot.id
        bindingHandle = binding.handle; targetInstanceToken = binding.targetInstanceToken
        committedDocumentID = snapshot.evidenceDocument?.committedDocumentID
        loaderID = snapshot.loaderID; documentEpoch = snapshot.documentEpoch; documentURL = snapshot.documentURL
        self.element = element; self.label = label; self.exposures = exposures
        self.selectedIndex = selectedIndex; self.deadline = deadline
    }
}

struct BrowserTabSnapshot: Equatable, Sendable {
    let id: UUID
    let tabHandle: UUID
    let documentEpoch: UUID
    let loaderID: String
    let documentURL: URL
    let elements: [BrowserTabElement]
    let formattedText: String
    var nextCursor: String? = nil
    var sourceTruncated: Bool = false
    var totalMatches: Int = 0
    var isLiveObservation: Bool = true
    /// Internal source evidence, independent of the model-facing pagination.
    /// This is not a capability and never authorizes an unexposed element.
    var evidenceDocument: BrowserDocumentObservation? = nil
    /// Exact emitted body spans; the retained source and action fields are not read coverage.
    var readReceipt: SemanticReadReceipt? = nil
    /// Exact published row text; full retained fields above must not be used
    /// to reconstruct a model-facing reference menu.
    var presentation: SemanticReadPresentation? = nil
    /// A subtree may share sourceID, but only cursor continuation retains this
    /// selection identity and can retain previously published input references.
    var actionSelectionID: UUID? = nil
    var isActionContinuation = false
    var actionWitnesses: [Int: BrowserPublishedActionWitness] = [:]

    func element(at index: Int) -> BrowserTabElement? {
        guard elements.indices.contains(index), elements[index].index == index else {
            return nil
        }
        return elements[index]
    }
}

struct BrowserTabObservation: Equatable, Sendable {
    let binding: BrowserTabBinding
    let snapshot: BrowserTabSnapshot
}

enum BrowserTabBrokerError: Error, Equatable, LocalizedError, Sendable {
    case browserUnavailable(String)
    case malformedResponse(String)
    case handleMissing
    case crossTaskHandle
    case browserGenerationChanged
    case targetClosed
    case targetReplaced
    case staleDocument
    case staleSnapshot
    case operationInProgress
    case elementNotFound
    case elementChanged
    case unsupportedAction(String)
    case mutationRejected(String)
    case ownershipMismatch
    case invalidRead(String)
    // Post-input observation diagnostics must distinguish host policy from
    // output packing without inferring either from private error text.
    case scopeDenied(String)
    case outputLimit(String)

    var errorDescription: String? {
        switch self {
        case .browserUnavailable(let detail):
            "The browser tab broker is unavailable: \(detail)"
        case .malformedResponse(let detail):
            "The browser returned an invalid response: \(detail)"
        case .handleMissing:
            "The bound browser tab handle is no longer available. Open the tab again."
        case .crossTaskHandle:
            "The browser tab handle belongs to a different task."
        case .browserGenerationChanged:
            "The brokered browser instance changed. Open the browser tab again."
        case .targetClosed:
            "The bound browser tab was closed. Open it again before interacting."
        case .targetReplaced:
            "The bound browser tab target was replaced or reused. Open it again."
        case .staleDocument:
            "The bound browser tab navigated or reloaded. Capture a fresh snapshot."
        case .staleSnapshot:
            "The browser Accessibility snapshot is missing or stale. Capture a fresh snapshot."
        case .operationInProgress:
            "Another browser operation is pending for this task. Retry after it completes."
        case .elementNotFound:
            "The approved browser element no longer exists in the bound document."
        case .elementChanged:
            "The approved browser element changed before input. Capture a fresh snapshot."
        case .unsupportedAction(let action):
            "The browser tab broker does not support \(action) for this element."
        case .mutationRejected(let detail):
            "The browser rejected the approved browser action: \(detail)"
        case .ownershipMismatch:
            "The browser tab operation does not match this broker's ownership policy."
        case .invalidRead(let detail), .scopeDenied(let detail), .outputLimit(let detail):
            "The browser read request is invalid: \(detail)"
        }
    }
}

func requireBrowserAccessibilityPermission() throws {
    guard AXIsProcessTrusted() else {
        throw AutomationError.permissionNotGranted(.accessibility)
    }
}

/// A runtime can revoke this synchronously before scheduling actor cleanup.
/// The lock covers only validity checks and the synchronous WebSocket enqueue.
final class BrowserTabLifetime: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var valid = true

    static func == (lhs: BrowserTabLifetime, rhs: BrowserTabLifetime) -> Bool {
        lhs === rhs
    }

    func revoke() {
        lock.withLock { valid = false }
    }

    func check() throws {
        try lock.withLock {
            guard valid else { throw BrowserTabBrokerError.handleMissing }
        }
    }

    fileprivate func whileValid(_ enqueue: () throws -> Void) throws {
        try lock.withLock {
            guard valid else { throw BrowserTabBrokerError.staleSnapshot }
            try enqueue()
        }
    }
}

/// The only mutable field is private and always protected by `lock`.
/// `commit` holds the lock only across a synchronous, non-reentrant enqueue;
/// it never holds it across an await, response, or browser execution.
final class BrowserMutationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    private let lifetime: BrowserTabLifetime?
    private let deadline: ContinuousClock.Instant?

    init(lifetime: BrowserTabLifetime? = nil, deadline: ContinuousClock.Instant? = nil) {
        self.lifetime = lifetime
        self.deadline = deadline
    }

    func revoke() {
        lock.lock()
        defer { lock.unlock() }
        available = false
    }

    func commit(_ enqueue: () throws -> Void) throws {
        if let lifetime {
            try lifetime.whileValid { try consume(enqueue) }
        } else {
            try consume(enqueue)
        }
    }

    private func consume(_ enqueue: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard available else {
            throw BrowserTabBrokerError.staleSnapshot
        }
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw BrowserTabBrokerError.staleSnapshot }
        available = false
        try enqueue()
    }
}

actor BrowserTabSessionBroker {
    private struct TargetLeaseKey: Hashable {
        let targetID: String
        let instanceToken: String
    }

    private struct TargetLease {
        let taskKey: String
        let handle: UUID
    }

    private struct Entry {
        let taskKey: String
        let browserGeneration: UUID
        let targetID: String
        let targetInstanceToken: String
        let processIdentifier: Int32
        let ownership: BrowserTabOwnership
        var loaderID: String
        var documentURL: URL
        var documentEpoch: UUID
        var activeSnapshot: BrowserTabSnapshot?
        let lifetime: BrowserTabLifetime
        var readState: ReadState? = nil
        var committedDocumentID: UUID? = nil
    }

    /// Server-owned pagination capabilities never encode a user-controlled tab,
    /// node ID, offset, or URL. A new observation or action retires the old token.
    private struct ReadState {
        let document: BrowserDocumentObservation
        let capturedAt: ContinuousClock.Instant
        let selected: [BrowserTabElement]
        let request: SemanticReadRequest
        let scopeNodeID: String?
        let sourceID: UUID
        let selectionID: UUID
        let nextPosition: ReadPosition
        let nextCursor: String?
        let snapshotID: UUID
    }

    private struct ReadPosition {
        var element = 0
        var field = 0
        var utf8Offset = 0
    }

    private struct FieldFragment {
        let field: SemanticReadField
        let text: String
        let start: Int
        let end: Int
        let total: Int
    }

    private struct ReadPage {
        var elements: [BrowserTabElement] = []
        var rows: [String] = []
        var presentedRows: [SemanticReadPresentedRow] = []
        var exposures: [SemanticReadFieldExposure] = []
        var nextPosition: ReadPosition
        var fieldsTruncated: Bool { nextPosition.field > 0 || nextPosition.utf8Offset > 0 }
    }

    private let transport: any BrowserTabTransport
    private let browserGeneration: UUID
    private let ownership: BrowserTabOwnership
    private let readLifetime: Duration
    private let readClock = ContinuousClock()
    private var entries = [UUID: Entry]()
    // A reservation exists before borrowed binding's first suspension and is
    // retained by the published handle. Cleanup may only release its own UUID.
    private var targetLeases = [TargetLeaseKey: TargetLease]()
    private var tasksInFlight = Set<String>()
    private var pendingMutations = [UUID: BrowserMutationPermit]()
    private var openingLifetimes = [String: BrowserTabLifetime]()
    private var ownedTargets = [String: BrowserTarget]()
    private var isShutDown = false

    init(
        transport: any BrowserTabTransport,
        browserGeneration: UUID,
        ownership: BrowserTabOwnership = .owned,
        readLifetime: Duration = .seconds(120)
    ) {
        self.transport = transport
        self.browserGeneration = browserGeneration
        self.ownership = ownership
        self.readLifetime = readLifetime
    }

    func open(
        taskKey: String,
        processIdentifier: Int32,
        url: URL,
        lifetime: BrowserTabLifetime = BrowserTabLifetime()
    ) async throws -> BrowserTabBinding {
        guard ownership == .owned else { throw BrowserTabBrokerError.ownershipMismatch }
        try beginOperation(taskKey: taskKey)
        openingLifetimes[taskKey] = lifetime
        defer {
            openingLifetimes.removeValue(forKey: taskKey)
            tasksInFlight.remove(taskKey)
        }
        try lifetime.check()
        for (handle, prior) in entries.filter({ $0.value.taskKey == taskKey }) {
            try await revoke(taskKey: taskKey, binding: binding(handle: handle, entry: prior))
        }
        try lifetime.check()
        let created = try await transport.createTarget(url: url)
        ownedTargets[created.targetID] = created
        do {
            try lifetime.check()
            try await transport.activateTarget(id: created.targetID)
            var target = created
            var document: BrowserDocumentObservation?
            for attempt in 0 ..< 120 {
                try Task.checkCancellation()
                try lifetime.check()
                guard let current = try await transport.target(id: created.targetID) else {
                    throw BrowserTabBrokerError.targetClosed
                }
                guard current.instanceToken == created.instanceToken else {
                    throw BrowserTabBrokerError.targetReplaced
                }
                target = current
                if let observed = try? await transport.observe(target: current),
                   !observed.loaderID.isEmpty,
                   ["http", "https", "file"].contains(observed.url.scheme ?? "") {
                    document = observed
                    break
                }
                if attempt < 119 { try await Task.sleep(for: .milliseconds(25)) }
            }
            try lifetime.check()
            guard !isShutDown, let document else {
                throw BrowserTabBrokerError.browserUnavailable(
                    "the new tab did not expose a stable document"
                )
            }
            let handle = UUID()
            let entry = Entry(
                taskKey: taskKey,
                browserGeneration: browserGeneration,
                targetID: target.targetID,
                targetInstanceToken: target.instanceToken,
                processIdentifier: processIdentifier,
                ownership: .owned,
                loaderID: document.loaderID,
                documentURL: document.url,
                documentEpoch: UUID(),
                activeSnapshot: nil,
                lifetime: lifetime,
                committedDocumentID: document.committedDocumentID
            )
            entries[handle] = entry
            return binding(handle: handle, entry: entry)
        } catch {
            lifetime.revoke()
            try? await closeOwnedTarget(created)
            throw error
        }
    }

    /// The caller must already hold an authorized exact built-in target identity.
    /// Binding observes that target without activation, navigation, or ownership
    /// transfer. Failure/cancellation only revokes the local capability.
    func bindBorrowed(
        taskKey: String,
        processIdentifier: Int32,
        target: BrowserTarget,
        lifetime: BrowserTabLifetime = BrowserTabLifetime()
    ) async throws -> BrowserTabBinding {
        guard ownership == .borrowed else { throw BrowserTabBrokerError.ownershipMismatch }
        try beginOperation(taskKey: taskKey)
        openingLifetimes[taskKey] = lifetime
        defer {
            openingLifetimes.removeValue(forKey: taskKey)
            tasksInFlight.remove(taskKey)
        }
        let handle = UUID()
        let leaseKey = TargetLeaseKey(targetID: target.targetID, instanceToken: target.instanceToken)
        do {
            try lifetime.check()
            if let lease = targetLeases[leaseKey], lease.taskKey != taskKey {
                throw BrowserTabBrokerError.operationInProgress
            }
            // Replace a same-task reservation before revoking the old handle;
            // its delayed cleanup must not clear this new reservation.
            targetLeases[leaseKey] = TargetLease(taskKey: taskKey, handle: handle)
            for (handle, prior) in entries.filter({ $0.value.taskKey == taskKey }) {
                try await revoke(taskKey: taskKey, binding: binding(handle: handle, entry: prior))
            }
            try lifetime.check()
            guard let current = try await transport.target(id: target.targetID) else {
                throw BrowserTabBrokerError.targetClosed
            }
            guard current.instanceToken == target.instanceToken else {
                throw BrowserTabBrokerError.targetReplaced
            }
            let document = try await transport.observe(target: current)
            // Observation may suspend while the user closes/replaces the tab.
            guard let refreshed = try await transport.target(id: target.targetID) else {
                throw BrowserTabBrokerError.targetClosed
            }
            guard refreshed.instanceToken == target.instanceToken else {
                throw BrowserTabBrokerError.targetReplaced
            }
            try Task.checkCancellation()
            try lifetime.check()
            guard !isShutDown, targetLeases[leaseKey]?.handle == handle else {
                throw BrowserTabBrokerError.handleMissing
            }
            guard !document.loaderID.isEmpty,
                  ["http", "https", "file"].contains(document.url.scheme ?? "") else {
                throw BrowserTabBrokerError.staleDocument
            }
            let entry = Entry(
                taskKey: taskKey, browserGeneration: browserGeneration,
                targetID: current.targetID, targetInstanceToken: current.instanceToken,
                processIdentifier: processIdentifier, ownership: .borrowed,
                loaderID: document.loaderID, documentURL: document.url,
                documentEpoch: UUID(), activeSnapshot: nil, lifetime: lifetime,
                committedDocumentID: document.committedDocumentID
            )
            entries[handle] = entry
            return binding(handle: handle, entry: entry)
        } catch {
            lifetime.revoke()
            releaseTargetLease(leaseKey, handle: handle)
            throw error
        }
    }

    func snapshot(
        taskKey: String,
        binding suppliedBinding: BrowserTabBinding,
        bundleIdentifier: String,
        query: String?
    ) async throws -> BrowserTabObservation {
        try await snapshot(
            taskKey: taskKey, binding: suppliedBinding, bundleIdentifier: bundleIdentifier,
            read: SemanticReadRequest(query: query)
        )
    }

    func snapshot(
        taskKey: String,
        binding suppliedBinding: BrowserTabBinding,
        bundleIdentifier: String,
        read: SemanticReadRequest,
        replacingCursor: String? = nil,
        compact: Bool = false,
        compactEncoding: BrowserCompleteObservation.Encoding = .read,
        readAuthorization: BrowserReadAuthorization? = nil
    ) async throws -> BrowserTabObservation {
        try beginOperation(taskKey: taskKey)
        defer { tasksInFlight.remove(taskKey) }
        var entry = try entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: false
        )
        guard (read.snapshotID == nil) == (read.elementIndex == nil) else {
            throw BrowserTabBrokerError.invalidRead("subtree expansion requires snapshot_id and element_index together")
        }
        let priorRead = entry.readState
        let priorSnapshot = entry.activeSnapshot
        // A changed-filter recovery is a separate fresh read, admitted only
        // by the exact current, unexpired cursor. It never follows an unknown
        // cursor or turns a navigation-stale capture into a new capability.
        if let replacingCursor {
            guard read.cursor == nil, read.snapshotID == nil, read.elementIndex == nil,
                  !replacingCursor.isEmpty, let priorRead,
                  priorRead.nextCursor == replacingCursor,
                  priorRead.snapshotID == priorSnapshot?.id,
                  priorRead.capturedAt.duration(to: readClock.now) < readLifetime else {
                throw BrowserTabBrokerError.staleSnapshot
            }
        }
        if let cursor = read.cursor {
            guard !cursor.isEmpty, priorRead?.nextCursor == cursor,
                  priorRead?.snapshotID == priorSnapshot?.id else {
                throw BrowserTabBrokerError.staleSnapshot
            }
            guard let priorRead, read.continues(priorRead.request) else {
                throw BrowserTabBrokerError.invalidRead("a continuation cursor retains its original filters and subtree; omit filters or repeat matching ones")
            }
        }
        if read.cursor != nil || read.snapshotID != nil {
            guard let priorRead, priorRead.capturedAt.duration(to: readClock.now) < readLifetime else {
                throw BrowserTabBrokerError.staleSnapshot
            }
        }
        var scopeNodeID: String?
        if let snapshotID = read.snapshotID, let index = read.elementIndex {
            guard priorSnapshot?.id == snapshotID, priorRead?.snapshotID == snapshotID,
                  let element = priorSnapshot?.element(at: index), let nodeID = element.nodeID else {
                throw BrowserTabBrokerError.staleSnapshot
            }
            scopeNodeID = nodeID
        }
        if replacingCursor == nil {
            entry.activeSnapshot = nil
            entry.readState = nil
            entries[suppliedBinding.handle] = entry
        }
        let target = try await currentTarget(for: suppliedBinding.handle, entry: entry)
        if replacingCursor != nil, target.url != priorRead?.document.url {
            throw BrowserTabBrokerError.staleSnapshot
        }
        let freshDocument: BrowserDocumentObservation
        if read.cursor == nil, read.snapshotID == nil {
            let readiness: BrowserReadReadiness = read.view == .content ? .content : .semanticContent
            if let readAuthorization {
                freshDocument = try await transport.observeForRead(
                    target: target, readiness: readiness, authorization: readAuthorization)
            } else {
                freshDocument = try await transport.observeForRead(target: target, readiness: readiness)
            }
        } else {
            freshDocument = try await transport.observe(target: target)
        }
        // The observation may have suspended across target detach/replacement.
        // Recheck exact identity, then local validity after that extra await.
        _ = try self.entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: false
        )

        _ = try await currentTarget(for: suppliedBinding.handle, entry: entry)
        try Task.checkCancellation()
        _ = try self.entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: false
        )
        if replacingCursor != nil {
            guard let priorRead, freshDocument.loaderID == priorRead.document.loaderID,
                  freshDocument.url == priorRead.document.url,
                  priorRead.capturedAt.duration(to: readClock.now) < readLifetime else {
                entry.activeSnapshot = nil
                entry.readState = nil
                entries[suppliedBinding.handle] = entry
                throw BrowserTabBrokerError.staleSnapshot
            }
        }

        if freshDocument.loaderID != entry.loaderID
            || freshDocument.url != entry.documentURL {
            entry.loaderID = freshDocument.loaderID
            entry.documentURL = freshDocument.url
            entry.documentEpoch = UUID()
            entry.activeSnapshot = nil
        }
        entry.committedDocumentID = freshDocument.committedDocumentID
        // Read pages are one immutable captured observation, not a splice of
        // different live trees. Unrelated timers or ads must not make that
        // observation impossible to finish. Revalidate the exact tab/document
        // and age; mutations still re-read and compare their exact target.
        let retainingObservation = read.cursor != nil || read.snapshotID != nil
        if retainingObservation {
            guard priorRead?.document.loaderID == freshDocument.loaderID,
                  priorRead?.document.url == freshDocument.url,
                  let priorRead, priorRead.capturedAt.duration(to: readClock.now) < readLifetime else {
                entries[suppliedBinding.handle] = entry
                throw BrowserTabBrokerError.staleSnapshot
            }
        }
        let document = retainingObservation ? priorRead!.document : freshDocument
        let capturedAt = retainingObservation ? priorRead!.capturedAt : readClock.now
        let effectiveRead = read.cursor == nil ? read : priorRead!.request
        if read.cursor != nil { scopeNodeID = priorRead?.scopeNodeID }
        let selected = read.cursor == nil
            ? makeElements(from: document, read: effectiveRead, scopeNodeID: scopeNodeID)
            : priorRead!.selected
        let position = read.cursor == nil ? ReadPosition() : priorRead!.nextPosition
        let snapshotID = UUID()
        let currentBinding = binding(handle: suppliedBinding.handle, entry: entry)
        // At most the next page can be exposed. The validator uses the full
        // immutable source, without another browser read or any input authority.
        let candidateSnapshot = BrowserTabSnapshot(id: snapshotID, tabHandle: currentBinding.handle,
            documentEpoch: currentBinding.documentEpoch, loaderID: document.loaderID, documentURL: document.url,
            elements: Array(selected.dropFirst(position.element).prefix(60)), formattedText: "",
            sourceTruncated: document.sourceTruncated, isLiveObservation: !retainingObservation,
            evidenceDocument: document)
        let candidates = BrowserActionVerification.regionChangedCandidateBackendIDs(
            snapshot: candidateSnapshot, binding: currentBinding)
        let navigationCandidates = Set(candidateSnapshot.elements.filter {
            BrowserActionVerification.observedLinkDestination($0, at: document.url) != nil
        }.map(\.backendNodeID))
        let sourceID = retainingObservation ? priorRead!.sourceID : UUID()
        let selectionID = read.cursor != nil ? priorRead!.selectionID : UUID()
        let continuationID = UUID().uuidString
        var bodyLimit = compact ? 3_000 : (effectiveRead.view == .overview ? 6_000 : 10_000)
        var page: ReadPage
        var receipt: SemanticReadReceipt
        var nextCursor: String?
        var formatted: String
        // Rebuild from the same immutable position; never trim a finished page
        // while keeping a cursor which has already advanced past omitted rows.
        while true {
            page = try makePage(selected: selected, position: position, regionCandidates: candidates,
                navigationCandidates: navigationCandidates, overview: effectiveRead.view == .overview,
                bodyByteLimit: bodyLimit, compact: compact)
            nextCursor = page.nextPosition.element < selected.count ? continuationID : nil
            receipt = SemanticReadReceipt(
                id: snapshotID, sourceID: sourceID,
                targetGeneration: "\(browserGeneration):\(currentBinding.handle):\(currentBinding.documentEpoch)",
                consistency: .immutableCapture, view: effectiveRead.view, query: effectiveRead.query,
                subtreeNodeID: scopeNodeID, selectedElementCount: selected.count,
                selectedFieldCount: selected.reduce(0) { $0 + readFields($1).count },
                sourceTruncated: document.sourceTruncated, fieldTruncated: page.fieldsTruncated,
                outputTruncated: nextCursor != nil, exposures: page.exposures)
            formatted = try formatSnapshot(snapshotID: snapshotID, binding: currentBinding,
                bundleIdentifier: bundleIdentifier, document: document, elements: page.elements,
                rows: page.rows, sourceID: sourceID, read: effectiveRead, receipt: receipt,
                scopeNodeID: scopeNodeID, totalMatches: selected.count, offset: position.element,
                nextCursor: nextCursor, fieldsTruncated: page.fieldsTruncated,
                retainedObservation: retainingObservation, compact: compact)
            if !compact { break }
            let withFooter = formatted + (try BrowserCompleteObservation.footer(cursor: nextCursor))
            let encoded = try compactEncoding.encode(withFooter, snapshotID: snapshotID,
                page: .init(loaderID: document.loaderID, documentURL: document.url, elements: page.elements, receipt: receipt,
                            committedDocumentID: document.committedDocumentID))
            let excess = try BrowserCompleteObservation.excessBytes(encoded,
                referenceReserve: page.elements.reduce(0) { $0 + compactReferenceReserve($1) },
                actionReceipt: compactEncoding.actionReceipt)
            if excess == 0 { break }
            // This can fail even with zero rows when the host metadata itself
            // cannot fit. Do not publish any partial page or reference menu.
            // `excess` includes the envelope and JSON's nested escaping, so
            // it can exceed the entire unescaped row allowance. Reduce by at
            // most half and rebuild the same position before declaring that
            // even one field fragment cannot fit.
            let nextLimit = max(bodyLimit / 2, bodyLimit - max(64, excess))
            guard !page.elements.isEmpty, nextLimit > 0, nextLimit < bodyLimit else {
                throw BrowserTabBrokerError.outputLimit("The complete browser observation exceeds its bounded output. Use a narrower view or query; no partial page was published.")
            }
            bodyLimit = nextLimit
        }
        let elements = page.elements
        guard formatted.utf8.count <= 16_384 else {
            throw BrowserTabBrokerError.outputLimit("the observed snapshot metadata exceeds the bounded read output")
        }
        var snapshot = BrowserTabSnapshot(
            id: snapshotID,
            tabHandle: currentBinding.handle,
            documentEpoch: currentBinding.documentEpoch,
            loaderID: document.loaderID,
            documentURL: document.url,
            elements: elements,
            formattedText: formatted,
            nextCursor: nextCursor,
            sourceTruncated: document.sourceTruncated,
            totalMatches: selected.count,
            isLiveObservation: !retainingObservation,
            evidenceDocument: document,
            readReceipt: receipt,
            presentation: .init(snapshotID: snapshotID, rows: page.presentedRows),
            actionSelectionID: selectionID,
            isActionContinuation: read.cursor != nil
        )
        // Build witnesses from this final internally constructed page, after
        // both output budgets have passed. Never mint from arbitrary retained
        // document nodes or from a caller-supplied snapshot.
        for row in page.presentedRows {
            guard let element = snapshot.element(at: row.index), element.isEnabled,
                  element.supportsPress || element.supportsSetText,
                  let label = EmbeddedBrowserTargetAssertion.exposedLabel(snapshot: snapshot, element: element) else { continue }
            let matches = selected.enumerated().filter { $0.element.backendNodeID == element.backendNodeID }
            guard matches.count == 1, let selectedElement = matches.first,
                  reindexed(selectedElement.element, index: element.index) == element else { continue }
            snapshot.actionWitnesses[row.index] = BrowserPublishedActionWitness(
                sourceID: sourceID, selectionID: selectionID, snapshot: snapshot, binding: currentBinding,
                element: element, label: label,
                exposures: receipt.exposures.filter { $0.nodeID == "backend:\(element.backendNodeID)" },
                selectedIndex: selectedElement.offset, deadline: capturedAt + readLifetime)
        }
        entry.activeSnapshot = snapshot
        entry.readState = ReadState(
            document: document, capturedAt: capturedAt, selected: selected, request: effectiveRead, scopeNodeID: scopeNodeID,
            sourceID: sourceID, selectionID: selectionID,
            nextPosition: page.nextPosition, nextCursor: nextCursor, snapshotID: snapshotID
        )
        entries[suppliedBinding.handle] = entry
        return BrowserTabObservation(binding: currentBinding, snapshot: snapshot)
    }

    private enum CapturedTarget {
        case snapshot(BrowserTabSnapshot, Int)
        case published(BrowserPublishedActionWitness)
    }

    /// Read-only preapproval validation. The witness is not refreshed: it must
    /// still identify the original retained selection and capture deadline.
    func validatePublishedAction(taskKey: String, binding: BrowserTabBinding,
                                 witness: BrowserPublishedActionWitness) throws {
        try beginOperation(taskKey: taskKey)
        defer { tasksInFlight.remove(taskKey) }
        let current = try entry(taskKey: taskKey, binding: binding, requiresCurrentEpoch: true)
        _ = try approvedTarget(.published(witness), entry: current, binding: binding)
        try Task.checkCancellation()
    }

    private func approvedTarget(_ captured: CapturedTarget, entry: Entry, binding: BrowserTabBinding)
        throws -> (element: BrowserTabElement, deadline: ContinuousClock.Instant) {
        guard let active = entry.activeSnapshot, let read = entry.readState,
              read.snapshotID == active.id,
              active.documentEpoch == entry.documentEpoch,
              active.loaderID == entry.loaderID, active.documentURL == entry.documentURL else {
            throw BrowserTabBrokerError.staleSnapshot
        }
        let deadline = read.capturedAt + readLifetime
        guard readClock.now < deadline else { throw BrowserTabBrokerError.staleSnapshot }
        switch captured {
        case let .snapshot(snapshot, index):
            guard active == snapshot else { throw BrowserTabBrokerError.staleSnapshot }
            guard let element = snapshot.element(at: index) else { throw BrowserTabBrokerError.elementNotFound }
            return (element, deadline)
        case let .published(witness):
            guard witness.sourceID == read.sourceID, witness.selectionID == read.selectionID,
                  active.actionSelectionID == witness.selectionID,
                  witness.bindingHandle == binding.handle,
                  witness.targetInstanceToken == entry.targetInstanceToken,
                  witness.committedDocumentID == read.document.committedDocumentID,
                  witness.loaderID == entry.loaderID, witness.documentURL == entry.documentURL,
                  witness.documentEpoch == entry.documentEpoch, witness.deadline == deadline,
                  read.selected.indices.contains(witness.selectedIndex),
                  reindexed(read.selected[witness.selectedIndex], index: witness.element.index) == witness.element else {
                throw BrowserTabBrokerError.staleSnapshot
            }
            return (witness.element, deadline)
        }
    }

    @discardableResult func perform(
        taskKey: String,
        binding suppliedBinding: BrowserTabBinding,
        snapshot suppliedSnapshot: BrowserTabSnapshot,
        elementIndex: Int,
        action: String,
        verificationPlan: BrowserActionVerification.Plan? = nil
    ) async throws -> BrowserInputFeedback? {
        try await perform(taskKey: taskKey, binding: suppliedBinding,
            captured: .snapshot(suppliedSnapshot, elementIndex), action: action, verificationPlan: verificationPlan)
    }

    @discardableResult func perform(taskKey: String, binding: BrowserTabBinding, witness: BrowserPublishedActionWitness,
                 action: String, verificationPlan: BrowserActionVerification.Plan? = nil) async throws -> BrowserInputFeedback? {
        try await perform(taskKey: taskKey, binding: binding, captured: .published(witness),
                          action: action, verificationPlan: verificationPlan)
    }

    private func perform(taskKey: String, binding suppliedBinding: BrowserTabBinding, captured: CapturedTarget,
                         action: String, verificationPlan: BrowserActionVerification.Plan?) async throws -> BrowserInputFeedback? {
        try beginOperation(taskKey: taskKey)
        defer { tasksInFlight.remove(taskKey) }
        guard action == "AXPress" else {
            throw BrowserTabBrokerError.unsupportedAction(action)
        }
        var entry = try entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: true
        )
        let (approvedElement, deadline) = try approvedTarget(captured, entry: entry, binding: suppliedBinding)
        guard approvedElement.supportsPress, approvedElement.isEnabled else {
            throw BrowserTabBrokerError.unsupportedAction(action)
        }
        // Reject unsupported intent without consuming the retained read. Once
        // a supported mutation is admitted, consume it before the first await
        // so a stale/retried request still cannot replay input.
        entry.activeSnapshot = nil
        entries[suppliedBinding.handle] = entry

        let permit = BrowserMutationPermit(lifetime: entry.lifetime, deadline: deadline)
        pendingMutations[suppliedBinding.handle] = permit
        defer {
            permit.revoke()
            pendingMutations.removeValue(forKey: suppliedBinding.handle)
        }
        let target = try await currentTarget(for: suppliedBinding.handle, entry: entry)
        let currentDocument = try await transport.observe(target: target)
        _ = try self.entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: true
        )
        guard currentDocument.loaderID == entry.loaderID,
              currentDocument.url == entry.documentURL else {
            entry.loaderID = currentDocument.loaderID
            entry.documentURL = currentDocument.url
            entry.documentEpoch = UUID()
            entries[suppliedBinding.handle] = entry
            throw BrowserTabBrokerError.staleDocument
        }
        let matches = currentDocument.nodes.compactMap {
            browserElement(from: $0, index: approvedElement.index)
        }.filter {
            $0.backendNodeID == approvedElement.backendNodeID
        }
        guard matches.count == 1, let currentElement = matches.first else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard sameApprovedSemantics(currentElement, approvedElement) else {
            throw BrowserTabBrokerError.elementChanged
        }
        guard readClock.now < deadline else { throw BrowserTabBrokerError.staleSnapshot }

        try verificationPlan?.revalidateBaseline(binding: suppliedBinding, document: currentDocument)
        var dispatchedDocument = currentDocument
        dispatchedDocument.verificationPlan = verificationPlan

        return try await transport.pressWithFeedback(
            target: target,
            backendNodeID: approvedElement.backendNodeID,
            document: dispatchedDocument,
            permit: permit
        )
    }

    func setText(
        taskKey: String,
        binding suppliedBinding: BrowserTabBinding,
        snapshot suppliedSnapshot: BrowserTabSnapshot,
        elementIndex: Int,
        text: String,
        verificationPlan: BrowserActionVerification.Plan? = nil
    ) async throws {
        try await setText(taskKey: taskKey, binding: suppliedBinding,
            captured: .snapshot(suppliedSnapshot, elementIndex), text: text, verificationPlan: verificationPlan)
    }

    func setText(taskKey: String, binding: BrowserTabBinding, witness: BrowserPublishedActionWitness,
                 text: String, verificationPlan: BrowserActionVerification.Plan? = nil) async throws {
        try await setText(taskKey: taskKey, binding: binding, captured: .published(witness),
                          text: text, verificationPlan: verificationPlan)
    }

    private func setText(taskKey: String, binding suppliedBinding: BrowserTabBinding, captured: CapturedTarget,
                         text: String, verificationPlan: BrowserActionVerification.Plan?) async throws {
        try beginOperation(taskKey: taskKey)
        defer { tasksInFlight.remove(taskKey) }
        var entry = try entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: true
        )
        let (approvedElement, deadline) = try approvedTarget(captured, entry: entry, binding: suppliedBinding)
        guard approvedElement.supportsSetText, approvedElement.isEnabled else {
            throw BrowserTabBrokerError.unsupportedAction("set text")
        }
        entry.activeSnapshot = nil
        entries[suppliedBinding.handle] = entry

        let permit = BrowserMutationPermit(lifetime: entry.lifetime, deadline: deadline)
        pendingMutations[suppliedBinding.handle] = permit
        defer {
            permit.revoke()
            pendingMutations.removeValue(forKey: suppliedBinding.handle)
        }
        let target = try await currentTarget(for: suppliedBinding.handle, entry: entry)
        let currentDocument = try await transport.observe(target: target)
        _ = try self.entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: true
        )
        guard currentDocument.loaderID == entry.loaderID,
              currentDocument.url == entry.documentURL else {
            entry.loaderID = currentDocument.loaderID
            entry.documentURL = currentDocument.url
            entry.documentEpoch = UUID()
            entries[suppliedBinding.handle] = entry
            throw BrowserTabBrokerError.staleDocument
        }
        let matches = currentDocument.nodes.compactMap {
            browserElement(from: $0, index: approvedElement.index)
        }.filter {
            $0.backendNodeID == approvedElement.backendNodeID
        }
        guard matches.count == 1, let currentElement = matches.first else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard sameApprovedSemantics(currentElement, approvedElement) else {
            throw BrowserTabBrokerError.elementChanged
        }
        guard readClock.now < deadline else { throw BrowserTabBrokerError.staleSnapshot }

        try verificationPlan?.revalidateBaseline(binding: suppliedBinding, document: currentDocument)
        var dispatchedDocument = currentDocument
        dispatchedDocument.verificationPlan = verificationPlan

        try await transport.setText(
            target: target,
            backendNodeID: approvedElement.backendNodeID,
            text: text,
            document: dispatchedDocument,
            permit: permit
        )
    }

    func revoke(taskKey: String, binding: BrowserTabBinding) async throws {
        let current = try entry(
            taskKey: taskKey,
            binding: binding,
            requiresCurrentEpoch: false,
            allowsRevokedLifetime: true
        )
        current.lifetime.revoke()
        pendingMutations.removeValue(forKey: binding.handle)?.revoke()
        entries.removeValue(forKey: binding.handle)
        releaseTargetLease(for: current, handle: binding.handle)
        if current.ownership == .owned,
           let target = ownedTargets[current.targetID],
           target.instanceToken == current.targetInstanceToken {
            try await closeOwnedTarget(target)
        }
    }

    /// Capability invalidation has no transport await. The process owner can
    /// then stop the complete owned group without waiting for every socket.
    func invalidateAll() {
        isShutDown = true
        for lifetime in openingLifetimes.values { lifetime.revoke() }
        for entry in entries.values { entry.lifetime.revoke() }
        for permit in pendingMutations.values { permit.revoke() }
        entries.removeAll()
        pendingMutations.removeAll()
        targetLeases.removeAll()
    }

    /// Internal fixture cleanup only. Identity still comes from created targets,
    /// never from enumeration of arbitrary browser tabs with matching titles.
    func closeTargets(urls: Set<URL>) async throws {
        guard ownership == .owned else { return }
        let targets = ownedTargets.values.filter { urls.contains($0.url) }
        for target in targets {
            let handles = entries.filter { $0.value.targetID == target.targetID }
            for (handle, entry) in handles {
                entry.lifetime.revoke()
                pendingMutations.removeValue(forKey: handle)?.revoke()
                entries.removeValue(forKey: handle)
                releaseTargetLease(for: entry, handle: handle)
            }
            try await closeOwnedTarget(target)
        }
    }

    private func closeOwnedTarget(_ target: BrowserTarget) async throws {
        guard ownership == .owned else { throw BrowserTabBrokerError.ownershipMismatch }
        guard ownedTargets[target.targetID]?.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        let transport = self.transport
        // Cleanup must not inherit the revoked action's cancellation.
        let cleanup = Task { try await transport.closeTarget(target: target) }
        try await cleanup.value
        if ownedTargets[target.targetID]?.instanceToken == target.instanceToken {
            ownedTargets.removeValue(forKey: target.targetID)
        }
    }

    private func beginOperation(taskKey: String) throws {
        try Task.checkCancellation()
        guard !isShutDown else { throw BrowserTabBrokerError.handleMissing }
        guard tasksInFlight.insert(taskKey).inserted else {
            throw BrowserTabBrokerError.operationInProgress
        }
    }

    private func releaseTargetLease(_ key: TargetLeaseKey, handle: UUID) {
        guard targetLeases[key]?.handle == handle else { return }
        targetLeases.removeValue(forKey: key)
    }

    private func releaseTargetLease(for entry: Entry, handle: UUID) {
        releaseTargetLease(
            TargetLeaseKey(targetID: entry.targetID, instanceToken: entry.targetInstanceToken),
            handle: handle
        )
    }

    private func entry(
        taskKey: String,
        binding: BrowserTabBinding,
        requiresCurrentEpoch: Bool,
        allowsRevokedLifetime: Bool = false
    ) throws -> Entry {
        guard binding.browserGeneration == browserGeneration else {
            throw BrowserTabBrokerError.browserGenerationChanged
        }
        guard let entry = entries[binding.handle] else {
            throw BrowserTabBrokerError.handleMissing
        }
        guard entry.taskKey == taskKey, binding.taskKey == taskKey else {
            throw BrowserTabBrokerError.crossTaskHandle
        }
        guard entry.browserGeneration == binding.browserGeneration,
              entry.targetID == binding.targetID,
              entry.targetInstanceToken == binding.targetInstanceToken,
              entry.processIdentifier == binding.processIdentifier,
              entry.ownership == binding.ownership,
              entry.lifetime === binding.lifetime else {
            throw BrowserTabBrokerError.targetReplaced
        }
        if !allowsRevokedLifetime { try entry.lifetime.check() }
        if requiresCurrentEpoch, entry.documentEpoch != binding.documentEpoch {
            throw BrowserTabBrokerError.staleDocument
        }
        return entry
    }

    private func currentTarget(
        for handle: UUID,
        entry: Entry
    ) async throws -> BrowserTarget {
        guard let target = try await transport.target(id: entry.targetID) else {
            entry.lifetime.revoke()
            pendingMutations.removeValue(forKey: handle)?.revoke()
            entries.removeValue(forKey: handle)
            releaseTargetLease(for: entry, handle: handle)
            throw BrowserTabBrokerError.targetClosed
        }
        guard target.instanceToken == entry.targetInstanceToken else {
            entry.lifetime.revoke()
            pendingMutations.removeValue(forKey: handle)?.revoke()
            entries.removeValue(forKey: handle)
            releaseTargetLease(for: entry, handle: handle)
            throw BrowserTabBrokerError.targetReplaced
        }
        return target
    }

    private func binding(handle: UUID, entry: Entry) -> BrowserTabBinding {
        BrowserTabBinding(
            handle: handle,
            taskKey: entry.taskKey,
            browserGeneration: entry.browserGeneration,
            targetID: entry.targetID,
            targetInstanceToken: entry.targetInstanceToken,
            processIdentifier: entry.processIdentifier,
            documentEpoch: entry.documentEpoch,
            ownership: entry.ownership,
            lifetime: entry.lifetime,
            committedDocumentID: entry.committedDocumentID
        )
    }

    private func makeElements(
        from document: BrowserDocumentObservation,
        read: SemanticReadRequest,
        scopeNodeID: String?
    ) -> [BrowserTabElement] {
        let sourceNodes = Dictionary(grouping: document.nodes.compactMap { node in
            node.nodeID.map { ($0, node) }
        }, by: { $0.0 }).filter { !$0.key.isEmpty && $0.value.count == 1 }.mapValues { $0[0].1 }
        let scopeIDs: Set<String>?
        if let scopeNodeID {
            var included: Set<String> = [scopeNodeID]
            let byID = Dictionary(grouping: document.nodes.compactMap { node in
                node.nodeID.map { ($0, node) }
            }, by: { $0.0 })
            var pending = [scopeNodeID]
            while let id = pending.popLast() {
                for (_, node) in byID[id] ?? [] {
                    for childID in node.childNodeIDs where included.insert(childID).inserted {
                        pending.append(childID)
                    }
                }
            }
            // Captures may provide parent links without a complete child list.
            var changed = true
            while changed {
                changed = false
                for node in document.nodes {
                    if let parentID = node.parentNodeID, included.contains(parentID),
                       let id = node.nodeID, included.insert(id).inserted {
                        changed = true
                    }
                }
            }
            scopeIDs = included
        } else {
            scopeIDs = nil
        }
        let trimmedQuery = read.query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let elements: [BrowserTabElement] = document.nodes.compactMap { node in
            if let scopeIDs, !scopeIDs.contains(node.nodeID ?? "") { return nil }
            guard var element = browserElement(from: node, index: 0) else { return nil }
            element.contentScope = contentScope(of: node, nodes: sourceNodes)
            element.contentKind = contentKind(of: node, nodes: sourceNodes)
            switch read.view {
            case .all:
                break
            case .overview:
                guard overviewCategory(element) != nil else { return nil }
            case .headings:
                guard node.role.lowercased() == "heading" else { return nil }
            case .links:
                guard node.role.lowercased() == "link" else { return nil }
            case .content:
                guard element.contentKind == .readable || isListboxOptionContent(node, nodes: sourceNodes),
                      !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !(element.value ?? "").isEmpty else { return nil }
            }
            if let trimmedQuery, !trimmedQuery.isEmpty {
                let matches = [element.role, element.label, element.value, element.linkURL]
                    .compactMap { $0 }
                    .contains {
                        $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                            .contains(trimmedQuery)
                    }
                guard matches else { return nil }
            }
            return element
        }
        if read.view == .content {
            // A source-order result list can fill the first bounded page before
            // an already captured reading pane. Keep every field and its exact
            // authority, but expose document text before selectable results.
            let documentText = elements.filter { $0.contentKind == .readable && $0.contentScope.isDocumentContent }
            let otherText = elements.filter { $0.contentKind == .readable && !$0.contentScope.isDocumentContent }
            let controls = elements.filter { $0.contentKind != .readable }
            return documentText + otherText + controls
        }
        guard read.view == .overview else { return elements }
        // Interleave observed controls, headings, document text, and navigation
        // within the same page budget. Post-input observations must show a
        // bounded sample of the new document, not only its heading and controls.
        // Preserve source order within each lane, then freeze the selection for
        // continuations. No page text or success wording determines priority.
        // Captured clickability can also mark roots and empty layout wrappers.
        // Keep those custom candidates, but never let them precede observed
        // semantic controls in the control lane. No label text is ranked.
        let controls = elements.filter { overviewCategory($0) == 0 }
            + elements.filter { overviewCategory($0) == 3 }
        let groups = [controls, elements.filter { overviewCategory($0) == 1 },
                      elements.filter { overviewCategory($0) == 4 },
                      elements.filter { overviewCategory($0) == 2 }]
        var ordered = [BrowserTabElement]()
        for offset in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where offset < group.count { ordered.append(group[offset]) }
        }
        return ordered
    }

    private func overviewCategory(_ element: BrowserTabElement) -> Int? {
        let role = element.semanticRole?.lowercased() ?? ""
        if role == "heading" { return 1 }
        if ["link", "navigation", "complementary", "banner", "contentinfo"].contains(role) { return 2 }
        // Capabilities include custom semantic controls. Inherited content_kind
        // is deliberately insufficient: a button's StaticText child is not a
        // second control and a sidebar's ordinary text is not navigation.
        if element.supportsSetText
            || ["button", "checkbox", "combobox", "searchbox", "textbox", "menu", "menubar", "menuitem",
                "menuitemcheckbox", "menuitemradio", "radio", "radiogroup", "switch", "tab", "tablist",
                "toolbar", "slider", "spinbutton", "listbox", "option", "treeitem"].contains(role) { return 0 }
        if element.supportsPress || element.isDOMClickable || element.isFocusablePointer { return 3 }
        if element.contentKind == .readable, element.contentScope.isDocumentContent,
           !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(element.value ?? "").isEmpty { return 4 }
        return nil
    }

    private func contentScope(of node: BrowserDocumentNode,
                              nodes: [String: BrowserDocumentNode]) -> BrowserContentScope {
        var current = node
        var seen = Set<String>()
        var content: BrowserContentScope?
        for _ in 0..<128 {
            if let id = current.nodeID {
                guard nodes[id] == current, seen.insert(id).inserted else { return .unknown }
            }
            let observedScope = BrowserContentScope(rawValue: current.role.lowercased())
            switch observedScope {
            case .navigation, .complementary, .banner, .contentinfo:
                // A card/article inside a sidebar remains sidebar evidence.
                // Conversely, navigation inside main is not document content.
                return observedScope ?? .unknown
            case .main, .article:
                if content == nil { content = observedScope }
            default:
                break
            }
            guard let parentID = current.parentNodeID else { return content ?? .unknown }
            guard let parent = nodes[parentID] else { return .unknown }
            current = parent
        }
        return .unknown
    }

    /// Readability and provenance are separate observations. In particular a
    /// toolbar inside main stays a control, while text without landmarks is
    /// still readable. DOM clickability never changes this classification.
    private func contentKind(of node: BrowserDocumentNode,
                             nodes: [String: BrowserDocumentNode]) -> SemanticReadContentKind {
        let controls: Set<String> = ["button", "checkbox", "combobox", "searchbox", "textbox",
            "menu", "menubar", "menuitem", "menuitemcheckbox", "menuitemradio", "radio", "radiogroup",
            "switch", "tab", "tablist", "toolbar", "slider", "spinbutton", "listbox", "option", "treeitem"]
        var current = node
        var seen = Set<String>()
        var navigation = false
        for _ in 0..<128 {
            let role = current.role.lowercased()
            if controls.contains(role) { return .control }
            if ["link", "navigation", "complementary", "banner", "contentinfo"].contains(role) {
                navigation = true
            }
            if let id = current.nodeID {
                guard nodes[id] == current, seen.insert(id).inserted else { break }
            }
            guard let parentID = current.parentNodeID, let parent = nodes[parentID] else { break }
            current = parent
        }
        if navigation { return .navigation }
        switch node.role.lowercased() {
        case "statictext", "inlinetextbox", "text", "heading", "paragraph", "listitem", "term",
             "definition", "code", "blockquote", "cell", "gridcell", "rowheader", "columnheader", "caption", "label":
            return .readable
        case "rootwebarea", "webarea", "main", "article", "region", "document", "image":
            return .metadata
        default:
            return .unknown
        }
    }

    /// Selectable listbox results can carry document text while remaining
    /// controls. This changes view selection only, never their action authority
    /// or document-content classification. Every ancestor must be observed.
    private func isListboxOptionContent(_ node: BrowserDocumentNode,
                                        nodes: [String: BrowserDocumentNode]) -> Bool {
        let textRoles: Set<String> = ["statictext", "inlinetextbox", "text", "heading", "paragraph", "listitem", "term",
            "definition", "code", "blockquote", "cell", "gridcell", "rowheader", "columnheader", "caption", "label"]
        guard node.role.lowercased() == "option" || textRoles.contains(node.role.lowercased()) else { return false }
        let excludedRoles: Set<String> = ["button", "checkbox", "combobox", "searchbox", "textbox", "menu", "menubar",
            "menuitem", "menuitemcheckbox", "menuitemradio", "radio", "radiogroup", "switch", "tab", "tablist", "toolbar",
            "slider", "spinbutton", "treeitem", "link", "navigation", "banner", "contentinfo"]
        var current = node
        var seen = Set<String>()
        var optionSeen = false, listboxSeen = false
        for _ in 0..<128 {
            guard let id = current.nodeID, nodes[id] == current, seen.insert(id).inserted else { return false }
            let role = current.role.lowercased()
            if excludedRoles.contains(role) { return false }
            if role == "option" {
                guard !optionSeen else { return false }
                optionSeen = true
            } else if role == "listbox" {
                guard optionSeen, !listboxSeen else { return false }
                listboxSeen = true
            }
            guard let parentID = current.parentNodeID else { return optionSeen && listboxSeen }
            guard let parent = nodes[parentID] else { return false }
            current = parent
        }
        return false
    }

    private func readFields(_ element: BrowserTabElement) -> [(field: SemanticReadField, text: String)] {
        var fields: [(field: SemanticReadField, text: String)] = [(.label, element.label)]
        if let value = element.value { fields.append((.value, value)) }
        if let link = element.linkURL { fields.append((.linkURL, link)) }
        return fields
    }

    private func reindexed(_ original: BrowserTabElement, index: Int) -> BrowserTabElement {
        BrowserTabElement(index: index, backendNodeID: original.backendNodeID, role: original.role,
            label: original.label, value: original.value, isEnabled: original.isEnabled,
            supportsPress: original.supportsPress, supportsSetText: original.supportsSetText,
            isDOMClickable: original.isDOMClickable, isFocusablePointer: original.isFocusablePointer,
            nodeID: original.nodeID, parentNodeID: original.parentNodeID, childNodeIDs: original.childNodeIDs,
            linkURL: original.linkURL, semanticRole: original.semanticRole, contentScope: original.contentScope,
            contentKind: original.contentKind, constraintValidation: original.constraintValidation)
    }

    private func makePage(selected: [BrowserTabElement], position: ReadPosition,
                          regionCandidates: Set<Int64>, navigationCandidates: Set<Int64>, overview: Bool = false,
                          bodyByteLimit: Int, compact: Bool = false) throws -> ReadPage {
        let maximumElements = overview ? 18 : 60
        var page = ReadPage(nextPosition: position)
        var pageFragments = [[FieldFragment]]()
        var bytes = 0
        // The immutable action element is never replaced by its displayed
        // fragment. Only the current page's original elements authorize input.
        while page.nextPosition.element < selected.count, page.elements.count < maximumElements {
            let original = selected[page.nextPosition.element]
            let element = reindexed(original, index: page.elements.count)
            // A parent can occur later on this page. Reserve the largest
            // possible page index now, then resolve actual page membership.
            let reservedParentIndex = element.parentNodeID == nil ? nil : maximumElements - 1
            let regionCandidate = regionCandidates.contains(element.backendNodeID)
            let fields = readFields(element)
            var next = page.nextPosition
            var fragments = [FieldFragment]()
            let referenceReserve = compact ? compactReferenceReserve(element) : SemanticReadPresentation.rowMetadataByteReserve
            let available = bodyByteLimit - bytes - 1 - referenceReserve
            while next.field < fields.count {
                let field = fields[next.field]
                // Links are never presented as a syntactically valid clipped
                // destination: their continued portions use href_fragment.
                var budget = min(field.field == .linkURL ? 2048 : 4096, available)
                var accepted: FieldFragment?
                while budget >= 0 {
                    let part = fieldPrefix(field.text, startUTF8: next.utf8Offset, escapedByteLimit: budget)
                    let fragment = FieldFragment(field: field.field, text: part.text,
                        start: next.utf8Offset, end: part.end, total: field.text.utf8.count)
                    guard fragment.end > fragment.start || fragment.total == 0 else { break }
                    let rowBytes = formatElement(element, fragments: fragments + [fragment],
                        parentIndex: reservedParentIndex, regionCandidate: regionCandidate, navigationCandidate: navigationCandidates.contains(element.backendNodeID), compact: compact).utf8.count
                    if rowBytes <= available { accepted = fragment; break }
                    budget -= max(1, rowBytes - available)
                }
                guard let fragment = accepted else { break }
                fragments.append(fragment)
                if fragment.end < fragment.total {
                    next.utf8Offset = fragment.end
                    break
                }
                next.field += 1
                next.utf8Offset = 0
            }
            guard !fragments.isEmpty else {
                if page.elements.isEmpty {
                    throw BrowserTabBrokerError.outputLimit(compact
                        ? "The observed element metadata exceeds the bounded read output. Use a narrower view or query; no partial page was published."
                        : "the observed element metadata exceeds the bounded read output")
                }
                break
            }
            let row = formatElement(element, fragments: fragments,
                parentIndex: reservedParentIndex, regionCandidate: regionCandidate, navigationCandidate: navigationCandidates.contains(element.backendNodeID), compact: compact)
            page.elements.append(element)
            pageFragments.append(fragments)
            bytes += row.utf8.count + 1 + referenceReserve
            page.exposures += fragments.map {
                SemanticReadFieldExposure(nodeID: "backend:\(element.backendNodeID)", field: $0.field,
                    startUTF8: $0.start, endUTF8: $0.end, totalUTF8: $0.total,
                    kind: element.contentKind,
                    provenance: SemanticReadProvenance(rawValue: element.contentScope.rawValue) ?? .unknown)
            }
            if next.field == fields.count {
                next.element += 1
                next.field = 0
                next.utf8Offset = 0
            }
            page.nextPosition = next
            // A split field is continued before later nodes. Every cursor
            // advances actual bytes, including a single unusually long field.
            if next.field > 0 || next.utf8Offset > 0 { break }
        }
        let visibleNodes = Dictionary(grouping: page.elements.compactMap { element in
            element.nodeID.map { ($0, element.index) }
        }, by: { $0.0 }).filter { !$0.key.isEmpty && $0.value.count == 1 }.mapValues { $0[0].1 }
        page.rows = zip(page.elements, pageFragments).map { element, fragments in
            let parentIndex = element.parentNodeID.flatMap { visibleNodes[$0] }
            return formatElement(element, fragments: fragments,
                parentIndex: parentIndex == element.index ? nil : parentIndex,
                regionCandidate: regionCandidates.contains(element.backendNodeID), navigationCandidate: navigationCandidates.contains(element.backendNodeID), compact: compact)
        }
        page.presentedRows = zip(page.elements, page.rows).map { element, row in
            let parentIndex = element.parentNodeID.flatMap { visibleNodes[$0] }
            let presentsTextEntry = element.isEnabled && element.supportsSetText
                && ["textbox", "searchbox"].contains((element.semanticRole ?? "").lowercased())
            // Prefer filling editable text fields in the model menu. Keep
            // combobox presses and the underlying legacy press capability.
            return SemanticReadPresentedRow(index: element.index, text: row,
                actions: element.isEnabled && element.supportsPress && !presentsTextEntry ? ["AXPress"] : [],
                settable: element.isEnabled && element.supportsSetText,
                followLink: navigationCandidates.contains(element.backendNodeID),
                region: true, regionChanged: regionCandidates.contains(element.backendNodeID),
                parentIndex: parentIndex == element.index ? nil : parentIndex)
        }
        return page
    }

    /// Offsets refer to raw UTF-8, while the budget includes escaping. Splitting
    /// on scalar boundaries preserves valid Unicode without copying a tail.
    private func fieldPrefix(_ value: String, startUTF8: Int, escapedByteLimit: Int) -> (text: String, end: Int) {
        let utf8 = value.utf8
        guard let byteIndex = utf8.index(utf8.startIndex, offsetBy: startUTF8, limitedBy: utf8.endIndex),
              let index = byteIndex.samePosition(in: value.unicodeScalars) else { return ("", startUTF8) }
        var text = ""
        var rawBytes = startUTF8
        var escapedBytes = 0
        for scalar in value.unicodeScalars[index...] {
            let piece = String(scalar)
            let cost = quote(piece).utf8.count - 2
            guard escapedBytes + cost <= escapedByteLimit else { break }
            text += piece
            rawBytes += piece.utf8.count
            escapedBytes += cost
        }
        return (text, rawBytes)
    }

    // Tokens are native UUIDs: each suffix, including JSON escaping, is <64
    // bytes. Passive rows need no speculative capability budget.
    private func compactReferenceReserve(_ element: BrowserTabElement) -> Int {
        guard element.isEnabled else { return 0 }
        return (element.supportsPress ? 64 : 0) + (element.supportsSetText ? 64 : 0)
    }

    private func formatElement(_ element: BrowserTabElement, fragments: [FieldFragment],
                               parentIndex: Int?, regionCandidate: Bool, navigationCandidate: Bool, compact: Bool = false) -> String {
        let actions = element.supportsPress ? "[\"AXPress\"]" : "[]"
        let pressSource: String
        if element.supportsPress && !supportsSemanticPress(role: element.semanticRole ?? element.role) {
            pressSource = element.isDOMClickable ? " press_source=browser_clickability"
                : (element.isFocusablePointer ? " press_source=focusable_pointer" : "")
        } else { pressSource = "" }
        let fields = fragments.map { fragment in
            let partial = fragment.start != 0 || fragment.end != fragment.total
            let name = fragment.field == .linkURL ? (partial ? "href_fragment" : "href") : fragment.field.rawValue
            let range = partial ? " \(name)_utf8=\(fragment.start):\(fragment.end)/\(fragment.total)" : ""
            let omitted = fragment.field == .linkURL && partial ? " href_omitted=1" : ""
            return "\(name)=\(quote(fragment.text))\(range)\(omitted)"
        }.joined(separator: " ")
        let semanticRole: String
        if let role = element.semanticRole {
            let bounded = fieldPrefix(role, startUTF8: 0, escapedByteLimit: 256)
            semanticRole = " semantic_role=\(quote(bounded.text))"
                + (bounded.end < role.utf8.count ? " semantic_role_truncated=1" : "")
        } else { semanticRole = "" }
        let candidate = (regionCandidate ? " region_changed_candidate=true" : "")
            + (navigationCandidate ? " follow_link=true" : "")
        // Raw AX node IDs remain host identity, never model-facing element
        // indices. Only #index and an exposed parent's index address this page.
        let parent = parentIndex.map { " parent_index=\($0)" } ?? ""
        let children = element.childNodeIDs.isEmpty ? "" : " child_count=\(element.childNodeIDs.count) expandable=true"
        return "#\(element.index) role=\(quote(element.role))\(semanticRole)\(candidate) \(fields)\(parent)\(children) "
            + "content_scope=\(element.contentScope.rawValue) content_kind=\(element.contentKind.rawValue) "
            + (compact ? (element.isEnabled ? "" : "enabled=false ") : "enabled=\(element.isEnabled ? "true" : "false") ")
            + (compact ? (element.supportsSetText ? "settable=true " : "") : "settable=\(element.supportsSetText ? "true" : "false") ")
            + (compact && !element.supportsPress ? "" : "actions=\(actions)") + pressSource
            + (element.constraintValidation?.formattedMetadata ?? "")
    }

    private func readViewName(_ view: SemanticReadView) -> String {
        switch view {
        case .all: "all"
        case .overview: "overview"
        case .content: "content"
        case .headings: "headings"
        case .links: "links"
        }
    }

    private func browserElement(
        from node: BrowserDocumentNode,
        index: Int
    ) -> BrowserTabElement? {
        guard !node.isIgnored, let backendNodeID = node.backendNodeID else {
            return nil
        }
        let role = axRole(for: node.role)
        let label = node.name.isEmpty ? (node.value ?? "") : node.name
        let normalizedRole = node.role.lowercased()
        let supportsPress = !node.isPressUnsupported
            && (supportsSemanticPress(role: normalizedRole) || node.isDOMClickable || node.isFocusablePointer)
        let supportsSetText = !node.isReadOnly && [
            "combobox", "searchbox", "textbox",
        ].contains(normalizedRole)
        return BrowserTabElement(
            index: index,
            backendNodeID: backendNodeID,
            role: role,
            label: label,
            value: node.value,
            isEnabled: !node.isDisabled,
            supportsPress: supportsPress,
            supportsSetText: supportsSetText,
            isDOMClickable: node.isDOMClickable,
            isFocusablePointer: node.isFocusablePointer,
            nodeID: node.nodeID,
            parentNodeID: node.parentNodeID,
            childNodeIDs: node.childNodeIDs,
            linkURL: node.linkURL,
            semanticRole: node.role,
            constraintValidation: node.constraintValidation
        )
    }

    private func sameApprovedSemantics(
        _ current: BrowserTabElement,
        _ approved: BrowserTabElement
    ) -> Bool {
        current.backendNodeID == approved.backendNodeID
            && current.role == approved.role
            && current.semanticRole == approved.semanticRole
            && current.label == approved.label
            && current.value == approved.value
            && current.linkURL == approved.linkURL
            && current.nodeID == approved.nodeID
            && current.parentNodeID == approved.parentNodeID
            && current.isEnabled == approved.isEnabled
            && current.supportsPress == approved.supportsPress
            && current.supportsSetText == approved.supportsSetText
            && current.isDOMClickable == approved.isDOMClickable
            && current.isFocusablePointer == approved.isFocusablePointer
    }

    private func supportsSemanticPress(role: String) -> Bool {
        ["button", "checkbox", "link", "menuitem", "radio", "switch", "tab"]
            .contains(role.lowercased())
    }

    private func axRole(for rawRole: String) -> String {
        switch rawRole.lowercased() {
        case "button": "AXButton"
        case "checkbox": "AXCheckBox"
        case "combobox": "AXComboBox"
        case "heading": "AXHeading"
        case "image": "AXImage"
        case "link": "AXLink"
        case "list": "AXList"
        case "listitem": "AXGroup"
        case "menuitem": "AXMenuItem"
        case "radio": "AXRadioButton"
        case "rootwebarea", "webarea": "AXWebArea"
        case "searchbox", "textbox": "AXTextField"
        case "slider": "AXSlider"
        case "statictext", "inlinetextbox": "AXStaticText"
        case "switch": "AXCheckBox"
        case "tab": "AXRadioButton"
        default: "AXGroup"
        }
    }

    /// Selection counts describe this capture, never the website's search
    /// results. Match provenance uses only exposed field fragments, so a query
    /// hidden in a retained field tail cannot become claimed readable evidence.
    private func selectionEvidence(receipt: SemanticReadReceipt,
                                   elements: [BrowserTabElement]) throws -> String {
        let query = receipt.query?.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let filtered = query?.isEmpty == false
        var evidence: [String: Any] = [
            "operation": filtered ? "local_capture_filter" : "capture_view_selection",
            "counts_scope": "captured_elements_only",
            "query_applied": filtered,
            "site_search_evaluated": false,
            "site_result_count": "not_measured",
        ]
        if let query, filtered {
            let exposures = Dictionary(grouping: receipt.exposures, by: \.nodeID)
            var readable = Set<Int>(), inputValues = Set<Int>(), other = Set<Int>()
            for element in elements {
                let fields = readFields(element)
                for exposure in exposures["backend:\(element.backendNodeID)", default: []] {
                    guard let field = fields.first(where: { $0.field == exposure.field })?.text else { continue }
                    let bytes = field.utf8
                    guard exposure.startUTF8 >= 0, exposure.endUTF8 >= exposure.startUTF8,
                          exposure.endUTF8 <= bytes.count else { continue }
                    let start = bytes.index(bytes.startIndex, offsetBy: exposure.startUTF8)
                    let end = bytes.index(bytes.startIndex, offsetBy: exposure.endUTF8)
                    guard let fragment = String(bytes: bytes[start..<end], encoding: .utf8),
                          fragment.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                            .contains(query) else { continue }
                    if exposure.field == .value,
                       element.supportsSetText || ["textbox", "searchbox", "combobox"].contains((element.semanticRole ?? "").lowercased()) {
                        inputValues.insert(element.index)
                    } else if exposure.kind == .readable, exposure.field != .linkURL {
                        readable.insert(element.index)
                    } else {
                        other.insert(element.index)
                    }
                }
            }
            evidence["emitted_query_matches"] = [
                "basis": "emitted_field_fragments",
                "readable_text_elements": readable.count,
                "input_value_elements": inputValues.count,
                "other_field_elements": other.count,
                "only_input_values": !inputValues.isEmpty && readable.isEmpty && other.isEmpty,
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        return "READ_SELECTION_EVIDENCE " + String(decoding: data, as: UTF8.self)
    }

    private func formatSnapshot(
        snapshotID: UUID,
        binding: BrowserTabBinding,
        bundleIdentifier: String,
        document: BrowserDocumentObservation,
        elements: [BrowserTabElement],
        rows: [String],
        sourceID: UUID,
        read: SemanticReadRequest,
        receipt: SemanticReadReceipt,
        scopeNodeID: String?,
        totalMatches: Int,
        offset: Int,
        nextCursor: String?,
        fieldsTruncated: Bool,
        retainedObservation: Bool,
        compact: Bool = false
    ) throws -> String {
        if compact {
            return try formatCompactSnapshot(snapshotID: snapshotID, binding: binding,
                document: document, elements: elements, rows: rows, sourceID: sourceID,
                read: read, receipt: receipt, scopeNodeID: scopeNodeID, totalMatches: totalMatches,
                offset: offset, nextCursor: nextCursor, fieldsTruncated: fieldsTruncated,
                retainedObservation: retainedObservation)
        }
        let documentURL = document.url.absoluteString
        let formattedURL = documentURL.utf8.count <= 2048
            ? "url=\(quote(documentURL))" : "url_omitted=1"
        let title = fieldPrefix(document.title, startUTF8: 0, escapedByteLimit: 512)
        let metadataTruncated = title.end < document.title.utf8.count || documentURL.utf8.count > 2048
        var lines = [
            "AXSNAPSHOT id=\(snapshotID.uuidString) pid=\(binding.processIdentifier) "
                + "bundle=\(quote(bundleIdentifier)) tab_handle=\(binding.handle.uuidString) "
                + "document_epoch=\(binding.documentEpoch.uuidString) source=\(document.sourceName) "
                + "\(formattedURL) "
                + "title=\(quote(title.text))",
            "READ view=\(readViewName(read.view)) scope=\(scopeNodeID == nil ? "document" : "subtree") "
                + "source_observation=\(sourceID) consistency=immutable_capture "
                + "source_nodes=\(document.nodes.count) source_truncated=\(document.sourceTruncated ? 1 : 0) "
                + "matches=\(totalMatches) shown=\(elements.count) offset=\(offset) "
                + "output_truncated=\(nextCursor == nil ? 0 : 1) field_truncated=\(fieldsTruncated ? 1 : 0) "
                + "metadata_truncated=\(metadataTruncated ? 1 : 0) "
                + "no_matches=\(totalMatches == 0 ? 1 : 0) visibility=unknown "
                + (nextCursor.map { "next_cursor=\($0) " } ?? "")
                + "observation=\(retainedObservation ? "retained" : "live")"
                + (document.semanticReadiness.map { " semantic_readiness=\($0.rawValue)" } ?? ""),
            try selectionEvidence(receipt: receipt, elements: elements),
            "CONTENT_EVIDENCE document_content_shown=\(elements.filter { $0.contentKind == .readable && $0.contentScope.isDocumentContent }.count) "
                + "navigation_shown=\(elements.filter { $0.contentScope == .navigation }.count) "
                + "complementary_shown=\(elements.filter { $0.contentScope == .complementary }.count) "
                + "banner_shown=\(elements.filter { $0.contentScope == .banner }.count) "
                + "contentinfo_shown=\(elements.filter { $0.contentScope == .contentinfo }.count) "
                + "unknown_shown=\(elements.filter { $0.contentScope == .unknown }.count) "
                + "readable_shown=\(elements.filter { $0.contentKind == .readable }.count) "
                + "controls_shown=\(elements.filter { $0.contentKind == .control }.count) "
                + "metadata_shown=\(elements.filter { $0.contentKind == .metadata }.count) "
                + "scope_basis=observed_ancestry subject_relevance=not_verified",
        ]
        if read.view == .links {
            lines.insert("LINK_VIEW_SCOPE non_link_controls_omitted=true. Buttons/form controls may be outside this view; read view=overview or all before absence/access claims.", at: 2)
        }
        if read.view == .content {
            lines.insert("CONTENT_VIEW_SCOPE includes=readable_text,listbox_options other_controls_omitted=true. Included options retain original actions; read view=overview or all for other controls and before absence/access claims.", at: 2)
        }
        if read.view == .overview {
            lines.append("OVERVIEW selection=observed_controls_headings_document_text_navigation ordering=interleaved_categories document_content_exhaustive=false. Body text is a bounded sample; continue its cursor or read view=content for more. View=all retains full structural context for action planning.")
        }
        lines.append(contentsOf: rows)
        if document.semanticReadiness == .emptyAtDeadline {
            lines.append(read.view == .content
                ? "No readable content or qualifying listbox options were observed before the content-readiness deadline. Controls may already be present; this bounded read does not establish website search results or absent content."
                : "Only a document shell or footer was observed before the readiness deadline; meaningful page content is still unresolved. This does not establish that requested content is absent.")
        }
        lines.append("Content scopes and counts describe only this exposed page's observed structure; subject relevance is not verified. Tab titles and navigation/sidebar labels alone do not establish the document's contents. Unknown scope is not proof that content is absent.")
        lines.append("Readable fields are distinct from controls and metadata. Use view=all or links for navigation/controls. Exhausting a captured selection does not establish that virtualized or uncaptured content is absent.")
        if rows.contains(where: { $0.contains(" region_changed_candidate=true ") }) {
            lines.append("region_changed_candidate marks a captured noneditable text container, not authorization or success. For region_changed use that container's index, not its StaticText child; parent_index refers only to this snapshot. Fresh preflight still applies.")
        }
        if nextCursor != nil {
            lines.append("Continue with cursor only, including remaining field fragments. UTF-8 ranges refer to the original captured field; href_fragment is not a complete destination. Indices apply only to this snapshot; use snapshot_id + element_index to read an observed subtree.")
        }
        if retainedObservation {
            lines.append("This is a page/subtree of the retained observation (maximum age 120 seconds), not a new live tree. Actions revalidate the exact target before input.")
        }
        if document.sourceTruncated {
            lines.append("Source tree is incomplete. Counts describe captured nodes, not the entire page; do not infer absent content from no_matches.")
        }
        if totalMatches == 0 {
            lines.append("No matching captured elements in this view/filter. This is not a website search result or proof of absent content. Read without a local query to inspect the site's actual result state; no unrelated fallback nodes were substituted.")
        }
        return lines.joined(separator: "\n")
    }

    /// The same captured rows and exact field spans, with one concise scope
    /// declaration instead of repeated prose. No text is removed after paging.
    private func formatCompactSnapshot(snapshotID: UUID, binding: BrowserTabBinding,
        document: BrowserDocumentObservation, elements: [BrowserTabElement], rows: [String], sourceID: UUID,
        read: SemanticReadRequest, receipt: SemanticReadReceipt, scopeNodeID: String?,
        totalMatches: Int, offset: Int, nextCursor: String?, fieldsTruncated: Bool,
        retainedObservation: Bool) throws -> String {
        let url = document.url.absoluteString
        let title = fieldPrefix(document.title, startUTF8: 0, escapedByteLimit: 128)
        let metadataTruncated = title.end < document.title.utf8.count || url.utf8.count > 1_024
        var lines = [
            "AXSNAPSHOT id=\(snapshotID.uuidString) tab_handle=\(binding.handle.uuidString) document_epoch=\(binding.documentEpoch.uuidString) source=\(document.sourceName) "
                + (url.utf8.count <= 1_024 ? "url=\(quote(url))" : "url_omitted=1") + " title=\(quote(title.text))",
            "READ view=\(readViewName(read.view)) scope=\(scopeNodeID == nil ? "document" : "subtree") source_observation=\(sourceID) consistency=immutable_capture "
                + "source_nodes=\(document.nodes.count) source_truncated=\(document.sourceTruncated ? 1 : 0) matches=\(totalMatches) shown=\(elements.count) offset=\(offset) "
                + "output_truncated=\(nextCursor == nil ? 0 : 1) field_truncated=\(fieldsTruncated ? 1 : 0) metadata_truncated=\(metadataTruncated ? 1 : 0) no_matches=\(totalMatches == 0 ? 1 : 0) "
                + (nextCursor.map { "next_cursor=\($0) " } ?? "") + "observation=\(retainedObservation ? "retained" : "live")"
                + (document.semanticReadiness.map { " semantic_readiness=\($0.rawValue)" } ?? ""),
            try selectionEvidence(receipt: receipt, elements: elements),
            "SCOPE captured selection only, not website search or proof of relevance/absence. *_utf8 marks exact fragments; href_fragment is not a destination. Omitted row flags: enabled=true settable=false actions=[]. Only shown click_ref/fill_ref authorize input."
        ]
        if read.view != .all {
            lines.append("VIEW \(readViewName(read.view)) omits other node kinds. Use content for message/document text; all includes toolbars.")
        }
        if document.semanticReadiness == .emptyAtDeadline {
            lines.append("READINESS deadline reached without qualifying content; search completion and absence remain unverified.")
        }
        lines.append(contentsOf: rows)
        if nextCursor != nil { lines.append("Continue with cursor only for remaining captured fields/rows.") }
        return lines.joined(separator: "\n")
    }

    private func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            case 0..<32: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

}

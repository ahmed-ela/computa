import AppKit
import ApplicationServices
import AutomationCore
import Foundation

struct BrowserTarget: Equatable, Sendable {
    let targetID: String
    let instanceToken: String
    let title: String
    let url: URL
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

    init(
        backendNodeID: Int64?, role: String, name: String, value: String?,
        isDisabled: Bool, isReadOnly: Bool, isIgnored: Bool,
        nodeID: String? = nil, parentNodeID: String? = nil,
        childNodeIDs: [String] = [], linkURL: String? = nil,
        isDOMClickable: Bool = false, isFocusablePointer: Bool = false,
        isEditable: Bool = false, isPressUnsupported: Bool = false
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

protocol BrowserTabTransport: Sendable {
    func createTarget(url: URL) async throws -> BrowserTarget
    func target(id: String) async throws -> BrowserTarget?
    func activateTarget(id: String) async throws
    func closeTarget(target: BrowserTarget) async throws
    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation
    /// Fresh user reads may await semantic content. Binding, continuation and
    /// mutation preflight retain the immediate observation contract.
    func observeForRead(target: BrowserTarget) async throws -> BrowserDocumentObservation
    func press(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws
    func setText(
        target: BrowserTarget,
        backendNodeID: Int64,
        text: String,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws
}

extension BrowserTabTransport {
    func observeForRead(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        try await observe(target: target)
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
        case .invalidRead(let detail):
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

    init(lifetime: BrowserTabLifetime? = nil) {
        self.lifetime = lifetime
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
                lifetime: lifetime
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
                documentEpoch: UUID(), activeSnapshot: nil, lifetime: lifetime
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
        replacingCursor: String? = nil
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
            freshDocument = try await transport.observeForRead(target: target)
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
        let page = try makePage(selected: selected, position: position, regionCandidates: candidates,
                                navigationCandidates: navigationCandidates,
                                overview: effectiveRead.view == .overview)
        let elements = page.elements
        let nextCursor = page.nextPosition.element < selected.count ? UUID().uuidString : nil
        let sourceID = retainingObservation ? priorRead!.sourceID : UUID()
        let receipt = SemanticReadReceipt(
            id: snapshotID, sourceID: sourceID,
            targetGeneration: "\(browserGeneration):\(currentBinding.handle):\(currentBinding.documentEpoch)",
            consistency: .immutableCapture, view: effectiveRead.view, query: effectiveRead.query,
            subtreeNodeID: scopeNodeID, selectedElementCount: selected.count,
            selectedFieldCount: selected.reduce(0) { $0 + readFields($1).count },
            sourceTruncated: document.sourceTruncated, fieldTruncated: page.fieldsTruncated,
            outputTruncated: nextCursor != nil, exposures: page.exposures
        )
        let formatted = try formatSnapshot(
            snapshotID: snapshotID,
            binding: currentBinding,
            bundleIdentifier: bundleIdentifier,
            document: document,
            elements: elements,
            rows: page.rows,
            sourceID: sourceID,
            read: effectiveRead,
            receipt: receipt,
            scopeNodeID: scopeNodeID,
            totalMatches: selected.count,
            offset: position.element,
            nextCursor: nextCursor,
            fieldsTruncated: page.fieldsTruncated,
            retainedObservation: retainingObservation
        )
        guard formatted.utf8.count <= 16_384 else {
            throw BrowserTabBrokerError.invalidRead("the observed snapshot metadata exceeds the bounded read output")
        }
        let snapshot = BrowserTabSnapshot(
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
            presentation: .init(snapshotID: snapshotID, rows: page.presentedRows)
        )
        entry.activeSnapshot = snapshot
        entry.readState = ReadState(
            document: document, capturedAt: capturedAt, selected: selected, request: effectiveRead, scopeNodeID: scopeNodeID,
            sourceID: sourceID, nextPosition: page.nextPosition, nextCursor: nextCursor, snapshotID: snapshotID
        )
        entries[suppliedBinding.handle] = entry
        return BrowserTabObservation(binding: currentBinding, snapshot: snapshot)
    }

    func perform(
        taskKey: String,
        binding suppliedBinding: BrowserTabBinding,
        snapshot suppliedSnapshot: BrowserTabSnapshot,
        elementIndex: Int,
        action: String,
        verificationPlan: BrowserActionVerification.Plan? = nil
    ) async throws {
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
        guard entry.activeSnapshot?.id == suppliedSnapshot.id,
              entry.activeSnapshot == suppliedSnapshot,
              suppliedSnapshot.documentEpoch == entry.documentEpoch,
              suppliedSnapshot.loaderID == entry.loaderID,
              suppliedSnapshot.documentURL == entry.documentURL else {
            throw BrowserTabBrokerError.staleSnapshot
        }
        guard let approvedElement = suppliedSnapshot.element(at: elementIndex) else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard approvedElement.supportsPress, approvedElement.isEnabled else {
            throw BrowserTabBrokerError.unsupportedAction(action)
        }
        // Reject unsupported intent without consuming the retained read. Once
        // a supported mutation is admitted, consume it before the first await
        // so a stale/retried request still cannot replay input.
        entry.activeSnapshot = nil
        entries[suppliedBinding.handle] = entry

        let permit = BrowserMutationPermit(lifetime: entry.lifetime)
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

        try verificationPlan?.revalidateBaseline(binding: suppliedBinding, document: currentDocument)
        var dispatchedDocument = currentDocument
        dispatchedDocument.verificationPlan = verificationPlan

        try await transport.press(
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
        try beginOperation(taskKey: taskKey)
        defer { tasksInFlight.remove(taskKey) }
        var entry = try entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: true
        )
        guard entry.activeSnapshot?.id == suppliedSnapshot.id,
              entry.activeSnapshot == suppliedSnapshot,
              suppliedSnapshot.documentEpoch == entry.documentEpoch,
              suppliedSnapshot.loaderID == entry.loaderID,
              suppliedSnapshot.documentURL == entry.documentURL else {
            throw BrowserTabBrokerError.staleSnapshot
        }
        guard let approvedElement = suppliedSnapshot.element(at: elementIndex) else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard approvedElement.supportsSetText, approvedElement.isEnabled else {
            throw BrowserTabBrokerError.unsupportedAction("set text")
        }
        entry.activeSnapshot = nil
        entries[suppliedBinding.handle] = entry

        let permit = BrowserMutationPermit(lifetime: entry.lifetime)
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
            lifetime: entry.lifetime
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
        // Interleave observed controls, headings, and navigation so a long
        // sidebar cannot consume the first page before controls are exposed.
        // Preserve source order within headings/navigation and each control
        // strength group, then freeze this selection for continuations.
        // Ordinary body text is read separately.
        // Captured clickability can also mark roots and empty layout wrappers.
        // Keep those custom candidates, but never let them precede observed
        // semantic controls in the control lane. No label text is ranked.
        let controls = elements.filter { overviewCategory($0) == 0 }
            + elements.filter { overviewCategory($0) == 3 }
        let groups = [controls, elements.filter { overviewCategory($0) == 1 },
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

    private func makePage(selected: [BrowserTabElement], position: ReadPosition,
                          regionCandidates: Set<Int64>, navigationCandidates: Set<Int64>, overview: Bool = false) throws -> ReadPage {
        let maximumElements = overview ? 18 : 60
        let bodyByteLimit = overview ? 6_000 : 10_000
        var page = ReadPage(nextPosition: position)
        var pageFragments = [[FieldFragment]]()
        var bytes = 0
        // The immutable action element is never replaced by its displayed
        // fragment. Only the current page's original elements authorize input.
        while page.nextPosition.element < selected.count, page.elements.count < maximumElements {
            let original = selected[page.nextPosition.element]
            let element = BrowserTabElement(
                index: page.elements.count, backendNodeID: original.backendNodeID, role: original.role,
                label: original.label, value: original.value, isEnabled: original.isEnabled,
                supportsPress: original.supportsPress, supportsSetText: original.supportsSetText,
                isDOMClickable: original.isDOMClickable, isFocusablePointer: original.isFocusablePointer,
                nodeID: original.nodeID, parentNodeID: original.parentNodeID,
                childNodeIDs: original.childNodeIDs, linkURL: original.linkURL,
                semanticRole: original.semanticRole, contentScope: original.contentScope, contentKind: original.contentKind
            )
            // A parent can occur later on this page. Reserve the largest
            // possible page index now, then resolve actual page membership.
            let reservedParentIndex = element.parentNodeID == nil ? nil : maximumElements - 1
            let regionCandidate = regionCandidates.contains(element.backendNodeID)
            let fields = readFields(element)
            var next = page.nextPosition
            var fragments = [FieldFragment]()
            let available = bodyByteLimit - bytes - 1 - SemanticReadPresentation.rowMetadataByteReserve
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
                        parentIndex: reservedParentIndex, regionCandidate: regionCandidate, navigationCandidate: navigationCandidates.contains(element.backendNodeID)).utf8.count
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
                    throw BrowserTabBrokerError.invalidRead("the observed element metadata exceeds the bounded read output")
                }
                break
            }
            let row = formatElement(element, fragments: fragments,
                parentIndex: reservedParentIndex, regionCandidate: regionCandidate, navigationCandidate: navigationCandidates.contains(element.backendNodeID))
            page.elements.append(element)
            pageFragments.append(fragments)
            bytes += row.utf8.count + 1 + SemanticReadPresentation.rowMetadataByteReserve
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
                regionCandidate: regionCandidates.contains(element.backendNodeID), navigationCandidate: navigationCandidates.contains(element.backendNodeID))
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

    private func formatElement(_ element: BrowserTabElement, fragments: [FieldFragment],
                               parentIndex: Int?, regionCandidate: Bool, navigationCandidate: Bool) -> String {
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
            + "enabled=\(element.isEnabled ? "true" : "false") "
            + "settable=\(element.supportsSetText ? "true" : "false") actions=\(actions)\(pressSource)"
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
            semanticRole: node.role
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
        retainedObservation: Bool
    ) throws -> String {
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
                + "next_cursor=\(nextCursor ?? "none") observation=\(retainedObservation ? "retained" : "live")"
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
            lines.append("OVERVIEW selection=observed_controls_headings_navigation ordering=interleaved_categories document_content_exhaustive=false. Read view=content for the document body; view=all retains full structural context for action planning.")
        }
        lines.append(contentsOf: rows)
        if document.semanticReadiness == .emptyAtDeadline {
            lines.append("Only a document shell or footer was observed before the readiness deadline; meaningful page content is still unresolved. This does not establish that requested content is absent.")
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

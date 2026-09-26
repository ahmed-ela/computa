import AppKit
import ApplicationServices
import AutomationCore
import Foundation

struct BrowserAttachedSession: Equatable, Sendable {
    let connectionGeneration: UUID
    let sessionID: String
    let incarnation: UUID
}

struct BrowserTarget: Equatable, Sendable {
    let targetID: String
    let instanceToken: String
    let title: String
    let url: URL
    let webSocketURL: URL?
    let attachedSession: BrowserAttachedSession?

    init(targetID: String, instanceToken: String, title: String, url: URL, webSocketURL: URL?) {
        self.targetID = targetID
        self.instanceToken = instanceToken
        self.title = title
        self.url = url
        self.webSocketURL = webSocketURL
        attachedSession = nil
    }

    init(targetID: String, title: String, url: URL, attachedSession: BrowserAttachedSession) {
        self.targetID = targetID
        instanceToken = attachedSession.incarnation.uuidString
        self.title = title
        self.url = url
        webSocketURL = nil
        self.attachedSession = attachedSession
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
}

struct BrowserDocumentObservation: Equatable, Sendable {
    let loaderID: String
    let title: String
    let url: URL
    let nodes: [BrowserDocumentNode]
}

protocol BrowserTabTransport: Sendable {
    func createTarget(url: URL) async throws -> BrowserTarget
    func target(id: String) async throws -> BrowserTarget?
    func activateTarget(id: String) async throws
    func closeTarget(target: BrowserTarget) async throws
    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation
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

/// Target lifetime is independent of browser/process ownership. A borrowed
/// broker must never be placed in ChromeTabBroker's owned process/profile path.
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

struct BrowserTabElement: Equatable, Sendable {
    let index: Int
    let backendNodeID: Int64
    let role: String
    let label: String
    let value: String?
    let isEnabled: Bool
    let supportsPress: Bool
    let supportsSetText: Bool
}

struct BrowserTabSnapshot: Equatable, Sendable {
    let id: UUID
    let tabHandle: UUID
    let documentEpoch: UUID
    let loaderID: String
    let documentURL: URL
    let elements: [BrowserTabElement]
    let formattedText: String

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
    case malformedDevToolsResponse(String)
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

    var errorDescription: String? {
        switch self {
        case .browserUnavailable(let detail):
            "The project-owned Chrome tab broker is unavailable: \(detail)"
        case .malformedDevToolsResponse(let detail):
            "Chrome DevTools returned an invalid response: \(detail)"
        case .handleMissing:
            "The bound browser tab handle is no longer available. Open the tab again."
        case .crossTaskHandle:
            "The browser tab handle belongs to a different task."
        case .browserGenerationChanged:
            "The brokered Chrome process changed. Open the browser tab again."
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
            "Chrome rejected the approved browser action: \(detail)"
        case .ownershipMismatch:
            "The browser tab operation does not match this broker's ownership policy."
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
    }

    private let transport: any BrowserTabTransport
    private let browserGeneration: UUID
    private let ownership: BrowserTabOwnership
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
        ownership: BrowserTabOwnership = .owned
    ) {
        self.transport = transport
        self.browserGeneration = browserGeneration
        self.ownership = ownership
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

    /// Adapter foundation only: no current ordinary-Chrome extension is wired
    /// here. The caller must already hold an authorized exact target identity.
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
        try beginOperation(taskKey: taskKey)
        defer { tasksInFlight.remove(taskKey) }
        var entry = try entry(
            taskKey: taskKey,
            binding: suppliedBinding,
            requiresCurrentEpoch: false
        )
        entry.activeSnapshot = nil
        entries[suppliedBinding.handle] = entry
        let target = try await currentTarget(for: suppliedBinding.handle, entry: entry)
        let document = try await transport.observe(target: target)
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

        if document.loaderID != entry.loaderID
            || document.url != entry.documentURL {
            entry.loaderID = document.loaderID
            entry.documentURL = document.url
            entry.documentEpoch = UUID()
            entry.activeSnapshot = nil
        }

        let elements = makeElements(from: document, query: query)
        let snapshotID = UUID()
        let currentBinding = binding(handle: suppliedBinding.handle, entry: entry)
        let formatted = formatSnapshot(
            snapshotID: snapshotID,
            binding: currentBinding,
            bundleIdentifier: bundleIdentifier,
            document: document,
            elements: elements
        )
        let snapshot = BrowserTabSnapshot(
            id: snapshotID,
            tabHandle: currentBinding.handle,
            documentEpoch: currentBinding.documentEpoch,
            loaderID: document.loaderID,
            documentURL: document.url,
            elements: elements,
            formattedText: formatted
        )
        entry.activeSnapshot = snapshot
        entries[suppliedBinding.handle] = entry
        return BrowserTabObservation(binding: currentBinding, snapshot: snapshot)
    }

    func perform(
        taskKey: String,
        binding suppliedBinding: BrowserTabBinding,
        snapshot suppliedSnapshot: BrowserTabSnapshot,
        elementIndex: Int,
        action: String
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
        entry.activeSnapshot = nil
        entries[suppliedBinding.handle] = entry
        guard let approvedElement = suppliedSnapshot.element(at: elementIndex) else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard approvedElement.supportsPress, approvedElement.isEnabled else {
            throw BrowserTabBrokerError.unsupportedAction(action)
        }

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

        try await transport.press(
            target: target,
            backendNodeID: approvedElement.backendNodeID,
            document: currentDocument,
            permit: permit
        )
    }

    func setText(
        taskKey: String,
        binding suppliedBinding: BrowserTabBinding,
        snapshot suppliedSnapshot: BrowserTabSnapshot,
        elementIndex: Int,
        text: String
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
        entry.activeSnapshot = nil
        entries[suppliedBinding.handle] = entry
        guard let approvedElement = suppliedSnapshot.element(at: elementIndex) else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard approvedElement.supportsSetText, approvedElement.isEnabled else {
            throw BrowserTabBrokerError.unsupportedAction("set text")
        }

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

        try await transport.setText(
            target: target,
            backendNodeID: approvedElement.backendNodeID,
            text: text,
            document: currentDocument,
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
    /// never from enumeration of arbitrary Chrome tabs with matching titles.
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
        query: String?
    ) -> [BrowserTabElement] {
        let candidates = document.nodes.compactMap {
            browserElement(from: $0, index: 0)
        }
        let trimmedQuery = query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let selected: [BrowserTabElement]
        if let trimmedQuery, !trimmedQuery.isEmpty {
            let matches = candidates.filter { element in
                [element.role, element.label, element.value]
                    .compactMap { $0?.lowercased() }
                    .contains(where: { $0.contains(trimmedQuery) })
            }
            selected = matches.isEmpty ? Array(candidates.prefix(80)) : matches
        } else {
            selected = Array(candidates.prefix(240))
        }

        return selected.prefix(240).enumerated().map { index, element in
            BrowserTabElement(
                index: index,
                backendNodeID: element.backendNodeID,
                role: element.role,
                label: element.label,
                value: element.value,
                isEnabled: element.isEnabled,
                supportsPress: element.supportsPress,
                supportsSetText: element.supportsSetText
            )
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
        let supportsPress = [
            "button", "checkbox", "link", "menuitem", "radio", "switch", "tab",
        ].contains(normalizedRole)
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
            supportsSetText: supportsSetText
        )
    }

    private func sameApprovedSemantics(
        _ current: BrowserTabElement,
        _ approved: BrowserTabElement
    ) -> Bool {
        current.backendNodeID == approved.backendNodeID
            && current.role == approved.role
            && current.label == approved.label
            && current.value == approved.value
            && current.isEnabled == approved.isEnabled
            && current.supportsPress == approved.supportsPress
            && current.supportsSetText == approved.supportsSetText
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

    private func formatSnapshot(
        snapshotID: UUID,
        binding: BrowserTabBinding,
        bundleIdentifier: String,
        document: BrowserDocumentObservation,
        elements: [BrowserTabElement]
    ) -> String {
        var lines = [
            "AXSNAPSHOT id=\(snapshotID.uuidString) pid=\(binding.processIdentifier) "
                + "bundle=\(quote(bundleIdentifier)) tab_handle=\(binding.handle.uuidString) "
                + "document_epoch=\(binding.documentEpoch.uuidString) source=chrome_devtools "
                + "url=\(quote(document.url.absoluteString)) title=\(quote(document.title))",
        ]
        for element in elements {
            let actions = element.supportsPress ? "[\"AXPress\"]" : "[]"
            let value = element.value.map { " value=\(quote($0))" } ?? ""
            lines.append(
                "#\(element.index) role=\(quote(element.role)) "
                    + "label=\(quote(element.label))\(value) "
                    + "enabled=\(element.isEnabled ? "true" : "false") "
                    + "settable=\(element.supportsSetText ? "true" : "false") "
                    + "actions=\(actions)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func quote(_ value: String) -> String {
        "\""
            + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            + "\""
    }
}

actor SystemChromeDevToolsTransport: BrowserTabTransport {
    private let baseURL: URL

    init(port: UInt16) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func createTarget(url: URL) async throws -> BrowserTarget {
        try requireBrowserAccessibilityPermission()
        let allowed = CharacterSet.urlQueryAllowed.subtracting(
            CharacterSet(charactersIn: "&=+#")
        )
        guard let encoded = url.absoluteString.addingPercentEncoding(
            withAllowedCharacters: allowed
        ), let endpoint = URL(string: "/json/new?\(encoded)", relativeTo: baseURL) else {
            throw BrowserTabBrokerError.browserUnavailable("the requested URL could not be encoded")
        }
        let object = try await requestJSONObject(url: endpoint, method: "PUT")
        return try parseTarget(object)
    }

    func target(id: String) async throws -> BrowserTarget? {
        let targets = try await listTargets()
        return targets.first(where: { $0.targetID == id })
    }

    func activateTarget(id: String) async throws {
        guard let endpoint = URL(
            string: "/json/activate/\(id)",
            relativeTo: baseURL
        ) else {
            throw BrowserTabBrokerError.browserUnavailable("the target ID is invalid")
        }
        _ = try await requestData(url: endpoint, method: "GET")
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        try requireBrowserAccessibilityPermission()
        let current = try await requireCurrent(target)
        guard let endpoint = current.webSocketURL, current.attachedSession == nil else {
            throw BrowserTabBrokerError.ownershipMismatch
        }
        let socket = ChromeDevToolsSocket(url: endpoint)
        defer { socket.close() }
        return try await BrowserCDPDocumentOperations().observe(target: current, socket: socket)
    }

    func press(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        try requireBrowserAccessibilityPermission()
        let current = try await requireCurrent(target)
        guard let endpoint = current.webSocketURL, current.attachedSession == nil else {
            throw BrowserTabBrokerError.ownershipMismatch
        }
        let socket = ChromeDevToolsSocket(url: endpoint)
        defer { socket.close() }
        try await BrowserCDPDocumentOperations().press(
            target: current, backendNodeID: backendNodeID, document: document,
            permit: permit, socket: socket
        )
    }

    func setText(
        target: BrowserTarget,
        backendNodeID: Int64,
        text: String,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        try requireBrowserAccessibilityPermission()
        let current = try await requireCurrent(target)
        guard let endpoint = current.webSocketURL, current.attachedSession == nil else {
            throw BrowserTabBrokerError.ownershipMismatch
        }
        let socket = ChromeDevToolsSocket(url: endpoint)
        defer { socket.close() }
        try await BrowserCDPDocumentOperations().setText(
            target: current, backendNodeID: backendNodeID, text: text,
            document: document, permit: permit, socket: socket
        )
    }

    func listTargets() async throws -> [BrowserTarget] {
        guard let endpoint = URL(string: "/json/list", relativeTo: baseURL) else {
            throw BrowserTabBrokerError.browserUnavailable("the target-list URL is invalid")
        }
        let data = try await requestData(url: endpoint, method: "GET")
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BrowserTabBrokerError.malformedDevToolsResponse(
                "/json/list did not return an array"
            )
        }
        return values.compactMap { value in
            guard value["type"] as? String == "page" else { return nil }
            return try? parseTarget(value)
        }
    }

    func closeTarget(target: BrowserTarget) async throws {
        guard let current = try await self.target(id: target.targetID) else { return }
        guard current.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        try await closeTarget(id: current.targetID)
    }

    func closeTarget(id: String) async throws {
        guard let endpoint = URL(
            string: "/json/close/\(id)",
            relativeTo: baseURL
        ) else {
            throw BrowserTabBrokerError.browserUnavailable("the target ID is invalid")
        }
        _ = try await requestData(url: endpoint, method: "GET")
    }

    private func requireCurrent(_ target: BrowserTarget) async throws -> BrowserTarget {
        guard let current = try await self.target(id: target.targetID) else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard current.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        return current
    }


    private func parseTarget(_ object: [String: Any]) throws -> BrowserTarget {
        let allowedID = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        guard let targetID = object["id"] as? String,
              !targetID.isEmpty, targetID.utf8.count <= 128,
              let rawURL = object["url"] as? String,
              let url = URL(string: rawURL),
              let rawWebSocketURL = object["webSocketDebuggerUrl"] as? String,
              let webSocketURL = URL(string: rawWebSocketURL),
              webSocketURL.scheme == "ws",
              webSocketURL.host == "127.0.0.1",
              webSocketURL.port == baseURL.port,
              webSocketURL.user == nil, webSocketURL.password == nil,
              webSocketURL.query == nil, webSocketURL.fragment == nil,
              webSocketURL.path == "/devtools/page/\(targetID)" else {
            throw BrowserTabBrokerError.malformedDevToolsResponse(
                "a page target was missing its ID, URL, or WebSocket endpoint"
            )
        }
        // Avoid the optimized allSatisfy(bound-method) specialization shared
        // with contains(where:); keep identifier rejection explicit.
        for scalar in targetID.unicodeScalars {
            if !allowedID.contains(scalar) {
                throw BrowserTabBrokerError.malformedDevToolsResponse("a page target had an invalid ID")
            }
        }
        return BrowserTarget(
            targetID: targetID,
            instanceToken: webSocketURL.absoluteString,
            title: object["title"] as? String ?? "",
            url: url,
            webSocketURL: webSocketURL
        )
    }


    private func requestJSONObject(
        url: URL,
        method: String
    ) async throws -> [String: Any] {
        let data = try await requestData(url: url, method: method)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserTabBrokerError.malformedDevToolsResponse(
                "\(url.path) did not return a JSON object"
            )
        }
        return object
    }

    private func requestData(url: URL, method: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            throw BrowserTabBrokerError.browserUnavailable(
                "\(method) \(url.path) did not return success"
            )
        }
        return data
    }
}

private actor ChromeDevToolsSocket: BrowserDocumentChannel {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var nextID = 1
    private let deadline: Task<Void, Never>

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
        let socketTask = session.webSocketTask(with: url)
        task = socketTask
        deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            socketTask.cancel(with: .goingAway, reason: nil)
        }
        socketTask.resume()
    }

    func request(
        method: String,
        params: Data,
        permit: BrowserMutationPermit?
    ) async throws -> Data {
        try Task.checkCancellation()
        let parameters = try JSONSerialization.jsonObject(with: params)
        let id = nextID
        nextID += 1
        let request: [String: Any] = [
            "id": id,
            "method": method,
            "params": parameters,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BrowserTabBrokerError.malformedDevToolsResponse(
                "a command could not be encoded as UTF-8"
            )
        }
        if let permit {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try permit.commit {
                        try requireBrowserAccessibilityPermission()
                        task.send(.string(text)) { error in
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: ())
                            }
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } else {
            try await task.send(.string(text))
        }

        while true {
            try Task.checkCancellation()
            let message = try await task.receive()
            let responseData: Data
            switch message {
            case .data(let data):
                responseData = data
            case .string(let text):
                responseData = Data(text.utf8)
            @unknown default:
                throw BrowserTabBrokerError.malformedDevToolsResponse(
                    "an unknown WebSocket message was received"
                )
            }
            guard let object = try JSONSerialization.jsonObject(
                with: responseData
            ) as? [String: Any] else {
                throw BrowserTabBrokerError.malformedDevToolsResponse(
                    "a WebSocket response was not a JSON object"
                )
            }
            guard (object["id"] as? NSNumber)?.intValue == id else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                throw BrowserTabBrokerError.malformedDevToolsResponse(
                    error["message"] as? String ?? "\(method) failed"
                )
            }
            guard let result = object["result"] as? [String: Any] else {
                throw BrowserTabBrokerError.malformedDevToolsResponse(
                    "\(method) returned no result"
                )
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }

    nonisolated func close() {
        deadline.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func invalidate() { close() }
}

/// A narrow lifecycle seam. Live ownership still comes only from OwnedChildProcess.
protocol BrowserOwnedChild: Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    func stop() async -> OwnedChildProcess.StopResult
}

extension OwnedChildProcess: BrowserOwnedChild {}

actor ChromeTabBroker {
    struct OpenedTab: Sendable {
        let application: ActivatedApplication
        let binding: BrowserTabBinding
    }

    static let shared = ChromeTabBroker()

    struct BrowserProcess: Sendable {
        let process: any BrowserOwnedChild
        let dataDirectory: URL
        let generation: UUID
        let transport: SystemChromeDevToolsTransport
        let sessions: BrowserTabSessionBroker
    }

    /// Tests can construct a fresh child without launching Chrome. The post-spawn
    /// hook runs only after that child and its directory are recorded by the owner.
    struct LaunchOperations: Sendable {
        let resolveExecutable: @Sendable () async throws -> URL
        let createProfile: @Sendable (URL) throws -> Void
        let spawn: @Sendable (URL, [String]) throws -> any BrowserOwnedChild
        let didSpawn: @Sendable (any BrowserOwnedChild, URL) async throws -> Void

        static let live = Self(
            resolveExecutable: {
                let applicationURL = await MainActor.run {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
                }
                guard let applicationURL else {
                    throw BrowserTabBrokerError.browserUnavailable("Google Chrome is not installed")
                }
                let executableURL = applicationURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("MacOS", isDirectory: true)
                    .appendingPathComponent("Google Chrome")
                guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                    throw BrowserTabBrokerError.browserUnavailable(
                        "the Google Chrome executable could not be found"
                    )
                }
                return executableURL
            },
            createProfile: { directory in
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            },
            spawn: { executableURL, arguments in
                try OwnedChildProcess(executableURL: executableURL, arguments: arguments)
            },
            didSpawn: { _, _ in }
        )
    }

    private var browser: BrowserProcess?
    private var isStartingBrowser = false
    private var isShuttingDown = false
    private var startingProcess: (any BrowserOwnedChild)?
    private var startingDirectory: URL?
    private var ownedDirectories = Set<URL>()
    private var unboundTargets = [String: BrowserTarget]()
    private var lifetimes = [ObjectIdentifier: BrowserTabLifetime]()
    private var shutdownTask: Task<ShutdownReport, Never>?
    private var exactCloseIssues = [String]()
    private struct RetirementResult: Sendable {
        let stopped: OwnedChildProcess.StopResult
        let profileRemoved: Bool
        let profileIssue: String?
    }
    private struct Retirement: Sendable {
        let directory: URL
        let task: Task<RetirementResult, Never>
    }
    private var retirement: Retirement?
    private let removeProfile: @Sendable (URL) async -> String?
    private let willLaunchBrowser: @Sendable () async throws -> Void
    private let launchOperations: LaunchOperations
    // Optional instrumentation. Nil in production and in the primitive gate.
    // A configured read-only observer completes before a successful press returns;
    // it neither authorizes input nor delays synchronous lifetime revocation.
    private let didPerformPress: (@Sendable (BrowserTabBinding, BrowserTabSnapshot) async -> Void)?

    /// Live defaults construct only an OwnedChildProcess. Lifecycle tests may
    /// inject a fresh fake child; neither path adopts a discovered process ID.
    init(
        initialBrowser: BrowserProcess? = nil,
        removeProfile: @escaping @Sendable (URL) async -> String? = {
            await OwnedProfileCleanup.remove($0)
        },
        willLaunchBrowser: @escaping @Sendable () async throws -> Void = {},
        launchOperations: LaunchOperations = .live,
        didPerformPress: (@Sendable (BrowserTabBinding, BrowserTabSnapshot) async -> Void)? = nil
    ) {
        browser = initialBrowser
        self.removeProfile = removeProfile
        self.willLaunchBrowser = willLaunchBrowser
        self.launchOperations = launchOperations
        self.didPerformPress = didPerformPress
        if let initialBrowser { ownedDirectories.insert(initialBrowser.dataDirectory) }
    }

    struct Ownership: Equatable, Sendable {
        let processGroupID: Int32
        let profileDirectory: URL
    }

    struct ShutdownReport: Equatable, Sendable {
        let ownership: [Ownership]
        let issues: [String]
        var succeeded: Bool { issues.isEmpty }
    }

    /// Diagnostics are retained through shutdown. Successful group/profile
    /// disposal can reconcile a close race, but must not erase its evidence.
    func exactTargetCleanupIssues() -> [String] { exactCloseIssues }

    func ownership() -> Ownership? {
        if let browser {
            return Ownership(
                processGroupID: browser.process.processIdentifier,
                profileDirectory: browser.dataDirectory
            )
        }
        if let startingProcess, let startingDirectory {
            return Ownership(
                processGroupID: startingProcess.processIdentifier,
                profileDirectory: startingDirectory
            )
        }
        return nil
    }

    func shutdown() async -> ShutdownReport {
        await beginShutdown().value
    }

    /// Synchronously revoke and return the one owned disposal operation.
    /// Tests can establish this boundary without sleeps or scheduler assumptions.
    func beginShutdown() -> Task<ShutdownReport, Never> {
        if let shutdownTask { return shutdownTask }
        isShuttingDown = true
        for lifetime in lifetimes.values { lifetime.revoke() }
        lifetimes.removeAll()
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        return task
    }

    private func finishShutdown() async -> ShutdownReport {
        let active = browser
        let starting = startingProcess
        let directory = startingDirectory
        let retiring = retirement
        browser = nil
        startingProcess = nil
        startingDirectory = nil
        retirement = nil
        unboundTargets.removeAll()
        if let active { await active.sessions.invalidateAll() }

        var children = [(any BrowserOwnedChild, URL)]()
        if let active { children.append((active.process, active.dataDirectory)) }
        if let starting, let directory,
           !children.contains(where: { $0.0.processIdentifier == starting.processIdentifier }) {
            children.append((starting, directory))
        }
        var issues = [String]()
        var ownership = [Ownership]()
        let unlaunchedDirectories = ownedDirectories.subtracting(Set(children.map { $0.1 }))
        for (process, directory) in children {
            ownership.append(Ownership(
                processGroupID: process.processIdentifier,
                profileDirectory: directory
            ))
            let stopped: OwnedChildProcess.StopResult
            var profileRemoved = false
            if let retiring, retiring.directory == directory {
                // Retirement remains the sole stop/removal owner while suspended.
                // Join it; never invoke stop concurrently or discard its errors.
                let result = await retiring.task.value
                stopped = result.stopped
                profileRemoved = result.profileRemoved
                if let issue = result.profileIssue { issues.append(issue) }
            } else {
                stopped = await process.stop()
            }
            issues.append(contentsOf: stopped.issues)
            // Disposal can remove a safe profile while still reporting stop issues.
            // A failed earlier removal may be retried sequentially, with its
            // original error retained even when the retry succeeds.
            if stopped.rootReaped && stopped.groupGone {
                if profileRemoved {
                    ownedDirectories.remove(directory)
                } else if let issue = await removeProfile(directory) {
                    issues.append(issue)
                } else {
                    ownedDirectories.remove(directory)
                }
            } else {
                issues.append("Retained the profile because owned process cleanup was incomplete: \(directory.path)")
            }
        }
        for directory in unlaunchedDirectories {
            if let issue = await removeProfile(directory) {
                issues.append(issue)
            } else {
                ownedDirectories.remove(directory)
            }
        }
        return ShutdownReport(ownership: ownership, issues: issues)
    }

    func open(
        taskKey: String,
        url: URL,
        lifetime: BrowserTabLifetime = BrowserTabLifetime()
    ) async throws -> OpenedTab {
        try requireBrowserAccessibilityPermission()
        guard !isShuttingDown else { throw BrowserTabBrokerError.handleMissing }
        try lifetime.check()
        let lifetimeID = ObjectIdentifier(lifetime)
        lifetimes[lifetimeID] = lifetime
        var published = false
        defer {
            if !published { lifetimes.removeValue(forKey: lifetimeID) }
        }
        let browser = try await ensureBrowser()
        try lifetime.check()
        let processIdentifier = browser.process.processIdentifier
        let binding = try await browser.sessions.open(
            taskKey: taskKey,
            processIdentifier: processIdentifier,
            url: url,
            lifetime: lifetime
        )
        do {
            try lifetime.check()
            // Never close another task's blank or still-loading target.
            let application = try await activatedApplication(
                processIdentifier: processIdentifier
            )
            try lifetime.check()
            _ = try currentBrowser(generation: binding.browserGeneration)
            published = true
            return OpenedTab(application: application, binding: binding)
        } catch {
            try? await browser.sessions.revoke(taskKey: taskKey, binding: binding)
            throw error
        }
    }

    func snapshot(
        taskKey: String,
        binding: BrowserTabBinding,
        query: String?
    ) async throws -> BrowserTabObservation {
        let browser = try currentBrowser(generation: binding.browserGeneration)
        return try await browser.sessions.snapshot(
            taskKey: taskKey,
            binding: binding,
            bundleIdentifier: "com.google.Chrome",
            query: query
        )
    }

    func perform(
        taskKey: String,
        binding: BrowserTabBinding,
        snapshot: BrowserTabSnapshot,
        elementIndex: Int,
        action: String
    ) async throws {
        let browser = try currentBrowser(generation: binding.browserGeneration)
        try await browser.sessions.perform(
            taskKey: taskKey,
            binding: binding,
            snapshot: snapshot,
            elementIndex: elementIndex,
            action: action
        )
        if let didPerformPress {
            // Normal tool response/turn completion follows this awaited boundary.
            // The observer receives immutable provenance, not mutation authority.
            await didPerformPress(binding, snapshot)
        }
    }

    func setText(
        taskKey: String,
        binding: BrowserTabBinding,
        snapshot: BrowserTabSnapshot,
        elementIndex: Int,
        text: String
    ) async throws {
        let browser = try currentBrowser(generation: binding.browserGeneration)
        try await browser.sessions.setText(
            taskKey: taskKey,
            binding: binding,
            snapshot: snapshot,
            elementIndex: elementIndex,
            text: text
        )
    }

    func revoke(taskKey: String, binding: BrowserTabBinding) async {
        guard binding.taskKey == taskKey else { return }
        binding.lifetime.revoke()
        lifetimes.removeValue(forKey: ObjectIdentifier(binding.lifetime))
        guard let browser, browser.generation == binding.browserGeneration else { return }
        do {
            try await browser.sessions.revoke(taskKey: taskKey, binding: binding)
        } catch BrowserTabBrokerError.handleMissing {
            // Already revoked or known closed/replaced; never retarget by URL.
        } catch {
            exactCloseIssues.append(error.localizedDescription)
            NSLog("Exact broker target cleanup failed: %@", error.localizedDescription)
        }
    }

    func openUnboundForegroundTab(
        processIdentifier: Int32,
        url: URL
    ) async throws -> ActivatedApplication {
        guard !isShuttingDown, let browser,
              browser.process.isRunning,
              browser.process.processIdentifier == processIdentifier else {
            throw BrowserTabBrokerError.browserGenerationChanged
        }
        let target = try await browser.transport.createTarget(url: url)
        do {
            _ = try currentBrowser(generation: browser.generation)
            unboundTargets[target.targetID] = target
            try await browser.transport.activateTarget(id: target.targetID)
            return try await activatedApplication(processIdentifier: processIdentifier)
        } catch {
            try? await browser.transport.closeTarget(target: target)
            unboundTargets.removeValue(forKey: target.targetID)
            throw error
        }
    }

    func closeTabs(
        processIdentifier: Int32,
        urls: Set<URL>
    ) async throws {
        guard !isShuttingDown, let browser,
              browser.process.processIdentifier == processIdentifier else {
            throw BrowserTabBrokerError.browserGenerationChanged
        }
        try await browser.sessions.closeTargets(urls: urls)
        let targets = unboundTargets.values.filter { urls.contains($0.url) }
        for target in targets {
            try await browser.transport.closeTarget(target: target)
            unboundTargets.removeValue(forKey: target.targetID)
        }
    }

    /// Internal so deterministic tests exercise this caller's actual restart gate.
    /// Model-facing opens still enter through open(), including its permission check.
    func ensureBrowser() async throws -> BrowserProcess {
        guard !isShuttingDown else {
            throw BrowserTabBrokerError.browserUnavailable("the broker has been shut down")
        }
        if let browser, browser.process.isRunning { return browser }
        guard startingProcess == nil || isStartingBrowser else {
            throw BrowserTabBrokerError.browserUnavailable(
                "prior owned cleanup is incomplete; shut down this broker before retrying"
            )
        }
        guard browser != nil || ownedDirectories.isEmpty || isStartingBrowser else {
            throw BrowserTabBrokerError.browserUnavailable(
                "prior owned cleanup is incomplete; shut down this broker before retrying"
            )
        }
        guard !isStartingBrowser else {
            throw BrowserTabBrokerError.browserUnavailable(
                "the isolated browser is starting; retry after it becomes ready"
            )
        }
        isStartingBrowser = true
        defer { isStartingBrowser = false }
        let retired = browser
        browser = nil
        if let retired {
            startingProcess = retired.process
            startingDirectory = retired.dataDirectory
            let remove = removeProfile
            let operation = Task {
                await retired.sessions.invalidateAll()
                let stopped = await retired.process.stop()
                // Restart requires total stop success. Shutdown may subsequently
                // remove a physically safe profile despite an unexpected stop issue.
                guard stopped.succeeded else {
                    return RetirementResult(stopped: stopped, profileRemoved: false, profileIssue: nil)
                }
                let issue = await remove(retired.dataDirectory)
                return RetirementResult(stopped: stopped, profileRemoved: issue == nil, profileIssue: issue)
            }
            // Publish the operation BEFORE the first await. Shutdown must join it.
            retirement = Retirement(directory: retired.dataDirectory, task: operation)
            let result = await operation.value
            if isShuttingDown {
                let report = await shutdown()
                guard report.succeeded else {
                    throw BrowserTabBrokerError.browserUnavailable(report.issues.joined(separator: "; "))
                }
                throw BrowserTabBrokerError.handleMissing
            }
            guard result.stopped.succeeded else {
                let detail = result.stopped.issues.isEmpty
                    ? "owned root/group cleanup is incomplete"
                    : result.stopped.issues.joined(separator: "; ")
                throw BrowserTabBrokerError.browserUnavailable(detail)
            }
            if let issue = result.profileIssue {
                throw BrowserTabBrokerError.browserUnavailable(issue)
            }
            ownedDirectories.remove(retired.dataDirectory)
            retirement = nil
            if startingDirectory == retired.dataDirectory {
                startingProcess = nil
                startingDirectory = nil
            }
            guard !isShuttingDown else { throw BrowserTabBrokerError.handleMissing }
        }
        try await willLaunchBrowser()
        guard !isShuttingDown else { throw BrowserTabBrokerError.handleMissing }
        let executableURL = try await launchOperations.resolveExecutable()
        guard !isShuttingDown else { throw BrowserTabBrokerError.handleMissing }

        let generation = UUID()
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexBrowserBroker-\(generation.uuidString)", isDirectory: true)
        try launchOperations.createProfile(dataDirectory)
        ownedDirectories.insert(dataDirectory)
        var launchedProcess: (any BrowserOwnedChild)?
        do {
            // No await between construction and publishing ownership. A shutdown
            // entering at didSpawn/readiness can therefore find the fresh child.
            let process = try launchOperations.spawn(
                executableURL,
                [
                    "--remote-debugging-address=127.0.0.1",
                    "--remote-debugging-port=0",
                    "--user-data-dir=\(dataDirectory.path)",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-background-networking",
                    "--disable-background-mode",
                    "--disable-component-update",
                    "--new-window",
                    "about:blank",
                ]
            )
            launchedProcess = process
            startingProcess = process
            startingDirectory = dataDirectory
            try await launchOperations.didSpawn(process, dataDirectory)
            guard !isShuttingDown else { throw BrowserTabBrokerError.handleMissing }
            let port = try await waitForDevToolsPort(
                dataDirectory: dataDirectory, process: process
            )
            guard !isShuttingDown else { throw BrowserTabBrokerError.handleMissing }
            let transport = SystemChromeDevToolsTransport(port: port)
            let sessions = BrowserTabSessionBroker(
                transport: transport, browserGeneration: generation
            )
            let launched = BrowserProcess(
                process: process,
                dataDirectory: dataDirectory,
                generation: generation,
                transport: transport,
                sessions: sessions
            )
            browser = launched
            startingProcess = nil
            startingDirectory = nil
            return launched
        } catch {
            if isShuttingDown {
                // didSpawn/readiness may resume after shutdown has taken ownership.
                // Join that cached disposal rather than re-stopping/re-removing or
                // publishing a second cleanup result after the final report.
                let report = await shutdown()
                if !report.succeeded {
                    throw BrowserTabBrokerError.browserUnavailable(
                        "\(error.localizedDescription); owned shutdown failed: "
                            + report.issues.joined(separator: "; ")
                    )
                }
                throw error
            }
            var cleanupComplete = false
            var stopSucceeded = true
            var cleanupIssues = [String]()
            if let launchedProcess {
                let stopped = await launchedProcess.stop()
                stopSucceeded = stopped.succeeded
                cleanupIssues.append(contentsOf: stopped.issues)
                if !stopSucceeded && stopped.issues.isEmpty {
                    cleanupIssues.append("owned root/group cleanup is incomplete")
                }
                // Safe deletion does not authorize a later launch after stop issues.
                if stopped.rootReaped && stopped.groupGone {
                    if let issue = await removeProfile(dataDirectory) {
                        cleanupIssues.append(issue)
                    } else {
                        cleanupComplete = true
                    }
                }
            } else {
                if let issue = await removeProfile(dataDirectory) {
                    cleanupIssues.append(issue)
                } else {
                    cleanupComplete = true
                }
            }
            if cleanupComplete {
                ownedDirectories.remove(dataDirectory)
                if stopSucceeded && startingDirectory == dataDirectory {
                    startingProcess = nil
                    startingDirectory = nil
                }
            }
            // Failed stop ownership stays recorded even if its profile is gone.
            // Preserve simultaneous stop AND profile errors with the launch error.
            if !cleanupIssues.isEmpty {
                let detail = cleanupIssues.joined(separator: "; ")
                throw BrowserTabBrokerError.browserUnavailable(
                    "\(error.localizedDescription); owned launch cleanup failed: \(detail)"
                )
            }
            throw error
        }
    }

    private func currentBrowser(generation: UUID) throws -> BrowserProcess {
        guard !isShuttingDown, let browser, browser.process.isRunning else {
            throw BrowserTabBrokerError.browserUnavailable(
                "the brokered Chrome process exited"
            )
        }
        guard browser.generation == generation else {
            throw BrowserTabBrokerError.browserGenerationChanged
        }
        return browser
    }

    private func waitForDevToolsPort(
        dataDirectory: URL,
        process: any BrowserOwnedChild
    ) async throws -> UInt16 {
        let activePortURL = dataDirectory.appendingPathComponent("DevToolsActivePort")
        for attempt in 0 ..< 200 {
            try Task.checkCancellation()
            guard !isShuttingDown else { throw BrowserTabBrokerError.handleMissing }
            guard process.isRunning else {
                throw BrowserTabBrokerError.browserUnavailable(
                    "Chrome exited before remote debugging became ready"
                )
            }
            if let data = try? Data(contentsOf: activePortURL) {
                let contents = String(decoding: data, as: UTF8.self)
                let lines = contents.split(
                    whereSeparator: \.isNewline
                ).map(String.init)
                if lines.count >= 2,
                   let port = UInt16(lines[0]), port > 0,
                   lines[1].hasPrefix("/devtools/browser/") {
                    return port
                }
            }
            if attempt < 199 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw BrowserTabBrokerError.browserUnavailable(
            "Chrome did not publish DevToolsActivePort"
        )
    }

    private func activatedApplication(
        processIdentifier: Int32
    ) async throws -> ActivatedApplication {
        for attempt in 0 ..< 120 {
            try Task.checkCancellation()
            guard !isShuttingDown else { throw BrowserTabBrokerError.handleMissing }
            let values: (String?, String?, Bool)? = await MainActor.run {
                guard let application = NSRunningApplication(
                    processIdentifier: processIdentifier
                ) else {
                    return nil
                }
                return (
                    application.bundleIdentifier,
                    application.localizedName,
                    application.isTerminated
                )
            }
            if let values,
               values.0 == "com.google.Chrome",
               !values.2 {
                return ActivatedApplication(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: values.0 ?? "com.google.Chrome",
                    localizedName: values.1
                )
            }
            if attempt < 119 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw BrowserTabBrokerError.browserUnavailable(
            "the brokered Chrome process did not register with AppKit"
        )
    }
}

import CoreFoundation
import Foundation
import OSLog
import WebKit

/// Finite native diagnostics only. No page-provided strings, document identity,
/// or source content are retained or forwarded to the model.
struct BrowserCaptureDiagnostics: Codable, Equatable, Sendable {
    enum StopReason: String, Codable, Sendable { case none, visitedLimit = "visited_limit", nodeLimit = "node_limit", byteBudget = "byte_budget" }
    enum VisibilityState: String, Codable, Sendable { case visible, hidden, prerender, unknown }
    let stopReason: StopReason
    let visited: Int
    let emitted: Int
    let estimatedBytes: Int
    let visibilityState: VisibilityState
    let viewportWidth: Int
    let viewportHeight: Int
    let frames: Int
    let shadowRoots: Int
    let oversizedRoles: Int
    let clippedFields: Int
    let boxlessContents: Int
    let scheduling: Scheduling?
    let discovery: Discovery?

    /// Only the existing bounded priority-discovery walk contributes counts.
    /// Panel states use rendered/display-none/hard-hidden/visibility-hidden/no-box
    /// order; a limit-reached walk never establishes that missing controls are absent.
    struct Discovery: Codable, Equatable, Sendable {
        let panelsByState: [Int]
        let prunedSubtrees: Int
        let limitReached: Bool

        static func valid(_ raw: Any, scheduling: Any?) -> Bool {
            guard let fields = raw as? [String: Any],
                  Set(fields.keys) == ["panelsByState", "prunedSubtrees", "limitReached"],
                  let scheduling = scheduling as? [String: Any],
                  let slots = integer(scheduling["discoverySlots"]),
                  let counts = fields["panelsByState"] as? [Any], counts.count == 5,
                  let pruned = integer(fields["prunedSubtrees"]),
                  let limitReached = fields["limitReached"] as? NSNumber,
                  CFGetTypeID(limitReached) == CFBooleanGetTypeID() else { return false }
            let panels = counts.compactMap(integer)
            // The root can be inspected without consuming a child-discovery
            // slot. A limit-reached diagnostic must refer to the existing shared
            // ceiling, never a reset clock or an added traversal.
            return panels.count == 5 && panels.reduce(0, +) <= min(4_096, slots + 1)
                && pruned <= slots + 1 && (!limitReached.boolValue || slots == 4_096)
        }

        private static func integer(_ raw: Any?) -> Int? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  (0...4_096).contains(number.doubleValue) else { return nil }
            return number.intValue
        }
    }

    /// Counts come from the existing bounded traversal, never page content.
    /// Priority arrays use the fixed focus/dialog/form/ordinary order.
    struct Scheduling: Codable, Equatable, Sendable {
        let discoverySlots: Int
        let panelProbes: Int
        let partialPanels: Int
        let controlsSeen: Int
        let controlsVisible: Int
        let controlsPrioritized: Int
        let controlsEmitted: Int
        let emittedByPriority: [Int]
        let pendingByPriority: [Int]
        let pendingClipped: Bool

        static func valid(_ raw: Any, emitted: Int) -> Bool {
            let counts = ["discoverySlots", "panelProbes", "partialPanels", "controlsSeen", "controlsVisible", "controlsPrioritized", "controlsEmitted"]
            guard let fields = raw as? [String: Any],
                  Set(fields.keys) == Set(counts + ["emittedByPriority", "pendingByPriority", "pendingClipped"]) else { return false }
            func integer(_ raw: Any?, limit: Int) -> Int? {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      (0...Double(limit)).contains(number.doubleValue) else { return nil }
                return number.intValue
            }
            var values: [String: Int] = [:]
            for key in counts {
                guard let value = integer(fields[key], limit: key == "controlsEmitted" ? 3_000 : 4_096) else { return false }
                values[key] = value
            }
            guard values["partialPanels"]! <= values["panelProbes"]!,
                  values["controlsEmitted"]! <= values["controlsPrioritized"]!,
                  values["controlsPrioritized"]! <= values["controlsVisible"]!,
                  values["controlsVisible"]! <= values["controlsSeen"]!, values["controlsEmitted"]! <= emitted,
                  let emittedRaw = fields["emittedByPriority"] as? [Any], emittedRaw.count == 4,
                  let pendingRaw = fields["pendingByPriority"] as? [Any], pendingRaw.count == 4,
                  let clipped = fields["pendingClipped"] as? NSNumber, CFGetTypeID(clipped) == CFBooleanGetTypeID() else { return false }
            let emittedValues = emittedRaw.compactMap { integer($0, limit: 3_000) }
            let pendingValues = pendingRaw.compactMap { integer($0, limit: 20_001) }
            return emittedValues.count == 4 && emittedValues.reduce(0, +) == emitted && pendingValues.count == 4
                && (!clipped.boolValue || pendingValues.contains(20_001))
        }
    }

    static func decode(_ raw: Any?, emitted: Int, sourceTruncated: Bool) throws -> Self {
        let baseKeys: Set<String> = ["stopReason", "visited", "emitted", "estimatedBytes", "visibilityState", "viewportWidth", "viewportHeight", "frames",
                                     "shadowRoots", "oversizedRoles", "clippedFields", "boxlessContents"]
        guard let fields = raw as? [String: Any],
              baseKeys.isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: baseKeys.union(["scheduling", "discovery"])),
              fields["scheduling"].map({ Scheduling.valid($0, emitted: emitted) }) ?? true,
              fields["discovery"].map({ Discovery.valid($0, scheduling: fields["scheduling"]) }) ?? true,
              let bytes = try? JSONSerialization.data(withJSONObject: fields), bytes.count <= 768,
              let value = try? JSONDecoder().decode(Self.self, from: bytes),
              (0...20_001).contains(value.visited), (0...3_000).contains(value.emitted),
              value.emitted == emitted, value.emitted <= value.visited,
              (0...1_000_000).contains(value.estimatedBytes),
              (0...1_000_000).contains(value.viewportWidth), (0...1_000_000).contains(value.viewportHeight),
              [value.frames, value.shadowRoots, value.oversizedRoles, value.clippedFields, value.boxlessContents]
                .allSatisfy({ (0...20_000).contains($0) && $0 <= value.visited }),
              sourceTruncated == (value.stopReason != .none || value.frames > 0 || value.shadowRoots > 0
                                  || value.oversizedRoles > 0 || value.clippedFields > 0)
        else { throw BrowserTabBrokerError.browserUnavailable("The built-in page returned invalid capture diagnostics.") }
        return value
    }
}

struct BrowserCaptureLogRecord: Encodable {
    let kind = "browser_capture_v1"
    let tabID: UUID
    let generation: UUID
    let requestedReadiness: String
    let readiness: String
    let capture: BrowserCaptureDiagnostics
    let viewAttached: Bool
    let viewHasWindow: Bool
    let viewHidden: Bool
    let viewWidth: Int
    let viewHeight: Int
}

/// Runtime integration depends on this narrow backend, rather than WebKit or
/// native window focus. Fixtures can implement it without launching a browser.
protocol EmbeddedBrowserControlBackend: BrowserTabTransport {
    func humanTargets() async throws -> [BrowserTarget]
    func acquireRendering(target: BrowserTarget, lifetime: BrowserTabLifetime) async throws
    func releaseRendering(target: BrowserTarget, lifetime: BrowserTabLifetime) async
    func navigate(target: BrowserTarget, url: URL, permit: BrowserMutationPermit) async throws
    func wait(target: BrowserTarget, text: String?, timeoutMS: Int) async throws -> Bool
    func waitForDocumentChange(target: BrowserTarget, checkpoint: BrowserDocumentChangeCheckpoint,
                               timeoutMS: Int, authorization: @escaping BrowserReadAuthorization) async throws
        -> BrowserDocumentChangeResult
    func closeOwnedTargets() async -> [String]
}

extension EmbeddedBrowserControlBackend {
    func acquireRendering(target: BrowserTarget, lifetime: BrowserTabLifetime) async throws {}
    func releaseRendering(target: BrowserTarget, lifetime: BrowserTabLifetime) async {}
    /// Backends must implement the native predicate or explicitly reject it;
    /// an ordinary readiness check cannot stand in for document change.
    func waitForDocumentChange(target: BrowserTarget, checkpoint: BrowserDocumentChangeCheckpoint,
                               timeoutMS: Int, authorization: @escaping BrowserReadAuthorization) async throws
        -> BrowserDocumentChangeResult {
        throw BrowserTabBrokerError.browserUnavailable("This browser backend does not support document-change waits.")
    }
}

/// Uses only Computa's human WebViews. Inference pages and the privileged app UI
/// are absent from this inventory, even when their titles or URLs match.
@MainActor
final class EmbeddedBrowserTabTransport: EmbeddedBrowserControlBackend {
    private let session: EmbeddedBrowserSession
    private let world = WKContentWorld.world(name: "Computa.BrowserControl.\(UUID().uuidString)")
    private var owned = [UUID: String]()
    private struct RenderingLease {
        let target: BrowserTarget
        let lifetime: BrowserTabLifetime
        let token: UUID
    }
    private var renderingLeases: [ObjectIdentifier: RenderingLease] = [:]
    private let script: String?
    private static let captureLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "EmbeddedBrowserCapture")
    #if DEBUG
    private(set) var captureDiagnosticsForTesting: BrowserCaptureDiagnostics?
    #endif

    init(session: EmbeddedBrowserSession, script: String? = nil) {
        self.session = session
        self.script = script ?? Self.loadScript()
    }

    func humanTargets() async throws -> [BrowserTarget] {
        session.humanTabs.compactMap { target(for: $0.id) }
    }

    func acquireRendering(target: BrowserTarget, lifetime: BrowserTabLifetime) async throws {
        try Task.checkCancellation()
        try lifetime.check()
        let id = try exactID(target), key = ObjectIdentifier(lifetime)
        if let existing = renderingLeases[key] {
            guard existing.target.targetID == target.targetID,
                  existing.target.instanceToken == target.instanceToken else {
                throw BrowserTabBrokerError.targetReplaced
            }
            try session.requireToolRendering(tabID: id)
            return
        }
        let token = try session.acquireToolRendering(tabID: id)
        // Revocation is synchronous and can race the actor hop. No cancelled
        // binding may retain its host, even if acquisition just completed.
        do { try lifetime.check(); try Task.checkCancellation() }
        catch { session.releaseToolRendering(tabID: id, lease: token); throw error }
        renderingLeases[key] = RenderingLease(target: target, lifetime: lifetime, token: token)
    }

    func releaseRendering(target: BrowserTarget, lifetime: BrowserTabLifetime) async {
        let key = ObjectIdentifier(lifetime)
        guard let lease = renderingLeases[key], lease.target.targetID == target.targetID,
              lease.target.instanceToken == target.instanceToken,
              let id = UUID(uuidString: target.targetID) else { return }
        renderingLeases.removeValue(forKey: key)
        session.releaseToolRendering(tabID: id, lease: lease.token)
    }

    func createTarget(url: URL) async throws -> BrowserTarget {
        try EmbeddedBrowserURLPolicy.validate(url)
        try Task.checkCancellation()
        let id = try session.createToolTab(url: url)
        let token = id.uuidString
        owned[id] = token
        do {
            try await session.waitForHumanTabReady(id: id, until: .now + .seconds(12))
            try Task.checkCancellation()
            guard let target = target(for: id) else { throw BrowserTabBrokerError.targetClosed }
            return target
        } catch {
            session.closeTab(id)
            owned.removeValue(forKey: id)
            throw error
        }
    }

    func target(id: String) async throws -> BrowserTarget? {
        guard let id = UUID(uuidString: id) else { throw BrowserTabBrokerError.handleMissing }
        return target(for: id)
    }

    private func target(for id: UUID) -> BrowserTarget? {
        guard let tab = session.humanTab(id: id) else { return nil }
        return BrowserTarget(
            targetID: id.uuidString, instanceToken: id.uuidString, title: tab.title,
            url: tab.url ?? URL(string: "about:blank")!)
    }

    // General browser tools never activate/select a tab implicitly.
    func activateTarget(id: String) async throws {
        guard try await target(id: id) != nil else { throw BrowserTabBrokerError.targetClosed }
    }

    func closeTarget(target: BrowserTarget) async throws {
        guard let id = UUID(uuidString: target.targetID) else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard owned[id] == target.instanceToken else { throw BrowserTabBrokerError.ownershipMismatch }
        // Native closure of this never-reused UUID is already a confirmed
        // disposal. Never replace it or close a matching URL/title instead.
        if let current = self.target(for: id) {
            guard current.instanceToken == target.instanceToken else {
                throw BrowserTabBrokerError.targetReplaced
            }
            session.closeTab(id)
        }
        owned.removeValue(forKey: id)
    }

    func closeOwnedTargets() async -> [String] {
        for lease in renderingLeases.values {
            if let id = UUID(uuidString: lease.target.targetID) { session.releaseToolRendering(tabID: id, lease: lease.token) }
        }
        renderingLeases.removeAll()
        for (id, token) in owned where target(for: id)?.instanceToken == token { session.closeTab(id) }
        owned.removeAll()
        return []
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        try await observe(target: target, readiness: nil)
    }

    func observeForRead(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        try await observeForRead(target: target, readiness: .semanticContent)
    }

    func observeForRead(target: BrowserTarget, readiness: BrowserReadReadiness) async throws -> BrowserDocumentObservation {
        try await observe(target: target, readiness: readiness)
    }

    func observeForRead(target: BrowserTarget, readiness: BrowserReadReadiness,
                        authorization: @escaping BrowserReadAuthorization) async throws -> BrowserDocumentObservation {
        try await observe(target: target, readiness: readiness, authorization: authorization)
    }

    private func observe(target: BrowserTarget, readiness requestedReadiness: BrowserReadReadiness?,
                         authorization: BrowserReadAuthorization? = nil) async throws -> BrowserDocumentObservation {
        let id = try exactID(target)
        try session.markHumanDocumentUsedByTool(tabID: id, generation: generation(for: id))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(12))
        try Task.checkCancellation()
        _ = try exactID(target)
        guard let readyTarget = self.target(for: id) else { throw BrowserTabBrokerError.targetClosed }
        let generation = try generation(for: id)
        try authorization?(readyTarget)
        _ = try exactID(target)
        guard self.target(for: id)?.url == readyTarget.url,
              try self.generation(for: id) == generation else { throw BrowserTabBrokerError.staleDocument }
        try session.markHumanDocumentUsedByTool(tabID: id, generation: generation)
        let data = try await run(
            id: id, generation: generation,
            input: ["operation": "observe", "awaitSemanticReadiness": requestedReadiness != nil,
                    "readinessView": requestedReadiness?.rawValue ?? "immediate", "timeoutMS": 10_000],
            timeoutMS: 12_000,
            readAdmission: authorization.map { authorize in {
                try Task.checkCancellation()
                _ = try self.exactID(target)
                guard let current = self.target(for: id), current.url == readyTarget.url,
                      try self.generation(for: id) == generation else { throw BrowserTabBrokerError.staleDocument }
                try authorize(current)
                _ = try self.exactID(target)
                guard self.target(for: id)?.url == readyTarget.url,
                      try self.generation(for: id) == generation else { throw BrowserTabBrokerError.staleDocument }
            } })
        guard data.count <= 1_000_000,
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            raw["loaderID"] as? String == generation.uuidString,
            let urlString = raw["url"] as? String, let url = URL(string: urlString),
            let title = raw["title"] as? String, let rows = raw["nodes"] as? [[String: Any]],
            rows.count <= 3_000,
            let truncated = raw["sourceTruncated"] as? Bool
        else {
            throw BrowserTabBrokerError.browserUnavailable(
                "The built-in page returned an invalid bounded observation.")
        }
        let readiness: BrowserDocumentObservation.SemanticReadiness?
        if requestedReadiness != nil {
            guard let value = raw["semanticReadiness"] as? String,
                  let parsed = BrowserDocumentObservation.SemanticReadiness(rawValue: value) else {
                throw BrowserTabBrokerError.browserUnavailable("The built-in page returned invalid semantic readiness.")
            }
            readiness = parsed
        } else {
            guard raw["semanticReadiness"] == nil else {
                throw BrowserTabBrokerError.browserUnavailable("An immediate observation cannot claim semantic readiness.")
            }
            readiness = nil
        }
        try EmbeddedBrowserURLPolicy.validate(url)
        let nodes = try rows.map { row -> BrowserDocumentNode in
            guard let number = row["backendNodeID"] as? NSNumber, number.int64Value > 0,
                let role = row["role"] as? String, role.utf8.count <= 100,
                let name = row["name"] as? String, name.count <= 4_096,
                let disabled = row["isDisabled"] as? Bool, let readOnly = row["isReadOnly"] as? Bool,
                let ignored = row["isIgnored"] as? Bool, let editable = row["isEditable"] as? Bool,
                let clickable = row["isDOMClickable"] as? Bool,
                let pressUnsupported = row["isPressUnsupported"] as? Bool,
                let pointer = row["isFocusablePointer"] as? Bool,
                let nodeID = row["nodeID"] as? String, let children = row["childNodeIDs"] as? [String]
            else {
                throw BrowserTabBrokerError.browserUnavailable(
                    "The built-in page returned invalid element metadata.")
            }
            let explicitlyNamed: Bool
            if let rawFlag = row["isExplicitlyNamedContainer"] {
                guard let flag = rawFlag as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                    throw BrowserTabBrokerError.browserUnavailable("The built-in page returned invalid container naming metadata.")
                }
                explicitlyNamed = flag.boolValue
            } else { explicitlyNamed = false }
            return BrowserDocumentNode(
                backendNodeID: number.int64Value, role: role, name: name,
                value: row["value"] as? String, isDisabled: disabled, isReadOnly: readOnly,
                isIgnored: ignored,
                nodeID: nodeID, parentNodeID: row["parentNodeID"] as? String, childNodeIDs: children,
                linkURL: row["linkURL"] as? String, isDOMClickable: clickable, isFocusablePointer: pointer,
                isEditable: editable, isPressUnsupported: pressUnsupported,
                constraintValidation: try BrowserConstraintValidation.decode(row["constraintValidation"]),
                isExplicitlyNamedContainer: explicitlyNamed)
        }
        var result = BrowserDocumentObservation(
            loaderID: generation.uuidString, title: title, url: url, nodes: nodes,
            sourceTruncated: truncated)
        result.sourceName = "computa_webkit_dom"
        result.semanticReadiness = readiness
        result.committedDocumentID = session.committedHumanDocumentID(for: id, generation: generation)
        let diagnostics = try BrowserCaptureDiagnostics.decode(raw["captureDiagnostics"], emitted: nodes.count,
                                                              sourceTruncated: truncated)
        #if DEBUG
        captureDiagnosticsForTesting = diagnostics
        #endif
        // Emit only the final returned capture, not each MutationObserver probe.
        // These opaque IDs are host-generated and permit exact-tab correlation.
        let view = session.webView(for: id)
        func dimension(_ value: CGFloat?) -> Int {
            guard let value, value.isFinite, (0...1_000_000).contains(value) else { return 0 }
            return Int(value.rounded(.down))
        }
        let record = BrowserCaptureLogRecord(tabID: id, generation: generation,
            requestedReadiness: requestedReadiness?.rawValue ?? "immediate",
            readiness: readiness?.rawValue ?? "immediate", capture: diagnostics,
            viewAttached: view?.superview != nil, viewHasWindow: view?.window != nil,
            viewHidden: view?.isHiddenOrHasHiddenAncestor ?? true,
            viewWidth: dimension(view?.bounds.width), viewHeight: dimension(view?.bounds.height))
        if let bytes = try? JSONEncoder().encode(record), bytes.count <= 1_024 {
            let text = String(decoding: bytes, as: UTF8.self)
            Self.captureLog.notice("capture \(text, privacy: .public)")
        }
        return result
    }

    func press(
        target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        _ = try await mutate(
            target: target, nodeID: backendNodeID, document: document, operation: "press", text: nil,
            permit: permit)
    }

    func pressWithFeedback(
        target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws -> BrowserInputFeedback? {
        try await mutate(target: target, nodeID: backendNodeID, document: document, operation: "press", text: nil,
                         permit: permit)
    }

    func setText(
        target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        _ = try await mutate(
            target: target, nodeID: backendNodeID, document: document, operation: "fill", text: text,
            permit: permit)
    }

    private func mutate(
        target: BrowserTarget, nodeID: Int64, document: BrowserDocumentObservation,
        operation: String, text: String?, permit: BrowserMutationPermit
    ) async throws -> BrowserInputFeedback? {
        let id = try exactID(target)
        let generation = try generation(for: id)
        guard document.loaderID == generation.uuidString, session.humanTab(id: id)?.url == document.url,
            let node = document.nodes.first(where: { $0.backendNodeID == nodeID }),
            document.verificationPlan == nil
        else {
            throw BrowserTabBrokerError.staleDocument
        }
        let expected: [String: Any] = [
            "role": node.role, "name": node.name, "value": node.value as Any? ?? NSNull(),
            "linkURL": node.linkURL as Any? ?? NSNull(), "isDisabled": node.isDisabled,
            "isReadOnly": node.isReadOnly,
            "isEditable": node.isEditable, "isDOMClickable": node.isDOMClickable,
            "isPressUnsupported": node.isPressUnsupported,
            "parentNodeID": node.parentNodeID as Any? ?? NSNull(),
        ]
        var input: [String: Any] = [
            "operation": operation, "nodeID": nodeID, "expected": expected,
            "expectedURL": document.url.absoluteString,
        ]
        if let text { input["text"] = text }
        let result = try await run(
            id: id, generation: generation, input: input, timeoutMS: 5_000, permit: permit, mutation: true
        )
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
            object["dispatched"] as? Bool == true
        else {
            throw BrowserTabBrokerError.mutationRejected(
                "The built-in action was not dispatched; no replay is allowed.")
        }
        return operation == "press" ? BrowserInputFeedback.decode(object["constraintFeedback"], document: document) : nil
    }

    func navigate(target: BrowserTarget, url: URL, permit: BrowserMutationPermit) async throws {
        let id = try exactID(target)
        try EmbeddedBrowserURLPolicy.validate(url)
        try permit.commit {
            try session.requireToolRendering(tabID: id)
            try session.navigate(tabID: id, to: url)
        }
        // A failed navigation is not resubmitted, even when its response times out.
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(12))
    }

    func wait(target: BrowserTarget, text: String?, timeoutMS: Int) async throws -> Bool {
        let id = try exactID(target)
        let deadline = ContinuousClock.now + .milliseconds(timeoutMS)
        do { try await session.waitForHumanTabReady(id: id, until: deadline) } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if ContinuousClock.now >= deadline { return false }
            throw error
        }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let remainingMS =
            Int(remaining.seconds) * 1_000 + Int(remaining.attoseconds / 1_000_000_000_000_000)
        guard remainingMS > 0 else { return false }
        let result: Data
        do {
            result = try await run(
                id: id, generation: generation(for: id),
                input: ["operation": "wait", "text": text ?? "", "timeoutMS": remainingMS],
                timeoutMS: remainingMS, deadline: deadline)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if ContinuousClock.now >= deadline { return false }
            throw error
        }
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Bool],
            let matched = object["matched"]
        else {
            throw BrowserTabBrokerError.browserUnavailable(
                "The built-in wait returned an invalid result.")
        }
        return matched
    }

    func waitForDocumentChange(target: BrowserTarget, checkpoint: BrowserDocumentChangeCheckpoint,
                               timeoutMS: Int, authorization: @escaping BrowserReadAuthorization) async throws
        -> BrowserDocumentChangeResult {
        try Task.checkCancellation()
        guard (1...10_000).contains(timeoutMS), checkpoint.targetID == target.targetID,
              checkpoint.targetInstanceToken == target.instanceToken,
              ContinuousClock.now < checkpoint.expiresAt else { throw BrowserTabBrokerError.staleSnapshot }
        let id = try exactID(target)
        let deadline = min(ContinuousClock.now + .milliseconds(timeoutMS), checkpoint.expiresAt)
        return try await session.waitForHumanTabDocumentChange(id: id, loaderID: checkpoint.loaderID,
            url: checkpoint.documentURL, until: deadline) { [self] in
                _ = try exactID(target)
                guard let current = self.target(for: id) else { throw BrowserTabBrokerError.targetClosed }
                try authorization(current)
            }
    }

    private func exactID(_ target: BrowserTarget) throws -> UUID {
        guard let id = UUID(uuidString: target.targetID), let current = self.target(for: id) else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard current.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        return id
    }

    private func generation(for id: UUID) throws -> UUID {
        guard session.humanTab(id: id) != nil, let generation = session.documentGeneration(for: id)
        else { throw BrowserTabBrokerError.targetClosed }
        return generation
    }

    private func requireCurrentReadDocument(id: UUID, view: WKWebView, generation: UUID) throws {
        guard let current = session.webView(for: id) else { throw BrowserTabBrokerError.targetClosed }
        guard current === view else { throw BrowserTabBrokerError.targetReplaced }
        guard try self.generation(for: id) == generation else { throw BrowserTabBrokerError.staleDocument }
    }

    private func run(
        id: UUID, generation: UUID, input: [String: Any], timeoutMS: Int,
        deadline: ContinuousClock.Instant? = nil,
        permit: BrowserMutationPermit? = nil, mutation: Bool = false,
        readAdmission: (() throws -> Void)? = nil
    ) async throws -> Data {
        guard let source = script, let view = session.webView(for: id), session.humanTab(id: id) != nil,
            try self.generation(for: id) == generation
        else { throw BrowserTabBrokerError.staleDocument }
        var input = input
        input["documentToken"] = generation.uuidString
        let result = EmbeddedBrowserScriptResult()
        let bytes: Data
        do {
            bytes = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    // A wait's millisecond script budget is rounded down. Its host
                    // timer must use the original deadline so it cannot expire first
                    // and turn a normal unmatched wait into a browser failure.
                    result.install(continuation, until: deadline ?? .now + .milliseconds(timeoutMS), mutation: mutation)
                    let enqueue = {
                        try readAdmission?()
                        try self.session.requireToolRendering(tabID: id)
                        let operationID: UUID?
                        if mutation {
                            operationID = try self.session.prepareToolMutation(tabID: id, generation: generation)
                        } else {
                            operationID = nil
                        }
                        view.callAsyncJavaScript(source, arguments: ["input": input], in: nil, in: self.world) {
                            reply in
                            do {
                                let value = try reply.get()
                                guard JSONSerialization.isValidJSONObject(value) else {
                                    throw BrowserTabBrokerError.browserUnavailable(
                                        "The built-in script returned an invalid result.")
                                }
                                if let operationID, self.session.toolPopupWasRejected(tabID: id, operationID: operationID) {
                                    result.finish(.failure(BrowserTabBrokerError.mutationRejected(
                                        "Browser input was dispatched, but a pop-up was blocked. No replay is allowed. Open the observed destination with browser tools; human pop-ups on this document require a fresh navigation.")))
                                    return
                                }
                                result.finish(.success(try JSONSerialization.data(withJSONObject: value)))
                            } catch {
                                // An empty-shell wait can span a real navigation,
                                // which destroys its JS context before returning.
                                // Only read-only operations may use the existing
                                // fresh-read retry; mutation dispatch is never replayed.
                                if !mutation {
                                    do {
                                        try self.requireCurrentReadDocument(id: id, view: view, generation: generation)
                                    } catch {
                                        result.finish(.failure(error))
                                        return
                                    }
                                }
                                result.finish(
                                    .failure(
                                        BrowserTabBrokerError.browserUnavailable(
                                            mutation
                                                ? "The built-in action could not be confirmed. No replay is allowed; read the page before deciding what to do next."
                                                : "The built-in page could not be inspected. Its document may have changed."
                                        ))
                                )
                            }
                        }
                    }
                    do { if let permit { try permit.commit(enqueue) } else { try enqueue() } } catch {
                        result.finish(.failure(error))
                    }
                }
            } onCancel: {
                result.finish(.failure(CancellationError()))
            }
        } catch {
            if !mutation {
                try Task.checkCancellation()
                // A redirect can retire the JS context without delivering its
                // callback. Apply the same exact fence to native timer errors;
                // an unchanged document preserves the original timeout/error.
                try requireCurrentReadDocument(id: id, view: view, generation: generation)
            }
            throw error
        }
        // Read results cannot publish stale content after a navigation or close.
        // A dispatched mutation may itself navigate; report dispatch only and
        // require a new read instead of misclassifying it as undispatched input.
        if !mutation {
            try Task.checkCancellation()
            try requireCurrentReadDocument(id: id, view: view, generation: generation)
            try session.requireToolRendering(tabID: id)
        }
        return bytes
    }

    private static func loadScript() -> String? {
        #if SWIFT_PACKAGE
            let bundles = [Bundle.module, Bundle.main]
        #else
            let bundles = [Bundle.main]
        #endif
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "browser-control", withExtension: "js", subdirectory: "BrowserModels"),
                let source = try? String(contentsOf: url, encoding: .utf8)
            {
                return source
            }
        }
        return nil
    }
}

/// Late WebKit callbacks cannot resume canceled or timed-out operations twice.
private final class EmbeddedBrowserScriptResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var completed: Result<Data, Error>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Data, Error>, until deadline: ContinuousClock.Instant, mutation: Bool) {
        lock.lock()
        if let completed {
            lock.unlock()
            continuation.resume(with: completed)
            return
        }
        self.continuation = continuation
        timer = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                finish(
                    .failure(
                        BrowserTabBrokerError.browserUnavailable(
                            mutation
                                ? "The built-in action timed out. No replay is allowed; inspect the page before any further action."
                                : "The built-in page observation timed out.")))
            } catch {}
        }
        lock.unlock()
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard completed == nil else {
            lock.unlock()
            return
        }
        completed = result
        let continuation = self.continuation
        let timer = self.timer
        self.continuation = nil
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

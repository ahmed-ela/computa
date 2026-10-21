import Foundation
import WebKit

/// Runtime integration depends on this narrow backend, rather than WebKit or
/// native window focus. Fixtures can implement it without launching a browser.
protocol EmbeddedBrowserControlBackend: BrowserTabTransport {
    func humanTargets() async throws -> [BrowserTarget]
    func navigate(target: BrowserTarget, url: URL, permit: BrowserMutationPermit) async throws
    func wait(target: BrowserTarget, text: String?, timeoutMS: Int) async throws -> Bool
    func closeOwnedTargets() async -> [String]
}

/// Uses only Computa's human WebViews. Inference pages and the privileged app UI
/// are absent from this inventory, even when their titles or URLs match.
@MainActor
final class EmbeddedBrowserTabTransport: EmbeddedBrowserControlBackend {
    private let session: EmbeddedBrowserSession
    private let world = WKContentWorld.world(name: "Computa.BrowserControl.\(UUID().uuidString)")
    private var owned = [UUID: String]()
    private let script: String?

    init(session: EmbeddedBrowserSession, script: String? = nil) {
        self.session = session
        self.script = script ?? Self.loadScript()
    }

    func humanTargets() async throws -> [BrowserTarget] {
        session.humanTabs.compactMap { target(for: $0.id) }
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
            url: tab.url ?? URL(string: "about:blank")!, webSocketURL: nil)
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
        for (id, token) in owned where target(for: id)?.instanceToken == token { session.closeTab(id) }
        owned.removeAll()
        return []
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        let id = try exactID(target)
        try session.markHumanDocumentUsedByTool(tabID: id, generation: generation(for: id))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(12))
        let generation = try generation(for: id)
        try session.markHumanDocumentUsedByTool(tabID: id, generation: generation)
        let data = try await run(
            id: id, generation: generation, input: ["operation": "observe", "timeoutMS": 10_000], timeoutMS: 12_000)
        guard data.count <= 1_000_000,
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            raw["loaderID"] as? String == generation.uuidString,
            let urlString = raw["url"] as? String, let url = URL(string: urlString),
            let title = raw["title"] as? String, let rows = raw["nodes"] as? [[String: Any]],
            rows.count <= 3_000,
            let truncated = raw["sourceTruncated"] as? Bool,
            let readinessValue = raw["semanticReadiness"] as? String,
            let readiness = BrowserDocumentObservation.SemanticReadiness(rawValue: readinessValue)
        else {
            throw BrowserTabBrokerError.browserUnavailable(
                "The built-in page returned an invalid bounded observation.")
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
            return BrowserDocumentNode(
                backendNodeID: number.int64Value, role: role, name: name,
                value: row["value"] as? String, isDisabled: disabled, isReadOnly: readOnly,
                isIgnored: ignored,
                nodeID: nodeID, parentNodeID: row["parentNodeID"] as? String, childNodeIDs: children,
                linkURL: row["linkURL"] as? String, isDOMClickable: clickable, isFocusablePointer: pointer,
                isEditable: editable, isPressUnsupported: pressUnsupported)
        }
        var result = BrowserDocumentObservation(
            loaderID: generation.uuidString, title: title, url: url, nodes: nodes,
            sourceTruncated: truncated)
        result.sourceName = "computa_webkit_dom"
        result.semanticReadiness = readiness
        return result
    }

    func press(
        target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        try await mutate(
            target: target, nodeID: backendNodeID, document: document, operation: "press", text: nil,
            permit: permit)
    }

    func setText(
        target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        try await mutate(
            target: target, nodeID: backendNodeID, document: document, operation: "fill", text: text,
            permit: permit)
    }

    private func mutate(
        target: BrowserTarget, nodeID: Int64, document: BrowserDocumentObservation,
        operation: String, text: String?, permit: BrowserMutationPermit
    ) async throws {
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
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Bool],
            object["dispatched"] == true
        else {
            throw BrowserTabBrokerError.mutationRejected(
                "The built-in action was not dispatched; no replay is allowed.")
        }
    }

    func navigate(target: BrowserTarget, url: URL, permit: BrowserMutationPermit) async throws {
        let id = try exactID(target)
        try EmbeddedBrowserURLPolicy.validate(url)
        try permit.commit { try session.navigate(tabID: id, to: url) }
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

    private func run(
        id: UUID, generation: UUID, input: [String: Any], timeoutMS: Int,
        deadline: ContinuousClock.Instant? = nil,
        permit: BrowserMutationPermit? = nil, mutation: Bool = false
    ) async throws -> Data {
        guard let source = script, let view = session.webView(for: id), session.humanTab(id: id) != nil,
            try self.generation(for: id) == generation
        else { throw BrowserTabBrokerError.staleDocument }
        var input = input
        input["documentToken"] = generation.uuidString
        let result = EmbeddedBrowserScriptResult()
        let bytes: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // A wait's millisecond script budget is rounded down. Its host
                // timer must use the original deadline so it cannot expire first
                // and turn a normal unmatched wait into a browser failure.
                result.install(continuation, until: deadline ?? .now + .milliseconds(timeoutMS), mutation: mutation)
                let enqueue = {
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
                                    guard let currentView = self.session.webView(for: id) else {
                                        throw BrowserTabBrokerError.targetClosed
                                    }
                                    guard currentView === view else {
                                        throw BrowserTabBrokerError.targetReplaced
                                    }
                                    if try self.generation(for: id) != generation {
                                        throw BrowserTabBrokerError.staleDocument
                                    }
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
        // Read results cannot publish stale content after a navigation or close.
        // A dispatched mutation may itself navigate; report dispatch only and
        // require a new read instead of misclassifying it as undispatched input.
        if !mutation, try self.generation(for: id) != generation {
            throw BrowserTabBrokerError.staleDocument
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

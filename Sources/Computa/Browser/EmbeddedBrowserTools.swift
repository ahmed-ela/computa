import AutomationCore
import CoreFoundation
import Foundation

/// Strict model-facing contract for Computa's own browser, independent of
/// Chrome attachment and native computer/window input.
enum EmbeddedBrowserTools {
    static let names: Set<String> = [
        "browser_tabs", "browser_open", "browser_bind", "browser_navigate", "browser_read",
        "browser_click", "browser_fill", "browser_wait", "browser_close",
    ]
    static func requiresApproval(tool: String) -> Bool {
        ["browser_open", "browser_navigate", "browser_click", "browser_fill", "browser_close"].contains(
            tool)
    }

    static func definitions() -> [[String: Any]] {
        func specification(
            _ name: String, _ description: String, _ properties: [String: Any] = [:],
            _ required: [String] = []
        ) -> [String: Any] {
            [
                "type": "function", "name": name, "description": description,
                "inputSchema": [
                    "type": "object", "properties": properties, "required": required,
                    "additionalProperties": false,
                ],
            ]
        }
        let string: [String: Any] = ["type": "string"]
        let mutation: [String: Any] = [
            "snapshot_id": string, "element_index": ["type": "integer", "minimum": 0],
        ]
        return [
            specification(
                "browser_tabs",
                "List human tabs in Computa's built-in browser, including current logins, within an 8KB page. Continue next_cursor with cursor. Inference and app-control pages are excluded. Use an observed tab_id to bind; busy tabs belong to another task.",
                ["cursor": string]),
            specification(
                "browser_open",
                "Create and bind one background task-owned tab in Computa's built-in browser, sharing its signed-in profile. Only this created tab is cleaned up at turn end.",
                ["url": string], ["url"]),
            specification(
                "browser_bind",
                "Bind the exact observed available human built-in tab without activating or navigating it. Existing user tabs are preserved at cleanup.",
                ["tab_id": string], ["tab_id"]),
            specification(
                "browser_navigate",
                "Navigate the currently bound built-in tab once. A timeout never replays navigation. Read its new document before acting.",
                ["url": string], ["url"]),
            specification(
                "browser_read",
                "Read compact visible DOM semantics for the bound built-in tab. Use overview for controls/headings, content for document text, all for structure; continue next_cursor with cursor. Use browser_click for observed enabled links (including follow_link=true) and controls, browser_fill for fields. Snapshot IDs and indices authorize one subsequent action only; act on observed navigation without repeating unchanged reads.",
                [
                    "view": ["type": "string", "enum": ["overview", "content", "all", "headings", "links"]],
                    "query": string, "cursor": string,
                ]),
            specification(
                "browser_click",
                "Press exactly one enabled observed control/link using the latest snapshot_id and element_index. Semantic DOM activation, with stale-node and obstruction checks; not native global input. Reports dispatch, not success. Read or wait to verify the result. Never retry a timed-out mutation.",
                mutation, ["snapshot_id", "element_index"]),
            specification(
                "browser_fill",
                "Replace one observed editable field and dispatch input/change events. Uses one fresh snapshot capability; password fields are unavailable. Read to verify the value before a later submit.",
                mutation.merging(["text": string], uniquingKeysWith: { _, right in right }),
                ["snapshot_id", "element_index", "text"]),
            specification(
                "browser_wait",
                "Wait by DOM mutation events until visible semantic text contains text, or until the document is ready when text is omitted. Bounded, read-only; matched=false at deadline. Does not refresh or replay actions.",
                ["text": string, "timeout_ms": ["type": "integer", "minimum": 1, "maximum": 10_000]]),
            specification(
                "browser_close",
                "Release the bound built-in tab. Closes only this task's created tab; a bound existing user tab stays open."
            ),
        ]
    }

    static func validate(tool: String, arguments: [String: Any]) throws {
        guard names.contains(tool) else {
            throw BrowserTabBrokerError.invalidRead("Unknown built-in browser tool.")
        }
        let required: Set<String>
        let allowed: Set<String>
        switch tool {
        case "browser_tabs":
            required = []
            allowed = ["cursor"]
        case "browser_open", "browser_navigate":
            required = ["url"]
            allowed = required
        case "browser_bind":
            required = ["tab_id"]
            allowed = required
        case "browser_read":
            required = []
            allowed = ["view", "query", "cursor"]
        case "browser_click":
            required = ["snapshot_id", "element_index"]
            allowed = required
        case "browser_fill":
            required = ["snapshot_id", "element_index", "text"]
            allowed = required
        case "browser_wait":
            required = []
            allowed = ["text", "timeout_ms"]
        default:
            required = []
            allowed = []
        }
        guard required.isSubset(of: Set(arguments.keys)), Set(arguments.keys).isSubset(of: allowed)
        else {
            throw BrowserTabBrokerError.invalidRead(
                "The built-in browser tool has missing or unexpected arguments.")
        }
        for key in ["url", "tab_id", "snapshot_id", "view", "query", "cursor", "text"]
        where arguments[key] != nil {
            guard let value = arguments[key] as? String,
                value.utf8.count <= (key == "text" && tool == "browser_fill" ? 65_536 : 2_048),
                key == "text" || !value.isEmpty
            else { throw BrowserTabBrokerError.invalidRead("Invalid built-in browser string argument.") }
        }
        for key in ["tab_id", "snapshot_id"] where arguments[key] != nil {
            guard UUID(uuidString: arguments[key] as! String) != nil else {
                throw BrowserTabBrokerError.invalidRead("Use an exact observed browser identifier.")
            }
        }
        if let raw = arguments["view"] as? String, SemanticReadView(rawValue: raw) == nil {
            throw BrowserTabBrokerError.invalidRead("Unsupported browser read view.")
        }
        if let value = arguments["element_index"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite,
                number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= 0,
                number.doubleValue < 3_000
            else {
                throw BrowserTabBrokerError.invalidRead(
                    "The browser element index must be an observed nonnegative integer.")
            }
        }
        if let value = arguments["timeout_ms"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite,
                number.doubleValue.rounded() == number.doubleValue, (1...10_000).contains(number.intValue)
            else {
                throw BrowserTabBrokerError.invalidRead(
                    "The browser wait deadline must be from 1 to 10000 milliseconds.")
            }
        }
        if tool == "browser_wait", let text = arguments["text"] as? String,
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 512
        {
            throw BrowserTabBrokerError.invalidRead(
                "Browser wait text must be nonempty and within its bounded limit.")
        }
        if let string = arguments["url"] as? String {
            guard let url = URL(string: string),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else {
                throw BrowserTabBrokerError.invalidRead(
                    "Browser tool navigation requires an explicit HTTP or HTTPS URL.")
            }
            try EmbeddedBrowserURLPolicy.validate(url)
        }
    }
}

/// Each active turn receives its own taskKey from the runtime. The controller
/// retains an exact tab lease and capability; it never operates on an active tab.
actor EmbeddedBrowserToolController {
    private struct Context {
        let id = UUID()
        let lifetime = BrowserTabLifetime()
        var binding: BrowserTabBinding?
        var snapshot: BrowserTabSnapshot?
        var ownedTarget: BrowserTarget?
        var leasedTarget: BrowserTarget?
        var bindingLifetime: BrowserTabLifetime?
        var observedTargets = [String: BrowserTarget]()
        var inventory = [BrowserTarget]()
        var inventoryOffset = 0
        var inventoryCursor: String?
        var scope: ComputerTaskScope?
    }
    private let transport: any EmbeddedBrowserControlBackend
    private let broker: BrowserTabSessionBroker
    private var contexts = [String: Context]()
    private var leases = [String: String]()
    private var inFlight = Set<String>()
    private var closed = false

    init(transport: any EmbeddedBrowserControlBackend) {
        self.transport = transport
        broker = BrowserTabSessionBroker(
            transport: transport, browserGeneration: UUID(), ownership: .borrowed)
    }

    func execute(taskKey: String, tool: String, arguments: Data, scope: ComputerTaskScope? = nil)
        async throws -> String
    {
        guard !closed else { throw BrowserTabBrokerError.handleMissing }
        guard let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw BrowserTabBrokerError.invalidRead("Browser arguments must be a JSON object.")
        }
        try EmbeddedBrowserTools.validate(tool: tool, arguments: object)
        if let violation = scope?.embeddedBrowserToolViolation() {
            throw BrowserTabBrokerError.invalidRead(violation)
        }
        guard inFlight.insert(taskKey).inserted else { throw BrowserTabBrokerError.operationInProgress }
        defer { inFlight.remove(taskKey) }
        if contexts[taskKey] == nil { contexts[taskKey] = Context(scope: scope) }
        guard contexts[taskKey]?.scope == scope else {
            throw BrowserTabBrokerError.invalidRead(
                "The host browser scope changed within this turn; start a new turn.")
        }
        let contextID = contexts[taskKey]!.id
        let lifetime = contexts[taskKey]!.lifetime
        try lifetime.check()
        switch tool {
        case "browser_tabs":
            if let cursor = object["cursor"] as? String {
                guard contexts[taskKey]?.inventoryCursor == cursor else {
                    throw BrowserTabBrokerError.staleSnapshot
                }
            } else {
                let targets = try await transport.humanTargets().filter {
                    scope?.candidateViolation(url: $0.url, title: $0.title) == nil
                }
                try check(taskKey, contextID)
                contexts[taskKey]?.inventory = targets
                contexts[taskKey]?.inventoryOffset = 0
                contexts[taskKey]?.inventoryCursor = nil
                contexts[taskKey]?.observedTargets = [:]
            }
            guard var context = contexts[taskKey] else { throw BrowserTabBrokerError.handleMissing }
            var rows = [[String: Any]]()
            var bytes = 0
            while context.inventoryOffset < context.inventory.count {
                let target = context.inventory[context.inventoryOffset]
                let title = Self.inventoryTitle(target.title)
                var row: [String: Any] = [
                    "tab_id": target.targetID, "title": title.text,
                    "title_truncated": title.truncated,
                    "availability": leases[target.targetID].map { $0 == taskKey ? "bound_here" : "busy" }
                        ?? "available",
                ]
                if target.url.absoluteString.utf8.count <= 2_048 {
                    row["url"] = target.url.absoluteString
                } else {
                    row["url_omitted"] = true
                }
                let size = try JSONSerialization.data(withJSONObject: row).count + 1
                guard bytes + size <= 7_000 else { break }
                rows.append(row)
                bytes += size
                context.observedTargets[target.targetID] = target
                context.inventoryOffset += 1
            }
            let more = context.inventoryOffset < context.inventory.count
            context.inventoryCursor = more ? UUID().uuidString : nil
            contexts[taskKey] = context
            return try json([
                "browser": "computa_builtin", "tabs": rows, "count": context.inventory.count,
                "returned": rows.count, "truncated": more,
                "next_cursor": context.inventoryCursor as Any? ?? NSNull(),
                "consistency": "retained_metadata", "content_evidence": "metadata_only",
            ])
        case "browser_open", "browser_bind":
            let owned = tool == "browser_open"
            if owned { try requireScope(scope, url: URL(string: object["url"] as! String)!) }
            var selected: BrowserTarget?
            if !owned {
                let id = object["tab_id"] as! String
                guard let observed = contexts[taskKey]?.observedTargets[id] else {
                    throw BrowserTabBrokerError.invalidRead(
                        "List browser_tabs in this turn before binding an observed tab_id.")
                }
                guard leases[id] == nil || leases[id] == taskKey else {
                    throw BrowserTabBrokerError.operationInProgress
                }
                guard let current = try await transport.target(id: id),
                    current.instanceToken == observed.instanceToken
                else {
                    throw BrowserTabBrokerError.targetClosed
                }
                try requireScope(scope, url: current.url, title: current.title)
                try check(taskKey, contextID)
                selected = current
                if let binding = contexts[taskKey]?.binding, binding.targetID == current.targetID,
                    binding.targetInstanceToken == current.instanceToken, leases[current.targetID] == taskKey
                {
                    try binding.lifetime.check()
                    return try bindingResponse(
                        target: current, binding: binding,
                        owned: contexts[taskKey]?.ownedTarget != nil, alreadyBound: true)
                }
            }
            let cleanup = await unbind(taskKey: taskKey)
            guard cleanup.isEmpty else {
                throw BrowserTabBrokerError.browserUnavailable(
                    "Previous task-tab cleanup could not be confirmed.")
            }
            try check(taskKey, contextID)
            let target: BrowserTarget
            if owned {
                let url = URL(string: object["url"] as! String)!
                try requireScope(scope, url: url)
                target = try await transport.createTarget(url: url)
            } else {
                guard let selected else { throw BrowserTabBrokerError.targetClosed }
                target = selected
            }
            do {
                try check(taskKey, contextID)
                try requireScope(scope, url: target.url, title: target.title)
                guard leases[target.targetID] == nil || leases[target.targetID] == taskKey else {
                    throw BrowserTabBrokerError.operationInProgress
                }
                leases[target.targetID] = taskKey
                contexts[taskKey]?.leasedTarget = target
                if owned { contexts[taskKey]?.ownedTarget = target }
                let bindingLifetime = BrowserTabLifetime()
                contexts[taskKey]?.bindingLifetime = bindingLifetime
                let binding = try await broker.bindBorrowed(
                    taskKey: taskKey, processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier),
                    target: target, lifetime: bindingLifetime)
                try check(taskKey, contextID)
                contexts[taskKey]?.binding = binding
                return try bindingResponse(target: target, binding: binding, owned: owned)
            } catch {
                if leases[target.targetID] == taskKey { leases.removeValue(forKey: target.targetID) }
                if owned { try? await transport.closeTarget(target: target) }
                throw error
            }
        case "browser_read":
            let binding = try bound(taskKey, contextID)
            _ = try await currentTarget(binding: binding, scope: scope)
            try check(taskKey, contextID)
            let view = (object["view"] as? String).flatMap(SemanticReadView.init(rawValue:))
            let read = SemanticReadRequest(
                query: object["query"] as? String,
                view: view ?? (object["cursor"] == nil ? .overview : nil),
                cursor: object["cursor"] as? String)
            let observation = try await broker.snapshot(
                taskKey: taskKey, binding: binding, bundleIdentifier: "com.ahmedelamin.computa", read: read)
            try check(taskKey, contextID)
            try requireScope(scope, url: observation.snapshot.documentURL)
            contexts[taskKey]?.binding = observation.binding
            contexts[taskKey]?.snapshot = observation.snapshot
            return observation.snapshot.formattedText
        case "browser_click", "browser_fill":
            let binding = try bound(taskKey, contextID)
            _ = try await currentTarget(binding: binding, scope: scope)
            try check(taskKey, contextID)
            guard let snapshot = contexts[taskKey]?.snapshot,
                snapshot.id == UUID(uuidString: object["snapshot_id"] as! String)
            else { throw BrowserTabBrokerError.staleSnapshot }
            let index = (object["element_index"] as! NSNumber).intValue
            try requireScope(scope, url: snapshot.documentURL)
            if tool == "browser_click", let link = snapshot.element(at: index)?.linkURL, !link.isEmpty {
                guard let destination = URL(string: link, relativeTo: snapshot.documentURL)?.absoluteURL
                else {
                    throw BrowserTabBrokerError.invalidRead(
                        "The observed browser link has an invalid destination.")
                }
                try EmbeddedBrowserURLPolicy.validate(destination)
                try requireScope(scope, url: destination)
            }
            contexts[taskKey]?.snapshot = nil
            if tool == "browser_click" {
                try await broker.perform(
                    taskKey: taskKey, binding: binding, snapshot: snapshot, elementIndex: index,
                    action: "AXPress")
            } else {
                try await broker.setText(
                    taskKey: taskKey, binding: binding, snapshot: snapshot, elementIndex: index,
                    text: object["text"] as! String)
            }
            try check(taskKey, contextID)
            return try json([
                "dispatched": true, "no_replay": true, "result_verified": false,
                "next": "Read or wait for the resulting page before reporting success.",
            ])
        case "browser_navigate":
            let binding = try bound(taskKey, contextID)
            let destination = URL(string: object["url"] as! String)!
            try requireScope(scope, url: destination)
            contexts[taskKey]?.snapshot = nil
            let target = try await currentTarget(binding: binding, scope: scope)
            try check(taskKey, contextID)
            try await transport.navigate(
                target: target, url: destination, permit: BrowserMutationPermit(lifetime: binding.lifetime))
            try check(taskKey, contextID)
            return try json([
                "navigation_complete": true, "no_replay": true,
                "next": "Read the current document before acting.",
            ])
        case "browser_wait":
            let binding = try bound(taskKey, contextID)
            let target = try await currentTarget(binding: binding, scope: scope)
            try check(taskKey, contextID)
            let matched = try await transport.wait(
                target: target, text: object["text"] as? String,
                timeoutMS: (object["timeout_ms"] as? NSNumber)?.intValue ?? 5_000)
            try check(taskKey, contextID)
            _ = try await currentTarget(binding: binding, scope: scope)
            try check(taskKey, contextID)
            return try json([
                "matched": matched, "event_driven": true,
                "next":
                    "Read the current page for evidence; wait results do not expose new action references.",
            ])
        case "browser_close":
            _ = try bound(taskKey, contextID)
            let cleanup = await unbind(taskKey: taskKey)
            guard cleanup.isEmpty else {
                throw BrowserTabBrokerError.browserUnavailable("Task-tab cleanup could not be confirmed.")
            }
            try check(taskKey, contextID)
            return try json(["released": true, "existing_user_tab_preserved": true])
        default: throw BrowserTabBrokerError.invalidRead("Unknown built-in browser tool.")
        }
    }

    /// Revocation precedes every cleanup await. An opening operation retains the
    /// same revoked lifetime and closes any target it receives late.
    func release(taskKey: String) async -> [String] {
        contexts[taskKey]?.lifetime.revoke()
        contexts[taskKey]?.bindingLifetime?.revoke()
        return await unbind(taskKey: taskKey, removeContext: true)
    }

    func shutdown() async -> [String] {
        closed = true
        for context in contexts.values {
            context.lifetime.revoke()
            context.bindingLifetime?.revoke()
        }
        var issues = [String]()
        for key in Array(contexts.keys) { issues += await unbind(taskKey: key, removeContext: true) }
        await broker.invalidateAll()
        issues += await transport.closeOwnedTargets()
        return issues
    }

    private func unbind(taskKey: String, removeContext: Bool = false) async -> [String] {
        guard let context = contexts[taskKey] else { return [] }
        context.bindingLifetime?.revoke()
        if removeContext {
            contexts.removeValue(forKey: taskKey)
        } else {
            contexts[taskKey]?.binding = nil
            contexts[taskKey]?.snapshot = nil
            contexts[taskKey]?.ownedTarget = nil
            contexts[taskKey]?.leasedTarget = nil
            contexts[taskKey]?.bindingLifetime = nil
        }
        if let target = context.leasedTarget, leases[target.targetID] == taskKey {
            leases.removeValue(forKey: target.targetID)
        }
        var issues = [String]()
        if let binding = context.binding {
            do { try await broker.revoke(taskKey: taskKey, binding: binding) } catch {
                issues.append("Built-in browser binding cleanup failed.")
            }
        }
        if let target = context.ownedTarget {
            do { try await transport.closeTarget(target: target) } catch {
                issues.append("Owned built-in browser tab cleanup could not be confirmed.")
            }
        }
        return issues
    }

    private func check(_ taskKey: String, _ id: UUID) throws {
        guard !closed, let context = contexts[taskKey], context.id == id else {
            throw BrowserTabBrokerError.handleMissing
        }
        try context.lifetime.check()
    }

    private func bound(_ taskKey: String, _ id: UUID) throws -> BrowserTabBinding {
        try check(taskKey, id)
        guard let binding = contexts[taskKey]?.binding else {
            throw BrowserTabBrokerError.handleMissing
        }
        try binding.lifetime.check()
        return binding
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// A single Character can contain arbitrarily many combining scalars.
    /// Bound UTF-8 bytes without scanning that whole grapheme. Even six-byte
    /// JSON escapes fit beside the bounded URL and metadata in one row.
    private static func inventoryTitle(_ title: String) -> (text: String, truncated: Bool) {
        var prefix = ""
        var bytes = 0
        for scalar in title.unicodeScalars {
            let size = String(scalar).utf8.count
            guard bytes + size <= 256 else { return (prefix, true) }
            prefix.unicodeScalars.append(scalar)
            bytes += size
        }
        return (prefix, false)
    }

    private func bindingResponse(
        target: BrowserTarget, binding: BrowserTabBinding, owned: Bool, alreadyBound: Bool = false
    ) throws -> String {
        try json([
            "browser": "computa_builtin", "tab_id": target.targetID,
            "tab_handle": binding.handle.uuidString,
            "ownership": owned ? "task_created" : "user_existing", "already_bound": alreadyBound,
            "profile": "shared_human", "content_evidence": "metadata_only",
            "next": "Call browser_read before using page contents or taking actions.",
        ])
    }

    private func requireScope(_ scope: ComputerTaskScope?, url: URL, title: String? = nil) throws {
        let violation: String?
        if let title {
            violation = scope?.candidateViolation(url: url, title: title)
        } else {
            violation = scope?.siteViolation(url: url)
        }
        if let violation { throw BrowserTabBrokerError.invalidRead(violation) }
    }

    private func currentTarget(binding: BrowserTabBinding, scope: ComputerTaskScope?) async throws
        -> BrowserTarget
    {
        guard let target = try await transport.target(id: binding.targetID),
            target.instanceToken == binding.targetInstanceToken
        else {
            throw BrowserTabBrokerError.targetClosed
        }
        try requireScope(scope, url: target.url)
        return target
    }
}

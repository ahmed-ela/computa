import AutomationCore
import CoreFoundation
import Foundation

/// Strict model-facing contract for Computa's own browser, independent of
/// native computer/window input.
enum EmbeddedBrowserTools {
    /// An assertion mismatch never grants a lookup, retarget, approval or input.
    /// Do not echo model arguments or unexposed retained page fields in errors.
    enum TargetAssertionFailure: Error, LocalizedError, Equatable, Sendable {
        case mismatch
        var errorDescription: String? {
            #"{"success":false,"error":{"code":"browser_target_mismatch","message":"No input was dispatched. The frozen target does not match this current row's exposed bytes."},"dispatched":false,"no_replay":true,"next":"Read the bound page if needed and copy the intended current row's click_ref or fill_ref. No target was searched for or substituted, and no earlier input was replayed."}"#
        }
    }
    enum MutationEligibilityFailure: Error, LocalizedError, Equatable {
        case disabledTarget, pressUnavailable, fillUnavailable

        var errorDescription: String? {
            switch self {
            case .disabledTarget:
                "No input was dispatched. This browser target has enabled=false. Use browser_read to observe an enabled target; do not retry this target or substitute its parent or child."
            case .pressUnavailable:
                "No input was dispatched. This browser target has no advertised AXPress action. actions=[] is read-only, even when enabled=true. Use browser_read with view=links or view=all and an observed text query, then choose an enabled row with actions=[\"AXPress\"]. Do not substitute a parent or child without observing its own reference."
            case .fillUnavailable:
                "No input was dispatched. This browser target has settable=false. Use browser_read to observe an enabled field with settable=true, then browser_fill with that field's own fill_ref. Clicking a label or parent does not grant field authority."
            }
        }
    }
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
            let schema: [String: Any] = ["type": "object", "properties": properties,
                "required": required, "additionalProperties": false]
            return ["type": "function", "name": name, "description": description, "inputSchema": schema]
        }
        let waitText: [String: Any] = ["type": "string", "minLength": 1,
            "pattern": "[^\\u0009-\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000-\\u200B\\u2028\\u2029\\u202F\\u205F\\u3000]",
            "description": "Nonblank visible text to wait for, at most 512 UTF-8 bytes. Omit text to wait for readable text or controls outside the footer after document readiness; never send an empty or whitespace-only string."]
        let cursor: [String: Any] = ["type": ["string", "null"], "minLength": 1,
            "description": "Omit this field on the first page or a fresh inventory; null has the same fresh-inventory meaning and never resumes a previous cursor. Only copy an exact nonempty next_cursor returned by browser_tabs in the current turn to continue; never send an empty string or an invented cursor. At most 2048 UTF-8 bytes."]
        let readCursor: [String: Any] = ["type": ["string", "null"], "minLength": 1,
            "description": "Omit this field on the first page or a fresh read; null starts fresh and never resumes a previous cursor. Continue with the exact nonempty next_cursor from the latest page in the current turn. Prefer cursor alone: repeated view/query must match the captured filters exactly; changing them requires a fresh read. Each successful continuation, fresh read or current_observation replaces older cursors; admitted input invalidates them. Never send an empty or invented cursor. At most 2048 UTF-8 bytes."]
        let query: [String: Any] = ["type": "string", "minLength": 1,
            "description": "Local filter of captured fields, including search-box values; not website Search or result-count evidence. At most 2048 UTF-8 bytes. Omit this field for an unfiltered read; never send an empty string."]
        let readView: [String: Any] = ["type": "string", "enum": ["overview", "content", "all", "headings", "links"]]
        let url: [String: Any] = ["type": "string", "minLength": 1, "description": "Copy a supplied or observed URL exactly, preserving punctuation. Without a supplied URL, use a user-named known service's official homepage or sign-in entrypoint, then observed controls. Never invent deep links, account paths, message IDs or address variants."]
        let clickRef: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128,
            "description": "Copy the exact click_ref on the intended current published row. Never construct it or use a fill_ref/native reference. The host resolves and validates the same observed target; the token never searches for a target."]
        let fillRef: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128,
            "description": "Copy the exact fill_ref on the intended current published field. Never construct it or use a click_ref/native reference. Admitted input consumes all current references."]
        return [
            specification(
                "browser_tabs",
                "List human tabs in Computa's built-in browser, including current logins, within an 8KB page. Omit cursor or use null for a fresh first page. Empty inventory means no matching user tabs were listed, not denied access; use browser_open for a named known service's official entrypoint. Continue with browser_tabs(cursor=next_cursor) alone; computer_v2_continue cannot consume this inventory cursor. Inference and app-control pages are excluded. Use an observed tab_id to bind; busy tabs belong to another task.",
                ["cursor": cursor]),
            specification(
                "browser_open",
                "Create and bind one background task-owned tab in Computa's built-in browser, sharing its signed-in profile. A user-provided URL is not required for a user-named known service's official homepage or sign-in entrypoint. Preserve any supplied URL exactly; use observed controls for deeper pages. Only this created tab is cleaned up at turn end.",
                ["url": url], ["url"]),
            specification(
                "browser_bind",
                "Bind the exact observed available human built-in tab without activating or navigating it. Existing user tabs are preserved at cleanup.",
                ["tab_id": ["type": "string", "minLength": 1]], ["tab_id"]),
            specification(
                "browser_navigate",
                "Navigate the currently bound built-in tab once. A timeout never replays navigation. Read its new document before acting.",
                ["url": url], ["url"]),
            specification(
                "browser_read",
                "Read the bound built-in tab. Use content for readable text and non-navigation listbox options, including messages/documents; overview for controls/headings and a bounded text sample; all for structural troubleshooting, not page progression. A fresh read restarts page one: omit cursor or use null, with optional view/query. Only browser_read(cursor=next_cursor) advances. Prefer cursor alone; any repeated view/query must match its captured filters exactly. To change filters, omit cursor. Never use computer_v2_continue. READ_SELECTION_EVIDENCE counts and query matches describe the local capture, never website search results or absence. Use browser_click for observed enabled links (including follow_link=true) and controls only when actions contains AXPress; browser_fill requires enabled=true and settable=true. actions=[] cannot be clicked; enabled settable fields can still be filled using their fill_ref. Containers do not inherit child actions. For popup-only links without AXPress, browser_navigate may use the complete exact observed href in the same tab; never reconstruct href_fragment/href_omitted. Use overview/all with observed text to find form controls; links selects links only. Only published click_ref/fill_ref values authorize input; choose the intended row without repeated unchanged reads. Same-capture cursor pages retain earlier refs within the 120-ref FIFO bound. Fresh reads retain prior refs only when the same native target is corroborated without renewing expiry; changed/absent targets expire. Input consumes all refs.",
                ["view": readView, "query": query, "cursor": readCursor]),
            specification(
                "browser_click",
                "Press exactly one observed row with enabled=true and actions=[\"AXPress\"] using its current click_ref. Choose the intended row by its observed label and action. actions=[] is not pressable: never click a content container or substitute its parent/child. Find the actual control using browser_read(view=overview or all, query=observed text). An observed existing-account selector may be used within the authorized service/task and approvals; ask for help when credentials, MFA or account ambiguity actually require it, not because they might appear later. Semantic DOM activation, with stale-node and obstruction checks; not native global input. Returns dispatch plus a fresh current_observation when available; inspect it for the result and use only its new references. If dispatched input leaves the page unchanged, wait/read instead of clicking again. After stale errors use available current_observation; otherwise browser_read. Never repeat an input because its following observation failed. Never retry a timed-out mutation.",
                ["click_ref": clickRef], ["click_ref"]),
            specification(
                "browser_fill",
                "Replace one observed field with enabled=true and settable=true and dispatch input/change events; no Enter key or submit-control click is sent. Page handlers may react to these events. Use that field's current fill_ref, never a label or parent. Uses one current observed capability; password fields are unavailable. Returns a fresh current_observation when available: compare its field value with the complete requested value before submitting. A distinct observed enabled submit/Search control remains available if needed within the task's scope and approvals. Use only new references. If unavailable, browser_read; the fill was still dispatched and must not be repeated.",
                ["fill_ref": fillRef].merging(["text": ["type": "string", "description": "Copy the complete requested field value verbatim, including prefixes, spaces and punctuation. Do not infer a shorter identifier format. Transform only when the task explicitly requires it."]], uniquingKeysWith: { _, right in right }),
                ["fill_ref", "text"]),
            specification(
                "browser_wait",
                "Wait by DOM mutation and document events until visible semantic text contains text. When text is omitted, wait for readable text or controls outside the footer after document readiness; a title-only, empty or footer-only shell is not ready. Read-only and bounded; matched=false at deadline. This readiness is not proof that requested content exists. Does not refresh or replay actions.",
                ["text": waitText, "timeout_ms": ["type": "integer", "minimum": 1, "maximum": 10_000]]),
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
            required = ["click_ref"]
            allowed = required
        case "browser_fill":
            required = ["fill_ref", "text"]
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
        for key in ["click_ref", "fill_ref"] where arguments[key] != nil {
            guard let value = arguments[key] as? String, !value.isEmpty, value.utf8.count <= 128 else {
                throw EmbeddedBrowserActionReferences.Failure.invalidReference
            }
        }
        for key in ["url", "tab_id", "snapshot_id", "view", "query", "cursor", "text"]
        where arguments[key] != nil {
            // Only these explicitly nullable optional cursors mean omission.
            // All other fields keep their strict contracts.
            if ["browser_read", "browser_tabs"].contains(tool), key == "cursor", arguments[key] is NSNull { continue }
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

/// Assertions refer only to one row in the current, already published read.
/// A retained full label is not evidence that its unexposed bytes were seen.
enum EmbeddedBrowserTargetAssertion {
    static func exposedLabel(snapshot: BrowserTabSnapshot, element: BrowserTabElement) -> String? {
        guard snapshot.element(at: element.index) == element,
              let receipt = snapshot.readReceipt, receipt.id == snapshot.id else { return nil }
        let bytes = Array(element.label.utf8)
        for exposure in receipt.exposures {
            guard exposure.nodeID == "backend:\(element.backendNodeID)", exposure.field == .label,
                  exposure.totalUTF8 == bytes.count, exposure.startUTF8 >= 0,
                  exposure.endUTF8 >= exposure.startUTF8, exposure.endUTF8 <= bytes.count,
                  exposure.startUTF8 < exposure.endUTF8 || bytes.isEmpty && exposure.startUTF8 == 0,
                  let fragment = String(bytes: bytes[exposure.startUTF8..<exposure.endUTF8], encoding: .utf8)
            else { continue }
            return fragment
        }
        return nil
    }

    static func matches(snapshot: BrowserTabSnapshot, element: BrowserTabElement, role: String, label: String) -> Bool {
        element.role.utf8.elementsEqual(role.utf8)
            && exposedLabel(snapshot: snapshot, element: element).map { $0.utf8.elementsEqual(label.utf8) } == true
    }

}

/// A historical dispatch cue, never a fresh observation or input capability.
/// Keeping it in its own text item lets native history compaction retain it
/// intact at the smallest text-only receipt budget (256 minus 128 reserve).
struct EmbeddedBrowserActionReceipt: Equatable, Sendable {
    enum Kind: String, Sendable { case click, fill }
    let compactText: String

    init(kind: Kind, snapshot: BrowserTabSnapshot, elementIndex: Int) throws {
        try self.init(kind: kind, element: snapshot.element(at: elementIndex),
                      exposures: snapshot.readReceipt?.id == snapshot.id ? snapshot.readReceipt?.exposures ?? [] : [])
    }

    init(kind: Kind, witness: BrowserPublishedActionWitness) throws {
        try self.init(kind: kind, element: witness.element, exposures: witness.exposures)
    }

    private init(kind: Kind, element: BrowserTabElement?, exposures: [SemanticReadFieldExposure]) throws {
        var exposedLabel = ""
        var wholeLabelExposed = false
        if let element {
            let bytes = element.label.utf8
            // A retained element may hold an unexposed prefix or suffix. Copy
            // only one actually emitted span; never reconstruct the full label.
            for exposure in exposures where exposure.nodeID == "backend:\(element.backendNodeID)"
                && exposure.field == .label {
                guard exposure.totalUTF8 == bytes.count, exposure.startUTF8 >= 0,
                      exposure.endUTF8 >= exposure.startUTF8, exposure.endUTF8 <= bytes.count else { continue }
                let start = bytes.index(bytes.startIndex, offsetBy: exposure.startUTF8)
                let end = bytes.index(bytes.startIndex, offsetBy: exposure.endUTF8)
                guard let fragment = String(bytes: bytes[start..<end], encoding: .utf8) else { continue }
                exposedLabel = fragment
                wholeLabelExposed = exposure.startUTF8 == 0 && exposure.endUTF8 == bytes.count
                break
            }
        }
        func encode(_ label: String, partial: Bool) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "kind": kind.rawValue, "dispatched": true, "outcome": "unverified",
                "label": label, "partial": partial,
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        var label = ""
        // Measure the serialized bytes, including escaping. Iterating Characters
        // keeps any shortened fragment on Unicode grapheme boundaries.
        for character in exposedLabel {
            let candidate = label + String(character)
            guard try encode(candidate, partial: true).utf8.count <= 128 else { break }
            label = candidate
        }
        // false is one byte longer than true, so include the final flag in the
        // budget check rather than assuming the provisional size is sufficient.
        var encoded = try encode(label, partial: !wholeLabelExposed || label != exposedLabel)
        if encoded.utf8.count > 128 {
            label.removeLast()
            encoded = try encode(label, partial: true)
        }
        compactText = encoded
    }
}

struct EmbeddedBrowserReadFailureScope: Equatable, Sendable {
    let bindingHandle: UUID
    let committedDocumentID: UUID

    init(bindingHandle: UUID, committedDocumentID: UUID) {
        self.bindingHandle = bindingHandle
        self.committedDocumentID = committedDocumentID
    }

    init?(binding: BrowserTabBinding) {
        guard let documentID = binding.committedDocumentID else { return nil }
        bindingHandle = binding.handle; committedDocumentID = documentID
    }
    init?(snapshot: BrowserTabSnapshot) {
        guard let documentID = snapshot.evidenceDocument?.committedDocumentID else { return nil }
        bindingHandle = snapshot.tabHandle; committedDocumentID = documentID
    }
}

struct EmbeddedBrowserToolExecution: Sendable {
    /// Issued only by the successful native read/inventory branches. This is
    /// history provenance, never permission, a page claim, or action authority.
    enum NativeRead: String, Sendable { case read = "read_v1", inventory = "inventory_v1" }
    let response: String
    let actionReceipt: EmbeddedBrowserActionReceipt?
    let completeObservation: Bool
    let nativeRead: NativeRead?
    /// Native-only evidence of an observed binding/document generation.
    /// A fresh snapshot UUID or URL alone cannot reset a read failure budget.
    let readFailureScope: EmbeddedBrowserReadFailureScope?

    init(response: String, actionReceipt: EmbeddedBrowserActionReceipt? = nil,
         readFailureScope: EmbeddedBrowserReadFailureScope? = nil, completeObservation: Bool = false,
         nativeRead: NativeRead? = nil) {
        self.completeObservation = completeObservation
        self.response = response
        self.actionReceipt = actionReceipt
        self.readFailureScope = readFailureScope
        self.nativeRead = nativeRead
    }
}

/// A rejected preflight stays a tool failure. The runtime may publish this
/// separate bounded read only after its normal failure/terminal checks.
struct EmbeddedBrowserPreflightRecoveryFailure: Error, LocalizedError, Sendable {
    let original: BrowserTabBrokerError
    let observationResponse: String
    var readFailureScope: EmbeddedBrowserReadFailureScope? = nil
    /// Present only when the separate read's full page and rejection cue fit
    /// the existing atomic output bounds. Unavailable recoveries stay unmarked.
    var rejectionReceipt: BrowserCompleteObservation.RejectionReceipt? = nil
    var errorDescription: String? { original.localizedDescription }
}

/// A fresh turn has no inherited browser lease. This reports only host state;
/// it does not inspect tabs, reconnect an old binding, or authorize any input.
struct EmbeddedBrowserBindingRequiredFailure: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        #"{"success":false,"error":{"code":"browser_binding_required","message":"No browser tab is bound in this user turn. Previous-turn bindings, snapshots and cursors do not carry over; task-created tabs may have been closed at turn end. This is a missing binding, not a permission denial or sign-in failure."},"browser":"computa_builtin","binding_state":"unbound_current_turn","inventory_evidence":"not_observed","permission_evidence":"not_assessed","dispatched":false,"no_replay":true,"next":"Do not retry browser_read, browser_click or browser_fill until you establish this turn's binding. Use browser_tabs then browser_bind for an observed matching user tab, or browser_open with the task's supplied or previously observed URL (including local URLs), or a named service's official entrypoint. Opening a fresh task tab is an offered operation, subject to current user scope and approvals. Empty human-tab inventory does not prohibit browser_open. Then browser_read for new action references. Do not ask the user to reopen a tab or supply a URL already present in the task."}"#
    }
}

/// Each active turn receives its own taskKey from the runtime. The controller
/// retains an exact tab lease and capability; it never operates on an active tab.
actor EmbeddedBrowserToolController {
    private struct TargetIdentity: Hashable {
        let id: String
        let instanceToken: String
        init(_ target: BrowserTarget) { id = target.targetID; instanceToken = target.instanceToken }
    }
    private struct Context {
        let id = UUID()
        let lifetime = BrowserTabLifetime()
        var binding: BrowserTabBinding?
        var hasBoundTarget = false
        var snapshot: BrowserTabSnapshot?
        var actionReferences = EmbeddedBrowserActionReferences()
        var ownedTarget: BrowserTarget?
        var leasedTarget: BrowserTarget?
        var bindingLifetime: BrowserTabLifetime?
        var observedTargets = [String: BrowserTarget]()
        var inventory = [BrowserTarget]()
        var inventoryOffset = 0
        var inventoryCursor: String?
        var stalePreflightRecoveryIDs = Set<UUID>()
        var changedFilterRecoveryCursors = Set<String>()
        var scope: ComputerTaskScope?
        var cleanupTargets = [EmbeddedBrowserCleanupReport.Target]()
        var cleanupFailures = [EmbeddedBrowserCleanupReport.Issue]()
        var userBindingReleased = false
    }
    private let transport: any EmbeddedBrowserControlBackend
    private let broker: BrowserTabSessionBroker
    private var contexts = [String: Context]()
    private var leases = [String: String]()
    // Physical disposal may outlive its task/context. Never offer the same
    // unconfirmed target incarnation as a borrowable user tab.
    private var quarantinedTargets = Set<TargetIdentity>()
    private var inFlight = Set<String>()
    // A repeated release cannot turn a failed or pending disposal into an
    // empty successful result. Retired keys never grant browser authority.
    private var releasedReports = [String: EmbeddedBrowserCleanupReport]()
    private var retiredKeys = Set<String>()
    private var releasing = [String: Task<EmbeddedBrowserCleanupReport, Never>]()
    private var closed = false

    init(transport: any EmbeddedBrowserControlBackend, readLifetime: Duration = .seconds(120)) {
        self.transport = transport
        broker = BrowserTabSessionBroker(
            transport: transport, browserGeneration: UUID(), ownership: .borrowed, readLifetime: readLifetime)
    }

    /// Freeze this native-only invocation before retry accounting and approval.
    /// Resolution never captures, searches, follows a URL, or dispatches input.
    func prepareMutation(taskKey: String, tool: String, arguments: Data) throws -> EmbeddedBrowserActionReferences.Prepared {
        guard !closed, !retiredKeys.contains(taskKey) else { throw BrowserTabBrokerError.handleMissing }
        guard let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw EmbeddedBrowserActionReferences.Failure.invalidReference
        }
        try EmbeddedBrowserTools.validate(tool: tool, arguments: object)
        guard let context = contexts[taskKey] else { throw EmbeddedBrowserBindingRequiredFailure() }
        _ = try bound(taskKey, context.id)
        try context.bindingLifetime?.check()
        return try context.actionReferences.prepare(taskKey: taskKey, contextID: context.id,
            tool: tool, arguments: object, snapshot: context.snapshot)
    }

    #if DEBUG
    func actionReferenceCountsForTesting(taskKey: String) -> (current: Int, retired: Int) {
        contexts[taskKey]?.actionReferences.countsForTesting ?? (0, 0)
    }
    #endif

    /// Read-only admission before host approval. This does not reserve an input
    /// or consume its snapshot. Execute repeats these checks after approval;
    /// the broker/backend still revalidate the physical element before input.
    func preflightMutation(
        taskKey: String, tool: String, arguments: Data, scope: ComputerTaskScope? = nil,
        prepared: EmbeddedBrowserActionReferences.Prepared? = nil
    ) async throws {
        guard !closed, !retiredKeys.contains(taskKey) else { throw BrowserTabBrokerError.handleMissing }
        guard let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw BrowserTabBrokerError.invalidRead("Browser arguments must be a JSON object.")
        }
        try EmbeddedBrowserTools.validate(tool: tool, arguments: object)
        guard ["browser_click", "browser_fill"].contains(tool) else {
            throw BrowserTabBrokerError.invalidRead("Captured-target preflight requires browser_click or browser_fill.")
        }
        if let violation = scope?.embeddedBrowserToolViolation() {
            throw BrowserTabBrokerError.scopeDenied(violation)
        }
        guard inFlight.insert(taskKey).inserted else { throw BrowserTabBrokerError.operationInProgress }
        defer { inFlight.remove(taskKey) }
        guard let context = contexts[taskKey] else { throw EmbeddedBrowserBindingRequiredFailure() }
        guard context.scope == scope else {
            throw BrowserTabBrokerError.scopeDenied("The host browser scope changed within this turn; start a new turn.")
        }
        let invocation = try prepared ?? prepareMutation(taskKey: taskKey, tool: tool, arguments: arguments)
        guard invocation.matches(taskKey: taskKey, contextID: context.id, tool: tool, arguments: object) else {
            throw EmbeddedBrowserActionReferences.Failure.invalidReference
        }
        do {
            _ = try await capturedMutation(taskKey: taskKey, contextID: context.id,
                                           tool: tool, invocation: invocation, scope: scope)
        } catch let original as BrowserTabBrokerError where original == .staleSnapshot || original == .staleDocument {
            throw try await stalePreflightRecovery(taskKey: taskKey, contextID: context.id,
                                                   rejectedID: invocation.snapshotID, original: original,
                                                   wasFill: tool == "browser_fill", scope: scope)
        }
    }

    func execute(taskKey: String, tool: String, arguments: Data, scope: ComputerTaskScope? = nil)
        async throws -> String
    {
        try await executeResult(taskKey: taskKey, tool: tool, arguments: arguments, scope: scope).response
    }

    func executeResult(taskKey: String, tool: String, arguments: Data, scope: ComputerTaskScope? = nil,
                       prepared: EmbeddedBrowserActionReferences.Prepared? = nil)
        async throws -> EmbeddedBrowserToolExecution
    {
        guard !closed, !retiredKeys.contains(taskKey) else { throw BrowserTabBrokerError.handleMissing }
        guard let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw BrowserTabBrokerError.invalidRead("Browser arguments must be a JSON object.")
        }
        try EmbeddedBrowserTools.validate(tool: tool, arguments: object)
        if let violation = scope?.embeddedBrowserToolViolation() {
            throw BrowserTabBrokerError.scopeDenied(violation)
        }
        guard inFlight.insert(taskKey).inserted else { throw BrowserTabBrokerError.operationInProgress }
        defer { inFlight.remove(taskKey) }
        if contexts[taskKey] == nil { contexts[taskKey] = Context(scope: scope) }
        guard contexts[taskKey]?.scope == scope else {
            throw BrowserTabBrokerError.scopeDenied(
                "The host browser scope changed within this turn; start a new turn.")
        }
        let contextID = contexts[taskKey]!.id
        let lifetime = contexts[taskKey]!.lifetime
        try lifetime.check()
        switch tool {
        case "browser_tabs":
            // An omitted or explicit-null cursor takes the same fresh branch;
            // it never inherits the retained inventory's offset or authority.
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
                    "availability": quarantinedTargets.contains(TargetIdentity(target)) ? "busy"
                        : leases[target.targetID].map { $0 == taskKey ? "bound_here" : "busy" } ?? "available",
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
            var result: [String: Any] = [
                "browser": "computa_builtin", "tabs": rows, "count": context.inventory.count,
                "binding_state": context.binding == nil ? "unbound_current_turn" : "bound_current_turn",
                "returned": rows.count, "truncated": more,
                "next_cursor": context.inventoryCursor as Any? ?? NSNull(),
                "consistency": "retained_metadata", "content_evidence": "metadata_only",
            ]
            if context.inventory.isEmpty && !more {
                result["inventory_state"] = "no_matching_human_tabs"
                result["authentication_evidence"] = "not_observed"
                result["next"] = "No matching human tabs were listed; this does not establish logout, missing credentials or denied access. Previous task-created tabs may have been closed at turn end. Use browser_open with the task's supplied or previously observed URL (including local URLs), or an authorized known service's official entrypoint, then browser_read. Opening a new task tab remains an offered operation subject to current user scope and approvals; an empty inventory is not a reason to refuse the task or ask for an already-known URL."
            }
            return try .init(response: json(result), nativeRead: .inventory)
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
                guard !quarantinedTargets.contains(TargetIdentity(current)) else {
                    throw BrowserTabBrokerError.operationInProgress
                }
                try requireScope(scope, url: current.url, title: current.title)
                try check(taskKey, contextID)
                selected = current
                if let binding = contexts[taskKey]?.binding, binding.targetID == current.targetID,
                    binding.targetInstanceToken == current.instanceToken, leases[current.targetID] == taskKey
                {
                    try binding.lifetime.check()
                    return try .init(response: bindingResponse(
                        target: current, binding: binding,
                        owned: contexts[taskKey]?.ownedTarget != nil, alreadyBound: true))
                }
            }
            let cleanup = await unbind(taskKey: taskKey, trigger: .replacement)
            guard cleanup.isSettled else {
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
                guard !quarantinedTargets.contains(TargetIdentity(target)) else {
                    throw BrowserTabBrokerError.operationInProgress
                }
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
                guard !quarantinedTargets.contains(TargetIdentity(target)) else {
                    throw BrowserTabBrokerError.operationInProgress
                }
                contexts[taskKey]?.binding = binding
                contexts[taskKey]?.hasBoundTarget = true
                // Creation and successful binding are a current observation of
                // this exact instance. A redundant bind can reuse the existing
                // no-op path, including its live target, lease and scope checks.
                if owned { contexts[taskKey]?.observedTargets[target.targetID] = target }
                return try .init(response: bindingResponse(target: target, binding: binding, owned: owned),
                                 readFailureScope: EmbeddedBrowserReadFailureScope(binding: binding))
            } catch {
                // Failed binding never retains read/input authority. Keep a
                // created target reserved for cleanup until close is confirmed.
                if contexts[taskKey]?.id == contextID {
                    contexts[taskKey]?.bindingLifetime?.revoke()
                    contexts[taskKey]?.binding = nil
                    contexts[taskKey]?.snapshot = nil
                    if owned {
                        contexts[taskKey]?.ownedTarget = target
                        contexts[taskKey]?.leasedTarget = target
                        contexts[taskKey]?.observedTargets.removeValue(forKey: target.targetID)
                        if leases[target.targetID] == nil { leases[target.targetID] = taskKey }
                    }
                }
                var disposed = !owned
                if owned {
                    let identity = TargetIdentity(target)
                    quarantinedTargets.insert(identity)
                    do {
                        try await transport.closeTarget(target: target)
                        quarantinedTargets.remove(identity)
                        disposed = true
                    } catch { }
                }
                if disposed {
                    if contexts[taskKey]?.id == contextID,
                       contexts[taskKey]?.leasedTarget?.targetID == target.targetID,
                       contexts[taskKey]?.leasedTarget?.instanceToken == target.instanceToken {
                        contexts[taskKey]?.ownedTarget = nil
                        contexts[taskKey]?.leasedTarget = nil
                        contexts[taskKey]?.bindingLifetime = nil
                    }
                    if leases[target.targetID] == taskKey { leases.removeValue(forKey: target.targetID) }
                }
                throw error
            }
        case "browser_read":
            let view = (object["view"] as? String).flatMap(SemanticReadView.init(rawValue:))
            let cursor = object["cursor"] as? String
            let read = SemanticReadRequest(
                query: object["query"] as? String,
                view: view ?? (cursor == nil ? .overview : nil),
                cursor: cursor)
            // Keep the invalid continuation rejected. For its exact current
            // cursor only, separately expose the explicitly requested fresh
            // view once instead of leaving the model on the old overview.
            if let cursor = read.cursor {
                _ = try bound(taskKey, contextID)
                guard let previous = contexts[taskKey]?.snapshot,
                      previous.nextCursor == cursor, let receipt = previous.readReceipt else {
                    // Diagnose the exact retained-capability mismatch before
                    // any capture. Do not infer an identifier's kind or turn
                    // an unissued/replaced cursor into a fresh read.
                    throw BrowserTabBrokerError.invalidRead(
                        "cursor is not the latest page's exact next_cursor. Successful continuation, fresh read or current_observation replaces older cursors; admitted input invalidates them. Send only the latest page's next_cursor to continue. Omit cursor or use null for a fresh view/query. No read or input was dispatched.")
                }
                let original = SemanticReadRequest(query: receipt.query, view: receipt.view)
                guard read.continues(original) else {
                    throw try await changedFilterRecovery(taskKey: taskKey, contextID: contextID,
                        cursor: cursor, read: SemanticReadRequest(query: read.query, view: view ?? .overview), scope: scope)
                }
            }
            let snapshot = try await currentReadObservation(
                taskKey: taskKey, contextID: contextID, scope: scope, read: read, compact: true)
            return try .init(response: readResponse(snapshot, taskKey: taskKey, compact: true),
                readFailureScope: .init(snapshot: snapshot), completeObservation: true, nativeRead: .read)
        case "browser_click", "browser_fill":
            let invocation = try prepared ?? prepareMutation(taskKey: taskKey, tool: tool, arguments: arguments)
            guard invocation.matches(taskKey: taskKey, contextID: contextID, tool: tool, arguments: object) else {
                throw EmbeddedBrowserActionReferences.Failure.invalidReference
            }
            let (binding, witness) = try await capturedMutation(
                taskKey: taskKey, contextID: contextID, tool: tool, invocation: invocation, scope: scope)
            let receipt = try EmbeddedBrowserActionReceipt(kind: tool == "browser_fill" ? .fill : .click,
                                                          witness: witness)
            // Unsupported captured intent retains the observation. An admitted
            // mutation consumes it synchronously before the first input await.
            contexts[taskKey]?.snapshot = nil
            contexts[taskKey]?.actionReferences.retireCurrent()
            var feedback: BrowserInputFeedback?
            if tool == "browser_click" {
                feedback = try await broker.perform(
                    taskKey: taskKey, binding: binding, witness: witness,
                    action: "AXPress")
            } else {
                try await broker.setText(
                    taskKey: taskKey, binding: binding, witness: witness,
                    text: object["text"] as! String)
            }
            // Input has already completed. Observation failure must not turn
            // that dispatch into an apparent input failure that invites replay.
            let response = try await postInputResponse(taskKey: taskKey, contextID: contextID, scope: scope,
                                                      wasFill: tool == "browser_fill", receipt: receipt.compactText, feedback: feedback)
            return .init(response: response.text, actionReceipt: receipt,
                readFailureScope: contexts[taskKey]?.snapshot.flatMap(EmbeddedBrowserReadFailureScope.init(snapshot:)),
                completeObservation: response.complete)
        case "browser_navigate":
            let binding = try bound(taskKey, contextID)
            let destination = URL(string: object["url"] as! String)!
            try requireScope(scope, url: destination)
            contexts[taskKey]?.snapshot = nil
            contexts[taskKey]?.actionReferences.retireCurrent()
            let target = try await currentTarget(binding: binding, scope: scope)
            try check(taskKey, contextID)
            try await transport.navigate(
                target: target, url: destination, permit: BrowserMutationPermit(lifetime: binding.lifetime))
            try check(taskKey, contextID)
            return try .init(response: json([
                "navigation_complete": true, "no_replay": true,
                "next": "Read the current document before acting.",
            ]))
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
            return try .init(response: json([
                "matched": matched, "event_driven": true,
                "next":
                    "Read the current page for evidence; wait results do not expose new action references.",
            ]))
        case "browser_close":
            _ = try bound(taskKey, contextID)
            let cleanup = await unbind(taskKey: taskKey, trigger: .explicit)
            guard cleanup.isSettled else {
                throw BrowserTabBrokerError.browserUnavailable("Task-tab cleanup could not be confirmed.")
            }
            try check(taskKey, contextID)
            return try .init(response: json(["released": true, "existing_user_tab_preserved": true,
                "literal_copy_guidance": Self.literalCopyGuidance]))
        default: throw BrowserTabBrokerError.invalidRead("Unknown built-in browser tool.")
        }
    }

    /// Revocation precedes every cleanup await. An opening operation retains the
    /// same revoked lifetime and closes any target it receives late.
    func release(taskKey: String) async -> [String] {
        await releaseReport(taskKey: taskKey).issues
    }

    func releaseReport(taskKey: String, trigger: EmbeddedBrowserCleanupReport.Trigger = .automatic) async -> EmbeddedBrowserCleanupReport {
        if let saved = releasedReports[taskKey] { return saved }
        if let operation = releasing[taskKey] { return await operation.value }
        guard retiredKeys.insert(taskKey).inserted else {
            // The bounded detail cache may retire old reports, but never
            // their authority tombstones or uncertainty about missing proof.
            return EmbeddedBrowserCleanupReport(targets: [], userBindingReleased: false,
                pendingOperation: false, failures: [.historyLimit])
        }
        contexts[taskKey]?.lifetime.revoke()
        contexts[taskKey]?.bindingLifetime?.revoke()
        let operation = Task { await self.unbind(taskKey: taskKey, trigger: trigger, removeContext: true) }
        releasing[taskKey] = operation
        let report = await operation.value
        releasing.removeValue(forKey: taskKey)
        if releasedReports.count >= 256, let retired = releasedReports.keys.sorted().first {
            releasedReports.removeValue(forKey: retired)
        }
        releasedReports[taskKey] = report
        return report
    }

    func shutdown() async -> [String] {
        closed = true
        for context in contexts.values {
            context.lifetime.revoke()
            context.bindingLifetime?.revoke()
        }
        var issues = [String]()
        for key in Array(contexts.keys) { issues += await releaseReport(taskKey: key, trigger: .shutdown).issues }
        await broker.invalidateAll()
        issues += await transport.closeOwnedTargets()
        return issues
    }

    private func unbind(taskKey: String, trigger: EmbeddedBrowserCleanupReport.Trigger, removeContext: Bool = false) async -> EmbeddedBrowserCleanupReport {
        let pending = removeContext && inFlight.contains(taskKey)
        guard let context = contexts[taskKey] else {
            return EmbeddedBrowserCleanupReport(targets: [], userBindingReleased: false,
                pendingOperation: pending, failures: pending ? [.operationPending] : [])
        }
        var targets = context.cleanupTargets
        var failures = context.cleanupFailures
        var userBindingReleased = context.userBindingReleased
        if let target = context.ownedTarget { quarantinedTargets.insert(TargetIdentity(target)) }
        context.bindingLifetime?.revoke()
        if removeContext {
            contexts.removeValue(forKey: taskKey)
        } else {
            // An owned target's open receipt cannot reauthorize it after this
            // binding is retired, including when physical close is uncertain.
            if let target = context.ownedTarget {
                contexts[taskKey]?.observedTargets.removeValue(forKey: target.targetID)
            }
            contexts[taskKey]?.binding = nil
            contexts[taskKey]?.snapshot = nil
            contexts[taskKey]?.actionReferences.retireCurrent()
            contexts[taskKey]?.ownedTarget = nil
            contexts[taskKey]?.leasedTarget = nil
            contexts[taskKey]?.bindingLifetime = nil
        }
        if let target = context.leasedTarget, leases[target.targetID] == taskKey {
            leases.removeValue(forKey: target.targetID)
        }
        if let binding = context.binding {
            do { try await broker.revoke(taskKey: taskKey, binding: binding) } catch {
                failures.append(.bindingReleaseFailed)
            }
        }
        if let target = context.ownedTarget {
            var disposed = false
            do {
                try await transport.closeTarget(target: target)
                quarantinedTargets.remove(TargetIdentity(target))
                disposed = true
            } catch {
                failures.append(.ownedTargetCloseFailed)
            }
            if targets.count < 64 {
                targets.append(.init(targetID: target.targetID, instanceToken: target.instanceToken,
                    trigger: trigger, closed: disposed))
            } else { failures.append(.historyLimit) }
        } else if context.binding != nil || context.leasedTarget != nil {
            userBindingReleased = true
        }
        if pending { failures.append(.operationPending) }
        failures = Array(Set(failures)).sorted { $0.rawValue < $1.rawValue }
        if !removeContext, contexts[taskKey]?.id == context.id {
            contexts[taskKey]?.cleanupTargets = targets
            contexts[taskKey]?.cleanupFailures = failures
            contexts[taskKey]?.userBindingReleased = userBindingReleased
        }
        return EmbeddedBrowserCleanupReport(targets: targets, userBindingReleased: userBindingReleased,
            pendingOperation: pending, failures: failures)
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
            if contexts[taskKey]?.hasBoundTarget == false { throw EmbeddedBrowserBindingRequiredFailure() }
            throw BrowserTabBrokerError.handleMissing
        }
        try binding.lifetime.check()
        return binding
    }

    private func capturedMutation(
        taskKey: String, contextID: UUID, tool: String,
        invocation: EmbeddedBrowserActionReferences.Prepared, scope: ComputerTaskScope?
    ) async throws -> (BrowserTabBinding, BrowserPublishedActionWitness) {
        let binding = try bound(taskKey, contextID)
        guard let snapshot = contexts[taskKey]?.snapshot,
              contexts[taskKey]?.actionReferences.admits(invocation, snapshot: snapshot) == true,
              let witness = invocation.witness
        else { throw BrowserTabBrokerError.staleSnapshot }
        let element = witness.element
        guard element.isEnabled else { throw EmbeddedBrowserTools.MutationEligibilityFailure.disabledTarget }
        if tool == "browser_click" {
            guard element.supportsPress else { throw EmbeddedBrowserTools.MutationEligibilityFailure.pressUnavailable }
        } else {
            guard element.supportsSetText else { throw EmbeddedBrowserTools.MutationEligibilityFailure.fillUnavailable }
        }
        try requireScope(scope, url: witness.documentURL)
        if tool == "browser_click", let link = element.linkURL, !link.isEmpty {
            guard let destination = URL(string: link, relativeTo: witness.documentURL)?.absoluteURL else {
                throw BrowserTabBrokerError.invalidRead("The observed browser link has an invalid destination.")
            }
            try EmbeddedBrowserURLPolicy.validate(destination)
            try requireScope(scope, url: destination)
        }
        try await broker.validatePublishedAction(taskKey: taskKey, binding: binding, witness: witness)
        try Task.checkCancellation()
        try check(taskKey, contextID)
        let target = try await currentTarget(binding: binding, scope: scope)
        try Task.checkCancellation()
        try check(taskKey, contextID)
        try binding.lifetime.check()
        guard contexts[taskKey]?.snapshot == snapshot,
              contexts[taskKey]?.actionReferences.admits(invocation, snapshot: snapshot) == true else {
            throw BrowserTabBrokerError.staleSnapshot
        }
        guard target.url == witness.documentURL else { throw BrowserTabBrokerError.staleDocument }
        try witness.checkCaptureAge()
        return (binding, witness)
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Ordinary and post-input reads share the broker's exact document,
    /// pagination and physical-target checks. This grants no input or new tab.
    private func currentObservation(
        taskKey: String, contextID: UUID, scope: ComputerTaskScope?, read: SemanticReadRequest,
        replacingCursor: String? = nil, compact: Bool = false,
        compactEncoding: BrowserCompleteObservation.Encoding = .read
    ) async throws -> BrowserTabSnapshot {
        let binding = try bound(taskKey, contextID)
        let priorPublishedActions = contexts[taskKey]?.actionReferences.freshReadCandidates(snapshot: contexts[taskKey]?.snapshot) ?? []
        // No failed/unpublished read can carry an earlier reference through a
        // later fresh capture. Cursor admission errors never reach this method.
        contexts[taskKey]?.actionReferences.beginRead()
        var observationReady = false
        defer {
            if !observationReady, contexts[taskKey]?.id == contextID {
                contexts[taskKey]?.actionReferences.abortRead()
            }
        }
        let fresh = read.cursor == nil && read.snapshotID == nil && read.elementIndex == nil && replacingCursor == nil
        // A fresh read already waits for native navigation in its transport.
        // Check physical ownership now, then site scope at that existing wait's
        // completion, before any page capture. Retained reads remain immediate.
        _ = try await currentTarget(binding: binding, scope: fresh ? nil : scope)
        try check(taskKey, contextID)
        try binding.lifetime.check()
        let contextLifetime = contexts[taskKey]!.lifetime
        let authorization: BrowserReadAuthorization?
        if fresh {
            authorization = { target in
                try Task.checkCancellation()
                try contextLifetime.check()
                try binding.lifetime.check()
                guard target.targetID == binding.targetID, target.instanceToken == binding.targetInstanceToken else {
                    throw BrowserTabBrokerError.targetReplaced
                }
                if let violation = scope?.siteViolation(url: target.url) {
                    throw BrowserTabBrokerError.scopeDenied(violation)
                }
            }
        } else { authorization = nil }
        // Ordinary reads revoke first. A bounded changed-filter recovery is
        // transactional in the broker: a failed capture preserves the prior
        // capability, which still requires all normal physical preflights.
        if replacingCursor == nil { contexts[taskKey]?.snapshot = nil }
        let observation = try await broker.snapshot(
            taskKey: taskKey, binding: binding, bundleIdentifier: "com.ahmedelamin.computa", read: read,
            replacingCursor: replacingCursor, compact: compact, compactEncoding: compactEncoding,
            readAuthorization: authorization, priorPublishedActions: priorPublishedActions)
        // The broker has now committed the replacement. If publication fails,
        // neither its unpublished references nor the superseded ones survive.
        contexts[taskKey]?.snapshot = nil
        try check(taskKey, contextID)
        try observation.binding.lifetime.check()
        try requireScope(scope, url: observation.snapshot.documentURL)
        let target = try await currentTarget(binding: observation.binding, scope: nil)
        try Task.checkCancellation()
        try check(taskKey, contextID)
        try observation.binding.lifetime.check()
        guard contexts[taskKey]?.binding?.handle == binding.handle,
              target.url == observation.snapshot.documentURL else { throw BrowserTabBrokerError.staleDocument }
        // Navigation can begin immediately after capture. Classify that drift
        // before interpreting a different provisional address as this page's
        // scope. The existing fresh-read retry still gates its settled target.
        try requireScope(scope, url: target.url)
        contexts[taskKey]?.binding = observation.binding
        contexts[taskKey]?.snapshot = observation.snapshot
        observationReady = true
        return observation.snapshot
    }

    /// A dispatched input can start navigation after the old page looked ready.
    /// Share the ordinary fresh-read recovery with post-input observation: one
    /// additional read on the same lease, never another input or a new binding.
    /// Retained cursor/subtree reads cannot move to a different document.
    private func currentReadObservation(
        taskKey: String, contextID: UUID, scope: ComputerTaskScope?, read: SemanticReadRequest, compact: Bool = false,
        compactEncoding: BrowserCompleteObservation.Encoding = .read
    ) async throws -> BrowserTabSnapshot {
        do {
            return try await currentObservation(taskKey: taskKey, contextID: contextID, scope: scope, read: read,
                                                compact: compact, compactEncoding: compactEncoding)
        } catch BrowserTabBrokerError.staleDocument
            where read.cursor == nil && read.snapshotID == nil && read.elementIndex == nil {
            try Task.checkCancellation()
            try check(taskKey, contextID)
            try bound(taskKey, contextID).lifetime.check()
            contexts[taskKey]?.snapshot = nil
            // This direct call deliberately cannot recurse/retry a second time.
            // It repeats physical target, document, scope and publication checks.
            return try await currentObservation(taskKey: taskKey, contextID: contextID, scope: scope, read: read,
                                                compact: compact, compactEncoding: compactEncoding)
        }
    }

    private func postInputResponse(taskKey: String, contextID: UUID, scope: ComputerTaskScope?, wasFill: Bool,
                                   receipt: String, feedback: BrowserInputFeedback?) async throws -> (text: String, complete: Bool) {
        var result: [String: Any] = ["dispatched": true, "no_replay": true, "result_verified": false,
                                     "input_kind": wasFill ? "fill" : "click"]
        let effect = wasFill
            ? "Field replacement and input/change events were dispatched; no Enter key or submit-control click was sent. Page handlers may react."
            : "Click already dispatched."
        do {
            let encoding = BrowserCompleteObservation.Encoding.input(wasFill: wasFill, receipt: receipt, feedback: feedback)
            let snapshot = try await currentReadObservation(taskKey: taskKey, contextID: contextID,
                scope: scope, read: SemanticReadRequest(view: .overview), compact: true, compactEncoding: encoding)
            let text = try readResponse(snapshot, taskKey: taskKey, compact: true)
            let encoded = try encoding.encode(text, snapshotID: snapshot.id, page: .init(snapshot: snapshot))
            // The broker fits the same envelope before issuing its cursor.
            // Recheck actual published refs; never truncate a capability row.
            guard try BrowserCompleteObservation.excessBytes(encoded, actionReceipt: receipt) == 0 else {
                throw PostInputObservationFailure.outputLimit
            }
            return (encoded, true)
        } catch {
            if contexts[taskKey]?.id == contextID {
                contexts[taskKey]?.snapshot = nil
                contexts[taskKey]?.actionReferences.retireCurrent()
            }
            result["current_observation"] = ["status": "unavailable", "reason": Self.observationFailureReason(error)]
            if !wasFill, let feedback, !Task.isCancelled, (try? check(taskKey, contextID)) != nil {
                result["input_feedback"] = feedback.presentation(page: nil)
            }
            result["action_references"] = ["consumed": true, "next": "browser_read"]
            result["next"] = effect + " Do not repeat this input. Use browser_read for current evidence and new references if the bound tab is still available."
            return (try json(result), false)
        }
    }

    /// Called only after capturedMutation rejected before approval or input.
    /// Neither a failed recovery nor an explicit read refunds this turn's cap.
    private func stalePreflightRecovery(taskKey: String, contextID: UUID, rejectedID: UUID,
                                         original: BrowserTabBrokerError, wasFill: Bool,
                                         scope: ComputerTaskScope?) async throws -> EmbeddedBrowserPreflightRecoveryFailure {
        try Task.checkCancellation()
        try check(taskKey, contextID)
        var result: [String: Any] = [
            "success": false, "error": ["code": original == .staleDocument ? "stale_document" : "stale_snapshot",
                                        "message": original.localizedDescription],
            "dispatched": false, "no_replay": true,
        ]
        let repeated = contexts[taskKey]!.stalePreflightRecoveryIDs.contains(rejectedID)
        let exhausted = contexts[taskKey]!.stalePreflightRecoveryIDs.count
            + contexts[taskKey]!.changedFilterRecoveryCursors.count >= 3
        if repeated || exhausted {
            result["current_observation"] = ["status": "unavailable", "reason": repeated ? "recovery_already_attempted" : "recovery_limit"]
            result["next"] = "No input was dispatched. The stale reference was rejected and not retried. Use browser_read for current evidence before choosing another input."
            return EmbeddedBrowserPreflightRecoveryFailure(original: original, observationResponse: try json(result))
        }
        contexts[taskKey]?.stalePreflightRecoveryIDs.insert(rejectedID)
        do {
            let cue = BrowserCompleteObservation.RejectionReceipt.stale(
                wasFill: wasFill, documentChanged: original == .staleDocument)
            let encoding = BrowserCompleteObservation.Encoding.recovery(receipt: cue, view: .overview)
            let snapshot = try await currentObservation(taskKey: taskKey, contextID: contextID,
                scope: scope, read: SemanticReadRequest(view: .overview), compact: true, compactEncoding: encoding)
            try Task.checkCancellation()
            try check(taskKey, contextID)
            let response = try completeRecoveryResponse(snapshot, taskKey: taskKey, encoding: encoding)
            try Task.checkCancellation()
            return EmbeddedBrowserPreflightRecoveryFailure(original: original, observationResponse: response,
                readFailureScope: .init(snapshot: snapshot), rejectionReceipt: cue)
        } catch {
            if contexts[taskKey]?.id == contextID { contexts[taskKey]?.snapshot = nil }
            try Task.checkCancellation()
            result["current_observation"] = ["status": "unavailable", "reason": Self.observationFailureReason(error)]
            result["next"] = "No input was dispatched. The stale reference was rejected and not retried. Use browser_read for current evidence if the bound tab is still available."
            return EmbeddedBrowserPreflightRecoveryFailure(original: original, observationResponse: try json(result))
        }
    }

    /// A rejected continuation may carry one separate, fresh read of the
    /// filters the model explicitly supplied. This never replays an action or
    /// reads from a foreign, expired, replaced or navigation-stale capture.
    private func changedFilterRecovery(taskKey: String, contextID: UUID, cursor: String,
                                       read: SemanticReadRequest, scope: ComputerTaskScope?) async throws -> EmbeddedBrowserPreflightRecoveryFailure {
        try Task.checkCancellation()
        try check(taskKey, contextID)
        let original = BrowserTabBrokerError.invalidRead("A continuation retains its captured view/query. The changed-filter continuation was rejected; any attached observation is a separate fresh read of the requested filters. No input was dispatched.")
        var result: [String: Any] = [
            "success": false, "error": ["code": "continuation_filters_changed", "message": original.localizedDescription],
            "dispatched": false, "no_replay": true,
        ]
        let repeated = contexts[taskKey]!.changedFilterRecoveryCursors.contains(cursor)
        let exhausted = contexts[taskKey]!.changedFilterRecoveryCursors.count
            + contexts[taskKey]!.stalePreflightRecoveryIDs.count >= 3
        if repeated || exhausted {
            result["current_observation"] = ["status": "unavailable", "reason": repeated ? "recovery_already_attempted" : "recovery_limit"]
            result["next"] = "The continuation was rejected. To change view/query, call browser_read with the requested filters and omit cursor. No input or recovery read occurred."
            return EmbeddedBrowserPreflightRecoveryFailure(original: original, observationResponse: try json(result))
        }
        contexts[taskKey]?.changedFilterRecoveryCursors.insert(cursor)
        var captured = false
        do {
            let cue = BrowserCompleteObservation.RejectionReceipt.changedFilters
            let encoding = BrowserCompleteObservation.Encoding.recovery(receipt: cue, view: read.view)
            let snapshot = try await currentObservation(taskKey: taskKey, contextID: contextID,
                scope: scope, read: read, replacingCursor: cursor, compact: true, compactEncoding: encoding)
            captured = true
            try Task.checkCancellation()
            try check(taskKey, contextID)
            let response = try completeRecoveryResponse(snapshot, taskKey: taskKey, encoding: encoding)
            return EmbeddedBrowserPreflightRecoveryFailure(original: original, observationResponse: response,
                readFailureScope: .init(snapshot: snapshot), rejectionReceipt: cue)
        } catch {
            if captured, contexts[taskKey]?.id == contextID { contexts[taskKey]?.snapshot = nil }
            try Task.checkCancellation()
            result["current_observation"] = ["status": "unavailable", "reason": Self.observationFailureReason(error)]
            result["next"] = "The continuation was rejected and no input was dispatched. No replacement observation is available. Request browser_read with the desired filters and omit cursor; do not infer absent content."
            return EmbeddedBrowserPreflightRecoveryFailure(original: original, observationResponse: try json(result))
        }
    }

    /// The broker sizes the same envelope while paging its immutable capture.
    /// Recheck actual published refs without clipping rows or advancing a cursor.
    private func completeRecoveryResponse(_ snapshot: BrowserTabSnapshot, taskKey: String,
                                           encoding: BrowserCompleteObservation.Encoding) throws -> String {
        let text = try readResponse(snapshot, taskKey: taskKey, compact: true)
        let response = try encoding.encode(text, snapshotID: snapshot.id)
        guard try BrowserCompleteObservation.excessBytes(response, actionReceipt: encoding.retentionCue) == 0 else {
            throw PostInputObservationFailure.outputLimit
        }
        return response
    }

    private enum PostInputObservationFailure: Error { case outputLimit }

    private static func observationFailureReason(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is PostInputObservationFailure { return "output_limit" }
        switch error as? BrowserTabBrokerError {
        case .handleMissing, .crossTaskHandle, .browserGenerationChanged, .ownershipMismatch: return "binding_unavailable"
        case .targetClosed, .targetReplaced: return "target_unavailable"
        case .staleDocument, .staleSnapshot: return "document_changed"
        case .scopeDenied: return "scope_denied"
        case .outputLimit: return "output_limit"
        case .invalidRead: return "invalid_read"
        default: return "read_failed"
        }
    }

    /// Host guidance refers only to values already observed. It neither repeats
    /// page data nor grants observations, references or outcome proof.
    private static let literalCopyGuidance = BrowserCompleteObservation.literalCopyGuidance

    /// References adapt only controls actually exposed by this read. Their
    /// reserved row bytes do not change current-snapshot/physical preflight.
    private func readResponse(_ snapshot: BrowserTabSnapshot, taskKey: String, compact: Bool = false) throws -> String {
        guard var context = contexts[taskKey], context.snapshot == snapshot, let binding = context.binding else {
            throw BrowserTabBrokerError.staleSnapshot
        }
        let suffixes = context.actionReferences.publish(snapshot: snapshot, binding: binding)
        let rows = Dictionary(uniqueKeysWithValues: (snapshot.presentation?.rows ?? []).map { row in
            (row.text, row.text + (suffixes[row.index] ?? ""))
        })
        let text = Self.modelFacingSnapshotText(snapshot).split(separator: "\n", omittingEmptySubsequences: false)
            .map { rows[String($0)] ?? String($0) }.joined(separator: "\n")
        guard text.utf8.count <= 16_384,
              suffixes.values.allSatisfy({ $0.utf8.count <= SemanticReadPresentation.rowMetadataByteReserve }) else {
            throw PostInputObservationFailure.outputLimit
        }
        if compact {
            let result = text + (try BrowserCompleteObservation.footer(cursor: snapshot.nextCursor))
            guard try BrowserCompleteObservation.excessBytes(result) == 0 else {
                throw PostInputObservationFailure.outputLimit
            }
            // Reference publication is transactional with the complete page.
            contexts[taskKey]?.actionReferences = context.actionReferences
            return result
        }
        var metadata: [String: Any] = [
            "supersedes_previous": !snapshot.isActionContinuation, "consumed_by_admitted_input": true,
            "next_after_input": "Use available current_observation; otherwise browser_read. Never replay dispatched input.",
            "references": "Use the intended observed click_ref or fill_ref. Cursor pages retain earlier refs from the same capture within the 120-ref FIFO bound. Fresh reads retain prior refs only when the same native target is corroborated without renewing expiry; changed/absent targets expire. Input consumes all refs.",
            "literal_copy_guidance": Self.literalCopyGuidance,
        ]
        if let cursor = snapshot.nextCursor {
            metadata["continuation"] = ["tool": "browser_read", "arguments": ["cursor": cursor]]
        }
        let result = text + "\nBROWSER_ACTION_REFERENCES " + (try json(metadata))
        contexts[taskKey]?.actionReferences = context.actionReferences
        return result.utf8.count <= 16_384 ? result : text
    }

    /// The epoch remains native authority and canonical evidence, but is not a
    /// browser tool argument. Omit only its exact host-generated header field;
    /// page text, pagination provenance and the actionable snapshot ID stay intact.
    nonisolated static func modelFacingSnapshotText(_ snapshot: BrowserTabSnapshot) -> String {
        let text = snapshot.formattedText
        let end = text.firstIndex(of: "\n") ?? text.endIndex
        let header = text[..<end]
        let anchor = " tab_handle=\(snapshot.tabHandle.uuidString) document_epoch=\(snapshot.documentEpoch.uuidString) source="
        guard header.hasPrefix("AXSNAPSHOT id=\(snapshot.id.uuidString) "),
              let range = header.range(of: anchor) else { return text }
        var result = text
        result.replaceSubrange(range, with: " tab_handle=\(snapshot.tabHandle.uuidString) source=")
        return result
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
            "bound": true,
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
        if let violation { throw BrowserTabBrokerError.scopeDenied(violation) }
    }

    private func currentTarget(binding: BrowserTabBinding, scope: ComputerTaskScope?) async throws
        -> BrowserTarget
    {
        guard let target = try await transport.target(id: binding.targetID),
            target.instanceToken == binding.targetInstanceToken
        else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard !quarantinedTargets.contains(TargetIdentity(target)) else {
            throw BrowserTabBrokerError.operationInProgress
        }
        try requireScope(scope, url: target.url)
        return target
    }
}

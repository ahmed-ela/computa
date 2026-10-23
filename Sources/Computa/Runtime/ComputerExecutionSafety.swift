import Foundation

/// Host-owned decisions, never inferred from model assertions of success.
struct ComputerExecutionFailure: LocalizedError {
    let message: String
    var stop = false
    var errorDescription: String? { message }
}

struct ComputerUnchangedAttemptGuard {
    static let browserReferenceRoutingKey = "browser-reference-routing"
    private var attempts: [String: Int] = [:]
    private var browserReadScope: EmbeddedBrowserReadFailureScope?

    static func key(tool: String, arguments: [String: Any], observedElementIdentity: String? = nil) -> String {
        if tool == "browser_click" || tool == "browser_fill" {
            guard let observedElementIdentity else { return browserReferenceRoutingKey }
            var intent: [String: Any] = ["observed_element_identity": observedElementIdentity]
            if tool == "browser_fill", let text = arguments["text"] as? String { intent["text"] = text }
            let bytes = try? JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
            return tool + ":" + (bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "invalid")
        }
        // Capability refresh is not a new intent. Keep action/text/element,
        // but do not let fresh opaque IDs evade the no-progress budget.
        var stable = arguments.filter { !["snapshot_id", "capture_id", "cursor", "postcondition"].contains($0.key) }
        if let observedElementIdentity {
            stable.removeValue(forKey: "element_index")
            stable["observed_element_identity"] = observedElementIdentity
        }
        let data = try? JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys])
        return tool + ":" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "invalid")
    }

    mutating func failed(key: String) -> Bool {
        attempts[key, default: 0] += 1
        return attempts[key, default: 0] >= 3
    }

    mutating func succeeded(key: String) { attempts.removeValue(forKey: key) }

    /// Only a host-verified binding/current observation supplies this identity.
    /// Fresh cursors/snapshots and model URLs are not document transitions.
    /// Mutation/native failures and the controller's turn-wide recovery cap
    /// remain independent of which browser document is now being read.
    mutating func observedBrowserReadScope(_ scope: EmbeddedBrowserReadFailureScope) {
        guard browserReadScope != scope else { return }
        browserReadScope = scope
        attempts = attempts.filter { !$0.key.hasPrefix("browser_read:") }
    }
}

enum ComputerOutcomeToolContract {
    static let name = "computer_v2_verify"
    static var spec: [String: Any] { [
        "type": "function",
        "name": name,
        "description": "Read-only action receipt lookup or pending-outcome verification; never replays input. For an operation already verified or explicitly rejected before input, operation_id alone returns bounded HISTORICAL_ACTION_STATUS, never a live observation or proof of a newly requested property. Only current-task/current-turn receipts are available. Background-native planned actions are verified automatically against intent fixed BEFORE dispatch. VERIFIED_PROPERTY needs no extra verify call; ALREADY_SATISFIED means the state was already present and no input occurred. For a pending armed plan, this tool can only recheck that original plan within its remaining read budget: it cannot replace the property or expected result after seeing the outcome. Copy operation_id from ACTION_EVIDENCE and the current snapshot_id. For legacy unplanned actions, property=value checks value=, property=text checks label= (NOT value=), and document_url checks url=; expected must be the exact nonempty observed value, changed from a known baseline. A verified property is not whole-task success or sender/message identity. Search conclusions separately require the requested query and actual results/explicit empty state; snapshot no_matches is NOT empty search results. A rejected undispatched request did not perform its action. Do not retry input to obtain verification.",
        "inputSchema": [
            "type": "object", "additionalProperties": false,
            "properties": [
                "operation_id": ["type": "string"],
                "snapshot_id": ["type": "string", "format": "uuid"],
                "property": ["type": "string", "enum": ["text", "value", "document_url"]],
                "element_index": ["type": "integer", "minimum": 0],
                "expected": ["type": "string", "minLength": 1, "maxLength": 2048],
            ],
            "required": ["operation_id"],
        ],
    ] }

    struct Request {
        let operationID: String
        let snapshotID: UUID
        let property: String
        let expected: String
    }

    static func validateOperationID(_ args: [String: Any]) throws -> String {
        guard Set(args.keys).isSubset(of: ["operation_id", "snapshot_id", "property", "element_index", "expected"]),
              let id = args["operation_id"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 256,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ComputerExecutionFailure(message: "Invalid operation_id or unsupported verification arguments. No lookup, read or input occurred.")
        }
        return id
    }

    /// Returns only host-recorded terminal facts, never a live observation.
    /// Ordinary failed/unknown-delivery operations remain on the normal path.
    static func historicalStatus(operationID: String, evidence: ComputerActionEvidence,
                                 activeTurnID: String) -> String? {
        guard evidence.turnID == activeTurnID,
              let operation = evidence.operations.first(where: { $0.id == operationID }),
              operation.requiresVerification else { return nil }
        let status: String
        if operation.verification != nil {
            status = "original_property_verified"
        } else if operation.dispatch == .notDispatched, operation.foregroundEffect == nil,
                  operation.preflightRejection != nil || operation.alreadySatisfied != nil {
            status = "not_performed"
        } else { return nil }
        return "HISTORICAL_ACTION_STATUS operation_id=\(operationID) status=\(status) live_observation=false. "
            + "This reports only the existing receipt; no read, input or replay occurred. It does not verify supplied property/expected values, current page state, or task completion. Read current content if needed; do not repeat this action or verification to obtain a new proof."
    }

    static func validate(_ args: [String: Any]) throws -> Request {
        let operationID = try validateOperationID(args)
        guard let id = args["snapshot_id"] as? String, let snapshotID = UUID(uuidString: id),
              let property = args["property"] as? String, ["text", "value", "document_url"].contains(property),
              let expected = args["expected"] as? String, !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expected.count <= 2048 else {
            throw ComputerExecutionFailure(message: "Invalid outcome verification arguments. Use an actual operation_id and current snapshot_id; no verification occurred.")
        }
        let key: String
        if property == "document_url" {
            guard args["element_index"] == nil else { throw ComputerExecutionFailure(message: "document_url has no element_index.") }
            key = property
        } else {
            guard let index = args["element_index"] as? NSNumber,
                  CFGetTypeID(index) != CFBooleanGetTypeID(), index.doubleValue.isFinite,
                  index.doubleValue == Double(index.intValue), index.intValue >= 0 else {
                throw ComputerExecutionFailure(message: "Verification requires an observed element_index.")
            }
            key = "element:\(index.intValue):\(property)"
        }
        return Request(operationID: operationID, snapshotID: snapshotID, property: key, expected: expected)
    }
}

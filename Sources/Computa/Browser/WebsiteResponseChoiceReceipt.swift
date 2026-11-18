import Foundation
import CoreFoundation

/// A finite action receipt, never a model, conversation, response or cleanup
/// proof. The current optional action is Qwen's anonymous SMRM preference.
struct WebsiteResponseChoiceReceipt: Equatable, Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case observed
        case grantSpent = "grant_spent"
        case acknowledged

        var rank: Int { switch self { case .observed: 0; case .grantSpent: 1; case .acknowledged: 2 } }
    }
    let phase: Phase

    init(phase: Phase) { self.phase = phase }

    init?(_ raw: Any?) {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["version", "kind", "policy", "phase", "choiceSpent", "acknowledged", "noReplay"],
              let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              value["kind"] as? String == "qwen_smrm", value["policy"] as? String == "first_observed_card_v1",
              let rawPhase = value["phase"] as? String, let phase = Phase(rawValue: rawPhase) else { return nil }
        func bool(_ key: String) -> Bool? {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        let spent = phase != .observed
        guard bool("choiceSpent") == spent, bool("noReplay") == spent,
              bool("acknowledged") == (phase == .acknowledged) else { return nil }
        self.phase = phase
    }

    func follows(_ previous: Self?) -> Bool { previous.map { phase.rank >= $0.phase.rank } ?? true }

    var dictionary: [String: Any] {
        ["version": 1, "kind": "qwen_smrm", "policy": "first_observed_card_v1", "phase": phase.rawValue,
            "choiceSpent": phase != .observed, "acknowledged": phase == .acknowledged, "noReplay": phase != .observed]
    }
}

/// Native memory only. These fields fence a historical action receipt; they
/// are never a current page, model, response or cleanup proof.
struct WebsiteResponseChoiceStatus: Equatable, Sendable {
    let sessionToken: UUID
    let documentGeneration: UUID
    let modelID: String
    let sequence: Int
    let receipt: WebsiteResponseChoiceReceipt

    func matches(sessionToken: String, documentGeneration: UUID?, modelID: String, sequence: Int,
                 previous: WebsiteResponseChoiceReceipt?) -> Bool {
        UUID(uuidString: sessionToken) == self.sessionToken && documentGeneration == self.documentGeneration
            && modelID == self.modelID && sequence == 1 && self.sequence == 1 && receipt.follows(previous)
    }
}

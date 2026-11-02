import Foundation
import CoreFoundation

/// Only the routes observed during a single Kimi plain-chat submission. Route
/// recognition is not conversation ownership; native first-body proof is separate.
enum KimiSavedConversationRoute: Equatable {
    case fresh, provisional(String), canonical(String)

    init?(_ url: URL) {
        guard url.scheme == "https", url.host == "www.kimi.ai", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard items.isEmpty || items == [URLQueryItem(name: "chat_enter_method", value: "home")] else { return nil }
        if url.absoluteString == "https://www.kimi.ai/" { self = .fresh; return }
        guard url.path.hasPrefix("/chat/") else { return nil }
        let id = String(url.path.dropFirst(6))
        guard url.absoluteString == "https://www.kimi.ai/chat/" + id + (items.isEmpty ? "" : "?chat_enter_method=home") else { return nil }
        if id.range(of: #"^p[a-f0-9]{7}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"#, options: .regularExpression) != nil {
            self = .provisional(url.path)
        } else if let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id {
            self = .canonical("https://www.kimi.ai" + url.path)
        } else { return nil }
    }

    var conversation: String? {
        if case .canonical(let value) = self { return value }
        return nil
    }
}

/// Monotonic observation state only. It cannot authorize an answer or deletion.
struct KimiSavedConversationRoutes {
    private(set) var last: URL?
    private(set) var provisional: String?
    private(set) var canonical: String?

    mutating func observe(_ url: URL, submitted: Bool) -> Bool {
        guard let route = KimiSavedConversationRoute(url) else { return false }
        if !submitted { return route == .fresh && provisional == nil && canonical == nil }
        if url == last { return true }
        switch route {
        case .fresh:
            guard provisional == nil, canonical == nil else { return false }
        case .provisional(let path):
            guard canonical == nil, provisional == nil else { return false }
            provisional = path
        case .canonical(let value):
            guard canonical == nil else { return false }
            canonical = value
        }
        last = url
        return true
    }
}

/// One operation, three separately claimed UI mutations. Observations never
/// replenish a claim, including when a callback is lost or throws after dispatch.
struct KimiDeletionProgress {
    enum Action: String, CaseIterable, Hashable {
        case openMenu = "deleteConversation"
        case selectDelete = "selectConversationDeletion"
        case confirmDelete = "confirmConversationDeletion"
        case observe = "observeDeletedConversation"
    }
    enum Phase: String { case menu, confirmation, observing }
    private(set) var claimed = Set<Action>()
    private(set) var phase: Phase?
    private(set) var nextActionReady = false
    private(set) var deleted = false

    mutating func claimNext() -> Action {
        let action: Action
        switch phase {
        case nil: action = .openMenu
        case .menu where nextActionReady: action = .selectDelete
        case .confirmation where nextActionReady: action = .confirmDelete
        default: return .observe
        }
        guard claimed.insert(action).inserted else { return .observe }
        return action
    }

    mutating func accept(_ raw: Any?, id: UUID, generation: UUID,
                         fingerprint: String, conversation: String) -> Bool {
        let keys: Set<String> = ["id", "documentGeneration", "sequence", "firstUserFingerprint", "conversationURL",
            "phase", "menuAcknowledged", "deleteAcknowledged", "confirmAcknowledged", "conversationDeleted", "remoteErasureVerified", "nextActionReady"]
        guard let proof = raw as? [String: Any], Set(proof.keys) == keys,
              proof["id"] as? String == id.uuidString,
              proof["documentGeneration"] as? String == generation.uuidString,
              ComputerToolArgumentContract.exactInt64(proof["sequence"]) == 1,
              proof["firstUserFingerprint"] as? String == fingerprint,
              proof["conversationURL"] as? String == conversation,
              let rawPhase = proof["phase"] as? String, let nextPhase = Phase(rawValue: rawPhase),
              let menu = Self.boolean(proof["menuAcknowledged"]),
              let selection = Self.boolean(proof["deleteAcknowledged"]),
              let confirm = Self.boolean(proof["confirmAcknowledged"]),
              let nextDeleted = Self.boolean(proof["conversationDeleted"]),
              let ready = Self.boolean(proof["nextActionReady"]),
              Self.boolean(proof["remoteErasureVerified"]) == false,
              menu, claimed.contains(.openMenu), !deleted || nextDeleted else { return false }
        switch nextPhase {
        case .menu:
            guard !selection, !confirm, !nextDeleted, phase == nil || phase == .menu else { return false }
        case .confirmation:
            guard selection, !confirm, !nextDeleted, claimed.contains(.selectDelete),
                  phase == .menu || phase == .confirmation else { return false }
        case .observing:
            guard selection, confirm, !ready, claimed.contains(.confirmDelete),
                  phase == .confirmation || phase == .observing else { return false }
        }
        phase = nextPhase; nextActionReady = ready; deleted = nextDeleted
        return true
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// Dispatch acknowledgement only. A response and deletion still require the
/// full first-body proof on the canonical route after native adopts this ack.
enum KimiSubmissionAcknowledgement {
    static func matches(_ raw: Any?, owner: String, generation: UUID, fingerprint: String) -> Bool {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["ownerToken", "documentGeneration", "sequence", "outboundFingerprint"],
              value["ownerToken"] as? String == owner,
              value["documentGeneration"] as? String == generation.uuidString,
              ComputerToolArgumentContract.exactInt64(value["sequence"]) == 1,
              value["outboundFingerprint"] as? String == fingerprint else { return false }
        return true
    }
}

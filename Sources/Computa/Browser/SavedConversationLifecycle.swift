import Foundation
import CoreFoundation

/// Closed provider policies for the saved-conversation lifecycle. A provider
/// does not inherit another website's routes, temporary mode or cleanup key.
enum SavedConversationPolicy: String {
    case kimi, qwen, deepseek

    var host: String {
        switch self { case .kimi: "www.kimi.ai"; case .qwen: "chat.qwen.ai"; case .deepseek: "chat.deepseek.com" }
    }
    var origin: String { "https://" + host }
    var conversationPrefix: String {
        switch self { case .kimi: "/chat/"; case .qwen: "/c/"; case .deepseek: "/a/chat/s/" }
    }
    var cleanupInspectionKey: String {
        switch self { case .kimi: "kimiCleanupInspection"; case .qwen, .deepseek: "savedCleanupInspection" }
    }
}

/// Only observed route shapes. Recognition is not ownership: a canonical
/// conversation still requires the exact native first-body proof after Send.
enum SavedConversationRoute: Equatable {
    case fresh, provisional(String), canonical(String)

    init?(_ url: URL, policy: SavedConversationPolicy) {
        guard url.scheme == "https", url.host == policy.host, url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        switch policy {
        case .kimi:
            guard items.isEmpty || items == [URLQueryItem(name: "chat_enter_method", value: "home")] else { return nil }
        case .qwen, .deepseek:
            guard components.query == nil else { return nil }
        }
        if url.absoluteString == policy.origin + "/" { self = .fresh; return }
        guard url.path.hasPrefix(policy.conversationPrefix) else { return nil }
        let id = String(url.path.dropFirst(policy.conversationPrefix.count))
        let suffix = items.isEmpty ? "" : "?chat_enter_method=home"
        guard url.absoluteString == policy.origin + policy.conversationPrefix + id + suffix else { return nil }
        if policy == .qwen, id == "new-chat" {
            // Observed same-document placeholder after the sole Send. It has
            // no conversation identity; canonical ownership remains separate.
            self = .provisional(url.path)
        } else if policy == .kimi,
           id.range(of: #"^p[a-f0-9]{7}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"#, options: .regularExpression) != nil {
            self = .provisional(url.path)
        } else if let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id {
            self = .canonical(policy.origin + url.path)
        } else { return nil }
    }

    var conversation: String? {
        if case .canonical(let value) = self { return value }
        return nil
    }
}

/// Monotonic observation state only. It cannot authorize an answer or deletion.
struct SavedConversationRoutes {
    let policy: SavedConversationPolicy
    private(set) var last: URL?
    private(set) var provisional: String?
    private(set) var canonical: String?

    enum Rejection: String {
        case trackerMissing = "tracker_missing"
        case routeUnrecognized = "route_unrecognized"
        case nonfreshBeforeSend = "nonfresh_before_send"
        case lineageBeforeSend = "lineage_before_send"
        case regressedToFresh = "regressed_to_fresh"
        case regressedToProvisional = "regressed_to_provisional"
        case provisionalIdentityChanged = "provisional_identity_changed"
        case provisionalURLChanged = "provisional_url_changed"
        case canonicalIdentityChanged = "canonical_identity_changed"
        case canonicalURLChanged = "canonical_url_changed"
        case pinnedContextChanged = "pinned_context_changed"
        case ownedConversationMissing = "owned_conversation_missing"
        case ownedConversationChanged = "owned_conversation_changed"
    }

    enum Observation: Equatable {
        case accepted
        case rejected(Rejection)
    }

    mutating func observe(_ url: URL, submitted: Bool) -> Bool {
        observation(of: url, submitted: submitted) == .accepted
    }

    /// A rejected observation never changes any pin. The finite reason describes
    /// the original decision without storing the observed URL or identity.
    mutating func observation(of url: URL, submitted: Bool) -> Observation {
        guard let route = SavedConversationRoute(url, policy: policy) else { return .rejected(.routeUnrecognized) }
        if !submitted {
            guard route == .fresh else { return .rejected(.nonfreshBeforeSend) }
            return provisional == nil && canonical == nil ? .accepted : .rejected(.lineageBeforeSend)
        }
        if url == last { return .accepted }
        switch route {
        case .fresh:
            guard provisional == nil, canonical == nil else { return .rejected(.regressedToFresh) }
        case .provisional(let path):
            guard canonical == nil else { return .rejected(.regressedToProvisional) }
            if let provisional {
                return .rejected(path == provisional ? .provisionalURLChanged : .provisionalIdentityChanged)
            }
            provisional = path
        case .canonical(let value):
            if let canonical {
                return .rejected(value == canonical ? .canonicalURLChanged : .canonicalIdentityChanged)
            }
            canonical = value
        }
        last = url
        return .accepted
    }
}

/// One operation, three separately claimed UI mutations. Observations never
/// replenish a claim, including when a callback is lost or throws after dispatch.
struct SavedConversationDeletionProgress {
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
enum SavedConversationSubmissionAcknowledgement {
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

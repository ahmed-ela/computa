import CoreFoundation
import Foundation

/// Grok removes its Private toggle after Send. This records the observed
/// transition, never a claim that a hidden control still proves current mode.
struct GrokPrivateModeEvidence: Equatable {
    enum Source: String { case current = "current_private_control", submitted = "submitted_private_provenance" }
    static let root = "https://grok.com/"
    let source: Source
    let ownerToken: String
    let generation: UUID

    static func parse(_ raw: Any?, ownerToken: String, generation: UUID) -> Self? {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["version", "source", "ownerToken", "documentGeneration", "url", "sequence",
                                  "enteredBeforeSend", "sendClaimed", "contradictoryModeObserved"],
              integer(value["version"]) == 1,
              let source = (value["source"] as? String).flatMap(Source.init(rawValue:)),
              UUID(uuidString: ownerToken) != nil, value["ownerToken"] as? String == ownerToken,
              value["documentGeneration"] as? String == generation.uuidString,
              value["url"] as? String == root,
              integer(value["sequence"]) == (source == .current ? 0 : 1),
              boolean(value["enteredBeforeSend"]) == true,
              boolean(value["sendClaimed"]) == (source == .submitted),
              boolean(value["contradictoryModeObserved"]) == false else { return nil }
        return Self(source: source, ownerToken: ownerToken, generation: generation)
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue == Double(value.intValue) else { return nil }
        return value.intValue
    }
    private static func boolean(_ raw: Any?) -> Bool? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}

/// Native proof of the sole Send, created only from its preceding ready read.
/// It carries the host's outbound hash; adapter provenance cannot mint a claim.
struct GrokPrivateSubmission: Equatable {
    let ownerToken: String
    let generation: UUID
    let outboundFingerprint: String
    private(set) var claimed = false

    init?(ready: GrokPrivateModeEvidence, outboundFingerprint: String) {
        guard ready.source == .current, outboundFingerprint.utf8.count == 64,
              outboundFingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        ownerToken = ready.ownerToken; generation = ready.generation
        self.outboundFingerprint = outboundFingerprint
    }

    mutating func claim(ownerToken: String, generation: UUID, url: String, outboundFingerprint: String) -> Bool {
        guard !claimed, self.ownerToken == ownerToken, self.generation == generation,
              url == GrokPrivateModeEvidence.root, self.outboundFingerprint == outboundFingerprint else { return false }
        claimed = true
        return true
    }

    func accepts(_ evidence: GrokPrivateModeEvidence, sequence: Int) -> Bool {
        claimed && sequence == 1 && evidence.source == .submitted
            && evidence.ownerToken == ownerToken && evidence.generation == generation
    }
}

/// Navigation-only lease. A saved route can be left once, but is never an
/// inference conversation or a source of model, message, or cleanup authority.
struct GrokFreshStartPreparation: Sendable {
    enum Action: String, Sendable { case inspect = "grokFreshStartInspect", expand = "grokFreshStartExpandSidebar", newChat = "grokFreshStartNewChat", verify = "grokFreshStartVerify" }
    enum Stage: String, Sendable { case pending, sidebarClosed = "sidebar_closed", newChatReady = "new_chat_ready", sidebarRequested = "sidebar_requested", newChatRequested = "new_chat_requested", rootObserved = "root_observed" }
    struct Readiness: Hashable, Sendable {
        enum Target: String, Sendable { case toggle, newChat = "new_chat" }
        enum Reason: String, Sendable { case disabled, invalidGeometry = "invalid_geometry", outsideViewport = "outside_viewport", occluded }
        let target: Target
        let reason: Reason
    }
    struct Observation: Sendable {
        let stage: Stage
        let readiness: Readiness?
    }
    struct Route: Equatable, Sendable {
        let path: String
        let responseID: String?
        init?(_ raw: String) {
            let uuid = "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"
            guard raw.range(of: "^https://grok\\.com/c/" + uuid + "(?:\\?rid=" + uuid + ")?$", options: .regularExpression) != nil,
                  !raw.contains("\n"), !raw.contains("\r") else { return nil }
            let parts = raw.components(separatedBy: "?rid=")
            path = parts[0]; responseID = parts.count == 2 ? parts[1] : nil
        }
    }
    let token = UUID().uuidString
    let owner: String
    let generation: UUID
    let path: String
    private(set) var responseID: String?
    private(set) var expanded = false
    private(set) var newChatClaimed = false
    private(set) var reachedRoot = false
    private(set) var verified = false
    private(set) var failed = false
    private(set) var stage: Stage?
    private var loggedReadiness = Set<Readiness>()

    init?(url: String, owner: String, generation: UUID) {
        guard let route = Route(url), UUID(uuidString: owner) != nil else { return nil }
        self.owner = owner; self.generation = generation; path = route.path; responseID = route.responseID
    }

    mutating func reject() { failed = true }
    @discardableResult mutating func observe(_ url: String?) -> Bool {
        guard !failed else { return false }
        if newChatClaimed, url == GrokPrivateModeEvidence.root { reachedRoot = true; return true }
        guard !reachedRoot, let url, let route = Route(url), route.path == path,
              responseID == nil || route.responseID == responseID else { failed = true; return false }
        if let rid = route.responseID { responseID = rid }
        return true
    }

    /// Claims precede dispatch; cancellation or a missing callback cannot reset them.
    mutating func nextAction() -> Action? {
        guard !failed, !verified else { return nil }
        if newChatClaimed { return .verify }
        switch stage {
        case .sidebarClosed:
            guard !expanded else { failed = true; return nil }
            expanded = true; return .expand
        case .newChatReady:
            newChatClaimed = true; return .newChat
        case nil, .pending, .sidebarRequested: return .inspect
        default: failed = true; return nil
        }
    }

    static func failureDiagnostic(error rawError: Any?, detail rawDetail: Any?) -> String {
        let errors: Set<String> = ["composer_not_empty", "composer_unavailable", "document_changed", "model_unverified",
            "not_fresh", "temporary_mode_unverified", "unknown_action"]
        let details: Set<String> = ["fresh_start_grant", "fresh_start_already_bound", "fresh_start_route", "fresh_start_context",
            "fresh_start_editor_ambiguous", "fresh_start_editor_invalid", "fresh_start_sidebar_ambiguous",
            "fresh_start_toggle_invalid", "fresh_start_sidebar_invalid", "fresh_start_new_chat_ambiguous",
            "fresh_start_new_chat_invalid", "fresh_start_root_ambiguous", "fresh_start_unclaimed", "fresh_start_replay",
            "fresh_start_toggle_occluded", "fresh_start_new_chat_occluded", "fresh_start_action_unverified",
            "structure_limit", "document_url", "owner_token"]
        let error = (rawError as? String).flatMap { errors.contains($0) ? $0 : nil } ?? "unknown"
        let detail = rawDetail == nil ? "absent" : (rawDetail as? String).flatMap { details.contains($0) ? $0 : nil } ?? "unknown"
        return "error=\(error) detail=\(detail)"
    }

    static func parse(_ value: [String: Any]) -> Observation? {
        guard Set(value.keys) == ["grokFreshStart"],
              let packet = value["grokFreshStart"] as? [String: Any],
              Set(packet.keys) == (packet["readiness"] == nil ? ["version", "stage"] : ["version", "stage", "readiness"]),
              let version = packet["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let raw = packet["stage"] as? String, let next = Stage(rawValue: raw) else { return nil }
        var readiness: Readiness?
        if let raw = packet["readiness"] {
            guard next == .pending, let fields = raw as? [String: Any], Set(fields.keys) == ["target", "reason"],
                  let target = (fields["target"] as? String).flatMap(Readiness.Target.init(rawValue:)),
                  let reason = (fields["reason"] as? String).flatMap(Readiness.Reason.init(rawValue:)) else { return nil }
            readiness = Readiness(target: target, reason: reason)
        }
        return Observation(stage: next, readiness: readiness)
    }

    mutating func accept(_ value: [String: Any], action: Action) -> Bool {
        guard let stage = Self.parse(value) else { failed = true; return false }
        return accept(stage, action: action)
    }

    mutating func accept(_ observation: Observation, action: Action) -> Bool {
        guard !failed, !verified, observation.readiness == nil || action == .inspect else { failed = true; return false }
        let next = observation.stage
        let valid: Bool
        switch action {
        case .inspect: valid = !newChatClaimed && [.pending, .sidebarClosed, .newChatReady].contains(next) && !(expanded && next == .sidebarClosed)
        case .expand: valid = expanded && !newChatClaimed && next == .sidebarRequested
        case .newChat: valid = newChatClaimed && next == .newChatRequested
        case .verify: valid = newChatClaimed && (next == .pending || next == .rootObserved && reachedRoot)
        }
        guard valid else { failed = true; return false }
        stage = next
        if next == .rootObserved { verified = true }
        return true
    }
    /// At most eight pairs exist; repeated pending reads cannot flood logs.
    mutating func newlyObservedReadiness(_ observation: Observation) -> Readiness? {
        guard !failed, !verified, stage == .pending, let readiness = observation.readiness,
              loggedReadiness.insert(readiness).inserted else { return nil }
        return readiness
    }

}

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

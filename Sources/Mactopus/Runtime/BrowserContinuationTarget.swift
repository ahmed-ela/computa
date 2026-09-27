import Foundation

/// A host-observed routing hint, never an action capability. A continuation
/// must inventory and bind again under the same authorized connection, then
/// take a fresh observation. No tokens, handles, element indices or pixels survive.
struct BrowserContinuationTarget: Equatable, Sendable {
    let connectionID: UUID
    let targetID: String
    let origin: String

    init?(connectionID: UUID, targetID: String, url: URL) {
        guard let origin = Self.origin(url) else { return nil }
        self.connectionID = connectionID
        self.targetID = targetID
        self.origin = origin
    }

    func matches(connectionID: UUID, targetID: String, url: URL) -> Bool {
        self.connectionID == connectionID && self.targetID == targetID
            && Self.origin(url) == origin
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

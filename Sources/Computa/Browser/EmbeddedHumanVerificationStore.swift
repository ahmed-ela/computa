import Foundation

/// A profile-scoped checkpoint remembers only finite provider IDs and random
/// observation IDs. It never stores a website address or any page content.
struct EmbeddedHumanVerificationStore {
    static let providers: Set<String> = ["chatgpt", "claude", "gemini"]
    private static let maximumRecordBytes = 1_024

    let defaults: UserDefaults
    let profileID: UUID

    static func preferenceKey(profileID: UUID) -> String {
        "Computa.EmbeddedBrowser.HumanVerification.v1.\(profileID.uuidString.lowercased())"
    }

    private struct Record: Codable {
        let version: Int
        let checkpoints: [String: UUID]
    }

    func load() -> [String: UUID] {
        guard let data = defaults.data(forKey: Self.preferenceKey(profileID: profileID)),
              data.count <= Self.maximumRecordBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "checkpoints"],
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1,
              Set(record.checkpoints.keys).isSubset(of: Self.providers) else { return [:] }
        return record.checkpoints
    }

    func save(_ checkpoints: [String: UUID]) {
        let finite = checkpoints.filter { Self.providers.contains($0.key) }
        let key = Self.preferenceKey(profileID: profileID)
        guard !finite.isEmpty else { defaults.removeObject(forKey: key); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Record(version: 1, checkpoints: finite)) else { return }
        defaults.set(data, forKey: key)
    }

    /// Native main-frame URLs only. A search query or lookalike origin has no
    /// authority to classify the shared Google profile as challenged.
    static func provider(forTrustedHumanURL url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["google.com", "www.google.com"].contains(url.host?.lowercased() ?? ""),
              url.path == "/sorry" || url.path.hasPrefix("/sorry/") else { return nil }
        return "gemini"
    }
}

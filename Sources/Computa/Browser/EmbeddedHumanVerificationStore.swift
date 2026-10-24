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

    /// A settled human landing page is only a recovery intent. Discovery and
    /// confirmed disposal still supply the authority to clear a checkpoint.
    static func recoveryProvider(forTrustedHumanURL url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.host?.lowercased() == "gemini.google.com",
              url.path.range(of: #"^/(?:u/[0-9]{1,3}/)?app/?$"#, options: .regularExpression) != nil else { return nil }
        return "gemini"
    }

    struct RecoveryReport: Codable, Equatable {
        enum Phase: String, Codable { case requested, probing, verified, blocked, superseded, cancelled }
        enum Reason: String, Codable {
            case healthyHumanDocument = "healthy_human_document"
            case candidateRevoked = "candidate_revoked"
            case taskActive = "task_active"
            case verificationRequired = "verification_required"
            case discoveryFailed = "discovery_failed"
            case cleanupUnconfirmed = "cleanup_unconfirmed"
            case manualRefresh = "manual_refresh"
            case recoveryInProgress = "recovery_in_progress"
            case cancelled
        }
        let checkpointID: UUID
        let recoveryID: UUID
        let phase: Phase
        let reason: Reason
    }

    static func recoveryPreferenceKey(profileID: UUID) -> String {
        "Computa.EmbeddedBrowser.HumanVerificationRecovery.v1.\(profileID.uuidString.lowercased())"
    }

    private struct RecoveryRecord: Codable {
        let version: Int
        let providers: [String: RecoveryReport]
    }

    /// Latest finite diagnostics, separate from the unchanged checkpoint schema.
    /// They are never read by provider admission or checkpoint clearance.
    func loadRecoveryReports() -> [String: RecoveryReport] {
        guard let data = defaults.data(forKey: Self.recoveryPreferenceKey(profileID: profileID)), data.count <= 2_048,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "providers"],
              let rows = object["providers"] as? [String: [String: Any]],
              rows.values.allSatisfy({ Set($0.keys) == ["checkpointID", "recoveryID", "phase", "reason"] }),
              let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data), record.version == 1,
              Set(record.providers.keys).isSubset(of: Self.providers) else { return [:] }
        return record.providers
    }

    func saveRecoveryReports(_ reports: [String: RecoveryReport]) {
        let finite = reports.filter { Self.providers.contains($0.key) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(RecoveryRecord(version: 1, providers: finite)), data.count <= 2_048 else { return }
        defaults.set(data, forKey: Self.recoveryPreferenceKey(profileID: profileID))
    }

}

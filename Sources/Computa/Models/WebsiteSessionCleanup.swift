import Foundation

/// A cleanup observation, never a model response or evidence of a past deletion.
struct WebsiteSessionCleanupReceipt: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case closed, noOwnedSession = "no_owned_session", unconfirmed }
    enum Reason: String, Codable, Sendable {
        case deleted, notCreated = "not_created", noOwnedSession = "no_owned_session", busy
        case shuttingDown = "shutting_down", runtimeChanged = "runtime_changed"
        case cleanupUnverified = "cleanup_unverified", unsupportedRuntime = "unsupported_runtime"
    }
    enum Provider: String, Codable, Sendable { case chatgpt, gemini, claude }
    enum Route: String, Codable, Sendable { case embedded, chrome }
    enum Trigger: String, Codable, Sendable { case automatic, manual, replacement, shutdown }

    let schemaVersion: Int
    let attemptID: String
    let taskID: String
    let threadID: String?
    let turnID: String?
    let runtimeGeneration: String
    let timestamp: String
    let outcome: Outcome
    let provider: Provider?
    let route: Route?
    let modelID: String?
    let reason: Reason
    let trigger: Trigger
    var receiptSaved: Bool

    init(taskID: String, threadID: String? = nil, turnID: String? = nil, runtimeGeneration: UUID, outcome: Outcome, provider: Provider? = nil,
         route: Route? = nil, modelID: String? = nil, reason: Reason, trigger: Trigger, receiptSaved: Bool = false) {
        schemaVersion = 1
        attemptID = UUID().uuidString.lowercased()
        self.taskID = taskID.lowercased()
        self.threadID = threadID?.lowercased(); self.turnID = turnID?.lowercased()
        self.runtimeGeneration = runtimeGeneration.uuidString.lowercased()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp = formatter.string(from: Date())
        self.outcome = outcome; self.provider = provider; self.route = route; self.modelID = modelID
        self.reason = reason; self.trigger = trigger; self.receiptSaved = receiptSaved
    }

    var isValid: Bool {
        guard schemaVersion == 1, UUID(uuidString: attemptID) != nil, UUID(uuidString: taskID) != nil,
              UUID(uuidString: runtimeGeneration) != nil, timestamp.utf8.count <= 32 else { return false }
        guard threadID == nil || UUID(uuidString: threadID!) != nil,
              turnID == nil || (threadID != nil && UUID(uuidString: turnID!) != nil) else { return false }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: timestamp) != nil else { return false }
        if let modelID {
            guard let provider, modelID == "browser/\(provider.rawValue)"
                || WebsiteModelCatalog.choice(for: modelID)?.provider == provider.rawValue else { return false }
        }
        switch outcome {
        case .closed: return provider != nil && route != nil && modelID != nil && [.deleted, .notCreated].contains(reason)
        case .noOwnedSession: return provider == nil && route == nil && modelID == nil && reason == .noOwnedSession
        case .unconfirmed: return ![.deleted, .notCreated, .noOwnedSession].contains(reason)
        }
    }
}

/// Private, bounded, append-only observations using the app's atomic record pattern.
struct WebsiteSessionCleanupStore: Sendable {
    let directory: URL

    func save(_ receipt: WebsiteSessionCleanupReceipt) -> Bool {
        guard receipt.isValid, receipt.receiptSaved else { return false }
        let file = directory.appendingPathComponent(UUID(uuidString: receipt.taskID)!.uuidString.lowercased() + ".jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard !isLink(directory), !isLink(file) else { return false }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let existing = try records(file)
            guard existing.count < 64, !existing.contains(where: { $0.attemptID == receipt.attemptID }) else { return false }
            if existing.isEmpty {
                guard try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count < 256 else { return false }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for item in existing + [receipt] {
                let encoded = try encoder.encode(item)
                guard encoded.count <= 2_048 else { return false }
                data.append(encoded); data.append(0x0A)
            }
            guard data.count <= 65_536 else { return false }
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }

    func latest() -> [WebsiteSessionCleanupReceipt] {
        guard !isLink(directory), let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              files.count <= 256 else { return [] }
        return files.compactMap { file -> WebsiteSessionCleanupReceipt? in
            guard file.pathExtension == "jsonl", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { return nil }
            return try? records(file).last
        }.sorted { ($0.timestamp, $0.attemptID) < ($1.timestamp, $1.attemptID) }
    }

    private func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func records(_ file: URL) throws -> [WebsiteSessionCleanupReceipt] {
        if !FileManager.default.fileExists(atPath: file.path) { return [] }
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard !isLink(file), attributes.isRegularFile == true, (attributes.fileSize ?? 65_537) <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: file)
        guard data.count <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let lines = data.split(separator: 0x0A)
        guard lines.count <= 64 else { throw CocoaError(.fileReadCorruptFile) }
        let allowed: Set<String> = ["schemaVersion", "attemptID", "taskID", "threadID", "turnID", "runtimeGeneration", "timestamp", "outcome", "provider", "route", "modelID", "reason", "trigger", "receiptSaved"]
        var seen = Set<String>()
        return try lines.map { line in
            guard let raw = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], Set(raw.keys).isSubset(of: allowed) else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: Data(line))
            guard value.isValid, value.receiptSaved, UUID(uuidString: value.taskID)?.uuidString.lowercased() == file.deletingPathExtension().lastPathComponent,
                  seen.insert(value.attemptID).inserted else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
    }
}

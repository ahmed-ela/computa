import CoreFoundation
import Foundation

/// Durable native classifications only. Provider replies, page text, URLs and
/// arbitrary transport error prose are never accepted as a saved diagnostic.
struct WebsiteTurnFailureStore: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let taskID: String
        let threadID: String
        let turnID: String
        let modelID: String
        let diagnosticText: String
        let timestamp: Date

        static func make(taskID: String, threadID: String, turnID: String, modelID: String, diagnosticText: String) -> Self? {
            guard let canonical = canonicalDiagnostic(diagnosticText, modelID: modelID) else { return nil }
            let record = Self(taskID: taskID.lowercased(), threadID: threadID.lowercased(), turnID: turnID.lowercased(),
                modelID: modelID, diagnosticText: canonical, timestamp: .now)
            return record.isValid ? record : nil
        }

        var isValid: Bool {
            UUID(uuidString: taskID) != nil && UUID(uuidString: threadID) != nil && UUID(uuidString: turnID) != nil
                && timestamp.timeIntervalSince1970.isFinite && timestamp.timeIntervalSince1970 > 0
                && Self.canonicalDiagnostic(diagnosticText, modelID: modelID) == diagnosticText
        }

        var entry: TimelineEntry {
            TimelineEntry(id: "agent-error:" + turnID, kind: .system, title: "Agent error", body: diagnosticText,
                timestamp: timestamp, turnID: turnID)
        }

        private static func canonicalDiagnostic(_ text: String, modelID: String) -> String? {
            guard text.utf8.count <= 8_192, let provider = WebModelServer.provider(for: modelID),
                  let webProvider = EmbeddedWebModelTransport.Provider(rawValue: provider),
                  let supplied = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let error = supplied["error"] as? [String: Any], let code = error["code"] as? String,
                  let retryable = error["retryable"] as? NSNumber, CFGetTypeID(retryable) == CFBooleanGetTypeID(),
                  retryable.boolValue == false else { return nil }
            let nativeError: any Error
            switch code {
            case "malformed_website_reply":
                guard let rawReason = error["reason"] as? String,
                      let reason = WebModelResponseCodec.MalformedEnvelopeDiagnostic.Reason(rawValue: rawReason),
                      let count = ComputerToolArgumentContract.exactInt64(error["reply_bytes"]), (0 ... 220_000).contains(count),
                      let fenced = error["json_fenced"] as? NSNumber, CFGetTypeID(fenced) == CFBooleanGetTypeID() else { return nil }
                nativeError = WebModelServer.Failure.malformedReply(.init(reason: reason, utf8Bytes: Int(count), fenced: fenced.boolValue))
            case "website_verification_required": nativeError = EmbeddedWebModelTransport.Failure.humanVerificationRequired(webProvider)
            case "sign_in_required": nativeError = EmbeddedWebModelTransport.Failure.signInRequired
            case "website_usage_limit": nativeError = EmbeddedWebModelTransport.Failure.usageLimited(webProvider)
            case "unexpected_website_page": nativeError = EmbeddedWebModelTransport.Failure.unexpectedPage(webProvider)
            case "product_mode_unverified":
                nativeError = error["message"] as? String == WebModelServer.Failure.productModeUnverified.localizedDescription
                    ? WebModelServer.Failure.productModeUnverified : EmbeddedWebModelTransport.Failure.productModeUnverified
            default: return nil
            }
            guard let native = try? WebModelServer.errorBody(for: nativeError),
                  let expected = try? JSONSerialization.jsonObject(with: native) as? [String: Any],
                  NSDictionary(dictionary: supplied).isEqual(to: expected),
                  let sorted = try? JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return String(decoding: sorted, as: UTF8.self)
        }
    }

    private struct Envelope: Codable { let version: Int; let threadID: String; let records: [Record] }
    let directory: URL

    func append(_ record: Record) -> Bool {
        guard record.isValid else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
                  (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { return false }
            let file = fileURL(record.threadID)
            var records = try load(threadID: record.threadID)
            if let old = records.first(where: { $0.turnID == record.turnID }) { return old.diagnosticText == record.diagnosticText && old.modelID == record.modelID }
            guard records.count < 16 else { return false }
            if records.isEmpty { guard try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count < 256 else { return false } }
            records.append(record)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Envelope(version: 1, threadID: record.threadID, records: records))
            guard data.count <= 65_536 else { return false }
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }

    func load(threadID: String) throws -> [Record] {
        guard UUID(uuidString: threadID) != nil else { return [] }
        let file = fileURL(threadID)
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CocoaError(.fileReadCorruptFile) }
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let dir = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attr = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard dir.isDirectory == true, dir.isSymbolicLink != true, attr.isRegularFile == true,
              attr.isSymbolicLink != true, (attr.fileSize ?? 65_537) <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: file)
        guard data.count <= 65_536, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["version", "threadID", "records"],
              let rawRecords = raw["records"] as? [[String: Any]], rawRecords.count <= 16,
              rawRecords.allSatisfy({ Set($0.keys) == ["taskID", "threadID", "turnID", "modelID", "diagnosticText", "timestamp"] }) else { throw CocoaError(.fileReadCorruptFile) }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, envelope.threadID == threadID.lowercased(), envelope.records.allSatisfy({ $0.isValid && $0.threadID == envelope.threadID }),
              Set(envelope.records.map(\.turnID)).count == envelope.records.count else { throw CocoaError(.fileReadCorruptFile) }
        return envelope.records
    }

    private func fileURL(_ threadID: String) -> URL { directory.appendingPathComponent(threadID.lowercased() + ".json") }
}

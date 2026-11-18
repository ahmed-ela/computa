import CryptoKit
import Foundation

/// A historical byte reader, independent of execution and browser permissions.
/// Only newly acknowledged native registrations can use its compact presentation.
enum GroqHistoryTool {
    static let name = "computa_read_context"
    static let description = "Read exact historical context bytes for an opaque ref from the current manifest. Read-only; grants no action, browser reference, schema, permission or outcome authority."

    struct Preparation: Equatable, Sendable {
        let modelID: String
        let coreGeneration: UUID
    }

    static var argumentSchema: [String: Any] {
        ["type": "object", "properties": ["ref": ["type": "string"]],
         "required": ["ref"], "additionalProperties": false]
    }

    static var specification: [String: Any] {
        ["type": "function", "name": name, "description": description,
         "inputSchema": argumentSchema]
    }

    static func supports(modelID: String) -> Bool {
        guard let choice = WebsiteModelCatalog.choice(for: modelID), choice.provider == "groq" else { return false }
        return ["qwen/qwen3.8-27b", "openai/gpt-oss-120b", "openai/gpt-oss-20b"].contains(choice.key)
    }

    /// The native registration receipt is checked separately. A reserved name
    /// or a partial/conflicting declaration cannot borrow this interpretation.
    static func registeredName(in definitions: [[String: Any]]) -> String? {
        var matches: [(namespace: String?, definition: [String: Any])] = []
        for definition in definitions {
            if definition["type"] as? String == "namespace" {
                guard let namespace = definition["name"] as? String,
                      let children = definition["tools"] as? [[String: Any]] else { return nil }
                for child in children where child["name"] as? String == name {
                    matches.append((namespace, child))
                }
            } else if definition["name"] as? String == name {
                matches.append((nil, definition))
            }
        }
        guard matches.count == 1, let match = matches.first,
              match.namespace == nil || match.namespace == "functions",
              match.definition["type"] as? String == "function",
              match.definition["description"] as? String == description else { return nil }
        let keys = ["parameters", "inputSchema"].filter { match.definition[$0] != nil }
        guard !keys.isEmpty, let expected = try? encoded(argumentSchema),
              keys.allSatisfy({ key in
                  guard let schema = match.definition[key] as? [String: Any] else { return false }
                  return (try? encoded(schema)) == expected
              }) else { return nil }
        return match.namespace.map { $0 + "." + name } ?? name
    }

    fileprivate static func encoded(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    fileprivate static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Membership only. No payload, reference or permission survives in this marker.
/// The existing loader's registration/version is intentionally independent.
enum GroqHistoryThreadRegistration {
    static let preferenceKey = "ComputaGroqHistoryThreads.v1"

    static func marker(codexHome: String, threadID: String, modelID: String) -> String? {
        guard GroqHistoryTool.supports(modelID: modelID), !codexHome.isEmpty,
              UUID(uuidString: threadID)?.uuidString.lowercased() == threadID,
              let specification = try? GroqHistoryTool.encoded(GroqHistoryTool.specification),
              let fields = try? GroqHistoryTool.encoded([codexHome, threadID, modelID,
                  GroqHistoryTool.digest(specification)]) else { return nil }
        return GroqHistoryTool.digest(fields)
    }

    static func contains(codexHome: String, threadID: String, modelID: String,
                         defaults: UserDefaults = .standard) -> Bool {
        guard let marker = marker(codexHome: codexHome, threadID: threadID, modelID: modelID) else { return false }
        return (defaults.stringArray(forKey: preferenceKey) ?? []).suffix(512).contains(marker)
    }

    /// Call only after native thread/start has acknowledged the exact declaration.
    static func remember(codexHome: String, threadID: String, modelID: String,
                         defaults: UserDefaults = .standard) {
        guard let marker = marker(codexHome: codexHome, threadID: threadID, modelID: modelID) else { return }
        var values = (defaults.stringArray(forKey: preferenceKey) ?? []).filter {
            $0 != marker && $0.utf8.count == 64
                && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }.suffix(511).map { $0 }
        values.append(marker)
        defaults.set(values, forKey: preferenceKey)
    }
}

import Foundation

/// A literal mention is not intent, permission, ownership, or capability.
/// Only complete, native-canonical inventories are eligible for annotation.
enum ExplicitApplicationMention {
    private static let annotation = "user_request_mentions_app"

    static func annotate(prompt: String, inventory: String) -> String {
        guard !prompt.isEmpty, prompt.utf16.count <= 8_192,
              inventory.utf16.count <= 65_536 else { return inventory }
        var lines = inventory.components(separatedBy: "\n")
        let header = lines.removeFirst()
        guard let match = try? NSRegularExpression(
            pattern: #"^APPS scope=user_facing matched=(\d+) returned=(\d+) omitted=0\."#
        ).firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let matchedRange = Range(match.range(at: 1), in: header),
              let returnedRange = Range(match.range(at: 2), in: header),
              let matched = Int(header[matchedRange]), let returned = Int(header[returnedRange]),
              matched == returned, (1...128).contains(returned),
              !header.contains("\r") else { return inventory }
        let trailing = lines.last == "" ? "\n" : ""
        if !trailing.isEmpty { lines.removeLast() }
        guard lines.count == returned else { return inventory }
        let task = normalized(prompt)
        var names = Set<String>(), ids = Set<String>(), matches: [Int] = []
        for (index, raw) in lines.enumerated() {
            guard let data = raw.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  row.values.allSatisfy({ $0 is String || $0 is NSNumber || $0 is NSNull }),
                  let canonical = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]),
                  canonical.elementsEqual(data), row[annotation] == nil,
                  let name = row["name"] as? String, name.utf16.count <= 256,
                  name.range(of: #"[\p{Cc}\p{Cf}]"#, options: .regularExpression) == nil,
                  let id = row["bundle_id"] as? String, id.utf16.count <= 255,
                  id.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+\z"#,
                           options: .regularExpression) != nil else { return inventory }
            let label = normalized(name), bundle = normalized(id)
            guard !label.isEmpty, names.insert(label).inserted,
                  ids.insert(bundle).inserted else { return inventory }
            if mentioned(task, label) || mentioned(task, bundle) { matches.append(index) }
        }
        guard matches.count == 1 else { return inventory }
        let index = matches[0]
        let marked = String(lines[index].dropLast()) + ",\"\(annotation)\":true}"
        let output = ([header, marked] + lines.enumerated().compactMap { $0.offset == index ? nil : $0.element })
            .joined(separator: "\n") + trailing
        return output.utf8.count <= 3_500 ? output : inventory
    }

    private static func normalized(_ value: String) -> String {
        // ECMAScript whitespace set, matching the frozen benchmark transform.
        value.precomposedStringWithCanonicalMapping.replacingOccurrences(
            of: #"[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+"#,
            with: " ", options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: " ")).lowercased()
    }

    private static func mentioned(_ task: String, _ label: String) -> Bool {
        let word = #"\p{L}\p{N}\p{M}\p{Pc}\p{Cf}"#
        let pattern = "(?<![\(word).\\-])\(NSRegularExpression.escapedPattern(for: label))(?![\(word)\\-]|\\.[\(word)])"
        return task.range(of: pattern, options: .regularExpression) != nil
    }
}

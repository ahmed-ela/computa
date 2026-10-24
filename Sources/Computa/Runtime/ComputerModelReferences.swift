import AutomationCore
import Foundation

/// Ephemeral addresses for the exact rows published to this model turn. This
/// adapter grants no input authority: canonical calls still pass every existing
/// scope, freshness, capability, approval and postcondition check.
struct ComputerModelReferences {
    private static let presentationKey = "_hostSemanticReadPresentation"

    enum ReferenceError: Error, LocalizedError {
        case invalidReference
        case invalidPresentation

        var errorDescription: String? {
            switch self {
            case .invalidReference:
                "Reference unavailable, stale, or the wrong type. No input was sent. Use computer_v2_read_page for fresh references; copy the reference for the intended operation exactly."
            case .invalidPresentation:
                "The host could not publish an unambiguous reference menu. No references were issued."
            }
        }
    }

    struct Resolved {
        let tool: String
        let arguments: [String: Any]
    }

    struct Prepared {
        let contentItems: [[String: Any]]
        let references: ComputerModelReferences
    }

    private enum Capability: Equatable {
        case action(String), field, region
    }

    private struct Entry {
        let index: Int
        let capability: Capability
    }

    private var scope: String?
    private var snapshotID: UUID?
    private var entries: [String: Entry] = [:]

    static func attach(item: [String: Any], presentation: SemanticReadPresentation?) -> [String: Any] {
        guard let presentation else { return item }
        var result = item
        result[presentationKey] = presentation
        return result
    }

    /// Prepare a copy. The caller commits it only after the text response is
    /// enqueued. Captures inside a verifier are not model-visible references.
    func prepare(items: [[String: Any]], scope: String) throws -> Prepared {
        var next = self
        var output: [[String: Any]] = []
        for var item in items {
            let presentation = item.removeValue(forKey: Self.presentationKey) as? SemanticReadPresentation
            if let presentation, item["type"] as? String == "inputText",
               let text = item["text"] as? String {
                item["text"] = try next.publish(presentation, in: text, scope: scope)
            }
            output.append(item)
        }
        return Prepared(contentItems: output, references: next)
    }

    func resolve(tool: String, arguments: [String: Any], scope: String,
                 currentSnapshotID: UUID?) throws -> Resolved {
        let call = try ComputerV2ToolContract.validateAlias(tool: tool, arguments: arguments)
        if call.tool == .readPage {
            return Resolved(tool: ComputerV2ToolContract.Tool.snapshot.rawValue, arguments: arguments)
        }
        guard self.scope == scope, let snapshotID, snapshotID == currentSnapshotID else {
            throw ReferenceError.invalidReference
        }
        func entry(_ key: String, capability: Capability? = nil) throws -> Entry {
            guard let token = arguments[key] as? String, let entry = entries[token],
                  capability == nil || entry.capability == capability else {
                throw ReferenceError.invalidReference
            }
            return entry
        }
        var canonical: [String: Any] = ["snapshot_id": snapshotID.uuidString]
        switch call.tool {
        case .readPage:
            preconditionFailure("Handled above")
        case .readRegion:
            canonical["element_index"] = try entry("region_ref", capability: .region).index
            canonical["view"] = arguments["view"]
            canonical["query"] = arguments["query"]
            return Resolved(tool: ComputerV2ToolContract.Tool.snapshot.rawValue, arguments: canonical)
        case .fill:
            canonical["element_index"] = try entry("field_ref", capability: .field).index
            canonical["text"] = arguments["text"]
            return Resolved(tool: ComputerV2ToolContract.Tool.setText.rawValue, arguments: canonical)
        case .press:
            let target = try entry("action_ref")
            guard case .action(let action) = target.capability else { throw ReferenceError.invalidReference }
            canonical["element_index"] = target.index
            canonical["ax_action"] = action
            if var postcondition = arguments["postcondition"] as? [String: Any] {
                for (refKey, indexKey) in [("region_ref", "element_index"), ("detail_ref", "detail_element_index")] {
                    if let token = postcondition.removeValue(forKey: refKey) as? String {
                        guard let result = entries[token], result.capability == .region else {
                            throw ReferenceError.invalidReference
                        }
                        postcondition[indexKey] = result.index
                    }
                }
                canonical["postcondition"] = postcondition
            }
            return Resolved(tool: ComputerV2ToolContract.Tool.ax.rawValue, arguments: canonical)
        }
    }

    private mutating func mint(_ capability: Capability, index: Int, prefix: String) -> String {
        var token: String
        repeat { token = prefix + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() }
        while entries[token] != nil
        entries[token] = Entry(index: index, capability: capability)
        return token
    }

    private mutating func publish(_ presentation: SemanticReadPresentation, in text: String,
                                  scope: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        let counts = Dictionary(grouping: lines, by: { $0 }).mapValues(\.count)
        let rows = presentation.rows
        guard Set(rows.map(\.index)).count == rows.count,
              Set(rows.map(\.text)).count == rows.count,
              rows.allSatisfy({ $0.index >= 0 && counts[$0.text] == 1 && $0.text.hasPrefix("#\($0.index) ") }) else {
            throw ReferenceError.invalidPresentation
        }
        self.scope = scope
        snapshotID = presentation.snapshotID
        entries.removeAll(keepingCapacity: true)
        let rowTexts = Set(rows.map(\.text))
        var regionsByIndex: [Int: String] = [:]
        for row in rows where row.region {
            regionsByIndex[row.index] = mint(.region, index: row.index, prefix: "r")
        }
        var controls: [String] = [], regions: [String] = []
        for row in rows {
            var addresses: [String] = []
            if row.settable {
                addresses.append("field_ref=\(mint(.field, index: row.index, prefix: "f"))")
            }
            for action in row.actions {
                let token = mint(.action(action), index: row.index, prefix: "a")
                addresses.append(row.actions.count == 1 ? "action_ref=\(token)" : "\(action)_ref=\(token)")
            }
            let hasControl = !addresses.isEmpty
            if let region = regionsByIndex[row.index] { addresses.append("region_ref=\(region)") }
            if let parent = row.parentIndex, parent != row.index, let reference = regionsByIndex[parent] {
                addresses.append("parent_ref=\(reference)")
            }
            if row.regionChanged { addresses.append("region_changed_candidate=true") }
            let content = Self.withoutLegacyAddresses(row.text)
            let rendered = (addresses + [content]).joined(separator: " ")
            if hasControl { controls.append(rendered) } else { regions.append(rendered) }
        }
        // Only host-owned standalone guidance is replaced. Page strings occur
        // inside the exact quoted row fields and are never interpreted here.
        let obsoletePrefixes = ["OVERVIEW ", "region_changed_candidate marks", "Continue with cursor only"]
        var header: [String] = []
        var footer: [String] = []
        var passedRows = false
        for line in lines {
            if rowTexts.contains(line) { passedRows = true; continue }
            if obsoletePrefixes.contains(where: line.hasPrefix) { continue }
            let retained = line.hasPrefix("AXSNAPSHOT ")
                ? Self.withoutLegacyHeaderAncestry(line) : line
            if passedRows { footer.append(retained) } else { header.append(retained) }
        }
        header.append("REFERENCES current_page_only=true. Each new read or action result replaces these references; copy the token for the intended tool.")
        if !controls.isEmpty { header += ["CONTROLS (fill field_ref; press action_ref)"] + controls }
        if !regions.isEmpty { header += ["READABLE CONTEXT (region_ref reads a subtree; it cannot be pressed)"] + regions }
        header.append("Use read_page for a fresh view; read_region for a region_ref; continue with next_cursor. Read document content before making content claims.")
        let result = (header + footer).joined(separator: "\n")
        guard result.utf8.count <= presentation.maximumOutputBytes else { throw ReferenceError.invalidPresentation }
        return result
    }

    /// Split only host field boundaries, respecting quoted/escaped page text.
    /// No field value is decoded, regenerated, expanded, or searched for commands.
    private static func withoutLegacyAddresses(_ line: String) -> String {
        let obsolete = ["parent", "parent_index", "actions", "settable", "follow_link", "region_changed_candidate", "ancestors"]
        return tokens(line).dropFirst().filter { token in
            !obsolete.contains(String(token.prefix(while: { $0 != "=" })))
        }.map { token in
            if token.hasPrefix("sibling_heading=#"), let separator = token.firstIndex(of: ":") {
                return "sibling_heading=" + token[token.index(after: separator)...]
            }
            return token
        }.joined(separator: " ")
    }

    private static func withoutLegacyHeaderAncestry(_ line: String) -> String {
        tokens(line).filter { token in
            !["root", "parents"].contains(String(token.prefix(while: { $0 != "=" })))
        }.joined(separator: " ")
    }

    private static func tokens(_ line: String) -> [String] {
        var tokens: [String] = [], token = "", quoted = false, escaped = false
        for character in line {
            if character == " " && !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
                continue
            }
            token.append(character)
            if escaped { escaped = false }
            else if character == "\\" && quoted { escaped = true }
            else if character == "\"" { quoted.toggle() }
        }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }
}

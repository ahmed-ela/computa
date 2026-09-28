import CoreFoundation
import Foundation

/// Browser observations only, never model-authored selectors or JavaScript.
/// A pointer-shaped, focusable node is an activation candidate (delegated
/// listeners need not appear in isClickable), not evidence of task success.
struct BrowserDOMActionProjection {
    static let styles = ["cursor", "visibility", "display", "pointer-events"]
    let clickable: Set<Int64>
    let pointer: Set<Int64>
    let truncated: Bool
    let emptyTextValues: Set<Int64>
    init(clickable: Set<Int64>, pointer: Set<Int64>, truncated: Bool, emptyTextValues: Set<Int64> = []) {
        self.clickable = clickable
        self.pointer = pointer
        self.truncated = truncated
        self.emptyTextValues = emptyTextValues
    }
    static let unavailable = Self(clickable: [], pointer: [], truncated: false)

    static func parse(_ result: [String: Any], frameID: String, url: URL) throws -> Self {
        func malformed() -> BrowserTabBrokerError {
            .malformedDevToolsResponse("invalid bounded browser action evidence")
        }
        func integer(_ value: Any?, maximum: Int64 = 9_007_199_254_740_991) throws -> Int64 {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= 0, number.doubleValue <= Double(maximum) else { throw malformed() }
            return number.int64Value
        }
        func ids(_ value: Any?, maximum: Int) throws -> Set<Int64> {
            guard let values = value as? [Any], values.count <= maximum else { throw malformed() }
            var result = Set<Int64>()
            for value in values {
                let id = try integer(value)
                guard id > 0, result.insert(id).inserted else { throw malformed() }
            }
            return result
        }
        if let projected = result["mactopusClickability"] as? [String: Any] {
            guard projected["frameId"] as? String == frameID,
                  projected["documentURL"] as? String == url.absoluteString,
                  let truncated = projected["sourceTruncated"] as? NSNumber,
                  CFGetTypeID(truncated) == CFBooleanGetTypeID() else { throw malformed() }
            let count = try integer(projected["sourceNodeCount"], maximum: 100_000)
            let clickable = try ids(projected["clickableBackendNodeIds"], maximum: 12_000)
            let pointer = try ids(projected["pointerBackendNodeIds"], maximum: 12_000)
            let empty = try projected["emptyTextValueBackendNodeIds"].map { try ids($0, maximum: 12_000) } ?? []
            guard clickable.union(pointer).union(empty).count <= count else { throw malformed() }
            return Self(clickable: clickable, pointer: pointer, truncated: truncated.boolValue, emptyTextValues: empty)
        }
        // Raw CDP is used by the owned/DevTools transports. The extension sends
        // the same minimal evidence after stripping DOM text/attributes/layout.
        guard let strings = result["strings"] as? [String],
              let documents = result["documents"] as? [[String: Any]],
              !documents.isEmpty, documents.count <= 256 else { throw malformed() }
        func string(_ index: Any?) throws -> String {
            let i = try integer(index)
            guard i < strings.count else { throw malformed() }
            return strings[Int(i)]
        }
        let matches = try documents.filter { try string($0["frameId"]) == frameID }
        guard matches.count == 1, let document = matches.first,
              try string(document["documentURL"]) == url.absoluteString,
              let nodes = document["nodes"] as? [String: Any],
              let backend = nodes["backendNodeId"] as? [Any], backend.count <= 100_000 else { throw malformed() }
        _ = try ids(backend, maximum: 100_000)
        let backendIDs = try backend.map { try integer($0) }
        func nodeIndices(_ values: Any?, unique: Bool = true) throws -> [Int] {
            guard let values = values as? [Any], values.count <= 100_000 else { throw malformed() }
            var seen = Set<Int>()
            return try values.map {
                let index = try integer($0)
                guard index < backend.count else { throw malformed() }
                if unique && !seen.insert(Int(index)).inserted { throw malformed() }
                return Int(index)
            }
        }
        // Chromium SetRare records native input/textarea values explicitly;
        // AddString encodes the observed empty string as -1. An absent rare
        // entry is unknown. Never forward nonempty DOM values or password data.
        // https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/core/inspector/inspector_dom_snapshot_agent.cc
        func signedIndex(_ value: Any?) throws -> Int64 {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == -1 { return -1 }
            return try integer(value)
        }
        func possiblyEmptyString(_ value: Any?) throws -> String {
            try signedIndex(value) == -1 ? "" : string(value)
        }
        var emptyTextValues = Set<Int64>()
        var valueIndices = Set<Int>()
        for (field, tag) in [("inputValue", "INPUT"), ("textValue", "TEXTAREA")] {
            guard let raw = nodes[field] else { continue }
            guard let rare = raw as? [String: Any], Set(rare.keys) == ["index", "value"],
                  let values = rare["value"] as? [Any] else { throw malformed() }
            let indices = try nodeIndices(rare["index"])
            guard indices.count == values.count else { throw malformed() }
            for (offset, index) in indices.enumerated() {
                guard valueIndices.insert(index).inserted else { throw malformed() }
                let value = try possiblyEmptyString(values[offset])
                guard let names = nodes["nodeName"] as? [Any], names.count == backend.count,
                      let types = nodes["nodeType"] as? [Any], types.count == backend.count,
                      let attributes = nodes["attributes"] as? [[Any]], attributes.count == backend.count,
                      let parents = nodes["parentIndex"] as? [Any], parents.count == backend.count,
                      try integer(types[index]) == 1, try string(names[index]) == tag else { throw malformed() }
                guard value.isEmpty else { continue }
                var current = index
                var visited = Set<Int>()
                var allowed = true
                while current >= 0 {
                    guard visited.insert(current).inserted else { throw malformed() }
                    guard visited.count <= 128 else { allowed = false; break }
                    let rawAttributes = attributes[current]
                    guard rawAttributes.count.isMultiple(of: 2), rawAttributes.count <= 4_096 else { throw malformed() }
                    var attrs: [String: String] = [:]
                    for position in stride(from: 0, to: rawAttributes.count, by: 2) {
                        let key = try string(rawAttributes[position]).lowercased()
                        guard !key.isEmpty, attrs[key] == nil else { throw malformed() }
                        attrs[key] = try possiblyEmptyString(rawAttributes[position + 1])
                    }
                    if attrs["disabled"] != nil || attrs["readonly"] != nil || attrs["inert"] != nil
                        || attrs["aria-disabled"]?.lowercased() == "true" || attrs["aria-readonly"]?.lowercased() == "true" {
                        allowed = false
                    }
                    if current == index, tag == "INPUT",
                       !["", "text", "search", "email", "url", "tel"].contains((attrs["type"] ?? "text").lowercased()) {
                        allowed = false
                    }
                    let parent = try signedIndex(parents[current])
                    guard parent < backend.count else { throw malformed() }
                    current = Int(parent)
                }
                if allowed { emptyTextValues.insert(backendIDs[index]) }
            }
        }
        let clickableIndices: [Int]
        if let rare = nodes["isClickable"] {
            guard let rare = rare as? [String: Any], Set(rare.keys) == ["index"] else { throw malformed() }
            clickableIndices = try nodeIndices(rare["index"])
        } else { clickableIndices = [] }
        guard let layout = document["layout"] as? [String: Any],
              let styles = layout["styles"] as? [[Any]],
              let bounds = layout["bounds"] as? [[Any]] else { throw malformed() }
        // Multiple layout fragments may share a DOM node; empty computed style
        // arrays are normal for text boxes. Neither grants activation evidence.
        let indices = try nodeIndices(layout["nodeIndex"], unique: false)
        guard styles.count == indices.count, bounds.count == indices.count else { throw malformed() }
        var pointer = Set<Int64>()
        for (offset, index) in indices.enumerated() {
            guard (styles[offset].isEmpty || styles[offset].count == Self.styles.count),
                  bounds[offset].count == 4 else { throw malformed() }
            let style = try styles[offset].map(string)
            let rectangle = try bounds[offset].map { value -> Double in
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite else { throw malformed() }
                return n.doubleValue
            }
            guard rectangle[2] >= 0, rectangle[3] >= 0 else { throw malformed() }
            if style.count == Self.styles.count,
               style[0] == "pointer", style[1] == "visible", !style[2].isEmpty, !style[3].isEmpty,
               style[2] != "none", style[3] != "none",
               rectangle[2] > 0, rectangle[3] > 0 {
                pointer.insert(backendIDs[index])
            }
        }
        let clickable = Set(clickableIndices.map { backendIDs[$0] })
        return Self(clickable: Set(clickable.sorted().prefix(12_000)),
                    pointer: Set(pointer.sorted().prefix(12_000)),
                    truncated: clickable.count > 12_000 || pointer.count > 12_000 || emptyTextValues.count > 12_000,
                    emptyTextValues: Set(emptyTextValues.sorted().prefix(12_000)))
    }
}

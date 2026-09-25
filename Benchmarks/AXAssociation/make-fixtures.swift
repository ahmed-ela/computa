import AutomationCore
import Foundation

// Synthetic observations only: this executable never reads or controls the desktop.
func snapshot(nested: Bool, firstStatus: String, secondStatus: String) throws -> AccessibilityTreeSnapshot {
    var nodes: [[String: Any]] = []
    func add(_ parent: Int?, _ role: String, title: String? = nil, value: String? = nil) -> Int {
        let index = nodes.count
        var node: [String: Any] = ["index": index, "childIndices": [Int](), "depth": parent.map { (nodes[$0]["depth"] as! Int) + 1 } ?? 0,
            "role": role, "supportedActions": role == "AXButton" ? ["AXPress"] : [], "isValueSettable": false]
        if let parent {
            node["parentIndex"] = parent
            var children = nodes[parent]["childIndices"] as! [Int]
            children.append(index)
            nodes[parent]["childIndices"] = children
        }
        if let title { node["title"] = title }
        if let value { node["value"] = value }
        nodes.append(node)
        return index
    }
    let window = add(nil, "AXWindow", title: "Synthetic orders")
    let document = add(window, "AXWebArea", title: "Orders")
    for (label, status, titleBacked) in [("Order A", firstStatus, false), ("Order B", secondStatus, true)] {
        let card = add(document, "AXGroup")
        _ = add(card, "AXHeading", title: label)
        let statusParent = nested ? add(card, "AXGroup") : card
        _ = add(statusParent, "AXStaticText", title: titleBacked ? status : nil, value: titleBacked ? nil : status)
        _ = add(card, "AXButton", title: "Details")
    }
    let raw: [String: Any] = ["id": "11111111-1111-4111-8111-111111111111",
        "application": ["processIdentifier": 4242, "bundleIdentifier": "example.synthetic", "applicationName": "Synthetic"],
        "limits": ["maxDepth": 16, "maxElements": 240, "maxChildrenPerElement": 80, "maxActionsPerElement": 12, "maxTextLength": 4096],
        "rootIndex": window, "elements": nodes, "wasTruncated": false]
    return try JSONDecoder().decode(AccessibilityTreeSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
}

var fixtures: [[String: Any]] = []
for nested in [false, true] {
    for reversed in [false, true] {
        let first = reversed ? "Delivered Friday" : "Arrives Tuesday"
        let second = reversed ? "Arrives Tuesday" : "Delivered Friday"
        let source = try snapshot(nested: nested, firstStatus: first, secondStatus: second)
        let targetStatus = source.elements.first { $0.role == "AXStaticText" && $0.value == first }!
        for limited in [false, true] {
            let formatted = AccessibilitySnapshotTextFormatter(elementLimit: limited ? 6 : 240,
                fieldCharacterLimit: 72, outputCharacterLimit: 3000, prioritizesRelevantElements: true,
                usesCompactElementLines: true, prioritizesFocusedDocument: true).format(source)
            // A small budget is not proof that the target fact was omitted.
            // Ranking changes can make a formerly missing value visible.
            let targetLine = formatted.split(separator: "\n").first { $0.hasPrefix("#\(targetStatus.index) ") }
            let targetObserved = targetLine?.contains("value=\"\(first)\"") == true
            precondition(limited || targetObserved, "The full fixture must expose its requested status")
            let ablated = formatted.replacingOccurrences(of: #" parents=\[[^\]]*\]| parent=(?:[0-9]+|-)(?: ancestry_(?:unknown|truncated)=1)?| sibling_heading=#[0-9]+:"(?:[^"\\]|\\.)*""#,
                with: "", options: .regularExpression)
            precondition(formatted != ablated, "Build the parent-map-aware AutomationCore library before generating fixtures")
            precondition(!ablated.contains(" sibling_heading="), "Ablation must remove observed sibling-heading context too")
            for (variant, observation) in [("ancestry", formatted), ("without_ancestry", ablated)] {
                fixtures.append(["id": "\(nested ? "nested" : "flat")-\(reversed ? "reversed" : "normal")-\(limited ? "limited" : "full")-\(variant)",
                    "variant": variant, "expected": targetObserved ? first : "UNOBSERVED",
                    "targetObserved": targetObserved, "observation": observation])
            }
        }
    }
}
let data = try JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)

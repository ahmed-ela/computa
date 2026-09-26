import AutomationCore
import Foundation
import XCTest
@testable import HeyDash

final class ExplicitApplicationMentionTests: XCTestCase {
    private func row(_ name: String = "Cedar Desk", _ id: String = "test.cedar.desk", extra: [String: Any] = [:]) -> String {
        var value: [String: Any] = ["active": false, "bundle_id": id, "name": name, "pid": 42]
        value.merge(extra) { _, new in new }
        return String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
    }
    private func inventory(_ rows: [String]) -> String {
        "APPS scope=user_facing matched=\(rows.count) returned=\(rows.count) omitted=0. Native inventory.\n" + rows.joined(separator: "\n")
    }
    private func assertUnchanged(_ prompt: String, _ input: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ExplicitApplicationMention.annotate(prompt: prompt, inventory: input), input, file: file, line: line)
    }

    func testNativeInventoryMovesMentionedRowOnlyAndPreservesHeader() {
        let apps = [(1, "Amber Pad", "test.amber.pad"), (2, "Cedar Desk", "test.cedar.desk")].map {
            RunningApplicationInfo(processIdentifier: Int32($0.0), bundleIdentifier: $0.2, localizedName: $0.1,
                activationPolicy: .regular, isActive: false, isHidden: false, isTerminated: false)
        }
        let input = ComputerV2ToolContract.appInventory(apps, query: nil)
        let before = input.components(separatedBy: "\n")
        let output = ExplicitApplicationMention.annotate(prompt: "Inspect Cedar Desk.", inventory: input)
        XCTAssertEqual(output.components(separatedBy: "\n"), [before[0], String(before[2].dropLast()) + ",\"user_request_mentions_app\":true}", before[1]])
        assertUnchanged("Inspect Cedar Desk.", output)
    }

    func testNormalizationBundleMentionNegationAndTrailingNewline() {
        let input = inventory([row("Cafe\u{301} Desk")]) + "\n"
        for prompt in ["Read CAFÉ\u{00A0}  DESK.", "Do not open test.cedar.desk."] {
            let output = ExplicitApplicationMention.annotate(prompt: prompt, inventory: input)
            XCTAssertTrue(output.contains("\"user_request_mentions_app\":true"))
            XCTAssertTrue(output.hasSuffix("}\n"))
        }
    }

    func testWholeNameAndIdentifierBoundaries() {
        let input = inventory([row()])
        for prompt in ["Cedar Desktops", "xCedar Desk", "Cedar Desk-x", "Cedar Desk.extra", "Cedar Desk_2", "Cedar Desk\u{200D}", "test.cedar.desk.more", "x.test.cedar.desk", "test.cedar.desk-2"] {
            assertUnchanged(prompt, input)
        }
        for prompt in ["(Cedar Desk)", "Use test.cedar.desk."] {
            XCTAssertNotEqual(ExplicitApplicationMention.annotate(prompt: prompt, inventory: input), input)
        }
    }

    func testAmbiguousDuplicateAndInvalidRowsAbstain() {
        assertUnchanged("Cedar Desk and Amber Pad", inventory([row(), row("Amber Pad", "test.amber.pad")]))
        for rows in [[row(), row("CEDAR DESK", "test.other.app")], [row(), row("Other", "TEST.CEDAR.DESK")],
                     [row("Bad\nName")], [row("Bad\u{200D}Name")], [row("", "test.empty.name")],
                     [row("Cedar Desk", "not a bundle")], [row("Cedar Desk", "test.cedar.desk\n")],
                     [row(extra: ["nested": ["a": true]])],
                     [row(extra: ["user_request_mentions_app": false])]] {
            assertUnchanged("Cedar Desk", inventory(rows))
        }
        let duplicate = row().replacingOccurrences(of: "\"name\":", with: "\"name\":\"Other\",\"name\":")
        let escapedDuplicate = row().replacingOccurrences(of: "\"name\":", with: "\"\\u006eame\":\"Other\",\"name\":")
        for raw in [duplicate, escapedDuplicate, " " + row(), row().replacingOccurrences(of: ":", with: ": "), "{broken}"] {
            assertUnchanged("Cedar Desk", inventory([raw]))
        }
    }

    func testIncompleteFilteredMalformedInventoriesAndPromptBoundsAbstain() {
        let input = inventory([row()])
        for altered in [input.replacingOccurrences(of: "user_facing", with: "all_matching_running_apps"),
                        input.replacingOccurrences(of: "omitted=0", with: "omitted=1"),
                        input.replacingOccurrences(of: "matched=1", with: "matched=2"),
                        input + "\n\n", inventory([]), inventory(Array(repeating: row(), count: 129))] {
            assertUnchanged("Cedar Desk", altered)
        }
        for prompt in ["", "Unknown", "Cedar Desk " + String(repeating: "x", count: 8_192)] { assertUnchanged(prompt, input) }
        assertUnchanged("Cedar Desk", String(repeating: "x", count: 65_537))
    }

    func testAnnotationRespectsUTF8OutputBudget() {
        let base = inventory([row(extra: ["padding": ""])])
        let input = inventory([row(extra: ["padding": String(repeating: "x", count: 3_499 - base.utf8.count)])])
        XCTAssertEqual(input.utf8.count, 3_499)
        assertUnchanged("Cedar Desk", input)
        let unicode = inventory([row("雲 " + String(repeating: "界", count: 256))])
        assertUnchanged("雲 " + String(repeating: "界", count: 256), unicode)
    }
}

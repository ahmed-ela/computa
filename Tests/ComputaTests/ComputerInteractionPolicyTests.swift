import XCTest
@testable import Computa

final class ComputerInteractionPolicyTests: XCTestCase {
    func testDefaultViolationGuidanceRoutesWebpagesWithoutRelaxingNativePolicy() throws {
        for violation: ComputerInteractionPolicy.Violation in [.foregroundUnavailable, .legacyMutationUnavailable] {
            let message = violation.localizedDescription
            XCTAssertFalse(message.contains("Chrome")); XCTAssertFalse(message.contains("computer_v2_tabs"))
            XCTAssertTrue(message.contains("native app")); XCTAssertTrue(message.contains("browser_*"))
        }
        XCTAssertThrowsError(try ComputerInteractionPolicy.backgroundOnly.requireForeground()) {
            XCTAssertEqual($0 as? ComputerInteractionPolicy.Violation, .foregroundUnavailable)
        }
        XCTAssertThrowsError(try ComputerInteractionPolicy.backgroundOnly.requireLegacy(tool: "desktop_open_application", arguments: [:])) {
            XCTAssertEqual($0 as? ComputerInteractionPolicy.Violation, .legacyMutationUnavailable)
        }
        let native = try ComputerV2ToolContract.validate(tool: "computer_v2_open", arguments: ["bundle_id": "com.example.fixture"])
        XCTAssertNoThrow(try ComputerInteractionPolicy.backgroundOnly.requireV2(native))
    }
    private let snapshotID = "ABCDEF12-3456-4789-ABCD-0123456789AB"

    func testDefaultIsBackgroundOnlyAndCanRoundTripAsHostState() throws {
        XCTAssertEqual(ComputerInteractionPolicy.default, .backgroundOnly)
        for policy in ComputerInteractionPolicy.allCases {
            XCTAssertEqual(try JSONDecoder().decode(ComputerInteractionPolicy.self,
                from: JSONEncoder().encode(policy)), policy)
        }
    }

    func testBackgroundPolicyAllowsNonActivatingV2ObservationsAndSemanticActions() throws {
        let calls: [(ComputerV2ToolContract.Tool, [String: Any])] = [
            (.status, [:]), (.apps, [:]),
            (.open, ["bundle_id": "com.apple.MobileSMS"]),
            (.open, ["bundle_id": "com.google.Chrome", "activation": "none"]),
            (.snapshot, [:]),
            (.capture, [:]),
            (.ax, ["snapshot_id": snapshotID, "element_index": 0, "ax_action": "AXPress"]),
            (.setText, ["snapshot_id": snapshotID, "element_index": 0, "text": "read-only fixture query"]),
        ]
        for (tool, arguments) in calls {
            let call = try ComputerV2ToolContract.validate(tool: tool.rawValue, arguments: arguments)
            XCTAssertNoThrow(try ComputerInteractionPolicy.backgroundOnly.requireV2(call), tool.rawValue)
        }
    }

    func testBackgroundPolicyRejectsEveryV2GlobalInputBeforeDispatch() throws {
        let calls: [(ComputerV2ToolContract.Tool, [String: Any])] = [
            (.groundClick, ["capture_id": snapshotID, "target": "Save"]),
            (.click, ["capture_id": snapshotID, "x": 1, "y": 2]),
            (.pointer, ["capture_id": snapshotID, "action": "move", "x": 1, "y": 2]),
            (.keypress, ["key": "Return"]), (.type, ["text": "text"]),
            (.open, ["bundle_id": "com.apple.MobileSMS", "activation": "foreground"]),
            (.ax, ["snapshot_id": snapshotID, "element_index": 0, "ax_action": "AXRaise"]),
        ]
        for (tool, arguments) in calls {
            let call = try ComputerV2ToolContract.validate(tool: tool.rawValue, arguments: arguments)
            var dispatchCount = 0
            XCTAssertThrowsError(try {
                try ComputerInteractionPolicy.backgroundOnly.requireV2(call)
                dispatchCount += 1
            }()) { error in
                XCTAssertEqual(error as? ComputerInteractionPolicy.Violation, .foregroundUnavailable)
            }
            XCTAssertEqual(dispatchCount, 0, tool.rawValue)
            XCTAssertNoThrow(try ComputerInteractionPolicy.foregroundAllowed.requireV2(call))
        }
    }

    func testLegacyPureObservationsRemainAvailable() throws {
        for tool in ["desktop_permission_status", "desktop_list_apps", "desktop_focused_window",
                     "desktop_snapshot_app", "desktop_list_windows", "desktop_capture_window",
                     "desktop_capture_display"] {
            XCTAssertNoThrow(try ComputerInteractionPolicy.backgroundOnly.requireLegacy(tool: tool, arguments: [:]))
        }
        for action in ["permission_status", "apps", "snapshot", "capture"] {
            XCTAssertNoThrow(try ComputerInteractionPolicy.backgroundOnly.requireLegacy(tool: "computer",
                arguments: ["action": action, "parameters": [:]]))
        }
    }

    func testEveryLegacyMutationAndUnknownComputerActionFailsClosed() {
        for tool in ["desktop_open_application", "desktop_perform_action", "desktop_set_text",
                     "desktop_input", "desktop_future_mutation"] {
            assertLegacyRejected(tool: tool, arguments: ["activation": "none", "approved": true])
        }
        for action in ["open", "ax", "set_text", "move", "click", "double_click", "right_click",
                       "scroll", "drag", "keypress", "type", "future_action", ""] {
            assertLegacyRejected(tool: "computer", arguments: ["action": action, "parameters": [:]])
        }
        assertLegacyRejected(tool: "computer", arguments: [:])
        assertLegacyRejected(tool: "computer", arguments: ["action": ["apps"]])
    }

    func testToolArgumentsAndAutomaticApprovalDoNotElevatePolicy() throws {
        for approval: Any in [true, "fullAccess", "always_allow"] {
            assertLegacyRejected(tool: "desktop_input", arguments: ["approved": approval, "action": "click"])
        }
        XCTAssertThrowsError(try ComputerInteractionPolicy.backgroundOnly.requireForeground()) { error in
            XCTAssertEqual(error as? ComputerInteractionPolicy.Violation, .foregroundUnavailable)
            XCTAssertTrue(error.localizedDescription.contains("Background-only computer use cannot activate apps"))
            XCTAssertFalse(error.localizedDescription.contains("Open it again"))
        }
        XCTAssertNoThrow(try ComputerInteractionPolicy.foregroundAllowed.requireForeground())
        XCTAssertNoThrow(try ComputerInteractionPolicy.backgroundOnly.requireLegacy(tool: "unrelated_tool", arguments: [:]))
    }

    private func assertLegacyRejected(tool: String, arguments: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ComputerInteractionPolicy.backgroundOnly.requireLegacy(tool: tool, arguments: arguments),
                             file: file, line: line) { error in
            XCTAssertEqual(error as? ComputerInteractionPolicy.Violation, .legacyMutationUnavailable, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("computer_v2_open"), file: file, line: line)
        }
        XCTAssertNoThrow(try ComputerInteractionPolicy.foregroundAllowed.requireLegacy(tool: tool, arguments: arguments),
                         file: file, line: line)
    }
}

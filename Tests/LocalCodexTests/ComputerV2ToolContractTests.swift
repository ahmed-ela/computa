import AutomationCore
import Foundation
import XCTest
@testable import LocalCodex

final class ComputerV2ToolContractTests: XCTestCase {
    private let snapshotID = "11111111-1111-4111-8111-111111111111"
    private let captureID = "22222222-2222-4222-8222-222222222222"

    func testSpecsAreVersionedFlatAndActionSpecific() throws {
        let specs = ComputerV2ToolContract.specs
        XCTAssertEqual(specs.count, ComputerV2ToolContract.Tool.allCases.count)
        XCTAssertEqual(Set(specs.compactMap { $0["name"] as? String }).count, specs.count)

        for spec in specs {
            let name = try XCTUnwrap(spec["name"] as? String)
            XCTAssertTrue(name.hasPrefix("computer_v2_"))
            XCTAssertEqual(spec["type"] as? String, "function")
            let schema = try XCTUnwrap(spec["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let required = try XCTUnwrap(schema["required"] as? [String])
            XCTAssertTrue(Set(required).isSubset(of: Set(properties.keys)), name)
            XCTAssertNil(properties["process_id"], name)
        }

        let click = try spec(named: .click)
        XCTAssertEqual(Set(click.required), ["capture_id", "x", "y"])
        XCTAssertEqual(Set(click.properties.keys), ["capture_id", "x", "y"])
        let open = try spec(named: .open)
        XCTAssertEqual(open.required, ["bundle_id"])
        XCTAssertNotNil(open.properties["url"])
        let pointer = try spec(named: .pointer)
        let actionSchema = try XCTUnwrap(pointer.properties["action"] as? [String: Any])
        let actions = try XCTUnwrap(actionSchema["enum"] as? [String])
        XCTAssertFalse(actions.contains("drag"))
        XCTAssertNil(pointer.properties["end_x"])
        XCTAssertNil(pointer.properties["end_y"])
        XCTAssertNil(pointer.properties["duration"])
        let capture = try XCTUnwrap(ComputerV2ToolContract.specs.first {
            $0["name"] as? String == Tool.capture.rawValue
        })
        XCTAssertTrue((capture["description"] as? String)?.contains("focused app window") == true)
        XCTAssertTrue((capture["description"] as? String)?.contains("include_accessibility=true") == true)
        let captureSchema = try XCTUnwrap(capture["inputSchema"] as? [String: Any])
        let captureProperties = try XCTUnwrap(captureSchema["properties"] as? [String: Any])
        XCTAssertNotNil(captureProperties["include_accessibility"])
    }

    func testCaptureMetadataIdentifiesWindowImageAndPreservesPixelContract() throws {
        let mapper = try ScreenshotCoordinateMapper(
            frame: WindowFrame(x: 120, y: 80, width: 400, height: 300),
            imageWidth: 401,
            imageHeight: 301,
            captureID: UUID(uuidString: captureID)!,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let metadata = ComputerV2ToolContract.captureMetadata(mapper: mapper)

        XCTAssertTrue(metadata.contains("WINDOW_CAPTURE capture_id=\(captureID)"))
        XCTAssertTrue(metadata.contains("image_width=401 image_height=301"))
        XCTAssertTrue(metadata.contains("coordinate_space=image_pixels"))
        XCTAssertTrue(metadata.contains("focused app window"))
        XCTAssertFalse(metadata.contains("DISPLAY_CAPTURE"))
    }

    func testEveryToolAcceptsMinimalValidArguments() throws {
        let samples: [(ComputerV2ToolContract.Tool, [String: Any])] = [
            (.status, [:]),
            (.apps, [:]),
            (.open, ["bundle_id": "com.google.Chrome"]),
            (.snapshot, [:]),
            (.ax, [
                "snapshot_id": snapshotID,
                "element_index": 0,
                "ax_action": "AXPress",
            ]),
            (.setText, [
                "snapshot_id": snapshotID,
                "element_index": 1,
                "text": "hello",
            ]),
            (.capture, [:]),
            (.click, ["capture_id": captureID, "x": 12.5, "y": 20]),
            (.pointer, ["action": "move", "capture_id": captureID, "x": 1, "y": 2]),
            (.keypress, ["key": "return"]),
            (.type, ["text": "hello"]),
        ]
        XCTAssertEqual(samples.count, ComputerV2ToolContract.Tool.allCases.count)
        for (tool, arguments) in samples {
            let call = try ComputerV2ToolContract.validate(
                tool: tool.rawValue,
                arguments: arguments
            )
            XCTAssertEqual(call.tool, tool)
        }
    }

    func testMissingUnknownAndExtraArgumentsFailClosed() {
        assertFailure(.missing("bundle_id"), .open, [:])
        assertFailure(.unexpected("process_id"), .click, [
            "capture_id": captureID, "x": 1, "y": 2, "process_id": 820,
        ])
        assertFailure(.unexpected("action"), .status, ["action": "click"])
        XCTAssertThrowsError(try ComputerV2ToolContract.validate(
            tool: "computer",
            arguments: [:]
        )) { error in
            XCTAssertEqual(
                error as? ComputerV2ToolContract.ValidationError,
                .unknownTool("computer")
            )
        }
    }

    func testOpenAndSnapshotOptionalFieldsAreValidated() throws {
        _ = try ComputerV2ToolContract.validate(tool: Tool.open.rawValue, arguments: [
            "bundle_id": "com.google.Chrome",
            "url": "https://example.com",
        ])
        _ = try ComputerV2ToolContract.validate(tool: Tool.snapshot.rawValue, arguments: [
            "query": "Complete computer-use test",
        ])
        _ = try ComputerV2ToolContract.validate(tool: Tool.capture.rawValue, arguments: [
            "include_accessibility": true,
        ])
        assertFailure(.invalid("bundle_id"), .open, ["bundle_id": "not an.app"])
        assertFailure(.invalid("url"), .open, [
            "bundle_id": "com.google.Chrome", "url": "javascript:alert(1)",
        ])
        assertFailure(.invalid("query"), .snapshot, ["query": "   "])
        assertFailure(.invalid("query"), .snapshot, ["query": 17])
    }

    func testSnapshotAndCaptureIDsAreRequiredAndWellFormed() {
        assertFailure(.missing("snapshot_id"), .ax, [
            "element_index": 0, "ax_action": "AXPress",
        ])
        assertFailure(.invalid("snapshot_id"), .ax, [
            "snapshot_id": "stale", "element_index": 0, "ax_action": "AXPress",
        ])
        assertFailure(.invalid("capture_id"), .click, [
            "capture_id": "stale", "x": 1, "y": 2,
        ])
        assertFailure(.missing("capture_id"), .click, ["x": 1, "y": 2])
    }

    func testNumericValidationRejectsBooleansFractionsAndNonfiniteValues() {
        assertFailure(.invalid("element_index"), .ax, [
            "snapshot_id": snapshotID, "element_index": true, "ax_action": "AXPress",
        ])
        assertFailure(.invalid("element_index"), .ax, [
            "snapshot_id": snapshotID, "element_index": 0.5, "ax_action": "AXPress",
        ])
        assertFailure(.invalid("x"), .click, [
            "capture_id": captureID, "x": true, "y": 2,
        ])
        assertFailure(.invalid("x"), .click, [
            "capture_id": captureID, "x": -1, "y": 2,
        ])
        assertFailure(.invalid("y"), .click, [
            "capture_id": captureID, "x": 1, "y": Double.infinity,
        ])
        assertFailure(.invalid("display_id"), .capture, ["display_id": false])
        assertFailure(.invalid("shows_cursor"), .capture, ["shows_cursor": 1])
        assertFailure(.invalid("include_accessibility"), .capture, [
            "include_accessibility": 1,
        ])
    }

    func testPointerSubtypesHaveDistinctRuntimeRequirements() throws {
        let base: [String: Any] = ["capture_id": captureID, "x": 4, "y": 5]
        for action in ["move", "double_click", "right_click"] {
            var arguments = base
            arguments["action"] = action
            let call = try ComputerV2ToolContract.validate(
                tool: Tool.pointer.rawValue,
                arguments: arguments
            )
            XCTAssertEqual(call.pointerAction?.rawValue, action)
        }

        var scroll = base
        scroll["action"] = "scroll"
        assertFailure(.missing("delta_x"), .pointer, scroll)
        scroll["delta_x"] = 0
        scroll["delta_y"] = 0
        assertFailure(.invalid("delta_x/delta_y"), .pointer, scroll)
        scroll["delta_y"] = -120
        _ = try ComputerV2ToolContract.validate(tool: Tool.pointer.rawValue, arguments: scroll)

        var drag = base
        drag["action"] = "drag"
        drag["end_x"] = 30
        drag["end_y"] = 40
        drag["duration"] = 0.25
        assertFailure(.invalid("action"), .pointer, drag)

        var unknown = base
        unknown["action"] = "click"
        assertFailure(.invalid("action"), .pointer, unknown)
    }

    func testSemanticActionsTextAndModifiersAreBounded() throws {
        assertFailure(.invalid("ax_action"), .ax, [
            "snapshot_id": snapshotID, "element_index": 0, "ax_action": "delete_everything",
        ])
        assertFailure(.invalid("text"), .setText, [
            "snapshot_id": snapshotID, "element_index": 0,
            "text": String(repeating: "a", count: 4_097),
        ])
        assertFailure(.invalid("modifiers"), .keypress, [
            "key": "a", "modifiers": ["command", "command"],
        ])
        assertFailure(.invalid("modifiers"), .keypress, [
            "key": "a", "modifiers": ["hyper"],
        ])
        _ = try ComputerV2ToolContract.validate(tool: Tool.keypress.rawValue, arguments: [
            "key": "a", "modifiers": ["command", "shift"],
        ])
    }

    private typealias Tool = ComputerV2ToolContract.Tool

    private func assertFailure(
        _ expected: ComputerV2ToolContract.ValidationError,
        _ tool: Tool,
        _ arguments: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ComputerV2ToolContract.validate(
                tool: tool.rawValue,
                arguments: arguments
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ComputerV2ToolContract.ValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func spec(named tool: Tool) throws -> (
        properties: [String: Any],
        required: [String]
    ) {
        let match = try XCTUnwrap(ComputerV2ToolContract.specs.first {
            $0["name"] as? String == tool.rawValue
        })
        let schema = try XCTUnwrap(match["inputSchema"] as? [String: Any])
        return (
            try XCTUnwrap(schema["properties"] as? [String: Any]),
            try XCTUnwrap(schema["required"] as? [String])
        )
    }
}

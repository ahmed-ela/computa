import AutomationCore
import Foundation
import XCTest
@testable import HeyDash

final class ComputerV2ToolContractTests: XCTestCase {
    private let snapshotID = "11111111-1111-4111-8111-111111111111"
    private let captureID = "22222222-2222-4222-8222-222222222222"

    func testAppInventoryIsBoundedAndQueriesDoNotExcludeBackgroundApps() throws {
        func app(_ pid: Int32, _ name: String, _ policy: ApplicationActivationPolicy = .regular) -> RunningApplicationInfo {
            .init(processIdentifier: pid, bundleIdentifier: "example.app.\(pid)", localizedName: name,
                  activationPolicy: policy, isActive: false, isHidden: false, isTerminated: false)
        }
        let apps = (1...300).map { app(Int32($0), "Application \($0)") }
            + [app(999, "Background Helper", .accessory), app(1_000, "StudyLock")]
        let compact = ComputerV2ToolContract.appInventory(apps, query: nil)
        XCTAssertLessThanOrEqual(compact.utf8.count, ComputerV2ToolContract.maximumAppInventoryBytes)
        XCTAssertTrue(compact.contains("scope=user_facing matched=301"))
        XCTAssertFalse(compact.contains("Background Helper"))
        XCTAssertTrue(compact.contains("query with a name or bundle_id"))
        for query in ["Background Helper", "EXAMPLE.APP.999", "StudyLock"] {
            let result = ComputerV2ToolContract.appInventory(apps, query: query)
            XCTAssertTrue(result.contains("matched=1 returned=1 omitted=0"))
            XCTAssertTrue(result.contains(query == "StudyLock" ? "\"pid\":1000" : "\"pid\":999"))
        }
        _ = try ComputerV2ToolContract.validate(tool: Tool.apps.rawValue, arguments: ["query": "Chrome"])
        for query in [" ", String(repeating: "x", count: 201)] {
            XCTAssertThrowsError(try ComputerV2ToolContract.validate(tool: Tool.apps.rawValue, arguments: ["query": query]))
        }
    }

    func testAppInventoryRetainsExactIdentityAndEscapesUntrustedNames() throws {
        let app = RunningApplicationInfo(
            processIdentifier: 42, bundleIdentifier: "example.exact.identity", localizedName: "App\n\"quoted\"",
            activationPolicy: .regular, isActive: true, isHidden: false, isTerminated: false
        )
        let text = ComputerV2ToolContract.appInventory([app], query: nil)
        let rows = text.split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rows[1].utf8)) as? [String: Any])
        XCTAssertEqual(value["pid"] as? Int, 42)
        XCTAssertEqual(value["bundle_id"] as? String, "example.exact.identity")
        XCTAssertEqual(value["name"] as? String, "App\n\"quoted\"")
    }

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
        let browserMode = try XCTUnwrap(open.properties["browser_mode"] as? [String: Any])
        XCTAssertEqual(browserMode["type"] as? String, "string")
        XCTAssertEqual(Set(try XCTUnwrap(browserMode["enum"] as? [String])), ["existing", "isolated"])
        XCTAssertFalse(open.required.contains("browser_mode"))
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
        let displayID = try XCTUnwrap(captureProperties["display_id"] as? [String: Any])
        XCTAssertEqual(displayID["minimum"] as? Int, 1)
        XCTAssertEqual(displayID["maximum"] as? Int, 4_294_967_295)
        XCTAssertTrue((displayID["description"] as? String)?.contains("Usually omit") == true)
        _ = try ComputerV2ToolContract.validate(tool: Tool.capture.rawValue, arguments: [:])
        XCTAssertThrowsError(try ComputerV2ToolContract.validate(tool: Tool.capture.rawValue, arguments: ["display_id": 0]))
        let snapshot = try spec(named: .snapshot)
        let query = try XCTUnwrap(snapshot.properties["query"] as? [String: Any])
        XCTAssertEqual(query["maxLength"] as? Int, 200)
        XCTAssertTrue((query["description"] as? String)?.contains("missing/truncated") == true)
        let groundClick = try spec(named: .groundClick)
        XCTAssertEqual(Set(groundClick.required), ["capture_id", "target"])
        XCTAssertEqual(Set(groundClick.properties.keys), ["capture_id", "target"])
        let groundClickSpec = try XCTUnwrap(ComputerV2ToolContract.specs.first {
            $0["name"] as? String == Tool.groundClick.rawValue
        })
        XCTAssertTrue((groundClickSpec["description"] as? String)?.contains(
            "fresh post-action screenshot with synchronized Accessibility"
        ) == true)
        XCTAssertTrue((groundClickSpec["description"] as? String)?.contains(
            "dispatch marker alone is not success"
        ) == true)
    }

    func testVisualGroundingToolIsRegisteredOnlyForModelsWithMemoryHeadroom() {
        let groundClick = ComputerV2ToolContract.Tool.groundClick.rawValue
        for modelID in [
            "lmstudio-community/Qwen3.5-4B-MLX-4bit",
            "lmstudio-community/Qwen3.5-9B-MLX-4bit",
        ] {
            XCTAssertTrue(
                ComputerV2ToolContract.specs(for: modelID)
                    .contains { $0["name"] as? String == groundClick },
                modelID
            )
        }
        for modelID in [
            LocalModelCatalog.defaultModelID,
            "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit",
        ] {
            XCTAssertFalse(
                ComputerV2ToolContract.specs(for: modelID)
                    .contains { $0["name"] as? String == groundClick },
                modelID
            )
        }
    }

    func testModelGuidanceSeparatesAccessibilityActionsFromScreenshotClicks() throws {
        func description(_ tool: Tool) throws -> String {
            let value = try XCTUnwrap(ComputerV2ToolContract.specs.first {
                $0["name"] as? String == tool.rawValue
            })
            return try XCTUnwrap(value["description"] as? String)
        }
        let snapshot = try description(.snapshot)
        XCTAssertTrue(snapshot.contains("AX actions for buttons and links"))
        XCTAssertTrue(snapshot.contains("exact observed url with computer_v2_open"))
        XCTAssertTrue(snapshot.contains("navigation link without AXPress"))
        XCTAssertTrue(snapshot.contains("not an in-page script action"))
        XCTAssertTrue(snapshot.contains("follow parent through the header parents map (child:parent) to group facts, never adjacency alone"))
        XCTAssertTrue(snapshot.contains("try a short literal query before scrolling or capturing"))
        XCTAssertTrue(snapshot.contains("make one literal query for that item before answering; never substitute another item's fact"))
        XCTAssertTrue(snapshot.contains("sibling_heading is observed direct-sibling context, not proof of semantic ownership"))
        XCTAssertTrue(snapshot.contains("answer and stop"))
        XCTAssertTrue(snapshot.contains("never reconstruct url_omitted"))
        XCTAssertTrue(snapshot.contains("text field only focuses it; it does not submit"))
        XCTAssertTrue(try description(.ax).contains("use keypress for Enter"))
        let click = try description(.click)
        XCTAssertTrue(click.contains("fresh capture_id from computer_v2_capture"))
        XCTAssertTrue(click.contains("Never use snapshot_id or AX screen coordinates"))
        let typing = try description(.type)
        XCTAssertTrue(typing.contains("does not navigate or submit"))
        XCTAssertTrue(typing.contains("computer_v2_open with url"))
        for tool in [Tool.ax, .setText, .type, .keypress] {
            XCTAssertTrue(try description(tool).contains("fresh AX snapshot"))
        }
        let instructions = CodexAppServerRuntime.Configuration.localQwen.baseInstructions
        XCTAssertTrue(instructions.contains("Computer use: bind with computer_v2_open first each turn"))
        XCTAssertTrue(instructions.contains("Omit url for current tab"))
        XCTAssertTrue(instructions.contains("Image input needs fresh capture_id and image pixels, not AX screen points"))
        XCTAssertTrue(instructions.contains("If unchanged, inspect, do not repeat blindly"))
        XCTAssertTrue(instructions.contains("Answer only the requested facts"))
        XCTAssertLessThan(instructions.utf8.count, 1_024)
    }

    func testPointerGuidanceRequiresCoordinatesForScrollWithoutRelaxingValidation() throws {
        let pointer = try spec(named: .pointer)
        XCTAssertEqual(Set(pointer.required), ["action", "capture_id", "x", "y"])
        for field in ["x", "y"] {
            let property = try XCTUnwrap(pointer.properties[field] as? [String: Any])
            XCTAssertEqual(property["minimum"] as? Int, 0)
            XCTAssertTrue((property["description"] as? String)?.contains("including scroll") == true)
        }
        let capture = try XCTUnwrap(pointer.properties["capture_id"] as? [String: Any])
        XCTAssertTrue((capture["description"] as? String)?.contains("invalidates older captures") == true)
        let missingPoint: [String: Any] = ["action": "scroll", "capture_id": captureID, "delta_x": 0, "delta_y": 500]
        assertFailure(.missing("x"), .pointer, missingPoint)
        var partialPoint = missingPoint
        partialPoint["x"] = 100
        assertFailure(.missing("y"), .pointer, partialPoint)
    }

    func testGroundingGuidanceCoversVisibleButNonpressableLinksWithoutRemovingTools() throws {
        let grounded = ComputerV2ToolContract.specs(for: "lmstudio-community/Qwen3.5-4B-MLX-4bit")
        XCTAssertEqual(Set(grounded.compactMap { $0["name"] as? String }),
                       Set(ComputerV2ToolContract.specs.compactMap { $0["name"] as? String }))
        let click = try XCTUnwrap(grounded.first { $0["name"] as? String == Tool.click.rawValue })
        XCTAssertTrue((click["description"] as? String)?.contains("Prefer computer_v2_ground_click") == true)
        XCTAssertEqual(try spec(named: .click).required, ["capture_id", "x", "y"])
        XCTAssertTrue(ComputerV2ToolContract.visualGroundingInstructions.contains("listed link without AXPress"))
        XCTAssertTrue(ComputerV2ToolContract.visualGroundingInstructions.contains("without an observed url"))
        XCTAssertTrue(ComputerV2ToolContract.visualGroundingInstructions.contains("Prefer a link's supported AXPress"))
        XCTAssertTrue(ComputerV2ToolContract.visualGroundingInstructions.contains("do not guess or reconstruct an omitted URL"))
        XCTAssertTrue(ComputerV2ToolContract.visualGroundingInstructions.contains("verify the visible outcome"))
        let ungrounded = ComputerV2ToolContract.specs(for: LocalModelCatalog.defaultModelID)
        let ungroundedClick = try XCTUnwrap(ungrounded.first { $0["name"] as? String == Tool.click.rawValue })
        XCTAssertFalse((ungroundedClick["description"] as? String)?.contains("computer_v2_ground_click") == true,
                       "Do not recommend a tool excluded for memory headroom.")
    }

    func testGroundedCoordinatesRequireWholeWindowFreshness() {
        let points = [ScreenPoint(x: 10, y: 20)]
        XCTAssertEqual(
            ComputerV2FreshnessPolicy.windowFingerprintTargets(
                points,
                usesVisualGrounding: false
            ),
            points
        )
        XCTAssertTrue(ComputerV2FreshnessPolicy.windowFingerprintTargets(
            points,
            usesVisualGrounding: true
        ).isEmpty)
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
            (.groundClick, [
                "capture_id": captureID,
                "target": "the blue circular button with a white star",
            ]),
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

    func testChromeOpenDefaultsToExistingBrowserWithOrWithoutURL() throws {
        let samples: [[String: Any]] = [
            ["bundle_id": "com.google.Chrome"],
            ["bundle_id": "com.google.Chrome", "url": "https://example.com"],
        ]
        for arguments in samples {
            let call = try ComputerV2ToolContract.validate(tool: Tool.open.rawValue, arguments: arguments)
            XCTAssertEqual(call.browserMode, .existing)
            XCTAssertNil(call.arguments["browser_mode"], "The default must not rewrite the model's submitted arguments.")
        }
    }

    func testChromeOpenAcceptsExplicitExistingAndIsolatedModes() throws {
        for mode in ["existing", "isolated"] {
            let call = try ComputerV2ToolContract.validate(tool: Tool.open.rawValue, arguments: [
                "bundle_id": "com.google.Chrome", "url": "https://example.com", "browser_mode": mode,
            ])
            XCTAssertEqual(call.browserMode?.rawValue, mode)
            XCTAssertEqual(call.arguments["browser_mode"] as? String, mode)
        }
        let existing = try ComputerV2ToolContract.validate(tool: Tool.open.rawValue, arguments: [
            "bundle_id": "com.google.Chrome", "browser_mode": "existing",
        ])
        XCTAssertEqual(existing.browserMode, .existing)
    }

    func testBrowserModeIsOnlyAvailableForChromeOpen() throws {
        for bundleID in ["com.apple.Safari", "com.apple.calculator"] {
            for mode in ["existing", "isolated"] {
                assertFailure(.invalid("browser_mode"), .open, [
                    "bundle_id": bundleID, "url": "https://example.com", "browser_mode": mode,
                ])
            }
            let call = try ComputerV2ToolContract.validate(tool: Tool.open.rawValue, arguments: [
                "bundle_id": bundleID,
            ])
            XCTAssertNil(call.browserMode)
        }
        let status = try ComputerV2ToolContract.validate(tool: Tool.status.rawValue, arguments: [:])
        XCTAssertNil(status.browserMode)
        assertFailure(.unexpected("browser_mode"), .snapshot, ["browser_mode": "existing"])
    }

    func testBrowserModeRejectsUnknownAndMalformedValues() {
        let invalidModes: [Any] = ["", "default", "auto", "ISOLATED", " existing", true, 1, NSNull(), ["existing"]]
        for mode in invalidModes {
            assertFailure(.invalid("browser_mode"), .open, [
                "bundle_id": "com.google.Chrome", "url": "https://example.com", "browser_mode": mode,
            ])
        }
    }

    func testIsolatedChromeRequiresAValidURL() {
        assertFailure(.missing("url"), .open, [
            "bundle_id": "com.google.Chrome", "browser_mode": "isolated",
        ])
        let invalidURLs: [Any] = ["", "javascript:alert(1)", "about:blank", true, NSNull()]
        for url in invalidURLs {
            assertFailure(.invalid("url"), .open, [
                "bundle_id": "com.google.Chrome", "browser_mode": "isolated", "url": url,
            ])
        }
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
        assertFailure(.missing("capture_id"), .groundClick, ["target": "Save"])
        assertFailure(.invalid("capture_id"), .groundClick, [
            "capture_id": "stale", "target": "Save",
        ])
        assertFailure(.missing("target"), .groundClick, ["capture_id": captureID])
        assertFailure(.invalid("target"), .groundClick, [
            "capture_id": captureID, "target": "   ",
        ])
        assertFailure(.invalid("target"), .groundClick, [
            "capture_id": captureID, "target": String(repeating: "x", count: 513),
        ])
        for target in [" Save", "Save\nCancel", "Save\tCancel", "Save\u{202E}Cancel"] {
            assertFailure(.invalid("target"), .groundClick, [
                "capture_id": captureID, "target": target,
            ])
        }
        assertFailure(.unexpected("x"), .groundClick, [
            "capture_id": captureID, "target": "Save", "x": 10,
        ])
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

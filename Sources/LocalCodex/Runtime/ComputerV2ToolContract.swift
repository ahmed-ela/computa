import AutomationCore
import CoreFoundation
import Foundation

/// A compact, versioned model-facing computer contract. This is deliberately
/// separate from the legacy `computer` function so a rollout can be compared
/// without changing old threads. A V2 executor must bind the selected app,
/// retain snapshots/captures, and check image bounds before any mutation.
enum ComputerV2ToolContract {
    static func captureMetadata(mapper: ScreenshotCoordinateMapper) -> String {
        """
        WINDOW_CAPTURE capture_id=\(mapper.captureID.uuidString)
        image_width=\(mapper.imageWidth) image_height=\(mapper.imageHeight) coordinate_space=image_pixels
        This image shows the focused app window. The x and y for computer_v2_click or computer_v2_pointer are pixels in this image. Copy capture_id exactly; LocalCodex maps image pixels to screen points and checks the bound window.
        """
    }

    enum Tool: String, CaseIterable {
        case status = "computer_v2_status"
        case apps = "computer_v2_apps"
        case open = "computer_v2_open"
        case snapshot = "computer_v2_snapshot"
        case ax = "computer_v2_ax"
        case setText = "computer_v2_set_text"
        case capture = "computer_v2_capture"
        case groundClick = "computer_v2_ground_click"
        case click = "computer_v2_click"
        case pointer = "computer_v2_pointer"
        case keypress = "computer_v2_keypress"
        case type = "computer_v2_type"
    }

    enum PointerAction: String, CaseIterable {
        case move
        case doubleClick = "double_click"
        case rightClick = "right_click"
        case scroll
    }

    struct ValidatedCall {
        let tool: Tool
        let arguments: [String: Any]

        var pointerAction: PointerAction? {
            guard tool == .pointer,
                  let raw = arguments["action"] as? String
            else { return nil }
            return PointerAction(rawValue: raw)
        }
    }

    enum ValidationError: Error, Equatable, LocalizedError {
        case unknownTool(String)
        case missing(String)
        case unexpected(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): "Unknown computer V2 tool: \(name)"
            case .missing(let name): "Missing computer V2 argument: \(name)"
            case .unexpected(let name): "Unexpected computer V2 argument: \(name)"
            case .invalid(let name): "Invalid computer V2 argument: \(name)"
            }
        }
    }

    /// App Server DynamicToolSpec objects. Schemas help the model, but the
    /// local Responses-compatible server does not enforce `required` fields;
    /// callers must run `validate` before dispatching any action.
    static var specs: [[String: Any]] {
        Tool.allCases.map(spec)
    }

    static func specs(for modelID: String) -> [[String: Any]] {
        guard !LocalModelCatalog.supportsResidentVisualGrounding(modelID) else {
            return specs
        }
        return Tool.allCases.filter { $0 != .groundClick }.map(spec)
    }

    static func validate(
        tool name: String,
        arguments: [String: Any]
    ) throws -> ValidatedCall {
        guard let tool = Tool(rawValue: name) else {
            throw ValidationError.unknownTool(name)
        }

        switch tool {
        case .status, .apps:
            try checkKeys(arguments, required: [], allowed: [])

        case .open:
            try checkKeys(arguments, required: ["bundle_id"], allowed: ["bundle_id", "url"])
            let bundleID = try requiredString("bundle_id", in: arguments, maximum: 255)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
            guard bundleID.unicodeScalars.allSatisfy(allowed.contains) else {
                throw ValidationError.invalid("bundle_id")
            }
            if arguments["url"] != nil {
                let rawURL = try requiredString("url", in: arguments, maximum: 8_192)
                guard let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https", "file"].contains(scheme)
                else { throw ValidationError.invalid("url") }
            }

        case .snapshot:
            try checkKeys(arguments, required: [], allowed: ["query"])
            if arguments["query"] != nil {
                let query = try requiredString("query", in: arguments, maximum: 200)
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.invalid("query")
                }
            }

        case .ax:
            try checkKeys(
                arguments,
                required: ["snapshot_id", "element_index", "ax_action"],
                allowed: ["snapshot_id", "element_index", "ax_action"]
            )
            try requireUUID("snapshot_id", in: arguments)
            try requireNonnegativeInteger("element_index", in: arguments)
            let action = try requiredString("ax_action", in: arguments)
            guard SemanticAXAction(rawValue: action) != nil else {
                throw ValidationError.invalid("ax_action")
            }

        case .setText:
            try checkKeys(
                arguments,
                required: ["snapshot_id", "element_index", "text"],
                allowed: ["snapshot_id", "element_index", "text"]
            )
            try requireUUID("snapshot_id", in: arguments)
            try requireNonnegativeInteger("element_index", in: arguments)
            _ = try requiredString("text", in: arguments, maximum: 4_096)

        case .capture:
            try checkKeys(
                arguments,
                required: [],
                allowed: ["display_id", "shows_cursor", "include_accessibility"]
            )
            if arguments["display_id"] != nil {
                let value = try integer("display_id", in: arguments)
                guard value > 0, UInt32(exactly: value) != nil else {
                    throw ValidationError.invalid("display_id")
                }
            }
            if arguments["shows_cursor"] != nil {
                try requireBoolean("shows_cursor", in: arguments)
            }
            if arguments["include_accessibility"] != nil {
                try requireBoolean("include_accessibility", in: arguments)
            }

        case .groundClick:
            try checkKeys(
                arguments,
                required: ["capture_id", "target"],
                allowed: ["capture_id", "target"]
            )
            try requireUUID("capture_id", in: arguments)
            let target = try requiredString("target", in: arguments, maximum: 512)
            guard target == target.trimmingCharacters(in: .whitespacesAndNewlines),
                  target.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.properties.generalCategory {
                      case .control, .format, .lineSeparator, .paragraphSeparator:
                          false
                      default:
                          true
                      }
                  }) else {
                throw ValidationError.invalid("target")
            }

        case .click:
            try checkKeys(
                arguments,
                required: ["capture_id", "x", "y"],
                allowed: ["capture_id", "x", "y"]
            )
            try requireImagePoint(arguments)

        case .pointer:
            try validatePointer(arguments)

        case .keypress:
            try checkKeys(arguments, required: ["key"], allowed: ["key", "modifiers"])
            _ = try requiredString("key", in: arguments, maximum: 64)
            if let rawModifiers = arguments["modifiers"] {
                guard let modifiers = rawModifiers as? [String],
                      modifiers.count <= KeyboardModifier.allCases.count,
                      Set(modifiers).count == modifiers.count,
                      modifiers.allSatisfy({ KeyboardModifier(rawValue: $0) != nil })
                else { throw ValidationError.invalid("modifiers") }
            }

        case .type:
            try checkKeys(arguments, required: ["text"], allowed: ["text"])
            _ = try requiredString("text", in: arguments, maximum: 4_096)
        }

        return ValidatedCall(tool: tool, arguments: arguments)
    }

    private static func validatePointer(_ arguments: [String: Any]) throws {
        guard arguments["action"] != nil else { throw ValidationError.missing("action") }
        let rawAction = try requiredString("action", in: arguments)
        guard let action = PointerAction(rawValue: rawAction) else {
            throw ValidationError.invalid("action")
        }
        let base = ["action", "capture_id", "x", "y"]
        switch action {
        case .move, .doubleClick, .rightClick:
            try checkKeys(arguments, required: base, allowed: base)
        case .scroll:
            let fields = base + ["delta_x", "delta_y"]
            try checkKeys(arguments, required: fields, allowed: fields)
            let dx = try integer("delta_x", in: arguments)
            let dy = try integer("delta_y", in: arguments)
            guard (-10_000 ... 10_000).contains(dx),
                  (-10_000 ... 10_000).contains(dy),
                  dx != 0 || dy != 0
            else { throw ValidationError.invalid("delta_x/delta_y") }
        }
        try requireImagePoint(arguments)
    }

    private static func requireImagePoint(_ arguments: [String: Any]) throws {
        try requireUUID("capture_id", in: arguments)
        try requireImageCoordinate("x", in: arguments)
        try requireImageCoordinate("y", in: arguments)
        // The executor must additionally check x/y against the captured image
        // dimensions and ensure the capture belongs to the bound app.
    }

    private static func requireImageCoordinate(
        _ key: String,
        in arguments: [String: Any]
    ) throws {
        guard try finiteNumber(key, in: arguments) >= 0 else {
            throw ValidationError.invalid(key)
        }
    }

    private static func checkKeys(
        _ arguments: [String: Any],
        required: [String],
        allowed: [String]
    ) throws {
        let keys = Set(arguments.keys)
        if let missing = required.first(where: { !keys.contains($0) }) {
            throw ValidationError.missing(missing)
        }
        if let extra = keys.subtracting(allowed).sorted().first {
            throw ValidationError.unexpected(extra)
        }
    }

    private static func requiredString(
        _ key: String,
        in arguments: [String: Any],
        maximum: Int = 128
    ) throws -> String {
        guard let raw = arguments[key] else { throw ValidationError.missing(key) }
        guard let value = raw as? String,
              !value.isEmpty,
              value.count <= maximum
        else { throw ValidationError.invalid(key) }
        return value
    }

    private static func requireUUID(_ key: String, in arguments: [String: Any]) throws {
        let value = try requiredString(key, in: arguments)
        guard UUID(uuidString: value) != nil else { throw ValidationError.invalid(key) }
    }

    private static func requireNonnegativeInteger(
        _ key: String,
        in arguments: [String: Any]
    ) throws {
        guard try integer(key, in: arguments) >= 0 else {
            throw ValidationError.invalid(key)
        }
    }

    private static func integer(_ key: String, in arguments: [String: Any]) throws -> Int64 {
        guard let raw = arguments[key] else { throw ValidationError.missing(key) }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { throw ValidationError.invalid(key) }
        let value = number.int64Value
        guard number.compare(NSNumber(value: value)) == .orderedSame else {
            throw ValidationError.invalid(key)
        }
        return value
    }

    private static func finiteNumber(_ key: String, in arguments: [String: Any]) throws -> Double {
        guard let raw = arguments[key] else { throw ValidationError.missing(key) }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { throw ValidationError.invalid(key) }
        return number.doubleValue
    }

    private static func requireBoolean(_ key: String, in arguments: [String: Any]) throws {
        guard let number = arguments[key] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { throw ValidationError.invalid(key) }
    }

    private static func spec(_ tool: Tool) -> [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let integer: [String: Any] = ["type": "integer"]
        let number: [String: Any] = ["type": "number"]
        let boolean: [String: Any] = ["type": "boolean"]
        let capturePoint = ["capture_id": string, "x": number, "y": number]
        let properties: [String: [String: Any]]
        let required: [String]
        let description: String

        switch tool {
        case .status:
            properties = [:]; required = []
            description = "Read macOS computer-use permissions."
        case .apps:
            properties = [:]; required = []
            description = "List running apps."
        case .open:
            properties = ["bundle_id": string, "url": string]; required = ["bundle_id"]
            description = "Open and bind an app. A Chrome URL creates an exact task-scoped tab in a separate isolated profile; Chrome is com.google.Chrome."
        case .snapshot:
            properties = ["query": string]; required = []
            description = "Read the bound native app or exact brokered Chrome tab Accessibility tree; returns snapshot_id."
        case .ax:
            properties = [
                "snapshot_id": string, "element_index": integer,
                "ax_action": ["type": "string", "enum": SemanticAXAction.allCases.map(\.rawValue)],
            ]
            required = ["snapshot_id", "element_index", "ax_action"]
            description = "Act on a current native or exact brokered-tab AX snapshot element, then observe again. Approval required."
        case .setText:
            properties = ["snapshot_id": string, "element_index": integer, "text": string]
            required = ["snapshot_id", "element_index", "text"]
            description = "Set text on a current native or exact brokered-tab AX element, then observe again. Approval required."
        case .capture:
            properties = [
                "display_id": integer,
                "shows_cursor": boolean,
                "include_accessibility": boolean,
            ]; required = []
            description = "Capture the focused app window for native apps; brokered Chrome tabs fail closed. Returns capture_id and image dimensions. Set include_accessibility=true for synchronized native AX."
        case .groundClick:
            properties = ["capture_id": string, "target": string]
            required = ["capture_id", "target"]
            description = "For a native screenshot-only target that AX cannot identify, locate and click the target using the local GoClick + GUI-Owl agreement cascade with ShowUI only on disagreement. Requires a current capture_id and native approval, then returns a fresh post-action screenshot with synchronized Accessibility when available. Verify the visible outcome; the dispatch marker alone is not success."
        case .click:
            properties = capturePoint; required = ["capture_id", "x", "y"]
            description = "Click x,y in the captured image of the bound app, then observe. Approval required."
        case .pointer:
            properties = capturePoint.merging([
                "action": ["type": "string", "enum": PointerAction.allCases.map(\.rawValue)],
                "delta_x": integer, "delta_y": integer,
            ]) { _, new in new }
            required = ["action", "capture_id", "x", "y"]
            description = "Image-space move/double_click/right_click/scroll. Scroll needs delta_x,y. Approval required."
        case .keypress:
            properties = [
                "key": string,
                "modifiers": [
                    "type": "array",
                    "items": ["type": "string", "enum": KeyboardModifier.allCases.map(\.rawValue)],
                ],
            ]
            required = ["key"]
            description = "Press a key in the bound app, then observe. Approval required."
        case .type:
            properties = ["text": string]; required = ["text"]
            description = "Type text in the bound app, then observe. Approval required."
        }

        return [
            "type": "function",
            "name": tool.rawValue,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
        ]
    }
}

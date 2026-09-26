import AutomationCore
import CoreFoundation
import Foundation

/// A compact, versioned model-facing computer contract. This is deliberately
/// separate from the legacy `computer` function so a rollout can be compared
/// without changing old threads. A V2 executor must bind the selected app,
/// retain snapshots/captures, and check image bounds before any mutation.
enum ComputerV2ToolContract {
    static let maximumAppInventoryBytes = 3_500
    static let unboundApplicationMessage = "No application is bound in this turn. Call computer_v2_open, or use computer_v2_tabs then computer_v2_bind_tab for an existing Chrome tab through a native-user-approved connection."
    static let existingBrowserSessionNote = browserSessionNote(activationMode: .foreground)
    static func browserSessionNote(activationMode: ActivationMode) -> String {
        "\nBROWSER_SESSION profile=existing ordinary_profile_access=true tab_broker=false open_activation=\(activationMode.rawValue). Existing tabs and logins are preserved. Native AX may work in background. With activation=none, capture is an observation-only image and grants no input authority. Actionable capture and global key/pointer input still require foreground and are unavailable in a non-activating binding. This is not a task-isolated browser tab."
    }

    /// Keep discovery proportional to a small local model's context. The default
    /// lists user-facing apps, not every system helper. A query searches all
    /// running apps without any name-specific exclusions.
    static func appInventory(_ applications: [RunningApplicationInfo], query: String?) -> String {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = applications.filter { app in
            guard app.processIdentifier > 0, !app.isTerminated else { return false }
            if let query, !query.isEmpty {
                return [app.localizedName, app.bundleIdentifier].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            return app.activationPolicy == .regular || app.isActive
        }.sorted { left, right in
            if let query {
                let leftExact = left.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
                let rightExact = right.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
                if leftExact != rightExact { return leftExact }
            }
            if left.isActive != right.isActive { return left.isActive }
            let leftName = left.localizedName ?? left.bundleIdentifier ?? ""
            let rightName = right.localizedName ?? right.bundleIdentifier ?? ""
            let order = leftName.localizedCaseInsensitiveCompare(rightName)
            return order == .orderedSame ? left.processIdentifier < right.processIdentifier : order == .orderedAscending
        }
        var rows: [String] = []
        var bytes = 0
        for app in matches {
            var row: [String: Any] = ["pid": app.processIdentifier, "active": app.isActive]
            if let name = app.localizedName { row["name"] = String(name.prefix(72)) }
            if let bundle = app.bundleIdentifier { row["bundle_id"] = bundle }
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8),
                  bytes + data.count + 1 <= maximumAppInventoryBytes - 400 else { continue }
            rows.append(text)
            bytes += data.count + 1
        }
        let scope = query == nil ? "user_facing" : "all_matching_running_apps"
        return "APPS scope=\(scope) matched=\(matches.count) returned=\(rows.count) omitted=\(matches.count - rows.count). "
            + "Use query with a name or bundle_id to find helpers or omitted apps. Known bundle_id: open directly; no listing needed.\n"
            + rows.joined(separator: "\n")
    }

    static func captureMetadata(mapper: ScreenshotCoordinateMapper) -> String {
        """
        WINDOW_CAPTURE capture_id=\(mapper.captureID.uuidString)
        image_width=\(mapper.imageWidth) image_height=\(mapper.imageHeight) coordinate_space=image_pixels
        This image shows the focused app window. The x and y for computer_v2_click or computer_v2_pointer are pixels in this image. Copy capture_id exactly; Macrouse maps image pixels to screen points and checks the bound window.
        """
    }

    enum Tool: String, CaseIterable {
        case status = "computer_v2_status"
        case apps = "computer_v2_apps"
        case open = "computer_v2_open"
        case tabs = "computer_v2_tabs"
        case bindTab = "computer_v2_bind_tab"
        case snapshot = "computer_v2_snapshot"
        case ax = "computer_v2_ax"
        case setText = "computer_v2_set_text"
        case capture = "computer_v2_capture"
        case groundClick = "computer_v2_ground_click"
        case click = "computer_v2_click"
        case pointer = "computer_v2_pointer"
        case keypress = "computer_v2_keypress"
        case type = "computer_v2_type"

        var requiresGlobalInput: Bool {
            switch self {
            case .groundClick, .click, .pointer, .keypress, .type: true
            default: false
            }
        }
    }

    enum PointerAction: String, CaseIterable {
        case move
        case doubleClick = "double_click"
        case rightClick = "right_click"
        case scroll
    }

    enum BrowserMode: String, CaseIterable {
        case existing
        case isolated
    }

    enum ActivationMode: String, CaseIterable {
        case foreground
        case none
    }

    struct ValidatedCall {
        let tool: Tool
        let arguments: [String: Any]

        var tabPageSize: Int {
            (arguments["page_size"] as? NSNumber)?.intValue ?? 25
        }

        var activationMode: ActivationMode {
            (arguments["activation"] as? String).flatMap(ActivationMode.init(rawValue:)) ?? .foreground
        }

        var browserMode: BrowserMode? {
            guard tool == .open, arguments["bundle_id"] as? String == "com.google.Chrome" else { return nil }
            return (arguments["browser_mode"] as? String).flatMap(BrowserMode.init(rawValue:)) ?? .existing
        }

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
        guard LocalModelCatalog.supportsResidentVisualGrounding(modelID) else {
            return Tool.allCases.filter { $0 != .groundClick }.map(spec)
        }
        return specs.map { original in
            guard original["name"] as? String == Tool.click.rawValue else { return original }
            var result = original
            result["description"] = "Prefer computer_v2_ground_click with a target description for visual targets; do not guess coordinates. "
                + (original["description"] as? String ?? "")
            return result
        }
    }

    static let visualGroundingInstructions = """
        Prefer a link's supported AXPress. In Chrome, a navigation link without \
        a supported AXPress but with an observed url can be followed with \
        computer_v2_open(bundle_id="com.google.Chrome",url=<exact observed url>); \
        do not guess or reconstruct an omitted URL. Opening a URL is not equivalent \
        to activating an in-page menu or script action; verify navigation. \
        For a visible target with no supported AX action (including a listed link \
        without AXPress and without an observed url), capture once and use computer_v2_ground_click with the \
        exact capture_id and a concise target description. Prefer this over guessing \
        pixel coordinates. It returns a fresh post-action screenshot with synchronized \
        Accessibility when available; verify the visible outcome, not just dispatch.
        """

    static func validate(
        tool name: String,
        arguments: [String: Any]
    ) throws -> ValidatedCall {
        guard let tool = Tool(rawValue: name) else {
            throw ValidationError.unknownTool(name)
        }

        switch tool {
        case .status:
            try checkKeys(arguments, required: [], allowed: [])

        case .apps:
            try checkKeys(arguments, required: [], allowed: ["query"])
            if arguments["query"] != nil {
                let query = try requiredString("query", in: arguments, maximum: 200)
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.invalid("query")
                }
            }

        case .open:
            try checkKeys(arguments, required: ["bundle_id"], allowed: ["bundle_id", "url", "browser_mode", "activation"])
            let bundleID = try requiredString("bundle_id", in: arguments, maximum: 255)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
            // Keep this explicit: the shipped optimized binary inverted the
            // allSatisfy(bound-method) predicate and rejected valid app IDs.
            for scalar in bundleID.unicodeScalars {
                if !allowed.contains(scalar) {
                    throw ValidationError.invalid("bundle_id")
                }
            }
            if arguments["activation"] != nil {
                let raw = try requiredString("activation", in: arguments)
                guard let mode = ActivationMode(rawValue: raw) else { throw ValidationError.invalid("activation") }
                if mode == .none, arguments["url"] != nil || arguments["browser_mode"] as? String == "isolated" {
                    throw ValidationError.invalid("activation")
                }
            }
            if arguments["url"] != nil {
                let rawURL = try requiredString("url", in: arguments, maximum: 8_192)
                guard let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https", "file"].contains(scheme)
                else { throw ValidationError.invalid("url") }
            }
            if arguments["browser_mode"] != nil {
                let rawMode = try requiredString("browser_mode", in: arguments)
                guard bundleID == "com.google.Chrome", let mode = BrowserMode(rawValue: rawMode) else {
                    throw ValidationError.invalid("browser_mode")
                }
                if mode == .isolated, arguments["url"] == nil {
                    throw ValidationError.missing("url")
                }
            }

        case .tabs:
            try checkKeys(arguments, required: [], allowed: ["cursor", "page_size"])
            if arguments["cursor"] != nil { try requireUUID("cursor", in: arguments) }
            if arguments["page_size"] != nil {
                guard (1...100).contains(try integer("page_size", in: arguments)) else {
                    throw ValidationError.invalid("page_size")
                }
            }

        case .bindTab:
            try checkKeys(arguments, required: ["candidate_token"], allowed: ["candidate_token"])
            try requireUUID("candidate_token", in: arguments)

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
        let uuid: [String: Any] = ["type": "string", "format": "uuid", "minLength": 36, "maxLength": 36]
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
            properties = ["query": string]; required = []
            description = "List user-facing running apps compactly. Optional query searches names/bundle IDs of all running apps, including helpers. If you know bundle_id, open directly without listing."
        case .open:
            properties = [
                "bundle_id": string,
                "activation": ["type": "string", "enum": ActivationMode.allCases.map(\.rawValue),
                               "description": "none binds an already-running app's selected window without launch, activation or navigation; no url or isolated mode allowed. Use for non-interrupting background AX work. Default foreground preserves launch/navigation behavior."],
                "url": ["type": "string", "description": "Omit to use the current window/tab. A nonempty URL opens a new tab in normal Chrome."],
                "browser_mode": ["type": "string", "enum": BrowserMode.allCases.map(\.rawValue),
                                 "description": "Chrome only. Default existing uses the user's normal Chrome and logins. isolated requires a URL and an explicit user request for a separate profile."],
            ]; required = ["bundle_id"]
            description = "Open and bind an app. Chrome (com.google.Chrome) defaults to the user's existing normal session, with its tabs and logins; omit url to inspect an already-open tab. Use browser_mode=isolated only when the user explicitly requests a separate browser profile."
        case .tabs:
            properties = [
                "cursor": uuid.merging(["description": "Opaque next_cursor from this turn's previous page. Omit to refresh; refreshing invalidates earlier cursor and candidate tokens."], uniquingKeysWith: { _, new in new }),
                "page_size": ["type": "integer", "minimum": 1, "maximum": 100, "default": 25],
            ]; required = []
            description = "List existing Chrome tabs through a native-user-approved connection; this tool cannot grant access. Inventory is complete and paginated: follow next_cursor until absent, with no query filter. Candidate tokens and cursors are opaque and valid only in this turn. Select an observed candidate_token with computer_v2_bind_tab. Preserves existing tabs and logins, with no activation, navigation or closing tabs."
        case .bindTab:
            properties = ["candidate_token": uuid]; required = ["candidate_token"]
            description = "Bind an existing Chrome tab using only a candidate_token observed from computer_v2_tabs in this turn. Requires a native-user-approved connection; this tool cannot grant access. Preserves existing tabs and logins, with no activation, navigation or closing tabs. Then use computer_v2_snapshot and supported computer_v2_ax/computer_v2_set_text actions. Global image, key and pointer paths are unavailable in a borrowed tab; do not fall back to capture/click/keypress/type."
        case .snapshot:
            properties = ["query": ["type": "string", "minLength": 1, "maxLength": 200,
                                    "description": "Optional short literal text (case-insensitive substring), not a question. Searches a larger tree when target/page text is missing/truncated."]]; required = []
            description = "Read the bound app/tab Accessibility tree; returns snapshot_id and element indices. For missing/truncated text, try a short literal query before scrolling or capturing. If the requested item's fact is absent or its association is uncertain in truncated output, make one literal query for that item before answering; never substitute another item's fact. If the observed facts answer the request, answer and stop. Lines are relevance-ranked, not page order: follow parent through the header parents map (child:parent) to group facts, never adjacency alone. sibling_heading is observed direct-sibling context, not proof of semantic ownership. Container lines may be omitted. Prefer supported AX actions for buttons and links. For a Chrome navigation link without AXPress, follow its exact observed url with computer_v2_open; never reconstruct url_omitted destinations. URL navigation is not an in-page script action. Use only listed actions. Browser fields with settable=true support computer_v2_set_text directly without focus, even when actions=[]. Only a native text field advertising AXPress supports that focus action; it does not submit."
        case .ax:
            properties = [
                "snapshot_id": string, "element_index": integer,
                "ax_action": ["type": "string", "enum": SemanticAXAction.allCases.map(\.rawValue)],
            ]
            required = ["snapshot_id", "element_index", "ax_action"]
            description = "Act on a current AX snapshot element using only its listed actions; actions=[] means no AX action. NATIVE_AX scope=bound_window supports background semantic actions, not AXRaise or global input; do not reopen merely because another app is foreground. Only a native text field advertising AXPress supports focus via AXPress; use keypress for Enter when foreground input is available. Browser fields with settable=true use computer_v2_set_text directly without focus. Native actions return a fresh AX snapshot when available; use its new snapshot_id. Brokered-tab actions require another snapshot. Verify the outcome. Approval required."
        case .setText:
            properties = ["snapshot_id": string, "element_index": integer, "text": string]
            required = ["snapshot_id", "element_index", "text"]
            description = "Set text on a current AX element with settable=true; does not submit. Browser fields support this directly without first focusing, pressing, clicking or typing, including when actions=[]. Native actions return a fresh AX snapshot when available; use its new snapshot_id. Brokered-tab actions require another snapshot. Approval required."
        case .capture:
            properties = [
                "display_id": ["type": "integer", "minimum": 1, "maximum": 4_294_967_295,
                               "description": "Usually omit: capture uses the bound app window. Only supply an observed display ID; 0 is invalid."],
                "shows_cursor": boolean,
                "include_accessibility": boolean,
            ]; required = []
            description = "Capture the focused app window for native apps; brokered Chrome tabs fail closed. Returns capture_id and image dimensions. Set include_accessibility=true for synchronized native AX. When bound with activation=none, returns only a read-only exact-window image with observation_id, no pointer/key capability and no synchronized AX."
        case .groundClick:
            properties = ["capture_id": string, "target": string]
            required = ["capture_id", "target"]
            description = "For a visible native target with no supported AX action, including a listed link without AXPress and without an observed url, locate and click using a target description rather than guessed coordinates. A navigation link's observed url is a Chrome fallback, not a replacement for supported AXPress or an in-page script action. Uses the local GoClick + GUI-Owl agreement cascade with ShowUI only on disagreement. Requires a current capture_id and native approval, then returns a fresh post-action screenshot with synchronized Accessibility when available. Verify the visible outcome; the dispatch marker alone is not success."
        case .click:
            properties = capturePoint; required = ["capture_id", "x", "y"]
            description = "Image-only click at x,y using a fresh capture_id from computer_v2_capture. Never use snapshot_id or AX screen coordinates here; use computer_v2_ax for AX targets. Then observe. Approval required."
        case .pointer:
            properties = [
                "capture_id": ["type": "string", "description": "Exact ID from the latest screenshot, never from an AX snapshot. Navigation, input, or a new AX snapshot invalidates older captures."],
                "x": ["type": "number", "minimum": 0, "description": "Required for every action, including scroll: horizontal image pixel over the intended target/scroll region."],
                "y": ["type": "number", "minimum": 0, "description": "Required for every action, including scroll: vertical image pixel over the intended target/scroll region."],
                "action": ["type": "string", "enum": PointerAction.allCases.map(\.rawValue)],
                "delta_x": integer, "delta_y": integer,
            ]
            required = ["action", "capture_id", "x", "y"]
            description = "Image-space move/double_click/right_click/scroll. Every action requires a fresh capture_id plus x and y image pixels. Scroll additionally requires delta_x and delta_y; x,y choose the scroll region. Never invent capture IDs or reuse one after navigation/input/snapshot. Approval required."
        case .keypress:
            properties = [
                "key": string,
                "modifiers": [
                    "type": "array",
                    "items": ["type": "string", "enum": KeyboardModifier.allCases.map(\.rawValue)],
                ],
            ]
            required = ["key"]
            description = "Press a key in the already-observed focused control. Returns a fresh AX snapshot when available. Verify its result; do not repeat input if observation fails. Approval required."
        case .type:
            properties = ["text": string]; required = ["text"]
            description = "Insert text into the already-observed focused control; this does not navigate or submit. To open a URL, use computer_v2_open with url, or an observed link via AX. Returns a fresh AX snapshot when available; verify the result. Approval required."
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

import AutomationCore
import CoreFoundation
import Foundation

/// A compact, versioned model-facing computer contract. This is deliberately
/// separate from the legacy `computer` function so a rollout can be compared
/// without changing old threads. A V2 executor must bind the selected app,
/// retain snapshots/captures, and check image bounds before any mutation.
enum ComputerV2ToolContract {
    static let maximumAppInventoryBytes = 3_500
    static let unboundApplicationMessage = "No native application is bound in this turn. Use computer_v2_open for the requested native app. Built-in webpages have a separate binding: use browser_tabs and browser_bind for an observed existing page, or browser_open for an authorized task-owned page, then browser_read. A built-in browser binding never authorizes a native computer read. No read or input was dispatched."

    /// Keep discovery proportional to a small local model's context. The default
    /// lists supported user-facing apps, not every system helper. A query searches
    /// all matching running apps allowed by the same target policy as dispatch.
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
                  bytes + data.count + 1 <= maximumAppInventoryBytes - 600 else { continue }
            rows.append(text)
            bytes += data.count + 1
        }
        let scope = query == nil ? "user_facing_native_apps" : "matching_running_native_apps"
        let guidance = "Use query for matching helpers or omitted apps. Bind the requested native app with computer_v2_open; webpages use browser_tabs/browser_bind or browser_open in the built-in browser."
        return "APPS scope=\(scope) matched=\(matches.count) returned=\(rows.count) omitted=\(matches.count - rows.count). "
            + guidance + "\n"
            + rows.joined(separator: "\n")
    }

    static func captureMetadata(mapper: ScreenshotCoordinateMapper) -> String {
        """
        WINDOW_CAPTURE capture_id=\(mapper.captureID.uuidString)
        image_width=\(mapper.imageWidth) image_height=\(mapper.imageHeight) coordinate_space=image_pixels
        This image shows the focused app window. The x and y for computer_v2_click or computer_v2_pointer are pixels in this image. Copy capture_id exactly; Computa maps image pixels to screen points and checks the bound window.
        """
    }

    enum Tool: String, CaseIterable {
        case status = "computer_v2_status"
        case apps = "computer_v2_apps"
        case open = "computer_v2_open"
        case continueRead = "computer_v2_continue"
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

    /// The advertised reference interface is separate from legacy execution.
    /// Validation checks shape only; the host must resolve each opaque token
    /// against its current published snapshot before validating/dispatching the
    /// corresponding legacy call. A token is never a model-supplied index.
    enum Alias: String, CaseIterable {
        case readPage = "computer_v2_read_page"
        case readRegion = "computer_v2_read_region"
        case press = "computer_v2_press"
        case fill = "computer_v2_fill"
    }

    struct ValidatedAliasCall {
        let tool: Alias
        let arguments: [String: Any]
    }

    enum PointerAction: String, CaseIterable {
        case move
        case doubleClick = "double_click"
        case rightClick = "right_click"
        case scroll
    }

    enum ActivationMode: String, CaseIterable {
        case foreground
        case none
    }

    struct ValidatedCall {
        let tool: Tool
        let arguments: [String: Any]

        var semanticRead: SemanticReadRequest {
            SemanticReadRequest(
                query: arguments["query"] as? String,
                view: (arguments["view"] as? String).flatMap(SemanticReadView.init(rawValue:)),
                cursor: arguments["cursor"] as? String,
                snapshotID: (arguments["snapshot_id"] as? String).flatMap(UUID.init(uuidString:)),
                elementIndex: (arguments["element_index"] as? NSNumber)?.intValue
            )
        }

        var activationMode: ActivationMode {
            (arguments["activation"] as? String).flatMap(ActivationMode.init(rawValue:)) ?? .none
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
        case incompleteReadSubtree

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): "Unknown computer V2 tool: \(name)"
            case .missing(let name):
                "Missing computer V2 argument: \(name)"
            case .unexpected(let name): "Unexpected computer V2 argument: \(name)"
            case .incompleteReadSubtree:
                "A subtree read needs BOTH snapshot_id and an observed element_index. For a fresh whole-page read, omit both: {\"view\":\"content\"}. To continue a partial read, call computer_v2_continue with its observed next_cursor."
            case .invalid(let name):
                if name == "ax_action" {
                    "Invalid computer V2 argument: ax_action. Use only an action listed on the current element AND supported by this tool: "
                        + SemanticAXAction.allCases.map(\.rawValue).joined(separator: ", ")
                        + ". To read hidden descendants, use computer_v2_snapshot with snapshot_id and element_index; do not invent a scroll action."
                } else {
                    "Invalid computer V2 argument: \(name)"
                }
            }
        }
    }

    /// App Server DynamicToolSpec objects. Schemas help the model, but the
    /// local Responses-compatible server does not enforce `required` fields;
    /// callers must run `validate` before dispatching any action.
    static var specs: [[String: Any]] {
        Tool.allCases.map(spec)
    }

    static func specs(
        for modelID: String,
        interactionPolicy: ComputerInteractionPolicy = .backgroundOnly
    ) -> [[String: Any]] {
        // Website prompts carry semantic text. Captures require an actual
        // image attachment transport, which browser models do not yet have.
        let available = Tool.allCases.filter {
            ($0 != .capture || !LocalModelCatalog.isWebBrowser(modelID))
        }
        func advertised(_ tool: Tool, background: Bool = false) -> [String: Any] {
            background ? backgroundSpec(tool) : spec(tool)
        }
        if interactionPolicy == .backgroundOnly {
            return available.filter { !$0.requiresGlobalInput }.map { advertised($0, background: true) }
        }
        guard LocalModelCatalog.supportsResidentVisualGrounding(modelID) else {
            return available.filter { $0 != .groundClick }.map { advertised($0) }
        }
        return available.map { tool in
            let original = advertised(tool)
            guard original["name"] as? String == Tool.click.rawValue else { return original }
            var result = original
            result["description"] = "Prefer computer_v2_ground_click with a target description for visual targets; do not guess coordinates. "
                + (original["description"] as? String ?? "")
            return result
        }
    }

    /// New thread definitions advertise one reference interface, never both
    /// aliases and their legacy counterparts. Keep specs/validate unchanged
    /// for restored threads and canonicalized calls.
    static func referenceSpecs(
        for modelID: String,
        interactionPolicy: ComputerInteractionPolicy = .backgroundOnly
    ) -> [[String: Any]] {
        specs(for: modelID, interactionPolicy: interactionPolicy).flatMap { original -> [[String: Any]] in
            switch original["name"] as? String {
            case Tool.snapshot.rawValue: return [referenceSpec(.readPage), referenceSpec(.readRegion)]
            case Tool.ax.rawValue: return [referenceSpec(.press)]
            case Tool.setText.rawValue: return [referenceSpec(.fill)]
            default:
                var result = original
                result["description"] = (original["description"] as? String ?? "")
                    .replacingOccurrences(of: "computer_v2_snapshot", with: Alias.readPage.rawValue)
                    .replacingOccurrences(of: "computer_v2_ax", with: Alias.press.rawValue)
                    .replacingOccurrences(of: "computer_v2_set_text", with: Alias.fill.rawValue)
                return [result]
            }
        }
    }

    static func instructions(for interactionPolicy: ComputerInteractionPolicy) -> String {
        let limits = interactionPolicy == .backgroundOnly
            ? "Background-only computer use is enforced by the host. Bind an already-running native app with computer_v2_open(activation=none). Do not activate apps, raise windows or send global input. A background screenshot is observation only; it grants no click or keyboard authority. Full Access does not change this policy."
            : "Bind the requested native app and use its supported Accessibility actions. For a visible native target without an available Accessibility action, use only the offered capture and input tools and verify the observed outcome."
        return limits + " Computer tools operate native apps. For webpages use the offered browser_* tools in Computa's built-in browser. A computer_v2_continue cursor belongs only to a computer read; browser_read and browser_tabs continue their own cursors."
    }

    static func validateAlias(tool name: String, arguments: [String: Any]) throws -> ValidatedAliasCall {
        guard let tool = Alias(rawValue: name) else { throw ValidationError.unknownTool(name) }
        switch tool {
        case .readPage:
            try checkKeys(arguments, required: [], allowed: ["view", "query"])
            try validateAliasRead(arguments)
        case .readRegion:
            try checkKeys(arguments, required: ["region_ref"], allowed: ["region_ref", "view", "query"])
            try requireReference("region_ref", in: arguments)
            try validateAliasRead(arguments)
        case .press:
            try checkKeys(arguments, required: ["action_ref"], allowed: ["action_ref", "postcondition"])
            try requireReference("action_ref", in: arguments)
            if arguments["postcondition"] != nil { try validateAliasPostcondition(arguments["postcondition"]) }
        case .fill:
            try checkKeys(arguments, required: ["field_ref", "text"], allowed: ["field_ref", "text"])
            try requireReference("field_ref", in: arguments)
            _ = try requiredString("text", in: arguments, maximum: 4_096)
        }
        return .init(tool: tool, arguments: arguments)
    }

    private static func validateAliasRead(_ arguments: [String: Any]) throws {
        if arguments["view"] != nil {
            guard SemanticReadView(rawValue: try requiredString("view", in: arguments)) != nil else {
                throw ValidationError.invalid("view")
            }
        }
        if arguments["query"] != nil {
            let query = try requiredString("query", in: arguments, maximum: 200)
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.invalid("query") }
        }
    }

    private static func requireReference(_ key: String, in arguments: [String: Any], path: String? = nil) throws {
        let path = path ?? key
        guard let raw = arguments[key] else { throw ValidationError.missing(path) }
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 256,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { throw ValidationError.invalid(path) }
    }

    private static func validateAliasPostcondition(_ raw: Any?) throws {
        guard let object = raw as? [String: Any],
              Set(object.keys).isSubset(of: ["kind", "region_ref", "detail_ref", "expected"]),
              let rawKind = object["kind"] as? String,
              let kind = NativeActionVerification.Kind(rawValue: rawKind),
              let expected = object["expected"] as? String, expected.utf8.count <= 4_096,
              kind == .value || !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalid("postcondition")
        }
        switch kind {
        case .value, .regionText:
            try requireReference("region_ref", in: object, path: "postcondition.region_ref")
            guard object["detail_ref"] == nil else { throw ValidationError.invalid("postcondition.detail_ref") }
        case .selection:
            guard expected == "true" else { throw ValidationError.invalid("postcondition.expected") }
            if object["region_ref"] != nil { try requireReference("region_ref", in: object, path: "postcondition.region_ref") }
            guard object["detail_ref"] == nil else { throw ValidationError.invalid("postcondition.detail_ref") }
        case .detailView:
            try requireReference("detail_ref", in: object, path: "postcondition.detail_ref")
            guard object["region_ref"] == nil else { throw ValidationError.invalid("postcondition.region_ref") }
        }
    }

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
            try checkKeys(arguments, required: ["bundle_id"], allowed: ["bundle_id", "activation"])
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
                guard ActivationMode(rawValue: raw) != nil else { throw ValidationError.invalid("activation") }
            }

        case .continueRead:
            try checkKeys(arguments, required: ["cursor"], allowed: ["cursor"])
            try requireUUID("cursor", in: arguments)

        case .snapshot:
            try checkKeys(arguments, required: [], allowed: ["query", "view", "cursor", "snapshot_id", "element_index"])
            if arguments["cursor"] != nil {
                try requireUUID("cursor", in: arguments)
                guard arguments["snapshot_id"] == nil, arguments["element_index"] == nil else {
                    throw ValidationError.invalid("cursor: cannot change the retained subtree")
                }
            }
            if arguments["view"] != nil {
                let view = try requiredString("view", in: arguments)
                guard SemanticReadView(rawValue: view) != nil else { throw ValidationError.invalid("view") }
            }
            if arguments["snapshot_id"] != nil || arguments["element_index"] != nil {
                guard arguments["snapshot_id"] != nil, arguments["element_index"] != nil else {
                    throw ValidationError.incompleteReadSubtree
                }
                try requireUUID("snapshot_id", in: arguments)
                try requireNonnegativeInteger("element_index", in: arguments)
            }
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
                allowed: ["snapshot_id", "element_index", "ax_action", "postcondition"]
            )
            try requireUUID("snapshot_id", in: arguments)
            try requireNonnegativeInteger("element_index", in: arguments)
            let action = try requiredString("ax_action", in: arguments)
            guard SemanticAXAction(rawValue: action) != nil else {
                throw ValidationError.invalid("ax_action")
            }
            _ = try nativePostcondition(in: arguments)

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

    /// Native postconditions select only observed controls/regions. Identity,
    /// baseline and proof are supplied by the host, never by these arguments.
    static func nativePostcondition(in arguments: [String: Any]) throws -> NativeActionVerification.Request? {
        guard let raw = arguments["postcondition"] else { return nil }
        guard let object = raw as? [String: Any],
              Set(object.keys).isSubset(of: ["kind", "element_index", "detail_element_index", "expected"]),
              let name = object["kind"] as? String,
              let kind = NativeActionVerification.Kind(rawValue: name),
              let expected = object["expected"] as? String, expected.utf8.count <= 4_096,
              kind == .value || !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalid("postcondition")
        }
        func index(_ key: String) throws -> Int? {
            guard object[key] != nil else { return nil }
            let value = try integer(key, in: object, path: "postcondition.\(key)")
            guard value >= 0, value <= Int64(Int.max) else { throw ValidationError.invalid("postcondition.\(key)") }
            return Int(value)
        }
        let element = try index("element_index"), detail = try index("detail_element_index")
        if kind == .value || kind == .regionText {
            guard element != nil, detail == nil else { throw ValidationError.invalid("postcondition.element_index") }
        }
        if kind == .selection {
            guard expected == "true" else { throw ValidationError.invalid("postcondition.expected") }
            guard detail == nil else { throw ValidationError.invalid("postcondition.detail_element_index") }
        }
        if kind == .detailView {
            guard detail != nil else { throw ValidationError.invalid("postcondition.detail_element_index") }
            guard element == nil else { throw ValidationError.invalid("postcondition.element_index") }
        }
        return .init(kind: kind, expected: expected, elementIndex: element, detailElementIndex: detail)
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

    private static func integer(_ key: String, in arguments: [String: Any], path: String? = nil) throws -> Int64 {
        let argumentPath = path ?? key
        guard let raw = arguments[key] else { throw ValidationError.missing(argumentPath) }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { throw ValidationError.invalid(argumentPath) }
        let value = number.int64Value
        guard number.compare(NSNumber(value: value)) == .orderedSame else {
            throw ValidationError.invalid(argumentPath)
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

    private static func referenceSpec(_ tool: Alias) -> [String: Any] {
        let reference: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 256,
            "description": "Copy the exact typed reference from the current host action/region menu; never construct one. The host checks its type, target and snapshot."]
        let view: [String: Any] = ["type": "string", "enum": ["all", "content", "headings", "links"],
            "description": "Native app text and structure. Built-in webpages use browser_read."]
        let query: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 200,
            "description": "Optional literal text filter, not a question or instruction. No filtered matches does not prove absence."]
        let properties: [String: [String: Any]]
        let required: [String]
        let description: String
        switch tool {
        case .readPage:
            properties = ["view": view, "query": query]; required = []
            description = "Read the native app already bound this turn with computer_v2_open, using all or content. An unbound read requires computer_v2_open first; computer_v2_status does not bind or read a page. Returns current host action/region references; readable structure is not an action target. Continue partial native text with computer_v2_continue(cursor=next_cursor). Webpage tasks use browser_* directly without native app discovery/status; browser_read(cursor=next_cursor) continues their own page text."
        case .readRegion:
            properties = ["region_ref": reference, "view": view, "query": query]; required = ["region_ref"]
            description = "Read below a currently published native region_ref. This is read-only context, not an action target. Refresh the native app with computer_v2_read_page; continue its partial text with computer_v2_continue. Built-in browser cursors belong to browser_read."
        case .fill:
            properties = ["field_ref": reference, "text": ["type": "string", "minLength": 1, "maxLength": 4_096]]
            required = ["field_ref", "text"]
            description = "Set the currently published editable native field_ref to text. Does not submit. The host checks its reference and permission, dispatches once and verifies the value. Use browser_fill for a built-in webpage field; its snapshot indices are a separate domain."
        case .press:
            properties = ["action_ref": reference, "postcondition": referencePostconditionSchema(reference: reference)]
            required = ["action_ref"]
            description = "Perform the exact native action bound to a current action_ref. Declare any required native postcondition before input; the host checks permission and dispatches at most once. VERIFIED_PROPERTY proves only its declared property; VERIFICATION_PENDING allows read-only recovery, not replay. Built-in webpages use browser_click with their current snapshot_id and element_index."
        }
        let result: [String: Any] = ["type": "function", "name": tool.rawValue, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        return result
    }

    private static func referencePostconditionSchema(reference: [String: Any]) -> [String: Any] {
        ["type": "object", "additionalProperties": false,
         "properties": [
            "kind": ["type": "string", "enum": ["value", "region_text", "detail_view", "selection"]],
            "region_ref": reference,
            "detail_ref": reference.merging(["description": "Copy the region_ref of the separate observed detail pane."], uniquingKeysWith: { _, new in new }),
            "expected": ["type": "string", "maxLength": 4_096],
         ], "required": ["kind", "expected"],
         "oneOf": [
            ["properties": ["kind": ["enum": ["value"]]], "required": ["region_ref"], "not": ["required": ["detail_ref"]]],
            ["properties": ["kind": ["enum": ["region_text"]], "expected": ["minLength": 1, "pattern": "\\S"]], "required": ["region_ref"], "not": ["required": ["detail_ref"]]],
            ["properties": ["kind": ["enum": ["selection"]], "expected": ["enum": ["true"]]], "not": ["required": ["detail_ref"]]],
            ["properties": ["kind": ["enum": ["detail_view"]], "expected": ["minLength": 1, "pattern": "\\S"]], "required": ["detail_ref"], "not": ["required": ["region_ref"]]],
         ],
         "description": "Declare the intended native result before input using current observed references. value/region_text require a region_ref and exact expected value. selection requires expected=true and proves only selection. detail_view requires a separate observed detail_ref and exact expected content. The host verifies eligibility, permission and bounded fresh results without replaying input."]
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
            description = "Report permissions and route/binding metadata only. computer_v2_status does not bind an app, read a page, or issue observation references. An unbound native read requires computer_v2_open first. Webpage tasks use browser_* directly without native app discovery or status. This tool cannot grant permissions or change the requested target."
        case .apps:
            // Spell out Foundation's whitespace set rather than relying on
            // provider regex \s semantics. JSON Schema maxLength counts code
            // points, not requiredString's extended grapheme clusters.
            properties = ["query": [
                "type": "string", "minLength": 1,
                "pattern": "[^\\u0009-\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000-\\u200B\\u2028\\u2029\\u202F\\u205F\\u3000]",
                "description": "Nonblank app-name or bundle-ID filter, at most 200 characters (extended grapheme clusters). Omit this field for an unfiltered listing; never send an empty or whitespace-only string.",
            ]]; required = []
            description = "List user-facing running apps compactly. Optional query searches names/bundle IDs of all running apps, including helpers. Omit query for an unfiltered listing. If you know bundle_id, open directly without listing."
        case .open:
            properties = [
                "bundle_id": string,
                "activation": ["type": "string", "enum": ActivationMode.allCases.map(\.rawValue),
                               "description": "Default none binds an already-running app's selected window without launch, activation or navigation. Foreground activation is available only when the host's interaction policy explicitly permits it."],
            ]; required = ["bundle_id"]
            description = "Bind the requested native app using the offered activation mode and host policy. This tool does not navigate webpages. Use browser_tabs/browser_bind for an existing built-in page or browser_open for a task-owned page."
        case .continueRead:
            properties = ["cursor": uuid]; required = ["cursor"]
            description = "Continue only a current native computer read with its observed next_cursor. Send cursor alone. Built-in browser_read cursors must use browser_read(cursor=next_cursor); browser_tabs inventory cursors must use browser_tabs(cursor=next_cursor). Never cross sources or reuse previous-turn cursors. No input, navigation or reconnect occurs."
        case .snapshot:
            properties = [
                "query": ["type": "string", "minLength": 1, "maxLength": 200,
                          "description": "Optional literal text to find known missing/truncated text, not a question or extraction instruction. To discover unknown titles use view=headings or content."],
                "view": ["type": "string", "enum": ["all", "overview", "content", "headings", "links"],
                         "description": "overview: browser-only bounded controls, headings and navigation, not exhaustive content; all: full structural context; content: readable document; headings/links: enumerate unknown labels. Browser default with no query/subtree is overview; native default remains all."],
                "cursor": ["type": "string", "description": "Legacy page-read continuation only. Prefer computer_v2_continue(cursor=next_cursor); never supply a tab-inventory cursor here."],
                "snapshot_id": ["type": "string", "description": "Subtree read only: BOTH snapshot_id and element_index are required. Omit both for a fresh whole-page read or a different view."],
                "element_index": ["type": "integer", "minimum": 0, "description": "Observed current element to read below; not a guessed index."],
            ]; required = []
            description = "Read the native app already bound with computer_v2_open, using all or content. computer_v2_status does not bind or read a page; an unbound read requires computer_v2_open first. Fresh reads omit snapshot_id and element_index; a subtree requires both from a current observation. Continue native text with computer_v2_continue. Use only observed supported actions and verify their results. Webpage tasks use browser_* directly without native app discovery/status; their pages and cursors belong to browser_read."
        case .ax:
            properties = [
                "snapshot_id": string,
                "element_index": ["type": "integer", "minimum": 0],
                "ax_action": ["type": "string", "enum": SemanticAXAction.allCases.map(\.rawValue)],
                "postcondition": [
                    "type": "object", "additionalProperties": false,
                    "properties": [
                        "kind": ["type": "string", "enum": ["value", "region_text", "detail_view", "selection"]],
                        "element_index": ["type": "integer", "minimum": 0],
                        "detail_element_index": ["type": "integer", "minimum": 0],
                        "expected": ["type": "string", "maxLength": 4096],
                    ],
                    "required": ["kind", "expected"],
                    "description": "Declare the intended native result before input. value/region_text use the observed result element_index. detail_view requires a separate observed detail_element_index and no element_index. selection requires expected=true and proves only selection. Never reuse old indices with a new snapshot_id.",
                ],
            ]
            required = ["snapshot_id", "element_index", "ax_action"]
            description = "Act on a currently exposed native element using only a listed action. Declare a required native postcondition before input; selected controls may have an automatic verification plan. Runtime dispatches at most once and verifies with fresh reads. VERIFIED_PROPERTY proves only that property; ALREADY_SATISFIED means no input occurred. VERIFICATION_PENDING allows only read-only recovery. A new snapshot_id never makes an old element_index valid. Background AX cannot raise windows or post global input. Use set_text directly for settable fields. Approval follows the user's access mode. Built-in webpages use browser_click."
        case .setText:
            properties = ["snapshot_id": string, "element_index": integer, "text": string]
            required = ["snapshot_id", "element_index", "text"]
            description = "Set text on a currently exposed settable=true field; does not submit. No preliminary press or focus is needed. Background-native values are automatically verified against the requested text. VERIFIED_PROPERTY needs no further verification; ALREADY_SATISFIED means no input was needed. Do not repeat an unverified action. Approval follows the user's access mode."
        case .capture:
            properties = [
                "display_id": ["type": "integer", "minimum": 1, "maximum": 4_294_967_295,
                               "description": "Usually omit: capture uses the bound app window. Only supply an observed display ID; 0 is invalid."],
                "shows_cursor": boolean,
                "include_accessibility": boolean,
            ]; required = []
            description = "Capture the focused app window for native apps. Returns capture_id and image dimensions. Set include_accessibility=true for synchronized native AX. When bound with activation=none, returns only a read-only exact-window image with observation_id, no pointer/key capability and no synchronized AX."
        case .groundClick:
            properties = ["capture_id": string, "target": string]
            required = ["capture_id", "target"]
            description = "For a visible native target with no supported AX action, including a listed link without AXPress and without an observed url, locate and click using a target description rather than guessed coordinates. Uses the local GoClick + GUI-Owl agreement cascade with ShowUI only on disagreement. Requires a current capture_id and native approval, then returns a fresh post-action screenshot with synchronized Accessibility when available. Verify the visible outcome; the dispatch marker alone is not success."
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
            description = "Insert text into the already-observed focused control; this does not navigate or submit. Webpage navigation uses browser_* tools. Returns a fresh AX snapshot when available; verify the result. Approval required."
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

    private static func backgroundSpec(_ tool: Tool) -> [String: Any] {
        var result = spec(tool)
        switch tool {
        case .open:
            result["description"] = "Bind an already-running native app without launch, activation or navigation. Default activation=none; the host enforces background-only operation. Webpage tasks use browser_* tools. If the app or selected window is unavailable, report that limitation; do not try to gain focus or open another tab."
            result["inputSchema"] = [
                "type": "object",
                "properties": [
                    "bundle_id": ["type": "string"],
                    "activation": ["type": "string", "enum": ["none"], "default": "none"],
                ],
                "required": ["bundle_id"],
                "additionalProperties": false,
            ]
        case .ax:
            if var schema = result["inputSchema"] as? [String: Any],
               var properties = schema["properties"] as? [String: [String: Any]] {
                properties["ax_action"] = [
                    "type": "string",
                    "enum": SemanticAXAction.allCases.filter { $0.rawValue != "AXRaise" }.map(\.rawValue),
                ]
                schema["properties"] = properties
                result["inputSchema"] = schema
            }
            result["description"] = (result["description"] as? String ?? "")
                + " Background-only is enforced: no reopening to gain focus, keyboard fallback, or AXRaise."
        case .capture:
            result["description"] = "Read-only capture of the exact bound native app window without activation. Returns observation_id and image dimensions, not capture_id or pointer/key capability. This image is perception only: it does not authorize clicks, keyboard input, or a foreground fallback. No synchronized AX is returned."
        default:
            break
        }
        return result
    }
}

import AutomationCore
import CoreFoundation
import Foundation

/// A compact, versioned model-facing computer contract. This is deliberately
/// separate from the legacy `computer` function so a rollout can be compared
/// without changing old threads. A V2 executor must bind the selected app,
/// retain snapshots/captures, and check image bounds before any mutation.
enum ComputerV2ToolContract {
    /// A complete argument shape, not fabricated IDs or dispatch authority.
    /// Replace every placeholder only with values exposed in one current read.
    static let regionChangedPressArgumentShape = #"{"snapshot_id":"<observed snapshot_id>","element_index":<observed button index>,"ax_action":"AXPress","postcondition":{"kind":"region_changed","element_index":<observed container index>}}"#
    static let regionChangedIndexGuidance = "Top-level element_index is the button to press; postcondition.element_index is the separate observed result container. Complete region_changed argument shape (replace placeholders with observed values from the same snapshot): " + regionChangedPressArgumentShape
    static let maximumAppInventoryBytes = 3_500
    static let unboundApplicationMessage = "No application is bound in this turn. Call computer_v2_open, or use computer_v2_tabs then computer_v2_bind_tab for an existing Chrome tab through a native-user-approved connection."
    static func unboundApplicationMessage(externalChromeTools: Bool) -> String {
        if externalChromeTools { return unboundApplicationMessage }
        return "No native application is bound in this turn. Use computer_v2_open for the requested native app. Built-in webpages have a separate binding: use browser_tabs and browser_bind for an observed existing page, or browser_open for an authorized task-owned page, then browser_read. A built-in browser binding never authorizes a native computer read. No read or input was dispatched."
    }
    static let existingBrowserSessionNote = browserSessionNote(activationMode: .none)
    static func browserSessionNote(activationMode: ActivationMode) -> String {
        "\nBROWSER_SESSION profile=existing ordinary_profile_access=true tab_broker=false open_activation=\(activationMode.rawValue). Existing tabs and logins are preserved. For webpage content prefer computer_v2_tabs then computer_v2_bind_tab with an observed candidate_token; that reads the page directly without native window wrappers. If browser connection is unavailable, use snapshot view=content. Native AX may work in background. With activation=none, capture is an observation-only image and grants no input authority. Actionable capture and global key/pointer input still require foreground and are unavailable in a non-activating binding. This is not a task-isolated browser tab."
    }

    /// Keep discovery proportional to a small local model's context. The default
    /// lists supported user-facing apps, not every system helper. A query searches
    /// all matching running apps allowed by the same target policy as dispatch.
    static func appInventory(_ applications: [RunningApplicationInfo], query: String?,
                             externalChromeTools: Bool = false) -> String {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = applications.filter { app in
            guard app.processIdentifier > 0, !app.isTerminated else { return false }
            guard externalChromeTools || !ComputaModelToolCatalog.isExternalChromeTarget(bundleID: app.bundleIdentifier) else { return false }
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
                  bytes + data.count + 1 <= maximumAppInventoryBytes - (externalChromeTools ? 400 : 600) else { continue }
            rows.append(text)
            bytes += data.count + 1
        }
        let scope = externalChromeTools ? (query == nil ? "user_facing" : "all_matching_running_apps")
            : (query == nil ? "supported_user_facing_native_apps" : "supported_matching_running_native_apps")
        let guidance = externalChromeTools
            ? "Use query with a name or bundle_id to find helpers or omitted apps. Known bundle_id: open directly; no listing needed."
            : "Only currently supported native app targets are listed; omission does not prove an app is not running. Use query for matching supported helpers or omitted apps. Bind the requested native app with computer_v2_open; webpages use browser_tabs/browser_bind or browser_open in the built-in browser."
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
        case tabs = "computer_v2_tabs"
        case continueRead = "computer_v2_continue"
        case bindTab = "computer_v2_bind_tab"
        case createWorkspace = "computer_v2_create_workspace"
        case snapshot = "computer_v2_snapshot"
        case followLink = "computer_v2_follow_link"
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
        case follow = "computer_v2_follow"
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

        var semanticRead: SemanticReadRequest {
            SemanticReadRequest(
                query: arguments["query"] as? String,
                view: (arguments["view"] as? String).flatMap(SemanticReadView.init(rawValue:)),
                cursor: arguments["cursor"] as? String,
                snapshotID: (arguments["snapshot_id"] as? String).flatMap(UUID.init(uuidString:)),
                elementIndex: (arguments["element_index"] as? NSNumber)?.intValue
            )
        }

        var tabPageSize: Int {
            (arguments["page_size"] as? NSNumber)?.intValue ?? 25
        }

        var activationMode: ActivationMode {
            (arguments["activation"] as? String).flatMap(ActivationMode.init(rawValue:)) ?? .none
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
        case incompleteReadSubtree

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): "Unknown computer V2 tool: \(name)"
            case .missing(let name):
                "Missing computer V2 argument: \(name)"
                    + (name == "postcondition.element_index" ? ". " + ComputerV2ToolContract.regionChangedIndexGuidance : "")
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
        interactionPolicy: ComputerInteractionPolicy = .backgroundOnly,
        externalChromeTools: Bool = false
    ) -> [[String: Any]] {
        // Website prompts carry semantic text. Captures require an actual
        // image attachment transport, which browser models do not yet have.
        let available = Tool.allCases.filter {
            ($0 != .capture || !LocalModelCatalog.isWebBrowser(modelID))
                && (externalChromeTools || ![Tool.tabs, .bindTab, .createWorkspace, .followLink].contains($0))
        }
        func advertised(_ tool: Tool, background: Bool = false) -> [String: Any] {
            let original = background ? backgroundSpec(tool) : spec(tool)
            return externalChromeTools ? original : nativeOnlySpec(original, tool: tool)
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
        interactionPolicy: ComputerInteractionPolicy = .backgroundOnly,
        externalChromeTools: Bool = false
    ) -> [[String: Any]] {
        specs(for: modelID, interactionPolicy: interactionPolicy, externalChromeTools: externalChromeTools).flatMap { original -> [[String: Any]] in
            switch original["name"] as? String {
            case Tool.snapshot.rawValue: return [referenceSpec(.readPage, externalChromeTools: externalChromeTools), referenceSpec(.readRegion, externalChromeTools: externalChromeTools)]
            case Tool.ax.rawValue: return [referenceSpec(.press, externalChromeTools: externalChromeTools)]
            case Tool.followLink.rawValue: return [referenceSpec(.follow, externalChromeTools: externalChromeTools)]
            case Tool.setText.rawValue: return [referenceSpec(.fill, externalChromeTools: externalChromeTools)]
            default:
                var result = original
                if original["name"] as? String == Tool.bindTab.rawValue {
                    result["description"] = "Bind an existing Chrome tab with an observed candidate_token from this turn's inventory. Requires the user's existing approved connection; preserves tabs and logins without activation. Start with computer_v2_read_page(view=overview), then read content when needed. Use only the returned action menu references. Borrowed tabs have no capture, pointer, global keyboard or foreground fallback."
                } else {
                    result["description"] = (original["description"] as? String ?? "")
                        .replacingOccurrences(of: "computer_v2_snapshot", with: Alias.readPage.rawValue)
                        .replacingOccurrences(of: "computer_v2_ax", with: Alias.press.rawValue)
                        .replacingOccurrences(of: "computer_v2_set_text", with: Alias.fill.rawValue)
                        .replacingOccurrences(of: "computer_v2_follow_link", with: Alias.follow.rawValue)
                }
                return [result]
            }
        }
    }

    static func instructions(for interactionPolicy: ComputerInteractionPolicy, externalChromeTools: Bool = false) -> String {
        if externalChromeTools { return interactionPolicy == .backgroundOnly ? backgroundInstructions : visualGroundingInstructions }
        let limits = interactionPolicy == .backgroundOnly
            ? "Background-only computer use is enforced by the host. Bind an already-running native app with computer_v2_open(activation=none). Do not activate apps, raise windows or send global input. A background screenshot is observation only; it grants no click or keyboard authority. Full Access does not change this policy."
            : "Bind the requested native app and use its supported Accessibility actions. For a visible native target without an available Accessibility action, use only the offered capture and input tools and verify the observed outcome."
        return limits + " Computer tools operate native apps. For webpages use the offered browser_* tools in Computa's built-in browser. A computer_v2_continue cursor belongs only to a computer read; browser_read and browser_tabs continue their own cursors."
    }

    static let backgroundInstructions = """
        Background-only computer use is enforced by the host, including after \
        follow-ups or compaction. Bind an already-running app with computer_v2_open \
        (activation=none), or use computer_v2_tabs then computer_v2_bind_tab for \
        existing authorized Chrome tabs. Use fresh snapshot elements and only \
        supported AX actions or settable text fields. Do not reopen to gain focus, \
        raise windows, send global input, or navigate with native open. A background \
        screenshot is observation only; it grants no click or keyboard authority. \
        If no supported background action exists, report that capability limitation \
        instead of attempting foreground fallbacks or unchanged retries. Full Access \
        does not change this policy. Verify the observed outcome before claiming success.
        """

    static let visualGroundingInstructions = """
        Prefer a link's supported AXPress. In Chrome, a navigation link without \
        a supported AXPress but with an observed url can be followed with \
        computer_v2_open(bundle_id="com.google.Chrome",activation="foreground",url=<exact observed url>); \
        do not guess or reconstruct an omitted URL. Opening a URL is not equivalent \
        to activating an in-page menu or script action; verify navigation. \
        For a visible target with no supported AX action (including a listed link \
        without AXPress and without an observed url), capture once and use computer_v2_ground_click with the \
        exact capture_id and a concise target description. Prefer this over guessing \
        pixel coordinates. It returns a fresh post-action screenshot with synchronized \
        Accessibility when available; verify the visible outcome, not just dispatch.
        """

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
        case .follow:
            try checkKeys(arguments, required: ["link_ref"], allowed: ["link_ref"])
            try requireReference("link_ref", in: arguments)
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
              let kind = object["kind"] as? String,
              ["document_url", "value", "region_text", "region_changed", "dialog_opened", "detail_view", "selection"].contains(kind)
        else { throw ValidationError.invalid("postcondition") }
        if kind == "region_changed" || kind == "dialog_opened" {
            guard object["expected"] == nil else { throw ValidationError.invalid("postcondition.expected") }
        } else {
            guard let expected = object["expected"] as? String, expected.utf8.count <= 4_096,
                  kind == "value" || !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.invalid("postcondition.expected")
            }
            if kind == "selection", expected != "true" { throw ValidationError.invalid("postcondition.expected") }
        }
        switch kind {
        case "value", "region_text", "region_changed":
            try requireReference("region_ref", in: object, path: "postcondition.region_ref")
            guard object["detail_ref"] == nil else { throw ValidationError.invalid("postcondition.detail_ref") }
        case "selection":
            if object["region_ref"] != nil { try requireReference("region_ref", in: object, path: "postcondition.region_ref") }
            guard object["detail_ref"] == nil else { throw ValidationError.invalid("postcondition.detail_ref") }
        case "detail_view":
            // Browser detail_view uses the observed heading; native detail_view
            // additionally requires a separately observed pane at dispatch.
            if object["detail_ref"] != nil { try requireReference("detail_ref", in: object, path: "postcondition.detail_ref") }
            guard object["region_ref"] == nil else { throw ValidationError.invalid("postcondition.region_ref") }
        default:
            guard object["region_ref"] == nil, object["detail_ref"] == nil else { throw ValidationError.invalid("postcondition") }
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

        case .continueRead:
            try checkKeys(arguments, required: ["cursor"], allowed: ["cursor"])
            try requireUUID("cursor", in: arguments)

        case .bindTab, .createWorkspace:
            try checkKeys(arguments, required: ["candidate_token"], allowed: ["candidate_token"])
            try requireUUID("candidate_token", in: arguments)

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

        case .followLink:
            try checkKeys(arguments, required: ["snapshot_id", "element_index"],
                          allowed: ["snapshot_id", "element_index"])
            try requireUUID("snapshot_id", in: arguments)
            try requireNonnegativeInteger("element_index", in: arguments)

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
            if let object = arguments["postcondition"] as? [String: Any],
               object["kind"] as? String == "selection" || object["detail_element_index"] != nil {
                _ = try nativePostcondition(in: arguments)
            } else {
                _ = try browserPostcondition(in: arguments)
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

    /// A model may describe an expected result, but cannot supply its baseline,
    /// target authority, or proof. Those are captured by the browser runtime.
    static func browserPostcondition(in arguments: [String: Any]) throws -> BrowserActionVerification.Request? {
        guard let raw = arguments["postcondition"] else { return nil }
        guard let object = raw as? [String: Any],
              Set(object.keys).isSubset(of: ["kind", "element_index", "expected"]),
              let kindText = object["kind"] as? String,
              let kind = BrowserActionVerification.Kind(rawValue: kindText) else {
            throw ValidationError.invalid("postcondition")
        }
        let expected: String
        if kind == .regionChanged || kind == .dialogOpened {
            // The host owns the change predicate and its pre-input baseline;
            // callers cannot submit a fabricated future result or baseline.
            guard object["expected"] == nil else { throw ValidationError.invalid("postcondition.expected") }
            expected = kind == .dialogOpened ? "opened" : "changed"
        } else {
            guard let value = object["expected"] as? String, value.utf8.count <= 4_096,
                  kind == .value || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.invalid("postcondition")
            }
            expected = value
        }
        let index: Int?
        if kind == .value || kind == .regionText || kind == .regionChanged {
            let value = try integer("element_index", in: object, path: "postcondition.element_index")
            guard value >= 0, value <= Int64(Int.max) else { throw ValidationError.invalid("postcondition.element_index") }
            index = Int(value)
        } else {
            guard object["element_index"] == nil else { throw ValidationError.invalid("postcondition.element_index") }
            index = nil
        }
        return .init(kind: kind, elementIndex: index, expected: expected)
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

    private static func referenceSpec(_ tool: Alias, externalChromeTools: Bool) -> [String: Any] {
        let reference: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 256,
            "description": "Copy the exact typed reference from the current host action/region menu; never construct one. The host checks its type, target and snapshot."]
        let view: [String: Any] = ["type": "string", "enum": ["all", "overview", "content", "headings", "links"],
            "description": "Browser overview locates controls/headings/navigation; it is not complete content. Use content for the body, all for structure. Native apps use all or content."]
        let query: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 200,
            "description": "Optional literal text filter, not a question or instruction. No filtered matches does not prove absence."]
        let properties: [String: [String: Any]]
        let required: [String]
        let description: String
        switch tool {
        case .readPage:
            properties = ["view": view, "query": query]; required = []
            description = "Take a fresh read of the bound app/tab. An unfiltered browser read defaults to overview; use content when the body is needed. Native: all or content. Returns content, coverage and a host action/region menu. Read-only structure is not an action target. For a stale reference, read_page once and use only newly returned references. For partial text, use computer_v2_continue(cursor=next_cursor); do not restart unchanged reads. This tool accepts no reference, snapshot or cursor."
        case .readRegion:
            properties = ["region_ref": reference, "view": view, "query": query]; required = ["region_ref"]
            description = "Read below a currently published region_ref, including a readable result element. Defaults to all within that region. This is read-only and does not activate it. To refresh the whole page or change views without a region, use computer_v2_read_page. Continue partial text with computer_v2_continue and its next_cursor. A region reference alone does not authorize an action or prove a region_changed postcondition."
        case .follow:
            properties = ["link_ref": reference]; required = ["link_ref"]
            description = "Follow a browser navigation link from the current action menu. Send only link_ref. The host uses its exact observed destination, obtains required approval, dispatches once and verifies navigation. Do not provide a URL or postcondition. Then inspect the destination before making a content claim."
        case .fill:
            properties = ["field_ref": reference, "text": ["type": "string", "minLength": 1, "maxLength": 4_096]]
            required = ["field_ref", "text"]
            description = "Set a currently published editable field to text, without pressing or focusing it first. Does not submit or search. The host checks the reference, obtains required approval and verifies the requested value. Do not repeat VERIFIED_PROPERTY or ALREADY_SATISFIED."
        case .press:
            properties = ["action_ref": reference, "postcondition": referencePostconditionSchema(reference: reference)]
            required = ["action_ref"]
            description = "Perform the exact supported action bound to a current action_ref; no action-name or element-index guessing. Browser non-link presses require an intended postcondition, including search/pagination buttons. Native selected controls may have an automatic plan. For browser links with link_ref use computer_v2_follow; for editable fields use computer_v2_fill. The host obtains required approval, dispatches at most once and checks bounded fresh observations. VERIFIED_PROPERTY proves only that property; ALREADY_SATISFIED sent no input. VERIFICATION_PENDING permits bounded read-only recovery, never replaying the action."
        }
        var result: [String: Any] = ["type": "function", "name": tool.rawValue, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        if !externalChromeTools {
            switch tool {
            case .readPage:
                result["description"] = "Read the native app already bound this turn with computer_v2_open, using all or content. An unbound read requires computer_v2_open first; computer_v2_status does not bind or read a page. Returns current host action/region references; readable structure is not an action target. Continue partial native text with computer_v2_continue(cursor=next_cursor). Webpage tasks use browser_* directly without native app discovery/status; browser_read(cursor=next_cursor) continues their own page text."
            case .readRegion:
                result["description"] = "Read below a currently published native region_ref. This is read-only context, not an action target. Refresh the native app with computer_v2_read_page; continue its partial text with computer_v2_continue. Built-in browser cursors belong to browser_read."
            case .fill:
                result["description"] = "Set the currently published editable native field_ref to text. Does not submit. The host checks its reference and permission, dispatches once and verifies the value. Use browser_fill for a built-in webpage field; its snapshot indices are a separate domain."
            case .press:
                result["description"] = "Perform the exact native action bound to a current action_ref. Declare any required native postcondition before input; the host checks permission and dispatches at most once. VERIFIED_PROPERTY proves only its declared property; VERIFICATION_PENDING allows read-only recovery, not replay. Built-in webpages use browser_click with their current snapshot_id and element_index."
            case .follow: break // Not present in the disabled catalog.
            }
            var schema = result["inputSchema"] as! [String: Any]
            var nativeProperties = schema["properties"] as! [String: Any]
            if var nativeView = nativeProperties["view"] as? [String: Any] {
                nativeView["enum"] = ["all", "content", "headings", "links"]
                nativeView["description"] = "Native app text and structure. Built-in webpages use browser_read."
                nativeProperties["view"] = nativeView
            }
            if var postcondition = nativeProperties["postcondition"] as? [String: Any] {
                postcondition["description"] = "Declare the intended native result before input using current observed region references. A selected control proves only selection; a separate detail pane proves only its verified content. The host checks target eligibility and retains at-most-once input and bounded recovery."
                nativeProperties["postcondition"] = postcondition
            }
            schema["properties"] = nativeProperties; result["inputSchema"] = schema
        }
        return result
    }

    private static func nativeOnlySpec(_ original: [String: Any], tool: Tool) -> [String: Any] {
        var result = original
        switch tool {
        case .status:
            result["description"] = "Report permissions and route/binding metadata only. computer_v2_status does not bind an app, read a page, or issue observation references. An unbound native read requires computer_v2_open first. Webpage tasks use browser_* directly without native app discovery or status. This tool cannot grant permissions or change the requested target."
        case .open:
            var schema = result["inputSchema"] as! [String: Any]
            var properties = schema["properties"] as! [String: Any]
            properties.removeValue(forKey: "url"); properties.removeValue(forKey: "browser_mode")
            schema["properties"] = properties; result["inputSchema"] = schema
            result["description"] = "Bind the requested native app using the offered activation mode and host policy. This tool does not navigate webpages. Use browser_tabs/browser_bind for an existing built-in page or browser_open for a task-owned page."
        case .continueRead:
            result["description"] = "Continue only a current native computer read with its observed next_cursor. Send cursor alone. Built-in browser_read cursors must use browser_read(cursor=next_cursor); browser_tabs inventory cursors must use browser_tabs(cursor=next_cursor). Never cross sources or reuse previous-turn cursors. No input, navigation or reconnect occurs."
        case .snapshot:
            result["description"] = "Read the native app already bound with computer_v2_open, using all or content. computer_v2_status does not bind or read a page; an unbound read requires computer_v2_open first. Fresh reads omit snapshot_id and element_index; a subtree requires both from a current observation. Continue native text with computer_v2_continue. Use only observed supported actions and verify their results. Webpage tasks use browser_* directly without native app discovery/status; their pages and cursors belong to browser_read."
        case .capture:
            result["description"] = (result["description"] as? String ?? "")
                .replacingOccurrences(of: "brokered Chrome tabs fail closed. ", with: "")
        case .groundClick:
            result["description"] = (result["description"] as? String ?? "")
                .replacingOccurrences(of: "A navigation link's observed url is a Chrome fallback, not a replacement for supported AXPress or an in-page script action. ", with: "")
        default: break
        }
        return result
    }

    private static func referencePostconditionSchema(reference: [String: Any]) -> [String: Any] {
        ["type": "object", "additionalProperties": false,
         "properties": [
            "kind": ["type": "string", "enum": ["document_url", "value", "region_text", "region_changed", "dialog_opened", "detail_view", "selection"]],
            "region_ref": reference,
            "detail_ref": reference.merging(["description": "Native detail_view only: copy the region_ref of the separate observed detail pane."], uniquingKeysWith: { _, new in new }),
            "expected": ["type": "string", "maxLength": 4_096],
         ], "required": ["kind"],
         "oneOf": [
            ["properties": ["kind": ["enum": ["region_changed"]]], "required": ["region_ref"],
             "not": ["anyOf": [["required": ["expected"]], ["required": ["detail_ref"]]]]],
            ["properties": ["kind": ["enum": ["dialog_opened"]]],
             "not": ["anyOf": [["required": ["expected"]], ["required": ["region_ref"]], ["required": ["detail_ref"]]]]],
            ["properties": ["kind": ["enum": ["value"]]], "required": ["region_ref", "expected"],
             "not": ["required": ["detail_ref"]]],
            ["properties": ["kind": ["enum": ["region_text"]], "expected": ["minLength": 1, "pattern": "\\S"]], "required": ["region_ref", "expected"],
             "not": ["required": ["detail_ref"]]],
            ["properties": ["kind": ["enum": ["selection"]], "expected": ["enum": ["true"]]], "required": ["expected"],
             "not": ["required": ["detail_ref"]]],
            ["properties": ["kind": ["enum": ["detail_view"]], "expected": ["minLength": 1, "pattern": "\\S"]], "required": ["expected"],
             "not": ["required": ["region_ref"]]],
            ["properties": ["kind": ["enum": ["document_url"]], "expected": ["minLength": 1, "pattern": "\\S"]], "required": ["expected"],
             "not": ["anyOf": [["required": ["region_ref"]], ["required": ["detail_ref"]]]]],
         ],
         "description": "Declare before input. region_changed: use an observed eligible region_ref and omit expected; proves changed text only, so read it afterward. dialog_opened: kind alone, no refs/expected. value/region_text: region_ref plus exact intended expected. Native selection: expected=\"true\", optional region_ref; proves selection only. Native detail_view: separate detail_ref plus exact expected; browser detail_view: exact observed heading, no detail_ref. document_url: exact observed link destination. The host enforces target-specific eligibility; references and schema never supply proof or authority."]
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
                               "description": "Default none binds an already-running app's selected window without launch, activation or navigation; no url or isolated mode allowed. Foreground activation is available only when the host's interaction policy explicitly permits it."],
                "url": ["type": "string", "description": "Requires explicit activation=foreground and host foreground permission. Omit to use the current window/tab. A nonempty URL opens a new tab in normal Chrome."],
                "browser_mode": ["type": "string", "enum": BrowserMode.allCases.map(\.rawValue),
                                 "description": "Chrome only. Default existing uses the user's normal Chrome and logins. isolated requires a URL and an explicit user request for a separate profile."],
            ]; required = ["bundle_id"]
            description = "Open and bind a native app. For Chrome webpage reading first use computer_v2_tabs then computer_v2_bind_tab, not native open, when a connection is available. Chrome (com.google.Chrome) defaults to the user's existing normal session, with its tabs and logins; omit url to inspect an already-open tab. A URL opens a new tab; after opening, bind that observed tab for page reading. Use browser_mode=isolated only when the user explicitly requests a separate browser profile."
        case .tabs:
            properties = [
                "cursor": uuid.merging(["description": "Opaque next_cursor from this turn's previous page. Omit to refresh; refreshing invalidates earlier cursor and candidate tokens."], uniquingKeysWith: { _, new in new }),
                "page_size": ["type": "integer", "minimum": 1, "maximum": 100, "default": 25],
            ]; required = []
            description = "List existing Chrome tabs through a native-user-approved connection; this tool cannot grant access. Use computer_v2_continue(cursor=next_cursor) until absent to exhaust the inventory. Omit cursor here to refresh. When inventory_order=requested_scope_first, start with request_scope_match=true: this checks requested target metadata only, not authorization or content relevance. All tabs remain included; unknown or ambiguous requests retain transport order with null matches. Candidate tokens and cursors are opaque and valid only in this turn. Tab titles/URLs are candidate metadata, not evidence of page contents or relevance. Select an observed candidate_token with computer_v2_bind_tab and inspect its content before making a content claim. Preserves existing tabs and logins, with no activation, navigation or closing tabs."
        case .continueRead:
            properties = ["cursor": uuid]; required = ["cursor"]
            description = "Read the next page using an observed next_cursor from THIS turn. The host remembers whether it belongs to Chrome inventory or a page/native read and routes it safely. Send cursor alone; do not guess its type or reuse previous-turn cursors. Does not refresh, bind, reconnect, navigate or grant permissions. If stale, start a fresh inventory or snapshot of the intended source."
        case .bindTab:
            properties = ["candidate_token": uuid]; required = ["candidate_token"]
            description = "Bind an existing Chrome tab using only a candidate_token observed from computer_v2_tabs in this turn. Requires a native-user-approved connection; this tool cannot grant access. Preserves existing tabs and logins, with no activation, navigation or closing tabs. Start with computer_v2_snapshot(view=overview) to locate observed controls, headings and navigation, then view=content to read the document body. The overview is not exhaustive content. Use supported computer_v2_ax/computer_v2_set_text actions. Global image, key and pointer paths are unavailable in a borrowed tab; do not fall back to capture/click/keypress/type."
        case .createWorkspace:
            properties = ["candidate_token": uuid]; required = ["candidate_token"]
            description = "Create and bind one inactive temporary task tab at the exact URL of an available candidate_token from this turn's Chrome inventory, BEFORE binding that source. Use when navigation/search must preserve the user's existing page or draft. Requires the separate native temporary-tabs grant and supported extension; cannot grant itself access. No guessed URL, foreground activation, or busy-tab workaround. Original tabs stay untouched. Repeated creation does not make more tabs. Read the resulting page, use observed controls to navigate and verify content. The host cleans up only this task's still-owned tab; if the user activates it or ownership becomes uncertain, stop and retain it."
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
            description = "Read the bound app/tab; returns snapshot_id, element indices and coverage. Start a browser page with {\"view\":\"overview\"} for observed controls, headings and navigation; this bounded selection is not exhaustive document content. Read {\"view\":\"content\"} when the body is needed; act on an observed navigation control directly when appropriate. Native apps use all or content, not overview. Fresh reads omit snapshot_id and element_index. A different view is also a fresh read. Continue: computer_v2_continue with an observed next_cursor. Subtree: BOTH snapshot_id and an observed element_index. content_kind distinguishes readable text from controls and navigation; content_scope is only structural. Continued fields include original UTF8 offsets. A truncated read is not proof content is absent. Do not repeat unchanged reads: change view, expand, or continue. For a known missing item try a short literal query before scrolling or capturing; never substitute another item's fact. If the observed facts answer the request, answer and stop. Group facts by parent, never adjacency alone. sibling_heading is observed direct-sibling context, not proof of semantic ownership. Use computer_v2_follow_link for browser links marked follow_link=true; its destination verification is automatic. Use supported AX actions for other controls. For a Chrome navigation link without AXPress, follow its exact observed url with computer_v2_open; never reconstruct url_omitted destinations. URL navigation is not an in-page script action. Use only listed actions. Browser fields with settable=true support computer_v2_set_text directly without focus, even when actions=[]. Only a native text field advertising AXPress supports that focus action; it does not submit."
        case .followLink:
            properties = ["snapshot_id": string, "element_index": integer]
            required = ["snapshot_id", "element_index"]
            description = "Follow an observed browser navigation link marked follow_link=true. Supply only the current snapshot_id and its element_index. The host presses the exact link once and verifies its observed destination automatically; do not supply ax_action, URL, or postcondition. This is browser-only and still requires the user's action approval. A stale reference sends no input: take a fresh overview, then select the link from that snapshot. Navigation proof is not task completion; inspect the returned page."
        case .ax:
            properties = [
                "snapshot_id": string,
                "element_index": ["type": "integer", "minimum": 0, "description": "Top-level action target: the observed button/control to press. Keep the result container index inside postcondition.element_index."],
                "ax_action": ["type": "string", "enum": SemanticAXAction.allCases.map(\.rawValue)],
                "postcondition": [
                    "type": "object", "additionalProperties": false,
                    "properties": [
                        "kind": ["type": "string", "enum": ["document_url", "value", "region_text", "region_changed", "dialog_opened", "detail_view", "selection"]],
                        "element_index": ["type": "integer", "minimum": 0, "description": "Nested postcondition.element_index: the observed result element/container from this same snapshot. For region_changed use the candidate container, not the pressed button or a text child; keep the button index at the top level."],
                        "detail_element_index": ["type": "integer", "minimum": 0],
                        "expected": ["type": "string", "maxLength": 4096, "description": "Required exact intended result except region_changed and dialog_opened, which must omit expected."],
                    ],
                    "required": ["kind"],
                    "oneOf": [
                        ["properties": ["kind": ["enum": ["region_changed"]]],
                         "required": ["element_index"], "not": ["anyOf": [["required": ["expected"]], ["required": ["detail_element_index"]]]]],
                        ["properties": ["kind": ["enum": ["dialog_opened"]]],
                         "not": ["anyOf": [["required": ["expected"]], ["required": ["element_index"]], ["required": ["detail_element_index"]]]]],
                        ["properties": ["kind": ["enum": ["document_url", "value", "region_text", "detail_view", "selection"]]],
                         "required": ["expected"]],
                    ],
                    "description": "REQUIRED for a browser press without an observed link destination, including pagination. For an observed control intended to open a dialog on the same page, use only {kind:dialog_opened}: no expected text or result index. The host requires a complete baseline without a dialog and verifies one newly exposed dialog in the same document; read it before claiming any result. Browser region_changed: choose the observed container marked region_changed_candidate=true (semantic_role identifies its browser role), never its StaticText child; parent_index links a child to its visible container. Provide that container element_index and OMIT expected; the host verifies only changed displayed text in that exact region, not page/task success. Use it when future result text is unknown, then read the returned content. Declare the intended result BEFORE input. value/region_text: observed result element_index and exact expected value/region text. Browser detail_view: exact heading already observed in target; no detail_element_index. Native detail_view: supply observed detail_element_index for the separate detail pane and no element_index. Native selection: expected=true; selected= state is checked automatically when available, with no detail_element_index. Selection proves selection only; use detail_view to verify the separate detail content. Browser document_url must match the observed link. Runtime checks bounded fresh reads without replaying input. Never reuse old indices with a new snapshot_id.",
                ],
            ]
            required = ["snapshot_id", "element_index", "ax_action"]
            description = "Act on a currently exposed element using only a listed action. For links marked follow_link=true, prefer computer_v2_follow_link with no postcondition. For a control intended to open a same-page dialog, declare postcondition={kind:dialog_opened} without expected or element_index. Before pressing a browser button without a link destination, include postcondition; inspection/pagination buttons still require it. For unknown next-page text, first observe view=all and select the container marked region_changed_candidate=true, not its StaticText child (follow parent_index), then provide a complete press request without expected. \(regionChangedIndexGuidance) The candidate is not authorization. This proves changed region text only: read the new content before claiming progress or success. Browser links and native selected= controls have automatic verification plans; other presses require postcondition. Native detail views require an observed separate detail pane. Runtime dispatches at most once and verifies with fresh reads. VERIFIED_PROPERTY proves that property; ALREADY_SATISFIED means the desired state already held and no input occurred. Do not repeat either. VERIFICATION_PENDING allows only read-only recovery. A new snapshot_id never makes an old element_index valid. Background native AX cannot raise windows or post global input. Use set_text directly for settable fields. Approval follows the user's access mode."
        case .setText:
            properties = ["snapshot_id": string, "element_index": integer, "text": string]
            required = ["snapshot_id", "element_index", "text"]
            description = "Set text on a currently exposed settable=true field; does not submit. No preliminary press or focus is needed. Browser and background-native values are automatically verified against the requested text. VERIFIED_PROPERTY needs no further verification; ALREADY_SATISFIED means no input was needed. Do not repeat an unverified action. Approval follows the user's access mode."
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

    private static func backgroundSpec(_ tool: Tool) -> [String: Any] {
        var result = spec(tool)
        switch tool {
        case .open:
            result["description"] = "Bind an already-running native app without launch, activation or navigation. Default activation=none; the host enforces background-only operation. For existing Chrome webpage content prefer computer_v2_tabs then computer_v2_bind_tab. If the app or selected window is unavailable, report that limitation; do not try to gain focus or open another tab."
            result["inputSchema"] = [
                "type": "object",
                "properties": [
                    "bundle_id": ["type": "string"],
                    "activation": ["type": "string", "enum": ["none"], "default": "none"],
                ],
                "required": ["bundle_id"],
                "additionalProperties": false,
            ]
        case .snapshot:
            let foregroundNavigation = "For a Chrome navigation link without AXPress, follow its exact observed url with computer_v2_open; never reconstruct url_omitted destinations. URL navigation is not an in-page script action."
            result["description"] = (result["description"] as? String ?? "")
                .replacingOccurrences(of: foregroundNavigation, with: "Use only supported background actions. If navigation is not supported by the current element, report that limitation; do not open or activate a window as a fallback.")
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
            result["description"] = "Read-only capture of the exact bound native app window without activation; brokered Chrome tabs fail closed. Returns observation_id and image dimensions, not capture_id or pointer/key capability. This image is perception only: it does not authorize clicks, keyboard input, or a foreground fallback. No synchronized AX is returned."
        default:
            break
        }
        return result
    }
}

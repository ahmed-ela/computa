import Foundation

/// An app-owned model catalog opts our model IDs into the native Codex patch
/// executor for website providers. Local MLX keeps its existing function-only
/// producer contract and command editing support. Other fields mirror pinned
/// fallback metadata; context/provider configuration remain in thread config.
/// The pinned engine's models-manager matches the longest catalog slug prefix,
/// then retains the complete requested slug. Thus browser/<provider>/choice/...
/// inherits the already-admitted browser/<provider> freeform patch metadata even
/// when discovered after launch. No cached catalog reload or restart is assumed.
enum ComputaModelToolCatalog {
    // Temporary product policy. Keep the Chrome implementation for a later
    // opt-in, but expose only the app-owned browser route to models now.
    static let enableExternalChromeTools = false
    static let externalChromeToolNames: Set<String> = [
        "computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_create_workspace",
        "computer_v2_follow_link", "computer_v2_follow",
    ]
    static let externalChromeUnavailableMessage = "External Chrome tools are hidden in this build. Use browser_tabs for Computa's built-in browser, browser_read(cursor=next_cursor) for its page continuation, and browser_tabs(cursor=next_cursor) for its tab inventory. No Chrome read, connection, or input was dispatched."

    /// Also applies to schemas retained by old native threads. History stays
    /// unchanged; only the current model's callable tool definitions change.
    static func visibleToolDefinitions(_ definitions: [[String: Any]], modelID: String) -> [[String: Any]] {
        guard !enableExternalChromeTools else { return definitions }
        let overrides = nativeToolDescriptions(modelID: modelID)
        func visible(_ definition: [String: Any]) -> [String: Any]? {
            var value = definition
            if value["type"] as? String == "namespace", let children = value["tools"] as? [[String: Any]] {
                let tools = children.compactMap(visible)
                guard !tools.isEmpty else { return nil }
                value["tools"] = tools
                return value
            }
            guard let name = value["name"] as? String else { return value }
            guard !externalChromeToolNames.contains(name) else { return nil }
            if let description = overrides[name] { value["description"] = description }
            if name == "computer_v2_open" {
                for key in ["parameters", "inputSchema"] {
                    guard var schema = value[key] as? [String: Any], var properties = schema["properties"] as? [String: Any] else { continue }
                    properties.removeValue(forKey: "url"); properties.removeValue(forKey: "browser_mode")
                    schema["properties"] = properties
                    if let required = schema["required"] as? [String] {
                        schema["required"] = required.filter { !["url", "browser_mode"].contains($0) }
                    }
                    value[key] = schema
                }
            }
            return value
        }
        return definitions.compactMap(visible)
    }

    static func nativeToolDescriptions(modelID: String) -> [String: String] {
        let specs = ComputerV2ToolContract.specs(for: modelID, externalChromeTools: false)
            + ComputerV2ToolContract.referenceSpecs(for: modelID, externalChromeTools: false)
        return specs.reduce(into: [:]) { result, spec in
            if let name = spec["name"] as? String, let description = spec["description"] as? String { result[name] = description }
        }
    }

    static func localToolVisibilityEnvironment(modelID: String) throws -> [String: String] {
        let descriptions = nativeToolDescriptions(modelID: modelID).sorted { $0.key < $1.key }
            .map { ["name": $0.key, "description": $0.value] }
        let data = try JSONSerialization.data(withJSONObject: descriptions, options: [.sortedKeys])
        return ["COMPUTA_EXTERNAL_CHROME_TOOLS_ENABLED": enableExternalChromeTools ? "1" : "0",
                "COMPUTA_NATIVE_TOOL_OVERRIDES": String(decoding: data, as: UTF8.self)]
    }

    static func catalogData(additionalModelID: String? = nil) throws -> Data {
        var ids = Set(LocalModelCatalog.options.map(\.id))
        // The engine matches slug prefixes. Future configured API models use
        // the same native patch executor without reloading its model catalog.
        ids.insert("api/")
        if let additionalModelID, !additionalModelID.isEmpty { ids.insert(additionalModelID) }
        let models = ids.sorted().map { id -> [String: Any] in
            [
                "slug": id, "display_name": id, "description": NSNull(),
                "default_reasoning_level": NSNull(), "supported_reasoning_levels": [String](),
                "shell_type": "unified_exec", "visibility": "none", "supported_in_api": true,
                "priority": 99, "additional_speed_tiers": [String](), "service_tiers": [String](),
                "default_service_tier": NSNull(), "available_access_programs": NSNull(),
                "availability_nux": NSNull(), "upgrade": NSNull(),
                // ModelsResponse requires an instruction template at catalog
                // admission. Actual turns still receive Computa's explicit
                // model-specific base/developer instructions through App Server.
                "model_messages": ["instructions_template": "You are Computa, the user's local assistant. Follow the supplied developer instructions and offered local tool contracts."],
                "include_skills_usage_instructions": false, "include_plugin_usage_instructions": false,
                "include_apps_usage_instructions": false, "supports_reasoning_summary_parameter": true,
                "default_reasoning_summary": "auto", "support_verbosity": false,
                "default_verbosity": NSNull(), "apply_patch_tool_type": LocalModelCatalog.isWebBrowser(id) || id.hasPrefix("api/") ? "freeform" : NSNull(),
                "web_search_tool_type": "text", "truncation_policy": ["mode": "bytes", "limit": 10_000],
                "supports_image_detail_original": false, "context_window": 272_000,
                "effective_context_window_percent": 95, "experimental_supported_tools": [String](),
                "input_modalities": ["text", "image"], "supports_search_tool": false,
                "supports_experimental_context": false, "use_responses_lite": false,
                "node_repl_auto_review_required": false, "node_repl_disabled": false,
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["models": models], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func url(codexHomePath: String) -> URL {
        URL(fileURLWithPath: codexHomePath, isDirectory: true).appendingPathComponent("ComputaModels-v1.json")
    }

    @discardableResult
    static func prepare(codexHomePath: String, additionalModelID: String? = nil) throws -> URL {
        let destination = url(codexHomePath: codexHomePath)
        let data = try catalogData(additionalModelID: additionalModelID)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    static func launchArguments(catalogURL: URL) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quotedPath = String(decoding: try encoder.encode(catalogURL.path), as: UTF8.self)
        return ["-c", "model_catalog_json=" + quotedPath]
    }
}

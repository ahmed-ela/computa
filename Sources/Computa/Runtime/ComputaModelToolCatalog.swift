import Foundation
import CoreFoundation

/// An app-owned model catalog opts our model IDs into the native Codex patch
/// executor for website providers. Local MLX keeps its existing function-only
/// producer contract and command editing support. Other fields mirror pinned
/// fallback metadata; context/provider configuration remain in thread config.
/// The pinned engine's models-manager matches the longest catalog slug prefix,
/// then retains the complete requested slug. Thus browser/<provider>/choice/...
/// inherits the already-admitted browser/<provider> freeform patch metadata even
/// when discovered after launch. No cached catalog reload or restart is assumed.
enum ComputaModelToolCatalog {
    /// Only the two app-owned argument shapes are eligible for evolution. A
    /// similarly named MCP/custom tool or a modified schema keeps its contract.
    /// The pinned engine can omit constraints when projecting dynamic schemas.
    static func browserMutationSchemaVariants(name: String, namespace: String?, schema: [String: Any])
        -> (legacy: [String: Any], current: [String: Any])? {
        if let additional = schema["additionalProperties"] {
            guard let flag = additional as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else { return nil }
        }
        guard namespace == nil || namespace == "functions",
              ["browser_click", "browser_fill"].contains(name),
              let definition = EmbeddedBrowserTools.definitions().first(where: { $0["name"] as? String == name }),
              let current = definition["inputSchema"] as? [String: Any],
              let canonical = current["properties"] as? [String: [String: Any]],
              schema["type"] as? String == "object",
              Set(schema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties", "description"]),
              let properties = schema["properties"] as? [String: [String: Any]],
              let required = schema["required"] as? [String], Set(required).count == required.count
        else { return nil }
        let assertions: Set<String> = ["expected_role", "expected_label"]
        let currentKeys = Set(canonical.keys), legacyKeys = currentKeys.subtracting(assertions)
        guard Set(properties.keys) == legacyKeys || Set(properties.keys) == currentKeys,
              Set(required) == Set(properties.keys) else { return nil }
        for (field, property) in properties {
            guard let expected = canonical[field], property["type"] as? String == expected["type"] as? String,
                  Set(property.keys).subtracting(["description"]).isSubset(of: Set(expected.keys)) else { return nil }
            for (key, value) in property where key != "description" {
                guard let wanted = expected[key], NSDictionary(dictionary: [key: value]).isEqual(to: [key: wanted]) else { return nil }
            }
        }
        // Preserve the saved legacy constraints for historical calls. Do not
        // add fields to that shape or accept a half-upgraded argument object.
        var legacy = schema
        legacy["properties"] = properties.filter { !assertions.contains($0.key) }
        legacy["required"] = required.filter { !assertions.contains($0) }
        legacy["additionalProperties"] = false
        return (legacy, current)
    }

    /// Also applies to schemas retained by old native threads. History stays
    /// unchanged; only the current model's callable tool definitions change.
    static func visibleToolDefinitions(_ definitions: [[String: Any]], modelID: String) -> [[String: Any]] {
        let overrides = nativeToolDescriptions(modelID: modelID)
        // Availability is already scoped by the caller's interaction policy.
        // Reject removed names without hiding valid foreground tools that are
        // absent from the default background-only description set.
        let currentComputerNames = Set(ComputerV2ToolContract.Tool.allCases.map(\.rawValue)
            + ComputerV2ToolContract.Alias.allCases.map(\.rawValue)
            + [ComputerOutcomeToolContract.name])
        let appsSchema = ComputerV2ToolContract.specs(for: modelID)
            .first { $0["name"] as? String == "computer_v2_apps" }?["inputSchema"] as? [String: Any]
        let browserProperties = EmbeddedBrowserTools.definitions().reduce(into: [String: [String: Any]]()) { result, definition in
            guard let name = definition["name"] as? String,
                  let schema = definition["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else { return }
            result[name] = properties
        }
        func visible(_ definition: [String: Any], namespace: String? = nil) -> [String: Any]? {
            var value = definition
            if value["type"] as? String == "namespace", let children = value["tools"] as? [[String: Any]] {
                let tools = children.compactMap { visible($0, namespace: value["name"] as? String) }
                guard !tools.isEmpty else { return nil }
                value["tools"] = tools
                return value
            }
            guard let name = value["name"] as? String else { return value }
            // Restored threads may retain removed tools. History remains readable,
            // but only the current native contract may be offered for new calls.
            guard !name.hasPrefix("computer_v2_") || currentComputerNames.contains(name) else { return nil }
            if let description = overrides[name] { value["description"] = description }
            if value["type"] as? String == "function", ["browser_click", "browser_fill"].contains(name) {
                for key in ["parameters", "inputSchema"] {
                    guard let schema = value[key] as? [String: Any],
                          let variants = browserMutationSchemaVariants(name: name, namespace: namespace, schema: schema) else { continue }
                    value[key] = variants.current
                    value["description"] = EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name }?["description"]
                }
                // Do not partially refresh a custom shape under this name.
                return value
            }
            if name == "computer_v2_apps", value["type"] as? String == "function", let appsSchema {
                // Refresh current calls only. API history is parsed against its
                // original catalog before this projection, including old errors.
                for key in ["parameters", "inputSchema"] where value[key] is [String: Any] {
                    value[key] = appsSchema
                }
            }
            if value["type"] as? String == "function", let current = browserProperties[name] {
                for key in ["parameters", "inputSchema"] {
                    guard var schema = value[key] as? [String: Any],
                          var properties = schema["properties"] as? [String: Any] else { continue }
                    // The engine's limited schema representation drops these
                    // constraints. Restore current native limits only on fields
                    // already offered; preserve types, enum, required and history.
                    for (field, value) in properties {
                        guard var property = value as? [String: Any],
                              let canonical = current[field] as? [String: Any] else { continue }
                        for constraint in ["minimum", "maximum", "minLength", "pattern"] {
                            if let value = canonical[constraint] { property[constraint] = value }
                        }
                        properties[field] = property
                    }
                    schema["properties"] = properties
                    value[key] = schema
                }
            }
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
        return definitions.compactMap { visible($0) }
    }

    static func nativeToolDescriptions(modelID: String) -> [String: String] {
        let specs = ComputerV2ToolContract.specs(for: modelID)
            + ComputerV2ToolContract.referenceSpecs(for: modelID)
            + [ComputerOutcomeToolContract.spec]
        return specs.reduce(into: [:]) { result, spec in
            if let name = spec["name"] as? String, let description = spec["description"] as? String { result[name] = description }
        }
    }

    static func localToolVisibilityEnvironment(modelID: String) throws -> [String: String] {
        let descriptions = nativeToolDescriptions(modelID: modelID).sorted { $0.key < $1.key }
            .map { ["name": $0.key, "description": $0.value] }
        let data = try JSONSerialization.data(withJSONObject: descriptions, options: [.sortedKeys])
        return ["COMPUTA_NATIVE_TOOL_OVERRIDES": String(decoding: data, as: UTF8.self)]
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

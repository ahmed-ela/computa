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
    enum BrowserReadMode: Sendable, Equatable { case fresh, continuation }

    /// Capability comes from the exact registered native shape, never its name
    /// alone. The engine can omit scalar constraints while retaining structure.
    static func browserReadMode(name: String, namespace: String?, schema: [String: Any]) -> BrowserReadMode? {
        guard namespace == nil || namespace == "functions",
              name == "browser_read" || name == "browser_continue",
              let current = EmbeddedBrowserTools.definitions().first(where: { $0["name"] as? String == name })?["inputSchema"] as? [String: Any],
              matchesNativeReadSchema(schema, current) else { return nil }
        return name == "browser_read" ? .fresh : .continuation
    }

    private static func matchesNativeReadSchema(_ schema: [String: Any], _ canonical: [String: Any],
                                                omittable: Set<String> = ["minLength", "maxLength", "pattern"]) -> Bool {
        guard schema["type"] as? String == "object",
              Set(schema.keys).subtracting(["description"]).isSubset(of: Set(canonical.keys)),
              let properties = schema["properties"] as? [String: [String: Any]],
              let expected = canonical["properties"] as? [String: [String: Any]], Set(properties.keys) == Set(expected.keys),
              let required = schema["required"] as? [String], let wanted = canonical["required"] as? [String],
              Set(required) == Set(wanted), Set(required).count == required.count else { return false }
        guard let additional = schema["additionalProperties"] as? NSNumber,
              CFGetTypeID(additional) == CFBooleanGetTypeID(), !additional.boolValue else { return false }
        for (name, property) in properties {
            guard let target = expected[name],
                  Set(property.keys).subtracting(["description"]).isSubset(of: Set(target.keys)),
                  Set(target.keys).subtracting(omittable.union(["description"])).isSubset(of: Set(property.keys)) else { return false }
            for (key, value) in property where key != "description" {
                guard let wanted = target[key], NSDictionary(dictionary: [key: value]).isEqual(to: [key: wanted]) else { return false }
            }
        }
        return true
    }

    /// Recognize complete app-owned read versions only. Native cursor state
    /// decides whether repeated filters match; historical calls stay byte-exact.
    static func browserCursorSchemaVariants(name: String, namespace: String?, schema: [String: Any])
        -> (historical: [String: Any], current: [String: Any])? {
        if name == "browser_read", browserReadMode(name: name, namespace: namespace, schema: schema) == .fresh,
           let current = EmbeddedBrowserTools.definitions().first(where: { $0["name"] as? String == name })?["inputSchema"] as? [String: Any],
           var historical = EmbeddedBrowserTools.legacyReadDefinition["inputSchema"] as? [String: Any],
           var properties = historical["properties"] as? [String: Any],
           let saved = schema["properties"] as? [String: Any] {
            // Completed calls retain known legacy syntax, not an identity alias.
            // Preserve saved scalar constraints on the fresh view/query fields.
            for (key, value) in saved { properties[key] = value }
            historical["properties"] = properties
            return (historical, current)
        }
        var canonical: [String: [String: Any]] = ["cursor": ["type": ["string", "null"], "minLength": 1]]
        if name == "browser_read" {
            canonical["view"] = ["type": "string", "enum": ["overview", "content", "all", "headings", "links"]]
            canonical["query"] = ["type": "string", "minLength": 1]
        }
        guard ["browser_read", "browser_tabs"].contains(name), namespace == nil || namespace == "functions",
              let current = (name == "browser_read" ? EmbeddedBrowserTools.legacyReadDefinition :
                EmbeddedBrowserTools.definitions().first(where: { $0["name"] as? String == name }))?["inputSchema"] as? [String: Any],
              schema["type"] as? String == "object",
              Set(schema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties", "description", "oneOf"]),
              let properties = schema["properties"] as? [String: [String: Any]], Set(properties.keys) == Set(canonical.keys),
              let required = schema["required"] as? [String], required.isEmpty else { return nil }
        if let additional = schema["additionalProperties"] {
            guard let flag = additional as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else { return nil }
        }
        let omittable: Set<String> = ["minLength", "maxLength", "pattern"]
        for (field, property) in properties {
            guard let expected = canonical[field],
                  Set(property.keys).subtracting(["description"]).isSubset(of: Set(expected.keys)),
                  Set(expected.keys).subtracting(omittable.union(["description"])).isSubset(of: Set(property.keys)) else { return nil }
            for (key, value) in property where key != "description" {
                if field == "cursor", key == "type" {
                    let types = (value as? String).map { [$0] } ?? (value as? [String]) ?? []
                    guard types == ["string"] || (types.count == 2 && Set(types) == ["string", "null"]) else { return nil }
                } else {
                    guard let wanted = expected[key], NSDictionary(dictionary: [key: value]).isEqual(to: [key: wanted]) else { return nil }
                }
            }
        }
        if let variants = schema["oneOf"] {
            // Freeze the 231–233 contract independently of today's flat schema.
            // Only those exact branches may be migrated; a narrowed or foreign
            // composition must never acquire the app's more permissive contract.
            let expected: [[String: Any]] = [
                ["type": "object", "properties": [
                    "view": ["type": "string", "enum": ["overview", "content", "all", "headings", "links"]],
                    "query": ["type": "string", "minLength": 1], "cursor": ["type": "null"]],
                 "required": [String](), "additionalProperties": false],
                ["type": "object", "properties": ["cursor": ["type": "string", "minLength": 1]],
                 "required": ["cursor"], "additionalProperties": false],
            ]
            guard name == "browser_read", let actual = variants as? [[String: Any]],
                  let cursorTypes = properties["cursor"]?["type"] as? [String],
                  cursorTypes.count == 2, Set(cursorTypes) == ["string", "null"],
                  actual.count == expected.count else { return nil }
            // The pinned engine may omit scalar constraints and descriptions,
            // but must retain each branch's fields, types, required and closure.
            func matchesBranch(_ actual: [String: Any], _ expected: [String: Any]) -> Bool {
                guard Set(actual.keys).subtracting(["description"]).isSubset(of: Set(expected.keys)),
                      Set(expected.keys).subtracting(omittable.union(["description"])).isSubset(of: Set(actual.keys)) else { return false }
                for (key, value) in actual where key != "description" {
                    if key == "properties" {
                        guard let fields = value as? [String: [String: Any]],
                              let wanted = expected[key] as? [String: [String: Any]], Set(fields.keys) == Set(wanted.keys),
                              fields.allSatisfy({ matchesBranch($0.value, wanted[$0.key]!) }) else { return false }
                    } else {
                        guard let wanted = expected[key], NSDictionary(dictionary: [key: value]).isEqual(to: [key: wanted]) else { return false }
                    }
                }
                return true
            }
            guard zip(actual, expected).allSatisfy({ matchesBranch($0.0, $0.1) }) else { return nil }
        }
        // Only exact recognized versions reach this point. Historical and
        // current flat schemas leave cursor/filter consistency to native state.
        var historical = schema, historicalProperties = properties
        historicalProperties["cursor"]?["type"] = ["string", "null"]
        historical["properties"] = historicalProperties
        historical.removeValue(forKey: "oneOf")
        // Use one flat historical superset, not overlapping oneOf alternatives.
        // Saved scalar constraints remain untouched.
        return (historical, current)
    }

    /// Preserve saved wait constraints for completed calls while offering the
    /// additive current wait only for exact native schemas, including branches.
    static func browserWaitSchemaVariants(name: String, namespace: String?, schema: [String: Any])
        -> (historical: [[String: Any]], current: [String: Any])? {
        guard name == "browser_wait", namespace == nil || namespace == "functions",
              nativeConstraintTypesAreValid(schema),
              let legacy = EmbeddedBrowserTools.legacyWaitDefinition["inputSchema"] as? [String: Any],
              let current = EmbeddedBrowserTools.waitDefinition["inputSchema"] as? [String: Any] else { return nil }
        let omittable: Set<String> = ["minimum", "maximum", "minLength", "maxLength", "pattern", "description"]
        func matches(_ actual: [String: Any], _ expected: [String: Any]) -> Bool {
            guard Set(actual.keys).subtracting(["description"]).isSubset(of: Set(expected.keys)),
                  Set(expected.keys).subtracting(omittable).isSubset(of: Set(actual.keys)) else { return false }
            for (key, value) in actual where key != "description" {
                guard let wanted = expected[key] else { return false }
                switch key {
                case "properties":
                    guard let fields = value as? [String: [String: Any]],
                          let canonical = wanted as? [String: [String: Any]],
                          Set(fields.keys) == Set(canonical.keys),
                          fields.allSatisfy({ matches($0.value, canonical[$0.key]!) }) else { return false }
                case "oneOf":
                    guard let branches = value as? [[String: Any]], let canonical = wanted as? [[String: Any]],
                          branches.count == canonical.count,
                          zip(branches, canonical).allSatisfy({ matches($0.0, $0.1) }) else { return false }
                case "required":
                    guard let fields = value as? [String], let canonical = wanted as? [String],
                          fields.count == Set(fields).count, Set(fields) == Set(canonical) else { return false }
                case "additionalProperties":
                    guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else { return false }
                default:
                    guard NSDictionary(dictionary: [key: value]).isEqual(to: [key: wanted]) else { return false }
                }
            }
            return true
        }
        if matches(schema, legacy) { return ([schema, current], current) }
        if matches(schema, current) { return ([schema], current) }
        return nil
    }

    /// A conflicting second declaration cannot borrow recognition from its
    /// native-looking half, either for current projection or historical input.
    static func browserWaitDefinitionVariants(_ definition: [String: Any], namespace: String?)
        -> (historical: [[String: Any]], current: [String: Any])? {
        guard definition["type"] as? String == "function", definition["name"] as? String == "browser_wait" else { return nil }
        let keys = ["parameters", "inputSchema"].filter { definition[$0] != nil }
        guard let first = keys.first, let schema = definition[first] as? [String: Any],
              let variants = browserWaitSchemaVariants(name: "browser_wait", namespace: namespace, schema: schema) else { return nil }
        func withoutDescriptions(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { $0.key != "description" }.mapValues(withoutDescriptions)
            }
            if let array = value as? [Any] { return array.map(withoutDescriptions) }
            return value
        }
        let expected = withoutDescriptions(schema) as! [String: Any]
        guard keys.allSatisfy({ key in
            guard let other = definition[key] as? [String: Any],
                  browserWaitSchemaVariants(name: "browser_wait", namespace: namespace, schema: other) != nil,
                  let normalized = withoutDescriptions(other) as? [String: Any] else { return false }
            return NSDictionary(dictionary: normalized).isEqual(to: expected)
        }) else { return nil }
        return variants
    }

    /// Only the three app-owned argument shapes are eligible for evolution. A
    /// similarly named MCP/custom tool or a modified schema keeps its contract.
    /// The pinned engine can omit constraints when projecting dynamic schemas.
    static func browserMutationSchemaVariants(name: String, namespace: String?, schema: [String: Any])
        -> (historical: [[String: Any]], current: [String: Any])? {
        if let additional = schema["additionalProperties"] {
            guard let flag = additional as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else { return nil }
        }
        guard namespace == nil || namespace == "functions",
              ["browser_click", "browser_fill"].contains(name),
              let definition = EmbeddedBrowserTools.definitions().first(where: { $0["name"] as? String == name }),
              let current = definition["inputSchema"] as? [String: Any],
              schema["type"] as? String == "object",
              Set(schema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties", "description"]),
              let properties = schema["properties"] as? [String: [String: Any]],
              let required = schema["required"] as? [String], Set(required).count == required.count
        else { return nil }
        guard Set(required) == Set(properties.keys) else { return nil }
        // Freeze prior contracts independently of the currently callable refs.
        // Never infer a legacy shape by subtracting fields from a newer version.
        var indexed: [String: Any] = [
            "snapshot_id": ["type": "string", "minLength": 1],
            "element_index": ["type": "integer", "minimum": 0, "maximum": 2_999],
        ]
        if name == "browser_fill" { indexed["text"] = ["type": "string"] }
        let assertions: Set<String> = ["expected_role", "expected_label"]
        let asserted = indexed.merging([
            "expected_role": ["type": "string", "minLength": 1, "maxLength": 128],
            "expected_label": ["type": "string", "maxLength": 4_096],
        ]) { _, new in new }
        func object(_ fields: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false]
        }
        var historical = [object(indexed), object(asserted), current]
        let matched = historical.firstIndex { candidate in
            guard let canonical = candidate["properties"] as? [String: [String: Any]],
                  Set(properties.keys) == Set(canonical.keys) else { return false }
            for (field, property) in properties {
                guard let expected = canonical[field], property["type"] as? String == expected["type"] as? String,
                      Set(property.keys).subtracting(["description"]).isSubset(of: Set(expected.keys)) else { return false }
                for (key, value) in property where key != "description" {
                    guard let wanted = expected[key], NSDictionary(dictionary: [key: value]).isEqual(to: [key: wanted]) else { return false }
                }
            }
            return true
        }
        guard let matched else { return nil }
        // Preserve the saved version's constraints, including ones omitted by
        // the engine. History alone accepts complete older forms; a partial
        // assertion/ref upgrade never becomes another historical variant.
        var saved = schema
        saved["additionalProperties"] = false
        historical[matched] = saved
        if matched == 1 {
            var legacy = saved
            legacy["properties"] = properties.filter { !assertions.contains($0.key) }
            legacy["required"] = required.filter { !assertions.contains($0) }
            historical[0] = legacy
        }
        return (historical, current)
    }

    /// Only original, recognized native declarations require host binding state.
    /// Refreshing constraints first could make a modified contract look native.
    static func requiresBrowserToolAvailability(_ definitions: [[String: Any]]) -> Bool {
        definitions.contains { definition in
            if definition["type"] as? String == "namespace", let namespace = definition["name"] as? String,
               let children = definition["tools"] as? [[String: Any]] {
                return children.contains { requiresBrowserBinding($0, namespace: namespace) }
            }
            return requiresBrowserBinding(definition, namespace: nil)
        }
    }

    private static func nativeConstraintTypesAreValid(_ schema: [String: Any]) -> Bool {
        for key in ["minimum", "maximum", "minLength", "maxLength", "pattern"] where schema[key] != nil {
            if key == "pattern" {
                guard schema[key] is String else { return false }
            } else {
                guard let number = schema[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            }
        }
        if let fields = schema["properties"] as? [String: [String: Any]],
           !fields.values.allSatisfy(nativeConstraintTypesAreValid) { return false }
        if let variants = schema["oneOf"] as? [[String: Any]],
           !variants.allSatisfy(nativeConstraintTypesAreValid) { return false }
        return true
    }

    private static func requiresBrowserBinding(_ definition: [String: Any], namespace: String?) -> Bool {
        guard definition["type"] as? String == "function", namespace == nil || namespace == "functions",
              let name = definition["name"] as? String,
              ["browser_read", "browser_continue", "browser_click", "browser_fill", "browser_navigate", "browser_wait", "browser_close"].contains(name)
        else { return false }
        if name == "browser_wait" { return browserWaitDefinitionVariants(definition, namespace: namespace) != nil }
        let schemaKeys = ["parameters", "inputSchema"].filter { definition[$0] != nil }
        guard !schemaKeys.isEmpty else { return false }
        return schemaKeys.allSatisfy { key in
            guard let schema = definition[key] as? [String: Any], nativeConstraintTypesAreValid(schema) else { return false }
            switch name {
            case "browser_read":
                return browserCursorSchemaVariants(name: name, namespace: namespace, schema: schema) != nil
            case "browser_continue":
                return browserReadMode(name: name, namespace: namespace, schema: schema) == .continuation
            case "browser_click", "browser_fill":
                return browserMutationSchemaVariants(name: name, namespace: namespace, schema: schema) != nil
            default:
                guard let canonical = EmbeddedBrowserTools.definitions().first(where: { $0["name"] as? String == name })?["inputSchema"] as? [String: Any] else { return false }
                return matchesNativeReadSchema(schema, canonical,
                    omittable: ["minimum", "maximum", "minLength", "maxLength", "pattern"])
            }
        }
    }

    /// Explain host-deferred capabilities separately from the callable catalog.
    /// Use the original registered shapes, before projection can refresh them;
    /// a name, historical call or foreign namespace cannot establish capability.
    static func deferredBrowserToolInstructions(_ definitions: [[String: Any]],
                                                availability: EmbeddedBrowserToolAvailability?) -> String? {
        guard availability == .unbound else { return nil }
        var deferred = Set<String>()
        var entryTools = Set<String>()
        func inspect(_ definition: [String: Any], namespace: String?) {
            guard let name = definition["name"] as? String else { return }
            let qualified = namespace.map { $0 + "." + name } ?? name
            if requiresBrowserBinding(definition, namespace: namespace) {
                deferred.insert(qualified)
                return
            }
            guard ["browser_open", "browser_bind"].contains(name),
                  nativeBrowserToolName(definition, namespace: namespace) != nil else { return }
            entryTools.insert(qualified)
        }
        for definition in definitions {
            if definition["type"] as? String == "namespace", let name = definition["name"] as? String,
               let children = definition["tools"] as? [[String: Any]] {
                children.forEach { inspect($0, namespace: name) }
            } else {
                inspect(definition, namespace: nil)
            }
        }
        guard !deferred.isEmpty, !entryTools.isEmpty else { return nil }
        return """
        COMPUTA_DEFERRED_BROWSER_CAPABILITIES:
        This turn has no bound built-in browser page. Computa temporarily withholds
        these registered page tools from the callable catalog: \(deferred.sorted().joined(separator: ", ")).
        They are deferred until binding, not missing capabilities. An empty tab
        inventory does not mean webpage interaction is unavailable.
        Currently offered binding entry tools: \(entryTools.sorted().joined(separator: ", ")).
        Within tool_choice, task scope and permissions, use an offered entry tool
        with its exact schema. Successful open/bind refreshes the next request's
        callable catalog; then use its offered page tools and current observations.
        Do not call a deferred tool now or infer action authority from this notice.
        END_COMPUTA_DEFERRED_BROWSER_CAPABILITIES.
        """
    }

    /// Diagnostic recognition shares the projection's exact native contracts.
    /// It never makes an unrecognized declaration callable or changes a schema.
    static func nativeBrowserToolName(_ definition: [String: Any], namespace: String?) -> String? {
        guard definition["type"] as? String == "function", namespace == nil || namespace == "functions",
              let name = definition["name"] as? String, EmbeddedBrowserTools.names.contains(name) else { return nil }
        if !["browser_tabs", "browser_open", "browser_bind"].contains(name) {
            return requiresBrowserBinding(definition, namespace: namespace) ? name : nil
        }
        let keys = ["parameters", "inputSchema"].filter { definition[$0] != nil }
        guard !keys.isEmpty, keys.allSatisfy({ key in
            guard let schema = definition[key] as? [String: Any], nativeConstraintTypesAreValid(schema) else { return false }
            if name == "browser_tabs" {
                return browserCursorSchemaVariants(name: name, namespace: namespace, schema: schema) != nil
            }
            guard let canonical = EmbeddedBrowserTools.definitions().first(where: { $0["name"] as? String == name })?["inputSchema"] as? [String: Any] else { return false }
            return matchesNativeReadSchema(schema, canonical)
        }) else { return nil }
        return name
    }

    /// Also applies to schemas retained by old native threads. History stays
    /// unchanged; only the current model's callable tool definitions change.
    static func visibleToolDefinitions(_ definitions: [[String: Any]], modelID: String,
                                       browserToolAvailability: EmbeddedBrowserToolAvailability? = nil,
                                       browserActionReferences: EmbeddedBrowserCurrentActionReferences? = nil) -> [[String: Any]] {
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
        func hasContinuation(_ values: [[String: Any]], namespace: String?) -> Bool {
            values.contains { definition in
                guard definition["type"] as? String == "function", definition["name"] as? String == "browser_continue" else { return false }
                let schemas = ["parameters", "inputSchema"].compactMap { definition[$0] as? [String: Any] }
                return !schemas.isEmpty && schemas.allSatisfy {
                    browserReadMode(name: "browser_continue", namespace: namespace, schema: $0) == .continuation
                }
            }
        }
        func visible(_ definition: [String: Any], namespace: String? = nil, continuation: Bool) -> [String: Any]? {
            var value = definition
            if value["type"] as? String == "namespace", let children = value["tools"] as? [[String: Any]] {
                let childNamespace = value["name"] as? String
                let hasContinue = hasContinuation(children, namespace: childNamespace)
                let tools = children.compactMap { visible($0, namespace: childNamespace, continuation: hasContinue) }
                guard !tools.isEmpty else { return nil }
                value["tools"] = tools
                return value
            }
            if browserToolAvailability == .unbound, requiresBrowserBinding(definition, namespace: namespace) { return nil }
            guard let name = value["name"] as? String else { return value }
            if name == "browser_wait" {
                guard let variants = browserWaitDefinitionVariants(definition, namespace: namespace) else { return definition }
                for key in ["parameters", "inputSchema"] where value[key] != nil { value[key] = variants.current }
                value["description"] = EmbeddedBrowserTools.waitDefinition["description"]
                return value
            }
            // Restored threads may retain removed tools. History remains readable,
            // but only the current native contract may be offered for new calls.
            guard !name.hasPrefix("computer_v2_") || currentComputerNames.contains(name) else { return nil }
            if let description = overrides[name] { value["description"] = description }
            if value["type"] as? String == "function", ["browser_read", "browser_tabs"].contains(name) {
                for key in ["parameters", "inputSchema"] {
                    guard let schema = value[key] as? [String: Any],
                          let variants = browserCursorSchemaVariants(name: name, namespace: namespace, schema: schema) else { continue }
                    let definition = name == "browser_read" && !continuation &&
                        browserReadMode(name: name, namespace: namespace, schema: schema) != .fresh
                        ? EmbeddedBrowserTools.legacyReadDefinition
                        : EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name }
                    value[key] = continuation && name == "browser_read" ? definition?["inputSchema"] : variants.current
                    value["description"] = definition?["description"]
                    if name == "browser_read", !continuation,
                       browserReadMode(name: name, namespace: namespace, schema: schema) == .fresh,
                       let description = value["description"] as? String {
                        value["description"] = description.replacingOccurrences(
                            of: "Use browser_continue(cursor=next_cursor) to advance the same capture; changing filters requires this fresh tool.",
                            with: "Use a page continuation tool only if offered; changing filters requires this fresh tool.")
                    }
                }
                // Do not widen optionality or repair a modified/foreign schema.
                return value
            }
            if name == "browser_continue" {
                guard value["type"] as? String == "function" else { return value }
                for key in ["parameters", "inputSchema"] {
                    guard let schema = value[key] as? [String: Any],
                          browserReadMode(name: name, namespace: namespace, schema: schema) == .continuation,
                          let canonical = EmbeddedBrowserTools.definitions().first(where: { $0["name"] as? String == name }) else { continue }
                    value[key] = canonical["inputSchema"]
                    value["description"] = canonical["description"]
                }
                return value
            }
            if value["type"] as? String == "function", ["browser_click", "browser_fill"].contains(name) {
                // The API's native snapshot narrows only a whole recognized
                // original definition. A valid half of a modified dual-schema
                // declaration must not acquire host reference constraints.
                if browserActionReferences != nil, !requiresBrowserBinding(definition, namespace: namespace) {
                    return definition
                }
                let references = browserActionReferences.map {
                    name == "browser_click" ? $0.clickReferences : $0.fillReferences
                }
                if references?.isEmpty == true { return nil }
                for key in ["parameters", "inputSchema"] {
                    guard let schema = value[key] as? [String: Any],
                          let variants = browserMutationSchemaVariants(name: name, namespace: namespace, schema: schema) else { continue }
                    var current = variants.current
                    if let references, var properties = current["properties"] as? [String: [String: Any]] {
                        let field = name == "browser_click" ? "click_ref" : "fill_ref"
                        properties[field]?["enum"] = references
                        current["properties"] = properties
                    }
                    value[key] = current
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
        let continuation = hasContinuation(definitions, namespace: nil)
        return definitions.compactMap { visible($0, continuation: continuation) }
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

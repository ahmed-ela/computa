import CryptoKit
import Foundation

/// Presentation state only. Loading a schema never executes its tool or grants
/// permission; the codec and native executor retain their existing admission.
struct GroqToolCatalog: Sendable {
    static let name = "computa_load_tools"
    static let maximumLoadedTools = 4

    struct Scope: Hashable, Sendable {
        let taskID: String
        let threadID: String
        let turnID: String
        let runtimeGeneration: UUID
        let preparationID: UUID
        let modelID: String
    }

    struct Seed: Sendable {
        let registeredDefinitionsJSON: Data
        let callableNames: Set<String>
        let allowedNames: Set<String>
        let preloadNames: Set<String>
        let toolChoiceJSON: Data
    }

    struct Entry: Codable, Equatable, Sendable {
        let name: String
        let summary: String
        let isCustom: Bool
        let callable: Bool
        let allowed: Bool
    }

    struct Projection: Equatable, Sendable {
        let revision: String
        let inventory: [Entry]
        let selectedNames: Set<String>

        var discoverable: [Entry] { inventory.filter { $0.callable && $0.allowed } }
        var loaderChoices: [String] {
            discoverable.map(\.name).filter { $0 != GroqToolCatalog.name && $0 != "functions." + GroqToolCatalog.name }
        }

        /// Constrain only the website's displayed loader schema. Native registration,
        /// canonical history, response configuration and executor checks keep the originals.
        func displaySchemas(_ schemas: [[String: Any]]) -> [[String: Any]] {
            let choices = loaderChoices
            return schemas.map { tool in
                if tool["type"] as? String == "namespace" {
                    guard tool["name"] as? String == "functions", let children = tool["tools"] as? [[String: Any]] else { return tool }
                    var result = tool
                    result["tools"] = children.map { GroqToolCatalog.restoringRegisteredLoaderBounds($0, namespace: "functions", choices: choices) }
                    return result
                }
                return GroqToolCatalog.restoringRegisteredLoaderBounds(tool, choices: choices)
            }
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidCatalog, invalidScope, staleRevision, invalidArguments, unavailableTool, selectionTooLarge
        case tooManyNames(count: Int, direct: [String], loadable: [String], ineligible: Int)
        case budgetWithOfferedSchemas([String])
        case unavailableSelection(unavailable: [String], denied: [String], unknownCount: Int, direct: [String], loadable: [String])
        var errorDescription: String? {
            switch self {
            case .invalidCatalog: "The registered tool catalog could not be verified. No tool was loaded or executed."
            case .invalidScope: "Tool loading does not belong to the current registered Groq turn. No tool was loaded or executed."
            case .staleRevision: "The tool catalog changed. Use its current revision and inventory; no tool was loaded or executed."
            case .invalidArguments: "Tool loading requires the current catalog_revision and one to four unique inventory names. No tool was loaded or executed."
            case let .tooManyNames(count, direct, loadable, ineligible):
                "Requested \(count) names; the limit is four. No tool was loaded or executed. Eligible matches from this request (up to four): call existing schemas directly=\(Self.namesJSON(direct)); load other schemas by exact name=\(Self.namesJSON(loadable)). Ineligible requested names=\(ineligible). Check the current inventory before choosing a tool."
            case .unavailableTool: "A requested tool is not currently callable and allowed. No tool was loaded or executed."
            case let .unavailableSelection(unavailable, denied, unknownCount, direct, loadable):
                "No tool was loaded or executed. Rejected requested names (unavailable=\(Self.namesJSON(unavailable)), denied=\(Self.namesJSON(denied)), unknown_count=\(unknownCount)). Eligible requested names in the current inventory (call existing schemas directly=\(Self.namesJSON(direct)), load other schemas by exact name=\(Self.namesJSON(loadable)))."
            case let .budgetWithOfferedSchemas(names):
                "Load exceeds budget. No change or execution. Previously offered: \(Self.namesJSON(names)). Call directly if still listed."
            case .selectionTooLarge:
                "Schema load exceeds budget including loader history. No change or execution. Choose another fitting schema or a shorter task."
            }
        }

        private static func namesJSON(_ names: [String]) -> String {
            // Only validated, registered names reach this case (at most four,
            // each at most 256 UTF-8 bytes). Unknown requested text is not echoed.
            String(decoding: (try? JSONSerialization.data(withJSONObject: names, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8), as: UTF8.self)
        }
    }

    static var specification: [String: Any] {
        ["type": "function", "name": name,
         "description": "Load exact schemas for 1–4 inventory names for the next request. Read-only; executes nothing. Replaces the previous loaded selection. Use the current catalog_revision.",
         "inputSchema": argumentSchema()]
    }

    private static func argumentSchema(choices: [String]? = nil) -> [String: Any] {
        let items: Any
        if let choices {
            // minItems is one. A false items schema admits no names when none can load.
            items = choices.isEmpty ? false as Any : ["enum": choices] as Any
        } else {
            items = ["type": "string"]
        }
        return ["type": "object", "properties": [
            "catalog_revision": ["type": "string"],
            "names": ["type": "array", "items": items,
                      "minItems": 1, "maxItems": maximumLoadedTools, "uniqueItems": true],
        ], "required": ["catalog_revision", "names"], "additionalProperties": false]
    }

    // The pinned engine (4607249e430dac1c961df4dc615beae88e33cec8,
    // tools/src/json_schema/types.rs) preserves minItems but its JsonSchema
    // representation omits maxItems and uniqueItems. Accept only this exact
    // reviewed projection alongside the complete native declaration.
    private static var engineArgumentSchema: [String: Any] {
        var schema = argumentSchema()
        var properties = schema["properties"] as! [String: Any]
        var names = properties["names"] as! [String: Any]
        names.removeValue(forKey: "maxItems")
        names.removeValue(forKey: "uniqueItems")
        properties["names"] = names
        schema["properties"] = properties
        return schema
    }

    private static func matchesRegisteredSchema(_ schema: [String: Any]) -> Bool {
        guard let bytes = try? encoded(schema) else { return false }
        return bytes == (try? encoded(argumentSchema())) || bytes == (try? encoded(engineArgumentSchema))
    }

    /// Called only for the server's admitted native compact presentation. This
    /// restores loader bounds lost by the pinned engine; it never edits the
    /// original request/history or normalizes any other tool's contract.
    static func restoringRegisteredLoaderBounds(_ definition: [String: Any], namespace: String? = nil, choices: [String]? = nil) -> [String: Any] {
        guard namespace == nil || namespace == "functions",
              definition["type"] as? String == "function", definition["name"] as? String == name else { return definition }
        let keys = ["parameters", "inputSchema"].filter { definition[$0] != nil }
        guard !keys.isEmpty, keys.allSatisfy({ key in
            (definition[key] as? [String: Any]).map(matchesRegisteredSchema) == true
        }) else { return definition }
        var result = definition
        for key in keys { result[key] = argumentSchema(choices: choices) }
        return result
    }

    static func supports(modelID: String) -> Bool {
        WebsiteModelCatalog.choice(for: modelID)?.provider == "groq"
    }

    /// A native registration receipt is required independently by the server.
    /// This exact schema check prevents a conflicting same-name declaration
    /// from borrowing the registered loader's interpretation.
    static func isRegisteredLoader(_ definitions: [[String: Any]]) -> Bool {
        guard let flat = try? flatten(definitions) else { return false }
        let loaders = flat.filter { $0.definition["name"] as? String == name }
        guard loaders.count == 1, let loader = loaders.first,
              loader.namespace == nil || loader.namespace == "functions",
              loader.definition["type"] as? String == "function" else { return false }
        let schemaKeys = ["parameters", "inputSchema"].filter { loader.definition[$0] != nil }
        guard !schemaKeys.isEmpty else { return false }
        return schemaKeys.allSatisfy { key in
            guard let schema = loader.definition[key] as? [String: Any] else { return false }
            return matchesRegisteredSchema(schema)
        }
    }

    static func baseline(for seed: Seed) throws -> Projection {
        guard seed.registeredDefinitionsJSON.count <= 160 * 1_024,
              seed.toolChoiceJSON.count <= 160 * 1_024,
              let definitions = try? JSONSerialization.jsonObject(with: seed.registeredDefinitionsJSON) as? [[String: Any]],
              isRegisteredLoader(definitions),
              (try? JSONSerialization.jsonObject(with: seed.toolChoiceJSON, options: [.fragmentsAllowed])) != nil
        else { throw Failure.invalidCatalog }
        let flat = try flatten(definitions)
        let names = Set(flat.map(\.name))
        guard seed.callableNames.isSubset(of: names), seed.allowedNames.isSubset(of: names),
              seed.preloadNames.isSubset(of: seed.callableNames.intersection(seed.allowedNames)) else {
            throw Failure.invalidCatalog
        }
        let inventory = flat.map { item in
            Entry(name: item.name, summary: summary(item.definition["description"] as? String),
                  isCustom: item.definition["type"] as? String == "custom",
                  callable: seed.callableNames.contains(item.name), allowed: seed.allowedNames.contains(item.name))
        }.sorted { $0.name < $1.name }
        let loaders = Set(flat.filter { $0.definition["name"] as? String == name }.map(\.name))
        let selected = seed.preloadNames.union(loaders.intersection(seed.callableNames).intersection(seed.allowedNames))
        // Length-delimited values prevent a different set/policy from colliding
        // through ambiguous concatenation. Original schema/policy bytes bind too.
        var bytes = Data()
        for part in [seed.registeredDefinitionsJSON, seed.toolChoiceJSON,
                     try encoded(seed.callableNames.sorted()), try encoded(seed.allowedNames.sorted()),
                     try encoded(seed.preloadNames.sorted())] {
            bytes.append(contentsOf: "\(part.count):".utf8); bytes.append(part)
        }
        return Projection(revision: digest(bytes), inventory: inventory, selectedNames: selected)
    }

    static func validate(_ projection: Projection, for seed: Seed) throws {
        let baseline = try baseline(for: seed)
        guard projection.revision == baseline.revision, projection.inventory == baseline.inventory,
              baseline.selectedNames.isSubset(of: projection.selectedNames),
              projection.selectedNames.isSubset(of: seed.callableNames.intersection(seed.allowedNames)),
              projection.selectedNames.subtracting(baseline.selectedNames).count <= maximumLoadedTools else {
            throw Failure.invalidCatalog
        }
    }

    private struct State: Sendable {
        let scope: Scope
        let seed: Seed
        var projection: Projection
    }
    private var states: [String: State] = [:]

    mutating func prepare(scope: Scope, seed: Seed) throws -> Projection {
        try Self.validateScope(scope)
        let baseline = try Self.baseline(for: seed)
        let projection: Projection
        if let old = states[scope.taskID], old.scope == scope, old.projection.revision == baseline.revision {
            try Self.validate(old.projection, for: seed)
            projection = old.projection
        } else { projection = baseline }
        // The caller removes completed task state. Bound memory even if a
        // caller forgets; failure does not evict another live turn's selection.
        guard states[scope.taskID] != nil || states.count < 128 else { throw Failure.invalidCatalog }
        states[scope.taskID] = State(scope: scope, seed: seed, projection: projection)
        return projection
    }

    struct LoadPreview {
        let receipt: Data
        let budgetFailure: Failure
    }

    mutating func load(scope: Scope, arguments: Data, lastOfferedNames: Set<String> = []) throws -> Data {
        try previewLoad(scope: scope, arguments: arguments, lastOfferedNames: lastOfferedNames).receipt
    }

    mutating func previewLoad(scope: Scope, arguments: Data, lastOfferedNames: Set<String>) throws -> LoadPreview {
        try Self.validateScope(scope)
        guard var state = states[scope.taskID], state.scope == scope else { throw Failure.invalidScope }
        guard arguments.count <= 4_096,
              let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              Set(object.keys) == ["catalog_revision", "names"],
              let revision = object["catalog_revision"] as? String, Self.validDigest(revision),
              let names = object["names"] as? [String], !names.isEmpty,
              Set(names).count == names.count,
              names.allSatisfy(Self.validName) else { throw Failure.invalidArguments }
        guard revision == state.projection.revision else { throw Failure.staleRevision }
        let requested = Set(names)
        let baseline = try Self.baseline(for: state.seed)
        let loaderNames = Set(baseline.inventory.filter { $0.name == Self.name || $0.name == "functions." + Self.name }.map(\.name))
        guard !loaderNames.intersection(baseline.selectedNames).isEmpty,
              requested.isDisjoint(with: loaderNames) else {
            throw Failure.unavailableTool
        }
        let eligible = requested.intersection(state.seed.callableNames).intersection(state.seed.allowedNames)
        if names.count > Self.maximumLoadedTools || eligible != requested {
            // Never partially load. The last admitted offer distinguishes direct schemas from
            // other eligible names, including when the budget excluded default direct schemas.
            let direct = Array(eligible.intersection(lastOfferedNames).sorted().prefix(Self.maximumLoadedTools))
            let loadable = Array(eligible.subtracting(lastOfferedNames).sorted().prefix(Self.maximumLoadedTools - direct.count))
            if names.count > Self.maximumLoadedTools {
                throw Failure.tooManyNames(count: names.count, direct: direct, loadable: loadable,
                                           ineligible: names.count - eligible.count)
            }
            let registered = Set(baseline.inventory.map(\.name))
            let knownRequested = requested.intersection(registered)
            throw Failure.unavailableSelection(
                unavailable: knownRequested.subtracting(state.seed.callableNames).sorted(),
                denied: knownRequested.intersection(state.seed.callableNames).subtracting(state.seed.allowedNames).sorted(),
                unknownCount: requested.subtracting(registered).count, direct: direct, loadable: loadable)
        }
        let projection = Projection(revision: baseline.revision, inventory: baseline.inventory,
                                    selectedNames: baseline.selectedNames.union(requested))
        try Self.validate(projection, for: state.seed)
        let receipt = try Self.encoded(["catalog_revision": revision, "loaded": names.sorted(),
                                       "available": "next_request", "execution": false] as [String: Any])
        state.projection = projection
        states[scope.taskID] = state
        // Exact names reached this point only after every requested name passed
        // the current revision and availability checks. The next offer can change.
        let direct = requested.intersection(lastOfferedNames).sorted()
        return LoadPreview(receipt: receipt, budgetFailure: direct.isEmpty ? .selectionTooLarge : .budgetWithOfferedSchemas(direct))
    }

    mutating func remove(taskID: String) { states.removeValue(forKey: taskID) }
    mutating func removeAll() { states.removeAll() }

    private struct Definition {
        let name: String
        let namespace: String?
        let definition: [String: Any]
    }

    private static func flatten(_ definitions: [[String: Any]]) throws -> [Definition] {
        var result: [Definition] = []
        var names = Set<String>()
        func append(_ value: [String: Any], namespace: String?) throws {
            guard ["function", "custom"].contains(value["type"] as? String ?? ""),
                  let name = value["name"] as? String, validName(name),
                  value["description"] == nil || value["description"] is NSNull || value["description"] is String else {
                throw Failure.invalidCatalog
            }
            if value["type"] as? String == "function" {
                let schemas = ["parameters", "inputSchema"].filter { value[$0] != nil }
                guard !schemas.isEmpty, schemas.allSatisfy({ value[$0] is [String: Any] }) else { throw Failure.invalidCatalog }
            } else if let format = value["format"], !(format is [String: Any]) { throw Failure.invalidCatalog }
            let qualified = namespace.map { $0 + "." + name } ?? name
            guard validName(qualified), names.insert(qualified).inserted, result.count < 256 else { throw Failure.invalidCatalog }
            result.append(Definition(name: qualified, namespace: namespace, definition: value))
        }
        for definition in definitions {
            if definition["type"] as? String == "namespace" {
                guard let namespace = definition["name"] as? String, validName(namespace),
                      let children = definition["tools"] as? [[String: Any]] else { throw Failure.invalidCatalog }
                for child in children { try append(child, namespace: namespace) }
            } else { try append(definition, namespace: nil) }
        }
        return result
    }

    private static func summary(_ description: String?) -> String {
        // This label aids discovery only. Loading preserves the entire original
        // description, schema and custom grammar through the codec projection.
        String((description ?? "").split(whereSeparator: { $0.isNewline }).first.map(String.init)?.prefix(120) ?? "")
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validateScope(_ scope: Scope) throws {
        guard supports(modelID: scope.modelID), [scope.taskID, scope.threadID, scope.turnID].allSatisfy({
            UUID(uuidString: $0)?.uuidString.lowercased() == $0
        }) else { throw Failure.invalidScope }
    }
    private static func encoded(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Persist only a successful native thread registration, not loaded schemas or
/// execution permissions. Namespace, thread and exact concrete model all bind
/// the receipt, so restart/resume can preserve membership without migrating an
/// old thread or borrowing another model's registration.
enum GroqToolThreadRegistration {
    static let preferenceKey = "ComputaGroqToolThreads.v1"

    static func marker(codexHome: String, threadID: String, modelID: String) -> String? {
        guard GroqToolCatalog.supports(modelID: modelID), !threadID.isEmpty, threadID.utf8.count <= 256,
              !codexHome.isEmpty,
              let spec = try? JSONSerialization.data(withJSONObject: GroqToolCatalog.specification, options: [.sortedKeys]),
              let fields = try? JSONSerialization.data(withJSONObject: [codexHome, threadID, modelID,
                  SHA256.hash(data: spec).map { String(format: "%02x", $0) }.joined()]) else { return nil }
        return SHA256.hash(data: fields).map { String(format: "%02x", $0) }.joined()
    }

    static func contains(codexHome: String, threadID: String, modelID: String, defaults: UserDefaults = .standard) -> Bool {
        guard let marker = marker(codexHome: codexHome, threadID: threadID, modelID: modelID) else { return false }
        return (defaults.stringArray(forKey: preferenceKey) ?? []).suffix(512).contains(marker)
    }

    static func remember(codexHome: String, threadID: String, modelID: String, defaults: UserDefaults = .standard) {
        guard let marker = marker(codexHome: codexHome, threadID: threadID, modelID: modelID) else { return }
        var markers = (defaults.stringArray(forKey: preferenceKey) ?? []).filter {
            $0 != marker && $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }.suffix(511).map { $0 }
        markers.append(marker)
        defaults.set(markers, forKey: preferenceKey)
    }
}

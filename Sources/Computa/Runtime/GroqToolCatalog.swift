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
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidCatalog, invalidScope, staleRevision, invalidArguments, unavailableTool, selectionTooLarge
        var errorDescription: String? {
            switch self {
            case .invalidCatalog: "The registered tool catalog could not be verified. No tool was loaded or executed."
            case .invalidScope: "Tool loading does not belong to the current registered Groq turn. No tool was loaded or executed."
            case .staleRevision: "The tool catalog changed. Use its current revision and inventory; no tool was loaded or executed."
            case .invalidArguments: "Tool loading requires the current catalog_revision and one to four unique inventory names. No tool was loaded or executed."
            case .unavailableTool: "A requested tool is not currently callable and allowed. No tool was loaded or executed."
            case .selectionTooLarge:
                "These schemas do not fit the current Groq request budget plus the estimated loader-history allowance. Previous selection retained; request fewer or smaller schemas. No tool was loaded or executed."
            }
        }
    }

    static var specification: [String: Any] {
        ["type": "function", "name": name,
         "description": "Load exact schemas for 1–4 inventory names for the next request. Read-only; executes nothing. Replaces the previous loaded selection. Use the current catalog_revision.",
         "inputSchema": argumentSchema]
    }

    private static var argumentSchema: [String: Any] {
        ["type": "object", "properties": [
            "catalog_revision": ["type": "string"],
            "names": ["type": "array", "items": ["type": "string"]],
        ], "required": ["catalog_revision", "names"], "additionalProperties": false]
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
            return (try? encoded(schema)) == (try? encoded(argumentSchema))
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

    mutating func load(scope: Scope, arguments: Data) throws -> Data {
        try Self.validateScope(scope)
        guard var state = states[scope.taskID], state.scope == scope else { throw Failure.invalidScope }
        guard arguments.count <= 4_096,
              let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              Set(object.keys) == ["catalog_revision", "names"],
              let revision = object["catalog_revision"] as? String, Self.validDigest(revision),
              let names = object["names"] as? [String], !names.isEmpty,
              names.count <= Self.maximumLoadedTools, Set(names).count == names.count,
              names.allSatisfy(Self.validName) else { throw Failure.invalidArguments }
        guard revision == state.projection.revision else { throw Failure.staleRevision }
        let requested = Set(names)
        let baseline = try Self.baseline(for: state.seed)
        let loaderNames = Set(baseline.inventory.filter { $0.name == Self.name || $0.name == "functions." + Self.name }.map(\.name))
        guard !loaderNames.intersection(baseline.selectedNames).isEmpty,
              requested.isDisjoint(with: loaderNames),
              requested.isSubset(of: state.seed.callableNames.intersection(state.seed.allowedNames)) else {
            throw Failure.unavailableTool
        }
        let projection = Projection(revision: baseline.revision, inventory: baseline.inventory,
                                    selectedNames: baseline.selectedNames.union(requested))
        try Self.validate(projection, for: state.seed)
        let receipt = try Self.encoded(["catalog_revision": revision, "loaded": names.sorted(),
                                       "available": "next_request", "execution": false] as [String: Any])
        state.projection = projection
        states[scope.taskID] = state
        return receipt
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

import Foundation

struct APIModelDefinition: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let contextWindow: Int
    let supportsImages: Bool
    let supportsToolImages: Bool

    init(id: String, name: String, contextWindow: Int = 32_768, supportsImages: Bool = false,
         supportsToolImages: Bool = false) {
        self.id = id; self.name = name; self.contextWindow = contextWindow; self.supportsImages = supportsImages
        self.supportsToolImages = supportsToolImages
    }

    private enum CodingKeys: String, CodingKey { case id, name, contextWindow, supportsImages, supportsToolImages }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        contextWindow = try values.decode(Int.self, forKey: .contextWindow)
        supportsImages = try values.decode(Bool.self, forKey: .supportsImages)
        supportsToolImages = try values.decodeIfPresent(Bool.self, forKey: .supportsToolImages) ?? false
    }
}

struct APIProviderDefinition: Codable, Equatable, Sendable {
    enum WireAPI: String, Codable, CaseIterable, Sendable { case chatCompletions, responses }
    let id: String
    let name: String
    let baseURL: URL
    let wireAPI: WireAPI
    let models: [APIModelDefinition]

    static let cerebras = Self(id: "cerebras", name: "Cerebras", baseURL: URL(string: "https://api.cerebras.ai/v1")!,
                               wireAPI: .chatCompletions, models: [])

    /// Provider behavior follows the validated endpoint, independently of its user-chosen identity.
    var isCerebrasInference: Bool {
        (try? APIProviderCatalog.validate(self)) != nil && baseURL.scheme == "https"
            && baseURL.host?.lowercased() == "api.cerebras.ai"
            && (baseURL.port == nil || baseURL.port == 443)
            && ["/v1", "/v1/"].contains(URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "")
    }

    func withModels(_ models: [APIModelDefinition]) -> Self {
        Self(id: id, name: name, baseURL: baseURL, wireAPI: wireAPI, models: models)
    }
}

enum APIProviderCatalog {
    static let preferenceKey = "Computa.apiProviders.v1"
    // Keep Cerebras limited to GPT-OSS for now. Qwen3.8 27B is hidden because of its higher token usage.
    private static let showAdditionalCerebrasModels = false
    struct Identity: Equatable, Sendable { let providerID: String; let modelID: String }
    struct Selection: Equatable, Sendable { let provider: APIProviderDefinition; let model: APIModelDefinition }
    enum Failure: LocalizedError {
        case invalidProvider, invalidModel, duplicateProvider, duplicateModel, invalidCatalog
        var errorDescription: String? { "The API provider configuration is invalid. No request was sent." }
    }

    static func validProviderID(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    }
    private static func validField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value == value.precomposedStringWithCanonicalMapping
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func validate(_ provider: APIProviderDefinition) throws {
        guard validProviderID(provider.id), validField(provider.name), provider.models.count <= 256,
              let host = provider.baseURL.host, !host.isEmpty,
              provider.baseURL.user == nil, provider.baseURL.password == nil,
              provider.baseURL.query == nil, provider.baseURL.fragment == nil,
              provider.baseURL.absoluteString.utf8.count <= 2_048,
              provider.baseURL.scheme == "https" || provider.baseURL.scheme == "http"
                && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) else { throw Failure.invalidProvider }
        for model in provider.models {
            guard validField(model.id), validField(model.name), (1...10_000_000).contains(model.contextWindow) else { throw Failure.invalidModel }
        }
        guard Set(provider.models.map(\.id)).count == provider.models.count else { throw Failure.duplicateModel }
    }
    static func validate(_ providers: [APIProviderDefinition]) throws {
        guard providers.count <= 32 else { throw Failure.invalidCatalog }
        guard Set(providers.map(\.id)).count == providers.count else { throw Failure.duplicateProvider }
        for provider in providers { try validate(provider) }
    }

    static func appModelID(providerID: String, modelID: String) -> String {
        guard validProviderID(providerID), validField(modelID) else { return "" }
        let encoded = Data(modelID.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "api/\(providerID)/model/\(encoded)"
    }
    static func identity(for id: String) -> Identity? {
        guard id.utf8.count <= 512 else { return nil }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "api", parts[2] == "model", validProviderID(String(parts[1])) else { return nil }
        let raw = String(parts[3]), padding = String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + padding),
              let modelID = String(data: data, encoding: .utf8), validField(modelID),
              appModelID(providerID: String(parts[1]), modelID: modelID) == id else { return nil }
        return Identity(providerID: String(parts[1]), modelID: modelID)
    }
    static func selection(for id: String, providers: [APIProviderDefinition]) -> Selection? {
        guard let identity = identity(for: id), (try? validate(providers)) != nil,
              let provider = providers.first(where: { $0.id == identity.providerID }),
              let model = provider.models.first(where: { $0.id == identity.modelID }) else { return nil }
        return Selection(provider: provider, model: model)
    }
    static func options(for providers: [APIProviderDefinition]) -> [LocalModelOption] {
        guard (try? validate(providers)) != nil else { return [] }
        return providers.flatMap { provider in provider.models.filter { model in
            !provider.isCerebrasInference || showAdditionalCerebrasModels || model.id == "gpt-oss-120b"
        }.map { model in
            LocalModelOption(id: appModelID(providerID: provider.id, modelID: model.id),
                label: "\(provider.name) / \(model.name) · API",
                detail: "Uses \(model.name) through \(provider.name), with a \(model.contextWindow)-token context window. Your task tools and access mode apply.",
                highMemory: false, available: true)
        } }
    }
    /// Metadata only: this never adds a model unless the provider actually lists it.
    static func discoveredModel(id: String, name: String? = nil, provider: APIProviderDefinition) -> APIModelDefinition {
        if provider.isCerebrasInference, id == "qwen-3.8-27b" {
            return APIModelDefinition(id: id, name: name ?? "Qwen3.8 27B", contextWindow: 65_536,
                                      supportsImages: true, supportsToolImages: false)
        }
        return APIModelDefinition(id: id, name: name ?? id)
    }
    static func load(from preferences: UserDefaults) -> [APIProviderDefinition] {
        guard let data = preferences.data(forKey: preferenceKey), data.count <= 512 * 1_024,
              let providers = try? JSONDecoder().decode([APIProviderDefinition].self, from: data),
              (try? validate(providers)) != nil else { return [] }
        return providers
    }
    static func save(_ providers: [APIProviderDefinition], to preferences: UserDefaults) throws {
        try validate(providers)
        let data = try JSONEncoder().encode(providers)
        guard data.count <= 512 * 1_024 else { throw Failure.invalidCatalog }
        preferences.set(data, forKey: preferenceKey)
    }
}

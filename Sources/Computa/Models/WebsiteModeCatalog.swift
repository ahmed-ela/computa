import Foundation

/// Observed website behavior choices have their own cache. They never enter the
/// named-model catalog or imply a backend model/version.
enum WebsiteModeCatalog {
    static let preferenceKey = "Computa.websiteModeChoices.v1"

    static func validateObserved(_ choices: [WebsiteModeChoice], provider: String) throws {
        guard provider == "deepseek", choices.count == WebsiteModeChoice.DeepSeekMode.allCases.count,
              choices.allSatisfy({ $0.provider == provider }),
              Set(choices.map(\.key)) == Set(WebsiteModeChoice.DeepSeekMode.allCases.map(\.rawValue)) else {
            throw WebsiteModelCatalog.Failure.invalidChoices
        }
    }

    static func load(from preferences: UserDefaults) -> [WebsiteModeChoice] {
        guard let bytes = preferences.data(forKey: preferenceKey), bytes.count <= 2_048,
              let identifiers = try? JSONDecoder().decode([String].self, from: bytes), identifiers.count == 2 else { return [] }
        let choices = identifiers.compactMap(WebsiteModeChoice.parse(requestID:))
        guard choices.count == identifiers.count,
              (try? validateObserved(choices, provider: "deepseek")) != nil,
              WebsiteModelCatalog.providers.contains("deepseek") else { return [] }
        return choices
    }

    static func save(_ choices: [WebsiteModeChoice], to preferences: UserDefaults) {
        guard WebsiteModelCatalog.providers.contains("deepseek"),
              (try? validateObserved(choices, provider: "deepseek")) != nil,
              let bytes = try? JSONEncoder().encode(choices.map(\.requestID)) else { return }
        preferences.set(bytes, forKey: preferenceKey)
    }
}

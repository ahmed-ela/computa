import Foundation

/// A choice observed in the signed-in website's model menu. Neither model names
/// nor account availability are inferred from marketing catalogs or model prose.
struct WebsiteModelChoice: Codable, Equatable, Sendable {
    let provider: String
    let key: String
    let label: String

    var isValid: Bool {
        WebsiteModelCatalog.providers.contains(provider)
            && Self.validField(key) && Self.validField(label)
    }

    /// Retired choices retain their canonical identity for existing history,
    /// but cannot return through discovery, cache restoration or selection.
    var isRetired: Bool { provider == "chatgpt" && (key == "Latest" || label == "Latest") }
    var isSelectable: Bool { isValid && !isRetired }

    /// Self-contained identity preserves the exact website key and label across
    /// history/default restoration without a mutable global model registry.
    var modelID: String {
        guard isValid, let data = try? Self.encoder.encode(Identity(key: key, label: label)) else { return "" }
        return "browser/\(provider)/choice/" + Self.base64URL(data)
    }

    var canonicalJSONString: String? {
        guard isValid, let data = try? Self.encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ json: String) -> Self? {
        guard json.utf8.count <= 1_024, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(object.keys) == ["provider", "key", "label"],
              let choice = try? JSONDecoder().decode(Self.self, from: data), choice.isValid,
              choice.canonicalJSONString == json else { return nil }
        return choice
    }

    fileprivate struct Identity: Codable {
        let key: String
        let label: String
    }

    fileprivate static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    fileprivate static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func validField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.elementsEqual(value.precomposedStringWithCanonicalMapping.utf8)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum WebsiteModelCatalog {
    static let providers = ["chatgpt", "gemini", "claude"]
    static let maximumChoicesPerProvider = 32
    static let preferenceKey = "Computa.websiteModelChoices.v1"

    struct Selection: Equatable, Sendable {
        let provider: String
        let choice: WebsiteModelChoice?
    }

    enum Failure: LocalizedError {
        case invalidModelID, invalidChoices
        var errorDescription: String? {
            switch self {
            case .invalidModelID: "The saved website model choice is invalid. Choose a model from the selector. No prompt was sent."
            case .invalidChoices: "The website model menu could not be verified. Refresh its models after signing in."
            }
        }
    }

    static func providerLabel(_ provider: String) -> String {
        switch provider {
        case "chatgpt": "ChatGPT"
        case "gemini": "Gemini"
        case "claude": "Claude"
        default: provider
        }
    }

    static func selection(for modelID: String) -> Selection? {
        for provider in providers where modelID == "browser/\(provider)" {
            return Selection(provider: provider, choice: nil)
        }
        guard modelID.utf8.count <= 768 else { return nil }
        let parts = modelID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "browser", providers.contains(String(parts[1])), parts[2] == "choice" else { return nil }
        let encoded = String(parts[3])
        guard !encoded.isEmpty, encoded.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + padding),
              let identity = try? JSONDecoder().decode(WebsiteModelChoice.Identity.self, from: data) else { return nil }
        let choice = WebsiteModelChoice(provider: String(parts[1]), key: identity.key, label: identity.label)
        // Equality rejects duplicate/extra JSON fields, whitespace, alternate
        // Unicode escapes, padding and noncanonical encodings of the same choice.
        guard choice.isValid, choice.modelID == modelID else { return nil }
        return Selection(provider: choice.provider, choice: choice)
    }

    static func choice(for modelID: String) -> WebsiteModelChoice? { selection(for: modelID)?.choice }

    static func option(for choice: WebsiteModelChoice, available: Bool = true) -> LocalModelOption {
        let selectable = available && choice.isSelectable
        return LocalModelOption(id: choice.modelID,
            label: "\(providerLabel(choice.provider)) / \(choice.label) · Built-in browser",
            detail: choice.isRetired
                ? "This website model choice has been removed. Choose another model to continue."
                : selectable
                ? "Selects \(choice.label) in signed-in \(providerLabel(choice.provider)). Computa verifies the website's selected model before sending and accepting a response. Website limits still apply."
                : "Saved website choice: \(choice.label). It is absent from the latest observed menu. Refresh website models after signing in; Computa will not substitute another model.",
            highMemory: false, available: selectable)
    }

    static func validate(_ choices: [WebsiteModelChoice], provider: String) throws {
        guard providers.contains(provider), !choices.isEmpty, choices.count <= maximumChoicesPerProvider,
              choices.allSatisfy({ $0.isValid && $0.provider == provider }),
              Set(choices.map(\.key)).count == choices.count,
              Set(choices.map(\.label)).count == choices.count else { throw Failure.invalidChoices }
    }

    static func load(from preferences: UserDefaults) -> [WebsiteModelChoice] {
        guard let data = preferences.data(forKey: preferenceKey), data.count <= 100 * 1_024,
              let choices = try? JSONDecoder().decode([WebsiteModelChoice].self, from: data),
              choices.count <= providers.count * maximumChoicesPerProvider else { return [] }
        for provider in providers {
            let subset = choices.filter { $0.provider == provider }
            if !subset.isEmpty {
                do { try validate(subset, provider: provider) } catch { return [] }
            }
        }
        guard choices.allSatisfy(\.isValid) else { return [] }
        // Validate the complete stored catalog first: retiring a choice must
        // not hide duplicate or malformed entries from cache validation.
        let selectable = choices.filter(\.isSelectable)
        if selectable.count != choices.count { save(selectable, to: preferences) }
        return selectable
    }

    static func save(_ choices: [WebsiteModelChoice], to preferences: UserDefaults) {
        guard choices.count <= providers.count * maximumChoicesPerProvider, choices.allSatisfy(\.isValid) else { return }
        for provider in providers {
            let subset = choices.filter { $0.provider == provider }
            if !subset.isEmpty {
                do { try validate(subset, provider: provider) } catch { return }
            }
        }
        guard let data = try? WebsiteModelChoice.encoder.encode(choices.filter(\.isSelectable)) else { return }
        preferences.set(data, forKey: preferenceKey)
    }
}

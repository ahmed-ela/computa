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
    enum ChatGPTPower: String, CaseIterable, Sendable {
        case instant, medium, high, extraHigh = "extra-high", pro
        var label: String {
            switch self {
            case .instant: "Instant"
            case .medium: "Medium"
            case .high: "High"
            case .extraHigh: "Extra High"
            case .pro: "Pro"
            }
        }
        var modelKey: String { "chat/latest/" + rawValue }
    }

    var chatGPTPower: ChatGPTPower? {
        guard provider == "chatgpt" else { return nil }
        return ChatGPTPower.allCases.first { key == $0.modelKey }
    }

    var isRetired: Bool {
        guard provider == "chatgpt" else { return false }
        guard let power = chatGPTPower else { return true }
        if power == .pro {
            return label != "Pro" && (!label.hasSuffix(" Pro") || WebsiteModelCatalog.plainGPTVersion(String(label.dropLast(4))) == nil)
        }
        return label != power.label
    }
    var isSelectable: Bool { isValid && !isRetired }

    /// A canonical Pro intent names a policy, not an observed family label.
    /// Discovery and cached availability require the actual family display.
    var isObservedChoice: Bool { isSelectable && (chatGPTPower != .pro || label != "Pro") }

    /// Self-contained identity preserves the exact website key and label across
    /// history/default restoration without a mutable global model registry.
    var modelID: String {
        policyChoice.rawModelID
    }

    fileprivate var rawModelID: String {
        guard isValid, let data = try? Self.encoder.encode(Identity(key: key, label: label)) else { return "" }
        return "browser/\(provider)/choice/" + Self.base64URL(data)
    }

    /// The observed Pro family label is presentation. Its request identity
    /// follows the automatic family policy rather than freezing today's family.
    fileprivate var policyChoice: Self {
        chatGPTPower == .pro && isSelectable ? Self(provider: provider, key: key, label: "Pro") : self
    }

    var canonicalJSONString: String? {
        guard isValid, let data = try? Self.encoder.encode(policyChoice) else { return nil }
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
    /// A fresh profile selects normal Chat's Instant policy. This is an intent,
    /// not evidence of account availability; discovery still supplies the menu.
    static let freshProfileDefaultModelID = WebsiteModelChoice(
        provider: "chatgpt", key: WebsiteModelChoice.ChatGPTPower.instant.modelKey,
        label: WebsiteModelChoice.ChatGPTPower.instant.label
    ).modelID

    static let providers = ["chatgpt", "gemini", "claude"]
    static let maximumChoicesPerProvider = 32
    static let preferenceKey = "Computa.websiteModelChoices.v3-chat-latest-power"
    static let priorPreferenceKey = "Computa.websiteModelChoices.v2-chat-product"
    static let legacyPreferenceKey = "Computa.websiteModelChoices.v1"

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
        guard choice.isValid, choice.rawModelID == modelID else { return nil }
        return Selection(provider: choice.provider, choice: choice)
    }

    static func choice(for modelID: String) -> WebsiteModelChoice? { selection(for: modelID)?.choice }

    /// History retains structurally valid old IDs; a new inference must use the
    /// current normal-Chat preset contract, including an explicit power choice.
    static func inferenceSelection(for modelID: String) -> Selection? {
        guard let selected = selection(for: modelID) else { return nil }
        if selected.provider == "chatgpt" {
            guard let choice = selected.choice, choice.isSelectable, choice.modelID == modelID else { return nil }
        } else if let choice = selected.choice, !choice.isSelectable { return nil }
        return selected
    }

    /// Decimal components are bounded by the existing 128-byte field limit and
    /// compared without machine-integer conversion or lexical version ordering.
    static func plainGPTVersion(_ label: String) -> [String]? {
        guard label.utf8.count <= 128, label.hasPrefix("GPT-") else { return nil }
        var components = label.dropFirst(4).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ component in
            !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
                && (component == "0" || component.first != "0")
        }), components[0] != "0" else { return nil }
        while components.count > 1 && components.last == "0" { components.removeLast() }
        return components
    }

    static func highestOfferedPlainGPTFamily(_ labels: [String]) -> String? {
        guard !labels.isEmpty, labels.count <= maximumChoicesPerProvider else { return nil }
        var seen = Set<[String]>()
        var highest: (String, [String])?
        for label in labels {
            guard let version = plainGPTVersion(label), seen.insert(version).inserted else { return nil }
            if let prior = highest {
                var greater = false
                for index in 0..<max(version.count, prior.1.count) {
                    let lhs = index < version.count ? version[index] : "0"
                    let rhs = index < prior.1.count ? prior.1[index] : "0"
                    if lhs == rhs { continue }
                    greater = lhs.count == rhs.count ? lhs > rhs : lhs.count > rhs.count
                    break
                }
                if greater { highest = (label, version) }
            } else { highest = (label, version) }
        }
        return highest?.0
    }

    static func option(for choice: WebsiteModelChoice, available: Bool = true) -> LocalModelOption {
        let selectable = available && choice.isObservedChoice
        return LocalModelOption(id: choice.modelID,
            label: "\(providerLabel(choice.provider)) / \(choice.label) · Built-in browser",
            detail: choice.isRetired
                ? "This website model choice has been removed. Choose another model to continue."
                : selectable && choice.provider == "chatgpt"
                ? "Uses the newest available GPT family in ChatGPT Chat with \(choice.chatGPTPower?.label ?? choice.label) power. Computa verifies the website's family and power before sending and accepting a response. Website limits still apply."
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

    static func validateObserved(_ choices: [WebsiteModelChoice], provider: String) throws {
        try validate(choices, provider: provider)
        guard choices.allSatisfy(\.isObservedChoice) else { throw Failure.invalidChoices }
    }

    static func load(from preferences: UserDefaults) -> [WebsiteModelChoice] {
        let storedKey = preferences.data(forKey: preferenceKey) != nil ? preferenceKey
            : preferences.data(forKey: priorPreferenceKey) != nil ? priorPreferenceKey : legacyPreferenceKey
        let legacy = storedKey != preferenceKey
        guard let data = preferences.data(forKey: storedKey), data.count <= 100 * 1_024,
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
        // Earlier catalogs did not bind an automatic latest family to a Chat
        // power preset. Retire only those provider entries until fresh discovery.
        let selectable = choices.filter { $0.isObservedChoice && (!legacy || $0.provider != "chatgpt") }
        if legacy || selectable.count != choices.count { save(selectable, to: preferences) }
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
        guard let data = try? WebsiteModelChoice.encoder.encode(choices.filter(\.isObservedChoice)) else { return }
        preferences.set(data, forKey: preferenceKey)
    }
}

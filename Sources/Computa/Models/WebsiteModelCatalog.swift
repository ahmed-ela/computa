import Foundation

/// A choice observed in the signed-in website's model menu. Neither model names
/// nor account availability are inferred from marketing catalogs or model prose.
struct WebsiteModelChoice: Codable, Equatable, Sendable {
    let provider: String
    let key: String
    let label: String

    static let claudeHaiku55 = Self(provider: "claude", key: "Haiku 5.5", label: "Haiku 5.5")
    static let claudeOpus3 = Self(provider: "claude", key: "Opus 3", label: "Opus 3")

    var isValid: Bool {
        provider != "deepseek" && WebsiteModelCatalog.knownProviders.contains(provider)
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

    var supportsClaudeTurnPilot: Bool {
        self == Self.claudeHaiku55
    }

    var isRetired: Bool {
        if provider == "kimi" { return key != "k28-instant" || label != "Instant" }
        // Observed Plus/Max are staged for a native pilot. Omni remains
        // unavailable; this policy does not alias Alibaba's API model IDs.
        if provider == "qwen" { return key != label || !["Qwen3.7-Plus", "Qwen3.8-Max"].contains(key) }
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

    // Kimi Instant has passed offline adapter/native gates and is admitted for
    // the installed pilot. Live tool qualification remains pending; agent modes
    // stay excluded by the exact key/label policy in WebsiteModelChoice.
    static let providers = ["chatgpt", "gemini", "claude", "groq", "kimi", "qwen", "deepseek"]
    // Groq is temporarily paused in the picker and in catalog discovery.
    static let discoveryProviders = providers.filter { $0 != "groq" }
    // The pilot exposes only observed Plus/Max names and typed Chat/DeepThink modes.
    static let knownProviders = ["chatgpt", "gemini", "claude", "groq", "kimi", "qwen", "deepseek"]
    static let maximumChoicesPerProvider = 32
    static let preferenceKey = "Computa.websiteModelChoices.v4-claude-selectable-rows"
    static let priorSelectableRowsPreferenceKey = "Computa.websiteModelChoices.v3-chat-latest-power"
    static let priorPreferenceKey = "Computa.websiteModelChoices.v2-chat-product"
    static let legacyPreferenceKey = "Computa.websiteModelChoices.v1"

    struct Selection: Equatable, Sendable {
        let provider: String
        let choice: WebsiteModelChoice?
        let modeChoice: WebsiteModeChoice?
        init(provider: String, choice: WebsiteModelChoice?, modeChoice: WebsiteModeChoice? = nil) {
            self.provider = provider; self.choice = choice; self.modeChoice = modeChoice
        }
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
        case "groq": "Groq"
        case "kimi": "Kimi"
        case "qwen": "Qwen"
        case "deepseek": "DeepSeek"
        default: provider
        }
    }

    static func selection(for modelID: String) -> Selection? {
        if let mode = WebsiteModeChoice.parse(requestID: modelID) {
            return Selection(provider: mode.provider, choice: nil, modeChoice: mode)
        }
        for provider in providers where modelID == "browser/\(provider)" {
            return Selection(provider: provider, choice: nil)
        }
        guard modelID.utf8.count <= 768 else { return nil }
        let parts = modelID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "browser", knownProviders.contains(String(parts[1])), parts[2] == "choice" else { return nil }
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

    /// History retains structurally valid old IDs; inference requires the
    /// current provider policy, including explicit ChatGPT power and saved-conversation choices.
    static func inferenceSelection(for modelID: String) -> Selection? {
        guard let selected = selection(for: modelID), providers.contains(selected.provider) else { return nil }
        if selected.provider == "deepseek" {
            guard selected.choice == nil, let mode = selected.modeChoice, mode.requestID == modelID else { return nil }
        } else if selected.provider == "chatgpt" {
            guard let choice = selected.choice, choice.isSelectable, choice.modelID == modelID else { return nil }
        } else if ["kimi", "qwen"].contains(selected.provider) {
            guard let choice = selected.choice, choice.isSelectable else { return nil }
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
        let selectable = available && providers.contains(choice.provider) && choice.isObservedChoice
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

    /// Mode labels are explicit behavior choices; backend identity remains unclaimed.
    static func option(for mode: WebsiteModeChoice, available: Bool = false) -> LocalModelOption {
        LocalModelOption(id: mode.requestID, label: "DeepSeek / \(mode.label) · Built-in browser",
            detail: "Uses DeepSeek's \(mode.label) website mode with Search off. No backend model or version is attested.",
            highMemory: false, available: available && providers.contains(mode.provider))
    }

    static func validate(_ choices: [WebsiteModelChoice], provider: String) throws {
        guard knownProviders.contains(provider), !choices.isEmpty, choices.count <= maximumChoicesPerProvider,
              choices.allSatisfy({ $0.isValid && $0.provider == provider }),
              Set(choices.map(\.key)).count == choices.count,
              Set(choices.map(\.label)).count == choices.count else { throw Failure.invalidChoices }
    }

    static func validateObserved(_ choices: [WebsiteModelChoice], provider: String) throws {
        try validate(choices, provider: provider)
        guard choices.allSatisfy(\.isObservedChoice) else { throw Failure.invalidChoices }
    }

    static func load(from preferences: UserDefaults) -> [WebsiteModelChoice] {
        let keys = [preferenceKey, priorSelectableRowsPreferenceKey, priorPreferenceKey, legacyPreferenceKey]
        guard let storedKey = keys.first(where: { preferences.object(forKey: $0) != nil }),
              let data = preferences.data(forKey: storedKey), data.count <= 100 * 1_024,
              let choices = try? JSONDecoder().decode([WebsiteModelChoice].self, from: data),
              choices.count <= knownProviders.count * maximumChoicesPerProvider else { return [] }
        for provider in knownProviders {
            let subset = choices.filter { $0.provider == provider }
            if !subset.isEmpty {
                do { try validate(subset, provider: provider) } catch { return [] }
            }
        }
        guard choices.allSatisfy(\.isValid) else { return [] }
        // Validate the complete stored catalog first: retiring a choice must
        // not hide duplicate or malformed entries from cache validation.
        // Pre-v4 Claude catalogs do not prove selectable row semantics. Leave
        // that provider missing for normal idle discovery. v3 already bound Chat
        // presets to a family. Saved task/default identities are independent.
        let legacyChat = storedKey == priorPreferenceKey || storedKey == legacyPreferenceKey
        let selectable = choices.filter { choice in
            providers.contains(choice.provider) && choice.isObservedChoice
                && (choice.provider != "claude" || storedKey == preferenceKey)
                && (choice.provider != "chatgpt" || !legacyChat)
        }
        if storedKey != preferenceKey || selectable.count != choices.count { save(selectable, to: preferences) }
        return selectable
    }

    static func save(_ choices: [WebsiteModelChoice], to preferences: UserDefaults) {
        guard choices.count <= knownProviders.count * maximumChoicesPerProvider, choices.allSatisfy(\.isValid) else { return }
        for provider in knownProviders {
            let subset = choices.filter { $0.provider == provider }
            if !subset.isEmpty {
                do { try validate(subset, provider: provider) } catch { return }
            }
        }
        guard let data = try? WebsiteModelChoice.encoder.encode(choices.filter { providers.contains($0.provider) && $0.isObservedChoice }) else { return }
        preferences.set(data, forKey: preferenceKey)
    }
}

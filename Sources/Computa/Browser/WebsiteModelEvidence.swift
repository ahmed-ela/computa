import Foundation

/// Website controls and response attributes are independent of the model's
/// prose and of the Responses endpoint's echoed request model ID.
struct WebsiteModelEvidence: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let key: String
        let label: String
    }

    struct ResponseIdentity: Codable, Equatable, Sendable {
        let key: String
        let label: String
        let source: String
    }

    struct ChatSelection: Codable, Equatable, Sendable {
        struct AutomaticFamily: Codable, Equatable, Sendable {
            let policy: String
            let offered: [String]
        }
        let family: Identity
        let power: Identity
        let automaticFamily: AutomaticFamily

        var dictionary: [String: Any] {
            ["family": ["key": family.key, "label": family.label],
             "power": ["key": power.key, "label": power.label],
             "automaticFamily": ["policy": automaticFamily.policy, "offered": automaticFamily.offered]]
        }

        static func parse(_ raw: Any?, selected: WebsiteModelChoice) throws -> Self {
            guard let value = raw as? [String: Any], Set(value.keys) == ["family", "power", "automaticFamily"],
                  let family = value["family"] as? [String: String], Set(family.keys) == ["key", "label"],
                  let familyKey = family["key"], let familyLabel = family["label"], familyKey == familyLabel,
                  WebsiteModelCatalog.plainGPTVersion(familyKey) != nil,
                  let power = value["power"] as? [String: String], Set(power.keys) == ["key", "label"],
                  let powerKey = power["key"], let powerLabel = power["label"],
                  let preset = WebsiteModelChoice.ChatGPTPower(rawValue: powerKey), powerLabel == preset.label,
                  let automatic = value["automaticFamily"] as? [String: Any], Set(automatic.keys) == ["policy", "offered"],
                  automatic["policy"] as? String == "highest_offered_plain_gpt",
                  let offered = automatic["offered"] as? [String],
                  let highest = WebsiteModelCatalog.highestOfferedPlainGPTFamily(offered) else { throw Failure.unverified }
            guard familyKey == highest, selected.chatGPTPower == preset,
                  (preset == .pro ? selected.label == "Pro" || selected.label == familyLabel + " Pro"
                    : selected.label == powerLabel) else { throw Failure.mismatch }
            return Self(family: Identity(key: familyKey, label: familyLabel), power: Identity(key: powerKey, label: powerLabel),
                        automaticFamily: AutomaticFamily(policy: "highest_offered_plain_gpt", offered: offered))
        }
    }

    enum Failure: Error { case unverified, mismatch }

    let selected: Identity
    let response: ResponseIdentity?
    let verification: String
    let source: String?
    let chatSelection: ChatSelection?

    static func parse(_ raw: Any?, provider: String, expected: WebsiteModelChoice? = nil) throws -> Self {
        guard let value = raw as? [String: Any],
              Set(value.keys).isSubset(of: ["selected", "response", "verification", "source", "chatSelection"]),
              let selection = value["selected"] as? [String: String],
              Set(selection.keys) == ["key", "label"],
              let key = selection["key"], let label = selection["label"],
              WebsiteModelChoice(provider: provider, key: key, label: label).isValid,
              let verification = value["verification"] as? String,
              ["website_selection", "response_reported"].contains(verification) else { throw Failure.unverified }
        if let expected, expected.provider != provider || expected.key != key || expected.label != label {
            throw Failure.mismatch
        }
        var response: ResponseIdentity?
        if let rawResponse = value["response"] {
            guard let attribution = rawResponse as? [String: String],
                  Set(attribution.keys) == ["key", "label", "source"],
                  let responseKey = attribution["key"], let responseLabel = attribution["label"],
                  let source = attribution["source"], ["response_attribute", "response_label"].contains(source),
                  WebsiteModelChoice(provider: provider, key: responseKey, label: responseLabel).isValid else {
                throw Failure.unverified
            }
            guard responseKey == key, responseLabel == label else { throw Failure.mismatch }
            response = ResponseIdentity(key: responseKey, label: responseLabel, source: source)
        }
        guard (response == nil && verification == "website_selection")
                || (response != nil && verification == "response_reported") else { throw Failure.unverified }
        var source: String?
        if let rawSource = value["source"] {
            guard let name = rawSource as? String,
                  ["model_picker_label", "checked_model_option", "selected_model_indicator"].contains(name) else { throw Failure.unverified }
            source = name
        }
        let selectedChoice = WebsiteModelChoice(provider: provider, key: key, label: label)
        var chatSelection: ChatSelection?
        if selectedChoice.chatGPTPower != nil {
            guard selectedChoice.isSelectable, source == "selected_model_indicator",
                  response == nil, verification == "website_selection" else { throw Failure.unverified }
            chatSelection = try ChatSelection.parse(value["chatSelection"], selected: selectedChoice)
        } else if value["chatSelection"] != nil { throw Failure.unverified }
        return Self(selected: Identity(key: key, label: label), response: response, verification: verification,
                    source: source, chatSelection: chatSelection)
    }

    /// An automatic policy is resolved once per inference. A stable Medium ID
    /// must not hide a checked family or power change after the first proof.
    func isSameResolvedSelection(as other: Self) -> Bool {
        selected == other.selected && chatSelection?.family == other.chatSelection?.family
            && chatSelection?.power == other.chatSelection?.power
            && chatSelection?.automaticFamily.policy == other.chatSelection?.automaticFamily.policy
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = ["selected": ["key": selected.key, "label": selected.label],
                                    "verification": verification]
        if let response { value["response"] = ["key": response.key, "label": response.label, "source": response.source] }
        if let source { value["source"] = source }
        if let chatSelection { value["chatSelection"] = chatSelection.dictionary }
        return value
    }
}

/// Product mode is separate from the model label: the same model can appear
/// in both ChatGPT Chat and Work. The fixed adapter obtains this proof from
/// current product controls or the explicit Chat composer marker on the owned
/// empty root page before it claims the temporary-chat transition.
struct WebsiteProductModeEvidence: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case composerModeControl = "composer_mode_control"
        case chatComposerMarker = "chat_composer_marker"
    }
    enum TemporaryTransition: String, Codable, Sendable { case notRequested = "not_requested", acknowledged }
    enum Failure: Error { case unverified }
    let source: Source
    let temporaryTransition: TemporaryTransition

    static func parse(_ raw: Any?, requireTemporary: Bool = false) throws -> Self {
        guard let value = raw as? [String: String],
              Set(value.keys) == ["product", "mode", "source", "temporaryTransition"],
              value["product"] == "chatgpt", value["mode"] == "chat",
              let rawSource = value["source"], let source = Source(rawValue: rawSource),
              let rawTransition = value["temporaryTransition"],
              let transition = TemporaryTransition(rawValue: rawTransition),
              !requireTemporary || transition == .acknowledged else { throw Failure.unverified }
        return Self(source: source, temporaryTransition: transition)
    }

    var dictionary: [String: String] {
        ["product": "chatgpt", "mode": "chat", "source": source.rawValue,
         "temporaryTransition": temporaryTransition.rawValue]
    }
}

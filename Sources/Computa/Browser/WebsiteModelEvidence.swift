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

    enum Failure: Error { case unverified, mismatch }

    let selected: Identity
    let response: ResponseIdentity?
    let verification: String
    let source: String?

    static func parse(_ raw: Any?, provider: String, expected: WebsiteModelChoice? = nil) throws -> Self {
        guard let value = raw as? [String: Any],
              Set(value.keys).isSubset(of: ["selected", "response", "verification", "source"]),
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
        return Self(selected: Identity(key: key, label: label), response: response, verification: verification, source: source)
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = ["selected": ["key": selected.key, "label": selected.label],
                                    "verification": verification]
        if let response { value["response"] = ["key": response.key, "label": response.label, "source": response.source] }
        if let source { value["source"] = source }
        return value
    }
}

import CoreFoundation
import Foundation

/// A website behavior choice, not a backend model identity. These closed values
/// come from DeepSeek's observed DeepThink toggle. Search is independently off.
struct WebsiteModeChoice: Equatable, Sendable {
    enum DeepSeekMode: String, CaseIterable, Sendable {
        case chat, deepthink

        var label: String { self == .chat ? "Chat" : "DeepThink" }
    }

    let deepSeekMode: DeepSeekMode
    var provider: String { "deepseek" }
    var key: String { deepSeekMode.rawValue }
    var label: String { deepSeekMode.label }
    var dictionary: [String: String] { ["key": key, "label": label] }

    /// Future transport identity only. Parsing this ID does not enable public
    /// discovery or inference. A mode cannot masquerade as a model /choice/ ID.
    var requestID: String { "browser/deepseek/mode/" + key }

    var canonicalJSONString: String {
        // Both interpolated values are closed ASCII enum constants.
        #"{"key":"\#(key)","label":"\#(label)","provider":"deepseek"}"#
    }

    static func parse(_ json: String) -> Self? {
        guard json.utf8.count <= 256,
              let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
              Set(raw.keys) == ["provider", "key", "label"], let provider = raw["provider"],
              let key = raw["key"], let label = raw["label"],
              let choice = parse(["key": key, "label": label], provider: provider),
              choice.canonicalJSONString == json else { return nil }
        return choice
    }

    static func parse(_ raw: Any?, provider: String) -> Self? {
        guard provider == "deepseek", let value = raw as? [String: String],
              Set(value.keys) == ["key", "label"], let key = value["key"],
              let mode = DeepSeekMode(rawValue: key), value["label"] == mode.label else { return nil }
        return Self(deepSeekMode: mode)
    }

    static func parse(requestID: String) -> Self? {
        DeepSeekMode.allCases.map { Self(deepSeekMode: $0) }.first { $0.requestID == requestID }
    }
}

/// Exact control-state evidence. The explicit null backendModel field prevents
/// absence from being mistaken for an unobserved but asserted backend version.
struct WebsiteModeEvidence: Equatable, Sendable {
    enum Failure: Error { case unverified, mismatch }
    let selected: WebsiteModeChoice

    private init(selected: WebsiteModeChoice) { self.selected = selected }

    static func parse(_ raw: Any?, provider: String, expected: WebsiteModeChoice) throws -> Self {
        guard provider == expected.provider,
              let value = raw as? [String: Any],
              Set(value.keys) == ["selected", "source", "backendModel", "search"],
              let selected = WebsiteModeChoice.parse(value["selected"], provider: provider),
              value["source"] as? String == "website_mode_toggle",
              value["backendModel"] is NSNull,
              let search = value["search"] as? NSNumber,
              CFGetTypeID(search) == CFBooleanGetTypeID(), !search.boolValue else { throw Failure.unverified }
        guard selected == expected else { throw Failure.mismatch }
        return Self(selected: selected)
    }

    var dictionary: [String: Any] {
        ["selected": selected.dictionary, "source": "website_mode_toggle", "backendModel": NSNull(), "search": false]
    }
}

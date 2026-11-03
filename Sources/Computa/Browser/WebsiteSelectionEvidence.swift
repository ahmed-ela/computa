import Foundation

/// Native admission determines this case. A page cannot choose its own proof
/// kind, and a request's transport model field is not backend attestation.
enum WebsiteSelectionIntent: Equatable, Sendable {
    case model(WebsiteModelChoice)
    case mode(WebsiteModeChoice)

    var provider: String {
        switch self { case .model(let choice): choice.provider; case .mode(let choice): choice.provider }
    }

    var discoveryAction: String {
        switch self { case .model: "discoverModels"; case .mode: "discoverModes" }
    }
    var selectAction: String {
        switch self { case .model: "selectModel"; case .mode: "selectMode" }
    }
    var verifyAction: String {
        switch self { case .model: "verifyModel"; case .mode: "verifyMode" }
    }

    /// Merge into a fresh adapter input. Never retain the other proof kind's
    /// fields when a session changes provider or selection intent.
    var expectedAdapterInput: [String: Any] {
        switch self {
        case .model(let choice): ["expectedModelChoice": ["key": choice.key, "label": choice.label]]
        case .mode(let choice): ["expectedModeChoice": choice.dictionary]
        }
    }
    var selectAdapterInput: [String: Any] {
        switch self {
        case .model(let choice): ["modelChoice": ["key": choice.key, "label": choice.label]]
        case .mode(let choice): ["modeChoice": choice.dictionary]
        }
    }
}

/// Keep the existing model parser unchanged, with an explicit alternative for
/// mode controls. Saved-delete leases retain this typed proof as well as the
/// exact view, generation, route, first-user fingerprint and selection intent.
enum WebsiteSelectionEvidence: Equatable, Sendable {
    case model(WebsiteModelEvidence)
    case mode(WebsiteModeEvidence)

    enum Failure: Error { case unverified, mismatch }

    /// Existing provider defaults may resolve a named model from observation.
    /// DeepSeek cannot use that path: its mode intent must already be explicit.
    static func parse(snapshot: [String: Any], provider: String, expectedModel: WebsiteModelChoice?,
                      expectedMode: WebsiteModeChoice?) throws -> Self {
        if provider == "deepseek" {
            guard expectedModel == nil, let expectedMode, expectedMode.provider == provider else { throw Failure.unverified }
            return try parse(snapshot: snapshot, intent: .mode(expectedMode))
        }
        guard expectedMode == nil, snapshot["modeEvidence"] == nil else { throw Failure.unverified }
        do { return .model(try WebsiteModelEvidence.parse(snapshot["modelEvidence"], provider: provider, expected: expectedModel)) }
        catch WebsiteModelEvidence.Failure.mismatch { throw Failure.mismatch }
        catch { throw Failure.unverified }
    }

    var namedModel: WebsiteModelEvidence? {
        guard case .model(let evidence) = self else { return nil }
        return evidence
    }

    static func parse(snapshot: [String: Any], intent: WebsiteSelectionIntent) throws -> Self {
        switch intent {
        case .model(let expected):
            guard expected.provider != "deepseek", snapshot["modeEvidence"] == nil else { throw Failure.unverified }
            do { return .model(try WebsiteModelEvidence.parse(snapshot["modelEvidence"], provider: expected.provider, expected: expected)) }
            catch WebsiteModelEvidence.Failure.mismatch { throw Failure.mismatch }
            catch { throw Failure.unverified }
        case .mode(let expected):
            guard snapshot["modelEvidence"] == nil else { throw Failure.unverified }
            do { return .mode(try WebsiteModeEvidence.parse(snapshot["modeEvidence"], provider: expected.provider, expected: expected)) }
            catch WebsiteModeEvidence.Failure.mismatch { throw Failure.mismatch }
            catch { throw Failure.unverified }
        }
    }

    func isSameResolvedSelection(as other: Self) -> Bool {
        switch (self, other) {
        case let (.model(lhs), .model(rhs)): lhs.isSameResolvedSelection(as: rhs)
        case let (.mode(lhs), .mode(rhs)): lhs == rhs
        default: false
        }
    }

    var snapshotField: String {
        switch self { case .model: "modelEvidence"; case .mode: "modeEvidence" }
    }
    var responseMetadataField: String {
        switch self { case .model: "computa_website_model"; case .mode: "computa_website_mode" }
    }
    var dictionary: [String: Any] {
        switch self { case .model(let evidence): evidence.dictionary; case .mode(let evidence): evidence.dictionary }
    }

    /// Host proof must replace both reserved keys; client metadata cannot attach
    /// a fabricated model identity to a correctly verified website mode.
    func responseMetadata(preserving metadata: [String: Any]) -> [String: Any] {
        var result = metadata
        result.removeValue(forKey: "computa_website_model")
        result.removeValue(forKey: "computa_website_mode")
        result[responseMetadataField] = dictionary
        return result
    }
}

import Foundation
import XCTest
@testable import Computa

final class APIProviderCatalogTests: XCTestCase {
    func testAPIModelIdentityIsStableNamespacedAndRequiresRegisteredModel() throws {
        let model = APIProviderCatalog.discoveredModel(id: "qwen-3.8-27b", provider: .cerebras)
        let provider = APIProviderDefinition.cerebras.withModels([model])
        let id = APIProviderCatalog.appModelID(providerID: provider.id, modelID: model.id)
        XCTAssertEqual(APIProviderCatalog.identity(for: id)?.modelID, model.id)
        XCTAssertEqual(APIProviderCatalog.selection(for: id, providers: [provider])?.model, model)
        XCTAssertNil(APIProviderCatalog.selection(for: id, providers: []))
        XCTAssertNil(APIProviderCatalog.identity(for: id + "="))
        XCTAssertNil(APIProviderCatalog.identity(for: id.replacingOccurrences(of: "api/", with: "browser/")))
        let renamed = APIProviderDefinition(id: provider.id, name: "My Cerebras", baseURL: provider.baseURL,
            wireAPI: provider.wireAPI, models: [model, APIModelDefinition(id: "gpt-oss-120b", name: "Custom display")])
        XCTAssertEqual(APIProviderCatalog.options(for: [renamed]).map(\.id),
            [APIProviderCatalog.appModelID(providerID: provider.id, modelID: "gpt-oss-120b")])
    }
    func testCatalogUsesActualDiscoveredModelsAndConservativeMetadata() {
        XCTAssertTrue(APIProviderCatalog.options(for: [.cerebras]).isEmpty)
        let known = APIProviderCatalog.discoveredModel(id: "qwen-3.8-27b", provider: .cerebras)
        XCTAssertEqual(known.contextWindow, 65_536); XCTAssertTrue(known.supportsImages); XCTAssertFalse(known.supportsToolImages)
        let other = APIProviderCatalog.discoveredModel(id: "unknown-future-model", provider: .cerebras)
        XCTAssertEqual(other.contextWindow, 32_768); XCTAssertFalse(other.supportsImages); XCTAssertFalse(other.supportsToolImages)
        XCTAssertTrue(APIProviderCatalog.options(for: [.cerebras.withModels([known])]).isEmpty)
        let oss = APIProviderCatalog.discoveredModel(id: "gpt-oss-120b", provider: .cerebras)
        XCTAssertEqual(APIProviderCatalog.options(for: [.cerebras.withModels([known, oss, other])]).map(\.id),
            [APIProviderCatalog.appModelID(providerID: "cerebras", modelID: oss.id)])
        // An editable provider ID cannot grant another endpoint Cerebras-specific behavior.
        for address in ["http://127.0.0.1:1234/v1", "https://other.example/v1", "https://api.cerebras.ai:444/v1",
                        "https://api.cerebras.ai/v2", "https://api.cerebras.ai/v1//", "https://api.cerebras.ai/v1?key=fixture"] {
            let custom = APIProviderDefinition(id: "cerebras", name: "Custom", baseURL: URL(string: address)!,
                                              wireAPI: .chatCompletions, models: [])
            XCTAssertFalse(custom.isCerebrasInference, address)
            let generic = APIProviderCatalog.discoveredModel(id: known.id, provider: custom)
            XCTAssertEqual(generic.contextWindow, 32_768); XCTAssertFalse(generic.supportsImages)
            if (try? APIProviderCatalog.validate(custom)) != nil {
                XCTAssertEqual(APIProviderCatalog.options(for: [custom.withModels([generic])]).count, 1)
            }
        }
        for address in ["https://api.cerebras.ai/v1", "https://api.cerebras.ai:443/v1/"] {
            let official = APIProviderDefinition(id: "my-cerebras", name: "My endpoint", baseURL: URL(string: address)!,
                                                wireAPI: .chatCompletions, models: [])
            XCTAssertTrue(official.isCerebrasInference)
            XCTAssertEqual(APIProviderCatalog.discoveredModel(id: known.id, provider: official), known)
        }
    }
    func testUnsafeEndpointsAndAmbiguousModelCatalogsCannotBeAdmitted() {
        for address in ["http://remote.example/v1", "https://name:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#secret"] {
            let provider = APIProviderDefinition(id: "fixture", name: "Fixture", baseURL: URL(string: address)!, wireAPI: .responses, models: [])
            XCTAssertThrowsError(try APIProviderCatalog.validate(provider))
        }
        let local = APIProviderDefinition(id: "fixture", name: "Fixture", baseURL: URL(string: "http://127.0.0.1:1234/v1")!, wireAPI: .responses, models: [])
        XCTAssertNoThrow(try APIProviderCatalog.validate(local))
        let model = APIModelDefinition(id: "fixture", name: "Fixture")
        XCTAssertThrowsError(try APIProviderCatalog.validate([local, local]))
        XCTAssertThrowsError(try APIProviderCatalog.validate(local.withModels([model, model])))
        XCTAssertThrowsError(try APIProviderCatalog.validate(local.withModels([APIModelDefinition(id: "fixture", name: "Fixture", contextWindow: 0)])))
    }
    func testConfigurationPersistenceContainsNoCredentialAndInvalidCatalogCannotReplaceIt() throws {
        let preferences = isolatedTestPreferences(), model = APIModelDefinition(id: "fixture", name: "Fixture")
        let provider = APIProviderDefinition.cerebras.withModels([model])
        try APIProviderCatalog.save([provider], to: preferences)
        XCTAssertEqual(APIProviderCatalog.load(from: preferences), [provider])
        let data = try XCTUnwrap(preferences.data(forKey: APIProviderCatalog.preferenceKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(object[0].keys), ["id", "name", "baseURL", "wireAPI", "models"])
        let modelObject = try XCTUnwrap(object[0]["models"] as? [[String: Any]])
        XCTAssertEqual(modelObject[0]["supportsToolImages"] as? Bool, false)
        // Existing metadata remains readable and does not invent tool-image support.
        var historical = object
        var historicalModels = modelObject
        historicalModels[0].removeValue(forKey: "supportsToolImages")
        historical[0]["models"] = historicalModels
        preferences.set(try JSONSerialization.data(withJSONObject: historical), forKey: APIProviderCatalog.preferenceKey)
        XCTAssertEqual(APIProviderCatalog.load(from: preferences), [provider])
        preferences.set(data, forKey: APIProviderCatalog.preferenceKey)
        XCTAssertThrowsError(try APIProviderCatalog.save([provider, provider], to: preferences))
        XCTAssertEqual(preferences.data(forKey: APIProviderCatalog.preferenceKey), data)
        preferences.set(Data("invalid".utf8), forKey: APIProviderCatalog.preferenceKey)
        XCTAssertTrue(APIProviderCatalog.load(from: preferences).isEmpty)
    }
}

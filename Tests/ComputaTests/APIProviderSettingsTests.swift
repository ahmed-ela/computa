import Foundation
import XCTest
@testable import Computa

@MainActor
final class APIProviderSettingsTests: XCTestCase {
    private enum Rejection: Error { case busy }
    private enum ServerFailure: LocalizedError {
        case raw
        var errorDescription: String? { "raw server response: fixture-secret https://private.example/?key=fixture-secret" }
    }
    @MainActor private final class EditPermission { var allowed: Bool; init(_ value: Bool) { allowed = value } }
    private let model = APIModelDefinition(id: "fixture", name: "Fixture")
    func testFirstLaunchAlibabaPickerUsesAccountCatalogAndRespectsExistingCustomEndpoint() async throws {
        let prefs = isolatedTestPreferences()
        let vault = APIProviderTestVault()
        let custom = APIProviderDefinition(id: "alibaba", name: "My custom API",
            baseURL: URL(string: "https://api.example.test/v1")!, wireAPI: .chatCompletions, models: [])
        let settings = APIProviderSettings(preferences: prefs, credentials: vault.store, listModels: { provider, _ in
            provider.isAlibabaModelStudioInference
                ? [APIModelDefinition(id: "qwen3.7-flash-2026-07-15", name: "Flash"), APIModelDefinition(id: "other", name: "Other")]
                : [APIModelDefinition(id: "custom", name: "Custom")]
        }, onChanged: { _, mutation in try mutation() })
        try await settings.connect(custom, key: "fixture-custom")
        let state = AppState(tasks: [], preferences: prefs)
        let setup = try XCTUnwrap(WebUISnapshot(state: state).providerSetups.last)
        XCTAssertEqual(setup.route, "api/alibaba-2")
        XCTAssertFalse(setup.connected)
        state.connectModelProvider(route: setup.route)
        let id = try XCTUnwrap(state.alibabaSetupID)
        let alibaba = APIProviderDefinition(id: id, name: "Alibaba",
            baseURL: URL(string: "https://ws-test.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1")!,
            wireAPI: .chatCompletions, models: [])
        try await settings.connect(alibaba, key: "fixture-alibaba")
        let restored = WebUISnapshot(state: AppState(tasks: [], preferences: prefs))
        XCTAssertEqual(restored.providerSetups.last?.route, setup.route)
        XCTAssertEqual(restored.providerSetups.last?.connected, true)
        XCTAssertEqual(restored.modelOptions.filter { $0.id.hasPrefix(setup.route + "/") }.map(\.id),
            [APIProviderCatalog.appModelID(providerID: id, modelID: "qwen3.7-flash-2026-07-15")])
        XCTAssertTrue(restored.modelOptions.contains { $0.id == APIProviderCatalog.appModelID(providerID: "alibaba", modelID: "custom") })
        XCTAssertEqual(vault.value("alibaba"), "fixture-custom")
    }

    func testConnectDiscoversBeforeAdmissionAndPersistsMetadataWithoutKey() async throws {
        let preferences = isolatedTestPreferences(), vault = APIProviderTestVault()
        var admitted: [APIProviderDefinition] = []
        var mutations = 0
        let settings = APIProviderSettings(preferences: preferences, credentials: vault.store, listModels: { provider, key in
            XCTAssertEqual(provider.id, "cerebras"); XCTAssertEqual(key, "fixture-secret"); XCTAssertNil(vault.value("cerebras"))
            return [APIModelDefinition(id: "fixture", name: "Fixture")]
        }, onChanged: { providers, mutation in
            XCTAssertNil(vault.value("cerebras")); XCTAssertEqual(vault.mutationCount, 0)
            mutations += 1; try mutation()
            XCTAssertEqual(vault.value("cerebras"), "fixture-secret"); admitted = providers
        })
        try await settings.connect(.cerebras, key: "fixture-secret")
        XCTAssertEqual(settings.providers, admitted); XCTAssertEqual(settings.providers.first?.models, [model])
        XCTAssertEqual(APIProviderCatalog.load(from: preferences), admitted)
        let persisted = try XCTUnwrap(preferences.data(forKey: APIProviderCatalog.preferenceKey))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("fixture-secret"))
        XCTAssertFalse(settings.isConnecting); XCTAssertNil(settings.error)
        XCTAssertEqual(mutations, 1); XCTAssertEqual(vault.mutationCount, 1)
    }
    func testBusyBeforeOrAfterDiscoveryNeverMutatesCredentialOrRegistry() async {
        for initiallyBusy in [true, false] {
            let preferences = isolatedTestPreferences(), vault = APIProviderTestVault()
            let permission = EditPermission(!initiallyBusy)
            var applied = false
            let settings = APIProviderSettings(preferences: preferences, credentials: vault.store, listModels: { _, _ in
                await MainActor.run { permission.allowed = false }
                return [APIModelDefinition(id: "fixture", name: "Fixture")]
            }, canEdit: { permission.allowed }, onChanged: { _, mutation in applied = true; try mutation() })
            do { try await settings.connect(.cerebras, key: "fixture-secret"); XCTFail("Busy configuration must reject") } catch { }
            XCTAssertFalse(applied); XCTAssertNil(vault.value("cerebras")); XCTAssertTrue(settings.providers.isEmpty)
            XCTAssertNil(preferences.data(forKey: APIProviderCatalog.preferenceKey)); XCTAssertFalse(settings.isConnecting)
            XCTAssertEqual(vault.mutationCount, 0)
        }
    }
    func testRuntimeAdmissionFailureNeverMutatesOldKeyAndKeepsPersistedRegistry() async throws {
        let preferences = isolatedTestPreferences(), vault = APIProviderTestVault(), original = APIProviderDefinition.cerebras.withModels([model])
        try APIProviderCatalog.save([original], to: preferences); try vault.store.save("fixture-old", for: "cerebras")
        let initialMutations = vault.mutationCount
        var admissions = 0
        let settings = APIProviderSettings(preferences: preferences, credentials: vault.store,
            listModels: { _, key in
                XCTAssertEqual(key, "fixture-new"); XCTAssertEqual(vault.value("cerebras"), "fixture-old")
                return [APIModelDefinition(id: "new", name: "New")]
            }, onChanged: { _, _ in
                admissions += 1
                XCTAssertEqual(vault.value("cerebras"), "fixture-old")
                await Task.yield()
                // A competing runtime admission can reject after the async boundary.
                XCTAssertEqual(vault.value("cerebras"), "fixture-old")
                throw Rejection.busy
            })
        do { try await settings.connect(.cerebras, key: "fixture-new"); XCTFail("Rejected runtime admission must reject") } catch { }
        XCTAssertEqual(vault.value("cerebras"), "fixture-old"); XCTAssertEqual(settings.providers, [original])
        XCTAssertEqual(APIProviderCatalog.load(from: preferences), [original]); XCTAssertFalse(settings.error?.contains("fixture") == true)
        XCTAssertEqual(admissions, 1); XCTAssertEqual(vault.mutationCount, initialMutations)
    }
    func testChangedEndpointRequiresExplicitKeyAndNoModelsCannotReplacePriorConfiguration() async throws {
        let preferences = isolatedTestPreferences(), vault = APIProviderTestVault(), original = APIProviderDefinition.cerebras.withModels([model])
        try APIProviderCatalog.save([original], to: preferences); try vault.store.save("fixture-old", for: "cerebras")
        let initialMutations = vault.mutationCount
        let settings = APIProviderSettings(preferences: preferences, credentials: vault.store, listModels: { _, _ in [] }, onChanged: { _, _ in XCTFail("No model admission") })
        let moved = APIProviderDefinition(id: "cerebras", name: "Moved", baseURL: URL(string: "https://other.example/v1")!, wireAPI: .chatCompletions, models: [])
        do { try await settings.connect(moved, key: ""); XCTFail("Changed origin must not borrow key") } catch { }
        do { try await settings.connect(.cerebras, key: ""); XCTFail("Empty catalog must reject") } catch { }
        XCTAssertEqual(vault.value("cerebras"), "fixture-old"); XCTAssertEqual(settings.providers, [original])
        XCTAssertEqual(APIProviderCatalog.load(from: preferences), [original])
        XCTAssertEqual(vault.mutationCount, initialMutations)
    }
    func testRemoveRejectsWithoutMutationAndSuccessfulRemovalDeletesOnlyItsKey() async throws {
        let preferences = isolatedTestPreferences(), vault = APIProviderTestVault(), original = APIProviderDefinition.cerebras.withModels([model])
        try APIProviderCatalog.save([original], to: preferences); try vault.store.save("fixture-old", for: "cerebras"); try vault.store.save("fixture-other", for: "other")
        var reject = true
        var mutations = 0
        let initialMutations = vault.mutationCount
        let settings = APIProviderSettings(preferences: preferences, credentials: vault.store, listModels: { _, _ in [] }, onChanged: { _, mutation in
            XCTAssertEqual(vault.value("cerebras"), "fixture-old")
            if reject { throw Rejection.busy }
            mutations += 1; try mutation()
        })
        do { try await settings.remove(providerID: "cerebras"); XCTFail("Busy removal must reject") } catch { }
        XCTAssertEqual(vault.value("cerebras"), "fixture-old"); XCTAssertEqual(settings.providers, [original])
        XCTAssertEqual(mutations, 0); XCTAssertEqual(vault.mutationCount, initialMutations)
        reject = false; try await settings.remove(providerID: "cerebras")
        XCTAssertNil(vault.value("cerebras")); XCTAssertEqual(vault.value("other"), "fixture-other")
        XCTAssertTrue(settings.providers.isEmpty); XCTAssertTrue(APIProviderCatalog.load(from: preferences).isEmpty)
        XCTAssertEqual(mutations, 1); XCTAssertEqual(vault.mutationCount, initialMutations + 1)
    }
    func testConnectionFailuresDisplayFiniteTypedMessagesWithoutPersistingKeyOrRawServerText() async throws {
        let failures: [any Error] = [APIProviderHTTPClient.Failure.unauthorized, APIProviderHTTPClient.Failure.rateLimited,
                                     APIProviderHTTPClient.Failure.redirectRejected, ServerFailure.raw]
        for failure in failures {
            let preferences = isolatedTestPreferences(), vault = APIProviderTestVault()
            let original = APIProviderDefinition.cerebras.withModels([model])
            try APIProviderCatalog.save([original], to: preferences)
            try vault.store.save("fixture-old", for: "cerebras")
            let saved = preferences.data(forKey: APIProviderCatalog.preferenceKey), initialMutations = vault.mutationCount
            let settings = APIProviderSettings(preferences: preferences, credentials: vault.store,
                listModels: { _, key in XCTAssertEqual(key, "fixture-secret"); throw failure },
                onChanged: { _, _ in XCTFail("Failed discovery must never enter admission") })
            do { try await settings.connect(.cerebras, key: "fixture-secret"); XCTFail("Failed connection must reject") } catch { }
            XCTAssertEqual(settings.error, (failure as? APIProviderHTTPClient.Failure)?.localizedDescription
                           ?? APIProviderSettings.Failure.connectionFailed.localizedDescription)
            XCTAssertFalse(settings.error?.contains("fixture-secret") == true)
            XCTAssertFalse(settings.error?.contains("private.example") == true)
            XCTAssertFalse(settings.error?.contains("raw server response") == true)
            XCTAssertEqual(settings.providers, [original]); XCTAssertEqual(vault.value("cerebras"), "fixture-old")
            XCTAssertEqual(vault.mutationCount, initialMutations)
            XCTAssertEqual(preferences.data(forKey: APIProviderCatalog.preferenceKey), saved)
            XCTAssertFalse(settings.isConnecting)
        }
    }
}

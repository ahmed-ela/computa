import Foundation
import Observation

/// Native-only settings. API secrets never enter the WebUI snapshot or bridge.
@MainActor @Observable
final class APIProviderSettings {
    typealias ListModels = @Sendable (APIProviderDefinition, String) async throws -> [APIModelDefinition]
    typealias OnChanged = @MainActor ([APIProviderDefinition], @escaping @Sendable () throws -> Void) async throws -> Void
    enum Failure: LocalizedError {
        case busy, missingKey, noModels, connectionFailed
        var errorDescription: String? {
            switch self {
            case .busy: "Wait for active tasks and provider changes to finish before editing API providers."
            case .missingKey: "Enter an API key. Changing the endpoint requires an explicit key."
            case .noModels: "The provider returned no usable models. Your saved configuration was kept."
            case .connectionFailed: "The provider could not be connected. Check its URL, key and model access."
            }
        }
    }
    private(set) var providers: [APIProviderDefinition]
    private(set) var isConnecting = false
    private(set) var error: String?
    private let preferences: UserDefaults
    private let credentials: any APIProviderCredentials
    private let listModels: ListModels
    private let canEdit: @MainActor () -> Bool
    private let onChanged: OnChanged

    init(preferences: UserDefaults, credentials: any APIProviderCredentials = APIProviderCredentialStore(),
         listModels: @escaping ListModels, canEdit: @escaping @MainActor () -> Bool = { true },
         onChanged: @escaping OnChanged) {
        self.preferences = preferences; self.credentials = credentials; self.listModels = listModels
        self.canEdit = canEdit; self.onChanged = onChanged; providers = APIProviderCatalog.load(from: preferences)
    }

    var canEditProviders: Bool { !isConnecting && canEdit() }
    func clearError() { error = nil }

    /// onChanged must reserve runtime admission, execute the credential mutation once,
    /// and accept the complete registry atomically, or throw without changing either.
    /// Credentials are never mutated outside that admission boundary.
    func connect(_ definition: APIProviderDefinition, key suppliedKey: String) async throws {
        guard canEditProviders else { error = Failure.busy.localizedDescription; throw Failure.busy }
        isConnecting = true; error = nil
        defer { isConnecting = false }
        do {
            try APIProviderCatalog.validate(definition)
            let previous = providers.first { $0.id == definition.id }
            let key: String
            if suppliedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard previous?.baseURL == definition.baseURL,
                      let oldKey = try credentials.key(for: definition.id) else { throw Failure.missingKey }
                key = oldKey
            } else { key = try APIProviderCredentialStore.normalizedKey(suppliedKey) }
            let models = try await listModels(definition, key)
            guard !models.isEmpty else { throw Failure.noModels }
            let connected = definition.withModels(models)
            let next = providers.filter { $0.id != connected.id } + [connected]
            try APIProviderCatalog.validate(next)
            // Validate the same persistence budget before credentials/runtime mutate.
            let persisted = try JSONEncoder().encode(next)
            guard persisted.count <= 512 * 1_024 else { throw APIProviderCatalog.Failure.invalidCatalog }
            guard canEdit() else { throw Failure.busy }
            let credentials = self.credentials, providerID = definition.id
            try await onChanged(next) {
                try credentials.save(key, for: providerID)
            }
            preferences.set(persisted, forKey: APIProviderCatalog.preferenceKey)
            providers = next
        } catch {
            self.error = displayMessage(for: error)
            throw error
        }
    }

    func remove(providerID: String) async throws {
        guard canEditProviders else { error = Failure.busy.localizedDescription; throw Failure.busy }
        guard providers.contains(where: { $0.id == providerID }) else { return }
        isConnecting = true; error = nil
        defer { isConnecting = false }
        do {
            let next = providers.filter { $0.id != providerID }
            try APIProviderCatalog.validate(next)
            let persisted = try JSONEncoder().encode(next)
            guard persisted.count <= 512 * 1_024 else { throw APIProviderCatalog.Failure.invalidCatalog }
            let credentials = self.credentials
            try await onChanged(next) {
                try credentials.remove(for: providerID)
            }
            preferences.set(persisted, forKey: APIProviderCatalog.preferenceKey)
            providers = next
        } catch {
            self.error = displayMessage(for: error)
            throw error
        }
    }
    private func displayMessage(for error: any Error) -> String {
        (error as? Failure)?.localizedDescription
            ?? (error as? APIProviderHTTPClient.Failure)?.localizedDescription
            ?? Failure.connectionFailed.localizedDescription
    }
}

import Foundation
import Security

protocol APIProviderCredentials: Sendable {
    func key(for providerID: String) throws -> String?
    func save(_ key: String, for providerID: String) throws
    func remove(for providerID: String) throws
}

struct APIProviderCredentialStore: APIProviderCredentials {
    static let service = "com.ahmedelamin.Computa.api-provider-keys"
    enum Failure: LocalizedError {
        case invalidProvider, invalidKey, unavailable
        var errorDescription: String? { "The API key could not be stored securely. No key was published." }
    }
    struct Backend: Sendable {
        let read: @Sendable (String) throws -> String?
        let write: @Sendable (String, String) throws -> Void
        let delete: @Sendable (String) throws -> Void
        static let keychain = Self(read: { provider in
            var query = APIProviderCredentialStore.query(provider)
            query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw Failure.unavailable }
            return value
        }, write: { provider, key in
            let query = APIProviderCredentialStore.query(provider)
            let attributes = [kSecValueData as String: Data(key.utf8)]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query; item[kSecValueData as String] = Data(key.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
            } else if status != errSecSuccess { throw Failure.unavailable }
        }, delete: { provider in
            let status = SecItemDelete(APIProviderCredentialStore.query(provider) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
        })
    }
    private let backend: Backend
    init(backend: Backend = .keychain) { self.backend = backend }
    static func normalizedKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 8_192, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure.invalidKey }
        return key
    }
    func key(for providerID: String) throws -> String? {
        try validate(providerID)
        return try backend.read(providerID).map(Self.normalizedKey)
    }
    func save(_ key: String, for providerID: String) throws {
        try validate(providerID); try backend.write(providerID, Self.normalizedKey(key))
    }
    func remove(for providerID: String) throws { try validate(providerID); try backend.delete(providerID) }
    private func validate(_ providerID: String) throws {
        guard APIProviderCatalog.validProviderID(providerID) else { throw Failure.invalidProvider }
    }
    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider, kSecAttrSynchronizable as String: false]
    }
}

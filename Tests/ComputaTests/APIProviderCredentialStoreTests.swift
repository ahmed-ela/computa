import Foundation
import XCTest
@testable import Computa

final class APIProviderTestVault: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var operations = 0
    private var mutations = 0
    var count: Int { lock.withLock { operations } }
    var mutationCount: Int { lock.withLock { mutations } }
    func value(_ id: String) -> String? { lock.withLock { values[id] } }
    var store: APIProviderCredentialStore {
        APIProviderCredentialStore(backend: .init(read: { [self] id in lock.withLock { operations += 1; return values[id] } },
            write: { [self] id, key in lock.withLock { operations += 1; mutations += 1; values[id] = key } },
            delete: { [self] id in lock.withLock { operations += 1; mutations += 1; values.removeValue(forKey: id); return () } }))
    }
}

final class APIProviderCredentialStoreTests: XCTestCase {
    func testFixtureVaultUpdatesAndRemovesOnlyMatchingProviderWithoutUserKeychain() throws {
        let vault = APIProviderTestVault(), store = vault.store
        XCTAssertNil(try store.key(for: "cerebras"))
        try store.save(" fixture-key-one\n", for: "cerebras"); try store.save("fixture-key-two", for: "other")
        XCTAssertEqual(try store.key(for: "cerebras"), "fixture-key-one")
        try store.save("fixture-replacement", for: "cerebras")
        try store.remove(for: "cerebras"); XCTAssertNil(try store.key(for: "cerebras"))
        XCTAssertEqual(try store.key(for: "other"), "fixture-key-two")
        try store.remove(for: "cerebras")
    }
    func testInvalidProviderOrHeaderKeyNeverReachesCredentialBackend() {
        let vault = APIProviderTestVault(), store = vault.store
        for provider in ["", "../other", "Uppercase", "cerebras/other"] {
            XCTAssertThrowsError(try store.key(for: provider)); XCTAssertThrowsError(try store.remove(for: provider))
            XCTAssertThrowsError(try store.save("fixture-key", for: provider))
        }
        for key in ["", "fixture\r\nInjected: header", "contains space", "é", String(repeating: "x", count: 8_193)] {
            XCTAssertThrowsError(try store.save(key, for: "fixture"))
        }
        XCTAssertEqual(vault.count, 0)
    }
}

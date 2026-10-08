import Foundation
import XCTest
@testable import Computa

final class EmbeddedHumanVerificationStoreTests: XCTestCase {
    func testCheckpointRecordsRoundTripOnlyFiniteProvidersAndUUIDs() throws {
        let suite = "Computa.HumanVerification.StoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let store = EmbeddedHumanVerificationStore(defaults: defaults, profileID: profile)
        let expected = Dictionary(uniqueKeysWithValues: ["chatgpt", "claude", "gemini"].map { ($0, UUID()) })
        var supplied = expected
        supplied["https://www.google.com/sorry/?private=query"] = UUID()
        store.save(supplied)
        XCTAssertEqual(store.load(), expected)
        let data = try XCTUnwrap(defaults.data(forKey: EmbeddedHumanVerificationStore.preferenceKey(profileID: profile)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "checkpoints"])
        let checkpoints = try XCTUnwrap(object["checkpoints"] as? [String: String])
        XCTAssertEqual(Set(checkpoints.keys), ["chatgpt", "claude", "gemini"])
        XCTAssertTrue(checkpoints.values.allSatisfy { UUID(uuidString: $0) != nil })
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        XCTAssertTrue(EmbeddedHumanVerificationStore(defaults: defaults, profileID: UUID()).load().isEmpty)
        store.save([:])
        XCTAssertNil(defaults.object(forKey: EmbeddedHumanVerificationStore.preferenceKey(profileID: profile)))
    }

    func testMalformedOrFutureRecordsCannotIntroduceProviderGates() throws {
        let suite = "Computa.HumanVerification.StoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let store = EmbeddedHumanVerificationStore(defaults: defaults, profileID: profile)
        let key = EmbeddedHumanVerificationStore.preferenceKey(profileID: profile)
        let id = UUID().uuidString
        let malformed = [
            "not json",
            "[]",
            "{\"version\":2,\"checkpoints\":{\"gemini\":\"\(id)\"}}",
            "{\"version\":true,\"checkpoints\":{\"gemini\":\"\(id)\"}}",
            "{\"version\":1,\"checkpoints\":{\"gemini\":\"invalid UUID\"}}",
            "{\"version\":1,\"checkpoints\":{\"gemini\":null}}",
            "{\"version\":1,\"checkpoints\":[\"gemini\"]}",
            "{\"version\":1,\"checkpoints\":{\"unknown\":\"\(id)\"}}",
            "{\"version\":1,\"checkpoints\":{\"Gemini\":\"\(id)\"}}",
            "{\"version\":1,\"checkpoints\":{\"gemini\":\"\(id)\"},\"url\":\"private\"}",
            String(repeating: " ", count: 1_025) + "{\"version\":1,\"checkpoints\":{}}",
        ]
        for value in malformed {
            defaults.set(Data(value.utf8), forKey: key)
            XCTAssertTrue(store.load().isEmpty, "Malformed checkpoint record was accepted")
        }
        defaults.set(["gemini"], forKey: key)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testTrustedHumanCheckpointRequiresExactHTTPSOriginAndSorryPath() throws {
        for value in [
            "https://google.com/sorry", "https://www.google.com/sorry/",
            "https://www.google.com:443/sorry/index?continue=synthetic#fixture",
            "https://GOOGLE.COM/sorry/index",
        ] {
            XCTAssertEqual(EmbeddedHumanVerificationStore.provider(forTrustedHumanURL: URL(string: value)), "gemini", value)
        }
        for value in [
            "http://google.com/sorry", "https://google.com:444/sorry",
            "https://user@google.com/sorry", "https://user:password@google.com/sorry",
            "https://google.com.example.test/sorry", "https://www.google.com.example.test/sorry",
            "https://accounts.google.com/sorry", "https://google.com./sorry",
            "https://example.test/sorry?next=https://google.com/sorry",
            "https://google.com/search?q=/sorry/", "https://google.com/sorry-about-this",
            "https://google.com/SORRY", "https://google.com/", "about:blank",
        ] {
            XCTAssertNil(EmbeddedHumanVerificationStore.provider(forTrustedHumanURL: URL(string: value)), value)
        }
        XCTAssertNil(EmbeddedHumanVerificationStore.provider(forTrustedHumanURL: nil))
    }
}

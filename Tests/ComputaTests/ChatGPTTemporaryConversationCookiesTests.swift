import Foundation
import XCTest
@testable import Computa

final class ChatGPTTemporaryConversationCookiesTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let other = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSelectsOnlyPairedKeysAndKeepsMarkersUnpairedAndAuth() throws {
        let cookies = [try key(id), try marker(id), try key(other), try cookie("auth", "PRIVATE_AUTH")]
        let selection = try ChatGPTTemporaryConversationCookies.select(cookies, now: now)
        XCTAssertEqual(selection.targetIndices, [0]); XCTAssertEqual(selection.pairedMarkerIndices, [1])
        XCTAssertEqual(selection.keyCount, 2); XCTAssertEqual(selection.markerCount, 1)
        XCTAssertEqual(selection.pairedKeyCount, 1); XCTAssertEqual(selection.unpairedKeyCount, 1)
        XCTAssertEqual(selection.targetValueUTF8Bytes, "PRIVATE_ENCRYPTION_KEY".utf8.count)
    }

    func testProtectionAndExactDomainPathValueExpiryAndCanonicalUUID() throws {
        let cookies = [try key(id), try marker(id), try key(other), try marker(other, value: "0"),
            try key(id, domain: ".chatgpt.com"), try marker(id, domain: "chatgpt.com", path: "/different"),
            try key(id, domain: "sub.chatgpt.com"), try marker(id, domain: "sub.chatgpt.com"),
            try key(id, path: "/backend-api"), try marker(id, path: "/backend-api"),
            try cookie("conv_key_" + id.uuidString.uppercased().replacingOccurrences(of: "000000000001", with: "00000000000A"), "v"),
            try cookie("history_off_00000000-0000-4000-8000-00000000000A", "1")]
        let result = try ChatGPTTemporaryConversationCookies.select(cookies, now: now, protectedIDs: [id])
        XCTAssertTrue(result.targetIndices.isEmpty); XCTAssertEqual(result.protectedKeyCount, 1)
        XCTAssertEqual(result.pairedKeyCount, 1)
        let expired = [try key(id, expires: now), try marker(id), try key(other), try marker(other, expires: now)]
        XCTAssertTrue(try ChatGPTTemporaryConversationCookies.select(expired, now: now).targetIndices.isEmpty)
    }

    func testAmbiguousIdentitiesAndProfileOrTargetExcessRefuseWholeSelection() throws {
        let one = try key(id)
        XCTAssertThrowsError(try ChatGPTTemporaryConversationCookies.select([one, one], now: now))
        XCTAssertThrowsError(try ChatGPTTemporaryConversationCookies.select(Array(repeating: one, count: 4_097), now: now))
        var cookies: [HTTPCookie] = []
        for number in 1...513 {
            let generated = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", number)))
            cookies += [try key(generated), try marker(generated)]
        }
        XCTAssertThrowsError(try ChatGPTTemporaryConversationCookies.select(cookies, now: now))
    }

    func testDomainCookiePairsQualifyAndMalformedNamesRemainUntouched() throws {
        let cookies = [try key(id, domain: ".chatgpt.com"), try marker(id, domain: ".chatgpt.com"),
            try cookie("conv_key_not-a-uuid", "PRIVATE"), try cookie("history_off_not-a-uuid", "1"),
            try key(other, domain: "evilchatgpt.com"), try marker(other, domain: "evilchatgpt.com")]
        let result = try ChatGPTTemporaryConversationCookies.select(cookies, now: now)
        XCTAssertEqual(result.targetIndices, [0]); XCTAssertEqual(result.pairedMarkerIndices, [1])
        XCTAssertEqual(result.keyCount, 1); XCTAssertEqual(result.markerCount, 1)
    }

    private func key(_ id: UUID, domain: String = "chatgpt.com", path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
        try cookie("conv_key_" + id.uuidString.lowercased(), "PRIVATE_ENCRYPTION_KEY", domain: domain, path: path, expires: expires)
    }
    private func marker(_ id: UUID, value: String = "1", domain: String = "chatgpt.com", path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
        try cookie("history_off_" + id.uuidString.lowercased(), value, domain: domain, path: path, expires: expires)
    }
    private func cookie(_ name: String, _ value: String, domain: String = "chatgpt.com", path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value]
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}

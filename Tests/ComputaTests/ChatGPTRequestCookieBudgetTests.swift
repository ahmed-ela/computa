import Foundation
import XCTest
@testable import Computa

final class ChatGPTRequestCookieBudgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFixedHTTPSHostPathExpiryAndSecureEligibility() throws {
        let included = [
            try cookie(domain: "chatgpt.com", path: "/", name: "a", value: "1"),
            try cookie(domain: ".chatgpt.com", path: "/backend-api", name: "b", value: "22", secure: true),
            try cookie(domain: "CHATGPT.COM", path: "/backend-api/f/", name: "c", value: "333"),
            try cookie(path: "/backend-api/f/conversation", name: "d", value: "4444", expiry: now.addingTimeInterval(1))
        ]
        let excluded = [
            try cookie(domain: "other.test", name: "foreign", value: "PRIVATE"),
            try cookie(domain: "sub.chatgpt.com", name: "child", value: "PRIVATE"),
            try cookie(domain: ".com", name: "suffix", value: "PRIVATE"),
            try cookie(domain: "evilchatgpt.com", name: "suffix2", value: "PRIVATE"),
            try cookie(path: "/backend-api/f/conversations", name: "longer", value: "PRIVATE"),
            try cookie(path: "/backend-ap", name: "boundary", value: "PRIVATE"),
            try cookie(path: "/elsewhere", name: "other", value: "PRIVATE"),
            try cookie(name: "expired", value: "PRIVATE", expiry: now),
            try cookie(name: "old", value: "PRIVATE", expiry: now.addingTimeInterval(-1))
        ]
        let budget = try XCTUnwrap(ChatGPTProfileCookieBudget.estimate(cookies: included + excluded, now: now))
        XCTAssertEqual(budget.cookieCount, 4)
        XCTAssertEqual(budget.totalNameUTF8Bytes, 4)
        XCTAssertEqual(budget.totalValueUTF8Bytes, 10)
        XCTAssertEqual(budget.maxValueUTF8Bytes, 4)
        XCTAssertEqual(budget.estimatedCookieHeaderUTF8Bytes, 24)
        XCTAssertEqual(budget.duplicateNameCount, 0)
    }

    func testUTF8TotalsSeparatorsAndRepeatedNamesAreAggregateOnly() throws {
        let cookies = [try cookie(name: "a", value: "x"),
                       try cookie(path: "/backend-api", name: "b", value: "é"),
                       try cookie(path: "/backend-api/f", name: "a", value: "🙂")]
        let budget = try XCTUnwrap(ChatGPTProfileCookieBudget.estimate(cookies: cookies, now: now))
        XCTAssertEqual(budget.cookieCount, 3)
        XCTAssertEqual(budget.totalNameUTF8Bytes, 3)
        XCTAssertEqual(budget.totalValueUTF8Bytes, 7)
        XCTAssertEqual(budget.maxValueUTF8Bytes, 4)
        XCTAssertEqual(budget.estimatedCookieHeaderUTF8Bytes, 17)
        XCTAssertEqual(budget.duplicateNameCount, 1)
        XCTAssertEqual(Set(budget.dictionary.keys), ["source", "cookieCount", "totalNameUTF8Bytes",
            "totalValueUTF8Bytes", "maxValueUTF8Bytes", "estimatedCookieHeaderUTF8Bytes", "duplicateNameCount"])
        XCTAssertEqual(budget.dictionary["source"] as? String, "profile_estimate")
    }

    func testEmptyEligibleSetIsKnownZeroAndSecretsNeverSerialize() throws {
        let budget = try XCTUnwrap(ChatGPTProfileCookieBudget.estimate(cookies: [
            try cookie(domain: "other.test", path: "/PRIVATE_PATH", name: "PRIVATE_NAME", value: "PRIVATE_VALUE")
        ], now: now))
        XCTAssertEqual(budget.cookieCount, 0)
        XCTAssertEqual(budget.estimatedCookieHeaderUTF8Bytes, 0)
        let included = try XCTUnwrap(ChatGPTProfileCookieBudget.estimate(cookies: [
            try cookie(path: "/backend-api", name: "PRIVATE_NAME", value: "PRIVATE_VALUE")
        ], now: now))
        let encoded = try JSONSerialization.data(withJSONObject: included.dictionary, options: [.sortedKeys])
        let text = String(decoding: encoded, as: UTF8.self)
        for secret in ["PRIVATE", "other.test", "chatgpt.com", "backend-api"] { XCTAssertFalse(text.contains(secret)) }
        let roundTrip = try JSONDecoder().decode(ChatGPTProfileCookieBudget.self, from: JSONEncoder().encode(budget))
        XCTAssertEqual(roundTrip, budget)
    }

    func testOversizedProfilesStringsAndAggregateWorkReturnUnknown() throws {
        let small = try cookie(name: "a", value: "v")
        XCTAssertNil(ChatGPTProfileCookieBudget.estimate(cookies: Array(repeating: small, count: 4_097), now: now))
        // Foundation rejects oversized values before our defensive aggregator
        // receives them. A synthetic subclass exercises those input bounds
        // without relying on the system cookie constructor accepting bad data.
        let oversized = try XCTUnwrap(OversizedCookieFixture(value: String(repeating: "x", count: 65_537)))
        XCTAssertNil(ChatGPTProfileCookieBudget.estimate(cookies: [oversized], now: now))
        let maximum = try XCTUnwrap(OversizedCookieFixture(value: String(repeating: "x", count: 65_536)))
        XCTAssertEqual(ChatGPTProfileCookieBudget.estimate(cookies: [maximum], now: now)?.maxValueUTF8Bytes, 65_536)
        XCTAssertNil(ChatGPTProfileCookieBudget.estimate(cookies: Array(repeating: maximum, count: 16), now: now))
        let longPath = try XCTUnwrap(OversizedCookieFixture(value: "v", path: "/" + String(repeating: "p", count: 2_048)))
        XCTAssertNil(ChatGPTProfileCookieBudget.estimate(cookies: [longPath], now: now))
        XCTAssertNil(ChatGPTProfileCookieBudget.estimate(cookies: [], now: Date(timeIntervalSince1970: .infinity)))
    }

    private func cookie(domain: String = "chatgpt.com", path: String = "/", name: String, value: String,
                        secure: Bool = false, expiry: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value]
        if secure { properties[.secure] = "TRUE" }
        if let expiry { properties[.expires] = expiry }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}

private final class OversizedCookieFixture: HTTPCookie, @unchecked Sendable {
    private let fixtureValue: String
    private let fixturePath: String
    override var value: String { fixtureValue }
    override var path: String { fixturePath }

    init?(value: String, path: String = "/") {
        fixtureValue = value; fixturePath = path
        super.init(properties: [.domain: "chatgpt.com", .path: "/", .name: "a", .value: "v"])
    }

    required init?(coder: NSCoder) { return nil }
}

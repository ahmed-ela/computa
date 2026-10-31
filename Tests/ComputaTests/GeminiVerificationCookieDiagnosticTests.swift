import Foundation
import XCTest
@testable import Computa

final class GeminiVerificationCookieDiagnosticTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private typealias Diagnostic = GeminiVerificationCookieDiagnostic

    func testExpiryBoundaryAndSessionClassificationAreDisjoint() throws {
        let cookies = [try fixture(expiry: now.addingTimeInterval(1)), try fixture(expiry: now),
            try fixture(expiry: now.addingTimeInterval(-1)), try fixture(),
            try fixture(expiry: now.addingTimeInterval(1), sessionOnly: true),
            try fixture(name: "other_cookie", expiry: now.addingTimeInterval(1))]
        let result = Diagnostic.project(cookies, destination: .geminiApp, now: now)
        XCTAssertEqual(result.status, .available)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.counts, .init(scopedGoogleCookies: 6, exemptionFuture: 1, exemptionExpired: 2, exemptionSession: 2))
    }

    func testExactTrustedDomainsDoNotAcceptSuffixLookalikesOrSiblingCookies() throws {
        let allowed = ["google.com", ".google.com", "gemini.google.com", ".gemini.google.com", ".GOOGLE.COM"]
        let excluded = ["evilgoogle.com", "google.com.evil.test", ".google.com.evil.test", "com", ".com",
            "accounts.google.com", "www.google.com", ".www.google.com", "google.com.", "..google.com", "googlé.com"]
        let cookies = try (allowed + excluded).map { try fixture(domain: $0) }
        XCTAssertEqual(Diagnostic.project(cookies, destination: .geminiApp, now: now).counts,
            .init(scopedGoogleCookies: allowed.count, exemptionFuture: 0, exemptionExpired: 0, exemptionSession: allowed.count))
    }

    func testGoogleChallengeCookiesAreNotGeminiAppCandidates() throws {
        let cookies = [try fixture(domain: ".google.com"), try fixture(domain: "www.google.com"),
            try fixture(domain: "gemini.google.com"), try fixture(domain: ".google.com", path: "/sorry"),
            try fixture(domain: ".google.com", path: "/sorry/"), try fixture(domain: ".google.com", path: "/sorry/index")]
        let expected: [(Diagnostic.Destination, Int)] = [(.geminiApp, 2), (.googleSorry, 2),
            (.googleSorrySlash, 3), (.googleSorryIndex, 4), (.googleWWWSorry, 3),
            (.googleWWWSorrySlash, 4), (.googleWWWSorryIndex, 5)]
        for (destination, count) in expected {
            let result = Diagnostic.project(cookies, destination: destination, now: now)
            XCTAssertEqual(result.destination, destination)
            XCTAssertEqual(result.counts, .init(scopedGoogleCookies: count, exemptionFuture: 0,
                exemptionExpired: 0, exemptionSession: count), destination.rawValue)
        }
    }

    func testPathMatchingUsesExactAndSlashBoundariesAndNameIsCaseSensitive() throws {
        let paths = ["/", "/app", "/ap", "/app/", "/apps", "/app/child", "/sorry", "/APP"]
        let cookies = try paths.map { try fixture(path: $0) } +
            [try fixture(name: "google_abuse_exemption"), try fixture(name: "GOOGLE_ABUSE_EXEMPTION_SUFFIX")]
        XCTAssertEqual(Diagnostic.project(cookies, destination: .geminiApp, now: now).counts,
            .init(scopedGoogleCookies: 4, exemptionFuture: 0, exemptionExpired: 0, exemptionSession: 2))
    }

    func testCompleteEmptyAndForeignOnlyReadsAreKnownZero() throws {
        for cookies in [[], [try fixture(domain: "foreign.test", name: "PRIVATE_NAME", path: "/PRIVATE_PATH")]] {
            let result = Diagnostic.project(cookies, destination: .geminiApp, now: now)
            XCTAssertEqual(result.status, .available)
            XCTAssertEqual(result.counts, .init(scopedGoogleCookies: 0, exemptionFuture: 0, exemptionExpired: 0, exemptionSession: 0))
        }
    }

    func testNonfiniteClockAndExpiryOrMalformedMetadataAreUnavailableNotZero() throws {
        for value in [Double.infinity, -.infinity, .nan] {
            assertUnavailable(Diagnostic.project([], destination: .geminiApp, now: Date(timeIntervalSince1970: value)), .invalidClock)
            assertUnavailable(Diagnostic.project([try fixture(expiry: Date(timeIntervalSince1970: value))],
                destination: .geminiApp, now: now), .invalidMetadata)
        }
        for cookie in [try fixture(domain: ""), try fixture(domain: "google.com\n"), try fixture(name: ""),
            try fixture(name: "bad\u{0}name"), try fixture(path: ""), try fixture(path: "app"), try fixture(path: "/\u{7f}")] {
            assertUnavailable(Diagnostic.project([cookie], destination: .geminiApp, now: now), .invalidMetadata)
        }
    }

    func testProfileAndStringBoundsAreCheckedWithoutReadingValues() throws {
        let cookie = try fixture()
        let maximum = Diagnostic.project(Array(repeating: cookie, count: Diagnostic.maximumCookieCount), destination: .geminiApp, now: now)
        XCTAssertEqual(maximum.counts?.exemptionSession, Diagnostic.maximumCookieCount)
        assertUnavailable(Diagnostic.project(Array(repeating: cookie, count: Diagnostic.maximumCookieCount + 1),
            destination: .geminiApp, now: now), .inputLimitExceeded)
        for oversized in [try fixture(domain: String(repeating: "d", count: 257)),
            try fixture(path: "/" + String(repeating: "p", count: 2_048)),
            try fixture(name: String(repeating: "n", count: 1_025))] {
            assertUnavailable(Diagnostic.project([oversized], destination: .geminiApp, now: now), .metadataLimitExceeded)
            XCTAssertEqual(oversized.secretReads, 0)
        }
        XCTAssertEqual(cookie.secretReads, 0)
    }

    func testAggregateMetadataLimitRefusesWholeProjectionIncludingForeignCookies() throws {
        let large = try fixture(domain: "foreign.test", name: String(repeating: "n", count: 1_024),
            path: "/" + String(repeating: "p", count: 2_047))
        let bytes = large.domain.utf8.count + large.path.utf8.count + large.name.utf8.count
        let under = Diagnostic.maximumMetadataBytes / bytes
        XCTAssertEqual(Diagnostic.project(Array(repeating: large, count: under), destination: .geminiApp, now: now).status, .available)
        assertUnavailable(Diagnostic.project(Array(repeating: large, count: under + 1), destination: .geminiApp, now: now), .metadataLimitExceeded)
        XCTAssertEqual(large.secretReads, 0)
    }

    func testPrivacyCanaryValuesPropertiesDescriptionsAndArbitraryMetadataNeverEscape() throws {
        let cookies = [try fixture(expiry: now.addingTimeInterval(12345)),
            try fixture(name: "PRIVATE_NAME_CANARY"),
            try fixture(domain: "private-domain-canary.test", path: "/PRIVATE_PATH_CANARY")]
        for destination in Diagnostic.Destination.allCases {
            let snapshot = Diagnostic.project(cookies, destination: destination, now: now)
            let bytes = try JSONEncoder().encode(snapshot)
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertLessThan(bytes.count, 384)
            for forbidden in ["PRIVATE", "CANARY", "private-domain", "google.com", "GOOGLE_ABUSE_EXEMPTION", "1700012345"] {
                XCTAssertFalse(text.contains(forbidden), forbidden)
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["source", "destination", "status", "counts"])
            XCTAssertEqual(object["source"] as? String, "native_candidate_metadata")
            let counts = try XCTUnwrap(object["counts"] as? [String: Int])
            XCTAssertEqual(Set(counts.keys), ["scopedGoogleCookies", "exemptionFuture", "exemptionExpired", "exemptionSession"])
        }
        for cookie in cookies { XCTAssertEqual(cookie.secretReads, 0) }
        let unavailable = Diagnostic.project(cookies, destination: .geminiApp, now: Date(timeIntervalSince1970: .infinity))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(unavailable)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["source", "destination", "status", "reason"])
        XCTAssertNil(object["counts"])
    }

    func testTimelineLifetimeBucketsHaveExactDisjointFutureOnlyBoundaries() throws {
        let future = try [0.001, 60, 60.001, 600, 600.001, 3_600, 3_600.001].map {
            try fixture(expiry: now.addingTimeInterval($0))
        }
        let cookies = future + [try fixture(expiry: now.addingTimeInterval(-1)), try fixture(expiry: now),
            try fixture(), try fixture(expiry: now.addingTimeInterval(60), sessionOnly: true),
            try fixture(name: "other", expiry: now.addingTimeInterval(60))]
        let result = Diagnostic.timeline(cookies, now: now)
        XCTAssertEqual(result.status, .available)
        XCTAssertNil(result.reason)
        let scopes = try XCTUnwrap(result.scopes)
        XCTAssertEqual(scopes.map(\.destination), Diagnostic.Destination.allCases)
        for scope in scopes {
            XCTAssertEqual(scope.counts, .init(scopedGoogleCookies: 12, exemptionFuture: 7, exemptionExpired: 2, exemptionSession: 2))
            XCTAssertEqual(scope.remainingLifetime, .init(upToOneMinute: 2, upToTenMinutes: 2, upToOneHour: 2, overOneHour: 1))
            let buckets = scope.remainingLifetime
            XCTAssertEqual(buckets.upToOneMinute + buckets.upToTenMinutes + buckets.upToOneHour + buckets.overOneHour,
                scope.counts.exemptionFuture)
        }
    }

    func testTimelineScopesUseTheSameCookiesWithoutConfusingGoogleChallengeWithGemini() throws {
        let cookies = [try fixture(expiry: now.addingTimeInterval(60)),
            try fixture(domain: "www.google.com", expiry: now.addingTimeInterval(600)),
            try fixture(path: "/sorry/", expiry: now.addingTimeInterval(3_600)),
            try fixture(domain: "gemini.google.com", path: "/app", expiry: now.addingTimeInterval(3_601)),
            try fixture(domain: "google.com.evil.test", expiry: now.addingTimeInterval(60))]
        let scopes = try XCTUnwrap(Diagnostic.timeline(cookies, now: now).scopes)
        let expected: [(Diagnostic.Destination, Diagnostic.RemainingLifetimeCounts)] = [
            (.geminiApp, .init(upToOneMinute: 1, upToTenMinutes: 0, upToOneHour: 0, overOneHour: 1)),
            (.googleSorry, .init(upToOneMinute: 1, upToTenMinutes: 0, upToOneHour: 0, overOneHour: 0)),
            (.googleSorrySlash, .init(upToOneMinute: 1, upToTenMinutes: 0, upToOneHour: 1, overOneHour: 0)),
            (.googleSorryIndex, .init(upToOneMinute: 1, upToTenMinutes: 0, upToOneHour: 1, overOneHour: 0)),
            (.googleWWWSorry, .init(upToOneMinute: 1, upToTenMinutes: 1, upToOneHour: 0, overOneHour: 0)),
            (.googleWWWSorrySlash, .init(upToOneMinute: 1, upToTenMinutes: 1, upToOneHour: 1, overOneHour: 0)),
            (.googleWWWSorryIndex, .init(upToOneMinute: 1, upToTenMinutes: 1, upToOneHour: 1, overOneHour: 0))]
        for (destination, lifetime) in expected {
            let scope = try XCTUnwrap(scopes.first { $0.destination == destination })
            XCTAssertEqual(scope.remainingLifetime, lifetime, destination.rawValue)
            XCTAssertEqual(scope.counts, Diagnostic.project(cookies, destination: destination, now: now).counts)
        }
    }

    func testTimelineValidatesAndReadsMetadataOnceForAllDestinations() throws {
        let included = try fixture(expiry: now.addingTimeInterval(60))
        let foreign = try fixture(domain: "foreign.test")
        _ = Diagnostic.timeline([included, foreign], now: now)
        XCTAssertEqual(included.metadataReads, ["domain": 1, "path": 1, "name": 1, "expiry": 1, "session": 1])
        XCTAssertEqual(foreign.metadataReads, ["domain": 1, "path": 1, "name": 1, "expiry": 1])
        XCTAssertEqual(included.secretReads, 0)
        XCTAssertEqual(foreign.secretReads, 0)
    }

    func testTimelineInvalidOrOversizedLateInputDiscardsAllPartialScopes() throws {
        let valid = try fixture(expiry: now.addingTimeInterval(60))
        let invalid: [(VerificationCookieFixture, Diagnostic.UnavailableReason)] = [
            (try fixture(domain: ""), .invalidMetadata),
            (try fixture(path: "not_absolute"), .invalidMetadata),
            (try fixture(name: "bad\u{0}name"), .invalidMetadata),
            (try fixture(expiry: Date(timeIntervalSince1970: .nan)), .invalidMetadata),
            (try fixture(domain: String(repeating: "d", count: 257)), .metadataLimitExceeded),
            (try fixture(path: "/" + String(repeating: "p", count: 2_048)), .metadataLimitExceeded),
            (try fixture(name: String(repeating: "n", count: 1_025)), .metadataLimitExceeded)]
        for (cookie, reason) in invalid {
            let result = Diagnostic.timeline([valid, cookie], now: now)
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertEqual(result.reason, reason)
            XCTAssertNil(result.scopes)
        }
        let oversized = Diagnostic.timeline(Array(repeating: valid, count: Diagnostic.maximumCookieCount + 1), now: now)
        XCTAssertEqual(oversized.reason, .inputLimitExceeded)
        XCTAssertNil(oversized.scopes)
        let large = try fixture(domain: "foreign.test", name: String(repeating: "n", count: 1_024),
            path: "/" + String(repeating: "p", count: 2_047))
        let aggregate = Diagnostic.timeline([valid] + Array(repeating: large, count: 86), now: now)
        XCTAssertEqual(aggregate.reason, .metadataLimitExceeded)
        XCTAssertNil(aggregate.scopes)
        for value in [Double.infinity, -.infinity, .nan] {
            let badClock = Diagnostic.timeline([valid], now: Date(timeIntervalSince1970: value))
            XCTAssertEqual(badClock.reason, .invalidClock)
            XCTAssertNil(badClock.scopes)
        }
    }

    func testTimelineFiniteExtremeDatesRemainInTheCoarseOverOneHourBucket() throws {
        let distant = try fixture(expiry: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude))
        let result = Diagnostic.timeline([distant], now: Date(timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude))
        XCTAssertEqual(result.status, .available)
        for scope in try XCTUnwrap(result.scopes) {
            XCTAssertEqual(scope.counts.exemptionFuture, 1)
            XCTAssertEqual(scope.remainingLifetime, .init(upToOneMinute: 0, upToTenMinutes: 0, upToOneHour: 0, overOneHour: 1))
        }
    }

    func testTimelinePrivacyAndMaximumCountWireSizeRemainBounded() throws {
        let secret = try fixture(expiry: now.addingTimeInterval(12_345))
        let privateName = try fixture(name: "PRIVATE_NAME_CANARY")
        let privateScope = try fixture(domain: "private-domain-canary.test", path: "/PRIVATE_PATH_CANARY")
        let cookies = Array(repeating: secret, count: Diagnostic.maximumCookieCount - 2) + [privateName, privateScope]
        let result = Diagnostic.timeline(cookies, now: now)
        let bytes = try JSONEncoder().encode(result)
        XCTAssertLessThan(bytes.count, 4_096)
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["PRIVATE", "CANARY", "private-domain", "google.com", "GOOGLE_ABUSE_EXEMPTION", "1700012345"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["source", "status", "scopes"])
        let scopes = try XCTUnwrap(object["scopes"] as? [[String: Any]])
        XCTAssertEqual(scopes.count, 7)
        for scope in scopes {
            XCTAssertEqual(Set(scope.keys), ["destination", "counts", "remainingLifetime"])
            let lifetime = try XCTUnwrap(scope["remainingLifetime"] as? [String: Int])
            XCTAssertEqual(Set(lifetime.keys), ["upToOneMinute", "upToTenMinutes", "upToOneHour", "overOneHour"])
            XCTAssertEqual(lifetime["overOneHour"], Diagnostic.maximumCookieCount - 2)
        }
        for cookie in [secret, privateName, privateScope] { XCTAssertEqual(cookie.secretReads, 0) }
        let unavailable = Diagnostic.timeline(cookies, now: Date(timeIntervalSince1970: .infinity))
        let unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(unavailable)) as? [String: Any])
        XCTAssertEqual(Set(unknown.keys), ["source", "status", "reason"])
        XCTAssertNil(unknown["scopes"])
    }

    func testTimelineDoesNotChangeV1ProjectionWireFormat() throws {
        let cookies = [try fixture(expiry: now.addingTimeInterval(60))]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(Diagnostic.project(cookies, destination: .geminiApp, now: now))
        _ = Diagnostic.timeline(cookies, now: now)
        let after = try encoder.encode(Diagnostic.project(cookies, destination: .geminiApp, now: now))
        XCTAssertEqual(after, before)
        XCTAssertEqual(String(decoding: after, as: UTF8.self),
            #"{"counts":{"exemptionExpired":0,"exemptionFuture":1,"exemptionSession":0,"scopedGoogleCookies":1},"destination":"gemini_app","source":"native_candidate_metadata","status":"available"}"#)
        let unavailable = try encoder.encode(Diagnostic.project(cookies, destination: .geminiApp, now: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(String(decoding: unavailable, as: UTF8.self),
            #"{"destination":"gemini_app","reason":"invalid_clock","source":"native_candidate_metadata","status":"unavailable"}"#)
    }

    private func assertUnavailable(_ snapshot: Diagnostic.Snapshot, _ reason: Diagnostic.UnavailableReason,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.status, .unavailable, file: file, line: line)
        XCTAssertEqual(snapshot.reason, reason, file: file, line: line)
        XCTAssertNil(snapshot.counts, file: file, line: line)
    }

    private func fixture(domain: String = ".google.com", name: String = "GOOGLE_ABUSE_EXEMPTION", path: String = "/",
                         expiry: Date? = nil, sessionOnly: Bool? = nil) throws -> VerificationCookieFixture {
        try XCTUnwrap(VerificationCookieFixture(domain: domain, name: name, path: path, expiry: expiry,
            sessionOnly: sessionOnly ?? (expiry == nil)))
    }
}

/// Synthetic getters let invalid metadata reach the pure boundary without
/// relying on Foundation accepting it. Secret access is counted independently.
private final class VerificationCookieFixture: HTTPCookie, @unchecked Sendable {
    private let fixtureDomain: String, fixtureName: String, fixturePath: String
    private let fixtureExpiry: Date?
    private let fixtureSessionOnly: Bool
    private var armed = false
    private(set) var secretReads = 0
    private(set) var metadataReads: [String: Int] = [:]
    private func read(_ field: String) { if armed { metadataReads[field, default: 0] += 1 } }
    override var domain: String { read("domain"); return fixtureDomain }
    override var name: String { read("name"); return fixtureName }
    override var path: String { read("path"); return fixturePath }
    override var expiresDate: Date? { read("expiry"); return fixtureExpiry }
    override var isSessionOnly: Bool { read("session"); return fixtureSessionOnly }
    override var value: String { if armed { secretReads += 1 }; return "PRIVATE_VALUE_CANARY" }
    override var properties: [HTTPCookiePropertyKey: Any]? { if armed { secretReads += 1 }; return nil }
    override var description: String { if armed { secretReads += 1 }; return "PRIVATE_DESCRIPTION_CANARY" }

    init?(domain: String, name: String, path: String, expiry: Date?, sessionOnly: Bool) {
        fixtureDomain = domain; fixtureName = name; fixturePath = path; fixtureExpiry = expiry; fixtureSessionOnly = sessionOnly
        super.init(properties: [.domain: "google.com", .path: "/", .name: "fixture", .value: "synthetic"])
        armed = true
    }
    required init?(coder: NSCoder) { return nil }
}

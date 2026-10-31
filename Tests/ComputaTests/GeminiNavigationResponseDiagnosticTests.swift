import Foundation
import XCTest
@testable import Computa

@MainActor
final class GeminiNavigationResponseDiagnosticTests: XCTestCase {
    private typealias Diagnostic = GeminiNavigationResponseDiagnostic
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProjectsResponseMetadataWithoutClaimingWireOrNavigationIdentity() throws {
        let response = try response(status: 429, headers: [
            "Cache-Control": "no-cache, no-store, max-age=0, must-revalidate",
            "Date": date(now.addingTimeInterval(-60)), "Age": "0", "Expires": date(now.addingTimeInterval(-1))
        ])
        let snapshot = try XCTUnwrap(Diagnostic.project(response: response, now: now))
        XCTAssertEqual(snapshot.statusCode, 429)
        XCTAssertEqual(snapshot.responseKind, .http)
        XCTAssertEqual(snapshot.destination, .geminiApp)
        XCTAssertEqual(snapshot.cacheControl, .init(noStore: true, noCache: true, isPrivate: false,
                                                   isPublic: false, mustRevalidate: true, maxAgePresent: true))
        XCTAssertEqual(snapshot.dateAge, .upToOneMinute)
        XCTAssertEqual(snapshot.age, .zero)
        XCTAssertEqual(snapshot.expires, .expired)
        XCTAssertEqual(snapshot.responseSource, .unknown)
        XCTAssertEqual(snapshot.requestCookie, .unknown)
        XCTAssertEqual(snapshot.redirectChain, .unknown)
        XCTAssertEqual(snapshot.navigationIdentity, .unknown)
    }

    func testOnlyFixedHTTPSRoutesQualifyAndQueriesNeverReachOutput() throws {
        let accepted: [(String, Diagnostic.Destination)] = [
            ("https://gemini.google.com/app?PRIVATE_QUERY=secret#PRIVATE_FRAGMENT", .geminiApp),
            ("https://gemini.google.com:443/app", .geminiApp),
            ("https://google.com/sorry", .googleSorry),
            ("https://google.com/sorry/", .googleSorry),
            ("https://google.com/sorry/index?continue=PRIVATE_URL", .googleSorry),
            ("https://www.google.com/sorry", .googleWWWSorry),
            ("https://www.google.com/sorry/", .googleWWWSorry),
            ("https://www.google.com/sorry/index", .googleWWWSorry)
        ]
        for (url, destination) in accepted {
            let snapshot = try XCTUnwrap(Diagnostic.project(response: response(url: url), now: now), url)
            XCTAssertEqual(snapshot.destination, destination)
            let data = try XCTUnwrap(snapshot.logData())
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("PRIVATE"))
            XCTAssertFalse(text.contains("https:"))
            XCTAssertFalse(text.contains("google.com"))
        }
        for url in ["http://gemini.google.com/app", "https://gemini.google.com:444/app",
                    "https://user:password@gemini.google.com/app", "https://@gemini.google.com/app",
                    "https://gemini.google.com.evil.invalid/app", "https://gemini.google.com./app",
                    "https://gemini.google.com/app/", "https://gemini.google.com/app/conversation",
                    "https://gemini.google.com/%61pp", "https://google.com/search",
                    "https://www.google.com/sorry/other", "https://accounts.google.com/sorry",
                    "https://google.com/sorry%2Findex"] {
            XCTAssertNil(Diagnostic.project(response: try response(url: url), now: now), url)
        }
    }

    func testTrustedNonHTTPAndMissingHeadersRemainUnknownInsteadOfFalse() throws {
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        let response = URLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)
        let snapshot = try XCTUnwrap(Diagnostic.project(response: response, now: now))
        XCTAssertEqual(snapshot.responseKind, .nonHTTP)
        XCTAssertNil(snapshot.statusCode)
        XCTAssertNil(snapshot.cacheControl)
        XCTAssertNil(snapshot.dateAge)
        XCTAssertNil(snapshot.age)
        XCTAssertNil(snapshot.expires)
        let json = try object(snapshot)
        XCTAssertEqual(json["requestCookie"] as? String, "unknown")
        XCTAssertNil(json["statusCode"])
        XCTAssertNil(json["cacheControl"])
        let emptyHTTP = try XCTUnwrap(Diagnostic.project(response: self.response(), now: now))
        XCTAssertEqual(emptyHTTP.responseKind, .http)
        XCTAssertNil(emptyHTTP.cacheControl)
        XCTAssertNil(emptyHTTP.age)
    }

    func testMalformedOrAmbiguousCacheControlDoesNotInventNegativeFlags() throws {
        let invalid = ["", " ", "no-store,", "no-store,,private", "no-store,no-store",
                       "public,private", "max-age", "max-age=-1", "max-age=+1",
                       "max-age=18446744073709551616", "max-age=\"0\"", "private=\"field\"",
                       "no-cache=value", "no-store=yes", "private;x", "no-store\npublic",
                       "no-store\t", "no-store,extension=", "extension=a=b",
                       String(repeating: "x", count: 1_025),
                       (0..<17).map { "extension\($0)" }.joined(separator: ",")]
        for header in invalid {
            let snapshot = try XCTUnwrap(Diagnostic.project(response: response(headers: ["Cache-Control": header]), now: now))
            XCTAssertNil(snapshot.cacheControl, header)
            XCTAssertEqual(snapshot.statusCode, 200)
        }
        let parsed = try XCTUnwrap(Diagnostic.project(response: response(headers: [
            "Cache-Control": " Public , MAX-AGE = 300, extension=PRIVATE_CANARY"
        ]), now: now)?.cacheControl)
        XCTAssertTrue(parsed.isPublic)
        XCTAssertTrue(parsed.maxAgePresent)
        XCTAssertFalse(parsed.noStore)
    }

    func testAgeAndDateBucketsHaveExplicitBoundariesAndRejectInvalidInputs() throws {
        let cases: [(Int, Diagnostic.AgeBucket)] = [
            (0, .zero), (1, .upToOneMinute), (60, .upToOneMinute), (61, .upToOneHour),
            (3_600, .upToOneHour), (3_601, .upToOneDay), (86_400, .upToOneDay), (86_401, .overOneDay)
        ]
        for (seconds, expected) in cases {
            let snapshot = try XCTUnwrap(Diagnostic.project(response: response(headers: [
                "Age": String(seconds), "Date": date(now.addingTimeInterval(-Double(seconds)))
            ]), now: now))
            XCTAssertEqual(snapshot.age, expected, String(seconds))
            XCTAssertEqual(snapshot.dateAge, expected, String(seconds))
        }
        XCTAssertEqual(try XCTUnwrap(Diagnostic.project(response: response(headers: [
            "Date": date(now.addingTimeInterval(1))
        ]), now: now)).dateAge, .future)
        for value in ["-1", "+1", "1.5", "1, 2", "NaN", "18446744073709551616", String(repeating: "0", count: 21)] {
            XCTAssertNil(Diagnostic.project(response: try response(headers: ["Age": value]), now: now)?.age, value)
        }
        for value in ["PRIVATE_DATE", "0", "Fri, 30 Oct 2026 13:15:46 GMT, other",
                      "Sat, 30 Oct 2026 13:15:46 GMT", "Fri, 30 Oct 2026 13:15:46 UTC",
                      String(repeating: "x", count: 65)] {
            let snapshot = try XCTUnwrap(Diagnostic.project(response: response(headers: ["Date": value, "Expires": value]), now: now))
            XCTAssertNil(snapshot.dateAge, value)
            XCTAssertNil(snapshot.expires, value)
        }
    }

    func testExpiryAndInvalidClockDoNotAlterIndependentHTTPFacts() throws {
        let cases: [(Int, Diagnostic.ExpiryBucket)] = [
            (-1, .expired), (0, .expired), (1, .upToOneMinute), (60, .upToOneMinute),
            (61, .upToOneHour), (3_600, .upToOneHour), (3_601, .overOneHour)
        ]
        for (seconds, expected) in cases {
            let snapshot = try XCTUnwrap(Diagnostic.project(response: response(headers: [
                "Expires": date(now.addingTimeInterval(Double(seconds)))
            ]), now: now))
            XCTAssertEqual(snapshot.expires, expected, String(seconds))
        }
        for badClock in [Double.infinity, -.infinity, .nan] {
            let snapshot = try XCTUnwrap(Diagnostic.project(response: response(status: 403, headers: [
                "Date": date(now), "Expires": date(now), "Age": "60", "Cache-Control": "no-store"
            ]), now: Date(timeIntervalSince1970: badClock)))
            XCTAssertNil(snapshot.dateAge)
            XCTAssertNil(snapshot.expires)
            XCTAssertEqual(snapshot.age, .upToOneMinute)
            XCTAssertEqual(snapshot.statusCode, 403)
            XCTAssertEqual(snapshot.cacheControl?.noStore, true)
        }
    }

    func testStatusRangeIsBoundedIndependentlyOfRouteAndHeaders() throws {
        for status in [99, 100, 200, 302, 403, 429, 599, 600] {
            let snapshot = try XCTUnwrap(Diagnostic.project(response: response(status: status), now: now))
            XCTAssertEqual(snapshot.statusCode, (100...599).contains(status) ? status : nil)
        }
    }

    func testReadsOnlyFourAllowedHeadersAndNeverSerializesPrivateInput() throws {
        let url = try XCTUnwrap(URL(string: "https://google.com/sorry/index?PRIVATE_QUERY=SECRET"))
        let headers = [
            "Cache-Control": "public,max-age=300,extension=PRIVATE_CACHE_VALUE",
            "Date": date(now), "Age": "42", "Expires": date(now.addingTimeInterval(3600)),
            "Cookie": "GOOGLE_ABUSE_EXEMPTION=PRIVATE_COOKIE",
            "Set-Cookie": "GOOGLE_ABUSE_EXEMPTION=PRIVATE_SET_COOKIE",
            "Authorization": "Bearer PRIVATE_AUTHORIZATION", "Location": "https://private.invalid/SECRET"
        ]
        let spy = try XCTUnwrap(HeaderReadSpy(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        spy.fixtureHeaders = headers
        let snapshot = try XCTUnwrap(Diagnostic.project(response: spy, now: now))
        XCTAssertEqual(spy.readNames, ["Cache-Control", "Date", "Age", "Expires"])
        XCTAssertEqual(spy.headerEnumerationCount, 0)
        let text = String(decoding: try XCTUnwrap(snapshot.logData()), as: UTF8.self)
        for forbidden in ["PRIVATE", "SECRET", "GOOGLE_ABUSE_EXEMPTION", "https://", "1800000000", "Cache-Control"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertEqual(spy.url, url, "Projection is read-only")
    }

    func testCompleteFiniteWireFitsReservedBudgetWithUnknownFieldsExplicit() throws {
        let snapshot = try XCTUnwrap(Diagnostic.project(response: response(url: "https://www.google.com/sorry/index", status: 599, headers: [
            "Cache-Control": "no-store,no-cache,private,max-age=18446744073709551615,must-revalidate",
            "Date": date(now.addingTimeInterval(-3_601)), "Age": "18446744073709551615",
            "Expires": date(now.addingTimeInterval(60))
        ]), now: now))
        let data = try XCTUnwrap(snapshot.logData())
        XCTAssertLessThanOrEqual(data.count, Diagnostic.maximumJSONBytes)
        XCTAssertEqual(Diagnostic.maximumJSONBytes, 768)
        let json = try object(snapshot)
        XCTAssertEqual(Set(json.keys), ["kind", "evidence", "responseSource", "requestCookie", "redirectChain",
                                       "navigationIdentity", "destination", "responseKind", "statusCode", "cacheControl",
                                       "dateAge", "age", "expires"])
        for name in ["responseSource", "requestCookie", "redirectChain", "navigationIdentity"] {
            XCTAssertEqual(json[name] as? String, "unknown")
        }
    }

    private func response(url: String = "https://gemini.google.com/app", status: Int = 200,
                          headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: url)), statusCode: status,
                                     httpVersion: "HTTP/1.1", headerFields: headers))
    }

    private func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private func object(_ snapshot: Diagnostic.Snapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(snapshot.logData())) as? [String: Any])
    }
}

private final class HeaderReadSpy: HTTPURLResponse, @unchecked Sendable {
    var fixtureHeaders: [String: String] = [:]
    var readNames: [String] = []
    var headerEnumerationCount = 0

    override func value(forHTTPHeaderField field: String) -> String? {
        readNames.append(field)
        return fixtureHeaders[field]
    }

    override var allHeaderFields: [AnyHashable: Any] {
        headerEnumerationCount += 1
        return fixtureHeaders
    }
}

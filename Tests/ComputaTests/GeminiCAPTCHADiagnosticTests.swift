import WebKit
import XCTest
@testable import Computa

final class GeminiCAPTCHADiagnosticTests: XCTestCase {
    private typealias Diagnostic = GeminiCAPTCHADiagnostic
    private let now = Date(timeIntervalSince1970: 1_793_491_200)

    func testRequestProjectionNeverRetainsURLQueryCredentialsHeadersOrBody() throws {
        let secret = "PRIVATE_SENTINEL_MUST_NOT_SURVIVE"
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://gemini.google.com/app?token=\(secret)#\(secret)")))
        request.httpMethod = "POST"
        request.httpBody = Data(secret.utf8)
        for header in ["Cookie", "Authorization", "Referer", "X-Private-Fixture"] {
            request.setValue(secret, forHTTPHeaderField: header)
        }
        var journal = Diagnostic.Journal()
        journal.recordRequest(request, generation: UUID(), now: now)
        let report = makeReport(journal)
        let event = try XCTUnwrap(report.navigation.events.first)
        XCTAssertEqual(event.request?.destination, .geminiApp)
        XCTAssertEqual(event.request?.method, .post)
        XCTAssertEqual(event.request?.cookie, .presentInRequestMetadata)
        XCTAssertEqual(event.request?.referer, .presentInRequestMetadata)
        XCTAssertEqual(event.request?.authorization, .presentInRequestMetadata)
        let text = String(decoding: try report.encodedData(), as: UTF8.self)
        for forbidden in [secret, "gemini.google.com", "https://", "X-Private-Fixture", "httpBody"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertEqual(report.requestCookiesTransmitted, .unknown)
        XCTAssertEqual(report.networkOrCacheSource, .unknown)
        XCTAssertEqual(report.exactNavigationIdentity, .unknown)
    }

    func testMissingHeadersAndUnsupportedMethodsRemainUnknown() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://www.google.com/sorry/index?private=value")))
        request.httpMethod = "PRIVATE_UNKNOWN_METHOD"
        var journal = Diagnostic.Journal()
        journal.recordRequest(request, generation: UUID(), now: now)
        let report = makeReport(journal)
        let metadata = try XCTUnwrap(report.navigation.events.first?.request)
        XCTAssertEqual(metadata.destination, .googleWWWSorry)
        XCTAssertEqual(metadata.method, .unknown)
        XCTAssertEqual(metadata.cookie, .unknown)
        XCTAssertEqual(metadata.authorization, .unknown)
        XCTAssertEqual(metadata.referer, .unknown)
        XCTAssertFalse(String(decoding: try report.encodedData(), as: UTF8.self).contains("PRIVATE_UNKNOWN_METHOD"))
    }

    func testTrustedRouteBoundaryIsSharedByRequestAndResponse() throws {
        let accepted = ["https://gemini.google.com/app", "https://gemini.google.com:443/app?q=private",
                        "https://google.com/sorry", "https://google.com/sorry/", "https://google.com/sorry/index",
                        "https://www.google.com/sorry", "https://www.google.com/sorry/", "https://www.google.com/sorry/index"]
        let rejected = ["http://gemini.google.com/app", "https://gemini.google.com:444/app",
                        "https://user:password@gemini.google.com/app", "https://gemini.google.com.evil.test/app",
                        "https://gemini.google.com/app/conversation", "https://gemini.google.com/%61pp",
                        "https://google.com/search?q=private", "https://google.com/sorry/other",
                        "https://accounts.google.com/sorry", "https://example.test/app"]
        for address in accepted + rejected {
            let url = try XCTUnwrap(URL(string: address))
            var journal = Diagnostic.Journal()
            journal.recordRequest(URLRequest(url: url), generation: UUID(), now: now)
            journal.recordResponse(URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil),
                                   generation: UUID(), now: now)
            let history = makeReport(journal).navigation
            XCTAssertEqual(history.events.count, accepted.contains(address) ? 2 : 0, address)
            XCTAssertEqual(history.availability, accepted.contains(address) ? .available : .unknown, address)
        }
    }

    func testResponseSnapshotIsPreservedWithoutReadingOtherHeaders() throws {
        let response = try XCTUnwrap(HeaderReadSpy(url: URL(string: "https://www.google.com/sorry/index?PRIVATE_QUERY")!,
            statusCode: 429, httpVersion: "HTTP/2", headerFields: [
                "Cache-Control": "no-store, no-cache, max-age=0", "Age": "2",
                "Date": "Fri, 30 Oct 2026 09:00:00 GMT", "Expires": "Fri, 30 Oct 2026 09:00:00 GMT",
                "Set-Cookie": "PRIVATE_RESPONSE_COOKIE", "Location": "https://private.example/PRIVATE_LOCATION"
            ]))
        let expected = try XCTUnwrap(GeminiNavigationResponseDiagnostic.project(response: response, now: now))
        response.reads.removeAll()
        var journal = Diagnostic.Journal()
        journal.recordResponse(response, generation: UUID(), now: now)
        let report = makeReport(journal)
        XCTAssertEqual(report.navigation.events.first?.response, expected)
        XCTAssertEqual(response.reads, ["Cache-Control", "Date", "Age", "Expires"])
        XCTAssertEqual(report.navigation.events.first?.response?.statusCode, 429)
        let text = String(decoding: try report.encodedData(), as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_"))
    }

    func testNavigationBoundKeepsRecentEventsAndReportsDroppedHistoryAcrossGenerations() throws {
        var journal = Diagnostic.Journal()
        let initial = UUID(), redirected = UUID()
        journal.recordRequest(URLRequest(url: URL(string: "https://gemini.google.com/app")!), generation: initial, now: now)
        // Native didStart may advance the generation between action and redirect.
        journal.recordRedirect(generation: redirected, now: now.addingTimeInterval(1))
        let first = makeReport(journal)
        XCTAssertEqual(first.navigation.events.map(\.generation), [initial, redirected])
        XCTAssertNil(first.navigation.events[1].request)
        XCTAssertNil(first.navigation.events[1].response)
        for index in 2..<40 {
            journal.recordRedirect(generation: redirected, now: now.addingTimeInterval(Double(index)))
        }
        let report = makeReport(journal)
        XCTAssertEqual(report.navigation.events.count, 32)
        XCTAssertEqual(report.navigation.events.first?.sequence, 9)
        XCTAssertEqual(report.navigation.events.last?.sequence, 40)
        XCTAssertEqual(report.navigation.droppedEvents, 8)
        XCTAssertFalse(report.navigation.eventCountSaturated)
        XCTAssertEqual(report.navigation.oldestObservedAt, now.addingTimeInterval(8))
        XCTAssertEqual(report.navigation.newestObservedAt, now.addingTimeInterval(39))
        XCTAssertEqual(first.navigation.events.count, 2, "A frozen report cannot change when the journal advances")
    }

    func testCookieHistoryIsBoundedHistoricalAndRetainsUnavailableEvents() throws {
        let unavailable = cookieEvent(sequence: 12, status: .unavailable, reason: .deadlineExceeded)
        let values = (1...12).map { index in
            Diagnostic.CookieEvent(date: now.addingTimeInterval(Double(index)),
                event: index == 12 ? unavailable : cookieEvent(sequence: index))
        }
        let report = makeReport(Diagnostic.Journal(), cookies: values)
        XCTAssertEqual(report.cookies.events.count, 8)
        XCTAssertEqual(report.cookies.events.first?.event.sequence, 5)
        XCTAssertEqual(report.cookies.events.last?.event.sequence, 12)
        XCTAssertEqual(report.cookies.droppedEvents, 4)
        XCTAssertEqual(report.cookies.oldestObservedAt, now.addingTimeInterval(5))
        XCTAssertEqual(report.cookies.newestObservedAt, now.addingTimeInterval(12))
        XCTAssertEqual(report.cookies.events.last?.event.status, .unavailable)
        XCTAssertEqual(report.cookies.events.last?.event.reason, .deadlineExceeded)
        XCTAssertNil(report.cookies.events.last?.event.metadata)
        XCTAssertTrue(report.cookies.scope.contains("shared_profile_historical"))
        // Even a callback later than capture is retained with its own time; it
        // must never be retagged as the failed request's sent-cookie evidence.
        XCTAssertEqual(report.capturedAt, now)
        XCTAssertEqual(report.requestCookiesTransmitted, .unknown)
        let empty = makeReport(Diagnostic.Journal())
        XCTAssertEqual(empty.cookies.availability, .unknown)
        XCTAssertEqual(empty.navigation.availability, .unknown)
        XCTAssertNil(empty.cookies.oldestObservedAt)
        XCTAssertNil(empty.nativeState)
        XCTAssertEqual(empty.nativeStateAvailability, .unknown)
    }

    func testInvalidClocksEncodeUnknownInsteadOfNonFiniteJSON() throws {
        let invalid = Date(timeIntervalSince1970: .infinity)
        var journal = Diagnostic.Journal()
        journal.recordRequest(URLRequest(url: URL(string: "https://gemini.google.com/app")!), generation: UUID(), now: invalid)
        let report = journal.report(tabID: UUID(), generation: UUID(), role: .human, trigger: .humanCheckpoint,
            now: invalid, cookieEvents: [.init(date: invalid, event: cookieEvent(sequence: 1))])
        XCTAssertNil(report.capturedAt)
        XCTAssertEqual(report.captureTime, .unknown)
        XCTAssertNil(report.navigation.events.first?.observedAt)
        XCTAssertEqual(report.navigation.events.first?.observationTime, .unknown)
        XCTAssertNil(report.cookies.events.first?.observedAt)
        XCTAssertEqual(report.cookies.events.first?.observationTime, .unknown)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: report.encodedData()))
    }

    func testSubsecondTimesAndEarlierCookieDropsSurviveReportFreezing() throws {
        var journal = Diagnostic.Journal()
        let generation = UUID()
        journal.recordRequest(URLRequest(url: URL(string: "https://gemini.google.com/app")!),
                              generation: generation, now: now.addingTimeInterval(0.125))
        journal.recordRedirect(generation: generation, now: now.addingTimeInterval(0.375))
        let cookies = (1...10).map { Diagnostic.CookieEvent(date: now, event: cookieEvent(sequence: $0)) }
        let report = journal.report(tabID: UUID(), generation: generation, role: .model, trigger: .beforeClose,
            now: now, cookieEvents: cookies, earlierCookieEventsDropped: 7)
        XCTAssertEqual(report.cookies.droppedEvents, 9)
        XCTAssertFalse(report.cookies.eventCountSaturated)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encodedData()) as? [String: Any])
        let navigation = try XCTUnwrap(json["navigation"] as? [String: Any])
        let events = try XCTUnwrap(navigation["events"] as? [[String: Any]])
        let first = try XCTUnwrap(events[0]["observedAt"] as? Double)
        let second = try XCTUnwrap(events[1]["observedAt"] as? Double)
        XCTAssertEqual(second - first, 250, accuracy: 0.001)
        let saturated = journal.report(tabID: UUID(), generation: generation, role: .model, trigger: .beforeClose,
            now: now, cookieEvents: cookies, earlierCookieEventsDropped: Int.max)
        XCTAssertEqual(saturated.cookies.droppedEvents, Int.max)
        XCTAssertTrue(saturated.cookies.eventCountSaturated)
        XCTAssertNoThrow(try saturated.encodedData())
    }

    func testAllCachePoliciesAreFiniteAndNoRequestCachePolicyClaimsResponseSource() throws {
        let cases: [(URLRequest.CachePolicy, Diagnostic.CachePolicy)] = [
            (.useProtocolCachePolicy, .protocolPolicy), (.reloadIgnoringLocalCacheData, .reloadIgnoringLocal),
            (.reloadIgnoringLocalAndRemoteCacheData, .reloadIgnoringLocalAndRemote),
            (.returnCacheDataElseLoad, .cachedElseLoad), (.returnCacheDataDontLoad, .cachedOnly),
            (.reloadRevalidatingCacheData, .revalidate)
        ]
        for (native, expected) in cases {
            var journal = Diagnostic.Journal()
            journal.recordRequest(URLRequest(url: URL(string: "https://gemini.google.com/app")!, cachePolicy: native),
                                  generation: UUID(), now: now)
            let report = makeReport(journal)
            XCTAssertEqual(report.navigation.events.first?.request?.cachePolicy, expected)
            XCTAssertEqual(report.networkOrCacheSource, .unknown)
        }
    }

    func testFullBoundedReportFitsBudgetAndSupportsStableStoreIdentity() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "GOOGLE_ABUSE_EXEMPTION", .value: "PRIVATE_VALUE",
            .domain: ".google.com", .path: "/", .expires: now.addingTimeInterval(600)]))
        let metadata = GeminiVerificationCookieDiagnostic.timeline(Array(repeating: cookie, count: 4_096), now: now)
        XCTAssertEqual(metadata.status, .available)
        XCTAssertTrue(metadata.scopes?.allSatisfy { $0.counts.scopedGoogleCookies == 4_096 } == true)
        var journal = Diagnostic.Journal()
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://www.google.com/sorry/index")!,
            statusCode: 429, httpVersion: "HTTP/2", headerFields: ["Cache-Control": "no-store, no-cache, private, must-revalidate, max-age=0",
                "Date": "Fri, 30 Oct 2026 09:00:00 GMT", "Age": "9999999", "Expires": "Fri, 30 Oct 2026 09:00:00 GMT"]))
        for _ in 0..<32 { journal.recordResponse(response, generation: UUID(), now: now) }
        let event = GeminiVerificationCookieTimeline.Event(sequence: Int.max, read: Int.max,
            triggers: GeminiVerificationCookieTimeline.Trigger.allCases, phase: .sample, status: .available,
            reason: nil, coalescedTriggerCount: 255, duplicateSamplesSuppressed: 255, metadata: metadata)
        let id = UUID(), tab = UUID(), generation = UUID()
        let native = Diagnostic.NativeState(loading: false, pending: false, committed: true, finished: true, navigationError: false)
        let report = journal.report(tabID: tab, generation: generation, role: .model, trigger: .transport,
            now: now, cookieEvents: Array(repeating: .init(date: now, event: event), count: 8), nativeState: native, id: id)
        let bytes = try report.encodedData()
        XCTAssertLessThanOrEqual(bytes.count, Diagnostic.maximumReportBytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "gemini_captcha_diagnostic")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual((json["id"] as? String).flatMap(UUID.init(uuidString:)), id)
        XCTAssertEqual(report.nativeStateAvailability, .available)
        XCTAssertEqual(report.nativeState?.finished, true)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE_VALUE"))
        XCTAssertEqual(try report.encodedData(), bytes)
    }

    private func makeReport(_ journal: Diagnostic.Journal, cookies: [Diagnostic.CookieEvent] = []) -> Diagnostic.Report {
        journal.report(tabID: UUID(), generation: UUID(), role: .model, trigger: .transport, now: now, cookieEvents: cookies)
    }

    private func cookieEvent(sequence: Int, status: GeminiVerificationCookieTimeline.Event.Status = .pending,
                             reason: GeminiVerificationCookieTimeline.Event.Reason? = nil) -> GeminiVerificationCookieTimeline.Event {
        .init(sequence: sequence, read: sequence, triggers: [.challengeSettled], phase: .sample, status: status,
              reason: reason, coalescedTriggerCount: 0, duplicateSamplesSuppressed: 0, metadata: nil)
    }

    private final class HeaderReadSpy: HTTPURLResponse, @unchecked Sendable {
        var reads: [String] = []
        override func value(forHTTPHeaderField field: String) -> String? {
            reads.append(field)
            return super.value(forHTTPHeaderField: field)
        }
    }
}

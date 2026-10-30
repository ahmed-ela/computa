import Foundation
import XCTest
@testable import Computa

@MainActor
final class GeminiVerificationCookieTimelineLogTests: XCTestCase {
    private typealias Event = GeminiVerificationCookieTimeline.Event
    private typealias Diagnostic = GeminiVerificationCookieDiagnostic
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompactScopeRowsPreserveAllSevenDestinationsAndEightFields() throws {
        let cookies = try [cookie(domain: ".google.com", path: "/", remaining: 30),
                           cookie(domain: "gemini.google.com", path: "/app", remaining: 300),
                           cookie(domain: "www.google.com", path: "/sorry", remaining: 3_000),
                           cookie(domain: ".google.com", path: "/sorry/index", remaining: 4_000)]
        let snapshot = Diagnostic.timeline(cookies, now: now)
        let input = event(metadata: snapshot)
        let decoded = try object(input.logData())
        XCTAssertEqual(Set(decoded.keys), ["kind", "evidence", "seq", "read", "triggers", "phase", "status", "reason", "coalesced", "duplicates", "metadata"])
        XCTAssertEqual(decoded["kind"] as? String, "gemini_verification_cookie_timeline_v2")
        XCTAssertEqual(decoded["evidence"] as? String, input.evidence)
        let metadata = try XCTUnwrap(decoded["metadata"] as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["source", "status", "scopes"])
        XCTAssertEqual(metadata["source"] as? String, "native_candidate_metadata")
        let rows = try XCTUnwrap(metadata["scopes"] as? [[Int]])
        let scopes = try XCTUnwrap(snapshot.scopes)
        XCTAssertEqual(scopes.map(\.destination.rawValue), ["gemini_app", "google_sorry", "google_sorry_slash", "google_sorry_index", "google_www_sorry", "google_www_sorry_slash", "google_www_sorry_index"])
        XCTAssertEqual(rows.count, 7)
        for (row, scope) in zip(rows, scopes) {
            XCTAssertEqual(row, [scope.counts.scopedGoogleCookies, scope.counts.exemptionFuture,
                                 scope.counts.exemptionExpired, scope.counts.exemptionSession,
                                 scope.remainingLifetime.upToOneMinute, scope.remainingLifetime.upToTenMinutes,
                                 scope.remainingLifetime.upToOneHour, scope.remainingLifetime.overOneHour])
        }
        XCTAssertNotEqual(rows[0][0], rows[1][0], "Scope order must remain observable, not seven identical fixtures")
        let rich = try object(JSONEncoder().encode(input))
        XCTAssertEqual(rich["kind"] as? String, "gemini_verification_cookie_timeline_v1", "In-memory Event encoding is unchanged")
    }

    func testWorstBoundedCountsAndIntMaxCountersFitActualLogMessageBudget() throws {
        let fixture = try cookie(domain: ".google.com", path: "/", remaining: 4_000)
        let snapshot = Diagnostic.timeline(Array(repeating: fixture, count: Diagnostic.maximumCookieCount), now: now)
        let input = event(metadata: snapshot)
        let compact = try input.logData()
        XCTAssertLessThanOrEqual(GeminiVerificationCookieTimelineLog.prefix.utf8.count + compact.count, 1_000)
        XCTAssertGreaterThan(try JSONEncoder().encode(input).count, 1_020, "The former rich serialization reproduces the observed OSLog truncation risk")
        let decoded = try object(compact)
        for key in ["seq", "read", "coalesced", "duplicates"] {
            XCTAssertEqual((decoded[key] as? NSNumber)?.int64Value, Int64.max)
        }
        XCTAssertEqual(decoded["triggers"] as? [String], GeminiVerificationCookieTimeline.Trigger.allCases.map(\.rawValue))
        let metadata = try XCTUnwrap(decoded["metadata"] as? [String: Any])
        XCTAssertEqual((metadata["scopes"] as? [[Int]])?.count, 7)
        for forbidden in ["PRIVATE", "google.com", "GOOGLE_ABUSE_EXEMPTION", "1800004000", "expiresDate"] {
            XCTAssertFalse(String(decoding: compact, as: UTF8.self).contains(forbidden), forbidden)
        }
    }

    func testUnavailableMetadataReasonAndMissingReadStayExplicitWithoutInventingZeroRows() throws {
        let unavailable = Diagnostic.timeline([], now: Date(timeIntervalSince1970: .infinity))
        let input = event(metadata: unavailable, read: nil, status: .unavailable)
        let decoded = try object(input.logData())
        XCTAssertNil(decoded["read"])
        let metadata = try XCTUnwrap(decoded["metadata"] as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["source", "status", "reason"])
        XCTAssertEqual(metadata["status"] as? String, "unavailable")
        XCTAssertEqual(metadata["reason"] as? String, "invalid_clock")
        XCTAssertNil(metadata["scopes"])
        let pending = try object(event(metadata: nil, read: nil, status: .pending).logData())
        XCTAssertNil(pending["metadata"])
        XCTAssertNil(pending["read"])
    }

    func testEveryFinitePhaseAndReasonRemainsNamedAndBounded() throws {
        let phases: [Event.Phase] = [.intent, .requested, .sample, .gap, .stopped]
        let reasons: [Event.Reason] = [.deadlineExceeded, .supersededByStoreChange, .lateCallbackDiscarded,
                                     .stopped, .readBudgetExhausted, .logBudgetExhausted, .coalesced, .invalidClock]
        for phase in phases {
            for reason in reasons {
                let input = event(metadata: nil, phase: phase, status: .unavailable, reason: reason)
                let data = try input.logData(), decoded = try object(data)
                XCTAssertEqual(decoded["phase"] as? String, phase.rawValue)
                XCTAssertEqual(decoded["reason"] as? String, reason.rawValue)
                XCTAssertLessThanOrEqual(GeminiVerificationCookieTimelineLog.prefix.utf8.count + data.count, 1_000)
            }
        }
    }

    func testMalformedEventCannotExpandTheFiniteWireEnvelope() throws {
        let duplicateTriggers = Event(sequence: 1, read: nil, triggers: [.initial, .initial], phase: .requested,
                                      status: .pending, reason: nil, coalescedTriggerCount: 0, duplicateSamplesSuppressed: 0, metadata: nil)
        XCTAssertThrowsError(try duplicateTriggers.logData())
        let invalidCounter = Event(sequence: -1, read: nil, triggers: [], phase: .stopped,
                                   status: .unavailable, reason: .stopped, coalescedTriggerCount: 0, duplicateSamplesSuppressed: 0, metadata: nil)
        XCTAssertThrowsError(try invalidCounter.logData())
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func event(metadata: Diagnostic.TimelineSnapshot?, read: Int? = .max,
                       phase: Event.Phase = .requested, status: Event.Status = .available,
                       reason: Event.Reason? = .supersededByStoreChange) -> Event {
        Event(sequence: .max, read: read, triggers: GeminiVerificationCookieTimeline.Trigger.allCases,
              phase: phase, status: status, reason: reason,
              coalescedTriggerCount: .max, duplicateSamplesSuppressed: .max, metadata: metadata)
    }

    private func cookie(domain: String, path: String, remaining: TimeInterval) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.name: "GOOGLE_ABUSE_EXEMPTION", .value: "PRIVATE_VALUE_CANARY",
            .domain: domain, .path: path, .secure: "TRUE", .expires: now.addingTimeInterval(remaining)]))
    }
}

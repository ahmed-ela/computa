import Foundation

extension GeminiVerificationCookieTimeline.Event {
    /// Compact v2 wire format for OSLog's finite string payload. The rich Event
    /// remains unchanged. Scope rows are ordered: gemini_app, google_sorry,
    /// google_sorry_slash, google_sorry_index, google_www_sorry,
    /// google_www_sorry_slash, google_www_sorry_index. Each row contains:
    /// [scopedGoogleCookies, exemptionFuture, exemptionExpired, exemptionSession,
    ///  upToOneMinute, upToTenMinutes, upToOneHour, overOneHour].
    /// No row is a request Cookie header or evidence of server acceptance.
    func logData() throws -> Data {
        try GeminiVerificationCookieTimelineLog.data(for: self)
    }
}

enum GeminiVerificationCookieTimelineLog {
    static let prefix = "geminiVerificationCookieTimeline "
    static let maximumMessageBytes = 1_000

    enum Failure: Error { case invalidEvent, invalidMetadata, payloadTooLarge }

    private struct Metadata: Encodable {
        let source = "native_candidate_metadata"
        let status: GeminiVerificationCookieDiagnostic.Status
        let reason: GeminiVerificationCookieDiagnostic.UnavailableReason?
        let scopes: [[Int]]?

        init(_ snapshot: GeminiVerificationCookieDiagnostic.TimelineSnapshot) throws {
            status = snapshot.status
            reason = snapshot.reason
            switch status {
            case .unavailable:
                guard reason != nil, snapshot.scopes == nil else { throw Failure.invalidMetadata }
                scopes = nil
            case .available:
                let order: [GeminiVerificationCookieDiagnostic.Destination] = [
                    .geminiApp, .googleSorry, .googleSorrySlash, .googleSorryIndex,
                    .googleWWWSorry, .googleWWWSorrySlash, .googleWWWSorryIndex
                ]
                guard reason == nil, let rows = snapshot.scopes,
                      rows.map(\.destination) == order else { throw Failure.invalidMetadata }
                let projected = rows.map { row in
                    [row.counts.scopedGoogleCookies, row.counts.exemptionFuture,
                     row.counts.exemptionExpired, row.counts.exemptionSession,
                     row.remainingLifetime.upToOneMinute, row.remainingLifetime.upToTenMinutes,
                     row.remainingLifetime.upToOneHour, row.remainingLifetime.overOneHour]
                }
                guard projected.joined().allSatisfy({ (0...GeminiVerificationCookieDiagnostic.maximumCookieCount).contains($0) })
                else { throw Failure.invalidMetadata }
                scopes = projected
            }
        }
    }

    private struct Wire: Encodable {
        let kind = "gemini_verification_cookie_timeline_v2"
        let evidence = "callback_time_native_metadata_not_request_cookie_proof"
        let seq: Int
        let read: Int?
        let triggers: [GeminiVerificationCookieTimeline.Trigger]
        let phase: GeminiVerificationCookieTimeline.Event.Phase
        let status: GeminiVerificationCookieTimeline.Event.Status
        let reason: GeminiVerificationCookieTimeline.Event.Reason?
        let coalesced: Int
        let duplicates: Int
        let metadata: Metadata?
    }

    fileprivate static func data(for event: GeminiVerificationCookieTimeline.Event) throws -> Data {
        guard event.sequence >= 0, event.read.map({ $0 >= 0 }) ?? true,
              event.coalescedTriggerCount >= 0, event.duplicateSamplesSuppressed >= 0,
              event.triggers.count <= GeminiVerificationCookieTimeline.Trigger.allCases.count,
              Set(event.triggers.map(\.rawValue)).count == event.triggers.count else { throw Failure.invalidEvent }
        let wire = Wire(seq: event.sequence, read: event.read, triggers: event.triggers,
                        phase: event.phase, status: event.status, reason: event.reason,
                        coalesced: event.coalescedTriggerCount, duplicates: event.duplicateSamplesSuppressed,
                        metadata: try event.metadata.map(Metadata.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(wire)
        guard prefix.utf8.count + data.count <= maximumMessageBytes else { throw Failure.payloadTooLarge }
        return data
    }
}

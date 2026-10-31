import Foundation

/// A bounded history of native metadata, never a recording of network packets,
/// page contents, cookie values, or an exact WebKit navigation-token identity.
enum GeminiCAPTCHADiagnostic {
    static let maximumNavigationEvents = 32
    static let maximumCookieEvents = 8
    static let maximumReportBytes = 65_536

    enum Role: String, Encodable, Sendable { case human, model, tool }
    enum Trigger: String, Encodable, Sendable { case response, transport, humanCheckpoint, beforeClose }
    enum Availability: String, Encodable, Sendable { case available, unknown }
    enum EncodingFailure: Error { case reportTooLarge }

    struct NativeState: Encodable, Sendable {
        let loading: Bool
        let pending: Bool
        let committed: Bool
        let finished: Bool
        let navigationError: Bool

        init(loading: Bool, pending: Bool, committed: Bool, finished: Bool, navigationError: Bool) {
            self.loading = loading; self.pending = pending; self.committed = committed
            self.finished = finished; self.navigationError = navigationError
        }
    }

    struct CookieEvent: Sendable {
        let date: Date
        let event: GeminiVerificationCookieTimeline.Event
    }

    /// Missing headers on a URLRequest are unknown: WebKit may populate them
    /// later. Even a present value here does not establish transmission.
    enum HeaderPresence: String, Encodable, Sendable {
        case presentInRequestMetadata = "present_in_request_metadata"
        case unknown
    }
    enum Method: String, Encodable, Sendable {
        case get = "GET", head = "HEAD", post = "POST", put = "PUT", patch = "PATCH"
        case delete = "DELETE", options = "OPTIONS", connect = "CONNECT", trace = "TRACE", unknown
    }
    enum CachePolicy: String, Encodable, Sendable {
        case protocolPolicy = "use_protocol_cache_policy"
        case reloadIgnoringLocal = "reload_ignoring_local_cache"
        case reloadIgnoringLocalAndRemote = "reload_ignoring_local_and_remote_cache"
        case cachedElseLoad = "return_cache_else_load"
        case cachedOnly = "return_cache_dont_load"
        case revalidate = "reload_revalidating_cache"
        case unknown

        init(_ policy: URLRequest.CachePolicy) {
            switch policy {
            case .useProtocolCachePolicy: self = .protocolPolicy
            case .reloadIgnoringLocalCacheData: self = .reloadIgnoringLocal
            case .reloadIgnoringLocalAndRemoteCacheData: self = .reloadIgnoringLocalAndRemote
            case .returnCacheDataElseLoad: self = .cachedElseLoad
            case .returnCacheDataDontLoad: self = .cachedOnly
            case .reloadRevalidatingCacheData: self = .revalidate
            @unknown default: self = .unknown
            }
        }
    }

    struct RequestMetadata: Encodable, Sendable {
        let source = "url_request_metadata_not_transmitted_headers"
        let destination: GeminiNavigationResponseDiagnostic.Destination
        let method: Method
        let cachePolicy: CachePolicy
        let cookie: HeaderPresence
        let referer: HeaderPresence
        let authorization: HeaderPresence

        fileprivate init(_ request: URLRequest, destination: GeminiNavigationResponseDiagnostic.Destination) {
            self.destination = destination
            method = request.httpMethod.flatMap(Method.init(rawValue:)) ?? .unknown
            cachePolicy = CachePolicy(request.cachePolicy)
            // Do not enumerate headers or inspect/retain any value or body.
            cookie = request.value(forHTTPHeaderField: "Cookie") == nil ? .unknown : .presentInRequestMetadata
            referer = request.value(forHTTPHeaderField: "Referer") == nil ? .unknown : .presentInRequestMetadata
            authorization = request.value(forHTTPHeaderField: "Authorization") == nil ? .unknown : .presentInRequestMetadata
        }
    }

    struct NavigationEvent: Encodable, Sendable {
        enum Kind: String, Encodable, Sendable { case request, response, redirect }
        let sequence: Int
        let generation: UUID
        let kind: Kind
        let observedAt: Date?
        let observationTime: Availability
        let request: RequestMetadata?
        let response: GeminiNavigationResponseDiagnostic.Snapshot?
    }

    struct NavigationHistory: Encodable, Sendable {
        let scope = "current_view_generation_context_not_exact_navigation_identity"
        let availability: Availability
        let events: [NavigationEvent]
        let droppedEvents: Int
        let eventCountSaturated: Bool
        let oldestObservedAt: Date?
        let newestObservedAt: Date?
    }

    struct HistoricalCookieEvent: Encodable, Sendable {
        let observedAt: Date?
        let observationTime: Availability
        let event: GeminiVerificationCookieTimeline.Event
    }

    struct CookieHistory: Encodable, Sendable {
        let scope = "shared_profile_historical_callback_metadata_not_request_cookie_proof"
        let availability: Availability
        let events: [HistoricalCookieEvent]
        let droppedEvents: Int
        let eventCountSaturated: Bool
        let oldestObservedAt: Date?
        let newestObservedAt: Date?
    }

    struct Report: Encodable, Sendable {
        let kind = "gemini_captcha_diagnostic"
        let version = 1
        let evidence = "sanitized_native_metadata_not_wire_request_proof"
        let requestCookiesTransmitted = Availability.unknown
        let networkOrCacheSource = Availability.unknown
        let exactNavigationIdentity = Availability.unknown
        let id: UUID
        let precedingCaptureID: UUID?
        let tabID: UUID
        let generation: UUID
        let role: Role
        let trigger: Trigger
        let capturedAt: Date?
        let captureTime: Availability
        let nativeState: NativeState?
        let nativeStateAvailability: Availability
        let navigation: NavigationHistory
        let cookies: CookieHistory

        func encodedData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(self)
            guard data.count <= maximumReportBytes else { throw EncodingFailure.reportTooLarge }
            return data
        }
    }

    struct Journal: Sendable {
        private var events: [NavigationEvent] = []
        private var sequence = 0
        private var dropped = 0
        private var saturated = false

        mutating func recordRequest(_ request: URLRequest, generation: UUID, now: Date) {
            guard let destination = GeminiNavigationResponseDiagnostic.destination(request.url) else { return }
            append(kind: .request, generation: generation, now: now,
                   request: RequestMetadata(request, destination: destination))
        }

        mutating func recordResponse(_ response: URLResponse, generation: UUID, now: Date) {
            guard let snapshot = GeminiNavigationResponseDiagnostic.project(response: response, now: now) else { return }
            append(kind: .response, generation: generation, now: now, response: snapshot)
        }

        mutating func recordRedirect(generation: UUID, now: Date) {
            // The caller gates the current view and trusted route. The action
            // callback can precede didStart's generation change, so do not infer
            // a redirect chain from matching a prior event's generation.
            append(kind: .redirect, generation: generation, now: now)
        }

        func report(tabID: UUID, generation: UUID, role: Role, trigger: Trigger, now: Date,
                    cookieEvents: [CookieEvent], nativeState: NativeState? = nil, id: UUID = UUID(),
                    earlierCookieEventsDropped: Int = 0, precedingCaptureID: UUID? = nil) -> Report {
            let cookies = cookieEvents.suffix(maximumCookieEvents).map { value in
                let date = validDate(value.date)
                return HistoricalCookieEvent(observedAt: date, observationTime: date == nil ? .unknown : .available,
                                             event: value.event)
            }
            let dates = events.compactMap(\.observedAt), cookieDates = cookies.compactMap(\.observedAt)
            let date = validDate(now)
            let (cookieDrops, cookieDropsOverflowed) = max(0, earlierCookieEventsDropped)
                .addingReportingOverflow(cookieEvents.count - cookies.count)
            return Report(id: id, precedingCaptureID: precedingCaptureID, tabID: tabID, generation: generation, role: role, trigger: trigger,
                capturedAt: date, captureTime: date == nil ? .unknown : .available,
                nativeState: nativeState, nativeStateAvailability: nativeState == nil ? .unknown : .available,
                navigation: NavigationHistory(availability: events.isEmpty ? .unknown : .available,
                    events: events, droppedEvents: dropped, eventCountSaturated: saturated,
                    oldestObservedAt: dates.min(), newestObservedAt: dates.max()),
                cookies: CookieHistory(availability: cookies.isEmpty ? .unknown : .available,
                    events: cookies, droppedEvents: cookieDropsOverflowed ? Int.max : cookieDrops,
                    eventCountSaturated: cookieDropsOverflowed || earlierCookieEventsDropped == Int.max,
                    oldestObservedAt: cookieDates.min(), newestObservedAt: cookieDates.max()))
        }

        private mutating func append(kind: NavigationEvent.Kind, generation: UUID, now: Date,
                                     request: RequestMetadata? = nil,
                                     response: GeminiNavigationResponseDiagnostic.Snapshot? = nil) {
            if sequence < Int.max { sequence += 1 } else { saturated = true }
            if events.count == maximumNavigationEvents {
                events.removeFirst()
                if dropped < Int.max { dropped += 1 } else { saturated = true }
            }
            let date = validDate(now)
            events.append(NavigationEvent(sequence: sequence, generation: generation, kind: kind,
                observedAt: date, observationTime: date == nil ? .unknown : .available,
                request: request, response: response))
        }
    }

    private static func validDate(_ date: Date) -> Date? {
        let seconds = date.timeIntervalSince1970
        // Keep finite millisecond timestamps within ordinary calendar bounds.
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_800 ? date : nil
    }
}

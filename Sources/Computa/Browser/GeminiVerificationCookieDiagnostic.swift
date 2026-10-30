import Foundation

/// Pure native candidate-cookie metadata for fixed HTTPS destinations. This is
/// not evidence of the Cookie header: host-only, partitioning, SameSite and other
/// WebKit policy can affect which cookies are sent. No result grants recovery or
/// model authority. Cookie values, properties, descriptions and hashes are never
/// read; arbitrary metadata and absolute expiry dates never leave this projection.
enum GeminiVerificationCookieDiagnostic {
    enum Destination: String, Encodable, CaseIterable, Equatable, Sendable {
        case geminiApp = "gemini_app"
        case googleSorry = "google_sorry"
        case googleSorrySlash = "google_sorry_slash"
        case googleSorryIndex = "google_sorry_index"
        case googleWWWSorry = "google_www_sorry"
        case googleWWWSorrySlash = "google_www_sorry_slash"
        case googleWWWSorryIndex = "google_www_sorry_index"

        fileprivate var domains: Set<String> {
            switch self {
            case .geminiApp: ["google.com", ".google.com", "gemini.google.com", ".gemini.google.com"]
            case .googleSorry, .googleSorrySlash, .googleSorryIndex: ["google.com", ".google.com"]
            case .googleWWWSorry, .googleWWWSorrySlash, .googleWWWSorryIndex: ["google.com", ".google.com", "www.google.com", ".www.google.com"]
            }
        }

        fileprivate var path: String {
            switch self {
            case .geminiApp: "/app"
            case .googleSorry, .googleWWWSorry: "/sorry"
            case .googleSorrySlash, .googleWWWSorrySlash: "/sorry/"
            case .googleSorryIndex, .googleWWWSorryIndex: "/sorry/index"
            }
        }
    }

    enum Status: String, Encodable, Equatable, Sendable { case available, unavailable }
    enum UnavailableReason: String, Encodable, Equatable, Sendable {
        case invalidClock = "invalid_clock"
        case inputLimitExceeded = "input_limit_exceeded"
        case metadataLimitExceeded = "metadata_limit_exceeded"
        case invalidMetadata = "invalid_metadata"
    }

    struct Counts: Encodable, Equatable, Sendable {
        let scopedGoogleCookies: Int
        let exemptionFuture: Int
        let exemptionExpired: Int
        /// Session-only cookies, or cookies with no recorded expiry.
        let exemptionSession: Int
    }

    struct Snapshot: Encodable, Equatable, Sendable {
        enum Source: String, Encodable, Equatable, Sendable { case nativeCandidateMetadata = "native_candidate_metadata" }
        let source: Source = .nativeCandidateMetadata
        let destination: Destination
        let status: Status
        let reason: UnavailableReason?
        let counts: Counts?

        fileprivate init(destination: Destination, counts: Counts) {
            self.destination = destination; status = .available; reason = nil; self.counts = counts
        }

        fileprivate init(destination: Destination, reason: UnavailableReason) {
            self.destination = destination; status = .unavailable; self.reason = reason; counts = nil
        }
    }

    static let maximumCookieCount = 4_096
    static let maximumMetadataBytes = 262_144

    static func project(_ cookies: [HTTPCookie], destination: Destination, now: Date) -> Snapshot {
        func unavailable(_ reason: UnavailableReason) -> Snapshot { .init(destination: destination, reason: reason) }
        guard now.timeIntervalSinceReferenceDate.isFinite else { return unavailable(.invalidClock) }
        guard cookies.count <= maximumCookieCount else { return unavailable(.inputLimitExceeded) }
        var scannedBytes = 0
        func bounded(_ text: String, limit: Int) -> Bool {
            let bytes = text.utf8.prefix(limit + 1).count
            guard bytes <= limit, scannedBytes <= maximumMetadataBytes - bytes else { return false }
            scannedBytes += bytes
            return true
        }
        func valid(_ text: String) -> Bool {
            !text.isEmpty && !text.utf8.contains { $0 < 0x20 || $0 == 0x7f }
        }
        let domains = destination.domains, requestPath = destination.path
        var scoped = 0, future = 0, expired = 0, session = 0
        for cookie in cookies {
            let domain = cookie.domain, path = cookie.path, name = cookie.name
            guard bounded(domain, limit: 256), bounded(path, limit: 2_048), bounded(name, limit: 1_024) else {
                return unavailable(.metadataLimitExceeded)
            }
            guard valid(domain), valid(path), path.hasPrefix("/"), valid(name) else { return unavailable(.invalidMetadata) }
            let expiry = cookie.expiresDate
            guard expiry?.timeIntervalSinceReferenceDate.isFinite != false else { return unavailable(.invalidMetadata) }
            guard domains.contains(domain.lowercased()), requestPath == path ||
                    (requestPath.hasPrefix(path) && (path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/")) else { continue }
            scoped += 1
            guard name == "GOOGLE_ABUSE_EXEMPTION" else { continue }
            if cookie.isSessionOnly || expiry == nil { session += 1 }
            else if let expiry, expiry > now { future += 1 }
            else { expired += 1 }
        }
        return .init(destination: destination, counts: .init(scopedGoogleCookies: scoped,
            exemptionFuture: future, exemptionExpired: expired, exemptionSession: session))
    }
}

import Foundation

/// A policy-callback response projection, not a wire capture. In particular,
/// response headers cannot establish request cookies or network/cache origin.
enum GeminiNavigationResponseDiagnostic {
    static let maximumJSONBytes = 768
    private static let maximumCacheControlBytes = 1_024

    enum Destination: String, Encodable, Sendable {
        case geminiApp = "gemini_app"
        case googleSorry = "google_sorry"
        case googleWWWSorry = "google_www_sorry"
    }

    enum ResponseKind: String, Encodable, Sendable { case http, nonHTTP = "non_http" }
    enum Unknown: String, Encodable, Sendable { case unknown }
    enum AgeBucket: String, Encodable, Sendable {
        case zero, future
        case upToOneMinute = "up_to_one_minute"
        case upToOneHour = "up_to_one_hour"
        case upToOneDay = "up_to_one_day"
        case overOneDay = "over_one_day"
    }
    enum ExpiryBucket: String, Encodable, Sendable {
        case expired
        case upToOneMinute = "up_to_one_minute"
        case upToOneHour = "up_to_one_hour"
        case overOneHour = "over_one_hour"
    }

    struct CacheControl: Encodable, Equatable, Sendable {
        let noStore: Bool
        let noCache: Bool
        let isPrivate: Bool
        let isPublic: Bool
        let mustRevalidate: Bool
        let maxAgePresent: Bool
    }

    struct Snapshot: Encodable, Equatable, Sendable {
        let kind = "gemini_navigation_response_v1"
        let evidence = "callback_time_response_metadata_not_wire_proof"
        let responseSource = Unknown.unknown
        let requestCookie = Unknown.unknown
        let redirectChain = Unknown.unknown
        let navigationIdentity = Unknown.unknown
        let destination: Destination
        let responseKind: ResponseKind
        let statusCode: Int?
        // Omitted fields are unknown (absent, unsupported or malformed), not
        // evidence that the corresponding header or cache behavior was absent.
        let cacheControl: CacheControl?
        let dateAge: AgeBucket?
        let age: AgeBucket?
        let expires: ExpiryBucket?

        func logData() -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(self), data.count <= maximumJSONBytes else { return nil }
            return data
        }
    }

    static func project(response: URLResponse, now: Date) -> Snapshot? {
        guard let destination = destination(response.url) else { return nil }
        guard let http = response as? HTTPURLResponse else {
            return Snapshot(destination: destination, responseKind: .nonHTTP, statusCode: nil,
                            cacheControl: nil, dateAge: nil, age: nil, expires: nil)
        }
        // Never enumerate allHeaderFields or read Cookie/Set-Cookie. Values
        // below are transient parser inputs; only finite projections survive.
        let cacheControl = parseCacheControl(http.value(forHTTPHeaderField: "Cache-Control"))
        let date = parseDate(http.value(forHTTPHeaderField: "Date"))
        let age = parseAge(http.value(forHTTPHeaderField: "Age"))
        let expires = parseDate(http.value(forHTTPHeaderField: "Expires"))
        let validClock = now.timeIntervalSince1970.isFinite
        return Snapshot(destination: destination, responseKind: .http,
                        statusCode: (100...599).contains(http.statusCode) ? http.statusCode : nil,
                        cacheControl: cacheControl,
                        dateAge: validClock ? date.flatMap { ageBucket(now.timeIntervalSince($0)) } : nil,
                        age: age,
                        expires: validClock ? expires.flatMap { expiryBucket($0.timeIntervalSince(now)) } : nil)
    }

    private static func destination(_ url: URL?) -> Destination? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        let path = parts.percentEncodedPath
        switch parts.host?.lowercased() {
        case "gemini.google.com" where path == "/app": return .geminiApp
        case "google.com" where ["/sorry", "/sorry/", "/sorry/index"].contains(path): return .googleSorry
        case "www.google.com" where ["/sorry", "/sorry/", "/sorry/index"].contains(path): return .googleWWWSorry
        default: return nil
        }
    }

    private static func asciiHeader(_ value: String?, maximum: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximum,
              value.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isToken(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    private static func parseCacheControl(_ input: String?) -> CacheControl? {
        guard let input = asciiHeader(input, maximum: maximumCacheControlBytes), !input.contains("\"") else { return nil }
        let pieces = input.split(separator: ",", omittingEmptySubsequences: false)
        guard pieces.count <= 16 else { return nil }
        var names = Set<String>()
        let bareNames: Set<String> = ["no-store", "no-cache", "private", "public", "must-revalidate"]
        for piece in pieces {
            let parts = piece.split(separator: "=", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
            guard (1...2).contains(parts.count), isToken(parts[0][...]) else { return nil }
            let name = parts[0].lowercased()
            guard names.insert(name).inserted else { return nil }
            if bareNames.contains(name), parts.count != 1 { return nil }
            if parts.count == 2, !isToken(parts[1][...]) { return nil }
            if name == "max-age" {
                guard parts.count == 2, decimal(parts[1]) != nil else { return nil }
            }
        }
        guard !(names.contains("private") && names.contains("public")) else { return nil }
        return CacheControl(noStore: names.contains("no-store"), noCache: names.contains("no-cache"),
                            isPrivate: names.contains("private"), isPublic: names.contains("public"),
                            mustRevalidate: names.contains("must-revalidate"), maxAgePresent: names.contains("max-age"))
    }

    private static func decimal(_ input: String) -> UInt64? {
        guard !input.isEmpty, input.utf8.count <= 20,
              input.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(input)
    }

    private static func parseAge(_ input: String?) -> AgeBucket? {
        guard let input = asciiHeader(input, maximum: 20), let value = decimal(input) else { return nil }
        switch value {
        case 0: return .zero
        case 1...60: return .upToOneMinute
        case 61...3_600: return .upToOneHour
        case 3_601...86_400: return .upToOneDay
        default: return .overOneDay
        }
    }

    private static func parseDate(_ input: String?) -> Date? {
        guard let input = asciiHeader(input, maximum: 64), input.utf8.count == 29 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: input), date.timeIntervalSince1970.isFinite,
              formatter.string(from: date) == input else { return nil }
        return date
    }

    private static func ageBucket(_ seconds: TimeInterval) -> AgeBucket? {
        guard seconds.isFinite else { return nil }
        if seconds < 0 { return .future }
        if seconds == 0 { return .zero }
        if seconds <= 60 { return .upToOneMinute }
        if seconds <= 3_600 { return .upToOneHour }
        if seconds <= 86_400 { return .upToOneDay }
        return .overOneDay
    }

    private static func expiryBucket(_ seconds: TimeInterval) -> ExpiryBucket? {
        guard seconds.isFinite else { return nil }
        if seconds <= 0 { return .expired }
        if seconds <= 60 { return .upToOneMinute }
        if seconds <= 3_600 { return .upToOneHour }
        return .overOneHour
    }
}

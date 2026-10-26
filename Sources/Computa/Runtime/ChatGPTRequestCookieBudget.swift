import Foundation

/// A finite, native-only estimate for one fixed HTTPS request. This is not the
/// browser's Cookie header: cookie policy, partitioning and wire selection are
/// deliberately outside this diagnostic. No cookie text survives aggregation.
struct ChatGPTProfileCookieBudget: Sendable, Equatable, Codable {
    let cookieCount: Int
    let totalNameUTF8Bytes: Int
    let totalValueUTF8Bytes: Int
    let maxValueUTF8Bytes: Int
    let estimatedCookieHeaderUTF8Bytes: Int
    let duplicateNameCount: Int

    var dictionary: [String: Any] {
        ["source": "profile_estimate", "cookieCount": cookieCount,
         "totalNameUTF8Bytes": totalNameUTF8Bytes, "totalValueUTF8Bytes": totalValueUTF8Bytes,
         "maxValueUTF8Bytes": maxValueUTF8Bytes,
         "estimatedCookieHeaderUTF8Bytes": estimatedCookieHeaderUTF8Bytes,
         "duplicateNameCount": duplicateNameCount]
    }

    /// Bounds include domain/path filtering work. An oversized profile or string
    /// returns unknown rather than a truncated, deceptively small estimate.
    static func estimate(cookies: [HTTPCookie], now: Date = Date()) -> Self? {
        guard cookies.count <= 4_096, now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let targetHost = "chatgpt.com"
        let targetPath = "/backend-api/f/conversation"
        var scannedBytes = 0
        func byteCount(_ string: String, limit: Int) -> Int? {
            let count = string.utf8.prefix(limit + 1).count
            guard count <= limit, scannedBytes <= 1_048_576 - count else { return nil }
            scannedBytes += count
            return count
        }
        var count = 0, nameBytes = 0, valueBytes = 0, maximum = 0, duplicates = 0
        var names = Set<Data>()
        for cookie in cookies {
            let domain = cookie.domain, path = cookie.path
            guard byteCount(domain, limit: 2_048) != nil,
                  byteCount(path, limit: 2_048) != nil else { return nil }
            // chatgpt.com has no registrable parent other than the public suffix
            // com. Only its exact host/domain cookies can match this fixed URL.
            let normalizedDomain = domain.lowercased()
            guard normalizedDomain == targetHost || normalizedDomain == "." + targetHost,
                  path.hasPrefix("/"), targetPath == path ||
                    (targetPath.hasPrefix(path) && (path.hasSuffix("/") || targetPath.dropFirst(path.count).first == "/")) else { continue }
            if let expiry = cookie.expiresDate {
                guard expiry.timeIntervalSinceReferenceDate.isFinite else { return nil }
                if expiry <= now { continue }
            }
            // The fixed target uses HTTPS, so both Secure and non-Secure
            // cookies are eligible. This does not infer actual browser policy.
            let name = cookie.name, value = cookie.value
            guard let nameCount = byteCount(name, limit: 65_536),
                  let valueCount = byteCount(value, limit: 65_536) else { return nil }
            count += 1; nameBytes += nameCount; valueBytes += valueCount
            maximum = max(maximum, valueCount)
            // Cookie names use byte identity; Swift String's canonical Unicode
            // equivalence must not merge distinct names in this estimate.
            if !names.insert(Data(name.utf8)).inserted { duplicates += 1 }
        }
        return Self(cookieCount: count, totalNameUTF8Bytes: nameBytes,
                    totalValueUTF8Bytes: valueBytes, maxValueUTF8Bytes: maximum,
                    estimatedCookieHeaderUTF8Bytes: nameBytes + valueBytes + count + max(0, count - 1) * 2,
                    duplicateNameCount: duplicates)
    }
}

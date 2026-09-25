import Foundation

/// Decodes the fixture's URLSearchParams wire format, not arbitrary navigation
/// URLs. Form '+' is a space only BEFORE percent decoding; '%2B' is a literal
/// plus and '%252B' remains '%2B'. Never repair decoded JSON or page identities.
enum SafeFixtureTelemetryQuery {
    static func decode(_ requestLine: String) -> [String: String]? {
        guard requestLine.utf8.count <= 8_192 else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "POST",
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        let target = parts[1]
        guard let separator = target.firstIndex(of: "?"),
              target[..<separator] == "/CuaV2SafeBenchmark.telemetry",
              !target.contains("#") else { return nil }
        let query = target[target.index(after: separator)...]
        guard !query.isEmpty else { return nil }

        var values = [String: String]()
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let name = component(pair[0]), !name.isEmpty,
                  let value = component(pair[1]),
                  values[name] == nil else { return nil }
            values[name] = value
        }
        return values
    }

    private static func component(_ encoded: Substring) -> String? {
        String(encoded)
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }
}

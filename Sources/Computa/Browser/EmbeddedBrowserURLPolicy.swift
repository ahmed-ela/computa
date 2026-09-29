import Foundation

/// A navigation policy, not a search provider or an authority to open external applications.
enum EmbeddedBrowserURLPolicy {
    enum Rejection: Error, LocalizedError, Equatable {
        case invalidAddress
        case unsupportedScheme
        case embeddedCredentials

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "Enter a website address, such as https://example.com."
            case .unsupportedScheme: "This browser supports only HTTP, HTTPS, and about:blank. No external application or file was opened."
            case .embeddedCredentials: "Addresses containing a username or password are not supported."
            }
        }
    }

    static func validate(_ url: URL) throws {
        if url.absoluteString == "about:blank" { return }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw Rejection.unsupportedScheme
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              !host.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              components.port.map({ (1 ... 65_535).contains($0) }) ?? true else {
            throw Rejection.invalidAddress
        }
        guard components.user == nil, components.password == nil else {
            throw Rejection.embeddedCredentials
        }
    }

    static func normalize(_ address: String) throws -> URL {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else {
            throw Rejection.invalidAddress
        }
        let candidate: String
        if value == "about:blank" || value.contains("://") {
            candidate = value
        } else {
            // A host:port is an address; an arbitrary scheme is never reinterpreted as a host.
            let authority = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
            if let colon = authority.lastIndex(of: ":"), !authority.hasPrefix("[") {
                let port = authority[authority.index(after: colon)...]
                guard !port.isEmpty, port.allSatisfy(\.isNumber) else { throw Rejection.unsupportedScheme }
            }
            guard authority == "localhost" || authority.hasPrefix("localhost:") || authority.contains(".") || authority.hasPrefix("[") else {
                throw Rejection.invalidAddress
            }
            candidate = "https://" + value
        }
        guard let url = URL(string: candidate) else { throw Rejection.invalidAddress }
        try validate(url)
        return url
    }
}

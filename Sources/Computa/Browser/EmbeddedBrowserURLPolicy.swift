import Foundation

/// Resolves human address-bar input while restricting navigation to web pages.
enum EmbeddedBrowserURLPolicy {
    static let newTabURL = URL(string: "https://www.google.com/")!

    enum Rejection: Error, LocalizedError, Equatable {
        case invalidAddress
        case unsupportedScheme
        case embeddedCredentials

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "Enter a search or website address."
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

    /// Restore ordinary pages as GET navigations. OAuth grants belong to the original sign-in.
    static func workspaceAddress(_ url: URL?) -> URL? {
        guard let url, (try? validate(url)) != nil, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let keys = parameterNames(in: parts)
        guard keys.isDisjoint(with: ["access_token", "refresh_token", "id_token"]),
              !(keys.contains("code") && keys.contains("state")) else { return nil }
        return url
    }

    /// Identify temporary authentication routes on either end of a popup redirect. A blank opener
    /// is still eligible once an ordinary document commits (for example, window.open followed by location.assign).
    static func isSignInAddress(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let keys = parameterNames(in: parts)
        // An OAuth callback can carry an authorization code without a state parameter.
        if !keys.isDisjoint(with: ["code", "redirect_uri", "response_type", "code_challenge", "code_verifier",
                                   "access_token", "id_token", "refresh_token", "oauth_token", "oauth_verifier",
                                   "samlrequest", "samlresponse", "samlart", "relaystate"]) { return true }

        let endpoints: Set<String> = ["authorize", "callback", "signin", "sign-in", "login", "log-in",
                                      "servicelogin", "accountchooser", "saml", "sso", "oauth", "oauth2"]
        let routes = [parts.path, parts.fragment?.components(separatedBy: "?").first ?? ""]
        return routes.contains { route in
            let path = route.lowercased().split(separator: "/").map(String.init)
            return path.first.map(endpoints.contains) == true ||
                (path.contains("auth") && path.last.map(endpoints.contains) == true)
        }
    }

    private static func parameterNames(in parts: URLComponents) -> Set<String> {
        var fragment = URLComponents()
        // Covers both #access_token=… and hash routers such as #/callback?code=…&state=….
        fragment.percentEncodedQuery = parts.percentEncodedFragment
        var items = (parts.queryItems ?? []) + (fragment.queryItems ?? [])
        if let hash = parts.percentEncodedFragment, let query = hash.firstIndex(of: "?") {
            fragment.percentEncodedQuery = String(hash[hash.index(after: query)...])
            items += fragment.queryItems ?? []
        }
        return Set(items.map { $0.name.lowercased() })
    }

    /// srcdoc is a browser-created iframe document, not a top-level address.
    /// Keep address-bar and popup validation unchanged; the containing web
    /// document and WebKit's frame/origin rules supply its browsing context.
    static func validateNavigation(_ url: URL, isMainFrame: Bool, mainDocumentURL: URL?) throws {
        if !isMainFrame, url.absoluteString == "about:srcdoc",
           let mainDocumentURL, ["http", "https"].contains(mainDocumentURL.scheme?.lowercased() ?? "") {
            try validate(mainDocumentURL)
            return
        }
        try validate(url)
    }

    /// Finite diagnostics never include an address, credentials or page data.
    static func diagnosticAddressKind(_ url: URL?) -> String {
        guard let url else { return "missing" }
        if url.absoluteString == "about:srcdoc" { return "about_srcdoc" }
        if url.absoluteString == "about:blank" { return "about_blank" }
        switch url.scheme?.lowercased() {
        case "http": return "http"
        case "https": return "https"
        case "about": return "about_other"
        case "blob": return "blob"
        case "data": return "data"
        case "file": return "file"
        case "javascript": return "javascript"
        default: return "other"
        }
    }

    static func normalize(_ address: String) throws -> URL {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Rejection.invalidAddress }
        if let colon = value.firstIndex(of: ":"),
           ["site", "inurl", "intitle", "intext", "filetype", "before", "after"].contains(value[..<colon].lowercased()) {
            return try searchURL(for: value)
        }
        let candidate: String
        if value == "about:blank" || value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
            candidate = value
        } else if !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
            // A host:port is an address; an arbitrary scheme is never reinterpreted as a host.
            let authority = value.prefix { !"/?#".contains($0) }
            if let colon = authority.lastIndex(of: ":"), !authority.hasPrefix("[") {
                let port = authority[authority.index(after: colon)...]
                guard !port.isEmpty, port.allSatisfy(\.isNumber) else { throw Rejection.unsupportedScheme }
            }
            if authority == "localhost" || authority.hasPrefix("localhost:") || authority.contains(".") || authority.hasPrefix("[") {
                candidate = "https://" + value
            } else {
                return try searchURL(for: value)
            }
        } else {
            // Keep executable/external URL schemes blocked while allowing phrases with a colon.
            if let colon = value.firstIndex(of: ":"),
               ["javascript", "data", "file", "mailto", "tel", "ftp", "about", "http", "https"].contains(value[..<colon].lowercased()) {
                throw Rejection.unsupportedScheme
            }
            return try searchURL(for: value)
        }
        guard let url = URL(string: candidate) else { throw Rejection.invalidAddress }
        try validate(url)
        return url
    }

    static func searchURL(for query: String) throws -> URL {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search engines interpret a literal plus as a space in query parameters.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw Rejection.invalidAddress }
        try validate(url)
        return url
    }
}

import CryptoKit
import Foundation

/// Conservative search-interface evidence, distinct from successful text
/// entry. Runtime observations are the only inputs: no assistant success flag,
/// snapshot filter match count, or arbitrary body text can verify emptiness.
/// This confirms the current query/results interface, not every natural-
/// language claim about the records it contains or an exhaustive account scan.
struct ComputerSearchEvidence: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case notTracked, awaitingQueryRoute, awaitingResults
        case queryResultsObserved, queryEmptyStateObserved

        var isVerified: Bool { self == .queryResultsObserved || self == .queryEmptyStateObserved }
    }

    enum Failure: Error, LocalizedError {
        case invalidRequest, capacityExceeded
        var errorDescription: String? {
            switch self {
            case .invalidRequest: "Search evidence requires a bounded target identity and nonempty entered query."
            case .capacityExceeded: "Too many search targets remain tracked; their outcomes are unverified."
            }
        }
    }

    private struct Search: Codable, Equatable, Sendable {
        let queryFingerprint: String
        let routeWasAlreadyPresent: Bool
        var status: Status = .awaitingQueryRoute
    }

    private var searches: [String: Search] = [:]

    /// Call only for actual input into a runtime-observed search control, not
    /// from a guessed query in the user's prose. A later edit supersedes the
    /// current field contents without claiming the previous query was run.
    mutating func beginSearch(targetID: String, query: String, baselineDocumentURL: URL? = nil) throws {
        let query = Self.normalizedQuery(query)
        guard !targetID.isEmpty, targetID.utf8.count <= 256, !query.isEmpty, query.utf8.count <= 8_192 else {
            throw Failure.invalidRequest
        }
        guard searches[targetID] != nil || searches.count < 16 else { throw Failure.capacityExceeded }
        searches[targetID] = Search(queryFingerprint: Self.fingerprint(query),
            routeWasAlreadyPresent: baselineDocumentURL.flatMap(Self.query(in:)) == query)
    }

    static func isSearchInput(role: String, label: String) -> Bool {
        let role = role.lowercased()
        if ["searchbox", "axsearchfield"].contains(role) { return true }
        guard ["textbox", "textfield", "axtextfield", "combobox"].contains(role), label.count <= 256 else { return false }
        let label = normalized(label)
        return label == "search" || label.hasPrefix("search ") || label == "find" || label.hasPrefix("find ")
    }

    /// Only a fresh source observation can advance search evidence. Bounded or
    /// filtered snapshots may lack proof and remain unverified; absence of
    /// matching elements never becomes a negative search result.
    @discardableResult
    mutating func observe(targetID: String, documentURL: URL, elements: [BrowserTabElement], isLive: Bool,
                          sourceTruncated: Bool = false) -> Status {
        guard var search = searches[targetID] else { return .notTracked }
        guard isLive else { return search.status }
        guard Self.query(in: documentURL).map(Self.fingerprint) == search.queryFingerprint else {
            search.status = .awaitingQueryRoute
            searches[targetID] = search
            return search.status
        }
        search.status = .awaitingResults
        let nodes = Dictionary(grouping: elements.compactMap { element -> (String, BrowserTabElement)? in
            guard let id = element.nodeID, !id.isEmpty else { return nil }
            return (id, element)
        }, by: { $0.0 }).filter { $0.value.count == 1 }.mapValues { $0[0].1 }
        let scopes = Set(nodes.compactMap { id, node -> String? in
            guard ["region", "feed", "list", "table", "grid", "main"].contains(Self.semanticRole(node)),
                  Self.isResultsLabel(node.label, queryFingerprint: search.queryFingerprint) else { return nil }
            return id
        })
        let scoped = nodes.values.filter { Self.isDescendant($0, of: scopes, nodes: nodes) }
        let empty = scoped.contains { node in
            // Deliberately not StaticText/cell/paragraph, where an email body
            // or arbitrary document text could say "No results found".
            ["status", "alert", "heading"].contains(Self.semanticRole(node))
                && Self.isEmptyStateLabel(node.label, queryFingerprint: search.queryFingerprint)
        }
        let results = scoped.contains { node in
            ["listitem", "article"].contains(Self.semanticRole(node)) && !Self.normalized(node.label).isEmpty
        } || scoped.contains { row in
            Self.semanticRole(row) == "row" && scoped.contains { child in
                Self.semanticRole(child) == "link" && !Self.normalized(child.label).isEmpty
                    && row.nodeID.map { Self.isDescendant(child, of: [$0], nodes: nodes) } == true
            }
        }
        if empty && !results && !sourceTruncated { search.status = .queryEmptyStateObserved }
        else if results && !empty { search.status = .queryResultsObserved }
        // Conflicting empty/result evidence stays unverified; it may be a
        // partial update, unrelated scope, or stale site-rendered status.
        searches[targetID] = search
        return search.status
    }

    var completionDiagnostic: String? {
        let unresolved = searches.values.filter { !$0.status.isVerified }.count
        guard unresolved > 0 else { return nil }
        return "Search outcome not verified: \(unresolved) requested search query/queries lack verified query-and-results evidence. "
            + "Entering text alone does not establish that a search ran, and a filtered snapshot with no matches does not establish that the site returned no results."
    }

    func checkpointText() -> String {
        let pending = searches.values.filter { !$0.status.isVerified }.count
        return "RUNTIME_SEARCH_EVIDENCE tracked=\(searches.count) pending=\(pending). "
            + (completionDiagnostic ?? "Only observed query/results interfaces are verified; this does not prove arbitrary task claims.")
    }

    private static func isResultsLabel(_ label: String, queryFingerprint: String) -> Bool {
        let label = normalizedQuery(label)
        return label.lowercased() == "search results" || matchesQueriedLabel(label,
            prefixes: ["search results for ", "results for "], queryFingerprint: queryFingerprint)
    }

    private static func semanticRole(_ element: BrowserTabElement) -> String {
        (element.semanticRole ?? element.role).lowercased()
    }

    private static func isEmptyStateLabel(_ label: String, queryFingerprint: String) -> Bool {
        let label = normalizedQuery(label).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["no results", "no results found", "no matching results", "no matching results found",
                "no search results", "no search results found", "no conversations found"].contains(label.lowercased())
            || matchesQueriedLabel(label, prefixes: ["no results for "], queryFingerprint: queryFingerprint)
    }

    private static func matchesQueriedLabel(_ label: String, prefixes: [String], queryFingerprint: String) -> Bool {
        guard let prefix = prefixes.first(where: label.lowercased().hasPrefix) else { return false }
        let remainder = String(label.dropFirst(prefix.count))
        if fingerprint(remainder) == queryFingerprint { return true }
        if (remainder.hasPrefix("\"") && remainder.hasSuffix("\""))
            || (remainder.hasPrefix("“") && remainder.hasSuffix("”")) {
            return fingerprint(String(remainder.dropFirst().dropLast())) == queryFingerprint
        }
        return false
    }

    private static func isDescendant(_ element: BrowserTabElement, of scopes: Set<String>,
                                     nodes: [String: BrowserTabElement]) -> Bool {
        var parent = element.parentNodeID
        var seen = Set<String>()
        while let id = parent, seen.count < 64, seen.insert(id).inserted {
            if scopes.contains(id) { return true }
            guard let node = nodes[id] else { return false }
            parent = node.parentNodeID
        }
        return false
    }

    private static func query(in url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Adapter isolated to an observed Gmail route. It establishes the
        // current query only, never results or an empty account/inbox.
        if url.host?.lowercased() == "mail.google.com", let fragment = components.percentEncodedFragment,
           fragment.hasPrefix("search/") {
            return decodeQuery(String(fragment.dropFirst("search/".count)))
        }
        let queries = (components.percentEncodedQuery ?? "").split(separator: "&").compactMap { pair -> String? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let key = String(parts[0]).removingPercentEncoding?.lowercased(),
                  ["q", "query", "search"].contains(key) else { return nil }
            return decodeQuery(String(parts[1]))
        }
        let unique = Set(queries)
        return unique.count == 1 ? unique.first : nil
    }

    private static func decodeQuery(_ value: String) -> String? {
        guard let decoded = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
        return normalizedQuery(decoded)
    }

    private static func normalized(_ value: String) -> String {
        normalizedQuery(value).lowercased()
    }

    private static func normalizedQuery(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

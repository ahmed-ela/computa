import Foundation

/// A deliberately conservative restriction derived only from the submitted
/// user request. Model arguments, page text, tab titles, and compaction prose
/// must never be passed to this initializer as authority.
///
/// This is not a general natural-language intent classifier. Unknown and
/// multi-site requests remain unknown/ambiguous; a matching site proves only
/// target identity, never that the user's task or search succeeded.
struct ComputerTaskScope: Equatable, Sendable {
    enum TargetConfidence: String, Equatable, Sendable {
        case unknown, ambiguous, explicitURL, recognizedService, exactTabTitle
    }

    private struct Site: Equatable, Sendable {
        let name: String
        let hosts: Set<String>
        let port: Int?

        func matches(_ url: URL) -> Bool {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                  hosts.contains(host), url.user == nil, url.password == nil else { return false }
            return port == nil || (url.port ?? (url.scheme == "https" ? 443 : 80)) == port
        }
    }

    private struct Service {
        let name: String
        let aliases: [String]
        let hosts: Set<String>
    }

    // Identity catalog, not task-specific recovery code. Exact hosts prevent a
    // misleading title, URL query, or attacker-controlled suffix from matching.
    private static let services: [Service] = [
        .init(name: "Gmail", aliases: ["gmail"], hosts: ["mail.google.com"]),
        .init(name: "Outlook", aliases: ["outlook"], hosts: ["outlook.live.com", "outlook.office.com", "outlook.office365.com"]),
        .init(name: "YouTube", aliases: ["youtube"], hosts: ["youtube.com", "www.youtube.com", "m.youtube.com"]),
        .init(name: "GitHub", aliases: ["github"], hosts: ["github.com", "www.github.com"]),
        .init(name: "Google Calendar", aliases: ["google calendar"], hosts: ["calendar.google.com"]),
        .init(name: "Google Drive", aliases: ["google drive"], hosts: ["drive.google.com"]),
        .init(name: "Google Docs", aliases: ["google docs"], hosts: ["docs.google.com"]),
        .init(name: "ChatGPT", aliases: ["chatgpt"], hosts: ["chatgpt.com", "www.chatgpt.com", "chat.openai.com"]),
        .init(name: "Wikipedia", aliases: ["wikipedia"], hosts: ["wikipedia.org", "www.wikipedia.org", "en.wikipedia.org"]),
    ]

    let backgroundChromeOnly: Bool
    let targetConfidence: TargetConfidence
    private let site: Site?
    private let exactTitle: String?

    init(userPrompt: String) {
        let normalized = userPrompt.replacingOccurrences(of: "\u{2011}", with: "-")
        backgroundChromeOnly = Self.explicitBackgroundOnly(normalized)
        let titles = Set(Self.matches(#"\b(?:tabs?|pages?)\s+(?:titled|named|called)\s+[\"“]([^\"”]+)[\"”]"#,
                                     in: normalized, group: 1).map(Self.normalizedTitle))
        let rawURLs = Self.matches(#"https?://[^\s<>\"“”]+"#, in: normalized)
        let urls = rawURLs.compactMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)\u{2019}]"))
            guard let url = URL(string: trimmed), url.host != nil, url.user == nil, url.password == nil else { return nil }
            return url
        }
        var nonURLText = normalized
        for raw in rawURLs { nonURLText = nonURLText.replacingOccurrences(of: raw, with: " ") }
        let mentioned = Self.services.filter { service in
            service.aliases.contains { alias in
                let name = NSRegularExpression.escapedPattern(for: alias)
                guard Self.hasMatch("\\b" + name + "\\b", in: nonURLText) else { return false }
                // A negated site is not a requested destination. Conservative
                // omission is preferable to inventing a positive restriction.
                return !Self.hasMatch(#"\b(?:not|except|excluding|avoid|do not use|don't use|don’t use|do not open|don't open|don’t open)\s+(?:the\s+)?"# + name + #"\b"#, in: nonURLText)
            }
        }
        let origins = Set(urls.compactMap { url -> String? in
            guard let host = url.host?.lowercased() else { return nil }
            return host + ":" + String(url.port ?? (url.scheme == "https" ? 443 : 80))
        })
        guard titles.count <= 1, origins.count <= 1, mentioned.count <= 1 else {
            site = nil; exactTitle = nil; targetConfidence = .ambiguous
            return
        }
        exactTitle = titles.first
        if let url = urls.first, let host = url.host?.lowercased() {
            // Conflicting named service + URL cannot be resolved with syntax.
            if let service = mentioned.first, !service.hosts.contains(host) {
                site = nil; targetConfidence = .ambiguous
                return
            }
            site = Site(name: host, hosts: [host], port: url.port ?? (url.scheme == "https" ? 443 : 80))
            targetConfidence = .explicitURL
        } else if let service = mentioned.first {
            site = Site(name: service.name, hosts: service.hosts, port: nil)
            targetConfidence = .recognizedService
        } else {
            site = nil
            targetConfidence = exactTitle == nil ? .unknown : .exactTabTitle
        }
    }

    /// A host-retained target can give an otherwise untargeted follow-up its
    /// previous restrictions, never its old action capabilities. The caller
    /// must require the same still-authorized connection before setting the
    /// flag. Explicit/ambiguous current targets are new user intent and win.
    /// No affirmative-word list or model-authored history is used as authority.
    func preservingContinuationRestrictions(from previous: Self?, hasRetainedTarget: Bool) -> Self {
        guard hasRetainedTarget, targetConfidence == .unknown, let previous else { return self }
        return Self(continuing: previous, backgroundChromeOnly: backgroundChromeOnly || previous.backgroundChromeOnly)
    }

    private init(continuing previous: Self, backgroundChromeOnly: Bool) {
        self.backgroundChromeOnly = backgroundChromeOnly
        targetConfidence = previous.targetConfidence
        site = previous.site
        exactTitle = previous.exactTitle
    }

    /// Called before tool dispatch, with host-owned binding state. A model may
    /// not relax this restriction by passing activation=none or inventing an
    /// alternative tool name. Reads/actions require the borrowed tab binding.
    func toolViolation(tool: String, hasBorrowedBinding: Bool) -> String? {
        guard backgroundChromeOnly else { return nil }
        switch tool {
        case "computer_v2_status", "computer_v2_apps", "computer_v2_tabs", "computer_v2_bind_tab":
            return nil
        case "computer_v2_snapshot", "computer_v2_ax", "computer_v2_set_text", "computer_v2_verify":
            guard !hasBorrowedBinding else { return nil }
            return "This request permits background Chrome tab tools only. Bind an observed Chrome tab before reading or interacting; native app fallback is outside the requested scope."
        default:
            guard tool == "computer" || tool.hasPrefix("computer_") || tool.hasPrefix("desktop_") else { return nil }
            return "This request permits background Chrome tab tools only. Foreground app opening, new-tab fallback, screenshots, and global keyboard/pointer input are outside the requested scope. No action was dispatched."
        }
    }

    /// Call with the native owner's current inventory metadata, never a URL or
    /// title supplied by the model. A nil result is not semantic task proof.
    func candidateViolation(url: URL, title: String) -> String? {
        guard targetConfidence != .ambiguous else { return nil }
        if let violation = siteViolation(url: url) { return violation }
        if let exactTitle, Self.normalizedTitle(title) != exactTitle {
            return "The selected tab does not match the exact tab title in the user request. Do not substitute another tab or infer that its contents answer the request."
        }
        return nil
    }

    /// A document snapshot may not carry the inventory tab title. Validate its
    /// site without substituting an empty title or weakening bind-time checks.
    func siteViolation(url: URL) -> String? {
        guard targetConfidence != .ambiguous, let site, !site.matches(url) else { return nil }
        return "The selected tab does not match the requested \(site.name) site. Do not substitute an unrelated tab. Refresh the inventory if needed; if the requested site is absent, report that it was not found instead of binding another site."
    }

    private static func explicitBackgroundOnly(_ prompt: String) -> Bool {
        // Only explicit restrictions, not a passing mention such as "is
        // background Chrome faster?". Unrecognized phrasing is not interpreted
        // as a runtime-enforced promise.
        let patterns = [
            #"(?:^|[.!?\n])\s*(?:please\s+)?(?:use\s+)?(?:the\s+)?background\s+(?:chrome|browser)(?:\s+tab)?(?:\s+tools?)?\s+only\b"#,
            #"(?:^|[.!?\n])\s*(?:please\s+)?use\s+(?:the\s+)?background-only\s+(?:chrome|browser)\b"#,
            #"\b(?:chrome|browser)\s+(?:tab\s+)?tools?\s+only\s+in\s+the\s+background\b"#,
        ]
        return patterns.contains { hasMatch($0, in: prompt) }
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func hasMatch(_ pattern: String, in value: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?
            .firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func matches(_ pattern: String, in value: String, group: Int = 0) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range(at: group), in: value) else { return nil }
            return String(value[range])
        }
    }
}

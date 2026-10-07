import AppKit
import CoreFoundation
import Foundation
import OSLog
@preconcurrency import WebKit

/// Inference-only browser access. The website has no tool or native IPC handlers.
/// Prompts are data passed to a fixed DOM program in an isolated content world.
@MainActor
final class EmbeddedWebModelTransport: WebModelTransport {
    /// Every session pins one provider. A valid route on another provider can
    /// never satisfy its ownership checks, including before its first submit.
    enum Provider: String, CaseIterable {
        case chatgpt, claude, gemini

        var host: String {
            switch self {
            case .chatgpt: "chatgpt.com"
            case .claude: "claude.ai"
            case .gemini: "gemini.google.com"
            }
        }

        var displayName: String {
            switch self {
            case .chatgpt: "ChatGPT"
            case .claude: "Claude"
            case .gemini: "Gemini"
            }
        }

        var startURL: URL {
            switch self {
            case .chatgpt: URL(string: "https://chatgpt.com/?temporary-chat=true")!
            case .claude: URL(string: "https://claude.ai/new?incognito")!
            case .gemini: URL(string: "https://gemini.google.com/app")!
            }
        }

        func accepts(_ raw: String) -> Bool {
            guard let url = originURL(raw) else { return false }
            return isFreshPath(url.path) || conversationURL(raw) != nil
        }

        func conversationURL(_ raw: String?) -> String? {
            guard let raw, let url = originURL(raw) else { return nil }
            let pattern: String
            switch self {
            case .chatgpt: pattern = #"^/c/(?:[A-Za-z0-9-]+|local-chatgpt(?:%3[Aa]|:)[A-Za-z0-9-]+)/?$"#
            case .claude: pattern = #"^/chat/[A-Za-z0-9-]+/?$"#
            case .gemini: pattern = #"^/(?:u/[0-9]{1,3}/)?app/[A-Za-z0-9_-]+/?$"#
            }
            guard url.path.range(of: pattern, options: .regularExpression) != nil else { return nil }
            return "https://\(host)" + (url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path)
        }

        func isLocalConversation(_ route: String?) -> Bool {
            self == .chatgpt && route?.contains("/c/local-chatgpt") == true
        }

        /// Gemini may select an account before readiness. Once observed, its
        /// account prefix is immutable, including the first conversation route.
        func routeContext(_ raw: String) -> String? {
            guard accepts(raw), let url = originURL(raw) else { return nil }
            switch self {
            case .chatgpt: return "https://\(host)/"
            case .claude: return "https://\(host)/new"
            case .gemini:
                guard let range = url.path.range(of: #"^/(?:u/[0-9]{1,3}/)?app(?=/|$)"#, options: .regularExpression) else { return nil }
                return "https://\(host)" + String(url.path[range])
            }
        }

        func acceptsTemporaryToggle(_ url: URL) -> Bool {
            guard accepts(url.absoluteString), conversationURL(url.absoluteString) == nil else { return false }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch self {
            case .chatgpt: return query.contains(URLQueryItem(name: "temporary-chat", value: "true"))
            case .claude: return query.contains { $0.name == "incognito" }
            case .gemini: return false // Gemini changes its mode without changing the route.
            }
        }

        func acceptsUnboundStart(_ url: URL) -> Bool {
            guard accepts(url.absoluteString), conversationURL(url.absoluteString) == nil else { return false }
            return self == .gemini ? true : acceptsTemporaryToggle(url)
        }

        private func originURL(_ raw: String) -> URL? {
            guard let url = URL(string: raw), url.scheme == "https", url.host == host,
                  url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return nil }
            return url
        }

        private func isFreshPath(_ path: String) -> Bool {
            switch self {
            case .chatgpt: path == "/"
            case .claude: path == "/new" || path == "/new/"
            case .gemini: path.range(of: #"^/(?:u/[0-9]{1,3}/)?app/?$"#, options: .regularExpression) != nil
            }
        }
    }

    enum OwnershipReason: String {
        case documentGenerationBefore = "document_generation_before"
        case documentGenerationAfter = "document_generation_after"
        case routeBefore = "route_before"
        case routeAfter = "route_after"
        case unboundCleanup = "unbound_cleanup"
        case javaScriptDocument = "js_document_changed"
        case javaScriptConversation = "js_conversation_changed"
        case javaScriptOwner = "owner_token"
        case javaScriptUserCount = "user_count"
        case javaScriptConversationIdentity = "conversation_identity"
        case javaScriptURL = "document_url"
        case javaScriptConversationRoute = "conversation_route"
        case javaScriptFirstUser = "first_user_message"
        case promotionFirstUser = "promotion_first_user"
        case promotionTemporary = "promotion_temporary"
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidRequest, unsupportedProvider, capacity, staleSession, documentChanged
        case signInRequired, temporaryUnverified, notFresh, composerUnavailable
        case pageUnavailable, responseTooLarge, responseInterrupted, preparationDeadline, deadline
        case submissionObservationPending
        case modelUnverified, modelMismatch, modelUnavailable, discoveryCleanupFailed
        case usageLimited(Provider)
        case editorFailure(String)
        case ownershipFailure(OwnershipReason)

        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The built-in browser model request could not be validated."
            case .unsupportedProvider: "That model provider is not supported in the built-in browser."
            case .capacity: "Finish an existing website-model task before opening another session. If failed sessions remain retained, restart Computa to free local capacity; their website cleanup remains unconfirmed."
            case .staleSession: "The owned browser model session is no longer available."
            case .documentChanged: "The owned model page or conversation changed. No prompt was replayed."
            case .ownershipFailure(let reason): "The owned model page or conversation changed (\(reason.rawValue)). No prompt was replayed."
            case .signInRequired: "Sign in to the selected AI website in Computa's built-in browser, then retry."
            case .temporaryUnverified: "The AI website did not confirm temporary or incognito chat mode. No further prompt was sent."
            case .notFresh: "The new model page was not empty. It was not modified."
            case .composerUnavailable: "The website's message editor could not accept the exact prompt. No send was retried."
            case .editorFailure(let reason): "The website's message editor could not accept the exact prompt (\(reason)). No send was retried."
            case .pageUnavailable: "The model page could not be inspected in the built-in browser."
            case .submissionObservationPending: "The submitted message is still appearing on the model page."
            case .modelUnverified: "The website's selected model could not be verified. No prompt was replayed. Refresh the website models and retry."
            case .modelMismatch: "The website changed or reported a different model. Its response was not accepted, and no prompt was replayed."
            case .modelUnavailable: "That model is not available in the website's current account. Refresh the website models and choose an available model."
            case .discoveryCleanupFailed: "The model menu session could not be closed. Restart Computa to refresh website models."
            case .responseTooLarge: "The website's response exceeded the local browser transport limit."
            case .responseInterrupted: "The website interrupted its response. No send was retried."
            case .usageLimited(let provider): "\(provider.displayName)'s website usage limit has been reached. Try again after your account's limit resets."
            case .preparationDeadline: "The website did not prepare a verified temporary or incognito chat before the 45-second deadline. No prompt was sent."
            case .deadline: "The website did not finish its response before the five-minute deadline."
            }
        }
    }

    private final class Session {
        let token = UUID().uuidString
        let firstUserMarker = UUID().uuidString
        let tabID: UUID
        let provider: Provider
        let modelChoice: WebsiteModelChoice?
        let isDiscovery: Bool
        let view: WKWebView
        let initialDocumentGeneration: UUID
        let created = ContinuousClock.now
        var state = "loading"
        var submitted = false
        var temporary = false
        var temporaryRequested = false
        var sequence = 0
        var confirmedUsers = 0
        var pendingSubmission = false
        var baseline = 0
        var response = ""
        var lastChanged = ContinuousClock.now
        var turnStarted = ContinuousClock.now
        var conversation: String?
        var routeContext: String?
        var conversationIdentity: String?
        var firstUserFingerprint: String?
        var promoted = false
        var documentGeneration: UUID?
        var completionCandidate = false
        var candidateSince: ContinuousClock.Instant?
        var initialReadRetry: ContinuousClock.Instant?
        var initialReadFailures = 0
        var lastInspection: InspectionSignature?
        var loggedStructure = false
        var loggedReadinessStages: Set<Bool> = []
        var loggedCodeSequence: Int?
        var loggedCodeResponseCount: Int?
        var loggedFirstUserStructure = false
        var lastQuotaDiagnostic: [String]?
        var modelSelectionRequested = false
        var modelSelectionVerified = false
        var modelEvidence: WebsiteModelEvidence?
        var lastModelDiagnostic: String?
        var observedResponseCount = 0

        init(provider: Provider, tabID: UUID, view: WKWebView, documentGeneration: UUID, modelChoice: WebsiteModelChoice? = nil,
             isDiscovery: Bool = false) {
            self.provider = provider
            self.modelChoice = modelChoice
            self.isDiscovery = isDiscovery
            self.tabID = tabID
            self.view = view
            initialDocumentGeneration = documentGeneration
        }
    }

    private let browser: EmbeddedBrowserSession
    private let createTab: @MainActor (URL) throws -> UUID
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")
    private var sessions: [String: Session] = [:]
    private var scripts: [Provider: String] = [:]
    private var preparationTimeout: Duration = .seconds(45)
    private var responseTimeout: Duration = .seconds(300)
    private static let inspectionLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "EmbeddedWebModel")
    private struct InspectionSignature: Equatable {
        let responses: Int, users: Int, sequence: Int, textBytes: Int
        let pending: Bool, busy: Bool, answerComplete: Bool, ownershipPending: Bool, composer: Bool, temporary: Bool, temporaryActionAvailable: Bool
        let modernMarkers: Int, logicalAnswers: Int, scopedCopies: Int, enabledCopies: Int, depth: Int
    }
    #if DEBUG
    private var beforePageResultValidationForTesting: (@MainActor (String) async -> Void)?
    #endif

    init(browser: EmbeddedBrowserSession) {
        self.browser = browser
        self.createTab = { try browser.createModelTab(url: $0) }
    }

    #if DEBUG
    init(browser: EmbeddedBrowserSession, createTabForTesting: @escaping @MainActor (URL) throws -> UUID) {
        self.browser = browser
        self.createTab = createTabForTesting
    }

    func setBeforePageResultValidationForTesting(_ hook: (@MainActor (String) async -> Void)?) {
        beforePageResultValidationForTesting = hook
    }

    func setTimeoutsForTesting(preparation: Duration, response: Duration) {
        preparationTimeout = max(.milliseconds(1), min(.seconds(45), preparation))
        responseTimeout = max(.milliseconds(1), min(.seconds(300), response))
    }
    #endif

    func request(operation: String, params: Data) async throws -> Data {
        guard let values = try JSONSerialization.jsonObject(with: params) as? [String: String] else {
            throw Failure.invalidRequest
        }
        if operation == "webProviderStart" {
            try Task.checkCancellation()
            guard Set(values.keys) == ["provider"] || Set(values.keys) == ["provider", "modelChoice"] else { throw Failure.invalidRequest }
            guard let raw = values["provider"], let provider = Provider(rawValue: raw) else { throw Failure.unsupportedProvider }
            let choice: WebsiteModelChoice?
            if let encoded = values["modelChoice"] {
                guard let parsed = WebsiteModelChoice.parse(encoded), parsed.provider == raw else { throw Failure.invalidRequest }
                choice = parsed
            } else { choice = nil }
            let session = try createSession(provider: provider, choice: choice, isDiscovery: false)
            return try snapshot(session)
        }
        guard ["webProviderPoll", "webProviderSend", "webProviderFinish", "webProviderCancel"].contains(operation),
              Set(values.keys) == (operation == "webProviderSend" ? ["sessionToken", "prompt"] : ["sessionToken"]),
              let token = values["sessionToken"], let session = sessions[token] else { throw Failure.staleSession }
        switch operation {
        case "webProviderFinish", "webProviderCancel":
            return await finish(session, cancel: operation == "webProviderCancel")
        case "webProviderSend":
            guard !session.isDiscovery else { throw Failure.invalidRequest }
            try Task.checkCancellation()
            guard let prompt = values["prompt"], !prompt.isEmpty, prompt.utf8.count <= 180_000,
                  ["ready", "complete"].contains(session.state), !session.pendingSubmission else {
                throw Failure.invalidRequest
            }
            let before = try await page(session, action: "prepare")
            guard before["temporary"] as? Bool == true, session.temporary else { throw Failure.temporaryUnverified }
            guard before["prepared"] as? Bool == true else { throw Failure.editorFailure("focus_unavailable") }
            if !session.submitted {
                guard count(before, "responseCount") == 0, count(before, "userCount") == 0,
                      session.provider.conversationURL(before["url"] as? String) == nil else { throw Failure.notFresh }
            }
            session.baseline = count(before, "responseCount")
            // Keep the lineage marker out of the local transcript. It is an
            // opaque transport suffix for the first website submission only.
            let outbound = session.submitted ? prompt : "\(prompt)\n\nComputa session marker: \(session.firstUserMarker)"
            guard outbound.utf8.count <= 180_000 else { throw Failure.invalidRequest }
            let inserted = try await page(session, action: "insert", prompt: outbound)
            guard inserted["inserted"] as? Bool == true else { throw Failure.editorFailure("insertion_unconfirmed") }
            // Wait only through read-only checks. Site normalization can enable
            // Send later; insertion and the eventual click are never repeated.
            try await waitForSendReady(session, prompt: outbound)
            try Task.checkCancellation()
            session.response = ""
            session.completionCandidate = false
            session.candidateSince = nil
            session.lastChanged = .now
            session.turnStarted = .now
            // Claim submission before clicking: even a lost reply must not replay Send.
            session.submitted = true
            session.sequence += 1
            session.pendingSubmission = true
            session.state = "running"
            let sent = try await page(session, action: "submit", prompt: outbound)
            guard sent["submitted"] as? Bool == true else { throw Failure.editorFailure("submission_unconfirmed") }
            return try snapshot(session)
        default:
            return try await poll(session)
        }
    }

    func changeRevision(sessionToken: String) async throws -> UInt64? {
        guard let session = sessions[sessionToken] else { throw Failure.staleSession }
        return try browser.modelChangeRevision(for: session.tabID)
    }

    private func createSession(provider: Provider, choice: WebsiteModelChoice?, isDiscovery: Bool) throws -> Session {
        let admitted = sessions.values.filter { $0.isDiscovery == isDiscovery }.count
        guard admitted < (isDiscovery ? 1 : 4) else { throw Failure.capacity }
        guard script(for: provider) != nil else { throw Failure.pageUnavailable }
        let id = try createTab(provider.startURL)
        guard let view = browser.webView(for: id), let generation = browser.documentGeneration(for: id) else { throw Failure.staleSession }
        let session = Session(provider: provider, tabID: id, view: view, documentGeneration: generation,
                              modelChoice: choice, isDiscovery: isDiscovery)
        do { try browser.installModelChangeSignal(tabID: id, ownerToken: session.token, world: world, originHost: provider.host) }
        catch { browser.closeTab(id); throw error }
        sessions[session.token] = session
        return session
    }

    /// Read available choices on an empty owned page, without sending a prompt.
    func discoverModels(provider rawProvider: String) async throws -> [WebsiteModelChoice] {
        try Task.checkCancellation()
        guard let provider = Provider(rawValue: rawProvider) else { throw Failure.unsupportedProvider }
        let session = try createSession(provider: provider, choice: nil, isDiscovery: true)
        let token = session.token
        do {
            let deadline = session.created + preparationTimeout
            while session.state != "ready" {
                try Task.checkCancellation()
                let revision = try browser.modelChangeRevision(for: session.tabID)
                _ = try await poll(session)
                guard ContinuousClock.now < deadline else { throw Failure.preparationDeadline }
                if session.state != "ready" { _ = try await waitForChange(sessionToken: token, after: revision, until: deadline) }
            }
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let revision = try browser.modelChangeRevision(for: session.tabID)
                session.modelSelectionRequested = true
                let result = try await page(session, action: "discoverModels", maximumWait: min(.seconds(10), deadline - .now))
                if result["pending"] as? Bool != true {
                    guard let choices = result["modelChoices"] as? [[String: String]], !choices.isEmpty, choices.count <= 32 else { throw Failure.modelUnverified }
                    let parsed = try choices.map { choice -> WebsiteModelChoice in
                        guard Set(choice.keys) == ["key", "label"], let key = choice["key"], let label = choice["label"] else { throw Failure.modelUnverified }
                        let model = WebsiteModelChoice(provider: rawProvider, key: key, label: label)
                        guard model.isValid else { throw Failure.modelUnverified }
                        return model
                    }
                    guard Set(parsed.map(\.key)).count == parsed.count, Set(parsed.map(\.label)).count == parsed.count else { throw Failure.modelUnverified }
                    let cleanup = await finish(session, cancel: false)
                    guard let closed = try JSONSerialization.jsonObject(with: cleanup) as? [String: Any],
                          closed["cleanup"] as? String == "not_created" else { throw Failure.modelUnverified }
                    return parsed
                }
                _ = try await waitForChange(sessionToken: token, after: revision, until: deadline)
            }
            throw Failure.preparationDeadline
        } catch {
            let cleanup = await finish(session, cancel: true)
            guard let result = try? JSONSerialization.jsonObject(with: cleanup) as? [String: Any],
                  result["cleanup"] as? String == "not_created" else { throw Failure.discoveryCleanupFailed }
            throw error
        }
    }

    func waitForChange(sessionToken: String, after revision: UInt64,
                       until deadline: ContinuousClock.Instant) async throws -> UInt64? {
        guard let session = sessions[sessionToken] else { throw Failure.staleSession }
        var wake = deadline
        if session.state == "loading" { wake = min(wake, session.created + preparationTimeout) }
        else if session.state == "running" { wake = min(wake, session.turnStarted + responseTimeout) }
        if session.state == "running", session.completionCandidate, let since = session.candidateSince {
            wake = min(wake, max(since, session.lastChanged) + .milliseconds(1_600))
        }
        if let retry = session.initialReadRetry { wake = min(wake, retry) }
        return try await browser.waitForModelChange(tabID: session.tabID, after: revision, until: wake)
    }

    private func waitForSendReady(_ session: Session, prompt: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let remaining = deadline - .now
            guard remaining > .zero else { break }
            let revision = try browser.modelChangeRevision(for: session.tabID)
            let observed: [String: Any]
            do {
                observed = try await page(session, action: "sendReady", prompt: prompt, maximumWait: remaining)
            } catch {
                if ContinuousClock.now >= deadline, (error as? Failure) == .pageUnavailable {
                    throw Failure.editorFailure("send_unavailable")
                }
                throw error
            }
            guard ContinuousClock.now < deadline else { break }
            guard session.temporary, observed["temporary"] as? Bool == true else { throw Failure.temporaryUnverified }
            if observed["sendReady"] as? Bool == true { return }
            _ = try await browser.waitForModelChange(tabID: session.tabID, after: revision, until: deadline)
        }
        throw Failure.editorFailure("send_unavailable")
    }

    private func poll(_ session: Session) async throws -> Data {
        try Task.checkCancellation()
        guard ["loading", "running"].contains(session.state) else { return try snapshot(session) }
        if session.state == "loading", session.view.isLoading {
            session.initialReadRetry = nil
            guard ContinuousClock.now - session.created < preparationTimeout else { throw Failure.preparationDeadline }
            return try snapshot(session)
        }
        let timeoutFailure: Failure = session.state == "loading" ? .preparationDeadline : .deadline
        let deadline = session.state == "loading" ? session.created + preparationTimeout : session.turnStarted + responseTimeout
        guard ContinuousClock.now < deadline else { throw timeoutFailure }
        let observed: [String: Any]
        do { observed = try await page(session, action: "inspect", maximumWait: min(.seconds(10), deadline - .now)) }
        catch {
            if !Task.isCancelled, ContinuousClock.now >= deadline { throw timeoutFailure }
            if (error as? Failure) == .submissionObservationPending {
                try Task.checkCancellation()
                // The fixed adapter discarded a read crossed only by the
                // already-claimed submission's asynchronous user append. No
                // observation is admitted; the versioned DOM signal wakes a
                // fresh read which recomputes every ownership proof.
                return try snapshot(session)
            }
            // Retry only the initial read, before any mode toggle or submission.
            if session.state == "loading", !session.temporaryRequested, !session.modelSelectionRequested,
               !session.submitted, ContinuousClock.now - session.created < preparationTimeout,
               (error as? Failure) == .pageUnavailable, session.initialReadFailures < 3 {
                // Before the first observer exists, an inspection failure may
                // have no subsequent event. Only that failure gets a bounded retry.
                session.initialReadFailures += 1
                session.initialReadRetry = .now + .milliseconds(250)
                return try snapshot(session)
            }
            throw error
        }
        guard ContinuousClock.now < deadline else { throw timeoutFailure }
        session.initialReadRetry = nil
        logInspection(observed, session: session)
        if session.state == "loading" {
            guard count(observed, "responseCount") == 0, count(observed, "userCount") == 0,
                  session.provider.conversationURL(observed["url"] as? String) == nil else { throw Failure.notFresh }
            if observed["signIn"] as? Bool == true { throw Failure.signInRequired }
            if session.modelSelectionRequested, !session.modelSelectionVerified {
                // An owned model popup can make the already-verified temporary
                // controls or composer aria-hidden. Advance this claimed phase
                // so its adapter can close the popup. Only fresh checked model
                // proof and restored temporary mode can finish preparation.
                guard session.temporary, session.modelChoice != nil else { throw Failure.modelUnverified }
                let selected = try await page(session, action: "selectModel", maximumWait: min(.seconds(10), deadline - .now))
                if selected["pending"] as? Bool != true {
                    session.modelEvidence = try validatedModelEvidence(selected, session: session)
                    session.modelSelectionVerified = true
                    _ = try await page(session, action: "verifyModel", maximumWait: min(.seconds(10), deadline - .now))
                    session.state = "ready"
                }
            } else if observed["composer"] as? Bool == true {
                if observed["temporary"] as? Bool == true {
                    session.temporary = true
                    if let choice = session.modelChoice {
                        if let evidence = try? WebsiteModelEvidence.parse(observed["modelEvidence"], provider: session.provider.rawValue, expected: choice) {
                            session.modelEvidence = evidence
                            session.modelSelectionVerified = true
                            _ = try await page(session, action: "verifyModel", maximumWait: min(.seconds(10), deadline - .now))
                            session.state = "ready"
                        } else {
                            session.modelSelectionRequested = true
                            let selected = try await page(session, action: "selectModel", maximumWait: min(.seconds(10), deadline - .now))
                            if selected["pending"] as? Bool != true {
                                session.modelEvidence = try validatedModelEvidence(selected, session: session)
                                session.modelSelectionVerified = true
                                _ = try await page(session, action: "verifyModel", maximumWait: min(.seconds(10), deadline - .now))
                                session.state = "ready"
                            }
                        }
                    } else { session.state = "ready" }
                } else if !session.temporaryRequested, observed["temporaryActionAvailable"] as? Bool == true {
                    session.temporaryRequested = true
                    _ = try await page(session, action: "enableTemporary")
                }
            }
            guard session.state == "ready" || ContinuousClock.now - session.created < preparationTimeout else {
                throw Failure.preparationDeadline
            }
        } else {
            let previouslyCandidate = session.completionCandidate
            session.completionCandidate = false
            guard observed["temporary"] as? Bool == true else { throw Failure.temporaryUnverified }
            guard observed["interrupted"] as? Bool != true else { throw Failure.responseInterrupted }
            let response = observed["text"] as? String ?? ""
            guard response.utf8.count <= 220_000 else { throw Failure.responseTooLarge }
            if count(observed, "responseCount") > session.baseline,
               count(observed, "userCount") == session.sequence, !session.pendingSubmission, !response.isEmpty {
                if session.response != response {
                    session.response = response; session.lastChanged = .now; session.candidateSince = nil
                }
                if observed["busy"] as? Bool == false, observed["answerComplete"] as? Bool == true {
                    if !previouslyCandidate || session.candidateSince == nil { session.candidateSince = .now }
                    session.completionCandidate = true
                    if let since = session.candidateSince,
                       ContinuousClock.now - max(since, session.lastChanged) >= .milliseconds(1_600) { session.state = "complete" }
                }
            }
            if !session.completionCandidate { session.candidateSince = nil }
            guard session.state == "complete" || ContinuousClock.now - session.turnStarted < responseTimeout else {
                throw Failure.deadline
            }
        }
        return try snapshot(session)
    }

    private func logInspection(_ observed: [String: Any], session: Session) {
        if let raw = observed["quotaDiagnostic"] as? String {
            logQuotaDiagnostic(raw, session: session, action: "inspect")
        }
        let evidence = observed["completionEvidence"] as? [String: Any] ?? [:]
        let responseCount = count(observed, "responseCount")
        if observed["answerComplete"] as? Bool == true,
           session.loggedCodeSequence != session.sequence || session.loggedCodeResponseCount != responseCount,
           let structure = evidence["codeStructure"] as? [String: Any],
           let safe = Self.sanitizedCodeStructure(structure) {
            session.loggedCodeSequence = session.sequence
            session.loggedCodeResponseCount = responseCount
            Self.inspectionLog.info("codeStructure sequence=\(session.sequence) responses=\(responseCount) \(safe, privacy: .public)")
        }
        if let raw = observed["debugStructure"] as? String, raw.utf8.count <= 8_192,
           !session.loggedReadinessStages.contains(session.temporaryRequested),
           let safe = Self.sanitizedReadinessStructure(raw, provider: session.provider) {
            session.loggedReadinessStages.insert(session.temporaryRequested)
            Self.inspectionLog.info("readiness \(safe, privacy: .public)")
        }
        if !session.loggedStructure, count(observed, "responseCount") == 0 || count(observed, "userCount") == 0,
           let structure = observed["debugStructure"] as? String, !structure.isEmpty, structure.utf8.count <= 8_192,
           let metadata = try? JSONSerialization.jsonObject(with: Data(structure.utf8)) as? [String: Any],
           let copies = metadata["copies"] as? [[String: Any]], !copies.isEmpty {
            session.loggedStructure = true
            Self.inspectionLog.info("structure \(structure, privacy: .public)")
        }
        let signature = InspectionSignature(responses: count(observed, "responseCount"), users: count(observed, "userCount"),
            sequence: session.sequence, textBytes: (observed["text"] as? String ?? "").utf8.count,
            pending: session.pendingSubmission, busy: observed["busy"] as? Bool ?? false,
            answerComplete: observed["answerComplete"] as? Bool ?? false, ownershipPending: observed["ownershipPending"] as? Bool ?? false,
            composer: observed["composer"] as? Bool ?? false, temporary: observed["temporary"] as? Bool ?? false,
            temporaryActionAvailable: observed["temporaryActionAvailable"] as? Bool ?? false,
            modernMarkers: count(evidence, "modernMarkers"), logicalAnswers: count(evidence, "logicalAnswers"),
            scopedCopies: count(evidence, "scopedCopies"), enabledCopies: count(evidence, "enabledCopies"), depth: count(evidence, "depth"))
        guard signature != session.lastInspection else { return }
        session.lastInspection = signature
        Self.inspectionLog.info("inspection responses=\(signature.responses) users=\(signature.users) sequence=\(signature.sequence) pending=\(signature.pending) busy=\(signature.busy) answerComplete=\(signature.answerComplete) textBytes=\(signature.textBytes) ownershipPending=\(signature.ownershipPending) composer=\(signature.composer) temporary=\(signature.temporary) temporaryActionAvailable=\(signature.temporaryActionAvailable) modernMarkers=\(signature.modernMarkers) logicalAnswers=\(signature.logicalAnswers) scopedCopies=\(signature.scopedCopies) enabledCopies=\(signature.enabledCopies) depth=\(signature.depth)")
    }

    /// The fixed adapter's fresh quota receipt can pin an empty initial
    /// document for cleanup, without accepting readiness or message lineage.
    static func validFreshQuotaAbort(_ value: [String: Any], provider: Provider, expectedURL: URL, currentURL: URL) -> Bool {
        guard provider == .claude,
              Set(value.keys) == ["error", "freshQuotaAbort", "url", "userCount", "responseCount"],
              value["error"] as? String == "website_usage_limit",
              let receipt = value["freshQuotaAbort"] as? NSNumber,
              CFGetTypeID(receipt) == CFBooleanGetTypeID(), receipt.boolValue,
              let rawURL = value["url"] as? String, rawURL == expectedURL.absoluteString, rawURL == currentURL.absoluteString,
              provider.acceptsUnboundStart(currentURL) else { return false }
        for key in ["userCount", "responseCount"] {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == 0 else { return false }
        }
        return true
    }

    /// Diagnostic metadata has no authority. Project only bounded counts,
    /// booleans and selector names; never log arbitrary text, IDs or URLs.
    static func sanitizedQuotaStructure(_ raw: String, provider: Provider) -> String? {
        guard provider == .claude, raw.utf8.count <= 8_192,
              let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              value["kind"] as? String == "quota_structure", value["provider"] as? String == "claude" else { return nil }
        func boundedCount(_ source: [String: Any], _ key: String, limit: Int = 1_000) -> Int? {
            guard let number = source[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(limit),
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return number.intValue
        }
        func flag(_ source: [String: Any], _ key: String) -> Bool? {
            guard let number = source[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        func shape(_ source: [String: Any]) -> [String: Any]? {
            let tags = ["a", "button", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6", "p", "section", "main", "body", "html", "dialog", "other"]
            guard let tag = source["tag"] as? String,
                  let rectCount = boundedCount(source, "rectCount"),
                  let display = source["display"] as? String, ["none", "contents", "other"].contains(display),
                  let visibility = source["visibility"] as? String, ["visible", "hidden", "collapse", "other"].contains(visibility) else { return nil }
            var result: [String: Any] = ["tag": tags.contains(tag) ? tag : "other", "rectCount": rectCount,
                                         "display": display, "visibility": visibility]
            for key in ["strictVisible", "physicalVisible", "inertAncestor", "ariaHiddenAncestor"] {
                guard let boolean = flag(source, key) else { return nil }
                result[key] = boolean
            }
            return result
        }
        var safe: [String: Any] = ["kind": "quota_structure", "provider": "claude"]
        let sections: [(String, Int, [String], [String])] = [
            ("headings", 4, ["spacedClock", "joinedClock"], []),
            ("controls", 8, ["roleButton", "ariaLabelPresent", "ariaUpgradeExact", "ariaDismissExact",
                              "textUpgradeExact", "textDismissExact", "upgradeEdgePrivateUse", "dismissEdgePrivateUse", "hasUnknownLabelText"], ["privateUseCount"]),
            ("popupAncestors", 8, ["containsMessages"], ["depth", "buttonCount", "roleButtonCount", "anchorCount", "upgradeExactCount", "dismissExactCount"]),
            ("support", 4, ["labelExact", "labelKnownSuffix"], []),
            ("bannerParents", 4, ["spacedClock", "joinedClock", "supportDirect"], []),
        ]
        for (key, limit, flags, counts) in sections {
            guard let nodes = value[key] as? [[String: Any]], nodes.count <= limit else { return nil }
            var projected: [[String: Any]] = []
            for node in nodes {
                guard var result = shape(node) else { return nil }
                for name in flags {
                    guard let boolean = flag(node, name) else { return nil }
                    result[name] = boolean
                }
                for name in counts {
                    guard let count = boundedCount(node, name, limit: name == "depth" ? 7 : 1_000) else { return nil }
                    result[name] = count
                }
                if key == "bannerParents" {
                    guard let children = node["children"] as? [String], children.count <= 8,
                          children.allSatisfy({ ["text", "support", "element", "other"].contains($0) }) else { return nil }
                    result["children"] = children
                }
                projected.append(result)
            }
            safe[key] = projected
        }
        guard let mode = value["mode"] as? [String: Any] else { return nil }
        var counts: [String: Int] = [:]
        for key in ["headerTotal", "headerVisible", "headerPhysical", "exitTotal", "exitVisible", "exitPhysical"] {
            guard let count = boundedCount(mode, key) else { return nil }
            counts[key] = count
        }
        safe["mode"] = counts
        guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), bytes.count <= 8_192 else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func quotaStructureDiagnosticRecords(_ raw: String, provider: Provider) -> [String]? {
        guard let safe = sanitizedQuotaStructure(raw, provider: provider),
              var summary = try? JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any] else { return nil }
        var records: [[String: Any]] = []
        for section in ["headings", "controls", "popupAncestors", "support", "bannerParents"] {
            let nodes = summary.removeValue(forKey: section) as? [[String: Any]] ?? []
            records += nodes.enumerated().map { ["section": section, "index": $0.offset, "node": $0.element] }
        }
        var result: [String] = []
        for record in [summary] + records {
            guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys), bytes.count <= 960 else { return nil }
            result.append(String(decoding: bytes, as: UTF8.self))
        }
        return result
    }

    private func logQuotaDiagnostic(_ raw: String, session: Session, action: String, force: Bool = false) {
        guard let records = Self.quotaStructureDiagnosticRecords(raw, provider: session.provider),
              force || session.lastQuotaDiagnostic != records else { return }
        session.lastQuotaDiagnostic = records
        for (index, record) in records.enumerated() {
            Self.inspectionLog.error("quotaStructure action=\(action) sequence=\(session.sequence) index=\(index) \(record, privacy: .public)")
        }
    }

    static func sanitizedReadinessStructure(_ raw: String, provider: Provider) -> String? {
        guard raw.utf8.count <= 8_192,
              let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              value["kind"] as? String == "provider_readiness", value["provider"] as? String == provider.rawValue else { return nil }
        func node(_ source: [String: Any], descendants: Bool) -> [String: Any]? {
            guard let tag = source["tag"] as? String,
                  tag.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil,
                  let classes = source["classes"] as? [String], classes.count <= 6,
                  classes.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_-]{1,48}$"#, options: .regularExpression) != nil }),
                  let length = source["textLength"] as? Int, (0...220_001).contains(length) else { return nil }
            var safe: [String: Any] = ["tag": tag, "classes": classes, "textLength": length]
            for key in ["visible", "excluded", "initialExact", "activeExact", "initialTitle", "initialContained", "activeContained", "supportLink", "noHistory"] {
                if let flag = source[key] as? Bool { safe[key] = flag }
            }
            if descendants, let leaves = source["exactDescendants"] as? [[String: Any]] {
                guard leaves.count <= 4 else { return nil }
                let projected = leaves.compactMap { node($0, descendants: false) }
                guard projected.count == leaves.count else { return nil }
                safe["exactDescendants"] = projected
            }
            return safe
        }
        guard let nodes = value["nodes"] as? [[String: Any]], nodes.count <= 12 else { return nil }
        let projected = nodes.compactMap { node($0, descendants: true) }
        guard projected.count == nodes.count else { return nil }
        var safe: [String: Any] = ["kind": "provider_readiness", "provider": provider.rawValue, "nodes": projected]
        for key in ["composer", "toggle", "exit"] {
            guard let counts = value[key] as? [String: Any] else { return nil }
            var bounded: [String: Int] = [:]
            for name in ["total", "visible", "enabled"] {
                guard let count = counts[name] as? Int, (0...1_000).contains(count) else { return nil }
                bounded[name] = count
            }
            safe[key] = bounded
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), bytes.count <= 8_192 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func sanitizedCodeStructure(_ source: [String: Any]) -> String? {
        var safe: [String: Any] = [:]
        for key in ["preCount", "codeCount", "codeTextLength", "outsideTextLength"] {
            let limit = key.hasSuffix("Length") ? 220_001 : 1_000
            guard let count = source[key] as? Int, (0...limit).contains(count) else { return nil }
            safe[key] = count
        }
        guard let truncated = source["outsideTruncated"] as? Bool,
              let tags = source["preParentTags"] as? [String], tags.count <= 3,
              tags.allSatisfy({ $0.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil }) else { return nil }
        safe["outsideTruncated"] = truncated
        safe["preParentTags"] = tags
        if let nodes = source["outsideNodes"] as? [[String: Any]] {
            guard nodes.count <= 4 else { return nil }
            var projected: [[String: Any]] = []
            for node in nodes {
                guard let kind = node["kind"] as? String, ["json", "private_use", "other"].contains(kind),
                      let length = node["textLength"] as? Int, (0...220_001).contains(length),
                      let ancestors = node["ancestors"] as? [[String: Any]], ancestors.count <= 4 else { return nil }
                var parents: [[String: Any]] = []
                for parent in ancestors {
                    guard let tag = parent["tag"] as? String,
                          tag.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil,
                          let classes = parent["classes"] as? [String], classes.count <= 6,
                          classes.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_-]{1,48}$"#, options: .regularExpression) != nil }),
                          let pres = parent["preDescendants"] as? Int, (0...1_000).contains(pres),
                          let copies = parent["copyControls"] as? Int, (0...1_000).contains(copies) else { return nil }
                    parents.append(["tag": tag, "classes": classes, "preDescendants": pres, "copyControls": copies])
                }
                projected.append(["kind": kind, "textLength": length, "ancestors": parents])
            }
            safe["outsideNodes"] = projected
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), bytes.count <= 8_192 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func sanitizedFirstUserStructure(_ raw: String, provider: Provider) -> String? {
        guard raw.utf8.count <= 8_192,
              let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              value["kind"] as? String == "first_user_structure", value["provider"] as? String == provider.rawValue else { return nil }
        let tags: Set<String> = ["none", "div", "span", "p", "pre", "code", "button", "section", "article", "user-query", "a", "strong", "em", "ol", "ul", "li", "br", "input", "textarea", "mat-icon"]
        let utilityClasses: Set<String> = ["ng-star-inserted", "cdk-visually-hidden", "hidden", "invisible", "truncate", "overflow-hidden", "whitespace-pre-wrap"]
        let sitePrefixes = ["query-", "user-query-", "gds-", "mat-", "cdk-", "ng-"]
        func shape(_ source: [String: Any], discovery: Bool = false) -> [String: Any]? {
            guard let tag = source["tag"] as? String,
                  tag.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil,
                  let classes = source["classes"] as? [String], classes.count <= 6,
                  classes.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_-]{1,48}$"#, options: .regularExpression) != nil }) else { return nil }
            let safeClasses = classes.filter { token in
                utilityClasses.contains(token) || discovery && sitePrefixes.contains { token.hasPrefix($0) }
            }
            return ["tag": tags.contains(tag) ? tag : "other", "classes": safeClasses]
        }
        guard let root = value["root"] as? [String: Any], let safeRoot = shape(root),
              let body = value["body"] as? [String: Any], let safeBody = shape(body) else { return nil }
        var safe: [String: Any] = ["kind": "first_user_structure", "provider": provider.rawValue, "root": safeRoot, "body": safeBody]
        for key in ["userCount", "textLength", "lineCount", "markerOccurrences", "controlDescendants"] {
            let limit = key == "textLength" || key == "lineCount" ? 220_001 : 1_000
            guard let count = value[key] as? Int, (0...limit).contains(count) else { return nil }
            safe[key] = count
        }
        for key in ["markerFinalLine", "submitted", "markerMatches"] {
            guard let flag = value[key] as? Bool else { return nil }
            safe[key] = flag
        }
        if let rawReason = value["reason"] {
            let reasons: Set<String> = ["first_bound", "marker_invalid", "submission_unclaimed", "marker_mismatch", "body_limit", "marker_not_final", "marker_duplicate", "body_empty", "snapshot_before_action", "pinned_fingerprint", "native_fingerprint", "binding_not_authorized", "first_missing", "snapshot_after_action", "first_insert", "first_submit"]
            guard let reason = rawReason as? String, reasons.contains(reason) else { return nil }
            safe["reason"] = reason
        }
        for key in ["pinnedFingerprintMatch", "nativeFingerprintMatch"] {
            if let rawFlag = value[key] {
                guard let flag = rawFlag as? Bool else { return nil }
                safe[key] = flag
            }
        }
        if let rawSnapshot = value["snapshot"] {
            guard let snapshot = rawSnapshot as? [String: Any] else { return nil }
            var projected: [String: Bool] = [:]
            for key in ["rootSame", "bodySame", "bodyConnected", "textSame", "countSame", "urlSame", "originSame", "ownerSame"] {
                guard let flag = snapshot[key] as? Bool else { return nil }
                projected[key] = flag
            }
            safe["snapshot"] = projected
        }
        if let rawDescendants = value["descendants"] {
            guard let descendants = rawDescendants as? [[String: Any]], descendants.count <= 16 else { return nil }
            var projected: [[String: Any]] = []
            for node in descendants {
                guard var child = shape(node, discovery: true), let path = node["path"] as? [Int],
                      path.count <= 16, path.allSatisfy({ (0...1_000).contains($0) }) else { return nil }
                child["path"] = path
                for key in ["childElements", "controls", "textLength"] {
                    guard let count = node[key] as? Int, (0...(key == "textLength" ? 220_001 : 1_000)).contains(count) else { return nil }
                    child[key] = count
                }
                for key in ["markerExact", "markerContained", "visible", "editable"] {
                    guard let flag = node[key] as? Bool else { return nil }
                    child[key] = flag
                }
                projected.append(child)
            }
            safe["descendants"] = projected
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), bytes.count <= 8_192 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// Keep each already-sanitized record below unified logging's message cap.
    static func firstUserStructureDiagnosticRecords(_ raw: String, provider: Provider, expectedReason: String? = nil) -> [String]? {
        guard let safe = sanitizedFirstUserStructure(raw, provider: provider),
              var summary = try? JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any] else { return nil }
        if let expectedReason, summary["reason"] as? String != expectedReason { return nil }
        let children = summary.removeValue(forKey: "descendants") as? [[String: Any]] ?? []
        var records: [String] = []
        for value in [summary] + children {
            guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys), bytes.count <= 960 else { return nil }
            records.append(String(decoding: bytes, as: UTF8.self))
        }
        return records
    }

    private func logFirstUserStructure(_ records: [String], sequence: Int) {
        for (index, safe) in records.enumerated() {
            if index == 0 { Self.inspectionLog.info("firstUserStructure sequence=\(sequence) \(safe, privacy: .public)") }
            else { Self.inspectionLog.info("firstUserChild sequence=\(sequence) index=\(index - 1) \(safe, privacy: .public)") }
        }
    }

    static func insertionDifferenceDiagnostic(_ observed: [String: Any]) -> String? {
        guard let index = observed["firstDifference"] as? Int, (0...360_000).contains(index) else { return nil }
        func scalar(_ key: String) -> String? {
            if observed[key] is NSNull { return "end" }
            guard let value = observed[key] as? Int, (0...0x10FFFF).contains(value), !(0xD800...0xDFFF).contains(value) else { return nil }
            return String(value)
        }
        guard let actual = scalar("actualScalar"), let expected = scalar("expectedScalar") else { return nil }
        return "; first difference \(index); actual/expected scalars \(actual)/\(expected)"
    }

    private func page(_ session: Session, action: String, prompt: String? = nil, enforceModel: Bool = true,
                      refreshChangedRoute: Bool = true, recheckModelAfterAwait: Bool = true,
                      refreshReadOnlyObservation: Bool = true,
                      maximumWait: Duration = .seconds(10)) async throws -> [String: Any] {
        guard browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
        guard let generation = browser.documentGeneration(for: session.tabID),
              session.documentGeneration == nil || session.documentGeneration == generation else {
            throw Failure.ownershipFailure(.documentGenerationBefore)
        }
        let provider = session.provider
        guard let script = script(for: provider) else { throw Failure.pageUnavailable }
        guard let url = session.view.url, provider.accepts(url.absoluteString) else {
            // This can precede JavaScript execution after a failed navigation.
            // Record classifications only, without publishing the page URL.
            let candidate = session.view.url
            Self.inspectionLog.error("adapterContextUnavailable provider=\(provider.rawValue, privacy: .public) action=\(action, privacy: .public) sequence=\(session.sequence) urlPresent=\(candidate != nil) https=\(candidate?.scheme == "https") hostMatches=\(candidate?.host == provider.host) loading=\(session.view.isLoading)")
            throw Failure.pageUnavailable
        }
        let context = provider.routeContext(url.absoluteString)
        if let pinned = session.routeContext, context != pinned { throw Failure.ownershipFailure(.routeBefore) }
        let current = provider.conversationURL(url.absoluteString)
        let promotion = provider.isLocalConversation(session.conversation) && current != nil
            && current != session.conversation && !provider.isLocalConversation(current) && !session.promoted
        if let owned = session.conversation, current != owned, !promotion { throw Failure.ownershipFailure(.routeBefore) }
        if current != nil, !session.submitted { throw Failure.notFresh }
        let expectedCounts: [Int] = action == "submit" ? [session.confirmedUsers]
            : session.pendingSubmission ? [session.confirmedUsers, session.sequence] : [session.confirmedUsers]
        var input: [String: Any] = [
            "provider": provider.rawValue, "action": action, "expectedURL": url.absoluteString,
            "ownerToken": session.token, "bindOwner": session.state == "loading" && !session.submitted,
            "expectedUserCounts": expectedCounts,
            "expectedFirstUserMarker": session.firstUserMarker,
            "allowFirstUserBinding": action == "inspect" && session.sequence == 1
                && session.pendingSubmission && session.firstUserFingerprint == nil,
        ]
        if let choice = session.modelChoice {
            if action == "selectModel" { input["modelChoice"] = ["key": choice.key, "label": choice.label] }
            if enforceModel, session.modelSelectionVerified, !["stop", "cleanup", "discoverModels"].contains(action) {
                input["expectedModelChoice"] = ["key": choice.key, "label": choice.label]
            }
        }
        if let fingerprint = session.firstUserFingerprint { input["expectedFirstUserFingerprint"] = fingerprint }
        if let conversation = session.conversation, !promotion { input["expectedConversation"] = conversation }
        // Website selection IDs can change during ordinary re-rendering.
        // Authority comes from generation, private owner, pinned route, counts
        // and pinned first-message lineage; an auxiliary ID cannot veto it.
        if let prompt { input["prompt"] = prompt }
        browser.captureModelNativeFocus(tabID: session.tabID)
        defer { browser.restoreModelNativeFocus(tabID: session.tabID) }
        let result = EmbeddedScriptResult()
        let bytes: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                let timeout = Task {
                    do {
                        try await Task.sleep(for: maximumWait)
                        Self.inspectionLog.error("adapterTimeout provider=\(provider.rawValue, privacy: .public) action=\(action, privacy: .public) sequence=\(session.sequence)")
                        result.complete(.failure(Failure.pageUnavailable))
                    } catch { }
                }
                result.setTimeout(timeout)
                guard result.isPending else { return }
                session.view.callAsyncJavaScript(script, arguments: ["input": input], in: nil, in: world) { reply in
                    switch reply {
                    case .success(let value):
                        do { result.complete(.success(try JSONSerialization.data(withJSONObject: value))) }
                        catch {
                            Self.inspectionLog.error("adapterResultInvalid provider=\(provider.rawValue, privacy: .public) action=\(action, privacy: .public) sequence=\(session.sequence)")
                            result.complete(.failure(Failure.pageUnavailable))
                        }
                    case .failure(let error):
                        let native = error as NSError
                        let message = native.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
                        let kind = ["TypeError", "ReferenceError", "SyntaxError", "RangeError"].first {
                            message.hasPrefix($0 + ":")
                        } ?? "unknown"
                        let rawLine = native.userInfo["WKJavaScriptExceptionLineNumber"] as? Int ?? -1
                        let rawColumn = native.userInfo["WKJavaScriptExceptionColumnNumber"] as? Int ?? -1
                        let line = (0...999_999).contains(rawLine) ? rawLine : -1
                        let column = (0...99_999).contains(rawColumn) ? rawColumn : -1
                        // Log finite categories and source positions only.
                        // Exception messages can contain page or prompt data.
                        Self.inspectionLog.error("adapterFailure provider=\(provider.rawValue, privacy: .public) action=\(action, privacy: .public) code=\(native.code) kind=\(kind, privacy: .public) line=\(line) column=\(column)")
                        result.complete(.failure(Failure.pageUnavailable))
                    }
                }
            }
        } onCancel: { result.complete(.failure(CancellationError())) }
        #if DEBUG
        await beforePageResultValidationForTesting?(action)
        #endif
        guard browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
        guard browser.documentGeneration(for: session.tabID) == generation else {
            // Readiness may redirect before any document has been bound. Discard
            // this obsolete read; subsequent reads may bind the final ready page.
            if session.documentGeneration == nil, session.state == "loading",
               !session.temporaryRequested, !session.submitted { throw Failure.pageUnavailable }
            throw Failure.ownershipFailure(.documentGenerationAfter)
        }
        guard let currentURL = session.view.url, provider.accepts(currentURL.absoluteString) else {
            throw Failure.ownershipFailure(.routeAfter)
        }
        let currentContext = provider.routeContext(currentURL.absoluteString)
        if currentContext != context || session.routeContext != nil && session.routeContext != currentContext {
            if session.documentGeneration == nil, session.state == "loading", action == "inspect",
               !session.temporaryRequested, !session.submitted { throw Failure.pageUnavailable }
            throw Failure.ownershipFailure(.routeAfter)
        }
        if currentURL != url {
            let nextConversation = provider.conversationURL(currentURL.absoluteString)
            let firstConversation = session.submitted && session.sequence == 1 && session.conversation == nil
                && nextConversation != nil && (current == nil || provider.isLocalConversation(current)
                    && !provider.isLocalConversation(nextConversation))
            let promotedConversation = provider.isLocalConversation(session.conversation)
                && nextConversation != nil && nextConversation != session.conversation
                && !provider.isLocalConversation(nextConversation) && !session.promoted
            Self.inspectionLog.info("routeTransition provider=\(provider.rawValue, privacy: .public) action=\(action, privacy: .public) sequence=\(session.sequence) submitted=\(session.submitted) oldConversation=\(current != nil) newConversation=\(nextConversation != nil) oldLocal=\(provider.isLocalConversation(current)) newLocal=\(provider.isLocalConversation(nextConversation)) refresh=\(refreshChangedRoute) first=\(firstConversation) promotion=\(promotedConversation)")
            if ["inspect", "verifyModel"].contains(action), refreshChangedRoute, firstConversation || promotedConversation {
                // Discard every crossed read. ChatGPT can create a local route
                // and promote it during the next read before either result can
                // bind the conversation. Only that first empty-to-local edge
                // leaves one refresh for its monotonic public promotion. The
                // predicates above reject another local or public conversation.
                let awaitingLocalPromotion = firstConversation && current == nil
                    && provider.isLocalConversation(nextConversation)
                return try await page(session, action: "inspect", enforceModel: enforceModel,
                                      refreshChangedRoute: awaitingLocalPromotion, recheckModelAfterAwait: recheckModelAfterAwait,
                                      refreshReadOnlyObservation: refreshReadOnlyObservation,
                                      maximumWait: maximumWait)
            }
            let temporaryToggle = action == "enableTemporary" && session.state == "loading"
                && !session.submitted && current == nil && nextConversation == nil
                && provider.acceptsTemporaryToggle(currentURL)
            // Send can synchronously create the first SPA route before its
            // acknowledgment returns. The next poll verifies its conversation.
            guard action == "submit" && firstConversation || temporaryToggle else { throw Failure.ownershipFailure(.routeAfter) }
        }
        guard let observed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.pageUnavailable }
        logModelDiagnostic(observed, session: session)
        if let error = observed["error"] as? String {
            if ["temporary_mode_unavailable", "temporary_mode_unverified"].contains(error),
               let raw = observed["quotaDiagnostic"] as? String {
                logQuotaDiagnostic(raw, session: session, action: action, force: true)
            }
            if error == "prompt_not_inserted", let detail = observed["detail"] as? String,
               ["editor_empty", "line_break_expansion", "nonbreaking_spaces", "text_difference"].contains(detail),
               let actual = observed["actualLength"] as? Int, let expected = observed["expectedLength"] as? Int,
               let actualLines = observed["actualLines"] as? Int, let expectedLines = observed["expectedLines"] as? Int,
               [actual, expected, actualLines, expectedLines].allSatisfy({ (0...360_000).contains($0) }) {
                let difference = Self.insertionDifferenceDiagnostic(observed) ?? ""
                throw Failure.editorFailure("\(detail); \(actual)/\(expected) characters; \(actualLines)/\(expectedLines) lines\(difference)")
            }
            switch error {
            case "model_unverified": throw Failure.modelUnverified
            case "model_mismatch": throw Failure.modelMismatch
            case "model_unavailable": throw Failure.modelUnavailable
            case "acknowledged_user_append":
                // A read-only picker observation can cross the DOM append for
                // our already acknowledged Send. Discard that observation and
                // inspect once from the current page, including the exact first
                // marker/fingerprint checks. Never replay an editor operation.
                guard refreshReadOnlyObservation, ["inspect", "verifyModel"].contains(action),
                      observed["detail"] as? String == "readonly_model_observation",
                      session.submitted, session.pendingSubmission,
                      session.confirmedUsers + 1 == session.sequence else {
                    throw Failure.ownershipFailure(.javaScriptUserCount)
                }
                return try await page(session, action: "inspect", enforceModel: enforceModel,
                                      refreshChangedRoute: false, recheckModelAfterAwait: recheckModelAfterAwait,
                                      refreshReadOnlyObservation: false, maximumWait: maximumWait)
            case "first_user_observation_replaced":
                // Provider frameworks can replace an unchanged message while
                // its model picker is being read. The adapter only signals a
                // discard after checking both pinned hashes and the exact
                // marker on the disconnected node's replacement. Admit nothing
                // from that read; use the same one-inspect budget as an append.
                guard refreshReadOnlyObservation, ["inspect", "verifyModel"].contains(action),
                      observed["detail"] as? String == "readonly_model_observation",
                      session.submitted, session.firstUserFingerprint != nil else {
                    throw Failure.ownershipFailure(.javaScriptFirstUser)
                }
                return try await page(session, action: "inspect", enforceModel: enforceModel,
                                      refreshChangedRoute: false, recheckModelAfterAwait: recheckModelAfterAwait,
                                      refreshReadOnlyObservation: false, maximumWait: maximumWait)
            case "document_changed", "conversation_changed":
                if observed["detail"] as? String == "first_user_message",
                   let raw = observed["debugStructure"] as? String,
                   let records = Self.firstUserStructureDiagnosticRecords(raw, provider: provider) {
                    logFirstUserStructure(records, sequence: session.sequence)
                }
                let allowedDetails: [String: OwnershipReason] = [
                    "owner_token": .javaScriptOwner, "user_count": .javaScriptUserCount,
                    "conversation_identity": .javaScriptConversationIdentity, "document_url": .javaScriptURL,
                    "conversation_route": .javaScriptConversationRoute, "first_user_message": .javaScriptFirstUser,
                ]
                let detail = (observed["detail"] as? String).flatMap { allowedDetails[$0] }
                throw Failure.ownershipFailure(detail ?? (error == "document_changed" ? .javaScriptDocument : .javaScriptConversation))
            case "sign_in_required": throw Failure.signInRequired
            case "website_usage_limit":
                if action == "inspect", session.state == "loading", session.documentGeneration == nil,
                   session.sequence == 0, session.confirmedUsers == 0,
                   !session.submitted, !session.pendingSubmission, !session.temporaryRequested, !session.temporary,
                   session.firstUserFingerprint == nil,
                   Self.validFreshQuotaAbort(observed, provider: provider, expectedURL: url, currentURL: currentURL) {
                    // The fixed adapter proved an untouched, empty fresh page
                    // after its initial commit. Pin only that document for
                    // cleanup; quota cannot establish readiness or lineage.
                    session.documentGeneration = generation
                    session.routeContext = currentContext
                }
                throw Failure.usageLimited(provider)
            case "submission_observation_pending":
                guard provider == .gemini, action == "inspect", session.state == "running",
                      session.submitted, session.pendingSubmission, session.firstUserFingerprint != nil,
                      session.confirmedUsers + 1 == session.sequence else {
                    throw Failure.ownershipFailure(.javaScriptUserCount)
                }
                throw Failure.submissionObservationPending
            case "not_fresh": throw Failure.notFresh
            case "temporary_mode_unavailable", "temporary_mode_unverified": throw Failure.temporaryUnverified
            case "composer_unavailable", "composer_not_empty", "prompt_not_inserted", "send_unavailable", "caret_unavailable", "insert_command_rejected": throw Failure.editorFailure(error)
            default: throw Failure.composerUnavailable
            }
        }
        // Submit returns only its acknowledgment; observations carry ownership state.
        if let observedURL = observed["url"] as? String {
            guard provider.accepts(observedURL), provider.routeContext(observedURL) == currentContext else { throw Failure.documentChanged }
            if session.documentGeneration == nil { session.documentGeneration = generation }
            if session.routeContext == nil { session.routeContext = currentContext }
            session.observedResponseCount = count(observed, "responseCount")
            if count(observed, "userCount") > 0 {
                guard observed["firstUserVerified"] as? Bool == true,
                      observed["firstUserMarkerVerified"] as? Bool == true,
                      let fingerprint = observed["firstUserFingerprint"] as? String,
                      fingerprint.count == 64, fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                    throw Failure.ownershipFailure(.javaScriptFirstUser)
                }
                if let pinned = session.firstUserFingerprint {
                    guard fingerprint == pinned else { throw Failure.ownershipFailure(.javaScriptFirstUser) }
                } else {
                    guard action == "inspect", session.sequence == 1, session.pendingSubmission,
                          count(observed, "userCount") == 1,
                          session.temporary, observed["temporary"] as? Bool == true else {
                        throw Failure.ownershipFailure(.javaScriptFirstUser)
                    }
                    session.firstUserFingerprint = fingerprint
                    if !session.loggedFirstUserStructure,
                       let raw = observed["debugStructure"] as? String,
                       let records = Self.firstUserStructureDiagnosticRecords(raw, provider: provider, expectedReason: "first_bound") {
                        session.loggedFirstUserStructure = true
                        logFirstUserStructure(records, sequence: session.sequence)
                    }
                }
            }
            if action == "inspect", session.pendingSubmission, count(observed, "userCount") == 0 {
                try await verifyModelEvidenceAfterAwait(observed, session: session, action: action,
                                                       enforceModel: enforceModel, recheck: recheckModelAfterAwait,
                                                       refreshChangedRoute: refreshChangedRoute,
                                                       refreshReadOnlyObservation: refreshReadOnlyObservation,
                                                       maximumWait: maximumWait)
                if !promotion, session.conversation == nil, let conversation = provider.conversationURL(observedURL) {
                    // Preserve the initial route pin while waiting for render;
                    // a later promotion still requires the first-message proof.
                    session.conversation = conversation
                }
                // Neither answers nor cleanup can be admitted before the
                // submitted first message has established owned lineage.
                var pending: [String: Any] = ["temporary": observed["temporary"] as? Bool ?? false,
                        "userCount": 0, "responseCount": session.baseline, "text": "", "busy": true,
                        "answerComplete": false, "ownershipPending": true,
                        "debugStructure": observed["debugStructure"] as? String ?? ""]
                if let evidence = session.modelEvidence { pending["modelEvidence"] = evidence.dictionary }
                return pending
            }
            if promotion {
                guard session.temporary, observed["temporary"] as? Bool == true else {
                    throw Failure.ownershipFailure(.promotionTemporary)
                }
                guard observed["firstUserVerified"] as? Bool == true else {
                    throw Failure.ownershipFailure(.promotionFirstUser)
                }
                session.conversation = provider.conversationURL(observedURL)
                // Selection IDs are auxiliary rendering metadata. The private
                // world, pinned first-message lineage, generation and one-time route
                // promotion carry authority even while these IDs are absent.
                if let identity = observed["conversationIdentity"] as? String,
                   !identity.isEmpty, identity.utf8.count <= 256 {
                    session.conversationIdentity = identity
                } else {
                    session.conversationIdentity = nil
                }
                session.promoted = true
            } else if session.conversation == nil, let conversation = provider.conversationURL(observedURL) {
                guard session.submitted else { throw Failure.notFresh }
                session.conversation = conversation
            }
            if count(observed, "userCount") > 0, session.conversationIdentity == nil,
               let identity = observed["conversationIdentity"] as? String,
               !identity.isEmpty, identity.utf8.count <= 256 { session.conversationIdentity = identity }
            if session.pendingSubmission, count(observed, "userCount") == session.sequence {
                session.confirmedUsers = session.sequence
                session.pendingSubmission = false
            }
        }
        try await verifyModelEvidenceAfterAwait(observed, session: session, action: action,
                                               enforceModel: enforceModel, recheck: recheckModelAfterAwait,
                                               refreshChangedRoute: refreshChangedRoute,
                                               refreshReadOnlyObservation: refreshReadOnlyObservation,
                                               maximumWait: maximumWait)
        return observed
    }

    private func verifyModelEvidenceAfterAwait(_ observed: [String: Any], session: Session, action: String,
                                              enforceModel: Bool, recheck: Bool, refreshChangedRoute: Bool,
                                              refreshReadOnlyObservation: Bool,
                                              maximumWait: Duration) async throws {
        if enforceModel, session.modelSelectionVerified, !["stop", "cleanup", "discoverModels"].contains(action) {
            let evidence = try validatedModelEvidence(observed, session: session)
            // A native await can cross a model change without navigation. Read
            // the fixed proof again, rather than accepting the earlier result.
            if recheck, action != "verifyModel" {
                // The first Send can render its user message before native
                // acknowledges it. Only inspect may bind that exact lineage;
                // a fresh model-only read cannot acquire an unbound message.
                let freshAction = session.pendingSubmission && session.firstUserFingerprint == nil ? "inspect" : "verifyModel"
                let fresh = try await page(session, action: freshAction, enforceModel: enforceModel,
                                           refreshChangedRoute: refreshChangedRoute, recheckModelAfterAwait: false,
                                           refreshReadOnlyObservation: refreshReadOnlyObservation,
                                           maximumWait: maximumWait)
                let currentEvidence = try validatedModelEvidence(fresh, session: session)
                guard evidence.selected == currentEvidence.selected else { throw Failure.modelMismatch }
            }
            session.modelEvidence = evidence
        }
    }

    private func validatedModelEvidence(_ observation: [String: Any], session: Session) throws -> WebsiteModelEvidence {
        do { return try WebsiteModelEvidence.parse(observation["modelEvidence"], provider: session.provider.rawValue, expected: session.modelChoice) }
        catch WebsiteModelEvidence.Failure.mismatch { throw Failure.modelMismatch }
        catch { throw Failure.modelUnverified }
    }

    private func logModelDiagnostic(_ observation: [String: Any], session: Session) {
        guard let value = observation["modelDiagnostic"], JSONSerialization.isValidJSONObject(value),
              let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), bytes.count <= 16_384 else { return }
        let line = String(decoding: bytes, as: UTF8.self)
        guard line != session.lastModelDiagnostic else { return }
        session.lastModelDiagnostic = line
        // Unified Logging truncates long interpolated strings. Small numbered
        // byte chunks preserve the bounded sanitized JSON without publishing
        // page, prompt or response text.
        let identifier = UUID().uuidString
        let chunks = stride(from: 0, to: bytes.count, by: 512).map { offset in
            bytes.subdata(in: offset..<min(offset + 512, bytes.count)).base64EncodedString()
        }
        for (index, chunk) in chunks.enumerated() {
            Self.inspectionLog.info("modelDiagnostic provider=\(session.provider.rawValue, privacy: .public) id=\(identifier, privacy: .public) part=\(index + 1)/\(chunks.count) base64=\(chunk, privacy: .public)")
        }
    }

    private func finish(_ session: Session, cancel: Bool) async -> Data {
        do {
            if session.isDiscovery {
                // Discovery cannot Send and its private view cannot be adopted
                // by a human tab. Close exactly this read-only view even after
                // a sign-in redirect; inference cleanup authority is unchanged.
                guard !session.submitted, browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
            } else if session.submitted || session.temporaryRequested || session.temporary {
                let observed: [String: Any]
                do { observed = try await page(session, action: "inspect", enforceModel: false) }
                catch {
                    guard let failure = error as? Failure, case .usageLimited(let provider) = failure,
                          provider == session.provider, session.submitted, session.firstUserFingerprint != nil else { throw error }
                    // Only the fixed adapter's exact quota modal can expose
                    // physical temporary indicators for cleanup. The ordinary
                    // first-message and session proofs remain mandatory.
                    observed = try await page(session, action: "stop")
                    guard observed["usageLimited"] as? Bool == true, observed["busy"] as? Bool == false else {
                        throw Failure.temporaryUnverified
                    }
                }
                guard observed["ownershipPending"] as? Bool != true else {
                    throw Failure.ownershipFailure(.promotionFirstUser)
                }
                if session.submitted {
                    guard session.temporary, observed["temporary"] as? Bool == true else { throw Failure.temporaryUnverified }
                    if cancel, observed["busy"] as? Bool == true { _ = try await page(session, action: "stop") }
                } else {
                    guard count(observed, "userCount") == 0, count(observed, "responseCount") == 0 else { throw Failure.notFresh }
                }
            } else {
                guard browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
                let ownedGeneration = session.documentGeneration ?? session.initialDocumentGeneration
                guard browser.documentGeneration(for: session.tabID) == ownedGeneration else {
                    throw Failure.ownershipFailure(.unboundCleanup)
                }
                if let url = session.view.url {
                    guard session.provider.acceptsUnboundStart(url) else {
                        throw Failure.ownershipFailure(.unboundCleanup)
                    }
                }
            }
            browser.closeTab(session.tabID)
            sessions.removeValue(forKey: session.token)
            session.state = "finished"
            return try snapshot(session, cleanup: "not_created")
        } catch {
            // Retain the exact owned tab for inspection/retry; never erase a human chat.
            return (try? snapshot(session, cleanup: "failed")) ?? Data("{}".utf8)
        }
    }

    private func snapshot(_ session: Session, cleanup: String? = nil) throws -> Data {
        var value: [String: Any] = ["sessionToken": session.token, "provider": session.provider.rawValue,
                                  "state": session.state, "text": session.response, "sequence": session.sequence]
        if let evidence = session.modelEvidence { value["modelEvidence"] = evidence.dictionary }
        if let generation = session.documentGeneration {
            value["modelProofContext"] = ["documentGeneration": generation.uuidString, "sequence": session.sequence,
                                            "firstUserFingerprint": session.firstUserFingerprint ?? "",
                                            "responseCount": session.observedResponseCount,
                                            "baselineResponseCount": session.baseline]
        }
        if let cleanup { value["cleanup"] = cleanup }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func count(_ observation: [String: Any], _ key: String) -> Int { observation[key] as? Int ?? 0 }

    private func script(for provider: Provider) -> String? {
        if let script = scripts[provider] { return script }
        guard let script = Self.loadScript(provider: provider) else { return nil }
        scripts[provider] = script
        return script
    }

    private static func loadScript(provider: Provider) -> String? {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: provider.rawValue, withExtension: "js", subdirectory: "BrowserModels"),
               let source = try? String(contentsOf: url, encoding: .utf8) { return source }
        }
        return nil
    }
}

/// WebKit can finish after timeout/cancellation. Only serialized bytes cross tasks,
/// and a late callback never resumes a continuation twice or replays an action.
private final class EmbeddedScriptResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var completed: Result<Data, Error>?
    private var timeout: Task<Void, Never>?

    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return completed == nil
    }

    func install(_ value: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let completed { lock.unlock(); value.resume(with: completed) }
        else { continuation = value; lock.unlock() }
    }

    func setTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if completed != nil { lock.unlock(); task.cancel() }
        else { timeout = task; lock.unlock() }
    }

    func complete(_ value: Result<Data, Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = value
        let pending = continuation; continuation = nil
        let timer = timeout; timeout = nil
        lock.unlock()
        timer?.cancel()
        pending?.resume(with: value)
    }
}

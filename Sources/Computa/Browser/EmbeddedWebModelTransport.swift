import AppKit
import Foundation
import OSLog
@preconcurrency import WebKit

/// Inference-only browser access. The website has no tool or native IPC handlers.
/// Prompts are data passed to a fixed DOM program in an isolated content world.
@MainActor
final class EmbeddedWebModelTransport: WebModelTransport {
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
        case pageUnavailable, responseTooLarge, deadline
        case editorFailure(String)
        case ownershipFailure(OwnershipReason)

        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The built-in browser model request could not be validated."
            case .unsupportedProvider: "Only ChatGPT is supported in the built-in browser right now."
            case .capacity: "Finish an existing ChatGPT task before opening another browser session."
            case .staleSession: "The owned ChatGPT browser session is no longer available."
            case .documentChanged: "The owned ChatGPT page or conversation changed. No prompt was replayed."
            case .ownershipFailure(let reason): "The owned ChatGPT page or conversation changed (\(reason.rawValue)). No prompt was replayed."
            case .signInRequired: "Sign in to ChatGPT in Computa's built-in browser, then retry."
            case .temporaryUnverified: "ChatGPT did not confirm Temporary Chat mode. No further prompt was sent."
            case .notFresh: "The new ChatGPT page was not empty. It was not modified."
            case .composerUnavailable: "ChatGPT's message editor could not accept the exact prompt. No send was retried."
            case .editorFailure(let reason): "ChatGPT's message editor could not accept the exact prompt (\(reason)). No send was retried."
            case .pageUnavailable: "The ChatGPT page could not be inspected in the built-in browser."
            case .responseTooLarge: "ChatGPT's response exceeded the local browser transport limit."
            case .deadline: "ChatGPT did not become ready or complete its response before the deadline."
            }
        }
    }

    private final class Session {
        let token = UUID().uuidString
        let firstUserMarker = UUID().uuidString
        let tabID: UUID
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

        init(tabID: UUID, view: WKWebView, documentGeneration: UUID) {
            self.tabID = tabID
            self.view = view
            initialDocumentGeneration = documentGeneration
        }
    }

    private let browser: EmbeddedBrowserSession
    private let createTab: @MainActor (URL) throws -> UUID
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")
    private var sessions: [String: Session] = [:]
    private lazy var script: String? = Self.loadScript()
    private static let inspectionLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "EmbeddedChatGPT")
    private struct InspectionSignature: Equatable {
        let responses: Int, users: Int, sequence: Int, textBytes: Int
        let pending: Bool, busy: Bool, answerComplete: Bool, ownershipPending: Bool
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
    #endif

    func request(operation: String, params: Data) async throws -> Data {
        guard let values = try JSONSerialization.jsonObject(with: params) as? [String: String] else {
            throw Failure.invalidRequest
        }
        if operation == "webProviderStart" {
            try Task.checkCancellation()
            guard Set(values.keys) == ["provider"] else { throw Failure.invalidRequest }
            guard values["provider"] == "chatgpt" else { throw Failure.unsupportedProvider }
            guard sessions.count < 4 else { throw Failure.capacity }
            guard script != nil else { throw Failure.pageUnavailable }
            let id = try createTab(URL(string: "https://chatgpt.com/?temporary-chat=true")!)
            guard let view = browser.webView(for: id), let generation = browser.documentGeneration(for: id) else {
                throw Failure.staleSession
            }
            let session = Session(tabID: id, view: view, documentGeneration: generation)
            try browser.installModelChangeSignal(tabID: id, ownerToken: session.token, world: world)
            sessions[session.token] = session
            return try snapshot(session)
        }
        guard ["webProviderPoll", "webProviderSend", "webProviderFinish", "webProviderCancel"].contains(operation),
              Set(values.keys) == (operation == "webProviderSend" ? ["sessionToken", "prompt"] : ["sessionToken"]),
              let token = values["sessionToken"], let session = sessions[token] else { throw Failure.staleSession }
        switch operation {
        case "webProviderFinish", "webProviderCancel":
            return await finish(session, cancel: operation == "webProviderCancel")
        case "webProviderSend":
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
                      conversationURL(before["url"] as? String) == nil else { throw Failure.notFresh }
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

    func waitForChange(sessionToken: String, after revision: UInt64,
                       until deadline: ContinuousClock.Instant) async throws -> UInt64? {
        guard let session = sessions[sessionToken] else { throw Failure.staleSession }
        var wake = deadline
        if session.completionCandidate, let since = session.candidateSince {
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
            guard ContinuousClock.now - session.created < .seconds(45) else { throw Failure.deadline }
            return try snapshot(session)
        }
        let deadline = session.state == "loading" ? session.created + .seconds(45) : session.turnStarted + .seconds(300)
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
        let observed: [String: Any]
        do { observed = try await page(session, action: "inspect", maximumWait: min(.seconds(10), deadline - .now)) }
        catch {
            // Retry only the initial read, before any mode toggle or submission.
            if session.state == "loading", !session.temporaryRequested,
               !session.submitted, ContinuousClock.now - session.created < .seconds(45),
               (error as? Failure) == .pageUnavailable, session.initialReadFailures < 3 {
                // Before the first observer exists, an inspection failure may
                // have no subsequent event. Only that failure gets a bounded retry.
                session.initialReadFailures += 1
                session.initialReadRetry = .now + .milliseconds(250)
                return try snapshot(session)
            }
            throw error
        }
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
        session.initialReadRetry = nil
        logInspection(observed, session: session)
        if session.state == "loading" {
            guard count(observed, "responseCount") == 0, count(observed, "userCount") == 0,
                  conversationURL(observed["url"] as? String) == nil else { throw Failure.notFresh }
            if observed["signIn"] as? Bool == true { throw Failure.signInRequired }
            if observed["composer"] as? Bool == true {
                if observed["temporary"] as? Bool == true {
                    session.temporary = true
                    session.state = "ready"
                } else if !session.temporaryRequested {
                    session.temporaryRequested = true
                    _ = try await page(session, action: "enableTemporary")
                }
            }
            guard session.state == "ready" || ContinuousClock.now - session.created < .seconds(45) else {
                throw Failure.temporaryUnverified
            }
        } else {
            let previouslyCandidate = session.completionCandidate
            session.completionCandidate = false
            guard observed["temporary"] as? Bool == true else { throw Failure.temporaryUnverified }
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
            guard session.state == "complete" || ContinuousClock.now - session.turnStarted < .seconds(300) else {
                throw Failure.deadline
            }
        }
        return try snapshot(session)
    }

    private func logInspection(_ observed: [String: Any], session: Session) {
        let evidence = observed["completionEvidence"] as? [String: Any] ?? [:]
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
            modernMarkers: count(evidence, "modernMarkers"), logicalAnswers: count(evidence, "logicalAnswers"),
            scopedCopies: count(evidence, "scopedCopies"), enabledCopies: count(evidence, "enabledCopies"), depth: count(evidence, "depth"))
        guard signature != session.lastInspection else { return }
        session.lastInspection = signature
        Self.inspectionLog.info("inspection responses=\(signature.responses) users=\(signature.users) sequence=\(signature.sequence) pending=\(signature.pending) busy=\(signature.busy) answerComplete=\(signature.answerComplete) textBytes=\(signature.textBytes) ownershipPending=\(signature.ownershipPending) modernMarkers=\(signature.modernMarkers) logicalAnswers=\(signature.logicalAnswers) scopedCopies=\(signature.scopedCopies) enabledCopies=\(signature.enabledCopies) depth=\(signature.depth)")
    }

    private func page(_ session: Session, action: String, prompt: String? = nil,
                      refreshChangedRoute: Bool = true, maximumWait: Duration = .seconds(10)) async throws -> [String: Any] {
        guard browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
        guard let generation = browser.documentGeneration(for: session.tabID),
              session.documentGeneration == nil || session.documentGeneration == generation else {
            throw Failure.ownershipFailure(.documentGenerationBefore)
        }
        guard let script, let url = session.view.url, isChatGPTURL(url.absoluteString) else { throw Failure.pageUnavailable }
        let current = conversationURL(url.absoluteString)
        let promotion = session.conversation?.contains("/c/local-chatgpt") == true && current != nil
            && current != session.conversation && current?.contains("/c/local-chatgpt") == false && !session.promoted
        if let owned = session.conversation, current != owned, !promotion { throw Failure.ownershipFailure(.routeBefore) }
        if current != nil, !session.submitted { throw Failure.notFresh }
        let expectedCounts: [Int] = action == "submit" ? [session.confirmedUsers]
            : session.pendingSubmission ? [session.confirmedUsers, session.sequence] : [session.confirmedUsers]
        var input: [String: Any] = [
            "provider": "chatgpt", "action": action, "expectedURL": url.absoluteString,
            "ownerToken": session.token, "bindOwner": session.state == "loading" && !session.submitted,
            "expectedUserCounts": expectedCounts,
            "expectedFirstUserMarker": session.firstUserMarker,
            "allowFirstUserBinding": action == "inspect" && session.sequence == 1
                && session.pendingSubmission && session.firstUserFingerprint == nil,
        ]
        if let fingerprint = session.firstUserFingerprint { input["expectedFirstUserFingerprint"] = fingerprint }
        if let conversation = session.conversation, !promotion { input["expectedConversation"] = conversation }
        // ChatGPT's selection IDs can change during ordinary re-rendering.
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
                        result.complete(.failure(Failure.pageUnavailable))
                    } catch { }
                }
                result.setTimeout(timeout)
                guard result.isPending else { return }
                session.view.callAsyncJavaScript(script, arguments: ["input": input], in: nil, in: world) { reply in
                    switch reply {
                    case .success(let value):
                        do { result.complete(.success(try JSONSerialization.data(withJSONObject: value))) }
                        catch { result.complete(.failure(Failure.pageUnavailable)) }
                    case .failure: result.complete(.failure(Failure.pageUnavailable))
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
        guard let currentURL = session.view.url, isChatGPTURL(currentURL.absoluteString) else {
            throw Failure.ownershipFailure(.routeAfter)
        }
        if currentURL != url {
            let nextConversation = conversationURL(currentURL.absoluteString)
            let firstConversation = session.submitted && session.sequence == 1 && session.conversation == nil
                && nextConversation != nil && (current == nil || current?.contains("/c/local-chatgpt") == true
                    && nextConversation?.contains("/c/local-chatgpt") == false)
            let promotedConversation = session.conversation?.contains("/c/local-chatgpt") == true
                && nextConversation != nil && nextConversation != session.conversation
                && nextConversation?.contains("/c/local-chatgpt") == false && !session.promoted
            if action == "inspect", refreshChangedRoute, firstConversation || promotedConversation {
                // A read may race the site's normal SPA route promotion. Read
                // the current route once; never accept the old result or replay a mutation.
                return try await page(session, action: action, refreshChangedRoute: false, maximumWait: maximumWait)
            }
            let temporaryToggle = action == "enableTemporary" && session.state == "loading"
                && !session.submitted && current == nil && nextConversation == nil
                && URLComponents(url: currentURL, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(URLQueryItem(name: "temporary-chat", value: "true")) == true
            // Send can synchronously create the first SPA route before its
            // acknowledgment returns. The next poll verifies its conversation.
            guard action == "submit" && firstConversation || temporaryToggle else { throw Failure.ownershipFailure(.routeAfter) }
        }
        guard let observed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.pageUnavailable }
        if let error = observed["error"] as? String {
            if error == "prompt_not_inserted", let detail = observed["detail"] as? String,
               ["editor_empty", "line_break_expansion", "nonbreaking_spaces", "text_difference"].contains(detail),
               let actual = observed["actualLength"] as? Int, let expected = observed["expectedLength"] as? Int,
               let actualLines = observed["actualLines"] as? Int, let expectedLines = observed["expectedLines"] as? Int,
               [actual, expected, actualLines, expectedLines].allSatisfy({ (0...360_000).contains($0) }) {
                throw Failure.editorFailure("\(detail); \(actual)/\(expected) characters; \(actualLines)/\(expectedLines) lines")
            }
            switch error {
            case "document_changed", "conversation_changed":
                let allowedDetails: [String: OwnershipReason] = [
                    "owner_token": .javaScriptOwner, "user_count": .javaScriptUserCount,
                    "conversation_identity": .javaScriptConversationIdentity, "document_url": .javaScriptURL,
                    "conversation_route": .javaScriptConversationRoute, "first_user_message": .javaScriptFirstUser,
                ]
                let detail = (observed["detail"] as? String).flatMap { allowedDetails[$0] }
                throw Failure.ownershipFailure(detail ?? (error == "document_changed" ? .javaScriptDocument : .javaScriptConversation))
            case "sign_in_required": throw Failure.signInRequired
            case "not_fresh": throw Failure.notFresh
            case "temporary_mode_unavailable", "temporary_mode_unverified": throw Failure.temporaryUnverified
            case "composer_unavailable", "composer_not_empty", "prompt_not_inserted", "send_unavailable", "caret_unavailable", "insert_command_rejected": throw Failure.editorFailure(error)
            default: throw Failure.composerUnavailable
            }
        }
        // Submit returns only its acknowledgment; observations carry ownership state.
        if let observedURL = observed["url"] as? String {
            guard isChatGPTURL(observedURL) else { throw Failure.documentChanged }
            if session.documentGeneration == nil { session.documentGeneration = generation }
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
                }
            }
            if action == "inspect", session.pendingSubmission, count(observed, "userCount") == 0 {
                if !promotion, session.conversation == nil, let conversation = conversationURL(observedURL) {
                    // Preserve the initial route pin while waiting for render;
                    // a later promotion still requires the first-message proof.
                    session.conversation = conversation
                }
                // Neither answers nor cleanup can be admitted before the
                // submitted first message has established owned lineage.
                return ["temporary": observed["temporary"] as? Bool ?? false,
                        "userCount": 0, "responseCount": session.baseline, "text": "", "busy": true,
                        "answerComplete": false, "ownershipPending": true,
                        "debugStructure": observed["debugStructure"] as? String ?? ""]
            }
            if promotion {
                guard session.temporary, observed["temporary"] as? Bool == true else {
                    throw Failure.ownershipFailure(.promotionTemporary)
                }
                guard observed["firstUserVerified"] as? Bool == true else {
                    throw Failure.ownershipFailure(.promotionFirstUser)
                }
                session.conversation = conversationURL(observedURL)
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
            } else if session.conversation == nil, let conversation = conversationURL(observedURL) {
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
        return observed
    }

    private func finish(_ session: Session, cancel: Bool) async -> Data {
        do {
            if session.submitted || session.temporaryRequested || session.temporary {
                let observed = try await page(session, action: "inspect")
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
                    guard isChatGPTURL(url.absoluteString), conversationURL(url.absoluteString) == nil,
                          URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                            .contains(URLQueryItem(name: "temporary-chat", value: "true")) == true else {
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
        var value: [String: Any] = ["sessionToken": session.token, "provider": "chatgpt",
                                  "state": session.state, "text": session.response, "sequence": session.sequence]
        if let cleanup { value["cleanup"] = cleanup }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func count(_ observation: [String: Any], _ key: String) -> Int { observation[key] as? Int ?? 0 }

    private func isChatGPTURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "chatgpt.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return false }
        return url.path == "/" || conversationURL(raw) != nil
    }

    private func conversationURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host == "chatgpt.com",
              url.path.range(of: #"^/c/(?:[A-Za-z0-9-]+|local-chatgpt(?:%3[Aa]|:)[A-Za-z0-9-]+)/?$"#, options: .regularExpression) != nil else { return nil }
        return "https://chatgpt.com" + (url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path)
    }

    private static func loadScript() -> String? {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: "chatgpt", withExtension: "js", subdirectory: "BrowserModels"),
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

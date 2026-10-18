import AppKit
import CoreFoundation
import CryptoKit
import Foundation
import OSLog
@preconcurrency import WebKit

/// A finite diagnostic returned by the original admitted native read. It has
/// no model/browser operation and cannot supply submission or response proof.
struct ChatSubmissionFailureDiagnostic: Sendable {
    private let encoded: Data

    @MainActor
    init?(adapterValue: Any) {
        guard let safe = EmbeddedWebModelTransport.sanitizedChatSubmissionDiagnostic(adapterValue) else { return nil }
        encoded = Data(safe.utf8)
    }

    var dictionary: [String: Any] {
        (try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
    }
}

/// One inference-local, synchronous callback cell. No identity, page data or
/// callback from another inference can be merged into this cell.
final class ChatSubmissionFailureDiagnosticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var first: ChatSubmissionFailureDiagnostic?

    func record(_ diagnostic: ChatSubmissionFailureDiagnostic) {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = diagnostic }
    }

    var snapshot: ChatSubmissionFailureDiagnostic? {
        lock.lock(); defer { lock.unlock() }
        return first
    }
}

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
            case .chatgpt: URL(string: "https://chatgpt.com/")!
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
            return self == .gemini || self == .chatgpt ? true : acceptsTemporaryToggle(url)
        }

        /// Abort-only classification of known provider checkpoints. Never run
        /// the provider adapter on these documents or treat them as ownership
        /// evidence. Query strings can contain IPs or credentials and stay local.
        func blockingFailure(for url: URL?) -> Failure? {
            guard let url, url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443 else { return nil }
            if self == .gemini, ["google.com", "www.google.com"].contains(url.host ?? ""),
               url.path == "/sorry" || url.path.hasPrefix("/sorry/") {
                return .humanVerificationRequired(self)
            }
            if [.gemini, .chatgpt].contains(self), url.host == "accounts.google.com" {
                return .signInRequired
            }
            guard url.host == host else { return nil }
            let authRoots = self == .chatgpt ? ["/auth", "/login"] : self == .claude ? ["/login", "/signup"] : ["/signin"]
            if authRoots.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) {
                return .signInRequired
            }
            return nil
        }

        /// Disposal-only recognition for a never-used private ChatGPT view.
        /// External identity-provider pages retain their existing cleanup policy.
        func acceptsUntouchedSignIn(_ url: URL) -> Bool {
            self == .chatgpt && url.host == host && blockingFailure(for: url) == .signInRequired
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
        case javaScriptSubmission = "submission_message"
        case promotionFirstUser = "promotion_first_user"
        case promotionTemporary = "promotion_temporary"
    }

    private enum SubmissionNativeStage: String {
        case adapterRejected = "adapter_rejected"
        case bindingMissing = "binding_missing"
        case proofMissing = "proof_missing"
        case proofInvalid = "proof_invalid"
        case replacementRefreshRejected = "replacement_refresh_rejected"
        case capabilityMissing = "capability_missing"
        case currentProofMissing = "current_proof_missing"
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidRequest, unsupportedProvider, capacity, staleSession, documentChanged, turnLimit, cookieMaintenancePending
        case signInRequired, temporaryUnverified, notFresh, composerUnavailable
        case pageUnavailable, responseTooLarge, responseInterrupted, preparationDeadline, deadline
        case submissionObservationPending
        case modelUnverified, modelMismatch, modelUnavailable, productModeUnverified, discoveryCleanupFailed
        case usageLimited(Provider), responseFailed(Provider)
        case humanVerificationRequired(Provider), unexpectedPage(Provider)
        case editorFailure(String)
        case ownershipFailure(OwnershipReason)

        var diagnosticCode: String? {
            switch self {
            case .humanVerificationRequired: "website_verification_required"
            case .signInRequired: "sign_in_required"
            case .usageLimited: "website_usage_limit"
            case .responseFailed: "website_response_failed"
            case .unexpectedPage: "unexpected_website_page"
            case .productModeUnverified: "product_mode_unverified"
            case .ownershipFailure: "website_ownership_unverified"
            case .turnLimit: "website_turn_limit"
            default: nil
            }
        }

        var requiredAction: String? {
            switch self {
            case .humanVerificationRequired: "complete_website_verification"
            case .signInRequired: "sign_in"
            case .usageLimited: "wait_for_quota_reset"
            case .responseFailed: "inspect_website"
            case .unexpectedPage: "inspect_website"
            case .productModeUnverified: "refresh_website_models"
            case .ownershipFailure: "inspect_website"
            default: nil
            }
        }

        /// These account/profile gates affect new sessions too. An unexpected
        /// route or ownership failure can be specific to one tab and must not
        /// disable otherwise healthy sessions for the provider.
        var blocksProviderUntilRefresh: Bool {
            switch self {
            case .humanVerificationRequired, .signInRequired, .usageLimited: true
            default: false
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The built-in browser model request could not be validated."
            case .turnLimit: "The bounded website conversation limit was reached. No prompt was replayed; start a new task."
            case .unsupportedProvider: "That model provider is not supported in the built-in browser."
            case .capacity: "Finish an existing website-model task before opening another session. If failed sessions remain retained, restart Computa to free local capacity; their website cleanup remains unconfirmed."
            case .cookieMaintenancePending: "ChatGPT's previous browser session is still closing. Wait briefly before starting another task."
            case .staleSession: "The owned browser model session is no longer available."
            case .documentChanged: "The owned model page or conversation changed. No prompt was replayed."
            case .ownershipFailure(let reason): "The owned model page or conversation changed (\(reason.rawValue)). No prompt was replayed."
            case .signInRequired: "Sign in to the selected AI website in Computa's built-in browser, then refresh website models before retrying."
            case .temporaryUnverified: "The AI website did not confirm temporary or incognito chat mode. No further prompt was sent."
            case .notFresh: "The new model page was not empty. It was not modified."
            case .composerUnavailable: "The website's message editor could not accept the exact prompt. No send was retried."
            case .editorFailure(let reason): "The website's message editor could not accept the exact prompt (\(reason)). No send was retried."
            case .pageUnavailable: "The model page could not be inspected in the built-in browser."
            case .submissionObservationPending: "The submitted message is still appearing on the model page."
            case .modelUnverified: "The website's selected model could not be verified. No prompt was replayed. Refresh the website models and retry."
            case .modelMismatch: "The website changed or reported a different model. Its response was not accepted, and no prompt was replayed."
            case .productModeUnverified: "ChatGPT normal Chat mode could not be verified. No response was accepted and no prompt was replayed. Refresh website models before retrying."
            case .modelUnavailable: "That model is not available in the website's current account. Refresh the website models and choose an available model."
            case .discoveryCleanupFailed: "The model menu session could not be closed. Restart Computa to refresh website models."
            case .responseTooLarge: "The website's response exceeded the local browser transport limit."
            case .responseInterrupted: "The website interrupted its response. No send was retried."
            case .responseFailed(let provider): "\(provider.displayName)'s website reported that the response failed to load. Check its page in Computa's built-in browser before starting a new task. No prompt was replayed."
            case .usageLimited(let provider): "\(provider.displayName)'s website usage limit has been reached. After your account's limit resets, refresh website models before retrying."
            case .humanVerificationRequired(let provider): "\(provider.displayName) has a saved or current website-verification block. Check its website in Computa's built-in browser and resolve any challenge shown. Once the page is clear, refresh website models before retrying. No prompt was replayed."
            case .unexpectedPage(let provider): "\(provider.displayName)'s website opened an unexpected page. Check its page in Computa's built-in browser before retrying. No prompt was replayed."
            case .preparationDeadline: "The website did not prepare a verified temporary or incognito chat before the 45-second deadline. This website inference was not submitted."
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
        let isRecoveryProbe: Bool
        let view: WKWebView
        let initialDocumentGeneration: UUID
        let created = ContinuousClock.now
        var state = "loading"
        var terminalFailure: Failure?
        struct SavedChatSubmissionFailure {
            let generation: UUID
            let sequence: Int
            let diagnostic: ChatSubmissionFailureDiagnostic
        }
        var firstChatSubmissionFailure: SavedChatSubmissionFailure?
        // Claimed before dispatch, including calls whose reply is lost. A
        // checkpoint can never turn an ambiguous adapter call into no input.
        var providerAdapterEverDispatched = false
        struct UntouchedCheckpoint {
            let documentGeneration: UUID
            let url: URL
        }
        var untouchedGoogleCheckpoint: UntouchedCheckpoint?
        var untouchedChatGPTSignIn: UntouchedCheckpoint?
        var postBlockDiagnostic: GeminiPostBlockDiagnostic?
        struct InitialCheckpointSettlement {
            let deadline: ContinuousClock.Instant
            var observations = 0
            var finished = false
        }
        // One passive initial window; native navigation changes never renew it.
        var initialCheckpointSettlement: InitialCheckpointSettlement?
        var submitted = false
        // A native Send claim precedes dispatch. Only the validated callback
        // below acknowledges that sequence; a lost reply cannot grant recovery.
        var acknowledgedSendSequence = 0
        var temporary = false
        var temporaryRequested = false
        var chatModeRequested = false
        var productModeEvidence: WebsiteProductModeEvidence?
        var sequence = 0
        struct SubmissionBinding {
            let sequence: Int
            let marker: String
            let promptFingerprint: String
            let outboundFingerprint: String
        }
        var preparedSubmission: SubmissionBinding?
        var currentSubmission: SubmissionBinding?
        var previousSubmission: SubmissionBinding?
        var currentSubmissionVerified = false
        var submittedUTF8Count = 0
        var usesSubmissionOwnership: Bool { !isDiscovery && (provider == .gemini || provider == .chatgpt) }
        var usesBoundedTurn: Bool { usesSubmissionOwnership && provider == .chatgpt }
        var confirmedUsers = 0
        var pendingSubmission = false
        var baseline = 0
        var response = ""
        var lastChanged = ContinuousClock.now
        var turnStarted = ContinuousClock.now
        var responseProfile: WebsiteResponseProfile?
        var profiledFirstPositive = false
        var profiledFirstCompletionCandidate = false
        var profiledCompletionTransitions = 0
        func profileCompletionTransition(_ phase: WebsiteResponseProfile.Phase) {
            guard let responseProfile, profiledCompletionTransitions < 32 else { return }
            profiledCompletionTransitions += 1
            responseProfile.mark(phase)
        }
        var readTimeoutCount = 0
        var responseReadRetryUsed = false
        var firstBodyReadRecoveryActive = false
        var conversation: String?
        var routeContext: String?
        var conversationIdentity: String?
        var temporaryCookieRoutes = ChatGPTTemporaryConversationRoutes()
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
        // Running observations retain negative pins, but never claim a fresh picker proof.
        var modelVerificationPending = false
        var loggedPendingModelVerification = false
        var modelEvidence: WebsiteModelEvidence?
        var lastModelDiagnostic: String?
        var lastProductModeDiagnostic: String?
        var observedResponseCount = 0
        var responseCodeStructure: [String: Any]?
        var benchmarkObservationLogCount = 0
        var lastBenchmarkObservationLog: String?
        var failedPageDiagnosticAttempted = false
        var outboundUTF16Count: Int?
        var outboundUTF8Count: Int?
        // Diagnostic-only immutable hashes; populated only by a saved synthetic capture.
        var benchmarkObservationBinding: WebsiteBenchmarkCaptureLease.ObservationBinding?
        var resourceTimingSignatures: [String: String] = [:]
        struct ResponseProgressInspection {
            let sequence: Int
            let generation: UUID
            let fields: [String: Any]
            let responseNotice: String?
            let answerScope: String?
        }
        var responseProgressInspection: ResponseProgressInspection?
        var responseProgressEmitted = false

        init(provider: Provider, tabID: UUID, view: WKWebView, documentGeneration: UUID, modelChoice: WebsiteModelChoice? = nil,
             isDiscovery: Bool = false, isRecoveryProbe: Bool = false) {
            self.provider = provider
            self.modelChoice = modelChoice
            self.isDiscovery = isDiscovery
            self.isRecoveryProbe = isRecoveryProbe
            self.tabID = tabID
            self.view = view
            initialDocumentGeneration = documentGeneration
        }
    }


    private final class GeminiPostBlockDiagnostic {
        let id = UUID()
        let started: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        let checkpointID: UUID
        var lease: EmbeddedBrowserSession.GeminiPostBlockNativeLease?
        var task: Task<Data, Never>?
        var generations: [UUID: Int] = [:]
        var lastSignature: String?
        var records = 0
        var truncated = false
        var completed = false
        var physicallyClosed = false
        var interruption: String?

        init(duration: Duration, checkpointID: UUID) {
            let started = ContinuousClock.now
            self.started = started
            deadline = started + duration
            self.checkpointID = checkpointID
        }
    }

    private static var compiledPostBlockDiagnostic: Bool {
        #if COMPUTA_GEMINI_POST_BLOCK_DIAGNOSTIC
        true
        #else
        false
        #endif
    }

    private let browser: EmbeddedBrowserSession
    private let geminiPostBlockDiagnosticEnabled: Bool
    private var geminiPostBlockDiagnosticDuration: Duration = .seconds(5)
    private let createTab: @MainActor (URL) throws -> UUID
    private let isolatesChatGPTInference: Bool
    private var pendingInferenceStarts = 0
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")
    private var sessions: [String: Session] = [:]
    private var finishingTasks: [String: Task<Data, Never>] = [:]
    private var closedSessions: [String: (created: ContinuousClock.Instant, receipt: Data)] = [:]
    private struct ProviderGate {
        let id = UUID()
        let failure: Failure
    }
    // This transport belongs to one shared browser profile. New tasks must not
    // repeatedly revisit a checkpoint that the profile already encountered.
    private var providerGates: [Provider: ProviderGate] = [:]
    private var chatGPTPrewarmingEnabled = false
    private var scripts: [Provider: String] = [:]
    private var preparationTimeout: Duration = .seconds(45)
    private var responseTimeout: Duration = .seconds(300)
    private var inspectionTimeout: Duration = .seconds(30)
    private var initialCheckpointSettlementTimeout: Duration = .seconds(3)
    private static let inspectionLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "EmbeddedWebModel")
    private struct InspectionSignature: Equatable {
        let responses: Int, users: Int, sequence: Int, textBytes: Int
        let pending: Bool, busy: Bool, answerComplete: Bool, ownershipPending: Bool, composer: Bool, temporary: Bool, temporaryActionAvailable: Bool
        let modernMarkers: Int, logicalAnswers: Int, scopedCopies: Int, enabledCopies: Int, depth: Int
    }
    #if DEBUG
    enum FirstUserExpansionRouteCheckpoint { case routeAccepted, continuationInput }
    private var beforePageResultValidationForTesting: (@MainActor (String) async -> Void)?
    private var beforePageResultValidationDetailedForTesting: (@MainActor (String, Bool) async -> Void)?
    private var firstUserDiagnosticsObserverForTesting: (@MainActor ([String]) -> Void)?
    private var submissionDiagnosticsObserverForTesting: (@MainActor (String, String) -> Void)?
    private var firstUserStructureEmissionObserverForTesting: (@MainActor (Bool, String) -> Void)?
    private var modelDiagnosticsObserverForTesting: (@MainActor (String) -> Void)?
    private var adapterTimeoutObserverForTesting: (@MainActor (String) -> Void)?
    private var failedPageDiagnosticObserverForTesting: (@MainActor (String) -> Void)?
    private var resourceTimingDiagnosticObserverForTesting: (@MainActor (String) -> Void)?
    private var responseProgressDiagnosticObserverForTesting: (@MainActor (String) -> Void)?
    private var initialCheckpointSettlementObserverForTesting: (@MainActor ([String: Any]) -> Void)?
    private var geminiPostBlockObserverForTesting: (@MainActor ([String: Any]) -> Void)?
    private var firstUserExpansionRouteCheckpointForTesting: (@MainActor (FirstUserExpansionRouteCheckpoint) async -> Void)?
    #endif

    init(browser: EmbeddedBrowserSession, geminiPostBlockDiagnostic: Bool? = nil) {
        self.geminiPostBlockDiagnosticEnabled = geminiPostBlockDiagnostic ?? Self.compiledPostBlockDiagnostic
        self.browser = browser
        self.createTab = { try browser.createModelTab(url: $0) }
        self.isolatesChatGPTInference = true
    }

    #if DEBUG
    init(browser: EmbeddedBrowserSession, geminiPostBlockDiagnostic: Bool? = nil,
         createTabForTesting: @escaping @MainActor (URL) throws -> UUID) {
        self.geminiPostBlockDiagnosticEnabled = geminiPostBlockDiagnostic ?? Self.compiledPostBlockDiagnostic
        self.browser = browser
        self.createTab = createTabForTesting
        self.isolatesChatGPTInference = false
    }


    @discardableResult
    func setGeminiPostBlockDiagnosticWindowForTesting(_ duration: Duration) -> Bool {
        guard !browser.hasConsumedGeminiPostBlockDiagnostic else { return false }
        geminiPostBlockDiagnosticDuration = max(.milliseconds(1), min(.seconds(5), duration))
        return true
    }

    func setGeminiPostBlockDiagnosticObserverForTesting(_ observer: (@MainActor ([String: Any]) -> Void)?) {
        geminiPostBlockObserverForTesting = observer
    }

    func geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: String) -> ContinuousClock.Instant? {
        sessions[sessionToken]?.postBlockDiagnostic?.deadline
    }

    func canDisposeUntouchedGoogleCheckpointForTesting(sessionToken: String) -> Bool {
        sessions[sessionToken].map(canDisposeUntouchedGoogleCheckpoint) ?? false
    }

    /// Negative fixtures can only remove eligibility, never create proof or input.
    func invalidateGeminiPostBlockEligibilityForTesting(sessionToken: String, submitted: Bool, adapterDispatched: Bool) {
        guard let session = sessions[sessionToken] else { return }
        if submitted { session.submitted = true; session.sequence = max(1, session.sequence) }
        if adapterDispatched { session.providerAdapterEverDispatched = true }
    }

    func revokeGeminiPostBlockObservationForTesting(sessionToken: String) {
        guard let lease = sessions[sessionToken]?.postBlockDiagnostic?.lease else { return }
        browser.endGeminiPostBlockNativeObservation(lease)
    }

    func createGeminiPostBlockRoleSessionForTesting(provider: Provider, isDiscovery: Bool, isRecoveryProbe: Bool) throws -> String {
        guard providerGates[provider] == nil, !browser.savedHumanVerificationProviders.contains(provider.rawValue) else {
            throw Failure.humanVerificationRequired(provider)
        }
        return try createSession(provider: provider, choice: nil, isDiscovery: isDiscovery,
                                 isRecoveryProbe: isRecoveryProbe).token
    }

    func setBeforePageResultValidationForTesting(_ hook: (@MainActor (String) async -> Void)?) {
        beforePageResultValidationForTesting = hook
    }

    /// Separate model-enforced reads from product-only lineage observations.
    func setBeforePageResultValidationDetailedForTesting(_ hook: (@MainActor (String, Bool) async -> Void)?) {
        beforePageResultValidationDetailedForTesting = hook
    }

    func setSubmissionDiagnosticsObserverForTesting(_ observer: (@MainActor (String, String) -> Void)?) {
        submissionDiagnosticsObserverForTesting = observer
    }

    func setFirstUserDiagnosticsObserverForTesting(_ observer: (@MainActor ([String]) -> Void)?) {
        firstUserDiagnosticsObserverForTesting = observer
    }

    func setFirstUserStructureEmissionObserverForTesting(_ observer: (@MainActor (Bool, String) -> Void)?) {
        firstUserStructureEmissionObserverForTesting = observer
    }

    func setModelDiagnosticsObserverForTesting(_ observer: (@MainActor (String) -> Void)?) {
        modelDiagnosticsObserverForTesting = observer
    }

    func setAdapterTimeoutObserverForTesting(_ observer: (@MainActor (String) -> Void)?) {
        adapterTimeoutObserverForTesting = observer
    }

    func setFailedPageDiagnosticObserverForTesting(_ observer: (@MainActor (String) -> Void)?) {
        failedPageDiagnosticObserverForTesting = observer
    }

    func setResourceTimingDiagnosticObserverForTesting(_ observer: (@MainActor (String) -> Void)?) {
        resourceTimingDiagnosticObserverForTesting = observer
    }

    func setResponseProgressDiagnosticObserverForTesting(_ observer: (@MainActor (String) -> Void)?) {
        responseProgressDiagnosticObserverForTesting = observer
    }

    func setFirstUserExpansionRouteCheckpointForTesting(_ hook: (@MainActor (FirstUserExpansionRouteCheckpoint) async -> Void)?) {
        firstUserExpansionRouteCheckpointForTesting = hook
    }

    /// Shorten only before any checkpoint window starts; tests cannot renew one.
    @discardableResult
    func setInitialCheckpointSettlementTimeoutForTesting(_ timeout: Duration) -> Bool {
        guard sessions.values.allSatisfy({ $0.initialCheckpointSettlement == nil }) else { return false }
        initialCheckpointSettlementTimeout = max(.milliseconds(1), min(.seconds(3), timeout))
        return true
    }

    func initialCheckpointSettlementDeadlineForTesting(sessionToken: String) -> ContinuousClock.Instant? {
        sessions[sessionToken]?.initialCheckpointSettlement?.deadline
    }

    func setInitialCheckpointSettlementObserverForTesting(_ observer: (@MainActor ([String: Any]) -> Void)?) {
        initialCheckpointSettlementObserverForTesting = observer
    }

    func setTimeoutsForTesting(preparation: Duration, response: Duration) {
        preparationTimeout = max(.milliseconds(1), min(.seconds(45), preparation))
        responseTimeout = max(.milliseconds(1), min(.seconds(300), response))
    }

    /// Establish the test's original response deadline after its owned queue
    /// blocker has started; this never runs in production or renews a retry.
    func anchorResponseDeadlineForTesting(sessionToken: String) -> Bool {
        guard let session = sessions[sessionToken], session.state == "running", session.submitted,
              session.firstUserFingerprint != nil, !session.pendingSubmission else { return false }
        session.turnStarted = .now
        return true
    }

    func setInspectionTimeoutForTesting(_ timeout: Duration) {
        inspectionTimeout = max(.milliseconds(1), min(.seconds(30), timeout))
    }

    /// Negative-only: removing a receipt cannot authorize a read or input.
    func revokeAcknowledgedSendForTesting(sessionToken: String) -> Bool {
        guard let session = sessions[sessionToken], session.acknowledgedSendSequence > 0 else { return false }
        session.acknowledgedSendSequence = 0
        return true
    }
    #endif

    /// Called only through the native server's manually armed handoff, never request().
    func grantInspectorDiagnostic(_ authorization: ChatGPTInspectorLease, sessionToken: String) async -> Bool {
        guard !Task.isCancelled, let session = sessions[sessionToken], session.provider == .chatgpt,
              !session.isDiscovery, !session.isRecoveryProbe, ["ready", "complete"].contains(session.state),
              session.temporary, session.modelSelectionVerified, session.modelEvidence != nil,
              browser.webView(for: session.tabID) === session.view,
              let generation = browser.documentGeneration(for: session.tabID),
              generation == (session.documentGeneration ?? session.initialDocumentGeneration),
              let binding = authorization.bind(view: ObjectIdentifier(session.view), ownerToken: session.token, generation: generation) else { return false }
        return browser.grantModelInspectorDiagnostic(binding, tabID: session.tabID, view: session.view,
            ownerToken: session.token, generation: generation)
    }

    func revokeInspectorDiagnostic(sessionToken: String) async {
        guard let session = sessions[sessionToken] else { return }
        browser.revokeModelInspectorDiagnostic(tabID: session.tabID, ownerToken: session.token)
    }

    func startWithRequestMetadata(params: Data, authorization: ChatGPTRequestMetadataLease) async throws -> Data {
        guard let values = try JSONSerialization.jsonObject(with: params) as? [String: String],
              values["provider"] == "chatgpt" else { authorization.revoke(); throw Failure.invalidRequest }
        return try await start(values, requestMetadata: authorization)
    }

    func activateRequestMetadata(sessionToken: String) async -> Bool {
        guard let session = sessions[sessionToken], session.provider == .chatgpt, !session.isDiscovery,
              !session.isRecoveryProbe, session.state == "ready", !session.submitted,
              session.temporary, session.modelSelectionVerified, session.modelEvidence != nil else { return false }
        let snapshot = await browser.modelRequestMetadata(command: "activate", tabID: session.tabID,
            view: session.view, ownerToken: session.token)
        return snapshot?.active == true && snapshot?.expired == false
    }

    func stopRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot? {
        guard let session = sessions[sessionToken], session.provider == .chatgpt else { return nil }
        return await browser.modelRequestMetadata(command: "stop", tabID: session.tabID,
            view: session.view, ownerToken: session.token)
    }

    func snapshotRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot? {
        guard let session = sessions[sessionToken], session.provider == .chatgpt else { return nil }
        return await browser.modelRequestMetadata(command: "snapshot", tabID: session.tabID,
            view: session.view, ownerToken: session.token)
    }

    func revokeRequestMetadata(sessionToken: String) async {
        guard let session = sessions[sessionToken] else { return }
        browser.revokeModelRequestMetadata(tabID: session.tabID, ownerToken: session.token)
    }

    /// A blank root may load before Send; it has no model Session, prompt,
    /// adapter ownership or inference result. Actual Start still establishes
    /// all of those using the unchanged preparation and submission checks.
    func setChatGPTPrewarmingEnabled(_ enabled: Bool) {
        chatGPTPrewarmingEnabled = enabled
        synchronizeProviderGate(.chatgpt)
        browser.setChatGPTInferencePrewarmingEnabled(enabled && providerGates[.chatgpt] == nil) { [weak self] in
            guard let self, self.chatGPTPrewarmingEnabled else { throw CancellationError() }
            self.synchronizeProviderGate(.chatgpt)
            if let gate = self.providerGates[.chatgpt] { throw gate.failure }
            try Task.checkCancellation()
        }
    }

    private func start(_ values: [String: String], requestMetadata: ChatGPTRequestMetadataLease? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard Set(values.keys) == ["provider"] || Set(values.keys) == ["provider", "modelChoice"] else { throw Failure.invalidRequest }
        guard let raw = values["provider"], let provider = Provider(rawValue: raw) else { throw Failure.unsupportedProvider }
        let choice: WebsiteModelChoice?
        if let encoded = values["modelChoice"] {
            guard let parsed = WebsiteModelChoice.parse(encoded), parsed.provider == raw,
                  parsed.isSelectable else { throw Failure.invalidRequest }
            choice = parsed
        } else { choice = nil }
        guard provider != .chatgpt || choice?.chatGPTPower != nil else { throw Failure.invalidRequest }
        if provider == .chatgpt {
            guard await browser.admitChatGPTAfterCookieCallbacks(until: .now + .seconds(2)) else { throw Failure.cookieMaintenancePending }
            try Task.checkCancellation()
        }
        synchronizeProviderGate(provider)
        if let gate = providerGates[provider] { throw gate.failure }
        let pending = pendingInferenceStarts + browser.failedChatGPTInferenceCookiePreparationCount
        guard sessions.values.filter({ !$0.isDiscovery }).count + pending < 4 else { throw Failure.capacity }
        guard script(for: provider) != nil else { throw Failure.pageUnavailable }
        pendingInferenceStarts += 1
        defer { pendingInferenceStarts -= 1 }
        let preparedTab: UUID?
        if provider == .chatgpt, isolatesChatGPTInference {
            let admit: @MainActor () throws -> Void = {
                self.synchronizeProviderGate(provider)
                if let gate = self.providerGates[provider] { throw gate.failure }
                try Task.checkCancellation()
            }
            // Metadata capture must be installed before the first navigation;
            // its explicitly authorized diagnostic path always stays cold.
            let warmTab = requestMetadata == nil
                ? try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: admit) : nil
            if let warmTab { preparedTab = warmTab }
            else { preparedTab = try await browser.createChatGPTInferenceTab(requestMetadata: requestMetadata, admit: admit) }
        } else { preparedTab = nil }
        let session: Session
        do {
            try Task.checkCancellation()
            session = try createSession(provider: provider, choice: choice, isDiscovery: false,
                requestMetadata: requestMetadata, preparedTab: preparedTab, reservedStart: true)
        } catch {
            if let preparedTab { browser.closeTab(preparedTab) }
            throw error
        }
        return try snapshot(session)
    }

    func request(operation: String, params: Data) async throws -> Data {
        try await request(operation: operation, params: params, onChatSubmissionFailure: nil)
    }

    func request(operation: String, params: Data,
                 onChatSubmissionFailure: (@Sendable (ChatSubmissionFailureDiagnostic) -> Void)?) async throws -> Data {
        guard let values = try JSONSerialization.jsonObject(with: params) as? [String: String] else {
            throw Failure.invalidRequest
        }
        if operation == "webProviderStart" {
            return try await start(values)
        }
        let expectedKeys: Set<String> = operation == "webProviderSend" ? ["sessionToken", "prompt"] : ["sessionToken"]
        let cancellationKeys: Set<String> = ["sessionToken", "cleanupCause"]
        guard ["webProviderPoll", "webProviderSend", "webProviderFinish", "webProviderCancel"].contains(operation),
              Set(values.keys) == expectedKeys || operation == "webProviderCancel" && Set(values.keys) == cancellationKeys,
              let token = values["sessionToken"] else { throw Failure.staleSession }
        if ["webProviderFinish", "webProviderCancel"].contains(operation) {
            if let task = finishingTasks[token] { return await task.value }
            if let closed = closedSessions[token], ContinuousClock.now - closed.created < .seconds(3_600) { return closed.receipt }
        }
        guard let session = sessions[token] else { throw Failure.staleSession }
        if !["webProviderFinish", "webProviderCancel"].contains(operation), let failure = session.terminalFailure {
            throw failure
        }
        do {
            switch operation {
            case "webProviderFinish", "webProviderCancel":
                let cause = values["cleanupCause"].flatMap(WebModelCleanupCause.init(rawValue:)) ?? .cancelled
                return await finish(session, cancel: operation == "webProviderCancel", cleanupCause: cause)
            case "webProviderSend":
                guard !session.isDiscovery else { throw Failure.invalidRequest }
                try Task.checkCancellation()
                guard let prompt = values["prompt"], !prompt.isEmpty, prompt.utf8.count <= 180_000,
                      ["ready", "complete"].contains(session.state), !session.pendingSubmission else {
                    throw Failure.invalidRequest
                }
                // These pilot limits bound duplicated website context; they
                // are engineering guards, not measured provider context sizes.
                let submissionMarker = session.submitted && session.usesSubmissionOwnership
                    ? UUID().uuidString.lowercased() : session.firstUserMarker
                let outbound = !session.submitted || session.usesSubmissionOwnership
                    ? "\(prompt)\n\nComputa session marker: \(submissionMarker)" : prompt
                let outboundBytes = outbound.utf8.count
                guard outboundBytes <= 180_000 else { throw Failure.invalidRequest }
                if session.usesBoundedTurn {
                    guard session.sequence < Self.maximumTurnSubmissions,
                          outboundBytes <= Self.maximumTurnUTF8Bytes - session.submittedUTF8Count else {
                        throw Failure.turnLimit
                    }
                }
                if session.usesSubmissionOwnership, session.submitted {
                    // Re-prove the completed round before any preparation can
                    // focus or change the editor. Read-only remount recovery
                    // cannot become an insertion or Send retry.
                    guard session.currentSubmissionVerified, session.firstUserFingerprint != nil,
                          let binding = session.currentSubmission, binding.sequence == session.sequence,
                          session.confirmedUsers == session.sequence else {
                        throw Failure.ownershipFailure(.javaScriptSubmission)
                    }
                    let preflight = try await page(session, action: "inspect")
                    guard preflight["temporary"] as? Bool == true,
                          count(preflight, "userCount") == binding.sequence,
                          preflight["submissionOwnershipCapability"] as? String == Self.turnContinuationCapability,
                          let preflightProof = preflight["submissionProof"],
                          Self.validSubmissionProof(preflightProof,
                              sequence: binding.sequence, fingerprint: binding.outboundFingerprint) else {
                        throw Failure.ownershipFailure(.javaScriptSubmission)
                    }
                }
                // A first Instant insert can validate focus inside its existing
                // full precheck/final-proof pair. Other models and retained rounds keep
                // their separate preparation and observed response baseline.
                let prepareFirstInstantInInsert = canPrepareFirstInstantInInsert(session)
                if !prepareFirstInstantInInsert {
                    let before = try await page(session, action: "prepare",
                        recheckModelAfterAwait: session.provider != .chatgpt)
                    guard before["temporary"] as? Bool == true, session.temporary else { throw Failure.temporaryUnverified }
                    guard before["prepared"] as? Bool == true else { throw Failure.editorFailure("focus_unavailable") }
                    if !session.submitted {
                        guard count(before, "responseCount") == 0, count(before, "userCount") == 0,
                              session.provider.conversationURL(before["url"] as? String) == nil else { throw Failure.notFresh }
                    }
                    session.baseline = count(before, "responseCount")
                }
                if let benchmark = WebsiteBenchmarkCaptureLease.current, prepareFirstInstantInInsert,
                   canPrepareFirstInstantInInsert(session), session.provider == .chatgpt,
                   let choice = session.modelChoice, choice.key == "chat/latest/instant",
                   let generation = session.documentGeneration,
                   browser.webView(for: session.tabID) === session.view,
                   browser.documentGeneration(for: session.tabID) == generation,
                   let url = session.view.url, url.scheme == "https", url.host == "chatgpt.com", url.path == "/" {
                    let captureStarted = ContinuousClock.now
                    let saved = benchmark.capture(prompt: prompt, outbound: outbound, modelID: choice.modelID,
                        sessionToken: session.token, generation: generation, marker: submissionMarker,
                        nativeFirstFreshInstant: true)
                    if saved { session.benchmarkObservationBinding = benchmark.observationBinding }
                    let elapsed = WebsiteBenchmarkCaptureLease.milliseconds(.now - captureStarted)
                    Self.inspectionLog.notice("benchmarkPayloadCapture version=1 nonce=\(benchmark.nonce.uuidString.lowercased(), privacy: .public) saved=\(saved) elapsedMs=\(elapsed)")
                }
                // Each proof-capable round has a unique transport-only suffix.
                if session.usesSubmissionOwnership {
                    session.preparedSubmission = Session.SubmissionBinding(sequence: session.sequence + 1,
                        marker: submissionMarker, promptFingerprint: Self.promptFingerprint(prompt),
                        outboundFingerprint: Self.outboundFingerprint(outbound))
                }
                let inserted = try await page(session, action: "insert", prompt: outbound,
                    prepareFirstInstantInInsert: prepareFirstInstantInInsert)
                guard inserted["inserted"] as? Bool == true else { throw Failure.editorFailure("insertion_unconfirmed") }
                if prepareFirstInstantInInsert {
                    guard inserted["temporary"] as? Bool == true, session.temporary else { throw Failure.temporaryUnverified }
                    guard count(inserted, "responseCount") == 0, count(inserted, "userCount") == 0,
                          session.provider.conversationURL(inserted["url"] as? String) == nil else { throw Failure.notFresh }
                    session.baseline = 0
                }
                // Wait only through read-only checks. Site normalization can enable
                // Send later; insertion and the eventual click are never repeated.
                try await waitForSendReady(session, prompt: outbound)
                try Task.checkCancellation()
                session.response = ""
                session.responseCodeStructure = nil
                session.completionCandidate = false
                session.candidateSince = nil
                session.lastChanged = .now
                session.turnStarted = .now
                session.responseProfile = session.provider == .chatgpt
                    ? WebsiteResponseProfile.begin(source: .nativeTurn, sessionToken: session.token,
                        sequence: session.sequence + 1, started: session.turnStarted) : nil
                session.profiledFirstPositive = false
                session.profiledFirstCompletionCandidate = false
                session.profiledCompletionTransitions = 0
                session.responseReadRetryUsed = false
                session.failedPageDiagnosticAttempted = false
                session.resourceTimingSignatures.removeAll()
                session.responseProgressInspection = nil
                session.responseProgressEmitted = false
                // Claim submission before clicking: even a lost reply must not replay Send.
                session.submitted = true
                session.sequence += 1
                if session.usesSubmissionOwnership { session.submittedUTF8Count += outboundBytes }
                if session.provider == .chatgpt {
                    session.outboundUTF16Count = outbound.utf16.count
                    session.outboundUTF8Count = outbound.utf8.count
                    // Retained finite metadata makes healthy and failed rounds
                    // comparable. A native claim is not backend acceptance.
                    Self.inspectionLog.error("outboundSize provider=chatgpt sequence=\(session.sequence) claimed=true outboundUTF16Count=\(outbound.utf16.count) outboundUTF8Count=\(outbound.utf8.count)")
                }
                if session.usesSubmissionOwnership {
                    guard let binding = session.preparedSubmission, binding.sequence == session.sequence else { throw Failure.invalidRequest }
                    session.previousSubmission = session.currentSubmission
                    session.currentSubmission = binding
                    session.currentSubmissionVerified = false
                }
                session.pendingSubmission = true
                session.modelVerificationPending = session.provider == .chatgpt
                    && session.modelSelectionVerified && session.modelChoice != nil
                session.loggedPendingModelVerification = false
                session.state = "running"
                let submittedSequence = session.sequence
                let sent = try await page(session, action: "submit", prompt: outbound)
                guard sent["submitted"] as? Bool == true else { throw Failure.editorFailure("submission_unconfirmed") }
                session.acknowledgedSendSequence = submittedSequence
                // Prepare the next untouched page during website generation,
                // never while the current request is still preparing to Send.
                if session.provider == .chatgpt, chatGPTPrewarmingEnabled {
                    browser.prepareChatGPTInferencePrewarmIfNeeded()
                }
                return try snapshot(session)
            default:
                return try await poll(session)
            }
        } catch {
            logResponseProgressFailure(session, cause: error is CancellationError ? "cancelled"
                : (error as? Failure) == .deadline ? "response_deadline" : "request_error")
            // Recognized website gates are terminal for this inference. Even a
            // caller that keeps polling cannot inspect, insert, or Send again.
            // Finish still uses the original ownership/cleanup checks.
            if let failure = error as? Failure, failure.diagnosticCode != nil {
                _ = recordedWebsiteBlocker(failure, session: session)
                session.terminalFailure = failure
                session.state = "failed"
                session.initialReadRetry = nil
            }
            // This callback belongs to this original request's returned error,
            // not a queued phase notification or a later cleanup inspection.
            if !Task.isCancelled, let onChatSubmissionFailure,
               (error as? Failure) == .ownershipFailure(.javaScriptSubmission),
               session.provider == .chatgpt, let saved = session.firstChatSubmissionFailure,
               saved.sequence == session.sequence, sessions[session.token] === session,
               browser.webView(for: session.tabID) === session.view,
               browser.documentGeneration(for: session.tabID) == saved.generation {
                session.firstChatSubmissionFailure = nil
                onChatSubmissionFailure(saved.diagnostic)
            }
            throw error
        }
    }

    func changeRevision(sessionToken: String) async throws -> UInt64? {
        guard let session = sessions[sessionToken] else { throw Failure.staleSession }
        return try browser.modelChangeRevision(for: session.tabID)
    }

    private func recordProviderGate(_ error: Error, provider: Provider) {
        guard let failure = error as? Failure, failure.blocksProviderUntilRefresh else { return }
        // Propagation of the same gate is not a new website observation and
        // must not invalidate a successful recovery already in progress.
        guard providerGates[provider]?.failure != failure else { return }
        if case .humanVerificationRequired = failure {
            browser.recordHumanVerificationRequired(provider: provider.rawValue)
        }
        providerGates[provider] = ProviderGate(failure: failure)
        if provider == .chatgpt {
            browser.setChatGPTInferencePrewarmingEnabled(false, admit: { throw failure })
        }
        for session in sessions.values where session.provider == provider && !session.isRecoveryProbe {
            if session.terminalFailure == nil { session.terminalFailure = failure }
            session.state = "failed"
            session.initialReadRetry = nil
            browser.notifyModelSessionChange(tabID: session.tabID)
        }
    }

    private func synchronizeProviderGate(_ provider: Provider) {
        if browser.savedHumanVerificationProviders.contains(provider.rawValue) {
            recordProviderGate(Failure.humanVerificationRequired(provider), provider: provider)
        }
    }

    private func recordedWebsiteBlocker(_ failure: Failure, session: Session) -> Failure {
        // Cleanup may inspect an old failed page after an explicit recovery.
        // Its already-latched failure cannot invalidate that newer recovery.
        if session.terminalFailure != failure { recordProviderGate(failure, provider: session.provider) }
        return failure
    }

    private func checkProviderGate(_ session: Session) throws {
        synchronizeProviderGate(session.provider)
        if let failure = session.terminalFailure { throw failure }
        if !session.isRecoveryProbe, let gate = providerGates[session.provider] { throw gate.failure }
    }

    private func createSession(provider: Provider, choice: WebsiteModelChoice?, isDiscovery: Bool,
                               isRecoveryProbe: Bool = false, requestMetadata: ChatGPTRequestMetadataLease? = nil,
                               preparedTab: UUID? = nil, reservedStart: Bool = false) throws -> Session {
        closedSessions = closedSessions.filter { ContinuousClock.now - $0.value.created < .seconds(3_600) }
        synchronizeProviderGate(provider)
        if !isRecoveryProbe, let gate = providerGates[provider] { throw gate.failure }
        let admitted = sessions.values.filter { $0.isDiscovery == isDiscovery }.count
        let pending = pendingInferenceStarts + browser.failedChatGPTInferenceCookiePreparationCount
        let capacity = admitted + (isDiscovery ? 0 : pending)
        guard capacity < (isDiscovery ? 1 : 4) || reservedStart && !isDiscovery && capacity <= 4 else { throw Failure.capacity }
        guard script(for: provider) != nil else { throw Failure.pageUnavailable }
        let id: UUID
        if let preparedTab { id = preparedTab }
        else if let requestMetadata, provider == .chatgpt, !isDiscovery, !isRecoveryProbe {
            id = try browser.createModelTab(url: provider.startURL, requestMetadata: requestMetadata)
        } else { id = try createTab(provider.startURL) }
        guard let view = browser.webView(for: id), let generation = browser.documentGeneration(for: id) else { throw Failure.staleSession }
        let session = Session(provider: provider, tabID: id, view: view, documentGeneration: generation,
                              modelChoice: choice, isDiscovery: isDiscovery, isRecoveryProbe: isRecoveryProbe)
        do { try browser.installModelChangeSignal(tabID: id, ownerToken: session.token, world: world, originHost: provider.host) }
        catch { browser.closeTab(id); throw error }
        sessions[session.token] = session
        if let proof = browser.chatGPTInferenceCookieSummary(tabID: id, view: view) {
            Self.inspectionLog.info("inferenceCookieSeed policyVersion=1 isolatedStoreVerified=true destinationVerified=true sourceMutations=0 sequence=0 sourceCookieCount=\(proof.sourceCookieCount) eligibleCookieCount=\(proof.eligibleCookieCount) excludedConversationCookieCount=\(proof.excludedConversationCookieCount) seededCookieCount=\(proof.seededCookieCount) profileEstimateAvailable=\(proof.estimatedCookieHeaderUTF8Bytes != nil) estimatedCookieHeaderUTF8Bytes=\(proof.estimatedCookieHeaderUTF8Bytes ?? -1)")
        }
        return session
    }

    /// Read available choices on an empty owned page, without sending a prompt.
    func discoverModels(provider rawProvider: String, retryBlocked: Bool = false,
                        recoveryCandidateIsCurrent: (@MainActor () -> Bool)? = nil) async throws -> [WebsiteModelChoice] {
        try Task.checkCancellation()
        guard let provider = Provider(rawValue: rawProvider) else { throw Failure.unsupportedProvider }
        guard recoveryCandidateIsCurrent?() != false else { throw CancellationError() }
        // An explicit refresh or validated human recovery can probe a blocked
        // provider. Keep its gate in place until this prompt-free check succeeds.
        synchronizeProviderGate(provider)
        let previousGateID = providerGates[provider]?.id
        let previousVerificationID = browser.savedHumanVerificationCheckpointIDs[provider.rawValue]
        if provider == .chatgpt {
            guard await browser.admitChatGPTAfterCookieCallbacks(until: .now + .seconds(2)) else { throw Failure.cookieMaintenancePending }
            try Task.checkCancellation()
        }
        let session = try createSession(provider: provider, choice: nil, isDiscovery: true, isRecoveryProbe: retryBlocked)
        let token = session.token
        var closed = false
        do {
            let deadline = session.created + preparationTimeout
            while session.state != "ready" {
                try Task.checkCancellation()
                let revision = try browser.modelChangeRevision(for: session.tabID)
                _ = try await poll(session)
                guard ContinuousClock.now < deadline else { throw preparationFailure(session) }
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
                        guard model.isObservedChoice else { throw Failure.modelUnverified }
                        return model
                    }
                    guard Set(parsed.map(\.key)).count == parsed.count, Set(parsed.map(\.label)).count == parsed.count else { throw Failure.modelUnverified }
                    let cleanup = await finish(session, cancel: false)
                    guard let receipt = try JSONSerialization.jsonObject(with: cleanup) as? [String: Any],
                          receipt["cleanup"] as? String == "not_created" else { throw Failure.modelUnverified }
                    closed = true
                    if let gate = providerGates[provider], gate.id != previousGateID {
                        // A newer failure from another inference takes precedence;
                        // do not report recovery while new tasks remain blocked.
                        throw gate.failure
                    }
                    if browser.savedHumanVerificationCheckpointIDs[provider.rawValue] != previousVerificationID {
                        // A human tab can observe a new checkpoint while this
                        // read-only recovery awaits. Never erase that observation.
                        throw Failure.humanVerificationRequired(provider)
                    }
                    try Task.checkCancellation()
                    guard recoveryCandidateIsCurrent?() != false else { throw CancellationError() }
                    try Task.checkCancellation()
                    if retryBlocked {
                        browser.clearHumanVerificationRequired(provider: provider.rawValue)
                        providerGates.removeValue(forKey: provider)
                    }
                    return parsed
                }
                _ = try await waitForChange(sessionToken: token, after: revision, until: deadline)
            }
            throw preparationFailure(session)
        } catch {
            recordProviderGate(error, provider: provider)
            if closed { throw error }
            let cleanup = await finish(session, cancel: true)
            guard let result = try? JSONSerialization.jsonObject(with: cleanup) as? [String: Any],
                  result["cleanup"] as? String == "not_created" else { throw Failure.discoveryCleanupFailed }
            throw error
        }
    }

    func waitForChange(sessionToken: String, after revision: UInt64,
                       until deadline: ContinuousClock.Instant) async throws -> UInt64? {
        guard let session = sessions[sessionToken] else { throw Failure.staleSession }
        try checkProviderGate(session)
        var wake = deadline
        if session.state == "loading" { wake = min(wake, session.created + preparationTimeout) }
        else if session.state == "running" { wake = min(wake, session.turnStarted + responseTimeout) }
        if session.state == "running", session.completionCandidate, let since = session.candidateSince {
            wake = min(wake, max(since, session.lastChanged) + .milliseconds(1_600))
        }
        if let retry = session.initialReadRetry { wake = min(wake, retry) }
        if let settlement = session.initialCheckpointSettlement, !settlement.finished {
            wake = min(wake, settlement.deadline)
        }
        let profileQuietWait = session.state == "running" && session.completionCandidate && session.candidateSince != nil
        if profileQuietWait { session.profileCompletionTransition(.quietWaitStarted) }
        let changed: UInt64
        do {
            defer { if profileQuietWait { session.profileCompletionTransition(.quietWaitFinished) } }
            changed = try await browser.waitForModelChange(tabID: session.tabID, after: revision, until: wake)
        }
        try checkProviderGate(session)
        return changed
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

    private func preparationFailure(_ session: Session) -> Failure {
        let diagnostic = browser.modelDiagnosticSnapshot(tabID: session.tabID)
        Self.inspectionLog.error("preparationTimeout provider=\(session.provider.rawValue, privacy: .public) \(diagnostic, privacy: .public)")
        return .preparationDeadline
    }

    /// An abort-only observation, separate from inference and cleanup proofs.
    /// A queued WebContent operation cannot extend this one-second budget or
    /// publish after the exact owned view/document/session has changed.
    private func logFailedPageDiagnostic(_ session: Session) async {
        guard session.provider == .chatgpt, session.state == "running", session.submitted,
              !session.failedPageDiagnosticAttempted, !Task.isCancelled else { return }
        session.failedPageDiagnosticAttempted = true
        let sequence = session.sequence
        let outboundUTF16Count = session.outboundUTF16Count ?? -1
        let outboundUTF8Count = session.outboundUTF8Count ?? -1
        let ownedGeneration = session.documentGeneration ?? session.initialDocumentGeneration
        let url = session.view.url
        func current() -> Bool {
            sessions[session.token] === session && session.sequence == sequence && session.state == "running"
                && browser.webView(for: session.tabID) === session.view
                && browser.documentGeneration(for: session.tabID) == ownedGeneration
                && session.view.url == url && url.map { session.provider.accepts($0.absoluteString) } == true
        }
        func unavailable(_ category: String) {
            Self.inspectionLog.error("failedPageDiagnostic provider=chatgpt sequence=\(sequence) result=\(category, privacy: .public) outboundUTF16Count=\(outboundUTF16Count) outboundUTF8Count=\(outboundUTF8Count)")
            #if DEBUG
            failedPageDiagnosticObserverForTesting?(category)
            #endif
        }
        guard current(), let url, let script = script(for: .chatgpt) else { unavailable("stale"); return }
        let deadline = ContinuousClock.now + .seconds(1)
        let result = EmbeddedScriptResult()
        do {
            let bytes = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    result.install(continuation)
                    let timer = Task {
                        do {
                            try await Task.sleep(until: deadline, clock: .continuous)
                            result.complete(.failure(Failure.pageUnavailable))
                        } catch { }
                    }
                    result.setTimeout(timer)
                    guard result.isPending else { return }
                    // No model/menu reads, first-message expansion or owner
                    // binding. The fixed adapter returns before any async work.
                    let input: [String: Any] = ["provider": "chatgpt", "action": "failedPageDiagnostic",
                        "expectedURL": url.absoluteString, "ownerToken": session.token, "bindOwner": false]
                    session.providerAdapterEverDispatched = true
                    session.view.callAsyncJavaScript(script, arguments: ["input": input], in: nil, in: world) { reply in
                        switch reply {
                        case .success(let value):
                            do { result.complete(.success(try JSONSerialization.data(withJSONObject: value))) }
                            catch { result.complete(.failure(Failure.pageUnavailable)) }
                        case .failure:
                            result.complete(.failure(Failure.pageUnavailable))
                        }
                    }
                }
            } onCancel: { result.complete(.failure(CancellationError())) }
            #if DEBUG
            await beforePageResultValidationForTesting?("failedPageDiagnostic")
            #endif
            guard !Task.isCancelled, ContinuousClock.now < deadline else { unavailable("timed_out"); return }
            guard current() else { unavailable("stale"); return }
            guard bytes.count <= 8_192,
                  let observed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], observed["error"] == nil,
                  let raw = observed["failureDiagnostic"] as? [String: Any],
                  let safe = Self.sanitizedFailedPageDiagnostic(raw) else { unavailable("unavailable"); return }
            logResourceTimingDiagnostic(observed["resourceTimingDiagnostic"], session: session, phase: "failure")
            #if DEBUG
            failedPageDiagnosticObserverForTesting?(safe)
            #endif
            // Use bounded chunks to avoid Unified Logging truncating a finite
            // structure; no page strings or identifiers enter this projection.
            let data = Data(safe.utf8), identifier = UUID().uuidString
            let chunks = stride(from: 0, to: data.count, by: 512).map { offset in
                data.subdata(in: offset..<min(offset + 512, data.count)).base64EncodedString()
            }
            for (index, chunk) in chunks.enumerated() {
                Self.inspectionLog.error("failedPageDiagnostic provider=chatgpt sequence=\(sequence) id=\(identifier, privacy: .public) part=\(index + 1)/\(chunks.count) base64=\(chunk, privacy: .public)")
            }
        } catch {
            unavailable(ContinuousClock.now >= deadline ? "timed_out" : "unavailable")
        }
    }

    /// Relationship observations only. No strings, identity or response authority.
    static func sanitizedResponseNoticeDiagnostic(_ raw: Any?) -> String? {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["kind", "retryCount", "observationsTruncated", "observations"],
              value["kind"] as? String == "chatgpt_response_notice_v1" else { return nil }
        func integer(_ raw: Any?, maximum: Int) -> Int? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  (0...Double(maximum)).contains(number.doubleValue) else { return nil }
            return number.intValue
        }
        guard let count = integer(value["retryCount"], maximum: 10_000),
              let truncated = firstUserDiagnosticBool(value["observationsTruncated"]), truncated == (count > 2),
              let observations = value["observations"] as? [[String: Any]], observations.count == min(count, 2) else { return nil }
        let keys: Set<String> = ["excludedAncestor", "contentExcluded", "retryEnabled", "noticeRole", "pairing",
                                 "sameWidget", "knownError", "labelStructure", "labelScanTruncated"]
        var projected: [[String: Any]] = []
        for observation in observations {
            guard Set(observation.keys) == keys,
                  let ancestor = observation["excludedAncestor"] as? String,
                  ["none", "menu", "dialog", "nav", "aside"].contains(ancestor),
                  let role = observation["noticeRole"] as? String, ["none", "alert", "status"].contains(role),
                  let pairing = observation["pairing"] as? String, ["none", "ambiguous", "ancestor", "shared_parent"].contains(pairing),
                  let known = observation["knownError"] as? String, ["none", "unknown", "load_failed"].contains(known),
                  let structure = observation["labelStructure"] as? String, ["none", "leaf", "nested", "multiple"].contains(structure),
                  let excluded = firstUserDiagnosticBool(observation["contentExcluded"]),
                  let enabled = firstUserDiagnosticBool(observation["retryEnabled"]),
                  let sameWidget = firstUserDiagnosticBool(observation["sameWidget"]),
                  let scanTruncated = firstUserDiagnosticBool(observation["labelScanTruncated"]),
                  sameWidget == ["ancestor", "shared_parent"].contains(pairing),
                  sameWidget == (role != "none"), sameWidget == (known != "none"),
                  (known == "load_failed") == (structure != "none"),
                  !scanTruncated || (sameWidget && known == "unknown" && structure == "none"),
                  !(excluded || ["menu", "nav", "aside"].contains(ancestor)) || pairing == "none" else { return nil }
            projected.append(["excludedAncestor": ancestor, "contentExcluded": excluded, "retryEnabled": enabled,
                              "noticeRole": role, "pairing": pairing, "sameWidget": sameWidget,
                              "knownError": known, "labelStructure": structure, "labelScanTruncated": scanTruncated])
        }
        let safe: [String: Any] = ["kind": "chatgpt_response_notice_v1", "retryCount": count,
                                   "observationsTruncated": truncated, "observations": projected]
        guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), bytes.count <= 768 else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Fixed rendering counts only. This projection cannot establish answer
    /// ownership, completion or content, and never retains page strings.
    static func sanitizedAnswerScopeDiagnostic(_ raw: Any?) -> String? {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["kind", "rootPresent", "bodyPresent", "rootTextLength", "bodyTextLength",
                                  "rootChildren", "bodyChildren"],
              value["kind"] as? String == "chatgpt_answer_scope_v1",
              let rootPresent = firstUserDiagnosticBool(value["rootPresent"]),
              let bodyPresent = firstUserDiagnosticBool(value["bodyPresent"]) else { return nil }
        var safe: [String: Any] = ["kind": "chatgpt_answer_scope_v1",
                                   "rootPresent": rootPresent, "bodyPresent": bodyPresent]
        for (key, maximum): (String, Int64) in [("rootTextLength", 220_001), ("bodyTextLength", 220_001),
                                              ("rootChildren", 1_000), ("bodyChildren", 1_000)] {
            guard let count = ComputerToolArgumentContract.exactInt64(value[key]),
                  (0...maximum).contains(count) else { return nil }
            safe[key] = count
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys),
              bytes.count <= 512 else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func sanitizedFailedPageDiagnostic(_ value: [String: Any]) -> String? {
        guard value["kind"] as? String == "chatgpt_failed_page_v1",
              let route = value["route"] as? String, ["root", "local_conversation", "server_conversation", "other"].contains(route),
              let category = value["errorCategory"] as? String,
              ["none", "load_failed", "sign_in_required", "unrecognized_notice"].contains(category) else { return nil }
        func integer(_ raw: Any?, maximum: Int) -> Int? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  (0...Double(maximum)).contains(number.doubleValue) else { return nil }
            return number.intValue
        }
        var safe: [String: Any] = ["kind": "chatgpt_failed_page_v1", "route": route, "errorCategory": category]
        if let rawNotice = value["responseNoticeDiagnostic"] {
            guard let encoded = sanitizedResponseNoticeDiagnostic(rawNotice),
                  let projected = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else { return nil }
            safe["responseNoticeDiagnostic"] = projected
        }
        let sizeKeys = ["outboundUTF16Count", "outboundUTF8Count"]
        if sizeKeys.contains(where: { value[$0] != nil }) {
            if value[sizeKeys[0]] is NSNull, value[sizeKeys[1]] is NSNull {
                safe[sizeKeys[0]] = NSNull(); safe[sizeKeys[1]] = NSNull()
            } else {
                guard let utf16 = integer(value[sizeKeys[0]], maximum: 180_200),
                      let utf8 = integer(value[sizeKeys[1]], maximum: 720_800),
                      utf8 >= utf16, utf8 <= 3 * utf16 else { return nil }
                safe[sizeKeys[0]] = utf16; safe[sizeKeys[1]] = utf8
            }
        }
        for key in ["modernUsers", "legacyUsers", "modernAssistants", "legacyAssistants"] {
            guard let roots = value[key] as? [String: Any], let connected = integer(roots["connected"], maximum: 10_000),
                  let visible = integer(roots["visible"], maximum: connected) else { return nil }
            safe[key] = ["connected": connected, "visible": visible]
        }
        for key in ["stopPresent", "composerPresent", "composerEnabled", "copyPresent", "copyEnabled",
                    "retryPresent", "retryInsideUserMessage", "retryInsideAssistantMessage", "retryInsideCodeOrEditor",
                    "retryInsideMenuOrNavigation", "retryOutsideExcludedContent",
                    "temporaryRendered", "temporaryVerified", "noticesTruncated"] {
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }
            safe[key] = flag
        }
        guard !(safe["composerEnabled"] as? Bool == true && safe["composerPresent"] as? Bool != true),
              !(safe["copyEnabled"] as? Bool == true && safe["copyPresent"] as? Bool != true),
              !(safe["temporaryVerified"] as? Bool == true && safe["temporaryRendered"] as? Bool != true) else { return nil }
        if safe["retryPresent"] as? Bool != true,
           ["retryInsideUserMessage", "retryInsideAssistantMessage", "retryInsideCodeOrEditor",
            "retryInsideMenuOrNavigation", "retryOutsideExcludedContent"].contains(where: { safe[$0] as? Bool == true }) { return nil }
        for (countKey, lengthsKey) in [("alertCount", "alertTextLengths"), ("statusCount", "statusTextLengths")] {
            guard let count = integer(value[countKey], maximum: 10_000), let raw = value[lengthsKey] as? [Any],
                  raw.count == min(count, 8) else { return nil }
            let lengths = raw.compactMap { integer($0, maximum: 220_001) }
            guard lengths.count == raw.count else { return nil }
            safe[countKey] = count; safe[lengthsKey] = lengths
        }
        guard safe["noticesTruncated"] as? Bool == ((safe["alertCount"] as? Int ?? 0) > 8 || (safe["statusCount"] as? Int ?? 0) > 8),
              let bytes = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), bytes.count <= 2_048 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// Only ended resource observations, never dispatch, upload or acceptance proof.
    static func sanitizedResourceTimingDiagnostic(_ raw: Any?, phase: String, sequence: Int) -> String? {
        let keys: Set<String> = ["kind", "phase", "sequence", "available", "sendMarkAvailable", "scanTruncated",
                                 "scannedCount", "conversationCount", "preparationCount", "observations",
                                 "observationsTruncated", "absenceInconclusive"]
        guard ["send", "completion", "failure"].contains(phase), (1...10_000).contains(sequence),
              let value = raw as? [String: Any], Set(value.keys) == keys,
              value["kind"] as? String == "chatgpt_resource_timing_v1", value["phase"] as? String == phase,
              ComputerToolArgumentContract.exactInt64(value["sequence"]) == Int64(sequence) else { return nil }
        func integer(_ raw: Any?, maximum: Int64) -> Int? {
            guard let number = ComputerToolArgumentContract.exactInt64(raw), (0...maximum).contains(number) else { return nil }
            return Int(number)
        }
        var safe: [String: Any] = ["kind": "chatgpt_resource_timing_v1", "phase": phase, "sequence": sequence]
        for key in ["available", "sendMarkAvailable", "scanTruncated", "observationsTruncated", "absenceInconclusive"] {
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }; safe[key] = flag
        }
        guard safe["absenceInconclusive"] as? Bool == true,
              let scanned = integer(value["scannedCount"], maximum: 256),
              let conversation = integer(value["conversationCount"], maximum: 256),
              let preparation = integer(value["preparationCount"], maximum: 256), conversation + preparation <= scanned,
              let observations = value["observations"] as? [[String: Any]], observations.count == min(conversation + preparation, 4),
              safe["observationsTruncated"] as? Bool == (conversation + preparation > 4),
              !(safe["scanTruncated"] as? Bool == true && scanned != 256) else { return nil }
        if safe["available"] as? Bool != true || safe["sendMarkAvailable"] as? Bool != true {
            guard scanned == 0, conversation == 0, preparation == 0, safe["scanTruncated"] as? Bool == false else { return nil }
        }
        let sampleKeys: Set<String> = ["endpoint", "initiator", "startOffsetMs", "durationMs", "transferBytes",
                                       "encodedBodyBytes", "decodedBodyBytes", "responseStatusAvailable", "responseStatus"]
        var samples: [[String: Any]] = []
        for sample in observations {
            guard Set(sample.keys) == sampleKeys, let endpoint = sample["endpoint"] as? String,
                  ["conversation", "preparation"].contains(endpoint), let initiator = sample["initiator"] as? String,
                  ["fetch", "xmlhttprequest", "other"].contains(initiator),
                  let statusAvailable = firstUserDiagnosticBool(sample["responseStatusAvailable"]) else { return nil }
            var projected: [String: Any] = ["endpoint": endpoint, "initiator": initiator, "responseStatusAvailable": statusAvailable]
            for key in ["startOffsetMs", "durationMs", "transferBytes", "encodedBodyBytes", "decodedBodyBytes"] {
                guard let number = integer(sample[key], maximum: key.hasSuffix("Ms") ? 3_600_000 : 2_147_483_647) else { return nil }
                projected[key] = number
            }
            if statusAvailable {
                guard let status = integer(sample["responseStatus"], maximum: 599) else { return nil }; projected["responseStatus"] = status
            } else {
                guard sample["responseStatus"] is NSNull else { return nil }; projected["responseStatus"] = NSNull()
            }
            samples.append(projected)
        }
        guard samples.filter({ $0["endpoint"] as? String == "conversation" }).count <= conversation,
              samples.filter({ $0["endpoint"] as? String == "preparation" }).count <= preparation else { return nil }
        safe["scannedCount"] = scanned; safe["conversationCount"] = conversation; safe["preparationCount"] = preparation
        safe["observations"] = samples
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), data.count <= 2_048 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func logResourceTimingDiagnostic(_ raw: Any?, session: Session, phase: String) {
        guard session.provider == .chatgpt, session.state == "running", session.submitted,
              sessions[session.token] === session, browser.webView(for: session.tabID) === session.view,
              browser.documentGeneration(for: session.tabID) == (session.documentGeneration ?? session.initialDocumentGeneration),
              session.view.url.map({ session.provider.accepts($0.absoluteString) }) == true,
              let safe = Self.sanitizedResourceTimingDiagnostic(raw, phase: phase, sequence: session.sequence),
              session.resourceTimingSignatures[phase] == nil else { return }
        session.resourceTimingSignatures[phase] = safe
        #if DEBUG
        resourceTimingDiagnosticObserverForTesting?(safe)
        #endif
        let data = Data(safe.utf8), identifier = UUID().uuidString
        let chunks = stride(from: 0, to: data.count, by: 512).map {
            data.subdata(in: $0..<min($0 + 512, data.count)).base64EncodedString()
        }
        for (index, chunk) in chunks.enumerated() {
            Self.inspectionLog.error("resourceTimingDiagnostic provider=chatgpt sequence=\(session.sequence) phase=\(phase, privacy: .public) id=\(identifier, privacy: .public) part=\(index + 1)/\(chunks.count) base64=\(chunk, privacy: .public)")
        }
    }

    private enum InitialCheckpointPhase: String {
        case waitStarted = "wait_started"
        case providerRouteObserved = "provider_route_observed"
        case nativeStateRejected = "native_state_rejected"
        case foreignRouteObserved = "foreign_route_observed"
        case authorityRejected = "authority_rejected"
        case budgetExpired = "budget_expired"
        case preparationExpired = "preparation_expired"
        case cancelled, finished
    }

    private func initialCheckpointRoute(_ session: Session) -> String {
        guard let url = session.view.url else { return "unknown" }
        if session.provider.blockingFailure(for: url) == .humanVerificationRequired(.gemini) {
            return "google_verification"
        }
        return session.provider.accepts(url.absoluteString) ? "provider" : "other"
    }

    /// Native observations only. No URL, document content, identity or input.
    private func logInitialCheckpointSettlement(_ session: Session, phase: InitialCheckpointPhase) {
        guard let window = session.initialCheckpointSettlement else { return }
        let facts = browser.modelNavigationDiagnostic(tabID: session.tabID, view: session.view)
        let record: [String: Any] = [
            "kind": "gemini_initial_checkpoint_settlement_v1", "phase": phase.rawValue,
            "routeClass": initialCheckpointRoute(session), "observations": window.observations,
            "maximumMilliseconds": 3_000, "originalPreparationDeadlineRetained": true,
            "nativeFactsAvailable": facts != nil,
            "committed": facts.map { $0.generationCommitted as Any } ?? NSNull(),
            "finished": facts.map { $0.generationFinished as Any } ?? NSNull(),
            "loading": facts.map { $0.viewLoading as Any } ?? NSNull(),
            "navigationPending": facts.map { $0.navigationPending as Any } ?? NSNull(),
            "navigationError": facts.map { $0.navigationError as Any } ?? NSNull(),
            "geminiCommitObserved": facts.map { $0.geminiDocumentCommitObserved as Any } ?? NSNull(),
            "serverRedirectObserved": facts.map { $0.serverRedirectObservedInCurrentNavigation as Any } ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys), data.count <= 768 else { return }
        #if DEBUG
        initialCheckpointSettlementObserverForTesting?(record)
        #endif
        let safe = String(decoding: data, as: UTF8.self)
        Self.inspectionLog.error("initialCheckpointSettlement provider=gemini \(safe, privacy: .public)")
    }

    private func finishInitialCheckpointSettlement(_ session: Session, phase: InitialCheckpointPhase) {
        guard session.initialCheckpointSettlement?.finished == false else { return }
        session.initialCheckpointSettlement?.finished = true
        logInitialCheckpointSettlement(session, phase: phase)
    }

    /// Observe this existing initial navigation for at most three seconds.
    /// A committed but unfinished Google checkpoint may finish naturally; no
    /// provider adapter, prompt, refresh or challenge action is permitted here.
    private func waitForInitialCheckpointSettlement(_ session: Session) throws -> Bool {
        guard session.state == "loading", session.terminalFailure == nil, isUntouchedInference(session),
              sessions[session.token] === session, browser.webView(for: session.tabID) === session.view else {
            finishInitialCheckpointSettlement(session, phase: .authorityRejected)
            return false
        }
        guard session.initialCheckpointSettlement?.finished != true else { return false }
        let route = initialCheckpointRoute(session)
        // This experiment cannot postpone a gate saved by another session or
        // human tab, including when a native navigation has changed the route.
        if session.initialCheckpointSettlement != nil || route == "google_verification" {
            do { try checkProviderGate(session) }
            catch {
                finishInitialCheckpointSettlement(session, phase: .authorityRejected)
                throw error
            }
        }
        let now = ContinuousClock.now
        if session.initialCheckpointSettlement != nil, now >= session.created + preparationTimeout {
            finishInitialCheckpointSettlement(session, phase: .preparationExpired)
            throw preparationFailure(session)
        }
        if let window = session.initialCheckpointSettlement, now >= window.deadline {
            finishInitialCheckpointSettlement(session, phase: .budgetExpired)
            // A current Google route still takes the original blocker below.
            // Do not label a late provider/foreign route as a Google checkpoint.
            if route != "google_verification" { throw preparationFailure(session) }
            return false
        }
        guard route == "google_verification" else {
            finishInitialCheckpointSettlement(session,
                phase: route == "provider" ? .providerRouteObserved : .foreignRouteObserved)
            return false
        }
        guard let facts = browser.modelNavigationDiagnostic(tabID: session.tabID, view: session.view),
              facts.viewLoading, facts.tabLoading, facts.navigationPending,
              !facts.generationFinished, !facts.navigationError, !facts.geminiDocumentCommitObserved else {
            finishInitialCheckpointSettlement(session, phase: .nativeStateRejected)
            return false
        }
        let first = session.initialCheckpointSettlement == nil
        if first {
            session.initialCheckpointSettlement = .init(deadline: min(now + initialCheckpointSettlementTimeout,
                session.created + preparationTimeout))
        }
        if var window = session.initialCheckpointSettlement {
            window.observations = min(10_000, window.observations + 1)
            session.initialCheckpointSettlement = window
        }
        if now >= session.created + preparationTimeout {
            finishInitialCheckpointSettlement(session, phase: .preparationExpired)
            throw preparationFailure(session)
        }
        if first { logInitialCheckpointSettlement(session, phase: .waitStarted) }
        return true
    }

    private func canRecoverPendingFirstBodyRead(_ session: Session) -> Bool {
        guard !Task.isCancelled, session.provider == .chatgpt, !session.isDiscovery, !session.isRecoveryProbe,
              sessions[session.token] === session, session.terminalFailure == nil,
              session.state == "running", session.submitted, session.sequence == 1,
              session.acknowledgedSendSequence == 1, session.confirmedUsers == 0,
              session.pendingSubmission, session.firstUserFingerprint == nil, !session.currentSubmissionVerified,
              session.temporaryRequested, session.temporary,
              session.productModeEvidence?.temporaryTransition == .acknowledged,
              session.modelSelectionVerified, session.modelChoice != nil,
              let prepared = session.preparedSubmission, let current = session.currentSubmission,
              prepared.sequence == 1, current.sequence == 1,
              prepared.marker == session.firstUserMarker, prepared.marker == current.marker,
              !prepared.promptFingerprint.isEmpty, prepared.promptFingerprint == current.promptFingerprint,
              !prepared.outboundFingerprint.isEmpty, prepared.outboundFingerprint == current.outboundFingerprint,
              let generation = session.documentGeneration,
              browser.webView(for: session.tabID) === session.view,
              browser.documentGeneration(for: session.tabID) == generation else { return false }
        return true
    }

    private func poll(_ session: Session) async throws -> Data {
        try Task.checkCancellation()
        guard ["loading", "running"].contains(session.state) else { return try snapshot(session) }
        guard browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
        if try waitForInitialCheckpointSettlement(session) {
            session.initialReadRetry = nil
            return try snapshot(session)
        }
        try rejectWebsiteBlocker(session, action: "inspect", phase: "before")
        if session.state == "loading", session.view.isLoading {
            session.initialReadRetry = nil
            guard ContinuousClock.now - session.created < preparationTimeout else { throw preparationFailure(session) }
            return try snapshot(session)
        }
        let timeoutFailure: Failure = session.state == "loading" ? .preparationDeadline : .deadline
        let deadline = session.state == "loading" ? session.created + preparationTimeout : session.turnStarted + responseTimeout
        guard ContinuousClock.now < deadline else { throw session.state == "loading" ? preparationFailure(session) : timeoutFailure }
        let observed: [String: Any]
        let readTimeoutCount = session.readTimeoutCount
        // WebKit may queue an inspection while the provider renders its reply.
        // The adapter's own waits remain bounded; allow queue time without
        // extending the inference's preparation or response deadline.
        do { observed = try await page(session, action: "inspect", maximumWait: min(inspectionTimeout, deadline - .now)) }
        catch {
            if let failure = error as? Failure, failure.diagnosticCode != nil { throw failure }
            if !Task.isCancelled, ContinuousClock.now >= deadline { throw session.state == "loading" ? preparationFailure(session) : timeoutFailure }
            if (error as? Failure) == .submissionObservationPending {
                try Task.checkCancellation()
                // The fixed adapter discarded a read crossed only by the
                // already-claimed submission's asynchronous user append. No
                // observation is admitted; the versioned DOM signal wakes a
                // fresh read which recomputes every ownership proof.
                return try snapshot(session)
            }
            if (error as? Failure) == .pageUnavailable,
               session.readTimeoutCount > readTimeoutCount, !session.responseReadRetryUsed,
               session.state == "running", session.submitted, session.temporary,
               session.firstUserFingerprint != nil, !session.pendingSubmission {
                // A route promotion or queued context read can consume one
                // inspection budget after owned lineage is already bound.
                // Discard that observation and make one fresh read within the
                // unchanged response deadline. No insertion, Send, model
                // selection or expansion action may be replayed here.
                session.responseReadRetryUsed = true
                Self.inspectionLog.info("inspectionReadRecovery provider=\(session.provider.rawValue, privacy: .public) sequence=\(session.sequence) retry=1 reason=bound_read_timeout")
                return try await poll(session)
            }
            if (error as? Failure) == .pageUnavailable,
               session.readTimeoutCount > readTimeoutCount, !session.responseReadRetryUsed,
               canRecoverPendingFirstBodyRead(session) {
                // Observe once more after an acknowledged first Send. The new
                // invocation cannot acquire a fresh display-expansion claim;
                // every body, owner, model and route proof is still recomputed.
                session.responseReadRetryUsed = true
                session.firstBodyReadRecoveryActive = true
                defer { session.firstBodyReadRecoveryActive = false }
                Self.inspectionLog.info("inspectionReadRecovery provider=chatgpt sequence=1 retry=1 reason=pending_first_body_timeout")
                return try await poll(session)
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
        guard ContinuousClock.now < deadline else { throw session.state == "loading" ? preparationFailure(session) : timeoutFailure }
        session.initialReadRetry = nil
        logInspection(observed, session: session)
        if session.state == "loading" {
            guard count(observed, "responseCount") == 0, count(observed, "userCount") == 0,
                  session.provider.conversationURL(observed["url"] as? String) == nil else { throw Failure.notFresh }
            if observed["signIn"] as? Bool == true { throw Failure.signInRequired }
            if session.provider == .chatgpt, observed["chatModeReady"] as? Bool != true {
                guard !session.temporaryRequested, !session.temporary else { throw Failure.productModeUnverified }
                // A recognized complementary pair may hydrate disabled on a
                // fresh root. Only the adapter's fixed pre-proof signal can
                // wait for enabling; it authorizes no action or readiness.
                if observed["chatModeHydrating"] as? Bool == true {
                    guard observed["pending"] as? Bool == true, observed["chatModeActionAvailable"] as? Bool == false,
                          !session.chatModeRequested, session.productModeEvidence == nil, !session.modelSelectionRequested,
                          !session.submitted, session.sequence == 0 else { throw Failure.productModeUnverified }
                    return try snapshot(session)
                }
                if observed["chatModeActionAvailable"] as? Bool == true {
                    if !session.chatModeRequested {
                        session.chatModeRequested = true
                        _ = try await page(session, action: "ensureChatMode", maximumWait: min(.seconds(10), deadline - .now))
                    }
                } else if observed["composer"] as? Bool == true,
                          !(session.chatModeRequested && observed["pending"] as? Bool == true) { throw Failure.productModeUnverified }
                return try snapshot(session)
            }
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
                    } else if session.provider == .gemini, !session.isDiscovery {
                        // Website default still needs a concrete observed model
                        // pin before a retained turn can receive its first Send.
                        var defaultObservation = observed
                        if defaultObservation["modelEvidence"] == nil || defaultObservation["modelEvidence"] is NSNull {
                            // Read the checked option on this same empty owned
                            // page. Discovery never selects a different model.
                            while ContinuousClock.now < deadline {
                                let revision = try browser.modelChangeRevision(for: session.tabID)
                                let current = try await page(session, action: "discoverModels",
                                    maximumWait: min(.seconds(10), deadline - .now))
                                if current["pending"] as? Bool != true { defaultObservation = current; break }
                                _ = try await waitForChange(sessionToken: session.token, after: revision, until: deadline)
                            }
                            guard ContinuousClock.now < deadline else { throw preparationFailure(session) }
                        }
                        session.modelEvidence = try validatedModelEvidence(defaultObservation, session: session)
                        session.modelSelectionVerified = true
                        _ = try await page(session, action: "verifyModel", maximumWait: min(.seconds(10), deadline - .now))
                        session.state = "ready"
                    } else { session.state = "ready" }
                } else if !session.temporaryRequested, observed["temporaryActionAvailable"] as? Bool == true {
                    session.temporaryRequested = true
                    _ = try await page(session, action: "enableTemporary")
                }
            }
            guard session.state == "ready" || ContinuousClock.now - session.created < preparationTimeout else {
                throw preparationFailure(session)
            }
        } else {
            let previouslyCandidate = session.completionCandidate
            session.completionCandidate = false
            guard observed["temporary"] as? Bool == true else { throw Failure.temporaryUnverified }
            guard observed["interrupted"] as? Bool != true else { throw Failure.responseInterrupted }
            if session.provider == .chatgpt, observed["responseLoadFailed"] as? Bool == true {
                guard session.submitted, session.firstUserFingerprint != nil, !session.pendingSubmission else {
                    throw Failure.ownershipFailure(.promotionFirstUser)
                }
                throw Failure.responseFailed(.chatgpt)
            }
            let response = observed["text"] as? String ?? ""
            guard response.utf8.count <= 220_000 else { throw Failure.responseTooLarge }
            if count(observed, "responseCount") > session.baseline,
               count(observed, "userCount") == session.sequence, !session.pendingSubmission, !response.isEmpty {
                if session.usesSubmissionOwnership {
                    guard session.currentSubmissionVerified,
                          session.currentSubmission?.sequence == session.sequence else {
                        logSubmissionFailure(session, action: "inspect", stage: .currentProofMissing, observed: observed)
                        throw Failure.ownershipFailure(.javaScriptSubmission)
                    }
                }
                if !session.profiledFirstPositive {
                    session.profiledFirstPositive = true
                    session.responseProfile?.mark(.firstPositive)
                }
                let responseChanged = session.modelVerificationPending
                    ? !session.response.utf8.elementsEqual(response.utf8) : session.response != response
                if responseChanged {
                    if session.profiledFirstCompletionCandidate { session.profileCompletionTransition(.candidateResponseChanged) }
                    session.response = response; session.lastChanged = .now; session.candidateSince = nil
                }
                if observed["busy"] as? Bool == false, observed["answerComplete"] as? Bool == true {
                    if !session.profiledFirstCompletionCandidate {
                        session.profiledFirstCompletionCandidate = true
                        session.responseProfile?.mark(.firstCompletionCandidate)
                    }
                    // Retain only the finite projection from this owned answer,
                    // alongside the exact response selected for strict parsing.
                    session.responseCodeStructure = nil
                    if let completion = observed["completionEvidence"] as? [String: Any],
                       let structure = completion["codeStructure"] as? [String: Any],
                       let safe = Self.sanitizedCodeStructure(structure),
                       let projected = try? JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any] {
                        session.responseCodeStructure = projected
                    }
                    if !previouslyCandidate || session.candidateSince == nil {
                        session.candidateSince = .now
                        session.profileCompletionTransition(.completionCandidateArmed)
                    }
                    session.completionCandidate = true
                    if let since = session.candidateSince,
                       ContinuousClock.now - max(since, session.lastChanged) >= .milliseconds(1_600) {
                        session.responseProfile?.mark(.quietDeadlineReady)
                        var completionObservation = observed
                        var currentAnswerVerified = true
                        if session.modelVerificationPending {
                            // One full picker proof is permitted only for this
                            // owned completed-answer candidate. The adapter
                            // rechecks the exact answer after its last await;
                            // native generation/route/lineage checks still run.
                            session.responseProfile?.mark(.finalFullInspectStart)
                            let final: [String: Any]
                            do {
                                defer { session.responseProfile?.mark(.finalFullInspectEnd) }
                                final = try await page(session, action: "inspect",
                                    recheckModelAfterAwait: false, recheckProductAfterAwait: false,
                                    allowPendingChatGPTModelVerification: false,
                                    maximumWait: min(inspectionTimeout, session.turnStarted + responseTimeout - .now))
                            }
                            currentAnswerVerified = final["modelVerificationPending"] == nil
                                && final["temporary"] as? Bool == true
                                && final["interrupted"] as? Bool != true
                                && final["responseLoadFailed"] as? Bool != true
                                && final["busy"] as? Bool == false && final["answerComplete"] as? Bool == true
                                && (final["text"] as? String).map({ $0.utf8.elementsEqual(response.utf8) }) == true
                                && count(final, "responseCount") == count(observed, "responseCount")
                                && count(final, "userCount") == session.sequence
                                && session.currentSubmissionVerified && !session.pendingSubmission
                            completionObservation = final
                            if currentAnswerVerified {
                                session.modelVerificationPending = false
                                Self.inspectionLog.info("modelVerification provider=chatgpt sequence=\(session.sequence) phase=final_verified")
                                session.responseCodeStructure = nil
                                if let completion = final["completionEvidence"] as? [String: Any],
                                   let structure = completion["codeStructure"] as? [String: Any],
                                   let safe = Self.sanitizedCodeStructure(structure),
                                   let projected = try? JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any] {
                                    session.responseCodeStructure = projected
                                }
                            } else {
                                session.completionCandidate = false
                                session.candidateSince = nil
                            }
                        }
                        if currentAnswerVerified {
                            guard ContinuousClock.now - session.turnStarted < responseTimeout else { throw Failure.deadline }
                            logResourceTimingDiagnostic(completionObservation["resourceTimingDiagnostic"], session: session, phase: "completion")
                            session.state = "complete"
                            session.responseProfile?.mark(.transportComplete)
                        }
                    }
                }
            }
            if !session.completionCandidate {
                if previouslyCandidate { session.profileCompletionTransition(.completionCandidateLost) }
                session.candidateSince = nil
            }
            guard session.state == "complete" || ContinuousClock.now - session.turnStarted < responseTimeout else {
                throw Failure.deadline
            }
        }
        return try snapshot(session)
    }

    private func logInspection(_ observed: [String: Any], session: Session) {
        if session.provider == .chatgpt, session.state == "running",
           browser.webView(for: session.tabID) === session.view,
           let generation = browser.documentGeneration(for: session.tabID),
           generation == (session.documentGeneration ?? session.initialDocumentGeneration) {
            // Cache only finite facts from an already completed native inspect.
            // No page text, URLs or IDs enter this diagnostic-only record.
            session.responseProgressInspection = Self.sanitizedResponseProgressInspection(observed).map {
                .init(sequence: session.sequence, generation: generation, fields: $0,
                      responseNotice: Self.sanitizedResponseNoticeDiagnostic(observed["responseNoticeDiagnostic"]),
                      answerScope: Self.sanitizedAnswerScopeDiagnostic(observed["answerScopeDiagnostic"]))
            }
        }
        if let raw = observed["quotaDiagnostic"] as? String {
            logQuotaDiagnostic(raw, session: session, action: "inspect")
        }
        let evidence = observed["completionEvidence"] as? [String: Any] ?? [:]
        let responseCount = count(observed, "responseCount")
        if observed["answerComplete"] as? Bool == true,
           !(observed["text"] as? String ?? "").isEmpty,
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

    /// Missing optional observations remain unknown. Malformed values cannot
    /// become false/zero, and oversized text is represented only by a sentinel.
    static func sanitizedResponseProgressInspection(_ observed: [String: Any]) -> [String: Any]? {
        var safe: [String: Any] = [:]
        for key in ["responseCount", "userCount"] {
            guard let value = ComputerToolArgumentContract.exactInt64(observed[key]),
                  (0...10_000).contains(value) else { return nil }
            safe[key] = value
        }
        for key in ["busy", "answerComplete", "responseLoadFailed"] {
            guard let raw = observed[key] else { safe[key] = NSNull(); continue }
            guard let value = firstUserDiagnosticBool(raw) else { return nil }
            safe[key] = value
        }
        if let raw = observed["text"] {
            guard let text = raw as? String else { return nil }
            let bytes = text.utf8.prefix(220_001).count
            safe["textBytes"] = bytes
            safe["textBytesLimitExceeded"] = bytes > 220_000
        } else {
            safe["textBytes"] = NSNull()
            safe["textBytesLimitExceeded"] = NSNull()
        }
        return safe
    }

    /// Synchronous terminal diagnostics only: never evaluate the page, wait,
    /// authorize a response or influence the original failure/cleanup path.
    private func logResponseProgressFailure(_ session: Session, cause: String) {
        guard session.provider == .chatgpt, !session.isDiscovery,
              session.state == "running", session.submitted,
              sessions[session.token] === session, !session.responseProgressEmitted,
              (1...10_000).contains(session.sequence), (0...10_000).contains(session.confirmedUsers),
              ["response_deadline", "cancelled", "request_error"].contains(cause) else { return }
        session.responseProgressEmitted = true
        let viewCurrent = browser.webView(for: session.tabID) === session.view
        let generation = browser.documentGeneration(for: session.tabID)
        let documentCurrent = viewCurrent && generation == (session.documentGeneration ?? session.initialDocumentGeneration)
        let cached = session.responseProgressInspection
        let inspectionCurrent = documentCurrent && cached?.sequence == session.sequence && cached?.generation == generation
        let lastInspection: Any
        if inspectionCurrent, let cached { lastInspection = cached.fields } else { lastInspection = NSNull() }
        let record: [String: Any] = ["kind": "chatgpt_response_progress_v1", "phase": "failure", "cause": cause,
            "sequence": session.sequence, "confirmedUsers": session.confirmedUsers,
            "pendingSubmission": session.pendingSubmission, "currentSubmissionVerified": session.currentSubmissionVerified,
            "modelSelectionVerified": session.modelSelectionVerified, "modelEvidencePresent": session.modelEvidence != nil,
            "ownedViewCurrent": viewCurrent, "ownedDocumentCurrent": documentCurrent,
            "lastInspectionAvailable": inspectionCurrent,
            "lastInspection": lastInspection]
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys),
              bytes.count <= 768 else { return }
        let safe = String(decoding: bytes, as: UTF8.self)
        #if DEBUG
        responseProgressDiagnosticObserverForTesting?(safe)
        #endif
        Self.inspectionLog.error("responseProgressDiagnostic provider=chatgpt sequence=\(session.sequence) phase=failure \(safe, privacy: .public)")
        // Same admitted read and exact current generation as the progress cache.
        // Separate metadata keeps response-progress-v1 and error policy unchanged.
        if inspectionCurrent, let notice = cached?.responseNotice {
            Self.inspectionLog.error("responseNoticeDiagnostic provider=chatgpt sequence=\(session.sequence) phase=failure \(notice, privacy: .public)")
        }
        if inspectionCurrent, let scope = cached?.answerScope {
            Self.inspectionLog.error("answerScopeDiagnostic provider=chatgpt sequence=\(session.sequence) phase=failure \(scope, privacy: .public)")
        }
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

    nonisolated static func sanitizedCodeStructure(_ source: [String: Any]) -> String? {
        func integer(_ value: Any?, limit: Int) -> Int? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let exact = Int(exactly: number.doubleValue), (0...limit).contains(exact) else { return nil }
            return exact
        }
        var safe: [String: Any] = [:]
        for key in ["preCount", "codeCount", "codeTextLength", "outsideTextLength"] {
            let limit = key.hasSuffix("Length") ? 220_001 : 1_000
            guard let count = integer(source[key], limit: limit) else { return nil }
            safe[key] = count
        }
        guard let truncated = source["outsideTruncated"] as? NSNumber,
              CFGetTypeID(truncated) == CFBooleanGetTypeID(),
              let tags = source["preParentTags"] as? [String], tags.count <= 3,
              tags.allSatisfy({ $0.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil }) else { return nil }
        safe["outsideTruncated"] = truncated.boolValue
        safe["preParentTags"] = tags
        if let valid = source["literalCodeValidJSON"] {
            guard valid is NSNull || CFGetTypeID(valid as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
            safe["literalCodeValidJSON"] = valid
        }
        if let known = source["literalCodeKnownEnvelopeType"] {
            guard known is NSNull || ["message", "tool_calls", "unknown"].contains(known as? String ?? "") else { return nil }
            safe["literalCodeKnownEnvelopeType"] = known
        }
        if let extraction = source["selectedExtraction"] {
            guard ["raw_code", "rendered_fallback"].contains(extraction as? String ?? "") else { return nil }
            safe["selectedExtraction"] = extraction
        }
        if let reason = source["extractionReason"] {
            guard ["absent_answer", "missing_pre", "multiple_pre", "missing_code", "multiple_code",
                   "oversized_code", "invalid_json", "unknown_envelope_type", "outside_content",
                   "outside_scan_limit", "accepted_literal_code"].contains(reason as? String ?? "") else { return nil }
            safe["extractionReason"] = reason
        }
        if let raw = source["rendererGuard"] {
            guard let guardDiagnostic = sanitizedRendererGuardDiagnostic(raw) else { return nil }
            safe["rendererGuard"] = guardDiagnostic
        }
        if let nodes = source["outsideNodes"] as? [[String: Any]] {
            guard nodes.count <= 4 else { return nil }
            var projected: [[String: Any]] = []
            for node in nodes {
                guard let kind = node["kind"] as? String, ["json", "private_use", "other"].contains(kind),
                      let length = integer(node["textLength"], limit: 220_001),
                      let ancestors = node["ancestors"] as? [[String: Any]], ancestors.count <= 4 else { return nil }
                var parents: [[String: Any]] = []
                for parent in ancestors {
                    guard let tag = parent["tag"] as? String,
                          tag.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil,
                          let classes = parent["classes"] as? [String], classes.count <= 6,
                          classes.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_-]{1,48}$"#, options: .regularExpression) != nil }),
                          let pres = integer(parent["preDescendants"], limit: 1_000),
                          let copies = integer(parent["copyControls"], limit: 1_000) else { return nil }
                    parents.append(["tag": tag, "classes": classes, "preDescendants": pres, "copyControls": copies])
                }
                projected.append(["kind": kind, "textLength": length, "ancestors": parents])
            }
            safe["outsideNodes"] = projected
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), bytes.count <= 8_192 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// Fixed structural facts from the same already-admitted response read.
    /// This projection has no role in response, error or ownership acceptance.
    nonisolated static func sanitizedRendererGuardDiagnostic(_ raw: Any) -> [String: Any]? {
        let flags = ["rawKnownLabel", "trimmedKnownLabel", "guardBodyIsExtractedAnswer", "bodyIsRoot",
                     "knownScopedCopyOutsideDIL", "rejectedDisplayContents"]
        let keys = Set(flags + ["reason", "subject", "visitedNodeCount"])
        let reasons: Set<String> = ["root_missing", "root_not_visible", "ancestor_budget", "ancestor_excluded",
            "ancestor_foreign_message", "conversation_boundary_missing", "body_missing", "body_not_visible",
            "body_outside_root", "body_ancestor_budget", "body_quote_or_markdown", "body_foreign_message",
            "node_budget", "tree_depth", "text_budget", "multiple_text_leaves", "raw_label_differs", "text_not_visible",
            "non_element", "non_div_element", "node_not_visible", "interactive_metadata", "markdown_content",
            "nested_message", "class_budget", "dil_pair_incomplete", "dil_pair_multiple", "portal_pair_incomplete",
            "portal_pair_multiple", "children_budget", "leaf_classed", "components_missing", "label_missing",
            "portal_not_direct_parent", "leaf_not_direct_child", "leaf_has_elements", "dil_has_other_children",
            "component_scope_changed", "matched"]
        guard let value = raw as? [String: Any], Set(value.keys) == keys,
              let reason = value["reason"] as? String, reasons.contains(reason),
              let subject = value["subject"] as? String,
              ["none", "root", "body", "text_leaf", "dil_pair", "portal_pair", "other"].contains(subject),
              let visited = value["visitedNodeCount"] as? NSNumber, CFGetTypeID(visited) != CFBooleanGetTypeID(),
              let exactVisited = Int(exactly: visited.doubleValue), (0...65).contains(exactVisited) else { return nil }
        var safe: [String: Any] = ["reason": reason, "subject": subject, "visitedNodeCount": exactVisited]
        for flag in flags {
            if value[flag] is NSNull { safe[flag] = NSNull(); continue }
            guard let number = value[flag] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            safe[flag] = number.boolValue
        }
        guard !(safe["rawKnownLabel"] as? Bool == true) || safe["trimmedKnownLabel"] as? Bool == true,
              safe["trimmedKnownLabel"] is NSNull || !(safe["rawKnownLabel"] is NSNull),
              (safe["bodyIsRoot"] is NSNull) == (safe["guardBodyIsExtractedAnswer"] is NSNull),
              safe["knownScopedCopyOutsideDIL"] is NSNull || safe["guardBodyIsExtractedAnswer"] as? Bool == true,
              (exactVisited == 65) == (reason == "node_budget"),
              safe["rejectedDisplayContents"] is NSNull
                || ["root_not_visible", "body_not_visible", "node_not_visible", "text_not_visible"].contains(reason),
              reason != "matched" || (exactVisited > 0 && safe["rawKnownLabel"] as? Bool == true
                && safe["trimmedKnownLabel"] as? Bool == true && !(safe["bodyIsRoot"] is NSNull)) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), data.count <= 768 else { return nil }
        return safe
    }

    private static let firstUserDiagnosticActions: Set<String> = ["inspect", "prepare", "insert", "sendReady", "submit",
        "verifyModel", "verifyProductMode", "ensureChatMode", "enableTemporary", "selectModel", "discoverModels", "modelDiagnostic", "stop", "cleanup"]
    private static let productProofFailures: Set<String> = ["work_selected", "mutation_overflow", "group_overflow", "work_overflow",
        "contradictory_controls", "owner", "document", "frame", "origin", "route", "not_ready", "temporary_unclaimed"]
    private static let productMutationCounts = ["productMutationRelevantCount", "productMutationIgnoredCount"]
    private static let firstUserBodyLengths = ["bodyInnerTextLength", "bodyTextContentLength", "rootRenderedTextLength", "rootTextContentLength", "firstPromptLength"]
    private static let firstUserBodyCounts = ["bodyTextContentMarkerOccurrences", "rootRenderedMarkerOccurrences", "rootTextContentMarkerOccurrences", "scopedExpandControlCount"]
    private static let firstUserBodyFlags = ["bodyTextContentAnalyzed", "rootRenderedAnalyzed", "rootTextContentAnalyzed", "firstPromptAnalyzed",
        "bodyTextContentMarkerFinalLine", "rootRenderedMarkerFinalLine", "rootTextContentMarkerFinalLine", "renderedPrefixOfFirstPrompt"]
    private static let firstUserTextFlags = ["expansionTextAnalyzed", "expansionClicked", "expansionExactPrefixMatches",
        "expansionASCIIPrefixMatches", "expansionASCIIPromptMatches"]
    private static let firstUserTextLengths = ["expansionASCIIRenderedLength", "expansionASCIIPrefixLength",
        "expansionASCIIPromptLength", "expansionFirstMismatchOffset"]
    private static let firstUserTextCounts = ["expansionUnicodeSpaceCount", "expansionExpectedUnicodeSpaceCount",
        "expansionFormatCount", "expansionExpectedFormatCount"]
    private static let firstUserTextCharacters = ["expansionFirstActualCharacter", "expansionFirstExpectedCharacter"]
    private static let firstUserCharacterLabels: Set<String> = ["end", "other", "ascii_space", "exclamation", "double_quote",
        "hash", "dollar", "ampersand", "apostrophe", "left_parenthesis", "right_parenthesis", "asterisk", "hyphen", "period",
        "slash", "colon", "less_than", "greater_than", "left_bracket", "backslash", "right_bracket", "underscore", "backtick",
        "left_brace", "right_brace", "tilde", "no_break_space", "zero_width_space", "word_joiner", "byte_order_mark"]
    private static let firstUserTextKeys = firstUserTextFlags + firstUserTextLengths + firstUserTextCounts + firstUserTextCharacters + ["expansionFirstMismatchClass"]
    private static let firstUserPayloadFlags = ["payloadExpectedFrameUnique", "payloadRenderedFrameUnique", "payloadExpectedParsed",
        "payloadRenderedParsed", "payloadOutsideFrameMatches", "payloadCompared", "payloadParsedJSONEqual", "payloadObjectKeyOrderChanged"]
    private static let firstUserPayloadKeys = firstUserPayloadFlags + ["payloadMismatchField", "payloadMismatchKind", "payloadExpectedType", "payloadRenderedType", "payloadUnavailableReason"]
    private static let firstUserLiteralDOMFlags = ["literalDOMAvailable", "literalDOMMatchesPrompt", "literalDOMMatchesRendered",
        "literalDOMFrameUnique", "literalDOMFrameParsed", "literalDOMPayloadCompared", "literalDOMParsedJSONEqual"]
    private static let firstUserLiteralDOMCounts = ["literalDOMLength", "literalDOMNodeCount", "literalDOMMaxDepth", "literalDOMParagraphCount", "literalDOMBRCount"]
    private static let firstUserLiteralDOMFailureKeys = ["literalDOMFailureNodeKind", "literalDOMFailureTag", "literalDOMFailureParentTag", "literalDOMFailureRule"]
    private static let firstUserLiteralDOMKeys = firstUserLiteralDOMFlags + firstUserLiteralDOMCounts + ["literalDOMLinkCount", "literalDOMUnavailableReason", "literalDOMPayloadUnavailableReason"] + firstUserLiteralDOMFailureKeys

    private static func firstUserDiagnosticBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Finite rendering measurements only. These fields never grant ownership.
    static func sanitizedQueryTemplateDiagnostic(_ raw: Any) -> [String: Any]? {
        let flags = ["expectedAvailable", "allTextRowsSingleFrame", "rawWholeMatches", "singleFrameWholeMatches"]
        let counts = ["rowCount", "brRowCount", "textRowCount", "directTextNodeMin", "directTextNodeMax",
                      "rawRowMatches", "singleFrameRowMatches", "leadingSpaceRows", "trailingSpaceRows"]
        let keys = Set(flags + counts + ["kind", "selectedMode"])
        guard let value = raw as? [String: Any], Set(value.keys) == keys,
              value["kind"] as? String == "gemini_query_template_v1",
              let mode = value["selectedMode"] as? String,
              ["literal", "ascii_space_frame_v1", "unverified"].contains(mode) else { return nil }
        var safe: [String: Any] = ["kind": "gemini_query_template_v1", "selectedMode": mode]
        var measured: [String: Int64] = [:], observed: [String: Bool] = [:]
        for key in counts {
            guard let count = ComputerToolArgumentContract.exactInt64(value[key]), (0...8_192).contains(count) else { return nil }
            measured[key] = count; safe[key] = count
        }
        for key in flags {
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }
            observed[key] = flag; safe[key] = flag
        }
        let rows = measured["rowCount"]!, textRows = measured["textRowCount"]!
        guard rows > 0, measured["brRowCount"]! + textRows == rows,
              measured["directTextNodeMin"]! <= measured["directTextNodeMax"]!,
              ["rawRowMatches", "singleFrameRowMatches"].allSatisfy({ measured[$0]! <= rows }),
              ["leadingSpaceRows", "trailingSpaceRows"].allSatisfy({ measured[$0]! <= textRows }),
              textRows != 0 || measured["directTextNodeMax"]! == 0 else { return nil }
        let expected = observed["expectedAvailable"]!, framed = observed["allTextRowsSingleFrame"]!
        let rawMatch = observed["rawWholeMatches"]!, frameMatch = observed["singleFrameWholeMatches"]!
        guard expected || (!rawMatch && !frameMatch && measured["rawRowMatches"] == 0 && measured["singleFrameRowMatches"] == 0),
              !frameMatch || framed,
              framed || measured["singleFrameRowMatches"] == 0,
              !framed || measured["leadingSpaceRows"] == textRows && measured["trailingSpaceRows"] == textRows else { return nil }
        switch mode {
        case "literal": guard rawMatch else { return nil }
        case "ascii_space_frame_v1": guard !rawMatch, frameMatch else { return nil }
        default: guard !rawMatch, !frameMatch else { return nil }
        }
        return safe
    }

    static func sanitizedFirstUserStructure(_ raw: String, provider: Provider) -> String? {
        guard raw.utf8.count <= 8_192,
              let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              value["kind"] as? String == "first_user_structure", value["provider"] as? String == provider.rawValue else { return nil }
        let tags: Set<String> = ["none", "div", "span", "p", "pre", "code", "button", "section", "article", "user-query", "a", "strong", "em", "ol", "ul", "li", "br", "input", "textarea", "mat-icon", "h1", "h2", "h3", "h4", "h5", "h6"]
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
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }
            safe[key] = flag
        }
        if let action = value["action"] {
            guard let action = action as? String, firstUserDiagnosticActions.contains(action) else { return nil }
            safe["action"] = action
        }
        if let scope = value["scope"] {
            let scopes: Set<String> = ["marker_validation", "digest", "model_precheck", "binding", "action_final_guard", "first_insert", "first_submit", "first_missing"]
            guard let scope = scope as? String, scopes.contains(scope) else { return nil }
            safe["scope"] = scope
        }
        if let rawReason = value["reason"] {
            let reasons: Set<String> = ["first_bound", "marker_invalid", "submission_unclaimed", "marker_mismatch", "body_limit", "marker_not_final", "marker_duplicate", "body_empty", "snapshot_before_action", "pinned_fingerprint", "native_fingerprint", "binding_not_authorized", "first_missing", "snapshot_after_action", "first_insert", "first_submit"]
            guard let reason = rawReason as? String,
                  reasons.contains(reason) || provider == .gemini && reason == "submission_text" else { return nil }
            safe["reason"] = reason
        }
        if let rawScope = value["descendantScope"] {
            guard provider == .gemini,
                  rawScope as? String == "selected_body" else { return nil }
            safe["descendantScope"] = "selected_body"
        }
        if let query = value["queryTemplate"] {
            guard provider == .gemini, safe["descendantScope"] as? String == "selected_body",
                  let projected = sanitizedQueryTemplateDiagnostic(query) else { return nil }
            safe["queryTemplate"] = projected
        }
        for key in ["pinnedFingerprintMatch", "nativeFingerprintMatch", "allowFirstUserBinding", "allowFirstUserExpansion", "privatePinPresent", "expectedFingerprintPresent",
                    "markerValid", "firstPromptPresent", "firstPromptMatches"] {
            if let rawFlag = value[key] {
                guard let flag = firstUserDiagnosticBool(rawFlag) else { return nil }
                safe[key] = flag
            }
        }
        if let rawSelection = value["bodySelection"] {
            let selections: Set<String> = ["markdown_user_message", "whitespace_pre_wrap", "author_user", "root_fallback", "none", "unmatched"]
            guard let selection = rawSelection as? String, selections.contains(selection) else { return nil }
            safe["bodySelection"] = selection
        }
        if let rawOutcome = value["expansionOutcome"] {
            let outcomes: Set<String> = ["not_requested", "ineligible", "unavailable", "ambiguous", "disabled", "obstructed", "claimed",
                "model_unverified", "timeout", "context_changed", "node_changed", "text_mismatch", "expanded", "failed"]
            guard let outcome = rawOutcome as? String, outcomes.contains(outcome) else { return nil }
            safe["expansionOutcome"] = outcome
        }
        if let rawFailure = value["expansionContextFailure"] {
            let failures: Set<String> = ["frame", "provider", "origin", "owner", "user_count", "submission", "submission_count",
                "marker", "prompt", "private_pin", "product", "temporary", "root", "body", "conversation_route",
                "conversation_identity", "url", "continuation", "deadline"]
            guard let failure = rawFailure as? String, failures.contains(failure) else { return nil }
            safe["expansionContextFailure"] = failure
        }
        if let rawError = value["expansionModelError"] {
            let errors: Set<String> = ["model_unverified", "model_unavailable", "model_mismatch", "document_changed",
                "conversation_changed", "product_mode_unverified", "temporary_mode_unverified"]
            guard let error = rawError as? String, errors.contains(error) else { return nil }
            safe["expansionModelError"] = error
        }
        if let rawFailure = value["productProofFailure"] {
            guard let failure = rawFailure as? String, productProofFailures.contains(failure) else { return nil }
            safe["productProofFailure"] = failure
        }
        for key in productMutationCounts {
            if let rawCount = value[key] {
                guard let count = ComputerToolArgumentContract.exactInt64(rawCount), (0...1_000).contains(count) else { return nil }
                safe[key] = count
            }
        }
        for key in firstUserBodyLengths + firstUserBodyCounts {
            if let rawCount = value[key] {
                let limit: Int64 = firstUserBodyLengths.contains(key) ? 220_001 : 1_000
                guard let count = ComputerToolArgumentContract.exactInt64(rawCount), (0...limit).contains(count) else { return nil }
                safe[key] = count
            }
        }
        for key in firstUserBodyFlags {
            if let rawFlag = value[key] {
                guard let flag = firstUserDiagnosticBool(rawFlag) else { return nil }
                safe[key] = flag
            }
        }
        if firstUserPayloadKeys.contains(where: { value[$0] != nil }) {
            guard provider == .chatgpt else { return nil }
            var flags: [String: Bool] = [:]
            for key in firstUserPayloadFlags {
                guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }
                flags[key] = flag; safe[key] = flag
            }
            let fields: [String: Set<String>] = [
                "payloadMismatchField": ["none", "instructions", "input", "tools", "metadata", "other"],
                "payloadMismatchKind": ["none", "container_type", "leaf_type", "leaf_value", "array_length", "object_keys"],
                "payloadExpectedType": ["none", "missing", "object", "array", "string", "number", "boolean", "null"],
                "payloadRenderedType": ["none", "missing", "object", "array", "string", "number", "boolean", "null"],
                "payloadUnavailableReason": ["none", "missing_frame", "parse_failure", "bounds", "number_precision"],
            ]
            for (key, allowed) in fields {
                guard let text = value[key] as? String, allowed.contains(text) else { return nil }
                safe[key] = text
            }
            let frames = flags["payloadExpectedFrameUnique"] == true && flags["payloadRenderedFrameUnique"] == true
            let parsed = flags["payloadExpectedParsed"] == true && flags["payloadRenderedParsed"] == true
            guard flags["payloadExpectedParsed"] != true || flags["payloadExpectedFrameUnique"] == true,
                  flags["payloadRenderedParsed"] != true || flags["payloadRenderedFrameUnique"] == true,
                  flags["payloadOutsideFrameMatches"] != true || frames else { return nil }
            let compared = flags["payloadCompared"] == true, equal = flags["payloadParsedJSONEqual"] == true
            let noMismatch = value["payloadMismatchField"] as? String == "none" && value["payloadMismatchKind"] as? String == "none"
                && value["payloadExpectedType"] as? String == "none" && value["payloadRenderedType"] as? String == "none"
            if !compared {
                guard !equal, flags["payloadObjectKeyOrderChanged"] != true, noMismatch,
                      let reason = value["payloadUnavailableReason"] as? String, reason != "none" else { return nil }
                if reason == "missing_frame" { guard !frames else { return nil } }
                if reason == "parse_failure" { guard frames, !parsed else { return nil } }
                if reason == "number_precision" { guard frames, parsed else { return nil } }
            } else {
                guard frames, parsed, value["payloadUnavailableReason"] as? String == "none" else { return nil }
                if equal { guard noMismatch else { return nil } }
                else {
                    guard value["payloadMismatchField"] as? String != "none", value["payloadMismatchKind"] as? String != "none",
                          let expected = value["payloadExpectedType"] as? String, expected != "none",
                          let rendered = value["payloadRenderedType"] as? String, rendered != "none" else { return nil }
                    let containers: Set<String> = ["object", "array"]
                    switch value["payloadMismatchKind"] as? String {
                    case "container_type": guard expected != rendered, expected != "missing", rendered != "missing",
                        containers.contains(expected) || containers.contains(rendered) else { return nil }
                    case "leaf_type": guard expected != rendered, !containers.contains(expected), !containers.contains(rendered), expected != "missing", rendered != "missing" else { return nil }
                    case "leaf_value": guard expected == rendered, ["string", "number", "boolean"].contains(expected) else { return nil }
                    case "array_length": guard expected == "array", rendered == "array" else { return nil }
                    case "object_keys": guard (expected == "missing") != (rendered == "missing") else { return nil }
                    default: return nil
                    }
                }
            }
        }
        if firstUserLiteralDOMKeys.contains(where: { value[$0] != nil }) {
            guard provider == .chatgpt else { return nil }
            for key in firstUserLiteralDOMFlags {
                guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }
                safe[key] = flag
            }
            for key in firstUserLiteralDOMCounts {
                let limit: Int64 = key == "literalDOMLength" ? 180_201 : key == "literalDOMMaxDepth" ? 65 : key == "literalDOMNodeCount" ? 8_193 : 8_192
                guard let count = ComputerToolArgumentContract.exactInt64(value[key]), (0...limit).contains(count) else { return nil }
                safe[key] = count
            }
            if let rawLinks = value["literalDOMLinkCount"] {
                guard let links = ComputerToolArgumentContract.exactInt64(rawLinks), (0...8_192).contains(links) else { return nil }
                safe["literalDOMLinkCount"] = links
            }
            guard let reason = value["literalDOMUnavailableReason"] as? String,
                  ["none", "read_failure", "hidden_markup", "inert_markup", "control_markup", "unsupported_markup", "node_budget", "depth_budget", "character_budget"].contains(reason),
                  let payloadReason = value["literalDOMPayloadUnavailableReason"] as? String,
                  ["unavailable", "none", "missing_frame", "parse_failure", "bounds", "number_precision"].contains(payloadReason) else { return nil }
            safe["literalDOMUnavailableReason"] = reason; safe["literalDOMPayloadUnavailableReason"] = payloadReason
            let available = safe["literalDOMAvailable"] as? Bool == true
            if firstUserLiteralDOMFailureKeys.contains(where: { value[$0] != nil }) {
                let tags: Set<String> = ["none", "other", "div", "span", "p", "pre", "code", "button", "section", "article", "a", "strong", "em", "ol", "ul", "li", "br", "input", "textarea"]
                guard !available, ["unsupported_markup", "control_markup"].contains(reason),
                      let kind = value["literalDOMFailureNodeKind"] as? String, ["element", "comment", "other"].contains(kind),
                      let tag = value["literalDOMFailureTag"] as? String, tags.contains(tag),
                      let parent = value["literalDOMFailureParentTag"] as? String, tags.contains(parent),
                      let rule = value["literalDOMFailureRule"] as? String else { return nil }
                switch rule {
                case "node_type": guard reason == "unsupported_markup", kind != "element", tag == "none" else { return nil }
                case "tag": guard reason == "unsupported_markup", kind == "element", !["none", "div", "span", "p", "br"].contains(tag) else { return nil }
                case "nested_div": guard reason == "unsupported_markup", kind == "element", tag == "div", parent != "none" else { return nil }
                case "paragraph_parent": guard reason == "unsupported_markup", kind == "element", tag == "p", parent != "none" else { return nil }
                case "control": guard reason == "control_markup", kind == "element", tag != "none" else { return nil }
                default: return nil
                }
                for key in firstUserLiteralDOMFailureKeys { safe[key] = value[key] }
            }
            let frame = safe["literalDOMFrameUnique"] as? Bool == true, parsed = safe["literalDOMFrameParsed"] as? Bool == true
            let compared = safe["literalDOMPayloadCompared"] as? Bool == true, equal = safe["literalDOMParsedJSONEqual"] as? Bool == true
            let nodes = safe["literalDOMNodeCount"] as? Int64 ?? 0
            let links = safe["literalDOMLinkCount"] as? Int64 ?? 0
            guard (safe["literalDOMParagraphCount"] as? Int64 ?? 0) + (safe["literalDOMBRCount"] as? Int64 ?? 0) + links <= nodes,
                  links == 0 || (safe["literalDOMParagraphCount"] as? Int64 ?? 0) > 0 && (safe["literalDOMMaxDepth"] as? Int64 ?? 0) >= 2,
                  (safe["literalDOMMaxDepth"] as? Int64 ?? 0) <= max(0, nodes - 1) else { return nil }
            if available {
                guard reason == "none", payloadReason != "unavailable",
                      (safe["literalDOMLength"] as? Int64 ?? 0) <= 180_200,
                      nodes > 0, nodes <= 8_192,
                      (safe["literalDOMMaxDepth"] as? Int64 ?? 0) <= 64,
                      !parsed || frame, !equal || compared, !compared || parsed && payloadReason == "none",
                      payloadReason != "none" || compared else { return nil }
                if payloadReason == "missing_frame" { guard !parsed else { return nil } }
                if ["bounds", "number_precision"].contains(payloadReason) { guard parsed else { return nil } }
            } else {
                guard reason != "none", payloadReason == "unavailable",
                      firstUserLiteralDOMFlags.filter({ $0 != "literalDOMAvailable" }).allSatisfy({ safe[$0] as? Bool == false }) else { return nil }
                if reason == "node_budget" { guard safe["literalDOMNodeCount"] as? Int64 == 8_193 else { return nil } }
                if reason == "depth_budget" { guard safe["literalDOMMaxDepth"] as? Int64 == 65 else { return nil } }
                if reason == "character_budget" { guard safe["literalDOMLength"] as? Int64 == 180_201 else { return nil } }
            }
        }
        for key in firstUserTextFlags {
            if let rawFlag = value[key] {
                guard let flag = firstUserDiagnosticBool(rawFlag) else { return nil }
                safe[key] = flag
            }
        }
        for key in firstUserTextLengths + firstUserTextCounts {
            if let rawCount = value[key] {
                let limit: Int64 = firstUserTextLengths.contains(key) ? 180_200 : 1_000
                guard let count = ComputerToolArgumentContract.exactInt64(rawCount), (0...limit).contains(count) else { return nil }
                safe[key] = count
            }
        }
        if let rawClass = value["expansionFirstMismatchClass"] {
            guard let mismatch = rawClass as? String,
                  ["none", "end", "ascii_space", "unicode_space", "format", "punctuation", "content"].contains(mismatch) else { return nil }
            safe["expansionFirstMismatchClass"] = mismatch
        }
        let analyzedTextKeys = firstUserTextKeys.filter { !["expansionTextAnalyzed", "expansionClicked"].contains($0) }
        if analyzedTextKeys.contains(where: { safe[$0] != nil }), safe["expansionTextAnalyzed"] as? Bool != true { return nil }
        if safe["expansionFirstMismatchOffset"] != nil {
            guard let mismatch = safe["expansionFirstMismatchClass"] as? String, mismatch != "none" else { return nil }
        }
        if firstUserTextCharacters.contains(where: { value[$0] != nil }) {
            guard safe["expansionFirstMismatchOffset"] != nil,
                  safe["expansionASCIIPromptMatches"] as? Bool == false,
                  safe["expansionTextAnalyzed"] as? Bool == true else { return nil }
            for key in firstUserTextCharacters {
                guard let label = value[key] as? String, firstUserCharacterLabels.contains(label) else { return nil }
                if label == "end" {
                    guard safe["expansionFirstMismatchClass"] as? String == "end" else { return nil }
                }
                safe[key] = label
            }
            // Distinct letters/digits deliberately collapse to "other".
            let actual = safe[firstUserTextCharacters[0]] as? String
            let expected = safe[firstUserTextCharacters[1]] as? String
            guard actual != expected || actual == "other" else { return nil }
        }
        // An unavailable alternate observation must not look like a verified
        // absence of the marker. The adapter omits these fields over its limit.
        for prefix in ["bodyTextContent", "rootRendered", "rootTextContent"] {
            if safe[prefix + "MarkerOccurrences"] != nil || safe[prefix + "MarkerFinalLine"] != nil {
                guard safe[prefix + "Analyzed"] as? Bool == true else { return nil }
            }
        }
        if safe["renderedPrefixOfFirstPrompt"] != nil, safe["firstPromptAnalyzed"] as? Bool != true { return nil }
        if let rawSnapshot = value["snapshot"] {
            guard let snapshot = rawSnapshot as? [String: Any] else { return nil }
            var projected: [String: Bool] = [:]
            for key in ["rootSame", "bodySame", "bodyConnected", "textSame", "countSame", "urlSame", "originSame", "ownerSame"] {
                guard let flag = firstUserDiagnosticBool(snapshot[key]) else { return nil }
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
                    guard let flag = firstUserDiagnosticBool(node[key]) else { return nil }
                    child[key] = flag
                }
                if node["outboundInnerTextMatches"] != nil || node["outboundTextContentMatches"] != nil {
                    guard provider == .gemini, safe["descendantScope"] as? String == "selected_body",
                          let inner = firstUserDiagnosticBool(node["outboundInnerTextMatches"]),
                          let content = firstUserDiagnosticBool(node["outboundTextContentMatches"]) else { return nil }
                    child["outboundInnerTextMatches"] = inner
                    child["outboundTextContentMatches"] = content
                }
                let headingFlags = ["headingSemantic", "absolutePosition", "onePixelBox", "overflowHidden", "rectClipped", "insetClipped"]
                if headingFlags.contains(where: { node[$0] != nil }) {
                    guard provider == .gemini else { return nil }
                    for key in headingFlags {
                        guard let flag = firstUserDiagnosticBool(node[key]) else { return nil }
                        child[key] = flag
                    }
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
        var queryObservation = summary.removeValue(forKey: "queryTemplate") as? [String: Any] ?? [:]
        if !queryObservation.isEmpty { queryObservation["provider"] = provider.rawValue }
        var payloadObservation: [String: Any] = [:]
        for key in firstUserPayloadKeys {
            if let value = summary.removeValue(forKey: key) { payloadObservation[key] = value }
        }
        if !payloadObservation.isEmpty {
            payloadObservation["kind"] = "first_user_payload"; payloadObservation["provider"] = provider.rawValue
            for key in ["action", "scope"] { payloadObservation[key] = summary[key] }
        }
        var literalDOMObservation: [String: Any] = [:]
        for key in firstUserLiteralDOMKeys {
            if let value = summary.removeValue(forKey: key) { literalDOMObservation[key] = value }
        }
        if !literalDOMObservation.isEmpty {
            literalDOMObservation["kind"] = "first_user_literal_dom"; literalDOMObservation["provider"] = provider.rawValue
            for key in ["action", "scope"] { literalDOMObservation[key] = summary[key] }
        }
        var textObservation: [String: Any] = [:]
        for key in firstUserTextKeys {
            if let value = summary.removeValue(forKey: key) { textObservation[key] = value }
        }
        if !textObservation.isEmpty {
            textObservation["kind"] = "first_user_text"; textObservation["provider"] = provider.rawValue
            for key in ["action", "scope"] { textObservation[key] = summary[key] }
        }
        // Product-control provenance has its own bounded record so diagnosing
        // message rendering cannot push the body observation past the log cap.
        var productObservation: [String: Any] = [:]
        for key in ["productProofFailure", "productMutationRelevantCount", "productMutationIgnoredCount"] {
            if let value = summary.removeValue(forKey: key) { productObservation[key] = value }
        }
        if !productObservation.isEmpty {
            productObservation["kind"] = "first_user_product_proof"; productObservation["provider"] = provider.rawValue
            for key in ["action", "scope"] { productObservation[key] = summary[key] }
        }
        var bodyObservation: [String: Any] = [:]
        for key in ["bodySelection", "expansionOutcome", "expansionContextFailure", "expansionModelError"] + firstUserBodyLengths + firstUserBodyCounts + firstUserBodyFlags {
            if let value = summary.removeValue(forKey: key) { bodyObservation[key] = value }
        }
        if !bodyObservation.isEmpty {
            bodyObservation["kind"] = "first_user_body"; bodyObservation["provider"] = provider.rawValue
            for key in ["action", "scope"] { bodyObservation[key] = summary[key] }
        }
        // Keep optional context separate if the full summary exceeds the same
        // existing log cap. Adding diagnostics must not discard the branch.
        var context: [String: Any] = [:]
        if let bytes = try? JSONSerialization.data(withJSONObject: summary), bytes.count > 960 {
            context = ["kind": "first_user_context", "provider": provider.rawValue]
            for key in ["scope", "action", "allowFirstUserBinding", "allowFirstUserExpansion", "privatePinPresent", "expectedFingerprintPresent",
                        "markerValid", "firstPromptPresent", "firstPromptMatches", "snapshot"] {
                if let value = summary.removeValue(forKey: key) { context[key] = value }
            }
        }
        var records: [String] = []
        for value in [summary] + (context.isEmpty ? [] : [context]) + (bodyObservation.isEmpty ? [] : [bodyObservation])
            + (productObservation.isEmpty ? [] : [productObservation]) + (textObservation.isEmpty ? [] : [textObservation])
            + (payloadObservation.isEmpty ? [] : [payloadObservation]) + (literalDOMObservation.isEmpty ? [] : [literalDOMObservation])
            + (queryObservation.isEmpty ? [] : [queryObservation]) + children {
            guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys), bytes.count <= 960 else { return nil }
            records.append(String(decoding: bytes, as: UTF8.self))
        }
        return records
    }

    private func logFirstUserStructure(_ records: [String], sequence: Int, isFailure: Bool = false) {
        var childIndex = 0
        for (index, safe) in records.enumerated() {
            let event: String
            if index == 0 { event = "firstUserStructure" }
            else if safe.contains("\"kind\":\"first_user_context\"") {
                event = "firstUserContext"
            }
            else if safe.contains("\"kind\":\"first_user_body\"") {
                event = "firstUserBody"
            }
            else if safe.contains("\"kind\":\"first_user_text\"") {
                event = "firstUserText"
            }
            else if safe.contains("\"kind\":\"first_user_payload\"") {
                event = "firstUserPayload"
            }
            else if safe.contains("\"kind\":\"first_user_literal_dom\"") {
                event = "firstUserLiteralDOM"
            }
            else if safe.contains("\"kind\":\"gemini_query_template_v1\"") {
                event = "firstUserQueryTemplate"
            }
            else {
                event = "firstUserChild"
            }
            let child = event == "firstUserChild" ? "index=\(childIndex) " : ""
            // Both paths receive only the existing validated finite projection.
            // Retain rejection causes without persisting healthy-read noise.
            if isFailure {
                Self.inspectionLog.error("\(event, privacy: .public) sequence=\(sequence) \(child, privacy: .public)\(safe, privacy: .public)")
            } else {
                Self.inspectionLog.info("\(event, privacy: .public) sequence=\(sequence) \(child, privacy: .public)\(safe, privacy: .public)")
            }
            if event == "firstUserChild" { childIndex += 1 }
            #if DEBUG
            firstUserStructureEmissionObserverForTesting?(isFailure, safe)
            #endif
        }
        #if DEBUG
        firstUserDiagnosticsObserverForTesting?(records)
        #endif
    }

    enum FirstUserNativeStage: String {
        case adapterRejected = "adapter_rejected"
        case replacementRefreshRejected = "replacement_refresh_rejected"
        case proofFlagsMissing = "proof_flags_missing"
        case fingerprintInvalid = "fingerprint_invalid"
        case fingerprintMismatch = "fingerprint_mismatch"
        case bindingNotAuthorized = "binding_not_authorized"
    }

    /// Native state only: never retain an owner, marker, URL, fingerprint or text.
    struct FirstUserNativeState {
        let sequence: Int, confirmedUsers: Int
        let pendingSubmission: Bool, submitted: Bool, temporary: Bool, fingerprintPresent: Bool
    }

    private func firstUserNativeState(_ session: Session) -> FirstUserNativeState {
        .init(sequence: session.sequence, confirmedUsers: session.confirmedUsers,
              pendingSubmission: session.pendingSubmission, submitted: session.submitted,
              temporary: session.temporary, fingerprintPresent: session.firstUserFingerprint != nil)
    }

    static func firstUserNativeDiagnosticRecords(provider: Provider, action: String, stage: FirstUserNativeStage,
                                                entry: FirstUserNativeState, current: FirstUserNativeState,
                                                observed: [String: Any], refresh: Bool, modelRecheck: Bool, productRecheck: Bool) -> [String]? {
        guard firstUserDiagnosticActions.contains(action) else { return nil }
        var summary: [String: Any] = ["kind": "first_user_native", "provider": provider.rawValue, "action": action,
            "stage": stage.rawValue, "refresh": refresh, "modelRecheck": modelRecheck, "productRecheck": productRecheck,
            "adapterDiagnosticPresent": observed["debugStructure"] != nil,
            "adapterDiagnosticAccepted": (observed["debugStructure"] as? String).flatMap {
                firstUserStructureDiagnosticRecords($0, provider: provider)
            } != nil]
        for key in ["temporary", "firstUserVerified", "firstUserMarkerVerified"] {
            summary[key] = observed[key] == nil ? "absent"
                : firstUserDiagnosticBool(observed[key]).map { $0 ? "true" : "false" } ?? "invalid"
        }
        if let number = ComputerToolArgumentContract.exactInt64(observed["userCount"]), (0...10_000).contains(number) {
            summary["userCountState"] = "valid"; summary["userCount"] = number
        } else { summary["userCountState"] = observed["userCount"] == nil ? "absent" : "invalid" }
        if let fingerprint = observed["firstUserFingerprint"] as? String,
           fingerprint.count == 64, fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            summary["fingerprintState"] = "valid"
        } else { summary["fingerprintState"] = observed["firstUserFingerprint"] == nil ? "absent" : "invalid" }
        var values = [summary]
        for (phase, state) in [("entry", entry), ("current", current)] {
            guard (0...10_000).contains(state.sequence), (0...10_000).contains(state.confirmedUsers) else { return nil }
            values.append(["kind": "first_user_native_state", "phase": phase, "sequence": state.sequence,
                "confirmedUsers": state.confirmedUsers, "pendingSubmission": state.pendingSubmission,
                "submitted": state.submitted, "temporary": state.temporary, "fingerprintPresent": state.fingerprintPresent,
                "bindingAllowed": action == "inspect" && state.sequence == 1 && state.pendingSubmission && !state.fingerprintPresent])
        }
        var records: [String] = []
        for value in values {
            guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys),
                  bytes.count <= 960 else { return nil }
            records.append(String(decoding: bytes, as: UTF8.self))
        }
        return records
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

    private func rejectWebsiteBlocker(_ session: Session, action: String, phase: String) throws {
        let url = session.view.url
        let initialBlank = session.documentGeneration == nil && url?.absoluteString == "about:blank"
        let unexpected = url.map { !initialBlank && !session.provider.accepts($0.absoluteString) } ?? false
        guard let failure = session.provider.blockingFailure(for: url) ?? (unexpected ? .unexpectedPage(session.provider) : nil) else { return }
        if failure == .humanVerificationRequired(.gemini), session.terminalFailure == nil,
           session.untouchedGoogleCheckpoint == nil,
           isUntouchedInference(session), sessions[session.token] === session,
           browser.webView(for: session.tabID) === session.view,
           let generation = browser.documentGeneration(for: session.tabID), let url {
            // This receipt grants only disposal of this exact private view.
            // It never authorizes JavaScript on Google's checkpoint document.
            session.untouchedGoogleCheckpoint = .init(documentGeneration: generation, url: url)
        }
        if failure == .signInRequired, session.provider == .chatgpt, session.terminalFailure == nil,
           session.untouchedChatGPTSignIn == nil, hasUntouchedInferenceState(session),
           sessions[session.token] === session, browser.webView(for: session.tabID) === session.view,
           let generation = browser.documentGeneration(for: session.tabID), let url,
           session.provider.acceptsUntouchedSignIn(url),
           browser.modelNavigationDiagnostic(tabID: session.tabID, view: session.view) != nil {
            // Native identity only; do not evaluate the adapter on an auth page.
            // A later document or URL cannot replace this first receipt.
            session.untouchedChatGPTSignIn = .init(documentGeneration: generation, url: url)
        }
        let navigation = browser.modelNavigationDiagnostic(tabID: session.tabID, view: session.view)?.logDescription
            ?? EmbeddedBrowserSession.ModelNavigationDiagnostic.unknownLogDescription
        Self.inspectionLog.error("websiteBlocked provider=\(session.provider.rawValue, privacy: .public) action=\(action, privacy: .public) phase=\(phase, privacy: .public) sequence=\(session.sequence) code=\(failure.diagnosticCode ?? "unknown", privacy: .public) firstFailure=\(session.terminalFailure == nil) navigation={\(navigation, privacy: .public)}")
        let firstFailure = session.terminalFailure == nil
        let recorded = recordedWebsiteBlocker(failure, session: session)
        if action == "inspect", phase == "before", failure == .humanVerificationRequired(.gemini) {
            enrollGeminiPostBlockDiagnostic(session, firstFailure: firstFailure)
        }
        throw recorded
    }


    /// Instrumentation only, after the original failure and saved gate exist.
    private func enrollGeminiPostBlockDiagnostic(_ session: Session, firstFailure: Bool) {
        guard geminiPostBlockDiagnosticEnabled, firstFailure, session.postBlockDiagnostic == nil,
              isUntouchedInference(session), sessions[session.token] === session,
              session.terminalFailure == .humanVerificationRequired(.gemini), session.state == "failed",
              providerGates[.gemini]?.failure == .humanVerificationRequired(.gemini),
              canDisposeUntouchedGoogleCheckpoint(session),
              let checkpointID = browser.savedHumanVerificationCheckpointIDs["gemini"],
              let facts = browser.modelNavigationDiagnostic(tabID: session.tabID, view: session.view),
              facts.settled, !facts.geminiDocumentCommitObserved else { return }
        let capture = GeminiPostBlockDiagnostic(duration: geminiPostBlockDiagnosticDuration, checkpointID: checkpointID)
        guard let lease = browser.beginGeminiPostBlockNativeObservation(tabID: session.tabID, view: session.view,
            ownerToken: session.token, callback: { [weak self, weak session, weak capture] event in
                guard let self, let session, let capture, session.postBlockDiagnostic === capture,
                      !capture.completed else { return }
                self.recordGeminiPostBlockDiagnostic(session, capture: capture, event: event.rawValue)
                if event == .closed || event == .terminated {
                    if event == .closed, capture.lease?.exactViewClosed == true,
                       self.browser.webView(for: session.tabID) == nil { capture.physicallyClosed = true }
                    capture.interruption = event.rawValue
                    capture.task?.cancel()
                } else if self.browser.savedHumanVerificationCheckpointIDs["gemini"] != capture.checkpointID {
                    capture.interruption = "gate_changed"
                    capture.task?.cancel()
                }
            }) else { return }
        capture.lease = lease
        session.postBlockDiagnostic = capture
        recordGeminiPostBlockDiagnostic(session, capture: capture, event: "enrolled")
        // The timer starts at the saved block, not at Finish, and is never
        // replaced or renewed by a callback, poll or concurrent cleanup.
        capture.task = Task { @MainActor [self, session, capture] in
            do {
                let snapshot = capture.started + .seconds(1)
                if snapshot < capture.deadline {
                    try await ContinuousClock().sleep(until: snapshot)
                    recordGeminiPostBlockDiagnostic(session, capture: capture, event: "snapshot")
                }
                try await ContinuousClock().sleep(until: capture.deadline)
            } catch {
                if capture.interruption == nil { capture.interruption = "cancelled" }
            }
            return completeGeminiPostBlockDiagnostic(session, capture: capture)
        }
    }

    private func recordGeminiPostBlockDiagnostic(_ session: Session, capture: GeminiPostBlockDiagnostic,
                                                event: String, terminal: Bool = false,
                                                ordinaryCleanupVerified: Bool = false) {
        guard session.postBlockDiagnostic === capture, terminal || !capture.completed else { return }
        guard capture.records < (terminal ? 32 : 31) else {
            if !terminal { capture.truncated = true }
            return
        }
        if !terminal, ContinuousClock.now >= capture.deadline {
            capture.interruption = capture.interruption ?? "deadline"
            capture.task?.cancel()
            return
        }
        let present = browser.webView(for: session.tabID) === session.view
        let facts = browser.modelNavigationDiagnostic(tabID: session.tabID, view: session.view)
        var ordinal: Any = NSNull()
        if present, let generation = browser.documentGeneration(for: session.tabID) {
            if capture.generations[generation] == nil, capture.generations.count < 32 {
                capture.generations[generation] = capture.generations.count + 1
            }
            if let value = capture.generations[generation] { ordinal = value }
        }
        let route: String
        if !present { route = "unknown" }
        else if session.provider.blockingFailure(for: session.view.url) == .humanVerificationRequired(.gemini) { route = "google_verification" }
        else if session.provider.blockingFailure(for: session.view.url) == .signInRequired { route = "signin" }
        else if session.view.url.map({ session.provider.accepts($0.absoluteString) }) == true { route = "provider" }
        else { route = session.view.url == nil ? "unknown" : "other" }
        let elapsed = ContinuousClock.now - capture.started
        let milliseconds = max(0, min(60_000, elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
        var record: [String: Any] = [
            "kind": "gemini_post_block_native_v1", "captureID": capture.id.uuidString.lowercased(),
            "event": event, "elapsedMs": milliseconds, "maximumMs": 5_000,
            "exactViewPresent": present, "generationOrdinal": ordinal, "routeClass": route,
            "known": facts != nil, "loading": facts.map { $0.viewLoading as Any } ?? NSNull(),
            "pending": facts.map { $0.navigationPending as Any } ?? NSNull(),
            "committed": facts.map { $0.generationCommitted as Any } ?? NSNull(),
            "finished": facts.map { $0.generationFinished as Any } ?? NSNull(),
            "navigationError": facts.map { $0.navigationError as Any } ?? NSNull(),
            "checkpointUnchanged": browser.savedHumanVerificationCheckpointIDs["gemini"] == capture.checkpointID,
            "adapterDispatched": session.providerAdapterEverDispatched, "sequence": session.sequence,
            "taskFailed": session.terminalFailure == .humanVerificationRequired(.gemini),
            "physicallyClosed": capture.physicallyClosed, "ordinaryCleanupVerified": ordinaryCleanupVerified,
            "eventsTruncated": capture.truncated,
        ]
        // Ignore identical adjacent callbacks; truncation never prolongs life.
        let signature = record.filter { !["captureID", "elapsedMs"].contains($0.key) }
        guard let signatureData = try? JSONSerialization.data(withJSONObject: signature, options: .sortedKeys) else { return }
        let signatureString = String(decoding: signatureData, as: UTF8.self)
        guard terminal || signatureString != capture.lastSignature else { return }
        capture.lastSignature = signatureString
        capture.records += 1
        record["record"] = capture.records
        if terminal { record["disposalCause"] = capture.interruption ?? "deadline" }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys), data.count <= 960 else { return }
        #if DEBUG
        geminiPostBlockObserverForTesting?(record)
        #endif
        Self.inspectionLog.error("geminiPostBlockDiagnostic \(String(decoding: data, as: UTF8.self), privacy: .public)")
    }

    private func completeGeminiPostBlockDiagnostic(_ session: Session, capture: GeminiPostBlockDiagnostic) -> Data {
        capture.completed = true
        let ordinary = canDisposeUntouchedGoogleCheckpoint(session)
        let authority = sessions[session.token] === session && isUntouchedInference(session)
        if let lease = capture.lease {
            if lease.exactViewClosed, browser.webView(for: session.tabID) == nil {
                capture.physicallyClosed = true
            } else if authority {
                // The diagnostic lease is separately scoped to this never-used
                // private view, not to the now-possibly-stale checkpoint route.
                capture.physicallyClosed = browser.disposeGeminiPostBlockDiagnosticView(lease)
            }
            browser.endGeminiPostBlockNativeObservation(lease)
        }
        if !authority { capture.interruption = "authority_lost" }
        else if !capture.physicallyClosed { capture.interruption = "identity_lost" }
        recordGeminiPostBlockDiagnostic(session, capture: capture, event: "disposed", terminal: true,
                                       ordinaryCleanupVerified: ordinary && capture.physicallyClosed)
        // Preserve the original failed task and saved gate. A changed-generation
        // diagnostic close cannot forge the ordinary not_created receipt.
        session.state = "failed"
        return (try? snapshot(session, cleanup: ordinary && capture.physicallyClosed ? "not_created" : "failed")) ?? Data("{}".utf8)
    }

    private func isUntouchedInference(_ session: Session) -> Bool {
        session.provider == .gemini && hasUntouchedInferenceState(session)
    }

    private func hasUntouchedInferenceState(_ session: Session) -> Bool {
        !session.isDiscovery && !session.isRecoveryProbe
            && !session.providerAdapterEverDispatched && session.sequence == 0
            && !session.submitted && !session.pendingSubmission && session.confirmedUsers == 0
            && !session.temporaryRequested && !session.temporary && !session.chatModeRequested
            && !session.modelSelectionRequested && !session.modelSelectionVerified
            && session.preparedSubmission == nil && session.currentSubmission == nil && session.previousSubmission == nil
            && !session.currentSubmissionVerified && session.firstUserFingerprint == nil
            && session.documentGeneration == nil && session.routeContext == nil && session.conversation == nil
            && session.modelEvidence == nil && session.productModeEvidence == nil
            && session.baseline == 0 && session.observedResponseCount == 0
    }

    private func canDisposeUntouchedGoogleCheckpoint(_ session: Session) -> Bool {
        guard isUntouchedInference(session), sessions[session.token] === session,
              browser.webView(for: session.tabID) === session.view,
              let checkpoint = session.untouchedGoogleCheckpoint,
              browser.documentGeneration(for: session.tabID) == checkpoint.documentGeneration,
              session.view.url == checkpoint.url else { return false }
        return session.provider.blockingFailure(for: checkpoint.url) == .humanVerificationRequired(.gemini)
    }

    private func canDisposeUntouchedChatGPTSignIn(_ session: Session) -> Bool {
        guard session.provider == .chatgpt, hasUntouchedInferenceState(session), sessions[session.token] === session,
              browser.webView(for: session.tabID) === session.view,
              let checkpoint = session.untouchedChatGPTSignIn,
              browser.documentGeneration(for: session.tabID) == checkpoint.documentGeneration,
              session.view.url == checkpoint.url, session.provider.acceptsUntouchedSignIn(checkpoint.url),
              browser.modelNavigationDiagnostic(tabID: session.tabID, view: session.view)?.settled == true else { return false }
        return true
    }

    private struct FirstUserExpansionRouteEdge {
        let fromURL: URL
        let toURL: URL
    }

    /// Ephemeral receipts for the existing first-route allowance, never a new
    /// navigation or a session-wide permission. Only root/local/public order
    /// is possible, even when JavaScript has not consumed the first receipt.
    private static func appendingFirstUserExpansionRoute(_ edges: [FirstUserExpansionRouteEdge],
                                                        from: URL, to: URL) throws -> [FirstUserExpansionRouteEdge] {
        let provider = Provider.chatgpt
        let source = provider.conversationURL(from.absoluteString)
        let destination = provider.conversationURL(to.absoluteString)
        guard edges.count < 2, from != to, provider.accepts(from.absoluteString), provider.accepts(to.absoluteString),
              provider.routeContext(from.absoluteString) == provider.routeContext(to.absoluteString),
              destination != nil else { throw Failure.ownershipFailure(.routeAfter) }
        let rootToFirst = source == nil && edges.isEmpty
        let localToPublic = provider.isLocalConversation(source) && !provider.isLocalConversation(destination)
        guard rootToFirst || localToPublic else { throw Failure.ownershipFailure(.routeAfter) }
        if let preceding = edges.last {
            guard edges.count == 1, preceding.toURL == from,
                  provider.conversationURL(preceding.fromURL.absoluteString) == nil,
                  provider.isLocalConversation(provider.conversationURL(preceding.toURL.absoluteString)),
                  localToPublic else { throw Failure.ownershipFailure(.routeAfter) }
        }
        return edges + [FirstUserExpansionRouteEdge(fromURL: from, toURL: to)]
    }

    /// Passive synthetic measurements are always removed before observation
    /// validation. Invalid/missing/foreign values are unknown, never authority.
    static func removeMatchedBenchmarkMilestones(from observed: inout [String: Any],
        binding: WebsiteBenchmarkCaptureLease.ObservationBinding?) -> [String: Any]? {
        let raw = observed.removeValue(forKey: "benchmarkMilestones")
        let hashes = ["editorSHA256", "editorCanonicalSHA256", "editorRenderedSHA256", "userSHA256", "responseSHA256"]
        let counts = ["editorUTF8Bytes", "editorRenderedUTF8Bytes", "userUTF8Bytes", "responseUTF8Bytes"]
        let durations = ["sendSinceInstallMs", "firstTextAfterSendMs", "firstCompleteAfterSendMs", "lastTextChangeAfterSendMs"]
        let flags = ["editorMatchesExpected", "userMatchesExpected"]
        let keys = ["schemaVersion", "nonce", "expectedSHA256", "expectedCanonicalSHA256", "expectedUTF8Bytes", "invalidReason",
                    "sendClickCount", "userCount", "assistantCount", "payloadMatched", "currentComplete", "installedUnixMs", "sendUnixMs", "completionScope", "responseKind", "editorRepresentation"]
            + hashes + counts + durations + flags
        guard let binding, let value = raw as? [String: Any], Set(value.keys) == Set(keys),
              value["nonce"] as? String == binding.nonce.uuidString.lowercased(),
              value["expectedSHA256"] as? String == binding.rawOutboundSHA,
              value["expectedCanonicalSHA256"] as? String == binding.canonicalOutboundSHA,
              let reason = value["invalidReason"] as? String,
              ["none", "not_fresh", "document_changed", "extra_user", "extra_answer", "user_root_changed", "answer_root_changed", "user_body_changed",
               "multiple_sends", "editor_unavailable", "editor_mismatch", "hash_failed", "expired", "overflow"].contains(reason),
              let scope = value["completionScope"] as? String, ["none", "assistant_ancestor", "paired_turn"].contains(scope),
              let kind = value["responseKind"] as? String, ["none", "code", "rendered"].contains(kind) else { return nil }
        guard let representation = value["editorRepresentation"] as? String,
              ["unknown", "exact", "single_terminal_newline"].contains(representation) else { return nil }
        func number(_ key: String, upper: Double) -> Double? {
            guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, (0...upper).contains(n.doubleValue) else { return nil }
            return n.doubleValue
        }
        guard number("schemaVersion", upper: 1) == 1,
              number("expectedUTF8Bytes", upper: 180_200) == Double(binding.utf8Bytes) else { return nil }
        var safe: [String: Any] = ["schemaVersion": 1, "nonce": binding.nonce.uuidString.lowercased(),
            "expectedSHA256": binding.rawOutboundSHA, "expectedCanonicalSHA256": binding.canonicalOutboundSHA,
            "expectedUTF8Bytes": binding.utf8Bytes, "invalidReason": reason, "completionScope": scope, "responseKind": kind,
            "editorRepresentation": representation]
        for key in ["sendClickCount", "userCount", "assistantCount"] {
            guard let n = number(key, upper: 2), n.rounded() == n else { return nil }; safe[key] = Int(n)
        }
        for key in counts {
            if value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let n = number(key, upper: key == "responseUTF8Bytes" ? 220_000 : 180_200), n.rounded() == n else { return nil }; safe[key] = Int(n)
        }
        for key in hashes {
            if value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let h = value[key] as? String, h.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }; safe[key] = h
        }
        for key in durations {
            if value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let n = number(key, upper: 600_000) else { return nil }; safe[key] = n
        }
        for key in ["installedUnixMs", "sendUnixMs"] {
            if key == "sendUnixMs", value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let n = number(key, upper: 4_102_444_800_000), n >= 946_684_800_000, n.rounded() == n else { return nil }; safe[key] = n
        }
        for key in flags + ["payloadMatched", "currentComplete"] {
            if flags.contains(key), value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let n = value[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; safe[key] = n.boolValue
        }
        if safe["editorMatchesExpected"] as? Bool == true {
            guard representation != "unknown", safe["editorSHA256"] as? String == binding.rawOutboundSHA,
                  safe["editorUTF8Bytes"] as? Int == binding.utf8Bytes else { return nil }
            // Hash callbacks can finish in either order. A pending rendered hash
            // is unknown; a populated one must describe the explicit extraction.
            if let renderedBytes = safe["editorRenderedUTF8Bytes"] as? Int,
               let renderedHash = safe["editorRenderedSHA256"] as? String {
                guard representation == "exact" && renderedBytes == binding.utf8Bytes && renderedHash == binding.rawOutboundSHA
                    || representation == "single_terminal_newline" && renderedBytes == binding.utf8Bytes + 1
                        && renderedHash != binding.rawOutboundSHA else { return nil }
            }
        }
        if safe["userMatchesExpected"] as? Bool == true {
            guard safe["userSHA256"] as? String == binding.canonicalOutboundSHA else { return nil }
        }
        if safe["payloadMatched"] as? Bool == true {
            guard reason == "none", safe["sendClickCount"] as? Int == 1, safe["userCount"] as? Int == 1,
                  safe["assistantCount"] as? Int == 1, safe["editorMatchesExpected"] as? Bool == true,
                  safe["userMatchesExpected"] as? Bool == true else { return nil }
        }
        return safe
    }

    /// Diagnostic metadata is removed before any observation shape or authority
    /// checks. Invalid/missing timings are unknown, never an inference failure.
    static func removePreparationTiming(from observed: inout [String: Any]) -> [String: Any]? {
        let raw = observed.removeValue(forKey: "preparationTiming")
        let durations = ["totalMs", "beginSubmissionMs", "beginSubmissionHashMs", "modelPrecheckMs",
                         "finalGuardMs", "editorFocusMs", "editorMutationMs", "inputDispatchMs", "editorReadinessMs",
                         "outerSetupMs", "guardedSetupMs", "providerEntryMs", "providerSetupMs", "insertPreFocusMs",
                         "insertPostFocusMs", "providerReturnMs", "guardedFinalizationMs", "outerFinalizationMs"]
        guard let value = raw as? [String: Any], Set(value.keys) == Set(durations + ["openingRecoveryUsed", "editorReadyAtEntry"]),
              let flag = value["openingRecoveryUsed"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
        var safe: [String: Any] = ["openingRecoveryUsed": flag.boolValue]
        if value["editorReadyAtEntry"] is NSNull { safe["editorReadyAtEntry"] = NSNull() }
        else {
            guard let ready = value["editorReadyAtEntry"] as? NSNumber, CFGetTypeID(ready) == CFBooleanGetTypeID() else { return nil }
            safe["editorReadyAtEntry"] = ready.boolValue
        }
        for key in durations {
            if value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...45_000).contains(number.doubleValue) else { return nil }
            safe[key] = number.doubleValue
        }
        return safe
    }

    private static func preparationMilliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(max(0, min(600_000, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)))
    }

    private func canShareFirstChatGPTEditorContextRecheck(_ session: Session) -> Bool {
        session.provider == .chatgpt && session.state == "ready" && !session.submitted && !session.pendingSubmission
            && session.sequence == 0 && session.confirmedUsers == 0 && session.firstUserFingerprint == nil
            && session.currentSubmission == nil && session.previousSubmission == nil
            && session.temporary && session.temporaryRequested && session.modelChoice != nil
            && session.modelSelectionVerified && !session.modelVerificationPending
    }

    private func canConsolidateFirstInstantReadinessProof(_ session: Session) -> Bool {
        canShareFirstChatGPTEditorContextRecheck(session)
            && !session.isDiscovery && !session.isRecoveryProbe && session.usesSubmissionOwnership
            && session.modelChoice?.key == "chat/latest/instant"
            && session.preparedSubmission?.sequence == 1 && session.preparedSubmission?.marker == session.firstUserMarker
            && session.baseline == 0 && session.observedResponseCount == 0 && session.conversation == nil
            && session.documentGeneration != nil && session.routeContext != nil && session.productModeEvidence != nil
    }

    private func canPrepareFirstInstantInInsert(_ session: Session) -> Bool {
        canShareFirstChatGPTEditorContextRecheck(session)
            && !session.isDiscovery && !session.isRecoveryProbe && session.usesSubmissionOwnership
            && session.modelChoice?.key == "chat/latest/instant" && session.preparedSubmission == nil
            && session.baseline == 0 && session.observedResponseCount == 0 && session.conversation == nil
            && session.documentGeneration != nil && session.routeContext != nil && session.productModeEvidence != nil
    }

    private func page(_ session: Session, action: String, prompt: String? = nil, enforceModel: Bool = true,
                      refreshChangedRoute: Bool = true, recheckModelAfterAwait: Bool = true, recheckProductAfterAwait: Bool = true,
                      refreshReadOnlyObservation: Bool = true,
                      allowBlockedProvider: Bool = false, allowPendingModelTemporary: Bool = false,
                      allowPendingChatGPTModelVerification: Bool = true,
                      firstUserExpansionRouteContinuation: [FirstUserExpansionRouteEdge] = [],
                      prepareFirstInstantInInsert: Bool = false,
                      maximumWait: Duration = .seconds(10)) async throws -> [String: Any] {
        let preparationActionStarted = ContinuousClock.now
        let logPreparationAction = session.provider == .chatgpt
            && (session.state == "loading" || !session.submitted || action == "submit")
            && ["inspect", "ensureChatMode", "verifyProductMode", "enableTemporary", "selectModel",
                "verifyModel", "prepare", "insert", "sendReady", "submit"].contains(action)
        let profilePreparation = session.provider == .chatgpt && !session.isDiscovery
            && session.confirmedUsers == 0 && session.sequence <= 1
            && ["prepare", "insert", "sendReady", "submit", "verifyModel", "verifyProductMode"].contains(action)
            && (session.state == "loading" || !session.submitted || action == "submit")
        var preparationSpans: [String: Int] = [:]
        defer {
            if profilePreparation {
                let total = Self.preparationMilliseconds(.now - preparationActionStarted)
                let setup = preparationSpans["nativeSetupMs"] ?? -1
                let evaluation = preparationSpans["evaluationMs"] ?? -1
                let validation = preparationSpans["callbackValidationMs"] ?? -1
                let product = preparationSpans["postProductMs"] ?? -1
                let between = preparationSpans["betweenChecksMs"] ?? -1
                let model = preparationSpans["postModelMs"] ?? -1
                let final = preparationSpans["finalValidationMs"] ?? -1
                Self.inspectionLog.notice("preparationSpans provider=chatgpt action=\(action, privacy: .public) nativeSetupMs=\(setup) evaluationMs=\(evaluation) callbackValidationMs=\(validation) postProductMs=\(product) betweenChecksMs=\(between) postModelMs=\(model) finalValidationMs=\(final) totalMs=\(total)")
            }
            if logPreparationAction {
                let elapsed = (ContinuousClock.now - preparationActionStarted).components
                let milliseconds = Int(max(0, min(600_000,
                    Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)))
                Self.inspectionLog.info("preparationAction provider=chatgpt action=\(action, privacy: .public) elapsedMs=\(milliseconds)")
            }
        }
        guard maximumWait > .zero else { throw Failure.pageUnavailable }
        let evaluationDeadline = ContinuousClock.now + maximumWait
        let budgetParts = maximumWait.components
        let allocatedBudgetMilliseconds = Int(max(0, min(45_000,
            Double(budgetParts.seconds) * 1_000 + Double(budgetParts.attoseconds) / 1e15)))
        if !allowBlockedProvider { try checkProviderGate(session) }
        guard browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
        try rejectWebsiteBlocker(session, action: action, phase: "before")
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
            if candidate != nil, candidate?.absoluteString != "about:blank" { throw Failure.unexpectedPage(provider) }
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
        // Cleanup also inspects pending lineage. It may verify an already
        // rendered message, but must never acquire expansion-click authority.
        let allowFirstUserExpansion = provider == .chatgpt && action == "inspect" && !allowBlockedProvider
            && !session.isDiscovery && session.state == "running" && session.submitted
            && session.sequence == 1 && session.confirmedUsers == 0 && session.pendingSubmission
            && session.temporary && session.firstUserFingerprint == nil
            && session.modelSelectionVerified && session.modelChoice != nil
        var routeContinuation = firstUserExpansionRouteContinuation
        var routeRefreshAvailable = refreshChangedRoute
        if let preceding = routeContinuation.last {
            guard allowFirstUserExpansion else { throw Failure.ownershipFailure(.routeBefore) }
            if preceding.toURL != url {
                // The allowed public promotion can arrive after native accepts
                // the local edge but before this recursive inspect starts.
                guard routeRefreshAvailable, !session.promoted,
                      session.conversation == nil || session.conversation == provider.conversationURL(preceding.toURL.absoluteString),
                      provider.isLocalConversation(provider.conversationURL(preceding.toURL.absoluteString)),
                      current != nil, !provider.isLocalConversation(current) else {
                    throw Failure.ownershipFailure(.routeBefore)
                }
                routeContinuation = try Self.appendingFirstUserExpansionRoute(routeContinuation, from: preceding.toURL, to: url)
                routeRefreshAvailable = false
            }
        }
        var input: [String: Any] = [
            "provider": provider.rawValue, "action": action, "expectedURL": url.absoluteString,
            "ownerToken": session.token, "bindOwner": session.state == "loading" && !session.submitted,
            "expectedUserCounts": expectedCounts,
            "expectedFirstUserMarker": session.firstUserMarker,
            "allowFirstUserBinding": action == "inspect" && session.sequence == 1
                && session.pendingSubmission && session.firstUserFingerprint == nil,
            "allowFirstUserExpansion": allowFirstUserExpansion,
            "allowSubmissionExpansion": provider == .chatgpt && ["inspect", "verifyModel"].contains(action)
                && session.pendingSubmission && session.sequence > 1,
        ]
        // A saved, separately leased synthetic capture only requests passive
        // measurement; it cannot change readiness, waits or inference authority.
        let benchmarkFirstInsert = action == "insert" && session.sequence == 0 && !session.submitted
            && session.confirmedUsers == 0 && session.baseline == 0 && session.observedResponseCount == 0
            && session.preparedSubmission?.sequence == 1
        let benchmarkFirstInspect = action == "inspect" && session.sequence == 1
        if provider == .chatgpt, session.modelChoice?.key == "chat/latest/instant",
           benchmarkFirstInsert || benchmarkFirstInspect, let binding = session.benchmarkObservationBinding {
            input["matchedBenchmarkProbe"] = ["schemaVersion": 1, "nonce": binding.nonce.uuidString.lowercased(),
                "expectedSHA256": binding.rawOutboundSHA, "expectedCanonicalSHA256": binding.canonicalOutboundSHA,
                "expectedUTF8Bytes": binding.utf8Bytes]
        }
        // Only a claimed current Send may defer positive model proof. The
        // adapter still performs submit's full precheck before the actual click.
        let deferModelVerification = allowPendingChatGPTModelVerification && !allowBlockedProvider && provider == .chatgpt
            && session.state == "running" && session.submitted && session.modelVerificationPending
            && ["inspect", "submit", "verifyModel", "verifyProductMode"].contains(action)
        if provider == .chatgpt { input["deferModelVerification"] = deferModelVerification }
        if action == "sendReady", canConsolidateFirstInstantReadinessProof(session) {
            // This removes only the read-only action's duplicate model precheck.
            // Its full final proof, native model/product callbacks, original
            // readiness wait/deadline and eventual submit all remain unchanged.
            input["firstInstantReadinessFinalGuardOnly"] = true
        }
        if prepareFirstInstantInInsert {
            guard action == "insert", canShareFirstChatGPTEditorContextRecheck(session),
                  session.modelChoice?.key == "chat/latest/instant", session.conversation == nil,
                  session.baseline == 0, session.observedResponseCount == 0,
                  session.preparedSubmission?.sequence == 1 else { throw Failure.invalidRequest }
            input["prepareFirstInstantInInsert"] = true
        }
        if profilePreparation { input["preparationTiming"] = true }
        if provider == .chatgpt, session.firstBodyReadRecoveryActive {
            input["suppressFirstUserExpansionClaim"] = true
        }
        if session.usesSubmissionOwnership {
            // Only already-dispatched bindings authorize a detached-message
            // inspection. A prepared, unsent body cannot supply this pin.
            input["expectedSubmissionProofs"] = [session.previousSubmission, session.currentSubmission]
                .compactMap { $0 }.map { ["sequence": $0.sequence, "fingerprint": $0.outboundFingerprint] as [String: Any] }
            let editorAction = ["insert", "sendReady", "submit"].contains(action)
            if let binding = editorAction ? session.preparedSubmission : session.currentSubmission {
                input["submissionMarker"] = binding.marker
                input["submissionSequence"] = binding.sequence
            }
        }
        if allowFirstUserExpansion, !routeContinuation.isEmpty {
            // A bounded contiguous chain survives an unconsumed intermediate
            // read. Cleanup and unrelated read refreshes receive no receipts.
            input["firstUserExpansionRouteContinuation"] = routeContinuation.map {
                ["fromURL": $0.fromURL.absoluteString, "toURL": $0.toURL.absoluteString]
            }
        }
        if let choice = session.modelChoice {
            if allowFirstUserExpansion {
                input["firstUserExpansionModelChoice"] = ["key": choice.key, "label": choice.label]
            }
            if action == "selectModel" { input["modelChoice"] = ["key": choice.key, "label": choice.label] }
            if enforceModel || deferModelVerification, session.modelSelectionVerified, !["stop", "cleanup", "discoverModels"].contains(action) {
                input["expectedModelChoice"] = ["key": choice.key, "label": choice.label]
            }
        } else if provider == .gemini, session.modelSelectionVerified, let evidence = session.modelEvidence,
                  !["stop", "cleanup", "discoverModels"].contains(action) {
            input["expectedModelChoice"] = ["key": evidence.selected.key, "label": evidence.selected.label]
        }
        if let fingerprint = session.firstUserFingerprint { input["expectedFirstUserFingerprint"] = fingerprint }
        if let conversation = session.conversation, !promotion { input["expectedConversation"] = conversation }
        // Website selection IDs can change during ordinary re-rendering.
        // Authority comes from generation, private owner, pinned route, counts
        // and pinned first-message lineage; an auxiliary ID cannot veto it.
        if let prompt { input["prompt"] = prompt }
        let operationID = UUID()
        input["operationID"] = operationID.uuidString
        try browser.beginModelDiagnostic(tabID: session.tabID, ownerToken: session.token, operationID: operationID)
        defer { browser.endModelDiagnostic(tabID: session.tabID, operationID: operationID) }
        let firstUserEntry = firstUserNativeState(session)
        func recordFirstUserFailure(_ stage: FirstUserNativeStage, observed: [String: Any]) {
            guard let records = Self.firstUserNativeDiagnosticRecords(provider: provider, action: action, stage: stage,
                entry: firstUserEntry, current: firstUserNativeState(session), observed: observed,
                refresh: refreshReadOnlyObservation, modelRecheck: recheckModelAfterAwait, productRecheck: recheckProductAfterAwait) else { return }
            for record in records { Self.inspectionLog.error("firstUserNative \(record, privacy: .public)") }
            #if DEBUG
            firstUserDiagnosticsObserverForTesting?(records)
            #endif
        }
        #if DEBUG
        if !routeContinuation.isEmpty { await firstUserExpansionRouteCheckpointForTesting?(.continuationInput) }
        #endif
        browser.captureModelNativeFocus(tabID: session.tabID)
        defer { browser.restoreModelNativeFocus(tabID: session.tabID) }
        let result = EmbeddedScriptResult()
        let bytes: Data
        do {
            let evaluationStarted = ContinuousClock.now
            if profilePreparation { preparationSpans["nativeSetupMs"] = Self.preparationMilliseconds(evaluationStarted - preparationActionStarted) }
            defer {
                if profilePreparation {
                    preparationSpans["evaluationMs"] = Self.preparationMilliseconds(.now - evaluationStarted)
                }
            }
            bytes = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    result.install(continuation)
                    let timeout = Task {
                        do {
                            try await Task.sleep(until: evaluationDeadline, clock: .continuous)
                            guard result.isPending else { return }
                            let diagnostic = browser.modelDiagnosticSnapshot(tabID: session.tabID, operationID: operationID)
                            Self.inspectionLog.error("adapterTimeout provider=\(provider.rawValue, privacy: .public) action=\(action, privacy: .public) sequence=\(session.sequence) budgetMs=\(allocatedBudgetMilliseconds) \(diagnostic, privacy: .public)")
                            if ["inspect", "verifyModel", "verifyProductMode"].contains(action) {
                                session.readTimeoutCount += 1
                            }
                            #if DEBUG
                            adapterTimeoutObserverForTesting?(diagnostic)
                            #endif
                            result.complete(.failure(Failure.pageUnavailable))
                        } catch { }
                    }
                    result.setTimeout(timeout)
                    guard result.isPending else { return }
                    session.providerAdapterEverDispatched = true
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
        } catch {
            if !Task.isCancelled, browser.webView(for: session.tabID) === session.view {
                // A challenge redirect can destroy the JavaScript context. Use
                // only its native URL classification; never execute on it.
                try rejectWebsiteBlocker(session, action: action, phase: "callback_failure")
            }
            throw error
        }
        let callbackValidationStarted = ContinuousClock.now
        // A callback and its timeout can become runnable together. A late
        // result must not win that scheduling race and gain page authority.
        guard ContinuousClock.now < evaluationDeadline else { throw Failure.pageUnavailable }
        browser.endModelDiagnostic(tabID: session.tabID, operationID: operationID)
        #if DEBUG
        await beforePageResultValidationForTesting?(action)
        await beforePageResultValidationDetailedForTesting?(action, enforceModel)
        #endif
        if !allowBlockedProvider { try checkProviderGate(session) }
        guard browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
        try rejectWebsiteBlocker(session, action: action, phase: "after")
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
            Self.inspectionLog.info("routeTransition provider=\(provider.rawValue, privacy: .public) action=\(action, privacy: .public) sequence=\(session.sequence) submitted=\(session.submitted) oldConversation=\(current != nil) newConversation=\(nextConversation != nil) oldLocal=\(provider.isLocalConversation(current)) newLocal=\(provider.isLocalConversation(nextConversation)) refresh=\(routeRefreshAvailable) first=\(firstConversation) promotion=\(promotedConversation)")
            if ["inspect", "verifyModel", "verifyProductMode"].contains(action), routeRefreshAvailable, firstConversation || promotedConversation {
                // Discard every crossed read. ChatGPT can create a local route
                // and promote it during the next read before either result can
                // bind the conversation. Only that first empty-to-local edge
                // leaves one refresh for its monotonic public promotion. The
                // predicates above reject another local or public conversation.
                let awaitingLocalPromotion = firstConversation && current == nil
                    && provider.isLocalConversation(nextConversation)
                let nextContinuation = allowFirstUserExpansion
                    ? try Self.appendingFirstUserExpansionRoute(routeContinuation, from: url, to: currentURL) : []
                if provider == .chatgpt, !nextContinuation.isEmpty {
                    for edge in nextContinuation {
                        session.temporaryCookieRoutes.observe(edge.fromURL)
                        session.temporaryCookieRoutes.observe(edge.toURL)
                    }
                }
                #if DEBUG
                if !nextContinuation.isEmpty { await firstUserExpansionRouteCheckpointForTesting?(.routeAccepted) }
                #endif
                return try await page(session, action: "inspect", enforceModel: enforceModel,
                                      refreshChangedRoute: awaitingLocalPromotion, recheckModelAfterAwait: recheckModelAfterAwait, recheckProductAfterAwait: recheckProductAfterAwait,
                                      refreshReadOnlyObservation: refreshReadOnlyObservation,
                                      allowBlockedProvider: allowBlockedProvider,
                                      allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                      firstUserExpansionRouteContinuation: nextContinuation,
                                      maximumWait: evaluationDeadline - .now)
            }
            let temporaryToggle = action == "enableTemporary" && session.state == "loading"
                && !session.submitted && current == nil && nextConversation == nil
                && provider.acceptsTemporaryToggle(currentURL)
            // Send can synchronously create the first SPA route before its
            // acknowledgment returns. The next poll verifies its conversation.
            guard action == "submit" && firstConversation || temporaryToggle else { throw Failure.ownershipFailure(.routeAfter) }
        }
        try Task.checkCancellation()
        guard var observed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.pageUnavailable }
        if provider == .chatgpt {
            let timing = Self.removePreparationTiming(from: &observed)
            if profilePreparation, let timing,
               let data = try? JSONSerialization.data(withJSONObject: timing, options: .sortedKeys),
               let structure = String(data: data, encoding: .utf8) {
                Self.inspectionLog.notice("preparationJavaScript provider=chatgpt action=\(action, privacy: .public) structure=\(structure, privacy: .public)")
            }
        }
        let benchmark = Self.removeMatchedBenchmarkMilestones(from: &observed,
            binding: provider == .chatgpt ? session.benchmarkObservationBinding : nil)
        if action == "inspect", let benchmark, session.benchmarkObservationLogCount < 32,
           let data = try? JSONSerialization.data(withJSONObject: benchmark, options: .sortedKeys), data.count <= 4_096,
           let structure = String(data: data, encoding: .utf8), structure != session.lastBenchmarkObservationLog {
            session.lastBenchmarkObservationLog = structure; session.benchmarkObservationLogCount += 1
            Self.inspectionLog.notice("matchedBenchmark provider=chatgpt sequence=\(session.sequence) structure=\(structure, privacy: .public)")
        }
        logModelDiagnostic(observed, session: session)
        if let safe = Self.sanitizedProductModeDiagnostic(observed["productModeDiagnostic"]),
           safe != session.lastProductModeDiagnostic {
            session.lastProductModeDiagnostic = safe
            Self.inspectionLog.error("productModeDiagnostic provider=\(provider.rawValue, privacy: .public) action=\(action, privacy: .public) sequence=\(session.sequence) structure=\(safe, privacy: .public)")
        }
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
            case "product_mode_unverified": throw Failure.productModeUnverified
            case "model_unverified": throw Failure.modelUnverified
            case "model_mismatch": throw Failure.modelMismatch
            case "model_unavailable": throw Failure.modelUnavailable
            case "acknowledged_user_append":
                // A read-only picker observation can cross the DOM append for
                // our already acknowledged Send. Discard that observation and
                // inspect once from the current page, including the exact first
                // marker/fingerprint checks. Never replay an editor operation.
                guard refreshReadOnlyObservation, ["inspect", "verifyModel", "verifyProductMode"].contains(action),
                      observed["detail"] as? String == "readonly_model_observation",
                      session.submitted, session.pendingSubmission,
                      session.confirmedUsers + 1 == session.sequence else {
                    throw Failure.ownershipFailure(.javaScriptUserCount)
                }
                return try await page(session, action: "inspect", enforceModel: enforceModel,
                                      refreshChangedRoute: false, recheckModelAfterAwait: recheckModelAfterAwait, recheckProductAfterAwait: recheckProductAfterAwait,
                                      refreshReadOnlyObservation: false, allowBlockedProvider: allowBlockedProvider,
                                      allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                      maximumWait: evaluationDeadline - .now)
            case "submission_observation_replaced":
                let bindings = [session.currentSubmission, session.previousSubmission].compactMap { $0 }
                guard provider == .gemini, refreshReadOnlyObservation,
                      ["inspect", "verifyModel"].contains(action),
                      observed["detail"] as? String == "readonly_model_observation",
                      session.submitted, session.firstUserFingerprint != nil,
                      let proof = observed["replacementSubmissionProof"],
                      bindings.contains(where: { Self.validSubmissionProof(proof,
                          sequence: $0.sequence, fingerprint: $0.outboundFingerprint) }) else {
                    logSubmissionFailure(session, action: action, stage: .replacementRefreshRejected, observed: observed)
                    throw Failure.ownershipFailure(.javaScriptSubmission)
                }
                return try await page(session, action: "inspect", enforceModel: enforceModel,
                                      refreshChangedRoute: false, recheckModelAfterAwait: recheckModelAfterAwait,
                                      recheckProductAfterAwait: recheckProductAfterAwait,
                                      refreshReadOnlyObservation: false, allowBlockedProvider: allowBlockedProvider,
                                      allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                      maximumWait: evaluationDeadline - .now)
            case "first_user_observation_replaced":
                // Provider frameworks can replace an unchanged message while
                // its model picker is being read. The adapter only signals a
                // discard after checking both pinned hashes and the exact
                // marker on the disconnected node's replacement. Admit nothing
                // from that read; use the same one-inspect budget as an append.
                guard refreshReadOnlyObservation, ["inspect", "verifyModel", "verifyProductMode"].contains(action),
                      observed["detail"] as? String == "readonly_model_observation",
                      session.submitted, session.firstUserFingerprint != nil else {
                    recordFirstUserFailure(.replacementRefreshRejected, observed: observed)
                    throw Failure.ownershipFailure(.javaScriptFirstUser)
                }
                return try await page(session, action: "inspect", enforceModel: enforceModel,
                                      refreshChangedRoute: false, recheckModelAfterAwait: recheckModelAfterAwait, recheckProductAfterAwait: recheckProductAfterAwait,
                                      refreshReadOnlyObservation: false, allowBlockedProvider: allowBlockedProvider,
                                      allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                      maximumWait: evaluationDeadline - .now)
            case "document_changed", "conversation_changed":
                if session.usesSubmissionOwnership, observed["detail"] as? String == "submission_message" {
                    // Freeze only the original returned read after the existing
                    // callback ownership/generation/route checks, before throw.
                    // Cleanup cannot replace it and no extra page read occurs.
                    if provider == .chatgpt, ["inspect", "verifyModel", "verifyProductMode"].contains(action),
                       session.state == "running", session.submitted, session.terminalFailure == nil,
                       session.firstChatSubmissionFailure == nil, sessions[session.token] === session,
                       let diagnostic = observed["submissionDiagnostic"].flatMap({ ChatSubmissionFailureDiagnostic(adapterValue: $0) }) {
                        session.firstChatSubmissionFailure = .init(generation: generation,
                            sequence: session.sequence, diagnostic: diagnostic)
                    }
                    logSubmissionFailure(session, action: action, stage: .adapterRejected, observed: observed)
                }
                if observed["detail"] as? String == "first_user_message" {
                    recordFirstUserFailure(.adapterRejected, observed: observed)
                }
                if observed["detail"] as? String == "first_user_message",
                   let raw = observed["debugStructure"] as? String,
                   let records = Self.firstUserStructureDiagnosticRecords(raw, provider: provider) {
                    logFirstUserStructure(records, sequence: session.sequence, isFailure: true)
                }
                let allowedDetails: [String: OwnershipReason] = [
                    "owner_token": .javaScriptOwner, "user_count": .javaScriptUserCount,
                    "conversation_identity": .javaScriptConversationIdentity, "document_url": .javaScriptURL,
                    "conversation_route": .javaScriptConversationRoute, "first_user_message": .javaScriptFirstUser,
                    "submission_message": .javaScriptSubmission,
                ]
                let detail = (observed["detail"] as? String).flatMap { allowedDetails[$0] }
                throw Failure.ownershipFailure(detail ?? (error == "document_changed" ? .javaScriptDocument : .javaScriptConversation))
            case "sign_in_required": throw recordedWebsiteBlocker(.signInRequired, session: session)
            case "website_verification_required": throw recordedWebsiteBlocker(.humanVerificationRequired(provider), session: session)
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
                throw recordedWebsiteBlocker(.usageLimited(provider), session: session)
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
        // Once the first message is bound, the final model read also proves
        // Chat mode and the same owned lineage. Initial binding, pending appends
        // and replacement recovery retain their independent product recheck.
        let combinedContextRecheck = provider == .chatgpt && action == "inspect"
            && session.state == "running" && session.firstUserFingerprint != nil && !session.pendingSubmission
            && refreshReadOnlyObservation && routeContinuation.isEmpty
            && enforceModel && session.modelSelectionVerified && recheckModelAfterAwait && !deferModelVerification
        // Fresh first-request editor actions need the model read below. Its
        // final product read also rechecks Chat/temporary after that callback;
        // do this shared chain before publishing the original observation.
        let editorContextRecheck = ["insert", "sendReady"].contains(action)
            && canShareFirstChatGPTEditorContextRecheck(session)
            && enforceModel && recheckModelAfterAwait && recheckProductAfterAwait
            && refreshReadOnlyObservation && routeContinuation.isEmpty && !allowBlockedProvider && !deferModelVerification
        // A continuation's fixed submit action has already checked product,
        // editor and owned lineage before one Send. Its empty receipt grants no body,
        // answer or fresh model proof. Leave that work to the ordinary poll;
        // a second body read here can consume the remaining click deadline.
        let dispatchOnlyAcknowledgement = provider == .chatgpt && action == "submit"
            && enforceModel && deferModelVerification && session.usesSubmissionOwnership
            && session.state == "running" && session.submitted && session.pendingSubmission
            && session.modelVerificationPending && session.modelSelectionVerified && session.modelChoice != nil
            && session.temporary && session.temporaryRequested
            && session.documentGeneration == generation && currentURL == url
            && session.confirmedUsers > 0 && session.sequence == session.confirmedUsers + 1 && !session.currentSubmissionVerified
            && session.firstUserFingerprint.map { observed["firstUserFingerprint"] as? String == $0 } == true
            && session.currentSubmission.map { current in
                session.preparedSubmission.map { prepared in
                    current.sequence == session.sequence && prepared.sequence == current.sequence
                        && prepared.marker == current.marker && prepared.promptFingerprint == current.promptFingerprint
                        && prepared.outboundFingerprint == current.outboundFingerprint
                } ?? false
            } == true
            && Self.isChatGPTDispatchOnlySubmissionAcknowledgement(observed)
        if profilePreparation {
            preparationSpans["callbackValidationMs"] = Self.preparationMilliseconds(.now - callbackValidationStarted)
        }
        do {
            let started = ContinuousClock.now
            defer { if profilePreparation { preparationSpans["postProductMs"] = Self.preparationMilliseconds(.now - started) } }
            try await verifyProductModeAfterAwait(observed, session: session, action: action,
                                                 recheck: recheckProductAfterAwait && !combinedContextRecheck && !dispatchOnlyAcknowledgement && !editorContextRecheck,
                                                 refreshChangedRoute: routeRefreshAvailable,
                                                 refreshReadOnlyObservation: refreshReadOnlyObservation,
                                                 maximumWait: evaluationDeadline - .now,
                                                 allowBlockedProvider: allowBlockedProvider,
                                                 allowPendingModelTemporary: allowPendingModelTemporary,
                                                 allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification)
        }
        if editorContextRecheck {
            // Both original proofs are parsed before this existing model ->
            // final-product chain. Keep its inclusive model span here; only
            // this first-request branch skips the later duplicate helper.
            do {
                let started = ContinuousClock.now
                defer { if profilePreparation { preparationSpans["postModelMs"] = Self.preparationMilliseconds(.now - started) } }
                try await verifyModelEvidenceAfterAwait(observed, session: session, action: action,
                                                       enforceModel: enforceModel, recheck: recheckModelAfterAwait,
                                                       refreshChangedRoute: routeRefreshAvailable,
                                                       refreshReadOnlyObservation: refreshReadOnlyObservation,
                                                       combinedContextRecheck: combinedContextRecheck,
                                                       allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                                       maximumWait: evaluationDeadline - .now)
            }
        }
        let betweenChecksStarted = ContinuousClock.now
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
                    recordFirstUserFailure(observed["firstUserVerified"] as? Bool != true || observed["firstUserMarkerVerified"] as? Bool != true
                        ? .proofFlagsMissing : .fingerprintInvalid, observed: observed)
                    throw Failure.ownershipFailure(.javaScriptFirstUser)
                }
                if let pinned = session.firstUserFingerprint {
                    guard fingerprint == pinned else {
                        recordFirstUserFailure(.fingerprintMismatch, observed: observed)
                        throw Failure.ownershipFailure(.javaScriptFirstUser)
                    }
                } else {
                    guard action == "inspect", session.sequence == 1, session.pendingSubmission,
                          count(observed, "userCount") == 1,
                          session.temporary, observed["temporary"] as? Bool == true else {
                        recordFirstUserFailure(.bindingNotAuthorized, observed: observed)
                        throw Failure.ownershipFailure(.javaScriptFirstUser)
                    }
                    session.firstUserFingerprint = fingerprint
                    if !session.loggedFirstUserStructure,
                       let raw = (observed["firstUserDebugStructure"] ?? observed["debugStructure"]) as? String,
                       let records = Self.firstUserStructureDiagnosticRecords(raw, provider: provider, expectedReason: "first_bound") {
                        session.loggedFirstUserStructure = true
                        logFirstUserStructure(records, sequence: session.sequence)
                    }
                }
            }
            if session.usesSubmissionOwnership, let currentSubmission = session.currentSubmission,
               count(observed, "userCount") > 0 {
                let users = count(observed, "userCount")
                let binding: Session.SubmissionBinding?
                if users == currentSubmission.sequence { binding = currentSubmission }
                else if session.pendingSubmission, users == session.confirmedUsers { binding = session.previousSubmission }
                else { binding = nil }
                guard let binding else {
                    logSubmissionFailure(session, action: action, stage: .bindingMissing, observed: observed)
                    throw Failure.ownershipFailure(.javaScriptSubmission)
                }
                guard let raw = observed["submissionProof"] else {
                    if action == "inspect", session.pendingSubmission, users == currentSubmission.sequence {
                        throw Failure.submissionObservationPending
                    }
                    logSubmissionFailure(session, action: action, stage: .proofMissing, observed: observed)
                    throw Failure.ownershipFailure(.javaScriptSubmission)
                }
                guard observed["submissionOwnershipCapability"] as? String == Self.turnContinuationCapability,
                      Self.validSubmissionProof(raw, sequence: binding.sequence, fingerprint: binding.outboundFingerprint) else {
                    logSubmissionFailure(session, action: action, stage: .proofInvalid, observed: observed)
                    throw Failure.ownershipFailure(.javaScriptSubmission)
                }
                if binding.sequence == currentSubmission.sequence { session.currentSubmissionVerified = true }
            }
            if action == "inspect", session.pendingSubmission, count(observed, "userCount") == 0 {
                if profilePreparation {
                    preparationSpans["betweenChecksMs"] = Self.preparationMilliseconds(.now - betweenChecksStarted)
                }
                do {
                    let started = ContinuousClock.now
                    defer { if profilePreparation { preparationSpans["postModelMs"] = Self.preparationMilliseconds(.now - started) } }
                    try await verifyModelEvidenceAfterAwait(observed, session: session, action: action,
                                                           enforceModel: enforceModel, recheck: recheckModelAfterAwait,
                                                           refreshChangedRoute: routeRefreshAvailable,
                                                           refreshReadOnlyObservation: refreshReadOnlyObservation,
                                                           combinedContextRecheck: combinedContextRecheck,
                                                           allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                                           maximumWait: evaluationDeadline - .now)
                }
                if !promotion, session.conversation == nil, let conversation = provider.conversationURL(observedURL) {
                    // Preserve the initial route pin while waiting for render;
                    // a later promotion still requires the first-message proof.
                    session.conversation = conversation
                    if provider == .chatgpt, session.view.url == currentURL,
                       browser.documentGeneration(for: session.tabID) == generation { session.temporaryCookieRoutes.observe(currentURL) }
                }
                // Neither answers nor cleanup can be admitted before the
                // submitted first message has established owned lineage.
                var pending: [String: Any] = ["temporary": observed["temporary"] as? Bool ?? false,
                        "userCount": 0, "responseCount": session.baseline, "text": "", "busy": true,
                        "answerComplete": false, "ownershipPending": true,
                        "debugStructure": observed["debugStructure"] as? String ?? ""]
                if observed["modelVerificationPending"] as? Bool == true { pending["modelVerificationPending"] = true }
                else if let evidence = session.modelEvidence { pending["modelEvidence"] = evidence.dictionary }
                if let evidence = session.productModeEvidence { pending["productModeEvidence"] = evidence.dictionary }
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
        if profilePreparation {
            preparationSpans["betweenChecksMs"] = Self.preparationMilliseconds(.now - betweenChecksStarted)
        }
        if !editorContextRecheck {
            do {
                let started = ContinuousClock.now
                defer { if profilePreparation { preparationSpans["postModelMs"] = Self.preparationMilliseconds(.now - started) } }
                try await verifyModelEvidenceAfterAwait(observed, session: session, action: action,
                                                       enforceModel: enforceModel, recheck: recheckModelAfterAwait,
                                                       refreshChangedRoute: routeRefreshAvailable,
                                                       refreshReadOnlyObservation: refreshReadOnlyObservation,
                                                       combinedContextRecheck: combinedContextRecheck,
                                                       allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                                       maximumWait: evaluationDeadline - .now)
            }
        }
        let finalValidationStarted = ContinuousClock.now
        defer { if profilePreparation { preparationSpans["finalValidationMs"] = Self.preparationMilliseconds(.now - finalValidationStarted) } }
        if session.usesSubmissionOwnership, ["insert", "sendReady", "submit"].contains(action) {
            guard observed["submissionOwnershipCapability"] as? String == Self.turnContinuationCapability else {
                logSubmissionFailure(session, action: action, stage: .capabilityMissing, observed: observed)
                throw Failure.ownershipFailure(.javaScriptSubmission)
            }
        }
        guard ContinuousClock.now < evaluationDeadline else { throw Failure.pageUnavailable }
        if provider == .chatgpt, action == "submit" {
            logResourceTimingDiagnostic(observed["resourceTimingDiagnostic"], session: session, phase: "send")
        }
        if provider == .chatgpt, session.submitted, session.temporary,
           browser.webView(for: session.tabID) === session.view, session.view.url == currentURL,
           browser.documentGeneration(for: session.tabID) == generation {
            session.temporaryCookieRoutes.observe(currentURL)
            if let generation = session.documentGeneration, let fingerprint = session.firstUserFingerprint,
               session.confirmedUsers > 0, session.currentSubmissionVerified,
               observed["temporary"] as? Bool == true, observed["ownershipPending"] as? Bool != true {
                browser.recordOwnedTemporaryChatGPTRoutes(session.temporaryCookieRoutes.candidates,
                    tabID: session.tabID, view: session.view, ownerToken: session.token,
                    generation: generation, firstUserFingerprint: fingerprint)
            }
        }
        return observed
    }

    /// Recognize only the shipped adapter's empty dispatch receipt. This does
    /// not validate product evidence or authorize a response; page() still
    /// parses product proof and applies every native post-await fence. Unknown
    /// future fields fall back to the complete recheck until reviewed here.
    static func isChatGPTDispatchOnlySubmissionAcknowledgement(_ observed: [String: Any]) -> Bool {
        let required: Set<String> = ["submitted", "submissionPending", "modelVerificationPending", "temporary",
            "chatModeReady", "chatModeActionAvailable", "productModeEvidence", "submissionOwnershipCapability",
            "text", "answerComplete", "firstUserVerified", "firstUserFingerprint", "firstUserMarkerVerified"]
        let optional: Set<String> = ["resourceTimingDiagnostic"]
        guard required.isSubset(of: Set(observed.keys)), Set(observed.keys).isSubset(of: required.union(optional)),
              observed["submissionOwnershipCapability"] as? String == turnContinuationCapability,
              observed["text"] as? String == "", observed["productModeEvidence"] is [String: Any] else { return false }
        func boolean(_ key: String, _ expected: Bool) -> Bool {
            guard let number = observed[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue == expected
        }
        guard ["submitted", "submissionPending", "modelVerificationPending", "temporary", "chatModeReady",
               "firstUserVerified", "firstUserMarkerVerified"]
                .allSatisfy({ boolean($0, true) }),
              boolean("answerComplete", false), boolean("chatModeActionAvailable", false),
              let fingerprint = observed["firstUserFingerprint"] as? String, fingerprint.utf8.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
        return true
    }

    private func verifyProductModeAfterAwait(_ observed: [String: Any], session: Session, action: String,
                                            recheck: Bool, refreshChangedRoute: Bool,
                                            refreshReadOnlyObservation: Bool, maximumWait: Duration,
                                            allowBlockedProvider: Bool, allowPendingModelTemporary: Bool,
                                            allowPendingChatGPTModelVerification: Bool) async throws {
        guard session.provider == .chatgpt else { return }
        // Before hydration or the explicitly claimed Chat click, an untouched
        // root can report pending readiness. That never authorizes temporary
        // mode, model discovery, insertion or Send.
        let initialPending = session.state == "loading" && !session.temporaryRequested && !session.submitted
            && session.productModeEvidence == nil && ["inspect", "ensureChatMode"].contains(action)
        if observed["productModeEvidence"] == nil, initialPending {
            guard observed["chatModeReady"] as? Bool != true else { throw Failure.productModeUnverified }
            return
        }
        // The owned picker can hide the already verified temporary control.
        // Permit only its claimed pending phase to finish closing; readiness
        // and every editor/Send/response admission still require physical mode.
        let pendingPicker = session.temporary && session.modelSelectionRequested
            && session.productModeEvidence?.temporaryTransition == .acknowledged
            && (allowPendingModelTemporary
                || ["selectModel", "discoverModels"].contains(action) && observed["pending"] as? Bool == true
                || session.state == "loading" && !session.modelSelectionVerified && ["inspect", "verifyProductMode"].contains(action))
        let evidence: WebsiteProductModeEvidence
        do { evidence = try WebsiteProductModeEvidence.parse(observed["productModeEvidence"],
                    requireTemporary: session.temporary || observed["temporary"] as? Bool == true) }
        catch { throw Failure.productModeUnverified }
        if evidence.temporaryTransition == .acknowledged {
            guard session.temporaryRequested, observed["temporary"] as? Bool == true || pendingPicker else { throw Failure.productModeUnverified }
        }
        if session.productModeEvidence?.temporaryTransition == .acknowledged,
           evidence.temporaryTransition != .acknowledged { throw Failure.productModeUnverified }
        session.productModeEvidence = evidence
        // Native awaits can cross a Work-mode change without a navigation.
        // Re-read only the fixed product controls; never replay a click or Send.
        if recheck, !["verifyProductMode", "ensureChatMode", "stop", "cleanup"].contains(action) {
            let freshAction = session.pendingSubmission && session.firstUserFingerprint == nil ? "inspect" : "verifyProductMode"
            let fresh = try await page(session, action: freshAction, enforceModel: false,
                                       refreshChangedRoute: refreshChangedRoute,
                                       recheckModelAfterAwait: false, recheckProductAfterAwait: false,
                                       refreshReadOnlyObservation: refreshReadOnlyObservation,
                                       allowBlockedProvider: allowBlockedProvider, allowPendingModelTemporary: pendingPicker,
                                       allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                       maximumWait: maximumWait)
            let current: WebsiteProductModeEvidence
            do { current = try WebsiteProductModeEvidence.parse(fresh["productModeEvidence"],
                    requireTemporary: session.temporary || fresh["temporary"] as? Bool == true) }
            catch { throw Failure.productModeUnverified }
            guard evidence.temporaryTransition != .acknowledged || current.temporaryTransition == .acknowledged else {
                throw Failure.productModeUnverified
            }
            session.productModeEvidence = current
        }
    }

    private func verifyModelEvidenceAfterAwait(_ observed: [String: Any], session: Session, action: String,
                                              enforceModel: Bool, recheck: Bool, refreshChangedRoute: Bool,
                                              refreshReadOnlyObservation: Bool,
                                              combinedContextRecheck: Bool,
                                              allowPendingChatGPTModelVerification: Bool,
                                              maximumWait: Duration) async throws {
        if observed["modelVerificationPending"] != nil {
            guard observed["modelVerificationPending"] as? Bool == true,
                  allowPendingChatGPTModelVerification, session.provider == .chatgpt,
                  session.state == "running", session.submitted, session.modelVerificationPending,
                  ["inspect", "submit", "verifyModel", "verifyProductMode"].contains(action),
                  observed["modelEvidence"] == nil else { throw Failure.modelUnverified }
            // These are negative continuity checks, not fresh selection evidence.
            if action == "inspect", !session.loggedPendingModelVerification {
                session.loggedPendingModelVerification = true
                Self.inspectionLog.info("modelVerification provider=chatgpt sequence=\(session.sequence) phase=pending_read")
            }
            return
        }
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
                                           recheckProductAfterAwait: !combinedContextRecheck,
                                           refreshReadOnlyObservation: refreshReadOnlyObservation,
                                           allowPendingChatGPTModelVerification: allowPendingChatGPTModelVerification,
                                           maximumWait: maximumWait)
                let currentEvidence = try validatedModelEvidence(fresh, session: session)
                guard evidence.isSameResolvedSelection(as: currentEvidence) else { throw Failure.modelMismatch }
            }
            session.modelEvidence = evidence
        }
    }

    private func validatedModelEvidence(_ observation: [String: Any], session: Session) throws -> WebsiteModelEvidence {
        let current: WebsiteModelEvidence
        do { current = try WebsiteModelEvidence.parse(observation["modelEvidence"], provider: session.provider.rawValue, expected: session.modelChoice) }
        catch WebsiteModelEvidence.Failure.mismatch { throw Failure.modelMismatch }
        catch { throw Failure.modelUnverified }
        guard session.modelEvidence.map({ $0.isSameResolvedSelection(as: current) }) ?? true else { throw Failure.modelMismatch }
        return current
    }

    static func sanitizedProductModeDiagnostic(_ raw: Any?) -> String? {
        let required: Set<String> = ["kind", "groupCount", "groupVisible", "recognized", "contradictory", "chat", "work",
                                     "proofPresent", "proofInvalidated", "chatClickClaimed"]
        let optional: Set<String> = ["productProofFailure", "productMutationRelevantCount", "productMutationIgnoredCount"]
        guard let value = raw as? [String: Any],
              required.isSubset(of: Set(value.keys)), Set(value.keys).isSubset(of: required.union(optional)),
              value["kind"] as? String == "chatgpt_product_mode_structure",
              let count = value["groupCount"] as? NSNumber,
              CFGetTypeID(count) != CFBooleanGetTypeID(), (0...16).contains(count.intValue),
              count.doubleValue == Double(count.intValue) else { return nil }
        func boolean(_ raw: Any?) -> Bool? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        var safe: [String: Any] = ["kind": "chatgpt_product_mode_structure", "groupCount": count.intValue]
        for key in ["groupVisible", "recognized", "contradictory", "proofPresent", "proofInvalidated", "chatClickClaimed"] {
            guard let flag = boolean(value[key]) else { return nil }; safe[key] = flag
        }
        if let rawFailure = value["productProofFailure"] {
            guard let failure = rawFailure as? String, productProofFailures.contains(failure) else { return nil }
            safe["productProofFailure"] = failure
        }
        for key in productMutationCounts {
            if let rawCount = value[key] {
                guard let count = ComputerToolArgumentContract.exactInt64(rawCount), (0...1_000).contains(count) else { return nil }
                safe[key] = count
            }
        }
        for key in ["chat", "work"] {
            if value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let control = value[key] as? [String: Any],
                  Set(control.keys) == ["tag", "role", "pressed", "checked", "visible", "enabled"],
                  let tag = control["tag"] as? String, ["button", "other"].contains(tag),
                  let visible = boolean(control["visible"]), let enabled = boolean(control["enabled"]) else { return nil }
            var item: [String: Any] = ["tag": tag, "visible": visible, "enabled": enabled]
            for field in ["role", "pressed", "checked"] {
                if control[field] is NSNull { item[field] = NSNull(); continue }
                let allowed = field == "role" ? ["button", "radio", "switch", "checkbox"] : ["true", "false", "mixed"]
                guard let state = control[field] as? String, allowed.contains(state) else { return nil }; item[field] = state
            }
            safe[key] = item
        }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]), data.count <= 2_048 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func logModelDiagnostic(_ observation: [String: Any], session: Session) {
        guard let value = observation["modelDiagnostic"], JSONSerialization.isValidJSONObject(value),
              let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), bytes.count <= 16_384 else { return }
        let line = String(decoding: bytes, as: UTF8.self)
        guard line != session.lastModelDiagnostic else { return }
        session.lastModelDiagnostic = line
        #if DEBUG
        modelDiagnosticsObserverForTesting?(line)
        #endif
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

    func interruptPostBlockObservation(sessionToken: String) async {
        sessions[sessionToken]?.postBlockDiagnostic?.task?.cancel()
    }

    private func finish(_ session: Session, cancel: Bool,
                        cleanupCause: WebModelCleanupCause = .cancelled) async -> Data {
        guard session.provider == .chatgpt else { return await performFinish(session, cancel: cancel, cleanupCause: cleanupCause) }
        if let task = finishingTasks[session.token] { return await task.value }
        if let closed = closedSessions[session.token] { return closed.receipt }
        let work = Task { @MainActor in await self.performFinish(session, cancel: cancel, cleanupCause: cleanupCause) }
        finishingTasks[session.token] = work
        let result = await work.value
        finishingTasks.removeValue(forKey: session.token)
        if session.state == "finished" {
            while closedSessions.count >= 16 || closedSessions.values.reduce(0, { $0 + $1.receipt.count }) + result.count > 16 * 1_024 * 1_024 {
                guard let oldest = closedSessions.min(by: { $0.value.created < $1.value.created })?.key else { break }
                closedSessions.removeValue(forKey: oldest)
            }
            closedSessions[session.token] = (.now, result)
        }
        return result
    }

    private func performFinish(_ session: Session, cancel: Bool,
                               cleanupCause: WebModelCleanupCause) async -> Data {
        finishInitialCheckpointSettlement(session, phase: cancel ? .cancelled : .finished)
        browser.revokeModelInspectorDiagnostic(tabID: session.tabID, ownerToken: session.token)
        if let capture = session.postBlockDiagnostic, let task = capture.task {
            if cancel && cleanupCause != .failedTurn || Task.isCancelled { task.cancel() }
            let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            if capture.physicallyClosed, sessions[session.token] === session { sessions.removeValue(forKey: session.token) }
            return result
        }
        // The outer server can reach its deadline before another native poll
        // is scheduled. Observe only an already-expired running response;
        // successful, preparing and early-cancelled sessions are untouched.
        if session.state == "running", ContinuousClock.now - session.turnStarted >= responseTimeout {
            logResponseProgressFailure(session, cause: "response_deadline")
            await logFailedPageDiagnostic(session)
        } else if cancel {
            logResponseProgressFailure(session, cause: "cancelled")
        }
        do {
            guard browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
            if !session.isDiscovery {
                // A checkpoint may first arrive after the last poll or before
                // mode setup. Record it even when cleanup cannot own the page.
                do { try rejectWebsiteBlocker(session, action: "cleanup", phase: "before") }
                catch {
                    let googleCheckpoint = (error as? Failure) == .humanVerificationRequired(.gemini)
                        && canDisposeUntouchedGoogleCheckpoint(session)
                    let chatGPTSignIn = (error as? Failure) == .signInRequired && canDisposeUntouchedChatGPTSignIn(session)
                    guard googleCheckpoint || chatGPTSignIn else { throw error }
                    // No provider adapter could have focused an editor or sent
                    // anything. Keep the provider gate, but retire this exact
                    // app-created view without evaluating the checkpoint.
                    browser.closeTab(session.tabID)
                    session.responseProfile?.mark(.physicalClose)
                    guard browser.webView(for: session.tabID) == nil,
                          !browser.tabs.contains(where: { $0.id == session.tabID }), session.view.superview == nil else {
                        throw Failure.staleSession
                    }
                    sessions.removeValue(forKey: session.token)
                    session.state = "finished"
                    if session.provider == .chatgpt {
                        session.responseProfile?.mark(.cookieSettleStart)
                        _ = await browser.settleChatGPTTemporaryCookieRetirement(until: .now + .seconds(2))
                        session.responseProfile?.mark(.cookieSettleEnd)
                    }
                    return try snapshot(session, cleanup: "not_created")
                }
            }
            if session.isDiscovery {
                // Discovery cannot Send and its private view cannot be adopted
                // by a human tab. Close exactly this read-only view even after
                // a sign-in redirect; inference cleanup authority is unchanged.
                guard !session.submitted, browser.webView(for: session.tabID) === session.view else { throw Failure.staleSession }
            } else if session.submitted || session.temporaryRequested || session.temporary {
                let observed: [String: Any]
                session.responseProfile?.mark(.cleanupOwnershipInspectStart)
                do {
                    defer { session.responseProfile?.mark(.cleanupOwnershipInspectEnd) }
                    observed = try await page(session, action: "inspect", enforceModel: false, allowBlockedProvider: true)
                }
                catch {
                    guard let failure = error as? Failure, case .usageLimited(let provider) = failure,
                          provider == session.provider, session.submitted, session.firstUserFingerprint != nil else { throw error }
                    // Only the fixed adapter's exact quota modal can expose
                    // physical temporary indicators for cleanup. The ordinary
                    // first-message and session proofs remain mandatory.
                    observed = try await page(session, action: "stop", allowBlockedProvider: true)
                    guard observed["usageLimited"] as? Bool == true, observed["busy"] as? Bool == false else {
                        throw Failure.temporaryUnverified
                    }
                }
                guard observed["ownershipPending"] as? Bool != true else {
                    throw Failure.ownershipFailure(.promotionFirstUser)
                }
                if session.submitted {
                    guard session.temporary, observed["temporary"] as? Bool == true else { throw Failure.temporaryUnverified }
                    if cancel, observed["busy"] as? Bool == true { _ = try await page(session, action: "stop", allowBlockedProvider: true) }
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
            session.responseProfile?.mark(.physicalClose)
            sessions.removeValue(forKey: session.token)
            session.state = "finished"
            if session.provider == .chatgpt {
                // Physical website closure is already verified. Local cookie
                // maintenance has its own durable state and cannot reopen or
                // invalidate that receipt when a callback remains pending.
                session.responseProfile?.mark(.cookieSettleStart)
                _ = await browser.settleChatGPTTemporaryCookieRetirement(until: .now + .seconds(2))
                session.responseProfile?.mark(.cookieSettleEnd)
            }
            return try snapshot(session, cleanup: "not_created")
        } catch {
            // Retain the exact owned tab for inspection/retry; never erase a human chat.
            return (try? snapshot(session, cleanup: "failed")) ?? Data("{}".utf8)
        }
    }

    private func snapshot(_ session: Session, cleanup: String? = nil) throws -> Data {
        let pendingModel = session.provider == .chatgpt && session.state == "running" && session.modelVerificationPending
        var value: [String: Any] = ["sessionToken": session.token, "provider": session.provider.rawValue,
                                  "state": session.state, "text": pendingModel ? "" : session.response, "sequence": session.sequence]
        if pendingModel { value["modelVerificationPending"] = true }
        if !pendingModel, let evidence = session.modelEvidence { value["modelEvidence"] = evidence.dictionary }
        if let evidence = session.productModeEvidence { value["productModeEvidence"] = evidence.dictionary }
        if session.usesSubmissionOwnership {
            value["turnContinuationCapability"] = Self.turnContinuationCapability
        }
        if session.state == "complete", let structure = session.responseCodeStructure {
            value["completionEvidence"] = ["codeStructure": structure]
        }
        if let generation = session.documentGeneration {
            let contextKey = pendingModel ? "pendingSubmissionContext" : "modelProofContext"
            value[contextKey] = ["documentGeneration": generation.uuidString, "sequence": session.sequence,
                                            "firstUserFingerprint": session.firstUserFingerprint ?? "",
                                            "responseCount": session.observedResponseCount,
                                            "baselineResponseCount": session.baseline]
            if session.usesSubmissionOwnership,
               var context = value[contextKey] as? [String: Any] {
                context["submittedPromptFingerprint"] = session.currentSubmissionVerified
                    ? session.currentSubmission?.promptFingerprint ?? "" : ""
                value[contextKey] = context
            }
        }
        if let cleanup { value["cleanup"] = cleanup }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func count(_ observation: [String: Any], _ key: String) -> Int { observation[key] as? Int ?? 0 }

    static let turnContinuationCapability = "per_submission_ownership_v1"
    static let maximumTurnSubmissions = 16
    static let maximumTurnUTF8Bytes = 1_048_576

    nonisolated static func promptFingerprint(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Match the adapter's existing CRLF/NFC/ECMAScript trim policy exactly.
    /// This hash is proof of the full outbound body, including its private marker.
    nonisolated static func outboundFingerprint(_ outbound: String) -> String {
        let spaces = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        let canonical = outbound.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping.trimmingCharacters(in: spaces)
        return promptFingerprint(canonical)
    }

    static func validSubmissionProof(_ raw: Any, sequence: Int, fingerprint: String) -> Bool {
        guard (1...10_000).contains(sequence), fingerprint.utf8.count == 64,
              let value = raw as? [String: Any], Set(value.keys) == ["sequence", "fingerprint"],
              let observedSequence = ComputerToolArgumentContract.exactInt64(value["sequence"]),
              observedSequence == Int64(sequence), let observed = value["fingerprint"] as? String,
              observed.utf8.count == 64, observed.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              observed == fingerprint else { return false }
        return true
    }

    /// Diagnostic-only projection. Never publish message text, markers, hashes,
    /// page identities, URLs or an arbitrary JavaScript value on rejection.
    static func sanitizedSubmissionDiagnostic(_ raw: Any?) -> String? {
        let flags = ["statePresent", "recordPresent", "stateRevoked", "ownerMatches", "documentMatches",
                     "nonceMatches", "canonicalMatches", "suffixMatches", "contextMatches"]
        let keys = Set(flags + ["kind", "stage", "action", "phase", "requestedSequence", "recordSequence", "userCount"])
        guard let value = raw as? [String: Any], Set(value.keys) == keys,
              value["kind"] as? String == "gemini_submission_v1",
              let stage = value["stage"] as? String,
              ["invalid_input", "begin_initial", "begin_admission", "begin_digest", "claim_admission",
               "observe_state", "observe_record", "observe_parent", "observe_pending", "observe_count",
               "observe_body", "observe_text", "observe_digest", "observe_final"].contains(stage),
              let action = value["action"] as? String,
              ["inspect", "prepare", "insert", "sendReady", "submit", "verifyModel", "stop", "discoverModels",
               "selectModel", "modelDiagnostic", "enableTemporary", "unknown"].contains(action),
              let phase = value["phase"] as? String,
              ["none", "insert_claimed", "inserted", "send_claimed", "verified", "unknown"].contains(phase),
              let users = ComputerToolArgumentContract.exactInt64(value["userCount"]), (0...10_000).contains(users) else { return nil }
        var safe: [String: Any] = ["kind": "gemini_submission_v1", "stage": stage, "action": action, "phase": phase, "userCount": users]
        for key in ["requestedSequence", "recordSequence"] {
            if value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let number = ComputerToolArgumentContract.exactInt64(value[key]), (0...10_000).contains(number) else { return nil }
            safe[key] = number
        }
        for key in flags {
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }
            safe[key] = flag
        }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), data.count <= 2_048 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func sanitizedChatSubmissionDiagnostic(_ raw: Any?) -> String? {
        let flags = ["contextMatches", "nativePinMatches", "pendingRecord", "lastVerifiedRecord", "rootSame", "bodySame",
                     "oldRootConnected", "oldBodyConnected", "currentRootConnected", "currentBodyConnected", "canonicalMatches", "oldRootPresent", "oldBodyPresent"]
        let keys = Set(flags + ["kind", "action", "stage", "requestedSequence", "recordSequence", "userCount", "recordPhase", "contextChecks"])
        guard let value = raw as? [String: Any], Set(value.keys) == keys,
              value["kind"] as? String == "chatgpt_submission_v1",
              let action = value["action"] as? String,
              ["inspect", "prepare", "insert", "sendReady", "submit", "verifyModel", "verifyProductMode", "ensureChatMode",
               "stop", "discoverModels", "selectModel", "modelDiagnostic", "enableTemporary", "cleanup", "unknown"].contains(action),
              let stage = value["stage"] as? String,
              ["missing_state", "begin_invocation", "begin_input", "begin_text", "begin_initial", "begin_admission", "begin_digest",
               "claim_admission", "observe_context", "observe_ordinal", "observe_record", "observe_count", "observe_body",
               "observe_expansion", "observe_text", "observe_parent", "observe_digest"].contains(stage),
              let users = ComputerToolArgumentContract.exactInt64(value["userCount"]), (0...17).contains(users) else { return nil }
        var safe: [String: Any] = ["kind": "chatgpt_submission_v1", "action": action, "stage": stage, "userCount": users]
        for key in ["requestedSequence", "recordSequence"] {
            if value[key] is NSNull { safe[key] = NSNull(); continue }
            guard let number = ComputerToolArgumentContract.exactInt64(value[key]), (0...16).contains(number) else { return nil }
            safe[key] = number
        }
        for key in flags {
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }; safe[key] = flag
        }
        guard let phase = value["recordPhase"] as? String,
              ["none", "prepared", "send_claimed", "verified", "unknown"].contains(phase) else { return nil }
        safe["recordPhase"] = phase
        let checkKeys = ["invocationClaimed", "invocationCurrent", "statePresent", "stateNotRevoked", "stateDocumentMatches",
                         "stateOwnerMatches", "stateCurrent", "globalOwnerMatches", "topFrame", "providerMatches",
                         "originMatches", "urlMatches", "firstMarkerMatches", "productProofVerified", "temporaryVerified", "modelChoiceMatches"]
        if value["contextChecks"] is NSNull {
            safe["contextChecks"] = NSNull()
        } else {
            guard let checks = value["contextChecks"] as? [String: Any], Set(checks.keys) == Set(checkKeys) else { return nil }
            var checked: [String: Any] = [:], stopped = false
            for key in checkKeys {
                if stopped {
                    guard checks[key] is NSNull else { return nil }; checked[key] = NSNull()
                } else {
                    guard let flag = firstUserDiagnosticBool(checks[key]) else { return nil }
                    checked[key] = flag
                    if !flag { stopped = true }
                }
            }
            guard stopped else { return nil }
            safe["contextChecks"] = checked
        }
        // This enlarged diagnostic-only bound accommodates sixteen nullable
        // checks; submission/body/request/journal limits are unchanged.
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), data.count <= 2_048 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func sanitizedSubmissionNodeDiagnostic(_ raw: Any?) -> String? {
        let flags = ["rootSame", "bodySame", "oldRootConnected", "oldBodyConnected", "currentRootConnected",
                     "currentBodyConnected", "remountCertificatePresent", "projectedCanonicalMatches"]
        guard let value = raw as? [String: Any], Set(value.keys) == Set(flags + ["kind", "cause"]),
              value["kind"] as? String == "gemini_submission_nodes_v1",
              let cause = value["cause"] as? String,
              ["body_missing", "payload_type", "payload_limit", "physical_replaced"].contains(cause) else { return nil }
        var safe: [String: Any] = ["kind": "gemini_submission_nodes_v1", "cause": cause]
        for key in flags {
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }; safe[key] = flag
        }
        if cause == "body_missing" {
            guard safe["currentBodyConnected"] as? Bool == false, safe["projectedCanonicalMatches"] as? Bool == false else { return nil }
        }
        if cause == "physical_replaced" {
            guard safe["rootSame"] as? Bool != true || safe["bodySame"] as? Bool != true else { return nil }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), data.count <= 960 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func sanitizedSubmissionDigestDiagnostic(_ raw: Any?) -> String? {
        let flags = ["stateSame", "stateRevoked", "recordRetained", "parentRequired", "parentIntact",
                     "remountRequired", "remountIntact", "contextMatches", "rootCountMatches", "rootsSame",
                     "firstRootSame", "currentRootSame", "rootConnected", "bodyConnected", "bodySame",
                     "payloadAvailable", "payloadWithinLimit", "bodyTextUnchanged", "bodyCanonicalMatches",
                     "priorIntact", "digestMatches"]
        guard let value = raw as? [String: Any], Set(value.keys) == Set(flags + ["kind", "projectedLength"]),
              value["kind"] as? String == "gemini_submission_digest_v1",
              let length = ComputerToolArgumentContract.exactInt64(value["projectedLength"]),
              (0...180_201).contains(length) else { return nil }
        var safe: [String: Any] = ["kind": "gemini_submission_digest_v1", "projectedLength": length]
        for key in flags {
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }; safe[key] = flag
        }
        let available = safe["payloadAvailable"] as? Bool == true
        let withinLimit = safe["payloadWithinLimit"] as? Bool == true
        guard available || length == 0,
              withinLimit == (available && length <= 180_200),
              withinLimit || (safe["bodyTextUnchanged"] as? Bool == false && safe["bodyCanonicalMatches"] as? Bool == false),
              safe["parentRequired"] as? Bool == true || safe["parentIntact"] as? Bool == true,
              safe["remountRequired"] as? Bool == true || safe["remountIntact"] as? Bool == true,
              let data = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), data.count <= 960 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first refusal survives a discarded outer read, but supplies no proof.
    /// Each record remains below the existing unified logging message budget.
    static func submissionFirstFailureDiagnosticRecords(_ raw: Any?, current: Any?) -> [String]? {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["firstFailureKind", "stage", "action", "sequence", "digestDiagnostic"],
              value["firstFailureKind"] as? String == "gemini_submission_first_failure_v1",
              let stage = value["stage"] as? String,
              ["begin_digest", "claim_admission", "observe_record", "observe_parent", "observe_pending",
               "observe_count", "observe_body", "observe_text", "observe_digest", "observe_final"].contains(stage),
              let action = value["action"] as? String,
              ["inspect", "prepare", "insert", "sendReady", "submit", "verifyModel", "stop", "discoverModels",
               "selectModel", "modelDiagnostic", "enableTemporary"].contains(action),
              let sequence = ComputerToolArgumentContract.exactInt64(value["sequence"]), (1...10_000).contains(sequence),
              sanitizedSubmissionDiagnostic(current) != nil, let current = current as? [String: Any],
              ComputerToolArgumentContract.exactInt64(current["requestedSequence"]) == sequence,
              ComputerToolArgumentContract.exactInt64(current["recordSequence"]) == sequence else { return nil }
        let header: [String: Any] = ["firstFailureKind": "gemini_submission_first_failure_v1",
                                     "stage": stage, "action": action, "sequence": sequence]
        var records = [header]
        if !(value["digestDiagnostic"] is NSNull) {
            guard stage == "observe_digest", let safe = sanitizedSubmissionDigestDiagnostic(value["digestDiagnostic"]),
                  var digest = try? JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any] else { return nil }
            digest.merge(header) { _, retained in retained }
            records.append(digest)
        }
        var encoded: [String] = []
        for record in records {
            guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys),
                  bytes.count <= 960 else { return nil }
            encoded.append(String(decoding: bytes, as: UTF8.self))
        }
        return encoded
    }

    static func sanitizedSubmissionBodyDiagnostic(_ raw: Any?) -> String? {
        let measurements = ["expectedLength", "innerTextLength", "textContentLength", "expectedLines", "innerTextLines",
                            "textContentLines", "firstMismatchIndex", "literalDOMLength", "innerTextExpectedOffset", "textContentExpectedOffset"]
        let counts = ["nodeCount", "paragraphCount", "brCount", "textNodeCount", "spanCount", "bodyChildElements"]
        let flags = ["innerTextMatches", "textContentMatches", "literalDOMAvailable", "literalDOMMatches",
                     "innerTextContainsExpected", "textContentContainsExpected"]
        let keys = Set(measurements + counts + flags + ["kind", "maximumDepth", "actualCategory", "expectedCategory", "literalDOMUnavailableReason"])
        guard let value = raw as? [String: Any], Set(value.keys) == keys,
              value["kind"] as? String == "gemini_submission_body_v1",
              let reason = value["literalDOMUnavailableReason"] as? String,
              ["none", "missing_body", "hidden", "inert", "control", "unsupported_markup", "length_budget", "node_budget", "depth_budget", "read_failure"].contains(reason)
        else { return nil }
        var safe: [String: Any] = ["kind": "gemini_submission_body_v1", "literalDOMUnavailableReason": reason]
        for key in ["actualCategory", "expectedCategory"] {
            guard let category = value[key] as? String,
                  ["linefeed", "carriage_return", "space", "quote", "bracket", "brace", "backslash", "other", "end"].contains(category) else { return nil }
            safe[key] = category
        }
        for (fields, maximum) in [(measurements, 180_201), (counts, 8_193), (["maximumDepth"], 65)] {
            for key in fields {
                guard let number = ComputerToolArgumentContract.exactInt64(value[key]), (0...Int64(maximum)).contains(number) else { return nil }
                safe[key] = number
            }
        }
        for key in flags {
            guard let flag = firstUserDiagnosticBool(value[key]) else { return nil }; safe[key] = flag
        }
        for prefix in ["innerText", "textContent"] {
            let contains = safe[prefix + "ContainsExpected"] as? Bool == true
            let matches = safe[prefix + "Matches"] as? Bool == true
            let offset = safe[prefix + "ExpectedOffset"] as? Int64
            guard contains == (offset != 180_201), !matches || contains && offset == 0 else { return nil }
        }
        guard !(safe["literalDOMAvailable"] as? Bool == false && safe["literalDOMMatches"] as? Bool == true),
              (safe["literalDOMAvailable"] as? Bool == true) == (reason == "none"),
              let data = try? JSONSerialization.data(withJSONObject: safe, options: .sortedKeys), data.count <= 2_048 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func logSubmissionFailure(_ session: Session, action: String, stage: SubmissionNativeStage, observed: [String: Any]) {
        guard session.usesSubmissionOwnership else { return }
        // Native Send is claimed before the click. These fields deliberately
        // distinguish that intent from a verified physical website submission.
        var context: [String: Any] = ["kind": "submission_native_v1", "action": action, "stage": stage.rawValue,
            "sequence": session.sequence, "confirmedUsers": session.confirmedUsers,
            "preparedSequence": session.preparedSubmission?.sequence ?? 0,
            "currentSequence": session.currentSubmission?.sequence ?? 0,
            "sendClaimed": session.submitted, "pending": session.pendingSubmission,
            "currentBodyVerified": session.currentSubmissionVerified,
            "capabilityMatches": observed["submissionOwnershipCapability"] as? String == Self.turnContinuationCapability,
            "proofPresent": observed["submissionProof"] != nil]
        if session.provider == .chatgpt { context["provider"] = "chatgpt" }
        if let data = try? JSONSerialization.data(withJSONObject: context, options: .sortedKeys), data.count <= 1_024 {
            let encoded = String(decoding: data, as: UTF8.self)
            Self.inspectionLog.error("submissionNative \(encoded, privacy: .public)")
            #if DEBUG
            submissionDiagnosticsObserverForTesting?("submissionNative", encoded)
            #endif
        }
        if session.provider == .chatgpt {
            if let safe = Self.sanitizedChatSubmissionDiagnostic(observed["submissionDiagnostic"]) {
                Self.inspectionLog.error("submissionChatAdapter \(safe, privacy: .public)")
                #if DEBUG
                submissionDiagnosticsObserverForTesting?("submissionChatAdapter", safe)
                #endif
            }
            return
        }
        // The existing Gemini-only sidecars retain their schema and scope.
        if let safe = Self.sanitizedSubmissionDiagnostic(observed["submissionDiagnostic"]) {
            Self.inspectionLog.error("submissionAdapter \(safe, privacy: .public)")
            if let records = Self.submissionFirstFailureDiagnosticRecords(observed["submissionFirstFailure"],
                                                                          current: observed["submissionDiagnostic"]) {
                for record in records { Self.inspectionLog.error("submissionFirstFailure \(record, privacy: .public)") }
            }
            if (observed["submissionDiagnostic"] as? [String: Any])?["stage"] as? String == "observe_body",
               let nodes = Self.sanitizedSubmissionNodeDiagnostic(observed["submissionNodesDiagnostic"]) {
                Self.inspectionLog.error("submissionNodes \(nodes, privacy: .public)")
            }
            if (observed["submissionDiagnostic"] as? [String: Any])?["stage"] as? String == "observe_digest",
               let digest = Self.sanitizedSubmissionDigestDiagnostic(observed["submissionDigestDiagnostic"]) {
                Self.inspectionLog.error("submissionDigest \(digest, privacy: .public)")
            }
        }
        if let raw = observed["debugSubmissionStructure"] as? String,
           let records = Self.firstUserStructureDiagnosticRecords(raw, provider: .gemini, expectedReason: "submission_text") {
            logFirstUserStructure(records, sequence: session.sequence, isFailure: true)
        }
        if let safe = Self.sanitizedSubmissionBodyDiagnostic(observed["submissionBodyDiagnostic"]) {
            let data = Data(safe.utf8), id = UUID().uuidString
            let chunks = stride(from: 0, to: data.count, by: 512).map { offset in
                data.subdata(in: offset..<min(offset + 512, data.count)).base64EncodedString()
            }
            for (index, chunk) in chunks.enumerated() {
                Self.inspectionLog.error("submissionBody id=\(id, privacy: .public) part=\(index + 1)/\(chunks.count) base64=\(chunk, privacy: .public)")
            }
        }
    }

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

/// Post-Send diagnostic events only. Native and server epochs are distinct:
/// nativeTurn starts at the existing turnStarted; serverAcknowledged starts
/// after Send's existing callback. Join only exact session/sequence IDs, plus
/// the server's native inference ID and OSLog time. No event grants authority.
/// Elapsed marks share an epoch and are not additive phase durations. End
/// events also record a throwing scope's exit; they do not assert success.
struct WebsiteResponseProfile: Sendable {
    @TaskLocal static var cleanup: WebsiteResponseProfile?
    enum Source: String, Sendable, Codable, CaseIterable { case nativeTurn, serverAcknowledged }
    enum Phase: String, Sendable, Codable, CaseIterable {
        case firstPositive, firstCompletionCandidate, quietDeadlineReady
        case completionCandidateArmed, completionCandidateLost, candidateResponseChanged, quietWaitStarted, quietWaitFinished
        case finalFullInspectStart, finalFullInspectEnd, transportComplete
        case cleanupOwnershipInspectStart, cleanupOwnershipInspectEnd, physicalClose, cookieSettleStart, cookieSettleEnd
        case serverSendAcknowledged, codecStart, codecEnd
        case submissionEvidenceStart, submissionEvidenceEnd, completionEvidenceStart, completionEvidenceEnd
        case encodeStart, encoded, cleanupReceiptDone, inferenceReturnReady, httpWriteStart, httpWriteEnd
        case cleanupPersistStart, cleanupPersistEnd, cleanupReleaseStart, cleanupReleaseEnd, cleanupObserverStart, cleanupObserverEnd

        var source: Source {
            switch self {
            case .firstPositive, .firstCompletionCandidate, .quietDeadlineReady, .finalFullInspectStart, .finalFullInspectEnd,
                 .completionCandidateArmed, .completionCandidateLost, .candidateResponseChanged, .quietWaitStarted, .quietWaitFinished,
                 .transportComplete, .cleanupOwnershipInspectStart, .cleanupOwnershipInspectEnd, .physicalClose,
                 .cookieSettleStart, .cookieSettleEnd: .nativeTurn
            default: .serverAcknowledged
            }
        }
    }
    struct Event: Encodable, Equatable {
        let version: Int
        let source: Source
        let phase: Phase
        let sessionID: UUID
        let sequence: Int
        let inferenceID: UUID?
        let elapsedMs: Int
    }
    private static let log = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "WebsiteInference")
    private let source: Source
    private let sessionID: UUID
    private let sequence: Int
    private let inferenceID: UUID?
    private let started: ContinuousClock.Instant

    static func begin(source: Source, sessionToken: String, sequence: Int, inferenceID: UUID? = nil,
                      started: ContinuousClock.Instant = .now) -> Self? {
        guard let sessionID = UUID(uuidString: sessionToken), (1...16).contains(sequence),
              (source == .nativeTurn ? inferenceID == nil : inferenceID != nil) else { return nil }
        return Self(source: source, sessionID: sessionID, sequence: sequence, inferenceID: inferenceID, started: started)
    }

    static func milliseconds(_ value: Duration) -> Int {
        let parts = value.components
        return Int(max(0, min(600_000, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)))
    }

    func event(_ phase: Phase, at now: ContinuousClock.Instant = .now) -> Event? {
        guard phase.source == source else { return nil }
        return Event(version: 1, source: source, phase: phase, sessionID: sessionID,
                     sequence: sequence, inferenceID: inferenceID, elapsedMs: Self.milliseconds(now - started))
    }

    func mark(_ phase: Phase) {
        guard let event = event(phase) else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event), let encoded = String(data: data, encoding: .utf8) else { return }
        Self.log.notice("websiteResponse structure=\(encoded, privacy: .public)")
    }
}

/// WebKit can finish after timeout/cancellation. Only serialized bytes cross tasks,
/// and a late callback never resumes a continuation twice or replays an action.
final class EmbeddedScriptResult: @unchecked Sendable {
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

import AppKit
import Foundation
import Observation
import OSLog
import WebKit

@MainActor @Observable
final class EmbeddedBrowserTab: Identifiable {
    let id: UUID
    let isPopup: Bool
    fileprivate(set) var title = "New tab"
    fileprivate(set) var url: URL?
    fileprivate(set) var isLoading = false
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false
    fileprivate(set) var documentID = UUID()
    /// Invalidates full-document navigation receipts; SPA route changes preserve it.
    fileprivate(set) var documentGeneration = UUID()
    fileprivate(set) var error: String?
    fileprivate(set) var isWebInspectorEnabled = false
    fileprivate(set) var isWebInspectorAvailable = false

    fileprivate init(id: UUID = UUID(), isPopup: Bool = false) { self.id = id; self.isPopup = isPopup }
}

/// Browser views are independent of the privileged Octane UI WebView.
/// Hidden human views detach unless an active tool binding leases rendering.
/// Rendering leases never transfer tab ownership or presentation authority.
/// Only close/shutdown destroys either session.
@MainActor @Observable
final class EmbeddedBrowserSession {
    enum Failure: Error, LocalizedError, Equatable {
        case tabLimit(Int)
        case tabClosed
        case sessionClosed
        case modelTabPrivate
        case modelPopupUnsupported
        case toolPopupUnsupported
        case popupProfileMismatch
        case inspectionUnavailable, cookieMaintenancePending

        var errorDescription: String? {
            switch self {
            case .tabLimit(let limit): "This browser allows up to \(limit) tabs, including background model sessions. Close a browser tab before opening another; restart Computa if only retained model sessions remain."
            case .tabClosed: "That browser tab is no longer open."
            case .sessionClosed: "This browser session has ended."
            case .modelTabPrivate: "Model sessions run privately in the background. Open a regular browser tab to visit the website."
            case .modelPopupUnsupported: "Pop-up windows are not enabled for model inference pages."
            case .toolPopupUnsupported: "This task tab cannot open an unowned pop-up. Open the observed destination with the browser tools."
            case .popupProfileMismatch: "The requested pop-up did not preserve this browser's sign-in profile."
            case .inspectionUnavailable: "Web Inspector is unavailable for this tab while a task owns or uses it."
            case .cookieMaintenancePending: "The browser profile is completing a local maintenance operation."
            }
        }
    }

    private(set) var tabs: [EmbeddedBrowserTab] = []
    /// The human browser never exposes an inference page, including a retained
    /// session whose website cleanup could not be confirmed.
    var humanTabs: [EmbeddedBrowserTab] { tabs.filter { entries[$0.id]?.isModelOwned == false } }
    private(set) var selectedTabID: UUID?
    private(set) var errorMessage: String?
    #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
    enum ModelNativeFocusDiagnosticDisposition: String {
        case idle, armed, acquired, rejected, restored
    }
    private(set) var modelNativeFocusDiagnosticRequested = false
    private(set) var modelNativeFocusDiagnosticTabID: UUID?
    private(set) var modelNativeFocusDiagnosticDisposition: ModelNativeFocusDiagnosticDisposition = .idle

    /// Native UI only. A live, successfully saved synthetic first-turn capture
    /// consumes this choice; ordinary turns and Inspector leases cannot do so.
    func setModelNativeFocusDiagnosticRequested(_ requested: Bool) {
        guard !isShutdown, modelNativeFocusDiagnosticTabID == nil else { return }
        modelNativeFocusDiagnosticRequested = requested
        modelNativeFocusDiagnosticDisposition = requested ? .armed : .idle
    }

    func cancelModelNativeFocusDiagnostic() {
        modelNativeFocusDiagnosticRequested = false
        guard let id = modelNativeFocusDiagnosticTabID, let entry = entries[id] else {
            modelNativeFocusDiagnosticTabID = nil
            modelNativeFocusDiagnosticDisposition = .idle
            return
        }
        endModelNativeFocusDiagnostic(entry)
    }

    private func endModelNativeFocusDiagnostic(_ entry: Entry) {
        let synthetic = entry.syntheticNativeFocusDiagnostic
        entry.syntheticNativeFocusDiagnostic = nil
        synthetic?.expiry.cancel()
        synthetic?.binding.revoke()
        (entry.view as? EmbeddedModelWebView)?.endNativeFocusDiagnostic()
        if modelNativeFocusDiagnosticTabID == entry.tab.id {
            modelNativeFocusDiagnosticTabID = nil
            modelNativeFocusDiagnosticDisposition = .restored
        }
        if let synthetic {
            Self.inspectorDiagnosticLog.notice("syntheticNativeFocusDiagnostic version=1 nonce=\(synthetic.binding.nonce.uuidString.lowercased(), privacy: .public) sessionID=\(synthetic.binding.ownerToken.lowercased(), privacy: .public) generation=\(synthetic.binding.generation.uuidString.lowercased(), privacy: .public) disposition=restored")
        }
    }
    #endif
    let maximumTabs: Int
    var pendingChatGPTInferenceCookiePreparationCount: Int { inferenceCookieSeeds.count + inferenceCookieValidations.count }
    var failedChatGPTInferenceCookiePreparationCount: Int {
        inferenceCookieSeeds.values.filter(\.hasFailedCallerAwaitingCallback).count
            + inferenceCookieValidations.values.filter(\.hasFailedCallerAwaitingCallback).count
    }

    @ObservationIgnored private var websiteDataStore: WKWebsiteDataStore?
    @ObservationIgnored private var geminiCookieObservationRequests = 0
    @ObservationIgnored private var geminiCookieTimeline: GeminiVerificationCookieTimeline?
    @ObservationIgnored private var geminiDiagnosticCookieEvents: [GeminiCAPTCHADiagnostic.CookieEvent] = []
    @ObservationIgnored private var geminiDiagnosticCookieEventsDropped = 0
    @ObservationIgnored private let geminiDiagnosticDirectory: URL?
    @ObservationIgnored private var geminiDiagnosticSaveInstants: [ContinuousClock.Instant] = []
    #if DEBUG
    @ObservationIgnored private var geminiDiagnosticWriterForTesting: ((GeminiCAPTCHADiagnostic.Report) throws -> URL)?
    #endif
    @ObservationIgnored private var geminiResponseObservationClock: @MainActor () -> ContinuousClock.Instant = { .now }
    @ObservationIgnored private var geminiResponseObservationInstants: [ContinuousClock.Instant] = []
    #if DEBUG
    @ObservationIgnored private var geminiResponseObserverForTesting: (@MainActor (String) -> Void)?
    #endif
    @ObservationIgnored private var cacheIdentity: EmbeddedBrowserCacheIdentity?
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private let profileID: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cookieRetirementDirectory: URL?
    @ObservationIgnored private var temporaryCookieRetirement: ChatGPTTemporaryCookieRetirement?
    @ObservationIgnored private var inferenceCookieSeeds: [UUID: ChatGPTInferenceCookieSeed] = [:]
    @ObservationIgnored private var inferenceCookieValidations: [UUID: ChatGPTInferenceCookieValidation] = [:]
    @ObservationIgnored private var chatGPTInferencePrewarmingEnabled = false
    @ObservationIgnored private var chatGPTInferencePrewarmAdmission: (@MainActor () throws -> Void)?
    @ObservationIgnored private var chatGPTInferencePrewarm: InferencePrewarm?
    @ObservationIgnored private var chatGPTResumeProtections: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var uncertainChatGPTResumeProtections: Set<UUID> = []
    @ObservationIgnored private var chatGPTResumeProtectionOverflow = false
    @ObservationIgnored private var exclusiveCookieMaintenance: UUID?
    @ObservationIgnored private var chatGPTResumeProtectionRevision: UInt64 = 0
    @ObservationIgnored private let transientProfileID = UUID()
    @ObservationIgnored private var resolvedProfileID: UUID?
    @ObservationIgnored private var transientHumanVerificationCheckpoints: [String: UUID] = [:]
    @ObservationIgnored private var transientRecoveryReports: [String: EmbeddedHumanVerificationStore.RecoveryReport] = [:]
    @ObservationIgnored var onHumanVerificationRecoveryCandidate: (@MainActor (HumanVerificationRecoveryCandidate) -> Void)?
    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private weak var modelRenderHost: NSView?
    @ObservationIgnored private var modelRenderHosts: [ModelRenderHostReference] = []
    @ObservationIgnored private var isShutdown = false
    @ObservationIgnored private var geminiPostBlockDiagnosticConsumed = false
    static let profileDefaultsKey = "Computa.EmbeddedBrowser.ProfileIdentifier.v1"

    private final class ModelRenderHostReference {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    /// No transport Session, adapter, prompt, model choice or task owns this
    /// pristine root. Claiming consumes the exact physical page once.
    @MainActor private final class InferencePrewarm {
        let created = ContinuousClock.now
        let lifetime: Duration
        var deadline: ContinuousClock.Instant { created + lifetime }
        var claimed = false
        var task: Task<UUID?, Never>?
        var expiry: Task<Void, Never>?
        var tabID: UUID?
        var view: WKWebView?
        var generation: UUID?
        var source: WKWebsiteDataStore?
        var sourceCookies: [HTTPCookie]?
        var validation: ChatGPTInferenceCookieValidation?
        var resumeValidation: ChatGPTInferenceCookieValidation?
        var resumeTask: Task<Void, Never>?
        init(lifetime: Duration) { self.lifetime = lifetime }
    }

    private enum InferencePrewarmUnavailable: String {
        case identity, navigationError = "navigation_error", blankIdle = "blank_idle", unexpectedRoute = "unexpected_route"
    }

    private enum InferenceCookieValidationPhase: String { case claim, resume }
    private enum InferenceCookieValidationOutcome: String { case match, mismatch, unavailable, cancelled }

    private struct ToolMutationPopupContext {
        let operationID = UUID()
        let documentID: UUID
        var rejected = false
    }

    @MainActor private final class Entry {
        let tab: EmbeddedBrowserTab
        let view: WKWebView
        let delegate: EmbeddedBrowserDelegate
        let isModelOwned: Bool
        let isToolOwned: Bool
        let usesIsolatedChatGPTProfile: Bool
        let navigationChanges = EmbeddedModelChangeChannel(ownerToken: UUID().uuidString)
        let popupOpenerTabID: UUID?
        weak var presentationHost: NSView?
        var toolRenderLeases: Set<UUID> = []
        var frameBeforeToolRendering: (frame: NSRect, autoresizing: NSView.AutoresizingMask)?
        var needsBackgroundRendering: Bool { isModelOwned || isToolOwned || !toolRenderLeases.isEmpty }
        var shouldMountInBackground: Bool { needsBackgroundRendering && (presentationHost == nil || !toolRenderLeases.isEmpty) }
        var observations: [NSKeyValueObservation] = []
        var navigation: WKNavigation?
        var geminiPostBlockObservation: (lease: GeminiPostBlockNativeLease, callback: @MainActor (GeminiPostBlockNativeEvent) -> Void)?
        var geminiResponseObservationGeneration: UUID?
        var geminiResponseObservationsInGeneration = 0
        var geminiDiagnosticJournal = GeminiCAPTCHADiagnostic.Journal()
        var geminiDiagnosticIncident: (generation: UUID, report: GeminiCAPTCHADiagnostic.Report, attempts: Int, saved: Bool)?
        var preparedDocumentNavigation = false
        // Native lifecycle facts can defer an untouched initial inspection,
        // but never grant adapter, document, or recovery authority.
        // Binds a future, page-initiated root navigation to its previous native generation.
        var hadChatRootDiagnostic = false
        var authorizedChatRootRequest: UUID?
        var initialChatRootTransition: (from: UUID, to: UUID)?
        var modelCommittedGeneration: UUID?
        var modelFinishedGeneration: UUID?
        var modelFailedGeneration: UUID?
        // Observation only: these never participate in readiness or quarantine.
        // A false flag means not observed, not proof that no redirect occurred.
        var modelNavigationGeneration: UUID?
        var geminiDocumentCommitObserved = false
        var serverRedirectObservedInCurrentNavigation = false
        var inspectorDiagnostic: (id: UUID, binding: ChatGPTInspectorLease.Binding, expiry: Task<Void, Never>)?
        #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
        var syntheticNativeFocusDiagnostic: (id: UUID, binding: WebsiteBenchmarkCaptureLease.NativeFocusBinding,
                                            expiry: Task<Void, Never>)?
        #endif
        var requestMetadataDiagnostic: RequestMetadataDiagnostic?
        var groqStatus: GroqStatusProbe?
        var qwenMarkerProbe: QwenMarkerProbe?
        var claudeResponseStreamDiagnostic: ClaudeResponseStreamDiagnosticState?
        // Stop removes the page observer, but close must still revoke this exact
        // lease after transport's pre-cleanup persistence attempt.
        var claudeResponseStreamLease: ClaudeResponseStreamLease?
        var responseCompletionObserver: ResponseCompletionObserver?
        var responseCompletion: ChatGPTResponseCompletion?
        var responseCompletionDiagnosticLogged = false
        var responseCompletionPreparation: ResponseCompletionPreparation?
        var ownedTemporaryChatGPTRoutes: Set<UUID> = []
        var inferenceCookieSummary: ChatGPTInferenceCookieSeed.Summary?
        var pendingConversationURL: URL?
        var pendingConversationAdmission: (id: UUID, generation: UUID)?
        var pendingCacheAdmission: (id: UUID, generation: UUID)?
        var modelChanges: EmbeddedModelChangeChannel?
        var qwenCodePayloadChannel: [String: String]?
        var modelSignalWorld: WKContentWorld?
        var modelSignalOriginHost: String?
        var modelDiagnosticOperation: UUID?
        var modelDiagnosticGeneration: UUID?
        var modelDiagnosticStarted: ContinuousClock.Instant?
        var modelDiagnosticPhaseStarted: ContinuousClock.Instant?
        var modelDiagnosticPhases: [ModelAdapterPhase] = []
        var modelDiagnosticReceived: UInt16 = 0
        var modelDiagnosticAccepted: UInt16 = 0
        var modelDiagnosticLastRejection: ModelDiagnosticRejection?
        var modelDOMReceivedAtOperationStart: UInt16 = 0
        var modelClockWaits: [UUID: ModelClockWait] = [:]
        var modelDOMSignalsReceived: UInt16 = 0
        var modelDOMSignalsAccepted: UInt16 = 0
        // Model generations also invalidate on provisional loads. Human
        // checkpoint observations advance only for a committed document.
        var humanCommittedDocumentID = UUID()
        var humanCommittedNavigation: WKNavigation?
        var recoveryCommittedGeneration: UUID?
        var recoverySettledGeneration: UUID?
        var recoveryToolUsed = false
        var geminiCookieObservationGeneration: UUID?
        var recoveryAttemptedCheckpointID: UUID?
        var recoveryAttemptedDocumentID: UUID?
        // The callback that requests a popup carries no public tool-origin
        // token. Retain the guard until a replacement document commits so
        // delayed page callbacks cannot become human-owned after tool cleanup.
        var toolPopupContext: ToolMutationPopupContext?
        // Ephemeral deduplication only; neither URL nor document identity is persisted.
        var humanCheckpointDocumentID: UUID?
        var humanCheckpointURL: URL?

        init(tab: EmbeddedBrowserTab, view: WKWebView, delegate: EmbeddedBrowserDelegate, isModelOwned: Bool, isToolOwned: Bool = false,
             popupOpenerTabID: UUID? = nil, usesIsolatedChatGPTProfile: Bool = false) {
            self.tab = tab
            self.view = view
            self.delegate = delegate
            self.isModelOwned = isModelOwned
            self.isToolOwned = isToolOwned
            self.usesIsolatedChatGPTProfile = usesIsolatedChatGPTProfile
            self.popupOpenerTabID = popupOpenerTabID
        }
    }

    /// `persistent: false` makes an isolated, nonpersistent test/private session.
    /// An explicit profile ID avoids reading or writing the production preference in tests.
    init(persistent: Bool = true, maximumTabs: Int = 8, profileID: UUID? = nil, defaults: UserDefaults = .standard,
         cookieRetirementDirectory: URL? = nil, geminiDiagnosticDirectory: URL? = nil) {
        self.maximumTabs = max(1, min(maximumTabs, 32))
        self.persistent = persistent
        self.profileID = profileID
        self.defaults = defaults
        self.cookieRetirementDirectory = cookieRetirementDirectory
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.geminiDiagnosticDirectory = geminiDiagnosticDirectory ?? (persistent ? support.appendingPathComponent(
            "LocalCodex/CodexHome/GeminiCAPTCHADiagnostics-v1", isDirectory: true) : nil)
    }

    /// Resolve once for both WebKit and saved checkpoints, even if preferences
    /// change while this browser instance is alive. Private sessions never call this.
    private func persistentProfileIdentifier() -> UUID {
        precondition(persistent)
        if let resolvedProfileID { return resolvedProfileID }
        let identifier: UUID
        if let profileID {
            identifier = profileID
        } else if let existing = defaults.string(forKey: Self.profileDefaultsKey).flatMap(UUID.init(uuidString:)) {
            identifier = existing
        } else {
            identifier = UUID()
            defaults.set(identifier.uuidString, forKey: Self.profileDefaultsKey)
        }
        resolvedProfileID = identifier
        return identifier
    }

    var savedHumanVerificationCheckpointIDs: [String: UUID] {
        guard persistent else { return transientHumanVerificationCheckpoints }
        return EmbeddedHumanVerificationStore(defaults: defaults, profileID: persistentProfileIdentifier()).load()
    }

    var savedHumanVerificationProviders: Set<String> { Set(savedHumanVerificationCheckpointIDs.keys) }

    struct HumanVerificationRecoveryCandidate: Equatable, Sendable {
        let id = UUID()
        let provider: String
        let checkpointID: UUID
        let tabID: UUID
        let committedDocumentID: UUID
        let documentID: UUID
        let documentGeneration: UUID
    }

    var humanVerificationRecoveryReports: [String: EmbeddedHumanVerificationStore.RecoveryReport] {
        guard persistent else { return transientRecoveryReports }
        return EmbeddedHumanVerificationStore(defaults: defaults, profileID: persistentProfileIdentifier()).loadRecoveryReports()
    }

    func recordHumanVerificationRecovery(_ candidate: HumanVerificationRecoveryCandidate,
        phase: EmbeddedHumanVerificationStore.RecoveryReport.Phase,
        reason: EmbeddedHumanVerificationStore.RecoveryReport.Reason) {
        var reports = humanVerificationRecoveryReports
        // A late completion must not replace a newer candidate's diagnostic.
        guard phase == .requested || reports[candidate.provider]?.recoveryID == candidate.id else { return }
        reports[candidate.provider] = .init(checkpointID: candidate.checkpointID, recoveryID: candidate.id, phase: phase, reason: reason)
        if persistent {
            EmbeddedHumanVerificationStore(defaults: defaults, profileID: persistentProfileIdentifier()).saveRecoveryReports(reports)
        } else { transientRecoveryReports = reports }
    }

    func isHumanVerificationRecoveryCandidateCurrent(_ candidate: HumanVerificationRecoveryCandidate) -> Bool {
        isHumanVerificationRecoverySourceCurrent(candidate)
            && savedHumanVerificationCheckpointIDs[candidate.provider] == candidate.checkpointID
    }

    /// Freshness only after a separately verified discovery and cleanup. This
    /// does not clear a checkpoint, authorize a probe or establish recovery.
    func isHumanVerificationRecoverySourceCurrentAfterDiscovery(_ candidate: HumanVerificationRecoveryCandidate) -> Bool {
        isHumanVerificationRecoverySourceCurrent(candidate)
            && savedHumanVerificationCheckpointIDs[candidate.provider] == nil
    }

    private func isHumanVerificationRecoverySourceCurrent(_ candidate: HumanVerificationRecoveryCandidate) -> Bool {
        guard !isShutdown, let entry = entries[candidate.tabID], !entry.isModelOwned, !entry.isToolOwned,
              !entry.recoveryToolUsed, entry.toolPopupContext == nil,
              entry.humanCommittedDocumentID == candidate.committedDocumentID,
              entry.tab.documentID == candidate.documentID, entry.tab.documentGeneration == candidate.documentGeneration,
              entry.recoveryCommittedGeneration == candidate.documentGeneration,
              entry.recoverySettledGeneration == candidate.documentGeneration,
              entry.navigation == nil, !entry.view.isLoading, !entry.tab.isLoading, entry.tab.error == nil,
              EmbeddedHumanVerificationStore.recoveryProvider(forTrustedHumanURL: entry.view.url) == candidate.provider else { return false }
        return true
    }

    private func observeHumanVerificationRecovery(_ entry: Entry) {
        guard let callback = onHumanVerificationRecoveryCandidate,
              let provider = EmbeddedHumanVerificationStore.recoveryProvider(forTrustedHumanURL: entry.view.url),
              let checkpointID = savedHumanVerificationCheckpointIDs[provider] else { return }
        let candidate = HumanVerificationRecoveryCandidate(provider: provider, checkpointID: checkpointID,
            tabID: entry.tab.id, committedDocumentID: entry.humanCommittedDocumentID,
            documentID: entry.tab.documentID, documentGeneration: entry.tab.documentGeneration)
        guard isHumanVerificationRecoveryCandidateCurrent(candidate),
              entry.recoveryAttemptedCheckpointID != checkpointID || entry.recoveryAttemptedDocumentID != entry.humanCommittedDocumentID else { return }
        entry.recoveryAttemptedCheckpointID = checkpointID
        entry.recoveryAttemptedDocumentID = entry.humanCommittedDocumentID
        recordHumanVerificationRecovery(candidate, phase: .requested, reason: .healthyHumanDocument)
        callback(candidate)
    }

    /// Re-observing a saved gate in the model transport does not make it newer.
    func recordHumanVerificationRequired(provider: String) {
        recordHumanVerificationRequired(provider: provider, renewObservation: false)
    }

    private func recordHumanVerificationRequired(provider: String, renewObservation: Bool) {
        guard EmbeddedHumanVerificationStore.providers.contains(provider) else { return }
        var checkpoints = savedHumanVerificationCheckpointIDs
        guard renewObservation || checkpoints[provider] == nil else { return }
        checkpoints[provider] = UUID()
        saveHumanVerificationCheckpoints(checkpoints)
    }

    func clearHumanVerificationRequired(provider: String) {
        guard EmbeddedHumanVerificationStore.providers.contains(provider) else { return }
        var checkpoints = savedHumanVerificationCheckpointIDs
        guard checkpoints.removeValue(forKey: provider) != nil else { return }
        saveHumanVerificationCheckpoints(checkpoints)
    }

    private func saveHumanVerificationCheckpoints(_ checkpoints: [String: UUID]) {
        if persistent {
            EmbeddedHumanVerificationStore(defaults: defaults, profileID: persistentProfileIdentifier()).save(checkpoints)
        } else {
            transientHumanVerificationCheckpoints = checkpoints
        }
        for entry in entries.values where entry.isModelOwned { signalModelChange(entry) }
    }

    private func dataStore() -> WKWebsiteDataStore {
        if let websiteDataStore { return websiteDataStore }
        let store: WKWebsiteDataStore
        if persistent {
            store = WKWebsiteDataStore(forIdentifier: persistentProfileIdentifier())
        } else {
            store = .nonPersistent()
        }
        websiteDataStore = store
        let timeline = GeminiVerificationCookieTimeline(store: store.httpCookieStore, sink: { [weak self] event in
            self?.recordGeminiDiagnosticCookieEvent(event)
            if let data = try? event.logData(), data.count <= 1_000 {
                Self.inferencePrewarmLog.notice("geminiVerificationCookieTimeline \(String(decoding: data, as: UTF8.self), privacy: .public)")
            }
            #if DEBUG
            self?.geminiCookieTimelineSinkForTesting?(event)
            #endif
        })
        geminiCookieTimeline = timeline
        timeline.start()
        if persistent {
            // ComputaApp creates one session and injects it into AppState; that
            // session owns this profile and one migration shared by all tabs.
            #if DEBUG
            if let removal = cacheIdentityRemovalForTesting {
                cacheIdentity = EmbeddedBrowserCacheIdentity(profileID: persistentProfileIdentifier(),
                    identity: EmbeddedBrowserIdentity.currentCacheIdentity, defaults: defaults, remove: removal)
            } else {
                cacheIdentity = EmbeddedBrowserCacheIdentity(profileID: persistentProfileIdentifier(), store: store, defaults: defaults)
            }
            #else
            cacheIdentity = EmbeddedBrowserCacheIdentity(profileID: persistentProfileIdentifier(), store: store, defaults: defaults)
            #endif
        }
        let registry: ChatGPTTemporaryCookieRegistry?
        if persistent {
            let profile = persistentProfileIdentifier()
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            let directory = cookieRetirementDirectory ?? support
                .appendingPathComponent("Computa/BrowserCookieRetirement-v1/" + profile.uuidString.lowercased(), isDirectory: true)
            registry = ChatGPTTemporaryCookieRegistry(directory: directory, profileID: profile)
        } else { registry = nil }
        temporaryCookieRetirement = ChatGPTTemporaryCookieRetirement(store: ChatGPTWKTemporaryCookieStore(store.httpCookieStore),
            registry: registry, initiallySuspended: exclusiveCookieMaintenance != nil,
            protection: { [weak self] in self?.protectedChatGPTConversationIDs() })
        return store
    }

    /// Only admitted native temporary first-message lineage may call this.
    /// Page selection IDs and cookie-name deltas never enter this path.
    func recordOwnedTemporaryChatGPTRoutes(_ ids: Set<UUID>, tabID: UUID, view: WKWebView,
                                         ownerToken: String, generation: UUID, firstUserFingerprint: String) {
        guard !isShutdown, !ids.isEmpty, ids.count <= 2, let entry = entries[tabID], entry.isModelOwned,
              entry.view === view, entry.modelChanges?.ownerToken == ownerToken,
              entry.tab.documentGeneration == generation, Self.inspectorOriginAllowed(view.url),
              firstUserFingerprint.utf8.count == 64,
              firstUserFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              entry.ownedTemporaryChatGPTRoutes.union(ids).count <= 2 else { return }
        entry.ownedTemporaryChatGPTRoutes.formUnion(ids)
    }

    func settleChatGPTTemporaryCookieRetirement(until deadline: ContinuousClock.Instant) async -> Bool {
        guard !isShutdown else { return false }
        _ = dataStore()
        return await temporaryCookieRetirement?.settle(until: deadline) ?? false
    }

    func admitChatGPTAfterCookieCallbacks(until deadline: ContinuousClock.Instant) async -> Bool {
        guard !isShutdown, exclusiveCookieMaintenance == nil else { return false }
        _ = dataStore()
        _ = await temporaryCookieRetirement?.settle(until: deadline)
        return temporaryCookieRetirement?.canAdmit == true
    }

    /// Startup-only native maintenance. The operation must await every issued
    /// store callback before returning, including cancellation/timeout paths.
    /// The lease cannot be granted while any tab or retirement callback exists.
    func withExclusiveCookieMaintenance<Result>(
        _ operation: @MainActor (WKHTTPCookieStore, UUID, @escaping @MainActor () -> Bool) async -> Result
    ) async -> Result? {
        guard !isShutdown, entries.isEmpty, inferenceCookieSeeds.isEmpty, inferenceCookieValidations.isEmpty, exclusiveCookieMaintenance == nil else { return nil }
        let lease = UUID(), revision = chatGPTResumeProtectionRevision
        exclusiveCookieMaintenance = lease
        var suspended = false
        defer {
            if exclusiveCookieMaintenance == lease { exclusiveCookieMaintenance = nil }
            if suspended { _ = temporaryCookieRetirement?.setSuspended(false) }
        }
        let store = dataStore()
        guard temporaryCookieRetirement?.setSuspended(true) == true else { return nil }
        suspended = true
        _ = await temporaryCookieRetirement?.settle(until: .now + .seconds(2))
        guard !isShutdown, entries.isEmpty, exclusiveCookieMaintenance == lease,
              temporaryCookieRetirement?.hasPendingCallback == false else { return nil }
        let profile = persistent ? persistentProfileIdentifier() : (profileID ?? transientProfileID)
        return await operation(store.httpCookieStore, profile, { [weak self] in
            guard let self else { return false }
            return !self.isShutdown && self.entries.isEmpty && self.exclusiveCookieMaintenance == lease
                && self.websiteDataStore === store && self.chatGPTResumeProtectionRevision == revision
        })
    }

    func cookieMaintenanceProtectedIDs() -> Set<UUID>? {
        guard entries.isEmpty, exclusiveCookieMaintenance != nil else { return nil }
        return protectedChatGPTConversationIDs()
    }

    /// Native future resume owners reserve IDs before allowing an admission.
    /// Unknown or over-bound inventories conservatively defer maintenance.
    func holdChatGPTConversationResumeIDs(_ ids: Set<UUID>?, owner: UUID) {
        chatGPTResumeProtectionRevision &+= 1
        guard chatGPTResumeProtections[owner] != nil || uncertainChatGPTResumeProtections.contains(owner)
                || chatGPTResumeProtections.count + uncertainChatGPTResumeProtections.count < 32 else {
            chatGPTResumeProtectionOverflow = true; return
        }
        if let ids, ids.count <= 512, chatGPTResumeProtections.count < 32 || chatGPTResumeProtections[owner] != nil {
            chatGPTResumeProtections[owner] = ids; uncertainChatGPTResumeProtections.remove(owner)
        } else { uncertainChatGPTResumeProtections.insert(owner) }
    }

    func releaseChatGPTConversationResumeIDs(owner: UUID) {
        chatGPTResumeProtectionRevision &+= 1
        chatGPTResumeProtections.removeValue(forKey: owner); uncertainChatGPTResumeProtections.remove(owner)
        temporaryCookieRetirement?.requestSweep()
    }

    private func protectedChatGPTConversationIDs() -> Set<UUID>? {
        guard !isShutdown, !chatGPTResumeProtectionOverflow, uncertainChatGPTResumeProtections.isEmpty else { return nil }
        var ids = chatGPTResumeProtections.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        guard ids.count <= 512 else { return nil }
        func add(_ url: URL?) -> Bool {
            if let id = ChatGPTTemporaryConversationRoutes.id(from: url) { ids.insert(id) }
            else if let url, EmbeddedWebModelTransport.Provider.chatgpt.conversationURL(url.absoluteString) != nil { return false }
            return ids.count <= 512
        }
        for entry in entries.values {
            ids.formUnion(entry.ownedTemporaryChatGPTRoutes)
            let history = entry.view.backForwardList
            let back = history.backList, forward = history.forwardList
            guard back.count <= 256, forward.count <= 256 else { return nil }
            // A human/tool SPA can switch routes without a navigation delegate.
            // History may restore that writer. Defer maintenance for its whole
            // ChatGPT lifetime; never guess which IDs it might use next.
            let humanURLs = [entry.view.url, entry.tab.url, entry.pendingConversationURL, history.currentItem?.url]
                + back.map { Optional($0.url) } + forward.map { Optional($0.url) }
            if !entry.isModelOwned, humanURLs.contains(where: { $0?.host?.lowercased() == "chatgpt.com" }) { return nil }
            if (entry.view.isLoading || entry.tab.isLoading), entry.view.url == nil || entry.pendingConversationURL?.host == "chatgpt.com"
                || entry.view.url?.host == "chatgpt.com" { return nil }
            if entry.view.url?.host == "chatgpt.com", ChatGPTTemporaryConversationRoutes.id(from: entry.view.url) == nil { return nil }
            guard add(entry.view.url), add(entry.tab.url), add(entry.pendingConversationURL), add(history.currentItem?.url) else { return nil }
            for item in back + forward { guard add(item.url) else { return nil } }
            guard ids.count <= 512 else { return nil }
        }
        return ids
    }

    @discardableResult
    func createTab(url: URL? = nil, select: Bool = true) throws -> UUID {
        try createTab(url: url, select: select, modelOwned: false)
    }

    private func createTab(url: URL? = nil, select: Bool, modelOwned: Bool, toolOwned: Bool = false,
                           isolatedChatGPTStore: WKWebsiteDataStore? = nil) throws -> UUID {
        do {
            guard !isShutdown else { throw Failure.sessionClosed }
            guard tabs.count + pendingChatGPTInferenceCookiePreparationCount < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
            if let url { try EmbeddedBrowserURLPolicy.validate(url) }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = isolatedChatGPTStore ?? dataStore()
            // This fresh controller has no native script handlers, scripts, or UI resource scheme.
            configuration.userContentController = WKUserContentController()
            // OAuth can open a window after an asynchronous response, beyond
            // the original click's gesture. Human popups still use the tab cap
            // and navigation policy; inference-owned pages cannot open them.
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = !modelOwned && !toolOwned
            if modelOwned {
                // Inference pages must keep executing while privately hosted.
                // This public macOS 14 policy controls inactive/detached view
                // scheduling; it grants no browser or model authority.
                configuration.preferences.inactiveSchedulingPolicy = .none
            }
            if modelOwned, isolatedChatGPTStore != nil {
                let arm = defaults.object(forKey: "ComputaRendererFailureDiagnosticExpiresAt")
                if let script = Self.rendererStartupDiagnosticScript(armedUntil: arm, source: {
                    Self.rendererDiagnosticSource(named: "chatgpt-renderer-startup-diagnostic")
                }) { configuration.userContentController.addUserScript(script) }
                for script in Self.rendererRegexDiagnosticScripts(armedUntil: arm, source: {
                    Self.rendererDiagnosticSource(named: "chatgpt-regex-diagnostic")
                }) { configuration.userContentController.addUserScript(script) }
            }
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let entry = try registerTab(configuration: configuration, select: select, modelOwned: modelOwned, toolOwned: toolOwned,
                                        usesIsolatedChatGPTProfile: isolatedChatGPTStore != nil)
            if toolOwned { mountModelView(entry) }
            // Empty tabs intentionally do not load a homepage or trigger any network request.
            if let url { try navigate(tabID: entry.tab.id, to: url) }
            return entry.tab.id
        } catch {
            if !modelOwned { errorMessage = error.localizedDescription }
            throw error
        }
    }

    private func registerTab(configuration: WKWebViewConfiguration, select: Bool, modelOwned: Bool, toolOwned: Bool = false,
                             popupOpenerTabID: UUID? = nil, usesIsolatedChatGPTProfile: Bool = false) throws -> Entry {
        guard !isShutdown else { throw Failure.sessionClosed }
        guard exclusiveCookieMaintenance == nil else { throw Failure.cookieMaintenancePending }
        guard tabs.count + pendingChatGPTInferenceCookiePreparationCount < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
        // Apply before construction/initial navigation for human, tool, model
        // and popup tabs. Keep WebKit's own platform/engine user-agent prefix.
        configuration.applicationNameForUserAgent = EmbeddedBrowserIdentity.currentApplicationName
        let tab = EmbeddedBrowserTab(isPopup: popupOpenerTabID != nil)
        let view: WKWebView
        #if DEBUG
        if modelOwned, let factory = modelViewFactoryForTesting { view = factory(configuration) }
        else {
            view = EmbeddedModelWebView(frame: modelOwned || toolOwned ? NSRect(x: 0, y: 0, width: 1_024, height: 768) : .zero,
                                        configuration: configuration)
        }
        #else
        view = EmbeddedModelWebView(frame: modelOwned || toolOwned ? NSRect(x: 0, y: 0, width: 1_024, height: 768) : .zero,
                                    configuration: configuration)
        #endif
        (view as? EmbeddedModelWebView)?.protectsNativeFocus = modelOwned || toolOwned
        // Inspection is an explicit, ephemeral choice for each human tab.
        // An inspectable opener must not grant it to a new popup.
        view.isInspectable = false
        tab.isWebInspectorAvailable = !modelOwned && !toolOwned
        let delegate = EmbeddedBrowserDelegate(session: self, tabID: tab.id)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.allowsBackForwardNavigationGestures = true
        let entry = Entry(tab: tab, view: view, delegate: delegate, isModelOwned: modelOwned, isToolOwned: toolOwned,
                          popupOpenerTabID: popupOpenerTabID, usesIsolatedChatGPTProfile: usesIsolatedChatGPTProfile)
        entries[tab.id] = entry
        tabs.append(tab)
        // Inactive creation stays inactive, including the first inference tab.
        if select { selectedTabID = tab.id }
        observe(entry)
        if !modelOwned { errorMessage = nil }
        return entry
    }

    fileprivate func createPopup(from source: WKWebView, tabID: UUID,
                                 configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        guard let opener = entries[tabID], opener.view === source else { return nil }
        do {
            guard !opener.isModelOwned else { throw Failure.modelPopupUnsupported }
            guard !opener.isToolOwned else { throw Failure.toolPopupUnsupported }
            if opener.toolPopupContext?.documentID == opener.humanCommittedDocumentID {
                opener.toolPopupContext?.rejected = true
                // A rejected task popup must not poison the borrowed human
                // document's error state or prevent a subsequent read.
                return nil
            }
            // window.open('', name) supplies an empty relative URL rather than
            // nil/about:blank. WebKit owns that initial blank document.
            if let url, !url.absoluteString.isEmpty { try EmbeddedBrowserURLPolicy.validate(url) }
            guard configuration.websiteDataStore === source.configuration.websiteDataStore else {
                throw Failure.popupProfileMismatch
            }
            // Preserve WebKit's configuration, opener and initial navigation.
            // Registration adds the same browser identity; never load again.
            return try registerTab(configuration: configuration, select: true, modelOwned: false,
                                   popupOpenerTabID: tabID).view
        } catch {
            report(error.localizedDescription, tabID: tabID)
            return nil
        }
    }

    fileprivate func closePopup(_ view: WKWebView, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view, !entry.isModelOwned,
              entry.popupOpenerTabID != nil else { return }
        closeTab(tabID)
    }

    func selectTab(_ id: UUID) {
        guard let entry = entries[id] else { errorMessage = Failure.tabClosed.localizedDescription; return }
        guard !entry.isModelOwned else { return }
        selectedTabID = id
        errorMessage = entry.tab.error
    }

    func closeTab(_ id: UUID) {
        guard let entry = entries[id], let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Freeze and sync evidence while this exact page, generation and its
        // delegates still exist. Failure to save never changes cleanup authority.
        if EmbeddedHumanVerificationStore.provider(forTrustedHumanURL: entry.view.url) == "gemini"
            || entry.geminiDiagnosticIncident != nil {
            captureGeminiCAPTCHA(tabID: id, view: entry.view, trigger: .beforeClose)
        }
        entries.removeValue(forKey: id)
        entry.toolRenderLeases.removeAll()
        entry.frameBeforeToolRendering = nil
        removeResponseCompletionObserver(entry)
        revokeRequestMetadata(entry)
        revokeClaudeResponseStream(entry)
        removeGroqStatus(entry)
        removeQwenMarker(entry)
        let postBlockObservation = entry.geminiPostBlockObservation
        entry.geminiPostBlockObservation = nil
        revokeModelInspector(entry, reason: isShutdown ? .shutdown : .closed)
        let humanIndex = tabs.prefix(index).filter { entries[$0.id]?.isModelOwned == false }.count
        entry.view.isInspectable = false
        entry.tab.isWebInspectorEnabled = false
        entry.tab.isWebInspectorAvailable = false
        entry.tab.documentID = UUID()
        entry.tab.documentGeneration = UUID()
        entry.modelChanges?.close()
        entry.navigationChanges.close()
        cancelModelClocks(entry)
        if let world = entry.modelSignalWorld {
            entry.view.configuration.userContentController.removeScriptMessageHandler(forName: Self.modelSignalName, contentWorld: world)
            entry.view.configuration.userContentController.removeScriptMessageHandler(forName: Self.modelDiagnosticName, contentWorld: world)
            entry.view.configuration.userContentController.removeScriptMessageHandler(forName: Self.modelClockName, contentWorld: world)
        }
        entry.delegate.invalidate()
        entry.observations.forEach { $0.invalidate() }
        entry.observations.removeAll()
        entry.navigation = nil
        entry.view.navigationDelegate = nil
        entry.view.uiDelegate = nil
        entry.view.stopLoading()
        entry.view.removeFromSuperview()
        tabs.remove(at: index)
        if selectedTabID == id {
            if let opener = entry.popupOpenerTabID, entries[opener]?.isModelOwned == false { selectedTabID = opener }
            else {
                let remaining = humanTabs
                selectedTabID = remaining.isEmpty ? nil : remaining[min(humanIndex, remaining.count - 1)].id
            }
        }
        if !entry.isModelOwned { errorMessage = selectedTabID.flatMap { entries[$0]?.tab.error } }
        if let observation = postBlockObservation {
            observation.lease.exactViewClosed = true
            observation.callback(.closed)
        }
        if entry.usesIsolatedChatGPTProfile {
            // Its cookies never belonged to the human store; closing it grants
            // no authority to retire an ID in that separate profile.
        } else if entry.isModelOwned, !entry.ownedTemporaryChatGPTRoutes.isEmpty {
            _ = temporaryCookieRetirement?.registerClosedOwnedIDs(entry.ownedTemporaryChatGPTRoutes)
        } else { temporaryCookieRetirement?.requestSweep() }
        if !isShutdown, entry.isModelOwned, entry.view.configuration.websiteDataStore === websiteDataStore {
            geminiCookieTimeline?.observe(.modelClosed)
        }
    }

    func navigate(tabID: UUID, to url: URL) throws {
        do {
            let entry = try entry(tabID)
            try EmbeddedBrowserURLPolicy.validate(url)
            prepareNavigation(entry, replacesDocument: true)
            entry.pendingConversationURL = url
            (entry.view as? EmbeddedModelWebView)?.captureNativeFocus()
            entry.navigation = entry.view.load(URLRequest(url: url))
        } catch {
            report(error.localizedDescription, tabID: tabID)
            throw error
        }
    }

    func goBack(tabID: UUID) {
        guard let entry = entries[tabID], entry.view.canGoBack else { return }
        prepareNavigation(entry)
        entry.pendingConversationURL = entry.view.backForwardList.backItem?.url
        entry.navigation = entry.view.goBack()
    }

    func goForward(tabID: UUID) {
        guard let entry = entries[tabID], entry.view.canGoForward else { return }
        prepareNavigation(entry)
        entry.pendingConversationURL = entry.view.backForwardList.forwardItem?.url
        entry.navigation = entry.view.goForward()
    }

    func reload(tabID: UUID) {
        guard let entry = entries[tabID], entry.view.url != nil else { return }
        prepareNavigation(entry, replacesDocument: true)
        entry.pendingConversationURL = entry.view.url
        entry.navigation = entry.view.reload()
    }

    func stop(tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        entry.pendingCacheAdmission = nil
        entry.delegate.cancelCacheAdmission()
        revokeResponseCompletion(entry)
        removeGroqStatus(entry)
        removeQwenMarker(entry)
        revokeClaudeResponseStream(entry)
        revokeModelInspector(entry, reason: .navigation)
        resetModelNavigationDiagnostic(entry)
        entry.navigation = nil
        entry.preparedDocumentNavigation = false
        entry.tab.documentID = UUID()
        entry.tab.documentGeneration = UUID()
        entry.view.stopLoading()
        entry.tab.isLoading = false
        signalModelChange(entry)
    }

    func webView(for id: UUID) -> WKWebView? { entries[id]?.view }

    func canInspect(tabID: UUID) -> Bool {
        guard !isShutdown, let entry = entries[tabID] else { return false }
        return entry.tab.isWebInspectorAvailable && !entry.isModelOwned && !entry.isToolOwned
            && entry.toolPopupContext?.documentID != entry.humanCommittedDocumentID
    }

    /// Public WebKit inspection only; no inspector is opened and no page data is captured.
    func setWebInspectorEnabled(_ enabled: Bool, for tabID: UUID) throws {
        let entry = try entry(tabID)
        guard !enabled || canInspect(tabID: tabID) else { throw Failure.inspectionUnavailable }
        entry.view.isInspectable = enabled
        entry.tab.isWebInspectorEnabled = enabled
    }

    enum ModelInspectorRevocation: String {
        case navigation, origin, closed, shutdown, expired, nativeContext = "native_context", finished
    }
    private static let inspectorDiagnosticLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "ModelInspectorDiagnostic")

    /// This observes one explicitly armed synthetic inference. It never supplies
    /// response text, ownership, provider completion or tool-dispatch authority.
    @MainActor private final class GroqStatusProbe {
        let lease: GroqOwnedStatusLease
        let key = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let secret = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let url: URL
        let source: String
        var initialStart = false
        var initialPreparation = false
        var generation: UUID?
        var owner: String?
        var fingerprint: String?
        var armed = false
        init?(lease:GroqOwnedStatusLease, url:URL) {
            self.lease=lease; self.url=url
            guard EmbeddedWebModelTransport.Provider.groq.acceptsGroqModelQuery(url,expectedKey:lease.modelChoice.key),
                  let source=EmbeddedBrowserSession.rendererDiagnosticSource(named:"groq-owned-status"),
                  source.components(separatedBy:"__GROQ_OWNED_SYNTHETIC_CONFIG__").count==2 else{return nil}
            let remaining=(lease.deadline - ContinuousClock.now).components
            let milliseconds=Int(min(390_000,max(0,Double(remaining.seconds)*1000+Double(remaining.attoseconds)/1e15)))
            guard milliseconds>0 else{return nil}
            self.source = source
        }
        // Capture the current page fetch only inside the already-verified arm
        // evaluation. No early wrapper or previously captured fetch is rebound.
        func installationSource() -> String? {
            guard lease.isCurrent else { return nil }
            let remaining=(lease.deadline - ContinuousClock.now).components
            let milliseconds=Int(min(390_000,max(0,Double(remaining.seconds)*1000+Double(remaining.attoseconds)/1e15)))
            var config:[String:Any]=["key":key,"secret":secret,"durationMs":milliseconds,"profile":lease.profile.rawValue]
            if lease.isFixture { config["setupDiagnostics"] = true }
            guard milliseconds>0,let bytes=try? JSONSerialization.data(withJSONObject:config) else{return nil}
            return source.replacingOccurrences(of:"__GROQ_OWNED_SYNTHETIC_CONFIG__",with:String(decoding:bytes,as:UTF8.self))
        }
    }
    func createGroqStatusTab(url:URL,lease:GroqOwnedStatusLease) throws -> UUID {
        let id=try createModelTab(initialURL:nil)
        do {
            if let entry=entries[id],entry.isModelOwned,!entry.isToolOwned,entry.view.url==nil,entry.modelChanges==nil,
               let probe=GroqStatusProbe(lease:lease,url:url),lease.isCurrent {
                entry.groqStatus=probe
            } else {lease.revoke()}
            try navigate(tabID:id,to:url);return id
        } catch {closeTab(id);lease.revoke();throw error}
    }
    private func removeGroqStatus(_ entry:Entry, preserveFixtureFailureScope:Bool=false) {
        guard let probe=entry.groqStatus else{return}
        entry.groqStatus=nil
        if entry.view.url==probe.url && (probe.generation==nil || entry.tab.documentGeneration==probe.generation) {
            entry.view.callAsyncJavaScript("if(document.URL===url)window[key]?.(secret,'dispose'); return null",
                arguments:["url":probe.url.absoluteString,"key":"__computaGroqStatus_"+probe.key,"secret":probe.secret],in:nil,in:.page,completionHandler:nil)
        }
        // Failed observer setup grants nothing. A fixture-only native scope can
        // still report not-armed at the original failure, under native joins.
        if !preserveFixtureFailureScope || !probe.lease.isFixture { probe.lease.revoke() }
    }
    private func groqStatusCurrent(_ entry:Entry,_ probe:GroqStatusProbe,view:WKWebView,owner:String,generation:UUID)->Bool {
        !isShutdown && !Task.isCancelled && entries[entry.tab.id]===entry && entry.groqStatus===probe && probe.initialStart
        && entry.view===view && entry.isModelOwned && !entry.isToolOwned && view.url==probe.url && entry.tab.documentGeneration==generation
        && entry.modelChanges?.ownerToken==owner && entry.modelSignalOriginHost=="chat.groq.com"
    }
    func prepareGroqStatus(_ id:UUID, view:WKWebView, owner:String, generation:UUID, outbound:String, fingerprint:String,
                           lease: GroqOwnedStatusLease) async {
        guard let e=entries[id],let p=e.groqStatus,p.lease.isCurrent,p.owner==nil,
              groqStatusCurrent(e,p,view:view,owner:owner,generation:generation) else {
            var reason: GroqOwnedStatusLease.SetupReason = .nativePrepareGuardSkipped
            // Failed-guard diagnostics read only this exact current owned view;
            // probe flags additionally require the same native fixture lease.
            if lease.isFixture, !isShutdown, !Task.isCancelled, lease.isCurrent, let entry=entries[id],
               entry.view===view, entry.isModelOwned, !entry.isToolOwned, entry.tab.documentGeneration==generation {
                if let probe=entry.groqStatus, probe.lease===lease {
                    if !probe.initialStart { reason = .nativeInitialStartMissing }
                    else if probe.owner != nil { reason = .nativeOwnerAlreadySet }
                    else if entry.modelChanges?.ownerToken != owner { reason = .nativeSignalOwnerMismatch }
                    else if entry.modelSignalOriginHost != "chat.groq.com" { reason = .nativeSignalOriginMismatch }
                } else if entry.groqStatus == nil { reason = .nativeProbeAbsent }
            }
            lease.recordSetupReason(reason); return
        }
        p.owner=owner;p.generation=generation;p.fingerprint=fingerprint
        let result=await callGroqStatus(p,view:view,command:"arm",args:["model":p.lease.modelChoice.key,"label":p.lease.modelChoice.label,"prompt":outbound])
        guard p.lease.isCurrent,groqStatusCurrent(e,p,view:view,owner:owner,generation:generation) else {
            lease.recordSetupReason(.postAwaitContextRetired)
            removeGroqStatus(e,preserveFixtureFailureScope:true); return
        }
        guard case .returned("ready") = result else {
            let reason: GroqOwnedStatusLease.SetupReason
            switch result {
            case .returned(let value): reason = .javaScriptArmReason(value) ?? .armFalse
            case .javascriptException: reason = .armException
            case .timedOut: reason = .armTimeout
            case .unavailable: reason = .armFalse
            }
            lease.recordSetupReason(reason)
            removeGroqStatus(e,preserveFixtureFailureScope:true); return
        }
        p.armed=true;p.lease.recordObserverArmed()
    }
    func groqStatusResult(_ id:UUID,view:WKWebView,owner:String,generation:UUID,fingerprint:String) async -> String? {
        guard let e=entries[id],let p=e.groqStatus,p.lease.isCurrent,p.armed,p.owner==owner,p.generation==generation,p.fingerprint==fingerprint,
              groqStatusCurrent(e,p,view:view,owner:owner,generation:generation) else{return nil}
        p.armed=false
        let result=await callGroqStatus(p,view:view,command:"finish",args:[:])
        guard p.lease.isCurrent,groqStatusCurrent(e,p,view:view,owner:owner,generation:generation) else{return nil}
        guard case .returned(let value) = result, GroqOwnedStatusLease.stages.contains(value) else { return nil }
        return value
    }
    private enum GroqStatusCallOutcome {
        case returned(String), javascriptException, timedOut, unavailable
    }
    private enum GroqStatusCallFailure: Error { case javascriptException, timedOut, invalidReturn }
    private func callGroqStatus(_ probe:GroqStatusProbe,view:WKWebView,command:String,args:[String:Any]) async -> GroqStatusCallOutcome {
        let installation: String
        if command == "arm" {
            guard let source = probe.installationSource() else { return .unavailable }
            installation = source + ";\n"
        } else { installation = "" }
        let result=EmbeddedScriptResult(),deadline=min(probe.lease.deadline,ContinuousClock.now + .milliseconds(500))
        do {
            let bytes: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    result.install(continuation)
                    result.setTimeout(Task { do { try await Task.sleep(until:deadline) } catch{return};result.complete(.failure(GroqStatusCallFailure.timedOut)) })
                    guard !Task.isCancelled,ContinuousClock.now<deadline else{result.complete(.failure(CancellationError()));return}
                    view.callAsyncJavaScript("""
                        if(document.URL!==url)return command==='arm'?'js_route_unavailable':null;
                        \(installation)
                        if(typeof window[key]!=='function')return command==='arm'?'controller_absent':null;
                        const r=window[key](secret,command,args);
                        return r===true?'ready':typeof r==='string'&&r.length<=42?r:command==='arm'?'arm_false':null;
                        """,arguments:["url":probe.url.absoluteString,"key":"__computaGroqStatus_"+probe.key,"secret":probe.secret,"command":command,"args":args],
                        in:nil,in:.page){ reply in
                            switch reply {
                            case .success(let value):
                                if let string=value as? String,string.utf8.count<=42 {result.complete(.success(Data(string.utf8)))}
                                else {result.complete(.failure(GroqStatusCallFailure.invalidReturn))}
                            case .failure: result.complete(.failure(GroqStatusCallFailure.javascriptException))
                            }
                        }
                }
            } onCancel: { result.complete(.failure(CancellationError())) }
            guard ContinuousClock.now<deadline else { return .timedOut }
            return .returned(String(decoding:bytes,as:UTF8.self))
        } catch GroqStatusCallFailure.timedOut { return .timedOut }
        catch GroqStatusCallFailure.javascriptException { return .javascriptException }
        catch { return .unavailable }
    }

    @MainActor private final class QwenMarkerProbe {
        let lease: QwenMarkerWireLease
        let key = "__computaQwenMarker_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let secret = UUID().uuidString
        let script: WKUserScript
        var initialStart = false
        var initialPreparation = false
        var canonical: String?
        var reachedProvisional = false
        var generation: UUID?
        var prepareResult: String?
        var expiry: Task<Void, Never>?

        init?(lease: QwenMarkerWireLease, label: String) {
            self.lease = lease
            let duration = min(60_000, lease.remainingMilliseconds)
            let config: [String: Any] = ["origin":"https://chat.qwen.ai", "key":key, "secret":secret, "visibleModel":label,
                "expiresAt":Date().timeIntervalSince1970 * 1_000 + Double(duration)]
            guard duration > 0, let source = EmbeddedBrowserSession.rendererDiagnosticSource(named: "qwen-marker-wire"),
                  source.components(separatedBy: "__COMPUTA_QWEN_MARKER_CONFIG__").count == 2,
                  let json = try? JSONSerialization.data(withJSONObject: config) else { return nil }
            script = .init(source: source.replacingOccurrences(of: "__COMPUTA_QWEN_MARKER_CONFIG__", with: String(decoding: json, as: UTF8.self)),
                           injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        }
        func allows(_ url: URL) -> Bool {
            let raw = url.absoluteString
            if let canonical { return raw == canonical }
            if raw == "https://chat.qwen.ai/" { return !reachedProvisional }
            guard generation != nil else { return false }
            if raw == "https://chat.qwen.ai/c/new-chat" { reachedProvisional = true; return true }
            guard let id = UUID(uuidString: url.lastPathComponent), raw == "https://chat.qwen.ai/c/" + id.uuidString.lowercased() else { return false }
            canonical = raw
            return true
        }
    }

    private func installQwenCodePayload(tabID: UUID) throws {
        guard let entry = entries[tabID], entry.isModelOwned, !entry.isToolOwned,
              entry.view.url == nil, entry.qwenCodePayloadChannel == nil,
              let source = Self.rendererDiagnosticSource(named:"qwen-code-payload"),
              let rawSource = Self.rendererDiagnosticSource(named:"qwen-authored-source"),
              [source,rawSource].allSatisfy({ $0.components(separatedBy: "__COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__").count == 2 }) else { throw Failure.tabClosed }
        let channel = ["dispatch": UUID().uuidString.lowercased(), "result": UUID().uuidString.lowercased(),
                       "secret": UUID().uuidString.lowercased()]
        let bytes = try JSONSerialization.data(withJSONObject: channel)
        for template in [source,rawSource] {
            let script = WKUserScript(source: template.replacingOccurrences(of: "__COMPUTA_QWEN_CODE_PAYLOAD_CONFIG__",
                with: String(decoding: bytes, as: UTF8.self)), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
            entry.view.configuration.userContentController.addUserScript(script)
        }
        entry.qwenCodePayloadChannel = channel
    }

    func qwenCodePayloadChannel(tabID: UUID, view: WKWebView, owner: String, generation: UUID) -> [String: String]? {
        guard let entry = entries[tabID], entry.isModelOwned, !entry.isToolOwned, entry.view === view,
              entry.modelChanges?.ownerToken == owner, entry.modelSignalOriginHost == "chat.qwen.ai",
              entry.tab.documentGeneration == generation, view.url?.host == "chat.qwen.ai" else { return nil }
        return entry.qwenCodePayloadChannel
    }

    func createQwenMarkerTab(url: URL, label: String, lease: QwenMarkerWireLease) throws -> UUID {
        let id = try createModelTab(initialURL: nil)
        do { try installQwenCodePayload(tabID:id) } catch { closeTab(id); lease.revoke(); throw error }
        do {
            if url.absoluteString == "https://chat.qwen.ai/", let entry = entries[id], entry.isModelOwned, !entry.isToolOwned,
               entry.view.url == nil, !entry.view.isLoading, entry.modelChanges == nil,
               let probe = QwenMarkerProbe(lease: lease, label: label), lease.claim(view: ObjectIdentifier(entry.view)) {
                entry.qwenMarkerProbe = probe
                entry.view.configuration.userContentController.addUserScript(probe.script)
                probe.expiry = Task { @MainActor [weak self, weak probe] in
                    guard let probe else { return }
                    do { try await Task.sleep(for: .milliseconds(min(60_000, lease.remainingMilliseconds))) } catch { return }
                    if let self, let current = self.entries[id], current.qwenMarkerProbe === probe { self.removeQwenMarker(current) }
                }
            } else { lease.revoke() }
            try navigate(tabID: id, to: url)
            return id
        } catch { closeTab(id); lease.revoke(); throw error }
    }

    private func removeQwenMarker(_ entry: Entry, preserveStagedLease: Bool = false) {
        guard let probe = entry.qwenMarkerProbe else { return }
        entry.qwenMarkerProbe = nil
        probe.expiry?.cancel()
        let controller = entry.view.configuration.userContentController
        if controller.userScripts.contains(where: { $0 === probe.script }) {
            let surviving = controller.userScripts.filter { $0 !== probe.script }
            controller.removeAllUserScripts(); surviving.forEach(controller.addUserScript)
        }
        if let url = entry.view.url, url.scheme == "https", url.host == "chat.qwen.ai", url.port == nil,
           url.user == nil, url.password == nil, probe.generation == nil || probe.generation == entry.tab.documentGeneration {
            entry.view.callAsyncJavaScript("if (location.origin===origin && document.URL===url) { try { window[key]?.(secret,'retire',null) } catch {} } return null",
                arguments: ["origin":"https://chat.qwen.ai","url":url.absoluteString,"key":probe.key,"secret":probe.secret],
                in:nil, in:.page, completionHandler:nil)
        }
        if !preserveStagedLease { probe.lease.revoke() }
    }

    private func qwenMarkerCurrent(_ entry: Entry, _ probe: QwenMarkerProbe, view: WKWebView, owner: String, generation: UUID) -> Bool {
        !isShutdown && !Task.isCancelled && entries[entry.tab.id] === entry && entry.qwenMarkerProbe === probe
            && entry.isModelOwned && !entry.isToolOwned && entry.view === view && entry.modelChanges?.ownerToken == owner
            && entry.modelSignalOriginHost == "chat.qwen.ai" && entry.tab.documentGeneration == generation
            && probe.generation == generation && probe.initialStart && view.url.map(probe.allows) == true
            && probe.lease.matches(view: ObjectIdentifier(view), ownerToken: owner, generation: generation)
    }

    func prepareQwenMarker(tabID: UUID, view: WKWebView, owner: String, turn: String, label: String,
                           generation: UUID, outbound: String, fingerprint: String) async {
        guard let entry = entries[tabID], let probe = entry.qwenMarkerProbe,
              entry.isModelOwned, !entry.isToolOwned, entry.view === view, entry.modelChanges?.ownerToken == owner,
              entry.modelSignalOriginHost == "chat.qwen.ai", entry.tab.documentGeneration == generation,
              view.url?.absoluteString == "https://chat.qwen.ai/", probe.initialStart, probe.generation == nil,
              probe.lease.bind(view: ObjectIdentifier(view), ownerToken: owner, generation: generation, outboundFingerprint: fingerprint)
        else { return }
        probe.generation = generation
        guard qwenMarkerCurrent(entry, probe, view:view, owner:owner, generation:generation) else { removeQwenMarker(entry); return }
        let tag = await callQwenMarker(probe, view:view, command:"prepare", packet:["turn":turn,"generation":generation.uuidString.lowercased(),
            "visibleModel":label,"pickerVerified":true,"prompt":outbound])
        guard qwenMarkerCurrent(entry, probe, view:view, owner:owner, generation:generation),
              view.url?.absoluteString == "https://chat.qwen.ai/" else { return }
        if let tag, ["ready","catalog_not_seen","catalog_pending","catalog_path_unverified","catalog_missing","catalog_ambiguous",
            "catalog_binding","catalog_binding_scope","catalog_open_changed","catalog_send_changed","catalog_held_changed",
            "catalog_send_unobserved","catalog_not_done","catalog_final_url","catalog_non_200","catalog_response_type",
            "catalog_size","catalog_request","catalog_response","catalog_reused","catalog_accessor","catalog_mime","catalog_shape","stream_unavailable"].contains(tag) {
            probe.prepareResult = tag
        }
    }

    func finishQwenMarker(tabID: UUID, view: WKWebView, owner: String, generation: UUID, packet: [String: Any]) async -> String? {
        guard let entry = entries[tabID], let probe = entry.qwenMarkerProbe,
              qwenMarkerCurrent(entry, probe, view:view, owner:owner, generation:generation),
              let canonical = probe.canonical, canonical == view.url?.absoluteString, let prepared = probe.prepareResult else { return nil }
        let tag: String?
        if prepared == "ready" { tag = await callQwenMarker(probe, view:view, command:"finish", packet:packet) }
        else { tag = prepared }
        guard qwenMarkerCurrent(entry, probe, view:view, owner:owner, generation:generation),
              view.url?.absoluteString == canonical else { return nil }
        removeQwenMarker(entry, preserveStagedLease:true)
        return tag
    }

    private func callQwenMarker(_ probe: QwenMarkerProbe, view: WKWebView, command: String, packet: [String: Any]) async -> String? {
        guard let url = view.url?.absoluteString, probe.lease.isCurrent else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(min(750, probe.lease.remainingMilliseconds))
        let result = EmbeddedScriptResult()
        let bytes: Data? = try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                result.setTimeout(Task {
                    do { try await Task.sleep(until: deadline) } catch { return }
                    result.complete(.failure(Failure.tabClosed))
                })
                guard result.isPending, !Task.isCancelled, ContinuousClock.now < deadline else {
                    result.complete(.failure(CancellationError())); return
                }
                view.callAsyncJavaScript("""
                    if(document.URL!==url || typeof window[key]!=='function')return null;
                    const r=window[key](secret,command,packet);
                    return r && Object.keys(r).length===1 && typeof r.stage==='string' && r.stage.length<=48 ? r.stage : null;
                    """, arguments:["url":url,"key":probe.key,"secret":probe.secret,"command":command,"packet":packet], in:nil, in:.page) { reply in
                    if case .success(let value) = reply, let tag = value as? String, tag.utf8.count <= 48 {
                        result.complete(.success(Data(tag.utf8)))
                    } else { result.complete(.failure(Failure.tabClosed)) }
                }
            }
        } onCancel: { result.complete(.failure(CancellationError())) }
        return ContinuousClock.now < deadline ? bytes.map { String(decoding:$0,as:UTF8.self) } : nil
    }

    private final class ClaudeResponseStreamDiagnosticState {
        let authorization: ClaudeResponseStreamLease
        let key: String
        let script: WKUserScript
        var initialNavigationPrepared = false
        var initialNavigationStarted = false
        var generation: UUID?
        var conversationURL: String?
        var expiry: Task<Void, Never>?
        init(authorization: ClaudeResponseStreamLease, key: String, script: WKUserScript) {
            self.authorization = authorization; self.key = key; self.script = script
        }
    }

    func createModelTab(url: URL, claudeResponseStream authorization: ClaudeResponseStreamLease) throws -> UUID {
        let id = try createModelTab(initialURL: nil)
        do {
            if Self.claudeResponseStreamFreshURL(url) { _ = installClaudeResponseStream(authorization, tabID: id) }
            else { authorization.revoke() }
            // A failed diagnostic cannot fail or replay the ordinary navigation.
            try navigate(tabID: id, to: url)
            return id
        } catch { closeTab(id); authorization.revoke(); throw error }
    }

    @discardableResult
    func installClaudeResponseStream(_ authorization: ClaudeResponseStreamLease, tabID: UUID) -> Bool {
        guard !isShutdown, !Task.isCancelled, let entry = entries[tabID], entry.isModelOwned, !entry.isToolOwned,
              entry.claudeResponseStreamDiagnostic == nil, entry.claudeResponseStreamLease == nil,
              entry.view.url == nil, !entry.view.isLoading,
              entry.modelChanges == nil, authorization.isCurrent,
              authorization.claim(view: ObjectIdentifier(entry.view)) else { authorization.revoke(); return false }
        let duration = min(60_000, authorization.remainingMilliseconds)
        let key = "__computaClaudeResponseStream_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        guard duration > 0, let source = Self.claudeResponseStreamSource(),
              let config = try? JSONSerialization.data(withJSONObject: ["key": key, "durationMs": duration]),
              let text = String(data: config, encoding: .utf8) else { authorization.revoke(); return false }
        let script = WKUserScript(source: source.replacingOccurrences(of: "__COMPUTA_CLAUDE_RESPONSE_STREAM_CONFIG__", with: text),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        let diagnostic = ClaudeResponseStreamDiagnosticState(authorization: authorization, key: key, script: script)
        entry.claudeResponseStreamDiagnostic = diagnostic
        entry.claudeResponseStreamLease = authorization
        entry.view.configuration.userContentController.addUserScript(script)
        diagnostic.expiry = Task { @MainActor [weak self, weak diagnostic] in
            do { try await Task.sleep(for: .milliseconds(duration)) } catch { return }
            guard let self, let diagnostic, let current = self.entries[tabID],
                  current.claudeResponseStreamDiagnostic === diagnostic else { return }
            self.revokeClaudeResponseStream(current)
        }
        return true
    }

    func armClaudeResponseStream(tabID: UUID, view: WKWebView, ownerToken: String, expectedPrompt: String) async -> Bool {
        guard !Task.isCancelled, !isShutdown, let entry = entries[tabID], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.modelChanges?.ownerToken == ownerToken,
              entry.modelSignalOriginHost == "claude.ai", Self.claudeResponseStreamFreshURL(view.url),
              let diagnostic = entry.claudeResponseStreamDiagnostic, diagnostic.generation == nil,
              diagnostic.initialNavigationStarted, diagnostic.authorization.isCurrent,
              !expectedPrompt.isEmpty, expectedPrompt.utf16.count <= 131_072 else { return false }
        let generation = entry.tab.documentGeneration
        guard diagnostic.authorization.bind(view: ObjectIdentifier(view), ownerToken: ownerToken, generation: generation) else { return false }
        diagnostic.generation = generation
        let bytes = await callClaudeResponseStream(command: "arm", entry: entry, diagnostic: diagnostic,
                                                  arguments: ["expectedPrompt": expectedPrompt,
                                                              "expectedMarker": diagnostic.authorization.expectedMarker])
        guard claudeResponseStreamCurrent(entry, diagnostic: diagnostic, view: view, ownerToken: ownerToken, generation: generation),
              bytes == Data("true".utf8) else {
            if entries[tabID] === entry, entry.claudeResponseStreamDiagnostic === diagnostic { revokeClaudeResponseStream(entry) }
            return false
        }
        return true
    }

    func stopClaudeResponseStream(tabID: UUID, view: WKWebView, ownerToken: String) async -> ClaudeResponseStreamSnapshot? {
        guard !isShutdown, let entry = entries[tabID], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.modelChanges?.ownerToken == ownerToken,
              entry.modelSignalOriginHost == "claude.ai", let diagnostic = entry.claudeResponseStreamDiagnostic else { return nil }
        // Removal is unconditional for this exact caller, even if no arm or
        // snapshot succeeded. Persistence belongs to transport before revoke.
        defer { removeClaudeResponseStream(entry, diagnostic: diagnostic) }
        guard let generation = diagnostic.generation,
              claudeResponseStreamCurrent(entry, diagnostic: diagnostic, view: view, ownerToken: ownerToken, generation: generation) else { return nil }
        let bytes = await callClaudeResponseStream(command: "stop", entry: entry, diagnostic: diagnostic)
        guard claudeResponseStreamCurrent(entry, diagnostic: diagnostic, view: view, ownerToken: ownerToken, generation: generation),
              let bytes else { return nil }
        return try? ClaudeResponseStreamSnapshot.parse(bytes)
    }

    func revokeClaudeResponseStream(tabID: UUID, ownerToken: String) {
        guard let entry = entries[tabID], entry.modelChanges?.ownerToken == ownerToken else { return }
        revokeClaudeResponseStream(entry)
    }

    private func claudeResponseStreamCurrent(_ entry: Entry, diagnostic: ClaudeResponseStreamDiagnosticState,
                                            view: WKWebView, ownerToken: String, generation: UUID) -> Bool {
        !Task.isCancelled && !isShutdown && entries[entry.tab.id] === entry && entry.view === view
            && entry.claudeResponseStreamDiagnostic === diagnostic && diagnostic.generation == generation
            && entry.tab.documentGeneration == generation && entry.modelChanges?.ownerToken == ownerToken
            && entry.modelSignalOriginHost == "claude.ai"
            && diagnostic.authorization.matches(view: ObjectIdentifier(view), ownerToken: ownerToken, generation: generation)
            && claudeResponseStreamRouteCurrent(entry, diagnostic: diagnostic)
    }

    private static func claudeResponseStreamFreshURL(_ url: URL?) -> Bool {
        ["https://claude.ai/new", "https://claude.ai/new?incognito"].contains(url?.absoluteString ?? "")
    }

    private func claudeResponseStreamRouteCurrent(_ entry: Entry, diagnostic: ClaudeResponseStreamDiagnosticState) -> Bool {
        guard let url = entry.view.url, url.scheme == "https", url.host == "claude.ai",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil else { return false }
        if let pinned = diagnostic.conversationURL { return url.absoluteString == pinned }
        if Self.claudeResponseStreamFreshURL(url) { return true }
        guard diagnostic.generation != nil, url.query == nil, url.path.hasPrefix("/chat/"),
              let id = UUID(uuidString: String(url.path.dropFirst(6))),
              url.absoluteString == "https://claude.ai/chat/" + id.uuidString.lowercased() else { return false }
        diagnostic.conversationURL = url.absoluteString
        return true
    }

    private func callClaudeResponseStream(command: String, entry: Entry, diagnostic: ClaudeResponseStreamDiagnosticState,
                                          arguments: [String: Any] = [:]) async -> Data? {
        guard let expectedURL = entry.view.url?.absoluteString, diagnostic.authorization.isCurrent else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(min(1_000, diagnostic.authorization.remainingMilliseconds))
        let result = EmbeddedScriptResult()
        let bytes: Data? = try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                let timeout = Task {
                    do { try await Task.sleep(until: deadline) } catch { return }
                    result.complete(.failure(Failure.tabClosed))
                }
                result.setTimeout(timeout)
                guard result.isPending, !Task.isCancelled, ContinuousClock.now < deadline else {
                    result.complete(.failure(CancellationError())); return
                }
                var values = arguments
                values["key"] = diagnostic.key; values["command"] = command; values["expectedURL"] = expectedURL
                values["expectedPrompt"] = values["expectedPrompt"] ?? NSNull()
                values["expectedMarker"] = values["expectedMarker"] ?? NSNull()
                entry.view.callAsyncJavaScript("""
                    if (document.URL !== expectedURL || typeof window[key] !== 'function') return null;
                    try {
                      const value = await window[key](command, expectedPrompt, expectedMarker);
                      const text = JSON.stringify(value);
                      return typeof text === 'string' && text.length <= 81920 ? text : null;
                    } catch { return null; }
                    """, arguments: values, in: nil, in: .page) { reply in
                    switch reply {
                    case .success(let value):
                        if let text = value as? String, text.utf8.count <= ClaudeResponseStreamSnapshot.maximumEncodedBytes {
                            result.complete(.success(Data(text.utf8)))
                        } else { result.complete(.failure(Failure.tabClosed)) }
                    case .failure: result.complete(.failure(Failure.tabClosed))
                    }
                }
            }
        } onCancel: { result.complete(.failure(CancellationError())) }
        return ContinuousClock.now < deadline ? bytes : nil
    }

    private func removeClaudeResponseStream(_ entry: Entry, diagnostic: ClaudeResponseStreamDiagnosticState) {
        guard entry.claudeResponseStreamDiagnostic === diagnostic else { return }
        entry.claudeResponseStreamDiagnostic = nil; diagnostic.expiry?.cancel()
        let controller = entry.view.configuration.userContentController
        let surviving = controller.userScripts.filter { $0 !== diagnostic.script }
        controller.removeAllUserScripts(); surviving.forEach(controller.addUserScript)
        // No snapshot or authority is retained by this best-effort disposal.
        entry.view.callAsyncJavaScript("""
            if (typeof window[key] === 'function') { try { window[key]('stop'); } catch {} }
            try { delete window[key]; } catch {} return null;
            """, arguments: ["key": diagnostic.key], in: nil, in: .page, completionHandler: nil)
    }

    private func revokeClaudeResponseStream(_ entry: Entry) {
        if let diagnostic = entry.claudeResponseStreamDiagnostic { removeClaudeResponseStream(entry, diagnostic: diagnostic) }
        entry.claudeResponseStreamLease?.revoke()
        entry.claudeResponseStreamLease = nil
    }

    private static func claudeResponseStreamSource() -> String? {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: "claude-response-stream-diagnostic", withExtension: "js", subdirectory: "BrowserModels"),
               let source = try? String(contentsOf: url, encoding: .utf8),
               source.components(separatedBy: "__COMPUTA_CLAUDE_RESPONSE_STREAM_CONFIG__").count == 2 { return source }
        }
        return nil
    }

    private final class RequestMetadataDiagnostic {
        let authorization: ChatGPTRequestMetadataLease
        let key: String
        let script: WKUserScript
        var generation: UUID?
        var expiry: Task<Void, Never>?
        init(authorization: ChatGPTRequestMetadataLease, key: String, script: WKUserScript) {
            self.authorization = authorization; self.key = key; self.script = script
        }
    }

    /// Only an explicitly armed native start takes this path. Ordinary model,
    /// discovery, human and tool views receive no page-world fetch observer.
    func createModelTab(url: URL, requestMetadata authorization: ChatGPTRequestMetadataLease) throws -> UUID {
        let id = try createModelTab(initialURL: nil)
        do {
            // A missing/expired diagnostic cannot fail or replay the original
            // inference. This is still its one newly created view/navigation.
            if Self.inspectorOriginAllowed(url) { _ = installModelRequestMetadata(authorization, tabID: id) }
            else { authorization.revoke() }
            try navigate(tabID: id, to: url)
            return id
        } catch {
            closeTab(id); authorization.revoke(); throw error
        }
    }

    @discardableResult
    func installModelRequestMetadata(_ authorization: ChatGPTRequestMetadataLease, tabID: UUID) -> Bool {
        guard !isShutdown, !Task.isCancelled, let entry = entries[tabID], entry.isModelOwned, !entry.isToolOwned,
              entry.requestMetadataDiagnostic == nil, entry.view.url == nil, !entry.view.isLoading,
              authorization.isCurrent, authorization.claim(view: ObjectIdentifier(entry.view)) else {
            authorization.revoke(); return false
        }
        let key = "__computaRequestMetadata_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let duration = authorization.remainingMilliseconds
        var configuration: [String: Any] = ["key": key, "durationMs": duration]
        if authorization.capturesDecodedEvents {
            installResponseCompletionObserver(entry, allowsDiagnostics: true)
            guard let completion = entry.responseCompletionObserver else { authorization.revoke(); return false }
            configuration["captureDecodedEvents"] = true
            configuration["completionKey"] = completion.key
        }
        guard duration > 0, let source = Self.requestMetadataSource(),
              let config = try? JSONSerialization.data(withJSONObject: configuration),
              let configText = String(data: config, encoding: .utf8) else { authorization.revoke(); return false }
        let script = WKUserScript(source: source.replacingOccurrences(of: "__COMPUTA_REQUEST_METADATA_CONFIG__", with: configText),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        let diagnostic = RequestMetadataDiagnostic(authorization: authorization, key: key, script: script)
        entry.hadChatRootDiagnostic = true
        entry.requestMetadataDiagnostic = diagnostic
        entry.view.configuration.userContentController.addUserScript(script)
        diagnostic.expiry = Task { @MainActor [weak self, weak diagnostic] in
            do { try await Task.sleep(for: .milliseconds(duration)) } catch { return }
            guard let self, let diagnostic, let current = self.entries[tabID],
                  current.requestMetadataDiagnostic === diagnostic else { return }
            self.revokeRequestMetadata(current)
        }
        return true
    }

    func modelRequestMetadata(command: String, tabID: UUID, view: WKWebView, ownerToken: String) async -> ChatGPTRequestMetadataSnapshot? {
        guard ["activate", "snapshot", "stop"].contains(command), !Task.isCancelled, !isShutdown,
              let entry = entries[tabID], entry.view === view, entry.isModelOwned, !entry.isToolOwned,
              entry.modelChanges?.ownerToken == ownerToken, entry.modelSignalOriginHost == "chatgpt.com",
              Self.inspectorOriginAllowed(view.url), let expectedURL = view.url?.absoluteString,
              let diagnostic = entry.requestMetadataDiagnostic,
              diagnostic.authorization.isCurrent else { return nil }
        let generation = entry.tab.documentGeneration
        if command == "activate" {
            guard diagnostic.generation == nil else { return nil }
            diagnostic.generation = generation
        } else { guard diagnostic.generation == generation else { return nil } }
        // Both read-only observations share the existing diagnostic budget.
        // Activation does not inspect cookies; an optional cookie-store timeout
        // yields unknown without discarding a valid page observation.
        let deadline = ContinuousClock.now + .milliseconds(min(1_000, diagnostic.authorization.remainingMilliseconds))
        async let cookieBytes: Data? = command == "activate" ? Data() : requestProfileCookieBudget(
            store: view.configuration.websiteDataStore.httpCookieStore, deadline: deadline)
        let result = EmbeddedScriptResult()
        let bytes: Data? = try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                let timeout = Task {
                    do { try await Task.sleep(until: deadline) }
                    catch { return }
                    result.complete(.failure(Failure.tabClosed))
                }
                result.setTimeout(timeout)
                guard result.isPending, !Task.isCancelled else { return }
                view.callAsyncJavaScript("""
                    if (document.URL !== expectedURL || typeof window[key] !== 'function') return null;
                    try {
                      const snapshot = await window[key](command);
                      const text = JSON.stringify(snapshot);
                      return typeof text === 'string' && text.length <= 8192 ? text : null;
                    } catch { return null; }
                    """, arguments: ["key": diagnostic.key, "command": command, "expectedURL": expectedURL], in: nil, in: .page) { reply in
                    switch reply {
                    case .success(let value):
                        if let text = value as? String, text.utf8.count <= 8_192 {
                            let data = Data(text.utf8)
                            result.complete(.success(data))
                        } else { result.complete(.failure(Failure.tabClosed)) }
                    case .failure: result.complete(.failure(Failure.tabClosed))
                    }
                }
            }
        } onCancel: { result.complete(.failure(CancellationError())) }
        let nativeCookieBytes = await cookieBytes
        guard !Task.isCancelled, ContinuousClock.now < deadline, entries[tabID] === entry, entry.view === view,
              entry.requestMetadataDiagnostic === diagnostic, diagnostic.authorization.isCurrent,
              entry.tab.documentGeneration == generation, diagnostic.generation == generation,
              entry.modelChanges?.ownerToken == ownerToken, Self.inspectorOriginAllowed(view.url),
              view.url?.absoluteString == expectedURL,
              let bytes, let snapshot = try? ChatGPTRequestMetadataSnapshot.parse(bytes),
              snapshot.schemaVersion == (diagnostic.authorization.capturesDecodedEvents ? 2 : 1) else { return nil }
        let cookieBudget = nativeCookieBytes.flatMap { try? JSONDecoder().decode(ChatGPTProfileCookieBudget.self, from: $0) }
        if command == "stop" { removeRequestMetadata(entry, diagnostic: diagnostic) }
        return snapshot.attachingProfileCookieBudget(cookieBudget)
    }

    /// WKHTTPCookieStore offers a completion callback, not cancellation. Only a
    /// bounded, secret-free aggregate crosses this callback; the one-shot result
    /// ignores late completions after timeout/cancellation. Empty bytes mean a
    /// completed read whose profile exceeded aggregation bounds (unknown).
    private func requestProfileCookieBudget(store: WKHTTPCookieStore, deadline: ContinuousClock.Instant) async -> Data? {
        let result = EmbeddedScriptResult()
        return try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                let timeout = Task {
                    do { try await Task.sleep(until: deadline) } catch { return }
                    result.complete(.failure(Failure.tabClosed))
                }
                result.setTimeout(timeout)
                guard result.isPending, !Task.isCancelled, ContinuousClock.now < deadline else {
                    result.complete(.failure(CancellationError())); return
                }
                store.getAllCookies { cookies in
                    guard result.isPending else { return }
                    guard ContinuousClock.now < deadline else {
                        result.complete(.failure(Failure.tabClosed)); return
                    }
                    let budget = ChatGPTProfileCookieBudget.estimate(cookies: cookies)
                    let bytes = budget.flatMap { try? JSONEncoder().encode($0) } ?? Data()
                    guard result.isPending, ContinuousClock.now < deadline else {
                        result.complete(.failure(Failure.tabClosed)); return
                    }
                    result.complete(.success(bytes))
                }
            }
        } onCancel: { result.complete(.failure(CancellationError())) }
    }

    func revokeModelRequestMetadata(tabID: UUID, ownerToken: String) {
        guard let entry = entries[tabID], entry.modelChanges?.ownerToken == ownerToken else { return }
        revokeRequestMetadata(entry)
    }

    private func removeRequestMetadata(_ entry: Entry, diagnostic: RequestMetadataDiagnostic) {
        guard entry.requestMetadataDiagnostic === diagnostic else { return }
        entry.requestMetadataDiagnostic = nil
        diagnostic.expiry?.cancel()
        let controller = entry.view.configuration.userContentController
        let surviving = controller.userScripts.filter { $0 !== diagnostic.script }
        controller.removeAllUserScripts()
        surviving.forEach(controller.addUserScript)
    }

    private func revokeRequestMetadata(_ entry: Entry) {
        guard let diagnostic = entry.requestMetadataDiagnostic else { return }
        removeRequestMetadata(entry, diagnostic: diagnostic)
        diagnostic.authorization.revoke()
        // Stop is best effort only. It returns no data, waits for nothing and
        // cannot keep an inference or cleanup alive after the native deadline.
        if let expectedURL = entry.view.url?.absoluteString {
            entry.view.callAsyncJavaScript("if (document.URL === expectedURL && typeof window[key] === 'function') window[key]('stop'); return null;",
                arguments: ["key": diagnostic.key, "expectedURL": expectedURL], in: nil, in: .page, completionHandler: nil)
        }
    }

    private static func requestMetadataSource() -> String? {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: "chatgpt-request-metadata", withExtension: "js", subdirectory: "BrowserModels"),
               let source = try? String(contentsOf: url, encoding: .utf8),
               source.components(separatedBy: "__COMPUTA_REQUEST_METADATA_CONFIG__").count == 2 { return source }
        }
        return nil
    }

    static let responseCompletionName = "computaChatGPTCompletion"

    private static func responseCompletionURLAllowed(_ url: URL?) -> Bool {
        guard inspectorOriginAllowed(url), let url else { return false }
        return url.path.isEmpty || url.path == "/" || ChatGPTTemporaryConversationRoutes.id(from: url) != nil
    }

    private final class ResponseCompletionObserver {
        let key: String
        let script: WKUserScript
        let allowsDiagnostics: Bool
        init(key: String, script: WKUserScript, allowsDiagnostics: Bool) {
            self.key = key; self.script = script; self.allowsDiagnostics = allowsDiagnostics
        }
    }

    /// The main-world API is inert until a native current submission arms it.
    /// Install before any model navigation, including prompt-free prewarming.
    private func installResponseCompletionObserver(_ entry: Entry, allowsDiagnostics: Bool = false) {
        let previous = entry.responseCompletionObserver
        guard entry.isModelOwned, !entry.isToolOwned,
              previous == nil || allowsDiagnostics && previous?.allowsDiagnostics == false,
              entry.view.url == nil, !entry.view.isLoading,
              let source = responseCompletionSource(), source.utf8.count <= 65_536,
              source.components(separatedBy: "__COMPUTA_COMPLETION_CONFIG__").count == 2 else { return }
        let key = previous?.key ?? "__computaCompletion_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        var configuration: [String: Any] = ["key": key, "handlerName": Self.responseCompletionName]
        if allowsDiagnostics { configuration["allowsDiagnosticSubscribers"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: configuration),
              let config = String(data: data, encoding: .utf8) else { return }
        let script = WKUserScript(source: source.replacingOccurrences(of: "__COMPUTA_COMPLETION_CONFIG__", with: config),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        let controller = entry.view.configuration.userContentController
        if let previous {
            // Materialize the replacement before mutating WebKit's script
            // collection; its bridged getter can otherwise become empty when
            // removeAllUserScripts() changes the underlying collection.
            guard controller.userScripts.filter({ $0 === previous.script }).count == 1 else { return }
            let scripts = controller.userScripts.map { $0 === previous.script ? script : $0 }
            controller.removeAllUserScripts()
            scripts.forEach(controller.addUserScript)
        } else {
            controller.add(EmbeddedResponseCompletionHandler(session: self, tabID: entry.tab.id),
                contentWorld: .page, name: Self.responseCompletionName)
            controller.addUserScript(script)
        }
        entry.responseCompletionObserver = ResponseCompletionObserver(key: key, script: script, allowsDiagnostics: allowsDiagnostics)
    }

    /// Content-free observation of one preparation attempt. It is retained after
    /// revocation so cancellation diagnostics can distinguish a silent armed
    /// observer from a missing/failed observer; it never participates in proof.
    private final class ResponseCompletionPreparation {
        enum Outcome: String {
            case preparing, armed
            case observerUnavailable = "observer_unavailable", bindingRejected = "binding_rejected"
            case expired, pageRejected = "page_rejected", evaluationFailed = "evaluation_failed"
            case timedOut = "timed_out", contextChanged = "context_changed", cancelled
        }
        enum Signal: String { case terminal, terminalFailure = "terminal_failure", invalidated }
        let owner: String
        let generation: UUID
        let sequence: Int
        var correlationID: UUID?
        var outcome: Outcome = .preparing
        var diagnostic: ChatGPTResponseCompletion.Diagnostic?
        var signal: Signal?
        init(owner: String, generation: UUID, sequence: Int) {
            self.owner = owner; self.generation = generation; self.sequence = sequence
        }
    }

    /// Does not evaluate the page or test receipt authority. Deliberately usable
    /// after task cancellation/lease expiry, but never across owners or documents.
    func chatGPTResponseObserverDiagnostic(tabID: UUID, view: WKWebView, ownerToken: String,
                                          generation: UUID, sequence: Int) -> [String: Any]? {
        guard !isShutdown, let entry = entries[tabID], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.modelChanges?.ownerToken == ownerToken,
              entry.tab.documentGeneration == generation, let record = entry.responseCompletionPreparation,
              record.owner == ownerToken, record.generation == generation, record.sequence == sequence else { return nil }
        return ["outcome": record.outcome.rawValue,
                "reason": record.diagnostic.map { $0.reason.rawValue as Any } ?? NSNull(),
                "calls": record.diagnostic.map { $0.calls as Any } ?? NSNull(),
                "instances": record.diagnostic.map { $0.instances as Any } ?? NSNull(),
                "signal": record.signal.map { $0.rawValue as Any } ?? NSNull()]
    }

    /// Arming is a bounded preparation, never a Send or a response proof. A
    /// missing/changed decoder simply leaves the ordinary completion fallback.
    func prepareChatGPTResponseCompletion(tabID: UUID, view: WKWebView, ownerToken: String, generation: UUID,
                                         sequence: Int, outboundSHA256: String, outboundUTF8Bytes: Int,
                                         deadline: ContinuousClock.Instant) async -> Bool {
        guard !isShutdown, !Task.isCancelled, let entry = entries[tabID], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.modelChanges?.ownerToken == ownerToken,
              entry.modelSignalOriginHost == "chatgpt.com", entry.tab.documentGeneration == generation,
              Self.responseCompletionURLAllowed(view.url), let expectedURL = view.url?.absoluteString else { return false }
        let preparation = ResponseCompletionPreparation(owner: ownerToken, generation: generation, sequence: sequence)
        entry.responseCompletionPreparation = preparation
        guard let observer = entry.responseCompletionObserver else { preparation.outcome = .observerUnavailable; return false }
        revokeResponseCompletion(entry)
        guard let lease = ChatGPTResponseCompletion(view: ObjectIdentifier(view), ownerToken: ownerToken,
            generation: generation, sequence: sequence, inputSHA256: outboundSHA256,
            inputUTF8Bytes: outboundUTF8Bytes, deadline: deadline) else {
            preparation.outcome = ContinuousClock.now >= deadline ? .expired : .bindingRejected
            return false
        }
        let parts = (deadline - .now).components
        let duration = Int(max(0, min(600_000, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)))
        guard duration > 0 else { preparation.outcome = .expired; return false }
        entry.responseCompletion = lease
        preparation.correlationID = lease.correlationID
        entry.responseCompletionDiagnosticLogged = false
        let evaluationDeadline = min(deadline, ContinuousClock.now + .seconds(1))
        let result = EmbeddedScriptResult()
        let reply: Data? = try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                let timeout = Task {
                    do { try await Task.sleep(until: evaluationDeadline, clock: .continuous) }
                    catch { return }
                    result.complete(.failure(Failure.tabClosed))
                }
                result.setTimeout(timeout)
                guard result.isPending, !Task.isCancelled else { return }
                view.callAsyncJavaScript("""
                    if (document.URL !== expectedURL || window !== window.top || location.origin !== 'https://chatgpt.com') return false;
                    const api = window[key];
                    if (!api || typeof api.arm !== 'function' || typeof api.stop !== 'function') return false;
                    const reply = await api.arm(arm);
                    const valid = !!reply && typeof reply === 'object' && !Array.isArray(reply)
                      && Object.keys(reply).length === 1 && reply.armed === true;
                    return valid && window[key] === api && document.URL === expectedURL && window === window.top
                      && location.origin === 'https://chatgpt.com';
                    """, arguments: ["key": observer.key, "expectedURL": expectedURL,
                        "arm": ["correlationID": lease.correlationID.uuidString.lowercased(), "sequence": sequence,
                            "inputSHA256": outboundSHA256, "inputUTF8Bytes": outboundUTF8Bytes, "durationMs": duration]],
                    in: nil, in: .page) { value in
                    switch value {
                    case .success(let value): result.complete(.success(Data([value as? Bool == true ? 1 : 0])))
                    case .failure: result.complete(.failure(Failure.tabClosed))
                    }
                }
            }
        } onCancel: { result.complete(.failure(CancellationError())) }
        let current = !isShutdown && !Task.isCancelled && ContinuousClock.now < evaluationDeadline
            && entries[tabID] === entry && entry.view === view && entry.responseCompletionObserver === observer
            && entry.responseCompletion === lease && entry.modelChanges?.ownerToken == ownerToken
            && entry.tab.documentGeneration == generation && view.url?.absoluteString == expectedURL
            && Self.responseCompletionURLAllowed(view.url)
            && lease.isCurrent(view: ObjectIdentifier(view), ownerToken: ownerToken, generation: generation, sequence: sequence)
        guard current, reply == Data([1]) else {
            preparation.outcome = Task.isCancelled ? .cancelled : ContinuousClock.now >= evaluationDeadline ? .timedOut
                : !current ? .contextChanged : reply == nil ? .evaluationFailed : .pageRejected
            if entry.responseCompletion === lease { revokeResponseCompletion(entry) }
            else { lease.revoke() }
            return false
        }
        preparation.outcome = .armed
        return true
    }

    func chatGPTResponseCompletionReceipt(tabID: UUID, view: WKWebView, ownerToken: String,
                                         generation: UUID, sequence: Int) -> ChatGPTResponseCompletion.Receipt? {
        guard !isShutdown, !Task.isCancelled, let entry = entries[tabID], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.modelChanges?.ownerToken == ownerToken,
              entry.modelSignalOriginHost == "chatgpt.com", entry.tab.documentGeneration == generation,
              Self.responseCompletionURLAllowed(view.url), let lease = entry.responseCompletion,
              let receipt = lease.receipt(view: ObjectIdentifier(view), ownerToken: ownerToken,
                generation: generation, sequence: sequence) else { return nil }
        if view.url?.path.hasPrefix("/c/local-chatgpt") != true,
           let currentConversation = ChatGPTTemporaryConversationRoutes.id(from: view.url),
           currentConversation.uuidString.lowercased() != receipt.conversationID {
            revokeResponseCompletion(entry); return nil
        }
        return receipt
    }

    func chatGPTResponseFailureReceipt(tabID: UUID, view: WKWebView, ownerToken: String,
                                      generation: UUID, sequence: Int) -> ChatGPTResponseCompletion.FailureReceipt? {
        guard !isShutdown, !Task.isCancelled, let entry = entries[tabID], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.modelChanges?.ownerToken == ownerToken,
              entry.modelSignalOriginHost == "chatgpt.com", entry.tab.documentGeneration == generation,
              Self.responseCompletionURLAllowed(view.url), let lease = entry.responseCompletion,
              let receipt = lease.failureReceipt(view: ObjectIdentifier(view), ownerToken: ownerToken,
                generation: generation, sequence: sequence) else { return nil }
        if view.url?.path.hasPrefix("/c/local-chatgpt") != true,
           let currentConversation = ChatGPTTemporaryConversationRoutes.id(from: view.url),
           currentConversation.uuidString.lowercased() != receipt.conversationID {
            revokeResponseCompletion(entry); return nil
        }
        return receipt
    }

    func revokeChatGPTResponseCompletion(tabID: UUID, ownerToken: String) {
        guard let entry = entries[tabID], entry.modelChanges?.ownerToken == ownerToken else { return }
        revokeResponseCompletion(entry)
    }

    fileprivate func receivedResponseCompletion(_ message: WKScriptMessage, tabID: UUID) {
        guard !isShutdown, let entry = entries[tabID], entry.view === message.webView,
              entry.isModelOwned, !entry.isToolOwned, message.frameInfo.isMainFrame,
              entry.modelSignalOriginHost == "chatgpt.com", Self.responseCompletionURLAllowed(entry.view.url),
              let lease = entry.responseCompletion,
              lease.view == ObjectIdentifier(entry.view), lease.ownerToken == entry.modelChanges?.ownerToken,
              lease.generation == entry.tab.documentGeneration else { return }
        let origin = message.frameInfo.securityOrigin
        guard origin.`protocol` == "https", origin.host == "chatgpt.com", origin.port == 0 || origin.port == 443 else { return }
        if let body = message.body as? [String: Any], body["kind"] as? String == "diagnostic" {
            // Diagnostic packets are never passed to the authoritative receipt
            // parser, even when malformed or foreign to the current lease.
            guard let diagnostic = lease.diagnostic(body), !entry.responseCompletionDiagnosticLogged else { return }
            entry.responseCompletionDiagnosticLogged = true
            if let record = entry.responseCompletionPreparation, record.owner == lease.ownerToken,
               record.generation == lease.generation, record.sequence == lease.sequence,
               record.correlationID == lease.correlationID {
                record.diagnostic = diagnostic
            }
            Self.inferencePrewarmLog.notice("completionObserver version=1 session=\(lease.ownerToken, privacy: .public) sequence=\(lease.sequence) reason=\(diagnostic.reason.rawValue, privacy: .public) calls=\(diagnostic.calls) instances=\(diagnostic.instances)")
            return
        }
        guard lease.isCurrent(view: ObjectIdentifier(entry.view), ownerToken: entry.modelChanges?.ownerToken ?? "",
            generation: entry.tab.documentGeneration, sequence: lease.sequence) else { return }
        if lease.receive(message.body) {
            let failure = lease.failureReceipt(view: ObjectIdentifier(entry.view), ownerToken: entry.modelChanges?.ownerToken ?? "",
                generation: entry.tab.documentGeneration, sequence: lease.sequence)
            let state = lease.invalidated ? "invalidated" : failure == nil ? "terminal" : "terminal_failure"
            if let record = entry.responseCompletionPreparation, record.owner == lease.ownerToken,
               record.generation == lease.generation, record.sequence == lease.sequence,
               record.correlationID == lease.correlationID {
                record.signal = .init(rawValue: state)
            }
            Self.inferencePrewarmLog.notice("completionSignal version=1 session=\(lease.ownerToken, privacy: .public) sequence=\(lease.sequence) state=\(state, privacy: .public)")
            if let failure {
                Self.inferencePrewarmLog.notice("completionFailure version=1 session=\(lease.ownerToken, privacy: .public) sequence=\(lease.sequence) reason=\(failure.reason.rawValue, privacy: .public) calls=\(failure.calls) assistantMessages=\(failure.assistantMessages) messageTerminalCount=\(failure.messageTerminalCount) mainTerminalCount=\(failure.mainTerminalCount)")
            }
            entry.modelChanges?.signal()
        }
    }

    private func revokeResponseCompletion(_ entry: Entry) {
        guard let lease = entry.responseCompletion else { return }
        entry.responseCompletion = nil
        lease.revoke()
        guard let observer = entry.responseCompletionObserver, let url = entry.view.url,
              Self.inspectorOriginAllowed(url) else { return }
        // Native revocation is immediate. Late page stop cannot revive a lease,
        // overwrite a newer correlation, or keep cleanup waiting.
        entry.view.callAsyncJavaScript("""
            if (document.URL === expectedURL && typeof window[key]?.stop === 'function') window[key].stop(correlationID);
            return null;
            """, arguments: ["key": observer.key, "expectedURL": url.absoluteString,
                "correlationID": lease.correlationID.uuidString.lowercased()], in: nil, in: .page, completionHandler: nil)
    }

    private func removeResponseCompletionObserver(_ entry: Entry) {
        revokeResponseCompletion(entry)
        guard let observer = entry.responseCompletionObserver else { return }
        entry.responseCompletionObserver = nil
        let controller = entry.view.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.responseCompletionName, contentWorld: .page)
        let surviving = controller.userScripts.filter { $0 !== observer.script }
        controller.removeAllUserScripts(); surviving.forEach(controller.addUserScript)
    }

    private func responseCompletionSource() -> String? {
        #if DEBUG
        if let responseCompletionSourceForTesting { return responseCompletionSourceForTesting }
        #endif
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: "chatgpt-completion", withExtension: "js", subdirectory: "BrowserModels"),
               let source = try? String(contentsOf: url, encoding: .utf8) { return source }
        }
        return nil
    }

    /// An explicit, short-lived diagnostic opt-in applies only to new isolated
    /// inference views. Installation does not consume the failure capture arm.
    static func rendererStartupDiagnosticScript(armedUntil: Any?, now: TimeInterval = Date().timeIntervalSince1970,
                                                source: () -> String?) -> WKUserScript? {
        guard let expiry = armedUntil as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue.isFinite, expiry.doubleValue > now, expiry.doubleValue <= now + 600,
              let source = source(), source.utf8.count <= 65_536,
              source.components(separatedBy: "__COMPUTA_RENDERER_STARTUP_DIAGNOSTIC_CONFIG__").count == 2,
              let data = try? JSONSerialization.data(withJSONObject: ["expiresAtUnixSeconds": expiry.doubleValue]),
              let config = String(data: data, encoding: .utf8) else { return nil }
        return WKUserScript(source: source.replacingOccurrences(of: "__COMPUTA_RENDERER_STARTUP_DIAGNOSTIC_CONFIG__", with: config),
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static func rendererRegexDiagnosticScripts(armedUntil: Any?, now: TimeInterval = Date().timeIntervalSince1970,
                                               source: () -> String?) -> [WKUserScript] {
        guard let expiry = armedUntil as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue.isFinite, expiry.doubleValue > now, expiry.doubleValue <= now + 600,
              let source = source(), source.utf8.count <= 65_536,
              source.components(separatedBy: "__COMPUTA_RENDERER_REGEX_DIAGNOSTIC_CONFIG__").count == 2,
              let data = try? JSONSerialization.data(withJSONObject: ["expiresAtUnixSeconds": expiry.doubleValue]),
              let config = String(data: data, encoding: .utf8) else { return [] }
        let script = source.replacingOccurrences(of: "__COMPUTA_RENDERER_REGEX_DIAGNOSTIC_CONFIG__", with: config)
        // The two realms have separate RegExp intrinsics and diagnostic state.
        // Both probes precede any provider or adapter code in this owned view.
        return [WKContentWorld.page, WKContentWorld.world(name: "computa-chatgpt-model-v1")].map {
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: $0)
        }
    }

    private static func rendererDiagnosticSource(named name: String) -> String? {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "BrowserModels"),
               let source = try? String(contentsOf: url, encoding: .utf8) { return source }
        }
        return nil
    }

    /// Native-only, one-use capability. Human inspector policy/flags stay unchanged.
    /// This toggles public WebKit inspection only; it does not open or capture it.
    func grantModelInspectorDiagnostic(_ binding: ChatGPTInspectorLease.Binding, tabID: UUID,
                                       view: WKWebView, ownerToken: String, generation: UUID) -> Bool {
        guard !isShutdown, !Task.isCancelled, let entry = entries[tabID], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.inspectorDiagnostic == nil,
              entry.modelChanges?.ownerToken == ownerToken, entry.modelSignalOriginHost == "chatgpt.com",
              entry.tab.documentGeneration == generation, Self.inspectorOriginAllowed(view.url) else { return false }
        let id = UUID()
        let activated = binding.activate(view: ObjectIdentifier(view), ownerToken: ownerToken, generation: generation,
            onRevocation: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let current = self.entries[tabID], current.inspectorDiagnostic?.id == id else { return }
                    self.revokeModelInspector(current, reason: .nativeContext)
                }
            }, action: {
                view.isInspectable = true
            })
        guard activated else { return false }
        let expiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: binding.deadline, clock: .continuous) }
            catch { return }
            guard let self, let current = self.entries[tabID], current.inspectorDiagnostic?.id == id else { return }
            self.revokeModelInspector(current, reason: .expired)
        }
        entry.hadChatRootDiagnostic = true
        entry.inspectorDiagnostic = (id, binding, expiry)
        Self.inspectorDiagnosticLog.notice("inspectorDiagnostic disposition=granted")
        return true
    }

    #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
    /// The exact active synthetic capture admits one native focus experiment,
    /// before insertion. No Inspector, website, request or tool grant is involved.
    @discardableResult
    func grantSyntheticBenchmarkNativeFocusDiagnostic(_ binding: WebsiteBenchmarkCaptureLease.NativeFocusBinding,
        tabID: UUID, view: WKWebView, ownerToken: String, generation: UUID) -> Bool {
        guard modelNativeFocusDiagnosticRequested, !isShutdown, !Task.isCancelled,
              modelNativeFocusDiagnosticTabID == nil, let entry = entries[tabID], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.syntheticNativeFocusDiagnostic == nil,
              entry.inspectorDiagnostic == nil, entry.requestMetadataDiagnostic == nil,
              entry.modelChanges?.ownerToken == ownerToken, entry.modelSignalOriginHost == "chatgpt.com",
              entry.tab.documentGeneration == generation, Self.inspectorOriginAllowed(view.url),
              view.url?.path == "/", let model = view as? EmbeddedModelWebView else { return false }
        let id = UUID()
        let activated = binding.activate(view: ObjectIdentifier(view), ownerToken: ownerToken, generation: generation,
            onRevocation: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let current = self.entries[tabID],
                          current.syntheticNativeFocusDiagnostic?.id == id else { return }
                    self.endModelNativeFocusDiagnostic(current)
                }
            }, action: {
                modelNativeFocusDiagnosticRequested = false
                guard model.beginNativeFocusDiagnostic(onEnd: { [weak self] in
                    guard let self, let current = self.entries[tabID],
                          current.syntheticNativeFocusDiagnostic?.id == id else { return }
                    self.endModelNativeFocusDiagnostic(current)
                }) else {
                    modelNativeFocusDiagnosticDisposition = .rejected
                    Self.inspectorDiagnosticLog.notice("syntheticNativeFocusDiagnostic version=1 nonce=\(binding.nonce.uuidString.lowercased(), privacy: .public) sessionID=\(binding.ownerToken.lowercased(), privacy: .public) generation=\(binding.generation.uuidString.lowercased(), privacy: .public) disposition=rejected reason=\(model.nativeFocusDiagnosticRejection.rawValue, privacy: .public)")
                    return false
                }
                modelNativeFocusDiagnosticTabID = tabID
                modelNativeFocusDiagnosticDisposition = .acquired
                return true
            })
        guard activated else { return false }
        let expiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: binding.deadline, clock: .continuous) }
            catch { return }
            guard let self, let current = self.entries[tabID],
                  current.syntheticNativeFocusDiagnostic?.id == id else { return }
            self.endModelNativeFocusDiagnostic(current)
        }
        entry.hadChatRootDiagnostic = true
        entry.syntheticNativeFocusDiagnostic = (id, binding, expiry)
        Self.inspectorDiagnosticLog.notice("syntheticNativeFocusDiagnostic version=1 nonce=\(binding.nonce.uuidString.lowercased(), privacy: .public) sessionID=\(binding.ownerToken.lowercased(), privacy: .public) generation=\(binding.generation.uuidString.lowercased(), privacy: .public) disposition=acquired")
        return true
    }
    #endif

    func revokeModelInspectorDiagnostic(tabID: UUID, ownerToken: String) {
        guard let entry = entries[tabID], entry.modelChanges?.ownerToken == ownerToken else { return }
        revokeModelInspector(entry, reason: .finished)
    }

    private static func inspectorOriginAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "chatgpt.com" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    private func revokeModelInspector(_ entry: Entry, reason: ModelInspectorRevocation) {
        #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
        endModelNativeFocusDiagnostic(entry)
        #endif
        guard let diagnostic = entry.inspectorDiagnostic else { return }
        entry.inspectorDiagnostic = nil
        diagnostic.expiry.cancel()
        entry.view.isInspectable = false
        diagnostic.binding.revoke()
        Self.inspectorDiagnosticLog.notice("inspectorDiagnostic disposition=revoked reason=\(reason.rawValue, privacy: .public)")
    }

    /// Binding a human page always performs a native backend observation before
    /// publishing its broker lease. Keep this document ineligible even after
    /// release; a new committed human document can offer a new recovery intent.
    func markHumanDocumentUsedByTool(tabID: UUID, generation: UUID) throws {
        let entry = try entry(tabID)
        guard !entry.isModelOwned, entry.tab.documentGeneration == generation else { throw BrowserTabBrokerError.staleDocument }
        entry.recoveryToolUsed = true
    }

    /// Called only inside the one-use mutation permit's successful enqueue.
    /// A provisional/failed load or Stop does not replace the retained document.
    func prepareToolMutation(tabID: UUID, generation: UUID) throws -> UUID {
        let entry = try entry(tabID)
        guard !entry.isModelOwned, entry.tab.documentGeneration == generation else {
            throw BrowserTabBrokerError.staleDocument
        }
        entry.view.isInspectable = false
        entry.tab.isWebInspectorEnabled = false
        entry.tab.isWebInspectorAvailable = false
        let context = ToolMutationPopupContext(documentID: entry.humanCommittedDocumentID)
        entry.toolPopupContext = context
        entry.recoveryToolUsed = true
        return context.operationID
    }

    func toolPopupWasRejected(tabID: UUID, operationID: UUID) -> Bool {
        guard let entry = entries[tabID], let context = entry.toolPopupContext,
              context.operationID == operationID, context.documentID == entry.humanCommittedDocumentID else { return false }
        return context.rejected
    }

    func captureModelNativeFocus(tabID: UUID) {
        (entries[tabID]?.view as? EmbeddedModelWebView)?.captureNativeFocus()
    }

    func restoreModelNativeFocus(tabID: UUID) {
        (entries[tabID]?.view as? EmbeddedModelWebView)?.restoreNativeFocus()
    }

    /// The SwiftUI workspace keeps this host attached even when Browser or
    /// Settings is hidden. It is a render surface, never an input destination.
    func installModelRenderHost(_ host: NSView) {
        modelRenderHosts.removeAll { $0.view == nil }
        if !modelRenderHosts.contains(where: { $0.view === host }) { modelRenderHosts.append(ModelRenderHostReference(host)) }
        // WindowGroup shares this session. Updating another window must not
        // move live pages away from a surviving designated render host.
        if modelRenderHost == nil { modelRenderHost = modelRenderHosts.first?.view }
        for entry in entries.values where entry.shouldMountInBackground {
            mountModelView(entry)
        }
    }

    func removeModelRenderHost(_ host: NSView) {
        modelRenderHosts.removeAll { $0.view == nil || $0.view === host }
        if modelRenderHost === host {
            modelRenderHost = modelRenderHosts.first?.view
            for entry in entries.values where entry.shouldMountInBackground {
                if modelRenderHost != nil { mountModelView(entry) }
                else if entry.view.superview === host {
                    #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
                    endModelNativeFocusDiagnostic(entry)
                    #endif
                    entry.view.removeFromSuperview()
                }
            }
        }
    }

    func presentTab(_ id: UUID, in host: NSView) throws {
        let entry = try entry(id)
        guard !entry.isModelOwned else { throw Failure.modelTabPrivate }
        entry.presentationHost = host
        if !entry.toolRenderLeases.isEmpty {
            // The workspace may update or replace its selected pane while a
            // task borrows this exact page. Remember the latest human host,
            // but keep the task's viewport stable until its final lease ends.
            rememberPresentedFrame(entry, host: host)
            mountModelView(entry)
            return
        }
        mountPresentedView(entry, in: host)
    }

    private func mountPresentedView(_ entry: Entry, in host: NSView) {
        entry.view.removeFromSuperview()
        entry.frameBeforeToolRendering = nil
        (entry.view as? EmbeddedModelWebView)?.protectsNativeFocus = entry.isModelOwned || entry.isToolOwned
        entry.view.frame = host.bounds
        entry.view.autoresizingMask = [.width, .height]
        (entry.view as? EmbeddedModelWebView)?.captureNativeFocus(in: host.window)
        host.addSubview(entry.view)
    }

    func detachPresentedTab(_ id: UUID, from host: NSView) {
        guard let entry = entries[id], entry.presentationHost === host else { return }
        if !entry.toolRenderLeases.isEmpty { rememberPresentedFrame(entry, host: host) }
        entry.presentationHost = nil
        if entry.view.superview === host { entry.view.removeFromSuperview() }
        if entry.needsBackgroundRendering { mountModelView(entry) }
    }

    /// A revocable render lease borrows the exact human view. It cannot select,
    /// navigate, close, or change the ownership of that tab. A selected narrow
    /// human pane cannot shrink the task viewport; final release restores it.
    func acquireToolRendering(tabID: UUID) throws -> UUID {
        let entry = try entry(tabID)
        guard !entry.isModelOwned else { throw Failure.modelTabPrivate }
        guard modelRenderHost?.window != nil else {
            throw BrowserTabBrokerError.browserUnavailable("The background browser render host is unavailable. No page action was dispatched.")
        }
        let lease = UUID()
        entry.toolRenderLeases.insert(lease)
        mountModelView(entry)
        return lease
    }

    func releaseToolRendering(tabID: UUID, lease: UUID) {
        guard let entry = entries[tabID], entry.toolRenderLeases.remove(lease) != nil,
              entry.toolRenderLeases.isEmpty else { return }
        if let host = entry.presentationHost {
            mountPresentedView(entry, in: host)
            return
        }
        guard !entry.needsBackgroundRendering else { return }
        entry.view.removeFromSuperview()
        if let saved = entry.frameBeforeToolRendering {
            entry.view.frame = saved.frame
            entry.view.autoresizingMask = saved.autoresizing
        }
        entry.frameBeforeToolRendering = nil
        (entry.view as? EmbeddedModelWebView)?.protectsNativeFocus = false
    }

    /// A retained lease is not evidence that its render surface still exists.
    /// Check immediately before tool dispatch, without moving or replaying it.
    func requireToolRendering(tabID: UUID) throws {
        let entry = try entry(tabID)
        guard !entry.toolRenderLeases.isEmpty else { return }
        guard let host = modelRenderHost, let window = host.window,
              entry.view.superview === host, entry.view.window === window,
              entry.view.bounds.width >= 1_024, entry.view.bounds.height >= 768 else {
            throw BrowserTabBrokerError.browserUnavailable("The background browser render host is unavailable. No page action was dispatched.")
        }
    }

    private func rememberPresentedFrame(_ entry: Entry, host: NSView) {
        guard !entry.isModelOwned, !entry.isToolOwned else { return }
        entry.frameBeforeToolRendering = (host.bounds, [.width, .height])
    }

    private func mountModelView(_ entry: Entry) {
        guard let host = modelRenderHost else { return }
        if !entry.isModelOwned, !entry.isToolOwned, entry.frameBeforeToolRendering == nil {
            entry.frameBeforeToolRendering = (entry.view.frame, entry.view.autoresizingMask)
        }
        (entry.view as? EmbeddedModelWebView)?.protectsNativeFocus = true
        if entry.view.superview !== host {
            #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
            endModelNativeFocusDiagnostic(entry)
            #endif
            entry.view.removeFromSuperview()
        }
        entry.view.autoresizingMask = []
        entry.view.frame = NSRect(x: 0, y: 0, width: 1_024, height: 768)
        (entry.view as? EmbeddedModelWebView)?.captureNativeFocus(in: host.window)
        if entry.view.superview !== host { host.addSubview(entry.view) }
    }

    func documentGeneration(for id: UUID) -> UUID? { entries[id]?.tab.documentGeneration }

    /// A provisional load may invalidate capabilities without replacing the
    /// rendered document. Retry accounting uses only an observed native commit.
    func committedHumanDocumentID(for id: UUID, generation: UUID) -> UUID? {
        guard let entry = entries[id], !entry.isModelOwned,
              entry.tab.documentGeneration == generation,
              entry.humanCommittedNavigation != nil else { return nil }
        return entry.humanCommittedDocumentID
    }


    /// Diagnostic-only native observation/disposal authority for one exact
    /// private view. It never grants provider/page or conversation authority.
    enum GeminiPostBlockNativeEvent: String {
        case changed, started, redirected, committed, finished, failed, terminated, closed
    }

    @MainActor final class GeminiPostBlockNativeLease {
        let id = UUID()
        fileprivate let tabID: UUID
        fileprivate let view: WKWebView
        fileprivate let ownerToken: String
        fileprivate(set) var exactViewClosed = false
        fileprivate(set) var ended = false

        fileprivate init(tabID: UUID, view: WKWebView, ownerToken: String) {
            self.tabID = tabID; self.view = view; self.ownerToken = ownerToken
        }
    }

    var hasConsumedGeminiPostBlockDiagnostic: Bool { geminiPostBlockDiagnosticConsumed }

    /// Caller must already have latched its original checkpoint failure. No
    /// setting/RPC or page script can arm this initializer-only diagnostic.
    func beginGeminiPostBlockNativeObservation(tabID: UUID, view: WKWebView, ownerToken: String,
        callback: @escaping @MainActor (GeminiPostBlockNativeEvent) -> Void) -> GeminiPostBlockNativeLease? {
        guard !isShutdown, !geminiPostBlockDiagnosticConsumed,
              let entry = entries[tabID], entry.isModelOwned, !entry.isToolOwned,
              entry.view === view, entry.modelChanges?.ownerToken == ownerToken,
              entry.geminiPostBlockObservation == nil else { return nil }
        let lease = GeminiPostBlockNativeLease(tabID: tabID, view: view, ownerToken: ownerToken)
        geminiPostBlockDiagnosticConsumed = true
        entry.geminiPostBlockObservation = (lease, callback)
        return lease
    }

    func isGeminiPostBlockNativeLeaseCurrent(_ lease: GeminiPostBlockNativeLease) -> Bool {
        guard !isShutdown, !lease.ended, let entry = entries[lease.tabID], entry.isModelOwned,
              !entry.isToolOwned, entry.view === lease.view,
              entry.modelChanges?.ownerToken == lease.ownerToken,
              entry.geminiPostBlockObservation?.lease === lease else { return false }
        return true
    }

    func endGeminiPostBlockNativeObservation(_ lease: GeminiPostBlockNativeLease) {
        if let entry = entries[lease.tabID], entry.view === lease.view,
           entry.geminiPostBlockObservation?.lease === lease { entry.geminiPostBlockObservation = nil }
        lease.ended = true
    }

    /// Separate from the unchanged checkpoint generation/URL receipt. This
    /// closes only the originally leased, still-private physical view.
    func disposeGeminiPostBlockDiagnosticView(_ lease: GeminiPostBlockNativeLease) -> Bool {
        guard isGeminiPostBlockNativeLeaseCurrent(lease) else { return false }
        closeTab(lease.tabID)
        return lease.exactViewClosed && entries[lease.tabID] == nil
    }

    private func emitGeminiPostBlockNativeEvent(_ entry: Entry, _ event: GeminiPostBlockNativeEvent) {
        guard entries[entry.tab.id] === entry, let observation = entry.geminiPostBlockObservation,
              isGeminiPostBlockNativeLeaseCurrent(observation.lease) else { return }
        observation.callback(event)
    }

    #if DEBUG
    func emitGeminiPostBlockNativeEventForTesting(tabID: UUID, view: WKWebView, event: GeminiPostBlockNativeEvent) {
        guard let entry = entries[tabID], entry.view === view else { return }
        emitGeminiPostBlockNativeEvent(entry, event)
    }
    #endif

    struct ModelNavigationDiagnostic: Equatable {
        let viewLoading: Bool
        let tabLoading: Bool
        let navigationPending: Bool
        let generationCommitted: Bool
        let generationFinished: Bool
        let navigationError: Bool
        let geminiDocumentCommitObserved: Bool
        let serverRedirectObservedInCurrentNavigation: Bool

        var settled: Bool {
            generationCommitted && generationFinished && !viewLoading && !tabLoading
                && !navigationPending && !navigationError
        }

        var logDescription: String {
            "known=true viewLoading=\(viewLoading) tabLoading=\(tabLoading) navigationPending=\(navigationPending) generationCommitted=\(generationCommitted) generationFinished=\(generationFinished) navigationError=\(navigationError) settled=\(settled) geminiDocumentCommitObserved=\(geminiDocumentCommitObserved) serverRedirectObservedInCurrentNavigation=\(serverRedirectObservedInCurrentNavigation)"
        }

        static let unknownLogDescription = "known=false viewLoading=unknown tabLoading=unknown navigationPending=unknown generationCommitted=unknown generationFinished=unknown navigationError=unknown settled=unknown geminiDocumentCommitObserved=unknown serverRedirectObservedInCurrentNavigation=unknown"
    }

    /// Native-only observation of the exact private view. Neither a URL nor a
    /// document body is captured, and unknown ownership never becomes false facts.
    func modelNavigationDiagnostic(tabID: UUID, view: WKWebView) -> ModelNavigationDiagnostic? {
        guard !isShutdown, let entry = entries[tabID], entry.isModelOwned, entry.view === view else { return nil }
        let generation = entry.tab.documentGeneration
        return .init(viewLoading: view.isLoading, tabLoading: entry.tab.isLoading,
                     navigationPending: entry.navigation != nil,
                     generationCommitted: entry.modelCommittedGeneration == generation,
                     generationFinished: entry.modelFinishedGeneration == generation,
                     navigationError: entry.modelFailedGeneration == generation,
                     geminiDocumentCommitObserved: entry.geminiDocumentCommitObserved,
                     serverRedirectObservedInCurrentNavigation: entry.serverRedirectObservedInCurrentNavigation)
    }

    /// Waiting is allowed only for a current native provisional navigation on
    /// the exact private view. A committed, failed, idle, or unknown document
    /// must take the normal blocker/readiness path instead.
    func hasUncommittedModelNavigation(tabID: UUID, view: WKWebView) -> Bool {
        guard let facts = modelNavigationDiagnostic(tabID: tabID, view: view) else { return false }
        return facts.viewLoading && facts.tabLoading && facts.navigationPending
            && !facts.generationCommitted && !facts.generationFinished && !facts.navigationError
    }

    fileprivate func invalidateChatRootRequest(_ view: WKWebView, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view, entry.usesIsolatedChatGPTProfile else { return }
        entry.authorizedChatRootRequest = nil
        entry.initialChatRootTransition = nil
    }

    fileprivate func noteAllowedChatRootRequest(_ action: WKNavigationAction, view: WKWebView, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view, entry.usesIsolatedChatGPTProfile, entry.isModelOwned,
              action.targetFrame?.isMainFrame == true else { return }
        entry.authorizedChatRootRequest = nil
        entry.initialChatRootTransition = nil
        if action.sourceFrame.isMainFrame, action.request.httpMethod == "GET",
           action.navigationType == .other || action.navigationType == .reload,
           action.request.url?.absoluteString == "https://chatgpt.com/", view.url?.absoluteString == "https://chatgpt.com/" {
            entry.authorizedChatRootRequest = entry.tab.documentGeneration
        }
    }

    enum InitialChatRootTransition { case provisional, settled }

    func initialChatRootTransition(tabID: UUID, view: WKWebView, owner: String,
                                   from: UUID, to: UUID) -> InitialChatRootTransition? {
        guard !isShutdown, let entry = entries[tabID], entry.isModelOwned, !entry.isToolOwned,
              entry.usesIsolatedChatGPTProfile, !entry.hadChatRootDiagnostic, !entry.view.isInspectable, entry.view === view, entry.modelChanges?.ownerToken == owner,
              entry.modelSignalOriginHost == "chatgpt.com", entry.tab.documentGeneration == to, from != to,
              let edge = entry.initialChatRootTransition, edge.from == from, edge.to == to,
              let facts = modelNavigationDiagnostic(tabID: tabID, view: view), !facts.navigationError,
              !facts.serverRedirectObservedInCurrentNavigation else { return nil }
        if facts.settled {
            return view.url?.absoluteString == "https://chatgpt.com/" ? .settled : nil
        }
        guard entry.pendingConversationURL?.absoluteString == "https://chatgpt.com/", facts.navigationPending else { return nil }
        return .provisional
    }

    static let modelSignalName = "computaChatGPTSignal"
    static let modelDiagnosticName = "computaModelDiagnostic"
    static let modelClockName = "computaModelClock"

    private struct ModelClockWait {
        let task: Task<Void, Never>
        let reply: @MainActor @Sendable (Any?, String?) -> Void
    }

    /// Fixed categories only. Diagnostics never change revisions or grant page authority.
    enum ModelAdapterPhase: String, CaseIterable {
        case adapterEntry = "adapter_entry"
        case modelProof = "model_proof"
        case modelWait = "model_wait"
        case modelWaitDone = "model_wait_done"
        case firstUserHash = "first_user_hash"
        case firstUserExpand = "first_user_expand"
        case firstUserExpandWait = "first_user_expand_wait"
        case firstUserExposureWait = "first_user_exposure_wait"
        case firstUserExposureDone = "first_user_exposure_done"
        case pageAction = "page_action"
        case finalModelGuard = "final_model_guard"
    }

    private enum ModelDiagnosticRejection: String {
        case frame, generation, payload, origin
    }

    /// Install private-world notifications, diagnostics and bounded deadline
    /// replies for one inference-owned view.
    func installModelChangeSignal(tabID: UUID, ownerToken: String, world: WKContentWorld,
                                  originHost: String = "chatgpt.com") throws {
        let entry = try entry(tabID)
        guard UUID(uuidString: ownerToken) != nil, entry.modelChanges == nil,
              ["chatgpt.com", "claude.ai", "gemini.google.com", "chat.groq.com", "www.kimi.ai", "chat.qwen.ai", "chat.deepseek.com"].contains(originHost) else { throw Failure.tabClosed }
        entry.modelChanges = EmbeddedModelChangeChannel(ownerToken: ownerToken)
        entry.modelSignalWorld = world
        entry.modelSignalOriginHost = originHost
        entry.view.configuration.userContentController.add(EmbeddedModelSignalHandler(session: self, tabID: tabID),
                                                           contentWorld: world, name: Self.modelSignalName)
        entry.view.configuration.userContentController.add(EmbeddedModelDiagnosticHandler(session: self, tabID: tabID),
                                                           contentWorld: world, name: Self.modelDiagnosticName)
        entry.view.configuration.userContentController.addScriptMessageHandler(EmbeddedModelClockHandler(session: self, tabID: tabID),
                                                                                contentWorld: world, name: Self.modelClockName)
    }

    func beginModelDiagnostic(tabID: UUID, ownerToken: String, operationID: UUID) throws {
        let entry = try entry(tabID)
        guard entry.modelChanges?.ownerToken == ownerToken else { throw Failure.tabClosed }
        // Scope diagnostics and native clocks to one operation. A newer
        // operation expires older waits without supplying positive proof.
        cancelModelClocks(entry)
        entry.modelDiagnosticOperation = operationID
        entry.modelDiagnosticGeneration = entry.tab.documentGeneration
        entry.modelDiagnosticStarted = .now
        entry.modelDiagnosticPhaseStarted = nil
        entry.modelDiagnosticPhases.removeAll(keepingCapacity: true)
        entry.modelDiagnosticReceived = 0
        entry.modelDiagnosticAccepted = 0
        entry.modelDiagnosticLastRejection = nil
        entry.modelDOMReceivedAtOperationStart = entry.modelDOMSignalsReceived
    }

    func endModelDiagnostic(tabID: UUID, operationID: UUID) {
        guard let entry = entries[tabID], entry.modelDiagnosticOperation == operationID else { return }
        entry.modelDiagnosticOperation = nil
        entry.modelDiagnosticGeneration = nil
        cancelModelClocks(entry)
    }

    /// A synchronous native snapshot remains available when JavaScript is stalled.
    /// Values are bounded geometry, booleans, counters and enum names, never page data.
    func modelDiagnosticSnapshot(tabID: UUID, operationID: UUID? = nil) -> String {
        guard let entry = entries[tabID] else { return "state=closed" }
        if let operationID, entry.modelDiagnosticOperation != operationID { return "state=superseded" }
        func dimension(_ value: CGFloat) -> Int { value.isFinite ? Int(max(0, min(16_384, value.rounded()))) : 0 }
        func milliseconds(since instant: ContinuousClock.Instant?) -> Int {
            guard let instant else { return 0 }
            let parts = (ContinuousClock.now - instant).components
            return Int(max(0, min(45_000, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)))
        }
        let view = entry.view, window = view.window
        let phases = entry.modelDiagnosticPhases.map(\.rawValue).joined(separator: ",")
        let url = view.url
        let originCurrent = url?.scheme == "https" && url?.host == entry.modelSignalOriginHost
            && (url?.port == nil || url?.port == 443)
        return "phases=\(phases.isEmpty ? "not_started" : phases) active=\(entry.modelDiagnosticOperation != nil)"
            + " operationAgeMs=\(milliseconds(since: entry.modelDiagnosticStarted)) phaseAgeMs=\(milliseconds(since: entry.modelDiagnosticPhaseStarted)) clocksPending=\(entry.modelClockWaits.count)"
            + " generationCurrent=\(entry.modelDiagnosticGeneration == entry.tab.documentGeneration) originCurrent=\(originCurrent)"
            + " diagnosticsReceived=\(entry.modelDiagnosticReceived) diagnosticsAccepted=\(entry.modelDiagnosticAccepted) diagnosticRejected=\(entry.modelDiagnosticLastRejection?.rawValue ?? "none")"
            + " domDuringOperation=\(max(0, Int(entry.modelDOMSignalsReceived) - Int(entry.modelDOMReceivedAtOperationStart)))"
            + " domReceived=\(entry.modelDOMSignalsReceived) domAccepted=\(entry.modelDOMSignalsAccepted) revision=\((try? entry.modelChanges?.currentRevision()) ?? 0)"
            + " attached=\(view.superview != nil) hidden=\(view.isHiddenOrHasHiddenAncestor) window=\(window != nil)"
            + " visible=\(window?.isVisible == true) occluded=\(window != nil && window?.occlusionState.contains(.visible) != true)"
            + " width=\(dimension(view.bounds.width)) height=\(dimension(view.bounds.height))"
            + " visibleWidth=\(dimension(view.visibleRect.width)) visibleHeight=\(dimension(view.visibleRect.height))"
            + " hostWidth=\(dimension(view.superview?.bounds.width ?? 0)) hostHeight=\(dimension(view.superview?.bounds.height ?? 0))"
    }

    fileprivate func receivedModelDiagnostic(_ message: WKScriptMessage, tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        entry.modelDiagnosticReceived = entry.modelDiagnosticReceived == .max ? .max : entry.modelDiagnosticReceived + 1
        guard message.webView === entry.view, message.frameInfo.isMainFrame else {
            entry.modelDiagnosticLastRejection = .frame; return
        }
        guard entry.modelDiagnosticGeneration == entry.tab.documentGeneration else {
            entry.modelDiagnosticLastRejection = .generation; return
        }
        guard let operation = entry.modelDiagnosticOperation,
              let body = message.body as? [String: String], Set(body.keys) == ["ownerToken", "operationID", "phase"],
              body["ownerToken"] == entry.modelChanges?.ownerToken,
              body["operationID"].flatMap(UUID.init(uuidString:)) == operation,
              let rawPhase = body["phase"], let phase = ModelAdapterPhase(rawValue: rawPhase) else {
            entry.modelDiagnosticLastRejection = .payload; return
        }
        let origin = message.frameInfo.securityOrigin
        guard origin.`protocol` == "https", origin.host == entry.modelSignalOriginHost,
              origin.port == 0 || origin.port == 443 else { entry.modelDiagnosticLastRejection = .origin; return }
        entry.modelDiagnosticAccepted = entry.modelDiagnosticAccepted == .max ? .max : entry.modelDiagnosticAccepted + 1
        entry.modelDiagnosticPhaseStarted = .now
        if entry.modelDiagnosticPhases.last != phase {
            entry.modelDiagnosticPhases.append(phase)
            if entry.modelDiagnosticPhases.count > 8 { entry.modelDiagnosticPhases.removeFirst() }
        }
    }

    /// A bounded one-shot deadline, independent of website timers. Its reply can
    /// only expire a JavaScript wait; it cannot supply model or ownership proof.
    fileprivate func receivedModelClock(_ message: WKScriptMessage, tabID: UUID,
                                       reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let entry = entries[tabID], message.webView === entry.view, message.frameInfo.isMainFrame,
              entry.modelDiagnosticGeneration == entry.tab.documentGeneration,
              let operation = entry.modelDiagnosticOperation,
              let body = message.body as? [String: Any], Set(body.keys) == ["ownerToken", "operationID", "milliseconds"],
              body["ownerToken"] as? String == entry.modelChanges?.ownerToken,
              (body["operationID"] as? String).flatMap(UUID.init(uuidString:)) == operation,
              let number = body["milliseconds"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (1...10_000).contains(number.doubleValue),
              number.doubleValue.rounded(.towardZero) == number.doubleValue, entry.modelClockWaits.count < 32 else {
            reply(nil, "model_clock_rejected"); return
        }
        let origin = message.frameInfo.securityOrigin
        guard origin.`protocol` == "https", origin.host == entry.modelSignalOriginHost,
              origin.port == 0 || origin.port == 443 else { reply(nil, "model_clock_rejected"); return }
        let id = UUID()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(number.intValue))
                self?.finishModelClock(tabID: tabID, operationID: operation, id: id)
            } catch { }
        }
        entry.modelClockWaits[id] = ModelClockWait(task: task, reply: reply)
    }

    private func finishModelClock(tabID: UUID, operationID: UUID, id: UUID) {
        guard let entry = entries[tabID], let wait = entry.modelClockWaits.removeValue(forKey: id) else { return }
        guard entry.modelDiagnosticOperation == operationID, entry.modelDiagnosticGeneration == entry.tab.documentGeneration else {
            wait.reply(nil, "model_clock_cancelled"); return
        }
        wait.reply(true, nil)
    }

    private func cancelModelClocks(_ entry: Entry) {
        let waits = Array(entry.modelClockWaits.values)
        entry.modelClockWaits.removeAll(keepingCapacity: true)
        for wait in waits { wait.task.cancel(); wait.reply(nil, "model_clock_cancelled") }
    }

    /// A native-memory observation only. This does not inspect the provider,
    /// signal/rearm its observer, advance a revision, or grant page authority.
    struct ModelSignalProgress: Sendable {
        let received: Int
        let accepted: Int
        let revision: Int
        let saturated: Bool
        let attached: Bool
        let hidden: Bool
        let windowPresent: Bool
        let visible: Bool
        let occluded: Bool
    }

    func modelSignalProgress(tabID: UUID, view: WKWebView, ownerToken: String,
                             generation: UUID) -> ModelSignalProgress? {
        guard let entry = entries[tabID], entry.isModelOwned, !entry.isToolOwned,
              entry.view === view, let channel = entry.modelChanges,
              channel.ownerToken == ownerToken, entry.tab.documentGeneration == generation,
              let revision = try? channel.currentRevision() else { return nil }
        let cap = UInt64(UInt16.max)
        let received = Int(entry.modelDOMSignalsReceived)
        let accepted = Int(entry.modelDOMSignalsAccepted)
        let window = view.window
        return ModelSignalProgress(received: received, accepted: accepted,
            revision: Int(min(revision, cap)),
            saturated: UInt64(received) >= cap || UInt64(accepted) >= cap || revision >= cap,
            attached: view.superview != nil, hidden: view.isHiddenOrHasHiddenAncestor,
            windowPresent: window != nil, visible: window?.isVisible == true,
            occluded: window != nil && window?.occlusionState.contains(.visible) != true)
    }

    func modelChangeRevision(for id: UUID) throws -> UInt64 {
        guard let channel = try entry(id).modelChanges else { throw Failure.tabClosed }
        return try channel.currentRevision()
    }

    /// Native profile state can invalidate an inference without a DOM change.
    /// This only wakes its existing notification channel; it grants no page authority.
    func notifyModelSessionChange(tabID: UUID) {
        entries[tabID]?.modelChanges?.signal()
    }

    func waitForModelChange(tabID: UUID, after revision: UInt64,
                            until deadline: ContinuousClock.Instant) async throws -> UInt64 {
        guard let channel = try entry(tabID).modelChanges else { throw Failure.tabClosed }
        return try await channel.wait(after: revision, until: deadline)
    }

    fileprivate func receivedModelSignal(_ message: WKScriptMessage, tabID: UUID) {
        guard let entry = entries[tabID], message.webView === entry.view else { return }
        if entry.modelDOMSignalsReceived < .max { entry.modelDOMSignalsReceived += 1 }
        guard message.frameInfo.isMainFrame, let channel = entry.modelChanges,
              let body = message.body as? [String: String], body.count == 2, Set(body.keys) == ["ownerToken", "kind"],
              body["ownerToken"] == channel.ownerToken, body["kind"] == "dom_changed" else { return }
        let origin = message.frameInfo.securityOrigin
        guard origin.`protocol` == "https", origin.host == entry.modelSignalOriginHost,
              origin.port == 0 || origin.port == 443 else { return }
        if entry.modelDOMSignalsAccepted < .max { entry.modelDOMSignalsAccepted += 1 }
        channel.signalDOMChange()
    }

    private func signalModelChange(_ entry: Entry) {
        entry.modelChanges?.signal()
        entry.navigationChanges.signal()
    }

    /// Tool tabs share the human profile and can be inspected by the user, but
    /// keep a render surface and never select or acquire native keyboard focus.
    func createToolTab(url: URL) throws -> UUID {
        try createTab(url: url, select: false, modelOwned: false, toolOwned: true)
    }

    /// No model page or privileged app WebView can enter the general browser driver.
    func humanTab(id: UUID) -> EmbeddedBrowserTab? {
        guard let entry = entries[id], !entry.isModelOwned else { return nil }
        return entry.tab
    }

    func waitForHumanTabReady(id: UUID, until deadline: ContinuousClock.Instant) async throws {
        while true {
            try Task.checkCancellation()
            let entry = try entry(id)
            guard !entry.isModelOwned else { throw Failure.modelTabPrivate }
            let revision = try entry.navigationChanges.currentRevision()
            if let error = entry.tab.error { throw BrowserTabBrokerError.browserUnavailable(error) }
            if !entry.tab.isLoading, !entry.view.isLoading, entry.view.url != nil { return }
            guard ContinuousClock.now < deadline else {
                throw BrowserTabBrokerError.browserUnavailable("The built-in tab did not finish navigation before its deadline; no action was replayed.")
            }
            _ = try await entry.navigationChanges.wait(after: revision, until: deadline)
        }
    }

    #if DEBUG
    var documentChangeWaitRegisteredForTesting: (() -> Void)?
    #endif

    /// Metadata-only future-change predicate. One absolute deadline covers
    /// both waiting for a change and any navigation that follows it.
    func waitForHumanTabDocumentChange(id: UUID, loaderID: String, url: URL,
                                      until deadline: ContinuousClock.Instant,
                                      authorization: () throws -> Void) async throws -> BrowserDocumentChangeResult {
        let original = try entry(id)
        guard !original.isModelOwned else { throw Failure.modelTabPrivate }
        let view = original.view
        var changed = false
        while true {
            try Task.checkCancellation()
            let current = try entry(id)
            guard !current.isModelOwned else { throw Failure.modelTabPrivate }
            guard current.view === view else { throw BrowserTabBrokerError.targetReplaced }
            try authorization()
            // Register against the revision obtained before examining state;
            // an event between inspection and suspension cannot be missed.
            let revision = try current.navigationChanges.currentRevision()
            changed = changed || current.tab.documentGeneration.uuidString != loaderID || current.view.url != url
            if let error = current.tab.error { throw BrowserTabBrokerError.browserUnavailable(error) }
            guard ContinuousClock.now < deadline else {
                return .init(changed: changed, navigationReady: false)
            }
            if changed, !current.tab.isLoading, !current.view.isLoading, current.view.url != nil {
                return .init(changed: true, navigationReady: true)
            }
            #if DEBUG
            documentChangeWaitRegisteredForTesting?()
            #endif
            _ = try await current.navigationChanges.wait(after: revision, until: deadline)
        }
    }

    /// Model pages share the sign-in profile, but never reuse a human's tab.
    func createModelTab(url: URL) throws -> UUID {
        try createModelTab(initialURL: url)
    }

    private static let inferencePrewarmLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "EmbeddedWebModel")

    struct GeminiVerificationCookieObservation: Encodable, Equatable, Sendable {
        enum Role: String, Encodable, Equatable, Sendable { case human, model }
        enum Phase: String, Encodable, Equatable, Sendable { case requested, callback }
        enum Status: String, Encodable, Equatable, Sendable { case pending, available, unavailable }
        enum Reason: String, Encodable, Equatable, Sendable {
            case sessionClosed = "session_closed", entryChanged = "entry_changed", documentChanged = "document_changed"
            case toolUsed = "tool_used", unsettled, storeChanged = "store_changed", routeChanged = "route_changed"
        }
        let kind = "gemini_verification_cookie_observation_v1"
        let evidence = "callback_time_native_metadata_not_request_cookie_proof"
        let request: Int
        let role: Role
        let destination: GeminiVerificationCookieDiagnostic.Destination
        let sharedStore: Bool
        let phase: Phase
        let status: Status
        let reason: Reason?
        let metadata: GeminiVerificationCookieDiagnostic.Snapshot?
    }

    static let geminiCookieObservationLimit = 16
    @MainActor private final class GeminiCookieObservationTicket { var completed = false }

    private static func geminiCookieDestination(_ url: URL?) -> GeminiVerificationCookieDiagnostic.Destination? {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        switch (url.host?.lowercased(), url.path) {
        case ("gemini.google.com", "/app"): return .geminiApp
        case ("google.com", "/sorry"): return .googleSorry
        case ("google.com", "/sorry/"): return .googleSorrySlash
        case ("google.com", "/sorry/index"): return .googleSorryIndex
        case ("www.google.com", "/sorry"): return .googleWWWSorry
        case ("www.google.com", "/sorry/"): return .googleWWWSorrySlash
        case ("www.google.com", "/sorry/index"): return .googleWWWSorryIndex
        default: return nil
        }
    }

    /// Observation only, after a successful committed navigation. Never awaits
    /// WebKit, retains cookies, clears a checkpoint, or grants model authority.
    private func observeGeminiVerificationCookies(_ entry: Entry) {
        guard !isShutdown, entries[entry.tab.id] === entry, !entry.isToolOwned, !entry.recoveryToolUsed, entry.toolPopupContext == nil,
              entry.toolRenderLeases.isEmpty, entry.navigation == nil, !entry.view.isLoading, !entry.tab.isLoading,
              entry.tab.error == nil, let destination = Self.geminiCookieDestination(entry.view.url),
              entry.geminiCookieObservationGeneration != entry.tab.documentGeneration,
              geminiCookieObservationRequests < Self.geminiCookieObservationLimit else { return }
        let view = entry.view, store = view.configuration.websiteDataStore, shared = websiteDataStore
        let generation = entry.tab.documentGeneration, documentID = entry.tab.documentID
        let committedID = entry.humanCommittedDocumentID, url = view.url, tabID = entry.tab.id
        entry.geminiCookieObservationGeneration = generation
        geminiCookieObservationRequests += 1
        let ordinal = geminiCookieObservationRequests, role: GeminiVerificationCookieObservation.Role = entry.isModelOwned ? .model : .human
        let emit: @MainActor @Sendable (GeminiVerificationCookieObservation.Phase, GeminiVerificationCookieObservation.Reason?,
                                       GeminiVerificationCookieDiagnostic.Snapshot?) -> Void = { [weak self] phase, reason, metadata in
            let value = GeminiVerificationCookieObservation(request: ordinal, role: role, destination: destination,
                sharedStore: store === shared, phase: phase,
                status: phase == .requested ? .pending : metadata?.status == .available ? .available : .unavailable,
                reason: reason, metadata: metadata)
            if let data = try? JSONEncoder().encode(value), data.count <= 2_048 {
                Self.inferencePrewarmLog.notice("geminiVerificationCookieObservation \(String(decoding: data, as: UTF8.self), privacy: .public)")
            }
            #if DEBUG
            self?.geminiCookieObservationSinkForTesting?(value)
            #endif
        }
        emit(.requested, nil, nil)
        let ticket = GeminiCookieObservationTicket()
        let completion: @MainActor @Sendable ([HTTPCookie]) -> Void = { [weak self, weak entry, weak view] cookies in
            guard !ticket.completed else { return }
            ticket.completed = true
            guard let self, !self.isShutdown else { emit(.callback, .sessionClosed, nil); return }
            guard let entry, let view, self.entries[tabID] === entry, entry.view === view else {
                emit(.callback, .entryChanged, nil); return
            }
            guard entry.tab.documentGeneration == generation, entry.tab.documentID == documentID,
                  entry.humanCommittedDocumentID == committedID else { emit(.callback, .documentChanged, nil); return }
            guard !entry.recoveryToolUsed, entry.toolPopupContext == nil, entry.toolRenderLeases.isEmpty else {
                emit(.callback, .toolUsed, nil); return
            }
            guard entry.navigation == nil, !view.isLoading, !entry.tab.isLoading, entry.tab.error == nil else {
                emit(.callback, .unsettled, nil); return
            }
            guard view.configuration.websiteDataStore === store, self.websiteDataStore === shared else {
                emit(.callback, .storeChanged, nil); return
            }
            guard view.url == url, Self.geminiCookieDestination(view.url) == destination else {
                emit(.callback, .routeChanged, nil); return
            }
            emit(.callback, nil, GeminiVerificationCookieDiagnostic.project(cookies, destination: destination, now: Date()))
        }
        #if DEBUG
        if let reader = geminiCookieObservationReaderForTesting { reader(store.httpCookieStore, completion); return }
        #endif
        store.httpCookieStore.getAllCookies(completion)
    }

    /// Store-level diagnostics survive model-view closure. They never authorize
    /// navigation, recovery, model selection, or publication of a response.
    private func observeGeminiCookieTimelineAfterNavigation(_ entry: Entry) {
        guard !isShutdown, entries[entry.tab.id] === entry, !entry.isToolOwned, !entry.recoveryToolUsed,
              entry.toolPopupContext == nil, entry.toolRenderLeases.isEmpty, entry.navigation == nil,
              !entry.view.isLoading, !entry.tab.isLoading, entry.tab.error == nil,
              entry.view.configuration.websiteDataStore === websiteDataStore,
              let destination = Self.geminiCookieDestination(entry.view.url) else { return }
        geminiCookieTimeline?.observe(destination == .geminiApp ? .navigationSettled : .challengeSettled)
    }

    /// Called before runtime teardown, without waiting for a diagnostic read.
    /// A missing callback is unknown; this is not a disk-flush acknowledgement.
    func observeGeminiCookieShutdownRequested() {
        guard !isShutdown else { return }
        geminiCookieTimeline?.observe(.shutdownRequested)
    }
    // Keep one prompt-free root through normal pauses between tasks. Expiring
    // it sooner repeatedly discards a hydrated page just before the next Send.
    // Adoption still validates current cookies, view, generation and route;
    // the transport establishes fresh product/model/readiness proofs afterward.
    private static let inferencePrewarmLifetime: Duration = .seconds(600)

    func setChatGPTInferencePrewarmingEnabled(_ enabled: Bool, preserveUnusedRoot: Bool = false,
                                            admit: @escaping @MainActor () throws -> Void) {
        let wasEnabled = chatGPTInferencePrewarmingEnabled
        // Only a published, unclaimed pristine root may survive a draft pause.
        // Pausing grants no creation/adoption permission and renews no deadline.
        let retained = !enabled && preserveUnusedRoot && chatGPTInferencePrewarm.map {
            !$0.claimed && inferencePrewarmIdentityIsCurrent($0)
        } == true
        chatGPTInferencePrewarmingEnabled = enabled && !isShutdown
        chatGPTInferencePrewarmAdmission = chatGPTInferencePrewarmingEnabled ? admit : nil
        if chatGPTInferencePrewarmingEnabled {
            if !wasEnabled { validateResumedInferencePrewarmIfNeeded() }
            prepareChatGPTInferencePrewarmIfNeeded()
        } else if let warm = chatGPTInferencePrewarm {
            warm.resumeTask?.cancel(); warm.resumeValidation?.cancel()
            if !retained { discardInferencePrewarm(warm) }
        }
    }

    private static func recordInferenceCookieValidation(_ phase: InferenceCookieValidationPhase,
                                                       _ outcome: InferenceCookieValidationOutcome) {
        inferencePrewarmLog.notice("inferencePrewarm validationPhase=\(phase.rawValue, privacy: .public) validationOutcome=\(outcome.rawValue, privacy: .public)")
    }

    /// An explicit resume may replace a stale, still-unclaimed standby before
    /// Start. This read never grants adoption: every claim reads again below.
    private func validateResumedInferencePrewarmIfNeeded() {
        guard let warm = chatGPTInferencePrewarm, !warm.claimed, inferencePrewarmIsCurrent(warm),
              warm.resumeValidation == nil, inferenceCookieValidations.isEmpty,
              let source = warm.source, let cookies = warm.sourceCookies,
              let admit = chatGPTInferencePrewarmAdmission else { return }
        do { try admit() } catch { return }
        let reservation = UUID()
        let reader: any ChatGPTInferenceCookieSource
        #if DEBUG
        reader = cookieValidationSourceForTesting?(source) ?? ChatGPTWKInferenceCookieStore(source)
        #else
        reader = ChatGPTWKInferenceCookieStore(source)
        #endif
        let validation = ChatGPTInferenceCookieValidation(source: reader)
        warm.resumeValidation = validation
        inferenceCookieValidations[reservation] = validation
        warm.resumeTask = Task { @MainActor [weak self, weak warm] in
            guard let self, let warm else { validation.cancel(); return }
            defer {
                if warm.resumeValidation === validation {
                    warm.resumeTask = nil
                    // Cancellation may finish the waiter before the native
                    // callback drains. Do not allow another resume read yet.
                    if self.inferenceCookieValidations[reservation] !== validation { warm.resumeValidation = nil }
                }
            }
            let isCurrent: @MainActor @Sendable () -> Bool = { [weak self, weak warm, weak validation] in
                guard let self, let warm, let validation else { return false }
                return !warm.claimed && warm.resumeValidation === validation && self.inferencePrewarmIsCurrent(warm)
            }
            let matches: Bool
            do {
                matches = try await validation.run(expected: cookies, until: min(warm.deadline, .now + .seconds(2)),
                    isCurrent: isCurrent, onDrained: { [weak self, weak warm, weak validation] in
                        guard let self, let validation, self.inferenceCookieValidations[reservation] === validation else { return }
                        self.inferenceCookieValidations.removeValue(forKey: reservation)
                        if let warm, warm.resumeValidation === validation, warm.resumeTask == nil { warm.resumeValidation = nil }
                    })
            } catch {
                Self.recordInferenceCookieValidation(.resume, error is CancellationError ? .cancelled : .unavailable)
                guard !(error is CancellationError), !Task.isCancelled, isCurrent() else { return }
                warm.resumeTask = nil; warm.resumeValidation = nil
                self.discardInferencePrewarm(warm)
                return
            }
            Self.recordInferenceCookieValidation(.resume, matches ? .match : .mismatch)
            guard !Task.isCancelled, isCurrent() else { return }
            do { try admit() } catch {
                if isCurrent() {
                    warm.resumeTask = nil; warm.resumeValidation = nil
                    self.discardInferencePrewarm(warm)
                }
                return
            }
            guard !Task.isCancelled, isCurrent(), !matches else { return }
            // Detach this completed check before disposing its old slot. The
            // replacement still passes normal admission, seeding and capacity.
            warm.resumeTask = nil; warm.resumeValidation = nil
            self.discardInferencePrewarm(warm)
            self.prepareChatGPTInferencePrewarmIfNeeded()
        }
    }

    /// An explicit demand trigger, never a timer-based refresh or retry loop.
    func prepareChatGPTInferencePrewarmIfNeeded() {
        guard chatGPTInferencePrewarmingEnabled, !isShutdown, chatGPTInferencePrewarm == nil,
              inferenceCookieValidations.isEmpty, exclusiveCookieMaintenance == nil,
              let admit = chatGPTInferencePrewarmAdmission,
              tabs.count + pendingChatGPTInferenceCookiePreparationCount < maximumTabs else { return }
        do { try admit() } catch { return }
        let warm: InferencePrewarm
        #if DEBUG
        warm = InferencePrewarm(lifetime: prewarmLifetimeForTesting ?? Self.inferencePrewarmLifetime)
        #else
        warm = InferencePrewarm(lifetime: Self.inferencePrewarmLifetime)
        #endif
        chatGPTInferencePrewarm = warm
        warm.expiry = Task { @MainActor [weak self, weak warm] in
            guard let warm else { return }
            do { try await Task.sleep(until: warm.deadline) } catch { return }
            self?.discardInferencePrewarm(warm)
        }
        warm.task = Task { @MainActor [weak self, weak warm] in
            guard let self, let warm else { return nil }
            do {
                let id = try await self.createChatGPTInferenceTab(until: min(warm.deadline, .now + .seconds(10)),
                    admit: {
                        guard self.chatGPTInferencePrewarm === warm, self.chatGPTInferencePrewarmingEnabled else {
                            throw ChatGPTInferenceCookieSeed.Failure.unavailable
                        }
                        try admit()
                    }, sourceSelection: { source, cookies in warm.source = source; warm.sourceCookies = cookies })
                warm.tabID = id
                warm.view = self.entries[id]?.view
                warm.generation = self.entries[id]?.tab.documentGeneration
                guard !Task.isCancelled, self.chatGPTInferencePrewarm === warm,
                      self.chatGPTInferencePrewarmingEnabled, self.inferencePrewarmIsCurrent(warm) else {
                    self.rejectInferencePrewarm(warm, reason: self.inferencePrewarmClaimFailure(warm) ?? .identity)
                    // Disable/cancellation may already have removed the slot
                    // before this newly published exact page was recorded.
                    if self.entries[id]?.view === warm.view { self.closeTab(id) }
                    return nil
                }
                let elapsed = (ContinuousClock.now - warm.created).components
                let milliseconds = max(0, min(120_000, elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000))
                Self.inferencePrewarmLog.notice("inferencePrewarm created=true creationMs=\(milliseconds)")
                return id
            } catch { self.discardInferencePrewarm(warm); return nil }
        }
    }

    /// Claim before awaiting an in-flight seed. No second Start or refill may
    /// adopt that slot; all adapter/product/model proofs are established later.
    func takePrewarmedChatGPTInferenceTab(until deadline: ContinuousClock.Instant,
                                        admit: @MainActor () throws -> Void) async throws -> UUID? {
        try Task.checkCancellation()
        var hit = false
        let age = chatGPTInferencePrewarm.map { warm -> Int64 in
            let duration = (ContinuousClock.now - warm.created).components
            return min(600_000, max(0, min(600, max(0, duration.seconds)) * 1_000 + duration.attoseconds / 1_000_000_000_000_000))
        } ?? 0
        defer { Self.inferencePrewarmLog.notice("inferencePrewarm hit=\(hit) ageMs=\(age)") }
        guard chatGPTInferencePrewarmingEnabled, let warm = chatGPTInferencePrewarm, !warm.claimed else {
            return nil
        }
        warm.claimed = true
        // Start supersedes an optional preflight, but never reuses its result.
        // Its outstanding callback remains capacity-accounted until drained.
        warm.resumeTask?.cancel(); warm.resumeValidation?.cancel()
        let waitDeadline = min(deadline, warm.deadline)
        let timeout = Task { @MainActor [weak self, weak warm] in
            do { try await Task.sleep(until: waitDeadline) } catch { return }
            guard let self, let warm else { return }
            self.discardInferencePrewarm(warm)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            do {
                guard ContinuousClock.now < min(deadline, warm.deadline), let task = warm.task,
                      let id = await task.value else { discardInferencePrewarm(warm); return nil }
                try Task.checkCancellation()
                try admit()
                guard ContinuousClock.now < min(deadline, warm.deadline) else {
                    discardInferencePrewarm(warm); return nil
                }
                if let failure = inferencePrewarmClaimFailure(warm) { rejectInferencePrewarm(warm, reason: failure); return nil }
                guard let source = warm.source, let cookies = warm.sourceCookies else {
                    rejectInferencePrewarm(warm, reason: .identity); return nil
                }
                let reservation = UUID()
                let reader: any ChatGPTInferenceCookieSource
                #if DEBUG
                reader = cookieValidationSourceForTesting?(source) ?? ChatGPTWKInferenceCookieStore(source)
                #else
                reader = ChatGPTWKInferenceCookieStore(source)
                #endif
                let validation = ChatGPTInferenceCookieValidation(source: reader)
                warm.validation = validation
                inferenceCookieValidations[reservation] = validation
                let matches: Bool
                do {
                    matches = try await validation.run(expected: cookies, until: min(deadline, warm.deadline),
                        isCurrent: { [weak self, weak warm] in
                            guard let self, let warm else { return false }
                            return self.inferencePrewarmIsCurrent(warm)
                        }, onDrained: { [weak self, weak validation] in
                            guard let self, let validation, self.inferenceCookieValidations[reservation] === validation else { return }
                            self.inferenceCookieValidations.removeValue(forKey: reservation)
                        })
                } catch {
                    Self.recordInferenceCookieValidation(.claim, error is CancellationError ? .cancelled : .unavailable)
                    throw error
                }
                Self.recordInferenceCookieValidation(.claim, matches ? .match : .mismatch)
                try Task.checkCancellation()
                try admit()
                guard ContinuousClock.now < min(deadline, warm.deadline), matches else {
                    discardInferencePrewarm(warm); return nil
                }
                if let failure = inferencePrewarmClaimFailure(warm) { rejectInferencePrewarm(warm, reason: failure); return nil }
                chatGPTInferencePrewarm = nil
                warm.expiry?.cancel(); warm.expiry = nil
                warm.sourceCookies = nil
                hit = true
                return id
            } catch {
                let internallyDisposed = chatGPTInferencePrewarm !== warm
                if !internallyDisposed, let failure = inferencePrewarmClaimFailure(warm) { rejectInferencePrewarm(warm, reason: failure) }
                else { discardInferencePrewarm(warm) }
                if Task.isCancelled { throw CancellationError() }
                if error is CancellationError, internallyDisposed { return nil }
                if error is ChatGPTInferenceCookieSeed.Failure { return nil }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self, weak warm] in
                guard let self, let warm else { return }
                self.discardInferencePrewarm(warm)
            }
        }
    }

    private func inferencePrewarmIsCurrent(_ warm: InferencePrewarm) -> Bool {
        chatGPTInferencePrewarmingEnabled && inferencePrewarmIdentityIsCurrent(warm)
    }

    /// Retention alone may use this identity check while adoption is paused.
    /// Every actual claim still requires inferencePrewarmIsCurrent above.
    private func inferencePrewarmIdentityIsCurrent(_ warm: InferencePrewarm) -> Bool {
        guard !isShutdown, chatGPTInferencePrewarm === warm,
              exclusiveCookieMaintenance == nil, ContinuousClock.now < warm.deadline,
              let source = warm.source, websiteDataStore === source, let id = warm.tabID,
              let view = warm.view, let entry = entries[id], entry.view === view,
              entry.isModelOwned, !entry.isToolOwned, entry.usesIsolatedChatGPTProfile,
              !view.configuration.websiteDataStore.isPersistent, view.configuration.websiteDataStore !== source,
              entry.tab.documentGeneration == warm.generation, entry.modelChanges == nil,
              entry.requestMetadataDiagnostic == nil, entry.inspectorDiagnostic == nil, entry.tab.error == nil,
              entry.ownedTemporaryChatGPTRoutes.isEmpty, entry.modelFailedGeneration != entry.tab.documentGeneration else { return false }
        let root = URL(string: "https://chatgpt.com/")!
        return view.url == root || view.url == nil && entry.pendingConversationURL == root
    }

    /// An issued load request is not readiness. Only the real root or an
    /// actually loading native navigation may leave the optional standby slot.
    /// Actual Start still establishes all document/product/model proofs.
    private func inferencePrewarmClaimFailure(_ warm: InferencePrewarm) -> InferencePrewarmUnavailable? {
        guard let id = warm.tabID, let view = warm.view, let entry = entries[id], entry.view === view else { return .identity }
        if entry.tab.error != nil || entry.modelFailedGeneration == entry.tab.documentGeneration { return .navigationError }
        guard inferencePrewarmIsCurrent(warm) else { return .identity }
        let root = URL(string: "https://chatgpt.com/")!
        if view.url == root { return nil }
        if view.url == nil, entry.pendingConversationURL == root, entry.navigation != nil, view.isLoading { return nil }
        return view.url == nil ? .blankIdle : .unexpectedRoute
    }

    private func rejectInferencePrewarm(_ warm: InferencePrewarm, reason: InferencePrewarmUnavailable) {
        let entry = warm.tabID.flatMap { entries[$0] }
        let exact = entry?.view === warm.view && entry != nil
        let urlPresent = exact && warm.view?.url != nil
        let loading = exact && warm.view?.isLoading == true
        let navigationPending = exact && entry?.navigation != nil
        let tabError = exact && entry?.tab.error != nil
        let failedGeneration = exact && entry?.modelFailedGeneration == entry?.tab.documentGeneration
        let generationCurrent = exact && entry?.tab.documentGeneration == warm.generation
        let diagnostic = "reason=\(reason.rawValue) viewPresent=\(exact) urlPresent=\(urlPresent) loading=\(loading) navigationPending=\(navigationPending) tabError=\(tabError) failedGeneration=\(failedGeneration) generationCurrent=\(generationCurrent)"
        Self.inferencePrewarmLog.notice("inferencePrewarmUnavailable \(diagnostic, privacy: .public)")
        #if DEBUG
        lastInferencePrewarmUnavailableForTesting = diagnostic
        #endif
        discardInferencePrewarm(warm)
    }

    private func discardInferencePrewarm(_ warm: InferencePrewarm) {
        guard chatGPTInferencePrewarm === warm else { return }
        chatGPTInferencePrewarm = nil
        warm.task?.cancel(); warm.expiry?.cancel()
        warm.validation?.cancel()
        warm.resumeTask?.cancel(); warm.resumeValidation?.cancel()
        warm.sourceCookies = nil
        if let id = warm.tabID, entries[id]?.view === warm.view { closeTab(id) }
    }

    /// Independent inference pages need authentication, not the human profile's
    /// accumulated conversation keys. Publication/navigation follows complete
    /// seeding; failure never falls back to the shared store.
    func createChatGPTInferenceTab(requestMetadata: ChatGPTRequestMetadataLease? = nil,
                                   until deadline: ContinuousClock.Instant = .now + .seconds(10),
                                   admit: @MainActor () throws -> Void) async throws -> UUID {
        // An armed document-start diagnostic always receives a cold view;
        // an optional unused page must not consume its publication capacity.
        if requestMetadata != nil, let warm = chatGPTInferencePrewarm { discardInferencePrewarm(warm) }
        return try await createChatGPTInferenceTab(requestMetadata: requestMetadata, until: deadline, admit: admit, sourceSelection: nil)
    }

    private func createChatGPTInferenceTab(requestMetadata: ChatGPTRequestMetadataLease? = nil,
                                          until deadline: ContinuousClock.Instant,
                                          admit: @MainActor () throws -> Void,
                                          sourceSelection: ((WKWebsiteDataStore, [HTTPCookie]) -> Void)?) async throws -> UUID {
        try Task.checkCancellation()
        guard !isShutdown else { throw Failure.sessionClosed }
        guard exclusiveCookieMaintenance == nil else { throw Failure.cookieMaintenancePending }
        guard tabs.count + pendingChatGPTInferenceCookiePreparationCount < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
        let source = dataStore(), isolated = WKWebsiteDataStore.nonPersistent(), reservation = UUID()
        let seed: ChatGPTInferenceCookieSeed
        #if DEBUG
        seed = cookieSeedFactoryForTesting?(source, isolated)
            ?? ChatGPTInferenceCookieSeed(source: ChatGPTWKInferenceCookieStore(source), destination: ChatGPTWKInferenceCookieStore(isolated))
        #else
        seed = ChatGPTInferenceCookieSeed(source: ChatGPTWKInferenceCookieStore(source), destination: ChatGPTWKInferenceCookieStore(isolated))
        #endif
        inferenceCookieSeeds[reservation] = seed
        try await seed.run(until: deadline, isCurrent: { [weak self, weak seed] in
            guard let self, let seed else { return false }
            return !self.isShutdown && self.exclusiveCookieMaintenance == nil && self.websiteDataStore === source
                && self.inferenceCookieSeeds[reservation] === seed
        }, onDrained: { [weak self, weak seed] in
            guard let self, let seed, self.inferenceCookieSeeds[reservation] === seed else { return }
            self.inferenceCookieSeeds.removeValue(forKey: reservation)
        })
        #if DEBUG
        if let afterCookieSeedForTesting { await afterCookieSeedForTesting() }
        #endif
        try Task.checkCancellation()
        guard !isShutdown, exclusiveCookieMaintenance == nil, websiteDataStore === source else {
            throw ChatGPTInferenceCookieSeed.Failure.unavailable
        }
        // The consumer's provider gate may have changed while native cookie
        // callbacks ran. It must pass before publication or any provider load.
        try admit()
        let id = try createModelTab(initialURL: nil, isolatedChatGPTStore: isolated)
        do {
            guard let summary = seed.verifiedSummary, let entry = entries[id], entry.usesIsolatedChatGPTProfile,
                  entry.view.configuration.websiteDataStore === isolated, isolated !== source, !isolated.isPersistent else {
                throw ChatGPTInferenceCookieSeed.Failure.verificationFailed
            }
            entry.inferenceCookieSummary = summary
            if let sourceSelection, let cookies = seed.verifiedSourceCookies { sourceSelection(source, cookies) }
            if let requestMetadata { _ = installModelRequestMetadata(requestMetadata, tabID: id) }
            try navigate(tabID: id, to: URL(string: "https://chatgpt.com/")!)
            return id
        } catch { closeTab(id); requestMetadata?.revoke(); throw error }
    }

    func chatGPTInferenceCookieSummary(tabID: UUID, view: WKWebView) -> ChatGPTInferenceCookieSeed.Summary? {
        guard let entry = entries[tabID], entry.isModelOwned, entry.usesIsolatedChatGPTProfile, entry.view === view,
              entry.view.configuration.websiteDataStore !== websiteDataStore else { return nil }
        return entry.inferenceCookieSummary
    }

    #if DEBUG
    private var geminiCookieObservationReaderForTesting: (@MainActor (WKHTTPCookieStore, @escaping @MainActor @Sendable ([HTTPCookie]) -> Void) -> Void)?
    private var geminiCookieObservationSinkForTesting: (@MainActor (GeminiVerificationCookieObservation) -> Void)?
    private var geminiCookieTimelineSinkForTesting: (@MainActor (GeminiVerificationCookieTimeline.Event) -> Void)?

    func setGeminiCookieTimelineSinkForTesting(_ sink: @escaping @MainActor (GeminiVerificationCookieTimeline.Event) -> Void) {
        geminiCookieTimelineSinkForTesting = sink
    }

    func setGeminiCookieObservationForTesting(
        reader: @escaping @MainActor (WKHTTPCookieStore, @escaping @MainActor @Sendable ([HTTPCookie]) -> Void) -> Void,
        sink: @escaping @MainActor (GeminiVerificationCookieObservation) -> Void) {
        geminiCookieObservationReaderForTesting = reader
        geminiCookieObservationSinkForTesting = sink
    }

    private var modelViewFactoryForTesting: (@MainActor (WKWebViewConfiguration) -> WKWebView)?
    private var responseCompletionSourceForTesting: String?
    private var cookieSeedFactoryForTesting: (@MainActor (WKWebsiteDataStore, WKWebsiteDataStore) -> ChatGPTInferenceCookieSeed)?
    private var afterCookieSeedForTesting: (@MainActor () async -> Void)?
    private var cookieValidationSourceForTesting: (@MainActor (WKWebsiteDataStore) -> any ChatGPTInferenceCookieSource)?
    private var prewarmLifetimeForTesting: Duration?
    private(set) var lastInferencePrewarmUnavailableForTesting: String?
    var afterChatGPTNavigationGateForTesting: (@MainActor () -> Void)?
    var cacheIdentityRemovalForTesting: EmbeddedBrowserCacheIdentity.Removal?
    private(set) var lastChatGPTNavigationDenialForTesting: String?

    /// Changes only the fixture's page observer source. All native admission,
    /// message, generation and final response guards remain the real path.
    func setChatGPTResponseCompletionSourceForTesting(_ source: String?) {
        responseCompletionSourceForTesting = source
    }

    func admitChatGPTNavigationForTesting(tabID: UUID, view: WKWebView, url: URL) async -> Bool {
        guard let admission = beginChatGPTNavigationAdmission(view, tabID: tabID, url: url) else { return false }
        return await admitChatGPTNavigation(view, tabID: tabID, url: url, admission: admission)
    }

    func admitCacheIdentityForTesting(tabID: UUID, view: WKWebView, url: URL,
                                      until deadline: ContinuousClock.Instant) async -> CacheNavigationAdmission {
        protectPendingConversation(view, tabID: tabID, url: url)
        return await admitCacheIdentity(view, tabID: tabID, url: url, until: deadline)
    }

    func setCookieValidationSourceForTesting(_ factory: (@MainActor (WKWebsiteDataStore) -> any ChatGPTInferenceCookieSource)?) {
        cookieValidationSourceForTesting = factory
    }

    func awaitChatGPTInferencePrewarmForTesting() async -> UUID? { await chatGPTInferencePrewarm?.task?.value }
    func awaitChatGPTInferencePrewarmResumeForTesting() async -> UUID? {
        await chatGPTInferencePrewarm?.resumeTask?.value
        return await chatGPTInferencePrewarm?.task?.value
    }
    var chatGPTInferencePrewarmClaimedForTesting: Bool { chatGPTInferencePrewarm?.claimed == true }
    func setChatGPTInferencePrewarmLifetimeForTesting(_ lifetime: Duration) { prewarmLifetimeForTesting = lifetime }
    func expireChatGPTInferencePrewarmForTesting() {
        if let warm = chatGPTInferencePrewarm { discardInferencePrewarm(warm) }
    }

    func setAfterCookieSeedForTesting(_ hook: (@MainActor () async -> Void)?) { afterCookieSeedForTesting = hook }

    var pendingInferenceCookieSeedsForTesting: Int { inferenceCookieSeeds.count }
    func setCookieSeedFactoryForTesting(_ factory: (@MainActor (WKWebsiteDataStore, WKWebsiteDataStore) -> ChatGPTInferenceCookieSeed)?) {
        cookieSeedFactoryForTesting = factory
    }

    func setModelViewFactoryForTesting(_ factory: (@MainActor (WKWebViewConfiguration) -> WKWebView)?) {
        modelViewFactoryForTesting = factory
    }

    /// Fixtures load one local document themselves. Starting about:blank first
    /// would leave two competing provisional navigations in the same WebView.
    func createUnloadedModelTabForTesting(isolatedChatGPTProfile: Bool = false, qwenCodePayload: Bool = false,
                                         viewFactory: (@MainActor (WKWebViewConfiguration) -> WKWebView)? = nil) throws -> UUID {
        modelViewFactoryForTesting = viewFactory
        defer { modelViewFactoryForTesting = nil }
        let id = try createModelTab(initialURL: nil, isolatedChatGPTStore: isolatedChatGPTProfile ? .nonPersistent() : nil)
        if qwenCodePayload { try installQwenCodePayload(tabID:id) }
        return id
    }
    #endif

    private func createModelTab(initialURL: URL?, isolatedChatGPTStore: WKWebsiteDataStore? = nil) throws -> UUID {
        let id = try createTab(select: false, modelOwned: true, isolatedChatGPTStore: isolatedChatGPTStore)
        do {
            guard let view = webView(for: id) else { throw Failure.tabClosed }
            if let entry = entries[id] { installResponseCompletionObserver(entry) }
            view.frame = NSRect(x: 0, y: 0, width: 1_024, height: 768)
            if let entry = entries[id] { mountModelView(entry) }
            if let initialURL {
                if initialURL.absoluteString == "https://chat.qwen.ai/" { try installQwenCodePayload(tabID:id) }
                try navigate(tabID: id, to: initialURL)
            }
            return id
        } catch {
            closeTab(id)
            throw error
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
        cancelModelNativeFocusDiagnostic()
        #endif
        isShutdown = true
        geminiCookieTimeline?.stop()
        geminiCookieTimeline = nil
        cacheIdentity?.close()
        chatGPTInferencePrewarmingEnabled = false
        chatGPTInferencePrewarmAdmission = nil
        if let warm = chatGPTInferencePrewarm { discardInferencePrewarm(warm) }
        for seed in Array(inferenceCookieSeeds.values) { seed.cancel() }
        for validation in Array(inferenceCookieValidations.values) { validation.cancel() }
        onHumanVerificationRecoveryCandidate = nil
        for id in tabs.map(\.id) { closeTab(id) }
        temporaryCookieRetirement?.stop()
        modelRenderHost = nil
        modelRenderHosts.removeAll()
        websiteDataStore = nil
        cacheIdentity = nil
    }

    private func entry(_ id: UUID) throws -> Entry {
        guard !isShutdown else { throw Failure.sessionClosed }
        guard let entry = entries[id] else { throw Failure.tabClosed }
        return entry
    }

    private func prepareNavigation(_ entry: Entry, replacesDocument: Bool = false, claudeInitialStart: Bool = false) {
        entry.pendingCacheAdmission = nil
        entry.delegate.cancelCacheAdmission()
        entry.pendingConversationAdmission = nil
        revokeResponseCompletion(entry)
        if entry.requestMetadataDiagnostic?.generation != nil { revokeRequestMetadata(entry) }
        if let probe = entry.groqStatus {
            if claudeInitialStart && !probe.initialStart {probe.initialStart=true}
            else if !probe.initialPreparation && !probe.initialStart && entry.view.url==nil && entry.navigation==nil {probe.initialPreparation=true}
            else {removeGroqStatus(entry)}
        }
        if let probe = entry.qwenMarkerProbe {
            if claudeInitialStart && !probe.initialStart { probe.initialStart = true }
            else if !probe.initialPreparation && !probe.initialStart && entry.view.url == nil && entry.navigation == nil { probe.initialPreparation = true }
            else { removeQwenMarker(entry) }
        }
        if let diagnostic = entry.claudeResponseStreamDiagnostic {
            if claudeInitialStart, !diagnostic.initialNavigationStarted {
                // The one initial owned navigation injects the dormant script.
                diagnostic.initialNavigationStarted = true
            } else if !diagnostic.initialNavigationPrepared, !diagnostic.initialNavigationStarted,
                      entry.view.url == nil, entry.navigation == nil {
                diagnostic.initialNavigationPrepared = true
            } else { revokeClaudeResponseStream(entry) }
        } else if entry.claudeResponseStreamLease != nil {
            revokeClaudeResponseStream(entry)
        }
        revokeModelInspector(entry, reason: .navigation)
        resetModelNavigationDiagnostic(entry)
        entry.recoverySettledGeneration = nil
        entry.tab.documentID = UUID()
        entry.preparedDocumentNavigation = replacesDocument
        if replacesDocument { entry.tab.documentGeneration = UUID() }
        entry.tab.error = nil
        entry.tab.isLoading = true
        signalModelChange(entry)
        if selectedTabID == entry.tab.id { errorMessage = nil }
    }

    private func resetModelNavigationDiagnostic(_ entry: Entry) {
        entry.modelCommittedGeneration = nil
        entry.modelFinishedGeneration = nil
        entry.modelFailedGeneration = nil
        entry.modelNavigationGeneration = nil
        entry.serverRedirectObservedInCurrentNavigation = false
    }

    private func observe(_ entry: Entry) {
        let id = entry.tab.id
        let refresh: @Sendable () -> Void = { [weak self, weak view = entry.view] in
            Task { @MainActor in
                guard let self, let view, self.entries[id]?.view === view else { return }
                self.refresh(id, view: view)
            }
        }
        entry.observations = [
            entry.view.observe(\.title, options: [.new]) { _, _ in refresh() },
            entry.view.observe(\.url, options: [.new]) { _, _ in refresh() },
            entry.view.observe(\.isLoading, options: [.new]) { _, _ in refresh() },
            entry.view.observe(\.canGoBack, options: [.new]) { _, _ in refresh() },
            entry.view.observe(\.canGoForward, options: [.new]) { _, _ in refresh() },
        ]
    }

    private func refresh(_ id: UUID, view: WKWebView, committedNavigation: Bool = false) {
        guard let entry = entries[id], entry.view === view else { return }
        if let probe=entry.groqStatus,let url=view.url,url != probe.url {removeGroqStatus(entry)}
        if let probe = entry.qwenMarkerProbe, let url = view.url, !probe.allows(url) { removeQwenMarker(entry) }
        if let diagnostic = entry.claudeResponseStreamDiagnostic, view.url != nil,
           !claudeResponseStreamRouteCurrent(entry, diagnostic: diagnostic) { revokeClaudeResponseStream(entry) }
        if entry.responseCompletion != nil, !Self.responseCompletionURLAllowed(view.url) { revokeResponseCompletion(entry) }
        if entry.inspectorDiagnostic != nil, !Self.inspectorOriginAllowed(view.url) { revokeModelInspector(entry, reason: .origin) }
        let title = view.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        entry.tab.title = title.isEmpty ? (view.url?.host ?? "New tab") : String(title.prefix(512))
        // Includes history.pushState/fragment navigation. This is intentionally conservative;
        // a document identity is not proof that arbitrary DOM content has remained unchanged.
        if entry.tab.url != view.url { entry.tab.documentID = UUID() }
        entry.tab.url = view.url
        entry.tab.isLoading = view.isLoading
        entry.tab.canGoBack = view.canGoBack
        entry.tab.canGoForward = view.canGoForward
        // A provisional load can still expose the old page URL. Observe the
        // committed document or settled native URL without inspecting its DOM.
        if !entry.isModelOwned, committedNavigation || !view.isLoading {
            observeHumanVerificationCheckpoint(entry)
            if entry.recoverySettledGeneration == entry.tab.documentGeneration { observeHumanVerificationRecovery(entry) }
        }
        signalModelChange(entry)
        emitGeminiPostBlockNativeEvent(entry, .changed)
        temporaryCookieRetirement?.requestSweep()
    }

    private func observeHumanVerificationCheckpoint(_ entry: Entry) {
        guard let provider = EmbeddedHumanVerificationStore.provider(forTrustedHumanURL: entry.view.url) else {
            entry.humanCheckpointDocumentID = nil
            entry.humanCheckpointURL = nil
            return
        }
        guard entry.humanCheckpointDocumentID != entry.humanCommittedDocumentID
                || entry.humanCheckpointURL != entry.view.url else { return }
        entry.humanCheckpointDocumentID = entry.humanCommittedDocumentID
        entry.humanCheckpointURL = entry.view.url
        recordHumanVerificationRequired(provider: provider, renewObservation: true)
        if provider == "gemini" {
            captureGeminiCAPTCHA(tabID: entry.tab.id, view: entry.view, trigger: .humanCheckpoint)
        }
    }

    fileprivate func owns(_ view: WKWebView, tabID: UUID) -> Bool { entries[tabID]?.view === view }

    enum CacheNavigationAdmission { case allowed, cancelled, timedOut }

    fileprivate func needsCacheIdentityAdmission(_ view: WKWebView, url: URL) -> Bool {
        persistent && view.configuration.websiteDataStore === websiteDataStore
            && ["http", "https"].contains(url.scheme?.lowercased() ?? "") && cacheIdentity?.ready == false
    }

    fileprivate func admitCacheIdentity(_ view: WKWebView, tabID: UUID, url: URL,
                                        until deadline: ContinuousClock.Instant) async -> CacheNavigationAdmission {
        guard !isShutdown, !Task.isCancelled, let entry = entries[tabID], entry.view === view else { return .cancelled }
        // Isolated model profiles and nonpersistent sessions have no legacy
        // shared-profile HTTP responses. Never clear a supplied foreign store.
        guard needsCacheIdentityAdmission(view, url: url), let cacheIdentity else { return .allowed }
        let ticket = UUID(), generation = entry.tab.documentGeneration
        entry.pendingCacheAdmission = (ticket, generation)
        let ready = await cacheIdentity.wait(until: deadline)
        guard !isShutdown, !Task.isCancelled, entries[tabID] === entry, entry.view === view,
              entry.pendingCacheAdmission?.id == ticket, entry.tab.documentGeneration == generation,
              entry.pendingConversationURL == url else { return .cancelled }
        entry.pendingCacheAdmission = nil
        guard ready else {
            entry.tab.isLoading = false
            entry.navigation = nil
            entry.preparedDocumentNavigation = false
            report("The browser cache update did not finish in time. Try opening the page again. No navigation was replayed.", tabID: tabID)
            signalModelChange(entry)
            return .timedOut
        }
        return .allowed
    }

    fileprivate func protectPendingConversation(_ view: WKWebView, tabID: UUID, url: URL) {
        guard let entry = entries[tabID], entry.view === view else { return }
        entry.pendingConversationURL = url
        entry.pendingConversationAdmission = nil
    }

    fileprivate func beginChatGPTNavigationAdmission(_ view: WKWebView, tabID: UUID, url: URL) -> UUID? {
        guard let entry = entries[tabID], entry.view === view else { return nil }
        let id = UUID()
        entry.pendingConversationURL = url
        entry.pendingConversationAdmission = (id, entry.tab.documentGeneration)
        return id
    }

    fileprivate func admitChatGPTNavigation(_ view: WKWebView, tabID: UUID, url: URL, admission: UUID) async -> Bool {
        guard let entry = entries[tabID], entry.view === view else {
            recordChatGPTNavigationDenial(reason: "entry_or_view", gateChecked: false); return false
        }
        guard let pending = entry.pendingConversationAdmission, pending.id == admission else {
            recordChatGPTNavigationDenial(reason: "ticket", gateChecked: false, entryCurrent: true); return false
        }
        let permitted = await admitChatGPTAfterCookieCallbacks(until: .now + .seconds(2))
        #if DEBUG
        afterChatGPTNavigationGateForTesting?()
        #endif
        let entryCurrent = entries[tabID] === entry && entry.view === view
        let targetMatches = entryCurrent && entry.pendingConversationURL == url
        let ticketMatches = entryCurrent && entry.pendingConversationAdmission?.id == admission
        let generationMatches = entryCurrent && entry.tab.documentGeneration == pending.generation
        if permitted && entryCurrent && targetMatches && ticketMatches && generationMatches { return true }
        let reason = !permitted ? "cookie_gate" : !entryCurrent ? "entry_or_view"
            : !targetMatches ? "pending_target" : !ticketMatches ? "ticket" : "generation"
        recordChatGPTNavigationDenial(reason: reason, gateChecked: true, cookieGatePermitted: permitted,
            entryCurrent: entryCurrent, targetMatches: targetMatches, ticketMatches: ticketMatches, generationMatches: generationMatches)
        return false
    }

    private func recordChatGPTNavigationDenial(reason: String, gateChecked: Bool, cookieGatePermitted: Bool = false,
                                              entryCurrent: Bool = false, targetMatches: Bool = false,
                                              ticketMatches: Bool = false, generationMatches: Bool = false) {
        let diagnostic = "reason=\(reason) gateChecked=\(gateChecked) cookieGatePermitted=\(cookieGatePermitted) entryCurrent=\(entryCurrent) pendingTargetMatches=\(targetMatches) ticketMatches=\(ticketMatches) generationMatches=\(generationMatches)"
        Self.inferencePrewarmLog.notice("chatGPTNavigationAdmissionDenied \(diagnostic, privacy: .public)")
        #if DEBUG
        lastChatGPTNavigationDenialForTesting = diagnostic
        #endif
    }

    fileprivate func report(_ message: String, tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        entry.tab.error = message
        if selectedTabID == tabID { errorMessage = message }
    }

    private func recordGeminiDiagnosticCookieEvent(_ event: GeminiVerificationCookieTimeline.Event) {
        // Historical metadata only. Never start an extra cookie read or wait
        // for one here; an absent/currently pending sample remains unknown.
        geminiDiagnosticCookieEvents.append(.init(date: Date(), event: event))
        if geminiDiagnosticCookieEvents.count > GeminiCAPTCHADiagnostic.maximumCookieEvents {
            geminiDiagnosticCookieEvents.removeFirst()
            if geminiDiagnosticCookieEventsDropped < Int.max { geminiDiagnosticCookieEventsDropped += 1 }
        }
    }

    fileprivate func observeGeminiNavigationRequest(_ request: URLRequest, isMainFrame: Bool,
                                                    view: WKWebView, tabID: UUID) {
        guard !isShutdown, isMainFrame, let entry = entries[tabID], entry.view === view else { return }
        entry.geminiDiagnosticJournal.recordRequest(request, generation: entry.tab.documentGeneration, now: Date())
    }

    /// Observation, not admission/cleanup authority. Call only for an observed
    /// challenge on this exact view, never for propagation of a saved gate.
    /// Synchronous persistence makes the save acknowledgment precede teardown,
    /// including cancellation and shutdown; no page evaluation or retry occurs.
    func captureGeminiCAPTCHA(tabID: UUID, view: WKWebView, trigger: GeminiCAPTCHADiagnostic.Trigger) {
        guard let entry = entries[tabID], entry.view === view else { return }
        #if DEBUG
        guard geminiDiagnosticDirectory != nil || geminiDiagnosticWriterForTesting != nil else { return }
        #else
        guard geminiDiagnosticDirectory != nil else { return }
        #endif
        let generation = entry.tab.documentGeneration
        let closingPreviousIncident = trigger == .beforeClose && entry.geminiDiagnosticIncident != nil
        // A transport/native observation can win the race with a response
        // callback. Preserve its first report, then save at most one linked
        // supplement if the actual challenge response arrives before teardown.
        let precedingCaptureID = trigger == .response
            && entry.geminiDiagnosticIncident?.generation == generation
            && entry.geminiDiagnosticIncident?.report.trigger != .response
            ? entry.geminiDiagnosticIncident?.report.id : nil
        if (entry.geminiDiagnosticIncident?.generation != generation && !closingPreviousIncident)
            || precedingCaptureID != nil {
            let native: GeminiCAPTCHADiagnostic.NativeState? = entry.isModelOwned ? .init(
                loading: view.isLoading, pending: entry.navigation != nil,
                committed: entry.modelCommittedGeneration == generation,
                finished: entry.modelFinishedGeneration == generation,
                navigationError: entry.modelFailedGeneration == generation) : nil
            let report = entry.geminiDiagnosticJournal.report(tabID: tabID, generation: generation,
                role: entry.isToolOwned ? .tool : entry.isModelOwned ? .model : .human,
                trigger: trigger, now: Date(), cookieEvents: geminiDiagnosticCookieEvents, nativeState: native,
                earlierCookieEventsDropped: geminiDiagnosticCookieEventsDropped, precedingCaptureID: precedingCaptureID)
            entry.geminiDiagnosticIncident = (generation, report, 0, false)
        }
        guard var incident = entry.geminiDiagnosticIncident, !incident.saved, incident.attempts < 2 else { return }
        // A disk failure gets one retry at teardown, with the same immutable
        // evidence. Repeated polls cannot repeatedly write or extend page life.
        guard incident.attempts == 0 || trigger == .beforeClose else { return }
        let now = ContinuousClock.now
        geminiDiagnosticSaveInstants.removeAll { now - $0 >= .seconds(60) }
        guard geminiDiagnosticSaveInstants.count < 8 else {
            Self.inferencePrewarmLog.error("geminiCAPTCHADiagnostic result=not_saved reason=rate_limit trigger=\(trigger.rawValue, privacy: .public)")
            return
        }
        geminiDiagnosticSaveInstants.append(now)
        incident.attempts += 1
        do {
            #if DEBUG
            if let writer = geminiDiagnosticWriterForTesting { _ = try writer(incident.report) }
            else if let directory = geminiDiagnosticDirectory {
                _ = try GeminiCAPTCHADiagnosticStore(directory: directory).save(incident.report)
            }
            #else
            if let directory = geminiDiagnosticDirectory {
                _ = try GeminiCAPTCHADiagnosticStore(directory: directory).save(incident.report)
            }
            #endif
            incident.saved = true
            Self.inferencePrewarmLog.notice("geminiCAPTCHADiagnostic incident=\(incident.report.id.uuidString.lowercased(), privacy: .public) result=saved trigger=\(trigger.rawValue, privacy: .public) beforeTeardown=true")
        } catch {
            // Never include arbitrary filesystem error text, paths or page
            // content, and never replace the original model/verification error.
            Self.inferencePrewarmLog.error("geminiCAPTCHADiagnostic incident=\(incident.report.id.uuidString.lowercased(), privacy: .public) result=not_saved reason=storage_failure trigger=\(trigger.rawValue, privacy: .public)")
        }
        entry.geminiDiagnosticIncident = incident
    }

    #if DEBUG
    func setGeminiCAPTCHADiagnosticWriterForTesting(_ writer: @escaping (GeminiCAPTCHADiagnostic.Report) throws -> URL) {
        geminiDiagnosticWriterForTesting = writer
    }

    func observeGeminiNavigationRequestForTesting(_ request: URLRequest, isMainFrame: Bool,
                                                view: WKWebView, tabID: UUID) {
        observeGeminiNavigationRequest(request, isMainFrame: isMainFrame, view: view, tabID: tabID)
    }
    #endif

    /// A small callback-time sample, not a complete redirect trace. WebKit's
    /// response-policy callback supplies neither a navigation token nor cache
    /// provenance or the outgoing Cookie header. No observation affects policy.
    fileprivate func observeGeminiNavigationResponse(_ response: URLResponse, isMainFrame: Bool,
                                                     view: WKWebView, tabID: UUID) {
        guard !isShutdown, isMainFrame, let entry = entries[tabID], entry.view === view else { return }
        let generation = entry.tab.documentGeneration
        // The bounded durable journal is independent of the OSLog rate limit.
        // A busy log window must not hide the response that actually failed.
        entry.geminiDiagnosticJournal.recordResponse(response, generation: generation, now: Date())
        if EmbeddedHumanVerificationStore.provider(forTrustedHumanURL: response.url) == "gemini" {
            captureGeminiCAPTCHA(tabID: tabID, view: view, trigger: .response)
        }
        if entry.geminiResponseObservationGeneration != generation {
            entry.geminiResponseObservationGeneration = generation
            entry.geminiResponseObservationsInGeneration = 0
        }
        guard entry.geminiResponseObservationsInGeneration < 2 else { return }
        let instant = geminiResponseObservationClock()
        geminiResponseObservationInstants.removeAll { instant - $0 >= .seconds(60) }
        guard geminiResponseObservationInstants.count < 12,
              let snapshot = GeminiNavigationResponseDiagnostic.project(response: response, now: Date()),
              let data = snapshot.logData() else { return }
        let sample = entry.geminiResponseObservationsInGeneration + 1
        let role = entry.isToolOwned ? "tool" : entry.isModelOwned ? "model" : "human"
        let message = "geminiNavigationResponse tab=\(tabID.uuidString.lowercased()) generation=\(generation.uuidString.lowercased()) role=\(role) sample=\(sample) \(String(decoding: data, as: UTF8.self))"
        guard message.utf8.count <= 1_000 else { return }
        entry.geminiResponseObservationsInGeneration = sample
        geminiResponseObservationInstants.append(instant)
        Self.inferencePrewarmLog.notice("\(message, privacy: .public)")
        #if DEBUG
        geminiResponseObserverForTesting?(message)
        #endif
    }

    #if DEBUG
    func setGeminiNavigationResponseObserverForTesting(_ observer: (@MainActor (String) -> Void)?) {
        geminiResponseObserverForTesting = observer
    }

    func setGeminiNavigationResponseClockForTesting(_ clock: @escaping @MainActor () -> ContinuousClock.Instant) {
        geminiResponseObservationClock = clock
    }

    func observeGeminiNavigationResponseForTesting(response: URLResponse, isMainFrame: Bool,
                                                  view: WKWebView, tabID: UUID) {
        observeGeminiNavigationResponse(response, isMainFrame: isMainFrame, view: view, tabID: tabID)
    }
    #endif

    fileprivate func started(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view else { return }
        // A native load/reload invalidates synchronously, before WebKit starts it.
        // Page-initiated full navigations advance here; pushState does not arrive here.
        let prepared = entry.preparedDocumentNavigation && entry.navigation === navigation
        let prior = entry.tab.documentGeneration
        let exactRoot = !prepared && navigation != nil && entry.isModelOwned && entry.usesIsolatedChatGPTProfile
            && !entry.hadChatRootDiagnostic && !entry.view.isInspectable && entry.authorizedChatRootRequest == prior
            && entry.pendingConversationURL?.absoluteString == "https://chatgpt.com/"
            && entry.view.url?.absoluteString == "https://chatgpt.com/"
        prepareNavigation(entry, claudeInitialStart: true)
        if !prepared { entry.tab.documentGeneration = UUID() }
        entry.authorizedChatRootRequest = nil
        entry.initialChatRootTransition = exactRoot ? (prior, entry.tab.documentGeneration) : nil
        entry.navigation = navigation
        if entry.isModelOwned, navigation != nil {
            entry.modelNavigationGeneration = entry.tab.documentGeneration
        }
        refresh(tabID, view: view)
        emitGeminiPostBlockNativeEvent(entry, .started)
    }

    fileprivate func serverRedirected(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID) {
        if let entry = entries[tabID], entry.view === view, let navigation, entry.navigation === navigation,
           GeminiNavigationResponseDiagnostic.destination(entry.pendingConversationURL ?? view.url) != nil {
            entry.geminiDiagnosticJournal.recordRedirect(generation: entry.tab.documentGeneration, now: Date())
        }
        guard let entry = entries[tabID], entry.isModelOwned, entry.view === view,
              let navigation, entry.navigation === navigation,
              entry.modelNavigationGeneration == entry.tab.documentGeneration,
              entry.modelCommittedGeneration != entry.tab.documentGeneration,
              entry.modelFinishedGeneration != entry.tab.documentGeneration,
              entry.modelFailedGeneration != entry.tab.documentGeneration else { return }
        removeGroqStatus(entry)
        removeQwenMarker(entry)
        entry.initialChatRootTransition = nil
        entry.serverRedirectObservedInCurrentNavigation = true
        emitGeminiPostBlockNativeEvent(entry, .redirected)
    }

    fileprivate func completed(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID, error: Error? = nil) {
        guard let entry = entries[tabID], entry.view === view, entry.navigation === navigation else { return }
        if entry.isModelOwned, navigation != nil {
            if error == nil, entry.modelCommittedGeneration == entry.tab.documentGeneration {
                entry.modelFinishedGeneration = entry.tab.documentGeneration
            } else if error != nil {
                entry.modelFailedGeneration = entry.tab.documentGeneration
            }
        }
        entry.navigation = nil
        entry.pendingConversationURL = nil
        entry.preparedDocumentNavigation = false
        refresh(tabID, view: view)
        entry.tab.isLoading = false
        if let error, (error as NSError).code != NSURLErrorCancelled {
            report("The page could not load. \(error.localizedDescription)", tabID: tabID)
        }
        if error == nil, let navigation, entry.humanCommittedNavigation === navigation,
           entry.recoveryCommittedGeneration == entry.tab.documentGeneration {
            entry.recoverySettledGeneration = entry.tab.documentGeneration
            observeHumanVerificationRecovery(entry)
        }
        emitGeminiPostBlockNativeEvent(entry, error == nil ? .finished : .failed)
        if error == nil, navigation != nil,
           entry.isModelOwned ? entry.modelFinishedGeneration == entry.tab.documentGeneration
                : entry.recoverySettledGeneration == entry.tab.documentGeneration {
            observeGeminiVerificationCookies(entry)
            observeGeminiCookieTimelineAfterNavigation(entry)
        }
    }

    fileprivate func committed(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view, entry.navigation === navigation else { return }
        if entry.isModelOwned, navigation != nil {
            entry.modelCommittedGeneration = entry.tab.documentGeneration
            if entry.modelNavigationGeneration == entry.tab.documentGeneration,
               let url = view.url, EmbeddedWebModelTransport.Provider.gemini.accepts(url.absoluteString) {
                entry.geminiDocumentCommitObserved = true
            }
        }
        if !entry.isModelOwned, let navigation, entry.humanCommittedNavigation !== navigation {
            entry.humanCommittedNavigation = navigation
            entry.humanCommittedDocumentID = UUID()
            entry.recoveryCommittedGeneration = entry.tab.documentGeneration
            entry.recoveryToolUsed = entry.toolPopupContext != nil
            entry.toolPopupContext = nil
            entry.tab.isWebInspectorAvailable = !entry.isToolOwned
        }
        refresh(tabID, view: view, committedNavigation: true)
        emitGeminiPostBlockNativeEvent(entry, .committed)
    }

    fileprivate func terminated(_ view: WKWebView, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view else { return }
        revokeResponseCompletion(entry)
        removeGroqStatus(entry)
        removeQwenMarker(entry)
        revokeClaudeResponseStream(entry)
        revokeModelInspector(entry, reason: .navigation)
        resetModelNavigationDiagnostic(entry)
        entry.navigation = nil
        entry.preparedDocumentNavigation = false
        entry.tab.documentID = UUID()
        entry.tab.documentGeneration = UUID()
        entry.tab.isLoading = false
        report("The web content process stopped. Reload this tab to recover; no action was replayed.", tabID: tabID)
        signalModelChange(entry)
        emitGeminiPostBlockNativeEvent(entry, .terminated)
    }
}

/// DOM focus is needed for the fixed editor adapter, but must never acquire
/// the application's native first responder, including during reparenting.
@MainActor
private final class EmbeddedModelWebView: WKWebView {
    /// Human tabs use normal WebKit focus until a render lease temporarily
    /// borrows the same view. Final release restores ordinary presentation.
    var protectsNativeFocus = true {
        didSet {
            guard !protectsNativeFocus else { return }
            NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
            focusWindow = nil; focusResponder = nil; focusField = nil; focusFieldEditor = nil
            focusFieldText = nil; focusFieldSelection = nil
        }
    }
    private weak var focusWindow: NSWindow?
    private weak var focusResponder: NSResponder?
    private weak var focusField: NSTextField?
    private weak var focusFieldEditor: NSTextView?
    private var focusFieldText: String?
    private var focusFieldSelection: NSRange?
    private var restoringFocus = false

    #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
    private var nativeFocusDiagnosticActive = false
    private var nativeFocusDiagnosticOnEnd: (() -> Void)?
    enum NativeFocusDiagnosticRejection: String {
        case none, active, unattached, hidden, notKeyWindow = "not_key_window"
        case responderUnavailable = "responder_unavailable", alreadyOwned = "already_owned"
        case snapshotChanged = "snapshot_changed", acquisitionFailed = "acquisition_failed"
    }
    private(set) var nativeFocusDiagnosticRejection: NativeFocusDiagnosticRejection = .none

    /// The session calls this only inside one exact synthetic capture's activation.
    /// Neither the window nor this view is activated, reordered or reparented.
    func beginNativeFocusDiagnostic(onEnd: @escaping () -> Void) -> Bool {
        nativeFocusDiagnosticRejection = .none
        guard !nativeFocusDiagnosticActive else { nativeFocusDiagnosticRejection = .active; return false }
        guard let target = window else { nativeFocusDiagnosticRejection = .unattached; return false }
        guard target.isKeyWindow else { nativeFocusDiagnosticRejection = .notKeyWindow; return false }
        guard !isHiddenOrHasHiddenAncestor else { nativeFocusDiagnosticRejection = .hidden; return false }
        guard let responder = target.firstResponder else { nativeFocusDiagnosticRejection = .responderUnavailable; return false }
        guard !ownsResponder(responder) else { nativeFocusDiagnosticRejection = .alreadyOwned; return false }
        captureNativeFocus(in: target)
        guard focusWindow === target, focusResponder === responder else {
            nativeFocusDiagnosticRejection = .snapshotChanged; return false
        }
        nativeFocusDiagnosticActive = true
        guard target.makeFirstResponder(self), nativeFocusDiagnosticActive, window === target, target.isKeyWindow,
              let current = target.firstResponder, ownsResponder(current) else {
            // A failed AppKit acquisition can leave the window itself as
            // responder. Restore that fallback without replacing a newer human.
            nativeFocusDiagnosticRejection = .acquisitionFailed
            finishNativeFocusDiagnostic(allowWindowFallback: true)
            return false
        }
        nativeFocusDiagnosticOnEnd = onEnd
        return true
    }

    func endNativeFocusDiagnostic() {
        guard nativeFocusDiagnosticActive else { return }
        finishNativeFocusDiagnostic(allowWindowFallback: false)
    }

    private func finishNativeFocusDiagnostic(allowWindowFallback: Bool) {
        let onEnd = nativeFocusDiagnosticOnEnd
        nativeFocusDiagnosticOnEnd = nil
        nativeFocusDiagnosticActive = false
        restoreNativeFocus(allowWindowFallback: allowWindowFallback)
        // A detached/disabled original control must not leave the page as the
        // responder after its diagnostic grant ends. Respect every newer human.
        if let target = window, let current = target.firstResponder, ownsResponder(current) {
            _ = target.makeFirstResponder(nil)
        }
        onEnd?()
    }
    #endif

    override var acceptsFirstResponder: Bool {
        if !protectsNativeFocus { return super.acceptsFirstResponder }
        #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
        return nativeFocusDiagnosticActive
        #else
        return false
        #endif
    }

    #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if nativeFocusDiagnosticActive, newWindow !== window { endNativeFocusDiagnostic() }
        super.viewWillMove(toWindow: newWindow)
    }
    #endif

    func captureNativeFocus(in targetWindow: NSWindow? = nil) {
        guard protectsNativeFocus else { return }
        guard let target = targetWindow ?? window, let responder = target.firstResponder,
              !ownsResponder(responder) else { return }
        focusWindow = target
        focusResponder = responder
        NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
        focusField = nil
        focusFieldEditor = nil
        focusFieldText = nil
        focusFieldSelection = nil
        guard let editor = responder as? NSTextView, editor.isFieldEditor,
              let field = editingField(for: editor, in: target) else { return }
        // The window's shared editor detaches when WebKit takes native focus.
        // Keep its stable control and current editing buffer instead of trying
        // to make that detached editor a responder again.
        focusField = field
        focusFieldEditor = editor
        rememberFieldEditing()
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(fieldEditingChanged(_:)),
                                                   name: name, object: editor)
        }
    }

    func restoreNativeFocus(allowWindowFallback: Bool = false) {
        guard protectsNativeFocus else { return }
        #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
        guard !nativeFocusDiagnosticActive else { return }
        #endif
        guard !restoringFocus, let target = window, target === focusWindow else { return }
        let current = target.firstResponder
        guard current.map({ ownsResponder($0) }) == true
                || (allowWindowFallback && (current == nil || current === target)) else { return }
        if let field = focusField {
            guard field.window === target, !field.isHiddenOrHasHiddenAncestor,
                  field.isEnabled, field.isEditable,
                  let selection = focusFieldSelection else { return }
            restoringFocus = true
            defer { restoringFocus = false }
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView,
                  target.firstResponder === editor else { return }
            if let text = focusFieldText, editor.string != text {
                // Reenter the normal editing path so SwiftUI's binding receives
                // the unsent buffer too. Restoring focus is not an undoable edit.
                let undo = editor.undoManager
                let undoWasEnabled = undo?.isUndoRegistrationEnabled == true
                if undoWasEnabled { undo?.disableUndoRegistration() }
                editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                if undoWasEnabled { undo?.enableUndoRegistration() }
            }
            let length = editor.textStorage?.length ?? 0
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            return
        }
        guard let responder = focusResponder, !ownsResponder(responder) else { return }
        // An old control detached during an await is no longer an admissible
        // focus destination; never redirect into another window.
        if let view = responder as? NSView, view.window !== target { return }
        if let responderWindow = responder as? NSWindow, responderWindow !== target { return }
        restoringFocus = true
        defer { restoringFocus = false }
        _ = target.makeFirstResponder(responder)
    }

    @objc private func fieldEditingChanged(_ notification: Notification) {
        guard !restoringFocus, let editor = notification.object as? NSTextView,
              editor === focusFieldEditor, let target = focusWindow,
              target === window, target.firstResponder === editor else { return }
        if focusField?.currentEditor() !== editor {
            // The human reused this window's shared editor for another field
            // during an awaited website action. Follow its exact current owner,
            // rather than restoring the earlier control over that newer choice.
            captureNativeFocus(in: target)
            return
        }
        rememberFieldEditing()
    }

    private func rememberFieldEditing() {
        guard let field = focusField, let editor = focusFieldEditor,
              field.window === focusWindow, field.currentEditor() === editor else { return }
        // A secure control retains its own contents. Never copy its plaintext
        // into a model view's focus snapshot or synthesize a password insertion.
        focusFieldText = field is NSSecureTextField ? nil : editor.string
        focusFieldSelection = editor.selectedRange()
    }

    private func editingField(for editor: NSTextView, in target: NSWindow) -> NSTextField? {
        if let field = editor.delegate as? NSTextField, field.window === target,
           field.currentEditor() === editor { return field }
        // SwiftUI may use a delegate proxy. Match the actual current editor in
        // this window, rather than guessing a control from its class or label.
        var pending = target.contentView.map { [$0] } ?? []
        var inspected = 0
        while let view = pending.popLast(), inspected < 2_048 {
            inspected += 1
            if let field = view as? NSTextField, field.currentEditor() === editor { return field }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    override func becomeFirstResponder() -> Bool {
        if !protectsNativeFocus { return super.becomeFirstResponder() }
        #if DEBUG || COMPUTA_NATIVE_FOCUS_DIAGNOSTIC
        if nativeFocusDiagnosticActive { return super.becomeFirstResponder() }
        #endif
        // NSWindow has already installed this responder at this point. A
        // refusal falls back to the window, clearing the human's input. Restore
        // the exact captured responder synchronously before another key event.
        restoreNativeFocus()
        return true
    }

    private func ownsResponder(_ responder: NSResponder) -> Bool {
        responder === self || (responder as? NSView)?.isDescendant(of: self) == true
    }
}

@MainActor
private final class EmbeddedResponseCompletionHandler: NSObject, WKScriptMessageHandler {
    private weak var session: EmbeddedBrowserSession?
    private let tabID: UUID

    init(session: EmbeddedBrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receivedResponseCompletion(message, tabID: tabID)
    }
}

@MainActor
private final class EmbeddedModelSignalHandler: NSObject, WKScriptMessageHandler {
    private weak var session: EmbeddedBrowserSession?
    private let tabID: UUID

    init(session: EmbeddedBrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receivedModelSignal(message, tabID: tabID)
    }
}

@MainActor
private final class EmbeddedModelDiagnosticHandler: NSObject, WKScriptMessageHandler {
    private weak var session: EmbeddedBrowserSession?
    private let tabID: UUID

    init(session: EmbeddedBrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receivedModelDiagnostic(message, tabID: tabID)
    }
}

@MainActor
private final class EmbeddedModelClockHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var session: EmbeddedBrowserSession?
    private let tabID: UUID

    init(session: EmbeddedBrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let session else { replyHandler(nil, "model_clock_cancelled"); return }
        session.receivedModelClock(message, tabID: tabID, reply: replyHandler)
    }
}

/// Revision is recorded before inspection. A change between inspection and
/// registration returns immediately instead of disappearing into a missed wakeup.
@MainActor
final class EmbeddedModelChangeChannel {
    let ownerToken: String
    private var revision: UInt64 = 0
    private var closed = false
    private struct Waiter {
        let continuation: CheckedContinuation<UInt64, Error>
        let timeout: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]
    private var pendingDOMSignal: Task<Void, Never>?

    init(ownerToken: String) { self.ownerToken = ownerToken }
    func currentRevision() throws -> UInt64 {
        guard !closed else { throw EmbeddedBrowserSession.Failure.tabClosed }
        return revision
    }

    /// Website timers may be suspended in an inactive view. Deliver its
    /// notification immediately; batch DOM bursts on the native monotonic clock.
    /// Navigation/profile signals still wake readers synchronously via signal().
    func signalDOMChange() {
        guard !closed, pendingDOMSignal == nil else { return }
        pendingDOMSignal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let self, !self.closed else { return }
            self.pendingDOMSignal = nil
            self.signal()
        }
    }

    func signal() {
        guard !closed else { return }
        guard revision < UInt64.max else { close(); return }
        revision += 1
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.timeout.cancel(); waiter.continuation.resume(returning: revision) }
    }

    func close() {
        closed = true
        pendingDOMSignal?.cancel()
        pendingDOMSignal = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: EmbeddedBrowserSession.Failure.tabClosed)
        }
    }

    func wait(after expected: UInt64, until deadline: ContinuousClock.Instant) async throws -> UInt64 {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !closed else { throw EmbeddedBrowserSession.Failure.tabClosed }
            if revision != expected || ContinuousClock.now >= deadline { return revision }
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timeout = Task {
                    do {
                        // Callers choose the absolute deadline, including any
                        // required quiet interval; avoid extra timer leeway.
                        try await Task.sleep(until: deadline, tolerance: .zero, clock: .continuous)
                        self.complete(id, cancelled: false)
                    } catch { }
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id, cancelled: true) }
        }
    }

    private func complete(_ id: UUID, cancelled: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        if cancelled { waiter.continuation.resume(throwing: CancellationError()) }
        else { waiter.continuation.resume(returning: revision) }
    }
}

@MainActor
private final class EmbeddedBrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let policyLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "EmbeddedBrowserPolicy")
    private weak var session: EmbeddedBrowserSession?
    private let tabID: UUID
    private var cacheAdmission: (id: UUID, task: Task<Void, Never>)?

    init(session: EmbeddedBrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }
    func invalidate() { cancelCacheAdmission(); session = nil }

    func cancelCacheAdmission() {
        cacheAdmission?.task.cancel()
        cacheAdmission = nil
    }

    private func admitCacheIdentity(_ url: URL, view: WKWebView,
                                    completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        cancelCacheAdmission()
        guard session?.needsCacheIdentityAdmission(view, url: url) == true else { completion(true); return }
        let id = UUID()
        let task = Task { @MainActor [weak self, weak view] in
            guard let self, let view, let session = self.session else { completion(false); return }
            let outcome = await session.admitCacheIdentity(view, tabID: self.tabID, url: url, until: .now + .seconds(5))
            if self.cacheAdmission?.id == id { self.cacheAdmission = nil }
            // Every policy callback resolves once, including cancellation. A
            // late native clear only releases a new request, never this one.
            completion(outcome == .allowed && !Task.isCancelled)
        }
        cacheAdmission = (id, task)
    }

    private func deny(_ message: String, view: WKWebView) {
        guard session?.owns(view, tabID: tabID) == true else { return }
        session?.report(message, tabID: tabID)
    }

    private func admitChatGPT(_ url: URL, view: WKWebView,
                             completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard url.host?.lowercased() == "chatgpt.com" else { completion(true); return }
        guard let session, let ticket = session.beginChatGPTNavigationAdmission(view, tabID: tabID, url: url) else {
            completion(false); return
        }
        Task { @MainActor [weak self, weak view] in
            guard let self, let view, let session = self.session else { completion(false); return }
            let permitted = await session.admitChatGPTNavigation(view, tabID: self.tabID, url: url, admission: ticket)
            if !permitted { self.deny("The previous ChatGPT browser operation is still closing. No navigation was replayed.", view: view) }
            completion(permitted)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard session?.owns(webView, tabID: tabID) == true else { decisionHandler(.cancel); return }
        session?.observeGeminiNavigationRequest(navigationAction.request,
            isMainFrame: navigationAction.targetFrame?.isMainFrame == true, view: webView, tabID: tabID)
        if navigationAction.targetFrame?.isMainFrame ?? true {
            cancelCacheAdmission()
            session?.invalidateChatRootRequest(webView, tabID: tabID)
        }
        if navigationAction.shouldPerformDownload {
            deny("Downloads are not enabled. No file was saved.", view: webView)
            decisionHandler(.cancel)
            return
        }
        do {
            guard let url = navigationAction.request.url else { throw EmbeddedBrowserURLPolicy.Rejection.invalidAddress }
            try EmbeddedBrowserURLPolicy.validateNavigation(url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true, mainDocumentURL: webView.url)
            if navigationAction.targetFrame?.isMainFrame ?? true {
                session?.protectPendingConversation(webView, tabID: tabID, url: url)
            }
            if navigationAction.targetFrame?.isMainFrame ?? true {
                admitCacheIdentity(url, view: webView) { [weak self, weak webView] permitted in
                    guard permitted, let self, let webView else { decisionHandler(.cancel); return }
                    self.admitChatGPT(url, view: webView) { allowed in
                        if allowed { self.session?.noteAllowedChatRootRequest(navigationAction, view: webView, tabID: self.tabID) }
                        decisionHandler(allowed ? .allow : .cancel)
                    }
                }
            } else { decisionHandler(.allow) }
        } catch {
            let kind = EmbeddedBrowserURLPolicy.diagnosticAddressKind(navigationAction.request.url)
            let target = navigationAction.targetFrame.map { $0.isMainFrame ? "main" : "subframe" } ?? "new_window"
            Self.policyLog.error("navigationRejected addressKind=\(kind, privacy: .public) target=\(target, privacy: .public)")
            deny(error.localizedDescription, view: webView)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard session?.owns(webView, tabID: tabID) == true else { decisionHandler(.cancel); return }
        do {
            guard let url = navigationResponse.response.url else { throw EmbeddedBrowserURLPolicy.Rejection.invalidAddress }
            try EmbeddedBrowserURLPolicy.validateNavigation(url,
                isMainFrame: navigationResponse.isForMainFrame, mainDocumentURL: webView.url)
            if navigationResponse.isForMainFrame {
                session?.observeGeminiNavigationResponse(navigationResponse.response, isMainFrame: true,
                                                         view: webView, tabID: tabID)
                session?.protectPendingConversation(webView, tabID: tabID, url: url)
            }
        } catch {
            deny(error.localizedDescription, view: webView)
            decisionHandler(.cancel)
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        guard navigationResponse.canShowMIMEType, !disposition.lowercased().contains("attachment") else {
            deny("Downloads are not enabled. No file was saved.", view: webView)
            decisionHandler(.cancel)
            return
        }
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url {
            admitChatGPT(url, view: webView) { decisionHandler($0 ? .allow : .cancel) }
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        session?.started(webView, navigation: navigation, tabID: tabID)
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        session?.serverRedirected(webView, navigation: navigation, tabID: tabID)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        session?.committed(webView, navigation: navigation, tabID: tabID)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        session?.completed(webView, navigation: navigation, tabID: tabID)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        session?.completed(webView, navigation: navigation, tabID: tabID, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        session?.completed(webView, navigation: navigation, tabID: tabID, error: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { session?.terminated(webView, tabID: tabID) }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        deny("Downloads are not enabled. The download was cancelled.", view: webView)
        download.cancel { _ in }
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        deny("Downloads are not enabled. The download was cancelled.", view: webView)
        download.cancel { _ in }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        session?.createPopup(from: webView, tabID: tabID, configuration: configuration,
                             url: navigationAction.request.url)
    }

    func webViewDidClose(_ webView: WKWebView) { session?.closePopup(webView, tabID: tabID) }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        deny("Camera and microphone access are not enabled for this browser.", view: webView)
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        deny("File selection is not enabled. No files were shared with this page.", view: webView)
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        deny("A page alert was dismissed. This browser does not open modal page dialogs.", view: webView)
        completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        deny("A page confirmation was declined. This browser does not open modal page dialogs.", view: webView)
        completionHandler(false)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        deny("A page input dialog was declined. No input was submitted.", view: webView)
        completionHandler(nil)
    }
}

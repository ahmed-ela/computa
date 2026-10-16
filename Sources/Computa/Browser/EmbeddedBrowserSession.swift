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

/// Browser views are independent of the privileged Octane UI WebView and Chrome.
/// Human views may detach when hidden; inference views return to a render host.
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
    let maximumTabs: Int
    var pendingChatGPTInferenceCookiePreparationCount: Int { inferenceCookieSeeds.count }
    var failedChatGPTInferenceCookiePreparationCount: Int {
        inferenceCookieSeeds.values.filter(\.hasFailedCallerAwaitingCallback).count
    }

    @ObservationIgnored private var websiteDataStore: WKWebsiteDataStore?
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private let profileID: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cookieRetirementDirectory: URL?
    @ObservationIgnored private var temporaryCookieRetirement: ChatGPTTemporaryCookieRetirement?
    @ObservationIgnored private var inferenceCookieSeeds: [UUID: ChatGPTInferenceCookieSeed] = [:]
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
        var observations: [NSKeyValueObservation] = []
        var navigation: WKNavigation?
        var geminiPostBlockObservation: (lease: GeminiPostBlockNativeLease, callback: @MainActor (GeminiPostBlockNativeEvent) -> Void)?
        var preparedDocumentNavigation = false
        // Native lifecycle facts can defer an untouched initial inspection,
        // but never grant adapter, document, or recovery authority.
        var modelCommittedGeneration: UUID?
        var modelFinishedGeneration: UUID?
        var modelFailedGeneration: UUID?
        // Observation only: these never participate in readiness or quarantine.
        // A false flag means not observed, not proof that no redirect occurred.
        var modelNavigationGeneration: UUID?
        var geminiDocumentCommitObserved = false
        var serverRedirectObservedInCurrentNavigation = false
        var inspectorDiagnostic: (id: UUID, binding: ChatGPTInspectorLease.Binding, expiry: Task<Void, Never>)?
        var requestMetadataDiagnostic: RequestMetadataDiagnostic?
        var ownedTemporaryChatGPTRoutes: Set<UUID> = []
        var inferenceCookieSummary: ChatGPTInferenceCookieSeed.Summary?
        var pendingConversationURL: URL?
        var pendingConversationAdmission: (id: UUID, generation: UUID)?
        var modelChanges: EmbeddedModelChangeChannel?
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
         cookieRetirementDirectory: URL? = nil) {
        self.maximumTabs = max(1, min(maximumTabs, 32))
        self.persistent = persistent
        self.profileID = profileID
        self.defaults = defaults
        self.cookieRetirementDirectory = cookieRetirementDirectory
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
        guard !isShutdown, let entry = entries[candidate.tabID], !entry.isModelOwned, !entry.isToolOwned,
              !entry.recoveryToolUsed, entry.toolPopupContext == nil,
              entry.humanCommittedDocumentID == candidate.committedDocumentID,
              entry.tab.documentID == candidate.documentID, entry.tab.documentGeneration == candidate.documentGeneration,
              entry.recoveryCommittedGeneration == candidate.documentGeneration,
              entry.recoverySettledGeneration == candidate.documentGeneration,
              entry.navigation == nil, !entry.view.isLoading, !entry.tab.isLoading, entry.tab.error == nil,
              EmbeddedHumanVerificationStore.recoveryProvider(forTrustedHumanURL: entry.view.url) == candidate.provider,
              savedHumanVerificationCheckpointIDs[candidate.provider] == candidate.checkpointID else { return false }
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
        guard !isShutdown, entries.isEmpty, inferenceCookieSeeds.isEmpty, exclusiveCookieMaintenance == nil else { return nil }
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
            guard tabs.count + inferenceCookieSeeds.count < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
            if let url { try EmbeddedBrowserURLPolicy.validate(url) }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = isolatedChatGPTStore ?? dataStore()
            // This fresh controller has no native script handlers, scripts, or UI resource scheme.
            configuration.userContentController = WKUserContentController()
            // OAuth can open a window after an asynchronous response, beyond
            // the original click's gesture. Human popups still use the tab cap
            // and navigation policy; inference-owned pages cannot open them.
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = !modelOwned && !toolOwned
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
        guard tabs.count + inferenceCookieSeeds.count < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
        let tab = EmbeddedBrowserTab(isPopup: popupOpenerTabID != nil)
        let view: WKWebView
        #if DEBUG
        if modelOwned, let factory = modelViewFactoryForTesting { view = factory(configuration) }
        else {
            view = modelOwned || toolOwned ? EmbeddedModelWebView(frame: NSRect(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
                : WKWebView(frame: .zero, configuration: configuration)
        }
        #else
        view = modelOwned || toolOwned ? EmbeddedModelWebView(frame: NSRect(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
            : WKWebView(frame: .zero, configuration: configuration)
        #endif
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
            // WebKit owns this configuration, opener and initial navigation.
            // Return synchronously without replacing settings or loading again.
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
        guard let entry = entries.removeValue(forKey: id), let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        revokeRequestMetadata(entry)
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
        guard duration > 0, let source = Self.requestMetadataSource(),
              let config = try? JSONSerialization.data(withJSONObject: ["key": key, "durationMs": duration]),
              let configText = String(data: config, encoding: .utf8) else { authorization.revoke(); return false }
        let script = WKUserScript(source: source.replacingOccurrences(of: "__COMPUTA_REQUEST_METADATA_CONFIG__", with: configText),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        let diagnostic = RequestMetadataDiagnostic(authorization: authorization, key: key, script: script)
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
                      const text = JSON.stringify(window[key](command));
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
        guard !Task.isCancelled, entries[tabID] === entry, entry.view === view,
              entry.requestMetadataDiagnostic === diagnostic, diagnostic.authorization.isCurrent,
              entry.tab.documentGeneration == generation, diagnostic.generation == generation,
              entry.modelChanges?.ownerToken == ownerToken, Self.inspectorOriginAllowed(view.url),
              view.url?.absoluteString == expectedURL,
              let bytes, let snapshot = try? ChatGPTRequestMetadataSnapshot.parse(bytes) else { return nil }
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
            }, action: { view.isInspectable = true })
        guard activated else { return false }
        let expiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: binding.deadline, clock: .continuous) }
            catch { return }
            guard let self, let current = self.entries[tabID], current.inspectorDiagnostic?.id == id else { return }
            self.revokeModelInspector(current, reason: .expired)
        }
        entry.inspectorDiagnostic = (id, binding, expiry)
        Self.inspectorDiagnosticLog.notice("inspectorDiagnostic disposition=granted")
        return true
    }

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
        for entry in entries.values where (entry.isModelOwned || entry.isToolOwned) && entry.presentationHost == nil {
            mountModelView(entry)
        }
    }

    func removeModelRenderHost(_ host: NSView) {
        modelRenderHosts.removeAll { $0.view == nil || $0.view === host }
        if modelRenderHost === host {
            modelRenderHost = modelRenderHosts.first?.view
            for entry in entries.values where (entry.isModelOwned || entry.isToolOwned) && entry.presentationHost == nil {
                if modelRenderHost != nil { mountModelView(entry) }
                else if entry.view.superview === host { entry.view.removeFromSuperview() }
            }
        }
    }

    func presentTab(_ id: UUID, in host: NSView) throws {
        let entry = try entry(id)
        guard !entry.isModelOwned else { throw Failure.modelTabPrivate }
        entry.presentationHost = host
        entry.view.removeFromSuperview()
        entry.view.frame = host.bounds
        entry.view.autoresizingMask = [.width, .height]
        (entry.view as? EmbeddedModelWebView)?.captureNativeFocus(in: host.window)
        host.addSubview(entry.view)
    }

    func detachPresentedTab(_ id: UUID, from host: NSView) {
        guard let entry = entries[id], entry.presentationHost === host else { return }
        entry.presentationHost = nil
        if entry.view.superview === host { entry.view.removeFromSuperview() }
        if entry.isModelOwned || entry.isToolOwned { mountModelView(entry) }
    }

    private func mountModelView(_ entry: Entry) {
        guard let host = modelRenderHost else { return }
        if entry.view.superview !== host { entry.view.removeFromSuperview() }
        entry.view.autoresizingMask = []
        entry.view.frame = NSRect(x: 0, y: 0, width: 1_024, height: 768)
        (entry.view as? EmbeddedModelWebView)?.captureNativeFocus(in: host.window)
        if entry.view.superview !== host { host.addSubview(entry.view) }
    }

    func documentGeneration(for id: UUID) -> UUID? { entries[id]?.tab.documentGeneration }


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
              ["chatgpt.com", "claude.ai", "gemini.google.com"].contains(originHost) else { throw Failure.tabClosed }
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

    /// Model pages share the sign-in profile, but never reuse a human's tab.
    func createModelTab(url: URL) throws -> UUID {
        try createModelTab(initialURL: url)
    }

    /// Independent inference pages need authentication, not the human profile's
    /// accumulated conversation keys. Publication/navigation follows complete
    /// seeding; failure never falls back to the shared store.
    func createChatGPTInferenceTab(requestMetadata: ChatGPTRequestMetadataLease? = nil,
                                   until deadline: ContinuousClock.Instant = .now + .seconds(10),
                                   admit: @MainActor () throws -> Void) async throws -> UUID {
        try Task.checkCancellation()
        guard !isShutdown else { throw Failure.sessionClosed }
        guard exclusiveCookieMaintenance == nil else { throw Failure.cookieMaintenancePending }
        guard tabs.count + inferenceCookieSeeds.count < maximumTabs else { throw Failure.tabLimit(maximumTabs) }
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
    private var modelViewFactoryForTesting: (@MainActor (WKWebViewConfiguration) -> WKWebView)?
    private var cookieSeedFactoryForTesting: (@MainActor (WKWebsiteDataStore, WKWebsiteDataStore) -> ChatGPTInferenceCookieSeed)?
    private var afterCookieSeedForTesting: (@MainActor () async -> Void)?

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
    func createUnloadedModelTabForTesting(viewFactory: (@MainActor (WKWebViewConfiguration) -> WKWebView)? = nil) throws -> UUID {
        modelViewFactoryForTesting = viewFactory
        defer { modelViewFactoryForTesting = nil }
        return try createModelTab(initialURL: nil)
    }
    #endif

    private func createModelTab(initialURL: URL?, isolatedChatGPTStore: WKWebsiteDataStore? = nil) throws -> UUID {
        let id = try createTab(select: false, modelOwned: true, isolatedChatGPTStore: isolatedChatGPTStore)
        do {
            guard let view = webView(for: id) else { throw Failure.tabClosed }
            view.frame = NSRect(x: 0, y: 0, width: 1_024, height: 768)
            if let entry = entries[id] { mountModelView(entry) }
            if let initialURL { try navigate(tabID: id, to: initialURL) }
            return id
        } catch {
            closeTab(id)
            throw error
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for seed in Array(inferenceCookieSeeds.values) { seed.cancel() }
        onHumanVerificationRecoveryCandidate = nil
        for id in tabs.map(\.id) { closeTab(id) }
        temporaryCookieRetirement?.stop()
        modelRenderHost = nil
        modelRenderHosts.removeAll()
        websiteDataStore = nil
    }

    private func entry(_ id: UUID) throws -> Entry {
        guard !isShutdown else { throw Failure.sessionClosed }
        guard let entry = entries[id] else { throw Failure.tabClosed }
        return entry
    }

    private func prepareNavigation(_ entry: Entry, replacesDocument: Bool = false) {
        entry.pendingConversationAdmission = nil
        if entry.requestMetadataDiagnostic?.generation != nil { revokeRequestMetadata(entry) }
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
    }

    fileprivate func owns(_ view: WKWebView, tabID: UUID) -> Bool { entries[tabID]?.view === view }

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
        guard let entry = entries[tabID], entry.view === view, let pending = entry.pendingConversationAdmission,
              pending.id == admission else { return false }
        let permitted = await admitChatGPTAfterCookieCallbacks(until: .now + .seconds(2))
        return permitted && entries[tabID] === entry && entry.view === view && entry.pendingConversationURL == url
            && entry.pendingConversationAdmission?.id == admission && entry.tab.documentGeneration == pending.generation
    }

    fileprivate func report(_ message: String, tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        entry.tab.error = message
        if selectedTabID == tabID { errorMessage = message }
    }

    fileprivate func started(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID) {
        guard let entry = entries[tabID], entry.view === view else { return }
        // A native load/reload invalidates synchronously, before WebKit starts it.
        // Page-initiated full navigations advance here; pushState does not arrive here.
        let prepared = entry.preparedDocumentNavigation && entry.navigation === navigation
        prepareNavigation(entry)
        if !prepared { entry.tab.documentGeneration = UUID() }
        entry.navigation = navigation
        if entry.isModelOwned, navigation != nil {
            entry.modelNavigationGeneration = entry.tab.documentGeneration
        }
        refresh(tabID, view: view)
        emitGeminiPostBlockNativeEvent(entry, .started)
    }

    fileprivate func serverRedirected(_ view: WKWebView, navigation: WKNavigation?, tabID: UUID) {
        guard let entry = entries[tabID], entry.isModelOwned, entry.view === view,
              let navigation, entry.navigation === navigation,
              entry.modelNavigationGeneration == entry.tab.documentGeneration,
              entry.modelCommittedGeneration != entry.tab.documentGeneration,
              entry.modelFinishedGeneration != entry.tab.documentGeneration,
              entry.modelFailedGeneration != entry.tab.documentGeneration else { return }
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
    private weak var focusWindow: NSWindow?
    private weak var focusResponder: NSResponder?
    private weak var focusField: NSTextField?
    private weak var focusFieldEditor: NSTextView?
    private var focusFieldText: String?
    private var focusFieldSelection: NSRange?
    private var restoringFocus = false

    override var acceptsFirstResponder: Bool { false }

    func captureNativeFocus(in targetWindow: NSWindow? = nil) {
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

    func restoreNativeFocus() {
        guard !restoringFocus, let target = window, target === focusWindow,
              let current = target.firstResponder, ownsResponder(current) else { return }
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
                        try await Task.sleep(until: deadline, clock: .continuous)
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

    init(session: EmbeddedBrowserSession, tabID: UUID) { self.session = session; self.tabID = tabID }
    func invalidate() { session = nil }

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
                admitChatGPT(url, view: webView) { decisionHandler($0 ? .allow : .cancel) }
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
            if navigationResponse.isForMainFrame { session?.protectPendingConversation(webView, tabID: tabID, url: url) }
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

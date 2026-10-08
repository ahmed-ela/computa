import AutomationCore
import CryptoKit
import Foundation
import Observation

private struct ActiveTurnTiming {
    let userEntryID: TimelineEntry.ID
    let startedAt: Date
}

@MainActor
@Observable
final class AppState {
    @ObservationIgnored private let runtime: (any AgentRuntimeClient)?
    @ObservationIgnored private var runtimeShutdown: Task<RuntimeShutdownReport, Never>?
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var chromeConnectionRequest: ChromeConnectionRequest?
    @ObservationIgnored private var chromeConnectionTask: Task<Void, Never>?
    @ObservationIgnored private var chromeCleanupTask: Task<Void, Never>?
    @ObservationIgnored private let chromeTargetProvider: @MainActor () throws -> NativeChromeConnectionTarget
    @ObservationIgnored private var attemptedRememberedChromeConnection = false
    @ObservationIgnored private var chromePreferenceGeneration: UInt64 = 0
    @ObservationIgnored private let permissionClient: any AutomationPermissionClient
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var embeddedModelTransport: EmbeddedWebModelTransport?
    @ObservationIgnored private let websiteModelDiscovery: (@MainActor (String) async throws -> [WebsiteModelChoice])?
    @ObservationIgnored private var websiteModelRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var websiteModelRefreshGeneration: UUID?
    @ObservationIgnored private var websiteModelRefreshProviders: [String] = []
    @ObservationIgnored private var websiteModelRefreshRetriesBlocked = false
    @ObservationIgnored private var didStartWebsiteModelDiscovery = false
    // Keep the persisted key across the Computa rename.
    private static let defaultModelPreferenceKey = "LocalCodex.defaultModelID"
    private static let accessModePreferenceKey = "HeyDash.accessMode"

    var tasks: [AgentTask]
    var selectedTaskID: AgentTask.ID?
    var selectedEntryID: TimelineEntry.ID?
    var composerText = ""
    var isInspectorPresented = false
    var isBrowserPresented = false
    var isReviewPresented = false
    private(set) var review: AppReviewState?
    @ObservationIgnored private let reviewService = WorkspaceReviewService()
    @ObservationIgnored private var reviewGeneration: UInt64 = 0
    @ObservationIgnored private var reviewRefresh: Task<Void, Never>?
    private var reviewMutationTaskIDs: Set<String> = []
    @ObservationIgnored private var reviewNeedsRefresh: Set<String> = []
    let browserSession: EmbeddedBrowserSession
    var presentedSheet: SheetDestination? {
        didSet {
            if presentedSheet != nil, approvalGateBlocksInteraction {
                presentedSheet = nil
            }
        }
    }

    var appearance: AppAppearance = .system
    var defaultModel: String
    private(set) var websiteModelChoices: [WebsiteModelChoice]
    private(set) var websiteModelsRefreshing = false
    private(set) var websiteModelsError: String?
    var showToolPayloads = false
    var connectionState: RuntimeConnectionState = .disconnected
    private(set) var chromeConnectionState: ChromeConnectionState = .disconnected
    private(set) var chromeConnectionID: UUID?
    private(set) var chromeDisconnecting = false
    private(set) var remembersChromeConnection = false
    private(set) var extensionBridge: BrowserExtensionCoordinator?
    var automationPermissions: AutomationPermissionSnapshot
    var contextUsageByTask: [AgentTask.ID: RuntimeContextUsage] = [:]
    var compactionStateByTask: [AgentTask.ID: RuntimeCompactionState] = [:]
    private(set) var accessMode: AccessMode = .askEveryTime
    var automaticApprovalError: String?
    var pendingApprovals: [ActionApprovalRequest] = [] {
        didSet { dismissSettingsIfApprovalBlocksInteraction() }
    }
    var resolvingApprovalIDs: Set<String> = [] {
        didSet { dismissSettingsIfApprovalBlocksInteraction() }
    }
    var activeTurnTaskIDs: Set<AgentTask.ID> = []
    private var activeTurnTimings: [AgentTask.ID: ActiveTurnTiming] = [:]
    private var provisionalAssistantItemIDs: [AgentTask.ID: Set<TimelineEntry.ID>] = [:]
    private var assistantItemPhases: [AgentTask.ID: [TimelineEntry.ID: String]] = [:]
    // A delayed event must not recreate output discarded by cancellation or
    // the runtime's evidence/compaction guard, even if a newer turn is running.
    private var discardedAssistantItemIDs: [AgentTask.ID: Set<TimelineEntry.ID>] = [:]
    private var provisionalReasoningItemIDs: [AgentTask.ID: Set<TimelineEntry.ID>] = [:]
    private var discardedReasoningItemIDs: [AgentTask.ID: Set<TimelineEntry.ID>] = [:]
    var interruptingTaskIDs: Set<AgentTask.ID> = []
    private(set) var websiteSessionCleanupTaskIDs: Set<AgentTask.ID> = []
    private(set) var websiteSessionCleanupReceipts: [AgentTask.ID: WebsiteSessionCleanupReceipt] = [:]
    var queuedPrompts: [AgentTask.ID: [QueuedPrompt]] = [:]
    var pausedQueueTaskIDs: Set<AgentTask.ID> = []
    var promptReceipts: [PromptReceipt] = []
    @ObservationIgnored private var promptReceiptRevision: UInt64 = 0
    @ObservationIgnored private var acceptedPromptRequests: [String: (taskID: String, digest: Data)] = [:]
    private var dispatchingQueueTaskIDs: Set<AgentTask.ID> = []
    private var steeringTaskIDs: Set<AgentTask.ID> = []
    @ObservationIgnored private var resolvedDuringApprovalAttemptIDs: Set<String> = []
    @ObservationIgnored private var approvalAttemptRequests: [String: ActionApprovalRequest] = [:]
    @ObservationIgnored private var approvalRequestsAwaitingResolvedEvents: [String: [ActionApprovalRequest]] = [:]
    @ObservationIgnored private var latestApprovalRequestsByID: [String: ActionApprovalRequest] = [:]
    @ObservationIgnored private var approvalIDsRequiringManualReview: Set<String> = []
    @ObservationIgnored private var automaticApprovalAttemptedRequests: Set<ActionApprovalRequest> = []
    @ObservationIgnored private var accessModeGeneration: UInt64 = 0

    init(
        tasks: [AgentTask] = SampleData.tasks,
        runtime: (any AgentRuntimeClient)? = nil,
        permissionClient: any AutomationPermissionClient = PermissionInspector(),
        preferences: UserDefaults = .standard,
        browserSession: EmbeddedBrowserSession? = nil,
        enableChromeExtensionBridge: Bool = false,
        websiteModelDiscovery: (@MainActor (String) async throws -> [WebsiteModelChoice])? = nil,
        chromeTargetProvider: @escaping @MainActor () throws -> NativeChromeConnectionTarget = {
            try NativeChromeConnectionTarget.prepare()
        }
    ) {
        self.runtime = runtime
        self.permissionClient = permissionClient
        self.preferences = preferences
        self.websiteModelDiscovery = websiteModelDiscovery
        self.browserSession = browserSession ?? EmbeddedBrowserSession(defaults: preferences)
        self.chromeTargetProvider = chromeTargetProvider
        remembersChromeConnection = RememberedChromeConnection.load(from: preferences) != nil
        let storedAccessMode = preferences.object(forKey: Self.accessModePreferenceKey) as? String
        accessMode = storedAccessMode.flatMap(AccessMode.init(rawValue:)) ?? .askEveryTime
        let storedModel = preferences.string(forKey: Self.defaultModelPreferenceKey)
        defaultModel = storedModel.flatMap { id in
            // Saved website choices remain selected if an account/menu changes.
            // Invalid ones are visible and rejected, never replaced with Qwen.
            id.hasPrefix("browser/") ? id : LocalModelCatalog.option(for: id)?.id
        } ?? LocalModelCatalog.defaultModelID
        websiteModelChoices = WebsiteModelCatalog.load(from: preferences)
        automationPermissions = permissionClient.current()
        self.tasks = tasks
        selectedTaskID = tasks.first?.id
        selectedEntryID = tasks.first?.entries.last?.id
        retireWebsiteModelSelections()
        if enableChromeExtensionBridge {
            extensionBridge = BrowserExtensionCoordinator(preferences: preferences, onAdmission: { [weak self] request in
                guard let self, self.canConnectChrome else { request.consent.revoke(); return false }
                return self.connectChrome(request, remember: true)
            }, onRevocation: { [weak self] in
                guard let self, self.chromeConnectionRequest?.extensionAdmission != nil else { return }
                self.endChromeConnection(state: .disconnected)
            })
        }
    }

    var selectedTask: AgentTask? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    var modelOptions: [LocalModelOption] {
        var options = LocalModelCatalog.options.flatMap { option -> [LocalModelOption] in
            guard let provider = LocalModelCatalog.webProvider(for: option.id) else { return [option] }
            return [option] + websiteModelChoices.filter { $0.provider == provider && $0.isSelectable }.map { WebsiteModelCatalog.option(for: $0) }
        }
        for id in [defaultModel, selectedTask?.model].compactMap({ $0 })
            where id.hasPrefix("browser/") && !options.contains(where: { $0.id == id }) {
            if let choice = WebsiteModelCatalog.choice(for: id) {
                guard !choice.isRetired else { continue }
                options.append(WebsiteModelCatalog.option(for: choice, available: false))
            } else {
                options.append(LocalModelOption(id: id, label: "Unavailable website choice",
                    detail: WebsiteModelCatalog.Failure.invalidModelID.localizedDescription,
                    highMemory: false, available: false))
            }
        }
        return options
    }

    /// Explicitly removed choices migrate only the next inference's selection.
    /// Recorded messages and active/queued turns retain their original identity.
    private func retireWebsiteModelSelections() {
        let choices = websiteModelChoices.filter { $0.provider == "chatgpt" && $0.isSelectable }
        let replacement = choices.first { $0.key == "GPT-5.6 Sol" }?.modelID
            ?? choices.first?.modelID ?? "browser/chatgpt"
        if WebsiteModelCatalog.choice(for: defaultModel)?.isRetired == true {
            defaultModel = replacement
            preferences.set(replacement, forKey: Self.defaultModelPreferenceKey)
        }
        for index in tasks.indices where WebsiteModelCatalog.choice(for: tasks[index].model)?.isRetired == true {
            let taskID = tasks[index].id
            guard canChangeModel(for: taskID) else { continue }
            tasks[index].model = replacement
            contextUsageByTask.removeValue(forKey: taskID)
            compactionStateByTask.removeValue(forKey: taskID)
        }
    }

    private func websiteTransport() -> EmbeddedWebModelTransport {
        if let embeddedModelTransport { return embeddedModelTransport }
        let transport = EmbeddedWebModelTransport(browser: browserSession)
        embeddedModelTransport = transport
        return transport
    }

    /// Called after the privileged WebUI is ready and its background render host
    /// is attached. Saved choices are immediately usable; only providers with
    /// no saved choices need startup discovery. An explicit refresh can replace
    /// the saved catalog without adding provider page loads on every launch.
    func refreshWebsiteModelsIfNeeded() {
        guard !didStartWebsiteModelDiscovery, runtime != nil || websiteModelDiscovery != nil else { return }
        didStartWebsiteModelDiscovery = true
        let missing = WebsiteModelCatalog.providers.filter { provider in
            !websiteModelChoices.contains { $0.provider == provider }
        }
        guard !missing.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.refreshWebsiteModels(providers: missing, retryBlocked: false)
        }
    }

    func refreshWebsiteModels() async {
        await refreshWebsiteModels(providers: WebsiteModelCatalog.providers, retryBlocked: true)
    }

    private func refreshWebsiteModels(providers: [String], retryBlocked: Bool) async {
        guard !isShuttingDown, !approvalGateBlocksInteraction else { return }
        if let websiteModelRefreshTask {
            // Extend an in-flight partial startup refresh rather than dropping
            // an explicit full refresh or loading a provider twice.
            for provider in providers where !websiteModelRefreshProviders.contains(provider) {
                websiteModelRefreshProviders.append(provider)
            }
            websiteModelRefreshRetriesBlocked = websiteModelRefreshRetriesBlocked || retryBlocked
            await websiteModelRefreshTask.value
            return
        }
        let generation = UUID()
        websiteModelRefreshGeneration = generation
        websiteModelRefreshProviders = providers
        websiteModelRefreshRetriesBlocked = retryBlocked
        websiteModelsRefreshing = true
        websiteModelsError = nil
        let refresh = Task { @MainActor [weak self] in
            guard let self else { return }
            var errors: [String] = []
            var providerIndex = 0
            while providerIndex < self.websiteModelRefreshProviders.count {
                guard !Task.isCancelled, !self.isShuttingDown else { break }
                let provider = self.websiteModelRefreshProviders[providerIndex]
                providerIndex += 1
                do {
                    let choices: [WebsiteModelChoice]
                    if let discovery = self.websiteModelDiscovery { choices = try await discovery(provider) }
                    else {
                        choices = try await self.websiteTransport().discoverModels(provider: provider,
                            retryBlocked: self.websiteModelRefreshRetriesBlocked)
                    }
                    guard !Task.isCancelled, !self.isShuttingDown,
                          self.websiteModelRefreshGeneration == generation else { break }
                    try WebsiteModelCatalog.validate(choices, provider: provider)
                    self.websiteModelChoices.removeAll { $0.provider == provider }
                    self.websiteModelChoices.append(contentsOf: choices.filter(\.isSelectable))
                    WebsiteModelCatalog.save(self.websiteModelChoices, to: self.preferences)
                    self.retireWebsiteModelSelections()
                } catch is CancellationError {
                    break
                } catch {
                    guard !self.isShuttingDown, self.websiteModelRefreshGeneration == generation else { break }
                    errors.append("\(WebsiteModelCatalog.providerLabel(provider)): \(error.localizedDescription)")
                }
            }
            guard self.websiteModelRefreshGeneration == generation else { return }
            self.websiteModelsError = errors.isEmpty ? nil : errors.joined(separator: "\n")
            self.websiteModelsRefreshing = false
            self.websiteModelRefreshTask = nil
            self.websiteModelRefreshGeneration = nil
            self.websiteModelRefreshProviders = []
            self.websiteModelRefreshRetriesBlocked = false
        }
        websiteModelRefreshTask = refresh
        await refresh.value
    }

    /// Settings is rendered inside the privileged UI document. Temporarily
    /// remove the sibling pane so it cannot cover or interact through Settings.
    var shouldPresentBrowserPane: Bool {
        isBrowserPresented && presentedSheet != .settings
    }

    var selectedEntry: TimelineEntry? {
        guard let selectedEntryID else { return nil }
        return selectedTask?.entries.first { $0.id == selectedEntryID }
    }

    /// Full access never presents or focuses the native approval card. A failed
    /// automatic delivery stays pending until the user switches back to Ask.
    var presentedApproval: ActionApprovalRequest? {
        guard accessMode == .askEveryTime, resolvingApprovalIDs.isEmpty else { return nil }
        return pendingApprovals.first
    }

    var approvalGateBlocksInteraction: Bool {
        accessMode == .askEveryTime
            && (!pendingApprovals.isEmpty || !resolvingApprovalIDs.isEmpty)
    }

    /// Full access is deliberately absent: action approvals do not grant a
    /// signed-in browser connection. Only the separate native confirmation can.
    var canConnectChrome: Bool {
        runtime != nil && !isShuttingDown && !approvalGateBlocksInteraction
            && !chromeConnectionRequiresIdleRuntime
            && !chromeDisconnecting && chromeConnectionID == nil
    }

    /// Native controls remain visible to Accessibility. Requiring an idle
    /// runtime prevents an active model's own UI input from granting itself a
    /// new browser capability, including while Full access is selected.
    var chromeConnectionRequiresIdleRuntime: Bool {
        !activeTurnTaskIDs.isEmpty || tasks.contains { $0.status == .running }
            || !interruptingTaskIDs.isEmpty || !dispatchingQueueTaskIDs.isEmpty
            || !steeringTaskIDs.isEmpty || !pendingApprovals.isEmpty
            || !resolvingApprovalIDs.isEmpty
            || compactionStateByTask.values.contains(.running)
            || queuedPrompts.contains { taskID, prompts in
                !prompts.isEmpty && !pausedQueueTaskIDs.contains(taskID)
            }
    }

    @discardableResult
    func connectChrome(_ request: ChromeConnectionRequest, remember: Bool = false) -> Bool {
        guard canConnectChrome, let runtime else {
            // A duplicate invocation must not revoke the active request itself.
            if chromeConnectionRequest?.consent !== request.consent { request.consent.revoke() }
            return false
        }
        do { try request.consent.check() }
        catch {
            chromeConnectionState = .failed(message: error.localizedDescription)
            return false
        }

        if !remember { forgetRememberedChromeConnection() }
        let preferenceGeneration = chromePreferenceGeneration
        chromeConnectionRequest = request
        chromeConnectionID = request.id
        chromeConnectionState = .connecting
        chromeConnectionTask = Task { [weak self] in
            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try request.consent.check()
                    try await runtime.connectChrome(request)
                    try Task.checkCancellation()
                    try request.consent.check()
                } onCancel: {
                    request.consent.revoke()
                }
                guard let self, !self.isShuttingDown,
                      self.chromeConnectionID == request.id else { return }
                if remember, request.extensionAdmission == nil, self.chromePreferenceGeneration == preferenceGeneration {
                    try RememberedChromeConnection(request: request).save(to: self.preferences)
                    self.remembersChromeConnection = true
                }
                self.chromeConnectionState = .connected
                self.chromeConnectionTask = nil
            } catch {
                request.consent.revoke()
                guard let self, self.chromeConnectionID == request.id else { return }
                let state: ChromeConnectionState = error is CancellationError
                    ? .disconnected : .failed(message: error.localizedDescription)
                self.endChromeConnection(state: state)
            }
        }
        return true
    }

    /// Revocation happens before this method returns, not after the runtime
    /// actor next receives a message. Neither the model nor the web bridge calls
    /// this connection control. Disconnect is also safe during a pending Allow.
    func disconnectChrome() {
        let revocation = extensionBridge?.forget()
        forgetRememberedChromeConnection()
        endChromeConnection(state: .disconnected, beforeCleanup: revocation)
    }

    var canPairChromeExtension: Bool {
        runtime != nil && !isShuttingDown && !chromeConnectionRequiresIdleRuntime
            && !approvalGateBlocksInteraction && !chromeDisconnecting
    }

    func pairChromeExtension() {
        guard canPairChromeExtension, let bridge = extensionBridge, bridge.pairingAvailable else { return }
        // Native user-authorized transport switch. No automatic fallback from
        // extension failure to the old prompt-producing connection.
        forgetRememberedChromeConnection()
        endChromeConnection(state: .disconnected)
        let cleanup = chromeCleanupTask
        Task { [weak self] in
            await cleanup?.value
            guard let self, self.canConnectChrome else { return }
            do { try await bridge.approvePairing() }
            catch { self.chromeConnectionState = .failed(message: error.localizedDescription) }
        }
    }

    var canAllowTemporaryChromeTabs: Bool {
        canPairChromeExtension && chromeConnectionState == .connected
            && chromeConnectionTask == nil && extensionBridge?.enabled == true
            && extensionBridge?.temporaryTabsAllowed == false
    }

    /// No web-bridge action exists for this native capability grant.
    func allowTemporaryChromeTabs(expectedConnectionID: UUID) {
        guard canAllowTemporaryChromeTabs, chromeConnectionID == expectedConnectionID,
              let bridge = extensionBridge else { return }
        do {
            try bridge.allowTemporaryTabs()
            // Normal teardown preserves pairing; a new extension session
            // receives the expanded grant only after all old authority dies.
            endChromeConnection(state: .disconnected)
        } catch {
            chromeConnectionState = .failed(message: error.localizedDescription)
        }
    }

    var canRememberChromeConnection: Bool {
        !isShuttingDown && !chromeDisconnecting && !approvalGateBlocksInteraction
            && !chromeConnectionRequiresIdleRuntime && chromeConnectionState == .connected
            && chromeConnectionTask == nil && chromeConnectionRequest != nil && !remembersChromeConnection
    }

    /// Native confirmation only; the model and web bridge have no such action.
    @discardableResult
    func rememberChromeConnection(expectedID: UUID) -> Bool {
        guard canRememberChromeConnection, let request = chromeConnectionRequest,
              request.id == expectedID else { return false }
        do {
            try request.consent.check()
            try RememberedChromeConnection(request: request).save(to: preferences)
            remembersChromeConnection = true
            return true
        } catch { return false }
    }

    func forgetRememberedChromeConnection() {
        chromePreferenceGeneration &+= 1
        RememberedChromeConnection.forget(in: preferences)
        remembersChromeConnection = false
    }

    private func restoreRememberedChromeConnectionOnLaunch() async {
        guard !attemptedRememberedChromeConnection else { return }
        attemptedRememberedChromeConnection = true
        // Extension pairing is separate authority. Never silently fall back to
        // legacy CDP and surprise the user with a new Chrome permission dialog.
        if extensionBridge?.enabled == true { return }
        guard !Task.isCancelled, canConnectChrome,
              let saved = RememberedChromeConnection.load(from: preferences) else { return }
        do {
            let target = try chromeTargetProvider()
            guard saved.matches(target) else {
                chromeConnectionState = .failed(message: "The running Chrome app or profile differs from the connection you remembered. Connect it manually to approve this scope. No automatic connection was made.")
                return
            }
            // The saved scope is the native user's authority. Every launch
            // still resolves a fresh process, endpoint and revocable consent.
            if connectChrome(target.confirmedRequest(), remember: true) {
                await chromeConnectionTask?.value
            }
        } catch {
            chromeConnectionState = .failed(message: error.localizedDescription)
        }
    }

    private func endChromeConnection(state: ChromeConnectionState, beforeCleanup: Task<Void, Never>? = nil) {
        chromeConnectionRequest?.consent.revoke()
        let pendingConnection = chromeConnectionTask
        pendingConnection?.cancel()
        chromeConnectionTask = nil
        let hadConnection = chromeConnectionID != nil
        chromeConnectionRequest = nil
        chromeConnectionID = nil
        chromeConnectionState = state
        guard hadConnection, chromeCleanupTask == nil else { return }
        chromeDisconnecting = true
        let runtime = self.runtime
        chromeCleanupTask = Task { [weak self] in
            await beforeCleanup?.value
            await runtime?.disconnectChrome()
            // Do not admit a newer connection while a cancelled older connect
            // can still finish. Its consent is already revoked above.
            await pendingConnection?.value
            guard let self else { return }
            self.chromeDisconnecting = false
            self.chromeCleanupTask = nil
            if self.canConnectChrome { self.extensionBridge?.reconnectSaved() }
        }
    }

    func selectTask(_ id: AgentTask.ID?) {
        selectedTaskID = id
        selectedEntryID = selectedTask?.entries.last?.id
        reviewGeneration &+= 1
        reviewRefresh?.cancel()
        review = nil
        if isReviewPresented, let id { requestReviewRefresh(taskID: id) }
    }

    /// Remember the native user's choice across launches. Missing or invalid
    /// preferences start in Ask; the web bridge cannot change this preference.
    @discardableResult
    func setAccessMode(_ mode: AccessMode) -> Bool {
        guard !isShuttingDown, accessMode != mode else { return false }
        let approvalWasPresented = presentedApproval != nil
        accessMode = mode
        preferences.set(mode.rawValue, forKey: Self.accessModePreferenceKey)
        accessModeGeneration &+= 1
        automaticApprovalAttemptedRequests.removeAll()
        automaticApprovalError = nil
        dismissSettingsIfApprovalBlocksInteraction()
        if mode == .fullAccess {
            claimPendingAutomaticApprovals(settlePresentedApproval: approvalWasPresented)
        }
        return true
    }

    /// Settings must never cover or disable the native controls for an Ask-mode
    /// approval. Keep this guard in state so native commands and bridge actions
    /// cannot reopen Settings while an approval is pending or settling.
    @discardableResult
    func presentSettings() -> Bool {
        guard !approvalGateBlocksInteraction else {
            presentedSheet = nil
            return false
        }
        presentedSheet = .settings
        return true
    }

    private func dismissSettingsIfApprovalBlocksInteraction() {
        if approvalGateBlocksInteraction {
            presentedSheet = nil
        }
    }

    func createTask() {
        let task = AgentTask(
            title: "Untitled task",
            summary: "A new local task",
            status: .draft,
            workspace: "No workspace selected",
            model: defaultModel
        )
        tasks.insert(task, at: 0)
        selectedTaskID = task.id
        selectedEntryID = nil
        composerText = ""
        reviewGeneration &+= 1
        reviewRefresh?.cancel()
        review = nil
        if isReviewPresented { requestReviewRefresh(taskID: task.id) }
    }

    func toggleReview() {
        guard !approvalGateBlocksInteraction else { return }
        isReviewPresented.toggle()
        if isReviewPresented, let selectedTaskID { requestReviewRefresh(taskID: selectedTaskID) }
        else {
            reviewGeneration &+= 1
            reviewRefresh?.cancel()
        }
    }

    func setReviewScope(_ scope: FileReviewScope, taskID: String) {
        guard taskID == selectedTaskID else { return }
        let reference = review?.reference ?? "HEAD"
        review = AppReviewState(taskID: taskID, scope: scope, reference: reference)
        requestReviewRefresh(taskID: taskID)
    }

    func setReviewReference(_ reference: String, taskID: String) {
        guard taskID == selectedTaskID, reference.utf8.count <= 1_024 else { return }
        if review == nil { review = AppReviewState(taskID: taskID, scope: .branch, reference: "HEAD") }
        review?.reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        requestReviewRefresh(taskID: taskID)
    }

    func requestReviewRefresh(taskID: String) {
        guard taskID == selectedTaskID, isReviewPresented else { return }
        reviewGeneration &+= 1
        if !reviewMutationTaskIDs.isEmpty {
            reviewNeedsRefresh.insert(taskID)
            return
        }
        let previous = reviewRefresh
        previous?.cancel()
        reviewRefresh = Task { @MainActor [weak self] in
            // Coalesce event wakeups without overlapping retained Git reads.
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.refreshReview(taskID: taskID)
        }
    }

    func refreshReview(taskID: String) async {
        guard !Task.isCancelled, !isShuttingDown, isReviewPresented, taskID == selectedTaskID,
              let task = tasks.first(where: { $0.id == taskID }) else { return }
        reviewGeneration &+= 1
        let generation = reviewGeneration
        var current = review?.taskID == taskID ? review! : AppReviewState(taskID: taskID, scope: .lastTurn, reference: "HEAD")
        current.loading = true
        current.error = nil
        current.snapshot = nil
        review = current
        do {
            let lastTurn = task.turnDiffs.last
            let completedChanges = task.entries.filter {
                lastTurn != nil && $0.turnID == lastTurn?.id && $0.toolEvent?.name == "fileChange"
                    && $0.toolEvent?.status == .succeeded
            }.flatMap { $0.fileChanges ?? [] }
            let snapshot = try await reviewService.load(workspace: task.workspace, scope: current.scope,
                reference: current.reference.isEmpty ? nil : current.reference,
                turnDiff: lastTurn?.diff, turnChanges: completedChanges)
            guard !Task.isCancelled, generation == reviewGeneration, selectedTaskID == taskID, isReviewPresented else { return }
            review?.snapshot = snapshot
            review?.loading = false
        } catch {
            guard !Task.isCancelled, generation == reviewGeneration, selectedTaskID == taskID else { return }
            review?.loading = false
            review?.error = error.localizedDescription
        }
    }

    /// Applies only the exact patch held by the native service. Web content
    /// supplies opaque receipt IDs, never paths, replacement text or Git flags.
    func mutateReview(taskID: String, snapshotID: String, operation: FileReviewOperation,
                      fileID: String?, hunkID: String?) async {
        guard !isShuttingDown, !approvalGateBlocksInteraction, !isBusy(taskID: taskID),
              taskID == selectedTaskID, review?.taskID == taskID, review?.snapshot?.id == snapshotID,
              review?.loading == false else { return }
        reviewMutationTaskIDs.insert(taskID)
        defer {
            reviewMutationTaskIDs.remove(taskID)
            if reviewMutationTaskIDs.isEmpty {
                let pending = reviewNeedsRefresh
                reviewNeedsRefresh.removeAll()
                if let selectedTaskID, pending.contains(selectedTaskID) {
                    requestReviewRefresh(taskID: selectedTaskID)
                }
            }
            Task { @MainActor [weak self] in await self?.drainQueue(taskID: taskID) }
        }
        reviewGeneration &+= 1
        let generation = reviewGeneration
        review?.loading = true
        review?.error = nil
        do {
            let snapshot = try await reviewService.mutate(snapshotID: snapshotID, operation: operation, fileID: fileID, hunkID: hunkID)
            guard generation == reviewGeneration, selectedTaskID == taskID else { return }
            review?.snapshot = snapshot
            review?.loading = false
        } catch {
            guard generation == reviewGeneration, selectedTaskID == taskID else { return }
            review?.loading = false
            review?.snapshot = nil
            review?.error = error.localizedDescription
        }
    }

    func reviewFileURL(taskID: String, snapshotID: String, fileID: String) async throws -> URL? {
        guard taskID == selectedTaskID, review?.taskID == taskID, review?.snapshot?.id == snapshotID,
              review?.loading == false else { return nil }
        return try await reviewService.fileURL(snapshotID: snapshotID, fileID: fileID)
    }

    func reportReviewError(_ message: String, taskID: String) {
        guard selectedTaskID == taskID else { return }
        review?.error = message
    }

    var canChooseTaskWorkspace: Bool {
        guard let task = selectedTask else { return false }
        return task.status == .draft && task.entries.isEmpty && !isBusy(taskID: task.id)
    }

    func setTaskWorkspace(_ url: URL, taskID: String) async throws {
        guard taskID == selectedTaskID, canChooseTaskWorkspace, url.isFileURL,
              let runtime else { return }
        try await runtime.configureWorkspace(path: url.path, forTaskID: taskID)
        guard taskID == selectedTaskID, let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].status == .draft,
              tasks[index].entries.isEmpty else { return }
        tasks[index].workspace = url.path
        if isReviewPresented { requestReviewRefresh(taskID: taskID) }
    }

    @discardableResult
    func setDefaultModel(_ modelID: String) -> Bool {
        guard let option = modelOptions.first(where: { $0.id == modelID }), option.available != false else { return false }
        defaultModel = modelID
        preferences.set(modelID, forKey: Self.defaultModelPreferenceKey)
        return true
    }

    @discardableResult
    func setTaskModel(_ modelID: String, taskID: AgentTask.ID) -> Bool {
        guard let option = modelOptions.first(where: { $0.id == modelID }), option.available != false,
              let index = tasks.firstIndex(where: { $0.id == taskID }),
              canChangeModel(for: taskID)
        else { return false }
        tasks[index].model = modelID
        contextUsageByTask.removeValue(forKey: taskID)
        compactionStateByTask.removeValue(forKey: taskID)
        return true
    }

    func canChangeModel(for taskID: AgentTask.ID) -> Bool {
        tasks.contains(where: { $0.id == taskID })
            && !isBusy(taskID: taskID)
            && queuedPrompts[taskID, default: []].allSatisfy {
                $0.status == .failed && $0.deliveryUncertain == false
            }
    }

    func isBusy(taskID: AgentTask.ID) -> Bool {
        tasks.contains(where: { $0.id == taskID && $0.status == .running })
            || activeTurnTaskIDs.contains(taskID)
            || compactionStateByTask[taskID] == .running
            || pendingApprovals.contains(where: { $0.taskID == nil || $0.taskID == taskID })
            || !resolvingApprovalIDs.isEmpty
            || steeringTaskIDs.contains(taskID)
            || reviewMutationTaskIDs.contains(taskID)
            || websiteSessionCleanupTaskIDs.contains(taskID)
    }

    /// A cleanup retry never resumes the failed turn or drains its prompt queue.
    func canRetryWebsiteSessionCleanup(taskID: AgentTask.ID) -> Bool {
        guard runtime != nil, !isShuttingDown,
              case .connected = connectionState,
              !approvalGateBlocksInteraction, pendingApprovals.isEmpty, resolvingApprovalIDs.isEmpty,
              !isBusy(taskID: taskID), !interruptingTaskIDs.contains(taskID),
              !dispatchingQueueTaskIDs.contains(taskID),
              !queuedPrompts[taskID, default: []].contains(where: { $0.status == .sending }),
              let task = tasks.first(where: { $0.id == taskID }), task.status == .waiting,
              let lastUser = task.entries.lastIndex(where: { $0.kind == .user })
        else { return false }
        if let receipt = currentWebsiteSessionCleanupReceipt(taskID: taskID) {
            guard receipt.outcome == .unconfirmed else { return false }
            if receipt.provider != nil, receipt.route != nil,
               receipt.modelID.map(LocalModelCatalog.isWebBrowser) == true { return true }
        }
        guard LocalModelCatalog.isWebBrowser(task.model) else { return false }
        return task.entries[lastUser...].contains {
            $0.kind == .system && ["Agent error", "Website session cleanup unconfirmed"].contains($0.title)
        }
    }

    func currentWebsiteSessionCleanupReceipt(taskID: AgentTask.ID) -> WebsiteSessionCleanupReceipt? {
        guard let receipt = websiteSessionCleanupReceipts[taskID],
              let task = tasks.first(where: { $0.id == taskID }),
              let user = task.entries.last(where: { $0.kind == .user }) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let observedAt = formatter.date(from: receipt.timestamp), observedAt >= user.timestamp else { return nil }
        return receipt
    }

    /// Claim synchronously at the UI boundary so duplicate clicks and queued
    /// submissions cannot race the cleanup-only runtime call.
    @discardableResult
    func requestWebsiteSessionCleanup(taskID: AgentTask.ID) -> Bool {
        guard canRetryWebsiteSessionCleanup(taskID: taskID), let runtime else { return false }
        websiteSessionCleanupTaskIDs.insert(taskID)
        pausedQueueTaskIDs.insert(taskID)
        Task { @MainActor [weak self] in
            let receipt = await runtime.retryWebsiteSessionCleanup(taskID: taskID)
            guard let self else { return }
            self.websiteSessionCleanupTaskIDs.remove(taskID)
            guard !self.isShuttingDown, receipt.isValid, receipt.taskID == taskID.lowercased(),
                  let index = self.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            self.recordWebsiteSessionCleanupReceipt(receipt, taskID: taskID)
            // The runtime persists the finite receipt separately. This local
            // timeline copy displays that same attempt, without replaying it.
            let entryID = "website-session-cleanup-" + receipt.attemptID
            guard !self.tasks[index].entries.contains(where: { $0.id == entryID }) else { return }
            let body: String
            switch receipt.outcome {
            case .closed:
                body = "Computa confirmed that this task's owned website session is closed. Your local chat is retained."
            case .noOwnedSession:
                body = "Computa currently has no owned website session for this task. This does not confirm whether an earlier website conversation was deleted."
            case .unconfirmed:
                body = "Computa could not confirm website session cleanup. The task remains paused."
            }
            let entry = TimelineEntry(id: entryID, kind: .system, title: "Website session cleanup",
                body: body + " No prompt was sent and the model was not restarted."
                    + (receipt.receiptSaved ? "" : " The cleanup receipt could not be saved locally."))
            self.tasks[index].entries.append(entry)
            self.tasks[index].updatedAt = max(self.tasks[index].updatedAt, entry.timestamp)
            if self.selectedTaskID == taskID { self.selectedEntryID = entry.id }
        }
        return true
    }

    private func recordWebsiteSessionCleanupReceipt(_ receipt: WebsiteSessionCleanupReceipt, taskID: AgentTask.ID) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let timestamp = formatter.date(from: receipt.timestamp) else { return }
        if let current = websiteSessionCleanupReceipts[taskID],
           let currentTimestamp = formatter.date(from: current.timestamp), timestamp <= currentTimestamp { return }
        websiteSessionCleanupReceipts[taskID] = receipt
    }

    private func projectWebsiteSessionCleanupReceipt(_ receipt: WebsiteSessionCleanupReceipt) {
        guard receipt.isValid else { return }
        let task = tasks.first(where: { $0.id.lowercased() == receipt.taskID })
            ?? receipt.threadID.flatMap { thread in tasks.first(where: { $0.id.lowercased() == thread }) }
        if let task {
            // A persisted thread match is presentation provenance, never a
            // recreation of the receipt's old live website-session association.
            recordWebsiteSessionCleanupReceipt(receipt, taskID: task.id)
        }
    }

    func activeTurnStartedAt(for taskID: AgentTask.ID) -> TimeInterval? {
        guard activeTurnTaskIDs.contains(taskID) else { return nil }
        return activeTurnTimings[taskID]?.startedAt.timeIntervalSince1970
    }

    func activeActivityGroupID(for taskID: AgentTask.ID) -> String? {
        guard activeTurnTaskIDs.contains(taskID) else { return nil }
        return activeTurnTimings[taskID]?.userEntryID
    }

    func canSteer(taskID: AgentTask.ID) -> Bool {
        runtime != nil && !isShuttingDown
            && tasks.contains(where: { $0.id == taskID && $0.status == .running })
            && activeTurnTaskIDs.contains(taskID)
            && compactionStateByTask[taskID] != .running
            && !interruptingTaskIDs.contains(taskID)
            && !steeringTaskIDs.contains(taskID)
            && !pendingApprovals.contains(where: { $0.taskID == nil || $0.taskID == taskID })
            && resolvingApprovalIDs.isEmpty
    }

    /// Stop is a human UI action for a running task. The App Server owns the
    /// resulting status; keep it running here until its turn event arrives.
    @discardableResult
    func interrupt(taskID: AgentTask.ID) async -> Bool {
        guard let runtime,
              tasks.contains(where: { $0.id == taskID && $0.status == .running }),
              !interruptingTaskIDs.contains(taskID)
        else { return false }

        interruptingTaskIDs.insert(taskID)
        pausedQueueTaskIDs.insert(taskID)
        let activityGroupID = activeActivityGroupID(for: taskID)
        do {
            try await runtime.interrupt(taskID: taskID)
            return true
        } catch {
            interruptingTaskIDs.remove(taskID)
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return false }
            let failure = TimelineEntry(
                kind: .system,
                title: "Could not stop task",
                body: error.localizedDescription,
                activityGroupID: activityGroupID
            )
            tasks[index].entries.append(failure)
            if selectedTaskID == taskID {
                selectedEntryID = failure.id
            }
            return false
        }
    }

    func refreshAutomationPermissions() {
        automationPermissions = permissionClient.current()
    }

    /// This is only called by the native bridge for the matching Settings
    /// button. Model/runtime code has no permission-request action.
    func requestAccessibilityPermission() {
        automationPermissions = permissionClient.requestAccessibility()
    }

    /// This is only called by the native bridge for the matching Settings
    /// button. Model/runtime code has no permission-request action.
    func requestScreenRecordingPermission() {
        automationPermissions = permissionClient.requestScreenRecording()
    }

    @ObservationIgnored private var approvalAttemptTaskIDs: [String: AgentTask.ID] = [:]
    @ObservationIgnored private var invalidatedApprovalAttemptIDs: Set<String> = []

    private enum ApprovalResolutionOrigin {
        case user
        case automatic(generation: UInt64, settlePresentedApproval: Bool)
    }

    private struct ApprovalResolutionAttempt {
        let request: ActionApprovalRequest
        let approved: Bool
        let originalIndex: Int
        let origin: ApprovalResolutionOrigin
    }

    private enum ApprovalClaimResult {
        case claimed(ApprovalResolutionAttempt)
        case rejected(reason: String)
    }

    @discardableResult
    func resolveApproval(
        _ request: ActionApprovalRequest,
        approved: Bool,
        settlePresentation: (@MainActor () async throws -> Void)? = nil
    ) async -> ApprovalResolutionResult {
        switch claimApproval(request, approved: approved, origin: .user) {
        case .rejected(let reason):
            return .init(requestID: request.id, status: .notAttempted, reason: reason)
        case .claimed(let attempt):
            return await deliverApproval(attempt, settlePresentation: settlePresentation)
        }
    }

    private func claimApproval(
        _ request: ActionApprovalRequest,
        approved: Bool,
        origin: ApprovalResolutionOrigin
    ) -> ApprovalClaimResult {
        guard runtime != nil else { return .rejected(reason: "runtime_missing") }
        guard !isShuttingDown else { return .rejected(reason: "runtime_shutting_down") }
        guard !resolvingApprovalIDs.contains(request.id) else {
            return .rejected(reason: "resolution_in_flight")
        }
        guard let approvalIndex = pendingApprovals.firstIndex(of: request) else {
            return .rejected(reason: "exact_request_not_pending")
        }

        resolvingApprovalIDs.insert(request.id)
        approvalAttemptTaskIDs[request.id] = request.taskID
        approvalAttemptRequests[request.id] = request
        latestApprovalRequestsByID[request.id] = request
        invalidatedApprovalAttemptIDs.remove(request.id)
        resolvedDuringApprovalAttemptIDs.remove(request.id)
        pendingApprovals.remove(at: approvalIndex)
        return .claimed(ApprovalResolutionAttempt(
            request: request,
            approved: approved,
            originalIndex: approvalIndex,
            origin: origin
        ))
    }

    private func deliverApproval(
        _ attempt: ApprovalResolutionAttempt,
        settlePresentation: (@MainActor () async throws -> Void)?
    ) async -> ApprovalResolutionResult {
        let request = attempt.request
        defer {
            resolvingApprovalIDs.remove(request.id)
            approvalAttemptTaskIDs.removeValue(forKey: request.id)
            if approvalAttemptRequests[request.id] == request {
                approvalAttemptRequests.removeValue(forKey: request.id)
            }
            invalidatedApprovalAttemptIDs.remove(request.id)
            resolvedDuringApprovalAttemptIDs.remove(request.id)
            for taskID in queuedPrompts.keys { scheduleQueueDrain(taskID: taskID) }
            claimPendingAutomaticApprovals()
        }

        @MainActor func restoreIfStillPending() -> Bool {
            guard !isShuttingDown,
                  !invalidatedApprovalAttemptIDs.contains(request.id),
                  !resolvedDuringApprovalAttemptIDs.contains(request.id),
                  !pendingApprovals.contains(where: { $0.id == request.id }) else { return false }
            pendingApprovals.insert(request, at: min(attempt.originalIndex, pendingApprovals.endIndex))
            return true
        }

        switch attempt.origin {
        case .user:
            // Preserve native approval-overlay teardown before resuming computer
            // input. The injected operation is only a deterministic test seam.
            do {
                if let settlePresentation {
                    try await settlePresentation()
                } else {
                    await nextMainRunLoopTurn()
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
            } catch {
                return .init(
                    requestID: request.id, status: .notAttempted,
                    reason: "presentation_settle_failed: \(error.localizedDescription)",
                    requestRestored: restoreIfStillPending(),
                    resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
                )
            }
        case .automatic(let generation, let settlePresentedApproval):
            guard accessMode == .fullAccess, generation == accessModeGeneration else {
                return .init(
                    requestID: request.id, status: .notAttempted,
                    reason: "access_mode_changed_before_delivery",
                    requestRestored: restoreIfStillPending(),
                    resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
                )
            }
            do {
                if settlePresentedApproval {
                    await nextMainRunLoopTurn()
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
            } catch {
                return .init(
                    requestID: request.id, status: .notAttempted,
                    reason: "automatic_resolution_cancelled_before_delivery",
                    requestRestored: restoreIfStillPending(),
                    resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
                )
            }
        }

        if case .automatic(let generation, _) = attempt.origin,
           !(accessMode == .fullAccess && generation == accessModeGeneration) {
            return .init(
                requestID: request.id, status: .notAttempted,
                reason: "access_mode_changed_before_delivery",
                requestRestored: restoreIfStillPending(),
                resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
            )
        }

        guard !isShuttingDown,
              !invalidatedApprovalAttemptIDs.contains(request.id),
              !resolvedDuringApprovalAttemptIDs.contains(request.id),
              approvalAttemptRequests[request.id] == request,
              !pendingApprovals.contains(where: { $0.id == request.id }) else {
            return .init(
                requestID: request.id, status: .notAttempted,
                reason: "request_invalidated_or_superseded_before_delivery",
                resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
            )
        }

        let dispatchStartedAt = DispatchTime.now().uptimeNanoseconds
        let activityGroupID = request.taskID.flatMap { activeActivityGroupID(for: $0) }
        approvalRequestsAwaitingResolvedEvents[request.id, default: []].append(request)
        do {
            guard let runtime else {
                return .init(requestID: request.id, status: .notAttempted, reason: "runtime_missing")
            }
            try await runtime.resolveApproval(requestID: request.id, approved: attempt.approved)
            return .init(
                requestID: request.id, status: .delivered, reason: "runtime_returned_success",
                approved: attempt.approved, dispatchStartedAt: dispatchStartedAt,
                resolvedEventObserved: resolvedDuringApprovalAttemptIDs.contains(request.id)
            )
        } catch {
            let eventObserved = resolvedDuringApprovalAttemptIDs.contains(request.id)
            if case .automatic = attempt.origin {
                // Once an automatic delivery reaches the runtime and fails, its
                // outcome is uncertain. A later mode-generation change must not
                // turn restoration into another automatic approved=true attempt.
                automaticApprovalAttemptedRequests.insert(request)
                approvalIDsRequiringManualReview.insert(request.id)
            }
            let restored = restoreIfStillPending()
            if let taskID = request.taskID,
               let index = tasks.firstIndex(where: { $0.id == taskID }) {
                let failure = TimelineEntry(
                    kind: .system,
                    title: "Approval could not be resolved",
                    body: error.localizedDescription,
                    activityGroupID: activityGroupID
                )
                tasks[index].entries.append(failure)
                selectedEntryID = failure.id
            }
            if case .automatic = attempt.origin,
               accessMode == .fullAccess,
               !isShuttingDown,
               restored {
                automaticApprovalError = "Full access could not approve “\(request.title)”. Switch to Ask every time to review and retry."
            }
            // In particular, approvalResolved followed by an error is NOT proof
            // that this caller's approved=true/false decision was delivered.
            return .init(
                requestID: request.id, status: .failed, reason: error.localizedDescription,
                dispatchStartedAt: dispatchStartedAt, requestRestored: restored,
                resolvedEventObserved: eventObserved
            )
        }
    }

    /// Claims every eligible request synchronously so Full access never flashes or
    /// focuses the native approval UI. Failures and reused IDs remain pending for
    /// explicit human review, without an automatic retry loop.
    private func claimPendingAutomaticApprovals(settlePresentedApproval: Bool = false) {
        guard accessMode == .fullAccess, !isShuttingDown else { return }
        let generation = accessModeGeneration
        for request in pendingApprovals where !automaticApprovalAttemptedRequests.contains(request) {
            automaticApprovalAttemptedRequests.insert(request)

            if approvalIDsRequiringManualReview.contains(request.id) {
                automaticApprovalError = "Full access did not retry an approval whose prior response is ambiguous. Switch to Ask every time to review it."
                continue
            }

            if approvalRequestsAwaitingResolvedEvents[request.id]?.isEmpty == false {
                approvalIDsRequiringManualReview.insert(request.id)
                automaticApprovalError = "Full access did not approve a request whose approval ID still has an unresolved prior response. Switch to Ask every time to review it."
                continue
            }

            if let inFlight = approvalAttemptRequests[request.id] {
                if inFlight != request {
                    approvalIDsRequiringManualReview.insert(request.id)
                    automaticApprovalError = "Full access did not approve a replacement request that reused an in-flight approval ID. Switch to Ask every time to review it."
                }
                continue
            }

            switch claimApproval(
                request,
                approved: true,
                origin: .automatic(
                    generation: generation,
                    settlePresentedApproval: settlePresentedApproval
                )
            ) {
            case .rejected(let reason):
                automaticApprovalError = "Full access could not claim “\(request.title)” (\(reason)). Switch to Ask every time to review it."
            case .claimed(let attempt):
                Task { @MainActor [weak self] in
                    _ = await self?.deliverApproval(attempt, settlePresentation: nil)
                }
            }
        }
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// Starts listening to the injected runtime. With no runtime installed the
    /// sample store remains fully local and this method is a no-op.
    func startRuntime() async {
        guard !isShuttingDown, let runtime else { return }
        connectionState = .connecting

        do {
            await runtime.configureEmbeddedWebModelTransport(websiteTransport())
            guard !Task.isCancelled, !isShuttingDown else { return }
            let snapshot = try await runtime.loadTasks()
            guard !isShuttingDown else { return }
            replaceTasks(with: snapshot)
            extensionBridge?.start()
            await restoreRememberedChromeConnectionOnLaunch()
            guard !Task.isCancelled, !isShuttingDown else { return }
            connectionState = .connected(provider: runtime.providerName)

            for await event in runtime.events() {
                guard !Task.isCancelled, !isShuttingDown else { return }
                apply(event)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isShuttingDown else { return }
            apply(.connectionChanged(.failed(message: error.localizedDescription)))
        }
    }

    func shutdownRuntime() async -> RuntimeShutdownReport {
        if let runtimeShutdown { return await runtimeShutdown.value }
        isShuttingDown = true
        websiteModelRefreshTask?.cancel()
        let websiteRefresh = websiteModelRefreshTask
        websiteModelRefreshGeneration = nil
        websiteModelsRefreshing = false
        reviewGeneration &+= 1
        reviewRefresh?.cancel()
        reviewNeedsRefresh.removeAll()
        discardAllMessageDrafts()
        extensionBridge?.stop()
        endChromeConnection(state: .disconnected)
        invalidatedApprovalAttemptIDs.formUnion(resolvingApprovalIDs)
        pendingApprovals.removeAll()
        automaticApprovalAttemptedRequests.removeAll()
        latestApprovalRequestsByID.removeAll()
        approvalIDsRequiringManualReview.removeAll()
        approvalRequestsAwaitingResolvedEvents.removeAll()
        pausedQueueTaskIDs.formUnion(queuedPrompts.keys)
        let runtime = self.runtime
        let browserSession = self.browserSession
        let chromeCleanup = chromeCleanupTask
        let task = Task {
            await websiteRefresh?.value
            await chromeCleanup?.value
            let report = await runtime?.shutdown() ?? RuntimeShutdownReport(issues: [])
            browserSession.shutdown()
            return report
        }
        runtimeShutdown = task
        let report = await task.value
        websiteModelRefreshTask = nil
        websiteModelRefreshProviders = []
        websiteModelRefreshRetriesBlocked = false
        pendingApprovals.removeAll()
        resolvingApprovalIDs.removeAll()
        approvalAttemptTaskIDs.removeAll()
        approvalAttemptRequests.removeAll()
        approvalRequestsAwaitingResolvedEvents.removeAll()
        latestApprovalRequestsByID.removeAll()
        approvalIDsRequiringManualReview.removeAll()
        automaticApprovalAttemptedRequests.removeAll()
        automaticApprovalError = nil
        activeTurnTaskIDs.removeAll()
        activeTurnTimings.removeAll()
        interruptingTaskIDs.removeAll()
        contextUsageByTask.removeAll()
        compactionStateByTask.removeAll()
        connectionState = .disconnected
        return report
    }

    func replaceTasks(with newTasks: [AgentTask]) {
        let priorSelection = selectedTaskID
        let cleanupReceipts = websiteSessionCleanupReceipts.values.sorted {
            $0.timestamp == $1.timestamp ? $0.attemptID < $1.attemptID : $0.timestamp < $1.timestamp
        }
        discardAllMessageDrafts()
        tasks = newTasks
        selectedTaskID = newTasks.contains(where: { $0.id == priorSelection })
            ? priorSelection
            : newTasks.first?.id
        selectedEntryID = selectedTask?.entries.last?.id
        interruptingTaskIDs.formIntersection(
            Set(newTasks.filter { $0.status == .running }.map(\.id))
        )
        let liveTaskIDs = Set(newTasks.map(\.id))
        discardedAssistantItemIDs = discardedAssistantItemIDs.filter { liveTaskIDs.contains($0.key) }
        discardedReasoningItemIDs = discardedReasoningItemIDs.filter { liveTaskIDs.contains($0.key) }
        activeTurnTimings = activeTurnTimings.filter { taskID, timing in
            liveTaskIDs.contains(taskID)
                && newTasks.first(where: { $0.id == taskID })?.entries.contains(where: {
                    $0.id == timing.userEntryID
                }) == true
        }
        contextUsageByTask = contextUsageByTask.filter { liveTaskIDs.contains($0.key) }
        compactionStateByTask = compactionStateByTask.filter { liveTaskIDs.contains($0.key) }
        websiteSessionCleanupReceipts = websiteSessionCleanupReceipts.filter { liveTaskIDs.contains($0.key) }
        for receipt in cleanupReceipts { projectWebsiteSessionCleanupReceipt(receipt) }
        retireWebsiteModelSelections()
    }

    func apply(_ event: AgentRuntimeEvent) {
        switch event {
        case .websiteSessionCleanupUpdated(let receipt):
            guard !isShuttingDown, receipt.isValid else { return }
            projectWebsiteSessionCleanupReceipt(receipt)

        case .tasksSnapshot(let snapshot):
            replaceTasks(with: snapshot)

        case .taskUpserted(let task):
            discardAssistantDrafts(taskID: task.id)
            discardReasoningDrafts(taskID: task.id)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            } else {
                tasks.insert(task, at: 0)
            }
            retireWebsiteModelSelections()

        case .turnDiffUpdated(let taskID, let turnID, let diff):
            guard let index = tasks.firstIndex(where: { $0.id == taskID }), !turnID.isEmpty else { return }
            let value = AgentTurnDiff(id: turnID, diff: diff)
            if let existing = tasks[index].turnDiffs.firstIndex(where: { $0.id == turnID }) {
                tasks[index].turnDiffs[existing] = value
            } else { tasks[index].turnDiffs.append(value) }
            if isReviewPresented, selectedTaskID == taskID, review?.scope == .lastTurn {
                requestReviewRefresh(taskID: taskID)
            }

        case .timelineEntryAppended(let taskID, let entry):
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            if entry.kind == .user { websiteSessionCleanupReceipts.removeValue(forKey: taskID) }
            var completedEntry = entry
            completedEntry.activityGroupID = activeActivityGroupID(for: taskID) ?? entry.activityGroupID
            if entry.kind == .assistant {
                completedEntry.isStreaming = false
                completedEntry.assistantPhase = TimelineEntry.validAssistantPhase(entry.assistantPhase)
                    ?? assistantItemPhases[taskID]?[entry.id]
                guard !discardedAssistantItemIDs[taskID, default: []].contains(entry.id) else { return }
                if let entryIndex = tasks[index].entries.firstIndex(where: { $0.id == entry.id }) {
                    // Completion is authoritative, but duplicate completions or
                    // late deltas must not rewrite an already finalized reply.
                    guard provisionalAssistantItemIDs[taskID, default: []].contains(entry.id),
                          tasks[index].entries[entryIndex].kind == .assistant else { return }
                    completedEntry.timestamp = tasks[index].entries[entryIndex].timestamp
                    completedEntry.activityGroupID = tasks[index].entries[entryIndex].activityGroupID
                        ?? completedEntry.activityGroupID
                    completedEntry.assistantPhase = completedEntry.assistantPhase
                        ?? tasks[index].entries[entryIndex].assistantPhase
                    tasks[index].entries[entryIndex] = completedEntry
                } else {
                    tasks[index].entries.append(completedEntry)
                }
                provisionalAssistantItemIDs[taskID]?.remove(entry.id)
                if provisionalAssistantItemIDs[taskID]?.isEmpty == true {
                    provisionalAssistantItemIDs.removeValue(forKey: taskID)
                }
                assistantItemPhases[taskID]?.removeValue(forKey: entry.id)
                if assistantItemPhases[taskID]?.isEmpty == true {
                    assistantItemPhases.removeValue(forKey: taskID)
                }
                pauseReasoningStreaming(taskID: taskID, taskIndex: index)
            } else if entry.kind == .reasoning {
                guard !discardedReasoningItemIDs[taskID, default: []].contains(entry.id) else { return }
                completedEntry.isStreaming = false
                completedEntry.assistantPhase = nil
                // Reasoning is never the public answer or its completion clock.
                completedEntry.workedForSeconds = nil
                if let entryIndex = tasks[index].entries.firstIndex(where: { $0.id == entry.id }) {
                    guard provisionalReasoningItemIDs[taskID, default: []].contains(entry.id),
                          tasks[index].entries[entryIndex].kind == .reasoning else { return }
                    completedEntry.timestamp = tasks[index].entries[entryIndex].timestamp
                    completedEntry.activityGroupID = tasks[index].entries[entryIndex].activityGroupID
                        ?? completedEntry.activityGroupID
                    tasks[index].entries[entryIndex] = completedEntry
                } else {
                    guard !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    tasks[index].entries.append(completedEntry)
                }
                provisionalReasoningItemIDs[taskID]?.remove(entry.id)
                if provisionalReasoningItemIDs[taskID]?.isEmpty == true {
                    provisionalReasoningItemIDs.removeValue(forKey: taskID)
                }
            } else {
                completedEntry.assistantPhase = nil
                if entry.kind == .tool, let name = entry.toolEvent?.name, ["commandExecution", "fileChange"].contains(name),
                   let existing = tasks[index].entries.firstIndex(where: {
                       $0.id == entry.id && $0.kind == .tool && $0.toolEvent?.name == name
                   }) {
                    if name == "fileChange" {
                        guard tasks[index].entries[existing].turnID == entry.turnID else { return }
                        if tasks[index].entries[existing].toolEvent?.status != .running, entry.toolEvent?.status == .running { return }
                    }
                    completedEntry.timestamp = tasks[index].entries[existing].timestamp
                    completedEntry.activityGroupID = tasks[index].entries[existing].activityGroupID
                        ?? completedEntry.activityGroupID
                    tasks[index].entries[existing] = completedEntry
                } else { tasks[index].entries.append(completedEntry) }
            }
            tasks[index].updatedAt = max(tasks[index].updatedAt, entry.timestamp)
            if selectedTaskID == taskID {
                selectedEntryID = entry.id
            }
            if completedEntry.kind == .tool, completedEntry.toolEvent?.name == "fileChange",
               completedEntry.toolEvent?.status == .succeeded,
               isReviewPresented, selectedTaskID == taskID, review?.scope == .lastTurn {
                // A metadata-only move may have no aggregate-diff notification.
                requestReviewRefresh(taskID: taskID)
            }

        case .assistantMessagePhaseUpdated(let taskID, let itemID, let phase):
            guard !isShuttingDown, !itemID.isEmpty,
                  let validPhase = TimelineEntry.validAssistantPhase(phase),
                  !discardedAssistantItemIDs[taskID, default: []].contains(itemID),
                  let index = tasks.firstIndex(where: { $0.id == taskID }),
                  activeTurnTaskIDs.contains(taskID) || tasks[index].status == .running else { return }
            if let entryIndex = tasks[index].entries.firstIndex(where: { $0.id == itemID }) {
                guard provisionalAssistantItemIDs[taskID, default: []].contains(itemID),
                      tasks[index].entries[entryIndex].kind == .assistant else { return }
                tasks[index].entries[entryIndex].assistantPhase = validPhase
            }
            assistantItemPhases[taskID, default: [:]][itemID] = validPhase

        case .assistantMessageDelta(let taskID, let itemID, let delta):
            guard !isShuttingDown, !itemID.isEmpty, !delta.isEmpty,
                  !discardedAssistantItemIDs[taskID, default: []].contains(itemID),
                  let index = tasks.firstIndex(where: { $0.id == taskID }),
                  activeTurnTaskIDs.contains(taskID) || tasks[index].status == .running else { return }
            if let entryIndex = tasks[index].entries.firstIndex(where: { $0.id == itemID }) {
                guard provisionalAssistantItemIDs[taskID, default: []].contains(itemID),
                      tasks[index].entries[entryIndex].kind == .assistant else { return }
                tasks[index].entries[entryIndex].body += delta
            } else {
                tasks[index].entries.append(TimelineEntry(
                    id: itemID, kind: .assistant, title: "Computa", body: delta, isStreaming: true,
                    activityGroupID: activeActivityGroupID(for: taskID), assistantPhase: assistantItemPhases[taskID]?[itemID]
                ))
                provisionalAssistantItemIDs[taskID, default: []].insert(itemID)
            }
            pauseReasoningStreaming(taskID: taskID, taskIndex: index)
            tasks[index].updatedAt = .now
            if selectedTaskID == taskID { selectedEntryID = itemID }

        case .assistantMessagesDiscarded(let taskID):
            discardAssistantDrafts(taskID: taskID)

        case .reasoningMessageUpdated(let taskID, let itemID, let text):
            guard !isShuttingDown, !itemID.isEmpty,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !discardedReasoningItemIDs[taskID, default: []].contains(itemID),
                  let index = tasks.firstIndex(where: { $0.id == taskID }),
                  activeTurnTaskIDs.contains(taskID) || tasks[index].status == .running else { return }
            if let entryIndex = tasks[index].entries.firstIndex(where: { $0.id == itemID }) {
                guard provisionalReasoningItemIDs[taskID, default: []].contains(itemID),
                      tasks[index].entries[entryIndex].kind == .reasoning else { return }
                tasks[index].entries[entryIndex].body = text
                tasks[index].entries[entryIndex].isStreaming = true
            } else {
                tasks[index].entries.append(TimelineEntry(
                    id: itemID, kind: .reasoning, title: "Thinking", body: text, isStreaming: true,
                    activityGroupID: activeActivityGroupID(for: taskID)
                ))
                provisionalReasoningItemIDs[taskID, default: []].insert(itemID)
            }
            tasks[index].updatedAt = .now
            if selectedTaskID == taskID { selectedEntryID = itemID }

        case .reasoningMessagesDiscarded(let taskID):
            discardReasoningDrafts(taskID: taskID)

        case .taskStatusChanged(let taskID, let status):
            if status == .running,
               case .failed? = compactionStateByTask[taskID] {
                compactionStateByTask.removeValue(forKey: taskID)
            }
            if status != .running {
                for (requestID, owner) in approvalAttemptTaskIDs where owner == taskID {
                    invalidatedApprovalAttemptIDs.insert(requestID)
                }
            }
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[index].status = status
            let eventTime = Date.now
            tasks[index].updatedAt = eventTime
            if status != .running {
                // A completed turn with an unfinished item is not a completed
                // answer. Remove the draft before looking for a timed reply.
                if discardAssistantDrafts(taskID: taskID) {
                    activeTurnTimings.removeValue(forKey: taskID)
                }
                discardReasoningDrafts(taskID: taskID)
                if status == .completed {
                    finishTurnTiming(taskID: taskID, taskIndex: index, completedAt: eventTime)
                } else {
                    activeTurnTimings.removeValue(forKey: taskID)
                }
                activeTurnTaskIDs.remove(taskID)
                interruptingTaskIDs.remove(taskID)
                pendingApprovals.removeAll { $0.taskID == taskID }
                retireWebsiteModelSelections()
                automaticApprovalAttemptedRequests = automaticApprovalAttemptedRequests.filter {
                    $0.taskID != taskID
                }
                if status == .completed {
                    scheduleQueueDrain(taskID: taskID)
                } else if !queuedPrompts[taskID, default: []].isEmpty {
                    pausedQueueTaskIDs.insert(taskID)
                }
                if canConnectChrome { extensionBridge?.reconnectSaved() }
                if isReviewPresented, selectedTaskID == taskID {
                    // Shell edits have no native patch item. Refresh current Git
                    // scopes when the turn finishes, including interrupted work.
                    requestReviewRefresh(taskID: taskID)
                }
            }

        case .contextUsageUpdated(let taskID, let usage):
            guard tasks.contains(where: { $0.id == taskID }) else { return }
            if let usage {
                contextUsageByTask[taskID] = usage
            } else {
                contextUsageByTask.removeValue(forKey: taskID)
            }

        case .contextCompactionChanged(let taskID, let state):
            guard tasks.contains(where: { $0.id == taskID }) else { return }
            compactionStateByTask[taskID] = state
            if case .failed = state {
                pausedQueueTaskIDs.insert(taskID)
            }

        case .approvalRequested(let request):
            if let latest = latestApprovalRequestsByID[request.id] {
                let isCurrentDuplicate = latest == request
                    && (pendingApprovals.contains(request)
                        || approvalAttemptRequests[request.id] == request
                        || approvalRequestsAwaitingResolvedEvents[request.id]?.contains(request) == true)
                guard !isCurrentDuplicate else { return }

                latestApprovalRequestsByID[request.id] = request
                approvalIDsRequiringManualReview.insert(request.id)
                if let index = pendingApprovals.firstIndex(where: { $0.id == request.id }) {
                    pendingApprovals[index] = request
                } else {
                    pendingApprovals.append(request)
                }
                if accessMode == .fullAccess {
                    // A reused ID cannot prove that resolving the ID would approve
                    // the payload we inspected. Require an explicit mode change and
                    // human review instead of silently approving the replacement.
                    automaticApprovalAttemptedRequests.insert(request)
                    automaticApprovalError = "Full access did not approve a request that reused an approval ID. Switch to Ask every time to review it."
                }
                return
            }

            latestApprovalRequestsByID[request.id] = request
            guard !pendingApprovals.contains(where: { $0.id == request.id }) else { return }
            pendingApprovals.append(request)
            claimPendingAutomaticApprovals()

        case .approvalResolved(let requestID):
            let eventRequest: ActionApprovalRequest?
            if var waiting = approvalRequestsAwaitingResolvedEvents[requestID], !waiting.isEmpty {
                eventRequest = waiting.removeFirst()
                if waiting.isEmpty {
                    approvalRequestsAwaitingResolvedEvents.removeValue(forKey: requestID)
                } else {
                    approvalRequestsAwaitingResolvedEvents[requestID] = waiting
                }
            } else {
                eventRequest = approvalAttemptRequests[requestID]
            }

            if let eventRequest {
                pendingApprovals.removeAll { $0 == eventRequest }
                automaticApprovalAttemptedRequests.remove(eventRequest)
            } else {
                pendingApprovals.removeAll { $0.id == requestID }
                automaticApprovalAttemptedRequests = automaticApprovalAttemptedRequests.filter {
                    $0.id != requestID
                }
            }
            if resolvingApprovalIDs.contains(requestID),
               eventRequest == approvalAttemptRequests[requestID] {
                resolvedDuringApprovalAttemptIDs.insert(requestID)
            }

        case .connectionChanged(let state):
            connectionState = state
            if case .failed = state {
                // Browser lifetime is independent of model/runtime readiness.
                // Core separately reports a browser failure after its bounded
                // quiescence check; a model error alone is not revoked consent.
                invalidateApprovalsForDisconnectedRuntime()
                invalidateContextForDisconnectedRuntime()
                discardAllMessageDrafts()
                activeTurnTaskIDs.removeAll()
                activeTurnTimings.removeAll()
                interruptingTaskIDs.removeAll()
                pausedQueueTaskIDs.formUnion(queuedPrompts.keys)
                markDisconnectedTurnsWaiting()
            } else if case .disconnected = state {
                invalidateApprovalsForDisconnectedRuntime()
                invalidateContextForDisconnectedRuntime()
                discardAllMessageDrafts()
                pausedQueueTaskIDs.formUnion(queuedPrompts.keys)
                activeTurnTaskIDs.removeAll()
                activeTurnTimings.removeAll()
                interruptingTaskIDs.removeAll()
                markDisconnectedTurnsWaiting()
            }
        case .chromeConnectionChanged(let connectionID, let state):
            guard !isShuttingDown, chromeConnectionID == connectionID,
                  let request = chromeConnectionRequest else { return }
            switch state {
            case .disconnected, .failed:
                endChromeConnection(state: state)
            case .connecting:
                // A delayed progress event cannot regress a completed connect.
                if chromeConnectionState == .connecting { chromeConnectionState = state }
            case .connected:
                do {
                    try request.consent.check()
                    chromeConnectionState = state
                } catch {
                    endChromeConnection(state: .disconnected)
                }
            }
        }
    }

    @discardableResult
    func submitComposer() async -> Bool {
        let original = composerText
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let selectedTaskID else {
            return false
        }
        let accepted = await submitOrQueue(prompt: prompt, toTaskID: selectedTaskID)
        if accepted && composerText == original { composerText = "" }
        return accepted
    }

    /// Submits immutable prompt and task values captured at the UI boundary.
    /// This prevents selection or composer changes from retargeting a queued turn.
    @discardableResult
    func submit(prompt rawPrompt: String, toTaskID taskID: AgentTask.ID) async -> Bool {
        await submitDelivery(prompt: rawPrompt, toTaskID: taskID).wasDelivered
    }

    private enum PromptDelivery {
        case delivered, notDelivered(String), uncertain(String)
        var wasDelivered: Bool { if case .delivered = self { true } else { false } }
    }

    private func submitDelivery(prompt rawPrompt: String, toTaskID taskID: AgentTask.ID) async -> PromptDelivery {
        // Do not begin a turn while a remembered connection is being restored:
        // Core correctly rejects that race, which otherwise loses first-send UX.
        if let pendingConnection = chromeConnectionTask { await pendingConnection.value }
        if let cleanup = chromeCleanupTask { await cleanup.value }
        guard !Task.isCancelled else { return .notDelivered("Submission was cancelled before delivery.") }
        retireWebsiteModelSelections()
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              !isShuttingDown,
              let index = tasks.firstIndex(where: { $0.id == taskID }),
              !isBusy(taskID: taskID)
        else {
            return .notDelivered("Submission was rejected before delivery.")
        }

        var entry = TimelineEntry(
            kind: .user,
            title: "You",
            body: prompt
        )
        websiteSessionCleanupReceipts.removeValue(forKey: taskID)
        entry.activityGroupID = entry.id
        tasks[index].entries.append(entry)
        tasks[index].summary = prompt
        tasks[index].status = .waiting
        tasks[index].updatedAt = .now
        if selectedTaskID == taskID {
            selectedEntryID = entry.id
        }

        if let runtime {
            let modelID = tasks[index].model
            activeTurnTimings[taskID] = ActiveTurnTiming(
                userEntryID: entry.id,
                startedAt: entry.timestamp
            )
            activeTurnTaskIDs.insert(taskID)
            do {
                try await runtime.submit(prompt: prompt, toTaskID: taskID, modelID: modelID)
            } catch {
                discardAssistantDrafts(taskID: taskID)
                discardReasoningDrafts(taskID: taskID)
                activeTurnTaskIDs.remove(taskID)
                activeTurnTimings.removeValue(forKey: taskID)
                if case .connected = connectionState {
                    // A rejected turn (for example, a missing local model) does
                    // not mean the App Server transport itself disconnected.
                } else {
                    apply(.connectionChanged(.failed(message: error.localizedDescription)))
                }
                guard let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
                    return .uncertain(error.localizedDescription)
                }
                tasks[currentIndex].status = .waiting
                let rejectedBeforeDispatch: Bool
                if case .embeddedRequired? = error as? WebModelServer.Failure {
                    rejectedBeforeDispatch = true
                } else if error is LocalModelServerPreflight.Failure {
                    rejectedBeforeDispatch = true
                } else { rejectedBeforeDispatch = false }
                let failure = TimelineEntry(
                    kind: .system,
                    title: rejectedBeforeDispatch ? "Prompt was not delivered" : "Prompt delivery unconfirmed",
                    body: error.localizedDescription,
                    activityGroupID: entry.id
                )
                tasks[currentIndex].entries.append(failure)
                if selectedTaskID == taskID {
                    selectedEntryID = failure.id
                }
                return rejectedBeforeDispatch ? .notDelivered(error.localizedDescription) : .uncertain(error.localizedDescription)
            }
        }

        return .delivered
    }

    @discardableResult
    private func discardAssistantDrafts(taskID: AgentTask.ID) -> Bool {
        if let phases = assistantItemPhases.removeValue(forKey: taskID) {
            discardedAssistantItemIDs[taskID, default: []].formUnion(phases.keys)
        }
        guard let itemIDs = provisionalAssistantItemIDs.removeValue(forKey: taskID),
              !itemIDs.isEmpty else { return false }
        discardedAssistantItemIDs[taskID, default: []].formUnion(itemIDs)
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[index].entries.removeAll { itemIDs.contains($0.id) && $0.kind == .assistant }
            if selectedTaskID == taskID, let selectedEntryID, itemIDs.contains(selectedEntryID) {
                self.selectedEntryID = tasks[index].entries.last?.id
            }
        }
        return true
    }

    private func pauseReasoningStreaming(taskID: AgentTask.ID, taskIndex: Int) {
        guard let itemIDs = provisionalReasoningItemIDs[taskID], !itemIDs.isEmpty else { return }
        // Public answer text means the model moved beyond thinking, even when
        // the provider holds item completion until EOF. Keep ownership so the
        // eventual authoritative reasoning completion can still reconcile.
        for index in tasks[taskIndex].entries.indices {
            if itemIDs.contains(tasks[taskIndex].entries[index].id),
               tasks[taskIndex].entries[index].kind == .reasoning {
                tasks[taskIndex].entries[index].isStreaming = false
            }
        }
    }

    private func discardReasoningDrafts(taskID: AgentTask.ID) {
        guard let itemIDs = provisionalReasoningItemIDs.removeValue(forKey: taskID),
              !itemIDs.isEmpty else { return }
        discardedReasoningItemIDs[taskID, default: []].formUnion(itemIDs)
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[index].entries.removeAll { itemIDs.contains($0.id) && $0.kind == .reasoning }
            if selectedTaskID == taskID, let selectedEntryID, itemIDs.contains(selectedEntryID) {
                self.selectedEntryID = tasks[index].entries.last?.id
            }
        }
    }

    private func discardAllMessageDrafts() {
        for taskID in Set(provisionalAssistantItemIDs.keys).union(assistantItemPhases.keys) {
            discardAssistantDrafts(taskID: taskID)
        }
        for taskID in Array(provisionalReasoningItemIDs.keys) {
            discardReasoningDrafts(taskID: taskID)
        }
    }

    private func finishTurnTiming(
        taskID: AgentTask.ID,
        taskIndex: Int,
        completedAt: Date
    ) {
        guard let timing = activeTurnTimings.removeValue(forKey: taskID),
              let userIndex = tasks[taskIndex].entries.firstIndex(where: {
                  $0.id == timing.userEntryID && $0.kind == .user
              }),
              userIndex + 1 < tasks[taskIndex].entries.count
        else { return }

        guard let replyIndex = tasks[taskIndex].entries.indices.reversed().first(where: { index in
            index > userIndex
                && tasks[taskIndex].entries[index].kind == .assistant
                && !tasks[taskIndex].entries[index].body.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
        }) else { return }

        tasks[taskIndex].entries[replyIndex].workedForSeconds = max(
            0,
            completedAt.timeIntervalSince(timing.startedAt)
        )
    }

    /// Accept once into native state, before any asynchronous transport work.
    /// The task ID is captured by the composer; selection never retargets it.
    @discardableResult
    func submitOrQueue(prompt rawPrompt: String, toTaskID taskID: AgentTask.ID) async -> Bool {
        guard enqueuePrompt(prompt: rawPrompt, taskID: taskID) else { return false }
        await drainQueue(taskID: taskID)
        return true
    }

    /// The web composer waits for this receipt before clearing its draft. A
    /// retransmitted request ID can acknowledge the same prompt, never send twice.
    @discardableResult
    func acceptPrompt(prompt: String, taskID: String, requestID: String) -> Bool {
        guard !requestID.isEmpty, requestID.utf8.count <= 128 else { return false }
        let digest = Data(SHA256.hash(data: Data(prompt.utf8)))
        let accepted: Bool
        if let prior = acceptedPromptRequests[requestID] {
            accepted = prior.taskID == taskID && prior.digest == digest
        } else {
            accepted = enqueuePrompt(prompt: prompt, taskID: taskID)
            if accepted { acceptedPromptRequests[requestID] = (taskID, digest) }
        }
        promptReceipts.removeAll { $0.id == requestID }
        promptReceiptRevision &+= 1
        promptReceipts.append(PromptReceipt(id: requestID, taskID: taskID, accepted: accepted, revision: promptReceiptRevision))
        if promptReceipts.count > 64 { promptReceipts.removeFirst(promptReceipts.count - 64) }
        if accepted { scheduleQueueDrain(taskID: taskID) }
        return accepted
    }

    private func enqueuePrompt(prompt rawPrompt: String, taskID: String) -> Bool {
        guard let prompt = validatedPrompt(rawPrompt), !isShuttingDown,
              tasks.contains(where: { $0.id == taskID }) else { return false }
        retireWebsiteModelSelections()
        if queuedPrompts[taskID, default: []].isEmpty && !isBusy(taskID: taskID) {
            pausedQueueTaskIDs.remove(taskID)
        }
        queuedPrompts[taskID, default: []].append(QueuedPrompt(text: prompt))
        return true
    }

    private func markDisconnectedTurnsWaiting() {
        for index in tasks.indices where tasks[index].status == .running {
            tasks[index].status = .waiting
        }
    }

    private func invalidateApprovalsForDisconnectedRuntime() {
        invalidatedApprovalAttemptIDs.formUnion(resolvingApprovalIDs)
        pendingApprovals.removeAll()
        latestApprovalRequestsByID.removeAll()
        approvalIDsRequiringManualReview.removeAll()
        automaticApprovalAttemptedRequests.removeAll()
        automaticApprovalError = nil
    }

    private func invalidateContextForDisconnectedRuntime() {
        contextUsageByTask.removeAll()
        let interruptedTaskIDs = compactionStateByTask.compactMap { taskID, state in
            state == .running ? taskID : nil
        }
        for taskID in interruptedTaskIDs {
            compactionStateByTask[taskID] = .failed(
                message: "The runtime disconnected before context compaction was confirmed."
            )
        }
    }

    @discardableResult
    func beginQueueEdit(taskID: String, id: String) -> Bool {
        guard let index = editableQueueIndex(taskID: taskID, id: id) else { return false }
        queuedPrompts[taskID]?[index].status = .editing
        return true
    }

    @discardableResult
    func editQueuedPrompt(taskID: String, id: String, prompt: String) -> Bool {
        guard let text = validatedPrompt(prompt),
              let index = editableQueueIndex(taskID: taskID, id: id) else { return false }
        queuedPrompts[taskID]?[index].text = text
        queuedPrompts[taskID]?[index].status = .queued
        queuedPrompts[taskID]?[index].error = nil
        scheduleQueueDrain(taskID: taskID)
        return true
    }

    @discardableResult
    func cancelQueueEdit(taskID: String, id: String) -> Bool {
        guard let index = editableQueueIndex(taskID: taskID, id: id),
              queuedPrompts[taskID]?[index].status == .editing else { return false }
        let restoredStatus: QueuedPrompt.Status = queuedPrompts[taskID]?[index].error == nil ? .queued : .failed
        queuedPrompts[taskID]?[index].status = restoredStatus
        scheduleQueueDrain(taskID: taskID)
        return true
    }

    @discardableResult
    func deleteQueuedPrompt(taskID: String, id: String) -> Bool {
        guard let index = editableQueueIndex(taskID: taskID, id: id) else { return false }
        queuedPrompts[taskID]?.remove(at: index)
        retireWebsiteModelSelections()
        scheduleQueueDrain(taskID: taskID)
        return true
    }

    @discardableResult
    func moveQueuedPrompt(taskID: String, id: String, beforeID: String?) -> Bool {
        guard let index = editableQueueIndex(taskID: taskID, id: id), id != beforeID,
              var items = queuedPrompts[taskID] else { return false }
        if let beforeID {
            guard items.contains(where: { $0.id == beforeID && $0.status != .sending }) else { return false }
        }
        let item = items.remove(at: index)
        let destination = beforeID.flatMap { target in items.firstIndex { $0.id == target } } ?? items.endIndex
        items.insert(item, at: destination)
        queuedPrompts[taskID] = items
        scheduleQueueDrain(taskID: taskID)
        return true
    }

    @discardableResult
    func resumeQueue(taskID: String) async -> Bool {
        guard !isShuttingDown, tasks.contains(where: { $0.id == taskID }),
              !dispatchingQueueTaskIDs.contains(taskID), !steeringTaskIDs.contains(taskID)
        else { return false }
        pausedQueueTaskIDs.remove(taskID)
        for index in queuedPrompts[taskID, default: []].indices
            where queuedPrompts[taskID]?[index].status == .failed {
            queuedPrompts[taskID]?[index].status = .queued
            queuedPrompts[taskID]?[index].error = nil
            queuedPrompts[taskID]?[index].deliveryUncertain = nil
        }
        await drainQueue(taskID: taskID)
        return true
    }

    @discardableResult
    func steerQueuedPrompt(taskID: String, id: String) async -> Bool {
        guard let submission = claimSteer(taskID: taskID, id: id) else { return false }
        return await deliverSteer(submission)
    }

    /// Reserve synchronously when the bridge receives the human's action. A
    /// completion cannot dispatch this prompt as a new turn before steering runs.
    @discardableResult
    func requestSteerQueuedPrompt(taskID: String, id: String) -> Bool {
        guard let submission = claimSteer(taskID: taskID, id: id) else { return false }
        Task { @MainActor [weak self] in await self?.deliverSteer(submission) }
        return true
    }

    private struct SteerSubmission {
        let taskID: String
        let item: QueuedPrompt
        let transcriptPosition: Int
        let submittedAt: Date
        let activityGroupID: String?
    }

    private func claimSteer(taskID: String, id: String) -> SteerSubmission? {
        guard canSteer(taskID: taskID),
              let index = editableQueueIndex(taskID: taskID, id: id),
              let item = queuedPrompts[taskID]?[index], item.status == .queued else { return nil }
        steeringTaskIDs.insert(taskID)
        queuedPrompts[taskID]?[index].status = .sending
        return SteerSubmission(taskID: taskID, item: item,
            transcriptPosition: tasks.first(where: { $0.id == taskID })?.entries.count ?? 0,
            submittedAt: .now, activityGroupID: activeActivityGroupID(for: taskID))
    }

    private func deliverSteer(_ submission: SteerSubmission) async -> Bool {
        let taskID = submission.taskID
        let item = submission.item
        let id = item.id
        defer {
            steeringTaskIDs.remove(taskID)
            retireWebsiteModelSelections()
        }
        guard let runtime, !isShuttingDown else {
            failQueuedPrompt(taskID: taskID, id: id, message: "Steering was cancelled before delivery.")
            return false
        }
        do {
            try await runtime.steer(prompt: item.text, toTaskID: taskID)
            queuedPrompts[taskID]?.removeAll { $0.id == id }
            if let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) {
                let entry = TimelineEntry(kind: .user, title: "You", body: item.text,
                    timestamp: submission.submittedAt, activityGroupID: submission.activityGroupID)
                tasks[taskIndex].entries.insert(entry, at: min(submission.transcriptPosition, tasks[taskIndex].entries.count))
                tasks[taskIndex].updatedAt = .now
                if selectedTaskID == taskID { selectedEntryID = entry.id }
            }
            // A completion can arrive while the steering acknowledgement is in
            // flight. Resume the queue only after acceptance has been resolved.
            if tasks.first(where: { $0.id == taskID })?.status == .completed {
                scheduleQueueDrain(taskID: taskID)
            }
            return true
        } catch {
            failQueuedPrompt(taskID: taskID, id: id, message: "Steering was not confirmed. Review the conversation before resending. \(error.localizedDescription)")
            return false
        }
    }

    private func validatedPrompt(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf8.count <= 200_000 ? text : nil
    }

    private func editableQueueIndex(taskID: String, id: String) -> Int? {
        guard !isShuttingDown, tasks.contains(where: { $0.id == taskID }) else { return nil }
        return queuedPrompts[taskID]?.firstIndex { $0.id == id && $0.status != .sending }
    }

    private func scheduleQueueDrain(taskID: String) {
        Task { @MainActor [weak self] in await self?.drainQueue(taskID: taskID) }
    }

    private func drainQueue(taskID: String) async {
        guard !isShuttingDown, !isBusy(taskID: taskID),
              !dispatchingQueueTaskIDs.contains(taskID),
              !pausedQueueTaskIDs.contains(taskID),
              let item = queuedPrompts[taskID]?.first, item.status == .queued else { return }
        dispatchingQueueTaskIDs.insert(taskID)
        queuedPrompts[taskID]?[0].status = .sending
        let delivery = await submitDelivery(prompt: item.text, toTaskID: taskID)
        let delivered = delivery.wasDelivered
        if delivered {
            queuedPrompts[taskID]?.removeAll { $0.id == item.id }
        } else {
            switch delivery {
            case .notDelivered(let reason):
                failQueuedPrompt(taskID: taskID, id: item.id,
                    message: "The prompt was not delivered. \(reason)", deliveryUncertain: false)
            case .uncertain:
                failQueuedPrompt(taskID: taskID, id: item.id, message: "Delivery was not confirmed. Review the conversation before resending.")
            case .delivered: break
            }
        }
        dispatchingQueueTaskIDs.remove(taskID)
        retireWebsiteModelSelections()
        if delivered, tasks.first(where: { $0.id == taskID })?.status == .completed {
            scheduleQueueDrain(taskID: taskID)
        }
    }

    private func failQueuedPrompt(taskID: String, id: String, message: String, deliveryUncertain: Bool = true) {
        if let index = queuedPrompts[taskID]?.firstIndex(where: { $0.id == id }) {
            queuedPrompts[taskID]?[index].status = .failed
            queuedPrompts[taskID]?[index].error = message
            queuedPrompts[taskID]?[index].deliveryUncertain = deliveryUncertain
        }
        pausedQueueTaskIDs.insert(taskID)
    }
}

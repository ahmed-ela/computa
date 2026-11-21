import Foundation

/// Routes each chat to one app-server process for the lifetime of its thread.
actor SelectableCodexRuntime: AgentRuntimeClient {
    nonisolated let providerName: String
    private let bundled: CodexAppServerRuntime
    private let cli: CodexAppServerRuntime
    private let providerChats: ProviderCLIChats
    private var providerOwners: [String: ProviderCLI] = [:]
    private let cliThreads: InstalledCodexCLI.Threads
    private var owners: [String: Bool] = [:]
    private var submitting = Set<String>()
    private var cliApprovals = Set<String>()
    private var listeners: [Task<Void, Never>] = []
    private let channel = AsyncStream<AgentRuntimeEvent>.makeStream()

    init(configuration: CodexAppServerRuntime.Configuration = .localQwen) {
        let events = channel.continuation
        providerChats = ProviderCLIChats(root: URL(fileURLWithPath: configuration.codexHomePath)
            .appendingPathComponent("ProviderCLIChats", isDirectory: true)) { events.yield($0) }
        bundled = CodexAppServerRuntime(configuration: configuration)
        providerName = bundled.providerName
        var native = configuration
        native.executable = .installedCLI
        native.backend = .external
        native.modelProvider = "openai"
        native.model = ""
        native.codexHomePath = URL(fileURLWithPath: configuration.codexHomePath)
            .appendingPathComponent("InstalledCLI", isDirectory: true).path
        cliThreads = .init(home: native.codexHomePath)
        cli = CodexAppServerRuntime(configuration: native)
    }

    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { channel.stream }

    private func listen() {
        guard listeners.isEmpty else { return }
        for (runtime, isCLI) in [(bundled, false), (cli, true)] {
            listeners.append(Task { [weak self] in
                for await event in runtime.events() {
                    guard !Task.isCancelled, let self else { return }
                    await self.forward(event, fromCLI: isCLI)
                }
            })
        }
    }

    private func forward(_ event: AgentRuntimeEvent, fromCLI: Bool) {
        switch event {
        case .connectionChanged where fromCLI: return
        case .approvalRequested(let request) where fromCLI: cliApprovals.insert(request.id)
        case .approvalResolved(let id) where fromCLI: cliApprovals.remove(id)
        default: break
        }
        channel.continuation.yield(event)
    }

    func loadTasks() async throws -> [AgentTask] {
        listen()
        let external = try await providerChats.load()
        for chat in external { providerOwners[chat.id] = ProviderCLI(modelID: chat.model) }
        let regular = try await bundled.loadTasks()
        for chat in regular { owners[chat.id] = false }
        let saved = try cliThreads.entries()
        guard !saved.isEmpty else { return (regular + external).sorted { $0.updatedAt > $1.updatedAt } }
        let native: [AgentTask]
        do { native = try await cli.loadTasks() }
        catch { native = saved.map { InstalledCodexCLI.unavailableTask(threadID: $0.key, modelID: $0.value, error: error) } }
        for chat in native { owners[chat.id] = true }
        return (regular + native + external).sorted { $0.updatedAt > $1.updatedAt }
    }

    func providerCLIModels(_ provider: ProviderCLI) async throws -> [LocalModelOption] { try await providerChats.models(provider) }

    func installedCLIModels() async throws -> [LocalModelOption] { try await cli.installedCLIModels() }

    func submit(prompt: String, toTaskID taskID: String, modelID: String) async throws {
        try await submit(prompt: prompt, toTaskID: taskID, modelID: modelID, accessMode: .askEveryTime)
    }

    func submit(prompt: String, toTaskID taskID: String, modelID: String, accessMode: AccessMode) async throws {
        listen()
        if let provider = ProviderCLI(modelID: modelID) {
            guard owners[taskID] == nil, providerOwners[taskID].map({ $0 == provider }) != false else { throw InstalledCodexCLI.Failure.differentRuntime }
            guard submitting.insert(taskID).inserted else { throw InstalledCodexCLI.Failure.busy }
            defer { submitting.remove(taskID) }
            let previous = providerOwners[taskID]
            providerOwners[taskID] = provider
            do { try await providerChats.submit(prompt, id: taskID, provider: provider, modelID: modelID) }
            catch { providerOwners[taskID] = previous; throw error }
            return
        }
        guard providerOwners[taskID] == nil else { throw InstalledCodexCLI.Failure.differentRuntime }
        let isCLI = InstalledCodexCLI.slug(modelID) != nil
        if let existing = owners[taskID], existing != isCLI { throw InstalledCodexCLI.Failure.differentRuntime }
        guard submitting.insert(taskID).inserted else { throw InstalledCodexCLI.Failure.busy }
        defer { submitting.remove(taskID) }
        owners[taskID] = isCLI
        let target = runtime(for: taskID)
        do { try await target.submit(prompt: prompt, toTaskID: taskID, modelID: modelID, accessMode: accessMode) }
        catch {
            if !(await target.hasBoundThread(taskID: taskID)) { owners.removeValue(forKey: taskID) }
            throw error
        }
    }

    private func runtime(for id: String) -> CodexAppServerRuntime { owners[id] == true ? cli : bundled }
    func configureWorkspace(path: String, forTaskID id: String) async throws {
        await providerChats.setDirectory(path, for: id)
        if providerOwners[id] != nil { return }
        if owners[id] != nil {
            try await runtime(for: id).configureWorkspace(path: path, forTaskID: id)
        } else {
            try await bundled.configureWorkspace(path: path, forTaskID: id)
            try await cli.configureWorkspace(path: path, forTaskID: id)
        }
    }
    func steer(prompt: String, toTaskID id: String) async throws {
        guard providerOwners[id] == nil else { throw AgentRuntimeCapabilityError.steeringUnsupported }
        try await runtime(for: id).steer(prompt: prompt, toTaskID: id)
    }
    func compact(taskID: String) async throws {
        guard providerOwners[taskID] == nil else { throw AgentRuntimeCapabilityError.compactionUnsupported }
        try await runtime(for: taskID).compact(taskID: taskID)
    }
    func interrupt(taskID: String) async throws {
        if providerOwners[taskID] != nil { await providerChats.interrupt(taskID); return }
        try await runtime(for: taskID).interrupt(taskID: taskID)
    }
    func retryWebsiteSessionCleanup(taskID: String) async -> WebsiteSessionCleanupReceipt {
        await runtime(for: taskID).retryWebsiteSessionCleanup(taskID: taskID)
    }
    func resolveApproval(requestID: String, approved: Bool) async throws {
        if requestID.hasPrefix("provider-cli/") { try await providerChats.approve(requestID, approved); return }
        try await (cliApprovals.contains(requestID) ? cli : bundled).resolveApproval(requestID: requestID, approved: approved)
    }
    func configureAPIProviders(_ providers: [APIProviderDefinition], credentialMutation: @escaping @Sendable () throws -> Void) async throws {
        try await bundled.configureAPIProviders(providers, credentialMutation: credentialMutation)
    }
    func configureEmbeddedWebModelTransport(_ transport: any WebModelTransport) async {
        await bundled.configureEmbeddedWebModelTransport(transport)
    }
    func configureEmbeddedBrowserTools(_ controller: EmbeddedBrowserToolController) async {
        await bundled.configureEmbeddedBrowserTools(controller)
        await cli.configureEmbeddedBrowserTools(controller)
    }
    func shutdown() async -> RuntimeShutdownReport {
        async let mainReport = bundled.shutdown()
        async let cliReport = cli.shutdown()
        let providerIssues = await providerChats.shutdown()
        let reports = await [mainReport, cliReport]
        for listener in listeners { await listener.value }
        channel.continuation.finish()
        return RuntimeShutdownReport(issues: reports.flatMap(\.issues) + providerIssues)
    }
}

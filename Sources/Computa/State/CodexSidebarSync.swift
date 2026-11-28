import Foundation
import Observation

/// The official account is consulted only by the source picker and Import.
@MainActor @Observable
final class CodexSidebarSync {
    typealias Client = CodexDesktopSidebarClient
    struct Reader: Codable, Equatable, Sendable {
        let request: UUID
        let id: String
        var title: String
    }
    @ObservationIgnored private let makeClient: @MainActor () -> Client
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var database: CodexImportStore?
    private(set) var library: [Client.Chat] = []
    private(set) var error: String?
    private var catalogs: [UUID: Client.Catalog] = [:]
    private var queries: [UUID: UUID] = [:]
    private var disclosure: [UUID: [String: Bool]] = [:]

    static func installed(
        preferences: UserDefaults, candidates: [URL] = InstalledCodexCLI.candidateURLs,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        profile: URL = InstalledCodexCLI.userProfile, directory: URL? = nil
    ) -> CodexSidebarSync? {
        let folder =
            directory
            ?? URL(fileURLWithPath: CodexAppServerRuntime.Configuration.localQwen.codexHomePath)
            .appendingPathComponent("CodexImports", isDirectory: true)
        return .init(directory: folder) { Client(candidates: candidates, home: home, codexHome: profile) }
    }

    init(directory: URL, makeClient: @escaping @MainActor () -> Client) {
        self.directory = directory
        self.makeClient = makeClient
    }

    private func store() throws -> CodexImportStore {
        if let database { return database }
        let opened = try CodexImportStore(directory: directory)
        database = opened
        return opened
    }
    private func reload() throws {
        library = try store().list().map { Client.Chat(id: $0.id, title: $0.title, updatedAt: $0.updated) }
    }
    func attach(_ window: WorkspaceTabs) {
        do {
            try reload()
            if window.desktopReader == nil, let id = window.importedChatID { open(id, in: window) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func detach(_ window: WorkspaceTabs) {
        window.desktopReader = nil
        closePicker(window)
    }
    private func closePicker(_ window: WorkspaceTabs) {
        queries[window.id] = nil
        catalogs[window.id] = nil
        disclosure[window.id] = nil
        window.codexImportRequest = nil
        window.codexImportError = nil
    }
    func sections(in window: WorkspaceTabs) -> [Client.Section] {
        guard window.codexImportRequest != nil else {
            return [
                .init(
                    id: "imports", name: "Imported chats", chats: library, isCollapsed: disclosure[window.id]?["imports"] ?? false
                )
            ]
        }
        return (catalogs[window.id]?.sections ?? []).map {
            var section = $0
            section.isCollapsed = disclosure[window.id]?[$0.id] ?? $0.isCollapsed
            return section
        }
    }
    func setCollapsed(_ collapsed: Bool, sectionID: String, in window: WorkspaceTabs) {
        disclosure[window.id, default: [:]][sectionID] = collapsed
    }
    func open(_ id: String, in window: WorkspaceTabs) {
        guard !window.isClosed, window.showsDesktopChats, let row = library.first(where: { $0.id == id }) else { return }
        closePicker(window)
        if window.desktopReader?.id != id { window.desktopReader = .init(request: UUID(), id: id, title: row.title) }
        window.importedChatID = id
    }
    func browse(in window: WorkspaceTabs) async {
        guard window.showsDesktopChats, !window.isClosed else { return }
        closePicker(window)
        let token = UUID()
        queries[window.id] = token
        window.codexImportRequest = token
        let client = makeClient()
        do {
            let catalog = try await client.catalog()
            if queries[window.id] == token { catalogs[window.id] = catalog }
        } catch { if queries[window.id] == token { window.codexImportError = error.localizedDescription } }
        await client.close()
    }
    func cancelBrowse(in window: WorkspaceTabs) { closePicker(window) }

    func importChat(_ id: String, request: UUID, in window: WorkspaceTabs) async throws -> String {
        guard !window.isClosed, window.showsDesktopChats, window.codexImportRequest == request, queries[window.id] == request,
            let catalog = catalogs[window.id], let owner = CodexDesktopLayout.ownerKey(for: catalog.account),
            let row = catalog.sections.lazy.flatMap(\.chats).first(where: { $0.id == id })
        else { throw Client.Failure.noChat }
        let client = makeClient()
        do {
            // A new connection rechecks both the signed-in account and current membership.
            try await client.checkImportSource(id, owner: catalog.account)
            let db = try store()
            let local: String
            if let existing = try db.existing(owner: owner, source: id) {
                local = existing
            } else {
                let snapshot = try await client.importSnapshot(id, owner: catalog.account, title: row.title)
                guard queries[window.id] == request, !window.isClosed else { throw CancellationError() }
                local = try db.accepted(owner: owner, source: id, snapshot: snapshot)
            }
            guard queries[window.id] == request, !window.isClosed else { throw CancellationError() }
            try reload()
            open(local, in: window)
            await client.close()
            return local
        } catch {
            await client.close()
            throw error
        }
    }

    func conversation(_ action: String, body: [String: Any], in window: WorkspaceTabs, runtime: (any AgentRuntimeClient)? = nil,
                      websiteOptions: [LocalModelOption] = [])
        async throws -> Any
    {
        guard !window.isClosed, window.showsDesktopChats, let id = body["thread"] as? String,
            let token = (body["selection"] as? String).flatMap(UUID.init(uuidString:))
        else { throw Client.Failure.noChat }
        if action == "import" { return try await importChat(id, request: token, in: window) }
        guard window.codexImportRequest == nil, let reader = window.desktopReader, reader.id == id, reader.request == token
        else { throw Client.Failure.noChat }
        let db = try store()
        if action == "page" {
            return try db.page(id, cursor: body["cursor"] as? String, ascending: body["direction"] as? String == "asc")
        }
        let current = try db.selectedModel(id)
        if action == "currentModel" { return current }
        guard let runtime else { throw InstalledCodexCLI.Failure.missing }
        func choices(_ provider: String) async throws -> [LocalModelOption] {
            if provider.hasPrefix("browser/") {
                return websiteOptions.filter { option in
                    guard let selected = WebsiteModelCatalog.importedSelection(for: option.id) else { return false }
                    return provider == "browser/" + selected.provider && option.available != false && option.selectable != false
                }
            }
            if provider == "codex" { return try await runtime.installedCLIModels() }
            guard let route = ProviderCLI(rawValue: provider), [.antigravity, .claude].contains(route) else {
                throw Client.Failure.unavailableModel
            }
            return try await runtime.providerCLIModels(route).filter { ProviderCLI.conversationProvider(for: $0.id) == route }
        }
        if action == "models", let provider = body["provider"] as? String {
            return try await choices(provider).filter { $0.available != false && $0.selectable != false }.map {
                ["model": $0.id, "displayName": $0.label]
            }
        }
        guard body["expected"] as? String == current else {
            throw AgentCLIError.unavailable("The model changed in another window.")
        }
        let lease = try db.lease(id)
        defer { withExtendedLifetime(lease) {} }
        switch action {
        case "changeModel":
            guard let model = body["model"] as? String else { throw Client.Failure.unavailableModel }
            let provider = WebsiteModelCatalog.importedSelection(for: model).map { "browser/" + $0.provider }
                ?? (InstalledCodexCLI.slug(model) != nil ? "codex" : ProviderCLI.conversationProvider(for: model)?.rawValue)
            guard let provider,
                try await choices(provider).contains(where: { $0.id == model && $0.available != false && $0.selectable != false }
                ),
                window.desktopReader == reader, window.codexImportRequest == nil, window.showsDesktopChats, !window.isClosed
            else { throw Client.Failure.unavailableModel }
            try db.select(model, id: id, expected: current)
            return model
        case "send":
            guard !current.isEmpty, let text = body["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                text.utf16.count <= 200_000, let submission = (body["submission"] as? String).flatMap(UUID.init(uuidString:))
            else { throw Client.Failure.inconsistent }
            if current.hasPrefix("browser/") {
                guard let selection = WebsiteModelCatalog.importedSelection(for: current),
                      try await choices("browser/" + selection.provider).contains(where: { $0.id == current })
                else { throw Client.Failure.unavailableModel }
            }
            let prompt = try db.begin(text, submission: submission, chat: id, model: current)
            do {
                let reply = try await runtime.conversationReply(prompt, model: current, chat: id, submission: submission)
                try db.finish(submission, chat: id, model: current, result: .success(reply))
            } catch {
                try db.finish(submission, chat: id, model: current, result: .failure(error))
                throw error
            }
            try reload()
            return true
        default: throw Client.Failure.inconsistent
        }
    }
}

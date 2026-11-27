import Foundation
import Observation

/// One live source per app, with independent conversation selection per window.
@MainActor @Observable
final class CodexSidebarSync {
    typealias Client = CodexDesktopSidebarClient
    struct Reader: Codable, Equatable, Sendable {
        let request: UUID
        let id: String
        var title: String
        var updatedAt: Double
        var messages: [Client.Message] = []
        var older: String?
        var loading = true
        var error: String?
    }

    private(set) var catalog: Client.Catalog?
    private(set) var error: String?
    @ObservationIgnored private let makeClient: @MainActor () -> Client
    private var disclosureOverrides: [String: Bool] = [:]
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var windows: [UUID: WorkspaceTabs] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var delay: Task<Void, Error>?
    @ObservationIgnored private var client: Client?
    @ObservationIgnored private var epoch = UUID()

    static func installed(preferences: UserDefaults) -> CodexSidebarSync? {
        guard let executable = Client.installedExecutable() else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return .init(preferences: preferences) { Client(executable: executable, home: home, codexHome: home.appendingPathComponent(".codex")) }
    }

    init(interval: Duration = .seconds(5), preferences: UserDefaults = .standard, makeClient: @escaping @MainActor () -> Client) {
        self.preferences = preferences
        self.makeClient = makeClient
        self.interval = interval
    }

    func attach(_ window: WorkspaceTabs) {
        windows[window.id] = window
        guard loop == nil else { return }
        let token = UUID()
        epoch = token
        let source = makeClient()
        client = source
        loop = Task { [weak self] in
            while !Task.isCancelled, let self, self.epoch == token {
                var wait = self.interval
                do {
                    let next = try await source.catalog()
                    guard !Task.isCancelled, self.epoch == token else { break }
                    self.update(next)
                    self.error = nil
                } catch {
                    guard !Task.isCancelled, self.epoch == token else { break }
                    self.update(nil)
                    self.error = error.localizedDescription
                    await source.close()
                    wait = max(wait, .seconds(10))
                }
                guard !Task.isCancelled, self.epoch == token else { break }
                let sleep = Task { [wait] in try await Task.sleep(for: wait) }
                self.delay = sleep
                _ = await sleep.result
                if self.epoch == token { self.delay = nil }
            }
            await source.close()
        }
    }

    func becameActive() { delay?.cancel() }

    func detach(_ window: WorkspaceTabs) {
        window.desktopReader = nil
        windows.removeValue(forKey: window.id)
        guard windows.isEmpty else { return }
        epoch = UUID()
        delay?.cancel()
        loop?.cancel()
        loop = nil
        client = nil
        catalog = nil
        disclosureOverrides = [:]
        error = nil
    }

    var presentedSections: [Client.Section] {
        let sections = catalog?.sections ?? []
        guard !disclosureOverrides.isEmpty else { return sections }
        return sections.map { section in
            var presented = section
            presented.isCollapsed = disclosureOverrides[section.id] ?? section.isCollapsed
            return presented
        }
    }

    private func preferenceKey(_ account: Client.Account) -> String? {
        CodexDesktopLayout.ownerKey(for: account).map { "codexDesktopSectionDisclosures." + $0 }
    }

    private func saveOverrides(for account: Client.Account) {
        guard let key = preferenceKey(account) else { return }
        if disclosureOverrides.isEmpty { preferences.removeObject(forKey: key) }
        else { preferences.set(disclosureOverrides, forKey: key) }
    }

    func setCollapsed(_ collapsed: Bool, sectionID: String) {
        guard let catalog, let section = catalog.sections.first(where: { $0.id == sectionID }) else { return }
        disclosureOverrides[sectionID] = collapsed == section.isCollapsed ? nil : collapsed
        saveOverrides(for: catalog.account)
    }

    func update(_ next: Client.Catalog?) {
        let accountChanged = catalog?.account != next?.account
        if catalog != next {
            if accountChanged {
                let key = next.flatMap { preferenceKey($0.account) }
                disclosureOverrides = key.flatMap { preferences.dictionary(forKey: $0) as? [String: Bool] } ?? [:]
            }
            if let next, !disclosureOverrides.isEmpty {
                // Once the desktop agrees with a local choice, follow its further changes again.
                var remaining: [String: Bool] = [:]
                for section in next.sections {
                    if let choice = disclosureOverrides[section.id], choice != section.isCollapsed {
                        remaining[section.id] = choice
                    }
                }
                if remaining != disclosureOverrides {
                    disclosureOverrides = remaining
                    saveOverrides(for: next.account)
                }
            }
            catalog = next
        }
        for window in windows.values {
            guard let reader = window.desktopReader else { continue }
            guard !accountChanged, let row = chat(reader.id) else { window.desktopReader = nil; continue }
            if row.updatedAt != reader.updatedAt && window.showsDesktopChats { open(row.id, in: window) }
            else if row.title != reader.title { window.desktopReader?.title = row.title }
        }
    }

    private func chat(_ id: String) -> Client.Chat? {
        for section in catalog?.sections ?? [] {
            if let row = section.chats.first(where: { $0.id == id }) { return row }
        }
        return nil
    }

    func open(_ id: String, in window: WorkspaceTabs) {
        guard !window.isClosed, window.showsDesktopChats, let row = chat(id) else { return }
        window.desktopReader = .init(request: UUID(), id: row.id, title: row.title, updatedAt: row.updatedAt)
        load(in: window)
    }

    func older(in window: WorkspaceTabs) {
        guard window.showsDesktopChats, let reader = window.desktopReader, !reader.loading,
              reader.older != nil || reader.error != nil else { return }
        window.desktopReader?.loading = true
        window.desktopReader?.error = nil
        load(in: window)
    }

    private func load(in window: WorkspaceTabs) {
        guard let client, let account = catalog?.account, let reader = window.desktopReader else { return }
        let token = epoch
        Task {
            do {
                let page = try await client.messages(for: reader.id, account: account, before: reader.older)
                guard token == epoch, !window.isClosed, window.desktopReader?.request == reader.request else { return }
                var seen = Set(reader.messages.map(\.id))
                window.desktopReader?.messages.insert(contentsOf: page.list.filter { seen.insert($0.id).inserted }, at: 0)
                window.desktopReader?.older = page.older
            } catch {
                guard token == epoch, !window.isClosed, window.desktopReader?.request == reader.request else { return }
                window.desktopReader?.error = error.localizedDescription
            }
            window.desktopReader?.loading = false
        }
    }
}

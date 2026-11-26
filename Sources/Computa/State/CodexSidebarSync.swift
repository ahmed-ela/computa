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
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var windows: [UUID: WorkspaceTabs] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var delay: Task<Void, Error>?
    @ObservationIgnored private var client: Client?
    @ObservationIgnored private var epoch = UUID()

    static func installed() -> CodexSidebarSync? {
        guard let executable = Client.installedExecutable() else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return .init { Client(executable: executable, home: home, codexHome: home.appendingPathComponent(".codex")) }
    }

    init(interval: Duration = .seconds(5), makeClient: @escaping @MainActor () -> Client) {
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
        error = nil
    }

    private func update(_ next: Client.Catalog?) {
        let accountChanged = catalog?.account != next?.account
        if catalog != next { catalog = next }
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

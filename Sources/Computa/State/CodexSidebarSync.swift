import AppKit
import Observation

/// One live source per app, with independent conversation selection per window.
@MainActor @Observable
final class CodexSidebarSync {
    typealias Client = CodexDesktopSidebarClient
    struct Reader: Codable, Equatable, Sendable {
        let request: UUID
        let id: String
        var title: String
    }

    private(set) var catalog: Client.Catalog?
    private(set) var error: String?
    @ObservationIgnored private let makeClient: @MainActor () -> Client
    private var disclosureOverrides: [String: Bool] = [:]
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let wake: @MainActor (UUID) async throws -> Void
    @ObservationIgnored private var modelWrites = Set<String>()
    @ObservationIgnored private var submissions = Set<UUID>()
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var windows: [UUID: WorkspaceTabs] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var delay: Task<Void, Error>?
    @ObservationIgnored private var client: Client?
    @ObservationIgnored private var epoch = UUID()

    static func installed(preferences: UserDefaults, candidates: [URL] = InstalledCodexCLI.candidateURLs,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          profile: URL = InstalledCodexCLI.userProfile) -> CodexSidebarSync? {
        guard candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        return .init(preferences: preferences) { Client(candidates: candidates, home: home, codexHome: profile) }
    }

    init(interval: Duration = .seconds(5), preferences: UserDefaults = .standard,
         wake: @escaping @MainActor (UUID) async throws -> Void = CodexSidebarSync.wakeDesktop,
         makeClient: @escaping @MainActor () -> Client) {
        self.preferences = preferences
        self.wake = wake
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
            if row.title != reader.title { window.desktopReader?.title = row.title }
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
        if window.desktopReader?.id != id {
            window.desktopReader = .init(request: UUID(), id: row.id, title: row.title)
        }
    }

    static func wakeURL(_ id: UUID) -> URL {
        URL(string: "codex://threads/wake/" + id.uuidString.lowercased())!
    }

    private static func wakeDesktop(_ id: UUID) async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Client.bundleID).first(where: { !$0.isTerminated })?.bundleURL else { throw Client.Failure.ownerUnavailable }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.open([wakeURL(id)], withApplicationAt: app, configuration: config)
    }

    func conversation(_ action: String, body: [String: Any], in window: WorkspaceTabs, runtime: (any AgentRuntimeClient)? = nil, accessMode: AccessMode = .askEveryTime) async throws -> Any {
        guard !window.isClosed, window.showsDesktopChats, let client, let owner = catalog?.account,
              let reader = window.desktopReader, body["thread"] as? String == reader.id,
              let token = body["selection"] as? String, UUID(uuidString: token) == reader.request,
              chat(reader.id) != nil, let thread = UUID(uuidString: reader.id) else { throw Client.Failure.noChat }
        let response: Any
        switch action {
        case "page":
            let bytes = try await client.conversationPage(reader.id, owner: owner, cursor: body["cursor"] as? String, ascending: body["direction"] as? String == "asc")
            response = try JSONSerialization.jsonObject(with: bytes)
        case "item":
            guard let turn = body["turn"] as? String, let item = body["item"] as? String else { throw Client.Failure.noChat }
            let bytes = try await client.itemDetails(reader.id, owner: owner, turn: turn, item: item)
            response = try JSONSerialization.jsonObject(with: bytes)
        case "models":
            response = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try await client.modelSelection(reader.id, owner: owner)))
        case "currentModel":
            response = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try await client.currentModel(reader.id, owner: owner)))
        case "changeModel":
            guard let model = body["model"] as? String, !model.isEmpty, modelWrites.insert(reader.id).inserted else { throw Client.Failure.inconsistent }
            defer { modelWrites.remove(reader.id) }
            let selection = try await client.modelSelection(reader.id, owner: owner)
            guard selection.choices.contains(where: { $0.model == model }) else { throw Client.Failure.unavailableModel }
            guard selection.state.current == body["expected"] as? String else { throw Client.Failure.modelChanged }
            guard try await client.queuedMessages(reader.id, owner: owner).isEmpty else { throw Client.Failure.pendingQueue }
            response = "nextTurn"
        case "queue":
            response = try await client.queuedMessages(reader.id, owner: owner)
        case "wake":
            if !(try await client.queuedMessages(reader.id, owner: owner)).isEmpty { try await wake(thread) }
            response = true
        case "send":
            guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf16.count <= 200_000, let raw = body["submission"] as? String, let submission = UUID(uuidString: raw),
                  submissions.insert(submission).inserted else { throw Client.Failure.inconsistent }
            guard modelWrites.insert(reader.id).inserted else { throw Client.Failure.inconsistent }
            defer { modelWrites.remove(reader.id) }
            let expected = body["expected"] as? String
            let selection = try await client.modelSelection(reader.id, owner: owner)
            guard selection.state.current == expected else { throw Client.Failure.modelChanged }
            guard let model = body["model"] as? String ?? expected,
                  selection.choices.contains(where: { $0.model == model }) else { throw Client.Failure.unavailableModel }
            do {
                do {
                    try await client.sendWithModel(model, replacing: expected, text: text, submission: submission, in: reader.id, owner: owner)
                } catch Client.Failure.ownerUnavailable {
                    guard let runtime else { throw InstalledCodexCLI.Failure.missing }
                    try await runtime.continueCodexConversation(.init(profile: client.codexHome, thread: reader.id, owner: owner,
                        expected: expected, provider: selection.provider, model: model, prompt: text, submission: submission), accessMode: accessMode)
                }
                response = "started"
            } catch Client.Failure.ownerUnavailable where body["model"] == nil,
                    Client.Failure.pendingQueue where body["model"] == nil,
                    Client.Failure.busyThread where body["model"] == nil {
                // The private owner was already running. Preserve a follow-up's
                // queue semantics; a model-bound message must never enter this path.
                do { try await client.enqueue(text, submission: submission, in: reader.id, owner: owner, expectedModel: expected) }
                catch Client.Failure.deliveryUnconfirmed { return "unconfirmed" }
                do { try await wake(thread); response = "queued" }
                catch { response = "queuedWakeFailed" }
            } catch Client.Failure.deliveryUnconfirmed { response = "unconfirmed" }
        default: throw Client.Failure.inconsistent
        }
        guard !window.isClosed, window.showsDesktopChats, catalog?.account == owner,
              window.desktopReader?.request == reader.request else { throw Client.Failure.noChat }
        return response
    }
}

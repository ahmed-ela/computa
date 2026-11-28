import AppKit
import Foundation

/// A client of the app-server shipped inside the official desktop application.
actor CodexDesktopSidebarClient {
    struct Chat: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let updatedAt: Double
    }
    struct Section: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let chats: [Chat]
        var isCollapsed = false
    }
    struct Catalog: Equatable, Sendable {
        let account: Account
        let sections: [Section]
    }
    struct Account: Equatable, Sendable {
        let userID: String?
        let workspaceID: String?
        let type: String
        let email: String?
        let workspaceName: String?
    }
    enum Failure: LocalizedError {
        case signedOut, inconsistent, noChat, deliveryUnconfirmed, modelChanged, unavailableModel, pendingQueue, ownerUnavailable, busyThread
        var errorDescription: String? {
            switch self {
            case .modelChanged: "The model changed in Codex. Check the current selection before sending."
            case .unavailableModel: "This model is no longer available for this Codex chat."
            case .ownerUnavailable: "Open this chat in Codex to change its model."
            case .busyThread: "Wait for the current Codex turn to finish before sending with a selected model."
            case .pendingQueue: "Wait for Codex to process the queued messages before switching models."
            case .signedOut: "Sign in to the Codex desktop app to see your chats."
            case .inconsistent: "The Codex sidebar changed while it was loading."
            case .deliveryUnconfirmed: "Message delivery is unconfirmed. Check the conversation in Codex."
            case .noChat: "This chat is no longer in the current Codex account."
            }
        }
    }

    // Reserved by the official desktop protocol, including in an empty profile.
    static let pinnedID = "01984de2-8f74-7c91-a3b2-5c5e937cf318"
    static let recentID = "recent"
    static let bundleID = "com.openai.codex"

    @MainActor static func installedExecutable() -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
            .map { app.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private let executable: URL
    private let home: URL
    private let codexHome: URL
    private var connection: AgentCLIConnection?
    private var opening: Task<AgentCLIConnection, Error>?
    private var generation = UUID()
    private struct AuthFile: Equatable {
        let inode: UInt64
        let changed: Date
    }
    private var authFile: AuthFile?

    // The app-server caches account/read events from its own login flow. An
    // independent desktop sign-out or account change must retire that connection.
    private func currentAuthFile() -> AuthFile? {
        let file = codexHome.appendingPathComponent("auth.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return AuthFile(inode: inode.uint64Value, changed: date)
    }

    private func refreshAccountSession() async {
        let current = currentAuthFile()
        if current != authFile || (current == nil && connection != nil) {
            authFile = current
            await close()
        }
    }

    init(executable: URL, home: URL, codexHome: URL) {
        self.executable = executable
        self.home = home
        self.codexHome = codexHome
    }

    private func session() async throws -> AgentCLIConnection {
        if let connection { return connection }
        let token = generation
        if let opening {
            let result = try await opening.value
            guard generation == token else { throw CancellationError() }
            return result
        }
        let task = Task { [executable, home, codexHome] () throws -> AgentCLIConnection in
            var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "LANG", "TMPDIR", "USER", "LOGNAME"].contains($0.key) }
            environment["HOME"] = home.path
            environment["CODEX_HOME"] = codexHome.path
            let conn = try AgentCLIConnection(executable: executable, arguments: InstalledCodexCLI.arguments,
                directory: home, environment: environment, codexProtocol: true) { _ in }
            do {
                _ = try await conn.request("initialize", params: Data(#"{"clientInfo":{"name":"kolmogor_sidebar","version":"1"},"capabilities":{"experimentalApi":true}}"#.utf8), timeout: .seconds(10))
                try await conn.send(Data(#"{"method":"initialized"}"#.utf8))
                try Task.checkCancellation()
                return conn
            } catch { _ = await conn.close(); throw error }
        }
        opening = task
        defer { if generation == token { opening = nil } }
        let conn = try await task.value
        guard generation == token else {
            await conn.close()
            throw CancellationError()
        }
        connection = conn
        return conn
    }

    func close() async {
        generation = UUID()
        opening?.cancel()
        opening = nil
        let current = connection
        connection = nil
        _ = await current?.close()
    }

    private struct Page<Row: Decodable>: Decodable {
        let data: [Row]
        let nextCursor: String?
    }
    private struct Group: Decodable {
        let id: String
        let name: String
    }
    private struct Row: Decodable {
        let id: String
        let name: String?
        let preview: String
        let updatedAt: Double
        let section: Group?
        var chat: Chat {
            let fallback = preview.isEmpty ? "Untitled chat" : String(preview.prefix(2_000))
            return Chat(id: id, title: name.flatMap { $0.isEmpty ? nil : $0 } ?? fallback, updatedAt: updatedAt)
        }
    }
    private static let visible: [String: any Sendable] = ["archived": false, "currentAccountOnly": true, "useStateDbOnly": true]
    private func read<T: Decodable>(_ type: T.Type, _ method: String, _ params: [String: any Sendable]) async throws -> T {
        let conn = try await session()
        let data = try await conn.request(method, params: JSONSerialization.data(withJSONObject: params), timeout: .seconds(15))
        return try JSONDecoder().decode(type, from: data)
    }
    private func all<T: Decodable>(_ type: T.Type, _ method: String, _ params: [String: any Sendable]) async throws -> [T] {
        var params = params, seen = Set<String>(), rows: [T] = []
        params["limit"] = 100
        while true {
            try Task.checkCancellation()
            let page = try await read(Page<T>.self, method, params)
            rows.append(contentsOf: page.data)
            guard let next = page.nextCursor else { return rows }
            guard !next.isEmpty, seen.insert(next).inserted else { throw Failure.inconsistent }
            params["cursor"] = next
        }
    }

    func account() async throws -> Account { try await account(on: session()) }

    private func account(on conn: AgentCLIConnection) async throws -> Account {
        struct Reply: Decodable {
            struct Identity: Decodable {
                let type: String
                let email: String?
                let workspaceName: String?
            }
            struct Routing: Decodable { let chatgptAccountId: String }
            let userId: String?
            let account: Identity?
            let workspaceRouting: Routing?
        }
        let bytes = try await conn.request("account/read", params: Data("{}".utf8), timeout: .seconds(10))
        let reply = try JSONDecoder().decode(Reply.self, from: bytes)
        guard let identity = reply.account else { throw Failure.signedOut }
        return Account(userID: reply.userId, workspaceID: reply.workspaceRouting?.chatgptAccountId,
                       type: identity.type, email: identity.email, workspaceName: identity.workspaceName)
    }

    func catalog() async throws -> Catalog {
        do { return try await snapshot() }
        catch Failure.inconsistent { return try await snapshot() }
    }

    private func snapshot() async throws -> Catalog {
        await refreshAccountSession()
        let owner = try await account()
        let layout = try CodexDesktopLayout.read(from: codexHome, account: owner)
        let groups = try await all(Group.self, "threadSection/list", [:])
        // Recent follows chat activity. Background metadata changes can also advance updated_at.
        let list = try await all(Row.self, "thread/list", Self.visible.merging(["sortKey": "recency_at", "sortDirection": "desc"]) { _, new in new })
        let ids = Set(list.map(\.id))
        guard ids.count == list.count, Set(groups.map(\.id)).count == groups.count else { throw Failure.inconsistent }
        var sections: [Section] = [], claimed = Set<String>()
        for group in groups {
            let ordered = try await all(Row.self, "thread/list", Self.visible.merging(["sectionId": group.id,
                "sortKey": "section_position", "sortDirection": "asc"]) { _, new in new })
            let members = Set(ordered.map(\.id))
            guard members == Set(list.filter { $0.section?.id == group.id }.map(\.id)),
                  members.count == ordered.count, claimed.isDisjoint(with: members) else { throw Failure.inconsistent }
            claimed.formUnion(members)
            let section = Section(id: group.id, name: group.name, chats: ordered.map(\.chat))
            if group.id == Self.pinnedID { sections.insert(section, at: 0) } else { sections.append(section) }
        }
        guard claimed == Set(list.filter { $0.section != nil }.map(\.id)), try await account() == owner, currentAuthFile() == authFile else { throw Failure.inconsistent }
        sections.append(Section(id: Self.recentID, name: "Recent", chats: list.filter { !claimed.contains($0.id) }.map(\.chat)))
        return Catalog(account: owner, sections: layout.arrange(sections))
    }

    private func verifyVisible(_ id: String, owner: Account) async throws {
        guard UUID(uuidString: id) != nil, currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        let rows = try await all(Row.self, "thread/list", Self.visible.merging(["includedThreadIds": [id]]) { _, new in new })
        guard rows.contains(where: { $0.id == id }), currentAuthFile() == authFile else { throw Failure.noChat }
    }

    struct ModelOption: Codable, Equatable, Sendable {
        let model: String
        let displayName: String
        let hidden: Bool
    }

    struct ModelState: Codable, Sendable {
        let current: String?
        let live: Bool
    }

    struct ModelSelection: Codable, Sendable {
        let state: ModelState
        let choices: [ModelOption]
    }

    private struct ThreadModel: Decodable {
        let id: String
        struct Status: Decodable { let type: String }
        let status: Status
        let modelProvider: String
        let model: String?
    }

    private func threadModel(_ id: String, owner: Account) async throws -> ThreadModel {
        struct Reply: Decodable { let thread: ThreadModel }
        try await verifyVisible(id, owner: owner)
        let row = try await read(Reply.self, "thread/read", ["threadId": id]).thread
        guard row.id == id, currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        return row
    }

    private func modelState(_ row: ThreadModel, owner: Account) async throws -> ModelState {
        if let conn = try await CodexDesktopOwner.connect(home: codexHome) {
            do {
                guard try await account(on: conn) == owner else { throw Failure.noChat }
                let live = try await liveModel(row.id, on: conn)
                await conn.close()
                guard currentAuthFile() == authFile else { throw Failure.noChat }
                if live.status.type != "notLoaded" { return ModelState(current: live.model, live: true) }
            } catch { await conn.close(); throw error }
        }
        return ModelState(current: row.model, live: false)
    }

    func currentModel(_ id: String, owner: Account) async throws -> ModelState {
        try await modelState(threadModel(id, owner: owner), owner: owner)
    }

    func modelSelection(_ id: String, owner: Account) async throws -> ModelSelection {
        let row = try await threadModel(id, owner: owner)
        let options = try await all(ModelOption.self, "model/list", ["modelProvider": row.modelProvider, "includeHidden": false])
        var seen = Set<String>()
        let visible = options.filter { !$0.hidden && !$0.model.isEmpty && seen.insert($0.model).inserted }
        guard currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        return ModelSelection(state: try await modelState(row, owner: owner), choices: visible)
    }

    // Codex locks a conversation to its active writer. Resuming an unowned
    // conversation can also start its queued turn immediately. Keep this
    // sidebar client read-only with respect to the conversation's execution.
    private func withIdleOwner<T: Sendable>(_ id: String, owner: Account, expected: String?,
                                             perform: (AgentCLIConnection) async throws -> T) async throws -> T {
        guard let conn = try await CodexDesktopOwner.connect(home: codexHome) else {
            // A queue can change after the picker opens. Changing the model in
            // the desktop could also reroute a previously queued prompt.
            guard try await queuedMessages(id, owner: owner).isEmpty else { throw Failure.pendingQueue }
            throw Failure.ownerUnavailable
        }
        do {
            try await verifyVisible(id, owner: owner)
            guard try await account(on: conn) == owner else { throw Failure.noChat }
            let row = try await liveModel(id, on: conn)
            guard try await queuedMessages(id, owner: owner).isEmpty else { throw Failure.pendingQueue }
            guard row.status.type != "notLoaded" else { throw Failure.ownerUnavailable }
            guard row.status.type == "idle" else { throw Failure.busyThread }
            guard row.model == expected else { throw Failure.modelChanged }
            let result = try await perform(conn)
            await conn.close()
            return result
        } catch { await conn.close(); throw error }
    }

    private func liveModel(_ id: String, on conn: AgentCLIConnection) async throws -> ThreadModel {
        struct Reply: Decodable { let thread: ThreadModel }
        let result = try await conn.request("thread/read", params: JSONEncoder().encode(["threadId": id]), timeout: .seconds(10))
        let row = try JSONDecoder().decode(Reply.self, from: result).thread
        guard row.id == id else { throw Failure.noChat }
        return row
    }

    func selectModel(_ model: String, replacing expected: String?, in id: String, owner: Account) async throws {
        let catalog = try await modelSelection(id, owner: owner)
        guard catalog.choices.contains(where: { $0.model == model }) else { throw Failure.unavailableModel }
        try await withIdleOwner(id, owner: owner, expected: expected) { conn in
            _ = try await conn.request("thread/settings/update", params: JSONEncoder().encode(["threadId": id, "model": model]), timeout: .seconds(10))
            guard try await liveModel(id, on: conn).model == model, currentAuthFile() == authFile,
                  try await account(on: conn) == owner else { throw Failure.modelChanged }
        }
    }

    /// Bind the model to this specific turn at the owner. A later edit to the
    /// thread default cannot reroute this send while a durable queue drains.
    func sendWithModel(_ model: String, text: String, submission: UUID, in id: String, owner: Account) async throws {
        try await withIdleOwner(id, owner: owner, expected: model) { conn in
            let params: [String: Any] = ["threadId": id, "model": model, "clientUserMessageId": submission.uuidString.lowercased(),
                                         "input": [["type": "text", "text": text]]]
            let request = try JSONSerialization.data(withJSONObject: params)
            struct Reply: Decodable { struct Turn: Decodable { let id: String }; let turn: Turn }
            do {
                let reply = try await conn.request("turn/start", params: request, timeout: .seconds(15))
                guard !(try JSONDecoder().decode(Reply.self, from: reply)).turn.id.isEmpty else { throw Failure.inconsistent }
            } catch let error as AgentCLIInvalidRequest { throw error }
            catch { throw Failure.deliveryUnconfirmed }
        }
    }

    func conversationPage(_ id: String, owner: Account, cursor: String?, ascending: Bool) async throws -> Data {
        try await verifyVisible(id, owner: owner)
        var params: [String: any Sendable] = ["threadId": id, "sortDirection": ascending ? "asc" : "desc", "limit": 32,
            "deferOutput": ["commandExecution": true, "mcpToolCall": true]]
        if let cursor { params["cursor"] = cursor }
        let data = try await session().request("thread/items/list", params: JSONSerialization.data(withJSONObject: params), timeout: .seconds(30))
        guard currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        return data
    }

    func itemDetails(_ id: String, owner: Account, turn: String, item: String) async throws -> Data {
        try await verifyVisible(id, owner: owner)
        let params: [String: Any] = ["threadId": id, "turnId": turn, "itemIds": [item]]
        let data = try await session().request("thread/items/read", params: JSONSerialization.data(withJSONObject: params), timeout: .seconds(30))
        guard currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        return data
    }

    func queuedMessages(_ id: String, owner: Account) async throws -> [String] {
        struct Entry: Decodable { let clientUserMessageId: String }
        try await verifyVisible(id, owner: owner)
        let entries = try await all(Entry.self, "thread/queue/list", ["threadId": id])
        guard currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        return entries.map(\.clientUserMessageId)
    }

    // Queueing is durable. Only the official desktop app wakes and runs the thread,
    // using its existing writer, model, tools and approval policy.
    func enqueue(_ text: String, submission: UUID, in id: String, owner: Account, expectedModel: String? = nil) async throws {
        if let expectedModel {
            guard try await currentModel(id, owner: owner).current == expectedModel else { throw Failure.modelChanged }
        } else {
            try await verifyVisible(id, owner: owner)
        }
        let params: [String: Any] = ["threadId": id, "clientUserMessageId": submission.uuidString.lowercased(),
            "input": [["type": "text", "text": text]]]
        let bytes = try JSONSerialization.data(withJSONObject: params)
        let conn = try await session()
        guard currentAuthFile() == authFile else { throw Failure.noChat }
        struct Acknowledgment: Decodable {
            struct Submission: Decodable { let clientUserMessageId: String }
            let queuedSubmission: Submission
        }
        do {
            let data = try await conn.request("thread/queue/add", params: bytes, timeout: .seconds(15))
            let ack = try JSONDecoder().decode(Acknowledgment.self, from: data)
            guard UUID(uuidString: ack.queuedSubmission.clientUserMessageId) == submission else { throw Failure.inconsistent }
        } catch {
            // Never replay an ambiguous write, including after a response timeout.
            throw Failure.deliveryUnconfirmed
        }
    }
}

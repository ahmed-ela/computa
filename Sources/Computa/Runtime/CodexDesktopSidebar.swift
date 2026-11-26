import AppKit
import Foundation

/// A read-only client of the app-server shipped inside the official desktop application.
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
    struct Message: Codable, Equatable, Sendable {
        let id: String
        let role: String
        let text: String
    }
    struct Messages: Sendable {
        let list: [Message]
        let older: String?
    }
    enum Failure: LocalizedError {
        case signedOut, inconsistent, noChat
        var errorDescription: String? {
            switch self {
            case .signedOut: "Sign in to the Codex desktop app to see your chats."
            case .inconsistent: "The Codex sidebar changed while it was loading."
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

    func account() async throws -> Account {
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
        let reply = try await read(Reply.self, "account/read", [:])
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
        let list = try await all(Row.self, "thread/list", Self.visible.merging(["sortKey": "updated_at", "sortDirection": "desc"]) { _, new in new })
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

    func messages(for id: String, account owner: Account, before cursor: String?) async throws -> Messages {
        if currentAuthFile() != authFile { await refreshAccountSession() }
        guard UUID(uuidString: id) != nil, try await account() == owner else { throw Failure.noChat }
        let allowed = try await all(Row.self, "thread/list", Self.visible.merging(["includedThreadIds": [id]]) { _, new in new })
        guard allowed.contains(where: { $0.id == id }) else { throw Failure.noChat }
        struct Item: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let type: String; let id: String; let text: String?; let content: [Content]?
            enum CodingKeys: CodingKey { case type, id, text, content }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try c.decode(String.self, forKey: .type)
                id = try c.decode(String.self, forKey: .id)
                text = type == "agentMessage" ? try c.decode(String.self, forKey: .text) : nil
                content = type == "userMessage" ? try c.decode([Content].self, forKey: .content) : nil
            }
        }
        struct Entry: Decodable { let item: Item }
        var params: [String: any Sendable] = ["threadId": id, "limit": 30, "sortDirection": "desc",
            "deferOutput": ["commandExecution": true, "mcpToolCall": true]]
        if let cursor { params["cursor"] = cursor }
        let page = try await read(Page<Entry>.self, "thread/items/list", params)
        guard page.nextCursor == nil || (page.nextCursor != cursor && page.nextCursor != "") else { throw Failure.inconsistent }
        let messages: [Message] = page.data.reversed().compactMap { entry in
            let item = entry.item
            if let text = item.text { return .init(id: item.id, role: "assistant", text: text) }
            if let parts = item.content { return .init(id: item.id, role: "user", text: parts.map { $0.text ?? "[\($0.type)]" }.joined(separator: "\n")) }
            return nil
        }
        guard try await account() == owner, currentAuthFile() == authFile else { throw Failure.noChat }
        return Messages(list: messages, older: page.nextCursor)
    }
}

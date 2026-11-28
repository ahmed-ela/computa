import Foundation

/// Reads official Codex conversations through the installed CLI app-server.
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
            case .ownerUnavailable: "Another Codex client owns this conversation. Release it there and retry."
            case .busyThread: "Wait for the current Codex turn to finish before sending with a selected model."
            case .pendingQueue: "Wait for Codex to process the queued messages before switching models."
            case .signedOut: "Sign in to Codex CLI to see your chats."
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

    private let candidates: [URL]
    private let home: URL
    nonisolated let codexHome: URL
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

    init(candidates: [URL], home: URL, codexHome: URL) {
        self.candidates = candidates
        self.home = home
        self.codexHome = codexHome
    }

    init(executable: URL, home: URL, codexHome: URL) {
        self.init(candidates: [executable], home: home, codexHome: codexHome)
    }

    private func session() async throws -> AgentCLIConnection {
        if let connection { return connection }
        let token = generation
        if let opening {
            let result = try await opening.value
            guard generation == token else { throw CancellationError() }
            return result
        }
        let task = Task { [candidates, home, codexHome] () throws -> AgentCLIConnection in
            var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "LANG", "TMPDIR", "USER", "LOGNAME"].contains($0.key) }
            environment["HOME"] = home.path
            environment["CODEX_HOME"] = codexHome.path
            let binary = try await InstalledCodexCLI.executable(candidates: candidates)
            let conn = try AgentCLIConnection(executable: binary, arguments: InstalledCodexCLI.arguments,
                directory: home, environment: environment, codexProtocol: true, reportInvalidRequests: true) { _ in }
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
        let bytes = try await conn.request("account/read", params: Data("{}".utf8), timeout: .seconds(10))
        return try Self.decodeAccount(bytes)
    }

    static func decodeAccount(_ bytes: Data) throws -> Account {
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

    func checkImportSource(_ id: String, owner: Account) async throws {
        await refreshAccountSession()
        try await verifyVisible(id, owner: owner)
    }

    /// Capture complete items, including normally deferred tool output. Check the
    /// source on both sides of pagination before publishing anything locally.
    func importSnapshot(_ id: String, owner: Account, title: String) async throws -> CodexImportStore.Snapshot {
        struct Stamp: Decodable, Equatable {
            struct Status: Decodable, Equatable { let type: String }
            let id: String
            let updatedAt: Double
            let model: String?
            let status: Status
        }
        struct Reply: Decodable { let thread: Stamp }
        func stamp() async throws -> Stamp {
            try await verifyVisible(id, owner: owner)
            let value = try await read(Reply.self, "thread/read", ["threadId": id]).thread
            guard value.id == id, value.status.type != "active" else { throw Failure.busyThread }
            return value
        }
        let first = try await stamp()
        struct Policy: Decodable {
            struct Requirements: Decodable { let modelProvider: String? }
            let requirements: Requirements?
        }
        guard try await read(Policy.self, "configRequirements/read", [:]).requirements?.modelProvider == nil
        else { throw AgentCLIError.unavailable("Your managed Codex profile restricts provider transfers.") }
        let routed: CodexRoutedHistory?
        do {
            let records = try await all(CodexRoutedHistory.Attachment.self, "thread/attachment/list", ["threadId": id])
            routed = try CodexRoutedHistory(records)
        } catch let error as AgentCLIInvalidRequest where error.code == -32601 { routed = nil }
        var pages: [Data] = [], seen = Set<String>()
        var params: [String: any Sendable] = ["threadId":id,"sortDirection":"asc","limit":16]
        while true {
            try Task.checkCancellation()
            let data = try await session().request("thread/items/list", params: JSONSerialization.data(withJSONObject: params), timeout: .seconds(30))
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = page["data"] as? [[String: Any]], rows.allSatisfy({ $0["outputDeferred"] as? Bool != true }) else { throw Failure.inconsistent }
            if let routed, !routed.records.isEmpty {
                var merged: [[String: Any]] = []
                for row in rows {
                    merged.append(row)
                    guard let turn = row["turnId"] as? String, let key = (row["item"] as? [String: Any])?["id"] as? String else { throw Failure.inconsistent }
                    for extra in try routed.exchanges(anchor: turn + "/" + key) {
                        let tid = extra.id.uuidString
                        merged.append(["turnId":tid, "model":extra.model, "item":["id":"user","type":"userMessage","content":[["type":"text","text":extra.prompt]]]])
                        let item = extra.status == "completed"
                            ? ["id":"reply","type":"agentMessage","text":extra.answer ?? ""]
                            : ["id":"reply","type":"deliveryStatus","message":extra.answer ?? "Reply unconfirmed"]
                        merged.append(["turnId":tid,"model":extra.model,"item":item])
                    }
                }
                pages.append(try JSONSerialization.data(withJSONObject: ["data":merged]))
            } else { pages.append(data) }
            guard let next = page["nextCursor"] as? String else { break }
            guard !next.isEmpty, seen.insert(next).inserted else { throw Failure.inconsistent }
            params["cursor"] = next
        }
        guard try await stamp() == first, currentAuthFile() == authFile, try await account() == owner else { throw Failure.inconsistent }
        return .init(title: title, model: first.model.map { InstalledCodexCLI.prefix + $0 } ?? "", pages: pages)
    }
}

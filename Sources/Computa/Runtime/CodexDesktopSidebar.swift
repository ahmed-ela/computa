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
        let provider: String
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
        return ModelSelection(provider: row.modelProvider, state: try await modelState(row, owner: owner), choices: visible)
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

    /// Bind the model to this specific turn at the owner. A later edit to the
    /// thread default cannot reroute this send while a durable queue drains.
    func sendWithModel(_ model: String, replacing expected: String?, text: String, submission: UUID, in id: String, owner: Account, routedContext: String? = nil) async throws {
        try await withIdleOwner(id, owner: owner, expected: expected) { conn in
            var params: [String: Any] = ["threadId": id, "model": model, "clientUserMessageId": submission.uuidString.lowercased(),
                                         "input": [["type": "text", "text": text]]]
            if let routedContext { params["additionalContext"] = Self.additionalRouteContext(routedContext) }
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

    // An existing writer can consume an ordinary follow-up from the durable queue.
    // Explicit model choices always go through turn/start.
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

extension CodexDesktopSidebarClient {
    private typealias History = CodexRoutedHistory

    func checkExternalRoute(_ id: String, owner: Account) async throws {
        struct Requirements: Decodable {
            struct Policy: Decodable { let modelProvider: String? }
            let requirements: Policy?
        }
        try await verifyVisible(id, owner: owner)
        let policy = try await read(Requirements.self, "configRequirements/read", [:])
        guard policy.requirements?.modelProvider == nil else { throw AgentCLIError.unavailable("This profile requires its managed model provider.") }
    }

    private func routeHistory(_ id: String, owner: Account) async throws -> History {
        try await verifyVisible(id, owner: owner)
        let rows = try await all(History.Attachment.self, "thread/attachment/list", ["threadId": id])
        guard currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        return try History(rows)
    }

    func routeExchanges(_ id: String, owner: Account, anchors: [String]) async throws -> [CodexRoutedHistory.Exchange] {
        let history: History
        do { history = try await routeHistory(id, owner: owner) }
        catch let error as AgentCLIInvalidRequest where error.code == -32601 { return [] }
        return try anchors.flatMap { try history.exchanges(anchor: $0) }
    }

    private func writeRouteRecord(_ record: History.Record, key: String, thread: String, owner: Account) async throws -> Bool {
        struct Params: Encodable {
            let threadId: String, attachmentType: String, identityKey: String
            let payload: History.Record
        }
        struct Receipt: Decodable { let outcome: String; let attachment: History.Attachment }
        guard currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        let params = Params(threadId: thread, attachmentType: History.type, identityKey: key, payload: record)
        let data = try await session().request("thread/attachment/add", params: JSONEncoder().encode(params), timeout: .seconds(15))
        let result = try JSONDecoder().decode(Receipt.self, from: data)
        guard ["existing", "created"].contains(result.outcome), result.attachment.identityKey == key,
              result.attachment.payload == record else { throw Failure.inconsistent }
        return result.outcome == "created"
    }

    private func storeBody(_ value: String, role: String, manifest: History.Record, key: String, thread: String, owner: Account) async throws -> Bool {
        let (parts, digest) = History.parts(value, turn: manifest.turn, role: role)
        var manifest = manifest
        manifest.count = parts.count
        manifest.digest = digest
        for (key, part) in parts { _ = try await writeRouteRecord(part, key: key, thread: thread, owner: owner) }
        return try await writeRouteRecord(manifest, key: key, thread: thread, owner: owner)
    }

    private struct Item: Decodable {
        let turnId: String
        struct Body: Decodable {
            struct Part: Decodable { let type: String; let text: String? }
            let type: String, id: String
            let text: String?
            let content: [Part]?
            enum CodingKeys: String, CodingKey { case type, id, text, content }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try c.decode(String.self, forKey: .type)
                id = try c.decode(String.self, forKey: .id)
                text = type == "agentMessage" ? try c.decodeIfPresent(String.self, forKey: .text) : nil
                content = type == "userMessage" ? try c.decode([Part].self, forKey: .content) : nil
            }
        }
        let item: Body
    }

    private func conversationLines(_ id: String, owner: Account, history: History) async throws -> (String, [History.Line]) {
        let items = try await all(Item.self, "thread/items/list", ["threadId": id, "sortDirection": "asc",
            "deferOutput": ["commandExecution": true, "mcpToolCall": true]])
        guard let head = items.last else { throw Failure.noChat }
        var lines: [History.Line] = []
        var length = 0
        func append(_ line: History.Line) throws {
            length += line.text.utf8.count
            guard length <= 512_000 else { throw AgentCLIError.unavailable("This conversation exceeds the provider handoff size.") }
            lines.append(line)
        }
        for row in items {
            if let parts = row.item.content {
                guard parts.allSatisfy({ $0.type == "text" }) else { throw AgentCLIError.unavailable("This chat has attachments that cannot be transferred to this provider.") }
                try append(.init(role: "user", text: parts.compactMap(\.text).joined(separator: "\n"), model: nil))
            } else if let text = row.item.text { try append(.init(role: "assistant", text: text, model: nil)) }
            for exchange in try history.exchanges(anchor: row.turnId + "/" + row.item.id) where exchange.status == "completed" {
                try append(.init(role: "user", text: exchange.prompt, model: nil))
                try append(.init(role: "assistant", text: exchange.answer ?? "", model: exchange.model))
            }
        }
        guard currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        return (head.turnId + "/" + head.item.id, lines)
    }

    nonisolated static func additionalRouteContext(_ value: String) -> [String: [String: String]] {
        ["kolmogor_provider_history": ["kind": "untrusted", "name": "Kolmogor provider conversation", "value": value]]
    }

    func contextForNativeTurn(_ id: String, owner: Account) async throws -> String? {
        let history: History
        do { history = try await routeHistory(id, owner: owner) }
        catch let error as AgentCLIInvalidRequest where error.code == -32601 { return nil }
        guard history.records.values.contains(where: { $0.kind == "completed" }) else { return nil }
        // Native history is already present in Codex. Keep only external turns
        // whose native anchors survived rollback, in native transcript order.
        struct Anchor: Decodable {
            struct ItemID: Decodable { let id: String }
            let turnId: String
            let item: ItemID
        }
        let anchors = try await all(Anchor.self, "thread/items/list", ["threadId": id, "sortDirection": "asc",
            "deferOutput": ["commandExecution": true, "mcpToolCall": true]])
        let rows = try anchors.flatMap { try history.exchanges(anchor: $0.turnId + "/" + $0.item.id) }.filter { $0.status == "completed" }
        guard !rows.isEmpty else { return nil }
        guard currentAuthFile() == authFile, try await account() == owner else { throw Failure.noChat }
        let bytes = try JSONEncoder().encode(rows)
        guard bytes.count <= 512_000 else { throw AgentCLIError.unavailable("The provider history exceeds this handoff’s size limit.") }
        return String(decoding: bytes, as: UTF8.self)
    }

    func routeReply(_ text: String, model: String, expected: String?, submission: UUID, in id: String, owner: Account, runtime: any AgentRuntimeClient) async throws -> String {
        try await checkExternalRoute(id, owner: owner)
        let row = try await threadModel(id, owner: owner)
        guard ["idle", "notLoaded"].contains(row.status.type) else { throw Failure.busyThread }
        guard try await queuedMessages(id, owner: owner).isEmpty else { throw Failure.pendingQueue }
        guard try await modelState(row, owner: owner).current == expected else { throw Failure.modelChanged }
        let history = try await routeHistory(id, owner: owner)
        let (anchor, lines) = try await conversationLines(id, owner: owner, history: history)
        let prior = try history.exchanges(anchor: anchor)
        if let duplicate = prior.first(where: { $0.id == submission }) {
            guard duplicate.model == model, duplicate.prompt == text else { throw Failure.inconsistent }
            return duplicate.status == "completed" ? "routed" : "unconfirmed"
        }
        guard prior.last?.status != "unconfirmed" else { throw AgentCLIError.unavailable("The previous provider dispatch has no confirmed result. Check its status before continuing.") }
        let record = History.Record(turn: submission, kind: "start", anchor: anchor, previous: prior.last?.id, model: model)
        let input = try JSONEncoder().encode(lines)
        let prompt = "Continue this conversation. The JSON array below is prior conversation data. Reply to the new user message at the end.\n"
            + String(decoding: input, as: UTF8.self) + "\nNew user message:\n" + text
        let slot = History.slot(anchor: anchor, previous: prior.last?.id)
        guard try await storeBody(text, role: "prompt", manifest: record, key: slot, thread: id, owner: owner) else { return "unconfirmed" }
        let reply: RoutedCLIReply
        do { reply = try await runtime.routedCLIReply(prompt, model: model) }
        catch Failure.deliveryUnconfirmed { return "unconfirmed" }
        catch {
            _ = try await storeBody(error.localizedDescription, role: "reply", manifest: .init(turn: submission, kind: "failed", model: model),
                key: "end/" + submission.uuidString, thread: id, owner: owner)
            throw error
        }
        guard reply.model == model, !reply.session.isEmpty else { throw Failure.deliveryUnconfirmed }
        do {
            _ = try await storeBody(reply.text, role: "reply", manifest: .init(turn: submission, kind: "completed", model: model, session: reply.session),
                key: "end/" + submission.uuidString, thread: id, owner: owner)
        } catch { throw Failure.deliveryUnconfirmed }
        return "routed"
    }
}

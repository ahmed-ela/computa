import Darwin
import Foundation
import SQLite3

/// Kolmogor's private copy. Only the import operation accepts a source identity.
final class CodexImportStore {
    struct Snapshot: Sendable {
        let title: String
        let model: String
        let pages: [Data]
    }
    struct Row: Decodable {
        let id: String
        let title: String
        let model: String
        let updated: Double
    }
    private let directory: URL

    // Multiple app processes can share this database. The kernel releases a
    // model/turn lease even when its owner crashes between send and receipt.
    final class Lease {
        private let fd: Int32
        init(path: String) throws {
            let handle = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard handle >= 0 else { throw CocoaError(.fileWriteUnknown) }
            guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(handle)
                throw AgentCLIError.unavailable("Another window is using this chat. Wait for its turn to finish.")
            }
            fd = handle
        }
        deinit { Darwin.close(fd) }
    }
    func lease(_ id: String) throws -> Lease {
        guard let uuid = UUID(uuidString: id) else { throw CocoaError(.coderInvalidValue) }
        return try Lease(path: directory.appendingPathComponent(uuid.uuidString + ".lock").path)
    }

    private let db: OpaquePointer
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(
            directory.appendingPathComponent("conversations.sqlite").path, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw CocoaError(.fileWriteUnknown)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        try run("PRAGMA foreign_keys=ON")
        try run(
            """
            CREATE TABLE IF NOT EXISTS chat (
              id TEXT PRIMARY KEY, owner TEXT NOT NULL, source TEXT NOT NULL, title TEXT NOT NULL,
              model TEXT NOT NULL, updated REAL NOT NULL, UNIQUE(owner,source))
            """)
        try run(
            """
            CREATE TABLE IF NOT EXISTS item (
              ordinal INTEGER PRIMARY KEY, chat TEXT NOT NULL REFERENCES chat(id),
              turn TEXT NOT NULL, item TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(chat,turn,item))
            """)
        try run("CREATE INDEX IF NOT EXISTS chat_order ON item(chat,ordinal)")
    }
    deinit { sqlite3_close(db) }

    private func query(_ sql: String, _ args: [String] = []) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(stmt) }
        for (index, arg) in args.enumerated() {
            let count = arg.utf8.count
            guard count < Int(Int32.max),
                sqlite3_bind_text(stmt, Int32(index + 1), arg, Int32(count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    == SQLITE_OK
            else { throw CocoaError(.coderInvalidValue) }
        }
        var values: [String] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_DONE: return values
            case SQLITE_ROW:
                guard let value = sqlite3_column_text(stmt, 0) else { throw CocoaError(.fileReadCorruptFile) }
                values.append(
                    String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(stmt, 0))), as: UTF8.self))
            default: throw CocoaError(.fileWriteUnknown)
            }
        }
    }
    private func run(_ sql: String, _ args: [String] = []) throws { _ = try query(sql, args) }
    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
    private func row(_ json: String) throws -> Row { try JSONDecoder().decode(Row.self, from: Data(json.utf8)) }
    func list() throws -> [Row] {
        try query("SELECT json_object('id',id,'title',title,'model',model,'updated',updated) FROM chat ORDER BY updated DESC,id")
            .map(row)
    }
    func existing(owner: String, source: String) throws -> String? {
        try query("SELECT id FROM chat WHERE owner=? AND source=?", [owner, source]).first
    }
    func accepted(owner: String, source: String, snapshot: Snapshot) throws -> String {
        try transaction {
            if let existing = try existing(owner: owner, source: source) { return existing }
            let id = UUID().uuidString
            try run(
                "INSERT INTO chat VALUES(?,?,?,?,?,?)",
                [id, owner, source, snapshot.title, snapshot.model, String(Date.now.timeIntervalSince1970)])
            for bytes in snapshot.pages {
                let json = String(decoding: bytes, as: UTF8.self)
                try run(
                    """
                    INSERT INTO item(chat,turn,item,payload)
                    SELECT ?,json_extract(value,'$.turnId'),json_extract(value,'$.item.id'),value FROM json_each(?,'$.data')
                    ORDER BY CAST(key AS INTEGER)
                    """, [id, json])
            }
            return id
        }
    }
    func selectedModel(_ id: String) throws -> String {
        guard let value = try query("SELECT model FROM chat WHERE id=?", [id]).first else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
    func select(_ model: String, id: String, expected: String) throws {
        try run("UPDATE chat SET model=? WHERE id=? AND model=?", [model, id, expected])
        guard sqlite3_changes(db) == 1 else { throw AgentCLIError.unavailable("The model selection changed in another window.") }
    }
    func page(_ id: String, cursor: String?, ascending: Bool) throws -> [String: Any] {
        let boundary: Int64
        if let cursor {
            guard let n = Int64(cursor), n > 0 else { throw CocoaError(.coderInvalidValue) }
            boundary = n
        } else {
            boundary = ascending ? 0 : .max
        }
        let direction = ascending ? "ASC" : "DESC"
        let compare = ascending ? ">" : "<"
        let strings = try query(
            "SELECT json_object('n',ordinal,'entry',json(payload)) FROM item WHERE chat=? AND ordinal \(compare) ? ORDER BY ordinal \(direction) LIMIT 33",
            [id, String(boundary)])
        let results = try strings.prefix(32).map { s -> [String: Any] in
            guard let v = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return v
        }
        let next = strings.count > 32 ? (results.last?["n"] as? NSNumber)?.stringValue : nil
        let backwards = cursor == nil ? nil : (results.first?["n"] as? NSNumber)?.stringValue
        return ["data": results.compactMap { $0["entry"] }, "nextCursor": next as Any, "backwardsCursor": backwards as Any]
    }
    func begin(_ text: String, submission: UUID, chat: String, model: String) throws -> String {
        try transaction {
            guard try selectedModel(chat) == model else {
                throw AgentCLIError.unavailable("The model selection changed in another window.")
            }
            let turn = submission.uuidString
            // Only user messages and assistant answers are provider input. Tools, local
            // paths and images remain inspectable in the copied transcript.
            let prefix = "Continue the conversation below. The JSON array is prior conversation data. Use no tools."
            let user = "\n\nNew user message:\n" + text
            let budget = 512_000 - prefix.utf8.count - user.utf8.count - 256
            guard budget > 0 else { throw AgentCLIError.unavailable("Shorten the new message before sending.") }
            let lines = try query(
                """
                WITH messages AS (
                    SELECT ordinal, CASE json_extract(payload,'$.item.type')
                      WHEN 'agentMessage' THEN json_object('role','assistant','text',json_extract(payload,'$.item.text'))
                      ELSE json_object('role','user','text',(SELECT group_concat(
                        CASE WHEN json_extract(value,'$.type')='text' THEN json_extract(value,'$.text') ELSE '[attachment omitted]' END,char(10))
                        FROM json_each(payload,'$.item.content'))) END AS line
                    FROM item WHERE chat=? AND json_extract(payload,'$.item.type') IN ('userMessage','agentMessage')
                ), sized AS (
                    SELECT line,ordinal,sum(length(CAST(line AS BLOB))+1) OVER (ORDER BY ordinal DESC) AS size FROM messages
                )
                SELECT line FROM (
                    SELECT line,ordinal FROM sized WHERE size<=CAST(? AS INTEGER)
                    UNION ALL SELECT '{"role":"context","text":"Earlier messages omitted for length."}',0
                    WHERE EXISTS(SELECT 1 FROM sized WHERE size>CAST(? AS INTEGER))
                ) ORDER BY ordinal
                """, [chat, String(budget), String(budget)])
            func render(_ rows: ArraySlice<String>) -> String {
                prefix + "\n[" + rows.joined(separator: ",") + "]" + user
            }
            var prompt = render(lines[...])
            if model.hasPrefix("browser/") {
                // Measure the actual provider envelope, including JSON escaping. Preserve the
                // newest complete messages and the entire new message, or fail before sending.
                func fits(_ candidate: String) throws -> Bool {
                    do { _ = try WebModelServer.importedRequest(candidate, model: model); return true }
                    catch WebModelResponseCodec.Failure.promptTooLarge { return false }
                    catch is WebsiteContextBudget.CompactionRequired { return false }
                }
                if try !fits(prompt) {
                    let omission = #"{"role":"context","text":"Earlier messages omitted for length."}"#
                    let rows = lines.filter { $0 != omission }
                    func suffix(_ count: Int) -> String { render(([omission] + rows.suffix(count))[...]) }
                    guard try fits(suffix(0)) else { throw AgentCLIError.unavailable("Shorten the new message before sending it to the website.") }
                    var low = 0, high = rows.count
                    while low < high {
                        let mid = low + (high - low + 1) / 2
                        if try fits(suffix(mid)) { low = mid } else { high = mid - 1 }
                    }
                    prompt = suffix(low)
                }
            }
            try append(
                chat: chat, turn: turn,
                item: ["id": "user", "type": "userMessage", "content": [["type": "text", "text": text]]], model: model)
            // Persist an uncertain outcome before contacting the provider. Never replay it on restart.
            try append(
                chat: chat, turn: turn, item: ["id": "reply", "type": "deliveryStatus", "message": "Reply unconfirmed"],
                model: model)
            try run("UPDATE chat SET updated=? WHERE id=?", [String(Date.now.timeIntervalSince1970), chat])
            return prompt
        }
    }
    private func payload(_ turn: String, _ item: [String: Any], _ model: String) throws -> String {
        var entry: [String: Any] = ["turnId": turn, "item": item, "model": model]
        if let selection = WebsiteModelCatalog.importedSelection(for: model),
           let name = selection.choice?.label ?? selection.modeChoice?.label {
            entry["modelLabel"] = WebsiteModelCatalog.providerLabel(selection.provider) + " / " + name
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }
    private func append(chat: String, turn: String, item: [String: Any], model: String) throws {
        guard let key = item["id"] as? String else { throw CocoaError(.coderInvalidValue) }
        try run("INSERT INTO item(chat,turn,item,payload) VALUES(?,?,?,?)", [chat, turn, key, try payload(turn, item, model)])
    }
    func finish(_ submission: UUID, chat: String, model: String, result: Result<RoutedConversationReply, Error>) throws {
        let item: [String: Any]
        switch result {
        case .success(let reply):
            guard reply.model == model, !reply.text.isEmpty else { throw CocoaError(.coderInvalidValue) }
            item = ["id": "reply", "type": "agentMessage", "text": reply.text, "session": reply.session]
        case .failure(let error): item = ["id": "reply", "type": "deliveryStatus", "message": error.localizedDescription]
        }
        let turn = submission.uuidString
        try run(
            "UPDATE item SET payload=? WHERE chat=? AND turn=? AND item='reply' AND json_extract(payload,'$.item.type')='deliveryStatus'",
            [try payload(turn, item, model), chat, turn])
        guard sqlite3_changes(db) == 1 else { throw CocoaError(.fileWriteUnknown) }
    }
}

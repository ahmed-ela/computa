import CryptoKit
import Foundation
import SQLite3

/// The app-server owns chats and section membership. Electron keeps cross-surface
/// section order, legacy groups and manual chat order in per-account display settings.
struct CodexDesktopLayout {
    typealias Section = CodexDesktopSidebarClient.Section
    typealias Chat = CodexDesktopSidebarClient.Chat
    struct Group: Decodable {
        let id: String
        let name: String
        let itemKeys: [String]
        let hostSectionIds: [String: String]?
    }
    struct Placement: Decodable {
        let sections: [Group]
        let sectionOrder: [String]
    }

    var placement: Placement?
    var manualOrder = false
    var chatOrder: [String] = []

    static func read(from home: URL, account: CodexDesktopSidebarClient.Account) throws -> Self {
        guard let user = account.userID, let workspace = account.workspaceID else { return Self() }
        let url = home.appendingPathComponent(".codex-global-state.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let identity = try JSONEncoder().encode([user, workspace])
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let scope = "electron-owner-atoms:" + digest
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        let query = """
            SELECT key, value FROM settings WHERE scope = ? AND key IN
            ('sidebar-custom-sections-v3', 'codex-sidebar-sort-mode-v1', 'codex-sidebar-chat-order-v1',
             'flat-project-sidebar-preferences-v1')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        var layout = Self()
        var legacySortOverride = false
        try scope.withCString { owner in
            guard sqlite3_bind_text(statement, 1, owner, -1, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                guard let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let data = Data(bytes: value, count: Int(sqlite3_column_bytes(statement, 1)))
                let decode = JSONDecoder()
                switch String(cString: key) {
                case "sidebar-custom-sections-v3":
                    // Only decode this workspace, even when a settings record contains several.
                    let accounts = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if let prefs = accounts?[workspace] {
                        layout.placement = try decode.decode(Placement.self, from: JSONSerialization.data(withJSONObject: prefs))
                    }
                case "codex-sidebar-sort-mode-v1":
                    legacySortOverride = (try decode.decode(String?.self, from: data)) != nil
                case "flat-project-sidebar-preferences-v1":
                    struct Sorting: Decodable {
                        let chatSortMode: String?
                        let manualSortVersion: Int?
                    }
                    let prefs = try decode.decode(Sorting.self, from: data)
                    layout.manualOrder = prefs.chatSortMode == "manual" && prefs.manualSortVersion == 1
                case "codex-sidebar-chat-order-v1":
                    struct Order: Decodable { let threadIds: [String] }
                    layout.chatOrder = try decode.decode(Order.self, from: data).threadIds
                default: break
                }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        }
        if legacySortOverride { layout.manualOrder = false }
        return layout
    }

    func arrange(_ sections: [Section]) -> [Section] {
        let recentID = CodexDesktopSidebarClient.recentID
        guard let recent = sections.first(where: { $0.id == recentID }) else { return sections }
        let server = sections.filter { $0.id != recentID }
        let pinnedID = CodexDesktopSidebarClient.pinnedID
        let known = Dictionary(uniqueKeysWithValues: recent.chats.map { ($0.id, $0) })
        var consumed = Set<String>()
        var matched = Set<String>()
        var ordered: [(key: String, section: Section)] = []
        if let pin = server.first(where: { $0.id == pinnedID }) {
            matched.insert(pin.id)
            ordered.append(("pinned", pin))
        }
        for group in placement?.sections ?? [] {
            let localID = group.hostSectionIds?["local"] ?? group.id
            if let section = server.first(where: { $0.id == localID }) {
                guard matched.insert(section.id).inserted else { continue }
                ordered.append(("custom:" + group.id, section))
            } else {
                let chats = group.itemKeys.compactMap { key -> Chat? in
                    let prefix = "codex:thread:local:"
                    guard key.hasPrefix(prefix), let chat = known[String(key.dropFirst(prefix.count))],
                          consumed.insert(chat.id).inserted else { return nil }
                    return chat
                }
                ordered.append(("custom:" + group.id, Section(id: group.id, name: group.name, chats: chats)))
            }
        }
        for section in server where !matched.contains(section.id) {
            ordered.append(("custom:" + section.id, section))
        }
        var remaining = recent.chats.filter { !consumed.contains($0.id) }
        if manualOrder {
            var ranks: [String: Int] = [:]
            for (i, key) in chatOrder.enumerated() {
                ranks[key.replacingOccurrences(of: "codex:thread:local:", with: "")] = i
            }
            remaining.sort { ranks[$0.id, default: .max] < ranks[$1.id, default: .max] }
        }
        ordered.append(("chats", Section(id: recentID, name: recent.name, chats: remaining)))
        let order = placement?.sectionOrder ?? []
        guard !order.isEmpty else { return ordered.map(\.section) }
        var positions: [String: Int] = [:]
        for (i, key) in order.enumerated() { positions[key] = i }
        return ordered.sorted { positions[$0.key, default: .max] < positions[$1.key, default: .max] }.map(\.section)
    }
}

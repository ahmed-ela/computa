import Darwin
import Foundation
import SQLite3

/// Read-only Chrome sources and a separate destination for each persistent WebKit profile.
struct ChromeProfileLibrary: Sendable {
    struct Profile: Identifiable, Hashable, Sendable {
        let folder: URL
        let name: String
        var id: URL { folder }
    }
    struct Categories: Sendable {
        var history = true
        var bookmarks = true
        var passwords = false
    }
    struct Suggestion: Identifiable, Equatable, Sendable {
        let url: URL
        let title: String
        let bookmark: Bool
        var id: URL { url }
        var label: String { url.host.map { title + " · " + $0 } ?? title }
    }
    struct Counts: Equatable {
        var history = 0
        var bookmarks = 0
        func summary(for categories: Categories) -> String {
            var parts: [String] = []
            if categories.history { parts.append("\(history) history " + (history == 1 ? "entry" : "entries")) }
            if categories.bookmarks { parts.append("\(bookmarks) " + (bookmarks == 1 ? "bookmark" : "bookmarks")) }
            return "Imported or updated " + parts.joined(separator: " and ") + "."
        }
    }
    enum Failure: LocalizedError {
        case read, database, profile
        var errorDescription: String? {
            switch self {
            case .read: "Couldn’t read the selected Chrome data. Check file access and try again."
            case .database: "Couldn’t finish importing browsing data. Close Chrome if it is busy and retry."
            case .profile: "Choose an available Chrome profile."
            }
        }
    }

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let chromeRoot = support.appendingPathComponent("Google/Chrome", isDirectory: true)
    let database: URL
    init(database: URL) { self.database = database }
    init?(profile: UUID?) {
        guard let profile else { return nil }
        database = Self.support.appendingPathComponent("LocalCodex/BrowserLibrary/" + profile.uuidString + "/places.sqlite")
    }

    static func profiles(in root: URL) throws -> [Profile] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) { return [] }
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return folders.compactMap { folder in
            let id = folder.lastPathComponent
            guard id == "Default" || (id.hasPrefix("Profile ") && Int(id.dropFirst(8)) != nil),
                  let attrs = try? folder.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey]),
                  attrs.isDirectory == true, attrs.isSymbolicLink != true else { return nil }
            var label = id
            if let file = try? source("Preferences", in: folder), let data = try? Data(contentsOf: file),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let profile = object["profile"] as? [String: Any], let name = profile["name"] as? String, !name.isEmpty {
                label = name == id ? id : "\(name) (\(id))"
            }
            return Profile(folder: folder, name: label)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func source(_ name: String, in folder: URL) throws -> URL? {
        let file = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true,
              (name == "History" || (attrs.fileSize ?? Int.max) <= 64 * 1024 * 1024) else { throw Failure.read }
        return file
    }

    private static func safeURL(_ string: String) -> URL? {
        guard string.utf8.count <= 8192, let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased()), EmbeddedBrowserURLPolicy.workspaceAddress(url) != nil else { return nil }
        return url
    }

    func importPlaces(from profile: Profile, categories: Categories) throws -> Counts {
        var counts = Counts()
        guard categories.bookmarks || categories.history else { return counts }
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = try Connection(database, readOnly: false)
        try target.execute("BEGIN IMMEDIATE")
        defer { try? target.execute("ROLLBACK") }
        try target.execute("""
            CREATE TABLE IF NOT EXISTS places(
                url TEXT PRIMARY KEY, title TEXT NOT NULL, bookmark TEXT, term TEXT NOT NULL DEFAULT '', visited INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS bookmark_locations(
                url TEXT NOT NULL, folder TEXT NOT NULL, title TEXT NOT NULL, PRIMARY KEY(url,folder,title)
            )
            """)
        if categories.history, let file = try Self.source("History", in: profile.folder) {
            let source = try Connection(file, readOnly: true)
            let hasTerms = try source.statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name='keyword_search_terms'")
            let term = try hasTerms.next() ? "COALESCE((SELECT term FROM keyword_search_terms WHERE url_id=urls.id LIMIT 1),'')" : "''"
            let rows = try source.statement("SELECT url,title,last_visit_time," + term + " FROM urls WHERE hidden=0")
            let save = try target.statement("""
                INSERT INTO places(url,title,visited,term) VALUES(?,?,?,?)
                ON CONFLICT(url) DO UPDATE SET title=excluded.title,visited=excluded.visited,term=excluded.term
                WHERE excluded.visited >= places.visited
                """)
            while try rows.next() {
                guard let url = Self.safeURL(rows.text(0)) else { continue }
                try save.bind(url.absoluteString, 1)
                try save.bind(String(rows.text(1).prefix(2048)), 2)
                guard sqlite3_bind_int64(save.handle, 3, sqlite3_column_int64(rows.handle, 2)) == SQLITE_OK else { throw Failure.database }
                try save.bind(String(rows.text(3).prefix(2048)), 4)
                try save.write()
                counts.history += 1
            }
        }
        if categories.bookmarks, let file = try Self.source("Bookmarks", in: profile.folder) {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            guard let object = json as? [String: Any], let roots = object["roots"] as? [String: Any] else { throw Failure.read }
            let save = try target.statement("""
                INSERT INTO places(url,title,bookmark) VALUES(?,'',?)
                ON CONFLICT(url) DO UPDATE SET bookmark=excluded.bookmark
                """)
            let saveLocation = try target.statement("INSERT OR IGNORE INTO bookmark_locations(url,folder,title) VALUES(?,?,?)")
            var nodes = roots.values.compactMap { ($0 as? [String: Any]).map { (node: $0, path: [String]()) } }
            while let (node, path) = nodes.popLast() {
                if node["type"] as? String == "folder" {
                    let name = node["name"] as? String ?? ""
                    let next = name.isEmpty ? path : path + [name]
                    nodes.append(contentsOf: (node["children"] as? [[String: Any]] ?? []).map { (node: $0, path: next) })
                } else if node["type"] as? String == "url", let raw = node["url"] as? String, let url = Self.safeURL(raw) {
                    try save.bind(url.absoluteString, 1)
                    let title = String((node["name"] as? String ?? "").prefix(2048))
                    try save.bind(title, 2)
                    try save.write()
                    try saveLocation.bind(url.absoluteString, 1)
                    try saveLocation.bind(path.joined(separator: " / "), 2)
                    try saveLocation.bind(title, 3)
                    try saveLocation.write()
                    counts.bookmarks += 1
                }
            }
        }
        try target.execute("COMMIT")
        return counts
    }

    func matches(_ query: String) throws -> [Suggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, FileManager.default.fileExists(atPath: database.path) else { return [] }
        let db = try Connection(database, readOnly: true)
        let rows = try db.statement("""
            SELECT url,COALESCE(NULLIF(bookmark,''),NULLIF(title,''),url),bookmark IS NOT NULL FROM places
            WHERE instr(lower(url || ' ' || COALESCE(bookmark,'') || ' ' || title || ' ' || term),lower(?)) > 0
            OR url IN (SELECT url FROM bookmark_locations WHERE instr(lower(folder || ' ' || title), lower(?1)) > 0)
            ORDER BY bookmark IS NOT NULL DESC,visited DESC,url LIMIT 5
            """)
        try rows.bind(query, 1)
        var matches: [Suggestion] = []
        while try rows.next() {
            if let url = Self.safeURL(rows.text(0)) {
                matches.append(.init(url: url, title: rows.text(1), bookmark: sqlite3_column_int(rows.handle, 2) != 0))
            }
        }
        return matches
    }

    struct Results {
        var query = ""
        var entries: [Suggestion] = []
        static func search(_ text: String, in library: ChromeProfileLibrary?) async -> Results {
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let library else { return Results() }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return Results() }
            let entries = await Task.detached(priority: .userInitiated) { (try? library.matches(query)) ?? [] }.value
            return Results(query: text, entries: entries)
        }
    }

    private final class Connection {
        let handle: OpaquePointer
        init(_ url: URL, readOnly: Bool) throws {
            var raw: OpaquePointer?
            let mode = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
            // macOS hands out temporary roots under /var, a symlink to /private/var.
            guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw Failure.database }
            defer { free(parent) }
            let path = String(cString: parent) + "/" + url.lastPathComponent
            guard sqlite3_open_v2(path, &raw, mode | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let raw else {
                sqlite3_close(raw); throw Failure.database
            }
            handle = raw
            sqlite3_busy_timeout(raw, 1500)
            try execute("PRAGMA trusted_schema=OFF")
        }
        deinit { sqlite3_close_v2(handle) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database }
        }
        func statement(_ sql: String) throws -> Statement { try Statement(self, sql) }
    }

    private final class Statement {
        let handle: OpaquePointer
        let connection: Connection
        init(_ db: Connection, _ sql: String) throws {
            connection = db
            var raw: OpaquePointer?
            guard sqlite3_prepare_v2(db.handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else { throw Failure.database }
            handle = raw
        }
        deinit { sqlite3_finalize(handle) }
        func text(_ index: Int32) -> String { sqlite3_column_text(handle, index).map { String(cString: $0) } ?? "" }
        func bind(_ value: String, _ index: Int32) throws {
            guard sqlite3_bind_text(handle, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw Failure.database }
        }
        func next() throws -> Bool {
            switch sqlite3_step(handle) {
            case SQLITE_ROW: true
            case SQLITE_DONE: false
            default: throw Failure.database
            }
        }
        func write() throws {
            guard try !next(), sqlite3_reset(handle) == SQLITE_OK else { throw Failure.database }
        }
    }
}

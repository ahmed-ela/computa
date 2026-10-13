import Foundation

/// Turn-local routing for host-issued read cursors. This is not an authorization
/// store: the inventory/page backend still validates its unchanged UUID, target,
/// lifetime and replay rules. Construct a new registry at every turn boundary.
/// Only successful host-generated read results may register a cursor here.
struct ComputerReadContinuation: Sendable {
    static let capacity = 128

    enum Route: Equatable, Sendable {
        case inventory(cursor: UUID, pageSize: Int)
        case page(cursor: UUID)

        var toolName: String {
            switch self {
            case .inventory: "computer_v2_tabs"
            case .page: "computer_v2_snapshot"
            }
        }

        var arguments: [String: Any] {
            switch self {
            case let .inventory(cursor, pageSize): ["cursor": cursor.uuidString, "page_size": pageSize]
            case let .page(cursor): ["cursor": cursor.uuidString]
            }
        }

        fileprivate var source: Source {
            switch self {
            case .inventory: .inventory
            case .page: .page
            }
        }
    }

    enum Failure: Error, Equatable, LocalizedError, Sendable {
        case unknownCursor
        case inventoryScopeChanged
        case pageScopeChanged
        case invalidPageSize
        case invalidScope
        case conflictingCursor

        var errorDescription: String? {
            switch self {
            case .unknownCursor:
                "This continuation cursor was not issued by a current read in this turn, or its route is no longer retained. Call computer_v2_tabs without cursor for a fresh inventory, or computer_v2_snapshot for a fresh page read, then use its returned cursor. No read or action was dispatched."
            case .inventoryScopeChanged:
                "The tab inventory scope changed. Call computer_v2_tabs without cursor for a fresh inventory, then use its returned cursor. No tab was attached or changed."
            case .pageScopeChanged:
                "The observed app or tab scope changed. Call computer_v2_snapshot for a fresh page read, then use its returned cursor. No input was sent."
            case .invalidPageSize:
                "A tab-inventory continuation requires its original page_size from 1 through 100. Start a fresh computer_v2_tabs read."
            case .invalidScope:
                "The host read scope is unavailable. Start a fresh computer_v2_tabs or computer_v2_snapshot read; no continuation was registered."
            case .conflictingCursor:
                "The cursor has conflicting host read routes. Start a fresh computer_v2_tabs or computer_v2_snapshot read; no continuation was dispatched."
            }
        }

        func message(externalChromeTools: Bool) -> String {
            if externalChromeTools { return errorDescription! }
            let reason: String
            switch self {
            case .unknownCursor:
                reason = "This cursor is not a current native computer continuation, or its retained route expired."
            case .inventoryScopeChanged:
                reason = "The inventory source changed or is not offered under the current routing policy."
            case .pageScopeChanged:
                reason = "The observed native app scope changed."
            case .invalidPageSize:
                reason = "The continuation does not retain a valid inventory page size."
            case .invalidScope:
                reason = "The host read scope is unavailable; no continuation was registered."
            case .conflictingCursor:
                reason = "The cursor has conflicting host read routes."
            }
            return reason + " For a native app, bind with computer_v2_open and make a fresh computer_v2_read_page (or computer_v2_snapshot if offered), then use its own returned cursor. Built-in page cursors continue with browser_read(cursor=next_cursor); tab inventory uses browser_tabs(cursor=next_cursor). Use only a cursor returned by that same tool; cursors are never converted between sources. No read, binding, navigation or input was dispatched."
        }
    }

    fileprivate enum Source: Equatable, Sendable { case inventory, page }

    private struct Entry: Equatable, Sendable {
        let route: Route
        let scope: String
    }

    private var entries: [UUID: Entry] = [:]
    private var insertionOrder: [UUID] = []
    var count: Int { entries.count }

    mutating func recordInventory(nextCursor: UUID?, pageSize: Int, scope: String, replacing: Bool) throws {
        guard (1...100).contains(pageSize) else { throw Failure.invalidPageSize }
        try record(cursor: nextCursor, source: .inventory, scope: scope, replacing: replacing) {
            .inventory(cursor: $0, pageSize: pageSize)
        }
    }

    mutating func recordPage(nextCursor: UUID?, scope: String, replacing: Bool) throws {
        try record(cursor: nextCursor, source: .page, scope: scope, replacing: replacing) { .page(cursor: $0) }
    }

    /// Resolution never refreshes an inventory, reconnects, binds, or consumes
    /// the backend cursor. Replaying a route goes through the same backend.
    func resolve(cursor: UUID, inventoryScope: String?, pageScope: String?) throws -> Route {
        guard let entry = entries[cursor] else { throw Failure.unknownCursor }
        switch entry.route {
        case .inventory:
            guard inventoryScope == entry.scope else { throw Failure.inventoryScopeChanged }
        case .page:
            guard pageScope == entry.scope else { throw Failure.pageScopeChanged }
        }
        return entry.route
    }

    private mutating func record(cursor: UUID?, source: Source, scope: String, replacing: Bool,
                                 route: (UUID) -> Route) throws {
        guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              scope.utf8.count <= 1_024,
              !scope.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidScope
        }
        // Validate transactionally: a conflicting backend token must not erase
        // a different valid source or partially replace the current registry.
        var nextEntries = entries
        var nextOrder = insertionOrder
        if replacing {
            let removed = Set(nextEntries.compactMap { $0.value.route.source == source ? $0.key : nil })
            for cursor in removed { nextEntries.removeValue(forKey: cursor) }
            nextOrder.removeAll { removed.contains($0) }
        }
        if let cursor {
            let entry = Entry(route: route(cursor), scope: scope)
            if let existing = nextEntries[cursor] {
                guard existing.scope == entry.scope,
                      existing.route.source == entry.route.source else { throw Failure.conflictingCursor }
                // The inventory backend can issue the same cursor for the same
                // offset after differently sized requests hit its byte bound.
                // Keep the first route/page size instead of rejecting that
                // harmless replay or silently extending its FIFO lifetime.
            } else {
                while nextEntries.count >= Self.capacity, let oldest = nextOrder.first {
                    nextOrder.removeFirst()
                    nextEntries.removeValue(forKey: oldest)
                }
                nextEntries[cursor] = entry
                nextOrder.append(cursor)
            }
        }
        // nil means this response is terminal, not that prior backend cursors
        // became invalid. An explicit replacement clears only its source kind.
        entries = nextEntries
        insertionOrder = nextOrder
    }

    /// Adapter for existing host formatters that do not expose a structured
    /// nextCursor. Never call this with model text or arbitrary page content.
    /// Accept only the first host READ header at its exact framing position;
    /// do not search element labels, appended notices, or later body lines.
    static func nextPageCursor(from text: String) -> UUID? {
        let prefix = String(decoding: text.utf8.prefix(8_192), as: UTF8.self)
        let lines = prefix.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard let first = lines.first, first.utf8.count < 4_096 else { return nil }
        let header: Substring
        if first.hasPrefix("SEMANTIC_READ ") {
            header = first
        } else if first.hasPrefix("NATIVE_AX scope=bound_window "), lines.count > 1,
                  lines[1].hasPrefix("SEMANTIC_READ "), tokens(in: first) != nil {
            header = lines[1]
        } else if first.hasPrefix("AXSNAPSHOT id="), lines.count > 1,
                  lines[1].hasPrefix("READ "), tokens(in: first) != nil {
            header = lines[1]
        } else { return nil }
        guard header.utf8.count < 4_096, let fields = tokens(in: header),
              ["READ", "SEMANTIC_READ"].contains(fields.first ?? ""),
              fields.filter({ $0.hasPrefix("view=") }).count == 1,
              fields.contains(where: { ["view=all", "view=content", "view=headings", "view=links"].contains($0) }) else { return nil }
        let cursors = fields.filter { $0.hasPrefix("next_cursor=") }
        guard cursors.count == 1 else { return nil }
        let value = String(cursors[0].dropFirst("next_cursor=".count))
        guard value.utf8.count == 36, let cursor = UUID(uuidString: value),
              cursor.uuidString.caseInsensitiveCompare(value) == .orderedSame else { return nil }
        return cursor
    }

    /// Keep quoted metadata intact, so next_cursor inside a quoted scope/title
    /// is never interpreted as a host continuation field.
    private static func tokens(in line: Substring) -> [String]? {
        var quoted = false
        var escaped = false
        var token = ""
        var result: [String] = []
        for character in line {
            if escaped { token.append(character); escaped = false; continue }
            if character == "\\", quoted { token.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle(); token.append(character); continue }
            if (character == " " || character == "\t"), !quoted {
                if !token.isEmpty { result.append(token); token = "" }
            } else { token.append(character) }
        }
        guard !quoted, !escaped else { return nil }
        if !token.isEmpty { result.append(token) }
        return result
    }
}

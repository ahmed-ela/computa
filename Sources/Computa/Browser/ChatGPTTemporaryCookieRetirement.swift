import Darwin
import CoreFoundation
import Foundation
@preconcurrency import WebKit

/// Native route evidence only. Cookie deltas and auxiliary page selection IDs
/// cannot add an ID. A local-to-public promotion retains both strict UUIDs.
struct ChatGPTTemporaryConversationRoutes {
    private(set) var candidates: Set<UUID> = []
    mutating func observe(_ url: URL?) {
        guard let id = Self.id(from: url), candidates.contains(id) || candidates.count < 2 else { return }
        candidates.insert(id)
    }
    static func id(from url: URL?) -> UUID? {
        guard let url, url.scheme == "https", url.host == "chatgpt.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        guard path.hasPrefix("/c/") else { return nil }
        var suffix = String(path.dropFirst(3))
        if suffix.hasPrefix("local-chatgpt:") { suffix = String(suffix.dropFirst("local-chatgpt:".count)) }
        guard suffix.utf8.count == 36, let id = UUID(uuidString: suffix), id.uuidString.lowercased() == suffix else { return nil }
        return id
    }
}

@MainActor protocol ChatGPTTemporaryCookieStore: AnyObject {
    var onChange: (@MainActor () -> Void)? { get set }
    func read(_ completion: @escaping @MainActor ([HTTPCookie]) -> Void)
    func delete(_ cookie: HTTPCookie, completion: @escaping @MainActor () -> Void)
    func stopObserving()
}

@MainActor final class ChatGPTWKTemporaryCookieStore: NSObject, ChatGPTTemporaryCookieStore, WKHTTPCookieStoreObserver {
    private let store: WKHTTPCookieStore
    var onChange: (@MainActor () -> Void)?
    init(_ store: WKHTTPCookieStore) { self.store = store; super.init(); store.add(self) }
    func read(_ completion: @escaping @MainActor ([HTTPCookie]) -> Void) { store.getAllCookies(completion) }
    func delete(_ cookie: HTTPCookie, completion: @escaping @MainActor () -> Void) { store.delete(cookie, completionHandler: completion) }
    func stopObserving() { onChange = nil; store.remove(self) }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { onChange?() }
}

/// One callback permit per profile. A waiter deadline/cancellation cannot cancel
/// a write, release its permit, or authorize another batch while it is pending.
/// Tombstones contain only positively owned, physically closed temporary IDs.
@MainActor final class ChatGPTTemporaryCookieRetirement {
    nonisolated static let maximumIDs = 4_096
    nonisolated static let lifetime: TimeInterval = 7 * 86_400
    private let store: any ChatGPTTemporaryCookieStore
    private let registry: ChatGPTTemporaryCookieRegistry?
    private let protection: @MainActor () -> Set<UUID>?
    private let now: @MainActor () -> Date
    private var retired: [UUID: Date] = [:]
    private var valid = true
    private var stopped = false
    private var suspended = false
    private var operation: UUID?
    private var callback: UUID?
    private var pass = 0
    private var lastSettled = true
    private var scheduled: Task<Void, Never>?
    private var changedDuringOperation = false
    private struct Waiter { let continuation: CheckedContinuation<Bool, Never>; let timeout: Task<Void, Never> }
    private var waiters: [UUID: Waiter] = [:]

    init(store: any ChatGPTTemporaryCookieStore, registry: ChatGPTTemporaryCookieRegistry? = nil,
         initiallySuspended: Bool = false,
         now: @escaping @MainActor () -> Date = Date.init,
         protection: @escaping @MainActor () -> Set<UUID>?) {
        self.store = store; self.registry = registry; self.now = now; self.protection = protection
        suspended = initiallySuspended
        if let registry {
            if let records = registry.load(now: now()) { retired = records } else { valid = false }
        }
        store.onChange = { [weak self] in self?.requestSweep() }
        if !retired.isEmpty { requestSweep() }
    }

    var hasPendingCallback: Bool { operation != nil || scheduled != nil }
    /// Unavailable ownership metadata disables deletion, not provider use.
    /// Only a still-issued callback prevents a new profile admission.
    var canAdmit: Bool { !stopped && !suspended && !hasPendingCallback }
    var registeredCount: Int { retired.count }

    @discardableResult func registerClosedOwnedIDs(_ ids: Set<UUID>) -> Bool {
        guard !stopped, valid, !ids.isEmpty, ids.count <= 2 else { return false }
        let date = now()
        guard date.timeIntervalSince1970.isFinite else { return false }
        var records = retired.filter {
            let age = date.timeIntervalSince1970 - $0.value.timeIntervalSince1970
            return age >= 0 && age < Self.lifetime
        }
        for id in ids where records[id] == nil { records[id] = date }
        guard records.count <= Self.maximumIDs, registry?.save(records) != false else { valid = false; return false }
        retired = records
        requestSweep()
        return true
    }

    func requestSweep() {
        guard !stopped, !suspended, valid, !retired.isEmpty else { return }
        if operation != nil { changedDuringOperation = true; return }
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            guard !self.stopped, !self.suspended, self.operation == nil else { return }
            self.operation = UUID(); self.pass = 0; self.readPass(verification: false)
        }
    }

    /// Bounded waiting only. The callback permit remains owned after false.
    func settle(until deadline: ContinuousClock.Instant) async -> Bool {
        if !hasPendingCallback { requestSweep() }
        guard !stopped, valid else { return false }
        guard hasPendingCallback else { return lastSettled }
        guard !Task.isCancelled, waiters.count < 32, ContinuousClock.now < deadline else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline) } catch { return }
                    self?.completeWaiter(id, value: false)
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timeout)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.completeWaiter(id, value: false) } }
    }

    func stop() {
        stopped = true; scheduled?.cancel(); scheduled = nil; store.stopObserving()
        for id in Array(waiters.keys) { completeWaiter(id, value: false) }
        // Issued cookie-store callbacks remain owned until they actually return.
    }

    func setSuspended(_ value: Bool) -> Bool {
        guard !stopped else { return false }
        suspended = value
        if value {
            // A startup inspection must not initiate retirement writes. Drain
            // only already-issued callbacks; their continuations stop below.
            scheduled?.cancel(); scheduled = nil; changedDuringOperation = false
            if operation == nil { for id in Array(waiters.keys) { completeWaiter(id, value: false) } }
        } else { requestSweep() }
        return true
    }

    private func completeWaiter(_ id: UUID, value: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel(); waiter.continuation.resume(returning: value)
    }

    private func complete(_ settled: Bool) {
        let resweep = changedDuringOperation
        changedDuringOperation = false
        operation = nil; callback = nil; lastSettled = settled
        if resweep { requestSweep() }
        if !hasPendingCallback { for id in Array(waiters.keys) { completeWaiter(id, value: settled) } }
    }

    private func readPass(verification: Bool) {
        guard !stopped, !suspended, valid, operation != nil else { complete(false); return }
        let ticket = UUID(); callback = ticket
        store.read { [self] cookies in
            guard callback == ticket else { return }
            callback = nil
            guard !stopped, !suspended, valid, let protected = protection(), protected.count <= 512,
                  let targets = select(cookies, protected: protected) else { complete(false); return }
            guard !targets.isEmpty else { complete(true); return }
            // One trigger gets two finite passes. Continued writes remain in
            // the durable registry and a subsequent native cookie event retries.
            if verification && pass >= 2 { complete(false); return }
            pass += 1
            delete(Array(targets.prefix(64)), index: 0)
        }
    }

    private func delete(_ cookies: [HTTPCookie], index: Int) {
        guard !stopped, !suspended, valid, operation != nil else { complete(false); return }
        guard index < cookies.count else { readPass(verification: true); return }
        guard let protected = protection(), protected.count <= 512 else { complete(false); return }
        let cookie = cookies[index]
        guard let id = cookieID(cookie), isCurrent(id), !protected.contains(id) else { delete(cookies, index: index + 1); return }
        let ticket = UUID(); callback = ticket
        store.delete(cookie) { [self] in
            guard callback == ticket else { return }
            callback = nil
            delete(cookies, index: index + 1)
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard let date = retired[id] else { return false }
        let age = now().timeIntervalSince1970 - date.timeIntervalSince1970
        return age.isFinite && age >= 0 && age < Self.lifetime
    }

    private func cookieID(_ cookie: HTTPCookie) -> UUID? {
        guard (cookie.domain == "chatgpt.com" || cookie.domain == ".chatgpt.com"), cookie.path == "/" else { return nil }
        return ChatGPTTemporaryConversationCookies.canonicalID(name: cookie.name, prefix: "conv_key_")
            ?? ChatGPTTemporaryConversationCookies.canonicalID(name: cookie.name, prefix: "history_off_")
    }

    private func select(_ cookies: [HTTPCookie], protected: Set<UUID>) -> [HTTPCookie]? {
        guard cookies.count <= 4_096 else { return nil }
        var bytes = 0, identities = Set<Data>(), selected: [HTTPCookie] = []
        for cookie in cookies {
            for value in [cookie.domain, cookie.path, cookie.name, cookie.value] {
                let count = value.utf8.prefix(65_537).count
                guard count <= 65_536, bytes <= 1_048_576 - count else { return nil }; bytes += count
            }
            guard !cookie.domain.contains("\0"), !cookie.path.contains("\0"), !cookie.name.contains("\0") else { return nil }
            let identity = Data((cookie.domain + "\0" + cookie.path + "\0" + cookie.name).utf8)
            guard identities.insert(identity).inserted else { return nil }
            if let id = cookieID(cookie), isCurrent(id), !protected.contains(id) { selected.append(cookie) }
        }
        return selected
    }
}

/// Private native tombstones, never cookie values or page authority. Invalid,
/// over-bound, linked, or non-private storage disables retirement conservatively.
struct ChatGPTTemporaryCookieRegistry: Sendable {
    let directory: URL
    let profileID: UUID
    private static let limit = 524_288

    func load(now: Date) -> [UUID: Date]? {
        guard let descriptor = openDirectory(create: false) else { return nil }
        if descriptor == -2 { return [:] }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return nil }
        defer { _ = flock(descriptor, LOCK_UN) }
        let file = openat(descriptor, "owned.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 { return errno == ENOENT ? [:] : nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, privateFile(info), info.st_size > 0, info.st_size <= Self.limit else { return nil }
        var data = Data(count: Int(info.st_size))
        let completeRead = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }; offset += count
            }
            var extra: UInt8 = 0
            return Darwin.read(file, &extra, 1) == 0
        }
        guard completeRead, APIModelCorrectionJSON.isUnambiguous(data),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["version", "profileID", "entries"],
              let version = root["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              root["profileID"] as? String == profileID.uuidString.lowercased(),
              let rows = root["entries"] as? [[String: Any]], rows.count <= ChatGPTTemporaryCookieRetirement.maximumIDs else { return nil }
        var entries: [UUID: Date] = [:], seen = Set<UUID>()
        for row in rows {
            guard Set(row.keys) == ["id", "retiredAt"], let text = row["id"] as? String,
                  let id = UUID(uuidString: text), id.uuidString.lowercased() == text, seen.insert(id).inserted,
                  let number = row["retiredAt"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= now.timeIntervalSince1970 + 300 else { return nil }
            let date = Date(timeIntervalSince1970: number.doubleValue)
            // Compare in the serialized epoch. Date's reference-epoch
            // conversion can make an exact round trip appear slightly future.
            let age = now.timeIntervalSince1970 - number.doubleValue
            if age >= 0 && age < ChatGPTTemporaryCookieRetirement.lifetime { entries[id] = date }
        }
        return entries
    }

    func save(_ entries: [UUID: Date]) -> Bool {
        guard entries.count <= ChatGPTTemporaryCookieRetirement.maximumIDs,
              entries.values.allSatisfy({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 }),
              let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "profileID": profileID.uuidString.lowercased(),
                "entries": entries.keys.sorted(by: { $0.uuidString < $1.uuidString }).map {
                    ["id": $0.uuidString.lowercased(), "retiredAt": entries[$0]!.timeIntervalSince1970] as [String: Any]
                }], options: [.sortedKeys]), data.count <= Self.limit,
              let descriptor = openDirectory(create: true), descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { _ = flock(descriptor, LOCK_UN) }
        var existing = stat()
        if fstatat(descriptor, "owned.json", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard privateFile(existing) else { return false }
        } else if errno != ENOENT { return false }
        let name = ".owned-" + UUID().uuidString.lowercased()
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { return false }
        defer { close(file); _ = unlinkat(descriptor, name, 0) }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }; offset += count
            }
            return true
        }
        guard written, fchmod(file, 0o600) == 0, fsync(file) == 0,
              renameat(descriptor, name, descriptor, "owned.json") == 0, fsync(descriptor) == 0 else { return false }
        return true
    }

    private func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1 && value.st_mode & 0o7777 == 0o600
    }

    /// -2 means absent, nil means unsafe/unavailable. Traverse without following
    /// symlinks; only the final app-created directory must have private mode.
    private func openDirectory(create: Bool) -> Int32? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.host == nil || directory.host == "",
              directory.path.utf8.count <= 4_096 else { return nil }
        let parts = directory.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.count <= 64, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { return nil }
        for (index, part) in parts.enumerated() {
            var next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if !create { close(current); return -2 }
                if mkdirat(current, part, 0o700) != 0, errno != EEXIST { close(current); return nil }
                next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(current)
            guard next >= 0 else { return nil }; current = next
            if index == parts.count - 1 {
                var info = stat()
                guard fstat(current, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { close(current); return nil }
            }
        }
        return current
    }
}

import CoreFoundation
import CryptoKit
import Darwin
import Foundation
@preconcurrency import WebKit

private let expectedBundle = "com.ahmedelamin.LocalCodex"
private enum Failure: Error { case refused, timedOut, archive, verification }

@MainActor protocol ChatGPTCookieMaintenanceStore: AnyObject {
    func read(_ completion: @escaping @MainActor @Sendable ([HTTPCookie]) -> Void)
    func delete(_ cookie: HTTPCookie, completion: @escaping @MainActor @Sendable () -> Void)
    func set(_ cookie: HTTPCookie, completion: @escaping @MainActor @Sendable () -> Void)
}

@MainActor final class ChatGPTWKCookieMaintenanceStore: ChatGPTCookieMaintenanceStore {
    private let store: WKHTTPCookieStore
    init(_ store: WKHTTPCookieStore) { self.store = store }
    func read(_ completion: @escaping @MainActor @Sendable ([HTTPCookie]) -> Void) { store.getAllCookies(completion) }
    func delete(_ cookie: HTTPCookie, completion: @escaping @MainActor @Sendable () -> Void) { store.delete(cookie, completionHandler: completion) }
    func set(_ cookie: HTTPCookie, completion: @escaping @MainActor @Sendable () -> Void) { store.setCookie(cookie, completionHandler: completion) }
}

/// Diagnostic-only, native-only maintenance. A caller must hold its exclusive
/// browser admission lease for the entire async invocation, including a callback
/// that exceeds its deadline. Nothing logs cookie text or private digests.
@MainActor final class ChatGPTCookieMaintenanceDiagnostic {
    enum Outcome: Equatable { case noArm, inspected, quarantined, restored, refused }
    enum FailurePhase: String {
        case armDirectory, armFile, armSchema, armScope, armRename
        case context, read, select, receipt, priorInspect, priorInspectSchema, priorInspectClock, archive, verify, delete, restore
    }
    static let directoryName = "BrowserCookieMaintenanceDiagnostics-v1"
    private let directory: URL
    private let profileID: UUID
    private let store: any ChatGPTCookieMaintenanceStore
    private let isCurrentExclusive: @MainActor () -> Bool
    private let contextIdentityMatchesExpected: @MainActor () -> Bool
    private let protectedIDs: @MainActor () -> Set<UUID>?
    private let now: @MainActor () -> Date
    private let callbackDeadline: Duration
    private var preclaimed: Arm?
    private var running = false
    private var phase: FailurePhase = .armDirectory
    private(set) var lastFailurePhase: FailurePhase?
    private(set) var callbackInFlight = false
    private(set) var callbackTimedOut = false
    private(set) var issuedMutations = 0
    private(set) var settledMutations = 0

    init(codexHome: URL, profileID: UUID, store: any ChatGPTCookieMaintenanceStore,
         isCurrentExclusive: @escaping @MainActor () -> Bool,
         protectedIDs: @escaping @MainActor () -> Set<UUID>?,
         contextIdentityMatchesExpected: @escaping @MainActor () -> Bool = { Bundle.main.bundleIdentifier == "com.ahmedelamin.LocalCodex" },
         now: @escaping @MainActor () -> Date = Date.init, callbackDeadline: Duration = .seconds(5)) {
        directory = Self.directory(codexHome: codexHome); self.profileID = profileID; self.store = store
        self.isCurrentExclusive = isCurrentExclusive; self.protectedIDs = protectedIDs
        self.contextIdentityMatchesExpected = contextIdentityMatchesExpected
        self.now = now; self.callbackDeadline = callbackDeadline
    }

    static func directory(codexHome: URL) -> URL { codexHome.appendingPathComponent(directoryName, isDirectory: true) }
    static func hasArm(codexHome: URL) -> Bool {
        var info = stat()
        let result = lstat(directory(codexHome: codexHome).appendingPathComponent("arm.json").path, &info)
        return result == 0 || errno != ENOENT
    }

    @discardableResult
    static func runAtStartupIfArmed(in browser: EmbeddedBrowserSession) async -> Outcome {
        let home = URL(fileURLWithPath: CodexAppServerRuntime.Configuration.localQwen.codexHomePath, isDirectory: true)
        guard hasArm(codexHome: home) else { return .noArm }
        guard Bundle.main.bundleIdentifier == expectedBundle else { return .refused }
        // Claim synchronously, before the session's first possible settlement
        // await. The lease is installed synchronously by the session bridge.
        let arm: Arm
        do { arm = try Arm.claim(directory: directory(codexHome: home), now: Date()) }
        catch { return .refused }
        return await browser.withExclusiveCookieMaintenance { cookieStore, profile, current in
            let diagnostic = Self(codexHome: home, profileID: profile, store: ChatGPTWKCookieMaintenanceStore(cookieStore),
                isCurrentExclusive: current, protectedIDs: { browser.cookieMaintenanceProtectedIDs() })
            diagnostic.preclaimed = arm
            return await diagnostic.runIfArmed()
        } ?? .refused
    }

    func runIfArmed() async -> Outcome {
        guard !running else { return .refused }
        guard preclaimed != nil || Self.hasArm(codexHome: directory.deletingLastPathComponent()) else { return .noArm }
        running = true
        lastFailurePhase = nil
        defer { running = false }
        var claimed: Arm?
        do {
            let arm = try preclaimed ?? Arm.claim(directory: directory, now: now(), phase: { self.phase = $0 })
            preclaimed = nil; claimed = arm
            phase = .context
            try check(arm)
            guard let protected = protectedIDs(), protected.count <= 512 else { throw Failure.refused }
            phase = .read
            let before = try await read(arm)
            phase = .select
            let selection = try ChatGPTTemporaryConversationCookies.select(before, now: now(), protectedIDs: protected)
            let beforeCounts = Counts(cookies: before, selection: selection)
            switch arm.mode {
            case .inspect:
                phase = .receipt
                try check(arm)
                try publish(arm: arm, fields: ["counts": beforeCounts.dictionary, "budget": budget(before)])
                return .inspected
            case .quarantine:
                phase = .priorInspect
                guard let expected = arm.expectedCounts, expected == beforeCounts, expected.cookieCount > 0,
                      expected.selectedCount > 0, let inspectID = arm.inspectRequestID else { throw Failure.refused }
                try require(try positiveInspect(inspectID, now: now()) == expected)
                phase = .archive
                let indices = Set(selection.targetIndices)
                let archive = Archive(targets: selection.targetIndices.map { before[$0] },
                    markers: selection.pairedMarkerIndices.map { before[$0] },
                    nonselected: try fingerprints(before.enumerated().filter { !indices.contains($0.offset) }.map(\.element)),
                    baselineCount: before.count, fixture: false, created: now(), profileID: profileID)
                let location = try archiveLocation(requestID: arm.requestID, creatingParent: true)
                try check(arm); try writePrivate(archive.encode(), directory: location)
                let verified = try Archive.read(directory: location, fixture: false, profileID: profileID)
                try require(try fingerprints(verified.targets) == fingerprints(archive.targets) && verified.nonselected == archive.nonselected)
                phase = .verify
                let fresh = try await read(arm)
                try require(try fingerprints(fresh) == fingerprints(before))
                phase = .delete
                for target in verified.targets { try await delete(target, arm: arm) }
                phase = .verify
                let after = try await read(arm), keys = Set(verified.targets.map(identity))
                try require(after.count == before.count - verified.targets.count && !after.contains { keys.contains(identity($0)) })
                try require(try fingerprints(after) == verified.nonselected)
                try check(arm)
                let afterSelection = try ChatGPTTemporaryConversationCookies.select(after, now: now(), protectedIDs: protected)
                phase = .receipt
                try publish(arm: arm, fields: ["before": beforeCounts.dictionary,
                    "after": Counts(cookies: after, selection: afterSelection).dictionary,
                    "removedCount": verified.targets.count, "nonselectedUnchanged": true, "archivePreserved": true])
                return .quarantined
            case .restore:
                phase = .archive
                guard let archiveID = arm.archiveRequestID else { throw Failure.refused }
                let archive = try Archive.read(directory: archiveLocation(requestID: archiveID, creatingParent: false), fixture: false, profileID: profileID)
                let keys = Set(archive.targets.map(identity))
                var existing: [Data: HTTPCookie] = [:]
                for cookie in before { try require(existing.updateValue(cookie, forKey: identity(cookie)) == nil) }
                var missing: [HTTPCookie] = []
                for target in archive.targets {
                    if let expiry = target.expiresDate { try require(expiry > now()) }
                    if let value = existing[identity(target)] { try require(try canonical(value) == canonical(target)) }
                    else { missing.append(target) }
                }
                // Preflight every target before the first set. Current auth and
                // other nonselected state may have legitimately rotated since
                // quarantine; preserve this invocation's current values.
                let nonselected = try fingerprints(before.filter { !keys.contains(identity($0)) })
                phase = .restore
                for target in missing { try await set(target, arm: arm) }
                phase = .verify
                let after = try await read(arm)
                try require(after.count == before.count + missing.count)
                try require(try fingerprints(after.filter { !keys.contains(identity($0)) }) == nonselected)
                try require(try fingerprints(after.filter { keys.contains(identity($0)) }) == fingerprints(archive.targets))
                try check(arm)
                phase = .receipt
                try publish(arm: arm, fields: ["beforeCount": before.count, "afterCount": after.count,
                    "restoredCount": missing.count, "alreadyPresentCount": archive.targets.count - missing.count,
                    "nonselectedUnchanged": true, "archivePreserved": true])
                return .restored
            }
        } catch {
            lastFailurePhase = phase
            if let arm = claimed {
                try? publish(arm: arm, fields: ["archivePreserved": true, "failurePhase": phase.rawValue], failure: true)
            }
            return .refused
        }
    }

    private func check(_ arm: Arm) throws {
        try require(!Task.isCancelled && isCurrentExclusive() && contextIdentityMatchesExpected()
            && arm.profileID == profileID && arm.expiresAt > now())
    }
    private func read(_ arm: Arm) async throws -> [HTTPCookie] {
        try check(arm); callbackInFlight = true; defer { callbackInFlight = false }
        let values = try await CallbackWait<[HTTPCookie]>().run(deadline: callbackDeadline, onTimeout: { self.callbackTimedOut = true }) { done in self.store.read(done) }
        try check(arm); try require(values.count <= 4_096); return values
    }
    private func delete(_ cookie: HTTPCookie, arm: Arm) async throws {
        try check(arm); callbackInFlight = true; defer { callbackInFlight = false }
        _ = try await CallbackWait<Bool>().run(deadline: callbackDeadline, onTimeout: { self.callbackTimedOut = true }) { done in
            self.issuedMutations += 1
            self.store.delete(cookie) { self.settledMutations += 1; done(true) }
        }
        try check(arm)
    }
    private func set(_ cookie: HTTPCookie, arm: Arm) async throws {
        try check(arm); callbackInFlight = true; defer { callbackInFlight = false }
        _ = try await CallbackWait<Bool>().run(deadline: callbackDeadline, onTimeout: { self.callbackTimedOut = true }) { done in
            self.issuedMutations += 1
            self.store.set(cookie) { self.settledMutations += 1; done(true) }
        }
        try check(arm)
    }
    private func budget(_ cookies: [HTTPCookie]) -> Any { ChatGPTProfileCookieBudget.estimate(cookies: cookies)?.dictionary as Any? ?? NSNull() }
    private func archiveLocation(requestID: UUID, creatingParent: Bool) throws -> URL {
        let parent = directory.appendingPathComponent("archives", isDirectory: true)
        var info = stat()
        if lstat(parent.path, &info) != 0 {
            try require(creatingParent && errno == ENOENT && mkdir(parent.path, 0o700) == 0)
        }
        try safeDirectory(parent, creating: false)
        return parent.appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
    }
    private func publish(arm: Arm, fields: [String: Any], failure: Bool = false) throws {
        try safeDirectory(directory, creating: false)
        var object: [String: Any] = ["schemaVersion": 1, "purpose": "cookie_maintenance_v1", "mode": arm.mode.rawValue,
            "requestID": arm.requestID.uuidString.lowercased(), "profileID": profileID.uuidString.lowercased(),
            "createdAt": Arm.timestamp(now()), "status": failure ? "unverified" : "verified",
            "issuedMutations": issuedMutations, "settledMutations": settledMutations,
            "callbackTimedOut": callbackTimedOut, "noProviderRequests": true,
            "profileUUIDMatchesArm": arm.profileID == profileID,
            "nativeExclusiveContextVerified": !failure && isCurrentExclusive(),
            "bundleIdentifierMatchesExpected": contextIdentityMatchesExpected(),
            "profileVisibilityEvidence": "native_cookie_counts_only"]
        object.merge(fields) { _, new in new }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try require(bytes.count <= 16_384)
        let name = (failure ? "failure" : arm.mode.rawValue) + "-" + arm.requestID.uuidString.lowercased() + ".json"
        let fd = open(directory.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(fd >= 0); defer { close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                try require(count > 0); offset += count
            }
        }
        try require(fsync(fd) == 0 && fchmod(fd, 0o600) == 0)
    }
    private func positiveInspect(_ requestID: UUID, now: Date) throws -> Counts {
        phase = .priorInspectSchema
        let bytes = try readPrivate(directory.appendingPathComponent("inspect-" + requestID.uuidString.lowercased() + ".json"), limit: 16_384)
        guard APIModelCorrectionJSON.isUnambiguous(bytes), let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(value.keys) == ["schemaVersion", "purpose", "mode", "requestID", "profileID", "createdAt", "status", "issuedMutations", "settledMutations", "callbackTimedOut", "noProviderRequests", "counts", "budget", "profileUUIDMatchesArm", "nativeExclusiveContextVerified", "bundleIdentifierMatchesExpected", "profileVisibilityEvidence"],
              integer(value["schemaVersion"], 1...1) == 1, value["purpose"] as? String == "cookie_maintenance_v1",
              value["mode"] as? String == "inspect", value["requestID"] as? String == requestID.uuidString.lowercased(),
              value["profileID"] as? String == profileID.uuidString.lowercased(), value["status"] as? String == "verified",
              integer(value["issuedMutations"], 0...0) == 0, integer(value["settledMutations"], 0...0) == 0,
              boolean(value["callbackTimedOut"]) == false, boolean(value["noProviderRequests"]) == true,
              boolean(value["profileUUIDMatchesArm"]) == true, boolean(value["nativeExclusiveContextVerified"]) == true,
              boolean(value["bundleIdentifierMatchesExpected"]) == true,
              value["profileVisibilityEvidence"] as? String == "native_cookie_counts_only",
              let text = value["createdAt"] as? String, let created = Arm.date(text), let counts = Counts.parse(value["counts"]),
              counts.cookieCount > 0, counts.selectedCount > 0 else { throw Failure.refused }
        phase = .priorInspectClock
        try require((0...600).contains(now.timeIntervalSince(created)))
        return counts
    }

    private struct Counts: Equatable {
        let cookieCount: Int, pairedKeyCount: Int, unpairedKeyCount: Int, selectedCount: Int, protectedKeyCount: Int
        init(cookies: [HTTPCookie], selection: ChatGPTTemporaryConversationCookies.Selection) {
            cookieCount = cookies.count; pairedKeyCount = selection.pairedKeyCount; unpairedKeyCount = selection.unpairedKeyCount
            selectedCount = selection.targetIndices.count; protectedKeyCount = selection.protectedKeyCount
        }
        private init(cookieCount: Int, pairedKeyCount: Int, unpairedKeyCount: Int, selectedCount: Int, protectedKeyCount: Int) {
            self.cookieCount = cookieCount; self.pairedKeyCount = pairedKeyCount; self.unpairedKeyCount = unpairedKeyCount
            self.selectedCount = selectedCount; self.protectedKeyCount = protectedKeyCount
        }
        var dictionary: [String: Any] { ["cookieCount": cookieCount, "pairedKeyCount": pairedKeyCount,
            "unpairedKeyCount": unpairedKeyCount, "selectedCount": selectedCount, "protectedKeyCount": protectedKeyCount] }
        static func parse(_ raw: Any?) -> Self? {
            guard let value = raw as? [String: Any], Set(value.keys) == ["cookieCount", "pairedKeyCount", "unpairedKeyCount", "selectedCount", "protectedKeyCount"],
                  let cookies = integer(value["cookieCount"], 0...4_096), let paired = integer(value["pairedKeyCount"], 0...4_096),
                  let unpaired = integer(value["unpairedKeyCount"], 0...4_096), let selected = integer(value["selectedCount"], 0...512),
                  let protected = integer(value["protectedKeyCount"], 0...512), paired == selected + protected,
                  cookies >= paired * 2 + unpaired else { return nil }
            return Self(cookieCount: cookies, pairedKeyCount: paired, unpairedKeyCount: unpaired, selectedCount: selected, protectedKeyCount: protected)
        }
    }
    private struct Arm {
        enum Mode: String { case inspect, quarantine, restore }
        let mode: Mode, requestID: UUID, profileID: UUID, expiresAt: Date
        let inspectRequestID: UUID?, expectedCounts: Counts?, archiveRequestID: UUID?
        static func claim(directory: URL, now: Date, phase: (FailurePhase) -> Void = { _ in }) throws -> Self {
            phase(.armDirectory)
            try safeDirectory(directory, creating: false)
            phase(.armFile)
            let path = directory.appendingPathComponent("arm.json")
            var before = stat(); try require(lstat(path.path, &before) == 0)
            let bytes = try readPrivate(path, limit: 4_096)
            phase(.armSchema)
            guard APIModelCorrectionJSON.isUnambiguous(bytes), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  object["purpose"] as? String == "cookie_maintenance_v1", let rawMode = object["mode"] as? String, let mode = Mode(rawValue: rawMode),
                  let request = id(object["requestID"]), let profile = id(object["profileID"]), let text = object["expiresAt"] as? String,
                  let expiry = date(text), expiry > now, expiry.timeIntervalSince(now) <= 600 else { throw Failure.refused }
            phase(.armScope)
            let base: Set<String> = ["purpose", "mode", "requestID", "profileID", "expiresAt"]
            var inspect: UUID?, counts: Counts?, archive: UUID?
            switch mode {
            case .inspect: try require(Set(object.keys) == base)
            case .quarantine:
                try require(Set(object.keys) == base.union(["inspectRequestID", "expectedCounts"]))
                inspect = id(object["inspectRequestID"]); counts = Counts.parse(object["expectedCounts"])
                try require(inspect != nil && counts != nil && inspect != request)
            case .restore:
                try require(Set(object.keys) == base.union(["archiveRequestID"]))
                archive = id(object["archiveRequestID"]); try require(archive != nil && archive != request)
            }
            var after = stat(); try require(lstat(path.path, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            let consumed = directory.appendingPathComponent("consumed-" + request.uuidString.lowercased() + ".json")
            phase(.armRename)
            try require(renameatx_np(AT_FDCWD, path.path, AT_FDCWD, consumed.path, UInt32(RENAME_EXCL)) == 0)
            return Self(mode: mode, requestID: request, profileID: profile, expiresAt: expiry,
                inspectRequestID: inspect, expectedCounts: counts, archiveRequestID: archive)
        }
        static func id(_ raw: Any?) -> UUID? {
            guard let text = raw as? String, let value = UUID(uuidString: text), value.uuidString.lowercased() == text else { return nil }
            return value
        }
        static func timestamp(_ value: Date) -> String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return formatter.string(from: value)
        }
        static func date(_ text: String) -> Date? {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; formatter.isLenient = false
            guard let value = formatter.date(from: text), timestamp(value) == text else { return nil }; return value
        }
    }
}

@MainActor private final class CallbackWait<T: Sendable> {
    private var completed = false, timedOut = false
    private var continuation: CheckedContinuation<T, Never>?
    private var timer: Task<Void, Never>?
    func run(deadline: Duration, onTimeout: @escaping @MainActor () -> Void,
             start: (@escaping @MainActor @Sendable (T) -> Void) -> Void) async throws -> T {
        if Task.isCancelled { throw CancellationError() }
        let expires = ContinuousClock.now + deadline
        let value = await withCheckedContinuation { continuation in
            self.continuation = continuation
            timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(until: expires) } catch { return }
                guard let self, !completed else { return }
                timedOut = true; onTimeout()
            }
            start { [self] value in
                guard !completed else { return }
                if !timedOut, ContinuousClock.now >= expires { timedOut = true; onTimeout() }
                completed = true; timer?.cancel(); timer = nil
                self.continuation?.resume(returning: value); self.continuation = nil
            }
        }
        if timedOut { throw Failure.timedOut }
        if Task.isCancelled { throw CancellationError() }
        return value
    }
}
private func integer(_ raw: Any?, _ range: ClosedRange<Int>) -> Int? {
    guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
          value.doubleValue.rounded(.towardZero) == value.doubleValue, range.contains(value.intValue),
          value.doubleValue == Double(value.intValue) else { return nil }; return value.intValue
}
private func boolean(_ raw: Any?) -> Bool? {
    guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue
}

private func require(_ value: Bool) throws { if !value { throw Failure.refused } }
private func canonicalValue(_ value: Any, depth: Int = 0) throws -> Any {
    try require(depth <= 8)
    if let value = value as? String { try require(value.utf8.count <= 65_536); return ["s": value] }
    if let value = value as? Date { try require(value.timeIntervalSinceReferenceDate.isFinite); return ["d": String(value.timeIntervalSinceReferenceDate.bitPattern)] }
    if let value = value as? NSNumber { try require(value.doubleValue.isFinite); return ["n": value.stringValue] }
    if let value = value as? URL { return ["u": value.absoluteString] }
    if let value = value as? Data { try require(value.count <= 65_536); return ["b": value.base64EncodedString()] }
    if let value = value as? [String: Any] {
        try require(value.count <= 128)
        return try value.mapValues { try canonicalValue($0, depth: depth + 1) }
    }
    if let value = value as? [Any] {
        try require(value.count <= 128)
        return try value.map { try canonicalValue($0, depth: depth + 1) }
    }
    throw Failure.archive
}
private func properties(_ cookie: HTTPCookie) throws -> [String: Any] {
    guard let values = cookie.properties else { throw Failure.archive }
    return Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
}
private func canonical(_ cookie: HTTPCookie) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: canonicalValue(properties(cookie)), options: [.sortedKeys])
    try require(data.count <= 65_536); return data
}
private func identity(_ cookie: HTTPCookie) -> Data { Data((cookie.domain + "\0" + cookie.path + "\0" + cookie.name).utf8) }
private func fingerprints(_ cookies: [HTTPCookie]) throws -> [Data] {
    var total = 0
    return try cookies.map { cookie in
        let bytes = try canonical(cookie); total += bytes.count; try require(total <= 1_048_576)
        return Data(SHA256.hash(data: bytes))
    }.sorted { $0.lexicographicallyPrecedes($1) }
}
private func reconstructed(_ array: [[String: Any]]) throws -> [HTTPCookie] {
    try require(array.count <= 512)
    return try array.map { values in
        guard let cookie = HTTPCookie(properties: Dictionary(uniqueKeysWithValues: values.map { (HTTPCookiePropertyKey($0.key), $0.value) })) else { throw Failure.archive }
        // Validate that reconstruction did not silently discard archived fields.
        let before = try JSONSerialization.data(withJSONObject: canonicalValue(values), options: [.sortedKeys])
        try require(before == canonical(cookie)); return cookie
    }
}
private func safeDirectory(_ directory: URL, creating: Bool) throws {
    let path = directory.path
    // standardizedFileURL consults the filesystem: an existing physical
    // /private/var directory may be rewritten to macOS's /var alias. Keep this
    // check lexical; lstat of every ancestor below enforces the no-symlink rule.
    try require(directory.isFileURL && path.hasPrefix("/") &&
        !directory.pathComponents.contains(where: { $0 == "." || $0 == ".." }))
    var parent = URL(fileURLWithPath: "/", isDirectory: true)
    for part in directory.pathComponents.dropFirst().dropLast() {
        parent.appendPathComponent(part, isDirectory: true)
        var info = stat(); try require(lstat(parent.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR)
    }
    if creating { try require(mkdir(path, 0o700) == 0) }
    var info = stat()
    try require(lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700)
}
private func readPrivate(_ url: URL, limit: Int) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW); try require(fd >= 0); defer { close(fd) }
    var info = stat(); try require(fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o777 == 0o600 && info.st_size <= limit)
    var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let amount = read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
        try require(amount >= 0); if amount == 0 { break }; data.append(contentsOf: buffer.prefix(amount)); try require(data.count <= limit)
    }
    return data
}
private func writePrivate(_ data: Data, directory: URL) throws {
    try require(data.count <= 1_048_576); try safeDirectory(directory, creating: true)
    let fd = open(directory.appendingPathComponent("cookies.archive").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    try require(fd >= 0); defer { close(fd) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < data.count {
            let amount = write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            try require(amount > 0); offset += amount
        }
    }
    try require(fsync(fd) == 0 && fchmod(fd, 0o600) == 0)
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    try require(directoryFD >= 0); defer { close(directoryFD) }; try require(fsync(directoryFD) == 0)
    try require(try readPrivate(directory.appendingPathComponent("cookies.archive"), limit: 1_048_576) == data)
}

private struct Archive {
    let targets: [HTTPCookie]
    let markers: [HTTPCookie]
    let nonselected: [Data]
    let baselineCount: Int
    let fixture: Bool
    let created: Date
    let profileID: UUID
    func encode() throws -> Data {
        let object: [String: Any] = ["schemaVersion": 1, "bundleID": expectedBundle, "profileID": profileID.uuidString,
            "fixture": fixture, "created": created, "targets": try targets.map(properties), "markers": try markers.map(properties),
            "nonselected": nonselected, "baselineCount": baselineCount, "targetCount": targets.count]
        return try NSKeyedArchiver.archivedData(withRootObject: object as NSDictionary, requiringSecureCoding: true)
    }
    static func read(directory: URL, fixture: Bool, profileID: UUID) throws -> Self {
        try safeDirectory(directory, creating: false)
        let bytes = try readPrivate(directory.appendingPathComponent("cookies.archive"), limit: 1_048_576)
        let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSDate.self, NSData.self, NSURL.self]
        guard let object = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: bytes) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "bundleID", "profileID", "fixture", "created", "targets", "markers", "nonselected", "baselineCount", "targetCount"],
              object["schemaVersion"] as? Int == 1, object["bundleID"] as? String == expectedBundle,
              object["profileID"] as? String == profileID.uuidString, object["fixture"] as? Bool == fixture,
              let created = object["created"] as? Date, created.timeIntervalSinceReferenceDate.isFinite,
              let targetProperties = object["targets"] as? [[String: Any]], let markerProperties = object["markers"] as? [[String: Any]],
              let nonselected = object["nonselected"] as? [Data], nonselected.count <= 4_096, nonselected.allSatisfy({ $0.count == 32 }),
              let baselineCount = object["baselineCount"] as? Int, (0...4_096).contains(baselineCount),
              object["targetCount"] as? Int == targetProperties.count, baselineCount == targetProperties.count + nonselected.count else { throw Failure.archive }
        let targets = try reconstructed(targetProperties), markers = try reconstructed(markerProperties)
        try require(targets.count == markers.count && !targets.isEmpty)
        let scope = try ChatGPTTemporaryConversationCookies.select(targets + markers, now: created)
        try require(scope.targetIndices == Array(targets.indices) && scope.pairedMarkerIndices == targets.indices.map { $0 + targets.count })
        return Self(targets: targets, markers: markers, nonselected: nonselected, baselineCount: baselineCount, fixture: fixture, created: created, profileID: profileID)
    }
}


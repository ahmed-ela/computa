import CoreFoundation
import Darwin
import Foundation

/// A separately and explicitly armed, same-UID diagnostic. It grants only finite
/// request metadata collection on one new private view, never page/tool authority.
final class ChatGPTRequestMetadataLease: @unchecked Sendable {
    private let lock = NSLock()
    private let taskID: UUID, threadID: UUID, turnID: UUID, preparationID: UUID
    private let directory: URL
    private let deadline: ContinuousClock.Instant
    let capturesDecodedEvents: Bool
    private var current = true
    private var claimedView: ObjectIdentifier?

    private init(taskID: UUID, threadID: UUID, turnID: UUID, preparationID: UUID, directory: URL,
                 deadline: ContinuousClock.Instant, capturesDecodedEvents: Bool) {
        self.taskID = taskID; self.threadID = threadID; self.turnID = turnID
        self.preparationID = preparationID; self.directory = directory; self.deadline = deadline
        self.capturesDecodedEvents = capturesDecodedEvents
    }
    var isCurrent: Bool { lock.withLock { current && ContinuousClock.now < deadline } }
    var remainingMilliseconds: Int {
        lock.withLock {
            guard current else { return 0 }
            let parts = (deadline - ContinuousClock.now).components
            return Int(max(0, min(600_000, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)))
        }
    }
    func matches(taskID: UUID, threadID: UUID, turnID: UUID, preparationID: UUID) -> Bool {
        lock.withLock { current && ContinuousClock.now < deadline && self.taskID == taskID
            && self.threadID == threadID && self.turnID == turnID && self.preparationID == preparationID }
    }
    func claim(view: ObjectIdentifier) -> Bool {
        lock.withLock {
            guard current, ContinuousClock.now < deadline, claimedView == nil else { return false }
            claimedView = view; return true
        }
    }
    func revoke() { lock.withLock { current = false } }

    /// Append-only private sidecar: exclusive creation and no replacement API.
    /// Its values cannot release a model
    /// response, qualify a request, grant an action, or change the original error.
    func persist(_ snapshot: ChatGPTRequestMetadataSnapshot, inferenceID: UUID, sessionToken: UUID) -> Bool {
        guard isCurrent, snapshot.schemaVersion == (capturesDecodedEvents ? 2 : 1),
              let diagnostic = try? JSONSerialization.jsonObject(with: snapshot.encodedData),
              let bytes = try? JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "purpose": capturesDecodedEvents ? "request_and_decoded_metadata_v2" : "request_metadata_v1", "provider": "chatgpt",
                "evidenceClass": "page_world_untrusted", "instrumented": true,
                "taskID": taskID.uuidString.lowercased(), "threadID": threadID.uuidString.lowercased(),
                "turnID": turnID.uuidString.lowercased(), "preparationID": preparationID.uuidString.lowercased(),
                "inferenceID": inferenceID.uuidString.lowercased(), "sessionToken": sessionToken.uuidString.lowercased(),
                "diagnostic": diagnostic,
                "nativeCookieBudget": snapshot.profileCookieBudget.map { $0.dictionary as Any } ?? NSNull(),
              ], options: [.sortedKeys]), bytes.count <= 9_216 else { return false }
        let descriptor = Self.openDirectoryWithoutSymlinks(directory)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.privateDirectory(info) else { return false }
        let temporary = ".metadata-" + UUID().uuidString.lowercased() + ".tmp"
        let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return false }
        defer { close(output); _ = unlinkat(descriptor, temporary, 0) }
        let written = bytes.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard fchmod(output, 0o600) == 0, written, fsync(output) == 0, isCurrent,
              Self.directoryStillMatches(directory, descriptor: descriptor, initial: info),
              renameatx_np(descriptor, temporary, descriptor,
                "request-metadata-" + inferenceID.uuidString.lowercased() + ".json", UInt32(RENAME_EXCL)) == 0 else { return false }
        _ = fsync(descriptor)
        return true
    }

    // Same strict private-file/single-use mechanics as the Inspector arm. Its
    // separate purpose and directory never reinterpret an Inspector permission.
    static func consume(directory: URL?, taskID: UUID, threadID: UUID, turnID: UUID, preparationID: UUID, isMaintenance: Bool = false,
                        now: Date = Date()) -> ChatGPTRequestMetadataLease? {
        let started = ContinuousClock.now
        guard !isMaintenance, !Task.isCancelled, let directory else { return nil }
        let descriptor = openDirectoryWithoutSymlinks(directory)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0, privateDirectory(directoryInfo),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        let armFD = openat(descriptor, "arm.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard armFD >= 0 else { return nil }
        defer { close(armFD) }
        var before = stat()
        guard fstat(armFD, &before) == 0, privateFile(before), before.st_size > 0, before.st_size <= 512,
              let bytes = readArm(armFD), bytes.count == before.st_size,
              APIModelCorrectionJSON.isUnambiguous(bytes),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
              Set(value.keys) == ["taskID", "threadID", "provider", "purpose", "expiresAt"],
              value["taskID"] == taskID.uuidString.lowercased(), value["threadID"] == threadID.uuidString.lowercased(),
              value["provider"] == "chatgpt", let purpose = value["purpose"],
              ["request_metadata_v1", "request_and_decoded_metadata_v2"].contains(purpose),
              let text = value["expiresAt"], text.utf8.count == 24 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        guard let expiry = formatter.date(from: text), formatter.string(from: expiry) == text else { return nil }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 0, seconds <= 600 else { return nil }
        let originalDeadline = started + .seconds(seconds)
        var after = stat(), named = stat()
        guard fstat(armFD, &after) == 0, sameUnchangedFile(before, after),
              fstatat(descriptor, "arm.json", &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(before, named),
              directoryStillMatches(directory, descriptor: descriptor, initial: directoryInfo), !Task.isCancelled else { return nil }
        let claimed = ".claimed-arm-" + UUID().uuidString.lowercased()
        guard renameatx_np(descriptor, "arm.json", descriptor, claimed, UInt32(RENAME_EXCL)) == 0 else { return nil }
        var claim = stat()
        guard fstatat(descriptor, claimed, &claim, AT_SYMLINK_NOFOLLOW) == 0, privateFile(claim),
              before.st_dev == claim.st_dev, before.st_ino == claim.st_ino, before.st_size == claim.st_size,
              before.st_mtimespec.tv_sec == claim.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == claim.st_mtimespec.tv_nsec,
              lseek(armFD, 0, SEEK_SET) == 0, readArm(armFD) == bytes,
              fstat(armFD, &after) == 0, sameUnchangedFile(claim, after),
              fstatat(descriptor, claimed, &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(after, named),
              directoryStillMatches(directory, descriptor: descriptor, initial: directoryInfo) else {
            _ = renameatx_np(descriptor, claimed, descriptor, "arm.json", UInt32(RENAME_EXCL)); return nil
        }
        guard unlinkat(descriptor, claimed, 0) == 0 else { return nil }
        _ = fsync(descriptor)
        // Preserve the original monotonic bound across all file operations.
        guard !Task.isCancelled, ContinuousClock.now < originalDeadline else { return nil }
        return ChatGPTRequestMetadataLease(taskID: taskID, threadID: threadID, turnID: turnID,
            preparationID: preparationID, directory: directory, deadline: originalDeadline,
            capturesDecodedEvents: purpose == "request_and_decoded_metadata_v2")
    }

    private static func openDirectoryWithoutSymlinks(_ url: URL) -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { return -1 }
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return -1 }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }
    private static func directoryStillMatches(_ directory: URL, descriptor: Int32, initial: stat) -> Bool {
        let currentFD = openDirectoryWithoutSymlinks(directory)
        guard currentFD >= 0 else { return false }
        defer { close(currentFD) }
        var current = stat(), held = stat()
        return fstat(currentFD, &current) == 0 && fstat(descriptor, &held) == 0
            && privateDirectory(current) && privateDirectory(held)
            && current.st_dev == initial.st_dev && current.st_ino == initial.st_ino
            && held.st_dev == initial.st_dev && held.st_ino == initial.st_ino
    }
    private static func privateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o700
    }
    private static func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1
            && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o600
    }
    private static func sameUnchangedFile(_ lhs: stat, _ rhs: stat) -> Bool {
        privateFile(rhs) && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
    private static func readArm(_ descriptor: Int32) -> Data? {
        var bytes = Data(count: 513)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int? in
            var count = 0
            while count < buffer.count {
                let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if result < 0 { if errno == EINTR { continue }; return nil }
                if result == 0 { return count }
                count += result
            }
            return count
        }
        guard let count, count <= 512 else { return nil }
        bytes.count = count
        return bytes
    }
}

/// All page-world values are untrusted. Reject arbitrary text and unknown keys
/// rather than retaining raw diagnostic JSON or trying to repair it.
struct ChatGPTRequestMetadataSnapshot: Sendable {
    enum Failure: Error { case invalid }
    let encodedData: Data
    let schemaVersion: Int
    let active: Bool
    let expired: Bool
    let rowCount: Int
    /// Native profile estimate only. It is never accepted from page JSON or
    /// represented as the cookies actually attached to a particular request.
    let profileCookieBudget: ChatGPTProfileCookieBudget?

    func attachingProfileCookieBudget(_ budget: ChatGPTProfileCookieBudget?) -> Self {
        Self(encodedData: encodedData, schemaVersion: schemaVersion, active: active, expired: expired,
             rowCount: rowCount, profileCookieBudget: budget)
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 8_192, APIModelCorrectionJSON.isUnambiguous(data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = integer(object["schemaVersion"], in: 1...2),
              Set(object.keys) == (version == 1 ? ["schemaVersion", "active", "expired", "rows"]
                                  : ["schemaVersion", "active", "expired", "rows", "decoder"]),
              (version == 1 || validDecoder(object["decoder"])),
              let active = boolean(object["active"]), let expired = boolean(object["expired"]),
              !(active && expired), let rows = object["rows"] as? [[String: Any]], rows.count <= 8 else { throw Failure.invalid }
        let keys: Set<String> = ["ordinal", "endpoint", "origin", "method", "bodyType", "bodyBytes", "keepalive", "duplex",
                                 "headerMetadata", "startedMs", "settledMs", "outcome", "status", "error"]
        var lastOrdinal = 0
        var lastStarted = 0.0
        for row in rows {
            guard Set(row.keys) == keys, let ordinal = integer(row["ordinal"], in: 1...8), ordinal == lastOrdinal + 1,
                  member(row["endpoint"], ["conversation", "preparation", "other", "unknown"]),
                  member(row["origin"], ["same", "other", "unknown"]),
                  member(row["method"], ["GET", "POST", "other", "unknown"]),
                  member(row["bodyType"], ["string", "blob", "buffer", "view", "stream", "form_data", "url_params", "none", "unknown"]),
                  row["bodyBytes"] is NSNull || integer(row["bodyBytes"], in: 0...1_048_576) != nil,
                  validHeaderMetadata(row["headerMetadata"]),
                  member(row["keepalive"], ["true", "false", "absent", "unknown"]),
                  member(row["duplex"], ["half", "absent", "other", "unknown"]),
                  let started = milliseconds(row["startedMs"]), started >= lastStarted,
                  row["settledMs"] is NSNull || milliseconds(row["settledMs"]).map({ $0 >= started }) == true,
                  member(row["outcome"], ["pending", "headers", "rejected", "sync_throw"]),
                  row["status"] is NSNull || integer(row["status"], in: 100...599) != nil,
                  member(row["error"], ["none", "type_error", "abort", "unsupported", "other"]) else { throw Failure.invalid }
            let bodyType = row["bodyType"] as? String
            if bodyType == "none" {
                guard integer(row["bodyBytes"], in: 0...0) != nil else { throw Failure.invalid }
            } else if bodyType != "string", !(row["bodyBytes"] is NSNull) { throw Failure.invalid }
            let outcome = row["outcome"] as? String
            if outcome == "pending" {
                guard row["settledMs"] is NSNull, row["status"] is NSNull,
                      row["error"] as? String == "none" else { throw Failure.invalid }
            } else if outcome == "headers" {
                guard milliseconds(row["settledMs"]) != nil, row["error"] as? String == "none" else { throw Failure.invalid }
            } else {
                guard milliseconds(row["settledMs"]) != nil, row["status"] is NSNull,
                      row["error"] as? String != "none" else { throw Failure.invalid }
            }
            lastOrdinal = ordinal
            lastStarted = started
        }
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard encoded.count <= 8_192 else { throw Failure.invalid }
        return Self(encodedData: encoded, schemaVersion: version, active: active, expired: expired,
                    rowCount: rows.count, profileCookieBudget: nil)
    }
    /// This is an untrusted decoder observation, never response/completion or
    /// ownership evidence. Unknown content is rejected rather than retained.
    private static func validDecoder(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any],
              Set(object.keys) == ["state", "completionCalls", "programObservations", "recoveredNullObservations", "lastProgram"],
              member(object["state"], ["pending", "unavailable", "installed", "restored", "superseded"]),
              let calls = integer(object["completionCalls"], in: 0...65_535),
              let programs = integer(object["programObservations"], in: 0...65_535),
              let recovered = integer(object["recoveredNullObservations"], in: 0...65_535),
              recovered <= programs, calls != 0 || programs == 0 else { return false }
        if programs == 0 { return object["lastProgram"] is NSNull }
        guard let program = object["lastProgram"] as? [String: Any],
              Set(program.keys) == ["elapsedMs", "carrier", "messageStatus", "codeLength", "knownNullProgram",
                                    "emptyFallbackMarkdown", "recovery", "recoveryLine", "recoveryColumn", "conversationMatchesDocument"],
              milliseconds(program["elapsedMs"]) != nil,
              member(program["carrier"], ["message", "reference", "reference_patch"]),
              member(program["messageStatus"], ["in_progress", "finished_successfully", "finished_partial", "other", "unknown"]),
              program["codeLength"] is NSNull || integer(program["codeLength"], in: 0...1_048_576) != nil,
              let knownNull = boolean(program["knownNullProgram"]),
              program["emptyFallbackMarkdown"] is NSNull || boolean(program["emptyFallbackMarkdown"]) != nil,
              program["conversationMatchesDocument"] is NSNull || boolean(program["conversationMatchesDocument"]) != nil,
              member(program["recovery"], ["none", "unterminated_braced_value_recovered_parse", "other", "unknown"]),
              program["recoveryLine"] is NSNull || integer(program["recoveryLine"], in: 1...1_048_576) != nil,
              program["recoveryColumn"] is NSNull || integer(program["recoveryColumn"], in: 1...1_048_576) != nil,
              !knownNull || integer(program["codeLength"], in: 194...194) != nil else { return false }
        return program["recovery"] as? String != "none"
            || (program["recoveryLine"] is NSNull && program["recoveryColumn"] is NSNull)
    }
    private static func validHeaderMetadata(_ value: Any?) -> Bool {
        if value is NSNull { return true }
        guard let object = value as? [String: Any],
              Set(object.keys) == ["representation", "count", "nameUTF8Bytes", "valueUTF8Bytes", "maxValueUTF8Bytes",
                                   "invalidTokenName", "hasNUL", "hasCRLF", "hasNonLatin1"],
              member(object["representation"], ["native_headers", "record", "pairs"]),
              let count = integer(object["count"], in: 0...256),
              let names = integer(object["nameUTF8Bytes"], in: 0...1_048_576),
              let values = integer(object["valueUTF8Bytes"], in: 0...1_048_576),
              let maximum = integer(object["maxValueUTF8Bytes"], in: 0...1_048_576),
              let invalidName = boolean(object["invalidTokenName"]), let nul = boolean(object["hasNUL"]),
              let crlf = boolean(object["hasCRLF"]), let nonLatin1 = boolean(object["hasNonLatin1"]),
              names + values <= 1_048_576, maximum <= values,
              (count != 0 || (names == 0 && values == 0 && maximum == 0 && !invalidName && !nul && !crlf && !nonLatin1)),
              (count == 0 || invalidName || names >= count),
              (values == 0 || maximum > 0), maximum * count >= values,
              (!(nul || crlf || nonLatin1) || names + values > 0) else { return false }
        // A native Headers instance has validated token names and ByteString
        // values already; record/pair observations precede that validation.
        if object["representation"] as? String == "native_headers" {
            return !invalidName && !nul && !crlf && !nonLatin1
        }
        return true
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else { return nil }
        return number.intValue
    }
    private static func milliseconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...600_000).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }
    private static func member(_ value: Any?, _ allowed: Set<String>) -> Bool {
        (value as? String).map(allowed.contains) == true
    }
}

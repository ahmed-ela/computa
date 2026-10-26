import Darwin
import Foundation
import OSLog

/// Private, manually armed diagnostics. No directory creation, permission repair,
/// default telemetry, request-body capture, or retry authority lives here.
enum APIRejectedRequestCapture {
    static let maximumRecordBytes = 8_192
    private static let maximumArmBytes = 512
    enum Mode: Equatable, Sendable {
        case rejection, projection
        fileprivate var output: String { self == .rejection ? "rejected-request.json" : "request-projection.json" }
    }
    enum ProjectionDecodeOutcome: String, Codable, Sendable {
        case responseValidated = "response_validated", argumentsRejected = "arguments_rejected", decodeFailed = "decode_failed"
    }
    enum Disposition: String, Codable, Equatable, Sendable {
        case armUnlinkFailed = "arm_unlink_failed", armDirectorySyncFailed = "arm_directory_sync_failed", armConsumed = "arm_consumed"
        case captureStarted = "capture_started", alreadyUsed = "already_used", encodeFailed = "encode_failed", recordTooLarge = "record_too_large"
        case directoryChanged = "directory_changed", openFailed = "open_failed", chmodFailed = "chmod_failed", writeFailed = "write_failed"
        case fileSyncFailed = "file_sync_failed", fileMetadataInvalid = "file_metadata_invalid", renameFailed = "rename_failed"
        case published = "published", publishedDirectorySyncFailed = "published_directory_sync_failed"
    }
    struct Observation: Codable, Equatable, Sendable {
        let disposition: Disposition
        /// nil means not encoded/unknown; 8193 is an over-limit sentinel.
        let byteCount: Int?
    }
    typealias DispositionObserver = @Sendable (Observation) -> Void
    private static let dispositionLog = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "APIRequestCapture")
    private static func observe(_ disposition: Disposition, byteCount: Int? = nil, observer: DispositionObserver?) {
        let boundedCount = byteCount.map { min(max(0, $0), maximumRecordBytes + 1) }
        observer?(.init(disposition: disposition, byteCount: boundedCount))
        // Only a valid private arm or its resulting ticket reaches this logger.
        // -1 denotes unknown; no file paths, native IDs or provider fields enter it.
        dispositionLog.notice("captureDisposition disposition=\(disposition.rawValue, privacy: .public) byteCount=\(boundedCount ?? -1)")
    }

    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        private let directory: URL
        private let descriptor: Int32
        private let initial: stat
        private let taskID: UUID, threadID: UUID, turnID: UUID
        private let dispositionObserver: DispositionObserver?
        let mode: Mode
        fileprivate init(directory: URL, descriptor: Int32, initial: stat, taskID: UUID, threadID: UUID, turnID: UUID,
                         mode: Mode, dispositionObserver: DispositionObserver?) {
            self.directory = directory; self.descriptor = descriptor; self.initial = initial
            self.taskID = taskID; self.threadID = threadID; self.turnID = turnID
            self.dispositionObserver = dispositionObserver
            self.mode = mode
        }
        deinit { close(descriptor) }
        func capture(_ diagnostic: APIProviderHTTPClient.RejectionDiagnostic) {
            guard mode == .rejection else { return }
            struct Record: Encodable {
                let version = 1
                let taskID: String, threadID: String, turnID: String
                let automaticReplay = false
                let diagnostic: APIProviderHTTPClient.RejectionDiagnostic
            }
            let record = Record(taskID: taskID.uuidString.lowercased(), threadID: threadID.uuidString.lowercased(),
                                turnID: turnID.uuidString.lowercased(), diagnostic: diagnostic)
            publish(record)
        }
        func captureProjection(_ diagnostic: APIProviderHTTPClient.SuccessfulRequestProjection?,
                               decodeOutcome: ProjectionDecodeOutcome) {
            guard mode == .projection, let diagnostic else { return }
            struct Record: Encodable {
                let version = 1
                let taskID: String, threadID: String, turnID: String
                let purpose = "ordinary_inference", attempt = 1
                let automaticReplay = false, taskOutcomeVerified = false
                let diagnostic: APIProviderHTTPClient.SuccessfulRequestProjection
                let decodeOutcome: ProjectionDecodeOutcome
            }
            publish(Record(taskID: taskID.uuidString.lowercased(), threadID: threadID.uuidString.lowercased(),
                turnID: turnID.uuidString.lowercased(), diagnostic: diagnostic, decodeOutcome: decodeOutcome))
        }
        private func publish<T: Encodable>(_ record: T) {
            lock.lock(); defer { lock.unlock() }
            guard !used else { observe(.alreadyUsed, observer: dispositionObserver); return }; used = true
            observe(.captureStarted, observer: dispositionObserver)
            guard let bytes = try? JSONEncoder().encode(record) else { observe(.encodeFailed, observer: dispositionObserver); return }
            guard bytes.count <= maximumRecordBytes else { observe(.recordTooLarge, byteCount: bytes.count, observer: dispositionObserver); return }
            guard directoryStillMatches(directory, descriptor: descriptor, initial: initial) else {
                observe(.directoryChanged, byteCount: bytes.count, observer: dispositionObserver); return
            }
            let temporary = ".rejected-request-" + UUID().uuidString.lowercased() + ".tmp"
            let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { observe(.openFailed, byteCount: bytes.count, observer: dispositionObserver); return }
            defer {
                var held = stat(), named = stat()
                if fstat(output, &held) == 0, fstatat(descriptor, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   sameUnchangedFile(held, named) { _ = unlinkat(descriptor, temporary, 0) }
                close(output)
            }
            guard fchmod(output, 0o600) == 0 else { observe(.chmodFailed, byteCount: bytes.count, observer: dispositionObserver); return }
            guard writeAll(bytes, descriptor: output) else { observe(.writeFailed, byteCount: bytes.count, observer: dispositionObserver); return }
            guard fsync(output) == 0 else { observe(.fileSyncFailed, byteCount: bytes.count, observer: dispositionObserver); return }
            guard directoryStillMatches(directory, descriptor: descriptor, initial: initial) else {
                observe(.directoryChanged, byteCount: bytes.count, observer: dispositionObserver); return
            }
            var written = stat(), named = stat()
            guard fstat(output, &written) == 0, privateFile(written), written.st_size == bytes.count,
                  fstatat(descriptor, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(written, named) else {
                observe(.fileMetadataInvalid, byteCount: bytes.count, observer: dispositionObserver); return
            }
            guard renameatx_np(descriptor, temporary, descriptor, mode.output, UInt32(RENAME_EXCL)) == 0 else {
                observe(.renameFailed, byteCount: bytes.count, observer: dispositionObserver); return
            }
            let synced = fsync(descriptor) == 0 // Preserve the existing non-fatal final directory sync.
            observe(synced ? .published : .publishedDirectorySyncFailed, byteCount: bytes.count, observer: dispositionObserver)
        }
    }

    /// Called only after authenticated native turn admission and request validation,
    /// immediately before its sole upstream dispatch. A successful request also
    /// consumes the arm, so it cannot authorize another turn accidentally.
    static func consume(directory: URL?, taskID: UUID, threadID: UUID, turnID: UUID,
                        ordinaryInference: Bool = true, onDisposition: DispositionObserver? = nil) -> Ticket? {
        guard let directory else { return nil }
        let descriptor = openDirectoryWithoutSymlinks(directory)
        guard descriptor >= 0 else { return nil }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0, privateDirectory(directoryInfo),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        let armFD = openat(descriptor, "arm.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard armFD >= 0 else { return nil }
        defer { close(armFD) }
        var before = stat()
        guard fstat(armFD, &before) == 0, privateFile(before), before.st_size > 0,
              before.st_size <= maximumArmBytes, let bytes = readArm(armFD), bytes.count == before.st_size,
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        let uuid = #"[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}"#
        let task = #""taskID"\s*:\s*""# + uuid + #"""#
        let thread = #""threadID"\s*:\s*""# + uuid + #"""#
        let projection = #""mode"\s*:\s*"projection""#
        let legacy = [[task, thread], [thread, task]]
        let projected = [[task, thread, projection], [thread, task, projection],
            [task, projection, thread], [thread, projection, task], [projection, task, thread], [projection, thread, task]]
        let alternatives = (legacy + projected).map { $0.joined(separator: #"\s*,\s*"#) }.joined(separator: "|")
        let pattern = #"^\s*\{\s*(?:"# + alternatives + #")\s*\}\s*$"#
        guard text.range(of: pattern, options: .regularExpression) != nil,
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
              UUID(uuidString: value["taskID"] ?? "") == taskID,
              UUID(uuidString: value["threadID"] ?? "") == threadID else { return nil }
        let mode: Mode = value["mode"] == "projection" ? .projection : .rejection
        // The optional mode grants only one ordinary request inspection. Native
        // maintenance leaves its arm intact; corrective requests never consume.
        guard mode != .projection || ordinaryInference else { return nil }
        var after = stat(), named = stat(), output = stat()
        guard fstat(armFD, &after) == 0, sameUnchangedFile(before, after),
              fstatat(descriptor, "arm.json", &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(before, named),
              fstatat(descriptor, mode.output, &output, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              directoryStillMatches(directory, descriptor: descriptor, initial: directoryInfo) else { return nil }
        let claimed = ".claimed-arm-" + UUID().uuidString.lowercased()
        guard renameatx_np(descriptor, "arm.json", descriptor, claimed, UInt32(RENAME_EXCL)) == 0 else { return nil }
        var claim = stat()
        guard fstatat(descriptor, claimed, &claim, AT_SYMLINK_NOFOLLOW) == 0, privateFile(claim),
              before.st_dev == claim.st_dev, before.st_ino == claim.st_ino, before.st_size == claim.st_size,
              before.st_mtimespec.tv_sec == claim.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == claim.st_mtimespec.tv_nsec,
              lseek(armFD, 0, SEEK_SET) == 0, readArm(armFD) == bytes,
              fstat(armFD, &after) == 0, sameUnchangedFile(claim, after),
              fstatat(descriptor, claimed, &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(after, named) else {
            _ = renameatx_np(descriptor, claimed, descriptor, "arm.json", UInt32(RENAME_EXCL)); return nil
        }
        guard unlinkat(descriptor, claimed, 0) == 0 else { observe(.armUnlinkFailed, byteCount: bytes.count, observer: onDisposition); return nil }
        if fsync(descriptor) != 0 { observe(.armDirectorySyncFailed, byteCount: bytes.count, observer: onDisposition) }
        observe(.armConsumed, byteCount: bytes.count, observer: onDisposition)
        transferred = true
        return Ticket(directory: directory, descriptor: descriptor, initial: directoryInfo, taskID: taskID, threadID: threadID, turnID: turnID,
                      mode: mode, dispositionObserver: onDisposition)
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
        var bytes = Data(count: maximumArmBytes + 1)
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
        guard let count, count <= maximumArmBytes else { return nil }
        bytes.count = count
        return bytes
    }

    private static func writeAll(_ bytes: Data, descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if result < 0 { if errno == EINTR { continue }; return false }
                guard result > 0 else { return false }
                count += result
            }
            return true
        }
    }
}

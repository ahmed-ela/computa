import Darwin
import Foundation

/// Shared same-UID diagnostic file discipline. The caller alone validates an
/// explicit arm and creates its record; this helper grants no inference authority.
/// It never creates directories or replaces an existing output.
enum WebsitePrivateDiagnosticCapture {
    enum Record: String, Sendable {
        case request = "request.json"
        case rejectedReply = "rejected-reply.json"
        case claudeResponseMetadata = "response-metadata.json"

        var maximumBytes: Int { self == .claudeResponseMetadata ? 96 * 1_024 : 2_000_000 }
    }

    /// Holds the exact private directory opened during the single arm claim.
    /// The descriptor/lock live through publication; no replacement directory
    /// can inherit a claim. The caller must still enforce its native lease.
    final class Claim: @unchecked Sendable {
        fileprivate let directory: URL
        fileprivate let directoryFD: Int32
        fileprivate let directoryInfo: stat
        fileprivate let record: Record
        private let lock = NSLock()
        private var attempted = false

        fileprivate init(directory: URL, directoryFD: Int32, directoryInfo: stat, record: Record) {
            self.directory = directory; self.directoryFD = directoryFD
            self.directoryInfo = directoryInfo; self.record = record
        }
        deinit { close(directoryFD) }
        fileprivate func beginPublication() -> Bool {
            lock.withLock { guard !attempted else { return false }; attempted = true; return true }
        }
    }

    // Compatibility wrapper: record construction still precedes the arm claim,
    // and a raced replacement is restored rather than granting old authority.
    static func publish(directory: URL, outputName: String, maximumArmBytes: Int,
                        maximumRecordBytes: Int, makeRecord: (Data) -> Data?,
                        isCurrent: () -> Bool = { true },
                        beforeArmClaim: (@Sendable () -> Void)? = nil) -> Bool {
        guard let kind = Record(rawValue: outputName), kind != .claudeResponseMetadata,
              maximumRecordBytes > 0, maximumRecordBytes <= kind.maximumBytes else { return false }
        var record: Data?
        guard let claimed = claim(directory: directory, record: kind, maximumArmBytes: maximumArmBytes,
            validate: { arm in
                guard let value = makeRecord(arm), !value.isEmpty, value.count <= maximumRecordBytes else { return false }
                record = value; return true
            }, isCurrent: isCurrent, beforeArmClaim: beforeArmClaim), let record else { return false }
        return publish(record, using: claimed, isCurrent: isCurrent, commit: { rename in
            guard isCurrent() else { return false }; return rename()
        })
    }

    /// Validate and consume once. No output is written and no directories are
    /// created. Filesystem/expiry checks are deliberately separate from a lease.
    static func claim(directory: URL, record: Record, maximumArmBytes: Int,
                      validate: (Data) -> Bool, isCurrent: () -> Bool,
                      beforeArmClaim: (@Sendable () -> Void)? = nil) -> Claim? {
        // Legacy validators establish their monotonic deadline while creating
        // the record. Their first eligibility check must remain after validate.
        guard (1...4096).contains(maximumArmBytes) else { return nil }
        let directoryFD = openDirectoryWithoutSymlinks(directory)
        guard directoryFD >= 0 else { return nil }
        var retained = false
        defer { if !retained { close(directoryFD) } }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, privateDirectory(directoryInfo),
              flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else { return nil }
        let armFD = openat(directoryFD, "arm.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard armFD >= 0 else { return nil }
        defer { close(armFD) }
        var before = stat()
        guard fstat(armFD, &before) == 0, privateFile(before), before.st_size > 0,
              before.st_size <= maximumArmBytes, let arm = readArm(armFD, maximum: maximumArmBytes),
              arm.count == before.st_size, validate(arm), isCurrent() else { return nil }
        var after = stat(), named = stat(), output = stat()
        guard fstat(armFD, &after) == 0, sameUnchangedFile(before, after),
              fstatat(directoryFD, "arm.json", &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(before, named),
              fstatat(directoryFD, record.rawValue, &output, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return nil }
        let claimed = ".claimed-arm-" + UUID().uuidString.lowercased()
        beforeArmClaim?()
        guard renameatx_np(directoryFD, "arm.json", directoryFD, claimed, UInt32(RENAME_EXCL)) == 0 else { return nil }
        var claimedInfo = stat()
        // Preserve a raced replacement exclusively, or leave its private claimed
        // file recoverable if another new arm already occupies the original name.
        guard fstatat(directoryFD, claimed, &claimedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              privateFile(claimedInfo), before.st_dev == claimedInfo.st_dev, before.st_ino == claimedInfo.st_ino,
              before.st_size == claimedInfo.st_size,
              before.st_mtimespec.tv_sec == claimedInfo.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == claimedInfo.st_mtimespec.tv_nsec,
              lseek(armFD, 0, SEEK_SET) == 0, readArm(armFD, maximum: maximumArmBytes) == arm,
              fstat(armFD, &after) == 0, sameUnchangedFile(claimedInfo, after),
              fstatat(directoryFD, claimed, &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(after, named) else {
            _ = renameatx_np(directoryFD, claimed, directoryFD, "arm.json", UInt32(RENAME_EXCL))
            return nil
        }
        let authorizedClaim = after
        defer {
            var remaining = stat()
            if fstatat(directoryFD, claimed, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               sameUnchangedFile(authorizedClaim, remaining) { _ = unlinkat(directoryFD, claimed, 0) }
        }
        guard isCurrent(), directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return nil }
        // Consumption is irreversible even if a later snapshot is unavailable.
        guard unlinkat(directoryFD, claimed, 0) == 0 else { return nil }
        guard fsync(directoryFD) == 0 else { return nil }
        guard isCurrent() else { return nil }
        retained = true
        return Claim(directory: directory, directoryFD: directoryFD, directoryInfo: directoryInfo, record: record)
    }

    /// All preparation and fsync happen before/after commit. The caller uses
    /// commit to serialize only the final eligibility check and exclusive rename
    /// with lease revocation; slow writes cannot hold the caller's lease lock.
    static func publish(_ record: Data, using claim: Claim, isCurrent: () -> Bool,
                        beforeRecordWrite: (() -> Void)? = nil,
                        beforeCommit: (() -> Void)? = nil,
                        commit: (_ rename: () -> Bool) -> Bool) -> Bool {
        guard !record.isEmpty, record.count <= claim.record.maximumBytes,
              claim.beginPublication(), isCurrent() else { return false }
        let directoryFD = claim.directoryFD, directory = claim.directory, directoryInfo = claim.directoryInfo
        guard directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return false }
        let temporary = ".diagnostic-record-" + UUID().uuidString.lowercased() + ".tmp"
        let outputFD = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { return false }
        defer {
            var held = stat(), remaining = stat()
            if fstat(outputFD, &held) == 0,
               fstatat(directoryFD, temporary, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               sameUnchangedFile(held, remaining) { _ = unlinkat(directoryFD, temporary, 0) }
            close(outputFD)
        }
        beforeRecordWrite?()
        guard fchmod(outputFD, 0o600) == 0, writeAll(record, descriptor: outputFD), fsync(outputFD) == 0,
              isCurrent() else { return false }
        beforeCommit?()
        guard directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo), isCurrent() else { return false }
        var written = stat(), temporaryInfo = stat()
        guard fstat(outputFD, &written) == 0, privateFile(written), written.st_size == record.count,
              fstatat(directoryFD, temporary, &temporaryInfo, AT_SYMLINK_NOFOLLOW) == 0,
              sameUnchangedFile(written, temporaryInfo),
              commit({ renameatx_np(directoryFD, temporary, directoryFD, claim.record.rawValue, UInt32(RENAME_EXCL)) == 0 })
        else { return false }
        _ = fsync(directoryFD)
        return true
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

    private static func readArm(_ descriptor: Int32, maximum: Int) -> Data? {
        var bytes = Data(count: maximum + 1)
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
        guard let count, count <= maximum else { return nil }
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

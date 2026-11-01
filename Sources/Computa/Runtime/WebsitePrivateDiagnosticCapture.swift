import Darwin
import Foundation

/// Shared same-UID diagnostic file discipline. The caller alone validates an
/// explicit arm and creates its record; this helper grants no inference authority.
/// It never creates directories or replaces an existing output.
enum WebsitePrivateDiagnosticCapture {
    static func publish(directory: URL, outputName: String, maximumArmBytes: Int,
                        maximumRecordBytes: Int, makeRecord: (Data) -> Data?,
                        isCurrent: () -> Bool = { true },
                        beforeArmClaim: (@Sendable () -> Void)? = nil) -> Bool {
        guard ["rejected-reply.json", "request.json"].contains(outputName),
              (1...4096).contains(maximumArmBytes), maximumRecordBytes > 0,
              maximumRecordBytes <= 2_000_000 else { return false }
        let directoryFD = openDirectoryWithoutSymlinks(directory)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, privateDirectory(directoryInfo),
              flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else { return false }
        let armFD = openat(directoryFD, "arm.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard armFD >= 0 else { return false }
        defer { close(armFD) }
        var before = stat()
        guard fstat(armFD, &before) == 0, privateFile(before), before.st_size > 0,
              before.st_size <= maximumArmBytes, let arm = readArm(armFD, maximum: maximumArmBytes),
              arm.count == before.st_size, let record = makeRecord(arm),
              !record.isEmpty, record.count <= maximumRecordBytes, isCurrent() else { return false }
        var after = stat(), named = stat(), output = stat()
        guard fstat(armFD, &after) == 0, sameUnchangedFile(before, after),
              fstatat(directoryFD, "arm.json", &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(before, named),
              fstatat(directoryFD, outputName, &output, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return false }
        let claimed = ".claimed-arm-" + UUID().uuidString.lowercased()
        beforeArmClaim?()
        guard renameatx_np(directoryFD, "arm.json", directoryFD, claimed, UInt32(RENAME_EXCL)) == 0 else { return false }
        var claimedInfo = stat()
        // A replaced arm must never grant capture authority to its old reader.
        // Preserve a raced replacement: restore it exclusively, or leave its
        // private claimed file recoverable if another new arm already exists.
        guard fstatat(directoryFD, claimed, &claimedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              privateFile(claimedInfo), before.st_dev == claimedInfo.st_dev, before.st_ino == claimedInfo.st_ino,
              before.st_size == claimedInfo.st_size,
              before.st_mtimespec.tv_sec == claimedInfo.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == claimedInfo.st_mtimespec.tv_nsec,
              lseek(armFD, 0, SEEK_SET) == 0, readArm(armFD, maximum: maximumArmBytes) == arm,
              fstat(armFD, &after) == 0, sameUnchangedFile(claimedInfo, after),
              fstatat(directoryFD, claimed, &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(after, named) else {
            _ = renameatx_np(directoryFD, claimed, directoryFD, "arm.json", UInt32(RENAME_EXCL))
            return false
        }
        let authorizedClaim = after
        defer {
            var remaining = stat()
            if fstatat(directoryFD, claimed, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               sameUnchangedFile(authorizedClaim, remaining) { _ = unlinkat(directoryFD, claimed, 0) }
        }
        guard isCurrent() else { return false }
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
        guard fchmod(outputFD, 0o600) == 0, writeAll(record, descriptor: outputFD), fsync(outputFD) == 0,
              directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo), isCurrent() else { return false }
        var written = stat(), temporaryInfo = stat()
        guard fstat(outputFD, &written) == 0, privateFile(written), written.st_size == record.count,
              fstatat(directoryFD, temporary, &temporaryInfo, AT_SYMLINK_NOFOLLOW) == 0,
              sameUnchangedFile(written, temporaryInfo),
              renameatx_np(directoryFD, temporary, directoryFD, outputName, UInt32(RENAME_EXCL)) == 0 else { return false }
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

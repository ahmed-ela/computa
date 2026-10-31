import CoreFoundation
import Darwin
import Foundation

/// Private, bounded diagnostic history. These files never grant model, browser,
/// recovery, or cleanup authority. Only the finite typed report can be saved.
struct GeminiCAPTCHADiagnosticStore: Sendable {
    enum Failure: Error, Equatable {
        case directoryUnavailable, unsafeEntry, invalidReport, capacity, conflict, busy, writeFailed
    }

    static let maximumReports = 16
    static let maximumReportBytes = GeminiCAPTCHADiagnostic.maximumReportBytes
    static let maximumDirectoryBytes = 1_048_576
    static let maximumOrphanStages = 2
    let directory: URL

    #if DEBUG
    enum FaultPoint: Sendable, Equatable { case beforeWrite, beforePublish, afterPublish }
    var faultForTesting: (@Sendable (FaultPoint) throws -> Void)?
    #endif

    init(directory: URL) throws {
        self.directory = directory
        let handles = try openDirectory()
        handles.close()
    }

    @discardableResult
    func save(_ report: GeminiCAPTCHADiagnostic.Report) throws -> URL {
        let data = try report.encodedData()
        let name = report.id.uuidString.lowercased() + ".json"
        try validate(data, named: name)
        let handles = try openDirectory()
        defer { handles.close() }
        guard flock(handles.directory, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { _ = flock(handles.directory, LOCK_UN) }
        try requireDirectory(handles)
        let inventory = try inventory(handles)
        var files = inventory.files
        if let existing = files.first(where: { $0.name == name }) {
            guard existing.data == data else { throw Failure.conflict }
            // A prior crash after publication can leave the one extra report.
            // Exact duplicate recovery preserves the already-published bytes.
            try prune(&files, keeping: name, in: handles)
            guard fsync(handles.directory) == 0 else { throw Failure.writeFailed }
            guard try read(name, in: handles).data == data else { throw Failure.writeFailed }
            return directory.appendingPathComponent(name)
        }
        // Complete an interrupted post-publication retention step first. Every
        // entry was privately owned and validated before any removal is allowed.
        try prune(&files, keeping: nil, in: handles)
        let currentBytes = files.reduce(0) { $0 + $1.data.count }
        // Include staging bytes in the bound. Near-capacity directories fail
        // explicitly rather than deleting old evidence to make a write possible.
        guard currentBytes + inventory.orphanBytes + data.count <= Self.maximumDirectoryBytes else { throw Failure.capacity }
        let temporary = ".gemini-captcha-" + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(handles.directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.writeFailed }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { _ = unlinkat(handles.directory, temporary, 0) }
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw Failure.writeFailed }
        #if DEBUG
        try faultForTesting?(.beforeWrite)
        #endif
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw Failure.writeFailed }
        try requireDirectory(handles)
        #if DEBUG
        try faultForTesting?(.beforePublish)
        #endif
        guard renameatx_np(handles.directory, temporary, handles.directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw Failure.writeFailed
        }
        published = true
        guard fsync(handles.directory) == 0 else { throw Failure.writeFailed }
        #if DEBUG
        try faultForTesting?(.afterPublish)
        #endif
        let saved = try read(name, in: handles)
        guard saved.data == data else { throw Failure.writeFailed }
        files.append(saved)
        try prune(&files, keeping: name, in: handles)
        try requireDirectory(handles)
        guard try read(name, in: handles).data == data else { throw Failure.writeFailed }
        return directory.appendingPathComponent(name)
    }

    private struct Handles {
        let parent: Int32
        let directory: Int32
        let name: String
        let identity: stat
        func close() { Darwin.close(directory); Darwin.close(parent) }
    }

    private func openDirectory() throws -> Handles {
        guard directory.isFileURL, directory.baseURL == nil, directory.path.hasPrefix("/"),
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil,
              directory.path.utf8.count <= 4_096 else { throw Failure.directoryUnavailable }
        let parts = directory.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.count <= 64,
              parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw Failure.directoryUnavailable }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.directoryUnavailable }
        do {
            for part in parts.dropLast() {
                let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.directoryUnavailable }
                Darwin.close(parent); parent = next
            }
            let name = parts.last!
            var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT {
                if mkdirat(parent, name, 0o700) == 0 {
                    guard fsync(parent) == 0 else { throw Failure.directoryUnavailable }
                } else if errno != EEXIST { throw Failure.directoryUnavailable }
                descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw Failure.directoryUnavailable }
            var info = stat()
            guard fstat(descriptor, &info) == 0, privateDirectory(info) else {
                Darwin.close(descriptor); throw Failure.directoryUnavailable
            }
            return Handles(parent: parent, directory: descriptor, name: name, identity: info)
        } catch { Darwin.close(parent); throw error }
    }

    private func privateDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid() && info.st_mode & 0o7777 == 0o700
    }

    private func requireDirectory(_ handles: Handles) throws {
        var held = stat(), named = stat()
        guard fstat(handles.directory, &held) == 0,
              fstatat(handles.parent, handles.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              privateDirectory(held), privateDirectory(named),
              held.st_dev == handles.identity.st_dev, held.st_ino == handles.identity.st_ino,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw Failure.directoryUnavailable }
    }

    private struct File {
        let name: String
        let data: Data
        let identity: stat
    }

    private func validName(_ name: String) -> Bool {
        guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { return false }
        return name == id.uuidString.lowercased() + ".json"
    }

    private func validate(_ data: Data, named name: String) throws {
        guard validName(name), (1...Self.maximumReportBytes).contains(data.count),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == "gemini_captcha_diagnostic",
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1,
              let rawID = object["id"] as? String, let id = UUID(uuidString: rawID),
              id.uuidString.lowercased() + ".json" == name else { throw Failure.invalidReport }
    }

    private func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
            && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private func read(_ name: String, in handles: Handles) throws -> File {
        guard validName(name) else { throw Failure.unsafeEntry }
        let descriptor = openat(handles.directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeEntry }
        defer { Darwin.close(descriptor) }
        var before = stat(), named = stat()
        guard fstat(descriptor, &before) == 0,
              fstatat(handles.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0, sameFile(before, named),
              before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o7777 == 0o600,
              (1...Self.maximumReportBytes).contains(Int(before.st_size)) else { throw Failure.unsafeEntry }
        var data = Data(count: Self.maximumReportBytes + 1)
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw Failure.unsafeEntry }
                if count == 0 { return offset }; offset += count
            }
            return offset
        }
        guard count == before.st_size else { throw Failure.unsafeEntry }
        data.count = count
        try validate(data, named: name)
        var after = stat(), current = stat()
        guard fstat(descriptor, &after) == 0, fstatat(handles.directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(before, after), sameFile(after, current) else { throw Failure.unsafeEntry }
        try requireDirectory(handles)
        return File(name: name, data: data, identity: after)
    }

    private struct Inventory { let files: [File]; let orphanBytes: Int }

    private func orphanSize(_ name: String, in handles: Handles) throws -> Int {
        let prefix = ".gemini-captcha-", suffix = ".tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              let id = UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))),
              name == prefix + id.uuidString.lowercased() + suffix else { throw Failure.unsafeEntry }
        let descriptor = openat(handles.directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeEntry }
        defer { Darwin.close(descriptor) }
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, fstatat(handles.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(held, named), held.st_mode & S_IFMT == S_IFREG, held.st_uid == geteuid(),
              held.st_nlink == 1, held.st_mode & 0o7777 == 0o600,
              (0...Self.maximumReportBytes).contains(Int(held.st_size)) else { throw Failure.unsafeEntry }
        return Int(held.st_size)
    }

    private func inventory(_ handles: Handles) throws -> Inventory {
        let copy = dup(handles.directory)
        guard copy >= 0 else { throw Failure.directoryUnavailable }
        guard let listing = fdopendir(copy) else { Darwin.close(copy); throw Failure.directoryUnavailable }
        defer { closedir(listing) }
        var files: [File] = [], bytes = 0, orphanBytes = 0, orphans = 0
        while true {
            errno = 0
            guard let entry = readdir(listing) else {
                guard errno == 0 else { throw Failure.directoryUnavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if name.hasPrefix(".gemini-captcha-") {
                guard orphans < Self.maximumOrphanStages else { throw Failure.capacity }
                let size = try orphanSize(name, in: handles)
                orphans += 1; orphanBytes += size; bytes += size
                guard bytes <= Self.maximumDirectoryBytes else { throw Failure.capacity }
                // A crash can leave a partial private file. Preserve it, since
                // incomplete bytes cannot establish a report identity to prune.
                continue
            }
            // One extra published file is allowed only for crash recovery.
            guard files.count < Self.maximumReports + 1 else { throw Failure.capacity }
            let file = try read(name, in: handles)
            bytes += file.data.count
            guard bytes <= Self.maximumDirectoryBytes else { throw Failure.capacity }
            files.append(file)
        }
        return Inventory(files: files, orphanBytes: orphanBytes)
    }

    private func prune(_ files: inout [File], keeping name: String?, in handles: Handles) throws {
        let oldest = files.filter { $0.name != name }.sorted {
            let a = $0.identity.st_mtimespec, b = $1.identity.st_mtimespec
            if a.tv_sec != b.tv_sec { return a.tv_sec < b.tv_sec }
            if a.tv_nsec != b.tv_nsec { return a.tv_nsec < b.tv_nsec }
            return $0.name < $1.name
        }
        for candidate in oldest.prefix(max(0, files.count - Self.maximumReports)) {
            try requireDirectory(handles)
            let current = try read(candidate.name, in: handles)
            guard sameFile(current.identity, candidate.identity), current.data == candidate.data else { throw Failure.unsafeEntry }
            guard unlinkat(handles.directory, candidate.name, 0) == 0, fsync(handles.directory) == 0 else { throw Failure.writeFailed }
            files.removeAll { $0.name == candidate.name }
        }
    }
}

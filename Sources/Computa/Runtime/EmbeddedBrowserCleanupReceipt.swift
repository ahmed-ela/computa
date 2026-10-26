import CryptoKit
import Darwin
import Foundation

/// Host observations only. This report grants no browser or model authority.
struct EmbeddedBrowserCleanupReport: Codable, Equatable, Sendable {
    enum Trigger: String, Codable, Sendable { case explicit, replacement, automatic, shutdown }
    enum Issue: String, Codable, Sendable {
        case bindingReleaseFailed, ownedTargetCloseFailed, operationPending, historyLimit
    }
    struct Target: Codable, Equatable, Sendable {
        let targetID: String
        let instanceToken: String
        let trigger: Trigger
        let closed: Bool

        init(targetID: String, instanceToken: String, trigger: Trigger, closed: Bool) {
            self.targetID = targetID; self.instanceToken = instanceToken
            self.trigger = trigger; self.closed = closed
        }
        private enum CodingKeys: String, CodingKey, CaseIterable { case targetID, instanceToken, trigger, closed }
        init(from decoder: any Decoder) throws {
            try CleanupReceiptCoding.requireKeys(decoder, CodingKeys.self)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(targetID: try values.decode(String.self, forKey: .targetID),
                      instanceToken: try values.decode(String.self, forKey: .instanceToken),
                      trigger: try values.decode(Trigger.self, forKey: .trigger),
                      closed: try values.decode(Bool.self, forKey: .closed))
            guard isValid else { throw CleanupReceiptCoding.invalid(decoder) }
        }
        fileprivate var isValid: Bool {
            CleanupReceiptCoding.validIdentity(targetID) && CleanupReceiptCoding.validIdentity(instanceToken)
        }
    }

    let targets: [Target]
    let userBindingReleased: Bool
    let pendingOperation: Bool
    let failures: [Issue]

    init(targets: [Target] = [], userBindingReleased: Bool = false,
         pendingOperation: Bool = false, failures: [Issue] = []) {
        self.targets = targets; self.userBindingReleased = userBindingReleased
        self.pendingOperation = pendingOperation; self.failures = failures
    }
    var isSettled: Bool { targets.allSatisfy(\.closed) && failures.isEmpty && !pendingOperation }
    var wasUsed: Bool { !targets.isEmpty || userBindingReleased || pendingOperation || !failures.isEmpty }
    var issues: [String] {
        var observed = failures
        if targets.contains(where: { !$0.closed }) && !observed.contains(.ownedTargetCloseFailed) {
            observed.append(.ownedTargetCloseFailed)
        }
        if pendingOperation && !observed.contains(.operationPending) { observed.append(.operationPending) }
        let values = observed.map { issue in
            switch issue {
            case .bindingReleaseFailed: "The existing browser-tab binding could not be released."
            case .ownedTargetCloseFailed: "A task-created browser tab could not be confirmed closed."
            case .operationPending: "A task browser operation is still pending."
            case .historyLimit: "The task browser cleanup history reached its bound."
            }
        }
        return values.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case targets, userBindingReleased, pendingOperation, failures }
    init(from decoder: any Decoder) throws {
        try CleanupReceiptCoding.requireKeys(decoder, CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(targets: try values.decode([Target].self, forKey: .targets),
                  userBindingReleased: try values.decode(Bool.self, forKey: .userBindingReleased),
                  pendingOperation: try values.decode(Bool.self, forKey: .pendingOperation),
                  failures: try values.decode([Issue].self, forKey: .failures))
    }
    fileprivate var isValid: Bool { targets.allSatisfy(\.isValid) }
}

struct EmbeddedBrowserCleanupReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int = 1
    let taskID: String
    let threadID: String
    let turnID: String
    let runtimeGeneration: UUID
    let timestamp: Date
    let report: EmbeddedBrowserCleanupReport

    init(taskID: String, threadID: String, turnID: String, runtimeGeneration: UUID,
         report: EmbeddedBrowserCleanupReport, timestamp: Date = .now) {
        self.taskID = taskID; self.threadID = threadID; self.turnID = turnID
        self.runtimeGeneration = runtimeGeneration; self.timestamp = timestamp; self.report = report
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, taskID, threadID, turnID, runtimeGeneration, timestamp, report
    }
    init(from decoder: any Decoder) throws {
        try CleanupReceiptCoding.requireKeys(decoder, CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else { throw CleanupReceiptCoding.invalid(decoder) }
        self.init(taskID: try values.decode(String.self, forKey: .taskID),
                  threadID: try values.decode(String.self, forKey: .threadID),
                  turnID: try values.decode(String.self, forKey: .turnID),
                  runtimeGeneration: try values.decode(UUID.self, forKey: .runtimeGeneration),
                  report: try values.decode(EmbeddedBrowserCleanupReport.self, forKey: .report),
                  timestamp: try values.decode(Date.self, forKey: .timestamp))
        guard isValid else { throw CleanupReceiptCoding.invalid(decoder) }
    }
    fileprivate var isValid: Bool {
        [taskID, threadID, turnID].allSatisfy(CleanupReceiptCoding.validIdentity)
            && timestamp.timeIntervalSinceReferenceDate.isFinite && report.isValid
    }
}

private enum CleanupReceiptCoding {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func requireKeys<K: CodingKey & CaseIterable>(_ decoder: any Decoder, _ keys: K.Type) throws {
        let supplied = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        guard Set(supplied) == Set(K.allCases.map(\.stringValue)) else { throw invalid(decoder) }
    }
    static func invalid(_ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid native browser cleanup receipt."))
    }
    static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
    }
}

/// One immutable receipt per exact native turn/generation, never page content.
/// Directory and file descriptors retain physical ownership across publication.
struct EmbeddedBrowserCleanupReceiptStore: Sendable {
    enum Failure: Error { case invalidReceipt, unavailable, recordLimit }
    static let maximumRecordBytes = 64 * 1_024
    static let maximumRecords = 8_192
    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// The configured existing app-data home may use normal OS aliases such
    /// as /var. Resolve that trusted parent once; the new receipt directory
    /// and its records still pass the descriptor-based no-follow checks.
    init?(codexHomePath: String) {
        guard codexHomePath.hasPrefix("/"), codexHomePath.utf8.count <= 4_096,
              !codexHomePath.contains("\0"), let physical = realpath(codexHomePath, nil) else { return nil }
        defer { free(physical) }
        directory = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("EmbeddedBrowserCleanup-v1", isDirectory: true)
    }

    func save(_ receipt: EmbeddedBrowserCleanupReceipt) -> Bool {
        do {
            guard receipt.isValid else { throw Failure.invalidReceipt }
            let bytes = try encoded(receipt)
            guard bytes.count <= Self.maximumRecordBytes else { throw Failure.recordLimit }
            guard let handles = try openDirectory(create: true) else { throw Failure.unavailable }
            defer { close(handles.directory); close(handles.parent) }
            guard flock(handles.directory, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
            defer { _ = flock(handles.directory, LOCK_UN) }
            try requireDirectory(handles)
            let count = try entryCount(handles.directory)
            let name = try filename(taskID: receipt.taskID, threadID: receipt.threadID,
                                    turnID: receipt.turnID, runtimeGeneration: receipt.runtimeGeneration)
            if let existing = try read(name, in: handles) {
                guard existing == receipt, fsync(handles.directory) == 0 else { throw Failure.unavailable }
                try requireDirectory(handles)
                return true
            }
            guard count < Self.maximumRecords else { throw Failure.recordLimit }
            try publish(bytes, name: name, in: handles)
            guard try read(name, in: handles) == receipt else { throw Failure.unavailable }
            return true
        } catch { return false }
    }

    func load(taskID: String, threadID: String, turnID: String,
              runtimeGeneration: UUID) throws -> EmbeddedBrowserCleanupReceipt? {
        let name = try filename(taskID: taskID, threadID: threadID, turnID: turnID, runtimeGeneration: runtimeGeneration)
        guard let handles = try openDirectory(create: false) else { return nil }
        defer { close(handles.directory); close(handles.parent) }
        guard flock(handles.directory, LOCK_SH | LOCK_NB) == 0 else { throw Failure.unavailable }
        defer { _ = flock(handles.directory, LOCK_UN) }
        try requireDirectory(handles)
        _ = try entryCount(handles.directory)
        guard let receipt = try read(name, in: handles) else { return nil }
        guard receipt.taskID == taskID, receipt.threadID == threadID, receipt.turnID == turnID,
              receipt.runtimeGeneration == runtimeGeneration else { throw Failure.invalidReceipt }
        return receipt
    }

    private struct Handles {
        let parent: Int32
        let directory: Int32
        let name: String
        let identity: stat
    }
    private func openDirectory(create: Bool) throws -> Handles? {
        // Do not compare Foundation's standardized spelling: /private/var may
        // become /var after creation. O_NOFOLLOW traversal owns the real path.
        guard directory.isFileURL, directory.baseURL == nil, directory.path.hasPrefix("/"),
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil,
              directory.path.utf8.count <= 4_096 else { throw Failure.unavailable }
        let components = directory.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= 64,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw Failure.unavailable }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.unavailable }
        do {
            for component in components.dropLast() {
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unavailable }
                close(parent); parent = next
            }
            let name = components.last!
            var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT {
                if !create { close(parent); return nil }
                if mkdirat(parent, name, 0o700) == 0 {
                    guard fsync(parent) == 0 else { throw Failure.unavailable }
                } else if errno != EEXIST { throw Failure.unavailable }
                descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw Failure.unavailable }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o700 else {
                close(descriptor); throw Failure.unavailable
            }
            return Handles(parent: parent, directory: descriptor, name: name, identity: metadata)
        } catch { close(parent); throw error }
    }
    private func requireDirectory(_ handles: Handles) throws {
        var held = stat(), named = stat()
        guard fstat(handles.directory, &held) == 0,
              fstatat(handles.parent, handles.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == handles.identity.st_dev, held.st_ino == handles.identity.st_ino,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              held.st_uid == geteuid(), named.st_uid == geteuid(),
              held.st_mode & 0o777 == 0o700, named.st_mode & 0o777 == 0o700 else { throw Failure.unavailable }
    }
    private func entryCount(_ descriptor: Int32) throws -> Int {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw Failure.unavailable }
        guard let stream = fdopendir(copy) else { close(copy); throw Failure.unavailable }
        defer { closedir(stream) }
        rewinddir(stream)
        var count = 0
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else { throw Failure.unavailable }
                return count
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= Self.maximumRecords else { throw Failure.recordLimit }
        }
    }
    private func encoded(_ receipt: EmbeddedBrowserCleanupReceipt) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(receipt)
    }
    private func filename(taskID: String, threadID: String, turnID: String, runtimeGeneration: UUID) throws -> String {
        guard [taskID, threadID, turnID].allSatisfy(CleanupReceiptCoding.validIdentity) else { throw Failure.invalidReceipt }
        let identity = try JSONEncoder().encode([taskID, threadID, turnID, runtimeGeneration.uuidString.lowercased()])
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    private func read(_ name: String, in handles: Handles) throws -> EmbeddedBrowserCleanupReceipt? {
        let descriptor = openat(handles.directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var before = stat(), named = stat()
        guard fstat(descriptor, &before) == 0,
              fstatat(handles.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(before, named), before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o777 == 0o400,
              (1...Self.maximumRecordBytes).contains(Int(before.st_size)) else { throw Failure.unavailable }
        let bytes = try readBytes(descriptor)
        guard let receipt = try? JSONDecoder().decode(EmbeddedBrowserCleanupReceipt.self, from: bytes) else {
            throw Failure.invalidReceipt
        }
        // Exact canonical bytes reject duplicate keys and alternate encodings.
        guard receipt.isValid, try encoded(receipt) == bytes else { throw Failure.invalidReceipt }
        var after = stat(), current = stat()
        guard bytes.count == before.st_size, fstat(descriptor, &after) == 0,
              fstatat(handles.directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(before, after), sameFile(after, current) else { throw Failure.unavailable }
        try requireDirectory(handles)
        return receipt
    }
    private func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func readBytes(_ descriptor: Int32) throws -> Data {
        var bytes = Data(count: Self.maximumRecordBytes + 1)
        let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw Failure.unavailable }
                if count == 0 { return offset }; offset += count
            }
            return offset
        }
        guard count <= Self.maximumRecordBytes else { throw Failure.recordLimit }
        bytes.count = count; return bytes
    }
    private func publish(_ bytes: Data, name: String, in handles: Handles) throws {
        let temporary = ".cleanup-" + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(handles.directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor); _ = unlinkat(handles.directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }; offset += count
            }
        }
        guard fchmod(descriptor, 0o400) == 0, fsync(descriptor) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0, try readBytes(descriptor) == bytes else { throw Failure.unavailable }
        try requireDirectory(handles)
        guard renameatx_np(handles.directory, temporary, handles.directory, name, UInt32(RENAME_EXCL)) == 0,
              fsync(handles.directory) == 0 else { throw Failure.unavailable }
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0,
              fstatat(handles.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(held, named), held.st_mode & S_IFMT == S_IFREG,
              held.st_uid == geteuid(), held.st_nlink == 1, held.st_mode & 0o777 == 0o400 else { throw Failure.unavailable }
        try requireDirectory(handles)
    }
}

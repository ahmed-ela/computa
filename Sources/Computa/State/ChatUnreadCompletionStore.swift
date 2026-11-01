import Darwin
import Foundation

/// App-owned read state only: no prompts, answers, provider details or historical
/// status inference. A read acknowledgement retains the last completion ID so a
/// repeated terminal event cannot turn a read chat blue again.
struct ChatUnreadCompletionStore: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let completionID: String
        var hasUnreadCompletion: Bool
    }
    private struct Envelope: Codable {
        let schemaVersion: Int
        let threads: [String: Record]
    }
    enum Failure: Error { case invalid, filesystem }
    static let maximumRecords = 10_000
    static let maximumBytes = 2 * 1_024 * 1_024
    let fileURL: URL

    static var applicationDefault: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(fileURL: root.appendingPathComponent("Computa/ChatReadState/completions-v1.json"))
    }

    static func identity(_ value: String?) -> String? {
        guard let value, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    func load() throws -> [String: Record] {
        guard fileURL.isFileURL else { throw Failure.invalid }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return [:] }
            throw Failure.filesystem
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Self.maximumBytes else { throw Failure.invalid }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Failure.filesystem }
            if count == 0 { break }
            guard bytes.count + count <= Self.maximumBytes else { throw Failure.invalid }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.schemaVersion == 1 else { throw Failure.invalid }
        try Self.validate(envelope.threads)
        return envelope.threads
    }

    func save(_ records: [String: Record]) throws {
        guard fileURL.isFileURL else { throw Failure.invalid }
        try Self.validate(records)
        // Refuse to replace an unreadable/corrupt existing store with an empty
        // reconstruction. Callers retain their unread indicator on failure.
        _ = try load()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: 1, threads: records))
        guard data.count <= Self.maximumBytes else { throw Failure.invalid }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.filesystem }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.filesystem }
        let temporary = ".completion-\(UUID().uuidString).tmp"
        let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure.filesystem }
        defer { close(output); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw Failure.invalid }
            var written = 0
            while written < bytes.count {
                let count = write(output, base.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.filesystem }
                written += count
            }
        }
        guard fsync(output) == 0,
              renameat(parent, temporary, parent, fileURL.lastPathComponent) == 0,
              fsync(parent) == 0 else { throw Failure.filesystem }
    }

    private static func validate(_ records: [String: Record]) throws {
        guard records.count <= maximumRecords, records.allSatisfy({ key, value in
            identity(key) == key && identity(value.completionID) == value.completionID
        }) else { throw Failure.invalid }
    }
}

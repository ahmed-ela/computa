import Foundation
import Darwin

/// Provider-reported billable counts. These are never the native context gauge.
struct APIModelCorrectionUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cachedInputTokens: Int
    let reasoningOutputTokens: Int

    func adding(_ other: Self) throws -> Self {
        func sum(_ a: Int, _ b: Int) throws -> Int {
            let result = a.addingReportingOverflow(b)
            guard !result.overflow else { throw APIModelResponseCodec.Failure.invalidResponse }
            return result.partialValue
        }
        return try .init(inputTokens: sum(inputTokens, other.inputTokens), outputTokens: sum(outputTokens, other.outputTokens),
                         totalTokens: sum(totalTokens, other.totalTokens), cachedInputTokens: sum(cachedInputTokens, other.cachedInputTokens),
                         reasoningOutputTokens: sum(reasoningOutputTokens, other.reasoningOutputTokens))
    }

    var responseUsage: [String: Any] {
        ["input_tokens": inputTokens, "output_tokens": outputTokens, "total_tokens": totalTokens,
         "input_tokens_details": ["cached_tokens": cachedInputTokens], "output_tokens_details": ["reasoning_tokens": reasoningOutputTokens]]
    }
}

/// Three exclusive, fsynced finite records form one correction journal.
/// The first known usage is durable before any corrective request can start.
/// No prompt, arguments, reasoning, tool schema, URL or credential is stored.
struct APIModelCorrectionAccounting: Sendable {
    enum Failure: Error { case unavailable }
    enum Outcome: String, Codable, Sendable {
        case responseValidated = "response_validated", argumentsRejected = "arguments_rejected"
        case transportFailed = "transport_failed", decodeFailed = "decode_failed"
        case cancelled, timedOut = "timed_out", budgetExhausted = "budget_exhausted"
    }
    struct Ticket: Sendable {
        let id: UUID
        let taskID: String
        let threadID: String
        let turnID: String
        let firstUsage: APIModelCorrectionUsage
    }
    struct Record: Codable, Sendable {
        let schemaVersion: Int
        let scope: String
        let correctionID: UUID
        let taskID: String
        let threadID: String
        let turnID: String
        let phase: String
        let secondRequestClaimed: Bool
        let firstUsage: APIModelCorrectionUsage
        let secondUsage: APIModelCorrectionUsage?
        let secondUsageUnknown: Bool
        let outcome: Outcome?
    }
    let directory: URL

    private func validUsage(_ usage: APIModelCorrectionUsage) -> Bool {
        (0...100_000_000).contains(usage.inputTokens) && (0...100_000_000).contains(usage.outputTokens)
            && usage.totalTokens == usage.inputTokens + usage.outputTokens
            && (0...usage.inputTokens).contains(usage.cachedInputTokens)
            && (0...usage.outputTokens).contains(usage.reasoningOutputTokens)
    }
    func begin(taskID: String, threadID: String, turnID: String, firstUsage: APIModelCorrectionUsage) throws -> Ticket {
        guard validUsage(firstUsage) else { throw Failure.unavailable }
        for id in [taskID, threadID, turnID] {
            guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.unavailable }
        }
        let ticket = Ticket(id: UUID(), taskID: taskID, threadID: threadID, turnID: turnID, firstUsage: firstUsage)
        try publish(record(ticket, phase: "first_received", claimed: false, usage: nil, unknown: false, outcome: nil), ticket: ticket)
        return ticket
    }
    func claimed(_ ticket: Ticket) throws {
        try requireFirst(ticket)
        try publish(record(ticket, phase: "second_claimed", claimed: true, usage: nil, unknown: true, outcome: nil), ticket: ticket)
    }
    func finish(_ ticket: Ticket, claimed: Bool, usage: APIModelCorrectionUsage?, outcome: Outcome) throws {
        try requireFirst(ticket)
        if claimed { try requireFirst(ticket, phase: "second_claimed", claimed: true) }
        guard usage.map(validUsage) ?? true else { throw Failure.unavailable }
        try publish(record(ticket, phase: "finished", claimed: claimed, usage: usage, unknown: claimed && usage == nil, outcome: outcome), ticket: ticket)
    }
    private func record(_ ticket: Ticket, phase: String, claimed: Bool, usage: APIModelCorrectionUsage?, unknown: Bool, outcome: Outcome?) -> Record {
        .init(schemaVersion: 1, scope: "provider_attempt_accounting_not_native_execution", correctionID: ticket.id, taskID: ticket.taskID, threadID: ticket.threadID, turnID: ticket.turnID,
              phase: phase, secondRequestClaimed: claimed, firstUsage: ticket.firstUsage,
              secondUsage: usage, secondUsageUnknown: unknown, outcome: outcome)
    }
    private struct Handles {
        let parent: Int32
        let directory: Int32
        let name: String
        let identity: stat
    }
    private func handles() throws -> Handles {
        // Foundation may rewrite /private/var to /var after creation. Physical
        // descriptor traversal, not that changing spelling, owns the directory.
        guard directory.isFileURL, directory.baseURL == nil, directory.path.hasPrefix("/"),
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil,
              directory.path.utf8.count <= 4_096 else { throw Failure.unavailable }
        let components = directory.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw Failure.unavailable }
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
        guard fstat(handles.directory, &held) == 0, fstatat(handles.parent, handles.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == handles.identity.st_dev, held.st_ino == handles.identity.st_ino,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              held.st_uid == geteuid(), held.st_mode & 0o777 == 0o700 else { throw Failure.unavailable }
    }
    private func encoded(_ value: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    private func requireFirst(_ ticket: Ticket, phase: String = "first_received", claimed: Bool = false) throws {
        let h = try handles(); defer { close(h.directory); close(h.parent) }
        try requireDirectory(h)
        let name = ticket.id.uuidString.lowercased() + "." + phase + ".json"
        let fd = openat(h.directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }; defer { close(fd) }
        var before = stat(), named = stat()
        guard fstat(fd, &before) == 0, fstatat(h.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == named.st_dev, before.st_ino == named.st_ino,
              before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o777 == 0o400, (1...2_048).contains(before.st_size) else { throw Failure.unavailable }
        var data = Data(count: 2_049)
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0, errno == EINTR { continue }; guard n >= 0 else { throw Failure.unavailable }
                if n == 0 { return offset }; offset += n
            }
            return offset
        }
        data.count = count
        let expected = try encoded(record(ticket, phase: phase, claimed: claimed, usage: nil, unknown: claimed, outcome: nil))
        var after = stat(), current = stat()
        guard data == expected, count == before.st_size, fstat(fd, &after) == 0,
              fstatat(h.directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, after.st_dev == current.st_dev, after.st_ino == current.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              after.st_mode == before.st_mode, after.st_nlink == 1 else { throw Failure.unavailable }
        try requireDirectory(h)
    }
    private func publish(_ value: Record, ticket: Ticket) throws {
        let bytes = try encoded(value)
        guard bytes.count <= 2_048 else { throw Failure.unavailable }
        let h = try handles(); defer { close(h.directory); close(h.parent) }
        try requireDirectory(h)
        let temporary = ".correction-" + UUID().uuidString.lowercased() + ".tmp"
        let name = ticket.id.uuidString.lowercased() + "." + value.phase + ".json"
        let descriptor = openat(h.directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor); _ = unlinkat(h.directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }; offset += count
            }
        }
        guard fchmod(descriptor, 0o400) == 0, fsync(descriptor) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else { throw Failure.unavailable }
        var readback = Data(count: bytes.count + 1)
        let readCount = try readback.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw Failure.unavailable }
                if count == 0 { return offset }; offset += count
            }
            return offset
        }
        readback.count = readCount
        guard readback == bytes else { throw Failure.unavailable }
        try requireDirectory(h)
        guard renameatx_np(h.directory, temporary, h.directory, name, UInt32(RENAME_EXCL)) == 0,
              fsync(h.directory) == 0 else { throw Failure.unavailable }
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, fstatat(h.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino, held.st_mode & S_IFMT == S_IFREG,
              held.st_nlink == 1, held.st_uid == geteuid(), held.st_mode & 0o777 == 0o400,
              held.st_size == bytes.count else { throw Failure.unavailable }
        try requireDirectory(h)
    }
}

/// Correction eligibility must not rely on Foundation's duplicate-key or
/// decimal-rounding behavior. This scanner grants no normal decode authority.
/// Argument strings are kept opaque; native schema validation remains exact.
private struct APICorrectionJSONScanner {
    enum Invalid: Error { case shape }
    let bytes: [UInt8]
    var index = 0
    var nodes = 0
    static let integerKeys = Set(["prompt_tokens", "completion_tokens", "total_tokens", "cached_tokens",
        "reasoning_tokens", "input_tokens", "output_tokens", "index", "created"].map { Data($0.utf8) })
    mutating func parse() throws {
        guard bytes.count <= APIProviderHTTPClient.maximumResponseBytes else { throw Invalid.shape }
        try value(depth: 0, key: nil); whitespace()
        guard index == bytes.count else { throw Invalid.shape }
    }
    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
    }
    mutating func string(decoded: Bool) throws -> Data {
        let start = index
        guard consume(34) else { throw Invalid.shape }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { throw Invalid.shape }; index += 1 }
            else if byte == 34 {
                guard decoded else { return Data() }
                let token = Data(bytes[start..<index])
                guard let text = try JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String else { throw Invalid.shape }
                return Data(text.utf8)
            }
        }
        throw Invalid.shape
    }
    mutating func value(depth: Int, key: Data?) throws {
        nodes += 1; whitespace()
        guard depth <= 64, nodes <= 16_384, index < bytes.count else { throw Invalid.shape }
        if consume(123) {
            var keys = Set<Data>(); whitespace()
            if consume(125) { return }
            repeat {
                whitespace(); let name = try string(decoded: true)
                guard keys.insert(name).inserted else { throw Invalid.shape }; whitespace()
                guard consume(58) else { throw Invalid.shape }
                try value(depth: depth + 1, key: name); whitespace()
                if consume(125) { return }
                guard consume(44) else { throw Invalid.shape }
            } while true
        }
        if consume(91) {
            whitespace(); if consume(93) { return }
            repeat {
                try value(depth: depth + 1, key: nil); whitespace()
                if consume(93) { return }; guard consume(44) else { throw Invalid.shape }
            } while true
        }
        if bytes[index] == 34 { _ = try string(decoded: false); return }
        for literal in [Array("true".utf8), Array("false".utf8), Array("null".utf8)] {
            if bytes[index...].starts(with: literal) { index += literal.count; return }
        }
        let start = index
        while index < bytes.count, [45, 43, 46, 69, 101].contains(bytes[index]) || (48...57).contains(bytes[index]) { index += 1 }
        guard start < index else { throw Invalid.shape }
        if let key, Self.integerKeys.contains(key) {
            let raw = bytes[start..<index]
            guard raw.count <= 16, raw.allSatisfy({ (48...57).contains($0) }) else { throw Invalid.shape }
        }
    }
}
enum APIModelCorrectionJSON {
    static func isUnambiguous(_ data: Data) -> Bool {
        do {
            guard data.count <= APIProviderHTTPClient.maximumResponseBytes else { return false }
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var scanner = APICorrectionJSONScanner(bytes: Array(data)); try scanner.parse(); return true
        }
        catch { return false }
    }
}

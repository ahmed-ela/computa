import Foundation
import Darwin

/// A permanent, per-native-turn budget for one website format correction.
/// Each exclusive record is durable before its caller can advance. No prompt,
/// reply, tool arguments, URL, or provider-reported usage enters this journal.
struct WebsiteModelFormatCorrectionStore: Sendable {
    enum Failure: Error { case unavailable }
    enum Outcome: String, Codable, Sendable {
        case responseValidated = "response_validated", invalidJSON = "invalid_json", failed, cancelled
        case timedOut = "timed_out", budgetExhausted = "budget_exhausted"
    }
    struct Ticket: Equatable, Sendable {
        let id: UUID
        let taskID: String
        let threadID: String
        let turnID: String
        let firstInferenceID: UUID
        let firstSessionToken: UUID
        let secondInferenceID: UUID
    }
    enum Phase: String, Codable, Hashable, Sendable { case claimed, firstClosed = "first_closed", finished }
    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let scope: String
        let correctionID: UUID
        let taskID: String
        let threadID: String
        let turnID: String
        let firstInferenceID: UUID
        let firstSessionToken: UUID
        let secondInferenceID: UUID
        let phase: Phase
        let usageUnknown: Bool
        let cleanupAttemptID: UUID?
        let secondStarted: Bool
        let secondSessionToken: UUID?
        let outcome: Outcome?

        var ticket: Ticket {
            .init(id: correctionID, taskID: taskID, threadID: threadID, turnID: turnID,
                  firstInferenceID: firstInferenceID, firstSessionToken: firstSessionToken,
                  secondInferenceID: secondInferenceID)
        }
        var isValid: Bool {
            guard schemaVersion == 1, scope == "website_format_correction_not_native_execution", usageUnknown,
                  [taskID, threadID, turnID].allSatisfy(WebsiteModelFormatCorrectionStore.validIdentity),
                  firstInferenceID != secondInferenceID else { return false }
            switch phase {
            case .claimed:
                return cleanupAttemptID == nil && !secondStarted && secondSessionToken == nil && outcome == nil
            case .firstClosed:
                return cleanupAttemptID != nil && !secondStarted && secondSessionToken == nil && outcome == nil
            case .finished:
                guard let outcome, secondStarted == (secondSessionToken != nil),
                      secondSessionToken != firstSessionToken else { return false }
                if secondStarted { return cleanupAttemptID != nil }
                return outcome != .responseValidated && outcome != .invalidJSON
            }
        }
    }
    static let maximumRecords = 4_096
    static let maximumRecordBytes = 2_048
    let directory: URL

    func claim(taskID: String, threadID: String, turnID: String, firstInferenceID: UUID,
               firstSessionToken: UUID, secondInferenceID: UUID) throws -> Ticket {
        guard [taskID, threadID, turnID].allSatisfy(Self.validIdentity),
              firstInferenceID != secondInferenceID else { throw Failure.unavailable }
        let ticket = Ticket(id: UUID(), taskID: taskID, threadID: threadID, turnID: turnID,
                            firstInferenceID: firstInferenceID, firstSessionToken: firstSessionToken,
                            secondInferenceID: secondInferenceID)
        return try withInventory { handles, inventory in
            guard inventory.groups[key(ticket)] == nil,
                  inventory.count + inventory.reserved + 3 <= Self.maximumRecords else { throw Failure.unavailable }
            try publish(record(ticket, phase: .claimed), in: handles)
            return ticket
        }
    }

    func recordClosed(_ ticket: Ticket, cleanupAttemptID: UUID) throws {
        try withInventory { handles, inventory in
            let group = try requireClaim(ticket, inventory: inventory)
            guard group[.firstClosed] == nil, group[.finished] == nil else { throw Failure.unavailable }
            try publish(record(ticket, phase: .firstClosed, cleanupAttemptID: cleanupAttemptID), in: handles)
        }
    }

    func finish(_ ticket: Ticket, secondInferenceID: UUID?, secondSessionToken: UUID?, outcome: Outcome) throws {
        guard (secondInferenceID == nil) == (secondSessionToken == nil),
              secondInferenceID == nil || secondInferenceID == ticket.secondInferenceID,
              secondSessionToken != ticket.firstSessionToken else { throw Failure.unavailable }
        try withInventory { handles, inventory in
            let group = try requireClaim(ticket, inventory: inventory)
            guard group[.finished] == nil else { throw Failure.unavailable }
            let started = secondInferenceID != nil
            let value = record(ticket, phase: .finished, cleanupAttemptID: group[.firstClosed]?.cleanupAttemptID,
                               secondStarted: started, secondSessionToken: secondSessionToken, outcome: outcome)
            guard value.isValid, !started || group[.firstClosed] != nil else { throw Failure.unavailable }
            try publish(value, in: handles)
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value
    }
    private func key(_ ticket: Ticket) -> String { ticket.threadID + "-" + ticket.turnID }
    private func filename(_ record: Record) -> String { key(record.ticket) + "." + record.phase.rawValue + ".json" }
    private func record(_ ticket: Ticket, phase: Phase, cleanupAttemptID: UUID? = nil,
                        secondStarted: Bool = false, secondSessionToken: UUID? = nil, outcome: Outcome? = nil) -> Record {
        .init(schemaVersion: 1, scope: "website_format_correction_not_native_execution", correctionID: ticket.id,
              taskID: ticket.taskID, threadID: ticket.threadID, turnID: ticket.turnID,
              firstInferenceID: ticket.firstInferenceID, firstSessionToken: ticket.firstSessionToken,
              secondInferenceID: ticket.secondInferenceID, phase: phase, usageUnknown: true,
              cleanupAttemptID: cleanupAttemptID, secondStarted: secondStarted,
              secondSessionToken: secondSessionToken, outcome: outcome)
    }
    private struct Inventory {
        let groups: [String: [Phase: Record]]
        let count: Int
        let reserved: Int
    }
    private func requireClaim(_ ticket: Ticket, inventory: Inventory) throws -> [Phase: Record] {
        guard let group = inventory.groups[key(ticket)], group[.claimed]?.ticket == ticket else { throw Failure.unavailable }
        return group
    }
    private func withInventory<T>(_ body: (Handles, Inventory) throws -> T) throws -> T {
        let handles = try openDirectory(); defer { close(handles.directory); close(handles.parent) }
        // Contending or unavailable journals disable correction instead of waiting.
        guard flock(handles.directory, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
        defer { _ = flock(handles.directory, LOCK_UN) }
        try requireDirectory(handles)
        return try body(handles, inventory(in: handles))
    }
    private func inventory(in handles: Handles) throws -> Inventory {
        let copy = dup(handles.directory)
        guard copy >= 0 else { throw Failure.unavailable }
        guard let stream = fdopendir(copy) else { close(copy); throw Failure.unavailable }
        defer { closedir(stream) }
        rewinddir(stream)
        var count = 0, groups: [String: [Phase: Record]] = [:]
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else { throw Failure.unavailable }; break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= Self.maximumRecords, name.utf8.count <= 96 else { throw Failure.unavailable }
            let value = try read(name, in: handles)
            guard filename(value) == name, groups[key(value.ticket)]?[value.phase] == nil else { throw Failure.unavailable }
            groups[key(value.ticket), default: [:]][value.phase] = value
        }
        var reserved = 0
        for group in groups.values {
            guard let claim = group[.claimed], group.values.allSatisfy({ $0.ticket == claim.ticket }) else { throw Failure.unavailable }
            if let finished = group[.finished] {
                guard finished.cleanupAttemptID == group[.firstClosed]?.cleanupAttemptID,
                      !finished.secondStarted || group[.firstClosed] != nil else { throw Failure.unavailable }
            } else {
                reserved += group[.firstClosed] == nil ? 2 : 1
            }
        }
        guard count + reserved <= Self.maximumRecords else { throw Failure.unavailable }
        try requireDirectory(handles)
        return .init(groups: groups, count: count, reserved: reserved)
    }

    private struct Handles {
        let parent: Int32
        let directory: Int32
        let name: String
        let identity: stat
    }
    private func openDirectory() throws -> Handles {
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
                if mkdirat(parent, name, 0o700) == 0 {
                    guard fsync(parent) == 0 else { throw Failure.unavailable }
                } else if errno != EEXIST { throw Failure.unavailable }
                descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw Failure.unavailable }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o7777 == 0o700 else {
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
              held.st_uid == geteuid(), named.st_uid == geteuid(),
              held.st_mode & 0o7777 == 0o700, named.st_mode & 0o7777 == 0o700 else { throw Failure.unavailable }
    }
    private func encoded(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
    private func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
            && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func readBytes(_ descriptor: Int32) throws -> Data {
        var data = Data(count: Self.maximumRecordBytes + 1)
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw Failure.unavailable }
                if count == 0 { return offset }; offset += count
            }
            return offset
        }
        guard count <= Self.maximumRecordBytes else { throw Failure.unavailable }
        data.count = count; return data
    }
    private func read(_ name: String, in handles: Handles) throws -> Record {
        let descriptor = openat(handles.directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }; defer { close(descriptor) }
        var before = stat(), named = stat()
        guard fstat(descriptor, &before) == 0, fstatat(handles.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(before, named), before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
              before.st_nlink == 1, before.st_mode & 0o7777 == 0o600,
              (1...Self.maximumRecordBytes).contains(Int(before.st_size)) else { throw Failure.unavailable }
        let bytes = try readBytes(descriptor)
        guard let record = try? JSONDecoder().decode(Record.self, from: bytes), record.isValid,
              try encoded(record) == bytes else { throw Failure.unavailable }
        // Canonical equality also rejects duplicate/unknown keys, explicit nulls
        // and alternative number/UUID encodings that JSONDecoder alone accepts.
        var after = stat(), current = stat()
        guard bytes.count == before.st_size, fstat(descriptor, &after) == 0,
              fstatat(handles.directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(before, after), sameFile(after, current) else { throw Failure.unavailable }
        try requireDirectory(handles)
        return record
    }
    private func publish(_ record: Record, in handles: Handles) throws {
        let bytes = try encoded(record)
        guard record.isValid, bytes.count <= Self.maximumRecordBytes else { throw Failure.unavailable }
        try requireDirectory(handles)
        // Publish directly with O_EXCL: even an interrupted partial write spends
        // this turn's budget. Never unlink a claim or rewrite a prior phase.
        let name = filename(record)
        let descriptor = openat(handles.directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }; defer { close(descriptor) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }; offset += count
            }
        }
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0, fsync(handles.directory) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0, try readBytes(descriptor) == bytes else { throw Failure.unavailable }
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, fstatat(handles.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(held, named), try read(name, in: handles) == record else { throw Failure.unavailable }
        try requireDirectory(handles)
    }
}

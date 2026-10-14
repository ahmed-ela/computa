import Darwin
import Foundation

/// Same-UID, manually armed scope checking, not proof that a human wrote the
/// file. Full Access can write it indirectly. No tool/wire operation exposes
/// this capability; it neither captures page data nor authorizes any request.
final class ChatGPTInspectorLease: @unchecked Sendable {
    private let lock = NSLock()
    private let taskID: UUID, threadID: UUID, turnID: UUID
    private let deadline: ContinuousClock.Instant
    private var current = true
    private var bound = false
    private var activated = false
    private var onRevocation: (@Sendable () -> Void)?

    private init(taskID: UUID, threadID: UUID, turnID: UUID, deadline: ContinuousClock.Instant) {
        self.taskID = taskID; self.threadID = threadID; self.turnID = turnID
        self.deadline = deadline
    }

    func matches(taskID: UUID, threadID: UUID, turnID: UUID) -> Bool {
        lock.withLock { current && ContinuousClock.now < deadline && self.taskID == taskID
            && self.threadID == threadID && self.turnID == turnID }
    }

    /// Native-only handoff. Copies share the same single-use and revocation state.
    final class Binding: @unchecked Sendable {
        private let lease: ChatGPTInspectorLease
        let deadline: ContinuousClock.Instant
        private let view: ObjectIdentifier, ownerToken: String, generation: UUID
        fileprivate init(lease: ChatGPTInspectorLease, view: ObjectIdentifier, ownerToken: String, generation: UUID) {
            self.lease = lease; deadline = lease.deadline
            self.view = view; self.ownerToken = ownerToken; self.generation = generation
        }
        func activate(view: ObjectIdentifier, ownerToken: String, generation: UUID,
                      onRevocation: @escaping @Sendable () -> Void, action: () -> Void) -> Bool {
            lease.lock.withLock {
                guard !Task.isCancelled, lease.current, !lease.activated, ContinuousClock.now < deadline,
                      self.view == view, self.ownerToken == ownerToken, self.generation == generation else { return false }
                lease.activated = true; lease.onRevocation = onRevocation
                action()
                return true
            }
        }
        func revoke() { lease.revoke() }
    }

    func bind(view: ObjectIdentifier, ownerToken: String, generation: UUID) -> Binding? {
        lock.withLock {
            guard !Task.isCancelled, current, !bound, ContinuousClock.now < deadline,
                  UUID(uuidString: ownerToken) != nil else { return nil }
            bound = true
            return Binding(lease: self, view: view, ownerToken: ownerToken, generation: generation)
        }
    }

    func revoke() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            current = false
            let callback = onRevocation; onRevocation = nil
            return callback
        }
        callback?()
    }

    /// No creation, repair or fallback. An absent/invalid arm cannot grant.
    /// A valid arm is consumed even if the later exact-view grant fails.
    static func consume(directory: URL?, taskID: UUID, threadID: UUID, turnID: UUID,
                        now: Date = Date()) -> ChatGPTInspectorLease? {
        let started = ContinuousClock.now
        guard !Task.isCancelled, let directory else { return nil }
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
              Set(value.keys) == ["taskID", "threadID", "provider", "expiresAt"],
              value["taskID"] == taskID.uuidString.lowercased(), value["threadID"] == threadID.uuidString.lowercased(),
              value["provider"] == "chatgpt", let text = value["expiresAt"], text.utf8.count == 24 else { return nil }
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
        return ChatGPTInspectorLease(taskID: taskID, threadID: threadID, turnID: turnID,
            deadline: originalDeadline)
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

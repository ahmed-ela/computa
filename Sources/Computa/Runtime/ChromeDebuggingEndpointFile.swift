import Darwin
import Foundation

enum ChromeDebuggingEndpointError: Error, Equatable, LocalizedError {
    case consentRequired
    case invalidDirectory
    case unavailable
    case accessDenied(operation: ChromeDebuggingEndpointOperation, code: Int32)
    case unsafeFile
    case invalidContents
    case changed

    var errorDescription: String? {
        switch self {
        case .consentRequired: "Connecting to your existing Chrome profile requires explicit permission."
        case .invalidDirectory: "The selected Chrome profile directory is not a local absolute directory."
        case .unavailable: "Chrome has not exposed a readable debugging endpoint. Enable it in Chrome after granting permission."
        case .accessDenied: "macOS denied Computa access to Chrome's connection file. Review System Settings > Privacy & Security > Files & Folders > LocalCodex (or Computa) > Google Chrome. This macOS permission covers Chrome's app-data directory; Computa reads only the connection file. Full Disk Access is not required. No browser connection was made."
        case .unsafeFile: "Chrome's debugging endpoint file has unsafe ownership, permissions or type."
        case .invalidContents: "Chrome's debugging endpoint file is malformed."
        case .changed: "Chrome's debugging endpoint changed. The old connection authority is no longer valid."
        }
    }
}

enum ChromeDebuggingEndpointOperation: String, Equatable, Sendable {
    case openDirectory, openFile, readFile
}

/// Host-owned and per-connection. The model cannot grant or persist this object.
/// A default instance authorizes nothing. Revocation is synchronous, including
/// when a mutation is queued on another actor.
final class ChromeDebuggingConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var approved: Bool
    private let temporaryTabsApproved: Bool

    init(approvedByUser: Bool = false, allowsTemporaryTabs: Bool = false) {
        approved = approvedByUser
        temporaryTabsApproved = approvedByUser && allowsTemporaryTabs
    }
    var allowsTemporaryTabs: Bool { lock.withLock { approved && temporaryTabsApproved } }
    func revoke() { lock.withLock { approved = false } }
    func check() throws { try withApproval {} }

    /// Linearizes revocation with the actual synchronous submission, not only
    /// a check made before it. Never await or reenter this consent in `operation`.
    func withApproval<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard approved else { throw ChromeDebuggingEndpointError.consentRequired }
            return try operation()
        }
    }
}

/// This is a file-generation fence, not proof of the listening process. Combine
/// it with ChromeDebuggingProcessBinding before creating a WebSocket and at
/// enqueue. No profile, cookie or tab content is read here.
struct ChromeDebuggingEndpointFile: Sendable {
    let endpoint: URL
    private let directory: URL
    private let consent: ChromeDebuggingConsent
    private let identity: Identity
    private let directoryIdentity: DirectoryIdentity
    private let bytes: Data

    private struct DirectoryIdentity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let owner: UInt32
        let mode: UInt16

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            owner = value.st_uid
            mode = value.st_mode
        }
    }

    private struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let owner: UInt32
        let size: Int64
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            owner = value.st_uid
            size = value.st_size
            mode = value.st_mode
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    static func read(
        explicitlyApprovedUserDataDirectory directory: URL,
        consent: ChromeDebuggingConsent
    ) throws -> Self {
        try consent.withApproval {
            let read = try readBounded(directory: directory)
            let endpoint = try parse(read.bytes)
            return Self(endpoint: endpoint, directory: directory, consent: consent, identity: read.identity,
                        directoryIdentity: read.directoryIdentity, bytes: read.bytes)
        }
    }

    func validate() throws {
        try consent.withApproval { try validateIdentity() }
    }

    /// For the connection authority, which holds this same consent across both
    /// file/process validation and wire enqueue. Does not grant permission.
    func validateIdentity() throws {
        let current = try Self.readBounded(directory: directory)
        guard current.identity == identity, current.directoryIdentity == directoryIdentity,
              current.bytes == bytes else { throw ChromeDebuggingEndpointError.changed }
    }

    static func parse(_ bytes: Data) throws -> URL {
        guard !bytes.isEmpty, bytes.count <= 1_024,
              let text = String(data: bytes, encoding: .utf8) else { throw ChromeDebuggingEndpointError.invalidContents }
        // Chrome writes a decimal port and exact browser path. One terminal LF
        // is allowed; blank lines, CRLF, extra records and trimmed tokens are not.
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 2, !lines[0].isEmpty,
              lines[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(lines[0]), port > 0,
              lines[0] == String(port),
              let endpoint = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") else {
            throw ChromeDebuggingEndpointError.invalidContents
        }
        do { try URLSessionBrowserCDPWire.validate(endpoint: endpoint) }
        catch { throw ChromeDebuggingEndpointError.invalidContents }
        return endpoint
    }

    private static func readBounded(directory: URL) throws -> (identity: Identity, directoryIdentity: DirectoryIdentity, bytes: Data) {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.query == nil, directory.fragment == nil,
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.standardizedFileURL.path == directory.path else { throw ChromeDebuggingEndpointError.invalidDirectory }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw accessError(errno, operation: .openDirectory) }
        defer { close(directoryFD) }
        var directoryStat = stat()
        guard fstat(directoryFD, &directoryStat) == 0,
              directoryStat.st_uid == geteuid(), (directoryStat.st_mode & 0o022) == 0 else {
            throw ChromeDebuggingEndpointError.unsafeFile
        }
        let fileFD = openat(directoryFD, "DevToolsActivePort", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fileFD >= 0 else { throw accessError(errno, operation: .openFile) }
        defer { close(fileFD) }
        var before = stat()
        guard fstat(fileFD, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1,
              before.st_uid == geteuid(), (before.st_mode & 0o022) == 0,
              before.st_size > 0, before.st_size <= 1_024 else { throw ChromeDebuggingEndpointError.unsafeFile }
        var storage = [UInt8](repeating: 0, count: 1_025)
        var total = 0
        while total < storage.count {
            let count = storage.withUnsafeMutableBytes { buffer in
                Darwin.read(fileFD, buffer.baseAddress!.advanced(by: total), buffer.count - total)
            }
            if count == -1 && errno == EINTR { continue }
            guard count >= 0 else { throw accessError(errno, operation: .readFile) }
            if count == 0 { break }
            total += count
        }
        var after = stat(), pathStat = stat(), currentDirectory = stat()
        guard fstat(fileFD, &after) == 0,
              fstatat(directoryFD, "DevToolsActivePort", &pathStat, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(directory.path, &currentDirectory) == 0,
              DirectoryIdentity(directoryStat) == DirectoryIdentity(currentDirectory),
              Identity(before) == Identity(after), Identity(after) == Identity(pathStat),
              total == before.st_size else { throw ChromeDebuggingEndpointError.changed }
        return (Identity(after), DirectoryIdentity(directoryStat), Data(storage.prefix(total)))
    }

    static func accessError(_ code: Int32, operation: ChromeDebuggingEndpointOperation) -> ChromeDebuggingEndpointError {
        if code == EACCES || code == EPERM { return .accessDenied(operation: operation, code: code) }
        return .unavailable
    }
}

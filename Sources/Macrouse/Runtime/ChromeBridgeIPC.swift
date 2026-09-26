import Darwin
import Foundation
import Security

/// Shared with the signed native host. No TCP listener, browser profile read,
/// shell execution, or arbitrary endpoint supplied by a web page.
enum ChromeBridgeIPC {
    static let maximumFrame = 512 * 1_024
    static let appIdentifier = "com.ahmedelamin.LocalCodex"
    static let hostIdentifier = "com.ahmedelamin.LocalCodex.ChromeBridgeHost"
    static let teamIdentifier = "MSMG8CJLB3"
    static let hostName = "com.macndash.chrome_bridge"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalCodex/BrowserBridge", isDirectory: true)
    }
    static var socketPath: String { directory.appendingPathComponent("bridge.sock").path }

    static func prepareDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.identity }
    }

    static func address(path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard !path.isEmpty, !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw Failure.configuration }
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { target in target.copyBytes(from: bytes) }
        return value
    }

    static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        do {
            configure(fd)
            var addr = try address(path: socketPath)
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw Failure.unavailable }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    static func peerPID(_ fd: Int32) throws -> Int32 {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Failure.identity }
        var pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { throw Failure.identity }
        return pid
    }

    static func validateCode(pid: Int32, identifier: String, team: String = teamIdentifier) throws {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else {
            throw Failure.identity
        }
        var requirement: SecRequirement?
        let rule = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw Failure.identity }
    }

    static func parentPID(_ pid: Int32) throws -> Int32 {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid(), info.pbi_ppid > 0 else { throw Failure.identity }
        return Int32(info.pbi_ppid)
    }

    static func verifiedChromeParent(of hostPID: Int32) throws -> Int32 {
        let parent = try parentPID(hostPID)
        try validateCode(pid: parent, identifier: "com.google.Chrome", team: "EQHXZ8M8AV")
        return parent
    }

    static func readFrame(_ fd: Int32) throws -> Data? {
        guard let header = try readExactly(fd, count: 4, allowEOF: true) else { return nil }
        let count = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard count > 0, count <= maximumFrame else { throw Failure.invalidFrame }
        return try readExactly(fd, count: Int(count), allowEOF: false)
    }

    static func writeFrame(_ fd: Int32, data: Data) throws {
        guard !data.isEmpty, data.count <= maximumFrame else { throw Failure.invalidFrame }
        var length = UInt32(data.count).littleEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(fd, data: header + data)
    }

    private static func readExactly(_ fd: Int32, count: Int, allowEOF: Bool) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { bytes in Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset) }
            if n == 0, offset == 0, allowEOF { return nil }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw Failure.closed }
            offset += n
        }
        return data
    }

    private static func writeAll(_ fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { bytes in Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw Failure.closed }
            offset += n
        }
    }

    enum Failure: Error, LocalizedError {
        case unavailable, identity, configuration, invalidFrame, closed, deadline, rejected
        var errorDescription: String? {
            switch self {
            case .unavailable: "The Macrouse browser bridge is not available."
            case .identity: "The browser bridge identity could not be verified. No access was granted."
            case .configuration: "The browser bridge configuration is invalid."
            case .invalidFrame: "The browser bridge returned an invalid or oversized message."
            case .closed: "The browser bridge disconnected. The operation was not replayed."
            case .deadline: "The browser bridge request timed out. The operation was not replayed."
            case .rejected: "The browser extension rejected this operation."
            }
        }
    }
}

/// Exactly one read loop owns an fd. close() shuts it down to unblock that loop;
/// deinit closes it only after both read/write users have released the object.
final class ChromeBridgeSocket: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var closed = false
    init(fd: Int32) { self.fd = fd; ChromeBridgeIPC.configure(fd) }
    func send(_ data: Data) throws {
        try writeLock.withLock {
            guard !lock.withLock({ closed }) else { throw ChromeBridgeIPC.Failure.closed }
            try ChromeBridgeIPC.writeFrame(fd, data: data)
        }
    }
    func check() throws {
        guard !lock.withLock({ closed }) else { throw ChromeBridgeIPC.Failure.closed }
    }
    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
    }
    deinit { Darwin.close(fd) }
}

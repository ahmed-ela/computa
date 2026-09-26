import Darwin
import Foundation

public enum ChromeDebuggingLoopbackAddress: String, Equatable, Sendable {
    case ipv4 = "127.0.0.1"
    case ipv6 = "::1"
}

public enum ChromeDebuggingProcessBindingError: Error, Equatable, Sendable, LocalizedError {
    case invalidSelection
    case processUnavailable
    case processChanged
    case unverifiedOrdinaryProfile
    case descriptorLimit
    case listenerUnavailable
    case listenerAmbiguous
    case listenerChanged
    case nonLoopbackListener

    public var errorDescription: String? {
        switch self {
        case .invalidSelection: "The selected Chrome process or debugging endpoint is invalid."
        case .processUnavailable: "The selected Chrome process could not be inspected."
        case .processChanged: "The selected Chrome process identity changed. Reconnect explicitly."
        case .unverifiedOrdinaryProfile: "The selected Chrome process is not a verified ordinary profile."
        case .descriptorLimit: "Chrome's bounded listener inventory could not be verified."
        case .listenerUnavailable: "The selected Chrome process does not expose the requested loopback listener."
        case .listenerAmbiguous: "The selected Chrome listener is ambiguous."
        case .listenerChanged: "Chrome's debugging listener changed. Reconnect explicitly."
        case .nonLoopbackListener: "Chrome's debugging listener is not bound exclusively to loopback."
        }
    }
}

public struct ChromeDebuggingProcessIdentity: Equatable, Sendable {
    public let processIdentifier: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let userIdentifier: UInt32
    public let realUserIdentifier: UInt32
    public let executablePath: String
}

public struct ChromeDebuggingListenerIdentity: Equatable, Sendable {
    public let fileDescriptor: Int32
    public let generation: UInt64
    public let address: ChromeDebuggingLoopbackAddress
    public let port: UInt16
}

/// Read-only attribution of a caller-selected, already-running ordinary Chrome
/// process and one exact TCP listener. This neither discovers a profile nor
/// connects, launches, activates, or grants permission to the browser.
///
/// The caller obtains `expectedExecutableURL` from its independently selected
/// Chrome bundle. An exact path match is not code-signature authentication.
/// Kernel reads are snapshots, not an atomic peer credential for a WebSocket:
/// validate around connection establishment and immediately before enqueueing.
/// A changed process/listener must never trigger transparent reconnection.
public struct ChromeDebuggingProcessBinding: Sendable {
    public let process: ChromeDebuggingProcessIdentity
    public let listener: ChromeDebuggingListenerIdentity
    private let syscalls: any ChromeDebuggingProcessSyscalls

    public static func bind(
        processIdentifier: Int32,
        expectedExecutableURL: URL,
        port: UInt16,
        address: ChromeDebuggingLoopbackAddress = .ipv4
    ) throws -> Self {
        try bind(processIdentifier: processIdentifier, expectedExecutableURL: expectedExecutableURL,
                 port: port, address: address, syscalls: SystemChromeDebuggingProcessSyscalls())
    }

    static func bind(
        processIdentifier: Int32,
        expectedExecutableURL: URL,
        port: UInt16,
        address: ChromeDebuggingLoopbackAddress = .ipv4,
        syscalls: any ChromeDebuggingProcessSyscalls
    ) throws -> Self {
        guard processIdentifier > 0, port > 0, expectedExecutableURL.isFileURL,
              expectedExecutableURL.path.hasPrefix("/"),
              expectedExecutableURL.lastPathComponent == "Google Chrome" else {
            throw ChromeDebuggingProcessBindingError.invalidSelection
        }
        let expectedPath = expectedExecutableURL.standardizedFileURL.path
        let first = try readProcess(processIdentifier, expectedPath: expectedPath, syscalls: syscalls)
        let descriptors = try readDescriptors(processIdentifier, syscalls: syscalls)
        var matches = [ChromeDebuggingListenerIdentity]()
        for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            // Unrelated sockets may close after LISTFDS. Only an explicit EBADF
            // is skippable during discovery; partial reads and access failures
            // cannot prove that the descriptor merely disappeared.
            guard let socket = try readSocket(processIdentifier, descriptor: descriptor.proc_fd,
                                              allowDisappeared: true, syscalls: syscalls) else { continue }
            guard let candidate = try listeningSocket(socket, descriptor: descriptor.proc_fd, port: port) else { continue }
            if candidate.address == address { matches.append(candidate) }
        }
        guard !matches.isEmpty else { throw ChromeDebuggingProcessBindingError.listenerUnavailable }
        guard matches.count == 1 else { throw ChromeDebuggingProcessBindingError.listenerAmbiguous }
        let binding = Self(process: first, listener: matches[0], syscalls: syscalls)
        // Re-read the captured fd and bracket it with process identity reads.
        // Initial descriptor inventory can race unrelated Chrome socket churn.
        try binding.validate()
        return binding
    }

    /// Synchronous and non-reentrant: suitable for a mutation enqueue boundary.
    /// Uses only the retained descriptor; it never scans, substitutes, or retries.
    public func validate() throws {
        let before = try Self.readProcess(process.processIdentifier, expectedPath: process.executablePath, syscalls: syscalls)
        guard before == process else { throw ChromeDebuggingProcessBindingError.processChanged }
        guard let socket = try Self.readSocket(process.processIdentifier, descriptor: listener.fileDescriptor, syscalls: syscalls),
              let current = try Self.listeningSocket(socket, descriptor: listener.fileDescriptor, port: listener.port),
              current == listener else { throw ChromeDebuggingProcessBindingError.listenerChanged }
        let after = try Self.readProcess(process.processIdentifier, expectedPath: process.executablePath, syscalls: syscalls)
        guard after == process else { throw ChromeDebuggingProcessBindingError.processChanged }
    }

    private static func readProcess(
        _ pid: Int32, expectedPath: String, syscalls: any ChromeDebuggingProcessSyscalls
    ) throws -> ChromeDebuggingProcessIdentity {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let count = withUnsafeMutablePointer(to: &info) {
            syscalls.processInfo(pid: pid, flavor: Int32(PROC_PIDTBSDINFO), buffer: $0, byteCount: Int32(size))
        }
        guard count == size, info.pbi_pid == UInt32(pid),
              info.pbi_status == UInt32(SRUN) || info.pbi_status == UInt32(SSLEEP),
              info.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0,
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000,
              info.pbi_uid == syscalls.effectiveUserIdentifier(), info.pbi_ruid == info.pbi_uid else {
            throw ChromeDebuggingProcessBindingError.processUnavailable
        }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let pathCount = bytes.withUnsafeMutableBytes {
            syscalls.processPath(pid: pid, buffer: $0.baseAddress!, byteCount: UInt32($0.count))
        }
        guard pathCount > 0, pathCount < bytes.count,
              let terminator = bytes.firstIndex(of: 0), terminator > 0, terminator <= Int(pathCount),
              let path = String(bytes: bytes[..<terminator], encoding: .utf8) else {
            throw ChromeDebuggingProcessBindingError.processUnavailable
        }
        guard path == expectedPath else { throw ChromeDebuggingProcessBindingError.processChanged }
        let arguments = syscalls.processArguments(pid: pid)
        guard (try? ExistingChromeSelection.processIdentifier(in: [
            ExistingChromeCandidate(processIdentifier: pid, arguments: arguments),
        ])) == pid else { throw ChromeDebuggingProcessBindingError.unverifiedOrdinaryProfile }
        return ChromeDebuggingProcessIdentity(
            processIdentifier: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
            userIdentifier: info.pbi_uid, realUserIdentifier: info.pbi_ruid, executablePath: path
        )
    }

    /// Fixed allocation; a full buffer is potentially truncated and is refused.
    /// No allocation is sized from a process's descriptor count or syscall output.
    private static func readDescriptors(_ pid: Int32, syscalls: any ChromeDebuggingProcessSyscalls) throws -> [proc_fdinfo] {
        let limit = 16_384
        let stride = MemoryLayout<proc_fdinfo>.stride
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: limit)
        let count = entries.withUnsafeMutableBytes {
            syscalls.processInfo(pid: pid, flavor: Int32(PROC_PIDLISTFDS), buffer: $0.baseAddress!, byteCount: Int32($0.count))
        }
        guard count >= 0, count < limit * stride, Int(count) % stride == 0 else {
            throw ChromeDebuggingProcessBindingError.descriptorLimit
        }
        let result = Array(entries.prefix(Int(count) / stride))
        guard result.allSatisfy({ $0.proc_fd >= 0 }), Set(result.map(\.proc_fd)).count == result.count else {
            throw ChromeDebuggingProcessBindingError.descriptorLimit
        }
        return result
    }

    private static func readSocket(
        _ pid: Int32, descriptor: Int32, allowDisappeared: Bool = false, syscalls: any ChromeDebuggingProcessSyscalls
    ) throws -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = MemoryLayout<socket_fdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) {
            syscalls.fileDescriptorInfo(pid: pid, descriptor: descriptor, buffer: $0, byteCount: Int32(size))
        }
        guard result.byteCount == size else {
            if allowDisappeared, result.byteCount <= 0, result.errorNumber == EBADF { return nil }
            throw ChromeDebuggingProcessBindingError.listenerUnavailable
        }
        return info
    }

    private static func listeningSocket(
        _ socket: socket_fdinfo, descriptor: Int32, port: UInt16
    ) throws -> ChromeDebuggingListenerIdentity? {
        let info = socket.psi
        guard info.soi_kind == SOCKINFO_TCP, info.soi_type == SOCK_STREAM,
              info.soi_protocol == IPPROTO_TCP else { return nil }
        let tcp = info.soi_proto.pri_tcp
        let internet = tcp.tcpsi_ini
        guard tcp.tcpsi_state == TSI_S_LISTEN,
              UInt16(bigEndian: UInt16(truncatingIfNeeded: internet.insi_lport)) == port else { return nil }
        let address: ChromeDebuggingLoopbackAddress
        if info.soi_family == AF_INET, internet.insi_vflag == INI_IPV4 {
            var value = internet.insi_laddr.ina_46.i46a_addr4.s_addr
            let bytes = withUnsafeBytes(of: &value) { Array($0) }
            guard bytes == [127, 0, 0, 1] else { throw ChromeDebuggingProcessBindingError.nonLoopbackListener }
            address = .ipv4
        } else if info.soi_family == AF_INET6, internet.insi_vflag == INI_IPV6 {
            var value = internet.insi_laddr.ina_6
            let bytes = withUnsafeBytes(of: &value) { Array($0) }
            guard bytes == Array(repeating: UInt8(0), count: 15) + [1] else {
                throw ChromeDebuggingProcessBindingError.nonLoopbackListener
            }
            address = .ipv6
        } else {
            throw ChromeDebuggingProcessBindingError.nonLoopbackListener
        }
        guard internet.insi_gencnt > 0 else { throw ChromeDebuggingProcessBindingError.listenerUnavailable }
        return ChromeDebuggingListenerIdentity(fileDescriptor: descriptor, generation: internet.insi_gencnt, address: address, port: port)
    }
}

/// Injected synchronous syscall boundary. No pointer escapes the call; no
/// callbacks into permit/connection locks, actor hops, shells, or profile IO.
protocol ChromeDebuggingProcessSyscalls: Sendable {
    func effectiveUserIdentifier() -> UInt32
    func processInfo(pid: Int32, flavor: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int32) -> Int32
    func fileDescriptorInfo(pid: Int32, descriptor: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int32) -> (byteCount: Int32, errorNumber: Int32)
    func processPath(pid: Int32, buffer: UnsafeMutableRawPointer, byteCount: UInt32) -> Int32
    func processArguments(pid: Int32) -> [String]?
}

struct SystemChromeDebuggingProcessSyscalls: ChromeDebuggingProcessSyscalls {
    func effectiveUserIdentifier() -> UInt32 { geteuid() }
    func processInfo(pid: Int32, flavor: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int32) -> Int32 {
        proc_pidinfo(pid, flavor, 0, buffer, byteCount)
    }
    func fileDescriptorInfo(pid: Int32, descriptor: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int32) -> (byteCount: Int32, errorNumber: Int32) {
        errno = 0
        let count = proc_pidfdinfo(pid, descriptor, Int32(PROC_PIDFDSOCKETINFO), buffer, byteCount)
        let errorNumber = count <= 0 ? errno : 0
        return (count, errorNumber)
    }
    func processPath(pid: Int32, buffer: UnsafeMutableRawPointer, byteCount: UInt32) -> Int32 {
        proc_pidpath(pid, buffer, byteCount)
    }
    func processArguments(pid: Int32) -> [String]? { ChromeProcessArguments.read(processIdentifier: pid) }
}

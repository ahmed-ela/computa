import Darwin
import Foundation
import XCTest
@testable import AutomationCore

final class ChromeDebuggingProcessBindingTests: XCTestCase {
    /// Real public libproc layout and listener decoding against this XCTest
    /// process only. Path/argv policy inputs are deliberately adapted below;
    /// this is not evidence of real Chrome attribution or profile permission.
    func testNativeLibprocDecodesAnOwnedIPv4LoopbackListener() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var needsClose = true
        defer { if needsClose { Darwin.close(descriptor) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        guard named == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let port = UInt16(bigEndian: address.sin_port)
        XCTAssertGreaterThan(port, 0)

        let syscalls = SystemChromeDebuggingProcessSyscalls()
        let pid = getpid()
        var process = proc_bsdinfo()
        let processCount = withUnsafeMutablePointer(to: &process) {
            syscalls.processInfo(pid: pid, flavor: Int32(PROC_PIDTBSDINFO), buffer: $0,
                                 byteCount: Int32(MemoryLayout<proc_bsdinfo>.stride))
        }
        XCTAssertEqual(processCount, Int32(MemoryLayout<proc_bsdinfo>.stride))
        XCTAssertEqual(process.pbi_pid, UInt32(pid))
        XCTAssertEqual(process.pbi_uid, geteuid())
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let pathCount = bytes.withUnsafeMutableBytes {
            syscalls.processPath(pid: pid, buffer: $0.baseAddress!, byteCount: UInt32($0.count))
        }
        XCTAssertGreaterThan(pathCount, 0)
        XCTAssertLessThan(pathCount, Int32(bytes.count))
        let nativePath = try XCTUnwrap(String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8))
        XCTAssertTrue(nativePath.hasPrefix("/"))
        XCTAssertFalse(nativePath.isEmpty)

        let binding = try ChromeDebuggingProcessBinding.bind(
            processIdentifier: pid, expectedExecutableURL: URL(fileURLWithPath: DebuggingProcessProbe.path),
            port: port, syscalls: OwnedNativeLoopbackProcessProbe(processIdentifier: pid, expectedNativePath: nativePath)
        )
        XCTAssertEqual(binding.process.processIdentifier, pid)
        XCTAssertEqual(binding.process.startSeconds, process.pbi_start_tvsec)
        XCTAssertEqual(binding.process.startMicroseconds, process.pbi_start_tvusec)
        XCTAssertEqual(binding.listener.fileDescriptor, descriptor)
        XCTAssertEqual(binding.listener.address, .ipv4)
        XCTAssertEqual(binding.listener.port, port)
        XCTAssertGreaterThan(binding.listener.generation, 0)
        try binding.validate()
        XCTAssertEqual(Darwin.close(descriptor), 0)
        needsClose = false
        assertFailure(.listenerUnavailable) { try binding.validate() }
    }

    func testCapturesExactOrdinaryChromeAndIPv4Listener() throws {
        let probe = DebuggingProcessProbe()
        let binding = try bind(probe)
        XCTAssertEqual(binding.process.processIdentifier, 42)
        XCTAssertEqual(binding.process.startSeconds, 1_800_000_000)
        XCTAssertEqual(binding.process.startMicroseconds, 321)
        XCTAssertEqual(binding.process.userIdentifier, 501)
        XCTAssertEqual(binding.process.realUserIdentifier, 501)
        XCTAssertEqual(binding.process.executablePath, DebuggingProcessProbe.path)
        XCTAssertEqual(binding.listener.fileDescriptor, 17)
        XCTAssertEqual(binding.listener.generation, 9_876)
        XCTAssertEqual(binding.listener.address, .ipv4)
        XCTAssertEqual(binding.listener.port, 9_222)
        try binding.validate()
    }

    func testCapturesExactIPv6ListenerWithoutTreatingIPv4AsIPv6() throws {
        let probe = DebuggingProcessProbe()
        probe.edit { $0.sockets[17] = DebuggingProcessProbe.socket(address: .ipv6) }
        let binding = try bind(probe, address: .ipv6)
        XCTAssertEqual(binding.listener.address, .ipv6)
        try binding.validate()
        assertFailure(.listenerUnavailable) { try bind(probe, address: .ipv4) }
    }

    func testHotValidationDoesNotEnumerateOrSubstituteDescriptors() throws {
        let probe = DebuggingProcessProbe()
        let binding = try bind(probe)
        probe.edit { $0.calls = []; $0.descriptors = [DebuggingProcessProbe.descriptor(99)] }
        try binding.validate()
        XCTAssertEqual(probe.snapshot().calls.filter { $0 == "fds" }.count, 0)
        XCTAssertEqual(probe.snapshot().calls.filter { $0 == "socket:17" }.count, 1)
        XCTAssertFalse(probe.snapshot().calls.contains("socket:99"))
    }

    func testRejectsInvalidSelectionBeforeSyscalls() {
        let probe = DebuggingProcessProbe()
        for pid: Int32 in [0, -1] {
            assertFailure(.invalidSelection) { try bind(probe, pid: pid) }
        }
        assertFailure(.invalidSelection) { try bind(probe, port: 0) }
        for url in [URL(string: "https://example.invalid/Google%20Chrome")!, URL(fileURLWithPath: "/tmp/Other Browser")] {
            assertFailure(.invalidSelection) {
                try ChromeDebuggingProcessBinding.bind(processIdentifier: 42, expectedExecutableURL: url, port: 9_222, syscalls: probe)
            }
        }
        XCTAssertTrue(probe.snapshot().calls.isEmpty)
    }

    func testRejectsUnrelatedExecutablePath() {
        let probe = DebuggingProcessProbe()
        probe.edit { $0.path = "/tmp/Google Chrome" }
        assertFailure(.processChanged) { try bind(probe) }
        XCTAssertFalse(probe.snapshot().calls.contains("fds"))
    }

    func testRejectsUnknownOrIsolatedArgumentsWithoutRetainingDetails() {
        let cases: [[String]?] = [nil, [], ["chrome", "--user-data-dir", "/private/synthetic"],
                                 ["chrome", "--user-data-dir=/private/synthetic"],
                                 ["chrome", "--remote-debugging-port=9222"], ["chrome", "--remote-debugging-pipe"]]
        for arguments in cases {
            let probe = DebuggingProcessProbe()
            probe.edit { $0.arguments = arguments }
            assertFailure(.unverifiedOrdinaryProfile) { try bind(probe) }
            XCTAssertFalse(probe.snapshot().calls.contains("fds"))
        }
        XCTAssertFalse(ChromeDebuggingProcessBindingError.unverifiedOrdinaryProfile.localizedDescription.contains("synthetic"))
    }

    func testRejectsWrongPIDUIDRealUIDAndInvalidStartStamp() {
        let edits: [(inout proc_bsdinfo) -> Void] = [
            { $0.pbi_pid = 43 }, { $0.pbi_uid = 502 }, { $0.pbi_ruid = 502 },
            { $0.pbi_start_tvsec = 0 }, { $0.pbi_start_tvusec = 1_000_000 },
        ]
        for edit in edits {
            let probe = DebuggingProcessProbe()
            probe.edit { edit(&$0.process) }
            assertFailure(.processUnavailable) { try bind(probe) }
        }
    }

    func testRejectsExitingStoppedAndZombieProcess() {
        for status: UInt32 in [0, UInt32(SIDL), UInt32(SSTOP), UInt32(SZOMB)] {
            let probe = DebuggingProcessProbe()
            probe.edit { $0.process.pbi_status = status }
            assertFailure(.processUnavailable) { try bind(probe) }
        }
        let probe = DebuggingProcessProbe()
        probe.edit { $0.process.pbi_flags |= UInt32(PROC_FLAG_INEXIT) }
        assertFailure(.processUnavailable) { try bind(probe) }
    }

    func testOrdinarySleepRunTransitionIsNotIdentityChange() throws {
        let probe = DebuggingProcessProbe()
        let binding = try bind(probe)
        probe.edit { $0.process.pbi_status = UInt32(SSLEEP) }
        try binding.validate()
    }

    func testRefusesShortFailedOrOversizedBSDResults() {
        for count: Int32 in [-1, 0, 1, Int32(MemoryLayout<proc_bsdinfo>.stride - 1), Int32(MemoryLayout<proc_bsdinfo>.stride + 1)] {
            let probe = DebuggingProcessProbe()
            probe.edit { $0.processReturnCount = count }
            assertFailure(.processUnavailable) { try bind(probe) }
        }
    }

    func testRefusesFailedTruncatedAndInvalidUTF8Path() {
        for count: Int32 in [-1, 0, 4_096, 4_097, 1] {
            let probe = DebuggingProcessProbe()
            probe.edit { $0.pathReturnCount = count }
            assertFailure(.processUnavailable) { try bind(probe) }
        }
        let probe = DebuggingProcessProbe()
        probe.edit { $0.pathBytes = [255, 0] }
        assertFailure(.processUnavailable) { try bind(probe) }
    }

    func testRejectsMalformedFullOrFailedDescriptorInventory() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        for count: Int32 in [-1, 1, Int32(stride - 1), Int32(16_384 * stride), Int32(16_384 * stride + stride)] {
            let probe = DebuggingProcessProbe()
            probe.edit { $0.descriptorReturnCount = count }
            assertFailure(.descriptorLimit) { try bind(probe) }
        }
        let duplicate = DebuggingProcessProbe()
        duplicate.edit { $0.descriptors.append($0.descriptors[0]) }
        assertFailure(.descriptorLimit) { try bind(duplicate) }
        let negative = DebuggingProcessProbe()
        negative.edit { $0.descriptors[0].proc_fd = -1 }
        assertFailure(.descriptorLimit) { try bind(negative) }
    }

    func testRejectsMissingListenerAndNonSocketDescriptor() {
        let probe = DebuggingProcessProbe()
        probe.edit { $0.descriptors = [] }
        assertFailure(.listenerUnavailable) { try bind(probe) }
        probe.edit { $0.descriptors = [DebuggingProcessProbe.descriptor(17)]; $0.descriptors[0].proc_fdtype = UInt32(PROX_FDTYPE_VNODE) }
        assertFailure(.listenerUnavailable) { try bind(probe) }
        XCTAssertFalse(probe.snapshot().calls.contains("socket:17"))
    }

    func testRejectsShortFailedAndOversizedSocketResult() {
        for count: Int32 in [-1, 0, 1, Int32(MemoryLayout<socket_fdinfo>.stride - 1), Int32(MemoryLayout<socket_fdinfo>.stride + 1)] {
            let probe = DebuggingProcessProbe()
            probe.edit { $0.socketReturnCount = count }
            assertFailure(.listenerUnavailable) { try bind(probe) }
        }
    }

    func testDiscoverySkipsOnlyExplicitlyDisappearedUnrelatedDescriptor() throws {
        for count: Int32 in [-1, 0] {
            let probe = DebuggingProcessProbe()
            probe.edit {
                $0.descriptors.insert(DebuggingProcessProbe.descriptor(16), at: 0)
                $0.socketFailures[16] = (count, EBADF)
            }
            let binding = try bind(probe)
            XCTAssertEqual(binding.listener.fileDescriptor, 17)
            try binding.validate()
            XCTAssertTrue(probe.snapshot().calls.contains("socket:16"))
        }
    }

    func testDiscoveryDoesNotSkipOtherErrorsOrPartialReadsWithStaleErrno() {
        let failures: [(Int32, Int32)] = [(-1, EACCES), (0, EPERM), (-1, ESRCH),
                                         (-1, ENOENT), (0, 0), (1, EBADF)]
        for failure in failures {
            let probe = DebuggingProcessProbe()
            probe.edit {
                $0.descriptors.insert(DebuggingProcessProbe.descriptor(16), at: 0)
                $0.socketFailures[16] = failure
            }
            assertFailure(.listenerUnavailable) { try bind(probe) }
            XCTAssertFalse(probe.snapshot().calls.contains("socket:17"))
        }
    }

    func testRetainedListenerDisappearanceStillFailsClosed() throws {
        let probe = DebuggingProcessProbe()
        let binding = try bind(probe)
        probe.edit { $0.socketFailures[17] = (0, EBADF); $0.calls = [] }
        assertFailure(.listenerUnavailable) { try binding.validate() }
        XCTAssertEqual(probe.snapshot().calls.filter { $0.hasPrefix("socket:") }, ["socket:17"])
        XCTAssertFalse(probe.snapshot().calls.contains("fds"))
    }

    func testRequiresTCPStreamListeningOnExactPortWithGeneration() {
        let edits: [(inout socket_fdinfo) -> Void] = [
            { $0.psi.soi_kind = Int32(SOCKINFO_IN) }, { $0.psi.soi_type = SOCK_DGRAM },
            { $0.psi.soi_protocol = IPPROTO_UDP }, { $0.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_ESTABLISHED },
            { $0.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(9_223).bigEndian) },
            { $0.psi.soi_proto.pri_tcp.tcpsi_ini.insi_gencnt = 0 },
        ]
        for edit in edits {
            let probe = DebuggingProcessProbe()
            probe.edit { edit(&$0.sockets[17]!) }
            assertFailure(.listenerUnavailable) { try bind(probe) }
        }
    }

    func testRejectsWildcardSiblingLoopbackAndExternalIPv4Address() {
        for address: UInt32 in [0, 0x7f000002, 0xc0a80101] {
            let probe = DebuggingProcessProbe()
            probe.edit { $0.sockets[17]!.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = address.bigEndian }
            assertFailure(.nonLoopbackListener) { try bind(probe) }
        }
    }

    func testRejectsIPv6WildcardAndFamilyFlagMismatch() {
        let probe = DebuggingProcessProbe()
        probe.edit {
            $0.sockets[17] = DebuggingProcessProbe.socket(address: .ipv6)
            $0.sockets[17]!.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_6 = in6_addr()
        }
        assertFailure(.nonLoopbackListener) { try bind(probe, address: .ipv6) }
        probe.edit {
            $0.sockets[17] = DebuggingProcessProbe.socket()
            $0.sockets[17]!.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4 | INI_IPV6)
        }
        assertFailure(.nonLoopbackListener) { try bind(probe) }
    }

    func testDistinctLoopbackFamiliesAreAllowedButSameAddressIsAmbiguous() throws {
        let probe = DebuggingProcessProbe()
        probe.edit {
            $0.descriptors.append(DebuggingProcessProbe.descriptor(18))
            $0.sockets[18] = DebuggingProcessProbe.socket(address: .ipv6)
        }
        XCTAssertEqual(try bind(probe).listener.fileDescriptor, 17)
        XCTAssertEqual(try bind(probe, address: .ipv6).listener.fileDescriptor, 18)
        probe.edit { $0.sockets[18] = DebuggingProcessProbe.socket() }
        assertFailure(.listenerAmbiguous) { try bind(probe) }
    }

    func testRejectsNonLoopbackCompanionListenerOnSamePort() {
        let probe = DebuggingProcessProbe()
        probe.edit {
            $0.descriptors.append(DebuggingProcessProbe.descriptor(18))
            $0.sockets[18] = DebuggingProcessProbe.socket()
            $0.sockets[18]!.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = 0
        }
        assertFailure(.nonLoopbackListener) { try bind(probe) }
    }

    func testPIDReuseBetweenCaptureAndValidationIsRejected() {
        let probe = DebuggingProcessProbe()
        let original = probe.snapshot().process
        var reused = original
        reused.pbi_start_tvusec += 1
        probe.edit { $0.processSequence = [original, reused] }
        assertFailure(.processChanged) { try bind(probe) }
    }

    func testProcessChangeAfterListenerReadIsRejected() throws {
        let probe = DebuggingProcessProbe()
        let binding = try bind(probe)
        let original = probe.snapshot().process
        var reused = original
        reused.pbi_start_tvsec += 1
        probe.edit { $0.processSequence = [original, reused] }
        assertFailure(.processChanged) { try binding.validate() }
    }

    func testListenerFDReuseDoesNotRediscoverOrRetry() throws {
        let probe = DebuggingProcessProbe()
        let binding = try bind(probe)
        probe.edit {
            $0.calls = []
            $0.sockets[17]!.psi.soi_proto.pri_tcp.tcpsi_ini.insi_gencnt += 1
            $0.sockets[99] = DebuggingProcessProbe.socket()
            $0.descriptors = [DebuggingProcessProbe.descriptor(99)]
        }
        assertFailure(.listenerChanged) { try binding.validate() }
        XCTAssertEqual(probe.snapshot().calls.filter { $0.hasPrefix("socket:") }, ["socket:17"])
        XCTAssertFalse(probe.snapshot().calls.contains("fds"))
    }

    func testHotValidationRejectsArgvRevocationAndMissingOriginalFD() throws {
        let probe = DebuggingProcessProbe()
        let binding = try bind(probe)
        probe.edit { $0.arguments = nil; $0.calls = [] }
        assertFailure(.unverifiedOrdinaryProfile) { try binding.validate() }
        XCTAssertFalse(probe.snapshot().calls.contains("socket:17"))
        probe.edit { $0.arguments = ["chrome"]; $0.sockets.removeValue(forKey: 17) }
        assertFailure(.listenerUnavailable) { try binding.validate() }
    }

    private func bind(
        _ probe: DebuggingProcessProbe, pid: Int32 = 42, port: UInt16 = 9_222,
        address: ChromeDebuggingLoopbackAddress = .ipv4
    ) throws -> ChromeDebuggingProcessBinding {
        try ChromeDebuggingProcessBinding.bind(processIdentifier: pid,
            expectedExecutableURL: URL(fileURLWithPath: DebuggingProcessProbe.path), port: port, address: address, syscalls: probe)
    }

    private func assertFailure<T>(
        _ expected: ChromeDebuggingProcessBindingError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? ChromeDebuggingProcessBindingError, expected, file: file, line: line)
        }
    }
}

/// All process/fd metadata comes from native public syscalls for getpid(). The
/// actual path is checked before replacing the policy-only path/argv inputs,
/// allowing the production listener decoder to be tested without accessing or
/// pretending to authenticate Chrome. No foreign process is probed here.
private struct OwnedNativeLoopbackProcessProbe: ChromeDebuggingProcessSyscalls {
    let processIdentifier: Int32
    let expectedNativePath: String
    private let native = SystemChromeDebuggingProcessSyscalls()

    func effectiveUserIdentifier() -> UInt32 { native.effectiveUserIdentifier() }

    func processInfo(pid: Int32, flavor: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int32) -> Int32 {
        guard pid == processIdentifier, pid == getpid() else { return -1 }
        return native.processInfo(pid: pid, flavor: flavor, buffer: buffer, byteCount: byteCount)
    }

    func fileDescriptorInfo(pid: Int32, descriptor: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int32) -> (byteCount: Int32, errorNumber: Int32) {
        guard pid == processIdentifier, pid == getpid() else { return (-1, ESRCH) }
        return native.fileDescriptorInfo(pid: pid, descriptor: descriptor, buffer: buffer, byteCount: byteCount)
    }

    func processPath(pid: Int32, buffer: UnsafeMutableRawPointer, byteCount: UInt32) -> Int32 {
        guard pid == processIdentifier, pid == getpid() else { return -1 }
        let count = native.processPath(pid: pid, buffer: buffer, byteCount: byteCount)
        guard count > 0, count < byteCount else { return -1 }
        let actual = UnsafeRawBufferPointer(start: buffer, count: Int(count))
        guard String(bytes: actual.prefix { $0 != 0 }, encoding: .utf8) == expectedNativePath else { return -1 }
        let adapted: [UInt8] = Array(DebuggingProcessProbe.path.utf8) + [0]
        guard adapted.count < byteCount else { return -1 }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(byteCount))
        adapted.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return Int32(adapted.count - 1)
    }

    func processArguments(pid: Int32) -> [String]? {
        guard pid == processIdentifier, pid == getpid(), native.processArguments(pid: pid)?.isEmpty == false else { return nil }
        return ["chrome"]
    }
}

private final class DebuggingProcessProbe: ChromeDebuggingProcessSyscalls, @unchecked Sendable {
    static let path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    struct State {
        var process = DebuggingProcessProbe.process()
        var processSequence = [proc_bsdinfo]()
        var processReturnCount: Int32?
        var path = DebuggingProcessProbe.path
        var pathBytes: [UInt8]?
        var pathReturnCount: Int32?
        var arguments: [String]? = ["chrome"]
        var descriptors = [DebuggingProcessProbe.descriptor(17)]
        var descriptorReturnCount: Int32?
        var sockets: [Int32: socket_fdinfo] = [17: DebuggingProcessProbe.socket()]
        var socketReturnCount: Int32?
        var socketFailures: [Int32: (Int32, Int32)] = [:]
        var calls = [String]()
    }
    private let lock = NSLock()
    private var state = State()

    func edit(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }
    func effectiveUserIdentifier() -> UInt32 { 501 }

    func processInfo(pid: Int32, flavor: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard pid == 42 else { return -1 }
        if flavor == PROC_PIDTBSDINFO {
            state.calls.append("bsd")
            let value = state.processSequence.isEmpty ? state.process : state.processSequence.removeFirst()
            write(value, to: buffer, byteCount: byteCount)
            return state.processReturnCount ?? Int32(MemoryLayout<proc_bsdinfo>.stride)
        }
        guard flavor == PROC_PIDLISTFDS else { return -1 }
        state.calls.append("fds")
        state.descriptors.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress { buffer.copyMemory(from: address, byteCount: min(Int(byteCount), bytes.count)) }
        }
        return state.descriptorReturnCount ?? Int32(state.descriptors.count * MemoryLayout<proc_fdinfo>.stride)
    }

    func fileDescriptorInfo(pid: Int32, descriptor: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int32) -> (byteCount: Int32, errorNumber: Int32) {
        lock.lock(); defer { lock.unlock() }
        state.calls.append("socket:\(descriptor)")
        if let failure = state.socketFailures[descriptor] { return failure }
        guard pid == 42, let value = state.sockets[descriptor] else { return (-1, EBADF) }
        write(value, to: buffer, byteCount: byteCount)
        return (state.socketReturnCount ?? Int32(MemoryLayout<socket_fdinfo>.stride), 0)
    }

    func processPath(pid: Int32, buffer: UnsafeMutableRawPointer, byteCount: UInt32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        state.calls.append("path")
        guard pid == 42 else { return -1 }
        let bytes: [UInt8] = state.pathBytes ?? (Array(state.path.utf8) + [UInt8(0)])
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: min(Int(byteCount), $0.count)) }
        return state.pathReturnCount ?? Int32(bytes.count - 1)
    }

    func processArguments(pid: Int32) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        state.calls.append("argv")
        return pid == 42 ? state.arguments : nil
    }

    private func write<T>(_ value: T, to buffer: UnsafeMutableRawPointer, byteCount: Int32) {
        var copy = value
        withUnsafeBytes(of: &copy) { buffer.copyMemory(from: $0.baseAddress!, byteCount: min(Int(byteCount), $0.count)) }
    }

    static func process() -> proc_bsdinfo {
        var info = proc_bsdinfo()
        info.pbi_pid = 42; info.pbi_uid = 501; info.pbi_ruid = 501
        info.pbi_status = UInt32(SRUN)
        info.pbi_start_tvsec = 1_800_000_000; info.pbi_start_tvusec = 321
        return info
    }

    static func descriptor(_ number: Int32) -> proc_fdinfo {
        var info = proc_fdinfo()
        info.proc_fd = number; info.proc_fdtype = UInt32(PROX_FDTYPE_SOCKET)
        return info
    }

    static func socket(address: ChromeDebuggingLoopbackAddress = .ipv4) -> socket_fdinfo {
        var info = socket_fdinfo()
        info.psi.soi_kind = Int32(SOCKINFO_TCP); info.psi.soi_type = SOCK_STREAM; info.psi.soi_protocol = IPPROTO_TCP
        info.psi.soi_family = address == .ipv4 ? AF_INET : AF_INET6
        info.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_LISTEN
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_gencnt = 9_876
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(9_222).bigEndian)
        if address == .ipv4 {
            info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
            info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = UInt32(0x7f000001).bigEndian
        } else {
            info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV6)
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { $0[15] = 1 }
            info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_6 = address
        }
        return info
    }
}

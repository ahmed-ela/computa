import Darwin
import Foundation
import XCTest
@testable import Computa

@MainActor
final class OwnedChildProcessTests: XCTestCase {
    private let pid: Int32 = 89757

    func testChildWorkingDirectoryDoesNotChangeParentWorkingDirectory() async throws {
        let failuresBefore = testRun?.failureCount ?? 0
        let before = FileManager.default.currentDirectoryPath
        let fixture = try OwnedFixtureDirectory(prefix: "ComputaChildCWD-")
        let root = fixture.root
        let output = Pipe()
        let child = try OwnedChildProcess(executableURL: URL(fileURLWithPath: "/bin/pwd"),
            arguments: [], environment: [:], workingDirectory: root,
            outputDescriptor: output.fileHandleForWriting.fileDescriptor)
        try output.fileHandleForWriting.close()
        let read = Result { try output.fileHandleForReading.readToEnd() ?? Data() }
        let result = await child.stop()
        XCTAssertTrue(result.succeeded)
        let bytes = try read.get()
        let observed = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: observed).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        XCTAssertEqual(FileManager.default.currentDirectoryPath, before)
        removeSuccessfulFixture(fixture, terminationVerified: result.succeeded, failuresBefore: failuresBefore)
    }

    func testSpawnClearsChildSignalMaskWithoutChangingTheSpawningThread() async throws {
        let failuresBefore = testRun?.failureCount ?? 0
        let probe = try await compileSignalProbe()
        let output = Pipe()
        let (child, unchanged) = try await Task.detached {
            var blocked = sigset_t(), original = sigset_t(), before = sigset_t(), after = sigset_t()
            sigemptyset(&blocked)
            for signal in [SIGCHLD, SIGTERM, SIGINT, SIGPIPE] { sigaddset(&blocked, signal) }
            guard pthread_sigmask(SIG_BLOCK, &blocked, &original) == 0 else { throw POSIXError(.EINVAL) }
            defer { pthread_sigmask(SIG_SETMASK, &original, nil) }
            pthread_sigmask(SIG_BLOCK, nil, &before)
            let child = try OwnedChildProcess(executableURL: probe.binary, arguments: ["mask"], environment: [:],
                outputDescriptor: output.fileHandleForWriting.fileDescriptor)
            pthread_sigmask(SIG_BLOCK, nil, &after)
            return (child, before == after)
        }.value
        try output.fileHandleForWriting.close()
        let stopped = try await waitForExit(child)
        let text = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        XCTAssertTrue(unchanged)
        XCTAssertEqual(text, "blocked=0 nondefault=0\n")
        removeSuccessfulFixture(probe.fixture, terminationVerified: stopped, failuresBefore: failuresBefore)
    }

    func testSpawnedRuntimeCanReceiveSIGCHLDAndReapItsOwnChild() async throws {
        let failuresBefore = testRun?.failureCount ?? 0
        let probe = try await compileSignalProbe()
        let output = Pipe()
        let child = try await Task.detached {
            try OwnedChildProcess(executableURL: probe.binary, arguments: ["wait"], environment: [:],
                outputDescriptor: output.fileHandleForWriting.fileDescriptor)
        }.value
        try output.fileHandleForWriting.close()
        let stopped = try await waitForExit(child)
        let text = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        XCTAssertEqual(text, "blocked=0 nondefault=0\nobserved_sigchld=1 child_exit=23\n")
        removeSuccessfulFixture(probe.fixture, terminationVerified: stopped, failuresBefore: failuresBefore)
    }

    private struct CompiledProbe: Sendable {
        let binary: URL
        let fixture: OwnedFixtureDirectory
    }

    private struct OwnedFixtureDirectory: Sendable {
        let root: URL
        let device: dev_t
        let inode: ino_t

        init(prefix: String) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            var identity = stat()
            guard root.path.withCString({ Darwin.lstat($0, &identity) }) == 0,
                  (identity.st_mode & S_IFMT) == S_IFDIR else { throw POSIXError(.EINVAL) }
            device = identity.st_dev
            inode = identity.st_ino
            print("fixtureOwned kind=owned_child path=\(root.path) device=\(device) inode=\(inode)")
        }

        func removeAfterVerifiedTermination() -> String? {
            var identity = stat()
            guard root.path.withCString({ Darwin.lstat($0, &identity) }) == 0,
                  (identity.st_mode & S_IFMT) == S_IFDIR,
                  identity.st_dev == device, identity.st_ino == inode else {
                return "Fixture identity changed; refusing removal of \(root.path)."
            }
            return OwnedProfileCleanup.removeAndVerify(root, operations: .live)
        }
    }

    private func removeSuccessfulFixture(_ fixture: OwnedFixtureDirectory,
        terminationVerified: Bool, failuresBefore: Int) {
        guard terminationVerified, (testRun?.failureCount ?? 0) == failuresBefore else {
            print("fixtureCleanupPreserved kind=owned_child path=\(fixture.root.path) reason=test_or_termination_failed")
            return
        }
        if let issue = fixture.removeAfterVerifiedTermination() {
            XCTFail("Fixture cleanup failed: \(String(issue.prefix(1_024)))")
        } else {
            print("fixtureCleanupVerified kind=owned_child path=\(fixture.root.path) device=\(fixture.device) inode=\(fixture.inode)")
        }
    }

    private func compileSignalProbe() async throws -> CompiledProbe {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OwnedChildSignalProbe.c")
        let fixture = try OwnedFixtureDirectory(prefix: "ComputaSignalProbe-")
        let binary = fixture.root.appendingPathComponent("probe")
        let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        let compilerURL = developer.map {
            URL(fileURLWithPath: $0).appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        } ?? URL(fileURLWithPath: "/usr/bin/clang")
        let sdkArguments = developer.map {
            ["-isysroot", URL(fileURLWithPath: $0)
                .appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk").path]
        } ?? []
        let diagnosticURL = fixture.root.appendingPathComponent("compiler.log")
        guard FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil) else {
            throw POSIXError(.EIO)
        }
        let diagnostics = try FileHandle(forWritingTo: diagnosticURL)
        defer { try? diagnostics.close() }
        let compiler = try OwnedChildProcess(executableURL: compilerURL,
            arguments: sdkArguments + [source.path, "-o", binary.path],
            errorDescriptor: diagnostics.fileDescriptor)
        // Fixture compilation can pay a cold toolchain cost. Keep that budget
        // separate from the short deadline for the signal behavior under test.
        let stopped = try await waitForExit(compiler, timeout: .seconds(60), role: "signal fixture compiler")
        let reader = try FileHandle(forReadingFrom: diagnosticURL)
        defer { try? reader.close() }
        let diagnosticText = String(decoding: try reader.read(upToCount: 1_024) ?? Data(), as: UTF8.self)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path),
            "Signal fixture compilation failed: \(diagnosticText)")
        guard stopped, FileManager.default.isExecutableFile(atPath: binary.path) else {
            print("fixtureCleanupPreserved kind=signal_probe path=\(fixture.root.path) reason=compiler_termination_or_output_failed")
            throw POSIXError(.ENOEXEC)
        }
        return CompiledProbe(binary: binary, fixture: fixture)
    }

    private func waitForExit(_ child: OwnedChildProcess, timeout: Duration = .seconds(8),
        role: String = "signal fixture") async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while child.isRunning && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            let cleanup = await child.stop()
            print("fixtureTerminationAfterCancellation pid=\(child.processIdentifier) stopped=\(cleanup.succeeded) issues=\(String(cleanup.issues.joined(separator: "; ").prefix(1_024)))")
            throw error
        }
        let exited = !child.isRunning
        let cleanup = await child.stop()
        XCTAssertTrue(exited, "The owned \(role) did not exit within its \(timeout) bound.")
        XCTAssertTrue(cleanup.succeeded, cleanup.issues.joined(separator: "; "))
        return exited && cleanup.succeeded
    }

    func testObservedSIGKILLEPERMResolvesOnlyAfterReapAndFreshESRCH() async {
        let script = ScriptedStopOperations(
            killResult: failed(EPERM),
            waits: [waited(pid)],
            probes: [failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.rootReaped)
        XCTAssertTrue(result.groupGone)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.signalDiagnostics, [
            "SIGKILL failed for owned group \(pid): result=-1 errno=\(EPERM)",
        ])
        XCTAssertEqual(script.events, [
            .signal(-pid, SIGTERM),
            .sleep(.milliseconds(750)),
            .signal(-pid, SIGKILL),
            .wait(pid),
            .signal(-pid, 0),
        ])
    }

    func testBothSignalEPERMsAreRetainedAsDiagnosticsAfterVerifiedExit() async {
        let script = ScriptedStopOperations(
            termResult: failed(EPERM),
            killResult: failed(EPERM),
            waits: [waited(pid, status: SIGTERM)],
            probes: [failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.signalDiagnostics.count, 2)
        XCTAssertTrue(result.signalDiagnostics[0].hasPrefix("SIGTERM"))
        XCTAssertTrue(result.signalDiagnostics[1].hasPrefix("SIGKILL"))
    }

    func testTransientPostReapProbeEPERMRequiresLaterESRCH() async {
        let script = ScriptedStopOperations(
            killResult: failed(EPERM),
            waits: [waited(pid)],
            probes: [failed(EPERM), failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(script.elapsed, .milliseconds(775))
        XCTAssertEqual(script.events.filter { $0 == .wait(pid) }.count, 1)
        XCTAssertEqual(script.events.filter { $0 == .signal(-pid, 0) }.count, 2)
        assertSignalOrdering(script)
    }

    func testSurvivingGroupFailsEvenWithSuccessfullyReapedRoot() async {
        let script = ScriptedStopOperations(
            killResult: failed(EPERM),
            waits: [waited(pid)],
            probes: [succeeded()]
        )
        let result = await stop(script)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.rootReaped)
        XCTAssertFalse(result.groupGone)
        XCTAssertTrue(result.issues.contains { $0.hasPrefix("SIGKILL failed") })
        XCTAssertTrue(result.issues.contains { $0.contains("still exists or is unverifiable") })
        XCTAssertEqual(script.elapsed, .milliseconds(2750))
        XCTAssertEqual(script.events.filter { $0 == .wait(pid) }.count, 1)
        assertSignalOrdering(script)
    }

    func testUnverifiableFinalGroupFailsForEveryNonESRCHError() async {
        for errorNumber in [EPERM, EACCES, EIO, EINVAL, EINTR] {
            let script = ScriptedStopOperations(
                killResult: failed(EPERM),
                waits: [waited(pid)],
                probes: [failed(errorNumber)]
            )
            let result = await stop(script)
            XCTAssertFalse(result.succeeded, "errno=\(errorNumber)")
            XCTAssertTrue(result.rootReaped)
            XCTAssertFalse(result.groupGone)
            XCTAssertTrue(result.issues.contains {
                $0.contains("Last probe: result=-1 errno=\(errorNumber)")
            })
            XCTAssertEqual(script.elapsed, .milliseconds(2750))
            assertSignalOrdering(script)
        }
    }

    func testESRCHAloneDoesNotProveRootWasReaped() async {
        let script = ScriptedStopOperations(
            killResult: failed(EPERM),
            waits: [waited(0)],
            probes: [failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.rootReaped)
        XCTAssertTrue(result.groupGone)
        XCTAssertTrue(result.issues.contains { $0.hasPrefix("SIGKILL failed") })
        XCTAssertTrue(result.issues.contains { $0.contains("was not reaped") })
        XCTAssertEqual(script.elapsed, .milliseconds(2750))
        assertSignalOrdering(script)
    }

    func testECHILDIsNotConvertedIntoSuccessfulRootReaping() async {
        let script = ScriptedStopOperations(
            waits: [waitFailed(ECHILD)],
            probes: [failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.rootReaped)
        XCTAssertTrue(result.groupGone)
        XCTAssertTrue(result.issues.contains {
            $0 == "waitpid failed for owned child \(pid): errno=\(ECHILD)"
        })
        XCTAssertEqual(script.events.filter { $0 == .wait(pid) }.count, 1)
        assertSignalOrdering(script)
    }

    func testInterruptedWaitIsRetriedWithinTheSameDeadline() async {
        let script = ScriptedStopOperations(
            waits: [waitFailed(EINTR), waited(pid, status: SIGKILL)],
            probes: [succeeded(), failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(script.elapsed, .milliseconds(775))
        XCTAssertEqual(script.events.filter { $0 == .wait(pid) }.count, 2)
        assertSignalOrdering(script)
    }

    func testRepeatedInterruptedWaitCannotExtendTheDeadline() async {
        let script = ScriptedStopOperations(
            waits: [waitFailed(EINTR)],
            probes: [failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.rootReaped)
        XCTAssertEqual(script.elapsed, .milliseconds(2750))
        assertSignalOrdering(script)
    }

    func testStoppedOrContinuedStatusIsNotAReapedRoot() async {
        for signal in [SIGSTOP, SIGCONT] {
            let script = ScriptedStopOperations(
                waits: [waited(pid, status: (signal << 8) | 0x7f), waited(pid)],
                probes: [failed(ESRCH)]
            )
            let result = await stop(script)
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(script.events.filter { $0 == .wait(pid) }.count, 2)
            XCTAssertEqual(script.elapsed, .milliseconds(775))
        }
    }

    func testUnexpectedWaitPIDFailsClosed() async {
        let script = ScriptedStopOperations(
            waits: [waited(pid + 1)],
            probes: [failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.rootReaped)
        XCTAssertTrue(result.issues.contains { $0.contains("unexpected PID") })
        assertSignalOrdering(script)
    }

    func testUnexpectedSignalErrorRemainsFatalDespiteFinalPostconditions() async {
        let script = ScriptedStopOperations(
            killResult: failed(EINVAL),
            waits: [waited(pid)],
            probes: [failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertTrue(result.rootReaped)
        XCTAssertTrue(result.groupGone)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.issues, result.signalDiagnostics)
        XCTAssertTrue(result.issues.contains { $0.contains("errno=\(EINVAL)") })
    }

    func testSignalESRCHStillRequiresIndependentWaitAndGroupProbe() async {
        let script = ScriptedStopOperations(
            termResult: failed(ESRCH),
            killResult: failed(ESRCH),
            waits: [waited(0), waited(pid)],
            probes: [succeeded(), failed(ESRCH)]
        )
        let result = await stop(script)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.signalDiagnostics.isEmpty)
        XCTAssertEqual(script.events.filter { $0 == .wait(pid) }.count, 2)
        assertSignalOrdering(script)
    }

    func testSuccessfulProbeCannotUseAStaleESRCHErrno() async {
        let script = ScriptedStopOperations(
            waits: [waited(pid)],
            probes: [OwnedChildProcess.CallResult(value: 0, errorNumber: ESRCH)]
        )
        let result = await stop(script)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.groupGone)
        XCTAssertEqual(script.elapsed, .milliseconds(2750))
    }

    func testEarlierESRCHIsNotLatchedAcrossReaping() async {
        let script = ScriptedStopOperations(
            killResult: failed(EPERM),
            waits: [waited(0), waited(pid)],
            probes: [failed(ESRCH), failed(EPERM)]
        )
        let result = await stop(script)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.rootReaped)
        XCTAssertFalse(result.groupGone)
        XCTAssertTrue(result.issues.contains { $0.hasPrefix("SIGKILL failed") })
        assertSignalOrdering(script)
    }

    func testUnsafeIdentifiersNeverReachAnySystemOperation() async {
        for invalidPID in [Int32(0), 1, -1, -89757, Int32.min] {
            let script = ScriptedStopOperations(waits: [waited(0)], probes: [failed(ESRCH)])
            let result = await OwnedChildProcess.stopOwnedGroup(
                processIdentifier: invalidPID, operations: script.operations
            )
            XCTAssertFalse(result.succeeded)
            XCTAssertTrue(script.events.isEmpty)
        }
    }

    private func stop(_ script: ScriptedStopOperations) async -> OwnedChildProcess.StopResult {
        await OwnedChildProcess.stopOwnedGroup(
            processIdentifier: pid, operations: script.operations
        )
    }

    private func assertSignalOrdering(
        _ script: ScriptedStopOperations,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let events = script.events
        let nonzeroSignals = events.filter {
            if case .signal(_, let signal) = $0 { return signal != 0 }
            return false
        }
        XCTAssertEqual(nonzeroSignals, [.signal(-pid, SIGTERM), .signal(-pid, SIGKILL)],
                       file: file, line: line)
        guard let firstWait = events.firstIndex(of: .wait(pid)),
              let lastSignal = events.lastIndex(of: .signal(-pid, SIGKILL)) else {
            XCTFail("Missing wait or escalation attempt.", file: file, line: line)
            return
        }
        XCTAssertLessThan(lastSignal, firstWait, file: file, line: line)
    }
}

@MainActor
final class OwnedProfileCleanupTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/owned-cleanup-test/profile", isDirectory: true)

    func testRemovalRequiresVerifiedENOENT() {
        let operations = OwnedProfileCleanup.Operations(
            remove: { _ in },
            inspect: { _ in failed(ENOENT) }
        )
        XCTAssertNil(OwnedProfileCleanup.removeAndVerify(directory, operations: operations))
    }

    func testConcurrentRemovalErrorCanResolveOnlyThroughENOENT() {
        let operations = OwnedProfileCleanup.Operations(
            remove: { _ in throw POSIXError(.EACCES) },
            inspect: { _ in failed(ENOENT) }
        )
        XCTAssertNil(OwnedProfileCleanup.removeAndVerify(directory, operations: operations))
    }

    func testRemainingPathOrDanglingSymlinkFailsAfterRemovalReturns() {
        let operations = OwnedProfileCleanup.Operations(
            remove: { _ in },
            // lstat returns zero for an extant entry, including a dangling symlink.
            inspect: { _ in succeeded() }
        )
        let issue = OwnedProfileCleanup.removeAndVerify(directory, operations: operations)
        XCTAssertTrue(issue?.contains("the path still exists") == true)
    }

    func testUnverifiableProfileNeverMasqueradesAsMissing() {
        for errorNumber in [EACCES, EPERM, EIO, ENOTDIR, EINTR] {
            let operations = OwnedProfileCleanup.Operations(
                remove: { _ in },
                inspect: { _ in failed(errorNumber) }
            )
            let issue = OwnedProfileCleanup.removeAndVerify(directory, operations: operations)
            XCTAssertTrue(issue?.contains("absence is unverifiable") == true)
            XCTAssertTrue(issue?.contains("errno=\(errorNumber)") == true)
        }
    }

    func testRemovalErrorIsPreservedWhenTheProfileStillExists() {
        let operations = OwnedProfileCleanup.Operations(
            remove: { _ in throw POSIXError(.EACCES) },
            inspect: { _ in succeeded() }
        )
        let issue = OwnedProfileCleanup.removeAndVerify(directory, operations: operations)
        XCTAssertTrue(issue?.contains("the path still exists") == true)
        XCTAssertTrue(issue?.contains("Removal error:") == true)
    }

    func testSuccessfulInspectionCannotUseStaleENOENT() {
        let operations = OwnedProfileCleanup.Operations(
            remove: { _ in },
            inspect: { _ in OwnedChildProcess.CallResult(value: 0, errorNumber: ENOENT) }
        )
        XCTAssertNotNil(OwnedProfileCleanup.removeAndVerify(directory, operations: operations))
    }
}

private func succeeded() -> OwnedChildProcess.CallResult {
    OwnedChildProcess.CallResult(value: 0, errorNumber: 0)
}

private func failed(_ errorNumber: Int32) -> OwnedChildProcess.CallResult {
    OwnedChildProcess.CallResult(value: -1, errorNumber: errorNumber)
}

private func waited(_ pid: Int32, status: Int32 = 0) -> OwnedChildProcess.WaitObservation {
    OwnedChildProcess.WaitObservation(
        call: OwnedChildProcess.CallResult(value: pid, errorNumber: 0), status: status
    )
}

private func waitFailed(_ errorNumber: Int32) -> OwnedChildProcess.WaitObservation {
    OwnedChildProcess.WaitObservation(call: failed(errorNumber), status: 0)
}

/// Test-only syscall/clock script. Every mutable field is private and all access
/// holds lock synchronously; no lock spans an await. No OS syscall, process launch,
/// filesystem operation, or real-time sleep is performed by this fake.
private final class ScriptedStopOperations: @unchecked Sendable {
    enum Event: Equatable {
        case signal(Int32, Int32)
        case wait(Int32)
        case sleep(Duration)
    }

    private let lock = NSLock()
    private let termResult: OwnedChildProcess.CallResult
    private let killResult: OwnedChildProcess.CallResult
    private let waits: [OwnedChildProcess.WaitObservation]
    private let probes: [OwnedChildProcess.CallResult]
    private var waitIndex = 0
    private var probeIndex = 0
    private var recordedEvents = [Event]()
    private var elapsedTime: Duration = .zero

    init(
        termResult: OwnedChildProcess.CallResult = succeeded(),
        killResult: OwnedChildProcess.CallResult = succeeded(),
        waits: [OwnedChildProcess.WaitObservation],
        probes: [OwnedChildProcess.CallResult]
    ) {
        precondition(!waits.isEmpty && !probes.isEmpty)
        self.termResult = termResult
        self.killResult = killResult
        self.waits = waits
        self.probes = probes
    }

    var events: [Event] { lock.withLock { recordedEvents } }
    var elapsed: Duration { lock.withLock { elapsedTime } }

    var operations: OwnedChildProcess.StopOperations {
        OwnedChildProcess.StopOperations(
            signal: { [self] pid, signal in signalResult(pid, signal) },
            wait: { [self] pid in waitResult(pid) },
            now: { [self] in elapsed },
            sleep: { [self] duration in advance(duration) }
        )
    }

    private func signalResult(_ pid: Int32, _ signal: Int32) -> OwnedChildProcess.CallResult {
        lock.withLock {
            recordedEvents.append(.signal(pid, signal))
            switch signal {
            case SIGTERM: return termResult
            case SIGKILL: return killResult
            case 0:
                let result = probes[min(probeIndex, probes.count - 1)]
                probeIndex += 1
                return result
            default: return failed(EINVAL)
            }
        }
    }

    private func waitResult(_ pid: Int32) -> OwnedChildProcess.WaitObservation {
        lock.withLock {
            recordedEvents.append(.wait(pid))
            let result = waits[min(waitIndex, waits.count - 1)]
            waitIndex += 1
            return result
        }
    }

    private func advance(_ duration: Duration) {
        lock.withLock {
            recordedEvents.append(.sleep(duration))
            elapsedTime += duration
        }
    }
}

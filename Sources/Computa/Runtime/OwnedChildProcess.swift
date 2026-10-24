import Darwin
import Foundation

/// Owns one child and a process group created for that child at spawn time.
/// No Foundation Process or other code may reap this PID. Keeping the root
/// unreaped pins its PID until the final nonzero group signal. After reaping,
/// only zero-signal absence probes are allowed. Never adopt a discovered PID.
actor OwnedChildProcess {
    struct StopResult: Equatable, Sendable {
        let rootReaped: Bool
        let groupGone: Bool
        let issues: [String]
        /// Intermediate signal errors are retained even when final proof resolves them.
        let signalDiagnostics: [String]

        init(
            rootReaped: Bool,
            groupGone: Bool,
            issues: [String],
            signalDiagnostics: [String] = []
        ) {
            self.rootReaped = rootReaped
            self.groupGone = groupGone
            self.issues = issues
            self.signalDiagnostics = signalDiagnostics
        }

        var succeeded: Bool { rootReaped && groupGone && issues.isEmpty }
    }

    /// Capture errno synchronously with its syscall, before any suspension.
    struct CallResult: Equatable, Sendable {
        let value: Int32
        let errorNumber: Int32
    }

    struct WaitObservation: Equatable, Sendable {
        let call: CallResult
        let status: Int32

        var isTerminal: Bool {
            // Darwin's WIFEXITED || WIFSIGNALED, excluding stopped/continued
            // status (including a traced stop returned without WUNTRACED).
            (status & 0x7f) != 0x7f
        }
    }

    /// Injected only into the stop algorithm; the normal ownership initializer
    /// still obtains its PID exclusively from posix_spawn, never PID discovery.
    struct StopOperations: Sendable {
        let signal: @Sendable (Int32, Int32) -> CallResult
        let wait: @Sendable (Int32) -> WaitObservation
        let now: @Sendable () -> Duration
        let sleep: @Sendable (Duration) async -> Void

        static func live() -> Self {
            let clock = ContinuousClock()
            let origin = clock.now
            return Self(
                signal: { pid, signal in
                    let value = Darwin.kill(pid, signal)
                    let errorNumber = value == -1 ? errno : 0
                    return CallResult(value: value, errorNumber: errorNumber)
                },
                wait: { pid in
                    var status: Int32 = 0
                    let value = waitpid(pid, &status, WNOHANG)
                    let errorNumber = value == -1 ? errno : 0
                    return WaitObservation(
                        call: CallResult(value: value, errorNumber: errorNumber),
                        status: status
                    )
                },
                now: { origin.duration(to: clock.now) },
                sleep: { duration in
                    try? await Task.sleep(for: duration)
                }
            )
        }
    }

    nonisolated let processIdentifier: Int32
    private var stopTask: Task<StopResult, Never>?

    /// WNOWAIT observes exit without releasing the PID needed for safe group
    /// signaling. Protocol/AppKit reads, not this property, establish readiness.
    nonisolated var isRunning: Bool {
        var information = siginfo_t()
        let result = waitid(
            P_PID, id_t(processIdentifier), &information, WEXITED | WNOHANG | WNOWAIT
        )
        if result == 0 { return information.si_pid == 0 }
        return errno == EINTR
    }

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil,
        inputDescriptor: Int32? = nil,
        outputDescriptor: Int32? = nil,
        errorDescriptor: Int32? = nil
    ) throws {
        processIdentifier = try Self.spawn(
            executableURL: executableURL, arguments: arguments,
            environment: environment, workingDirectory: workingDirectory,
            inputDescriptor: inputDescriptor, outputDescriptor: outputDescriptor,
            errorDescriptor: errorDescriptor
        )
    }

    /// Transfers sole ownership of an unreaped child and its new process group
    /// to the caller. The caller must finish group signaling before reaping.
    /// Synchronous command runners use this same descriptor and signal setup.
    nonisolated static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil,
        inputDescriptor: Int32? = nil,
        outputDescriptor: Int32? = nil,
        errorDescriptor: Int32? = nil
    ) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        try Self.requireSuccess(posix_spawnattr_init(&attributes))
        defer { _ = posix_spawnattr_destroy(&attributes) }
        try Self.requireSuccess(posix_spawn_file_actions_init(&actions))
        defer { _ = posix_spawn_file_actions_destroy(&actions) }

        // Set only the child's cwd, atomically at spawn. Never change the
        // native app's process-wide cwd (other owned children may be running).
        if let workingDirectory {
            guard workingDirectory.isFileURL else { throw POSIXError(.EINVAL) }
            try Self.requireSuccess(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path))
        }

        // Swift concurrency workers block signals. Inheriting that thread mask
        // prevents an async child runtime from receiving SIGCHLD and reaping its
        // own commands. Set only the child's mask/dispositions; never mutate the
        // application's process-wide handlers or the spawning thread's mask.
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try Self.requireSuccess(posix_spawnattr_setsigmask(&attributes, &signalMask))
        var signalDefaults = sigset_t()
        sigemptyset(&signalDefaults)
        for signal in [SIGCHLD, SIGTERM, SIGINT, SIGPIPE] { sigaddset(&signalDefaults, signal) }
        try Self.requireSuccess(posix_spawnattr_setsigdefault(&attributes, &signalDefaults))
        // pgroup=0 makes the child's own PID its PGID atomically at spawn.
        // CLOEXEC_DEFAULT prevents unrelated host descriptors reaching it.
        try Self.requireSuccess(posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        ))
        try Self.requireSuccess(posix_spawnattr_setpgroup(&attributes, 0))
        let descriptors: [(Int32, Int32?)] = [
            (STDIN_FILENO, inputDescriptor),
            (STDOUT_FILENO, outputDescriptor),
            (STDERR_FILENO, errorDescriptor),
        ]
        for (destination, source) in descriptors {
            if let source {
                try Self.requireSuccess(
                    posix_spawn_file_actions_adddup2(&actions, source, destination)
                )
            } else {
                try Self.requireSuccess(posix_spawn_file_actions_addopen(
                    &actions, destination, "/dev/null",
                    destination == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0
                ))
            }
        }

        let argumentStrings = [executableURL.path] + arguments
        let environmentStrings = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        let argumentPointers: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        let environmentPointers: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }
        guard argumentPointers.allSatisfy({ $0 != nil }),
              environmentPointers.allSatisfy({ $0 != nil }) else {
            throw POSIXError(.ENOMEM)
        }
        var argv = argumentPointers + [nil]
        var envp = environmentPointers + [nil]
        var pid: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer { arguments in
            envp.withUnsafeMutableBufferPointer { environment in
                executableURL.path.withCString { path in
                    posix_spawn(
                        &pid, path, &actions, &attributes,
                        arguments.baseAddress!, environment.baseAddress!
                    )
                }
            }
        }
        try Self.requireSuccess(status)
        return pid
    }

    func stop() async -> StopResult {
        if let stopTask { return await stopTask.value }
        // An unstructured owned task does not inherit caller cancellation.
        let task = Task { await self.stopOnce() }
        stopTask = task
        return await task.value
    }

    private func stopOnce() async -> StopResult {
        let result = await Self.stopOwnedGroup(
            processIdentifier: processIdentifier, operations: .live()
        )
        for diagnostic in result.signalDiagnostics {
            NSLog(
                "%@",
                "\(diagnostic); root_reaped=\(result.rootReaped) group_gone=\(result.groupGone)"
            )
        }
        return result
    }

    /// No default operations: tests must explicitly supply fake syscalls.
    /// Production calls this only for the unreaped child owned by this actor.
    static func stopOwnedGroup(
        processIdentifier: Int32,
        operations: StopOperations
    ) async -> StopResult {
        guard processIdentifier > 1 else {
            return StopResult(
                rootReaped: false,
                groupGone: false,
                issues: ["Refused an invalid owned process-group ID: \(processIdentifier)."]
            )
        }

        // Keep the root unreaped until BOTH nonzero signal attempts complete.
        // Reaping before escalation could allow its numeric PID/PGID to be reused.
        let terminated = operations.signal(-processIdentifier, SIGTERM)
        await operations.sleep(.milliseconds(750))
        let killed = operations.signal(-processIdentifier, SIGKILL)
        let attempts = [("SIGTERM", terminated), ("SIGKILL", killed)]

        let deadline = operations.now() + .seconds(2)
        var issues = [String]()
        var rootReaped = false
        var groupGone = false
        var lastProbe: CallResult?
        repeat {
            var waitFailed = false
            if !rootReaped {
                let observed = operations.wait(processIdentifier)
                if observed.call.value == processIdentifier {
                    rootReaped = observed.isTerminal
                } else if observed.call.value == -1 {
                    if observed.call.errorNumber != EINTR {
                        // ECHILD is not proof that this owner reaped its root.
                        issues.append(
                            "waitpid failed for owned child \(processIdentifier): "
                                + "errno=\(observed.call.errorNumber)"
                        )
                        waitFailed = true
                    }
                } else if observed.call.value != 0 {
                    issues.append(
                        "waitpid returned unexpected PID \(observed.call.value) "
                            + "for owned child \(processIdentifier)."
                    )
                    waitFailed = true
                }
            }

            // Only a failed zero-signal probe with ESRCH establishes absence.
            // EPERM means unavailable evidence, NOT absence. Do not latch an
            // earlier ESRCH across a later reap; sample again after that reap.
            let probe = operations.signal(-processIdentifier, 0)
            lastProbe = probe
            groupGone = probe.value == -1 && probe.errorNumber == ESRCH
            if (rootReaped && groupGone) || waitFailed { break }
            await operations.sleep(.milliseconds(25))
        } while operations.now() < deadline

        var signalDiagnostics = [String]()
        for (name, attempt) in attempts {
            if attempt.value == 0 { continue }
            if attempt.value == -1 && attempt.errorNumber == ESRCH { continue }
            let diagnostic =
                "\(name) failed for owned group \(processIdentifier): "
                + "result=\(attempt.value) errno=\(attempt.errorNumber)"
            signalDiagnostics.append(diagnostic)

            // XNU's group path can find the group but filter out all zombies,
            // yielding EPERM. That is only a possible explanation, not proof.
            // Resolve this intermediate error ONLY with both final postconditions.
            let resolved = attempt.value == -1 && attempt.errorNumber == EPERM
                && rootReaped && groupGone
            if !resolved { issues.append(diagnostic) }
        }
        if !rootReaped {
            issues.append("Owned child \(processIdentifier) was not reaped before the deadline.")
        }
        if !groupGone {
            let detail = lastProbe.map {
                " Last probe: result=\($0.value) errno=\($0.errorNumber)."
            } ?? ""
            issues.append(
                "Owned process group \(processIdentifier) still exists or is unverifiable."
                    + detail
            )
        }
        return StopResult(
            rootReaped: rootReaped,
            groupGone: groupGone,
            issues: issues,
            signalDiagnostics: signalDiagnostics
        )
    }

    private static func requireSuccess(_ status: Int32) throws {
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
    }
}

enum OwnedProfileCleanup {
    struct Operations: Sendable {
        let remove: @Sendable (URL) throws -> Void
        let inspect: @Sendable (URL) -> OwnedChildProcess.CallResult

        static let live = Self(
            remove: { try FileManager.default.removeItem(at: $0) },
            inspect: { directory in
                var information = stat()
                return directory.path.withCString { path in
                    let value = Darwin.lstat(path, &information)
                    let errorNumber = value == -1 ? errno : 0
                    return OwnedChildProcess.CallResult(value: value, errorNumber: errorNumber)
                }
            }
        )
    }

    /// Runs on the existing bounded cleanup worker. A failed removal can race
    /// with another removal, but only an errno-aware absence check resolves it.
    static func removeAndVerify(_ directory: URL, operations: Operations) -> String? {
        var removalError: String?
        do {
            try operations.remove(directory)
        } catch {
            removalError = error.localizedDescription
        }

        // lstat also detects a remaining dangling symlink. fileExists(false)
        // cannot distinguish absence from an inability to inspect the path.
        let inspected = operations.inspect(directory)
        if inspected.value == -1 && inspected.errorNumber == ENOENT { return nil }
        let detail = inspected.value == 0
            ? "the path still exists"
            : "absence is unverifiable (result=\(inspected.value) errno=\(inspected.errorNumber))"
        let removalDetail = removalError.map { " Removal error: \($0)" } ?? ""
        return "Owned profile cleanup failed for \(directory.path): \(detail).\(removalDetail)"
    }

    /// The caller supplies only its freshly created private profile directory.
    /// A timeout reports incomplete cleanup; it never pretends deletion finished.
    static func remove(_ directory: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .utility).async {
                completion.finish(removeAndVerify(directory, operations: .live))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                completion.finish("Owned profile deletion exceeded its deadline: \(directory.path)")
            }
        }
    }

    /// Only the continuation slot is mutable; every access takes this lock.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?

        init(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func finish(_ issue: String?) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(returning: issue)
        }
    }
}

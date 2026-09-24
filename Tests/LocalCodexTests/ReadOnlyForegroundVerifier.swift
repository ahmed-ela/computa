import Foundation

/// Final verification has only read, clock, delay, and evidence dependencies.
/// There is intentionally no activation, AXRaise, navigation, or input operation.
/// The legacy type/file name is retained; active-tab and global-app outcomes
/// are separate fields, and only the former participates in tab correctness.
@MainActor
enum ReadOnlyForegroundVerifier {
    enum Focus: String, Codable, Sendable {
        case focused
        case notWindow = "not_window"
        case applicationNotFocused = "application_not_focused"
        case windowNotFocused = "window_not_focused"
        case unavailable
    }

    struct FrontmostApplication: Codable, Equatable, Sendable {
        let processIdentifier: Int32
        let bundleIdentifier: String?
    }

    /// Derived from this run's received, acknowledged fixture observations.
    /// Any observed contradiction after the cutoff stays fatal even if a later
    /// heartbeat returns to the expected visibility.
    struct VisibilityEvidence: Codable, Equatable, Sendable {
        var aHiddenAcknowledged = false
        var bVisibleAcknowledged = false
        var aObservedVisible = false
        var bObservedHidden = false
        var latestASequence: Int?
        var latestBSequence: Int?

        var contradictsPreservation: Bool { aObservedVisible || bObservedHidden }
        var confirmsPreservation: Bool {
            aHiddenAcknowledged && bVisibleAcknowledged && !contradictsPreservation
        }
    }

    struct Probe: Codable, Equatable, Sendable {
        var focus: Focus = .unavailable
        var snapshotIdentifier: String?
        var isWindowSnapshot = false
        var addressFieldCount = 0
        var exactAddressMatches = 0
        var addressValues = [String]()
        var visibility = VisibilityEvidence()
        var frontmostReadAttempted = false
        var frontmostBefore: FrontmostApplication?
        var frontmostAfter: FrontmostApplication?
        var focusReadError: String?
        var focusErrorCode: Int32?
        var readError: String?
        var accessibilityErrorCode: Int32?
        var fatalError: String?

        var hasExactWindowAddress: Bool {
            fatalError == nil && readError == nil && isWindowSnapshot
                && snapshotIdentifier?.isEmpty == false && focus != .notWindow
                && addressFieldCount == 1 && exactAddressMatches == 1
        }

        var isExactActiveTab: Bool {
            // windowNotFocused describes macOS window focus, not Chrome's
            // selected tab. The independent address + visibility proof governs.
            hasExactWindowAddress && visibility.confirmsPreservation
        }

        var contradictsExpectedAddress: Bool {
            fatalError == nil && readError == nil && isWindowSnapshot
                && snapshotIdentifier?.isEmpty == false
                && addressFieldCount == 1 && exactAddressMatches == 0
                && addressValues.count == 1 && !addressValues[0].isEmpty
        }
    }

    struct Limits {
        var maximumAttempts = 20
        var timeout: Duration = .seconds(5)
        var retryDelay: Duration = .milliseconds(100)
        var requiredConsecutiveMatches = 2
    }

    enum Status: String, Codable, Sendable {
        case inProgress = "in_progress"
        case confirmed
        case exhausted
        case deadlineExceeded = "deadline_exceeded"
        case contradictoryAddress = "contradictory_address"
        case contradictoryVisibility = "contradictory_visibility"
        case fatalRead = "fatal_read"
        case cancelled
    }

    /// Sampled observations, NOT a claim of continuous desktop focus.
    enum GlobalApplicationFocus: String, Codable, Sendable {
        case unobserved
        case frontmostAtAllSamples = "frontmost_at_all_samples"
        case notFrontmostAtAllSamples = "not_frontmost_at_all_samples"
        case mixed
        case incomplete
    }

    struct Sample: Codable, Equatable, Sendable {
        let attempt: Int
        let startedMilliseconds: Int64
        let finishedMilliseconds: Int64
        let probe: Probe
    }

    struct Report: Codable, Equatable, Sendable {
        let mode: String
        let processIdentifier: Int32
        let expectedAddress: String
        let maximumAttempts: Int
        let timeoutMilliseconds: Int64
        let retryDelayMilliseconds: Int64
        let requiredConsecutiveMatches: Int
        var schemaVersion = 2
        var activeTabStatus: Status = .inProgress
        var globalApplicationFocus: GlobalApplicationFocus = .unobserved
        var consecutiveMatches = 0
        var samples = [Sample]()

        var activeTabPreserved: Bool { activeTabStatus == .confirmed }
    }

    struct Operations {
        let read: @MainActor () -> Probe
        let now: @MainActor () -> Duration
        let sleep: @MainActor (Duration) async throws -> Void
        let persist: @MainActor (Report) throws -> Void
    }

    enum VerificationError: Error {
        case invalidLimits
    }

    static func verify(
        processIdentifier: Int32,
        expectedAddress: String,
        limits: Limits = Limits(),
        operations: Operations
    ) async throws -> Report {
        guard limits.maximumAttempts >= limits.requiredConsecutiveMatches,
              limits.requiredConsecutiveMatches > 0,
              limits.timeout > .zero, limits.retryDelay > .zero else {
            throw VerificationError.invalidLimits
        }
        let origin = operations.now()
        let deadline = origin + limits.timeout
        var report = Report(
            mode: "read_only_active_tab_no_activation",
            processIdentifier: processIdentifier,
            expectedAddress: expectedAddress,
            maximumAttempts: limits.maximumAttempts,
            timeoutMilliseconds: milliseconds(limits.timeout),
            retryDelayMilliseconds: milliseconds(limits.retryDelay),
            requiredConsecutiveMatches: limits.requiredConsecutiveMatches
        )
        do {
            try operations.persist(report)
            for attempt in 1...limits.maximumAttempts {
                try Task.checkCancellation()
                let started = operations.now()
                guard started < deadline else {
                    report.activeTabStatus = .deadlineExceeded
                    try operations.persist(report)
                    return report
                }

                let probe = operations.read()
                let finished = operations.now()
                report.samples.append(Sample(
                    attempt: attempt,
                    startedMilliseconds: milliseconds(started - origin),
                    finishedMilliseconds: milliseconds(finished - origin),
                    probe: probe
                ))
                report.globalApplicationFocus = globalFocus(
                    in: report.samples, processIdentifier: processIdentifier
                )
                try Task.checkCancellation()

                // A synchronous AX read cannot be preempted by this loop. Its
                // result is retained, but never accepted after the deadline.
                if finished >= deadline {
                    report.activeTabStatus = .deadlineExceeded
                } else if probe.fatalError != nil {
                    report.activeTabStatus = .fatalRead
                } else if probe.contradictsExpectedAddress {
                    // A known wrong Chrome address is fatal regardless of which
                    // application currently owns global macOS focus.
                    report.activeTabStatus = .contradictoryAddress
                } else if probe.visibility.contradictsPreservation {
                    report.activeTabStatus = .contradictoryVisibility
                } else {
                    report.consecutiveMatches = probe.isExactActiveTab ? report.consecutiveMatches + 1 : 0
                    if report.consecutiveMatches >= limits.requiredConsecutiveMatches {
                        report.activeTabStatus = .confirmed
                    } else if attempt == limits.maximumAttempts {
                        report.activeTabStatus = .exhausted
                    }
                }

                // Every observed probe, including the terminal failure, is
                // durably recorded by the live adapter before another read.
                try operations.persist(report)
                if report.activeTabStatus != .inProgress { return report }
                let remaining = deadline - operations.now()
                if remaining > .zero {
                    try await operations.sleep(min(limits.retryDelay, remaining))
                }
            }
        } catch is CancellationError {
            report.activeTabStatus = .cancelled
            try operations.persist(report)
            throw CancellationError()
        }
        // The final attempt always sets a terminal status.
        report.activeTabStatus = .exhausted
        try operations.persist(report)
        return report
    }

    static func globalFocus(
        in samples: [Sample], processIdentifier: Int32
    ) -> GlobalApplicationFocus {
        var observed = [Bool]()
        var hasUnknown = false
        for sample in samples {
            let probe = sample.probe
            switch probe.focus {
            case .focused, .windowNotFocused:
                observed.append(true)
            case .applicationNotFocused:
                observed.append(false)
            case .notWindow, .unavailable:
                hasUnknown = true
            }
            if probe.frontmostReadAttempted {
                for application in [probe.frontmostBefore, probe.frontmostAfter] {
                    if let application {
                        observed.append(application.processIdentifier == processIdentifier)
                    } else {
                        hasUnknown = true
                    }
                }
            }
        }
        guard !observed.isEmpty else { return .unobserved }
        if observed.contains(true) && observed.contains(false) { return .mixed }
        if hasUnknown { return .incomplete }
        return observed[0] ? .frontmostAtAllSamples : .notFrontmostAtAllSamples
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}

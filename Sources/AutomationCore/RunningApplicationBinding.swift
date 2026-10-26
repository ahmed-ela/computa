import AppKit
import ApplicationServices
import Foundation

public struct RunningApplicationBinding: Sendable {
    public let application: ActivatedApplication
    public let window: ApplicationWindowObservation
}

public enum RunningApplicationBindingError: Error, Equatable, LocalizedError, Sendable {
    case invalidBundleIdentifier
    case notRunning
    case ambiguousApplications(Int)
    case processIdentityUnavailable
    case targetChanged

    public var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier: "An exact nonempty application bundle identifier is required."
        case .notRunning: "The requested application is not running. Open it yourself before binding; no application was launched."
        case let .ambiguousApplications(count): "The requested application has \(count) running matches. No process was selected."
        case .processIdentityUnavailable: "The running application's exact process and launch identity cannot be verified."
        case .targetChanged: "The running application or its selected window changed while binding. No activation or input was sent."
        }
    }
}

/// Read-only process discovery; intentionally has no launch, activation,
/// navigation, permission-request or input method.
@MainActor
protocol RunningApplicationBindingRuntime {
    func runningApplications(bundleIdentifier: String) throws -> [ApplicationWindowProcessState]
}

/// Binds to an existing app and exact app-selected AX window without affecting
/// OS foreground state. The returned window identity must still be validated
/// around subsequent reads/actions; binding is not an input authorization.
@MainActor
public final class RunningApplicationBinder {
    private let runtime: any RunningApplicationBindingRuntime
    private let accessibilityCheck: () -> Bool
    private let cancellationCheck: () throws -> Void
    private let resolveWindow: (Int32, String) throws -> ApplicationWindowObservation
    private let waitForWindowRetry: (Duration) async throws -> Void

    public init() {
        runtime = SystemRunningApplicationBindingRuntime()
        accessibilityCheck = { AXIsProcessTrusted() }
        cancellationCheck = { try Task.checkCancellation() }
        waitForWindowRetry = { try await Task.sleep(for: $0) }
        resolveWindow = { pid, bundle in
            try ApplicationWindowReader().selectedWindowObservation(
                processIdentifier: pid, expectedBundleIdentifier: bundle
            )
        }
    }

    init(
        runtime: any RunningApplicationBindingRuntime,
        accessibilityCheck: @escaping () -> Bool,
        cancellationCheck: @escaping () throws -> Void = { try Task.checkCancellation() },
        waitForWindowRetry: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        resolveWindow: @escaping (Int32, String) throws -> ApplicationWindowObservation
    ) {
        self.runtime = runtime
        self.accessibilityCheck = accessibilityCheck
        self.cancellationCheck = cancellationCheck
        self.waitForWindowRetry = waitForWindowRetry
        self.resolveWindow = resolveWindow
    }

    public func bind(bundleIdentifier: String) throws -> RunningApplicationBinding {
        let before = try initialTarget(bundleIdentifier: bundleIdentifier)
        let window = try resolveWindow(before.processIdentifier, bundleIdentifier)
        return try finishBinding(before: before, window: window, bundleIdentifier: bundleIdentifier)
    }

    /// Initial binding only: allow a briefly unavailable AX provider to settle.
    /// No activation, input, window guessing, or post-dispatch retargeting occurs.
    /// The original process generation is pinned across all three read attempts.
    public func bindWhenReady(bundleIdentifier: String) async throws -> RunningApplicationBinding {
        let before = try initialTarget(bundleIdentifier: bundleIdentifier)
        let delays: [Duration] = [.milliseconds(150), .milliseconds(300)]
        for attempt in 0...delays.count {
            try requireReadAccess()
            let window: ApplicationWindowObservation
            do {
                window = try resolveWindow(before.processIdentifier, bundleIdentifier)
            } catch {
                guard attempt < delays.count, Self.permitsInitialReadRetry(error) else { throw error }
                try requireReadAccess()
                try await waitForWindowRetry(delays[attempt])
                try requireReadAccess()
                let current = try select(bundleIdentifier: bundleIdentifier)
                guard sameProcess(before, current) else { throw RunningApplicationBindingError.targetChanged }
                continue
            }
            // Once an observation exists, any validation failure is terminal.
            // In particular, never retry into a different selected window.
            return try finishBinding(before: before, window: window, bundleIdentifier: bundleIdentifier)
        }
        preconditionFailure("The final read attempt must return or throw")
    }

    private static func permitsInitialReadRetry(_ error: Error) -> Bool {
        if let error = error as? ApplicationWindowReadError { return error.permitsInitialReadRetry }
        if case let AutomationError.accessibilityFailure(_, code) = error {
            return code == AXError.cannotComplete.rawValue
        }
        return false
    }

    private func sameProcess(_ lhs: ApplicationWindowProcessState, _ rhs: ApplicationWindowProcessState) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier
            && lhs.bundleIdentifier == rhs.bundleIdentifier && lhs.launchDate == rhs.launchDate
    }

    private func initialTarget(bundleIdentifier: String) throws -> ApplicationWindowProcessState {
        try cancellationCheck()
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
              !bundleIdentifier.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { throw RunningApplicationBindingError.invalidBundleIdentifier }
        try requireReadAccess()
        let before = try select(bundleIdentifier: bundleIdentifier)
        try requireReadAccess()
        return before
    }

    private func finishBinding(before: ApplicationWindowProcessState, window: ApplicationWindowObservation,
                               bundleIdentifier: String) throws -> RunningApplicationBinding {
        try requireReadAccess()
        let after = try select(bundleIdentifier: bundleIdentifier)
        guard sameProcess(before, after),
              window.info.processIdentifier == before.processIdentifier,
              window.info.bundleIdentifier == bundleIdentifier,
              window.identity.processIdentifier == before.processIdentifier,
              window.identity.bundleIdentifier == bundleIdentifier,
              try window.identity.isStillSelected() else {
            throw RunningApplicationBindingError.targetChanged
        }
        try requireReadAccess()
        return RunningApplicationBinding(
            application: ActivatedApplication(
                processIdentifier: before.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                localizedName: before.applicationName
            ),
            window: window
        )
    }

    private func requireReadAccess() throws {
        try cancellationCheck()
        guard accessibilityCheck() else { throw AutomationError.permissionNotGranted(.accessibility) }
    }

    private func select(bundleIdentifier: String) throws -> ApplicationWindowProcessState {
        let candidates = try runtime.runningApplications(bundleIdentifier: bundleIdentifier).filter {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
        guard !candidates.isEmpty else { throw RunningApplicationBindingError.notRunning }
        guard candidates.allSatisfy({ $0.processIdentifier > 0 }) else {
            throw RunningApplicationBindingError.processIdentityUnavailable
        }
        guard candidates.count == 1 else {
            throw RunningApplicationBindingError.ambiguousApplications(candidates.count)
        }
        let selected = candidates[0]
        guard let launchDate = selected.launchDate, launchDate.timeIntervalSince1970.isFinite else {
            throw RunningApplicationBindingError.processIdentityUnavailable
        }
        return selected
    }
}

@MainActor
private struct SystemRunningApplicationBindingRuntime: RunningApplicationBindingRuntime {
    func runningApplications(bundleIdentifier: String) throws -> [ApplicationWindowProcessState] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }.map {
            ApplicationWindowProcessState(
                processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                applicationName: $0.localizedName, launchDate: $0.launchDate, isTerminated: $0.isTerminated
            )
        }
    }
}

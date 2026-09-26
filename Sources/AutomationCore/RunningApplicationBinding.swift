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
    func chromeArguments(processIdentifier: Int32) throws -> [String]?
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

    public init() {
        runtime = SystemRunningApplicationBindingRuntime()
        accessibilityCheck = { AXIsProcessTrusted() }
        cancellationCheck = { try Task.checkCancellation() }
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
        resolveWindow: @escaping (Int32, String) throws -> ApplicationWindowObservation
    ) {
        self.runtime = runtime
        self.accessibilityCheck = accessibilityCheck
        self.cancellationCheck = cancellationCheck
        self.resolveWindow = resolveWindow
    }

    public func bind(bundleIdentifier: String) throws -> RunningApplicationBinding {
        try cancellationCheck()
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
              !bundleIdentifier.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { throw RunningApplicationBindingError.invalidBundleIdentifier }
        try requireReadAccess()
        let before = try select(bundleIdentifier: bundleIdentifier)
        try requireReadAccess()
        let window = try resolveWindow(before.processIdentifier, bundleIdentifier)
        try requireReadAccess()
        let after = try select(bundleIdentifier: bundleIdentifier)
        guard before.processIdentifier == after.processIdentifier,
              before.bundleIdentifier == after.bundleIdentifier,
              before.launchDate == after.launchDate,
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
        let selected: ApplicationWindowProcessState
        if bundleIdentifier == "com.google.Chrome" {
            // Reuse the existing ordinary-profile policy, including refusing
            // an uninspectable candidate beside an otherwise ordinary one.
            let chromeCandidates = try candidates.map {
                ExistingChromeCandidate(
                    processIdentifier: $0.processIdentifier,
                    arguments: try runtime.chromeArguments(processIdentifier: $0.processIdentifier)
                )
            }
            guard let pid = try ExistingChromeSelection.processIdentifier(in: chromeCandidates),
                  let match = candidates.first(where: { $0.processIdentifier == pid }) else {
                throw RunningApplicationBindingError.notRunning
            }
            selected = match
        } else {
            guard candidates.count == 1 else {
                throw RunningApplicationBindingError.ambiguousApplications(candidates.count)
            }
            selected = candidates[0]
        }
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

    func chromeArguments(processIdentifier: Int32) throws -> [String]? {
        // Existing argc-bounded reader discards environment and wipes its
        // temporary kernel buffer. No arguments are exposed in the result.
        ChromeProcessArguments.read(processIdentifier: processIdentifier)
    }
}

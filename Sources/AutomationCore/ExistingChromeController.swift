import AppKit
import ApplicationServices
import Darwin
import Foundation

public enum ExistingChromeError: Error, Equatable, LocalizedError {
    case processCannotBeInspected
    case noOrdinaryBrowser
    case ambiguousOrdinaryBrowsers
    case targetChanged
    case addressBarNotVerified
    case tabStateNotVerified
    case navigationRecoveryRequired
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .processCannotBeInspected:
            "Chrome's profile could not be verified. Open your normal Chrome window and try again."
        case .noOrdinaryBrowser:
            "Only automated or custom-profile Chrome instances are running. Open your normal Chrome window first."
        case .ambiguousOrdinaryBrowsers:
            "More than one ordinary Chrome process is running. Close the extra instance before trying again."
        case .targetChanged:
            "The selected Chrome process or focused window changed. Observe again before continuing."
        case .addressBarNotVerified:
            "Chrome's focused address bar could not be verified. No URL was submitted."
        case .tabStateNotVerified:
            "Chrome's exact newly selected tab could not be verified. No URL was submitted."
        case .navigationRecoveryRequired:
            "Chrome navigation could not be confirmed or recovered safely. Any tab already created was left open; no additional tab was opened or URL resubmitted during recovery. Stop retrying this navigation and inspect Chrome before continuing."
        case .invalidURL:
            "Chrome navigation requires a valid HTTP, HTTPS, or file URL."
        }
    }
}

/// No environment variables are retained. `arguments` is nil when the kernel's
/// argc-bounded argument block cannot be decoded, which is not permission to
/// treat an unknown Chrome process as the user's normal browser.
public struct ExistingChromeCandidate: Equatable, Sendable {
    public let processIdentifier: Int32
    public let arguments: [String]?

    public init(processIdentifier: Int32, arguments: [String]?) {
        self.processIdentifier = processIdentifier
        self.arguments = arguments
    }
}

public enum ExistingChromeSelection {
    /// nil means there is no running Chrome and a normal launch is permitted.
    /// If Chrome is already running, never silently substitute an isolated
    /// process or choose arbitrarily between multiple ordinary processes.
    public static func processIdentifier(in candidates: [ExistingChromeCandidate]) throws -> Int32? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.allSatisfy({ $0.processIdentifier > 0 && $0.arguments?.isEmpty == false }) else {
            throw ExistingChromeError.processCannotBeInspected
        }
        let ordinary = candidates.filter { candidate in
            !candidate.arguments!.contains { argument in
                argument == "--user-data-dir"
                    || argument.hasPrefix("--user-data-dir=")
                    || argument.hasPrefix("--remote-debugging")
            }
        }
        guard !ordinary.isEmpty else { throw ExistingChromeError.noOrdinaryBrowser }
        guard ordinary.count == 1 else { throw ExistingChromeError.ambiguousOrdinaryBrowsers }
        return ordinary[0].processIdentifier
    }
}

enum ChromeProcessArguments {
    /// KERN_PROCARGS2: argc, executable path, NUL padding, exactly argc
    /// NUL-terminated argv strings, then environment. Stop before environment.
    static func parse(_ bytes: [UInt8], validByteCount: Int? = nil) -> [String]? {
        let limit = validByteCount ?? bytes.count
        guard limit <= bytes.count, limit >= MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << ($1.offset * 8))
        }
        guard argc > 0, argc <= 4_096 else { return nil }
        var cursor = 4
        guard let executableEnd = bytes[cursor ..< limit].firstIndex(of: 0), executableEnd > cursor else { return nil }
        cursor = executableEnd + 1
        while cursor < limit, bytes[cursor] == 0 { cursor += 1 }
        var arguments = [String]()
        arguments.reserveCapacity(Int(argc))
        for _ in 0 ..< argc {
            guard cursor < limit,
                  let end = bytes[cursor ..< limit].firstIndex(of: 0),
                  let argument = String(bytes: bytes[cursor ..< end], encoding: .utf8) else { return nil }
            arguments.append(argument)
            cursor = end + 1
        }
        guard arguments.first?.isEmpty == false else { return nil }
        return arguments
    }

    static func read(processIdentifier: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        // macOS ARG_MAX is bounded; do not allocate based on untrusted process
        // content. Wipe the temporary kernel block, including any environment.
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var size = bytes.count
        let result = bytes.withUnsafeMutableBytes { storage in
            sysctl(&mib, u_int(mib.count), storage.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > 0, size <= bytes.count else { return nil }
        // Do not copy the whole block; parse it in place and only return argv.
        return parse(bytes, validByteCount: size)
    }
}

struct ExistingChromeTextRange: Equatable, Sendable {
    let location: Int
    let length: Int
}

@MainActor
struct ExistingChromeFocus {
    let processIdentifier: Int32
    let role: String?
    let identifier: String?
    let label: String?
    let value: String?
    let selectedTextRange: ExistingChromeTextRange?
    let isEditable: Bool
    let ancestorRoles: [String]
    let isSameWindow: () throws -> Bool
    let isSameControl: () throws -> Bool
    let setValue: (String) throws -> Void
    let tabs: () throws -> ExistingChromeTabInventory

    var isAddressBar: Bool {
        // The browser chrome must contain the text field, not web content.
        // The exact identifier/label is pinned to Chrome's native omnibox;
        // an arbitrary page field with the same visible name is insufficient.
        role == "AXTextField"
            && label == "Address and search bar"
            && isEditable
            && ancestorRoles.contains("AXToolbar")
            && !ancestorRoles.contains("AXWebArea")
            && !ancestorRoles.contains("AXDocument")
    }

    /// AX ranges use UTF-16 offsets, not Swift character counts. A selected
    /// history completion is safe to remove only when its entire unselected
    /// prefix is the exact requested destination and the selection ends at EOF.
    /// A prefix match, non-suffix selection, or absent selection is insufficient.
    func hasSelectedCompletionSuffix(after expectedValue: String) -> Bool {
        guard let value, let selectedTextRange,
              selectedTextRange.location == expectedValue.utf16.count,
              selectedTextRange.length > 0,
              selectedTextRange.location <= value.utf16.count,
              selectedTextRange.length == value.utf16.count - selectedTextRange.location else { return false }
        return value.utf16.prefix(selectedTextRange.location).elementsEqual(expectedValue.utf16)
    }
}

@MainActor
protocol ExistingChromeRuntime: AnyObject {
    func candidates() -> [ExistingChromeCandidate]
    func launch(beforeMutation: @escaping @Sendable () async throws -> Void) async throws -> ActivatedApplication
    func activate(_ processIdentifier: Int32, beforeMutation: @escaping @Sendable () async throws -> Void) async throws -> ActivatedApplication
    func focus(_ processIdentifier: Int32) throws -> ExistingChromeFocus
    func press(_ chord: KeyboardChord) throws
    func setAddressBar(_ focus: ExistingChromeFocus, to text: String) throws
    func pause() async throws
}

/// Opt-in test evidence only. Never includes text values, URLs, page content,
/// labels, process arguments, or identifiers from the user's browser.
public struct ExistingChromeFocusDiagnostic: Codable, Sendable {
    public let phase: String
    public let attempt: Int
    public let role: String
    public let labelMatchesAddressBar: Bool
    public let isEditable: Bool
    public let ancestorRoles: [String]
    public let valuePresent: Bool
    public let valueEmpty: Bool
    public let valueMatchesExpected: Bool
}

/// Uses the user's ordinary Chrome, never a disposable debugging profile. It
/// requires the existing Accessibility grant and changes no Chrome settings,
/// profile files, permissions, or remote-debugging flags.
@MainActor
public final class ExistingChromeController {
    private let runtime: any ExistingChromeRuntime
    private let diagnostics: (@Sendable (ExistingChromeFocusDiagnostic) -> Void)?
    private var pendingNavigation: PendingNavigation?

    /// Retained only by this controller, never persisted or rediscovered by a
    /// title/URL. The sentinel is recorded before Cmd+T, including when its
    /// delivery or resulting tab cannot be verified. A retry cannot open again.
    @MainActor
    private final class PendingNavigation {
        let application: ActivatedApplication
        let destination: String
        let originalWindow: ExistingChromeFocus
        let baselineTabs: ExistingChromeTabInventory
        var addressBar: ExistingChromeFocus?
        var newTab: (any ExistingChromeTabIdentity)?
        var didAttemptEntry = false
        var didAttemptCompletionRemoval = false
        var didAttemptReturn = false
        var recoveryAttempts = 0

        init(application: ActivatedApplication, destination: String,
             originalWindow: ExistingChromeFocus, baselineTabs: ExistingChromeTabInventory) {
            self.application = application
            self.destination = destination
            self.originalWindow = originalWindow
            self.baselineTabs = baselineTabs
        }
    }

    public var hasPendingNavigation: Bool { pendingNavigation != nil }

    public init(diagnostics: (@Sendable (ExistingChromeFocusDiagnostic) -> Void)? = nil) {
        runtime = SystemExistingChromeRuntime()
        self.diagnostics = diagnostics
    }
    init(runtime: any ExistingChromeRuntime) {
        self.runtime = runtime
        diagnostics = nil
    }

    /// Restores an already-bound ordinary Chrome process without selecting a
    /// replacement, launching Chrome, navigating, or posting keyboard input.
    /// Callers must still verify their retained window/control after activation.
    public func activate(
        processIdentifier: Int32,
        beforeMutation: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> ActivatedApplication {
        try Task.checkCancellation()
        guard processIdentifier > 0,
              try ExistingChromeSelection.processIdentifier(in: runtime.candidates()) == processIdentifier else {
            throw ExistingChromeError.targetChanged
        }
        try await beforeMutation()
        try Task.checkCancellation()
        guard try ExistingChromeSelection.processIdentifier(in: runtime.candidates()) == processIdentifier else {
            throw ExistingChromeError.targetChanged
        }
        let application = try await runtime.activate(processIdentifier, beforeMutation: beforeMutation)
        try Task.checkCancellation()
        guard application.processIdentifier == processIdentifier,
              application.bundleIdentifier == "com.google.Chrome",
              try ExistingChromeSelection.processIdentifier(in: runtime.candidates()) == processIdentifier else {
            throw ExistingChromeError.targetChanged
        }
        return application
    }

    public func open(
        url: URL? = nil,
        beforeMutation: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> ActivatedApplication {
        if let url {
            guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
                  url.absoluteString.count <= 8_192,
                  !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ExistingChromeError.invalidURL
            }
        }
        if let pendingNavigation {
            // Do not reinterpret a new destination, an unverified Return, or a
            // second retry as permission to discard the partial tab and start over.
            guard pendingNavigation.destination == url?.absoluteString,
                  !pendingNavigation.didAttemptReturn,
                  pendingNavigation.addressBar != nil, pendingNavigation.newTab != nil,
                  pendingNavigation.recoveryAttempts == 0 else {
                throw ExistingChromeError.navigationRecoveryRequired
            }
            pendingNavigation.recoveryAttempts += 1
            do {
                // The app's approval sheet may have taken focus between calls.
                // Restore only the retained ordinary PID, never launch or pick
                // another window/tab. finishNavigation rechecks the old handles.
                _ = try await activate(
                    processIdentifier: pendingNavigation.application.processIdentifier,
                    beforeMutation: beforeMutation
                )
                return try await finishNavigation(pendingNavigation, beforeMutation: beforeMutation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ExistingChromeError.navigationRecoveryRequired
            }
        }
        let selected = try ExistingChromeSelection.processIdentifier(in: runtime.candidates())
        let application: ActivatedApplication
        try Task.checkCancellation()
        try await beforeMutation()
        try Task.checkCancellation()
        guard try ExistingChromeSelection.processIdentifier(in: runtime.candidates()) == selected else {
            throw ExistingChromeError.targetChanged
        }
        if let selected {
            application = try await runtime.activate(selected, beforeMutation: beforeMutation)
            guard application.processIdentifier == selected else { throw ExistingChromeError.targetChanged }
        } else {
            application = try await runtime.launch(beforeMutation: beforeMutation)
        }
        try Task.checkCancellation()
        guard application.bundleIdentifier == "com.google.Chrome",
              try ExistingChromeSelection.processIdentifier(in: runtime.candidates()) == application.processIdentifier else {
            throw ExistingChromeError.targetChanged
        }
        guard let url else { return application }
        let processID = application.processIdentifier
        let original = try checkedFocus(processID)
        let baselineTabs = try original.tabs()
        try Task.checkCancellation()
        try await beforeMutation()
        try Task.checkCancellation()
        let beforeNewTab = try checkedFocus(processID)
        guard try original.isSameWindow(), try baselineTabs.isSame(as: beforeNewTab.tabs()) else {
            throw ExistingChromeError.targetChanged
        }
        let pending = PendingNavigation(
            application: application, destination: url.absoluteString,
            originalWindow: original, baselineTabs: baselineTabs
        )
        pendingNavigation = pending
        try runtime.press(KeyboardChord(keyCode: 17, modifiers: [.command])) // Cmd+T, never replace a user's tab.
        return try await finishNavigation(pending, beforeMutation: beforeMutation)
    }

    private func finishNavigation(
        _ pending: PendingNavigation,
        beforeMutation: @escaping @Sendable () async throws -> Void
    ) async throws -> ActivatedApplication {
        let processID = pending.application.processIdentifier
        if pending.addressBar == nil || pending.newTab == nil {
            let (addressBar, newTab) = try await waitForAddressBar(
                processID, window: pending.originalWindow, expectedValue: "", baselineTabs: pending.baselineTabs
            )
            pending.addressBar = addressBar
            pending.newTab = newTab
        }
        guard let addressBar = pending.addressBar, let newTab = pending.newTab else {
            throw ExistingChromeError.navigationRecoveryRequired
        }
        let text = pending.destination
        if !pending.didAttemptEntry {
            try Task.checkCancellation()
            try await beforeMutation()
            try Task.checkCancellation()
            let current = try checkAddressBarStillFocused(processID, original: addressBar, tab: newTab)
            guard current.value == "" else { throw ExistingChromeError.addressBarNotVerified }
            pending.didAttemptEntry = true
            try runtime.setAddressBar(addressBar, to: text)
        }
        try await waitForDestination(pending, beforeMutation: beforeMutation)
        try Task.checkCancellation()
        try await beforeMutation()
        try Task.checkCancellation()
        let current = try checkAddressBarStillFocused(processID, original: addressBar, tab: newTab)
        guard current.value == text else { throw ExistingChromeError.addressBarNotVerified }
        pending.didAttemptReturn = true
        try runtime.press(KeyboardChord(keyCode: 36, modifiers: []))
        pendingNavigation = nil
        return pending.application
    }

    private func waitForDestination(
        _ pending: PendingNavigation,
        beforeMutation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard let addressBar = pending.addressBar, let newTab = pending.newTab else {
            throw ExistingChromeError.navigationRecoveryRequired
        }
        let processID = pending.application.processIdentifier
        let text = pending.destination
        for attempt in 0 ..< 50 {
            try Task.checkCancellation()
            let current = try checkAddressBarStillFocused(processID, original: addressBar, tab: newTab)
            emitDiagnostic(current, expectedValue: text, attempt: attempt)
            if current.value == text { return }
            if !pending.didAttemptCompletionRemoval, current.hasSelectedCompletionSuffix(after: text) {
                try await beforeMutation()
                try Task.checkCancellation()
                // Permission approval can yield. Recheck the exact value and
                // selection as well as the original window/control/tab afterward.
                let verified = try checkAddressBarStillFocused(processID, original: addressBar, tab: newTab)
                guard verified.value == current.value,
                      verified.selectedTextRange == current.selectedTextRange,
                      verified.hasSelectedCompletionSuffix(after: text) else {
                    throw ExistingChromeError.addressBarNotVerified
                }
                pending.didAttemptCompletionRemoval = true
                try runtime.press(KeyboardChord(keyCode: 51, modifiers: [])) // Backspace only the proven selected suffix.
            }
            if attempt < 49 { try await runtime.pause() }
        }
        throw ExistingChromeError.addressBarNotVerified
    }

    private func checkedFocus(_ processID: Int32) throws -> ExistingChromeFocus {
        guard try ExistingChromeSelection.processIdentifier(in: runtime.candidates()) == processID else {
            throw ExistingChromeError.targetChanged
        }
        let focus = try runtime.focus(processID)
        guard focus.processIdentifier == processID, try focus.isSameWindow() else {
            throw ExistingChromeError.targetChanged
        }
        return focus
    }

    @discardableResult
    private func checkAddressBarStillFocused(
        _ processID: Int32, original: ExistingChromeFocus, tab: any ExistingChromeTabIdentity
    ) throws -> ExistingChromeFocus {
        let current = try checkedFocus(processID)
        guard current.isAddressBar, try original.isSameWindow(), try original.isSameControl(),
              try current.tabs().hasSelected(tab) else {
            throw ExistingChromeError.addressBarNotVerified
        }
        return current
    }

    private func waitForAddressBar(
        _ processID: Int32,
        window: ExistingChromeFocus,
        expectedValue: String,
        baselineTabs: ExistingChromeTabInventory? = nil,
        requiredTab: (any ExistingChromeTabIdentity)? = nil
    ) async throws -> (ExistingChromeFocus, any ExistingChromeTabIdentity) {
        var lastObservationError: Error?
        for attempt in 0 ..< 50 {
            try Task.checkCancellation()
            do {
                let current = try checkedFocus(processID)
                guard try window.isSameWindow() else { throw ExistingChromeError.targetChanged }
                emitDiagnostic(current, expectedValue: expectedValue, attempt: attempt)
                let inventory = try current.tabs()
                let tab = requiredTab ?? baselineTabs.flatMap { inventory.newlySelectedTab(since: $0) }
                if current.isAddressBar, current.value == expectedValue,
                   let tab, inventory.hasSelected(tab) { return (current, tab) }
                lastObservationError = nil
            } catch {
                // Cmd+T can temporarily rebuild focus. Settle reads only against
                // the original window/tab baseline; never repeat the key or
                // adopt replacement targets. Permission errors are not retried.
                let transient: Bool
                if let error = error as? ExistingChromeError {
                    transient = [.targetChanged, .addressBarNotVerified, .tabStateNotVerified].contains(error)
                } else if case AutomationError.accessibilityFailure(_, let code) = error {
                    transient = code == AXError.cannotComplete.rawValue
                } else { transient = false }
                guard baselineTabs != nil, transient else { throw error }
                lastObservationError = error
            }
            if attempt < 49 { try await runtime.pause() }
        }
        throw lastObservationError ?? ExistingChromeError.addressBarNotVerified
    }

    private func emitDiagnostic(_ current: ExistingChromeFocus, expectedValue: String, attempt: Int) {
        guard attempt == 0 || attempt == 49 else { return }
        let knownRoles: Set<String> = ["AXTextField", "AXComboBox", "AXGroup", "AXToolbar", "AXWindow", "AXWebArea", "AXDocument", "AXApplication"]
        diagnostics?(ExistingChromeFocusDiagnostic(
            phase: expectedValue.isEmpty ? "new_tab" : "typed_url", attempt: attempt,
            role: current.role.flatMap { knownRoles.contains($0) ? $0 : nil } ?? "other_or_missing",
            labelMatchesAddressBar: current.label == "Address and search bar", isEditable: current.isEditable,
            ancestorRoles: current.ancestorRoles.map { knownRoles.contains($0) ? $0 : "other" },
            valuePresent: current.value != nil, valueEmpty: current.value?.isEmpty == true,
            valueMatchesExpected: current.value == expectedValue
        ))
    }
}

/// A retained native window, not a bundle lookup or rediscovered label. The
/// runtime creates the handle only from the approved PID's focused/main window.
@MainActor
struct ExistingChromeActivationTarget {
    let application: ActivatedApplication
    let windowProcessIdentifier: Int32
    let windowRole: String?
    let isCurrent: () throws -> Bool
    let raise: () throws -> Void
    let makeFrontmost: () throws -> Void
    let isExactlyFocused: () throws -> Bool
}

@MainActor
enum ExistingChromeActivationRecovery {
    static func recover(
        processIdentifier: Int32,
        beforeMutation: @escaping @Sendable () async throws -> Void,
        permissionCheck: () -> Bool,
        resolve: () throws -> ExistingChromeActivationTarget,
        pause: () async throws -> Void
    ) async throws -> ActivatedApplication {
        try Task.checkCancellation()
        guard permissionCheck() else { throw AutomationError.permissionNotGranted(.accessibility) }
        let target = try resolve()
        guard target.application.processIdentifier == processIdentifier,
              target.application.bundleIdentifier == "com.google.Chrome",
              target.windowProcessIdentifier == processIdentifier,
              target.windowRole == "AXWindow" else { throw ExistingChromeError.targetChanged }
        for operation in [target.raise, target.makeFrontmost] {
            try await beforeMutation()
            try Task.checkCancellation()
            guard permissionCheck() else { throw AutomationError.permissionNotGranted(.accessibility) }
            guard try target.isCurrent() else { throw ExistingChromeError.targetChanged }
            try operation()
        }
        for attempt in 0 ..< 100 {
            try Task.checkCancellation()
            guard permissionCheck() else { throw AutomationError.permissionNotGranted(.accessibility) }
            guard try target.isCurrent() else { throw ExistingChromeError.targetChanged }
            if try target.isExactlyFocused() { return target.application }
            if attempt < 99 { try await pause() }
        }
        throw ComputerInputError.applicationActivationFailed(processIdentifier: processIdentifier)
    }
}

@MainActor
private final class SystemExistingChromeRuntime: ExistingChromeRuntime {
    private let controller = ComputerInputController()

    func candidates() -> [ExistingChromeCandidate] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated
        }.map {
            ExistingChromeCandidate(
                processIdentifier: $0.processIdentifier,
                arguments: ChromeProcessArguments.read(processIdentifier: $0.processIdentifier)
            )
        }
    }

    func launch(beforeMutation: @escaping @Sendable () async throws -> Void) async throws -> ActivatedApplication {
        do {
            return try await controller.launchOrActivateApplication(bundleIdentifier: "com.google.Chrome")
        } catch ComputerInputError.applicationActivationFailed(let processIdentifier) {
            return try await recoverActivation(processIdentifier, beforeMutation: beforeMutation)
        }
    }

    func activate(
        _ processIdentifier: Int32,
        beforeMutation: @escaping @Sendable () async throws -> Void
    ) async throws -> ActivatedApplication {
        do {
            return try await controller.activateApplication(processIdentifier: processIdentifier)
        } catch ComputerInputError.applicationActivationFailed(let failedPID) where failedPID == processIdentifier {
            return try await recoverActivation(processIdentifier, beforeMutation: beforeMutation)
        }
    }

    private func recoverActivation(
        _ processIdentifier: Int32,
        beforeMutation: @escaping @Sendable () async throws -> Void
    ) async throws -> ActivatedApplication {
        try await ExistingChromeActivationRecovery.recover(
            processIdentifier: processIdentifier,
            beforeMutation: beforeMutation,
            permissionCheck: { AXIsProcessTrusted() },
            resolve: { [self] in
                guard try ExistingChromeSelection.processIdentifier(in: candidates()) == processIdentifier,
                      let running = NSRunningApplication(processIdentifier: processIdentifier),
                      running.bundleIdentifier == "com.google.Chrome", !running.isTerminated else {
                    throw ExistingChromeError.targetChanged
                }
                let application = AXUIElementCreateApplication(processIdentifier)
                guard let window = element(application, kAXFocusedWindowAttribute)
                    ?? element(application, kAXMainWindowAttribute),
                      let windowPID = pid(window) else { throw ExistingChromeError.targetChanged }
                let target = ActivatedApplication(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: "com.google.Chrome",
                    localizedName: running.localizedName
                )
                return ExistingChromeActivationTarget(
                    application: target,
                    windowProcessIdentifier: windowPID,
                    windowRole: string(window, kAXRoleAttribute),
                    isCurrent: { [self] in
                        guard try ExistingChromeSelection.processIdentifier(in: candidates()) == processIdentifier,
                              !running.isTerminated,
                              pid(window) == processIdentifier,
                              string(window, kAXRoleAttribute) == "AXWindow",
                              let current = element(application, kAXFocusedWindowAttribute)
                                ?? element(application, kAXMainWindowAttribute) else { return false }
                        return CFEqual(window, current)
                    },
                    raise: {
                        var rawActions: CFArray?
                        guard AXUIElementCopyActionNames(window, &rawActions) == .success,
                              let actions = rawActions as? [String],
                              actions.contains(kAXRaiseAction as String),
                              AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
                            throw ComputerInputError.applicationActivationFailed(processIdentifier: processIdentifier)
                        }
                    },
                    makeFrontmost: {
                        guard AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success else {
                            throw ComputerInputError.applicationActivationFailed(processIdentifier: processIdentifier)
                        }
                    },
                    isExactlyFocused: { [self] in
                        guard running.isActive,
                              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
                              let focused = element(application, kAXFocusedWindowAttribute) else { return false }
                        return CFEqual(window, focused)
                    }
                )
            },
            pause: { try await Task.sleep(for: .milliseconds(20)) }
        )
    }

    func press(_ chord: KeyboardChord) throws { try controller.pressKeyChord(chord) }
    func setAddressBar(_ focus: ExistingChromeFocus, to text: String) throws {
        guard AXIsProcessTrusted() else { throw AutomationError.permissionNotGranted(.accessibility) }
        guard try ExistingChromeSelection.processIdentifier(in: candidates()) == focus.processIdentifier,
              focus.isAddressBar, try focus.isSameWindow(), try focus.isSameControl() else {
            throw ExistingChromeError.addressBarNotVerified
        }
        try focus.setValue(text)
    }
    func pause() async throws { try await Task.sleep(for: .milliseconds(20)) }

    func focus(_ processIdentifier: Int32) throws -> ExistingChromeFocus {
        guard let observation = try FocusedWindowReader().focusedWindowObservation(),
              observation.info.processIdentifier == processIdentifier,
              observation.info.bundleIdentifier == "com.google.Chrome" else {
            throw ExistingChromeError.targetChanged
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let control = element(application, kAXFocusedUIElementAttribute),
              pid(control) == processIdentifier else {
            throw ExistingChromeError.addressBarNotVerified
        }
        var ancestorRoles = [String]()
        var current = control
        var reachedWindow = false
        var retainedWindow: AXUIElement?
        for _ in 0 ..< 24 {
            guard let parent = element(current, kAXParentAttribute), pid(parent) == processIdentifier else { break }
            guard let role = string(parent, kAXRoleAttribute) else { break }
            ancestorRoles.append(role)
            if role == "AXWindow" { reachedWindow = true; retainedWindow = parent; break }
            current = parent
        }
        if !reachedWindow { ancestorRoles = [] }
        let identity = observation.identity
        var isEditable = DarwinBoolean(false)
        let editableResult = AXUIElementIsAttributeSettable(control, kAXValueAttribute as CFString, &isEditable)
        let role = string(control, kAXRoleAttribute)
        let identifier = string(control, kAXIdentifierAttribute)
        let label = string(control, kAXDescriptionAttribute) ?? string(control, kAXTitleAttribute)
        let value = string(control, kAXValueAttribute)
        let selectedTextRange = textRange(control)
        guard try identity.isStillFocused(), try identity.isSameFocusedUIElement(),
              let currentControl = element(application, kAXFocusedUIElementAttribute),
              CFEqual(control, currentControl) else {
            throw ExistingChromeError.targetChanged
        }
        return ExistingChromeFocus(
            processIdentifier: processIdentifier,
            role: role,
            identifier: identifier,
            label: label,
            value: value,
            selectedTextRange: selectedTextRange,
            isEditable: editableResult == .success && isEditable.boolValue,
            ancestorRoles: ancestorRoles,
            isSameWindow: { try identity.isStillFocused() },
            isSameControl: { try identity.isSameFocusedUIElement() },
            setValue: { [self] text in
                guard AXIsProcessTrusted() else { throw AutomationError.permissionNotGranted(.accessibility) }
                guard try identity.isStillFocused(), try identity.isSameFocusedUIElement(),
                      pid(control) == processIdentifier else { throw ExistingChromeError.targetChanged }
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(control, kAXValueAttribute as CFString, &settable) == .success,
                      settable.boolValue,
                      AXUIElementSetAttributeValue(control, kAXValueAttribute as CFString, text as CFString) == .success else {
                    throw ExistingChromeError.addressBarNotVerified
                }
            },
            tabs: {
                guard let retainedWindow else { throw ExistingChromeError.targetChanged }
                return try NativeChromeTabReadRecovery.read(
                    isSameWindow: { try identity.isStillFocused() },
                    traverse: {
                        try NativeChromeTabInventory.read(window: retainedWindow, processIdentifier: processIdentifier)
                    }
                )
            }
        )
    }

    private func pid(_ element: AXUIElement) -> Int32? {
        var result: pid_t = 0
        return AXUIElementGetPid(element, &result) == .success ? result : nil
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func textRange(_ element: AXUIElement) -> ExistingChromeTextRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return ExistingChromeTextRange(location: range.location, length: range.length)
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

import Foundation
import XCTest
@testable import AutomationCore

final class ExistingChromeControllerTests: XCTestCase {
    func testSelectionUsesOrdinaryProcessNotIsolatedProcess() throws {
        XCTAssertEqual(try ExistingChromeSelection.processIdentifier(in: [
            candidate(41, ["chrome", "--user-data-dir=/tmp/LocalCodexBrowserBroker-test"]),
            candidate(42, ["chrome"]),
            candidate(43, ["chrome", "--remote-debugging-port=9222"]),
        ]), 42)
    }

    func testSelectionRejectsEveryKnownAutomationFlagForm() {
        for arguments in [
            ["chrome", "--user-data-dir", "/tmp/custom"],
            ["chrome", "--user-data-dir=/tmp/custom"],
            ["chrome", "--remote-debugging-port=0"],
            ["chrome", "--remote-debugging-pipe"],
            ["chrome", "--remote-debugging-address=127.0.0.1"],
        ] {
            XCTAssertThrowsError(try ExistingChromeSelection.processIdentifier(in: [candidate(41, arguments)])) {
                XCTAssertEqual($0 as? ExistingChromeError, .noOrdinaryBrowser)
            }
        }
    }

    func testUninspectableCandidateCannotBeIgnoredBesideOrdinaryChrome() {
        for arguments: [String]? in [nil, []] {
            XCTAssertThrowsError(try ExistingChromeSelection.processIdentifier(in: [
                candidate(41, arguments), candidate(42, ["chrome"]),
            ])) {
                XCTAssertEqual($0 as? ExistingChromeError, .processCannotBeInspected)
            }
        }
    }

    func testSelectionFailsClosedOnAmbiguousOrdinaryProcesses() {
        XCTAssertThrowsError(try ExistingChromeSelection.processIdentifier(in: [
            candidate(41, ["chrome"]), candidate(42, ["chrome"]),
        ])) {
            XCTAssertEqual($0 as? ExistingChromeError, .ambiguousOrdinaryBrowsers)
        }
    }

    func testOnlyNoRunningChromePermitsNormalLaunch() throws {
        XCTAssertNil(try ExistingChromeSelection.processIdentifier(in: []))
        XCTAssertThrowsError(try ExistingChromeSelection.processIdentifier(in: [candidate(0, ["chrome"])]))
    }

    func testKernelArgumentParserStopsBeforeEnvironment() {
        let arguments = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--flag=hello world", ""]
        var bytes = argumentBlock(arguments)
        bytes += Array("SECRET_TOKEN=not-returned\0--user-data-dir=/not-an-argument\0".utf8)
        XCTAssertEqual(ChromeProcessArguments.parse(bytes), arguments)
    }

    func testKernelArgumentParserHandlesPaddingAndSeparatedFlags() {
        let arguments = ["chrome", "--user-data-dir", "/tmp/custom profile"]
        XCTAssertEqual(ChromeProcessArguments.parse(argumentBlock(arguments)), arguments)
    }

    func testKernelArgumentParserRejectsTruncationInvalidUTF8AndAbsurdCounts() {
        XCTAssertNil(ChromeProcessArguments.parse([]))
        XCTAssertNil(ChromeProcessArguments.parse([0, 0, 0, 0]))
        XCTAssertNil(ChromeProcessArguments.parse([255, 255, 255, 255]))
        var truncated = argumentBlock(["chrome"])
        truncated.removeLast()
        XCTAssertNil(ChromeProcessArguments.parse(truncated))
        var malformed = argumentBlock(["chrome"])
        malformed[malformed.count - 2] = 255
        XCTAssertNil(ChromeProcessArguments.parse(malformed))
        let valid = argumentBlock(["chrome"])
        XCTAssertNil(ChromeProcessArguments.parse(valid + [0, 0], validByteCount: valid.count - 1))
    }

    @MainActor
    func testNoURLActivatesExactOrdinaryProcessWithoutKeyboardInput() async throws {
        let runtime = ChromeRuntimeFixture()
        runtime.processes.append(candidate(91, ["chrome", "--user-data-dir=/tmp/owned"]))
        let result = try await ExistingChromeController(runtime: runtime).open()
        XCTAssertEqual(result.processIdentifier, 42)
        XCTAssertEqual(runtime.actions, ["activate:42"])
    }

    @MainActor
    func testNormalLaunchRevalidatesReturnedProcess() async throws {
        let runtime = ChromeRuntimeFixture()
        runtime.processes = []
        let result = try await ExistingChromeController(runtime: runtime).open()
        XCTAssertEqual(result.processIdentifier, 42)
        XCTAssertEqual(runtime.actions, ["launch"])
    }

    @MainActor
    func testUnexpectedIsolatedLaunchCannotBecomeBoundUserBrowser() async {
        let runtime = ChromeRuntimeFixture()
        runtime.processes = []
        runtime.launchedArguments = ["chrome", "--user-data-dir=/tmp/unexpected"]
        await assertFailure(.noOrdinaryBrowser) { try await ExistingChromeController(runtime: runtime).open() }
        XCTAssertEqual(runtime.actions, ["launch"])
    }

    @MainActor
    func testURLUsesNewTabThenVerifiedAddressBarThenReturn() async throws {
        let runtime = ChromeRuntimeFixture()
        _ = try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command", "set-address-bar:https://example.com", "key:36:"])
    }

    @MainActor
    func testPageFieldSpoofCannotReceiveURL() async {
        let runtime = ChromeRuntimeFixture()
        runtime.ancestorRoles = ["AXWebArea", "AXGroup", "AXToolbar", "AXWindow"]
        await assertFailure(.addressBarNotVerified) {
            try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
        }
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
    }

    @MainActor
    func testMissingToolbarUnknownLabelAndReadOnlyFieldRejectNavigation() async {
        for kind in 0 ..< 3 {
            let runtime = ChromeRuntimeFixture()
            if kind == 0 { runtime.ancestorRoles = ["AXGroup", "AXWindow"] }
            if kind == 1 { runtime.label = "Search" }
            if kind == 2 { runtime.isEditable = false }
            await assertFailure(.addressBarNotVerified) {
                try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
            }
            XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
        }
    }

    @MainActor
    func testFailedNewTabCannotOverwriteNonemptyAddressBar() async {
        let runtime = ChromeRuntimeFixture()
        runtime.value = "https://untouched.example"
        runtime.newTabSucceeds = false
        await assertFailure(.addressBarNotVerified) {
            try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
        }
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
    }

    @MainActor
    func testNoOpNewTabWithInitiallyEmptyAddressBarCannotOverwriteExistingTab() async {
        let runtime = ChromeRuntimeFixture()
        runtime.newTabSucceeds = false
        await assertFailure(.addressBarNotVerified) {
            try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
        }
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
    }

    @MainActor
    func testNewTabInventoryRejectsLostOldTabTwoNewTabsAndWrongSelection() async {
        for kind in 0 ..< 3 {
            let runtime = ChromeRuntimeFixture()
            runtime.loseOldTabAfterNewTab = kind == 0
            runtime.createTwoTabs = kind == 1
            runtime.selectOldTabAfterNewTab = kind == 2
            await assertFailure(.addressBarNotVerified) {
                try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
            }
            XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
        }
    }

    @MainActor
    func testNewTabReadSettlingDoesNotRepeatAnyMutation() async throws {
        let runtime = ChromeRuntimeFixture()
        runtime.transientReadsAfterNewTab = 2
        _ = try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
        XCTAssertEqual(runtime.pauseCount, 2)
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command", "set-address-bar:https://example.com", "key:36:"])
    }

    @MainActor
    func testPermissionDenialDuringNewTabSettlingIsNeverRetried() async {
        let runtime = ChromeRuntimeFixture()
        runtime.denyPermissionAfterNewTab = true
        do {
            _ = try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
            XCTFail("Expected permission failure")
        } catch { XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility)) }
        XCTAssertEqual(runtime.pauseCount, 0)
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
    }

    @MainActor
    func testSameOmniboxOnDifferentSelectedTabCannotSubmit() async {
        let runtime = ChromeRuntimeFixture()
        runtime.selectOldTabAfterEntry = true
        await assertFailure(.addressBarNotVerified) {
            try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
        }
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command", "set-address-bar:https://example.com"])
    }

    @MainActor
    func testChangedFocusBeforeTypingPreventsInput() async {
        let runtime = ChromeRuntimeFixture()
        runtime.loseFocusAfterNewTab = true
        await assertFailure(.targetChanged) {
            try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
        }
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
    }

    @MainActor
    func testChangedControlAfterSemanticEntryNeverSubmits() async {
        let runtime = ChromeRuntimeFixture()
        runtime.changeControlAfterEntry = true
        await assertFailure(.addressBarNotVerified) {
            try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com/semantic-entry")!)
        }
        XCTAssertEqual(runtime.actions.count, 3)
        XCTAssertFalse(runtime.actions.contains("key:36:"))
    }

    @MainActor
    func testAddressBarValueMismatchPreventsReturn() async {
        let runtime = ChromeRuntimeFixture()
        runtime.dropEnteredText = true
        await assertFailure(.addressBarNotVerified) {
            try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!)
        }
        XCTAssertFalse(runtime.actions.contains("key:36:"))
    }

    @MainActor
    func testCancellationCallbackRunsBeforeEveryMutation() async throws {
        let runtime = ChromeRuntimeFixture()
        let gate = ChromeMutationGate(failAt: 3)
        do {
            _ = try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com")!) {
                try await gate.check()
            }
            XCTFail("Expected cancellation before URL entry")
        } catch is CancellationError {
            XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
        }
        let calls = await gate.calls
        XCTAssertEqual(calls, 3)
    }

    @MainActor
    func testCallbackCancelsTaskWithoutThrowingStillPreventsActivation() async {
        let runtime = ChromeRuntimeFixture()
        let task = Task { @MainActor in
            try await ExistingChromeController(runtime: runtime).open {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { XCTAssertEqual(runtime.actions, []) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testCancellationDuringActivationCannotReturnSuccessfulBinding() async {
        let runtime = ChromeRuntimeFixture()
        runtime.cancelDuringActivation = true
        let task = Task { @MainActor in try await ExistingChromeController(runtime: runtime).open() }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { XCTAssertEqual(runtime.actions, ["activate:42"]) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testInvalidURLDoesNotActivateOrLaunch() async {
        let runtime = ChromeRuntimeFixture()
        await assertFailure(.invalidURL) {
            try await ExistingChromeController(runtime: runtime).open(url: URL(string: "javascript:alert(1)")!)
        }
        XCTAssertEqual(runtime.actions, [])
    }

    @MainActor
    func testActivationRecoveryRaisesOnlyExactOwnedWindowThenVerifiesFocus() async throws {
        let fixture = ChromeActivationFixture()
        let result = try await fixture.recover()
        XCTAssertEqual(result.processIdentifier, 42)
        XCTAssertEqual(fixture.actions, ["raise:42", "frontmost:42"])
    }

    @MainActor
    func testActivationRecoveryRejectsWrongOwnerOrNonWindowBeforeMutation() async {
        for badOwner in [true, false] {
            let fixture = ChromeActivationFixture()
            if badOwner { fixture.windowPID = 99 } else { fixture.role = "AXGroup" }
            await assertFailure(.targetChanged) { try await fixture.recover() }
            XCTAssertEqual(fixture.actions, [])
        }
    }

    @MainActor
    func testActivationRecoveryStopsWhenWindowChangesAfterRaise() async {
        let fixture = ChromeActivationFixture()
        fixture.changeWindowAfterRaise = true
        await assertFailure(.targetChanged) { try await fixture.recover() }
        XCTAssertEqual(fixture.actions, ["raise:42"])
    }

    @MainActor
    func testActivationRecoveryPermissionRevocationPreventsNextMutation() async {
        let fixture = ChromeActivationFixture()
        fixture.revokePermissionAfterRaise = true
        do { _ = try await fixture.recover(); XCTFail("Expected permission refusal") }
        catch { XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility)) }
        XCTAssertEqual(fixture.actions, ["raise:42"])
    }

    @MainActor
    func testActivationRecoveryCannotClaimSuccessWithoutExactFocus() async {
        let fixture = ChromeActivationFixture()
        fixture.focusSucceeds = false
        do { _ = try await fixture.recover(); XCTFail("Expected activation failure") }
        catch { XCTAssertEqual(error as? ComputerInputError, .applicationActivationFailed(processIdentifier: 42)) }
        XCTAssertEqual(fixture.actions, ["raise:42", "frontmost:42"])
    }

    private func candidate(_ pid: Int32, _ arguments: [String]?) -> ExistingChromeCandidate {
        ExistingChromeCandidate(processIdentifier: pid, arguments: arguments)
    }

    private func argumentBlock(_ arguments: [String]) -> [UInt8] {
        let count = UInt32(arguments.count)
        var bytes = (0 ..< 4).map { UInt8((count >> ($0 * 8)) & 255) }
        bytes += Array("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\0\0\0".utf8)
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        return bytes
    }

    @MainActor
    private func assertFailure(
        _ expected: ExistingChromeError,
        operation: () async throws -> ActivatedApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do { _ = try await operation(); XCTFail("Expected failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? ExistingChromeError, expected, file: file, line: line) }
    }
}

private actor ChromeMutationGate {
    private let failAt: Int
    private(set) var calls = 0
    init(failAt: Int) { self.failAt = failAt }
    func check() throws {
        calls += 1
        if calls == failAt { throw CancellationError() }
    }
}

@MainActor
private final class ChromeActivationFixture {
    var windowPID: Int32 = 42
    var role = "AXWindow"
    var actions = [String]()
    var permission = true
    var current = true
    var focused = false
    var focusSucceeds = true
    var changeWindowAfterRaise = false
    var revokePermissionAfterRaise = false

    func recover() async throws -> ActivatedApplication {
        try await ExistingChromeActivationRecovery.recover(
            processIdentifier: 42,
            beforeMutation: {},
            permissionCheck: { self.permission },
            resolve: {
                ExistingChromeActivationTarget(
                    application: ActivatedApplication(processIdentifier: 42, bundleIdentifier: "com.google.Chrome", localizedName: "Chrome"),
                    windowProcessIdentifier: self.windowPID, windowRole: self.role,
                    isCurrent: { self.current },
                    raise: {
                        self.actions.append("raise:42")
                        if self.changeWindowAfterRaise { self.current = false }
                        if self.revokePermissionAfterRaise { self.permission = false }
                    },
                    makeFrontmost: { self.actions.append("frontmost:42"); self.focused = self.focusSucceeds },
                    isExactlyFocused: { self.focused }
                )
            },
            pause: {}
        )
    }
}

@MainActor
private final class ChromeRuntimeFixture: ExistingChromeRuntime {
    var processes = [ExistingChromeCandidate(processIdentifier: 42, arguments: ["chrome"])]
    var launchedArguments = ["chrome"]
    var actions = [String]()
    var value = ""
    var label = "Address and search bar"
    var isEditable = true
    var ancestorRoles = ["AXGroup", "AXToolbar", "AXGroup", "AXWindow"]
    var newTabSucceeds = true
    var loseFocusAfterNewTab = false
    var changeControlAfterEntry = false
    var dropEnteredText = false
    var cancelDuringActivation = false
    var loseOldTabAfterNewTab = false
    var createTwoTabs = false
    var selectOldTabAfterNewTab = false
    var selectOldTabAfterEntry = false
    var transientReadsAfterNewTab = 0
    var denyPermissionAfterNewTab = false
    var pauseCount = 0
    private var focusPresent = true
    private var controlGeneration = 0
    private var remainingTransientReads = 0
    private var newTabWasRequested = false
    private var tabHandles = [ChromeTabFixture(1)]
    private var selectedTab = ChromeTabFixture(1)

    func candidates() -> [ExistingChromeCandidate] { processes }
    func launch(beforeMutation: @escaping @Sendable () async throws -> Void) async throws -> ActivatedApplication {
        actions.append("launch")
        processes = [ExistingChromeCandidate(processIdentifier: 42, arguments: launchedArguments)]
        return application
    }
    func activate(_ processIdentifier: Int32, beforeMutation: @escaping @Sendable () async throws -> Void) async throws -> ActivatedApplication {
        actions.append("activate:\(processIdentifier)")
        if cancelDuringActivation { withUnsafeCurrentTask { $0?.cancel() } }
        return application
    }
    func focus(_ processIdentifier: Int32) throws -> ExistingChromeFocus {
        if newTabWasRequested, denyPermissionAfterNewTab { throw AutomationError.permissionNotGranted(.accessibility) }
        if remainingTransientReads > 0 {
            remainingTransientReads -= 1
            throw ExistingChromeError.targetChanged
        }
        let generation = controlGeneration
        return ExistingChromeFocus(
            processIdentifier: focusPresent ? processIdentifier : 99,
            role: "AXTextField", identifier: nil, label: label, value: value,
            isEditable: isEditable, ancestorRoles: ancestorRoles,
            isSameWindow: { self.focusPresent },
            isSameControl: { self.controlGeneration == generation },
            setValue: { self.value = $0 },
            tabs: { ExistingChromeTabInventory(tabs: self.tabHandles, selected: self.selectedTab) }
        )
    }
    func press(_ chord: KeyboardChord) throws {
        actions.append("key:\(chord.keyCode):\(chord.modifiers.map(\.rawValue).joined(separator: ","))")
        if chord.keyCode == 17 {
            newTabWasRequested = true
            remainingTransientReads = transientReadsAfterNewTab
            if newTabSucceeds {
                value = ""; controlGeneration += 1
                let added = ChromeTabFixture(2)
                tabHandles.append(added)
                selectedTab = added
                if loseOldTabAfterNewTab { tabHandles.removeFirst() }
                if createTwoTabs { tabHandles.append(ChromeTabFixture(3)) }
                if selectOldTabAfterNewTab { selectedTab = ChromeTabFixture(1) }
            }
            if loseFocusAfterNewTab { focusPresent = false }
        }
    }
    func setAddressBar(_ focus: ExistingChromeFocus, to text: String) throws {
        actions.append("set-address-bar:\(text)")
        if !dropEnteredText { value = text }
        if changeControlAfterEntry { controlGeneration += 1 }
        if selectOldTabAfterEntry { selectedTab = ChromeTabFixture(1) }
    }
    func pause() async throws { pauseCount += 1 }
    private var application: ActivatedApplication {
        ActivatedApplication(processIdentifier: 42, bundleIdentifier: "com.google.Chrome", localizedName: "Google Chrome")
    }
}

@MainActor
private final class ChromeTabFixture: ExistingChromeTabIdentity {
    private let id: Int
    init(_ id: Int) { self.id = id }
    func isSame(as other: any ExistingChromeTabIdentity) -> Bool {
        (other as? ChromeTabFixture)?.id == id
    }
}

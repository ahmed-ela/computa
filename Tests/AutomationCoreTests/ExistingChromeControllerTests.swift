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
    func testBoundActivationUsesExactOrdinaryPIDWithoutLaunchingOrPostingInput() async throws {
        let runtime = ChromeRuntimeFixture()
        runtime.processes.append(candidate(91, ["chrome", "--user-data-dir=/tmp/owned"]))
        let gate = ChromeMutationGate(failAt: 99)
        let result = try await ExistingChromeController(runtime: runtime).activate(processIdentifier: 42) {
            try await gate.check()
        }
        XCTAssertEqual(result.processIdentifier, 42)
        XCTAssertEqual(runtime.actions, ["activate:42"])
        let checks = await gate.calls
        XCTAssertEqual(checks, 1)
    }

    @MainActor
    func testBoundActivationNeverLaunchesOrSubstitutesAnotherProcess() async {
        for processes in [[], [candidate(43, ["chrome"])]] {
            let runtime = ChromeRuntimeFixture()
            runtime.processes = processes
            await assertFailure(.targetChanged) {
                try await ExistingChromeController(runtime: runtime).activate(processIdentifier: 42)
            }
            XCTAssertEqual(runtime.actions, [])
        }
    }

    @MainActor
    func testBoundActivationRejectsIsolatedAmbiguousAndUnknownProcessesBeforeMutation() async {
        let cases: [([ExistingChromeCandidate], ExistingChromeError)] = [
            ([candidate(42, ["chrome", "--remote-debugging-port=9222"])], .noOrdinaryBrowser),
            ([candidate(42, ["chrome"]), candidate(43, ["chrome"])], .ambiguousOrdinaryBrowsers),
            ([candidate(42, nil)], .processCannotBeInspected),
        ]
        for (processes, error) in cases {
            let runtime = ChromeRuntimeFixture()
            runtime.processes = processes
            await assertFailure(error) {
                try await ExistingChromeController(runtime: runtime).activate(processIdentifier: 42)
            }
            XCTAssertEqual(runtime.actions, [])
        }
    }

    @MainActor
    func testBoundActivationRevalidatesAfterMutationGate() async {
        let runtime = ChromeRuntimeFixture()
        await assertFailure(.targetChanged) {
            try await ExistingChromeController(runtime: runtime).activate(processIdentifier: 42) {
                await MainActor.run { runtime.processes = [] }
            }
        }
        XCTAssertEqual(runtime.actions, [])
    }

    @MainActor
    func testBoundActivationForwardsGateToRecoveryAndStopsOnRevocation() async {
        let runtime = ChromeRuntimeFixture()
        runtime.checkGateDuringActivation = true
        let gate = ChromeMutationGate(failAt: 2)
        do {
            _ = try await ExistingChromeController(runtime: runtime).activate(processIdentifier: 42) {
                try await gate.check()
            }
            XCTFail("Expected mutation gate rejection")
        } catch is CancellationError {
            XCTAssertEqual(runtime.actions, [])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let checks = await gate.calls
        XCTAssertEqual(checks, 2)
    }

    @MainActor
    func testBoundActivationRejectsChangedReturnedIdentityOrCandidate() async {
        for kind in 0 ..< 3 {
            let runtime = ChromeRuntimeFixture()
            if kind == 0 { runtime.activatedProcessIdentifier = 43 }
            if kind == 1 { runtime.activatedBundleIdentifier = "com.example.other" }
            if kind == 2 { runtime.processesAfterActivation = [candidate(43, ["chrome"])] }
            await assertFailure(.targetChanged) {
                try await ExistingChromeController(runtime: runtime).activate(processIdentifier: 42)
            }
            XCTAssertEqual(runtime.actions, ["activate:42"])
        }
    }

    @MainActor
    func testBoundActivationCannotSucceedAfterCancellationDuringActivation() async {
        let runtime = ChromeRuntimeFixture()
        runtime.cancelDuringActivation = true
        let task = Task { @MainActor in
            try await ExistingChromeController(runtime: runtime).activate(processIdentifier: 42)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { XCTAssertEqual(runtime.actions, ["activate:42"]) }
        catch { XCTFail("Unexpected error: \(error)") }
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
    func testSelectedHistorySuffixIsRemovedOnceBeforeExactDestinationIsSubmitted() async throws {
        for destination in [
            "https://www.youtube.com/", "https://example.com/path", "https://example.com/search?q=one",
            "https://example.com/#section", "https://example.com/caf%C3%A9", "file:///tmp/example.html",
        ] {
            let runtime = ChromeRuntimeFixture()
            runtime.enteredSuffix = "history-completion"
            let controller = ExistingChromeController(runtime: runtime)
            _ = try await controller.open(url: URL(string: destination)!)
            XCTAssertEqual(runtime.value, destination)
            XCTAssertEqual(runtime.actions, [
                "activate:42", "key:17:command", "set-address-bar:\(destination)", "key:51:", "key:36:",
            ])
            XCTAssertFalse(controller.hasPendingNavigation)
        }
    }

    @MainActor
    func testCompletionSuffixRequiresExactUTF16PrefixAndRange() throws {
        let runtime = ChromeRuntimeFixture()
        let expected = "https://example.com/😀e\u{301}"
        let suffix = "🧭history"
        runtime.value = expected + suffix
        runtime.selectedTextRange = ExistingChromeTextRange(location: expected.utf16.count, length: suffix.utf16.count)
        XCTAssertTrue(try runtime.focus(42).hasSelectedCompletionSuffix(after: expected))
        // Swift strings can compare canonically equal while AX byte offsets differ.
        XCTAssertFalse(try runtime.focus(42).hasSelectedCompletionSuffix(after: "https://example.com/😀é"))
        for range in [
            ExistingChromeTextRange(location: expected.count, length: suffix.count),
            ExistingChromeTextRange(location: -1, length: 1),
            ExistingChromeTextRange(location: expected.utf16.count, length: Int.max),
            ExistingChromeTextRange(location: Int.max, length: 1),
            ExistingChromeTextRange(location: 0, length: runtime.value.utf16.count),
        ] {
            runtime.selectedTextRange = range
            XCTAssertFalse(try runtime.focus(42).hasSelectedCompletionSuffix(after: expected))
        }
        runtime.value = "https://different.example/" + suffix
        runtime.selectedTextRange = ExistingChromeTextRange(location: expected.utf16.count, length: suffix.utf16.count)
        XCTAssertFalse(try runtime.focus(42).hasSelectedCompletionSuffix(after: expected))
    }

    @MainActor
    func testCompletionIsNeverSubmittedOrDeletedWithoutExactSuffixSelection() async {
        let destination = "https://example.com/"
        for kind in 0 ..< 5 {
            let runtime = ChromeRuntimeFixture()
            runtime.enteredSuffix = "history"
            if kind == 0 { runtime.omitCompletionSelection = true }
            if kind == 1 { runtime.completionRangeOverride = ExistingChromeTextRange(location: 0, length: destination.utf16.count + 7) }
            if kind == 2 { runtime.completionRangeOverride = ExistingChromeTextRange(location: destination.utf16.count, length: 0) }
            if kind == 3 { runtime.completionRangeOverride = ExistingChromeTextRange(location: destination.utf16.count, length: 3) }
            if kind == 4 { runtime.completionRangeOverride = ExistingChromeTextRange(location: destination.utf16.count - 1, length: 8) }
            await assertFailure(.addressBarNotVerified) {
                try await ExistingChromeController(runtime: runtime).open(url: URL(string: destination)!)
            }
            XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command", "set-address-bar:\(destination)"])
        }
    }

    @MainActor
    func testCompletionRemovalRevalidatesSelectionValueAndIdentityAfterApproval() async {
        for kind in 0 ..< 6 {
            let runtime = ChromeRuntimeFixture()
            runtime.enteredSuffix = "history"
            do {
                _ = try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com/")!) {
                    await MainActor.run {
                        runtime.mutationGateCalls += 1
                        if runtime.mutationGateCalls == 4 {
                            switch kind {
                            case 0: runtime.selectedTextRange = nil
                            case 1: runtime.value += "changed"
                            case 2: runtime.changeFocusedControl()
                            case 3: runtime.selectOriginalTab()
                            case 4: runtime.processes = [ExistingChromeCandidate(processIdentifier: 99, arguments: ["chrome"])]
                            default: runtime.removeFocus()
                            }
                        }
                    }
                }
                XCTFail("Expected changed-target refusal")
            } catch {
                guard let chromeError = error as? ExistingChromeError else {
                    XCTFail("Unexpected error: \(error)")
                    continue
                }
                XCTAssertTrue([ExistingChromeError.addressBarNotVerified, .targetChanged].contains(chromeError))
            }
            XCTAssertFalse(runtime.actions.contains("key:51:"))
            XCTAssertFalse(runtime.actions.contains("key:36:"))
        }
    }

    @MainActor
    func testCancellationBeforeCompletionRemovalPreventsDeleteAndReturn() async {
        let runtime = ChromeRuntimeFixture()
        runtime.enteredSuffix = "history"
        let gate = ChromeMutationGate(failAt: 4)
        do {
            _ = try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com/")!) {
                try await gate.check()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(runtime.actions.contains("key:51:"))
        XCTAssertFalse(runtime.actions.contains("key:36:"))
    }

    @MainActor
    func testFailedCompletionRemovalIsNotRepeatedAcrossBoundedRecovery() async {
        let runtime = ChromeRuntimeFixture()
        runtime.enteredSuffix = "history"
        runtime.deleteLeavesCompletion = true
        let controller = ExistingChromeController(runtime: runtime)
        let url = URL(string: "https://example.com/")!
        await assertFailure(.addressBarNotVerified) { try await controller.open(url: url) }
        XCTAssertTrue(controller.hasPendingNavigation)
        await assertFailure(.navigationRecoveryRequired) { try await controller.open(url: url) }
        let actionsAfterRecovery = runtime.actions
        await assertFailure(.navigationRecoveryRequired) { try await controller.open(url: url) }
        XCTAssertEqual(runtime.actions, actionsAfterRecovery)
        XCTAssertEqual(runtime.actions.filter { $0 == "key:17:command" }.count, 1)
        XCTAssertEqual(runtime.actions.filter { $0 == "key:51:" }.count, 1)
        XCTAssertFalse(runtime.actions.contains("key:36:"))
    }

    @MainActor
    func testChangedTabOrControlAfterDeletionNeverSubmits() async {
        for kind in 0 ..< 2 {
            let runtime = ChromeRuntimeFixture()
            runtime.enteredSuffix = "history"
            runtime.changeControlAfterDelete = kind == 0
            runtime.selectOldTabAfterDelete = kind == 1
            await assertFailure(.addressBarNotVerified) {
                try await ExistingChromeController(runtime: runtime).open(url: URL(string: "https://example.com/")!)
            }
            XCTAssertTrue(runtime.actions.contains("key:51:"))
            XCTAssertFalse(runtime.actions.contains("key:36:"))
        }
    }

    @MainActor
    func testRecoveryUsesRetainedTabWithoutRepeatingEntryOrNewTab() async throws {
        let runtime = ChromeRuntimeFixture()
        runtime.enteredSuffix = "history"
        runtime.omitCompletionSelection = true
        let controller = ExistingChromeController(runtime: runtime)
        let destination = "https://example.com/"
        await assertFailure(.addressBarNotVerified) { try await controller.open(url: URL(string: destination)!) }
        runtime.selectedTextRange = ExistingChromeTextRange(location: destination.utf16.count, length: 7)
        _ = try await controller.open(url: URL(string: destination)!)
        XCTAssertEqual(runtime.actions, [
            "activate:42", "key:17:command", "set-address-bar:\(destination)", "activate:42", "key:51:", "key:36:",
        ])
        XCTAssertFalse(controller.hasPendingNavigation)
    }

    @MainActor
    func testRecoveryRestoresRetainedPIDAfterApprovalTakesFocus() async throws {
        let runtime = ChromeRuntimeFixture()
        runtime.enteredSuffix = "history"
        runtime.omitCompletionSelection = true
        let controller = ExistingChromeController(runtime: runtime)
        let destination = "https://example.com/"
        await assertFailure(.addressBarNotVerified) { try await controller.open(url: URL(string: destination)!) }
        runtime.removeFocus()
        runtime.restoreFocusOnActivation = true
        runtime.selectedTextRange = ExistingChromeTextRange(location: destination.utf16.count, length: 7)
        _ = try await controller.open(url: URL(string: destination)!)
        XCTAssertEqual(runtime.actions.filter { $0 == "activate:42" }.count, 2)
        XCTAssertEqual(runtime.actions.filter { $0 == "key:17:command" }.count, 1)
        XCTAssertEqual(runtime.actions.filter { $0 == "key:36:" }.count, 1)
    }

    @MainActor
    func testAmbiguousTabCreationCannotOpenAnotherTabOnRecovery() async {
        let runtime = ChromeRuntimeFixture()
        runtime.createTwoTabs = true
        let controller = ExistingChromeController(runtime: runtime)
        let url = URL(string: "https://example.com/")!
        await assertFailure(.addressBarNotVerified) { try await controller.open(url: url) }
        await assertFailure(.navigationRecoveryRequired) { try await controller.open(url: url) }
        XCTAssertEqual(runtime.actions, ["activate:42", "key:17:command"])
    }

    @MainActor
    func testRetainedNavigationCannotRecoverOnDifferentTabWindowOrDestination() async {
        for kind in 0 ..< 4 {
            let runtime = ChromeRuntimeFixture()
            runtime.dropEnteredText = true
            let controller = ExistingChromeController(runtime: runtime)
            let url = URL(string: "https://example.com/")!
            await assertFailure(.addressBarNotVerified) { try await controller.open(url: url) }
            let beforeRecovery = runtime.actions
            if kind == 0 { runtime.selectOriginalTab() }
            if kind == 1 { runtime.removeFocus() }
            let recoveryURL = kind == 2 ? URL(string: "https://other.example/") : kind == 3 ? nil : url
            await assertFailure(.navigationRecoveryRequired) { try await controller.open(url: recoveryURL) }
            XCTAssertEqual(runtime.actions, beforeRecovery + (kind < 2 ? ["activate:42"] : []))
        }
    }

    @MainActor
    func testUncertainReturnDeliveryNeverSubmitsAgain() async {
        let runtime = ChromeRuntimeFixture()
        runtime.failAfterReturn = true
        let controller = ExistingChromeController(runtime: runtime)
        let url = URL(string: "https://example.com/")!
        await assertFailure(.targetChanged) { try await controller.open(url: url) }
        await assertFailure(.navigationRecoveryRequired) { try await controller.open(url: url) }
        XCTAssertEqual(runtime.actions.filter { $0 == "key:17:command" }.count, 1)
        XCTAssertEqual(runtime.actions.filter { $0 == "key:36:" }.count, 1)
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
    var selectedTextRange: ExistingChromeTextRange?
    var enteredSuffix: String?
    var completionRangeOverride: ExistingChromeTextRange?
    var omitCompletionSelection = false
    var deleteLeavesCompletion = false
    var changeControlAfterDelete = false
    var selectOldTabAfterDelete = false
    var failAfterReturn = false
    var mutationGateCalls = 0
    var restoreFocusOnActivation = false
    var label = "Address and search bar"
    var isEditable = true
    var ancestorRoles = ["AXGroup", "AXToolbar", "AXGroup", "AXWindow"]
    var newTabSucceeds = true
    var loseFocusAfterNewTab = false
    var changeControlAfterEntry = false
    var dropEnteredText = false
    var cancelDuringActivation = false
    var checkGateDuringActivation = false
    var activatedProcessIdentifier: Int32 = 42
    var activatedBundleIdentifier = "com.google.Chrome"
    var processesAfterActivation: [ExistingChromeCandidate]?
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
        if checkGateDuringActivation { try await beforeMutation() }
        actions.append("activate:\(processIdentifier)")
        if restoreFocusOnActivation { focusPresent = true }
        if cancelDuringActivation { withUnsafeCurrentTask { $0?.cancel() } }
        if let processesAfterActivation { processes = processesAfterActivation }
        return ActivatedApplication(
            processIdentifier: activatedProcessIdentifier,
            bundleIdentifier: activatedBundleIdentifier,
            localizedName: "Google Chrome"
        )
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
            selectedTextRange: selectedTextRange,
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
        if chord.keyCode == 51 {
            if !deleteLeavesCompletion, let selectedTextRange {
                value = String(decoding: value.utf16.prefix(selectedTextRange.location), as: UTF16.self)
                self.selectedTextRange = nil
            }
            if changeControlAfterDelete { controlGeneration += 1 }
            if selectOldTabAfterDelete { selectedTab = ChromeTabFixture(1) }
        }
        if chord.keyCode == 36, failAfterReturn { throw ExistingChromeError.targetChanged }
    }
    func setAddressBar(_ focus: ExistingChromeFocus, to text: String) throws {
        actions.append("set-address-bar:\(text)")
        if !dropEnteredText { value = text }
        if let enteredSuffix {
            value = text + enteredSuffix
            selectedTextRange = omitCompletionSelection ? nil : completionRangeOverride
                ?? ExistingChromeTextRange(location: text.utf16.count, length: enteredSuffix.utf16.count)
        }
        if changeControlAfterEntry { controlGeneration += 1 }
        if selectOldTabAfterEntry { selectedTab = ChromeTabFixture(1) }
    }
    func pause() async throws { pauseCount += 1 }
    func changeFocusedControl() { controlGeneration += 1 }
    func selectOriginalTab() { selectedTab = ChromeTabFixture(1) }
    func removeFocus() { focusPresent = false }
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

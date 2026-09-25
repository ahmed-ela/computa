import ApplicationServices
import XCTest
@testable import AutomationCore

@MainActor
final class ExistingChromeTabInventoryTests: XCTestCase {
    func testFlatStripRemainsValid() {
        var topology = NativeChromeTabTopology()
        topology.observe(role: "AXTabGroup", inTabGroup: false)
        topology.observe(role: "AXRadioButton", inTabGroup: true)
        topology.observe(role: "AXRadioButton", inTabGroup: true, selected: true)
        XCTAssertTrue(topology.isSingleCompleteStrip)
    }

    func testMeasuredVerticalStripWithNestedGroupAndTenTabsIsValid() {
        var topology = NativeChromeTabTopology()
        topology.observe(role: "AXTabGroup", inTabGroup: false)
        for index in 0..<9 {
            topology.observe(role: "AXRadioButton", inTabGroup: true, selected: index == 8)
        }
        topology.observe(role: "AXTabGroup", inTabGroup: true)
        topology.observe(role: "AXRadioButton", inTabGroup: true)
        XCTAssertTrue(topology.isSingleCompleteStrip)
    }

    func testSelectionInsideNestedGroupIsValidWithinOneStrip() {
        var topology = NativeChromeTabTopology()
        topology.observe(role: "AXTabGroup", inTabGroup: false)
        topology.observe(role: "AXGroup", inTabGroup: true)
        topology.observe(role: "AXTabGroup", inTabGroup: true)
        topology.observe(role: "AXTabGroup", inTabGroup: true)
        topology.observe(role: "AXRadioButton", inTabGroup: true, selected: true)
        XCTAssertTrue(topology.isSingleCompleteStrip)
    }

    func testPeerTopLevelStripsAreRejectedEvenWithOnlyOneSelectedTab() {
        var topology = NativeChromeTabTopology()
        topology.observe(role: "AXTabGroup", inTabGroup: false)
        topology.observe(role: "AXRadioButton", inTabGroup: true, selected: true)
        topology.observe(role: "AXTabGroup", inTabGroup: false)
        topology.observe(role: "AXTabGroup", inTabGroup: true)
        topology.observe(role: "AXRadioButton", inTabGroup: true)
        XCTAssertFalse(topology.isSingleCompleteStrip)
    }

    func testOutsideGroupRadioIsRejectedBesideAnOtherwiseValidStrip() {
        for outsideSelected in [false, true] {
            var topology = NativeChromeTabTopology()
            topology.observe(role: "AXTabGroup", inTabGroup: false)
            topology.observe(role: "AXRadioButton", inTabGroup: true, selected: true)
            topology.observe(role: "AXRadioButton", inTabGroup: false, selected: outsideSelected)
            XCTAssertFalse(topology.isSingleCompleteStrip)
        }
    }

    func testMissingRootStripOrTabsCannotPass() {
        var missingRoot = NativeChromeTabTopology()
        missingRoot.observe(role: "AXTabGroup", inTabGroup: true)
        missingRoot.observe(role: "AXRadioButton", inTabGroup: true, selected: true)
        XCTAssertFalse(missingRoot.isSingleCompleteStrip)
        var missingTabs = NativeChromeTabTopology()
        missingTabs.observe(role: "AXTabGroup", inTabGroup: false)
        missingTabs.observe(role: "AXTabGroup", inTabGroup: true)
        XCTAssertFalse(missingTabs.isSingleCompleteStrip)
    }

    func testMissingOrMultipleSelectedTabsAreRejectedAcrossNestedGroups() {
        for selectedCount in [0, 2] {
            var topology = NativeChromeTabTopology()
            topology.observe(role: "AXTabGroup", inTabGroup: false)
            topology.observe(role: "AXRadioButton", inTabGroup: true, selected: selectedCount > 0)
            topology.observe(role: "AXTabGroup", inTabGroup: true)
            topology.observe(role: "AXRadioButton", inTabGroup: true, selected: selectedCount > 1)
            XCTAssertFalse(topology.isSingleCompleteStrip)
        }
    }

    func testDuplicateRetainedTabIdentityCannotPassAnyInventoryGuard() {
        let first = TabIdentity(1)
        let duplicate = TabIdentity(1)
        let added = TabIdentity(2)
        let before = ExistingChromeTabInventory(tabs: [first], selected: first)
        let repeated = ExistingChromeTabInventory(tabs: [first, duplicate], selected: duplicate)
        XCTAssertFalse(repeated.isSame(as: repeated))
        XCTAssertFalse(repeated.hasSelected(first))
        XCTAssertNil(repeated.newlySelectedTab(since: before))
        let after = ExistingChromeTabInventory(tabs: [first, duplicate, added], selected: added)
        XCTAssertNil(after.newlySelectedTab(since: repeated))
    }

    func testNewTabDeltaStillRequiresEveryOldIdentityAndOneNewSelectedIdentity() throws {
        let first = TabIdentity(1)
        let grouped = TabIdentity(2)
        let added = TabIdentity(3)
        let before = ExistingChromeTabInventory(tabs: [first, grouped], selected: grouped)
        let after = ExistingChromeTabInventory(tabs: [grouped, first, added], selected: added)
        let newTab = try XCTUnwrap(after.newlySelectedTab(since: before))
        XCTAssertTrue(newTab.isSame(as: added))
        XCTAssertTrue(after.hasSelected(newTab))
        XCTAssertTrue(before.isSame(as: ExistingChromeTabInventory(tabs: [grouped, first], selected: grouped)))
    }

    func testSameCountReplacementOfOldTabCannotMasqueradeAsOneNewTab() {
        let first = TabIdentity(1)
        let second = TabIdentity(2)
        let before = ExistingChromeTabInventory(tabs: [first, second], selected: second)
        let replacement = TabIdentity(99)
        let added = TabIdentity(3)
        let after = ExistingChromeTabInventory(tabs: [first, replacement, added], selected: added)
        XCTAssertNil(after.newlySelectedTab(since: before))
        XCTAssertFalse(before.isSame(as: ExistingChromeTabInventory(tabs: [first, replacement], selected: replacement)))
    }

    func testExtraNewTabsOrSelectionOfAnOldTabAreRejected() {
        let old = TabIdentity(1)
        let added = TabIdentity(2)
        let before = ExistingChromeTabInventory(tabs: [old], selected: old)
        XCTAssertNil(ExistingChromeTabInventory(tabs: [old, added], selected: old).newlySelectedTab(since: before))
        XCTAssertNil(ExistingChromeTabInventory(tabs: [old, added, TabIdentity(3)], selected: added)
            .newlySelectedTab(since: before))
        XCTAssertFalse(ExistingChromeTabInventory(tabs: [old], selected: added).hasSelected(added))
    }

    func testStableReadChecksSameWindowBeforeAndAfterWithoutRetry() throws {
        let tab = TabIdentity(1)
        let expected = ExistingChromeTabInventory(tabs: [tab], selected: tab)
        var events = [String]()
        let actual = try NativeChromeTabReadRecovery.read(
            isSameWindow: { events.append("focus"); return true },
            traverse: { events.append("read"); return expected }
        )
        XCTAssertTrue(actual.isSame(as: expected))
        XCTAssertEqual(events, ["focus", "read", "focus"])
    }

    func testInvalidDescendantRetriesWholeReadOnceWithExactFocusChecks() throws {
        let tab = TabIdentity(1)
        let expected = ExistingChromeTabInventory(tabs: [tab], selected: tab)
        var reads = 0
        var events = [String]()
        let actual = try NativeChromeTabReadRecovery.read(
            isSameWindow: { events.append("focus"); return true },
            traverse: {
                reads += 1
                events.append("read")
                if reads == 1 {
                    throw AutomationError.accessibilityFailure(
                        operation: "AXRole", code: AXError.invalidUIElement.rawValue
                    )
                }
                return expected
            }
        )
        XCTAssertTrue(actual.isSame(as: expected))
        XCTAssertEqual(events, ["focus", "read", "focus", "read", "focus"])
    }

    func testPersistentInvalidDescendantStopsAfterTwoReads() {
        var reads = 0
        XCTAssertThrowsError(try NativeChromeTabReadRecovery.read(
            isSameWindow: { true },
            traverse: {
                reads += 1
                throw AutomationError.accessibilityFailure(
                    operation: "AXRole", code: AXError.invalidUIElement.rawValue
                )
            }
        )) { error in
            guard case AutomationError.accessibilityFailure("AXRole", AXError.invalidUIElement.rawValue) = error else {
                return XCTFail("Expected original invalid descendant error, got \(error)")
            }
        }
        XCTAssertEqual(reads, 2)
    }

    func testUnrelatedFailuresNeverRetryTabTraversal() {
        let errors: [Error] = [
            AutomationError.permissionNotGranted(.accessibility),
            AutomationError.accessibilityFailure(operation: "AXRole", code: AXError.cannotComplete.rawValue),
            ExistingChromeError.targetChanged,
            ExistingChromeError.tabStateNotVerified,
        ]
        for expected in errors {
            var reads = 0
            XCTAssertThrowsError(try NativeChromeTabReadRecovery.read(
                isSameWindow: { true },
                traverse: { reads += 1; throw expected }
            )) { error in
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
            }
            XCTAssertEqual(reads, 1)
        }
    }

    func testFocusLossBeforeEitherTraversalOrAfterSuccessFailsClosed() {
        let tab = TabIdentity(1)
        let inventory = ExistingChromeTabInventory(tabs: [tab], selected: tab)
        // Fail before the first read, before retry, or after either successful
        // read. No replacement window is adopted in any of these cases.
        for scenario in [(retry: false, lostAt: 1, reads: 0),
                         (retry: false, lostAt: 2, reads: 1),
                         (retry: true, lostAt: 2, reads: 1),
                         (retry: true, lostAt: 3, reads: 2)] {
            var checks = 0
            var reads = 0
            XCTAssertThrowsError(try NativeChromeTabReadRecovery.read(
                isSameWindow: { checks += 1; return checks != scenario.lostAt },
                traverse: {
                    reads += 1
                    if scenario.retry, reads == 1 {
                        throw AutomationError.accessibilityFailure(
                            operation: "AXRole", code: AXError.invalidUIElement.rawValue
                        )
                    }
                    return inventory
                }
            )) { error in
                XCTAssertEqual(error as? ExistingChromeError, .targetChanged)
            }
            XCTAssertEqual(reads, scenario.reads)
        }
    }

    func testFocusCheckErrorIsNeverTreatedAsAnInvalidDescendantRetry() {
        var checks = 0
        var reads = 0
        XCTAssertThrowsError(try NativeChromeTabReadRecovery.read(
            isSameWindow: {
                checks += 1
                throw AutomationError.accessibilityFailure(
                    operation: "focus", code: AXError.invalidUIElement.rawValue
                )
            },
            traverse: {
                reads += 1
                throw ExistingChromeError.tabStateNotVerified
            }
        ))
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(reads, 0)
    }
}

@MainActor
private final class TabIdentity: ExistingChromeTabIdentity {
    private let id: Int
    init(_ id: Int) { self.id = id }
    func isSame(as other: any ExistingChromeTabIdentity) -> Bool { (other as? TabIdentity)?.id == id }
}

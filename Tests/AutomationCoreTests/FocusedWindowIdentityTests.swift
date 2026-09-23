import ApplicationServices
import XCTest
@testable import AutomationCore

final class FocusedWindowIdentityTests: XCTestCase {
    @MainActor
    func testSameAXWindowRemainsFocused() throws {
        let window = AXUIElementCreateApplication(41_001)
        var current = FocusedWindowElements(processIdentifier: 77, window: window)
        let reader = FocusedWindowReader(
            accessibilityCheck: { true },
            focusedElements: { current }
        )

        let identity = try XCTUnwrap(reader.focusedWindowIdentity())
        XCTAssertEqual(identity.processIdentifier, 77)
        XCTAssertTrue(try identity.isStillFocused())

        // AX creates new wrapper objects when an element is looked up again;
        // CFEqual must recognize the same underlying AX element.
        current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_001)
        )
        XCTAssertTrue(try identity.isStillFocused())
    }

    @MainActor
    func testReplacementAXWindowWithSameProcessIsRejected() throws {
        var current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_001)
        )
        let reader = FocusedWindowReader(
            accessibilityCheck: { true },
            focusedElements: { current }
        )
        let identity = try XCTUnwrap(reader.focusedWindowIdentity())

        // The fake deliberately keeps the same process metadata. Only the
        // opaque AX window identity changes, as can happen during navigation.
        current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_002)
        )
        XCTAssertFalse(try identity.isStillFocused())
    }

    @MainActor
    func testChangedProcessOrMissingFocusIsRejected() throws {
        var current: FocusedWindowElements? = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_001)
        )
        let reader = FocusedWindowReader(
            accessibilityCheck: { true },
            focusedElements: { current }
        )
        let identity = try XCTUnwrap(reader.focusedWindowIdentity())

        current = FocusedWindowElements(
            processIdentifier: 78,
            window: AXUIElementCreateApplication(41_001)
        )
        XCTAssertFalse(try identity.isStillFocused())
        current = nil
        XCTAssertFalse(try identity.isStillFocused())
    }

    @MainActor
    func testPermissionIsRecheckedWhenIdentityIsCompared() throws {
        var trusted = true
        var lookups = 0
        let reader = FocusedWindowReader(
            accessibilityCheck: { trusted },
            focusedElements: {
                lookups += 1
                return FocusedWindowElements(
                    processIdentifier: 77,
                    window: AXUIElementCreateApplication(41_001)
                )
            }
        )
        let identity = try XCTUnwrap(reader.focusedWindowIdentity())
        XCTAssertEqual(lookups, 1)

        trusted = false
        XCTAssertThrowsError(try identity.isStillFocused()) { error in
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertEqual(lookups, 1)
    }

    @MainActor
    func testFocusedControlIdentityRejectsRetargetingWithinSameWindow() throws {
        let window = AXUIElementCreateApplication(41_001)
        let control = AXUIElementCreateApplication(42_001)
        var current = FocusedWindowElements(
            processIdentifier: 77,
            window: window,
            focusedUIElement: control
        )
        let reader = FocusedWindowReader(
            accessibilityCheck: { true },
            focusedElements: { current }
        )
        let identity = try XCTUnwrap(reader.focusedWindowIdentity())

        current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_001),
            focusedUIElement: AXUIElementCreateApplication(42_001)
        )
        XCTAssertTrue(try identity.isSameFocusedUIElement())

        current = FocusedWindowElements(
            processIdentifier: 77,
            window: window,
            focusedUIElement: AXUIElementCreateApplication(42_002)
        )
        XCTAssertTrue(try identity.isStillFocused())
        XCTAssertFalse(try identity.isSameFocusedUIElement())
    }

    @MainActor
    func testKeyboardFocusIdentityRejectsMissingControlAndChangedWindow() throws {
        var current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_001),
            focusedUIElement: AXUIElementCreateApplication(42_001)
        )
        let reader = FocusedWindowReader(
            accessibilityCheck: { true },
            focusedElements: { current }
        )
        let identity = try XCTUnwrap(reader.focusedWindowIdentity())

        current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_001)
        )
        XCTAssertFalse(try identity.isSameFocusedUIElement())

        current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_002),
            focusedUIElement: AXUIElementCreateApplication(42_001)
        )
        XCTAssertFalse(try identity.isSameFocusedUIElement())

        let replacementWindowIdentity = try XCTUnwrap(reader.focusedWindowIdentity())
        XCTAssertTrue(try replacementWindowIdentity.isSameFocusedUIElement())
        current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_002)
        )
        XCTAssertFalse(try replacementWindowIdentity.isSameFocusedUIElement())

        let identityWithoutControl = try XCTUnwrap(reader.focusedWindowIdentity())
        current = FocusedWindowElements(
            processIdentifier: 77,
            window: AXUIElementCreateApplication(41_002),
            focusedUIElement: AXUIElementCreateApplication(42_001)
        )
        XCTAssertFalse(try identityWithoutControl.isSameFocusedUIElement())
    }
}

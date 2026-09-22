import ApplicationServices
import CoreFoundation
import XCTest
@testable import AutomationCore

final class FakeAXRuntime: AXRuntime {
    var actions = [String]()
    var performedActions = [String]()
    var settable = true
    var setAttributes = [String]()

    func actionNames(for element: AXUIElement) throws -> [String] {
        actions
    }

    func perform(action: String, on element: AXUIElement) throws {
        performedActions.append(action)
    }

    func isAttributeSettable(_ attribute: String, on element: AXUIElement) throws -> Bool {
        settable
    }

    func set(value: CFTypeRef, for attribute: String, on element: AXUIElement) throws {
        setAttributes.append(attribute)
    }
}

final class AXElementControllerTests: XCTestCase {
    private let inertElement = AXUIElementCreateApplication(getpid())

    func testPerformsOnlySupportedSemanticAction() throws {
        let runtime = FakeAXRuntime()
        runtime.actions = [SemanticAXAction.press.rawValue]
        let controller = AXElementController(runtime: runtime, accessibilityCheck: { true })

        try controller.perform(.press, on: inertElement)

        XCTAssertEqual(runtime.performedActions, ["AXPress"])
    }

    func testRejectsUnsupportedActionBeforeRuntimeMutation() {
        let runtime = FakeAXRuntime()
        let controller = AXElementController(runtime: runtime, accessibilityCheck: { true })

        XCTAssertThrowsError(try controller.perform(.showMenu, on: inertElement)) { error in
            XCTAssertEqual(error as? AutomationError, .unsupportedAction("AXShowMenu"))
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }

    func testSetValueChecksSettableFirst() throws {
        let runtime = FakeAXRuntime()
        let controller = AXElementController(runtime: runtime, accessibilityCheck: { true })

        try controller.setValue("replacement", on: inertElement)

        XCTAssertEqual(runtime.setAttributes, [kAXValueAttribute as String])
    }

    func testRejectsValueWhenAttributeIsNotSettable() {
        let runtime = FakeAXRuntime()
        runtime.settable = false
        let controller = AXElementController(runtime: runtime, accessibilityCheck: { true })

        XCTAssertThrowsError(try controller.setValue("replacement", on: inertElement)) { error in
            XCTAssertEqual(
                error as? AutomationError,
                .attributeNotSettable(kAXValueAttribute as String)
            )
        }
        XCTAssertTrue(runtime.setAttributes.isEmpty)
    }

    func testPermissionFailureDoesNotTouchRuntime() {
        let runtime = FakeAXRuntime()
        runtime.actions = [SemanticAXAction.press.rawValue]
        let controller = AXElementController(runtime: runtime, accessibilityCheck: { false })

        XCTAssertThrowsError(try controller.perform(.press, on: inertElement)) { error in
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertTrue(runtime.performedActions.isEmpty)
    }
}

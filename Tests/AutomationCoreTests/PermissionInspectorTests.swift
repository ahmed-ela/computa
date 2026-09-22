import XCTest
@testable import AutomationCore

final class PermissionInspectorTests: XCTestCase {
    func testReportsGrantedStatuses() {
        let inspector = PermissionInspector(
            accessibilityCheck: { true },
            screenRecordingCheck: { true }
        )

        XCTAssertEqual(
            inspector.current(),
            AutomationPermissionSnapshot(accessibility: .granted, screenRecording: .granted)
        )
    }

    func testReportsNotGrantedWithoutRequesting() {
        var accessibilityChecks = 0
        var screenRecordingChecks = 0
        let inspector = PermissionInspector(
            accessibilityCheck: {
                accessibilityChecks += 1
                return false
            },
            screenRecordingCheck: {
                screenRecordingChecks += 1
                return false
            }
        )

        XCTAssertEqual(
            inspector.current(),
            AutomationPermissionSnapshot(accessibility: .notGranted, screenRecording: .notGranted)
        )
        XCTAssertEqual(accessibilityChecks, 1)
        XCTAssertEqual(screenRecordingChecks, 1)
    }
}

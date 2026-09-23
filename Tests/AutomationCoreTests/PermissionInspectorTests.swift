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
        var accessibilityRequests = 0
        var screenRecordingRequests = 0
        let inspector = PermissionInspector(
            accessibilityCheck: {
                accessibilityChecks += 1
                return false
            },
            screenRecordingCheck: {
                screenRecordingChecks += 1
                return false
            },
            accessibilityRequest: {
                accessibilityRequests += 1
                return false
            },
            screenRecordingRequest: {
                screenRecordingRequests += 1
                return false
            }
        )

        XCTAssertEqual(
            inspector.current(),
            AutomationPermissionSnapshot(accessibility: .notGranted, screenRecording: .notGranted)
        )
        XCTAssertEqual(accessibilityChecks, 1)
        XCTAssertEqual(screenRecordingChecks, 1)
        XCTAssertEqual(accessibilityRequests, 0)
        XCTAssertEqual(screenRecordingRequests, 0)
    }

    func testRequestAccessibilityOnlyInvokesItsExplicitRequestPath() {
        var accessibilityGranted = false
        var accessibilityRequests = 0
        var screenRecordingRequests = 0
        let inspector = PermissionInspector(
            accessibilityCheck: { accessibilityGranted },
            screenRecordingCheck: { false },
            accessibilityRequest: {
                accessibilityRequests += 1
                accessibilityGranted = true
                return true
            },
            screenRecordingRequest: {
                screenRecordingRequests += 1
                return false
            }
        )

        let snapshot = inspector.requestAccessibility()

        XCTAssertEqual(accessibilityRequests, 1)
        XCTAssertEqual(screenRecordingRequests, 0)
        XCTAssertEqual(snapshot.accessibility, .granted)
        XCTAssertEqual(snapshot.screenRecording, .notGranted)
    }

    func testRequestScreenRecordingOnlyInvokesItsExplicitRequestPath() {
        var screenRecordingGranted = false
        var accessibilityRequests = 0
        var screenRecordingRequests = 0
        let inspector = PermissionInspector(
            accessibilityCheck: { false },
            screenRecordingCheck: { screenRecordingGranted },
            accessibilityRequest: {
                accessibilityRequests += 1
                return false
            },
            screenRecordingRequest: {
                screenRecordingRequests += 1
                screenRecordingGranted = true
                return true
            }
        )

        let snapshot = inspector.requestScreenRecording()

        XCTAssertEqual(accessibilityRequests, 0)
        XCTAssertEqual(screenRecordingRequests, 1)
        XCTAssertEqual(snapshot.accessibility, .notGranted)
        XCTAssertEqual(snapshot.screenRecording, .granted)
    }
}

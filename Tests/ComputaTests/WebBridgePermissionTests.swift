import AutomationCore
import XCTest
@testable import Computa

final class WebBridgePermissionTests: XCTestCase {
    @MainActor
    func testAccessibilityRecoveryUsesTheCurrentProcessAndOnlyOpensSettingsWhileDenied() {
        let permissions = ScreenRecordingPermissionStub(requestResult: .notGranted)
        let state = AppState(tasks: [], permissionClient: permissions, preferences: isolatedTestPreferences())
        var openedURLs: [URL] = []
        let bridge = WebBridge(state: state) { url in openedURLs.append(url); return true }
        XCTAssertTrue(state.presentSettings())
        XCTAssertTrue(openedURLs.isEmpty)
        bridge.requestAccessibilityPermission()
        XCTAssertEqual(openedURLs, [WebBridge.accessibilitySettingsURL])
        XCTAssertEqual(permissions.accessibilityRequests, 1)
        permissions.accessibility = .granted
        state.refreshAutomationPermissions()
        XCTAssertEqual(state.automationPermissions.accessibility, .granted)
        XCTAssertEqual(permissions.accessibilityRequests, 1)
        bridge.requestAccessibilityPermission()
        XCTAssertEqual(openedURLs, [WebBridge.accessibilitySettingsURL])
        XCTAssertEqual(permissions.requestCount, 0)
    }
    @MainActor
    func testDeniedHumanRequestOpensScreenRecordingSettings() {
        let permissions = ScreenRecordingPermissionStub(requestResult: .notGranted)
        let state = AppState(tasks: [], permissionClient: permissions, preferences: isolatedTestPreferences())
        var openedURLs: [URL] = []
        let bridge = WebBridge(state: state) { url in
            openedURLs.append(url)
            return true
        }

        bridge.requestScreenRecordingPermission()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(state.automationPermissions.screenRecording, .notGranted)
        XCTAssertEqual(openedURLs, [WebBridge.screenRecordingSettingsURL])
        XCTAssertEqual(
            openedURLs.first?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
    }

    @MainActor
    func testGrantedHumanRequestDoesNotOpenSystemSettings() {
        let permissions = ScreenRecordingPermissionStub(requestResult: .granted)
        let state = AppState(tasks: [], permissionClient: permissions, preferences: isolatedTestPreferences())
        var openedURLs: [URL] = []
        let bridge = WebBridge(state: state) { url in
            openedURLs.append(url)
            return true
        }

        bridge.requestScreenRecordingPermission()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(state.automationPermissions.screenRecording, .granted)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    @MainActor
    func testDeniedRequestFallsBackToSystemSettingsAppWhenPaneLinkFails() {
        let permissions = ScreenRecordingPermissionStub(requestResult: .notGranted)
        let state = AppState(tasks: [], permissionClient: permissions, preferences: isolatedTestPreferences())
        var openedURLs: [URL] = []
        let bridge = WebBridge(state: state) { url in
            openedURLs.append(url)
            return url == WebBridge.systemSettingsAppURL
        }

        bridge.requestScreenRecordingPermission()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(
            openedURLs,
            [WebBridge.screenRecordingSettingsURL, WebBridge.systemSettingsAppURL]
        )
    }

    @MainActor
    func testPermissionStatusReadsNeverOpenSystemSettings() {
        let permissions = ScreenRecordingPermissionStub(requestResult: .notGranted)
        let state = AppState(tasks: [], permissionClient: permissions, preferences: isolatedTestPreferences())
        var openedURLs: [URL] = []
        let bridge = WebBridge(state: state) { url in
            openedURLs.append(url)
            return true
        }

        bridge.update(snapshot: WebUISnapshot(state: state))
        state.refreshAutomationPermissions()
        bridge.update(snapshot: WebUISnapshot(state: state))

        XCTAssertEqual(permissions.requestCount, 0)
        XCTAssertTrue(openedURLs.isEmpty)
    }
}

private final class ScreenRecordingPermissionStub: AutomationPermissionClient {
    let requestResult: PermissionGrant
    private(set) var requestCount = 0
    private(set) var accessibilityRequests = 0
    var accessibility: PermissionGrant = .notGranted
    private var screenRecording: PermissionGrant = .notGranted

    init(requestResult: PermissionGrant) {
        self.requestResult = requestResult
    }

    func current() -> AutomationPermissionSnapshot {
        AutomationPermissionSnapshot(
            accessibility: accessibility,
            screenRecording: screenRecording
        )
    }

    func requestAccessibility() -> AutomationPermissionSnapshot {
        accessibilityRequests += 1
        return current()
    }

    func requestScreenRecording() -> AutomationPermissionSnapshot {
        requestCount += 1
        screenRecording = requestResult
        return current()
    }
}

import AutomationCore
import XCTest
@testable import LocalCodex

final class WebBridgePermissionTests: XCTestCase {
    @MainActor
    func testDeniedHumanRequestOpensScreenRecordingSettings() {
        let permissions = ScreenRecordingPermissionStub(requestResult: .notGranted)
        let state = AppState(tasks: [], permissionClient: permissions)
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
        let state = AppState(tasks: [], permissionClient: permissions)
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
        let state = AppState(tasks: [], permissionClient: permissions)
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
        let state = AppState(tasks: [], permissionClient: permissions)
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
    private var screenRecording: PermissionGrant = .notGranted

    init(requestResult: PermissionGrant) {
        self.requestResult = requestResult
    }

    func current() -> AutomationPermissionSnapshot {
        AutomationPermissionSnapshot(
            accessibility: .notGranted,
            screenRecording: screenRecording
        )
    }

    func requestAccessibility() -> AutomationPermissionSnapshot {
        current()
    }

    func requestScreenRecording() -> AutomationPermissionSnapshot {
        requestCount += 1
        screenRecording = requestResult
        return current()
    }
}

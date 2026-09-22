import XCTest
@testable import AutomationCore

final class PermissionGuardTests: XCTestCase {
    @MainActor
    func testFocusedWindowReaderStopsBeforeAXInspection() {
        var checks = 0
        let reader = FocusedWindowReader(accessibilityCheck: {
            checks += 1
            return false
        })

        XCTAssertThrowsError(try reader.focusedWindow()) { error in
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        XCTAssertEqual(checks, 1)
    }

    @MainActor
    func testScreenshotterStopsBeforeScreenCaptureKitDiscovery() async {
        var checks = 0
        let screenshotter = WindowScreenshotter(screenRecordingCheck: {
            checks += 1
            return false
        })

        do {
            _ = try await screenshotter.availableWindows()
            XCTFail("Expected a permission failure")
        } catch {
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.screenRecording))
        }
        XCTAssertEqual(checks, 1)
    }
}

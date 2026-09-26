import AutomationCore
import CoreGraphics
import Foundation
import XCTest
@testable import Macrouse

@MainActor
final class NativeBackgroundCaptureTests: XCTestCase {
    private let application = ActivatedApplication(
        processIdentifier: 77, bundleIdentifier: "com.example.fixture", localizedName: "Fixture"
    )

    func testBackgroundCaptureReturnsObservationOnlyWithoutGlobalInputAuthority() async throws {
        let backend = try Backend()
        let result = try await subject(backend).capture()
        XCTAssertEqual(result.image.width, 64)
        XCTAssertEqual(result.image.height, 48)
        XCTAssertTrue(result.text.contains("observation_id=\(result.observationID.uuidString)"))
        XCTAssertTrue(result.text.contains("input_authority=none"))
        XCTAssertTrue(result.text.contains("activation=none"))
        XCTAssertFalse(result.text.contains("capture_id="))
        XCTAssertEqual(backend.capturedIDs, [42])
        XCTAssertEqual(backend.windowReads, 2)
        XCTAssertEqual(backend.selectionReads, 4)
        // The injected/production interfaces have no global-focus, activate,
        // display-capture, coordinate conversion, or input operation at all.
    }

    func testRepeatedCapturesHaveDistinctObservationIDs() async throws {
        let backend = try Backend()
        let capture = subject(backend)
        let first = try await capture.capture()
        let second = try await capture.capture()
        XCTAssertNotEqual(first.observationID, second.observationID)
        XCTAssertEqual(backend.capturedIDs, [42, 42])
    }

    func testWrongProcessOrBundleFailsBeforeScreenCapture() async throws {
        for field in ["process", "bundle"] {
            let backend = try Backend()
            backend.processID = field == "process" ? 88 : 77
            backend.bundleID = field == "bundle" ? "com.example.other" : "com.example.fixture"
            await expect(.targetChanged) { _ = try await self.subject(backend).capture() }
            XCTAssertEqual(backend.windowReads, 0)
            XCTAssertTrue(backend.capturedIDs.isEmpty)
        }
    }

    func testAmbiguousMappingNeverCapturesAnArbitraryWindow() async throws {
        let backend = try Backend()
        backend.list = [backend.window(id: 42), backend.window(id: 43)]
        await expect(.ambiguousWindow) { _ = try await self.subject(backend).capture() }
        XCTAssertTrue(backend.capturedIDs.isEmpty)
    }

    func testMissingOrOffscreenWindowDoesNotActivateOrCapture() async throws {
        for offscreen in [false, true] {
            let backend = try Backend()
            backend.list = offscreen ? [backend.window(id: 42, onScreen: false)] : []
            await expect(.ambiguousWindow) { _ = try await self.subject(backend).capture() }
            XCTAssertTrue(backend.capturedIDs.isEmpty)
        }
    }

    func testWindowIdentityReplacementAfterCaptureDoesNotPublishImage() async throws {
        let backend = try Backend()
        backend.onCapture = { backend.selectionValid = false }
        await expect(.targetChanged) { _ = try await self.subject(backend).capture() }
        XCTAssertEqual(backend.capturedIDs, [42])
    }

    func testWindowMoveDuringDiscoveryPreventsCapture() async throws {
        let backend = try Backend()
        backend.onWindows = {
            backend.frame = WindowFrame(x: 30, y: 20, width: 64, height: 48)
        }
        await expect(.windowChanged) { _ = try await self.subject(backend).capture() }
        XCTAssertTrue(backend.capturedIDs.isEmpty)
    }

    func testSCWindowReplacementGeometryChangeAndNewAmbiguityFailAfterCapture() async throws {
        for change in ["id", "frame", "ambiguity"] {
            let backend = try Backend()
            backend.onCapture = {
                if change == "id" { backend.list = [backend.window(id: 43)] }
                if change == "frame" {
                    backend.list = [backend.window(id: 42, frame: WindowFrame(x: 11, y: 20, width: 64, height: 48))]
                }
                if change == "ambiguity" { backend.list.append(backend.window(id: 43)) }
            }
            await expect(.windowChanged) { _ = try await self.subject(backend).capture() }
            XCTAssertEqual(backend.capturedIDs, [42])
        }
    }

    func testRevokedLifetimeStopsBeforeDiscovery() async throws {
        let backend = try Backend(); let lifetime = NativeBackgroundLifetime()
        lifetime.revoke()
        await expectCancellation { _ = try await self.subject(backend, lifetime: lifetime).capture() }
        XCTAssertEqual(backend.selectionReads, 0)
        XCTAssertEqual(backend.windowReads, 0)
    }

    func testRevocationDuringIdentityReadStopsBeforeDiscovery() async throws {
        let backend = try Backend(); let lifetime = NativeBackgroundLifetime()
        backend.onSelection = { lifetime.revoke() }
        await expectCancellation { _ = try await self.subject(backend, lifetime: lifetime).capture() }
        XCTAssertEqual(backend.windowReads, 0)
    }

    func testRevocationDuringEachAwaitPreventsFurtherCaptureOrPublication() async throws {
        for phase in ["discovery", "capture", "finalDiscovery"] {
            let backend = try Backend(); let lifetime = NativeBackgroundLifetime()
            backend.onWindows = {
                if (phase == "discovery" && backend.windowReads == 1)
                    || (phase == "finalDiscovery" && backend.windowReads == 2) { lifetime.revoke() }
            }
            backend.onCapture = { if phase == "capture" { lifetime.revoke() } }
            await expectCancellation { _ = try await self.subject(backend, lifetime: lifetime).capture() }
            XCTAssertEqual(backend.capturedIDs, phase == "discovery" ? [] : [42])
        }
    }

    func testTaskCancellationDuringCapturePreventsPublication() async throws {
        let backend = try Backend()
        backend.onCapture = { withUnsafeCurrentTask { $0?.cancel() } }
        let capture = subject(backend)
        let task = Task { try await capture.capture() }
        await expectCancellation { _ = try await task.value }
        XCTAssertEqual(backend.capturedIDs, [42])
        XCTAssertEqual(backend.windowReads, 1)
    }

    func testPermissionOrCaptureFailureDoesNotRetryOrPublish() async throws {
        for discovery in [false, true] {
            let backend = try Backend()
            if discovery {
                backend.onWindows = { throw AutomationError.permissionNotGranted(.screenRecording) }
            } else {
                backend.onCapture = { throw AutomationError.windowNotFound(42) }
            }
            do { _ = try await subject(backend).capture(); XCTFail("Expected injected failure") }
            catch { XCTAssertTrue(error is AutomationError) }
            XCTAssertEqual(backend.capturedIDs, discovery ? [] : [42])
            XCTAssertEqual(backend.windowReads, 1)
        }
    }

    private func subject(_ backend: Backend, lifetime: NativeBackgroundLifetime = .init()) -> NativeBackgroundCapture {
        NativeBackgroundCapture(application: application, lifetime: lifetime, backend: backend)
    }

    private func expect(_ failure: NativeBackgroundCapture.Failure, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(failure)") }
        catch { XCTAssertEqual(error as? NativeBackgroundCapture.Failure, failure) }
    }

    private func expectCancellation(operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected \(error)") }
    }

    private final class Backend: NativeBackgroundCaptureBackend {
        var processID: Int32 = 77
        var bundleID = "com.example.fixture"
        var frame = WindowFrame(x: 10, y: 20, width: 64, height: 48)
        var selectionValid = true
        var list = [CapturableWindowInfo]()
        var onSelection: (() throws -> Void)?
        var onWindows: (() throws -> Void)?
        var onCapture: (() throws -> Void)?
        var selectionReads = 0
        var windowReads = 0
        var capturedIDs = [UInt32]()
        let image: CGImage

        init() throws {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            image = try XCTUnwrap(context.makeImage())
            list = [window(id: 42)]
        }

        func selectedWindow() throws -> FocusedWindowInfo {
            selectionReads += 1
            try onSelection?()
            guard selectionValid else { throw NativeBackgroundCapture.Failure.targetChanged }
            return FocusedWindowInfo(
                processIdentifier: processID, bundleIdentifier: bundleID, applicationName: "Fixture",
                title: "AX title", role: "AXWindow", subrole: nil, frame: frame
            )
        }

        func windows() async throws -> [CapturableWindowInfo] {
            windowReads += 1
            try onWindows?()
            return list
        }

        func capture(windowID: UInt32) async throws -> CGImage {
            capturedIDs.append(windowID)
            try onCapture?()
            return image
        }

        func window(id: UInt32, frame: WindowFrame? = nil, onScreen: Bool = true) -> CapturableWindowInfo {
            CapturableWindowInfo(
                windowID: id, title: "SC title", owningApplicationName: "Fixture",
                owningBundleIdentifier: bundleID, owningProcessIdentifier: processID,
                frame: frame ?? self.frame, isOnScreen: onScreen, isActive: false
            )
        }
    }
}

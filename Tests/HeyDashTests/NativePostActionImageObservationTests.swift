import AutomationCore
import Foundation
import XCTest
@testable import HeyDash

@MainActor
final class NativePostActionImageObservationTests: XCTestCase {
    func testSharedDispatchHeaderDoesNotClaimSynchronizedAccessibility() {
        let header = NativePostActionImageObservation.dispatchMarker
        XCTAssertTrue(header.contains("action_dispatched=true"))
        XCTAssertTrue(header.contains("this marker alone is not success"))
        XCTAssertTrue(header.contains("Do not repeat the click"))
        XCTAssertFalse(header.contains("modality="))
        XCTAssertFalse(header.contains("snapshot_id"))
        XCTAssertFalse(header.contains("capture_id"))
    }

    func testScreenshotOnlyVerificationStripsActionableIDsAndAXClaims() throws {
        let image: [String: Any] = ["type": "inputImage", "imageUrl": "fixture-image"]
        let content = try NativePostActionImageObservation.verificationContent(from: [
            ["type": "inputText", "text": "WINDOW_CAPTURE capture_id=private-id\n"
                + NativeCombinedCapture.omissionMarker], image])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "inputText")
        let text = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertEqual(text, NativePostActionImageObservation.marker)
        XCTAssertFalse(text.contains("private-id"))
        XCTAssertFalse(text.contains("SYNCHRONIZED_AX"))
        XCTAssertFalse(text.contains("snapshot_id="))
        XCTAssertEqual(content[1]["imageUrl"] as? String, "fixture-image")
    }

    func testSynchronizedVerificationKeepsAXButNotPointerCapture() throws {
        let content = try NativePostActionImageObservation.verificationContent(from: [
            ["type": "inputText", "text": "WINDOW_CAPTURE capture_id=private-id"],
            ["type": "inputText", "text": "SYNCHRONIZED_AX screen_frame=screen_points\nAXSNAPSHOT id=guarded-ax"],
            ["type": "inputImage", "imageUrl": "fixture-image"]])
        let text = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(text.hasPrefix("POST_ACTION_SYNCHRONIZED_AX"))
        XCTAssertTrue(text.contains("AXSNAPSHOT id=guarded-ax"))
        XCTAssertFalse(text.contains("private-id"))
        XCTAssertEqual(content[1]["imageUrl"] as? String, "fixture-image")
    }

    func testMalformedVerificationPayloadDoesNotDiscloseImage() {
        let metadata = ["type": "inputText", "text": "WINDOW_CAPTURE capture_id=private-id"]
        let image = ["type": "inputImage", "imageUrl": "not-disclosed"]
        let cases: [[[String: Any]]] = [[], [metadata, image],
            [["text": NativeCombinedCapture.omissionMarker], image],
            [metadata, ["text": "not an AX header\nprivate data"], image],
            [metadata, ["text": "SYNCHRONIZED_AX no newline"], image]]
        for content in cases {
            XCTAssertThrowsError(try NativePostActionImageObservation.verificationContent(from: content))
        }
    }

    func testKeyboardImageSupplementRequiresObservedOpaqueSurface() {
        XCTAssertFalse(NativePostActionImageObservation.supplementsKeyboard(
            hadImageObservation: false, exposedFocusedRoles: []))
        XCTAssertFalse(NativePostActionImageObservation.supplementsKeyboard(
            hadImageObservation: false, exposedFocusedRoles: ["AXTextField", "AXButton"]))
        XCTAssertTrue(NativePostActionImageObservation.supplementsKeyboard(
            hadImageObservation: true, exposedFocusedRoles: []))
        XCTAssertTrue(NativePostActionImageObservation.supplementsKeyboard(
            hadImageObservation: false, exposedFocusedRoles: ["AXSharedScreen"]))
        XCTAssertTrue(NativePostActionImageObservation.supplementsKeyboard(
            hadImageObservation: false, exposedFocusedRoles: ["AXImage"]))
    }

    func testFallbackRequiresTypedSynchronizationFailure() {
        XCTAssertTrue(NativePostActionImageObservation.allowsSynchronizationFallback(
            NativePostActionImageObservation.Failure.pixelsChangedDuringAccessibility))
        XCTAssertFalse(NativePostActionImageObservation.allowsSynchronizationFallback(
            NativePostActionImageObservation.Failure.windowChanged))
        XCTAssertFalse(NativePostActionImageObservation.allowsSynchronizationFallback(CancellationError()))
        XCTAssertFalse(NativePostActionImageObservation.allowsSynchronizationFallback(
            NSError(domain: "Permission denied", code: 1)))
    }

    func testVerificationImageIsBoundToSameWindowBeforeAndAfterCapture() async throws {
        var checks = 0
        var captures = 0
        let image = try await NativePostActionImageObservation.capture(
            expectedWindow: window(),
            validateAccessAndFocus: { checks += 1 },
            currentWindow: { self.window(title: "Title changed after input") },
            captureImage: { captures += 1; return "verification-image" }
        )
        XCTAssertEqual(image, "verification-image")
        XCTAssertEqual(checks, 4)
        XCTAssertEqual(captures, 1)
        XCTAssertTrue(NativePostActionImageObservation.marker.contains("verification_only=true"))
        XCTAssertTrue(NativePostActionImageObservation.marker.contains("Do not repeat the action"))
    }

    func testChangedWindowBeforeCaptureNeverCaptures() async {
        var captures = 0
        do {
            _ = try await NativePostActionImageObservation.capture(expectedWindow: window(),
                validateAccessAndFocus: {}, currentWindow: { self.window(id: 8) },
                captureImage: { captures += 1; return "not disclosed" })
            XCTFail("A different window must fail")
        } catch {}
        XCTAssertEqual(captures, 0)
    }

    func testChangedWindowAfterCaptureNeverDisclosesImage() async {
        var captures = 0
        do {
            _ = try await NativePostActionImageObservation.capture(expectedWindow: window(),
                validateAccessAndFocus: {}, currentWindow: { self.window(id: captures == 0 ? 7 : 8) },
                captureImage: { captures += 1; return "not disclosed" })
            XCTFail("Image from a changed window must not escape")
        } catch {}
        XCTAssertEqual(captures, 1)
    }

    func testRevokedPermissionAfterCaptureNeverDisclosesImage() async {
        var captures = 0
        do {
            _ = try await NativePostActionImageObservation.capture(expectedWindow: window(),
                validateAccessAndFocus: { if captures > 0 { throw CancellationError() } },
                currentWindow: { self.window() }, captureImage: { captures += 1; return "not disclosed" })
            XCTFail("Revocation must fail before disclosure")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(captures, 1)
    }

    private func window(id: UInt32 = 7, title: String = "Synthetic") -> CapturableWindowInfo {
        .init(windowID: id, title: title, owningApplicationName: "Fixture", owningBundleIdentifier: "fixture.bundle",
              owningProcessIdentifier: 100, frame: .init(x: 0, y: 0, width: 100, height: 100),
              isOnScreen: true, isActive: true)
    }
}

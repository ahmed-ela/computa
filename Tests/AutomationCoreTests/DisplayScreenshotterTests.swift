import CoreGraphics
import Foundation
import XCTest
@testable import AutomationCore

@MainActor
private final class RecordingDisplayCaptureRuntime: DisplayCaptureRuntime {
    struct Capture: Equatable {
        let displayID: UInt32
        let width: Int
        let height: Int
        let showsCursor: Bool
    }

    var availableDisplays = [CapturableDisplayInfo]()
    var displayRequests = 0
    var captures = [Capture]()

    func displays() async throws -> [CapturableDisplayInfo] {
        displayRequests += 1
        return availableDisplays
    }

    func capture(
        displayID: UInt32,
        width: Int,
        height: Int,
        showsCursor: Bool
    ) async throws -> CGImage {
        captures.append(
            Capture(
                displayID: displayID,
                width: width,
                height: height,
                showsCursor: showsCursor
            )
        )
        return Self.stubImage
    }

    private static let stubImage: CGImage = {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()
}

final class DisplayScreenshotterTests: XCTestCase {
    @MainActor
    func testDiscoveryAndCaptureFailClosedBeforeRuntimeUse() async {
        var permissionChecks = 0
        let runtime = RecordingDisplayCaptureRuntime()
        let screenshotter = DisplayScreenshotter(
            runtime: runtime,
            screenRecordingCheck: {
                permissionChecks += 1
                return false
            }
        )

        do {
            _ = try await screenshotter.availableDisplays()
            XCTFail("Expected Screen Recording permission failure")
        } catch {
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.screenRecording))
        }
        do {
            _ = try await screenshotter.captureDisplay()
            XCTFail("Expected Screen Recording permission failure")
        } catch {
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.screenRecording))
        }

        XCTAssertEqual(permissionChecks, 2)
        XCTAssertEqual(runtime.displayRequests, 0)
        XCTAssertEqual(runtime.captures, [])
    }

    @MainActor
    func testAvailableDisplaysSortsMainFirstThenByID() async throws {
        let runtime = RecordingDisplayCaptureRuntime()
        runtime.availableDisplays = [
            display(id: 8, isMain: false),
            display(id: 9, isMain: true),
            display(id: 2, isMain: false),
        ]
        let screenshotter = DisplayScreenshotter(runtime: runtime, screenRecordingCheck: { true })

        let displays = try await screenshotter.availableDisplays()

        XCTAssertEqual(displays.map(\.displayID), [9, 2, 8])
        XCTAssertEqual(runtime.displayRequests, 1)
    }

    @MainActor
    func testDefaultCaptureUsesMainDisplayAndAspectFitsWithinAllBounds() async throws {
        let runtime = RecordingDisplayCaptureRuntime()
        runtime.availableDisplays = [
            display(id: 2, width: 1_920, height: 1_080, isMain: false),
            display(id: 9, width: 5_120, height: 2_880, isMain: true),
        ]
        let screenshotter = DisplayScreenshotter(runtime: runtime, screenRecordingCheck: { true })

        _ = try await screenshotter.captureDisplay(showsCursor: true)

        XCTAssertEqual(
            runtime.captures,
            [.init(displayID: 9, width: 2_560, height: 1_440, showsCursor: true)]
        )
    }

    @MainActor
    func testExplicitDisplayCaptureHonorsPixelCountBound() async throws {
        let runtime = RecordingDisplayCaptureRuntime()
        runtime.availableDisplays = [display(id: 44, width: 6_000, height: 3_000, isMain: false)]
        let screenshotter = DisplayScreenshotter(runtime: runtime, screenRecordingCheck: { true })
        let limits = try DisplayCaptureLimits(
            maximumWidth: 4_000,
            maximumHeight: 4_000,
            maximumPixelCount: 2_000_000
        )

        _ = try await screenshotter.captureDisplay(displayID: 44, limits: limits)

        let capture = try XCTUnwrap(runtime.captures.first)
        XCTAssertEqual(capture.displayID, 44)
        XCTAssertLessThanOrEqual(capture.width, limits.maximumWidth)
        XCTAssertLessThanOrEqual(capture.height, limits.maximumHeight)
        XCTAssertLessThanOrEqual(capture.width * capture.height, limits.maximumPixelCount)
        XCTAssertEqual(Double(capture.width) / Double(capture.height), 2, accuracy: 0.002)
    }

    @MainActor
    func testCaptureRejectsMissingDisplayBeforeCaptureRuntimeCall() async {
        let runtime = RecordingDisplayCaptureRuntime()
        runtime.availableDisplays = [display(id: 1, isMain: true)]
        let screenshotter = DisplayScreenshotter(runtime: runtime, screenRecordingCheck: { true })

        do {
            _ = try await screenshotter.captureDisplay(displayID: 99)
            XCTFail("Expected missing display error")
        } catch {
            XCTAssertEqual(error as? DisplayScreenshotError, .displayNotFound(99))
        }
        XCTAssertEqual(runtime.captures, [])
    }

    func testDimensionsNeverUpscaleSmallDisplay() throws {
        let dimensions = try DisplayCaptureDimensions.make(
            sourceWidth: 800,
            sourceHeight: 600,
            limits: .agentDefault
        )
        XCTAssertEqual(dimensions, DisplayCaptureDimensions(width: 800, height: 600))
    }

    func testLimitsRejectUnsafeValuesWhenInitializedOrDecoded() throws {
        XCTAssertThrowsError(try DisplayCaptureLimits(maximumWidth: 8_193)) { error in
            XCTAssertEqual(
                error as? DisplayScreenshotError,
                .invalidLimit(name: "maximumWidth", value: 8_193)
            )
        }

        let unsafeJSON = Data(
            #"{"maximumWidth":2560,"maximumHeight":1600,"maximumPixelCount":999999999}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayCaptureLimits.self, from: unsafeJSON)) {
            error in
            XCTAssertEqual(
                error as? DisplayScreenshotError,
                .invalidLimit(name: "maximumPixelCount", value: 999_999_999)
            )
        }
    }

    private func display(
        id: UInt32,
        width: Int = 1_920,
        height: Int = 1_080,
        isMain: Bool
    ) -> CapturableDisplayInfo {
        CapturableDisplayInfo(
            displayID: id,
            frame: WindowFrame(x: 0, y: 0, width: Double(width), height: Double(height)),
            pixelWidth: width,
            pixelHeight: height,
            isMain: isMain
        )
    }
}

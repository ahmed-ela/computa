import Foundation
import XCTest
@testable import Computa

@MainActor
final class NativeCombinedCaptureTests: XCTestCase {
    func testStableCombinedCaptureNeverFallsBack() async throws {
        var events = [String]()
        let result = try await NativeCombinedCapture.run(includeAccessibility: true,
            capture: { events.append("combined"); return "synchronized" },
            screenshotOnly: { events.append("fallback"); return "image" })
        XCTAssertEqual(events, ["combined"])
        XCTAssertEqual(result, "synchronized")
    }

    func testOnlyPixelSynchronizationFailureGetsOneOrdinaryImageRetry() async throws {
        var events = [String]()
        let result: String = try await NativeCombinedCapture.run(includeAccessibility: true,
            capture: {
                events.append("combined")
                throw NativePostActionImageObservation.Failure.pixelsChangedDuringAccessibility
            }, screenshotOnly: { events.append("image-with-normal-guards"); return "fresh image" })
        XCTAssertEqual(events, ["combined", "image-with-normal-guards"])
        XCTAssertEqual(result, "fresh image")
    }

    func testFallbackFailureDoesNotLoopOrReturnTheUnsynchronizedTree() async {
        var events = [String]()
        do {
            let _: String = try await NativeCombinedCapture.run(includeAccessibility: true,
                capture: {
                    events.append("combined")
                    throw NativePostActionImageObservation.Failure.pixelsChangedDuringAccessibility
                }, screenshotOnly: {
                    events.append("image")
                    throw NativePostActionImageObservation.Failure.pixelsChangedDuringAccessibility
                })
            XCTFail("Both captures failed")
        } catch {}
        XCTAssertEqual(events, ["combined", "image"])
    }

    func testWindowPermissionAndCancellationFailuresNeverFallBack() async {
        let failures: [Error] = [NativePostActionImageObservation.Failure.windowChanged,
                                 CancellationError(), NSError(domain: "permission", code: 1)]
        for failure in failures {
            var fallback = false
            do {
                let _: String = try await NativeCombinedCapture.run(includeAccessibility: true,
                    capture: { throw failure }, screenshotOnly: { fallback = true; return "forbidden" })
                XCTFail("Invalid observation must not escape")
            } catch {}
            XCTAssertFalse(fallback)
        }
    }

    func testTaskCancelledDuringTypedSynchronizationFailureNeverFallsBack() async {
        var events = [String]()
        // Isolate cancellation from XCTest's task and avoid a timing-dependent sleep.
        let operation = Task { @MainActor in
            let result: String = try await NativeCombinedCapture.run(includeAccessibility: true,
                capture: {
                    events.append("combined")
                    withUnsafeCurrentTask { $0?.cancel() }
                    XCTAssertTrue(Task.isCancelled)
                    throw NativePostActionImageObservation.Failure.pixelsChangedDuringAccessibility
                }, screenshotOnly: { events.append("forbidden fallback"); return "image" })
            return result
        }
        do {
            _ = try await operation.value
            XCTFail("Cancellation must take precedence over an otherwise eligible retry")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(events, ["combined"])
    }

    func testIdenticalErrorDescriptionCannotSpoofTypedSynchronizationFailure() async {
        let failure = NativePostActionImageObservation.Failure.pixelsChangedDuringAccessibility
        let spoof = NSError(domain: "synthetic.observation", code: 1,
            userInfo: [NSLocalizedDescriptionKey: failure.localizedDescription])
        XCTAssertEqual(spoof.localizedDescription, failure.localizedDescription)
        var fallback = false
        do {
            let _: String = try await NativeCombinedCapture.run(includeAccessibility: true,
                capture: { throw spoof }, screenshotOnly: { fallback = true; return "forbidden" })
            XCTFail("Matching error text must not authorize a fallback")
        } catch {
            XCTAssertEqual(error as NSError, spoof)
        }
        XCTAssertFalse(fallback)
    }

    func testScreenshotOnlyFailureNeverRetries() async {
        var fallback = false
        do {
            let _: String = try await NativeCombinedCapture.run(includeAccessibility: false,
                capture: { throw NativePostActionImageObservation.Failure.pixelsChangedDuringAccessibility },
                screenshotOnly: { fallback = true; return "forbidden" })
            XCTFail("Unexpected screenshot-only retry")
        } catch {}
        XCTAssertFalse(fallback)
    }
}

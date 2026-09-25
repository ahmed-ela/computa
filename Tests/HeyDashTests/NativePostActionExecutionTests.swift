import Foundation
import XCTest
@testable import HeyDash

@MainActor
final class NativePostActionExecutionTests: XCTestCase {
    private enum Failure: Error { case injected }

    func testInvalidatesBeforeExactlyOneDispatchAndPublishesFreshObservation() async throws {
        var trace = [String]()
        var observationID: String? = "old"
        let text = try await NativePostActionExecution.run(
            invalidate: { trace.append("invalidate"); observationID = nil },
            dispatch: {
                XCTAssertNil(observationID)
                trace.append("dispatch")
            },
            observe: {
                trace.append("observe")
                observationID = "fresh"
                return "AXSNAPSHOT id=fresh"
            },
            discardObservation: { trace.append("discard"); observationID = nil }
        )
        XCTAssertEqual(trace, ["invalidate", "dispatch", "observe"])
        XCTAssertEqual(observationID, "fresh")
        XCTAssertTrue(text.contains("status=available action_dispatched=true"))
        XCTAssertTrue(text.contains("AXSNAPSHOT id=fresh"))
        XCTAssertTrue(text.contains("dispatch is not success"))
    }

    func testObservationFailureNeverRetriesOrClaimsMutationFailureAndDiscardsIDs() async throws {
        var trace = [String]()
        var observationID: String? = "old"
        let text = try await NativePostActionExecution.run(
            invalidate: { trace.append("invalidate"); observationID = nil },
            dispatch: { trace.append("dispatch") },
            observe: {
                trace.append("observe")
                observationID = "partially-created"
                throw Failure.injected
            },
            discardObservation: { trace.append("discard"); observationID = nil }
        )
        XCTAssertEqual(trace, ["invalidate", "dispatch", "observe", "discard"])
        XCTAssertNil(observationID)
        XCTAssertTrue(text.contains("status=unavailable action_dispatched=true"))
        XCTAssertTrue(text.contains("outcome is unverified"))
        XCTAssertTrue(text.contains("Do not repeat the action"))
        XCTAssertFalse(text.contains("AXSNAPSHOT"))
    }

    func testDispatchFailurePropagatesWithoutObservationOrRetry() async {
        var trace = [String]()
        do {
            _ = try await NativePostActionExecution.run(
                invalidate: { trace.append("invalidate") },
                dispatch: { trace.append("dispatch"); throw Failure.injected },
                observe: { trace.append("observe"); return "unexpected" },
                discardObservation: { trace.append("discard") }
            )
            XCTFail("Dispatch errors must propagate")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        XCTAssertEqual(trace, ["invalidate", "dispatch"])
    }

    func testInvalidationFailurePreventsInput() async {
        var trace = [String]()
        do {
            _ = try await NativePostActionExecution.run(
                invalidate: { trace.append("invalidate"); throw Failure.injected },
                dispatch: { trace.append("dispatch") },
                observe: { trace.append("observe"); return "unexpected" },
                discardObservation: { trace.append("discard") }
            )
            XCTFail("Invalidation errors must propagate")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        XCTAssertEqual(trace, ["invalidate"])
    }

    func testCancellationDuringObservationDiscardsIDsWithoutRedispatch() async throws {
        var dispatches = 0
        var discarded = false
        let text = try await NativePostActionExecution.run(
            invalidate: {},
            dispatch: { dispatches += 1 },
            observe: { throw CancellationError() },
            discardObservation: { discarded = true }
        )
        XCTAssertEqual(dispatches, 1)
        XCTAssertTrue(discarded)
        XCTAssertTrue(text.contains("status=unavailable"))
    }
}

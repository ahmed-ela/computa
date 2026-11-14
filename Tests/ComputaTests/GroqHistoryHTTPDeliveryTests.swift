#if DEBUG
import XCTest
@testable import Computa

@MainActor
final class GroqHistoryHTTPDeliveryTests: XCTestCase {
    func testDeliveredFactBeforeWaitAndOneDeliveryForMultipleParkedWaiters() async throws {
        let ready = GroqHistoryHTTPDelivery(); XCTAssertTrue(ready.deliver())
        try await ready.wait(); XCTAssertFalse(ready.deliver())
        let gate = GroqHistoryHTTPDelivery(), (events, signal) = AsyncStream<Void>.makeStream()
        let a = Task { try await gate.waitForTesting { _ = signal.yield(()) } }
        let b = Task { try await gate.waitForTesting { _ = signal.yield(()) } }
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next(), second = await iterator.next()
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertTrue(gate.deliver()); XCTAssertFalse(gate.deliver())
        try await a.value; try await b.value
        // A successful write is terminal, but current native binding must still
        // be checked by Root rather than treating this fact as authority.
        gate.revoke(); try await gate.wait()
        signal.finish()
    }

    func testCancellingOneWaiterLeavesAnotherWaitingForActualDelivery() async throws {
        let gate = GroqHistoryHTTPDelivery(), (events, signal) = AsyncStream<Void>.makeStream()
        let a = Task { try await gate.waitForTesting { _ = signal.yield(()) } }
        let b = Task { try await gate.waitForTesting { _ = signal.yield(()) } }
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next(), second = await iterator.next()
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        a.cancel()
        do { try await a.value; XCTFail("Cancellation must not return delivery") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(gate.deliver()); try await b.value
        signal.finish()
    }

    func testRevocationWakesWaitersAndRejectsLateDeliveryAndFutureWaits() async throws {
        let gate = GroqHistoryHTTPDelivery(), (events, signal) = AsyncStream<Void>.makeStream()
        let waiting = Task { try await gate.waitForTesting { _ = signal.yield(()) } }
        var iterator = events.makeAsyncIterator(); let parked = await iterator.next(); XCTAssertNotNil(parked)
        gate.revoke(); XCTAssertFalse(gate.deliver())
        do { try await waiting.value; XCTFail("Revoked HTTP write cannot become delivered") }
        catch { XCTAssertEqual(error as? GroqHistoryHTTPDelivery.Failure, .revoked) }
        do { try await gate.wait(); XCTFail("Revocation is terminal") }
        catch { XCTAssertEqual(error as? GroqHistoryHTTPDelivery.Failure, .revoked) }
        signal.finish()
    }

    func testSingleCreatedDeadlineExpiresAndIsNotRenewedByAnotherWait() async throws {
        let gate = GroqHistoryHTTPDelivery.forTesting(timeout: .seconds(1))
        let (events, signal) = AsyncStream<Void>.makeStream()
        let waiting = Task { try await gate.waitForTesting { _ = signal.yield(()) } }
        var iterator = events.makeAsyncIterator(); let parked = await iterator.next(); XCTAssertNotNil(parked)
        do { try await waiting.value; XCTFail("The original bounded deadline must expire") }
        catch { XCTAssertEqual(error as? GroqHistoryHTTPDelivery.Failure, .deadline) }
        XCTAssertFalse(gate.deliver())
        do { try await gate.wait(); XCTFail("A new waiter cannot renew an expired write") }
        catch { XCTAssertEqual(error as? GroqHistoryHTTPDelivery.Failure, .deadline) }
        signal.finish()
    }

    func testAlreadyCancelledWaitDoesNotConsumeActualFutureDelivery() async throws {
        let gate = GroqHistoryHTTPDelivery()
        let waiting = Task { try Task.checkCancellation(); try await gate.wait() }
        waiting.cancel()
        do { try await waiting.value; XCTFail("A cancelled caller cannot claim delivery") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(gate.deliver()); try await gate.wait()
    }
}
#endif

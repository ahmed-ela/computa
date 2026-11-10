import XCTest
@testable import Computa

final class WebsiteRequestPacerTests: XCTestCase {

    func testDeadlineRemovesBlockedHeadWithoutChargingOrBlockingItsSuccessor() async throws {
        let pacer = WebsiteRequestPacer(interval: .seconds(3_600), budget: 8)
        let held = try await pacer.acquire(cost: 4)
        let expired = Task { try await pacer.acquire(cost: 8, until: .now + .milliseconds(40)) }
        let queueEnd = ContinuousClock.now + .seconds(1)
        while await pacer.waitingCountForTesting() != 1, ContinuousClock.now < queueEnd {
            try await Task.sleep(for: .milliseconds(1))
        }
        let observedHead = await pacer.waitingCountForTesting()
        XCTAssertEqual(observedHead, 1, "The head must actually queue before its deadline")
        let successor = Task { try await pacer.acquire(cost: 4, until: .now + .seconds(1)) }
        addTeardownBlock { expired.cancel(); successor.cancel(); await pacer.release(held) }
        do { _ = try await expired.value; XCTFail("An expired waiter cannot acquire or charge the allowance") }
        catch { guard case .deadline = error as? WebsiteRequestPacer.Failure else { return XCTFail("Expected the typed pacer deadline") } }
        let queued = await pacer.waitingCountForTesting()
        XCTAssertEqual(queued, 1, "Only the fitting successor remains while the actual permit is held")
        await pacer.release(held)
        let next = try await successor.value
        await pacer.release(next)
        let remaining = await pacer.waitingCountForTesting()
        XCTAssertEqual(remaining, 0)
    }

    func testDeadlineCancellationAndPastDeadlineCannotLeakOrReleaseAnotherPermit() async throws {
        let pacer = WebsiteRequestPacer(interval: .zero)
        let held = try await pacer.acquire()
        let waiter = Task { try await pacer.acquire(until: .now + .milliseconds(50)) }
        let queueEnd = ContinuousClock.now + .seconds(1)
        while await pacer.waitingCountForTesting() != 1, ContinuousClock.now < queueEnd {
            try await Task.sleep(for: .milliseconds(1))
        }
        let observedWaiter = await pacer.waitingCountForTesting()
        XCTAssertEqual(observedWaiter, 1)
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Cancellation must stay cancellation, not become a deadline") }
        catch { XCTAssertTrue(error is CancellationError) }
        await pacer.release(held)
        let current = try await pacer.acquire(until: .now + .seconds(1))
        do { _ = try await pacer.acquire(until: .now - .milliseconds(1)); XCTFail("Past deadline must not queue") }
        catch { guard case .deadline = error as? WebsiteRequestPacer.Failure else { return XCTFail("Expected the typed pacer deadline") } }
        try await Task.sleep(for: .milliseconds(60))
        let successor = Task { try await pacer.acquire(until: .now + .seconds(1)) }
        addTeardownBlock { successor.cancel(); await pacer.release(current) }
        let end = ContinuousClock.now + .seconds(1)
        while await pacer.waitingCountForTesting() != 1, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(1))
        }
        let queued = await pacer.waitingCountForTesting()
        XCTAssertEqual(queued, 1, "The cancelled waiter's old timeout cannot release another request's active permit")
        await pacer.release(current)
        let next = try await successor.value
        await pacer.release(next)
    }
    func testCancellingExpensiveHeadImmediatelyAdmitsFittingSuccessor() async throws {
        let pacer = WebsiteRequestPacer(interval: .seconds(3_600), budget: 8)
        let charged = try await pacer.acquire(cost: 4)
        await pacer.release(charged)
        let head = Task { try await pacer.acquire(cost: 8) }
        let deadline = ContinuousClock.now + .seconds(1)
        while await pacer.waitingCountForTesting() != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let queued = await pacer.waitingCountForTesting()
        XCTAssertEqual(queued, 1)
        let acquired = expectation(description: "Fitting request admitted after head cancellation")
        let successor = Task {
            let permit = try await pacer.acquire(cost: 4)
            acquired.fulfill()
            await pacer.release(permit)
        }
        addTeardownBlock { head.cancel(); successor.cancel() }
        head.cancel()
        await fulfillment(of: [acquired], timeout: 1)
        if await pacer.waitingCountForTesting() > 0 { successor.cancel() }
        _ = try await successor.value
        do { _ = try await head.value; XCTFail("Cancelled head acquired a permit") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSmallRequestsShareAllowanceWhileOverflowWaits() async throws {
        let pacer = WebsiteRequestPacer(interval: .milliseconds(30), budget: 8)
        let first = try await pacer.acquire(cost: 3)
        await pacer.release(first)
        let second = try await pacer.acquire(cost: 5)
        await pacer.release(second)
        let started = ContinuousClock.now
        let third = try await pacer.acquire(cost: 8)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(25))
        await pacer.release(third)
    }

    func testPermitSpansSubmissionAndChargesAfterRelease() async throws {
        let pacer = WebsiteRequestPacer(interval: .milliseconds(30))
        let first = try await pacer.acquire()
        let second = Task { try await pacer.acquire() }
        try await Task.sleep(for: .milliseconds(40))
        let released = ContinuousClock.now
        await pacer.release(first)
        let next = try await second.value
        XCTAssertGreaterThanOrEqual(released.duration(to: .now), .milliseconds(30))
        XCTAssertNotEqual(first, next)
        await pacer.release(next)
    }

    func testCancelledWaiterDoesNotDispatchOrBlockNextPermit() async throws {
        let pacer = WebsiteRequestPacer(interval: .zero)
        let first = try await pacer.acquire()
        let cancelled = Task { try await pacer.acquire() }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled wait acquired a permit") }
        catch { XCTAssertTrue(error is CancellationError) }
        await pacer.release(first)
        let next = try await pacer.acquire()
        await pacer.release(next)
    }

    func testForeignAndDuplicateReleaseCannotShortenCooldown() async throws {
        let pacer = WebsiteRequestPacer(interval: .milliseconds(30))
        let first = try await pacer.acquire()
        await pacer.release(UUID())
        let second = Task { try await pacer.acquire() }
        let released = ContinuousClock.now
        await pacer.release(first)
        await pacer.release(first)
        let next = try await second.value
        XCTAssertGreaterThanOrEqual(released.duration(to: .now), .milliseconds(30))
        await pacer.release(next)
    }
}

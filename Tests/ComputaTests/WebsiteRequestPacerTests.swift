import XCTest
@testable import Computa

final class WebsiteRequestPacerTests: XCTestCase {
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

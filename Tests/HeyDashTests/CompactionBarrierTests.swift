import Foundation
import XCTest
@testable import HeyDash

final class CompactionBarrierTests: XCTestCase {
    func testAllAcknowledgementAndLifecycleOrdersRequireEverySignal() throws {
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var barrier = boundBarrier()
            for (index, event) in order.enumerated() {
                switch event {
                case 0: barrier.acknowledged(operationID: barrier.id, generation: barrier.generation)
                case 1: barrier.itemCompleted(turnID: "turn", operationID: barrier.id, generation: barrier.generation)
                default: barrier.terminal(turnID: "turn", succeeded: true, operationID: barrier.id, generation: barrier.generation)
                }
                if index < 2 { XCTAssertNil(barrier.result, "Premature completion for \(order)") }
            }
            try XCTUnwrap(barrier.result).get()
        }
    }

    func testCompletedLifecycleCanWaitForLateAcknowledgement() throws {
        var barrier = boundBarrier()
        barrier.itemCompleted(turnID: "turn", operationID: barrier.id, generation: barrier.generation)
        barrier.terminal(turnID: "turn", succeeded: true, operationID: barrier.id, generation: barrier.generation)
        XCTAssertNil(barrier.result)
        barrier.acknowledged(operationID: barrier.id, generation: barrier.generation)
        // Reading this result after a waiter is installed cannot miss early events.
        try XCTUnwrap(barrier.result).get()
        try XCTUnwrap(barrier.result).get()
    }

    func testAcknowledgementBeforeTurnBindingDoesNotGrantSuccess() throws {
        var barrier = CompactionBarrier(generation: UUID())
        barrier.acknowledged(operationID: barrier.id, generation: barrier.generation)
        barrier.itemCompleted(turnID: "turn", operationID: barrier.id, generation: barrier.generation)
        barrier.terminal(turnID: "turn", succeeded: true, operationID: barrier.id, generation: barrier.generation)
        XCTAssertNil(barrier.result)
        XCTAssertTrue(barrier.bindTurn("turn", operationID: barrier.id, generation: barrier.generation))
        XCTAssertNil(barrier.result)
        barrier.itemCompleted(turnID: "turn", operationID: barrier.id, generation: barrier.generation)
        barrier.terminal(turnID: "turn", succeeded: true, operationID: barrier.id, generation: barrier.generation)
        try XCTUnwrap(barrier.result).get()
    }

    func testOldOperationOrServerGenerationCannotChangeCurrentBarrier() {
        for wrongOperation in [false, true] {
            var barrier = boundBarrier()
            let operation = wrongOperation ? UUID() : barrier.id
            let generation = wrongOperation ? barrier.generation : UUID()
            XCTAssertFalse(barrier.bindTurn("other-turn", operationID: operation, generation: generation))
            XCTAssertFalse(barrier.acknowledged(operationID: operation, generation: generation))
            XCTAssertFalse(barrier.itemCompleted(turnID: "turn", operationID: operation, generation: generation))
            XCTAssertFalse(barrier.terminal(turnID: "turn", succeeded: true, operationID: operation, generation: generation))
            XCTAssertFalse(barrier.fail(.rpcFailed("stale"), operationID: operation, generation: generation))
            XCTAssertFalse(barrier.cancel(operationID: operation, generation: generation))
            XCTAssertFalse(barrier.timeout(operationID: operation, generation: generation))
            XCTAssertFalse(barrier.disconnect(operationID: operation, generation: generation))
            XCTAssertEqual(barrier.turnID, "turn")
            XCTAssertNil(barrier.result)
        }
    }

    func testForeignTurnCannotCompleteOrFailCurrentOperation() {
        var barrier = boundBarrier()
        barrier.acknowledged(operationID: barrier.id, generation: barrier.generation)
        XCTAssertFalse(barrier.itemCompleted(turnID: "old", operationID: barrier.id, generation: barrier.generation))
        XCTAssertFalse(barrier.terminal(turnID: "old", succeeded: true, operationID: barrier.id, generation: barrier.generation))
        XCTAssertFalse(barrier.terminal(turnID: "old", succeeded: false, operationID: barrier.id, generation: barrier.generation))
        XCTAssertNil(barrier.result)
    }

    func testTerminalFailureWinsBeforeAcknowledgementAndCannotBeOverridden() {
        var barrier = boundBarrier()
        barrier.itemCompleted(turnID: "turn", operationID: barrier.id, generation: barrier.generation)
        XCTAssertTrue(barrier.terminal(turnID: "turn", succeeded: false, operationID: barrier.id, generation: barrier.generation))
        XCTAssertFalse(barrier.acknowledged(operationID: barrier.id, generation: barrier.generation))
        XCTAssertFalse(barrier.terminal(turnID: "turn", succeeded: true, operationID: barrier.id, generation: barrier.generation))
        assertFailure(barrier, .turnFailed)
    }

    func testCancellationTimeoutDisconnectAndRPCFailureAreSticky() {
        for expected in [CompactionBarrier.Failure.cancelled, .timedOut, .disconnected, .rpcFailed("rejected")] {
            var barrier = boundBarrier()
            barrier.itemCompleted(turnID: "turn", operationID: barrier.id, generation: barrier.generation)
            barrier.terminal(turnID: "turn", succeeded: true, operationID: barrier.id, generation: barrier.generation)
            switch expected {
            case .cancelled: XCTAssertTrue(barrier.cancel(operationID: barrier.id, generation: barrier.generation))
            case .timedOut: XCTAssertTrue(barrier.timeout(operationID: barrier.id, generation: barrier.generation))
            case .disconnected: XCTAssertTrue(barrier.disconnect(operationID: barrier.id, generation: barrier.generation))
            default: XCTAssertTrue(barrier.fail(expected, operationID: barrier.id, generation: barrier.generation))
            }
            XCTAssertFalse(barrier.acknowledged(operationID: barrier.id, generation: barrier.generation))
            XCTAssertFalse(barrier.fail(.rpcFailed("late"), operationID: barrier.id, generation: barrier.generation))
            XCTAssertFalse(barrier.bindTurn("next-turn", operationID: barrier.id, generation: barrier.generation))
            assertFailure(barrier, expected)
        }
    }

    func testSuccessIsTerminalAndDuplicateSignalsDoNotResettle() throws {
        var barrier = boundBarrier()
        XCTAssertFalse(barrier.bindTurn("turn", operationID: barrier.id, generation: barrier.generation))
        barrier.acknowledged(operationID: barrier.id, generation: barrier.generation)
        XCTAssertFalse(barrier.acknowledged(operationID: barrier.id, generation: barrier.generation))
        barrier.itemCompleted(turnID: "turn", operationID: barrier.id, generation: barrier.generation)
        XCTAssertFalse(barrier.itemCompleted(turnID: "turn", operationID: barrier.id, generation: barrier.generation))
        barrier.terminal(turnID: "turn", succeeded: true, operationID: barrier.id, generation: barrier.generation)
        XCTAssertFalse(barrier.terminal(turnID: "turn", succeeded: true, operationID: barrier.id, generation: barrier.generation))
        XCTAssertFalse(barrier.cancel(operationID: barrier.id, generation: barrier.generation))
        XCTAssertFalse(barrier.disconnect(operationID: barrier.id, generation: barrier.generation))
        try XCTUnwrap(barrier.result).get()
    }

    func testTurnIdentityCannotBeEmptyOrRebound() {
        for invalid in ["", " \n", "other"] {
            var barrier = invalid == "other" ? boundBarrier() : CompactionBarrier(generation: UUID())
            XCTAssertTrue(barrier.bindTurn(invalid, operationID: barrier.id, generation: barrier.generation))
            guard case .failure(.protocolViolation) = barrier.result else {
                return XCTFail("Expected identity violation for \(invalid.debugDescription)")
            }
            XCTAssertFalse(barrier.acknowledged(operationID: barrier.id, generation: barrier.generation))
        }
    }

    private func boundBarrier() -> CompactionBarrier {
        var barrier = CompactionBarrier(generation: UUID())
        barrier.bindTurn("turn", operationID: barrier.id, generation: barrier.generation)
        return barrier
    }

    private func assertFailure(_ barrier: CompactionBarrier, _ expected: CompactionBarrier.Failure,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let actual) = barrier.result else {
            return XCTFail("Expected failure \(expected)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

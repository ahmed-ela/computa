import Foundation
import XCTest
@testable import Computa

final class ComputerRecoveryStateTests: XCTestCase {
    func testConnectionLossRetainsOriginalCauseAcrossMissingContextAndAlternatingRetries() throws {
        let generation = UUID()
        var state = ComputerRecoveryState()
        let original = ComputerRecoveryState.Failure(code: .connectionLost,
            message: "The bridge timed out during attachment.", recovery: .newConnection,
            connectionGeneration: generation)
        state.record(original)
        state.record(.init(code: .inventoryRequired, message: "No inventory.", recovery: .refreshInventory))
        let first = try XCTUnwrap(state.admitBind(target: nil))
        XCTAssertEqual(first.failure, original)
        XCTAssertFalse(first.shouldStop)
        let second = try XCTUnwrap(state.admitInventory(connectionGeneration: nil))
        XCTAssertEqual(second.failure, original)
        XCTAssertTrue(second.shouldStop)
        XCTAssertEqual(state.unresolvedFailures, [original])
        XCTAssertEqual(state.latestFailure, original)
    }

    func testInventoryRefreshCannotClearConnectionFailureOrResetItsRejectionBudget() throws {
        let generation = UUID()
        var state = ComputerRecoveryState()
        state.record(.init(code: .connectionLost, message: "Connection lost.", recovery: .newConnection,
                           connectionGeneration: generation))
        XCTAssertFalse(try XCTUnwrap(state.admitBind(target: nil)).shouldStop)
        state.inventoryRefreshed(connectionGeneration: generation, availableTargets: ["one"])
        XCTAssertTrue(try XCTUnwrap(state.admitBind(target: .init(connectionGeneration: generation, targetID: "one"))).shouldStop)
        state.connected(generation: generation)
        XCTAssertTrue(state.hasPendingRecovery, "Reusing the same generation is not a new authorized connection.")
        let replacement = UUID()
        state.connected(generation: replacement)
        XCTAssertFalse(state.hasPendingRecovery)
        XCTAssertNil(state.admitInventory(connectionGeneration: replacement))
        XCTAssertNotNil(state.latestFailure, "Keep the diagnostic history after recovery.")
    }

    func testBusyTargetNeedsPositiveAvailabilityAndDoesNotBlockOtherTargets() throws {
        let generation = UUID()
        let busy = ComputerRecoveryState.Target(connectionGeneration: generation, targetID: "one")
        let other = ComputerRecoveryState.Target(connectionGeneration: generation, targetID: "two")
        var state = ComputerRecoveryState()
        state.record(.init(code: .targetBusy, message: "Another debugger controls this tab.",
                           recovery: .targetAvailable, target: busy))
        XCTAssertNil(state.admitInventory(connectionGeneration: generation))
        XCTAssertNil(state.admitBind(target: other))
        XCTAssertFalse(try XCTUnwrap(state.admitBind(target: busy)).shouldStop)
        state.inventoryRefreshed(connectionGeneration: generation, availableTargets: ["two"])
        XCTAssertTrue(state.hasPendingRecovery, "Absent or unknown is not available.")
        state.inventoryRefreshed(connectionGeneration: UUID(), availableTargets: ["one"])
        XCTAssertTrue(state.hasPendingRecovery, "A different connection's target ID cannot recover this target.")
        XCTAssertTrue(try XCTUnwrap(state.admitBind(target: busy)).shouldStop)
        state.inventoryRefreshed(connectionGeneration: generation, availableTargets: ["one"])
        XCTAssertNil(state.admitBind(target: busy))
        XCTAssertFalse(state.hasPendingRecovery)
    }

    func testRefreshingStaleInventoryPreservesIndependentBusyRestriction() throws {
        let generation = UUID()
        let busy = ComputerRecoveryState.Target(connectionGeneration: generation, targetID: "one")
        let other = ComputerRecoveryState.Target(connectionGeneration: generation, targetID: "two")
        var state = ComputerRecoveryState()
        state.record(.init(code: .staleInventory, message: "The token is stale.", recovery: .refreshInventory,
                           connectionGeneration: generation))
        state.record(.init(code: .targetBusy, message: "The tab is busy.", recovery: .targetAvailable, target: busy))
        XCTAssertNotNil(state.admitBind(target: other))
        state.inventoryRefreshed(connectionGeneration: generation, availableTargets: ["two"])
        XCTAssertNil(state.admitBind(target: other))
        XCTAssertEqual(try XCTUnwrap(state.admitBind(target: busy)).failure.code, .targetBusy)
        XCTAssertEqual(state.unresolvedFailures.count, 1)
    }

    func testBusyFailureSurvivesTokenRefreshAndRepeatedRecording() throws {
        let target = ComputerRecoveryState.Target(connectionGeneration: UUID(), targetID: "stable-native-ID")
        let failure = ComputerRecoveryState.Failure(code: .targetBusy, message: "Original busy diagnostic.",
                                                   recovery: .targetAvailable, target: target)
        var state = ComputerRecoveryState()
        state.record(failure)
        XCTAssertFalse(try XCTUnwrap(state.admitBind(target: target)).shouldStop)
        state.record(.init(code: .operationRejected, message: "Secondary diagnostic.",
                           recovery: .targetAvailable, target: target))
        state.inventoryRefreshed(connectionGeneration: target.connectionGeneration, availableTargets: [])
        let repeated = try XCTUnwrap(state.admitBind(target: target))
        XCTAssertEqual(repeated.failure, failure)
        XCTAssertTrue(repeated.shouldStop)
        XCTAssertEqual(repeated.deniedAttempts, 2)
    }

    func testConnectionFailureDominatesEarlierTargetFailureWithoutLosingIt() throws {
        let target = ComputerRecoveryState.Target(connectionGeneration: UUID(), targetID: "one")
        var state = ComputerRecoveryState()
        state.record(.init(code: .targetBusy, message: "Busy.", recovery: .targetAvailable, target: target))
        state.record(.init(code: .connectionLost, message: "Connection lost.", recovery: .newConnection,
                           connectionGeneration: target.connectionGeneration))
        XCTAssertEqual(try XCTUnwrap(state.admitBind(target: target)).failure.code, .connectionLost)
        XCTAssertEqual(state.unresolvedFailures.count, 2)
        let replacement = UUID()
        state.connected(generation: replacement)
        XCTAssertNil(state.admitBind(target: .init(connectionGeneration: replacement, targetID: "one")))
    }
}

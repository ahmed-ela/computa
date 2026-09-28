import Foundation
import XCTest
@testable import Computa

final class ComputerObservedActionIdentitiesTests: XCTestCase {
    func testExactOldSnapshotRetainsStableIdentityAfterReindexing() throws {
        var history = ComputerObservedActionIdentities()
        let old = UUID(), current = UUID()
        try history.record(targetID: "connection:tab:document", snapshotID: old,
                           elements: [.init(index: 7, backendNodeID: 50, supportsSetText: true)])
        try history.record(targetID: "connection:tab:document", snapshotID: current,
                           elements: [.init(index: 22, backendNodeID: 50, supportsSetText: false)])

        let prior = try XCTUnwrap(history.lookup(currentTargetID: "connection:tab:document", snapshotID: old, elementIndex: 7))
        let latest = try XCTUnwrap(history.lookup(currentTargetID: "connection:tab:document", snapshotID: current, elementIndex: 22))
        XCTAssertEqual(prior.backendNodeID, latest.backendNodeID)
        XCTAssertTrue(prior.supportsSetText, "Retain the exact observed semantics, not a replacement snapshot's semantics.")
        XCTAssertFalse(latest.supportsSetText)
        XCTAssertNil(history.lookup(currentTargetID: "connection:tab:document", snapshotID: old, elementIndex: 22))
        XCTAssertNil(history.lookup(currentTargetID: "connection:tab:document", snapshotID: current, elementIndex: 7))
    }

    func testAnotherTargetConnectionOrDocumentCannotBorrowTheIdentity() throws {
        var history = ComputerObservedActionIdentities()
        let snapshot = UUID()
        try history.record(targetID: "connection-a:tab-one:document-a", snapshotID: snapshot, elements: [element()])
        for target in ["connection-a:tab-two:document-a", "connection-b:tab-one:document-a", "connection-a:tab-one:document-b", ""] {
            XCTAssertNil(history.lookup(currentTargetID: target, snapshotID: snapshot, elementIndex: 0))
        }
        XCTAssertNil(history.lookup(currentTargetID: "connection-a:tab-one:document-a", snapshotID: UUID(), elementIndex: 0))
        XCTAssertNil(history.lookup(currentTargetID: "connection-a:tab-one:document-a", snapshotID: snapshot, elementIndex: -1))
        XCTAssertNil(history.lookup(currentTargetID: "connection-a:tab-one:document-a", snapshotID: snapshot, elementIndex: 1))
    }

    func testOnlyEightSnapshotsAreRetainedAndReplaysDoNotExtendRetention() throws {
        var history = ComputerObservedActionIdentities()
        let ids = (0...ComputerObservedActionIdentities.maximumSnapshots).map { _ in UUID() }
        for id in ids.dropLast() { try history.record(targetID: "target", snapshotID: id, elements: [element()]) }
        try history.record(targetID: "target", snapshotID: ids[0], elements: [element()])
        try history.record(targetID: "target", snapshotID: ids.last!, elements: [element()])
        XCTAssertNil(history.lookup(currentTargetID: "target", snapshotID: ids[0], elementIndex: 0))
        for id in ids.dropFirst() {
            XCTAssertEqual(history.lookup(currentTargetID: "target", snapshotID: id, elementIndex: 0), element())
        }
    }

    func testConflictingSnapshotCannotReplaceTheOriginalIdentity() throws {
        var history = ComputerObservedActionIdentities()
        let id = UUID()
        try history.record(targetID: "target", snapshotID: id, elements: [element()])
        for candidate in [element(backendNodeID: 20), element(supportsSetText: false), element(index: 1)] {
            XCTAssertThrowsError(try history.record(targetID: "target", snapshotID: id, elements: [candidate])) {
                XCTAssertEqual($0 as? ComputerObservedActionIdentities.Failure, .conflictingSnapshot)
            }
        }
        XCTAssertThrowsError(try history.record(targetID: "other", snapshotID: id, elements: [element()])) {
            XCTAssertEqual($0 as? ComputerObservedActionIdentities.Failure, .conflictingSnapshot)
        }
        XCTAssertEqual(history.lookup(currentTargetID: "target", snapshotID: id, elementIndex: 0), element())
        XCTAssertNil(history.lookup(currentTargetID: "other", snapshotID: id, elementIndex: 0))
    }

    func testInvalidMappingsRejectAtomicallyWithoutEvictingHistory() throws {
        var history = ComputerObservedActionIdentities()
        let retained = UUID(), invalid = UUID()
        try history.record(targetID: "target", snapshotID: retained, elements: [element()])
        let invalidElements = [
            [element(index: -1)], [element(backendNodeID: 0)], [element(backendNodeID: -1)],
            [element(), element(backendNodeID: 20)],
        ]
        for elements in invalidElements {
            XCTAssertThrowsError(try history.record(targetID: "target", snapshotID: invalid, elements: elements))
            XCTAssertNil(history.lookup(currentTargetID: "target", snapshotID: invalid, elementIndex: 0))
            XCTAssertEqual(history.lookup(currentTargetID: "target", snapshotID: retained, elementIndex: 0), element())
        }
        XCTAssertThrowsError(try history.record(targetID: "target", snapshotID: invalid,
            elements: (0...ComputerObservedActionIdentities.maximumElements).map { element(index: $0) })) {
            XCTAssertEqual($0 as? ComputerObservedActionIdentities.Failure, .capacityExceeded)
        }
        for target in ["", "target\nforged", String(repeating: "x", count: 1_025)] {
            XCTAssertThrowsError(try history.record(targetID: target, snapshotID: invalid, elements: [])) {
                XCTAssertEqual($0 as? ComputerObservedActionIdentities.Failure, .invalidTarget)
            }
        }
        XCTAssertEqual(history.lookup(currentTargetID: "target", snapshotID: retained, elementIndex: 0), element())
    }

    func testEmptySnapshotCannotFabricateAnElement() throws {
        var history = ComputerObservedActionIdentities()
        let id = UUID()
        try history.record(targetID: "target", snapshotID: id, elements: [])
        XCTAssertNil(history.lookup(currentTargetID: "target", snapshotID: id, elementIndex: 0))
        XCTAssertThrowsError(try history.record(targetID: "target", snapshotID: id, elements: [element()])) {
            XCTAssertEqual($0 as? ComputerObservedActionIdentities.Failure, .conflictingSnapshot)
        }
    }

    private func element(index: Int = 0, backendNodeID: Int64 = 10,
                         supportsSetText: Bool = true) -> ComputerObservedActionIdentities.Element {
        .init(index: index, backendNodeID: backendNodeID, supportsSetText: supportsSetText)
    }
}

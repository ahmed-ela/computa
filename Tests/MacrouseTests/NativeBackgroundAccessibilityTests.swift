@testable import AutomationCore
import Foundation
import XCTest
@testable import Macrouse

@MainActor
final class NativeBackgroundAccessibilityTests: XCTestCase {
    private enum Failure: Error { case injected }

    private final class Backend: NativeBackgroundAccessibilityBackend {
        var selected = true
        var failRead = false
        var failAction = false
        var changeAfterRead = false
        var duringRead: (() -> Void)?
        var duringRefresh: (() -> Void)?
        var duringIdentityCheck: (() -> Void)?
        var checks = 0
        var reads = 0
        var actions = 0
        var values = [String]()
        var lastID: UUID?

        func isStillSelected() throws -> Bool {
            checks += 1
            duringIdentityCheck?()
            return selected
        }
        func snapshot(limits: AccessibilityTreeLimits) throws -> AccessibilityTreeSnapshot {
            reads += 1
            if failRead { throw Failure.injected }
            let id = UUID()
            lastID = id
            if changeAfterRead { selected = false }
            duringRead?()
            return AccessibilityTreeSnapshot(
                id: id,
                application: AccessibilityApplicationTarget(processIdentifier: 123,
                    bundleIdentifier: "com.example.fixture", applicationName: "Fixture"),
                limits: limits, rootIndex: 0,
                elements: (0...2).map { index in
                    AccessibilityTreeElement(
                        index: index, parentIndex: index == 0 ? nil : 0,
                        childIndices: index == 0 ? [1,2] : [], depth: index == 0 ? 0 : 1,
                        role: index == 0 ? "AXWindow" : index == 1 ? "AXButton" : "AXTextField",
                        subrole: nil, title: index == 1 ? "Native target" : "Synthetic input",
                        elementDescription: nil, help: nil, identifier: nil, domIdentifier: nil,
                        value: index == 2 ? "" : nil, frame: nil, isEnabled: true, isFocused: false,
                        supportedActions: index == 1 ? ["AXPress"] : [], isValueSettable: index == 2
                    )
                }, wasTruncated: false
            )
        }
        func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
            duringRefresh?()
            try beforeDispatch()
            actions += 1
            if failAction { throw Failure.injected }
        }
        func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
            duringRefresh?()
            try beforeDispatch()
            values.append(text)
        }
    }

    func testReadsAndActsOnTargetWithoutAnyForegroundOrActivationDependency() throws {
        // The production backend interface deliberately has no focus/activate/HID methods.
        let backend = Backend()
        let bound = NativeBackgroundAccessibility(backend: backend)
        let observation = try bound.read()
        XCTAssertTrue(observation.text.contains("activation=none"))
        XCTAssertTrue(observation.text.contains("global key/pointer tools still require"))
        XCTAssertEqual(try bound.elementName(snapshotID: observation.snapshotID, index: 1), "Native target")
        try bound.perform(snapshotID: observation.snapshotID, index: 1, action: .press)
        XCTAssertEqual(backend.actions, 1)
        XCTAssertThrowsError(try bound.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        XCTAssertEqual(backend.actions, 1)
    }

    func testTargetChangeBeforeReadProducesNoSnapshot() throws {
        let backend = Backend(); backend.selected = false
        XCTAssertThrowsError(try NativeBackgroundAccessibility(backend: backend).read())
        XCTAssertEqual(backend.reads, 0)
    }

    func testTargetChangeDuringReadDoesNotPublishCapability() throws {
        let backend = Backend(); backend.changeAfterRead = true
        let subject = NativeBackgroundAccessibility(backend: backend)
        XCTAssertThrowsError(try subject.read())
        backend.selected = true
        XCTAssertThrowsError(try subject.perform(snapshotID: XCTUnwrap(backend.lastID), index: 1, action: .press))
        XCTAssertEqual(backend.actions, 0)
    }

    func testTargetChangeAcrossApprovalPreventsDispatch() throws {
        let backend = Backend()
        let bound = NativeBackgroundAccessibility(backend: backend)
        let observation = try bound.read()
        _ = try bound.elementName(snapshotID: observation.snapshotID, index: 1)
        backend.selected = false
        XCTAssertThrowsError(try bound.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        XCTAssertEqual(backend.actions, 0)
    }

    func testUnknownOrUnexposedElementCannotDispatch() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 99, action: .press))
        XCTAssertThrowsError(try subject.perform(snapshotID: UUID(), index: 1, action: .press))
        XCTAssertEqual(backend.actions, 0)
    }

    func testFailedReadInvalidatesPreviousObservation() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        backend.failRead = true
        XCTAssertThrowsError(try subject.read())
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        XCTAssertEqual(backend.actions, 0)
    }

    func testFailedActionInvalidatesBeforeDispatchAndCannotBeReplayed() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read(); backend.failAction = true
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        XCTAssertEqual(backend.actions, 1)
    }

    func testSetTextUsesRetainedSemanticTargetAndConsumesObservation() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        try subject.setValue(snapshotID: observation.snapshotID, index: 2, text: "fixture")
        XCTAssertEqual(backend.values, ["fixture"])
        XCTAssertThrowsError(try subject.setValue(snapshotID: observation.snapshotID, index: 2, text: "again"))
        XCTAssertEqual(backend.values, ["fixture"])
    }

    func testCancellationPreventsReadAndDispatch() async throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
            XCTAssertThrowsError(try subject.read())
        }
        try await task.value
        XCTAssertEqual(backend.actions, 0)
        XCTAssertEqual(backend.reads, 1)
    }

    func testRaiseCannotDispatchInBackgroundLane() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .raise))
        XCTAssertEqual(backend.actions, 0)
    }

    func testRevocationWhileAwaitingMainActorPreventsDispatch() async throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        let queued = Task { @MainActor in
            XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        }
        subject.lifetime.revoke()
        try await queued.value
        XCTAssertEqual(backend.actions, 0)
    }

    func testRevocationDuringRefreshPreventsActionAndValueDispatch() throws {
        for setValue in [false, true] {
            let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
            let observation = try subject.read()
            backend.duringRefresh = { subject.lifetime.revoke() }
            if setValue {
                XCTAssertThrowsError(try subject.setValue(snapshotID: observation.snapshotID, index: 2, text: "never"))
            } else {
                XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
            }
            XCTAssertEqual(backend.actions, 0)
            XCTAssertTrue(backend.values.isEmpty)
        }
    }

    func testIdentityChangeDuringRefreshPreventsDispatch() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        backend.duringRefresh = { backend.selected = false }
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        XCTAssertEqual(backend.actions, 0)
    }

    func testRevocationDuringReadDoesNotPublishCapability() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        backend.duringRead = { subject.lifetime.revoke() }
        XCTAssertThrowsError(try subject.read())
        XCTAssertThrowsError(try subject.elementName(snapshotID: XCTUnwrap(backend.lastID), index: 1))
        XCTAssertEqual(backend.actions, 0)
    }

    func testRevocationDuringFinalIdentityReadPreventsDispatch() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        backend.duringRefresh = {
            backend.duringIdentityCheck = { subject.lifetime.revoke() }
        }
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        XCTAssertEqual(backend.actions, 0)
    }
}

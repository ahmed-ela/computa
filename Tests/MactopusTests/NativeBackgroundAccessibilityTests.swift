@testable import AutomationCore
import Foundation
import XCTest
@testable import Mactopus

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
        var duringAction: (() -> Void)?
        var duringIdentityCheck: (() -> Void)?
        var checks = 0
        var reads = 0
        var actions = 0
        var values = [String]()
        var lastID: UUID?
        var invalidations = 0
        var capabilityValid = false
        var exposedIndices: Set<Int>?
        var identifiers = [Int: String]()
        var domIdentifiers = [Int: String]()
        var nodeTokens = [Int: UUID]()
        var rowSelected: Bool? = nil
        var fieldValue = ""
        var suppliesReadReceipts = false
        var lastReadReceipt: SemanticReadReceipt?

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
            capabilityValid = true
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
                        elementDescription: nil, help: nil, identifier: identifiers[index], domIdentifier: domIdentifiers[index],
                        value: index == 2 ? fieldValue : nil, frame: nil, isEnabled: true, isFocused: false,
                        supportedActions: index == 1 ? ["AXPress"] : [], isValueSettable: index == 2,
                        isSelected: index == 1 ? rowSelected : nil, evidenceIdentity: nodeTokens[index]
                    )
                }, wasTruncated: false
            )
        }
        func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
            guard capabilityValid else { throw Failure.injected }
            duringRefresh?()
            try beforeDispatch()
            actions += 1
            duringAction?()
            if failAction { throw Failure.injected }
        }
        func semanticRead(_ request: SemanticReadRequest, outputCharacterLimit: Int) throws -> AccessibilitySemanticReadResult {
            let captured = try snapshot(limits: .agentDefault)
            let observation = AccessibilitySnapshotTextFormatter(elementLimit: 240,
                outputCharacterLimit: outputCharacterLimit, usesCompactElementLines: true,
                includedElementIndices: exposedIndices, allowsRaise: false).formatObservation(captured,
                    readRequest: suppliesReadReceipts ? request : nil)
            lastReadReceipt = observation.readReceipt
            return AccessibilitySemanticReadResult(snapshot: captured, observation: observation)
        }
        func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
            guard capabilityValid else { throw Failure.injected }
            duringRefresh?()
            try beforeDispatch()
            values.append(text)
            duringAction?()
            if failAction { throw Failure.injected }
        }
        func invalidateObservation() { invalidations += 1; capabilityValid = false }
    }

    func testReadReceiptPropagatesWithoutInventingLegacyVerificationCoverage() throws {
        let backend = Backend()
        let bound = NativeBackgroundAccessibility(backend: backend)
        XCTAssertNil(try bound.read().readReceipt)
        backend.suppliesReadReceipts = true
        let observation = try bound.read(read: .init(view: .content))
        XCTAssertNotNil(observation.readReceipt)
        XCTAssertEqual(observation.readReceipt, backend.lastReadReceipt)
        XCTAssertEqual(observation.snapshotID, observation.readReceipt?.sourceID)
        XCTAssertNil(try bound.readForVerification().readReceipt,
                     "Legacy full-tree verification does not certify body coverage")
    }

    func testReadsAndActsOnTargetWithoutAnyForegroundOrActivationDependency() throws {
        // The production backend interface deliberately has no focus/activate/HID methods.
        let backend = Backend()
        let bound = NativeBackgroundAccessibility(backend: backend)
        let observation = try bound.read()
        XCTAssertTrue(observation.text.contains("activation=none"))
        XCTAssertTrue(observation.text.contains("global key/pointer tools are unavailable"))
        XCTAssertEqual(try bound.elementName(snapshotID: observation.snapshotID, index: 1), "Native target")
        try bound.perform(snapshotID: observation.snapshotID, index: 1, action: .press)
        XCTAssertEqual(backend.actions, 1)
        XCTAssertEqual(backend.invalidations, 1)
        XCTAssertFalse(backend.capabilityValid)
        XCTAssertThrowsError(try bound.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
        XCTAssertEqual(backend.actions, 1)
    }

    func testVerifiedActionReadsBeforeDispatchOnceAndLeavesForegroundAlone() throws {
        let backend = Backend(); backend.rowSelected = false
        backend.nodeTokens = [0: UUID(), 1: UUID(), 2: UUID()]
        let foreground: Int32 = 777
        let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { foreground })
        _ = try subject.read()
        let scope = NativeActionVerification.Scope(evidenceTargetID: "native:fixture", processIdentifier: 123, bundleIdentifier: "com.example.fixture")
        let plan = try XCTUnwrap(NativeActionVerification.compile(action: .press, elementIndex: 1,
            observation: subject.verificationObservation(), scope: scope))
        backend.duringRefresh = { XCTAssertEqual(backend.reads, 2, "No nested snapshot may invalidate handles at the dispatch callback") }
        backend.duringAction = { backend.rowSelected = true }
        try subject.performVerified(plan: plan, action: .press, text: nil)
        XCTAssertEqual(backend.actions, 1)
        XCTAssertEqual(backend.reads, 2)
        XCTAssertFalse(backend.capabilityValid)
        _ = try subject.readForVerification(preferredText: plan.presentationQuery)
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: subject.verificationObservation()).expectedValue, "true")
        XCTAssertEqual(foreground, 777)
        XCTAssertNoThrow(try subject.lifetime.check())
        XCTAssertThrowsError(try subject.performVerified(plan: plan, action: .press, text: nil))
        XCTAssertEqual(backend.actions, 1, "Old baseline prevents duplicate input")
    }

    func testVerifiedBaselineChangeDuringApprovalStopsBeforeInput() throws {
        let backend = Backend(); backend.rowSelected = false
        backend.nodeTokens = [0: UUID(), 1: UUID(), 2: UUID()]
        let subject = NativeBackgroundAccessibility(backend: backend)
        _ = try subject.read()
        let plan = try XCTUnwrap(NativeActionVerification.compile(action: .press, elementIndex: 1,
            observation: subject.verificationObservation(), scope: .init(evidenceTargetID: "native:fixture", processIdentifier: 123,
                                                                         bundleIdentifier: "com.example.fixture")))
        backend.duringRead = { backend.rowSelected = true }
        XCTAssertThrowsError(try subject.performVerified(plan: plan, action: .press, text: nil)) { error in
            guard let failure = error as? NativeBackgroundAccessibility.MutationFailure else { return XCTFail("Expected mutation boundary evidence") }
            XCTAssertFalse(failure.dispatchBegan)
            XCTAssertEqual(failure.underlying as? NativeActionVerification.Failure, .baselineChanged)
        }
        XCTAssertEqual(backend.actions, 0)
    }

    func testVerifiedAlreadySatisfiedPlanCannotReachMutationHelper() throws {
        let backend = Backend(); backend.rowSelected = true
        backend.nodeTokens = [0: UUID(), 1: UUID(), 2: UUID()]
        let subject = NativeBackgroundAccessibility(backend: backend)
        _ = try subject.read()
        let plan = try XCTUnwrap(NativeActionVerification.compile(action: .press, elementIndex: 1,
            observation: subject.verificationObservation(), scope: .init(evidenceTargetID: "native:fixture", processIdentifier: 123,
                                                                         bundleIdentifier: "com.example.fixture")))
        XCTAssertTrue(plan.alreadySatisfied)
        XCTAssertThrowsError(try subject.performVerified(plan: plan, action: .press, text: nil)) { error in
            XCTAssertEqual((error as? NativeBackgroundAccessibility.MutationFailure)?.dispatchBegan, false)
        }
        XCTAssertEqual(backend.actions, 0)
    }

    func testVerifiedForegroundChangeRecordsActualBoundaryWithoutRestoringOrReplaying() throws {
        for beforeDispatch in [true, false] {
            let backend = Backend(); backend.rowSelected = false
            backend.nodeTokens = [0: UUID(), 1: UUID(), 2: UUID()]
            var foreground: Int32 = 777
            let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { foreground })
            _ = try subject.read()
            let plan = try XCTUnwrap(NativeActionVerification.compile(action: .press, elementIndex: 1,
                observation: subject.verificationObservation(), scope: .init(evidenceTargetID: "native:fixture", processIdentifier: 123,
                                                                             bundleIdentifier: "com.example.fixture")))
            if beforeDispatch { backend.duringRefresh = { foreground = 123 } }
            else { backend.duringAction = { foreground = 123 } }
            XCTAssertThrowsError(try subject.performVerified(plan: plan, action: .press, text: nil)) { error in
                guard let failure = error as? NativeBackgroundAccessibility.MutationFailure else { return XCTFail("Expected dispatch evidence") }
                XCTAssertEqual(failure.dispatchBegan, !beforeDispatch)
                XCTAssertEqual(failure.underlying as? NativeBackgroundAccessibility.Failure, .focusChangedDuringAction)
            }
            XCTAssertEqual(backend.actions, beforeDispatch ? 0 : 1)
            XCTAssertEqual(foreground, 123, "Never restore focus")
            XCTAssertThrowsError(try subject.lifetime.check())
            XCTAssertThrowsError(try subject.performVerified(plan: plan, action: .press, text: nil))
            XCTAssertEqual(backend.actions, beforeDispatch ? 0 : 1)
        }
    }

    func testVerifiedInputFailureAfterBoundaryRemainsUncertainWhileCancellationSendsNothing() async throws {
        let backend = Backend(); backend.nodeTokens = [0: UUID(), 1: UUID(), 2: UUID()]
        let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { 777 })
        _ = try subject.read()
        let plan = try XCTUnwrap(NativeActionVerification.compile(action: .setText("Once"), elementIndex: 2,
            observation: subject.verificationObservation(), scope: .init(evidenceTargetID: "native:fixture", processIdentifier: 123,
                                                                         bundleIdentifier: "com.example.fixture")))
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try subject.performVerified(plan: plan, action: nil, text: "Once")) { error in
                XCTAssertEqual((error as? NativeBackgroundAccessibility.MutationFailure)?.dispatchBegan, false)
            }
        }
        try await cancelled.value
        XCTAssertTrue(backend.values.isEmpty)
        backend.failAction = true
        XCTAssertThrowsError(try subject.performVerified(plan: plan, action: nil, text: "Once")) { error in
            guard let failure = error as? NativeBackgroundAccessibility.MutationFailure else { return XCTFail("Expected dispatch evidence") }
            XCTAssertTrue(failure.dispatchBegan)
        }
        XCTAssertEqual(backend.values, ["Once"])
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

    func testStableForegroundAllowsOneSemanticActionAndSetValueWithoutRevokingLane() throws {
        let backend = Backend()
        var foreground: Int32? = 777
        let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { foreground })
        let first = try subject.read()
        try subject.perform(snapshotID: first.snapshotID, index: 1, action: .press)
        // A user switch between actions is allowed. Only the action boundary
        // is compared, not focus at the time an earlier snapshot was captured.
        foreground = 888
        let second = try subject.read()
        try subject.setValue(snapshotID: second.snapshotID, index: 2, text: "fixture")
        XCTAssertEqual(backend.actions, 1)
        XCTAssertEqual(backend.values, ["fixture"])
        XCTAssertNoThrow(try subject.lifetime.check())
        XCTAssertEqual(foreground, 888)
    }

    func testForegroundTransitionDuringSemanticMutationRevokesWithoutReplayOrRestore() throws {
        for setValue in [false, true] {
            let backend = Backend()
            var foreground: Int32? = 777
            let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { foreground })
            let observation = try subject.read()
            backend.duringAction = { foreground = 123 }
            XCTAssertThrowsError(try {
                if setValue { try subject.setValue(snapshotID: observation.snapshotID, index: 2, text: "once") }
                else { try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press) }
            }()) { error in
                guard case NativeBackgroundAccessibility.Failure.focusChangedDuringAction = error else {
                    return XCTFail("Expected uncertain foreground-change failure, got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("may have been dispatched"))
                XCTAssertTrue(error.localizedDescription.contains("app or the user"))
            }
            XCTAssertEqual(backend.actions, setValue ? 0 : 1)
            XCTAssertEqual(backend.values, setValue ? ["once"] : [])
            XCTAssertEqual(foreground, 123, "Never restore the previous foreground automatically.")
            XCTAssertThrowsError(try subject.lifetime.check())
            XCTAssertFalse(backend.capabilityValid)
            XCTAssertThrowsError(try subject.read())
            XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press))
            XCTAssertThrowsError(try subject.setValue(snapshotID: observation.snapshotID, index: 2, text: "retry"))
            XCTAssertEqual(backend.actions, setValue ? 0 : 1)
            XCTAssertEqual(backend.values, setValue ? ["once"] : [])
        }
    }

    func testForegroundTransitionDuringRefreshStopsBeforeDispatch() throws {
        for setValue in [false, true] {
            let backend = Backend()
            var foreground: Int32? = 777
            let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { foreground })
            let observation = try subject.read()
            backend.duringRefresh = { foreground = 888 }
            XCTAssertThrowsError(try {
                if setValue { try subject.setValue(snapshotID: observation.snapshotID, index: 2, text: "never") }
                else { try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press) }
            }()) { error in
                guard case NativeBackgroundAccessibility.Failure.focusChangedDuringAction = error else {
                    return XCTFail("Expected foreground-change failure, got \(error)")
                }
            }
            XCTAssertEqual(backend.actions, 0)
            XCTAssertTrue(backend.values.isEmpty)
            XCTAssertThrowsError(try subject.lifetime.check())
            XCTAssertEqual(foreground, 888)
        }
    }

    func testForegroundTransitionIsDetectedEvenWhenBackendThrowsAfterDispatch() throws {
        for setValue in [false, true] {
            let backend = Backend()
            var foreground: Int32? = 777
            let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { foreground })
            let observation = try subject.read()
            backend.failAction = true
            backend.duringAction = { foreground = 123 }
            XCTAssertThrowsError(try {
                if setValue { try subject.setValue(snapshotID: observation.snapshotID, index: 2, text: "uncertain") }
                else { try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press) }
            }()) { error in
                guard case NativeBackgroundAccessibility.Failure.focusChangedDuringAction = error else {
                    return XCTFail("The side effect must remain visible on the error path: \(error)")
                }
            }
            XCTAssertEqual(backend.actions, setValue ? 0 : 1)
            XCTAssertEqual(backend.values, setValue ? ["uncertain"] : [])
            XCTAssertThrowsError(try subject.lifetime.check())
            XCTAssertEqual(foreground, 123)
        }
    }

    func testUnchangedForegroundPreservesOriginalBackendError() throws {
        let backend = Backend()
        let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { 777 })
        let observation = try subject.read()
        backend.failAction = true
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press)) { error in
            guard case Failure.injected = error else { return XCTFail("Expected original backend error, got \(error)") }
        }
        XCTAssertEqual(backend.actions, 1)
        XCTAssertNoThrow(try subject.lifetime.check())
        XCTAssertFalse(backend.capabilityValid)
    }

    func testUserForegroundSwitchAfterObservationButBeforeActionIsNotBlamedOnAction() throws {
        let backend = Backend()
        var foreground: Int32? = 777
        let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { foreground })
        let observation = try subject.read()
        foreground = 888
        try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press)
        XCTAssertEqual(backend.actions, 1)
        XCTAssertEqual(foreground, 888)
        XCTAssertNoThrow(try subject.lifetime.check())
    }

    func testUnknownForegroundTransitionRevokesConservatively() throws {
        let backend = Backend()
        var foreground: Int32? = nil
        let subject = NativeBackgroundAccessibility(backend: backend, foregroundProcessIdentifier: { foreground })
        let observation = try subject.read()
        backend.duringAction = { foreground = 123 }
        XCTAssertThrowsError(try subject.perform(snapshotID: observation.snapshotID, index: 1, action: .press)) { error in
            guard case NativeBackgroundAccessibility.Failure.focusChangedDuringAction = error else {
                return XCTFail("Expected uncertainty when foreground identity becomes known: \(error)")
            }
        }
        XCTAssertEqual(backend.actions, 1)
        XCTAssertEqual(foreground, 123)
        XCTAssertThrowsError(try subject.lifetime.check())
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

    func testObservedPropertiesContainOnlyActualExposedTextAndValues() throws {
        let backend = Backend(); backend.exposedIndices = [1, 2]
        backend.identifiers = [1: "button", 2: "input"]
        let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        let buttonText = try subject.canonicalEvidenceProperty(snapshotID: observation.snapshotID, index: 1, field: "text")
        let inputText = try subject.canonicalEvidenceProperty(snapshotID: observation.snapshotID, index: 2, field: "text")
        let inputValue = try subject.canonicalEvidenceProperty(snapshotID: observation.snapshotID, index: 2, field: "value")
        XCTAssertEqual(try subject.observedProperties(snapshotID: observation.snapshotID), [
            buttonText: "Native target", inputText: "Synthetic input", inputValue: "",
        ])
        XCTAssertEqual(backend.reads, 1, "Reading retained properties must not silently replace the snapshot.")
        XCTAssertEqual(backend.actions, 0)
        XCTAssertTrue(backend.values.isEmpty)
    }

    func testObservedPropertiesRejectStaleIDsConsumedSnapshotsAndChangedTargets() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let first = try subject.read()
        XCTAssertThrowsError(try subject.observedProperties(snapshotID: UUID()))
        let second = try subject.read()
        XCTAssertThrowsError(try subject.observedProperties(snapshotID: first.snapshotID))
        try subject.setValue(snapshotID: second.snapshotID, index: 2, text: "dispatched only")
        XCTAssertThrowsError(try subject.observedProperties(snapshotID: second.snapshotID))
        let third = try subject.read()
        backend.selected = false
        XCTAssertThrowsError(try subject.observedProperties(snapshotID: third.snapshotID))
    }

    func testObservedPropertiesRejectRevokedLifetimeIncludingDuringIdentityRead() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        backend.duringIdentityCheck = { subject.lifetime.revoke() }
        XCTAssertThrowsError(try subject.observedProperties(snapshotID: observation.snapshotID))
        XCTAssertEqual(backend.actions, 0)
    }

    func testCurrentObservedPropertiesKeepSnapshotIdentityAndAbsenceDistinct() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        XCTAssertNil(try subject.currentObservedProperties())
        let observation = try subject.read()
        let current = try XCTUnwrap(subject.currentObservedProperties())
        XCTAssertEqual(current.id, observation.snapshotID)
        XCTAssertTrue(current.isLive)
        XCTAssertEqual(current.properties, try subject.observedProperties(snapshotID: observation.snapshotID))
        subject.invalidate()
        XCTAssertNil(try subject.currentObservedProperties())
        backend.selected = false
        XCTAssertThrowsError(try subject.currentObservedProperties())
    }

    func testRetainedNativeReadCannotBeLabeledFreshLiveEvidence() throws {
        let backend = Backend(); let subject = NativeBackgroundAccessibility(backend: backend)
        let first = try subject.read()
        _ = try subject.read(read: SemanticReadRequest(snapshotID: first.snapshotID, elementIndex: 1))
        XCTAssertFalse(try XCTUnwrap(subject.currentObservedProperties()).isLive)
        _ = try subject.read()
        XCTAssertTrue(try XCTUnwrap(subject.currentObservedProperties()).isLive)
    }

    func testObservedIdentityUsesOnlyActualUniqueIdentifiersAcrossEntireSnapshot() throws {
        let backend = Backend(); backend.exposedIndices = [1, 2]
        backend.identifiers = [0: "duplicate", 1: "duplicate", 2: "actual-input"]
        backend.domIdentifiers = [1: "unique-button"]
        let subject = NativeBackgroundAccessibility(backend: backend)
        let observation = try subject.read()
        let properties = try subject.observedProperties(snapshotID: observation.snapshotID)
        let button = try subject.canonicalEvidenceProperty(snapshotID: observation.snapshotID, index: 1, field: "text")
        let input = try subject.canonicalEvidenceProperty(snapshotID: observation.snapshotID, index: 2, field: "value")
        XCTAssertEqual(properties[button], "Native target")
        XCTAssertEqual(properties[input], "")
        XCTAssertThrowsError(try subject.canonicalEvidenceProperty(snapshotID: observation.snapshotID, index: 0, field: "text"))
        backend.domIdentifiers = [0: "duplicate-dom", 1: "duplicate-dom"]
        let second = try subject.read()
        XCTAssertThrowsError(try subject.canonicalEvidenceProperty(snapshotID: second.snapshotID, index: 1, field: "text"))
        XCTAssertNil(try subject.observedProperties(snapshotID: second.snapshotID)[button])
    }
}

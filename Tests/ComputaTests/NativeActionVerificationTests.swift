@testable import AutomationCore
import Foundation
import XCTest
@testable import Computa

final class NativeActionVerificationTests: XCTestCase {
    private typealias Native = NativeActionVerification
    private let scope = Native.Scope(evidenceTargetID: "native:fixture-window", processIdentifier: 42, bundleIdentifier: "test.fixture")
    private let rootToken = UUID(), rowToken = UUID(), regionToken = UUID(), editorToken = UUID()

    func testSelectionIsDerivedFromObservedAXSelectedAndUsesExactIdentityAfterReordering() throws {
        let before = observation([root([1, 2]), row(1, selected: false), node(2, role: "AXButton", title: "Other", token: UUID())])
        let plan = try requirePlan(action: .press, before: before)
        XCTAssertEqual(plan.kind, .selection)
        XCTAssertFalse(plan.baselineSatisfied)
        let after = observation([root([1, 2]), node(1, role: "AXButton", title: "Other", token: UUID()), row(2, selected: true)], exposed: [0])
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: after).expectedValue, "true")
        XCTAssertEqual(try plan.actionElementIndex(in: after), 2)
        XCTAssertTrue(plan.property.contains(rowToken.uuidString))
    }

    func testAlreadySelectedProducesStatePlanWithoutDemandingMutation() throws {
        let before = observation([root([1]), row(1, selected: true)])
        let plan = try requirePlan(action: .press, before: before)
        XCTAssertTrue(plan.alreadySatisfied)
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: before).expectedValue, "true")
        XCTAssertNoThrow(try plan.revalidateBaseline(observation: before))
        let after = observation([root([1]), row(1, selected: false)])
        assertFailure(.postconditionNotObserved) { try plan.evaluate(scope: scope, observation: after) }
    }

    func testValuePlanAllowsEmptyStringAndAlreadyPresentValueWithoutRepeatedInput() throws {
        let before = observation([root([1]), node(1, role: "AXTextField", title: "Field", value: "old", token: editorToken, settable: true)])
        let plan = try requirePlan(action: .setText(""), before: before)
        let after = observation([root([1]), node(1, role: "AXTextField", title: "Field", value: "", token: editorToken, settable: true)])
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: after).expectedValue, "")
        let noOp = try requirePlan(action: .setText("old"), before: before)
        XCTAssertTrue(noOp.alreadySatisfied)
    }

    func testUnknownSelectedStateDoesNotInventSelectionAndNoGenericPressMeaning() throws {
        let before = observation([root([1]), node(1, role: "AXButton", title: "Open", token: rowToken)])
        XCTAssertNil(try Native.compile(action: .press, elementIndex: 1, observation: before, scope: scope))
        assertFailure(.missingProperty) {
            try Native.compile(request: .init(kind: .selection, expected: "true"), action: .press,
                elementIndex: 1, observation: before, scope: scope)
        }
    }

    func testSameLabelReplacementAndDuplicateTokensNeverRebindSelection() throws {
        let before = observation([root([1]), row(1, selected: false)])
        let plan = try requirePlan(action: .press, before: before)
        let replaced = observation([root([1]), node(1, role: "AXRow", title: "Conversation", token: UUID(), selected: true)])
        assertFailure(.unstableIdentity) { try plan.evaluate(scope: scope, observation: replaced) }
        let duplicate = observation([root([1, 2]), row(1, selected: true), row(2, selected: true)])
        assertFailure(.ambiguousIdentity) { try plan.evaluate(scope: scope, observation: duplicate) }
    }

    func testRecycledExactAXObjectWithAnotherRowLabelOrValueCannotVerifyOriginalSelection() throws {
        for valueOnly in [false, true] {
            let beforeRow = node(1, role: "AXRow", title: valueOnly ? nil : "First conversation",
                value: valueOnly ? "First conversation" : nil, token: rowToken, selected: false)
            let plan = try requirePlan(action: .press, before: observation([root([1]), beforeRow]))
            let afterRow = node(1, role: "AXRow", title: valueOnly ? nil : "Another conversation",
                value: valueOnly ? "Another conversation" : nil, token: rowToken, selected: true)
            assertFailure(.wrongTarget) { try plan.evaluate(scope: scope, observation: observation([root([1]), afterRow])) }
        }
    }

    func testStringCompletenessMetadataRejectsPrefixesButAllowsExactLimitWhenKnownComplete() throws {
        let text = String(repeating: "x", count: AccessibilityTreeLimits.agentDefault.maxTextLength)
        let complete = observation([root([1]), node(1, role: "AXTextField", title: "Field", value: text,
            token: editorToken, settable: true, fieldsTruncated: false)], truncated: true)
        XCTAssertNoThrow(try requirePlan(action: .setText("short"), before: complete))
        for knownTruncated in [true, false] {
            let unsafe = observation([root([1]), node(1, role: "AXTextField", title: "Field", value: text,
                token: editorToken, settable: true, fieldsTruncated: knownTruncated ? true : nil)], truncated: !knownTruncated)
            assertFailure(.incompleteEvidence) { try requirePlan(action: .setText("short"), before: unsafe) }
        }
    }

    func testStableIdentifierFallbackRequiresCompleteUniqueSource() throws {
        let before = observation([root([1]), node(1, role: "AXRow", title: "Conversation", identifier: "stable-row", selected: false)])
        let plan = try requirePlan(action: .press, before: before)
        let after = observation([root([1]), node(1, role: "AXRow", title: "Conversation", identifier: "stable-row", selected: true)])
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: after).expectedValue, "true")
        let incomplete = observation(after.snapshot.elements, truncated: true)
        assertFailure(.incompleteEvidence) { try plan.evaluate(scope: scope, observation: incomplete) }
        let duplicate = observation([root([1, 2]), node(1, role: "AXRow", title: "A", identifier: "stable-row", selected: true),
                                     node(2, role: "AXRow", title: "B", identifier: "stable-row", selected: false)])
        assertFailure(.ambiguousIdentity) { try plan.evaluate(scope: scope, observation: duplicate) }
    }

    func testExactTokenSelectionSurvivesPartialPresentationButMissingValueCannotProveAnything() throws {
        let before = observation([root([1]), row(1, selected: false)], truncated: true)
        let plan = try requirePlan(action: .press, before: before)
        let after = observation([root([1]), row(1, selected: true)], exposed: [], truncated: true)
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: after).expectedValue, "true")
        let missingValue = observation([root([1]), node(1, role: "AXTextField", title: "Input", token: editorToken, settable: true)])
        assertFailure(.missingProperty) { try requirePlan(action: .setText("hello"), before: missingValue) }
    }

    func testRegionTextSurvivesReplacedChildrenButCannotUseAnotherRegionOrUnrelatedChanges() throws {
        let before = regionObservation("Counter 0", childToken: UUID())
        let plan = try requirePlan(request: .init(kind: .regionText, expected: "Counter 1", elementIndex: 2), action: .press, before: before)
        let after = regionObservation("Counter 1", childToken: UUID())
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: after).expectedValue, "Counter 1")
        assertFailure(.postconditionNotObserved) { try plan.evaluate(scope: scope, observation: regionObservation("Counter 0", childToken: UUID())) }
        let replacedRegion = observation([root([1, 2]), row(1), node(2, role: "AXGroup", title: "Result", token: UUID(), children: [3]),
                                         node(3, parent: 2, role: "AXStaticText", value: "Counter 1", token: UUID())])
        assertFailure(.unstableIdentity) { try plan.evaluate(scope: scope, observation: replacedRegion) }
    }

    func testDetailViewRequiresExactTargetFieldInDisjointStableRegionAndUniqueResult() throws {
        let before = regionObservation("Other detail", childToken: UUID())
        let request = Native.Request(kind: .detailView, expected: "Conversation", detailElementIndex: 2)
        let plan = try requirePlan(request: request, action: .press, before: before)
        let after = regionObservation("Conversation", childToken: UUID())
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: after).expectedValue, "Conversation")
        XCTAssertFalse(plan.alreadySatisfied)
        assertFailure(.invalidRequest) {
            try requirePlan(request: .init(kind: .detailView, expected: "Conver", detailElementIndex: 2), action: .press, before: before)
        }
        assertFailure(.postconditionNotObserved) { try plan.evaluate(scope: scope, observation: regionObservation("Wrong detail", childToken: UUID())) }
        let duplicate = observation([root([1, 2]), row(1), node(2, role: "AXGroup", title: "Result", token: regionToken, children: [3, 4]),
            node(3, parent: 2, role: "AXStaticText", value: "Conversation", token: UUID()),
            node(4, parent: 2, role: "AXStaticText", value: "Conversation", token: UUID())])
        assertFailure(.ambiguousIdentity) { try plan.evaluate(scope: scope, observation: duplicate) }
    }

    func testDetailViewRejectsOverlappingRegionDuplicateRowAndPartialAbsence() throws {
        let before = regionObservation("Other detail", childToken: UUID())
        assertFailure(.invalidRequest) {
            try requirePlan(request: .init(kind: .detailView, expected: "Conversation", detailElementIndex: 0), action: .press, before: before)
        }
        let incomplete = observation(before.snapshot.elements, truncated: true)
        assertFailure(.incompleteEvidence) {
            try requirePlan(request: .init(kind: .detailView, expected: "Conversation", detailElementIndex: 2), action: .press, before: incomplete)
        }
        let duplicateRow = observation([root([1, 2, 4]), row(1), node(2, role: "AXGroup", title: "Result", token: regionToken, children: [3]),
            node(3, parent: 2, role: "AXStaticText", value: "Other", token: UUID()),
            node(4, role: "AXRow", title: "Conversation", token: UUID())])
        assertFailure(.ambiguousIdentity) {
            try requirePlan(request: .init(kind: .detailView, expected: "Conversation", detailElementIndex: 2), action: .press, before: duplicateRow)
        }
    }

    func testDetailViewCombinesSelectionWhenAvailableAndCannotBeProvedBySelectionAlone() throws {
        func detail(_ selected: Bool, _ text: String) -> Native.Observation {
            observation([root([1, 2]), row(1, selected: selected),
                node(2, role: "AXGroup", title: "Result", token: regionToken, children: [3]),
                node(3, parent: 2, role: "AXStaticText", value: text, token: UUID())])
        }
        let request = Native.Request(kind: .detailView, expected: "Conversation", detailElementIndex: 2)
        let plan = try requirePlan(request: request, action: .press, before: detail(false, "Other detail"))
        assertFailure(.postconditionNotObserved) { try plan.evaluate(scope: scope, observation: detail(false, "Conversation")) }
        assertFailure(.postconditionNotObserved) { try plan.evaluate(scope: scope, observation: detail(true, "Other detail")) }
        XCTAssertEqual(try plan.evaluate(scope: scope, observation: detail(true, "Conversation")).expectedValue, "Conversation")
        let presentButNotSelected = try requirePlan(request: request, action: .press, before: detail(false, "Conversation"))
        XCTAssertFalse(presentButNotSelected.alreadySatisfied)
        XCTAssertEqual(try presentButNotSelected.evaluate(scope: scope, observation: detail(true, "Conversation")).expectedValue, "Conversation")
        XCTAssertTrue(try requirePlan(request: request, action: .press, before: detail(true, "Conversation")).alreadySatisfied)
    }

    func testDetailViewRevalidatesDescendantLabelOnRetainedRowBeforeInputAndProof() throws {
        func detail(rowText: String, selected: Bool, result: String) -> Native.Observation {
            observation([root([1, 2]), node(1, role: "AXRow", token: rowToken, selected: selected, children: [4]),
                node(4, parent: 1, role: "AXStaticText", value: rowText, token: UUID()),
                node(2, role: "AXGroup", title: "Result", token: regionToken, children: [3]),
                node(3, parent: 2, role: "AXStaticText", value: result, token: UUID())])
        }
        let before = detail(rowText: "Conversation", selected: false, result: "Other detail")
        let plan = try requirePlan(request: .init(kind: .detailView, expected: "Conversation", detailElementIndex: 2),
                                   action: .press, before: before)
        XCTAssertNoThrow(try plan.revalidateBaseline(observation: detail(rowText: "Conversation", selected: false, result: "Other detail")))
        assertFailure(.baselineChanged) {
            try plan.revalidateBaseline(observation: detail(rowText: "Another conversation", selected: false, result: "Other detail"))
        }
        assertFailure(.wrongTarget) {
            try plan.evaluate(scope: scope, observation: detail(rowText: "Another conversation", selected: true, result: "Conversation"))
        }
    }

    func testDetailViewRejectsDuplicateRowNamesExposedOnlyByDescendantsAtEveryBoundary() throws {
        func detail(duplicate: Bool, selected: Bool, result: String) -> Native.Observation {
            var elements = [root(duplicate ? [1, 2, 5] : [1, 2]),
                node(1, role: "AXRow", token: rowToken, selected: selected, children: [4]),
                node(4, parent: 1, role: "AXStaticText", value: "Conversation", token: UUID()),
                node(2, role: "AXGroup", title: "Result", token: regionToken, children: [3]),
                node(3, parent: 2, role: "AXStaticText", value: result, token: UUID())]
            if duplicate {
                elements += [node(5, role: "AXRow", token: UUID(), selected: false, children: [6]),
                    node(6, parent: 5, role: "AXStaticText", value: "Conversation", token: UUID())]
            }
            return observation(elements)
        }
        let request = Native.Request(kind: .detailView, expected: "Conversation", detailElementIndex: 2)
        let plan = try requirePlan(request: request, action: .press,
                                   before: detail(duplicate: false, selected: false, result: "Other detail"))
        let duplicateBefore = detail(duplicate: true, selected: false, result: "Other detail")
        assertFailure(.ambiguousIdentity) { try requirePlan(request: request, action: .press, before: duplicateBefore) }
        assertFailure(.ambiguousIdentity) { try plan.revalidateBaseline(observation: duplicateBefore) }
        assertFailure(.ambiguousIdentity) {
            try plan.evaluate(scope: scope, observation: detail(duplicate: true, selected: true, result: "Conversation"))
        }
    }

    func testBaselineDriftWrongScopeUnexposedAndRetainedObservationsFailClosed() throws {
        let before = observation([root([1]), row(1, selected: false)])
        let plan = try requirePlan(action: .press, before: before)
        let after = observation([root([1]), row(1, selected: true)])
        assertFailure(.baselineChanged) { try plan.revalidateBaseline(observation: after) }
        assertFailure(.wrongTarget) {
            try plan.evaluate(scope: .init(evidenceTargetID: "native:another-window", processIdentifier: 42, bundleIdentifier: "test.fixture"), observation: after)
        }
        assertFailure(.staleObservation) { try plan.evaluate(scope: scope, observation: before) }
        assertFailure(.staleObservation) {
            try plan.evaluate(scope: scope, observation: .init(snapshot: after.snapshot, exposedIndices: [1], isLive: false))
        }
        assertFailure(.unexposedElement) {
            try Native.compile(action: .press, elementIndex: 1,
                observation: .init(snapshot: before.snapshot, exposedIndices: [0], isLive: true), scope: scope)
        }
    }

    func testPlansPreserveIdentityBaselineAndNoOpStatusAcrossCodableRoundtrip() throws {
        for selected in [false, true] {
            let before = observation([root([1]), row(1, selected: selected)])
            let plan = try requirePlan(action: .press, before: before)
            let decoded = try JSONDecoder().decode(Native.Plan.self, from: JSONEncoder().encode(plan))
            XCTAssertEqual(decoded, plan)
            XCTAssertNoThrow(try decoded.validate())
            XCTAssertEqual(decoded.presentationQuery, "Conversation")
            XCTAssertEqual(decoded.alreadySatisfied, selected)
        }
    }

    private func requirePlan(request: Native.Request? = nil, action: Native.Action, before: Native.Observation) throws -> Native.Plan {
        guard let plan = try Native.compile(request: request, action: action, elementIndex: 1, observation: before, scope: scope) else { throw Native.Failure.invalidPlan }
        return plan
    }
    private func regionObservation(_ text: String, childToken: UUID) -> Native.Observation {
        observation([root([1, 2]), row(1), node(2, role: "AXGroup", title: "Result", token: regionToken, children: [3]),
            node(3, parent: 2, role: "AXStaticText", value: text, token: childToken)])
    }
    private func row(_ index: Int, selected: Bool? = nil) -> AccessibilityTreeElement {
        node(index, role: "AXRow", title: "Conversation", token: rowToken, selected: selected)
    }
    private func root(_ children: [Int]) -> AccessibilityTreeElement {
        node(0, parent: nil, role: "AXWindow", title: "Fixture", token: rootToken, children: children)
    }
    private func node(_ index: Int, parent: Int? = 0, role: String, title: String? = nil, value: String? = nil,
                      token: UUID? = nil, identifier: String? = nil, selected: Bool? = nil,
                      settable: Bool = false, children: [Int] = [], fieldsTruncated: Bool? = nil) -> AccessibilityTreeElement {
        AccessibilityTreeElement(index: index, parentIndex: parent, childIndices: children, depth: parent == nil ? 0 : 1,
            role: role, subrole: nil, title: title, elementDescription: nil, help: nil, identifier: identifier,
            domIdentifier: nil, value: value, frame: nil, isEnabled: true, isFocused: false,
            supportedActions: ["AXPress"], isValueSettable: settable, isSelected: selected, evidenceIdentity: token,
            evidenceFieldsTruncated: fieldsTruncated)
    }
    private func observation(_ elements: [AccessibilityTreeElement], exposed: Set<Int>? = nil, truncated: Bool = false) -> Native.Observation {
        .init(snapshot: AccessibilityTreeSnapshot(id: UUID(), application: .init(processIdentifier: 42, bundleIdentifier: "test.fixture"),
            limits: .agentDefault, rootIndex: 0, elements: elements, wasTruncated: truncated),
              exposedIndices: exposed ?? Set(elements.map(\.index)), isLive: true)
    }
    private func assertFailure<T>(_ failure: Native.Failure, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? Native.Failure, failure, file: file, line: line) }
    }
}

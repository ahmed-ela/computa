import Foundation
import XCTest
@testable import Mactopus

final class BrowserActionVerificationTests: XCTestCase {
    private typealias Verification = BrowserActionVerification

    func testExactObservedLinkURLIsAutomaticAndRejectsAnUnrelatedChange() throws {
        let binding = binding()
        let before = snapshot(binding, nodes: documentNodes(), displayed: [element(10, "link", "Open", link: "https://example.test/detail")])
        let plan = try XCTUnwrap(Verification.compile(action: .press, elementIndex: 0, snapshot: before, binding: binding))
        XCTAssertEqual(plan.kind, .documentURL)
        let afterBinding = replacing(binding, documentEpoch: UUID())
        let after = snapshot(afterBinding, url: "https://example.test/detail", nodes: documentNodes())
        XCTAssertEqual(try plan.evaluate(binding: afterBinding, snapshot: after).expectedValue, "https://example.test/detail")
        let wrong = snapshot(afterBinding, url: "https://example.test/unrelated", nodes: documentNodes())
        assertFailure(.postconditionNotObserved) { try plan.evaluate(binding: afterBinding, snapshot: wrong) }
        assertFailure(.invalidRequest) {
            try Verification.compile(request: .init(kind: .documentURL, expected: "https://other.test/"),
                action: .press, elementIndex: 0, snapshot: before, binding: binding)
        }
    }

    func testNoPlanIsInventedForArbitraryPress() throws {
        let binding = binding()
        let before = snapshot(binding, nodes: documentNodes(), displayed: [element(10, "button", "Press")])
        XCTAssertNil(try Verification.compile(action: .press, elementIndex: 0, snapshot: before, binding: binding))
    }

    func testValuePlanSupportsEmptyAndDoesNotVerifyAnUnchangedValue() throws {
        let binding = binding()
        let field = element(5, "textbox", "Query", value: "old")
        let before = snapshot(binding, nodes: [], displayed: [field], evidence: false)
        let plan = try XCTUnwrap(Verification.compile(action: .setText(""), elementIndex: 0, snapshot: before, binding: binding))
        let after = snapshot(binding, nodes: [], displayed: [element(5, "textbox", "Query", value: "")], evidence: false)
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: after).expectedValue, "")
        XCTAssertEqual(plan.property, "node:5:value")
        assertFailure(.baselineAlreadySatisfied) {
            try Verification.compile(action: .setText("old"), elementIndex: 0, snapshot: before, binding: binding)
        }
    }

    func testPressMayPlanAnObservedNoneditableResultValue() throws {
        let binding = binding()
        let before = snapshot(binding, nodes: [], displayed: [element(10, "button", "Increment"),
            element(30, "StaticText", "Count", index: 1, value: "0")], evidence: false)
        let plan = try XCTUnwrap(Verification.compile(request: .init(kind: .value, elementIndex: 1, expected: "1"),
            action: .press, elementIndex: 0, snapshot: before, binding: binding))
        let after = snapshot(binding, nodes: [], displayed: [element(30, "StaticText", "Count", value: "1")], evidence: false)
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: after).expectedValue, "1")
        assertFailure(.invalidRequest) {
            try Verification.compile(request: .init(kind: .value, elementIndex: 2, expected: "1"),
                action: .press, elementIndex: 0, snapshot: before, binding: binding)
        }
    }

    func testValuePlanMayUseInternalSourceOutsideDisplayPagination() throws {
        let binding = binding()
        let before = snapshot(binding, nodes: [], displayed: [element(5, "textbox", "Query", value: "old")], evidence: false)
        let plan = try XCTUnwrap(Verification.compile(action: .setText("new"), elementIndex: 0, snapshot: before, binding: binding))
        let after = snapshot(binding, nodes: [node(5, "textbox", "Query", value: "new")], displayed: [])
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: after).expectedValue, "new")
    }

    func testReplacedTextChildVerifiesTheStableRenderedRegion() throws {
        let binding = binding()
        let before = regionSnapshot(binding, text: "Count: 0", textID: 21)
        let plan = try regionPlan(before, binding: binding, expected: "Count: 1")
        let after = regionSnapshot(binding, text: "Count: 1", textID: 99)
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: after).expectedValue, "Count: 1")
        XCTAssertEqual(plan.property, "planned:region_text:20")
    }

    func testRegionWithInlineTextBoxesDoesNotDuplicateText() throws {
        let binding = binding()
        let before = regionSnapshot(binding, text: "Count: 0", textID: 21)
        let plan = try regionPlan(before, binding: binding, expected: "Count: 1")
        let nodes = [
            node(1, "RootWebArea", "Fixture", children: ["10", "20"]),
            node(10, "button", "Increment", parent: "1"),
            node(20, "status", "Counter status", parent: "1", children: ["30"]),
            node(30, "StaticText", "Count: 1", parent: "20", children: ["31"]),
            node(31, "InlineTextBox", "Count: 1", parent: "30"),
        ]
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: snapshot(binding, nodes: nodes)).expectedValue, "Count: 1")
    }

    func testUniquelyNamedContainerReplacementRequiresUnchangedParentAndSiblings() throws {
        let binding = binding()
        let before = regionSnapshot(binding, text: "Count: 0", textID: 21)
        let plan = try regionPlan(before, binding: binding, expected: "Count: 1")
        let after = regionSnapshot(binding, text: "Count: 1", textID: 91, regionID: 90)
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: after).expectedValue, "Count: 1")
        let changedSibling = regionSnapshot(binding, text: "Count: 1", textID: 91, regionID: 90, buttonName: "Different action")
        assertFailure(.missingAnchor) { try plan.evaluate(binding: binding, snapshot: changedSibling) }
        let replacedParent = regionSnapshot(binding, text: "Count: 1", textID: 91, regionID: 90, rootID: 100)
        assertFailure(.missingAnchor) { try plan.evaluate(binding: binding, snapshot: replacedParent) }
    }

    func testDuplicateReplacementAnchorsAreNotGuessed() throws {
        let binding = binding()
        let plan = try regionPlan(regionSnapshot(binding, text: "Count: 0", textID: 21), binding: binding, expected: "Count: 1")
        let nodes = [
            node(1, "RootWebArea", "Fixture", children: ["10", "90", "100"]),
            node(10, "button", "Increment", parent: "1"),
            node(90, "status", "Counter status", parent: "1", children: ["91"]),
            node(91, "StaticText", "Count: 1", parent: "90"),
            node(100, "status", "Counter status", parent: "1", children: ["101"]),
            node(101, "StaticText", "Count: 1", parent: "100"),
        ]
        assertFailure(.ambiguousAnchor) { try plan.evaluate(binding: binding, snapshot: snapshot(binding, nodes: nodes)) }
    }

    func testUnrelatedTextChangeCannotVerifyRegionAndChildCannotBeAnAnchor() throws {
        let binding = binding()
        let before = regionSnapshot(binding, text: "Count: 0", textID: 21)
        let plan = try regionPlan(before, binding: binding, expected: "Count: 1")
        let unrelated = regionSnapshot(binding, text: "Count: 0", textID: 21, buttonName: "Count: 1")
        assertFailure(.postconditionNotObserved) { try plan.evaluate(binding: binding, snapshot: unrelated) }
        var childSelected = before
        childSelected = snapshot(binding, nodes: before.evidenceDocument!.nodes,
            displayed: [element(10, "button", "Increment"), element(21, "StaticText", "Count: 0", index: 1)])
        assertFailure(.unsupportedRegion) {
            try Verification.compile(request: .init(kind: .regionText, elementIndex: 1, expected: "Count: 1"),
                action: .press, elementIndex: 0, snapshot: childSelected, binding: binding)
        }
    }

    func testPartialOrMalformedSourcesCannotEstablishARegionBaseline() throws {
        let binding = binding()
        var before = regionSnapshot(binding, text: "Count: 0", textID: 21)
        before.sourceTruncated = true
        assertFailure(.incompleteEvidence) { try regionPlan(before, binding: binding, expected: "Count: 1") }
        before = regionSnapshot(binding, text: "Count: 0", textID: 21)
        let document = before.evidenceDocument!
        before.evidenceDocument = BrowserDocumentObservation(loaderID: document.loaderID, title: document.title,
            url: document.url, nodes: document.nodes, sourceTruncated: true)
        assertFailure(.incompleteEvidence) { try regionPlan(before, binding: binding, expected: "Count: 1") }
        before.evidenceDocument = BrowserDocumentObservation(loaderID: document.loaderID, title: document.title,
            url: document.url, nodes: Array(document.nodes.dropLast()))
        assertFailure(.incompleteEvidence) { try regionPlan(before, binding: binding, expected: "Count: 1") }
    }

    func testDetailViewRequiresObservedTargetExactUniqueHeadingAndNavigation() throws {
        let binding = binding()
        let before = detailBefore(binding)
        let plan = try XCTUnwrap(Verification.compile(request: .init(kind: .detailView, expected: "Trip itinerary"),
            action: .press, elementIndex: 0, snapshot: before, binding: binding))
        let newBinding = replacing(binding, documentEpoch: UUID())
        let success = detailAfter(newBinding, headings: ["Trip itinerary"])
        XCTAssertEqual(try plan.evaluate(binding: newBinding, snapshot: success).expectedValue, "Trip itinerary")
        assertFailure(.postconditionNotObserved) {
            try plan.evaluate(binding: newBinding, snapshot: detailAfter(newBinding, headings: ["Unrelated message"]))
        }
        assertFailure(.ambiguousAnchor) {
            try plan.evaluate(binding: newBinding, snapshot: detailAfter(newBinding, headings: ["Trip itinerary", "Trip itinerary"]))
        }
        assertFailure(.postconditionNotObserved) {
            try plan.evaluate(binding: binding, snapshot: detailAfter(binding, headings: ["Trip itinerary"], url: "https://example.test/inbox"))
        }
        assertFailure(.wrongDocument) {
            try plan.evaluate(binding: newBinding, snapshot: detailAfter(newBinding, headings: ["Trip itinerary"], url: "https://other.test/message"))
        }
        assertFailure(.invalidRequest) {
            try Verification.compile(request: .init(kind: .detailView, expected: "Unseen title"),
                action: .press, elementIndex: 0, snapshot: before, binding: binding)
        }
    }

    func testDetailViewRejectsPreExistingHeadingAndIncompleteAbsence() throws {
        let binding = binding()
        var before = detailBefore(binding, preExistingHeading: true)
        assertFailure(.baselineAlreadySatisfied) {
            try Verification.compile(request: .init(kind: .detailView, expected: "Trip itinerary"),
                action: .press, elementIndex: 0, snapshot: before, binding: binding)
        }
        before = detailBefore(binding)
        before.sourceTruncated = true
        assertFailure(.incompleteEvidence) {
            try Verification.compile(request: .init(kind: .detailView, expected: "Trip itinerary"),
                action: .press, elementIndex: 0, snapshot: before, binding: binding)
        }
    }

    func testDetailViewCompositeLabelRequiresUnicodeWordBoundariesOrExactDescendantText() throws {
        let binding = binding()
        for label in ["Sender Tripod received today", "Sender 猫Trip犬 received today", "Sender Trip_1 received today", "Sender Trip\u{301} received today"] {
            let before = snapshot(binding, nodes: [node(1, "RootWebArea", "Inbox", children: ["10"]),
                node(10, "row", label, parent: "1")], displayed: [element(10, "row", label)])
            assertFailure(.invalidRequest) {
                try Verification.compile(request: .init(kind: .detailView, expected: "Trip"),
                    action: .press, elementIndex: 0, snapshot: before, binding: binding)
            }
        }
        let label = "Sender [Trip] received today"
        let bounded = snapshot(binding, nodes: [node(1, "RootWebArea", "Inbox", children: ["10"]),
            node(10, "row", label, parent: "1")], displayed: [element(10, "row", label)])
        XCTAssertNotNil(try Verification.compile(request: .init(kind: .detailView, expected: "Trip"),
            action: .press, elementIndex: 0, snapshot: bounded, binding: binding))
        let exactChild = snapshot(binding, nodes: [node(1, "RootWebArea", "Inbox", children: ["10"]),
            node(10, "row", "Composite label", parent: "1", children: ["11"]),
            node(11, "StaticText", "猫Trip犬", parent: "10")], displayed: [element(10, "row", "Composite label")])
        XCTAssertNotNil(try Verification.compile(request: .init(kind: .detailView, expected: "猫Trip犬"),
            action: .press, elementIndex: 0, snapshot: exactChild, binding: binding))
    }

    func testWrongTabGenerationInstanceDocumentAndRetainedReadAreRejected() throws {
        let binding = binding()
        let before = regionSnapshot(binding, text: "Count: 0", textID: 21)
        let plan = try regionPlan(before, binding: binding, expected: "Count: 1")
        for wrong in [replacing(binding, targetID: "other"), replacing(binding, targetInstance: "other"),
                      replacing(binding, generation: UUID()), replacing(binding, handle: UUID())] {
            assertFailure(.wrongTarget) { try plan.evaluate(binding: wrong, snapshot: regionSnapshot(wrong, text: "Count: 1", textID: 99)) }
        }
        let changedDocument = replacing(binding, documentEpoch: UUID())
        assertFailure(.wrongDocument) {
            try plan.evaluate(binding: changedDocument, snapshot: regionSnapshot(changedDocument, text: "Count: 1", textID: 99))
        }
        var retained = regionSnapshot(binding, text: "Count: 1", textID: 99)
        retained.isLiveObservation = false
        assertFailure(.staleObservation) { try plan.evaluate(binding: binding, snapshot: retained) }
        assertFailure(.staleObservation) { try plan.evaluate(binding: binding, snapshot: before) }
    }

    func testPlanRoundTripsAndReservesBaselineIndependentlyOfDisplayedProperties() throws {
        let binding = binding()
        let before = regionSnapshot(binding, text: "Count: 0", textID: 21)
        let plan = try regionPlan(before, binding: binding, expected: "Count: 1")
        let restored = try JSONDecoder().decode(Verification.Plan.self, from: JSONEncoder().encode(plan))
        try restored.validate()
        XCTAssertEqual(plan, restored)
        var after = regionSnapshot(binding, text: "Count: 1", textID: 99)
        after.nextCursor = "more-display-pages"
        XCTAssertEqual(try restored.evaluate(binding: binding, snapshot: after).expectedValue, "Count: 1")
        XCTAssertEqual(plan.scope.evidenceTargetID, "browser:\(binding.browserGeneration):\(binding.targetID)")
    }

    private func regionPlan(_ snapshot: BrowserTabSnapshot, binding: BrowserTabBinding, expected: String) throws -> Verification.Plan {
        guard let plan = try Verification.compile(request: .init(kind: .regionText, elementIndex: 1, expected: expected),
            action: .press, elementIndex: 0, snapshot: snapshot, binding: binding) else {
            throw Verification.Failure.invalidPlan
        }
        return plan
    }

    private func regionSnapshot(_ binding: BrowserTabBinding, text: String, textID: Int64,
                                regionID: Int64 = 20, rootID: Int64 = 1, buttonName: String = "Increment") -> BrowserTabSnapshot {
        snapshot(binding, nodes: [
            node(rootID, "RootWebArea", "Fixture", children: ["10", String(regionID)]),
            node(10, "button", buttonName, parent: String(rootID)),
            node(regionID, "status", "Counter status", parent: String(rootID), children: [String(textID)]),
            node(textID, "StaticText", text, parent: String(regionID)),
        ], displayed: [element(10, "button", buttonName), element(regionID, "status", "Counter status", index: 1)])
    }

    private func detailBefore(_ binding: BrowserTabBinding, preExistingHeading: Bool = false) -> BrowserTabSnapshot {
        var nodes = [node(1, "RootWebArea", "Inbox", children: preExistingHeading ? ["10", "40"] : ["10"]),
                     node(10, "row", "Sender Trip itinerary received today", parent: "1", children: ["11"]),
                     node(11, "StaticText", "Trip itinerary", parent: "10")]
        if preExistingHeading { nodes.append(node(40, "heading", "Trip itinerary", parent: "1")) }
        return snapshot(binding, nodes: nodes, displayed: [element(10, "row", "Sender Trip itinerary received today")])
    }

    private func detailAfter(_ binding: BrowserTabBinding, headings: [String], url: String = "https://example.test/message/1") -> BrowserTabSnapshot {
        let ids = headings.indices.map { String(100 + $0) }
        let nodes = [node(1, "RootWebArea", "Detail", children: ids)] + headings.enumerated().map { offset, title in
            node(Int64(100 + offset), "heading", title, parent: "1")
        }
        return snapshot(binding, url: url, nodes: nodes)
    }

    private func documentNodes() -> [BrowserDocumentNode] { [node(1, "RootWebArea", "Fixture")] }

    private func node(_ id: Int64, _ role: String, _ name: String, parent: String? = nil,
                      children: [String] = [], value: String? = nil) -> BrowserDocumentNode {
        BrowserDocumentNode(backendNodeID: id, role: role, name: name, value: value,
            isDisabled: false, isReadOnly: false, isIgnored: false,
            nodeID: String(id), parentNodeID: parent, childNodeIDs: children)
    }

    private func element(_ id: Int64, _ role: String, _ label: String, index: Int = 0,
                         value: String? = nil, link: String? = nil) -> BrowserTabElement {
        BrowserTabElement(index: index, backendNodeID: id, role: "AXGroup", label: label,
            value: value, isEnabled: true, supportsPress: true, supportsSetText: role == "textbox",
            linkURL: link, semanticRole: role)
    }

    private func snapshot(_ binding: BrowserTabBinding, url: String = "https://example.test/inbox",
                          nodes: [BrowserDocumentNode], displayed: [BrowserTabElement] = [], evidence: Bool = true) -> BrowserTabSnapshot {
        let url = URL(string: url)!
        return BrowserTabSnapshot(id: UUID(), tabHandle: binding.handle, documentEpoch: binding.documentEpoch,
            loaderID: "loader", documentURL: url, elements: displayed, formattedText: "fixture",
            evidenceDocument: evidence ? BrowserDocumentObservation(loaderID: "loader", title: "Fixture", url: url, nodes: nodes) : nil)
    }

    private func binding() -> BrowserTabBinding {
        BrowserTabBinding(handle: UUID(), taskKey: "fixture", browserGeneration: UUID(), targetID: "tab",
            targetInstanceToken: "instance", processIdentifier: 42, documentEpoch: UUID(), ownership: .borrowed,
            lifetime: BrowserTabLifetime())
    }

    private func replacing(_ value: BrowserTabBinding, targetID: String? = nil, targetInstance: String? = nil,
                           generation: UUID? = nil, handle: UUID? = nil, documentEpoch: UUID? = nil) -> BrowserTabBinding {
        BrowserTabBinding(handle: handle ?? value.handle, taskKey: value.taskKey,
            browserGeneration: generation ?? value.browserGeneration, targetID: targetID ?? value.targetID,
            targetInstanceToken: targetInstance ?? value.targetInstanceToken, processIdentifier: value.processIdentifier,
            documentEpoch: documentEpoch ?? value.documentEpoch, ownership: value.ownership, lifetime: value.lifetime)
    }

    private func assertFailure<T>(_ expected: Verification.Failure, file: StaticString = #filePath, line: UInt = #line,
                                  _ action: () throws -> T) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? Verification.Failure, expected, file: file, line: line)
        }
    }
}

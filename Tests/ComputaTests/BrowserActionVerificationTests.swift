import Foundation
import XCTest
@testable import Computa

final class BrowserActionVerificationTests: XCTestCase {
    func testRecoveryScopeSurvivesFreshReadsButNotDocumentOrTargetReplacement() throws {
        let binding = binding()
        let before = dialogBefore(binding)
        let scope = try XCTUnwrap(Verification.recoveryScope(binding: binding, snapshot: before))
        XCTAssertEqual(scope.count, 64)
        XCTAssertEqual(scope, Verification.recoveryScope(binding: binding, snapshot: dialogBefore(binding)),
                       "A new snapshot ID is not a new browser document.")
        XCTAssertNotEqual(scope, Verification.recoveryScope(binding: binding,
            snapshot: snapshot(binding, nodes: dialogNodes(), loader: "replacement-loader")))
        XCTAssertNotEqual(scope, Verification.recoveryScope(binding: binding,
            snapshot: snapshot(binding, url: "https://example.test/other", nodes: dialogNodes())))
        for other in [replacing(binding, targetID: "other-tab"), replacing(binding, targetInstance: "new-instance"),
                      replacing(binding, generation: UUID()), replacing(binding, handle: UUID()),
                      replacing(binding, documentEpoch: UUID())] {
            XCTAssertNotEqual(scope, Verification.recoveryScope(binding: other, snapshot: dialogBefore(other)))
        }
        XCTAssertNil(Verification.recoveryScope(binding: replacing(binding, handle: UUID()), snapshot: before))
        XCTAssertNil(Verification.recoveryScope(binding: replacing(binding, documentEpoch: UUID()), snapshot: before))
        XCTAssertNil(Verification.recoveryScope(binding: binding,
            snapshot: snapshot(binding, nodes: dialogNodes(), loader: "")))
        var retained = before
        retained.isLiveObservation = false
        XCTAssertNil(Verification.recoveryScope(binding: binding, snapshot: retained))
        XCTAssertFalse(scope.contains("example.test"), "The scope retains no page text or URL.")
    }

    private typealias Verification = BrowserActionVerification

    func testDialogOpenedVerifiesOnlyNewAXExposureAtSameURLWithOpenerRemoved() throws {
        let binding = binding()
        let before = dialogBefore(binding)
        let plan = try dialogPlan(before, binding: binding)
        XCTAssertEqual(plan.kind, .dialogOpened)
        XCTAssertEqual(plan.expected, "opened")
        XCTAssertEqual(plan.anchor?.backendNodeID, 10)
        XCTAssertEqual(plan.dialogBaseline?.rootBackendNodeID, 1)
        try plan.revalidateBaseline(binding: binding, document: XCTUnwrap(before.evidenceDocument))
        let after = snapshot(binding, nodes: dialogNodes(dialogIDs: [20], includeOpener: false))
        XCTAssertEqual(after.documentURL, before.documentURL)
        let proof = try plan.evaluate(binding: binding, snapshot: after)
        XCTAssertEqual(proof.property, "planned:dialog_opened")
        XCTAssertEqual(proof.expectedValue, "opened", "A dialog appearance proves no search result or task success.")
        XCTAssertEqual(proof.observationID, after.id)
        let restored = try JSONDecoder().decode(Verification.Plan.self, from: JSONEncoder().encode(plan))
        try restored.validate()
        XCTAssertEqual(restored, plan)
        XCTAssertEqual(try restored.evaluate(binding: binding, snapshot: after), proof)
        assertFailure(.staleObservation) { try plan.evaluate(binding: binding, snapshot: before) }
        assertFailure(.postconditionNotObserved) { try plan.evaluate(binding: binding, snapshot: dialogBefore(binding)) }
    }

    func testDialogOpenedRequiresExplicitSentinelAndAnObservedEnabledSemanticOpener() throws {
        let binding = binding()
        let before = dialogBefore(binding)
        XCTAssertNil(try Verification.compile(action: .press, elementIndex: 0, snapshot: before, binding: binding))
        for request in [Verification.Request(kind: .dialogOpened, expected: "Unseen heading"),
                        .init(kind: .dialogOpened, elementIndex: 0, expected: "opened")] {
            assertFailure(.invalidRequest) {
                try Verification.compile(request: request, action: .press, elementIndex: 0, snapshot: before, binding: binding)
            }
        }
        assertFailure(.invalidRequest) {
            try Verification.compile(request: .init(kind: .dialogOpened, expected: "opened"),
                action: .setText("text"), elementIndex: 0, snapshot: before, binding: binding)
        }
        for role in ["RootWebArea", "generic", "link", "textbox", "StaticText", "separator"] {
            let invalid = snapshot(binding, nodes: dialogNodes(), displayed: [element(10, role, "Open panel")])
            assertFailure(.invalidRequest) { try dialogPlan(invalid, binding: binding) }
        }
        for selected in [element(10, "button", "Open panel", supportsPress: false),
                         element(10, "button", "Open panel", enabled: false),
                         element(10, "button", "Open panel", link: "https://example.test/inbox")] {
            let invalid = snapshot(binding, nodes: dialogNodes(), displayed: [selected])
            assertFailure(.invalidRequest) { try dialogPlan(invalid, binding: binding) }
        }
        for nodes in [
            [node(1, "RootWebArea", "Fixture", children: ["10"]), node(10, "button", "Open panel", parent: "1", disabled: true)],
            [node(1, "RootWebArea", "Fixture", children: ["10"]), node(10, "button", "Open panel", parent: "1", editable: true)],
        ] {
            let invalid = snapshot(binding, nodes: nodes, displayed: [element(10, "button", "Open panel")])
            assertFailure(.invalidRequest) { try dialogPlan(invalid, binding: binding) }
        }
    }

    func testDialogOpenedRequiresCompleteAbsenceAndAllowsAnIgnoredDialogToBecomeExposed() throws {
        let binding = binding()
        let visible = snapshot(binding, nodes: dialogNodes(dialogIDs: [20]), displayed: [element(10, "button", "Open panel")])
        assertFailure(.dialogAlreadyOpen) { try dialogPlan(visible, binding: binding) }
        let hidden = snapshot(binding, nodes: dialogNodes(dialogIDs: [20], ignoredDialogs: true),
                              displayed: [element(10, "button", "Open panel")])
        let plan = try dialogPlan(hidden, binding: binding)
        try plan.revalidateBaseline(binding: binding, document: XCTUnwrap(hidden.evidenceDocument))
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: visible).expectedValue, "opened")
        var sourceCut = dialogBefore(binding)
        sourceCut.sourceTruncated = true
        var documentCut = dialogBefore(binding)
        let document = try XCTUnwrap(documentCut.evidenceDocument)
        documentCut.evidenceDocument = .init(loaderID: document.loaderID, title: document.title,
            url: document.url, nodes: document.nodes, sourceTruncated: true)
        let missing = snapshot(binding, nodes: dialogNodes(), displayed: [element(10, "button", "Open panel")], evidence: false)
        let malformed = snapshot(binding, nodes: Array(dialogNodes(dialogIDs: [20]).dropLast()),
                                 displayed: [element(10, "button", "Open panel")])
        for invalid in [sourceCut, documentCut, missing, malformed] {
            assertFailure(.incompleteEvidence) { try dialogPlan(invalid, binding: binding) }
        }
    }

    func testDialogOpenedRejectsAmbiguousIgnoredIncompleteAndSubframeEvidence() throws {
        let binding = binding()
        let plan = try dialogPlan(dialogBefore(binding), binding: binding)
        let ambiguous = snapshot(binding, nodes: dialogNodes(dialogIDs: [20, 40]))
        assertFailure(.ambiguousAnchor) { try plan.evaluate(binding: binding, snapshot: ambiguous) }
        let ignored = snapshot(binding, nodes: dialogNodes(dialogIDs: [20], ignoredDialogs: true))
        assertFailure(.postconditionNotObserved) { try plan.evaluate(binding: binding, snapshot: ignored) }
        var cut = snapshot(binding, nodes: dialogNodes(dialogIDs: [20]))
        cut.sourceTruncated = true
        assertFailure(.incompleteEvidence) { try plan.evaluate(binding: binding, snapshot: cut) }
        let malformed = snapshot(binding, nodes: Array(dialogNodes(dialogIDs: [20]).dropLast()))
        assertFailure(.incompleteEvidence) { try plan.evaluate(binding: binding, snapshot: malformed) }
        let missingIdentity = snapshot(binding, nodes: [node(1, "RootWebArea", "Fixture", children: ["20"]),
            BrowserDocumentNode(backendNodeID: nil, role: "dialog", name: "Panel", value: nil,
                isDisabled: false, isReadOnly: false, isIgnored: false, nodeID: "20", parentNodeID: "1")])
        assertFailure(.incompleteEvidence) { try plan.evaluate(binding: binding, snapshot: missingIdentity) }
        let subframe = snapshot(binding, nodes: [
            node(1, "RootWebArea", "Fixture", children: ["40"]),
            node(40, "Iframe", "Other frame", parent: "1", children: ["41"]),
            node(41, "RootWebArea", "Embedded page", parent: "40", children: ["20"]),
            node(20, "dialog", "Panel", parent: "41", children: ["21"]),
            node(21, "textbox", "Entry", parent: "20", editable: true),
        ])
        assertFailure(.postconditionNotObserved) { try plan.evaluate(binding: binding, snapshot: subframe) }
        let alert = snapshot(binding, nodes: dialogNodes(dialogIDs: [20], dialogRole: "alertdialog"))
        XCTAssertEqual(try plan.evaluate(binding: binding, snapshot: alert).expectedValue, "opened")
    }

    func testDialogOpenedRejectsStaleTargetDocumentLoaderAndRootIdentity() throws {
        let binding = binding()
        let plan = try dialogPlan(dialogBefore(binding), binding: binding)
        for wrong in [replacing(binding, targetID: "other"), replacing(binding, targetInstance: "other"),
                      replacing(binding, generation: UUID()), replacing(binding, handle: UUID())] {
            let after = snapshot(wrong, nodes: dialogNodes(dialogIDs: [20]))
            assertFailure(.wrongTarget) { try plan.evaluate(binding: wrong, snapshot: after) }
        }
        let moved = replacing(binding, documentEpoch: UUID())
        assertFailure(.wrongDocument) {
            try plan.evaluate(binding: moved, snapshot: snapshot(moved, nodes: dialogNodes(dialogIDs: [20])))
        }
        for after in [snapshot(binding, url: "https://example.test/other", nodes: dialogNodes(dialogIDs: [20])),
                      snapshot(binding, nodes: dialogNodes(dialogIDs: [20]), loader: "other-loader"),
                      snapshot(binding, nodes: dialogNodes(dialogIDs: [20], rootID: 100))] {
            assertFailure(.wrongDocument) { try plan.evaluate(binding: binding, snapshot: after) }
        }
        var retained = snapshot(binding, nodes: dialogNodes(dialogIDs: [20]))
        retained.isLiveObservation = false
        assertFailure(.staleObservation) { try plan.evaluate(binding: binding, snapshot: retained) }
    }

    func testDialogBaselineRevalidationRejectsPreexistingDialogOrChangedOpenerAndRoundTripTampering() throws {
        let binding = binding()
        let before = dialogBefore(binding)
        let plan = try dialogPlan(before, binding: binding)
        for nodes in [dialogNodes(dialogIDs: [20]), dialogNodes(openerName: "Different control"),
                      dialogNodes(rootID: 100)] {
            let changed = try XCTUnwrap(snapshot(binding, nodes: nodes).evidenceDocument)
            assertFailure(.baselineChanged) { try plan.revalidateBaseline(binding: binding, document: changed) }
        }
        let beforeDocument = try XCTUnwrap(before.evidenceDocument)
        let cut = BrowserDocumentObservation(loaderID: beforeDocument.loaderID, title: beforeDocument.title,
            url: beforeDocument.url, nodes: beforeDocument.nodes, sourceTruncated: true)
        assertFailure(.incompleteEvidence) { try plan.revalidateBaseline(binding: binding, document: cut) }
        let encoded = try JSONEncoder().encode(plan)
        for key in ["dialogBaseline", "expected", "scope"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if key == "dialogBaseline" { object.removeValue(forKey: key) }
            else if key == "expected" { object[key] = "result found" }
            else {
                var scope = try XCTUnwrap(object[key] as? [String: Any])
                scope["frame"] = "subframe"; object[key] = scope
            }
            let forged = try JSONDecoder().decode(Verification.Plan.self, from: JSONSerialization.data(withJSONObject: object))
            assertFailure(.invalidPlan) { try forged.validate() }
        }
    }

    func testObservedLinkDestinationRequiresEnabledActualHTTPLinkWithoutChangingGenericPressInference() throws {
        let base = URL(string: "https://example.test/inbox")!
        XCTAssertEqual(Verification.observedLinkDestination(element(10, "link", "Open", link: "/record"), at: base),
                       "https://example.test/record")
        for candidate in [element(10, "RootWebArea", "Document", link: base.absoluteString),
                          element(10, "generic", "Custom", link: "/record"),
                          element(10, "link", "Disabled", link: "/record", enabled: false),
                          element(10, "link", "Unsupported", link: "/record", supportsPress: false),
                          element(10, "link", "File", link: "file:///tmp/record"),
                          element(10, "link", "Script", link: "javascript:void(0)")] {
            XCTAssertNil(Verification.observedLinkDestination(candidate, at: base))
        }
        let binding = binding()
        let root = snapshot(binding, nodes: documentNodes(),
                            displayed: [element(1, "RootWebArea", "Document", link: "https://example.test/other")])
        let existing = try XCTUnwrap(Verification.compile(action: .press, elementIndex: 0, snapshot: root, binding: binding))
        XCTAssertEqual(existing.kind, .documentURL, "The narrow follow-link helper does not change existing press inference.")
    }

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

    func testRegionChangedUsesObservedStatusWithoutInventingFutureText() throws {
        let binding = binding()
        // Like a live pager, the status accessible name may derive from its
        // mutable text, and its text child may be replaced independently.
        let before = changedRegionSnapshot(binding, text: "Showing records 1-2. Later records are not mounted.")
        let plan = try changedRegionPlan(before, binding: binding)
        try plan.revalidateBaseline(binding: binding, document: XCTUnwrap(before.evidenceDocument))
        let after = changedRegionSnapshot(binding, text: "Showing records 3-4. Earlier records are not mounted.", textID: 99)
        let proof = try plan.evaluate(binding: binding, snapshot: after)
        XCTAssertEqual(plan.kind, .regionChanged)
        XCTAssertEqual(plan.expected, "changed")
        XCTAssertEqual(proof.expectedValue, "changed", "The proof makes no next-page or requested-record claim.")
        XCTAssertEqual(proof.property, "planned:region_changed:20")
        XCTAssertFalse(plan.expected.contains("records"))
        assertFailure(.staleObservation) { try plan.evaluate(binding: binding, snapshot: before) }
        assertFailure(.baselineChanged) { try plan.revalidateBaseline(binding: binding, document: XCTUnwrap(after.evidenceDocument)) }
        let restored = try JSONDecoder().decode(Verification.Plan.self, from: JSONEncoder().encode(plan))
        try restored.validate()
        XCTAssertEqual(restored, plan)
        XCTAssertEqual(try restored.evaluate(binding: binding, snapshot: after), proof)
    }

    func testRegionChangedRejectsUnrelatedChangesReplacementAndMovedContainer() throws {
        let binding = binding()
        let before = changedRegionSnapshot(binding, text: "Initial records")
        let plan = try changedRegionPlan(before, binding: binding)
        let unrelated = changedRegionSnapshot(binding, text: "Initial records", buttonName: "Unrelated changed button")
        assertFailure(.postconditionNotObserved) { try plan.evaluate(binding: binding, snapshot: unrelated) }
        let replacement = changedRegionSnapshot(binding, text: "Different records", regionID: 90)
        assertFailure(.missingAnchor) { try plan.evaluate(binding: binding, snapshot: replacement) }
        let changedParent = changedRegionSnapshot(binding, text: "Different records", rootID: 100)
        assertFailure(.missingAnchor) { try plan.evaluate(binding: binding, snapshot: changedParent) }
        let moved = changedRegionSnapshot(binding, text: "Different records", regionFirst: true)
        assertFailure(.missingAnchor) { try plan.evaluate(binding: binding, snapshot: moved) }
        let metadataOnly = changedRegionSnapshot(binding, text: "Initial records", regionName: "Changed metadata only")
        assertFailure(.postconditionNotObserved) { try plan.evaluate(binding: binding, snapshot: metadataOnly) }
    }

    func testRegionChangedRejectsControlsEditableDescendantsAndEmptyOrClippedText() throws {
        let binding = binding()
        let baseline = changedRegionSnapshot(binding, text: "Initial records")
        let plan = try changedRegionPlan(baseline, binding: binding)
        for unsafe in [changedRegionSnapshot(binding, text: "Input", textRole: "textbox"),
                       changedRegionSnapshot(binding, text: "Input", regionRole: "button"),
                       changedRegionSnapshot(binding, text: "Input", clickableRegion: true),
                       changedRegionSnapshot(binding, text: "Input", clickableText: true),
                       changedRegionSnapshot(binding, text: "Input", editableRegion: true),
                       changedRegionSnapshot(binding, text: "Input", textRole: "generic", editableText: true)] {
            assertFailure(.unsupportedRegion) { try changedRegionPlan(unsafe, binding: binding) }
            let expected: Verification.Failure = unsafe.elements[1].semanticRole == "button" ? .missingAnchor : .unsupportedRegion
            assertFailure(expected) { try plan.evaluate(binding: binding, snapshot: unsafe) }
        }
        for text in ["", String(repeating: "x", count: 8_193)] {
            let incomplete = changedRegionSnapshot(binding, text: text)
            assertFailure(.incompleteEvidence) { try changedRegionPlan(incomplete, binding: binding) }
            assertFailure(.incompleteEvidence) { try plan.evaluate(binding: binding, snapshot: incomplete) }
        }
        var clipped = changedRegionSnapshot(binding, text: "Different records")
        clipped.sourceTruncated = true
        assertFailure(.incompleteEvidence) { try changedRegionPlan(clipped, binding: binding) }
        assertFailure(.incompleteEvidence) { try plan.evaluate(binding: binding, snapshot: clipped) }
        let missing = snapshot(binding, nodes: documentNodes())
        assertFailure(.missingAnchor) { try plan.evaluate(binding: binding, snapshot: missing) }
    }

    func testRegionChangedRejectsWrongTargetDocumentAndRetainedObservation() throws {
        let binding = binding()
        let plan = try changedRegionPlan(changedRegionSnapshot(binding, text: "Initial"), binding: binding)
        for wrong in [replacing(binding, targetID: "other"), replacing(binding, targetInstance: "other"),
                      replacing(binding, generation: UUID()), replacing(binding, handle: UUID())] {
            assertFailure(.wrongTarget) { try plan.evaluate(binding: wrong, snapshot: changedRegionSnapshot(wrong, text: "Different")) }
        }
        let changedDocument = replacing(binding, documentEpoch: UUID())
        assertFailure(.wrongDocument) {
            try plan.evaluate(binding: changedDocument, snapshot: changedRegionSnapshot(changedDocument, text: "Different"))
        }
        var retained = changedRegionSnapshot(binding, text: "Different")
        retained.isLiveObservation = false
        assertFailure(.staleObservation) { try plan.evaluate(binding: binding, snapshot: retained) }
    }

    func testRegionCandidatesShareCompilerChecksAndRejectStaleObservations() throws {
        let binding = binding()
        let before = changedRegionSnapshot(binding, text: "Observed records")
        XCTAssertEqual(Verification.regionChangedCandidateBackendIDs(snapshot: before, binding: binding), [20])
        XCTAssertEqual(try changedRegionPlan(before, binding: binding).anchor?.backendNodeID, 20)
        for unsafe in [changedRegionSnapshot(binding, text: "Input", textRole: "textbox"),
                       changedRegionSnapshot(binding, text: "Input", regionRole: "button"),
                       changedRegionSnapshot(binding, text: "Input", editableRegion: true),
                       changedRegionSnapshot(binding, text: "Input", editableText: true),
                       changedRegionSnapshot(binding, text: "Input", clickableRegion: true),
                       changedRegionSnapshot(binding, text: "Input", regionRole: "StaticText"),
                       changedRegionSnapshot(binding, text: String(repeating: "x", count: 8_193))] {
            XCTAssertTrue(Verification.regionChangedCandidateBackendIDs(snapshot: unsafe, binding: binding).isEmpty)
            XCTAssertThrowsError(try changedRegionPlan(unsafe, binding: binding))
        }
        var clipped = before
        clipped.sourceTruncated = true
        XCTAssertTrue(Verification.regionChangedCandidateBackendIDs(snapshot: clipped, binding: binding).isEmpty)
        var retained = before
        retained.isLiveObservation = false
        XCTAssertTrue(Verification.regionChangedCandidateBackendIDs(snapshot: retained, binding: binding).isEmpty)
        XCTAssertTrue(Verification.regionChangedCandidateBackendIDs(snapshot: before,
            binding: replacing(binding, handle: UUID())).isEmpty)
        XCTAssertTrue(Verification.regionChangedCandidateBackendIDs(snapshot: before,
            binding: replacing(binding, documentEpoch: UUID())).isEmpty)
        binding.lifetime.revoke()
        XCTAssertTrue(Verification.regionChangedCandidateBackendIDs(snapshot: before, binding: binding).isEmpty)
    }

    private func changedRegionPlan(_ snapshot: BrowserTabSnapshot, binding: BrowserTabBinding) throws -> Verification.Plan {
        guard let plan = try Verification.compile(request: .init(kind: .regionChanged, elementIndex: 1, expected: "changed"),
            action: .press, elementIndex: 0, snapshot: snapshot, binding: binding) else { throw Verification.Failure.invalidPlan }
        return plan
    }

    private func changedRegionSnapshot(_ binding: BrowserTabBinding, text: String, textID: Int64 = 21,
                                       regionID: Int64 = 20, rootID: Int64 = 1, buttonName: String = "Next records",
                                       regionName: String? = nil, regionRole: String = "status", textRole: String = "StaticText",
                                       clickableRegion: Bool = false, clickableText: Bool = false,
                                       editableRegion: Bool = false, editableText: Bool = false, regionFirst: Bool = false) -> BrowserTabSnapshot {
        let children = regionFirst ? [String(regionID), "10"] : ["10", String(regionID)]
        return snapshot(binding, nodes: [
            node(rootID, "RootWebArea", "Fixture", children: children),
            node(10, "button", buttonName, parent: String(rootID)),
            node(regionID, regionRole, regionName ?? text, parent: String(rootID), children: [String(textID)], clickable: clickableRegion, editable: editableRegion),
            node(textID, textRole, text, parent: String(regionID), clickable: clickableText, editable: editableText),
        ], displayed: [element(10, "button", buttonName),
            element(regionID, regionRole, regionName ?? text, index: 1, supportsPress: false)])
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

    private func dialogPlan(_ snapshot: BrowserTabSnapshot, binding: BrowserTabBinding) throws -> Verification.Plan {
        let plan = try Verification.compile(request: .init(kind: .dialogOpened, expected: "opened"),
            action: .press, elementIndex: 0, snapshot: snapshot, binding: binding)
        return try XCTUnwrap(plan)
    }

    private func dialogBefore(_ binding: BrowserTabBinding) -> BrowserTabSnapshot {
        snapshot(binding, nodes: dialogNodes(), displayed: [element(10, "button", "Open panel")])
    }

    private func dialogNodes(dialogIDs: [Int64] = [], ignoredDialogs: Bool = false, includeOpener: Bool = true,
                             rootID: Int64 = 1, openerName: String = "Open panel", dialogRole: String = "dialog") -> [BrowserDocumentNode] {
        let children = (includeOpener ? ["10"] : []) + dialogIDs.map(String.init)
        var result = [node(rootID, "RootWebArea", "Fixture", children: children)]
        if includeOpener { result.append(node(10, "button", openerName, parent: String(rootID))) }
        for id in dialogIDs {
            result += [node(id, dialogRole, "Observed panel", parent: String(rootID), children: [String(id + 1)], ignored: ignoredDialogs),
                       node(id + 1, "textbox", "Entry field", parent: String(id), editable: true)]
        }
        return result
    }

    private func documentNodes() -> [BrowserDocumentNode] { [node(1, "RootWebArea", "Fixture")] }

    private func node(_ id: Int64, _ role: String, _ name: String, parent: String? = nil,
                      children: [String] = [], value: String? = nil, clickable: Bool = false, editable: Bool = false,
                      ignored: Bool = false, disabled: Bool = false) -> BrowserDocumentNode {
        BrowserDocumentNode(backendNodeID: id, role: role, name: name, value: value,
            isDisabled: disabled, isReadOnly: false, isIgnored: ignored,
            nodeID: String(id), parentNodeID: parent, childNodeIDs: children, isDOMClickable: clickable, isEditable: editable)
    }

    private func element(_ id: Int64, _ role: String, _ label: String, index: Int = 0,
                         value: String? = nil, link: String? = nil, supportsPress: Bool = true, enabled: Bool = true) -> BrowserTabElement {
        BrowserTabElement(index: index, backendNodeID: id, role: "AXGroup", label: label,
            value: value, isEnabled: enabled, supportsPress: supportsPress, supportsSetText: role == "textbox",
            linkURL: link, semanticRole: role)
    }

    private func snapshot(_ binding: BrowserTabBinding, url: String = "https://example.test/inbox",
                          nodes: [BrowserDocumentNode], displayed: [BrowserTabElement] = [], evidence: Bool = true,
                          loader: String = "loader") -> BrowserTabSnapshot {
        let url = URL(string: url)!
        return BrowserTabSnapshot(id: UUID(), tabHandle: binding.handle, documentEpoch: binding.documentEpoch,
            loaderID: loader, documentURL: url, elements: displayed, formattedText: "fixture",
            evidenceDocument: evidence ? BrowserDocumentObservation(loaderID: loader, title: "Fixture", url: url, nodes: nodes) : nil)
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

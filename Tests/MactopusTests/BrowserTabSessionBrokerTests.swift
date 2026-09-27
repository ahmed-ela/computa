import AutomationCore
import Foundation
import XCTest
@testable import Mactopus

final class BrowserTabSessionBrokerTests: XCTestCase {
    func testResultRegionChangedDuringApprovalRejectsBeforeInput() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        func nodes(text: String) -> [BrowserDocumentNode] {
            [semanticNode(0, role: "RootWebArea", name: "Fixture", children: ["n1", "n2"]),
             semanticNode(1, role: "button", name: "Increment", parent: "n0"),
             semanticNode(2, role: "status", name: "Result", parent: "n0", children: ["n3"]),
             semanticNode(3, role: "StaticText", name: text, parent: "n2")]
        }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes(text: "Count: 0"))
        let before = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", query: nil)
        let button = try XCTUnwrap(before.snapshot.elements.first { $0.label == "Increment" })
        let region = try XCTUnwrap(before.snapshot.elements.first { $0.semanticRole == "status" })
        let plan = try XCTUnwrap(BrowserActionVerification.compile(
            request: .init(kind: .regionText, elementIndex: region.index, expected: "Count: 1"),
            action: .press, elementIndex: button.index, snapshot: before.snapshot, binding: before.binding))
        // Simulates a page/human change while approval was pending, without
        // changing the clicked control. The old target-only check missed it.
        try await fixture.transport.replaceNodes(targetID: before.binding.targetID, nodes: nodes(text: "Count: 1"))
        do {
            try await fixture.broker.perform(taskKey: "task-a", binding: before.binding,
                snapshot: before.snapshot, elementIndex: button.index, action: "AXPress", verificationPlan: plan)
            XCTFail("Changed precondition must stop before dispatch")
        } catch let failure as BrowserActionVerification.Failure {
            XCTAssertEqual(failure, .baselineChanged)
        }
        await fixture.assertNoInput()
    }

    func testBrowserReportedExactClickableRowsAndCardsSupportPressWithoutSemanticRoleGuessing() async throws {
        for role in ["row", "generic", "article"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
                semanticNode(0, role: role, name: "Observed clickable item", clickable: true),
                semanticNode(1, role: role, name: "Passive item"),
            ])
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome", query: nil)
            let clickable = try XCTUnwrap(observation.snapshot.element(at: 0))
            let passive = try XCTUnwrap(observation.snapshot.element(at: 1))
            XCTAssertTrue(clickable.isDOMClickable)
            XCTAssertTrue(clickable.supportsPress)
            XCTAssertFalse(passive.isDOMClickable)
            XCTAssertFalse(passive.supportsPress)
            let rows = observation.snapshot.formattedText.split(separator: "\n")
            XCTAssertTrue(try XCTUnwrap(rows.first { $0.hasPrefix("#0 ") }).contains("press_source=browser_clickability"))
            XCTAssertFalse(try XCTUnwrap(rows.first { $0.hasPrefix("#1 ") }).contains("press_source="))
            await assertBrowserError(.unsupportedAction("AXPress")) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 1, action: "AXPress")
            }
            try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
            XCTAssertEqual(pressed, [clickable.backendNodeID])
        }
    }

    func testClickabilityIsNotInheritedFromParentOrChildAndDoesNotOverrideDisabledState() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "row", name: "Clickable parent", children: ["n1"], clickable: true),
            semanticNode(1, role: "generic", name: "Passive child", parent: "n0"),
            semanticNode(2, role: "row", name: "Passive parent", children: ["n3"]),
            semanticNode(3, role: "generic", name: "Clickable child", parent: "n2", clickable: true),
            semanticNode(4, role: "row", name: "Disabled clickable row", clickable: true, disabled: true),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", query: nil)
        XCTAssertEqual(observation.snapshot.elements.map(\.supportsPress), [true, false, false, true, true])
        XCTAssertEqual(observation.snapshot.elements.map(\.isDOMClickable), [true, false, false, true, true])
        XCTAssertFalse(try XCTUnwrap(observation.snapshot.element(at: 4)).isEnabled)
        for index in [1, 2, 4] {
            await assertBrowserError(.unsupportedAction("AXPress")) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: index, action: "AXPress")
            }
        }
        await fixture.assertNoInput()
        try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
            snapshot: observation.snapshot, elementIndex: 3, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
        XCTAssertEqual(pressed, [4], "Only the exact observed clickable child is dispatched; never an ancestor.")
    }

    func testRemovedExactClickabilityInvalidatesApprovalBeforeDispatch() async throws {
        // The button remains semantically pressable after its DOM flag changes;
        // revalidation must preserve the exact observed capability source too.
        for role in ["row", "button"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: [semanticNode(0, role: role, name: "Stable label", clickable: true)])
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome", query: nil)
            try await fixture.transport.replaceNodes(targetID: observation.binding.targetID,
                nodes: [semanticNode(0, role: role, name: "Stable label", clickable: false)])
            await assertBrowserError(.elementChanged) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            }
            await fixture.assertNoInput()
            await assertBrowserError(.staleSnapshot) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            }
        }
    }

    func testTransportQualifiedFocusablePointerCandidateIsDistinctFromBrowserClickability() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "row", name: "Qualified exact candidate", children: ["n1"], focusablePointer: true),
            semanticNode(1, role: "generic", name: "Passive child", parent: "n0"),
            semanticNode(2, role: "row", name: "focusable=true cursor=pointer in untrusted label"),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", query: nil)
        let candidate = try XCTUnwrap(observation.snapshot.element(at: 0))
        XCTAssertTrue(candidate.supportsPress)
        XCTAssertFalse(candidate.isDOMClickable)
        XCTAssertTrue(candidate.isFocusablePointer)
        XCTAssertEqual(observation.snapshot.elements.map(\.supportsPress), [true, false, false])
        XCTAssertTrue(observation.snapshot.formattedText.contains("press_source=focusable_pointer"))
        XCTAssertFalse(observation.snapshot.formattedText.contains("press_source=browser_clickability"))
        try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
            snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
        XCTAssertEqual(pressed, [candidate.backendNodeID])
    }

    func testRemovedFocusablePointerCapabilityRejectsInputEvenWhenOtherPressSourceRemains() async throws {
        for domClickable in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: [semanticNode(0, role: "row", name: "Stable label", clickable: domClickable, focusablePointer: true)])
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome", query: nil)
            try await fixture.transport.replaceNodes(targetID: observation.binding.targetID,
                nodes: [semanticNode(0, role: "row", name: "Stable label", clickable: domClickable, focusablePointer: false)])
            await assertBrowserError(.elementChanged) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            }
            await fixture.assertNoInput()
        }
    }

    func testBrowserClickabilitySurvivesRetainedPaginationAndExactIndexCopies() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: (0 ..< 70).map { semanticNode($0, role: "row", name: "Item \($0)", clickable: true, focusablePointer: true) })
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", query: nil)
        let second = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
            bundleIdentifier: "com.google.Chrome", read: .init(cursor: try XCTUnwrap(first.snapshot.nextCursor)))
        XCTAssertFalse(second.snapshot.isLiveObservation)
        XCTAssertTrue(second.snapshot.elements.allSatisfy { $0.isDOMClickable && $0.isFocusablePointer && $0.supportsPress })
        let target = try XCTUnwrap(second.snapshot.element(at: 0))
        XCTAssertEqual(target.backendNodeID, Int64(first.snapshot.elements.count + 1))
        XCTAssertTrue(second.snapshot.formattedText.contains("press_source=browser_clickability"))
        try await fixture.broker.perform(taskKey: "task-a", binding: second.binding,
            snapshot: second.snapshot, elementIndex: 0, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: second.binding.targetID)
        XCTAssertEqual(pressed, [target.backendNodeID])
    }

    func testUnsupportedAndMissingElementPreflightPreservesSnapshotForSupportedMutation() async throws {
        for setText in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
                semanticNode(0, role: "generic", name: "Passive"),
                semanticNode(1, role: "textbox", name: "Read only", readOnly: true),
                semanticNode(2, role: "textbox", name: "Editable"),
                semanticNode(3, role: "row", name: "Clickable", clickable: true),
            ])
            let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome", query: nil)
            await assertBrowserError(.elementNotFound) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 99, action: "AXPress")
            }
            await assertBrowserError(.unsupportedAction("AXPress")) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 0, action: "AXPress")
            }
            await assertBrowserError(.elementNotFound) {
                try await fixture.broker.setText(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 99, text: "not sent")
            }
            for index in [0, 1] {
                await assertBrowserError(.unsupportedAction("set text")) {
                    try await fixture.broker.setText(taskKey: "task-a", binding: observation.binding,
                        snapshot: observation.snapshot, elementIndex: index, text: "not sent")
                }
            }
            await fixture.assertNoInput()
            if setText {
                try await fixture.broker.setText(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 2, text: "supported once")
                let values = await fixture.transport.textValues(targetID: observation.binding.targetID)
                XCTAssertEqual(values, ["supported once"])
            } else {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 3, action: "AXPress")
                let pressed = await fixture.transport.pressedNodeIDs(targetID: observation.binding.targetID)
                XCTAssertEqual(pressed, [4])
            }
            await assertBrowserError(.staleSnapshot) {
                try await fixture.broker.perform(taskKey: "task-a", binding: observation.binding,
                    snapshot: observation.snapshot, elementIndex: 3, action: "AXPress")
            }
        }
    }

    func testSnapshotRetainsOriginalSemanticRolesAlongsideAXDisplayRoles() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "searchbox", name: "Text"),
            semanticNode(1, role: "region", name: "Search results", children: ["n2"]),
            semanticNode(2, role: "status", name: "No results found", parent: "n1"),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", query: nil)
        XCTAssertEqual(observation.snapshot.elements.map(\.role), ["AXTextField", "AXGroup", "AXGroup"])
        XCTAssertEqual(observation.snapshot.elements.map(\.semanticRole), ["searchbox", "region", "status"])
        let input = try XCTUnwrap(observation.snapshot.elements.first)
        XCTAssertTrue(ComputerSearchEvidence.isSearchInput(role: input.semanticRole ?? input.role, label: input.label))
        XCTAssertFalse(ComputerSearchEvidence.isSearchInput(role: input.role, label: input.label),
            "The generic AX role and generic Text label are not evidence of a search input.")
    }

    func testSemanticRoleChangeInvalidatesApprovalEvenWhenDisplayRoleIsUnchanged() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "textbox", name: "Text")])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", query: nil)
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "searchbox", name: "Text")])
        await assertBrowserError(.elementChanged) {
            try await fixture.broker.setText(taskKey: "task-a", binding: observation.binding,
                snapshot: observation.snapshot, elementIndex: 0, text: "must not dispatch")
        }
        await fixture.assertNoInput()
    }

    func testOversizedURLsAreOmittedWholeWhileExactMutationIdentityIsRetained() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let longURL = "https://example.test/unique-destination/" + String(repeating: "a", count: 2400) + "/actual-target"
        let destination = try XCTUnwrap(URL(string: longURL))
        try await fixture.transport.navigate(
            targetID: fixture.observation.binding.targetID, url: destination, loaderID: "long-url-loader"
        )
        try await fixture.transport.replaceNodes(
            targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "link", name: "Read exact destination", link: longURL)]
        )
        let result = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome", query: nil
        )
        XCTAssertTrue(result.snapshot.formattedText.contains("url_omitted=1"))
        XCTAssertTrue(result.snapshot.formattedText.contains("href_omitted=1"))
        XCTAssertFalse(result.snapshot.formattedText.contains(String(longURL.prefix(2048))))
        XCTAssertFalse(result.snapshot.formattedText.contains("https://example.test/unique-destination/"))
        XCTAssertEqual(result.snapshot.documentURL, destination)
        XCTAssertEqual(result.snapshot.elements.first?.linkURL, longURL)
        try await fixture.broker.perform(
            taskKey: "task-a", binding: result.binding, snapshot: result.snapshot, elementIndex: 0, action: "AXPress"
        )
        let pressed = await fixture.transport.pressedNodeIDs(targetID: result.binding.targetID)
        XCTAssertEqual(pressed, [1])
    }

    func testProgressiveHeadingReadFindsUnknownTitlesAfterWideDeepWrappers() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let wrappers = (0 ..< 350).map { index in
            semanticNode(index, role: "generic", name: "", parent: index == 0 ? nil : "n\(index - 1)", children: ["n\(index + 1)"])
        }
        let headings = (350 ..< 487).map { index in
            semanticNode(index, role: "heading", name: "Previously unknown title \(index)", parent: "n349")
        }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: wrappers + headings)
        var observation = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome",
            read: SemanticReadRequest(view: .headings)
        )
        var labels = observation.snapshot.elements.map(\.label)
        XCTAssertEqual(observation.snapshot.totalMatches, 137)
        XCTAssertTrue(observation.snapshot.formattedText.contains("parent_node=\"n349\""))
        XCTAssertNotNil(observation.snapshot.nextCursor)
        XCTAssertLessThan(observation.snapshot.formattedText.count, 11_000)
        while let cursor = observation.snapshot.nextCursor {
            observation = try await fixture.broker.snapshot(
                taskKey: "task-a", binding: observation.binding, bundleIdentifier: "com.google.Chrome",
                read: SemanticReadRequest(cursor: cursor)
            )
            labels.append(contentsOf: observation.snapshot.elements.map(\.label))
        }
        XCTAssertEqual(labels, headings.map(\.name))
        XCTAssertTrue(observation.snapshot.formattedText.contains("output_truncated=0"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("visibility=unknown"))
    }

    func testContentScopeDistinguishesIdenticalLabelsByObservedAncestry() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let label = "The same observed phrase"
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "RootWebArea", name: "", children: ["n1", "n3", "n8"]),
            semanticNode(1, role: "navigation", name: "", parent: "n0", children: ["n2"]),
            semanticNode(2, role: "link", name: label, parent: "n1"),
            semanticNode(3, role: "main", name: "", parent: "n0", children: ["n4", "n5", "n6"]),
            semanticNode(4, role: "StaticText", name: label, parent: "n3"),
            semanticNode(5, role: "article", name: label, parent: "n3"),
            semanticNode(6, role: "navigation", name: "", parent: "n3", children: ["n7"]),
            semanticNode(7, role: "link", name: label, parent: "n6"),
            semanticNode(8, role: "complementary", name: "", parent: "n0", children: ["n9"]),
            semanticNode(9, role: "article", name: label, parent: "n8"),
        ])
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", read: SemanticReadRequest(view: .content))
        XCTAssertEqual(observation.snapshot.elements.map(\.label), Array(repeating: label, count: 5))
        XCTAssertEqual(observation.snapshot.elements.map(\.contentScope), [.navigation, .main, .article, .navigation, .complementary])
        XCTAssertEqual(observation.snapshot.elements.map(\.supportsPress), [true, false, false, true, false],
                       "Provenance must not add or remove action authority.")
        for scope in ["navigation", "main", "article", "complementary"] {
            XCTAssertTrue(observation.snapshot.formattedText.contains("content_scope=\(scope)"))
        }
        XCTAssertTrue(observation.snapshot.formattedText.contains("document_content_shown=2 navigation_shown=2 complementary_shown=1"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("subject_relevance=not_verified"))
        await fixture.assertNoInput()
    }

    func testMissingAmbiguousOrCyclicContentAncestryRemainsUnknown() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: [
            semanticNode(0, role: "StaticText", name: "No parent"),
            semanticNode(1, role: "StaticText", name: "Missing parent", parent: "missing"),
            semanticNode(2, role: "main", name: "Main with incomplete ancestry", parent: "missing"),
            semanticNode(3, role: "StaticText", name: "Cyclic parent", parent: "n4"),
            semanticNode(4, role: "generic", name: "", parent: "n3"),
            semanticNode(5, role: "main", name: ""),
            semanticNode(5, role: "navigation", name: ""),
            semanticNode(6, role: "StaticText", name: "Ambiguous parent", parent: "n5"),
        ], sourceTruncated: true)
        let observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", read: SemanticReadRequest(view: .content))
        XCTAssertEqual(observation.snapshot.elements.count, 5)
        XCTAssertTrue(observation.snapshot.elements.allSatisfy { $0.contentScope == .unknown })
        XCTAssertTrue(observation.snapshot.formattedText.contains("document_content_shown=0"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("unknown_shown=5"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("source_truncated=1"))
        XCTAssertTrue(observation.snapshot.formattedText.contains("Unknown scope is not proof that content is absent."))
        await fixture.assertNoInput()
    }

    func testContentProvenanceCountsOnlyTheExposedPageOfTruncatedObservations() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        var nodes = [
            semanticNode(0, role: "RootWebArea", name: ""),
            semanticNode(1, role: "navigation", name: "", parent: "n0"),
            semanticNode(2, role: "main", name: "", parent: "n0"),
        ]
        nodes += (3..<73).map { semanticNode($0, role: "StaticText", name: "Navigation label \($0)", parent: "n1") }
        nodes += (73..<143).map { semanticNode($0, role: "StaticText", name: "Document text \($0)", parent: "n2") }
        nodes += (143..<146).map { semanticNode($0, role: "StaticText", name: "Unknown text \($0)", parent: "missing") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                                                 nodes: nodes, sourceTruncated: true)
        var observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", read: SemanticReadRequest(view: .content))
        var allElements = [BrowserTabElement]()
        var pages = 0
        while true {
            let elements = observation.snapshot.elements
            let content = elements.filter { $0.contentScope.isDocumentContent }.count
            let navigation = elements.filter { $0.contentScope == .navigation }.count
            let unknown = elements.filter { $0.contentScope == .unknown }.count
            let header = try XCTUnwrap(observation.snapshot.formattedText.split(separator: "\n")
                .first { $0.hasPrefix("CONTENT_EVIDENCE ") })
            XCTAssertTrue(header.contains("document_content_shown=\(content) "))
            XCTAssertTrue(header.contains("navigation_shown=\(navigation) "))
            XCTAssertTrue(header.contains("unknown_shown=\(unknown) "))
            XCTAssertEqual(content + navigation + unknown, elements.count)
            XCTAssertTrue(observation.snapshot.sourceTruncated)
            XCTAssertTrue(header.contains("subject_relevance=not_verified"))
            allElements += elements
            pages += 1
            guard let cursor = observation.snapshot.nextCursor else { break }
            observation = try await fixture.broker.snapshot(taskKey: "task-a", binding: observation.binding,
                bundleIdentifier: "com.google.Chrome", read: SemanticReadRequest(cursor: cursor))
        }
        XCTAssertGreaterThan(pages, 2)
        XCTAssertEqual(allElements.count, 143)
        XCTAssertEqual(allElements.filter { $0.contentScope == .main }.count, 70)
        XCTAssertEqual(allElements.filter { $0.contentScope == .navigation }.count, 70)
        XCTAssertEqual(allElements.filter { $0.contentScope == .unknown }.count, 3)
        await fixture.assertNoInput()
    }

    func testNoMatchReturnsNoUnrelatedFallbackAndReportsIncompleteSource() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(
            targetID: fixture.observation.binding.targetID,
            nodes: [semanticNode(0, role: "heading", name: "A real title")], sourceTruncated: true
        )
        let result = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome",
            read: SemanticReadRequest(query: "video title")
        )
        XCTAssertTrue(result.snapshot.elements.isEmpty)
        XCTAssertEqual(result.snapshot.totalMatches, 0)
        XCTAssertTrue(result.snapshot.formattedText.contains("no_matches=1"))
        XCTAssertTrue(result.snapshot.formattedText.contains("source_truncated=1"))
        XCTAssertFalse(result.snapshot.formattedText.contains("A real title"))
        XCTAssertNil(result.snapshot.nextCursor)
    }

    func testSubtreeExpansionRetainsAttributionAndLinkDestination() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = [
            semanticNode(0, role: "generic", name: "First card", children: ["n1", "n2"]),
            semanticNode(1, role: "heading", name: "Exact title", parent: "n0"),
            semanticNode(2, role: "link", name: "Publisher", parent: "n0", link: "https://example.test/publisher"),
            semanticNode(3, role: "generic", name: "Other card", children: ["n4"]),
            semanticNode(4, role: "heading", name: "Unrelated title", parent: "n3"),
        ]
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let first = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome", query: nil
        )
        let expanded = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome",
            read: SemanticReadRequest(snapshotID: first.snapshot.id, elementIndex: 0)
        )
        XCTAssertEqual(expanded.snapshot.elements.map(\.label), ["First card", "Exact title", "Publisher"])
        XCTAssertTrue(expanded.snapshot.formattedText.contains("href=\"https://example.test/publisher\""))
        XCTAssertTrue(expanded.snapshot.formattedText.contains("scope_node=\"n0\""))
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome",
                read: SemanticReadRequest(snapshotID: first.snapshot.id, elementIndex: 0)
            )
        }
    }

    func testCursorIsSingleUseAndInvalidatedByChangedDocumentOrNewRead() async throws {
        for cause in ["reuse", "new_read", "navigation"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            let nodes = (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
            let first = try await fixture.broker.snapshot(
                taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome",
                read: SemanticReadRequest(view: .links)
            )
            let cursor = try XCTUnwrap(first.snapshot.nextCursor)
            switch cause {
            case "reuse":
                _ = try await fixture.broker.snapshot(
                    taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome",
                    read: SemanticReadRequest(cursor: cursor)
                )
            case "new_read":
                _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome", query: nil)
            default:
                try await fixture.transport.navigate(targetID: first.binding.targetID, url: URL(string: "https://example.test/new")!, loaderID: "new-loader")
            }
            await assertBrowserError(.staleSnapshot) {
                _ = try await fixture.broker.snapshot(
                    taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome",
                    read: SemanticReadRequest(cursor: cursor)
                )
            }
        }
    }

    func testCursorAcceptsRepeatedMatchingFiltersAndRetainsSingleUse() async throws {
        for options in ["none", "view", "query", "both"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            let nodes = (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
            let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome", read: .init(query: "Item", view: .links))
            let cursor = try XCTUnwrap(first.snapshot.nextCursor)
            let second = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
                bundleIdentifier: "com.google.Chrome", read: .init(
                    query: options == "query" || options == "both" ? " Item\n" : nil,
                    view: options == "view" || options == "both" ? .links : nil, cursor: cursor))
            XCTAssertEqual(second.snapshot.totalMatches, 140)
            XCTAssertTrue(second.snapshot.formattedText.contains("observation=retained"))
            let firstLabels = Set(first.snapshot.elements.map(\.label))
            let secondLabels = Set(second.snapshot.elements.map(\.label))
            XCTAssertFalse(secondLabels.isEmpty)
            XCTAssertTrue(firstLabels.isDisjoint(with: secondLabels))
            await assertBrowserError(.staleSnapshot) {
                _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: second.binding,
                    bundleIdentifier: "com.google.Chrome", read: .init(query: "Item", view: .links, cursor: cursor))
            }
            await fixture.assertNoInput()
        }
    }

    func testCursorRejectsChangedFiltersAndSubtreeEvenWhenCursorIsCurrent() async throws {
        for change in ["view", "query", "snapshot", "index", "subtree"] {
            let fixture = try await BrowserBrokerTestFixture.make()
            try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
                nodes: (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") })
            let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome", read: .init(query: "Item", view: .links))
            let cursor = try XCTUnwrap(first.snapshot.nextCursor)
            let request = SemanticReadRequest(query: change == "query" ? "Different" : "Item",
                view: change == "view" ? .content : .links, cursor: cursor,
                snapshotID: change == "snapshot" || change == "subtree" ? first.snapshot.id : nil,
                elementIndex: change == "index" || change == "subtree" ? 0 : nil)
            do {
                _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
                    bundleIdentifier: "com.google.Chrome", read: request)
                XCTFail("Conflicting continuation must fail: \(change)")
            } catch let error as BrowserTabBrokerError {
                guard case .invalidRead = error else { return XCTFail("Expected invalidRead, got \(error)") }
            }
            await fixture.assertNoInput()
        }
    }

    func testRepeatedMatchingFiltersCannotReviveAStaleCursorAfterNavigation() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID,
            nodes: (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") })
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome", read: .init(query: "Item", view: .links))
        let cursor = try XCTUnwrap(first.snapshot.nextCursor)
        try await fixture.transport.navigate(targetID: first.binding.targetID,
            url: URL(string: "https://example.test/replaced")!, loaderID: "replaced-loader")
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding,
                bundleIdentifier: "com.google.Chrome", read: .init(query: "Item", view: .links, cursor: cursor))
        }
        await fixture.assertNoInput()
    }

    func testRetainedPagesSurviveUnrelatedLiveChangesAndIndicesDispatchExactLateTarget() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome", query: nil)
        try await fixture.transport.replaceNodes(
            targetID: first.binding.targetID, nodes: nodes + [semanticNode(999, role: "heading", name: "Clock changed")]
        )
        let second = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome",
            read: SemanticReadRequest(cursor: try XCTUnwrap(first.snapshot.nextCursor))
        )
        XCTAssertEqual(second.snapshot.totalMatches, 140, "One observation must not splice in the new clock.")
        XCTAssertTrue(second.snapshot.formattedText.contains("observation=retained"))
        let lateTarget = try XCTUnwrap(second.snapshot.element(at: 0))
        XCTAssertEqual(lateTarget.backendNodeID, Int64(first.snapshot.elements.count + 1))
        await assertBrowserError(.staleSnapshot) {
            try await fixture.broker.perform(taskKey: "task-a", binding: first.binding, snapshot: first.snapshot, elementIndex: 0, action: "AXPress")
        }
        try await fixture.broker.perform(taskKey: "task-a", binding: second.binding, snapshot: second.snapshot, elementIndex: 0, action: "AXPress")
        let pressed = await fixture.transport.pressedNodeIDs(targetID: first.binding.targetID)
        XCTAssertEqual(pressed, [lateTarget.backendNodeID])
    }

    func testRetainedPageActionRejectsChangedTargetAndFreshReadSeesNewContent() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let nodes = (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
        try await fixture.transport.replaceNodes(targetID: fixture.observation.binding.targetID, nodes: nodes)
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome", query: nil)
        let changedIndex = first.snapshot.elements.count
        var changedNodes = nodes
        changedNodes[changedIndex] = semanticNode(changedIndex, role: "link", name: "Replacement destination")
        try await fixture.transport.replaceNodes(targetID: first.binding.targetID, nodes: changedNodes)
        let second = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome",
            read: SemanticReadRequest(cursor: try XCTUnwrap(first.snapshot.nextCursor))
        )
        await assertBrowserError(.elementChanged) {
            try await fixture.broker.perform(taskKey: "task-a", binding: second.binding, snapshot: second.snapshot, elementIndex: 0, action: "AXPress")
        }
        let fresh = try await fixture.broker.snapshot(
            taskKey: "task-a", binding: second.binding, bundleIdentifier: "com.google.Chrome", query: "Replacement destination"
        )
        XCTAssertEqual(fresh.snapshot.elements.map(\.label), ["Replacement destination"])
        XCTAssertTrue(fresh.snapshot.formattedText.contains("observation=live"))
        await fixture.assertNoInput()
    }

    func testExpiredReadCursorRejectsButNewLiveReadWorks() async throws {
        let fixture = try await BrowserBrokerTestFixture.make(readLifetime: .zero)
        try await fixture.transport.replaceNodes(
            targetID: fixture.observation.binding.targetID,
            nodes: (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
        )
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome", query: nil)
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome",
                read: SemanticReadRequest(cursor: first.snapshot.nextCursor)
            )
        }
        let fresh = try await fixture.broker.snapshot(taskKey: "task-a", binding: first.binding, bundleIdentifier: "com.google.Chrome", query: "Item 139")
        XCTAssertEqual(fresh.snapshot.elements.map(\.label), ["Item 139"])
    }

    func testForeignCursorAndUnexposedElementCannotAuthorizeInput() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.replaceNodes(
            targetID: fixture.observation.binding.targetID,
            nodes: (0 ..< 140).map { semanticNode($0, role: "link", name: "Item \($0)") }
        )
        let first = try await fixture.broker.snapshot(taskKey: "task-a", binding: fixture.observation.binding, bundleIdentifier: "com.google.Chrome", query: nil)
        let other = try await fixture.broker.open(taskKey: "task-b", processIdentifier: 60, url: URL(string: "https://example.test/other")!)
        await assertBrowserError(.staleSnapshot) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-b", binding: other, bundleIdentifier: "com.google.Chrome",
                read: SemanticReadRequest(cursor: first.snapshot.nextCursor)
            )
        }
        await assertBrowserError(.elementNotFound) {
            try await fixture.broker.perform(
                taskKey: "task-a", binding: first.binding, snapshot: first.snapshot,
                elementIndex: 100, action: "AXPress"
            )
        }
        await fixture.assertNoInput()
    }

    private func semanticNode(
        _ id: Int, role: String, name: String, parent: String? = nil,
        children: [String] = [], link: String? = nil,
        clickable: Bool = false, focusablePointer: Bool = false, disabled: Bool = false, readOnly: Bool = false
    ) -> BrowserDocumentNode {
        BrowserDocumentNode(
            backendNodeID: Int64(id + 1), role: role, name: name, value: nil,
            isDisabled: disabled, isReadOnly: readOnly, isIgnored: false,
            nodeID: "n\(id)", parentNodeID: parent, childNodeIDs: children, linkURL: link,
            isDOMClickable: clickable, isFocusablePointer: focusablePointer
        )
    }

    func testTaskScopedHandleRejectsCrossTaskSnapshot() async throws {
        let transport = FakeBrowserTabTransport()
        let generation = UUID()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: generation
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 41,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )

        do {
            _ = try await broker.snapshot(
                taskKey: "task-b",
                binding: binding,
                bundleIdentifier: "com.google.Chrome",
                query: "Mark this tab complete"
            )
            XCTFail("A cross-task browser handle must fail closed.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .crossTaskHandle)
        }
    }

    func testNavigationChangesEpochAndRejectsApprovedSnapshotBeforeInput() async throws {
        let transport = FakeBrowserTabTransport()
        let generation = UUID()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: generation
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 42,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observation = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )
        try await transport.navigate(
            targetID: binding.targetID,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a?next=1")),
            loaderID: "loader-2"
        )

        do {
            try await broker.perform(
                taskKey: "task-a",
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
            XCTFail("A stale document epoch must reject before input.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .staleDocument)
        }
        let stalePressCount = await transport.pressCount(targetID: binding.targetID)
        XCTAssertEqual(stalePressCount, 0)

        let refreshed = try await broker.snapshot(
            taskKey: "task-a",
            binding: observation.binding,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )
        XCTAssertNotEqual(
            refreshed.binding.documentEpoch,
            observation.binding.documentEpoch
        )
    }



    func testNewObservationInvalidatesPriorBrowserSnapshot() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 46,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let first = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )
        _ = try await broker.snapshot(
            taskKey: "task-a",
            binding: first.binding,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )

        do {
            try await broker.perform(
                taskKey: "task-a",
                binding: first.binding,
                snapshot: first.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
            XCTFail("A newer observation must invalidate the prior snapshot.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .staleSnapshot)
        }
        let pressCount = await transport.pressCount(targetID: binding.targetID)
        XCTAssertEqual(pressCount, 0)
    }

    func testClosedTargetRejectsBeforeInput() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 45,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        await transport.closeTarget(targetID: binding.targetID)

        do {
            _ = try await broker.snapshot(
                taskKey: "task-a",
                binding: binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
            XCTFail("A closed tab must reject before any input.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .targetClosed)
        }
    }

    func testClosedOrReusedTargetCannotResurrectHandle() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 43,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        try await transport.replaceTargetInstance(targetID: binding.targetID)

        do {
            _ = try await broker.snapshot(
                taskKey: "task-a",
                binding: binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
            XCTFail("A target-ID reuse must not resurrect the opaque handle.")
        } catch let error as BrowserTabBrokerError {
            XCTAssertEqual(error, .targetReplaced)
        }
    }

    func testExactBackgroundTargetMutatesWhileOtherTargetStaysForeground() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID()
        )
        let bindingA = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 44,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observationA = try await broker.snapshot(
            taskKey: "task-a",
            binding: bindingA,
            bundleIdentifier: "com.google.Chrome",
            query: "Mark this tab complete"
        )
        let targetB = try await transport.createForegroundTarget(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        let foregroundBefore = await transport.activeTargetID()
        XCTAssertEqual(foregroundBefore, targetB.targetID)

        try await broker.perform(
            taskKey: "task-a",
            binding: observationA.binding,
            snapshot: observationA.snapshot,
            elementIndex: 0,
            action: "AXPress"
        )

        let tabAPressCount = await transport.pressCount(targetID: bindingA.targetID)
        let tabBPressCount = await transport.pressCount(targetID: targetB.targetID)
        let foregroundAfter = await transport.activeTargetID()
        XCTAssertEqual(tabAPressCount, 1)
        XCTAssertEqual(tabBPressCount, 0)
        XCTAssertEqual(foregroundAfter, targetB.targetID)
    }

    func testSnapshotRevocationNeverResurrectsHandle() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            try await fixture.broker.revoke(
                taskKey: "task-a",
                binding: fixture.observation.binding
            )
        }
        await assertBrowserError(.handleMissing) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
        }
        await assertBrowserError(.handleMissing) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
        }
        await fixture.assertNoInput()
    }

    func testRevocationCancelsBothActionsAcrossAwaits() async throws {
        for setText in [false, true] {
            for atDispatch in [false, true] {
                let fixture = try await BrowserBrokerTestFixture.make()
                let revoke: @Sendable () async throws -> Void = {
                    try await fixture.broker.revoke(
                        taskKey: "task-a",
                        binding: fixture.observation.binding
                    )
                }
                if atDispatch {
                    await fixture.transport.onNextMutation(revoke)
                } else {
                    await fixture.transport.onNextObservation(revoke)
                }
                await assertBrowserError(atDispatch ? .staleSnapshot : .handleMissing) {
                    try await fixture.act(setText: setText)
                }
                await fixture.assertNoInput()
            }
        }
    }

    func testLateReloadAndFragmentChangeRejectBothActions() async throws {
        for setText in [false, true] {
            for sameLoader in [false, true] {
                let fixture = try await BrowserBrokerTestFixture.make()
                let destination: URL
                if sameLoader {
                    destination = try XCTUnwrap(URL(string: "http://127.0.0.1/a#changed"))
                } else {
                    destination = fixture.observation.snapshot.documentURL
                }
                let loaderID = sameLoader
                    ? fixture.observation.snapshot.loaderID : "replacement-loader"
                await fixture.transport.onNextMutation {
                    try await fixture.transport.navigate(
                        targetID: fixture.observation.binding.targetID,
                        url: destination,
                        loaderID: loaderID
                    )
                }
                await assertBrowserError(.staleDocument) {
                    try await fixture.act(setText: setText)
                }
                await fixture.assertNoInput()
                let refreshed = try await fixture.broker.snapshot(
                    taskKey: "task-a",
                    binding: fixture.observation.binding,
                    bundleIdentifier: "com.google.Chrome",
                    query: nil
                )
                XCTAssertNotEqual(
                    refreshed.binding.documentEpoch,
                    fixture.observation.binding.documentEpoch
                )
            }
        }
    }

    func testOverlappingSnapshotFailsClosed() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            await assertBrowserError(.operationInProgress) {
                _ = try await fixture.broker.snapshot(
                    taskKey: "task-a",
                    binding: fixture.observation.binding,
                    bundleIdentifier: "com.google.Chrome",
                    query: nil
                )
            }
        }
        let refreshed = try await fixture.broker.snapshot(
            taskKey: "task-a",
            binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome",
            query: nil
        )
        XCTAssertNotEqual(refreshed.snapshot.id, fixture.observation.snapshot.id)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: false)
        }
        await fixture.assertNoInput()
    }

    func testFailedSnapshotInvalidatesPriorObservation() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        await fixture.transport.onNextObservation {
            throw BrowserTabBrokerError.browserUnavailable("injected observation failure")
        }
        await assertBrowserError(.browserUnavailable("injected observation failure")) {
            _ = try await fixture.broker.snapshot(
                taskKey: "task-a",
                binding: fixture.observation.binding,
                bundleIdentifier: "com.google.Chrome",
                query: nil
            )
        }
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: false)
        }
        await fixture.assertNoInput()
    }

    func testCrossTaskMutationsRejectBeforeInput() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        for setText in [false, true] {
            await assertBrowserError(.crossTaskHandle) {
                try await fixture.act(setText: setText, taskKey: "task-b")
            }
        }
        await fixture.assertNoInput()
    }

    func testBackgroundSetTextIsSingleUseAndLeavesForegroundUntouched() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let targetB = try await fixture.transport.createForegroundTarget(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        try await fixture.act(setText: true)
        let valuesA = await fixture.transport.textValues(
            targetID: fixture.observation.binding.targetID
        )
        let valuesB = await fixture.transport.textValues(targetID: targetB.targetID)
        let foreground = await fixture.transport.activeTargetID()
        XCTAssertEqual(valuesA, ["updated"])
        XCTAssertTrue(valuesB.isEmpty)
        XCTAssertEqual(foreground, targetB.targetID)
        await assertBrowserError(.staleSnapshot) {
            try await fixture.act(setText: true)
        }
        let finalValuesA = await fixture.transport.textValues(
            targetID: fixture.observation.binding.targetID
        )
        XCTAssertEqual(finalValuesA, ["updated"])
    }

    func testReadOnlyTextIsNotAdvertisedOrMutated() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.transport.makeTextReadOnly(
            targetID: fixture.observation.binding.targetID
        )
        await assertBrowserError(.elementChanged) {
            try await fixture.act(setText: true)
        }
        let refreshed = try await fixture.broker.snapshot(
            taskKey: "task-a",
            binding: fixture.observation.binding,
            bundleIdentifier: "com.google.Chrome",
            query: nil
        )
        let field = try XCTUnwrap(refreshed.snapshot.element(at: 1))
        XCTAssertFalse(field.supportsSetText)
        await assertBrowserError(.unsupportedAction("set text")) {
            try await fixture.broker.setText(
                taskKey: "task-a",
                binding: refreshed.binding,
                snapshot: refreshed.snapshot,
                elementIndex: 1,
                text: "not allowed"
            )
        }
        await fixture.assertNoInput()
    }

    func testMutationPermitRevocationAndSingleUse() throws {
        var sends = 0
        let revoked = BrowserMutationPermit()
        revoked.revoke()
        XCTAssertThrowsError(try revoked.commit { sends += 1 }) { error in
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        XCTAssertEqual(sends, 0)

        let committed = BrowserMutationPermit()
        try committed.commit { sends += 1 }
        XCTAssertThrowsError(try committed.commit { sends += 1 }) { error in
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        committed.revoke()
        XCTAssertEqual(sends, 1)
    }

    func testRevokingOneTaskClosesOnlyItsTargetAndPreservesOtherBinding() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let bindingB = try await fixture.broker.open(
            taskKey: "task-b",
            processIdentifier: 47,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/b"))
        )
        try await fixture.broker.revoke(taskKey: "task-a", binding: fixture.observation.binding)
        let closed = await fixture.transport.closedTargetIDs()
        XCTAssertEqual(closed, [fixture.observation.binding.targetID])
        let targetA = try await fixture.transport.target(id: fixture.observation.binding.targetID)
        XCTAssertNil(targetA)
        let observationB = try await fixture.broker.snapshot(
            taskKey: "task-b", binding: bindingB,
            bundleIdentifier: "com.google.Chrome", query: nil
        )
        try await fixture.broker.setText(
            taskKey: "task-b", binding: observationB.binding,
            snapshot: observationB.snapshot, elementIndex: 1, text: "B only"
        )
        let valuesB = await fixture.transport.textValues(targetID: bindingB.targetID)
        let foreground = await fixture.transport.activeTargetID()
        XCTAssertEqual(valuesB, ["B only"])
        XCTAssertEqual(foreground, bindingB.targetID)
        for setText in [false, true] {
            await assertBrowserError(.handleMissing) { try await fixture.act(setText: setText) }
        }
        await fixture.assertNoInput()
    }

    func testSynchronousRuntimeRevocationWinsBeforeActorCleanup() async throws {
        for setText in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            await fixture.transport.onNextMutation {
                fixture.observation.binding.lifetime.revoke()
            }
            await assertBrowserError(.staleSnapshot) {
                try await fixture.act(setText: setText)
            }
            await fixture.assertNoInput()
        }
    }

    func testRevocationDuringCreationClosesTheUnpublishedTarget() async throws {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID())
        let lifetime = BrowserTabLifetime()
        await transport.onNextCreation { lifetime.revoke() }
        await assertBrowserError(.handleMissing) {
            _ = try await broker.open(
                taskKey: "pending", processIdentifier: 48,
                url: URL(string: "http://127.0.0.1/pending")!,
                lifetime: lifetime
            )
        }
        let closed = await transport.closedTargetIDs()
        XCTAssertEqual(closed, ["target-1"])
        let target = try await transport.target(id: "target-1")
        let presses = await transport.pressCount(targetID: "target-1")
        let values = await transport.textValues(targetID: "target-1")
        XCTAssertNil(target)
        XCTAssertEqual(presses, 0)
        XCTAssertTrue(values.isEmpty)
    }

    func testSessionShutdownRevokesSuspendedMutationAndRejectsNewOpen() async throws {
        for setText in [false, true] {
            let fixture = try await BrowserBrokerTestFixture.make()
            await fixture.transport.onNextObservation { await fixture.broker.invalidateAll() }
            await assertBrowserError(.handleMissing) {
                try await fixture.act(setText: setText)
            }
            await assertBrowserError(.handleMissing) {
                _ = try await fixture.broker.open(
                    taskKey: "later", processIdentifier: 47,
                    url: URL(string: "http://127.0.0.1/later")!
                )
            }
            await fixture.assertNoInput()
        }
    }

    func testFakeOracleRetainsInputHistoryAfterClose() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        try await fixture.act(setText: true)
        try await fixture.broker.revoke(taskKey: "task-a", binding: fixture.observation.binding)
        let values = await fixture.transport.textValues(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(values, ["updated"], "Closing a fake target must not erase evidence of input.")
    }

    func testSuccessfulPressWaitsForIndependentProofBeforeReturning() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let pause = BrowserPressBoundaryPause()
        let chrome = pressBoundaryBroker(fixture, pause: pause)
        let action = Task {
            try await chrome.perform(
                taskKey: fixture.observation.binding.taskKey, binding: fixture.observation.binding,
                snapshot: fixture.observation.snapshot, elementIndex: 0, action: "AXPress"
            )
            await pause.returned()
        }
        await pause.waitUntilEntered()
        let held = await pause.snapshot()
        XCTAssertEqual(held.events, ["proof_started"])
        XCTAssertEqual(held.handle, fixture.observation.binding.handle)
        XCTAssertEqual(held.snapshotID, fixture.observation.snapshot.id)
        let count = await fixture.transport.pressCount(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(count, 1)

        // The successful action consumed its snapshot before reaching the proof.
        // A retry cannot dispatch again or create a second proof callback.
        do {
            try await chrome.perform(
                taskKey: fixture.observation.binding.taskKey, binding: fixture.observation.binding,
                snapshot: fixture.observation.snapshot, elementIndex: 0, action: "AXPress"
            )
            XCTFail("A consumed snapshot must fail even while proof is suspended.")
        } catch {
            XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot)
        }
        await pause.release()
        try await action.value
        let completed = await pause.snapshot()
        XCTAssertEqual(completed.events, ["proof_started", "proof_completed", "press_returned"])
        let report = await chrome.shutdown()
        XCTAssertTrue(report.succeeded)
    }

    func testShutdownRevokesWhileReadOnlyPressProofIsSuspended() async throws {
        let fixture = try await BrowserBrokerTestFixture.make()
        let pause = BrowserPressBoundaryPause()
        let chrome = pressBoundaryBroker(fixture, pause: pause)
        let action = Task {
            try await chrome.perform(
                taskKey: fixture.observation.binding.taskKey, binding: fixture.observation.binding,
                snapshot: fixture.observation.snapshot, elementIndex: 0, action: "AXPress"
            )
        }
        await pause.waitUntilEntered()
        let report = await chrome.shutdown()
        XCTAssertTrue(report.succeeded)
        XCTAssertThrowsError(try fixture.observation.binding.lifetime.check())
        let held = await pause.snapshot()
        XCTAssertEqual(held.events, ["proof_started"])
        await pause.release()
        try await action.value // The earlier press happened; no second input is authorized.
        let count = await fixture.transport.pressCount(targetID: fixture.observation.binding.targetID)
        XCTAssertEqual(count, 1)
        let ownership = await chrome.ownership()
        XCTAssertNil(ownership)
        let repeated = await chrome.shutdown()
        XCTAssertEqual(repeated, report)
    }

    private func pressBoundaryBroker(
        _ fixture: BrowserBrokerTestFixture, pause: BrowserPressBoundaryPause
    ) -> ChromeTabBroker {
        let initial = ChromeTabBroker.BrowserProcess(
            process: BrowserPressBoundaryChild(processIdentifier: fixture.observation.binding.processIdentifier),
            dataDirectory: URL(fileURLWithPath: "/not-created/LocalCodexBrowserBroker-proof-test"),
            generation: fixture.observation.binding.browserGeneration,
            transport: SystemChromeDevToolsTransport(port: 1), sessions: fixture.broker
        )
        return ChromeTabBroker(
            initialBrowser: initial, removeProfile: { _ in nil },
            didPerformPress: { binding, snapshot in
                await pause.enter(handle: binding.handle, snapshotID: snapshot.id)
            }
        )
    }
}

private struct BrowserBrokerTestFixture: Sendable {
    let transport: FakeBrowserTabTransport
    let broker: BrowserTabSessionBroker
    let observation: BrowserTabObservation

    static func make(readLifetime: Duration = .seconds(120)) async throws -> BrowserBrokerTestFixture {
        let transport = FakeBrowserTabTransport()
        let broker = BrowserTabSessionBroker(
            transport: transport,
            browserGeneration: UUID(),
            readLifetime: readLifetime
        )
        let binding = try await broker.open(
            taskKey: "task-a",
            processIdentifier: 47,
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/a"))
        )
        let observation = try await broker.snapshot(
            taskKey: "task-a",
            binding: binding,
            bundleIdentifier: "com.google.Chrome",
            query: nil
        )
        return BrowserBrokerTestFixture(
            transport: transport,
            broker: broker,
            observation: observation
        )
    }

    func act(setText: Bool, taskKey: String = "task-a") async throws {
        if setText {
            try await broker.setText(
                taskKey: taskKey,
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 1,
                text: "updated"
            )
        } else {
            try await broker.perform(
                taskKey: taskKey,
                binding: observation.binding,
                snapshot: observation.snapshot,
                elementIndex: 0,
                action: "AXPress"
            )
        }
    }

    func assertNoInput(file: StaticString = #filePath, line: UInt = #line) async {
        let presses = await transport.pressCount(targetID: observation.binding.targetID)
        let values = await transport.textValues(targetID: observation.binding.targetID)
        XCTAssertEqual(presses, 0, file: file, line: line)
        XCTAssertTrue(values.isEmpty, file: file, line: line)
    }
}

private func assertBrowserError(
    _ expected: BrowserTabBrokerError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: @Sendable () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch let error as BrowserTabBrokerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private actor FakeBrowserTabTransport: BrowserTabTransport {
    private struct State {
        var target: BrowserTarget
        var document: BrowserDocumentObservation
        var pressCount = 0
        var pressedNodeIDs: [Int64] = []
        var textValues = [String]()
    }

    private var nextTarget = 1
    private var states = [String: State]()
    private var closedStates = [String: State]()
    private var closedIDs = [String]()
    private var nextCreationHook: (@Sendable () async throws -> Void)?
    private var foregroundTargetID: String?
    private var nextObservationHook: (@Sendable () async throws -> Void)?
    private var nextMutationHook: (@Sendable () async throws -> Void)?

    func onNextCreation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextCreationHook = hook
    }

    func closedTargetIDs() -> [String] { closedIDs }

    func onNextObservation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextObservationHook = hook
    }

    func onNextMutation(_ hook: @escaping @Sendable () async throws -> Void) {
        nextMutationHook = hook
    }

    func replaceNodes(targetID: String, nodes: [BrowserDocumentNode], sourceTruncated: Bool = false) throws {
        guard var state = states[targetID] else { throw BrowserTabBrokerError.targetClosed }
        state.document = BrowserDocumentObservation(
            loaderID: state.document.loaderID, title: state.document.title, url: state.document.url,
            nodes: nodes, sourceTruncated: sourceTruncated
        )
        states[targetID] = state
    }

    func createTarget(url: URL) async throws -> BrowserTarget {
        let targetID = "target-\(nextTarget)"
        nextTarget += 1
        let target = makeTarget(targetID: targetID, url: url, instance: UUID())
        states[targetID] = State(
            target: target,
            document: makeDocument(url: url, loaderID: "loader-\(targetID)")
        )
        let hook = nextCreationHook
        nextCreationHook = nil
        if let hook { try await hook() }
        return target
    }

    func target(id: String) async throws -> BrowserTarget? {
        states[id]?.target
    }

    func activateTarget(id: String) async throws {
        guard states[id] != nil else {
            throw BrowserTabBrokerError.targetClosed
        }
        foregroundTargetID = id
    }

    func observe(target: BrowserTarget) async throws -> BrowserDocumentObservation {
        guard let state = states[target.targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard state.target.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        let hook = nextObservationHook
        nextObservationHook = nil
        if let hook { try await hook() }
        return state.document
    }

    func press(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        let hook = nextMutationHook
        nextMutationHook = nil
        if let hook { try await hook() }
        try permit.commit {
            var state = try stateForMutation(
                target: target, backendNodeID: backendNodeID, document: document
            )
            state.pressCount += 1
            state.pressedNodeIDs.append(backendNodeID)
            states[target.targetID] = state
        }
    }

    func setText(
        target: BrowserTarget,
        backendNodeID: Int64,
        text: String,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit
    ) async throws {
        let hook = nextMutationHook
        nextMutationHook = nil
        if let hook { try await hook() }
        try permit.commit {
            var state = try stateForMutation(
                target: target, backendNodeID: backendNodeID, document: document
            )
            state.textValues.append(text)
            states[target.targetID] = state
        }
    }

    private func stateForMutation(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation
    ) throws -> State {
        guard let state = states[target.targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        guard state.target.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        guard state.document.loaderID == document.loaderID,
              state.document.url == document.url else {
            throw BrowserTabBrokerError.staleDocument
        }
        let approved = document.nodes.filter { $0.backendNodeID == backendNodeID }
        let current = state.document.nodes.filter { $0.backendNodeID == backendNodeID }
        guard approved.count == 1, current.count == 1 else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard current[0] == approved[0] else {
            throw BrowserTabBrokerError.elementChanged
        }
        return state
    }

    func navigate(targetID: String, url: URL, loaderID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.target = makeTarget(
            targetID: targetID,
            url: url,
            instanceToken: state.target.instanceToken
        )
        state.document = makeDocument(url: url, loaderID: loaderID)
        states[targetID] = state
    }

    func closeTarget(target: BrowserTarget) async throws {
        guard let current = states[target.targetID]?.target else { return }
        guard current.instanceToken == target.instanceToken else {
            throw BrowserTabBrokerError.targetReplaced
        }
        closeTarget(targetID: target.targetID)
    }

    func closeTarget(targetID: String) {
        if let state = states.removeValue(forKey: targetID) {
            closedStates[targetID] = state
            closedIDs.append(targetID)
        }
        if foregroundTargetID == targetID {
            foregroundTargetID = nil
        }
    }

    func replaceTargetInstance(targetID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.target = makeTarget(
            targetID: targetID,
            url: state.target.url,
            instance: UUID()
        )
        states[targetID] = state
    }

    func createForegroundTarget(url: URL) async throws -> BrowserTarget {
        let target = try await createTarget(url: url)
        try await activateTarget(id: target.targetID)
        return target
    }

    func pressCount(targetID: String) -> Int {
        (states[targetID] ?? closedStates[targetID])?.pressCount ?? 0
    }

    func pressedNodeIDs(targetID: String) -> [Int64] {
        (states[targetID] ?? closedStates[targetID])?.pressedNodeIDs ?? []
    }

    func activeTargetID() -> String? {
        foregroundTargetID
    }

    func textValues(targetID: String) -> [String] {
        (states[targetID] ?? closedStates[targetID])?.textValues ?? []
    }

    func makeTextReadOnly(targetID: String) throws {
        guard var state = states[targetID] else {
            throw BrowserTabBrokerError.targetClosed
        }
        state.document = BrowserDocumentObservation(
            loaderID: state.document.loaderID,
            title: state.document.title,
            url: state.document.url,
            nodes: state.document.nodes.map { node in
                BrowserDocumentNode(
                    backendNodeID: node.backendNodeID,
                    role: node.role,
                    name: node.name,
                    value: node.value,
                    isDisabled: node.isDisabled,
                    isReadOnly: node.backendNodeID == 101 || node.isReadOnly,
                    isIgnored: node.isIgnored,
                    nodeID: node.nodeID, parentNodeID: node.parentNodeID,
                    childNodeIDs: node.childNodeIDs, linkURL: node.linkURL,
                    isDOMClickable: node.isDOMClickable, isFocusablePointer: node.isFocusablePointer
                )
            }
        )
        states[targetID] = state
    }

    private func makeTarget(
        targetID: String,
        url: URL,
        instance: UUID
    ) -> BrowserTarget {
        makeTarget(
            targetID: targetID,
            url: url,
            instanceToken: "ws://fake/\(targetID)/\(instance.uuidString)"
        )
    }

    private func makeTarget(
        targetID: String,
        url: URL,
        instanceToken: String
    ) -> BrowserTarget {
        BrowserTarget(
            targetID: targetID,
            instanceToken: instanceToken,
            title: "Safe computer-use benchmark - Google Chrome",
            url: url,
            webSocketURL: URL(string: instanceToken)!
        )
    }

    private func makeDocument(
        url: URL,
        loaderID: String
    ) -> BrowserDocumentObservation {
        BrowserDocumentObservation(
            loaderID: loaderID,
            title: "Safe computer-use benchmark - Google Chrome",
            url: url,
            nodes: [
                BrowserDocumentNode(
                    backendNodeID: 100,
                    role: "button",
                    name: "Mark this tab complete",
                    value: nil,
                    isDisabled: false,
                    isReadOnly: false,
                    isIgnored: false
                ),
                BrowserDocumentNode(
                    backendNodeID: 101,
                    role: "textbox",
                    name: "Editable note",
                    value: "",
                    isDisabled: false,
                    isReadOnly: false,
                    isIgnored: false
                ),            ]
        )
    }
}

import Foundation
import XCTest
@testable import Computa

final class ComputerSearchEvidenceTests: XCTestCase {
    func testSearchInputRecognitionUsesActualSemanticControlNotBodyText() {
        XCTAssertTrue(ComputerSearchEvidence.isSearchInput(role: "searchbox", label: ""))
        XCTAssertTrue(ComputerSearchEvidence.isSearchInput(role: "textField", label: "Search mail"))
        XCTAssertTrue(ComputerSearchEvidence.isSearchInput(role: "textbox", label: "Find products"))
        XCTAssertFalse(ComputerSearchEvidence.isSearchInput(role: "StaticText", label: "Search mail"))
        XCTAssertFalse(ComputerSearchEvidence.isSearchInput(role: "textbox", label: "Email body"))
        XCTAssertFalse(ComputerSearchEvidence.isSearchInput(role: "combobox", label: "Address and search bar"))
    }

    func testSuccessfulQueryFillWithoutSubmissionStillBlocksFalseFinal() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "United Flight")
        let filled = [node("input", role: "searchbox", label: "Search mail", value: "United Flight")]
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://mail.google.com/mail/u/0/#inbox"),
            elements: filled, isLive: true), .awaitingQueryRoute)
        XCTAssertNotNil(evidence.completionDiagnostic)
        XCTAssertFalse(evidence.checkpointText().contains("United"), "Durable reminders must omit private query contents.")
    }

    func testEmptyFilterAndArbitraryBodyTextNeverMeanEmptySearchResults() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "flight")
        let target = url("https://example.test/search?q=flight")
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: target, elements: [], isLive: true), .awaitingResults)
        for role in ["StaticText", "cell", "paragraph", "article"] {
            let fake = [node("scope", role: "region", label: "Search results"),
                        node("empty", parent: "scope", role: role, label: "No results found")]
            XCTAssertNotEqual(evidence.observe(targetID: "tab", documentURL: target, elements: fake, isLive: true), .queryEmptyStateObserved)
        }
    }

    func testVerifiedEmptyRequiresQueryRouteAndStructuredScopedEmptyStatus() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "flight")
        let empty = [node("scope", role: "region", label: "Search results"),
                     node("empty", parent: "scope", role: "status", label: "No results found.")]
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/search?q=other"),
            elements: empty, isLive: true), .awaitingQueryRoute)
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/search?q=flight"),
            elements: empty, isLive: false), .awaitingQueryRoute)
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/search?q=flight"),
            elements: empty, isLive: true), .queryEmptyStateObserved)
        XCTAssertNil(evidence.completionDiagnostic)
    }

    func testUnrelatedStatusUnknownAncestryAndContradictoryRecordsStayUnverified() throws {
        let scope = node("scope", role: "region", label: "Search results")
        let empty = node("empty", parent: "scope", role: "status", label: "No results found")
        for elements in [[scope, node("empty", parent: "elsewhere", role: "status", label: "No results found")],
                         [scope, node("empty", parent: "missing", role: "status", label: "No results found")],
                         [scope, empty, node("record", parent: "scope", role: "listitem", label: "Flight receipt")]] {
            var evidence = ComputerSearchEvidence()
            try evidence.beginSearch(targetID: "tab", query: "flight")
            XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?query=flight"),
                elements: elements, isLive: true), .awaitingResults)
            XCTAssertNotNil(evidence.completionDiagnostic)
        }
    }

    func testObservedResultRecordsRequireMatchingQueryAndResultScope() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "coffee grinder")
        let elements = [node("scope", role: "list", label: "Search results for coffee grinder"),
                        node("record", parent: "scope", role: "listitem", label: "Product record")]
        XCTAssertEqual(evidence.observe(targetID: "other", documentURL: url("https://shop.test/?q=coffee+grinder"),
            elements: elements, isLive: true), .notTracked)
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://shop.test/?q=coffee+grinder"),
            elements: elements, isLive: true), .queryResultsObserved)
        XCTAssertNil(evidence.completionDiagnostic)
        try evidence.beginSearch(targetID: "tab", query: "another product")
        XCTAssertNotNil(evidence.completionDiagnostic)
    }

    func testGmailAdapterOnlyRecognizesObservedQueryRouteAndNeverInfersEmpty() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "United Flight")
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://mail.google.com/mail/u/0/#search/United%20Flight"),
            elements: [], isLive: true), .awaitingResults)
        XCTAssertNotNil(evidence.completionDiagnostic)
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://mail.google.com.attacker.test/#search/United%20Flight"),
            elements: [], isLive: true), .awaitingQueryRoute)
    }

    func testAlreadyMatchingQueryStillNeedsFreshResultsAndConflictingParamsFailClosed() throws {
        var evidence = ComputerSearchEvidence()
        let route = url("https://example.test/?search=flight")
        try evidence.beginSearch(targetID: "tab", query: "flight", baselineDocumentURL: route)
        XCTAssertNotNil(evidence.completionDiagnostic)
        let elements = [node("scope", role: "feed", label: "Search results"),
                        node("record", parent: "scope", role: "article", label: "Record")]
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?q=flight&q=other"),
            elements: elements, isLive: true), .awaitingQueryRoute)
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: route, elements: elements, isLive: true), .queryResultsObserved)
    }

    func testTruncatedSourceCannotVerifyEmptyEvenWithExplicitStatus() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "flight")
        let elements = [node("scope", role: "region", label: "Search results"),
                        node("empty", parent: "scope", role: "status", label: "No results found")]
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?q=flight"),
            elements: elements, isLive: true, sourceTruncated: true), .awaitingResults)
        XCTAssertNotNil(evidence.completionDiagnostic)
    }

    func testCodableCheckpointPreservesPendingStateWithoutQueryPlaintext() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "Private Confirmation 123ABC")
        let data = try JSONEncoder().encode(evidence)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Private Confirmation"))
        XCTAssertFalse(text.contains("123ABC"))
        var restored = try JSONDecoder().decode(ComputerSearchEvidence.self, from: data)
        XCTAssertEqual(restored, evidence)
        XCTAssertNotNil(restored.completionDiagnostic)
        let elements = [node("scope", role: "region", label: "Search results for \"Private Confirmation 123ABC\""),
                        node("empty", parent: "scope", role: "status", label: "No results for Private Confirmation 123ABC")]
        XCTAssertEqual(restored.observe(targetID: "tab", documentURL: url("https://example.test/?q=Private+Confirmation+123ABC"),
            elements: elements, isLive: true), .queryEmptyStateObserved)
    }

    func testURLQueryCaseAndEncodedPlusAreNotSilentlyChanged() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "C++ API")
        let elements = [node("scope", role: "region", label: "Search results"),
                        node("empty", parent: "scope", role: "status", label: "No results found")]
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?q=C%2B%2B+api"),
            elements: elements, isLive: true), .awaitingQueryRoute)
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?q=C%2B%2B+API"),
            elements: elements, isLive: true), .queryEmptyStateObserved)
    }

    func testOriginalSemanticRolesSurviveLossyAXPresentationForResultEvidence() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "flight")
        var scope = node("scope", role: "AXGroup", label: "Search results")
        scope.semanticRole = "region"
        var empty = node("empty", parent: "scope", role: "AXGroup", label: "No results found")
        empty.semanticRole = "status"
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?q=flight"),
            elements: [scope, empty], isLive: true), .queryEmptyStateObserved)
        scope.semanticRole = nil; empty.semanticRole = nil
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?q=flight"),
            elements: [scope, empty], isLive: true), .awaitingResults,
            "A generic AXGroup must not be guessed to be a semantic status or result region.")
        XCTAssertNil(evidence.completionDiagnostic, "Losing current interface evidence does not erase the past receipt.")
    }

    func testCompleteHostHierarchyVerifiesResultsOmittedFromPublishedOverview() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "flight")
        let source = [sourceNode("root", role: "RootWebArea", children: ["scope"]),
                      sourceNode("scope", parent: "root", role: "region", name: "Search results", children: ["list"]),
                      sourceNode("list", parent: "scope", role: "list", children: ["record"]),
                      sourceNode("record", parent: "list", role: "listitem", name: "Record title", children: ["link"]),
                      sourceNode("link", parent: "record", role: "link", name: "Open record")]
        // Overview exposes only the link; its omitted result ancestry is host
        // interface evidence, not model read coverage or an action capability.
        let published = [node("link", parent: "record", role: "link", label: "Open record")]
        let snapshot = snapshot(source: source, elements: published)
        XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot), .queryResultsObserved)
        XCTAssertNil(evidence.completionDiagnostic)
        XCTAssertTrue(evidence.checkpointText().contains("not current results, current emptiness, read coverage"))
    }

    func testEmptyHostReceiptRequiresCompleteMatchingFreshCapture() throws {
        let source = emptySource()
        let published = [node("scope", role: "region", label: "Search results"),
                         node("empty", parent: "scope", role: "status", label: "No results found")]
        let invalid = [snapshot(source: source, elements: published, documentLoader: "other"),
                       snapshot(source: source, elements: published, documentLoader: "", snapshotLoader: ""),
                       snapshot(source: source, elements: published, documentURL: "https://example.test/?q=other"),
                       snapshot(source: source, elements: published, documentTruncated: true),
                       snapshot(source: source, elements: published, snapshotTruncated: true),
                       snapshot(source: nil, elements: published),
                       snapshot(source: source, elements: published, isLive: false)]
        for snapshot in invalid {
            var evidence = ComputerSearchEvidence()
            try evidence.beginSearch(targetID: "tab", query: "flight")
            XCTAssertFalse(evidence.observe(targetID: "tab", snapshot: snapshot).isVerified)
            XCTAssertNotNil(evidence.completionDiagnostic,
                "Exposed empty-state elements cannot compensate for missing complete host evidence.")
        }
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "flight")
        XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot(source: source)), .queryEmptyStateObserved)
    }

    func testHostHierarchyStillRejectsWrongQueryContradictionsAndAmbiguousAncestry() throws {
        let malformed = [[sourceNode("root", role: "RootWebArea", children: ["scope"]),
                          sourceNode("scope", parent: "root", role: "region", name: "Search results", children: ["empty", "record"]),
                          sourceNode("empty", parent: "scope", role: "status", name: "No results found"),
                          sourceNode("record", parent: "scope", role: "listitem", name: "Record")],
                         emptySource() + [sourceNode("scope", role: "region", name: "Search results")],
                         [sourceNode("scope", role: "region", name: "Search results"),
                          sourceNode("empty", parent: "missing", role: "status", name: "No results found")]]
        for source in malformed {
            var evidence = ComputerSearchEvidence()
            try evidence.beginSearch(targetID: "tab", query: "flight")
            XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot(source: source)), .awaitingResults)
            XCTAssertNotNil(evidence.completionDiagnostic)
        }
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "flight")
        XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot(source: emptySource(),
            documentURL: "https://example.test/?q=other", snapshotURL: "https://example.test/?q=other")), .awaitingQueryRoute)
        XCTAssertNotNil(evidence.completionDiagnostic)
    }

    func testIgnoredHostNodesAreOnlyAncestryLinksNotResultOrEmptyCandidates() throws {
        for candidate in [sourceNode("empty", parent: "scope", role: "status", name: "No results found", ignored: true),
                          sourceNode("record", parent: "scope", role: "listitem", name: "Record", ignored: true)] {
            var evidence = ComputerSearchEvidence()
            try evidence.beginSearch(targetID: "tab", query: "flight")
            XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot(source: [
                sourceNode("root", role: "RootWebArea", children: ["scope"]),
                sourceNode("scope", parent: "root", role: "region", name: "Search results", children: [candidate.nodeID!]),
                candidate])), .awaitingResults)
            XCTAssertNotNil(evidence.completionDiagnostic)
        }
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "flight")
        XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot(source: [
            sourceNode("root", role: "RootWebArea", children: ["scope"]),
            sourceNode("scope", parent: "root", role: "region", name: "Search results", ignored: true, children: ["empty"]),
            sourceNode("empty", parent: "scope", role: "status", name: "No results found")])), .awaitingResults)
        XCTAssertNotNil(evidence.completionDiagnostic)
        XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot(source: [
            sourceNode("root", role: "RootWebArea", children: ["scope"]),
            sourceNode("scope", parent: "root", role: "region", name: "Search results", children: ["bridge"]),
            sourceNode("bridge", parent: "scope", role: "generic", ignored: true, children: ["empty"]),
            sourceNode("empty", parent: "bridge", role: "status", name: "No results found")])), .queryEmptyStateObserved)
    }

    func testMalformedHostNodeReferencesCannotHideContradictoryResultsAndProveEmpty() throws {
        let duplicate = sourceNode("record", parent: "scope", role: "listitem", name: "Record")
        let missingID = BrowserDocumentNode(backendNodeID: nil, role: "listitem", name: "Record", value: nil,
            isDisabled: false, isReadOnly: true, isIgnored: false, parentNodeID: "scope")
        let missingChild = BrowserDocumentNode(backendNodeID: nil, role: "generic", name: "", value: nil,
            isDisabled: false, isReadOnly: true, isIgnored: false, nodeID: "branch", childNodeIDs: ["absent"])
        for extra in [[duplicate, duplicate], [missingID], [missingChild],
                      [sourceNode("record", parent: "absent", role: "listitem", name: "Record")],
                      [sourceNode("", parent: "scope", role: "listitem", name: "Record")]] {
            var evidence = ComputerSearchEvidence()
            try evidence.beginSearch(targetID: "tab", query: "flight")
            XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot(source: emptySource() + extra)), .awaitingResults)
            XCTAssertNotNil(evidence.completionDiagnostic)
        }
    }

    func testDisconnectedCyclesAndNonreciprocalHostEdgesCannotProveEmpty() throws {
        let disconnected = emptySource() + [sourceNode("extra-root", role: "RootWebArea", children: ["record"]),
            sourceNode("record", parent: "extra-root", role: "listitem", name: "Record")]
        let cyclic = emptySource() + [sourceNode("branch", parent: "record", role: "list", children: ["record"]),
            sourceNode("record", parent: "branch", role: "listitem", name: "Record", children: ["branch"])]
        let nonreciprocal = emptySource() + [sourceNode("record", parent: "scope", role: "listitem", name: "Record")]
        let conflictingEdge = [sourceNode("root", role: "RootWebArea", children: ["scope", "record"]),
            sourceNode("scope", parent: "root", role: "region", name: "Search results", children: ["empty", "record"]),
            sourceNode("empty", parent: "scope", role: "status", name: "No results found"),
            sourceNode("record", parent: "root", role: "listitem", name: "Record")]
        var deep = [sourceNode("root", role: "RootWebArea", children: ["scope"]),
            sourceNode("scope", parent: "root", role: "region", name: "Search results", children: ["empty", "branch0"]),
            sourceNode("empty", parent: "scope", role: "status", name: "No results found")]
        for index in 0..<64 {
            deep.append(sourceNode("branch\(index)", parent: index == 0 ? "scope" : "branch\(index - 1)",
                role: "generic", children: [index == 63 ? "record" : "branch\(index + 1)"]))
        }
        deep.append(sourceNode("record", parent: "branch63", role: "listitem", name: "Record"))
        for source in [disconnected, cyclic, nonreciprocal, conflictingEdge, deep] {
            var evidence = ComputerSearchEvidence()
            try evidence.beginSearch(targetID: "tab", query: "flight")
            XCTAssertEqual(evidence.observe(targetID: "tab", snapshot: snapshot(source: source)), .awaitingResults)
            XCTAssertNotNil(evidence.completionDiagnostic)
        }
    }

    func testHistoricalResultAndEmptyReceiptsSurviveDetailNavigationUntilNewSearch() throws {
        for result in [node("record", parent: "scope", role: "listitem", label: "Record"),
                       node("empty", parent: "scope", role: "status", label: "No results found")] {
            var evidence = ComputerSearchEvidence()
            try evidence.beginSearch(targetID: "tab", query: "flight")
            XCTAssertTrue(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?q=flight"),
                elements: [node("scope", role: "region", label: "Search results"), result], isLive: true).isVerified)
            XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/record/123"),
                elements: [], isLive: true), .awaitingQueryRoute,
                "The current detail page must not be described as a results or empty-results interface.")
            XCTAssertNil(evidence.completionDiagnostic, "Navigation must preserve proof that the requested search ran.")
            XCTAssertTrue(evidence.checkpointText().contains("historical_receipts=1"))
            XCTAssertEqual(evidence.observe(targetID: "different-scope", documentURL: url("https://example.test/?q=flight"),
                elements: [], isLive: true), .notTracked)
            try evidence.beginSearch(targetID: "different-scope", query: "flight")
            XCTAssertNotNil(evidence.completionDiagnostic, "A new target scope cannot inherit another scope's receipt.")
            // Even the same entered query starts a new search attempt.
            try evidence.beginSearch(targetID: "tab", query: "flight")
            XCTAssertTrue(evidence.checkpointText().contains("historical_receipts=0"))
            XCTAssertNotNil(evidence.completionDiagnostic)
        }
    }

    func testHistoricalReceiptsRestorePrivatelyAndLegacyVerifiedStatusMigrates() throws {
        var evidence = ComputerSearchEvidence()
        try evidence.beginSearch(targetID: "tab", query: "Private Receipt 123ABC")
        let observed = [node("scope", role: "region", label: "Search results"),
                        node("record", parent: "scope", role: "listitem", label: "Private record body")]
        XCTAssertEqual(evidence.observe(targetID: "tab", documentURL: url("https://example.test/?q=Private+Receipt+123ABC"),
            elements: observed, isLive: true), .queryResultsObserved)
        let data = try JSONEncoder().encode(evidence)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var searches = try XCTUnwrap(legacy["searches"] as? [String: [String: Any]])
        searches["tab"]?.removeValue(forKey: "historicalReceipt")
        legacy["searches"] = searches
        for checkpoint in [data, try JSONSerialization.data(withJSONObject: legacy)] {
            var restored = try JSONDecoder().decode(ComputerSearchEvidence.self, from: checkpoint)
            XCTAssertNil(restored.completionDiagnostic)
            XCTAssertEqual(restored.observe(targetID: "tab", documentURL: url("https://example.test/detail"),
                elements: [], isLive: true), .awaitingQueryRoute)
            XCTAssertNil(restored.completionDiagnostic)
            let saved = try JSONEncoder().encode(restored)
            let text = try XCTUnwrap(String(data: saved, encoding: .utf8))
            for privateText in ["Private", "123ABC", "example.test", "record body"] {
                XCTAssertFalse(text.contains(privateText))
                XCTAssertFalse(restored.checkpointText().contains(privateText))
            }
            let again = try JSONDecoder().decode(ComputerSearchEvidence.self, from: saved)
            XCTAssertEqual(again, restored)
            XCTAssertNil(again.completionDiagnostic)
            try restored.beginSearch(targetID: "tab", query: "different query")
            XCTAssertNotNil(restored.completionDiagnostic)
        }
    }

    private func url(_ value: String) -> URL { URL(string: value)! }

    private func snapshot(source: [BrowserDocumentNode]?, elements: [BrowserTabElement] = [],
                          documentLoader: String = "loader", snapshotLoader: String = "loader",
                          documentURL: String = "https://example.test/?q=flight",
                          snapshotURL: String = "https://example.test/?q=flight",
                          documentTruncated: Bool = false, snapshotTruncated: Bool = false,
                          isLive: Bool = true) -> BrowserTabSnapshot {
        BrowserTabSnapshot(id: UUID(), tabHandle: UUID(), documentEpoch: UUID(),
            loaderID: snapshotLoader, documentURL: url(snapshotURL), elements: elements,
            formattedText: "", sourceTruncated: snapshotTruncated, isLiveObservation: isLive,
            evidenceDocument: source.map { BrowserDocumentObservation(loaderID: documentLoader,
                title: "", url: url(documentURL), nodes: $0, sourceTruncated: documentTruncated) })
    }

    private func sourceNode(_ id: String, parent: String? = nil, role: String, name: String = "",
                            ignored: Bool = false, children: [String] = []) -> BrowserDocumentNode {
        BrowserDocumentNode(backendNodeID: nil, role: role, name: name, value: nil,
            isDisabled: false, isReadOnly: true, isIgnored: ignored, nodeID: id, parentNodeID: parent, childNodeIDs: children)
    }

    private func emptySource() -> [BrowserDocumentNode] {
        [sourceNode("root", role: "RootWebArea", children: ["scope"]),
         sourceNode("scope", parent: "root", role: "region", name: "Search results", children: ["empty"]),
         sourceNode("empty", parent: "scope", role: "status", name: "No results found")]
    }

    private func node(_ id: String, parent: String? = nil, role: String, label: String, value: String? = nil) -> BrowserTabElement {
        BrowserTabElement(index: 0, backendNodeID: Int64(id.utf8.reduce(0) { $0 + Int($1) }), role: role,
            label: label, value: value, isEnabled: true, supportsPress: false, supportsSetText: false,
            nodeID: id, parentNodeID: parent)
    }
}

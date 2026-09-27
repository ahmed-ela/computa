import Foundation
import XCTest
@testable import Mactopus

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
    }

    private func url(_ value: String) -> URL { URL(string: value)! }

    private func node(_ id: String, parent: String? = nil, role: String, label: String, value: String? = nil) -> BrowserTabElement {
        BrowserTabElement(index: 0, backendNodeID: Int64(id.utf8.reduce(0) { $0 + Int($1) }), role: role,
            label: label, value: value, isEnabled: true, supportsPress: false, supportsSetText: false,
            nodeID: id, parentNodeID: parent)
    }
}

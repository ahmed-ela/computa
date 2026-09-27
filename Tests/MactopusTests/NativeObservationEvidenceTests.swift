@testable import AutomationCore
import Foundation
import XCTest
@testable import Mactopus

final class NativeObservationEvidenceTests: XCTestCase {
    func testReorderingPreservesStableControlPropertyButNeverReusesAnArrayIndex() throws {
        let before = snapshot([element(0, role: "AXWindow"), element(1, parent: 0, id: "one", value: "before"),
                               element(2, parent: 0, id: "two", value: "other")])
        let after = snapshot([element(0, role: "AXWindow"), element(1, parent: 0, id: "two", value: "wrong"),
                              element(2, parent: 0, id: "one", value: "after")])
        let key = try NativeObservationEvidence.canonicalProperty(snapshot: before, exposedIndices: [1], index: 1, field: "value")
        XCTAssertEqual(key, try NativeObservationEvidence.canonicalProperty(snapshot: after, exposedIndices: [2], index: 2, field: "value"))
        XCTAssertNotEqual(key, try NativeObservationEvidence.canonicalProperty(snapshot: after, exposedIndices: [1], index: 1, field: "value"))
        XCTAssertEqual(NativeObservationEvidence.properties(snapshot: after, exposedIndices: [1, 2])[key], "after")
    }

    func testMissingOrDuplicatedIdentityCannotVerifyEvenIfTextMatches() throws {
        for elements in [
            [element(0, role: "AXWindow"), element(1, parent: 0, value: "success")],
            [element(0, role: "AXWindow", id: "shared"), element(1, parent: 0, id: "shared", value: "success")],
        ] {
            let source = snapshot(elements)
            XCTAssertThrowsError(try NativeObservationEvidence.canonicalProperty(snapshot: source, exposedIndices: [1], index: 1, field: "value"))
            XCTAssertTrue(NativeObservationEvidence.properties(snapshot: source, exposedIndices: [1]).isEmpty)
        }
    }

    func testDocumentURLScopesOtherwiseIdenticalControlIdentity() throws {
        let before = snapshot([element(0, role: "AXWebArea", url: "https://example.test/one"),
                               element(1, parent: 0, id: "search", value: "one")])
        let after = snapshot([element(0, role: "AXWebArea", url: "https://example.test/two"),
                              element(1, parent: 0, id: "search", value: "two")])
        let key = try NativeObservationEvidence.canonicalProperty(snapshot: before, exposedIndices: [1], index: 1, field: "value")
        XCTAssertNil(NativeObservationEvidence.properties(snapshot: after, exposedIndices: [1])[key])
        let missingURL = snapshot([element(0, role: "AXWebArea"), element(1, parent: 0, id: "search", value: "two")])
        XCTAssertThrowsError(try NativeObservationEvidence.canonicalProperty(snapshot: missingURL, exposedIndices: [1], index: 1, field: "value"))
    }

    func testUnknownOrCyclicAncestryCannotClaimSameDocument() {
        for elements in [[element(0, parent: 0, id: "cycle", value: "x")],
                         [element(0, parent: 10, id: "missing", value: "x")]] {
            XCTAssertTrue(NativeObservationEvidence.properties(snapshot: snapshot(elements), exposedIndices: [0]).isEmpty)
        }
    }

    func testAbsentValueIsNotFabricatedAndUnexposedElementCannotBeResolved() throws {
        let source = snapshot([element(0, role: "AXWindow"), element(1, parent: 0, id: "button")])
        XCTAssertThrowsError(try NativeObservationEvidence.canonicalProperty(snapshot: source, exposedIndices: [1], index: 1, field: "value"))
        XCTAssertThrowsError(try NativeObservationEvidence.canonicalProperty(snapshot: source, exposedIndices: [], index: 1, field: "text"))
        XCTAssertTrue(NativeObservationEvidence.properties(snapshot: source, exposedIndices: []).isEmpty)
    }

    private func element(_ index: Int, parent: Int? = nil, role: String = "AXTextField", id: String? = nil,
                         value: String? = nil, url: String? = nil) -> AccessibilityTreeElement {
        AccessibilityTreeElement(index: index, parentIndex: parent, childIndices: [], depth: parent == nil ? 0 : 1,
            role: role, subrole: nil, title: "Observed title", elementDescription: nil, help: nil,
            identifier: id, domIdentifier: nil, value: value, frame: nil, isEnabled: true, isFocused: false,
            supportedActions: [], isValueSettable: false, url: url)
    }

    private func snapshot(_ elements: [AccessibilityTreeElement]) -> AccessibilityTreeSnapshot {
        AccessibilityTreeSnapshot(id: UUID(), application: AccessibilityApplicationTarget(processIdentifier: 123,
            bundleIdentifier: "test.fixture"), limits: .agentDefault, rootIndex: 0, elements: elements, wasTruncated: false)
    }
}

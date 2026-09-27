import Foundation
import XCTest
@testable import Mactopus

final class ComputerExecutionSafetyTests: XCTestCase {
    func testInventoryCursorOrPageSizeChangesCannotResetRetryIdentity() {
        let first = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_tabs", arguments: ["cursor": UUID().uuidString])
        for size in [1, 25, 100] {
            XCTAssertEqual(first, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_tabs",
                arguments: ["cursor": UUID().uuidString, "page_size": size]))
        }
    }
    func testVerificationAcceptsOnlyFiniteObservedPropertyContract() throws {
        var arguments = fixture()
        let value = try ComputerOutcomeToolContract.validate(arguments)
        XCTAssertEqual(value.operationID, "action-1")
        XCTAssertEqual(value.property, "element:7:value")
        XCTAssertEqual(value.expected, "requested query")
        arguments["property"] = "document_url"
        arguments.removeValue(forKey: "element_index")
        arguments["expected"] = "https://example.test/results"
        XCTAssertEqual(try ComputerOutcomeToolContract.validate(arguments).property, "document_url")
    }

    func testModelBooleanCannotDeclareVerificationOrWholeTaskSuccess() throws {
        for injected in ["verified", "success", "task_complete", "empty_result"] {
            var arguments = fixture()
            arguments[injected] = true
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        }
        var arguments = fixture()
        arguments["property"] = "task_complete"
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        arguments = fixture()
        arguments["expected"] = true
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
    }

    func testElementIndexRejectsBooleansFractionsAndNonfiniteValues() throws {
        let invalid: [Any] = [true, false, "7", -1, 1.25, Double.infinity, Double.nan, NSNull()]
        for index in invalid {
            var arguments = fixture()
            arguments["element_index"] = index
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments), "Rejected index: \(index)")
        }
        var arguments = fixture()
        arguments.removeValue(forKey: "element_index")
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        arguments = fixture()
        arguments["property"] = "document_url"
        XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
    }

    func testMissingAndMalformedReferencesOrExpectationsFailClosed() throws {
        for field in ["operation_id", "snapshot_id", "property", "expected"] {
            var arguments = fixture()
            arguments.removeValue(forKey: field)
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        }
        for expected in ["", " \n\t", String(repeating: "x", count: 2_049)] {
            var arguments = fixture()
            arguments["expected"] = expected
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        }
        for snapshot in ["", "made-up", "1"] {
            var arguments = fixture()
            arguments["snapshot_id"] = snapshot
            XCTAssertThrowsError(try ComputerOutcomeToolContract.validate(arguments))
        }
    }

    func testPublishedSchemaRejectsAdditionalPropertiesAndHasNoSuccessFlag() throws {
        XCTAssertEqual(ComputerOutcomeToolContract.spec["type"] as? String, "function")
        XCTAssertTrue(ComputerV2ToolContract.specs.allSatisfy { $0["type"] as? String == ComputerOutcomeToolContract.spec["type"] as? String }, "Bundled App Server rejects mixed canonical and legacy tool declarations.")
        let schema = try XCTUnwrap(ComputerOutcomeToolContract.spec["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["operation_id", "snapshot_id", "property", "element_index", "expected"])
        XCTAssertEqual(ComputerOutcomeToolContract.name, "computer_v2_verify")
    }

    func testChangingOpaqueCapabilitiesDoesNotResetRetryBudget() {
        let one = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: [
            "snapshot_id": "one", "capture_id": "capture-one", "candidate_token": "candidate-one", "cursor": "page-one",
            "element_index": 7, "text": "requested query",
        ])
        let two = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: [
            "snapshot_id": "two", "capture_id": "capture-two", "candidate_token": "candidate-two", "cursor": "page-two",
            "element_index": 7, "text": "requested query",
        ])
        XCTAssertEqual(one, two)
        var guardrail = ComputerUnchangedAttemptGuard()
        XCTAssertFalse(guardrail.failed(key: one))
        XCTAssertFalse(guardrail.failed(key: two))
        XCTAssertTrue(guardrail.failed(key: one))
    }

    func testActionAndTextRemainPartOfRetryIdentity() {
        let base: [String: Any] = ["snapshot_id": "one", "element_index": 7, "text": "snapshot_id=literal user text"]
        let key = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: base)
        var differentText = base
        differentText["text"] = "another query"
        XCTAssertNotEqual(key, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: differentText))
        XCTAssertNotEqual(key, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_ax", arguments: base))
        XCTAssertTrue(key.contains("snapshot_id=literal user text"))
    }

    func testObservedStableControlIdentitySurvivesSnapshotReindexing() {
        let first: [String: Any] = ["snapshot_id": "one", "element_index": 7, "text": "query"]
        let later: [String: Any] = ["snapshot_id": "two", "element_index": 22, "text": "query"]
        let key = ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: first, observedElementIdentity: "node:50")
        XCTAssertEqual(key, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: later, observedElementIdentity: "node:50"))
        XCTAssertNotEqual(key, ComputerUnchangedAttemptGuard.key(tool: "computer_v2_set_text", arguments: later, observedElementIdentity: "node:51"))
    }

    func testOnlySuccessfulMatchingOperationResetsItsRetryBudget() {
        var guardrail = ComputerUnchangedAttemptGuard()
        XCTAssertFalse(guardrail.failed(key: "failed-input"))
        XCTAssertFalse(guardrail.failed(key: "failed-input"))
        guardrail.succeeded(key: "unrelated-snapshot")
        XCTAssertTrue(guardrail.failed(key: "failed-input"))
        guardrail.succeeded(key: "failed-input")
        XCTAssertFalse(guardrail.failed(key: "failed-input"))
    }

    private func fixture() -> [String: Any] {
        ["operation_id": "action-1", "snapshot_id": "D56814BA-CF94-44BB-938F-1008A315D982",
         "property": "value", "element_index": 7, "expected": "requested query"]
    }
}

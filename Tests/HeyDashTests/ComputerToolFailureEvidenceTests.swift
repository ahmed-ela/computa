import AutomationCore
import Foundation
import XCTest
@testable import HeyDash

final class ComputerToolFailureEvidenceTests: XCTestCase {
    func testMissingPointerFieldsExplainTheWholeContractWithoutInventingCoordinates() {
        for field in ["x", "y", "capture_id", "delta_x", "delta_y"] {
            let error = ComputerV2ToolContract.ValidationError.missing(field)
            let message = ComputerToolFailureEvidence.text(for: error, tool: "computer_v2_pointer")
            XCTAssertTrue(message.hasPrefix(error.localizedDescription))
            XCTAssertTrue(message.contains("No input was dispatched"))
            XCTAssertTrue(message.contains("capture_id, x, y; scroll also requires delta_x, delta_y"))
            XCTAssertTrue(message.contains("fresh screenshot"))
            XCTAssertTrue(message.contains("computer_v2_snapshot(query="))
            XCTAssertLessThan(message.utf8.count, 600)
            XCTAssertEqual(ComputerToolFailureEvidence.text(for: error, tool: "computer_v2_click"), error.localizedDescription)
            XCTAssertNil(ComputerToolFailureEvidence.terminalMessage(for: error))
        }
        let denial = AutomationError.permissionNotGranted(.accessibility)
        XCTAssertEqual(ComputerToolFailureEvidence.text(for: denial, tool: "computer_v2_pointer"), denial.localizedDescription)
    }

    func testActivationFailureCarriesOnlyMeasuredFactsAndUnknownCause() throws {
        let error = ComputerInputError.applicationActivationFailed(processIdentifier: 1234)
        let text = ComputerToolFailureEvidence.text(for: error)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(value["type"] as? String, "native_tool_failure")
        let diagnostic = try XCTUnwrap(value["error"] as? [String: String])
        XCTAssertEqual(diagnostic["code"], "application_activation_failed")
        XCTAssertEqual(diagnostic["message"], error.localizedDescription)
        XCTAssertEqual(value["process_id"] as? Int, 1234)
        XCTAssertEqual(value["cause"] as? String, "undetermined")
        XCTAssertEqual(value["website_status"] as? String, "not_observed")
        XCTAssertEqual(value["action_outcome"] as? String, "not_confirmed")
        XCTAssertNil(value["http_status"])
        XCTAssertNil(value["policy_name"])
        XCTAssertFalse(text.contains("StudyLock"))
        XCTAssertTrue((value["next_step"] as? String)?.contains("Do not retry this failed action") == true)
        XCTAssertLessThan(text.utf8.count, 1_024)
    }

    func testRealPermissionDenialsAndOtherFailuresAreNotReinterpretedOrHidden() {
        let errors: [Error] = [
            AutomationError.permissionNotGranted(.accessibility),
            ComputerInputError.applicationProcessNotFound(processIdentifier: 1234),
            NSError(domain: "ObservedPolicyDiagnostic", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Explicit policy denial from the inspected page."]),
        ]
        for error in errors {
            XCTAssertEqual(ComputerToolFailureEvidence.text(for: error), error.localizedDescription)
            XCTAssertNil(ComputerToolFailureEvidence.terminalMessage(for: error))
        }
    }

    func testTerminalMessageUsesExactNativeProcessAndUnknownCauseWithoutModelAuthorship() {
        let error = ComputerInputError.applicationActivationFailed(processIdentifier: 52339)
        XCTAssertEqual(ComputerToolFailureEvidence.terminalMessage(for: error),
            error.localizedDescription + " The cause is unknown. Further computer actions are blocked for this turn. "
                + "Bring the intended app to the foreground, then try again.")
        XCTAssertFalse(ComputerToolFailureEvidence.terminalMessage(for: error)?.contains("StudyLock") == true)
    }

    func testInstructionsRequireEvidenceInBothAnswersAndCompactionSummaries() {
        let instructions = CodexAppServerRuntime.Configuration.localQwen.baseInstructions
        XCTAssertTrue(instructions.contains("Replies/summaries"))
        XCTAssertTrue(instructions.contains("raw results beat guesses"))
        XCTAssertTrue(instructions.contains("StudyLock's allowed-work list is ONLY for work on StudyLock enforcement"))
        XCTAssertTrue(instructions.contains("Harmless text generation and unrelated read-only browser tasks are allowed"))
        XCTAssertTrue(instructions.contains("Never weaken enforcement"))
        XCTAssertTrue(instructions.contains("policy isn't block proof"))
        XCTAssertTrue(instructions.contains("Keep unknowns; don't exclude unobserved causes"))
        XCTAssertLessThan(instructions.utf8.count, 1_024)
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        XCTAssertEqual(configuration.workspacePath,
                       AgentRuntimeIsolation.workspaceURL(codexHomePath: configuration.codexHomePath).path)
    }
}

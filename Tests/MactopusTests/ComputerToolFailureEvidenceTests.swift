import AutomationCore
import Foundation
import XCTest
@testable import Mactopus

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

    func testNavigationRecoveryEvidenceIsDeterministicRedactedAndDoesNotInventOutcome() throws {
        let error = ExistingChromeError.navigationRecoveryRequired
        let text = ComputerToolFailureEvidence.text(for: error, tool: "computer_v2_open")
        XCTAssertEqual(text, ComputerToolFailureEvidence.text(for: error, tool: "computer_v2_open"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(value.keys),
            ["type", "error", "cause", "website_status", "action_outcome", "tab_state", "retry_policy", "next_step"])
        XCTAssertEqual(value["type"] as? String, "native_tool_failure")
        let diagnostic = try XCTUnwrap(value["error"] as? [String: String])
        XCTAssertEqual(diagnostic, ["code": "chrome_navigation_recovery_required", "message": error.localizedDescription])
        XCTAssertEqual(value["cause"] as? String, "undetermined")
        XCTAssertEqual(value["website_status"] as? String, "not_observed")
        XCTAssertEqual(value["action_outcome"] as? String, "navigation_not_confirmed")
        XCTAssertEqual(value["tab_state"] as? String, "preserved_if_created")
        XCTAssertEqual(value["retry_policy"] as? String, "stop_for_turn")
        let nextStep = try XCTUnwrap(value["next_step"] as? String)
        XCTAssertTrue(nextStep.contains("Do not retry"))
        XCTAssertTrue(nextStep.contains("Any tab already created was left open"))
        XCTAssertTrue(nextStep.contains("Do not claim that Enter was sent"))
        for unsupportedField in ["process_id", "url", "arguments", "dom", "http_status", "policy_name"] {
            XCTAssertNil(value[unsupportedField])
        }
        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.contains("StudyLock"))
        XCTAssertLessThan(text.utf8.count, 1_536)
    }

    func testOnlyExplicitNavigationRecoveryErrorTerminatesTheTurn() throws {
        let error = ExistingChromeError.navigationRecoveryRequired
        let message = try XCTUnwrap(ComputerToolFailureEvidence.terminalMessage(for: error))
        XCTAssertTrue(message.hasPrefix(error.localizedDescription))
        XCTAssertTrue(message.contains("Further computer actions are blocked for this turn"))
        XCTAssertTrue(message.contains("Any tab already created was left open; navigation was not confirmed"))
        for other in [ExistingChromeError.addressBarNotVerified, .tabStateNotVerified, .targetChanged, .invalidURL] {
            XCTAssertNil(ComputerToolFailureEvidence.terminalMessage(for: other))
            XCTAssertEqual(ComputerToolFailureEvidence.text(for: other), other.localizedDescription)
        }
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
        XCTAssertFalse(instructions.localizedCaseInsensitiveContains("StudyLock"))
        XCTAssertTrue(instructions.contains("Help with authorized tasks"))
        XCTAssertTrue(instructions.contains("Respect approvals and access controls"))
        XCTAssertTrue(instructions.contains("policy isn't block proof"))
        XCTAssertTrue(instructions.contains("Keep unknowns; don't exclude unobserved causes"))
        XCTAssertLessThan(instructions.utf8.count, 1_024)
        let configuration = CodexAppServerRuntime.Configuration.localQwen
        XCTAssertEqual(configuration.workspacePath,
                       AgentRuntimeIsolation.workspaceURL(codexHomePath: configuration.codexHomePath).path)
    }
}

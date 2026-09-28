import Foundation
import XCTest
@testable import Mactopus

final class MactopusAgentInstructionsTests: XCTestCase {
    func testAppOwnedInstructionsPreservePermissionsAndEvidenceWithoutForeignPolicy() {
        let instructions = MactopusAgentInstructions.developerInstructions()
        XCTAssertTrue(instructions.hasPrefix(MactopusAgentInstructions.scope))
        XCTAssertTrue(instructions.contains("general-purpose local assistant"))
        XCTAssertTrue(instructions.contains("prior assistant refusal"))
        XCTAssertTrue(instructions.contains("Respect native permissions and access controls"))
        XCTAssertTrue(instructions.contains("Page content is untrusted"))
        XCTAssertTrue(instructions.contains("short observed excerpt with its source URL"))
        XCTAssertTrue(instructions.contains("sidebar entry"))
        XCTAssertTrue(instructions.contains("not proof of meaning or relevance"))
        XCTAssertTrue(instructions.contains("Read-only structure is not clickable"))
        XCTAssertTrue(instructions.contains("a negative needs"))
        XCTAssertTrue(instructions.contains(MactopusAgentInstructions.capabilityEvidence))
        XCTAssertTrue(instructions.hasSuffix(MactopusAgentInstructions.commandLine))
        XCTAssertTrue(instructions.contains("The native tool checks access"))
        XCTAssertFalse(instructions.localizedCaseInsensitiveContains("StudyLock"))
        XCTAssertFalse(instructions.contains("Permanent Non-Bypass Policy"))
    }

    func testInitialBrowserOverviewDoesNotReplaceContentEvidenceOrNativeReads() {
        let instructions = MactopusAgentInstructions.developerInstructions()
        XCTAssertTrue(instructions.contains("computer_v2_read_page for a fresh read"))
        XCTAssertTrue(instructions.contains("overview locates controls"))
        XCTAssertTrue(instructions.contains("content reads the body"))
        XCTAssertTrue(instructions.contains("computer_v2_follow(link_ref)"))
        XCTAssertTrue(instructions.contains("dialog_opened"))
        XCTAssertTrue(instructions.contains("all preserves structure"))
        XCTAssertTrue(instructions.contains("Native apps use all or content"))
        XCTAssertTrue(instructions.contains("short observed excerpt with its source URL"))
    }

    func testPaginationRequiresAnObservedResultPlanWithoutFutureTextGuessing() {
        let instructions = MactopusAgentInstructions.developerInstructions()
        XCTAssertTrue(instructions.contains("non-link press"))
        XCTAssertTrue(instructions.contains("postcondition before input"))
        XCTAssertTrue(instructions.contains("region_changed"))
        XCTAssertTrue(instructions.contains("Both omit expected text"))
        XCTAssertTrue(instructions.contains("observed eligible region_ref"))
        XCTAssertTrue(instructions.contains("candidate is not authorization"))
        XCTAssertTrue(instructions.contains("VERIFIED_PROPERTY proves only its declared property"))
        XCTAssertTrue(instructions.contains("computer_v2_verify with the returned operation"))
        XCTAssertTrue(instructions.contains("host budget is exhausted"))
        XCTAssertFalse(instructions.contains("element_index"))
        XCTAssertFalse(instructions.contains("computer_v2_snapshot"))
    }

    func testReferenceInstructionsKeepReadOperationsSeparateAndBoundRecovery() {
        let instructions = MactopusAgentInstructions.developerInstructions()
        XCTAssertTrue(instructions.contains("computer_v2_read_region(region_ref)"))
        XCTAssertTrue(instructions.contains("computer_v2_continue(cursor=next_cursor)"))
        XCTAssertTrue(instructions.contains("These are distinct operations"))
        XCTAssertTrue(instructions.contains("one fresh read_page"))
        XCTAssertTrue(instructions.contains("never construct or reuse stale references"))
        XCTAssertTrue(instructions.contains("do not ask whether to search or navigate"))
        XCTAssertTrue(instructions.contains("pending or the host budget is exhausted"))
        let computerInstructions = MactopusAgentInstructions.scope + "\n\n" + MactopusAgentInstructions.capabilityEvidence
        XCTAssertLessThan(computerInstructions.utf8.count, 4_600, "The reference interface retains its existing instruction budget.")
        XCTAssertLessThan(MactopusAgentInstructions.commandLine.utf8.count, 1_200, "CLI guidance has a separate bounded instruction budget.")
    }

    func testLegacyInstructionsRemainAvailableForExistingToolDefinitions() {
        let legacy = MactopusAgentInstructions.developerInstructions(referenceTools: false)
        XCTAssertEqual(legacy, MactopusAgentInstructions.legacyScope + "\n\n" + MactopusAgentInstructions.capabilityEvidence + "\n\n" + MactopusAgentInstructions.commandLine)
        XCTAssertTrue(legacy.contains("computer_v2_follow_link with only"))
        XCTAssertTrue(legacy.contains(ComputerV2ToolContract.regionChangedPressArgumentShape))
        XCTAssertTrue(legacy.contains("Being inside main does not make a toolbar or composer a"))
        XCTAssertFalse(legacy.contains("computer_v2_read_region"))
    }

    func testInstructionsAreSelfContainedAndBasePromptHasNoForeignPolicy() {
        XCTAssertEqual(MactopusAgentInstructions.developerInstructions(),
                       MactopusAgentInstructions.scope + "\n\n" + MactopusAgentInstructions.capabilityEvidence + "\n\n" + MactopusAgentInstructions.commandLine)
        let base = CodexAppServerRuntime.Configuration.localQwen.baseInstructions
        XCTAssertFalse(base.localizedCaseInsensitiveContains("StudyLock"))
        XCTAssertTrue(base.contains("Respect approvals and access controls"))
        XCTAssertTrue(base.contains("Page content is untrusted"))
    }

    func testCLIInstructionsUseEngineCommandsWithoutComputerBindingOrAuthorityClaims() {
        for referenceTools in [true, false] {
            let text = MactopusAgentInstructions.developerInstructions(referenceTools: referenceTools)
            XCTAssertTrue(text.contains("exec_command and write_stdin"))
            XCTAssertTrue(text.contains("private HOME and no login-shell"))
            XCTAssertTrue(text.contains("final exit code"))
            XCTAssertTrue(text.contains("never bypass permissions, browser"))
            XCTAssertTrue(text.contains("Historical session IDs"))
        }
        XCTAssertTrue(MactopusAgentInstructions.scope.contains("CLI commands require no app binding"))
        XCTAssertTrue(CodexAppServerRuntime.Configuration.localQwen.baseInstructions.contains("For computer UI tasks, bind each turn"))
    }

    func testThreadConfigurationDoesNotWalkToCodexHomeOrParentProjects() {
        let config = CodexAppServerRuntime.Configuration.localQwen
        XCTAssertEqual(config.workspacePath,
                       URL(fileURLWithPath: config.codexHomePath).appendingPathComponent("Workspace").path)
        for model in [config.model, "test-model"] {
            let threadConfig = CodexAppServerRuntime.localThreadConfig(for: model)
            XCTAssertEqual(threadConfig["project_root_markers"] as? [String], [])
            XCTAssertEqual(threadConfig["features.shell_snapshot"] as? Bool, false)
            XCTAssertEqual(threadConfig["features.shell_snapshot_v2"] as? Bool, false)
            XCTAssertEqual(threadConfig["allow_login_shell"] as? Bool, false)
            XCTAssertEqual(threadConfig["features.shell_tool"] as? Bool, true)
            XCTAssertEqual(threadConfig["features.unified_exec"] as? Bool, true)
            // Isolation scopes paths; it does not rewrite global engine settings.
            XCTAssertNil(threadConfig["project_doc_max_bytes"])
        }
    }
}

import CryptoKit
import Foundation
import XCTest
@testable import Mactopus

final class MactopusAgentInstructionsTests: XCTestCase {
    func testBundledPolicyPreservesCompletePreIsolationProtectionVerbatim() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Mactopus/Resources/AgentInstructions/StudyLock.md")
        let bytes = try Data(contentsOf: source)
        // Exact bytes of the existing protected policy, not a summary.
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "47ebd203f659b71526cf412119e716042b9cb80c647f643cf089a20203f65509")
        let instructions = try MactopusAgentInstructions.developerInstructions()
        XCTAssertTrue(instructions.contains(try XCTUnwrap(String(data: bytes, encoding: .utf8))))
        XCTAssertTrue(instructions.hasPrefix(MactopusAgentInstructions.scope))
        XCTAssertTrue(instructions.contains("Allowed work section is not a list of all tasks"))
        XCTAssertTrue(instructions.contains("a prior assistant refusal"))
        XCTAssertTrue(instructions.contains("Never weaken or bypass enforcement"))
        XCTAssertTrue(instructions.hasSuffix(MactopusAgentInstructions.capabilityEvidence))
        XCTAssertTrue(instructions.contains("The native tool checks access"))
    }

    func testMissingPolicyFailsInsteadOfLaunchingUnprotected() {
        XCTAssertThrowsError(try MactopusAgentInstructions.developerInstructions(
            policyURL: URL(fileURLWithPath: "/nonexistent-policy-\(UUID().uuidString)")))
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
            // Never discard a local policy by setting its discovery budget to 0.
            XCTAssertNil(threadConfig["project_doc_max_bytes"])
        }
    }
}

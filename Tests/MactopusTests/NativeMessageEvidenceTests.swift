import XCTest
@testable import Mactopus

final class NativeMessageEvidenceTests: XCTestCase {
    func testGenericIncomingIntentRequiresLatestBoundaryProof() {
        for prompt in [
            "Read my latest incoming message.",
            "What is the last email I received?",
            "Find the most recent text from the project coordinator.",
            "Show the newest message they sent me.",
            "What's the last communication sent to us?",
            "What was the most recent DM from another person?",
            "Read the latest e-mail from the vendor.",
            "Find the LAST MESSAGE FROM someone in the conversation.",
            "Compare my last sent message with the latest incoming message.",
        ] {
            XCTAssertTrue(NativeMessageEvidence(prompt: prompt).requiresLatestIncoming, prompt)
        }
    }

    func testOutgoingOnlyGeneralReadAndUnrelatedLatestDoNotActivateGate() {
        for prompt in [
            "Read my last outgoing message.",
            "What is the latest email I sent?",
            "Read the last message from me.",
            "Show the last message from myself.",
            "Show the last message from us.",
            "Read the selected conversation.",
            "Find a message from the project coordinator.",
            "Open the latest file and read its text.",
            "What is the latest status from the project coordinator?",
            "Read the current message.",
        ] {
            XCTAssertFalse(NativeMessageEvidence(prompt: prompt).requiresLatestIncoming, prompt)
        }
    }

    func testRequirementDoesNotGateBrowserOrNonComputerAnswer() {
        let evidence = NativeMessageEvidence(prompt: "Read the latest incoming message.")
        XCTAssertTrue(evidence.requiresLatestIncoming)
        XCTAssertFalse(evidence.observedNativeRead)
        XCTAssertNil(evidence.completionDiagnostic, "Only the runtime's actual native read activates this conservative gate.")
    }

    func testRawNativeReadCannotCertifyLatestIncomingMetadata() throws {
        var evidence = NativeMessageEvidence(prompt: "Read the newest message from the coordinator.")
        evidence.observeNativeRead()
        let diagnostic = try XCTUnwrap(evidence.completionDiagnostic)
        for requirement in ["sender", "incoming direction", "ordering", "latest-message boundary"] {
            XCTAssertTrue(diagnostic.contains(requirement), requirement)
        }
        for _ in 0..<10 { evidence.observeNativeRead() }
        XCTAssertEqual(evidence.completionDiagnostic, diagnostic,
                       "More snapshots or a model's interpretation cannot manufacture a metadata certificate.")
    }

    func testIndependentTurnStateDoesNotLeakIncomingRequirement() {
        var oldTurn = NativeMessageEvidence(prompt: "What is the last message from my colleague?")
        oldTurn.observeNativeRead()
        var nextTurn = NativeMessageEvidence(prompt: "Read the selected row.")
        nextTurn.observeNativeRead()
        XCTAssertNotNil(oldTurn.completionDiagnostic)
        XCTAssertNil(nextTurn.completionDiagnostic)
    }
}

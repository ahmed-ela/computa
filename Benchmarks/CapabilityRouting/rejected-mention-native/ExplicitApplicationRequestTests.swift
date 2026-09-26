import Foundation
import XCTest
@testable import HeyDash

final class ExplicitApplicationRequestTests: XCTestCase {
    private let scope = ExplicitApplicationRequest.Scope(generation: UUID(), turnID: "turn-a", sessionEpoch: UUID())

    func testUserStartPreservesExactBoundedPromptOnce() throws {
        let prompt = "  Inspect Cedar Desk.\n"
        let pending = ExplicitApplicationRequest(prompt: prompt, submissionID: UUID())
        let active = try XCTUnwrap(pending.started(isUserTurn: true))
        XCTAssertEqual(active.text, prompt)
        XCTAssertEqual(active.submissionID, pending.submissionID)
        XCTAssertNil(active.started(isUserTurn: true))
        XCTAssertNil(pending.started(isUserTurn: false))
    }

    func testRejectedOrCancelledStartCannotRestoreHint() {
        var pending = ExplicitApplicationRequest(prompt: "Cedar Desk", submissionID: UUID())
        pending.invalidate()
        XCTAssertNil(pending.text)
        XCTAssertNil(pending.started(isUserTurn: true))
        // Completion/reset removes the whole session; its request is not reused.
        let next = ExplicitApplicationRequest(prompt: "Amber Pad", submissionID: UUID())
        XCTAssertNotEqual(next.submissionID, pending.submissionID)
        XCTAssertEqual(next.text, "Amber Pad")
    }

    func testSteerClearsBeforeAcknowledgmentAndOnlyLatestReplyCanRestore() {
        var request = ExplicitApplicationRequest(prompt: "Cedar Desk", submissionID: UUID())
        let first = request.beginSteer(scope: scope)
        XCTAssertNil(request.text)
        let second = request.beginSteer(scope: scope)
        request.acknowledgeSteer(prompt: "Old request", ticket: first, currentScope: scope)
        XCTAssertNil(request.text)
        request.acknowledgeSteer(prompt: "  Latest request\n", ticket: second, currentScope: scope)
        XCTAssertEqual(request.text, "  Latest request\n")
        request.acknowledgeSteer(prompt: "Old request", ticket: first, currentScope: scope)
        XCTAssertEqual(request.text, "  Latest request\n")
    }

    func testChangedGenerationTurnOrEpochRejectsAcknowledgment() {
        let changed = [
            ExplicitApplicationRequest.Scope(generation: UUID(), turnID: scope.turnID, sessionEpoch: scope.sessionEpoch),
            .init(generation: scope.generation, turnID: "turn-b", sessionEpoch: scope.sessionEpoch),
            .init(generation: scope.generation, turnID: scope.turnID, sessionEpoch: UUID()),
        ]
        for current in changed {
            var request = ExplicitApplicationRequest(prompt: "Cedar Desk", submissionID: UUID())
            let ticket = request.beginSteer(scope: scope)
            request.acknowledgeSteer(prompt: "Amber Pad", ticket: ticket, currentScope: current)
            XCTAssertNil(request.text)
        }
    }

    func testRevokedRequestRejectsLateSteerAndRejectedSteerRemainsEmpty() {
        var request = ExplicitApplicationRequest(prompt: "Cedar Desk", submissionID: UUID())
        let ticket = request.beginSteer(scope: scope)
        XCTAssertNil(request.text) // Rejection never calls acknowledgeSteer.
        request.invalidate()
        request.acknowledgeSteer(prompt: "Amber Pad", ticket: ticket, currentScope: scope)
        XCTAssertNil(request.text)
    }

    func testPromptBoundUsesUTF16AndNeverTruncates() {
        let exactly = String(repeating: "🦉", count: 4_096)
        XCTAssertEqual(ExplicitApplicationRequest(prompt: exactly, submissionID: UUID()).text, exactly)
        XCTAssertNil(ExplicitApplicationRequest(prompt: exactly + "x", submissionID: UUID()).text)
        var request = ExplicitApplicationRequest(prompt: "Cedar Desk", submissionID: UUID())
        let ticket = request.beginSteer(scope: scope)
        request.acknowledgeSteer(prompt: exactly + "x", ticket: ticket, currentScope: scope)
        XCTAssertNil(request.text)
    }
}

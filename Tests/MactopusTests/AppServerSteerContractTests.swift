import Foundation
import XCTest
@testable import Mactopus

final class AppServerSteerContractTests: XCTestCase {
    func testSteerRequestTargetsExactlyTheActiveThreadAndTurn() throws {
        let request = try AppServerSteerRequest(
            prompt: "  Use the existing browser tab.\nKeep the changes local.  ",
            threadID: "mapped-thread",
            expectedTurnID: "active-turn"
        )
        XCTAssertEqual(AppServerSteerRequest.method, "turn/steer")
        XCTAssertEqual(Set(request.parameters.keys), ["threadId", "expectedTurnId", "input"])
        XCTAssertEqual(request.parameters["threadId"] as? String, "mapped-thread")
        XCTAssertEqual(request.parameters["expectedTurnId"] as? String, "active-turn")
        let input = try XCTUnwrap(request.parameters["input"] as? [[String: String]])
        XCTAssertEqual(input, [[
            "type": "text",
            "text": "  Use the existing browser tab.\nKeep the changes local.  ",
        ]])
        XCTAssertNil(request.parameters["model"])
        XCTAssertNil(request.parameters["turnId"])
    }

    func testSteerRejectsMissingOrEmptyThreadAndTurnIdentities() {
        let identities: [(String?, String?)] = [
            (nil, nil), (nil, "turn"), ("thread", nil),
            ("", "turn"), ("thread", ""),
        ]
        for (threadID, turnID) in identities {
            XCTAssertThrowsError(try AppServerSteerRequest(
                prompt: "Keep going", threadID: threadID, expectedTurnID: turnID
            )) { error in
                XCTAssertEqual(error as? AppServerSteerRequest.ValidationError, .noActiveTurn)
            }
        }
    }

    func testSteerRejectsWhitespaceOnlyInput() {
        for prompt in ["", " \t\n "] {
            XCTAssertThrowsError(try AppServerSteerRequest(
                prompt: prompt, threadID: "thread", expectedTurnID: "turn"
            )) { error in
                XCTAssertEqual(error as? AppServerSteerRequest.ValidationError, .emptyPrompt)
            }
        }
    }

    func testSteerAcceptsOnlyAnAcknowledgmentForTheExpectedTurn() throws {
        let request = try AppServerSteerRequest(
            prompt: "Use blue", threadID: "thread", expectedTurnID: "turn"
        )
        for response in [
            #"{"id":7,"result":{"turnId":"turn"}}"#,
            #"{"id":7,"result":{"turnId":"turn"},"error":null}"#,
        ] {
            XCTAssertNoThrow(try request.validateAcknowledgment(Data(response.utf8)))
        }
    }

    func testSteerRejectsStaleMalformedAndErrorAcknowledgments() throws {
        let request = try AppServerSteerRequest(
            prompt: "Use blue", threadID: "thread", expectedTurnID: "expected-turn"
        )
        let responses = [
            #"{"result":{"turnId":"newer-turn"}}"#,
            #"{"result":{"turnId":""}}"#,
            #"{"result":{"turnId":17}}"#,
            #"{"result":{"turn":{"id":"expected-turn"}}}"#,
            #"{"result":{}}"#,
            #"{"result":null}"#,
            #"{"result":{"turnId":"expected-turn"},"error":{"message":"rejected"}}"#,
            #"{"error":{"message":"turn is no longer active"}}"#,
            "[]", "not JSON",
        ]
        for response in responses {
            XCTAssertThrowsError(try request.validateAcknowledgment(Data(response.utf8))) { error in
                XCTAssertEqual(error as? AppServerSteerRequest.ValidationError, .invalidAcknowledgment)
            }
        }
    }

    func testOnlySuccessfulCompletionCanDrainQueuedMessages() {
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: ["status": "completed"]), .completed)
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: [
            "status": "completed", "error": NSNull(),
        ]), .completed)
        for status in ["failed", "interrupted", "inProgress", "unknown", ""] {
            XCTAssertEqual(AppServerTurnCompletionContract.status(for: ["status": status]), .waiting)
        }
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: nil), .waiting)
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: [:]), .waiting)
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: [
            "status": "completed", "error": ["message": "provider failed"],
        ]), .waiting)
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: [
            "status": "completed", "error": "provider failed",
        ]), .waiting)
    }

    func testUnsupportedAdapterDoesNotSubmitOrInterruptAsASteerFallback() async {
        let runtime = UnsupportedSteeringRuntime()
        do {
            try await runtime.steer(prompt: "Use blue", toTaskID: "task")
            XCTFail("An adapter without steering support must reject the input.")
        } catch {
            XCTAssertEqual(error as? AgentRuntimeCapabilityError, .steeringUnsupported)
        }
        let calls = await runtime.calls
        XCTAssertEqual(calls, [])
    }

    func testCompletionRequiresExactCurrentTurnAndIgnoresDuplicates() {
        var tracker = AppServerTurnIdentityTracker()
        let token = tracker.beginStart(taskID: "task")
        tracker.observeStart(taskID: "task", turnID: "active")
        for turnID in [nil, "", "stale"] as [String?] {
            XCTAssertFalse(tracker.complete(taskID: "task", turnID: turnID))
            XCTAssertEqual(tracker.activeTurnID(for: "task"), "active")
        }
        XCTAssertTrue(tracker.acknowledgeStart(taskID: "task", turnID: "active", token: token))
        XCTAssertTrue(tracker.complete(taskID: "task", turnID: "active"))
        XCTAssertNil(tracker.activeTurnID(for: "task"))
        XCTAssertFalse(tracker.complete(taskID: "task", turnID: "active"))
    }

    func testLateStartAcknowledgmentCannotResurrectCompletedTurn() {
        var tracker = AppServerTurnIdentityTracker()
        let token = tracker.beginStart(taskID: "task")
        tracker.observeStart(taskID: "task", turnID: "finished")
        XCTAssertTrue(tracker.complete(taskID: "task", turnID: "finished"))
        XCTAssertFalse(tracker.acknowledgeStart(taskID: "task", turnID: "finished", token: token))
        XCTAssertNil(tracker.activeTurnID(for: "task"))
    }

    func testStaleCompletionCannotRetireTheNextTurn() {
        var tracker = AppServerTurnIdentityTracker()
        _ = tracker.beginStart(taskID: "task")
        tracker.observeStart(taskID: "task", turnID: "first")
        XCTAssertTrue(tracker.complete(taskID: "task", turnID: "first"))
        let token = tracker.beginStart(taskID: "task")
        tracker.observeStart(taskID: "task", turnID: "second")
        XCTAssertFalse(tracker.complete(taskID: "task", turnID: "first"))
        XCTAssertEqual(tracker.activeTurnID(for: "task"), "second")
        XCTAssertTrue(tracker.acknowledgeStart(taskID: "task", turnID: "second", token: token))
    }

    func testNewStartAttemptRejectsEarlierAcknowledgment() {
        var tracker = AppServerTurnIdentityTracker()
        let old = tracker.beginStart(taskID: "task")
        let current = tracker.beginStart(taskID: "task")
        XCTAssertFalse(tracker.acknowledgeStart(taskID: "task", turnID: "old", token: old))
        XCTAssertNil(tracker.activeTurnID(for: "task"))
        XCTAssertTrue(tracker.acknowledgeStart(taskID: "task", turnID: "current", token: current))
        XCTAssertEqual(tracker.activeTurnID(for: "task"), "current")
    }

    func testStartAcknowledgmentCannotOverwriteDifferentObservedTurn() {
        var tracker = AppServerTurnIdentityTracker()
        let token = tracker.beginStart(taskID: "task")
        tracker.observeStart(taskID: "task", turnID: "observed")
        XCTAssertFalse(tracker.acknowledgeStart(taskID: "task", turnID: "different", token: token))
        XCTAssertEqual(tracker.activeTurnID(for: "task"), "observed")
    }

    func testCancelAndShutdownInvalidatePendingStartAcknowledgments() {
        var tracker = AppServerTurnIdentityTracker()
        let cancelled = tracker.beginStart(taskID: "task")
        tracker.cancelStart(taskID: "task", token: cancelled)
        XCTAssertFalse(tracker.acknowledgeStart(taskID: "task", turnID: "cancelled", token: cancelled))
        let stopped = tracker.beginStart(taskID: "task")
        tracker.observeStart(taskID: "task", turnID: "active")
        tracker.removeAll()
        XCTAssertNil(tracker.activeTurnID(for: "task"))
        XCTAssertFalse(tracker.acknowledgeStart(taskID: "task", turnID: "active", token: stopped))
    }
}

private actor UnsupportedSteeringRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Unsupported steering fixture"
    private(set) var calls = [String]()

    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {
        calls.append("submit")
    }
    func interrupt(taskID: AgentTask.ID) async throws { calls.append("interrupt") }
    func resolveApproval(requestID: String, approved: Bool) async throws { }
}

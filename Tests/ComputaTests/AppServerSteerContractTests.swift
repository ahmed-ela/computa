import Foundation
import XCTest
@testable import Computa

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
        for status in ["interrupted", "inProgress", "unknown", ""] {
            XCTAssertEqual(AppServerTurnCompletionContract.status(for: ["status": status]), .waiting)
        }
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: nil), .waiting)
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: [:]), .waiting)
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: [
            "status": "completed", "error": ["message": "provider failed"],
        ]), .failed)
        XCTAssertEqual(AppServerTurnCompletionContract.status(for: [
            "status": "completed", "error": "provider failed",
        ]), .failed)
    }

    func testOrdinaryFailedTerminalSourcePreservesPostBlockObservation() {
        let failedTurns: [[String: Any]] = [
            ["status": "failed"],
            ["status": "failed", "error": NSNull()],
            ["status": "failed", "error": ["message": "website verification required"]],
            ["status": "completed", "error": ["message": "provider failed"]],
            ["status": "completed", "error": "provider failed"],
        ]
        for turn in failedTurns {
            XCTAssertEqual(AppServerTurnCompletionContract.status(for: turn), .failed)
            XCTAssertEqual(AppServerTurnCompletionContract.cleanupCause(for: turn), .failedTurn)
        }
    }

    func testInterruptedNativeAndContextStoppedSourcesAlwaysClipPostBlockObservation() {
        let interruptedTurns: [[String: Any]] = [
            ["status": "interrupted"],
            ["status": "interrupted", "error": ["message": "interrupted while blocked"]],
        ]
        for turn in interruptedTurns {
            XCTAssertEqual(AppServerTurnCompletionContract.status(for: turn), .waiting)
            XCTAssertEqual(AppServerTurnCompletionContract.cleanupCause(for: turn), .cancelled)
        }
        let failed: [String: Any] = ["status": "failed", "error": ["message": "terminal failure after stop"]]
        XCTAssertEqual(AppServerTurnCompletionContract.cleanupCause(for: failed, wasNativeStopped: true), .cancelled)
        XCTAssertEqual(AppServerTurnCompletionContract.cleanupCause(for: failed, wasContextStopped: true), .cancelled)
        XCTAssertEqual(AppServerTurnCompletionContract.cleanupCause(for: failed,
            wasNativeStopped: true, wasContextStopped: true), .cancelled)
    }

    func testAbsentOrUnknownTerminalSourceCannotGrantFailedTurnRetention() {
        let turns: [[String: Any]?] = [
            nil, [:], ["status": "unknown"], ["status": "inProgress"], ["status": ""],
            ["status": "completed"], ["status": "completed", "error": NSNull()],
        ]
        for turn in turns {
            XCTAssertEqual(AppServerTurnCompletionContract.cleanupCause(for: turn), .cancelled)
        }
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

    func testRetiredStartNotificationCannotBindTheNextPreparedTurn() {
        var tracker = AppServerTurnIdentityTracker()
        for old in ["first", "second"] {
            let token = tracker.beginStart(taskID: "task")
            XCTAssertTrue(tracker.observeStart(taskID: "task", turnID: old))
            XCTAssertTrue(tracker.acknowledgeStart(taskID: "task", turnID: old, token: token))
            XCTAssertTrue(tracker.complete(taskID: "task", turnID: old))
        }
        let current = tracker.beginStart(taskID: "task")
        for retired in ["first", "second"] {
            XCTAssertFalse(tracker.observeStart(taskID: "task", turnID: retired))
            XCTAssertNil(tracker.activeTurnID(for: "task"))
            XCTAssertFalse(tracker.acknowledgeStart(taskID: "task", turnID: retired, token: current))
        }
        XCTAssertTrue(tracker.acknowledgeStart(taskID: "task", turnID: "current", token: current))
        XCTAssertFalse(tracker.observeStart(taskID: "task", turnID: "foreign"))
        XCTAssertEqual(tracker.activeTurnID(for: "task"), "current")
        XCTAssertEqual(tracker.latestTurnID(for: "task"), "current")
    }

    func testRestoredHistoryCannotStartAgainWithinTheOwnedRuntime() {
        var tracker = AppServerTurnIdentityTracker()
        tracker.restoreLatestTurnID(taskID: "task", turnID: "saved")
        let token = tracker.beginStart(taskID: "task")
        XCTAssertFalse(tracker.observeStart(taskID: "task", turnID: "saved"))
        XCTAssertFalse(tracker.acknowledgeStart(taskID: "task", turnID: "saved", token: token))
        XCTAssertTrue(tracker.observeStart(taskID: "task", turnID: "fresh"))
        XCTAssertTrue(tracker.acknowledgeStart(taskID: "task", turnID: "fresh", token: token))
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

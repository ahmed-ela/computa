import Foundation
import XCTest
@testable import Computa

final class RuntimeContextContractTests: XCTestCase {
    func testContextUsesLastRequestNotCumulativeLifetimeUsage() throws {
        let date = Date(timeIntervalSince1970: 100)
        let usage = try XCTUnwrap(AppServerContextUsageContract.parse(payload(), expectedTurnID: "turn", now: date))
        XCTAssertEqual(usage.usedTokens, 2_100)
        XCTAssertEqual(usage.inputTokens, 2_000)
        XCTAssertEqual(usage.outputTokens, 100)
        XCTAssertEqual(usage.contextWindow, 8_192)
        XCTAssertEqual(usage.turnID, "turn")
        XCTAssertEqual(usage.measuredAt, date)
        XCTAssertEqual(try XCTUnwrap(usage.fractionUsed), 2_100.0 / 8_192.0)
    }

    func testMissingOrNullCapacityStaysUnknownRatherThanInventingAWindow() throws {
        for capacity in [nil, NSNull()] as [Any?] {
            let usage = try XCTUnwrap(AppServerContextUsageContract.parse(payload(window: capacity), expectedTurnID: "turn"))
            XCTAssertNil(usage.contextWindow)
            XCTAssertNil(usage.fractionUsed)
            XCTAssertEqual(usage.usedTokens, 2_100)
        }
    }

    func testZeroActualUsageIsValidAndLargeUsageIsNotSilentlyRewritten() throws {
        let zero = try XCTUnwrap(AppServerContextUsageContract.parse(
            payload(last: ["totalTokens": 0, "inputTokens": 0, "outputTokens": 0]), expectedTurnID: "turn"))
        XCTAssertEqual(zero.fractionUsed, 0)
        let over = try XCTUnwrap(AppServerContextUsageContract.parse(
            payload(last: ["totalTokens": 10_000, "inputTokens": 9_000, "outputTokens": 1_000]), expectedTurnID: "turn"))
        XCTAssertEqual(over.usedTokens, 10_000)
        XCTAssertEqual(over.fractionUsed, 1)
    }

    func testMalformedTokenCountsFailClosed() {
        let invalid: [Any] = [true, false, -1, 1.5, "2100", NSNull(),
                              Double.infinity, Double.nan, NSNumber(value: UInt64.max)]
        for field in ["totalTokens", "inputTokens", "outputTokens"] {
            for value in invalid {
                var last: [String: Any] = ["totalTokens": 2_100, "inputTokens": 2_000, "outputTokens": 100]
                last[field] = value
                XCTAssertNil(AppServerContextUsageContract.parse(payload(last: last), expectedTurnID: "turn"), "\(field): \(value)")
            }
        }
    }

    func testMissingTokenCountsNeverFallBackToLifetimeTotals() {
        for field in ["totalTokens", "inputTokens", "outputTokens"] {
            var last: [String: Any] = ["totalTokens": 2_100, "inputTokens": 2_000, "outputTokens": 100]
            last.removeValue(forKey: field)
            XCTAssertNil(AppServerContextUsageContract.parse(payload(last: last), expectedTurnID: "turn"))
        }
        XCTAssertNil(AppServerContextUsageContract.parse([
            "turnId": "turn", "tokenUsage": ["total": ["totalTokens": 500_000]],
        ], expectedTurnID: "turn"))
    }

    func testMalformedPresentCapacityIsNotDisplayedAsAuthoritative() {
        for value in [0, -8_192, true, 8192.5, "8192", Double.infinity, NSNumber(value: UInt64.max)] as [Any] {
            XCTAssertNil(AppServerContextUsageContract.parse(payload(window: value), expectedTurnID: "turn"))
        }
    }

    func testInconsistentUsageAndStaleTurnAreRejected() {
        XCTAssertNil(AppServerContextUsageContract.parse(payload(), expectedTurnID: "other-turn"))
        XCTAssertNil(AppServerContextUsageContract.parse(payload(), expectedTurnID: nil))
        XCTAssertNil(AppServerContextUsageContract.parse(payload(last: [
            "totalTokens": 100, "inputTokens": 101, "outputTokens": 0,
        ]), expectedTurnID: "turn"))
        XCTAssertNil(AppServerContextUsageContract.parse(payload(last: [
            "totalTokens": 100, "inputTokens": 0, "outputTokens": 101,
        ]), expectedTurnID: "turn"))
    }

    func testMalformedCurrentTurnInvalidatesButStaleTurnIsIgnoredByRouting() {
        let malformed: [String: Any] = ["turnId": "current", "tokenUsage": "bad payload"]
        XCTAssertTrue(AppServerContextUsageContract.matchesTurn(malformed, expectedTurnID: "current"))
        XCTAssertNil(AppServerContextUsageContract.parse(malformed, expectedTurnID: "current"))
        XCTAssertFalse(AppServerContextUsageContract.matchesTurn(malformed, expectedTurnID: "newer"))
        XCTAssertFalse(AppServerContextUsageContract.matchesTurn([:], expectedTurnID: "current"))
    }

    func testRuntimeEffectiveWindowOverridesNominalCatalogCapacity() throws {
        let usage = try XCTUnwrap(AppServerContextUsageContract.parse(payload(window: 7_782), expectedTurnID: "turn"))
        XCTAssertEqual(usage.contextWindow, 7_782)
        XCTAssertEqual(usage.fractionUsed, 2_100.0 / 7_782.0)
    }

    func testInexactSumAndPostCompactionEstimatesAreNotLabeledMeasured() {
        for last in [
            ["totalTokens": 100, "inputTokens": 70, "outputTokens": 70],
            ["totalTokens": 4_200, "inputTokens": 0, "outputTokens": 0],
            ["totalTokens": Int.max, "inputTokens": Int.max, "outputTokens": Int.max],
        ] {
            XCTAssertNil(AppServerContextUsageContract.parse(payload(last: last), expectedTurnID: "turn"))
        }
    }

    func testRetryingErrorPreservesCurrentTurnWhileTerminalErrorRetiresIt() {
        var identity = AppServerTurnIdentityTracker()
        let token = identity.beginStart(taskID: "task")
        identity.observeStart(taskID: "task", turnID: "turn")
        let retry = AppServerErrorNotificationContract.classify(errorPayload(willRetry: true),
            expectedThreadID: "thread", activeTurnID: identity.activeTurnID(for: "task"))
        XCTAssertEqual(retry, .retrying(message: "Provider unavailable"))
        XCTAssertEqual(identity.activeTurnID(for: "task"), "turn")
        let terminal = AppServerErrorNotificationContract.classify(errorPayload(willRetry: false),
            expectedThreadID: "thread", activeTurnID: identity.activeTurnID(for: "task"))
        guard case .terminal(let turnID, _) = terminal else { return XCTFail("Expected terminal error.") }
        XCTAssertTrue(identity.complete(taskID: "task", turnID: turnID))
        XCTAssertNil(identity.activeTurnID(for: "task"))
        XCTAssertFalse(identity.acknowledgeStart(taskID: "task", turnID: "turn", token: token))
        XCTAssertEqual(AppServerErrorNotificationContract.classify(errorPayload(willRetry: false),
            expectedThreadID: "thread", activeTurnID: identity.activeTurnID(for: "task")), .ignored)
    }

    func testTerminalTypedOverflowDoesNotRequireDiscardingTheChat() {
        var payload = errorPayload(willRetry: false)
        payload["error"] = ["message": "Start a new thread.", "codexErrorInfo": "contextWindowExceeded"]
        guard case .terminal(let turnID, let message) = AppServerErrorNotificationContract.classify(payload,
            expectedThreadID: "thread", activeTurnID: "turn") else { return XCTFail("Expected terminal error") }
        XCTAssertEqual(turnID, "turn")
        XCTAssertTrue(message.contains("continue in this chat"))
        XCTAssertFalse(message.contains("Start a new thread"))
        payload["willRetry"] = true
        XCTAssertEqual(AppServerErrorNotificationContract.classify(payload,
            expectedThreadID: "thread", activeTurnID: "turn"), .retrying(message: "Start a new thread."))
        payload["willRetry"] = false
        payload["error"] = ["message": "Start a new thread.", "codexErrorInfo": "other"]
        XCTAssertEqual(AppServerErrorNotificationContract.classify(payload,
            expectedThreadID: "thread", activeTurnID: "turn"), .terminal(turnID: "turn", message: "Start a new thread."))
    }

    func testMalformedStaleAndCrossThreadErrorsCannotRetireCurrentWork() {
        var cases = [[String: Any]]()
        for key in ["threadId", "turnId", "willRetry", "error"] {
            var invalid = errorPayload(willRetry: false)
            invalid.removeValue(forKey: key)
            cases.append(invalid)
        }
        for invalidRetry in [0, 1, "false", NSNull()] as [Any] {
            var invalid = errorPayload(willRetry: false)
            invalid["willRetry"] = invalidRetry
            cases.append(invalid)
        }
        for (key, value) in [("threadId", "other-thread"), ("turnId", "stale-turn")] {
            var invalid = errorPayload(willRetry: false)
            invalid[key] = value
            cases.append(invalid)
        }
        for invalid in cases {
            XCTAssertEqual(AppServerErrorNotificationContract.classify(invalid,
                expectedThreadID: "thread", activeTurnID: "turn"), .ignored)
        }
    }

    func testTerminalErrorWithoutCompletionSettlesCompactionFailure() {
        var tracker = AppServerCompactionTracker()
        _ = tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn")
        let error = AppServerErrorNotificationContract.classify(errorPayload(willRetry: false),
            expectedThreadID: "thread", activeTurnID: "turn")
        guard case .terminal(_, let message) = error else { return XCTFail("Expected terminal error.") }
        XCTAssertEqual(tracker.fail(taskID: "task", message: message), .failed(message: message))
        XCTAssertFalse(tracker.isRunning(taskID: "task"))
        XCTAssertNil(tracker.finishTurn(taskID: "task", turnID: "turn", succeeded: false, message: message))
    }

    func testPostCompactionEstimateIsOnlyAStopSignalNeverMeasuredUsage() throws {
        let params = payload(last: ["totalTokens": 11_762, "inputTokens": 0, "outputTokens": 0], window: 7_782)
        XCTAssertNil(AppServerContextUsageContract.parse(params, expectedTurnID: "turn"))
        let estimate = try XCTUnwrap(AppServerContextUsageContract.compactedEstimate(params, expectedTurnID: "turn"))
        XCTAssertEqual(estimate.tokens, 11_762)
        XCTAssertEqual(estimate.window, 7_782)
        XCTAssertNil(AppServerContextUsageContract.compactedEstimate(params, expectedTurnID: "other"))
        XCTAssertNil(AppServerContextUsageContract.compactedEstimate(payload(), expectedTurnID: "turn"))
    }

    func testRetainedContextOverEffectiveWindowFailsOnFirstEstimate() {
        var guardrail = AppServerCompactionProgressGuard()
        guardrail.observeTurnStart(taskID: "task", turnID: "turn")
        XCTAssertNil(guardrail.started(taskID: "task", turnID: "turn"))
        XCTAssertNotNil(guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 11_762, window: 7_782)))
    }

    func testSecondNonShrinkingCompactionAboveLimitFails() {
        var guardrail = AppServerCompactionProgressGuard()
        guardrail.observeTurnStart(taskID: "task", turnID: "turn")
        _ = guardrail.started(taskID: "task", turnID: "turn")
        XCTAssertNil(guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 6_500, window: 7_782)))
        XCTAssertNil(guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144))
        _ = guardrail.started(taskID: "task", turnID: "turn")
        _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 6_550, window: 7_782))
        XCTAssertNotNil(guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144))
    }

    func testThirdCompactionWithoutObservableProgressIsBounded() {
        var guardrail = AppServerCompactionProgressGuard()
        guardrail.observeTurnStart(taskID: "task", turnID: "turn")
        XCTAssertNil(guardrail.started(taskID: "task", turnID: "turn"))
        XCTAssertNil(guardrail.started(taskID: "task", turnID: "turn"))
        XCTAssertNotNil(guardrail.started(taskID: "task", turnID: "turn"))
    }

    func testTinyDecreasesWithInterveningToolItemsCannotExtendCompactionLoop() {
        var guardrail = AppServerCompactionProgressGuard()
        guardrail.observeTurnStart(taskID: "task", turnID: "turn")
        // Replay compaction -> agent/tool items -> compaction ordering. Generic
        // item completions deliberately have no progress-guard API/reset path.
        let notifications: [(String, Int?)] = [
            ("contextCompaction", 6_500), ("agentMessage", nil), ("dynamicToolCall", nil),
            ("contextCompaction", 6_499), ("agentMessage", nil), ("dynamicToolCall", nil),
            ("contextCompaction", 6_498),
        ]
        var stopObserved = false
        for (type, estimate) in notifications {
            guard type == "contextCompaction", let estimate else { continue }
            if estimate == 6_498 {
                XCTAssertNotNil(guardrail.started(taskID: "task", turnID: "turn"))
                stopObserved = true
                break
            }
            XCTAssertNil(guardrail.started(taskID: "task", turnID: "turn"))
            _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: estimate, window: 7_782))
            XCTAssertNil(guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144))
        }
        XCTAssertTrue(stopObserved)
    }

    func testToolAndAgentItemsCannotHideAboveLimitNonShrinkingCompactionLoop() {
        var guardrail = AppServerCompactionProgressGuard()
        guardrail.observeTurnStart(taskID: "task", turnID: "turn")
        _ = guardrail.started(taskID: "task", turnID: "turn")
        _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 6_500, window: 7_782))
        XCTAssertNil(guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144))
        // Real notification ordering: assistant item, then dynamic tool result,
        // then another auto-compaction inside the same unfinished turn.
        // Agent/tool item notifications do not modify the guard.
        XCTAssertNil(guardrail.started(taskID: "task", turnID: "turn"))
        _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 6_550, window: 7_782))
        XCTAssertNotNil(guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144))
    }

    func testActualBelowLimitHeadroomResetsOldEstimateComparison() {
        var guardrail = AppServerCompactionProgressGuard()
        guardrail.observeTurnStart(taskID: "task", turnID: "turn")
        _ = guardrail.started(taskID: "task", turnID: "turn")
        _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 5_000, window: 7_782))
        XCTAssertNil(guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144))
        _ = guardrail.started(taskID: "task", turnID: "turn")
        _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 6_500, window: 7_782))
        XCTAssertNil(guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144))
    }

    func testMaterialCompactionShrinkResetsBudgetButTinyChangesDoNot() {
        var guardrail = AppServerCompactionProgressGuard()
        guardrail.observeTurnStart(taskID: "task", turnID: "turn")
        _ = guardrail.started(taskID: "task", turnID: "turn")
        _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 7_500, window: 7_782))
        _ = guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144)
        _ = guardrail.started(taskID: "task", turnID: "turn")
        _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 6_800, window: 7_782))
        XCTAssertNil(guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144))
        XCTAssertNil(guardrail.started(taskID: "task", turnID: "turn"))
        _ = guardrail.estimated(taskID: "task", turnID: "turn", estimate: .init(tokens: 6_799, window: 7_782))
        _ = guardrail.completed(taskID: "task", turnID: "turn", compactLimit: 6_144)
        XCTAssertNil(guardrail.started(taskID: "task", turnID: "turn"))
        XCTAssertNotNil(guardrail.started(taskID: "task", turnID: "turn"))
    }

    func testCompactionProgressIsTaskAndTurnScoped() {
        var guardrail = AppServerCompactionProgressGuard()
        guardrail.observeTurnStart(taskID: "task", turnID: "old")
        _ = guardrail.started(taskID: "task", turnID: "old")
        _ = guardrail.started(taskID: "task", turnID: "old")
        XCTAssertNil(guardrail.started(taskID: "other", turnID: "old"))
        guardrail.observeTurnStart(taskID: "task", turnID: "new")
        XCTAssertNil(guardrail.started(taskID: "task", turnID: "new"))
        XCTAssertNil(guardrail.estimated(taskID: "task", turnID: "old", estimate: .init(tokens: 20_000, window: 7_782)))
    }

    func testLastUsageMayDecreaseAfterCompactionWithoutLifetimeReset() throws {
        let before = try XCTUnwrap(AppServerContextUsageContract.parse(payload(), expectedTurnID: "turn"))
        let after = try XCTUnwrap(AppServerContextUsageContract.parse(payload(last: [
            "totalTokens": 900, "inputTokens": 800, "outputTokens": 100,
        ]), expectedTurnID: "turn"))
        XCTAssertLessThan(after.usedTokens, before.usedTokens)
    }

    func testCompactionRequiresCorrelatedStartAndCompletion() {
        var tracker = AppServerCompactionTracker()
        XCTAssertFalse(tracker.completed(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertTrue(tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertTrue(tracker.isRunning(taskID: "task"))
        XCTAssertFalse(tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertTrue(tracker.completed(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertFalse(tracker.isRunning(taskID: "task"))
        XCTAssertFalse(tracker.completed(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertNil(tracker.finishTurn(taskID: "task", turnID: "turn", succeeded: true, message: "unused"))
        XCTAssertTrue(tracker.removeAll().isEmpty)
    }

    func testCompactionRejectsCrossTaskStaleTurnAndWrongItem() {
        var tracker = AppServerCompactionTracker()
        XCTAssertFalse(tracker.started(taskID: "task", turnID: nil, itemID: "item", activeTurnID: "turn"))
        XCTAssertFalse(tracker.started(taskID: "task", turnID: "turn", itemID: nil, activeTurnID: "turn"))
        XCTAssertFalse(tracker.started(taskID: "task", turnID: "stale", itemID: "item", activeTurnID: "turn"))
        XCTAssertTrue(tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertFalse(tracker.completed(taskID: "other", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertFalse(tracker.completed(taskID: "task", turnID: "stale", itemID: "item", activeTurnID: "turn"))
        XCTAssertFalse(tracker.completed(taskID: "task", turnID: "turn", itemID: "wrong", activeTurnID: "turn"))
        XCTAssertFalse(tracker.completed(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "new-turn"))
        XCTAssertTrue(tracker.isRunning(taskID: "task"))
    }

    func testExplicitCompactionRequestStillRequiresEnclosingTurnSuccess() {
        var tracker = AppServerCompactionTracker()
        _ = tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn")
        _ = tracker.completed(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn")
        XCTAssertEqual(tracker.finishTurn(taskID: "task", turnID: "turn", succeeded: false,
                       message: "Provider failed", expectedCompaction: true),
                       .failed(message: "Provider failed"))
    }

    func testLaterOrdinaryTerminalErrorDoesNotRelabelCompletedCompaction() {
        var tracker = AppServerCompactionTracker()
        XCTAssertTrue(tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertTrue(tracker.completed(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        var stale = errorPayload(willRetry: false)
        stale["turnId"] = "old-turn"
        XCTAssertEqual(AppServerErrorNotificationContract.classify(stale,
            expectedThreadID: "thread", activeTurnID: "turn"), .ignored)
        let disposition = AppServerErrorNotificationContract.classify(errorPayload(willRetry: false),
            expectedThreadID: "thread", activeTurnID: "turn")
        guard case .terminal(let turnID, let message) = disposition else { return XCTFail("Expected terminal error.") }
        XCTAssertEqual(turnID, "turn")
        XCTAssertNil(tracker.fail(taskID: "task", message: message))
        XCTAssertNil(tracker.finishTurn(taskID: "task", turnID: "turn", succeeded: false, message: message))
        XCTAssertTrue(tracker.removeAll().isEmpty)
    }

    func testLaterOrdinaryFailedTurnPreservesCompletedCompactionAndRejectsStaleTurn() {
        var tracker = AppServerCompactionTracker()
        XCTAssertTrue(tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertTrue(tracker.completed(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertNil(tracker.finishTurn(taskID: "task", turnID: "stale", succeeded: false, message: "late"))
        // A mismatched terminal must not consume the current completed record.
        XCTAssertFalse(tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertNil(tracker.finishTurn(taskID: "task", turnID: "turn", succeeded: false, message: "Provider failed"))
        XCTAssertTrue(tracker.removeAll().isEmpty)
    }

    func testNewTurnAfterCompletedCompactionDoesNotInventFailure() {
        var tracker = AppServerCompactionTracker()
        XCTAssertTrue(tracker.started(taskID: "task", turnID: "old", itemID: "item", activeTurnID: "old"))
        XCTAssertTrue(tracker.completed(taskID: "task", turnID: "old", itemID: "item", activeTurnID: "old"))
        XCTAssertNil(tracker.observeTurnStart(taskID: "task", turnID: "new"))
        XCTAssertFalse(tracker.completed(taskID: "task", turnID: "old", itemID: "item", activeTurnID: "new"))
        XCTAssertTrue(tracker.removeAll().isEmpty)
    }

    func testDisconnectOnlyFailsUnfinishedCompactionRecords() {
        var tracker = AppServerCompactionTracker()
        for task in ["completed", "running"] {
            XCTAssertTrue(tracker.started(taskID: task, turnID: "turn", itemID: "item", activeTurnID: "turn"))
        }
        XCTAssertTrue(tracker.completed(taskID: "completed", turnID: "turn", itemID: "item", activeTurnID: "turn"))
        XCTAssertEqual(tracker.removeAll(), ["running"])
        XCTAssertFalse(tracker.isRunning(taskID: "running"))
        XCTAssertTrue(tracker.removeAll().isEmpty)
    }

    func testMissingCompactionCompletionFailsEvenIfTurnClaimsSuccess() {
        var tracker = AppServerCompactionTracker()
        _ = tracker.started(taskID: "task", turnID: "turn", itemID: "item", activeTurnID: "turn")
        guard case .failed = tracker.finishTurn(taskID: "task", turnID: "turn", succeeded: true, message: "unused") else {
            return XCTFail("Unconfirmed compaction must not unblock queued work.")
        }
    }

    func testManualRequestCannotSucceedWithoutAnyCompactionLifecycle() {
        var tracker = AppServerCompactionTracker()
        guard case .failed = tracker.finishTurn(taskID: "task", turnID: "turn", succeeded: true,
            message: "unused", expectedCompaction: true) else {
            return XCTFail("Manual compaction acknowledgement alone must not report success.")
        }
    }

    func testReplacingUnfinishedCompactionTurnExplicitlyInvalidatesRunningPhase() {
        var tracker = AppServerCompactionTracker()
        _ = tracker.started(taskID: "task", turnID: "old", itemID: "item", activeTurnID: "old")
        XCTAssertNil(tracker.observeTurnStart(taskID: "task", turnID: "old"))
        guard case .failed = tracker.observeTurnStart(taskID: "task", turnID: "new") else {
            return XCTFail("The UI must not be left indefinitely compacting after replacement.")
        }
        XCTAssertFalse(tracker.isRunning(taskID: "task"))
    }

    func testNewTurnCannotCompleteOldCompactionAndErrorsAreTaskScoped() {
        var tracker = AppServerCompactionTracker()
        _ = tracker.started(taskID: "a", turnID: "first", itemID: "item-a", activeTurnID: "first")
        _ = tracker.started(taskID: "b", turnID: "other", itemID: "item-b", activeTurnID: "other")
        tracker.observeTurnStart(taskID: "a", turnID: "second")
        XCTAssertFalse(tracker.completed(taskID: "a", turnID: "first", itemID: "item-a", activeTurnID: "second"))
        XCTAssertNil(tracker.fail(taskID: "a", message: "late"))
        XCTAssertTrue(tracker.isRunning(taskID: "b"))
        XCTAssertEqual(tracker.fail(taskID: "b", message: "Disconnected"), .failed(message: "Disconnected"))
    }

    func testConfiguredCompactionLeavesQuarterWindowSafetyHeadroom() {
        for model in [LocalModelCatalog.defaultModelID, "lmstudio-community/Qwen3.5-4B-MLX-4bit",
                      "lmstudio-community/Qwen3.5-9B-MLX-4bit", "unlisted/model"] {
            let context = LocalThreadContext.forModel(model)
            let config = CodexAppServerRuntime.localThreadConfig(for: model)
            XCTAssertEqual(config["model_context_window"] as? Int, context.contextWindow)
            XCTAssertEqual(config["model_auto_compact_token_limit"] as? Int, context.contextWindow * 3 / 4)
            XCTAssertGreaterThanOrEqual(context.contextWindow - context.autoCompactTokenLimit, 1_024)
        }
    }

    func testNativeCompactorUsesDefaultPromptWithoutUnprovenOverrides() {
        let config = CodexAppServerRuntime.localThreadConfig(for: "lmstudio-community/Qwen3.5-4B-MLX-4bit")
        XCTAssertNil(config["compact_prompt"])
    }

    func testDefaultModeThreadsDoNotOfferTheUnavailableStructuredQuestionTool() {
        let apiModel = APIProviderCatalog.appModelID(providerID: "cerebras", modelID: "gpt-oss-120b")
        for model in [LocalModelCatalog.defaultModelID, "browser/chatgpt", apiModel] {
            let config = CodexAppServerRuntime.localThreadConfig(for: model)
            XCTAssertEqual(config["tools.experimental_request_user_input.enabled"] as? Bool, false)
            XCTAssertEqual(config["features.shell_tool"] as? Bool, true)
            XCTAssertEqual(config["features.unified_exec"] as? Bool, true)
            XCTAssertEqual(config["include_permissions_instructions"] as? Bool, true)
        }
    }

    func testNineBInheritsOnlyTheSharedComputerUseContextProfile() {
        let fourB = CodexAppServerRuntime.localThreadConfig(for: "lmstudio-community/Qwen3.5-4B-MLX-4bit")
        let nineB = CodexAppServerRuntime.localThreadConfig(for: "lmstudio-community/Qwen3.5-9B-MLX-4bit")
        XCTAssertEqual(NSDictionary(dictionary: nineB), NSDictionary(dictionary: fourB))
        XCTAssertEqual(nineB["model_context_window"] as? Int, 16_384)
        XCTAssertEqual(nineB["model_auto_compact_token_limit"] as? Int, 12_288)
        XCTAssertEqual(nineB["features.shell_tool"] as? Bool, true)
        XCTAssertEqual(nineB["features.unified_exec"] as? Bool, true)
        XCTAssertEqual(nineB["web_search"] as? String, "disabled")
        XCTAssertNil(nineB["compact_prompt"])
    }

    func testIsolatedFixtureOverrideCannotDisableOrExceedContextWindow() {
        let model = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let context = LocalThreadContext.forModel(model)
        for value in [-1, 0, context.contextWindow, Int.max] {
            XCTAssertEqual(CodexAppServerRuntime.localThreadConfig(for: model,
                autoCompactLimitOverride: value)["model_auto_compact_token_limit"] as? Int, context.autoCompactTokenLimit)
        }
        XCTAssertEqual(CodexAppServerRuntime.localThreadConfig(for: model,
            autoCompactLimitOverride: 2_048)["model_auto_compact_token_limit"] as? Int, 2_048)
        XCTAssertNil(CodexAppServerRuntime.Configuration.localQwen.autoCompactLimitOverride)
    }

    private func payload(last: [String: Any] = ["totalTokens": 2_100, "inputTokens": 2_000, "outputTokens": 100],
                         window: Any? = 8_192) -> [String: Any] {
        var usage: [String: Any] = ["last": last, "total": ["totalTokens": 500_000, "inputTokens": 450_000, "outputTokens": 50_000]]
        if let window { usage["modelContextWindow"] = window }
        return ["threadId": "thread", "turnId": "turn", "tokenUsage": usage]
    }

    private func errorPayload(willRetry: Bool) -> [String: Any] {
        ["threadId": "thread", "turnId": "turn", "willRetry": willRetry,
         "error": ["message": "Provider unavailable"]]
    }
}

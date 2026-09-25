import Foundation
import CoreFoundation

/// The last model request's reported token footprint, not a thread's lifetime
/// consumption. New input/tool output since this measurement is not estimated.
struct RuntimeContextUsage: Equatable, Sendable {
    let usedTokens: Int
    let contextWindow: Int?
    let inputTokens: Int
    let outputTokens: Int
    let turnID: String
    let measuredAt: Date

    var fractionUsed: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return min(1, max(0, Double(usedTokens) / Double(contextWindow)))
    }
}

enum RuntimeCompactionState: Equatable, Sendable {
    case running
    case completed
    case failed(message: String)
}

enum AppServerContextUsageContract {
    struct CompactedEstimate: Equatable, Sendable {
        let tokens: Int
        let window: Int
    }

    static func matchesTurn(_ params: [String: Any], expectedTurnID: String?) -> Bool {
        guard let turnID = params["turnId"] as? String, !turnID.isEmpty else { return false }
        return turnID == expectedTurnID
    }

    static func parse(_ params: [String: Any], expectedTurnID: String?, now: Date = .now) -> RuntimeContextUsage? {
        guard matchesTurn(params, expectedTurnID: expectedTurnID),
              let turnID = params["turnId"] as? String,
              let usage = params["tokenUsage"] as? [String: Any],
              let last = usage["last"] as? [String: Any],
              let used = nonnegativeInteger(last["totalTokens"]),
              let input = nonnegativeInteger(last["inputTokens"]),
              let output = nonnegativeInteger(last["outputTokens"]),
              input <= used, output == used - input else { return nil }
        let window: Int?
        if let value = usage["modelContextWindow"], !(value is NSNull) {
            guard let parsed = nonnegativeInteger(value), parsed > 0 else { return nil }
            window = parsed
        } else {
            window = nil
        }
        return RuntimeContextUsage(usedTokens: used, contextWindow: window,
            inputTokens: input, outputTokens: output, turnID: turnID, measuredAt: now)
    }

    /// Codex's zero-breakdown post-compaction estimate is useful as a stop
    /// signal, but must never be presented as measured occupancy in the ring.
    static func compactedEstimate(_ params: [String: Any], expectedTurnID: String?) -> CompactedEstimate? {
        guard matchesTurn(params, expectedTurnID: expectedTurnID),
              let usage = params["tokenUsage"] as? [String: Any],
              let last = usage["last"] as? [String: Any],
              nonnegativeInteger(last["inputTokens"]) == 0,
              nonnegativeInteger(last["outputTokens"]) == 0,
              let tokens = nonnegativeInteger(last["totalTokens"]), tokens > 0,
              let window = nonnegativeInteger(usage["modelContextWindow"]), window > 0 else { return nil }
        return CompactedEstimate(tokens: tokens, window: window)
    }

    /// NSNumber bridges booleans too. Reject those and values outside signed
    /// machine integer range before converting, rather than truncating them.
    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        let decimal = number.decimalValue
        guard decimal >= 0, decimal <= Decimal(Int.max) else { return nil }
        let integer = number.int64Value
        guard Decimal(integer) == decimal else { return nil }
        return Int(exactly: integer)
    }
}

/// Bounds native compaction without replacing its summarizer or deleting user
/// history. Progress resets the retry budget; repeated summaries alone do not.
struct AppServerCompactionProgressGuard: Sendable {
    private struct Record: Sendable {
        let turnID: String
        var startsWithoutProgress = 0
        var estimate: Int?
        var previousEstimate: Int?
    }
    private var records: [AgentTask.ID: Record] = [:]

    mutating func observeTurnStart(taskID: AgentTask.ID, turnID: String) {
        if records[taskID]?.turnID != turnID { records[taskID] = Record(turnID: turnID) }
    }

    mutating func started(taskID: AgentTask.ID, turnID: String) -> String? {
        guard records[taskID]?.turnID == turnID else { return nil }
        records[taskID]?.startsWithoutProgress += 1
        records[taskID]?.estimate = nil
        guard records[taskID, default: Record(turnID: turnID)].startsWithoutProgress >= 3 else { return nil }
        return "Context compaction made no forward progress after two attempts. Start a new task or shorten retained input."
    }

    mutating func estimated(taskID: AgentTask.ID, turnID: String,
                            estimate: AppServerContextUsageContract.CompactedEstimate) -> String? {
        guard records[taskID]?.turnID == turnID else { return nil }
        records[taskID]?.estimate = estimate.tokens
        guard estimate.tokens >= estimate.window else { return nil }
        return "Retained context still exceeds the model's effective window after compaction. Start a new task or shorten the input."
    }

    mutating func completed(taskID: AgentTask.ID, turnID: String, compactLimit: Int) -> String? {
        guard let record = records[taskID], record.turnID == turnID, let estimate = record.estimate else { return nil }
        records[taskID]?.previousEstimate = estimate
        if let previous = record.previousEstimate, estimate >= previous, estimate >= compactLimit {
            return "Repeated context compaction did not reduce retained input below the safe limit. Start a new task or shorten the input."
        }
        // A real size reduction or usable headroom is progress, even before a
        // tool/message completes. A subsequent regression still needs checking.
        if estimate < compactLimit {
            records[taskID]?.startsWithoutProgress = 0
            records[taskID]?.previousEstimate = nil
        } else if record.previousEstimate.map({
            estimate < $0 && $0 - estimate >= max(128, $0 / 20)
        }) ?? false {
            records[taskID]?.startsWithoutProgress = 0
        }
        return nil
    }

    mutating func remove(taskID: AgentTask.ID) { records.removeValue(forKey: taskID) }
    mutating func removeAll() { records.removeAll() }
}

enum AppServerErrorNotificationContract {
    enum Disposition: Equatable {
        case ignored
        case retrying(message: String)
        case terminal(turnID: String, message: String)
    }

    static func classify(_ params: [String: Any], expectedThreadID: String, activeTurnID: String?) -> Disposition {
        guard let threadID = params["threadId"] as? String, threadID == expectedThreadID,
              let turnID = params["turnId"] as? String, !turnID.isEmpty, turnID == activeTurnID,
              let retry = params["willRetry"] as? NSNumber,
              CFGetTypeID(retry) == CFBooleanGetTypeID(),
              let error = params["error"] as? [String: Any],
              let message = error["message"] as? String else { return .ignored }
        return retry.boolValue ? .retrying(message: message) : .terminal(turnID: turnID, message: message)
    }
}

/// Correlates compaction lifecycle at both the task and exact turn/item level.
/// Item completion alone is not proof that the enclosing turn succeeded.
struct AppServerCompactionTracker: Sendable {
    private struct Record: Sendable {
        let turnID: String
        let itemID: String
        var completed: Bool
    }
    private var records: [AgentTask.ID: Record] = [:]

    func isRunning(taskID: AgentTask.ID) -> Bool { records[taskID]?.completed == false }

    @discardableResult
    mutating func observeTurnStart(taskID: AgentTask.ID, turnID: String) -> RuntimeCompactionState? {
        guard let record = records[taskID], record.turnID != turnID else { return nil }
        records.removeValue(forKey: taskID)
        return .failed(message: "A new turn began before the previous compaction turn was confirmed.")
    }

    mutating func started(taskID: AgentTask.ID, turnID: String?, itemID: String?, activeTurnID: String?) -> Bool {
        guard let turnID, !turnID.isEmpty, turnID == activeTurnID,
              let itemID, !itemID.isEmpty else { return false }
        if let existing = records[taskID],
           !existing.completed || (existing.turnID == turnID && existing.itemID == itemID) { return false }
        records[taskID] = Record(turnID: turnID, itemID: itemID, completed: false)
        return true
    }

    mutating func completed(taskID: AgentTask.ID, turnID: String?, itemID: String?, activeTurnID: String?) -> Bool {
        guard let turnID, turnID == activeTurnID,
              let itemID, let record = records[taskID], !record.completed,
              record.turnID == turnID, record.itemID == itemID else { return false }
        records[taskID]?.completed = true
        return true
    }

    mutating func finishTurn(taskID: AgentTask.ID, turnID: String?, succeeded: Bool,
                             message: String, expectedCompaction: Bool = false) -> RuntimeCompactionState? {
        guard let turnID, let record = records[taskID], record.turnID == turnID else {
            return expectedCompaction ? .failed(message: "The runtime did not confirm the requested context compaction.") : nil
        }
        records.removeValue(forKey: taskID)
        guard !succeeded || !record.completed else { return nil }
        return .failed(message: !succeeded ? message : "The runtime ended without confirming context compaction.")
    }

    mutating func fail(taskID: AgentTask.ID, message: String) -> RuntimeCompactionState? {
        guard records.removeValue(forKey: taskID) != nil else { return nil }
        return .failed(message: message)
    }

    mutating func removeAll() -> [AgentTask.ID] {
        let tasks = Array(records.keys)
        records.removeAll()
        return tasks
    }
}

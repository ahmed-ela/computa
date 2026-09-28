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
        if !retry.boolValue, error["codexErrorInfo"] as? String == "contextWindowExceeded" {
            return .terminal(turnID: turnID, message:
                "This turn could not fit safely within the local model's context limit. Completed actions are not automatically replayed. You can continue in this chat with a smaller next step; a new chat is not required.")
        }
        return retry.boolValue ? .retrying(message: message) : .terminal(turnID: turnID, message: message)
    }
}

/// Correlates compaction lifecycle at both the task and exact turn/item level.
/// A completed automatic compaction stays completed if later generation fails.
/// Explicit maintenance requests still require their enclosing turn to succeed.
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
        guard !record.completed else { return nil }
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
        guard !record.completed || (expectedCompaction && !succeeded) else { return nil }
        return .failed(message: !succeeded ? message : "The runtime ended without confirming context compaction.")
    }

    mutating func fail(taskID: AgentTask.ID, message: String) -> RuntimeCompactionState? {
        guard let record = records.removeValue(forKey: taskID), !record.completed else { return nil }
        return .failed(message: message)
    }

    mutating func removeAll() -> [AgentTask.ID] {
        let tasks = records.compactMap { $0.value.completed ? nil : $0.key }
        records.removeAll()
        return tasks
    }
}

/// Presentation only. Process ownership, sandboxing and execution stay in App Server.
/// One tracker belongs to one task; the runtime correlates each item to its original turn.
struct AppServerCommandTranscript: Sendable {
    static let maximumOutputBytes = 32_768
    static let maximumItems = 128
    private struct Record: Sendable {
        var command: String
        var cwd: String
        var output: String = ""
        var clipped = false
        var terminal = false
        var timestamp = Date()
        var processID: String?
    }
    private var records: [String: Record] = [:]

    mutating func receive(item: [String: Any], completed: Bool) -> TimelineEntry? {
        guard item["type"] as? String == "commandExecution",
              let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
              let command = item["command"] as? String,
              let cwd = item["cwd"] as? String,
              records[id]?.terminal != true else { return nil }
        guard records[id] != nil || records.count < Self.maximumItems else { return nil }
        if !completed, records[id] != nil { return nil }
        let boundedCommand = Self.prefix(command, bytes: 8_192)
        let boundedCwd = Self.prefix(cwd, bytes: 4_096)
        var record = records[id] ?? Record(command: boundedCommand, cwd: boundedCwd)
        guard record.command == boundedCommand, record.cwd == boundedCwd else { return nil }
        if let processID = item["processId"] as? String {
            record.processID = Self.prefix(processID, bytes: 128)
        }
        if let output = item["aggregatedOutput"] as? String {
            record.output = Self.prefix(output, bytes: Self.maximumOutputBytes)
            record.clipped = output.utf8.count > Self.maximumOutputBytes
        }
        if !completed {
            records[id] = record
            return Self.entry(id: id, record: record, status: .running, result: "Running")
        }
        record.terminal = true
        records[id] = record
        let exit = Self.integer(item["exitCode"])
        let state = item["status"] as? String
        let status: ToolRunStatus = state == "completed" && exit == 0 ? .succeeded : .failed
        let result: String
        if state == "declined" { result = "Declined; command was not approved" }
        else if let exit { result = "Exit code: \(exit)" }
        else { result = "Exit status unavailable (\(state == "failed" ? "failed" : "unverified"))" }
        let duration = Self.integer(item["durationMs"]).flatMap { $0 >= 0 ? Double($0) / 1_000 : nil }
        return Self.entry(id: id, record: record, status: status, result: result, duration: duration)
    }

    mutating func append(itemID: String, delta: String) -> TimelineEntry? {
        guard var record = records[itemID], !record.terminal, !record.clipped else { return nil }
        let remaining = Self.maximumOutputBytes - record.output.utf8.count
        record.output += Self.prefix(delta, bytes: remaining)
        record.clipped = delta.utf8.count > remaining
        records[itemID] = record
        return Self.entry(id: itemID, record: record, status: .running, result: "Running")
    }

    mutating func beginTurn() { records = records.filter { !$0.value.terminal } }

    mutating func finishUnconfirmed(reason: String, interrupted: Bool, retainingPending: Bool = false) -> [TimelineEntry] {
        let pending = records.filter { !$0.value.terminal }.map { id, record in
            Self.entry(id: id, record: record, status: interrupted ? .failed : .running, result: reason)
        }
        if !retainingPending { records.removeAll() }
        return pending
    }

    private static func entry(id: String, record: Record, status: ToolRunStatus,
                              result: String, duration: TimeInterval? = nil) -> TimelineEntry {
        let suffix = record.clipped ? "\n[Output truncated at \(maximumOutputBytes) bytes]" : ""
        let session = record.processID.map { "\nProcess session: \($0)" } ?? ""
        let summary = result + " — " + record.command
        return TimelineEntry(id: id, kind: .tool, title: "Command", body: summary,
            timestamp: record.timestamp, toolEvent: ToolEvent(name: "commandExecution", summary: summary,
                status: status, input: "Working directory: \(record.cwd)\nCommand: \(record.command)" + session,
                output: record.output + suffix + "\n" + result, duration: duration))
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        let decimal = number.decimalValue
        guard decimal >= Decimal(Int.min), decimal <= Decimal(Int.max),
              Decimal(number.int64Value) == decimal else { return nil }
        return Int(exactly: number.int64Value)
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var data = Array(text.utf8.prefix(max(0, bytes)))
        while !data.isEmpty {
            if let result = String(bytes: data, encoding: .utf8) { return result }
            data.removeLast()
        }
        return ""
    }
}

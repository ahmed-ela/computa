import Foundation

/// The native engine's token estimate cannot account for website framing. Keep
/// room for the next bounded tool result and for the tool-free summary request.
/// This is local admission, not provider token usage, truncation or Send retry.
enum WebsiteContextBudget {
    static let compactionThresholdBytes = 128 * 1_024

    struct CompactionRequired: LocalizedError, Sendable {
        let actualBytes: Int
        var errorDescription: String? {
            "The complete website request needs context compaction (\(actualBytes) bytes; maintenance threshold \(compactionThresholdBytes)). No prompt was submitted."
        }

        func streamData() throws -> Data {
            let value: [String: Any] = ["type": "response.failed", "sequence_number": 0,
                "response": ["id": "resp_" + UUID().uuidString.lowercased(), "object": "response",
                    "status": "failed", "output": [], "usage": NSNull(),
                    "error": ["code": "context_length_exceeded", "type": "invalid_request_error",
                        "message": localizedDescription, "submitted": false,
                        "actual_bytes": actualBytes, "maximum_bytes": compactionThresholdBytes]]]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return Data("event: response.failed\ndata: ".utf8) + data + Data("\n\n".utf8)
        }
    }

    static func validate(_ request: WebModelResponseCodec.Request, maintenance: Bool) throws {
        // Groq has its own token-budget/history protocol. Other website adapters
        // need independent qualification before adopting this native checkpoint.
        guard LocalModelCatalog.webProvider(for: request.model) == "chatgpt", !maintenance else { return }
        let bytes = max(request.prompt.utf8.count, request.continuationRequest.count)
        if bytes > compactionThresholdBytes { throw CompactionRequired(actualBytes: bytes) }
    }
}

/// Only validated native App Server compaction events can authorize a new
/// history checkpoint. HTTP fields, summaries and page text cannot publish one.
/// The synchronous publication keeps stdio events ordered; the event stream
/// covers an HTTP request that races ahead of delivery of the native event.
final class WebsiteCompactionBoundary: @unchecked Sendable {
    struct Scope: Equatable, Sendable {
        let taskID: String
        let threadID: String
        let turnID: String
        let generation: UUID
    }
    struct Checkpoint: Equatable, Sendable {
        let scope: Scope
        let itemID: String
        let completed: Bool
        let sequence: Int
    }
    private struct Entry {
        let scope: Scope
        var checkpoint: Checkpoint?
        var observers: [UUID: AsyncStream<Checkpoint>.Continuation] = [:]
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func register(_ scope: Scope) {
        let old = lock.withLock { entries.updateValue(Entry(scope: scope), forKey: scope.taskID) }
        old?.observers.values.forEach { $0.finish() }
    }

    func remove(taskID: String) {
        let old = lock.withLock { entries.removeValue(forKey: taskID) }
        old?.observers.values.forEach { $0.finish() }
    }

    func publish(scope: Scope, itemID: String, completed: Bool) {
        guard !itemID.isEmpty else { return }
        lock.withLock {
            guard var entry = entries[scope.taskID], entry.scope == scope else { return }
            if completed {
                guard let prior = entry.checkpoint, !prior.completed, prior.itemID == itemID else { return }
            } else if let prior = entry.checkpoint {
                guard prior.completed, prior.itemID != itemID else { return }
            }
            let checkpoint = Checkpoint(scope: scope, itemID: itemID, completed: completed,
                                        sequence: (entry.checkpoint?.sequence ?? 0) + 1)
            entry.checkpoint = checkpoint
            entries[scope.taskID] = entry
            entry.observers.values.forEach { $0.yield(checkpoint) }
        }
    }

    func snapshot(scope: Scope) -> Checkpoint? {
        lock.withLock { entries[scope.taskID].flatMap { $0.scope == scope ? $0.checkpoint : nil } }
    }

    func next(scope: Scope, after sequence: Int, timeout: Duration = .seconds(5)) async throws -> Checkpoint {
        let id = UUID()
        let stream = AsyncStream<Checkpoint> { continuation in
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.entries[scope.taskID]?.observers.removeValue(forKey: id) }
            }
            let registered = lock.withLock {
                guard var entry = entries[scope.taskID], entry.scope == scope else {
                    return false
                }
                entry.observers[id] = continuation
                entries[scope.taskID] = entry
                if let checkpoint = entry.checkpoint { continuation.yield(checkpoint) }
                return true
            }
            if !registered { continuation.finish() }
        }
        return try await withThrowingTaskGroup(of: Checkpoint.self) { group in
            group.addTask {
                for await checkpoint in stream where checkpoint.sequence > sequence { return checkpoint }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebModelServer.Failure.inferenceContextRequired
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

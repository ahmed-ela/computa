import Foundation
import XCTest
@testable import LocalCodex

@MainActor
final class RuntimeShutdownTests: XCTestCase {
    func testOwnerCoalescesShutdownAndDoesNotRestartAfterDisposal() async throws {
        let runtime = ShutdownRecordingRuntime()
        let state = AppState(tasks: [], runtime: runtime)
        let first = Task { await state.shutdownRuntime() }
        await runtime.waitUntilShutdownEntered()
        let second = Task { await state.shutdownRuntime() }
        await runtime.releaseShutdown()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, secondResult)
        XCTAssertTrue(firstResult.succeeded)
        await state.startRuntime()
        let counts = await runtime.counts()
        XCTAssertEqual(counts.shutdowns, 1)
        XCTAssertEqual(counts.loads, 0)
        XCTAssertEqual(state.connectionState, .disconnected)
    }

    func testOwnerPreservesAnIncompleteShutdownReport() async {
        let runtime = ShutdownRecordingRuntime(issues: ["injected cleanup failure"])
        let state = AppState(tasks: [], runtime: runtime)
        let pending = Task { await state.shutdownRuntime() }
        await runtime.waitUntilShutdownEntered()
        await runtime.releaseShutdown()
        let result = await pending.value
        let repeated = await state.shutdownRuntime()
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.issues, ["injected cleanup failure"])
        XCTAssertEqual(result, repeated)
    }
}

private actor ShutdownRecordingRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Shutdown test"
    private let issues: [String]
    private var shutdowns = 0
    private var loads = 0
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(issues: [String] = []) { self.issues = issues }

    func loadTasks() async throws -> [AgentTask] {
        loads += 1
        return []
    }

    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> {
        AsyncStream { $0.finish() }
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {}
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}

    func shutdown() async -> RuntimeShutdownReport {
        shutdowns += 1
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            enteredWaiter?.resume()
            enteredWaiter = nil
        }
        return RuntimeShutdownReport(issues: issues)
    }

    func waitUntilShutdownEntered() async {
        if shutdowns > 0 { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func releaseShutdown() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func counts() -> (shutdowns: Int, loads: Int) { (shutdowns, loads) }
}

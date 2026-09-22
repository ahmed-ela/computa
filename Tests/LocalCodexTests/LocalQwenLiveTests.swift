import Foundation
import XCTest
@testable import LocalCodex

@MainActor
final class LocalQwenLiveTests: XCTestCase {
    func testProductionRuntimeCompletesLocalQwenTurn() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_TEST"] == "1",
            "Set LOCALCODEX_LIVE_MODEL_TEST=1 to run against the loaded LM Studio model."
        )

        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexLiveTest-\(UUID().uuidString)", isDirectory: true)
            .path

        let runtime = CodexAppServerRuntime(configuration: configuration)
        let state = AppState(tasks: [], runtime: runtime)
        let eventTask = Task { await state.startRuntime() }
        defer { eventTask.cancel() }

        try await waitUntil("runtime connection", state: state) {
            if case .connected = state.connectionState { return true }
            return false
        }

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let submitted = await state.submit(
            prompt: "Reply with exactly LOCAL_QWEN_OK and do not use tools.",
            toTaskID: taskID
        )
        XCTAssertTrue(submitted, diagnostics(for: state))

        try await waitUntil("completed inference turn", state: state, attempts: 240) {
            guard let task = state.tasks.first(where: { $0.id == taskID }) else { return false }
            return task.status == .completed
                && task.entries.contains {
                    $0.kind == .assistant
                        && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == "LOCAL_QWEN_OK"
                }
        }

        let completedTask = try XCTUnwrap(state.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(completedTask.status, .completed)
        XCTAssertEqual(
            completedTask.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "LOCAL_QWEN_OK"
        )

        let webSnapshot = WebUISnapshot(state: state)
        let webTask = try XCTUnwrap(webSnapshot.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(webTask.status, "Completed")
        XCTAssertEqual(
            webTask.entries.last(where: { $0.kind == "assistant" })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "LOCAL_QWEN_OK"
        )
    }

    private func waitUntil(
        _ operation: String,
        state: AppState,
        attempts: Int = 80,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }

        XCTFail("Timed out waiting for \(operation). \(diagnostics(for: state))")
    }

    private func diagnostics(for state: AppState) -> String {
        let tasks = state.tasks.map { task in
            let entries = task.entries.map { "\($0.kind.rawValue):\($0.body)" }.joined(separator: " | ")
            return "\(task.id)=\(task.status.rawValue)[\(entries)]"
        }.joined(separator: "; ")
        return "connection=\(state.connectionState.label); tasks=\(tasks)"
    }
}

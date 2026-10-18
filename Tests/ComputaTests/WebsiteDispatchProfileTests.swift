import Foundation
import XCTest
@testable import Computa

@MainActor
final class WebsiteDispatchProfileTests: XCTestCase {
    private let task = "7489d029-98e8-4bb0-81cf-54bf7ee7d3ba"
    private let request = "946f2fc9-dcfb-49b4-bfb8-e176be18ed43"
    private let model = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID

    func testOnlyCanonicalIdentifiersAndChatGPTCanProduceProfileMetadata() {
        XCTAssertNil(WebsiteDispatchProfile.begin(taskID: "PRIVATE_TASK_PATH", modelID: model, origin: .webUI))
        XCTAssertNil(WebsiteDispatchProfile.begin(taskID: task, modelID: model, requestID: "PRIVATE_REQUEST", origin: .webUI))
        for other in ["browser/gemini", "browser/claude", "api/cerebras/model/private", "PRIVATE_MODEL"] {
            XCTAssertNil(WebsiteDispatchProfile.begin(taskID: task, modelID: other, origin: .runtime))
        }
        XCTAssertNotNil(WebsiteDispatchProfile.begin(taskID: task, modelID: model, requestID: request, origin: .webUI))
    }

    func testQueueTaskAndRuntimeActorInheritTheSameIngressProfileWithoutLeakingIt() async throws {
        let profile = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: request, origin: .webUI))
        let probe = DispatchProfileActor()
        let inherited = await WebsiteDispatchProfile.$current.withValue(profile) {
            let queued = Task { @MainActor in
                await probe.inherited(taskID: self.task, modelID: self.model)
            }
            return await queued.value
        }
        XCTAssertEqual(inherited, profile)
        XCTAssertNil(WebsiteDispatchProfile.current)
    }

    func testAnotherTaskOrExplicitRequestCannotReuseAnIngressTrace() throws {
        let profile = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: request, origin: .webUI))
        WebsiteDispatchProfile.$current.withValue(profile) {
            XCTAssertEqual(WebsiteDispatchProfile.matching(taskID: task), profile)
            XCTAssertNil(WebsiteDispatchProfile.matching(taskID: UUID().uuidString))
            XCTAssertNil(WebsiteDispatchProfile.begin(taskID: task, modelID: model, requestID: "PRIVATE_REQUEST", origin: .webUI))
            let other = WebsiteDispatchProfile.begin(taskID: task, modelID: model,
                requestID: "f7c2c109-82ea-4f1d-906b-7f6c6e3ebc51", origin: .webUI)
            XCTAssertNotNil(other); XCTAssertNotEqual(other, profile)
        }
        XCTAssertNil(WebsiteDispatchProfile.current)
    }

    func testDiagnosticDurationsAreFiniteNonnegativeAndCapped() {
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.nanoseconds(-1)), 0)
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.zero), 0)
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.microseconds(1_500)), 1)
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.seconds(600)), 600_000)
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.seconds(Int64.max)), 600_000)
    }

    func testFIFOReorderAndDuplicateSchedulingKeepEachItemsOwnIngressProfile() async throws {
        let secondRequest = "f7c2c109-82ea-4f1d-906b-7f6c6e3ebc51"
        let first = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: request, origin: .webUI))
        let second = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: secondRequest, origin: .webUI))
        for reorder in [false, true] {
            let (state, runtime) = fixture(running: true)
            WebsiteDispatchProfile.$current.withValue(first) {
                XCTAssertTrue(state.acceptPrompt(prompt: "First", taskID: task, requestID: request))
            }
            await settleScheduledWork()
            let initiallySent = await runtime.calls
            XCTAssertTrue(initiallySent.isEmpty)
            makeIdle(state)
            WebsiteDispatchProfile.$current.withValue(second) {
                XCTAssertTrue(state.acceptPrompt(prompt: "Second", taskID: task, requestID: secondRequest))
                if reorder, let items = state.queuedPrompts[task] {
                    XCTAssertTrue(state.moveQueuedPrompt(taskID: task, id: items[1].id, beforeID: items[0].id))
                }
            }
            let one = try await observedCalls(1, runtime: runtime)
            XCTAssertEqual(one[0].prompt, reorder ? "Second" : "First")
            XCTAssertEqual(one[0].profile, reorder ? second : first)
            await settleScheduledWork()
            makeIdle(state)
            // A duplicate of the already delivered request schedules the
            // remaining FIFO item. Its task-local trace must not retarget it.
            WebsiteDispatchProfile.$current.withValue(reorder ? second : first) {
                XCTAssertTrue(state.acceptPrompt(prompt: reorder ? "Second" : "First", taskID: task,
                    requestID: reorder ? secondRequest : request))
            }
            let two = try await observedCalls(2, runtime: runtime)
            XCTAssertEqual(two.map(\.prompt), reorder ? ["Second", "First"] : ["First", "Second"])
            XCTAssertEqual(two[1].profile, reorder ? first : second)
            await settleScheduledWork()
            XCTAssertTrue(state.queuedPrompts[task, default: []].isEmpty)
        }
        XCTAssertNil(WebsiteDispatchProfile.current)
    }

    func testEditedOrDeletedQueueItemsCannotReuseTheirOriginalIngressProfile() async throws {
        let original = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: request, origin: .webUI))
        for deleting in [false, true] {
            let (state, runtime) = fixture(running: false)
            WebsiteDispatchProfile.$current.withValue(original) {
                XCTAssertTrue(state.acceptPrompt(prompt: "Original", taskID: task, requestID: request))
                guard let item = state.queuedPrompts[task]?.first else { XCTFail("Expected queued item"); return }
                if deleting {
                    XCTAssertTrue(state.deleteQueuedPrompt(taskID: task, id: item.id))
                    // This direct native submission has no web ingress trace.
                    XCTAssertTrue(state.acceptPrompt(prompt: "Replacement", taskID: task, requestID: "replacement"))
                } else {
                    XCTAssertTrue(state.beginQueueEdit(taskID: task, id: item.id))
                    XCTAssertTrue(state.editQueuedPrompt(taskID: task, id: item.id, prompt: "Edited"))
                }
            }
            let calls = try await observedCalls(1, runtime: runtime)
            XCTAssertEqual(calls[0].prompt, deleting ? "Replacement" : "Edited")
            XCTAssertNil(calls[0].profile)
        }
        XCTAssertNil(WebsiteDispatchProfile.current)
    }

    private func fixture(running: Bool) -> (AppState, DispatchProfileRuntime) {
        let runtime = DispatchProfileRuntime()
        let state = AppState(tasks: [AgentTask(id: task, title: "Dispatch fixture", summary: "",
            status: running ? .running : .draft, workspace: "/tmp", model: model)],
            runtime: runtime, preferences: isolatedTestPreferences())
        if running { state.activeTurnTaskIDs.insert(task) }
        state.connectionState = .connected(provider: runtime.providerName)
        return (state, runtime)
    }

    private func makeIdle(_ state: AppState) {
        state.activeTurnTaskIDs.remove(task)
        state.tasks[0].status = .draft
    }

    private func settleScheduledWork() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func observedCalls(_ count: Int, runtime: DispatchProfileRuntime) async throws -> [DispatchProfileRuntime.Call] {
        for _ in 0..<200 {
            let calls = await runtime.calls
            if calls.count >= count { return calls }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected fake-runtime dispatch was not observed")
        throw DispatchProfileRuntime.Failure()
    }
}

private actor DispatchProfileActor {
    func inherited(taskID: String, modelID: String) -> WebsiteDispatchProfile? {
        WebsiteDispatchProfile.begin(taskID: taskID, modelID: modelID, origin: .runtime)
    }
}

private actor DispatchProfileRuntime: AgentRuntimeClient {
    struct Failure: Error { }
    struct Call: Sendable {
        let prompt: String
        let profile: WebsiteDispatchProfile?
    }
    nonisolated let providerName = "Dispatch fixture runtime"
    private(set) var calls: [Call] = []
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID: AgentTask.ID, modelID: String) async throws {
        calls.append(Call(prompt: prompt, profile: WebsiteDispatchProfile.current))
    }
    func interrupt(taskID: AgentTask.ID) async throws { }
    func resolveApproval(requestID: String, approved: Bool) async throws { }
}

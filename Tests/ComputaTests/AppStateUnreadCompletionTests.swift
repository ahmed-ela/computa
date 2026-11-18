import Foundation
import Observation
import XCTest
@testable import Computa

@MainActor
final class AppStateUnreadCompletionTests: XCTestCase {
    private let thread = "01a19692-9acc-7112-979d-cabc1465b23c"
    private let firstTurn = "01a195e8-ff2a-73e3-b28e-bb1e101dc0bf"
    private let secondTurn = "01a195e7-f241-7210-b74b-dfb9fe987073"

    func testCompletionPersistsAcrossDifferentRestoredTaskIDAndExplicitRead() throws {
        let store = try makeStore()
        let local = task(id: UUID().uuidString)
        let state = state([local], store: store)
        state.apply(.taskThreadBound(taskID: local.id, threadID: thread))
        state.apply(.taskStatusChanged(taskID: local.id, status: .running))
        state.apply(.taskCompletionObserved(taskID: local.id, threadID: thread, turnID: firstTurn))
        XCTAssertFalse(state.acknowledgeTaskCompletion(taskID: local.id, completionID: firstTurn), "Before terminal status the rendered view cannot acknowledge completion.")
        state.apply(.taskStatusChanged(taskID: local.id, status: .completed))
        XCTAssertTrue(state.hasUnreadCompletion(for: local.id), "Being selected is not a read acknowledgement.")
        XCTAssertEqual(WebUISnapshot(state: state).tasks.first?.unreadCompletionID, firstTurn)

        let restored = task(id: thread, thread: thread, status: .completed)
        let restarted = self.state([restored], store: store)
        XCTAssertNotEqual(restored.id, local.id)
        XCTAssertEqual(restarted.selectedTaskID, restored.id)
        restarted.apply(.tasksSnapshot([restored]))
        XCTAssertTrue(WebUISnapshot(state: restarted).tasks[0].hasUnreadCompletion)
        restarted.selectTask(restored.id)
        XCTAssertFalse(restarted.hasUnreadCompletion(for: restored.id))
        let readRestart = self.state([restored], store: store)
        readRestart.apply(.taskCompletionObserved(taskID: restored.id, threadID: thread, turnID: firstTurn))
        XCTAssertFalse(readRestart.hasUnreadCompletion(for: restored.id), "Duplicate completion stays read even after restart.")
        XCTAssertEqual(try store.load()[thread]?.completionID, firstTurn)
    }

    func testHistoricalCompletedAndFailedTasksDoNotBecomeUnreadOnUpgrade() throws {
        let state = state([task(id: "history", thread: thread, status: .completed)], store: try makeStore())
        state.apply(.taskStatusChanged(taskID: "history", status: .completed))
        XCTAssertFalse(state.hasUnreadCompletion(for: "history"))
        state.apply(.taskStatusChanged(taskID: "history", status: .failed))
        XCTAssertEqual(state.tasks.first?.status, .failed)
        XCTAssertFalse(WebUISnapshot(state: state).tasks[0].hasUnreadCompletion)
    }

    func testExactVisibleAcknowledgementIsObservedAndCannotReadAnotherOrNewCompletion() throws {
        let state = state([task(id: "local", thread: thread), task(id: "other")], store: try makeStore())
        complete(state, turn: firstTurn)
        state.selectTask("other")
        XCTAssertFalse(state.acknowledgeTaskCompletion(taskID: "local", completionID: firstTurn))
        // Restoration selects the task without acting as a user read.
        state.apply(.tasksSnapshot([task(id: "local", thread: thread, status: .completed)]))
        XCTAssertTrue(state.hasUnreadCompletion(for: "local"))
        XCTAssertFalse(state.acknowledgeTaskCompletion(taskID: "local", completionID: secondTurn))
        let changed = expectation(description: "read change publishes an observable snapshot")
        withObservationTracking { _ = WebUISnapshot(state: state) } onChange: { changed.fulfill() }
        XCTAssertTrue(state.acknowledgeTaskCompletion(taskID: "local", completionID: firstTurn))
        wait(for: [changed], timeout: 0.1)
        XCTAssertFalse(WebUISnapshot(state: state).tasks[0].hasUnreadCompletion)
        XCTAssertNil(WebUISnapshot(state: state).tasks[0].unreadCompletionID)
        complete(state, turn: secondTurn)
        XCTAssertFalse(state.acknowledgeTaskCompletion(taskID: "local", completionID: firstTurn))
        XCTAssertEqual(state.unreadCompletionID(for: "local"), secondTurn)
    }

    func testNewTurnClearsOldUnreadButRetainsDedupIdentityAndNextCompletionIsNew() throws {
        let store = try makeStore(), state = state([task(id: "local", thread: thread)], store: nil)
        complete(state, turn: firstTurn)
        state.apply(.taskStatusChanged(taskID: "local", status: .running))
        XCTAssertFalse(state.hasUnreadCompletion(for: "local"))
        state.apply(.taskCompletionObserved(taskID: "local", threadID: thread, turnID: firstTurn))
        XCTAssertFalse(state.hasUnreadCompletion(for: "local"))
        XCTAssertFalse(state.acknowledgeTaskCompletion(taskID: "local", completionID: firstTurn))
        complete(state, turn: secondTurn)
        XCTAssertEqual(state.unreadCompletionID(for: "local"), secondTurn)
        // Persisted records also retain the completion ID on the new-turn clear.
        let durable = self.state([task(id: "local", thread: thread)], store: store)
        complete(durable, turn: firstTurn)
        durable.apply(.taskStatusChanged(taskID: "local", status: .running))
        XCTAssertEqual(try store.load()[thread], .init(completionID: firstTurn, hasUnreadCompletion: false))
    }

    func testReplacementPreservesStableBindingAndRejectsForeignOrUnknownEvents() throws {
        let state = state([task(id: "local")], store: try makeStore())
        state.apply(.taskThreadBound(taskID: "local", threadID: thread.uppercased()))
        complete(state, turn: firstTurn)
        state.apply(.taskUpserted(task(id: "local", status: .completed)))
        state.apply(.tasksSnapshot([task(id: "local", status: .completed)]))
        XCTAssertEqual(state.tasks[0].runtimeThreadID, thread)
        XCTAssertEqual(state.unreadCompletionID(for: "local"), firstTurn)
        state.apply(.taskCompletionObserved(taskID: "local", threadID: UUID().uuidString, turnID: secondTurn))
        state.apply(.taskCompletionObserved(taskID: "unknown", threadID: thread, turnID: secondTurn))
        state.apply(.taskCompletionObserved(taskID: "local", threadID: thread, turnID: "invalid"))
        XCTAssertEqual(state.unreadCompletionID(for: "local"), firstTurn)
    }

    func testPersistenceFailureRetainsUnreadAndDoesNotCorruptPriorFileOrBlockCompletion() throws {
        let store = try makeStore()
        let state = state([task(id: "local", thread: thread)], store: store)
        complete(state, turn: firstTurn)
        let original = try Data(contentsOf: store.fileURL)
        let corrupt = Data("preserve unread-store corruption evidence".utf8)
        try corrupt.write(to: store.fileURL)
        state.selectTask("local")
        XCTAssertTrue(state.hasUnreadCompletion(for: "local"))
        XCTAssertTrue(state.unreadCompletionPersistenceFailed)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
        complete(state, turn: secondTurn)
        XCTAssertEqual(state.tasks[0].status, .completed)
        XCTAssertEqual(state.unreadCompletionID(for: "local"), secondTurn)
        XCTAssertFalse(state.acknowledgeTaskCompletion(taskID: "local", completionID: secondTurn))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
        try original.write(to: store.fileURL)
        XCTAssertTrue(state.acknowledgeTaskCompletion(taskID: "local", completionID: secondTurn))
        XCTAssertFalse(state.unreadCompletionPersistenceFailed)
        XCTAssertEqual(try store.load()[thread], .init(completionID: secondTurn, hasUnreadCompletion: false))
        try corrupt.write(to: store.fileURL)
        let unreadable = self.state([task(id: "local", thread: thread)], store: store)
        XCTAssertTrue(unreadable.unreadCompletionPersistenceFailed)
        complete(unreadable, turn: firstTurn)
        XCTAssertTrue(unreadable.hasUnreadCompletion(for: "local"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testSnapshotDefaultsForOlderPayloadAndUnreadRoundTrip() throws {
        let snapshot = WebTaskSnapshot(task(id: "local"), hasUnreadCompletion: true, unreadCompletionID: firstTurn)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let encoded = try encoder.encode(snapshot)
        XCTAssertEqual(try decoder.decode(WebTaskSnapshot.self, from: encoded), snapshot)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "hasUnreadCompletion"); legacy.removeValue(forKey: "unreadCompletionID")
        let decoded = try decoder.decode(WebTaskSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(decoded.hasUnreadCompletion)
        XCTAssertNil(decoded.unreadCompletionID)
    }

    private func task(id: String, thread: String? = nil, status: TaskStatus = .draft) -> AgentTask {
        AgentTask(id: id, runtimeThreadID: thread, title: "Synthetic task", summary: "", status: status,
                  workspace: "/tmp", model: "local-test")
    }
    private func state(_ tasks: [AgentTask], store: ChatUnreadCompletionStore?) -> AppState {
        AppState(tasks: tasks, preferences: isolatedTestPreferences(), unreadCompletionStore: store)
    }
    private func complete(_ state: AppState, turn: String) {
        state.apply(.taskCompletionObserved(taskID: "local", threadID: thread, turnID: turn))
        state.apply(.taskStatusChanged(taskID: "local", status: .completed))
    }
    private func makeStore() throws -> ChatUnreadCompletionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnreadState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return ChatUnreadCompletionStore(fileURL: root.appendingPathComponent("completions.json"))
    }
}

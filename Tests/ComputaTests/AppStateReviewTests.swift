import Foundation
import XCTest
@testable import Computa

@MainActor
final class AppStateReviewTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("computa-review-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func task(_ root: URL, id: String = "task", status: TaskStatus = .draft) -> AgentTask {
        AgentTask(id: id, title: "Code task", summary: "", status: status, workspace: root.path, model: LocalModelCatalog.chatGPTBrowserModelID)
    }

    func testNativeTurnDiffAndFileChangesRemainVisibleWithoutRawToolPayloads() async throws {
        let root = try root()
        let state = AppState(tasks: [task(root)], preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let patch = "diff --git a/code.swift b/code.swift\n--- a/code.swift\n+++ b/code.swift\n@@ -1 +1 @@\n-let value = 1\n+let value = 2\n"
        state.apply(.turnDiffUpdated(taskID: "task", turnID: "turn", diff: patch))
        state.apply(.timelineEntryAppended(taskID: "task", entry: TimelineEntry(id: "patch", kind: .tool, title: "File changes", body: "Changed one file",
            toolEvent: ToolEvent(name: "fileChange", summary: "Changed", status: .succeeded, input: "private raw payload", output: nil, duration: nil),
            fileChanges: [AgentFileChange(path: root.appendingPathComponent("code.swift").path, kind: "update", movePath: nil, diff: patch)], turnID: "turn")))
        let snapshot = WebUISnapshot(state: state)
        XCTAssertEqual(snapshot.tasks.first?.entries.first?.fileChanges?.first?.diff, patch)
        XCTAssertEqual(snapshot.tasks.first?.entries.first?.tool?.input, "")
        state.isReviewPresented = true
        await state.refreshReview(taskID: "task")
        XCTAssertEqual(state.review?.snapshot?.scope, .lastTurn)
        XCTAssertEqual(state.review?.snapshot?.files.first?.path, "code.swift")
        XCTAssertEqual(state.review?.snapshot?.files.first?.additions, 1)
        XCTAssertEqual(state.review?.snapshot?.canRevert, false)
        let encoded = try JSONEncoder().encode(WebUISnapshot(state: state))
        XCTAssertEqual(try JSONDecoder().decode(WebUISnapshot.self, from: encoded).review, state.review)
    }

    func testDiffEventsUpdateTheirOwnTurnWithoutDuplicatingOrRetargetingTasks() throws {
        let root = try root()
        let state = AppState(tasks: [task(root), task(root, id: "other")])
        state.apply(.turnDiffUpdated(taskID: "other", turnID: "one", diff: "first"))
        state.apply(.turnDiffUpdated(taskID: "other", turnID: "two", diff: "second"))
        state.apply(.turnDiffUpdated(taskID: "other", turnID: "one", diff: "updated first"))
        state.apply(.turnDiffUpdated(taskID: "missing", turnID: "one", diff: "not owned"))
        XCTAssertTrue(state.tasks[0].turnDiffs.isEmpty)
        XCTAssertEqual(state.tasks[1].turnDiffs, [.init(id: "one", diff: "updated first"), .init(id: "two", diff: "second")])
        XCTAssertEqual(state.selectedTaskID, "task")
    }

    func testLastTurnSupplementsOnlyCompletedRenameReceiptsFromThatTurn() async throws {
        let root = try root()
        let state = AppState(tasks: [task(root)])
        state.apply(.turnDiffUpdated(taskID: "task", turnID: "latest", diff: ""))
        for (id, turn, status) in [("applied", "latest", ToolRunStatus.succeeded),
                                  ("proposed", "latest", .running), ("failed", "latest", .failed),
                                  ("historical", "earlier", .succeeded)] {
            state.apply(.timelineEntryAppended(taskID: "task", entry: TimelineEntry(id: id, kind: .tool,
                title: "File changes", body: id,
                toolEvent: ToolEvent(name: "fileChange", summary: id, status: status, input: "", output: nil, duration: nil),
                fileChanges: [.init(path: root.appendingPathComponent(id + ".py").path, kind: "update",
                    movePath: root.appendingPathComponent(id + "-moved.py").path, diff: "")], turnID: turn)))
        }
        state.isReviewPresented = true
        await state.refreshReview(taskID: "task")
        XCTAssertEqual(state.review?.snapshot?.files.map(\.path), ["applied-moved.py"])
        XCTAssertEqual(state.review?.snapshot?.files.first?.previousPath, "applied.py")
        XCTAssertEqual(state.review?.snapshot?.canRevert, false)
    }

    func testCompletedPureMoveRefreshesOpenLastTurnWithoutAggregateNotification() async throws {
        let root = try root()
        let state = AppState(tasks: [task(root, status: .running)])
        state.apply(.turnDiffUpdated(taskID: "task", turnID: "turn", diff: ""))
        state.toggleReview()
        try await waitForReview { state.review?.snapshot?.files.isEmpty == true && state.review?.loading == false }
        let initialID = try XCTUnwrap(state.review?.snapshot?.id)
        func move(_ status: ToolRunStatus) -> TimelineEntry {
            TimelineEntry(id: "move", kind: .tool, title: "File changes", body: "Move file",
                toolEvent: ToolEvent(name: "fileChange", summary: "Move file", status: status, input: "", output: nil, duration: nil),
                fileChanges: [.init(path: root.appendingPathComponent("old.swift").path, kind: "update",
                    movePath: root.appendingPathComponent("new.swift").path, diff: "")], turnID: "turn")
        }
        state.apply(.timelineEntryAppended(taskID: "task", entry: move(.running)))
        XCTAssertEqual(state.review?.snapshot?.id, initialID)
        state.apply(.timelineEntryAppended(taskID: "task", entry: move(.succeeded)))
        try await waitForReview { state.review?.snapshot?.files.first?.path == "new.swift" && state.review?.loading == false }
        XCTAssertNotEqual(state.review?.snapshot?.id, initialID)
        XCTAssertEqual(state.review?.snapshot?.files.first?.previousPath, "old.swift")
        XCTAssertEqual(state.review?.snapshot?.files.first?.diff, "rename from \"old.swift\"\nrename to \"new.swift\"\n")
        XCTAssertEqual(state.tasks[0].entries.count, 1)
        XCTAssertEqual(state.tasks[0].turnDiffs, [.init(id: "turn", diff: "")], "No aggregate notification was needed after the move")
        state.toggleReview()
    }

    func testTaskCompletionRefreshesOpenUnstagedReviewAfterShellStyleWrite() async throws {
        let root = try root()
        let file = root.appendingPathComponent("code.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        try git(root: root, arguments: ["init", "-q"])
        try git(root: root, arguments: ["add", "code.swift"])
        try git(root: root, arguments: ["commit", "-qm", "Review fixture"])
        let state = AppState(tasks: [task(root, status: .running)])
        state.toggleReview()
        state.setReviewScope(.unstaged, taskID: "task")
        try await waitForReview { state.review?.snapshot?.scope == .unstaged && state.review?.snapshot?.files.isEmpty == true && state.review?.loading == false }
        let initialID = try XCTUnwrap(state.review?.snapshot?.id)
        try Data("let value = 2\n".utf8).write(to: file)
        XCTAssertEqual(state.review?.snapshot?.id, initialID)
        state.apply(.taskStatusChanged(taskID: "task", status: .completed))
        try await waitForReview { state.review?.snapshot?.files.first?.diff.contains("+let value = 2") == true && state.review?.loading == false }
        XCTAssertEqual(state.review?.snapshot?.scope, .unstaged)
        XCTAssertEqual(state.review?.snapshot?.files.first?.path, "code.swift")
        XCTAssertNotEqual(state.review?.snapshot?.id, initialID)
        XCTAssertTrue(state.tasks[0].turnDiffs.isEmpty, "The refresh came from completion, not a patch aggregate")
        XCTAssertTrue(state.tasks[0].entries.isEmpty, "Shell writes need no native file-change item")
        XCTAssertEqual(state.tasks[0].status, .completed)
        state.toggleReview()
    }

    func testPatchStreamingAndCompletionUpdateOneOwnedCardWithoutLateProposalOverwrite() throws {
        let state = AppState(tasks: [task(try root())])
        func entry(_ status: ToolRunStatus, turn: String = "turn", text: String) -> TimelineEntry {
            TimelineEntry(id: "patch", kind: .tool, title: "File changes", body: text,
                toolEvent: ToolEvent(name: "fileChange", summary: text, status: status, input: "", output: nil, duration: nil),
                fileChanges: [.init(path: "file", kind: "update", movePath: nil, diff: text)], turnID: turn)
        }
        state.apply(.timelineEntryAppended(taskID: "task", entry: entry(.running, text: "proposed")))
        state.apply(.timelineEntryAppended(taskID: "task", entry: entry(.succeeded, text: "applied")))
        state.apply(.timelineEntryAppended(taskID: "task", entry: entry(.running, text: "late proposal")))
        state.apply(.timelineEntryAppended(taskID: "task", entry: entry(.failed, turn: "foreign", text: "wrong owner")))
        XCTAssertEqual(state.tasks[0].entries.count, 1)
        XCTAssertEqual(state.tasks[0].entries[0].body, "applied")
        XCTAssertEqual(state.tasks[0].entries[0].fileChanges?.first?.diff, "applied")
    }

    func testReviewSelectionAndMutationRequireCurrentNativeReceipt() async throws {
        let root = try root()
        let state = AppState(tasks: [task(root), task(root, id: "other")])
        state.isReviewPresented = true
        await state.refreshReview(taskID: "task")
        let id = try XCTUnwrap(state.review?.snapshot?.id)
        await state.mutateReview(taskID: "other", snapshotID: id, operation: .revert, fileID: nil, hunkID: nil)
        await state.mutateReview(taskID: "task", snapshotID: "invented", operation: .stage, fileID: nil, hunkID: nil)
        XCTAssertEqual(state.review?.snapshot?.id, id)
        state.selectTask("other")
        XCTAssertNil(state.review)
        state.isReviewPresented = false
    }

    func testDraftWorkspaceChoiceDoesNotRetargetSavedOrRunningChats() async throws {
        let first = try root(), chosen = try root()
        let runtime = ReviewWorkspaceRuntime()
        let state = AppState(tasks: [task(first)], runtime: runtime)
        try await state.setTaskWorkspace(chosen, taskID: "task")
        XCTAssertEqual(state.selectedTask?.workspace, chosen.path)
        let initialPaths = await runtime.paths()
        XCTAssertEqual(initialPaths, [chosen.path])
        state.tasks[0].entries.append(TimelineEntry(kind: .user, title: "You", body: "Saved conversation"))
        XCTAssertFalse(state.canChooseTaskWorkspace)
        try await state.setTaskWorkspace(first, taskID: "task")
        XCTAssertEqual(state.selectedTask?.workspace, chosen.path)
        let unchangedPaths = await runtime.paths()
        XCTAssertEqual(unchangedPaths, [chosen.path])
    }

    private func waitForReview(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "AppStateReviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The runtime event did not refresh the review."])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func git(root: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                             "-c", "user.name=Computa review fixture", "-c", "user.email=fixture@example.invalid",
                             "-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        try process.run()
        let errors = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AppStateReviewGitFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)])
        }
    }
}

private actor ReviewWorkspaceRuntime: AgentRuntimeClient {
    nonisolated let providerName = "Review fixture"
    private var configured = [String]()
    func paths() -> [String] { configured }
    func configureWorkspace(path: String, forTaskID taskID: String) async throws { configured.append(path) }
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: String, modelID: String) async throws {}
    func interrupt(taskID: String) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

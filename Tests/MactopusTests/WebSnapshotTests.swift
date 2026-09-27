import XCTest
@testable import Mactopus

final class WebSnapshotTests: XCTestCase {
    func testActivityMetadataRoundTripsWithoutRequiringItOnOldEntries() throws {
        let entry = TimelineEntry(id: "answer", kind: .assistant, title: "Mactopus", body: "Answer",
                                  activityGroupID: "original-user", assistantPhase: "final_answer")
        let snapshot = WebTaskSnapshot(AgentTask(
            id: "task", title: "Task", summary: "", status: .running,
            workspace: "/tmp", model: "local", entries: [entry]
        ), activeTurnStartedAt: 100, activeActivityGroupID: "original-user")
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WebTaskSnapshot.self, from: encoded)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.activeActivityGroupID, "original-user")
        XCTAssertEqual(decoded.entries.first?.activityGroupID, "original-user")
        XCTAssertEqual(decoded.entries.first?.assistantPhase, "final_answer")

        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "activeActivityGroupID")
        var oldEntries = try XCTUnwrap(old["entries"] as? [[String: Any]])
        oldEntries[0].removeValue(forKey: "activityGroupID")
        oldEntries[0].removeValue(forKey: "assistantPhase")
        old["entries"] = oldEntries
        let oldSnapshot = try JSONDecoder().decode(WebTaskSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(oldSnapshot.activeActivityGroupID)
        XCTAssertNil(oldSnapshot.entries.first?.activityGroupID)
        XCTAssertNil(oldSnapshot.entries.first?.assistantPhase)
    }

    @MainActor
    func testReasoningStreamingFlagSurvivesSnapshotSerialization() throws {
        let entries = [
            TimelineEntry(id: "thought", kind: .reasoning, title: "Thinking", body: "Checking a step", isStreaming: true),
            TimelineEntry(id: "answer", kind: .assistant, title: "Mactopus", body: "Final answer"),
        ]
        let state = AppState(tasks: [AgentTask(
            id: "task", title: "Test", summary: "", status: .running,
            workspace: "/tmp", model: "local", entries: entries
        )], preferences: isolatedTestPreferences())
        let snapshot = WebUISnapshot(state: state)
        XCTAssertEqual(snapshot.tasks.first?.entries.map(\.isStreaming), [true, false])
        let decoded = try JSONDecoder().decode(WebUISnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.tasks.first?.entries.first?.kind, "reasoning")
        XCTAssertEqual(decoded.tasks.first?.entries.first?.body, "Checking a step")
    }

    @MainActor
    func testAccessModeIsReadOnlySnapshotStateAndFullAccessDoesNotShowManualGate() {
        let state = AppState(tasks: [], preferences: isolatedTestPreferences())
        XCTAssertEqual(WebUISnapshot(state: state).accessMode, "askEveryTime")
        state.pendingApprovals = [.init(id: "test", taskID: nil, kind: .computerUse,
            title: "Test", summary: "", details: "")]
        XCTAssertEqual(WebUISnapshot(state: state).pendingApprovalCount, 1)
        state.setAccessMode(.fullAccess)
        XCTAssertEqual(WebUISnapshot(state: state).accessMode, "fullAccess")
        XCTAssertEqual(WebUISnapshot(state: state).pendingApprovalCount, 0)
        state.setAccessMode(.askEveryTime)
        XCTAssertEqual(WebUISnapshot(state: state).accessMode, "askEveryTime")
    }

    @MainActor
    func testApprovalGateStaysActiveDuringResolutionAndForUnownedRequests() {
        let state = AppState(tasks: [AgentTask(title: "Queue", summary: "", status: .completed, workspace: "/tmp", model: "local")], preferences: isolatedTestPreferences())
        let taskID = state.tasks[0].id
        state.resolvingApprovalIDs = ["settling"]
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertEqual(WebUISnapshot(state: state).pendingApprovalCount, 1)
        XCTAssertTrue(state.isBusy(taskID: taskID))
        state.resolvingApprovalIDs = []
        state.pendingApprovals = [.init(id: "unowned", taskID: nil, kind: .computerUse, title: "Approve", summary: "", details: "")]
        XCTAssertTrue(state.isBusy(taskID: taskID))
        XCTAssertFalse(state.canSteer(taskID: taskID))
    }

    @MainActor
    func testMactopusBrandingKeepsNativeBridgeCompatibility() throws {
        XCTAssertEqual(TimelineEntryKind.assistant.label, "Mactopus")
        XCTAssertTrue(CodexAppServerRuntime.Configuration.localQwen.baseInstructions.hasPrefix("You are Mactopus."))
        XCTAssertEqual(WebBridge.handlerName, "localCodex")
        XCTAssertEqual(WebUIResourceLocator.scheme, "localcodex-app")
        let index = try XCTUnwrap(WebUIResourceLocator.indexURL)
        let html = try String(contentsOf: index, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Mactopus</title>"))
        XCTAssertTrue(html.contains("Fast, Mac-optimized local AI."))
        XCTAssertFalse(html.contains("<title>LocalCodex</title>"))
    }

    func testMactopusRetainsInstalledVisualModels() throws {
        let configuration = try VisualGroundingConfiguration.local(environment: [:])
        XCTAssertTrue(configuration.modelRoot.path.hasSuffix("/LocalCodex/VisualGrounding/models"))
        XCTAssertTrue(configuration.pythonExecutable.path.hasSuffix("/LocalCodex/VisualGrounding/venv/bin/python"))
    }

    @MainActor
    func testSnapshotMapsPresentationStateWithoutWeakeningApprovalGate() throws {
        let task = AgentTask(
            id: "task-1",
            title: "Inspect the bridge",
            summary: "Native state rendered by Octane",
            status: .running,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            workspace: "/tmp/workspace",
            model: "local-model",
            branch: "main",
            entries: [
                TimelineEntry(
                    id: "entry-1",
                    kind: .assistant,
                    title: "Mactopus",
                    body: "Rendered as text <script>alert('no')</script>",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_010),
                    workedForSeconds: 65
                ),
                TimelineEntry(
                    id: "entry-tool",
                    kind: .tool,
                    title: "Sensitive tool",
                    body: "Tool result",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_011),
                    toolEvent: ToolEvent(
                        name: "secret-tool",
                        summary: "Sensitive payload",
                        status: .succeeded,
                        input: "tool-input-secret",
                        output: "tool-output-secret"
                    )
                )
            ]
        )
        let inactiveTask = AgentTask(
            id: "task-2",
            title: "Inactive task",
            summary: "Sidebar only",
            status: .waiting,
            workspace: "/tmp/inactive",
            model: "local-model",
            entries: [
                TimelineEntry(
                    id: "inactive-entry",
                    kind: .assistant,
                    title: "Mactopus",
                    body: "inactive-transcript-secret"
                )
            ]
        )
        let state = AppState(tasks: [task, inactiveTask], preferences: isolatedTestPreferences())
        state.queuedPrompts[task.id] = [QueuedPrompt(id: "queue-1", text: "Next local step")]
        state.queuedPrompts[inactiveTask.id] = [QueuedPrompt(text: "inactive-queue-secret")]
        state.pausedQueueTaskIDs.insert(task.id)
        state.showToolPayloads = false
        state.pendingApprovals = [
            ActionApprovalRequest(
                id: "approval-1",
                taskID: task.id,
                kind: .computerUse,
                title: "Allow a desktop action?",
                summary: "Press a button",
                details: "snapshot-scoped element"
            )
        ]
        state.resolvingApprovalIDs = ["approval-1"]

        let snapshot = WebUISnapshot(state: state)

        XCTAssertEqual(snapshot.tasks.first?.statusTone, "blue")
        XCTAssertEqual(snapshot.tasks.first?.entries.first?.body, task.entries.first?.body)
        XCTAssertEqual(snapshot.tasks.first?.entries.first?.workedForSeconds, 65)
        XCTAssertNil(snapshot.tasks.first?.activeTurnStartedAt)
        XCTAssertEqual(snapshot.tasks.first?.entries.last?.tool?.input, "")
        XCTAssertNil(snapshot.tasks.first?.entries.last?.tool?.output)
        XCTAssertTrue(snapshot.tasks.last?.entries.isEmpty == true)
        XCTAssertEqual(snapshot.pendingApprovalCount, 1)
        XCTAssertFalse(snapshot.tasks.first?.modelSelectable ?? true)
        XCTAssertEqual(snapshot.tasks.first?.queuedPrompts.first?.text, "Next local step")
        XCTAssertTrue(snapshot.tasks.first?.queuePaused == true)
        XCTAssertTrue(snapshot.tasks.first?.isBusy == true)
        XCTAssertFalse(snapshot.tasks.first?.canSteer ?? true)
        XCTAssertTrue(snapshot.tasks.last?.queuedPrompts.isEmpty == true)
        XCTAssertEqual(snapshot.modelOptions.map(\.id), LocalModelCatalog.options.map(\.id))

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("approval-1"))
        XCTAssertFalse(encodedText.contains("snapshot-scoped element"))
        XCTAssertFalse(encodedText.contains("tool-input-secret"))
        XCTAssertFalse(encodedText.contains("tool-output-secret"))
        XCTAssertFalse(encodedText.contains("inactive-transcript-secret"))
        XCTAssertFalse(encodedText.contains("inactive-queue-secret"))
        let decoded = try JSONDecoder().decode(WebUISnapshot.self, from: encoded)
        XCTAssertEqual(decoded, snapshot)
    }

    func testBundledOctaneEntryPointAndAssetsExist() throws {
        let indexURL = try XCTUnwrap(WebUIResourceLocator.indexURL)
        let html = try String(contentsOf: indexURL, encoding: .utf8)

        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("./assets/"))

        let assetsURL = indexURL.deletingLastPathComponent().appendingPathComponent("assets")
        let assets = try FileManager.default.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(assets.contains { $0.pathExtension == "js" })
        XCTAssertTrue(assets.contains { $0.pathExtension == "css" })
        XCTAssertFalse(assets.contains { $0.pathExtension == "map" })

        let noticeURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent("THIRD_PARTY_NOTICES.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: noticeURL.path))
    }

    func testWebResourceSchemeOnlyMapsBundledOrigin() throws {
        XCTAssertNotNil(WebUIResourceLocator.fileURL(for: WebUIResourceLocator.appURL))
        XCTAssertFalse(WebUIResourceLocator.contains(URL(string: "https://example.com/index.html")))
        XCTAssertFalse(WebUIResourceLocator.contains(URL(string: "localcodex-app://other/index.html")))
        XCTAssertNil(WebUIResourceLocator.fileURL(for: try XCTUnwrap(
            URL(string: "localcodex-app://ui/%2E%2E/Info.plist")
        )))
    }
}

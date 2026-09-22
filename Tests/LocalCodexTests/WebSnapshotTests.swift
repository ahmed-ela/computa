import XCTest
@testable import LocalCodex

final class WebSnapshotTests: XCTestCase {
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
                    title: "LocalCodex",
                    body: "Rendered as text <script>alert('no')</script>",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_010)
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
                    title: "LocalCodex",
                    body: "inactive-transcript-secret"
                )
            ]
        )
        let state = AppState(tasks: [task, inactiveTask])
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
        XCTAssertEqual(snapshot.tasks.first?.entries.last?.tool?.input, "")
        XCTAssertNil(snapshot.tasks.first?.entries.last?.tool?.output)
        XCTAssertTrue(snapshot.tasks.last?.entries.isEmpty == true)
        XCTAssertEqual(snapshot.pendingApprovalCount, 1)

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("approval-1"))
        XCTAssertFalse(encodedText.contains("snapshot-scoped element"))
        XCTAssertFalse(encodedText.contains("tool-input-secret"))
        XCTAssertFalse(encodedText.contains("tool-output-secret"))
        XCTAssertFalse(encodedText.contains("inactive-transcript-secret"))
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

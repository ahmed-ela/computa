import AutomationCore
import Foundation
import XCTest
@testable import Computa

/// Real Swift Core/owned-child transport, with no model or computer operations.
@MainActor
final class RuntimeIsolationTransportTests: XCTestCase {
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
    private let prompt = "Keep this exact fixture prompt: 東京 👋\nNo rewriting."

    private struct NoModelVisualGrounder: VisualGroundingClient {
        func prepare() async throws {}
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw NSError(domain: "NoGroundingInIsolationFixture", code: 1)
        }
        func shutdown() async -> [String] { [] }
    }

    func testNewThreadReceivesOnlyAppOwnedInstructionsAndPrivateChildState() async throws {
        try await checkSubmission(mode: "new", expectedThreadMethod: "thread/start")
    }

    func testColdExistingThreadReceivesOnlyAppOwnedInstructionsAndPrivateChildState() async throws {
        try await checkSubmission(mode: "resume", expectedThreadMethod: "thread/resume")
    }

    private final class Audit {
        var completed = false
        var assistant = [String]()
        func record(_ event: AgentRuntimeEvent) {
            switch event {
            case .taskStatusChanged(_, let status): completed = status == .completed
            case .timelineEntryAppended(_, let entry):
                if entry.kind == .assistant { assistant.append(entry.body) }
            default: break
            }
        }
    }

    private func checkSubmission(mode: String, expectedThreadMethod: String) async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaIsolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let root = location.resolvingSymlinksInPath()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IsolationAppServer.ts")
        let executable = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(mode.utf8).write(to: root.appendingPathComponent("scenario"))
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.executable = .fixture(path: executable.path)
        configuration.codexHomePath = root.path
        configuration.workspacePath = AgentRuntimeIsolation.workspaceURL(codexHomePath: root.path).path
        let runtime = CodexAppServerRuntime(configuration: configuration, visualGrounder: NoModelVisualGrounder())
        let audit = Audit()
        let events = Task { for await event in runtime.events() { audit.record(event) } }
        do {
            let tasks = try await runtime.loadTasks()
            XCTAssertEqual(tasks.map(\.id), mode == "resume" ? ["isolation-existing-thread"] : [])
            let taskID = mode == "resume" ? "isolation-existing-thread" : "isolation-new-task"
            try await runtime.submit(prompt: prompt, toTaskID: taskID, modelID: modelID)
            for _ in 0..<500 {
                if audit.completed { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(audit.completed, "Fixture turn did not complete")
            XCTAssertEqual(audit.assistant, ["ISOLATION_TRANSPORT_OK"])
            try assertRecordedIsolation(root: root, configuration: configuration, threadMethod: expectedThreadMethod)
            let report = await runtime.shutdown()
            events.cancel()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            if report.succeeded { try FileManager.default.removeItem(at: root) }
        } catch {
            let report = await runtime.shutdown()
            events.cancel()
            if report.succeeded { try? FileManager.default.removeItem(at: root) }
            throw error
        }
    }

    private func assertRecordedIsolation(
        root: URL, configuration: CodexAppServerRuntime.Configuration, threadMethod: String
    ) throws {
        let child = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("child.json"))) as? [String: Any])
        XCTAssertEqual(child["home"] as? String, AgentRuntimeIsolation.processHomeURL(codexHomePath: root.path).path)
        XCTAssertEqual(child["codexHome"] as? String, root.path)
        // getcwd reports the physical /private/var path while Foundation can
        // spell the same macOS temporary directory through /var's symlink.
        let childCWD = try XCTUnwrap(child["cwd"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: childCWD).resolvingSymlinksInPath(),
                       URL(fileURLWithPath: configuration.workspacePath).resolvingSymlinksInPath())
        // The CLI implementation deliberately includes these two fixed tool
        // directories; no caller-specific PATH or shell initialization is inherited.
        XCTAssertEqual(child["path"] as? String, "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        let keys = Set(try XCTUnwrap(child["environmentKeys"] as? [String]))
        var expectedEnvironment = AgentRuntimeIsolation.environment(
            inheriting: ProcessInfo.processInfo.environment,
            userHomePath: AgentRuntimeIsolation.processHomeURL(codexHomePath: root.path).path,
            codexHomePath: root.path
        )
        for key in ["CODEX_OSS_BASE_URL", "CODEX_OSS_PORT"] {
            expectedEnvironment[key] = ProcessInfo.processInfo.environment[key]
        }
        XCTAssertEqual(keys, Set(expectedEnvironment.keys))
        let lines = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        let requests = try lines.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let threadRequests = requests.filter { ["thread/start", "thread/resume"].contains($0["method"] as? String ?? "") }
        XCTAssertEqual(threadRequests.map { $0["method"] as? String }, [threadMethod])
        let params = try XCTUnwrap(threadRequests.first?["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, configuration.workspacePath)
        // New chats receive reference tools; the cold legacy fixture has no
        // persisted reference-tool marker and must retain its legacy contract.
        XCTAssertEqual(params["developerInstructions"] as? String,
                       ComputaAgentInstructions.developerInstructions(referenceTools: threadMethod == "thread/start"))
        let config = try XCTUnwrap(params["config"] as? [String: Any])
        XCTAssertEqual(config["project_root_markers"] as? [String], [])
        XCTAssertNil(config["project_doc_max_bytes"])
        for key in ["developerInstructions", "baseInstructions"] {
            let instructions = try XCTUnwrap(params[key] as? String)
            XCTAssertFalse(instructions.localizedCaseInsensitiveContains("StudyLock"))
            XCTAssertFalse(instructions.contains("Permanent Non-Bypass Policy"))
        }
        let turnRequests = requests.filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual(turnRequests.count, 1)
        let turn = try XCTUnwrap(turnRequests.first?["params"] as? [String: Any])
        let inputs = try XCTUnwrap(turn["input"] as? [[String: String]])
        XCTAssertEqual(inputs.first, ["type": "text", "text": prompt], "The original user prompt is not rewritten.")
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs.last?["type"], "text")
        XCTAssertTrue(inputs.last?["text"]?.hasPrefix("APP_RUNTIME_INTERACTION_POLICY: background_only.") == true)
        XCTAssertFalse(requests.contains { $0["method"] as? String == "thread/compact/start" })
    }
}

import Foundation
import XCTest
@testable import Computa

final class ProviderCLIIntegrationTests: XCTestCase {
    func testCurrentAndLegacyModelCatalog() {
        let current = AgentCLIModels(session: ["configOptions": [["id": "engine", "category": "model", "options": [
            ["group": "Group", "options": [["value": "p/m", "name": "My model"]]]]]]])
        XCTAssertEqual(current.configID, "engine")
        XCTAssertEqual(current.entries.first?.id, "p/m")
        XCTAssertEqual(AgentCLIModels(session: ["models": ["availableModels": [["modelId": "legacy", "name": "Legacy"]]]]).entries.first?.id, "legacy")
        XCTAssertEqual(ProviderCLI(modelID: "cli/opencode/model/p/m"), .opencode)
        XCTAssertNil(ProviderCLI(modelID: "cli/opencode/model/"))
        XCTAssertNil(ProviderCLI(modelID: "cli/codex/model/other"))
        XCTAssertNil(ProviderCLI(modelID: "cli/deepseek/default"))
        XCTAssertNil(ProviderCLI(modelID: "cli/gemini/default"))
    }

    @MainActor
    func testFixtureConversationAndRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agy")
        let source = #"""
        #!/usr/bin/python3
        import sys,json
        def emit(obj):
            print(json.dumps(dict(jsonrpc="2.0",**obj)),flush=True)
        for line in sys.stdin:
            m=json.loads(line); method=m["method"]; p=m["params"]
            config={"configOptions":[{"category":"model","id":"model","options":[{"value":"fixture","name":"Fixture"}]}]}
            if method=="initialize":result={"protocolVersion":1,"agentCapabilities":{"loadSession":True}}
            elif method=="session/new":result=dict(config,sessionId="owned")
            elif method=="session/load":
                assert p["sessionId"]=="owned";result=config
            elif method=="session/set_config_option":
                assert p["value"]=="fixture";config["configOptions"][0]["currentValue"]="fixture";result=config
            elif method=="session/prompt":
                word=p["prompt"][0]["text"]
                emit({"method":"session/request_permission","id":"consent","params":{"sessionId":"owned","toolCall":{"title":"Fixture tool"},"options":[{"kind":"allow_once","optionId":"yes"},{"kind":"reject_once","optionId":"no"}]}})
                receipt=json.loads(sys.stdin.readline())
                assert receipt["id"]=="consent" and receipt["result"]["outcome"]=={"outcome":"selected","optionId":"yes" if word=="first" else "no"}
                for state in ["in_progress","completed" if word=="first" else "failed"]:
                    emit({"method":"session/update","params":{"sessionId":"owned","update":{"sessionUpdate":"tool_call_update","toolCallId":"call","title":"Fixture action","status":state}}})
                for sid,text in [("foreign","leak"),("owned","received "+word)]:
                    emit({"method":"session/update","params":{"sessionId":sid,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}})
                result={"stopReason":"end_turn"}
            else:raise Exception(method)
            emit({"id":m["id"],"result":result})
        """#
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let id = UUID().uuidString
        for word in ["first", "second"] {
            let channel = AsyncStream<AgentRuntimeEvent>.makeStream()
            let runtime = ProviderCLIChats(root: directory.appendingPathComponent("store"), searchDirectories: [directory.path, "/usr/bin"]) { channel.continuation.yield($0) }
            let rows = try await runtime.load()
            XCTAssertEqual(rows.count, word == "first" ? 0 : 1)
            let models = try await runtime.models(.antigravity)
            let selection = try XCTUnwrap(models.first?.id)
            try await runtime.submit(word, id: id, provider: .antigravity, modelID: selection)
            let result = try await Self.answer(channel.stream, id: id) { request in
                XCTAssertEqual(request.taskID, id)
                try await runtime.approve(request.id, word == "first")
            }
            XCTAssertEqual(result, "received " + word)
            _ = await runtime.shutdown()
            let saved = try await runtime.load()
            XCTAssertEqual(saved.first?.entries.last?.body, result)
            let tools = saved.first?.entries.filter { $0.kind == .tool } ?? []
            XCTAssertEqual(tools.count, word == "first" ? 1 : 2)
            XCTAssertEqual(tools.last?.toolEvent?.status, word == "first" ? .succeeded : .failed)
        }
    }

    /// Runs only on a machine explicitly selected for signed-in provider testing.
    @MainActor
    func testInstalledProviderThroughComputa() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["COMPUTA_TEST_AGENT_CLI"], let provider = ProviderCLI(rawValue: raw) else { throw XCTSkip("Local provider test disabled") }
        var config = CodexAppServerRuntime.Configuration.localQwen
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        config.codexHomePath = directory.path
        let runtime = SelectableCodexRuntime(configuration: config)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "computa.provider-cli.test." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let state = AppState(tasks: [], runtime: runtime, installedProviderCLIs: [provider], preferences: prefs,
            unreadCompletionStore: .init(fileURL: directory.appendingPathComponent("unread.json")))
        let listener = Task { @MainActor in
            for await event in runtime.events() { state.apply(event) }
        }
        defer { listener.cancel() }
        do {
            state.connectModelProvider(route: provider.route)
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            while state.providerCLISetups.first?.connected != true, state.providerCLISetups.first?.detail == nil,
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            let picker = WebUISnapshot(state: state)
            let setup = try XCTUnwrap(picker.providerSetups.first { $0.route == provider.route })
            XCTAssertTrue(setup.connected, setup.detail ?? "Model discovery did not finish")
            let model = env["COMPUTA_TEST_AGENT_MODEL"].map { provider.route + "/model/" + $0 } ?? provider.modelID
            XCTAssertTrue(picker.modelOptions.contains { $0.id == model })
            state.createTask()
            let id = try XCTUnwrap(state.selectedTaskID)
            XCTAssertTrue(state.setTaskModel(model, taskID: id))
            let workspace = directory.appendingPathComponent("fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try await state.setTaskWorkspace(workspace, taskID: id)
            let marker = "COMPUTA-" + UUID().uuidString.prefix(8)
            var checks = [("Reply with exactly " + marker + ". Use no tools.", marker)]
            if env["COMPUTA_TEST_AGENT_SINGLE_TURN"] != "1" {
                checks.append(("Repeat the exact marker from my last message. Use no tools.", marker))
            }
            if env["COMPUTA_TEST_AGENT_FILE_READ"] == "1" {
                let fileMarker = UUID().uuidString
                try fileMarker.write(to: workspace.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
                checks.append(("Read fixture.txt in the selected workspace. Reply with its exact contents only.", fileMarker))
            }
            for (prompt, expected) in checks {
                state.composerText = prompt
                let accepted = await state.submitComposer()
                guard accepted else { throw AgentCLIError.protocolError(state.selectedTask?.entries.last?.body ?? "Submission failed") }
                let deadline = ContinuousClock.now.advanced(by: .seconds(90))
                while [.running, .waiting].contains(state.selectedTask?.status), ContinuousClock.now < deadline {
                    if !state.pendingApprovals.isEmpty { throw AgentCLIError.protocolError("The CLI requested interactive tool approval.") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let task = try XCTUnwrap(state.selectedTask)
                guard task.status == .completed else { throw AgentCLIError.protocolError(task.entries.last?.body ?? "No completed turn") }
                let shown = try XCTUnwrap(WebUISnapshot(state: state).tasks.first { $0.id == id }?.entries.last)
                XCTAssertEqual(shown.body.trimmingCharacters(in: .whitespacesAndNewlines), String(expected))
            }
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
        let report = await runtime.shutdown()
        XCTAssertTrue(report.succeeded, report.issues.joined(separator: ", "))
    }

    private static func answer(_ events: AsyncStream<AgentRuntimeEvent>, id: String,
                               decide: @escaping @Sendable (ActionApprovalRequest) async throws -> Void) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var answer = "", error = ""
                for await event in events {
                    switch event {
                    case .approvalRequested(let request) where request.taskID == id:
                        try await decide(request)
                    case .timelineEntryAppended(let taskID, let entry) where taskID == id:
                        if entry.kind == .assistant { answer = entry.body }
                        if entry.kind == .system { error = entry.body }
                    case .taskStatusChanged(let taskID, let status) where taskID == id:
                        if status == .failed { throw AgentCLIError.protocolError(error) }
                        if status == .completed { return answer }
                    default: break
                    }
                }
                throw CancellationError()
            }
            group.addTask { try await Task.sleep(for: .seconds(90)); throw AgentCLIError.protocolError("Test timed out") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

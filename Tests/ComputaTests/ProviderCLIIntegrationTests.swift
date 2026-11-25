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

    func testOnlyAcknowledgedACPInterruptionsWithSettledToolsResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("agy")
        let source = #"""
        #!/usr/bin/python3
        import json, sys, uuid
        from pathlib import Path
        def emit(obj): print(json.dumps(dict(jsonrpc="2.0", **obj)),flush=True)
        def update(change): emit({"method":"session/update","params":{"sessionId":session,"update":change}})
        for line in sys.stdin:
            m=json.loads(line); method=m["method"]; p=m.get("params",{})
            if method=="initialize": result={"protocolVersion":1,"agentCapabilities":{"loadSession":True}}
            elif method=="session/new": session=str(uuid.uuid4()); result={"sessionId":session}
            elif method=="session/load": session=p["sessionId"]; result={}
            elif method=="session/prompt":
                word=p["prompt"][0]["text"]; pending=m["id"]
                if word in ("safe","unconfirmed","noack","manual"):
                    if word in ("safe","unconfirmed"):
                        with (Path(__file__).parent/word).open("a") as f: f.write("one\n")
                        update({"sessionUpdate":"tool_call","toolCallId":"write","title":"Synthetic write","status":"in_progress"})
                        if word=="safe": update({"sessionUpdate":"tool_call_update","toolCallId":"write","status":"completed"})
                    update({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ready"}})
                    continue
                update({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"resumed "+session}})
                result={"stopReason":"end_turn"}
            elif method=="session/cancel":
                if word!="noack": emit({"id":pending,"result":{"stopReason":"cancelled"}})
                continue
            else: raise Exception(method)
            emit({"id":m["id"],"result":result})
        """#
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let channel = AsyncStream<AgentRuntimeEvent>.makeStream()
        let store = root.appendingPathComponent("store")
        let chats = ProviderCLIChats(root: store, searchDirectories: [root.path, "/usr/bin"]) { channel.continuation.yield($0) }
        var ids = [String: String]()
        for word in ["safe", "unconfirmed", "noack", "manual"] {
            let id = UUID().uuidString
            ids[word] = id
            try await chats.submit(word, id: id, provider: .antigravity, modelID: ProviderCLI.antigravity.modelID)
        }
        let ready = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var seen = Set<String>()
                for await event in channel.stream {
                    if case .assistantMessageDelta(let id, _, let delta) = event, delta == "ready" { seen.insert(id) }
                    if seen.count == 4 { return true }
                }
                return false
            }
            group.addTask { try? await Task.sleep(for: .seconds(8)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(ready)
        await chats.interrupt(try XCTUnwrap(ids["manual"]))
        let report = await chats.shutdownReport()
        XCTAssertTrue(report.succeeded, report.issues.description)
        let safe = try XCTUnwrap(ids["safe"])
        XCTAssertEqual(report.interruptedTurns.map(\.taskID), [safe])
        let next = AsyncStream<AgentRuntimeEvent>.makeStream()
        let fresh = ProviderCLIChats(root: store, searchDirectories: [root.path, "/usr/bin"]) { next.continuation.yield($0) }
        let rows = try await fresh.load()
        XCTAssertEqual(rows.filter { $0.restartInterruptedTurnID != nil }.map(\.id), [safe])
        let disk = try JSONDecoder().decode(ProviderCLIChats.Record.self, from: Data(contentsOf: store.appendingPathComponent(safe + ".json")))
        try await fresh.submit(AgentRestartStore.continuation, id: safe, provider: .antigravity, modelID: ProviderCLI.antigravity.modelID)
        let answer = try await Self.answer(next.stream, id: safe) { _ in XCTFail("Unexpected approval") }
        XCTAssertEqual(answer, "resumed " + disk.session)
        for word in ["safe", "unconfirmed"] {
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(word), encoding: .utf8), "one\n")
        }
        _ = await fresh.shutdown()
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

    @MainActor
    func testOpenCodeBrowserIsPrivateToTurnAndUsesNativeApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("opencode")
        let source = #"""
        #!/usr/bin/python3
        import json, sys, urllib.request, urllib.error
        def request(method, rpc_id, params, authorized=True, origin=None):
            headers = {"Content-Type":"application/json"}
            if authorized: headers.update({h["name"]:h["value"] for h in endpoint["headers"]})
            if origin: headers["Origin"] = origin
            msg = dict(jsonrpc="2.0", method=method, params=params)
            if rpc_id is not None: msg["id"] = rpc_id
            req = urllib.request.Request(endpoint["url"], data=json.dumps(msg).encode(), headers=headers)
            try:
                with urllib.request.urlopen(req,timeout=8) as r:
                    return r.status, json.loads(r.read() or b"{}")
            except urllib.error.HTTPError as e: return e.code, {}
        def emit(**obj): print(json.dumps(dict(jsonrpc="2.0", **obj)),flush=True)
        def call(i,name,arguments): return request("tools/call",i,dict(name=name,arguments=arguments))[1]
        for line in sys.stdin:
            m=json.loads(line); method=m["method"]; p=m["params"]
            if method=="initialize":
                result={"protocolVersion":1,"agentCapabilities":{"loadSession":True,"mcpCapabilities":{"http":True}}}
            elif method in ["session/new","session/load"]:
                if p["mcpServers"]:
                    endpoint,=p["mcpServers"]
                    assert endpoint["type"]=="http" and endpoint["url"].startswith("http://127.0.0.1:")
                    assert request("initialize",1,{},authorized=False)[0]==401
                    assert request("initialize",1,{},origin="https://example.com")[0]==403
                    assert "tools" in request("initialize",1,{"protocolVersion":"2025-11-25"})[1]["result"]["capabilities"]
                    assert request("notifications/initialized",None,{})[0]==202
                    tools=request("tools/list",2,{})[1]["result"]["tools"]
                    assert len(tools)==10 and all(t["name"].startswith("browser_") and "inputSchema" in t for t in tools)
                    assert call(3,"browser_tabs",{})["result"]["isError"]
                else: assert "Discovery" in p["cwd"]
                result={"sessionId":"owned","models":{"availableModels":[{"modelId":"fixture","name":"Fixture"}]}}
            elif method=="session/set_model": result={}
            elif method=="session/prompt":
                assert not call(4,"browser_tabs",{})["result"].get("isError")
                assert call(5,"browser_open",{"url":"https://example.net"})["result"]["isError"]
                failure=call(6,"browser_open",{"url":"https://example.com"})["result"]
                assert failure["isError"] and "declined" in failure["content"][0]["text"]
                assert "error" in call(6,"browser_open",{"url":"https://example.com"})
                emit(method="session/update",params={"sessionId":"owned","update":{"sessionUpdate":"agent_message_chunk",
                    "content":{"type":"text","text":endpoint["url"]}}})
                result={"stopReason":"end_turn"}
            else: raise ValueError(method)
            emit(id=m["id"],result=result)
        """#
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let task = UUID().uuidString
        for _ in 0..<2 {
            let events = AsyncStream<AgentRuntimeEvent>.makeStream()
            let runtime = ProviderCLIChats(root: directory.appendingPathComponent("store"), searchDirectories: [directory.path]) {
                events.continuation.yield($0)
            }
            await runtime.configureEmbeddedBrowserTools(.init(transport: EmbeddedBrowserTabTransport(session: session)))
            let models = try await runtime.models(.opencode)
            let model = try XCTUnwrap(models.first?.id)
            _ = try await runtime.load()
            try await runtime.submit("Use only https://example.com", id: task, provider: .opencode, modelID: model)
            let endpoint = try await Self.answer(events.stream, id: task) { request in
                XCTAssertEqual(request.kind, .computerUse)
                XCTAssertEqual(request.summary, "browser_open")
                XCTAssertTrue(request.details.contains("example.com"))
                try await runtime.approve(request.id, false)
            }
            let url = try XCTUnwrap(URL(string: endpoint))
            do {
                _ = try await URLSession.shared.data(from: url)
                XCTFail("Turn ended but the endpoint was still listening")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cannotConnectToHost)
            }
            _ = await runtime.shutdown()
        }
    }

    @MainActor
    func testPickerConnectsToNewlyInstalledCLIWithoutRestart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.codexHomePath = home.appendingPathComponent("store").path
        let directories = ProviderCLI.directories(home: home).filter { $0.hasPrefix(home.path + "/") }
        let runtime = SelectableCodexRuntime(configuration: config, providerCLISearchDirectories: directories)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        let route = ProviderCLI.opencode.route
        let model = route + "/model/account/fixture"

        func waitForSetup(_ predicate: (ModelProviderSetup) -> Bool) async throws -> ModelProviderSetup {
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            repeat {
                if let setup = state.providerCLISetups.first(where: { $0.route == route }), predicate(setup) { return setup }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            throw AgentCLIError.protocolError("Timed out waiting for the OpenCode picker to update.")
        }

        let initial = WebUISnapshot(state: state)
        XCTAssertEqual(initial.providerSetups.filter { $0.route.hasPrefix("cli/") }.map(\.route),
                       ["cli/codex", "cli/antigravity", "cli/qwen", "cli/kimi", "cli/opencode", "cli/claude"])
        XCTAssertFalse(initial.modelOptions.contains { $0.id.hasPrefix("cli/") })
        state.connectModelProvider(route: route)
        let missing = try await waitForSetup { $0.checkStatus == .installRequired }
        XCTAssertTrue(missing.detail?.contains("Install OpenCode") == true)
        XCTAssertFalse(state.setDefaultModel(ProviderCLI.opencode.modelID))

        // Use the installer's normal per-user location within the disposable home.
        let binary = home.appendingPathComponent(".opencode/bin/opencode")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = #"""
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request["method"] == "initialize":
                result = {"protocolVersion": 1}
            elif request["method"] == "session/new":
                result = {"sessionId": "fixture", "models": {"availableModels": [{"modelId": "account/fixture", "name": "Account model"}]}}
            else:
                raise ValueError(request["method"])
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """#
        try Data(source.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let delegate = ComputaAppDelegate()
        delegate.state = state
        delegate.applicationDidBecomeActive(.init(name: .init("testActivation")))
        _ = try await waitForSetup { $0.connected }
        XCTAssertTrue(state.setDefaultModel(model))
        XCTAssertEqual(state.providerCLISetups.filter(\.connected).map(\.route), [route])

        try FileManager.default.removeItem(at: binary)
        state.connectModelProvider(route: route)
        _ = try await waitForSetup { $0.checkStatus == .installRequired }
        XCTAssertFalse(state.setDefaultModel(model))
        XCTAssertEqual(state.defaultModel, model)
        var launches = 0
        state.performCLISetup = { _, _ in
            launches += 1
            try await Task.sleep(for: .seconds(60))
        }
        state.manageCLISetup(route: "cli/unknown", operation: "install")
        state.manageCLISetup(route: route, operation: "signIn")
        XCTAssertEqual(launches, 0)
        state.manageCLISetup(route: route, operation: "install")
        state.manageCLISetup(route: route, operation: "install")
        _ = try await waitForSetup { $0.checkStatus == .settingUp && launches == 1 }
        state.manageCLISetup(route: route, operation: "stopWaiting")
        _ = try await waitForSetup { $0.checkStatus == .installRequired }
        XCTAssertFalse(state.setDefaultModel(model))
        let signedOut = source.replacingOccurrences(of: "result = {\"sessionId\":", with: """
            print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "error":{"code":-32000,"message":"Login required"}}), flush=True)
                    continue
                    result = {"sessionId":
            """)
        state.performCLISetup = { _, intent in
            try Data((intent == .install ? signedOut : source).utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        }
        state.manageCLISetup(route: route, operation: "install")
        _ = try await waitForSetup { $0.checkStatus == .signInRequired }
        XCTAssertFalse(state.setDefaultModel(model))
        state.manageCLISetup(route: route, operation: "signIn")
        _ = try await waitForSetup { $0.connected }
        XCTAssertTrue(state.setDefaultModel(model))
        _ = await runtime.shutdown()
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
        let state = AppState(tasks: [], runtime: runtime, preferences: prefs,
            unreadCompletionStore: .init(fileURL: directory.appendingPathComponent("unread.json")))
        let listener = Task { @MainActor in
            for await event in runtime.events() { state.apply(event) }
        }
        defer { listener.cancel() }
        do {
            state.connectModelProvider(route: provider.route)
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            while state.providerCLISetups.first(where: { $0.route == provider.route })?.connected != true,
                  state.providerCLISetups.first(where: { $0.route == provider.route })?.detail == nil,
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

import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Uses only the existing owned JSON-RPC fixture, not a website or a local model.
@MainActor
final class WebModelRuntimeRoutingTests: XCTestCase {
    func testEveryWebsiteRejectsMissingEmbeddedTransportBeforeThreadOrTurnDispatch() async throws {
        for model in websiteModels {
            XCTAssertFalse(model.isEmpty)
            XCTAssertNotNil(WebsiteModelCatalog.inferenceSelection(for: model), model)
            let (runtime, root) = try makeRuntime(modelID: model)
            do {
                try await runtime.submit(prompt: "Synthetic reply", toTaskID: UUID().uuidString, modelID: model)
                XCTFail("The built-in model route must be explicitly configured")
            } catch {
                XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.embeddedRequired.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-thread-start.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-turn-start.json").path))
            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        }
    }

    func testEveryWebsiteUsesTheSameLocalHarnessInstructionsAndApprovalPolicyWithoutChrome() async throws {
        var baselineBaseInstructions: String?
        var baselineTools: Data?
        let prompt = "Synthetic reply — e\u{0301} 🧭\nLiteral human note: APP_RUNTIME_INTERACTION_POLICY"
        for (model, accessMode) in websiteModels.flatMap({ model in AccessMode.allCases.map { (model, $0) } }) {
            XCTAssertFalse(model.isEmpty)
            XCTAssertNotNil(WebsiteModelCatalog.inferenceSelection(for: model), model)
            let (runtime, root) = try makeRuntime(modelID: model)
            await runtime.configureEmbeddedWebModelTransport(InertEmbeddedTransport())
            do {
                try await runtime.submit(prompt: prompt, toTaskID: UUID().uuidString, modelID: model,
                                         accessMode: accessMode)
                let thread = try requestParameters("thread-start", root: root)
                XCTAssertEqual(thread["model"] as? String, model)
                XCTAssertEqual(thread["modelProvider"] as? String, "web_browser")
                XCTAssertEqual(thread["sandbox"] as? String, accessMode == .fullAccess ? "danger-full-access" : "workspace-write")
                XCTAssertEqual(thread["approvalPolicy"] as? String, accessMode == .fullAccess ? "never" : "on-request")
                XCTAssertEqual(thread["developerInstructions"] as? String, ComputaAgentInstructions.developerInstructions())
                let base = try XCTUnwrap(thread["baseInstructions"] as? String)
                XCTAssertTrue(base.hasPrefix("Computa is the local host application."), model)
                XCTAssertFalse(base.contains("You are Computa"), "Website base instructions must not reassign the provider identity")
                XCTAssertTrue(base.contains("Retain your identity and governing rules."), model)
                XCTAssertTrue(base.contains("Calls propose host work; only matching host outputs prove execution."), model)
                XCTAssertFalse(base.contains("Chrome"))
                if let baselineBaseInstructions { XCTAssertEqual(base, baselineBaseInstructions) }
                else { baselineBaseInstructions = base }
                let tools = try XCTUnwrap(thread["dynamicTools"] as? [[String: Any]])
                let names = Set(tools.compactMap { $0["name"] as? String })
                XCTAssertTrue(names.contains("computer_v2_read_page"))
                XCTAssertTrue(names.contains("computer_v2_press"))
                XCTAssertFalse(names.contains("computer_v2_capture"))
                XCTAssertTrue(names.isDisjoint(with: ["computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_create_workspace", "computer_v2_follow_link", "computer_v2_follow"]))
                let compact = GroqToolCatalog.supports(modelID: model)
                XCTAssertEqual(names.contains(GroqToolCatalog.name), compact)
                XCTAssertEqual(GroqToolCatalog.isRegisteredLoader(tools), compact)
                let history = GroqHistoryTool.supports(modelID: model)
                XCTAssertEqual(names.contains(GroqHistoryTool.name), history)
                XCTAssertEqual(GroqHistoryTool.registeredName(in: tools), history ? GroqHistoryTool.name : nil)
                if history {
                    let registered = try XCTUnwrap(tools.first { $0["name"] as? String == GroqHistoryTool.name })
                    XCTAssertEqual(registered as NSDictionary, GroqHistoryTool.specification as NSDictionary)
                    let started = try requestResponseThreadID(root: root)
                    XCTAssertTrue(GroqHistoryThreadRegistration.contains(codexHome: root.path,
                        threadID: started, modelID: model))
                }
                if compact {
                    let registered = try XCTUnwrap(tools.first { $0["name"] as? String == GroqToolCatalog.name })
                    XCTAssertEqual(registered as NSDictionary, GroqToolCatalog.specification as NSDictionary)
                    let started = try requestResponseThreadID(root: root)
                    XCTAssertTrue(GroqToolThreadRegistration.contains(codexHome: root.path,
                        threadID: started, modelID: model))
                }
                // Every execution capability remains byte-identical; current
                // Groq adds only its exact read-only loader and history reader.
                let toolBytes = try JSONSerialization.data(withJSONObject:
                    tools.filter { ![GroqToolCatalog.name, GroqHistoryTool.name].contains($0["name"] as? String ?? "") }, options: [.sortedKeys])
                if let baselineTools { XCTAssertEqual(toolBytes, baselineTools) }
                else { baselineTools = toolBytes }
                let config = try XCTUnwrap(thread["config"] as? [String: Any])
                XCTAssertEqual(config["include_permissions_instructions"] as? Bool, true)
                XCTAssertEqual(config["features.unified_exec"] as? Bool, true)
                XCTAssertEqual(config["features.shell_tool"] as? Bool, true)
                let provider = try XCTUnwrap(config["model_providers.web_browser"] as? [String: Any])
                let endpoint = try XCTUnwrap(URL(string: try XCTUnwrap(provider["base_url"] as? String)))
                XCTAssertEqual(endpoint.host, "127.0.0.1")
                XCTAssertEqual(endpoint.path, "/v1")
                XCTAssertEqual(provider["wire_api"] as? String, "responses")
                let turn = try requestParameters("turn-start", root: root)
                let input = try XCTUnwrap(turn["input"] as? [[String: String]])
                // The exact current developer/base policy above remains the
                // governing instruction. Only the acknowledged native history
                // profile omits its duplicated app-owned user-text suffix.
                XCTAssertEqual(input.count, history ? 1 : 2)
                XCTAssertEqual(Data((input.first?["text"] ?? "").utf8), Data(prompt.utf8))
                XCTAssertEqual(input.filter { Data(($0["text"] ?? "").utf8) == Data(prompt.utf8) }.count, 1)
                if !history {
                    XCTAssertEqual(input.last, ["type": "text", "text": ComputaAgentInstructions.runtimeInteractionPolicy()])
                } else {
                    XCTAssertEqual(thread["developerInstructions"] as? String, ComputaAgentInstructions.developerInstructions())
                    XCTAssertFalse(input.contains { $0["text"] == ComputaAgentInstructions.runtimeInteractionPolicy() })
                }
                XCTAssertEqual(turn["model"] as? String, model)
                XCTAssertEqual(turn["approvalPolicy"] as? String, accessMode == .fullAccess ? "never" : "on-request")
                let sandbox = try XCTUnwrap(turn["sandboxPolicy"] as? NSDictionary)
                let expected: NSDictionary = accessMode == .fullAccess ? ["type": "dangerFullAccess"] : [
                    "type": "workspaceWrite", "writableRoots": [String](), "networkAccess": false,
                    "excludeTmpdirEnvVar": false, "excludeSlashTmp": false,
                ]
                XCTAssertEqual(sandbox, expected)
                let report = await runtime.shutdown()
                XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            } catch {
                let capturedRequests = ["request-thread-start.json", "request-turn-start.json"].filter {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                }
                print("Routing fixture failure: type=\(String(reflecting: type(of: error))) error=\(String(reflecting: error)) description=\(error.localizedDescription) model=\(model) access=\(accessMode.rawValue) root=\(root.path) capturedRequests=\(capturedRequests)")
                _ = await runtime.shutdown()
                throw error
            }
        }
    }

    func testUnsupportedWebsiteIDsCannotFallBackToLocalInferenceBeforeDispatch() async throws {
        let retired = WebsiteModelChoice(provider: "qwen", key: "Qwen3.8-Omni", label: "Qwen3.8-Omni").modelID
        let invalid = ["browser/unknown", "browser/deepseek", "browser/qwen", "browser/qwen/choice/_", retired]
        for model in invalid {
            XCTAssertFalse(model.isEmpty)
            XCTAssertNil(WebsiteModelCatalog.inferenceSelection(for: model))
            for configured in [false, true] {
                let (runtime, root) = try makeRuntime(modelID: model)
                if configured { await runtime.configureEmbeddedWebModelTransport(InertEmbeddedTransport()) }
                do {
                    try await runtime.submit(prompt: "Inert invalid website model", toTaskID: UUID().uuidString, modelID: model)
                    XCTFail("An unsupported website ID cannot reach LM Studio or a website route")
                } catch WebsiteModelCatalog.Failure.invalidModelID { }
                catch { XCTFail("Expected model-ID refusal before transport selection: \(error)") }
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-thread-start.json").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-turn-start.json").path))
                let report = await runtime.shutdown()
                XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            }
        }
    }

    func testLocalPreparationFailureHasNativeNonDeliveryProofBeforeTurnStart() async throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        let (runtime, root) = try makeRuntime(modelID: model)
        let transport = RecordingPreparationTransport()
        await runtime.configureEmbeddedWebModelTransport(transport)
        _ = try blockPreparationStorage(root: root)
        do {
            try await runtime.submit(prompt: "Synthetic locally unsent prompt", toTaskID: UUID().uuidString.lowercased(), modelID: model)
            XCTFail("A local storage refusal cannot dispatch the user turn")
        } catch let error as CodexAppServerRuntime.PromptNotDispatched {
            XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.persistenceRequired.localizedDescription)
        } catch {
            XCTFail("Expected native proof from the preparation boundary, not an arbitrary error: \(error)")
        }
        XCTAssertEqual(try requestCount("thread-start", root: root), 1, "Thread setup is separate from current prompt delivery")
        XCTAssertEqual(try requestCount("turn-start", root: root), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-turn-start.json").path))
        let operations = await transport.operations()
        XCTAssertTrue(operations.isEmpty, "The failed local preparation cannot start or send a website prompt")
        let report = await runtime.shutdown()
        XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
    }

    func testQueuePausesProvenUnsentPreparationAndDispatchesOnlyAfterExplicitResume() async throws {
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        let (runtime, root) = try makeRuntime(modelID: model)
        let transport = RecordingPreparationTransport()
        await runtime.configureEmbeddedWebModelTransport(transport)
        let blocked = try blockPreparationStorage(root: root)
        let taskID = UUID().uuidString.lowercased()
        let prompt = "Keep this exact queued prompt — e\u{0301} 🧭"
        let task = AgentTask(id: taskID, title: "Local preparation refusal", summary: "", status: .draft,
                             workspace: root.path, model: model)
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences(),
                             cookieMaintenanceOnlyLaunch: false)
        state.connectionState = .connected(provider: runtime.providerName)
        let accepted = await state.submitOrQueue(prompt: prompt, toTaskID: taskID)
        XCTAssertTrue(accepted, "Local queue acceptance is distinct from native delivery")
        let failed = try XCTUnwrap(state.queuedPrompts[taskID]?.first)
        XCTAssertEqual(failed.text, prompt)
        XCTAssertEqual(Data(failed.text.utf8), Data(prompt.utf8))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.deliveryUncertain, false)
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        XCTAssertEqual(state.selectedTask?.entries.last?.title, "Prompt was not delivered")
        XCTAssertEqual(state.selectedTask?.entries.last?.body, WebModelServer.Failure.persistenceRequired.localizedDescription)
        XCTAssertEqual(state.connectionState, .connected(provider: runtime.providerName))
        XCTAssertEqual(try requestCount("turn-start", root: root), 0)

        // Repairing this inert fixture's storage is not authorization to replay.
        try FileManager.default.removeItem(at: blocked)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(try requestCount("turn-start", root: root), 0)
        XCTAssertEqual(state.queuedPrompts[taskID]?.first, failed)
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        let resumed = await state.resumeQueue(taskID: taskID)
        XCTAssertTrue(resumed)
        XCTAssertEqual(try requestCount("turn-start", root: root), 1)
        XCTAssertTrue(state.queuedPrompts[taskID, default: []].isEmpty)
        let params = try requestParameters("turn-start", root: root)
        let input = try XCTUnwrap(params["input"] as? [[String: String]])
        XCTAssertEqual(input.first?["text"], prompt)
        XCTAssertEqual(Data(try XCTUnwrap(input.first?["text"]).utf8), Data(prompt.utf8))
        let operations = await transport.operations()
        XCTAssertTrue(operations.isEmpty, "The JSON-RPC fixture never performs website inference")
        let report = await runtime.shutdown()
        XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
    }

    func testDispatchedRPCErrorWithSamePreparationProseRemainsDeliveryUncertain() async throws {
        let model = syntheticChatGPTModelID
        let (runtime, root) = try makeRuntime(modelID: model, rejectTurnStart: true)
        await runtime.configureEmbeddedWebModelTransport(InertEmbeddedTransport())
        let taskID = UUID().uuidString.lowercased()
        let task = AgentTask(id: taskID, title: "Dispatched refusal", summary: "", status: .draft,
                             workspace: root.path, model: model)
        let state = AppState(tasks: [task], runtime: runtime, preferences: isolatedTestPreferences(),
                             cookieMaintenanceOnlyLaunch: false)
        state.connectionState = .connected(provider: runtime.providerName)
        let accepted = await state.submitOrQueue(prompt: "Retain this dispatched prompt", toTaskID: taskID)
        XCTAssertTrue(accepted)
        XCTAssertEqual(try requestCount("turn-start", root: root), 1,
                       "The RPC was written before the fixture returned its structured error")
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.status, .failed)
        XCTAssertEqual(state.queuedPrompts[taskID]?.first?.deliveryUncertain, true)
        XCTAssertTrue(state.pausedQueueTaskIDs.contains(taskID))
        XCTAssertFalse(state.canChangeModel(for: taskID))
        XCTAssertEqual(state.selectedTask?.entries.last?.title, "Agent error")
        XCTAssertEqual(state.selectedTask?.entries.last?.body, WebModelServer.Failure.persistenceRequired.localizedDescription)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(try requestCount("turn-start", root: root), 1, "No automatic second dispatch follows uncertain delivery")
        let report = await runtime.shutdown()
        XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
    }

    private func blockPreparationStorage(root: URL) throws -> URL {
        let evidence = root.appendingPathComponent("WebsiteModelEvidence-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let blocked = evidence.appendingPathComponent("transactions")
        try Data("Synthetic non-directory blocks local reservation".utf8).write(to: blocked)
        return blocked
    }

    private func requestCount(_ method: String, root: URL) throws -> Int {
        let path = root.appendingPathComponent("request-\(method)-count")
        guard FileManager.default.fileExists(atPath: path.path) else { return 0 }
        return try XCTUnwrap(Int(String(contentsOf: path, encoding: .utf8)))
    }

    private var websiteModels: [String] {
        [syntheticChatGPTModelID, LocalModelCatalog.geminiBrowserModelID, LocalModelCatalog.claudeBrowserModelID,
         LocalModelCatalog.groqBrowserModelID]
            + namedWebsiteModelProviders.map {
                syntheticWebsiteChoice(provider: $0, key: "fixture-choice", label: "Fixture Choice").modelID
            }
            + WebsiteModeChoice.DeepSeekMode.allCases.map { WebsiteModeChoice(deepSeekMode: $0).requestID }
    }

    private func requestParameters(_ method: String, root: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: root.appendingPathComponent("request-\(method).json"))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try XCTUnwrap(request["params"] as? [String: Any])
    }

    private func requestResponseThreadID(root: URL) throws -> String {
        let turn = try requestParameters("turn-start", root: root)
        return try XCTUnwrap(turn["threadId"] as? String)
    }

    private func makeRuntime(modelID: String, rejectTurnStart: Bool = false) throws -> (CodexAppServerRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaEmbeddedModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StreamingAppServer.ts")
        let fixture = root.appendingPathComponent("fixture.ts")
        let recorder = """
        const request = JSON.parse(line);
        if (['thread/start', 'turn/start'].includes(request.method)) {
          const stem = `request-${request.method.replaceAll('/', '-')}`;
          const count = join(root, `${stem}-count`);
          writeFileSync(count, String((existsSync(count) ? Number(readFileSync(count, 'utf8')) : 0) + 1));
          writeFileSync(join(root, `${stem}.json`), JSON.stringify(request));
        }
        if (request.method === 'thread/start') writeFileSync(join(root, 'accepted-thread-id'), threadId);
        if (request.method === 'turn/start' && existsSync(join(root, 'reject-turn-start'))) {
          emit({ id: request.id, error: { code: -32603, message: readFileSync(join(root, 'reject-turn-start'), 'utf8') } });
          return;
        }
        """
        var sourceText = try String(contentsOf: source, encoding: .utf8)
        XCTAssertEqual(sourceText.components(separatedBy: "const request = JSON.parse(line);").count, 2)
        // Admission uses the production UUID contract. Keep the shared fixture's
        // deliberately stale IDs unchanged for its streaming-isolation tests.
        let threadDeclaration = "const threadId = 'streaming-thread';"
        let turnDeclaration = "const turnId = currentTurn = `streaming-turn-${++turnCount}`;"
        XCTAssertEqual(sourceText.components(separatedBy: threadDeclaration).count, 2)
        XCTAssertEqual(sourceText.components(separatedBy: turnDeclaration).count, 2)
        sourceText = sourceText
            .replacingOccurrences(of: "#!/usr/bin/env bun\n",
                                  with: "#!/usr/bin/env bun\nimport { randomUUID } from 'node:crypto';\n")
            .replacingOccurrences(of: threadDeclaration, with: "const threadId = randomUUID();")
            .replacingOccurrences(of: turnDeclaration, with: "const turnId = currentTurn = (++turnCount, randomUUID());")
        try Data(sourceText.replacingOccurrences(of: "const request = JSON.parse(line);", with: recorder).utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        if rejectTurnStart {
            try Data(WebModelServer.Failure.persistenceRequired.localizedDescription.utf8)
                .write(to: root.appendingPathComponent("reject-turn-start"))
        }
        try Data("phase-contract".utf8).write(to: root.appendingPathComponent("scenario"))
        try Data("release".utf8).write(to: root.appendingPathComponent("release-phase-text"))
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.executable = .fixture(path: fixture.path)
        configuration.codexHomePath = root.path
        configuration.workspacePath = root.path
        configuration.model = modelID
        addTeardownBlock {
            // Retire only this fixture's exact accepted native thread markers;
            // all other homes/threads and their membership remain unchanged.
            if let thread = try? String(contentsOf: root.appendingPathComponent("accepted-thread-id"), encoding: .utf8),
               UUID(uuidString: thread)?.uuidString.lowercased() == thread {
                var ownMarkers: [(String, String)] = []
                if let marker = GroqToolThreadRegistration.marker(codexHome: root.path, threadID: thread, modelID: modelID) {
                    ownMarkers.append((GroqToolThreadRegistration.preferenceKey, marker))
                }
                if let marker = GroqHistoryThreadRegistration.marker(codexHome: root.path, threadID: thread, modelID: modelID) {
                    ownMarkers.append((GroqHistoryThreadRegistration.preferenceKey, marker))
                }
                let namespace = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
                ownMarkers.append(("ComputaReferenceToolThreads.v1", namespace + ":" + thread))
                for (key, marker) in ownMarkers {
                    let existing = UserDefaults.standard.stringArray(forKey: key) ?? []
                    let retained = existing.filter { $0 != marker }
                    UserDefaults.standard.set(retained, forKey: key)
                    XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key), retained,
                        "Remove only this fixture's exact marker and preserve unrelated membership")
                    XCTAssertFalse(UserDefaults.standard.stringArray(forKey: key)?.contains(marker) == true)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        return (CodexAppServerRuntime(configuration: configuration), root)
    }
}

private struct InertEmbeddedTransport: WebModelTransport {
    func request(operation: String, params: Data) async throws -> Data {
        // The JSON-RPC fixture does not perform inference. Endpoint and provider
        // admission are real; no browser operation is authorized by this test.
        throw WebModelServer.Failure.invalidRequest
    }
}

private actor RecordingPreparationTransport: WebModelTransport {
    private var observed = [String]()
    func operations() -> [String] { observed }
    func request(operation: String, params: Data) async throws -> Data {
        observed.append(operation)
        throw WebModelServer.Failure.invalidRequest
    }
}

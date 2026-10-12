import Foundation
import XCTest
@testable import Computa

/// Provider/catalog fixtures only. The JSON-RPC fixture records App Server
/// configuration without making an inference request or reading any API key.
@MainActor
final class APIProviderRuntimeContractTests: XCTestCase {
    func testCanonicalAPIIdentityUsesRemoteRouteWhileLegacyLocalAndBrowserRoutesStayDistinct() throws {
        let model = APIModelDefinition(id: "qwen-3.8-27b", name: "Fixture Qwen", contextWindow: 65_536)
        let id = apiID(model)
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.backend = .headlessMLX

        XCTAssertNoThrow(try configuration.validateSelectedModel(id))
        XCTAssertEqual(configuration.modelProvider(for: id), "computa_api")
        XCTAssertEqual(configuration.modelProvider(for: LocalModelCatalog.defaultModelID), "lmstudio")
        XCTAssertEqual(configuration.modelProvider(for: LocalModelCatalog.geminiBrowserModelID), "web_browser")
        XCTAssertThrowsError(try configuration.validateSelectedModel(model.id),
                             "A bare remote model name is not an admitted API identity")
        XCTAssertEqual(configuration.modelProvider(for: model.id), "lmstudio",
                       "Legacy local routing remains separate; API callers must use canonical identities")
        XCTAssertEqual(configuration.effectiveBackend, .headlessMLX)
    }

    func testMalformedAPIIDsAreRejectedBeforeTheyCanUseLegacyInference() {
        let id = apiID(APIModelDefinition(id: "fixture/model", name: "Fixture"))
        let malformed = [
            "api/", "api/cerebras/model/", "api/Cerebras/model/Zml4dHVyZQ",
            "api/cerebras/model/not!base64", id + "=", id + "/extra",
            id.replacingOccurrences(of: "/model/", with: "/choice/"),
        ]
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.backend = .external
        for value in malformed {
            XCTAssertNil(APIProviderCatalog.identity(for: value), value)
            XCTAssertThrowsError(try configuration.validateSelectedModel(value), value)
        }
    }

    func testRegisteredAPIContextAndCompactionUseCatalogCapacityInsteadOfLocalFallback() throws {
        for capacity in [8_192, 32_768, 65_536, 131_072, 10_000_000] {
            let model = APIModelDefinition(id: "fixture-\(capacity)", name: "Fixture", contextWindow: capacity)
            let provider = APIProviderDefinition.cerebras.withModels([model])
            let id = apiID(model)
            let registered = try XCTUnwrap(APIProviderCatalog.selection(for: id, providers: [provider]))
            let context = LocalThreadContext.forModel(id, apiModel: registered.model, apiProviderURL: provider.baseURL)
            XCTAssertEqual(context, .remoteAPI(modelID: id, endpoint: provider.baseURL.absoluteString,
                                               contextWindow: capacity))
            XCTAssertEqual(context.contextWindow, capacity)
            XCTAssertNotEqual(context.contextWindow, LocalThreadContext.constrained.contextWindow)
            XCTAssertEqual(context.autoCompactTokenLimit, capacity * 3 / 4)
            XCTAssertLessThan(context.autoCompactTokenLimit, context.contextWindow)
            let config = CodexAppServerRuntime.localThreadConfig(for: id, apiModel: registered.model,
                                                                 apiProviderURL: provider.baseURL)
            XCTAssertEqual(config["model_context_window"] as? Int, capacity)
            XCTAssertEqual(config["model_auto_compact_token_limit"] as? Int, capacity * 3 / 4)
        }
    }

    func testAPICompactionOverrideMustLeaveRoomForNextReply() {
        let model = APIModelDefinition(id: "fixture", name: "Fixture", contextWindow: 32_768)
        let id = apiID(model)
        let accepted = CodexAppServerRuntime.localThreadConfig(
            for: id, autoCompactLimitOverride: 10_000, apiModel: model)
        XCTAssertEqual(accepted["model_auto_compact_token_limit"] as? Int, 10_000)
        for invalid in [0, -1, model.contextWindow, model.contextWindow + 1, Int.max] {
            let config = CodexAppServerRuntime.localThreadConfig(
                for: id, autoCompactLimitOverride: invalid, apiModel: model)
            XCTAssertEqual(config["model_auto_compact_token_limit"] as? Int, 24_576)
            XCTAssertEqual(config["model_context_window"] as? Int, 32_768)
        }
    }

    func testAPIModelSwitchRequiresSameIdentityEndpointAndCapacityWithoutReusingLocalOrBrowserProfile() {
        let first = APIModelDefinition(id: "first", name: "First", contextWindow: 65_536)
        let equalCapacity = APIModelDefinition(id: "second", name: "Second", contextWindow: 65_536)
        let smaller = APIModelDefinition(id: "third", name: "Third", contextWindow: 32_768)
        let endpoint = URL(string: "https://provider-fixture.invalid/v1")!
        let changedEndpoint = URL(string: "https://changed-provider-fixture.invalid/v1")!
        let profile = LocalThreadContext.forModel(apiID(first), apiModel: first, apiProviderURL: endpoint)
        let otherProviderID = APIProviderCatalog.appModelID(providerID: "fixture-other", modelID: equalCapacity.id)
        XCTAssertTrue(profile.supportsModelSwitch(to: apiID(first), apiModel: first, apiProviderURL: endpoint))
        XCTAssertFalse(profile.supportsModelSwitch(to: apiID(equalCapacity), apiModel: equalCapacity, apiProviderURL: endpoint))
        XCTAssertFalse(profile.supportsModelSwitch(to: otherProviderID, apiModel: equalCapacity, apiProviderURL: endpoint))
        XCTAssertFalse(profile.supportsModelSwitch(to: apiID(first), apiModel: first, apiProviderURL: changedEndpoint))
        XCTAssertFalse(profile.supportsModelSwitch(to: apiID(first), apiModel: first),
                       "An unbound endpoint cannot reuse an admitted API thread")
        XCTAssertFalse(profile.supportsModelSwitch(to: apiID(smaller), apiModel: smaller, apiProviderURL: endpoint))
        let changedCapacity = APIModelDefinition(id: first.id, name: first.name, contextWindow: 32_768)
        XCTAssertFalse(profile.supportsModelSwitch(to: apiID(first), apiModel: changedCapacity, apiProviderURL: endpoint))
        XCTAssertFalse(profile.supportsModelSwitch(to: LocalModelCatalog.defaultModelID))
        XCTAssertFalse(profile.supportsModelSwitch(to: LocalModelCatalog.geminiBrowserModelID))
        XCTAssertFalse(LocalThreadContext.webBrowser.supportsModelSwitch(to: apiID(first), apiModel: first),
                       "Equal capacity does not make a browser thread an API thread")
        XCTAssertFalse(LocalThreadContext.constrained.supportsModelSwitch(to: apiID(smaller), apiModel: smaller))
        XCTAssertEqual(LocalThreadContext.forModel(LocalModelCatalog.defaultModelID), .smallModelComputerUse)
        XCTAssertEqual(LocalThreadContext.forModel("legacy-unvalidated-local"), .constrained)
    }

    func testAPICatalogPrefixAndObservedModelEnableNativePatchWithoutChangingLocalProducerContract() throws {
        let id = apiID(APIModelDefinition(id: "future/model", name: "Future"))
        let data = try ComputaModelToolCatalog.catalogData(additionalModelID: id)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        for slug in ["api/", id] {
            let metadata = try XCTUnwrap(models.first { $0["slug"] as? String == slug })
            XCTAssertEqual(metadata["apply_patch_tool_type"] as? String, "freeform")
            XCTAssertEqual(metadata["shell_type"] as? String, "unified_exec")
            XCTAssertEqual(metadata["supported_in_api"] as? Bool, true)
            XCTAssertEqual(metadata["supports_search_tool"] as? Bool, false)
            XCTAssertEqual(metadata["experimental_supported_tools"] as? [String], [])
            XCTAssertEqual(metadata["include_apps_usage_instructions"] as? Bool, false)
            XCTAssertNotNil((metadata["model_messages"] as? [String: Any])?["instructions_template"])
        }
        let local = try XCTUnwrap(models.first { $0["slug"] as? String == LocalModelCatalog.defaultModelID })
        XCTAssertTrue(local["apply_patch_tool_type"] is NSNull)
        XCTAssertEqual(models.filter { $0["slug"] as? String == "api/" }.count, 1)
        XCTAssertFalse(models.contains { $0["slug"] as? String == "future/model" })
    }

    func testUnavailableOrMalformedAPISubmitDispatchesNeitherThreadNorTurn() async throws {
        let model = APIModelDefinition(id: "removed-fixture", name: "Removed")
        let available = APIModelDefinition(id: "available-fixture", name: "Available")
        let cases: [(String, [APIProviderDefinition])] = [
            (apiID(model), []),
            (apiID(model), [.cerebras.withModels([available])]),
            (apiID(model) + "=", [.cerebras.withModels([model])]),
        ]
        for (id, providers) in cases {
            let (runtime, root) = try makeRuntime(modelID: id)
            do {
                try await runtime.configureAPIProviders(providers)
                do {
                    try await runtime.submit(prompt: "Synthetic fixture only", toTaskID: UUID().uuidString, modelID: id)
                    XCTFail("Unavailable API identities must not fall back to another provider")
                } catch {
                    XCTAssertFalse(error.localizedDescription.isEmpty)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-thread-start.json").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-turn-start.json").path))
                let report = await runtime.shutdown()
                XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            } catch {
                _ = await runtime.shutdown()
                throw error
            }
        }
    }

    func testBothAPIWireProfilesUseNativeHarnessAndOnlyLocalTaskScopedInferenceHeaders() async throws {
        let model = APIModelDefinition(id: "fixture/remote-model", name: "Fixture Model", contextWindow: 32_768,
                                       supportsImages: true, supportsToolImages: true)
        for wire in APIProviderDefinition.WireAPI.allCases {
            for accessMode in AccessMode.allCases {
                let provider = APIProviderDefinition(id: "fixture-api", name: "REMOTE_METADATA_ONLY",
                    baseURL: URL(string: "https://provider-fixture.invalid/v1")!, wireAPI: wire, models: [model])
                let id = APIProviderCatalog.appModelID(providerID: provider.id, modelID: model.id)
                let taskID = UUID().uuidString
                let (runtime, root) = try makeRuntime(modelID: id)
                do {
                    try await runtime.configureAPIProviders([provider])
                    try await runtime.submit(prompt: "Synthetic fixture only", toTaskID: taskID,
                                             modelID: id, accessMode: accessMode)
                    let thread = try requestParameters("thread-start", root: root)
                    XCTAssertEqual(thread["model"] as? String, id)
                    XCTAssertEqual(thread["modelProvider"] as? String, "computa_api")
                    XCTAssertEqual(thread["ephemeral"] as? Bool, false)
                    XCTAssertEqual(thread["cwd"] as? String, root.path)
                    XCTAssertEqual(thread["sandbox"] as? String, accessMode == .fullAccess ? "danger-full-access" : "workspace-write")
                    XCTAssertEqual(thread["approvalPolicy"] as? String, accessMode == .fullAccess ? "never" : "on-request")
                    XCTAssertEqual(thread["developerInstructions"] as? String, ComputaAgentInstructions.developerInstructions())
                    let tools = try XCTUnwrap(thread["dynamicTools"] as? [[String: Any]])
                    let names = Set(tools.compactMap { $0["name"] as? String })
                    XCTAssertTrue(names.contains("computer_v2_read_page"))
                    XCTAssertTrue(names.contains("computer_v2_press"))
                    XCTAssertTrue(names.contains("computer_v2_capture"))
                    let config = try XCTUnwrap(thread["config"] as? [String: Any])
                    XCTAssertEqual(config["model_context_window"] as? Int, model.contextWindow)
                    XCTAssertEqual(config["model_auto_compact_token_limit"] as? Int, 24_576)
                    XCTAssertEqual(config["features.unified_exec"] as? Bool, true)
                    XCTAssertEqual(config["features.shell_tool"] as? Bool, true)
                    XCTAssertEqual(config["include_permissions_instructions"] as? Bool, true)
                    XCTAssertEqual(config["include_environment_context"] as? Bool, true)
                    XCTAssertNil(config["model_providers.lmstudio"])
                    XCTAssertNil(config["model_providers.web_browser"])
                    let inference = try XCTUnwrap(config["model_providers.computa_api"] as? [String: Any])
                    XCTAssertEqual(Set(inference.keys), ["name", "base_url", "wire_api", "requires_openai_auth",
                        "supports_websockets", "request_max_retries", "stream_max_retries", "http_headers"])
                    let endpoint = try XCTUnwrap(URL(string: try XCTUnwrap(inference["base_url"] as? String)))
                    XCTAssertEqual(endpoint.scheme, "http")
                    XCTAssertEqual(endpoint.host, "127.0.0.1")
                    XCTAssertEqual(endpoint.path, "/v1")
                    XCTAssertNil(endpoint.user); XCTAssertNil(endpoint.password); XCTAssertNil(endpoint.query)
                    XCTAssertEqual(inference["wire_api"] as? String, "responses")
                    XCTAssertEqual(inference["requires_openai_auth"] as? Bool, false)
                    XCTAssertEqual(inference["supports_websockets"] as? Bool, false)
                    XCTAssertEqual(inference["request_max_retries"] as? Int, 0)
                    XCTAssertEqual(inference["stream_max_retries"] as? Int, 0)
                    let headers = try XCTUnwrap(inference["http_headers"] as? [String: String])
                    XCTAssertEqual(Set(headers.keys), ["Authorization", "X-Computa-Task-ID"])
                    XCTAssertEqual(headers["X-Computa-Task-ID"], taskID)
                    let localAuthorization = try XCTUnwrap(headers["Authorization"])
                    XCTAssertTrue(localAuthorization.hasPrefix("Bearer "))
                    XCTAssertGreaterThan(localAuthorization.utf8.count, "Bearer ".utf8.count)
                    let bytes = try JSONSerialization.data(withJSONObject: thread, options: [.sortedKeys])
                    let engineJSON = try XCTUnwrap(String(data: bytes, encoding: .utf8))
                    XCTAssertFalse(engineJSON.contains(provider.baseURL.absoluteString))
                    XCTAssertFalse(engineJSON.contains("provider-fixture.invalid"))
                    XCTAssertFalse(engineJSON.contains(provider.name))
                    XCTAssertFalse(engineJSON.contains("api_key"))
                    let turn = try requestParameters("turn-start", root: root)
                    XCTAssertEqual(turn["model"] as? String, id)
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
                    _ = await runtime.shutdown()
                    throw error
                }
            }
        }
    }

    #if DEBUG
    func testSuccessfulFailedHistoryCompactionRetiresAPILeaseBeforeOnePendingNormalTurn() async throws {
        try XCTSkipUnless((try? FixtureBunExecutable.resolve()) != nil,
                         "The deterministic App Server fixture requires the installed Bun executable.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaAPICompaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = APIModelDefinition(id: "fixture-compaction", name: "Fixture API", contextWindow: 65_536)
        let provider = APIProviderDefinition(id: "fixture-api", name: "Synthetic API",
            baseURL: URL(string: "https://provider-fixture.invalid/v1")!, wireAPI: .chatCompletions, models: [model])
        let modelID = APIProviderCatalog.appModelID(providerID: provider.id, modelID: model.id)
        let threadID = UUID().uuidString.lowercased()
        let priorTurnID = UUID().uuidString.lowercased()
        let maintenanceTurnID = UUID().uuidString.lowercased()
        let fixtureSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ManagedCompactionAppServer.ts")
        var fixtureText = try String(contentsOf: fixtureSource, encoding: .utf8)
        let substitutions = [
            ("#!/usr/bin/env bun\n", "#!/usr/bin/env bun\nimport { randomUUID } from 'node:crypto';\n"),
            ("const threadId = \"fixture-thread\";", "const threadId = \"\(threadID)\";"),
            ("const modelId = \"lmstudio-community/Qwen3.5-4B-MLX-4bit\";", "const modelId = \"\(modelID)\";"),
            ("const resumedTurnId = \"resume-prior-turn\";", "const resumedTurnId = \"\(priorTurnID)\";"),
            ("const turnId = \"maintenance-turn\";", "const turnId = \"\(maintenanceTurnID)\";"),
            ("const turnId = `user-turn-${index}`;", "const turnId = randomUUID();"),
            ("id: resumedTurnId, status: \"completed\", error: null, itemsView: \"full\", items: [",
             "id: resumedTurnId, status: \"failed\", error: {message:'Synthetic prior failure'}, itemsView: \"full\", items: ["),
        ]
        for (original, replacement) in substitutions {
            guard fixtureText.components(separatedBy: original).count == 2 else {
                throw APICompactionFixtureFailure("The isolated compaction fixture source changed.")
            }
            fixtureText = fixtureText.replacingOccurrences(of: original, with: replacement)
        }
        let fixture = root.appendingPathComponent("fixture.ts")
        try Data(fixtureText.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        try Data("resume-failed-history-api".utf8).write(to: root.appendingPathComponent("scenario"))
        try Data("release".utf8).write(to: root.appendingPathComponent("release-injection"))
        let server = APIModelServer(credentials: APICompactionNoCredentials())
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.executable = .fixture(path: fixture.path)
        configuration.model = modelID
        configuration.codexHomePath = root.path
        configuration.workspacePath = root.path
        let traceURL = root.appendingPathComponent("protocol.jsonl")
        configuration.protocolTracePath = traceURL.path
        configuration.apiModelServerForTesting = server
        let runtime = CodexAppServerRuntime(configuration: configuration)
        do {
            try await runtime.configureAPIProviders([provider])
            let tasks = try await runtime.loadTasks()
            XCTAssertEqual(tasks.map(\.id), [threadID])
            XCTAssertEqual(tasks.first?.model, modelID)
            // This exercises Core's actual maintenance preparation and the
            // actor's unchanged fail-closed admission. The native fixture makes
            // no HTTP inference; a stale maintenance lease rejects this submit.
            try await runtime.submit(prompt: "ONE_PENDING_SYNTHETIC_PROMPT", toTaskID: threadID, modelID: modelID)
            let trace = try AppServerWireTrace.load(traceURL)
            XCTAssertEqual(trace.parseFailures, [])
            let requests = trace.messages.filter { $0.direction == .clientToServer }
            XCTAssertFalse(requests.contains { $0.method == "thread/start" })
            XCTAssertEqual(requests.filter { $0.method == "thread/resume" }.count, 1)
            let compact = try XCTUnwrap(requests.first { $0.method == "thread/compact/start" })
            XCTAssertEqual(requests.filter { $0.method == "thread/compact/start" }.count, 1)
            let compactTerminal = try XCTUnwrap(trace.messages.first {
                guard $0.method == "turn/completed", let params = $0.object["params"] as? [String: Any],
                      let turn = params["turn"] as? [String: Any] else { return false }
                return turn["id"] as? String == maintenanceTurnID && turn["status"] as? String == "completed"
            })
            let starts = requests.filter { $0.method == "turn/start" }
            XCTAssertEqual(starts.count, 1, "Maintenance must not consume or replay the pending normal prompt.")
            let start = try XCTUnwrap(starts.first)
            XCTAssertLessThan(compact.sequence, compactTerminal.sequence)
            XCTAssertLessThan(compactTerminal.sequence, start.sequence)
            let params = try XCTUnwrap(start.object["params"] as? [String: Any])
            XCTAssertEqual(params["threadId"] as? String, threadID)
            XCTAssertEqual(params["model"] as? String, modelID)
            let input = try XCTUnwrap(params["input"] as? [[String: Any]])
            XCTAssertEqual(input.filter { $0["text"] as? String == "ONE_PENDING_SYNTHETIC_PROMPT" }.count, 1)
            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }
    #endif

    private func apiID(_ model: APIModelDefinition) -> String {
        APIProviderCatalog.appModelID(providerID: "cerebras", modelID: model.id)
    }

    private func requestParameters(_ method: String, root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("request-\(method).json"))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(request["params"] as? [String: Any])
    }

    private func makeRuntime(modelID: String) throws -> (CodexAppServerRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaAPIContract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StreamingAppServer.ts")
        var sourceText = try String(contentsOf: source, encoding: .utf8)
        let requestDeclaration = "const request = JSON.parse(line);"
        let threadDeclaration = "const threadId = 'streaming-thread';"
        let turnDeclaration = "const turnId = currentTurn = `streaming-turn-${++turnCount}`;"
        for declaration in [requestDeclaration, threadDeclaration, turnDeclaration] {
            XCTAssertEqual(sourceText.components(separatedBy: declaration).count, 2)
        }
        let recorder = """
        const request = JSON.parse(line);
        if (['thread/start', 'turn/start'].includes(request.method)) {
          writeFileSync(join(root, `request-${request.method.replaceAll('/', '-')}.json`), JSON.stringify(request));
        }
        """
        sourceText = sourceText
            .replacingOccurrences(of: "#!/usr/bin/env bun\n", with: "#!/usr/bin/env bun\nimport { randomUUID } from 'node:crypto';\n")
            .replacingOccurrences(of: threadDeclaration, with: "const threadId = randomUUID();")
            .replacingOccurrences(of: turnDeclaration, with: "const turnId = currentTurn = (++turnCount, randomUUID());")
            .replacingOccurrences(of: requestDeclaration, with: recorder)
        let fixture = root.appendingPathComponent("fixture.ts")
        try Data(sourceText.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        try Data("phase-contract".utf8).write(to: root.appendingPathComponent("scenario"))
        try Data("release".utf8).write(to: root.appendingPathComponent("release-phase-text"))
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.executable = .fixture(path: fixture.path)
        configuration.codexHomePath = root.path
        configuration.workspacePath = root.path
        configuration.model = modelID
        return (CodexAppServerRuntime(configuration: configuration), root)
    }
}

#if DEBUG
private struct APICompactionNoCredentials: APIProviderCredentials {
    func key(for providerID: String) throws -> String? {
        throw APICompactionFixtureFailure("A protocol-only compaction fixture must not read credentials.")
    }
    func save(_ key: String, for providerID: String) throws {
        throw APICompactionFixtureFailure("A protocol-only compaction fixture must not save credentials.")
    }
    func remove(for providerID: String) throws {
        throw APICompactionFixtureFailure("A protocol-only compaction fixture must not remove credentials.")
    }
}

private struct APICompactionFixtureFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
#endif

import Foundation
import XCTest
@testable import Computa

/// Uses only the existing owned JSON-RPC fixture, not a website or a local model.
@MainActor
final class WebModelRuntimeRoutingTests: XCTestCase {
    func testEveryWebsiteRejectsMissingEmbeddedTransportBeforeThreadOrTurnDispatch() async throws {
        for model in websiteModels {
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
        for (model, accessMode) in websiteModels.flatMap({ model in AccessMode.allCases.map { (model, $0) } }) {
            let (runtime, root) = try makeRuntime(modelID: model)
            await runtime.configureEmbeddedWebModelTransport(InertEmbeddedTransport())
            do {
                try await runtime.submit(prompt: "Synthetic reply", toTaskID: UUID().uuidString, modelID: model,
                                         accessMode: accessMode)
                let thread = try requestParameters("thread-start", root: root)
                XCTAssertEqual(thread["model"] as? String, model)
                XCTAssertEqual(thread["modelProvider"] as? String, "web_browser")
                XCTAssertEqual(thread["sandbox"] as? String, accessMode == .fullAccess ? "danger-full-access" : "workspace-write")
                XCTAssertEqual(thread["approvalPolicy"] as? String, accessMode == .fullAccess ? "never" : "on-request")
                XCTAssertEqual(thread["developerInstructions"] as? String, ComputaAgentInstructions.developerInstructions())
                let base = try XCTUnwrap(thread["baseInstructions"] as? String)
                if let baselineBaseInstructions { XCTAssertEqual(base, baselineBaseInstructions) }
                else { baselineBaseInstructions = base }
                let tools = try XCTUnwrap(thread["dynamicTools"] as? [[String: Any]])
                let names = Set(tools.compactMap { $0["name"] as? String })
                XCTAssertTrue(names.contains("computer_v2_read_page"))
                XCTAssertTrue(names.contains("computer_v2_press"))
                XCTAssertFalse(names.contains("computer_v2_capture"))
                let toolBytes = try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
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
                XCTAssertEqual(turn["model"] as? String, model)
                XCTAssertEqual(turn["approvalPolicy"] as? String, accessMode == .fullAccess ? "never" : "on-request")
                let sandbox = try XCTUnwrap(turn["sandboxPolicy"] as? NSDictionary)
                let expected: NSDictionary = accessMode == .fullAccess ? ["type": "dangerFullAccess"] : [
                    "type": "workspaceWrite", "writableRoots": [String](), "networkAccess": false,
                    "excludeTmpdirEnvVar": false, "excludeSlashTmp": false,
                ]
                XCTAssertEqual(sandbox, expected)
                await runtime.disconnectChrome()
                let report = await runtime.shutdown()
                XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            } catch {
                _ = await runtime.shutdown()
                throw error
            }
        }
    }

    private var websiteModels: [String] {
        [LocalModelCatalog.chatGPTBrowserModelID, LocalModelCatalog.geminiBrowserModelID, LocalModelCatalog.claudeBrowserModelID]
            + WebsiteModelCatalog.providers.map {
                WebsiteModelChoice(provider: $0, key: "fixture-choice", label: "Fixture Choice").modelID
            }
    }

    private func requestParameters(_ method: String, root: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: root.appendingPathComponent("request-\(method).json"))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try XCTUnwrap(request["params"] as? [String: Any])
    }

    private func makeRuntime(modelID: String) throws -> (CodexAppServerRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaEmbeddedModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StreamingAppServer.ts")
        let fixture = root.appendingPathComponent("fixture.ts")
        let recorder = """
        const request = JSON.parse(line);
        if (['thread/start', 'turn/start'].includes(request.method)) {
          writeFileSync(join(root, `request-${request.method.replaceAll('/', '-')}.json`), JSON.stringify(request));
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
        try Data("phase-contract".utf8).write(to: root.appendingPathComponent("scenario"))
        try Data("release".utf8).write(to: root.appendingPathComponent("release-phase-text"))
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.executable = .fixture(path: fixture.path)
        configuration.codexHomePath = root.path
        configuration.workspacePath = root.path
        configuration.model = modelID
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
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

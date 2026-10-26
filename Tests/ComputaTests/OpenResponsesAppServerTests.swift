import Foundation
import XCTest
@testable import Computa

/// Executes the verified bundled App Server, its real HTTP Responses client,
/// and the native host tool loop. Only website inference is deterministic:
/// no account, browser view, local model weights, or desktop input is needed.
@MainActor
final class OpenResponsesAppServerTests: XCTestCase {
    func testBundledEngineConsumesCanonicalTextSSEForEveryWebsiteProvider() async throws {
        for model in [syntheticChatGPTModelID, LocalModelCatalog.geminiBrowserModelID,
                      LocalModelCatalog.claudeBrowserModelID] {
            try await qualify(model: model, scenario: .text)
        }
    }

    func testBundledEngineExecutesReadOnlyHostToolAndReturnsItsMatchingOutputToTheModel() async throws {
        try await qualify(model: syntheticChatGPTModelID, scenario: .statusTool)
    }

    func testBundledEngineReusesOneGeminiConversationAcrossSixNativeToolRoundsAndFinalResponse() async throws {
        try await qualify(model: LocalModelCatalog.geminiBrowserModelID, scenario: .sevenToolRounds)
    }

    func testBundledEngineStopsAfterModel500WithoutReplayingInference() async throws {
        try await qualify(model: syntheticChatGPTModelID, scenario: .malformedReply)
    }

    func testBundledEngineStopsAfterQuota429WithoutReplayingInference() async throws {
        try await qualify(model: syntheticChatGPTModelID, scenario: .usageLimit)
    }

    private func qualify(model: String, scenario: EngineInferenceScenario) async throws {
        let artifact: ComputaRuntimeArtifact
        do { artifact = try ComputaRuntimeArtifact.resolve() }
        catch ComputaRuntimeArtifact.ValidationError.resourcesUnavailable {
            throw XCTSkip("The bundled AgentRuntime resource directory is absent in this source-only checkout")
        }
        catch ComputaRuntimeArtifact.ValidationError.unavailableFile {
            throw XCTSkip("The bundled AgentRuntime binary or manifest is absent in this source-only checkout")
        }
        XCTAssertEqual(artifact.manifest.sourceCommit, ComputaRuntimeArtifact.sourceCommit)
        XCTAssertEqual(artifact.executableURL.lastPathComponent, "codex-app-server")
        XCTAssertFalse(artifact.executableURL.path.contains("ChatGPT.app"))

        let failuresBefore = testRun?.failureCount ?? 0
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ComputaOpenResponsesEngine-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("PrivateCodexHome", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        let traceURL = root.appendingPathComponent("app-server-protocol.jsonl")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let taskID = UUID().uuidString.lowercased()
        let marker = "OPEN_RESPONSES_ENGINE_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
        configuration.executable = .bundled
        configuration.model = model
        configuration.codexHomePath = home.path
        configuration.workspacePath = workspace.path
        configuration.protocolTracePath = traceURL.path
        XCTAssertTrue(configuration.isBundled)
        let runtime = CodexAppServerRuntime(configuration: configuration, visualGrounder: EngineNoVisualGrounder())
        let inference = EngineInferenceTransport(scenario: scenario, marker: marker)
        let audit = EngineEventAudit(taskID: taskID)
        let observer = Task {
            for await event in runtime.events() { audit.receive(event) }
        }
        defer { observer.cancel() }
        do {
            // Only the provider proof is synthetic. The actual bundled HTTP
            // client and native turn notifications supply inference context.
            await runtime.configureEmbeddedWebModelTransport(WebsiteInferenceFixtureTransport(inference, defaultChatChoice: syntheticChatGPTChoice))
            let initial = try await runtime.loadTasks()
            XCTAssertTrue(initial.isEmpty, "Only this isolated Codex home may supply thread history")
            try await runtime.configureWorkspace(path: workspace.path, forTaskID: taskID)
            let prompt: String
            switch scenario {
            case .statusTool:
                prompt = "Read computer_v2_status once with empty arguments. After its matching result, reply with the fixture acknowledgment. Do not inspect apps or perform input."
            case .sevenToolRounds:
                prompt = "Read computer_v2_status six times in sequence with empty arguments, waiting for each matching result. Then reply with the fixture acknowledgment. Do not inspect apps or perform input."
            default:
                prompt = "Reply with the fixture acknowledgment. Do not use tools."
            }
            try await runtime.submit(prompt: prompt, toTaskID: taskID, modelID: model)
            let deadline = ContinuousClock.now + .seconds(45)
            while !audit.terminal, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(audit.terminal, "The actual bundled engine did not reach a terminal state within 45 seconds")
            guard audit.terminal else {
                throw EngineTestFailure("Bundled runtime completion timed out")
            }
            XCTAssertEqual(audit.approvals, 0, "A read-only status query cannot request user approval")
            let receipt = await inference.receipt()
            XCTAssertTrue(receipt.requestsWereStreaming)
            XCTAssertTrue(receipt.nativeEncryptedReasoningIncludePresent,
                          "Exercise the unconditional include sent by the actual pinned Codex HTTP client")
            XCTAssertEqual(receipt.requestModels, Array(repeating: model, count: scenario.responseCount))
            let expectedInferences = scenario == .statusTool ? 2 : 1
            XCTAssertEqual(receipt.startCount, expectedInferences)
            XCTAssertEqual(Set(receipt.sessionTokens).count, expectedInferences,
                           "The provider's admitted continuation capability determines physical lease reuse")
            XCTAssertEqual(receipt.sendCount, scenario.responseCount,
                           "Failures must not cause native-client or app-level inference replay")
            if scenario.isFailure {
                XCTAssertEqual(audit.status, .waiting)
                XCTAssertFalse(audit.errors.isEmpty)
                XCTAssertTrue(audit.errors.joined().contains(scenario == .usageLimit ? "website_usage_limit" : "malformed_website_reply"),
                              "The actual HTTP client's terminal error must preserve the structured failure code")
                XCTAssertTrue(audit.assistant.isEmpty, "A failed HTTP inference must not become an assistant answer")
                XCTAssertEqual(receipt.finishCount, expectedInferences)
            } else {
                XCTAssertEqual(audit.status, .completed)
                XCTAssertEqual(audit.errors, [])
                XCTAssertEqual(audit.assistant.last?.body, marker)
                XCTAssertEqual(audit.assistant.last?.assistantPhase, "final_answer")
                XCTAssertEqual(receipt.finishCount, expectedInferences)
            }
            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            observer.cancel()

            let trace = try AppServerWireTrace.load(traceURL)
            XCTAssertEqual(trace.parseFailures, [])
            XCTAssertEqual(trace.messages.filter { $0.method == "turn/start" && $0.direction == .clientToServer }.count, 1)
            let toolRequests = trace.messages.filter { $0.method == "item/tool/call" && $0.direction == .serverToClient }
            if scenario == .statusTool || scenario == .sevenToolRounds {
                XCTAssertTrue(receipt.statusToolOffered)
                XCTAssertTrue(receipt.matchingCallAndOutput)
                XCTAssertTrue(receipt.actualHostStatusOutputPresent)
                XCTAssertEqual(toolRequests.count, scenario.responseCount - 1)
                for call in toolRequests {
                    XCTAssertEqual((call.object["params"] as? [String: Any])?["tool"] as? String, "computer_v2_status")
                    let result = try XCTUnwrap(trace.messages.first {
                        $0.direction == .clientToServer && $0.identifier == call.identifier && $0.object["result"] != nil
                    }?.object["result"] as? [String: Any])
                    XCTAssertEqual(result["success"] as? Bool, true)
                    let content = try XCTUnwrap(result["contentItems"] as? [[String: Any]])
                    let item = try XCTUnwrap(content.only)
                    XCTAssertEqual(item["type"] as? String, "inputText")
                    let text = try XCTUnwrap(item["text"] as? String)
                    XCTAssertTrue(EngineHostStatusProof.matches(text),
                                  "Require the native permission snapshot and the default built-in browser route")
                }
                if scenario == .sevenToolRounds {
                    XCTAssertEqual(receipt.matchingNativeOutputCount, 6)
                    XCTAssertEqual(Set(receipt.nativeCallIDs).count, 6)
                    XCTAssertEqual(Set(receipt.nativeOutputCallIDs), Set(receipt.nativeCallIDs))
                    XCTAssertEqual(receipt.nativeOutputIDs.count, 6)
                    XCTAssertEqual(Set(receipt.nativeOutputIDs).count, 6)
                    XCTAssertTrue(receipt.nativeOutputIDs.allSatisfy { $0.hasPrefix("fco_") && $0.utf8.count == 40 },
                                  "The actual Core assigns and retains prefixed native tool-result item IDs")
                    XCTAssertTrue(receipt.nativeWireMetadataAbsent)
                    XCTAssertEqual(receipt.sentSessionTokens, Array(repeating: try XCTUnwrap(receipt.sessionTokens.only), count: 7))
                    XCTAssertEqual(receipt.finishedSessionTokens, receipt.sessionTokens)
                    XCTAssertTrue(receipt.allNativeHistoriesMatched,
                                  "Each real Core append must contain precisely the preceding native calls and their results")
                }
            } else { XCTAssertTrue(toolRequests.isEmpty) }
            guard (testRun?.failureCount ?? 0) == failuresBefore else {
                throw EngineTestFailure("One or more bundled App Server integration invariants failed")
            }
            print("openResponsesBundledEngine scenario=\(scenario.rawValue) model=\(model) sendCount=\(receipt.sendCount) nativeToolCalls=\(toolRequests.count) outcome=passed")
            try FileManager.default.removeItem(at: root)
        } catch {
            _ = await runtime.shutdown()
            print("openResponsesBundledEngineFailureArtifacts=\(root.path)")
            throw error
        }
    }
}

private enum EngineInferenceScenario: String, Sendable {
    case text, statusTool, sevenToolRounds, malformedReply, usageLimit
    var isFailure: Bool { self == .malformedReply || self == .usageLimit }
    var responseCount: Int { self == .sevenToolRounds ? 7 : self == .statusTool ? 2 : 1 }
}

private struct EngineTestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Validate the actual native status payload, rather than a route substring in
/// arbitrary serialized tool data. Neither permission state requests access.
private enum EngineHostStatusProof {
    static func matches(_ text: String) -> Bool {
        let route = "\nbrowser_route=computa_builtin. "
        guard text.utf8.count <= 512, let boundary = text.range(of: route),
              let permissions = try? JSONSerialization.jsonObject(with: Data(text[..<boundary.lowerBound].utf8)) as? [String: String],
              Set(permissions.keys) == ["accessibility", "screenRecording"],
              permissions.values.allSatisfy({ ["granted", "not-granted"].contains($0) }) else { return false }
        let guidance = text[boundary.upperBound...]
        return guidance.contains("computer_v2_open") && guidance.contains("browser_tabs") &&
            guidance.contains("browser_open") && guidance.contains("browser_read") && !text.contains("chrome_connection=")
    }
}

@MainActor
private final class EngineEventAudit {
    let taskID: String
    var began = false
    var terminal = false
    var status: TaskStatus?
    var assistant = [TimelineEntry]()
    var errors = [String]()
    var approvals = 0
    init(taskID: String) { self.taskID = taskID }
    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case .taskStatusChanged(let id, let value) where id == taskID:
            status = value
            if value == .running { began = true }
            if began && (value == .completed || value == .waiting) { terminal = true }
        case .timelineEntryAppended(let id, let entry) where id == taskID:
            if entry.kind == .assistant { assistant.append(entry) }
            if entry.kind == .system, entry.title == "Agent error" { errors.append(entry.body) }
        case .approvalRequested(let request) where request.taskID == taskID: approvals += 1
        case .connectionChanged(.failed(let message)): errors.append(message); terminal = true
        default: break
        }
    }
}

private actor EngineInferenceTransport: WebModelTransport {
    struct Receipt: Sendable {
        var startCount = 0
        var sendCount = 0
        var finishCount = 0
        var sessionTokens = [String]()
        var requestModels = [String]()
        var requestsWereStreaming = true
        var nativeEncryptedReasoningIncludePresent = true
        var statusToolOffered = false
        var matchingCallAndOutput = false
        var actualHostStatusOutputPresent = false
        var matchingNativeOutputCount = 0
        var nativeCallIDs = [String]()
        var nativeOutputCallIDs = [String]()
        var nativeOutputIDs = [String]()
        var nativeWireMetadataAbsent = true
        var sentSessionTokens = [String]()
        var finishedSessionTokens = [String]()
        var allNativeHistoriesMatched = true
    }
    let scenario: EngineInferenceScenario
    let marker: String
    var token = UUID().uuidString
    var reply = ""
    var observations = Receipt()
    init(scenario: EngineInferenceScenario, marker: String) { self.scenario = scenario; self.marker = marker }
    func receipt() -> Receipt { observations }
    func request(operation: String, params: Data) async throws -> Data {
        let result: [String: Any]
        switch operation {
        case "webProviderStart":
            observations.startCount += 1
            token = UUID().uuidString
            observations.sessionTokens.append(token)
            result = ["sessionToken": token, "state": "ready"]
        case "webProviderSend":
            observations.sendCount += 1
            let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
            observations.sentSessionTokens.append(try XCTUnwrap(parameters["sessionToken"] as? String))
            let prompt = try XCTUnwrap(parameters["prompt"] as? String)
            let bytes = try WebsiteRequestFixture.json(in: prompt)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let prepared = try WebModelResponseCodec.prepareRequest(bytes)
            observations.requestModels.append(prepared.model)
            observations.requestsWereStreaming = observations.requestsWereStreaming && prepared.stream
            observations.nativeEncryptedReasoningIncludePresent = observations.nativeEncryptedReasoningIncludePresent
                && ((object["include"] as? [String])?.contains("reasoning.encrypted_content") == true)
            if scenario == .statusTool || scenario == .sevenToolRounds, observations.sendCount > 1 {
                let items = object["input"] as? [[String: Any]] ?? []
                let calls = items.filter { $0["type"] as? String == "function_call" }
                let outputs = items.filter { $0["type"] as? String == "function_call_output" }
                let callIDs = calls.compactMap { $0["call_id"] as? String }
                let outputIDs = outputs.compactMap { $0["call_id"] as? String }
                let expectedCount = observations.sendCount - 1
                let nativeMatched = calls.count == expectedCount && outputs.count == expectedCount
                    && Set(callIDs).count == expectedCount && Set(outputIDs) == Set(callIDs)
                    && calls.allSatisfy { $0["name"] as? String == "computer_v2_status" && $0["arguments"] as? String == "{}" }
                observations.allNativeHistoriesMatched = observations.allNativeHistoriesMatched && nativeMatched
                observations.matchingCallAndOutput = nativeMatched
                observations.matchingNativeOutputCount = outputs.count
                observations.nativeCallIDs = callIDs
                observations.nativeOutputCallIDs = outputIDs
                observations.nativeOutputIDs = outputs.compactMap { $0["id"] as? String }
                observations.nativeWireMetadataAbsent = observations.nativeWireMetadataAbsent &&
                    outputs.allSatisfy { $0["internal_chat_message_metadata_passthrough"] == nil }
                observations.actualHostStatusOutputPresent = !outputs.isEmpty && outputs.allSatisfy {
                    guard let text = $0["output"] as? String else { return false }
                    return EngineHostStatusProof.matches(text)
                }
            }
            if scenario == .usageLimit { throw EmbeddedWebModelTransport.Failure.usageLimited(.chatgpt) }
            if scenario == .malformedReply { reply = #"{"type":"tool_calls","calls":["# }
            else if (scenario == .statusTool || scenario == .sevenToolRounds), observations.sendCount < scenario.responseCount {
                let name = try XCTUnwrap(prepared.offeredToolNames.first {
                    $0 == "computer_v2_status" || $0.hasSuffix(".computer_v2_status")
                })
                observations.statusToolOffered = true
                reply = String(decoding: try JSONSerialization.data(withJSONObject: [
                    "type": "tool_calls", "calls": [["name": name, "arguments": [:] as [String: String]]],
                ]), as: UTF8.self)
            } else {
                reply = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "message", "text": marker]), as: UTF8.self)
            }
            result = ["state": "running"]
        case "webProviderPoll": result = ["state": "complete", "text": reply]
        case "webProviderFinish", "webProviderCancel":
            observations.finishCount += 1
            let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
            observations.finishedSessionTokens.append(try XCTUnwrap(parameters["sessionToken"] as? String))
            result = ["cleanup": "not_created"]
        default: throw EngineTestFailure("Unexpected deterministic transport operation")
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(result))
    }
}

private struct EngineNoVisualGrounder: VisualGroundingClient {
    func prepare() async throws { throw EngineTestFailure("Visual grounding was unexpectedly requested") }
    func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
        throw EngineTestFailure("Visual grounding was unexpectedly requested")
    }
    func shutdown() async -> [String] { [] }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

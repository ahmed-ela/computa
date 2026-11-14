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

    func testBundledEnginePreservesUnexpectedQwenPage400WithoutReplayingInference() async throws {
        try await qualify(model: syntheticQwenChoice.modelID, scenario: .unexpectedWebsitePage)
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
            try await inference.expectUserPrompt(prompt)
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
            // The synthetic website sees the presentation, not the actual
            // bundled HTTP input. Native API transport controls are validated
            // and retained upstream but omitted from every website's task copy.
            XCTAssertTrue(receipt.websiteAPIOnlyControlsOmitted)
            XCTAssertTrue(receipt.websiteUserTaskAndToolsPreserved)
            XCTAssertEqual(receipt.requestModels, Array(repeating: model, count: scenario.responseCount))
            let expectedInferences = scenario == .statusTool ? 2 : 1
            XCTAssertEqual(receipt.startCount, expectedInferences)
            XCTAssertEqual(Set(receipt.sessionTokens).count, expectedInferences,
                           "The provider's admitted continuation capability determines physical lease reuse")
            XCTAssertEqual(receipt.sendCount, scenario.responseCount,
                           "Failures must not cause native-client or app-level inference replay")
            if scenario.isFailure {
                XCTAssertEqual(audit.status, .failed)
                XCTAssertFalse(audit.errors.isEmpty)
                if scenario == .unexpectedWebsitePage {
                    XCTAssertTrue(audit.errors.joined().contains("unexpected_website_page"))
                    XCTAssertFalse(audit.errors.joined().contains("high demand"))
                } else {
                    XCTAssertTrue(audit.errors.joined().contains(scenario == .usageLimit ? "website_usage_limit" : "malformed_website_reply"),
                                  "The actual HTTP client's terminal error must preserve the structured failure code")
                }
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
            if scenario == .unexpectedWebsitePage {
                // App-layer failure history can replace a generic engine message.
                // Require the raw bundled-engine terminal notification itself to
                // preserve the complete HTTP error body before that overlay.
                let completion = try XCTUnwrap(trace.messages.filter {
                    $0.method == "turn/completed" && $0.direction == .serverToClient
                }.only)
                let params = try XCTUnwrap(completion.object["params"] as? [String: Any])
                let turn = try XCTUnwrap(params["turn"] as? [String: Any])
                XCTAssertEqual(turn["status"] as? String, "failed")
                let error = try XCTUnwrap(turn["error"] as? [String: Any])
                let message = try XCTUnwrap(error["message"] as? String)
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
                let expectedBytes = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.unexpectedPage(.qwen))
                let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: expectedBytes) as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: decoded).isEqual(to: expected))
                XCTAssertTrue(message.contains("unexpected_website_page"))
                XCTAssertTrue(message.contains("inspect_website"))
                XCTAssertFalse(message.contains("high demand"))
                XCTAssertFalse(trace.messages.contains {
                    $0.direction == .serverToClient && $0.method == "error"
                        && ($0.object["params"] as? [String: Any])?["willRetry"] as? Bool == true
                }, "The raw engine must not advertise another inference attempt")
            }
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
                    XCTAssertTrue(receipt.nativeOutputIDs.isEmpty,
                                  "Pinned mactopus16 omits result record IDs from external HTTP copies")
                    XCTAssertTrue(receipt.nativeFunctionRecordIDsAbsent,
                                  "Each external input omits both function-call and result record IDs; call_id remains authoritative")
                    XCTAssertEqual(receipt.nativeRecordIDAbsenceChecks, 6)
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
    case text, statusTool, sevenToolRounds, malformedReply, usageLimit, unexpectedWebsitePage
    var isFailure: Bool { self == .malformedReply || self == .usageLimit || self == .unexpectedWebsitePage }
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
            if began && (value == .completed || value == .waiting || value == .failed) { terminal = true }
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
        var websiteAPIOnlyControlsOmitted = true
        var websiteUserTaskAndToolsPreserved = true
        var statusToolOffered = false
        var matchingCallAndOutput = false
        var actualHostStatusOutputPresent = false
        var matchingNativeOutputCount = 0
        var nativeCallIDs = [String]()
        var nativeOutputCallIDs = [String]()
        var nativeOutputIDs = [String]()
        var nativeFunctionRecordIDsAbsent = true
        var nativeRecordIDAbsenceChecks = 0
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
    private var expectedUserPrompt: String?
    private var currentProvider: String?
    init(scenario: EngineInferenceScenario, marker: String) { self.scenario = scenario; self.marker = marker }
    func receipt() -> Receipt { observations }
    func expectUserPrompt(_ prompt: String) throws {
        guard observations.startCount == 0 else { throw EngineTestFailure("Fixture input must be fixed before inference") }
        expectedUserPrompt = prompt
    }
    func request(operation: String, params: Data) async throws -> Data {
        let result: [String: Any]
        switch operation {
        case "webProviderStart":
            let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
            currentProvider = try XCTUnwrap(parameters["provider"])
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
            let apiOnlyFields = ["include", "reasoning", "client_metadata", "prompt_cache_key", "metadata", "safety_identifier",
                "stream", "stream_options", "store", "background", "service_tier"]
            observations.websiteAPIOnlyControlsOmitted = observations.websiteAPIOnlyControlsOmitted
                && apiOnlyFields.allSatisfy { object[$0] == nil }
            let expectedUserPrompt = try XCTUnwrap(self.expectedUserPrompt)
            let userTexts = (object["input"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
                .flatMap { item -> [String] in
                    if let text = item["content"] as? String { return [text] }
                    return (item["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "input_text" }
                        .compactMap { $0["text"] as? String }
                }
            let tools = object["tools"] as? [[String: Any]]
            observations.websiteUserTaskAndToolsPreserved = observations.websiteUserTaskAndToolsPreserved
                && userTexts.filter { Data($0.utf8) == Data(expectedUserPrompt.utf8) }.count == 1
                && tools?.isEmpty == false
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
                observations.nativeFunctionRecordIDsAbsent = observations.nativeFunctionRecordIDsAbsent
                    && calls.allSatisfy { !$0.keys.contains("id") } && outputs.allSatisfy { !$0.keys.contains("id") }
                observations.nativeRecordIDAbsenceChecks += 1
                observations.nativeWireMetadataAbsent = observations.nativeWireMetadataAbsent &&
                    outputs.allSatisfy { $0["internal_chat_message_metadata_passthrough"] == nil }
                observations.actualHostStatusOutputPresent = !outputs.isEmpty && outputs.allSatisfy {
                    guard let text = $0["output"] as? String else { return false }
                    return EngineHostStatusProof.matches(text)
                }
            }
            if scenario == .usageLimit { throw EmbeddedWebModelTransport.Failure.usageLimited(.chatgpt) }
            if scenario == .unexpectedWebsitePage { throw EmbeddedWebModelTransport.Failure.unexpectedPage(.qwen) }
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
        var snapshot = syntheticPreparedWebsiteSnapshot(result)
        if currentProvider == "chatgpt", operation == "webProviderPoll", snapshot["state"] as? String == "complete" {
            // This inert provider serializes its own exact literal JSON bytes.
            // It must supply the same finite extraction proof required of the
            // live transport; absence or rendered fallback remains a rejection.
            snapshot["completionEvidence"] = ["codeStructure": [
                "selectedExtraction": "raw_code", "extractionReason": "accepted_literal_code"]]
        }
        if scenario == .unexpectedWebsitePage, ["ready", "running", "complete"].contains(snapshot["state"] as? String ?? "") {
            snapshot["modelEvidence"] = ["selected": ["key": syntheticQwenChoice.key, "label": syntheticQwenChoice.label],
                "source": "model_picker_label", "verification": "website_selection"]
        }
        return try JSONSerialization.data(withJSONObject: snapshot)
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

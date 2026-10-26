import Foundation
import XCTest
@testable import Computa

/// Model-free native runtime qualification. The real bundled App Server edits
/// only an isolated test project; a deterministic inference transport supplies
/// protocol replies, without contacting websites or loading local weights.
@MainActor
final class RuntimeFileEditingLiveTests: XCTestCase {
    func testAllWebsiteModelIDsUseNativePatchCommandAndAggregateDiffWithoutChrome() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_FILE_EDITING_ENGINE_TEST"] == "1",
            "Set COMPUTA_FILE_EDITING_ENGINE_TEST=1 for the bundled native patch executor qualification.")
        for model in [syntheticChatGPTModelID, LocalModelCatalog.geminiBrowserModelID, LocalModelCatalog.claudeBrowserModelID] {
            try await qualify(modelID: model)
        }
    }

    func testMalformedAndStaleContextPatchesRejectWithoutWritesBeforeExplicitValidRetry() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_FILE_EDITING_ENGINE_TEST"] == "1",
            "Set COMPUTA_FILE_EDITING_ENGINE_TEST=1 for native patch rejection and continuation qualification.")
        try await qualify(modelID: syntheticChatGPTModelID, failureProbes: true)
    }

    func testRepeatedFastCommandOutputReachesModelTimelineAndReopenedHistory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_FILE_EDITING_ENGINE_TEST"] == "1",
            "Set COMPUTA_FILE_EDITING_ENGINE_TEST=1 for native command transcript qualification.")
        try await qualify(modelID: syntheticChatGPTModelID, commandCount: 32)
    }

    func testChatGPTBundledEnginePreservesProjectedToolIdentityAcrossTwoCommandContinuations() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_FILE_EDITING_ENGINE_TEST"] == "1",
            "Enable the isolated bundled website tool-continuation qualification.")
        let artifact = try ComputaRuntimeArtifact.resolve()
        XCTAssertEqual(artifact.manifest.runtimeVersion, "mactopus-16")
        let failuresBefore = testRun?.failureCount ?? 0
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ComputaWebsiteContinuation-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("PrivateHome", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = choice.modelID
        config.codexHomePath = home.path; config.workspacePath = project.path
        config.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
        let markers = ["WEBSITE_CONTINUATION_FIRST", "WEBSITE_CONTINUATION_SECOND"]
        let transport = NativePatchInferenceFixture(projectPath: project.path, commandMarkers: markers, commandsOnly: true)
        let runtime = CodexAppServerRuntime(configuration: config), audit = PatchAudit()
        let taskID = UUID().uuidString
        let observer = Task { for await event in runtime.events() { audit.receive(event) } }
        defer { observer.cancel() }
        var reopened: CodexAppServerRuntime?
        do {
            await runtime.configureEmbeddedWebModelTransport(WebsiteInferenceFixtureTransport(transport, defaultChatChoice: choice))
            try await runtime.configureWorkspace(path: project.path, forTaskID: taskID)
            try await runtime.submit(prompt: "Run each of the two harmless fixture commands once, then report their observed results.",
                toTaskID: taskID, modelID: choice.modelID)
            let deadline = ContinuousClock.now + .seconds(45)
            while !audit.terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(audit.terminal)
            XCTAssertTrue(audit.errors.isEmpty)
            XCTAssertTrue(audit.approvals.isEmpty)
            XCTAssertTrue(audit.fileEntries.isEmpty)
            XCTAssertEqual(audit.finalTexts.last, "PATCH_HARNESS_OK")
            let commands = audit.commands.filter { $0.toolEvent?.status == .succeeded }
            XCTAssertEqual(Set(commands.map(\.id)).count, 2)
            for marker in markers {
                XCTAssertEqual(Set(commands.filter { $0.toolEvent?.output?.contains(marker) == true }.map(\.id)).count, 1)
            }
            let receipt = await transport.receipt()
            XCTAssertEqual(receipt.startCount, 3); XCTAssertEqual(receipt.sendCount, 3); XCTAssertEqual(receipt.finishCount, 3)
            XCTAssertEqual(Set(receipt.sessionTokens).count, 3)
            XCTAssertTrue(receipt.commandOutputMatched)
            XCTAssertEqual(receipt.requestModels, Array(repeating: choice.modelID, count: 3))
            XCTAssertEqual(receipt.projectedInputs.count, 3); XCTAssertEqual(receipt.expectedCommands.count, 2)
            let inputs = try receipt.projectedInputs.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [[String: Any]]) }
            for (previous, next) in zip(inputs, inputs.dropFirst()) {
                XCTAssertEqual(Array(next.prefix(previous.count)) as NSArray, previous as NSArray,
                    "A later native request must preserve the exact previously accepted projected prefix")
            }
            let finalInput = try XCTUnwrap(inputs.last)
            let calls = finalInput.filter { $0["type"] as? String == "function_call" }
            let outputs = finalInput.filter { $0["type"] as? String == "function_call_output" }
            XCTAssertEqual(calls.count, 2); XCTAssertEqual(outputs.count, 2)
            for (index, call) in calls.enumerated() {
                let expected = try XCTUnwrap(receipt.expectedCommands.dropFirst(index).first)
                let callID = try XCTUnwrap(call["call_id"] as? String)
                XCTAssertNil(call["id"], "The pinned external projection omits local function record IDs")
                XCTAssertEqual(call["name"] as? String, expected.name)
                XCTAssertEqual(call["namespace"] as? String, expected.namespace)
                XCTAssertEqual(call["arguments"] as? String, expected.argumentsJSON)
                let result = try XCTUnwrap(outputs.first { $0["call_id"] as? String == callID })
                XCTAssertNil(result["id"])
                let output = try XCTUnwrap(result["output"] as? String)
                XCTAssertTrue(output.contains(markers[index])); XCTAssertTrue(output.contains("Process exited with code 0"))
            }
            let closed = audit.websiteReceipts.filter { $0.trigger == .inference && $0.outcome == .closed }
            XCTAssertEqual(Set(closed.compactMap(\.inferenceID)).count, 3)
            XCTAssertEqual(Set(closed.compactMap(\.sessionToken)), Set(receipt.sessionTokens.map { $0.lowercased() }))
            XCTAssertTrue(closed.allSatisfy { $0.receiptSaved && $0.provider == .chatgpt && $0.modelID == choice.modelID })
            let shutdown = await runtime.shutdown()
            XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
            observer.cancel()
            let wire = try AppServerWireTrace.load(root.appendingPathComponent("protocol.jsonl"))
            XCTAssertTrue(wire.parseFailures.isEmpty)
            XCTAssertEqual(wire.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }.count, 1)
            // Inspect only this synthetic fixture's canonical rollout, which keeps
            // the IDs omitted by external wire projection and exact arguments.
            var canonical = [[String: Any]]()
            let files = FileManager.default.enumerator(at: home.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "jsonl" else { continue }
                for line in try Data(contentsOf: file).split(separator: 0x0A) {
                    let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                    if record["type"] as? String == "response_item", let item = record["payload"] as? [String: Any] {
                        canonical.append(item)
                    }
                }
            }
            for call in calls {
                let callID = try XCTUnwrap(call["call_id"] as? String)
                let originalCalls = canonical.filter { $0["type"] as? String == "function_call" && $0["call_id"] as? String == callID }
                let originalOutputs = canonical.filter { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == callID }
                XCTAssertEqual(originalCalls.count, 1); XCTAssertEqual(originalOutputs.count, 1)
                let original = try XCTUnwrap(originalCalls.first), output = try XCTUnwrap(originalOutputs.first)
                XCTAssertTrue((original["id"] as? String)?.hasPrefix("fc_") == true)
                XCTAssertTrue((output["id"] as? String)?.hasPrefix("fco_") == true)
                for key in ["call_id", "name", "namespace", "arguments"] {
                    XCTAssertEqual(original[key] as? String, call[key] as? String)
                }
                XCTAssertEqual(output["output"] as? String, outputs.first { $0["call_id"] as? String == callID }?["output"] as? String)
            }
            var coldConfig = config; coldConfig.protocolTracePath = root.appendingPathComponent("cold-protocol.jsonl").path
            let cold = CodexAppServerRuntime(configuration: coldConfig); reopened = cold
            let restored = try await cold.loadTasks()
            let task = try XCTUnwrap(restored.first)
            XCTAssertEqual(task.status, .completed)
            XCTAssertEqual(task.entries.filter { $0.toolEvent?.name == "commandExecution" && $0.toolEvent?.status == .succeeded }.count, 2)
            XCTAssertEqual(task.entries.last { $0.kind == .assistant }?.body, "PATCH_HARNESS_OK")
            let coldShutdown = await cold.shutdown(); XCTAssertTrue(coldShutdown.succeeded)
            reopened = nil
            let coldWire = try AppServerWireTrace.load(root.appendingPathComponent("cold-protocol.jsonl"))
            XCTAssertTrue(coldWire.parseFailures.isEmpty)
            XCTAssertFalse(coldWire.messages.contains { $0.direction == .clientToServer && $0.method == "turn/start" })
            let afterReload = await transport.receipt(); XCTAssertEqual(afterReload.sendCount, 3)
            guard (testRun?.failureCount ?? 0) == failuresBefore else {
                throw NSError(domain: "ComputaWebsiteContinuationQualification", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Synthetic native website continuation invariants failed."])
            }
            try FileManager.default.removeItem(at: root)
        } catch {
            if let reopened { _ = await reopened.shutdown() }
            _ = await runtime.shutdown()
            print("nativeWebsiteContinuationFailureArtifacts=\(root.path)")
            throw error
        }
    }

    private func qualify(modelID: String, failureProbes: Bool = false, commandCount: Int = 1) async throws {
        precondition((1...32).contains(commandCount))
        let commandMarkers = (0..<commandCount).map {
            commandCount == 1 ? "PATCH_TEST_OK" : String(format: "PATCH_TEST_OK_%03d", $0)
        }
        let failuresBefore = testRun?.failureCount ?? 0
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ComputaNativePatch-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("PrivateHome", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("def greet(name):\n    return \"old\"\n".utf8).write(to: project.appendingPathComponent("hello.py"))
        try Data("obsolete\n".utf8).write(to: project.appendingPathComponent("obsolete.txt"))
        try Data("def multiply(a, b):\n    return a * b\n".utf8).write(to: project.appendingPathComponent("legacy.py"))
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.codexHomePath = home.path
        config.workspacePath = home.appendingPathComponent("Workspace", isDirectory: true).path
        config.model = modelID
        config.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
        let runtime = CodexAppServerRuntime(configuration: config)
        let transport = NativePatchInferenceFixture(projectPath: project.path, failureProbes: failureProbes,
            commandMarkers: commandMarkers)
        let audit = PatchAudit()
        let taskID = UUID().uuidString.lowercased()
        let observer = Task { [audit] in
            for await event in runtime.events() { audit.receive(event) }
        }
        var reopenedRuntime: CodexAppServerRuntime?
        do {
            // The deterministic provider supplies lease proof; the real
            // native runtime supplies its actual inference and turn context.
            await runtime.configureEmbeddedWebModelTransport(WebsiteInferenceFixtureTransport(transport, defaultChatChoice: syntheticChatGPTChoice))
            try await runtime.configureWorkspace(path: project.path, forTaskID: taskID)
            try await runtime.submit(prompt: "Apply the requested isolated fixture edits and run its assertion.",
                toTaskID: taskID, modelID: modelID)
            let deadline = ContinuousClock.now + .seconds(45)
            while !audit.terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(audit.terminal, "The native executor did not finish within its bounded deadline")
            XCTAssertEqual(audit.errors, [])
            XCTAssertEqual(audit.approvals.count, 0, "Workspace-local patch and assertion must use the selected engine workspace")
            let completed = try XCTUnwrap(audit.fileEntries.last { $0.toolEvent?.status == .succeeded })
            XCTAssertEqual(completed.toolEvent?.status, .succeeded)
            XCTAssertEqual(Set(completed.fileChanges?.map(\.kind) ?? []), Set(["add", "update", "delete"]))
            XCTAssertEqual(completed.fileChanges?.first(where: { $0.path.hasSuffix("/hello.py") })?.movePath,
                project.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("lib/greetings.py").path)
            let pureMove = try XCTUnwrap(completed.fileChanges?.first { $0.path.hasSuffix("/legacy.py") })
            XCTAssertEqual(pureMove.kind, "update")
            XCTAssertEqual(pureMove.movePath, project.appendingPathComponent("helpers.py").path)
            XCTAssertEqual(pureMove.diff, "", "Native move display metadata is not a content diff")
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("lib/greetings.py"), encoding: .utf8),
                "def greet(name):\n    return f\"Hello, {name}!\"\n")
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8), "created by native apply_patch\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("hello.py").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("obsolete.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("legacy.py").path))
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("helpers.py"), encoding: .utf8),
                "def multiply(a, b):\n    return a * b\n")
            let diff = try XCTUnwrap(audit.diffs.last)
            XCTAssertFalse(diff.diff.isEmpty)
            XCTAssertTrue(diff.diff.contains("lib/greetings.py"))
            XCTAssertTrue(diff.diff.contains("obsolete.txt"))
            XCTAssertTrue(diff.diff.contains("notes.txt"))
            XCTAssertEqual(completed.turnID, diff.id)
            XCTAssertEqual(audit.finalTexts.last, "PATCH_HARNESS_OK")
            let command = try XCTUnwrap(audit.commands.last)
            XCTAssertEqual(command.toolEvent?.status, .succeeded)
            XCTAssertTrue(command.toolEvent?.output?.contains("PATCH_TEST_OK") == true)
            let completedCommands = audit.commands.filter { $0.toolEvent?.status == .succeeded }
            XCTAssertEqual(Set(completedCommands.map(\.id)).count, commandCount)
            var completedCommandIDs = [String: String]()
            for marker in commandMarkers {
                let matching = completedCommands.filter { $0.toolEvent?.output?.contains(marker) == true }
                XCTAssertEqual(Set(matching.map(\.id)).count, 1,
                    "Every fast command must retain its distinct completed transcript: \(marker)")
                let input = try XCTUnwrap(matching.last?.toolEvent?.input)
                XCTAssertEqual(commandMarkers.filter { input.contains($0) }, [marker],
                    "Output must belong to the command that printed its marker")
                completedCommandIDs[marker] = matching.last?.id
            }
            XCTAssertEqual(Set(completedCommandIDs.values).count, commandCount,
                "Separate commands must have separate completed items")
            let receipt = await transport.receipt()
            let expectedInferences = commandCount + 2 + (failureProbes ? 2 : 0)
            XCTAssertEqual(receipt.sendCount, expectedInferences)
            XCTAssertEqual(receipt.startCount, expectedInferences)
            XCTAssertEqual(receipt.finishCount, expectedInferences)
            XCTAssertEqual(Set(receipt.sessionTokens).count, expectedInferences)
            XCTAssertTrue(receipt.customPatchOffered)
            XCTAssertTrue(receipt.patchOutputMatched)
            XCTAssertTrue(receipt.commandOutputMatched)
            XCTAssertEqual(receipt.requestModels, Array(repeating: modelID, count: expectedInferences))
            if failureProbes {
                XCTAssertTrue(receipt.malformedPatchRejected)
                XCTAssertTrue(receipt.staleContextRejected)
                XCTAssertTrue(receipt.rejectedPatchesDidNotWrite)
            }
            do {
                try await runtime.configureWorkspace(path: root.path, forTaskID: taskID)
                XCTFail("A started chat must keep its original project folder")
            } catch { XCTAssertTrue(error.localizedDescription.contains("original folder")) }
            audit.terminal = false
            try await runtime.submit(prompt: "Give a brief confirmation without editing files.",
                toTaskID: taskID, modelID: modelID)
            let noEditDeadline = ContinuousClock.now + .seconds(30)
            while !audit.terminal, ContinuousClock.now < noEditDeadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(audit.terminal)
            let noEditDiff = try XCTUnwrap(audit.diffs.last)
            XCTAssertNotEqual(noEditDiff.id, diff.id)
            XCTAssertEqual(noEditDiff.diff, "", "Last turn means the latest actual user turn, even if it made no edits")
            XCTAssertEqual(audit.fileEntries.filter { $0.toolEvent?.status == .succeeded }.count, 1)
            let noEditReceipt = await transport.receipt()
            XCTAssertEqual(noEditReceipt.sendCount, expectedInferences + 1)
            XCTAssertEqual(noEditReceipt.startCount, expectedInferences + 1)
            XCTAssertEqual(noEditReceipt.finishCount, expectedInferences + 1)
            XCTAssertEqual(Set(noEditReceipt.sessionTokens).count, expectedInferences + 1)
            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            observer.cancel()
            // Verify locally saved engine aggregates and upstream item history
            // survive a fresh runtime, without replaying any edit or inference.
            var reopenedConfig = config
            reopenedConfig.protocolTracePath = root.appendingPathComponent("history-reopen-protocol.jsonl").path
            let reopened = CodexAppServerRuntime(configuration: reopenedConfig)
            reopenedRuntime = reopened
            let tasks = try await reopened.loadTasks()
            let saved = try XCTUnwrap(tasks.first)
            XCTAssertEqual(URL(fileURLWithPath: saved.workspace, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath(),
                project.standardizedFileURL.resolvingSymlinksInPath())
            XCTAssertTrue(saved.turnDiffs.contains(diff))
            XCTAssertEqual(saved.turnDiffs.last, noEditDiff)
            let savedCommand = try XCTUnwrap(saved.entries.last {
                $0.toolEvent?.name == "commandExecution" && $0.toolEvent?.status == .succeeded
            })
            XCTAssertTrue(savedCommand.toolEvent?.output?.contains("PATCH_TEST_OK") == true,
                "The canonical command transcript must survive reopening saved history")
            let savedCommands = saved.entries.filter {
                $0.toolEvent?.name == "commandExecution" && $0.toolEvent?.status == .succeeded
            }
            XCTAssertEqual(savedCommands.count, commandCount)
            for marker in commandMarkers {
                let matching = savedCommands.filter { $0.toolEvent?.output?.contains(marker) == true }
                XCTAssertEqual(matching.count, 1, "Saved history must retain each command: \(marker)")
                XCTAssertEqual(matching.first?.id, completedCommandIDs[marker],
                    "Saved history must retain the original command identity")
                let savedInput = try XCTUnwrap(matching.first?.toolEvent?.input)
                XCTAssertEqual(commandMarkers.filter { savedInput.contains($0) }, [marker])
            }
            XCTAssertEqual(saved.entries.filter { $0.toolEvent?.name == "fileChange" && $0.toolEvent?.status == .succeeded }.last?.fileChanges, completed.fileChanges)
            let savedPureMove = try XCTUnwrap(saved.entries.filter { $0.toolEvent?.name == "fileChange" && $0.toolEvent?.status == .succeeded }
                .last?.fileChanges?.first { $0.path.hasSuffix("/legacy.py") })
            XCTAssertEqual(savedPureMove.movePath, pureMove.movePath)
            XCTAssertEqual(savedPureMove.diff, "", "History must normalize the same metadata-only move after reopening")
            let reopenedReport = await reopened.shutdown()
            XCTAssertTrue(reopenedReport.succeeded, reopenedReport.issues.joined(separator: "; "))
            reopenedRuntime = nil
            guard (testRun?.failureCount ?? 0) == failuresBefore else {
                throw NSError(domain: "ComputaNativePatchQualification", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "One or more native patch qualification invariants failed; exact fixture artifacts were retained."])
            }
            try FileManager.default.removeItem(at: root)
            print("nativePatchProvider=\(modelID) outcome=passed successfulPatchCalls=1 rejectedPatchCalls=\(failureProbes ? 2 : 0) commandCalls=\(commandCount) replayedCalls=0")
        } catch {
            if let reopenedRuntime { _ = await reopenedRuntime.shutdown() }
            _ = await runtime.shutdown()
            observer.cancel()
            // Failed qualification keeps its exact bounded fixture artifacts.
            print("nativePatchFailureArtifacts=\(root.path)")
            throw error
        }
    }
}

@MainActor
private final class PatchAudit {
    var terminal = false
    var fileEntries = [TimelineEntry]()
    var commands = [TimelineEntry]()
    var diffs = [AgentTurnDiff]()
    var finalTexts = [String]()
    var errors = [String]()
    var approvals = [ActionApprovalRequest]()
    var websiteReceipts = [WebsiteSessionCleanupReceipt]()
    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case .timelineEntryAppended(_, let entry):
            if entry.toolEvent?.name == "fileChange" { fileEntries.append(entry) }
            if entry.toolEvent?.name == "commandExecution" { commands.append(entry) }
            if entry.kind == .assistant { finalTexts.append(entry.body) }
            if entry.kind == .system, ["Agent error", "Saved chat history unavailable"].contains(entry.title) { errors.append(entry.body) }
        case .turnDiffUpdated(_, let turnID, let diff): diffs.append(AgentTurnDiff(id: turnID, diff: diff))
        case .taskStatusChanged(_, let status): if status == .completed || status == .waiting { terminal = true }
        case .approvalRequested(let request): approvals.append(request)
        case .websiteSessionCleanupUpdated(let receipt): websiteReceipts.append(receipt)
        case .connectionChanged(.failed(let message)): errors.append(message); terminal = true
        default: break
        }
    }
}

private actor NativePatchInferenceFixture: WebModelTransport {
    struct Receipt: Sendable {
        var startCount = 0
        var finishCount = 0
        var sessionTokens = [String]()
        var sendCount = 0
        var customPatchOffered = false
        var patchOutputMatched = false
        var commandOutputMatched = false
        var malformedPatchRejected = false
        var staleContextRejected = false
        var rejectedPatchesDidNotWrite = false
        var requestModels = [String]()
        var projectedInputs = [Data]()
        var expectedCommands = [WebModelResponseCodec.ToolCall]()
    }
    private var token = UUID().uuidString
    private let projectPath: String
    private let failureProbes: Bool
    private let commandMarkers: [String]
    private let commandsOnly: Bool
    private var response = ""
    private var observations = Receipt()
    init(projectPath: String, failureProbes: Bool = false, commandMarkers: [String] = ["PATCH_TEST_OK"], commandsOnly: Bool = false) {
        self.projectPath = projectPath
        self.failureProbes = failureProbes
        self.commandMarkers = commandMarkers
        self.commandsOnly = commandsOnly
    }
    func receipt() -> Receipt { observations }
    func request(operation: String, params: Data) throws -> Data {
        var result: [String: Any]
        switch operation {
        case "webProviderStart":
            token = UUID().uuidString
            observations.startCount += 1
            observations.sessionTokens.append(token)
            result = ["sessionToken": token, "state": "ready"]
        case "webProviderSend":
            let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
            let prompt = try XCTUnwrap(parameters["prompt"] as? String)
            let data = try WebsiteRequestFixture.json(in: prompt)
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let request = try WebModelResponseCodec.prepareRequest(data)
            observations.requestModels.append(request.model)
            let patchName = request.offeredToolNames.first { $0 == "apply_patch" || $0.hasSuffix(".apply_patch") }
            observations.customPatchOffered = observations.customPatchOffered || patchName != nil
            let items = input["input"] as? [[String: Any]] ?? []
            if commandsOnly { observations.projectedInputs.append(try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys, .withoutEscapingSlashes])) }
            let outputs = items.filter { ["custom_tool_call_output", "function_call_output"].contains($0["type"] as? String ?? "") }
            let outputsJSON = String(decoding: try JSONSerialization.data(withJSONObject: outputs), as: UTF8.self)
            let progress = observations.sendCount - (failureProbes ? 2 : 0) + (commandsOnly ? 1 : 0)
            if failureProbes, observations.sendCount == 0 {
                response = try patchReply(name: XCTUnwrap(patchName), patch: "*** Begin Patch\n*** Invalid Operation: hello.py\n*** End Patch")
            } else if failureProbes, observations.sendCount == 1 {
                observations.malformedPatchRejected = outputsJSON.contains("apply_patch verification failed")
                response = try patchReply(name: XCTUnwrap(patchName), patch: "*** Begin Patch\n*** Update File: hello.py\n@@\n-this context does not exist\n+must not appear\n*** End Patch")
            } else if progress == 0 {
                if failureProbes {
                    observations.staleContextRejected = outputsJSON.contains("Failed to find expected lines")
                    let project = URL(fileURLWithPath: projectPath, isDirectory: true)
                    observations.rejectedPatchesDidNotWrite = try String(contentsOf: project.appendingPathComponent("hello.py"), encoding: .utf8) == "def greet(name):\n    return \"old\"\n"
                        && FileManager.default.fileExists(atPath: project.appendingPathComponent("obsolete.txt").path)
                        && !FileManager.default.fileExists(atPath: project.appendingPathComponent("notes.txt").path)
                        && !FileManager.default.fileExists(atPath: project.appendingPathComponent("lib/greetings.py").path)
                        && !FileManager.default.fileExists(atPath: project.appendingPathComponent("helpers.py").path)
                        && String(contentsOf: project.appendingPathComponent("legacy.py"), encoding: .utf8) == "def multiply(a, b):\n    return a * b\n"
                }
                let patch = """
                *** Begin Patch
                *** Add File: notes.txt
                +created by native apply_patch
                *** Update File: hello.py
                *** Move to: lib/greetings.py
                @@
                -def greet(name):
                -    return "old"
                +def greet(name):
                +    return f"Hello, {name}!"
                *** Update File: legacy.py
                *** Move to: helpers.py
                @@
                 def multiply(a, b):
                     return a * b
                *** Delete File: obsolete.txt
                *** End Patch
                """
                response = try patchReply(name: XCTUnwrap(patchName), patch: patch)
            } else if (1...commandMarkers.count).contains(progress) {
                observations.patchOutputMatched = observations.patchOutputMatched
                    || outputsJSON.contains("Success. Updated the following files")
                let commandName = try XCTUnwrap(request.offeredToolNames.first { $0 == "exec_command" || $0.hasSuffix(".exec_command") })
                let marker = commandMarkers[progress - 1]
                let command = commandsOnly ? "/usr/bin/printf '%s\\n' '\(marker)'" : "/usr/bin/python3 -c 'from lib.greetings import greet; from helpers import multiply; assert greet(\"Computa\") == \"Hello, Computa!\"; assert multiply(2, 3) == 6; print(\"\(marker)\")'"
                response = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [["name": commandName, "arguments": ["cmd": command, "workdir": projectPath, "yield_time_ms": 10000, "max_output_tokens": 1000]]]]), as: UTF8.self)
            } else {
                var commandCallIDs = Set<String>()
                var allCommandOutputsMatched = true
                // Keep non-Sendable JSON dictionaries inside this actor's
                // synchronous execution, rather than capturing them in a
                // closure invoked through an actor-isolated stored collection.
                for marker in commandMarkers {
                    var matchingOutput: [String: Any]?
                    var matchingOutputCount = 0
                    for candidate in outputs {
                        if candidate["type"] as? String == "function_call_output",
                           let candidateOutput = candidate["output"] as? String,
                           candidateOutput.contains(marker) {
                            matchingOutput = candidate
                            matchingOutputCount += 1
                        }
                    }
                    guard matchingOutputCount == 1,
                          let output = matchingOutput?["output"] as? String,
                          output.contains("Process exited with code 0"),
                          let callID = matchingOutput?["call_id"] as? String, !callID.isEmpty else {
                        allCommandOutputsMatched = false
                        break
                    }
                    var matchingCall: [String: Any]?
                    var matchingCallCount = 0
                    for candidate in items {
                        if candidate["type"] as? String == "function_call",
                           candidate["call_id"] as? String == callID {
                            matchingCall = candidate
                            matchingCallCount += 1
                        }
                    }
                    guard matchingCallCount == 1, let arguments = matchingCall?["arguments"] as? String,
                          let params = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
                          let cmd = params["cmd"] as? String else {
                        allCommandOutputsMatched = false
                        break
                    }
                    var commandInputMarkers = [String]()
                    for expectedMarker in commandMarkers where cmd.contains(expectedMarker) {
                        commandInputMarkers.append(expectedMarker)
                    }
                    guard commandInputMarkers == [marker] else {
                        allCommandOutputsMatched = false
                        break
                    }
                    commandCallIDs.insert(callID)
                }
                observations.commandOutputMatched = allCommandOutputsMatched
                    && commandCallIDs.count == commandMarkers.count
                response = #"{"type":"message","text":"PATCH_HARNESS_OK"}"#
            }
            if commandsOnly, case .toolCalls(let calls) = try WebModelResponseCodec.parseEmbeddedReply(response, request: request) {
                observations.expectedCommands.append(contentsOf: calls)
            }
            observations.sendCount += 1
            result = ["state": "running"]
        case "webProviderPoll": result = ["state": "complete", "text": response]
        case "webProviderFinish", "webProviderCancel":
            observations.finishCount += 1
            result = ["cleanup": "not_created"]
        default: throw WebModelServer.Failure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(result))
    }

    private func patchReply(name: String, patch: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [["name": name, "input": patch]]]), as: UTF8.self)
    }
}

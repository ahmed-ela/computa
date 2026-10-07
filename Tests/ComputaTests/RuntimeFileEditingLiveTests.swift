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
        for model in [LocalModelCatalog.chatGPTBrowserModelID, LocalModelCatalog.geminiBrowserModelID, LocalModelCatalog.claudeBrowserModelID] {
            try await qualify(modelID: model)
        }
    }

    func testMalformedAndStaleContextPatchesRejectWithoutWritesBeforeExplicitValidRetry() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_FILE_EDITING_ENGINE_TEST"] == "1",
            "Set COMPUTA_FILE_EDITING_ENGINE_TEST=1 for native patch rejection and continuation qualification.")
        try await qualify(modelID: LocalModelCatalog.chatGPTBrowserModelID, failureProbes: true)
    }

    private func qualify(modelID: String, failureProbes: Bool = false) async throws {
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
        let runtime = CodexAppServerRuntime(configuration: config)
        let transport = NativePatchInferenceFixture(projectPath: project.path, failureProbes: failureProbes)
        let audit = PatchAudit()
        let observer = Task { [audit] in
            for await event in runtime.events() { audit.receive(event) }
        }
        do {
            await runtime.configureEmbeddedWebModelTransport(transport)
            try await runtime.configureWorkspace(path: project.path, forTaskID: "qualification")
            try await runtime.submit(prompt: "Apply the requested isolated fixture edits and run its assertion.",
                toTaskID: "qualification", modelID: modelID)
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
            let receipt = await transport.receipt()
            let expectedInferences = failureProbes ? 5 : 3
            XCTAssertEqual(receipt.sendCount, expectedInferences)
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
                try await runtime.configureWorkspace(path: root.path, forTaskID: "qualification")
                XCTFail("A started chat must keep its original project folder")
            } catch { XCTAssertTrue(error.localizedDescription.contains("original folder")) }
            audit.terminal = false
            try await runtime.submit(prompt: "Give a brief confirmation without editing files.",
                toTaskID: "qualification", modelID: modelID)
            let noEditDeadline = ContinuousClock.now + .seconds(30)
            while !audit.terminal, ContinuousClock.now < noEditDeadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(audit.terminal)
            let noEditDiff = try XCTUnwrap(audit.diffs.last)
            XCTAssertNotEqual(noEditDiff.id, diff.id)
            XCTAssertEqual(noEditDiff.diff, "", "Last turn means the latest actual user turn, even if it made no edits")
            XCTAssertEqual(audit.fileEntries.filter { $0.toolEvent?.status == .succeeded }.count, 1)
            let noEditReceipt = await transport.receipt()
            XCTAssertEqual(noEditReceipt.sendCount, expectedInferences + 1)
            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            observer.cancel()
            // Verify locally saved engine aggregates and upstream item history
            // survive a fresh runtime, without replaying any edit or inference.
            let reopened = CodexAppServerRuntime(configuration: config)
            let tasks = try await reopened.loadTasks()
            let saved = try XCTUnwrap(tasks.first)
            XCTAssertEqual(URL(fileURLWithPath: saved.workspace, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath(),
                project.standardizedFileURL.resolvingSymlinksInPath())
            XCTAssertTrue(saved.turnDiffs.contains(diff))
            XCTAssertEqual(saved.turnDiffs.last, noEditDiff)
            XCTAssertEqual(saved.entries.filter { $0.toolEvent?.name == "fileChange" && $0.toolEvent?.status == .succeeded }.last?.fileChanges, completed.fileChanges)
            let savedPureMove = try XCTUnwrap(saved.entries.filter { $0.toolEvent?.name == "fileChange" && $0.toolEvent?.status == .succeeded }
                .last?.fileChanges?.first { $0.path.hasSuffix("/legacy.py") })
            XCTAssertEqual(savedPureMove.movePath, pureMove.movePath)
            XCTAssertEqual(savedPureMove.diff, "", "History must normalize the same metadata-only move after reopening")
            let reopenedReport = await reopened.shutdown()
            XCTAssertTrue(reopenedReport.succeeded, reopenedReport.issues.joined(separator: "; "))
            guard (testRun?.failureCount ?? 0) == failuresBefore else {
                throw NSError(domain: "ComputaNativePatchQualification", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "One or more native patch qualification invariants failed; exact fixture artifacts were retained."])
            }
            try FileManager.default.removeItem(at: root)
            print("nativePatchProvider=\(modelID) outcome=passed successfulPatchCalls=1 rejectedPatchCalls=\(failureProbes ? 2 : 0) commandCalls=1 replayedCalls=0")
        } catch {
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
        case .connectionChanged(.failed(let message)): errors.append(message); terminal = true
        default: break
        }
    }
}

private actor NativePatchInferenceFixture: WebModelTransport {
    struct Receipt: Sendable {
        var sendCount = 0
        var customPatchOffered = false
        var patchOutputMatched = false
        var commandOutputMatched = false
        var malformedPatchRejected = false
        var staleContextRejected = false
        var rejectedPatchesDidNotWrite = false
        var requestModels = [String]()
    }
    private let token = UUID().uuidString
    private let projectPath: String
    private let failureProbes: Bool
    private var response = ""
    private var observations = Receipt()
    init(projectPath: String, failureProbes: Bool = false) { self.projectPath = projectPath; self.failureProbes = failureProbes }
    func receipt() -> Receipt { observations }
    func request(operation: String, params: Data) throws -> Data {
        var result: [String: Any]
        switch operation {
        case "webProviderStart": result = ["sessionToken": token, "state": "ready"]
        case "webProviderSend":
            let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
            let prompt = try XCTUnwrap(parameters["prompt"] as? String)
            let start = try XCTUnwrap(prompt.range(of: "COMPLETE_RESPONSES_REQUEST_JSON:\n"))
            let end = try XCTUnwrap(prompt.range(of: "\nEND_COMPLETE_RESPONSES_REQUEST_JSON.", range: start.upperBound..<prompt.endIndex))
            let data = Data(prompt[start.upperBound..<end.lowerBound].utf8)
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let request = try WebModelResponseCodec.prepareRequest(data)
            observations.requestModels.append(request.model)
            let patchName = request.offeredToolNames.first { $0 == "apply_patch" || $0.hasSuffix(".apply_patch") }
            observations.customPatchOffered = observations.customPatchOffered || patchName != nil
            let items = input["input"] as? [[String: Any]] ?? []
            let outputs = items.filter { ["custom_tool_call_output", "function_call_output"].contains($0["type"] as? String ?? "") }
            let outputsJSON = String(decoding: try JSONSerialization.data(withJSONObject: outputs), as: UTF8.self)
            let progress = observations.sendCount - (failureProbes ? 2 : 0)
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
            } else if progress == 1 {
                observations.patchOutputMatched = outputsJSON.contains("Success. Updated the following files")
                let commandName = try XCTUnwrap(request.offeredToolNames.first { $0 == "exec_command" || $0.hasSuffix(".exec_command") })
                let command = "/usr/bin/python3 -c 'from lib.greetings import greet; from helpers import multiply; assert greet(\"Computa\") == \"Hello, Computa!\"; assert multiply(2, 3) == 6; print(\"PATCH_TEST_OK\")'"
                response = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [["name": commandName, "arguments": ["cmd": command, "workdir": projectPath, "yield_time_ms": 10000, "max_output_tokens": 1000]]]]), as: UTF8.self)
            } else {
                observations.commandOutputMatched = outputsJSON.contains("PATCH_TEST_OK") && outputsJSON.contains("Process exited with code 0")
                response = #"{"type":"message","text":"PATCH_HARNESS_OK"}"#
            }
            observations.sendCount += 1
            result = ["state": "running"]
        case "webProviderPoll": result = ["state": "complete", "text": response]
        case "webProviderFinish", "webProviderCancel": result = ["cleanup": "not_created"]
        default: throw WebModelServer.Failure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    private func patchReply(name: String, patch: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [["name": name, "input": patch]]]), as: UTF8.self)
    }
}

import Foundation
import XCTest
@testable import Computa

/// Real bundled engine, HTTP client, compactor, terminal and patch executor.
/// Only model replies are synthetic. Never contacts a signed-in website.
@MainActor
final class WebsiteContextBudgetEngineTests: XCTestCase {
    func testBudgetCompactsWithinTurnThenContinuesCommandsAndFileEditingWithoutReplay() async throws {
        _ = try ComputaRuntimeArtifact.resolve()
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ComputaByteBudget-" + UUID().uuidString)
        let project = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Short commands leave enough room for all exact call receipts at compaction.
        let script = """
        marker="READ_$1"
        echo "$marker" >> executed.txt
        echo "$marker"
        if [ "$1" -ge 16 ]; then
            /usr/bin/awk 'BEGIN { for (i=0; i<500; i++) print "bounded code observation" }'
        fi
        """
        try script.write(to: project.appendingPathComponent("read.sh"), atomically: true, encoding: .utf8)
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = choice.modelID
        config.codexHomePath = root.appendingPathComponent("Home").path
        config.workspacePath = project.path
        config.protocolTracePath = root.appendingPathComponent("wire.jsonl").path
        let runtime = CodexAppServerRuntime(configuration: config)
        let provider = BudgetEngineTransport()
        var terminal = false, final = "", errors: [String] = [], completedCompactions = 0
        let observer = Task {
            for await event in runtime.events() {
                switch event {
                case .taskStatusChanged(_, let status):
                    if [.completed, .failed, .waiting].contains(status) { terminal = true }
                case .timelineEntryAppended(_, let entry):
                    if entry.kind == .assistant, entry.assistantPhase == "final_answer" { final = entry.body }
                    if entry.kind == .system, entry.title == "Agent error" { errors.append(entry.body) }
                case .contextCompactionChanged(_, let state):
                    if state == .completed { completedCompactions += 1 }
                    if case .failed(let message) = state { errors.append(message) }
                default: break
                }
            }
        }
        let task = UUID().uuidString
        do {
            await runtime.configureEmbeddedWebModelTransport(WebsiteInferenceFixtureTransport(provider, defaultChatChoice: choice))
            try await runtime.configureWorkspace(path: project.path, forTaskID: task)
            try await runtime.submit(prompt: "Inspect the fixture code, keep track of completed reads, then create the requested review file and report the result.", toTaskID: task, modelID: choice.modelID)
            let deadline = ContinuousClock.now + .seconds(90)
            while !terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            let receipt = await provider.receipt()
            XCTAssertTrue(terminal, "Native turn timed out: \(root.path)")
            XCTAssertEqual(errors, [], "\(root.path)")
            XCTAssertEqual(final, "BYTE_BUDGET_REVIEW_COMPLETE")
            XCTAssertEqual(completedCompactions, 1)
            XCTAssertEqual(receipt.summaries, 1)
            XCTAssertTrue(receipt.receiptsPreserved)
            XCTAssertTrue(receipt.patchVerified)
            XCTAssertGreaterThanOrEqual(receipt.commands, WebModelServer.maximumTurnInferences)
            XCTAssertEqual(receipt.sends, receipt.commands + 3, "Commands, summary, patch and final only")
            XCTAssertEqual(receipt.starts, receipt.sends)
            XCTAssertEqual(receipt.finishes, receipt.sends)
            XCTAssertTrue(receipt.promptSizes.allSatisfy { $0 <= WebModelResponseCodec.maximumPromptBytes })
            let executed = try String(contentsOf: project.appendingPathComponent("executed.txt"), encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(executed, (0..<receipt.commands).map { Substring("READ_\($0)") }, "Compaction must never rerun an executed command")
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("review.txt"), encoding: .utf8), "Verified after compaction\n")
            let shutdown = await runtime.shutdown()
            XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
            observer.cancel()
            if errors.isEmpty, final == "BYTE_BUDGET_REVIEW_COMPLETE" { try FileManager.default.removeItem(at: root) }
        } catch {
            _ = await runtime.shutdown(); observer.cancel()
            XCTFail("Native byte budget fixture retained at \(root.path): \(error)")
            throw error
        }
    }
}

private actor BudgetEngineTransport: WebModelTransport {
    struct Receipt: Sendable {
        var commands = 0, summaries = 0, sends = 0, starts = 0, finishes = 0
        var receiptsPreserved = false, patchVerified = false
        var promptSizes: [Int] = []
    }
    private var result = Receipt(), reply = "", token = ""
    private var patchIssued = false
    func receipt() -> Receipt { result }

    func request(operation: String, params: Data) throws -> Data {
        var response: [String: Any]
        switch operation {
        case "webProviderStart":
            result.starts += 1; token = UUID().uuidString
            response = ["state": "ready", "sessionToken": token]
        case "webProviderSend":
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
            let prompt = try XCTUnwrap(values["prompt"])
            let data = try WebsiteRequestFixture.json(in: prompt)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let request = try WebModelResponseCodec.prepareRequest(data)
            let input = try XCTUnwrap(object["input"] as? [[String: Any]])
            result.sends += 1; result.promptSizes.append(prompt.utf8.count)
            if request.offeredToolNames.isEmpty {
                XCTAssertTrue(prompt.contains("INTERNAL CONTEXT MAINTENANCE"))
                result.summaries += 1
                reply = #"{"type":"message","text":"The code reads completed. Their original tool receipts are retained. Create review.txt with Verified after compaction, then report completion. Never repeat the executed reads."}"#
            } else if result.summaries == 0 {
                guard result.commands < 32 else { throw WebModelServer.Failure.turnLimit }
                let name = try XCTUnwrap(request.offeredToolNames.first { $0 == "exec_command" || $0.hasSuffix(".exec_command") })
                let args = ["cmd": "sh read.sh \(result.commands)"]
                reply = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [["name": name, "arguments": args]]]), as: UTF8.self)
                result.commands += 1
            } else if !patchIssued {
                let calls = input.filter { $0["type"] as? String == "function_call" }
                let outputs = input.filter { $0["type"] as? String == "function_call_output" }
                let callCount = calls.count, outputCount = outputs.count
                result.receiptsPreserved = callCount == result.commands && outputCount == result.commands
                for index in 0..<result.commands {
                    let marker = "READ_\(index)"
                    let output = try XCTUnwrap(outputs.first { ($0["output"] as? String)?.contains(marker) == true })
                    let callID = try XCTUnwrap(output["call_id"] as? String)
                    XCTAssertEqual(calls.filter { $0["call_id"] as? String == callID }.count, 1)
                    XCTAssertTrue((output["output"] as? String)?.contains("Process exited with code 0") == true)
                }
                let name = try XCTUnwrap(request.offeredToolNames.first { $0 == "apply_patch" || $0.hasSuffix(".apply_patch") })
                let patch = "*** Begin Patch\n*** Add File: review.txt\n+Verified after compaction\n*** End Patch"
                reply = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [["name": name, "input": patch]]]), as: UTF8.self)
                patchIssued = true
            } else {
                let outputs = input.filter { $0["type"] as? String == "custom_tool_call_output" }
                result.patchVerified = outputs.contains { ($0["output"] as? String)?.contains("Success. Updated the following files") == true }
                reply = #"{"type":"message","text":"BYTE_BUDGET_REVIEW_COMPLETE"}"#
            }
            response = ["state": "running"]
        case "webProviderPoll":
            response = ["state": "complete", "text": reply, "completionEvidence": ["codeStructure": [
                "selectedExtraction": "raw_code", "extractionReason": "accepted_literal_code"]]]
        case "webProviderFinish", "webProviderCancel":
            result.finishes += 1; response = ["cleanup": "not_created"]
        default: throw WebModelServer.Failure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(response))
    }
}

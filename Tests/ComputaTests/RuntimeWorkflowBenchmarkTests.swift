import Foundation
import XCTest
@testable import Computa

/// Integration benchmark of production runtime composition. Website judgment
/// remains deliberately scripted; actual files, tools, Git and sockets do not.
@MainActor
final class RuntimeWorkflowBenchmarkTests: XCTestCase {
    func testEveryWebsiteProviderEditsBuildsCommitsPushesAndServesLocalhost() async throws {
        try requireEngine()
        for model in [LocalModelCatalog.chatGPTBrowserModelID, LocalModelCatalog.geminiBrowserModelID,
                      LocalModelCatalog.claudeBrowserModelID] {
            try await qualify(model: model, scenario: .workflow)
        }
    }

    func testDeclinedTerminalApprovalNeverWritesTheRequestedSideEffect() async throws {
        try requireEngine()
        try await qualify(model: LocalModelCatalog.chatGPTBrowserModelID, scenario: .deniedWrite, approve: false)
    }

    func testInterruptedTurnAndShutdownReapAnOwnedLocalServer() async throws {
        try requireEngine()
        try await qualify(model: LocalModelCatalog.chatGPTBrowserModelID, scenario: .interruptedServer)
    }

    private func requireEngine() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_WORKFLOW_ENGINE_TEST"] == "1",
            "Set COMPUTA_WORKFLOW_ENGINE_TEST=1 to run the bundled editing, terminal, Git and localhost benchmark.")
        // Explicitly enabled qualification fails closed if the pinned artifact
        // is missing or mismatched, rather than reporting a false passing skip.
        _ = try ComputaRuntimeArtifact.resolve()
    }

    private func qualify(model: String, scenario: WorkflowBenchmarkTransport.Scenario, approve: Bool = true) async throws {
        let failuresBefore = testRun?.failureCount ?? 0
        let fixture = try WorkflowBenchmarkFixture()
        let traceURL = fixture.root.appendingPathComponent("app-server-wire.jsonl")
        let taskID = UUID().uuidString
        let transport = WorkflowBenchmarkTransport(fixture: fixture, scenario: scenario)
        var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
        configuration.model = model
        configuration.codexHomePath = fixture.home.path
        configuration.workspacePath = fixture.project.path
        configuration.protocolTracePath = traceURL.path
        let runtime = CodexAppServerRuntime(configuration: configuration)
        let audit = WorkflowEventAudit(taskID: taskID)
        let observer = Task {
            for await event in runtime.events() {
                audit.receive(event)
                if case .approvalRequested(let request) = event, request.taskID == taskID {
                    do { try await runtime.resolveApproval(requestID: request.id, approved: approve) }
                    catch { audit.errors.append("Approval fixture failed: " + error.localizedDescription) }
                }
            }
        }
        let began = ContinuousClock.now
        var failure: Error?
        var receiptSummary: String?
        var stopReapLatency: Duration?
        do {
            // Match AppState's production composition before thread/start.
            // The real pinned parser must accept native and built-in tools in
            // one payload even when this workflow only dispatches file/terminal tools.
            await runtime.configureEmbeddedBrowserTools(
                EmbeddedBrowserToolController(transport: InertRuntimeBrowser()))
            await runtime.configureEmbeddedWebModelTransport(transport)
            try await runtime.configureWorkspace(path: fixture.project.path, forTaskID: taskID)
            try await runtime.submit(prompt: "Complete this disposable coding workflow and verify every result.",
                toTaskID: taskID, modelID: model)
            if scenario == .interruptedServer {
                try await wait(label: "owned server readiness", seconds: 45) {
                    let receipt = await transport.receipt()
                    return receipt.readyToInterrupt || receipt.failure != nil || audit.terminal
                }
                let ready = await transport.receipt()
                try WorkflowBenchmarkFailure.require(ready.failure == nil && ready.readyToInterrupt,
                    "The server never reached the interrupt boundary: \(ready.failure ?? audit.errors.joined())")
                XCTAssertFalse(audit.terminal)
                try await runtime.interrupt(taskID: taskID)
            }
            try await wait(label: "native workflow completion", seconds: 90) { audit.terminal }
            let receipt = await transport.receipt()
            try WorkflowBenchmarkFailure.require(receipt.failure == nil,
                "Scripted inference oracle rejected the real result: \(receipt.failure ?? "unknown")")
            try WorkflowBenchmarkFailure.require(audit.errors.isEmpty, "Native runtime errors: \(audit.errors.joined(separator: "; "))")
            XCTAssertEqual(receipt.starts, receipt.sends)
            XCTAssertEqual(Set(receipt.createdTokens).count, receipt.starts)
            XCTAssertEqual(receipt.closedTokens, receipt.createdTokens,
                "Every inference must close its exact website lease before the next tool continuation")
            XCTAssertEqual(receipt.requestModels, Array(repeating: model, count: receipt.sends))
            switch scenario {
            case .workflow:
                XCTAssertEqual(audit.status, .completed)
                XCTAssertEqual(audit.finalTexts.last, "WORKFLOW_BENCHMARK_OK")
                XCTAssertEqual(audit.finalTexts.filter { $0 == WorkflowBenchmarkTransport.toolProgress }.count, 12,
                    "Each tool envelope's commentary must survive the real App Server without ending the turn")
                XCTAssertEqual(receipt.sends, 13)
                XCTAssertEqual(receipt.matchedOutputs, 12)
                XCTAssertEqual(receipt.finishes, 13)
                XCTAssertEqual(receipt.cancels, 0)
                _ = try fixture.verifyCommittedOutcome()
                try fixture.verifyServerClosed()
                let patch = try XCTUnwrap(audit.files.last { $0.toolEvent?.status == .succeeded })
                XCTAssertEqual(Set(patch.fileChanges?.map(\.kind) ?? []), Set(["add", "update", "delete"]))
                let diff = try XCTUnwrap(audit.diffs.last)
                XCTAssertEqual(patch.turnID, diff.id)
                XCTAssertTrue(diff.diff.contains("src/math_utils.py"))
                XCTAssertTrue(diff.diff.contains("README.md"))
                XCTAssertTrue(diff.diff.contains("obsolete.txt"))
                XCTAssertFalse(diff.diff.contains("user-note.txt"))
                XCTAssertTrue(audit.commands.contains { $0.toolEvent?.status == .failed && $0.toolEvent?.output?.contains("Exit code: 23") == true })
                XCTAssertTrue(audit.commands.contains { $0.toolEvent?.status == .succeeded && $0.toolEvent?.output?.contains("INTERACTIVE_RESULT=composable") == true })
            case .deniedWrite:
                XCTAssertEqual(audit.status, .completed)
                XCTAssertEqual(audit.finalTexts.last, "DENIAL_BENCHMARK_OK")
                XCTAssertEqual(audit.approvals, 1)
                XCTAssertEqual(receipt.sends, 2)
                XCTAssertEqual(receipt.matchedOutputs, 1)
                XCTAssertEqual(receipt.finishes, 2)
                XCTAssertEqual(receipt.cancels, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("denied-side-effect.txt").path))
            case .interruptedServer:
                XCTAssertEqual(audit.status, .waiting)
                XCTAssertTrue(audit.finalTexts.isEmpty)
                XCTAssertEqual(receipt.sends, 2)
                XCTAssertEqual(receipt.matchedOutputs, 1)
                XCTAssertEqual(receipt.cancels, 1)
                XCTAssertEqual(receipt.finishes, 1)
                XCTAssertEqual(audit.approvals, 1)
                // Session termination precedes the engine's asynchronous PTY
                // reap. Only observed ESRCH plus ECONNREFUSED within this
                // finite window passes, before shutdown or fixture cleanup.
                stopReapLatency = try await fixture.waitForServerClosed()
            }
            let shutdown = await runtime.shutdown()
            try WorkflowBenchmarkFailure.require(shutdown.succeeded,
                "Runtime cleanup remained unconfirmed: \(shutdown.issues.joined(separator: "; "))")
            observer.cancel()
            if scenario == .interruptedServer { try fixture.verifyServerClosed() }
            let trace = try AppServerWireTrace.load(traceURL)
            XCTAssertEqual(trace.parseFailures, [])
            XCTAssertEqual(trace.messages.filter { $0.method == "turn/start" && $0.direction == .clientToServer }.count, 1)
            XCTAssertEqual(trace.messages.filter { $0.method == "thread/start" && $0.direction == .clientToServer }.count, 1)
            let threadStart = try XCTUnwrap(trace.messages.first {
                $0.method == "thread/start" && $0.direction == .clientToServer
            })
            let threadParameters = try XCTUnwrap(threadStart.object["params"] as? [String: Any])
            let dynamicSpecs = try XCTUnwrap(threadParameters["dynamicTools"] as? [[String: Any]])
            try CanonicalDynamicToolTestContract.validate(dynamicSpecs)
            let offeredNames = Set(dynamicSpecs.compactMap { $0["name"] as? String })
            XCTAssertEqual(offeredNames.intersection(EmbeddedBrowserTools.names), EmbeddedBrowserTools.names)
            XCTAssertTrue(offeredNames.contains(ComputerOutcomeToolContract.name))
            XCTAssertTrue(offeredNames.contains("computer_v2_apps"))
            let acceptedThread = try XCTUnwrap(trace.messages.first {
                $0.direction == .serverToClient && $0.method == nil && $0.identifier == threadStart.identifier
            })
            XCTAssertNil(acceptedThread.object["error"], "The real pinned App Server rejected combined dynamic tools")
            XCTAssertNotNil((acceptedThread.object["result"] as? [String: Any])?["thread"])
            if scenario == .interruptedServer {
                try verifyInterruptedServer(trace: trace, receipt: receipt, audit: audit, fixture: fixture)
            } else {
                XCTAssertTrue(trace.messages.contains { $0.method == "item/completed" &&
                    (($0.object["params"] as? [String: Any])?["item"] as? [String: Any])?["type"] as? String == "commandExecution" })
            }
            let duration = began.duration(to: .now)
            receiptSummary = "workflowBenchmark model=\(model) scenario=\(scenario) duration=\(duration) actualInferences=\(receipt.sends) matchedToolOutputs=\(receipt.matchedOutputs) approvals=\(audit.approvals)"
            if let stopReapLatency {
                receiptSummary? += " stopReapLatency=\(stopReapLatency) processAbsent=true portRefused=true observedBeforeShutdown=true"
            }
        } catch {
            failure = error
            if scenario == .interruptedServer {
                // Retain only structural ownership/cancellation evidence before
                // the always-required emergency cleanup removes its fixture.
                if let diagnostic = try? fixture.serverDiagnostic() {
                    print("workflowStopFailureObservation " + diagnostic)
                }
                let receipt = await transport.receipt()
                if let diagnostic = try? interruptedServerDiagnostic(traceURL: traceURL, receipt: receipt, taskID: taskID) {
                    print("workflowStopFailureProtocol " + diagnostic)
                }
            }
        }
        // Never leave fixture servers or user-visible benchmark repositories
        // behind, even when an assertion, engine startup or cancellation fails.
        let finalShutdown = await runtime.shutdown()
        observer.cancel()
        do { try await fixture.cleanup() }
        catch { if failure == nil { failure = error } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path), "Owned fixture cleanup must complete")
        XCTAssertTrue(finalShutdown.succeeded, finalShutdown.issues.joined(separator: "; "))
        if let failure { throw failure }
        try WorkflowBenchmarkFailure.require((testRun?.failureCount ?? 0) == failuresBefore,
            "One or more native workflow assertions failed")
        if let receiptSummary { print(receiptSummary + " fixtureRemoved=true outcome=verified") }
    }

    private func interruptedServerDiagnostic(traceURL: URL,
        receipt: WorkflowBenchmarkTransport.Receipt, taskID: String) throws -> String {
        let trace = try AppServerWireTrace.load(traceURL)
        let starts = trace.messages.filter { $0.direction == .serverToClient && $0.method == "turn/started" }
        let startParams = starts.first?.object["params"] as? [String: Any]
        let threadID = startParams?["threadId"] as? String
        let turnID = (startParams?["turn"] as? [String: Any])?["id"] as? String
        let methods: Set<String> = ["turn/interrupt", "thread/backgroundTerminals/list", "thread/backgroundTerminals/terminate"]
        let requests = trace.messages.filter {
            $0.direction == .clientToServer && methods.contains($0.method ?? "")
                && threadID != nil && ($0.object["params"] as? [String: Any])?["threadId"] as? String == threadID
        }
        let operations: [[String: Any]] = requests.prefix(16).map { request in
            let params = request.object["params"] as? [String: Any] ?? [:]
            let responses = trace.messages.filter { $0.direction == .serverToClient && $0.method == nil && $0.identifier == request.identifier }
            var value: [String: Any] = ["method": request.method ?? "", "sequence": request.sequence,
                "requestID": request.identifier ?? "", "responseCount": responses.count]
            if let turnID = params["turnId"] as? String { value["turnID"] = turnID }
            if let processID = params["processId"] as? String { value["engineSession"] = processID }
            if let response = responses.first {
                value["responseSequence"] = response.sequence
                value["responseError"] = response.object["error"] != nil
                let result = response.object["result"] as? [String: Any] ?? [:]
                if let terminated = result["terminated"] as? Bool { value["terminated"] = terminated }
                if let sessions = result["data"] as? [[String: Any]] {
                    value["sessions"] = sessions.prefix(32).map { row in
                        ["engineSession": row["processId"] as? String ?? "", "itemID": row["itemId"] as? String ?? ""]
                    }
                }
            }
            return value
        }
        let completions = trace.messages.filter {
            guard $0.direction == .serverToClient, $0.method == "turn/completed",
                  let params = $0.object["params"] as? [String: Any], threadID != nil,
                  params["threadId"] as? String == threadID,
                  let turn = params["turn"] as? [String: Any], turnID != nil else { return false }
            return turn["id"] as? String == turnID
        }
        let value: [String: Any] = ["schemaVersion": 1, "taskID": taskID,
            "threadID": threadID ?? "", "turnID": turnID ?? "",
            "callID": receipt.interruptedServerCall?.callID ?? "",
            "engineSession": receipt.interruptedServerSession.map(String.init) ?? "",
            "parseFailureCount": trace.parseFailures.count, "nativeStartCount": starts.count,
            "nativeCompletionCount": completions.count,
            "nativeCompletionStatuses": completions.compactMap {
                (($0.object["params"] as? [String: Any])?["turn"] as? [String: Any])?["status"] as? String
            }, "operations": operations]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func verifyInterruptedServer(trace: AppServerWireTrace,
        receipt: WorkflowBenchmarkTransport.Receipt, audit: WorkflowEventAudit,
        fixture: WorkflowBenchmarkFixture) throws {
        let observed = try XCTUnwrap(receipt.interruptedServerCall)
        let session = try XCTUnwrap(receipt.interruptedServerSession)
        XCTAssertTrue(observed.name == "exec_command" || observed.name.hasSuffix(".exec_command"))
        let script = fixture.project.appendingPathComponent("server.py").path
        let expectedCommand = "/usr/bin/python3 '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        XCTAssertEqual(observed.command, expectedCommand)
        XCTAssertEqual(observed.workdir, fixture.project.path)
        XCTAssertTrue(observed.output.contains("SERVER_READY"))
        XCTAssertTrue(observed.output.contains("Process running with session ID \(session)"))
        XCTAssertFalse(observed.output.contains("Process exited with code"))

        let turnStarts = trace.messages.filter { $0.direction == .serverToClient && $0.method == "turn/started" }
        XCTAssertEqual(turnStarts.count, 1)
        let start = try XCTUnwrap(turnStarts.first)
        let startParams = try XCTUnwrap(start.object["params"] as? [String: Any])
        let threadID = try XCTUnwrap(startParams["threadId"] as? String)
        let turnID = try XCTUnwrap((startParams["turn"] as? [String: Any])?["id"] as? String)
        let commandStarts = trace.messages.filter { message in
            guard message.direction == .serverToClient, message.method == "item/started",
                  let params = message.object["params"] as? [String: Any],
                  params["threadId"] as? String == threadID, params["turnId"] as? String == turnID,
                  let item = params["item"] as? [String: Any] else { return false }
            return item["type"] as? String == "commandExecution" && item["id"] as? String == observed.callID
        }
        XCTAssertEqual(commandStarts.count, 1)
        let commandStart = try XCTUnwrap(commandStarts.first)
        let item = try XCTUnwrap((commandStart.object["params"] as? [String: Any])?["item"] as? [String: Any])
        XCTAssertEqual(item["cwd"] as? String, fixture.project.path)
        // The pinned engine emits the approval-stage item before launch with
        // no processId, then suppresses the duplicate canonical core start.
        // Its optional schema permits null/absence here. The real running
        // session is proved by the call-ID-matched continuation output above.
        XCTAssertTrue(item["processId"] == nil || item["processId"] is NSNull)
        XCTAssertEqual(item["status"] as? String, "inProgress")
        // Native presentation may include the shell wrapper and quoting; its
        // exact item ID correlates it to the validated model-facing arguments.
        XCTAssertTrue((item["command"] as? String)?.contains(script) == true)
        let approvals = trace.messages.filter { message in
            guard message.direction == .serverToClient,
                  message.method == "item/commandExecution/requestApproval",
                  let params = message.object["params"] as? [String: Any] else { return false }
            return params["threadId"] as? String == threadID && params["turnId"] as? String == turnID
                && params["itemId"] as? String == observed.callID
        }
        XCTAssertEqual(approvals.count, 1)
        let approval = try XCTUnwrap(approvals.first)
        XCTAssertLessThan(commandStart.sequence, approval.sequence)
        let approvalParams = try XCTUnwrap(approval.object["params"] as? [String: Any])
        XCTAssertEqual(approvalParams["cwd"] as? String, fixture.project.path)
        XCTAssertTrue((approvalParams["command"] as? String)?.contains(script) == true)
        let approvalID = try XCTUnwrap(approval.identifier)
        let decisions = trace.messages.filter { $0.direction == .clientToServer && $0.method == nil && $0.identifier == approvalID }
        XCTAssertEqual(decisions.count, 1)
        let decision = try XCTUnwrap(decisions.first)
        XCTAssertEqual((decision.object["result"] as? [String: Any])?["decision"] as? String, "accept")
        XCTAssertLessThan(approval.sequence, decision.sequence)
        let presentations = audit.commands.filter { $0.id == observed.callID }
        XCTAssertTrue(presentations.contains { $0.toolEvent?.status == .running })
        let retired = try XCTUnwrap(presentations.last)
        XCTAssertEqual(retired.toolEvent?.status, .failed)
        XCTAssertTrue(retired.toolEvent?.output?.contains("final exit status unconfirmed") == true)
        XCTAssertFalse(presentations.contains { $0.toolEvent?.status == .succeeded })
        XCTAssertFalse(presentations.contains { $0.toolEvent?.output?.contains("Exit code:") == true })

        let interrupts = trace.messages.filter { $0.direction == .clientToServer && $0.method == "turn/interrupt" }
        XCTAssertEqual(interrupts.count, 1)
        let interrupt = try XCTUnwrap(interrupts.first)
        let interruptParams = try XCTUnwrap(interrupt.object["params"] as? [String: Any])
        XCTAssertEqual(interruptParams["threadId"] as? String, threadID)
        XCTAssertEqual(interruptParams["turnId"] as? String, turnID)
        XCTAssertLessThan(commandStart.sequence, interrupt.sequence)
        XCTAssertLessThan(decision.sequence, interrupt.sequence)
        let interruptID = try XCTUnwrap(interrupt.identifier)
        let responses = trace.messages.filter { $0.direction == .serverToClient && $0.method == nil && $0.identifier == interruptID }
        XCTAssertEqual(responses.count, 1)
        let response = try XCTUnwrap(responses.first)
        XCTAssertNil(response.object["error"])
        XCTAssertNotNil(response.object["result"])
        let completions = trace.messages.filter { message in
            guard message.direction == .serverToClient, message.method == "turn/completed",
                  let params = message.object["params"] as? [String: Any],
                  params["threadId"] as? String == threadID,
                  let turn = params["turn"] as? [String: Any] else { return false }
            return turn["id"] as? String == turnID
        }
        XCTAssertEqual(completions.count, 1)
        let completion = try XCTUnwrap(completions.first)
        XCTAssertEqual(((completion.object["params"] as? [String: Any])?["turn"] as? [String: Any])?["status"] as? String, "interrupted")
        XCTAssertLessThan(interrupt.sequence, completion.sequence)
    }

    private func wait(label: String, seconds: Int, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorkflowBenchmarkFailure("Bounded deadline: \(label)")
    }
}

@MainActor
private final class WorkflowEventAudit {
    let taskID: String
    var began = false
    var terminal = false
    var status: TaskStatus?
    var approvals = 0
    var files = [TimelineEntry]()
    var commands = [TimelineEntry]()
    var diffs = [AgentTurnDiff]()
    var finalTexts = [String]()
    var errors = [String]()
    init(taskID: String) { self.taskID = taskID }
    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case .taskStatusChanged(let id, let status) where id == taskID:
            self.status = status
            if status == .running { began = true }
            if began && (status == .completed || status == .waiting) { terminal = true }
        case .timelineEntryAppended(let id, let entry) where id == taskID:
            if entry.toolEvent?.name == "fileChange" { files.append(entry) }
            if entry.toolEvent?.name == "commandExecution" { commands.append(entry) }
            if entry.kind == .assistant { finalTexts.append(entry.body) }
            if entry.kind == .system, entry.title == "Agent error" { errors.append(entry.body) }
        case .turnDiffUpdated(let id, let turnID, let diff) where id == taskID:
            diffs.append(.init(id: turnID, diff: diff))
        case .approvalRequested(let request) where request.taskID == taskID: approvals += 1
        case .connectionChanged(.failed(let message)): errors.append(message); terminal = true
        default: break
        }
    }
}

import Foundation
import Network
import XCTest
@testable import Computa

#if DEBUG
/// Opt-in, model-free integration. Only the bundled native engine executes
/// tools; provider inference and credentials are isolated loopback fixtures.
@MainActor
final class APIProviderHarnessLiveTests: XCTestCase {
    func testBundledEngineExecutesPatchAndCommandThenColdResumesSealedReasoning() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_API_ENGINE_TEST"] == "1",
            "Set TEST_RUNNER_COMPUTA_API_ENGINE_TEST=1 for the isolated bundled API harness qualification.")
        let artifact: ComputaRuntimeArtifact
        do { artifact = try ComputaRuntimeArtifact.resolve() }
        catch ComputaRuntimeArtifact.ValidationError.resourcesUnavailable {
            throw XCTSkip("The bundled AgentRuntime resources are absent in this source-only checkout.")
        } catch ComputaRuntimeArtifact.ValidationError.unavailableFile {
            throw XCTSkip("The bundled AgentRuntime artifact is absent in this source-only checkout.")
        }
        XCTAssertEqual(artifact.manifest.sourceCommit, "4607249e430dac1c961df4dc615beae88e33cec8")
        XCTAssertEqual(artifact.manifest.runtimeVersion, "mactopus-7")
        XCTAssertEqual(artifact.executableURL.lastPathComponent, "codex-app-server")
        XCTAssertFalse(artifact.executableURL.path.contains("ChatGPT.app"))

        let failuresBefore = testRun?.failureCount ?? 0
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("ComputaAPIHarness-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("PrivateCodexHome", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let finalMarker = "API_HARNESS_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let privateReasoning = (1...3).map { "API_PRIVATE_THINKING_\($0)_" + UUID().uuidString }
        let fakeKey = "SYNTHETIC_ONLY_API_KEY_" + UUID().uuidString
        try Data("old\n".utf8).write(to: project.appendingPathComponent("fixture.txt"))
        try Data("untouched\n".utf8).write(to: project.appendingPathComponent("unrelated.txt"))
        try Data((finalMarker + "\n").utf8).write(to: project.appendingPathComponent("receipt.txt"))
        let capsuleKey = Data(repeating: 0x5A, count: 32)
        let credentials = APIHarnessCredentials(providerID: "fixture-harness", value: fakeKey)
        let inference = APIHarnessInference(projectPath: project.path, marker: finalMarker,
                                            privateReasoning: privateReasoning, expectedKey: fakeKey)
        let upstream = try APIHarnessHTTPFixture { await inference.respond($0) }
        var first: CodexAppServerRuntime?
        var reopened: CodexAppServerRuntime?
        var firstPump: Task<Void, Never>?
        var reopenedPump: Task<Void, Never>?
        do {
            let endpoint = try await upstream.start()
            let model = APIModelDefinition(id: "fixture-native-harness", name: "Synthetic Native Harness",
                                           contextWindow: 65_536)
            let provider = APIProviderDefinition(id: "fixture-harness", name: "Synthetic Loopback",
                baseURL: endpoint, wireAPI: .chatCompletions, models: [model])
            let modelID = APIProviderCatalog.appModelID(providerID: provider.id, modelID: model.id)
            let firstTrace = root.appendingPathComponent("first-native-protocol.jsonl")
            let reopenedTrace = root.appendingPathComponent("resumed-native-protocol.jsonl")
            let firstServer = APIModelServer(credentials: credentials,
                                            capsules: try APIReasoningCapsules(key: capsuleKey),
                                            toolNamingDirectory: home.appendingPathComponent("APIToolNaming-v1", isDirectory: true))
            var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
            configuration.executable = .bundled
            configuration.model = modelID
            configuration.codexHomePath = home.path
            configuration.workspacePath = project.path
            configuration.protocolTracePath = firstTrace.path
            configuration.apiModelServerForTesting = firstServer
            let runtime = CodexAppServerRuntime(configuration: configuration, visualGrounder: APIHarnessNoVisualGrounder())
            first = runtime
            let taskID = UUID().uuidString.lowercased()
            let audit = APIHarnessEventAudit(taskID: taskID)
            firstPump = Task { for await event in runtime.events() { audit.receive(event) } }
            try await runtime.configureAPIProviders([provider])
            let initialTasks = try await runtime.loadTasks()
            XCTAssertTrue(initialTasks.isEmpty)
            try await runtime.configureWorkspace(path: project.path, forTaskID: taskID)
            try await runtime.submit(prompt: "In this isolated project, change fixture.txt from old to fixed, "
                + "verify the file and read receipt.txt with a command. Leave unrelated.txt unchanged. "
                + "Return only the observed receipt.", toTaskID: taskID, modelID: modelID)
            try await waitForTerminal(audit)
            XCTAssertEqual(audit.status, .completed)
            XCTAssertEqual(audit.errors, [])
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertEqual(audit.finalTexts.last, finalMarker)
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("fixture.txt"), encoding: .utf8), "fixed\n")
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("unrelated.txt"), encoding: .utf8), "untouched\n")
            let patch = try XCTUnwrap(audit.fileEntries.last { $0.toolEvent?.status == .succeeded })
            XCTAssertEqual(patch.fileChanges?.count, 1)
            let change = try XCTUnwrap(patch.fileChanges?.first)
            XCTAssertEqual(change.kind, "update")
            XCTAssertEqual(URL(fileURLWithPath: change.path).resolvingSymlinksInPath().path,
                           project.appendingPathComponent("fixture.txt").resolvingSymlinksInPath().path)
            XCTAssertTrue(change.diff.contains("-old"))
            XCTAssertTrue(change.diff.contains("+fixed"))
            let diff = try XCTUnwrap(audit.diffs.last)
            XCTAssertEqual(patch.turnID, diff.id)
            XCTAssertTrue(diff.diff.contains("fixture.txt"))
            let command = try XCTUnwrap(audit.commands.last { $0.toolEvent?.status == .succeeded })
            XCTAssertTrue(command.toolEvent?.output?.contains(finalMarker) == true)
            XCTAssertTrue(command.toolEvent?.output?.contains("Exit code: 0") == true)
            XCTAssertFalse(command.toolEvent?.input.contains(finalMarker) == true,
                           "The command must read the fixture receipt, not print an embedded marker.")

            let firstReceipt = await inference.receipt()
            XCTAssertEqual(firstReceipt.requestCount, 3)
            XCTAssertTrue(firstReceipt.requestsWereStreaming)
            XCTAssertTrue(firstReceipt.patchOffered)
            XCTAssertTrue(firstReceipt.commandOffered)
            XCTAssertTrue(firstReceipt.patchOutputMatched)
            XCTAssertTrue(firstReceipt.commandOutputMatched)
            XCTAssertTrue(firstReceipt.reasoningRoundtripped)
            XCTAssertTrue(firstReceipt.semanticNamingStable,
                          "Actual Core thread/start must opt the fresh chat into semantic naming before the provider receives its tools")
            XCTAssertEqual(firstReceipt.failures, [])
            let firstShutdown = await runtime.shutdown()
            XCTAssertTrue(firstShutdown.succeeded, firstShutdown.issues.joined(separator: "; "))
            guard firstShutdown.succeeded else { throw APIHarnessFailure("The first runtime cleanup was not confirmed.") }
            firstPump?.cancel()
            let firstWire = try AppServerWireTrace.load(firstTrace)
            XCTAssertEqual(firstWire.parseFailures, [])
            let threadID = try threadStarted(in: firstWire)
            let namingPin = home.appendingPathComponent("APIToolNaming-v1", isDirectory: true)
                .appendingPathComponent(threadID.lowercased() + ".json")
            let pinBytes = try Data(contentsOf: namingPin)
            let pin = try XCTUnwrap(JSONSerialization.jsonObject(with: pinBytes) as? [String: Any])
            XCTAssertEqual(pin["threadID"] as? String, threadID.lowercased())
            XCTAssertEqual(pin["style"] as? String, APIModelResponseCodec.ToolNaming.semantic.rawValue)
            XCTAssertNotEqual(threadID, taskID)
            XCTAssertEqual(firstWire.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }.count, 1)
            assertNoPrivateState(in: firstWire, fakeKey: fakeKey, reasoning: privateReasoning)
            try assertNoPrivateState(in: [firstTrace, home], fakeKey: fakeKey, reasoning: privateReasoning)

            // A fresh Core, gateway actor and capsule object must use saved
            // native history. The same upstream endpoint and capsule key are
            // retained; no live authority or in-memory history is transferred.
            let secondServer = APIModelServer(credentials: credentials,
                                             capsules: try APIReasoningCapsules(key: capsuleKey),
                                             toolNamingDirectory: home.appendingPathComponent("APIToolNaming-v1", isDirectory: true))
            configuration.apiModelServerForTesting = secondServer
            configuration.protocolTracePath = reopenedTrace.path
            let resumed = CodexAppServerRuntime(configuration: configuration, visualGrounder: APIHarnessNoVisualGrounder())
            reopened = resumed
            try await resumed.configureAPIProviders([provider])
            let savedTasks = try await resumed.loadTasks()
            let saved = try XCTUnwrap(savedTasks.first)
            XCTAssertEqual(saved.id, threadID)
            XCTAssertEqual(saved.model, modelID)
            XCTAssertNotEqual(saved.id, taskID, "Reopening must use a new local task binding to the same native thread.")
            XCTAssertTrue(saved.turnDiffs.contains(diff))
            XCTAssertEqual(saved.entries.filter { $0.toolEvent?.name == "fileChange" && $0.toolEvent?.status == .succeeded }.count, 1)
            XCTAssertTrue(saved.entries.contains { $0.toolEvent?.name == "commandExecution"
                && $0.toolEvent?.status == .succeeded && $0.toolEvent?.output?.contains(finalMarker) == true })
            let resumedAudit = APIHarnessEventAudit(taskID: saved.id)
            reopenedPump = Task { for await event in resumed.events() { resumedAudit.receive(event) } }
            try await resumed.submit(prompt: "Read our saved result and return the same receipt without editing files or running commands.",
                                     toTaskID: saved.id, modelID: modelID)
            try await waitForTerminal(resumedAudit)
            XCTAssertEqual(resumedAudit.status, .completed)
            XCTAssertEqual(resumedAudit.errors, [])
            XCTAssertEqual(resumedAudit.finalTexts.last, finalMarker)
            XCTAssertEqual(resumedAudit.approvals, 0)
            XCTAssertTrue(resumedAudit.fileEntries.isEmpty)
            XCTAssertTrue(resumedAudit.commands.isEmpty)
            let finalReceipt = await inference.receipt()
            XCTAssertEqual(finalReceipt.requestCount, 4, "No inference, edit, or command may be replayed during cold resume.")
            XCTAssertTrue(finalReceipt.reasoningSurvivedColdResume)
            XCTAssertTrue(finalReceipt.originalToolResultsSurvivedColdResume)
            XCTAssertTrue(finalReceipt.semanticNamingStable)
            XCTAssertEqual(try Data(contentsOf: namingPin), pinBytes)
            XCTAssertEqual(finalReceipt.failures, [])
            XCTAssertEqual(credentials.counts().reads, 4)
            XCTAssertEqual(credentials.counts().mutations, 0)
            let resumedShutdown = await resumed.shutdown()
            XCTAssertTrue(resumedShutdown.succeeded, resumedShutdown.issues.joined(separator: "; "))
            reopenedPump?.cancel()
            let resumedWire = try AppServerWireTrace.load(reopenedTrace)
            XCTAssertEqual(resumedWire.parseFailures, [])
            XCTAssertFalse(resumedWire.messages.contains { $0.direction == .clientToServer && $0.method == "thread/start" })
            let resume = try XCTUnwrap(resumedWire.messages.first { $0.direction == .clientToServer && $0.method == "thread/resume" })
            XCTAssertEqual((resume.object["params"] as? [String: Any])?["threadId"] as? String, threadID)
            assertNoPrivateState(in: resumedWire, fakeKey: fakeKey, reasoning: privateReasoning)
            try assertNoPrivateState(in: [firstTrace, reopenedTrace, home], fakeKey: fakeKey, reasoning: privateReasoning)
            guard (testRun?.failureCount ?? 0) == failuresBefore else {
                throw APIHarnessFailure("One or more API harness qualification invariants failed.")
            }
            let proof = "bundledAPIHarness=true\nengineSource=\(artifact.manifest.sourceCommit)\n"
                + "engineVersion=\(artifact.manifest.runtimeVersion)\nproviderRequests=4\n"
                + "successfulPatches=1\nsuccessfulCommands=1\ncommandExit=0\n"
                + "coldResumeReasoningRoundtrip=true\nprivateStateAbsentFromNativeStorage=true\n"
            let attachment = XCTAttachment(string: proof)
            attachment.name = "Synthetic API bundled-engine qualification"
            attachment.lifetime = .keepAlways
            add(attachment)
            await upstream.stop()
            try FileManager.default.removeItem(at: root)
            print("syntheticAPIHarness outcome=passed requests=4 patchCalls=1 commandCalls=1 coldResume=true")
        } catch {
            if let reopened { _ = await reopened.shutdown() }
            if let first { _ = await first.shutdown() }
            firstPump?.cancel(); reopenedPump?.cancel()
            await upstream.stop()
            print("syntheticAPIHarnessFailureArtifacts=\(root.path)")
            throw error
        }
    }

    func testBundledEngineHighTrafficStopsAfterOneUpstreamRequestWithoutRunningTools() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_API_ENGINE_TEST"] == "1",
            "Set TEST_RUNNER_COMPUTA_API_ENGINE_TEST=1 for the isolated bundled API harness qualification.")
        let artifact: ComputaRuntimeArtifact
        do { artifact = try ComputaRuntimeArtifact.resolve() }
        catch ComputaRuntimeArtifact.ValidationError.resourcesUnavailable {
            throw XCTSkip("The bundled AgentRuntime resources are absent in this source-only checkout.")
        } catch ComputaRuntimeArtifact.ValidationError.unavailableFile {
            throw XCTSkip("The bundled AgentRuntime artifact is absent in this source-only checkout.")
        }
        XCTAssertEqual(artifact.manifest.sourceCommit, "4607249e430dac1c961df4dc615beae88e33cec8")
        XCTAssertEqual(artifact.manifest.runtimeVersion, "mactopus-7")
        let failuresBefore = testRun?.failureCount ?? 0
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ComputaAPIRateLimit-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("PrivateCodexHome", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let target = project.appendingPathComponent("fixture.txt")
        try Data("unchanged\n".utf8).write(to: target)
        let fakeKey = "SYNTHETIC_ONLY_API_KEY_" + UUID().uuidString
        let rawRemoteMessage = "UNTRUSTED_RATE_LIMIT_TEXT_" + UUID().uuidString
        let credentials = APIHarnessCredentials(providerID: "fixture-rate-limit", value: fakeKey)
        let observations = APIHarnessRateLimitObservations()
        // The visible provider log established this message and HTTP 429.
        // The wrapper is a controlled fixture shape, not a claimed vendor code.
        let body = try JSONSerialization.data(withJSONObject: ["error": [
            "message": "We're experiencing high traffic right now! Please try again soon.",
            "detail": rawRemoteMessage,
        ]])
        let upstream = try APIHarnessHTTPFixture { request in
            await observations.record(request)
            return .init(status: "429 Too Many Requests", body: body, contentType: "application/json")
        }
        var ownedRuntime: CodexAppServerRuntime?
        var pump: Task<Void, Never>?
        do {
            let model = APIModelDefinition(id: "fixture-rate-limited-model", name: "Synthetic Rate Limit", contextWindow: 65_536)
            let provider = APIProviderDefinition(id: "fixture-rate-limit", name: "Synthetic Loopback",
                baseURL: try await upstream.start(), wireAPI: .chatCompletions, models: [model])
            let modelID = APIProviderCatalog.appModelID(providerID: provider.id, modelID: model.id)
            let traceURL = root.appendingPathComponent("native-protocol.jsonl")
            var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
            configuration.executable = .bundled
            configuration.model = modelID
            configuration.codexHomePath = home.path
            configuration.workspacePath = project.path
            configuration.protocolTracePath = traceURL.path
            configuration.apiModelServerForTesting = APIModelServer(credentials: credentials,
                capsules: try APIReasoningCapsules(key: Data(repeating: 0x6B, count: 32)))
            let runtime = CodexAppServerRuntime(configuration: configuration, visualGrounder: APIHarnessNoVisualGrounder())
            ownedRuntime = runtime
            let taskID = UUID().uuidString.lowercased()
            let audit = APIHarnessEventAudit(taskID: taskID)
            pump = Task { for await event in runtime.events() { audit.receive(event) } }
            try await runtime.configureAPIProviders([provider])
            let tasks = try await runtime.loadTasks()
            XCTAssertTrue(tasks.isEmpty)
            try await runtime.configureWorkspace(path: project.path, forTaskID: taskID)
            try await runtime.submit(prompt: "Change fixture.txt to changed using apply_patch, verify it with a command, then report the result.",
                                     toTaskID: taskID, modelID: modelID)
            try await waitForTerminal(audit)
            XCTAssertEqual(audit.status, .waiting)
            let errors = audit.errors.joined(separator: "\n")
            XCTAssertTrue(errors.contains("The API provider is busy because of high traffic. Try again shortly. No request was replayed."), errors)
            XCTAssertFalse(errors.contains("exceeded retry limit"), errors)
            XCTAssertFalse(errors.lowercased().contains("quota"), errors)
            XCTAssertFalse(errors.lowercased().contains("account rate limit"), errors)
            XCTAssertFalse(errors.contains(rawRemoteMessage), "Untrusted provider text must not become the native error.")
            XCTAssertTrue(audit.finalTexts.isEmpty)
            XCTAssertTrue(audit.commands.isEmpty)
            XCTAssertTrue(audit.fileEntries.isEmpty)
            XCTAssertTrue(audit.toolEvents.isEmpty)
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged\n")
            let receipt = await observations.receipt()
            XCTAssertEqual(receipt.requests, 1, "A failed provider request must never be replayed.")
            XCTAssertTrue(receipt.streaming)
            XCTAssertTrue(receipt.commandOffered, "The blocked turn must use the normal native tool-enabled harness.")
            XCTAssertTrue(receipt.patchOffered)
            XCTAssertEqual(credentials.counts().reads, 1)
            XCTAssertEqual(credentials.counts().mutations, 0)
            let shutdown = await runtime.shutdown()
            XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
            pump?.cancel()
            let trace = try AppServerWireTrace.load(traceURL)
            XCTAssertEqual(trace.parseFailures, [])
            XCTAssertEqual(trace.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }.count, 1)
            XCTAssertFalse(trace.messages.contains { $0.method == "item/tool/call" })
            let nativeWire = trace.messages.map { String(decoding: $0.wireData, as: UTF8.self) }.joined(separator: "\n")
            XCTAssertTrue(nativeWire.contains("rateLimitExceeded"), "The native engine must retain the semantic rate-limit category.")
            XCTAssertFalse(nativeWire.contains("responseTooManyFailedAttempts"))
            assertNoPrivateState(in: trace, fakeKey: fakeKey, reasoning: [rawRemoteMessage])
            try assertNoPrivateState(in: [traceURL, home], fakeKey: fakeKey, reasoning: [rawRemoteMessage])
            guard (testRun?.failureCount ?? 0) == failuresBefore else {
                throw APIHarnessFailure("The bundled rate-limit invariants failed.")
            }
            await upstream.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            if let ownedRuntime { _ = await ownedRuntime.shutdown() }
            pump?.cancel()
            await upstream.stop()
            print("syntheticAPIRateLimitFailureArtifacts=\(root.path)")
            throw error
        }
    }

    func testBundledEngineRejectsEntireBadBatchBeforeOneCorrectionAndExecutesOnlyAcceptedTools() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_API_ENGINE_TEST"] == "1",
            "Set TEST_RUNNER_COMPUTA_API_ENGINE_TEST=1 for the isolated bundled API harness qualification.")
        let artifact: ComputaRuntimeArtifact
        do { artifact = try ComputaRuntimeArtifact.resolve() }
        catch ComputaRuntimeArtifact.ValidationError.resourcesUnavailable {
            throw XCTSkip("The bundled AgentRuntime resources are absent in this source-only checkout.")
        } catch ComputaRuntimeArtifact.ValidationError.unavailableFile {
            throw XCTSkip("The bundled AgentRuntime artifact is absent in this source-only checkout.")
        }
        XCTAssertEqual(artifact.manifest.sourceCommit, "4607249e430dac1c961df4dc615beae88e33cec8")
        XCTAssertEqual(artifact.manifest.runtimeVersion, "mactopus-7")
        let failuresBefore = testRun?.failureCount ?? 0
        // Match the passing harness: descriptor-based stores reject the /var symlink alias.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("ComputaAPICorrection-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("PrivateCodexHome", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let accounting = home.appendingPathComponent("APIModelCorrectionUsage-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let marker = "API_CORRECTION_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fakeKey = "SYNTHETIC_ONLY_API_KEY_" + UUID().uuidString
        let rejectedThinking = "REJECTED_PRIVATE_THINKING_" + UUID().uuidString
        let credentials = APIHarnessCredentials(providerID: "fixture-correction", value: fakeKey)
        try Data("old\n".utf8).write(to: project.appendingPathComponent("fixture.txt"))
        try Data("untouched\n".utf8).write(to: project.appendingPathComponent("unrelated.txt"))
        try Data((marker + "\n").utf8).write(to: project.appendingPathComponent("receipt.txt"))
        let inference = APIHarnessCorrectionInference(project: project, accounting: accounting,
            marker: marker, expectedKey: fakeKey, rejectedThinking: rejectedThinking)
        let upstream = try APIHarnessHTTPFixture { await inference.respond($0) }
        var ownedRuntime: CodexAppServerRuntime?
        var pump: Task<Void, Never>?
        do {
            let model = APIModelDefinition(id: "fixture-correction-model", name: "Synthetic Correction", contextWindow: 65_536)
            let provider = APIProviderDefinition(id: "fixture-correction", name: "Synthetic Loopback",
                baseURL: try await upstream.start(), wireAPI: .chatCompletions, models: [model])
            let modelID = APIProviderCatalog.appModelID(providerID: provider.id, modelID: model.id)
            let traceURL = root.appendingPathComponent("native-protocol.jsonl")
            var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
            configuration.executable = .bundled
            configuration.model = modelID
            configuration.codexHomePath = home.path
            configuration.workspacePath = project.path
            configuration.protocolTracePath = traceURL.path
            configuration.apiModelServerForTesting = APIModelServer(credentials: credentials,
                capsules: try APIReasoningCapsules(key: Data(repeating: 0x6C, count: 32)),
                toolNamingDirectory: home.appendingPathComponent("APIToolNaming-v1", isDirectory: true),
                correctionAccountingDirectory: accounting)
            let runtime = CodexAppServerRuntime(configuration: configuration, visualGrounder: APIHarnessNoVisualGrounder())
            ownedRuntime = runtime
            let taskID = UUID().uuidString.lowercased()
            let audit = APIHarnessEventAudit(taskID: taskID)
            pump = Task { for await event in runtime.events() { audit.receive(event) } }
            try await runtime.configureAPIProviders([provider])
            let tasks = try await runtime.loadTasks()
            XCTAssertTrue(tasks.isEmpty)
            try await runtime.configureWorkspace(path: project.path, forTaskID: taskID)
            try await runtime.submit(prompt: "Change fixture.txt from old to fixed with apply_patch. Then run one command "
                + "to verify fixture.txt and unrelated.txt, append one line to execution-count.txt, and read receipt.txt. "
                + "Return only that observed receipt. Do not create rejected-batch.txt or change unrelated.txt.",
                toTaskID: taskID, modelID: modelID)
            try await waitForTerminal(audit)
            XCTAssertEqual(audit.status, .completed)
            XCTAssertEqual(audit.errors, [])
            XCTAssertEqual(audit.approvals, 0)
            XCTAssertEqual(audit.finalTexts, [marker])
            XCTAssertEqual(audit.fileEntries.filter { $0.toolEvent?.status == .succeeded }.count, 1)
            XCTAssertEqual(audit.commands.filter { $0.toolEvent?.status == .succeeded }.count, 1)
            let patch = try XCTUnwrap(audit.fileEntries.last { $0.toolEvent?.status == .succeeded })
            XCTAssertEqual(patch.fileChanges?.count, 1)
            let change = try XCTUnwrap(patch.fileChanges?.first)
            XCTAssertEqual(URL(fileURLWithPath: change.path).resolvingSymlinksInPath().path,
                           project.appendingPathComponent("fixture.txt").resolvingSymlinksInPath().path)
            XCTAssertTrue(change.diff.contains("-old"))
            XCTAssertTrue(change.diff.contains("+fixed"))
            let command = try XCTUnwrap(audit.commands.last { $0.toolEvent?.status == .succeeded })
            XCTAssertTrue(command.toolEvent?.output?.contains(marker) == true)
            XCTAssertTrue(command.toolEvent?.output?.contains("Exit code: 0") == true)
            XCTAssertFalse(command.toolEvent?.input.contains(marker) == true)
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("fixture.txt"), encoding: .utf8), "fixed\n")
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("unrelated.txt"), encoding: .utf8), "untouched\n")
            XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("execution-count.txt"), encoding: .utf8), "executed\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("rejected-batch.txt").path))
            let receipt = await inference.receipt()
            XCTAssertEqual(receipt.requests, 4, "Three native inferences plus exactly one private corrective inference.")
            XCTAssertTrue(receipt.rejectedBatchHadNoEffectsAtCorrection)
            XCTAssertTrue(receipt.firstUsageDurableBeforeCorrection)
            XCTAssertTrue(receipt.correctiveRequestPreservedOriginal)
            XCTAssertTrue(receipt.acceptedToolHistoryOnly)
            XCTAssertEqual(receipt.failures, [])
            XCTAssertEqual(credentials.counts().reads, 3, "The correction retains the already admitted credential; native rounds still read independently.")
            XCTAssertEqual(credentials.counts().mutations, 0)
            let shutdown = await runtime.shutdown()
            XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
            pump?.cancel()
            let trace = try AppServerWireTrace.load(traceURL)
            XCTAssertEqual(trace.parseFailures, [])
            XCTAssertEqual(trace.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }.count, 1)
            let threadID = try threadStarted(in: trace)
            let turnIDs = Set(trace.messages.compactMap { message -> String? in
                guard message.direction == .serverToClient, message.method == "thread/tokenUsage/updated",
                      let params = message.object["params"] as? [String: Any] else { return nil }
                return params["turnId"] as? String
            })
            XCTAssertEqual(turnIDs.count, 1)
            let turnID = try XCTUnwrap(turnIDs.first)
            let lastTotals = trace.messages.compactMap { message -> Int? in
                guard message.direction == .serverToClient, message.method == "thread/tokenUsage/updated",
                      let params = message.object["params"] as? [String: Any],
                      let usage = params["tokenUsage"] as? [String: Any], let last = usage["last"] as? [String: Any] else { return nil }
                return last["totalTokens"] as? Int
            }
            XCTAssertTrue(lastTotals.contains(36), "The accepted corrected response reports its own 23+13 tokens to the pinned engine.")
            XCTAssertFalse(lastTotals.contains(54), "Rejected18+accepted36 must never become context occupancy.")
            let journalFiles = try FileManager.default.contentsOfDirectory(at: accounting, includingPropertiesForKeys: nil)
            XCTAssertEqual(journalFiles.count, 3)
            let records = try journalFiles.map { try JSONDecoder().decode(APIModelCorrectionAccounting.Record.self, from: Data(contentsOf: $0)) }
            XCTAssertEqual(Set(records.map(\.correctionID)).count, 1)
            XCTAssertEqual(Set(records.map(\.phase)), Set(["first_received", "second_claimed", "finished"]))
            for record in records {
                XCTAssertEqual(record.taskID, taskID)
                XCTAssertEqual(record.threadID, threadID.lowercased())
                XCTAssertEqual(record.turnID, turnID.lowercased())
                XCTAssertEqual(record.firstUsage, APIModelCorrectionUsage(inputTokens: 11, outputTokens: 7,
                    totalTokens: 18, cachedInputTokens: 2, reasoningOutputTokens: 3))
            }
            let finished = try XCTUnwrap(records.first { $0.phase == "finished" })
            XCTAssertEqual(finished.outcome, .responseValidated)
            XCTAssertTrue(finished.secondRequestClaimed)
            XCTAssertFalse(finished.secondUsageUnknown)
            XCTAssertEqual(finished.secondUsage, APIModelCorrectionUsage(inputTokens: 23, outputTokens: 13,
                totalTokens: 36, cachedInputTokens: 4, reasoningOutputTokens: 5))
            for rejectedID in ["rejected-valid-patch", "rejected-invalid-command"] {
                XCTAssertFalse(trace.messages.contains { String(decoding: $0.wireData, as: UTF8.self).contains(rejectedID) },
                    "No item or delta from either call in the rejected batch may reach the native engine.")
            }
            assertNoPrivateState(in: trace, fakeKey: fakeKey, reasoning: [rejectedThinking])
            try assertNoPrivateState(in: [traceURL, home], fakeKey: fakeKey, reasoning: [rejectedThinking])
            guard (testRun?.failureCount ?? 0) == failuresBefore else {
                throw APIHarnessFailure("The bundled correction invariants failed.")
            }
            await upstream.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            if let ownedRuntime { _ = await ownedRuntime.shutdown() }
            pump?.cancel()
            await upstream.stop()
            print("syntheticAPICorrectionFailureArtifacts=\(root.path)")
            throw error
        }
    }

    private func waitForTerminal(_ audit: APIHarnessEventAudit) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !audit.terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard audit.terminal else { throw APIHarnessFailure("The bundled API harness did not settle within 60 seconds.") }
    }

    private func threadStarted(in trace: AppServerWireTrace) throws -> String {
        let start = try XCTUnwrap(trace.messages.first { $0.direction == .clientToServer && $0.method == "thread/start" })
        let reply = try XCTUnwrap(trace.messages.first { $0.direction == .serverToClient && $0.identifier == start.identifier
            && $0.object["result"] != nil })
        let result = try XCTUnwrap(reply.object["result"] as? [String: Any])
        let thread = try XCTUnwrap(result["thread"] as? [String: Any])
        return try XCTUnwrap(thread["id"] as? String)
    }

    private func assertNoPrivateState(in targets: [URL], fakeKey: String, reasoning: [String]) throws {
        var files = Set<URL>()
        for target in targets {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isRegularFile == true { files.insert(target) }
            if values.isDirectory == true {
                let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                while let file = enumerator?.nextObject() as? URL {
                    let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if value.isRegularFile == true, value.isSymbolicLink != true { files.insert(file) }
                }
            }
        }
        for file in files {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data(fakeKey.utf8)), "Synthetic upstream credential must not enter native storage.")
            for value in reasoning {
                XCTAssertNil(bytes.range(of: Data(value.utf8)), "Provider thinking must stay encrypted in native history and protocol traces.")
            }
        }
    }

    private func assertNoPrivateState(in trace: AppServerWireTrace, fakeKey: String, reasoning: [String]) {
        // The recorder base64-encodes each wire frame; searching the containing
        // JSONL file alone would miss leaked plaintext inside encoded frames.
        for message in trace.messages {
            XCTAssertNil(message.wireData.range(of: Data(fakeKey.utf8)), "Synthetic credential must not enter an engine wire frame.")
            for value in reasoning {
                XCTAssertNil(message.wireData.range(of: Data(value.utf8)), "Raw thinking must not enter an engine wire frame.")
            }
        }
    }
}

private struct APIHarnessFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct APIHarnessNoVisualGrounder: VisualGroundingClient {
    func prepare() async throws { throw APIHarnessFailure("Visual grounding is outside the API fixture.") }
    func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
        throw APIHarnessFailure("Visual grounding is outside the API fixture.")
    }
    func shutdown() async -> [String] { [] }
}

@MainActor
private final class APIHarnessEventAudit {
    let taskID: String
    var began = false
    var terminal = false
    var status: TaskStatus?
    var errors = [String]()
    var finalTexts = [String]()
    var fileEntries = [TimelineEntry]()
    var commands = [TimelineEntry]()
    var toolEvents = [ToolEvent]()
    var diffs = [AgentTurnDiff]()
    var approvals = 0
    init(taskID: String) { self.taskID = taskID }
    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case .taskStatusChanged(let id, let value) where id == taskID:
            status = value
            if value == .running { began = true }
            if began && (value == .completed || value == .waiting) { terminal = true }
        case .timelineEntryAppended(let id, let entry) where id == taskID:
            if let tool = entry.toolEvent { toolEvents.append(tool) }
            if entry.kind == .assistant { finalTexts.append(entry.body) }
            if entry.toolEvent?.name == "fileChange" { fileEntries.append(entry) }
            if entry.toolEvent?.name == "commandExecution" { commands.append(entry) }
            if entry.kind == .system, ["Agent error", "Saved chat history unavailable"].contains(entry.title) { errors.append(entry.body) }
        case .turnDiffUpdated(let id, let turnID, let diff) where id == taskID:
            diffs.append(AgentTurnDiff(id: turnID, diff: diff))
        case .approvalRequested(let request) where request.taskID == taskID: approvals += 1
        case .connectionChanged(.failed(let message)): errors.append(message); terminal = true
        default: break
        }
    }
}

private final class APIHarnessCredentials: APIProviderCredentials, @unchecked Sendable {
    private let providerID: String
    private let value: String
    private let lock = NSLock()
    private var reads = 0
    private var mutations = 0
    init(providerID: String, value: String) { self.providerID = providerID; self.value = value }
    func key(for providerID: String) throws -> String? {
        try lock.withLock {
            guard providerID == self.providerID else { throw APIHarnessFailure("Unexpected synthetic credential owner.") }
            reads += 1; return value
        }
    }
    func save(_ key: String, for providerID: String) throws {
        lock.withLock { mutations += 1 }; throw APIHarnessFailure("Inference must not save a credential.")
    }
    func remove(for providerID: String) throws {
        lock.withLock { mutations += 1 }; throw APIHarnessFailure("Inference must not remove a credential.")
    }
    func counts() -> (reads: Int, mutations: Int) { lock.withLock { (reads, mutations) } }
}

private actor APIHarnessRateLimitObservations {
    private var requests = 0
    private var streaming = false
    private var commandOffered = false
    private var patchOffered = false

    func record(_ request: APIModelServer.HTTPRequest) {
        requests += 1
        guard request.method == "POST", request.path == "/v1/chat/completions",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let tools = body["tools"] as? [[String: Any]] else { return }
        streaming = body["stream"] as? Bool == true
        for tool in tools {
            guard let function = tool["function"] as? [String: Any],
                  let schema = function["parameters"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else { continue }
            if properties["cmd"] != nil { commandOffered = true }
            if properties["input"] != nil,
               (function["description"] as? String ?? "").lowercased().contains("patch") { patchOffered = true }
        }
    }

    func receipt() -> (requests: Int, streaming: Bool, commandOffered: Bool, patchOffered: Bool) {
        (requests, streaming, commandOffered, patchOffered)
    }
}

private actor APIHarnessInference {
    struct Receipt: Sendable {
        var requestCount = 0
        var requestsWereStreaming = true
        var patchOffered = false
        var commandOffered = false
        var patchOutputMatched = false
        var commandOutputMatched = false
        var reasoningRoundtripped = false
        var reasoningSurvivedColdResume = false
        var originalToolResultsSurvivedColdResume = false
        var semanticNamingStable = true
        var failures = [String]()
    }
    private let projectPath: String
    private let marker: String
    private let privateReasoning: [String]
    private let expectedKey: String
    private let patchCallID = "fixture-native-patch-call"
    private let commandCallID = "fixture-native-command-call"
    private var observations = Receipt()
    private var firstToolNames: Set<String>?
    init(projectPath: String, marker: String, privateReasoning: [String], expectedKey: String) {
        self.projectPath = projectPath; self.marker = marker; self.privateReasoning = privateReasoning; self.expectedKey = expectedKey
    }
    func receipt() -> Receipt { observations }
    func respond(_ request: APIModelServer.HTTPRequest) -> APIHarnessHTTPFixture.Response {
        do {
            guard request.method == "POST", request.path == "/v1/chat/completions",
                  request.headers["authorization"] == "Bearer " + expectedKey,
                  let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  body["model"] as? String == "fixture-native-harness",
                  let messages = body["messages"] as? [[String: Any]],
                  let tools = body["tools"] as? [[String: Any]] else { throw APIHarnessFailure("request_contract") }
            observations.requestCount += 1
            observations.requestsWereStreaming = observations.requestsWereStreaming && body["stream"] as? Bool == true
            let currentNames = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            let semantic = !currentNames.isEmpty && currentNames.allSatisfy {
                !$0.hasPrefix("computa_tool_") && $0.range(of: #"^[A-Za-z0-9_-]+__[a-f0-9]{24}$"#, options: .regularExpression) != nil
            }
            if let firstToolNames { observations.semanticNamingStable = observations.semanticNamingStable && firstToolNames == currentNames }
            else { firstToolNames = currentNames }
            observations.semanticNamingStable = observations.semanticNamingStable && semantic
            let count = observations.requestCount
            let message: [String: Any], finish: String
            if count == 1 {
                guard !String(decoding: request.body, as: UTF8.self).contains(marker),
                      let patchName = try toolName(tools, property: "input", descriptionContains: "patch") else {
                    throw APIHarnessFailure("patch_not_offered")
                }
                observations.patchOffered = true
                let patch = "*** Begin Patch\n*** Update File: fixture.txt\n@@\n-old\n+fixed\n*** End Patch"
                message = try toolMessage(name: patchName, id: patchCallID, arguments: ["input": patch], reasoning: privateReasoning[0])
                finish = "tool_calls"
            } else if count == 2 {
                guard let output = matchingToolOutput(messages, id: patchCallID), output.contains("Success. Updated the following files"),
                      assistantReasoning(messages).contains(privateReasoning[0]),
                      let commandName = try toolName(tools, property: "cmd") else { throw APIHarnessFailure("patch_roundtrip") }
                observations.patchOutputMatched = true; observations.commandOffered = true; observations.reasoningRoundtripped = true
                let command = "/usr/bin/python3 -c 'from pathlib import Path; assert Path(\"fixture.txt\").read_text() == \"fixed\\n\"; assert Path(\"unrelated.txt\").read_text() == \"untouched\\n\"; print(Path(\"receipt.txt\").read_text().strip())'"
                guard !command.contains(marker) else { throw APIHarnessFailure("marker_in_command") }
                message = try toolMessage(name: commandName, id: commandCallID,
                    arguments: ["cmd": command, "workdir": projectPath, "yield_time_ms": 10_000, "max_output_tokens": 1_000],
                    reasoning: privateReasoning[1])
                finish = "tool_calls"
            } else if count == 3 {
                guard let output = matchingToolOutput(messages, id: commandCallID), output.contains(marker),
                      output.contains("Process exited with code 0"),
                      Set(assistantReasoning(messages)).isSuperset(of: privateReasoning.prefix(2)) else { throw APIHarnessFailure("command_roundtrip") }
                observations.commandOutputMatched = true
                message = ["role": "assistant", "content": marker, "reasoning": privateReasoning[2]]; finish = "stop"
            } else if count == 4 {
                guard Set(assistantReasoning(messages)).isSuperset(of: privateReasoning),
                      matchingToolOutput(messages, id: patchCallID)?.contains("Success. Updated the following files") == true,
                      matchingToolOutput(messages, id: commandCallID)?.contains(marker) == true,
                      messages.contains(where: { $0["role"] as? String == "assistant" && $0["content"] as? String == marker }) else {
                    throw APIHarnessFailure("cold_resume_history")
                }
                observations.reasoningSurvivedColdResume = true; observations.originalToolResultsSurvivedColdResume = true
                message = ["role": "assistant", "content": marker]; finish = "stop"
            } else { throw APIHarnessFailure("unexpected_provider_replay") }
            return .init(status: "200 OK", body: try streamingReply(message: message, finish: finish, count: count))
        } catch {
            observations.failures.append((error as? APIHarnessFailure)?.message ?? "fixture_response_failed")
            return .init(status: "400 Bad Request", body: Data("{\"error\":{\"code\":\"fixture_contract_rejected\"}}".utf8), contentType: "application/json")
        }
    }
    private func toolName(_ tools: [[String: Any]], property: String, descriptionContains: String? = nil) throws -> String? {
        let candidates = tools.compactMap { item -> String? in
            guard item["type"] as? String == "function", let function = item["function"] as? [String: Any],
                  let schema = function["parameters"] as? [String: Any], let properties = schema["properties"] as? [String: Any],
                  properties[property] != nil, let name = function["name"] as? String else { return nil }
            if let descriptionContains, !(function["description"] as? String ?? "").lowercased().contains(descriptionContains) { return nil }
            return name
        }
        guard candidates.count <= 1 else { throw APIHarnessFailure("ambiguous_native_tool") }
        return candidates.first
    }
    private func toolMessage(name: String, id: String, arguments: [String: Any], reasoning: String) throws -> [String: Any] {
        ["role": "assistant", "content": NSNull(), "reasoning": reasoning,
         "tool_calls": [["id": id, "type": "function", "function": ["name": name,
            "arguments": String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)]]]]
    }
    private func matchingToolOutput(_ messages: [[String: Any]], id: String) -> String? {
        let calls = messages.filter { $0["role"] as? String == "assistant" }.flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }
        let outputs = messages.filter { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == id }
        guard calls.filter({ $0["id"] as? String == id }).count == 1, outputs.count == 1 else { return nil }
        return outputs.first?["content"] as? String
    }
    private func assistantReasoning(_ messages: [[String: Any]]) -> [String] {
        messages.filter { $0["role"] as? String == "assistant" }.compactMap { $0["reasoning"] as? String }
    }
    private func streamingReply(message: [String: Any], finish: String, count: Int) throws -> Data {
        let id = "chatcmpl-fixture-\(count)"
        var frames: [[String: Any]] = []
        func frame(_ delta: [String: Any], finishReason: Any = NSNull()) -> [String: Any] {
            ["id": id, "object": "chat.completion.chunk", "model": "fixture-native-harness",
             "choices": [["index": 0, "delta": delta, "finish_reason": finishReason]]]
        }
        frames.append(frame(["role": "assistant"]))
        if let reasoning = message["reasoning"] as? String { frames.append(frame(["reasoning": reasoning])) }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            let call = calls[0], function = call["function"] as! [String: Any]
            let arguments = function["arguments"] as! String
            let boundary = arguments.index(arguments.startIndex, offsetBy: arguments.count / 2)
            frames.append(frame(["tool_calls": [["index": 0, "id": call["id"]!, "type": "function",
                "function": ["name": function["name"]!, "arguments": String(arguments[..<boundary])]]]]))
            frames.append(frame(["tool_calls": [["index": 0, "function": ["arguments": String(arguments[boundary...])]]]]))
        } else if let content = message["content"] as? String { frames.append(frame(["content": content])) }
        frames.append(frame([:], finishReason: finish))
        frames.append(["id": id, "object": "chat.completion.chunk", "model": "fixture-native-harness", "choices": [],
                       "usage": ["prompt_tokens": 120, "completion_tokens": 80, "total_tokens": 200,
                                 "completion_tokens_details": ["reasoning_tokens": 20]]])
        var result = Data()
        for value in frames { result.append(Data("data: ".utf8)); result.append(try JSONSerialization.data(withJSONObject: value)); result.append(Data("\n\n".utf8)) }
        result.append(Data("data: [DONE]\n\n".utf8)); return result
    }
}

private actor APIHarnessCorrectionInference {
    struct Receipt: Sendable {
        var requests = 0
        var rejectedBatchHadNoEffectsAtCorrection = false
        var firstUsageDurableBeforeCorrection = false
        var correctiveRequestPreservedOriginal = false
        var acceptedToolHistoryOnly = false
        var failures = [String]()
    }
    private let project: URL
    private let accounting: URL
    private let marker: String
    private let expectedKey: String
    private let rejectedThinking: String
    private var observations = Receipt()
    private var originalBody: [String: Any]?
    init(project: URL, accounting: URL, marker: String, expectedKey: String, rejectedThinking: String) {
        self.project = project; self.accounting = accounting; self.marker = marker
        self.expectedKey = expectedKey; self.rejectedThinking = rejectedThinking
    }
    func receipt() -> Receipt { observations }
    func respond(_ request: APIModelServer.HTTPRequest) -> APIHarnessHTTPFixture.Response {
        observations.requests += 1
        do {
            guard request.method == "POST", request.path == "/v1/chat/completions",
                  request.headers["authorization"] == "Bearer " + expectedKey,
                  let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  body["model"] as? String == "fixture-correction-model", body["stream"] as? Bool == true,
                  let tools = body["tools"] as? [[String: Any]], let messages = body["messages"] as? [[String: Any]] else {
                throw APIHarnessFailure("request_contract")
            }
            let patchName = try toolName(tools, property: "input", descriptionContains: "patch")
            let commandName = try toolName(tools, property: "cmd")
            let message: [String: Any], finish: String, usage: [String: Any]
            switch observations.requests {
            case 1:
                guard body["parallel_tool_calls"] as? Bool == true else { throw APIHarnessFailure("parallel_batch_not_offered") }
                originalBody = body
                let patch = "*** Begin Patch\n*** Add File: rejected-batch.txt\n+must never execute\n*** End Patch"
                message = ["role": "assistant", "content": rejectedThinking + "_VISIBLE", "reasoning": rejectedThinking,
                    "tool_calls": [try call(patchName, id: "rejected-valid-patch", arguments: ["input": patch]),
                                   try call(commandName, id: "rejected-invalid-command", arguments: ["cmd": 42])]]
                finish = "tool_calls"; usage = tokens(input: 11, output: 7, cached: 2, reasoning: 3)
            case 2:
                // This check occurs in the second actual upstream HTTP handler,
                // before its response can publish any native item or tool effect.
                guard !FileManager.default.fileExists(atPath: project.appendingPathComponent("rejected-batch.txt").path),
                      !FileManager.default.fileExists(atPath: project.appendingPathComponent("execution-count.txt").path),
                      try String(contentsOf: project.appendingPathComponent("fixture.txt"), encoding: .utf8) == "old\n" else {
                    throw APIHarnessFailure("rejected_batch_executed")
                }
                observations.rejectedBatchHadNoEffectsAtCorrection = true
                let records = try FileManager.default.contentsOfDirectory(at: accounting, includingPropertiesForKeys: nil).map {
                    try JSONDecoder().decode(APIModelCorrectionAccounting.Record.self, from: Data(contentsOf: $0))
                }
                guard records.count == 2, Set(records.map(\.phase)) == Set(["first_received", "second_claimed"]),
                      Set(records.map(\.correctionID)).count == 1,
                      records.allSatisfy({ $0.firstUsage.totalTokens == 18 && $0.secondUsage == nil }),
                      records.first(where: { $0.phase == "second_claimed" })?.secondRequestClaimed == true,
                      records.first(where: { $0.phase == "second_claimed" })?.secondUsageUnknown == true else {
                    throw APIHarnessFailure("first_usage_not_durable_before_correction")
                }
                observations.firstUsageDurableBeforeCorrection = true
                guard var expected = originalBody, var expectedMessages = expected["messages"] as? [[String: Any]] else {
                    throw APIHarnessFailure("missing_original_request")
                }
                guard let correctionText = messages.first?["content"] as? String,
                      let markerRange = correctionText.range(of: APIModelResponseCodec.schemaFeedbackMarker),
                      let facts = try JSONSerialization.jsonObject(with: Data(correctionText[markerRange.upperBound...].utf8)) as? [[String: Any]], facts.count == 1,
                      facts[0]["callable"] as? String == commandName,
                      facts[0]["constraint"] as? String == "type_mismatch",
                      facts[0]["schema_path"] as? [String] == ["properties", "cmd"],
                      facts[0]["expected_types"] as? [String] == ["string"] else { throw APIHarnessFailure("missing_static_schema_feedback") }
                if expectedMessages.first?["role"] as? String == "system" {
                    guard let text = expectedMessages[0]["content"] as? String,
                          correctionText.hasPrefix(text + "\n\n" + APIModelResponseCodec.correctiveFeedback + "\n\n") else { throw APIHarnessFailure("system_content") }
                    expectedMessages[0]["content"] = correctionText
                } else {
                    guard correctionText.hasPrefix(APIModelResponseCodec.correctiveFeedback + "\n\n") else { throw APIHarnessFailure("system_content") }
                    expectedMessages.insert(["role": "system", "content": correctionText], at: 0)
                }
                expected["messages"] = expectedMessages
                guard NSDictionary(dictionary: body).isEqual(to: expected),
                      !String(decoding: request.body, as: UTF8.self).contains(rejectedThinking),
                      !messages.contains(where: { $0["role"] as? String == "tool" }) else {
                    throw APIHarnessFailure("correction_changed_request_or_published_rejected_batch")
                }
                observations.correctiveRequestPreservedOriginal = true
                // Native cwd may use /var while the private stores require /private/var.
                // Resolve the synthetic patch within that already-bound isolated cwd.
                let patch = "*** Begin Patch\n*** Update File: fixture.txt\n@@\n-old\n+fixed\n*** End Patch"
                message = ["role": "assistant", "content": NSNull(),
                    "tool_calls": [try call(patchName, id: "accepted-patch", arguments: ["input": patch])]]
                finish = "tool_calls"; usage = tokens(input: 23, output: 13, cached: 4, reasoning: 5)
            case 3:
                guard matchingToolOutput(messages, id: "accepted-patch")?.contains("Success. Updated the following files") == true,
                      !String(decoding: request.body, as: UTF8.self).contains("rejected-valid-patch"),
                      !String(decoding: request.body, as: UTF8.self).contains("rejected-invalid-command"),
                      !String(decoding: request.body, as: UTF8.self).contains(APIModelResponseCodec.correctiveFeedback) else {
                    throw APIHarnessFailure("accepted_patch_history")
                }
                let command = "/usr/bin/python3 -c 'from pathlib import Path; assert Path(\"fixture.txt\").read_text() == \"fixed\\n\"; assert Path(\"unrelated.txt\").read_text() == \"untouched\\n\"; assert not Path(\"rejected-batch.txt\").exists(); count=Path(\"execution-count.txt\"); count.open(\"a\").write(\"executed\\n\"); print(Path(\"receipt.txt\").read_text().strip())'"
                guard !command.contains(marker) else { throw APIHarnessFailure("marker_in_command") }
                message = ["role": "assistant", "content": NSNull(), "tool_calls": [try call(commandName,
                    id: "accepted-command", arguments: ["cmd": command, "workdir": project.path,
                        "yield_time_ms": 10_000, "max_output_tokens": 1_000])]]
                finish = "tool_calls"; usage = tokens(input: 41, output: 17, cached: 0, reasoning: 0)
            case 4:
                guard matchingToolOutput(messages, id: "accepted-patch")?.contains("Success. Updated the following files") == true,
                      let commandOutput = matchingToolOutput(messages, id: "accepted-command"), commandOutput.contains(marker),
                      commandOutput.contains("Process exited with code 0"),
                      !String(decoding: request.body, as: UTF8.self).contains("rejected-valid-patch"),
                      !String(decoding: request.body, as: UTF8.self).contains("rejected-invalid-command") else {
                    throw APIHarnessFailure("accepted_command_history")
                }
                observations.acceptedToolHistoryOnly = true
                message = ["role": "assistant", "content": marker]
                finish = "stop"; usage = tokens(input: 61, output: 19, cached: 0, reasoning: 0)
            default: throw APIHarnessFailure("unexpected_provider_request")
            }
            return .init(status: "200 OK", body: try stream(message: message, finish: finish, usage: usage))
        } catch {
            observations.failures.append((error as? APIHarnessFailure)?.message ?? "fixture_response_failed")
            return .init(status: "400 Bad Request", body: Data("{\"error\":{\"code\":\"fixture_contract_rejected\"}}".utf8), contentType: "application/json")
        }
    }
    private func toolName(_ tools: [[String: Any]], property: String, descriptionContains: String? = nil) throws -> String {
        let candidates = tools.compactMap { item -> String? in
            guard item["type"] as? String == "function", let function = item["function"] as? [String: Any],
                  let schema = function["parameters"] as? [String: Any], let properties = schema["properties"] as? [String: Any],
                  properties[property] != nil, let name = function["name"] as? String else { return nil }
            if let descriptionContains, !(function["description"] as? String ?? "").lowercased().contains(descriptionContains) { return nil }
            return name
        }
        guard candidates.count == 1 else { throw APIHarnessFailure("native_tool_missing_or_ambiguous") }
        return candidates[0]
    }
    private func call(_ name: String, id: String, arguments: [String: Any]) throws -> [String: Any] {
        ["id": id, "type": "function", "function": ["name": name,
            "arguments": String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys), as: UTF8.self)]]
    }
    private func matchingToolOutput(_ messages: [[String: Any]], id: String) -> String? {
        let calls = messages.filter { $0["role"] as? String == "assistant" }.flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }
        let outputs = messages.filter { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == id }
        guard calls.filter({ $0["id"] as? String == id }).count == 1, outputs.count == 1 else { return nil }
        return outputs.first?["content"] as? String
    }
    private func tokens(input: Int, output: Int, cached: Int, reasoning: Int) -> [String: Any] {
        ["prompt_tokens": input, "completion_tokens": output, "total_tokens": input + output,
         "prompt_tokens_details": ["cached_tokens": cached], "completion_tokens_details": ["reasoning_tokens": reasoning]]
    }
    private func stream(message: [String: Any], finish: String, usage: [String: Any]) throws -> Data {
        let id = "chatcmpl-correction-\(observations.requests)"
        func frame(_ delta: [String: Any], finishReason: Any = NSNull()) -> [String: Any] {
            ["id": id, "object": "chat.completion.chunk", "model": "fixture-correction-model",
             "choices": [["index": 0, "delta": delta, "finish_reason": finishReason]]]
        }
        var frames = [frame(["role": "assistant"])]
        if let reasoning = message["reasoning"] as? String { frames.append(frame(["reasoning": reasoning])) }
        if let text = message["content"] as? String { frames.append(frame(["content": text])) }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for (index, original) in calls.enumerated() {
                var call = original; call["index"] = index
                frames.append(frame(["tool_calls": [call]]))
            }
        }
        frames.append(frame([:], finishReason: finish))
        frames.append(["id": id, "object": "chat.completion.chunk", "model": "fixture-correction-model", "choices": [], "usage": usage])
        var result = Data()
        for frame in frames {
            result.append(Data("data: ".utf8)); result.append(try JSONSerialization.data(withJSONObject: frame)); result.append(Data("\n\n".utf8))
        }
        result.append(Data("data: [DONE]\n\n".utf8))
        return result
    }
}

/// A finite owned listener follows the existing APIModelServerTests fixture
/// pattern. It saves no request bodies and drains only its own sockets/tasks.
private final class APIHarnessHTTPFixture: @unchecked Sendable {
    struct Response: Sendable {
        let status: String
        let body: Data
        var contentType = "text/event-stream"
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ComputaTests.API.harness-loopback")
    private let lock = NSLock()
    private var sockets = [UUID: NWConnection]()
    private var tasks = [UUID: Task<Void, Never>]()
    init(_ handler: @escaping @Sendable (APIModelServer.HTTPRequest) async -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            self.lock.withLock { self.sockets[id] = connection }
            connection.start(queue: self.queue)
            let task = Task {
                defer { connection.cancel(); self.retire(id) }
                do {
                    var buffer = Data()
                    while true {
                        let data: Data = try await withCheckedThrowingContinuation { continuation in
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                                if let error { continuation.resume(throwing: error) }
                                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                                else { continuation.resume(throwing: CancellationError()) }
                            }
                        }
                        buffer.append(data)
                        if let request = try APIModelServer.parseRequest(buffer) {
                            let response = await handler(request)
                            var output = Data("HTTP/1.1 \(response.status)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8)
                            output.append(response.body)
                            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                connection.send(content: output, completion: .contentProcessed { error in
                                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                                })
                            }
                            break
                        }
                    }
                } catch { }
            }
            self.lock.withLock { self.tasks[id] = task }
        }
    }
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = APIHarnessListenerReady(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port { once.finish(.success(port.rawValue)) }
                    else { once.finish(.failure(APIHarnessFailure("Fixture listener has no port."))) }
                case .failed(let error): once.finish(.failure(error))
                case .cancelled: once.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/v1")!
    }
    func stop() async {
        listener.cancel()
        let values = lock.withLock { (Array(sockets.values), Array(tasks.values)) }
        for task in values.1 { task.cancel() }
        for socket in values.0 { socket.cancel() }
        for task in values.1 { await task.value }
        lock.withLock { sockets.removeAll(); tasks.removeAll() }
    }
    private func retire(_ id: UUID) { lock.withLock { sockets.removeValue(forKey: id); tasks.removeValue(forKey: id) } }
}
private final class APIHarnessListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ value: Result<UInt16, Error>) {
        let once = lock.withLock { let current = continuation; continuation = nil; return current }
        once?.resume(with: value)
    }
}
#endif

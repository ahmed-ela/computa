#if DEBUG
import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Genuine bundled Core/HTTP/tool frames; only website inference is synthetic.
/// The finite printed result is budget evidence, never provider qualification.
@MainActor
final class GroqBundledPreflightProducerTests: XCTestCase {
    func testBundledGroq27BProducesUnmodifiedNativePreflightFramesOrAnExactLocalBudgetStop() async throws {
        try await produce(choice: WebsiteModelChoice(provider: "groq", key: "qwen/qwen3.8-27b", label: "Qwen/Qwen3.8-27B"))
    }

    func testBundledGroq120BProducesUnmodifiedNativePreflightFramesOrAnExactLocalBudgetStop() async throws {
        try await produce(choice: WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B"))
    }

    func testBundledNativeComputerSelectionKeepsBrowserEntryLoadableWithoutUserEnablement() async throws {
        guard ProcessInfo.processInfo.environment["COMPUTA_TEST_GROQ_LOADER_SELF_SERVICE"] == "1" else {
            throw XCTSkip("Explicit opt-in required: COMPUTA_TEST_GROQ_LOADER_SELF_SERVICE=1")
        }
        let failures = try XCTUnwrap(testRun).failureCount
        let artifact = try ComputaRuntimeArtifact.resolve()
        XCTAssertEqual(artifact.manifest.sourceCommit, ComputaRuntimeArtifact.sourceCommit)
        let choice = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GroqLoaderSelfService-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true), workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let task = UUID().uuidString.lowercased(), marker = "GROQ_LOADER_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let user = "This is a schema-only fixture. First load exactly exec_command, computer_v2_open, computer_v2_fill and computer_v2_read_page. Then load browser_open and acknowledge. Do not execute commands, inspect apps, open pages, perform input or request permissions."
        let reducer = GroqProducerReducer(taskID: task, modelID: choice.modelID, userText: user)
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = choice.modelID; config.codexHomePath = home.path; config.workspacePath = workspace.path
        config.protocolTracePath = nil; config.groqPreflightObserverForTesting = { reducer.observe($0, $1) }
        let runtime = CodexAppServerRuntime(configuration: config, visualGrounder: GroqProducerNoVisualGrounder())
        let browser = InertRuntimeBrowser(), transport = GroqLoaderSelfServiceTransport(choice: choice, marker: marker)
        let audit = GroqProducerAudit(taskID: task, marker: marker)
        let watcher = Task { for await event in runtime.events() { audit.receive(event) } }
        do {
            await runtime.configureEmbeddedBrowserTools(EmbeddedBrowserToolController(transport: browser))
            await runtime.configureEmbeddedWebModelTransport(WebsiteInferenceFixtureTransport(transport))
            await runtime.setGroqSubmissionIntervalForTesting(.zero)
            let tasks = try await runtime.loadTasks(); XCTAssertTrue(tasks.isEmpty)
            try await runtime.configureWorkspace(path: workspace.path, forTaskID: task)
            try await runtime.submit(prompt: user, toTaskID: task, modelID: choice.modelID)
            let deadline = ContinuousClock.now + .seconds(300)
            while !audit.terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(audit.terminal); XCTAssertEqual(audit.status, .completed); XCTAssertTrue(audit.finalMarkerSeen)
            XCTAssertEqual(audit.approvals, 0)
            let shutdown = await runtime.shutdown(); watcher.cancel(); XCTAssertTrue(shutdown.succeeded)
            let observed = reducer.snapshot(), receipt = await transport.receipt(), counts = await browser.counts()
            XCTAssertTrue(observed.issues.isEmpty, observed.issues.joined(separator: ","))
            XCTAssertEqual(observed.inferences.count, 3); XCTAssertEqual(receipt.sends, 3)
            XCTAssertEqual(receipt.displayPairs.count, receipt.sends)
            XCTAssertEqual(receipt.starts.count, 3); XCTAssertEqual(Set(receipt.starts).count, 3)
            XCTAssertEqual(Set(receipt.starts), Set(receipt.finished))
            XCTAssertTrue(receipt.firstFourLoaded); XCTAssertTrue(receipt.browserEntryEligibleAfterFirstLoad)
            XCTAssertTrue(receipt.loaderCallableAfterFirstLoad); XCTAssertTrue(receipt.browserSchemaShownAfterSecondLoad)
            XCTAssertTrue(receipt.selfServiceHandoffShown); XCTAssertTrue(receipt.deferredPageToolsWithheld)
            XCTAssertEqual(receipt.onlyLoaderNativePairs, 2)
            XCTAssertEqual(Set(observed.inferences.map(\.fullRegistrySHA256)).count, 1)
            for (index, inference) in observed.inferences.enumerated() {
                XCTAssertTrue(inference.fullNativeRegistryPresent); XCTAssertTrue(inference.registeredLoaderPresent)
                XCTAssertTrue(inference.registeredHistoryReaderPresent); XCTAssertEqual(inference.fullRegistryCount, 24)
                XCTAssertTrue(inference.fixtureUserPreserved); XCTAssertEqual(inference.nativeHTTPPairs.count, index)
                XCTAssertTrue(inference.compactToolThread)
                XCTAssertNotEqual(inference.bodyMetadataMatches, false)
                XCTAssertTrue(inference.candidates.allSatisfy { $0.nativeHTTPBodySHA256 == inference.nativeHTTPBodySHA256 })
                XCTAssertTrue(inference.nativeHTTPPairs.allSatisfy { $0.name == GroqToolCatalog.name
                    && !$0.callRecordIDPresent && !$0.outputRecordIDPresent })
                if index > 0 {
                    let previous = observed.inferences[index - 1].nativeHTTPPairs
                    XCTAssertEqual(Array(inference.nativeHTTPPairs.prefix(previous.count)), previous)
                }
                if receipt.displayPairs.indices.contains(index) {
                    XCTAssertEqual(inference.nativeHTTPPairs, receipt.displayPairs[index],
                        "The exact admitted Send must preserve native call IDs, literal args/output hashes and output shape")
                } else { XCTFail("An admitted native inference has no matching displayed pair capture") }
                let sentSHA = receipt.promptSHA256.indices.contains(index) ? receipt.promptSHA256[index] : nil
                XCTAssertEqual(inference.candidates.last?.promptSHA256, sentSHA)
                XCTAssertEqual(inference.admittedUnits, inference.candidates.last?.sourceUnits)
                XCTAssertLessThanOrEqual(try XCTUnwrap(inference.admittedUnits), 6_000); XCTAssertNil(inference.rejection)
            }
            XCTAssertEqual(counts.created, 0); XCTAssertEqual(counts.mutations, 0); XCTAssertEqual(counts.observations, 0)
            XCTAssertEqual(counts.activations, 0); XCTAssertEqual(counts.humanCloseAttempts, 0); XCTAssertTrue(counts.humanIntact)
            let first = try XCTUnwrap(observed.inferences.first)
            XCTAssertEqual(audit.threadID, first.threadID); XCTAssertTrue(audit.threadBindingConsistent)
            let cleanup = try WebsiteSessionCleanupStore(directory: home.appendingPathComponent("WebsiteSessionCleanup-v1"))
                .transactionRecords(for: task, turnID: first.turnID)
            let closed = cleanup.filter { $0.outcome == .closed }
            XCTAssertEqual(closed.count, 3); XCTAssertEqual(Set(closed.compactMap(\.sessionToken)), Set(receipt.finished))
            XCTAssertTrue(closed.allSatisfy { $0.isValid && $0.receiptSaved && $0.reason == .transcriptCleared
                && $0.provider == .groq && $0.modelID == choice.modelID && $0.threadID == first.threadID && $0.turnID == first.turnID
                && $0.runtimeGeneration == first.runtimeGeneration.uuidString.lowercased() })
            let journal = home.appendingPathComponent("WebsiteModelEvidence-v1/transactions/" + task + "/" + first.turnID + ".jsonl")
            let rows = try Data(contentsOf: journal).split(separator: 10).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
            let released = rows.filter { $0["phase"] as? String == "release_verified" }
            XCTAssertEqual(released.count, 3)
            XCTAssertEqual(Set(released.compactMap { $0["cleanupAttemptID"] as? String }), Set(closed.map(\.attemptID)))
            XCTAssertTrue(released.allSatisfy { $0["transactionMode"] as? String == "explicit_clear_per_inference" })
            let retired = retireRegistrations(home: home, threadID: first.threadID, modelID: choice.modelID); XCTAssertTrue(retired)
            guard testRun?.failureCount == failures else { throw GroqProducerFailure("loader_self_service_invariant") }
            let report = GroqLoaderSelfServiceReport(firstFourLoaded: receipt.firstFourLoaded,
                browserEntryEligibleAfterFirstLoad: receipt.browserEntryEligibleAfterFirstLoad,
                loaderCallableAfterFirstLoad: receipt.loaderCallableAfterFirstLoad,
                browserSchemaShownAfterSecondLoad: receipt.browserSchemaShownAfterSecondLoad,
                selfServiceHandoffShown: receipt.selfServiceHandoffShown, deferredPageToolsWithheld: receipt.deferredPageToolsWithheld,
                sends: receipt.sends, closed: closed.count, onlyLoaderNativePairs: receipt.onlyLoaderNativePairs,
                nativeRegistryUnchanged: Set(observed.inferences.map(\.fullRegistrySHA256)).count == 1,
                nativeRegistryCount: 24, providerQualificationClaimed: false, realProviderOrBrowserActions: 0)
            try writeFiniteReport(JSONEncoder().encode(report), prefix: "groqLoaderSelfServiceFinite=")
            try FileManager.default.removeItem(at: root)
        } catch {
            _ = await runtime.shutdown(); watcher.cancel()
            _ = retireRegistrations(home: home, threadID: audit.threadID ?? reducer.snapshot().inferences.first?.threadID, modelID: choice.modelID)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func testDiscoveryNoticeJoinsUnloadedRowsWithExactLoadedSchemas() throws {
        let names = [GroqToolCatalog.name, GroqHistoryTool.name, "computer_v2_status"]
        let tools = names.map { GroqProducerFacts.Tool(local: $0, qualified: $0) }
        let revision = String(repeating: "a", count: 64)
        let unloaded: [String: Any] = ["catalog_revision": revision, "loaded": names,
            "inventory": [["exec_command", "function"]]]
        let legacy: [String: Any] = ["catalog_revision": revision, "loaded": names,
            "inventory": (names + ["exec_command"]).map { [$0, "Inert purpose", "function"] }]
        let expected = Set(names + ["exec_command"])
        XCTAssertEqual(try GroqProducerFacts.catalogNames(unloaded, tools: tools), expected)
        XCTAssertEqual(try GroqProducerFacts.catalogNames(legacy, tools: tools), expected)
        let rows = try XCTUnwrap(unloaded["inventory"] as? [[String]])
        XCTAssertFalse(rows.contains { $0.first == GroqToolCatalog.name }, "The loader is intentionally absent from unloaded rows")
        for kind in ["duplicate_loaded", "missing_schema", "foreign_schema", "unknown_kind", "duplicate_row", "loaded_in_unloaded", "extra_key"] {
            var changed = unloaded, shown = tools
            switch kind {
            case "duplicate_loaded": changed["loaded"] = names + [GroqToolCatalog.name]
            case "missing_schema": shown.removeLast()
            case "foreign_schema": shown.append(.init(local: "foreign", qualified: "foreign"))
            case "unknown_kind": changed["inventory"] = [["exec_command", "unknown"]]
            case "duplicate_row": changed["inventory"] = [["exec_command", "function"], ["exec_command", "function"]]
            case "loaded_in_unloaded": changed["inventory"] = [[GroqToolCatalog.name, "function"]]
            case "extra_key": changed["foreign"] = true
            default: XCTFail("Unknown synthetic notice mutation")
            }
            XCTAssertThrowsError(try GroqProducerFacts.catalogNames(changed, tools: shown), kind)
        }
    }

    private func produce(choice: WebsiteModelChoice) async throws {
        guard ProcessInfo.processInfo.environment["COMPUTA_TEST_GROQ_BUNDLED_PREFLIGHT"] == "1" else {
            throw XCTSkip("Explicit opt-in required: COMPUTA_TEST_GROQ_BUNDLED_PREFLIGHT=1")
        }
        guard let initialRun = testRun else { throw GroqProducerFailure("missing_test_run") }
        let failuresBefore = initialRun.failureCount
        let artifact: ComputaRuntimeArtifact
        do { artifact = try ComputaRuntimeArtifact.resolve() }
        catch ComputaRuntimeArtifact.ValidationError.resourcesUnavailable {
            throw GroqProducerFailure("enabled_producer_missing_bundled_resources")
        } catch ComputaRuntimeArtifact.ValidationError.unavailableFile {
            throw GroqProducerFailure("enabled_producer_missing_bundled_artifact")
        }
        XCTAssertEqual(artifact.manifest.sourceCommit, ComputaRuntimeArtifact.sourceCommit)
        XCTAssertEqual(artifact.executableURL.lastPathComponent, "codex-app-server")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GroqBundledPreflight-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("PrivateCodexHome", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let taskID = UUID().uuidString.lowercased()
        let marker = "GROQ_BUNDLED_PREFLIGHT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let userText = "Load computer_v2_status with computa_load_tools using the current catalog revision. Then read computer_v2_status twice in sequence with empty arguments, waiting for each matching result. Finally reply with the fixture acknowledgment. Do not inspect apps, request permissions, or perform input."
        let reducer = GroqProducerReducer(taskID: taskID, modelID: choice.modelID, userText: userText)
        var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
        configuration.executable = .bundled
        configuration.model = choice.modelID
        configuration.codexHomePath = home.path
        configuration.workspacePath = workspace.path
        configuration.protocolTracePath = nil // Never persist raw model HTTP/RPC frames.
        configuration.groqPreflightObserverForTesting = { context, event in reducer.observe(context, event) }
        let runtime = CodexAppServerRuntime(configuration: configuration, visualGrounder: GroqProducerNoVisualGrounder())
        let browser = InertRuntimeBrowser()
        let transport = GroqProducerTransport(choice: choice, marker: marker)
        let audit = GroqProducerAudit(taskID: taskID, marker: marker)
        let watcher = Task { for await event in runtime.events() { audit.receive(event) } }
        do {
            await runtime.configureEmbeddedBrowserTools(EmbeddedBrowserToolController(transport: browser))
            await runtime.configureEmbeddedWebModelTransport(WebsiteInferenceFixtureTransport(transport))
            // Explicit and independent of installing the observer. No real provider is used.
            await runtime.setGroqSubmissionIntervalForTesting(.zero)
            let initialTasks = try await runtime.loadTasks()
            XCTAssertTrue(initialTasks.isEmpty)
            try await runtime.configureWorkspace(path: workspace.path, forTaskID: taskID)
            try await runtime.submit(prompt: userText, toTaskID: taskID, modelID: choice.modelID)
            let deadline = ContinuousClock.now + .seconds(300)
            while !audit.terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(audit.terminal, "The bounded synthetic bundled turn did not terminate")
            let shutdown = await runtime.shutdown()
            watcher.cancel()
            XCTAssertTrue(shutdown.succeeded, "Isolated bundled runtime teardown failed")
            XCTAssertEqual(audit.approvals, 0)
            let browserCounts = await browser.counts()
            XCTAssertEqual(browserCounts.created, 0)
            XCTAssertEqual(browserCounts.mutations, 0)
            XCTAssertEqual(browserCounts.observations, 0)
            XCTAssertEqual(browserCounts.activations, 0)
            XCTAssertEqual(browserCounts.humanCloseAttempts, 0)
            XCTAssertTrue(browserCounts.humanIntact)
            let observed = reducer.snapshot()
            let receipt = await transport.receipt()
            XCTAssertTrue(observed.issues.isEmpty, observed.issues.joined(separator: ","))
            XCTAssertFalse(observed.inferences.isEmpty, "Require a genuine native preflight callback")
            XCTAssertLessThanOrEqual(observed.inferences.count, 4)
            XCTAssertEqual(Set(observed.inferences.map(\.fullRegistrySHA256)).count, 1, "Keep every original registered definition across native continuation frames")
            XCTAssertLessThanOrEqual(receipt.sendCount, 4)
            XCTAssertEqual(receipt.starts.count, receipt.sendCount)
            XCTAssertEqual(Set(receipt.starts), Set(receipt.finished))
            XCTAssertEqual(Set(receipt.starts).count, receipt.starts.count)
            XCTAssertTrue(receipt.frames.allSatisfy(\.valid))
            let admittedInferences = observed.inferences.filter { $0.admittedUnits != nil }
            XCTAssertEqual(admittedInferences.count, receipt.frames.count)
            for (inference, frame) in zip(admittedInferences, receipt.frames) {
                XCTAssertEqual(inference.candidates.last?.promptSHA256, frame.promptSHA256,
                    "Join the actual synthetic Send bytes to the exact final admitted builder candidate")
                XCTAssertEqual(inference.nativeHTTPPairs, frame.displayPairs,
                    "Compare raw native HTTP pair facts with the exact paired Send display, without inferring ID removal")
            }
            for (index, inference) in observed.inferences.enumerated() {
                XCTAssertEqual(inference.nativeHTTPPairs.count, index,
                    "Each native HTTP frame appends exactly the preceding completed native pair")
                XCTAssertTrue(inference.nativeHTTPPairs.allSatisfy { !$0.callRecordIDPresent && !$0.outputRecordIDPresent },
                    "Pinned mactopus16 omits function record IDs on the external HTTP copy")
                if index > 0 {
                    let previous = observed.inferences[index - 1].nativeHTTPPairs
                    XCTAssertEqual(Array(inference.nativeHTTPPairs.prefix(previous.count)), previous,
                        "The prior native HTTP pair facts remain an immutable prefix")
                }
                XCTAssertTrue(inference.compactToolThread)
                XCTAssertNotEqual(inference.bodyMetadataMatches, false, "Body metadata, when present, must agree with the already checked native hook context")
                XCTAssertTrue(inference.fullNativeRegistryPresent)
                XCTAssertTrue(inference.registeredLoaderPresent)
                XCTAssertTrue(inference.registeredHistoryReaderPresent)
                XCTAssertEqual(inference.fullRegistryCount, 24, "Keep the complete current native registry, including the history reader")
                XCTAssertTrue(inference.fixtureUserPreserved)
                XCTAssertTrue(inference.candidates.allSatisfy { $0.nativeHTTPBodySHA256 == inference.nativeHTTPBodySHA256 })
                XCTAssertLessThanOrEqual(inference.candidates.count, 4)
                if let admitted = inference.admittedUnits {
                    XCTAssertLessThanOrEqual(admitted, 6_000)
                    XCTAssertNil(inference.rejection)
                    XCTAssertEqual(inference.candidates.last?.sourceUnits, admitted)
                }
            }
            let first = try XCTUnwrap(observed.inferences.first)
            XCTAssertEqual(audit.threadID, first.threadID)
            XCTAssertTrue(audit.threadBindingConsistent)
            XCTAssertTrue(GroqToolThreadRegistration.contains(codexHome: home.path,
                threadID: first.threadID, modelID: choice.modelID), "Require accepted native thread registration")
            XCTAssertTrue(GroqHistoryThreadRegistration.contains(codexHome: home.path,
                threadID: first.threadID, modelID: choice.modelID), "Require accepted native history-reader registration")
            let cleanup = try WebsiteSessionCleanupStore(directory: home.appendingPathComponent("WebsiteSessionCleanup-v1"))
                .transactionRecords(for: taskID, turnID: first.turnID)
            let closed = cleanup.filter { $0.outcome == .closed }
            XCTAssertEqual(closed.count, receipt.sendCount)
            XCTAssertEqual(Set(closed.compactMap(\.sessionToken)), Set(receipt.finished.map { $0.lowercased() }))
            XCTAssertTrue(closed.allSatisfy { $0.isValid && $0.receiptSaved && $0.reason == .transcriptCleared
                && $0.provider == .groq && $0.modelID == choice.modelID && $0.threadID == first.threadID
                && $0.turnID == first.turnID && $0.runtimeGeneration == first.runtimeGeneration.uuidString.lowercased() })
            let evidenceURL = home.appendingPathComponent("WebsiteModelEvidence-v1/transactions/" + taskID + "/" + first.turnID + ".jsonl")
            let evidence = FileManager.default.fileExists(atPath: evidenceURL.path)
                ? try Data(contentsOf: evidenceURL).split(separator: 10).map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
                } : []
            let released = evidence.filter { $0["phase"] as? String == "release_verified" }
            XCTAssertEqual(released.count, receipt.sendCount)
            XCTAssertTrue(released.allSatisfy { row in
                row["transactionMode"] as? String == "explicit_clear_per_inference"
                    && closed.contains { $0.attemptID == row["cleanupAttemptID"] as? String
                        && $0.inferenceID == row["inferenceID"] as? String }
            })
            let outcome: String
            if let rejection = observed.inferences.last?.rejection {
                XCTAssertTrue(["bodyTokens", "bodyBytes", "counterUnavailable"].contains(rejection.kind))
                XCTAssertEqual(audit.status, .failed)
                XCTAssertFalse(audit.finalMarkerSeen)
                XCTAssertEqual(observed.inferences.filter { $0.rejection != nil }.count, 1)
                XCTAssertEqual(observed.inferences.count, receipt.sendCount + 1)
                // Original selected error is retained separately from the last fallback candidate.
                if rejection.kind == "bodyTokens" || rejection.kind == "bodyBytes" {
                    XCTAssertEqual(rejection.maximum, 6_000); XCTAssertEqual(rejection.reserved, 2_000)
                    XCTAssertGreaterThan(try XCTUnwrap(rejection.actual), 6_000)
                }
                outcome = "local_preflight_budget_stop"
            } else if receipt.loaderBudgetStop {
                XCTAssertEqual(audit.status, .completed)
                XCTAssertTrue(audit.loaderStopMarkerSeen)
                XCTAssertFalse(audit.finalMarkerSeen)
                XCTAssertEqual(receipt.sendCount, 2)
                XCTAssertEqual(receipt.frames.last?.statusOutputs, 0)
                outcome = "local_loader_budget_stop"
            } else {
                XCTAssertEqual(audit.status, .completed)
                XCTAssertTrue(audit.finalMarkerSeen)
                XCTAssertEqual(receipt.sendCount, 4)
                let final = try XCTUnwrap(receipt.frames.last)
                XCTAssertEqual(final.callCount, 3); XCTAssertEqual(final.outputCount, 3)
                XCTAssertEqual(final.statusOutputs, 2)
                XCTAssertTrue(final.loaderReceiptValid)
                XCTAssertTrue(final.outputIDs.isEmpty, "Current pinned external wire omits result record IDs")
                XCTAssertEqual(final.displayPairs.count, 3)
                outcome = "synthetic_native_sequence_completed"
            }
            let registrationsRetired = retireRegistrations(home: home, threadID: audit.threadID, modelID: choice.modelID)
            XCTAssertTrue(registrationsRetired, "Both exact fixture registrations must be retired")
            guard let finalRun = testRun, finalRun.failureCount == failuresBefore else {
                let failure = GroqProducerReport(outcome: "fixture_invariant_failure", sourceModelID: choice.modelID,
                    registrationTeardownVerified: registrationsRetired,
                    targetRebuildCompared: false, providerQualificationClaimed: false,
                    inferences: observed.inferences, frames: receipt.frames,
                    startCount: receipt.starts.count, sendCount: receipt.sendCount, closedCleanupCount: closed.count)
                let bytes = try JSONEncoder().encode(failure)
                try writeFiniteReport(bytes, prefix: "groqBundledPreflightFailureFinite=")
                throw GroqProducerFailure("producer_invariant_failed")
            }
            let report = GroqProducerReport(outcome: outcome, sourceModelID: choice.modelID,
                registrationTeardownVerified: registrationsRetired,
                targetRebuildCompared: false, providerQualificationClaimed: false,
                inferences: observed.inferences, frames: receipt.frames,
                startCount: receipt.starts.count, sendCount: receipt.sendCount, closedCleanupCount: closed.count)
            let encoded = try JSONEncoder().encode(report)
            try writeFiniteReport(encoded, prefix: "groqBundledPreflightFinite=")
            try FileManager.default.removeItem(at: root)
        } catch {
            _ = await runtime.shutdown()
            watcher.cancel()
            let knownThread = audit.threadID ?? reducer.snapshot().inferences.first?.threadID
            let retired = retireRegistrations(home: home, threadID: knownThread, modelID: choice.modelID)
            print("groqBundledPreflightFailedTeardown threadKnown=\(knownThread != nil) registrationsRetired=\(retired)")
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func writeFiniteReport(_ bytes: Data, prefix: String) throws {
        // Bypass buffered print: XCTest can otherwise write its next test line
        // into the middle of a buffered report even with separate stderr.
        var line = Data(prefix.utf8)
        line.append(bytes)
        line.append(10)
        try FileHandle.standardOutput.write(contentsOf: line)
    }

    private func retireRegistrations(home: URL, threadID: String?, modelID: String) -> Bool {
        guard let threadID, UUID(uuidString: threadID) != nil,
              let groqMarker = GroqToolThreadRegistration.marker(codexHome: home.path, threadID: threadID, modelID: modelID),
              let historyMarker = GroqHistoryThreadRegistration.marker(codexHome: home.path, threadID: threadID, modelID: modelID) else { return false }
        let defaults = UserDefaults.standard
        let referenceKey = "ComputaReferenceToolThreads.v1"
        let referenceMarker = GroqProducerFacts.hash(Data(home.path.utf8)) + ":" + threadID
        // Remove only these exact registrations; preserve every other test/user marker.
        for (key, marker) in [(GroqToolThreadRegistration.preferenceKey, groqMarker),
                              (GroqHistoryThreadRegistration.preferenceKey, historyMarker), (referenceKey, referenceMarker)] {
            let original = defaults.stringArray(forKey: key) ?? []
            if original.contains(marker) { defaults.set(original.filter { $0 != marker }, forKey: key) }
        }
        return !(defaults.stringArray(forKey: GroqToolThreadRegistration.preferenceKey) ?? []).contains(groqMarker)
            && !(defaults.stringArray(forKey: GroqHistoryThreadRegistration.preferenceKey) ?? []).contains(historyMarker)
            && !(defaults.stringArray(forKey: referenceKey) ?? []).contains(referenceMarker)
    }
}

private struct GroqProducerReport: Codable {
    let outcome: String
    let sourceModelID: String
    let registrationTeardownVerified: Bool
    let targetRebuildCompared: Bool
    let providerQualificationClaimed: Bool
    let inferences: [GroqProducerInference]
    let frames: [GroqProducerFrame]
    let startCount: Int
    let sendCount: Int
    let closedCleanupCount: Int
}

private struct GroqProducerCandidate: Codable {
    let promptSHA256: String
    let nativeHTTPBodySHA256: String
    let promptBytes: Int
    let directTools: String
    let compactHistory: Bool
    let qwen27BSameTextUnits: Int?
    let gptOSS120BSameTextUnits: Int?
    let sourceUnits: Int?
    let statistics: WebsitePromptProjection.Statistics
}

private struct GroqProducerRejection: Codable {
    let kind: String
    let actual: Int?
    let maximum: Int?
    let reserved: Int?
}

private struct GroqProducerInference: Codable {
    let taskID: String
    let threadID: String
    let turnID: String
    let modelID: String
    let runtimeGeneration: UUID
    let preparationID: UUID
    let transportGeneration: UUID
    let inferenceID: UUID
    let compactToolThread: Bool
    var nativeHTTPBodySHA256 = ""
    var nativeHTTPBodyBytes = 0
    var fullRegistrySHA256 = ""
    var fullRegistryCount = 0
    var nativeHTTPPairs: [GroqProducerPair] = []
    var fullNativeRegistryPresent = false
    var registeredLoaderPresent = false
    var registeredHistoryReaderPresent = false
    var bodyMetadataMatches: Bool?
    var fixtureUserPreserved = false
    var candidates: [GroqProducerCandidate] = []
    var admittedUnits: Int?
    var rejection: GroqProducerRejection?
}

/// Locked finite reducer: no Data, Request, text, schema or tool-output value is retained.
private final class GroqProducerReducer: @unchecked Sendable {
    struct Snapshot { let inferences: [GroqProducerInference]; let issues: [String] }
    private let lock = NSLock()
    private let taskID: String
    private let modelID: String
    private let userSHA256: String
    private let nativeNames: Set<String>
    private var records: [GroqProducerInference] = []
    private var issues = Set<String>()
    init(taskID: String, modelID: String, userText: String) {
        self.taskID = taskID; self.modelID = modelID; userSHA256 = GroqProducerFacts.hash(Data(userText.utf8))
        nativeNames = Set((ComputerV2ToolContract.referenceSpecs(for: modelID)
            + [ComputerOutcomeToolContract.spec, GroqToolCatalog.specification, GroqHistoryTool.specification] + EmbeddedBrowserTools.definitions()).compactMap { $0["name"] as? String })
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return Snapshot(inferences: records, issues: issues.sorted()) }
    func observe(_ context: WebModelServer.GroqPreflightContextForTesting, _ event: WebModelServer.GroqPreflightEventForTesting) {
        // This older four-round producer issues no reader calls. Ignore the
        // new diagnostic event without allocating a record or changing checks.
        if case .historyReaderPreview = event { return }
        lock.lock(); defer { lock.unlock() }
        guard context.taskID == taskID, context.modelID == modelID, context.compactToolThread,
              [context.taskID, context.threadID, context.turnID].allSatisfy({ UUID(uuidString: $0) != nil }) else {
            issues.insert("native_scope_mismatch"); return
        }
        if let first = records.first {
            guard first.threadID == context.threadID, first.turnID == context.turnID,
                  first.runtimeGeneration == context.runtimeGeneration, first.preparationID == context.preparationID,
                  first.transportGeneration == context.transportGeneration else { issues.insert("changed_native_scope"); return }
        }
        let index: Int
        if let existing = records.firstIndex(where: { $0.inferenceID == context.inferenceID }) { index = existing }
        else {
            guard records.count < 4 else { issues.insert("too_many_native_inferences"); return }
            records.append(GroqProducerInference(taskID: context.taskID, threadID: context.threadID,
                turnID: context.turnID, modelID: context.modelID, runtimeGeneration: context.runtimeGeneration,
                preparationID: context.preparationID, transportGeneration: context.transportGeneration,
                inferenceID: context.inferenceID, compactToolThread: context.compactToolThread))
            index = records.count - 1
        }
        switch event {
        case .historyReaderPreview: break
        case let .canonical(bytes):
            guard records[index].nativeHTTPBodySHA256.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  object["model"] as? String == modelID, let tools = object["tools"] as? [[String: Any]],
                  let toolBytes = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]) else {
                issues.insert("invalid_or_duplicate_canonical"); return
            }
            let definitions = GroqProducerFacts.tools(tools)
            records[index].nativeHTTPBodySHA256 = GroqProducerFacts.hash(bytes)
            records[index].nativeHTTPBodyBytes = bytes.count
            do { records[index].nativeHTTPPairs = try GroqProducerFacts.pairFacts(object) }
            catch { issues.insert("invalid_native_http_pairs") }
            records[index].fullRegistrySHA256 = GroqProducerFacts.hash(toolBytes)
            records[index].fullRegistryCount = definitions.count
            records[index].fullNativeRegistryPresent = nativeNames.isSubset(of: Set(definitions.map { $0.local }))
            records[index].registeredLoaderPresent = GroqToolCatalog.isRegisteredLoader(tools)
            records[index].registeredHistoryReaderPresent = GroqHistoryTool.registeredName(in: tools) != nil
            if let client = object["client_metadata"] as? [String: Any], let raw = client["x-codex-turn-metadata"] as? String,
               let metadata = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                records[index].bodyMetadataMatches = metadata["thread_id"] as? String == context.threadID
                    && metadata["turn_id"] as? String == context.turnID
            }
            let userTexts = (object["input"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
                .flatMap { item -> [String] in
                    if let text = item["content"] as? String { return [text] }
                    return (item["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "input_text" }.compactMap { $0["text"] as? String }
                }
            records[index].fixtureUserPreserved = userTexts.filter { GroqProducerFacts.hash(Data($0.utf8)) == userSHA256 }.count == 1
        case let .candidate(request, directTools, compactHistory):
            guard ["standard", "essential", "loadedOnly"].contains(directTools),
                  !records[index].nativeHTTPBodySHA256.isEmpty, records[index].candidates.count < 4,
                  records[index].admittedUnits == nil, records[index].rejection == nil else {
                issues.insert("candidate_order_or_bound"); return
            }
            let qwen = try? QwenBodyTokenCounter.tokenCount(request.prompt)
            let oss = try? GroqBodyTokenCounter.tokenCount(request.prompt)
            let source = WebsiteModelCatalog.choice(for: modelID)?.key == "qwen/qwen3.8-27b" ? qwen : oss
            records[index].candidates.append(GroqProducerCandidate(promptSHA256: GroqProducerFacts.hash(Data(request.prompt.utf8)),
                nativeHTTPBodySHA256: GroqProducerFacts.hash(request.continuationRequest), promptBytes: request.prompt.utf8.count,
                directTools: directTools, compactHistory: compactHistory,
                qwen27BSameTextUnits: qwen, gptOSS120BSameTextUnits: oss, sourceUnits: source, statistics: request.promptStatistics))
        case let .admitted(units):
            guard !records[index].candidates.isEmpty, records[index].admittedUnits == nil,
                  records[index].rejection == nil else { issues.insert("admission_order"); return }
            records[index].admittedUnits = units
        case let .rejected(kind, actual, maximum, reserved):
            guard records[index].admittedUnits == nil, records[index].rejection == nil else { issues.insert("rejection_order"); return }
            records[index].rejection = GroqProducerRejection(kind: kind.rawValue, actual: actual, maximum: maximum, reserved: reserved)
        }
    }
}

/// Observed transient HTTP/display facts only, not native stored-history records.
private struct GroqProducerPair: Codable, Equatable, Sendable {
    let callID: String
    let name: String
    let namespace: String?
    let argumentsSHA256: String
    let outputType: String
    let outputShape: String
    let outputTextSHA256: String
    let callRecordIDPresent: Bool
    let outputRecordIDPresent: Bool
}

private struct GroqProducerFrame: Codable, Sendable {
    let displayPairs: [GroqProducerPair]
    let promptSHA256: String
    let presentedJSONSHA256: String
    let callCount: Int
    let outputCount: Int
    let callIDs: [String]
    let outputIDs: [String]
    let outputTextSHA256: [String]
    let statusOutputs: Int
    let loaderReceiptValid: Bool
    let loaderBudgetStop: Bool
    let valid: Bool
}

private actor GroqProducerTransport: WebModelTransport {
    struct Receipt: Sendable {
        var starts: [String] = []
        var finished: [String] = []
        var sendCount = 0
        var frames: [GroqProducerFrame] = []
        var loaderBudgetStop = false
    }
    private let choice: WebsiteModelChoice
    private let marker: String
    private var observations = Receipt()
    private var activeToken: String?
    private var reply = ""
    private var revision = ""
    private var loaderName = ""
    private var statusName = ""
    init(choice: WebsiteModelChoice, marker: String) { self.choice = choice; self.marker = marker }
    func receipt() -> Receipt { observations }
    func request(operation: String, params: Data) async throws -> Data {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        var result: [String: Any]
        switch operation {
        case "webProviderStart":
            guard activeToken == nil, observations.starts.count < 4, input["provider"] == "groq",
                  input["modelChoice"].flatMap(WebsiteModelChoice.parse) == choice else { throw GroqProducerFailure("invalid_synthetic_start") }
            let token = UUID().uuidString.lowercased(); activeToken = token; observations.starts.append(token)
            result = ["sessionToken": token, "state": "ready"]
        case "webProviderSend":
            guard input["sessionToken"] == activeToken, observations.sendCount < 4, let prompt = input["prompt"] else {
                throw GroqProducerFailure("invalid_synthetic_send")
            }
            let json = try WebsiteRequestFixture.json(in: prompt)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            guard object["model"] as? String == choice.modelID else { throw GroqProducerFailure("wrong_source_model") }
            let tools = GroqProducerFacts.tools(try XCTUnwrap(object["tools"] as? [[String: Any]]))
            let inventory = try GroqProducerFacts.inventory(prompt)
            let currentRevision = try XCTUnwrap(inventory["catalog_revision"] as? String)
            let names = try GroqProducerFacts.catalogNames(inventory, tools: tools)
            let actualLoader = try XCTUnwrap(names.first { $0 == GroqToolCatalog.name || $0 == "functions." + GroqToolCatalog.name })
            let actualStatus = try XCTUnwrap(names.first { $0 == "computer_v2_status" || $0 == "functions.computer_v2_status" })
            if revision.isEmpty { revision = currentRevision; loaderName = actualLoader; statusName = actualStatus }
            guard currentRevision == revision, actualLoader == loaderName, actualStatus == statusName,
                  tools.contains(where: { $0.qualified == loaderName }) else { throw GroqProducerFailure("catalog_changed") }
            let items = try XCTUnwrap(object["input"] as? [[String: Any]])
            let calls = items.filter { $0["type"] as? String == "function_call" }
            let outputs = items.filter { $0["type"] as? String == "function_call_output" }
            let callIDs = calls.compactMap { $0["call_id"] as? String }
            let outputIDs = outputs.compactMap { $0["id"] as? String }
            let pairFacts = try GroqProducerFacts.pairFacts(object)
            guard calls.count == outputs.count else { throw GroqProducerFailure("unbalanced_native_pairs") }
            var valid = calls.count == observations.sendCount && outputs.count == calls.count
                && Set(callIDs).count == calls.count && outputs.compactMap { $0["call_id"] as? String } == callIDs
                && pairFacts.allSatisfy { !$0.callRecordIDPresent && !$0.outputRecordIDPresent }
                && outputs.allSatisfy { $0["internal_chat_message_metadata_passthrough"] == nil }
            var statusOutputs = 0, loaderReceiptValid = false, loaderBudgetStop = false
            var outputHashes: [String] = []
            for (index, call) in calls.enumerated() {
                let name = try XCTUnwrap(call["name"] as? String)
                let namespace = call["namespace"] as? String
                let qualified = namespace.map { $0 + "." + name } ?? name
                let args = try XCTUnwrap(call["arguments"] as? String)
                let output = try GroqProducerFacts.outputText(outputs[index]["output"])
                outputHashes.append(GroqProducerFacts.hash(Data(output.utf8)))
                if index == 0 {
                    valid = valid && qualified == loaderName
                    let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any])
                    let argumentKeys = Set(arguments.keys)
                    let argumentRevision = arguments["catalog_revision"] as? String
                    let argumentNames = arguments["names"] as? [String]
                    valid = valid && argumentKeys == ["catalog_revision", "names"]
                        && argumentRevision == revision && argumentNames == [statusName]
                    if let receipt = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] {
                        let receiptKeys = Set(receipt.keys)
                        let receiptRevision = receipt["catalog_revision"] as? String
                        let receiptLoaded = receipt["loaded"] as? [String]
                        let receiptAvailable = receipt["available"] as? String
                        let receiptExecution = receipt["execution"] as? Bool
                        loaderReceiptValid = receiptKeys == ["catalog_revision", "loaded", "available", "execution"]
                            && receiptRevision == revision && receiptLoaded == [statusName]
                            && receiptAvailable == "next_request" && receiptExecution == false
                    }
                    loaderBudgetStop = output == GroqToolCatalog.Failure.selectionTooLarge.localizedDescription
                    valid = valid && (loaderReceiptValid || loaderBudgetStop)
                } else {
                    valid = valid && qualified == statusName && args == "{}" && GroqProducerFacts.hostStatus(output)
                    if GroqProducerFacts.hostStatus(output) { statusOutputs += 1 }
                }
            }
            observations.frames.append(GroqProducerFrame(displayPairs: pairFacts, promptSHA256: GroqProducerFacts.hash(Data(prompt.utf8)),
                presentedJSONSHA256: GroqProducerFacts.hash(json), callCount: calls.count, outputCount: outputs.count,
                callIDs: callIDs, outputIDs: outputIDs, outputTextSHA256: outputHashes, statusOutputs: statusOutputs,
                loaderReceiptValid: loaderReceiptValid, loaderBudgetStop: loaderBudgetStop, valid: valid))
            guard valid else { throw GroqProducerFailure("unproved_native_history") }
            observations.sendCount += 1
            if loaderBudgetStop {
                observations.loaderBudgetStop = true
                reply = try GroqProducerFacts.message(marker + "_LOCAL_LOADER_BUDGET_STOP")
            } else if observations.sendCount == 1 {
                reply = try GroqProducerFacts.call(loaderName, arguments: ["catalog_revision": revision, "names": [statusName]])
            } else if observations.sendCount < 4 {
                guard tools.contains(where: { $0.qualified == statusName }) else { throw GroqProducerFailure("status_schema_not_loaded") }
                reply = try GroqProducerFacts.call(statusName, arguments: [:])
            } else { reply = try GroqProducerFacts.message(marker) }
            result = ["state": "running"]
        case "webProviderPoll":
            guard input["sessionToken"] == activeToken else { throw GroqProducerFailure("foreign_synthetic_poll") }
            result = ["state": "complete", "text": reply]
        case "webProviderFinish", "webProviderCancel":
            guard let token = activeToken, input["sessionToken"] == token else { throw GroqProducerFailure("foreign_synthetic_cleanup") }
            observations.finished.append(token); activeToken = nil
            result = ["cleanup": "transcript_cleared"]
        default: throw GroqProducerFailure("unexpected_synthetic_operation")
        }
        if ["ready", "running", "complete"].contains(result["state"] as? String ?? "") {
            // Fixed independently configured synthetic menu, never a reflection of requested fields.
            result["modelEvidence"] = ["selected": ["key": choice.key, "label": choice.label],
                "source": "selected_model_indicator", "verification": "website_selection"]
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

private struct GroqLoaderSelfServiceReport: Codable {
    let firstFourLoaded: Bool; let browserEntryEligibleAfterFirstLoad: Bool; let loaderCallableAfterFirstLoad: Bool
    let browserSchemaShownAfterSecondLoad: Bool; let selfServiceHandoffShown: Bool; let deferredPageToolsWithheld: Bool
    let sends: Int; let closed: Int; let onlyLoaderNativePairs: Int; let nativeRegistryUnchanged: Bool
    let nativeRegistryCount: Int; let providerQualificationClaimed: Bool; let realProviderOrBrowserActions: Int
}

private actor GroqLoaderSelfServiceTransport: WebModelTransport {
    struct Receipt: Sendable {
        var starts: [String] = [], finished: [String] = [], promptSHA256: [String] = []
        var displayPairs: [[GroqProducerPair]] = []
        var sends = 0, onlyLoaderNativePairs = 0
        var firstFourLoaded = false, browserEntryEligibleAfterFirstLoad = false, loaderCallableAfterFirstLoad = false
        var browserSchemaShownAfterSecondLoad = false, selfServiceHandoffShown = false, deferredPageToolsWithheld = false
    }
    private let choice: WebsiteModelChoice, marker: String
    private var state = Receipt(), token: String?, reply = "", revision = "", loader = "", firstNames: [String] = [], open = ""
    init(choice: WebsiteModelChoice, marker: String) { self.choice = choice; self.marker = marker }
    func receipt() -> Receipt { state }
    func request(operation: String, params: Data) async throws -> Data {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        var result: [String: Any]
        switch operation {
        case "webProviderStart":
            guard token == nil, state.starts.count < 3, input["provider"] == "groq",
                  input["modelChoice"].flatMap(WebsiteModelChoice.parse) == choice else { throw GroqProducerFailure("self_service_start") }
            let fresh = UUID().uuidString.lowercased(); token = fresh; state.starts.append(fresh)
            result = ["sessionToken": fresh, "state": "ready"]
        case "webProviderSend":
            guard input["sessionToken"] == token, state.sends < 3, let prompt = input["prompt"] else { throw GroqProducerFailure("self_service_send") }
            let raw = try WebsiteRequestFixture.json(in: prompt)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            guard object["model"] as? String == choice.modelID else { throw GroqProducerFailure("self_service_model") }
            let definitions = try XCTUnwrap(object["tools"] as? [[String: Any]]), tools = GroqProducerFacts.tools(definitions)
            let inventory = try GroqProducerFacts.inventory(prompt), names = try GroqProducerFacts.catalogNames(inventory, tools: tools)
            let current = try XCTUnwrap(inventory["catalog_revision"] as? String)
            func exact(_ local: String) throws -> String {
                let matches = names.filter { $0 == local || $0 == "functions." + local }
                guard matches.count == 1 else { throw GroqProducerFailure("self_service_inventory") }; return matches.first!
            }
            if state.sends == 0 {
                revision = current; loader = try exact(GroqToolCatalog.name); open = try exact("browser_open")
                firstNames = try ["exec_command", "computer_v2_open", "computer_v2_fill", "computer_v2_read_page"].map(exact)
            }
            guard current == revision, tools.contains(where: { $0.qualified == loader }) else { throw GroqProducerFailure("self_service_loader_missing") }
            let items = try XCTUnwrap(object["input"] as? [[String: Any]])
            let calls = items.filter { $0["type"] as? String == "function_call" }, outputs = items.filter { $0["type"] as? String == "function_call_output" }
            guard calls.count == state.sends, outputs.count == calls.count else { throw GroqProducerFailure("self_service_pairs") }
            for (index, pair) in zip(calls, outputs).enumerated() {
                let call = pair.0, output = pair.1
                let name = try XCTUnwrap(call["name"] as? String), namespace = call["namespace"] as? String
                guard (namespace.map { $0 + "." + name } ?? name) == loader,
                      call["call_id"] as? String == output["call_id"] as? String else { throw GroqProducerFailure("self_service_non_loader_call") }
                let args = try XCTUnwrap(call["arguments"] as? String)
                let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any])
                let expected = index == 0 ? firstNames : [open]
                guard Set(arguments.keys) == ["catalog_revision", "names"], arguments["catalog_revision"] as? String == revision,
                      arguments["names"] as? [String] == expected else { throw GroqProducerFailure("self_service_native_arguments") }
                let text = try GroqProducerFacts.outputText(output["output"])
                let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                guard Set(receipt.keys) == ["catalog_revision", "loaded", "available", "execution"],
                      receipt["catalog_revision"] as? String == revision, receipt["loaded"] as? [String] == expected.sorted(),
                      receipt["available"] as? String == "next_request", receipt["execution"] as? Bool == false else {
                    throw GroqProducerFailure("self_service_native_receipt")
                }
            }
            if state.sends == 0 {
                reply = try GroqProducerFacts.call(loader, arguments: ["catalog_revision": revision, "names": firstNames])
            } else if state.sends == 1 {
                let shown = Set(tools.map(\.qualified)), reader = try exact(GroqHistoryTool.name)
                state.firstFourLoaded = shown == Set(firstNames + [loader, reader])
                state.browserEntryEligibleAfterFirstLoad = names.contains(open) && !shown.contains(open)
                state.loaderCallableAfterFirstLoad = shown.contains(loader)
                state.selfServiceHandoffShown = prompt.contains("load needed schemas yourself, not user enablement")
                    && prompt.contains("Webpages use browser_*; computer_v2_* is native-app UI.")
                state.deferredPageToolsWithheld = !names.contains(where: { ["browser_read", "functions.browser_read"].contains($0) })
                guard state.firstFourLoaded, state.browserEntryEligibleAfterFirstLoad, state.loaderCallableAfterFirstLoad,
                      state.selfServiceHandoffShown, state.deferredPageToolsWithheld else { throw GroqProducerFailure("self_service_second_frame") }
                reply = try GroqProducerFacts.call(loader, arguments: ["catalog_revision": revision, "names": [open]])
            } else {
                let shown = Set(tools.map(\.qualified)), reader = try exact(GroqHistoryTool.name)
                let children = definitions.flatMap { $0["type"] as? String == "namespace" ? ($0["tools"] as? [[String: Any]] ?? []) : [$0] }
                let definition = try XCTUnwrap(children.first { $0["name"] as? String == "browser_open" })
                let schema = try XCTUnwrap(definition["parameters"] as? [String: Any]), properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                let requiresURL = (schema["required"] as? [String])?.contains("url") == true
                let urlType = (properties["url"] as? [String: Any])?["type"] as? String
                state.browserSchemaShownAfterSecondLoad = shown == Set([loader, reader, open]) && requiresURL && urlType == "string"
                guard state.browserSchemaShownAfterSecondLoad else { throw GroqProducerFailure("self_service_browser_schema") }
                state.onlyLoaderNativePairs = calls.count
                reply = try GroqProducerFacts.message(marker)
            }
            state.displayPairs.append(try GroqProducerFacts.pairFacts(object))
            state.promptSHA256.append(GroqProducerFacts.hash(Data(prompt.utf8))); state.sends += 1
            result = ["state": "running"]
        case "webProviderPoll":
            guard input["sessionToken"] == token else { throw GroqProducerFailure("self_service_poll") }
            result = ["state": "complete", "text": reply]
        case "webProviderFinish", "webProviderCancel":
            guard let current = token, input["sessionToken"] == current else { throw GroqProducerFailure("self_service_cleanup") }
            state.finished.append(current); token = nil; result = ["cleanup": "transcript_cleared"]
        default: throw GroqProducerFailure("self_service_operation")
        }
        if ["ready", "running", "complete"].contains(result["state"] as? String ?? "") {
            result["modelEvidence"] = ["selected": ["key": choice.key, "label": choice.label], "source": "selected_model_indicator", "verification": "website_selection"]
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

private enum GroqProducerFacts {
    struct Tool { let local: String; let qualified: String }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func tools(_ values: [[String: Any]]) -> [Tool] {
        values.flatMap { value in
            if value["type"] as? String == "namespace", let namespace = value["name"] as? String,
               let children = value["tools"] as? [[String: Any]] {
                return children.compactMap { child in (child["name"] as? String).map { Tool(local: $0, qualified: namespace + "." + $0) } }
            }
            return (value["name"] as? String).map { [Tool(local: $0, qualified: $0)] } ?? []
        }
    }
    /// The current native profile lists only UNLOADED discovery rows; loaded
    /// names are proved independently by the exact current callable schemas.
    /// Legacy three-column discovery may repeat loaded names in its rows.
    static func catalogNames(_ inventory: [String: Any], tools: [Tool]) throws -> Set<String> {
        guard Set(inventory.keys) == ["catalog_revision", "loaded", "inventory"],
              let revision = inventory["catalog_revision"] as? String, revision.utf8.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let loaded = inventory["loaded"] as? [String], loaded.count <= 128,
              !loaded.isEmpty, loaded.allSatisfy({ !$0.isEmpty }), Set(loaded).count == loaded.count,
              let rows = inventory["inventory"] as? [[String]], rows.count <= 128,
              rows.allSatisfy({ (2...3).contains($0.count) && !($0.first ?? "").isEmpty
                  && ["function", "custom"].contains($0.last ?? "") }),
              Set(rows.map(\.count)).count <= 1 else { throw GroqProducerFailure("invalid_discovery_notice") }
        let discovered = rows.compactMap(\.first), schemaNames = tools.map(\.qualified)
        guard Set(discovered).count == discovered.count, Set(schemaNames).count == schemaNames.count,
              Set(loaded) == Set(schemaNames),
              rows.first?.count != 2 || Set(loaded).isDisjoint(with: discovered) else {
            throw GroqProducerFailure("invalid_discovery_notice")
        }
        return Set(discovered).union(loaded)
    }
    static func pairFacts(_ object: [String: Any]) throws -> [GroqProducerPair] {
        let items = try XCTUnwrap(object["input"] as? [[String: Any]])
        let calls = items.filter { $0["type"] as? String == "function_call" }
        let outputs = items.filter { $0["type"] as? String == "function_call_output" }
        guard calls.count == outputs.count, calls.count <= 3,
              !items.contains(where: { ["custom_tool_call", "custom_tool_call_output"].contains($0["type"] as? String ?? "") }) else {
            throw GroqProducerFailure("unexpected_native_pair_shape")
        }
        var seen = Set<String>()
        return try zip(calls, outputs).map { call, output in
            let callID = try XCTUnwrap(call["call_id"] as? String)
            let name = try XCTUnwrap(call["name"] as? String)
            let namespace = call["namespace"] as? String
            let arguments = try XCTUnwrap(call["arguments"] as? String)
            let qualified = namespace.map { $0 + "." + name } ?? name
            guard (1...256).contains(callID.utf8.count),
                  callID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  seen.insert(callID).inserted, output["call_id"] as? String == callID,
                  [GroqToolCatalog.name, "functions." + GroqToolCatalog.name, "computer_v2_status", "functions.computer_v2_status"].contains(qualified),
                  namespace == nil || namespace == "functions" else { throw GroqProducerFailure("native_pair_identity_mismatch") }
            let text = try outputText(output["output"])
            return GroqProducerPair(callID: callID, name: name, namespace: namespace,
                argumentsSHA256: hash(Data(arguments.utf8)), outputType: "function_call_output",
                outputShape: output["output"] is String ? "text" : "input_text_parts",
                outputTextSHA256: hash(Data(text.utf8)),
                callRecordIDPresent: call.keys.contains("id"), outputRecordIDPresent: output.keys.contains("id"))
        }
    }
    static func inventory(_ prompt: String) throws -> [String: Any] {
        let section = try XCTUnwrap(prompt.range(of: "GROQ_NATIVE_TOOL_INVENTORY:\n"))
        let opening = try XCTUnwrap(prompt.range(of: "\n```\n", range: section.upperBound..<prompt.endIndex))
        let closing = try XCTUnwrap(prompt.range(of: "\n```\nEND_GROQ_NATIVE_TOOL_INVENTORY.", range: opening.upperBound..<prompt.endIndex))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt[opening.upperBound..<closing.lowerBound].utf8)) as? [String: Any])
    }
    static func outputText(_ value: Any?) throws -> String {
        if let text = value as? String { return text }
        let parts = try XCTUnwrap(value as? [[String: Any]])
        guard !parts.isEmpty, parts.allSatisfy({ Set($0.keys) == ["type", "text"] && $0["type"] as? String == "input_text" }) else {
            throw GroqProducerFailure("unknown_native_output_shape")
        }
        return try parts.map { try XCTUnwrap($0["text"] as? String) }.joined(separator: "\n")
    }
    static func hostStatus(_ text: String) -> Bool {
        guard text.utf8.count <= 512, let boundary = text.range(of: "\nbrowser_route=computa_builtin. "),
              let permissions = try? JSONSerialization.jsonObject(with: Data(text[..<boundary.lowerBound].utf8)) as? [String: String],
              Set(permissions.keys) == ["accessibility", "screenRecording"],
              permissions.values.allSatisfy({ ["granted", "not-granted"].contains($0) }) else { return false }
        let guidance = text[boundary.upperBound...]
        return guidance.contains("computer_v2_open") && guidance.contains("browser_tabs")
            && guidance.contains("browser_open") && guidance.contains("browser_read") && !text.contains("chrome_connection=")
    }
    static func call(_ name: String, arguments: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls",
            "calls": [["name": name, "arguments": arguments]]]), as: UTF8.self)
    }
    static func message(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "message", "text": text]), as: UTF8.self)
    }
}

@MainActor
private final class GroqProducerAudit {
    let taskID: String
    let marker: String
    var began = false
    var terminal = false
    var status: TaskStatus?
    var approvals = 0
    var threadID: String?
    var threadBindingConsistent = true
    var finalMarkerSeen = false
    var loaderStopMarkerSeen = false
    init(taskID: String, marker: String) { self.taskID = taskID; self.marker = marker }
    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case let .taskThreadBound(id, thread) where id == taskID:
            threadBindingConsistent = threadBindingConsistent && (threadID == nil || threadID == thread)
            if threadID == nil { threadID = thread }
        case let .taskStatusChanged(id, value) where id == taskID:
            status = value
            if value == .running { began = true }
            if began && [.completed, .waiting, .failed].contains(value) { terminal = true }
        case let .timelineEntryAppended(id, entry) where id == taskID && entry.kind == .assistant:
            if entry.assistantPhase == "final_answer" {
                finalMarkerSeen = finalMarkerSeen || entry.body == marker
                loaderStopMarkerSeen = loaderStopMarkerSeen || entry.body == marker + "_LOCAL_LOADER_BUDGET_STOP"
            }
        case let .approvalRequested(request) where request.taskID == taskID: approvals += 1
        case .connectionChanged(.failed): terminal = true
        default: break
        }
    }
}

private struct GroqProducerFailure: LocalizedError {
    let code: String
    init(_ code: String) { self.code = code }
    var errorDescription: String? { code }
}

private struct GroqProducerNoVisualGrounder: VisualGroundingClient {
    func prepare() async throws { throw GroqProducerFailure("unexpected_visual_grounder") }
    func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
        throw GroqProducerFailure("unexpected_visual_grounder")
    }
    func shutdown() async -> [String] { [] }
}
#endif

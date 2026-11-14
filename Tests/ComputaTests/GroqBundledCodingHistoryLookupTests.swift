#if DEBUG
import CoreFoundation
import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Real bundled Core, exec and patch in a private fixture workspace. Only model
/// replies are synthetic; no provider page/account/browser action is involved.
@MainActor
final class GroqBundledCodingHistoryLookupTests: XCTestCase {
    func testPinnedOnRequestProbeMatchesOnlyTheCompleteTrustedPermissionUnit() {
        typealias P = CodingLookupOnRequestTemplateProbe
        let sandbox = "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`. Editing files in other directories requires approval. Network access is restricted."
        func envelope(_ unit: String = P.fullSource, prefix: String? = nil) -> String {
            "<permissions instructions>\n" + (prefix ?? sandbox) + "\n" + unit + "</permissions instructions>"
        }
        func governing(_ text: String) -> [String: Any] {
            ["input": [["role": "developer", "content": [["type": "input_text", "text": text]]]]]
        }
        let literal = envelope()
        let positive = P.inspect(governing(literal))
        XCTAssertTrue(positive.frozenSourceValid)
        XCTAssertTrue(positive.exactWholeTemplatePresent)
        XCTAssertEqual(positive.permissionParts, 1); XCTAssertEqual(positive.knownSandboxPrefixParts, 1)
        XCTAssertEqual(positive.exactWholeTemplateParts, 1); XCTAssertEqual(positive.additionalSuffixParts, 0)
        XCTAssertEqual(positive.ambiguousParts, 0); XCTAssertFalse(positive.countsSaturated)
        let surrounding = "Native surrounding context stays unknown.\n" + envelope(P.fullSource + " The writable root is `/synthetic/root`.\n") + "\nNative tail stays unknown."
        let withSuffix = P.inspect(["instructions": surrounding])
        XCTAssertTrue(withSuffix.exactWholeTemplatePresent); XCTAssertEqual(withSuffix.additionalSuffixParts, 1)
        let changed = P.fullSource.replacingOccurrences(of: "Commands are run", with: "Commands can run")
        let invalid = [governing(P.fullSource), governing(envelope(changed)),
            governing(envelope(String(P.fullSource.dropLast(2)))),
            governing(envelope(prefix: sandbox + " Extra prefix")),
            governing(envelope(prefix: sandbox.replacingOccurrences(of: "restricted", with: "unknown"))),
            governing(literal + literal), governing("<permissions instructions>" + literal),
            governing(literal + "</permissions instructions>"),
            ["input": [["role": "user", "content": literal]]],
            ["input": [["type": "function_call_output", "call_id": "inert", "output": literal]]],
            ["input": [["role": "developer", "content": [["type": "input_text", "text": String(literal.prefix(literal.count / 2))],
                ["type": "input_text", "text": String(literal.suffix(literal.count - literal.count / 2))]]]]]]
        for object in invalid {
            XCTAssertFalse(P.inspect(object).exactWholeTemplatePresent)
            XCTAssertEqual(P.inspect(object).exactWholeTemplateParts, 0)
        }
    }

    func testReviewedCompactProbePinsTheUnitAndPreservesNativePermissionEnvelopeBytes() throws {
        typealias P = CodingLookupOnRequestTemplateProbe
        let sandbox = "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`. Editing files in other directories requires approval. Network access is restricted."
        let before = "<permissions instructions>\n" + sandbox + "\n"
        let suffix = "Unknown native writable-root/context suffix café / cafe\u{301} 🙂 stays exact.\n</permissions instructions>"
        let full = before + P.fullSource + suffix
        let compact = before + GroqNativePermissionPresentation.compactSource + suffix
        func governing(_ text: String) -> [String: Any] {
            ["input": [["role": "developer", "content": [["type": "input_text", "text": text]]]]]
        }
        let native = governing(full), displayed = governing(compact)
        XCTAssertEqual(Data(GroqNativePermissionPresentation.fullSource.utf8), Data(P.fullSource.utf8))
        XCTAssertEqual(CodingLookupTools.hash(Data(GroqNativePermissionPresentation.compactSource.utf8)), P.compactSourceSHA256)
        XCTAssertEqual(Data(GroqNativePermissionPresentation.compactSource.utf8).count, 1915)
        let exact = P.inspectCompact(displayed)
        XCTAssertTrue(exact.frozenSourceValid); XCTAssertTrue(exact.exactWholeTemplatePresent)
        XCTAssertEqual(exact.permissionParts, 1); XCTAssertEqual(exact.knownSandboxPrefixParts, 1)
        XCTAssertEqual(exact.exactWholeTemplateParts, 1); XCTAssertEqual(exact.additionalSuffixParts, 1)
        XCTAssertFalse(exact.countsSaturated); XCTAssertEqual(exact.ambiguousParts, 0)
        XCTAssertEqual(P.inspect(native).exactWholeTemplateParts, 1)
        XCTAssertEqual(P.inspect(displayed).exactWholeTemplateParts, 0)
        XCTAssertTrue(P.envelopeRemainderUnchanged(native: native, presented: displayed))
        let match = try XCTUnwrap(GroqNativePermissionPresentation.replacement(in: [full], enabled: true))
        var actual = Data(full.utf8); actual.replaceSubrange(match.range, with: match.replacementUTF8)
        XCTAssertEqual(actual, Data(compact.utf8))
        XCTAssertNil(GroqNativePermissionPresentation.replacement(in: [full], enabled: false))
        XCTAssertEqual(P.inspect(native).exactWholeTemplateParts, 1, "No native source mutation or permission inference")
        for changed in [compact.replacingOccurrences(of: "Unknown native writable-root", with: "Changed native writable-root"),
                        compact.replacingOccurrences(of: "Network access is restricted.", with: "Network access is enabled.")] {
            XCTAssertTrue(P.inspectCompact(governing(changed)).exactWholeTemplatePresent)
            XCTAssertFalse(P.envelopeRemainderUnchanged(native: native, presented: governing(changed)))
        }
        let changedUnit = compact.replacingOccurrences(of: "Evaluate every command segment", with: "Skip command segments")
        XCTAssertFalse(P.inspectCompact(governing(changedUnit)).exactWholeTemplatePresent)
        let wrongPart: [String: Any] = ["input": [["role": "developer", "content": compact]]]
        XCTAssertFalse(P.envelopeRemainderUnchanged(native: native, presented: wrongPart))
        let duplicated: [String: Any] = ["instructions": compact,
            "input": [["role": "developer", "content": compact]]]
        XCTAssertFalse(P.envelopeRemainderUnchanged(native: native, presented: duplicated))
        let untrusted: [String: Any] = ["input": [["role": "user", "content": compact],
            ["type": "function_call_output", "call_id": "inert", "output": compact]]]
        XCTAssertFalse(P.inspectCompact(untrusted).exactWholeTemplatePresent)
        let encoded = try JSONEncoder().encode(exact)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("writable-root"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(P.compactSourceSHA256))
        let shape = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(shape.values.allSatisfy { $0 is NSNumber })
    }

    func testGroq120BCodesInvoiceAndReadsEarlierNativeOutputThroughPaginatedContext() async throws {
        try await run(WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B"))
    }
    func testGroq27BCodesInvoiceAndReadsEarlierNativeOutputThroughPaginatedContext() async throws {
        try await run(WebsiteModelChoice(provider: "groq", key: "qwen/qwen3.8-27b", label: "Qwen/Qwen3.8-27B"))
    }

    /// Ordinary genuine reader path with native command-only metadata. No
    /// global tool-output setting and no reconstructed/synthetic reader result.
    func testGroqCommandOnlyLimitPreservesGenuineFullHistoryReader() async throws {
        guard ProcessInfo.processInfo.environment["COMPUTA_TEST_GROQ_COMMAND_OUTPUT_POLICY"] == "1" else {
            throw XCTSkip("Explicit opt-in required: COMPUTA_TEST_GROQ_COMMAND_OUTPUT_POLICY=1")
        }
        try await run(WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B"),
            commandOnlyProbe: true)
    }

    /// Genuine native coding-prefix trajectory matching live495's schema/history
    /// pressure. The unchanged human asks for the complete browser workflow;
    /// this inert model stops after coding and claims no browser qualification.
    func testGroq120BFullAccessBaselineFailureBeforePatchWithOmittedLimitAndThreeSchemasFitsNativeBudget() async throws {
        guard ProcessInfo.processInfo.environment["COMPUTA_TEST_GROQ_CODING_LOOKUP"] == "1" else {
            throw XCTSkip("Explicit opt-in required: COMPUTA_TEST_GROQ_CODING_LOOKUP=1")
        }
        let choice = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B")
        let artifact = try ComputaRuntimeArtifact.resolve()
        try GroqCommandPolicyProof.require(artifact: artifact, modelID: choice.modelID)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Standard private temporary storage with the same meaningful fixture
        // hierarchy and195-byte cwd as the actual live case; no filler content.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ComputaNativeInvoiceTests495-" + nonce, isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let workspace = root.appendingPathComponent("work/all-models-20261102/current-workflow-preparation/fixtures/cases/invoice-495-groq-gptoss120b-" + String(nonce.prefix(16)) + "/coding", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, bytes) in GroqInvoiceHistorySeed.files { try bytes.write(to: workspace.appendingPathComponent(name)) }
        XCTAssertEqual(workspace.path.utf8.count, 195)
        let user = """
            In \(workspace.path), fix the invoice aggregation bug in reconcile.py according to its README. Keep the tests, sample data, and reference format unchanged. Run python3 -m unittest -v, then run python3 reconcile.py.

            Use the built-in browser to open http://127.0.0.1:50473/, enter the printed reference, and submit it once. Read the resulting receipt, then close the tab you opened. Use browser tools for the website; do not use terminal HTTP requests or inspect the fixture's control directory, server source, or receipt files.

            Return the test result, the reference, and the receipt shown by the page.
            """
        XCTAssertEqual(user.utf8.count, 780); XCTAssertEqual(user.filter { $0 == "\n" }.count, 4)
        let task = UUID().uuidString.lowercased(), marker = "SYNTHETIC_CODING_PREFIX_ONLY_" + nonce
        let facts = CodingLookupFacts(task: task, choice: choice, user: user, home: home.path, accessMode: .fullAccess)
        let trajectoryFacts = Coding495TrajectoryFacts()
        let transport = Coding495TrajectoryTransport(choice: choice, workspace: workspace.path, marker: marker, facts: facts)
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = choice.modelID
        config.codexHomePath = home.path; config.workspacePath = workspace.path; config.protocolTracePath = nil
        config.groqPreflightObserverForTesting = { context, event in
            facts.observe(context, event)
            trajectoryFacts.observe(context, event, profile: facts.snapshot().profiles.last)
        }
        let runtime = CodexAppServerRuntime(configuration: config, visualGrounder: CodingLookupNoVisual())
        let browser = InertRuntimeBrowser(), audit = CodingLookupAudit(task: task, marker: marker)
        let watcher = Task { for await event in runtime.events() { audit.receive(event) } }
        do {
            await runtime.configureEmbeddedBrowserTools(EmbeddedBrowserToolController(transport: browser))
            await runtime.configureEmbeddedWebModelTransport(WebsiteInferenceFixtureTransport(transport))
            await runtime.setGroqSubmissionIntervalForTesting(.zero)
            let initialTasks = try await runtime.loadTasks(); XCTAssertTrue(initialTasks.isEmpty)
            try await runtime.configureWorkspace(path: workspace.path, forTaskID: task)
            try await runtime.submit(prompt: user, toTaskID: task, modelID: choice.modelID, accessMode: .fullAccess)
            let deadline = ContinuousClock.now + .seconds(180)
            while !audit.terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let shutdown = await runtime.shutdown(); watcher.cancel()
            let result = await transport.receipt(), observed = facts.snapshot(), counts = await browser.counts()
            let report = Coding495TrajectoryReport(requestedAccessMode: AccessMode.fullAccess.rawValue, status: audit.status?.rawValue ?? "none", receipt: result,
                admissions: observed.admitted, rejections: observed.rejections, candidateProfiles: observed.profiles,
                nativeFailureField: trajectoryFacts.snapshot(), codingPrefixOnly: true, providerQualificationClaimed: false,
                realProviderRequests: 0, realBrowserActions: 0)
            var line = Data("groq495TrajectoryFinite=".utf8); line.append(try JSONEncoder().encode(report)); line.append(10)
            try FileHandle.standardOutput.write(contentsOf: line)
            // No expected-failure mask: a genuine local budget rejection must
            // fail this regression before a production fix is considered.
            XCTAssertTrue(audit.terminal); XCTAssertEqual(audit.status, .completed); XCTAssertTrue(audit.finalSeen)
            XCTAssertTrue(shutdown.succeeded); XCTAssertEqual(audit.approvals, 0)
            XCTAssertTrue(observed.issues.isEmpty, observed.issues.joined(separator: ","))
            XCTAssertGreaterThan(observed.permissionPresentationChecks, 0, "Actual native Full Access permission/profile checks must run")
            XCTAssertTrue(result.seedFailed26); XCTAssertTrue(result.patchVerified)
            XCTAssertTrue(result.sixTestsPassed); XCTAssertTrue(result.referenceVerified)
            XCTAssertEqual(result.omittedLimitCommands, 4); XCTAssertTrue(result.threeOptionalSchemasVerified)
            XCTAssertEqual(result.sends, 8); XCTAssertEqual(result.starts.count, result.sends)
            XCTAssertEqual(Set(result.starts), Set(result.finished)); XCTAssertEqual(Set(result.starts).count, result.starts.count)
            XCTAssertEqual(observed.admitted.count, result.sends); XCTAssertTrue(observed.admitted.allSatisfy { $0.units <= 6_000 })
            XCTAssertEqual(counts.created, 0); XCTAssertEqual(counts.observations, 0); XCTAssertEqual(counts.mutations, 0)
            XCTAssertEqual(counts.activations, 0); XCTAssertEqual(counts.humanCloseAttempts, 0); XCTAssertTrue(counts.humanIntact)
            for name in ["README.md", "test_reconcile.py"] { XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent(name)), GroqInvoiceHistorySeed.files[name]) }
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("reconcile.py")), try Coding495TrajectoryPatch.expectedModule())
            if let thread = audit.thread, let turn = observed.turn {
                let cleanup = try WebsiteSessionCleanupStore(directory: home.appendingPathComponent("WebsiteSessionCleanup-v1")).transactionRecords(for: task, turnID: turn)
                let closed = cleanup.filter { $0.outcome == .closed }
                XCTAssertEqual(closed.count, result.sends)
                XCTAssertEqual(Set(closed.compactMap(\.sessionToken)), Set(result.finished.map { $0.lowercased() }))
                XCTAssertTrue(closed.allSatisfy { $0.receiptSaved && $0.threadID == thread && $0.turnID == turn })
                XCTAssertTrue(CodingLookupTools.retire(home: home, thread: thread, model: choice.modelID))
            } else { XCTFail("The genuine native thread/turn must be retained") }
            try FileManager.default.removeItem(at: root)
        } catch {
            _ = await runtime.shutdown(); watcher.cancel()
            for thread in audit.threads { _ = CodingLookupTools.retire(home: home, thread: thread, model: choice.modelID) }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func run(_ choice: WebsiteModelChoice, commandOnlyProbe: Bool = false) async throws {
        guard commandOnlyProbe || ProcessInfo.processInfo.environment["COMPUTA_TEST_GROQ_CODING_LOOKUP"] == "1" else {
            throw XCTSkip("Explicit opt-in required: COMPUTA_TEST_GROQ_CODING_LOOKUP=1")
        }
        let before = try XCTUnwrap(testRun).failureCount
        let artifact = try ComputaRuntimeArtifact.resolve() // Enabled missing artifact is a failure.
        XCTAssertEqual(artifact.manifest.sourceCommit, ComputaRuntimeArtifact.sourceCommit)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GroqCodingLookup-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let workspace = root.appendingPathComponent("Coding", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, bytes) in GroqInvoiceHistorySeed.files { try bytes.write(to: workspace.appendingPathComponent(name)) }
        if commandOnlyProbe {
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("config.toml").path))
            XCTAssertNil(CodexAppServerRuntime.localThreadConfig(for: choice.modelID)["tool_output_token_limit"])
            try GroqCommandPolicyProof.require(artifact: artifact, modelID: choice.modelID)
        }
        let task = UUID().uuidString.lowercased(), marker = "GROQ_CODING_LOOKUP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let user = "Read README.md, reconcile.py and test_reconcile.py. Fix only summarize with the native patch tool. Run python3 -m unittest -v and python3 reconcile.py. Then retrieve the earlier reconcile.py read through computa_read_context, following its pagination references, and finish with \(marker). Do not open a browser, inspect apps, change permissions or perform input."
        let facts = CodingLookupFacts(task: task, choice: choice, user: user, home: home.path)
        let transport = CodingLookupTransport(choice: choice, workspace: workspace.path, marker: marker, facts: facts)
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = choice.modelID
        config.codexHomePath = home.path; config.workspacePath = workspace.path; config.protocolTracePath = nil
        config.groqPreflightObserverForTesting = { facts.observe($0, $1) }
        let runtime = CodexAppServerRuntime(configuration: config, visualGrounder: CodingLookupNoVisual())
        let browser = InertRuntimeBrowser(), audit = CodingLookupAudit(task: task, marker: marker)
        let watcher = Task { for await event in runtime.events() { audit.receive(event) } }
        do {
            await runtime.configureEmbeddedBrowserTools(EmbeddedBrowserToolController(transport: browser))
            await runtime.configureEmbeddedWebModelTransport(WebsiteInferenceFixtureTransport(transport))
            // Explicit fixture pacing; observing alone never changes production pacing.
            await runtime.setGroqSubmissionIntervalForTesting(.zero)
            let tasks = try await runtime.loadTasks(); XCTAssertTrue(tasks.isEmpty)
            try await runtime.configureWorkspace(path: workspace.path, forTaskID: task)
            try await runtime.submit(prompt: user, toTaskID: task, modelID: choice.modelID)
            let deadline = ContinuousClock.now + .seconds(600)
            while !audit.terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(audit.terminal); XCTAssertEqual(audit.status, .completed); XCTAssertTrue(audit.finalSeen)
            XCTAssertEqual(audit.threads.count, 1)
            XCTAssertEqual(audit.approvals, 0)
            let shutdown = await runtime.shutdown(); watcher.cancel(); XCTAssertTrue(shutdown.succeeded)
            let receipt = await transport.receipt(), observed = facts.snapshot(), counts = await browser.counts()
            XCTAssertTrue(observed.issues.isEmpty, observed.issues.joined(separator: ","))
            XCTAssertEqual(observed.permissionPresentationChecks, observed.admitted.reduce(0) { $0 + $1.attempts.count })
            XCTAssertGreaterThan(observed.permissionPresentationChecks, 0)
            XCTAssertTrue(receipt.lookupVerified); XCTAssertGreaterThanOrEqual(receipt.readFragments, 2)
            if commandOnlyProbe {
                XCTAssertEqual(receipt.firstReaderFragmentBytes, 1_024,
                    "The command-only policy must preserve the actual maximum current reader fragment")
            }
            XCTAssertEqual(receipt.codingSteps, 6); XCTAssertLessThanOrEqual(receipt.sends, 20)
            XCTAssertEqual(receipt.starts.count, receipt.sends); XCTAssertEqual(Set(receipt.starts), Set(receipt.finished))
            XCTAssertEqual(Set(receipt.starts).count, receipt.starts.count)
            XCTAssertEqual(observed.admitted.count, receipt.sends)
            XCTAssertTrue(observed.admitted.allSatisfy { $0.units <= 6_000 })
            XCTAssertEqual(counts.created, 0); XCTAssertEqual(counts.mutations, 0); XCTAssertEqual(counts.observations, 0)
            XCTAssertEqual(counts.activations, 0); XCTAssertEqual(counts.humanCloseAttempts, 0); XCTAssertTrue(counts.humanIntact)
            for name in ["README.md", "test_reconcile.py"] {
                XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent(name)), GroqInvoiceHistorySeed.files[name])
            }
            let expected = try CodingLookupTools.expectedModule()
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("reconcile.py")), expected)
            let thread = try XCTUnwrap(audit.thread), turn = try XCTUnwrap(observed.turn)
            XCTAssertEqual(thread, observed.thread)
            let cleanup = try WebsiteSessionCleanupStore(directory: home.appendingPathComponent("WebsiteSessionCleanup-v1"))
                .transactionRecords(for: task, turnID: turn)
            let closed = cleanup.filter { $0.outcome == .closed }
            XCTAssertEqual(closed.count, receipt.sends)
            XCTAssertEqual(Set(closed.map(\.attemptID)).count, receipt.sends)
            XCTAssertEqual(Set(closed.compactMap(\.sessionToken)), Set(receipt.finished.map { $0.lowercased() }))
            XCTAssertTrue(closed.allSatisfy { $0.isValid && $0.receiptSaved && $0.reason == .transcriptCleared && $0.provider == .groq
                && $0.modelID == choice.modelID && $0.threadID == thread && $0.turnID == turn
                && $0.runtimeGeneration == observed.runtimeGeneration })
            let path = home.appendingPathComponent("WebsiteModelEvidence-v1/transactions/" + task + "/" + turn + ".jsonl")
            let rows = try Data(contentsOf: path).split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
            let released = rows.filter { $0["phase"] as? String == "release_verified" }
            XCTAssertEqual(released.count, receipt.sends)
            let releaseAttempts = released.compactMap { $0["cleanupAttemptID"] as? String }
            XCTAssertEqual(Set(releaseAttempts), Set(closed.map(\.attemptID)))
            for row in released {
                let attempt = row["cleanupAttemptID"] as? String, inference = row["inferenceID"] as? String
                XCTAssertEqual(row["transactionMode"] as? String, "explicit_clear_per_inference")
                XCTAssertTrue(closed.contains { $0.attemptID == attempt && $0.inferenceID == inference })
            }
            let retired = CodingLookupTools.retire(home: home, thread: thread, model: choice.modelID)
            XCTAssertTrue(retired)
            guard testRun?.failureCount == before else { throw CodingLookupFailure("fixture_invariant_failure") }
            // Finite summary only; raw tokens, prompts, tool outputs and handles stay in memory.
            let report = CodingLookupReport(model: choice.modelID, sends: receipt.sends, closed: closed.count,
                lookupFragments: receipt.readFragments, retrievedBytes: receipt.retrievedBytes,
                retrievedSHA256: receipt.retrievedSHA256, registryCount: 24, admissions: observed.admitted,
                providerQualificationClaimed: false, realProviderRequests: 0, realBrowserActions: 0,
                candidateProfiles: observed.profiles, profilingIssues: observed.profilingIssues,
                permissionPresentationChecks: observed.permissionPresentationChecks, readerPreviews: observed.readerPreviews)
            var line = Data("groqCodingLookupFinite=".utf8); line.append(try JSONEncoder().encode(report)); line.append(10)
            try FileHandle.standardOutput.write(contentsOf: line)
            if commandOnlyProbe {
                let finite: [String: Any] = ["commandOutputLimit": 1_024, "globalOutputBytes": 10_000, "firstFragmentBytes": try XCTUnwrap(receipt.firstReaderFragmentBytes),
                    "lookupFragments": receipt.readFragments, "retrievedBytes": receipt.retrievedBytes,
                    "retrievedSHA256": receipt.retrievedSHA256, "full15ReaderVerified": true,
                    "providerQualificationClaimed": false]
                var capLine = Data("groqCommandOutputReaderFinite=".utf8)
                capLine.append(try JSONSerialization.data(withJSONObject: finite, options: [.sortedKeys])); capLine.append(10)
                try FileHandle.standardOutput.write(contentsOf: capLine)
            }
            try FileManager.default.removeItem(at: root)
        } catch {
            _ = await runtime.shutdown(); watcher.cancel()
            var threads = audit.threads
            if let thread = facts.snapshot().thread { threads.insert(thread) }
            for thread in threads { _ = CodingLookupTools.retire(home: home, thread: thread, model: choice.modelID) }
            let observed = facts.snapshot(), receipt = await transport.receipt()
            let failure = CodingLookupFailureReport(outcome: "fixture_invariant_failure", issues: observed.issues,
                admissions: observed.admitted, rejections: observed.rejections, syntheticStarts: receipt.starts.count,
                syntheticSends: receipt.sends, syntheticFinishes: receipt.finished.count, completedCodingSteps: receipt.codingSteps,
                transportFailureCodes: receipt.transportFailureCodes,
                transportFailures: receipt.transportFailures,
                readerIdentityDiagnostics: receipt.readerIdentityDiagnostics,
                candidateProfiles: observed.profiles, profilingIssues: observed.profilingIssues,
                permissionPresentationChecks: observed.permissionPresentationChecks, readerPreviews: observed.readerPreviews)
            if let encoded = try? JSONEncoder().encode(failure) {
                var line = Data("groqCodingLookupFailureFinite=".utf8); line.append(encoded); line.append(10)
                try? FileHandle.standardOutput.write(contentsOf: line)
            }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

private struct CodingLookupAdmission: Codable, Sendable { let units: Int; let attempts: [String] }
private struct CodingLookupRejection: Codable, Sendable { let kind: String; let actual: Int?; let maximum: Int?; let reserved: Int? }
private struct CodingLookupFailureReport: Codable {
    let outcome: String; let issues: [String]; let admissions: [CodingLookupAdmission]; let rejections: [CodingLookupRejection]
    let syntheticStarts: Int; let syntheticSends: Int; let syntheticFinishes: Int; let completedCodingSteps: Int
    let transportFailureCodes: [String]
    let transportFailures: [CodingLookupTransportFailure]
    let readerIdentityDiagnostics: [CodingLookupReaderIdentityDiagnostic]
    let candidateProfiles: [CodingLookupCandidateProfile]; let profilingIssues: [String]
    let permissionPresentationChecks: Int
    let readerPreviews: [WebModelServer.GroqHistoryReaderPreviewForTesting]
}
private struct CodingLookupReport: Codable {
    let model: String; let sends: Int; let closed: Int; let lookupFragments: Int
    let retrievedBytes: Int; let retrievedSHA256: String; let registryCount: Int
    let admissions: [CodingLookupAdmission]; let providerQualificationClaimed: Bool
    let realProviderRequests: Int; let realBrowserActions: Int
    let candidateProfiles: [CodingLookupCandidateProfile]; let profilingIssues: [String]
    let permissionPresentationChecks: Int
    let readerPreviews: [WebModelServer.GroqHistoryReaderPreviewForTesting]
}
/// Standalone exact counts of existing slices, NOT additive token attribution.
/// Only finite sizes/hashes/closed tags survive the synchronous callback.
private struct CodingLookupSizedTokens: Codable, Sendable { let utf8Bytes: Int; let tokens: Int }
private struct CodingLookupFieldSizes: Codable, Sendable {
    let position: Int; let kind: String; let field: String; let nativeJSONBytes: Int
    let presentedJSONBytes: Int?; let descriptorObject: Bool
}
private struct CodingLookupDeveloperPart: Codable, Sendable {
    let item: Int; let part: Int; let tag: String
    /// Offsets in the decoded native instruction text, not JSON byte offsets.
    let decodedUTF8Start: Int; let decodedUTF8End: Int
    let utf8Bytes: Int; let tokens: Int; let exactCurrentAppText: Bool
}
private struct CodingLookupOnRequestTemplateProbe: Codable, Sendable {
    let frozenSourceValid: Bool
    let permissionParts: Int; let knownSandboxPrefixParts: Int; let exactWholeTemplateParts: Int
    let additionalSuffixParts: Int; let ambiguousParts: Int; let countsSaturated: Bool
    let exactWholeTemplatePresent: Bool
    // Frozen pinned first-party source, not loaded from disk at test runtime:
    // codex-rs/prompts/templates/permissions/approval_policy/on_request.md
    // SHA25685541a9738741407642b3c39bbe3781fbf8bb42f628d50e562c87738ab192b3a (3661B).
    // permissions_instructions.rs:259-281 retains this whole source via
    // to_string()/join; no template trim variant is accepted by this probe.
    static let fullSource = """
    # Escalation Requests

    Commands are run outside the sandbox if they are approved by the user, or match an existing rule that allows it to run unrestricted. The command string is split into independent command segments at shell control operators, including but not limited to:

    - Pipes: |
    - Logical operators: &&, ||
    - Command separators: ;
    - Subshell boundaries: (...), $(...)

    Each resulting segment is evaluated independently for sandbox restrictions and approval requirements.

    Example:

    git pull | tee output.txt

    This is treated as two command segments:

    ["git", "pull"]

    ["tee", "output.txt"]

    Commands that use more advanced shell features like redirection (>, >>, <), substitutions ($(...), ...), environment variables (FOO=bar), or wildcard patterns (*, ?) will not be evaluated against rules, to limit the scope of what an approved rule allows.

    ## How to request escalation

    IMPORTANT: To request approval to execute a command that will require escalated privileges:

    - Provide the `sandbox_permissions` parameter with the value `"require_escalated"`
    - Include a short question asking the user if they want to allow the action in `justification` parameter. e.g. "Do you want to download and install dependencies for this project?"
    - Optionally suggest a `prefix_rule` - this will be shown to the user with an option to persist the rule approval for future sessions.

    If you run a command that is important to solving the user's query, but it fails because of sandboxing or with a likely sandbox-related network error (for example DNS/host resolution, registry/index access, or dependency download failure), rerun the command with "require_escalated". ALWAYS proceed to use the `justification` parameter - do not message the user before requesting approval for the command.

    ## When to request escalation

    While commands are running inside the sandbox, here are some scenarios that will require escalation outside the sandbox:

    - You need to run a command that writes to a directory that requires it (e.g. running tests that write to /var)
    - You need to run a GUI app (e.g., open/xdg-open/osascript) to open browsers or files.
    - If you run a command that is important to solving the user's query, but it fails because of sandboxing or with a likely sandbox-related network error (for example DNS/host resolution, registry/index access, or dependency download failure), rerun the command with `require_escalated`. ALWAYS proceed to use the `sandbox_permissions` and `justification` parameters. do not message the user before requesting approval for the command.
    - You are about to take a potentially destructive action such as an `rm` or `git reset` that the user did not explicitly ask for.
    - Be judicious with escalating, but if completing the user's request requires it, you should do so - don't try and circumvent approvals by using other tools.

    ## prefix_rule guidance

    When choosing a `prefix_rule`, request one that will allow you to fulfill similar requests from the user in the future without re-requesting escalation. It should be categorical and reasonably scoped to similar capabilities. You should rarely pass the entire command into `prefix_rule`.

    ### Banned prefix_rules\u{20}
    Avoid requesting overly broad prefixes that the user would be ill-advised to approve. For example, do not request ["python3"], ["python", "-"], or other similar prefixes that would allow arbitrary scripting.
    NEVER provide a prefix_rule argument for destructive commands like rm.
    NEVER provide a prefix_rule if your command uses a heredoc or herestring.\u{20}

    ### Examples
    Good examples of prefixes:
    - ["npm", "run", "dev"]
    - ["gh", "pr", "check"]
    - ["cargo", "test"]
    """ + "\n"
    private static let frozenSourceValid = Data(fullSource.utf8).count == 3661
        && CodingLookupTools.hash(Data(fullSource.utf8)) == "85541a9738741407642b3c39bbe3781fbf8bb42f628d50e562c87738ab192b3a"
    // sandbox_text uses template.trim_end() before rendering network_access.
    // append_section then contributes exactly one LF before approval_text.
    private static let sandboxTemplates = [
        "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `danger-full-access`: No filesystem sandboxing - all commands are permitted. Network access is {{ network_access }}.",
        "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`. Editing files in other directories requires approval. Network access is {{ network_access }}.",
        "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `read-only`: The sandbox only permits reading files. Network access is {{ network_access }}."
    ]
    private static let sandboxPrefixes = sandboxTemplates.flatMap { template in
        ["enabled", "restricted"].map { network in
            Data(("\n" + template.replacingOccurrences(of: "{{ network_access }}", with: network) + "\n").utf8)
        }
    }

    // Exact source template presence only, never permission/approval authority.
    // Extra native suffix/context bytes remain unknown, untouched and unreported.
    static let compactSourceSHA256 = "f306874f724edaa783a30df0593f228b6031e78a91c73502e51b6802482cbce2"
    static func inspect(_ object: [String: Any]) -> Self {
        inspect(object, unit: fullSource, valid: frozenSourceValid)
    }
    static func inspectCompact(_ object: [String: Any]) -> Self {
        let unit = GroqNativePermissionPresentation.compactSource
        let valid = Data(unit.utf8).count == 1915 && CodingLookupTools.hash(Data(unit.utf8)) == compactSourceSHA256
        return inspect(object, unit: unit, valid: valid)
    }
    private static func inspect(_ object: [String: Any], unit: String, valid: Bool) -> Self {
        guard valid else { return .init(frozenSourceValid: false, permissionParts: 0,
            knownSandboxPrefixParts: 0, exactWholeTemplateParts: 0, additionalSuffixParts: 0,
            ambiguousParts: 0, countsSaturated: false, exactWholeTemplatePresent: false) }
        var texts = (object["instructions"] as? String).map { [$0] } ?? []
        for item in object["input"] as? [[String: Any]] ?? []
            where (item["type"] == nil || item["type"] as? String == "message")
                && ["system", "developer"].contains(item["role"] as? String ?? "") {
            if let text = item["content"] as? String { texts.append(text) }
            for part in item["content"] as? [[String: Any]] ?? []
                where ["input_text", "text"].contains(part["type"] as? String ?? "") {
                if let text = part["text"] as? String { texts.append(text) }
            }
        }
        guard texts.count <= 128 else { return .init(frozenSourceValid: true, permissionParts: 0,
            knownSandboxPrefixParts: 0, exactWholeTemplateParts: 0, additionalSuffixParts: 0,
            ambiguousParts: 0, countsSaturated: true, exactWholeTemplatePresent: false) }
        let opening = Data("<permissions instructions>".utf8), closing = Data("</permissions instructions>".utf8)
        var permissionParts = 0, knownPrefixes = 0, matches = 0, suffixes = 0, ambiguous = 0
        let template = Data(unit.utf8)
        for text in texts {
            let bytes = Data(text.utf8)
            let start = bytes.range(of: opening), end = bytes.range(of: closing)
            guard start != nil || end != nil else { continue }
            guard let start, let end, start.upperBound <= end.lowerBound,
                  bytes.range(of: opening, in: start.upperBound..<bytes.count) == nil,
                  bytes.range(of: closing, in: end.upperBound..<bytes.count) == nil else {
                ambiguous += 1; continue
            }
            permissionParts += 1
            let body = bytes.subdata(in: start.upperBound..<end.lowerBound)
            guard let prefix = sandboxPrefixes.first(where: { body.starts(with: $0) }) else { continue }
            knownPrefixes += 1
            let afterPrefix = body.subdata(in: prefix.count..<body.count)
            // No substring search/trim: the COMPLETE source unit must start at
            // approval_text's documented position after the sandbox section.
            guard afterPrefix.starts(with: template) else { continue }
            matches += 1
            if afterPrefix.count > template.count { suffixes += 1 }
        }
        return .init(frozenSourceValid: true, permissionParts: permissionParts,
            knownSandboxPrefixParts: knownPrefixes, exactWholeTemplateParts: matches,
            additionalSuffixParts: suffixes, ambiguousParts: ambiguous, countsSaturated: false,
            exactWholeTemplatePresent: matches > 0)
    }
    /// Compare only the permission component's unchanged prefix/suffix. Raw
    /// bytes are local temporaries; neither they nor their hashes enter reports.
    static func envelopeRemainderUnchanged(native: [String: Any], presented: [String: Any]) -> Bool {
        func remainder(_ object: [String: Any], unit: String) -> (String, Data, Data)? {
            var texts: [(String, String)] = []
            if let text = object["instructions"] as? String { texts.append(("root", text)) }
            for (itemIndex, item) in (object["input"] as? [[String: Any]] ?? []).enumerated()
                where (item["type"] == nil || item["type"] as? String == "message")
                    && ["system", "developer"].contains(item["role"] as? String ?? "") {
                if let text = item["content"] as? String { texts.append(("\(itemIndex):content", text)) }
                for (partIndex, part) in (item["content"] as? [[String: Any]] ?? []).enumerated()
                    where ["input_text", "text"].contains(part["type"] as? String ?? "") {
                    if let text = part["text"] as? String { texts.append(("\(itemIndex):part:\(partIndex)", text)) }
                }
            }
            guard texts.count <= 128 else { return nil }
            let opening = Data("<permissions instructions>".utf8), closing = Data("</permissions instructions>".utf8)
            let template = Data(unit.utf8)
            var result: (String, Data, Data)?
            for (location, text) in texts {
                let bytes = Data(text.utf8), start = bytes.range(of: opening), end = bytes.range(of: closing)
                guard start != nil || end != nil else { continue }
                guard result == nil, let start, let end, start.upperBound <= end.lowerBound,
                      bytes.range(of: opening, in: start.upperBound..<bytes.count) == nil,
                      bytes.range(of: closing, in: end.upperBound..<bytes.count) == nil else { return nil }
                let body = bytes.subdata(in: start.upperBound..<end.lowerBound)
                guard let prefix = sandboxPrefixes.first(where: { body.starts(with: $0) }),
                      body.subdata(in: prefix.count..<body.count).starts(with: template) else { return nil }
                let unitStart = start.upperBound + prefix.count, unitEnd = unitStart + template.count
                result = (location, bytes.subdata(in: start.lowerBound..<unitStart), bytes.subdata(in: unitEnd..<end.upperBound))
            }
            return result
        }
        guard let before = remainder(native, unit: fullSource),
              let after = remainder(presented, unit: GroqNativePermissionPresentation.compactSource) else { return false }
        return before.0 == after.0 && before.1 == after.1 && before.2 == after.2
    }
}

private struct CodingLookupPermissionPresentationProof: Sendable {
    let nativeFull: CodingLookupOnRequestTemplateProbe
    let presentedFull: CodingLookupOnRequestTemplateProbe
    let presentedCompact: CodingLookupOnRequestTemplateProbe
    let envelopeRemainderUnchanged: Bool
}

private struct CodingLookupCandidateProfile: Codable, Sendable {
    let inference: Int; let attempt: Int; let directTools: String; let compactLoaderHistory: Bool
    let nativeHTTPBodySHA256: String; let candidatePromptSHA256: String
    let counter: String; let fullBodyTokens: Int; let hasPlan: Bool; let previewOnly: Bool
    let planReplacedFields: Int; let planSavedJSONBytes: Int
    let historyRevision: GroqContextManifestProjector.RevisionDiagnostics?
    let nativeBaseIsCurrent: Bool; let nativePolicyIsCurrent: Bool
    let canonicalSlices: [String: CodingLookupSizedTokens]
    let presentedSlices: [String: CodingLookupSizedTokens]
    let nativeInstructionMarkers: [String: Int]; let presentedInstructionMarkers: [String: Int]
    let nativeDeveloperParts: [CodingLookupDeveloperPart]; let presentedDeveloperParts: [CodingLookupDeveloperPart]
    let nativeOnRequestTemplate: CodingLookupOnRequestTemplateProbe
    let presentedOnRequestTemplate: CodingLookupOnRequestTemplateProbe
    let presentedCompactOnRequestTemplate: CodingLookupOnRequestTemplateProbe
    let permissionEnvelopeRemainderUnchanged: Bool
    let rawFieldSizes: [CodingLookupFieldSizes]
    let productionStatistics: WebsitePromptProjection.Statistics
}
private struct CodingField: Equatable, Sendable {
    let callID: String; let kind: GroqContextJSONLayout.ItemKind; let name: String?
    let namespace: String?; let recordID: String?; let field: GroqContextJSONLayout.PayloadField; let sha: String; let bytes: Int
}
/// Synchronous native callback reducer; no raw canonical body is retained.
private final class CodingLookupFacts: @unchecked Sendable {
    struct Snapshot {
        let issues: [String]; let thread: String?; let turn: String?; let runtimeGeneration: String?
        let admitted: [CodingLookupAdmission]; let rejections: [CodingLookupRejection]
        let profiles: [CodingLookupCandidateProfile]; let profilingIssues: [String]
        let permissionPresentationChecks: Int
        let readerPreviews: [WebModelServer.GroqHistoryReaderPreviewForTesting]
    }
    private let lock = NSLock(), task: String, choice: WebsiteModelChoice, user: String, home: String
    private let accessMode: AccessMode
    private let expectedNativeNames: Set<String>
    private var issues = Set<String>(), context: String?, thread: String?, turn: String?, previousFields: [CodingField] = []
    private var inferenceIDs = Set<UUID>()
    private var runtimeGeneration: String?
    private var canonicalSHA = "", registrySHA: String?, instructionsSHA: String?, messagePrefix: [String] = []
    private var instructionsInitialized = false
    private var currentFields: [CodingField] = [], attempts: [String] = [], candidateSHA = "", admittedSHA = ""
    private var candidateReferenceRevision: String?
    private var admissions: [CodingLookupAdmission] = []
    private var rejections: [CodingLookupRejection] = []
    private var profiles: [CodingLookupCandidateProfile] = [], profilingIssues = Set<String>()
    private var permissionPresentationChecks = 0
    private var readerPreviews: [WebModelServer.GroqHistoryReaderPreviewForTesting] = []
    private var canonicalSlices: [String: CodingLookupSizedTokens] = [:], nativeInstructionMarkers: [String: Int] = [:]
    private var nativeDeveloperParts: [CodingLookupDeveloperPart] = []
    private var nativeOnRequestTemplate = CodingLookupOnRequestTemplateProbe.inspect([:])
    init(task: String, choice: WebsiteModelChoice, user: String, home: String, accessMode: AccessMode = .askEveryTime) {
        self.task = task; self.choice = choice; self.user = user; self.home = home; self.accessMode = accessMode
        expectedNativeNames = Set((ComputerV2ToolContract.referenceSpecs(for: choice.modelID)
            + [ComputerOutcomeToolContract.spec, GroqToolCatalog.specification, GroqHistoryTool.specification]
            + EmbeddedBrowserTools.definitions()).compactMap { $0["name"] as? String })
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(issues: issues.sorted(), thread: thread, turn: turn, runtimeGeneration: runtimeGeneration,
            admitted: admissions, rejections: rejections, profiles: profiles, profilingIssues: profilingIssues.sorted(),
            permissionPresentationChecks: permissionPresentationChecks,
            readerPreviews: readerPreviews)
    }
    func observe(_ c: WebModelServer.GroqPreflightContextForTesting, _ event: WebModelServer.GroqPreflightEventForTesting) {
        lock.lock(); defer { lock.unlock() }
        do {
            let key = [c.taskID, c.threadID, c.turnID, c.runtimeGeneration.uuidString, c.preparationID.uuidString,
                       c.transportGeneration.uuidString, c.modelID].joined(separator: ":")
            guard c.taskID == task, c.modelID == choice.modelID, c.compactToolThread, context == nil || context == key,
                  GroqToolThreadRegistration.contains(codexHome: home, threadID: c.threadID, modelID: choice.modelID),
                  GroqHistoryThreadRegistration.contains(codexHome: home, threadID: c.threadID, modelID: choice.modelID) else { throw CodingLookupFailure("native_context") }
            context = key; thread = c.threadID; turn = c.turnID; runtimeGeneration = c.runtimeGeneration.uuidString.lowercased()
            switch event {
            case .historyReaderPreview(let preview):
                if !inferenceIDs.contains(c.inferenceID) { profilingIssues.insert("reader_preview_inference_unseen") }
                else if readerPreviews.count < 100 { readerPreviews.append(preview) }
                else { profilingIssues.insert("reader_preview_capacity") }
            case .canonical(let bytes):
                guard admissions.count < 20, inferenceIDs.insert(c.inferenceID).inserted else { throw CodingLookupFailure("inference_bound") }
                let layout = try GroqContextJSONLayout.parse(bytes)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                guard object["model"] as? String == choice.modelID else { throw CodingLookupFailure("native_model") }
                let tools = try XCTUnwrap(layout.toolsRange), nativeTools = try CodingLookupTools.names(object["tools"])
                guard nativeTools.count == 24, expectedNativeNames.isSubset(of: Set(nativeTools.map(\.local))),
                      nativeTools.contains(where: { $0.local == "exec_command" }), nativeTools.contains(where: { $0.local == "apply_patch" }),
                      CodingLookupTools.nativeReaderSchemaMatches(object["tools"]) else { throw CodingLookupFailure("full_registry") }
                let toolSHA = CodingLookupTools.hash(try layout.rawBytes(in: tools))
                guard registrySHA == nil || registrySHA == toolSHA else { throw CodingLookupFailure("registry_changed") }; registrySHA = toolSHA
                let policySHA = try layout.instructionsRange.map { CodingLookupTools.hash(try layout.rawBytes(in: $0)) }
                guard !instructionsInitialized || instructionsSHA == policySHA else { throw CodingLookupFailure("policy_changed") }
                instructionsSHA = policySHA; instructionsInitialized = true
                let messages = try layout.items.filter { ["system", "developer", "user"].contains($0.role ?? "") }
                    .map { CodingLookupTools.hash(try layout.rawBytes(in: $0.wholeRange)) }
                guard Array(messages.prefix(messagePrefix.count)) == messagePrefix else { throw CodingLookupFailure("native_message_prefix") }; messagePrefix = messages
                let userParts = CodingLookupTools.userTexts(object)
                guard userParts.filter({ Data($0.utf8) == Data(user.utf8) }).count == 1,
                      userParts.last.map({ Data($0.utf8) }) == Data(user.utf8) else {
                    throw CodingLookupFailure("current_human_part_changed")
                }
                guard !userParts.contains(where: { Data($0.utf8) == Data(ComputaAgentInstructions.runtimeInteractionPolicy().utf8) }) else {
                    throw CodingLookupFailure("duplicate_runtime_policy_user_part")
                }
                // This is the genuine pre-projection native HTTP frame, not a
                // model claim or a compact-policy marker. The fresh bundled
                // fixture registered the current reference/browser contract.
                var nativePolicyTexts = (object["instructions"] as? String).map { [$0] } ?? []
                for item in object["input"] as? [[String: Any]] ?? [] where (item["type"] == nil || item["type"] as? String == "message")
                    && ["system", "developer"].contains(item["role"] as? String ?? "") {
                    if let text = item["content"] as? String { nativePolicyTexts.append(text) }
                    for part in item["content"] as? [[String: Any]] ?? [] where ["input_text", "text"].contains(part["type"] as? String ?? "") {
                        if let text = part["text"] as? String { nativePolicyTexts.append(text) }
                    }
                }
                let currentPolicy = Data(ComputaAgentInstructions.developerInstructions(referenceTools: true, embeddedBrowserTools: true).utf8)
                guard nativePolicyTexts.contains(where: { Data($0.utf8).range(of: currentPolicy) != nil }) else {
                    throw CodingLookupFailure("current_native_policy_missing")
                }
                currentFields = layout.items.compactMap { item in
                    guard let p = item.payload, let call = item.callID else { return nil }
                    return CodingField(callID: call, kind: item.kind, name: item.name, namespace: item.namespace,
                        recordID: item.recordID, field: p.field, sha: CodingLookupTools.hash(p.rawJSON), bytes: p.rawJSON.count)
                }
                guard Array(currentFields.prefix(previousFields.count)) == previousFields else { throw CodingLookupFailure("native_pair_prefix") }
                guard layout.items.filter({ $0.kind == .functionCall || $0.kind == .functionCallOutput }).allSatisfy({ $0.recordID == nil }) else { throw CodingLookupFailure("function_wire_record_ids") }
                previousFields = currentFields; canonicalSHA = CodingLookupTools.hash(bytes); attempts = []; candidateSHA = ""; admittedSHA = ""
                candidateReferenceRevision = nil
                canonicalSlices = [:]; nativeInstructionMarkers = [:]; nativeDeveloperParts = []
                nativeOnRequestTemplate = CodingLookupOnRequestTemplateProbe.inspect(object)
                do {
                    canonicalSlices["whole_http_json"] = try measure(bytes)
                    canonicalSlices["input_json"] = try measure(layout.rawBytes(in: layout.inputRange))
                    canonicalSlices["tools_json"] = try measure(layout.rawBytes(in: tools))
                    if let range = layout.instructionsRange { canonicalSlices["instructions_json"] = try measure(layout.rawBytes(in: range)) }
                    for item in layout.items where ["system", "developer", "user"].contains(item.role ?? "") {
                        canonicalSlices["message_" + String(item.ordinal) + "_" + (item.role ?? "unknown")] = try measure(layout.rawBytes(in: item.wholeRange))
                    }
                    nativeInstructionMarkers = Self.instructionMarkers(object)
                    nativeDeveloperParts = try developerParts(object, known: Self.knownAppInstructionTexts())
                } catch { profilingIssues.insert("canonical_component_profile_unavailable") }
            case .candidate(let request, let directTools, let compactHistory):
                guard attempts.count < GroqNativePublicationLedger.maximumCalls + 4,
                      CodingLookupTools.hash(request.continuationRequest) == canonicalSHA,
                      ["standard", "essential", "loadedOnly"].contains(directTools) else { throw CodingLookupFailure("canonical_changed") }
                attempts.append(directTools); candidateSHA = CodingLookupTools.hash(Data(request.prompt.utf8))
                candidateReferenceRevision = request.groqHistoryPlan?.snapshot.contextRevision
                let permissionProof = try verifyPermissionPresentation(request)
                permissionPresentationChecks += 1
                do {
                    guard profiles.count < 256 else { throw CodingLookupFailure("profile_capacity") }
                    profiles.append(try profile(request, directTools: directTools, compactHistory: compactHistory,
                        permissionProof: permissionProof))
                } catch { profilingIssues.insert((error as? CodingLookupFailure)?.code ?? "candidate_component_profile_unavailable") }
            case .admitted(let units):
                guard !candidateSHA.isEmpty, units <= 6_000 else { throw CodingLookupFailure("admission") }
                admittedSHA = candidateSHA; admissions.append(.init(units: units, attempts: attempts))
            case .rejected(let kind, let actual, let maximum, let reserved):
                rejections.append(.init(kind: kind.rawValue, actual: actual, maximum: maximum, reserved: reserved))
                throw CodingLookupFailure("local_budget_rejection")
            }
        } catch { issues.insert((error as? CodingLookupFailure)?.code ?? "native_observer_shape") }
    }
    private func verifyPermissionPresentation(_ request: WebModelResponseCodec.Request) throws -> CodingLookupPermissionPresentationProof {
        guard request.usesNativeGroqHistoryPresentation, let plan = request.groqHistoryPlan, plan.isCurrent(),
              !request.groqHistoryPreviewOnly,
              let reader = request.groqHistoryReaderName,
              [GroqHistoryTool.name, "functions." + GroqHistoryTool.name].contains(reader),
              request.offeredToolNames.contains(reader),
              plan.snapshot.nativeHTTPSourceSHA256 == canonicalSHA else { throw CodingLookupFailure("permission_native_profile") }
        let native = try XCTUnwrap(JSONSerialization.jsonObject(with: request.continuationRequest) as? [String: Any])
        let displayedBytes = try CodingLookupTools.presentedJSON(request.prompt, model: choice.modelID)
        let displayed = try XCTUnwrap(JSONSerialization.jsonObject(with: displayedBytes) as? [String: Any])
        let full = CodingLookupOnRequestTemplateProbe.inspect(native)
        let old = CodingLookupOnRequestTemplateProbe.inspect(displayed)
        let compact = CodingLookupOnRequestTemplateProbe.inspectCompact(displayed)
        if accessMode == .fullAccess {
            // Separate matching-live variant: assert the REAL native profile and
            // exact unchanged Full Access permission block, not only the API flag.
            func texts(_ object: [String: Any], roles: Set<String>) -> [String] {
                (object["input"] as? [[String: Any]] ?? []).filter { roles.contains($0["role"] as? String ?? "") }.flatMap { item -> [String] in
                    if let text = item["content"] as? String { return [text] }
                    return (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                }
            }
            let expected = "<permissions instructions>\nFilesystem sandboxing defines which files can be read or written. `sandbox_mode` is `danger-full-access`: No filesystem sandboxing - all commands are permitted. Network access is enabled.\nApproval policy is currently never. Do not provide the `sandbox_permissions` for any reason, commands will be rejected.\n</permissions instructions>"
            let nativePermissions = texts(native, roles: ["system", "developer"]).filter { $0.contains("<permissions instructions>") }
            let displayedPermissions = texts(displayed, roles: ["system", "developer"]).filter { $0.contains("<permissions instructions>") }
            let environments = texts(native, roles: ["user"]).filter { $0.hasPrefix("<environment_context>\n") }
            let displayedEnvironments = texts(displayed, roles: ["user"]).filter { $0.hasPrefix("<environment_context>\n") }
            let unchanged = nativePermissions.map { Data($0.utf8) } == displayedPermissions.map { Data($0.utf8) }
                && environments.map { Data($0.utf8) } == displayedEnvironments.map { Data($0.utf8) }
            guard unchanged, nativePermissions.count == 1, displayedPermissions.count == 1,
                  Data(nativePermissions[0].utf8) == Data(expected.utf8),
                  Data(displayedPermissions[0].utf8) == Data(expected.utf8),
                  environments.count == 1, environments[0].contains("<permission_profile type=\"disabled\">"),
                  environments[0].contains("<file_system type=\"unrestricted\" />"),
                  full.exactWholeTemplateParts == 0, compact.exactWholeTemplateParts == 0 else {
                throw CodingLookupFailure("full_access_native_profile")
            }
            return .init(nativeFull: full, presentedFull: old, presentedCompact: compact, envelopeRemainderUnchanged: unchanged)
        }
        func exact(_ probe: CodingLookupOnRequestTemplateProbe) -> Bool {
            probe.frozenSourceValid && probe.permissionParts == 1 && probe.knownSandboxPrefixParts == 1
                && probe.exactWholeTemplatePresent && probe.exactWholeTemplateParts == 1
                && probe.ambiguousParts == 0 && !probe.countsSaturated
        }
        guard exact(full), exact(nativeOnRequestTemplate), exact(compact), old.frozenSourceValid,
              old.permissionParts == 1, old.knownSandboxPrefixParts == 1, old.exactWholeTemplateParts == 0,
              !old.exactWholeTemplatePresent, old.ambiguousParts == 0, !old.countsSaturated,
              full.additionalSuffixParts == compact.additionalSuffixParts else { throw CodingLookupFailure("permission_template_identity") }
        let unchanged = CodingLookupOnRequestTemplateProbe.envelopeRemainderUnchanged(native: native, presented: displayed)
        guard unchanged else { throw CodingLookupFailure("permission_native_remainder_changed") }
        return .init(nativeFull: full, presentedFull: old, presentedCompact: compact, envelopeRemainderUnchanged: unchanged)
    }

    /// Profiling failures stay separate from admission/oracle issues. This
    /// optional diagnostic never changes the prompt, selection, pacing or Send.
    private func measure(_ bytes: Data) throws -> CodingLookupSizedTokens {
        guard let text = String(data: bytes, encoding: .utf8) else { throw CodingLookupFailure("profile_utf8") }
        return try measure(text)
    }
    private func measure(_ text: String) throws -> CodingLookupSizedTokens {
        let count: Int
        if choice.key == "qwen/qwen3.8-27b" { count = try QwenBodyTokenCounter.tokenCount(text) }
        else if choice.key == "openai/gpt-oss-120b" { count = try GroqBodyTokenCounter.tokenCount(text) }
        else { throw CodingLookupFailure("profile_counter_scope") }
        return .init(utf8Bytes: text.utf8.count, tokens: count)
    }
    private func profile(_ request: WebModelResponseCodec.Request, directTools: String,
        compactHistory: Bool, permissionProof: CodingLookupPermissionPresentationProof) throws -> CodingLookupCandidateProfile {
        let json = try CodingLookupTools.presentedJSON(request.prompt, model: choice.modelID)
        let layout = try GroqContextJSONLayout.parse(json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        var slices: [String: CodingLookupSizedTokens] = [:]
        slices["full_prompt"] = try measure(request.prompt)
        slices["runtime_total"] = try measure(request.runtimeInstructions)
        slices["current_user_contract"] = try measure(request.currentUserInstructions)
        slices["body_json"] = try measure(json)
        slices["input_json"] = try measure(layout.rawBytes(in: layout.inputRange))
        if let range = layout.toolsRange { slices["selected_tools_json"] = try measure(layout.rawBytes(in: range)) }
        if let range = layout.instructionsRange { slices["instructions_json"] = try measure(layout.rawBytes(in: range)) }
        for item in layout.items where ["system", "developer", "user"].contains(item.role ?? "") {
            slices["message_" + String(item.ordinal) + "_" + (item.role ?? "unknown")] = try measure(layout.rawBytes(in: item.wholeRange))
        }
        let label = request.prompt.contains("\nGROQ_CONTEXT_MANIFEST_V1:\n")
            ? GroqContextManifestProjector.label : "COMPLETE_RESPONSES_REQUEST_JSON"
        guard let bodyStart = request.prompt.range(of: label + ":\n```\n"),
              let bodyEnd = request.prompt.range(of: "\n```\nEND_" + label + ".\n\n", range: bodyStart.upperBound..<request.prompt.endIndex) else {
            throw CodingLookupFailure("profile_prompt_frame")
        }
        let beforeBody = String(request.prompt[..<bodyStart.lowerBound]), runtimePrefix = request.runtimeInstructions + "\n\n"
        guard beforeBody.hasPrefix(runtimePrefix), beforeBody.hasSuffix("\n") else { throw CodingLookupFailure("profile_runtime_frame") }
        let context = String(beforeBody.dropFirst(runtimePrefix.count).dropLast())
        let afterBody = String(request.prompt[bodyEnd.upperBound...]), userPrefix = request.currentUserInstructions + "\n\n"
        guard afterBody.hasPrefix(userPrefix) else { throw CodingLookupFailure("profile_user_frame") }
        let response = String(afterBody.dropFirst(userPrefix.count))
        guard context.utf8.count == request.promptStatistics.requestContextBytes,
              response.utf8.count == request.promptStatistics.responseContractBytes else { throw CodingLookupFailure("profile_component_length") }
        slices["request_context_contract"] = try measure(context)
        slices["response_contract"] = try measure(response)
        let runtime = request.runtimeInstructions
        if let start = runtime.range(of: "GROQ_NATIVE_TOOL_INVENTORY:\n"),
           let end = runtime.range(of: "END_GROQ_NATIVE_TOOL_INVENTORY.", range: start.upperBound..<runtime.endIndex) {
            let inventory = String(runtime[start.lowerBound..<end.upperBound])
            slices["inventory_block"] = try measure(inventory)
            if let fence = inventory.range(of: "```\n"), let close = inventory.range(of: "\n```", range: fence.upperBound..<inventory.endIndex) {
                slices["inventory_json"] = try measure(String(inventory[fence.upperBound..<close.lowerBound]))
            }
        }
        let sizes = currentFields.enumerated().map { position, field -> CodingLookupFieldSizes in
            let payload = layout.items.first { $0.callID == field.callID && $0.kind == field.kind && $0.payload?.field == field.field }?.payload
            let descriptor = payload.flatMap { try? CodingLookupTools.historyDescriptor($0.rawJSON) }
            return .init(position: position, kind: field.kind.rawValue, field: field.field.rawValue,
                nativeJSONBytes: field.bytes, presentedJSONBytes: payload?.rawJSON.count,
                descriptorObject: descriptor != nil)
        }
        return .init(inference: inferenceIDs.count, attempt: attempts.count, directTools: directTools,
            compactLoaderHistory: compactHistory, nativeHTTPBodySHA256: canonicalSHA, candidatePromptSHA256: candidateSHA,
            counter: choice.key == "qwen/qwen3.8-27b" ? "qwen38_27b" : "o200k_harmony",
            fullBodyTokens: try measure(request.prompt).tokens, hasPlan: request.groqHistoryPlan != nil,
            previewOnly: request.groqHistoryPreviewOnly, planReplacedFields: request.groqHistoryPlan?.replacedFields ?? 0,
            planSavedJSONBytes: request.groqHistoryPlan?.savedJSONBytes ?? 0,
            historyRevision: request.groqHistoryPlan?.revisionDiagnostics,
            nativeBaseIsCurrent: ComputaAgentInstructions.groqNativeBaseIsCurrent,
            nativePolicyIsCurrent: ComputaAgentInstructions.groqNativePolicyIsCurrent,
            canonicalSlices: canonicalSlices, presentedSlices: slices, nativeInstructionMarkers: nativeInstructionMarkers,
            presentedInstructionMarkers: Self.instructionMarkers(object),
            nativeDeveloperParts: nativeDeveloperParts,
            presentedDeveloperParts: try developerParts(object, known: Self.knownAppInstructionTexts(request: request)),
            nativeOnRequestTemplate: permissionProof.nativeFull,
            presentedOnRequestTemplate: permissionProof.presentedFull,
            presentedCompactOnRequestTemplate: permissionProof.presentedCompact,
            permissionEnvelopeRemainderUnchanged: permissionProof.envelopeRemainderUnchanged,
            rawFieldSizes: sizes,
            productionStatistics: request.promptStatistics)
    }
    /// Current app text is matched byte-for-byte against its actual source
    /// generator; a marker alone is never labeled exact app-owned text. This
    /// diagnostic creates no replacement, authority, schema or publication.
    private static func knownAppInstructionTexts(request: WebModelResponseCodec.Request? = nil) -> [(String, Data)] {
        var domains = Set<ComputaAgentInstructions.GroqInstructionDomain>()
        if let request {
            for name in request.offeredToolNames {
                let pieces = name.split(separator: ".").map(String.init)
                guard pieces.count == 1 || (pieces.count == 2 && pieces[0] == "functions"), let local = pieces.last else { continue }
                if !request.customToolNames.contains(name), ["exec_command", "write_stdin"].contains(local) { domains.insert(.terminal) }
                if request.customToolNames.contains(name), local == "apply_patch" { domains.insert(.files) }
                if !request.customToolNames.contains(name), local.hasPrefix("computer_v2_") { domains.insert(.computer) }
            }
            for (index, name) in WebModelResponseCodec.ToolCatalogDiagnostic.browserNames.enumerated()
                where request.toolCatalogDiagnostic.offeredBrowserMask & (UInt16(1) << index) != 0 {
                domains.insert(.browser)
                if ["browser_fill", "browser_click"].contains(name) { domains.insert(.browserInput) }
                else if name == "browser_close" { domains.insert(.browserClose) }
                else { domains.insert(.browserRead) }
            }
        }
        var values: [(String, Data)] = [], seen = Set<Data>()
        func add(_ tag: String, _ text: String) {
            let bytes = Data(text.utf8)
            if !bytes.isEmpty, seen.insert(bytes).inserted { values.append((tag, bytes)) }
        }
        for references in [true, false] {
            let base = ComputaAgentInstructions.groqReviewedNativeBase(referenceTools: references)
            add("known_app_full_base", base)
            if request != nil { add("known_app_compact_base", ComputaAgentInstructions.groqCompactTrustedNativeText(base, domains: domains)) }
            for browser in [true, false] {
                let policy = ComputaAgentInstructions.developerInstructions(referenceTools: references, embeddedBrowserTools: browser)
                add("known_app_full_policy", policy)
                if request != nil { add("known_app_compact_policy", ComputaAgentInstructions.groqCompactTrustedNativeText(policy, domains: domains)) }
            }
        }
        return values.sorted { $0.1.count > $1.1.count }
    }
    /// Closed tags only. Unknown residual content is never printed, hashed or
    /// reconstructed. Counts are standalone and are not additive token totals.
    private func developerParts(_ object: [String: Any], known: [(String, Data)]) throws -> [CodingLookupDeveloperPart] {
        var texts: [(Int, Int, String)] = []
        if let value = object["instructions"] as? String { texts.append((-1, 0, value)) }
        for (index, item) in (object["input"] as? [[String: Any]] ?? []).enumerated()
            where (item["type"] == nil || item["type"] as? String == "message") && ["developer", "system"].contains(item["role"] as? String ?? "") {
            if let value = item["content"] as? String { texts.append((index, 0, value)) }
            for (part, content) in (item["content"] as? [[String: Any]] ?? []).enumerated()
                where ["input_text", "text"].contains(content["type"] as? String ?? "") {
                if let value = content["text"] as? String { texts.append((index, part, value)) }
            }
        }
        let envelopes = [("permissions", "<permissions instructions>", "</permissions instructions>"),
            ("collaboration", "<collaboration_mode>", "</collaboration_mode>"),
            ("persistent", "<persistent_mode>", "</persistent_mode>"),
            ("managed_developer", "<managed_developer_instructions>", "</managed_developer_instructions>"),
            ("execution_environments", "<environments_instructions>", "</environments_instructions>"),
            ("tools", "<tools>", "</tools>"), ("apps", "<apps_instructions>", "</apps_instructions>"),
            ("plugins", "<plugins_instructions>", "</plugins_instructions>"),
            ("multi_agent", "<multi_agent_mode>", "</multi_agent_mode>"),
            ("context_window", "<context_window>", "</context_window>"),
            ("context_guidance", "<context_window_guidance>", "</context_window_guidance>")]
        var result: [CodingLookupDeveloperPart] = []
        for (item, part, text) in texts {
            let bytes = Data(text.utf8)
            var cursor = 0
            while cursor < bytes.count {
                guard result.count < 512 else { throw CodingLookupFailure("developer_profile_capacity") }
                var matches: [(Range<Int>, String, Bool)] = []
                for (tag, pattern) in known {
                    if let range = bytes.range(of: pattern, in: cursor..<bytes.count) { matches.append((range, tag, true)) }
                }
                for (tag, opening, closing) in envelopes {
                    if let start = bytes.range(of: Data(opening.utf8), in: cursor..<bytes.count),
                       let end = bytes.range(of: Data(closing.utf8), in: start.upperBound..<bytes.count) {
                        let range = start.lowerBound..<end.upperBound
                        // Keep an exact app-owned match separately, even if a
                        // native wrapper happens to surround that known text.
                        if !matches.contains(where: { $0.2 && range.overlaps($0.0) }) { matches.append((range, tag, false)) }
                    }
                }
                let next = matches.min { left, right in
                    left.0.lowerBound == right.0.lowerBound ? left.0.count > right.0.count : left.0.lowerBound < right.0.lowerBound
                }
                let end = next?.0.lowerBound ?? bytes.count
                if cursor < end {
                    let raw = bytes.subdata(in: cursor..<end), size = try measure(raw)
                    let tag = raw.allSatisfy { [UInt8(9), 10, 13, 32].contains($0) } ? "whitespace" : "unclassified"
                    result.append(.init(item: item, part: part, tag: tag, decodedUTF8Start: cursor, decodedUTF8End: end,
                        utf8Bytes: size.utf8Bytes, tokens: size.tokens, exactCurrentAppText: false))
                }
                guard let next else { break }
                let size = try measure(bytes.subdata(in: next.0))
                result.append(.init(item: item, part: part, tag: next.1, decodedUTF8Start: next.0.lowerBound,
                    decodedUTF8End: next.0.upperBound, utf8Bytes: size.utf8Bytes, tokens: size.tokens, exactCurrentAppText: next.2))
                cursor = next.0.upperBound
            }
        }
        return result
    }
    private static func instructionMarkers(_ object: [String: Any]) -> [String: Int] {
        var texts = (object["instructions"] as? String).map { [$0] } ?? []
        for item in object["input"] as? [[String: Any]] ?? [] where ["system", "developer"].contains(item["role"] as? String ?? "") {
            if let text = item["content"] as? String { texts.append(text) }
            for part in item["content"] as? [[String: Any]] ?? [] where ["input_text", "text"].contains(part["type"] as? String ?? "") {
                if let text = part["text"] as? String { texts.append(text) }
            }
        }
        let markers = ["COMPUTA_NATIVE_BASE_COMPACT_V1:", "COMPUTA_NATIVE_POLICY_COMPACT_V1:", "COMPUTA_CURRENT_RUNTIME_CONTRACT:"]
        return Dictionary(uniqueKeysWithValues: markers.map { marker in
            (marker, texts.reduce(0) { $0 + $1.components(separatedBy: marker).count - 1 })
        })
    }
    func validatedSend(_ prompt: String) throws -> (fields: [CodingField], referenceRevision: String?) {
        lock.lock(); defer { lock.unlock() }
        guard issues.isEmpty, !admittedSHA.isEmpty, admittedSHA == CodingLookupTools.hash(Data(prompt.utf8)) else { throw CodingLookupFailure("send_not_native_admitted") }
        let bytes = try CodingLookupTools.presentedJSON(prompt, model: choice.modelID)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        guard CodingLookupTools.userTexts(object).filter({ Data($0.utf8) == Data(user.utf8) }).count == 1 else { throw CodingLookupFailure("display_user_missing") }
        admittedSHA = ""; return (currentFields, candidateReferenceRevision)
    }
}

private enum CodingLookupTransportPhase: String, Codable, Sendable {
    case parameters, start, sendScope, validatedSend, displayFrame, displayLayout, displayObject
    case displayValidate, tools, inventory, inventoryHeader, consumePending, consumePendingOutput
    case consumeLoader, consumeCoding, consumeCodingArguments, consumeReader, consumeReaderRange, consumeReaderCursor
    case codingReply, loaderReply, readerReply, readerDescriptor, readerArguments, poll, cleanup, encodeSnapshot
}
private struct CodingLookupTransportFailure: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case codingLookup, layoutUnavailable, xctest, foundation, other }
    let phase: CodingLookupTransportPhase
    let kind: Kind
    let code: String
    let nsErrorDomain: String?
    let nsErrorCode: Int?
}

private struct CodingLookupReaderIdentityDiagnostic: Codable, Sendable {
    let failedKeys: [String]
    // Nil is unavailable, never an invented inequality. These revisions are
    // verification-only; neither is used to form any model/native call.
    let currentRevisionEqualsIssued: Bool?
    let replyEqualsIssued: Bool?
}

private actor CodingLookupTransport: WebModelTransport {
    struct Receipt: Sendable {
        var starts: [String] = [], finished: [String] = []
        var sends = 0, codingSteps = 0, readFragments = 0, retrievedBytes = 0
        var retrievedSHA256 = "", lookupVerified = false
        var firstReaderFragmentBytes: Int?
        var transportFailureCodes: [String] = []
        var transportFailures: [CodingLookupTransportFailure] = []
        var readerIdentityDiagnostics: [CodingLookupReaderIdentityDiagnostic] = []
    }
    private enum Pending { case load(String, String), coding(Int), read(String, issuedRevision: String?) }
    private struct Target {
        let callID: String; let name: String; let rawJSON: Data
    }
    private let choice: WebsiteModelChoice, workspace: String, marker: String, facts: CodingLookupFacts
    private var result = Receipt(), active: String?, reply = "", pending: Pending?, stage = 0
    private var consumed = Set<String>(), target: Target?, lookupVerificationRevision: String?, nextRef: String?
    private var recovered = Data(), usedRefs = Set<String>()
    private var requestPhase = CodingLookupTransportPhase.parameters
    init(choice: WebsiteModelChoice, workspace: String, marker: String, facts: CodingLookupFacts) {
        self.choice = choice; self.workspace = workspace; self.marker = marker; self.facts = facts
    }
    func receipt() -> Receipt { result }
    // Diagnostic tags only: never retain localized errors, prompts or tool text.
    private static let knownTransportFailureCodes: Set<String> = [
        "admission", "ambiguous_display_frame", "canonical_changed", "cleanup_scope",
        "coding_step", "command_not_native_success", "current_human_part_changed", "current_native_policy_missing",
        "descriptor_shape", "developer_profile_capacity", "display_descriptor_not_native_field", "display_field_identity",
        "display_frame_model", "display_history_dropped", "display_model", "display_user_missing",
        "duplicate_runtime_policy_user_part", "fixture_invariant_failure", "full_registry", "function_wire_record_ids",
        "inference_bound", "latest_native_output_not_inline", "loader_not_native_success", "local_budget_rejection",
        "native_context", "native_message_prefix", "native_model", "native_pair_prefix",
        "noncanonical_count", "older_read_not_described", "pagination_ref", "patch_not_native_success",
        "policy_changed", "poll_scope", "profile_capacity", "profile_component_length",
        "profile_counter_scope", "profile_prompt_frame", "profile_runtime_frame", "profile_user_frame",
        "profile_utf8", "read_seed_changed", "reader_identity", "reader_range",
        "reference_mismatch", "registry_changed", "repeated_cursor", "retrieval_not_exact",
        "send_not_native_admitted", "send_scope", "six_tests_not_passed", "start_scope",
        "unexpected_visual", "unfenced_groq_display", "unknown_transport_operation",
    ]
    func request(operation: String, params: Data) async throws -> Data {
        requestPhase = .parameters
        do { return try performRequest(operation: operation, params: params) }
        catch {
            let proposed = (error as? CodingLookupFailure)?.code
            let code = proposed.flatMap { Self.knownTransportFailureCodes.contains($0) ? $0 : nil }
                ?? "other_native_transport_error"
            if result.transportFailureCodes.count < 64 {
                result.transportFailureCodes.append(code)
                result.transportFailures.append(Self.failure(error, phase: requestPhase, code: code))
            }
            throw error
        }
    }
    private static func failure(_ error: Error, phase: CodingLookupTransportPhase,
        code: String) -> CodingLookupTransportFailure {
        if error is CodingLookupFailure {
            return .init(phase: phase, kind: .codingLookup, code: code, nsErrorDomain: nil, nsErrorCode: nil)
        }
        if let layout = error as? GroqContextJSONLayout.Failure, layout == .unavailable {
            return .init(phase: phase, kind: .layoutUnavailable, code: code, nsErrorDomain: nil, nsErrorCode: nil)
        }
        // Type spelling is inspected transiently only. No dynamic type name,
        // description, userInfo, stack, JSON or error text reaches the report.
        let isXCTest = String(reflecting: type(of: error)).hasPrefix("XCTest.")
        let ns = error as NSError
        let domain: String
        switch ns.domain {
        case NSCocoaErrorDomain: domain = "NSCocoaErrorDomain"
        case NSPOSIXErrorDomain: domain = "NSPOSIXErrorDomain"
        case NSURLErrorDomain: domain = "NSURLErrorDomain"
        case "XCTestErrorDomain": domain = "XCTestErrorDomain"
        default: domain = "other"
        }
        let boundedCode = (-1_000_000...1_000_000).contains(ns.code) ? ns.code : nil
        let kind: CodingLookupTransportFailure.Kind = (isXCTest || domain == "XCTestErrorDomain") ? .xctest : (domain == "other" ? .other : .foundation)
        return .init(phase: phase, kind: kind, code: code, nsErrorDomain: domain, nsErrorCode: boundedCode)
    }
    /// Observe individual existing predicates without changing their original
    /// guard or thrown error below. All raw values remain local/transient.
    private func readerIdentityDiagnostic(call: GroqContextJSONLayout.Item, requestedRef: String,
        issuedRevision: String?, currentRevision: String?, text: String) -> CodingLookupReaderIdentityDiagnostic {
        let reply = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let argumentData: Data? = call.payload?.literalUTF8
        let arguments: [String: Any]? = argumentData.flatMap { bytes in
            (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        let expected = lookupVerificationRevision
        let keys: Set<String> = ["context_revision", "ref", "source_call_id", "source_name", "source_kind", "field",
            "value_encoding", "whole_bytes", "whole_sha256", "start_byte", "end_byte", "utf8_fragment", "next_ref",
            "historical_only", "action_authority"]
        let wholeBytes = try? CodingLookupTools.integer(reply?["whole_bytes"])
        let startByte = try? CodingLookupTools.integer(reply?["start_byte"])
        // Cast before actor-isolated short-circuit closures; the parsed Any
        // dictionary remains local to this synchronous diagnostic function.
        let replyRevision = reply?["context_revision"] as? String
        let replySourceID = reply?["source_call_id"] as? String
        let replySourceName = reply?["source_name"] as? String
        let replyWholeSHA = reply?["whole_sha256"] as? String
        let checks: [(String, Bool)] = [
            ("call_name", CodingLookupTools.local(call.name) == "computa_read_context"),
            ("target_present", target != nil),
            ("chain_revision_present", expected != nil),
            ("current_context_revision", expected != nil && currentRevision == expected),
            ("argument_json", arguments != nil),
            ("argument_keys", arguments.map { Set($0.keys) == ["ref"] } ?? false),
            ("argument_ref", arguments?["ref"] as? String == requestedRef),
            ("reply_json", reply != nil),
            ("reply_keys", reply.map { Set($0.keys) == keys } ?? false),
            ("context_revision", expected != nil && replyRevision == expected),
            ("ref", reply?["ref"] as? String == requestedRef),
            ("source_call_id", target != nil && replySourceID == target?.callID),
            ("source_name", target != nil && replySourceName == target?.name),
            ("source_kind", reply?["source_kind"] as? String == "function"),
            ("field", reply?["field"] as? String == "output"),
            ("value_encoding", reply?["value_encoding"] as? String == "json"),
            ("historical_only", CodingLookupTools.boolean(reply?["historical_only"], is: true)),
            ("action_authority", CodingLookupTools.boolean(reply?["action_authority"], is: false)),
            ("whole_bytes", target != nil && wholeBytes == target?.rawJSON.count),
            ("whole_sha256", target.map { replyWholeSHA == CodingLookupTools.hash($0.rawJSON) } ?? false),
            ("start_byte", startByte == recovered.count),
            ("utf8_fragment", reply?["utf8_fragment"] is String),
        ]
        func same(_ first: String?, _ second: String?) -> Bool? {
            guard let first, let second else { return nil }; return first == second
        }
        return .init(failedKeys: checks.filter { !$0.1 }.map { $0.0 },
            currentRevisionEqualsIssued: same(currentRevision, issuedRevision),
            replyEqualsIssued: same(replyRevision, issuedRevision))
    }
    private func performRequest(operation: String, params: Data) throws -> Data {
        let p = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        var snapshot: [String: Any]
        switch operation {
        case "webProviderStart":
            requestPhase = .start
            guard active == nil, result.starts.count < 20, p["provider"] == "groq",
                  p["modelChoice"].flatMap(WebsiteModelChoice.parse) == choice else { throw CodingLookupFailure("start_scope") }
            let token = UUID().uuidString.lowercased(); active = token; result.starts.append(token)
            snapshot = ["sessionToken": token, "state": "ready"]
        case "webProviderSend":
            requestPhase = .sendScope
            guard p["sessionToken"] == active, result.sends < 20, let prompt = p["prompt"] else { throw CodingLookupFailure("send_scope") }
            requestPhase = .validatedSend
            let nativeFields = try facts.validatedSend(prompt)
            requestPhase = .displayFrame
            let json = try CodingLookupTools.presentedJSON(prompt, model: choice.modelID)
            requestPhase = .displayLayout
            let layout = try GroqContextJSONLayout.parse(json)
            requestPhase = .displayObject
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            guard object["model"] as? String == choice.modelID else { throw CodingLookupFailure("display_model") }
            requestPhase = .displayValidate
            try CodingLookupTools.validateDisplay(layout, native: nativeFields.fields, referenceRevision: nativeFields.referenceRevision)
            requestPhase = .tools
            let tools = try CodingLookupTools.names(object["tools"])
            requestPhase = .inventory
            let inventory = try CodingLookupTools.inventory(prompt)
            requestPhase = .inventoryHeader
            let catalogRevision = try XCTUnwrap(inventory["catalog_revision"] as? String)
            let names = (inventory["inventory"] as? [[String]] ?? []).compactMap(\.first)
            if let pending {
                requestPhase = .consumePending
                let calls = layout.items.filter { $0.kind == .functionCall || $0.kind == .customToolCall }
                let fresh = calls.filter { !consumed.contains($0.callID ?? "") }
                guard fresh.count == 1, let call = fresh.first, let id = call.callID,
                      let output = layout.items.first(where: { $0.callID == id && ($0.kind == .functionCallOutput || $0.kind == .customToolCallOutput) }),
                      let payload = output.payload else {
                    throw CodingLookupFailure("latest_native_output_not_inline")
                }
                requestPhase = .consumePendingOutput
                let text = try CodingLookupTools.outputText(payload)
                consumed.insert(id)
                switch pending {
                case .load(let requested, let originalRevision):
                    requestPhase = .consumeLoader
                    guard CodingLookupTools.local(call.name) == GroqToolCatalog.name,
                          let receipt = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          receipt["catalog_revision"] as? String == originalRevision,
                          (receipt["loaded"] as? [String])?.contains(requested) == true,
                          receipt["available"] as? String == "next_request", receipt["execution"] as? Bool == false else {
                        throw CodingLookupFailure("loader_not_native_success")
                    }
                case .coding(let step):
                    requestPhase = .consumeCoding
                    guard step == stage else { throw CodingLookupFailure("coding_step") }
                    if step == 3 {
                        guard call.kind == .customToolCall, CodingLookupTools.local(call.name) == "apply_patch",
                              call.payload?.literalUTF8 == Data(CodingLookupTools.patch(workspace).utf8),
                              text.contains("reconcile.py"), !text.lowercased().contains("failed") else { throw CodingLookupFailure("patch_not_native_success") }
                    } else {
                        requestPhase = .consumeCodingArguments
                        guard call.kind == .functionCall, CodingLookupTools.local(call.name) == "exec_command",
                              let args = call.payload?.literalUTF8,
                              let arguments = try JSONSerialization.jsonObject(with: args) as? [String: Any],
                              arguments["cmd"] as? String == CodingLookupTools.commands[step],
                              arguments["workdir"] as? String == workspace,
                              text.contains("Process exited with code 0") else { throw CodingLookupFailure("command_not_native_success") }
                        if step < 3 {
                            let name = ["README.md", "reconcile.py", "test_reconcile.py"][step]
                            let seed = String(decoding: try XCTUnwrap(GroqInvoiceHistorySeed.files[name]), as: UTF8.self)
                            guard text.contains(seed.hasSuffix("\n") ? String(seed.dropLast()) : seed) else { throw CodingLookupFailure("read_seed_changed") }
                        }
                        if step == 1 { target = Target(callID: id, name: CodingLookupTools.qualified(call), rawJSON: payload.rawJSON) }
                        if step == 4 { guard text.contains("Ran 6 tests"), text.contains("OK") else { throw CodingLookupFailure("six_tests_not_passed") } }
                        if step == 5 { guard text.contains("INV-5DF5A197-600") else { throw CodingLookupFailure("reference_mismatch") } }
                    }
                    stage += 1; result.codingSteps = stage
                case .read(let requestedRef, let issuedRevision):
                    requestPhase = .consumeReader
                    if result.readerIdentityDiagnostics.count < 64 {
                        result.readerIdentityDiagnostics.append(readerIdentityDiagnostic(call: call, requestedRef: requestedRef,
                            issuedRevision: issuedRevision, currentRevision: nativeFields.referenceRevision, text: text))
                    }
                    guard CodingLookupTools.local(call.name) == "computa_read_context", let target, let lookupVerificationRevision,
                          nativeFields.referenceRevision == lookupVerificationRevision,
                          let issuedArguments = call.payload?.literalUTF8,
                          let argumentObject = try JSONSerialization.jsonObject(with: issuedArguments) as? [String: Any],
                          Set(argumentObject.keys) == ["ref"], argumentObject["ref"] as? String == requestedRef,
                          let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          Set(value.keys) == ["context_revision", "ref", "source_call_id", "source_name", "source_kind", "field", "value_encoding", "whole_bytes", "whole_sha256", "start_byte", "end_byte", "utf8_fragment", "next_ref", "historical_only", "action_authority"],
                          value["context_revision"] as? String == lookupVerificationRevision, value["ref"] as? String == requestedRef,
                          value["source_call_id"] as? String == target.callID, value["source_name"] as? String == target.name,
                          value["source_kind"] as? String == "function", value["field"] as? String == "output",
                          value["value_encoding"] as? String == "json", CodingLookupTools.boolean(value["historical_only"], is: true),
                          CodingLookupTools.boolean(value["action_authority"], is: false),
                          try CodingLookupTools.integer(value["whole_bytes"]) == target.rawJSON.count,
                          value["whole_sha256"] as? String == CodingLookupTools.hash(target.rawJSON),
                          try CodingLookupTools.integer(value["start_byte"]) == recovered.count,
                          let fragment = value["utf8_fragment"] as? String else { throw CodingLookupFailure("reader_identity") }
                    requestPhase = .consumeReaderRange
                    let bytes = Data(fragment.utf8), end = try CodingLookupTools.integer(value["end_byte"])
                    guard !bytes.isEmpty, end == recovered.count + bytes.count, end <= target.rawJSON.count else { throw CodingLookupFailure("reader_range") }
                    if result.firstReaderFragmentBytes == nil { result.firstReaderFragmentBytes = bytes.count }
                    recovered.append(bytes); result.readFragments += 1
                    requestPhase = .consumeReaderCursor
                    if let next = value["next_ref"] as? String {
                        guard CodingLookupTools.isCanonicalReference(next), !usedRefs.contains(next), end < target.rawJSON.count else { throw CodingLookupFailure("pagination_ref") }
                        nextRef = next
                    } else {
                        guard value["next_ref"] is NSNull, recovered == target.rawJSON else { throw CodingLookupFailure("retrieval_not_exact") }
                        nextRef = nil; result.lookupVerified = true; result.retrievedBytes = recovered.count
                        result.retrievedSHA256 = CodingLookupTools.hash(recovered)
                    }
                }
                self.pending = nil
            }
            result.sends += 1
            if stage < 6 {
                requestPhase = .codingReply
                let local = stage == 3 ? "apply_patch" : "exec_command"
                let offered = tools.first { $0.local == local }
                if let offered {
                    pending = .coding(stage)
                    reply = stage == 3 ? try CodingLookupTools.call(offered, declaredCustomInput: CodingLookupTools.patch(workspace))
                        : try CodingLookupTools.call(offered.qualified, arguments: ["cmd": CodingLookupTools.commands[stage], "workdir": workspace, "yield_time_ms": 10_000, "max_output_tokens": 6_000])
                } else {
                    requestPhase = .loaderReply
                    let requested = try XCTUnwrap(names.first { CodingLookupTools.local($0) == local })
                    let loader = try XCTUnwrap(tools.first { $0.local == GroqToolCatalog.name })
                    pending = .load(requested, catalogRevision)
                    reply = try CodingLookupTools.call(loader.qualified, arguments: ["catalog_revision": catalogRevision, "names": [requested]])
                }
            } else if result.lookupVerified { reply = try CodingLookupTools.message(marker) }
            else {
                requestPhase = .readerReply
                let reader = try XCTUnwrap(tools.first { $0.local == "computa_read_context" })
                if nextRef == nil {
                    let target = try XCTUnwrap(target)
                    let output = try XCTUnwrap(layout.items.first { $0.callID == target.callID && $0.kind == .functionCallOutput }?.payload)
                    requestPhase = .readerDescriptor
                    let ref = try CodingLookupTools.descriptor(output.rawJSON)
                    guard let internalRevision = nativeFields.referenceRevision,
                          CodingLookupTools.isContextRevision(internalRevision) else { throw CodingLookupFailure("older_read_not_described") }
                    // Full context identity comes ONLY from the actual admitted
                    // native Plan, for verification of every returned chunk.
                    // It is never obtained from display or placed in call args.
                    lookupVerificationRevision = internalRevision; nextRef = ref
                }
                requestPhase = .readerArguments
                let ref = try XCTUnwrap(nextRef)
                guard CodingLookupTools.isCanonicalReference(ref), usedRefs.insert(ref).inserted else { throw CodingLookupFailure("repeated_cursor") }
                pending = .read(ref, issuedRevision: nativeFields.referenceRevision)
                reply = try CodingLookupTools.call(reader.qualified, arguments: ["ref": ref])
            }
            snapshot = ["state": "running"]
        case "webProviderPoll":
            requestPhase = .poll
            guard p["sessionToken"] == active else { throw CodingLookupFailure("poll_scope") }
            snapshot = ["state": "complete", "text": reply]
        case "webProviderFinish", "webProviderCancel":
            requestPhase = .cleanup
            guard let token = active, p["sessionToken"] == token else { throw CodingLookupFailure("cleanup_scope") }
            result.finished.append(token); active = nil; snapshot = ["cleanup": "transcript_cleared"]
        default: throw CodingLookupFailure("unknown_transport_operation")
        }
        if ["ready", "running", "complete"].contains(snapshot["state"] as? String ?? "") {
            snapshot["modelEvidence"] = ["selected": ["key": choice.key, "label": choice.label],
                "source": "selected_model_indicator", "verification": "website_selection"]
        }
        requestPhase = .encodeSnapshot
        return try JSONSerialization.data(withJSONObject: snapshot)
    }
}


private struct Coding495TrajectoryReport: Codable {
    let requestedAccessMode: String
    let status: String
    let receipt: Coding495TrajectoryTransport.Receipt
    let admissions: [CodingLookupAdmission]
    let rejections: [CodingLookupRejection]
    let candidateProfiles: [CodingLookupCandidateProfile]
    let nativeFailureField: Coding495TrajectoryFacts.Snapshot
    let codingPrefixOnly: Bool, providerQualificationClaimed: Bool
    let realProviderRequests: Int, realBrowserActions: Int
}

/// Diagnostics from the existing test-only native preflight observer. This
/// records field identity/representation, never manufactures a ledger fact.
private final class Coding495TrajectoryFacts: @unchecked Sendable {
    struct Candidate: Codable, Sendable {
        let inferenceID: String, promptSHA256: String
        let bodyUnits: Int?, represented: Bool, descriptorObject: Bool
        let descriptorFailedExitCode: Int?
        let presentedJSONBytes: Int?, presentedSHA256: String?
    }
    struct Snapshot: Codable, Sendable {
        let callID: String?, nativeJSONBytes: Int?, nativeSHA256: String?, formattedUTF8Bytes: Int?
        let candidates: [Candidate]
    }
    private let lock = NSLock()
    private var callID: String?, nativeJSONBytes: Int?, nativeSHA256: String?, formattedUTF8Bytes: Int?
    private var candidates: [Candidate] = []
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(callID: callID, nativeJSONBytes: nativeJSONBytes, nativeSHA256: nativeSHA256,
            formattedUTF8Bytes: formattedUTF8Bytes, candidates: candidates)
    }
    func observe(_ context: WebModelServer.GroqPreflightContextForTesting,
        _ event: WebModelServer.GroqPreflightEventForTesting, profile: CodingLookupCandidateProfile?) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .canonical(let raw):
            guard let layout = try? GroqContextJSONLayout.parse(raw) else { return }
            for item in layout.items where item.kind == .functionCallOutput {
                guard let id = item.callID, let payload = item.payload,
                      let text = try? CodingLookupTools.outputText(payload),
                      text.contains("Process exited with code 1"), text.contains("FAILED (failures=26)") else { continue }
                callID = id; nativeJSONBytes = payload.rawJSON.count
                nativeSHA256 = CodingLookupTools.hash(payload.rawJSON); formattedUTF8Bytes = text.utf8.count
            }
        case .candidate(let request, _, _):
            guard let callID, candidates.count < 40,
                  let raw = try? CodingLookupTools.presentedJSON(request.prompt, model: request.model),
                  let layout = try? GroqContextJSONLayout.parse(raw) else { return }
            let payload = layout.items.first { $0.callID == callID && $0.kind == .functionCallOutput }?.payload
            let descriptor = payload.flatMap { try? CodingLookupTools.historyDescriptor($0.rawJSON) }
            let sha = CodingLookupTools.hash(Data(request.prompt.utf8))
            candidates.append(.init(inferenceID: context.inferenceID.uuidString.lowercased(), promptSHA256: sha,
                bodyUnits: profile?.candidatePromptSHA256 == sha ? profile?.fullBodyTokens : nil,
                represented: payload != nil, descriptorObject: descriptor != nil,
                descriptorFailedExitCode: descriptor?.failedExitCode,
                presentedJSONBytes: payload?.rawJSON.count, presentedSHA256: payload.map { CodingLookupTools.hash($0.rawJSON) }))
        default: break
        }
    }
}

/// Only provider replies are synthetic. Every loader/command/patch and its
/// native history/writer/admission is performed by the actual bundled engine.
private actor Coding495TrajectoryTransport: WebModelTransport {
    struct Receipt: Codable, Sendable {
        var starts: [String] = [], finished: [String] = []
        var sends = 0, omittedLimitCommands = 0
        var seedFailed26 = false, patchVerified = false, sixTestsPassed = false, referenceVerified = false
        var threeOptionalSchemasVerified = false
    }
    private enum Pending { case load([String], String), coding(Int) }
    private let choice: WebsiteModelChoice, workspace: String, marker: String, facts: CodingLookupFacts
    private var result = Receipt(), token: String?, reply = "", stage = 0, pending: Pending?
    private var consumed = Set<String>()
    init(choice: WebsiteModelChoice, workspace: String, marker: String, facts: CodingLookupFacts) {
        self.choice = choice; self.workspace = workspace; self.marker = marker; self.facts = facts
    }
    func receipt() -> Receipt { result }
    private func command(_ step: Int) -> String {
        step == 2 ? "sed -n '1,200p' '\(workspace)/reconcile.py'" : step == 6 ? "python3 reconcile.py" : "python3 -m unittest -v"
    }
    func request(operation: String, params: Data) async throws -> Data {
        let p = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        var snapshot: [String: Any]
        switch operation {
        case "webProviderStart":
            guard token == nil, result.starts.count < 12, p["provider"] == "groq",
                  p["modelChoice"].flatMap(WebsiteModelChoice.parse) == choice else { throw CodingLookupFailure("trajectory_start") }
            let id = UUID().uuidString.lowercased(); token = id; result.starts.append(id)
            snapshot = ["sessionToken": id, "state": "ready"]
        case "webProviderSend":
            guard p["sessionToken"] == token, result.sends < 12, let prompt = p["prompt"] else { throw CodingLookupFailure("trajectory_send") }
            let native = try facts.validatedSend(prompt)
            let raw = try CodingLookupTools.presentedJSON(prompt, model: choice.modelID)
            let layout = try GroqContextJSONLayout.parse(raw)
            try CodingLookupTools.validateDisplay(layout, native: native.fields, referenceRevision: native.referenceRevision)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            let tools = try CodingLookupTools.names(object["tools"]), inventory = try CodingLookupTools.inventory(prompt)
            let revision = try XCTUnwrap(inventory["catalog_revision"] as? String)
            let inventoryNames = (inventory["inventory"] as? [[String]] ?? []).compactMap(\.first)
            if let pending {
                let fresh = layout.items.filter { ($0.kind == .functionCall || $0.kind == .customToolCall) && !consumed.contains($0.callID ?? "") }
                guard fresh.count == 1, let call = fresh.first, let id = call.callID,
                      let output = layout.items.first(where: { $0.callID == id && ($0.kind == .functionCallOutput || $0.kind == .customToolCallOutput) })?.payload else {
                    throw CodingLookupFailure("trajectory_latest_output")
                }
                let text = try CodingLookupTools.outputText(output); consumed.insert(id)
                switch pending {
                case let .load(names, originalRevision):
                    guard CodingLookupTools.local(call.name) == GroqToolCatalog.name,
                          let loaded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          loaded["catalog_revision"] as? String == originalRevision,
                          Set(loaded["loaded"] as? [String] ?? []) == Set(names),
                          loaded["available"] as? String == "next_request", loaded["execution"] as? Bool == false else {
                        throw CodingLookupFailure("trajectory_loader")
                    }
                case let .coding(step):
                    guard step == stage else { throw CodingLookupFailure("trajectory_order") }
                    if step == 4 {
                        guard call.kind == .customToolCall, CodingLookupTools.local(call.name) == "apply_patch",
                              call.payload?.literalUTF8 == Data(Coding495TrajectoryPatch.patch(workspace).utf8),
                              text.contains("Success. Updated the following files:"), text.contains(workspace + "/reconcile.py") else {
                            throw CodingLookupFailure("trajectory_patch")
                        }
                        result.patchVerified = true
                    } else {
                        guard call.kind == .functionCall, CodingLookupTools.local(call.name) == "exec_command",
                              let args = call.payload?.literalUTF8,
                              let arguments = try JSONSerialization.jsonObject(with: args) as? [String: Any],
                              Set(arguments.keys) == ["cmd", "workdir"], arguments["cmd"] as? String == command(step),
                              arguments["workdir"] as? String == workspace else { throw CodingLookupFailure("trajectory_arguments") }
                        result.omittedLimitCommands += 1
                        if step == 3 {
                            guard text.contains("Process exited with code 1"), text.contains("Ran 6 tests"),
                                  text.contains("FAILED (failures=26)"), text.contains("Warning: truncated output") else {
                                throw CodingLookupFailure("trajectory_seed_failure")
                            }
                            result.seedFailed26 = true
                        } else {
                            guard text.contains("Process exited with code 0") else { throw CodingLookupFailure("trajectory_exit") }
                            if step == 2 {
                                let seed = String(decoding: try XCTUnwrap(GroqInvoiceHistorySeed.files["reconcile.py"]), as: UTF8.self)
                                guard text.contains(seed.trimmingCharacters(in: .newlines)) else { throw CodingLookupFailure("trajectory_source") }
                            }
                            if step == 5 { guard text.contains("Ran 6 tests"), text.contains("OK") else { throw CodingLookupFailure("trajectory_pass") }; result.sixTestsPassed = true }
                            if step == 6 { guard text.contains("INV-5DF5A197-600") else { throw CodingLookupFailure("trajectory_reference") }; result.referenceVerified = true }
                        }
                    }
                }
                self.pending = nil; stage += 1
            }
            result.sends += 1
            if stage <= 1 {
                let requestedLocal = stage == 0 ? ["browser_open", "browser_fill", "browser_click", "browser_read"] : ["exec_command", "apply_patch", "browser_close"]
                let requested = try requestedLocal.map { local in try XCTUnwrap(inventoryNames.first { CodingLookupTools.local($0) == local }) }
                let loader = try XCTUnwrap(tools.first { $0.local == GroqToolCatalog.name })
                pending = .load(requested, revision)
                reply = try CodingLookupTools.call(loader.qualified, arguments: ["catalog_revision": revision, "names": requested])
            } else if stage <= 6 {
                let optional = Set(tools.map(\.local)).subtracting([GroqToolCatalog.name, GroqHistoryTool.name])
                guard optional == ["exec_command", "apply_patch", "browser_close"] else { throw CodingLookupFailure("trajectory_three_schemas") }
                result.threeOptionalSchemasVerified = true; pending = .coding(stage)
                let tool = try XCTUnwrap(tools.first { $0.local == (stage == 4 ? "apply_patch" : "exec_command") })
                reply = stage == 4 ? try CodingLookupTools.call(tool, declaredCustomInput: Coding495TrajectoryPatch.patch(workspace))
                    : try CodingLookupTools.call(tool.qualified, arguments: ["cmd": command(stage), "workdir": workspace])
            } else {
                reply = try CodingLookupTools.message(marker) // Coding prefix only, not a workflow completion claim.
            }
            snapshot = ["state": "running"]
        case "webProviderPoll":
            guard p["sessionToken"] == token else { throw CodingLookupFailure("trajectory_poll") }
            snapshot = ["state": "complete", "text": reply]
        case "webProviderFinish", "webProviderCancel":
            guard let current = token, p["sessionToken"] == current else { throw CodingLookupFailure("trajectory_cleanup") }
            result.finished.append(current); token = nil; snapshot = ["cleanup": "transcript_cleared"]
        default: throw CodingLookupFailure("trajectory_operation")
        }
        if ["ready", "running", "complete"].contains(snapshot["state"] as? String ?? "") {
            snapshot["modelEvidence"] = ["selected": ["key": choice.key, "label": choice.label], "source": "selected_model_indicator", "verification": "website_selection"]
        }
        return try JSONSerialization.data(withJSONObject: snapshot)
    }
}

private enum Coding495TrajectoryPatch {
    // Exact live custom input SHA8bec4ffe...,1603B. Only its absolute workspace
    // is substituted with an equally long private fixture path.
    private static let template = "*** Begin Patch\n*** Update File: __WORKSPACE__/reconcile.py\n@@\n-def summarize(items):\n-    \"\"\"Aggregate normalized SKUs, quantities, and exact integer-cent subtotals.\"\"\"\n-    grouped = {}\n-    for item in items:\n-        sku = item[\"sku\"].strip().upper()\n-        grouped[sku] = {\n-            \"sku\": sku,\n-            \"quantity\": item[\"quantity\"],\n-            \"subtotal_cents\": item[\"quantity\"] * item[\"unit_cents\"],\n-        }\n-    rows = [grouped[sku] for sku in sorted(grouped)]\n-    return {\"items\": rows, \"total_cents\": sum(row[\"subtotal_cents\"] for row in rows)}\n+def summarize(items):\n+    \"\"\"Aggregate normalized SKUs, quantities, and exact integer-cent subtotals.\n+    This function now correctly accumulates quantities and subtotals for duplicate\n+    SKUs instead of overwriting them.\n+    \"\"\"\n+    grouped = {}\n+    for item in items:\n+        sku = item[\"sku\"].strip().upper()\n+        qty = item[\"quantity\"]\n+        subtotal = qty * item[\"unit_cents\"]\n+        if sku in grouped:\n+            grouped[sku][\"quantity\"] += qty\n+            grouped[sku][\"subtotal_cents\"] += subtotal\n+        else:\n+            grouped[sku] = {\n+                \"sku\": sku,\n+                \"quantity\": qty,\n+                \"subtotal_cents\": subtotal,\n+            }\n+    rows = [grouped[sku] for sku in sorted(grouped)]\n+    return {\"items\": rows, \"total_cents\": sum(row[\"subtotal_cents\"] for row in rows)}\n*** End Patch\n"
    static func patch(_ workspace: String) -> String { template.replacingOccurrences(of: "__WORKSPACE__", with: workspace) }
    static func expectedModule() throws -> Data {
        let (source, range) = try CodingLookupTools.originalModuleAndRange()
        let lines = template.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let removed = lines.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }.joined(separator: "\n")
        let added = lines.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }.joined(separator: "\n")
        guard removed + "\n" == String(source[range]) else { throw CodingLookupFailure("trajectory_patch_scope") }
        return Data(source.replacingCharacters(in: range, with: added + "\n").utf8)
    }
}

private enum CodingLookupTools {
    struct Tool { let local: String; let qualified: String; let definition: [String: Any] }
    static let commands = ["cat README.md", "cat reconcile.py", "cat test_reconcile.py", "", "python3 -m unittest -v", "python3 reconcile.py"]
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func local(_ name: String?) -> String { name?.split(separator: ".").last.map(String.init) ?? "" }
    static func qualified(_ item: GroqContextJSONLayout.Item) -> String {
        let name = item.name ?? ""
        return item.namespace.map { $0 + "." + name } ?? name
    }
    /// Same strict framing walk as WebsiteRequestFixture, with the explicit
    /// new manifest label. Never select a generic code block or repair bytes.
    static func presentedJSON(_ prompt: String, model: String) throws -> Data {
        var selected: Range<String.Index>?
        for label in ["COMPLETE_RESPONSES_REQUEST_JSON", GroqContextManifestProjector.label] {
            let opening = label + ":\n", closing = "\nEND_" + label + "."
            guard let start = prompt.range(of: opening) else { continue }
            guard selected == nil, prompt.range(of: opening, options: .backwards) == start,
                  let end = prompt.range(of: closing, range: start.upperBound..<prompt.endIndex),
                  prompt.range(of: closing, options: .backwards) == end else { throw CodingLookupFailure("ambiguous_display_frame") }
            let frame = start.upperBound..<end.lowerBound
            guard prompt[frame].hasPrefix("```\n"), prompt[frame].hasSuffix("\n```"), prompt[frame].utf8.count >= 8 else {
                throw CodingLookupFailure("unfenced_groq_display")
            }
            selected = prompt.index(frame.lowerBound, offsetBy: 4)..<prompt.index(frame.upperBound, offsetBy: -4)
        }
        let bytes = Data(prompt[try XCTUnwrap(selected)].utf8)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["model"] as? String == model, LocalModelCatalog.webProvider(for: model) == "groq" else {
            throw CodingLookupFailure("display_frame_model")
        }
        return bytes
    }
    static func outputText(_ payload: GroqContextJSONLayout.Payload) throws -> String {
        if let bytes = payload.literalUTF8, let text = String(data: bytes, encoding: .utf8) { return text }
        guard let parts = try JSONSerialization.jsonObject(with: payload.rawJSON) as? [[String: Any]],
              !parts.isEmpty, parts.allSatisfy({ Set($0.keys) == ["type", "text"] && $0["type"] as? String == "input_text" }) else {
            throw CodingLookupFailure("latest_native_output_not_inline")
        }
        return try parts.map { try XCTUnwrap($0["text"] as? String) }.joined(separator: "\n")
    }
    static func names(_ value: Any?) throws -> [Tool] {
        try XCTUnwrap(value as? [[String: Any]]).flatMap { value in
            if value["type"] as? String == "namespace", let namespace = value["name"] as? String, let children = value["tools"] as? [[String: Any]] {
                return children.compactMap { child in (child["name"] as? String).map { Tool(local: local($0), qualified: namespace + "." + $0, definition: child) } }
            }
            return (value["name"] as? String).map { [Tool(local: local($0), qualified: $0, definition: value)] } ?? []
        }
    }
    static func userTexts(_ object: [String: Any]) -> [String] {
        (object["input"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }.flatMap { item -> [String] in
            if let text = item["content"] as? String { return [text] }
            return (item["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }
        }
    }
    static func nativeReaderSchemaMatches(_ value: Any?) -> Bool {
        guard let tools = value as? [[String: Any]] else { return false }
        let definitions = tools.flatMap { ($0["type"] as? String == "namespace" ? $0["tools"] as? [[String: Any]] : nil) ?? [$0] }
        let readers = definitions.filter { local($0["name"] as? String) == GroqHistoryTool.name }
        guard readers.count == 1, let reader = readers.first, reader["description"] as? String == GroqHistoryTool.description,
              let schema = (reader["parameters"] ?? reader["inputSchema"]) as? [String: Any] else { return false }
        guard let properties = schema["properties"] as? [String: Any], Set(properties.keys) == ["ref"],
              schema["required"] as? [String] == ["ref"] else { return false }
        return NSDictionary(dictionary: schema).isEqual(to: GroqHistoryTool.argumentSchema)
    }
    static func inventory(_ prompt: String) throws -> [String: Any] {
        let section = try XCTUnwrap(prompt.range(of: "GROQ_NATIVE_TOOL_INVENTORY:\n"))
        let opening = try XCTUnwrap(prompt.range(of: "\n```\n", range: section.upperBound..<prompt.endIndex))
        let closing = try XCTUnwrap(prompt.range(of: "\n```\nEND_GROQ_NATIVE_TOOL_INVENTORY.", range: opening.upperBound..<prompt.endIndex))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt[opening.upperBound..<closing.lowerBound].utf8)) as? [String: Any])
    }
    static func integer(_ value: Any?) throws -> Int {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue),
              (0...(160 * 1_024)).contains(n.intValue) else { throw CodingLookupFailure("noncanonical_count") }
        return n.intValue
    }
    static func boolean(_ value: Any?, is expected: Bool) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue == expected
    }
    static func isCanonicalReference(_ value: String) -> Bool {
        guard value.utf8.count == 22,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return false }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
        guard let bytes = Data(base64Encoded: padded), bytes.count == 16 else { return false }
        let canonical = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return Data(canonical.utf8) == Data(value.utf8)
    }
    static func isContextRevision(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
    static func historyDescriptor(_ raw: Data) throws -> (reference: String, failedExitCode: Int?) {
        guard let wrapper = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let ref = wrapper["$computa_history"] as? String, isCanonicalReference(ref) else {
            throw CodingLookupFailure("descriptor_shape")
        }
        if Set(wrapper.keys) == ["$computa_history"] { return (ref, nil) }
        guard Set(wrapper.keys) == ["$computa_history", "status", "exit_code", "historical_only", "action_authority"],
              wrapper["status"] as? String == "failed", let exit = wrapper["exit_code"] as? NSNumber,
              CFGetTypeID(exit) != CFBooleanGetTypeID(), exit.doubleValue >= 1,
              exit.doubleValue <= Double(Int32.max), exit.doubleValue == Double(exit.int64Value),
              boolean(wrapper["historical_only"], is: true), boolean(wrapper["action_authority"], is: false) else {
            throw CodingLookupFailure("descriptor_shape")
        }
        return (ref, exit.intValue)
    }
    static func descriptor(_ raw: Data) throws -> String { try historyDescriptor(raw).reference }
    static func validateDisplay(_ layout: GroqContextJSONLayout, native: [CodingField], referenceRevision: String?) throws {
        var references = Set<String>()
        let latest = layout.items.last { $0.kind == .functionCallOutput || $0.kind == .customToolCallOutput }?.callID
        for item in layout.items {
            guard let payload = item.payload, let id = item.callID else { continue }
            guard let original = native.first(where: { $0.callID == id && $0.field == payload.field }),
                  original.kind == item.kind, original.name == item.name, original.namespace == item.namespace,
                  original.recordID == item.recordID else { throw CodingLookupFailure("display_field_identity") }
            if CodingLookupTools.hash(payload.rawJSON) == original.sha { continue }
            let ref = try descriptor(payload.rawJSON)
            guard id != latest, let expected = referenceRevision, isContextRevision(expected),
                  references.insert(ref).inserted else {
                throw CodingLookupFailure("display_descriptor_not_native_field")
            }
        }
        guard layout.items.compactMap({ $0.payload }).count == native.count else { throw CodingLookupFailure("display_history_dropped") }
    }
    static func call(_ name: String, arguments: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [["name": name, "arguments": arguments]]]), as: UTF8.self)
    }
    static func call(_ tool: Tool, declaredCustomInput input: String) throws -> String {
        // The synthetic provider follows the actual current declared schema.
        // The next real native-history read still requires customToolCall and exact patch bytes.
        guard tool.definition["type"] as? String == "function",
              let parameters = tool.definition["parameters"] as? [String: Any],
              parameters["type"] as? String == "object",
              let properties = parameters["properties"] as? [String: Any], Set(properties.keys) == ["input"],
              let property = properties["input"] as? [String: Any], property["type"] as? String == "string",
              parameters["required"] as? [String] == ["input"],
              boolean(parameters["additionalProperties"], is: false) else {
            throw CodingLookupFailure("patch_not_declared_function")
        }
        return try call(tool.qualified, arguments: ["input": input])
    }
    static func message(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "message", "text": text]), as: UTF8.self)
    }
    static let fixedFunction = #"""
def summarize(items):
    """Aggregate normalized SKUs, quantities, and exact integer-cent subtotals."""
    grouped = {}
    for item in items:
        sku = item["sku"].strip().upper()
        row = grouped.setdefault(sku, {"sku": sku, "quantity": 0, "subtotal_cents": 0})
        row["quantity"] += item["quantity"]
        row["subtotal_cents"] += item["quantity"] * item["unit_cents"]
    rows = [grouped[sku] for sku in sorted(grouped)]
    return {"items": rows, "total_cents": sum(row["subtotal_cents"] for row in rows)}
"""#
    static func originalModuleAndRange() throws -> (String, Range<String.Index>) {
        let source = String(decoding: try XCTUnwrap(GroqInvoiceHistorySeed.files["reconcile.py"]), as: UTF8.self)
        let start = try XCTUnwrap(source.range(of: "def summarize(items):"))
        let end = try XCTUnwrap(source.range(of: "\n\ndef reference_for", range: start.upperBound..<source.endIndex))
        return (source, start.lowerBound..<end.lowerBound)
    }
    static func expectedModule() throws -> Data {
        let (source, range) = try originalModuleAndRange()
        return Data(source.replacingCharacters(in: range, with: fixedFunction).utf8)
    }
    static func patch(_ workspace: String) -> String {
        // The seed is fixed source; failure to find its sole function is a test
        // authoring invariant, not an opportunity to widen the patch.
        guard let (source, range) = try? originalModuleAndRange() else { return "INVALID_FIXTURE_PATCH" }
        return "*** Begin Patch\n*** Update File: \(workspace)/reconcile.py\n@@\n"
            + source[range].split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }.joined(separator: "\n") + "\n"
            + fixedFunction.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
            + "\n*** End Patch"
    }
    static func retire(home: URL, thread: String, model: String) -> Bool {
        guard UUID(uuidString: thread) != nil,
              let loader = GroqToolThreadRegistration.marker(codexHome: home.path, threadID: thread, modelID: model),
              let history = GroqHistoryThreadRegistration.marker(codexHome: home.path, threadID: thread, modelID: model) else { return false }
        let defaults = UserDefaults.standard
        for (key, marker) in [(GroqToolThreadRegistration.preferenceKey, loader), (GroqHistoryThreadRegistration.preferenceKey, history),
                              ("ComputaReferenceToolThreads.v1", hash(Data(home.path.utf8)) + ":" + thread)] {
            let old = defaults.stringArray(forKey: key) ?? []
            if old.contains(marker) { defaults.set(old.filter { $0 != marker }, forKey: key) }
        }
        return !(defaults.stringArray(forKey: GroqToolThreadRegistration.preferenceKey) ?? []).contains(loader)
            && !(defaults.stringArray(forKey: GroqHistoryThreadRegistration.preferenceKey) ?? []).contains(history)
            && !(defaults.stringArray(forKey: "ComputaReferenceToolThreads.v1") ?? []).contains(hash(Data(home.path.utf8)) + ":" + thread)
    }
}

@MainActor
private final class CodingLookupAudit {
    let task: String, marker: String
    var thread: String?, threads = Set<String>(), status: TaskStatus?, began = false, terminal = false, finalSeen = false, approvals = 0
    init(task: String, marker: String) { self.task = task; self.marker = marker }
    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case .taskThreadBound(let id, let thread) where id == task:
            threads.insert(thread); if self.thread == nil { self.thread = thread }
        case .taskStatusChanged(let id, let status) where id == task:
            self.status = status; if status == .running { began = true }
            if began && [.completed, .failed, .waiting].contains(status) { terminal = true }
        case .timelineEntryAppended(let id, let entry) where id == task && entry.kind == .assistant:
            if entry.assistantPhase == "final_answer", entry.body == marker { finalSeen = true }
        case .approvalRequested(let request) where request.taskID == task: approvals += 1
        case .connectionChanged(.failed): terminal = true
        default: break
        }
    }
}
private struct CodingLookupFailure: LocalizedError {
    let code: String
    init(_ code: String) { self.code = code }
    var errorDescription: String? { code }
}
private struct CodingLookupNoVisual: VisualGroundingClient {
    func prepare() async throws { throw CodingLookupFailure("unexpected_visual") }
    func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision { throw CodingLookupFailure("unexpected_visual") }
    func shutdown() async -> [String] { [] }
}
#endif

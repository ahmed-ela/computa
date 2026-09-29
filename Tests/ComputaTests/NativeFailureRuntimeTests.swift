import AutomationCore
import Foundation
import XCTest
@testable import Computa

/// Production runtime state machine over deterministic child-process JSON-RPC.
/// The DEBUG-only seam supplies one typed activation failure, not real input.
@MainActor
final class NativeFailureRuntimeTests: XCTestCase {
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"

    private struct NoModelVisualGrounder: VisualGroundingClient {
        func prepare() async throws {}
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw NSError(domain: "NoGroundingInNativeFailureFixture", code: 1)
        }
        func shutdown() async -> [String] { [] }
    }
    func testStopsBeforeReturningFailurePersistsEvidenceAndAllowsNextTurn() async throws {
        try await withHarness { runtime, root, audit in
            try await runtime.submit(prompt: "Synthetic activation failure", toTaskID: "native-failure-task", modelID: self.modelID)
            try await self.waitFor { audit.status == .waiting && !audit.diagnostics.isEmpty }
            XCTAssertEqual(audit.diagnostics.count, 1)
            XCTAssertTrue(audit.diagnostics[0].contains("cause is unknown"))
            XCTAssertTrue(audit.assistant.isEmpty)
            XCTAssertTrue(audit.assistantDeltas.isEmpty, "A stopped native action must not leak unverified claims through streaming.")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("interrupt-order"), encoding: .utf8), "interrupt-first")
            let records = try NativeFailureEvidenceStore(directory: root.appendingPathComponent("heydash-native-failures"))
                .load(threadID: "native-failure-task")
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].callID, "activation-call")
            let reloaded = try await runtime.loadTasks()
            XCTAssertEqual(reloaded.first?.entries.filter { $0.title == "Native action stopped" }.map(\.body), audit.diagnostics)
            try await runtime.submit(prompt: "A new unrelated turn", toTaskID: "native-failure-task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed }
            XCTAssertEqual(audit.assistant, ["NEXT_TURN_OK"])
            XCTAssertTrue(audit.assistantDeltas.isEmpty, "A resumed turn must not accept deltas from the previously stopped turn.")
            let trace = try AppServerWireTrace.load(root.appendingPathComponent("protocol.jsonl"))
            let denial = try XCTUnwrap(trace.messages.first { $0.direction == .clientToServer && $0.identifier == "string:late-tool" })
            XCTAssertNotNil(denial.object["error"])
            let stale = try XCTUnwrap(trace.messages.first { $0.direction == .clientToServer && $0.identifier == "string:stale-tool-after-resume" })
            XCTAssertNotNil(stale.object["error"])
        }
    }

    func testFailedInterruptKeepsTurnBusyAndToolBlocked() async throws {
        try await withHarness(expectedShutdownIssues: [
            "Background command termination unconfirmed: Synthetic interrupt failed"
        ]) { runtime, root, audit in
            try Data("yes".utf8).write(to: root.appendingPathComponent("interrupt-fails"))
            try await runtime.submit(prompt: "Synthetic activation failure", toTaskID: "native-failure-task", modelID: self.modelID)
            try await self.waitFor { audit.stopFailed }
            XCTAssertEqual(audit.status, .running)
            XCTAssertTrue(audit.assistant.isEmpty)
            XCTAssertTrue(audit.assistantDeltas.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("result-received").path))
        }
    }

    func testChromeRecoveryExhaustionStopsRetriesAndPersistsWithoutInventingNavigation() async throws {
        try await withHarness(chromeRecoveryFailure: true) { runtime, root, audit in
            try await runtime.submit(prompt: "Synthetic exhausted Chrome recovery", toTaskID: "native-failure-task", modelID: self.modelID)
            try await self.waitFor { audit.status == .waiting && !audit.diagnostics.isEmpty }
            XCTAssertEqual(audit.diagnostics.count, 1)
            XCTAssertTrue(audit.assistant.isEmpty)
            XCTAssertTrue(audit.assistantDeltas.isEmpty)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("interrupt-order"), encoding: .utf8), "interrupt-first")
            let records = try NativeFailureEvidenceStore(directory: root.appendingPathComponent("heydash-native-failures"))
                .load(threadID: "native-failure-task")
            XCTAssertEqual(records.count, 1)
            let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[0].diagnosticText.utf8)) as? [String: Any])
            XCTAssertEqual((diagnostic["error"] as? [String: String])?["code"], "chrome_navigation_recovery_required")
            XCTAssertEqual(diagnostic["action_outcome"] as? String, "navigation_not_confirmed")
            let reloaded = try await runtime.loadTasks()
            XCTAssertEqual(reloaded.first?.entries.filter { $0.title == "Native action stopped" }.map(\.body), audit.diagnostics)
            try await runtime.submit(prompt: "A new unrelated turn", toTaskID: "native-failure-task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed }
            XCTAssertEqual(audit.assistant, ["NEXT_TURN_OK"])
            XCTAssertTrue(audit.assistantDeltas.isEmpty)
            let trace = try AppServerWireTrace.load(root.appendingPathComponent("protocol.jsonl"))
            let denied = try XCTUnwrap(trace.messages.first { $0.direction == .clientToServer && $0.identifier == "string:late-tool" })
            XCTAssertNotNil(denied.object["error"])
        }
    }

    func testEvidenceWriteFailureStopsWithoutClaimingPersistence() async throws {
        try await withHarness { runtime, root, audit in
            // The store must reject a regular file where its directory belongs.
            let directory = root.appendingPathComponent("heydash-native-failures")
            // loadTasks may already have created this isolated empty directory.
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            try Data("synthetic non-directory".utf8).write(to: directory)
            try await runtime.submit(prompt: "Synthetic activation failure", toTaskID: "native-failure-task", modelID: self.modelID)
            try await self.waitFor { audit.status == .waiting && !audit.diagnostics.isEmpty }
            XCTAssertTrue(audit.diagnostics[0].contains("could not be saved"))
            XCTAssertTrue(audit.assistant.isEmpty)
            XCTAssertTrue(audit.assistantDeltas.isEmpty)
        }
    }

    private final class Audit {
        var status: TaskStatus?
        var diagnostics = [String]()
        var assistant = [String]()
        var assistantDeltas = [String]()
        var stopFailed = false
        func record(_ event: AgentRuntimeEvent) {
            switch event {
            case .assistantMessageDelta(_, _, let delta): assistantDeltas.append(delta)
            case .taskStatusChanged(_, let value): status = value
            case .timelineEntryAppended(_, let entry):
                if entry.title == "Native action stopped" { diagnostics.append(entry.body) }
                if entry.title == "Could not stop native action turn" { stopFailed = true }
                if entry.kind == .assistant { assistant.append(entry.body) }
            default: break
            }
        }
    }

    private func withHarness(chromeRecoveryFailure: Bool = false, expectedShutdownIssues: [String] = [],
                             _ body: (CodexAppServerRuntime, URL, Audit) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaNativeFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NativeFailureAppServer.ts")
        let executable = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.executable = .fixture(path: executable.path)
        config.fixtureActivationFailurePID = 1234
        config.fixtureChromeNavigationRecoveryFailure = chromeRecoveryFailure
        config.model = modelID
        config.codexHomePath = root.path
        config.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
        let runtime = CodexAppServerRuntime(configuration: config, visualGrounder: NoModelVisualGrounder())
        let audit = Audit()
        let events = Task { for await event in runtime.events() { audit.record(event) } }
        _ = try await runtime.loadTasks()
        do {
            try await body(runtime, root, audit)
            let report = await runtime.shutdown()
            events.cancel()
            // A fixture which deliberately refuses interruption must not be
            // reported as successful cleanup. All other cleanup stays strict.
            XCTAssertEqual(report.issues, expectedShutdownIssues)
            XCTAssertEqual(report.succeeded, expectedShutdownIssues.isEmpty)
        } catch {
            _ = await runtime.shutdown()
            events.cancel()
            throw error
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for native terminal evidence")
        throw NSError(domain: "NativeFailureRuntimeTests", code: 1)
    }
}

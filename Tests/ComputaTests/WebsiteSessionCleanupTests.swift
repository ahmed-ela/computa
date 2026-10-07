import Foundation
import XCTest
@testable import Computa

@MainActor
final class WebsiteSessionCleanupTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaCleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAutomaticFailureAndExactManualRetryPersistFiniteOriginalBindingWithoutInferenceReplay() async throws {
        let root = try directory(), task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
        let generation = UUID(), original = CleanupReceiptTransport(failFirstCleanup: true)
        let replacement = CleanupReceiptTransport()
        let server = WebModelServer(), audit = CleanupReceiptAudit()
        await server.configureEmbeddedTransport(original)
        await server.configureCleanupReceipts(directory: root, runtimeGeneration: generation) { await audit.append($0) }
        await server.registerCleanupTurn(taskID: task, threadID: thread, turnID: turn)
        _ = try await server.infer(Data("{\"model\":\"browser/claude\",\"input\":\"Synthetic\",\"tools\":[]}".utf8), taskID: task)
        let initialIssues = await server.finish(taskID: task)
        XCTAssertFalse(initialIssues.isEmpty)
        let lastAutomatic = await audit.last()
        let automatic = try XCTUnwrap(lastAutomatic)
        XCTAssertEqual(automatic.outcome, .unconfirmed); XCTAssertEqual(automatic.trigger, .automatic)
        XCTAssertEqual(automatic.taskID, task.lowercased()); XCTAssertEqual(automatic.threadID, thread.lowercased())
        XCTAssertEqual(automatic.turnID, turn.lowercased()); XCTAssertEqual(automatic.provider, .claude)
        XCTAssertEqual(automatic.route, .embedded); XCTAssertEqual(automatic.modelID, "browser/claude")
        XCTAssertEqual(automatic.runtimeGeneration, generation.uuidString.lowercased()); XCTAssertTrue(automatic.receiptSaved)
        await server.configureEmbeddedTransport(replacement)
        let closed = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
        XCTAssertEqual(closed.outcome, .closed); XCTAssertEqual(closed.reason, .deleted)
        XCTAssertEqual(closed.trigger, .manual); XCTAssertTrue(closed.receiptSaved)
        let absent = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
        XCTAssertEqual(absent.outcome, .noOwnedSession); XCTAssertEqual(absent.reason, .noOwnedSession)
        XCTAssertNil(absent.provider); XCTAssertNil(absent.route); XCTAssertNil(absent.modelID)
        let originalCalls = await original.calls(), replacementCalls = await replacement.calls()
        XCTAssertEqual(originalCalls.map(\.0), ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish", "webProviderCancel"])
        XCTAssertTrue(replacementCalls.isEmpty, "Selector/transport changes cannot retarget old cleanup")
        let originalToken = await original.token()
        XCTAssertEqual(originalCalls.suffix(2).map(\.1), Array(repeating: originalToken, count: 2))
        let file = root.appendingPathComponent(task.lowercased() + ".jsonl")
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains(originalToken)); XCTAssertFalse(raw.contains("PRIVATE_REPLY_CANARY"))
        let records = try raw.split(separator: "\n").map { try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: Data($0.utf8)) }
        XCTAssertEqual(records.map(\.outcome), [.unconfirmed, .closed, .noOwnedSession])
        XCTAssertEqual(WebsiteSessionCleanupStore(directory: root).latest(), [absent])
        _ = await server.shutdown()
    }

    func testDuplicateManualAttemptIsFiniteBusyAndNeverRepeatsDestructiveOperation() async throws {
        let root = try directory(), task = UUID().uuidString, generation = UUID()
        let gate = CleanupReceiptGate(), transport = CleanupReceiptTransport(cleanupGate: gate)
        let server = WebModelServer()
        await server.configureEmbeddedTransport(transport)
        await server.configureCleanupReceipts(directory: root, runtimeGeneration: generation) { _ in }
        _ = try await server.infer(Data("{\"model\":\"browser/claude\",\"input\":\"Synthetic\",\"tools\":[]}".utf8), taskID: task)
        let first = Task { await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation) }
        await gate.waitUntilEntered()
        let duplicate = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
        XCTAssertEqual(duplicate.outcome, .unconfirmed); XCTAssertEqual(duplicate.reason, .busy)
        do { _ = try await server.infer(Data("{\"model\":\"browser/gemini\",\"input\":\"Forbidden\",\"tools\":[]}".utf8), taskID: task); XCTFail("Cleanup must fence inference") }
        catch { XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.busy.localizedDescription) }
        await gate.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult.outcome, .closed)
        let calls = await transport.calls()
        XCTAssertEqual(calls.filter { $0.0 == "webProviderCancel" }.count, 1)
        XCTAssertEqual(calls.filter { $0.0 == "webProviderSend" }.count, 1)
        _ = await server.shutdown()
    }

    func testMissingCurrentOwnerIsNotAClaimOfHistoricalDeletionAndDoesNotCallTransport() async throws {
        let root = try directory(), task = UUID().uuidString, transport = CleanupReceiptTransport()
        let server = WebModelServer()
        await server.configureEmbeddedTransport(transport)
        await server.configureCleanupReceipts(directory: root, runtimeGeneration: UUID()) { _ in }
        let result = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: UUID())
        XCTAssertEqual(result.outcome, .noOwnedSession); XCTAssertEqual(result.reason, .noOwnedSession)
        XCTAssertNil(result.provider); XCTAssertTrue(result.receiptSaved)
        let calls = await transport.calls()
        XCTAssertTrue(calls.isEmpty)
        _ = await server.shutdown()
    }

    func testPrivateStoreRejectsUntrustedFieldsDuplicateAttemptsAndSymlinks() throws {
        let root = try directory(), task = UUID().uuidString
        let receipt = WebsiteSessionCleanupReceipt(taskID: task, runtimeGeneration: UUID(), outcome: .closed,
            provider: .claude, route: .embedded, modelID: "browser/claude", reason: .notCreated, trigger: .automatic, receiptSaved: true)
        let store = WebsiteSessionCleanupStore(directory: root)
        XCTAssertTrue(store.save(receipt)); XCTAssertFalse(store.save(receipt))
        let file = root.appendingPathComponent(task.lowercased() + ".jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        raw["pageText"] = "PRIVATE_REPLY_CANARY"
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        XCTAssertTrue(store.latest().isEmpty); XCTAssertFalse(store.save(receipt))
        try FileManager.default.removeItem(at: file)
        let outside = root.appendingPathComponent("untouched")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertFalse(store.save(receipt)); XCTAssertTrue(store.latest().isEmpty)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }

    func testReceiptValidationRejectsForgedSuccessAndProviderIdentityDrift() throws {
        let valid = WebsiteSessionCleanupReceipt(taskID: UUID().uuidString, threadID: UUID().uuidString, turnID: UUID().uuidString,
            runtimeGeneration: UUID(), outcome: .closed, provider: .claude, route: .embedded, modelID: "browser/claude",
            reason: .deleted, trigger: .manual, receiptSaved: true)
        XCTAssertTrue(valid.isValid)
        for mutation in [["modelID": "browser/gemini"], ["reason": "cleanup_unverified"], ["outcome": "no_owned_session"], ["threadID": "invalid"], ["turnID": "invalid"], ["taskID": "invalid"]] {
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
            mutation.forEach { raw[$0.key] = $0.value }
            let forged = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: raw))
            XCTAssertFalse(forged.isValid)
        }
    }
}

private actor CleanupReceiptAudit {
    private var receipts: [WebsiteSessionCleanupReceipt] = []
    func append(_ receipt: WebsiteSessionCleanupReceipt) { receipts.append(receipt) }
    func last() -> WebsiteSessionCleanupReceipt? { receipts.last }
}

/// The actual bundled engine plus deterministic website transport. Cleanup
/// recovery must not issue another turn, model prompt, tool call or engine start.
@MainActor
final class WebsiteSessionCleanupRuntimeTests: XCTestCase {
    func testFailedTurnAutomaticReceiptThenLiveReloadAndClaimedRecoveryNeverReplayInference() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ComputaCleanupRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var configuration = CodexAppServerRuntime.Configuration.externalLocalQwen
        configuration.executable = .bundled; configuration.model = "browser/claude"
        configuration.codexHomePath = root.appendingPathComponent("PrivateHome").path
        configuration.workspacePath = root.appendingPathComponent("Workspace").path
        let trace = root.appendingPathComponent("protocol.jsonl")
        configuration.protocolTracePath = trace.path
        let runtime = CodexAppServerRuntime(configuration: configuration)
        let gate = CleanupReceiptGate(), transport = CleanupReceiptTransport(failFirstCleanup: true, cleanupGate: gate, malformedReply: true)
        let taskID = UUID().uuidString, audit = CleanupRuntimeAudit(taskID: taskID)
        let observer = Task { for await event in runtime.events() { audit.receive(event) } }
        defer { observer.cancel() }
        do {
            await runtime.configureEmbeddedWebModelTransport(transport)
            _ = try await runtime.loadTasks()
            try await runtime.submit(prompt: "Return the isolated fixture response. Do not use tools.", toTaskID: taskID, modelID: "browser/claude")
            let deadline = ContinuousClock.now + .seconds(45)
            while audit.status != .waiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .waiting)
            let automatic = try XCTUnwrap(audit.receipts.last(where: { $0.trigger == .automatic }))
            XCTAssertEqual(automatic.outcome, .unconfirmed); XCTAssertTrue(automatic.receiptSaved)
            XCTAssertNotNil(automatic.threadID); XCTAssertNotNil(automatic.turnID)
            let reloaded = try await runtime.loadTasks()
            XCTAssertEqual(reloaded.first?.id, taskID, "In-process history reload must preserve the exact private task owner")
            let manual = Task { await runtime.retryWebsiteSessionCleanup(taskID: taskID) }
            await gate.waitUntilEntered()
            let duplicate = await runtime.retryWebsiteSessionCleanup(taskID: taskID)
            XCTAssertEqual(duplicate.reason, .busy)
            do { try await runtime.submit(prompt: "Must not dispatch", toTaskID: automatic.threadID!, modelID: "browser/gemini"); XCTFail("A live persisted-thread alias cannot bypass cleanup claim") }
            catch { XCTAssertTrue(error.localizedDescription.contains("website session cleanup")) }
            do { try await runtime.compact(taskID: taskID); XCTFail("Compaction cannot race cleanup") }
            catch { XCTAssertTrue(error.localizedDescription.contains("current turn")) }
            let stopping = Task { await runtime.shutdown() }
            await runtime.waitForWebsiteSessionShutdownForFixture()
            let refused = await runtime.retryWebsiteSessionCleanup(taskID: taskID)
            XCTAssertEqual(refused.reason, .shuttingDown)
            await gate.release()
            let closed = await manual.value
            XCTAssertEqual(closed.outcome, .closed); XCTAssertTrue(closed.receiptSaved)
            XCTAssertEqual(closed.provider, .claude); XCTAssertEqual(closed.modelID, "browser/claude")
            XCTAssertEqual(closed.threadID, automatic.threadID); XCTAssertEqual(closed.turnID, automatic.turnID)
            _ = await stopping.value
            let calls = await transport.calls()
            XCTAssertEqual(calls.filter { $0.0 == "webProviderStart" }.count, 1)
            XCTAssertEqual(calls.filter { $0.0 == "webProviderSend" }.count, 1)
            XCTAssertEqual(calls.filter { ["webProviderCancel", "webProviderFinish"].contains($0.0) }.count, 2)
            let wire = try AppServerWireTrace.load(trace)
            XCTAssertEqual(wire.messages.filter { $0.method == "turn/start" && $0.direction == .clientToServer }.count, 1)
            XCTAssertTrue(wire.messages.filter { $0.method == "item/tool/call" }.isEmpty)
            let store = WebsiteSessionCleanupStore(directory: URL(fileURLWithPath: configuration.codexHomePath).appendingPathComponent("WebsiteSessionCleanup-v1"))
            let latest = try XCTUnwrap(store.latest().last)
            XCTAssertEqual(latest.runtimeGeneration, automatic.runtimeGeneration)
            let saved = try String(contentsOf: store.directory.appendingPathComponent(taskID.lowercased() + ".jsonl"), encoding: .utf8)
            let records = try saved.split(separator: "\n").map { try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: Data($0.utf8)) }
            XCTAssertTrue(records.contains(closed), "A later current-absence observation cannot erase the causal manual closure receipt")
        } catch { _ = await runtime.shutdown(); throw error }
    }
}

@MainActor
private final class CleanupRuntimeAudit {
    let taskID: String
    var status: TaskStatus?
    var receipts: [WebsiteSessionCleanupReceipt] = []
    init(taskID: String) { self.taskID = taskID }
    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case .taskStatusChanged(let task, let value) where task == taskID: status = value
        case .websiteSessionCleanupUpdated(let receipt): receipts.append(receipt)
        default: break
        }
    }
}

private actor CleanupReceiptGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; enteredWaiter?.resume(); enteredWaiter = nil; await withCheckedContinuation { releaseWaiter = $0 } }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { enteredWaiter = $0 } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor CleanupReceiptTransport: WebModelTransport {
    private let ownedToken = UUID().uuidString
    private var operations: [(String, String)] = []
    private var failFirstCleanup: Bool
    private let cleanupGate: CleanupReceiptGate?
    private let malformedReply: Bool
    init(failFirstCleanup: Bool = false, cleanupGate: CleanupReceiptGate? = nil, malformedReply: Bool = false) {
        self.failFirstCleanup = failFirstCleanup; self.cleanupGate = cleanupGate; self.malformedReply = malformedReply
    }
    func token() -> String { ownedToken }
    func calls() -> [(String, String)] { operations }
    func request(operation: String, params: Data) async throws -> Data {
        let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        operations.append((operation, parameters["sessionToken"] ?? ""))
        let result: [String: Any]
        if operation == "webProviderStart" { result = ["sessionToken": ownedToken, "state": "ready"] }
        else {
            guard parameters["sessionToken"] == ownedToken else { throw WebModelServer.Failure.invalidRequest }
            switch operation {
            case "webProviderSend": result = ["state": "running"]
            case "webProviderPoll": result = ["state": "complete", "text": malformedReply ? "INVALID_JSON_FIXTURE" : "{\"type\":\"message\",\"text\":\"OK\"}"]
            case "webProviderFinish", "webProviderCancel":
                if failFirstCleanup { failFirstCleanup = false; result = ["cleanup": "failed", "error": ["message": "PRIVATE_REPLY_CANARY"]] }
                else { await cleanupGate?.pause(); result = ["cleanup": "deleted"] }
            default: throw WebModelServer.Failure.invalidRequest
            }
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(result))
    }
}

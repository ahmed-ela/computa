import Foundation
import XCTest
@testable import Computa

@MainActor
final class GroqHistoryTurnRegistrationTests: XCTestCase {
    func testWriterPrecedesGateAndDuplicateAcknowledgmentKeepsTheSameEpoch() async throws {
        try await withFixture { f in
            await self.expectContextRefusal { try await f.register() }
            let firstValue = try await f.prepareWriter()
            let first = try XCTUnwrap(firstValue)
            XCTAssertTrue(first.isCurrent(current: f.scope))
            let duplicateValue = try await f.prepareWriter()
            let duplicate = try XCTUnwrap(duplicateValue)
            XCTAssertTrue(first.isCurrent(current: f.scope), "A duplicate ACK must not reinstall/revoke the first writer")
            XCTAssertTrue(duplicate.isCurrent(current: f.scope))
            try await f.register()
            try await f.register()
            XCTAssertTrue(first.isCurrent(current: f.scope))
            await self.expectContextRefusal {
                _ = try await f.server.prepareGroqHistoryTurn(taskID: f.task, threadID: f.thread,
                    turnID: f.turn, runtimeGeneration: f.runtime, preparationID: f.preparation,
                    modelID: f.model, coreGeneration: UUID())
            }
        }
    }

    func testFirstHTTPMayWaitWhileWriterIsPreparedWithoutOpeningTheGate() async throws {
        try await withFixture { f in
            let metadata = String(decoding: try JSONSerialization.data(withJSONObject: [
                "thread_id": f.thread, "turn_id": f.turn, "request_kind": "turn"
            ]), as: UTF8.self)
            let tools = [GroqToolCatalog.specification, GroqHistoryTool.specification].map { definition in
                var wire = definition
                wire["parameters"] = wire.removeValue(forKey: "inputSchema")
                return wire
            }
            let body = try JSONSerialization.data(withJSONObject: ["model": f.model,
                "input": "Read-only registration race fixture.",
                "tools": tools,
                "client_metadata": ["x-codex-turn-metadata": metadata]])
            _ = try WebModelResponseCodec.prepareRequest(body)
            let inference = Task { try await f.server.infer(body, taskID: f.task) }
            var waiting = false
            let end = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < end {
                waiting = await f.server.isWaitingForContextForTesting(taskID: f.task)
                if waiting { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard waiting else {
                inference.cancel()
                do { _ = try await inference.value; XCTFail("Unexpected inference completion before registration") }
                catch { XCTFail("Require the actual inference task at its native-context gate: \(error)") }
                return
            }
            let writerValue = try await f.prepareWriter()
            let writer = try XCTUnwrap(writerValue)
            XCTAssertTrue(writer.isCurrent(current: f.scope))
            let stillWaiting = await f.server.isWaitingForContextForTesting(taskID: f.task)
            XCTAssertTrue(stillWaiting, "Phase one must not resolve the native inference waiter")
            let callsBeforeCancel = await f.transport.callCount()
            XCTAssertEqual(callsBeforeCancel, 0)
            _ = await f.server.cancel(taskID: f.task, runtimeGeneration: f.runtime)
            do { _ = try await inference.value; XCTFail("Retired registration cannot run inference") }
            catch { /* The exact cancelled context remains closed. */ }
            XCTAssertFalse(writer.isCurrent(current: f.scope))
            let callsAfterCancel = await f.transport.callCount()
            XCTAssertEqual(callsAfterCancel, 0)
        }
    }

    func testTransportReplacementRevokesWriterWithoutRecreatingItThroughDuplicateAck() async throws {
        for gateAlreadyOpened in [false, true] { try await withFixture { f in
            let writerValue = try await f.prepareWriter()
            let writer = try XCTUnwrap(writerValue)
            if gateAlreadyOpened { try await f.register() }
            await f.server.configureEmbeddedTransport(GroqHistoryRegistrationProbe())
            XCTAssertFalse(writer.isCurrent(current: f.scope))
            await self.expectContextRefusal { _ = try await f.prepareWriter() }
            await self.expectContextRefusal { try await f.register() }
        } }
    }

    func testRuntimeReplacementAndFreshPreparationRevokeOldWriters() async throws {
        try await withFixture { f in
            let writerValue = try await f.prepareWriter()
            let writer = try XCTUnwrap(writerValue)
            try await f.register()
            let next = UUID()
            try await f.server.prepareInferenceTurn(taskID: f.task, threadID: f.thread,
                runtimeGeneration: f.runtime, preparationID: next, isNewThread: false,
                isCompactToolThread: true, historyPreparation: .init(modelID: f.model, coreGeneration: f.core))
            XCTAssertFalse(writer.isCurrent(current: f.scope))
            await self.expectContextRefusal { _ = try await f.prepareWriter() }
            let nextTurn = UUID().uuidString.lowercased()
            let freshValue = try await f.server.prepareGroqHistoryTurn(taskID: f.task,
                threadID: f.thread, turnID: nextTurn, runtimeGeneration: f.runtime,
                preparationID: next, modelID: f.model, coreGeneration: f.core)
            let fresh = try XCTUnwrap(freshValue)
            let freshScope = GroqNativePublicationLedger.Scope(taskID: f.task, threadID: f.thread,
                turnID: nextTurn, runtimeGeneration: f.runtime, preparationID: next,
                modelID: f.model, coreGeneration: f.core)
            XCTAssertTrue(fresh.isCurrent(current: freshScope))
            await f.server.setCleanupRuntimeGeneration(UUID())
            XCTAssertFalse(fresh.isCurrent(current: freshScope))
        }
    }

    private struct Fixture: Sendable {
        let server: WebModelServer
        let transport: GroqHistoryRegistrationProbe
        let task = UUID().uuidString.lowercased()
        let thread = UUID().uuidString.lowercased()
        let turn = UUID().uuidString.lowercased()
        let runtime = UUID(), preparation = UUID(), core = UUID()
        let model = WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
        var scope: GroqNativePublicationLedger.Scope {
            .init(taskID: task, threadID: thread, turnID: turn, runtimeGeneration: runtime,
                  preparationID: preparation, modelID: model, coreGeneration: core)
        }
        func prepareWriter() async throws -> GroqNativePublicationLedger.CompletionWriter? {
            try await server.prepareGroqHistoryTurn(taskID: task, threadID: thread, turnID: turn,
                runtimeGeneration: runtime, preparationID: preparation, modelID: model, coreGeneration: core)
        }
        func register() async throws {
            try await server.registerInferenceTurn(taskID: task, threadID: thread, turnID: turn,
                runtimeGeneration: runtime, preparationID: preparation)
        }
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GroqHistoryRegistration-" + UUID().uuidString)
        let f = Fixture(server: WebModelServer(), transport: GroqHistoryRegistrationProbe())
        await f.server.configureCleanupReceipts(directory: root.appendingPathComponent("cleanup"),
            runtimeGeneration: f.runtime, observer: { _ in })
        await f.server.configureEvidenceDirectory(root.appendingPathComponent("evidence"))
        await f.server.configureEmbeddedTransport(f.transport)
        do {
            try await f.server.prepareInferenceTurn(taskID: f.task, threadID: f.thread,
                runtimeGeneration: f.runtime, preparationID: f.preparation, isNewThread: true,
                isCompactToolThread: true, historyPreparation: .init(modelID: f.model, coreGeneration: f.core))
            try await body(f)
            _ = await f.server.shutdown()
            try? FileManager.default.removeItem(at: root)
        } catch {
            _ = await f.server.shutdown()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func expectContextRefusal(_ operation: @MainActor () async throws -> Void) async {
        do { try await operation(); XCTFail("The exact native context must be required") }
        catch WebModelServer.Failure.inferenceContextRequired { }
        catch { XCTFail("Unexpected native registration failure: \(error)") }
    }
}

private actor GroqHistoryRegistrationProbe: WebModelTransport {
    private var calls = 0
    func callCount() -> Int { calls }
    func request(operation: String, params: Data) async throws -> Data {
        calls += 1
        throw ProbeFailure.unexpectedProviderRequest
    }
    enum ProbeFailure: Error { case unexpectedProviderRequest }
}

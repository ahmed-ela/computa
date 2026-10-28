import Darwin
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

    func testInferenceRetirementFailureAndExactManualRetryPersistOriginalBindingWithoutInferenceReplay() async throws {
        let root = try directory(), task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
        let generation = UUID(), original = CleanupReceiptTransport(failFirstCleanup: true)
        let replacement = CleanupReceiptTransport()
        let server = WebModelServer(), audit = CleanupReceiptAudit()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(original))
        await server.configureEvidenceDirectory(root.appendingPathComponent("evidence"))
        await server.configureCleanupReceipts(directory: root, runtimeGeneration: generation) { await audit.append($0) }
        do {
            _ = try await server.fixtureInfer(Data("{\"model\":\"browser/claude\",\"input\":\"Synthetic\",\"tools\":[]}".utf8),
                taskID: task, threadID: thread, turnID: turn, runtimeGeneration: generation)
            XCTFail("A response cannot escape a failed inference retirement")
        } catch { XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.cleanupFailed.localizedDescription) }
        let lastAutomatic = await audit.last()
        let automatic = try XCTUnwrap(lastAutomatic)
        XCTAssertEqual(automatic.outcome, .unconfirmed); XCTAssertEqual(automatic.trigger, .inference)
        XCTAssertEqual(automatic.taskID, task.lowercased()); XCTAssertEqual(automatic.threadID, thread.lowercased())
        XCTAssertEqual(automatic.turnID, turn.lowercased()); XCTAssertEqual(automatic.provider, .claude)
        XCTAssertEqual(automatic.route, .embedded); XCTAssertEqual(automatic.modelID, "browser/claude")
        XCTAssertEqual(automatic.runtimeGeneration, generation.uuidString.lowercased()); XCTAssertTrue(automatic.receiptSaved)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(replacement))
        let unrelatedProfile = try XCTUnwrap(WebsiteResponseProfile.begin(source: .serverAcknowledged,
            sessionToken: UUID().uuidString, sequence: 1, inferenceID: UUID()))
        // A stale inherited diagnostic must not fence real cleanup or retarget
        // its transport, durable receipt, release evidence, or observer.
        let closed = await WebsiteResponseProfile.$cleanup.withValue(unrelatedProfile) {
            await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
        }
        XCTAssertEqual(closed.outcome, .closed); XCTAssertEqual(closed.reason, .deleted)
        XCTAssertEqual(closed.trigger, .manual); XCTAssertTrue(closed.receiptSaved)
        let repeated = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
        XCTAssertEqual(repeated, closed, "Turn-end current absence cannot overwrite the exact durable closure")
        let originalCalls = await original.calls(), replacementCalls = await replacement.calls()
        XCTAssertEqual(originalCalls.map(\.0), ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish", "webProviderCancel"])
        XCTAssertTrue(replacementCalls.isEmpty, "Selector/transport changes cannot retarget old cleanup")
        let originalToken = await original.token()
        XCTAssertEqual(originalCalls.suffix(2).map(\.1), Array(repeating: originalToken, count: 2))
        let file = root.appendingPathComponent(task.lowercased() + ".jsonl")
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains(originalToken.lowercased())); XCTAssertFalse(raw.contains("PRIVATE_REPLY_CANARY"))
        let records = try raw.split(separator: "\n").map { try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: Data($0.utf8)) }
        XCTAssertEqual(records.map(\.outcome), [.unconfirmed, .closed])
        XCTAssertTrue(records.allSatisfy { $0.inferenceID == automatic.inferenceID && $0.sessionToken == automatic.sessionToken })
        XCTAssertEqual(WebsiteSessionCleanupStore(directory: root).latest(), [closed])
        _ = await server.shutdown()
    }

    func testDuplicateManualAttemptIsFiniteBusyAndNeverRepeatsDestructiveOperation() async throws {
        let root = try directory(), task = UUID().uuidString, generation = UUID()
        let gate = CleanupReceiptGate(), transport = CleanupReceiptTransport(cleanupGate: gate)
        let server = WebModelServer()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        await server.configureEvidenceDirectory(root.appendingPathComponent("evidence"))
        await server.configureCleanupReceipts(directory: root, runtimeGeneration: generation) { _ in }
        let first = Task {
            try await server.fixtureInfer(Data("{\"model\":\"browser/claude\",\"input\":\"Synthetic\",\"tools\":[]}".utf8),
                taskID: task, runtimeGeneration: generation)
        }
        await gate.waitUntilEntered()
        let duplicate = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
        XCTAssertEqual(duplicate.outcome, .unconfirmed); XCTAssertEqual(duplicate.reason, .busy)
        do {
            _ = try await server.fixtureInfer(Data("{\"model\":\"browser/gemini\",\"input\":\"Forbidden\",\"tools\":[]}".utf8),
                taskID: task, runtimeGeneration: generation)
            XCTFail("Cleanup must fence an otherwise valid inference for the same native turn")
        }
        catch { XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.busy.localizedDescription) }
        await gate.release()
        _ = try await first.value
        let saved = try XCTUnwrap(WebsiteSessionCleanupStore(directory: root).latest().last)
        XCTAssertEqual(saved.outcome, .closed); XCTAssertEqual(saved.trigger, .inference)
        let calls = await transport.calls()
        XCTAssertEqual(calls.filter { $0.0 == "webProviderFinish" }.count, 1)
        XCTAssertTrue(calls.filter { $0.0 == "webProviderCancel" }.isEmpty)
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
        XCTAssertTrue(store.save(receipt)); XCTAssertTrue(store.save(receipt), "An exact persistence retry must not append or repeat cleanup")
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

@MainActor
final class WebsiteSessionCleanupTransactionStoreTests: XCTestCase {
    private struct Scope {
        let task = UUID().uuidString.lowercased()
        let thread = UUID().uuidString.lowercased()
        let turn = UUID().uuidString.lowercased()
        let generation = UUID()
        let inference = UUID().uuidString.lowercased()
        let token = UUID().uuidString.lowercased()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaCleanupJournal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func receipt(_ scope: Scope, turn: String? = nil, inference: String? = nil, token: String? = nil,
                         outcome: WebsiteSessionCleanupReceipt.Outcome = .closed) -> WebsiteSessionCleanupReceipt {
        WebsiteSessionCleanupReceipt(taskID: scope.task, threadID: scope.thread, turnID: turn ?? scope.turn,
            runtimeGeneration: scope.generation, outcome: outcome, provider: .claude, route: .embedded,
            modelID: "browser/claude", reason: outcome == .closed ? .notCreated : .cleanupUnverified,
            trigger: .inference, receiptSaved: true, inferenceID: inference ?? scope.inference, sessionToken: token ?? scope.token)
    }

    private func legacy(_ task: String) -> WebsiteSessionCleanupReceipt {
        WebsiteSessionCleanupReceipt(taskID: task, runtimeGeneration: UUID(), outcome: .noOwnedSession,
            reason: .noOwnedSession, trigger: .automatic, receiptSaved: true)
    }

    private func startup(_ scope: Scope, inference: String? = nil) -> WebsiteSessionCleanupReceipt {
        WebsiteSessionCleanupReceipt(taskID: scope.task, threadID: scope.thread, turnID: scope.turn,
            runtimeGeneration: scope.generation, outcome: .unconfirmed, provider: .claude, route: .embedded,
            modelID: "browser/claude", reason: .cleanupUnverified, trigger: .inference, receiptSaved: true,
            inferenceID: inference ?? scope.inference)
    }

    func testStartupAttemptHasCausalIdentityButCannotClaimLeaseOrClosure() throws {
        let scope = Scope(), pending = startup(scope)
        XCTAssertEqual(pending.schemaVersion, 3)
        XCTAssertTrue(pending.isValid)
        XCTAssertFalse(pending.isTransactionLinked)
        XCTAssertNil(pending.sessionToken)
        for field in ["inferenceID", "threadID", "turnID"] {
            XCTAssertFalse(try changed(pending, [:], removing: [field]).isValid, field)
        }
        for field in ["attemptID", "taskID", "threadID", "turnID", "runtimeGeneration", "inferenceID"] {
            XCTAssertFalse(try changed(pending, [field: UUID().uuidString.uppercased()]).isValid, field)
        }
        XCTAssertFalse(try changed(pending, ["sessionToken": scope.token]).isValid)
        XCTAssertFalse(try changed(pending, ["outcome": "closed", "reason": "not_created"]).isValid)
        XCTAssertFalse(try changed(pending, ["outcome": "no_owned_session", "reason": "no_owned_session"]).isValid)
        XCTAssertFalse(try changed(pending, ["schemaVersion": 1]).isValid)
    }

    func testFullSummaryCachePersistsUnconfirmedStartupWithoutInventingLease() throws {
        let root = try directory(), oldScope = Scope(), scope = Scope(), otherScope = Scope()
        var limits = WebsiteSessionCleanupStore.Limits(); limits.summaryTasks = 1
        let store = WebsiteSessionCleanupStore(directory: root, limits: limits), old = legacy(oldScope.task)
        XCTAssertTrue(store.save(old))
        let originalSummary = try Data(contentsOf: root.appendingPathComponent(oldScope.task + ".jsonl"))
        let pending = startup(scope), other = startup(otherScope)
        XCTAssertTrue(store.save(pending)); XCTAssertTrue(store.save(pending))
        XCTAssertTrue(store.save(other), "Two missing tokens are not a shared session identity")
        XCTAssertFalse(store.saveTransaction(pending), "An unacknowledged attempt is not a lease proof")
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [pending])
        XCTAssertEqual(try store.transactionRecords(for: otherScope.task, turnID: otherScope.turn), [other])
        let reopened = WebsiteSessionCleanupStore(directory: root, limits: limits)
        XCTAssertEqual(Set(reopened.latest().map(\.attemptID)), Set([old.attemptID, pending.attemptID, other.attemptID]))
        XCTAssertFalse(store.save(receipt(scope)), "An acknowledged token cannot be invented for the same startup attempt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(scope.task + ".jsonl").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(oldScope.task + ".jsonl")), originalSummary)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.count, 1)
        let journal = journalFile(root, scope), validJournal = try Data(contentsOf: journal)
        try Data("corrupt\n".utf8).write(to: journal)
        XCTAssertFalse(store.save(pending), "A full summary cache cannot excuse a corrupt attempt journal")
        try validJournal.write(to: journal)
    }

    func testUnconfirmedStartupCannotBorrowAnotherClosureAndKeepsJournalBudget() throws {
        let root = try directory(), scope = Scope()
        var limits = WebsiteSessionCleanupStore.Limits(); limits.transactionRecords = 2
        let store = WebsiteSessionCleanupStore(directory: root, limits: limits)
        let previous = receipt(scope, inference: UUID().uuidString.lowercased()), pending = startup(scope)
        XCTAssertTrue(store.save(previous)); XCTAssertTrue(store.save(pending))
        XCTAssertTrue(store.save(legacy(scope.task)))
        XCTAssertEqual(store.latest(), [pending], "Another closure or current absence cannot retire an unknown startup")
        let journal = journalFile(root, scope), original = try Data(contentsOf: journal)
        XCTAssertTrue(store.save(pending), "An identical persistence retry consumes no new record")
        XCTAssertFalse(store.save(startup(scope, inference: UUID().uuidString.lowercased())))
        XCTAssertEqual(try Data(contentsOf: journal), original)
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [previous, pending])
    }

    func testUnacknowledgedStartupWithFullCachePersistsAndCannotRetryInference() async throws {
        let root = try directory(), store = WebsiteSessionCleanupStore(directory: root)
        for _ in 0..<256 { XCTAssertTrue(store.save(legacy(Scope().task))) }
        let scope = Scope(), transport = CleanupBlockedStartTransport(), server = WebModelServer(), audit = CleanupReceiptAudit()
        await server.configureEmbeddedTransport(transport)
        await server.configureEvidenceDirectory(root.appendingPathComponent("evidence"))
        await server.configureCleanupReceipts(directory: root, runtimeGeneration: scope.generation) { await audit.append($0) }
        do {
            _ = try await server.fixtureInfer(Data("{\"model\":\"browser/gemini\",\"input\":\"Synthetic\",\"tools\":[]}".utf8),
                taskID: scope.task, threadID: scope.thread, turnID: scope.turn, runtimeGeneration: scope.generation)
            XCTFail("The saved provider gate cannot release a response")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        let issues = await server.fixtureFinish(taskID: scope.task, runtimeGeneration: scope.generation)
        XCTAssertEqual(issues, [WebModelServer.Failure.startOwnershipUnconfirmed.localizedDescription])
        let observed = await audit.last(), pending = try XCTUnwrap(observed)
        XCTAssertEqual(pending.schemaVersion, 3); XCTAssertTrue(pending.receiptSaved)
        XCTAssertEqual(pending.outcome, .unconfirmed); XCTAssertNil(pending.sessionToken)
        XCTAssertEqual(pending.taskID, scope.task); XCTAssertEqual(pending.threadID, scope.thread)
        XCTAssertEqual(pending.turnID, scope.turn); XCTAssertNotNil(pending.inferenceID)
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [pending])
        XCTAssertTrue(WebsiteSessionCleanupStore(directory: root).latest().contains(pending))
        let retried = await server.retryWebsiteSessionCleanup(taskID: scope.task, runtimeGeneration: scope.generation)
        XCTAssertEqual(retried, pending, "Manual cleanup preserves the exact unknown attempt and does not invent ownership")
        do {
            _ = try await server.fixtureInfer(Data("{\"model\":\"browser/claude\",\"input\":\"No replay\",\"tools\":[]}".utf8),
                taskID: scope.task, threadID: scope.thread, turnID: scope.turn, runtimeGeneration: scope.generation)
            XCTFail("Changing providers cannot replay an unresolved Start")
        } catch { XCTAssertEqual(error.localizedDescription, WebModelServer.Failure.startOwnershipUnconfirmed.localizedDescription) }
        let calls = await transport.calls(); XCTAssertEqual(calls, ["webProviderStart"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.count, 256)
        _ = await server.shutdown()
    }

    /// Diagnostic-only, synthetic store benchmark. It is intentionally opt-in:
    /// no test queries app state or personal receipts, and no latency threshold
    /// can turn scheduler/filesystem variance into a functional failure.
    func testSyntheticCleanupStoreSaveMicrobenchmark() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["COMPUTA_CLEANUP_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Set COMPUTA_CLEANUP_BENCHMARK_OUTPUT to a new private artifact path to run the synthetic store benchmark")
        }
        guard outputPath.hasPrefix("/"), outputPath.utf8.count <= 4_096,
              let label = ProcessInfo.processInfo.environment["COMPUTA_CLEANUP_BENCHMARK_LABEL"],
              !label.isEmpty, label.utf8.count <= 32,
              label.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            XCTFail("The synthetic benchmark requires an absolute output path and a bounded label")
            throw CocoaError(.fileWriteInvalidFileName)
        }
        func syntheticID(_ index: Int, _ field: Int) -> String {
            String(format: "aa000000-%04x-4000-8000-%012llx", UInt32(field), UInt64(index))
        }
        func syntheticReceipt(_ index: Int) throws -> WebsiteSessionCleanupReceipt {
            let row = WebsiteSessionCleanupReceipt(taskID: syntheticID(index, 1), threadID: syntheticID(index, 2),
                turnID: syntheticID(index, 3), runtimeGeneration: UUID(uuidString: "f0000000-0000-4000-8000-000000000001")!,
                outcome: .closed, provider: .chatgpt, route: .embedded,
                modelID: WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID,
                reason: .notCreated, trigger: .inference, receiptSaved: true,
                inferenceID: syntheticID(index, 4), sessionToken: syntheticID(index, 5))
            return try changed(row, ["attemptID": syntheticID(index, 6), "timestamp": "2026-10-18T00:00:00.000Z"])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func line(_ receipt: WebsiteSessionCleanupReceipt) throws -> Data {
            var data = try encoder.encode(receipt); data.append(0x0A); return data
        }
        func transaction(_ root: URL, _ receipt: WebsiteSessionCleanupReceipt) -> URL {
            root.appendingPathComponent("transactions", isDirectory: true).appendingPathComponent(receipt.taskID, isDirectory: true)
                .appendingPathComponent(receipt.turnID! + ".jsonl")
        }
        func milliseconds(_ elapsed: Duration) throws -> Double {
            let parts = elapsed.components
            let value = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
            guard value.isFinite, (0...600_000).contains(value) else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        func measuredSave(_ store: WebsiteSessionCleanupStore, _ receipt: WebsiteSessionCleanupReceipt)
            throws -> (saved: Bool, elapsedMs: Double, scopes: [[Any]]) {
            typealias Scope = WebsiteSessionCleanupStore.SaveTimingScope
            var metrics = Dictionary(uniqueKeysWithValues: Scope.allCases.map {
                ($0, (count: 0, total: 0.0, maximum: 0.0, firstCalls: [Double]()))
            })
            var measurementError: Error?
            let began = ContinuousClock.now
            let saved = store.save(receipt, timing: { scope, duration in
                do {
                    let ms = try milliseconds(duration)
                    var value = metrics[scope]!
                    value.count += 1; value.total += ms; value.maximum = max(value.maximum, ms)
                    if value.firstCalls.count < 2 { value.firstCalls.append(ms) }
                    metrics[scope] = value
                } catch { measurementError = error }
            })
            let elapsed = try milliseconds(.now - began)
            if let measurementError { throw measurementError }
            let scopes = Scope.allCases.map { scope -> [Any] in
                let value = metrics[scope]!
                return [value.count, value.total, value.maximum, value.firstCalls]
            }
            return (saved, elapsed, scopes)
        }
        var samples: [[String: Any]] = [], cases: [[String: Any]] = []
        for seededFiles in [100, 200] {
            let root = try directory(), store = WebsiteSessionCleanupStore(directory: root)
            let transactions = root.appendingPathComponent("transactions", isDirectory: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var seedBytes = 0, seeds: [WebsiteSessionCleanupReceipt] = []
            // Seeding writes exact deterministic native journal/summary bytes
            // directly, outside measurement. The timed path is the real save().
            // Every seed is read back through the public store before timing.
            for index in 1...seededFiles {
                let row = try syntheticReceipt(index), data = try line(row)
                XCTAssertTrue(row.isTransactionLinked); XCTAssertTrue(row.isValid)
                let file = transaction(root, row)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let summary = root.appendingPathComponent(row.taskID + ".jsonl")
                try data.write(to: summary, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summary.path)
                XCTAssertEqual(try store.transactionRecords(for: row.taskID, turnID: row.turnID!), [row])
                seedBytes += data.count; seeds.append(row)
            }
            var fresh: [WebsiteSessionCleanupReceipt] = []
            for index in 0..<5 {
                let row = try syntheticReceipt(seededFiles + index + 1)
                let measurement = try measuredSave(store, row), saved = measurement.saved, elapsed = measurement.elapsedMs
                guard saved else { XCTFail("A synthetic fresh save was rejected"); throw CocoaError(.fileWriteUnknown) }
                XCTAssertEqual(try store.transactionRecords(for: row.taskID, turnID: row.turnID!), [row])
                XCTAssertEqual(try Data(contentsOf: transaction(root, row)), try line(row))
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(row.taskID + ".jsonl")), try line(row))
                samples.append(["seededJournalFiles": seededFiles, "journalFilesBefore": seededFiles + index,
                    "sample": index + 1, "operation": "fresh_save", "elapsedMs": elapsed, "saved": true, "scopeTimings": measurement.scopes])
                fresh.append(row)
            }
            for (index, row) in fresh.enumerated() {
                let journal = transaction(root, row), summary = root.appendingPathComponent(row.taskID + ".jsonl")
                let oldJournal = try Data(contentsOf: journal), oldSummary = try Data(contentsOf: summary)
                let measurement = try measuredSave(store, row), saved = measurement.saved, elapsed = measurement.elapsedMs
                guard saved else { XCTFail("An exact synthetic persistence retry was rejected"); throw CocoaError(.fileWriteUnknown) }
                XCTAssertEqual(try Data(contentsOf: journal), oldJournal)
                XCTAssertEqual(try Data(contentsOf: summary), oldSummary)
                XCTAssertEqual(try store.transactionRecords(for: row.taskID, turnID: row.turnID!), [row])
                samples.append(["seededJournalFiles": seededFiles, "journalFilesBefore": seededFiles + 5,
                    "sample": index + 1, "operation": "idempotent_retry", "elapsedMs": elapsed, "saved": true, "scopeTimings": measurement.scopes])
            }
            let first = try XCTUnwrap(seeds.first)
            for (index, field) in ["inferenceID", "sessionToken"].enumerated() {
                let collision = try changed(syntheticReceipt(seededFiles + 101 + index), [field: field == "inferenceID" ? first.inferenceID! : first.sessionToken!])
                XCTAssertFalse(store.save(collision), "A fresh task cannot adopt a seeded native inference or website session")
                XCTAssertFalse(FileManager.default.fileExists(atPath: transaction(root, collision).path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(collision.taskID + ".jsonl").path))
            }
            for row in seeds + fresh {
                XCTAssertEqual(try store.transactionRecords(for: row.taskID, turnID: row.turnID!), [row])
            }
            cases.append(["seededJournalFiles": seededFiles, "seededSummaryFiles": seededFiles, "seededJournalBytes": seedBytes,
                "timedFreshSaves": 5, "timedExactRetries": 5, "rejectedCrossTaskCollisions": 2,
                "finalJournalFiles": seededFiles + 5, "allStoredReceiptsReadBackExactly": true])
        }
        let report: [String: Any] = ["schemaVersion": 1, "kind": "synthetic_cleanup_store_save_microbenchmark",
            "fixtureVersion": 1, "label": label, "cases": cases, "samples": samples,
            "timingBoundary": "only_real_WebsiteSessionCleanupStore_save_including_existing_validation_and_durable_writes",
            "seeding": "deterministic_synthetic_native_journal_and_summary_bytes_written_before_timing_and_read_back_via_store",
            "performanceThresholdApplied": false,
            "scopeTimingContract": ["fixedScopes": WebsiteSessionCleanupStore.SaveTimingScope.allCases.map(\.rawValue),
                "clock": "ContinuousClock synchronous wall time, not CPU", "firstCallsRetainedPerScope": 2,
                "scopeRow": ["calls", "totalMs", "maximumMs", "firstCallsMs"],
                "freshWriteOrder": "journal then summary; atomicWrite/synchronize/readback first two calls follow that order",
                "scopeCoverage": "leaf timings do not include every guard, encoding, directory preparation or sink overhead",
                "ordinaryProductionSink": "nil; no clock sampling or callbacks"]]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        guard data.count <= 32_768 else { throw CocoaError(.fileWriteOutOfSpace) }
        let descriptor = open(outputPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard count > 0 else { throw POSIXError(.EIO) }; offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func testOptionalSaveTimingsPreserveBytesSyncRetriesAndCorruptionRejection() throws {
        let plainRoot = try directory(), timedRoot = try directory(), scope = Scope(), row = receipt(scope)
        let plain = WebsiteSessionCleanupStore(directory: plainRoot), timed = WebsiteSessionCleanupStore(directory: timedRoot)
        typealias Stage = WebsiteSessionCleanupStore.SaveTimingScope
        var stages: [Stage: [Duration]] = [:]
        let sink: WebsiteSessionCleanupStore.SaveTimingSink = { stage, elapsed in
            stages[stage, default: []].append(elapsed)
        }
        XCTAssertTrue(plain.save(row)); XCTAssertTrue(timed.save(row, timing: sink))
        XCTAssertEqual(stages[.inventory]?.count, 1); XCTAssertEqual(stages[.records]?.count, 2)
        for stage in [Stage.atomicWrite, .synchronize, .readback] { XCTAssertEqual(stages[stage]?.count, 2) }
        XCTAssertTrue(stages.values.flatMap { $0 }.allSatisfy { $0 >= .zero })
        let journal = journalFile(timedRoot, scope), summary = timedRoot.appendingPathComponent(scope.task + ".jsonl")
        let journalBytes = try Data(contentsOf: journal), summaryBytes = try Data(contentsOf: summary)
        XCTAssertEqual(journalBytes, try Data(contentsOf: journalFile(plainRoot, scope)))
        XCTAssertEqual(summaryBytes, try Data(contentsOf: plainRoot.appendingPathComponent(scope.task + ".jsonl")))
        XCTAssertEqual(timed.latest(), plain.latest())
        stages.removeAll()
        XCTAssertTrue(timed.save(row, timing: sink))
        XCTAssertEqual(stages[.synchronize]?.count, 2); XCTAssertNil(stages[.atomicWrite]); XCTAssertNil(stages[.readback])
        XCTAssertEqual(try Data(contentsOf: journal), journalBytes); XCTAssertEqual(try Data(contentsOf: summary), summaryBytes)
        try Data("corrupt\n".utf8).write(to: journal, options: .atomic)
        let next = Scope()
        XCTAssertFalse(timed.save(receipt(next), timing: sink), "Profiling cannot bypass current historical validation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalFile(timedRoot, next).path))
        XCTAssertEqual(try Data(contentsOf: summary), summaryBytes)
    }

    func testFreshMetadataDistinguishesMissingEmptyDirectoryAndDanglingJournal() throws {
        let root = try directory(), scope = Scope(), store = WebsiteSessionCleanupStore(directory: root)
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [])
        let file = journalFile(root, scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        XCTAssertThrowsError(try store.transactionRecords(for: scope.task, turnID: scope.turn))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.transactionRecords(for: scope.task, turnID: scope.turn))
        XCTAssertFalse(store.save(receipt(Scope())), "A journal-shaped directory is not a regular historical file")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.transactionRecords(for: scope.task, turnID: scope.turn))
        XCTAssertFalse(store.save(receipt(Scope())), "A dangling symlink is not an absent journal")
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [])
        let row = receipt(scope)
        XCTAssertTrue(store.save(row)); XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [row])
    }

    func testFreshMetadataRejectsTaskSymlinkAndRegularFileWithoutReusingEarlierType() throws {
        let root = try directory(), scope = Scope(), next = Scope(), store = WebsiteSessionCleanupStore(directory: root)
        let row = receipt(scope)
        XCTAssertTrue(store.save(row))
        let task = journalFile(root, scope).deletingLastPathComponent(), held = root.appendingPathComponent("held-task")
        try FileManager.default.moveItem(at: task, to: held)
        try FileManager.default.createSymbolicLink(at: task, withDestinationURL: held)
        XCTAssertFalse(store.save(receipt(next)), "Even an intact target cannot authorize a symlinked task")
        try FileManager.default.removeItem(at: task)
        try Data("not a directory".utf8).write(to: task)
        XCTAssertFalse(store.save(receipt(next)), "A valid earlier directory read cannot authorize a changed regular file")
        try FileManager.default.removeItem(at: task)
        try FileManager.default.moveItem(at: held, to: task)
        XCTAssertTrue(store.save(receipt(next)))
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [row])
    }

    func testHistoricalValidationRereadsChangedJournalOnEverySave() throws {
        let root = try directory(), scope = Scope(), next = Scope(), store = WebsiteSessionCleanupStore(directory: root)
        let original = receipt(scope), later = receipt(next)
        XCTAssertTrue(store.save(original))
        let file = journalFile(root, scope), exact = try Data(contentsOf: file)
        let malformed = try changed(original, ["timestamp": "not-a-date"])
        var corrupt = try JSONEncoder().encode(malformed); corrupt.append(0x0A)
        try corrupt.write(to: file, options: .atomic)
        XCTAssertFalse(store.save(later), "A prior valid pass must never cache a file or hide subsequent corruption")
        try exact.write(to: file, options: .atomic)
        XCTAssertTrue(store.save(later), "The next pass validates the restored bytes independently")
        XCTAssertEqual(try store.transactionRecords(for: next.task, turnID: next.turn), [later])
    }

    func testOnePassRejectsInvalidProviderOrTimestampAfterAValidHistoricalRow() throws {
        for fields in [["provider": "chatgpt"], ["timestamp": "not-a-date"]] {
            let root = try directory(), scope = Scope(), next = Scope(), store = WebsiteSessionCleanupStore(directory: root)
            let first = receipt(scope)
            XCTAssertTrue(store.save(first))
            let second = try changed(receipt(scope, inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased()), fields)
            XCTAssertFalse(second.isValid)
            let file = journalFile(root, scope), exact = try Data(contentsOf: file)
            var corrupt = exact; corrupt.append(try JSONEncoder().encode(second)); corrupt.append(0x0A)
            try corrupt.write(to: file, options: .atomic)
            XCTAssertFalse(store.save(receipt(next)), "A valid earlier model/timestamp cannot validate a changed provider or malformed row")
            try exact.write(to: file, options: .atomic)
            let later = receipt(next)
            XCTAssertTrue(store.save(later))
            XCTAssertEqual(try store.transactionRecords(for: next.task, turnID: next.turn), [later])
        }
    }

    func testOnePassDoesNotMemoizeCanonicallyEquivalentNonASCIIModelBytesAsValid() throws {
        let model = WebsiteModelChoice(provider: "chatgpt", key: "fixture/(x)", label: "Instant").modelID
        XCTAssertTrue(model.contains("K"))
        let forged = model.replacingOccurrences(of: "K", with: "\u{212A}")
        XCTAssertEqual(model, forged, "Swift String equality treats the Kelvin sign as canonical ASCII K")
        XCTAssertNotEqual(Array(model.utf8), Array(forged.utf8))
        XCTAssertNotNil(WebsiteModelCatalog.choice(for: model))
        XCTAssertNil(WebsiteModelCatalog.choice(for: forged), "Encoded model IDs require ASCII bytes")
        let root = try directory(), scope = Scope(), next = Scope(), store = WebsiteSessionCleanupStore(directory: root)
        let first = try changed(receipt(scope), ["provider": "chatgpt", "modelID": model])
        let second = try changed(receipt(scope, inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased()),
            ["provider": "chatgpt", "modelID": forged])
        XCTAssertTrue(first.isValid); XCTAssertFalse(second.isValid)
        XCTAssertTrue(store.save(first))
        let file = journalFile(root, scope), exact = try Data(contentsOf: file), later = receipt(next)
        var corrupt = exact; corrupt.append(try JSONEncoder().encode(second)); corrupt.append(0x0A)
        try corrupt.write(to: file, options: .atomic)
        XCTAssertThrowsError(try store.transactionRecords(for: scope.task, turnID: scope.turn))
        XCTAssertFalse(store.save(later), "An earlier valid row must not grant validity to distinct malformed bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalFile(root, next).path))
        try exact.write(to: file, options: .atomic)
        XCTAssertTrue(store.save(later))
        XCTAssertEqual(try store.transactionRecords(for: next.task, turnID: next.turn), [later])
    }

    private func changed(_ receipt: WebsiteSessionCleanupReceipt, _ fields: [String: Any], removing: [String] = []) throws -> WebsiteSessionCleanupReceipt {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        fields.forEach { raw[$0.key] = $0.value }; removing.forEach { raw.removeValue(forKey: $0) }
        return try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    private func rowBytes(_ receipt: WebsiteSessionCleanupReceipt) throws -> Int {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(receipt).count
    }

    private func journalFile(_ root: URL, _ scope: Scope, turn: String? = nil) -> URL {
        root.appendingPathComponent("transactions").appendingPathComponent(scope.task).appendingPathComponent((turn ?? scope.turn) + ".jsonl")
    }

    func testLegacyDecodeAndIdenticalRetryRemainCompatibleWithoutInventedTransactionProof() throws {
        let root = try directory(), scope = Scope(), old = legacy(scope.task), store = WebsiteSessionCleanupStore(directory: root)
        let raw = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("inferenceID"))
        let decoded = try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: raw)
        XCTAssertEqual(decoded.schemaVersion, 1); XCTAssertTrue(decoded.isValid); XCTAssertFalse(decoded.isTransactionLinked)
        XCTAssertTrue(store.save(decoded)); XCTAssertTrue(store.save(decoded))
        XCTAssertFalse(store.saveTransaction(decoded)); XCTAssertEqual(store.latest(), [decoded])
        XCTAssertTrue(try store.transactionRecords(for: scope.task, turnID: scope.turn).isEmpty)
        let rows = try String(contentsOf: root.appendingPathComponent(scope.task + ".jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(rows.count, 1)
    }

    func testTransactionSchemaRequiresCompleteCanonicalCausalBinding() throws {
        let scope = Scope(), valid = receipt(scope)
        XCTAssertEqual(valid.schemaVersion, 2); XCTAssertTrue(valid.isValid); XCTAssertTrue(valid.isTransactionLinked)
        for field in ["inferenceID", "sessionToken", "threadID", "turnID"] {
            XCTAssertFalse(try changed(valid, [:], removing: [field]).isValid, field)
        }
        for field in ["attemptID", "taskID", "threadID", "turnID", "runtimeGeneration", "inferenceID", "sessionToken"] {
            XCTAssertFalse(try changed(valid, [field: "invalid"]).isValid, field)
            XCTAssertFalse(try changed(valid, [field: UUID().uuidString.uppercased()]).isValid, field)
        }
        XCTAssertFalse(try changed(valid, ["schemaVersion": 1]).isValid)
        XCTAssertFalse(try changed(valid, ["outcome": "no_owned_session", "reason": "no_owned_session"]).isValid)
        XCTAssertFalse(try changed(legacy(scope.task), ["trigger": "inference"]).isValid)
        let halfLinked = WebsiteSessionCleanupReceipt(taskID: scope.task, threadID: scope.thread, turnID: scope.turn,
            runtimeGeneration: scope.generation, outcome: .closed, provider: .claude, route: .embedded,
            modelID: "browser/claude", reason: .notCreated, trigger: .inference, inferenceID: scope.inference)
        XCTAssertFalse(halfLinked.isValid)
    }

    func testJournalIsIdempotentAndRejectsChangedRecordWithSameAttemptID() throws {
        let root = try directory(), scope = Scope(), first = receipt(scope), store = WebsiteSessionCleanupStore(directory: root)
        XCTAssertTrue(store.save(first)); let bytes = try Data(contentsOf: journalFile(root, scope))
        XCTAssertTrue(store.save(first)); XCTAssertTrue(store.saveTransaction(first))
        XCTAssertEqual(try Data(contentsOf: journalFile(root, scope)), bytes)
        let conflicting = try changed(first, ["trigger": "manual"])
        XCTAssertTrue(conflicting.isValid); XCTAssertFalse(store.saveTransaction(conflicting)); XCTAssertFalse(store.save(conflicting))
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [first])
        let retry = receipt(scope)
        XCTAssertTrue(store.saveTransaction(retry))
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [first, retry])
        let foreign = try changed(receipt(Scope()), ["attemptID": first.attemptID])
        XCTAssertTrue(foreign.isValid); XCTAssertFalse(store.saveTransaction(foreign), "A conflicting attempt cannot move to a different task journal")
    }

    func testInferenceAndSessionCannotBeReboundAcrossNativeScope() throws {
        let root = try directory(), scope = Scope(), original = receipt(scope), store = WebsiteSessionCleanupStore(directory: root)
        XCTAssertTrue(store.saveTransaction(original))
        let mutations: [[String: Any]] = [
            ["sessionToken": UUID().uuidString.lowercased()], ["inferenceID": UUID().uuidString.lowercased()],
            ["turnID": UUID().uuidString.lowercased()], ["threadID": UUID().uuidString.lowercased()],
            ["runtimeGeneration": UUID().uuidString.lowercased()], ["provider": "gemini", "modelID": "browser/gemini"]
        ]
        for mutation in mutations {
            var new = mutation; new["attemptID"] = UUID().uuidString.lowercased()
            let row = try changed(original, new)
            XCTAssertTrue(row.isValid); XCTAssertFalse(store.saveTransaction(row), String(describing: mutation))
        }
        let otherThread = try changed(receipt(scope, inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased()),
            ["threadID": UUID().uuidString.lowercased()])
        XCTAssertFalse(store.saveTransaction(otherThread), "One native turn cannot change its owning thread")
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [original])
    }

    func testRecordAndJournalByteBudgetsHaveExactInclusiveBoundary() throws {
        let root = try directory(), scope = Scope(), row = receipt(scope), bytes = try rowBytes(row)
        var limits = WebsiteSessionCleanupStore.Limits(); limits.recordBytes = bytes; limits.transactionBytes = bytes + 1
        let store = WebsiteSessionCleanupStore(directory: root, limits: limits)
        XCTAssertTrue(store.saveTransaction(row)); XCTAssertTrue(store.saveTransaction(row))
        XCTAssertFalse(store.saveTransaction(receipt(scope)), "A second row exceeds the byte budget")
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [row])
        let other = try directory(); limits.recordBytes = bytes - 1
        XCTAssertFalse(WebsiteSessionCleanupStore(directory: other, limits: limits).saveTransaction(row))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalFile(other, scope).path))
    }

    func testCountAndGlobalByteBudgetsRetainExistingProofOnFailure() throws {
        let root = try directory(), scope = Scope()
        var limits = WebsiteSessionCleanupStore.Limits(); limits.transactionRecords = 2
        let store = WebsiteSessionCleanupStore(directory: root, limits: limits)
        let first = receipt(scope), second = receipt(scope)
        XCTAssertTrue(store.saveTransaction(first)); XCTAssertTrue(store.saveTransaction(second)); XCTAssertFalse(store.saveTransaction(receipt(scope)))
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [first, second])
        let exactBytes = try Data(contentsOf: journalFile(root, scope)).count
        limits.transactionDirectoryBytes = exactBytes
        let exactStore = WebsiteSessionCleanupStore(directory: root, limits: limits)
        XCTAssertTrue(exactStore.saveTransaction(first))
        XCTAssertFalse(exactStore.saveTransaction(receipt(scope, turn: UUID().uuidString.lowercased(), inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased())))
        XCTAssertEqual(try exactStore.transactionRecords(for: scope.task, turnID: scope.turn), [first, second])
    }

    func testJournalTaskTurnAndFileCountsAreFinite() throws {
        for constrained in ["task", "turn", "file"] {
            let root = try directory(), scope = Scope()
            var limits = WebsiteSessionCleanupStore.Limits()
            if constrained == "task" { limits.transactionTasks = 1 }
            if constrained == "turn" { limits.transactionTurnsPerTask = 1 }
            if constrained == "file" { limits.transactionFiles = 1 }
            let store = WebsiteSessionCleanupStore(directory: root, limits: limits), first = receipt(scope)
            XCTAssertTrue(store.saveTransaction(first))
            let next = constrained == "task" ? receipt(Scope())
                : receipt(scope, turn: UUID().uuidString.lowercased(), inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased())
            XCTAssertFalse(store.saveTransaction(next), constrained)
            XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [first])
        }
    }

    func testNinetyNativeTurnsRetainEveryJournalAndArchiveEvictedLegacyRows() throws {
        let root = try directory(), scope = Scope(), store = WebsiteSessionCleanupStore(directory: root)
        let old = (0..<64).map { _ in legacy(scope.task) }
        for row in old { XCTAssertTrue(store.save(row)) }
        var fresh: [WebsiteSessionCleanupReceipt] = []
        for _ in 0..<90 {
            let row = receipt(scope, turn: UUID().uuidString.lowercased(), inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased())
            XCTAssertTrue(store.save(row)); fresh.append(row)
        }
        XCTAssertEqual(try store.archivedLegacyRecords(for: scope.task), old)
        for row in fresh { XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: row.turnID!), [row]) }
        let summary = try String(contentsOf: root.appendingPathComponent(scope.task + ".jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(summary.count, 64)
        let permissions = try FileManager.default.attributesOfItem(atPath: journalFile(root, scope, turn: fresh[0].turnID!).path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("transactions").path)
        XCTAssertEqual((directoryPermissions[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testNinetySixInferencesWithinOneNativeTurnSurviveSummaryCompaction() throws {
        let root = try directory(), scope = Scope(), store = WebsiteSessionCleanupStore(directory: root)
        var expected: [WebsiteSessionCleanupReceipt] = []
        for _ in 0..<96 {
            let row = receipt(scope, inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased())
            XCTAssertTrue(store.save(row)); expected.append(row)
        }
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), expected)
        let summary = try String(contentsOf: root.appendingPathComponent(scope.task + ".jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(summary.count, 64); XCTAssertEqual(store.latest(), [expected.last!])
    }

    func testArchiveFailurePreservesSummaryAndExactRetryCompletesWithoutDuplicateJournal() throws {
        let root = try directory(), scope = Scope()
        var limits = WebsiteSessionCleanupStore.Limits(); limits.summaryRecords = 2
        let store = WebsiteSessionCleanupStore(directory: root, limits: limits), old = [legacy(scope.task), legacy(scope.task)]
        old.forEach { XCTAssertTrue(store.save($0)) }
        let summary = root.appendingPathComponent(scope.task + ".jsonl"), original = try Data(contentsOf: summary)
        let blocked = root.appendingPathComponent("legacy-archive")
        try Data("blocked".utf8).write(to: blocked)
        let closed = receipt(scope)
        XCTAssertFalse(store.save(closed)); XCTAssertEqual(try Data(contentsOf: summary), original)
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [closed])
        try FileManager.default.removeItem(at: blocked)
        XCTAssertTrue(store.save(closed)); XCTAssertTrue(store.save(closed))
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [closed])
        XCTAssertEqual(try store.archivedLegacyRecords(for: scope.task), [old[0]])
    }

    func testSummaryFailureAfterJournalWriteCanRecoverSameSavedReceipt() throws {
        let root = try directory(), scope = Scope(), store = WebsiteSessionCleanupStore(directory: root), closed = receipt(scope)
        let summary = root.appendingPathComponent(scope.task + ".jsonl")
        try FileManager.default.createDirectory(at: summary, withIntermediateDirectories: true)
        XCTAssertFalse(store.save(closed)); XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [closed])
        try FileManager.default.removeItem(at: summary)
        XCTAssertTrue(store.save(closed)); XCTAssertEqual(store.latest(), [closed])
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [closed])
    }

    func testFullSummaryCacheKeepsExactTransactionProofWithoutGrowingCacheOrAcceptingLegacy() throws {
        let root = try directory(), oldScope = Scope(), newScope = Scope()
        var limits = WebsiteSessionCleanupStore.Limits(); limits.summaryTasks = 1
        let store = WebsiteSessionCleanupStore(directory: root, limits: limits), old = legacy(oldScope.task)
        XCTAssertTrue(store.save(old))
        let originalSummary = try Data(contentsOf: root.appendingPathComponent(oldScope.task + ".jsonl"))
        let unresolved = receipt(newScope, outcome: .unconfirmed)
        XCTAssertTrue(store.save(unresolved)); XCTAssertTrue(store.save(unresolved))
        XCTAssertEqual(try store.transactionRecords(for: newScope.task, turnID: newScope.turn), [unresolved])
        XCTAssertTrue(store.latest().contains(unresolved), "A full cache cannot hide a retained lease")
        let closed = receipt(newScope)
        XCTAssertTrue(store.save(closed)); XCTAssertTrue(store.save(closed))
        XCTAssertEqual(try store.transactionRecords(for: newScope.task, turnID: newScope.turn), [unresolved, closed])
        XCTAssertEqual(Set(store.latest().map(\.attemptID)), Set([old.attemptID, closed.attemptID]))
        XCTAssertFalse(store.save(legacy(Scope().task)), "A legacy observation has no durable transaction proof")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(newScope.task + ".jsonl").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(oldScope.task + ".jsonl")), originalSummary)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.count, 1)
        let journal = journalFile(root, newScope), validJournal = try Data(contentsOf: journal)
        try Data("corrupt\n".utf8).write(to: journal)
        XCTAssertFalse(store.save(closed), "Cache capacity never excuses a corrupt durable proof")
        try validJournal.write(to: journal)
        limits.transactionRecords = 2
        XCTAssertFalse(WebsiteSessionCleanupStore(directory: root, limits: limits).save(receipt(newScope)),
            "The durable journal retains its finite record budget")
    }

    func testInferenceReleasesResponseWithFullDefaultSummaryCacheAndOneDurableClosure() async throws {
        let root = try directory(), store = WebsiteSessionCleanupStore(directory: root)
        for _ in 0..<256 { XCTAssertTrue(store.save(legacy(Scope().task))) }
        let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString, generation = UUID()
        let transport = CleanupReceiptTransport(), server = WebModelServer(), audit = CleanupReceiptAudit()
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport))
        await server.configureEvidenceDirectory(root.appendingPathComponent("evidence"))
        await server.configureCleanupReceipts(directory: root, runtimeGeneration: generation) { await audit.append($0) }
        let response = try await server.fixtureInfer(Data("{\"model\":\"browser/claude\",\"input\":\"Synthetic\",\"tools\":[]}".utf8),
            taskID: task, threadID: thread, turnID: turn, runtimeGeneration: generation)
        XCTAssertFalse(response.isEmpty)
        let observation = await audit.last(), closed = try XCTUnwrap(observation)
        XCTAssertTrue(closed.receiptSaved); XCTAssertEqual(closed.outcome, .closed)
        XCTAssertEqual(try store.transactionRecords(for: task.lowercased(), turnID: turn.lowercased()), [closed])
        let repeated = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
        XCTAssertEqual(repeated, closed)
        let calls = await transport.calls()
        XCTAssertEqual(calls.map(\.0), ["webProviderStart", "webProviderSend", "webProviderPoll", "webProviderFinish"])
        XCTAssertEqual(store.latest().count, 257)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.count, 256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(task.lowercased() + ".jsonl").path))
        _ = await server.shutdown()
    }

    func testArchiveCountBudgetFailsBeforeEvictingHistoricalProof() throws {
        let root = try directory(), scope = Scope()
        var limits = WebsiteSessionCleanupStore.Limits(); limits.summaryRecords = 2; limits.archiveRecords = 1
        let store = WebsiteSessionCleanupStore(directory: root, limits: limits), old = [legacy(scope.task), legacy(scope.task)]
        old.forEach { XCTAssertTrue(store.save($0)) }
        let first = receipt(scope)
        XCTAssertTrue(store.save(first))
        let file = root.appendingPathComponent(scope.task + ".jsonl"), before = try Data(contentsOf: file)
        let second = receipt(scope, inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased())
        XCTAssertFalse(store.save(second)); XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try store.archivedLegacyRecords(for: scope.task), [old[0]])
        limits.archiveRecords = 2
        let expandedStore = WebsiteSessionCleanupStore(directory: root, limits: limits)
        XCTAssertTrue(expandedStore.save(second))
        XCTAssertThrowsError(try store.archivedLegacyRecords(for: scope.task),
            "The original reader must continue to enforce its one-record archive budget")
        XCTAssertEqual(try expandedStore.archivedLegacyRecords(for: scope.task), old)
        XCTAssertTrue(expandedStore.save(second), "A persistence retry must not append either durable proof again")
        XCTAssertEqual(try expandedStore.archivedLegacyRecords(for: scope.task), old)
        XCTAssertEqual(try expandedStore.transactionRecords(for: scope.task, turnID: scope.turn), [first, second])
    }

    func testUnresolvedTransactionCannotBeMaskedByOtherClosureOrNoOwnedSession() throws {
        let root = try directory(), scope = Scope(), store = WebsiteSessionCleanupStore(directory: root)
        let unresolved = receipt(scope, outcome: .unconfirmed)
        XCTAssertTrue(store.save(unresolved))
        let other = receipt(scope, inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased())
        XCTAssertTrue(store.save(other)); let absent = legacy(scope.task); XCTAssertTrue(store.save(absent))
        XCTAssertEqual(store.latest(), [unresolved])
        let resolved = receipt(scope)
        XCTAssertTrue(store.save(resolved)); let laterAbsent = legacy(scope.task); XCTAssertTrue(store.save(laterAbsent))
        XCTAssertEqual(store.latest(), [laterAbsent])
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [unresolved, other, resolved])
    }

    func testArchiveByteBudgetsFailBeforeSummaryCompaction() throws {
        for globalBudget in [false, true] {
            let root = try directory(), scope = Scope(), old = legacy(scope.task)
            var limits = WebsiteSessionCleanupStore.Limits(); limits.summaryRecords = 1
            let bytes = try rowBytes(old) + 1
            if globalBudget { limits.archiveDirectoryBytes = bytes - 1 } else { limits.archiveBytes = bytes - 1 }
            let store = WebsiteSessionCleanupStore(directory: root, limits: limits)
            XCTAssertTrue(store.save(old))
            let summary = root.appendingPathComponent(scope.task + ".jsonl"), before = try Data(contentsOf: summary), closed = receipt(scope)
            XCTAssertFalse(store.save(closed)); XCTAssertEqual(try Data(contentsOf: summary), before)
            XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [closed])
            limits.archiveDirectoryBytes = bytes; limits.archiveBytes = bytes
            let repaired = WebsiteSessionCleanupStore(directory: root, limits: limits)
            XCTAssertTrue(repaired.save(closed)); XCTAssertEqual(try repaired.archivedLegacyRecords(for: scope.task), [old])
        }
    }

    func testEvictedUnconfirmedTransactionRemainsVisibleUntilThatSameLeaseCloses() throws {
        let root = try directory(), scope = Scope(), store = WebsiteSessionCleanupStore(directory: root)
        let unresolved = receipt(scope, outcome: .unconfirmed)
        XCTAssertTrue(store.save(unresolved))
        for _ in 0..<70 {
            XCTAssertTrue(store.save(receipt(scope, turn: UUID().uuidString.lowercased(),
                inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased())))
        }
        XCTAssertEqual(store.latest(), [unresolved])
        let closed = receipt(scope)
        XCTAssertTrue(store.save(closed)); XCTAssertEqual(store.latest(), [closed])
        XCTAssertEqual(try store.transactionRecords(for: scope.task, turnID: scope.turn), [unresolved, closed])
    }

    func testJournalRejectsUnknownFieldsPartialRowsAndSymlinkedScope() throws {
        let root = try directory(), scope = Scope(), store = WebsiteSessionCleanupStore(directory: root), row = receipt(scope)
        XCTAssertTrue(store.saveTransaction(row)); let file = journalFile(root, scope), original = try Data(contentsOf: file)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        raw["pageText"] = "PRIVATE_REPLY_CANARY"
        var corrupt = try JSONSerialization.data(withJSONObject: raw); corrupt.append(0x0A)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try store.transactionRecords(for: scope.task, turnID: scope.turn)); XCTAssertFalse(store.saveTransaction(row))
        try original.dropLast().write(to: file)
        XCTAssertThrowsError(try store.transactionRecords(for: scope.task, turnID: scope.turn))
        try FileManager.default.removeItem(at: file)
        let outside = root.appendingPathComponent("outside"); try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try store.transactionRecords(for: scope.task, turnID: scope.turn)); XCTAssertFalse(store.saveTransaction(row))
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testJournalReaderRejectsContradictoryInferenceLinkageEvenWithValidIndividualRows() throws {
        let root = try directory(), scope = Scope(), store = WebsiteSessionCleanupStore(directory: root), first = receipt(scope)
        XCTAssertTrue(store.saveTransaction(first))
        let different = receipt(scope, token: UUID().uuidString.lowercased())
        XCTAssertTrue(different.isValid)
        var bytes = try Data(contentsOf: journalFile(root, scope)); bytes.append(try JSONEncoder().encode(different)); bytes.append(0x0A)
        try bytes.write(to: journalFile(root, scope))
        XCTAssertThrowsError(try store.transactionRecords(for: scope.task, turnID: scope.turn))
        XCTAssertFalse(store.saveTransaction(receipt(scope, inference: UUID().uuidString.lowercased(), token: UUID().uuidString.lowercased())))
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
    func testActualBundledEngineRestartPreservesCookieStartupFailureWithoutSendingOrClaimingCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ComputaCookieStartupRestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let modelID = choice.modelID
        XCTAssertEqual(WebsiteModelCatalog.choice(for: modelID), choice)
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = modelID
        config.codexHomePath = root.appendingPathComponent("PrivateHome").path
        config.workspacePath = root.appendingPathComponent("Workspace").path
        config.protocolTracePath = root.appendingPathComponent("first-protocol.jsonl").path
        let prompt = "Synthetic local ChatGPT profile startup failure. Do not use tools."
        let taskID = UUID().uuidString, first = CodexAppServerRuntime(configuration: config)
        let transport = CleanupCookieStartupFailureTransport(), audit = CleanupRuntimeAudit(taskID: taskID)
        let observer = Task { for await event in first.events() { audit.receive(event) } }
        defer { observer.cancel() }
        await first.configureEmbeddedWebModelTransport(transport)
        do {
            _ = try await first.loadTasks()
            try await first.submit(prompt: prompt, toTaskID: taskID, modelID: modelID)
            let deadline = ContinuousClock.now + .seconds(45)
            while audit.status != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .failed)
            XCTAssertEqual(audit.errors.count, 1)
            let original = try XCTUnwrap(audit.errors.first)
            let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
            let originalError = try XCTUnwrap(originalObject["error"] as? [String: Any])
            XCTAssertEqual(originalError["code"] as? String, "chatgpt_profile_preparation_failed")
            XCTAssertEqual(originalError["reason"] as? String, "verification_failed")
            XCTAssertEqual(originalError["message"] as? String,
                "The private ChatGPT browser profile could not be verified. No prompt was replayed.")
            XCTAssertEqual(originalError["retryable"] as? Bool, false)
            XCTAssertEqual(originalError["type"] as? String, "model_error")
            XCTAssertNil(originalError["required_action"])
            XCTAssertFalse(original.contains("high demand"))
            let pending = try XCTUnwrap(audit.receipts.first { $0.outcome == .unconfirmed })
            XCTAssertEqual(pending.schemaVersion, 3)
            XCTAssertTrue(pending.isStartupAttemptLinked); XCTAssertTrue(pending.receiptSaved)
            XCTAssertEqual(pending.reason, .cleanupUnverified)
            XCTAssertEqual(pending.provider, .chatgpt); XCTAssertEqual(pending.modelID, modelID)
            XCTAssertNil(pending.sessionToken, "A pre-token failure cannot establish an owned website session")
            XCTAssertFalse(audit.receipts.contains { $0.outcome == .closed })
            let threadID = try XCTUnwrap(pending.threadID), turnID = try XCTUnwrap(pending.turnID)
            let cleanupDirectory = URL(fileURLWithPath: config.codexHomePath).appendingPathComponent("WebsiteSessionCleanup-v1")
            XCTAssertTrue(WebsiteSessionCleanupStore(directory: cleanupDirectory).latest().contains(pending))
            _ = await first.shutdown()
            let firstWire = try AppServerWireTrace.load(root.appendingPathComponent("first-protocol.jsonl"))
            XCTAssertTrue(firstWire.parseFailures.isEmpty)
            XCTAssertEqual(firstWire.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }.count, 1)
            XCTAssertFalse(firstWire.messages.contains { $0.method == "item/tool/call" })
            let calls = await transport.calls()
            XCTAssertEqual(calls.map(\.operation), ["webProviderStart"], "Cookie preparation cannot submit, retry, poll or manufacture cleanup")
            XCTAssertEqual(calls.first?.parameters["provider"], "chatgpt")
            XCTAssertEqual(calls.first?.parameters["modelChoice"], choice.canonicalJSONString)

            var reloadConfig = config
            reloadConfig.protocolTracePath = root.appendingPathComponent("reload-protocol.jsonl").path
            let reloadedRuntime = CodexAppServerRuntime(configuration: reloadConfig), inert = CleanupReceiptTransport()
            await reloadedRuntime.configureEmbeddedWebModelTransport(inert)
            do {
                let tasks = try await reloadedRuntime.loadTasks()
                let restored = try XCTUnwrap(tasks.first { $0.id == threadID })
                XCTAssertEqual(restored.status, .failed)
                XCTAssertEqual(restored.model, modelID)
                XCTAssertEqual(restored.entries.filter { $0.kind == .user }.map(\.body), [prompt])
                XCTAssertFalse(restored.entries.contains { $0.kind == .assistant })
                let errors = restored.entries.filter { $0.title == "Agent error" }
                XCTAssertEqual(errors.count, 1)
                let restoredError = try XCTUnwrap(errors.first)
                XCTAssertEqual(restoredError.turnID, turnID)
                let restoredObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(restoredError.body.utf8)) as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: restoredObject).isEqual(to: originalObject))
                let failures = try WebsiteTurnFailureStore(directory: URL(fileURLWithPath: config.codexHomePath)
                    .appendingPathComponent("WebsiteTurnFailureStore-v1")).load(threadID: threadID)
                XCTAssertEqual(failures.count, 1); XCTAssertEqual(failures.first?.turnID, turnID)
                XCTAssertEqual(failures.first?.modelID, modelID)
                let cleanup = WebsiteSessionCleanupStore(directory: cleanupDirectory)
                XCTAssertTrue(cleanup.latest().contains(pending), "Cold reload cannot turn unknown startup ownership into closed")
                XCTAssertEqual(try cleanup.transactionRecords(for: pending.taskID, turnID: turnID), [pending])
                let reloadedCalls = await inert.calls()
                XCTAssertTrue(reloadedCalls.isEmpty, "Restoring this failure must not invoke a website operation")
                _ = await reloadedRuntime.shutdown()
                let reloadWire = try AppServerWireTrace.load(root.appendingPathComponent("reload-protocol.jsonl"))
                XCTAssertTrue(reloadWire.parseFailures.isEmpty)
                XCTAssertFalse(reloadWire.messages.contains { $0.direction == .clientToServer && $0.method == "turn/start" })
                XCTAssertFalse(reloadWire.messages.contains { $0.method == "item/tool/call" })
                XCTAssertTrue(cleanup.latest().contains(pending))
            } catch { _ = await reloadedRuntime.shutdown(); throw error }
        } catch { _ = await first.shutdown(); throw error }
    }

    func testActualBundledEngineRestartPreservesPageInspectionFailureWithoutReplaying() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ComputaInspectionRestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = "browser/claude"
        config.codexHomePath = root.appendingPathComponent("PrivateHome").path
        config.workspacePath = root.appendingPathComponent("Workspace").path
        config.protocolTracePath = root.appendingPathComponent("first-protocol.jsonl").path
        let prompt = "Synthetic café 🧭 inspection failure. Do not use tools."
        let taskID = UUID().uuidString, first = CodexAppServerRuntime(configuration: config)
        let transport = CleanupReceiptTransport(pageUnavailableOnPoll: true), audit = CleanupRuntimeAudit(taskID: taskID)
        let observer = Task { for await event in first.events() { audit.receive(event) } }
        defer { observer.cancel() }
        await first.configureEmbeddedWebModelTransport(transport)
        do {
            _ = try await first.loadTasks()
            try await first.submit(prompt: prompt, toTaskID: taskID, modelID: "browser/claude")
            let deadline = ContinuousClock.now + .seconds(45)
            while audit.status != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .failed)
            let original = try XCTUnwrap(audit.errors.last)
            let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
            let originalError = try XCTUnwrap(originalObject["error"] as? [String: Any])
            XCTAssertEqual(originalError["code"] as? String, "browser_model_error")
            XCTAssertEqual(originalError["message"] as? String, EmbeddedWebModelTransport.Failure.pageUnavailable.localizedDescription)
            XCTAssertNil(originalError["retryable"])
            let automatic = try XCTUnwrap(audit.receipts.first { $0.trigger == .automatic && $0.outcome == .closed })
            let threadID = try XCTUnwrap(automatic.threadID), turnID = try XCTUnwrap(automatic.turnID)
            _ = await first.shutdown()
            let firstWire = try AppServerWireTrace.load(root.appendingPathComponent("first-protocol.jsonl"))
            XCTAssertTrue(firstWire.parseFailures.isEmpty)
            XCTAssertFalse(firstWire.messages.contains { $0.direction == .clientToServer && $0.method == "thread/name/set" })
            var reloadConfig = config; reloadConfig.protocolTracePath = root.appendingPathComponent("reload-protocol.jsonl").path
            let reloadedRuntime = CodexAppServerRuntime(configuration: reloadConfig), inert = CleanupReceiptTransport()
            await reloadedRuntime.configureEmbeddedWebModelTransport(inert)
            do {
                let tasks = try await reloadedRuntime.loadTasks()
                let restored = try XCTUnwrap(tasks.first { $0.id == threadID })
                XCTAssertEqual(restored.status, .failed)
                XCTAssertEqual(restored.title, prompt)
                XCTAssertEqual(restored.model, "browser/claude")
                XCTAssertEqual(restored.entries.filter { $0.kind == .user }.map(\.body), [prompt])
                XCTAssertEqual(restored.entries.first { $0.kind == .user }?.turnID, turnID)
                XCTAssertFalse(restored.title.contains("APP_RUNTIME_INTERACTION_POLICY"))
                XCTAssertFalse(restored.entries.contains { $0.kind == .assistant })
                let errors = restored.entries.filter { $0.title == "Agent error" }
                XCTAssertEqual(errors.count, 1)
                let error = try XCTUnwrap(errors.first); XCTAssertEqual(error.turnID, turnID)
                let restoredObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(error.body.utf8)) as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: restoredObject).isEqual(to: originalObject))
                XCTAssertFalse(error.body.contains("high demand"))
                let saved = try WebsiteTurnFailureStore(directory: URL(fileURLWithPath: config.codexHomePath)
                    .appendingPathComponent("WebsiteTurnFailureStore-v1")).load(threadID: threadID)
                XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved.first?.turnID, turnID)
                let reloadedCalls = await inert.calls()
                XCTAssertTrue(reloadedCalls.isEmpty, "Loading failed history cannot invoke any website operation")
                _ = await reloadedRuntime.shutdown()
                try assertUnnamedWebsiteThreadMetadata(in: root.appendingPathComponent("reload-protocol.jsonl"), threadID: threadID)
                let reloadWire = try AppServerWireTrace.load(root.appendingPathComponent("reload-protocol.jsonl"))
                XCTAssertFalse(reloadWire.messages.contains { $0.direction == .clientToServer && $0.method == "turn/start" })
            } catch { _ = await reloadedRuntime.shutdown(); throw error }
            let calls = await transport.calls()
            XCTAssertEqual(calls.filter { $0.0 == "webProviderSend" }.count, 1)
        } catch { _ = await first.shutdown(); throw error }
    }

    func testActualBundledEngineKeepsFirstLongUnicodeTitleAcrossLaterTurnAndColdRestartWithoutNamingRPC() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ComputaUnnamedTitleRestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = "browser/claude"
        config.codexHomePath = root.appendingPathComponent("PrivateHome").path
        config.workspacePath = root.appendingPathComponent("Workspace").path
        config.protocolTracePath = root.appendingPathComponent("first-protocol.jsonl").path
        let firstPrompt = String(repeating: "航🧭é ", count: 24) + "Only return OK. Do not use tools."
        let expectedTitle = String(firstPrompt.prefix(72)).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondPrompt = "Second synthetic turn. Only return OK. Do not use tools."
        let taskID = UUID().uuidString, runtime = CodexAppServerRuntime(configuration: config)
        let firstTransport = CleanupReceiptTransport(), secondTransport = CleanupReceiptTransport()
        let audit = CleanupRuntimeAudit(taskID: taskID)
        let observer = Task { for await event in runtime.events() { audit.receive(event) } }
        defer { observer.cancel() }
        await runtime.configureEmbeddedWebModelTransport(firstTransport)
        do {
            _ = try await runtime.loadTasks()
            try await runtime.submit(prompt: firstPrompt, toTaskID: taskID, modelID: "browser/claude")
            let firstDeadline = ContinuousClock.now + .seconds(45)
            while (audit.status != .completed || !audit.receipts.contains { $0.trigger == .inference && $0.outcome == .closed }),
                  ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .completed)
            let firstReceipt = try XCTUnwrap(audit.receipts.first { $0.trigger == .inference && $0.outcome == .closed })
            let threadID = try XCTUnwrap(firstReceipt.threadID), firstTurnID = try XCTUnwrap(firstReceipt.turnID)
            let firstTasks = try await runtime.loadTasks()
            let afterFirst = try XCTUnwrap(firstTasks.first { $0.id == taskID })
            XCTAssertEqual(afterFirst.title, expectedTitle)
            XCTAssertEqual(afterFirst.entries.filter { $0.kind == .user }.map(\.body), [firstPrompt])
            XCTAssertEqual(afterFirst.entries.first { $0.kind == .user }?.turnID, firstTurnID)
            // A later real turn gets a new deterministic website session. Its
            // text cannot replace the first visible user's saved display title.
            await runtime.configureEmbeddedWebModelTransport(secondTransport)
            audit.status = nil
            try await runtime.submit(prompt: secondPrompt, toTaskID: taskID, modelID: "browser/claude")
            let secondDeadline = ContinuousClock.now + .seconds(45)
            while (audit.status != .completed || !audit.receipts.contains {
                $0.trigger == .inference && $0.outcome == .closed && $0.turnID != firstTurnID
            }), ContinuousClock.now < secondDeadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .completed)
            XCTAssertTrue(audit.errors.isEmpty)
            let secondReceipt = try XCTUnwrap(audit.receipts.first {
                $0.trigger == .inference && $0.outcome == .closed && $0.turnID != firstTurnID
            })
            XCTAssertEqual(secondReceipt.threadID, threadID)
            let secondTurnID = try XCTUnwrap(secondReceipt.turnID)
            let currentTasks = try await runtime.loadTasks()
            let current = try XCTUnwrap(currentTasks.first { $0.id == taskID })
            XCTAssertEqual(current.title, expectedTitle)
            XCTAssertEqual(current.entries.filter { $0.kind == .user }.map(\.body), [firstPrompt, secondPrompt])
            XCTAssertEqual(current.entries.filter { $0.kind == .user }.compactMap(\.turnID), [firstTurnID, secondTurnID])
            _ = await runtime.shutdown()
            let firstTrace = root.appendingPathComponent("first-protocol.jsonl")
            try assertUnnamedWebsiteThreadMetadata(in: firstTrace, threadID: threadID)
            let firstWire = try AppServerWireTrace.load(firstTrace)
            XCTAssertEqual(firstWire.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }.count, 2)
            var reloadConfig = config
            reloadConfig.protocolTracePath = root.appendingPathComponent("reload-protocol.jsonl").path
            let cold = CodexAppServerRuntime(configuration: reloadConfig), inert = CleanupReceiptTransport()
            await cold.configureEmbeddedWebModelTransport(inert)
            do {
                let restoredTasks = try await cold.loadTasks()
                let restored = try XCTUnwrap(restoredTasks.first { $0.id == threadID })
                XCTAssertEqual(restored.title, expectedTitle)
                XCTAssertEqual(restored.status, .completed)
                XCTAssertEqual(restored.model, "browser/claude")
                XCTAssertEqual(restored.entries.filter { $0.kind == .user }.map(\.body), [firstPrompt, secondPrompt])
                XCTAssertEqual(restored.entries.filter { $0.kind == .user }.compactMap(\.turnID), [firstTurnID, secondTurnID])
                let reloadCalls = await inert.calls(); XCTAssertTrue(reloadCalls.isEmpty)
                _ = await cold.shutdown()
                let reloadTrace = root.appendingPathComponent("reload-protocol.jsonl")
                try assertUnnamedWebsiteThreadMetadata(in: reloadTrace, threadID: threadID)
                let reloadWire = try AppServerWireTrace.load(reloadTrace)
                XCTAssertFalse(reloadWire.messages.contains { $0.direction == .clientToServer && $0.method == "turn/start" })
            } catch { _ = await cold.shutdown(); throw error }
            let firstCalls = await firstTransport.calls(), secondCalls = await secondTransport.calls()
            XCTAssertEqual(firstCalls.filter { $0.0 == "webProviderSend" }.count, 1)
            XCTAssertEqual(secondCalls.filter { $0.0 == "webProviderSend" }.count, 1)
        } catch { _ = await runtime.shutdown(); throw error }
    }

    private func assertUnnamedWebsiteThreadMetadata(in traceURL: URL, threadID: String,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let wire = try AppServerWireTrace.load(traceURL)
        XCTAssertTrue(wire.parseFailures.isEmpty, file: file, line: line)
        XCTAssertFalse(wire.messages.contains { $0.direction == .clientToServer && $0.method == "thread/name/set" },
            "Automatic titles cannot issue a metadata RPC before initial thread persistence", file: file, line: line)
        let listed = wire.messages.filter { $0.direction == .serverToClient }
            .compactMap { $0.object["result"] as? [String: Any] }
            .flatMap { $0["data"] as? [[String: Any]] ?? [] }
            .filter { $0["id"] as? String == threadID }
        let record = try XCTUnwrap(listed.last, "Native thread/list must retain the website thread", file: file, line: line)
        XCTAssertEqual(record["modelProvider"] as? String, "web_browser", file: file, line: line)
        XCTAssertEqual(record["source"] as? String, "vscode", file: file, line: line)
        XCTAssertEqual(record["model"] as? String, "browser/claude", file: file, line: line)
        XCTAssertFalse((record["cwd"] as? String ?? "").isEmpty, file: file, line: line)
        XCTAssertFalse((record["cliVersion"] as? String ?? "").isEmpty, file: file, line: line)
        XCTAssertTrue(record["name"] == nil || record["name"] is NSNull, file: file, line: line)
    }

    func testActualBundledEngineRestartRestoresTypedFailureThenHistoricalGenericFailureWithoutReplaying() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ComputaFailureRestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .bundled; config.model = "browser/claude"
        config.codexHomePath = root.appendingPathComponent("PrivateHome").path
        config.workspacePath = root.appendingPathComponent("Workspace").path
        config.protocolTracePath = root.appendingPathComponent("first-protocol.jsonl").path
        let taskID = UUID().uuidString, first = CodexAppServerRuntime(configuration: config)
        let transport = CleanupReceiptTransport(malformedReply: true), audit = CleanupRuntimeAudit(taskID: taskID)
        let observer = Task { for await event in first.events() { audit.receive(event) } }
        defer { observer.cancel() }
        await first.configureEmbeddedWebModelTransport(transport)
        do {
            _ = try await first.loadTasks()
            try await first.submit(prompt: "Synthetic failed restart fixture. Do not use tools.", toTaskID: taskID, modelID: "browser/claude")
            let deadline = ContinuousClock.now + .seconds(45)
            while audit.status != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .failed)
            let original = try XCTUnwrap(audit.errors.last)
            XCTAssertTrue(original.contains("malformed_website_reply")); XCTAssertTrue(original.contains("invalid_json"))
            let automatic = try XCTUnwrap(audit.receipts.first { $0.trigger == .automatic && $0.outcome == .closed })
            let threadID = try XCTUnwrap(automatic.threadID), turnID = try XCTUnwrap(automatic.turnID)
            _ = await first.shutdown()
            let storedFile = URL(fileURLWithPath: config.codexHomePath).appendingPathComponent("WebsiteTurnFailureStore-v1").appendingPathComponent(threadID + ".json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: storedFile.path))
            for typedStorePresent in [true, false] {
                if !typedStorePresent { try FileManager.default.removeItem(at: storedFile) }
                var reloadConfig = config; reloadConfig.protocolTracePath = root.appendingPathComponent(typedStorePresent ? "typed-reload.jsonl" : "historical-reload.jsonl").path
                let reloadedRuntime = CodexAppServerRuntime(configuration: reloadConfig), inert = CleanupReceiptTransport()
                await reloadedRuntime.configureEmbeddedWebModelTransport(inert)
                do {
                    let tasks = try await reloadedRuntime.loadTasks()
                    let restored = try XCTUnwrap(tasks.first { $0.id == threadID })
                    XCTAssertEqual(restored.status, .failed, "An actual process restart cannot change a recorded failed turn to Completed")
                    XCTAssertEqual(restored.model, "browser/claude")
                    XCTAssertTrue(restored.entries.contains { $0.kind == .user && $0.body == "Synthetic failed restart fixture. Do not use tools." })
                    XCTAssertFalse(restored.entries.contains { $0.kind == .assistant })
                    let error = try XCTUnwrap(restored.entries.last { $0.title == "Agent error" })
                    XCTAssertEqual(error.turnID, turnID)
                    if typedStorePresent {
                        let restoredError = try JSONSerialization.jsonObject(with: Data(error.body.utf8)) as! [String: Any]
                        let originalError = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! [String: Any]
                        XCTAssertTrue(NSDictionary(dictionary: restoredError).isEqual(to: originalError))
                    }
                    else {
                        XCTAssertEqual(error.body, "We’re currently experiencing high demand, which may cause temporary errors.")
                        XCTAssertFalse(error.body.contains("malformed_website_reply"))
                    }
                    let absent = await reloadedRuntime.retryWebsiteSessionCleanup(taskID: threadID)
                    XCTAssertEqual(absent.outcome, .noOwnedSession); XCTAssertEqual(absent.threadID, threadID)
                    XCTAssertEqual(absent.turnID, turnID); XCTAssertNil(absent.provider)
                    let calls = await inert.calls(); XCTAssertTrue(calls.isEmpty)
                    _ = await reloadedRuntime.shutdown()
                } catch { _ = await reloadedRuntime.shutdown(); throw error }
            }
            let calls = await transport.calls()
            XCTAssertEqual(calls.filter { $0.0 == "webProviderSend" }.count, 1)
        } catch { _ = await first.shutdown(); throw error }
    }

    func testCompletionOnlyNativeHTTPFailurePersistsBeforeCleanupAndSurvivesFreshRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaCompletionOnly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WebsiteFailureCompletionAppServer.ts")
        let fixture = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: source, to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .fixture(path: fixture.path); config.codexHomePath = root.path; config.workspacePath = root.path; config.model = "browser/claude"
        let taskID = UUID().uuidString, runtime = CodexAppServerRuntime(configuration: config)
        let transport = CleanupReceiptTransport(malformedReply: true), audit = CleanupRuntimeAudit(taskID: taskID)
        let observer = Task { for await event in runtime.events() { audit.receive(event) } }
        defer { observer.cancel() }
        await runtime.configureEmbeddedWebModelTransport(transport)
        do {
            _ = try await runtime.loadTasks()
            try await runtime.submit(prompt: "Completion-only fixture prompt", toTaskID: taskID, modelID: "browser/claude")
            let deadline = ContinuousClock.now + .seconds(15)
            while audit.status != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .failed)
            XCTAssertEqual(audit.errors.count, 1)
            XCTAssertTrue(audit.errors.first?.contains("malformed_website_reply") == true)
            _ = await runtime.shutdown()
            let fresh = CodexAppServerRuntime(configuration: config), inert = CleanupReceiptTransport()
            await fresh.configureEmbeddedWebModelTransport(inert)
            do {
                let restoredTasks = try await fresh.loadTasks()
                let restored = try XCTUnwrap(restoredTasks.first)
                XCTAssertEqual(restored.status, .failed)
                XCTAssertEqual(restored.entries.filter { $0.title == "Agent error" }.count, 1)
                XCTAssertTrue(restored.entries.last?.body.contains("malformed_website_reply") == true)
                let saved = try WebsiteTurnFailureStore(directory: root.appendingPathComponent("WebsiteTurnFailureStore-v1")).load(threadID: restored.id)
                XCTAssertEqual(saved.count, 1)
                let calls = await inert.calls(); XCTAssertTrue(calls.isEmpty)
                _ = await fresh.shutdown()
            } catch { _ = await fresh.shutdown(); throw error }
            let calls = await transport.calls()
            XCTAssertEqual(calls.filter { $0.0 == "webProviderSend" }.count, 1)
        } catch { _ = await runtime.shutdown(); throw error }
    }

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
            while audit.status != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .failed)
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
        } catch { await gate.releaseForTeardown(); _ = await runtime.shutdown(); throw error }
    }
}

@MainActor
private final class CleanupRuntimeAudit {
    let taskID: String
    var status: TaskStatus?
    var receipts: [WebsiteSessionCleanupReceipt] = []
    var errors: [String] = []
    init(taskID: String) { self.taskID = taskID }
    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case .taskStatusChanged(let task, let value) where task == taskID: status = value
        case .websiteSessionCleanupUpdated(let receipt): receipts.append(receipt)
        case .timelineEntryAppended(let task, let entry) where task == taskID && entry.title == "Agent error": errors.append(entry.body)
        default: break
        }
    }
}

private actor CleanupReceiptGate {
    private var entered = false
    private var tearingDown = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        guard !tearingDown else { return }
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { enteredWaiter = $0 } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func releaseForTeardown() { tearingDown = true; release() }
}

private actor CleanupBlockedStartTransport: WebModelTransport {
    private var operations: [String] = []
    func calls() -> [String] { operations }
    func request(operation: String, params: Data) async throws -> Data {
        operations.append(operation)
        guard operation == "webProviderStart" else { throw WebModelServer.Failure.invalidRequest }
        throw EmbeddedWebModelTransport.Failure.humanVerificationRequired(.gemini)
    }
}

private actor CleanupCookieStartupFailureTransport: WebModelTransport {
    struct Call: Sendable {
        let operation: String
        let parameters: [String: String]
    }
    private var operations: [Call] = []
    func calls() -> [Call] { operations }
    func request(operation: String, params: Data) async throws -> Data {
        let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: String])
        operations.append(Call(operation: operation, parameters: parameters))
        guard operation == "webProviderStart" else { throw WebModelServer.Failure.invalidRequest }
        throw ChatGPTInferenceCookieSeed.Failure.verificationFailed
    }
}

private actor CleanupReceiptTransport: WebModelTransport {
    private let ownedToken = UUID().uuidString
    private let documentGeneration = UUID().uuidString.lowercased()
    private var operations: [(String, String)] = []
    private var failFirstCleanup: Bool
    private let cleanupGate: CleanupReceiptGate?
    private let malformedReply: Bool
    private let pageUnavailableOnPoll: Bool
    init(failFirstCleanup: Bool = false, cleanupGate: CleanupReceiptGate? = nil, malformedReply: Bool = false,
         pageUnavailableOnPoll: Bool = false) {
        self.failFirstCleanup = failFirstCleanup; self.cleanupGate = cleanupGate; self.malformedReply = malformedReply
        self.pageUnavailableOnPoll = pageUnavailableOnPoll
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
            case "webProviderPoll":
                if pageUnavailableOnPoll { throw EmbeddedWebModelTransport.Failure.pageUnavailable }
                result = ["state": "complete", "text": malformedReply ? #"{"type":"tool_calls","calls":["# : "{\"type\":\"message\",\"text\":\"OK\"}"]
            case "webProviderFinish", "webProviderCancel":
                if failFirstCleanup { failFirstCleanup = false; result = ["cleanup": "failed", "error": ["message": "PRIVATE_REPLY_CANARY"]] }
                else { await cleanupGate?.pause(); result = ["cleanup": "deleted"] }
            default: throw WebModelServer.Failure.invalidRequest
            }
        }
        var snapshot = syntheticPreparedWebsiteSnapshot(result)
        if ["running", "complete"].contains(snapshot["state"] as? String ?? "") {
            snapshot["sessionToken"] = ownedToken; snapshot["sequence"] = 1
            snapshot["modelProofContext"] = ["documentGeneration": documentGeneration, "sequence": 1,
                "baselineResponseCount": 0, "responseCount": snapshot["state"] as? String == "complete" ? 1 : 0,
                "firstUserFingerprint": String(repeating: "a", count: 64)]
        }
        return try JSONSerialization.data(withJSONObject: snapshot)
    }
}

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
        let closed = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
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
            while audit.status != .waiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .waiting)
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
                    XCTAssertEqual(restored.status, .waiting, "An actual process restart cannot change a recorded failed turn to Completed")
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
            while audit.status != .waiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(audit.status, .waiting)
            XCTAssertEqual(audit.errors.count, 1)
            XCTAssertTrue(audit.errors.first?.contains("malformed_website_reply") == true)
            _ = await runtime.shutdown()
            let fresh = CodexAppServerRuntime(configuration: config), inert = CleanupReceiptTransport()
            await fresh.configureEmbeddedWebModelTransport(inert)
            do {
                let restoredTasks = try await fresh.loadTasks()
                let restored = try XCTUnwrap(restoredTasks.first)
                XCTAssertEqual(restored.status, .waiting)
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
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; enteredWaiter?.resume(); enteredWaiter = nil; await withCheckedContinuation { releaseWaiter = $0 } }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { enteredWaiter = $0 } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor CleanupReceiptTransport: WebModelTransport {
    private let ownedToken = UUID().uuidString
    private let documentGeneration = UUID().uuidString.lowercased()
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

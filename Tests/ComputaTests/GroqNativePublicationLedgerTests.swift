import Foundation
import XCTest
@testable import Computa

final class GroqNativePublicationLedgerTests: XCTestCase {
    private typealias L = GroqNativePublicationLedger
    private let args = Data(#"{"cmd":"fixture"}"#.utf8)
    private let rawOutput = Data(#"[{"type":"input_text","text":"A\u002DB\nquoted \"value\""}]"#.utf8)

    private func scope(task: String = "20000000-0000-4000-8000-000000000001", thread: String = "20000000-0000-4000-8000-000000000003",
        turn: String = "20000000-0000-4000-8000-000000000002", model: String = "native-groq-fixture",
        runtime: UUID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
        preparation: UUID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
        core: UUID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!) -> L.Scope {
        .init(taskID: task, threadID: thread, turnID: turn,
            runtimeGeneration: runtime, preparationID: preparation,
            modelID: model, coreGeneration: core)
    }
    private func binding(_ value: L.Scope? = nil, transport: UUID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!) -> L.Binding {
        .init(scope: value ?? scope(), transportGeneration: transport)
    }
    private func issued(_ kind: L.Kind = .execCommand, id: String = "call-A", bytes: Data? = nil,
        namespace: String? = nil) -> L.IssuedCall {
        .init(callID: id, kind: kind, name: kind == .execCommand ? "exec_command" : "apply_patch",
            namespace: namespace, argumentUTF8: bytes ?? args)
    }
    private func history(_ call: L.IssuedCall, output: Data? = nil) throws -> L.ValidatedHistory {
        // Synthetic authenticated-boundary fixture. Exact Data slices, no
        // production scanner or server is bypassed by this standalone unit.
        let token = try JSONSerialization.data(withJSONObject: String(decoding: call.argumentUTF8, as: UTF8.self), options: [.fragmentsAllowed])
        let custom = call.kind == .applyPatch
        var callMetadata = ["type": custom ? "custom_tool_call" : "function_call", "call_id": call.callID, "name": call.name]
        if let namespace = call.namespace { callMetadata["namespace"] = namespace }
        var encodedCall = try JSONSerialization.data(withJSONObject: callMetadata, options: [.sortedKeys])
        var encodedOutput = try JSONSerialization.data(withJSONObject: ["type": custom ? "custom_tool_call_output" : "function_call_output", "call_id": call.callID], options: [.sortedKeys])
        encodedCall.removeLast(); encodedOutput.removeLast()
        let prefix = Data("{\"input\":[".utf8) + encodedCall + Data((custom ? ",\"input\":" : ",\"arguments\":").utf8)
        let middle = Data("},".utf8) + encodedOutput + Data(",\"output\":".utf8)
        let value = output ?? rawOutput
        let source = prefix + token + middle + value + Data("}]}".utf8)
        _ = try JSONSerialization.jsonObject(with: source)
        let start = prefix.count, outputStart = prefix.count + token.count + middle.count
        return .init(sourceUTF8: source, pairs: [.init(callID: call.callID, kind: call.kind,
            name: call.name, namespace: call.namespace, argumentUTF8: call.argumentUTF8,
            argumentValueRange: start..<(start + token.count), outputValueRange: outputStart..<(outputStart + value.count))])
    }
    private func complete(_ ledger: L, _ writer: L.CompletionWriter, _ current: L.Binding, _ call: L.IssuedCall) {
        let end: L.Terminal = call.kind == .execCommand ? .command(status: .completed, exitCode: 0) : .patch(status: .completed)
        XCTAssertTrue(writer.recordCompleted(current: current.scope, itemID: call.callID, terminal: end))
    }
    private func stage(_ ledger: L, _ authority: L.ServerAuthority, _ handle: L.ScopeHandle,
        _ current: L.Binding, _ calls: [L.IssuedCall], response: String = "resp-A") throws -> L.Ticket {
        try ledger.stageIssuedResponse(authority, scope: handle, current: current,
            responseID: response, encodedResponseSHA256: String(repeating: "a", count: 64), calls: calls)
    }

    func testCompletionBeforeHTTPAckRemainsInlineThenPublishesActualTokens() throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (handle, writer) = try ledger.installScope(authority, binding: current)
        let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
        complete(ledger, writer, current, call)
        let actual = try history(call)
        XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: actual).isEmpty)
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current))
        let pairs = ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: actual)
        let pair = try XCTUnwrap(pairs.first); XCTAssertEqual(pairs.count, 1)
        let out = try XCTUnwrap(ledger.literal(authority, publication: pair, current: current, field: .output))
        XCTAssertEqual(out.rawJSONValue, rawOutput); XCTAssertEqual(out.byteCount, rawOutput.count)
        XCTAssertEqual(out.sha256.count, 64)
        XCTAssertEqual(out.scope, current.scope); XCTAssertEqual(out.name, "exec_command"); XCTAssertNil(out.namespace)
        XCTAssertEqual(out.valueRange, actual.pairs[0].outputValueRange)
        XCTAssertEqual(ledger.literal(authority, publication: pair, current: current, field: .arguments)?.rawJSONValue,
            actual.sourceUTF8.subdata(in: actual.pairs[0].argumentValueRange))
        XCTAssertNil(ledger.literal(authority, publication: pair, current: current, field: .input))
    }

    func testHTTPAckWithoutTypedCompletionAndUnknownEarlierCompletionCannotPublish() throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (handle, writer) = try ledger.installScope(authority, binding: current)
        let call = issued()
        XCTAssertFalse(writer.recordCompleted(current: current.scope, itemID: call.callID,
            terminal: .command(status: .completed, exitCode: 0)))
        let ticket = try stage(ledger, authority, handle, current, [call])
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current))
        XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: try history(call)).isEmpty)
        complete(ledger, writer, current, call)
        XCTAssertEqual(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: try history(call)).count, 1)
    }

    func testPatchUsesWholeInputAndLiteralActualHTTPOutputWithoutStdoutProof() throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (handle, writer) = try ledger.installScope(authority, binding: current)
        let patch = Data("*** Begin Patch\n*** End Patch\n".utf8), call = issued(.applyPatch, bytes: patch)
        let ticket = try stage(ledger, authority, handle, current, [call])
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
        let actualOutput = Data(#""This exact HTTP value is not compared with aggregatedOutput or stdout.""#.utf8)
        let pair = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: handle, current: current,
            history: history(call, output: actualOutput)).first)
        XCTAssertEqual(ledger.literal(authority, publication: pair, current: current, field: .output)?.rawJSONValue, actualOutput)
        XCTAssertNotNil(ledger.literal(authority, publication: pair, current: current, field: .input))
        XCTAssertNil(ledger.literal(authority, publication: pair, current: current, field: .arguments))
    }

    func testFailedDeclinedUncertainAndWrongKindRemainInline() throws {
        let terminals: [L.Terminal] = [.command(status: .failed, exitCode: 1), .command(status: .completed, exitCode: 1),
            .command(status: .completed, exitCode: nil), .command(status: .declined, exitCode: 0),
            .command(status: .inProgress, exitCode: 0), .patch(status: .completed)]
        for terminal in terminals {
            let (ledger, authority) = L.makeOwner(), current = binding()
            let (handle, writer) = try ledger.installScope(authority, binding: current)
            XCTAssertTrue(writer.isCurrent(current: current.scope))
            let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
            XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current))
            XCTAssertTrue(writer.recordCompleted(current: current.scope, itemID: call.callID, terminal: terminal))
            XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: try history(call)).isEmpty)
        }
    }

    func testDuplicateOrConflictingNativeCompletionInvalidatesExistingPublication() throws {
        for duplicate: L.Terminal in [.command(status: .completed, exitCode: 0), .command(status: .failed, exitCode: 1)] {
            let (ledger, authority) = L.makeOwner(), current = binding()
            let (handle, writer) = try ledger.installScope(authority, binding: current)
            let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
            XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
            let pair = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: history(call)).first)
            XCTAssertFalse(writer.recordCompleted(current: current.scope, itemID: call.callID, terminal: duplicate))
            XCTAssertNil(ledger.literal(authority, publication: pair, current: current, field: .output))
        }
    }

    func testAbortAfterEarlyCompletionNeverPublishesOrReusesIssuedIDs() throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (handle, writer) = try ledger.installScope(authority, binding: current)
        let call = issued(), ticket = try stage(ledger, authority, handle, current, [call]); complete(ledger, writer, current, call)
        ledger.abortHTTPWrite(authority, ticket: ticket, current: current)
        XCTAssertFalse(ledger.commitHTTPWrite(authority, ticket: ticket, current: current))
        XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: try history(call)).isEmpty)
        XCTAssertThrowsError(try stage(ledger, authority, handle, current, [call], response: "resp-B"))
    }

    func testForeignOwnerAndAllScopeFencesRejectWithoutPublishing() throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (_, otherAuthority) = L.makeOwner()
        XCTAssertThrowsError(try ledger.installScope(otherAuthority, binding: current))
        XCTAssertThrowsError(try ledger.installScope(authority, binding: binding(scope(task: "not-a-uuid"))))
        let (handle, writer) = try ledger.installScope(authority, binding: current)
        let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
        let changed = [binding(scope(task: "30000000-0000-4000-8000-000000000001")),
            binding(scope(thread: "30000000-0000-4000-8000-000000000002")),
            binding(scope(turn: "30000000-0000-4000-8000-000000000003")), binding(scope(model: "foreign-model")),
            binding(scope(runtime: UUID())), binding(scope(preparation: UUID())),
            binding(scope(core: UUID())), binding(transport: UUID())]
        for wrong in changed {
            XCTAssertFalse(ledger.commitHTTPWrite(authority, ticket: ticket, current: wrong))
            XCTAssertThrowsError(try stage(ledger, authority, handle, wrong, [issued(id: "call-B")]))
            if wrong.scope != current.scope {
                XCTAssertFalse(writer.recordCompleted(current: wrong.scope, itemID: call.callID,
                    terminal: .command(status: .completed, exitCode: 0)))
            }
        }
        XCTAssertFalse(ledger.commitHTTPWrite(otherAuthority, ticket: ticket, current: current))
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
        XCTAssertEqual(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: try history(call)).count, 1)
    }

    func testEveryLifecycleRevocationAndSameTaskReinstallKillsOldCapabilities() throws {
        for reason in L.Revocation.allCases {
            let (ledger, authority) = L.makeOwner(), current = binding()
            let (handle, writer) = try ledger.installScope(authority, binding: current)
            let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
            XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
            let pair = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: history(call)).first)
            ledger.revoke(authority, scope: handle, reason: reason)
            XCTAssertFalse(writer.isCurrent(current: current.scope))
            XCTAssertNil(ledger.literal(authority, publication: pair, current: current, field: .output))
            XCTAssertFalse(writer.recordCompleted(current: current.scope, itemID: call.callID, terminal: .command(status: .completed, exitCode: 0)))
        }
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (old, oldWriter) = try ledger.installScope(authority, binding: current)
        _ = try ledger.installScope(authority, binding: current)
        XCTAssertFalse(oldWriter.isCurrent(current: current.scope))
        XCTAssertThrowsError(try stage(ledger, authority, old, current, [issued()]))
        XCTAssertFalse(oldWriter.recordCompleted(current: current.scope, itemID: "call-A", terminal: .command(status: .completed, exitCode: 0)))
    }

    func testReinstallingAnotherTaskDoesNotRevokeAnIndependentScope() throws {
        let (ledger, authority) = L.makeOwner(), a = binding(), b = binding(scope(task: "20000000-0000-4000-8000-000000000004"))
        let (handle, writer) = try ledger.installScope(authority, binding: a)
        _ = try ledger.installScope(authority, binding: b)
        let call = issued(), ticket = try stage(ledger, authority, handle, a, [call])
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: a)); complete(ledger, writer, a, call)
        XCTAssertEqual(ledger.reconcileValidatedHistory(authority, scope: handle, current: a, history: try history(call)).count, 1)
        ledger.revokeAll(authority, reason: .shutdown)
        XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: a, history: try history(call)).isEmpty)
    }

    func testIssuedIdentityArgumentsNamespaceAndHistoryRangesCannotBeBorrowed() throws {
        for mode in 0..<6 {
            let (ledger, authority) = L.makeOwner(), current = binding()
            let (handle, writer) = try ledger.installScope(authority, binding: current)
            let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
            XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
            let good = try history(call), p = good.pairs[0]
            let pair = L.HistoryPair(callID: mode == 0 ? "unissued" : p.callID,
                kind: mode == 1 ? .applyPatch : p.kind, name: mode == 2 ? "browser_click" : p.name,
                namespace: mode == 3 ? "functions" : p.namespace, argumentUTF8: mode == 4 ? Data("foreign".utf8) : p.argumentUTF8,
                argumentValueRange: mode == 5 ? p.outputValueRange : p.argumentValueRange, outputValueRange: p.outputValueRange)
            XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: current,
                history: .init(sourceUTF8: good.sourceUTF8, pairs: [pair])).isEmpty)
        }
    }

    func testChangedLiteralLexemeDoesNotBorrowPreviouslyPublishedReceipt() throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (handle, writer) = try ledger.installScope(authority, binding: current)
        let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
        let first = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: history(call)).first)
        // Even semantically equivalent rewritten strings are different raw tokens.
        XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: current,
            history: try history(call, output: Data(#"[{"type":"input_text","text":"A-B\nquoted \"value\""}]"#.utf8))).isEmpty)
        XCTAssertNil(ledger.literal(authority, publication: first, current: current, field: .output))
    }

    func testDuplicateIssuedCallsAndHistoryAndOversizedPayloadStayInline() throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (handle, writer) = try ledger.installScope(authority, binding: current), call = issued()
        XCTAssertThrowsError(try stage(ledger, authority, handle, current, [call, call]))
        XCTAssertThrowsError(try stage(ledger, authority, handle, current, [issued(namespace: "foreign")]))
        XCTAssertThrowsError(try stage(ledger, authority, handle, current,
            [issued(bytes: Data(repeating: 65, count: L.maximumLiteralBytes + 1))]))
        let ticket = try stage(ledger, authority, handle, current, [call])
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
        let good = try history(call)
        XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: current,
            history: .init(sourceUTF8: good.sourceUTF8, pairs: good.pairs + good.pairs)).isEmpty)
        XCTAssertTrue(ledger.reconcileValidatedHistory(authority, scope: handle, current: current,
            history: try history(call, output: Data(("\"" + String(repeating: "x", count: L.maximumLiteralBytes) + "\"").utf8))).isEmpty)
    }

    func testCurrentHTTPSourceAndEpochFactsCannotBeSubstitutedForAnotherLayoutOrEpoch() throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (handle, writer) = try ledger.installScope(authority, binding: current)
        let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
        let original = try history(call)
        let firstPair = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: original).first)
        let first = try XCTUnwrap(ledger.literal(authority, publication: firstPair, current: current, field: .output))
        let p = original.pairs[0]
        let shifted = L.ValidatedHistory(sourceUTF8: Data(" ".utf8) + original.sourceUTF8, pairs: [.init(
            callID: p.callID, kind: p.kind, name: p.name, namespace: p.namespace, argumentUTF8: p.argumentUTF8,
            argumentValueRange: (p.argumentValueRange.lowerBound + 1)..<(p.argumentValueRange.upperBound + 1),
            outputValueRange: (p.outputValueRange.lowerBound + 1)..<(p.outputValueRange.upperBound + 1))])
        let shiftedPair = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: shifted).first)
        let next = try XCTUnwrap(ledger.literal(authority, publication: shiftedPair, current: current, field: .output))
        XCTAssertEqual(first.rawJSONValue, next.rawJSONValue)
        XCTAssertNotEqual(first.nativeHTTPSourceSHA256, next.nativeHTTPSourceSHA256)
        XCTAssertTrue(first.isSameEpoch(as: next))
        XCTAssertEqual(next.valueRange, shifted.pairs[0].outputValueRange)
        writer.revoke(reason: .transportChanged)
        XCTAssertFalse(writer.isCurrent(current: current.scope))
        XCTAssertNil(ledger.literal(authority, publication: shiftedPair, current: current, field: .output))
        let (newHandle, newWriter) = try ledger.installScope(authority, binding: current)
        let newTicket = try stage(ledger, authority, newHandle, current, [call])
        XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: newTicket, current: current)); complete(ledger, newWriter, current, call)
        let newPair = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: newHandle, current: current, history: original).first)
        let newField = try XCTUnwrap(ledger.literal(authority, publication: newPair, current: current, field: .output))
        XCTAssertEqual(first.scope, newField.scope)
        XCTAssertFalse(first.isSameEpoch(as: newField))
    }

    func testCachedLiteralFieldRejectsPerCallDuplicateOrAbortWhileWriterRemainsCurrent() throws {
        for lateAbort in [false, true] {
            let (ledger, authority) = L.makeOwner(), current = binding()
            let (handle, writer) = try ledger.installScope(authority, binding: current)
            let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
            XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: current)); complete(ledger, writer, current, call)
            let original = try history(call)
            let pair = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: original).first)
            let cached = try XCTUnwrap(ledger.literal(authority, publication: pair, current: current, field: .output))
            XCTAssertTrue(cached.isCurrent()); XCTAssertTrue(writer.isCurrent(current: current.scope))
            // Authenticated later HTTP framing can advance without changing this
            // call's raw field; a cached field is not invalidated by framing alone.
            let p = original.pairs[0]
            let shifted = L.ValidatedHistory(sourceUTF8: Data(" ".utf8) + original.sourceUTF8, pairs: [.init(
                callID: p.callID, kind: p.kind, name: p.name, namespace: p.namespace, argumentUTF8: p.argumentUTF8,
                argumentValueRange: (p.argumentValueRange.lowerBound + 1)..<(p.argumentValueRange.upperBound + 1),
                outputValueRange: (p.outputValueRange.lowerBound + 1)..<(p.outputValueRange.upperBound + 1))])
            XCTAssertEqual(ledger.reconcileValidatedHistory(authority, scope: handle, current: current, history: shifted).count, 1)
            XCTAssertTrue(cached.isCurrent())
            if lateAbort { ledger.abortHTTPWrite(authority, ticket: ticket, current: current) }
            else {
                XCTAssertFalse(writer.recordCompleted(current: current.scope, itemID: call.callID,
                    terminal: .command(status: .completed, exitCode: 0)))
            }
            XCTAssertTrue(writer.isCurrent(current: current.scope))
            XCTAssertFalse(cached.isCurrent())
            XCTAssertNil(ledger.literal(authority, publication: pair, current: current, field: .output))
            let (freshHandle, freshWriter) = try ledger.installScope(authority, binding: current)
            let freshTicket = try stage(ledger, authority, freshHandle, current, [call])
            XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: freshTicket, current: current)); complete(ledger, freshWriter, current, call)
            let freshPair = try XCTUnwrap(ledger.reconcileValidatedHistory(authority, scope: freshHandle, current: current, history: original).first)
            let fresh = try XCTUnwrap(ledger.literal(authority, publication: freshPair, current: current, field: .output))
            XCTAssertTrue(fresh.isCurrent()); XCTAssertFalse(cached.isCurrent())
            freshWriter.revoke(reason: .stopped)
            XCTAssertFalse(fresh.isCurrent())
        }
    }

    #if DEBUG
    @MainActor
    func testAnyNativeFactEventSettlesOneCallWithoutWaitingForOtherOrRequiringSuccess() async throws {
        let (ledger, authority) = L.makeOwner(), current = binding()
        let (handle, writer) = try ledger.installScope(authority, binding: current)
        let a = issued(id: "call-A"), b = issued(id: "call-B")
        _ = try stage(ledger, authority, handle, current, [a, b])
        XCTAssertEqual(try ledger.unsettledIssuedCallIDs(authority, scope: handle, current: current,
            matchingIDs: [a.callID, "unissued", b.callID]), [a.callID, b.callID])
        let (events, signal) = AsyncStream<Void>.makeStream()
        let deadline = ContinuousClock.now + .seconds(2)
        let waiting = Task {
            defer { signal.finish() }
            try await ledger.waitForAnyNativeCompletionForTesting(authority, scope: handle, current: current,
                callIDs: [a.callID, b.callID], until: deadline, didPark: { _ = signal.yield(()) })
        }
        var iterator = events.makeAsyncIterator()
        let parked = await iterator.next(); XCTAssertNotNil(parked)
        XCTAssertTrue(writer.recordCompleted(current: current.scope, itemID: a.callID,
            terminal: .command(status: .completed, exitCode: 0)))
        try await waiting.value
        XCTAssertEqual(try ledger.unsettledIssuedCallIDs(authority, scope: handle, current: current,
            matchingIDs: [a.callID, b.callID]), [b.callID], "ANY fact woke the waiter; it did not wait for both calls")
        // The queued-result race returns immediately even with an expired wait
        // deadline, without inventing a completion for the remaining call.
        try await ledger.waitForAnyNativeCompletion(authority, scope: handle, current: current,
            callIDs: [a.callID, b.callID], until: ContinuousClock.now - .seconds(1))
        let (moreEvents, moreSignal) = AsyncStream<Void>.makeStream()
        let second = Task {
            defer { moreSignal.finish() }
            try await ledger.waitForAnyNativeCompletionForTesting(authority, scope: handle, current: current,
                callIDs: [b.callID], until: deadline, didPark: { _ = moreSignal.yield(()) })
        }
        var next = moreEvents.makeAsyncIterator()
        let secondParked = await next.next(); XCTAssertNotNil(secondParked)
        XCTAssertTrue(writer.recordCompleted(current: current.scope, itemID: b.callID,
            terminal: .command(status: .inProgress, exitCode: nil)))
        try await second.value // Typed uncertainty is a fact, not an await error.
        XCTAssertTrue(try ledger.unsettledIssuedCallIDs(authority, scope: handle, current: current,
            matchingIDs: [a.callID, b.callID, "unissued"]).isEmpty)
        do {
            try await ledger.waitForAnyNativeCompletion(authority, scope: handle, current: current,
                callIDs: ["unissued"], until: deadline)
            XCTFail("An unknown ID must never install a waiter")
        } catch { XCTAssertEqual(error as? L.NativeFactWaitFailure, .unknownCall) }
    }

    @MainActor
    func testAnyNativeFactWaitIsCancelledRevokedAbortedOrExpiredWithoutPolling() async throws {
        for mode in ["cancel", "writer_revoke", "all_revoke", "reinstall", "abort", "deadline"] {
            let (ledger, authority) = L.makeOwner(), current = binding()
            let (handle, writer) = try ledger.installScope(authority, binding: current)
            let call = issued(), ticket = try stage(ledger, authority, handle, current, [call])
            let (events, signal) = AsyncStream<Void>.makeStream()
            let deadline = ContinuousClock.now + (mode == "deadline" ? .milliseconds(100) : .seconds(2))
            let waiting = Task {
                defer { signal.finish() }
                try await ledger.waitForAnyNativeCompletionForTesting(authority, scope: handle, current: current,
                    callIDs: [call.callID], until: deadline, didPark: { _ = signal.yield(()) })
            }
            var iterator = events.makeAsyncIterator()
            let parked = await iterator.next(); XCTAssertNotNil(parked)
            switch mode {
            case "cancel": waiting.cancel()
            case "writer_revoke": writer.revoke(reason: .transportChanged)
            case "all_revoke": ledger.revokeAll(authority, reason: .shutdown)
            case "reinstall": _ = try ledger.installScope(authority, binding: current)
            case "abort": ledger.abortHTTPWrite(authority, ticket: ticket, current: current)
            default: break // One original deadline; no test or product polling.
            }
            do {
                try await waiting.value
                XCTFail("The parked native fact wait must stop: " + mode)
            } catch {
                if mode == "cancel" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? L.NativeFactWaitFailure, mode == "deadline" ? .deadline : .scope) }
            }
        }
    }
    #endif
}

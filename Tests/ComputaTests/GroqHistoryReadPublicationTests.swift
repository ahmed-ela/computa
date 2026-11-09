import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Native capability controls only; actual Core pipe publication is exercised
/// separately by the bundled coding/history fixture.
final class GroqHistoryReadPublicationTests: XCTestCase {
    private typealias L = GroqNativePublicationLedger
    private typealias M = GroqContextManifestProjector
    private typealias J = GroqContextJSONLayout
    private typealias P = GroqHistoryReadPublication

    private struct Fixture: Sendable {
        let ledger: L
        let writer: L.CompletionWriter
        let binding: L.Binding
        let reader: M.ReaderAuthority
        let source: Data
        let plan: M.Plan
        let arguments: Data
        let proposal: M.ReadProposal
        let publication: P

        init() throws {
            let owner = L.makeOwner()
            let scope = L.Scope(taskID: "30000000-0000-4000-8000-000000000001",
                threadID: "30000000-0000-4000-8000-000000000002", turnID: "30000000-0000-4000-8000-000000000003",
                runtimeGeneration: UUID(), preparationID: UUID(), modelID: "browser/groq/choice/inert", coreGeneration: UUID())
            let binding = L.Binding(scope: scope, transportGeneration: UUID())
            let (handle, writer) = try owner.ledger.installScope(owner.authority, binding: binding)
            let nonce = UUID()
            let reader = try M.makeReaderAuthority(binding: binding, contextNonce: nonce,
                registeredName: M.readerName, registrationSHA256: String(repeating: "a", count: 64))
            let calls = ["read_old", "read_latest"].map {
                L.IssuedCall(callID: $0, kind: .execCommand, name: "exec_command", namespace: nil,
                    argumentUTF8: Data(#"{"cmd":"read inert native source"}"#.utf8))
            }
            let issued = try owner.ledger.stageIssuedResponse(owner.authority, scope: handle, current: binding,
                responseID: "response_native", encodedResponseSHA256: String(repeating: "b", count: 64), calls: calls)
            guard owner.ledger.commitHTTPWrite(owner.authority, ticket: issued, current: binding) else { throw P.Failure.scope }
            for call in calls {
                guard writer.recordCompleted(current: scope, itemID: call.callID,
                    terminal: .command(status: .completed, exitCode: 0)) else { throw P.Failure.scope }
            }
            let tools: [[String: Any]] = [["type": "function", "name": M.readerName,
                "parameters": ["type": "object", "properties": ["ref": ["type": "string"]],
                    "required": ["ref"], "additionalProperties": false]]]
            var items: [[String: Any]] = [["role": "user", "content": "Read the inert native history."]]
            for (index, call) in calls.enumerated() {
                items.append(["type": "function_call", "call_id": call.callID, "name": call.name,
                    "arguments": String(decoding: call.argumentUTF8, as: UTF8.self)])
                items.append(["type": "function_call_output", "call_id": call.callID,
                    "output": index == 0 ? String(repeating: "Literal café 🙂 ", count: 700) : "LATEST_INLINE"])
            }
            let source = try publicationJSON(["model": scope.modelID, "instructions": "Unchanged native policy", "tools": tools, "input": items])
            let layout = try J.parse(source)
            let pairs = try calls.map { call -> L.HistoryPair in
                let input = try XCTUnwrap(layout.items.first { $0.callID == call.callID && $0.kind == .functionCall }?.payload)
                let output = try XCTUnwrap(layout.items.first { $0.callID == call.callID && $0.kind == .functionCallOutput }?.payload)
                return L.HistoryPair(callID: call.callID, kind: call.kind, name: call.name, namespace: nil,
                    argumentUTF8: call.argumentUTF8, argumentValueRange: input.valueRange, outputValueRange: output.valueRange)
            }
            let published = owner.ledger.reconcileValidatedHistory(owner.authority, scope: handle, current: binding,
                history: L.ValidatedHistory(sourceUTF8: source, pairs: pairs))
            let fields = published.flatMap { pair in [L.Field.arguments, .output].compactMap {
                owner.ledger.literal(owner.authority, publication: pair, current: binding, field: $0)
            } }
            let projector = try M(binding: binding, contextNonce: nonce, nativeLayout: layout, eligibleFields: fields,
                previous: nil, publishedLookups: [], readerAuthority: reader)
            let schema = publicationSHA(try layout.rawBytes(in: XCTUnwrap(layout.toolsRange)))
            let plan = try projector.project(candidateLayout: layout, fullSchemaSHA256: schema, selectedSchemaSHA256: schema)
            let rendered = try J.parse(plan.renderedJSON)
            let descriptorToken = try XCTUnwrap(rendered.items.first { $0.callID == calls[0].callID && $0.kind == .functionCallOutput }?.payload?.rawJSON)
            let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptorToken) as? [String: Any])
            XCTAssertEqual(Set(descriptor.keys), ["$computa_history"])
            let ref = try XCTUnwrap(descriptor["$computa_history"] as? String)
            let arguments = try publicationJSON(["ref": ref])
            let readCall = try M.issueLookupCall(reader, binding: binding, contextNonce: nonce,
                nativeHTTPSourceSHA256: plan.snapshot.nativeHTTPSourceSHA256, callID: "lookup_native",
                qualifiedName: M.readerName, arguments: arguments)
            let proposal = try M.prepareRead(plan.snapshot, issued: readCall, maximumBytes: 64)
            let publication = try P(snapshot: plan.snapshot, proposal: proposal, authority: reader, writer: writer)
            self.ledger = owner.ledger; self.writer = writer; self.binding = binding; self.reader = reader
            self.source = source; self.plan = plan; self.arguments = arguments
            self.proposal = proposal; self.publication = publication
        }

        /// An independent next-frame fixture retains the actual prior input
        /// tokens and appends the actual reader call and response, not a kernel
        /// prediction of that frame's serialization.
        func appendedActualFrame() throws -> Data {
            let layout = try J.parse(source), end = try XCTUnwrap(layout.items.last?.wholeRange.upperBound)
            let input = try layout.rawBytes(in: layout.inputRange.lowerBound..<end)
            let call = Data(#",{"type":"function_call","call_id":"lookup_native","name":"computa_read_context","arguments":"#.utf8)
                + (try publicationJSON(String(decoding: arguments, as: UTF8.self))) + Data("}".utf8)
            let result = Data(#",{"type":"function_call_output","call_id":"lookup_native","output":"#.utf8)
                + (try publicationJSON(String(decoding: proposal.responseData, as: UTF8.self))) + Data("}]".utf8)
            let parts: [Data] = [Data(#"{"instructions":"#.utf8),
                try layout.rawBytes(in: XCTUnwrap(layout.instructionsRange)),
                Data(#", "tools":"#.utf8), try layout.rawBytes(in: XCTUnwrap(layout.toolsRange)),
                Data(#", "model":"#.utf8), try publicationJSON(binding.scope.modelID),
                Data(#", "input":"#.utf8), input, call, result, Data("}".utf8)]
            var actual = Data()
            for part in parts { actual.append(part) }
            return actual
        }
    }

    func testPendingReceiptCannotPublishOrActivateNextFrameUntilExactRPCCommit() async throws {
        let f = try Fixture(), p = f.publication
        XCTAssertTrue(p.isCurrent(currentScope: f.binding.scope)); XCTAssertNil(p.publishedLookup())
        XCTAssertEqual(GroqHistoryReadExecution(publication: p).responseData, f.proposal.responseData)
        let next = try J.parse(f.appendedActualFrame())
        XCTAssertThrowsError(try M(binding: f.binding, contextNonce: f.plan.snapshot.contextNonce,
            nativeLayout: next, eligibleFields: [], previous: f.plan.snapshot, publishedLookups: [], readerAuthority: f.reader))
        let waiting = Task { try await p.waitForPublication() }
        XCTAssertTrue(p.commitAfterRPCWrite(responseData: f.proposal.responseData))
        let publication = try await waiting.value
        XCTAssertNotNil(p.publishedLookup()); XCTAssertFalse(p.isCurrent(currentScope: f.binding.scope))
        XCTAssertFalse(p.commitAfterRPCWrite(responseData: f.proposal.responseData))
        _ = try M(binding: f.binding, contextNonce: f.plan.snapshot.contextNonce, nativeLayout: next,
            eligibleFields: [], previous: f.plan.snapshot, publishedLookups: [publication], readerAuthority: f.reader)
        _ = try await p.waitForPublication() // Late observers see the same commit.
    }

    func testWrongWrittenBytesAbortReceiptAndCannotBeRetriedWithCorrectBytes() async throws {
        let f = try Fixture(), p = f.publication
        XCTAssertFalse(p.commitAfterRPCWrite(responseData: f.proposal.responseData + Data(" ".utf8)))
        XCTAssertNil(p.publishedLookup()); XCTAssertFalse(p.isCurrent(currentScope: f.binding.scope))
        XCTAssertFalse(p.commitAfterRPCWrite(responseData: f.proposal.responseData))
        do { _ = try await p.waitForPublication(); XCTFail("Changed bytes must not publish") }
        catch { XCTAssertEqual(error as? P.Failure, .scope) }
    }

    func testRevokedWriterAndInvalidatedNativeOriginCannotPublishCachedResponse() async throws {
        for duplicate in [false, true] {
            let f = try Fixture(), p = f.publication
            if duplicate {
                XCTAssertFalse(f.writer.recordCompleted(current: f.binding.scope, itemID: "read_old",
                    terminal: .command(status: .completed, exitCode: 0)))
                XCTAssertTrue(f.writer.isCurrent(current: f.binding.scope))
            } else { f.writer.revoke(reason: .stopped) }
            XCTAssertFalse(p.isCurrent(currentScope: f.binding.scope))
            XCTAssertFalse(p.commitAfterRPCWrite(responseData: f.proposal.responseData)); XCTAssertNil(p.publishedLookup())
            do { _ = try await p.waitForPublication(); XCTFail("Revoked origin must not publish") }
            catch { XCTAssertEqual(error as? P.Failure, .scope) }
        }
        let committed = try Fixture()
        XCTAssertTrue(committed.publication.commitAfterRPCWrite(responseData: committed.proposal.responseData))
        committed.writer.revoke(reason: .turnChanged)
        XCTAssertNil(committed.publication.publishedLookup())
        do { _ = try await committed.publication.waitForPublication(); XCTFail("A cached commit cannot outlive its writer") }
        catch { XCTAssertEqual(error as? P.Failure, .scope) }
    }

    func testExplicitAbortSettlesWaitingAndFutureObserversWithoutPublication() async throws {
        let f = try Fixture(), p = f.publication
        let waiting = Task { try await p.waitForPublication() }
        p.abortIfPending(); p.abortIfPending()
        do { _ = try await waiting.value; XCTFail("Aborted receipt must settle") }
        catch { XCTAssertEqual(error as? P.Failure, .aborted) }
        XCTAssertNil(p.publishedLookup()); XCTAssertFalse(p.commitAfterRPCWrite(responseData: f.proposal.responseData))
        do { _ = try await p.waitForPublication(); XCTFail("Late observer cannot renew abort") }
        catch { XCTAssertEqual(error as? P.Failure, .aborted) }
    }

    func testWaiterCancellationDoesNotPublishOrConsumeAnotherWaitersCommit() async throws {
        let f = try Fixture(), p = f.publication
        let cancelled = Task { try await p.waitForPublication() }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled waiter must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(p.isCurrent(currentScope: f.binding.scope)); XCTAssertNil(p.publishedLookup())
        let surviving = Task { try await p.waitForPublication() }
        XCTAssertTrue(p.commitAfterRPCWrite(responseData: f.proposal.responseData))
        _ = try await surviving.value
        XCTAssertNotNil(p.publishedLookup())
    }

    func testCreationDeadlineIsSharedAndLateWaitCannotRenewPublication() async throws {
        let f = try Fixture(), p = f.publication
        let first = Task { try await p.waitForPublication() }
        let second = Task { try await p.waitForPublication() }
        for waiting in [first, second] {
            do { _ = try await waiting.value; XCTFail("Unpublished receipt has a finite deadline") }
            catch { XCTAssertEqual(error as? P.Failure, .deadline) }
        }
        XCTAssertFalse(p.isCurrent(currentScope: f.binding.scope)); XCTAssertNil(p.publishedLookup())
        XCTAssertFalse(p.commitAfterRPCWrite(responseData: f.proposal.responseData))
        do { _ = try await p.waitForPublication(); XCTFail("A late observer cannot create a new deadline") }
        catch { XCTAssertEqual(error as? P.Failure, .deadline) }
    }
}

private func publicationJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
}
private func publicationSHA(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

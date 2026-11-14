import CryptoKit
import Foundation
import XCTest
@testable import Computa

/// Pure, synthetic native-boundary controls. No Core/HTTP/provider execution,
/// token fit or host-publication integration is claimed by these unit fixtures.
final class GroqContextManifestProjectorTests: XCTestCase {
    private typealias M = GroqContextManifestProjector
    private typealias L = GroqNativePublicationLedger
    private typealias J = GroqContextJSONLayout

    private final class Fixture {
        let ledger: L
        let authority: L.ServerAuthority
        let handle: L.ScopeHandle
        let writer: L.CompletionWriter
        let binding: L.Binding
        let nonce: UUID
        let reader: M.ReaderAuthority
        let calls: [L.IssuedCall]
        let source: Data
        init(arguments: String = #"{"cmd":"read inert source"}"#,
             output: String = String(repeating: "Literal é🙂 `\\n` ", count: 700),
             patch: Bool = false, completeOld: Bool = true,
             latestTerminal: L.Terminal = .command(status: .completed, exitCode: 0)) throws {
            let owner = L.makeOwner(), ledger = owner.ledger, authority = owner.authority
            let nonce = UUID()
            let scope = L.Scope(taskID: "20000000-0000-4000-8000-000000000001",
                threadID: "20000000-0000-4000-8000-000000000002", turnID: "20000000-0000-4000-8000-000000000003",
                runtimeGeneration: UUID(), preparationID: UUID(), modelID: "browser/groq/choice/inert", coreGeneration: UUID())
            let binding = L.Binding(scope: scope, transportGeneration: UUID())
            let installation = try ledger.installScope(authority, binding: binding)
            let handle = installation.0, writer = installation.1
            let reader = try M.makeReaderAuthority(binding: binding, contextNonce: nonce,
                registeredName: M.readerName, registrationSHA256: String(repeating: "a", count: 64))
            let calls = [L.IssuedCall(callID: "call_old", kind: patch ? .applyPatch : .execCommand,
                name: patch ? "apply_patch" : "exec_command", namespace: nil, argumentUTF8: Data(arguments.utf8)),
                L.IssuedCall(callID: "call_latest", kind: .execCommand, name: "exec_command", namespace: nil,
                    argumentUTF8: Data(#"{"cmd":"latest inert read"}"#.utf8))]
            let ticket = try ledger.stageIssuedResponse(authority, scope: handle, current: binding,
                responseID: "resp_fixture", encodedResponseSHA256: String(repeating: "b", count: 64), calls: calls)
            XCTAssertTrue(ledger.commitHTTPWrite(authority, ticket: ticket, current: binding))
            if completeOld {
                XCTAssertTrue(writer.recordCompleted(current: scope, itemID: calls[0].callID,
                    terminal: patch ? .patch(status: .completed) : .command(status: .completed, exitCode: 0)))
            }
            XCTAssertTrue(writer.recordCompleted(current: scope, itemID: calls[1].callID,
                terminal: latestTerminal))
            var items: [[String: Any]] = [["role": "developer", "content": "Keep the complete native policy."],
                ["role": "user", "content": "Exact user café / café 🙂 with `literal` text."]]
            for (index, call) in calls.enumerated() {
                let custom = call.kind == .applyPatch
                items.append(["type": custom ? "custom_tool_call" : "function_call", "call_id": call.callID,
                    "name": call.name, custom ? "input" : "arguments": String(decoding: call.argumentUTF8, as: UTF8.self)])
                items.append(["type": custom ? "custom_tool_call_output" : "function_call_output",
                    "call_id": call.callID, "output": index == 0 ? output : "LATEST_NATIVE_OBSERVATION_INLINE"])
            }
            let source = try Self.frame(model: scope.modelID, items: items)
            self.ledger = ledger; self.authority = authority; self.handle = handle; self.writer = writer
            self.binding = binding; self.nonce = nonce; self.reader = reader; self.calls = calls; self.source = source
        }
        static var tools: [[String: Any]] { [
            ["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]],
            ["type": "custom", "name": "apply_patch", "format": ["type": "text"]],
            ["type": "function", "name": M.readerName, "parameters": ["type": "object", "properties": [
                "ref": ["type": "string"]],
                "required": ["ref"], "additionalProperties": false]]] }
        static func frame(model: String, items: [[String: Any]]) throws -> Data {
            let encoded = try json(items), toolTokens = try json(Self.tools), modelToken = try json(model)
            return Data("{\"model\":".utf8) + modelToken + Data(",\"instructions\":\"policy\\u0061\",\"input\":".utf8)
                + encoded + Data(",\"tools\":".utf8) + toolTokens + Data(",\"foreign\":{\"number\":1.2300e+04,\"text\":\"foreign\\u002Dlexeme\"}}".utf8)
        }
        func fields(_ data: Data) throws -> [L.LiteralField] {
            let layout = try J.parse(data)
            let pairs = try calls.map { call -> L.HistoryPair in
                let argument = try XCTUnwrap(layout.items.first { $0.callID == call.callID && ($0.kind == .functionCall || $0.kind == .customToolCall) }?.payload)
                let output = try XCTUnwrap(layout.items.first { $0.callID == call.callID && ($0.kind == .functionCallOutput || $0.kind == .customToolCallOutput) }?.payload)
                return .init(callID: call.callID, kind: call.kind, name: call.name, namespace: call.namespace,
                    argumentUTF8: call.argumentUTF8, argumentValueRange: argument.valueRange, outputValueRange: output.valueRange)
            }
            let published = ledger.reconcileValidatedHistory(authority, scope: handle, current: binding,
                history: .init(sourceUTF8: data, pairs: pairs))
            return published.flatMap { pair in [L.Field.arguments, .input, .output].compactMap {
                ledger.literal(authority, publication: pair, current: binding, field: $0)
            } }
        }
        func projector(_ data: Data, previous: M.Snapshot? = nil,
            publications: [M.PublishedLookup] = []) throws -> M {
            try M(binding: binding, contextNonce: nonce, nativeLayout: J.parse(data), eligibleFields: fields(data),
                previous: previous, publishedLookups: publications, readerAuthority: reader)
        }
        func plan(_ data: Data, previous: M.Snapshot? = nil,
            publications: [M.PublishedLookup] = [], candidate: Data? = nil) throws -> M.Plan {
            let native = try J.parse(data), displayed = try J.parse(candidate ?? data)
            return try projector(data, previous: previous, publications: publications).project(candidateLayout: displayed,
                fullSchemaSHA256: sha(native.rawBytes(in: XCTUnwrap(native.toolsRange))),
                selectedSchemaSHA256: sha(displayed.rawBytes(in: XCTUnwrap(displayed.toolsRange))))
        }
        func issued(_ snapshot: M.Snapshot, arguments: Data, id: String) throws -> M.IssuedLookupCall {
            try M.issueLookupCall(reader, binding: binding, contextNonce: nonce,
                nativeHTTPSourceSHA256: snapshot.nativeHTTPSourceSHA256, callID: id,
                qualifiedName: M.readerName, arguments: arguments)
        }
        func read(_ plan: M.Plan, ref: String, id: String, maximum: Int = 4_096) throws -> (Data, M.ReadProposal, M.PublishedLookup) {
            let args = try json(["ref": ref])
            let read = try M.prepareRead(plan.snapshot, issued: issued(plan.snapshot, arguments: args, id: id), maximumBytes: maximum)
            let committed = try M.commitLookupPublication(reader, ticket: read.publicationTicket,
                binding: binding, contextNonce: nonce, responseData: read.responseData)
            return (args, read, committed)
        }
        /// Independently constructed actual-next-frame fixture: different ROOT
        /// member order, exact retained input bytes, arbitrary new pair key order.
        /// The kernel does not construct or predict any of these next bytes.
        func appendRead(to source: Data, id: String, arguments: Data, response: Data) throws -> Data {
            let layout = try J.parse(source)
            let end = try XCTUnwrap(layout.items.last?.wholeRange.upperBound)
            let prefix = try layout.rawBytes(in: layout.inputRange.lowerBound..<end)
            let call = Data("{\"name\":\"computa_read_context\",\"arguments\":".utf8) + (try json(String(decoding: arguments, as: UTF8.self)))
                + Data(",\"type\":\"function_call\",\"call_id\":".utf8) + (try json(id)) + Data("}".utf8)
            let output = Data("{\"output\":".utf8) + (try json(String(decoding: response, as: UTF8.self)))
                + Data(",\"call_id\":".utf8) + (try json(id)) + Data(",\"type\":\"function_call_output\"}".utf8)
            let tools = try layout.rawBytes(in: XCTUnwrap(layout.toolsRange))
            let instructions = try layout.rawBytes(in: XCTUnwrap(layout.instructionsRange))
            let model = try json(binding.scope.modelID)
            let pieces: [Data] = [Data("{\"tools\":".utf8), tools, Data(",\"input\":".utf8), prefix,
                Data(",".utf8), call, Data(",".utf8), output, Data("],\"instructions\":".utf8),
                instructions, Data(",\"model\":".utf8), model,
                Data(",\"foreign\":{\"number\":1.2300e+04,\"text\":\"foreign\\u002Dlexeme\"}}".utf8)]
            var result = Data()
            for piece in pieces { result.append(piece) }
            return result
        }
    }

    func testKnownFailedOlderOutputKeepsOutcomeAndWholeBytesWithoutGrantingActionAuthority() throws {
        let failedText = String(repeating: "FAILED exit1; exact é🙂 literal ", count: 32)
        let f = try Fixture(output: failedText, completeOld: false,
            latestTerminal: .knownNonzeroCommandResult(status: .failed, exitCode: 2))
        XCTAssertTrue(f.writer.recordCompleted(current: f.binding.scope, itemID: "call_old",
            terminal: .knownNonzeroCommandResult(status: .failed, exitCode: 1)))
        let native = try J.parse(f.source), plan = try f.plan(f.source), rendered = try J.parse(plan.renderedJSON)
        let original = try XCTUnwrap(native.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload)
        let replaced = try XCTUnwrap(rendered.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: replaced.rawJSON) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["$computa_history", "status", "exit_code", "historical_only", "action_authority"])
        XCTAssertEqual(value["status"] as? String, "failed")
        XCTAssertEqual(value["exit_code"] as? Int, 1)
        XCTAssertEqual(value["historical_only"] as? Bool, true)
        XCTAssertEqual(value["action_authority"] as? Bool, false)
        let ref = try XCTUnwrap(value["$computa_history"] as? String)
        XCTAssertNotNil(referenceBytes(ref))
        XCTAssertEqual(plan.replacedFields, 1)
        // Even an authenticated known failure stays wholly inline while it is latest.
        let latestItems = native.items.filter { $0.callID == "call_latest" }
        XCTAssertEqual(latestItems.count, 2)
        for before in latestItems {
            let kind = before.kind
            let after = try XCTUnwrap(rendered.items.first { $0.callID == "call_latest" && $0.kind == kind })
            XCTAssertEqual(try native.rawBytes(in: before.wholeRange), try rendered.rawBytes(in: after.wholeRange))
        }
        let first = try f.read(plan, ref: ref, id: "read_failed_one")
        try assertReadIdentity(first.1.responseData, plan: plan, ref: ref, callID: "call_old",
            name: "exec_command", kind: "function", field: "output", rawJSON: original.rawJSON)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: first.1.responseData) as? [String: Any])
        XCTAssertEqual(response["start_byte"] as? Int, 0)
        XCTAssertEqual(response["end_byte"] as? Int, original.rawJSON.count)
        XCTAssertTrue(response["next_ref"] is NSNull)
        XCTAssertEqual(Data(try XCTUnwrap(response["utf8_fragment"] as? String).utf8), original.rawJSON)
        // A successful history read of failed data does not itself become a failed command.
        let frame1 = try f.appendRead(to: f.source, id: "read_failed_one", arguments: first.0, response: first.1.responseData)
        let next = try f.plan(frame1, previous: plan.snapshot, publications: [first.2])
        let second = try f.read(next, ref: ref, id: "read_failed_two")
        let frame2 = try f.appendRead(to: frame1, id: "read_failed_two", arguments: second.0, response: second.1.responseData)
        let latest = try f.plan(frame2, previous: next.snapshot, publications: [second.2])
        _ = try reference(latest, id: "read_failed_one", field: .output) // Existing strict single-key oracle.
        let latestLayout = try J.parse(latest.renderedJSON)
        XCTAssertEqual(latestLayout.items.first { $0.callID == "read_failed_two" && $0.kind == .functionCallOutput }?.payload?.literalUTF8,
            second.1.responseData)
        // Identical text under a native success proof retains the old one-key descriptor.
        let success = try Fixture(output: failedText), successPlan = try success.plan(success.source)
        _ = try reference(successPlan, id: "call_old", field: .output)
        XCTAssertTrue(plan.isCurrent()); XCTAssertTrue(latest.isCurrent())
        f.writer.revoke(reason: .stopped)
        XCTAssertFalse(plan.isCurrent()); XCTAssertFalse(latest.isCurrent())
        XCTAssertThrowsError(try M.prepareRead(plan.snapshot,
            issued: f.issued(plan.snapshot, arguments: first.0, id: "read_revoked_failed"), maximumBytes: 4_096))
    }

    func testOnlyLargeOlderOutputIsReplacedAndEveryOtherByteRemainsVerbatim() throws {
        let f = try Fixture(), layout = try J.parse(f.source), plan = try f.plan(f.source)
        XCTAssertEqual(plan.replacedFields, 1); XCTAssertGreaterThan(plan.savedJSONBytes, 64)
        let old = try XCTUnwrap(layout.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload)
        let projected = try J.parse(plan.renderedJSON)
        let replacement = try XCTUnwrap(projected.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload)
        let expected = f.source.subdata(in: 0..<old.valueRange.lowerBound) + replacement.rawJSON
            + f.source.subdata(in: old.valueRange.upperBound..<f.source.count)
        XCTAssertEqual(plan.renderedJSON, expected)
        XCTAssertTrue(String(decoding: plan.renderedJSON, as: UTF8.self).contains("1.2300e+04"))
        XCTAssertTrue(String(decoding: plan.renderedJSON, as: UTF8.self).contains("LATEST_NATIVE_OBSERVATION_INLINE"))
        let ref = try reference(plan, id: "call_old", field: .output)
        let (_, read, _) = try f.read(plan, ref: ref, id: "read_exact_old_output")
        try assertReadIdentity(read.responseData, plan: plan, ref: ref, callID: "call_old",
            name: "exec_command", kind: "function", field: "output", rawJSON: old.rawJSON)
    }

    func testLargePatchInputCanBeReferencedWhileItsSmallOutputAndLatestPairStayInline() throws {
        let input = "*** Begin Patch\n*** Add File: /synthetic/inert\n" + String(repeating: "+literal line\n", count: 400) + "*** End Patch\n"
        let f = try Fixture(arguments: input, output: "native patch completed", patch: true), plan = try f.plan(f.source)
        XCTAssertEqual(plan.replacedFields, 1)
        let ref = try reference(plan, id: "call_old", field: .input)
        let original = try XCTUnwrap(J.parse(f.source).items.first { $0.callID == "call_old" && $0.kind == .customToolCall }?.payload)
        let (_, read, _) = try f.read(plan, ref: ref, id: "read_exact_old_patch")
        try assertReadIdentity(read.responseData, plan: plan, ref: ref, callID: "call_old",
            name: "apply_patch", kind: "custom", field: "input", rawJSON: original.rawJSON)
        let body = try J.parse(plan.renderedJSON)
        XCTAssertEqual(body.items.first { $0.callID == "call_old" && $0.kind == .customToolCallOutput }?.payload?.literalUTF8,
            Data("native patch completed".utf8))
    }

    func testLargeFunctionArgumentsAreIndependentOfTheirSmallCompletedOutput() throws {
        let arguments = String(decoding: try json(["cmd": String(repeating: "inert source line ", count: 400)]), as: UTF8.self)
        let f = try Fixture(arguments: arguments, output: "small native result"), plan = try f.plan(f.source)
        XCTAssertEqual(plan.replacedFields, 1)
        let ref = try reference(plan, id: "call_old", field: .arguments)
        let original = try XCTUnwrap(J.parse(f.source).items.first { $0.callID == "call_old" && $0.kind == .functionCall }?.payload)
        let (_, read, _) = try f.read(plan, ref: ref, id: "read_exact_old_arguments")
        try assertReadIdentity(read.responseData, plan: plan, ref: ref, callID: "call_old",
            name: "exec_command", kind: "function", field: "arguments", rawJSON: original.rawJSON)
        let layout = try J.parse(plan.renderedJSON)
        XCTAssertEqual(layout.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload?.literalUTF8,
            Data("small native result".utf8))
    }

    func testSmallFieldsAndMissingTypedCompletionNeverGainReferences() throws {
        let small = try Fixture(output: "small"), a = try small.plan(small.source)
        XCTAssertEqual(a.renderedJSON, small.source); XCTAssertEqual(a.replacedFields, 0)
        let uncertain = try Fixture(completeOld: false), b = try uncertain.plan(uncertain.source)
        XCTAssertEqual(b.renderedJSON, uncertain.source); XCTAssertFalse(b.requiresManifestContract)
    }

    func testBrowserUnknownAndPendingPayloadsRemainWholeInlineEvenWhenLarge() throws {
        let f = try Fixture(), object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
        var input = try XCTUnwrap(object["input"] as? [[String: Any]])
        let literal = String(repeating: "NEVER_ELIDE_BROWSER_OR_UNKNOWN ", count: 150)
        input += [["type": "function_call", "call_id": "browser_inert", "name": "browser_read", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "browser_inert", "output": literal],
            ["type": "function_call", "call_id": "pending_inert", "name": "exec_command", "arguments": #"{"cmd":""# + literal + #""}"#],
            ["type": "unknown_native_item", "output": literal]]
        let source = try Fixture.frame(model: f.binding.scope.modelID, items: input)
        let native = try J.parse(source), plan = try f.plan(source), display = try J.parse(plan.renderedJSON)
        for id in ["browser_inert", "pending_inert"] {
            let before = try XCTUnwrap(native.items.first { $0.callID == id })
            let after = try XCTUnwrap(display.items.first { $0.callID == id })
            XCTAssertEqual(try native.rawBytes(in: before.wholeRange), try display.rawBytes(in: after.wholeRange))
        }
        XCTAssertTrue(String(decoding: plan.renderedJSON, as: UTF8.self).contains(literal))
    }

    func testLookupRevisionIgnoresOnlyConfigurationLexemesWhileRawSourceAndValuesStayBound() throws {
        let f = try Fixture(), first = try f.plan(f.source)
        let ref = try reference(first, id: "call_old", field: .output)
        let read = try f.read(first, ref: ref, id: "read_config_lexical", maximum: 64)
        let next = try f.appendRead(to: f.source, id: "read_config_lexical", arguments: read.0, response: read.1.responseData)
        let layout = try J.parse(next)
        let foreign = try XCTUnwrap(layout.rootOtherMembers.first { $0.key == "foreign" }?.valueRange)
        func replacing(_ range: Range<Int>, with bytes: Data) -> Data {
            var data = next.subdata(in: 0..<range.lowerBound)
            data.append(bytes); data.append(next.subdata(in: range.upperBound..<next.count)); return data
        }
        // Ordinary continuation already treats these as identical JSON values:
        // only key order, whitespace, exact numeric spelling and a string escape.
        let lexical = replacing(foreign, with: Data(#"{ "text":"foreign-lexeme", "number":12300.0 }"#.utf8))
        XCTAssertNotEqual(lexical, next)
        let stable = try f.plan(lexical, previous: first.snapshot, publications: [read.2])
        XCTAssertEqual(stable.snapshot.contextRevision, first.snapshot.contextRevision)
        XCTAssertEqual(stable.snapshot.nativeHTTPSourceSHA256, sha(lexical))
        XCTAssertNotEqual(stable.snapshot.nativeHTTPSourceSHA256, sha(next))
        XCTAssertTrue(stable.isCurrent())
        #if DEBUG
        let diagnostic = try XCTUnwrap(stable.revisionDiagnostics)
        XCTAssertEqual(diagnostic.nativeConfigEqual, true); XCTAssertTrue(diagnostic.lookupOnly)
        XCTAssertEqual(diagnostic.selectedSchemasEqual, true); XCTAssertEqual(diagnostic.candidatePolicyEqual, true)
        XCTAssertTrue(diagnostic.preserveRevision)
        #endif
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: read.1.responseData) as? [String: Any])
        let cursor = try XCTUnwrap(response["next_ref"] as? String)
        let cursorArgs = try json(["ref": cursor])
        let fragment = try M.prepareRead(stable.snapshot,
            issued: f.issued(stable.snapshot, arguments: cursorArgs, id: "read_config_next"), maximumBytes: 64)
        let chunk = try XCTUnwrap(JSONSerialization.jsonObject(with: fragment.responseData) as? [String: Any])
        XCTAssertEqual(chunk["context_revision"] as? String, first.snapshot.contextRevision)
        XCTAssertEqual(chunk["start_byte"] as? Int, response["end_byte"] as? Int)
        // Exact old-source binding remains mandatory even when its configuration
        // is value-equivalent to the current source.
        XCTAssertThrowsError(try M.prepareRead(stable.snapshot,
            issued: f.issued(first.snapshot, arguments: cursorArgs, id: "read_config_old_source"), maximumBytes: 64)) {
            XCTAssertEqual($0 as? M.Failure, .binding)
        }
        let policy = try XCTUnwrap(layout.instructionsRange)
        let tools = try XCTUnwrap(layout.toolsRange)
        let realChanges = [
            replacing(foreign, with: Data(#"{"number":12301,"text":"foreign-lexeme"}"#.utf8)),
            replacing(policy, with: try json("Actually changed native policy")),
            replacing(tools, with: try json([Fixture.tools.last!])),
        ]
        for changed in realChanges {
            let rotated = try f.plan(changed, previous: first.snapshot, publications: [read.2])
            XCTAssertNotEqual(rotated.snapshot.contextRevision, first.snapshot.contextRevision)
            #if DEBUG
            XCTAssertEqual(rotated.revisionDiagnostics?.nativeConfigEqual, false)
            XCTAssertEqual(rotated.revisionDiagnostics?.preserveRevision, false)
            #endif
            XCTAssertThrowsError(try M.prepareRead(rotated.snapshot,
                issued: f.issued(rotated.snapshot, arguments: cursorArgs, id: "read_config_changed"), maximumBytes: 64)) {
                XCTAssertEqual($0 as? M.Failure, .unknownReference)
            }
        }
        let user = try XCTUnwrap(layout.items.first { $0.role == "user" })
        let oldUser = try layout.rawBytes(in: user.wholeRange)
        var userLexical = Data(" ".utf8); userLexical.append(oldUser)
        XCTAssertThrowsError(try f.plan(replacing(user.wholeRange, with: userLexical),
            previous: first.snapshot, publications: [read.2])) {
            XCTAssertEqual($0 as? M.Failure, .layout, "The retained input prefix stays byte-exact")
        }
        XCTAssertThrowsError(try f.plan(replacing(user.wholeRange, with: try json(["role": "user", "content": "Changed human task"])),
            previous: first.snapshot, publications: [read.2])) {
            XCTAssertEqual($0 as? M.Failure, .layout)
        }
    }

    func testActualLookupAppendKeepsRevisionWithoutPredictingRootOrNewPairSerialization() throws {
        let f = try Fixture(), first = try f.plan(f.source)
        let ref = try reference(first, id: "call_old", field: .output)
        let read = try f.read(first, ref: ref, id: "read_one")
        let next = try f.appendRead(to: f.source, id: "read_one", arguments: read.0, response: read.1.responseData)
        XCTAssertNotEqual(try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: next), options: [.sortedKeys]), next)
        let second = try f.plan(next, previous: first.snapshot, publications: [read.2])
        XCTAssertEqual(second.snapshot.contextRevision, first.snapshot.contextRevision)
        let nextLayout = try J.parse(next), displayed = try J.parse(second.renderedJSON)
        let sourceOutput = try XCTUnwrap(nextLayout.items.first { $0.callID == "read_one" && $0.kind == .functionCallOutput })
        let displayOutput = try XCTUnwrap(displayed.items.first { $0.callID == "read_one" && $0.kind == .functionCallOutput })
        XCTAssertEqual(try nextLayout.rawBytes(in: sourceOutput.wholeRange), try displayed.rawBytes(in: displayOutput.wholeRange))
    }

    func testUncommittedWrongOrReplayedLookupPublicationCannotStabilizeHistory() throws {
        let f = try Fixture(), plan = try f.plan(f.source)
        let ref = try reference(plan, id: "call_old", field: .output)
        let read = try f.read(plan, ref: ref, id: "read_one")
        let next = try f.appendRead(to: f.source, id: "read_one", arguments: read.0, response: read.1.responseData)
        XCTAssertThrowsError(try f.plan(next, previous: plan.snapshot))
        XCTAssertThrowsError(try M.commitLookupPublication(f.reader, ticket: read.1.publicationTicket,
            binding: f.binding, contextNonce: f.nonce, responseData: Data("changed".utf8)))
        XCTAssertThrowsError(try f.plan(next, previous: plan.snapshot, publications: [read.2, read.2]))
        let admitted = try f.plan(next, previous: plan.snapshot, publications: [read.2])
        XCTAssertThrowsError(try f.plan(next, previous: admitted.snapshot, publications: [read.2]))
    }

    func testUTF8PaginationReassemblesExactJSONTokenAndOnlyActualAppendActivatesNextRef() throws {
        let f = try Fixture(), initial = try f.plan(f.source), sourceLayout = try J.parse(f.source)
        let raw = try XCTUnwrap(sourceLayout.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload?.rawJSON)
        var current = initial, frame = f.source, ref = try reference(initial, id: "call_old", field: .output)
        var rebuilt = Data(), calls = 0
        while calls < 8 {
            let id = "read_chunk_" + String(calls), read = try f.read(current, ref: ref, id: id)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: read.1.responseData) as? [String: Any])
            XCTAssertEqual(response["historical_only"] as? Bool, true); XCTAssertEqual(response["action_authority"] as? Bool, false)
            XCTAssertEqual(response["value_encoding"] as? String, "json")
            rebuilt.append(Data(try XCTUnwrap(response["utf8_fragment"] as? String).utf8))
            if let nextRef = response["next_ref"] as? String {
                XCTAssertNotNil(referenceBytes(nextRef)); XCTAssertNotEqual(nextRef, ref)
                let args = try json(["ref": nextRef])
                XCTAssertThrowsError(try M.prepareRead(current.snapshot, issued: f.issued(current.snapshot, arguments: args, id: id + "_early"), maximumBytes: 4_096))
            }
            frame = try f.appendRead(to: frame, id: id, arguments: read.0, response: read.1.responseData)
            current = try f.plan(frame, previous: current.snapshot, publications: [read.2])
            XCTAssertEqual(current.snapshot.contextRevision, initial.snapshot.contextRevision)
            calls += 1
            guard let nextRef = response["next_ref"] as? String else { break }; ref = nextRef
        }
        XCTAssertGreaterThan(calls, 1); XCTAssertLessThan(calls, 8); XCTAssertEqual(rebuilt, raw)
        XCTAssertEqual(sha(rebuilt), sha(raw))
    }

    func testOlderCommittedLookupOutputMayBeReferencedButLatestLookupOutputIsInline() throws {
        let f = try Fixture(), a = try f.plan(f.source)
        let ref = try reference(a, id: "call_old", field: .output)
        let first = try f.read(a, ref: ref, id: "read_one")
        let frame1 = try f.appendRead(to: f.source, id: "read_one", arguments: first.0, response: first.1.responseData)
        let b = try f.plan(frame1, previous: a.snapshot, publications: [first.2])
        let second = try f.read(b, ref: ref, id: "read_two")
        let frame2 = try f.appendRead(to: frame1, id: "read_two", arguments: second.0, response: second.1.responseData)
        let c = try f.plan(frame2, previous: b.snapshot, publications: [second.2])
        let lookupRef = try reference(c, id: "read_one", field: .output)
        let lookup = try f.read(c, ref: lookupRef, id: "read_older_lookup")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: lookup.1.responseData) as? [String: Any])
        let original = try json(String(decoding: first.1.responseData, as: UTF8.self))
        XCTAssertEqual(metadata["source_kind"] as? String, "lookup")
        XCTAssertEqual(metadata["source_call_id"] as? String, "read_one")
        XCTAssertEqual(metadata["source_name"] as? String, M.readerName)
        XCTAssertEqual(metadata["field"] as? String, "output")
        XCTAssertEqual(metadata["whole_bytes"] as? Int, original.count)
        XCTAssertEqual(metadata["whole_sha256"] as? String, sha(original))
        let fragment = Data(try XCTUnwrap(metadata["utf8_fragment"] as? String).utf8)
        XCTAssertEqual(fragment, Data(original.prefix(fragment.count)))
        let layout = try J.parse(c.renderedJSON)
        XCTAssertEqual(layout.items.first { $0.callID == "read_two" && $0.kind == .functionCallOutput }?.payload?.literalUTF8, second.1.responseData)
        XCTAssertTrue(c.isCurrent())
    }

    func testSubstantiveUserOrSelectedSchemaChangeRevokesOldRevision() throws {
        let f = try Fixture(), old = try f.plan(f.source)
        let oldRef = try reference(old, id: "call_old", field: .output)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.source) as? [String: Any])
        var input = try XCTUnwrap(object["input"] as? [[String: Any]])
        input.append(["role": "user", "content": "New current user steering, preserved inline."])
        let changed = try Fixture.frame(model: f.binding.scope.modelID, items: input)
        let next = try f.plan(changed, previous: old.snapshot)
        XCTAssertNotEqual(next.snapshot.contextRevision, old.snapshot.contextRevision)
        let args = try json(["ref": oldRef])
        XCTAssertThrowsError(try M.prepareRead(next.snapshot, issued: f.issued(old.snapshot, arguments: args, id: "read_old_source"), maximumBytes: 64)) {
            XCTAssertEqual($0 as? M.Failure, .binding)
        }
        XCTAssertThrowsError(try M.prepareRead(next.snapshot, issued: f.issued(next.snapshot, arguments: args, id: "read_stale"), maximumBytes: 64)) {
            XCTAssertEqual($0 as? M.Failure, .unknownReference)
        }
        let oldLayout = try J.parse(f.source), toolRange = try XCTUnwrap(oldLayout.toolsRange)
        let candidate = f.source.subdata(in: 0..<toolRange.lowerBound) + (try json([Fixture.tools.last!]))
            + f.source.subdata(in: toolRange.upperBound..<f.source.count)
        let fallback = try f.plan(f.source, candidate: candidate)
        XCTAssertNotEqual(fallback.snapshot.contextRevision, old.snapshot.contextRevision)
        XCTAssertThrowsError(try M.prepareRead(fallback.snapshot, issued: f.issued(fallback.snapshot, arguments: args, id: "read_unused_plan"), maximumBytes: 64))
    }

    func testForeignBindingNonceSourceAndAuthorityNeverBorrowSnapshot() throws {
        let f = try Fixture(), plan = try f.plan(f.source), fields = try f.fields(f.source)
        XCTAssertThrowsError(try M(binding: f.binding, contextNonce: UUID(), nativeLayout: J.parse(f.source),
            eligibleFields: fields, previous: plan.snapshot, readerAuthority: f.reader))
        let other = try M.makeReaderAuthority(binding: f.binding, contextNonce: f.nonce,
            registeredName: M.readerName, registrationSHA256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try M(binding: f.binding, contextNonce: f.nonce, nativeLayout: J.parse(f.source),
            eligibleFields: fields, previous: plan.snapshot, readerAuthority: other))
        let changed = Data(String(decoding: f.source, as: UTF8.self).replacingOccurrences(of: "policy\\u0061", with: "policychanged").utf8)
        XCTAssertThrowsError(try M(binding: f.binding, contextNonce: f.nonce, nativeLayout: J.parse(changed),
            eligibleFields: fields, previous: nil, readerAuthority: f.reader))
    }

    func testRevokedIndividualPublicationKillsProjectReadCommitAndTransitiveLookup() throws {
        let f = try Fixture(), plan = try f.plan(f.source)
        let ref = try reference(plan, id: "call_old", field: .output)
        let read = try f.read(plan, ref: ref, id: "read_before_duplicate")
        let fields = try f.fields(f.source), seed = try f.projector(f.source)
        XCTAssertFalse(f.writer.recordCompleted(current: f.binding.scope, itemID: "call_old", terminal: .command(status: .completed, exitCode: 0)))
        XCTAssertTrue(f.writer.isCurrent(current: f.binding.scope)); XCTAssertFalse(plan.isCurrent())
        XCTAssertTrue(fields.contains { !$0.isCurrent() })
        XCTAssertThrowsError(try seed.project(candidateLayout: J.parse(f.source),
            fullSchemaSHA256: toolsSHA(f.source), selectedSchemaSHA256: toolsSHA(f.source)))
        XCTAssertThrowsError(try M.prepareRead(plan.snapshot, issued: f.issued(plan.snapshot, arguments: read.0, id: "read_revoked"), maximumBytes: 64))
        XCTAssertThrowsError(try M.commitLookupPublication(f.reader, ticket: read.1.publicationTicket,
            binding: f.binding, contextNonce: f.nonce, responseData: read.1.responseData))
    }

    func testPreviewKeepsNewTailInlineAndReturnsOnlyBytesWithoutPublishingItsRefs() throws {
        let f = try Fixture(), plan = try f.plan(f.source)
        let layout = try J.parse(f.source), end = try XCTUnwrap(layout.items.last?.wholeRange.upperBound)
        let prefix = try layout.rawBytes(in: layout.inputRange.lowerBound..<end)
        let extra = Data(", {\"type\":\"function_call\",\"call_id\":\"preview_loader\",\"name\":\"computa_load_tools\",\"arguments\":\"{}\"},{\"type\":\"function_call_output\",\"call_id\":\"preview_loader\",\"output\":\"HOST_PREVIEW_INLINE\"}".utf8)
        let preview = f.source.subdata(in: 0..<layout.inputRange.lowerBound) + prefix + extra
            + f.source.subdata(in: end..<f.source.count)
        let sourceLayout = try J.parse(preview), seed = try f.projector(f.source)
        let bytes = try seed.projectPreview(candidateLayout: sourceLayout, hostPreviewLayout: sourceLayout,
            fullSchemaSHA256: toolsSHA(f.source), selectedSchemaSHA256: toolsSHA(preview))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("HOST_PREVIEW_INLINE"))
        let alteredTail = Data(String(decoding: preview, as: UTF8.self).replacingOccurrences(of: "HOST_PREVIEW_INLINE", with: "short").utf8)
        XCTAssertThrowsError(try seed.projectPreview(candidateLayout: J.parse(alteredTail), hostPreviewLayout: sourceLayout,
            fullSchemaSHA256: toolsSHA(f.source), selectedSchemaSHA256: toolsSHA(preview)))
        XCTAssertThrowsError(try seed.project(candidateLayout: sourceLayout,
            fullSchemaSHA256: toolsSHA(f.source), selectedSchemaSHA256: toolsSHA(preview)))
        XCTAssertEqual(plan.snapshot.nativeHTTPSourceSHA256, sha(f.source))
    }

    func testCountOnlyHostAppendMayReferenceProvenPriorLatestWithoutPublishingIt() throws {
        let f = try Fixture()
        let latestText = String(repeating: "NATIVE_LATEST_LITERAL_", count: 300)
        let native = Data(String(decoding: f.source, as: UTF8.self)
            .replacingOccurrences(of: "LATEST_NATIVE_OBSERVATION_INLINE", with: latestText).utf8)
        let layout = try J.parse(native), seed = try f.projector(native)
        let schema = try toolsSHA(native)
        let actual = try seed.project(candidateLayout: layout,
            fullSchemaSHA256: schema, selectedSchemaSHA256: schema)
        let original = try XCTUnwrap(layout.items.first {
            $0.callID == "call_latest" && $0.kind == .functionCallOutput
        }?.payload)
        let actualLayout = try J.parse(actual.renderedJSON)
        XCTAssertEqual(actualLayout.items.first {
            $0.callID == "call_latest" && $0.kind == .functionCallOutput
        }?.payload?.rawJSON, original.rawJSON)

        let end = try XCTUnwrap(layout.items.last?.wholeRange.upperBound)
        let hostText = String(repeating: "HOST_PREVIEW_LATEST_INLINE_", count: 200)
        let call = Data(#",{"type":"function_call","call_id":"preview_loader","name":"computa_load_tools","arguments":"{}"}"#.utf8)
        let output = Data(#",{"type":"function_call_output","call_id":"preview_loader","output":"#.utf8)
            + (try json(hostText)) + Data("}".utf8)
        var host = native.subdata(in: 0..<end)
        host.append(call); host.append(output); host.append(native.subdata(in: end..<native.count))
        let hostLayout = try J.parse(host)
        let forecast = try seed.projectPreview(candidateLayout: hostLayout, hostPreviewLayout: hostLayout,
            fullSchemaSHA256: schema, selectedSchemaSHA256: schema)
        let forecastLayout = try J.parse(forecast)
        let replacement = try XCTUnwrap(forecastLayout.items.first {
            $0.callID == "call_latest" && $0.kind == .functionCallOutput
        }?.payload)
        XCTAssertNotEqual(replacement.rawJSON, original.rawJSON)
        let wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: replacement.rawJSON) as? [String: Any])
        XCTAssertEqual(Set(wrapper.keys), ["$computa_history"])
        let ref = try XCTUnwrap(wrapper["$computa_history"] as? String)
        XCTAssertNotNil(referenceBytes(ref))
        for (before, after) in zip(hostLayout.items.dropFirst(layout.items.count), forecastLayout.items.dropFirst(layout.items.count)) {
            XCTAssertEqual(try hostLayout.rawBytes(in: before.wholeRange), try forecastLayout.rawBytes(in: after.wholeRange))
        }
        XCTAssertEqual(forecastLayout.items.count, hostLayout.items.count)

        // Preview returned Data only: its reference is absent from the actual
        // snapshot, and its hypothetical result did not mutate the native seed.
        let arguments = try json(["ref": ref])
        let issued = try f.issued(actual.snapshot, arguments: arguments, id: "read_preview_only")
        XCTAssertThrowsError(try M.prepareRead(actual.snapshot, issued: issued, maximumBytes: 64)) {
            XCTAssertEqual($0 as? M.Failure, .unknownReference)
        }
        let unchanged = try seed.project(candidateLayout: layout,
            fullSchemaSHA256: schema, selectedSchemaSHA256: schema)
        XCTAssertEqual(unchanged.renderedJSON, actual.renderedJSON)
        let noNewResult = try seed.projectPreview(candidateLayout: layout, hostPreviewLayout: layout,
            fullSchemaSHA256: schema, selectedSchemaSHA256: schema)
        XCTAssertEqual(try J.parse(noNewResult).items.first {
            $0.callID == "call_latest" && $0.kind == .functionCallOutput
        }?.payload?.rawJSON, original.rawJSON)
        let changedTail = Data(String(decoding: host, as: UTF8.self)
            .replacingOccurrences(of: hostText, with: "CHANGED_HOST_TAIL").utf8)
        XCTAssertThrowsError(try seed.projectPreview(candidateLayout: J.parse(changedTail), hostPreviewLayout: hostLayout,
            fullSchemaSHA256: schema, selectedSchemaSHA256: schema))
        XCTAssertThrowsError(try seed.project(candidateLayout: hostLayout,
            fullSchemaSHA256: schema, selectedSchemaSHA256: schema))
    }

    func testLookupArgumentsAndBoundsRemainClosedAndForgedReferencesFail() throws {
        let f = try Fixture(), plan = try f.plan(f.source)
        let ref = try reference(plan, id: "call_old", field: .output)
        let args = try json(["ref": ref])
        for value in [Data((String(String(decoding: args, as: UTF8.self).dropLast()) + ",\"extra\":true}").utf8),
                      Data(#"{"context_revision":"x","ref":"x"}"#.utf8)] {
            XCTAssertThrowsError(try f.issued(plan.snapshot, arguments: value, id: "read_bad"))
        }
        let issued = try f.issued(plan.snapshot, arguments: args, id: "read_bound")
        for bound in [0, 63, 4_097] { XCTAssertThrowsError(try M.prepareRead(plan.snapshot, issued: issued, maximumBytes: bound)) }
        let different = (ref.first == "A" ? "B" : "A") + String(ref.dropFirst())
        let forged = try json(["ref": different])
        XCTAssertThrowsError(try M.prepareRead(plan.snapshot, issued: f.issued(plan.snapshot, arguments: forged, id: "read_forged"), maximumBytes: 64))
    }

    func testRefOnlyEncodingRetainsAll128DigestBitsAndFullReaderIdentity() throws {
        let f = try Fixture(), plan = try f.plan(f.source), layout = try J.parse(f.source)
        let ref = try reference(plan, id: "call_old", field: .output)
        let original = try XCTUnwrap(layout.items.first { $0.callID == "call_old" && $0.kind == .functionCallOutput }?.payload?.rawJSON)
        XCTAssertEqual(referenceBytes(ref), referenceDigest(revision: plan.snapshot.contextRevision,
            key: "call_old:output", rawJSON: original))
        XCTAssertEqual(plan.snapshot.contextRevision.utf8.count, 64)
        let (_, proposal, _) = try f.read(plan, ref: ref, id: "read_ref_only", maximum: 64)
        try assertReadIdentity(proposal.responseData, plan: plan, ref: ref, callID: "call_old",
            name: "exec_command", kind: "function", field: "output", rawJSON: original)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: proposal.responseData) as? [String: Any])
        let next = try XCTUnwrap(response["next_ref"] as? String), end = try XCTUnwrap(response["end_byte"] as? Int)
        XCTAssertNotEqual(next, ref)
        XCTAssertEqual(referenceBytes(next), referenceDigest(revision: plan.snapshot.contextRevision,
            key: "call_old:output:offset:" + String(end), rawJSON: original))
        let foreign = try Fixture(), foreignPlan = try foreign.plan(foreign.source)
        let foreignRef = try reference(foreignPlan, id: "call_old", field: .output)
        XCTAssertNotEqual(foreignRef, ref)
        let foreignArgs = try json(["ref": foreignRef])
        XCTAssertThrowsError(try M.prepareRead(plan.snapshot,
            issued: f.issued(plan.snapshot, arguments: foreignArgs, id: "read_foreign_ref"), maximumBytes: 64)) {
            XCTAssertEqual($0 as? M.Failure, .unknownReference)
        }
        let ownArgs = try json(["ref": ref])
        XCTAssertThrowsError(try M.prepareRead(plan.snapshot,
            issued: foreign.issued(foreignPlan.snapshot, arguments: ownArgs, id: "read_foreign_authority"), maximumBytes: 64)) {
            XCTAssertEqual($0 as? M.Failure, .binding)
        }
    }

    func testRefOnlyArgumentsRejectLegacyFieldsEscapesAliasesDuplicatesAndPadding() throws {
        let f = try Fixture(), plan = try f.plan(f.source), ref = try reference(plan, id: "call_old", field: .output)
        let aliases: [Character: Character] = ["A": "B", "Q": "R", "g": "h", "w": "x"]
        let last = try XCTUnwrap(ref.last), alias = String(ref.dropLast()) + String(try XCTUnwrap(aliases[last]))
        XCTAssertNil(referenceBytes(alias), "Nonzero unused padding bits are not a canonical spelling")
        let invalid = [
            try json(["context_revision": plan.snapshot.contextRevision, "ref": ref]),
            try json(["ref": ref, "extra": true]), try json(["ref": alias]), try json(["ref": ref + "=="]),
            try json(["ref": UUID().uuidString.lowercased()]), try json(["ref": String(repeating: "/", count: 22)]),
            try json(["ref": true]), try json(["ref": [ref]]), try json(["ref": NSNull()]),
            Data(("{\"ref\":\"" + ref + "\",\"ref\":\"" + ref + "\"}").utf8),
            Data(#"{"ref":"\u0041AAAAAAAAAAAAAAAAAAAAA"}"#.utf8),
            Data((String(repeating: " ", count: 513) + "{}").utf8),
        ]
        for (index, value) in invalid.enumerated() {
            XCTAssertThrowsError(try f.issued(plan.snapshot, arguments: value, id: "read_invalid_" + String(index))) {
                XCTAssertEqual($0 as? M.Failure, .arguments)
            }
        }
        let whitespace = Data((" \n { \"ref\" \t: \"" + ref + "\" } \r ").utf8)
        let issued = try f.issued(plan.snapshot, arguments: whitespace, id: "read_whitespace")
        let read = try M.prepareRead(plan.snapshot, issued: issued, maximumBytes: 64)
        try assertReadIdentity(read.responseData, plan: plan, ref: ref, callID: "call_old",
            name: "exec_command", kind: "function", field: "output", rawJSON: try XCTUnwrap(J.parse(f.source).items.first {
                $0.callID == "call_old" && $0.kind == .functionCallOutput
            }?.payload?.rawJSON))
    }

    #if DEBUG
    func testRevisionDiagnosticsDistinguishExactReaderAppendFromEachEpochFenceWithoutChangingIt() throws {
        let f = try Fixture(), first = try f.plan(f.source), initial = try XCTUnwrap(first.revisionDiagnostics)
        XCTAssertFalse(initial.hadPrevious); XCTAssertFalse(initial.lookupOnly); XCTAssertFalse(initial.preserveRevision)
        XCTAssertNil(initial.nativeConfigEqual); XCTAssertNil(initial.selectedSchemasEqual); XCTAssertNil(initial.candidatePolicyEqual)
        XCTAssertNil(initial.previousItemCount); XCTAssertNil(initial.appendedItems)
        XCTAssertEqual(initial.nativeItemCount, try J.parse(f.source).items.count)
        let ref = try reference(first, id: "call_old", field: .output), read = try f.read(first, ref: ref, id: "read_diagnostic")
        let next = try f.appendRead(to: f.source, id: "read_diagnostic", arguments: read.0, response: read.1.responseData)
        let plan = try f.plan(next, previous: first.snapshot, publications: [read.2])
        let stable = try XCTUnwrap(plan.revisionDiagnostics)
        XCTAssertTrue(stable.hadPrevious); XCTAssertTrue(stable.lookupOnly); XCTAssertTrue(stable.preserveRevision)
        XCTAssertEqual(stable.nativeConfigEqual, true); XCTAssertEqual(stable.selectedSchemasEqual, true); XCTAssertEqual(stable.candidatePolicyEqual, true)
        XCTAssertEqual(stable.previousItemCount, initial.nativeItemCount); XCTAssertEqual(stable.nativeItemCount, initial.nativeItemCount + 2)
        XCTAssertEqual(stable.appendedItems, 2); XCTAssertEqual(stable.appendedCalls, 1); XCTAssertEqual(stable.appendedOutputs, 1)
        XCTAssertEqual(stable.appendedOther, 0); XCTAssertEqual(stable.readerCalls, 1); XCTAssertEqual(stable.committedReaderPairs, 1)
        XCTAssertFalse(stable.countsSaturated)
        XCTAssertEqual(plan.snapshot.contextRevision, first.snapshot.contextRevision)
        let layout = try J.parse(next), tools = try XCTUnwrap(layout.toolsRange)
        var lexical = next.subdata(in: 0..<tools.lowerBound)
        lexical.append(Data("[ ".utf8)); lexical.append(next.subdata(in: tools.lowerBound + 1..<next.count))
        let changedConfig = try f.plan(lexical, previous: first.snapshot, publications: [read.2])
        let config = try XCTUnwrap(changedConfig.revisionDiagnostics)
        XCTAssertEqual(config.nativeConfigEqual, true); XCTAssertTrue(config.lookupOnly)
        XCTAssertEqual(config.selectedSchemasEqual, false); XCTAssertFalse(config.preserveRevision)
        XCTAssertEqual(config.committedReaderPairs, 1); XCTAssertEqual(config.appendedItems, 2)
        XCTAssertNotEqual(changedConfig.snapshot.contextRevision, first.snapshot.contextRevision)
        let subset = next.subdata(in: 0..<tools.lowerBound) + (try json([Fixture.tools.last!])) + next.subdata(in: tools.upperBound..<next.count)
        let changedSchema = try f.plan(next, previous: first.snapshot, publications: [read.2], candidate: subset)
        let schema = try XCTUnwrap(changedSchema.revisionDiagnostics)
        XCTAssertEqual(schema.nativeConfigEqual, true); XCTAssertTrue(schema.lookupOnly)
        XCTAssertEqual(schema.selectedSchemasEqual, false); XCTAssertEqual(schema.candidatePolicyEqual, true); XCTAssertFalse(schema.preserveRevision)
        let policyRange = try XCTUnwrap(layout.instructionsRange)
        let policyCandidate = next.subdata(in: 0..<policyRange.lowerBound) + (try json("Changed candidate policy")) + next.subdata(in: policyRange.upperBound..<next.count)
        let changedPolicy = try f.plan(next, previous: first.snapshot, publications: [read.2], candidate: policyCandidate)
        let policy = try XCTUnwrap(changedPolicy.revisionDiagnostics)
        XCTAssertEqual(policy.nativeConfigEqual, true); XCTAssertTrue(policy.lookupOnly)
        XCTAssertEqual(policy.selectedSchemasEqual, true); XCTAssertEqual(policy.candidatePolicyEqual, false); XCTAssertFalse(policy.preserveRevision)
        let encoded = try JSONEncoder().encode(stable)
        let shape = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(shape.keys), ["hadPrevious", "lookupOnly", "nativeConfigEqual", "selectedSchemasEqual", "candidatePolicyEqual",
            "previousItemCount", "nativeItemCount", "appendedItems", "appendedCalls", "appendedOutputs", "appendedOther", "readerCalls",
            "committedReaderPairs", "preserveRevision", "countsSaturated"])
        XCTAssertTrue(shape.values.allSatisfy { $0 is NSNumber })
        XCTAssertEqual(try f.plan(next, previous: first.snapshot, publications: [read.2]).renderedJSON, plan.renderedJSON)
    }

    #endif

    private func reference(_ plan: M.Plan, id: String, field: J.PayloadField) throws -> String {
        let layout = try J.parse(plan.renderedJSON)
        let payload = try XCTUnwrap(layout.items.first { $0.callID == id && $0.payload?.field == field }?.payload)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.rawJSON) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["$computa_history"])
        let ref = try XCTUnwrap(value["$computa_history"] as? String)
        XCTAssertNotNil(referenceBytes(ref))
        return ref
    }
    private func assertReadIdentity(_ bytes: Data, plan: M.Plan, ref: String, callID: String,
        name: String, kind: String, field: String, rawJSON: Data) throws {
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(response.keys), ["context_revision", "ref", "source_call_id", "source_name", "source_kind",
            "field", "value_encoding", "whole_bytes", "whole_sha256", "start_byte", "end_byte", "utf8_fragment",
            "next_ref", "historical_only", "action_authority"])
        XCTAssertEqual(response["context_revision"] as? String, plan.snapshot.contextRevision)
        XCTAssertEqual(response["ref"] as? String, ref)
        XCTAssertEqual(response["source_call_id"] as? String, callID)
        XCTAssertEqual(response["source_name"] as? String, name)
        XCTAssertEqual(response["source_kind"] as? String, kind)
        XCTAssertEqual(response["field"] as? String, field)
        XCTAssertEqual(response["value_encoding"] as? String, "json")
        XCTAssertEqual(response["whole_bytes"] as? Int, rawJSON.count)
        XCTAssertEqual(response["whole_sha256"] as? String, sha(rawJSON))
        XCTAssertEqual(response["historical_only"] as? Bool, true)
        XCTAssertEqual(response["action_authority"] as? Bool, false)
    }
    private func toolsSHA(_ bytes: Data) throws -> String {
        let layout = try J.parse(bytes); return try sha(layout.rawBytes(in: XCTUnwrap(layout.toolsRange)))
    }
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
}
private func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

private func referenceBytes(_ value: String) -> Data? {
    guard value.utf8.count == 22, value.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }), let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="),
        bytes.count == 16 else { return nil }
    let canonical = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return canonical == value ? bytes : nil
}
private func referenceDigest(revision: String, key: String, rawJSON: Data) -> Data {
    var joined = Data()
    for part in [Data(revision.utf8), Data(key.utf8), Data(sha(rawJSON).utf8)] {
        joined.append(Data("\(part.count):".utf8)); joined.append(part)
    }
    return Data(SHA256.hash(data: joined).prefix(16))
}

import Foundation
import XCTest
@testable import Computa

@MainActor
final class WebsiteDispatchProfileTests: XCTestCase {
    private let task = "7489d029-98e8-4bb0-81cf-54bf7ee7d3ba"
    private let request = "946f2fc9-dcfb-49b4-bfb8-e176be18ed43"
    private let model = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant").modelID

    func testOnlyCanonicalIdentifiersAndChatGPTCanProduceProfileMetadata() {
        XCTAssertNil(WebsiteDispatchProfile.begin(taskID: "PRIVATE_TASK_PATH", modelID: model, origin: .webUI))
        XCTAssertNil(WebsiteDispatchProfile.begin(taskID: task, modelID: model, requestID: "PRIVATE_REQUEST", origin: .webUI))
        for other in ["browser/gemini", "browser/claude", "api/cerebras/model/private", "PRIVATE_MODEL"] {
            XCTAssertNil(WebsiteDispatchProfile.begin(taskID: task, modelID: other, origin: .runtime))
        }
        XCTAssertNotNil(WebsiteDispatchProfile.begin(taskID: task, modelID: model, requestID: request, origin: .webUI))
    }

    func testQueueTaskAndRuntimeActorInheritTheSameIngressProfileWithoutLeakingIt() async throws {
        let profile = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: request, origin: .webUI))
        let probe = DispatchProfileActor()
        let inherited = await WebsiteDispatchProfile.$current.withValue(profile) {
            let queued = Task { @MainActor in
                await probe.inherited(taskID: self.task, modelID: self.model)
            }
            return await queued.value
        }
        XCTAssertEqual(inherited, profile)
        XCTAssertNil(WebsiteDispatchProfile.current)
    }

    func testAnotherTaskOrExplicitRequestCannotReuseAnIngressTrace() throws {
        let profile = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: request, origin: .webUI))
        WebsiteDispatchProfile.$current.withValue(profile) {
            XCTAssertEqual(WebsiteDispatchProfile.matching(taskID: task), profile)
            XCTAssertNil(WebsiteDispatchProfile.matching(taskID: UUID().uuidString))
            XCTAssertNil(WebsiteDispatchProfile.begin(taskID: task, modelID: model, requestID: "PRIVATE_REQUEST", origin: .webUI))
            let other = WebsiteDispatchProfile.begin(taskID: task, modelID: model,
                requestID: "f7c2c109-82ea-4f1d-906b-7f6c6e3ebc51", origin: .webUI)
            XCTAssertNotNil(other); XCTAssertNotEqual(other, profile)
        }
        XCTAssertNil(WebsiteDispatchProfile.current)
    }

    func testDiagnosticDurationsAreFiniteNonnegativeAndCapped() {
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.nanoseconds(-1)), 0)
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.zero), 0)
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.microseconds(1_500)), 1)
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.seconds(600)), 600_000)
        XCTAssertEqual(WebsiteDispatchProfile.milliseconds(.seconds(Int64.max)), 600_000)
    }

    func testFIFOReorderAndDuplicateSchedulingKeepEachItemsOwnIngressProfile() async throws {
        let secondRequest = "f7c2c109-82ea-4f1d-906b-7f6c6e3ebc51"
        let first = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: request, origin: .webUI))
        let second = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: secondRequest, origin: .webUI))
        for reorder in [false, true] {
            let (state, runtime) = fixture(running: true)
            WebsiteDispatchProfile.$current.withValue(first) {
                XCTAssertTrue(state.acceptPrompt(prompt: "First", taskID: task, requestID: request))
            }
            await settleScheduledWork()
            let initiallySent = await runtime.calls
            XCTAssertTrue(initiallySent.isEmpty)
            makeIdle(state)
            WebsiteDispatchProfile.$current.withValue(second) {
                XCTAssertTrue(state.acceptPrompt(prompt: "Second", taskID: task, requestID: secondRequest))
                if reorder, let items = state.queuedPrompts[task] {
                    XCTAssertTrue(state.moveQueuedPrompt(taskID: task, id: items[1].id, beforeID: items[0].id))
                }
            }
            let one = try await observedCalls(1, runtime: runtime)
            XCTAssertEqual(one[0].prompt, reorder ? "Second" : "First")
            XCTAssertEqual(one[0].profile, reorder ? second : first)
            await settleScheduledWork()
            makeIdle(state)
            // A duplicate of the already delivered request schedules the
            // remaining FIFO item. Its task-local trace must not retarget it.
            WebsiteDispatchProfile.$current.withValue(reorder ? second : first) {
                XCTAssertTrue(state.acceptPrompt(prompt: reorder ? "Second" : "First", taskID: task,
                    requestID: reorder ? secondRequest : request))
            }
            let two = try await observedCalls(2, runtime: runtime)
            XCTAssertEqual(two.map(\.prompt), reorder ? ["Second", "First"] : ["First", "Second"])
            XCTAssertEqual(two[1].profile, reorder ? first : second)
            await settleScheduledWork()
            XCTAssertTrue(state.queuedPrompts[task, default: []].isEmpty)
        }
        XCTAssertNil(WebsiteDispatchProfile.current)
    }

    func testEditedOrDeletedQueueItemsCannotReuseTheirOriginalIngressProfile() async throws {
        let original = try XCTUnwrap(WebsiteDispatchProfile.begin(taskID: task, modelID: model,
            requestID: request, origin: .webUI))
        for deleting in [false, true] {
            let (state, runtime) = fixture(running: false)
            WebsiteDispatchProfile.$current.withValue(original) {
                XCTAssertTrue(state.acceptPrompt(prompt: "Original", taskID: task, requestID: request))
                guard let item = state.queuedPrompts[task]?.first else { XCTFail("Expected queued item"); return }
                if deleting {
                    XCTAssertTrue(state.deleteQueuedPrompt(taskID: task, id: item.id))
                    // This direct native submission has no web ingress trace.
                    XCTAssertTrue(state.acceptPrompt(prompt: "Replacement", taskID: task, requestID: "replacement"))
                } else {
                    XCTAssertTrue(state.beginQueueEdit(taskID: task, id: item.id))
                    XCTAssertTrue(state.editQueuedPrompt(taskID: task, id: item.id, prompt: "Edited"))
                }
            }
            let calls = try await observedCalls(1, runtime: runtime)
            XCTAssertEqual(calls[0].prompt, deleting ? "Replacement" : "Edited")
            XCTAssertNil(calls[0].profile)
        }
        XCTAssertNil(WebsiteDispatchProfile.current)
    }

    private func fixture(running: Bool) -> (AppState, DispatchProfileRuntime) {
        let runtime = DispatchProfileRuntime()
        let state = AppState(tasks: [AgentTask(id: task, title: "Dispatch fixture", summary: "",
            status: running ? .running : .draft, workspace: "/tmp", model: model)],
            runtime: runtime, preferences: isolatedTestPreferences())
        if running { state.activeTurnTaskIDs.insert(task) }
        state.connectionState = .connected(provider: runtime.providerName)
        return (state, runtime)
    }

    private func makeIdle(_ state: AppState) {
        state.activeTurnTaskIDs.remove(task)
        state.tasks[0].status = .draft
    }

    private func settleScheduledWork() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func observedCalls(_ count: Int, runtime: DispatchProfileRuntime) async throws -> [DispatchProfileRuntime.Call] {
        for _ in 0..<200 {
            let calls = await runtime.calls
            if calls.count >= count { return calls }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected fake-runtime dispatch was not observed")
        throw DispatchProfileRuntime.Failure()
    }
}

private actor DispatchProfileActor {
    func inherited(taskID: String, modelID: String) -> WebsiteDispatchProfile? {
        WebsiteDispatchProfile.begin(taskID: taskID, modelID: modelID, origin: .runtime)
    }
}

private actor DispatchProfileRuntime: AgentRuntimeClient {
    struct Failure: Error { }
    struct Call: Sendable {
        let prompt: String
        let profile: WebsiteDispatchProfile?
    }
    nonisolated let providerName = "Dispatch fixture runtime"
    private(set) var calls: [Call] = []
    func loadTasks() async throws -> [AgentTask] { [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID: AgentTask.ID, modelID: String) async throws {
        calls.append(Call(prompt: prompt, profile: WebsiteDispatchProfile.current))
    }
    func interrupt(taskID: AgentTask.ID) async throws { }
    func resolveApproval(requestID: String, approved: Bool) async throws { }
}

final class WebsiteResponseProfileTests: XCTestCase {
    func testPostSendProfileRejectsArbitraryIdentityOutOfScopeOrdinalAndOrigin() throws {
        let session = UUID().uuidString, inference = UUID()
        for invalid in ["", "PRIVATE_PAYLOAD_CANARY", "https://chatgpt.com/c/private", String(repeating: "x", count: 1_024)] {
            XCTAssertNil(WebsiteResponseProfile.begin(source: .nativeTurn, sessionToken: invalid, sequence: 1))
        }
        for sequence in [-1, 0, 17, Int.max] {
            XCTAssertNil(WebsiteResponseProfile.begin(source: .nativeTurn, sessionToken: session, sequence: sequence))
        }
        XCTAssertNil(WebsiteResponseProfile.begin(source: .nativeTurn, sessionToken: session, sequence: 1, inferenceID: inference))
        XCTAssertNil(WebsiteResponseProfile.begin(source: .serverAcknowledged, sessionToken: session, sequence: 1))
        XCTAssertNotNil(WebsiteResponseProfile.begin(source: .nativeTurn, sessionToken: session, sequence: 16))
        XCTAssertNotNil(WebsiteResponseProfile.begin(source: .serverAcknowledged, sessionToken: session, sequence: 1, inferenceID: inference))
    }

    func testEveryPostSendEventHasOnlyItsBoundedFiniteSchemaAndTrustedUUIDs() throws {
        let session = UUID(), inference = UUID(), started = ContinuousClock.now
        let phases = WebsiteResponseProfile.Phase.allCases
        XCTAssertEqual(Set(phases.map(\.rawValue)).count, phases.count)
        for phase in phases {
            let profile = try XCTUnwrap(WebsiteResponseProfile.begin(source: phase.source, sessionToken: session.uuidString,
                sequence: 2, inferenceID: phase.source == .nativeTurn ? nil : inference, started: started))
            let event = try XCTUnwrap(profile.event(phase, at: started + .milliseconds(125)))
            let data = try JSONEncoder().encode(event)
            XCTAssertLessThan(data.count, 512)
            let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var keys: Set<String> = ["version", "source", "phase", "sessionID", "sequence", "elapsedMs"]
            if phase.source == .serverAcknowledged { keys.insert("inferenceID") }
            XCTAssertEqual(Set(value.keys), keys)
            XCTAssertEqual(value["version"] as? Int, 1)
            XCTAssertEqual(value["source"] as? String, phase.source.rawValue)
            XCTAssertEqual(value["phase"] as? String, phase.rawValue)
            XCTAssertEqual((value["sessionID"] as? String).flatMap(UUID.init(uuidString:)), session)
            XCTAssertEqual(value["sequence"] as? Int, 2)
            XCTAssertEqual(value["elapsedMs"] as? Int, 125)
            XCTAssertEqual((value["inferenceID"] as? String).flatMap(UUID.init(uuidString:)),
                           phase.source == .nativeTurn ? nil : inference)
            for secret in ["PRIVATE_PAYLOAD_CANARY", "prompt", "cookie_value", "https://", "tool_arguments"] {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret), phase.rawValue)
            }
        }
    }

    func testPostSendClockBoundsAreDiagnosticAndNeverProduceUnboundedOrNegativeNumbers() throws {
        XCTAssertEqual(WebsiteResponseProfile.milliseconds(.nanoseconds(-1)), 0)
        XCTAssertEqual(WebsiteResponseProfile.milliseconds(.zero), 0)
        XCTAssertEqual(WebsiteResponseProfile.milliseconds(.microseconds(1_500)), 1)
        XCTAssertEqual(WebsiteResponseProfile.milliseconds(.seconds(600)), 600_000)
        XCTAssertEqual(WebsiteResponseProfile.milliseconds(.seconds(Int64.max)), 600_000)
        let start = ContinuousClock.now
        let profile = try XCTUnwrap(WebsiteResponseProfile.begin(source: .nativeTurn,
            sessionToken: UUID().uuidString, sequence: 1, started: start))
        XCTAssertEqual(profile.event(.firstPositive, at: start - .seconds(1))?.elapsedMs, 0)
        XCTAssertEqual(profile.event(.transportComplete, at: start + .seconds(601))?.elapsedMs, 600_000)
    }

    func testPostSendOriginAndOrdinalRemainIndependentAndNeverBorrowAStateOrPhase() throws {
        let session = UUID().uuidString, inference = UUID(), start = ContinuousClock.now
        let native = try XCTUnwrap(WebsiteResponseProfile.begin(source: .nativeTurn, sessionToken: session, sequence: 1, started: start))
        let server = try XCTUnwrap(WebsiteResponseProfile.begin(source: .serverAcknowledged, sessionToken: session,
            sequence: 1, inferenceID: inference, started: start + .seconds(1)))
        let next = try XCTUnwrap(WebsiteResponseProfile.begin(source: .nativeTurn, sessionToken: session, sequence: 2,
            started: start + .seconds(2)))
        XCTAssertNil(native.event(.httpWriteStart)); XCTAssertNil(server.event(.transportComplete))
        let nativeEvent = try XCTUnwrap(native.event(.firstPositive, at: start + .seconds(2)))
        let serverEvent = try XCTUnwrap(server.event(.codecStart, at: start + .seconds(2)))
        XCTAssertEqual(nativeEvent.sessionID, serverEvent.sessionID); XCTAssertEqual(nativeEvent.sequence, serverEvent.sequence)
        XCTAssertEqual(nativeEvent.elapsedMs, 2_000); XCTAssertEqual(serverEvent.elapsedMs, 1_000)
        XCTAssertNil(nativeEvent.inferenceID); XCTAssertEqual(serverEvent.inferenceID, inference)
        XCTAssertEqual(next.event(.firstPositive, at: start + .seconds(2))?.sequence, 2)
        XCTAssertEqual(next.event(.firstPositive, at: start + .seconds(2))?.elapsedMs, 0)
        XCTAssertEqual(native.event(.firstPositive, at: start + .seconds(2)), nativeEvent,
                       "Sampling does not mutate, reset or consume another diagnostic context")
    }
}

@MainActor
final class MatchedBenchmarkProjectionTests: XCTestCase {
    // Insert into existing MatchedBenchmarkProjectionTests; uses its private
    // valid/binding/rejected helpers. Prepared only, not applied or executed.
    func testMatchedBenchmarkProjectionPreservesExplicitSingleTerminalLFWithoutChangingLiteralProof() throws {
        let literal = String(repeating: "x", count: 32)
        let literalHash = EmbeddedWebModelTransport.promptFingerprint(literal)
        let renderedHash = EmbeddedWebModelTransport.promptFingerprint(literal + "\n")
        let exact = WebsiteBenchmarkCaptureLease.ObservationBinding(nonce: nonce,
            rawOutboundSHA: literalHash, canonicalOutboundSHA: literalHash, utf8Bytes: 32)
        var terminal = valid
        for key in ["expectedSHA256", "expectedCanonicalSHA256", "editorSHA256", "editorCanonicalSHA256", "userSHA256"] {
            terminal[key] = literalHash
        }
        terminal["editorRepresentation"] = "single_terminal_newline"
        terminal["editorRenderedUTF8Bytes"] = 33
        terminal["editorRenderedSHA256"] = renderedHash
        let original: [String: Any] = ["state": "complete", "text": "PRIVATE_AUTHORITY_CANARY"]
        var observation = original; observation["benchmarkMilestones"] = terminal
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.removeMatchedBenchmarkMilestones(from: &observation, binding: exact))
        XCTAssertEqual(NSDictionary(dictionary: observation), NSDictionary(dictionary: original))
        XCTAssertEqual(NSDictionary(dictionary: safe), NSDictionary(dictionary: terminal))
        XCTAssertEqual(safe["editorUTF8Bytes"] as? Int, 32)
        XCTAssertEqual(safe["editorRenderedUTF8Bytes"] as? Int, 33)
        XCTAssertEqual(safe["editorSHA256"] as? String, literalHash)
        XCTAssertEqual(safe["editorRenderedSHA256"] as? String, renderedHash)
        XCTAssertNotEqual(literalHash, renderedHash)
        XCTAssertEqual(safe["editorMatchesExpected"] as? Bool, true)
        XCTAssertEqual(safe["userMatchesExpected"] as? Bool, true)
        XCTAssertEqual(safe["payloadMatched"] as? Bool, true)
        let encoded = try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys])
        XCTAssertLessThan(encoded.count, 4_096)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(literal))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE_AUTHORITY_CANARY"))
    }

    func testMatchedBenchmarkProjectionRejectsContradictoryTerminalLFRepresentationsAndCFBooleans() {
        var terminal = valid
        terminal["editorRepresentation"] = "single_terminal_newline"
        terminal["editorRenderedUTF8Bytes"] = 33
        terminal["editorRenderedSHA256"] = String(repeating: "d", count: 64)
        var variants: [(String, [String: Any])] = []
        func add(_ label: String, _ key: String, _ value: Any) {
            var bad = terminal; bad[key] = value; variants.append((label, bad))
        }
        add("wrong_exact_representation", "editorRepresentation", "exact")
        add("unknown_positive_representation", "editorRepresentation", "unknown")
        add("unrecognized_representation", "editorRepresentation", "trimmed")
        add("boolean_representation", "editorRepresentation", true)
        add("CFBoolean_rendered_byte_count", "editorRenderedUTF8Bytes", NSNumber(value: true))
        add("string_rendered_byte_count", "editorRenderedUTF8Bytes", "33")
        add("fractional_rendered_byte_count", "editorRenderedUTF8Bytes", 33.5)
        add("two_extra_LF_bytes", "editorRenderedUTF8Bytes", 34)
        add("no_extra_byte", "editorRenderedUTF8Bytes", 32)
        add("unchanged_hash_with_extra_byte", "editorRenderedSHA256", binding.rawOutboundSHA)
        add("boolean_rendered_hash", "editorRenderedSHA256", NSNumber(value: true))
        add("malformed_rendered_hash", "editorRenderedSHA256", "PRIVATE_HASH_CANARY")
        add("uppercase_rendered_hash", "editorRenderedSHA256", String(repeating: "D", count: 64))
        add("literal_size_was_relaxed", "editorUTF8Bytes", 33)
        add("literal_hash_was_relaxed", "editorSHA256", String(repeating: "d", count: 64))
        add("submitted_canonical_hash_was_relaxed", "userSHA256", String(repeating: "d", count: 64))
        for (_, bad) in variants { rejected(bad) }
    }

    private let nonce = UUID(uuidString: "cccccccc-1111-4222-8333-dddddddddddd")!
    private var binding: WebsiteBenchmarkCaptureLease.ObservationBinding {
        .init(nonce: nonce, rawOutboundSHA: String(repeating: "a", count: 64),
              canonicalOutboundSHA: String(repeating: "b", count: 64), utf8Bytes: 32)
    }
    private var valid: [String: Any] {
        ["schemaVersion": 1, "nonce": nonce.uuidString.lowercased(),
         "expectedSHA256": String(repeating: "a", count: 64), "expectedCanonicalSHA256": String(repeating: "b", count: 64),
         "expectedUTF8Bytes": 32, "invalidReason": "none", "sendClickCount": 1, "userCount": 1, "assistantCount": 1,
         "editorUTF8Bytes": 32, "editorSHA256": String(repeating: "a", count: 64),
         "editorCanonicalSHA256": String(repeating: "b", count: 64), "userUTF8Bytes": 32,
         "editorRenderedUTF8Bytes": 32, "editorRenderedSHA256": String(repeating: "a", count: 64), "editorRepresentation": "exact",
         "userSHA256": String(repeating: "b", count: 64), "responseUTF8Bytes": 30,
         "responseSHA256": String(repeating: "c", count: 64), "editorMatchesExpected": true,
         "userMatchesExpected": true, "payloadMatched": true, "currentComplete": true,
         "installedUnixMs": 1_792_300_000_000, "sendUnixMs": 1_792_300_000_010, "sendSinceInstallMs": 10.0,
         "firstTextAfterSendMs": 20.5, "firstCompleteAfterSendMs": 30.5, "lastTextChangeAfterSendMs": 20.5,
         "completionScope": "assistant_ancestor", "responseKind": "code"]
    }
    private func rejected(_ raw: Any, binding override: WebsiteBenchmarkCaptureLease.ObservationBinding? = nil,
                          file: StaticString = #filePath, line: UInt = #line) {
        let original: [String: Any] = ["submitted": true, "modelEvidence": ["unchanged": "PRIVATE_AUTHORITY_CANARY"], "text": "PRIVATE_ANSWER_CANARY"]
        var observation = original; observation["benchmarkMilestones"] = raw
        XCTAssertNil(EmbeddedWebModelTransport.removeMatchedBenchmarkMilestones(from: &observation, binding: override ?? binding), file: file, line: line)
        XCTAssertEqual(NSDictionary(dictionary: observation), NSDictionary(dictionary: original), file: file, line: line)
    }

    func testMatchedBenchmarkProjectionIsExactBoundedContentFreeAndRemovedBeforeAuthorityChecks() throws {
        let original: [String: Any] = ["submitted": true, "text": "PRIVATE_ANSWER_CANARY"]
        var observation = original; observation["benchmarkMilestones"] = valid
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.removeMatchedBenchmarkMilestones(from: &observation, binding: binding))
        XCTAssertEqual(NSDictionary(dictionary: observation), NSDictionary(dictionary: original))
        XCTAssertEqual(NSDictionary(dictionary: safe), NSDictionary(dictionary: valid))
        let data = try JSONSerialization.data(withJSONObject: safe, options: .sortedKeys)
        XCTAssertLessThan(data.count, 4_096)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_"))
        XCTAssertNil(EmbeddedWebModelTransport.removeMatchedBenchmarkMilestones(from: &observation, binding: binding))
    }

    func testMatchedBenchmarkProjectionRejectsUnknownMissingAndUnarmedValuesWithoutChangingObservation() {
        let primitiveValues: [Any] = [NSNull(), [], "PRIVATE_PAGE_CANARY"]
        for value in primitiveValues { rejected(value) }
        for key in valid.keys { var bad = valid; bad.removeValue(forKey: key); rejected(bad) }
        var unknown = valid; unknown["PRIVATE_PAGE_CANARY"] = "PRIVATE_VALUE_CANARY"; rejected(unknown)
        var observation: [String: Any] = ["state": "running", "benchmarkMilestones": valid]
        XCTAssertNil(EmbeddedWebModelTransport.removeMatchedBenchmarkMilestones(from: &observation, binding: nil))
        XCTAssertEqual(NSDictionary(dictionary: observation), NSDictionary(dictionary: ["state": "running"]))
    }

    func testMatchedBenchmarkProjectionDistinguishesCFBooleansAndRejectsNonfiniteOrUnboundedMetadata() {
        var variants: [[String: Any]] = []
        func add(_ key: String, _ value: Any) { var bad = valid; bad[key] = value; variants.append(bad) }
        for key in ["schemaVersion", "expectedUTF8Bytes", "sendClickCount", "userCount", "assistantCount", "editorUTF8Bytes", "userUTF8Bytes", "responseUTF8Bytes", "installedUnixMs", "sendUnixMs", "sendSinceInstallMs", "firstTextAfterSendMs", "firstCompleteAfterSendMs", "lastTextChangeAfterSendMs"] {
            add(key, true); add(key, "PRIVATE_NUMBER_CANARY")
        }
        for key in ["editorMatchesExpected", "userMatchesExpected", "payloadMatched", "currentComplete"] { add(key, NSNumber(value: 1)) }
        for value in [Double.nan, Double.infinity, -1.0, 600_000.1] { add("firstTextAfterSendMs", value) }
        add("sendClickCount", 1.5); add("userCount", 3); add("responseUTF8Bytes", 220_001)
        add("installedUnixMs", 946_684_799_999); add("sendUnixMs", 4_102_444_800_001)
        add("invalidReason", "PRIVATE_REASON_CANARY"); add("completionScope", "PRIVATE_SCOPE_CANARY"); add("responseKind", "PRIVATE_KIND_CANARY")
        add("editorSHA256", "PRIVATE_HASH_CANARY"); add("userSHA256", String(repeating: "B", count: 64))
        add("payloadMatched", NSNull()); add("currentComplete", NSNull())
        for bad in variants { rejected(bad) }
    }

    func testMatchedBenchmarkProjectionRejectsForeignBindingAndContradictoryPositiveClaims() {
        let foreign = WebsiteBenchmarkCaptureLease.ObservationBinding(nonce: UUID(), rawOutboundSHA: binding.rawOutboundSHA,
            canonicalOutboundSHA: binding.canonicalOutboundSHA, utf8Bytes: binding.utf8Bytes)
        rejected(valid, binding: foreign)
        var variants: [[String: Any]] = []
        func add(_ key: String, _ value: Any) { var bad = valid; bad[key] = value; variants.append(bad) }
        add("nonce", nonce.uuidString); add("expectedSHA256", String(repeating: "d", count: 64))
        add("expectedCanonicalSHA256", String(repeating: "d", count: 64)); add("expectedUTF8Bytes", 33)
        add("editorSHA256", String(repeating: "d", count: 64)); add("editorUTF8Bytes", 31)
        add("userSHA256", String(repeating: "d", count: 64)); add("userMatchesExpected", false)
        add("editorMatchesExpected", false); add("userCount", 0); add("assistantCount", 0); add("sendClickCount", 0)
        add("invalidReason", "user_root_changed")
        for bad in variants { rejected(bad) }
    }
}

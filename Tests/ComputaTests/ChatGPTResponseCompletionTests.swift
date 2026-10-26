import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class ChatGPTResponseCompletionTests: XCTestCase {
    func testOwnedTerminalFailureIsFiniteBoundAndCannotBecomeAResponse() throws {
        for reason in ["empty_stream", "provider_error"] {
            let fixture = try LeaseFixture()
            let packet = fixture.failurePacket(reason: reason)
            XCTAssertTrue(fixture.lease.receive(packet))
            let failure = try XCTUnwrap(fixture.failureReceipt())
            XCTAssertEqual(failure.reason.rawValue, reason)
            XCTAssertNil(fixture.receipt())
            XCTAssertFalse(fixture.lease.receive(packet))
            XCTAssertEqual(fixture.failureReceipt(), failure)
            XCTAssertNil(fixture.lease.failureReceipt(view: ObjectIdentifier(NSObject()), ownerToken: fixture.owner,
                generation: fixture.generation, sequence: fixture.sequence))
            XCTAssertNil(fixture.lease.failureReceipt(view: fixture.viewID, ownerToken: UUID().uuidString,
                generation: fixture.generation, sequence: fixture.sequence))
            XCTAssertNil(fixture.lease.failureReceipt(view: fixture.viewID, ownerToken: fixture.owner,
                generation: UUID(), sequence: fixture.sequence))
            XCTAssertNil(fixture.lease.failureReceipt(view: fixture.viewID, ownerToken: fixture.owner,
                generation: fixture.generation, sequence: fixture.sequence + 1))
            XCTAssertNil(fixture.failureReceipt(now: fixture.deadline))
            XCTAssertTrue(fixture.lease.receive(fixture.packet()), "Conflicting output invalidates rather than converting a failed stream")
            XCTAssertNil(fixture.failureReceipt()); XCTAssertNil(fixture.receipt())
        }
    }

    func testTerminalFailureRejectsMissingProofMalformedCountsForeignIdentityAndChangedDuplicates() throws {
        for mutation: (inout [String: Any]) -> Void in [
            { $0["reason"] = "arbitrary website message" }, { $0["calls"] = true }, { $0["calls"] = 2 },
            { $0["calls"] = 257 }, { $0["assistantMessages"] = 1 }, { $0["messageTerminalCount"] = 0 },
            { $0["messageTerminalCount"] = true }, { $0["mainTerminalCount"] = 0 },
            { $0["text"] = "not accepted" }, { $0["conversationID"] = "not a conversation" },
        ] {
            let fixture = try LeaseFixture(); var packet = fixture.failurePacket()
            mutation(&packet); XCTAssertTrue(fixture.lease.receive(packet))
            XCTAssertTrue(fixture.lease.invalidated); XCTAssertNil(fixture.failureReceipt())
        }
        let fixture = try LeaseFixture()
        var foreign = fixture.failurePacket(); foreign["inputSHA256"] = String(repeating: "b", count: 64)
        XCTAssertFalse(fixture.lease.receive(foreign)); XCTAssertFalse(fixture.lease.invalidated)
        XCTAssertTrue(fixture.lease.receive(fixture.failurePacket()))
        var changed = fixture.failurePacket(); changed["calls"] = 4
        XCTAssertTrue(fixture.lease.receive(changed)); XCTAssertNil(fixture.failureReceipt())
    }

    func testProviderErrorNeedsBothTerminalProofsAndCannotCarryOpaqueContent() throws {
        for mutation: (inout [String: Any]) -> Void in [
            { $0["mainTerminalCount"] = 0 }, { $0["messageTerminalCount"] = 0 },
            { $0["calls"] = 3 }, { $0["assistantMessages"] = 1 },
            { $0["message"] = ["content": "not a terminal-only receipt"] },
        ] {
            let fixture = try LeaseFixture(); var packet = fixture.failurePacket(reason: "provider_error")
            mutation(&packet); XCTAssertTrue(fixture.lease.receive(packet))
            XCTAssertTrue(fixture.lease.invalidated); XCTAssertNil(fixture.failureReceipt())
        }
    }

    func testFailureObservationCannotSurviveCancellationRevocationOrOverwriteSuccessfulCandidate() async throws {
        let fixture = try LeaseFixture(); XCTAssertTrue(fixture.lease.receive(fixture.failurePacket()))
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertNil(fixture.failureReceipt())
            XCTAssertFalse(fixture.lease.receive(fixture.failurePacket()))
        }
        await cancelled.value
        fixture.lease.revoke(); XCTAssertNil(fixture.failureReceipt())
        let success = try LeaseFixture(); XCTAssertTrue(success.lease.receive(success.packet()))
        XCTAssertTrue(success.lease.receive(success.failurePacket()))
        XCTAssertNil(success.receipt()); XCTAssertNil(success.failureReceipt())
    }

    func testNativeBindingBoundsAndCurrentLookupCannotCrossViewsOwnersGenerationsOrRounds() throws {
        let fixture = try LeaseFixture()
        XCTAssertTrue(fixture.lease.isCurrent(view: fixture.viewID, ownerToken: fixture.owner,
                                             generation: fixture.generation, sequence: fixture.sequence))
        XCTAssertNil(fixture.receipt())
        XCTAssertTrue(fixture.lease.receive(fixture.packet()))
        let receipt = try XCTUnwrap(fixture.receipt())
        XCTAssertNil(fixture.lease.receipt(view: ObjectIdentifier(NSObject()), ownerToken: fixture.owner,
                                           generation: fixture.generation, sequence: fixture.sequence))
        XCTAssertNil(fixture.lease.receipt(view: fixture.viewID, ownerToken: UUID().uuidString,
                                           generation: fixture.generation, sequence: fixture.sequence))
        XCTAssertNil(fixture.lease.receipt(view: fixture.viewID, ownerToken: fixture.owner,
                                           generation: UUID(), sequence: fixture.sequence))
        XCTAssertNil(fixture.lease.receipt(view: fixture.viewID, ownerToken: fixture.owner,
                                           generation: fixture.generation, sequence: fixture.sequence + 1))
        XCTAssertEqual(fixture.receipt(), receipt, "A foreign lookup cannot consume or alter the current receipt")
        let cases: [(owner: String, sequence: Int, sha: String, bytes: Int)] = [
            ("not-a-native-owner", 1, fixture.sha, 10),
            (fixture.owner, 0, fixture.sha, 10), (fixture.owner, 17, fixture.sha, 10),
            (fixture.owner, 1, String(repeating: "A", count: 64), 10),
            (fixture.owner, 1, String(repeating: "a", count: 63), 10),
            (fixture.owner, 1, fixture.sha, 0), (fixture.owner, 1, fixture.sha, 180_001),
        ]
        for item in cases {
            XCTAssertNil(ChatGPTResponseCompletion(view: fixture.viewID, ownerToken: item.owner,
                generation: fixture.generation, sequence: item.sequence, inputSHA256: item.sha,
                inputUTF8Bytes: item.bytes, deadline: .now + .seconds(10)))
        }
    }

    func testOneValidTerminalHasExactNativeDigestAndDuplicateDoesNotRenewItsIdentity() throws {
        let fixture = try LeaseFixture()
        let packet = fixture.packet(text: "Exact café 🌍\nsecond line")
        XCTAssertTrue(fixture.lease.receive(packet))
        let first = try XCTUnwrap(fixture.receipt())
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.correlationID, fixture.correlation)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.inputSHA256, fixture.sha)
        XCTAssertEqual(first.inputMessageID, fixture.inputMessage.uuidString.lowercased())
        XCTAssertEqual(first.conversationID, fixture.conversation.uuidString.lowercased())
        XCTAssertEqual(first.assistantMessageID, fixture.answer.uuidString.lowercased())
        XCTAssertEqual(first.text, "Exact café 🌍\nsecond line")
        XCTAssertEqual(first.textSHA256, EmbeddedWebModelTransport.promptFingerprint(first.text))
        XCTAssertFalse(fixture.lease.receive(packet), "An identical duplicate is not another native wake or new terminal")
        XCTAssertEqual(fixture.receipt(), first)
        XCTAssertEqual(fixture.lease.revision, 1)
        XCTAssertFalse(fixture.lease.invalidated)
    }

    func testForeignCorrelationSequenceAndInputHashCannotPoisonOrReplaceCurrentTerminal() throws {
        let fixture = try LeaseFixture()
        XCTAssertTrue(fixture.lease.receive(fixture.packet()))
        let original = try XCTUnwrap(fixture.receipt())
        let identities: [(String, Any)] = [
            ("correlationID", UUID().uuidString.lowercased()),
            ("correlationID", fixture.correlation.uuidString.uppercased()),
            ("sequence", 2), ("sequence", true),
            ("inputSHA256", String(repeating: "b", count: 64)),
        ]
        for (key, value) in identities {
            var packet = fixture.packet(text: "Foreign content must never replace the owned receipt")
            packet[key] = value
            packet["kind"] = "invalidated"
            XCTAssertFalse(fixture.lease.receive(packet), key)
            XCTAssertFalse(fixture.lease.invalidated, key)
            XCTAssertEqual(fixture.receipt(), original, key)
        }
    }

    func testMalformedMatchingPacketsInvalidatePermanentlyInsteadOfFallingThroughToLaterTerminal() throws {
        let mutations: [(String, (inout [String: Any], LeaseFixture) -> Void)] = [
            ("boolean_version", { packet, _ in packet["version"] = true }),
            ("unknown_version", { packet, _ in packet["version"] = 2 }),
            ("fractional_version", { packet, _ in packet["version"] = 1.5 }),
            ("unknown_kind", { packet, _ in packet["kind"] = "finished_successfully" }),
            ("unknown_key", { packet, _ in packet["unexpected"] = "not retained" }),
            ("missing_message", { packet, _ in packet.removeValue(forKey: "messageID") }),
            ("uppercase_message", { $0["messageID"] = $1.answer.uuidString.uppercased() }),
            ("invalid_conversation", { packet, _ in packet["conversationID"] = "not-a-conversation" }),
            ("same_input_answer", { $0["messageID"] = $1.inputMessage.uuidString.lowercased() }),
            ("nontext", { packet, _ in packet["text"] = ["HI"] }),
            ("empty_text", { packet, _ in packet["text"] = "" }),
            ("extra_on_invalidation", { packet, _ in packet["kind"] = "invalidated" }),
        ]
        for (name, mutation) in mutations {
            let fixture = try LeaseFixture()
            var packet = fixture.packet()
            mutation(&packet, fixture)
            XCTAssertTrue(fixture.lease.receive(packet), name)
            XCTAssertTrue(fixture.lease.invalidated, name)
            XCTAssertNil(fixture.receipt(), name)
            XCTAssertFalse(fixture.lease.receive(fixture.packet()), name)
            XCTAssertNil(fixture.receipt(), "A later valid terminal cannot resurrect \(name)")
        }
    }

    func testConflictingTerminalIdentityOrExactUTF8RevokesAnAlreadyPublishedCandidate() throws {
        let conflicts: [(String, (inout [String: Any], LeaseFixture) -> Void)] = [
            ("message", { packet, _ in packet["messageID"] = UUID().uuidString.lowercased() }),
            ("input_message", { packet, _ in packet["inputMessageID"] = UUID().uuidString.lowercased() }),
            ("conversation", { packet, _ in packet["conversationID"] = UUID().uuidString.lowercased() }),
            ("text", { packet, _ in packet["text"] = "Changed final content" }),
            ("canonical_equivalent_utf8", { packet, _ in packet["text"] = "e\u{301}" }),
        ]
        for (name, mutation) in conflicts {
            let fixture = try LeaseFixture()
            var packet = fixture.packet(text: "é")
            XCTAssertTrue(fixture.lease.receive(packet))
            let first = try XCTUnwrap(fixture.receipt())
            mutation(&packet, fixture)
            XCTAssertTrue(fixture.lease.receive(packet), name)
            XCTAssertTrue(fixture.lease.invalidated, name)
            XCTAssertGreaterThan(fixture.lease.revision, first.revision, name)
            XCTAssertNil(fixture.receipt(), name)
        }
        XCTAssertEqual("é", "e\u{301}", "The UTF8 conflict must remain stricter than Swift canonical String equality")
    }

    func testExplicitInvalidationAndRevocationAreFinalAndClearTheCandidate() throws {
        for revokeDirectly in [false, true] {
            let fixture = try LeaseFixture()
            XCTAssertTrue(fixture.lease.receive(fixture.packet()))
            let original = try XCTUnwrap(fixture.receipt())
            if revokeDirectly { fixture.lease.revoke() }
            else {
                var invalidated = fixture.identity()
                invalidated["kind"] = "invalidated"
                XCTAssertTrue(fixture.lease.receive(invalidated))
            }
            XCTAssertTrue(fixture.lease.invalidated)
            XCTAssertNil(fixture.receipt())
            XCTAssertFalse(fixture.lease.receive(fixture.packet()))
            let finalRevision = fixture.lease.revision
            XCTAssertGreaterThan(finalRevision, original.revision)
            fixture.lease.revoke()
            XCTAssertEqual(fixture.lease.revision, finalRevision, "Repeated revocation cannot renew state or a deadline")
        }
    }

    func testDeadlineAndCancellationDoNotYieldOrAcceptAReceipt() async throws {
        let fixture = try LeaseFixture()
        XCTAssertTrue(fixture.lease.receive(fixture.packet()))
        XCTAssertNil(fixture.receipt(now: fixture.deadline))
        XCTAssertFalse(fixture.lease.receive(fixture.packet(), now: fixture.deadline))
        XCTAssertNil(ChatGPTResponseCompletion(view: fixture.viewID, ownerToken: fixture.owner,
            generation: fixture.generation, sequence: 1, inputSHA256: fixture.sha,
            inputUTF8Bytes: 10, deadline: .now - .milliseconds(1)))
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertNil(fixture.receipt())
            XCTAssertFalse(fixture.lease.receive(fixture.packet()))
            XCTAssertNil(ChatGPTResponseCompletion(view: fixture.viewID, ownerToken: fixture.owner,
                generation: fixture.generation, sequence: 1, inputSHA256: fixture.sha,
                inputUTF8Bytes: 10, deadline: .now + .seconds(10)))
        }
        await cancelled.value
    }

    func testTextBudgetCountsUTF8AndOverBudgetCannotLeaveAStaleCandidate() throws {
        let maximum = ChatGPTResponseCompletion.maximumTextUTF8Bytes
        let valid = try LeaseFixture()
        XCTAssertTrue(valid.lease.receive(valid.packet(text: String(repeating: "x", count: maximum))))
        XCTAssertEqual(try XCTUnwrap(valid.receipt()).text.utf8.count, maximum)
        for text in [String(repeating: "x", count: maximum + 1),
                     String(repeating: "é", count: maximum / 2 + 1)] {
            let fixture = try LeaseFixture()
            XCTAssertTrue(fixture.lease.receive(fixture.packet(text: "Prior terminal")))
            XCTAssertTrue(fixture.lease.receive(fixture.packet(text: text)))
            XCTAssertTrue(fixture.lease.invalidated)
            XCTAssertNil(fixture.receipt())
        }
    }

    func testEveryClosedDiagnosticReasonIsReadOnlyBeforeAndAfterTerminalExpiryAndRevocation() throws {
        let fixture = try LeaseFixture()
        let deadline = fixture.lease.deadline
        for reason in ChatGPTResponseCompletion.DiagnosticReason.allCases {
            let packet = fixture.diagnosticPacket(reason: reason.rawValue)
            let diagnostic = try XCTUnwrap(fixture.lease.diagnostic(packet))
            XCTAssertEqual(diagnostic.reason, reason)
            XCTAssertEqual(diagnostic.correlationID, fixture.correlation)
            XCTAssertEqual(diagnostic.sequence, fixture.sequence)
            XCTAssertEqual(diagnostic.inputSHA256, fixture.sha)
            XCTAssertEqual(diagnostic.calls, 257)
            XCTAssertEqual(diagnostic.instances, 4)
            XCTAssertEqual(fixture.lease.revision, 0)
            XCTAssertFalse(fixture.lease.invalidated)
            XCTAssertNil(fixture.receipt(), "Diagnostic parsing cannot grant a receipt")
        }
        XCTAssertTrue(fixture.lease.receive(fixture.packet()))
        let terminal = try XCTUnwrap(fixture.receipt())
        let packet = fixture.diagnosticPacket(reason: "input_hash")
        XCTAssertNotNil(fixture.lease.diagnostic(packet))
        XCTAssertEqual(fixture.receipt(), terminal, "An unrelated decoder's rejection cannot revoke the matched receipt")
        XCTAssertEqual(fixture.lease.revision, terminal.revision)
        XCTAssertNil(fixture.receipt(now: deadline))
        XCTAssertNotNil(fixture.lease.diagnostic(packet))
        XCTAssertNil(fixture.receipt(now: deadline), "Reading a diagnostic cannot renew an expired lease")
        XCTAssertEqual(fixture.lease.deadline, deadline)
        fixture.lease.revoke()
        let revokedRevision = fixture.lease.revision
        XCTAssertNotNil(fixture.lease.diagnostic(packet), "A retained exact diagnostic is not positive authority")
        XCTAssertTrue(fixture.lease.invalidated)
        XCTAssertEqual(fixture.lease.revision, revokedRevision)
        XCTAssertNil(fixture.receipt())
    }

    func testDiagnosticRejectsForeignMalformedAndUnboundedRecordsWithoutMutatingAnyAuthority() throws {
        let fixture = try LeaseFixture()
        XCTAssertTrue(fixture.lease.receive(fixture.packet()))
        let original = try XCTUnwrap(fixture.receipt())
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("missing", { $0.removeValue(forKey: "reason") }),
            ("extra", { $0["text"] = "Never log provider text" }),
            ("version_bool", { $0["version"] = true }),
            ("version_fraction", { $0["version"] = 1.5 }),
            ("version_unknown", { $0["version"] = 2 }),
            ("kind", { $0["kind"] = "terminal" }),
            ("correlation", { $0["correlationID"] = UUID().uuidString.lowercased() }),
            ("uppercase_correlation", { $0["correlationID"] = fixture.correlation.uuidString.uppercased() }),
            ("sequence", { $0["sequence"] = 2 }), ("sequence_bool", { $0["sequence"] = true }),
            ("hash", { $0["inputSHA256"] = String(repeating: "b", count: 64) }),
            ("uppercase_hash", { $0["inputSHA256"] = fixture.sha.uppercased() }),
            ("unknown_reason", { $0["reason"] = "arbitrary provider error" }),
            ("reason_type", { $0["reason"] = ["expired"] }),
            ("calls_bool", { $0["calls"] = true }), ("calls_fraction", { $0["calls"] = 1.5 }),
            ("calls_string", { $0["calls"] = "1" }), ("calls_negative", { $0["calls"] = -1 }),
            ("calls_overflow", { $0["calls"] = 258 }),
            ("instances_bool", { $0["instances"] = false }), ("instances_fraction", { $0["instances"] = 0.5 }),
            ("instances_negative", { $0["instances"] = -1 }), ("instances_overflow", { $0["instances"] = 5 }),
        ]
        for (name, mutate) in mutations {
            var packet = fixture.diagnosticPacket(reason: "expired")
            mutate(&packet)
            XCTAssertNil(fixture.lease.diagnostic(packet), name)
            XCTAssertEqual(fixture.receipt(), original, name)
            XCTAssertEqual(fixture.lease.revision, original.revision, name)
            XCTAssertFalse(fixture.lease.invalidated, name)
        }
        XCTAssertNil(fixture.lease.diagnostic("not an object"))
        var zero = fixture.diagnosticPacket(reason: "runtime_unsupported")
        zero["calls"] = 0; zero["instances"] = 0
        XCTAssertNotNil(fixture.lease.diagnostic(zero))
    }

    func testMainWorldDiagnosticDeliveryCannotRevokeWakeOrRenewAnOwnedTerminal() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        // Only the decoder is replaced. The document-start installation, .page
        // handler, native arm, identity checks and channel are the real path.
        browser.setChatGPTResponseCompletionSourceForTesting("""
            (() => {
              const config = __COMPUTA_COMPLETION_CONFIG__;
              const api = Object.freeze({ arm(binding) {
                window.fixtureCompletionArm = Object.freeze({...binding}); return {armed:true};
              }, stop() {} });
              Object.defineProperty(window, config.key, {value:api});
              window.fixturePostCompletion = packet => {
                window.webkit.messageHandlers[config.handlerName].postMessage(packet); return true;
              };
            })();
            """)
        let tabID = try browser.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(browser.webView(for: tabID))
        let owner = UUID().uuidString
        try browser.installModelChangeSignal(tabID: tabID, ownerToken: owner,
            world: .world(name: "computa-completion-diagnostic-test"))
        view.loadHTMLString("<p id='ready'>Local completion fixture</p>", baseURL: URL(string: "https://chatgpt.com/"))
        let loadDeadline = ContinuousClock.now + .seconds(10)
        var ready = false
        while ContinuousClock.now < loadDeadline {
            if !view.isLoading,
               (try? await completionPage(view, "return !!document.getElementById('ready') && typeof window.fixturePostCompletion === 'function';")) == Data("true".utf8) {
                ready = true; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ready)
        let generation = try XCTUnwrap(browser.documentGeneration(for: tabID))
        let deadline = ContinuousClock.now + .seconds(2)
        let sha = EmbeddedWebModelTransport.promptFingerprint("Local exact outbound")
        let armed = await browser.prepareChatGPTResponseCompletion(tabID: tabID, view: view, ownerToken: owner,
            generation: generation, sequence: 1, outboundSHA256: sha, outboundUTF8Bytes: 20, deadline: deadline)
        XCTAssertTrue(armed)
        _ = try await completionPage(view, """
            const arm = window.fixtureCompletionArm;
            window.fixtureTerminal = {version:1,kind:'terminal',correlationID:arm.correlationID,
              sequence:arm.sequence,inputSHA256:arm.inputSHA256,
              inputMessageID:'11111111-1111-4111-8111-111111111111',
              conversationID:'22222222-2222-4222-8222-222222222222',
              messageID:'33333333-3333-4333-8333-333333333333',text:'HI'};
            return window.fixturePostCompletion(window.fixtureTerminal);
            """)
        func receipt() -> ChatGPTResponseCompletion.Receipt? {
            browser.chatGPTResponseCompletionReceipt(tabID: tabID, view: view, ownerToken: owner,
                generation: generation, sequence: 1)
        }
        let receiveDeadline = min(deadline, ContinuousClock.now + .seconds(1))
        while receipt() == nil, ContinuousClock.now < receiveDeadline { await Task.yield() }
        let terminal = try XCTUnwrap(receipt())
        let revision = try browser.modelChangeRevision(for: tabID)
        _ = try await completionPage(view, """
            const {version,correlationID,sequence,inputSHA256} = window.fixtureTerminal;
            const diagnostic = {version,kind:'diagnostic',correlationID,sequence,inputSHA256,
              reason:'input_hash',calls:1,instances:1};
            // Matching malformed records must be intercepted before receive().
            for (const packet of [{...diagnostic,reason:'private arbitrary error'},
              {...diagnostic,calls:true}, {...diagnostic,text:'must not enter authority'},
              {...diagnostic,correlationID:'44444444-4444-4444-8444-444444444444'},
              {...diagnostic,sequence:2}, diagnostic, diagnostic]) window.fixturePostCompletion(packet);
            return true;
            """)
        _ = try await completionPage(view, "return window.fixtureCompletionArm.sequence;")
        let after = try await browser.waitForModelChange(tabID: tabID, after: revision, until: .now + .milliseconds(100))
        XCTAssertEqual(after, revision, "Neither malformed, foreign nor repeated valid diagnostics may wake the channel")
        XCTAssertEqual(try browser.modelChangeRevision(for: tabID), revision)
        XCTAssertEqual(receipt(), terminal, "Real WK delivery cannot revoke or replace the owned terminal")
        XCTAssertEqual(browser.documentGeneration(for: tabID), generation)
        try await Task.sleep(until: deadline, clock: .continuous)
        XCTAssertNil(receipt(), "Diagnostics cannot renew the original lease deadline")
        _ = try await completionPage(view, """
            const {version,correlationID,sequence,inputSHA256} = window.fixtureTerminal;
            return window.fixturePostCompletion({version,kind:'diagnostic',correlationID,sequence,inputSHA256,
              reason:'expired',calls:2,instances:1});
            """)
        XCTAssertNil(receipt(), "Even a valid late diagnostic cannot revive an expired receipt")
        XCTAssertEqual(try browser.modelChangeRevision(for: tabID), revision)
    }

    private func completionPage(_ view: WKWebView, _ body: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) }
                    catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private struct LeaseFixture {
        let view = NSObject()
        let owner = UUID().uuidString
        let generation = UUID()
        let correlation = UUID()
        let inputMessage = UUID()
        let conversation = UUID()
        let answer = UUID()
        let sequence = 1
        let sha = EmbeddedWebModelTransport.promptFingerprint("Exact owned outbound payload")
        let deadline = ContinuousClock.now + .seconds(10)
        let lease: ChatGPTResponseCompletion
        var viewID: ObjectIdentifier { ObjectIdentifier(view) }

        init() throws {
            lease = try XCTUnwrap(ChatGPTResponseCompletion(view: ObjectIdentifier(view), ownerToken: owner,
                generation: generation, sequence: sequence, inputSHA256: sha,
                inputUTF8Bytes: "Exact owned outbound payload".utf8.count, deadline: deadline,
                correlationID: correlation))
        }
        func identity() -> [String: Any] {
            ["version": 1, "kind": "terminal", "correlationID": correlation.uuidString.lowercased(),
             "sequence": sequence, "inputSHA256": sha]
        }
        func packet(text: String = "HI") -> [String: Any] {
            identity().merging(["inputMessageID": inputMessage.uuidString.lowercased(),
                "conversationID": conversation.uuidString.lowercased(),
                "messageID": answer.uuidString.lowercased(), "text": text]) { _, right in right }
        }
        func diagnosticPacket(reason: String) -> [String: Any] {
            identity().merging(["kind": "diagnostic", "reason": reason, "calls": 257, "instances": 4]) { _, right in right }
        }
        func failurePacket(reason: String = "empty_stream") -> [String: Any] {
            identity().merging(["kind": "terminal_failure", "inputMessageID": inputMessage.uuidString.lowercased(),
                "conversationID": conversation.uuidString.lowercased(), "reason": reason, "calls": reason == "empty_stream" ? 3 : 4,
                "assistantMessages": 0, "messageTerminalCount": 1, "mainTerminalCount": 1]) { _, right in right }
        }
        func failureReceipt(now: ContinuousClock.Instant = .now) -> ChatGPTResponseCompletion.FailureReceipt? {
            lease.failureReceipt(view: viewID, ownerToken: owner, generation: generation, sequence: sequence, now: now)
        }
        func receipt(now: ContinuousClock.Instant = .now) -> ChatGPTResponseCompletion.Receipt? {
            lease.receipt(view: viewID, ownerToken: owner, generation: generation, sequence: sequence, now: now)
        }
    }
}

import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

/// Synthetic observed DOM, never a claim of live streaming or provider qualification.
@MainActor
final class DeepSeekWebModelTransportTests: XCTestCase {
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")

    func testExactSignInGateRecoversReadOnlyModesThenAllowsFreshAdmissionWithoutSend() async throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let gate = try await seedSignInRecoveryGate(fixture)
            let failedDiscoveryID = try XCTUnwrap(fixture.createdID)
            XCTAssertNil(fixture.browser.webView(for: failedDiscoveryID))
            do { _ = try await start(fixture, mode: mode); XCTFail("Cached sign-in must reject new admission") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
            XCTAssertEqual(fixture.createdID, failedDiscoveryID, "Blocked admission creates no view")
            fixture.navigationOverride = nil
            let modes = try await fixture.transport.discoverModes(provider: "deepseek", retryBlocked: true,
                recoveryCandidateIsCurrent: { fixture.transport.canRecoverSignInGate(gate) })
            XCTAssertEqual(Set(modes.map(\.key)), ["chat", "deepthink"])
            XCTAssertTrue(fixture.transport.didClearSignInRecoveryGate(gate))
            XCTAssertFalse(fixture.transport.isSignInRecoveryGateCurrent(gate))
            try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
            let observed = try await evaluate(fixture.view, "return [deepseekFixture.counters.searchClicks,deepseekFixture.counters.deepThinkClicks];") as? [Int]
            XCTAssertEqual(observed, [0, 0], "Read-only discovery cannot select a mode or Send")
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            let fresh = try await start(fixture, mode: mode)
            XCTAssertNotEqual(fixture.createdID, failedDiscoveryID)
            let cleanup = try await call(fixture, "webProviderCancel", fresh)
            XCTAssertEqual(cleanup["cleanup"] as? String, "not_created")
            try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testSignInRecoveryRejectsMissingForeignOwnerAndFailedDiscoveryWithoutGateClear() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        XCTAssertNil(fixture.transport.signInRecoveryGate(provider: "deepseek"))
        for provider in ["chatgpt", "gemini", "qwen", "deepseek.evil", ""] {
            XCTAssertNil(fixture.transport.signInRecoveryGate(provider: provider))
        }
        let gate = try await seedSignInRecoveryGate(fixture)
        let foreign = try Fixture(); defer { foreign.shutdown() }
        XCTAssertFalse(foreign.transport.isSignInRecoveryGateCurrent(gate))
        XCTAssertFalse(foreign.transport.canRecoverSignInGate(gate))
        XCTAssertFalse(foreign.transport.didClearSignInRecoveryGate(gate))
        do {
            _ = try await fixture.transport.discoverModes(provider: "deepseek", retryBlocked: true,
                recoveryCandidateIsCurrent: { fixture.transport.canRecoverSignInGate(gate) })
            XCTFail("The local sign-in page cannot prove modes or clear its gate")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
        XCTAssertTrue(fixture.transport.isSignInRecoveryGateCurrent(gate))
        XCTAssertTrue(fixture.transport.canRecoverSignInGate(gate))
        XCTAssertFalse(fixture.transport.didClearSignInRecoveryGate(gate))
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        fixture.browser.recordHumanVerificationRequired(provider: "deepseek")
        XCTAssertNil(fixture.transport.signInRecoveryGate(provider: "deepseek"))
        XCTAssertFalse(fixture.transport.isSignInRecoveryGateCurrent(gate))
        XCTAssertFalse(fixture.transport.canRecoverSignInGate(gate))
        XCTAssertFalse(fixture.transport.didClearSignInRecoveryGate(gate))
        let before = fixture.createdID
        do {
            _ = try await fixture.transport.discoverModes(provider: "deepseek", retryBlocked: true,
                recoveryCandidateIsCurrent: { fixture.transport.canRecoverSignInGate(gate) })
            XCTFail("A changed checkpoint must reject before creating a recovery view")
        } catch is CancellationError { }
        XCTAssertEqual(fixture.createdID, before)
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.contains("deepseek"))
    }

    func testNewCheckpointDuringModeDiscoveryPreservesNewerGateAndDisposesReadOnlyView() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let gate = try await seedSignInRecoveryGate(fixture)
        fixture.navigationOverride = nil
        var changed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "discoverModels", !changed else { return }
            changed = true
            fixture.browser.recordHumanVerificationRequired(provider: "deepseek")
        }
        do {
            _ = try await fixture.transport.discoverModes(provider: "deepseek", retryBlocked: true,
                recoveryCandidateIsCurrent: { fixture.transport.canRecoverSignInGate(gate) })
            XCTFail("Mode evidence cannot erase a newer checkpoint")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.deepseek)) }
        XCTAssertTrue(changed)
        XCTAssertFalse(fixture.transport.isSignInRecoveryGateCurrent(gate))
        XCTAssertFalse(fixture.transport.didClearSignInRecoveryGate(gate))
        XCTAssertNil(fixture.transport.signInRecoveryGate(provider: "deepseek"))
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.contains("deepseek"))
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
    }

    func testSignInRecoveryRefusesAnOwnedSessionAndItsUncertainCleanup() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let ownedID = try XCTUnwrap(fixture.createdID), ownedView = fixture.view
        let gate = try await seedSignInRecoveryGate(fixture, requiresQuiescent: false)
        XCTAssertTrue(fixture.transport.isSignInRecoveryGateCurrent(gate))
        XCTAssertFalse(fixture.transport.canRecoverSignInGate(gate))
        ownedView.loadHTMLString("<!doctype html><p>Local retained sign-in fixture</p>",
            baseURL: URL(string: "https://chat.deepseek.com/sign_in"))
        let deadline = ContinuousClock.now + .seconds(3)
        while ownedView.isLoading || ownedView.url?.absoluteString != "https://chat.deepseek.com/sign_in" {
            guard ContinuousClock.now < deadline else { throw FixtureFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cleanup = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(cleanup["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === ownedView)
        XCTAssertFalse(fixture.transport.canRecoverSignInGate(gate), "Uncertain retained cleanup remains a barrier")
        let before = fixture.createdID
        fixture.navigationOverride = nil
        do {
            _ = try await fixture.transport.discoverModes(provider: "deepseek", retryBlocked: true,
                recoveryCandidateIsCurrent: { fixture.transport.canRecoverSignInGate(gate) })
            XCTFail("Recovery cannot borrow authority from a retained owned session")
        } catch is CancellationError { }
        XCTAssertEqual(fixture.createdID, before)
        XCTAssertTrue(fixture.transport.isSignInRecoveryGateCurrent(gate))
        XCTAssertFalse(fixture.transport.didClearSignInRecoveryGate(gate))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    private func seedSignInRecoveryGate(_ fixture: Fixture, requiresQuiescent: Bool = true) async throws -> EmbeddedWebModelTransport.SignInRecoveryGate {
        fixture.navigationOverride = URL(string: "https://chat.deepseek.com/sign_in")!
        do {
            _ = try await fixture.transport.discoverModes(provider: "deepseek", retryBlocked: true)
            XCTFail("The actual local auth route must establish the native sign-in gate")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
        let gate = try XCTUnwrap(fixture.transport.signInRecoveryGate(provider: "deepseek"))
        XCTAssertTrue(fixture.transport.isSignInRecoveryGateCurrent(gate))
        XCTAssertEqual(fixture.transport.canRecoverSignInGate(gate), requiresQuiescent)
        XCTAssertFalse(fixture.transport.didClearSignInRecoveryGate(gate))
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        return gate
    }

    func testCanonicalDeepSeekSignInIsAnAbortOnlyRoute() throws {
        let provider = EmbeddedWebModelTransport.Provider.deepseek
        let url = try XCTUnwrap(URL(string: "https://chat.deepseek.com/sign_in"))
        let failure = try XCTUnwrap(provider.blockingFailure(for: url))
        XCTAssertEqual(failure, .signInRequired)
        XCTAssertEqual(failure.requiredAction, "sign_in")
        XCTAssertFalse(provider.accepts(url.absoluteString))
        XCTAssertFalse(provider.acceptsUnboundStart(url))
        XCTAssertFalse(provider.acceptsUntouchedSignIn(url))
        XCTAssertNil(provider.savedConversationRoute(url))
        XCTAssertNil(EmbeddedWebModelTransport.Provider.qwen.blockingFailure(for: url))
        for raw in ["http://chat.deepseek.com/sign_in", "https://chat.deepseek.com.evil.test/sign_in",
                    "https://user@chat.deepseek.com/sign_in", "https://chat.deepseek.com:8443/sign_in",
                    "https://chat.deepseek.com/sign_in/next", "https://chat.deepseek.com/sign_in?next=/",
                    "https://chat.deepseek.com/sign_in#other", "https://chat.deepseek.com/%73ign_in",
                    "https://chat.deepseek.com/a/chat/s/sign_in"] {
            XCTAssertNil(provider.blockingFailure(for: URL(string: raw)), raw)
        }
    }

    func testServerReleasesBothModeStreamsWithHonestProofAndDurableOwnedDeletion() async throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let choice = WebsiteModeChoice(deepSeekMode: mode)
            try await assertSavedProviderServerStream(transport: fixture.transport, provider: .deepseek,
                modelID: choice.requestID, selection: .mode(choice), expectedText: "Synthetic DeepSeek native reply")
            let counts = try await evaluate(fixture.view, "return [deepseekFixture.counters.searchClicks, deepseekFixture.counters.deepThinkClicks];") as? [Int]
            XCTAssertEqual(counts, [1, mode == .chat ? 0 : 1])
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testCompleteComposerRemountWithholdsAuthorityUntilExactFirstBodyInBothModes() async throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let fixture = try Fixture(setup: """
                deepseekFixture.options.delayUser = true;
                document.querySelector('.ds-button--circle').addEventListener('click', deepseekFixture.remountComposer);
                """)
            defer { fixture.shutdown() }
            let token = try await start(fixture, mode: mode)
            let prompt = String(repeating: "Exact synthetic remount café 👋 <tag>\n", count: 1_600)
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            for _ in 0..<2 {
                let pending = try await call(fixture, "webProviderPoll", token)
                XCTAssertEqual(pending["state"] as? String, "running")
                XCTAssertEqual(pending["modelVerificationPending"] as? Bool, true)
                XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, "deepseek_initial_composer_remount_v1")
                XCTAssertEqual(pending["text"] as? String, "")
                XCTAssertNil(pending["modeEvidence"]); XCTAssertNil(pending["modelEvidence"])
                XCTAssertNil(pending["modelProofContext"]); XCTAssertNil(pending["completionEvidence"])
                let context = try XCTUnwrap(pending["pendingSubmissionContext"] as? [String: Any])
                XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
                XCTAssertEqual(context["responseCount"] as? Int, 0)
            }
            let revision = try await fixture.transport.changeRevision(sessionToken: token)
            _ = try await evaluate(fixture.view, "deepseekFixture.appendUser(); return true;")
            let changed = try await fixture.transport.waitForChange(sessionToken: token,
                after: try XCTUnwrap(revision), until: .now + .seconds(2))
            XCTAssertNotNil(changed, "Existing DOM events must wake the held first-body observation")
            let complete = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic DeepSeek native reply"}"#)
            let choice = WebsiteModeChoice(deepSeekMode: mode)
            XCTAssertEqual(try WebsiteModeEvidence.parse(complete["modeEvidence"], provider: "deepseek", expected: choice).selected, choice)
            XCTAssertNil(complete["modelVerificationPending"])
            let exact = try await evaluate(fixture.view,
                "return fixturePrompts.length===1 && fixturePrompts[0]===document.querySelector('.ds-collapsible-text').textContent;") as? Bool
            XCTAssertEqual(exact, true)
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            let actions = try await evaluate(fixture.view,
                "return [deepseekFixture.counters.inputs,deepseekFixture.counters.searchClicks,deepseekFixture.counters.deepThinkClicks,deepseekFixture.counters.earlySends];") as? [Int]
            XCTAssertEqual(actions, [1,1,mode == .chat ? 0 : 1,0])
        }
    }

    func testExistingFirstCanonicalRouteRefreshRetainsOnlyInitialRemountObservationPermission() async throws {
        let fixture = try Fixture(setup: "deepseekFixture.options.delayUser=true; deepseekFixture.options.canonicalDelayMs=60000")
        defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic exact first canonical route transition")
        var crossed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !crossed {
                crossed = true
                _ = try? await self.evaluate(fixture.view,
                    "deepseekFixture.canonicalize(); deepseekFixture.remountComposer(); return true;")
            }
        }
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertTrue(crossed)
        XCTAssertEqual(pending["modelVerificationPending"] as? Bool, true)
        XCTAssertNil(pending["modeEvidence"]); XCTAssertEqual(pending["text"] as? String, "")
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        _ = try await evaluate(fixture.view, "deepseekFixture.appendUser(); return true;")
        _ = try await wait(fixture, token, state: "complete")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testServerAcceptsOnlyRestoredModeAfterHeldComposerRemountAndDurableDeletion() async throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let fixture = try Fixture(setup: """
                deepseekFixture.options.delayUser = true;
                document.querySelector('.ds-button--circle').addEventListener('click', deepseekFixture.remountComposer);
                """)
            defer { fixture.shutdown() }
            var pendingReads = 0
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect",
                   (try? await self.evaluate(fixture.view,
                       "return !!globalThis.__computaDeepSeekSavedSessionV1?.modeHandoff && !globalThis.__computaDeepSeekSavedSessionV1?.first;",
                       world: self.world)) as? Bool == true {
                    pendingReads += 1
                    if pendingReads == 1 {
                        _ = try? await self.evaluate(fixture.view, "setTimeout(()=>deepseekFixture.appendUser(),100); return true;")
                    }
                }
            }
            let choice = WebsiteModeChoice(deepSeekMode: mode)
            try await assertSavedProviderServerStream(transport: fixture.transport, provider: .deepseek,
                modelID: choice.requestID, selection: .mode(choice), expectedText: "Synthetic DeepSeek native reply")
            XCTAssertGreaterThanOrEqual(pendingReads, 1)
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        }
    }

    func testPendingRemountCannotRenewDeadlineOrRepairChangedMode() async throws {
        for failureKind in ["deadline", "search", "second-remount", "wrong-body"] {
            let fixture = try Fixture(setup: """
                deepseekFixture.options.delayUser = true;
                document.querySelector('.ds-button--circle').addEventListener('click', deepseekFixture.remountComposer);
                """)
            defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic bounded pending body")
            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["modelVerificationPending"] as? Bool, true)
            switch failureKind {
            case "deadline": fixture.transport.setTimeoutsForTesting(preparation: .seconds(10), response: .milliseconds(1))
            case "search": _ = try await evaluate(fixture.view, "deepseekFixture.setMode(false,true); return true;")
            case "second-remount": _ = try await evaluate(fixture.view, "deepseekFixture.remountComposer(); return true;")
            default: _ = try await evaluate(fixture.view,
                "deepseekFixture.appendUser(); document.querySelector('.ds-collapsible-text span').textContent += ' altered'; return true;")
            }
            do {
                _ = try await call(fixture, "webProviderPoll", token)
                XCTFail("A pending remount must not survive \(failureKind)")
            } catch let failure as EmbeddedWebModelTransport.Failure {
                if failureKind == "deadline" { XCTAssertEqual(failure, .deadline) }
                else if failureKind == "wrong-body" { XCTAssertEqual(failure, .ownershipFailure(.javaScriptFirstUser)) }
                else { XCTAssertEqual(failure, .modelUnverified) }
            }
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
            let actions = try await evaluate(fixture.view,
                "return [deepseekFixture.counters.inputs,deepseekFixture.counters.searchClicks,deepseekFixture.counters.deepThinkClicks,deepseekFixture.counters.earlySends];") as? [Int]
            XCTAssertEqual(actions, [1,1,0,0])
        }
    }

    func testObservedJSONFenceInRealWebKitPreservesBothModesOwnershipAndDeletion() async throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let fixture = try Fixture(setup: DeepSeekFencedResponseFixture.setup()); defer { fixture.shutdown() }
            let token = try await start(fixture, mode: mode)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Read the synthetic observed JSON fence")
            let complete = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(complete["text"] as? String, DeepSeekFencedResponseFixture.observedReply)
            let expected = WebsiteModeChoice(deepSeekMode: mode)
            XCTAssertEqual(try WebsiteModeEvidence.parse(complete["modeEvidence"], provider: "deepseek", expected: expected).selected, expected)
            let raw = try XCTUnwrap(complete["text"] as? String)
            let request = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: ["model": expected.requestID, "input": "Synthetic fence test"]))
            XCTAssertEqual(try WebModelResponseCodec.parseEmbeddedReply(raw, request: request), .message("FORMAT399-DEEPSEEK-A"))
            let tags = try await evaluate(fixture.view, "return [...document.querySelector('.md-code-block').children].map(n=>n.tagName);") as? [String]
            XCTAssertEqual(tags, ["DIV", "PRE", "svg", "svg"])
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        }
    }

    func testWholeFencedToolJSONPreservesEscapesWhitespaceAndParserRejection() async throws {
        let command = "printf \"quoted\"\nnext\tline <tag> & café"
        let valid = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "tool_calls", "calls": [["name": "exec_command", "arguments": ["cmd": command]]]], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        let variants = [valid, valid + "\nPRIVATE_PROSE", #"{"type":"message","text":"unterminated}"#]
        for (index, payload) in variants.enumerated() {
            let whitespace = " \t\n", expectedText = whitespace + payload + whitespace
            let fixture = try Fixture(setup: DeepSeekFencedResponseFixture.setup(DeepSeekFencedResponseFixture.literal(payload, whitespace: whitespace)))
            defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Read the synthetic literal fence")
            let complete = try await wait(fixture, token, state: "complete")
            let actual = try XCTUnwrap(complete["text"] as? String)
            XCTAssertEqual(actual, expectedText)
            let request = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: [
                "model": WebsiteModeChoice(deepSeekMode: .chat).requestID, "input": "Synthetic tool JSON",
                "tools": [[
                    "type": "function", "name": "exec_command",
                    "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]
                ]]
            ] as [String: Any]))
            if index == 0 {
                guard case let .toolCalls(calls) = try WebModelResponseCodec.parseEmbeddedReply(actual, request: request) else { return XCTFail("Expected exact tool calls") }
                XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0].name, "exec_command")
                let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[0].argumentsJSON.utf8)) as? [String: Any])
                XCTAssertEqual(arguments["cmd"] as? String, command)
            } else { XCTAssertThrowsError(try WebModelResponseCodec.parseEmbeddedReply(actual, request: request)) }
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        }
    }

    func testFencedSourceExtraProseUnknownSyntaxHiddenAndInteractiveRootsCannotReleaseAnswer() async throws {
        let base = DeepSeekFencedResponseFixture.observedBlock
        let variants = [base + "<p>PRIVATE_PROSE</p>", base + base,
            base.replacingOccurrences(of: ">json</span>", with: ">javascript</span>"),
            base.replacingOccurrences(of: "token punctuation", with: "token keyword"),
            base.replacingOccurrences(of: "<pre>", with: "<pre hidden>"),
            base.replacingOccurrences(of: "<pre>", with: "<pre contenteditable=\"true\">"),
            base.replacingOccurrences(of: "<pre>", with: "<pre role=\"button\">"),
            base.replacingOccurrences(of: "<pre>", with: "<pre tabindex=\"0\">"),
            base.replacingOccurrences(of: "<pre><span>", with: "<pre><span role=\"button\">"),
            base.replacingOccurrences(of: "md-code-block md-code-block-light\"", with: "md-code-block md-code-block-light\" contenteditable=\"true\"")]
        for (index, markup) in variants.enumerated() {
            let fixture = try Fixture(setup: DeepSeekFencedResponseFixture.setup(markup)); defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Read only the synthetic unsupported fence")
            do { _ = try await wait(fixture, token, state: "complete"); XCTFail("Unsupported fence must not release response: \(index)") }
            catch let failure as EmbeddedWebModelTransport.Failure { XCTAssertEqual(failure, .responseFormatUnavailable, "\(index)") }
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        }
    }

    func testReadOnlyModeDiscoveryDoesNotChangeSearchOrDeepThink() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let modes = try await fixture.transport.discoverModes(provider: "deepseek")
        XCTAssertEqual(Set(modes.map(\.key)), ["chat", "deepthink"])
        let state = try await evaluate(fixture.view, "return deepseekFixture.snapshot();") as? [String: Any]
        XCTAssertEqual(state?["mode"] as? String, "chat"); XCTAssertEqual(state?["search"] as? Bool, true)
        let counters = state?["counters"] as? [String: Any]
        XCTAssertEqual(counters?["deepThinkClicks"] as? Int, 0); XCTAssertEqual(counters?["searchClicks"] as? Int, 0)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testBothModesUseExactOneTextareaSubmissionAndHonestProofBeforeOneVerifiedDeletion() async throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let token = try await start(fixture, mode: mode)
            let requestBytes = try JSONSerialization.data(withJSONObject: [
                "model": WebsiteModeChoice(deepSeekMode: mode).requestID,
                "instructions": ComputaAgentInstructions.developerInstructions(embeddedBrowserTools: true),
                "input": "Read only the synthetic fixture.",
                "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object",
                    "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]]]
            ] as [String: Any])
            let request = try WebModelResponseCodec.prepareRequest(requestBytes)
            let prompt = request.prompt + "\nSynthetic exact DeepSeek café 👋\nLiteral \"quote\" <tag> &amp; e\u{301}"
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            let complete = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic DeepSeek native reply"}"#)
            XCTAssertNil(complete["modelEvidence"])
            let expected = WebsiteModeChoice(deepSeekMode: mode)
            XCTAssertEqual(try WebsiteModeEvidence.parse(complete["modeEvidence"], provider: "deepseek", expected: expected).selected, expected)
            let prompts = try await evaluate(fixture.view, "return fixturePrompts;") as? [String]
            let sent = try XCTUnwrap(prompts?.first)
            XCTAssertEqual(prompts?.count, 1)
            XCTAssertTrue(sent.hasPrefix(prompt + "\n\nComputa session marker: "))
            let echo = try await evaluate(fixture.view, "return document.querySelector('.ds-collapsible-text').textContent;") as? String
            XCTAssertEqual(echo, sent)
            let toggles = try await evaluate(fixture.view, "return [deepseekFixture.counters.searchClicks, deepseekFixture.counters.deepThinkClicks, deepseekFixture.counters.earlySends];") as? [Int]
            XCTAssertEqual(toggles, [1, mode == .chat ? 0 : 1, 0])
            let finished = try await call(fixture, "webProviderFinish", token)
            let repeated = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            XCTAssertEqual(repeated["cleanup"] as? String, "deleted")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testLongPromptWithEmptyDecorationPreservesBothModeProofsAndVerifiedDeletion() async throws {
        for mode in WebsiteModeChoice.DeepSeekMode.allCases {
            let fixture = try Fixture(setup: "deepseekFixture.options.firstUserSiblingKind='empty'")
            defer { fixture.shutdown() }
            let token = try await start(fixture, mode: mode)
            let prompt = String(repeating: "Synthetic complete prompt café 👋 <tag> \n", count: 1_700)
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            let complete = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic DeepSeek native reply"}"#)
            let choice = WebsiteModeChoice(deepSeekMode: mode)
            XCTAssertEqual(try WebsiteModeEvidence.parse(complete["modeEvidence"], provider: "deepseek", expected: choice).selected, choice)
            XCTAssertNil(complete["modelEvidence"])
            let observed = try await evaluate(fixture.view, """
                const container = document.querySelector('.ds-collapsible-text');
                return { sent: fixturePrompts[0], echo: container.textContent, count: container.children.length,
                  empty: container.children[1].textContent === '', leaf: container.children[1].children.length === 0 };
                """) as? [String: Any]
            let sent = try XCTUnwrap(observed?["sent"] as? String)
            XCTAssertTrue(sent.hasPrefix(prompt + "\n\nComputa session marker: "))
            XCTAssertEqual(observed?["echo"] as? String, sent)
            XCTAssertEqual(observed?["count"] as? Int, 2)
            XCTAssertEqual(observed?["empty"] as? Bool, true); XCTAssertEqual(observed?["leaf"] as? Bool, true)
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testExtraTextHiddenTextOrInteractiveDecorationCannotGrantAnswerOrReplay() async throws {
        for kind in ["text", "hidden-text", "button", "focusable", "editable", "aria-control", "duplicate", "two"] {
            let fixture = try Fixture(setup: "deepseekFixture.options.firstUserSiblingKind='\(kind)'")
            defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic exact decorated prompt")
            do {
                _ = try await call(fixture, "webProviderPoll", token)
                XCTFail("Extra text or controls must not release an answer: \(kind)")
            } catch let failure as EmbeddedWebModelTransport.Failure {
                XCTAssertEqual(failure, .ownershipFailure(.javaScriptFirstUser), kind)
            }
            do {
                _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic exact decorated prompt")
                XCTFail("Rejected ownership must not replay Send: \(kind)")
            } catch { }
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "failed", kind)
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        }
    }

    func testDelayedToggleClaimsAreObservedWithoutRepeatedClicks() async throws {
        let fixture = try Fixture(setup: "deepseekFixture.options.searchDelayMs=100; deepseekFixture.options.deepThinkDelayMs=100")
        defer { fixture.shutdown() }
        let token = try await start(fixture, mode: .deepthink)
        let actual = try await evaluate(fixture.view, "return [deepseekFixture.counters.searchClicks, deepseekFixture.counters.deepThinkClicks, deepseekFixture.counters.inputs, deepseekFixture.counters.sends];") as? [Int]
        XCTAssertEqual(actual, [1, 1, 0, 0])
        let result = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(result["cleanup"] as? String, "not_created")
    }

    func testInertToggleNeverBecomesReadyOrReplaysClick() async throws {
        for inert in ["inertSearch", "inertDeepThink"] {
            let fixture = try Fixture(setup: "deepseekFixture.options.\(inert)=true", preparationTimeout: .seconds(1))
            defer { fixture.shutdown() }
            do { _ = try await start(fixture, mode: .deepthink); XCTFail("Inert control must not grant readiness") }
            catch { }
            let actual = try await evaluate(fixture.view, "return [deepseekFixture.counters.searchClicks, deepseekFixture.counters.deepThinkClicks, deepseekFixture.counters.inputs, deepseekFixture.counters.sends];") as? [Int]
            XCTAssertEqual(actual, [1, inert == "inertSearch" ? 0 : 1, 0, 0])
        }
    }

    func testChangedModeOrSearchAfterReadinessRejectsBeforeInputWithoutRepair() async throws {
        for change in ["deepseekFixture.setMode(true,false)", "deepseekFixture.setMode(false,true)"] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await evaluate(fixture.view, change + "; return true;")
            do { _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic wrong mode"); XCTFail("Changed controls must fail") }
            catch { }
            let actual = try await evaluate(fixture.view, "return [deepseekFixture.counters.searchClicks, deepseekFixture.counters.deepThinkClicks, deepseekFixture.counters.inputs, deepseekFixture.counters.sends];") as? [Int]
            XCTAssertEqual(actual, [1, 0, 0, 0])
        }
    }

    func testMissingControlsAfterModeClaimCannotResetIntoHydrationOrRepeatToggle() async throws {
        let fixture = try Fixture(setup: "deepseekFixture.setMode(false,false); deepseekFixture.options.inertDeepThink=true",
            preparationTimeout: .seconds(2))
        defer { fixture.shutdown() }
        var removed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "selectModel", !removed {
                removed = true
                _ = try? await self.evaluate(fixture.view, "document.querySelector('.ds-button--circle').remove(); return true;")
            }
        }
        do { _ = try await start(fixture, mode: .deepthink); XCTFail("A claimed toggle cannot reset into hydration") }
        catch { }
        XCTAssertTrue(removed)
        let actual = try await evaluate(fixture.view, "return [deepseekFixture.counters.searchClicks, deepseekFixture.counters.deepThinkClicks, deepseekFixture.counters.inputs, deepseekFixture.counters.sends];") as? [Int]
        XCTAssertEqual(actual, [0, 1, 0, 0])
    }

    func testPartialResponseDoesNotCompleteUntilTerminalControlsReturn() async throws {
        let fixture = try Fixture(setup: "deepseekFixture.options.holdResponse=true"); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic partial response")
        _ = try await evaluate(fixture.view, "deepseekFixture.completeResponse(); deepseekFixture.resumeStreaming(); return true;")
        let running = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(running["state"] as? String, "running")
        _ = try await evaluate(fixture.view, "deepseekFixture.completeResponse(); return true;")
        _ = try await wait(fixture, token, state: "complete")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testNullModeProofCapturesInitialRemountReasonOnceBeforeCleanupWithoutRepairOrReplay() async throws {
        let fixture = try Fixture(setup: """
            deepseekFixture.options.delayUser = true;
            document.querySelector('.ds-button--circle').addEventListener('click', () => {
              const control = document.querySelectorAll('.ds-toggle-button')[0];
              control.replaceWith(control.cloneNode(true));
            });
            """)
        defer { fixture.shutdown() }
        let token = try await start(fixture)
        var diagnostics: [String] = []
        fixture.transport.setDeepSeekModeDiagnosticObserverForTesting { diagnostics.append($0) }
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic delayed first body with remounted mode control")
        do {
            _ = try await call(fixture, "webProviderPoll", token)
            XCTFail("A null optional mode proof must preserve the original native failure")
        } catch let failure as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(failure, .modelUnverified)
        }
        XCTAssertEqual(diagnostics.count, 1)
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(diagnostics.first).utf8)) as? [String: Any])
        XCTAssertEqual(packet["reason"] as? String, "deepthink_replaced")
        XCTAssertEqual(packet["required"] as? Bool, false)
        XCTAssertEqual(packet["modeMatches"] as? Bool, true)
        XCTAssertEqual(packet["searchSelected"] as? Bool, false)
        XCTAssertEqual(packet["deepThinkWasConnected"] as? Bool, false)
        XCTAssertEqual(packet["searchWasConnected"] as? Bool, true)
        XCTAssertEqual(packet["composerSameNode"] as? Bool, true)
        XCTAssertEqual(packet["firstBodyBound"] as? Bool, false)
        _ = try await evaluate(fixture.view, "deepseekFixture.appendUser(); return true;")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertEqual(diagnostics.count, 1, "A later required cleanup failure cannot overwrite the original read")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        let toggles = try await evaluate(fixture.view, "return [deepseekFixture.counters.deepThinkClicks, deepseekFixture.counters.searchClicks];") as? [Int]
        XCTAssertEqual(toggles, [0, 1], "Diagnostics never repair or replay a mode toggle")
    }

    func testChangedFirstUserBodyRetainsExactOwnershipFailureAndNativeDiagnostic() async throws {
        let fixture = try Fixture(setup: "deepseekFixture.options.holdResponse=true")
        defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic first-user classification")
        var records: [String] = []
        fixture.transport.setFirstUserDiagnosticsObserverForTesting { records += $0 }
        _ = try await evaluate(fixture.view, """
            document.querySelector('.ds-collapsible-text > div > span').textContent = 'Synthetic changed first user';
            return true;
            """)
        do {
            _ = try await call(fixture, "webProviderPoll", token)
            XCTFail("Changed first-user bytes must not release an answer")
        } catch let failure as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(failure, .ownershipFailure(.javaScriptFirstUser))
        }
        let values = try records.compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertTrue(values.contains { $0["kind"] as? String == "first_user_native"
            && $0["provider"] as? String == "deepseek" && $0["stage"] as? String == "adapter_rejected" })
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic first-user classification")
            XCTFail("The failed ownership check must not replay Send")
        } catch { }
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
    }

    func testLostSendCallbackCannotReplayOrGrantDeletion() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, """
            const original = HTMLElement.prototype.click;
            HTMLElement.prototype.click = function() {
              const isSend = this.classList.contains('ds-button--circle'); original.call(this);
              if (isSend) throw new Error('Synthetic lost Send acknowledgement');
            }; return true;
            """, world: world)
        do { _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic ambiguous dispatch"); XCTFail("Lost acknowledgement must fail") }
        catch { }
        do { _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic ambiguous dispatch"); XCTFail("No replay") }
        catch { }
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
    }

    func testDelayedDeletionAndConcurrentFinishClaimsEachMutationOnce() async throws {
        let fixture = try Fixture(setup: "deepseekFixture.options.menuDelayMs=100; deepseekFixture.options.dialogDelayMs=100")
        defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic delayed deletion")
        _ = try await wait(fixture, token, state: "complete")
        let first = Task { try await self.call(fixture, "webProviderFinish", token)["cleanup"] as? String }
        let second = Task { try await self.call(fixture, "webProviderCancel", token)["cleanup"] as? String }
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, "deleted"); XCTAssertEqual(b, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testSameClaimedDeletionMenuWaitsForRemovalWithAndWithoutDialogOverlap() async throws {
        for overlap in [false, true] {
            for mode in WebsiteModeChoice.DeepSeekMode.allCases {
                let fixture = try Fixture(setup: "deepseekFixture.options.holdDeletionMenu=true; deepseekFixture.options.holdDialog=\(!overlap)")
                defer { fixture.shutdown() }
                let token = try await start(fixture, mode: mode)
                _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic held menu and dialog ordering")
                _ = try await wait(fixture, token, state: "complete")
                var selectedPending = false
                fixture.transport.setBeforePageResultValidationForTesting { action in
                    guard action == "selectConversationDeletion", !selectedPending else { return }
                    selectedPending = true
                    let held = (try? await self.evaluate(fixture.view, "return deepseekFixture.snapshot();")) as? [String: Any]
                    XCTAssertEqual(held?["menuPresent"] as? Bool, true)
                    XCTAssertEqual(held?["dialogPresent"] as? Bool, overlap)
                    let counts = held?["counters"] as? [String: Any]
                    XCTAssertEqual(counts?["deleteSelections"] as? Int, 1)
                    XCTAssertEqual(counts?["confirmations"] as? Int, 0)
                    // The same physical menu disappears on a later DOM event.
                    // In the non-overlap case the dialog appears later still.
                    _ = try? await self.evaluate(fixture.view, """
                        setTimeout(() => deepseekFixture.closeDeletionMenu(), 100);
                        if (deepseekFixture.options.holdDialog) setTimeout(() => deepseekFixture.showConfirmation(), 200);
                        return true;
                        """)
                }
                let first = Task { try await self.call(fixture, "webProviderFinish", token)["cleanup"] as? String }
                let second = Task { try await self.call(fixture, "webProviderCancel", token)["cleanup"] as? String }
                let a = try await first.value, b = try await second.value
                fixture.transport.setBeforePageResultValidationForTesting(nil)
                XCTAssertTrue(selectedPending)
                XCTAssertEqual(a, "deleted"); XCTAssertEqual(b, "deleted")
                let repeated = try await call(fixture, "webProviderFinish", token)
                XCTAssertEqual(repeated["cleanup"] as? String, "deleted")
                try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
                let early = try await evaluate(fixture.view, "return deepseekFixture.counters.prematureConfirmations;") as? Int
                XCTAssertEqual(early, 0, "An overlapping dialog is not actionable while the owned menu remains visible")
                XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
                XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
            }
        }
    }

    func testForeignOrReplacedMenuAfterDeleteSelectionFailsWithoutConfirmOrReplay() async throws {
        for mutation in ["foreign", "replaced"] {
            let fixture = try Fixture(setup: "deepseekFixture.options.holdDeletionMenu=true; deepseekFixture.options.deleteMenuMutation='\(mutation)'")
            defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic changed deletion menu")
            _ = try await wait(fixture, token, state: "complete")
            let failed = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(failed["cleanup"] as? String, "failed", mutation)
            let repeated = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(repeated["cleanup"] as? String, "failed", mutation)
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 0)
            XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testCleanupDiagnosticRetainsOriginalAdapterFailureAcrossRetryWithoutReplay() async throws {
        let fixture = try Fixture(setup: "deepseekFixture.options.holdDeletionMenu=true; deepseekFixture.options.deleteMenuMutation='foreign'")
        defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic cleanup diagnostic")
        _ = try await wait(fixture, token, state: "complete")
        let first = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(first["cleanup"] as? String, "failed")
        let original = try XCTUnwrap(WebsiteCleanupFailureDiagnostic.parse(first["cleanupDiagnostic"]))
        XCTAssertEqual(original.stage, .savedDeletion); XCTAssertEqual(original.failure, .ownership)
        XCTAssertEqual(original.ownershipReason, .javaScriptConversation)
        XCTAssertEqual(original.adapter?.error, .conversationChanged)
        XCTAssertEqual(original.adapter?.detail, .deleteConfirmMenuStillVisible)
        // The next attempt encounters terminal_operation, but cannot replace
        // the original diagnostic or replenish any destructive-action claim.
        let second = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(second["cleanup"] as? String, "failed")
        XCTAssertEqual(WebsiteCleanupFailureDiagnostic.parse(second["cleanupDiagnostic"]), original)
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        let native = EmbeddedWebModelTransport.cleanupFailureDiagnostic(
            EmbeddedWebModelTransport.Failure.ownershipFailure(.documentGenerationAfter), stage: .savedDeletion)
        XCTAssertEqual(native.failure, .ownership); XCTAssertEqual(native.ownershipReason, .documentGenerationAfter)
        XCTAssertEqual(WebsiteCleanupFailureDiagnostic.parse(native.dictionary), native)
        let unknown = EmbeddedWebModelTransport.cleanupFailureDiagnostic(NSError(domain: "PRIVATE_CANARY", code: 1), stage: .preflight)
        XCTAssertEqual(unknown.failure, .other); XCTAssertNil(unknown.ownershipReason)
    }

    func testHeldDeletionMenuDOMWakeupsCannotRenewFixedCleanupDeadlineOrRepeatSelection() async throws {
        let fixture = try Fixture(setup: "deepseekFixture.options.holdDeletionMenu=true; deepseekFixture.options.menuWakeupMs=50")
        defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic bounded held deletion menu")
        _ = try await wait(fixture, token, state: "complete")
        var observations = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "observeDeletedConversation" { observations += 1 }
        }
        // Exercise the actual ten-second native cleanup deadline. Frequent
        // read-only DOM wakeups and a concurrent finish must not renew it.
        let started = ContinuousClock.now
        let first = Task { try await self.call(fixture, "webProviderFinish", token)["cleanup"] as? String }
        let second = Task { try await self.call(fixture, "webProviderCancel", token)["cleanup"] as? String }
        let a = try await first.value, b = try await second.value
        let elapsed = ContinuousClock.now - started
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        _ = try await evaluate(fixture.view, "deepseekFixture.stopMenuWakeups(); return true;")
        XCTAssertEqual(a, "failed"); XCTAssertEqual(b, "failed")
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(9))
        XCTAssertLessThan(elapsed, .seconds(14))
        XCTAssertGreaterThan(observations, 1)
        let ticks = try await evaluate(fixture.view, "return deepseekFixture.counters.menuWakeups;") as? Int
        XCTAssertGreaterThan(try XCTUnwrap(ticks), 1)
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testChangedCanonicalRouteCannotDeleteForeignChat() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic route drift")
        _ = try await wait(fixture, token, state: "complete")
        _ = try await evaluate(fixture.view, "history.replaceState({}, '', '/a/chat/s/22221111-abcd-4333-8444-555555555555'); return true;")
        let failed = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(failed["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testImplicitDefaultNamedModelAndForeignModeStartRejectedBeforeCreatingTab() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let mode = WebsiteModeChoice(deepSeekMode: .chat)
        for parameters in [["provider": "deepseek"], ["provider": "deepseek", "modelChoice": mode.canonicalJSONString],
                           ["provider": "qwen", "modeChoice": mode.canonicalJSONString],
                           ["provider": "deepseek", "modeChoice": mode.canonicalJSONString, "modelChoice": mode.canonicalJSONString]] {
            do {
                _ = try await fixture.transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: parameters))
                XCTFail("Invalid selection kind must be rejected")
            } catch { }
            XCTAssertNil(fixture.createdID)
        }
    }

    func testArmedStructureSurvivesEarlierSuccessAndCapturesExactLaterFailureBeforeCleanup() async throws {
        let diagnostic = try WebsiteAdapterFailureFixture(); defer { diagnostic.cleanup() }
        try diagnostic.writeArm()
        do {
            let first = try Fixture(); defer { first.shutdown() }
            let token = try await nativeDiagnosticStart(first, admission: diagnostic.admission)
            _ = try await call(first, "webProviderSend", token, prompt: "Synthetic first successful marker")
            _ = try await wait(first, token, state: "complete")
            XCTAssertTrue(FileManager.default.fileExists(atPath: diagnostic.armURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostic.outputURL.path))
            let finished = try await call(first, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        }
        let failed = try Fixture(setup: DeepSeekFencedResponseFixture.setup(
            DeepSeekFencedResponseFixture.observedBlock + "<p>PRIVATE_SYNTHETIC_EXTRA_PROSE</p>"))
        defer { failed.shutdown() }
        let admission = diagnostic.admission(inferenceID: UUID())
        let token = try await nativeDiagnosticStart(failed, admission: admission)
        _ = try await call(failed, "webProviderSend", token, prompt: "Synthetic second-inference structure failure")
        do { _ = try await wait(failed, token, state: "complete"); XCTFail("Original rejection must remain") }
        catch let failure as EmbeddedWebModelTransport.Failure { XCTAssertEqual(failure, .responseFormatUnavailable) }
        // The view still exists, and cleanup has not been requested.
        XCTAssertNotNil(failed.browser.webView(for: try XCTUnwrap(failed.createdID)))
        let bytes = try Data(contentsOf: diagnostic.outputURL)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(record["inferenceID"] as? String, admission.inferenceID.uuidString.lowercased())
        XCTAssertEqual(record["taskID"] as? String, admission.taskID)
        XCTAssertEqual(record["sessionToken"] as? String, token.lowercased())
        XCTAssertEqual(record["error"] as? String, "unsupported_response_format")
        XCTAssertEqual(record["detail"] as? String, "authored_source")
        XCTAssertEqual(record["responseAuthorityGranted"] as? Bool, false)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE_SYNTHETIC_EXTRA_PROSE"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostic.armURL.path))
        try await assertCounts(failed, sends: 1, headers: 0, selections: 0, confirmations: 0)
        let finished = try await call(failed, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(failed, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertEqual(try Data(contentsOf: diagnostic.outputURL), bytes)
    }

    func testWrongTaskAndWireStartCannotCaptureButKeepOriginalFailure() async throws {
        for wire in [false, true] {
            let diagnostic = try WebsiteAdapterFailureFixture(); defer { diagnostic.cleanup() }
            var arm = diagnostic.arm(); if !wire { arm["taskID"] = UUID().uuidString.lowercased() }
            try diagnostic.writeArm(arm)
            let fixture = try Fixture(setup: DeepSeekFencedResponseFixture.setup(
                DeepSeekFencedResponseFixture.observedBlock + "<p>PRIVATE_REJECTED_TEXT</p>"))
            defer { fixture.shutdown() }
            let token: String
            if wire { token = try await start(fixture) }
            else { token = try await nativeDiagnosticStart(fixture, admission: diagnostic.admission) }
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic unarmed format failure")
            do { _ = try await wait(fixture, token, state: "complete"); XCTFail("No diagnostic can admit a reply") }
            catch let failure as EmbeddedWebModelTransport.Failure { XCTAssertEqual(failure, .responseFormatUnavailable) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostic.outputURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: diagnostic.armURL.path))
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        }
    }

    func testDocumentReplacementDuringFilePreparationRevokesPublicationBeforeRename() async throws {
        let diagnostic = try WebsiteAdapterFailureFixture(); defer { diagnostic.cleanup() }; try diagnostic.writeArm()
        let fixture = try Fixture(setup: DeepSeekFencedResponseFixture.setup(
            DeepSeekFencedResponseFixture.observedBlock + "<p>PRIVATE_REPLACED_DOCUMENT</p>"))
        defer { fixture.shutdown() }
        let token = try await nativeDiagnosticStart(fixture, admission: diagnostic.admission)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic stale-document diagnostic")
        var replaced = false
        fixture.transport.setAdapterFailureBeforeCommitForTesting {
            replaced = true
            if let id = fixture.createdID { fixture.browser.stop(tabID: id) }
        }
        do { _ = try await wait(fixture, token, state: "complete"); XCTFail("Original format error must remain") }
        catch let failure as EmbeddedWebModelTransport.Failure { XCTAssertEqual(failure, .responseFormatUnavailable) }
        XCTAssertTrue(replaced)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostic.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostic.armURL.path))
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
    }

    func testDiagnosticContextCannotClaimDifferentDeepSeekMode() async throws {
        let diagnostic = try WebsiteAdapterFailureFixture(); defer { diagnostic.cleanup() }; try diagnostic.writeArm()
        let fixture = try Fixture(setup: DeepSeekFencedResponseFixture.setup(
            DeepSeekFencedResponseFixture.observedBlock + "<p>PRIVATE_MODE_MISMATCH</p>"))
        defer { fixture.shutdown() }
        let a = diagnostic.admission
        // The native diagnostic must match the actual selection even if a
        // caller's broad provider admission supplies another mode identifier.
        let params = try JSONSerialization.data(withJSONObject: ["provider": "deepseek",
            "modeChoice": WebsiteModeChoice(deepSeekMode: .deepthink).canonicalJSONString])
        let mismatched = WebModelStartAdmission(id: a.id, inferenceID: a.inferenceID, taskID: a.taskID,
            threadID: a.threadID, turnID: a.turnID, runtimeGeneration: a.runtimeGeneration,
            preparationID: a.preparationID, transportGeneration: a.transportGeneration,
            provider: a.provider, modelID: a.modelID, parameters: params, adapterFailureDirectory: diagnostic.directory)
        let token = try await nativeDiagnosticStart(fixture, admission: mismatched)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic differently selected mode")
        do { _ = try await wait(fixture, token, state: "complete"); XCTFail("Original format error must remain") }
        catch let failure as EmbeddedWebModelTransport.Failure { XCTAssertEqual(failure, .responseFormatUnavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostic.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnostic.armURL.path))
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
    }

    private func nativeDiagnosticStart(_ fixture: Fixture, admission: WebModelStartAdmission) async throws -> String {
        let data = try await fixture.transport.start(params: admission.parameters, admission: admission, authorization: nil)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let token = try XCTUnwrap(snapshot["sessionToken"] as? String)
        _ = try await wait(fixture, token, state: "ready")
        return token
    }

    private func start(_ fixture: Fixture, mode: WebsiteModeChoice.DeepSeekMode = .chat) async throws -> String {
        let choice = WebsiteModeChoice(deepSeekMode: mode)
        let data = try await fixture.transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject:
            ["provider": "deepseek", "modeChoice": choice.canonicalJSONString]))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let token = try XCTUnwrap(snapshot["sessionToken"] as? String)
        _ = try await wait(fixture, token, state: "ready")
        return token
    }
    private func call(_ fixture: Fixture, _ operation: String, _ token: String, prompt: String? = nil) async throws -> [String: Any] {
        var values = ["sessionToken": token]; if let prompt { values["prompt"] = prompt }
        let data = try await fixture.transport.request(operation: operation, params: JSONSerialization.data(withJSONObject: values))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func wait(_ fixture: Fixture, _ token: String, state: String) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            let revision = try await fixture.transport.changeRevision(sessionToken: token)
            let value = try await call(fixture, "webProviderPoll", token)
            if value["state"] as? String == state { return value }
            _ = try await fixture.transport.waitForChange(sessionToken: token, after: try XCTUnwrap(revision), until: deadline)
        }
        throw FixtureFailure.timeout
    }
    private func assertCounts(_ fixture: Fixture, sends: Int, headers: Int, selections: Int, confirmations: Int) async throws {
        let actual = try await evaluate(fixture.view, "return [deepseekFixture.counters.sends, deepseekFixture.counters.historyOpens, deepseekFixture.counters.deleteSelections, deepseekFixture.counters.confirmations];") as? [Int]
        XCTAssertEqual(actual, [sends, headers, selections, confirmations])
    }
    private func evaluate(_ view: WKWebView, _ source: String, world: WKContentWorld = .page) async throws -> Any {
        let completion = EmbeddedScriptResult()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            completion.setTimeout(Task {
                do { try await Task.sleep(for: .seconds(3)); completion.complete(.failure(FixtureFailure.timeout)) } catch { }
            })
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    do { completion.complete(.success(try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))) }
                    catch { completion.complete(.failure(error)) }
                case .failure(let error): completion.complete(.failure(error))
                }
            }
        }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
    private enum FixtureFailure: Error { case timeout }
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    @MainActor private final class Fixture {
        let browser = EmbeddedBrowserSession(persistent: false)
        let window: Window
        let host: EmbeddedModelRenderContainer
        let humanID: UUID
        var transport: EmbeddedWebModelTransport!
        var createdID: UUID?
        var navigationOverride: URL?
        private var retainedView: WKWebView?
        var view: WKWebView { retainedView! }
        init(setup: String = "", preparationTimeout: Duration = .seconds(10)) throws {
            window = Window(contentRect: NSRect(x: 20, y: 20, width: 1024, height: 768), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
            host = EmbeddedModelRenderContainer(session: browser); host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            window.contentView = host; browser.installModelRenderHost(host); window.orderBack(nil)
            humanID = try browser.createTab()
            browser.webView(for: humanID)?.loadHTMLString("<p>Untouched human fixture</p>", baseURL: URL(string: "https://example.test/"))
            transport = EmbeddedWebModelTransport(browser: browser, createTabForTesting: { [unowned self] url in
                let id = try self.browser.createUnloadedModelTabForTesting()
                let view = try XCTUnwrap(self.browser.webView(for: id)); view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
                self.createdID = id; self.retainedView = view
                let html = DeepSeekFixturePage.html.replacingOccurrences(of: "window.fixtureReady = true;", with: setup + "; window.fixtureReady = true;")
                view.loadHTMLString(html, baseURL: self.navigationOverride ?? url)
                return id
            })
            transport.setTimeoutsForTesting(preparation: preparationTimeout, response: .seconds(12))
        }
        func shutdown() {
            browser.shutdown(); host.detach(); window.orderOut(nil); window.close()
        }
    }
}

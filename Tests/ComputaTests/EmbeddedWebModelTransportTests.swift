import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedWebModelTransportTests: XCTestCase {
    func testProductDiagnosticsPermitOnlyFiniteStructuralFields() throws {
        let control: [String: Any] = ["tag": "button", "role": NSNull(), "pressed": "true", "checked": NSNull(), "visible": true, "enabled": false]
        let raw: [String: Any] = ["kind": "chatgpt_product_mode_structure", "groupCount": 1,
            "groupVisible": true, "recognized": true, "contradictory": false,
            "chat": control, "work": NSNull(), "proofPresent": false, "proofInvalidated": false, "chatClickClaimed": false]
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(raw))
        XCTAssertLessThan(safe.utf8.count, 2_048)
        XCTAssertTrue(safe.contains("composer") == false)
        for (field, bad): (String, Any) in [("groupCount", true), ("groupCount", 17), ("groupCount", 0.5),
                                          ("recognized", 1), ("kind", "PRIVATE_RAW_PAGE_CANARY")] {
            var invalid = raw; invalid[field] = bad
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(invalid))
        }
        for field in ["role", "pressed", "tag"] {
            var item = control; item[field] = "PRIVATE_RAW_PAGE_CANARY"
            var invalid = raw; invalid["chat"] = item
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(invalid))
        }
        var additional = raw; additional["pageText"] = "PRIVATE_RAW_PAGE_CANARY"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(additional))
        additional = raw; var item = control; item["text"] = "PRIVATE_RAW_PAGE_CANARY"; additional["chat"] = item
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(additional))
    }

    func testChatGPTStartsOnNormalRootAndProvesChatBeforeOwnedTemporaryTransition() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        XCTAssertEqual(view.url?.absoluteString, "https://chatgpt.com/")
        let ready = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertEqual(try WebsiteProductModeEvidence.parse(ready["productModeEvidence"], requireTemporary: true).temporaryTransition, .acknowledged)
        let claims = try await evaluate(view, "return {chat: window.fixtureChatModeClicks, temporary: window.fixtureTemporaryModeClicks};") as? [String: Int]
        XCTAssertEqual(claims, ["chat": 0, "temporary": 1])
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Read through normal Chat"])
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(sent["productModeEvidence"], requireTemporary: true))
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
        let finish = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finish["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTClaimedWorkToChatSwitchIsAcknowledgedBeforeTemporaryClick() async throws {
        let fixture = try Fixture(page: Self.page.replacingOccurrences(of: "id=\"fixture-chat-mode\" aria-pressed=\"true\"", with: "id=\"fixture-chat-mode\" aria-pressed=\"false\"")
            .replacingOccurrences(of: "id=\"fixture-work-mode\" aria-pressed=\"false\"", with: "id=\"fixture-work-mode\" aria-pressed=\"true\""))
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let ready = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(ready["productModeEvidence"], requireTemporary: true))
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        let claims = try await evaluate(view, "return {chat: window.fixtureChatModeClicks, temporary: window.fixtureTemporaryModeClicks, inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
        XCTAssertEqual(claims, ["chat": 1, "temporary": 1, "inputs": 0, "sends": 0])
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
    }

    func testChatGPTDisabledRecognizedModePairWaitsForBothControlsBeforeProofTemporaryAndSend() async throws {
        for initiallyWork in [false, true] {
            var page = Self.page
            if initiallyWork {
                page = page.replacingOccurrences(of: "id=\"fixture-chat-mode\" aria-pressed=\"true\"", with: "id=\"fixture-chat-mode\" aria-pressed=\"false\"")
                    .replacingOccurrences(of: "id=\"fixture-work-mode\" aria-pressed=\"false\"", with: "id=\"fixture-work-mode\" aria-pressed=\"true\"")
            }
            page = page.replacingOccurrences(of: "id=\"fixture-chat-mode\"", with: "id=\"fixture-chat-mode\" disabled")
                .replacingOccurrences(of: "id=\"fixture-work-mode\"", with: "id=\"fixture-work-mode\" disabled")
            let fixture = try Fixture(page: page)
            defer { fixture.shutdown() }
            let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(start["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            for _ in 0..<2 {
                let waiting = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(waiting["state"] as? String, "loading")
                XCTAssertNil(waiting["productModeEvidence"], "Disabled selected controls cannot establish normal Chat provenance")
            }
            _ = try await evaluate(view, "document.getElementById('fixture-chat-mode').disabled = false; return true;")
            let partial = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(partial["state"] as? String, "loading", "A partially enabled pair cannot authorize the Chat or temporary click")
            XCTAssertNil(partial["productModeEvidence"])
            let untouched = try await evaluate(view, "return {chat: window.fixtureChatModeClicks, temporary: window.fixtureTemporaryModeClicks, inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
            XCTAssertEqual(untouched, ["chat": 0, "temporary": 0, "inputs": 0, "sends": 0])
            let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
            let revision = try XCTUnwrap(observedRevision)
            _ = try await evaluate(view, "document.getElementById('fixture-work-mode').disabled = false; return true;")
            let signaledRevision = try await fixture.transport.waitForChange(sessionToken: token, after: revision, until: .now + .seconds(1))
            let signaled = try XCTUnwrap(signaledRevision)
            XCTAssertGreaterThan(signaled, revision, "Enabling the actual controls must wake the existing DOM observer")
            let ready = try await waitForState("ready", fixture.transport, token: token)
            XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(ready["productModeEvidence"], requireTemporary: true))
            XCTAssertEqual(view.url?.absoluteString, "https://chatgpt.com/?temporary-chat=true")
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Send once after mode hydration completes"])
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
            let ledger = try await evaluate(view, "return {chat: window.fixtureChatModeClicks, temporary: window.fixtureTemporaryModeClicks, inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
            XCTAssertEqual(ledger, ["chat": initiallyWork ? 1 : 0, "temporary": 1, "inputs": 1, "sends": 1])
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTNeverEnabledModePairStopsAtPreparationDeadlineWithoutActions() async throws {
        let page = Self.page.replacingOccurrences(of: "id=\"fixture-chat-mode\"", with: "id=\"fixture-chat-mode\" disabled")
            .replacingOccurrences(of: "id=\"fixture-work-mode\"", with: "id=\"fixture-work-mode\" disabled")
        let fixture = try Fixture(page: page)
        defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(1), response: .seconds(300))
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        let end = ContinuousClock.now + .seconds(3)
        var timedOut = false
        while ContinuousClock.now < end {
            let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
            let revision = try XCTUnwrap(observedRevision)
            do {
                let waiting = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(waiting["state"] as? String, "loading")
                XCTAssertNil(waiting["productModeEvidence"])
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .preparationDeadline)
                timedOut = true; break
            }
            _ = try await fixture.transport.waitForChange(sessionToken: token, after: revision, until: end)
        }
        XCTAssertTrue(timedOut, "Disabled mode controls cannot turn the existing preparation deadline into an unbounded wait")
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never insert into an unprepared product"])
            XCTFail("A never-enabled mode pair cannot authorize Send")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
        let ledger = try await evaluate(view, "return {chat: window.fixtureChatModeClicks, temporary: window.fixtureTemporaryModeClicks, inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
        XCTAssertEqual(ledger, ["chat": 0, "temporary": 0, "inputs": 0, "sends": 0])
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTDisabledModeControlsAfterRootProofCannotRestartHydrationBeforeTemporaryClaim() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        var crossed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "verifyProductMode", !crossed else { return }
            let proof = try? await self.evaluate(view, "return {present: !!globalThis.__computaChatProductMode, temporaryRequested: globalThis.__computaChatProductMode?.temporaryRequested === true};",
                world: .world(name: "computa-chatgpt-model-v1")) as? [String: Bool]
            XCTAssertEqual(proof, ["present": true, "temporaryRequested": false], "The controls must lose enabling after real root Chat proof and before the temporary action")
            crossed = true
            _ = try? await self.evaluate(view, """
                document.getElementById('fixture-chat-mode').disabled = true;
                document.getElementById('fixture-work-mode').disabled = true;
                return true;
                """)
        }
        defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("Lost root product proof cannot become initial pending hydration")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
        XCTAssertTrue(crossed)
        _ = try await evaluate(view, "document.getElementById('fixture-chat-mode').disabled = false; document.getElementById('fixture-work-mode').disabled = false; return true;")
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("Re-enabling controls cannot revive the invalidated product proof or failed inference")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Do not reuse lost normal Chat proof"])
            XCTFail("Invalidated root provenance cannot authorize insertion or Send")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
        let ledger = try await evaluate(view, "return {chat: window.fixtureChatModeClicks, temporary: window.fixtureTemporaryModeClicks, inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
        XCTAssertEqual(ledger, ["chat": 0, "temporary": 0, "inputs": 0, "sends": 0])
    }

    func testChatGPTAcknowledgedTemporaryModeRetainsProofWithLockedComplementaryControls() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let ready = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(ready["productModeEvidence"], requireTemporary: true))
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        let privateWorld = WKContentWorld.world(name: "computa-chatgpt-model-v1")
        _ = try await evaluate(view, "globalThis.__fixtureAcknowledgedProductProof = globalThis.__computaChatProductMode; return true;", world: privateWorld)
        _ = try await evaluate(view, """
            document.getElementById('fixture-composer-mode').hidden = false;
            document.getElementById('fixture-chat-mode').disabled = true;
            document.getElementById('fixture-work-mode').disabled = true;
            return true;
            """)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Continue under the established normal Chat and actual temporary proof"])
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(sent["productModeEvidence"], requireTemporary: true))
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
        let retained = try await evaluate(view, "return {same: globalThis.__fixtureAcknowledgedProductProof === globalThis.__computaChatProductMode, invalidated: globalThis.__computaChatProductMode?.invalidated === true, requested: globalThis.__computaChatProductMode?.temporaryRequested === true, acknowledged: globalThis.__computaChatProductMode?.temporaryAcknowledged === true};", world: privateWorld) as? [String: Bool]
        XCTAssertEqual(retained, ["same": true, "invalidated": false, "requested": true, "acknowledged": true],
            "Complementary locked controls retain existing acknowledged proof without acquiring new hydration provenance")
        let ledger = try await evaluate(view, "return {chat: window.fixtureChatModeClicks, temporary: window.fixtureTemporaryModeClicks, inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
        XCTAssertEqual(ledger, ["chat": 0, "temporary": 1, "inputs": 1, "sends": 1])
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTMissingConflictingOrDirectTemporaryProductModeCannotBecomeReady() async throws {
        for variant in ["missing", "conflicting", "direct_temporary"] {
            let fixture = try Fixture(initialURL: variant == "direct_temporary" ? URL(string: "https://chatgpt.com/?temporary-chat=true") : nil)
            defer { fixture.shutdown() }
            let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(start["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            if variant == "missing" { _ = try await evaluate(view, "document.getElementById('fixture-composer-mode').remove(); return true;") }
            if variant == "conflicting" { _ = try await evaluate(view, "document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true'); return true;") }
            for _ in 0..<2 {
                do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Unproven product cannot authorize readiness") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
            }
            let claims = try await evaluate(view, "return {chat: window.fixtureChatModeClicks, temporary: window.fixtureTemporaryModeClicks, inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
            XCTAssertEqual(claims, ["chat": 0, "temporary": 0, "inputs": 0, "sends": 0])
            let finish = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(finish["cleanup"] as? String, "failed", "Missing initial product proof cannot confer document cleanup authority")
            try await assertHumanTabIntact(fixture, retaining: fixture.createdTabs.last)
        }
    }

    func testChatGPTWorkDriftAcrossNativeAwaitCannotAdmitInsertionSendOrResponse() async throws {
        for actionToCross in ["prepare", "insert", "submit"] {
            let fixture = try Fixture()
            defer { fixture.shutdown() }
            let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(start["sessionToken"] as? String)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            var crossed = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == actionToCross, !crossed else { return }
                crossed = true
                _ = try? await self.evaluate(view, """
                    document.getElementById('fixture-composer-mode').hidden = false;
                    document.getElementById('fixture-chat-mode').setAttribute('aria-pressed','false');
                    document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true'); return true;
                    """)
            }
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never accept a Work response"])
                XCTFail("A stale Chat acknowledgment must be discarded after a native await")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
            XCTAssertTrue(crossed)
            let ledger = try await evaluate(view, "return {inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
            XCTAssertEqual(ledger, ["inputs": actionToCross == "prepare" ? 0 : 1, "sends": actionToCross == "submit" ? 1 : 0])
            do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("A product error is terminal without response acceptance") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
        }
    }

    func testCheckpointURLClassificationRequiresExactTrustedOriginAndPath() throws {
        let provider = EmbeddedWebModelTransport.Provider.gemini
        for raw in ["https://google.com/sorry", "https://www.google.com/sorry/index?private_canary=secret", "https://google.com:443/sorry/"] {
            XCTAssertEqual(provider.blockingFailure(for: URL(string: raw)), .humanVerificationRequired(.gemini))
        }
        for raw in ["http://google.com/sorry/", "https://google.com:444/sorry/", "https://user:secret@google.com/sorry/",
                    "https://google.com.evil.test/sorry/", "https://evil.test/?next=https://google.com/sorry/",
                    "https://www.google.com/sorry-about", "https://gemini.google.com/app/sorry", "https://google.com/search?q=captcha"] {
            XCTAssertNil(provider.blockingFailure(for: URL(string: raw)), raw)
        }
        XCTAssertNil(provider.blockingFailure(for: nil))
        XCTAssertNil(EmbeddedWebModelTransport.Provider.claude.blockingFailure(for: URL(string: "https://google.com/sorry/")))
        for (selected, raw) in [(EmbeddedWebModelTransport.Provider.gemini, "https://accounts.google.com/v3/signin/identifier"),
                                (.chatgpt, "https://chatgpt.com/auth/login"), (.claude, "https://claude.ai/login")] {
            XCTAssertEqual(selected.blockingFailure(for: URL(string: raw)), .signInRequired)
        }
        XCTAssertNil(provider.blockingFailure(for: URL(string: "https://accounts.google.com.evil.test/signin")))
        let failure = EmbeddedWebModelTransport.Failure.humanVerificationRequired(.gemini)
        XCTAssertEqual(failure.diagnosticCode, "website_verification_required")
        XCTAssertEqual(failure.requiredAction, "complete_website_verification")
        XCTAssertFalse(failure.localizedDescription.contains("private_canary"))
        for gate in [failure, .signInRequired, .usageLimited(.claude)] {
            XCTAssertTrue(gate.blocksProviderUntilRefresh)
            XCTAssertTrue(gate.localizedDescription.contains("refresh website models"))
        }
        for localFailure: EmbeddedWebModelTransport.Failure in [.unexpectedPage(.gemini), .modelMismatch, .ownershipFailure(.routeAfter)] {
            XCTAssertFalse(localFailure.blocksProviderUntilRefresh)
        }
    }

    func testInitialCheckpointAndUnexpectedPageFailImmediatelyAndLatchWithoutAdapterWork() async throws {
        let cases: [(URL, EmbeddedWebModelTransport.Failure)] = [
            (URL(string: "https://www.google.com/sorry/index?private_canary=secret")!, .humanVerificationRequired(.gemini)),
            (URL(string: "https://accounts.google.com/v3/signin/identifier")!, .signInRequired),
            (URL(string: "https://unexpected.example.test/checkpoint")!, .unexpectedPage(.gemini)),
        ]
        for (url, failure) in cases {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: url)
            defer { fixture.shutdown() }
            let start = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(start["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            let began = ContinuousClock.now
            for _ in 0..<4 {
                do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("A checkpoint cannot enter readiness") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, failure) }
            }
            XCTAssertLessThan(ContinuousClock.now - began, .seconds(1), "Recognized blockers must bypass the hydration retry delay")
            let adapterOwner = try await evaluate(view, "return globalThis.__computaModelOwner === undefined;", world: .world(name: "computa-chatgpt-model-v1")) as? Bool
            XCTAssertEqual(adapterOwner, true, "Provider JavaScript must never execute on a foreign checkpoint")
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)

            // Returning the URL to a valid-looking fixture cannot revive this
            // inference. Recovery requires an explicit refresh and new session.
            view.loadHTMLString(Self.modelChoicePage(.gemini).replacingOccurrences(of: "'initial'", with: "'restored'"), baseURL: URL(string: "https://gemini.google.com/app"))
            try await waitForFixture(view, generation: "restored")
            for operation in ["webProviderPoll", "webProviderSend"] {
                var params = ["sessionToken": token]
                if operation == "webProviderSend" { params["prompt"] = "Must never be replayed" }
                do { _ = try await call(fixture.transport, operation, params); XCTFail("A terminal checkpoint cannot resume implicitly") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, failure) }
            }
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            let cancelled = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(cancelled["state"] as? String, "failed")
            XCTAssertEqual(cancelled["cleanup"] as? String, "failed", "Classification cannot grant cleanup authority after document replacement")
            try await assertHumanTabIntact(fixture, retaining: id)
        }
    }

    func testCheckpointRedirectAcrossReadOrPrepareAwaitDiscardsResultBeforeInsertion() async throws {
        let cases: [(String, String, EmbeddedWebModelTransport.Failure)] = [
            ("inspect", "https://www.google.com/sorry/index?private_canary=secret", .humanVerificationRequired(.gemini)),
            ("prepare", "https://www.google.com/sorry/index?private_canary=secret", .humanVerificationRequired(.gemini)),
            ("inspect", "https://unexpected.example.test/checkpoint", .unexpectedPage(.gemini)),
            ("prepare", "https://unexpected.example.test/checkpoint", .unexpectedPage(.gemini)),
        ]
        for (interruptedAction, destination, expectedFailure) in cases {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
            defer { fixture.shutdown() }
            let start = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(start["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            if interruptedAction == "prepare" { _ = try await waitForState("ready", fixture.transport, token: token) }
            var redirected = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == interruptedAction, !redirected else { return }
                redirected = true
                view.loadHTMLString(Self.modelChoicePage(.gemini).replacingOccurrences(of: "'initial'", with: "'checkpoint'"), baseURL: URL(string: destination))
                try? await self.waitForFixture(view, generation: "checkpoint")
            }
            var params = ["sessionToken": token]
            if interruptedAction == "prepare" { params["prompt"] = "Must not cross a challenge redirect" }
            do {
                _ = try await call(fixture.transport, interruptedAction == "prepare" ? "webProviderSend" : "webProviderPoll", params)
                XCTFail("An obsolete ready/editor result cannot cross a challenge redirect")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expectedFailure) }
            XCTAssertTrue(redirected)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            let cancelled = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(cancelled["cleanup"] as? String, "failed")
            try await assertHumanTabIntact(fixture, retaining: id)
        }
    }

    func testInitialBlankDocumentCanHydrateWithoutBeingLatchedAsUnexpectedPage() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "about:blank"))
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let id = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: id))
        try await waitForFixture(view)
        let initial = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(initial["state"] as? String, "loading")
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        view.loadHTMLString(Self.modelChoicePage(.gemini).replacingOccurrences(of: "'initial'", with: "'hydrated'"), baseURL: URL(string: "https://gemini.google.com/app"))
        try await waitForFixture(view, generation: "hydrated")
        _ = try await waitForState("ready", fixture.transport, token: token)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testProviderGateStopsNewTasksAndDiscoveryUntilExplicitSuccessfulRefresh() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let blockedID = try XCTUnwrap(fixture.createdTabs.last)
        try await waitForFixture(XCTUnwrap(fixture.browser.webView(for: blockedID)))
        do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Expected checkpoint") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }

        // A healthy-looking next URL must not cause automatic retry traffic.
        fixture.initialURL = nil
        for _ in 0..<3 {
            do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"]); XCTFail("Expected provider gate") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            do { _ = try await fixture.transport.discoverModels(provider: "gemini"); XCTFail("Expected provider gate") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        }
        XCTAssertEqual(fixture.createdTabs.count, 1, "Blocked requests cannot even create a navigating tab")

        // The gate is per provider; another provider can still finish a task.
        fixture.page = Self.modelChoicePage(.claude)
        let other = try await call(fixture.transport, "webProviderStart", ["provider": "claude"])
        let otherToken = try XCTUnwrap(other["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: otherToken)
        let otherFinished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": otherToken])
        XCTAssertEqual(otherFinished["cleanup"] as? String, "not_created")

        fixture.page = Self.modelChoicePage(.gemini)
        let choices = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true)
        XCTAssertEqual(choices.map(\.label), Self.choiceLabels(.gemini))
        XCTAssertEqual(fixture.createdTabs.count, 3)
        // Successful recovery never resurrects the failed inference or replays it.
        do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Old inference must stay terminal") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        let recovered = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let recoveredToken = try XCTUnwrap(recovered["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: recoveredToken)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": recoveredToken])
        let cancelled = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
        XCTAssertEqual(cancelled["cleanup"] as? String, "failed", "Recovery cannot grant ownership of the old challenge document")
        try await assertHumanTabIntact(fixture, retaining: blockedID)
    }

    func testCleanupFirstCheckpointBlocksNewAndActiveSessionsUntilExplicitRecovery() async throws {
        for operation in ["webProviderFinish", "webProviderCancel"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let blockedID = try XCTUnwrap(fixture.createdTabs.last)
            let blockedView = try XCTUnwrap(fixture.browser.webView(for: blockedID))
            _ = try await waitForState("ready", fixture.transport, token: token)
            let peer = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let peerToken = try XCTUnwrap(peer["sessionToken"] as? String)
            let peerView = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: peerToken)

            blockedView.loadHTMLString(Self.modelChoicePage(.gemini).replacingOccurrences(of: "'initial'", with: "'checkpoint'"),
                                       baseURL: URL(string: "https://www.google.com/sorry/index?private_canary=secret"))
            try await waitForFixture(blockedView, generation: "checkpoint")
            // No Poll/Send observes this redirect before cleanup.
            let finished = try await call(fixture.transport, operation, ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertEqual(finished["state"] as? String, "failed")
            XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.contains("gemini"))
            XCTAssertTrue(fixture.browser.webView(for: blockedID) === blockedView)
            let unbound = try await evaluate(blockedView, "return globalThis.__computaModelOwner === undefined;",
                                            world: .world(name: "computa-chatgpt-model-v1")) as? Bool
            XCTAssertEqual(unbound, true, "Cleanup must not execute the provider adapter on a checkpoint")
            for _ in 0..<2 {
                do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"]); XCTFail("Cleanup must latch new-session admission") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
                do { _ = try await fixture.transport.discoverModels(provider: "gemini"); XCTFail("Automatic discovery must not navigate") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            }
            for action in ["webProviderPoll", "webProviderSend"] {
                var params = ["sessionToken": peerToken]
                if action == "webProviderSend" { params["prompt"] = "Must not insert after cleanup detected verification" }
                do { _ = try await call(fixture.transport, action, params); XCTFail("The shared provider peer must be terminal") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            }
            XCTAssertEqual(fixture.createdTabs.count, 2)
            try await assertChoiceLedger(peerView, insertions: 0, sends: 0, selections: 0)
            try await assertChoiceLedger(blockedView, insertions: 0, sends: 0, selections: 0)

            fixture.initialURL = URL(string: "https://google.com/sorry/")
            do { _ = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true); XCTFail("Failed explicit recovery must keep the gate") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            XCTAssertEqual(fixture.createdTabs.count, 3)
            XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.contains("gemini"))
            fixture.initialURL = nil
            var recoveryView: WKWebView?
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "discoverModels" { recoveryView = fixture.createdTabs.last.flatMap { fixture.browser.webView(for: $0) } }
            }
            let choices = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertEqual(choices.map(\.label), Self.choiceLabels(.gemini))
            XCTAssertEqual(fixture.createdTabs.count, 4)
            XCTAssertFalse(fixture.browser.savedHumanVerificationProviders.contains("gemini"))
            try await assertChoiceLedger(XCTUnwrap(recoveryView), insertions: 0, sends: 0, selections: 0)
            do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": peerToken]); XCTFail("Recovery cannot revive an old inference") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            let oldCleanup = try await call(fixture.transport, operation, ["sessionToken": token])
            XCTAssertEqual(oldCleanup["cleanup"] as? String, "failed")
            XCTAssertFalse(fixture.browser.savedHumanVerificationProviders.contains("gemini"), "Old terminal cleanup cannot re-latch its stale checkpoint")
            let fresh = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let freshToken = try XCTUnwrap(fresh["sessionToken"] as? String)
            _ = try await waitForState("ready", fixture.transport, token: freshToken)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": freshToken])
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": peerToken])
            try await assertHumanTabIntact(fixture, retaining: blockedID)
        }
    }

    func testCleanupFirstCheckpointBeforeModeSetupStillBlocksAdmission() async throws {
        for operation in ["webProviderFinish", "webProviderCancel"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last)
            try await waitForFixture(XCTUnwrap(fixture.browser.webView(for: id)))
            let finished = try await call(fixture.transport, operation, ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertEqual(finished["state"] as? String, "failed")
            do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"]); XCTFail("Unbound cleanup still observes a real provider checkpoint") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            XCTAssertEqual(fixture.createdTabs.count, 1)
            try await assertHumanTabIntact(fixture, retaining: id)
        }
    }

    func testCleanupFirstFixedAdapterQuotaBlocksAdmissionWithoutPersistingVerification() async throws {
        let fixture = try Fixture(page: Self.freshClaudeQuotaBannerPage.replacingOccurrences(of: "id=\"fixture-quota-banner\"", with: "id=\"fixture-quota-banner\" hidden"))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "claude"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let id = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: id))
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await evaluate(view, "document.getElementById('fixture-quota-banner').hidden = false; return true;")
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertEqual(finished["state"] as? String, "failed")
        do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "claude"]); XCTFail("A cleanup-only quota observation must gate future tasks") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .usageLimited(.claude)) }
        XCTAssertEqual(fixture.createdTabs.count, 1)
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty, "Quota retains the existing memory-only policy")
        for variable in ["fixtureInputCount", "fixtureFocusCount", "fixtureQuotaClicks"] {
            let value = try await evaluate(view, "return window.\(variable);") as? Int
            XCTAssertEqual(value, 0)
        }
        try await assertHumanTabIntact(fixture, retaining: id)
    }

    func testSavedVerificationSurvivesSameProfileTransportRecreationUntilExplicitRecovery() async throws {
        let suiteName = "ComputaVerificationGateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()
        let firstBrowser = EmbeddedBrowserSession(persistent: true, profileID: profileID, defaults: defaults)
        let first = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"), browser: firstBrowser)
        let started = try await call(first.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        try await waitForFixture(XCTUnwrap(first.browser.webView(for: XCTUnwrap(first.createdTabs.last))))
        let finished = try await call(first.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        let savedID = try XCTUnwrap(firstBrowser.savedHumanVerificationCheckpointIDs["gemini"])
        first.shutdown()

        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let nextBrowser = EmbeddedBrowserSession(persistent: true, profileID: profileID, defaults: restoredDefaults)
        let next = try Fixture(page: Self.modelChoicePage(.gemini), browser: nextBrowser)
        defer { next.shutdown() }
        XCTAssertEqual(nextBrowser.savedHumanVerificationCheckpointIDs["gemini"], savedID)
        do { _ = try await call(next.transport, "webProviderStart", ["provider": "gemini"]); XCTFail("Restart must not re-open a blocked provider") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        do { _ = try await next.transport.discoverModels(provider: "gemini"); XCTFail("Startup discovery must not bypass a saved checkpoint") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        XCTAssertTrue(next.createdTabs.isEmpty)
        let choices = try await next.transport.discoverModels(provider: "gemini", retryBlocked: true)
        XCTAssertEqual(choices.map(\.label), Self.choiceLabels(.gemini))
        XCTAssertEqual(next.createdTabs.count, 1, "Only the explicit read-only recovery may create a page")
        XCTAssertTrue(nextBrowser.savedHumanVerificationProviders.isEmpty)
        let reopenedBrowser = EmbeddedBrowserSession(persistent: true, profileID: profileID, defaults: restoredDefaults)
        defer { reopenedBrowser.shutdown() }
        XCTAssertTrue(reopenedBrowser.savedHumanVerificationProviders.isEmpty, "Verified recovery must clear the persisted checkpoint too")
        let recovered = try await call(next.transport, "webProviderStart", ["provider": "gemini"])
        let recoveredToken = try XCTUnwrap(recovered["sessionToken"] as? String)
        _ = try await waitForState("ready", next.transport, token: recoveredToken)
        _ = try await call(next.transport, "webProviderFinish", ["sessionToken": recoveredToken])
        try await assertHumanTabIntact(next)
    }

    func testHumanCheckpointWakesActiveInferenceAndPreventsSend() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let id = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: id))
        _ = try await waitForState("ready", fixture.transport, token: token)
        let waiter = Task { @MainActor in
            do {
                let deadline = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < deadline {
                    let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
                    let revision = try XCTUnwrap(observedRevision)
                    _ = try await fixture.transport.waitForChange(sessionToken: token, after: revision, until: deadline)
                }
                return false
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini))
                return true
            }
        }
        fixture.humanView.loadHTMLString(Self.modelChoicePage(.gemini).replacingOccurrences(of: "'initial'", with: "'human-checkpoint'"),
                                        baseURL: URL(string: "https://google.com/sorry/"))
        try await waitForFixture(fixture.humanView, generation: "human-checkpoint")
        let wokeBlocked = await waiter.value
        XCTAssertTrue(wokeBlocked)
        do { _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not insert after human verification appears"]); XCTFail("The active model session must synchronize the human-page gate") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        XCTAssertEqual(fixture.createdTabs.count, 1)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        let closed = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(closed["cleanup"] as? String, "not_created", "The gate cannot weaken or obstruct independently owned cleanup")
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testNewHumanCheckpointDuringExplicitRecoveryCannotBeCleared() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
        defer { fixture.shutdown() }
        fixture.browser.recordHumanVerificationRequired(provider: "gemini")
        let firstID = try XCTUnwrap(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"])
        var crossed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "discoverModels", !crossed else { return }
            crossed = true
            fixture.humanView.loadHTMLString(Self.modelChoicePage(.gemini).replacingOccurrences(of: "'initial'", with: "'human-checkpoint'"),
                                            baseURL: URL(string: "https://google.com/sorry/"))
            try? await self.waitForFixture(fixture.humanView, generation: "human-checkpoint")
        }
        do { _ = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true); XCTFail("Recovery must not clear a newer human checkpoint") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertTrue(crossed)
        let newID = try XCTUnwrap(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertNotEqual(newID, firstID)
        XCTAssertEqual(fixture.createdTabs.count, 1)
        let discoveryID = try XCTUnwrap(fixture.createdTabs.last)
        XCTAssertNil(fixture.browser.webView(for: discoveryID), "The prompt-free recovery view is still safely disposed")
        do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"]); XCTFail("The newer checkpoint must keep admission closed") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        XCTAssertEqual(fixture.createdTabs.count, 1)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testProviderGateOldInflightPrepareCannotRelatchAfterExplicitRecovery() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
        defer { fixture.shutdown() }
        let peer = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let peerToken = try XCTUnwrap(peer["sessionToken"] as? String)
        let peerView = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: peerToken)
        fixture.initialURL = URL(string: "https://google.com/sorry/")
        let challenged = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let challengedToken = try XCTUnwrap(challenged["sessionToken"] as? String)
        try await waitForFixture(XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last))))
        fixture.initialURL = nil
        var release: CheckedContinuation<Void, Never>?
        var held = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "prepare", !held else { return }
            held = true
            await withCheckedContinuation { release = $0 }
        }
        defer { release?.resume(); fixture.transport.setBeforePageResultValidationForTesting(nil) }
        let pendingSend = Task { @MainActor in
            do {
                _ = try await self.call(fixture.transport, "webProviderSend", ["sessionToken": peerToken, "prompt": "The old pending read must never insert"])
                return false
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini))
                return true
            }
        }
        let holdDeadline = ContinuousClock.now + .seconds(5)
        while release == nil, ContinuousClock.now < holdDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(release)
        do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": challengedToken]); XCTFail("Expected the new provider checkpoint") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        _ = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true)
        XCTAssertFalse(fixture.browser.savedHumanVerificationProviders.contains("gemini"))
        release?.resume(); release = nil
        let rejected = await pendingSend.value
        XCTAssertTrue(rejected)
        XCTAssertFalse(fixture.browser.savedHumanVerificationProviders.contains("gemini"), "An old in-flight rejection cannot undo a successful later recovery")
        try await assertChoiceLedger(peerView, insertions: 0, sends: 0, selections: 0)
        let fresh = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let freshToken = try XCTUnwrap(fresh["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: freshToken)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": freshToken])
    }

    func testFailedRecoveryKeepsGateAndCreatesOnlyOneReadOnlyProbe() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"))
        defer { fixture.shutdown() }
        for retry in [false, false, true, false] {
            do { _ = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: retry); XCTFail("Expected checkpoint") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            try await assertHumanTabIntact(fixture)
        }
        XCTAssertEqual(fixture.createdTabs.count, 2, "Only first discovery and one explicit recovery may navigate")
        do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"]); XCTFail("Failed recovery must retain gate") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        XCTAssertEqual(fixture.createdTabs.count, 2)
    }

    func testProviderGateArrivingDuringPrepareStopsInsertionButAllowsOwnedCleanup() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"))
        defer { fixture.shutdown() }
        let blocked = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let blockedToken = try XCTUnwrap(blocked["sessionToken"] as? String)
        let blockedID = try XCTUnwrap(fixture.createdTabs.last)
        try await waitForFixture(XCTUnwrap(fixture.browser.webView(for: blockedID)))
        fixture.initialURL = nil
        let healthy = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let healthyToken = try XCTUnwrap(healthy["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: healthyToken)
        var observedGate = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "prepare", !observedGate else { return }
            observedGate = true
            do { _ = try await self.call(fixture.transport, "webProviderPoll", ["sessionToken": blockedToken]); XCTFail("Expected checkpoint") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        }
        do { _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": healthyToken, "prompt": "Do not insert after a profile gate"]); XCTFail("Expected provider gate") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        XCTAssertTrue(observedGate)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": healthyToken])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created", "The provider gate must not prevent exact owned cleanup")
        try await assertHumanTabIntact(fixture, retaining: blockedID)
    }

    func testProviderGateWakesQuietPeerAndOldPeerCannotInvalidateRecovery() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"))
        defer { fixture.shutdown() }
        let blocked = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let blockedToken = try XCTUnwrap(blocked["sessionToken"] as? String)
        try await waitForFixture(XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last))))
        fixture.initialURL = nil
        let peer = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let peerToken = try XCTUnwrap(peer["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: peerToken)
        var waiting = false
        let waiter = Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(3)
            waiting = true
            do {
                while ContinuousClock.now < deadline {
                    let observedRevision = try await fixture.transport.changeRevision(sessionToken: peerToken)
                    let revision = try XCTUnwrap(observedRevision)
                    _ = try await fixture.transport.waitForChange(sessionToken: peerToken, after: revision, until: deadline)
                }
                return false
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini))
                return true
            }
        }
        for _ in 0..<1_000 where !waiting { await Task.yield() }
        XCTAssertTrue(waiting)
        let began = ContinuousClock.now
        do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": blockedToken]); XCTFail("Expected checkpoint") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        let wokeForGate = await waiter.value
        XCTAssertTrue(wokeForGate)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(1), "Native provider changes must wake quiet peer waits immediately")

        var polledPeerDuringRecovery = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "discoverModels", !polledPeerDuringRecovery else { return }
            polledPeerDuringRecovery = true
            do { _ = try await self.call(fixture.transport, "webProviderPoll", ["sessionToken": peerToken]); XCTFail("Peer must stay terminal") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        }
        _ = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true)
        XCTAssertTrue(polledPeerDuringRecovery)
        let recovered = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        XCTAssertNotNil(recovered["sessionToken"])
    }

    func testProviderGateFirstObservedDuringRecoveryIsReportedInsteadOfSuccess() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"))
        defer { fixture.shutdown() }
        let blocked = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(blocked["sessionToken"] as? String)
        let blockedID = try XCTUnwrap(fixture.createdTabs.last)
        try await waitForFixture(XCTUnwrap(fixture.browser.webView(for: blockedID)))
        fixture.initialURL = nil
        var observed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "discoverModels", !observed else { return }
            observed = true
            do { _ = try await self.call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Expected checkpoint") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        }
        do { _ = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true); XCTFail("A newer failure must be reported") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        XCTAssertTrue(observed)
        XCTAssertEqual(fixture.createdTabs.count, 2)
        try await assertHumanTabIntact(fixture, retaining: blockedID)
    }

    func testCheckpointAfterSubmissionRejectsResponseWithoutReplayOrCleanupOverclaim() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
        defer { fixture.shutdown() }
        print("Checkpoint submission fixture: phase=fixture_created")
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        print("Checkpoint submission fixture: phase=session_started")
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: token)
        print("Checkpoint submission fixture: phase=ready")
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Original single submission"])
        print("Checkpoint submission fixture: phase=submitted")
        let id = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: id))
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
        print("Checkpoint submission fixture: phase=ledger_verified")
        view.loadHTMLString(Self.modelChoicePage(.gemini).replacingOccurrences(of: "'initial'", with: "'checkpoint'"), baseURL: URL(string: "https://google.com/sorry/"))
        try await waitForFixture(view, generation: "checkpoint")
        print("Checkpoint submission fixture: phase=checkpoint_loaded")
        for _ in 0..<3 {
            do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Checkpoint text is not an AI response") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        }
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["state"] as? String, "failed")
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue((finished["text"] as? String ?? "").isEmpty)
        try await assertHumanTabIntact(fixture, retaining: id)
    }

    func testConcreteChoicesSelectExactlyOnceAndRetainProofAcrossTwoInferenceSends() async throws {
        for provider in Self.choiceProviders {
            let choice = Self.fixtureChoice(provider)
            let fixture = try Fixture(page: Self.modelChoicePage(provider))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            let generation = try XCTUnwrap(fixture.browser.documentGeneration(for: ownedID))
            let ready = try await waitForState("ready", fixture.transport, token: token)
            try assertChoiceEvidence(ready, choice: choice)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            for sequence in 1...2 {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Synthetic model choice inference \(sequence)"])
                XCTAssertEqual(sent["state"] as? String, "running")
                try assertChoiceEvidence(sent, choice: choice)
                let complete = try await waitForState("complete", fixture.transport, token: token)
                XCTAssertEqual(complete["sequence"] as? Int, sequence)
                XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
                try assertChoiceEvidence(complete, choice: choice)
                try await assertChoiceLedger(view, insertions: sequence, sends: sequence, selections: 1)
            }
            XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
            let prompts = try await capturedUserPrompts(view)
            XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) },
                ["Synthetic model choice inference 1", "Synthetic model choice inference 2"])
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testGenericChatGPTHeaderWithUnmountedPickerVerifiesTwoSendsWithoutSelfWakingOrReplayingSelection() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, genericHeader: true, unmountClosedMenu: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        let ready = try await waitForState("ready", fixture.transport, token: token)
        try assertChoiceEvidence(ready, choice: choice)
        XCTAssertEqual(try WebsiteModelEvidence.parse(ready["modelEvidence"], provider: "chatgpt", expected: choice).source,
            "checked_model_option")
        let generic = try await evaluate(view, "return document.getElementById('fixture-model-header').textContent;") as? String
        XCTAssertEqual(generic, "ChatGPT", "The closed trigger cannot supply a family identity")
        let initiallyUnmounted = try await evaluate(view, "return document.getElementById('fixture-model-menu') === null;") as? Bool
        XCTAssertEqual(initiallyUnmounted, true)

        for sequence in 1...2 {
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Generic-header inference \(sequence)"])
            XCTAssertEqual(sent["state"] as? String, "running")
            try assertChoiceEvidence(sent, choice: choice)
            if sequence == 2 {
                // Drain the genuine user/assistant append signals first. These
                // polls must actually remount/read/close the picker, but that
                // observation UI must not wake the native reader again.
                try await Task.sleep(for: .milliseconds(100))
                let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
                let revision = try XCTUnwrap(observedRevision)
                let triggerBefore = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
                for _ in 0..<3 {
                    let observed = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTAssertEqual(observed["state"] as? String, "running")
                    try assertChoiceEvidence(observed, choice: choice)
                    try await Task.sleep(for: .milliseconds(100))
                    let after = try await fixture.transport.changeRevision(sessionToken: token)
                    XCTAssertEqual(after, revision, "Read-only picker observations must not create a native DOM wake loop")
                    let closed = try await evaluate(view, "return document.getElementById('fixture-model-menu') === null;") as? Bool
                    XCTAssertEqual(closed, true)
                }
                let triggerAfter = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
                XCTAssertGreaterThan(try XCTUnwrap(triggerAfter), try XCTUnwrap(triggerBefore), "The polls must exercise actual portal reads")
            }
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(complete["sequence"] as? Int, sequence)
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
            try assertChoiceEvidence(complete, choice: choice)
            try await assertChoiceLedger(view, insertions: sequence, sends: sequence, selections: 1)
        }
        let escapes = try await evaluate(view, "return {attempts: window.fixtureModelEscapeEvents, closed: window.fixtureModelEscapeClosures};") as? [String: Int]
        XCTAssertGreaterThan(try XCTUnwrap(escapes?["attempts"]), 0, "Controlled ChatGPT picker reads must use its actual Escape close behavior")
        XCTAssertEqual(escapes?["attempts"], escapes?["closed"])

        // Change actual checked radios while the fresh-read suppression scope
        // is still active. Selection attributes must remain observable even
        // though the generic trigger text itself never changes family.
        try await Task.sleep(for: .milliseconds(50))
        let mounted = try await evaluate(view, """
            document.getElementById('fixture-model-trigger').click();
            const menu = document.getElementById('fixture-model-menu');
            return {connected: menu?.isConnected === true,
              checked: menu ? [...menu.querySelectorAll('[data-fixture-model][aria-checked="true"]')].map(node => node.dataset.fixtureModel) : []};
            """) as? [String: Any]
        XCTAssertEqual(mounted?["connected"] as? Bool, true, "The model attributes must belong to the observed document")
        XCTAssertEqual(mounted?["checked"] as? [String], [choice.label])
        // Let native delivery of the mount settle before measuring only the
        // subsequent checked-model mutation, still inside the 300 ms read scope.
        try await Task.sleep(for: .milliseconds(100))
        let suppressionActive = try await evaluate(view, "return globalThis.__computaModelReadUI?.until > Date.now();",
            world: .world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(suppressionActive, true)
        let observedBeforeDrift = try await fixture.transport.changeRevision(sessionToken: token)
        let beforeDrift = try XCTUnwrap(observedBeforeDrift)
        let changed = try await evaluate(view, """
            const menu = document.getElementById('fixture-model-menu');
            if (!menu?.isConnected) throw new Error('Expected connected controlled model menu');
            menu.querySelectorAll('[data-fixture-model]').forEach(node => node.setAttribute('aria-checked', String(node.dataset.fixtureModel === window.fixtureModelInitialLabel)));
            return {connected: menu.isConnected,
              checked: [...menu.querySelectorAll('[data-fixture-model][aria-checked="true"]')].map(node => node.dataset.fixtureModel)};
            """) as? [String: Any]
        XCTAssertEqual(changed?["connected"] as? Bool, true)
        XCTAssertEqual(changed?["checked"] as? [String], [Self.choiceLabels(.chatgpt)[1]])
        let woke = try await fixture.transport.waitForChange(sessionToken: token, after: beforeDrift, until: .now + .seconds(2))
        XCTAssertGreaterThan(try XCTUnwrap(woke), beforeDrift, "An aria-checked model change must wake the native reader")
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not replay selection or submit after drift"])
            XCTFail("A freshly read checked-family mismatch must reject another send")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testIgnoredChatGPTPickerEscapeCannotClaimReadyOrInsertSendAndStillClosesOwnedFreshTab() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, initiallySelectTarget: true,
            genericHeader: true, unmountClosedMenu: true, ignoreModelEscape: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        do {
            _ = try await waitForState("ready", fixture.transport, token: token)
            XCTFail("Checked model evidence is insufficient when its controlled popup cannot acknowledge Escape close")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnverified) }
        let popup = try await evaluate(view, """
            return {connected: document.getElementById('fixture-model-menu')?.isConnected === true,
              expanded: document.getElementById('fixture-model-trigger').getAttribute('aria-expanded') === 'true',
              attempts: window.fixtureModelEscapeEvents, closed: window.fixtureModelEscapeClosures};
            """) as? [String: Any]
        XCTAssertEqual(popup?["connected"] as? Bool, true)
        XCTAssertEqual(popup?["expanded"] as? Bool, true)
        XCTAssertEqual(popup?["attempts"] as? Int, 1, "An unacknowledged close must not replay Escape")
        XCTAssertEqual(popup?["closed"] as? Int, 0)
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not send through an unacknowledged model picker"])
            XCTFail("An unverified picker close cannot admit a prompt")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTClosingTransitionRecoversOneConsumedFreshOpeningWithoutFramesOrSendReplay() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let previousKeyWindow = NSApplication.shared.keyWindow
        let fixture = try Fixture(page: Self.familyClosingTransitionPage())
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        XCTAssertTrue(view.window === fixture.renderWindow)
        XCTAssertTrue(view.superview === fixture.renderHost)
        XCTAssertFalse(fixture.renderWindow.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        // Covered/minimized WebKit pages may not deliver render callbacks.
        // Actual DOM closure and current checked proof must suffice; paused
        // animation callbacks cannot become proof or trigger another Send.
        _ = try await evaluate(view, """
            window.fixturePausedFrameRequests = 0;
            window.requestAnimationFrame = callback => { window.fixturePausedFrameRequests++; return 1; };
            window.cancelAnimationFrame = frame => {};
            return true;
            """, world: .world(name: "computa-chatgpt-model-v1"))
        let ready = try await waitForState("ready", fixture.transport, token: token)
        try assertChoiceEvidence(ready, choice: choice)
        XCTAssertEqual(try WebsiteModelEvidence.parse(ready["modelEvidence"], provider: "chatgpt", expected: choice).source,
            "checked_model_option")
        let recovery = try await evaluate(view, """
            return {ignored: window.fixtureModelIgnoredClosingOpens,
              freshOpens: window.fixtureFirstPostFamilyOpenAttempts,
              closingCompletions: window.fixtureModelClosingCompletions,
              proofClosed: window.fixtureFirstPostFamilyReadClosed};
            """) as? [String: Any]
        XCTAssertEqual(recovery?["ignored"] as? Int, 1, "The closing transition must consume the original fresh opening")
        XCTAssertEqual(recovery?["freshOpens"] as? Int, 2, "Exactly one additional opening recovers actual checked proof")
        XCTAssertEqual(recovery?["closingCompletions"] as? Int, 1)
        XCTAssertEqual(recovery?["proofClosed"] as? Bool, true, "The associated proof popup must close before admission")
        let claims = try await evaluate(view, """
            return {recovery: globalThis.__computaModelSelection?.openingRecoveryAttempted === true,
              completed: globalThis.__computaModelSelection?.completed === true};
            """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Bool]
        XCTAssertEqual(claims, ["recovery": true, "completed": true], "The single recovery allowance must be claimed before checked proof is admitted")
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
        var firstFingerprint: String?
        for sequence in 1...2 {
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": sequence == 1 ? "Read the local terminal fixture" : #"{"type":"tool_results","results":[{"name":"exec_command","output":"fixture output"}]}"#])
            try assertChoiceEvidence(sent, choice: choice)
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(complete["sequence"] as? Int, sequence)
            XCTAssertEqual(complete["text"] as? String, sequence == 1 ? Self.fixtureToolReply : #"{"type":"message","text":"Fixture reply"}"#)
            try assertChoiceEvidence(complete, choice: choice)
            let context = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            let fingerprint = try XCTUnwrap(context["firstUserFingerprint"] as? String)
            XCTAssertEqual(fingerprint.count, 64)
            if sequence == 1 { firstFingerprint = fingerprint } else { XCTAssertEqual(fingerprint, firstFingerprint) }
            try await assertChoiceLedger(view, insertions: sequence, sends: sequence, selections: 1)
        }
        let pausedFrames = try await evaluate(view, "return window.fixturePausedFrameRequests;",
            world: .world(name: "computa-chatgpt-model-v1")) as? Int
        XCTAssertEqual(pausedFrames, 0, "Selection and inference must not require render callback delivery")
        let after = try await evaluate(view, "return {ignored: window.fixtureModelIgnoredClosingOpens, freshOpens: window.fixtureFirstPostFamilyOpenAttempts};") as? [String: Int]
        XCTAssertEqual(after, ["ignored": 1, "freshOpens": 2], "Continuation must not reopen the spent fresh-session recovery allowance")
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        XCTAssertFalse(fixture.renderWindow.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTFamilyReturningToParentClosesOnceBeforeFreshProofAndTwoSends() async throws {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "GPT-5.5", label: "GPT-5.5")
        let previousKeyWindow = NSApplication.shared.keyWindow
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, genericHeader: true,
            unmountClosedMenu: true, returnToParentAfterSelection: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        var observedReturnedParent = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "selectModel" else { return }
            let parent = try? await self.evaluate(view, """
                const menu = document.getElementById('fixture-model-menu');
                const checked = menu?.querySelector('[data-fixture-model][aria-checked="true"]');
                return {active: window.fixtureModelParentActive === true,
                  connected: menu?.isConnected === true, expanded: document.getElementById('fixture-model-trigger').getAttribute('aria-expanded') === 'true',
                  checked: checked?.dataset.fixtureModel ?? null, checkedHidden: checked?.hidden === true,
                  temporaryHidden: document.querySelector('[aria-label="Turn off temporary chat"]').getAttribute('aria-hidden') === 'true',
                  users: document.querySelectorAll('[data-message-author-role="user"]').length,
                  assistants: document.querySelectorAll('[data-message-author-role="assistant"]').length};
                """) as? [String: Any]
            if parent?["active"] as? Bool == true {
                observedReturnedParent = true
                XCTAssertEqual(parent?["connected"] as? Bool, true)
                XCTAssertEqual(parent?["expanded"] as? Bool, true)
                XCTAssertEqual(parent?["checked"] as? String, choice.label)
                XCTAssertEqual(parent?["checkedHidden"] as? Bool, true, "Hidden checked rows cannot prove the current model")
                XCTAssertEqual(parent?["temporaryHidden"] as? Bool, true, "The exact modal temporarily hides the mode controls")
                XCTAssertEqual(parent?["users"] as? Int, 0)
                XCTAssertEqual(parent?["assistants"] as? Int, 0)
            }
        }
        let ready = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertTrue(observedReturnedParent, "The actual family click must leave the associated parent popup open")
        try assertChoiceEvidence(ready, choice: choice)
        XCTAssertEqual(try WebsiteModelEvidence.parse(ready["modelEvidence"], provider: "chatgpt", expected: choice).source,
            "checked_model_option")
        let settled = try await evaluate(view, """
            return {returns: window.fixtureModelParentReturns, attempts: window.fixtureModelParentEscapeEvents,
              closed: window.fixtureModelParentEscapeClosures, freshReads: window.fixtureModelFreshProofReadOpens,
              menuAbsent: document.getElementById('fixture-model-menu') === null,
              temporaryVisible: document.querySelector('[aria-label="Turn off temporary chat"]').getAttribute('aria-hidden') !== 'true'};
            """) as? [String: Any]
        XCTAssertEqual(settled?["returns"] as? Int, 1)
        XCTAssertEqual(settled?["attempts"] as? Int, 1, "Only one Escape may dismiss the returned owned parent")
        XCTAssertEqual(settled?["closed"] as? Int, 1)
        XCTAssertGreaterThan(try XCTUnwrap(settled?["freshReads"] as? Int), 0, "Admission needs freshly visible checked rows after parent closure")
        XCTAssertEqual(settled?["menuAbsent"] as? Bool, true)
        XCTAssertEqual(settled?["temporaryVisible"] as? Bool, true)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
        var firstFingerprint: String?
        for sequence in 1...2 {
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "Parent-return inference \(sequence)"])
            try assertChoiceEvidence(sent, choice: choice)
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(complete["sequence"] as? Int, sequence)
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
            try assertChoiceEvidence(complete, choice: choice)
            let context = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            let fingerprint = try XCTUnwrap(context["firstUserFingerprint"] as? String)
            XCTAssertEqual(fingerprint.count, 64)
            if sequence == 1 { firstFingerprint = fingerprint } else { XCTAssertEqual(fingerprint, firstFingerprint) }
            try await assertChoiceLedger(view, insertions: sequence, sends: sequence, selections: 1)
        }
        let parentEscapes = try await evaluate(view, "return {attempts: window.fixtureModelParentEscapeEvents, closed: window.fixtureModelParentEscapeClosures};") as? [String: Int]
        XCTAssertEqual(parentEscapes, ["attempts": 1, "closed": 1], "Later model reads cannot replay the spent parent-close action")
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        XCTAssertFalse(fixture.renderWindow.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTParentModeDriftBeforeCloseCannotClaimReadyOrInsertSend() async throws {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "GPT-5.5", label: "GPT-5.5")
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, genericHeader: true,
            unmountClosedMenu: true, returnToParentAfterSelection: true, driftTemporaryInParent: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        do {
            _ = try await waitForState("ready", fixture.transport, token: token)
            XCTFail("A closed parent cannot admit readiness when its restored actual temporary proof changed")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnverified) }
        let closed = try await evaluate(view, """
            return {drifted: window.fixtureModelTemporaryDrifted === true,
              attempts: window.fixtureModelParentEscapeEvents, closed: window.fixtureModelParentEscapeClosures,
              freshReads: window.fixtureModelFreshProofReadOpens,
              menuAbsent: document.getElementById('fixture-model-menu') === null,
              oldTemporaryProof: !!document.querySelector('[aria-label="Turn off temporary chat"]'),
              actualMode: document.querySelector('[aria-label="Start temporary chat"]')?.textContent ?? null};
            """) as? [String: Any]
        XCTAssertEqual(closed?["drifted"] as? Bool, true)
        XCTAssertEqual(closed?["attempts"] as? Int, 1)
        XCTAssertEqual(closed?["closed"] as? Int, 1, "The one claimed Escape must actually acknowledge closure")
        XCTAssertEqual(closed?["freshReads"] as? Int, 0, "Invalid restored mode cannot authorize another picker opening")
        XCTAssertEqual(closed?["menuAbsent"] as? Bool, true)
        XCTAssertEqual(closed?["oldTemporaryProof"] as? Bool, false)
        XCTAssertEqual(closed?["actualMode"] as? String, "Start temporary chat")
        let claim = try await evaluate(view, "return globalThis.__computaModelSelection?.selectionCloseAttempted === true;",
            world: .world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(claim, true)
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not send after mode drift"])
            XCTFail("Unverified mode cannot admit insertion or Send")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTParentModalHidingComposerAdvancesOnlyThroughOwnedCloseAndFreshAdmission() async throws {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "GPT-5.5", label: "GPT-5.5")
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, genericHeader: true,
            unmountClosedMenu: true, returnToParentAfterSelection: true, hideComposerInPicker: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        var observedHiddenComposer = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "selectModel" else { return }
            let modal = try? await self.evaluate(view, """
                return {parent: window.fixtureModelParentActive === true,
                  composerHidden: document.getElementById('fixture-editor').closest('[aria-hidden="true"]') != null,
                  temporaryHidden: document.querySelector('[aria-label="Turn off temporary chat"]').getAttribute('aria-hidden') === 'true',
                  inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};
                """) as? [String: Any]
            if modal?["parent"] as? Bool == true {
                observedHiddenComposer = true
                XCTAssertEqual(modal?["composerHidden"] as? Bool, true)
                XCTAssertEqual(modal?["temporaryHidden"] as? Bool, true)
                XCTAssertEqual(modal?["inputs"] as? Int, 0)
                XCTAssertEqual(modal?["sends"] as? Int, 0)
            }
        }
        let ready = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertTrue(observedHiddenComposer, "The pending owned selection must really cross an unavailable composer observation")
        try assertChoiceEvidence(ready, choice: choice)
        let restored = try await evaluate(view, """
            const editor = document.getElementById('fixture-editor');
            return {composerVisible: editor.isConnected && editor.getClientRects().length > 0
                && !editor.closest('[aria-hidden="true"]'),
              attempts: window.fixtureModelParentEscapeEvents, closed: window.fixtureModelParentEscapeClosures,
              menuAbsent: document.getElementById('fixture-model-menu') === null};
            """) as? [String: Any]
        XCTAssertEqual(restored?["composerVisible"] as? Bool, true)
        XCTAssertEqual(restored?["attempts"] as? Int, 1)
        XCTAssertEqual(restored?["closed"] as? Int, 1)
        XCTAssertEqual(restored?["menuAbsent"] as? Bool, true)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Use the restored composer after exact parent closure"])
        try assertChoiceEvidence(sent, choice: choice)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["sequence"] as? Int, 1)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        try assertChoiceEvidence(complete, choice: choice)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testAcknowledgedDelayedUserAppendDuringModelPickerReadRetainsChoiceAcrossToolContinuation() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        _ = try await waitForState("ready", fixture.transport, token: token)
        var acknowledgements = 0
        var readActionsAfterLatestAcknowledgement: [String] = []
        fixture.transport.setBeforePageResultValidationDetailedForTesting { action, enforceModel in
            if action == "submit" {
                let claim = try? await self.evaluate(view,
                    "return {claimed: globalThis.__computaModelLastSubmissionCount, submitted: globalThis.__computaModelFirstSubmitted};",
                    world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
                XCTAssertEqual(claim?["claimed"] as? Int, acknowledgements)
                XCTAssertEqual(claim?["submitted"] as? Bool, true)
                let pending = try? await self.evaluate(view,
                    "window.fixtureRaceArmed = true; return {users: document.querySelectorAll('[data-message-author-role=\"user\"]').length, pending: !!window.fixturePendingUser};") as? [String: Any]
                XCTAssertEqual(pending?["users"] as? Int, acknowledgements, "The acknowledged Send has not rendered yet")
                XCTAssertEqual(pending?["pending"] as? Bool, true)
                acknowledgements += 1
                readActionsAfterLatestAcknowledgement = []
            } else if acknowledgements > 0, enforceModel, ["inspect", "verifyModel"].contains(action) {
                readActionsAfterLatestAcknowledgement.append(action)
            }
        }
        defer { fixture.transport.setBeforePageResultValidationDetailedForTesting(nil) }
        let prompts = ["Read the fixture output with the terminal tool", #"{"type":"tool_results","results":[{"name":"exec_command","output":"fixture output"}]}"#]
        for sequence in 1...2 {
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompts[sequence - 1]])
            XCTAssertEqual(sent["state"] as? String, "running")
            try assertChoiceEvidence(sent, choice: choice)
            XCTAssertEqual(readActionsAfterLatestAcknowledgement.count, 2,
                "A crossed acknowledged append must discard its stale read and take exactly one fresh read")
            XCTAssertEqual(readActionsAfterLatestAcknowledgement.last, "inspect", "The retry must validate full owned lineage")
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(complete["sequence"] as? Int, sequence)
            XCTAssertEqual(complete["text"] as? String, sequence == 1 ? Self.fixtureToolReply : #"{"type":"message","text":"Fixture reply"}"#)
            try assertChoiceEvidence(complete, choice: choice)
            try await assertChoiceLedger(view, insertions: sequence, sends: sequence, selections: 1)
        }
        XCTAssertEqual(acknowledgements, 2)
        let race = try await evaluate(view, "return {opens: window.fixtureDelayedPickerOpens, renderedCounts: window.fixtureRaceRenderedCounts};") as? [String: Any]
        XCTAssertEqual(race?["opens"] as? Int, 2, "Both appends must cross asynchronous picker reads")
        XCTAssertEqual(race?["renderedCounts"] as? [Int], [1, 2])
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        let captured = try await capturedUserPrompts(view)
        XCTAssertEqual(captured?.map { $0.trimmingCharacters(in: .newlines) }, prompts)
        fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testAcknowledgedAppendCannotRefreshChangedFirstBodyOrWrongMarkerDuringPickerRead() async throws {
        for corruption in ["changed_body", "wrong_marker"] {
            let choice = Self.fixtureChoice(.chatgpt)
            let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "submit" else { return }
                _ = try? await self.evaluate(view, "window.fixtureRaceArmed = true; return true;")
            }
            defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Pin the original first message"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            let pinned = try await evaluate(view, "return globalThis.__computaModelFirstProof?.fingerprint;",
                world: .world(name: "computa-chatgpt-model-v1")) as? String
            XCTAssertEqual(pinned?.count, 64)
            _ = try await evaluate(view, "window.fixtureRaceCorruption = '\(corruption)'; return true;")
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "This continuation crosses corrupted lineage"])
                XCTFail("A model read must reject \(corruption), even when the new user count matches an acknowledged Send")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
            let race = try await evaluate(view, "return {opens: window.fixtureDelayedPickerOpens, renderedCounts: window.fixtureRaceRenderedCounts};") as? [String: Any]
            XCTAssertEqual(race?["opens"] as? Int, 2)
            XCTAssertEqual(race?["renderedCounts"] as? [Int], [1, 2])
            try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not replay the failed continuation"])
                XCTFail("A pending failed continuation cannot admit another Send")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
            try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed", "Corrupted first-message lineage cannot authorize deletion")
            XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
            XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        }
    }

    func testChatGPTConversationRouteCreatedDuringAwaitedModelReadRetainsChoiceWithoutReplayingSend() async throws {
        for firstRoute in ["/c/local-chatgpt%3Amodel-choice-race?temporary-chat=true", "/c/direct-model-choice-race?temporary-chat=true"] {
            let choice = Self.fixtureChoice(.chatgpt)
            let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let routes = firstRoute.contains("local-chatgpt") ? [firstRoute, "/c/promoted-model-choice-race?temporary-chat=true"] : [firstRoute]
            let routeData = try JSONSerialization.data(withJSONObject: routes)
            let routeJSON = String(decoding: routeData, as: UTF8.self)
            _ = try await evaluate(view, "window.fixtureRaceRoutes = \(routeJSON); return true;")
            var acknowledgedSends = 0
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "submit" else { return }
                acknowledgedSends += 1
                let armed = try? await self.evaluate(view, "window.fixtureRaceArmed = true; return !!window.fixturePendingUser;") as? Bool
                XCTAssertEqual(armed, true, "Only actual acknowledged Send DOM may create the conversation route")
            }
            defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
            var firstFingerprint: String?
            for sequence in 1...2 {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": sequence == 1 ? "Create an owned conversation with a delayed route" : #"{"type":"tool_results","results":[{"name":"exec_command","output":"fixture output"}]}"#])
                XCTAssertEqual(sent["state"] as? String, "running")
                try assertChoiceEvidence(sent, choice: choice)
                let complete = try await waitForState("complete", fixture.transport, token: token)
                XCTAssertEqual(complete["sequence"] as? Int, sequence)
                XCTAssertEqual(complete["text"] as? String, sequence == 1 ? Self.fixtureToolReply : #"{"type":"message","text":"Fixture reply"}"#)
                try assertChoiceEvidence(complete, choice: choice)
                let context = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
                let fingerprint = try XCTUnwrap(context["firstUserFingerprint"] as? String)
                XCTAssertEqual(fingerprint.count, 64)
                if sequence == 1 { firstFingerprint = fingerprint } else { XCTAssertEqual(fingerprint, firstFingerprint) }
                XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
                try await assertChoiceLedger(view, insertions: sequence, sends: sequence, selections: 1)
            }
            XCTAssertEqual(acknowledgedSends, 2)
            let observedRoutes = try await evaluate(view, "return window.fixtureRaceRenderedRoutes;") as? [String]
            XCTAssertEqual(observedRoutes, routes, "Both first-route creation and local promotion must occur inside picker awaits")
            let ownedURL = try XCTUnwrap(view.url?.absoluteString)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            _ = try await evaluate(view, "history.replaceState({}, '', '/c/unrelated-human-route?temporary-chat=true'); return true;")
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not adopt an unrelated public conversation"])
                XCTFail("Read-only first-route recovery cannot authorize another unrelated conversation")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.routeBefore)) }
            try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
            let retained = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(retained["cleanup"] as? String, "failed")
            XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
            let restoredData = try JSONSerialization.data(withJSONObject: [ownedURL])
            let restoredJSON = String(decoding: restoredData, as: UTF8.self)
            _ = try await evaluate(view, "history.replaceState({}, '', \(restoredJSON)[0]); return true;")
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created", "Only restoration of the already pinned route can recover exact cleanup")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTFirstSendRefreshesEmptyLocalAndPublicRoutesInOneUnboundInspectionChain() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.firstSendRoutePromotionPage())
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let routes = ["/c/local-chatgpt%3Aunbound-first-read?temporary-chat=true",
                      "/c/public-unbound-first-read?temporary-chat=true"]
        var acknowledgedSends = 0
        var firstSendReturned = false
        var firstSendInspectionLocalRoutes: [Bool] = []
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "submit" { acknowledgedSends += 1 }
            guard action == "inspect", acknowledgedSends == 1, !firstSendReturned else { return }
            firstSendInspectionLocalRoutes.append(EmbeddedWebModelTransport.Provider.chatgpt.isLocalConversation(view.url?.absoluteString))
            let index = firstSendInspectionLocalRoutes.count - 1
            guard index < routes.count else { return }
            // This checkpoint precedes every native result/first-message bind.
            // Both edges therefore cross the same recursive first inspection,
            // rather than two later polls after a route has been admitted.
            let changed = try? await self.evaluate(view, """
                if (window.fixturePrompts.length !== 1 || window.fixtureInputCount !== 1
                  || document.querySelectorAll('[data-message-author-role="user"]').length !== 1) return false;
                history.pushState({}, '', '\(routes[index])'); return true;
                """) as? Bool
            XCTAssertEqual(changed, true, "Only the single acknowledged first Send can create either owned route edge")
        }
        defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
        let firstSent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "First local-to-public promotion before native lineage binding"])
        firstSendReturned = true
        XCTAssertEqual(firstSent["state"] as? String, "running")
        XCTAssertEqual(acknowledgedSends, 1)
        XCTAssertEqual(firstSendInspectionLocalRoutes, [false, true, false],
            "Empty, local and public reads must all occur before the first Send returns")
        try assertChoiceEvidence(firstSent, choice: choice)
        let firstContext = try XCTUnwrap(firstSent["modelProofContext"] as? [String: Any])
        let firstFingerprint = try XCTUnwrap(firstContext["firstUserFingerprint"] as? String)
        XCTAssertEqual(firstFingerprint.count, 64)
        XCTAssertEqual(view.url?.path, "/c/public-unbound-first-read")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let firstComplete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(firstComplete["text"] as? String, Self.fixtureToolReply)
        let secondSent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": #"{"type":"tool_results","results":[{"name":"exec_command","output":"fixture output"}]}"#])
        try assertChoiceEvidence(secondSent, choice: choice)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["sequence"] as? Int, 2)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        try assertChoiceEvidence(complete, choice: choice)
        let finalContext = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual(finalContext["firstUserFingerprint"] as? String, firstFingerprint)
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        let ownedURL = try XCTUnwrap(view.url?.absoluteString)
        _ = try await evaluate(view, "history.replaceState({}, '', '/c/foreign-after-pinned-public?temporary-chat=true'); return true;")
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Do not continue in a foreign public conversation"])
            XCTFail("The two-edge first-route refresh must not permit another public conversation")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.routeBefore)) }
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        _ = try await evaluate(view, "history.replaceState({}, '', '\(ownedURL)'); return true;")
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTFirstUnboundRouteRefreshRejectsSecondLocalOrThirdPublicConversationWithoutSendReplay() async throws {
        let scenarios = [
            ["/c/local-chatgpt%3Aunbound-route-one?temporary-chat=true",
             "/c/local-chatgpt%3Aunbound-route-two?temporary-chat=true"],
            ["/c/local-chatgpt%3Aunbound-route-one?temporary-chat=true",
             "/c/public-unbound-route-one?temporary-chat=true",
             "/c/foreign-unbound-route-two?temporary-chat=true"]
        ]
        for routes in scenarios {
            let choice = Self.fixtureChoice(.chatgpt)
            let fixture = try Fixture(page: Self.firstSendRoutePromotionPage())
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            var acknowledgedSends = 0, firstSendInspections = 0
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "submit" { acknowledgedSends += 1 }
                guard action == "inspect", acknowledgedSends == 1 else { return }
                let index = firstSendInspections
                firstSendInspections += 1
                guard index < routes.count else { return }
                let changed = try? await self.evaluate(view, """
                    if (window.fixturePrompts.length !== 1 || window.fixtureInputCount !== 1
                      || document.querySelectorAll('[data-message-author-role="user"]').length !== 1) return false;
                    history.pushState({}, '', '\(routes[index])'); return true;
                    """) as? Bool
                XCTAssertEqual(changed, true)
            }
            defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "One acknowledged Send cannot acquire unrelated local or public routes"])
                XCTFail("A second local or third public route cannot be admitted while the first result is still unbound")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.routeAfter)) }
            XCTAssertEqual(acknowledgedSends, 1)
            XCTAssertEqual(firstSendInspections, routes.count, "The invalid edge must stop the recursive refresh immediately")
            XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Do not replay the uncertain first Send"])
                XCTFail("A failed first-route admission cannot authorize another Send")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
            XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        }
    }

    func testRepeatedAcknowledgedAppendSignalStopsAfterOneFreshInspectWithoutReplayingSend() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        var acknowledged = false, rearmed = false
        var readonlyInspections = 0
        fixture.transport.setBeforePageResultValidationDetailedForTesting { action, enforceModel in
            if action == "submit" {
                acknowledged = true
                _ = try? await self.evaluate(view, "window.fixtureRaceArmed = true; return true;")
            } else if action == "inspect", acknowledged, enforceModel {
                readonlyInspections += 1
                guard !rearmed else { return }
                rearmed = true
                let removed = try? await self.evaluate(view, """
                    const user = document.querySelector('[data-message-author-role="user"]');
                    const turn = document.querySelector('[data-markdown-text-style="assistant-message"]')?.closest('section');
                    if (!user || !turn || window.fixtureDelayedPickerOpens !== 1) return false;
                    user.remove(); turn.remove();
                    window.fixturePendingUser = user; window.fixturePendingTurn = turn; window.fixtureRaceArmed = true;
                    return true;
                    """) as? Bool
                XCTAssertEqual(removed, true, "Only the already acknowledged first append is re-rendered across the fresh read")
            }
        }
        defer { fixture.transport.setBeforePageResultValidationDetailedForTesting(nil) }
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "A single Send with a repeatedly flapping render"])
            XCTFail("A second stale append signal must not start an unbounded read retry")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptUserCount)) }
        XCTAssertTrue(rearmed)
        XCTAssertEqual(readonlyInspections, 2, "Only the original inspect and its one fresh retry may run")
        let race = try await evaluate(view, "return {opens: window.fixtureDelayedPickerOpens, renderedCounts: window.fixtureRaceRenderedCounts};") as? [String: Any]
        XCTAssertEqual(race?["opens"] as? Int, 2)
        XCTAssertEqual(race?["renderedCounts"] as? [Int], [1, 1])
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created", "The current exact owned DOM can still authorize cleanup independently")
        try await assertHumanTabIntact(fixture)
    }

    func testGeminiFirstUserReplacementDuringPickerReadPreservesPinnedLineageThroughToolContinuation() async throws {
        let choice = Self.fixtureChoice(.gemini)
        let fixture = try Fixture(page: Self.firstUserReplacementRacePage(.gemini))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let firstSend = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Original first prompt for terminal fixture output"])
        let firstContext = try XCTUnwrap(firstSend["modelProofContext"] as? [String: Any])
        let fingerprint = try XCTUnwrap(firstContext["firstUserFingerprint"] as? String)
        XCTAssertEqual(fingerprint.count, 64)
        let armed = try await evaluate(view, "window.fixtureFirstReplacementArmed = true; document.getElementById('fixture-model-trigger').click(); return document.getElementById('fixture-model-menu')?.isConnected === true;") as? Bool
        XCTAssertEqual(armed, true)
        var refreshInspections = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect" { refreshInspections += 1 }
        }
        let refreshed = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertEqual(refreshed["state"] as? String, "running")
        XCTAssertEqual(refreshInspections, 2, "An exact disconnected first-root replacement must discard once and inspect the current page")
        try assertChoiceEvidence(refreshed, choice: choice)
        let replacement = try await evaluate(view, "return {count: window.fixtureFirstReplacementCount, oldRootDisconnected: window.fixtureOldRootDisconnected, oldBodyDisconnected: window.fixtureOldBodyDisconnected, currentCount: document.querySelectorAll('user-query').length};") as? [String: Any]
        XCTAssertEqual(replacement?["count"] as? Int, 1)
        XCTAssertEqual(replacement?["oldRootDisconnected"] as? Bool, true)
        XCTAssertEqual(replacement?["oldBodyDisconnected"] as? Bool, true)
        XCTAssertEqual(replacement?["currentCount"] as? Int, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let first = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(first["text"] as? String, Self.fixtureToolReply)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": #"{"type":"tool_results","results":[{"name":"exec_command","output":"fixture output"}]}"#])
        try assertChoiceEvidence(sent, choice: choice)
        let final = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(final["sequence"] as? Int, 2)
        XCTAssertEqual(final["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        try assertChoiceEvidence(final, choice: choice)
        let finalContext = try XCTUnwrap(final["modelProofContext"] as? [String: Any])
        XCTAssertEqual(finalContext["firstUserFingerprint"] as? String, fingerprint)
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testFirstUserReplacementCannotRefreshChangedTextMarkerOrProviderIdentity() async throws {
        let scenarios: [(EmbeddedWebModelTransport.Provider, String)] = [(.gemini, "changed_text"), (.gemini, "wrong_marker"), (.claude, "changed_identity")]
        for (provider, corruption) in scenarios {
            func recordPhase(_ phase: String) {
                FileHandle.standardError.write(Data("First-user replacement fixture: provider=\(provider.rawValue) corruption=\(corruption) phase=\(phase)\n".utf8))
            }
            recordPhase("start")
            let choice = Self.fixtureChoice(provider)
            let fixture = try Fixture(page: Self.firstUserReplacementRacePage(provider))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            recordPhase("ready")
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Original first prompt with exact provider lineage"])
            recordPhase("sent")
            _ = try await evaluate(view, "window.fixtureFirstReplacementCorruption = '\(corruption)'; window.fixtureFirstReplacementArmed = true; document.getElementById('fixture-model-trigger').click(); return true;")
            recordPhase("armed")
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A disconnected replacement cannot refresh \(corruption)")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
            recordPhase("poll_rejected")
            let replacements = try await evaluate(view, "return window.fixtureFirstReplacementCount;") as? Int
            XCTAssertEqual(replacements, 1)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not continue changed first-message lineage"])
                XCTFail("Changed first lineage cannot authorize a continuation Send")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            recordPhase("continuation_rejected")
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
            recordPhase("finished")
        }
    }

    func testRepeatedFirstUserReplacementStopsAfterOneFreshInspectWithoutReplayingSend() async throws {
        let choice = Self.fixtureChoice(.gemini)
        let fixture = try Fixture(page: Self.firstUserReplacementRacePage(.gemini))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Original first prompt in a repeatedly replaced DOM"])
        _ = try await evaluate(view, "window.fixtureFirstReplacementArmed = true; document.getElementById('fixture-model-trigger').click(); return true;")
        var inspections = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect" else { return }
            inspections += 1
            if inspections == 1 {
                let rearmed = try? await self.evaluate(view, "window.fixtureFirstReplacementArmed = true; document.getElementById('fixture-model-trigger').click(); return window.fixtureFirstReplacementCount === 1 && document.getElementById('fixture-model-menu')?.isConnected === true;") as? Bool
                XCTAssertEqual(rearmed, true, "The same read-only replacement race repeats only inside the native fresh inspect")
            }
        }
        defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A second replacement discard signal cannot reset the shared fresh-read budget")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
        XCTAssertEqual(inspections, 2)
        let replacements = try await evaluate(view, "return window.fixtureFirstReplacementCount;") as? Int
        XCTAssertEqual(replacements, 2)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created", "The final exact owned payload can still authorize independent cleanup")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTProductReadCannotResetConsumedFirstUserReplacementBudget() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, initiallySelectTarget: true, unmountClosedMenu: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Keep the exact first prompt through two disconnected DOM replacements"])
        let context = try XCTUnwrap(sent["modelProofContext"] as? [String: Any])
        XCTAssertEqual((context["firstUserFingerprint"] as? String)?.count, 64)
        let privateWorld = WKContentWorld.world(name: "computa-chatgpt-model-v1")
        _ = try await evaluate(view, """
            const original = crypto.subtle.digest.bind(crypto.subtle);
            globalThis.__fixtureReplaceNextDigest = true;
            globalThis.__fixtureRootReplacementCount = 0;
            crypto.subtle.digest = async (...args) => {
              const digest = await original(...args);
              if (globalThis.__fixtureReplaceNextDigest) {
                globalThis.__fixtureReplaceNextDigest = false;
                const root = document.querySelector('[data-message-author-role="user"]');
                if (!root) throw new Error('Expected pinned first-message root');
                root.replaceWith(root.cloneNode(true));
                globalThis.__fixtureRootReplacementCount++;
              }
              return digest;
            };
            return true;
            """, world: privateWorld)
        var modelInspections = 0, productReads = 0
        fixture.transport.setBeforePageResultValidationDetailedForTesting { action, enforceModel in
            if action == "inspect", enforceModel {
                modelInspections += 1
                if modelInspections == 2 {
                    _ = try? await self.evaluate(view, "globalThis.__fixtureReplaceNextDigest = true; return true;", world: privateWorld)
                }
            } else if action == "verifyProductMode" {
                productReads += 1
            }
        }
        defer { fixture.transport.setBeforePageResultValidationDetailedForTesting(nil) }
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A product-only re-read cannot renew the consumed first-message refresh budget")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
        XCTAssertEqual(modelInspections, 2, "Only the original read and its one fresh inspect may run")
        XCTAssertEqual(productReads, 1, "The product read must reject its second replacement without recursively inspecting")
        let replacements = try await evaluate(view, "return globalThis.__fixtureRootReplacementCount;", world: privateWorld) as? Int
        XCTAssertEqual(replacements, 2, "Both exact-body replacements must occur during real digest awaits")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
        fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created", "The current exact payload can independently authorize cleanup")
        try await assertHumanTabIntact(fixture)
    }

    func testUnacknowledgedUserAppendDuringModelReadCannotAdmitAnotherInsertionOrSend() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "submit" else { return }
            _ = try? await self.evaluate(view, "window.fixtureRaceArmed = true; return true;")
        }
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "The one acknowledged message"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        _ = try await evaluate(view, """
            window.fixturePendingUser = document.querySelector('[data-message-author-role="user"]').cloneNode(true);
            window.fixturePendingTurn = document.querySelector('[data-markdown-text-style="assistant-message"]').closest('section').cloneNode(true);
            window.fixtureRaceArmed = true; return true;
            """)
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must reject a user append without a pending Send"])
            XCTFail("A retained private submit claim cannot admit an unsolicited user count increment")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptUserCount)) }
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let race = try await evaluate(view, "return {opens: window.fixtureDelayedPickerOpens, renderedCounts: window.fixtureRaceRenderedCounts};") as? [String: Any]
        XCTAssertEqual(race?["opens"] as? Int, 2)
        XCTAssertEqual(race?["renderedCounts"] as? [Int], [1, 2])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testUnavailableConcreteChoicesNeverInsertSendOrFallBackToWebsiteDefault() async throws {
        for provider in Self.choiceProviders {
            let choice = Self.fixtureChoice(provider)
            let fixture = try Fixture(page: Self.modelChoicePage(provider, disableTarget: true))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            do {
                _ = try await waitForState("ready", fixture.transport, token: token)
                XCTFail("An unavailable concrete choice cannot use the website default")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnavailable)
            }
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testConcreteModelDriftBeforeSendRejectsWithoutInsertionAndStillClosesOnlyOwnedFreshTab() async throws {
        for provider in Self.choiceProviders {
            let choice = Self.fixtureChoice(provider)
            let fixture = try Fixture(page: Self.modelChoicePage(provider))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await evaluate(view, "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;")
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not reach a substituted model"])
                XCTFail("A different selected model must reject before insertion")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created", "Model verification failure must not erase exact cleanup ownership")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testConcreteModelDriftBeforeResponseCannotPublishTextAndOwnedTemporaryCleanupRemainsPossible() async throws {
        for provider in Self.choiceProviders {
            let fixture = try Fixture(page: Self.modelChoicePage(provider))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(provider), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Reject a response after model drift"])
            _ = try await evaluate(view, "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;")
            do {
                let response = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A substituted model must not publish \(response)")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testInitialConcreteReadinessRejectsModelDriftAcrossNativeAwaitWithoutClaimingReady() async throws {
        let provider: EmbeddedWebModelTransport.Provider = .chatgpt
        let fixture = try Fixture(page: Self.modelChoicePage(provider, initiallySelectTarget: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(provider), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let id = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: id))
        try await waitForFixture(view)
        let generation = fixture.browser.documentGeneration(for: id)
        // Normal Chat is established before the temporary transition. This
        // first preparation result has not admitted any concrete model yet.
        let preparing = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(preparing["state"] as? String, "loading")
        let temporaryClaims = try await evaluate(view, "return window.fixtureTemporaryModeClicks;") as? Int
        XCTAssertEqual(temporaryClaims, 1)
        var changed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect", !changed else { return }
            changed = true
            _ = try? await self.evaluate(view, "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;")
        }
        do {
            let ready = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("An initial read cannot claim stale ready model proof: \(ready)")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
        XCTAssertTrue(changed)
        XCTAssertEqual(fixture.browser.documentGeneration(for: id), generation)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testConcreteSelectionAcknowledgmentRejectsModelDriftAcrossNativeAwait() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.claude, deferSelectionCommit: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.claude), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        var changed = false
        var committed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            // Keep the clicked choice pending until an inspect has captured the
            // previous header. Its native continuation must then invoke the
            // final selectModel acknowledgment instead of the header fast path.
            if action == "inspect", !committed,
               (try? await self.evaluate(view, "return window.fixturePendingModelSelection != null;")) as? Bool == true {
                committed = true
                _ = try? await self.evaluate(view, "window.fixtureModelSelect(window.fixturePendingModelSelection); window.fixturePendingModelSelection = null; return true;")
                return
            }
            guard action == "selectModel", !changed else { return }
            let acknowledged = (try? await self.evaluate(view, "return globalThis.__computaModelSelection?.completed === true;",
                world: .world(name: "computa-chatgpt-model-v1"))) as? Bool
            guard acknowledged == true else { return }
            changed = true
            _ = try? await self.evaluate(view, "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;")
        }
        do {
            _ = try await waitForState("ready", fixture.transport, token: token)
            XCTFail("Selection acknowledgment cannot accept an older model observation")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
        XCTAssertTrue(committed)
        XCTAssertTrue(changed)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testConcretePrepareAndResponseRevalidateModelsAfterNativeAwait() async throws {
        for action in ["prepare", "inspect"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.gemini), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            _ = try await waitForState("ready", fixture.transport, token: token)
            if action == "inspect" {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Reject stale response proof"])
            }
            let generation = fixture.browser.documentGeneration(for: id)
            var changed = false
            fixture.transport.setBeforePageResultValidationForTesting { observedAction in
                guard observedAction == action, !changed else { return }
                changed = true
                _ = try? await self.evaluate(view, "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;")
            }
            do {
                let operation = action == "prepare" ? "webProviderSend" : "webProviderPoll"
                var params = ["sessionToken": token]
                if action == "prepare" { params["prompt"] = "Must not insert after a stale prepare result" }
                let reply = try await call(fixture.transport, operation, params)
                XCTFail("An awaited \(action) cannot accept stale proof: \(reply)")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
            XCTAssertTrue(changed)
            XCTAssertEqual(fixture.browser.documentGeneration(for: id), generation, "This regression changes model controls without navigation")
            let expectedSends = action == "prepare" ? 0 : 1
            try await assertChoiceLedger(view, insertions: expectedSends, sends: expectedSends, selections: 1)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testModelDiscoveryReturnsOnlyEnabledFamiliesWithoutSendingAndPreservesHumanTabs() async throws {
        for provider in Self.choiceProviders {
            let fixture = try Fixture(page: Self.modelChoicePage(provider))
            defer { fixture.shutdown() }
            let discovery = Task { try await fixture.transport.discoverModels(provider: provider.rawValue) }
            for _ in 0..<1_000 where fixture.createdTabs.isEmpty { await Task.yield() }
            let id = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            let choices = try await discovery.value
            let advertised = Self.choiceLabels(provider).filter { provider != .chatgpt || $0 != "Latest" }
            XCTAssertEqual(choices.map(\.label), advertised)
            XCTAssertEqual(choices.map(\.key), advertised)
            XCTAssertTrue(choices.allSatisfy { $0.provider == provider.rawValue && $0.isValid })
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            let clicks = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
            let escapes = try await evaluate(view, "return {attempts: window.fixtureModelEscapeEvents, closed: window.fixtureModelEscapeClosures};") as? [String: Int]
            if provider == .chatgpt {
                XCTAssertEqual(clicks, 1, "Discovery opens the associated ChatGPT model menu once")
                XCTAssertEqual(escapes, ["attempts": 1, "closed": 1], "Discovery closes that menu with one acknowledged Escape")
            } else {
                XCTAssertEqual(clicks, 2, "The associated model menu is opened and closed once")
                XCTAssertEqual(escapes, ["attempts": 0, "closed": 0])
            }
            XCTAssertNil(fixture.browser.webView(for: id))
            try await assertHumanTabIntact(fixture)
        }
    }

    func testDiscoveryAuthRedirectClosesOnlyReadonlyOwnedTabAndDoesNotLeakCapacity() async throws {
        let authURL = try XCTUnwrap(URL(string: "https://accounts.google.com/o/oauth2/auth"))
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), initialURL: authURL)
        defer { fixture.shutdown() }
        // More than the inference capacity proves failed discovery does not
        // retain an unreachable private session after an authentication redirect.
        for _ in 0..<5 {
            do {
                _ = try await fixture.transport.discoverModels(provider: "chatgpt", retryBlocked: true)
                XCTFail("An authentication document cannot prove a model menu")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired)
            }
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            XCTAssertNil(fixture.browser.webView(for: ownedID))
            try await assertHumanTabIntact(fixture)
        }
        XCTAssertEqual(fixture.createdTabs.count, 5)

        do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"]); XCTFail("Discovery auth failures must gate inference") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
        XCTAssertEqual(fixture.createdTabs.count, 5)

        // Ordinary inference keeps its existing document/route authority; the
        // new prompt-free discovery cleanup must not weaken that contract.
        let inferenceFixture = try Fixture(page: Self.modelChoicePage(.chatgpt), initialURL: authURL)
        defer { inferenceFixture.shutdown() }
        let started = try await call(inferenceFixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let inferenceID = try XCTUnwrap(inferenceFixture.createdTabs.last)
        let inferenceView = try XCTUnwrap(inferenceFixture.browser.webView(for: inferenceID))
        try await waitForFixture(inferenceView)
        let cancelled = try await call(inferenceFixture.transport, "webProviderCancel", ["sessionToken": token])
        XCTAssertEqual(cancelled["cleanup"] as? String, "failed")
        XCTAssertTrue(inferenceFixture.browser.webView(for: inferenceID) === inferenceView)
        XCTAssertEqual(inferenceView.url, authURL)
        XCTAssertTrue(inferenceFixture.browser.webView(for: inferenceFixture.humanID) === inferenceFixture.humanView)
        try await assertChoiceLedger(inferenceView, insertions: 0, sends: 0, selections: 0)
    }

    func testDiscoveryCapacityIsIndependentOfFourInferenceSessionsAndItsTokenCannotSend() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        var inferenceTokens: [String] = []
        var inferenceIDs: [UUID] = []
        for _ in 0..<4 {
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            inferenceTokens.append(token)
            inferenceIDs.append(id)
        }

        var blocked = false
        var release: CheckedContinuation<Void, Never>?
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "discoverModels", !blocked else { return }
            blocked = true
            await withCheckedContinuation { release = $0 }
        }
        let discovery = Task { try await fixture.transport.discoverModels(provider: "chatgpt") }
        defer {
            release?.resume(); release = nil
            discovery.cancel()
            fixture.transport.setBeforePageResultValidationForTesting(nil)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !blocked, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(blocked, "A fifth, discovery-only page must be admitted beside four real sessions")
        guard blocked else { throw FixtureFailure.timeout }
        XCTAssertEqual(fixture.createdTabs.count, 5)
        let discoveryID = try XCTUnwrap(fixture.createdTabs.last)
        let discoveryView = try XCTUnwrap(fixture.browser.webView(for: discoveryID))
        let owner = try await evaluate(discoveryView, "return globalThis.__computaModelOwner;",
            world: .world(name: "computa-chatgpt-model-v1"))
        let discoveryToken = try XCTUnwrap(owner as? String)
        XCTAssertNotNil(UUID(uuidString: discoveryToken))
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": discoveryToken, "prompt": "Discovery must never insert or send this"])
            XCTFail("Even a valid private discovery token cannot submit a prompt")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
        try await assertChoiceLedger(discoveryView, insertions: 0, sends: 0, selections: 0)
        do {
            _ = try await fixture.transport.discoverModels(provider: "chatgpt")
            XCTFail("Only one discovery page may be active")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .capacity) }
        do {
            _ = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            XCTFail("Separating discovery capacity must preserve the four-inference limit")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .capacity) }
        XCTAssertEqual(fixture.createdTabs.count, 5)
        XCTAssertTrue(inferenceIDs.allSatisfy { fixture.browser.webView(for: $0) != nil })

        release?.resume(); release = nil
        let choices = try await discovery.value
        XCTAssertEqual(choices.map(\.label), Self.choiceLabels(.chatgpt).filter { $0 != "Latest" })
        XCTAssertNil(fixture.browser.webView(for: discoveryID))
        XCTAssertTrue(inferenceIDs.allSatisfy { fixture.browser.webView(for: $0) != nil })
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        for token in inferenceTokens {
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        }
        try await assertHumanTabIntact(fixture)
    }

    func testProviderOriginsAndRoutesRemainSessionSpecific() throws {
        let routes: [(EmbeddedWebModelTransport.Provider, String, String)] = [
            (.chatgpt, "https://chatgpt.com/", "https://chatgpt.com/c/owned-123"),
            (.claude, "https://claude.ai/new?incognito", "https://claude.ai/chat/owned-123"),
            (.gemini, "https://gemini.google.com/app", "https://gemini.google.com/app/owned_123"),
        ]
        for (provider, fresh, conversation) in routes {
            XCTAssertEqual(provider.startURL.absoluteString, fresh)
            XCTAssertTrue(provider.accepts(fresh))
            XCTAssertNil(provider.conversationURL(fresh))
            XCTAssertTrue(provider.accepts(conversation))
            XCTAssertEqual(provider.conversationURL(conversation + "/"), conversation)
            XCTAssertTrue(provider.acceptsUnboundStart(try XCTUnwrap(URL(string: fresh))))
            for (other, otherFresh, otherConversation) in routes where other != provider {
                XCTAssertFalse(provider.accepts(otherFresh))
                XCTAssertFalse(provider.accepts(otherConversation))
                XCTAssertNil(provider.conversationURL(otherConversation))
            }
            for invalid in [conversation.replacingOccurrences(of: "https://", with: "http://"),
                            conversation.replacingOccurrences(of: provider.host, with: "\(provider.host):8443"),
                            conversation.replacingOccurrences(of: "https://", with: "https://foreign@"),
                            conversation + "/foreign", "https://\(provider.host)/settings"] {
                XCTAssertFalse(provider.accepts(invalid))
                XCTAssertNil(provider.conversationURL(invalid))
            }
        }
        XCTAssertTrue(EmbeddedWebModelTransport.Provider.chatgpt.isLocalConversation("https://chatgpt.com/c/local-chatgpt:owned-123"))
        XCTAssertFalse(EmbeddedWebModelTransport.Provider.claude.isLocalConversation("https://claude.ai/chat/local-chatgpt-owned"))
        XCTAssertFalse(EmbeddedWebModelTransport.Provider.gemini.acceptsTemporaryToggle(try XCTUnwrap(URL(string: "https://gemini.google.com/app?temporary-chat=true"))))
        let gemini = EmbeddedWebModelTransport.Provider.gemini
        XCTAssertTrue(gemini.accepts("https://gemini.google.com/u/0/app"))
        XCTAssertTrue(gemini.accepts("https://gemini.google.com/u/999/app/owned_123"))
        XCTAssertEqual(gemini.conversationURL("https://gemini.google.com/u/0/app/owned_123"), "https://gemini.google.com/u/0/app/owned_123")
        XCTAssertEqual(gemini.routeContext("https://gemini.google.com/u/0/app/owned_123"), "https://gemini.google.com/u/0/app")
        XCTAssertNotEqual(gemini.routeContext("https://gemini.google.com/u/0/app"), gemini.routeContext("https://gemini.google.com/u/1/app/owned_123"))
        XCTAssertFalse(gemini.accepts("https://gemini.google.com/u/1000/app"))
        XCTAssertFalse(gemini.accepts("https://gemini.google.com/u/foreign/app"))
    }

    func testClaudeAndGeminiOwnedTemporarySessionsSubmitOnceAndKeepHumanTabs() async throws {
        for provider in [EmbeddedWebModelTransport.Provider.claude, .gemini] {
            let fixture = try Fixture(page: Self.providerPage(provider))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": provider.rawValue])
            XCTAssertEqual(started["provider"] as? String, provider.rawValue)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            XCTAssertEqual(view.url, provider.startURL)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let prompt = "Use `local tools` with \"quotes\" and C++\n\nASCII  spaces and\u{00a0}NBSP"
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
            let completed = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(completed["provider"] as? String, provider.rawValue)
            XCTAssertEqual(completed["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
            let prompts = try await capturedUserPrompts(view)
            XCTAssertTrue(prompts == [prompt] || prompts == [prompt + "\n"])
            let insertions = try await evaluate(view, "return window.fixtureInputCount;") as? Int
            XCTAssertEqual(insertions, 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            XCTAssertNil(fixture.browser.webView(for: tabID))
            XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID])
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
            XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        }
    }

    func testClaudeAndGeminiCannotContinueOrCloseAfterTemporaryProofDisappears() async throws {
        for provider in [EmbeddedWebModelTransport.Provider.claude, .gemini] {
            let fixture = try Fixture(page: Self.providerPage(provider))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": provider.rawValue])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Owned first message"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            _ = try await evaluate(view, "document.querySelectorAll('[data-fixture-temporary]').forEach(node => node.remove()); return true;")
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not use normal chat"])
            let prompts = try await capturedUserPrompts(view)
            XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Owned first message"])
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
        }
    }

    func testClaudeUsageQuotaRejectsAnotherSendAndCleanupRequiresPinnedIncognitoProof() async throws {
        for preserveMode in [true, false] {
            let fixture = try Fixture(page: Self.providerPage(.claude))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "claude"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Keep the locally retained task"])
            let complete = try await waitForState("complete", fixture.transport, token: token)
            _ = try await evaluate(view, """
                \(preserveMode ? "" : "document.querySelectorAll('[data-fixture-temporary]').forEach(node => node.remove());")
                const background = document.createElement('div');
                while (document.body.firstChild) background.appendChild(document.body.firstChild);
                background.setAttribute('inert', ''); background.setAttribute('aria-hidden', 'true');
                document.body.appendChild(background);
                window.fixtureQuotaClicks = 0;
                const dialog = document.createElement('div');
                const title = document.createElement('h1'); title.textContent = 'Your free messages return at 11:40 PM';
                dialog.appendChild(title);
                // The observed popup has three actual buttons. Price rendering
                // is variable; the exact plans/dismiss pair carries this proof.
                for (const label of ['Upgrade to Pro$20/month', 'See all plans', 'Not now']) {
                    const button = document.createElement('button'); button.textContent = label;
                    button.addEventListener('click', () => { window.fixtureQuotaClicks++; }); dialog.appendChild(button);
                }
                document.body.appendChild(dialog); return true;
                """)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not send through a quota modal"])
                XCTFail("The known quota must fail inference with a provider-specific typed error")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .usageLimited(.claude))
                XCTAssertTrue(error.localizedDescription.contains("Claude"))
                XCTAssertTrue(error.localizedDescription.contains("usage limit"))
                XCTAssertFalse(error.localizedDescription.contains("11:40"))
            }
            let prompts = try await capturedUserPrompts(view)
            XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Keep the locally retained task"])
            let insertions = try await evaluate(view, "return window.fixtureInputCount;") as? Int
            let quotaClicks = try await evaluate(view, "return window.fixtureQuotaClicks;") as? Int
            XCTAssertEqual(insertions, 1)
            XCTAssertEqual(quotaClicks, 0)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["text"] as? String, complete["text"] as? String)
            XCTAssertEqual(finished["cleanup"] as? String, preserveMode ? "not_created" : "failed")
            if preserveMode { XCTAssertNil(fixture.browser.webView(for: tabID)) }
            else { XCTAssertTrue(fixture.browser.webView(for: tabID) === view) }
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
        }
    }

    func testClaudeInitialQuotaBannerAbortsBeforeFocusOrSendAndClosesOnlyFreshOwnedTab() async throws {
        let fixture = try Fixture(page: Self.freshClaudeQuotaBannerPage)
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "claude"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("The exact official quota banner must abort inference before readiness or Send")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .usageLimited(.claude))
        }
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts, [])
        for variable in ["fixtureInputCount", "fixtureFocusCount", "fixtureQuotaClicks"] {
            let count = try await evaluate(view, "return window.\(variable);") as? Int
            XCTAssertEqual(count, 0, "Initial quota cannot focus, insert, Send, or open a quota link")
        }
        let unbound = try await evaluate(view, "return globalThis.__computaModelFirstProof === undefined && globalThis.__computaModelFirstSubmitted === undefined;",
                                         world: WKContentWorld.world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(unbound, true, "A quota error cannot bind first-message lineage")
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID])
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
    }

    func testFreshQuotaAbortRequiresExactEmptyReceiptAndFreshClaudeURL() throws {
        let url = EmbeddedWebModelTransport.Provider.claude.startURL
        let source: [String: Any] = ["error": "website_usage_limit", "freshQuotaAbort": true,
                                     "url": url.absoluteString, "userCount": 0, "responseCount": 0]
        XCTAssertTrue(EmbeddedWebModelTransport.validFreshQuotaAbort(source, provider: .claude, expectedURL: url, currentURL: url))
        for key in source.keys {
            var missing = source; missing.removeValue(forKey: key)
            XCTAssertFalse(EmbeddedWebModelTransport.validFreshQuotaAbort(missing, provider: .claude, expectedURL: url, currentURL: url))
        }
        let invalidFields: [(String, Any)] = [("freshQuotaAbort", 1), ("freshQuotaAbort", false), ("userCount", false),
                                             ("userCount", 1), ("responseCount", 1), ("responseCount", "0"), ("error", "temporary_mode_unverified")]
        for (key, value) in invalidFields {
            var forged = source; forged[key] = value
            XCTAssertFalse(EmbeddedWebModelTransport.validFreshQuotaAbort(forged, provider: .claude, expectedURL: url, currentURL: url))
        }
        var forged = source; forged["temporary"] = true
        XCTAssertFalse(EmbeddedWebModelTransport.validFreshQuotaAbort(forged, provider: .claude, expectedURL: url, currentURL: url))
        XCTAssertFalse(EmbeddedWebModelTransport.validFreshQuotaAbort(source, provider: .gemini, expectedURL: url, currentURL: url))
        for other in ["https://claude.ai/chat/foreign", "https://claude.ai/new", "https://claude.ai/new?incognito&changed=1", "https://example.test/new?incognito"] {
            let changed = try XCTUnwrap(URL(string: other))
            XCTAssertFalse(EmbeddedWebModelTransport.validFreshQuotaAbort(source, provider: .claude, expectedURL: url, currentURL: changed))
        }
    }

    func testClaudeFreshQuotaCannotBindAfterActivityResponsesOrAwaitedPageChanges() async throws {
        for condition in ["prepared", "response", "generation", "route"] {
            let fixture = try Fixture(page: Self.freshClaudeQuotaBannerPage)
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "claude"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            if condition == "prepared" {
                _ = try await evaluate(view, "globalThis.__computaModelFirstPrepared = true; return true;",
                                       world: WKContentWorld.world(name: "computa-chatgpt-model-v1"))
            } else if condition == "response" {
                _ = try await evaluate(view, """
                    const old = document.createElement('div'); old.setAttribute('data-testid', 'assistant-message');
                    old.hidden = true; document.getElementById('messages').appendChild(old); return true;
                    """)
            } else {
                var changed = false
                fixture.transport.setBeforePageResultValidationForTesting { action in
                    guard action == "inspect", !changed else { return }
                    changed = true
                    if condition == "generation" {
                        view.loadHTMLString(Self.freshClaudeQuotaBannerPage.replacingOccurrences(of: "'initial'", with: "'replacement'"),
                                            baseURL: EmbeddedWebModelTransport.Provider.claude.startURL)
                        try? await self.waitForFixture(view, generation: "replacement")
                    } else {
                        _ = try? await self.evaluate(view, "history.replaceState({}, '', '/new?incognito&changed=1'); return true;")
                    }
                }
            }
            do {
                let observed = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                if condition == "generation" {
                    // An initial navigation discards its obsolete read before
                    // any document is bound; it cannot authorize cleanup.
                    XCTAssertEqual(observed["state"] as? String, "loading")
                } else { XCTFail("Quota cannot bind an ambiguous initial document: \(condition)") }
            } catch {
                let expected: EmbeddedWebModelTransport.Failure = condition == "route" ? .ownershipFailure(.routeAfter) : .usageLimited(.claude)
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expected)
            }
            let prompts = try await capturedUserPrompts(view)
            XCTAssertEqual(prompts, [])
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed", condition)
            XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
        }
    }

    func testProviderUnavailableTemporaryModeNeverFallsBackToNormalChat() async throws {
        for provider in [EmbeddedWebModelTransport.Provider.claude, .gemini] {
            let fixture = try Fixture(page: Self.providerPage(provider).replacingOccurrences(of: "data-fixture-temporary", with: "data-fixture-no-mode"))
            defer { fixture.shutdown() }
            fixture.transport.setTimeoutsForTesting(preparation: .seconds(1), response: .seconds(300))
            let started = try await call(fixture.transport, "webProviderStart", ["provider": provider.rawValue])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            _ = try await evaluate(view, "document.querySelectorAll('[data-fixture-no-mode]').forEach(node => node.remove()); return true;")
            let loading = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(loading["state"] as? String, "loading", "A composer alone cannot claim a not-yet-rendered mode action")
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never send into normal chat"])
            try await Task.sleep(for: .seconds(1))
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("An unavailable temporary mode must reach the preparation deadline without Send")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .preparationDeadline) }
            let prompts = try await capturedUserPrompts(view)
            XCTAssertEqual(prompts, [])
            let insertions = try await evaluate(view, "return window.fixtureInputCount;") as? Int
            XCTAssertEqual(insertions, 0)
        }
    }

    func testProviderLineageRejectsReplacedFirstBodyAndForeignRoute() async throws {
        for provider in [EmbeddedWebModelTransport.Provider.claude, .gemini] {
            let fixture = try Fixture(page: Self.providerPage(provider))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": provider.rawValue])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Preserve exact owned rendered body"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            let selector = provider == .claude ? "[data-testid=user-message]" : "user-query .user-query-bubble-with-background > span.ng-star-inserted"
            _ = try await evaluate(view, "document.querySelector('\(selector)').firstChild.textContent = document.querySelector('\(selector)').firstChild.textContent.replace('Preserve', 'Substitute'); return true;")
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not follow substituted body"])
            let prompts = try await capturedUserPrompts(view)
            XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Preserve exact owned rendered body"])
            // A same-origin route change cannot restore ownership after the
            // first body is substituted, and an invalid provider route is
            // independently rejected before any mutation or cleanup.
            _ = try await evaluate(view, "history.replaceState({}, '', '/settings'); return true;")
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not target another route"])
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
        }
    }

    func testGeminiAccountPrefixPinsFirstPromotionAndRejectsAnotherAccount() async throws {
        let initial = try XCTUnwrap(URL(string: "https://gemini.google.com/u/0/app"))
        let fixture = try Fixture(page: Self.providerPage(.gemini), initialURL: initial)
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await evaluate(view, """
            document.getElementById('fixture-send').addEventListener('click', () => {
                history.replaceState({}, '', '/u/0/app/owned_123');
            }); return true;
            """)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "One selected account only"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(view.url?.absoluteString, "https://gemini.google.com/u/0/app/owned_123")
        // The other account presents the same DOM, marker and temporary badge.
        // Only the immutable provider account-route context rejects it.
        _ = try await evaluate(view, "history.replaceState({}, '', '/u/1/app/owned_123'); return true;")
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not switch accounts"])
            XCTFail("The first conversation promotion cannot change the admitted account")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.routeBefore)) }
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["One selected account only"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testGeminiSiblingControlChangesDuringPrepareKeepPayloadLineageAndSubmitOnce() async throws {
        let fixture = try Fixture(page: Self.providerPage(.gemini))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Keep `the exact payload` and its marker"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        _ = try await evaluate(view, """
            window.fixtureControlMutations = 0;
            const editor = document.getElementById('fixture-editor'); editor.blur();
            editor.addEventListener('focus', () => {
                const controls = document.querySelector('user-query .user-query-bubble-with-background > div');
                const button = document.createElement('button'); button.textContent = 'Edit this prompt';
                controls.appendChild(button); window.fixtureControlMutations++;
            }, {once: true}); return true;
            """)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Continue after local tool output"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let mutations = try await evaluate(view, "return window.fixtureControlMutations;") as? Int
        XCTAssertEqual(mutations, 1, "Prepare must exercise an actual focus-time change to sibling UI")
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Keep `the exact payload` and its marker", "Continue after local tool output"])
        let insertions = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(insertions, 2, "Each send inserts its exact prompt once")
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testGeminiDuplicateRenderedPayloadCannotContinueOrCloseOwnedChat() async throws {
        let fixture = try Fixture(page: Self.providerPage(.gemini))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "One owned payload"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        _ = try await evaluate(view, """
            const payload = document.querySelector('user-query .user-query-bubble-with-background > span.ng-star-inserted');
            payload.parentElement.appendChild(payload.cloneNode(true)); return true;
            """)
        await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never select one ambiguous body"])
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["One owned payload"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testGeminiAcknowledgedAppendDuringInspectDigestDiscardsReadAndWakesFreshProof() async throws {
        let fixture = try Fixture(page: Self.delayedGeminiSecondUserPage())
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Preserve the first payload"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Append this after the send acknowledgment"])
        XCTAssertEqual(sent["state"] as? String, "running")
        let beforeCount = try await evaluate(view, "return document.querySelectorAll('user-query').length;") as? Int
        XCTAssertEqual(beforeCount, 1, "The second click is acknowledged before its user bubble appears")
        try await armFixtureAppendDuringDigest(view)
        let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
        let revision = try XCTUnwrap(observedRevision)
        let discarded = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(discarded["state"] as? String, "running")
        XCTAssertEqual(discarded["sequence"] as? Int, 2)
        XCTAssertEqual(discarded["text"] as? String, "", "The crossed read cannot admit a response or stale ownership state")
        let afterCount = try await evaluate(view, "return document.querySelectorAll('user-query').length;") as? Int
        XCTAssertEqual(afterCount, 2)
        let notifiedRevision = try await fixture.transport.waitForChange(sessionToken: token, after: revision, until: .now + .seconds(1))
        XCTAssertGreaterThan(try XCTUnwrap(notifiedRevision), revision, "The real append must wake the armed versioned observer")
        let completed = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(completed["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Preserve the first payload", "Append this after the send acknowledgment"])
        let insertions = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        let appends = try await evaluate(view, "return window.fixtureDelayedAppends;") as? Int
        XCTAssertEqual(insertions, 2)
        XCTAssertEqual(appends, 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testGeminiAcknowledgedAppendWithChangedFirstBodyStillFailsOwnedProof() async throws {
        let fixture = try Fixture(page: Self.delayedGeminiSecondUserPage(mutatesFirstBody: true))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Preserve the first payload"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Append this after the send acknowledgment"])
        try await armFixtureAppendDuringDigest(view)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("An expected append cannot excuse a changed first-message body")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser))
        }
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.count, 2, "Neither insertion nor Send may replay after the failed read")
        let insertions = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(insertions, 2)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testGeminiFirstSubmissionCannotPromoteAcrossAccountsOrReplaySend() async throws {
        let fixture = try Fixture(page: Self.providerPage(.gemini),
                                  initialURL: XCTUnwrap(URL(string: "https://gemini.google.com/u/0/app")))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await evaluate(view, """
            document.getElementById('fixture-send').addEventListener('click', () => {
                history.replaceState({}, '', '/u/1/app/foreign_123');
            }); return true;
            """)
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "First submit on one account"])
            XCTFail("Even the first server route must retain the observed account prefix")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.routeAfter)) }
        await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Do not replay an uncertain Send"])
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["First submit on one account"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testInterruptedClaudeResponseFailsWithoutReplayAndStillClosesOwnedIncognitoTab() async throws {
        let fixture = try Fixture(page: Self.providerPage(.claude))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "claude"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Do not accept partial website output"])
        _ = try await evaluate(view, """
            const status = document.createElement('div');
            status.setAttribute('role', 'status'); status.setAttribute('data-testid', 'response-status-announcer');
            status.textContent = "Claude's response was interrupted.";
            document.body.appendChild(status); return true;
            """)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("An interrupted answer must never be admitted as a complete response")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseInterrupted) }
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Do not accept partial website output"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testGeminiTemporaryToggleNotificationsSurviveBeforeWaitAndDelayedRendering() async throws {
        for delay in [0, 700] {
            let fixture = try Fixture(page: Self.providerPage(.gemini))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            _ = try await evaluate(view, """
                document.querySelectorAll('[data-fixture-temporary]').forEach(node => node.remove());
                window.fixtureToggleCount = 0;
                const toggle = document.createElement('button');
                toggle.setAttribute('aria-label', 'Temporary chat'); toggle.textContent = 'Temporary chat';
                toggle.addEventListener('click', () => {
                    window.fixtureToggleCount++;
                    toggle.disabled = true;
                    setTimeout(() => {
                        const heading = document.createElement('h2');
                        const title = document.createElement('span'); title.textContent = 'Just stopping by?';
                        const description = document.createElement('span');
                        description.textContent = "Temporary chats don't appear in recent chats and aren't used to improve Google AI.";
                        const support = document.createElement('a');
                        support.href = 'https://support.google.com/gemini/answer/13275745?p=temp_chats';
                        support.textContent = 'Learn more';
                        heading.append(title, description, support); document.body.prepend(heading);
                    }, \(delay));
                }); document.body.prepend(toggle); return true;
                """)
            let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
            let before = try XCTUnwrap(observedRevision)
            let loading = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(loading["state"] as? String, "loading")
            if delay == 0 {
                // Let the isolated observer post before the native waiter is
                // registered. Its revision must still be remembered.
                try await Task.sleep(for: .milliseconds(300))
                let began = ContinuousClock.now
                let after = try await fixture.transport.waitForChange(sessionToken: token, after: before, until: .now + .seconds(3))
                XCTAssertGreaterThan(try XCTUnwrap(after), before)
                XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(200))
            }
            _ = try await waitForState("ready", fixture.transport, token: token)
            let toggles = try await evaluate(view, "return window.fixtureToggleCount;") as? Int
            XCTAssertEqual(toggles, 1, "Read-only waiting must never toggle the mode again")
            let empty = try await capturedUserPrompts(view)
            XCTAssertEqual(empty, [])
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Submit only after verified mode"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            let prompts = try await capturedUserPrompts(view)
            XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Submit only after verified mode"])
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        }
    }

    func testPreparationDeadlineWakesWithoutDOMEventsAndNeverSubmits() async throws {
        let fixture = try Fixture(page: Self.providerPage(.gemini))
        defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(1), response: .seconds(300))
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await evaluate(view, "document.getElementById('fixture-editor').remove(); return true;")
        let began = ContinuousClock.now
        let end = began + .seconds(3)
        var timedOut = false
        while ContinuousClock.now < end {
            let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
            let before = try XCTUnwrap(observedRevision)
            do {
                let loading = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(loading["state"] as? String, "loading")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .preparationDeadline)
                XCTAssertTrue(error.localizedDescription.contains("45-second"))
                XCTAssertTrue(error.localizedDescription.contains("No prompt was sent"))
                XCTAssertFalse(error.localizedDescription.contains("five-minute"))
                timedOut = true; break
            }
            _ = try await fixture.transport.waitForChange(sessionToken: token, after: before, until: end)
        }
        XCTAssertTrue(timedOut)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2), "The native preparation deadline must wake a waiter even without another DOM event")
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts, [])
        let insertions = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(insertions, 0)
    }

    func testReadinessDiagnosticsProjectOnlyBoundedStructuralMetadata() throws {
        let counts = ["total": 1, "visible": 1, "enabled": 1]
        var raw: [String: Any] = ["kind": "provider_readiness", "provider": "gemini",
            "nodes": [["tag": "h2", "classes": ["temporary-chat"], "textLength": 123,
                       "visible": true, "excluded": false, "initialTitle": true, "supportLink": true, "noHistory": true,
                       "text": "private_canary", "id": "private_canary", "url": "https://private_canary"]],
            "composer": counts, "toggle": counts, "exit": counts, "prompt": "private_canary"]
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let projected = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedReadinessStructure(try encode(raw), provider: .gemini))
        XCTAssertFalse(projected.contains("private_canary"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
        let nodes = try XCTUnwrap(value["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.first?["initialTitle"] as? Bool, true)
        XCTAssertEqual(nodes.first?["supportLink"] as? Bool, true)
        XCTAssertNil(value["prompt"])
        XCTAssertNil(nodes.first?["text"])
        XCTAssertNil(nodes.first?["id"])
        XCTAssertNil(nodes.first?["url"])
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedReadinessStructure(try encode(raw), provider: .claude))
        raw["toggle"] = ["total": 1_001, "visible": 1, "enabled": 1]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedReadinessStructure(try encode(raw), provider: .gemini))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedReadinessStructure(String(repeating: "x", count: 8_193), provider: .gemini))
    }

    func testQuotaDiagnosticsRejectUntrustedStringsTypesAndUnboundedStructure() throws {
        let base: [String: Any] = ["tag": "div", "rectCount": 1, "strictVisible": false, "physicalVisible": true,
                                  "inertAncestor": true, "ariaHiddenAncestor": false, "display": "other", "visibility": "visible",
                                  "text": "private_canary", "id": "private_canary", "class": "private_canary", "url": "https://private_canary"]
        var heading = base; heading["tag"] = "h2"; heading["spacedClock"] = true; heading["joinedClock"] = false
        var control = base; control["tag"] = "button"; control["privateUseCount"] = 1
        for key in ["roleButton", "ariaLabelPresent", "ariaUpgradeExact", "ariaDismissExact", "textUpgradeExact", "textDismissExact",
                    "upgradeEdgePrivateUse", "dismissEdgePrivateUse", "hasUnknownLabelText"] { control[key] = false }
        var ancestor = base; ancestor["containsMessages"] = false
        for key in ["depth", "buttonCount", "roleButtonCount", "anchorCount", "upgradeExactCount", "dismissExactCount"] { ancestor[key] = 1 }
        var support = base; support["tag"] = "private_canary"; support["labelExact"] = false; support["labelKnownSuffix"] = true
        var banner = base; banner["spacedClock"] = false; banner["joinedClock"] = true; banner["supportDirect"] = true
        banner["children"] = ["text", "support", "text"]
        let source: [String: Any] = ["kind": "quota_structure", "provider": "claude",
            "headings": [heading], "controls": [control], "popupAncestors": [ancestor], "support": [support], "bannerParents": [banner],
            "mode": ["headerTotal": 1, "headerVisible": 0, "headerPhysical": 1, "exitTotal": 1, "exitVisible": 0, "exitPhysical": 1],
            "prompt": "private_canary"]
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(source), provider: .claude))
        XCTAssertFalse(safe.contains("private_canary"))
        let projected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        let supports = try XCTUnwrap(projected["support"] as? [[String: Any]])
        XCTAssertEqual(supports.first?["tag"] as? String, "other")
        XCTAssertEqual(supports.first?["labelKnownSuffix"] as? Bool, true)
        XCTAssertEqual((projected["mode"] as? [String: Int])?["headerVisible"], 0)
        XCTAssertNil(projected["prompt"])
        let records = try XCTUnwrap(EmbeddedWebModelTransport.quotaStructureDiagnosticRecords(try encode(source), provider: .claude))
        XCTAssertEqual(records.count, 6)
        XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(source), provider: .gemini))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(String(repeating: "x", count: 8_193), provider: .claude))
        for (section, limit) in [("headings", 4), ("controls", 8), ("popupAncestors", 8), ("support", 4), ("bannerParents", 4)] {
            var forged = source
            let node = try XCTUnwrap((source[section] as? [[String: Any]])?.first)
            forged[section] = Array(repeating: node, count: limit + 1)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(forged), provider: .claude))
        }
        let badCounts: [Any] = [-1, 1_001, 0.5, true, "private_canary"]
        for badCount in badCounts {
            var forged = source; var changed = heading; changed["rectCount"] = badCount; forged["headings"] = [changed]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(forged), provider: .claude))
        }
        var forged = source; var changed = control; changed["roleButton"] = 1; forged["controls"] = [changed]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(forged), provider: .claude))
        forged = source; changed = ancestor; changed["depth"] = 8; forged["popupAncestors"] = [changed]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(forged), provider: .claude))
        forged = source; changed = banner; changed["children"] = ["text", "private_canary"]; forged["bannerParents"] = [changed]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(forged), provider: .claude))
        forged = source; changed = banner; changed["children"] = Array(repeating: "text", count: 9); forged["bannerParents"] = [changed]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(forged), provider: .claude))
        forged = source; forged["mode"] = ["headerTotal": 1_001]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedQuotaStructure(try encode(forged), provider: .claude))
    }

    func testInsertionDifferenceDiagnosticsAllowOnlyFiniteIndexAndUnicodeScalars() {
        XCTAssertEqual(EmbeddedWebModelTransport.insertionDifferenceDiagnostic([
            "firstDifference": 42, "actualScalar": 160, "expectedScalar": 32, "rawPrompt": "private_canary"
        ]), "; first difference 42; actual/expected scalars 160/32")
        XCTAssertEqual(EmbeddedWebModelTransport.insertionDifferenceDiagnostic([
            "firstDifference": 3, "actualScalar": NSNull(), "expectedScalar": 0x1F680
        ]), "; first difference 3; actual/expected scalars end/128640")
        for invalid in [-1, 360_001] {
            XCTAssertNil(EmbeddedWebModelTransport.insertionDifferenceDiagnostic([
                "firstDifference": invalid, "actualScalar": 160, "expectedScalar": 32
            ]))
        }
        for invalid in [-1, 0xD800, 0xDFFF, 0x110000] {
            XCTAssertNil(EmbeddedWebModelTransport.insertionDifferenceDiagnostic([
                "firstDifference": 42, "actualScalar": invalid, "expectedScalar": 32
            ]))
        }
        XCTAssertNil(EmbeddedWebModelTransport.insertionDifferenceDiagnostic([
            "firstDifference": 42, "actualScalar": "private_canary", "expectedScalar": 32
        ]))
        XCTAssertNil(EmbeddedWebModelTransport.insertionDifferenceDiagnostic(["firstDifference": 42]))
    }

    func testCodeStructureDiagnosticsPreserveOnlyBoundedCountsAndHeaderAncestry() throws {
        var source: [String: Any] = ["preCount": 1, "codeCount": 1, "codeTextLength": 321,
            "outsideTextLength": 5, "outsideTruncated": false, "preParentTags": ["div", "section"],
            "outsideNodes": [["kind": "json", "textLength": 4, "text": "private_canary", "ancestors": [
                ["tag": "div", "classes": ["code-header"], "preDescendants": 1, "copyControls": 1,
                 "id": "private_canary", "url": "https://private_canary"]]]], "response": "private_canary"]
        let projected = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedCodeStructure(source))
        XCTAssertFalse(projected.contains("private_canary"))
        XCTAssertTrue(projected.contains("code-header"))
        XCTAssertTrue(projected.contains("json"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
        XCTAssertNil(value["response"])
        XCTAssertEqual(value["preCount"] as? Int, 1)
        source["outsideNodes"] = [["kind": "private_canary", "textLength": 4, "ancestors": []]]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(source))
        source.removeValue(forKey: "outsideNodes")
        source["preParentTags"] = ["private text"]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(source))
        source["preParentTags"] = ["div"]
        source["outsideTextLength"] = 220_002
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(source))
    }

    func testCodeStructureExtractionFlagsAreFiniteAndCannotCarryReplyContent() throws {
        let base: [String: Any] = ["preCount": 1, "codeCount": 1, "codeTextLength": 321,
            "outsideTextLength": 5, "outsideTruncated": false, "preParentTags": ["div"]]
        var source = base
        source.merge(["literalCodeValidJSON": true, "literalCodeKnownEnvelopeType": "tool_calls",
            "selectedExtraction": "rendered_fallback", "extractionReason": "outside_content",
            "reply": "private_canary"]) { _, new in new }
        let projected = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedCodeStructure(source))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
        XCTAssertEqual(value["literalCodeValidJSON"] as? Bool, true)
        XCTAssertEqual(value["literalCodeKnownEnvelopeType"] as? String, "tool_calls")
        XCTAssertEqual(value["selectedExtraction"] as? String, "rendered_fallback")
        XCTAssertEqual(value["extractionReason"] as? String, "outside_content")
        XCTAssertFalse(projected.contains("private_canary"))
        for key in ["literalCodeValidJSON", "literalCodeKnownEnvelopeType", "selectedExtraction", "extractionReason"] {
            var poisoned = source
            poisoned[key] = "private_canary"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(poisoned))
        }
        source["literalCodeValidJSON"] = 1
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(source))
        source["literalCodeValidJSON"] = NSNull()
        source["literalCodeKnownEnvelopeType"] = NSNull()
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedCodeStructure(source))
    }

    func testFirstUserDiagnosticsDropUnknownStringsAndRejectUnboundedMetadata() throws {
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let source: [String: Any] = ["kind": "first_user_structure", "provider": "gemini",
            "root": ["tag": "user-query", "classes": ["ng-star-inserted", "private_canary"], "text": "private_canary"],
            "body": ["tag": "private-canary", "classes": ["truncate", "private_canary"], "id": "private_canary"],
            "userCount": 1, "textLength": 42, "lineCount": 3, "markerOccurrences": 1, "controlDescendants": 2,
            "markerFinalLine": false, "submitted": true, "markerMatches": true,
            "prompt": "private_canary", "marker": "private_canary", "url": "https://private_canary"]
        let projected = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(source), provider: .gemini))
        XCTAssertFalse(projected.contains("private_canary"))
        XCTAssertFalse(projected.contains("private-canary"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
        XCTAssertEqual((value["root"] as? [String: Any])?["classes"] as? [String], ["ng-star-inserted"])
        XCTAssertEqual((value["body"] as? [String: Any])?["tag"] as? String, "other")
        XCTAssertEqual(value["controlDescendants"] as? Int, 2)
        XCTAssertEqual(value["markerFinalLine"] as? Bool, false)
        XCTAssertNil(value["prompt"])
        XCTAssertNil(value["marker"])
        XCTAssertNil(value["url"])
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(source), provider: .claude))
        for (key, invalid) in [("userCount", -1), ("markerOccurrences", 1_001), ("controlDescendants", 1_001),
                               ("textLength", 220_002), ("lineCount", 220_002)] {
            var forged = source; forged[key] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        }
        var forged = source; forged["submitted"] = "private_canary"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        forged = source; forged["root"] = ["tag": "user-query", "classes": Array(repeating: "truncate", count: 7)]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        forged = source; forged["body"] = ["tag": "div", "classes": [String(repeating: "x", count: 49)]]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(String(repeating: "x", count: 8_193), provider: .gemini))

        let child: [String: Any] = ["path": [0, 1], "tag": "span",
            "classes": ["query-text", "gds-body-l", "private_canary"], "childElements": 0, "controls": 0,
            "textLength": 42, "markerExact": false, "markerContained": true, "visible": true, "editable": false,
            "text": "private_canary", "id": "private_canary", "url": "https://private_canary"]
        let snapshot: [String: Any] = ["rootSame": true, "bodySame": true, "bodyConnected": true,
            "textSame": false, "countSame": true, "urlSame": true, "originSame": true, "ownerSame": true,
            "prompt": "private_canary"]
        var diagnostic = source
        diagnostic["reason"] = "snapshot_after_action"
        diagnostic["pinnedFingerprintMatch"] = false
        diagnostic["nativeFingerprintMatch"] = true
        diagnostic["snapshot"] = snapshot
        diagnostic["descendants"] = [child]
        let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(diagnostic), provider: .gemini))
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[0].utf8)) as? [String: Any])
        XCTAssertEqual(summary["reason"] as? String, "snapshot_after_action")
        XCTAssertEqual(summary["pinnedFingerprintMatch"] as? Bool, false)
        XCTAssertEqual((summary["snapshot"] as? [String: Any])?["textSame"] as? Bool, false)
        XCTAssertNil(summary["descendants"])
        let discovery = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[1].utf8)) as? [String: Any])
        XCTAssertEqual(discovery["classes"] as? [String], ["query-text", "gds-body-l"])
        XCTAssertEqual(discovery["path"] as? [Int], [0, 1])
        XCTAssertEqual(discovery["markerContained"] as? Bool, true)
        XCTAssertNil(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(diagnostic), provider: .gemini, expectedReason: "first_bound"))
        var bound = diagnostic; bound["reason"] = "first_bound"
        let boundRecords = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(bound), provider: .gemini, expectedReason: "first_bound"))
        XCTAssertEqual(boundRecords.count, 2)
        XCTAssertTrue(boundRecords[0].contains("first_bound"))
        XCTAssertFalse(boundRecords.joined().contains("private_canary"))
        forged = diagnostic; forged["reason"] = "private_canary"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        forged = diagnostic; forged["nativeFingerprintMatch"] = "private_canary"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        var incompleteSnapshot = snapshot; incompleteSnapshot.removeValue(forKey: "ownerSame")
        forged = diagnostic; forged["snapshot"] = incompleteSnapshot
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        forged = diagnostic; forged["descendants"] = Array(repeating: child, count: 17)
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        for invalidPath in [[-1], [1_001], Array(repeating: 0, count: 17)] {
            var invalidChild = child; invalidChild["path"] = invalidPath
            forged = diagnostic; forged["descendants"] = [invalidChild]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        }
        for (key, invalid) in [("childElements", 1_001), ("controls", 1_001), ("textLength", 220_002)] {
            var invalidChild = child; invalidChild[key] = invalid
            forged = diagnostic; forged["descendants"] = [invalidChild]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .gemini))
        }
    }

    func testGeminiLiteralQuillInsertionPreservesApostrophesAndEverySourceLine() async throws {
        let fixture = try Fixture(page: Self.providerPage(.gemini))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            const style = document.createElement('style');
            style.textContent = '.ql-editor p { margin: 0; padding: 0; }';
            document.head.appendChild(style); return true;
            """)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let prompt = "I can't say \"don't\": 'single quotes' and `backticks` \\\n\n\n  leading  ASCII\tspaces and\u{00a0}NBSP\n--flags /tmp/a\\b C++\nEmoji 🚀\n"
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let captured = try await capturedUserPrompts(view)
        XCTAssertTrue(captured == [prompt] || captured == [prompt + "\n"], "The fixed provider program must preserve literal source text through WK editor readback")
        let inputCount = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(inputCount, 1, "The ql-editor literal DOM path must dispatch one insertion event")
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
    }

    func testGeminiWaitsForAnEnabledTemporaryActionAfterItsComposerLoads() async throws {
        let fixture = try Fixture(page: Self.providerPage(.gemini))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            document.querySelectorAll('[data-fixture-temporary]').forEach(node => node.remove());
            window.fixtureToggleCount = 0; return true;
            """)
        let initial = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(initial["state"] as? String, "loading")
        await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never send before mode is available"])
        _ = try await evaluate(view, """
            const toggle = document.createElement('button');
            toggle.setAttribute('aria-label', 'Temporary chat'); toggle.textContent = 'Temporary chat';
            toggle.disabled = true;
            toggle.addEventListener('click', () => {
                window.fixtureToggleCount++;
                toggle.disabled = true;
                const exit = document.createElement('button');
                exit.setAttribute('aria-label', 'Turn off temporary chat'); exit.textContent = 'Temporary Chat';
                document.body.prepend(exit);
            }); document.body.prepend(toggle); return true;
            """)
        let disabled = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(disabled["state"] as? String, "loading")
        let noClicks = try await evaluate(view, "return window.fixtureToggleCount;") as? Int
        XCTAssertEqual(noClicks, 0, "Neither an absent nor a disabled mode control may be claimed")
        let empty = try await capturedUserPrompts(view)
        XCTAssertEqual(empty, [])
        _ = try await evaluate(view, """
            setTimeout(() => { document.querySelector('button[aria-label="Temporary chat"]').disabled = false; }, 700);
            return true;
            """)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let oneClick = try await evaluate(view, "return window.fixtureToggleCount;") as? Int
        XCTAssertEqual(oneClick, 1, "The enabled attribute signal must allow the sole mode activation")
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Send after mode activation"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Send after mode activation"])
    }

    func testUnconfirmedTemporaryToggleIsNeverClickedAgainDuringReadiness() async throws {
        let fixture = try Fixture(page: Self.providerPage(.gemini))
        defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(1), response: .seconds(300))
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            document.querySelectorAll('[data-fixture-temporary]').forEach(node => node.remove());
            window.fixtureToggleCount = 0;
            const toggle = document.createElement('button');
            toggle.setAttribute('aria-label', 'Temporary chat'); toggle.textContent = 'Temporary chat';
            toggle.addEventListener('click', () => { window.fixtureToggleCount++; toggle.className = 'clicked'; });
            document.body.prepend(toggle); return true;
            """)
        for _ in 0..<3 {
            let loading = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(loading["state"] as? String, "loading")
        }
        let clicks = try await evaluate(view, "return window.fixtureToggleCount;") as? Int
        XCTAssertEqual(clicks, 1, "An unconfirmed first click must not be replayed while its control remains enabled")
        try await Task.sleep(for: .seconds(1))
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("Unconfirmed mode activation must end at the preparation deadline")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .preparationDeadline) }
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts, [])
    }

    func testOwnedTemporaryChatSendsLiteralTextAndClosesOnlyItsTab() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let ownedView = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        XCTAssertTrue(ownedView.configuration.websiteDataStore === fixture.humanView.configuration.websiteDataStore)
        try await waitForFixture(ownedView)
        let documentURL = try await evaluate(ownedView, "return document.URL;") as? String
        XCTAssertEqual(documentURL, "https://chatgpt.com/")
        _ = try await waitForState("ready", fixture.transport, token: token)
        let temporaryURL = try await evaluate(ownedView, "return document.URL;") as? String
        XCTAssertEqual(temporaryURL, "https://chatgpt.com/?temporary-chat=true")

        let prompt = "A \"quote\", a \\ backslash, C++ & Swift\n\nASCII  spaces\tand\u{00a0}NBSP\n  {\"key\":\"escaped tags </script><script>window.fixtureInjected = true</script>\"}\nTail \"double quote\""
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
        XCTAssertEqual(sent["state"] as? String, "running")
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        let captured = try await capturedUserPrompts(ownedView)
        // WebKit may expose the final contenteditable block separator as one
        // trailing newline. Every character inside the prompt remains exact.
        XCTAssertTrue(captured == [prompt] || captured == [prompt + "\n"],
                      "The prompt must reach the editor literally and be submitted once")
        let clearedFocus = try await evaluate(ownedView, "return window.fixtureFocusClears > 0;") as? Bool
        XCTAssertEqual(clearedFocus, true, "The fixture must remove WebKit's incidental focus selection")
        let inputCount = try await evaluate(ownedView, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(inputCount, 1, "The owned editor must receive one insertion event")
        let normalizationCount = try await evaluate(ownedView, "return window.fixtureNormalizationCount;") as? Int
        XCTAssertEqual(normalizationCount, 1, "The site must commit its asynchronous editor normalization before Send")
        let injected = try await evaluate(ownedView, "return window.fixtureInjected === true;") as? Bool
        XCTAssertEqual(injected, false)

        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: ownedID))
        XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID])
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
        let humanMarker = try await evaluate(fixture.humanView, "return document.getElementById('human-marker')?.textContent;") as? String
        XCTAssertEqual(humanMarker, "Untouched human tab")
    }

    func testLosingTemporaryProofRejectsAnotherSendAndRetainsOwnedChat() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let ownedView = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(ownedView)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "First owned submission"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        _ = try await evaluate(ownedView, "document.querySelector('[aria-label=\"Turn off temporary chat\"]').remove(); return true;")

        await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not be submitted"])
        let captured = try await capturedUserPrompts(ownedView)
        XCTAssertTrue(captured == ["First owned submission"] || captured == ["First owned submission\n"],
                      "Losing temporary mode must not allow a second submission")
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === ownedView)
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testRenderedMarkdownPinsLineageAndRejectsSameCountBodyReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            window.fixtureRenderMarkdown = true;
            document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
                document.querySelectorAll('[data-message-author-role="user"]').forEach(user => {
                    user.removeAttribute('data-message-author-role');
                    user.setAttribute('data-user-message-bubble', '');
                    const body = user.firstElementChild;
                    body.removeAttribute('data-markdown-text-style');
                    body.className = 'whitespace-pre-wrap';
                });
            }); return true;
            """)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let prompt = "Use `tool_calls` and `exec_command` with \"quotes\"\n\n  ASCII  spaces and\u{00a0}NBSP"
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let captured = try await capturedUserPrompts(view)
        XCTAssertTrue(captured == [prompt] || captured == [prompt + "\n"])
        let codeCount = try await evaluate(view, "return document.querySelector('[data-user-message-bubble]').querySelectorAll('code').length;") as? Int
        XCTAssertEqual(codeCount, 2)
        let rawBody = try await evaluate(view, "return document.querySelector('.whitespace-pre-wrap').innerText;") as? String
        XCTAssertFalse(rawBody?.contains("`tool_calls`") == true, "The fixture must omit Markdown delimiters after rendering")
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "A follow-up after pinned lineage"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        _ = try await evaluate(view, """
            document.querySelector('[data-user-message-bubble] .whitespace-pre-wrap code').textContent = 'foreign_schema';
            return true;
            """)
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not follow substituted content"])
            XCTFail("The same marker and message count cannot adopt a changed first body")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser))
        }
        let afterRejected = try await capturedUserPrompts(view)
        XCTAssertEqual(afterRejected?.map { $0.trimmingCharacters(in: .newlines) }, [prompt, "A follow-up after pinned lineage"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testFirstMarkerOverheadRejectsOversizedOutboundBeforeInsertion() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": String(repeating: "x", count: 180_000)])
            XCTFail("First-send marker overhead must fit inside the outbound limit")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .invalidRequest) }
        let inputCount = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(inputCount, 0)
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts, [])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
    }

    func testUnknownTokenAndReplacementDocumentCannotAcquireOwnedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let ownedView = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(ownedView)
        _ = try await waitForState("ready", fixture.transport, token: token)
        await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": UUID().uuidString, "prompt": "Unknown authority"])
        let empty = try await capturedUserPrompts(ownedView)
        XCTAssertEqual(empty, [])

        // The replacement has the same origin, route and controls. Only the
        // owned document's isolated-world identity distinguishes it.
        let replacement = Self.page.replacingOccurrences(of: "window.fixtureGeneration = 'initial';", with: "window.fixtureGeneration = 'replacement';")
        ownedView.loadHTMLString(replacement, baseURL: URL(string: "https://chatgpt.com/?temporary-chat=true"))
        try await waitForFixture(ownedView, generation: "replacement")
        await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Replacement must not receive this"])
        let replacementPrompts = try await capturedUserPrompts(ownedView)
        XCTAssertEqual(replacementPrompts, [])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === ownedView)
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        XCTAssertEqual(fixture.createdTabs.count, 1)
    }

    func testDocumentReplacementAfterJavaScriptResultRejectsBeforeInsertion() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = try XCTUnwrap(fixture.browser.documentGeneration(for: ownedID))
        var replaced = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "prepare", !replaced else { return }
            replaced = true
            let replacement = Self.page.replacingOccurrences(of: "window.fixtureGeneration = 'initial';", with: "window.fixtureGeneration = 'replacement';")
            view.loadHTMLString(replacement, baseURL: URL(string: "https://chatgpt.com/?temporary-chat=true"))
            try? await self.waitForFixture(view, generation: "replacement")
        }
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not reach a replacement"])
            XCTFail("A result from the old document must be rejected")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.documentGenerationAfter))
        }
        XCTAssertTrue(replaced)
        XCTAssertNotEqual(generation, fixture.browser.documentGeneration(for: ownedID))
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts, [])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
    }

    func testChangedSPARouteAfterJavaScriptResultRejectsBeforeInsertion() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        var changed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "prepare", !changed else { return }
            changed = true
            _ = try? await self.evaluate(view, "history.pushState({}, '', '/c/foreign-conversation?temporary-chat=true'); return true;")
        }
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not reach another route"])
            XCTFail("A changed route must be rejected independently of document generation")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.routeAfter))
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(generation, fixture.browser.documentGeneration(for: ownedID))
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts, [])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
    }

    func testFirstSendAndAwaitedReadAllowOwnedSPAPromotionAndAnotherSend() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            const empty = document.createElement('div');
            empty.id = 'empty-identity'; empty.style.height = '1px';
            empty.setAttribute('data-chatgpt-selection-conversation-id', 'empty-placeholder');
            document.body.appendChild(empty);
            document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
                document.getElementById('empty-identity')?.remove();
                const identity = window.fixturePrompts.length === 1 ? 'local-fixture' : 'server-fixture';
                document.querySelectorAll('[data-chatgpt-selection-conversation-id]').forEach(node =>
                    node.setAttribute('data-chatgpt-selection-conversation-id', identity));
                if (window.fixturePrompts.length === 1)
                    history.pushState({}, '', '/c/local-chatgpt%3Afixture?temporary-chat=true');
            });
            return true;
            """)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "First owned prompt"])
        var reads = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect" else { return }
            reads += 1
            if reads == 2 {
                _ = try? await self.evaluate(view, """
                    document.querySelectorAll('[data-chatgpt-selection-conversation-id]').forEach(node =>
                        node.setAttribute('data-chatgpt-selection-conversation-id', 'server-fixture'));
                    history.replaceState({}, '', '/c/final-conversation?temporary-chat=true'); return true;
                    """)
            }
        }
        _ = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertGreaterThanOrEqual(reads, 3, "A route change during inspection must discard the stale result and inspect again")
        XCTAssertEqual(view.url?.path, "/c/final-conversation")
        _ = try await evaluate(view, """
            document.querySelectorAll('[data-chatgpt-selection-conversation-id]').forEach(node =>
                node.setAttribute('data-chatgpt-selection-conversation-id', 'ordinary-re-render'));
            return true;
            """)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Second owned prompt"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(generation, fixture.browser.documentGeneration(for: ownedID))
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["First owned prompt", "Second owned prompt"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: ownedID))
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testPromotionAllowsMissingOrAmbiguousAuxiliarySelectionIdentity() async throws {
        for ambiguous in [false, true] {
            let fixture = try Fixture()
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await evaluate(view, """
                document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
                    if (window.fixturePrompts.length === 1)
                        history.pushState({}, '', '/c/local-chatgpt%3Afixture?temporary-chat=true');
                }); return true;
                """)
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "First exact owned message"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            if ambiguous {
                _ = try await evaluate(view, """
                    const auxiliary = document.createElement('span');
                    auxiliary.textContent = 'An auxiliary selection';
                    auxiliary.setAttribute('data-chatgpt-selection-conversation-id', 'different-render-id');
                    document.body.appendChild(auxiliary); return true;
                    """)
            } else {
                _ = try await evaluate(view, "document.querySelectorAll('[data-chatgpt-selection-conversation-id]').forEach(node => node.removeAttribute('data-chatgpt-selection-conversation-id')); return true;")
            }
            _ = try await evaluate(view, "history.replaceState({}, '', '/c/server-conversation?temporary-chat=true'); return true;")
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Second exact owned message"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(generation, fixture.browser.documentGeneration(for: ownedID))
            let prompts = try await capturedUserPrompts(view)
            XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["First exact owned message", "Second exact owned message"])
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            XCTAssertNil(fixture.browser.webView(for: ownedID))
        }
    }

    func testPendingZeroUserPromotionDefersAnswerAndCleanupUntilOwnedUserAppears() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
                if (window.fixturePrompts.length === 1) {
                    document.querySelector('[data-message-author-role="user"]').remove();
                    history.pushState({}, '', '/c/local-chatgpt%3Afixture?temporary-chat=true');
                }
            }); return true;
            """)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "A delayed owned first message"])
        // Establish the local route while the submitted user has not rendered.
        let local = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(local["state"] as? String, "running")
        XCTAssertEqual(local["text"] as? String, "")
        _ = try await evaluate(view, "history.replaceState({}, '', '/c/pending-server-route?temporary-chat=true'); return true;")
        let deferred = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(deferred["state"] as? String, "running")
        XCTAssertEqual(deferred["text"] as? String, "", "An unverified answer must not escape during promotion")
        let cleanup = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(cleanup["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
        _ = try await evaluate(view, """
            const user = document.createElement('div');
            user.setAttribute('data-message-author-role', 'user');
            user.style.whiteSpace = 'pre-wrap'; user.textContent = window.fixturePrompts[0];
            document.getElementById('messages').prepend(user);
            document.querySelectorAll('[data-chatgpt-selection-conversation-id]').forEach(node =>
                node.removeAttribute('data-chatgpt-selection-conversation-id'));
            history.replaceState({}, '', '/c/final-verified-route?temporary-chat=true'); return true;
            """)
        // The earlier pending route was never adopted; this final route is
        // accepted only after the exact first message supplies its ownership proof.
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        XCTAssertEqual(generation, fixture.browser.documentGeneration(for: ownedID))
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Continue the verified session"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: ownedID))
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testChangingFirstPromptRejectsConversationPromotionAndRetainsTab() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
                history.pushState({}, '', '/c/local-chatgpt%3Afixture?temporary-chat=true');
            }); return true;
            """)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Original owned prompt"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        _ = try await evaluate(view, """
            document.querySelector('[data-message-author-role="user"]').textContent = 'A changed human prompt';
            document.querySelectorAll('[data-chatgpt-selection-conversation-id]').forEach(node =>
                node.setAttribute('data-chatgpt-selection-conversation-id', 'server-fixture'));
            history.replaceState({}, '', '/c/final-conversation?temporary-chat=true'); return true;
            """)
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not follow a changed first prompt"])
            XCTFail("A conversation promotion cannot adopt a changed first message")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser))
        }
        XCTAssertEqual(generation, fixture.browser.documentGeneration(for: ownedID))
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Original owned prompt"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testUnboundLoadingCleanupRetainsViewNavigatedAwayFromInitialRoute() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        // No provider poll has bound this document. A human changes its route.
        _ = try await evaluate(view, "history.pushState({}, '', '/c/human-conversation'); return true;")
        let finished = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
        XCTAssertEqual(view.url?.path, "/c/human-conversation")
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testDelayedSendReadinessWaitsWithoutReinsertingOrClickingTwice() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            const send = document.querySelector('[data-testid="send-button"]');
            const editor = document.getElementById('fixture-editor');
            let started = 0, readyAt = 0;
            editor.addEventListener('input', () => {
                started = performance.now(); readyAt = started + 700;
            });
            const observer = new MutationObserver(() => {
                if (!send.disabled && performance.now() < readyAt) {
                    send.disabled = true;
                    setTimeout(() => { send.disabled = false; }, Math.max(0, readyAt - performance.now()));
                }
            });
            observer.observe(send, { attributes: true, attributeFilter: ['disabled'] });
            send.addEventListener('click', () => { window.fixtureSendDelay = performance.now() - started; });
            window.fixtureSendGate = observer; return true;
            """)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let startedSending = ContinuousClock.now
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Wait for the site's Send button"])
        XCTAssertEqual(sent["state"] as? String, "running")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - startedSending, .milliseconds(600))
        let delayValue = try await evaluate(view, "return window.fixtureSendDelay;")
        let sendDelay = try XCTUnwrap(delayValue as? Double)
        XCTAssertGreaterThanOrEqual(sendDelay, 600)
        let inputCount = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(inputCount, 1)
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Wait for the site's Send button"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
    }

    func testUnavailableSendTimesOutWithoutReinsertingOrClicking() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            const send = document.querySelector('[data-testid="send-button"]');
            const observer = new MutationObserver(() => { if (!send.disabled) send.disabled = true; });
            observer.observe(send, { attributes: true, attributeFilter: ['disabled'] });
            window.fixtureSendGate = observer; return true;
            """)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let startedSending = ContinuousClock.now
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "A prompt that cannot be sent"])
            XCTFail("A permanently unavailable Send button must fail within the readiness deadline")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .editorFailure("send_unavailable"))
        }
        let elapsed = ContinuousClock.now - startedSending
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(2_800))
        XCTAssertLessThan(elapsed, .seconds(5))
        let inputCount = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(inputCount, 1)
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts, [])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
    }

    func testInitialReadFailureBeforeObserverGetsABoundedRetryWake() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.first)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await evaluate(view, "const Original = MutationObserver; globalThis.MutationObserver = function() { globalThis.MutationObserver = Original; throw new Error('fixture first inspection unavailable'); }; return true;",
                               world: .world(name: "computa-chatgpt-model-v1"))
        let loading = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(loading["state"] as? String, "loading")
        let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
        let revision = try XCTUnwrap(observedRevision)
        let began = ContinuousClock.now
        _ = try await fixture.transport.waitForChange(sessionToken: token, after: revision, until: .now + .seconds(2))
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(1), "An initial failed read has no observer to wake it")
        _ = try await waitForState("ready", fixture.transport, token: token)
        let finish = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finish["cleanup"] as? String, "not_created")
    }

    func testLateCompletionFooterStartsItsOwnQuietInterval() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Fixture late footer"])
        let tabID = try XCTUnwrap(fixture.createdTabs.first)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        _ = try await evaluate(view, "document.querySelector('button[aria-label=\"Copy\"]').disabled = true; return true;")
        _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        try await Task.sleep(for: .milliseconds(1_750))
        _ = try await evaluate(view, "document.querySelector('button[aria-label=\"Copy\"]').disabled = false; return true;")
        let began = ContinuousClock.now
        let candidate = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(candidate["state"] as? String, "running", "A late footer alone must not immediately finalize stale text")
        _ = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(1_500))
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
    }

    private func startChoice(_ choice: WebsiteModelChoice, in fixture: Fixture) async throws -> [String: Any] {
        try await call(fixture.transport, "webProviderStart", ["provider": choice.provider,
            "modelChoice": try XCTUnwrap(choice.canonicalJSONString)])
    }

    private func assertChoiceEvidence(_ snapshot: [String: Any], choice: WebsiteModelChoice,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let evidence = try WebsiteModelEvidence.parse(snapshot["modelEvidence"], provider: choice.provider, expected: choice)
        XCTAssertEqual(evidence.selected.key, choice.key, file: file, line: line)
        XCTAssertEqual(evidence.selected.label, choice.label, file: file, line: line)
        XCTAssertEqual(evidence.verification, "website_selection", file: file, line: line)
        XCTAssertNil(evidence.response, "The fixture exposes selection controls, not backend response attribution", file: file, line: line)
    }

    private func assertChoiceLedger(_ view: WKWebView, insertions: Int, sends: Int, selections: Int,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let observed = try await evaluate(view, "return {insertions: window.fixtureInputCount, sends: window.fixturePrompts.length, selections: window.fixtureModelSelectionClicks};")
        let ledger = try XCTUnwrap(observed as? [String: Int], file: file, line: line)
        XCTAssertEqual(ledger["insertions"], insertions, file: file, line: line)
        XCTAssertEqual(ledger["sends"], sends, file: file, line: line)
        XCTAssertEqual(ledger["selections"], selections, file: file, line: line)
    }

    private func assertHumanTabIntact(_ fixture: Fixture, retaining retainedID: UUID? = nil,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID] + (retainedID.map { [$0] } ?? []), file: file, line: line)
        XCTAssertEqual(fixture.browser.humanTabs.map(\.id), [fixture.humanID], file: file, line: line)
        if let retainedID {
            XCTAssertNotNil(fixture.browser.webView(for: retainedID), file: file, line: line)
            XCTAssertThrowsError(try fixture.browser.presentTab(retainedID, in: NSView())) { error in
                XCTAssertEqual(error as? EmbeddedBrowserSession.Failure, .modelTabPrivate, file: file, line: line)
            }
        }
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID, file: file, line: line)
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView, file: file, line: line)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if !fixture.humanView.isLoading,
               let marker = try await evaluate(fixture.humanView,
                    "return document.getElementById('human-marker')?.textContent;",
                    maximumWait: deadline - .now) as? String {
                XCTAssertEqual(marker, "Untouched human tab", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The untouched human fixture did not finish its initial document load", file: file, line: line)
        throw FixtureFailure.timeout
    }

    private static let choiceProviders: [EmbeddedWebModelTransport.Provider] = [.chatgpt, .gemini, .claude]

    private static func choiceLabels(_ provider: EmbeddedWebModelTransport.Provider) -> [String] {
        switch provider {
        case .chatgpt: ["Latest", "GPT-5.6 Sol", "GPT-5.5"]
        case .gemini: ["3.5 Flash-Lite", "3.8 Flash", "3.1 Pro"]
        case .claude: ["Sonnet 5.5", "Haiku 4.5", "Sonnet 5", "Sonnet 4.6"]
        }
    }

    private static func fixtureChoice(_ provider: EmbeddedWebModelTransport.Provider) -> WebsiteModelChoice {
        let label = choiceLabels(provider)[provider == .gemini ? 1 : choiceLabels(provider).count - 1]
        return WebsiteModelChoice(provider: provider.rawValue, key: label, label: label)
    }

    private static let fixtureToolReply = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf fixture"}}]}"#

    private static func familyClosingTransitionPage() -> String {
        modelChoicePage(.chatgpt, genericHeader: true, unmountClosedMenu: true)
            .replacingOccurrences(of: "window.fixtureModelSelectionClicks = 0;", with: """
                window.fixtureModelSelectionClicks = 0;
                window.fixtureModelClosingActive = false; window.fixtureModelClosingCompletions = 0;
                window.fixtureModelIgnoredClosingOpens = 0; window.fixtureModelClosingTimerStarted = false;
                window.fixtureFirstPostFamilyOpenAttempts = 0; window.fixtureFirstPostFamilyReadClosed = false;
                """)
            .replacingOccurrences(of: "window.fixtureModelTriggerClicks++;", with: """
                window.fixtureModelTriggerClicks++;
                if (window.fixtureModelSelectionClicks === 1 && !window.fixtureFirstPostFamilyReadClosed)
                  window.fixtureFirstPostFamilyOpenAttempts++;
                if (window.fixtureModelClosingActive) {
                  window.fixtureModelIgnoredClosingOpens++;
                  // Force the fresh read to arrive during the site's closing
                  // phase, then finish that phase using a genuine DOM timer.
                  // Only a subsequently mounted checked menu can prove choice.
                  if (!window.fixtureModelClosingTimerStarted) {
                    window.fixtureModelClosingTimerStarted = true;
                    setTimeout(() => {
                      window.fixtureModelClosingActive = false;
                      window.fixtureModelClosingCompletions++;
                    }, 200);
                  }
                  return;
                }
                """)
            .replacingOccurrences(of: "window.fixtureModelSelectionClicks++;", with: """
                window.fixtureModelSelectionClicks++;
                window.fixtureModelClosingActive = true;
                """)
            .replacingOccurrences(of: "window.fixtureModelEscapeClosures++;", with: """
                window.fixtureModelEscapeClosures++;
                if (window.fixtureModelSelectionClicks === 1 && window.fixtureFirstPostFamilyOpenAttempts > 0)
                  window.fixtureFirstPostFamilyReadClosed = true;
                """)
            .replacingOccurrences(of: "answerBody.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';",
                with: "answerBody.textContent = window.fixturePrompts.length === 1 ? '\(fixtureToolReply)' : '{\"type\":\"message\",\"text\":\"Fixture reply\"}';")
    }

    private static func firstSendRoutePromotionPage() -> String {
        modelChoicePage(.chatgpt, genericHeader: true, unmountClosedMenu: true)
            .replacingOccurrences(of: "answerBody.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';",
                with: "answerBody.textContent = window.fixturePrompts.length === 1 ? '\(fixtureToolReply)' : '{\"type\":\"message\",\"text\":\"Fixture reply\"}';")
    }

    /// Send still inserts and clicks once. Its user/answer DOM is committed
    /// only inside an asynchronous picker-open read after native sees the
    /// submit acknowledgment, making the count-snapshot race deterministic.
    private static func acknowledgedAppendRacePage() -> String {
        modelChoicePage(.chatgpt, genericHeader: true, unmountClosedMenu: true)
            .replacingOccurrences(of: "window.fixturePrompts = [];", with: """
                window.fixturePrompts = [];
                window.fixtureRaceArmed = false; window.fixtureRaceCorruption = 'none';
                window.fixtureDelayedPickerOpens = 0; window.fixtureRaceRenderedCounts = [];
                window.fixtureRaceRoutes = []; window.fixtureRaceRenderedRoutes = [];
                window.fixturePendingUser = null; window.fixturePendingTurn = null;
                """)
            .replacingOccurrences(of: "document.getElementById('messages').appendChild(user);",
                with: "window.fixturePendingUser = user;")
            .replacingOccurrences(of: "document.getElementById('messages').appendChild(turn);",
                with: "window.fixturePendingTurn = turn;")
            .replacingOccurrences(of: "answerBody.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';",
                with: "answerBody.textContent = window.fixturePrompts.length === 1 ? '\(fixtureToolReply)' : '{\"type\":\"message\",\"text\":\"Fixture reply\"}';")
            .replacingOccurrences(of: "if (open && !modelMenu.isConnected) document.body.appendChild(modelMenu);", with: """
                if (open && window.fixtureRaceArmed && window.fixturePendingUser) {
                  window.fixtureRaceArmed = false; window.fixtureDelayedPickerOpens++;
                  const pendingUser = window.fixturePendingUser, pendingTurn = window.fixturePendingTurn;
                  window.fixturePendingUser = null; window.fixturePendingTurn = null;
                  setTimeout(() => {
                    document.body.appendChild(modelMenu); modelMenu.style.display = 'block';
                    modelTrigger.setAttribute('aria-expanded', 'true');
                    const route = window.fixtureRaceRoutes.shift();
                    if (route) { history.pushState({}, '', route); window.fixtureRaceRenderedRoutes.push(route); }
                    const firstBody = document.querySelector('[data-message-author-role="user"] [data-markdown-text-style="user-message"]');
                    if (firstBody && window.fixtureRaceCorruption === 'changed_body')
                      firstBody.textContent = 'Changed first prompt' + firstBody.textContent.slice(firstBody.textContent.indexOf('\\n\\nComputa session marker: '));
                    if (firstBody && window.fixtureRaceCorruption === 'wrong_marker')
                      firstBody.textContent = firstBody.textContent.replace(/Computa session marker: [a-f0-9-]{36}/i,
                        'Computa session marker: 00000000-0000-0000-0000-000000000000');
                    document.getElementById('messages').appendChild(pendingUser);
                    if (pendingTurn) document.getElementById('messages').appendChild(pendingTurn);
                    window.fixtureRaceRenderedCounts.push(document.querySelectorAll('[data-message-author-role="user"]').length);
                  }, 25);
                  return;
                }
                if (open && !modelMenu.isConnected) document.body.appendChild(modelMenu);
                """)
    }

    /// A provider framework replaces an already pinned first message while the
    /// associated model popup's close acknowledgment is awaited. The exact
    /// payload remains chronological, and both old DOM objects disconnect.
    private static func firstUserReplacementRacePage(_ provider: EmbeddedWebModelTransport.Provider) -> String {
        precondition(provider == .gemini || provider == .claude)
        let rootSelector = provider == .gemini ? "user-query" : "[data-testid=\"user-message\"]"
        let bodyExpression = provider == .gemini
            ? "root.querySelector('.user-query-bubble-with-background > span.ng-star-inserted > span')"
            : "root"
        return modelChoicePage(provider, unmountClosedMenu: true)
            .replacingOccurrences(of: "window.fixturePrompts = [];", with: """
                window.fixturePrompts = [];
                window.fixtureFirstReplacementArmed = false; window.fixtureFirstReplacementCorruption = 'none';
                window.fixtureFirstReplacementCount = 0;
                window.fixtureOldRootDisconnected = false; window.fixtureOldBodyDisconnected = false;
                """)
            .replacingOccurrences(of: "body.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';",
                with: "body.textContent = window.fixturePrompts.length === 1 ? '\(fixtureToolReply)' : '{\"type\":\"message\",\"text\":\"Fixture reply\"}';")
            .replacingOccurrences(of: "modelMenu.style.display = open ? 'block' : 'none';", with: """
                if (!open && window.fixtureFirstReplacementArmed) {
                  window.fixtureFirstReplacementArmed = false;
                  setTimeout(() => {
                    const root = document.querySelector('\(rootSelector)');
                    const oldBody = \(bodyExpression);
                    if (!root || !oldBody) throw new Error('Expected pinned provider first message');
                    const replacement = root.cloneNode(true);
                    const replacementBody = \(provider == .gemini ? "replacement.querySelector('.user-query-bubble-with-background > span.ng-star-inserted > span')" : "replacement");
                    if (window.fixtureFirstReplacementCorruption === 'changed_text')
                      replacementBody.textContent = replacementBody.textContent.replace('Original', 'Changed');
                    if (window.fixtureFirstReplacementCorruption === 'wrong_marker')
                      replacementBody.textContent = replacementBody.textContent.replace(/Computa session marker: [a-f0-9-]{36}/i,
                        'Computa session marker: 00000000-0000-0000-0000-000000000000');
                    if (window.fixtureFirstReplacementCorruption === 'changed_identity') replacement.id += '-unrelated';
                    root.replaceWith(replacement); window.fixtureFirstReplacementCount++;
                    window.fixtureOldRootDisconnected = !root.isConnected;
                    window.fixtureOldBodyDisconnected = !oldBody.isConnected;
                    modelMenu.style.display = 'none'; modelTrigger.setAttribute('aria-expanded', 'false'); modelMenu.remove();
                  }, 25);
                  return;
                }
                modelMenu.style.display = open ? 'block' : 'none';
                """)
    }

    /// Actual WebKit DOM/layout, associated picker/menu roles and primary family
    /// leaves exercise the shipped scripts. Labels are synthetic menu fixtures,
    /// not an application availability catalog or model self-report.
    private static func modelChoicePage(_ provider: EmbeddedWebModelTransport.Provider,
                                        disableTarget: Bool = false, initiallySelectTarget: Bool = false,
                                        deferSelectionCommit: Bool = false, genericHeader: Bool = false,
                                        unmountClosedMenu: Bool = false, ignoreModelEscape: Bool = false,
                                        returnToParentAfterSelection: Bool = false, driftTemporaryInParent: Bool = false,
                                        hideComposerInPicker: Bool = false) -> String {
        precondition(!returnToParentAfterSelection || provider == .chatgpt)
        precondition(!(driftTemporaryInParent || hideComposerInPicker) || returnToParentAfterSelection)
        let labels = choiceLabels(provider)
        let initial = provider == .chatgpt ? labels[1] : provider == .gemini ? labels[2] : labels[0]
        let target = fixtureChoice(provider).label
        let aria = provider == .chatgpt ? "Select ChatGPT model" : provider == .gemini
            ? "Open mode picker, currently Gemini Pro" : "Model: \(initial) Medium"
        let disabled = provider == .chatgpt ? "GPT-4.9" : provider == .gemini ? "3.7 Flash" : "Opus 4.5"
        let upgrade = provider == .chatgpt ? "GPT-5.9" : provider == .gemini ? "4.0 Pro" : "Fable 5.5"
        let escapeClosesPopup = provider == .chatgpt
        let rows = labels.map { label in
            "<button role=\"menuitemradio\" aria-checked=\"false\" data-fixture-model=\"\(label)\" \(disableTarget && label == target ? "disabled" : "")><span>\(label)</span><span>Fixture description, independent of the family label</span></button>"
        }.joined()
        let picker = """
        <button id="fixture-model-trigger" aria-label="\(aria)" aria-controls="fixture-model-menu" aria-haspopup="menu" aria-expanded="false"><span id="fixture-model-header"></span></button>
        <div id="fixture-model-menu" role="menu" aria-labelledby="fixture-model-trigger" style="display:none">
        \(rows)
        <button role="menuitemradio" disabled><span>\(disabled)</span></button>
        <button role="menuitemradio"><span>\(upgrade)</span><span>Upgrade</span></button>
        <button role="menuitemradio"><span>Extended thinking</span></button>
        <button role="menuitemradio"><span>Medium</span></button>
        \(returnToParentAfterSelection ? "<button id=\"fixture-parent-option\" role=\"menuitem\" hidden>Adjust thinking time</button>" : "")
        </div>
        <script>
        window.fixtureModelInitialLabel = '\(initial)';
        window.fixtureModelSelectionClicks = 0; window.fixtureModelTriggerClicks = 0;
        window.fixtureModelEscapeEvents = 0; window.fixtureModelEscapeClosures = 0;
        const modelTrigger = document.getElementById('fixture-model-trigger');
        const modelMenu = document.getElementById('fixture-model-menu');
        \(returnToParentAfterSelection ? """
        window.fixtureModelParentActive = false; window.fixtureModelParentReturns = 0;
        window.fixtureModelParentEscapeEvents = 0; window.fixtureModelParentEscapeClosures = 0;
        window.fixtureModelFreshProofReadOpens = 0;
        window.fixtureModelTemporaryDrifted = false;
        const temporaryButtons = [document.getElementById('fixture-temporary-mode')];
        window.fixtureModelSetModalHidden = hidden => {
          for (const button of [...temporaryButtons, modelTrigger]) {
            if (hidden) button.setAttribute('aria-hidden', 'true'); else button.removeAttribute('aria-hidden');
          }
          \(hideComposerInPicker ? """
          const composerHost = document.getElementById('prompt-textarea');
          if (hidden) composerHost.setAttribute('aria-hidden', 'true'); else composerHost.removeAttribute('aria-hidden');
          """ : "")
        };
        """ : "")
        window.fixtureModelSelect = label => {
          window.fixtureModelCurrentLabel = label;
          document.getElementById('fixture-model-header').textContent = \(genericHeader ? "'ChatGPT'" : "label");
          modelMenu.querySelectorAll('[data-fixture-model]').forEach(node => node.setAttribute('aria-checked', String(node.dataset.fixtureModel === label)));
          \(provider == .claude ? "modelTrigger.setAttribute('aria-label', 'Model: ' + label + ' Medium');" : "")
        };
        modelTrigger.addEventListener('click', () => {
          window.fixtureModelTriggerClicks++;
          const open = !modelMenu.isConnected || modelMenu.style.display === 'none';
          \(escapeClosesPopup ? "if (!open) return; // Observed ChatGPT clicks do not close an already-open portal." : "")
          if (open && !modelMenu.isConnected) document.body.appendChild(modelMenu);
          modelMenu.style.display = open ? 'block' : 'none';
          modelTrigger.setAttribute('aria-expanded', String(open));
          \(returnToParentAfterSelection ? """
          modelMenu.setAttribute('data-state', open ? 'open' : 'closed');
          modelTrigger.setAttribute('data-state', open ? 'open' : 'closed');
          if (open) {
            modelMenu.querySelectorAll('[role="menuitemradio"]').forEach(node => { node.hidden = false; });
            document.getElementById('fixture-parent-option').hidden = true;
            if (window.fixtureModelParentEscapeClosures === 1) window.fixtureModelFreshProofReadOpens++;
          }
          window.fixtureModelSetModalHidden(open);
          """ : "")
          \(unmountClosedMenu ? "if (!open) modelMenu.remove();" : "")
        });
        \(escapeClosesPopup ? """
        document.addEventListener('keydown', event => {
          if (event.key !== 'Escape' || !modelMenu.isConnected || modelMenu.style.display === 'none'
            || !(event.target === document || event.target === modelTrigger || modelMenu.contains(event.target))) return;
          window.fixtureModelEscapeEvents++;
          \(returnToParentAfterSelection ? "if (window.fixtureModelParentActive) window.fixtureModelParentEscapeEvents++;" : "")
          \(ignoreModelEscape ? "return; // The owned popup intentionally ignores this one close request." : "")
          event.preventDefault();
          modelMenu.style.display = 'none'; modelTrigger.setAttribute('aria-expanded', 'false');
          \(returnToParentAfterSelection ? """
          modelMenu.setAttribute('data-state', 'closed'); modelTrigger.setAttribute('data-state', 'closed');
          window.fixtureModelSetModalHidden(false);
          if (window.fixtureModelParentActive) {
            window.fixtureModelParentActive = false; window.fixtureModelParentEscapeClosures++;
          }
          """ : "")
          \(unmountClosedMenu ? "modelMenu.remove();" : "")
          modelTrigger.focus(); window.fixtureModelEscapeClosures++;
        });
        """ : "")
        modelMenu.querySelectorAll('[data-fixture-model]').forEach(node => node.addEventListener('click', () => {
          window.fixtureModelSelectionClicks++;
          \(deferSelectionCommit ? "window.fixturePendingModelSelection = node.dataset.fixtureModel;" : "window.fixtureModelSelect(node.dataset.fixtureModel);")
          \(returnToParentAfterSelection ? """
          window.fixtureModelParentActive = true; window.fixtureModelParentReturns++;
          modelMenu.querySelectorAll('[role="menuitemradio"]').forEach(row => { row.hidden = true; });
          document.getElementById('fixture-parent-option').hidden = false;
          modelMenu.style.display = 'block'; modelTrigger.setAttribute('aria-expanded', 'true');
          modelMenu.setAttribute('data-state', 'open'); modelTrigger.setAttribute('data-state', 'open');
          window.fixtureModelSetModalHidden(true);
          \(driftTemporaryInParent ? """
          temporaryButtons[0].setAttribute('aria-label', 'Start temporary chat');
          temporaryButtons[0].textContent = 'Start temporary chat'; window.fixtureModelTemporaryDrifted = true;
          """ : "")
          return; // The actual family choice returns to its associated primary popup.
          """ : "")
          modelMenu.style.display = 'none'; modelTrigger.setAttribute('aria-expanded', 'false');
          \(unmountClosedMenu ? "modelMenu.remove();" : "")
        }));
        window.fixtureModelSelect('\(initiallySelectTarget ? target : initial)');
        \(unmountClosedMenu ? "modelMenu.remove();" : "")
        </script>
        """
        let base = provider == .chatgpt ? page : providerPage(provider)
        return base.replacingOccurrences(of: "</body>", with: picker + "</body>")
    }

    private func call(_ transport: EmbeddedWebModelTransport, _ operation: String,
                      _ params: [String: String]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params)
        let response: Data
        do { response = try await transport.request(operation: operation, params: data) }
        catch {
            if !(error is EmbeddedWebModelTransport.Failure) {
                print("Unexpected fixture transport failure: operation=\(operation) type=\(String(reflecting: type(of: error))) domain=\((error as NSError).domain) code=\((error as NSError).code)")
            }
            throw error
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    private func capturedUserPrompts(_ view: WKWebView) async throws -> [String]? {
        let value = try await evaluate(view, "return window.fixturePrompts;")
        var prompts = try XCTUnwrap(value as? [String])
        if let first = prompts.first {
            // The transport-only suffix must be fresh UUID-shaped metadata at
            // the end; preserve every original character before that suffix.
            let suffix = try XCTUnwrap(first.range(of: #"\n\nComputa session marker: [A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\n?$"#, options: .regularExpression))
            prompts[0] = String(first[..<suffix.lowerBound])
            if first.hasSuffix("\n") { prompts[0] += "\n" }
            XCTAssertFalse(prompts.dropFirst().contains { $0.contains("Computa session marker:") }, "Only the first website submission carries transport metadata")
        }
        return prompts
    }

    private func waitForState(_ state: String, _ transport: EmbeddedWebModelTransport,
                              token: String) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(10)
        var last: [String: Any] = [:]
        while ContinuousClock.now < deadline {
            let observedRevision = try await transport.changeRevision(sessionToken: token)
            let revision = try XCTUnwrap(observedRevision)
            last = try await call(transport, "webProviderPoll", ["sessionToken": token])
            if last["state"] as? String == state { return last }
            if ["failed", "needs_sign_in"].contains(last["state"] as? String ?? "") {
                XCTFail("Fixture provider failed while waiting for \(state): \(last)")
                throw FixtureFailure.unexpectedState
            }
            _ = try await transport.waitForChange(sessionToken: token, after: revision, until: deadline)
        }
        XCTFail("Fixture did not reach \(state): \(last)")
        throw FixtureFailure.timeout
    }

    private func assertRejected(_ transport: EmbeddedWebModelTransport, _ operation: String,
                                _ params: [String: String], file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let result = try await call(transport, operation, params)
            XCTFail("Expected rejection, received \(result)", file: file, line: line)
        } catch { }
    }

    private func waitForFixture(_ view: WKWebView, generation: String = "initial") async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if !view.isLoading,
               let loaded = try await evaluate(view,
                    "return window.fixtureReady === true ? window.fixtureGeneration : null;",
                    maximumWait: deadline - .now),
               loaded as? String == generation { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The synthetic provider document did not load (expectedGeneration=\(generation), isLoading=\(view.isLoading), urlPresent=\(view.url != nil))")
        throw FixtureFailure.timeout
    }

    private func evaluate(_ view: WKWebView, _ body: String, world: WKContentWorld = .page,
                          maximumWait: Duration = .seconds(10)) async throws -> Any? {
        let completion = FixtureScriptResult()
        let data: Data
        do {
        data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let timeout = Task {
                    do {
                        try await Task.sleep(for: maximumWait)
                        completion.complete(.failure(FixtureFailure.evaluationTimeout))
                    } catch { }
                }
                completion.setTimeout(timeout)
                guard completion.isPending else { return }
                view.callAsyncJavaScript(body, arguments: [:], in: nil, in: world) { result in
                    switch result {
                    case .success(let value):
                        do {
                            let serialized = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
                            completion.complete(.success(serialized))
                        } catch {
                            completion.complete(.failure(error))
                        }
                    case .failure(let error):
                        completion.complete(.failure(error))
                    }
                }
            }
        } onCancel: {
            completion.complete(.failure(CancellationError()))
        }
        } catch {
            print("Unexpected fixture evaluation failure: type=\(String(reflecting: type(of: error))) domain=\((error as NSError).domain) code=\((error as NSError).code)")
            throw error
        }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func armFixtureAppendDuringDigest(_ view: WKWebView) async throws {
        _ = try await evaluate(view, """
            const original = crypto.subtle.digest.bind(crypto.subtle);
            let armed = true;
            crypto.subtle.digest = async (...digestArguments) => {
              const digest = await original(...digestArguments);
              if (armed) {
                armed = false;
                await new Promise(resolve => setTimeout(() => {
                  document.dispatchEvent(new Event('fixture-append-pending-user'));
                  resolve();
                }, 0));
              }
              return digest;
            };
            return true;
            """, world: WKContentWorld.world(name: "computa-chatgpt-model-v1"))
    }

    private enum FixtureFailure: Error { case timeout, evaluationTimeout, unexpectedState }

    @MainActor
    private final class FixtureRenderWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    @MainActor
    private final class Fixture {
        let browser: EmbeddedBrowserSession
        let renderWindow: FixtureRenderWindow
        let renderHost: EmbeddedModelRenderContainer
        let humanID: UUID
        let humanView: WKWebView
        var createdTabs: [UUID] = []
        var page: String
        var initialURL: URL?
        private(set) var transport: EmbeddedWebModelTransport!

        init(page: String = EmbeddedWebModelTransportTests.page, initialURL: URL? = nil,
             browser: EmbeddedBrowserSession = EmbeddedBrowserSession(persistent: false)) throws {
            self.browser = browser
            self.page = page
            self.initialURL = initialURL
            // Match the application's nonhidden model render surface. An
            // unattached WKWebView reports hidden visibility and cannot prove
            // actual render commits through requestAnimationFrame callbacks.
            renderWindow = FixtureRenderWindow(contentRect: NSRect(x: 20, y: 20, width: 1_024, height: 768),
                                                styleMask: [], backing: .buffered, defer: false)
            renderWindow.isReleasedWhenClosed = false
            renderWindow.ignoresMouseEvents = true
            renderHost = EmbeddedModelRenderContainer(session: browser)
            renderHost.frame = NSRect(x: 0, y: 0, width: 1_024, height: 768)
            renderWindow.contentView = renderHost
            browser.installModelRenderHost(renderHost)
            renderWindow.orderBack(nil)
            humanID = try browser.createTab()
            humanView = try XCTUnwrap(browser.webView(for: humanID))
            humanView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            humanView.loadHTMLString("<p id='human-marker'>Untouched human tab</p>", baseURL: URL(string: "https://example.test/"))
            transport = EmbeddedWebModelTransport(browser: browser, createTabForTesting: { [unowned self] url in
                // Load only the local fixture, retaining the product's model
                // ownership, render-host mounting, and inactive-tab behavior.
                let id = try self.browser.createUnloadedModelTabForTesting()
                let view = try XCTUnwrap(self.browser.webView(for: id))
                view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
                view.loadHTMLString(self.page, baseURL: self.initialURL ?? url)
                self.createdTabs.append(id)
                return id
            })
        }

        func shutdown() {
            browser.shutdown()
            renderHost.detach()
            renderWindow.orderOut(nil)
            renderWindow.close()
        }
    }

    private static var freshClaudeQuotaBannerPage: String {
        let banner = #"""
        <div id="fixture-quota-banner"><p>You are out of free <a data-fixture-quota-link href="https://support.claude.com/en/articles/11647753-understanding-usage-and-length-limits"><span>messages</span><span hidden>private_canary accessibility suffix</span></a> until 11:40 PM</p><a data-fixture-quota-link href="https://claude.ai/upgrade?hide_free=true&amp;from=ratelimit">Upgrade</a></div>
        """#
        return providerPage(.claude)
            .replacingOccurrences(of: #"<div id="messages"></div>"#, with: banner + #"<div id="messages"></div>"#)
            .replacingOccurrences(of: "window.fixtureGeneration = 'initial'; window.fixtureReady = true;", with: """
                window.fixtureFocusCount = 0; window.fixtureQuotaClicks = 0;
                editor.addEventListener('focus', () => { window.fixtureFocusCount++; });
                document.querySelectorAll('[data-fixture-quota-link]').forEach(link =>
                  link.addEventListener('click', () => { window.fixtureQuotaClicks++; }));
                window.fixtureGeneration = 'initial'; window.fixtureReady = true;
                """)
    }

    private static func delayedGeminiSecondUserPage(mutatesFirstBody: Bool = false) -> String {
        providerPage(.gemini).replacingOccurrences(of: "document.getElementById('messages').appendChild(user);", with: """
            if (window.fixturePrompts.length === 2) {
              window.fixtureDelayedAppends = 0;
              document.addEventListener('fixture-append-pending-user', () => {
                document.getElementById('messages').appendChild(user);
                window.fixtureDelayedAppends++;
                \(mutatesFirstBody ? "const first = document.querySelector('user-query .user-query-bubble-with-background > span.ng-star-inserted > span'); first.textContent = first.textContent.replace('Preserve', 'Substitute');" : "")
              }, { once: true });
            } else document.getElementById('messages').appendChild(user);
            """)
    }

    private static func providerPage(_ provider: EmbeddedWebModelTransport.Provider) -> String {
        precondition(provider != .chatgpt)
        let temporary = provider == .claude
            ? #"<button data-fixture-temporary aria-label="Exit incognito">Exit incognito</button><div data-fixture-temporary class="animate-incognito-header-in"><span>Incognito chat</span></div>"#
            : #"<button data-fixture-temporary aria-label="Turn off temporary chat">Temporary Chat</button><h1 data-fixture-temporary>Just stopping by?</h1><span data-fixture-temporary class="info-text">Temporary Chat</span>"#
        let editor = provider == .claude
            ? #"<div id="fixture-editor" class="ProseMirror" data-testid="chat-input" role="textbox" contenteditable="true"><p><br class="ProseMirror-trailingBreak"></p></div>"#
            : #"<rich-textarea><div id="fixture-editor" class="ql-editor" contenteditable="true"></div></rich-textarea>"#
        let send = provider == .claude
            ? #"<button id="fixture-send" data-testid="chat-input-send" aria-label="Send message" disabled>Send</button>"#
            : #"<button id="fixture-send" aria-label="Send message" disabled>Send</button>"#
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 20px; } #fixture-editor { min-height: 50px; width: 600px; white-space: pre-wrap; }
        .fixture-user { white-space: pre-wrap; }
        .ql-editor p { margin: 0; padding: 0; }
        </style></head><body>\(temporary)<div id="messages"></div>\(editor)\(send)<script>
        window.fixturePrompts = []; window.fixtureInputCount = 0;
        const editor = document.getElementById('fixture-editor');
        const send = document.getElementById('fixture-send');
        editor.addEventListener('input', () => {
          window.fixtureInputCount++; send.disabled = true;
          setTimeout(() => { send.disabled = !editor.innerText.trim(); }, 15);
        });
        send.addEventListener('click', () => {
          const prompt = editor.innerText;
          window.fixturePrompts.push(prompt);
          const user = document.createElement('\(provider == .claude ? "div" : "user-query")');
          user.className = 'fixture-user';
          \(provider == .claude ? "user.setAttribute('data-testid', 'user-message'); user.id = 'user-' + window.fixturePrompts.length;" : "")
          \(provider == .claude ? "user.textContent = prompt;" : """
          const container = document.createElement('span'); container.className = 'user-query-container';
          const host = document.createElement('div'); const layout = document.createElement('div');
          layout.className = 'user-query-container';
          const content = document.createElement('div'); content.className = 'query-content ng-star-inserted';
          const status = document.createElement('div'); status.className = 'query-bubble-with-status ng-star-inserted';
          const background = document.createElement('span'); background.className = 'user-query-bubble-with-background ng-star-inserted';
          const payload = document.createElement('span'); payload.className = 'ng-star-inserted';
          const literal = document.createElement('span'); literal.textContent = prompt; payload.appendChild(literal);
          const controls = document.createElement('div'); controls.className = 'ng-star-inserted';
          const edit = document.createElement('button'); edit.setAttribute('aria-label', 'Edit prompt'); controls.appendChild(edit);
          background.append(payload, controls); status.appendChild(background); content.appendChild(status);
          layout.appendChild(content); host.appendChild(layout); container.appendChild(host); user.appendChild(container);
          """)
          document.getElementById('messages').appendChild(user);
          editor.replaceChildren(); send.disabled = true;
          const turn = document.createElement('\(provider == .claude ? "section" : "model-response")');
          \(provider == .claude ? "turn.setAttribute('role', 'article'); turn.id = 'answer-' + window.fixturePrompts.length;" : "")
          const answer = document.createElement('div');
          \(provider == .claude ? "answer.setAttribute('data-testid', 'assistant-message'); answer.setAttribute('data-is-streaming', 'false');" : "answer.className = 'model-response-text';")
          const body = document.createElement('div');
          \(provider == .claude ? "body.setAttribute('data-perf-reply-text', '');" : "body.className = 'markdown';")
          body.textContent = '{"type":"message","text":"Fixture reply"}'; answer.appendChild(body);
          turn.appendChild(answer);
          const actions = document.createElement('div'); actions.setAttribute('data-testid', 'message-actions');
          const copy = document.createElement('button'); copy.setAttribute('aria-label', 'Copy');
          copy.setAttribute('data-testid', 'action-bar-copy'); copy.setAttribute('data-test-id', 'copy-button');
          copy.textContent = 'Copy'; actions.appendChild(copy); turn.appendChild(actions);
          document.getElementById('messages').appendChild(turn);
        });
        window.fixtureGeneration = 'initial'; window.fixtureReady = true;
        </script></body></html>
        """
    }

    private static let page = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <style>body { margin: 20px; } .ProseMirror { min-height: 50px; width: 600px; white-space: pre-wrap; } .ProseMirror p { margin: 0; }</style>
    </head><body>
    <div id="fixture-composer-mode" role="group" aria-label="Composer mode">
      <button id="fixture-chat-mode" aria-pressed="true">Chat</button>
      <button id="fixture-work-mode" aria-pressed="false">Work</button>
    </div>
    <button id="fixture-temporary-mode" aria-label="Temporary chat">Temporary chat</button>
    <div id="messages"></div>
    <div id="prompt-textarea"><div id="fixture-editor" class="ProseMirror" contenteditable="true" aria-label="Ask ChatGPT"><p><br class="ProseMirror-trailingBreak"></p></div></div>
    <button data-testid="send-button" aria-label="Send prompt" disabled>Send</button>
    <script>
    window.fixturePrompts = [];
    window.fixtureChatModeClicks = 0; window.fixtureTemporaryModeClicks = 0;
    document.getElementById('fixture-chat-mode').addEventListener('click', () => {
      window.fixtureChatModeClicks++;
      document.getElementById('fixture-chat-mode').setAttribute('aria-pressed', 'true');
      document.getElementById('fixture-work-mode').setAttribute('aria-pressed', 'false');
    });
    document.getElementById('fixture-work-mode').addEventListener('click', () => {
      document.getElementById('fixture-chat-mode').setAttribute('aria-pressed', 'false');
      document.getElementById('fixture-work-mode').setAttribute('aria-pressed', 'true');
    });
    document.getElementById('fixture-temporary-mode').addEventListener('click', event => {
      window.fixtureTemporaryModeClicks++;
      event.currentTarget.setAttribute('aria-label', 'Turn off temporary chat');
      document.getElementById('fixture-composer-mode').hidden = true;
      history.replaceState({}, '', '/?temporary-chat=true');
    });
    window.fixtureFocusClears = 0;
    window.fixtureInputCount = 0;
    window.fixtureNormalizationCount = 0;
    const editor = document.getElementById('fixture-editor');
    editor.addEventListener('focus', () => {
      window.getSelection().removeAllRanges();
      window.fixtureFocusClears += 1;
    });
    editor.addEventListener('input', () => {
      window.fixtureInputCount += 1;
      document.querySelector('[data-testid="send-button"]').disabled = true;
      // ProseMirror reconciles a DOM edit asynchronously. Derive this model
      // from the actual DOM, preserving paragraph and hard-break semantics;
      // do not reconstruct it from the insertion event's supplied data.
      setTimeout(() => {
        const textOf = node => {
          if (node.nodeType === Node.TEXT_NODE) return node.data;
          if (node.nodeType !== Node.ELEMENT_NODE) return '';
          if (node.tagName === 'BR') return node.classList.contains('ProseMirror-trailingBreak') ? '' : '\n';
          return [...node.childNodes].map(textOf).join('');
        };
        const text = [...editor.childNodes].map(textOf).join('\n');
        const paragraph = document.createElement('p');
        const lines = text.split('\n');
        lines.forEach((line, index) => {
          if (index) paragraph.appendChild(document.createElement('br'));
          const mark = document.createElement('span');
          mark.setAttribute('data-fixture-normalized-text', 'true');
          mark.appendChild(document.createTextNode(line));
          paragraph.appendChild(mark);
        });
        if (!text || text.endsWith('\n')) {
          const trailing = document.createElement('br');
          trailing.className = 'ProseMirror-trailingBreak';
          paragraph.appendChild(trailing);
        }
        editor.replaceChildren(paragraph);
        window.fixtureNormalizationCount += 1;
        document.querySelector('[data-testid="send-button"]').disabled = !text.trim();
      }, 15);
    });
    document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
      const composer = document.getElementById('fixture-editor');
      const prompt = composer.innerText;
      window.fixturePrompts.push(prompt);
      const user = document.createElement('div');
      user.setAttribute('data-message-author-role', 'user');
      const userBody = document.createElement('div');
      userBody.setAttribute('data-markdown-text-style', 'user-message');
      userBody.style.whiteSpace = 'pre-wrap';
      if (window.fixtureRenderMarkdown) {
        prompt.split(/(`[^`]+`)/).forEach(part => {
          if (part.startsWith('`')) {
            const code = document.createElement('code');
            code.textContent = part.slice(1, -1); userBody.appendChild(code);
          } else userBody.appendChild(document.createTextNode(part));
        });
      } else userBody.textContent = prompt;
      user.appendChild(userBody);
      document.getElementById('messages').appendChild(user);
      composer.innerHTML = '<p><br class="ProseMirror-trailingBreak"></p>';
      document.querySelector('[data-testid="send-button"]').disabled = true;
      const turn = document.createElement('section');
      const answer = document.createElement('div');
      answer.setAttribute('data-markdown-text-style', 'assistant-message');
      answer.setAttribute('data-chatgpt-selection-conversation-id', 'fixture-conversation');
      const answerBody = document.createElement('div');
      answerBody.setAttribute('data-markdown-text-style', 'assistant-message');
      answerBody.textContent = '{"type":"message","text":"Fixture reply"}';
      answer.appendChild(answerBody);
      turn.appendChild(answer);
      const controls = document.createElement('div');
      controls.className = 'turn-action-controls';
      const copy = document.createElement('button');
      copy.setAttribute('aria-label', 'Copy');
      copy.textContent = 'Copy';
      controls.appendChild(copy);
      turn.appendChild(controls);
      document.getElementById('messages').appendChild(turn);
    });
    window.fixtureGeneration = 'initial';
    window.fixtureReady = true;
    </script></body></html>
    """#
}

/// WebKit may finish after a test's timeout or cancellation. Only the first
/// result resumes the continuation; every later callback is ignored.
private final class FixtureScriptResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var completed: Result<Data, Error>?
    private var timeout: Task<Void, Never>?

    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return completed == nil
    }

    func install(_ value: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let completed { lock.unlock(); value.resume(with: completed) }
        else { continuation = value; lock.unlock() }
    }

    func setTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if completed != nil { lock.unlock(); task.cancel() }
        else { timeout = task; lock.unlock() }
    }

    func complete(_ value: Result<Data, Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = value
        let pending = continuation; continuation = nil
        let timer = timeout; timeout = nil
        lock.unlock()
        timer?.cancel()
        pending?.resume(with: value)
    }
}

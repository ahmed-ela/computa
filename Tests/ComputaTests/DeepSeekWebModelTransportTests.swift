import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

/// Synthetic observed DOM, never a claim of live streaming or provider qualification.
@MainActor
final class DeepSeekWebModelTransportTests: XCTestCase {
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")

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
                view.loadHTMLString(html, baseURL: url)
                return id
            })
            transport.setTimeoutsForTesting(preparation: preparationTimeout, response: .seconds(12))
        }
        func shutdown() {
            browser.shutdown(); host.detach(); window.orderOut(nil); window.close()
        }
    }
}

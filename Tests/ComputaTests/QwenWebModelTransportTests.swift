import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class QwenWebModelTransportTests: XCTestCase {
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")

    func testServerReleasesEachObservedModelStreamOnlyAfterDurableOwnedDeletion() async throws {
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let choice = WebsiteModelChoice(provider: "qwen", key: label, label: label)
            try await assertSavedProviderServerStream(transport: fixture.transport, provider: .qwen,
                modelID: choice.modelID, selection: .model(choice), expectedText: "Synthetic Qwen native reply")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testDiscoveryValidatesFullMenuButExportsOnlyAdmittedPlusAndMax() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let choices = try await fixture.transport.discoverModels(provider: "qwen")
        XCTAssertEqual(Set(choices.map(\.key)), ["Qwen3.7-Plus", "Qwen3.8-Max"])
        XCTAssertTrue(choices.allSatisfy { $0.provider == "qwen" && $0.key == $0.label })
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testClaimedPickerCloseWaitsForBothDOMAndARIAWithoutRepeatingInput() async throws {
        for order in ["ariaFirst", "domFirst"] {
            let fixture = try Fixture(setup: "qwenFixture.options.modelCloseOrder = '\(order)';")
            defer { fixture.shutdown() }
            fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(5))
            var observedSplit = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "discoverModels", !observedSplit,
                    let state = try? await self.evaluate(fixture.view, "return qwenFixture.pickerState();") as? [String: Any],
                    state["pending"] as? Bool == true else { return }
                observedSplit = true
                XCTAssertEqual(state["expanded"] as? String, order == "ariaFirst" ? "false" : "true")
                XCTAssertEqual(state["visible"] as? Bool, order == "ariaFirst")
                let counts = try? await self.evaluate(fixture.view,
                    "return [qwenFixture.counts.modelOpens,qwenFixture.counts.modelCloses,qwenFixture.counts.modelSelections,qwenFixture.counts.input,qwenFixture.counts.sends];")
                XCTAssertEqual(counts as? [Int], [1,1,0,0,0])
                _ = try? await self.evaluate(fixture.view,
                    "setTimeout(() => qwenFixture.finishPickerClose(), 100); return true;")
            }
            let choices = try await fixture.transport.discoverModels(provider: "qwen")
            XCTAssertTrue(observedSplit)
            XCTAssertEqual(Set(choices.map(\.key)), ["Qwen3.7-Plus", "Qwen3.8-Max"])
            let counts = try await evaluate(fixture.view,
                "return [qwenFixture.counts.modelOpens,qwenFixture.counts.modelCloses,qwenFixture.counts.modelSelections,qwenFixture.counts.input,qwenFixture.counts.sends];")
            XCTAssertEqual(counts as? [Int], [1,1,0,0,0])
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testClaimedPickerCloseRejectsReplacedMenuOrCheckedRowWithoutAnotherClick() async throws {
        for selector in [".wms-list", ".wms-list__item--selected"] {
            let fixture = try Fixture(setup: "qwenFixture.options.modelCloseOrder = 'ariaFirst';")
            defer { fixture.shutdown() }
            fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(5))
            var replaced = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "discoverModels", !replaced,
                    let state = try? await self.evaluate(fixture.view, "return qwenFixture.pickerState();") as? [String: Any],
                    state["pending"] as? Bool == true else { return }
                replaced = true
                _ = try? await self.evaluate(fixture.view,
                    "const node=document.querySelector('\(selector)'); node.replaceWith(node.cloneNode(true)); return true;")
            }
            do {
                _ = try await fixture.transport.discoverModels(provider: "qwen")
                XCTFail("A replacement must not inherit the claimed close")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnverified) }
            XCTAssertTrue(replaced)
            let counts = try await evaluate(fixture.view,
                "return [qwenFixture.counts.modelOpens,qwenFixture.counts.modelCloses,qwenFixture.counts.modelSelections,qwenFixture.counts.input,qwenFixture.counts.sends];")
            XCTAssertEqual(counts as? [Int], [1,1,0,0,0])
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        }
    }

    func testUnfinishedPickerCloseKeepsPreparationDeadlineWithoutAnotherClick() async throws {
        let fixture = try Fixture(setup: "qwenFixture.options.modelCloseOrder = 'ariaFirst';")
        defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(5))
        do {
            _ = try await fixture.transport.discoverModels(provider: "qwen")
            XCTFail("One channel cannot verify a close")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .preparationDeadline) }
        let counts = try await evaluate(fixture.view,
            "return [qwenFixture.counts.modelOpens,qwenFixture.counts.modelCloses,qwenFixture.counts.modelSelections,qwenFixture.counts.input,qwenFixture.counts.sends];")
        XCTAssertEqual(counts as? [Int], [1,1,0,0,0])
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testClaimedModelOptionCloseWaitsThenReopensForCheckedRowVerification() async throws {
        for order in ["ariaFirst", "domFirst"] {
            let fixture = try Fixture(setup: "qwenFixture.options.modelOptionCloseOrder = '\(order)';")
            defer { fixture.shutdown() }
            fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(5))
            var observedSplit = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "selectModel", !observedSplit,
                    let state = try? await self.evaluate(fixture.view, "return qwenFixture.pickerState();") as? [String: Any],
                    state["optionPending"] as? Bool == true else { return }
                observedSplit = true
                XCTAssertEqual(state["expanded"] as? String, order == "ariaFirst" ? "false" : "true")
                XCTAssertEqual(state["visible"] as? Bool, order == "ariaFirst")
                let counts = try? await self.evaluate(fixture.view,
                    "return [qwenFixture.counts.modelOpens,qwenFixture.counts.modelCloses,qwenFixture.counts.modelSelections,qwenFixture.counts.input,qwenFixture.counts.sends];")
                XCTAssertEqual(counts as? [Int], [1,0,1,0,0])
                _ = try? await self.evaluate(fixture.view,
                    "setTimeout(() => qwenFixture.finishOptionClose(), 100); return true;")
            }
            let token = try await start(fixture, label: "Qwen3.7-Plus")
            XCTAssertTrue(observedSplit)
            let counts = try await evaluate(fixture.view,
                "return [qwenFixture.counts.modelOpens,qwenFixture.counts.modelCloses,qwenFixture.counts.modelSelections,qwenFixture.counts.input,qwenFixture.counts.sends];")
            XCTAssertEqual(counts as? [Int], [2,1,1,0,0])
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testObservedPlusAndMaxUseOneExactRawReplyAndVerifiedSavedDeletion() async throws {
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let token = try await start(fixture, label: label)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic exact Qwen café 👋")
            let complete = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic Qwen native reply"}"#)
            let snapshot = try await evaluate(fixture.view, "return qwenFixture.snapshot();") as? [String: Any]
            XCTAssertEqual(snapshot?["model"] as? String, label)
            let finished = try await call(fixture, "webProviderFinish", token)
            let repeated = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            XCTAssertEqual(repeated["cleanup"] as? String, "deleted")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
        }
    }

    func testPreparedHarnessPromptAndLiteralCharactersSurviveOneTextareaInput() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let choice = WebsiteModelChoice(provider: "qwen", key: "Qwen3.8-Max", label: "Qwen3.8-Max")
        let bytes = try JSONSerialization.data(withJSONObject: ["model": choice.modelID,
            "instructions": ComputaAgentInstructions.developerInstructions(embeddedBrowserTools: true),
            "input": "Read the synthetic fixture without external actions.",
            "tools": [["type": "function", "name": "exec_command", "parameters": ["type": "object",
                "properties": ["cmd": ["type": "string"]], "required": ["cmd"]]]]
        ] as [String: Any])
        let request = try WebModelResponseCodec.prepareRequest(bytes)
        let prompt = request.prompt + "\nLiteral \"double\" 'single' &amp; <tag> \\ path.\n\t  spaces\u{00a0} café e\u{301} 👋\n\n"
        _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
        _ = try await wait(fixture, token, state: "complete")
        let echoValue = try await evaluate(fixture.view, "return document.querySelector('p.user-message-content').textContent;")
        let echo = try XCTUnwrap(echoValue as? String)
        let prefix = prompt + "\n\nComputa session marker: "
        XCTAssertTrue(echo.hasPrefix(prefix))
        XCTAssertNotNil(UUID(uuidString: String(echo.dropFirst(prefix.count))))
        let events = try await evaluate(fixture.view, "return qwenFixture.counts.input;")
        XCTAssertEqual(events as? Int, 1)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
    }

    func testDelayedCanonicalRouteAndFirstBodyCannotPublishOrResend() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "qwenFixture.options.holdRoot = true; qwenFixture.options.delayUser = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic delayed Qwen ownership")
        for step in ["return true;", "qwenFixture.canonicalize(); return true;"] {
            _ = try await evaluate(fixture.view, step)
            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["state"] as? String, "running")
            XCTAssertEqual(pending["text"] as? String, "")
        }
        _ = try await evaluate(fixture.view, "qwenFixture.appendUser(); return true;")
        _ = try await wait(fixture, token, state: "complete")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testDelayedDeletionStagesCoalesceFinishAndCancelWithoutRepeatedMutations() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "qwenFixture.options.menuDelayMs = 120; qwenFixture.options.dialogDelayMs = 120; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic delayed deletion")
        _ = try await wait(fixture, token, state: "complete")
        let first = Task { try await self.call(fixture, "webProviderFinish", token)["cleanup"] as? String }
        let second = Task { try await self.call(fixture, "webProviderCancel", token)["cleanup"] as? String }
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, "deleted"); XCTAssertEqual(b, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testChangedCanonicalConversationCannotDeleteOrAcceptAnotherReply() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic route drift")
        _ = try await wait(fixture, token, state: "complete")
        _ = try await evaluate(fixture.view, "history.replaceState({}, '', '/c/22221111-abcd-4333-8444-555555555555'); return true;")
        let failed = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(failed["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testLostSendAcknowledgementCannotReplayOrGrantDeletionAuthority() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, """
            const original = HTMLElement.prototype.click;
            HTMLElement.prototype.click = function() {
              const send = this.classList.contains('send-button'); original.call(this);
              if (send) throw new Error('Synthetic lost Send acknowledgement');
            }; return true;
            """, world: world)
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic uncertain Qwen send")
            XCTFail("No acknowledgement after thrown Send")
        } catch { }
        let failed = try await call(fixture, "webProviderFinish", token)
        let retried = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(failed["cleanup"] as? String, "failed")
        XCTAssertEqual(retried["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
    }

    func testStreamingCancellationDeletesOnlyBoundOwnedConversation() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "qwenFixture.options.holdResponse = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic streaming cleanup")
        let running = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(running["state"] as? String, "running")
        let cancelled = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(cancelled["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testNeverSubmittedPageClosesWithoutDeletion() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
    }

    private func start(_ fixture: Fixture, label: String = "Qwen3.8-Max") async throws -> String {
        let choice = WebsiteModelChoice(provider: "qwen", key: label, label: label)
        let parameters = ["provider": "qwen", "modelChoice": try XCTUnwrap(choice.canonicalJSONString)]
        let data = try await fixture.transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: parameters))
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
        let actual = try await evaluate(fixture.view, "return [qwenFixture.counts.sends, qwenFixture.counts.headerOpens, qwenFixture.counts.deleteSelections, qwenFixture.counts.confirmations];") as? [Int]
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
        init(setup: String = "") throws {
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
                view.loadHTMLString(QwenFixturePage.html + "<script>" + setup + "</script>", baseURL: url)
                return id
            })
        }
        func shutdown() {
            browser.shutdown(); host.detach(); window.orderOut(nil); window.close()
        }
    }
}

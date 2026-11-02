import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class KimiWebModelTransportTests: XCTestCase {
    private let choice = WebsiteModelChoice(provider: "kimi", key: "k28-instant", label: "Instant")
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")

    func testDiscoveryExportsOnlyPlainChatInstantWithoutSendingOrDeleting() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertEqual(choices, [choice], "The observed menu also contains two unqualified agent choices")
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testOneExactUnicodeSubmissionCompletesAndDeletesOnlyItsOwnedChat() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let prompt = "Synthetic café 👋\nActual \\ and \"quoted\" content"
        _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
        let complete = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Offline Kimi fixture reply"}"#)
        let prompts = try await evaluate(fixture.view, "return fixturePrompts;") as? [String]
        XCTAssertEqual(prompts?.count, 1)
        XCTAssertTrue(prompts?.first?.hasPrefix(prompt + "\n\nComputa session marker: ") == true)
        let finished = try await call(fixture, "webProviderFinish", token)
        let repeated = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        XCTAssertEqual(repeated["cleanup"] as? String, "deleted")
        XCTAssertEqual(finished["temporary"] as? Bool, false)
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testFullHarnessPromptPreservesCodeWhitespaceQuotesAndMarkupLiterally() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let parameters: [String: Any] = [
            "model": choice.modelID,
            "instructions": ComputaAgentInstructions.developerInstructions(embeddedBrowserTools: true),
            "input": "Use the browser, terminal and patch tools only with their actual schemas. This is an offline insertion fixture.",
            "tools": [
                ["type": "function", "name": "exec_command", "description": "Run a command in the fixture workspace",
                 "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]], "required": ["cmd"], "additionalProperties": false]],
                ["type": "function", "name": "browser_open", "description": "Open an owned task tab",
                 "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"], "additionalProperties": false]],
                ["type": "custom", "name": "apply_patch", "format": ["type": "text"]],
            ]
        ]
        let prepared = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: parameters))
        let literal = "Straight \"double\" and 'single' quotes; -- dash; literal &amp; and <tag>.\n"
            + "  {\"indented\": \"two  spaces\", \"path\": \"C:\\fixture\"}\n"
            + "\tTab\tseparated; literal NBSP:\u{00a0}; café e\u{301} 👋\r\n"
            + "</script><script id=\"injected\">window.kimiFixtureInjected=true</script>\n\n"
        let prompt = prepared.prompt + "\n\nLiteral fixture block:\n" + literal
        XCTAssertGreaterThan(prompt.utf8.count, 4_000)
        _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
        _ = try await wait(fixture, token, state: "complete")
        let capturedValue = try await evaluate(fixture.view, "return fixturePrompts;")
        let captured = try XCTUnwrap(capturedValue as? [String])
        XCTAssertEqual(captured.count, 1)
        let prefix = prompt + "\n\nComputa session marker: "
        XCTAssertTrue(captured[0].hasPrefix(prefix))
        XCTAssertNotNil(UUID(uuidString: String(captured[0].dropFirst(prefix.count))))
        let receipt = try await evaluate(fixture.view, "return {inputEvents:kimiFixture.counters.input, injected:window.kimiFixtureInjected===true || document.getElementById('injected')!==null};") as? [String: Any]
        XCTAssertEqual(receipt?["inputEvents"] as? Int, 1)
        XCTAssertEqual(receipt?["injected"] as? Bool, false)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testProvisionalRouteCannotPublishAnswerAndCanonicalPromotionDoesNotResend() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdProvisional = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic pending first body")
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertEqual(pending["text"] as? String, "")
        _ = try await evaluate(fixture.view, "kimiFixture.canonicalize(); return true;")
        _ = try await wait(fixture, token, state: "complete")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testDelayedDeletionStagesObserveUntilReadyWithoutRepeatingClicks() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.menuDelayMs = 120; kimiFixture.options.dialogDelayMs = 120; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic delayed cleanup")
        _ = try await wait(fixture, token, state: "complete")
        let first = Task { try await self.call(fixture, "webProviderFinish", token)["cleanup"] as? String }
        let second = Task { try await self.call(fixture, "webProviderCancel", token)["cleanup"] as? String }
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, "deleted"); XCTAssertEqual(b, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testForeignCanonicalRouteCannotDeleteOrCloseItsOwnedView() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic wrong-route cleanup")
        _ = try await wait(fixture, token, state: "complete")
        _ = try await evaluate(fixture.view, "history.replaceState({}, '', '/chat/22221111-abcd-4333-8444-555555555555'); return true;")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testThrownSendCannotPublishAnswerDeleteOrReplay() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, """
            const original = HTMLElement.prototype.click;
            HTMLElement.prototype.click = function() {
              const send = this.classList.contains('send-button-container');
              original.call(this);
              if (send) throw new Error('Fixture lost Send acknowledgement after dispatch');
            };
            return true;
            """, world: world)
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic uncertain Send")
            XCTFail("A thrown Send cannot be acknowledged")
        } catch { }
        do {
            _ = try await call(fixture, "webProviderPoll", token)
            XCTFail("An unacknowledged Send cannot publish its answer")
        } catch { }
        let failed = try await call(fixture, "webProviderFinish", token)
        let retried = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(failed["cleanup"] as? String, "failed"); XCTAssertEqual(retried["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testThrownConfirmationCannotBecomeSuccessFromAnEmptyRootOrReplay() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic lost confirmation acknowledgement")
        _ = try await wait(fixture, token, state: "complete")
        _ = try await evaluate(fixture.view, """
            const original = HTMLElement.prototype.click;
            HTMLElement.prototype.click = function() {
              const confirm = this.getAttribute('data-testid') === 'confirm-dialog-confirm';
              original.call(this);
              if (confirm) throw new Error('Fixture lost acknowledgement after dispatch');
            };
            return true;
            """, world: world)
        let failed = try await call(fixture, "webProviderFinish", token)
        let retried = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(failed["cleanup"] as? String, "failed"); XCTAssertEqual(retried["cleanup"] as? String, "failed")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
    }

    func testFormatFailurePublishesNoPartialJSONButOwnedCleanupRemainsPossible() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdResponse = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic outside-prose reply")
        _ = try await evaluate(fixture.view, """
            kimiFixture.canonicalize();
            const prose = document.createElement('p'); prose.textContent = 'Outside authored prose must not be discarded.';
            document.querySelector('.markdown').append(prose); kimiFixture.completeResponse(); return true;
            """)
        do {
            _ = try await call(fixture, "webProviderPoll", token)
            XCTFail("Outside prose must reject publication")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .responseFormatUnavailable)
        }
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testMalformedReplyCleanupKeepsItsReadOnlyScopeAcrossCanonicalPromotion() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdProvisional = true; kimiFixture.options.holdResponse = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic crossed-route malformed cleanup")
        _ = try await evaluate(fixture.view, """
            const prose = document.createElement('p'); prose.textContent = 'Outside authored prose.';
            document.querySelector('.markdown').append(prose); kimiFixture.completeResponse(); return true;
            """)
        // The provisional route has no response authority yet, even when its
        // rendered body is malformed. Cleanup must preserve its separate read
        // scope when this route promotes during the next observation.
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertEqual(pending["text"] as? String, "")
        var promote = true
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", promote {
                promote = false
                _ = try? await self.evaluate(fixture.view, "kimiFixture.canonicalize(); return true;")
            }
        }
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertFalse(promote)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testCancellationDeletesTheExactBoundStreamingConversation() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.holdResponse = true; return true;")
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic streaming cancellation")
        _ = try await evaluate(fixture.view, "kimiFixture.canonicalize(); return true;")
        let running = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(running["state"] as? String, "running")
        let finished = try await call(fixture, "webProviderCancel", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testFreshOwnedPageClosesWithoutSendingOrDeleting() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
    }

    private func start(_ fixture: Fixture) async throws -> String {
        let parameters = ["provider": "kimi", "modelChoice": try XCTUnwrap(choice.canonicalJSONString)]
        let data = try await fixture.transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: parameters))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let token = try XCTUnwrap(snapshot["sessionToken"] as? String)
        _ = try await wait(fixture, token, state: "ready")
        return token
    }
    private func call(_ fixture: Fixture, _ operation: String, _ token: String, prompt: String? = nil) async throws -> [String: Any] {
        var values = ["sessionToken": token]; if let prompt { values["prompt"] = prompt }
        do {
            let data = try await fixture.transport.request(operation: operation, params: JSONSerialization.data(withJSONObject: values))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        } catch {
            // Preserve the original bounded failure before WebKit teardown can
            // replace its description with a deinitialization-state failure.
            let native = (error as? EmbeddedWebModelTransport.Failure).map { String(describing: $0) } ?? "other"
            print("KimiFixtureOriginalError phase=\(operation) type=\(String(reflecting: type(of: error))) domain=\((error as NSError).domain) code=\((error as NSError).code) native=\(native)")
            if operation == "webProviderSend", let shape = try? await evaluate(fixture.view, #"""
                const editor = document.querySelector('.chat-input-editor');
                const expected = globalThis.__computaKimiSavedSessionV1?.inserted?.prompt;
                if (!editor || typeof expected !== 'string') return {insertedPromptPresent:typeof expected === 'string'};
                const rendered = editor.innerText, text = editor.textContent;
                const paragraphs = [...editor.children], logical = paragraphs.map(node => node.textContent).join('\n');
                let mismatch = 0; while (mismatch < Math.min(logical.length, expected.length) && logical[mismatch] === expected[mismatch]) mismatch++;
                const logicalMatch = logical === expected;
                const tag = node => node.nodeType === 3 ? 'text' : ['P','DIV','BR','SPAN'].includes(node.tagName) ? node.tagName : 'other';
                const nodes = [...editor.childNodes].slice(0,16).map(node => ({tag:tag(node),
                    chars:(node.textContent||'').length, children:[...node.childNodes].slice(0,8).map(tag)}));
                return {expectedChars:expected.length, renderedChars:rendered.length, textChars:text.length,
                    logicalChars:logical.length, logicalMatch, logicalOnlyParagraphs:paragraphs.every(node=>node.tagName==='P'),
                    mismatchIndex:logicalMatch?-1:mismatch,
                    expectedCodePoint:logicalMatch?-1:expected.codePointAt(mismatch)??-1,
                    logicalCodePoint:logicalMatch?-1:logical.codePointAt(mismatch)??-1,
                    expectedNBSPs:(expected.match(/\u00a0/g)||[]).length, logicalNBSPs:(logical.match(/\u00a0/g)||[]).length,
                    spacesInsteadOfNBSPMatch:logical.replace(/\u00a0/g,' ')===expected,
                    exact:rendered===expected, oneTerminalLF:rendered===expected+'\n', twoTerminalLF:rendered===expected+'\n\n',
                    expectedNewlines:(expected.match(/\n/g)||[]).length, renderedNewlines:(rendered.match(/\n/g)||[]).length,
                    terminalNewlines:(rendered.match(/\n*$/)||[''])[0].length,
                    renderedWithoutTerminalNewlinesMatches:rendered.replace(/\n+$/,'')===expected,
                    textExact:text===expected, childCount:editor.childNodes.length, nodes};
                """#, world: world), let safe = try? JSONSerialization.data(withJSONObject: shape, options: .sortedKeys), safe.count <= 4096,
                let line = String(data: safe, encoding: .utf8) {
                print("KimiFixtureComposerShape " + line)
            }
            throw error
        }
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
        let actual = try await evaluate(fixture.view, "return [kimiFixture.counters.sends, kimiFixture.counters.headerOpens, kimiFixture.counters.deleteSelections, kimiFixture.counters.confirmations];") as? [Int]
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
        init() throws {
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
                view.loadHTMLString(KimiFixturePage.html, baseURL: url)
                return id
            })
        }
        func shutdown() {
            browser.shutdown(); host.detach(); window.orderOut(nil); window.close()
        }
    }
}

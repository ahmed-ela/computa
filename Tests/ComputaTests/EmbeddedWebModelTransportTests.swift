import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedWebModelTransportTests: XCTestCase {
    func testOwnedTemporaryChatSendsLiteralTextAndClosesOnlyItsTab() async throws {
        let fixture = try Fixture()
        defer { fixture.browser.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let ownedView = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        XCTAssertTrue(ownedView.configuration.websiteDataStore === fixture.humanView.configuration.websiteDataStore)
        try await waitForFixture(ownedView)
        let documentURL = try await evaluate(ownedView, "return document.URL;") as? String
        XCTAssertEqual(documentURL, "https://chatgpt.com/?temporary-chat=true")
        _ = try await waitForState("ready", fixture.transport, token: token)

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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
            defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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

    private func call(_ transport: EmbeddedWebModelTransport, _ operation: String,
                      _ params: [String: String]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params)
        let response = try await transport.request(operation: operation, params: data)
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
            if !view.isLoading,
               let loaded = try? await evaluate(view, "return window.fixtureReady === true ? window.fixtureGeneration : null;"),
               loaded as? String == generation { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The synthetic ChatGPT document did not load")
        throw FixtureFailure.timeout
    }

    private func evaluate(_ view: WKWebView, _ body: String, world: WKContentWorld = .page) async throws -> Any? {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: [:], in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    do {
                        let serialized = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
                        continuation.resume(returning: serialized)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private enum FixtureFailure: Error { case timeout, unexpectedState }

    @MainActor
    private final class Fixture {
        let browser = EmbeddedBrowserSession(persistent: false)
        let humanID: UUID
        let humanView: WKWebView
        var createdTabs: [UUID] = []
        private(set) var transport: EmbeddedWebModelTransport!

        init() throws {
            humanID = try browser.createTab()
            humanView = try XCTUnwrap(browser.webView(for: humanID))
            humanView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            humanView.loadHTMLString("<p id='human-marker'>Untouched human tab</p>", baseURL: URL(string: "https://example.test/"))
            transport = EmbeddedWebModelTransport(browser: browser, createTabForTesting: { [unowned self] url in
                let id = try self.browser.createTab(select: false)
                let view = try XCTUnwrap(self.browser.webView(for: id))
                view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
                view.loadHTMLString(EmbeddedWebModelTransportTests.page, baseURL: url)
                self.createdTabs.append(id)
                return id
            })
        }
    }

    private static let page = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <style>body { margin: 20px; } .ProseMirror { min-height: 50px; width: 600px; white-space: pre-wrap; } .ProseMirror p { margin: 0; }</style>
    </head><body>
    <button aria-label="Turn off temporary chat">Temporary chat</button>
    <div id="messages"></div>
    <div id="prompt-textarea"><div id="fixture-editor" class="ProseMirror" contenteditable="true" aria-label="Ask ChatGPT"><p><br class="ProseMirror-trailingBreak"></p></div></div>
    <button data-testid="send-button" aria-label="Send prompt" disabled>Send</button>
    <script>
    window.fixturePrompts = [];
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

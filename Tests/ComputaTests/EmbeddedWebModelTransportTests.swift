import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedWebModelTransportTests: XCTestCase {
    func testProviderOriginsAndRoutesRemainSessionSpecific() throws {
        let routes: [(EmbeddedWebModelTransport.Provider, String, String)] = [
            (.chatgpt, "https://chatgpt.com/?temporary-chat=true", "https://chatgpt.com/c/owned-123"),
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
            defer { fixture.browser.shutdown() }
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
            defer { fixture.browser.shutdown() }
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
            defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
            defer { fixture.browser.shutdown() }
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
            defer { fixture.browser.shutdown() }
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
            defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
            defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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
        defer { fixture.browser.shutdown() }
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

    private enum FixtureFailure: Error { case timeout, unexpectedState }

    @MainActor
    private final class Fixture {
        let browser = EmbeddedBrowserSession(persistent: false)
        let humanID: UUID
        let humanView: WKWebView
        var createdTabs: [UUID] = []
        private(set) var transport: EmbeddedWebModelTransport!

        init(page: String = EmbeddedWebModelTransportTests.page, initialURL: URL? = nil) throws {
            humanID = try browser.createTab()
            humanView = try XCTUnwrap(browser.webView(for: humanID))
            humanView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            humanView.loadHTMLString("<p id='human-marker'>Untouched human tab</p>", baseURL: URL(string: "https://example.test/"))
            transport = EmbeddedWebModelTransport(browser: browser, createTabForTesting: { [unowned self] url in
                let id = try self.browser.createTab(select: false)
                let view = try XCTUnwrap(self.browser.webView(for: id))
                view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
                view.loadHTMLString(page, baseURL: initialURL ?? url)
                self.createdTabs.append(id)
                return id
            })
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

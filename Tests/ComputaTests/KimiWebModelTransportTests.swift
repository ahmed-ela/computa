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

    func testDiscoveryFromNestedK3VerifiesItsCheckedRowWithoutSelectingItOrExposingIt() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertEqual(choices, [choice])
        let state = try await evaluate(fixture.view, """
            return {label:document.querySelector('.current-model .name').textContent,
                checked:document.querySelector('[data-testid="model-more-option"]').getAttribute('aria-checked'),
                opens:kimiFixture.counters.moreOpens, closes:kimiFixture.counters.moreCloses,
                nestedSelections:kimiFixture.counters.moreSelections, selections:kimiFixture.counters.modelSelections};
            """) as? [String: Any]
        XCTAssertEqual(state?["label"] as? String, "K3")
        XCTAssertEqual(state?["checked"] as? String, "true")
        XCTAssertEqual(state?["opens"] as? Int, 1); XCTAssertEqual(state?["closes"] as? Int, 1)
        XCTAssertEqual(state?["nestedSelections"] as? Int, 0); XCTAssertEqual(state?["selections"] as? Int, 0)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testStalledNestedDiscoveryRetainsFiniteLastObservationBeforeClosingWithoutReplaying() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(3))
        var installed = false, terminalBeforeClose = false
        var records: [String] = []
        fixture.transport.setKimiDiscoveryProgressObserverForTesting { record in
            records.append(record)
            if record.hasPrefix("event=terminal "), let id = fixture.createdID {
                terminalBeforeClose = fixture.browser.webView(for: id) === fixture.view
            }
        }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "discoverModels", !installed {
                installed = true
                _ = try? await self.evaluate(fixture.view, """
                    window.fixtureMoreDispatches = 0;
                    document.getElementById('fixture-more-trigger').addEventListener('click', event => {
                        window.fixtureMoreDispatches++;
                        event.preventDefault(); event.stopImmediatePropagation();
                    }, true);
                    return true;
                    """)
            }
        }
        do {
            _ = try await fixture.transport.discoverModels(provider: "kimi")
            XCTFail("An unacknowledged submenu open cannot complete discovery")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .preparationDeadline)
        }
        XCTAssertTrue(installed); XCTAssertTrue(terminalBeforeClose)
        let terminal = records.filter { $0.hasPrefix("event=terminal ") }
        XCTAssertEqual(terminal.count, 1)
        XCTAssertTrue(terminal.first?.contains("reason=preparation_timeout lastObservation phase=moreOpening") == true)
        XCTAssertTrue(terminal.first?.contains("submenuClaimed=true submenuPresent=false submenuExpanded=false submenuCollapsed=true") == true)
        XCTAssertLessThanOrEqual(records.count, 13)
        XCTAssertEqual(Set(records).count, records.count)
        for privateValue in ["K3", "Instant", "kimi.com", "fixture-more", fixture.createdID?.uuidString ?? "not-an-id"] {
            XCTAssertFalse(records.joined().contains(privateValue))
        }
        let clicks = try await evaluate(fixture.view, "return window.fixtureMoreDispatches;") as? Int
        XCTAssertEqual(clicks, 1)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testInstantSelectionFromNestedK3ReopensForProofThenSendsAndDeletesOnce() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        let token = try await start(fixture)
        let selected = try await evaluate(fixture.view, """
            return {label:document.querySelector('.current-model .name').textContent,
                instant:document.querySelector('[data-moon-key="k28-instant"]').getAttribute('aria-checked'),
                nested:document.querySelector('[data-testid="model-more-option"]').getAttribute('aria-checked'),
                moreOpens:kimiFixture.counters.moreOpens, moreCloses:kimiFixture.counters.moreCloses,
                modelOpens:kimiFixture.counters.modelOpens, selections:kimiFixture.counters.modelSelections,
                nestedSelections:kimiFixture.counters.moreSelections};
            """) as? [String: Any]
        XCTAssertEqual(selected?["label"] as? String, "Instant")
        XCTAssertEqual(selected?["instant"] as? String, "true"); XCTAssertEqual(selected?["nested"] as? String, "false")
        XCTAssertEqual(selected?["moreOpens"] as? Int, 1); XCTAssertEqual(selected?["moreCloses"] as? Int, 1)
        XCTAssertEqual(selected?["modelOpens"] as? Int, 2)
        XCTAssertEqual(selected?["selections"] as? Int, 1); XCTAssertEqual(selected?["nestedSelections"] as? Int, 0)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic Instant task after nested model selection")
        _ = try await wait(fixture, token, state: "complete")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
    }

    func testNestedDiscoveryRejectsForeignSubmenuBindingWithoutModelChangeOrSend() async throws {
        let fixture = try Fixture(initialNestedModel: true); defer { fixture.shutdown() }
        var changed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !changed {
                changed = true
                _ = try? await self.evaluate(fixture.view,
                    "document.getElementById('fixture-more-menu').setAttribute('aria-labelledby', 'foreign-trigger'); return true;")
            }
        }
        do { _ = try await fixture.transport.discoverModels(provider: "kimi"); XCTFail("A foreign submenu cannot supply model evidence") } catch { }
        XCTAssertTrue(changed)
        let actions = try await evaluate(fixture.view,
            "return [kimiFixture.counters.modelSelections,kimiFixture.counters.moreSelections,kimiFixture.counters.beforeInput,kimiFixture.counters.sends];") as? [Int]
        XCTAssertEqual(actions, [0, 0, 0, 0])
    }

    func testDiscoveryWaitsForInitialControlsWithoutBindingOrDispatchingEarly() async throws {
        let fixture = try Fixture(initialControlsPending: true); defer { fixture.shutdown() }
        var sawUnhydratedRead = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !sawUnhydratedRead {
                sawUnhydratedRead = true
                let before = try? await self.evaluate(fixture.view, """
                    const result = {empty:!document.querySelector('.current-model,.chat-input-editor,.send-button-container'),
                        sends:kimiFixture.counters.sends, modelOpens:kimiFixture.counters.modelOpens,
                        inputs:kimiFixture.counters.beforeInput};
                    setTimeout(() => fixtureHydration.restore(), 100); return result;
                    """) as? [String: Any]
                XCTAssertEqual(before?["empty"] as? Bool, true)
                XCTAssertEqual(before?["sends"] as? Int, 0)
                XCTAssertEqual(before?["modelOpens"] as? Int, 0)
                XCTAssertEqual(before?["inputs"] as? Int, 0)
            }
        }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertTrue(sawUnhydratedRead)
        XCTAssertEqual(choices, [choice])
        let restored = try await evaluate(fixture.view, "return fixtureHydration.restored;") as? Bool
        XCTAssertEqual(restored, true)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testDiscoveryWakesWhenExistingEditorBecomesEditableWithoutChildMutation() async throws {
        let fixture = try Fixture(initialEditorAttributePending: true); defer { fixture.shutdown() }
        var sawPendingRead = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !sawPendingRead {
                sawPendingRead = true
                let before = try? await self.evaluate(fixture.view, """
                    const editor = document.querySelector('.chat-input-editor');
                    const result = {exists:!!editor, editable:editor.hasAttribute('contenteditable'),
                        sends:kimiFixture.counters.sends, modelOpens:kimiFixture.counters.modelOpens,
                        inputs:kimiFixture.counters.beforeInput};
                    setTimeout(() => fixtureHydration.restore(), 100); return result;
                    """) as? [String: Any]
                XCTAssertEqual(before?["exists"] as? Bool, true)
                XCTAssertEqual(before?["editable"] as? Bool, false)
                XCTAssertEqual(before?["sends"] as? Int, 0)
                XCTAssertEqual(before?["modelOpens"] as? Int, 0)
                XCTAssertEqual(before?["inputs"] as? Int, 0)
            }
        }
        let choices = try await fixture.transport.discoverModels(provider: "kimi")
        XCTAssertTrue(sawPendingRead)
        XCTAssertEqual(choices, [choice])
        let restored = try await evaluate(fixture.view, "return fixtureHydration.restored;") as? Bool
        XCTAssertEqual(restored, true)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testMissingControlsAfterReadyCannotReenterInitialHydration() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "document.querySelector('.current-model').remove(); return true;")
        do {
            // Ready Poll is a cached native snapshot. Send's strict preparation
            // must re-read the bound controls before any editor mutation.
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic missing bound model controls")
            XCTFail("A bound model cannot reset into initial hydration")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .ownershipFailure(.javaScriptDocument))
        }
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
        let insertions = try await evaluate(fixture.view, "return kimiFixture.counters.beforeInput;") as? Int
        XCTAssertEqual(insertions, 0)
    }

    func testServerReleasesKimiResponseOnlyWithItsNativeDurableDeletionReceipt() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaKimiReceipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = WebModelServer(), generation = UUID()
        let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
        await server.configureEmbeddedTransport(fixture.transport)
        await server.configureEvidenceDirectory(directory.appendingPathComponent("evidence"))
        await server.configureCleanupReceipts(directory: directory, runtimeGeneration: generation) { _ in }
        do {
            let request = try JSONSerialization.data(withJSONObject: ["model": choice.modelID,
                "input": "Return the synthetic offline fixture reply.", "tools": []] as [String: Any])
            let response = try await server.fixtureInfer(request, taskID: task, threadID: thread, turnID: turn,
                runtimeGeneration: generation)
            XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("Offline Kimi fixture reply"))
            let receipts = await server.latestCleanupReceipts()
            XCTAssertEqual(receipts.count, 1)
            let receipt = try XCTUnwrap(receipts.first)
            XCTAssertTrue(receipt.isValid); XCTAssertTrue(receipt.isTransactionLinked); XCTAssertTrue(receipt.receiptSaved)
            XCTAssertEqual(receipt.provider, .kimi); XCTAssertEqual(receipt.route, .embedded)
            XCTAssertEqual(receipt.modelID, choice.modelID); XCTAssertEqual(receipt.reason, .deleted)
            XCTAssertEqual(receipt.outcome, .closed); XCTAssertEqual(receipt.trigger, .inference)
            XCTAssertEqual(receipt.taskID, task.lowercased()); XCTAssertEqual(receipt.threadID, thread.lowercased())
            XCTAssertEqual(receipt.turnID, turn.lowercased()); XCTAssertNotNil(receipt.sessionToken)
            XCTAssertEqual(receipt.runtimeGeneration, generation.uuidString.lowercased())
            XCTAssertEqual(WebsiteSessionCleanupStore(directory: directory).latest(), [receipt],
                           "A fresh store must recover the exact native lease after restart")
            let encoded = try JSONEncoder().encode(receipt)
            XCTAssertEqual(try JSONDecoder().decode(WebsiteSessionCleanupReceipt.self, from: encoded), receipt)
            let retried = await server.retryWebsiteSessionCleanup(taskID: task, runtimeGeneration: generation)
            XCTAssertEqual(retried, receipt)
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
            _ = await server.shutdown()
        } catch {
            _ = await server.shutdown()
            throw error
        }
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
        let receipt = try await evaluate(fixture.view, "return {injected:window.kimiFixtureInjected===true || document.getElementById('injected')!==null};") as? [String: Any]
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
        XCTAssertEqual(receipt?["injected"] as? Bool, false)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testDelayedLexicalCommitWaitsForExactReadbackWithoutReinserting() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        var insertions = 0, readinessReads = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "insert" { insertions += 1 }
            if action == "sendReady" {
                readinessReads += 1
                if readinessReads == 1 {
                    let before = try? await self.evaluate(fixture.view,
                        "return {empty:document.querySelector('.chat-input-editor').textContent === '', sends:kimiFixture.counters.sends};") as? [String: Any]
                    XCTAssertEqual(before?["empty"] as? Bool, true)
                    XCTAssertEqual(before?["sends"] as? Int, 0)
                    _ = try? await self.evaluate(fixture.view, "kimiFixture.settleInput(); return true;")
                }
            }
        }
        let prompt = "Exact \"quotes\" and 'apostrophe'\n\n  spaces\tand\u{00a0}NBSP <tag> &amp;\n"
        _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
        _ = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(insertions, 1); XCTAssertGreaterThanOrEqual(readinessReads, 2)
        let prompts = try await evaluate(fixture.view, "return fixturePrompts;") as? [String]
        XCTAssertEqual(prompts?.count, 1)
        XCTAssertTrue(prompts?.first?.hasPrefix(prompt + "\n\nComputa session marker: ") == true)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 1)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
    }

    func testControlledEditorBeforeInputDefaultComparisonPreservesExactEventPayload() async throws {
        for preventNativeInput in [false, true] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            _ = try await start(fixture)
            _ = try await evaluate(fixture.view, "kimiFixture.options.preventNativeInput = \(preventNativeInput ? "true" : "false"); return true;")
            let commandResult = try await evaluate(fixture.view, #"""
                const editor = document.querySelector('.chat-input-editor'); editor.focus();
                const payload = "Synthetic café 👋\nActual \\ and \"quoted\" content\n\n  spaces\tNBSP: <tag>&amp;\n";
                return document.execCommand('insertText', false, payload);
                """#, world: world)
            let observation = try await evaluate(fixture.view, #"""
                const editor = document.querySelector('.chat-input-editor');
                const payload = "Synthetic café 👋\nActual \\ and \"quoted\" content\n\n  spaces\tNBSP: <tag>&amp;\n";
                await new Promise(resolve => setTimeout(resolve, 30));
                return { preventNativeInput:kimiFixture.options.preventNativeInput,
                    exact:editor.textContent === payload, renderedLength:editor.textContent.length,
                    expectedLength:payload.length, inputEvents:kimiFixture.inputEvents,
                    beforeInput:kimiFixture.counters.beforeInput, inputs:kimiFixture.counters.input,
                    settlements:kimiFixture.counters.settlements, sends:kimiFixture.counters.sends };
                """#) as? [String: Any]
            var receipt = try XCTUnwrap(observation)
            receipt["returned"] = try XCTUnwrap(commandResult as? Bool)
            let encoded = try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys)
            XCTAssertLessThan(encoded.count, 8192)
            FileHandle.standardError.write(Data(("KimiControlledEditorEventComparison " + String(decoding: encoded, as: UTF8.self) + "\n").utf8))
            XCTAssertEqual(receipt["returned"] as? Bool, true)
            XCTAssertEqual(receipt["sends"] as? Int, 0)
            if preventNativeInput {
                XCTAssertEqual(receipt["exact"] as? Bool, true)
                XCTAssertEqual(receipt["beforeInput"] as? Int, 1)
                XCTAssertEqual(receipt["settlements"] as? Int, 1)
            }
        }
    }

    func testChangedLexicalCommitPreventsSendAndCannotReinsert() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; kimiFixture.options.lexicalWrongText = true; return true;")
        var released = false, insertions = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "insert" { insertions += 1 }
            if action == "sendReady", !released {
                released = true
                _ = try? await self.evaluate(fixture.view, "kimiFixture.settleInput(); return true;")
            }
        }
        let prompt = "Synthetic wrong deferred input"
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            XCTFail("A changed nonempty editor must not reach Send")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .editorFailure("prompt_not_inserted"))
        }
        XCTAssertTrue(released)
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("Input is never replayed") } catch { }
        XCTAssertEqual(insertions, 1)
        try await assertInsertionCounts(fixture, settlements: 1, sends: 0)
    }

    func testMissingLexicalCommitExpiresAndLateCommitCannotSendOrReinsert() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        let started = ContinuousClock.now, prompt = "Synthetic lost deferred input"
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            XCTFail("A dispatch receipt alone must not enable Send")
        } catch let error as EmbeddedWebModelTransport.Failure {
            XCTAssertEqual(error, .editorFailure("send_unavailable"))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(6), "The read-only readiness wait stays bounded")
        try await assertInsertionCounts(fixture, settlements: 0, sends: 0)
        _ = try await evaluate(fixture.view, "kimiFixture.settleInput(); return true;")
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("Late input cannot reopen a failed Send") } catch { }
        try await assertInsertionCounts(fixture, settlements: 1, sends: 0)
    }

    func testReplacedEditorDuringLexicalWaitCannotSendOrReinsert() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        var replaced = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "sendReady", !replaced {
                replaced = true
                _ = try? await self.evaluate(fixture.view, """
                    const editor = document.querySelector('.chat-input-editor');
                    editor.replaceWith(editor.cloneNode(true)); kimiFixture.settleInput(); return true;
                    """)
            }
        }
        let prompt = "Synthetic displaced editor"
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("A replacement editor cannot inherit the insertion") } catch { }
        XCTAssertTrue(replaced)
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("A replacement editor cannot cause reinsertion") } catch { }
        try await assertInsertionCounts(fixture, settlements: 0, sends: 0)
    }

    func testCancelledLexicalWaitDoesNotSendAfterLateCommit() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "kimiFixture.options.lexicalNeverSettle = true; return true;")
        var cancelled = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "sendReady", !cancelled {
                cancelled = true
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let prompt = "Synthetic cancelled deferred input"
        let sending = Task { try await self.call(fixture, "webProviderSend", token, prompt: prompt)["state"] as? String }
        do { _ = try await sending.value; XCTFail("Cancellation must stop Send") } catch { }
        XCTAssertTrue(cancelled)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        _ = try await evaluate(fixture.view, "kimiFixture.settleInput(); return true;")
        do { _ = try await call(fixture, "webProviderSend", token, prompt: prompt); XCTFail("Cancelled input is never replayed") } catch { }
        try await assertInsertionCounts(fixture, settlements: 1, sends: 0)
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
            FileHandle.standardError.write(Data("KimiFixtureOriginalError phase=\(operation) type=\(String(reflecting: type(of: error))) domain=\((error as NSError).domain) code=\((error as NSError).code) native=\(native)\n".utf8))
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
                FileHandle.standardError.write(Data(("KimiFixtureComposerShape " + line + "\n").utf8))
            }
            if operation == "webProviderSend", let events = try? await evaluate(fixture.view, "return kimiFixture.inputEvents;"),
               let encoded = try? JSONSerialization.data(withJSONObject: events, options: .sortedKeys), encoded.count <= 8192 {
                FileHandle.standardError.write(Data(("KimiFixtureInputEvents " + String(decoding: encoded, as: UTF8.self) + "\n").utf8))
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
    private func assertInsertionCounts(_ fixture: Fixture, settlements: Int, sends: Int) async throws {
        let value = try await evaluate(fixture.view,
            "return [kimiFixture.counters.beforeInput, kimiFixture.counters.input, kimiFixture.counters.settlements, kimiFixture.counters.earlySends, kimiFixture.counters.sends];") as? [Int]
        let actual = try XCTUnwrap(value)
        XCTAssertEqual(actual.count, 5)
        guard actual.count == 5 else { return }
        XCTAssertEqual(actual[0], 1, "Exactly one native insertion's beforeinput payload")
        XCTAssertEqual(actual[1], 0, "Cancelling the native edit prevents its substitution/input events")
        XCTAssertEqual(Array(actual[2...]), [settlements, 0, sends])
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
        init(initialControlsPending: Bool = false, initialEditorAttributePending: Bool = false, initialNestedModel: Bool = false) throws {
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
                let hydrationSetup = """
                    <script>(() => {
                      const controls = [...document.body.children].filter(node => node.tagName !== 'SCRIPT');
                      for (const node of controls) node.remove();
                      window.fixtureHydration = {restored:false, restore() {
                        if (this.restored) throw new Error('Fixture controls already restored');
                        this.restored = true;
                        for (const node of controls) document.body.append(node);
                      }};
                    })();</script>
                    """
                let attributeSetup = """
                    <script>(() => {
                      const editor = document.querySelector('.chat-input-editor');
                      editor.removeAttribute('contenteditable');
                      window.fixtureHydration = {restored:false, restore() {
                        if (this.restored) throw new Error('Fixture editor already restored');
                        this.restored = true;
                        editor.setAttribute('contenteditable', 'true');
                      }};
                    })();</script>
                    """
                let nestedSetup = initialNestedModel ? "<script>kimiFixture.selectNestedInitially();</script>" : ""
                let setup = nestedSetup + (initialControlsPending ? hydrationSetup : initialEditorAttributePending ? attributeSetup : "")
                let html = KimiFixturePage.html.replacingOccurrences(of: "</body>", with: setup + "</body>")
                view.loadHTMLString(html, baseURL: url)
                return id
            })
        }
        func shutdown() {
            browser.shutdown(); host.detach(); window.orderOut(nil); window.close()
        }
    }
}

import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedWebModelTransportTests: XCTestCase {
    // Insert into existing EmbeddedWebModelTransportTests. Uses the exact
    // bundled source and a real rendered WKWebView; no getter mocks/fake DOM.
    // Prepared only. Root applies/runs; this snippet has not been executed.
    func testMatchedProbeAdmitsOnlyOneTerminalLFOnExactContenteditablePayload() async throws {
        let (fixture, view, _, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        let payload = "Exact synthetic café 🌍\nKeep this internal line"
        let answer = #"{"type":"message","text":"HI"}"#
        let cases: [(name: String, textarea: Bool, terminalLFs: Int, wrongPrefix: Bool, matches: Bool)] = [
            ("contenteditable_one_terminal_lf", false, 1, false, true),
            ("textarea_one_extra_lf", true, 1, false, false),
            ("contenteditable_two_terminal_lfs", false, 2, false, false),
            ("contenteditable_same_size_wrong_payload", false, 1, true, false),
        ]
        for item in cases {
            try await resetMatchedProbePage(view)
            let config = try await installMatchedProbe(view, payload: payload)
            // Swap the editor after installing the observer but before Send,
            // matching the real page's contenteditable representation boundary.
            // The raw DOM read is independently checked before the probe sees it.
            let extraction = try await evaluate(view, """
                const old=document.getElementById('prompt-textarea');
                const textarea=\(item.textarea ? "true" : "false");
                const prefix=\(item.wrongPrefix ? "true" : "false")
                    ? globalThis.fixtureProbePayload.replace('Exact','Other') : globalThis.fixtureProbePayload;
                const rendered=prefix+'\\n'.repeat(\(item.terminalLFs));
                let editor=old;
                if (!textarea) {
                  editor=document.createElement('div'); editor.id='prompt-textarea';
                  editor.setAttribute('contenteditable','true'); editor.setAttribute('aria-label','Ask ChatGPT');
                  editor.style.whiteSpace='pre-wrap'; editor.style.minHeight='40px';
                  editor.textContent=rendered; old.replaceWith(editor);
                } else editor.value=rendered;
                const actual=textarea ? editor.value : (editor.innerText || editor.textContent || '');
                return {isTextarea:editor instanceof HTMLTextAreaElement,
                  renderedExactlyAsConstructed:actual===rendered,
                  renderedUTF8Bytes:new TextEncoder().encode(actual).length,
                  editorCount:document.querySelectorAll('#prompt-textarea').length};
                """, world: Self.matchedProbeWorld) as? [String: Any]
            let actual = try XCTUnwrap(extraction)
            XCTAssertEqual(actual["isTextarea"] as? Bool, item.textarea, item.name)
            XCTAssertEqual(actual["renderedExactlyAsConstructed"] as? Bool, true, item.name)
            XCTAssertEqual(actual["renderedUTF8Bytes"] as? Int, payload.utf8.count + item.terminalLFs, item.name)
            XCTAssertEqual(actual["editorCount"] as? Int, 1, item.name)
            try await sendMatchedProbeFixture(view, body: payload, answer: answer, codeCopy: true)
            if item.matches {
                let state = try await waitForMatchedProbeState(view) {
                    $0["payloadMatched"] as? Bool == true && $0["editorRenderedSHA256"] is String
                        && $0["editorCanonicalSHA256"] is String
                }
                XCTAssertEqual(state["invalidReason"] as? String, "none", item.name)
                XCTAssertEqual(state["editorRepresentation"] as? String, "single_terminal_newline", item.name)
                XCTAssertEqual(state["editorUTF8Bytes"] as? Int, payload.utf8.count, item.name)
                XCTAssertEqual(state["editorSHA256"] as? String, config["expectedSHA256"] as? String, item.name)
                XCTAssertEqual(state["editorSHA256"] as? String, EmbeddedWebModelTransport.promptFingerprint(payload), item.name)
                XCTAssertEqual(state["editorCanonicalSHA256"] as? String, config["expectedCanonicalSHA256"] as? String, item.name)
                XCTAssertEqual(state["userSHA256"] as? String, config["expectedCanonicalSHA256"] as? String, item.name)
                XCTAssertEqual(state["editorRenderedUTF8Bytes"] as? Int, payload.utf8.count + 1, item.name)
                XCTAssertEqual(state["editorRenderedSHA256"] as? String,
                    EmbeddedWebModelTransport.promptFingerprint(payload + "\n"), item.name)
                XCTAssertNotEqual(state["editorRenderedSHA256"] as? String, state["editorSHA256"] as? String, item.name)
                XCTAssertEqual(state["sendClickCount"] as? Int, 1, item.name)
                XCTAssertEqual(state["editorMatchesExpected"] as? Bool, true, item.name)
                XCTAssertEqual(state["userMatchesExpected"] as? Bool, true, item.name)
            } else {
                let state = try await waitForMatchedProbeState(view) {
                    $0["invalidReason"] as? String == "editor_mismatch"
                }
                XCTAssertEqual(state["payloadMatched"] as? Bool, false, item.name)
                XCTAssertEqual(state["editorMatchesExpected"] as? Bool, false, item.name)
                XCTAssertNotEqual(state["editorSHA256"] as? String, config["expectedSHA256"] as? String, item.name)
                XCTAssertEqual(state["sendClickCount"] as? Int, 1, item.name)
                if item.wrongPrefix {
                    XCTAssertEqual(state["editorRepresentation"] as? String, "single_terminal_newline", item.name)
                    XCTAssertEqual(state["editorUTF8Bytes"] as? Int, payload.utf8.count,
                        "The same byte count after removing one LF cannot replace the full exact hash")
                } else {
                    XCTAssertEqual(state["editorRepresentation"] as? String, "exact", item.name)
                    XCTAssertEqual(state["editorUTF8Bytes"] as? Int, payload.utf8.count + item.terminalLFs, item.name)
                }
            }
        }
    }

    func testMatchedProbeObservesTheWebsitesAriaOnlySendButtons() async throws {
        let (fixture, view, _, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        for label in ["Send", "Send message", "Send prompt"] {
            try await resetMatchedProbePage(view)
            _ = try await evaluate(view, "const b=document.getElementById('probe-send'); b.removeAttribute('data-testid'); b.setAttribute('aria-label',\(try matchedProbeJSON(label))); return true;", world: Self.matchedProbeWorld)
            _ = try await installMatchedProbe(view, payload: "Exact aria-only Send fixture")
            try await sendMatchedProbeFixture(view, body: "Exact aria-only Send fixture", answer: #"{"type":"message","text":"HI"}"#, codeCopy: true)
            let state = try await waitForMatchedProbeState(view) { $0["payloadMatched"] as? Bool == true }
            XCTAssertEqual(state["invalidReason"] as? String, "none", label)
            XCTAssertEqual(state["sendClickCount"] as? Int, 1, label)
            XCTAssertNotNil(state["sendUnixMs"] as? NSNumber, label)
            XCTAssertNotNil(state["firstTextAfterSendMs"] as? NSNumber, label)
        }
    }

    func testMatchedProbeExactBundledSourceIsDormantForIneligibleConfigurationAndCannotRetargetNonce() async throws {
        let (fixture, view, _, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        try await resetMatchedProbePage(view)
        let source = try Self.matchedProbeScript.get()
        let definitions = try await evaluate(view, source + "\nglobalThis.fixtureInstallMatchedProbe=computaInstallMatchedBenchmarkProbe; return typeof computaInstallMatchedBenchmarkProbe;", world: Self.matchedProbeWorld) as? String
        XCTAssertEqual(definitions, "function")
        let initiallyAbsent = try await evaluate(view, "return globalThis.__computaMatchedBenchmarkProbeV1 == null;", world: Self.matchedProbeWorld) as? Bool
        XCTAssertEqual(initiallyAbsent, true)
        let rejected = try await evaluate(view, #"""
            const base = {schemaVersion:1,nonce:'cccccccc-1111-4222-8333-dddddddddddd',
              expectedSHA256:'a'.repeat(64),expectedCanonicalSHA256:'b'.repeat(64),expectedUTF8Bytes:12};
            const variants = [null,{}, {...base,schemaVersion:true}, {...base,nonce:base.nonce.toUpperCase()},
              {...base,expectedSHA256:'PRIVATE_CANARY'}, {...base,expectedUTF8Bytes:true}, {...base,expectedUTF8Bytes:180201},
              {...base,unexpected:'PRIVATE_CANARY'}];
            const allRejected = variants.every(value => globalThis.fixtureInstallMatchedProbe(value) === null);
            document.querySelector('button[data-testid="send-button"]').click();
            return allRejected && globalThis.__computaMatchedBenchmarkProbeV1 == null;
            """#, world: Self.matchedProbeWorld) as? Bool
        XCTAssertEqual(rejected, true, "Dormant diagnostics must install neither observer nor getter")
        let config = try await installMatchedProbe(view, payload: "Matched UTF-8 café 🌍")
        let reuse = try await evaluate(view, #"""
            const original = globalThis.__computaMatchedBenchmarkProbeV1;
            const same = globalThis.fixtureInstallMatchedProbe(globalThis.fixtureProbeConfig);
            const other = globalThis.fixtureInstallMatchedProbe({...globalThis.fixtureProbeConfig,expectedSHA256:'f'.repeat(64)});
            return same === original && other === null && globalThis.__computaMatchedBenchmarkProbeV1 === original;
            """#, world: Self.matchedProbeWorld) as? Bool
        XCTAssertEqual(reuse, true)
        XCTAssertEqual(config["expectedUTF8Bytes"] as? Int, "Matched UTF-8 café 🌍".utf8.count)
        _ = try await evaluate(view, #"""
            const old = document.createElement('article'); old.dataset.turn='user'; old.textContent='pre-Send contamination';
            document.querySelector('main').append(old); document.querySelector('button[data-testid="send-button"]').click();
            return true;
            """#, world: Self.matchedProbeWorld)
        let contaminated = try await matchedProbeState(view)
        XCTAssertEqual(contaminated["invalidReason"] as? String, "not_fresh")
        XCTAssertTrue(contaminated["sendUnixMs"] is NSNull, "Rejected pre-Send contamination must not invent a send timestamp")
        XCTAssertEqual(contaminated["payloadMatched"] as? Bool, false)
    }

    func testMatchedProbeLateFullBodyBindsEarlierFirstTextAndCodeCopyDoesNotComplete() async throws {
        let (fixture, view, _, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        try await resetMatchedProbePage(view)
        let payload = "Computa synthetic café 🌍\n" + String(repeating: "x", count: 11_000)
        let config = try await installMatchedProbe(view, payload: payload)
        try await sendMatchedProbeFixture(view, body: String(payload.prefix(1_024)), answer: "json", codeCopy: false)
        let labelOnly = try await waitForMatchedProbeState(view) { $0["userSHA256"] is String }
        XCTAssertTrue(labelOnly["firstTextAfterSendMs"] is NSNull, "Fence language label alone is not response text")
        _ = try await evaluate(view, #"""
            document.getElementById('probe-answer').innerHTML='<pre><code>{"type":"message","text":"HI"}</code><button aria-label="Copy">Copy code</button></pre>';
            return true;
            """#, world: Self.matchedProbeWorld)
        let early = try await waitForMatchedProbeState(view) { $0["firstTextAfterSendMs"] is NSNumber && $0["responseSHA256"] is String }
        let firstText = try XCTUnwrap((early["firstTextAfterSendMs"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(early["editorSHA256"] as? String, config["expectedSHA256"] as? String)
        XCTAssertEqual(early["editorUTF8Bytes"] as? Int, payload.utf8.count)
        XCTAssertEqual(early["userMatchesExpected"] as? Bool, false)
        XCTAssertEqual(early["payloadMatched"] as? Bool, false)
        XCTAssertTrue(early["firstCompleteAfterSendMs"] is NSNull, "A code-block Copy button is not the assistant footer")
        XCTAssertEqual(early["currentComplete"] as? Bool, false)
        _ = try await evaluate(view, #"""
            document.getElementById('probe-user-body').textContent=globalThis.fixtureProbePayload;
            const controls=document.createElement('div'); controls.className='turn-action-controls';
            controls.innerHTML='<button data-testid="copy-turn-action-button" aria-label="Copy" disabled>Copy</button>';
            document.getElementById('probe-assistant').append(controls); return true;
            """#, world: Self.matchedProbeWorld)
        let full = try await waitForMatchedProbeState(view) { $0["payloadMatched"] as? Bool == true }
        XCTAssertEqual((full["firstTextAfterSendMs"] as? NSNumber)?.doubleValue, firstText, "Late body hashing must not restart the first-text clock")
        XCTAssertTrue(full["firstCompleteAfterSendMs"] is NSNull, "A disabled footer does not complete")
        _ = try await evaluate(view, "document.querySelector('[data-testid=copy-turn-action-button]').disabled=false; return true;", world: Self.matchedProbeWorld)
        let completed = try await waitForMatchedProbeState(view) { $0["currentComplete"] as? Bool == true }
        XCTAssertEqual(completed["invalidReason"] as? String, "none")
        XCTAssertEqual(completed["userSHA256"] as? String, config["expectedCanonicalSHA256"] as? String)
        XCTAssertEqual(completed["sendClickCount"] as? Int, 1)
        XCTAssertEqual(completed["userCount"] as? Int, 1)
        XCTAssertEqual(completed["assistantCount"] as? Int, 1)
        XCTAssertEqual((completed["firstTextAfterSendMs"] as? NSNumber)?.doubleValue, firstText)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap((completed["firstCompleteAfterSendMs"] as? NSNumber)?.doubleValue), firstText)
        let rawJSON = try await evaluate(view, "return globalThis.__computaMatchedBenchmarkProbeV1.read();", world: Self.matchedProbeWorld)
        let json = try XCTUnwrap(rawJSON as? String)
        XCTAssertLessThan(json.utf8.count, 4_096)
        XCTAssertFalse(json.contains("Computa synthetic"))
        XCTAssertFalse(json.contains("\"text\":\"HI\""))
    }

    func testMatchedProbeWrongPayloadAndFreshRootOrCountDriftCannotQualify() async throws {
        let (fixture, view, _, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        for mutation in ["wrong_editor", "wrong_body", "replace_user", "extra_user", "replace_answer", "extra_answer", "changed_body"] {
            try await resetMatchedProbePage(view)
            _ = try await installMatchedProbe(view, payload: "Exact matched benchmark payload café")
            if mutation == "wrong_editor" {
                _ = try await evaluate(view, "document.getElementById('prompt-textarea').value+=' extra'; document.querySelector('[data-testid=send-button]').click(); return true;", world: Self.matchedProbeWorld)
                let value = try await waitForMatchedProbeState(view) { $0["invalidReason"] as? String == "editor_mismatch" }
                XCTAssertEqual(value["payloadMatched"] as? Bool, false); continue
            }
            try await sendMatchedProbeFixture(view, body: mutation == "wrong_body" ? "Wrong body" : "Exact matched benchmark payload café", answer: #"{"type":"message","text":"HI"}"#, codeCopy: true)
            if mutation == "wrong_body" {
                let value = try await waitForMatchedProbeState(view) { $0["userMatchesExpected"] as? Bool == false }
                XCTAssertEqual(value["payloadMatched"] as? Bool, false, "A tentative response may never qualify against the wrong submitted body"); continue
            }
            _ = try await waitForMatchedProbeState(view) { $0["payloadMatched"] as? Bool == true }
            let command: String
            let reason: String
            switch mutation {
            case "replace_user": command = "const n=document.getElementById('probe-user'); n.replaceWith(n.cloneNode(true));"; reason = "user_root_changed"
            case "extra_user": command = "const n=document.getElementById('probe-user').cloneNode(true); n.id='extra'; document.querySelector('main').append(n);"; reason = "extra_user"
            case "replace_answer": command = "const n=document.getElementById('probe-assistant'); n.replaceWith(n.cloneNode(true));"; reason = "answer_root_changed"
            case "extra_answer": command = "const n=document.getElementById('probe-assistant').cloneNode(true); n.id='extra'; document.querySelector('main').append(n);"; reason = "extra_answer"
            default: command = "document.getElementById('probe-user-body').textContent+=' changed';"; reason = "user_body_changed"
            }
            _ = try await evaluate(view, command + " return true;", world: Self.matchedProbeWorld)
            let value = try await waitForMatchedProbeState(view) { $0["invalidReason"] as? String == reason }
            XCTAssertEqual(value["payloadMatched"] as? Bool, false, mutation)
        }
    }

    func testMatchedProbeEmptyAnswerClearsLatestResponseWithoutRewritingFirstMilestones() async throws {
        let (fixture, view, _, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        try await resetMatchedProbePage(view)
        _ = try await installMatchedProbe(view, payload: "Exact empty-answer fixture")
        try await sendMatchedProbeFixture(view, body: "Exact empty-answer fixture", answer: #"{"type":"message","text":"HI"}"#, codeCopy: true)
        _ = try await evaluate(view, #"""
            const controls=document.createElement('div'); controls.className='turn-action-controls';
            controls.innerHTML='<button data-testid="copy-turn-action-button" aria-label="Copy">Copy</button>';
            document.getElementById('probe-assistant').append(controls); return true;
            """#, world: Self.matchedProbeWorld)
        let before = try await waitForMatchedProbeState(view) { $0["payloadMatched"] as? Bool == true && $0["responseSHA256"] is String && $0["currentComplete"] as? Bool == true }
        _ = try await evaluate(view, "document.getElementById('probe-answer').replaceChildren(); return true;", world: Self.matchedProbeWorld)
        let empty = try await waitForMatchedProbeState(view) { $0["responseSHA256"] is NSNull }
        XCTAssertTrue(empty["responseUTF8Bytes"] is NSNull)
        XCTAssertEqual(empty["responseKind"] as? String, "none")
        XCTAssertEqual(empty["currentComplete"] as? Bool, false)
        XCTAssertEqual((empty["firstTextAfterSendMs"] as? NSNumber)?.doubleValue, (before["firstTextAfterSendMs"] as? NSNumber)?.doubleValue)
        XCTAssertEqual((empty["firstCompleteAfterSendMs"] as? NSNumber)?.doubleValue, (before["firstCompleteAfterSendMs"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(empty["payloadMatched"] as? Bool, true, "Prompt equality is intentionally distinct from a current valid answer")
    }

    private static let matchedProbeWorld = WKContentWorld.world(name: "computa-chatgpt-model-v1")
    private static let matchedProbeScript: Result<String, Error> = Result {
        let name = "Computa_Computa.bundle"
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [Bundle.main.bundleURL.deletingLastPathComponent(), executableDirectory]
            .compactMap { Bundle(url: $0.appendingPathComponent(name)) }
        let bundles = Bundle.allBundles + candidates + [Bundle.main]
        guard let url = bundles.compactMap({ $0.url(forResource: "chatgpt", withExtension: "js", subdirectory: "BrowserModels") }).first else {
            throw NSError(domain: "MatchedBenchmarkProbeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled ChatGPT resource missing"])
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let begin = "// BEGIN COMPUTA MATCHED BENCHMARK PROBE V1"
        let end = "// END COMPUTA MATCHED BENCHMARK PROBE V1."
        guard source.components(separatedBy: begin).count == 2, source.components(separatedBy: end).count == 2,
              let start = source.range(of: begin), let finish = source.range(of: end), start.lowerBound < finish.lowerBound else {
            throw NSError(domain: "MatchedBenchmarkProbeTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ambiguous fixed probe markers"])
        }
        // Do not rebuild the function or copy selectors into a second observer.
        return String(source[start.lowerBound..<finish.upperBound]) + "\n"
    }

    private func matchedProbeJSON(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }

    private func resetMatchedProbePage(_ view: WKWebView) async throws {
        _ = try await evaluate(view, #"""
            globalThis.__computaMatchedBenchmarkProbeV1?.stop(); delete globalThis.__computaMatchedBenchmarkProbeV1;
            document.body.innerHTML='<main></main><textarea id="prompt-textarea"></textarea><button id="probe-send" data-testid="send-button">Send</button>';
            return true;
            """#, world: Self.matchedProbeWorld)
    }

    @discardableResult private func installMatchedProbe(_ view: WKWebView, payload: String) async throws -> [String: Any] {
        let payloadJSON = try matchedProbeJSON(payload)
        let source = try Self.matchedProbeScript.get()
        let result = try await evaluate(view, #"""
            \#(source)
            globalThis.fixtureProbePayload=\#(payloadJSON);
            const bytes=new TextEncoder().encode(globalThis.fixtureProbePayload);
            const hash=async text => [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text)))].map(x=>x.toString(16).padStart(2,'0')).join('');
            globalThis.fixtureProbeConfig={schemaVersion:1,nonce:'cccccccc-1111-4222-8333-dddddddddddd',
              expectedSHA256:await hash(globalThis.fixtureProbePayload),
              expectedCanonicalSHA256:await hash(globalThis.fixtureProbePayload.replace(/\r\n?/g,'\n').normalize('NFC').trim()),expectedUTF8Bytes:bytes.length};
            document.getElementById('prompt-textarea').value=globalThis.fixtureProbePayload;
            globalThis.fixtureInstallMatchedProbe=computaInstallMatchedBenchmarkProbe;
            const probe=globalThis.fixtureInstallMatchedProbe(globalThis.fixtureProbeConfig);
            return probe ? globalThis.fixtureProbeConfig : null;
            """#, world: Self.matchedProbeWorld)
        return try XCTUnwrap(result as? [String: Any], "The exact bundled probe must install on a fresh synthetic root")
    }

    private func sendMatchedProbeFixture(_ view: WKWebView, body: String, answer: String, codeCopy: Bool) async throws {
        let bodyJSON = try matchedProbeJSON(body), answerJSON = try matchedProbeJSON(answer)
        _ = try await evaluate(view, #"""
            document.getElementById('probe-send').click();
            const user=document.createElement('article'); user.id='probe-user'; user.dataset.turn='user';
            const userBody=document.createElement('div'); userBody.id='probe-user-body'; userBody.dataset.markdownTextStyle='user-message'; userBody.style.whiteSpace='pre-wrap'; userBody.textContent=\#(bodyJSON); user.append(userBody);
            const article=document.createElement('article'); article.id='probe-assistant'; article.dataset.turn='assistant';
            const answer=document.createElement('div'); answer.id='probe-answer'; answer.dataset.markdownTextStyle='assistant-message';
            const text=\#(answerJSON);
            if (\#(codeCopy ? "true" : "false")) { const pre=document.createElement('pre'), code=document.createElement('code'), copy=document.createElement('button'); code.textContent=text; copy.setAttribute('aria-label','Copy'); copy.textContent='Copy code'; pre.append(code,copy); answer.append(pre); }
            else answer.textContent=text;
            article.append(answer); document.querySelector('main').append(user,article); return true;
            """#, world: Self.matchedProbeWorld)
    }

    private func matchedProbeState(_ view: WKWebView, maximumWait: Duration = .seconds(3)) async throws -> [String: Any] {
        let value = try await evaluate(view, "return globalThis.__computaMatchedBenchmarkProbeV1?.snapshot() || null;",
            world: Self.matchedProbeWorld, maximumWait: maximumWait)
        return try XCTUnwrap(value as? [String: Any])
    }

    private func waitForMatchedProbeState(_ view: WKWebView, file: StaticString = #filePath, line: UInt = #line,
                                         matching predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(5)
        var last: [String: Any] = [:]
        while ContinuousClock.now < deadline {
            let value = try await matchedProbeState(view, maximumWait: min(.seconds(1), deadline - .now))
            last = value
            if predicate(value) { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The real WebKit benchmark observation did not reach its bounded expected state: \(last)", file: file, line: line)
        throw FixtureFailure.timeout
    }

    func testMatchedBenchmarkProbeInstallsAtNativeFirstInsertSequenceZeroOnlyWhenCapturePublished() async throws {
        for armed in [false, true] {
            let (fixture, view, token, choice) = try await readyInstantPrepareFixture()
            defer { fixture.shutdown() }
            let root = try websiteBenchmarkTemporaryDirectory()
                .appendingPathComponent("benchmark-real-insert-phase-" + UUID().uuidString)
            let directory = root.appendingPathComponent("WebsiteBenchmarkDiagnostics-v1")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let nonce = UUID(), task = UUID(), thread = UUID(), turn = UUID()
            let nonceText = nonce.uuidString.lowercased()
            let policy = ComputaAgentInstructions.runtimeInteractionPolicy()
            let user = "Computa latency benchmark \(nonceText). Reply with exactly HI. Do not use tools."
                + "\n" + policy
            let input: [[String: Any]] = [
                ["type": "message", "role": "user", "content": [["type": "input_text", "text":
                    "<environment_context><cwd>/tmp/computa-empty-fixture</cwd><shell>zsh</shell></environment_context>"]]],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": user]]]]
            let request = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject:
                ["model": choice.modelID, "input": input, "instructions": "Synthetic native instruction prelude", "tools": []]))
            if armed {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
                let arm: [String: Any] = ["schemaVersion": 1, "purpose": "synthetic_latency_payload_v1", "nonce": nonceText,
                    "expiresAt": formatter.string(from: Date().addingTimeInterval(120))]
                let armURL = directory.appendingPathComponent("arm.json")
                try JSONSerialization.data(withJSONObject: arm).write(to: armURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armURL.path)
            }
            let lease = WebsiteBenchmarkCaptureLease.consume(directory: directory, request: request,
                taskID: task.uuidString.lowercased(), threadID: thread.uuidString.lowercased(), turnID: turn.uuidString.lowercased(),
                runtimeGeneration: websiteInferenceFixtureGeneration, preparationID: UUID(),
                isNewThread: true, isMaintenance: false, isFirstInference: true)
            XCTAssertEqual(lease != nil, armed)
            defer { lease?.revoke() }
            let before = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(before["state"] as? String, "ready")
            XCTAssertEqual(before["sequence"] as? Int, 0)
            var actions: [String] = [], insertProbe: [String: Any]?
            fixture.transport.setBeforePageResultValidationForTesting { action in
                actions.append(action)
                guard action == "insert" else { return }
                let value = try? await self.evaluate(view,
                    "return globalThis.__computaMatchedBenchmarkProbeV1?.snapshot() || null;",
                    world: .world(name: "computa-chatgpt-model-v1"))
                insertProbe = value as? [String: Any]
            }
            let sent = try await WebsiteBenchmarkCaptureLease.$current.withValue(lease) {
                try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": request.prompt])
            }
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1)
            XCTAssertEqual(actions.filter { $0 == "submit" }.count, 1)
            XCTAssertFalse(actions.contains("prepare"), "Exercise the actual fresh Instant folded-insert path")
            XCTAssertEqual(sent["sequence"] as? Int, 1)
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            if armed {
                let binding = try XCTUnwrap(lease?.observationBinding)
                let probe = try XCTUnwrap(insertProbe, "A published capture must install its observer before native sequence advances")
                XCTAssertEqual(probe["nonce"] as? String, binding.nonce.uuidString.lowercased())
                XCTAssertEqual(probe["expectedSHA256"] as? String, binding.rawOutboundSHA)
                XCTAssertEqual(probe["expectedCanonicalSHA256"] as? String, binding.canonicalOutboundSHA)
                XCTAssertEqual(probe["expectedUTF8Bytes"] as? Int, binding.utf8Bytes)
                XCTAssertEqual(probe["sendClickCount"] as? Int, 0, "The snapshot is taken at insert, before any Send")
                XCTAssertEqual(probe["userCount"] as? Int, 0)
                XCTAssertEqual(probe["assistantCount"] as? Int, 0)
                XCTAssertEqual(probe["invalidReason"] as? String, "none")
                let output = directory.appendingPathComponent("payload-" + nonceText + ".json")
                let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
                XCTAssertEqual(record["rawSHA256"] as? String, binding.rawOutboundSHA)
                XCTAssertEqual(record["sessionToken"] as? String, token.lowercased())
            } else {
                XCTAssertNil(insertProbe, "An ordinary unarmed inference must not install passive benchmark code")
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            }
            let complete = try await waitForState("complete", fixture.transport, token: token)
            try assertChoiceEvidence(complete, choice: choice)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testPreparationTimingIsFiniteContentFreeAndRemovedBeforeObservationParsing() throws {
        let timing: [String: Any] = ["totalMs": 805.25, "beginSubmissionMs": 2.25, "beginSubmissionHashMs": 1.5,
            "modelPrecheckMs": 31.75, "finalGuardMs": 45.5, "editorFocusMs": 0.25, "editorMutationMs": 5.25,
            "inputDispatchMs": NSNull(), "editorReadinessMs": NSNull(), "editorReadyAtEntry": NSNull(), "openingRecoveryUsed": false,
            "outerSetupMs": 1.0, "guardedSetupMs": 2.0, "providerEntryMs": 3.0, "providerSetupMs": 4.0,
            "insertPreFocusMs": 5.0, "insertPostFocusMs": 6.0, "providerReturnMs": 7.0,
            "guardedFinalizationMs": 8.0, "outerFinalizationMs": 9.0]
        let original: [String: Any] = ["inserted": true, "submissionOwnershipCapability": "unchanged"]
        var observed = original; observed["preparationTiming"] = timing
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.removePreparationTiming(from: &observed))
        XCTAssertEqual(NSDictionary(dictionary: observed), NSDictionary(dictionary: original))
        XCTAssertEqual(NSDictionary(dictionary: safe), NSDictionary(dictionary: timing))
        let data = try JSONSerialization.data(withJSONObject: safe, options: .sortedKeys)
        XCTAssertLessThan(data.count, 1_024)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("unchanged"))
        XCTAssertNil(EmbeddedWebModelTransport.removePreparationTiming(from: &observed))
        XCTAssertEqual(NSDictionary(dictionary: observed), NSDictionary(dictionary: original))
    }

    func testMalformedPreparationTimingCannotChangeAnObservationOrGrantAuthority() {
        let valid: [String: Any] = ["totalMs": 8.0, "beginSubmissionMs": NSNull(), "beginSubmissionHashMs": NSNull(),
            "modelPrecheckMs": 1.0, "finalGuardMs": 2.0, "editorFocusMs": NSNull(), "editorMutationMs": 3.0,
            "inputDispatchMs": 1.0, "editorReadinessMs": 1.0, "editorReadyAtEntry": false, "openingRecoveryUsed": true,
            "outerSetupMs": NSNull(), "guardedSetupMs": NSNull(), "providerEntryMs": NSNull(), "providerSetupMs": NSNull(),
            "insertPreFocusMs": NSNull(), "insertPostFocusMs": NSNull(), "providerReturnMs": NSNull(),
            "guardedFinalizationMs": NSNull(), "outerFinalizationMs": NSNull()]
        var cases: [Any] = [NSNull(), [], "PRIVATE_TIMING_CANARY"]
        for key in valid.keys { var bad = valid; bad.removeValue(forKey: key); cases.append(bad) }
        var unknown = valid; unknown["PRIVATE_TIMING_CANARY"] = "PRIVATE_VALUE_CANARY"; cases.append(unknown)
        let invalidDurations: [Any] = [true, -1, 45_000.001, Double.nan, Double.infinity, "8", [], [:]]
        for value in invalidDurations {
            var bad = valid; bad["totalMs"] = value; cases.append(bad)
            var focus = valid; focus["editorFocusMs"] = value; cases.append(focus)
            for key in ["outerSetupMs", "guardedSetupMs", "providerEntryMs", "providerSetupMs", "insertPreFocusMs",
                        "insertPostFocusMs", "providerReturnMs", "guardedFinalizationMs", "outerFinalizationMs"] {
                var span = valid; span[key] = value; cases.append(span)
            }
        }
        let invalidFlags: [Any] = [0, 1, NSNull(), "true"]
        for value in invalidFlags {
            var bad = valid; bad["openingRecoveryUsed"] = value; cases.append(bad)
        }
        for value in invalidFlags where !(value is NSNull) {
            var bad = valid; bad["editorReadyAtEntry"] = value; cases.append(bad)
        }
        for raw in cases {
            var observed: [String: Any] = ["error": "model_mismatch", "preparationTiming": raw]
            XCTAssertNil(EmbeddedWebModelTransport.removePreparationTiming(from: &observed))
            XCTAssertEqual(NSDictionary(dictionary: observed), NSDictionary(dictionary: ["error": "model_mismatch"]))
        }
    }

    func testRendererGuardProjectionPreservesFiniteDeclinesAndUnknownFacts() throws {
        let matched: [String: Any] = ["reason": "matched", "subject": "other", "visitedNodeCount": 5,
            "rawKnownLabel": true, "trimmedKnownLabel": true, "guardBodyIsExtractedAnswer": true,
            "bodyIsRoot": false, "knownScopedCopyOutsideDIL": true, "rejectedDisplayContents": NSNull()]
        let early: [String: Any] = ["reason": "root_missing", "subject": "none", "visitedNodeCount": 0,
            "rawKnownLabel": NSNull(), "trimmedKnownLabel": NSNull(), "guardBodyIsExtractedAnswer": NSNull(),
            "bodyIsRoot": NSNull(), "knownScopedCopyOutsideDIL": NSNull(), "rejectedDisplayContents": NSNull()]
        var whitespace = matched
        whitespace["reason"] = "raw_label_differs"; whitespace["subject"] = "text_leaf"; whitespace["rawKnownLabel"] = false
        var layout = early
        layout["reason"] = "node_not_visible"; layout["subject"] = "dil_pair"; layout["visitedNodeCount"] = 3
        layout["bodyIsRoot"] = false; layout["guardBodyIsExtractedAnswer"] = true; layout["rejectedDisplayContents"] = true
        for input in [matched, early, whitespace, layout] {
            let projected = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedRendererGuardDiagnostic(input))
            XCTAssertEqual(Set(projected.keys), Set(input.keys))
            let bytes = try JSONSerialization.data(withJSONObject: projected, options: .sortedKeys)
            XCTAssertLessThanOrEqual(bytes.count, 768)
            let structure: [String: Any] = ["preCount": 0, "codeCount": 0, "codeTextLength": 0,
                "outsideTextLength": 27, "outsideTruncated": false, "preParentTags": [], "rendererGuard": input]
            let encoded = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedCodeStructure(structure))
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
            XCTAssertNotNil(decoded["rendererGuard"] as? [String: Any])
            XCTAssertFalse(encoded.contains("This response")); XCTAssertFalse(encoded.contains("https://"))
        }
    }

    func testRendererGuardProjectionRejectsUnknownFieldsTypesRangesAndImpossibleRelations() {
        let valid: [String: Any] = ["reason": "matched", "subject": "other", "visitedNodeCount": 5,
            "rawKnownLabel": true, "trimmedKnownLabel": true, "guardBodyIsExtractedAnswer": true,
            "bodyIsRoot": false, "knownScopedCopyOutsideDIL": true, "rejectedDisplayContents": NSNull()]
        func rejected(_ raw: Any, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedRendererGuardDiagnostic(raw), file: file, line: line)
            let structure: [String: Any] = ["preCount": 0, "codeCount": 0, "codeTextLength": 0,
                "outsideTextLength": 27, "outsideTruncated": false, "preParentTags": [], "rendererGuard": raw]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(structure), file: file, line: line)
        }
        rejected(NSNull()); rejected([])
        for key in valid.keys { var bad = valid; bad.removeValue(forKey: key); rejected(bad) }
        var bad = valid; bad["text"] = "PRIVATE_RENDERER_CANARY"; rejected(bad)
        for key in ["reason", "subject"] { bad = valid; bad[key] = "PRIVATE_RENDERER_CANARY"; rejected(bad) }
        let counts: [Any] = [-1, 66, 1.5, true, NSNull(), "5", Double.nan, Double.infinity]
        for value in counts { bad = valid; bad["visitedNodeCount"] = value; rejected(bad) }
        for key in ["rawKnownLabel", "trimmedKnownLabel", "guardBodyIsExtractedAnswer", "bodyIsRoot",
                    "knownScopedCopyOutsideDIL", "rejectedDisplayContents"] {
            let values: [Any] = [0, 1, "true", [], [:]]
            for value in values { bad = valid; bad[key] = value; rejected(bad) }
        }
        let alterations: [[String: Any]] = [
            ["trimmedKnownLabel": false], ["rawKnownLabel": NSNull()],
            ["guardBodyIsExtractedAnswer": NSNull()], ["guardBodyIsExtractedAnswer": false], ["bodyIsRoot": NSNull()],
            ["rejectedDisplayContents": true], ["visitedNodeCount": 0], ["visitedNodeCount": 65],
            ["reason": "node_budget"], ["rawKnownLabel": false]]
        for alteration in alterations { bad = valid; bad.merge(alteration) { _, new in new }; rejected(bad) }
    }

    func testRendererGuardFactsSurviveOwnedCompletionWithoutChangingTextOrInputs() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Read only the current completed response"])
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        let completion = try XCTUnwrap(complete["completionEvidence"] as? [String: Any])
        let structure = try XCTUnwrap(completion["codeStructure"] as? [String: Any])
        let facts = try XCTUnwrap(structure["rendererGuard"] as? [String: Any])
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererGuardDiagnostic(facts))
        // This fixture has a plain #messages DIV, without the MAIN boundary
        // required by the unchanged classifier. Preserve that first decline;
        // extraction later finding a body must not invent earlier guard facts.
        XCTAssertEqual(facts["reason"] as? String, "conversation_boundary_missing")
        XCTAssertEqual(facts["visitedNodeCount"] as? Int, 0)
        XCTAssertTrue(facts["guardBodyIsExtractedAnswer"] is NSNull)
        XCTAssertTrue(facts["bodyIsRoot"] is NSNull)
        XCTAssertTrue(facts["rawKnownLabel"] is NSNull); XCTAssertTrue(facts["trimmedKnownLabel"] is NSNull)
        XCTAssertTrue(facts["knownScopedCopyOutsideDIL"] is NSNull)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTDispatchReceiptRequiresOnlyStrictEmptyContinuationFields() throws {
        let receipt: [String: Any] = ["submitted": true, "submissionPending": true, "modelVerificationPending": true,
            "temporary": true, "chatModeReady": true, "chatModeActionAvailable": false, "productModeEvidence": [:],
            "submissionOwnershipCapability": "per_submission_ownership_v1", "text": "", "answerComplete": false,
            "firstUserVerified": true, "firstUserMarkerVerified": true, "firstUserFingerprint": String(repeating: "a", count: 64)]
        XCTAssertTrue(EmbeddedWebModelTransport.isChatGPTDispatchOnlySubmissionAcknowledgement(receipt))
        for key in receipt.keys {
            var missing = receipt; missing.removeValue(forKey: key)
            XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTDispatchOnlySubmissionAcknowledgement(missing), key)
        }
        for key in ["submitted", "submissionPending", "modelVerificationPending", "temporary", "chatModeReady",
                    "chatModeActionAvailable", "answerComplete", "firstUserVerified", "firstUserMarkerVerified"] {
            let values: [Any] = [NSNull(), 0, 1, "true", !(receipt[key] as! Bool)]
            for value in values {
                var malformed = receipt; malformed[key] = value
                XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTDispatchOnlySubmissionAcknowledgement(malformed), key)
            }
        }
        let alterations: [(String, Any)] = [("text", "unverified answer"), ("text", NSNull()),
            ("firstUserFingerprint", String(repeating: "A", count: 64)), ("firstUserFingerprint", String(repeating: "a", count: 63)),
            ("firstUserFingerprint", NSNull()), ("submissionOwnershipCapability", "legacy"), ("productModeEvidence", NSNull()),
            ("url", "https://chatgpt.com/"), ("modelEvidence", [:]), ("submissionProof", [:]),
            ("completionEvidence", [:]), ("userCount", 2), ("responseCount", 2), ("unknown", false)]
        for (key, value) in alterations {
            var malformed = receipt; malformed[key] = value
            XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTDispatchOnlySubmissionAcknowledgement(malformed), key)
        }
        var measured = receipt; measured["resourceTimingDiagnostic"] = [:]
        XCTAssertTrue(EmbeddedWebModelTransport.isChatGPTDispatchOnlySubmissionAcknowledgement(measured))
    }

    func testChatGPTOptimisticPendingPacketRejectsProofFieldsAndWrongSubmission() {
        let hash = String(repeating: "a", count: 64)
        let packet: [String: Any] = ["error": "submission_observation_pending", "detail": "optimistic_user_body",
            "submissionSequence": 1, "submissionFingerprint": hash]
        XCTAssertTrue(EmbeddedWebModelTransport.isChatGPTOptimisticSubmissionPending(packet, sequence: 1, fingerprint: hash))
        var retained = packet; retained["submissionSequence"] = 2
        XCTAssertTrue(EmbeddedWebModelTransport.isChatGPTOptimisticSubmissionPending(retained, sequence: 2, fingerprint: hash))
        for key in packet.keys {
            var missing = packet; missing.removeValue(forKey: key)
            XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTOptimisticSubmissionPending(missing, sequence: 1, fingerprint: hash), key)
        }
        let changes: [(String, Any)] = [("error", "other"), ("detail", "readonly_model_observation"),
            ("submissionSequence", true), ("submissionSequence", 1.5), ("submissionSequence", "1"),
            ("submissionSequence", 0), ("submissionSequence", 2), ("submissionSequence", NSNull()),
            ("submissionFingerprint", String(repeating: "A", count: 64)), ("submissionFingerprint", String(repeating: "a", count: 63)),
            ("submissionFingerprint", String(repeating: "b", count: 64)), ("submissionFingerprint", NSNull()),
            ("url", "https://chatgpt.com/"), ("text", "unverified reply"), ("firstUserVerified", true),
            ("submissionProof", [:]), ("modelEvidence", [:]), ("answerComplete", false)]
        for (key, value) in changes {
            var changed = packet; changed[key] = value
            XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTOptimisticSubmissionPending(changed, sequence: 1, fingerprint: hash), key)
        }
        XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTOptimisticSubmissionPending(packet, sequence: 0, fingerprint: hash))
        var overLimit = packet; overLimit["submissionSequence"] = 17
        XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTOptimisticSubmissionPending(overLimit, sequence: 17, fingerprint: hash))
        let product: [String: Any] = ["chatModeReady": true, "chatModeActionAvailable": false,
            "productModeEvidence": [:], "temporary": true]
        XCTAssertTrue(EmbeddedWebModelTransport.isChatGPTPendingProductReceipt(product))
        for key in product.keys {
            var missing = product; missing.removeValue(forKey: key)
            XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTPendingProductReceipt(missing), key)
        }
        for (key, value) in [("chatModeReady", 1), ("chatModeActionAvailable", true), ("temporary", false),
                             ("productModeEvidence", NSNull()), ("url", "https://chatgpt.com/"),
                             ("firstUserFingerprint", hash), ("text", "reply"), ("userCount", 1)] as [(String, Any)] {
            var changed = product; changed[key] = value
            XCTAssertFalse(EmbeddedWebModelTransport.isChatGPTPendingProductReceipt(changed), key)
        }
    }

    func testChatGPTContinuationDispatchWithholdsOutputUntilFreshProductModelAndBodyProof() async throws {
        for drift in ["work", "temporary", "model", "body"] {
            let fixture = try Fixture()
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Complete the first verified round"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            var crossed = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "submit", !crossed else { return }
                crossed = true
                let mutation: String
                switch drift {
                case "work": mutation = """
                    document.getElementById('fixture-composer-mode').hidden = false;
                    document.getElementById('fixture-chat-mode').setAttribute('aria-pressed','false');
                    document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true');
                    """
                case "temporary": mutation = """
                    const control = document.querySelector('[aria-label="Turn off temporary chat"]');
                    if (!control) return false;
                    control.remove();
                    """
                case "model": mutation = """
                    const before = window.fixtureModelCurrentLabel;
                    window.fixtureModelSelect(window.fixtureModelInitialLabel);
                    if (before === window.fixtureModelCurrentLabel) return false;
                    """
                default: mutation = "document.querySelectorAll('[data-markdown-text-style=\"user-message\"]')[1].textContent = 'Unowned substituted body';"
                }
                let changed = try? await self.evaluate(view, mutation + " return true;") as? Bool
                XCTAssertEqual(changed, true, "The \(drift) fixture must actually change the proved control/body")
            }
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never accept an unverified continuation"])
            XCTAssertTrue(crossed)
            XCTAssertEqual(sent["state"] as? String, "running"); XCTAssertEqual(sent["text"] as? String, "")
            XCTAssertEqual(sent["modelVerificationPending"] as? Bool, true)
            XCTAssertNil(sent["modelEvidence"]); XCTAssertNil(sent["modelProofContext"]); XCTAssertNil(sent["completionEvidence"])
            let pending = try XCTUnwrap(sent["pendingSubmissionContext"] as? [String: Any])
            XCTAssertEqual(pending["sequence"] as? Int, 2); XCTAssertEqual(pending["submittedPromptFingerprint"] as? String, "")
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never replay a dispatched continuation"])
            do {
                let first = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(first["state"] as? String, "running")
                XCTAssertEqual(first["text"] as? String, "")
                XCTAssertNil(first["modelEvidence"]); XCTAssertNil(first["modelProofContext"])
                _ = try await waitForState("complete", fixture.transport, token: token)
                XCTFail("A dispatch acknowledgement cannot admit \(drift) drift as an answer")
            } catch {
                let expected: EmbeddedWebModelTransport.Failure = drift == "work" ? .productModeUnverified
                    : drift == "temporary" ? .temporaryUnverified
                    : drift == "model" ? .modelMismatch : .ownershipFailure(.javaScriptSubmission)
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expected, drift)
            }
            try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        }
    }

    func testChatGPTContinuationDispatchCancellationCannotReturnAnAcknowledgementOrReplaySend() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "First complete round"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        var crossed = false, release = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "submit" else { return }
            crossed = true
            while !release { await Task.yield() }
        }
        let request = Task<Bool, Error> {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Cancel after one actual Send"])
            return true
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !crossed, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(crossed)
        request.cancel(); release = true
        do { _ = try await request.value; XCTFail("A cancelled post-await acknowledgement cannot return") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Do not replay a lost acknowledgement"])
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["sequence"] as? Int, 2, "Only a later independent poll can prove the dispatched body")
        try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
    }

    func testChatGPTContinuationDispatchCannotCrossTheNativeConversationRoute() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Pin the initial round"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "submit" else { return }
            _ = try? await self.evaluate(view, "history.pushState({}, '', '/c/00000000-0000-0000-0000-000000000001'); return true;")
        }
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "A crossed native route cannot acknowledge"])
            XCTFail("Native route continuity remains mandatory after one Send")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.routeAfter)) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never replay across route drift"])
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
    }

    func testThirdChatGPTDispatchAcknowledgementDoesNotAwaitAnotherBodyRead() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        for sequence in 1...2 {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Complete owned round \(sequence)"])
            _ = try await waitForState("complete", fixture.transport, token: token)
        }
        var intercepted = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "submit", !intercepted else { return }
            intercepted = true
            let facts = try? await self.evaluate(view, """
                const state = globalThis.__computaChatSubmissionState;
                globalThis.__fixtureOriginalDigest = crypto.subtle.digest;
                globalThis.__fixturePostDispatchBodyReads = 0;
                crypto.subtle.digest = () => {
                  globalThis.__fixturePostDispatchBodyReads++;
                  return new Promise(() => {});
                };
                return {pending: state?.pending?.sequence, confirmed: state?.lastVerified?.sequence,
                  phase: state?.pending?.phase};
                """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
            XCTAssertEqual(facts?["pending"] as? Int, 3)
            XCTAssertEqual(facts?["confirmed"] as? Int, 2)
            XCTAssertEqual(facts?["phase"] as? String, "send_claimed")
        }
        let began = ContinuousClock.now
        do {
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "A third Send returns dispatch only"])
            XCTAssertEqual(sent["state"] as? String, "running")
            XCTAssertEqual(sent["text"] as? String, "")
            XCTAssertEqual(sent["modelVerificationPending"] as? Bool, true)
            XCTAssertNil(sent["modelEvidence"]); XCTAssertNil(sent["completionEvidence"])
            XCTAssertNil(sent["modelProofContext"])
            let pending = try XCTUnwrap(sent["pendingSubmissionContext"] as? [String: Any])
            XCTAssertEqual(pending["sequence"] as? Int, 3)
            XCTAssertEqual(pending["submittedPromptFingerprint"] as? String, "")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .pageUnavailable)
            try await assertChoiceLedger(view, insertions: 3, sends: 3, selections: 1)
            let reads = try await evaluate(view, "return globalThis.__fixturePostDispatchBodyReads;",
                world: .world(name: "computa-chatgpt-model-v1")) as? Int
            XCTAssertEqual(reads, 1, "The original failure is the redundant post-Send ownership/body read")
            XCTFail("A dispatch-only acknowledgement must not time out awaiting another body read after one Send")
            return
        }
        XCTAssertTrue(intercepted)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5))
        let reads = try await evaluate(view, """
            crypto.subtle.digest = globalThis.__fixtureOriginalDigest;
            return globalThis.__fixturePostDispatchBodyReads;
            """, world: .world(name: "computa-chatgpt-model-v1")) as? Int
        XCTAssertEqual(reads, 0)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["sequence"] as? Int, 3)
        let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual(proof["submittedPromptFingerprint"] as? String,
            EmbeddedWebModelTransport.promptFingerprint("A third Send returns dispatch only"))
        try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
        try await assertChoiceLedger(view, insertions: 3, sends: 3, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testFirstInstantFoldsFocusIntoInsertButRetainedAppendStillPrepares() async throws {
        let (fixture, view, token, choice) = try await readyInstantPrepareFixture(synchronousReadiness: true)
        defer { fixture.shutdown() }
        for round in 1...2 {
            var actions: [String] = [], readinessPickerReads: [Int] = []
            let initialOpens = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
            var lastOpens = try XCTUnwrap(initialOpens)
            fixture.transport.setBeforePageResultValidationForTesting { action in
                actions.append(action)
                guard let opens = try? await self.evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int else {
                    XCTFail("Read the independent picker action ledger"); return
                }
                if action == "sendReady" { readinessPickerReads.append(opens - lastOpens) }
                lastOpens = opens
            }
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "Exact first Instant focus and retained append round \(round)"])
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            XCTAssertEqual(actions.filter { $0 == "prepare" }.count, round == 1 ? 0 : 1)
            XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1)
            XCTAssertEqual(actions.filter { $0 == "submit" }.count, 1)
            if round == 1 {
                XCTAssertTrue(readinessPickerReads.isEmpty, "A fresh prepared Instant receipt skips the separate readiness action")
                let insert = try XCTUnwrap(actions.firstIndex(of: "insert"))
                let submit = try XCTUnwrap(actions.firstIndex(of: "submit"))
                XCTAssertEqual(Array(actions[insert..<submit]), ["insert", "verifyModel", "verifyProductMode"])
            } else {
                XCTAssertFalse(readinessPickerReads.isEmpty, "Retained rounds keep the original readiness loop")
                XCTAssertTrue(readinessPickerReads.allSatisfy { $0 == 2 })
            }
            XCTAssertTrue(actions.contains("verifyModel")); XCTAssertTrue(actions.contains("verifyProductMode"))
            let complete = try await waitForState("complete", fixture.transport, token: token)
            try assertChoiceEvidence(complete, choice: choice)
            try await assertChoiceLedger(view, insertions: round, sends: round, selections: 0)
        }
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testFirstInstantPreparedEditorReadinessAcceptsExactLongEditorClippedByItsScroller() async throws {
        let (fixture, view, token, choice) = try await readyInstantPrepareFixture(synchronousReadiness: true)
        defer {
            fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            fixture.shutdown()
        }
        _ = try await evaluate(view, """
            // The actual editable grows with its full body inside a short
            // scroll container; its geometric center is not the visible caret.
            document.getElementById('prompt-textarea').style.cssText =
              'position:fixed;left:20px;top:120px;width:620px;height:80px;overflow:auto';
            document.querySelector('[data-testid="send-button"]').style.cssText =
              'position:fixed;left:20px;top:240px;z-index:10000';
            return true;
            """)
        var actions: [String] = [], positiveHints = 0
        var geometry: [String: Any]?
        fixture.transport.setPreparedEditorReadinessTransformForTesting { raw in
            XCTAssertEqual((raw as? [String: Any])?["ready"] as? Bool, true,
                           "The real terminal product read must recognize the exact prepared editor")
            if (raw as? [String: Any])?["ready"] as? Bool == true { positiveHints += 1 }
            return raw
        }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            actions.append(action)
            guard action == "insert" else { return }
            geometry = try? await self.evaluate(view, """
                const editor = document.getElementById('fixture-editor');
                const scroller = document.getElementById('prompt-textarea');
                const send = document.querySelector('[data-testid="send-button"]');
                const rect = editor.getBoundingClientRect(), clip = scroller.getBoundingClientRect();
                const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
                const hit = document.elementFromPoint(x, y), button = send.getBoundingClientRect();
                const sendX = button.left + button.width / 2, sendY = button.top + button.height / 2;
                const sendHit = document.elementFromPoint(sendX, sendY);
                return { editorTall: rect.height > window.innerHeight,
                  editorCenterOutsideViewport: y >= window.innerHeight,
                  editorCenterClipped: y >= clip.bottom,
                  editorCenterHit: hit === editor || !!hit && editor.contains(hit),
                  editorConnected: editor.isConnected, editorHasLayout: editor.getClientRects().length > 0,
                  sendEnabled: !send.disabled && send.getAttribute('aria-disabled') !== 'true',
                  sendCenterInViewport: sendX >= 0 && sendY >= 0 && sendX < window.innerWidth && sendY < window.innerHeight,
                  sendCenterHit: sendHit === send || !!sendHit && send.contains(sendHit) };
                """) as? [String: Any]
        }
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": String(repeating: "Clipped editor exact ownership line.\n", count: 1_400)])
        fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        let observed = try XCTUnwrap(geometry)
        for key in ["editorTall", "editorCenterOutsideViewport", "editorCenterClipped", "editorConnected",
                    "editorHasLayout", "sendEnabled", "sendCenterInViewport", "sendCenterHit"] {
            XCTAssertEqual(observed[key] as? Bool, true, key)
        }
        XCTAssertEqual(observed["editorCenterHit"] as? Bool, false)
        XCTAssertEqual(positiveHints, 1)
        let insert = try XCTUnwrap(actions.firstIndex(of: "insert"))
        let submit = try XCTUnwrap(actions.firstIndex(of: "submit"))
        XCTAssertEqual(Array(actions[insert..<submit]), ["insert", "verifyModel", "verifyProductMode"])
        XCTAssertFalse(actions.contains("sendReady"), "A clipped editor center must not add another readiness RPC")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testFirstInstantPreparedEditorReadinessOptionalFailuresKeepOriginalLoop() async throws {
        for fault in ["absent", "false", "numeric", "string", "extra", "marker", "fingerprint", "sequence"] {
            let (fixture, view, token, choice) = try await readyInstantPrepareFixture(synchronousReadiness: true)
            defer {
                fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
                fixture.transport.setBeforePageResultValidationForTesting(nil)
                fixture.shutdown()
            }
            var actions: [String] = [], hints = 0
            fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
            fixture.transport.setPreparedEditorReadinessTransformForTesting { raw in
                hints += 1
                guard var hint = raw as? [String: Any] else { XCTFail("Expected the actual terminal product hint"); return raw }
                XCTAssertEqual(hint["ready"] as? Bool, true, fault)
                switch fault {
                case "absent": return nil
                case "false": hint["ready"] = false
                case "numeric": hint["ready"] = 1
                case "string": hint["ready"] = "true"
                case "extra": hint["unexpected"] = true
                case "marker": hint["marker"] = UUID().uuidString.lowercased()
                case "fingerprint": hint["fingerprint"] = String(repeating: "0", count: 64)
                default: hint["sequence"] = 2
                }
                return hint
            }
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "An optional readiness \(fault) cannot replace the original loop"])
            fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            XCTAssertEqual(hints, 1, fault)
            let insert = try XCTUnwrap(actions.firstIndex(of: "insert"))
            let ready = try XCTUnwrap(actions.firstIndex(of: "sendReady"))
            XCTAssertEqual(Array(actions[insert..<ready]), ["insert", "verifyModel", "verifyProductMode"], fault)
            XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1, fault)
            XCTAssertEqual(actions.filter { $0 == "submit" }.count, 1, fault)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
            _ = try await waitForState("complete", fixture.transport, token: token)
        }
    }

    func testFirstInstantPreparedEditorReadinessCannotRelaxRawBodyOrSubmitRecheck() async throws {
        for drift in ["nfc_at_insert", "body_after_hint", "disabled_after_hint"] {
            let (fixture, view, token, _) = try await readyInstantPrepareFixture(synchronousReadiness: true)
            defer {
                fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
                fixture.transport.setBeforePageResultValidationForTesting(nil)
                fixture.shutdown()
            }
            var actions: [String] = [], changed = false, readyHints = 0
            fixture.transport.setPreparedEditorReadinessTransformForTesting { raw in
                if (raw as? [String: Any])?["ready"] as? Bool == true { readyHints += 1 }
                return raw
            }
            fixture.transport.setBeforePageResultValidationForTesting { action in
                actions.append(action)
                guard !changed, actions.contains("insert"),
                      action == (drift == "nfc_at_insert" ? "insert" : "verifyProductMode") else { return }
                changed = true
                let mutated = try? await self.evaluate(view, """
                    // Let the fixture's one normalization finish before deliberately changing its physical editor/control.
                    while (window.fixtureNormalizationCount < 1) await new Promise(resolve => setTimeout(resolve, 5));
                    const editor = document.getElementById('fixture-editor');
                    const drift = \(String(reflecting: drift)), before = editor.innerText;
                    if (drift === 'disabled_after_hint') {
                      document.querySelector('[data-testid="send-button"]').disabled = true; return true;
                    }
                    editor.textContent = drift === 'nfc_at_insert' ? before.normalize('NFC') : before + ' changed';
                    return editor.innerText !== before;
                    """)
                XCTAssertEqual(mutated as? Bool, true, drift)
            }
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "Preserve decomposed cafe\u{301} and emoji 🌍 exactly"])
                XCTFail("The \(drift) mutation must reject before Send")
            } catch {
                if drift == "disabled_after_hint" {
                    XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .editorFailure("send_unavailable"), drift)
                } else if case .editorFailure(let detail) = error as? EmbeddedWebModelTransport.Failure {
                    XCTAssertTrue(detail.hasPrefix("text_difference;"), detail)
                } else {
                    XCTFail("Expected the existing exact editor comparison to reject \(drift): \(error)")
                }
            }
            fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertTrue(changed, drift)
            XCTAssertEqual(readyHints, drift == "nfc_at_insert" ? 0 : 1, drift)
            XCTAssertEqual(actions.contains("sendReady"), drift == "nfc_at_insert", drift)
            XCTAssertEqual(actions.contains("submit"), drift != "nfc_at_insert", drift)
            try await assertChoiceLedger(view, insertions: 1, sends: 0, selections: 0)
        }
    }

    func testFirstInstantPositivePreparedReadinessCannotSurviveCancellationBeforeSend() async throws {
        let (fixture, view, token, _) = try await readyInstantPrepareFixture(synchronousReadiness: true)
        defer {
            fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            fixture.shutdown()
        }
        var actions: [String] = [], positiveHints = 0, cancelledCurrentRequest = false
        fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
        fixture.transport.setPreparedEditorReadinessTransformForTesting { raw in
            guard (raw as? [String: Any])?["ready"] as? Bool == true else {
                XCTFail("Expected the real terminal product observation's positive readiness hint")
                return raw
            }
            positiveHints += 1
            // Cancel the actual child request after observing its real hint.
            // There is no timer, polling race or cancellation of the XCTest task.
            withUnsafeCurrentTask { task in
                XCTAssertNotNil(task)
                task?.cancel()
                cancelledCurrentRequest = task?.isCancelled == true
            }
            return raw
        }
        let sending = Task<Void, Error> {
            _ = try await self.call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "A positive prepared-readiness observation cannot override cancellation"])
        }
        do { try await sending.value; XCTFail("Cancellation after a positive hint must reject before Send") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertEqual(positiveHints, 1)
        XCTAssertTrue(cancelledCurrentRequest)
        let insert = try XCTUnwrap(actions.firstIndex(of: "insert"))
        XCTAssertEqual(Array(actions[insert...]), ["insert", "verifyModel", "verifyProductMode"])
        try await assertChoiceLedger(view, insertions: 1, sends: 0, selections: 0)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testFirstInstantPositivePreparedReadinessCannotSurviveNativeGenerationInvalidation() async throws {
        let (fixture, view, token, _) = try await readyInstantPrepareFixture(synchronousReadiness: true)
        defer {
            fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            fixture.shutdown()
        }
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let generation = try XCTUnwrap(fixture.browser.documentGeneration(for: ownedID))
        var actions: [String] = [], positiveHints = 0
        fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
        fixture.transport.setPreparedEditorReadinessTransformForTesting { raw in
            guard (raw as? [String: Any])?["ready"] as? Bool == true else {
                XCTFail("Expected the real terminal product observation's positive readiness hint")
                return raw
            }
            positiveHints += 1
            // The real native Stop lifecycle synchronously invalidates this
            // view's document generation without replacing the rendered DOM.
            fixture.browser.stop(tabID: ownedID)
            return raw
        }
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "A positive prepared-readiness observation belongs to one native generation"])
            XCTFail("The invalidated generation must reject before Send")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.documentGenerationBefore))
        }
        fixture.transport.setPreparedEditorReadinessTransformForTesting(nil)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertEqual(positiveHints, 1)
        XCTAssertNotEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
        XCTAssertFalse(actions.contains("submit"))
        XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 0, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        try await assertHumanTabIntact(fixture, retaining: ownedID)
    }

    func testFirstInstantReadonlyReadinessPreservesTransientEnableWaitAndOriginalDeadline() async throws {
        for enables in [true, false] {
            let (fixture, view, token, choice) = try await readyInstantPrepareFixture()
            defer { fixture.shutdown() }
            var actions: [String] = [], disabled = false
            var firstReadiness: ContinuousClock.Instant?
            fixture.transport.setBeforePageResultValidationForTesting { action in
                actions.append(action)
                if action == "sendReady", firstReadiness == nil {
                    firstReadiness = .now
                    if enables {
                        // Release only after the first real disabled-control
                        // observation returns; no wall-clock race can skip it.
                        let stillDisabled = try? await self.evaluate(view, "return document.querySelector('[data-testid=send-button]').disabled;")
                        XCTAssertEqual(stillDisabled as? Bool, true)
                        let changed = try? await self.evaluate(view, """
                            document.querySelector('[data-testid=send-button]').disabled = false;
                            window.fixtureControlledSendReenabled = true; return true;
                            """)
                        XCTAssertEqual(changed as? Bool, true)
                    }
                }
                guard action == "insert", !disabled else { return }
                disabled = true
                let changed = try? await self.evaluate(view, """
                    document.querySelector('[data-testid=send-button]').disabled = true;
                    window.fixtureControlledSendReenabled = false; return true;
                    """)
                XCTAssertEqual(changed as? Bool, true)
            }
            do {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "Observe transient Send readiness without repeating input or renewing the original wait deadline"])
                XCTAssertTrue(enables, "A permanently disabled Send must time out")
                try assertRunningOrVerifiedChoice(sent, choice: choice)
            } catch {
                XCTAssertFalse(enables, "Transient Send re-enabling should complete through the unchanged readiness wait")
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .editorFailure("send_unavailable"))
            }
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertTrue(disabled); XCTAssertTrue(actions.contains("sendReady"))
            XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1)
            XCTAssertEqual(actions.filter { $0 == "submit" }.count, enables ? 1 : 0)
            if enables {
                XCTAssertGreaterThanOrEqual(actions.filter { $0 == "sendReady" }.count, 2)
                let reenabled = try await evaluate(view, "return window.fixtureControlledSendReenabled;") as? Bool
                XCTAssertEqual(reenabled, true)
                _ = try await waitForState("complete", fixture.transport, token: token)
            } else if let firstReadiness {
                XCTAssertLessThan(ContinuousClock.now - firstReadiness, .seconds(3.5), "No readiness retry renews the three-second deadline")
            } else { XCTFail("An actual readiness observation must precede deadline failure") }
            try await assertChoiceLedger(view, insertions: 1, sends: enables ? 1 : 0, selections: 0)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
        }
    }

    func testFirstInstantFocusDriftCannotReachLiteralInputOrSend() async throws {
        for drift in ["model", "work", "work_restore", "assistant", "user", "route", "duplicate", "new_model_menu"] {
            let (fixture, view, token, _) = try await readyInstantPrepareFixture()
            defer { fixture.shutdown() }
            _ = try await evaluate(view, """
                const editor = document.getElementById('fixture-editor');
                editor.blur(); window.fixtureFoldedFocusMutations = 0;
                editor.addEventListener('focus', () => {
                  window.fixtureFoldedFocusMutations++;
                  const drift = \(String(reflecting: drift));
                  if (drift === 'model') {
                    window.fixtureChatPowerThumb.setAttribute('aria-valuenow','2'); window.fixtureModelUpdateHeader();
                  } else if (drift === 'work' || drift === 'work_restore') {
                    const group = document.getElementById('fixture-composer-mode'); const hidden = group.hidden;
                    const chat = document.getElementById('fixture-chat-mode'), work = document.getElementById('fixture-work-mode');
                    group.hidden = false; chat.setAttribute('aria-pressed','false'); work.setAttribute('aria-pressed','true');
                    if (drift === 'work_restore') {
                      work.setAttribute('aria-pressed','false'); chat.setAttribute('aria-pressed','true'); group.hidden = hidden;
                    }
                  } else if (drift === 'assistant' || drift === 'user') {
                    const message = document.createElement('article'); message.setAttribute('data-message-author-role',drift);
                    message.textContent = 'Foreign focus message'; document.body.appendChild(message);
                  } else if (drift === 'route') history.pushState({},'', '/c/foreign-focus?temporary-chat=true');
                  else if (drift === 'duplicate') {
                    const duplicate = document.createElement('div'); duplicate.contentEditable = 'true';
                    duplicate.setAttribute('aria-label','Ask ChatGPT'); duplicate.textContent = ''; document.body.appendChild(duplicate);
                  } else if (drift === 'new_model_menu') {
                    const menu = document.createElement('div'); menu.id = 'new-focus-model-menu';
                    menu.setAttribute('role','menu'); menu.setAttribute('aria-labelledby','fixture-model-trigger');
                    const family = document.createElement('div'); family.setAttribute('role','menuitemradio');
                    family.setAttribute('aria-checked','false'); family.textContent = 'GPT-5.5'; menu.appendChild(family);
                    document.body.appendChild(menu); family.setAttribute('aria-checked','true'); menu.remove();
                  }
                }, {once:true});
                return true;
                """)
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "Reject synchronous first-focus \(drift) drift before literal input"])
            let changed = try await evaluate(view, "return window.fixtureFoldedFocusMutations;") as? Int
            XCTAssertEqual(changed, 1, drift)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        }
    }

    // The standalone prepare action remains available to retained paths. These
    // adapter/native-clock tests exercise it directly; first Instant inference
    // now proves its focus inside insert and is covered separately below.
    func testRetainedInstantPrepareAdapterRecoversOneUnacknowledgedOpeningBeforeAnyEditorInput() async throws {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, initiallySelectTarget: true)
            .replacingOccurrences(of: "aria-valuenow=\"1\"", with: "aria-valuenow=\"0\""))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        let selection = try await evaluate(view, """
            return {completed: globalThis.__computaModelSelection?.completed === true,
              clicked: globalThis.__computaModelSelection?.familyClicked === true,
              powerEvents: globalThis.__computaModelSelection?.powerEvents,
              pin: globalThis.__computaChatPresetPin?.invalidated !== true && !!globalThis.__computaChatPresetPin};
            """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
        XCTAssertEqual(selection?["completed"] as? Bool, true)
        XCTAssertEqual(selection?["clicked"] as? Bool, false)
        XCTAssertEqual(selection?["powerEvents"] as? Int, 0)
        XCTAssertEqual(selection?["pin"] as? Bool, true)
        try await armFirstPrepareOpening(view, behavior: "ignore_once")
        do {
            let prepared = try await retainedInstantPrepare(fixture, view: view, token: token)
            XCTAssertEqual(prepared["prepared"] as? Bool, true)
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "Send after fresh checked Instant proof"])
            try assertRunningOrVerifiedChoice(sent, choice: choice)
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnverified)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            XCTFail("A single unacknowledged first-prepare opening must recover checked proof before input")
            return
        }
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        let attempts = try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int
        XCTAssertEqual(attempts, 2)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
        let powerEvents = try await evaluate(view, "return window.fixturePowerKeyEvents;") as? Int
        XCTAssertEqual(powerEvents, 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testRetainedInstantPrepareAdapterLateAcknowledgementDoesNotToggleTheOpenedPicker() async throws {
        let (fixture, view, token, choice) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        try await armFirstPrepareOpening(view, behavior: "late")
        let prepared = try await retainedInstantPrepare(fixture, view: view, token: token)
        XCTAssertEqual(prepared["prepared"] as? Bool, true)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Wait for the delayed actual picker"])
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        let attempts = try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int
        XCTAssertEqual(attempts, 1)
        let physical = try await evaluate(view, "return window.fixturePreparePhysicalClicks;") as? Int
        XCTAssertEqual(physical, 1, "A delayed acknowledged menu must not receive another physical opening")
        let claimed = try await evaluate(view, "return globalThis.__computaChatFirstPrepareOpening?.recoveryClaimed === true;",
            world: .world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(claimed, false)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
    }

    func testRetainedInstantPrepareAdapterPersistentFailureSpendsOneRecoveryAndCannotRenewFromBookkeeping() async throws {
        let (fixture, view, token, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        try await armFirstPrepareOpening(view, behavior: "never")
        let started = ContinuousClock.now
        await assertRetainedInstantPrepareRejected(fixture, view: view, token: token)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(4), "Recovery must retain the original 1.8-second proof budget")
        let first = try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int
        XCTAssertEqual(first, 2)
        let claimed = try await evaluate(view, "return globalThis.__computaChatFirstPrepareOpening?.recoveryClaimed === true;",
            world: .world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(claimed, true)
        _ = try await evaluate(view, "globalThis.__computaModelSelection = {...globalThis.__computaModelSelection}; return true;",
            world: .world(name: "computa-chatgpt-model-v1"))
        await assertRetainedInstantPrepareRejected(fixture, view: view, token: token)
        let repeated = try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int
        XCTAssertEqual(repeated, 3, "Repeated prepare gets its ordinary opening but no additional recovery")
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
    }

    func testRetainedInstantPrepareAdapterSuccessfulObservationCannotGrantALaterRecovery() async throws {
        let (fixture, view, token, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        // Run the same production adapter's focus-only action without handing
        // it editor input. This isolates the monotonic first-observation rule.
        let prepared = try await retainedInstantPrepare(fixture, view: view, token: token)
        XCTAssertNil(prepared["error"]); XCTAssertEqual(prepared["prepared"] as? Bool, true)
        try await armFirstPrepareOpening(view, behavior: "never")
        await assertRetainedInstantPrepareRejected(fixture, view: view, token: token)
        let attempts = try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int
        XCTAssertEqual(attempts, 1)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
    }

    func testRetainedInstantPrepareAdapterContextOrNegativeHistoryCannotAuthorizeASecondOpening() async throws {
        for behavior in ["header_restore", "unassociated", "route", "temporary", "user", "assistant", "owner"] {
            let (fixture, view, token, _) = try await readyInstantPrepareFixture()
            defer { fixture.shutdown() }
            try await armFirstPrepareOpening(view, behavior: behavior)
            await assertRetainedInstantPrepareRejected(fixture, view: view, token: token)
            let attempts = try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int
            XCTAssertEqual(attempts, 1, behavior)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        }
    }

    func testRetainedInstantPrepareAdapterCancellationCannotBecomeAnEarlySecondOpening() async throws {
        let (fixture, view, token, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        try await armFirstPrepareOpening(view, behavior: "never")
        let request = Task { @MainActor in
            _ = try await retainedInstantPrepare(fixture, view: view, token: token)
            return true
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while (try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int) == 0 {
            guard ContinuousClock.now < deadline else { request.cancel(); XCTFail("First opening was not dispatched"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        request.cancel()
        do { _ = try await request.value; XCTFail("A cancelled preparation cannot succeed") } catch {}
        try await Task.sleep(for: .milliseconds(1_000))
        let attempts = try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int
        XCTAssertEqual(attempts, 1)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
    }

    func testRetainedInstantPrepareAdapterTransientRecoveredMenuCannotDispatchAThirdOpening() async throws {
        let (fixture, view, token, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        try await armFirstPrepareOpening(view, behavior: "transient_recovery")
        await assertRetainedInstantPrepareRejected(fixture, view: view, token: token)
        let attempts = try await evaluate(view, "return window.fixturePrepareOpeningAttempts;") as? Int
        XCTAssertEqual(attempts, 2)
        let physical = try await evaluate(view, "return window.fixturePreparePhysicalClicks;") as? Int
        XCTAssertEqual(physical, 2)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
    }

    func testRetainedInstantPrepareAdapterLateClockRejectionCannotAuthorizeRecovery() async throws {
        let (fixture, view, token, _) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        try await armFirstPrepareOpening(view, behavior: "cancel_busy")
        let request = Task { @MainActor in
            _ = try await retainedInstantPrepare(fixture, view: view, token: token)
            return true
        }
        // WebContent briefly blocks after issuing its native clock request.
        // Cancel on MainActor while that reply cannot be delivered, then let
        // rejection arrive after the nominal first-acknowledgement deadline.
        try await Task.sleep(for: .milliseconds(300)); request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled preparation succeeded") } catch {}
        try await Task.sleep(for: .milliseconds(1_600))
        let observed = try await evaluate(view, "return {busy:window.fixturePrepareBusyFinished === true, attempts:window.fixturePrepareOpeningAttempts};") as? [String: Any]
        XCTAssertEqual(observed?["busy"] as? Bool, true)
        XCTAssertEqual(observed?["attempts"] as? Int, 1)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
    }

    func testChatGPTPostFamilyCancellationCannotAuthorizeAnOpeningRecovery() async throws {
        let fixture = try Fixture(page: Self.familyClosingTransitionPage())
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        let preparation = Task { @MainActor in
            _ = try await waitForState("ready", fixture.transport, token: token)
            return true
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while (try await evaluate(view, "return window.fixtureFirstPostFamilyOpenAttempts || 0;") as? Int) == 0 {
            guard ContinuousClock.now < deadline else { preparation.cancel(); XCTFail("Post-family opening was not observed"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preparation.cancel()
        do { _ = try await preparation.value; XCTFail("Cancelled preparation succeeded") } catch {}
        try await Task.sleep(for: .milliseconds(1_000))
        let attempts = try await evaluate(view, "return window.fixtureFirstPostFamilyOpenAttempts;") as? Int
        XCTAssertEqual(attempts, 1, "A rejected native clock is not an opening timeout")
        let recovered = try await evaluate(view, "return globalThis.__computaModelSelection?.openingRecoveryAttempted === true;",
            world: .world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(recovered, false)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
    }

    func testRepeatedChatGPTFinishAndCancelPreserveTheExactVerifiedReceipt() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Receipt preservation fixture"])
        let completed = try await waitForState("complete", fixture.transport, token: token)
        let params = try JSONSerialization.data(withJSONObject: ["sessionToken": token])
        let finish = Task { @MainActor in
            try await fixture.transport.request(operation: "webProviderFinish", params: params)
        }
        await Task.yield()
        let cancellation = try await fixture.transport.request(operation: "webProviderCancel", params: params)
        let original = try await finish.value
        let repeated = try await fixture.transport.request(operation: "webProviderFinish", params: params)
        XCTAssertEqual(cancellation, original)
        XCTAssertEqual(repeated, original)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(receipt["cleanup"] as? String, "not_created")
        XCTAssertEqual(receipt["text"] as? String, completed["text"] as? String)
        XCTAssertNotNil(receipt["modelEvidence"])
        XCTAssertNotNil(receipt["modelProofContext"])
        XCTAssertNil(fixture.browser.webView(for: ownedID))
        XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
    }

    func testResponseNoticeProjectionAcceptsOnlyFinitePairedStatusFacts() throws {
        let observation: [String: Any] = ["excludedAncestor": "dialog", "contentExcluded": false,
            "retryEnabled": true, "noticeRole": "status", "pairing": "shared_parent", "sameWidget": true,
            "knownError": "load_failed", "labelStructure": "nested", "labelScanTruncated": false]
        let valid: [String: Any] = ["kind": "chatgpt_response_notice_v1", "retryCount": 1,
            "observationsTruncated": false, "observations": [observation]]
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedResponseNoticeDiagnostic(valid))
        let projected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        XCTAssertEqual(projected["kind"] as? String, "chatgpt_response_notice_v1")
        XCTAssertFalse(safe.contains("https")); XCTAssertFalse(safe.contains("PRIVATE"))
        var extras = valid; extras["noticeText"] = "PRIVATE_NOTICE_CANARY"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedResponseNoticeDiagnostic(extras))
        var privateObservation = observation; privateObservation["url"] = "https://PRIVATE_URL_CANARY"
        var privatePayload = valid; privatePayload["observations"] = [privateObservation]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedResponseNoticeDiagnostic(privatePayload))
        for (key, value): (String, Any) in [("excludedAncestor", "PRIVATE_ANCESTOR"), ("excludedAncestor", "menu"),
            ("excludedAncestor", "nav"), ("excludedAncestor", "aside"), ("noticeRole", "dialog"),
            ("pairing", "PRIVATE_RELATION"), ("sameWidget", false), ("knownError", "PRIVATE_ERROR"),
            ("labelStructure", "PRIVATE_MARKUP"), ("contentExcluded", true), ("retryEnabled", 1),
            ("labelScanTruncated", true)] {
            var badObservation = observation; badObservation[key] = value
            var bad = valid; bad["observations"] = [badObservation]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResponseNoticeDiagnostic(bad), key)
        }
    }

    func testResponseNoticeCountsAndTruncationCannotImplyMissingObservations() throws {
        let absent: [String: Any] = ["excludedAncestor": "none", "contentExcluded": false,
            "retryEnabled": true, "noticeRole": "none", "pairing": "none", "sameWidget": false,
            "knownError": "none", "labelStructure": "none", "labelScanTruncated": false]
        for count in [0, 1, 2, 3, 10_000] {
            let payload: [String: Any] = ["kind": "chatgpt_response_notice_v1", "retryCount": count,
                "observationsTruncated": count > 2, "observations": Array(repeating: absent, count: min(count, 2))]
            XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedResponseNoticeDiagnostic(payload))
        }
        for badCount: Any in [true, -1, 10_001, 1.5, Double.infinity, "PRIVATE_COUNT"] {
            let bad: [String: Any] = ["kind": "chatgpt_response_notice_v1", "retryCount": badCount,
                "observationsTruncated": false, "observations": []]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResponseNoticeDiagnostic(bad))
        }
        let missing: [String: Any] = ["kind": "chatgpt_response_notice_v1", "retryCount": 1,
            "observationsTruncated": false, "observations": []]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedResponseNoticeDiagnostic(missing))
    }

    func testResponseNoticeDoesNotAlterExistingProgressOrResponseErrorEvidence() throws {
        let input: [String: Any] = ["responseCount": 0, "userCount": 1, "busy": false,
            "answerComplete": false, "responseLoadFailed": false, "text": "",
            "responseNoticeDiagnostic": ["PRIVATE_ARBITRARY_FIELD": "PRIVATE_CONTENT"]]
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedResponseProgressInspection(input))
        XCTAssertEqual(safe["responseLoadFailed"] as? Bool, false)
        XCTAssertNil(safe["responseNoticeDiagnostic"])
        XCTAssertFalse(String(describing: safe).contains("PRIVATE"))
    }

    func testNativeInspectorHandoffRequiresReadyChatGPTAndFinishRevokesExactView() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt)); defer { fixture.shutdown() }
        let arm = try InspectorArmFixture(); defer { arm.remove() }; try arm.arm()
        let authorization = try XCTUnwrap(arm.consume())
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let id = try XCTUnwrap(fixture.createdTabs.last), view = try XCTUnwrap(fixture.browser.webView(for: id))
        let early = await fixture.transport.grantInspectorDiagnostic(authorization, sessionToken: token)
        XCTAssertFalse(early); XCTAssertFalse(view.isInspectable)
        _ = try await waitForState("ready", fixture.transport, token: token)
        do {
            _ = try await call(fixture.transport, "webProviderGrantInspector", ["sessionToken": token])
            XCTFail("No wire operation can grant inspection")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .staleSession) }
        XCTAssertFalse(view.isInspectable, "An unknown wire operation cannot grant inspection")
        let granted = await fixture.transport.grantInspectorDiagnostic(authorization, sessionToken: token)
        XCTAssertTrue(granted); XCTAssertTrue(view.isInspectable)
        XCTAssertFalse(fixture.browser.canInspect(tabID: id))
        XCTAssertFalse(fixture.humanView.isInspectable)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertFalse(view.isInspectable)
    }

    func testNativeInspectorHandoffRejectsOtherProviderAndChangedGeneration() async throws {
        for provider in [EmbeddedWebModelTransport.Provider.gemini, .chatgpt] {
            let fixture = try Fixture(page: Self.modelChoicePage(provider)); defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(provider), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let id = try XCTUnwrap(fixture.createdTabs.last), view = try XCTUnwrap(fixture.browser.webView(for: id))
            if provider == .chatgpt { fixture.browser.stop(tabID: id) }
            let arm = try InspectorArmFixture(); defer { arm.remove() }; try arm.arm()
            let authorization = try XCTUnwrap(arm.consume())
            let granted = await fixture.transport.grantInspectorDiagnostic(authorization, sessionToken: token)
            XCTAssertFalse(granted); XCTAssertFalse(view.isInspectable)
        }
    }

    func testResponseProgressProjectionPreservesUnknownsAndOmitsPrivateContent() throws {
        let privateText = "PRIVATE_RESPONSE_CANARY😀é"
        let input: [String: Any] = ["responseCount": 1, "userCount": 2, "busy": true,
            "answerComplete": false, "text": privateText, "url": "https://private.invalid/?secret=CANARY",
            "prompt": "PRIVATE_PROMPT", "error": "PRIVATE_ERROR", "ownerToken": "PRIVATE_OWNER"]
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedResponseProgressInspection(input))
        XCTAssertEqual(Set(safe.keys), ["responseCount", "userCount", "busy", "answerComplete",
            "responseLoadFailed", "textBytes", "textBytesLimitExceeded"])
        XCTAssertEqual(safe["textBytes"] as? Int, privateText.utf8.count)
        XCTAssertEqual(safe["textBytesLimitExceeded"] as? Bool, false)
        XCTAssertTrue(safe["responseLoadFailed"] is NSNull, "An absent flag remains unknown")
        let encoded = try JSONSerialization.data(withJSONObject: safe, options: .sortedKeys)
        let text = String(decoding: encoded, as: UTF8.self)
        for secret in ["PRIVATE", "https", "CANARY", "😀", "é", "ownerToken", "prompt", "error", "url"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertLessThan(encoded.count, 256)
        let unknown = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedResponseProgressInspection(["responseCount": 0, "userCount": 0]))
        for key in ["busy", "answerComplete", "responseLoadFailed", "textBytes", "textBytesLimitExceeded"] {
            XCTAssertTrue(unknown[key] is NSNull, key)
        }
        for (key, value): (String, Any) in [("responseCount", true), ("userCount", 0.5),
            ("responseCount", -1), ("userCount", 10_001), ("busy", 1), ("answerComplete", "false"),
            ("responseLoadFailed", NSNull()), ("text", 123)] {
            var bad = input; bad[key] = value
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResponseProgressInspection(bad), key)
        }
        for key in ["responseCount", "userCount"] {
            var missing = input; missing.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResponseProgressInspection(missing), key)
        }
        var large = input; large["text"] = String(repeating: "A", count: 220_002)
        let bounded = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedResponseProgressInspection(large))
        XCTAssertEqual(bounded["textBytes"] as? Int, 220_001)
        XCTAssertEqual(bounded["textBytesLimitExceeded"] as? Bool, true)
    }

    func testResponseProgressFailureUsesOnlyCurrentRoundInspectionAndEmitsOnce() async throws {
        for inspectSecondRound in [false, true] {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, holdSecondReply: true))
            defer { fixture.shutdown() }
            var diagnostics: [String] = []
            fixture.transport.setResponseProgressDiagnosticObserverForTesting { diagnostics.append($0) }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "PRIVATE_FIRST_PROGRESS"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertTrue(diagnostics.isEmpty, "A completed first round produces no failure record")
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "PRIVATE_SECOND_PROGRESS"])
            if inspectSecondRound {
                let pending = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(pending["state"] as? String, "running")
            }
            fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1))
            try await Task.sleep(for: .milliseconds(2))
            for _ in 0..<2 {
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("Progress diagnostics cannot admit the expired response")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
            }
            XCTAssertEqual(diagnostics.count, 1)
            let safe = try XCTUnwrap(diagnostics.first)
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
            XCTAssertEqual(record["kind"] as? String, "chatgpt_response_progress_v1")
            XCTAssertEqual(record["phase"] as? String, "failure")
            XCTAssertEqual(record["cause"] as? String, "response_deadline")
            XCTAssertEqual(record["sequence"] as? Int, 2)
            XCTAssertEqual(record["ownedViewCurrent"] as? Bool, true)
            XCTAssertEqual(record["ownedDocumentCurrent"] as? Bool, true)
            XCTAssertEqual(record["modelSelectionVerified"] as? Bool, true)
            XCTAssertEqual(record["modelEvidencePresent"] as? Bool, true)
            XCTAssertEqual(record["lastInspectionAvailable"] as? Bool, inspectSecondRound)
            if inspectSecondRound {
                let observed = try XCTUnwrap(record["lastInspection"] as? [String: Any])
                XCTAssertEqual(observed["userCount"] as? Int, 2)
                XCTAssertEqual(observed["responseCount"] as? Int, 2)
                // This fixture appends an enabled Copy control before adding
                // Stop. Preserve both observed flags: busy still forbids native
                // completion even when a completion control is present.
                let controls = try await evaluate(view, """
                    const lastTurn = document.getElementById('messages').lastElementChild;
                    return { stop: !!document.getElementById('fixture-held-response-stop'),
                      copy: !!lastTurn.querySelector('button[aria-label="Copy"]') };
                    """) as? [String: Bool]
                XCTAssertEqual(controls?["stop"], true)
                XCTAssertEqual(controls?["copy"], true)
                XCTAssertEqual(observed["busy"] as? Bool, true)
                XCTAssertEqual(observed["answerComplete"] as? Bool, true)
                XCTAssertEqual(record["confirmedUsers"] as? Int, 2)
                XCTAssertEqual(record["pendingSubmission"] as? Bool, false)
                XCTAssertEqual(record["currentSubmissionVerified"] as? Bool, true)
            } else {
                XCTAssertTrue(record["lastInspection"] is NSNull, "First-round cached facts must not survive a new Send claim")
            }
            XCTAssertLessThanOrEqual(safe.utf8.count, 768)
            for secret in ["PRIVATE", token, "https", "Fixture reply", "Computa session marker"] { XCTAssertFalse(safe.contains(secret)) }
            try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(diagnostics.count, 1, "Finish cannot emit another progress record for the failed round")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testResponseProgressFailureOmitsCachedInspectionAfterOwnedViewRemoval() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "PRIVATE_STALE_PROGRESS")
        defer { fixture.shutdown() }
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        var diagnostics: [String] = []
        fixture.transport.setResponseProgressDiagnosticObserverForTesting { diagnostics.append($0) }
        fixture.browser.closeTab(try XCTUnwrap(fixture.createdTabs.last))
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A diagnostic must not restore a removed owned view")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .staleSession) }
        XCTAssertEqual(diagnostics.count, 1)
        let safe = try XCTUnwrap(diagnostics.first)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        XCTAssertEqual(record["ownedViewCurrent"] as? Bool, false)
        XCTAssertEqual(record["ownedDocumentCurrent"] as? Bool, false)
        XCTAssertEqual(record["lastInspectionAvailable"] as? Bool, false)
        XCTAssertTrue(record["lastInspection"] is NSNull)
        XCTAssertFalse(safe.contains("PRIVATE")); XCTAssertFalse(safe.contains(token))
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertEqual(diagnostics.count, 1)
        try await assertHumanTabIntact(fixture)
    }

    func testFailedPageDiagnosticProjectionAdmitsOnlyBoundedFiniteValues() throws {
        let root: [String: Any] = ["connected": 1, "visible": 1]
        let valid: [String: Any] = ["kind": "chatgpt_failed_page_v1", "route": "local_conversation", "errorCategory": "none",
            "modernUsers": root, "legacyUsers": root, "modernAssistants": root, "legacyAssistants": root,
            "stopPresent": false, "composerPresent": true, "composerEnabled": true, "copyPresent": false, "copyEnabled": false,
            "retryPresent": false, "retryInsideUserMessage": false, "retryInsideAssistantMessage": false,
            "retryInsideCodeOrEditor": false, "retryInsideMenuOrNavigation": false, "retryOutsideExcludedContent": false,
            "temporaryRendered": true, "temporaryVerified": true, "alertCount": 0, "statusCount": 1,
            "alertTextLengths": [], "statusTextLengths": [37], "noticesTruncated": false]
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(valid))
        var withPrivateExtras = valid; withPrivateExtras["body"] = "PRIVATE_PAGE_CANARY"
        withPrivateExtras["url"] = "https://private.example/?token=PRIVATE_URL_CANARY"
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(withPrivateExtras))
        XCTAssertFalse(safe.contains("PRIVATE_")); XCTAssertFalse(safe.contains("https"))
        for (key, value): (String, Any) in [("route", "PRIVATE_ROUTE"), ("errorCategory", "PRIVATE_ERROR"),
            ("stopPresent", 0), ("alertCount", true), ("statusCount", 0.5), ("noticesTruncated", true),
            ("statusTextLengths", [true]), ("statusTextLengths", [220_002]), ("statusTextLengths", []),
            ("retryInsideUserMessage", true), ("retryPresent", 1)] {
            var bad = valid; bad[key] = value
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(bad), key)
        }
        for roots: [String: Any] in [["connected": true, "visible": 0], ["connected": 0, "visible": 1],
                                     ["connected": 10_001, "visible": 0], ["connected": 1.5, "visible": 1]] {
            var bad = valid; bad["modernUsers"] = roots
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(bad))
        }
        for (presence, enabled) in [("composerPresent", "composerEnabled"), ("copyPresent", "copyEnabled"),
                                    ("temporaryRendered", "temporaryVerified")] {
            var bad = valid; bad[presence] = false; bad[enabled] = true
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(bad))
        }
    }

    func testResponseDeadlineGetsOneReadOnlyFinitePageDiagnosticWithoutResending() async throws {
        let prompt = "PRIVATE_DEADLINE_PROMPT😀é"
        let (fixture, token, view) = try await boundInspectionFixture(prompt: prompt, bindFirstRead: false)
        defer { fixture.shutdown() }
        var diagnostics: [String] = []
        var resourceDiagnostics: [String] = []
        fixture.transport.setFailedPageDiagnosticObserverForTesting { diagnostics.append($0) }
        fixture.transport.setResourceTimingDiagnosticObserverForTesting { resourceDiagnostics.append($0) }
        // The first healthy read starts its completion candidate now, rather
        // than depending on how long previous fixture setup was scheduled.
        _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(diagnostics, [])
        _ = try await evaluate(view, """
            const main = document.createElement('main'), region = document.createElement('div');
            const error = document.createElement('span'); error.textContent = 'Load failed';
            const retry = document.createElement('button'); retry.textContent = 'Retry';
            window.fixtureRetryClicks = 0; retry.addEventListener('click', () => window.fixtureRetryClicks++);
            const status = document.createElement('div'); status.setAttribute('role', 'status');
            status.textContent = 'PRIVATE_NOTICE_CANARY'; region.append(error, retry); main.append(region, status);
            document.body.append(main); return true;
            """)
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1))
        let began = ContinuousClock.now
        for _ in 0..<2 {
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("The diagnostic must not admit a late response")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
        }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(1))
        XCTAssertEqual(diagnostics, [], "The abort diagnostic cannot delay the original deadline error")
        let retryClicks = try await evaluate(view, "return window.fixtureRetryClicks;")
        XCTAssertEqual(retryClicks as? Int, 0)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertEqual(diagnostics.count, 1)
        let safe = try XCTUnwrap(diagnostics.first)
        let observation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        XCTAssertEqual(observation["errorCategory"] as? String, "load_failed")
        XCTAssertEqual(observation["statusCount"] as? Int, 1)
        let outboundShape = "\(prompt)\n\nComputa session marker: \(String(repeating: "0", count: 36))"
        XCTAssertEqual(observation["outboundUTF16Count"] as? Int, outboundShape.utf16.count)
        XCTAssertEqual(observation["outboundUTF8Count"] as? Int, outboundShape.utf8.count)
        XCTAssertEqual(resourceDiagnostics.count, 1)
        let resource = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(resourceDiagnostics.first).utf8)) as? [String: Any])
        XCTAssertEqual(resource["phase"] as? String, "failure"); XCTAssertEqual(resource["sequence"] as? Int, 1)
        XCTAssertEqual(resource["absenceInconclusive"] as? Bool, true)
        XCTAssertFalse(safe.contains("PRIVATE_")); XCTAssertFalse(safe.contains(token)); XCTAssertFalse(safe.contains("chatgpt.com"))
        try await assertHumanTabIntact(fixture)
    }

    func testFailedPageOutboundSizeProjectionKeepsPairedUnicodeCountsWithoutPrivateValues() throws {
        let empty: [String: Any] = ["connected": 0, "visible": 0]
        let base: [String: Any] = ["kind": "chatgpt_failed_page_v1", "route": "root", "errorCategory": "none",
            "modernUsers": empty, "legacyUsers": empty, "modernAssistants": empty, "legacyAssistants": empty,
            "stopPresent": false, "composerPresent": true, "composerEnabled": true, "copyPresent": false, "copyEnabled": false,
            "retryPresent": false, "retryInsideUserMessage": false, "retryInsideAssistantMessage": false,
            "retryInsideCodeOrEditor": false, "retryInsideMenuOrNavigation": false, "retryOutsideExcludedContent": false,
            "temporaryRendered": true, "temporaryVerified": true, "alertCount": 0, "statusCount": 0,
            "alertTextLengths": [], "statusTextLengths": [], "noticesTruncated": false]
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(base), "Historical records retain their old schema")
        for text in ["PRIVATE_ASCII_CANARY", "A😀é", String(repeating: "é", count: 100_000)] {
            var measured = base
            measured["outboundUTF16Count"] = text.utf16.count; measured["outboundUTF8Count"] = text.utf8.count
            measured["prompt"] = text; measured["nonce"] = "PRIVATE_NONCE"; measured["url"] = "PRIVATE_URL"
            let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(measured))
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
            XCTAssertEqual(fields["outboundUTF16Count"] as? Int, text.utf16.count)
            XCTAssertEqual(fields["outboundUTF8Count"] as? Int, text.utf8.count)
            XCTAssertLessThanOrEqual(safe.utf8.count, 2_048)
            for secret in ["PRIVATE", "😀", "é", "prompt", "nonce", "url"] { XCTAssertFalse(safe.contains(secret)) }
        }
        var absent = base; absent["outboundUTF16Count"] = NSNull(); absent["outboundUTF8Count"] = NSNull()
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(absent))
        let nulls = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        XCTAssertTrue(nulls["outboundUTF16Count"] is NSNull); XCTAssertTrue(nulls["outboundUTF8Count"] is NSNull)
        for (utf16, utf8): (Any, Any) in [(true, 1), (1, false), (-1, 0), (1, -1), (180_201, 180_201),
                                        (180_200, 720_801), (2, 1), (1, 4), (1.5, 2), (1, "1"),
                                        (NSNull(), 1), (1, NSNull())] {
            var invalid = base; invalid["outboundUTF16Count"] = utf16; invalid["outboundUTF8Count"] = utf8
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(invalid))
        }
        for key in ["outboundUTF16Count", "outboundUTF8Count"] {
            var invalid = base; invalid[key] = 1
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFailedPageDiagnostic(invalid), "The pair is atomic")
        }
    }

    func testResourceTimingProjectionRequiresExactPhaseSequenceAndFiniteResponseMetadata() throws {
        let sample: [String: Any] = ["endpoint": "conversation", "initiator": "fetch", "startOffsetMs": 1, "durationMs": 50,
            "transferBytes": 130, "encodedBodyBytes": 100, "decodedBodyBytes": 150, "responseStatusAvailable": true, "responseStatus": 200]
        let valid: [String: Any] = ["kind": "chatgpt_resource_timing_v1", "phase": "completion", "sequence": 1,
            "available": true, "sendMarkAvailable": true, "scanTruncated": false, "scannedCount": 1,
            "conversationCount": 1, "preparationCount": 0, "observations": [sample],
            "observationsTruncated": false, "absenceInconclusive": true]
        let safe = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(valid, phase: "completion", sequence: 1))
        XCTAssertLessThanOrEqual(safe.utf8.count, 2_048)
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(valid, phase: "failure", sequence: 1))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(valid, phase: "completion", sequence: 2))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(missing, phase: "completion", sequence: 1), key)
        }
        for key in ["name", "url", "headers", "prompt", "owner"] {
            var extra = valid; extra[key] = "PRIVATE_CANARY"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(extra, phase: "completion", sequence: 1))
            var nested = sample; nested[key] = "PRIVATE_CANARY"; extra = valid; extra["observations"] = [nested]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(extra, phase: "completion", sequence: 1))
        }
        for (key, bad): (String, Any) in [("sequence", true), ("scannedCount", 257), ("conversationCount", true),
                                        ("preparationCount", 2), ("available", false), ("sendMarkAvailable", false),
                                        ("scanTruncated", true), ("observationsTruncated", true), ("absenceInconclusive", false)] {
            var invalid = valid; invalid[key] = bad
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(invalid, phase: "completion", sequence: 1), key)
        }
        for (key, bad): (String, Any) in [("endpoint", "PRIVATE_URL"), ("initiator", "PRIVATE_HEADER"),
                                        ("durationMs", true), ("startOffsetMs", -1), ("durationMs", 3_600_001),
                                        ("transferBytes", 2_147_483_648), ("encodedBodyBytes", 1.5),
                                        ("responseStatusAvailable", 1), ("responseStatus", true), ("responseStatus", 600)] {
            var nested = sample; nested[key] = bad; var invalid = valid; invalid["observations"] = [nested]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(invalid, phase: "completion", sequence: 1), key)
        }
        for status: Any in [0, NSNull()] {
            var nested = sample; nested["responseStatusAvailable"] = !(status is NSNull); nested["responseStatus"] = status
            var observation = valid; observation["observations"] = [nested]
            XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(observation, phase: "completion", sequence: 1))
        }
        var absent = valid
        for key in ["scannedCount", "conversationCount", "preparationCount"] { absent[key] = 0 }
        absent["observations"] = [[String: Any]]()
        for available in [true, false] {
            absent["available"] = available; absent["sendMarkAvailable"] = available
            XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(absent, phase: "completion", sequence: 1))
        }
        var capped = valid; capped["sequence"] = 10_000; capped["scannedCount"] = 256; capped["scanTruncated"] = true
        capped["conversationCount"] = 256; capped["observationsTruncated"] = true
        var maximum = sample
        for key in ["startOffsetMs", "durationMs"] { maximum[key] = 3_600_000 }
        for key in ["transferBytes", "encodedBodyBytes", "decodedBodyBytes"] { maximum[key] = 2_147_483_647 }
        capped["observations"] = Array(repeating: maximum, count: 4)
        let bounded = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(capped, phase: "completion", sequence: 10_000))
        XCTAssertLessThanOrEqual(bounded.utf8.count, 2_048)
        for offset in stride(from: 0, to: bounded.utf8.count, by: 512) {
            let data = Data(bounded.utf8).subdata(in: offset..<min(offset + 512, bounded.utf8.count))
            let line = "resourceTimingDiagnostic provider=chatgpt sequence=10000 phase=completion id=\(UUID().uuidString) part=4/4 base64=\(data.base64EncodedString())"
            XCTAssertLessThanOrEqual(line.utf8.count, 960)
        }
    }

    func testResourceTimingV2RequiresExactNullableOrderedOffsetsAndPreservesV1() throws {
        let timingKeys = ["requestStartOffsetMs", "responseStartOffsetMs", "responseEndOffsetMs"]
        let legacy: [String: Any] = ["endpoint": "conversation", "initiator": "fetch", "startOffsetMs": 1, "durationMs": 50,
            "transferBytes": 130, "encodedBodyBytes": 100, "decodedBodyBytes": 150, "responseStatusAvailable": false, "responseStatus": NSNull()]
        var sample = legacy
        for (key, value) in zip(timingKeys, [10, 29, 51]) { sample[key] = value }
        func observation(_ sample: [String: Any], kind: String = "chatgpt_resource_timing_v2") -> [String: Any] {
            ["kind": kind, "phase": "completion", "sequence": 1, "available": true, "sendMarkAvailable": true,
             "scanTruncated": false, "scannedCount": 1, "conversationCount": 1, "preparationCount": 0,
             "observations": [sample], "observationsTruncated": false, "absenceInconclusive": true]
        }
        func parsed(_ value: [String: Any]) -> String? {
            EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(value, phase: "completion", sequence: 1)
        }
        let safe = try XCTUnwrap(parsed(observation(sample)))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["kind"] as? String, "chatgpt_resource_timing_v2")
        let rows = try XCTUnwrap(decoded["observations"] as? [[String: Any]])
        for (key, value) in zip(timingKeys, [10, 29, 51]) { XCTAssertEqual(rows[0][key] as? Int, value) }
        let legacySafe = try XCTUnwrap(parsed(observation(legacy, kind: "chatgpt_resource_timing_v1")))
        XCTAssertFalse(legacySafe.contains("requestStartOffsetMs")); XCTAssertTrue(legacySafe.contains("chatgpt_resource_timing_v1"))
        XCTAssertNil(parsed(observation(sample, kind: "chatgpt_resource_timing_v1")))
        XCTAssertNil(parsed(observation(sample, kind: "chatgpt_resource_timing_v3")))
        for key in timingKeys {
            var missing = sample; missing.removeValue(forKey: key)
            XCTAssertNil(parsed(observation(missing)), key)
            for bad: Any in [true, "10", -1, 1.5, Double.nan, Double.infinity, 3_600_001] {
                var invalid = sample; invalid[key] = bad
                XCTAssertNil(parsed(observation(invalid)), key)
            }
        }
        for changes: [String: Any] in [["requestStartOffsetMs": 0], ["responseStartOffsetMs": 9], ["responseEndOffsetMs": 28],
                                      ["requestStartOffsetMs": NSNull(), "responseStartOffsetMs": 52],
                                      ["responseStartOffsetMs": NSNull(), "responseEndOffsetMs": 9]] {
            XCTAssertNil(parsed(observation(sample.merging(changes) { _, new in new })))
        }
        for nullable in [timingKeys, ["requestStartOffsetMs"], ["responseStartOffsetMs"], ["responseEndOffsetMs"]] {
            var unknown = sample
            for key in nullable { unknown[key] = NSNull() }
            XCTAssertNotNil(parsed(observation(unknown)))
        }
        for key in ["url", "headers", "cookies", "prompt", "owner"] {
            var extra = observation(sample); extra[key] = "PRIVATE_CANARY"
            XCTAssertNil(parsed(extra))
            var nested = sample; nested[key] = "PRIVATE_CANARY"
            XCTAssertNil(parsed(observation(nested)))
        }
        var maximum = sample
        for key in ["startOffsetMs", "durationMs"] + timingKeys { maximum[key] = 3_600_000 }
        for key in ["transferBytes", "encodedBodyBytes", "decodedBodyBytes"] { maximum[key] = 2_147_483_647 }
        var capped = observation(maximum); capped["scannedCount"] = 256; capped["conversationCount"] = 256
        capped["scanTruncated"] = true; capped["observationsTruncated"] = true; capped["observations"] = Array(repeating: maximum, count: 4)
        XCTAssertLessThanOrEqual(try XCTUnwrap(parsed(capped)).utf8.count, 2_048)
    }

    func testResourceTimingV3OnlyProjectsBoundedPublicScriptHTTPFailuresInFailurePhase() throws {
        let failure: [String: Any] = ["asset": "633146.1f9c264032.js", "responseStatus": 404,
                                      "startOffsetMs": 1, "durationMs": 50]
        let scripts: [String: Any] = ["count": 3, "unknownStatusCount": 1, "httpFailureCount": 1,
                                      "failuresTruncated": false, "failures": [failure]]
        let valid: [String: Any] = ["kind": "chatgpt_resource_timing_v3", "phase": "failure", "sequence": 1,
            "available": true, "sendMarkAvailable": true, "scanTruncated": false, "scannedCount": 3,
            "conversationCount": 0, "preparationCount": 0, "observations": [[String: Any]](),
            "observationsTruncated": false, "absenceInconclusive": true, "scriptResources": scripts]
        func parsed(_ value: [String: Any], phase: String = "failure") -> String? {
            EmbeddedWebModelTransport.sanitizedResourceTimingDiagnostic(value, phase: phase, sequence: 1)
        }
        XCTAssertNotNil(parsed(valid))
        for phase in ["send", "completion"] {
            var invalid = valid; invalid["phase"] = phase
            XCTAssertNil(parsed(invalid, phase: phase))
        }
        for key in scripts.keys {
            var nested = scripts; nested.removeValue(forKey: key)
            var invalid = valid; invalid["scriptResources"] = nested
            XCTAssertNil(parsed(invalid), key)
        }
        for (key, bad): (String, Any) in [("count", true), ("count", 257), ("count", 4),
            ("unknownStatusCount", -1), ("unknownStatusCount", 3), ("httpFailureCount", 0),
            ("httpFailureCount", 2), ("failuresTruncated", true), ("failures", [failure, failure, failure]),
            ("url", "PRIVATE_CANARY")] {
            var nested = scripts; nested[key] = bad; var invalid = valid; invalid["scriptResources"] = nested
            XCTAssertNil(parsed(invalid), key)
        }
        for (key, bad): (String, Any) in [("asset", "https://chatgpt.com/cdn/assets/633146.1f9c264032.js"),
            ("asset", "633146.1F9C264032.js"), ("asset", "633146.1f9c264032.js?PRIVATE"),
            ("asset", "633146.1f9c264032.js\n"), ("asset", "633146.1f9c264032.js#PRIVATE"),
            ("asset", "1633146.1f9c264032.js"), ("asset", "633146.1f9c2640320.js"), ("asset", "PRIVATE.js"),
            ("responseStatus", 0), ("responseStatus", 200), ("responseStatus", 399), ("responseStatus", 600),
            ("responseStatus", true), ("responseStatus", NSNull()), ("startOffsetMs", -1),
            ("durationMs", 3_600_001), ("durationMs", 0.5), ("durationMs", true), ("url", "PRIVATE_CANARY")] {
            var row = failure; row[key] = bad; var nested = scripts; nested["failures"] = [row]
            var invalid = valid; invalid["scriptResources"] = nested
            XCTAssertNil(parsed(invalid), key)
        }
        for key in failure.keys {
            var row = failure; row.removeValue(forKey: key); var nested = scripts; nested["failures"] = [row]
            var invalid = valid; invalid["scriptResources"] = nested
            XCTAssertNil(parsed(invalid), key)
        }
        var absent = valid
        absent["scannedCount"] = 0
        absent["scriptResources"] = ["count": 0, "unknownStatusCount": 0, "httpFailureCount": 0,
            "failuresTruncated": false, "failures": [[String: Any]]()]
        absent["available"] = false; absent["sendMarkAvailable"] = false
        XCTAssertNotNil(parsed(absent))
        var invalid = absent; invalid["scriptResources"] = scripts
        XCTAssertNil(parsed(invalid))
        let maximum: [String: Any] = ["endpoint": "conversation", "initiator": "xmlhttprequest", "startOffsetMs": 3_600_000,
            "durationMs": 3_600_000, "requestStartOffsetMs": 3_600_000, "responseStartOffsetMs": 3_600_000,
            "responseEndOffsetMs": 3_600_000, "transferBytes": 2_147_483_647, "encodedBodyBytes": 2_147_483_647,
            "decodedBodyBytes": 2_147_483_647, "responseStatusAvailable": true, "responseStatus": 599]
        let maximumFailure: [String: Any] = ["asset": "999999.abcdef0123.js", "responseStatus": 599,
                                             "startOffsetMs": 3_600_000, "durationMs": 3_600_000]
        var capped = valid; capped["scannedCount"] = 256; capped["scanTruncated"] = true
        capped["conversationCount"] = 128; capped["observationsTruncated"] = true
        capped["observations"] = Array(repeating: maximum, count: 4)
        capped["scriptResources"] = ["count": 128, "unknownStatusCount": 0, "httpFailureCount": 128,
            "failuresTruncated": true, "failures": Array(repeating: maximumFailure, count: 2)]
        let safe = try XCTUnwrap(parsed(capped))
        XCTAssertLessThanOrEqual(safe.utf8.count, 2_048)
        for privateValue in ["PRIVATE", "https:", "/cdn", "url", "headers"] { XCTAssertFalse(safe.contains(privateValue)) }
    }

    func testResourceTimingPublishesOwnedSendAndStableCompletionWithoutExtraInput() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt)); defer { fixture.shutdown() }
        var diagnostics: [String] = []
        fixture.transport.setResourceTimingDiagnosticObserverForTesting { diagnostics.append($0) }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertEqual(diagnostics, [])
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "PRIVATE_RESOURCE_CANARY"])
        _ = try await waitForState("complete", fixture.transport, token: token)
        let records = try diagnostics.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(records.compactMap { $0["phase"] as? String }, ["send", "completion"])
        for record in records {
            XCTAssertEqual(record["kind"] as? String, "chatgpt_resource_timing_v2")
            XCTAssertEqual(record["sequence"] as? Int, 1); XCTAssertEqual(record["absenceInconclusive"] as? Bool, true)
            XCTAssertEqual(record["available"] as? Bool, true); XCTAssertEqual(record["sendMarkAvailable"] as? Bool, true)
        }
        for diagnostic in diagnostics { XCTAssertFalse(diagnostic.contains("PRIVATE")); XCTAssertFalse(diagnostic.contains(token)); XCTAssertFalse(diagnostic.contains("https:")) }
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created"); XCTAssertEqual(diagnostics.count, 2)
        try await assertHumanTabIntact(fixture)
    }

    func testInlineRendererFailureRetainsSameInspectionDiagnosticsWithoutAnotherReadOrSend() async throws {
        for retainCopy in [false, true] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "PRIVATE_RENDERER_FAILURE_PROMPT")
            defer { fixture.shutdown() }
            var timings: [String] = [], renderers: [String] = [], evaluations: [String] = []
            fixture.transport.setResourceTimingDiagnosticObserverForTesting { timings.append($0) }
            fixture.transport.setRendererGuardDiagnosticObserverForTesting { renderers.append($0) }
            _ = try await evaluate(view, """
                const main = document.createElement('main'), messages = document.getElementById('messages');
                document.body.append(main); main.append(messages);
                const answer = messages.querySelector('[data-markdown-text-style="assistant-message"]');
                const portal = document.createElement('div'); portal.className = 'PortalBoundary-Fixture Renderer-Fixture';
                const renderer = document.createElement('div'); renderer.className = 'DilRenderer-Fixture DilResponseRoot-Fixture';
                const leaf = document.createElement('div'); leaf.textContent = 'This response couldn’t load';
                renderer.append(leaf); portal.append(renderer); answer.replaceChildren(portal);
                if (!\(retainCopy ? "true" : "false")) messages.querySelectorAll('button').forEach(button => button.remove());
                return true;
                """)
            fixture.transport.setBeforePageResultValidationForTesting { evaluations.append($0) }
            let began = ContinuousClock.now
            for _ in 0..<2 {
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("A renderer error cannot publish a response, even when Copy is present")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure,
                                         retainCopy ? .responseRenderingFailed : .responseFailed(.chatgpt)) }
            }
            XCTAssertLessThan(ContinuousClock.now - began, .seconds(3))
            XCTAssertEqual(evaluations.filter { $0 == "inspect" }.count, retainCopy ? 2 : 1)
            XCTAssertFalse(evaluations.contains("failedPageDiagnostic"), "The terminal observation must reuse the admitted read")
            XCTAssertEqual(timings.count, 1); XCTAssertEqual(renderers.count, 1)
            let timing = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(timings.first).utf8)) as? [String: Any])
            XCTAssertEqual(timing["phase"] as? String, "failure")
            XCTAssertEqual(timing["sequence"] as? Int, 1)
            XCTAssertEqual(timing["absenceInconclusive"] as? Bool, true)
            let renderer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(renderers.first).utf8)) as? [String: Any])
            XCTAssertEqual(renderer["reason"] as? String, "matched")
            XCTAssertEqual(renderer["rawKnownLabel"] as? Bool, true)
            XCTAssertEqual(renderer["guardBodyIsExtractedAnswer"] as? Bool, true)
            for diagnostic in timings + renderers {
                for privateValue in ["PRIVATE", "This response", "PortalBoundary-", "https:", token] {
                    XCTAssertFalse(diagnostic.contains(privateValue))
                }
            }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            XCTAssertEqual(timings.count, 1); XCTAssertEqual(renderers.count, 1)
            try await assertHumanTabIntact(fixture)
        }
    }

    func testDeadlineDiagnosticDiscardsAnOwnedViewRemovedBeforePublication() async throws {
        let (fixture, token, _) = try await boundInspectionFixture(prompt: "Discard a crossed diagnostic")
        defer { fixture.shutdown() }
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        var diagnostics: [String] = []
        var resourceDiagnostics: [String] = []
        fixture.transport.setFailedPageDiagnosticObserverForTesting { diagnostics.append($0) }
        fixture.transport.setResourceTimingDiagnosticObserverForTesting { resourceDiagnostics.append($0) }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "failedPageDiagnostic" { fixture.browser.closeTab(ownedID) }
        }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1))
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("The original response deadline remains the failure")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
        XCTAssertEqual(diagnostics, [])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        XCTAssertEqual(diagnostics, ["stale"])
        XCTAssertEqual(resourceDiagnostics, [], "A crossed owned view cannot publish resource observations either")
        try await assertHumanTabIntact(fixture)
    }

    func testQueuedDeadlineDiagnosticTimesOutOnceWithoutLatePublicationOrReplay() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Bound the failure diagnostic")
        defer { fixture.shutdown() }
        var diagnostics: [String] = []
        var diagnosticPublishedAt: ContinuousClock.Instant?
        fixture.transport.setFailedPageDiagnosticObserverForTesting { diagnostics.append($0); diagnosticPublishedAt = .now }
        let work = FixtureWebContentWork(view: view)
        defer { work.detach() }
        try await work.start(milliseconds: 1_600)
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1))
        let began = ContinuousClock.now
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A queued diagnostic cannot replace the original deadline failure")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(500))
        XCTAssertEqual(diagnostics, [])
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect" {
                do { try await self.assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1) }
                catch { XCTFail("The pre-close diagnostic fixture ledger must remain readable") }
            }
        }
        let cleanupBegan = ContinuousClock.now
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        let publication = try XCTUnwrap(diagnosticPublishedAt)
        XCTAssertLessThan(publication - cleanupBegan, .milliseconds(1_500))
        try await work.waitForCompletion()
        XCTAssertEqual(diagnostics, ["timed_out"], "Cleanup cannot retry an already claimed diagnostic")
        try await assertHumanTabIntact(fixture)
    }

    func testCodeStructureProjectionRejectsBridgedBooleanCountsAndNumericFlags() throws {
        let valid: [String: Any] = ["preCount": 1, "codeCount": 1, "codeTextLength": 129,
            "outsideTextLength": 4, "outsideTruncated": false, "preParentTags": ["div"],
            "outsideNodes": [["kind": "other", "textLength": 4, "ancestors": [[
                "tag": "div", "classes": ["flex"], "preDescendants": 1, "copyControls": 1]]]]]
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedCodeStructure(valid))
        for key in ["preCount", "codeCount", "codeTextLength", "outsideTextLength"] {
            var altered = valid; altered[key] = true
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(altered), key)
            altered[key] = 1.5
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(altered), key)
        }
        var altered = valid; altered["outsideTruncated"] = 0
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(altered))
        for key in ["preDescendants", "copyControls"] {
            var parent: [String: Any] = ["tag": "div", "classes": [], "preDescendants": 1, "copyControls": 1]
            parent[key] = false
            altered = valid; altered["outsideNodes"] = [["kind": "other", "textLength": 4, "ancestors": [parent]]]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(altered), key)
        }
        altered = valid; altered["outsideNodes"] = [["kind": "other", "textLength": true, "ancestors": []]]
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedCodeStructure(altered))
    }

    func testChatGPTRunningReadsKeepPickerClosedAndWithholdAnswerUntilFinalProof() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await evaluate(view, """
            window.fixturePickerOpensAfterSend = 0; window.fixtureHasSent = false;
            document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
              window.fixtureHasSent = true;
              const stop = document.createElement('button'); stop.id = 'fixture-running-stop';
              stop.setAttribute('data-testid', 'stop-button'); stop.textContent = 'Stop generating'; document.body.append(stop);
            });
            document.getElementById('fixture-model-trigger').addEventListener('click', () => {
              if (window.fixtureHasSent) window.fixturePickerOpensAfterSend++;
            }); return true;
            """)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Read this owned answer without disturbing its running model"])
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        for _ in 0..<2 {
            let running = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(running["state"] as? String, "running")
            try assertRunningOrVerifiedChoice(running, choice: choice)
            let opens = try await evaluate(view, "return window.fixturePickerOpensAfterSend;")
            XCTAssertEqual(opens as? Int, 0, "No post-Send model picker interaction is allowed while proof is pending")
        }
        _ = try await evaluate(view, "document.getElementById('fixture-running-stop').remove(); return true;")
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        let opens = try await evaluate(view, "return window.fixturePickerOpensAfterSend;")
        XCTAssertGreaterThan(try XCTUnwrap(opens as? Int), 0, "Only a completed owned answer may reacquire full positive picker proof")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTInspectionAndDeadlineDiagnosticShareTheCurrentAnswerCopyScope() async throws {
        for (scope, expectedCopy) in [("MAIN", false), ("BODY", false), ("HTML", false),
                                      ("sharedUserDIV", false), ("sibling", true), ("hiddenSibling", false)] {
            let (fixture, token, view) = try await boundInspectionFixture(
                prompt: "Keep completion controls inside the current answer", bindFirstRead: false)
            defer { fixture.shutdown() }
            let shape = try await evaluate(view, """
                const messages = document.getElementById('messages');
                const user = messages.querySelector('[data-message-author-role="user"]');
                const turn = messages.querySelector('section');
                const answer = turn.querySelector('[data-markdown-text-style="assistant-message"]');
                const footer = turn.querySelector('.turn-action-controls');
                const copy = footer.querySelector('button[aria-label="Copy"]');
                footer.remove();
                const scope = '\(scope)';
                if (scope === 'MAIN') {
                  const main = document.createElement('main');
                  messages.before(user, main); main.append(turn, footer); messages.remove();
                } else if (scope === 'BODY') {
                  messages.before(user, turn); document.body.append(footer); messages.remove();
                } else if (scope === 'HTML') {
                  document.documentElement.append(turn, footer);
                } else if (scope === 'sharedUserDIV') {
                  messages.append(footer);
                } else {
                  turn.append(footer); footer.hidden = scope === 'hiddenSibling';
                }
                const answers = [...document.querySelectorAll('[data-markdown-text-style="assistant-message"]')];
                return {footerParent: footer.parentElement.tagName, copyConnected: copy.isConnected,
                  copyVisible: copy.getClientRects().length > 0 && getComputedStyle(copy).visibility !== 'hidden',
                  copyDisabled: copy.disabled, copyOutsideAnswer: !answer.contains(copy),
                  footerScopeContainsUser: footer.parentElement.contains(user),
                  users: document.querySelectorAll('[data-message-author-role="user"]').length,
                  answers: answers.filter(node => !answers.some(other => other !== node && other.contains(node))).length};
                """) as? [String: Any]
            let actualShape = try XCTUnwrap(shape, scope)
            XCTAssertEqual(actualShape["footerParent"] as? String,
                ["MAIN", "BODY", "HTML"].contains(scope) ? scope : scope == "sharedUserDIV" ? "DIV" : "SECTION", scope)
            XCTAssertEqual(actualShape["copyConnected"] as? Bool, true, scope)
            XCTAssertEqual(actualShape["copyVisible"] as? Bool, scope != "hiddenSibling", scope)
            XCTAssertEqual(actualShape["copyDisabled"] as? Bool, false, scope)
            XCTAssertEqual(actualShape["copyOutsideAnswer"] as? Bool, true, scope)
            XCTAssertEqual(actualShape["footerScopeContainsUser"] as? Bool,
                           ["BODY", "HTML", "sharedUserDIV"].contains(scope), scope)
            XCTAssertEqual(actualShape["users"] as? Int, 1, scope)
            XCTAssertEqual(actualShape["answers"] as? Int, 1, scope)

            var progressRecords: [String] = [], failureRecords: [String] = []
            fixture.transport.setResponseProgressDiagnosticObserverForTesting { progressRecords.append($0) }
            fixture.transport.setFailedPageDiagnosticObserverForTesting { failureRecords.append($0) }
            let running = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(running["state"] as? String, "running", scope)
            // Preserve the ordinary inspect's finite flags, then exercise the
            // independent production deadline read on the same physical DOM.
            fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1))
            try await Task.sleep(for: .milliseconds(2))
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("The deadline must withhold output (\(scope))")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline, scope) }
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created", scope)
            XCTAssertEqual(progressRecords.count, 1, scope)
            XCTAssertEqual(failureRecords.count, 1, scope)
            let progress = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(progressRecords.first, scope).utf8)) as? [String: Any])
            let inspected = try XCTUnwrap(progress["lastInspection"] as? [String: Any], scope)
            XCTAssertEqual(inspected["responseCount"] as? Int, 1, scope)
            XCTAssertEqual(inspected["userCount"] as? Int, 1, scope)
            XCTAssertEqual(inspected["busy"] as? Bool, false, scope)
            XCTAssertEqual(inspected["answerComplete"] as? Bool, expectedCopy, scope)
            let failedPage = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(failureRecords.first, scope).utf8)) as? [String: Any])
            XCTAssertEqual(failedPage["copyPresent"] as? Bool, expectedCopy, scope)
            XCTAssertEqual(failedPage["copyEnabled"] as? Bool, expectedCopy, scope)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTNamedPairedFooterUsesRealDOMOrderAndRejectsAuthoredRowText() async throws {
        for authoredRowText in [false, true] {
            let prompt = "Read the exact owned answer from its paired turn"
            let (fixture, token, view) = try await boundInspectionFixture(prompt: prompt)
            defer { fixture.shutdown() }
            let shape = try await evaluate(view, """
                const messages = document.getElementById('messages');
                const user = messages.querySelector('[data-message-author-role="user"]');
                const section = messages.querySelector('section');
                const answer = section.querySelector('[data-markdown-text-style="assistant-message"]');
                const oldFooter = section.querySelector('.turn-action-controls');
                const copy = oldFooter.querySelector('button[aria-label="Copy"]');
                oldFooter.remove();
                const outer = document.createElement('div');
                outer.setAttribute('data-content-search-turn-key', 'fixture-owned-paired-turn');
                const pair = document.createElement('div');
                pair.setAttribute('data-talvt-turn-state', 'complete');
                const row = document.createElement('div');
                row.append(copy, document.createTextNode('\\n'));
                for (const label of ['Rate response', 'Read aloud', 'Regenerate response']) {
                  const button = document.createElement('button');
                  button.setAttribute('aria-label', label); button.textContent = label;
                  row.append(button);
                }
                if (\(authoredRowText)) row.append(document.createTextNode('Unrelated authored fixture prose'));
                window.fixturePairedFooterClicks = 0;
                row.querySelectorAll('button').forEach(button => button.addEventListener('click', () => {
                  window.fixturePairedFooterClicks++;
                }));
                pair.append(user, section, row); outer.append(pair); messages.append(outer);
                const roots = [...document.querySelectorAll('[data-markdown-text-style="assistant-message"]')];
                const answers = roots.filter(node => !roots.some(other => other !== node && other.contains(node)));
                return {users: document.querySelectorAll('[data-message-author-role="user"]').length,
                  answers: answers.length, pairedTurns: outer.querySelectorAll('[data-talvt-turn-state]').length,
                  userAndAnswerBound: user.closest('[data-talvt-turn-state]') === pair
                    && answer.closest('[data-talvt-turn-state]') === pair,
                  copyOutsideMessages: !user.contains(copy) && !answer.contains(copy),
                  oldAssistantScopeHasCopy: section.querySelector('button[aria-label="Copy"]') !== null,
                  userBeforeAnswer: (user.compareDocumentPosition(answer) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0,
                  answerBeforeRow: (answer.compareDocumentPosition(row) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0,
                  copyVisible: copy.getClientRects().length > 0 && getComputedStyle(copy).visibility !== 'hidden',
                  copies: pair.querySelectorAll('button[aria-label="Copy"]').length,
                  companions: row.querySelectorAll('button').length - 1,
                  authoredTextNodes: [...row.childNodes].filter(node => node.nodeType === Node.TEXT_NODE
                    && node.textContent.trim()).length};
                """) as? [String: Any]
            let actualShape = try XCTUnwrap(shape)
            for key in ["users", "answers", "pairedTurns", "copies"] {
                XCTAssertEqual(actualShape[key] as? Int, 1, key)
            }
            for key in ["userAndAnswerBound", "copyOutsideMessages", "userBeforeAnswer", "answerBeforeRow", "copyVisible"] {
                XCTAssertEqual(actualShape[key] as? Bool, true, key)
            }
            XCTAssertEqual(actualShape["oldAssistantScopeHasCopy"] as? Bool, false)
            XCTAssertEqual(actualShape["companions"] as? Int, 3)
            XCTAssertEqual(actualShape["authoredTextNodes"] as? Int, authoredRowText ? 1 : 0)

            var progressRecords: [String] = [], failureRecords: [String] = []
            if authoredRowText {
                fixture.transport.setResponseProgressDiagnosticObserverForTesting { progressRecords.append($0) }
                fixture.transport.setFailedPageDiagnosticObserverForTesting { failureRecords.append($0) }
                let running = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(running["state"] as? String, "running")
                try assertRunningOrVerifiedChoice(running, choice: Self.fixtureChoice(.chatgpt))
                fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1))
                try await Task.sleep(for: .milliseconds(2))
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("Authored footer-row text must withhold completion")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
                XCTAssertEqual(progressRecords.count, 1)
                XCTAssertEqual(failureRecords.count, 0,
                    "The independent deadline page read runs during Finish, not the expired poll")
                let progress = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: Data(try XCTUnwrap(progressRecords.first).utf8)) as? [String: Any])
                let inspected = try XCTUnwrap(progress["lastInspection"] as? [String: Any])
                XCTAssertEqual(inspected["responseCount"] as? Int, 1)
                XCTAssertEqual(inspected["userCount"] as? Int, 1)
                XCTAssertEqual(inspected["busy"] as? Bool, false)
                XCTAssertEqual(inspected["answerComplete"] as? Bool, false)
            } else {
                let complete = try await waitForState("complete", fixture.transport, token: token)
                XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
                XCTAssertEqual(complete["sequence"] as? Int, 1)
                try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
                XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
                let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
                XCTAssertEqual(proof["submittedPromptFingerprint"] as? String,
                    EmbeddedWebModelTransport.promptFingerprint(prompt))
            }
            let clicks = try await evaluate(view, "return window.fixturePairedFooterClicks;")
            XCTAssertEqual(clicks as? Int, 0)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            if authoredRowText {
                XCTAssertEqual(failureRecords.count, 1)
                let failedPage = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: Data(try XCTUnwrap(failureRecords.first).utf8)) as? [String: Any])
                XCTAssertEqual(failedPage["copyPresent"] as? Bool, false,
                    "The deadline read has no native submission pins and cannot prove paired Copy")
                XCTAssertEqual(failedPage["copyEnabled"] as? Bool, false)
            }
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTLoadFailureIsTypedTerminalAndDoesNotReplayOrBlockOtherSessions() async throws {
        for alreadyBound in [false, true] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Detect the website's actual load failure", bindFirstRead: alreadyBound)
            defer { fixture.shutdown() }
            _ = try await evaluate(view, """
                const main = document.createElement('main');
                document.body.appendChild(main);
                const error = document.createElement('div');
                const text = document.createElement('span'); text.textContent = 'Load failed';
                const retry = document.createElement('button'); retry.textContent = 'Retry';
                window.fixtureRetryClicks = 0;
                retry.addEventListener('click', () => window.fixtureRetryClicks++);
                error.append(text, retry); main.append(error); return true;
                """)
            let began = ContinuousClock.now
            for _ in 0..<2 {
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("A visible Load failed / Retry response must not wait for the response deadline")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt)) }
            }
            XCTAssertLessThan(ContinuousClock.now - began, .seconds(3))
            let failure = EmbeddedWebModelTransport.Failure.responseFailed(.chatgpt)
            XCTAssertEqual(failure.diagnosticCode, "website_response_failed")
            XCTAssertEqual(failure.requiredAction, "inspect_website")
            XCTAssertFalse(failure.blocksProviderUntilRefresh)
            let retryClicks = try await evaluate(view, "return window.fixtureRetryClicks;")
            XCTAssertEqual(retryClicks as? Int, 0)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
            let next = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let nextToken = try XCTUnwrap(next["sessionToken"] as? String)
            _ = try await waitForState("ready", fixture.transport, token: nextToken)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": nextToken])
        }
    }

    func testChatGPTGenericLoadFailureAbortsOnceWithDirectOrNestedText() async throws {
        for alreadyBound in [false, true] {
            for nestedLabel in [false, true] {
                let (fixture, token, view) = try await boundInspectionFixture(
                    prompt: "Detect a small generic website error widget", bindFirstRead: alreadyBound)
                defer { fixture.shutdown() }
                _ = try await evaluate(view, """
                    const main = document.createElement('main');
                    const container = document.createElement('div');
                    const error = document.createElement('div');
                    if (\(nestedLabel ? "true" : "false")) {
                        const label = document.createElement('span'); label.append(document.createTextNode('Load '));
                        const nested = document.createElement('strong'); nested.textContent = 'failed';
                        label.append(nested); error.append(label);
                    } else error.append(document.createTextNode('Load failed'));
                    const retry = document.createElement('button'); retry.textContent = 'Retry';
                    window.fixtureRetryClicks = 0;
                    retry.addEventListener('click', () => window.fixtureRetryClicks++);
                    error.append(retry); container.append(error); main.append(container); document.body.append(main);
                    return error.getAttribute('role') === null;
                    """)
                var evaluations: [String] = []
                fixture.transport.setBeforePageResultValidationForTesting { evaluations.append($0) }
                let began = ContinuousClock.now
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("A direct generic Load failed widget must abort before the response deadline")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt)) }
                XCTAssertLessThan(ContinuousClock.now - began, .seconds(3))
                XCTAssertTrue(evaluations.contains("inspect"), "The error must come from an admitted current page read")
                let evaluationsAtFailure = evaluations
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("A terminal website error must remain terminal")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt)) }
                XCTAssertEqual(evaluations, evaluationsAtFailure, "A repeated poll must not evaluate the adapter again")
                fixture.transport.setBeforePageResultValidationForTesting(nil)
                let failure = EmbeddedWebModelTransport.Failure.responseFailed(.chatgpt)
                XCTAssertEqual(failure.diagnosticCode, "website_response_failed")
                XCTAssertEqual(failure.requiredAction, "inspect_website")
                XCTAssertFalse(failure.blocksProviderUntilRefresh)
                let retryClicks = try await evaluate(view, "return window.fixtureRetryClicks;")
                XCTAssertEqual(retryClicks as? Int, 0)
                try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
                _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
                try await assertHumanTabIntact(fixture)
                let next = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
                let nextToken = try XCTUnwrap(next["sessionToken"] as? String)
                _ = try await waitForState("ready", fixture.transport, token: nextToken)
                _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": nextToken])
            }
        }
    }

    func testChatGPTNestedAlertAsideLoadFailureAbortsWithoutRetryOrReplay() async throws {
        for alreadyBound in [false, true] {
            let (fixture, token, view) = try await boundInspectionFixture(
                prompt: "Detect the measured semantic website error", bindFirstRead: alreadyBound)
            defer { fixture.shutdown() }
            let count = try await evaluate(view, """
                const main = document.createElement('main');
                const alert = document.createElement('aside'); alert.setAttribute('role', 'alert');
                const empty = document.createElement('div'), content = document.createElement('div');
                const row = document.createElement('div'), errorBranch = document.createElement('div');
                const labelWrapper = document.createElement('div'), label = document.createElement('div');
                label.textContent = 'Load failed';
                const controlBranch = document.createElement('div'), retry = document.createElement('button');
                retry.textContent = 'Retry'; window.fixtureRetryClicks = 0;
                retry.addEventListener('click', () => window.fixtureRetryClicks++);
                alert.append(empty, content); content.append(row); row.append(errorBranch, controlBranch);
                errorBranch.append(labelWrapper); labelWrapper.append(label); controlBranch.append(retry);
                main.append(alert); document.body.append(main); return alert.querySelectorAll('*').length + 1;
                """)
            XCTAssertEqual(count as? Int, 9, "The measured error fixture contains exactly nine elements")
            var evaluations: [String] = []
            fixture.transport.setBeforePageResultValidationForTesting { evaluations.append($0) }
            let began = ContinuousClock.now
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("The owned semantic error widget must abort before the deadline")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt)) }
            XCTAssertLessThan(ContinuousClock.now - began, .seconds(3))
            XCTAssertTrue(evaluations.contains("inspect"))
            let evaluationsAtFailure = evaluations
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("The website response failure must stay terminal")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt)) }
            XCTAssertEqual(evaluations, evaluationsAtFailure)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            let retryClicks = try await evaluate(view, "return window.fixtureRetryClicks;")
            XCTAssertEqual(retryClicks as? Int, 0)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
            let next = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let nextToken = try XCTUnwrap(next["sessionToken"] as? String)
            _ = try await waitForState("ready", fixture.transport, token: nextToken)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": nextToken])
        }
    }

    func testChatGPTModalLoadFailureCannotOverrideCurrentModelVerification() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Keep current model proof ahead of a modal error")
        defer { fixture.shutdown() }
        _ = try await evaluate(view, """
            const main = document.createElement('main');
            const dialog = document.createElement('div'); dialog.setAttribute('role', 'dialog');
            const error = document.createElement('div'); error.append(document.createTextNode('Load failed'));
            const retry = document.createElement('button'); retry.textContent = 'Retry';
            window.fixtureRetryClicks = 0;
            retry.addEventListener('click', () => window.fixtureRetryClicks++);
            error.append(retry); dialog.append(error); main.append(dialog); document.body.append(main);
            return true;
            """)
        var evaluations: [String] = []
        fixture.transport.setBeforePageResultValidationForTesting { evaluations.append($0) }
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("An unassociated modal must keep the earlier model guard closed")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnverified) }
        XCTAssertTrue(evaluations.contains("inspect"))
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let retryClicks = try await evaluate(view, "return window.fixtureRetryClicks;")
        XCTAssertEqual(retryClicks as? Int, 0)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testPendingFirstBodyInspectionTimeoutGetsOneFreshReadWithoutResending() async throws {
        let prompt = "Recover only the acknowledged pending first body"
        let (fixture, token, view) = try await pendingFirstBodyInspectionFixture(prompt: prompt)
        defer { fixture.shutdown() }
        fixture.transport.setInspectionTimeoutForTesting(.milliseconds(800))
        var timeouts: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 1_100)
        var completed: [String: Any]?
        var recoveryFailure: (any Error)?
        do { completed = try await waitForState("complete", fixture.transport, token: token) }
        catch { recoveryFailure = error }
        try await blocker.waitForCompletion()
        XCTAssertEqual(timeouts.count, 1)
        XCTAssertTrue(timeouts.first?.contains("phases=not_started") == true)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
        if let recoveryFailure {
            XCTFail("An acknowledged pending first-body timeout must get one fresh read: \(recoveryFailure)")
            return
        }
        XCTAssertEqual(completed?["text"] as? String, Self.fixtureToolReply)
        let proof = try XCTUnwrap(completed?["modelProofContext"] as? [String: Any])
        XCTAssertEqual(proof["sequence"] as? Int, 1)
        XCTAssertFalse((proof["firstUserFingerprint"] as? String ?? "").isEmpty)
        XCTAssertFalse((proof["submittedPromptFingerprint"] as? String ?? "").isEmpty)
    }

    func testPendingFirstBodyInspectionRecoveryStopsAfterSecondTimeout() async throws {
        let (fixture, token, view) = try await pendingFirstBodyInspectionFixture(prompt: "Bound the first-body read recovery")
        defer { fixture.shutdown() }
        fixture.transport.setInspectionTimeoutForTesting(.milliseconds(600))
        var timeouts: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 2_400)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A second timeout cannot authorize another first-body read")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .pageUnavailable) }
        XCTAssertEqual(timeouts.count, 2)
        try await blocker.waitForCompletion()
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testPendingFirstBodyInspectionRecoveryKeepsOriginalResponseDeadline() async throws {
        let (fixture, token, view) = try await pendingFirstBodyInspectionFixture(prompt: "Keep the original first-body deadline")
        defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1_200))
        fixture.transport.setInspectionTimeoutForTesting(.milliseconds(800))
        var timeouts: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 2_400)
        let began = ContinuousClock.now
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("First-body recovery cannot renew the original response deadline")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(1_500))
        XCTAssertTrue((1...2).contains(timeouts.count))
        try await blocker.waitForCompletion()
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testPendingFirstBodyInspectionRecoveryRejectsModelAndWorkModeDrift() async throws {
        for drift in ["model", "work"] {
            let (fixture, token, view) = try await pendingFirstBodyInspectionFixture(prompt: "Reject first-body \(drift) drift")
            defer { fixture.shutdown() }
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            fixture.transport.setInspectionTimeoutForTesting(.milliseconds(800))
            var timeouts: [String] = []
            fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
            let blocker = FixtureWebContentWork(view: view)
            defer { blocker.detach() }
            let mutation = drift == "model"
                ? "window.fixtureModelSelect('GPT-5.5');"
                : "document.getElementById('fixture-composer-mode').hidden = false; document.getElementById('fixture-chat-mode').setAttribute('aria-pressed','false'); document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true');"
            try await blocker.start(milliseconds: 1_100, completionScript: mutation)
            do {
                _ = try await waitForState("complete", fixture.transport, token: token)
                XCTFail("The fresh first-body read must not publish \(drift) drift")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, drift == "model" ? .modelMismatch : .productModeUnverified)
            }
            XCTAssertEqual(timeouts.count, 1)
            try await blocker.waitForCompletion()
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, drift == "work" ? "failed" : "not_created")
            try await assertHumanTabIntact(fixture, retaining: drift == "work" ? ownedID : nil)
        }
    }

    func testPendingFirstBodyInspectionTimeoutWithoutSendReceiptDoesNotRecover() async throws {
        let (fixture, token, view) = try await pendingFirstBodyInspectionFixture(prompt: "A Send claim alone cannot grant recovery")
        defer { fixture.shutdown() }
        XCTAssertTrue(fixture.transport.revokeAcknowledgedSendForTesting(sessionToken: token))
        fixture.transport.setInspectionTimeoutForTesting(.milliseconds(800))
        var timeouts: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 1_100)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("The native pre-click Send claim cannot replace its validated callback")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .pageUnavailable) }
        XCTAssertEqual(timeouts.count, 1)
        try await blocker.waitForCompletion()
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testBoundInspectionTimeoutGetsOneFreshReadWithoutResending() async throws {
        let prompt = "Recover an owned read without resending"
        let (fixture, token, view) = try await boundInspectionFixture(prompt: prompt)
        defer { fixture.shutdown() }
        fixture.transport.setInspectionTimeoutForTesting(.milliseconds(450))
        var timeouts = [String]()
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 700)
        let completed: [String: Any]
        do { completed = try await waitForState("complete", fixture.transport, token: token) }
        catch {
            // Keep failure teardown from closing a WebContent queue which is
            // still occupied by this fixture's deliberately delayed read.
            try await blocker.waitForCompletion()
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTFail("Owned inspection recovery failed; timedOut=\((error as? EmbeddedWebModelTransport.Failure) == .pageUnavailable) callbacks=\(timeouts.count)")
            return
        }
        try await blocker.waitForCompletion()
        XCTAssertEqual(completed["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        XCTAssertEqual(timeouts.count, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testBoundInspectionRecoveryStopsAfterSecondReadTimeout() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Bounded read recovery")
        defer { fixture.shutdown() }
        fixture.transport.setInspectionTimeoutForTesting(.milliseconds(300))
        var timeouts = [String]()
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 1_200)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A second timed-out read must remain a terminal transport failure")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .pageUnavailable) }
        XCTAssertEqual(timeouts.count, 2, "Exactly one read recovery is allowed")
        try await blocker.waitForCompletion()
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testBoundInspectionRecoveryCannotExtendResponseDeadline() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "No late read admission")
        defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(450))
        fixture.transport.setInspectionTimeoutForTesting(.milliseconds(300))
        var timeouts = [String]()
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 1_200)
        XCTAssertTrue(fixture.transport.anchorResponseDeadlineForTesting(sessionToken: token))
        let began = ContinuousClock.now
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("Read recovery cannot extend the original response deadline")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(1))
        XCTAssertEqual(timeouts.count, 2, "The fresh read must stop at the original response deadline")
        try await blocker.waitForCompletion()
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testBoundInspectionRecoveryRechecksCurrentModelAndChatMode() async throws {
        for drift in ["work", "model"] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Reject drift on recovery")
            defer { fixture.shutdown() }
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            fixture.transport.setInspectionTimeoutForTesting(.milliseconds(450))
            var timeouts = [String]()
            fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
            let blocker = FixtureWebContentWork(view: view)
            defer { blocker.detach() }
            try await blocker.start(milliseconds: 700)
            var changed = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "inspect", !changed else { return }
                changed = true
                let script = drift == "model"
                    ? "window.fixtureModelSelect('GPT-5.5'); return true;"
                    : "document.getElementById('fixture-composer-mode').hidden = false; document.getElementById('fixture-chat-mode').setAttribute('aria-pressed','false'); document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true'); return true;"
                _ = try? await self.evaluate(view, script)
            }
            if drift == "model" {
                try await assertModelMismatchBeforePublication(fixture.transport, token: token, choice: Self.fixtureChoice(.chatgpt))
            } else {
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("Recovery must reject current Work-mode drift")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
            }
            XCTAssertTrue(changed)
            XCTAssertEqual(timeouts.count, 1)
            try await blocker.waitForCompletion()
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, drift == "work" ? "failed" : "not_created")
            try await assertHumanTabIntact(fixture, retaining: drift == "work" ? ownedID : nil)
        }
    }

    func testOriginalChatContextReadReturnsOneFiniteSidecarBeforeThrowAndCleanupCannotReplaceIt() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "PRIVATE_CONTEXT_READ_CANARY")
        defer { fixture.shutdown() }
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        // Bind the body explicitly before revocation. Send's fresh model read
        // may already bind it, so skipping the first poll cannot prove pending.
        let phase = try await evaluate(view, "return globalThis.__computaChatSubmissionState.lastVerified?.phase;",
            world: .world(name: "computa-chatgpt-model-v1"))
        XCTAssertEqual(phase as? String, "verified")
        _ = try await evaluate(view, "globalThis.__computaChatSubmissionState.revoked = true; return true;",
            world: .world(name: "computa-chatgpt-model-v1"))
        let sink = ChatSubmissionFailureDiagnosticSink()
        do {
            _ = try await fixture.transport.request(operation: "webProviderPoll",
                params: JSONSerialization.data(withJSONObject: ["sessionToken": token]),
                onChatSubmissionFailure: { sink.record($0) })
            XCTFail("Diagnostic capture must preserve the original ownership failure")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
        let diagnostic = try XCTUnwrap(sink.snapshot).dictionary
        XCTAssertEqual(diagnostic["stage"] as? String, "observe_context")
        XCTAssertEqual(diagnostic["oldRootPresent"] as? Bool, true)
        XCTAssertEqual(diagnostic["oldBodyPresent"] as? Bool, true)
        XCTAssertEqual(diagnostic["recordPhase"] as? String, "verified")
        let checks = try XCTUnwrap(diagnostic["contextChecks"] as? [String: Any])
        XCTAssertEqual(checks["stateNotRevoked"] as? Bool, false)
        XCTAssertTrue(checks["stateDocumentMatches"] is NSNull)
        let safe = String(decoding: try JSONSerialization.data(withJSONObject: diagnostic), as: UTF8.self)
        for secret in ["PRIVATE_CONTEXT_READ_CANARY", token, "https:", "Computa session marker"] { XCTAssertFalse(safe.contains(secret)) }
        let duplicate = ChatSubmissionFailureDiagnosticSink()
        do {
            _ = try await fixture.transport.request(operation: "webProviderPoll",
                params: JSONSerialization.data(withJSONObject: ["sessionToken": token]),
                onChatSubmissionFailure: { duplicate.record($0) })
            XCTFail("The original terminal guard still refuses another poll")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
        XCTAssertNil(duplicate.snapshot)
        let cleanup = try await fixture.transport.request(operation: "webProviderFinish",
            params: JSONSerialization.data(withJSONObject: ["sessionToken": token]),
            onChatSubmissionFailure: { duplicate.record($0) })
        XCTAssertEqual((try JSONSerialization.jsonObject(with: cleanup) as? [String: Any])?["cleanup"] as? String, "failed")
        XCTAssertNil(duplicate.snapshot, "A later cleanup read is not the original failed inference")
        let errorBody = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.ownershipFailure(.javaScriptSubmission))
        XCTAssertFalse(String(decoding: errorBody, as: UTF8.self).contains("contextChecks"))
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        try await assertHumanTabIntact(fixture, retaining: ownedID)
    }

    func testChatContextSidecarCannotPublishFromAReadWhoseOwnedViewWasRemovedBeforeValidation() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "PRIVATE_STALE_CONTEXT", bindFirstRead: false)
        defer { fixture.shutdown() }
        let tab = try XCTUnwrap(fixture.createdTabs.last)
        _ = try await evaluate(view, "globalThis.__computaChatSubmissionState.revoked = true; return true;",
            world: .world(name: "computa-chatgpt-model-v1"))
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect" { fixture.browser.closeTab(tab) }
        }
        let sink = ChatSubmissionFailureDiagnosticSink()
        do {
            _ = try await fixture.transport.request(operation: "webProviderPoll",
                params: JSONSerialization.data(withJSONObject: ["sessionToken": token]),
                onChatSubmissionFailure: { sink.record($0) })
            XCTFail("The stale view remains rejected")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .staleSession) }
        XCTAssertNil(sink.snapshot)
        try await assertHumanTabIntact(fixture)
    }

    private func pendingFirstBodyInspectionFixture(prompt: String) async throws -> (Fixture, String, WKWebView) {
        let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
        do {
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
            let pending = try XCTUnwrap(sent["pendingSubmissionContext"] as? [String: Any])
            XCTAssertEqual(sent["state"] as? String, "running")
            XCTAssertEqual(pending["sequence"] as? Int, 1)
            XCTAssertEqual(pending["firstUserFingerprint"] as? String, "")
            XCTAssertEqual(pending["submittedPromptFingerprint"] as? String, "")
            let privateState = try await evaluate(view, """
                const state = globalThis.__computaChatSubmissionState;
                return { firstProof: globalThis.__computaModelFirstProof != null,
                  phase: state?.pending?.phase, bound: state?.pending?.root != null };
                """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
            XCTAssertEqual(privateState?["firstProof"] as? Bool, false)
            XCTAssertEqual(privateState?["phase"] as? String, "send_claimed")
            XCTAssertEqual(privateState?["bound"] as? Bool, false)
            _ = try await evaluate(view, """
                document.getElementById('messages').appendChild(window.fixturePendingUser);
                document.getElementById('messages').appendChild(window.fixturePendingTurn);
                window.fixturePendingUser = null; window.fixturePendingTurn = null; return true;
                """)
            return (fixture, token, view)
        } catch { fixture.shutdown(); throw error }
    }

    private func boundInspectionFixture(prompt: String, bindFirstRead: Bool = true) async throws -> (Fixture, String, WKWebView) {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        do {
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
            if bindFirstRead {
                let first = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(first["state"] as? String, "running")
                try assertRunningOrVerifiedChoice(first, choice: Self.fixtureChoice(.chatgpt))
            }
            return (fixture, token, view)
        } catch { fixture.shutdown(); throw error }
    }

    func testOwnedChatGPTReplySkipsRepeatedGenericStructureWalkAfterFirstBinding() async throws {
        let (fixture, view, token, choice) = try await readyInstantPrepareFixture()
        defer { fixture.shutdown() }
        let privateWorld = WKContentWorld.world(name: "computa-chatgpt-model-v1")
        _ = try await evaluate(view, """
            globalThis.fixtureGenericStructureWalks = 0;
            const original = document.createTreeWalker;
            document.createTreeWalker = function(...args) {
              globalThis.fixtureGenericStructureWalks++;
              return original.apply(this, args);
            }; return true;
            """, world: privateWorld)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Bind this owned response before skipping its unused page anatomy diagnostic"])
        let first = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        try assertRunningOrVerifiedChoice(first, choice: choice)
        let initialWalks = try await evaluate(view, "return globalThis.fixtureGenericStructureWalks;", world: privateWorld) as? Int
        XCTAssertGreaterThan(try XCTUnwrap(initialWalks), 0, "The first unbound inspection keeps the original structural diagnostic")
        _ = try await evaluate(view, "globalThis.fixtureGenericStructureWalks = 0; return true;", world: privateWorld)
        let next = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        try assertRunningOrVerifiedChoice(next, choice: choice)
        let repeatedWalks = try await evaluate(view, "return globalThis.fixtureGenericStructureWalks;", world: privateWorld) as? Int
        XCTAssertEqual(repeatedWalks, 0, "The native request must skip the unused body-tree diagnostic on an ordinary owned 1/1 reply")
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        try assertChoiceEvidence(complete, choice: choice)
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testOwnedChatGPTStructureOptOutKeepsSpecificFirstUserFailureDiagnostics() async throws {
        let prompt = "Original private diagnostic body"
        let (fixture, token, view) = try await boundInspectionFixture(prompt: prompt)
        defer { fixture.shutdown() }
        var emissions: [(isFailure: Bool, record: String)] = []
        fixture.transport.setFirstUserStructureEmissionObserverForTesting { emissions.append(($0, $1)) }
        let changed = try await evaluate(view, """
            const user = document.querySelector('[data-message-author-role="user"]');
            const body = user.querySelector('[data-markdown-text-style="user-message"]');
            const before = body.textContent;
            body.textContent = before.replace('Original private diagnostic body', 'Changed private diagnostic body');
            return body.textContent !== before;
            """) as? Bool
        XCTAssertEqual(changed, true)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("Opting out of a generic anatomy log cannot admit a changed owned user body")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser))
        }
        let records = try emissions.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.record.utf8)) as? [String: Any]) }
        XCTAssertTrue(emissions.contains { $0.isFailure })
        XCTAssertTrue(records.contains { $0["kind"] as? String == "first_user_structure" },
            "The independent rejection path must retain its finite first-user diagnostic")
        XCTAssertFalse(emissions.contains { $0.record.contains(prompt) || $0.record.contains("Changed private diagnostic body") })
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
    }

    func testConcreteChatGPTDefersPickerReadsUntilFullCompletedAnswerProof() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Prove the current model and Chat mode together"])
        let first = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(first["state"] as? String, "running")
        try assertRunningOrVerifiedChoice(first, choice: Self.fixtureChoice(.chatgpt))
        fixture.transport.setInspectionTimeoutForTesting(.seconds(2))
        var actions: [String] = []
        var timeouts: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            actions.append(action)
            if ["verifyModel", "verifyProductMode"].contains(action) {
                // Real asynchronous handoff delay: redundant context reads
                // exhaust the unchanged shared inspection budget.
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        let completed: [String: Any]
        do {
            completed = try await waitForState("complete", fixture.transport, token: token)
        } catch {
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            let budgetExpired = error as? EmbeddedWebModelTransport.Failure == .pageUnavailable
            XCTFail("Combined context inspection budget expired=\(budgetExpired); native timer callbacks=\(timeouts.count); observed reads=\(actions)")
            return
        }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertEqual(timeouts, [])
        XCTAssertEqual(completed["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        XCTAssertFalse(actions.isEmpty)
        XCTAssertTrue(actions.allSatisfy { ["inspect", "verifyProductMode"].contains($0) }, actions.description)
        XCTAssertEqual(actions.filter { $0 == "verifyModel" }.count, 0,
                       "Running reads must not reopen the model picker; the final inspect proves the completed answer")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testConcreteChatGPTCombinedReadRejectsWorkAndModelDriftAcrossNativeAwait() async throws {
        for drift in ["work", "model"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never admit a stale model or Work response"])
            let first = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            try assertRunningOrVerifiedChoice(first, choice: Self.fixtureChoice(.chatgpt))
            var changed = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "inspect", !changed else { return }
                changed = true
                let script = drift == "model"
                    ? "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;"
                    : "document.getElementById('fixture-composer-mode').hidden = false; document.getElementById('fixture-chat-mode').setAttribute('aria-pressed','false'); document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true'); return true;"
                _ = try? await self.evaluate(view, script)
            }
            if drift == "model" {
                try await assertModelMismatchBeforePublication(fixture.transport, token: token, choice: Self.fixtureChoice(.chatgpt))
            } else {
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("The current product controls must reject Work-mode drift")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
            }
            XCTAssertTrue(changed)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, drift == "work" ? "failed" : "not_created")
            try await assertHumanTabIntact(fixture, retaining: drift == "work" ? ownedID : nil)
        }
    }

    func testTenSecondInspectionRecoveryCannotOutliveResponseDeadline() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .seconds(11))
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Verify a queued read expires without replay"])
        fixture.transport.setInspectionTimeoutForTesting(.seconds(10))
        var timeouts: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 12_000)
        let began = ContinuousClock.now
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("Read recovery must stop at the original response deadline before the queued reply")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
        XCTAssertGreaterThan(ContinuousClock.now - began, .seconds(9))
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(12))
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertTrue(timeouts.first?.contains("diagnosticsReceived=0") == true)
        try await blocker.waitForCompletion()
        XCTAssertEqual(timeouts.count, 2)
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Verify a queued read expires without replay"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID])
    }

    func testInspectionSurvivesWebContentQueueDelayBeyondTenSeconds() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .seconds(45))
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "One submission across queued inspection"])
        var timeouts: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 12_000)
        let began = ContinuousClock.now
        _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertGreaterThan(ContinuousClock.now - began, .seconds(10), "The fixture must actually delay native inspection beyond the old budget")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(20))
        try await blocker.waitForCompletion()
        let completed = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(completed["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        XCTAssertEqual(timeouts, [])
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["One submission across queued inspection"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID])
    }

    func testQueuedInspectionStillStopsAtResponseDeadlineWithoutAcceptingLateReply() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never accept a reply after its deadline"])
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(400))
        var timeouts: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { timeouts.append($0) }
        let blocker = FixtureWebContentWork(view: view)
        defer { blocker.detach() }
        try await blocker.start(milliseconds: 1_500)
        let began = ContinuousClock.now
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("Queued inspection must not extend the response deadline")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(1))
        XCTAssertEqual(timeouts.count, 1)
        XCTAssertTrue(timeouts.first?.contains("diagnosticsReceived=0") == true)
        try await blocker.waitForCompletion()
        XCTAssertEqual(timeouts.count, 1, "A late callback cannot reopen the timed-out operation")
        XCTAssertTrue(fixture.browser.modelDiagnosticSnapshot(tabID: try XCTUnwrap(fixture.createdTabs.last)).contains("active=false"))
        let prompts = try await capturedUserPrompts(view)
        XCTAssertEqual(prompts?.map { $0.trimmingCharacters(in: .newlines) }, ["Never accept a reply after its deadline"])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID])
    }

    func testStalledFirstUserDigestReportsNativePhaseAndCannotAcceptAReply() async throws {
        let fixture = try Fixture(page: Self.page)
        defer { fixture.shutdown() }
        let start = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(start["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "PRIVATE_PROMPT_CANARY"])
        _ = try await evaluate(view, """
        const original = crypto.subtle.digest.bind(crypto.subtle);
        crypto.subtle.digest = (...args) => {
          globalThis.__computaFixtureDigestPromise = new Promise(resolve => {
            globalThis.__computaFixtureDigestResolve = async () => resolve(await original(...args));
          });
          return globalThis.__computaFixtureDigestPromise;
        };
        return true;
        """,
                               world: .world(name: "computa-chatgpt-model-v1"))
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .seconds(2))
        var diagnostics: [String] = []
        fixture.transport.setAdapterTimeoutObserverForTesting { diagnostics.append($0) }
        let began = ContinuousClock.now
        do {
            let reply = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertNotEqual(reply["state"] as? String, "complete")
            XCTAssertNil(reply["response"])
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline)
        }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(4))
        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertTrue(diagnostic.contains("first_user_hash"), diagnostic)
        XCTAssertTrue(diagnostic.contains("width="))
        XCTAssertFalse(diagnostic.contains("PRIVATE_PROMPT_CANARY"))
        XCTAssertFalse(diagnostic.contains("Fixture reply"))
        XCTAssertFalse(diagnostic.contains(token))
        XCTAssertFalse(diagnostic.contains("chatgpt.com"))
        XCTAssertLessThan(diagnostic.utf8.count, 1_024)
        let ended = fixture.browser.modelDiagnosticSnapshot(tabID: try XCTUnwrap(fixture.createdTabs.last))
        XCTAssertTrue(ended.contains("active=false"))
        _ = try await evaluate(view, "await globalThis.__computaFixtureDigestResolve(); return true;",
                               world: .world(name: "computa-chatgpt-model-v1"))
        await Task.yield()
        XCTAssertTrue(fixture.browser.modelDiagnosticSnapshot(tabID: try XCTUnwrap(fixture.createdTabs.last)).contains("active=false"))
        XCTAssertEqual(diagnostics.count, 1, "A late completion cannot restart the native timeout or operation")
    }

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
        var failed = raw
        failed["productProofFailure"] = "mutation_overflow"
        failed["productMutationRelevantCount"] = 513
        failed["productMutationIgnoredCount"] = 1_000
        let failure = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(failed))
        XCTAssertTrue(failure.contains("mutation_overflow"))
        XCTAssertLessThan(failure.utf8.count, 2_048)
        for reason in ["mutation_scan_overflow", "mutation_uninspectable", "product_history_ambiguous"] {
            var boundedFailure = failed; boundedFailure["productProofFailure"] = reason
            let diagnostic = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(boundedFailure))
            XCTAssertTrue(diagnostic.contains(reason))
            XCTAssertLessThan(diagnostic.utf8.count, 2_048)
        }
        for field in ["productMutationRelevantCount", "productMutationIgnoredCount"] {
            for bad in [-1, 1_001, 0.5, true, NSNull(), "PRIVATE_RAW_PAGE_CANARY"] as [Any] {
                var invalid = failed; invalid[field] = bad
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(invalid))
            }
        }
        for bad in ["PRIVATE_RAW_PAGE_CANARY", true, NSNull()] as [Any] {
            var invalid = failed; invalid["productProofFailure"] = bad
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(invalid))
        }
    }

    func testProductMutationHistogramIsFiniteAndSharedAcrossDiagnosticRoutes() throws {
        let histogram: [String: Any] = ["version": 1, "phase": "send_claimed", "capped": true,
            "types": ["attributes": 1_000, "childList": 1_000, "characterData": 1_000, "other": 1_000],
            "scopes": ["trackedProduct": 1_000, "message": 1_000, "composer": 1_000, "other": 1_000],
            "composerAttributes": ["class": 1_000, "style": 1_000, "other": 1_000]]
        let product: [String: Any] = ["kind": "chatgpt_product_mode_structure", "groupCount": 0,
            "groupVisible": false, "recognized": false, "contradictory": false,
            "chat": NSNull(), "work": NSNull(), "proofPresent": true, "proofInvalidated": true,
            "chatClickClaimed": false, "productProofFailure": "mutation_overflow",
            "productMutationRelevantCount": 513, "productMutationIgnoredCount": 1_000]
        let firstUser: [String: Any] = ["kind": "first_user_structure", "provider": "chatgpt", "reason": "marker_not_final",
            "scope": "marker_validation", "action": "inspect", "root": ["tag": "div", "classes": []],
            "body": ["tag": "div", "classes": []], "userCount": 1, "textLength": 10_240, "lineCount": 98,
            "markerOccurrences": 0, "controlDescendants": 0, "markerFinalLine": false, "submitted": true, "markerMatches": true,
            "expansionOutcome": "context_changed", "expansionContextFailure": "product",
            "productProofFailure": "mutation_overflow", "productMutationRelevantCount": 513, "productMutationIgnoredCount": 1_000]
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        func withHistogram(_ source: [String: Any], _ value: Any) -> [String: Any] {
            source.merging(["productMutationHistogram": value]) { _, new in new }
        }
        for phase in ["none", "prepared", "send_claimed", "verified", "unknown"] {
            for count in [0, 1_000] {
                var candidate = histogram; candidate["phase"] = phase; candidate["capped"] = count == 1_000
                for key in ["types", "scopes", "composerAttributes"] {
                    let bucket = try XCTUnwrap(candidate[key] as? [String: Int])
                    candidate[key] = bucket.mapValues { _ in count }
                }
                let productText = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(withHistogram(product, candidate)))
                let productValue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(productText.utf8)) as? [String: Any])
                XCTAssertEqual(productValue["productMutationHistogram"] as? NSDictionary, candidate as NSDictionary)
                XCTAssertLessThanOrEqual(productText.utf8.count, 2_048)
                let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(
                    try encode(withHistogram(firstUser, candidate)), provider: .chatgpt))
                XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("PRIVATE_CANARY") })
                let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
                let provenance = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_product_proof" })
                XCTAssertEqual(provenance["productMutationHistogram"] as? NSDictionary, candidate as NSDictionary)
                XCTAssertEqual(provenance["productMutationRelevantCount"] as? Int, 513)
                XCTAssertEqual(values.filter { $0["productMutationHistogram"] != nil }.count, 1,
                    "The histogram remains separate from body/summary records at the existing log bound")
                let body = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_body" })
                XCTAssertEqual(body["expansionContextFailure"] as? String, "product")
            }
        }
        func reject(_ value: Any, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(withHistogram(product, value)), file: file, line: line)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(
                try encode(withHistogram(firstUser, value)), provider: .chatgpt), file: file, line: line)
        }
        for invalid in [NSNull(), [], "PRIVATE_CANARY"] as [Any] { try reject(invalid) }
        for key in histogram.keys {
            var missing = histogram; missing.removeValue(forKey: key); try reject(missing)
        }
        var extra = histogram; extra["pageText"] = "PRIVATE_CANARY"; try reject(extra)
        for (key, invalidValues) in ["version": [true, 0, 2, 1.5, "1", NSNull()],
                                     "phase": [true, 1, "PRIVATE_CANARY", NSNull()],
                                     "capped": [0, 1, "false", NSNull()]] as [String: [Any]] {
            for invalid in invalidValues { var value = histogram; value[key] = invalid; try reject(value) }
        }
        for key in ["types", "scopes", "composerAttributes"] {
            let original = try XCTUnwrap(histogram[key] as? [String: Int])
            for name in original.keys {
                for invalid in [-1, 1_001, 1.5, true, NSNull(), "PRIVATE_CANARY"] as [Any] {
                    var bucket: [String: Any] = original; bucket[name] = invalid
                    var value = histogram; value[key] = bucket; try reject(value)
                }
                var bucket = original; bucket.removeValue(forKey: name)
                var value = histogram; value[key] = bucket; try reject(value)
            }
            for invalid in [NSNull(), [], "PRIVATE_CANARY", original.merging(["PRIVATE_CANARY": 1]) { _, new in new }] as [Any] {
                var value = histogram; value[key] = invalid; try reject(value)
            }
        }
        for key in ["productProofFailure", "productMutationRelevantCount", "productMutationIgnoredCount"] {
            var incompleteProduct = withHistogram(product, histogram); incompleteProduct.removeValue(forKey: key)
            var incompleteFirstUser = withHistogram(firstUser, histogram); incompleteFirstUser.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedProductModeDiagnostic(incompleteProduct))
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(incompleteFirstUser), provider: .chatgpt))
        }
    }

    func testProductMutationRealWebKitProcessesLargeBatchesAndPreservesLateNegatives() async throws {
        for scenario in ["render", "late_work", "label_id"] {
            let page = Self.page.replacingOccurrences(
                of: #"<div id="fixture-composer-mode" role="group" aria-label="Composer mode">"#,
                with: #"<span id="fixture-mode-label">Composer mode</span><div id="fixture-composer-mode" role="group" aria-labelledby="fixture-mode-label">"#)
            let phase = "product_mutation_\(scenario)"
            let fixture = try await fixturePhaseProbe("\(phase)_init", trace: true) { try Fixture(page: page) }
            fixture.traceLifecycle = true
            defer { fixture.shutdown() }
            let started = try await fixturePhaseProbe("\(phase)_start", trace: true) {
                try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            }
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            _ = try await fixturePhaseProbe("\(phase)_ready", trace: true) {
                try await waitForState("ready", fixture.transport, token: token)
            }
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            // Real DOM mutations and native MutationObserver delivery, not an
            // injected record array or writes to the adapter's private proof.
            let rawSample = try await fixturePhaseProbe("\(phase)_mutation", trace: true) { try await evaluate(view, """
                const host = document.createElement('div'); document.body.appendChild(host);
                await new Promise(resolve => setTimeout(resolve, 0));
                const sample = {childList: 0, idRecords: 0, maximumBatch: 0};
                const observer = new MutationObserver(records => {
                  sample.maximumBatch = Math.max(sample.maximumBatch, records.length);
                  sample.childList += records.filter(record => record.type === 'childList').length;
                  sample.idRecords += records.filter(record => record.type === 'attributes' && record.attributeName === 'id').length;
                });
                observer.observe(document, {subtree: true, childList: true, attributes: true,
                  attributeOldValue: true, attributeFilter: ['class', 'id', 'aria-pressed']});
                for (let index = 0; index < 600; index++) host.appendChild(document.createElement('span'));
                for (let index = 0; index < 18; index++) host.className = 'render-' + index;
                if (\(String(reflecting: scenario)) === 'late_work') {
                  const work = document.getElementById('fixture-work-mode');
                  work.setAttribute('aria-pressed', 'true'); work.setAttribute('aria-pressed', 'false');
                }
                if (\(String(reflecting: scenario)) === 'label_id') {
                  const label = document.getElementById('fixture-mode-label');
                  label.id = 'fixture-mode-label-moved'; label.id = 'fixture-mode-label';
                }
                await new Promise(resolve => setTimeout(resolve, 0)); observer.disconnect();
                return sample;
                """) }
            let sample = try XCTUnwrap(rawSample as? [String: Int])
            XCTAssertGreaterThanOrEqual(sample["childList"] ?? 0, 600, scenario)
            XCTAssertGreaterThanOrEqual(sample["maximumBatch"] ?? 0, 618, scenario)
            if scenario == "label_id" { XCTAssertEqual(sample["idRecords"], 2) }
            let rawProof = try await fixturePhaseProbe("\(phase)_proof", trace: true) { try await evaluate(view, """
                const proof = globalThis.__computaChatProductMode;
                return {present: !!proof, invalidated: proof?.invalidated === true,
                  reason: proof?.invalidationReason ?? null};
                """, world: .world(name: "computa-chatgpt-model-v1")) }
            let proof = try XCTUnwrap(rawProof as? [String: Any])
            XCTAssertEqual(proof["present"] as? Bool, true)
            if scenario == "render" {
                XCTAssertEqual(proof["invalidated"] as? Bool, false)
                _ = try await fixturePhaseProbe("\(phase)_send", trace: true) {
                    try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "After bounded structural rendering"])
                }
                _ = try await fixturePhaseProbe("\(phase)_complete", trace: true) {
                    try await waitForState("complete", fixture.transport, token: token)
                }
                let closed = try await fixturePhaseProbe("\(phase)_finish", trace: true) {
                    try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
                }
                XCTAssertEqual(closed["cleanup"] as? String, "not_created")
                try await assertHumanTabIntact(fixture)
            } else {
                XCTAssertEqual(proof["invalidated"] as? Bool, true, scenario)
                XCTAssertEqual(proof["reason"] as? String,
                    scenario == "late_work" ? "work_selected" : "product_history_ambiguous", scenario)
                let sends = try await evaluate(view, "return window.fixturePrompts.length;") as? Int
                XCTAssertEqual(sends, 0)
                // Ready-state Poll is a cached snapshot. Send is the action
                // boundary that must freshly reject the invalidated proof.
                do {
                    _ = try await fixturePhaseProbe("\(phase)_rejected_send", trace: true) {
                        try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                            "prompt": "This local submission must be rejected"])
                    }
                    XCTFail("Historical product uncertainty cannot admit a submission: \(scenario)")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .productModeUnverified) }
                let sendsAfterAttempt = try await evaluate(view, "return window.fixturePrompts.length;") as? Int
                XCTAssertEqual(sendsAfterAttempt, 0, "The rejected action must not click Send")
            }
        }
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
            // A changed product invalidates the prepared submission context
            // after Send; earlier editor phases reject the product proof directly.
            let expectedFailure: EmbeddedWebModelTransport.Failure = actionToCross == "submit"
                ? .ownershipFailure(.javaScriptSubmission) : .productModeUnverified
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never accept a Work response"])
                XCTFail("A stale Chat acknowledgment must be discarded after a native await")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expectedFailure, actionToCross) }
            XCTAssertTrue(crossed)
            let ledger = try await evaluate(view, "return {inputs: window.fixtureInputCount, sends: window.fixturePrompts.length};") as? [String: Int]
            XCTAssertEqual(ledger, ["inputs": actionToCross == "prepare" ? 0 : 1, "sends": actionToCross == "submit" ? 1 : 0])
            do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("A product error is terminal without response acceptance") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expectedFailure, actionToCross) }
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
        let blockedView = try XCTUnwrap(fixture.browser.webView(for: blockedID))
        let untouched = try await evaluate(blockedView, "return globalThis.__computaModelOwner === undefined;", world: .world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(untouched, true)
        try await assertChoiceLedger(blockedView, insertions: 0, sends: 0, selections: 0)
        let cancelled = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
        XCTAssertEqual(cancelled["cleanup"] as? String, "not_created", "Only the exact untouched private checkpoint view is disposed")
        XCTAssertNil(fixture.browser.webView(for: blockedID))
        XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty, "Old disposal cannot re-latch the explicitly recovered gate")
        try await assertHumanTabIntact(fixture)
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
        for (operation, inspectFirst) in [("webProviderFinish", false), ("webProviderCancel", false),
                                          ("webProviderFinish", true), ("webProviderCancel", true)] {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            if inspectFirst {
                do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Expected native checkpoint rejection") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            }
            let untouched = try await evaluate(view, "return globalThis.__computaModelOwner === undefined;",
                                              world: .world(name: "computa-chatgpt-model-v1")) as? Bool
            XCTAssertEqual(untouched, true)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            let finished = try await call(fixture.transport, operation, ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            XCTAssertEqual(finished["state"] as? String, "finished")
            XCTAssertEqual(finished["sequence"] as? Int, 0)
            XCTAssertNil(fixture.browser.webView(for: id), "Only the untouched private checkpoint view is disposed")
            let checkpoint = try XCTUnwrap(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"])
            do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"]); XCTFail("Unbound cleanup still observes a real provider checkpoint") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            do { _ = try await fixture.transport.discoverModels(provider: "gemini"); XCTFail("Disposal cannot clear the checkpoint") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            do { _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never replay"]); XCTFail("Disposed lease must be stale") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .staleSession) }
            XCTAssertEqual(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
            XCTAssertEqual(fixture.createdTabs.count, 1)
            try await assertHumanTabIntact(fixture)
        }
    }

    func testUntouchedChatGPTSignInClosesOnlyExactPrivateViewWithoutAdapterOrSend() async throws {
        let cases = [("https://chatgpt.com/auth/login", "webProviderFinish", true),
                     ("https://chatgpt.com/auth/login", "webProviderCancel", false),
                     ("https://chatgpt.com/login", "webProviderCancel", true),
                     ("https://chatgpt.com/login", "webProviderFinish", false)]
        for (rawURL, operation, inspectFirst) in cases {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), initialURL: URL(string: rawURL))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last), view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            XCTAssertEqual(fixture.browser.modelNavigationDiagnostic(tabID: id, view: view)?.settled, true)
            if inspectFirst {
                do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Sign-in is terminal before provider JavaScript") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
            }
            let untouched = try await evaluate(view, "return globalThis.__computaModelOwner === undefined;",
                                              world: .world(name: "computa-chatgpt-model-v1")) as? Bool
            XCTAssertEqual(untouched, true)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            let closed = try await call(fixture.transport, operation, ["sessionToken": token])
            XCTAssertEqual(closed["state"] as? String, "finished")
            XCTAssertEqual(closed["cleanup"] as? String, "not_created")
            XCTAssertEqual(closed["sequence"] as? Int, 0)
            XCTAssertNil(fixture.browser.webView(for: id))
            XCTAssertFalse(fixture.browser.tabs.contains { $0.id == id })
            // A repeated Finish/Cancel may return its cached closed receipt;
            // it must never create another view or revive the signed-out lease.
            let repeated = try await call(fixture.transport, operation, ["sessionToken": token])
            XCTAssertEqual(repeated["cleanup"] as? String, "not_created")
            do { _ = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"]); XCTFail("Disposal does not clear sign-in admission") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
            XCTAssertEqual(fixture.createdTabs.count, 1)
            XCTAssertTrue(fixture.browser.savedHumanVerificationProviders.isEmpty)
            try await assertHumanTabIntact(fixture)
        }
    }

    func testUntouchedChatGPTSignInRejectsChangedDocumentURLClosedViewAndAdapterDispatch() async throws {
        for change in ["same_url_new_document", "same_document_new_url", "closed_view", "adapter_dispatched"] {
            let authURL = try XCTUnwrap(URL(string: "https://chatgpt.com/auth/login"))
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), initialURL: authURL)
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last), view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Expected sign-in") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
            let generation = fixture.browser.documentGeneration(for: id)
            if change == "same_url_new_document" {
                view.loadHTMLString(Self.modelChoicePage(.chatgpt).replacingOccurrences(of: "'initial'", with: "'replacement'"), baseURL: authURL)
                try await waitForFixture(view, generation: "replacement")
                XCTAssertNotEqual(fixture.browser.documentGeneration(for: id), generation)
            } else if change == "same_document_new_url" {
                _ = try await evaluate(view, "history.replaceState(null, '', '/auth/login?changed=1'); return true;")
                XCTAssertNotEqual(view.url, authURL)
                XCTAssertEqual(fixture.browser.documentGeneration(for: id), generation)
            } else if change == "closed_view" {
                fixture.browser.closeTab(id)
            } else {
                // Existing negative-only hook can revoke eligibility; it cannot
                // manufacture a dispatch acknowledgement or cleanup authority.
                fixture.transport.invalidateGeminiPostBlockEligibilityForTesting(sessionToken: token, submitted: false, adapterDispatched: true)
            }
            let closed = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(closed["cleanup"] as? String, "failed")
            if change != "closed_view" { XCTAssertTrue(fixture.browser.webView(for: id) === view) }
            try await assertHumanTabIntact(fixture, retaining: change == "closed_view" ? nil : id)
        }
    }

    func testUntouchedChatGPTSignInDoesNotAuthorizeExternalUnknownOrLookalikeRoutes() async throws {
        for rawURL in ["https://accounts.google.com/v3/signin/identifier", "https://unexpected.example.test/auth/login",
                       "https://chatgpt.com/authentication", "https://chatgpt.com.evil.test/auth/login"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), initialURL: URL(string: rawURL))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last), view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            let closed = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(closed["cleanup"] as? String, "failed")
            XCTAssertTrue(fixture.browser.webView(for: id) === view)
            let untouched = try await evaluate(view, "return globalThis.__computaModelOwner === undefined;",
                                              world: .world(name: "computa-chatgpt-model-v1")) as? Bool
            XCTAssertEqual(untouched, true)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            try await assertHumanTabIntact(fixture, retaining: id)
        }
    }

    func testChatGPTSignInAfterProviderReadOrSendCannotClaimUntouchedDisposal() async throws {
        for sendFirst in [false, true] {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last), view = try XCTUnwrap(fixture.browser.webView(for: id))
            _ = try await waitForState("ready", fixture.transport, token: token)
            if sendFirst {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Synthetic pre-sign-in submission"])
            }
            try await assertChoiceLedger(view, insertions: sendFirst ? 1 : 0, sends: sendFirst ? 1 : 0, selections: 1)
            view.loadHTMLString(Self.modelChoicePage(.chatgpt).replacingOccurrences(of: "'initial'", with: "'signin'"),
                                baseURL: URL(string: "https://chatgpt.com/auth/login"))
            try await waitForFixture(view, generation: "signin")
            let closed = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(closed["cleanup"] as? String, "failed")
            XCTAssertEqual(closed["sequence"] as? Int, sendFirst ? 1 : 0)
            XCTAssertTrue(fixture.browser.webView(for: id) === view)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            try await assertHumanTabIntact(fixture, retaining: id)
        }
    }

    func testUntouchedCheckpointDisposalRejectsChangedDocumentURLAndClosedView() async throws {
        for change in ["same_url_new_document", "different_checkpoint", "closed_view"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: "https://google.com/sorry/"))
            defer { fixture.shutdown() }
            let start = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(start["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Expected checkpoint") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            let capturedGeneration = fixture.browser.documentGeneration(for: id)
            let checkpoint = fixture.browser.savedHumanVerificationCheckpointIDs["gemini"]
            if change == "closed_view" {
                fixture.browser.closeTab(id)
            } else {
                let url = change == "different_checkpoint" ? "https://www.google.com/sorry/index" : "https://google.com/sorry/"
                view.loadHTMLString(Self.modelChoicePage(.gemini).replacingOccurrences(of: "'initial'", with: "'replacement'"),
                                    baseURL: URL(string: url))
                try await waitForFixture(view, generation: "replacement")
                XCTAssertNotEqual(fixture.browser.documentGeneration(for: id), capturedGeneration)
                try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            }
            let finished = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertEqual(finished["state"] as? String, "failed")
            XCTAssertEqual(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
            XCTAssertEqual(fixture.createdTabs.count, 1)
            try await assertHumanTabIntact(fixture, retaining: change == "closed_view" ? nil : id)
        }
    }

    func testUntouchedNonCheckpointDisposalDoesNotGainForeignPageAuthority() async throws {
        for url in ["https://accounts.google.com/v3/signin/identifier", "https://unexpected.example.test/checkpoint",
                    "https://google.com/sorry-about", "https://google.com.evil.test/sorry/"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini), initialURL: URL(string: url))
            defer { fixture.shutdown() }
            let start = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(start["sessionToken"] as? String)
            let id = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: id))
            try await waitForFixture(view)
            let finished = try await call(fixture.transport, "webProviderCancel", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            let untouched = try await evaluate(view, "return globalThis.__computaModelOwner === undefined;",
                                              world: .world(name: "computa-chatgpt-model-v1")) as? Bool
            XCTAssertEqual(untouched, true)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
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
        let blockedID = try XCTUnwrap(first.createdTabs.last)
        let blockedView = try XCTUnwrap(first.browser.webView(for: blockedID))
        try await waitForFixture(blockedView)
        let untouched = try await evaluate(blockedView, "return globalThis.__computaModelOwner === undefined;", world: .world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(untouched, true)
        try await assertChoiceLedger(blockedView, insertions: 0, sends: 0, selections: 0)
        let finished = try await call(first.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(first.browser.webView(for: blockedID))
        try await assertHumanTabIntact(first)
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

    func testAutomaticRecoveryValidatorRejectsBeforeCreatingAProbe() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
        defer { fixture.shutdown() }
        fixture.browser.recordHumanVerificationRequired(provider: "gemini")
        let checkpoint = fixture.browser.savedHumanVerificationCheckpointIDs["gemini"]
        do {
            _ = try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true,
                recoveryCandidateIsCurrent: { false })
            XCTFail("A revoked human candidate cannot create a provider page")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.createdTabs.isEmpty)
        XCTAssertEqual(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        try await assertHumanTabIntact(fixture)
    }

    func testAutomaticRecoveryValidatorRunsAfterConfirmedDisposalAndCannotClearOnRevocationOrCancellation() async throws {
        for cancelled in [false, true] {
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini))
            defer { fixture.shutdown() }
            fixture.browser.recordHumanVerificationRequired(provider: "gemini")
            let checkpoint = fixture.browser.savedHumanVerificationCheckpointIDs["gemini"]
            var checks = 0
            var probeView: WKWebView?
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "discoverModels" { probeView = fixture.createdTabs.last.flatMap { fixture.browser.webView(for: $0) } }
            }
            var task: Task<[WebsiteModelChoice], Error>!
            task = Task { @MainActor in
                try await fixture.transport.discoverModels(provider: "gemini", retryBlocked: true,
                    recoveryCandidateIsCurrent: {
                        checks += 1
                        if checks == 1 { return true }
                        XCTAssertNil(fixture.browser.webView(for: fixture.createdTabs.last!), "The final validator must run after owned probe disposal")
                        if cancelled { task.cancel(); return true }
                        return false
                    })
            }
            do { _ = try await task.value; XCTFail("Late revocation/cancellation must retain the checkpoint") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(checks, 2)
            XCTAssertEqual(fixture.createdTabs.count, 1)
            XCTAssertEqual(fixture.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
            try await assertChoiceLedger(XCTUnwrap(probeView), insertions: 0, sends: 0, selections: 0)
            do { _ = try await fixture.transport.discoverModels(provider: "gemini"); XCTFail("Ordinary discovery remains blocked") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
            XCTAssertEqual(fixture.createdTabs.count, 1)
        }
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
        let chatChoices = WebsiteModelChoice.ChatGPTPower.allCases.map {
            WebsiteModelChoice(provider: "chatgpt", key: $0.modelKey, label: $0.label)
        }
        let choices = chatChoices + Self.choiceProviders.filter { $0 != .chatgpt }.map(Self.fixtureChoice)
        for choice in choices {
            let provider = try XCTUnwrap(EmbeddedWebModelTransport.Provider(rawValue: choice.provider))
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
            let expectedPowerEvents = choice.chatGPTPower.flatMap { WebsiteModelChoice.ChatGPTPower.allCases.firstIndex(of: $0) }
            if let expectedPowerEvents {
                try await assertChatPowerControl(view, index: expectedPowerEvents, events: expectedPowerEvents)
                try await assertChatClosedPowerAndRememberedFamily(view, power: choice.label)
            }
            var powerOpensBeforeSends: Int?, familyOpensBeforeSends: Int?
            if choice.chatGPTPower != nil {
                powerOpensBeforeSends = try await evaluate(view, "return window.fixtureModelPowerOpenCount;") as? Int
                familyOpensBeforeSends = try await evaluate(view, "return window.fixtureModelFamilyOpenCount;") as? Int
            }
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            for sequence in 1...2 {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Synthetic model choice inference \(sequence)"])
                XCTAssertEqual(sent["state"] as? String, "running")
                try assertRunningOrVerifiedChoice(sent, choice: choice)
                let complete = try await waitForState("complete", fixture.transport, token: token)
                XCTAssertEqual(complete["sequence"] as? Int, sequence)
                XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
                try assertChoiceEvidence(complete, choice: choice)
                try await assertChoiceLedger(view, insertions: sequence, sends: sequence, selections: 1)
                if let expectedPowerEvents {
                    try await assertChatPowerControl(view, index: expectedPowerEvents, events: expectedPowerEvents)
                    try await assertChatClosedPowerAndRememberedFamily(view, power: choice.label)
                    let powerOpens = try await evaluate(view, "return window.fixtureModelPowerOpenCount;") as? Int
                    let familyOpens = try await evaluate(view, "return window.fixtureModelFamilyOpenCount;") as? Int
                    XCTAssertEqual(powerOpens, powerOpensBeforeSends, "A remembered Family read must not require or reopen the inactive Power view")
                    XCTAssertGreaterThan(try XCTUnwrap(familyOpens), try XCTUnwrap(familyOpensBeforeSends))
                }
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

    func testClosedChatGPTPowerHeaderWithRememberedFamilyVerifiesTwoSendsWithoutSelfWakingOrReplayingSelection() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, genericHeader: true,
            unmountClosedMenu: true, holdSecondReply: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        let ready = try await waitForState("ready", fixture.transport, token: token)
        try assertChoiceEvidence(ready, choice: choice)
        XCTAssertEqual(try WebsiteModelEvidence.parse(ready["modelEvidence"], provider: "chatgpt", expected: choice).source,
            "selected_model_indicator")
        let closedPower = try await evaluate(view, "return document.getElementById('fixture-model-header').textContent;") as? String
        XCTAssertEqual(closedPower, "Medium", "The closed trigger proves power only; active checked Family rows must still prove family")
        let initiallyUnmounted = try await evaluate(view, "return document.getElementById('fixture-model-menu') === null;") as? Bool
        XCTAssertEqual(initiallyUnmounted, true)

        for sequence in 1...2 {
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Generic-header inference \(sequence)"])
            XCTAssertEqual(sent["state"] as? String, "running")
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            if sequence == 2 {
                // A genuine composer update can arrive after the old 100 ms
                // baseline, followed by the native 100 ms burst batch. Observe
                // that late event before testing read-only picker operations.
                let delayedComposerUpdate = Task { @MainActor in
                    try await Task.sleep(for: .milliseconds(180))
                    return try await evaluate(view, "const send = document.querySelector('[data-testid=\"send-button\"]'); if (!send) return false; send.setAttribute('aria-busy', 'false'); return true;") as? Bool
                }
                try await Task.sleep(for: .milliseconds(100))
                let observedEarlyRevision = try await fixture.transport.changeRevision(sessionToken: token)
                let earlyRevision = try XCTUnwrap(observedEarlyRevision)
                let updated = try await delayedComposerUpdate.value
                XCTAssertEqual(updated, true)
                let revision = try await waitForQuietRevision(fixture.transport, token: token)
                XCTAssertGreaterThan(revision, earlyRevision, "The old fixed-delay baseline precedes a genuine delayed notification")
                let triggerBefore = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
                for _ in 0..<3 {
                    let observed = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTAssertEqual(observed["state"] as? String, "running")
                    try assertRunningOrVerifiedChoice(observed, choice: choice)
                    let after = try await waitForQuietRevision(fixture.transport, token: token)
                    XCTAssertEqual(after, revision, "Deferred observations must not create a native DOM wake loop")
                    let closed = try await evaluate(view, "return document.getElementById('fixture-model-menu') === null;") as? Bool
                    XCTAssertEqual(closed, true)
                }
                let triggerAfter = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
                XCTAssertEqual(try XCTUnwrap(triggerAfter), try XCTUnwrap(triggerBefore), "Running polls must leave the model picker closed")
                let released = try await evaluate(view, "const stop = document.getElementById('fixture-held-response-stop'); if (!stop) return false; stop.remove(); return true;") as? Bool
                XCTAssertEqual(released, true, "Completion is released only after the running-state observations")
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

        // Change actual checked radios synchronously during the next owned
        // picker close. This measures the real active suppression scope without
        // relying on separate native calls fitting inside its 300 ms window.
        try await Task.sleep(for: .milliseconds(50))
        let observedBeforeDrift = try await fixture.transport.changeRevision(sessionToken: token)
        let beforeDrift = try XCTUnwrap(observedBeforeDrift)
        let armed = try await evaluate(view, """
            globalThis.fixtureCheckedDrift = null;
            const mutateDuringClose = event => {
              const menu = document.getElementById('fixture-model-menu');
              if (event.key !== 'Escape' || !menu?.isConnected) return;
              document.removeEventListener('keydown', mutateDuringClose, true);
              const scope = globalThis.__computaModelReadUI;
              const checked = () => [...menu.querySelectorAll('[data-fixture-model][aria-checked="true"]')].map(node => node.dataset.fixtureModel);
              const result = {connected: menu.isConnected, before: checked(),
                suppressionActive: scope?.until > Date.now(),
                tracked: scope?.roots.includes(menu) === true};
              menu.querySelectorAll('[data-fixture-model]').forEach(node => node.setAttribute('aria-checked', String(node.dataset.fixtureModel === \(String(reflecting: Self.choiceLabels(.chatgpt)[1])))));
              result.checked = checked();
              result.suppressionStillActive = scope?.until > Date.now();
              globalThis.fixtureCheckedDrift = result;
            };
            document.addEventListener('keydown', mutateDuringClose, true);
            return true;
            """, world: .world(name: "computa-chatgpt-model-v1")) as? Bool
        XCTAssertEqual(armed, true)
        // A completed poll may use the cached result. The attempted next send
        // must perform a fresh picker read and reject drift before insertion.
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not replay selection or submit after drift"])
            XCTFail("A freshly read checked-family mismatch must reject another send")
        }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
        let changed = try await evaluate(view, "return globalThis.fixtureCheckedDrift;",
            world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
        XCTAssertEqual(changed?["connected"] as? Bool, true, "The model attributes must belong to the observed document")
        XCTAssertEqual(changed?["before"] as? [String], ["GPT-6"])
        XCTAssertEqual(changed?["tracked"] as? Bool, true)
        XCTAssertEqual(changed?["suppressionActive"] as? Bool, true)
        XCTAssertEqual(changed?["suppressionStillActive"] as? Bool, true)
        XCTAssertEqual(changed?["checked"] as? [String], [Self.choiceLabels(.chatgpt)[1]])
        let woke = try await fixture.transport.waitForChange(sessionToken: token, after: beforeDrift, until: .now + .seconds(2))
        XCTAssertGreaterThan(try XCTUnwrap(woke), beforeDrift, "An aria-checked model change must wake the native reader")
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

    func testChatGPTReadOnlyCloseRequiresEnabledClosedTriggerAndWaitsForActualAcknowledgment() async throws {
        for closure in ["disabled", "open", "delayed"] {
            let choice = Self.fixtureChoice(.chatgpt)
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, unmountClosedMenu: true))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await evaluate(view, """
                window.fixtureClosureDriftArmed = true;
                window.fixtureClosureTransitions = 0; window.fixtureClosureAcknowledgments = 0;
                window.fixtureClosurePendingInputs = null; window.fixtureClosurePendingSends = null;
                document.addEventListener('keydown', event => {
                  const trigger = document.getElementById('fixture-model-trigger');
                  if (event.key !== 'Escape' || !window.fixtureClosureDriftArmed
                    || trigger.getAttribute('aria-expanded') !== 'false') return;
                  window.fixtureClosureDriftArmed = false; window.fixtureClosureTransitions++;
                  window.fixtureClosurePendingInputs = window.fixtureInputCount;
                  window.fixtureClosurePendingSends = window.fixturePrompts.length;
                  trigger.disabled = '\(closure)' !== 'open';
                  trigger.setAttribute('data-state', '\(closure)' === 'disabled' ? 'closed' : 'open');
                  if ('\(closure)' === 'delayed') setTimeout(() => {
                    trigger.disabled = false; trigger.setAttribute('data-state', 'closed');
                    window.fixtureClosureAcknowledgments++;
                  }, 80);
                });
                return true;
                """)
            if closure == "delayed" {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "Send only after the same trigger acknowledges closed state"])
                try assertRunningOrVerifiedChoice(sent, choice: choice)
                let complete = try await waitForState("complete", fixture.transport, token: token)
                try assertChoiceEvidence(complete, choice: choice)
                XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
                try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            } else {
                do {
                    _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                        "prompt": "Must not send through an unsettled model trigger"])
                    XCTFail("An absent popup cannot admit a \(closure) trigger")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnverified) }
                try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            }
            let acknowledgment = try await evaluate(view, """
                return {transitions: window.fixtureClosureTransitions, acknowledgments: window.fixtureClosureAcknowledgments,
                  pendingInputs: window.fixtureClosurePendingInputs, pendingSends: window.fixtureClosurePendingSends};
                """) as? [String: Int]
            XCTAssertEqual(acknowledgment?["transitions"], 1, "A failed closure cannot replay its dismissal")
            XCTAssertEqual(acknowledgment?["acknowledgments"], closure == "delayed" ? 1 : 0)
            XCTAssertEqual(acknowledgment?["pendingInputs"], 0)
            XCTAssertEqual(acknowledgment?["pendingSends"], 0)
            _ = try await evaluate(view, "const trigger = document.getElementById('fixture-model-trigger'); trigger.disabled = false; trigger.setAttribute('data-state','closed'); return true;")
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
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
            "selected_model_indicator")
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
            try assertRunningOrVerifiedChoice(sent, choice: choice)
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
        let choice = Self.fixtureChoice(.chatgpt)
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
        let ready = try await waitForState("ready", fixture.transport, token: token)
        // The adapter now awaits family/power proof within one native call.
        // Record the actual intermediate DOM at the site's family click,
        // before Escape acknowledges the associated returned parent closure.
        let parentObservations = try await evaluate(view, "return window.fixtureModelParentObservations;")
        let parents = try XCTUnwrap(parentObservations as? [[String: Any]])
        XCTAssertEqual(parents.count, 1)
        let parent = try XCTUnwrap(parents.first)
        XCTAssertEqual(parent["active"] as? Bool, true)
        XCTAssertEqual(parent["connected"] as? Bool, true)
        XCTAssertEqual(parent["expanded"] as? Bool, true)
        XCTAssertEqual(parent["checked"] as? String, "GPT-6")
        XCTAssertEqual(parent["checkedHidden"] as? Bool, true, "Hidden checked rows cannot prove the current model")
        XCTAssertEqual(parent["temporaryHidden"] as? Bool, true, "The exact modal temporarily hides the mode controls")
        XCTAssertEqual(parent["users"] as? Int, 0)
        XCTAssertEqual(parent["assistants"] as? Int, 0)
        XCTAssertEqual(parent["inputs"] as? Int, 0)
        XCTAssertEqual(parent["sends"] as? Int, 0)
        try assertChoiceEvidence(ready, choice: choice)
        XCTAssertEqual(try WebsiteModelEvidence.parse(ready["modelEvidence"], provider: "chatgpt", expected: choice).source,
            "selected_model_indicator")
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
            try assertRunningOrVerifiedChoice(sent, choice: choice)
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
        let choice = Self.fixtureChoice(.chatgpt)
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
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, genericHeader: true,
            unmountClosedMenu: true, returnToParentAfterSelection: true, hideComposerInPicker: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        let ready = try await waitForState("ready", fixture.transport, token: token)
        let modalObservations = try await evaluate(view, "return window.fixtureModelParentObservations;")
        let modals = try XCTUnwrap(modalObservations as? [[String: Any]])
        XCTAssertEqual(modals.count, 1)
        let modal = try XCTUnwrap(modals.first)
        XCTAssertEqual(modal["active"] as? Bool, true, "The owned selection really returned to its modal")
        XCTAssertEqual(modal["composerHidden"] as? Bool, true, "The pending owned selection really crosses an unavailable composer")
        XCTAssertEqual(modal["temporaryHidden"] as? Bool, true)
        XCTAssertEqual(modal["inputs"] as? Int, 0)
        XCTAssertEqual(modal["sends"] as? Int, 0)
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
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["sequence"] as? Int, 1)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        try assertChoiceEvidence(complete, choice: choice)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testOptimisticChatGPTFirstAndRetainedBodiesWaitForDurableFreshProofWithoutResending() async throws {
        let fixture = try Fixture(page: Self.optimisticTemporarySubmissionPage())
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await fixturePhaseProbe("optimistic_start") { try await startChoice(choice, in: fixture) }
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        _ = try await fixturePhaseProbe("optimistic_ready") { try await waitForState("ready", fixture.transport, token: token) }
        let generation = fixture.browser.documentGeneration(for: ownedID)
        var firstPin: String?
        for round in 1...2 {
            let prompt = String(repeating: "Round \(round) exact optimistic then durable body.\n", count: 360)
            // The fixture inserts the real optimistic SPAN synchronously in
            // Send, including the pre-acknowledgment product recheck window.
            let sent = try await fixturePhaseProbe("optimistic_send") { try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt]) }
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            let pending = try await fixturePhaseProbe("optimistic_pending_poll") { try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]) }
            try assertRunningOrVerifiedChoice(pending, choice: choice)
            let context = try XCTUnwrap(pending["pendingSubmissionContext"] as? [String: Any])
            XCTAssertEqual(context["sequence"] as? Int, round)
            XCTAssertEqual(context["submittedPromptFingerprint"] as? String, "")
            XCTAssertEqual(context["firstUserFingerprint"] as? String, firstPin ?? "")
            let privateState = try await evaluate(view, """
                const state=globalThis.__computaChatSubmissionState;
                return {phase:state?.pending?.phase, sequence:state?.pending?.sequence,
                  lastVerified:state?.lastVerified?.sequence || 0, firstBound:!!globalThis.__computaModelFirstProof?.fingerprint};
                """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
            XCTAssertEqual(privateState?["phase"] as? String, "send_claimed")
            XCTAssertEqual(privateState?["sequence"] as? Int, round)
            XCTAssertEqual(privateState?["lastVerified"] as? Int, round - 1)
            XCTAssertEqual(privateState?["firstBound"] as? Bool, round > 1)
            try await assertChoiceLedger(view, insertions: round, sends: round, selections: 1)
            _ = try await evaluate(view, "document.dispatchEvent(new Event('fixture-commit-durable-user')); return true;")
            let complete = try await fixturePhaseProbe("optimistic_complete") { try await waitForState("complete", fixture.transport, token: token) }
            try assertChoiceEvidence(complete, choice: choice)
            let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            XCTAssertEqual(proof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(prompt))
            XCTAssertEqual(proof["sequence"] as? Int, round)
            if round == 1 {
                firstPin = try XCTUnwrap(proof["firstUserFingerprint"] as? String)
                XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
            } else { XCTAssertEqual(proof["firstUserFingerprint"] as? String, firstPin) }
            try await assertChoiceLedger(view, insertions: round, sends: round, selections: 1)
        }
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        XCTAssertEqual(fixture.createdTabs.count, 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testOptimisticChatGPTPendingDoesNotRenewDeadlineOrAdmitChangedDurableBody() async throws {
        for expires in [false, true] {
            let fixture = try Fixture(page: Self.optimisticTemporarySubmissionPage())
            defer { fixture.shutdown() }
            let started = try await fixturePhaseProbe("optimistic_start") { try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture) }
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            _ = try await fixturePhaseProbe("optimistic_ready") { try await waitForState("ready", fixture.transport, token: token) }
            _ = try await fixturePhaseProbe("optimistic_send") { try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": String(repeating: "Keep the complete exact request.\n", count: 400)]) }
            let pending = try await fixturePhaseProbe("optimistic_pending_poll") { try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]) }
            try assertRunningOrVerifiedChoice(pending, choice: Self.fixtureChoice(.chatgpt))
            if expires {
                fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1))
            } else {
                _ = try await evaluate(view, """
                    document.dispatchEvent(new Event('fixture-commit-durable-user'));
                    const body=document.querySelector('[data-user-message-bubble="true"] .whitespace-pre-wrap');
                    body.textContent=body.textContent.replace('Keep','Changed'); return true;
                    """)
            }
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A pending observation cannot authorize expired or changed response proof")
            } catch {
                let failure = try XCTUnwrap(error as? EmbeddedWebModelTransport.Failure)
                if expires { XCTAssertEqual(failure, .deadline) }
                else { XCTAssertTrue(failure == .ownershipFailure(.javaScriptFirstUser) || failure == .ownershipFailure(.javaScriptSubmission)) }
            }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            try await assertHumanTabIntact(fixture, retaining: ownedID)
        }
    }

    func testOptimisticChatGPTPreAcknowledgmentProductReadPreservesScopeAcrossRoutePromotion() async throws {
        let fixture = try Fixture(page: Self.optimisticTemporarySubmissionPage())
        defer { fixture.transport.setBeforePageResultValidationDetailedForTesting(nil); fixture.shutdown() }
        let started = try await fixturePhaseProbe("optimistic_start") { try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture) }
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        _ = try await fixturePhaseProbe("optimistic_ready") { try await waitForState("ready", fixture.transport, token: token) }
        let routes = ["/c/local-chatgpt%3Aoptimistic-product?temporary-chat=true", "/c/optimistic-product-public?temporary-chat=true"]
        var crossed = 0
        fixture.transport.setBeforePageResultValidationDetailedForTesting { action, enforceModel in
            guard action == "verifyProductMode", !enforceModel, crossed < routes.count else { return }
            let facts = try? await self.evaluate(view, """
                const state=globalThis.__computaChatSubmissionState;
                return state?.pending?.phase==='send_claimed' && state.pending.sequence===1
                  && !globalThis.__computaModelFirstProof
                  && document.querySelector('[data-user-message-bubble="true"]')?.lastElementChild?.tagName==='SPAN';
                """, world: .world(name: "computa-chatgpt-model-v1"))
            guard facts as? Bool == true else { return }
            let route = routes[crossed]; crossed += 1
            _ = try? await self.evaluate(view, "history.pushState({}, '', \(String(reflecting: route))); return true;")
        }
        _ = try await fixturePhaseProbe("optimistic_send") { try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": String(repeating: "Preserve the product-only route read.\n", count: 400)]) }
        XCTAssertEqual(crossed, 2)
        fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
        let pending = try await fixturePhaseProbe("optimistic_pending_poll") { try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]) }
        try assertRunningOrVerifiedChoice(pending, choice: Self.fixtureChoice(.chatgpt))
        let pendingContext = try XCTUnwrap(pending["pendingSubmissionContext"] as? [String: Any])
        XCTAssertEqual(pendingContext["firstUserFingerprint"] as? String, "")
        XCTAssertEqual(pendingContext["submittedPromptFingerprint"] as? String, "")
        _ = try await evaluate(view, "document.dispatchEvent(new Event('fixture-commit-durable-user')); return true;")
        let complete = try await fixturePhaseProbe("optimistic_complete") { try await waitForState("complete", fixture.transport, token: token) }
        try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testTemporaryUserOutlineSurvivesFirstExpansionAndRetainedSecondSend() async throws {
        let fixture = try Fixture(page: Self.temporaryOutlineFirstUserPage())
        defer { fixture.transport.setBeforePageResultValidationForTesting(nil); fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        var sawClippedOutline = false, firstFingerprint: String?
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "submit", !sawClippedOutline else { return }
            let clipped = try? await self.evaluate(view, """
                const bubble = document.querySelector('[data-user-message-bubble="true"]');
                return !!bubble?.querySelector(':scope > svg.temporaryOutline-bbkcxS')
                  && bubble.querySelector('.whitespace-pre-wrap').innerText.length === 10240
                  && !document.querySelector('[aria-label="Turn off temporary chat"], #fixture-composer-mode');
                """)
            XCTAssertEqual(clipped as? Bool, true); sawClippedOutline = clipped as? Bool == true
        }
        for round in 1...2 {
            let prompt = round == 1 ? String(repeating: "Owned dashed-outline fixture line.\n", count: 600)
                : "Retain the exact full first body through the second owned submission"
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            let complete = try await waitForState("complete", fixture.transport, token: token)
            try assertChoiceEvidence(complete, choice: choice)
            let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            let fingerprint = try XCTUnwrap(proof["firstUserFingerprint"] as? String)
            XCTAssertEqual(fingerprint.count, 64); XCTAssertEqual(complete["sequence"] as? Int, round)
            if round == 1 { firstFingerprint = fingerprint } else { XCTAssertEqual(fingerprint, firstFingerprint) }
            let full = try await evaluate(view, """
                return document.querySelector('[data-user-message-bubble="true"] .whitespace-pre-wrap').innerText === window.fixturePrompts[0]
                  && window.fixtureExpansionClicks === 1;
                """)
            XCTAssertEqual(full as? Bool, true)
            try await assertChoiceLedger(view, insertions: round, sends: round, selections: 1)
        }
        XCTAssertTrue(sawClippedOutline)
        XCTAssertEqual(fixture.createdTabs.count, 1); XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testTemporaryUserOutlineRejectsUnownedMalformedAndNonTemporaryVariants() async throws {
        for variant in ["url_only", "duplicate", "nested_body", "assistant", "code", "interactive", "malformed",
                        "fake_class", "hidden", "inert", "opacity", "queryless", "duplicate_query", "ackless", "pin_drift", "normal_chat"] {
            let fixture = try Fixture(page: Self.temporaryOutlineFirstUserPage(variant: variant))
            defer { fixture.transport.setBeforePageResultValidationForTesting(nil); fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            var changedPin = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "submit", !changedPin, ["ackless", "pin_drift", "normal_chat"].contains(variant) else { return }
                changedPin = true
                let changed = try? await self.evaluate(view, """
                    const variant = \(String(reflecting: variant));
                    const proof = globalThis.__computaChatProductMode, pending = globalThis.__computaChatSubmissionState?.pending;
                    if (!proof || !pending) return false;
                    if (variant === 'pin_drift') pending.fingerprint = '0'.repeat(64);
                    else proof.temporaryAcknowledged = false;
                    if (variant === 'normal_chat') {
                      proof.temporaryRequested = false;
                      const group = document.createElement('div'); group.id = 'fixture-composer-mode';
                      group.setAttribute('role','group'); group.setAttribute('aria-label','Composer mode');
                      group.innerHTML = '<button aria-pressed="true">Chat</button><button aria-pressed="false">Work</button>';
                      document.body.prepend(group);
                    } return true;
                    """, world: .world(name: "computa-chatgpt-model-v1"))
                XCTAssertEqual(changed as? Bool, true, variant)
            }
            var rejected = false
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": String(repeating: "Reject an unproven dashed-outline fixture line.\n", count: 600)])
                _ = try await waitForState("complete", fixture.transport, token: token)
            } catch {
                rejected = true
                switch error as? EmbeddedWebModelTransport.Failure {
                case .some(.ownershipFailure(_)), .some(.productModeUnverified), .some(.temporaryUnverified), .some(.modelUnverified): break
                case .some(.documentChanged) where ["queryless", "duplicate_query"].contains(variant): break
                default: XCTFail("Expected a finite proof rejection for \(variant), got \(error)")
                }
            }
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertTrue(rejected, variant)
            XCTAssertEqual(changedPin, ["ackless", "pin_drift", "normal_chat"].contains(variant), variant)
            let expansions = try await evaluate(view, "return window.fixtureExpansionClicks || 0;") as? Int
            XCTAssertEqual(expansions, 0, variant)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        }
    }

    func testCollapsedOwnedFirstMessageExpandsDuringInspectWithoutRepeatingSendOrCreatingTab() async throws {
        let fixture = try Fixture(page: Self.collapsedFirstUserPage())
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        var expansionObservedIn: String?
        var expansionDiagnostics: [String] = []
        fixture.transport.setFirstUserDiagnosticsObserverForTesting { expansionDiagnostics += $0 }
        fixture.transport.setBeforePageResultValidationDetailedForTesting { action, enforceModel in
            let clicks = try? await self.evaluate(view, "return window.fixtureExpansionClicks || 0;") as? Int
            if clicks == 1, expansionObservedIn == nil {
                expansionObservedIn = action
                XCTAssertEqual(action, "inspect")
                XCTAssertTrue(enforceModel, "Only the acknowledged outer inspection may claim the first body expansion")
            }
        }
        defer {
            fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
            fixture.transport.setFirstUserDiagnosticsObserverForTesting(nil)
        }
        let prompt = String(repeating: "Owned fixture payload line.\n", count: 600)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
        XCTAssertEqual(sent["state"] as? String, "running")
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(expansionObservedIn, "inspect")
        XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
        let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
        let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
        XCTAssertEqual(clicks, 1)
        let diagnosticValues = expansionDiagnostics.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertTrue(diagnosticValues.contains { $0["expansionOutcome"] as? String == "expanded" })
        XCTAssertEqual(fixture.createdTabs.count, 1)
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testCollapsedFirstMessageHeaderRemountRequiresFreshExactModelProof() async throws {
        for condition in ["unchanged", "promoted_route", "connected_old", "wrong_power", "wrong_family", "prior_header_drift"] {
            let page = Self.collapsedFirstUserPage().replacingOccurrences(
                of: "const modelTrigger = document.getElementById('fixture-model-trigger');",
                with: "let modelTrigger = document.getElementById('fixture-model-trigger');")
            let fixture = try Fixture(page: page)
            defer { fixture.shutdown() }
            let choice = Self.fixtureChoice(.chatgpt)
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            var applied = false
            fixture.transport.setBeforePageResultValidationDetailedForTesting { action, _ in
                guard action == "submit", !applied else { return }
                applied = true
                let observation = try? await self.evaluate(view, """
                    const condition = \(String(reflecting: condition));
                    const old = document.getElementById('fixture-model-trigger');
                    if (window.fixturePrompts.length !== 1 || !old || old.getAttribute('aria-expanded') !== 'false') return null;
                    if (condition === 'prior_header_drift') {
                      old.querySelector('#fixture-model-header').firstChild.data = 'High';
                      old.querySelector('#fixture-model-header').firstChild.data = 'Medium';
                      await Promise.resolve();
                    }
                    const replacement = old.cloneNode(true);
                    if (condition === 'connected_old') {
                      old.id = 'fixture-connected-old-model-trigger'; old.hidden = true;
                      old.after(replacement);
                    } else old.replaceWith(replacement);
                    // The provider remounts its click handler on the new physical
                    // node; keep the same fixture behavior and observable ledger.
                    modelTrigger = replacement;
                    replacement.addEventListener('click', () => old.click());
                    if (condition === 'wrong_power') replacement.querySelector('#fixture-model-header').textContent = 'High';
                    if (condition === 'wrong_family') modelMenu.querySelectorAll('[data-fixture-model]').forEach(node =>
                      node.setAttribute('aria-checked', String(node.dataset.fixtureModel === 'GPT-5.5')));
                    if (condition === 'promoted_route') history.pushState({}, '', '/c/local-chatgpt%3Aremount-fixture?temporary-chat=true');
                    window.fixtureRemountFamilyOpens = window.fixtureModelFamilyOpenCount;
                    await Promise.resolve();
                    return {oldConnected: old.isConnected, sameGeneration: true, power: replacement.innerText};
                    """) as? [String: Any]
                XCTAssertNotNil(observation, condition)
                XCTAssertEqual(observation?["oldConnected"] as? Bool, condition == "connected_old")
            }
            let succeeds = ["unchanged", "promoted_route"].contains(condition)
            let hiddenFamilyDrift = condition == "wrong_family"
            do {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": String(repeating: "Owned header remount fixture line.\n", count: 600)])
                XCTAssertEqual(sent["state"] as? String, "running")
                try assertRunningOrVerifiedChoice(sent, choice: choice)
                if hiddenFamilyDrift {
                    try await assertModelMismatchBeforePublication(fixture.transport, token: token, choice: choice)
                } else {
                    let complete = try await waitForState("complete", fixture.transport, token: token)
                    XCTAssertTrue(succeeds, "A contradictory or connected header cannot acquire final proof: \(condition)")
                    try assertChoiceEvidence(complete, choice: choice)
                    XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
                    let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
                    XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
                }
            } catch {
                if succeeds || hiddenFamilyDrift { throw error }
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser), condition)
            }
            XCTAssertTrue(applied, condition)
            let effects = try await evaluate(view, "return {expansions: window.fixtureExpansionClicks, freshFamilyReads: window.fixtureModelFamilyOpenCount - window.fixtureRemountFamilyOpens};") as? [String: Int]
            XCTAssertEqual(effects?["expansions"], succeeds || hiddenFamilyDrift ? 1 : 0, condition)
            if succeeds { XCTAssertGreaterThanOrEqual(effects?["freshFamilyReads"] ?? 0, 1, "The replacement's text alone cannot supply family proof") }
            XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, succeeds || hiddenFamilyDrift ? "not_created" : "failed", condition)
            try await assertHumanTabIntact(fixture, retaining: succeeds || hiddenFamilyDrift ? nil : ownedID)
        }
    }

    func testCollapsedFirstMessagePreservesModelPrecheckFailureWithoutExpansionOrReplay() async throws {
        for condition in ["unavailable", "power_mismatch"] {
            let fixture = try Fixture(page: Self.collapsedFirstUserPage())
            defer { fixture.shutdown() }
            let choice = Self.fixtureChoice(.chatgpt)
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            let ready = try await waitForState("ready", fixture.transport, token: token)
            try assertChoiceEvidence(ready, choice: choice)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            var mutationApplied = false
            var firstUserDiagnostics: [String] = [], modelDiagnostics: [String] = []
            var emissions: [(isFailure: Bool, record: String)] = []
            fixture.transport.setFirstUserDiagnosticsObserverForTesting { firstUserDiagnostics += $0 }
            fixture.transport.setFirstUserStructureEmissionObserverForTesting { emissions.append(($0, $1)) }
            fixture.transport.setModelDiagnosticsObserverForTesting { modelDiagnostics.append($0) }
            fixture.transport.setBeforePageResultValidationDetailedForTesting { action, _ in
                guard action == "submit", !mutationApplied else { return }
                mutationApplied = true
                let applied = try? await self.evaluate(view, """
                    const trigger = document.getElementById('fixture-model-trigger');
                    if (window.fixturePrompts.length !== 1 || !trigger) return false;
                    if (\(String(reflecting: condition)) === 'unavailable') {
                      trigger.disabled = true;
                    } else {
                      window.fixtureChatPowerThumb.setAttribute('aria-valuenow', '2');
                      window.fixtureModelUpdateHeader();
                    }
                    return true;
                    """) as? Bool
                XCTAssertEqual(applied, true, "The selector changes only after the actual first Send")
            }
            defer {
                fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
                fixture.transport.setFirstUserDiagnosticsObserverForTesting(nil)
                fixture.transport.setFirstUserStructureEmissionObserverForTesting(nil)
                fixture.transport.setModelDiagnosticsObserverForTesting(nil)
            }
            let prompt = String(repeating: "Owned private model-precheck fixture line.\n", count: 600)
            do {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
                try assertRunningOrVerifiedChoice(sent, choice: choice)
                // First-message verification belongs to the first post-Send read.
                _ = try await waitForState("complete", fixture.transport, token: token)
                XCTFail("The unverified expansion must not return a response or a tool instruction")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser))
            }
            XCTAssertTrue(mutationApplied)
            XCTAssertFalse(emissions.isEmpty, "Accepted first-user rejection causes must be emitted at retained error severity")
            XCTAssertTrue(emissions.allSatisfy { $0.isFailure })
            XCTAssertTrue(emissions.allSatisfy {
                $0.record.utf8.count <= 960 && !$0.record.contains("Owned private model-precheck")
                    && !$0.record.contains("Computa session marker:") && !$0.record.contains("https://")
            })
            let emitted = try emissions.map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.record.utf8)) as? [String: Any])
            }
            XCTAssertTrue(emitted.contains { $0["reason"] as? String == "marker_not_final" })
            XCTAssertTrue(emitted.contains { $0["expansionModelError"] as? String ==
                (condition == "unavailable" ? "model_unverified" : "model_mismatch") })
            let observations = firstUserDiagnostics.compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            let structure = try XCTUnwrap(observations.first { $0["kind"] as? String == "first_user_structure" })
            XCTAssertEqual(structure["reason"] as? String, "marker_not_final")
            XCTAssertEqual(structure["privatePinPresent"] as? Bool, false)
            XCTAssertEqual(structure["expectedFingerprintPresent"] as? Bool, false)
            let body = try XCTUnwrap(observations.first { $0["kind"] as? String == "first_user_body" })
            XCTAssertEqual(body["expansionOutcome"] as? String, "model_unverified")
            XCTAssertEqual(body["expansionModelError"] as? String,
                           condition == "unavailable" ? "model_unverified" : "model_mismatch")
            let pickerRows = modelDiagnostics.compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            XCTAssertFalse(pickerRows.contains {
                ($0["readContext"] as? [String: Any])?["scope"] as? String == "action_precheck"
                    && ($0["readContext"] as? [String: Any])?["action"] as? String == "inspect"
            }, "A passive negative check must not claim a fresh picker read")
            XCTAssertTrue(firstUserDiagnostics.allSatisfy { $0.utf8.count <= 960 && !$0.contains("Owned private model-precheck") })
            XCTAssertTrue(modelDiagnostics.allSatisfy { $0.utf8.count <= 16_384 && !$0.contains("Owned private model-precheck") })

            // A later native read cannot convert the retained failed claim
            // into another expansion, Send, or first-message authority.
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A rejected precheck must remain terminal")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertTrue((finished["text"] as? String ?? "").isEmpty)
            let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(clicks, 0)
            let privatePin = try await evaluate(view, "return !!globalThis.__computaModelFirstProof;",
                world: .world(name: "computa-chatgpt-model-v1")) as? Bool
            XCTAssertEqual(privatePin, false)
            XCTAssertEqual(fixture.createdTabs.count, 1)
            XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            try await assertHumanTabIntact(fixture, retaining: ownedID)
        }
    }

    func testExactFencedRequestDOMPreservesThreeNativeSubmissionProofsAndToolCallResponse() async throws {
        let render = #"""
            userBody.classList.add('whitespace-pre-wrap');
            const opening = 'COMPLETE_RESPONSES_REQUEST_JSON:\n```\n';
            const closing = '\n```\nEND_COMPLETE_RESPONSES_REQUEST_JSON.';
            const start = prompt.indexOf(opening) + opening.length, end = prompt.indexOf(closing, start);
            if (start < opening.length || end < start) throw new Error('Invalid synthetic request frame');
            const pre = document.createElement('pre');
            pre.setAttribute('data-markdown-copy', 'code-block'); pre.setAttribute('data-horizontal-scroll', 'true');
            const code = document.createElement('code'); code.setAttribute('data-markdown-copy-content', 'true');
            code.appendChild(document.createTextNode(prompt.slice(start, end))); pre.appendChild(code);
            userBody.replaceChildren(document.createTextNode(prompt.slice(0, start - 4)), pre,
              document.createTextNode(prompt.slice(end + 4)));
            """#
        let page = Self.modelChoicePage(.chatgpt)
            .replacingOccurrences(of: "else userBody.textContent = prompt;", with: "else { \(render) }")
            .replacingOccurrences(of: "answerBody.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';",
                with: "answerBody.textContent = window.fixturePrompts.length === 1 ? '\(Self.fixtureToolReply)' : '{\"type\":\"message\",\"text\":\"Fixture reply\"}';")
        XCTAssertTrue(page.contains(render))
        let fixture = try Fixture(page: page)
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        var firstFingerprint: String?
        for round in 1...3 {
            let request = Data(#"{"model":"\#(syntheticChatGPTModelID)","input":"literal \u005f \u0060 \u005c", "metadata":{"duplicate":"one","duplicate":"two"},"tools":[{"type":"function","name":"fixture","parameters":{"type":"object","properties":{"exact":{"type":"integer","minimum":9007199254740993}}}}]}"#.utf8)
            let prepared = try WebModelResponseCodec.prepareRequest(request)
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prepared.prompt])
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(complete["sequence"] as? Int, round)
            XCTAssertEqual(complete["text"] as? String, round == 1 ? Self.fixtureToolReply : #"{"type":"message","text":"Fixture reply"}"#)
            try assertChoiceEvidence(complete, choice: choice)
            let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            let fingerprint = try XCTUnwrap(proof["firstUserFingerprint"] as? String)
            let capturedPrompts = try await evaluate(view, "return window.fixturePrompts;")
            let sentPrompts = try XCTUnwrap(capturedPrompts as? [String])
            // The editor adds a terminal LF; ownership has always hashed the
            // complete CRLF/NFC/trim canonical body, including its marker.
            let firstOutbound = try XCTUnwrap(sentPrompts.first)
            let canonicalOutbound = firstOutbound.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(fingerprint, EmbeddedWebModelTransport.promptFingerprint(canonicalOutbound))
            XCTAssertEqual(canonicalOutbound.components(separatedBy: "\n\nComputa session marker: ").first, prepared.prompt)
            if let firstFingerprint { XCTAssertEqual(fingerprint, firstFingerprint) } else { firstFingerprint = fingerprint }
            let lexical = try await evaluate(view, """
                const bodies = [...document.querySelectorAll('[data-markdown-text-style="user-message"]')];
                return bodies.length === \(round) && bodies.every((body, index) => {
                  const code = body.querySelector('pre[data-markdown-copy="code-block"] > code[data-markdown-copy-content="true"]');
                  return code && code.textContent.includes('9007199254740993')
                    && code.textContent.includes('"duplicate":"one","duplicate":"two"')
                    && body.innerText !== window.fixturePrompts[index];
                });
                """) as? Bool
            XCTAssertEqual(lexical, true)
            try await assertChoiceLedger(view, insertions: round, sends: round, selections: 1)
        }
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        XCTAssertEqual(fixture.createdTabs.count, 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testStringPunctuationEncodingSurvivesExtraEscapeRenderingWithoutRelaxingOwnership() async throws {
        // Force +17 quote/markup, +5 markup and +2 underscore differences.
        // Modified intraword text still fails ownership; protected edge/repeated
        // underscores and unmodified intraword text succeed. This synthetic
        // transformation does not establish the real website's rendering.
        let original = try JSONSerialization.data(withJSONObject: [
            "model": syntheticChatGPTModelID,
            "input": String(repeating: "Owned quote rendering fixture line.\n", count: 600) + String(repeating: "\"", count: 12) + String(repeating: "<tag>&", count: 5),
        ], options: [.sortedKeys])
        let prepared = try WebModelResponseCodec.prepareRequest(original)
        let jsonRange = try WebsiteRequestFixture.range(in: prepared.prompt, expectedModel: syntheticChatGPTModelID)
        let legacy = prepared.prompt.replacingCharacters(in: jsonRange, with: String(decoding: original, as: UTF8.self))
        let quoteOnly = prepared.prompt.replacingOccurrences(of: #"\u003c"#, with: "<")
            .replacingOccurrences(of: #"\u003e"#, with: ">")
            .replacingOccurrences(of: #"\u0026"#, with: "&")
        let underscoreOriginal = try JSONSerialization.data(withJSONObject: [
            "model": syntheticChatGPTModelID,
            "input": String(repeating: "Owned underscore rendering fixture line.\n", count: 600) + "a_b c_d",
        ], options: [.sortedKeys])
        let underscorePrepared = try WebModelResponseCodec.prepareRequest(underscoreOriginal)
        let underscoreJSONRange = try WebsiteRequestFixture.range(in: underscorePrepared.prompt, expectedModel: syntheticChatGPTModelID)
        let underscoreLegacy = underscorePrepared.prompt.replacingCharacters(in: underscoreJSONRange,
                                                                            with: String(decoding: underscoreOriginal, as: UTF8.self))
        let protectedUnderscores = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: [
            "model": syntheticChatGPTModelID,
            "input": String(repeating: "Owned protected underscore fixture line.\n", count: 600) + "_edge a__b tail_",
        ], options: [.sortedKeys]))
        let extraEscapeScript = #"const start = prompt.indexOf('COMPLETE_RESPONSES_REQUEST_JSON:\n') + 'COMPLETE_RESPONSES_REQUEST_JSON:\n'.length; const end = prompt.indexOf('\nEND_COMPLETE_RESPONSES_REQUEST_JSON.', start); userBody.textContent = prompt.slice(0, start) + prompt.slice(start, end).replace(/\\(?=")|<|_/g, match => match === '\\' ? '\\\\' : '\\' + match) + prompt.slice(end);"#
        for (prompt, extraCharacters, transform) in [
            (legacy, 17, true), (quoteOnly, 5, true), (prepared.prompt, 0, true),
            (underscoreLegacy, 2, true), (underscorePrepared.prompt, 2, true),
            (protectedUnderscores.prompt, 0, true), (underscorePrepared.prompt, 0, false),
        ] {
            let succeeds = extraCharacters == 0
            let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionScript:
                transform ? extraEscapeScript : "userBody.textContent = prompt;"))
            defer { fixture.shutdown() }
            let choice = Self.fixtureChoice(.chatgpt)
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            var diagnostics: [String] = []
            fixture.transport.setFirstUserDiagnosticsObserverForTesting { diagnostics += $0 }
            defer { fixture.transport.setFirstUserDiagnosticsObserverForTesting(nil) }
            if succeeds {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
                let complete = try await waitForState("complete", fixture.transport, token: token)
                XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
                try assertChoiceEvidence(complete, choice: choice)
            } else {
                do {
                    let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
                    try assertRunningOrVerifiedChoice(sent, choice: choice)
                    _ = try await waitForState("complete", fixture.transport, token: token)
                    XCTFail("An extra escape must still fail ownership")
                } catch { XCTAssertTrue(error is EmbeddedWebModelTransport.Failure) }
            }
            let values = diagnostics.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let comparison = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_text" })
            XCTAssertEqual(comparison["expansionASCIIPromptMatches"] as? Bool, succeeds)
            if !succeeds {
                XCTAssertEqual(comparison["expansionFirstActualCharacter"] as? String, "backslash")
                XCTAssertEqual(comparison["expansionFirstExpectedCharacter"] as? String,
                               extraCharacters == 17 ? "double_quote" : extraCharacters == 5 ? "less_than" : "underscore")
                XCTAssertEqual(try XCTUnwrap(comparison["expansionASCIIRenderedLength"] as? Int) -
                               XCTUnwrap(comparison["expansionASCIIPromptLength"] as? Int), extraCharacters)
            }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let expansionClicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(expansionClicks, 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, succeeds ? "not_created" : "failed")
            if succeeds { try await assertHumanTabIntact(fixture) }
            else { try await assertHumanTabIntact(fixture, retaining: ownedID) }
        }
    }

    func testChatTurnFullCanonicalExpansionRejectsASCIIWhitespaceSubstitutionWithoutReplay() async throws {
        let mutations = [
            "ascii": "userBody.textContent = prompt.replace('Owned ', 'Owned ' + '\\n'.repeat(15));",
            "punctuation": "userBody.textContent = prompt.replace('Owned', 'Ow!ed');",
            "unicode_space": "userBody.textContent = prompt.replace('Owned ', 'Owned\\u00a0');",
            "format": "userBody.textContent = prompt.replace('Owned ', 'Owned\\u200b');",
        ]
        for condition in ["ascii", "punctuation", "unicode_space", "format"] {
            let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionScript: try XCTUnwrap(mutations[condition])))
            defer { fixture.shutdown() }
            let choice = Self.fixtureChoice(.chatgpt)
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            var diagnostics: [String] = []
            fixture.transport.setFirstUserDiagnosticsObserverForTesting { diagnostics += $0 }
            defer { fixture.transport.setFirstUserDiagnosticsObserverForTesting(nil) }
            let params: [String: String] = ["sessionToken": token,
                "prompt": String(repeating: "Owned prefix comparison fixture line.\n", count: 600)]
            if condition == "ascii" {
                do {
                    let sent = try await fixturePhaseProbe("strict_expansion_send") { try await call(fixture.transport, "webProviderSend", params) }
                    try assertRunningOrVerifiedChoice(sent, choice: choice)
                    _ = try await waitForState("complete", fixture.transport, token: token)
                    XCTFail("ASCII run equivalence cannot replace the actual full outbound digest")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("A failed full canonical proof cannot admit an answer")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
            } else {
                do {
                    let sent = try await call(fixture.transport, "webProviderSend", params)
                    try assertRunningOrVerifiedChoice(sent, choice: choice)
                    _ = try await waitForState("complete", fixture.transport, token: token)
                    XCTFail("ASCII whitespace comparison must preserve \(condition) differences")
                } catch { XCTAssertTrue(error is EmbeddedWebModelTransport.Failure) }
                _ = try await evaluate(view, """
                    document.querySelector('[data-message-author-role="user"] [data-markdown-text-style="user-message"]').textContent = window.fixturePrompts[0];
                    return true;
                    """)
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("Restoring text cannot revive a rejected expansion")
                } catch { XCTAssertTrue(error is EmbeddedWebModelTransport.Failure) }
            }
            let values = diagnostics.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            // The legacy expansion diagnostic can recognize ASCII run
            // equivalence, while the new full outbound proof refuses it.
            var privateComparison: [String: Any]?
            if condition == "ascii" {
                let observation = try await evaluate(view, "return globalThis.__computaModelFirstExpansion?.textDiagnostic;",
                    world: .world(name: "computa-chatgpt-model-v1"))
                privateComparison = observation as? [String: Any]
            }
            let comparison = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_text" } ?? privateComparison)
            XCTAssertEqual(comparison["expansionTextAnalyzed"] as? Bool, true)
            XCTAssertEqual(comparison["expansionClicked"] as? Bool, true)
            XCTAssertEqual(comparison["expansionExactPrefixMatches"] as? Bool, false)
            XCTAssertEqual(comparison["expansionASCIIPrefixMatches"] as? Bool, condition == "ascii")
            XCTAssertEqual(comparison["expansionASCIIPromptMatches"] as? Bool, condition == "ascii")
            XCTAssertEqual(comparison["expansionFirstMismatchClass"] as? String, condition == "ascii" ? "none" : condition)
            let expectedCharacters = ["punctuation": ("exclamation", "other"), "unicode_space": ("no_break_space", "ascii_space"), "format": ("zero_width_space", "ascii_space")]
            if let pair = expectedCharacters[condition] {
                XCTAssertEqual(comparison["expansionFirstActualCharacter"] as? String, pair.0)
                XCTAssertEqual(comparison["expansionFirstExpectedCharacter"] as? String, pair.1)
            } else {
                XCTAssertNil(comparison["expansionFirstActualCharacter"])
                XCTAssertNil(comparison["expansionFirstExpectedCharacter"])
            }
            XCTAssertTrue(diagnostics.allSatisfy { $0.utf8.count <= 960 && !$0.contains("Owned prefix comparison") })
            XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
            let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(clicks, 1)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            try await assertHumanTabIntact(fixture, retaining: ownedID)
        }
    }

    func testFirstMessageExpansionIgnoresRenderingChurnButRetainsTransientWorkRevocation() async throws {
        for transientWork in [false, true] {
            let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionScript: """
                const text = userBody.firstChild;
                for (let i = 0; i < 600; i++) text.data = prompt;
                if (\(transientWork)) {
                  const work = document.getElementById('fixture-work-mode');
                  work.setAttribute('aria-pressed', 'true');
                  work.setAttribute('aria-pressed', 'false');
                }
                window.fixtureRenderingMutations = 600;
                """))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            var diagnostics: [String] = []
            fixture.transport.setFirstUserDiagnosticsObserverForTesting { diagnostics += $0 }
            let prompt = String(repeating: "Rendering churn must preserve the owned prompt.\n", count: 600)
            if transientWork {
                do {
                    // Native may detect the product change during Send's
                    // first read or the subsequent completion observation.
                    _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
                    _ = try await waitForState("complete", fixture.transport, token: token)
                    XCTFail("A transient Work selection cannot be hidden among message rendering")
                } catch {
                    let failure = try XCTUnwrap(error as? EmbeddedWebModelTransport.Failure)
                    XCTAssertTrue([.productModeUnverified, .ownershipFailure(.javaScriptFirstUser),
                                   .ownershipFailure(.promotionFirstUser)].contains(failure))
                }
                let values = diagnostics.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                XCTAssertTrue(values.contains { $0["productProofFailure"] as? String == "work_selected" })
                XCTAssertTrue(values.contains { ($0["productMutationIgnoredCount"] as? Int ?? 0) >= 600 })
            } else {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
                let complete = try await waitForState("complete", fixture.transport, token: token)
                XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
                XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
            }
            let mutations = try await evaluate(view, "return window.fixtureRenderingMutations;") as? Int
            let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(mutations, 600)
            XCTAssertEqual(clicks, 1)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            if !transientWork {
                let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
                XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            }
            fixture.transport.setFirstUserDiagnosticsObserverForTesting(nil)
            try await assertHumanTabIntact(fixture, retaining: transientWork ? fixture.createdTabs.last : nil)
        }
    }

    func testFirstMessageExpansionContinuesThroughNativeCertifiedFirstLocalRouteWithoutReclick() async throws {
        let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionScript: """
            history.pushState({}, '', '/c/local-chatgpt%3Aexpanded-first-user?temporary-chat=true');
            """))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": String(repeating: "Owned first-route expansion fixture line.\n", count: 600)])
        XCTAssertEqual(sent["state"] as? String, "running")
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
        let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
        XCTAssertEqual(view.url?.path, "/c/local-chatgpt:expanded-first-user")
        let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        XCTAssertEqual(fixture.createdTabs.count, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testFirstSubmissionDigestCrossingNativeCertifiedPromotionDoesNotPoisonFreshProof() async throws {
        let localRoute = "/c/local-chatgpt%3Asubmission-digest-promotion?temporary-chat=true"
        let publicRoute = "/c/public-submission-digest-promotion?temporary-chat=true"
        let page = Self.firstSendRoutePromotionPage().replacingOccurrences(of: "window.fixturePrompts.push(prompt);", with: """
            window.fixturePrompts.push(prompt);
            if (window.fixturePrompts.length === 1) history.pushState({}, '', '\(localRoute)');
            """)
        let fixture = try Fixture(page: page)
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        let privateWorld = WKContentWorld.world(name: "computa-chatgpt-model-v1")
        _ = try await evaluate(view, """
            const original = crypto.subtle.digest.bind(crypto.subtle);
            globalThis.__fixtureSubmissionDigestPromotion = null;
            crypto.subtle.digest = async (...arguments_) => {
              const result = await original(...arguments_);
              const state = globalThis.__computaChatSubmissionState, record = state?.pending;
              const first = globalThis.__computaModelFirstProof;
              if (!globalThis.__fixtureSubmissionDigestPromotion && first && record?.sequence === 1
                && record.phase === 'send_claimed' && record.root == null && record.body == null
                && document.URL === 'https://chatgpt.com\(localRoute)'
                && new TextDecoder().decode(arguments_[1]) === record.canonical) {
                const root = document.querySelector('[data-message-author-role="user"]');
                const body = root?.querySelector('[data-markdown-text-style="user-message"]');
                globalThis.__fixtureSubmissionDigestPromotion = { root, body,
                  firstProofPresent: true, pendingPhase: record.phase, recordUnbound: true,
                  firstFingerprintMatches: first.fingerprint === record.fingerprint,
                  exactBody: body?.innerText.normalize('NFC').trim() === record.canonical,
                  fromURL: document.URL, promotions: 1 };
                history.pushState({}, '', '\(publicRoute)');
              }
              return result;
            }; return true;
            """, world: privateWorld)
        var certifiedPromotions = 0
        var opensAtPromotion: Int?
        fixture.transport.setFirstUserExpansionRouteCheckpointForTesting { checkpoint in
            guard checkpoint == .routeAccepted, view.url?.path == "/c/public-submission-digest-promotion" else { return }
            certifiedPromotions += 1
            let state = try? await self.evaluate(view, """
                const state = globalThis.__computaChatSubmissionState, record = state?.pending;
                return { revoked: state?.revoked, pendingPhase: record?.phase,
                  recordUnbound: record?.root == null && record?.body == null,
                  firstProofPresent: !!globalThis.__computaModelFirstProof };
                """, world: privateWorld) as? [String: Any]
            XCTAssertEqual(state?["revoked"] as? Bool, false)
            XCTAssertEqual(state?["pendingPhase"] as? String, "send_claimed")
            XCTAssertEqual(state?["recordUnbound"] as? Bool, true)
            XCTAssertEqual(state?["firstProofPresent"] as? Bool, true)
            opensAtPromotion = try? await self.evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
        }
        defer { fixture.transport.setFirstUserExpansionRouteCheckpointForTesting(nil) }
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Exact first request through the later submission digest promotion"])
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(certifiedPromotions, 1)
        XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
        try assertChoiceEvidence(complete, choice: choice)
        let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
        XCTAssertEqual((proof["submittedPromptFingerprint"] as? String)?.count, 64)
        let final = try await evaluate(view, """
            const capture = globalThis.__fixtureSubmissionDigestPromotion;
            const state = globalThis.__computaChatSubmissionState, record = state?.lastVerified;
            return { firstProofPresent: capture?.firstProofPresent, pendingPhase: capture?.pendingPhase,
              recordUnbound: capture?.recordUnbound, exactBody: capture?.exactBody,
              firstFingerprintMatches: capture?.firstFingerprintMatches, fromURL: capture?.fromURL,
              promotions: capture?.promotions, revoked: state?.revoked, pendingCleared: state?.pending == null,
              finalPhase: record?.phase, sameRoot: record?.root === capture?.root,
              sameBody: record?.body === capture?.body, bodyConnected: capture?.body.isConnected };
            """, world: privateWorld) as? [String: Any]
        XCTAssertEqual(final?["fromURL"] as? String, "https://chatgpt.com" + localRoute)
        XCTAssertEqual(final?["pendingPhase"] as? String, "send_claimed")
        XCTAssertEqual(final?["finalPhase"] as? String, "verified")
        XCTAssertEqual(final?["promotions"] as? Int, 1)
        for key in ["firstProofPresent", "recordUnbound", "exactBody", "firstFingerprintMatches",
                    "pendingCleared", "sameRoot", "sameBody", "bodyConnected"] {
            XCTAssertEqual(final?[key] as? Bool, true, key)
        }
        XCTAssertEqual(final?["revoked"] as? Bool, false)
        XCTAssertEqual(view.url?.absoluteString, "https://chatgpt.com" + publicRoute)
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        let finalOpens = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
        XCTAssertGreaterThan(try XCTUnwrap(finalOpens), try XCTUnwrap(opensAtPromotion),
                             "The crossed submission digest supplies no final selected-model proof")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        fixture.transport.setFirstUserExpansionRouteCheckpointForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testCompletedFirstExpansionSurvivesNativeCertifiedPromotionDuringDigestWithoutReplay() async throws {
        let localRoute = "/c/local-chatgpt%3Acompleted-native-expansion?temporary-chat=true"
        let publicRoute = "/c/public-completed-native-expansion?temporary-chat=true"
        let page = Self.collapsedFirstUserPage().replacingOccurrences(of: "window.fixturePrompts.push(prompt);", with: """
            window.fixturePrompts.push(prompt);
            if (window.fixturePrompts.length === 1) history.pushState({}, '', '\(localRoute)');
            """)
        let fixture = try Fixture(page: page)
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        let privateWorld = WKContentWorld.world(name: "computa-chatgpt-model-v1")
        _ = try await evaluate(view, """
            const original = crypto.subtle.digest.bind(crypto.subtle);
            globalThis.__fixtureCompletedExpansionPromotion = null;
            crypto.subtle.digest = async (...arguments_) => {
              const result = await original(...arguments_);
              const candidate = globalThis.__computaModelFirstExpansion;
              if (!globalThis.__fixtureCompletedExpansionPromotion && candidate?.outcome === 'expanded'
                && !globalThis.__computaModelFirstProof && location.pathname.startsWith('/c/local-chatgpt')) {
                globalThis.__fixtureCompletedExpansionPromotion = {
                  outcome: candidate.outcome, deadline: candidate.deadline, route: candidate.routeURL,
                  exactBody: candidate.body.innerText.normalize('NFC').trim() === candidate.canonical,
                  firstProofPresent: !!globalThis.__computaModelFirstProof, promotions: 1
                };
                history.pushState({}, '', '\(publicRoute)');
              }
              return result;
            }; return true;
            """, world: privateWorld)
        var opensAtPromotion: Int?
        fixture.transport.setFirstUserExpansionRouteCheckpointForTesting { checkpoint in
            guard checkpoint == .routeAccepted, view.url?.path == "/c/public-completed-native-expansion" else { return }
            let state = try? await self.evaluate(view, """
                const candidate = globalThis.__computaModelFirstExpansion;
                return { outcome: candidate?.outcome, firstProofPresent: !!globalThis.__computaModelFirstProof,
                  exactBody: candidate?.body.innerText.normalize('NFC').trim() === candidate?.canonical };
                """, world: privateWorld) as? [String: Any]
            XCTAssertEqual(state?["outcome"] as? String, "expanded")
            XCTAssertEqual(state?["firstProofPresent"] as? Bool, false)
            XCTAssertEqual(state?["exactBody"] as? Bool, true)
            opensAtPromotion = try? await self.evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
        }
        defer { fixture.transport.setFirstUserExpansionRouteCheckpointForTesting(nil) }
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": String(repeating: "Owned completed native expansion fixture line.\n", count: 600)])
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
        try assertChoiceEvidence(complete, choice: choice)
        let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
        let state = try await evaluate(view, """
            const candidate = globalThis.__computaModelFirstExpansion;
            return { ...globalThis.__fixtureCompletedExpansionPromotion,
              finalRoute: candidate.routeURL, finalDeadline: candidate.deadline, finalOutcome: candidate.outcome };
            """, world: privateWorld) as? [String: Any]
        XCTAssertEqual(state?["outcome"] as? String, "expanded")
        XCTAssertEqual(state?["exactBody"] as? Bool, true)
        XCTAssertEqual(state?["firstProofPresent"] as? Bool, false)
        XCTAssertEqual(state?["promotions"] as? Int, 1)
        XCTAssertEqual(state?["route"] as? String, "https://chatgpt.com" + localRoute)
        XCTAssertEqual(state?["finalRoute"] as? String, "https://chatgpt.com" + publicRoute)
        XCTAssertEqual(state?["finalOutcome"] as? String, "expanded")
        XCTAssertEqual(state?["finalDeadline"] as? Double, state?["deadline"] as? Double)
        let finalOpens = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
        XCTAssertGreaterThan(try XCTUnwrap(finalOpens), try XCTUnwrap(opensAtPromotion),
                             "The discarded read cannot supply selected-model proof")
        let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        fixture.transport.setFirstUserExpansionRouteCheckpointForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testOneExpansionContinuesAcrossFirstLocalRouteAndItsPublicPromotionBeforeLineageBinding() async throws {
        let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionDelayMilliseconds: 2_300,
            earlyExpansionScript: """
                history.pushState({}, '', '/c/local-chatgpt%3Aexpansion-route-chain?temporary-chat=true');
                """))
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: ownedID)
        let initialURL = try XCTUnwrap(view.url?.absoluteString)
        // This fixture oracle observes the private candidate route pin, which
        // advances only after JS validates and consumes the exact native edge.
        // The next route is committed by that receipt, never by a timer that
        // could let native validation skip the local document altogether.
        _ = try await evaluate(view, """
            globalThis.__computaFixtureExpansionEdges = [];
            let expansion;
            Object.defineProperty(globalThis, '__computaModelFirstExpansion', {
              configurable: true,
              get() { return expansion; },
              set(candidate) {
                expansion = candidate;
                if (!candidate) return;
                let route = candidate.routeURL;
                Object.defineProperty(candidate, 'routeURL', {
                  configurable: true, enumerable: true,
                  get() { return route; },
                  set(next) {
                    globalThis.__computaFixtureExpansionEdges.push([route, next]);
                    route = next;
                    if (globalThis.__computaFixtureExpansionEdges.length === 1) {
                      history.pushState({}, '', '/c/public-expansion-route-chain?temporary-chat=true');
                    } else if (globalThis.__computaFixtureExpansionEdges.length === 2) {
                      candidate.body.textContent = candidate.prompt;
                      candidate.root.querySelector('button[aria-label="Show more"]')?.remove();
                    }
                  }
                });
              }
            }); return true;
            """, world: .world(name: "computa-chatgpt-model-v1"))
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": String(repeating: "Owned two-edge expansion fixture line.\n", count: 600)])
        XCTAssertEqual(sent["state"] as? String, "running")
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
        try assertChoiceEvidence(complete, choice: choice)
        XCTAssertEqual(view.url?.path, "/c/public-expansion-route-chain")
        let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
        let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
        XCTAssertEqual(clicks, 1)
        let edges = try await evaluate(view, "return globalThis.__computaFixtureExpansionEdges;",
                                       world: .world(name: "computa-chatgpt-model-v1")) as? [[String]]
        let localURL = "https://chatgpt.com/c/local-chatgpt%3Aexpansion-route-chain?temporary-chat=true"
        let publicURL = "https://chatgpt.com/c/public-expansion-route-chain?temporary-chat=true"
        XCTAssertEqual(edges, [[initialURL, localURL], [localURL, publicURL]],
                       "Both native-certified receipts must be consumed before first-message lineage can bind")
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testExactExpansionRouteChainSurvivesPreEntryAndPreScriptPublicPromotion() async throws {
        for checkpoint in [EmbeddedWebModelTransport.FirstUserExpansionRouteCheckpoint.routeAccepted, .continuationInput] {
            let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionDelayMilliseconds: 2_300,
                earlyExpansionScript: "history.pushState({}, '', '/c/local-chatgpt%3Apre-entry-expansion?temporary-chat=true');"))
            defer { fixture.shutdown() }
            let choice = Self.fixtureChoice(.chatgpt)
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            let initialURL = try XCTUnwrap(view.url?.absoluteString)
            var promoted = false
            var originalDeadline: Double?
            fixture.transport.setFirstUserExpansionRouteCheckpointForTesting { observed in
                guard observed == checkpoint, !promoted else { return }
                promoted = true
                // At routeAccepted native has captured the local edge but has
                // not entered the next inspect. At continuationInput it has
                // captured that inspect's local URL, before executing JS.
                let before = try? await self.evaluate(view, """
                    const candidate = globalThis.__computaModelFirstExpansion;
                    return { route: candidate?.routeURL, deadline: candidate?.deadline,
                      clicked: candidate?.clicked, outcome: candidate?.outcome };
                    """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
                XCTAssertEqual(before?["route"] as? String, initialURL)
                XCTAssertEqual(before?["clicked"] as? Bool, true)
                XCTAssertEqual(before?["outcome"] as? String, "context_changed")
                originalDeadline = before?["deadline"] as? Double
                let changed = try? await self.evaluate(view, """
                    const body = document.querySelector('[data-message-author-role="user"] [data-markdown-text-style="user-message"]');
                    if (!body || window.fixturePrompts.length !== 1 || window.fixtureExpansionClicks !== 1) return false;
                    history.pushState({}, '', '/c/public-pre-entry-expansion?temporary-chat=true');
                    body.textContent = window.fixturePrompts[0];
                    body.parentElement.querySelector('button[aria-label="Show more"]')?.remove(); return true;
                    """) as? Bool
                XCTAssertEqual(changed, true)
            }
            defer { fixture.transport.setFirstUserExpansionRouteCheckpointForTesting(nil) }
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": String(repeating: "Owned native pre-entry route-chain fixture line.\n", count: 600)])
            XCTAssertEqual(sent["state"] as? String, "running")
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertTrue(promoted)
            XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
            try assertChoiceEvidence(complete, choice: choice)
            let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
            let final = try await evaluate(view, """
                const candidate = globalThis.__computaModelFirstExpansion;
                return { route: candidate.routeURL, deadline: candidate.deadline, outcome: candidate.outcome };
                """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
            XCTAssertNotNil(originalDeadline)
            XCTAssertEqual(final?["deadline"] as? Double, originalDeadline)
            XCTAssertEqual(final?["route"] as? String, view.url?.absoluteString)
            XCTAssertEqual(final?["outcome"] as? String, "expanded")
            XCTAssertEqual(view.url?.path, "/c/public-pre-entry-expansion")
            XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
            let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(clicks, 1)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            fixture.transport.setFirstUserExpansionRouteCheckpointForTesting(nil)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testPreEntryExpansionRouteChainRejectsExtraRoutesAndDestructiveChangesWithoutReplay() async throws {
        for condition in ["second_local", "third_public", "body", "owner", "work"] {
            let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionDelayMilliseconds: 2_300,
                earlyExpansionScript: "history.pushState({}, '', '/c/local-chatgpt%3Arejected-pre-entry?temporary-chat=true');"))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            var changed = false
            var extraPublic = false
            fixture.transport.setFirstUserExpansionRouteCheckpointForTesting { checkpoint in
                if checkpoint == .continuationInput, condition == "third_public", changed, !extraPublic {
                    extraPublic = true
                    _ = try? await self.evaluate(view, "history.pushState({}, '', '/c/foreign-second-public?temporary-chat=true'); return true;")
                    return
                }
                guard checkpoint == .routeAccepted, !changed else { return }
                changed = true
                let target = condition == "second_local" ? "/c/local-chatgpt%3Aforeign-second-local" : "/c/public-rejected-pre-entry"
                _ = try? await self.evaluate(view, """
                    const body = document.querySelector('[data-message-author-role="user"] [data-markdown-text-style="user-message"]');
                    history.pushState({}, '', '\(target)?temporary-chat=true');
                    body.textContent = window.fixturePrompts[0];
                    if ('\(condition)' === 'body') body.replaceWith(body.cloneNode(true));
                    if ('\(condition)' === 'work') {
                      const work = document.getElementById('fixture-work-mode');
                      work.setAttribute('aria-pressed', 'true'); work.setAttribute('aria-pressed', 'false');
                    }
                    return true;
                    """)
                if condition == "owner" {
                    _ = try? await self.evaluate(view, "globalThis.__computaModelOwner = 'changed-private-fixture-owner'; return true;",
                                                world: .world(name: "computa-chatgpt-model-v1"))
                }
            }
            defer { fixture.transport.setFirstUserExpansionRouteCheckpointForTesting(nil) }
            do {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": String(repeating: "Owned rejected pre-entry fixture line.\n", count: 600)])
                XCTAssertEqual(sent["state"] as? String, "running")
                XCTAssertEqual(sent["text"] as? String, "")
                _ = try await waitForState("complete", fixture.transport, token: token)
                XCTFail("The bounded route chain must reject \(condition)")
            } catch { XCTAssertTrue(error is EmbeddedWebModelTransport.Failure) }
            XCTAssertTrue(changed)
            if condition == "third_public" { XCTAssertTrue(extraPublic) }
            fixture.transport.setFirstUserExpansionRouteCheckpointForTesting(nil)
            let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(clicks, 1)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            let clicksAfterCleanup = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(clicksAfterCleanup, 1)
            try await assertHumanTabIntact(fixture, retaining: ownedID)
        }
    }

    func testExpansionRouteContinuationRejectsChangedLineageOwnerAndProductWithoutAnotherClick() async throws {
        let changes = [
            "body": "const replacement = userBody.cloneNode(true); userBody.replaceWith(replacement);",
            "prompt": "userBody.textContent = 'Changed first body.\\n' + prompt;",
            "owner": "document.dispatchEvent(new Event('fixture-change-private-owner'));",
            "private_prompt": "document.dispatchEvent(new Event('fixture-change-private-prompt'));",
            "temporary": "document.getElementById('fixture-temporary-mode').setAttribute('aria-label', 'Start temporary chat'); document.getElementById('fixture-temporary-mode').textContent = 'Start temporary chat';",
            "foreign_route": "history.pushState({}, '', '/settings');",
        ]
        for condition in ["body", "prompt", "owner", "private_prompt", "temporary", "foreign_route"] {
            let effect = try XCTUnwrap(changes[condition])
            let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionScript: """
                history.pushState({}, '', '/c/local-chatgpt%3Arejected-expansion-\(condition)?temporary-chat=true');
                \(effect)
                """))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            if ["owner", "private_prompt"].contains(condition) {
                // Deliberate fixture corruption in the adapter's isolated
                // world. Ordinary website page code cannot access these pins.
                _ = try await evaluate(view, """
                    document.addEventListener('fixture-change-private-owner', () => {
                      globalThis.__computaModelOwner = 'invalid-fixture-owner';
                    });
                    document.addEventListener('fixture-change-private-prompt', () => {
                      globalThis.__computaModelFirstPrompt += '\\nChanged private fixture prompt.';
                    }); return true;
                    """, world: .world(name: "computa-chatgpt-model-v1"))
            }
            do {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": String(repeating: "Owned rejected expansion fixture line.\n", count: 600)])
                XCTAssertEqual(sent["state"] as? String, "running")
                XCTAssertEqual(sent["text"] as? String, "")
                _ = try await waitForState("complete", fixture.transport, token: token)
                XCTFail("A native route edge cannot repair \(condition) drift")
            } catch { XCTAssertTrue(error is EmbeddedWebModelTransport.Failure) }
            let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(clicks, 1)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            let clicksAfterCleanup = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
            XCTAssertEqual(clicksAfterCleanup, 1)
            try await assertHumanTabIntact(fixture, retaining: ownedID)
        }
    }

    func testNativeCertifiedRouteContinuationCannotRestartExpiredExpansionDeadline() async throws {
        let fixture = try Fixture(page: Self.collapsedFirstUserPage(expansionDelayMilliseconds: 2_300,
            earlyExpansionScript: """
                history.pushState({}, '', '/c/local-chatgpt%3Aexpired-expansion?temporary-chat=true');
                """))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        do {
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": String(repeating: "Owned delayed expansion fixture line.\n", count: 600)])
            XCTAssertEqual(sent["state"] as? String, "running")
            XCTAssertEqual(sent["text"] as? String, "")
            _ = try await waitForState("complete", fixture.transport, token: token)
            XCTFail("A certified route transition cannot grant another expansion deadline")
        } catch { XCTAssertTrue(error is EmbeddedWebModelTransport.Failure) }
        try await Task.sleep(for: .milliseconds(650))
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("Later full rendering cannot revive an expired expansion claim")
        } catch { XCTAssertTrue(error is EmbeddedWebModelTransport.Failure) }
        let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
        XCTAssertEqual(clicks, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        try await assertHumanTabIntact(fixture, retaining: ownedID)
    }

    func testCleanupCannotExpandAnUnboundCollapsedFirstMessage() async throws {
        for operation in ["webProviderFinish", "webProviderCancel"] {
            let fixture = try Fixture(page: Self.collapsedFirstUserPage(deferred: true))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": String(repeating: "Owned cleanup fixture line.\n", count: 600)])
            let proof = try XCTUnwrap(sent["pendingSubmissionContext"] as? [String: Any])
            XCTAssertEqual(proof["firstUserFingerprint"] as? String, "")
            _ = try await evaluate(view, """
                document.getElementById('messages').appendChild(window.fixturePendingUser);
                document.getElementById('messages').appendChild(window.fixturePendingTurn);
                window.fixturePendingUser = null; window.fixturePendingTurn = null;
                history.pushState({}, '', '/c/local-chatgpt%3Acleanup-cannot-expand?temporary-chat=true'); return true;
                """)
            var diagnostics: [String] = []
            fixture.transport.setFirstUserDiagnosticsObserverForTesting { diagnostics += $0 }
            let finished = try await call(fixture.transport, operation, ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            let clicks = try await evaluate(view, "return window.fixtureExpansionClicks || 0;") as? Int
            XCTAssertEqual(clicks, 0, "Cleanup inspection may verify lineage but cannot expand it")
            let values = diagnostics.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            XCTAssertTrue(values.contains { $0["allowFirstUserExpansion"] as? Bool == false })
            XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
            XCTAssertEqual(fixture.createdTabs.count, 1)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            try await assertHumanTabIntact(fixture, retaining: ownedID)
        }
    }

    func testIgnoredFirstMessageExpansionNeverClicksOrSendsAgain() async throws {
        let fixture = try Fixture(page: Self.collapsedFirstUserPage(deferred: true, ignored: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": String(repeating: "Owned ignored expansion line.\n", count: 600)])
        _ = try await evaluate(view, """
            document.getElementById('messages').appendChild(window.fixturePendingUser);
            document.getElementById('messages').appendChild(window.fixturePendingTurn);
            window.fixturePendingUser = null; window.fixturePendingTurn = null; return true;
            """)
        var expansionDiagnostics: [String] = []
        fixture.transport.setFirstUserDiagnosticsObserverForTesting { expansionDiagnostics += $0 }
        for _ in 0..<2 {
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("An ignored local expansion cannot admit a first message")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
        }
        let clicks = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
        XCTAssertEqual(clicks, 1)
        let diagnosticValues = expansionDiagnostics.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertTrue(diagnosticValues.contains { $0["expansionOutcome"] as? String == "timeout" })
        XCTAssertEqual(fixture.createdTabs.count, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        let clicksAfterCleanup = try await evaluate(view, "return window.fixtureExpansionClicks;") as? Int
        XCTAssertEqual(clicksAfterCleanup, 1)
        try await assertHumanTabIntact(fixture, retaining: ownedID)
    }

    func testDelayedFirstBubbleBindsThroughInspectBeforeAnyModelOnlyRead() async throws {
        for boundary in ["submit_result", "product_result", "after_send"] {
            let choice = Self.fixtureChoice(.chatgpt)
            let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            var acknowledged = false, rendered = false, sendReturned = false
            var firstPrivateBindAction: String?
            var firstBoundDiagnostics: [String] = []
            var emissions: [(isFailure: Bool, record: String)] = []
            fixture.transport.setFirstUserDiagnosticsObserverForTesting { firstBoundDiagnostics += $0 }
            fixture.transport.setFirstUserStructureEmissionObserverForTesting { emissions.append(($0, $1)) }
            let renderPending = """
                if (!window.fixturePendingUser || !window.fixturePendingTurn) return false;
                document.getElementById('messages').appendChild(window.fixturePendingUser);
                document.getElementById('messages').appendChild(window.fixturePendingTurn);
                window.fixturePendingUser = null; window.fixturePendingTurn = null; return true;
                """
            fixture.transport.setBeforePageResultValidationDetailedForTesting { action, enforceModel in
                if action == "submit" { acknowledged = true }
                guard acknowledged else { return }
                let bound = try? await self.evaluate(view, "return !!globalThis.__computaModelFirstProof;",
                    world: .world(name: "computa-chatgpt-model-v1")) as? Bool
                if bound == true, firstPrivateBindAction == nil { firstPrivateBindAction = action }
                if firstPrivateBindAction == nil {
                    XCTAssertNotEqual(action, "verifyModel", "Unbound messages cannot acquire model-only proof")
                    if action == "verifyProductMode" {
                        // The first Send permits one product-only recheck before
                        // its acknowledgment; it must not bind the message body.
                        XCTAssertFalse(enforceModel)
                        XCTAssertFalse(sendReturned)
                        XCTAssertEqual(bound, false)
                    }
                }
                let shouldRender = boundary == "submit_result" && action == "submit"
                    || boundary == "product_result" && action == "verifyProductMode" && !enforceModel
                if shouldRender, !rendered {
                    rendered = true
                    let result = try? await self.evaluate(view, renderPending) as? Bool
                    XCTAssertEqual(result, true)
                }
            }
            defer {
                fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
                fixture.transport.setFirstUserDiagnosticsObserverForTesting(nil)
                fixture.transport.setFirstUserStructureEmissionObserverForTesting(nil)
            }
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "A controlled delayed first bubble"])
            sendReturned = true
            XCTAssertEqual(sent["state"] as? String, "running")
            if boundary == "after_send" {
                let context = try XCTUnwrap(sent["pendingSubmissionContext"] as? [String: Any])
                XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
                XCTAssertNil(firstPrivateBindAction)
                let renderedAfterSend = try await evaluate(view, renderPending) as? Bool
                XCTAssertEqual(renderedAfterSend, true)
            }
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(firstPrivateBindAction, "inspect")
            XCTAssertEqual(complete["text"] as? String, Self.fixtureToolReply)
            XCTAssertFalse(emissions.isEmpty)
            XCTAssertTrue(emissions.allSatisfy { !$0.isFailure }, "Healthy first-bound diagnostics must stay at info severity")
            XCTAssertTrue(emissions.allSatisfy {
                $0.record.utf8.count <= 960 && !$0.record.contains("A controlled delayed first bubble")
                    && !$0.record.contains("Computa session marker:") && !$0.record.contains("https://")
            })
            let boundRecords = firstBoundDiagnostics.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            XCTAssertEqual(boundRecords.filter { $0["reason"] as? String == "first_bound" }.count, 1,
                "The separate first-user diagnostic must survive without replacing completion structure (\(boundary))")
            let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testIdenticalFirstNodeReplacementBeforeNativeBindingReportsWithoutAdmittingOrReplaying() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Controlled private first pin before native admission"])
        let context = try XCTUnwrap(sent["pendingSubmissionContext"] as? [String: Any])
        XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
        _ = try await evaluate(view, """
            document.getElementById('messages').appendChild(window.fixturePendingUser);
            document.getElementById('messages').appendChild(window.fixturePendingTurn);
            window.fixturePendingUser = null; window.fixturePendingTurn = null; return true;
            """)
        var armed = false
        var diagnostics: [String] = []
        fixture.transport.setFirstUserDiagnosticsObserverForTesting { diagnostics += $0 }
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect", !armed else { return }
            let installed = try? await self.evaluate(view, """
                if (!globalThis.__computaModelFirstProof) return false;
                const originalDigest = crypto.subtle.digest.bind(crypto.subtle);
                let replaceOnce = true;
                crypto.subtle.digest = async (...arguments_) => {
                    const result = await originalDigest(...arguments_);
                    if (replaceOnce) {
                        replaceOnce = false;
                        const root = document.querySelector('[data-message-author-role="user"]');
                        root.replaceWith(root.cloneNode(true));
                    }
                    return result;
                };
                return true;
                """, world: .world(name: "computa-chatgpt-model-v1")) as? Bool
            armed = installed == true
        }
        defer {
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            fixture.transport.setFirstUserDiagnosticsObserverForTesting(nil)
        }
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A private-only pin cannot authorize a crossed first-node replacement")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
        XCTAssertTrue(armed)
        let values = diagnostics.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertTrue(values.contains { $0["stage"] as? String == "adapter_rejected" })
        XCTAssertTrue(values.contains { $0["reason"] as? String == "snapshot_before_action" })
        let nativeStates = values.filter { $0["kind"] as? String == "first_user_native_state" }
        XCTAssertEqual(nativeStates.count, 2)
        XCTAssertTrue(nativeStates.allSatisfy { $0["fingerprintPresent"] as? Bool == false })
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created", "A later independent fresh proof must still be required for owned cleanup")
        try await assertHumanTabIntact(fixture)
    }

    func testAcknowledgedDelayedUserAppendRetainsDeferredChoiceAcrossToolContinuation() async throws {
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
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            XCTAssertFalse(readActionsAfterLatestAcknowledgement.contains("verifyModel"),
                "An acknowledged asynchronous append must not reopen the picker while its answer is running")
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(complete["sequence"] as? Int, sequence)
            XCTAssertEqual(complete["text"] as? String, sequence == 1 ? Self.fixtureToolReply : #"{"type":"message","text":"Fixture reply"}"#)
            try assertChoiceEvidence(complete, choice: choice)
            try await assertChoiceLedger(view, insertions: sequence, sends: sequence, selections: 1)
        }
        XCTAssertEqual(acknowledgements, 2)
        let race = try await evaluate(view, "return {opens: window.fixtureDelayedAppendCommits, renderedCounts: window.fixtureRaceRenderedCounts};") as? [String: Any]
        XCTAssertEqual(race?["opens"] as? Int, 2, "Both acknowledged Sends must produce exactly one delayed append")
        XCTAssertEqual(race?["renderedCounts"] as? [Int], [1, 2])
        XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
        let captured = try await capturedUserPrompts(view)
        XCTAssertEqual(captured?.map { $0.trimmingCharacters(in: .newlines) }, prompts)
        fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testAcknowledgedAppendCannotRefreshChangedFirstBodyOrWrongMarkerDuringDeferredRead() async throws {
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
                _ = try await waitForState("complete", fixture.transport, token: token)
                XCTFail("A model read must reject \(corruption), even when the new user count matches an acknowledged Send")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
            let race = try await evaluate(view, "return {opens: window.fixtureDelayedAppendCommits, renderedCounts: window.fixtureRaceRenderedCounts};") as? [String: Any]
            XCTAssertEqual(race?["opens"] as? Int, 2)
            XCTAssertEqual(race?["renderedCounts"] as? [Int], [1, 2])
            try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not replay the failed continuation"])
                XCTFail("A pending failed continuation cannot admit another Send")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
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
                try assertRunningOrVerifiedChoice(sent, choice: choice)
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
            XCTAssertEqual(observedRoutes, routes, "Both first-route creation and local promotion must arise from acknowledged delayed renders")
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

    func testChatGPTFirstSendRefreshesEmptyLocalAndPublicRoutesInOneUnboundProductChain() async throws {
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
        @MainActor final class ProductReadTrace {
            var acknowledgedSends = 0
            var firstSendReturned = false
            var localRoutes: [Bool] = []
        }
        let trace = ProductReadTrace()
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "submit" { trace.acknowledgedSends += 1 }
            guard action == "verifyProductMode", trace.acknowledgedSends == 1, !trace.firstSendReturned else { return }
            trace.localRoutes.append(EmbeddedWebModelTransport.Provider.chatgpt.isLocalConversation(view.url?.absoluteString))
            let index = trace.localRoutes.count - 1
            guard index < routes.count else { return }
            // This checkpoint precedes every native result/first-message bind.
            // Both edges cross the same product-only pre-acknowledgment read;
            // neither its route nor its body can become a lineage proof.
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
        trace.firstSendReturned = true
        XCTAssertEqual(firstSent["state"] as? String, "running")
        XCTAssertEqual(trace.acknowledgedSends, 1)
        XCTAssertEqual(trace.localRoutes, [false, true, false],
            "Empty, local and public reads must all occur before the first Send returns")
        try assertRunningOrVerifiedChoice(firstSent, choice: choice)
        let firstContext = try XCTUnwrap(firstSent["pendingSubmissionContext"] as? [String: Any])
        XCTAssertEqual(firstContext["firstUserFingerprint"] as? String, "",
            "A product-only pre-acknowledgment read cannot bind user lineage")
        XCTAssertEqual(firstContext["submittedPromptFingerprint"] as? String, "")
        XCTAssertEqual(view.url?.path, "/c/public-unbound-first-read")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let firstComplete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(firstComplete["text"] as? String, Self.fixtureToolReply)
        let firstProof = try XCTUnwrap(firstComplete["modelProofContext"] as? [String: Any])
        let firstFingerprint = try XCTUnwrap(firstProof["firstUserFingerprint"] as? String)
        XCTAssertEqual(firstFingerprint.count, 64)
        let secondSent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": #"{"type":"tool_results","results":[{"name":"exec_command","output":"fixture output"}]}"#])
        try assertRunningOrVerifiedChoice(secondSent, choice: choice)
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
                guard action == "verifyProductMode", acknowledgedSends == 1 else { return }
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
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.routeAfter)) }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
            XCTAssertTrue(fixture.browser.webView(for: fixture.humanID) === fixture.humanView)
            XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        }
    }

    func testRepeatedVerifiedRenderRemovalRevokesWithoutReplayingSend() async throws {
        let choice = Self.fixtureChoice(.chatgpt)
        let fixture = try Fixture(page: Self.acknowledgedAppendRacePage())
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        var acknowledged = false, rearmed = false, pageReads = 0, detachedVerifiedSequence = 0
        fixture.transport.setBeforePageResultValidationDetailedForTesting { action, enforceModel in
            pageReads += 1
            if action == "submit" {
                acknowledged = true
                _ = try? await self.evaluate(view, "window.fixtureRaceArmed = true; return true;")
            } else if action == "inspect", acknowledged, enforceModel, !rearmed {
                let proof = try? await self.evaluate(view, """
                    const record = globalThis.__computaChatSubmissionState?.lastVerified;
                    return { sequence: record?.sequence || 0, verified: record?.phase === 'verified' };
                    """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
                guard proof?["sequence"] as? Int == 1, proof?["verified"] as? Bool == true else { return }
                let removed = try? await self.evaluate(view, """
                    const user = document.querySelector('[data-message-author-role="user"]');
                    const turn = document.querySelector('[data-markdown-text-style="assistant-message"]')?.closest('section');
                    if (!user || !turn || window.fixtureDelayedAppendCommits !== 1) return false;
                    user.remove(); turn.remove();
                    window.fixturePendingUser = user; window.fixturePendingTurn = turn; window.fixtureRaceArmed = true;
                    return true;
                    """) as? Bool
                if removed == true { rearmed = true; detachedVerifiedSequence = 1 }
            }
        }
        defer { fixture.transport.setBeforePageResultValidationDetailedForTesting(nil) }
        let sent = try await fixturePhaseProbe("repeated_render_send", trace: true) {
            try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "One Send with a delayed acknowledged render"])
        }
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        do {
            _ = try await waitForState("complete", fixture.transport, token: token)
            XCTFail("A detached per-round body must not publish a completed answer")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
        XCTAssertTrue(rearmed, "The verified current body must be detached during an owned read")
        XCTAssertEqual(detachedVerifiedSequence, 1, "Only an already digest-proved per-round body is detached")
        let readsAtFailure = pageReads
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A revoked body claim must remain terminal")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
        XCTAssertEqual(pageReads, readsAtFailure, "Terminal polling must not dispatch another adapter read")
        let race = try await evaluate(view, """
            await new Promise(resolve => setTimeout(resolve, 40));
            return {commits: window.fixtureDelayedAppendCommits, renderedCounts: window.fixtureRaceRenderedCounts};
            """) as? [String: Any]
        XCTAssertEqual(race?["commits"] as? Int, 2)
        XCTAssertEqual(race?["renderedCounts"] as? [Int], [1, 1])
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed", "A later render cannot revive a revoked body claim for cleanup")
        XCTAssertTrue((finished["text"] as? String ?? "").isEmpty)
        try await assertHumanTabIntact(fixture, retaining: ownedID)
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
        try assertRunningOrVerifiedChoice(sent, choice: choice)
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
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
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
        let pending = try XCTUnwrap(sent["pendingSubmissionContext"] as? [String: Any])
        XCTAssertEqual(pending["firstUserFingerprint"] as? String, "")
        // Send acknowledges dispatch only. Establish the native first-message
        // binding through its normal read before testing replacement recovery.
        let bound = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(bound["state"] as? String, "running")
        let context = try XCTUnwrap(bound["pendingSubmissionContext"] as? [String: Any])
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
            window.fixtureRaceArmed = true;
            await new Promise(resolve => setTimeout(resolve, 40));
            return document.querySelectorAll('[data-message-author-role="user"]').length;
            """)
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must reject a user append without a pending Send"])
            XCTFail("A retained private submit claim cannot admit an unsolicited user count increment")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptUserCount)) }
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let race = try await evaluate(view, "return {opens: window.fixtureDelayedAppendCommits, renderedCounts: window.fixtureRaceRenderedCounts};") as? [String: Any]
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

    func testChatGPTPowerReadsRenderedMetadataInsideItsInputBoundary() async throws {
        let cases: [(String, String, Bool, Bool, Bool)] = [
            ("self_inert", "thumb.inert = true;", true, false, false),
            ("self_aria_hidden", "thumb.setAttribute('aria-hidden', 'true');", false, false, true),
            ("wrapper_inert", "wrapper.inert = true;", false, true, false),
            ("wrapper_aria_hidden", "wrapper.setAttribute('aria-hidden', 'true');", false, false, true)
        ]
        for (name, mutation, thumbInert, metadataInert, metadataHidden) in cases {
            let choice = Self.fixtureChoice(.chatgpt)
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            _ = try await evaluate(view, """
                const thumb = document.getElementById('fixture-chat-power-slider');
                const wrapper = document.getElementById('fixture-chat-power-visual');
                thumb.inert = false; thumb.removeAttribute('aria-hidden');
                wrapper.inert = false; wrapper.removeAttribute('aria-hidden');
                \(mutation)
                return true;
                """)
            let ready = try await waitForState("ready", fixture.transport, token: token)
            try assertChoiceEvidence(ready, choice: choice)
            try await assertChatPowerControl(view, index: 1, events: 1, thumbInert: thumbInert,
                                             metadataInertAncestor: metadataInert, metadataAriaHidden: metadataHidden)
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created", name)
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTInertThumbDoesNotAuthorizeInertOrDisabledPowerControls() async throws {
        let cases: [(String, String, EmbeddedWebModelTransport.Failure)] = [
            ("inert_power", "power.inert = true;", .modelUnverified),
            ("inert_ancestor", "power.parentElement.inert = true;", .modelUnverified),
            ("aria_hidden_power", "power.setAttribute('aria-hidden', 'true');", .modelUnverified),
            ("aria_hidden_ancestor", "power.parentElement.setAttribute('aria-hidden', 'true');", .modelUnverified),
            ("disabled_power", "power.setAttribute('aria-disabled', 'true');", .modelUnavailable),
            ("trigger_hidden_before_first_power_input", "document.getElementById('fixture-model-trigger').addEventListener('click', event => event.currentTarget.setAttribute('aria-hidden', 'true'));", .modelUnverified)
        ]
        for (name, mutation, expected) in cases {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            _ = try await evaluate(view, "const power = document.getElementById('fixture-chat-power-item'); \(mutation) return true;")
            do {
                _ = try await waitForState("ready", fixture.transport, token: token)
                XCTFail("Rendered metadata cannot authorize \(name)")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expected, name) }
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            let events = try await evaluate(view, "return {power: window.fixturePowerKeyEvents, thumb: window.fixturePowerThumbKeyEvents, wrongTarget: window.fixturePowerWrongTargetEvents};") as? [String: Int]
            XCTAssertEqual(events, ["power": 0, "thumb": 0, "wrongTarget": 0], name)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTUnknownClosedPowerAndContradictoryVisibleSliderNeverAdmitSelectionOrSend() async throws {
        for condition in ["unknown_header", "visible_slider_disagrees"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            try await waitForFixture(view)
            _ = try await evaluate(view, """
                window.fixtureContradictoryPowerOpens = 0;
                if ('\(condition)' === 'unknown_header')
                  document.getElementById('fixture-model-header').textContent = 'Unknown effort';
                else document.getElementById('fixture-model-trigger').addEventListener('click', () => {
                  window.fixtureContradictoryPowerOpens++;
                  window.fixtureChatPowerThumb.setAttribute('aria-valuenow', '4');
                });
                return true;
                """)
            do {
                _ = try await waitForState("ready", fixture.transport, token: token)
                XCTFail("A fresh power proof must reject \(condition)")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelUnverified, condition) }
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
            let effects = try await evaluate(view, "return {power: window.fixturePowerKeyEvents, changed: window.fixtureContradictoryPowerOpens};") as? [String: Int]
            XCTAssertEqual(effects?["power"], 0, "Contradiction is not authority to repair the slider")
            XCTAssertEqual(effects?["changed"], condition == "unknown_header" ? 0 : 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTGenericClosedHeaderRequiresFreshMenusThroughSelectionSendAndResponse() async throws {
        for (key, label) in [("instant", "Instant"), ("medium", "Medium")] {
            let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/" + key, label: label)
            let fixture = try Fixture(page: Self.genericClosedChatPowerPage())
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            let ready = try await waitForState("ready", fixture.transport, token: token)
            try assertChoiceEvidence(ready, choice: choice)
            let beforeSend = try await evaluate(view, """
                return {header: document.getElementById('fixture-model-header').textContent,
                  powerViews: window.fixtureModelPowerOpenCount, familyViews: window.fixtureModelFamilyOpenCount,
                  selected: document.querySelector('[data-fixture-model][aria-checked="true"]')?.dataset.fixtureModel ?? null};
                """) as? [String: Any]
            XCTAssertEqual(beforeSend?["header"] as? String, "Thinking effort")
            XCTAssertGreaterThanOrEqual(beforeSend?["powerViews"] as? Int ?? 0, 2,
                "Every generic proof must read Power again after the family panel")
            var actions: [String] = []
            fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
            let prompt = "Synthetic generic closed-header " + key + " request"
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
            try assertRunningOrVerifiedChoice(sent, choice: choice)
            let complete = try await waitForState("complete", fixture.transport, token: token)
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            try assertChoiceEvidence(complete, choice: choice)
            XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1)
            XCTAssertEqual(actions.filter { $0 == "submit" }.count, 1)
            if key == "medium" { XCTAssertTrue(actions.contains("prepare")) }
            let prompts = try await capturedUserPrompts(view)
            // WK contenteditable readback may preserve its one terminal line
            // break; every other source byte and the single-message count stay exact.
            XCTAssertTrue(prompts == [prompt] || prompts == [prompt + "\n"])
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTCompositeHeaderRequiresRenderedPowerProofThroughSendAndResponse() async throws {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let page = Self.modelChoicePage(.chatgpt, initiallySelectTarget: true)
            .replacingOccurrences(of: "</body>", with: """
                <script>
                window.fixtureChatPowerThumb.setAttribute('aria-valuenow', '0');
                window.fixtureModelUpdateHeader = () => {
                  const header = document.getElementById('fixture-model-header');
                  header.setAttribute('aria-hidden', 'true');
                  header.replaceChildren();
                  if (document.getElementById('fixture-model-trigger').getAttribute('aria-expanded') === 'true') {
                    header.textContent = 'Thinking effort';
                    return;
                  }
                  const prefix = document.createElement('span'), power = document.createElement('span');
                  prefix.style.display = power.style.display = 'block';
                  prefix.textContent = 'Thinking effort';
                  power.textContent = ['Instant', 'Medium', 'High', 'Extra High', 'Pro'][Number(window.fixtureChatPowerThumb.getAttribute('aria-valuenow'))];
                  header.append(prefix, power);
                };
                window.fixtureModelUpdateHeader();
                </script></body>
                """)
        let fixture = try Fixture(page: page)
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        let ready = try await waitForState("ready", fixture.transport, token: token)
        try assertChoiceEvidence(ready, choice: choice)
        let header = try await evaluate(view, #"""
            const trigger = document.getElementById('fixture-model-trigger');
            const label = document.getElementById('fixture-model-header');
            return {rendered: trigger.innerText.replace(/\s+/g, ' ').trim(),
              text: label.textContent, suppressed: label.getAttribute('aria-hidden'),
              opens: window.fixtureModelTriggerClicks, powerInputs: window.fixturePowerKeyEvents};
            """#) as? [String: Any]
        XCTAssertEqual(header?["rendered"] as? String, "Thinking effort Instant")
        XCTAssertEqual(header?["text"] as? String, "Thinking effortInstant")
        XCTAssertEqual(header?["suppressed"] as? String, "true")
        XCTAssertGreaterThan(header?["opens"] as? Int ?? 0, 0, "The rendered composite cannot replace associated menu proof")
        XCTAssertEqual(header?["powerInputs"] as? Int, 0)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        let prompt = "Synthetic rendered composite-header request"
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        let prompts = try await capturedUserPrompts(view)
        XCTAssertTrue(prompts == [prompt] || prompts == [prompt + "\n"], "Only the existing terminal editor line break may differ")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTEmptyInitialHeaderHydratesBeforeAnyPickerInputThenVerifiesSendAndResponse() async throws {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, initiallySelectTarget: true))
        defer { fixture.shutdown() }
        var diagnostics: [String] = []
        fixture.transport.setModelDiagnosticsObserverForTesting { diagnostics.append($0) }
        defer { fixture.transport.setModelDiagnosticsObserverForTesting(nil) }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            window.fixtureChatPowerThumb.setAttribute('aria-valuenow', '0');
            document.getElementById('fixture-model-header').textContent = '';
            return true;
            """)
        let preparation = Task { @MainActor in
            let ready = try await self.waitForState("ready", fixture.transport, token: token)
            try self.assertChoiceEvidence(ready, choice: choice)
        }
        defer { preparation.cancel() }
        // Observe the actual native clock registration while the private-world
        // selector is suspended. Elapsed time alone does not prove the wait.
        let registrationDeadline = ContinuousClock.now + .seconds(3)
        var registered = false
        while ContinuousClock.now < registrationDeadline {
            let snapshot = fixture.browser.modelDiagnosticSnapshot(tabID: tabID)
            if snapshot.contains("model_wait") && snapshot.contains("clocksPending=1") {
                registered = true
                break
            }
            await Task.yield()
        }
        guard registered else { XCTFail("Empty-header native deadline was not registered"); throw FixtureFailure.timeout }
        let pending = try await evaluate(view, """
            return {empty: document.getElementById('fixture-model-header').textContent === '',
              opens: window.fixtureModelTriggerClicks, power: window.fixturePowerKeyEvents};
            """) as? [String: Any]
        XCTAssertEqual(pending?["empty"] as? Bool, true)
        XCTAssertEqual(pending?["opens"] as? Int, 0)
        XCTAssertEqual(pending?["power"] as? Int, 0)
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        _ = try await evaluate(view, "document.getElementById('fixture-model-header').textContent = 'Instant'; return true;")
        try await preparation.value
        let readiness = try diagnostics.compactMap { line -> [String: Any]? in
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return (value?["chatHeader"] as? [String: Any])?["readiness"] as? [String: Any]
        }
        XCTAssertTrue(readiness.contains { $0["startedEmpty"] as? Bool == true && $0["outcome"] as? String == "recognized" })
        let prompt = "Synthetic empty-header hydration request"
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        let prompts = try await capturedUserPrompts(view)
        XCTAssertTrue(prompts == [prompt] || prompts == [prompt + "\n"], "Only the existing terminal editor line break may differ")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTGenericClosedHeaderRejectsPostFamilyPowerResetWithoutRepairOrSend() async throws {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let fixture = try Fixture(page: Self.genericClosedChatPowerPage(resetAfterFamily: true))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        do {
            _ = try await waitForState("ready", fixture.transport, token: token)
            XCTFail("A generic label cannot hide a family-induced power reset")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
        let effects = try await evaluate(view, "return {events: window.fixturePowerKeyEvents, value: Number(window.fixtureChatPowerThumb.getAttribute('aria-valuenow'))};") as? [String: Int]
        XCTAssertEqual(effects?["events"], 1, "Only the originally requested Medium-to-Instant input may run")
        XCTAssertEqual(effects?["value"], 4, "A mismatched final Power must not be repaired")
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTClosedPowerDriftIncludingRestoreCannotAdmitReadOnlySend() async throws {
        for condition in ["unknown_before_read", "known_before_read", "restored_before_read", "known_after_close", "restored_after_close"] {
            let choice = Self.fixtureChoice(.chatgpt)
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            try await assertChatClosedPowerAndRememberedFamily(view, power: "Medium")
            _ = try await evaluate(view, """
                window.fixtureClosedHeaderDrifts = 0;
                const corrupt = () => {
                  const text = document.getElementById('fixture-model-header').firstChild;
                  if (!text || text.nodeType !== Node.TEXT_NODE || text.data !== 'Medium')
                    throw new Error('Expected the actual closed Medium text node');
                  window.fixtureClosedHeaderDrifts++;
                  text.data = '\(condition)' === 'unknown_before_read' ? 'Unknown power' : 'High';
                  if ('\(condition)'.startsWith('restored')) text.data = 'Medium';
                };
                if ('\(condition)'.endsWith('after_close')) {
                  const afterClose = event => {
                    if (event.key !== 'Escape' || document.getElementById('fixture-model-trigger').getAttribute('aria-expanded') !== 'false') return;
                    document.removeEventListener('keydown', afterClose);
                    corrupt();
                  };
                  document.addEventListener('keydown', afterClose);
                } else corrupt();
                return true;
                """)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "Must not send after closed power proof changes"])
                XCTFail("Closed power drift cannot authorize insertion or Send: \(condition)")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure,
                    condition == "unknown_before_read" ? .modelUnverified : .modelMismatch, condition)
            }
            let effects = try await evaluate(view, "return {drifts: window.fixtureClosedHeaderDrifts, power: window.fixturePowerKeyEvents};") as? [String: Int]
            XCTAssertEqual(effects, ["drifts": 1, "power": 1], "No read-only power repair or extra key is authorized")
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTFreshFinalClosedPowerMismatchCannotRepairOrSend() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await evaluate(view, """
            window.fixtureFinalPowerDrifts = 0;
            const update = window.fixtureModelUpdateHeader;
            window.fixtureModelUpdateHeader = () => {
              update();
              if (window.fixtureModelSelectionClicks === 1
                && document.getElementById('fixture-model-trigger').getAttribute('aria-expanded') === 'false') {
                document.getElementById('fixture-model-header').textContent = 'High';
                window.fixtureFinalPowerDrifts++;
              }
            };
            return true;
            """)
        do {
            _ = try await waitForState("ready", fixture.transport, token: token)
            XCTFail("A final closed label different from the requested power must not claim ready")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
        let effects = try await evaluate(view, "return {drifts: window.fixtureFinalPowerDrifts, power: window.fixturePowerKeyEvents};") as? [String: Int]
        XCTAssertEqual(effects, ["drifts": 1, "power": 1], "The fresh mutation allowance cannot retry a contradictory completed selection")
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTNewNestedHeaderMutationRetainsHistoricalOwnershipAfterSameBatchDetach() async throws {
        for changeAndRestore in [false, true] {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let choice = Self.fixtureChoice(.chatgpt)
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            _ = try await waitForState("ready", fixture.transport, token: token)
            try await assertChatClosedPowerAndRememberedFamily(view, power: "Medium")
            let mutation = try await evaluate(view, """
                const trigger = document.getElementById('fixture-model-trigger');
                const original = [...trigger.childNodes];
                const wrapper = document.createElement('span'), inner = document.createElement('span');
                const text = document.createTextNode('Medium');
                // These are actual WebKit MutationRecords, delivered after the
                // whole synchronous batch. By delivery time no changed node
                // retains its parent chain to the exact owned header.
                trigger.replaceChildren(wrapper);
                wrapper.appendChild(inner); inner.appendChild(text);
                const attachedDuringMutation = trigger.contains(text);
                if (\(changeAndRestore ? "true" : "false")) { text.data = 'High'; text.data = 'Medium'; }
                text.remove(); inner.remove(); wrapper.remove();
                trigger.append(...original);
                const result = {attachedDuringMutation, detached: !text.parentNode && !inner.parentNode && !wrapper.parentNode,
                  restoredOriginal: trigger.childNodes.length === original.length
                    && [...trigger.childNodes].every((node, index) => node === original[index]),
                  closed: trigger.getAttribute('aria-expanded') === 'false', header: trigger.innerText};
                await Promise.resolve();
                return result;
                """) as? [String: Any]
            XCTAssertEqual(mutation?["attachedDuringMutation"] as? Bool, true)
            XCTAssertEqual(mutation?["detached"] as? Bool, true)
            XCTAssertEqual(mutation?["restoredOriginal"] as? Bool, true)
            XCTAssertEqual(mutation?["closed"] as? Bool, true)
            XCTAssertEqual(mutation?["header"] as? String, "Medium", "The current label alone cannot reveal a prior change-and-restore")
            if changeAndRestore {
                do {
                    _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                        "prompt": "Must reject changed then detached power proof before insertion"])
                    XCTFail("A detached node that belonged to the owned header during mutation must retain its drift evidence")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
                try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            } else {
                let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "Continue after a same-power header remount"])
                try assertRunningOrVerifiedChoice(sent, choice: choice)
                let complete = try await waitForState("complete", fixture.transport, token: token)
                try assertChoiceEvidence(complete, choice: choice)
                XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
                try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            }
            try await assertChatPowerControl(view, index: 1, events: 1)
            XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTStandbyRefillWaitsForFirstOwnedNonemptyResponse() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), isolatedInference: true)
        defer { fixture.shutdown() }
        fixture.transport.setChatGPTPrewarmingEnabled(true)
        let preparedID = await fixture.browser.awaitChatGPTInferencePrewarmForTesting()
        let ownedID = try XCTUnwrap(preparedID)
        let ownedView = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await waitForFixture(ownedView)
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertEqual(fixture.isolatedViews.count, 1, "Start still consumes the existing blank root")
        _ = try await evaluate(ownedView, """
            document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
              const body = document.querySelector('#messages section [data-markdown-text-style="assistant-message"] [data-markdown-text-style="assistant-message"]');
              const reply = body.textContent;
              body.textContent = '';
              const stop = document.createElement('button'); stop.id = 'fixture-refill-stop';
              stop.setAttribute('data-testid', 'stop-button'); stop.textContent = 'Stop generating';
              document.body.appendChild(stop);
              window.fixtureReleaseStandbyReply = () => { body.textContent = reply; return true; };
            }, {once:true}); return true;
            """)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Keep the next blank page out of this owned answer's initial generation"])
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        for _ in 0..<2 {
            let pending = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(pending["state"] as? String, "running")
        }
        let beforeText = await fixture.browser.awaitChatGPTInferencePrewarmForTesting()
        XCTAssertNil(beforeText, "Acknowledged Send and empty-answer reads cannot refill the standby")
        XCTAssertEqual(fixture.isolatedViews.count, 1)
        try await assertChoiceLedger(ownedView, insertions: 1, sends: 1, selections: 1)

        _ = try await evaluate(ownedView, "return window.fixtureReleaseStandbyReply();")
        let firstPositive = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(firstPositive["state"] as? String, "running", "The busy answer still needs ordinary completion proof")
        let refillID = await fixture.browser.awaitChatGPTInferencePrewarmForTesting()
        let standbyID = try XCTUnwrap(refillID)
        XCTAssertNotEqual(standbyID, ownedID)
        let standby = try XCTUnwrap(fixture.browser.webView(for: standbyID))
        try await waitForFixture(standby)
        XCTAssertEqual(fixture.isolatedViews.count, 2, "The first owned nonempty answer starts one standby")
        XCTAssertFalse(standby.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(standby.configuration.websiteDataStore === ownedView.configuration.websiteDataStore)
        XCTAssertFalse(standby.configuration.websiteDataStore === fixture.humanView.configuration.websiteDataStore)
        let unowned = try await evaluate(standby, "return typeof globalThis.__computaModelOwner === 'undefined';",
            world: .world(name: "computa-chatgpt-model-v1"))
        XCTAssertEqual(unowned as? Bool, true, "Refill creates no transport owner or inference")
        try await assertChoiceLedger(standby, insertions: 0, sends: 0, selections: 0)
        for _ in 0..<3 {
            let running = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(running["state"] as? String, "running")
        }
        let retainedStandby = await fixture.browser.awaitChatGPTInferencePrewarmForTesting()
        XCTAssertEqual(retainedStandby, standbyID)
        XCTAssertEqual(fixture.isolatedViews.count, 2, "Repeated positive reads cannot create another standby")
        try await assertChoiceLedger(standby, insertions: 0, sends: 0, selections: 0)

        _ = try await evaluate(ownedView, "document.getElementById('fixture-refill-stop').remove(); return true;")
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        try await assertChoiceLedger(ownedView, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertTrue(fixture.browser.webView(for: standbyID) === standby,
                      "Finishing the owned turn preserves the untouched standby")
        fixture.transport.setChatGPTPrewarmingEnabled(false)
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTPrewarmedRootIsConsumedOnceAndStillRequiresFullTransportProof() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), isolatedInference: true)
        defer { fixture.shutdown() }
        fixture.browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
        let preparedID = await fixture.browser.awaitChatGPTInferencePrewarmForTesting()
        let warmID = try XCTUnwrap(preparedID)
        let warmView = try XCTUnwrap(fixture.browser.webView(for: warmID))
        try await waitForFixture(warmView)
        XCTAssertEqual(fixture.isolatedViews.count, 1)
        XCTAssertFalse(warmView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(warmView.configuration.websiteDataStore === fixture.humanView.configuration.websiteDataStore)
        let unowned = try await evaluate(warmView, "return typeof globalThis.__computaModelOwner === 'undefined';",
            world: .world(name: "computa-chatgpt-model-v1"))
        XCTAssertEqual(unowned as? Bool, true, "Preloading cannot create transport ownership or model proof")
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertEqual(fixture.isolatedViews.count, 1, "Start must consume the existing private view without reloading it")
        XCTAssertEqual(fixture.isolatedViews.first?.requestLoadCount, 1)
        XCTAssertTrue(fixture.browser.webView(for: warmID) === warmView)
        let owner = try await evaluate(warmView, "return globalThis.__computaModelOwner;",
            world: .world(name: "computa-chatgpt-model-v1"))
        XCTAssertEqual(owner as? String, token)
        try await assertChoiceLedger(warmView, insertions: 0, sends: 0, selections: 1)
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Use this fresh preloaded page only after all ordinary checks"])
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        try await assertChoiceLedger(warmView, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: warmID))
        try await assertHumanTabIntact(fixture)

        let second = try await startChoice(choice, in: fixture)
        let secondToken = try XCTUnwrap(second["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: secondToken)
        XCTAssertEqual(fixture.isolatedViews.count, 2, "A consumed or submitted page can never be claimed again")
        let secondID = try XCTUnwrap(fixture.browser.tabs.first(where: { $0.id != fixture.humanID })?.id)
        XCTAssertNotEqual(secondID, warmID)
        let secondView = try XCTUnwrap(fixture.browser.webView(for: secondID))
        XCTAssertFalse(secondView === warmView)
        try await assertChoiceLedger(secondView, insertions: 0, sends: 0, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": secondToken])
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTDisabledPrewarmingKeepsColdStartAndOrdinaryProof() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), isolatedInference: true)
        defer { fixture.shutdown() }
        fixture.browser.setChatGPTInferencePrewarmingEnabled(false, admit: {})
        let absent = await fixture.browser.awaitChatGPTInferencePrewarmForTesting()
        XCTAssertNil(absent)
        XCTAssertTrue(fixture.isolatedViews.isEmpty)
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        _ = try await waitForState("ready", fixture.transport, token: token)
        XCTAssertEqual(fixture.isolatedViews.count, 1)
        let view = try XCTUnwrap(fixture.isolatedViews.first)
        XCTAssertEqual(view.requestLoadCount, 1)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Disabled prewarming keeps the original cold inference path"])
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTPrewarmedRootCannotBypassModelOrWorkDriftBeforeSend() async throws {
        for drift in ["model", "work"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), isolatedInference: true)
            defer { fixture.shutdown() }
            fixture.browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
            let preparedID = await fixture.browser.awaitChatGPTInferencePrewarmForTesting()
            let warmID = try XCTUnwrap(preparedID)
            let view = try XCTUnwrap(fixture.browser.webView(for: warmID))
            try await waitForFixture(view)
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            _ = try await waitForState("ready", fixture.transport, token: token)
            XCTAssertEqual(fixture.isolatedViews.count, 1)
            let mutation = drift == "model"
                ? "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;"
                : "document.getElementById('fixture-composer-mode').hidden = false; document.getElementById('fixture-chat-mode').setAttribute('aria-pressed','false'); document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true'); return true;"
            let changed = try await evaluate(view, mutation)
            XCTAssertEqual(changed as? Bool, true)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "A warm view cannot authorize changed model or Work mode"])
                XCTFail("Prewarming cannot bypass the current product/model checks")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure,
                    drift == "model" ? .modelMismatch : .productModeUnverified)
            }
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, drift == "work" ? "failed" : "not_created")
            try await assertHumanTabIntact(fixture, retaining: drift == "work" ? warmID : nil)
        }
    }

    func testChatGPTPrewarmedRootWithExistingUserHistoryCannotBecomeReady() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt), isolatedInference: true)
        defer { fixture.shutdown() }
        fixture.browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
        let preparedID = await fixture.browser.awaitChatGPTInferencePrewarmForTesting()
        let warmID = try XCTUnwrap(preparedID)
        let view = try XCTUnwrap(fixture.browser.webView(for: warmID))
        try await waitForFixture(view)
        let changed = try await evaluate(view, """
            const message = document.createElement('div');
            message.setAttribute('data-message-author-role', 'user');
            message.textContent = 'Unowned synthetic history';
            document.getElementById('messages').appendChild(message);
            return document.querySelectorAll('[data-message-author-role="user"]').length;
            """)
        XCTAssertEqual(changed as? Int, 1)
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A loaded root is not proof that the page is fresh")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptUserCount))
        }
        XCTAssertEqual(fixture.isolatedViews.count, 1, "Do not silently replace a rejected claimed page")
        try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 0)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: warmID), "No native Send or temporary setup occurred; retire only this private view")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTEditorContextRecheckUsesModelThenFinalProductOnce() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        var actions: [String] = []
        fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Preserve both current proofs while avoiding a duplicate product read"])
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        let insert = try XCTUnwrap(actions.firstIndex(of: "insert"))
        let ready = try XCTUnwrap(actions.firstIndex(of: "sendReady"))
        let submit = try XCTUnwrap(actions.firstIndex(of: "submit"))
        XCTAssertEqual(Array(actions[insert..<ready]), ["insert", "verifyModel", "verifyProductMode"])
        // The button can enable after another read-only readiness cycle.
        // Each cycle must retain the exact complete verification chain.
        let readiness = Array(actions[ready..<submit])
        let readinessCycle = ["sendReady", "verifyModel", "verifyProductMode"]
        XCTAssertFalse(readiness.isEmpty)
        XCTAssertEqual(readiness.count % readinessCycle.count, 0)
        XCTAssertEqual(readiness, (0..<(readiness.count / readinessCycle.count)).flatMap { _ in readinessCycle })
        XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1)
        XCTAssertEqual(actions.filter { $0 == "submit" }.count, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        // A retained complete session has existing lineage. Its append keeps
        // the original independent product/model ordering unchanged.
        actions.removeAll()
        fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Retain the original completed-session append checks"])
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        let nextInsert = try XCTUnwrap(actions.firstIndex(of: "insert"))
        let nextReady = try XCTUnwrap(actions.firstIndex(of: "sendReady"))
        let nextSubmit = try XCTUnwrap(actions.firstIndex(of: "submit"))
        XCTAssertEqual(Array(actions[nextInsert..<nextReady]), ["insert", "verifyProductMode", "verifyModel", "verifyProductMode"])
        let nextReadiness = Array(actions[nextReady..<nextSubmit])
        let originalCycle = ["sendReady", "verifyProductMode", "verifyModel", "verifyProductMode"]
        XCTAssertFalse(nextReadiness.isEmpty)
        XCTAssertEqual(nextReadiness.count % originalCycle.count, 0)
        XCTAssertEqual(nextReadiness, (0..<(nextReadiness.count / originalCycle.count)).flatMap { _ in originalCycle })
        XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1)
        XCTAssertEqual(actions.filter { $0 == "submit" }.count, 1)
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        let nextComplete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(nextComplete, choice: choice)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTEditorContextRecheckRejectsOriginalAndNestedCallbackDrift() async throws {
        let cases = [("insert", "original", "model"), ("sendReady", "original", "model"),
            ("insert", "original", "work"), ("sendReady", "original", "transient_work"),
            ("insert", "model_callback", "work"), ("sendReady", "model_callback", "temporary"),
            ("sendReady", "model_callback", "owner")]
        for (stage, boundary, drift) in cases {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            var entered = false, crossed = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == stage { entered = true }
                guard entered, !crossed, action == (boundary == "original" ? stage : "verifyModel") else { return }
                crossed = true
                let mutation: String
                switch drift {
                case "model": mutation = "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;"
                case "owner": mutation = "globalThis.__computaModelOwner = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; return true;"
                case "temporary": mutation = "const node = document.querySelector('[aria-label=\"Turn off temporary chat\"]'); if (!node) return false; node.remove(); return true;"
                default: mutation = """
                    document.getElementById('fixture-composer-mode').hidden = false;
                    document.getElementById('fixture-chat-mode').setAttribute('aria-pressed', 'false');
                    document.getElementById('fixture-work-mode').setAttribute('aria-pressed', 'true');
                    \(drift == "transient_work" ? "document.getElementById('fixture-work-mode').setAttribute('aria-pressed', 'false'); document.getElementById('fixture-chat-mode').setAttribute('aria-pressed', 'true');" : "")
                    return true;
                    """
                }
                let changed = try? await self.evaluate(view, mutation,
                    world: drift == "owner" ? .world(name: "computa-chatgpt-model-v1") : .page)
                XCTAssertEqual(changed as? Bool, true)
            }
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "Never publish a stale editor context or replay its Send"])
                XCTFail("The \(stage)/\(boundary)/\(drift) change must fail closed")
            } catch {
                let expected: EmbeddedWebModelTransport.Failure = drift == "model" ? .modelMismatch
                    : drift == "owner" ? .ownershipFailure(.javaScriptOwner)
                    : drift == "temporary" ? .ownershipFailure(.javaScriptSubmission) : .productModeUnverified
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expected, "\(stage)/\(boundary)/\(drift)")
            }
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertTrue(crossed)
            try await assertChoiceLedger(view, insertions: 1, sends: 0, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            let retained = drift == "model" ? nil : fixture.createdTabs.last
            XCTAssertEqual(finished["cleanup"] as? String, drift == "model" ? "not_created" : "failed",
                           "\(stage)/\(boundary)/\(drift)")
            try await assertHumanTabIntact(fixture, retaining: retained)
        }
    }

    func testChatGPTEditorContextRecheckKeepsTheOriginalDeadlineBeforeAnyFreshRead() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        var crossed = false
        var actions: [String] = []
        fixture.transport.setBeforePageResultValidationForTesting { action in
            actions.append(action)
            guard action == "insert", !crossed else { return }
            crossed = true
            // page() allocates ten seconds once. This already completed native
            // callback cannot grant a new ten-second child verification budget.
            try? await Task.sleep(for: .milliseconds(10_050))
        }
        do {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Do not renew the original editor deadline"])
            XCTFail("The original elapsed deadline must reject before fresh verification or Send")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .pageUnavailable) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertTrue(crossed); XCTAssertEqual(actions.last, "insert")
        try await assertChoiceLedger(view, insertions: 1, sends: 0, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTEditorContextRecheckCancellationCannotReachFinalProductOrSend() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        var inserted = false, blocked = false
        var actions: [String] = []
        fixture.transport.setBeforePageResultValidationForTesting { action in
            actions.append(action)
            if action == "insert" { inserted = true }
            guard inserted, action == "verifyModel", !blocked else { return }
            blocked = true
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let sending = Task<Void, Error> { _ = try await self.call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Cancellation cannot publish the shared verification or send"] ) }
        let until = ContinuousClock.now + .seconds(10)
        while !blocked && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        sending.cancel()
        do { _ = try await sending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertTrue(blocked); XCTAssertEqual(actions.last, "verifyModel")
        try await assertChoiceLedger(view, insertions: 1, sends: 0, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTInternalPrepareDefersOnlyItsDuplicateModelReadToInsert() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        var actions: [String] = []
        fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "Prepare once and keep the atomic insert model proof"])
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        try assertRunningOrVerifiedChoice(sent, choice: choice)
        let prepareIndex = try XCTUnwrap(actions.firstIndex(of: "prepare"))
        let insertIndex = try XCTUnwrap(actions.firstIndex(of: "insert"))
        XCTAssertLessThan(prepareIndex, insertIndex)
        let between = Array(actions[(prepareIndex + 1)..<insertIndex])
        XCTAssertTrue(between.contains("verifyProductMode"), "The native post-prepare product check remains")
        XCTAssertFalse(between.contains("verifyModel"), "Insert supplies the next full proof before editing")
        XCTAssertEqual(actions.filter { $0 == "prepare" }.count, 1)
        XCTAssertEqual(actions.filter { $0 == "insert" }.count, 1)
        XCTAssertTrue(actions.contains("verifyModel"), "Other editor-stage model rechecks remain enabled")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        try assertChoiceEvidence(complete, choice: choice)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTPrepareBoundaryModelAndWorkDriftCannotReachEditorOrSend() async throws {
        for drift in ["model", "work"] {
            let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
            defer { fixture.shutdown() }
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            _ = try await waitForState("ready", fixture.transport, token: token)
            let generation = fixture.browser.documentGeneration(for: ownedID)
            var changed = false
            var actions: [String] = []
            fixture.transport.setBeforePageResultValidationForTesting { action in
                actions.append(action)
                guard action == "prepare", !changed else { return }
                changed = true
                let script = drift == "model"
                    ? "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;"
                    : "document.getElementById('fixture-composer-mode').hidden = false; document.getElementById('fixture-chat-mode').setAttribute('aria-pressed','false'); document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true'); return true;"
                let applied = try? await self.evaluate(view, script)
                XCTAssertEqual(applied as? Bool, true)
            }
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "Reject drift after focus and before the first editor mutation"])
                XCTFail("A stale prepare observation cannot permit input")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure,
                    drift == "model" ? .modelMismatch : .productModeUnverified)
            }
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertTrue(changed)
            XCTAssertEqual(fixture.browser.documentGeneration(for: ownedID), generation)
            if drift == "model" {
                XCTAssertTrue(actions.contains("insert"), "The full insert precheck rejects the drift before its input")
            } else {
                XCTAssertFalse(actions.contains("insert"), "The retained native product check rejects Work first")
            }
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, drift == "work" ? "failed" : "not_created")
            try await assertHumanTabIntact(fixture, retaining: drift == "work" ? ownedID : nil)
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
            if provider == .chatgpt {
                try await assertModelMismatchBeforePublication(fixture.transport, token: token, choice: Self.fixtureChoice(provider))
            } else {
                do {
                    _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                    XCTFail("A substituted model must not publish a response")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch) }
            }
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
            // The initial inspection intentionally precedes automatic family
            // selection. Change an actual checked plain family after the
            // selection acknowledgment, before its native readiness admission.
            guard action == "selectModel", !changed else { return }
            changed = true
            _ = try? await self.evaluate(view, "window.fixtureModelSelect('GPT-5.5'); return true;")
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
            let advertised = provider == .chatgpt ? WebsiteModelChoice.ChatGPTPower.allCases.map {
                $0 == .pro ? "GPT-6 Pro" : $0.label
            } : Self.choiceLabels(provider)
            XCTAssertEqual(choices.map(\.label), advertised)
            XCTAssertEqual(choices.map(\.key), provider == .chatgpt
                ? WebsiteModelChoice.ChatGPTPower.allCases.map(\.modelKey) : advertised)
            XCTAssertTrue(choices.allSatisfy { $0.provider == provider.rawValue && $0.isValid })
            try await assertChoiceLedger(view, insertions: 0, sends: 0, selections: provider == .chatgpt ? 1 : 0)
            let clicks = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
            let escapes = try await evaluate(view, "return {attempts: window.fixtureModelEscapeEvents, closed: window.fixtureModelEscapeClosures};") as? [String: Int]
            if provider == .chatgpt {
                XCTAssertEqual(clicks, 2, "Discovery selects the latest family once, then verifies active Family bracketed by the closed power header")
                XCTAssertEqual(escapes, ["attempts": 1, "closed": 1], "The family click closes once; the one fresh joint proof read dispatches one acknowledged Escape")
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

        // Ordinary inference cannot use its same-origin untouched sign-in
        // disposal receipt for an external Google identity-provider document.
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
        try await assertChoiceLedger(discoveryView, insertions: 0, sends: 0, selections: 1)
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
        XCTAssertEqual(choices.map(\.label), WebsiteModelChoice.ChatGPTPower.allCases.map { $0 == .pro ? "GPT-6 Pro" : $0.label })
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
        let ready = try await waitForState("ready", fixture.transport, token: token)
        let model = try WebsiteModelEvidence.parse(ready["modelEvidence"], provider: "gemini", expected: nil)
        XCTAssertEqual(model.selected.label, "3.1 Pro", "A bare start pins the observed current family, without choosing the fixture target")
        XCTAssertEqual(model.source, "checked_model_option")
        let readiness = try await evaluate(view, "return {choices: window.fixtureModelSelectionClicks, opens: window.fixtureModelTriggerClicks, closed: document.getElementById('fixture-model-trigger').getAttribute('aria-expanded') === 'false', sends: window.fixturePrompts.length};") as? [String: Any]
        XCTAssertEqual(readiness?["choices"] as? Int, 0)
        XCTAssertGreaterThan(readiness?["opens"] as? Int ?? 0, 0)
        XCTAssertEqual(readiness?["closed"] as? Bool, true)
        XCTAssertEqual(readiness?["sends"] as? Int, 0)
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
        let pendingProof = try XCTUnwrap(sent["modelProofContext"] as? [String: Any])
        XCTAssertEqual(pendingProof["submittedPromptFingerprint"] as? String, "", "A reverified previous body cannot prove the pending second prompt")
        let beforeCount = try await evaluate(view, "return document.querySelectorAll('user-query').length;") as? Int
        XCTAssertEqual(beforeCount, 1, "The second click is acknowledged before its user bubble appears")
        try await armFixtureAppendDuringDigest(view)
        let observedRevision = try await fixture.transport.changeRevision(sessionToken: token)
        let revision = try XCTUnwrap(observedRevision)
        var inspectedProofSequences: [Int] = []
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect" else { return }
            let sequence = try? await self.evaluate(view, "return globalThis.__computaGeminiSubmissionState?.lastVerified?.sequence ?? 0;",
                world: .world(name: "computa-chatgpt-model-v1")) as? Int
            if let sequence { inspectedProofSequences.append(sequence) }
        }
        defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
        let refreshed = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertEqual(inspectedProofSequences, [1, 2], "Discard the crossed previous-body read, then perform exactly one full inspect proving body two")
        XCTAssertEqual(refreshed["state"] as? String, "running")
        XCTAssertEqual(refreshed["sequence"] as? Int, 2)
        XCTAssertEqual(refreshed["text"] as? String, #"{"type":"message","text":"Appended fixture reply"}"#,
                       "The returned snapshot comes only from the fresh second-body proof and its distinct response")
        let refreshedProof = try XCTUnwrap(refreshed["modelProofContext"] as? [String: Any])
        XCTAssertEqual(refreshedProof["submittedPromptFingerprint"] as? String,
                       EmbeddedWebModelTransport.promptFingerprint("Append this after the send acknowledgment"))
        XCTAssertEqual(refreshedProof["responseCount"] as? Int, 2)
        let afterCount = try await evaluate(view, "return document.querySelectorAll('user-query').length;") as? Int
        XCTAssertEqual(afterCount, 2)
        let notifiedRevision = try await fixture.transport.waitForChange(sessionToken: token, after: revision, until: .now + .seconds(1))
        XCTAssertGreaterThan(try XCTUnwrap(notifiedRevision), revision, "The real append must wake the armed versioned observer")
        let completed = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(completed["text"] as? String, #"{"type":"message","text":"Appended fixture reply"}"#)
        let completedProof = try XCTUnwrap(completed["modelProofContext"] as? [String: Any])
        XCTAssertEqual(completedProof["submittedPromptFingerprint"] as? String,
                       EmbeddedWebModelTransport.promptFingerprint("Append this after the send acknowledgment"))
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
        let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Append this after the send acknowledgment"])
        XCTAssertEqual(sent["state"] as? String, "running")
        let pendingProof = try XCTUnwrap(sent["modelProofContext"] as? [String: Any])
        XCTAssertEqual(pendingProof["submittedPromptFingerprint"] as? String, "")
        let beforeCount = try await evaluate(view, "return document.querySelectorAll('user-query').length;") as? Int
        XCTAssertEqual(beforeCount, 1)
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
                XCTAssertTrue(error.localizedDescription.contains("This website inference was not submitted"))
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

    func testChatGPTFirstUserDiagnosticContextIsFiniteStrictlyTypedAndLogBounded() throws {
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let source: [String: Any] = ["kind": "first_user_structure", "provider": "chatgpt",
            "root": ["tag": "article", "classes": Array(repeating: "whitespace-pre-wrap", count: 6)],
            "body": ["tag": "div", "classes": Array(repeating: "whitespace-pre-wrap", count: 6)],
            "userCount": 1, "textLength": 220_001, "lineCount": 220_001, "markerOccurrences": 1, "controlDescendants": 1_000,
            "markerFinalLine": true, "submitted": true, "markerMatches": true,
            "reason": "binding_not_authorized", "scope": "action_final_guard", "action": "verifyProductMode",
            "allowFirstUserBinding": false, "allowFirstUserExpansion": false, "privatePinPresent": true, "expectedFingerprintPresent": false,
            "markerValid": true, "firstPromptPresent": true, "firstPromptMatches": true,
            "pinnedFingerprintMatch": true, "nativeFingerprintMatch": false,
            "snapshot": ["rootSame": true, "bodySame": true, "bodyConnected": true, "textSame": true,
                         "countSame": true, "urlSame": true, "originSame": true, "ownerSame": true],
            "prompt": "private_canary", "response": "private_canary", "ownerToken": "private_canary",
            "url": "https://private_canary", "marker": "private_canary", "fingerprint": "private_canary"]
        let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(source), provider: .chatgpt))
        XCTAssertEqual(records.count, 2, "Large context must split rather than lose the failure branch")
        XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
        let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(values[0]["reason"] as? String, "binding_not_authorized")
        XCTAssertEqual(values[1]["kind"] as? String, "first_user_context")
        XCTAssertEqual(values[1]["action"] as? String, "verifyProductMode")
        XCTAssertEqual(values[1]["expectedFingerprintPresent"] as? Bool, false)
        for key in ["allowFirstUserBinding", "allowFirstUserExpansion", "privatePinPresent", "expectedFingerprintPresent", "markerValid",
                    "firstPromptPresent", "firstPromptMatches", "pinnedFingerprintMatch", "markerFinalLine", "submitted"] {
            for invalid in [1, 0, "private_canary", NSNull()] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        for key in ["scope", "action"] {
            var forged = source; forged[key] = "private_canary"
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        var withBody = source
        withBody["bodySelection"] = "markdown_user_message"
        withBody["expansionOutcome"] = "model_unverified"
        withBody["expansionContextFailure"] = "owner"
        withBody["expansionModelError"] = "temporary_mode_unverified"
        for key in ["bodyInnerTextLength", "bodyTextContentLength", "rootRenderedTextLength", "rootTextContentLength", "firstPromptLength"] {
            withBody[key] = 220_001
        }
        for prefix in ["bodyTextContent", "rootRendered", "rootTextContent"] {
            withBody[prefix + "Analyzed"] = true
            withBody[prefix + "MarkerOccurrences"] = 1_000
            withBody[prefix + "MarkerFinalLine"] = false
        }
        withBody["firstPromptAnalyzed"] = true
        withBody["renderedPrefixOfFirstPrompt"] = true
        withBody["scopedExpandControlCount"] = 1_000
        let bodyRecords = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(withBody), provider: .chatgpt))
        XCTAssertEqual(bodyRecords.count, 3, "Alternate body observations must not crowd out existing summary/context")
        XCTAssertTrue(bodyRecords.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
        let bodyValues = try bodyRecords.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(bodyValues[0]["reason"] as? String, "binding_not_authorized")
        XCTAssertEqual(bodyValues[1]["kind"] as? String, "first_user_context")
        XCTAssertEqual(bodyValues[2]["kind"] as? String, "first_user_body")
        XCTAssertEqual(bodyValues[2]["bodyTextContentLength"] as? Int, 220_001)
        XCTAssertEqual(bodyValues[2]["expansionOutcome"] as? String, "model_unverified")
        XCTAssertEqual(bodyValues[2]["expansionContextFailure"] as? String, "owner")
        XCTAssertEqual(bodyValues[2]["expansionModelError"] as? String, "temporary_mode_unverified")
        XCTAssertNil(bodyValues[0]["bodyTextContentLength"])
    }

    func testFramedPayloadDiagnosticsAreFiniteStrictlyTypedBoundedAndSeparateFromBody() throws {
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let flags = ["payloadExpectedFrameUnique", "payloadRenderedFrameUnique", "payloadExpectedParsed", "payloadRenderedParsed",
                     "payloadOutsideFrameMatches", "payloadCompared", "payloadParsedJSONEqual", "payloadObjectKeyOrderChanged"]
        let enums = ["payloadMismatchField", "payloadMismatchKind", "payloadExpectedType", "payloadRenderedType", "payloadUnavailableReason"]
        var source: [String: Any] = ["kind": "first_user_structure", "provider": "chatgpt", "reason": "snapshot_before_action",
            "scope": "digest", "action": "inspect", "root": ["tag": "div", "classes": []], "body": ["tag": "div", "classes": []],
            "userCount": 1, "textLength": 51_738, "lineCount": 98, "markerOccurrences": 1, "controlDescendants": 0,
            "markerFinalLine": true, "submitted": true, "markerMatches": true,
            "bodySelection": "whitespace_pre_wrap", "expansionOutcome": "text_mismatch",
            "payloadMismatchField": "tools", "payloadMismatchKind": "container_type", "payloadExpectedType": "array",
            "payloadRenderedType": "object", "payloadUnavailableReason": "none",
            "payloadPrivateKey": "private_canary", "payloadPrivateValue": "private_canary",
            "prompt": "private_canary", "response": "private_canary", "url": "https://private_canary"]
        for key in flags { source[key] = true }
        source["payloadParsedJSONEqual"] = false
        let projected = try XCTUnwrap(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(source), provider: .chatgpt))
        XCTAssertFalse(projected.contains("private_canary"))
        let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(source), provider: .chatgpt))
        XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") && !$0.contains("https://") })
        let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let payload = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_payload" })
        XCTAssertEqual(payload["provider"] as? String, "chatgpt")
        XCTAssertEqual(payload["action"] as? String, "inspect")
        XCTAssertEqual(payload["scope"] as? String, "digest")
        XCTAssertEqual(payload["payloadMismatchField"] as? String, "tools")
        XCTAssertEqual(payload["payloadExpectedType"] as? String, "array")
        XCTAssertEqual(payload["payloadRenderedType"] as? String, "object")
        let body = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_body" })
        XCTAssertNil(body["payloadMismatchField"])
        XCTAssertNil(values[0]["payloadCompared"])
        for key in flags {
            for invalid in [1, 0, "private_canary", NSNull()] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        for key in enums {
            for invalid in ["private_canary", "TOOLS", 1, true, NSNull()] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
            var incomplete = source; incomplete.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(incomplete), provider: .chatgpt), key)
        }
        var otherProvider = source; otherProvider["provider"] = "gemini"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(otherProvider), provider: .gemini))
        var equal = source
        equal["payloadParsedJSONEqual"] = true
        for key in enums { equal[key] = "none" }
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(equal), provider: .chatgpt))
        var unavailable = equal
        unavailable["payloadCompared"] = false; unavailable["payloadParsedJSONEqual"] = false
        unavailable["payloadObjectKeyOrderChanged"] = false; unavailable["payloadUnavailableReason"] = "bounds"
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(unavailable), provider: .chatgpt))
        unavailable["payloadUnavailableReason"] = "parse_failure"; unavailable["payloadRenderedParsed"] = false
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(unavailable), provider: .chatgpt))
        unavailable["payloadUnavailableReason"] = "number_precision"; unavailable["payloadRenderedParsed"] = true
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(unavailable), provider: .chatgpt))
        unavailable["payloadUnavailableReason"] = "missing_frame"; unavailable["payloadRenderedParsed"] = false
        unavailable["payloadRenderedFrameUnique"] = false; unavailable["payloadOutsideFrameMatches"] = false
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(unavailable), provider: .chatgpt))
        let impossible: [[String: Any]] = [
            ["payloadParsedJSONEqual": true], ["payloadRenderedParsed": false],
            ["payloadExpectedFrameUnique": false], ["payloadMismatchKind": "leaf_type"],
            ["payloadMismatchKind": "array_length"], ["payloadMismatchKind": "object_keys"],
            ["payloadUnavailableReason": "bounds"],
        ]
        for changes in impossible {
            var forged = source; forged.merge(changes) { _, new in new }
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        for changes in [
            ["payloadCompared": false, "payloadParsedJSONEqual": false, "payloadObjectKeyOrderChanged": true, "payloadUnavailableReason": "bounds"],
            ["payloadCompared": false, "payloadParsedJSONEqual": false, "payloadUnavailableReason": "none"],
            ["payloadCompared": false, "payloadParsedJSONEqual": false, "payloadObjectKeyOrderChanged": false, "payloadUnavailableReason": "missing_frame"],
        ] as [[String: Any]] {
            var forged = equal; forged.merge(changes) { _, new in new }
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
    }

    func testLiteralDOMDiagnosticsAreFiniteStrictlyTypedBoundedAndDoNotPublishSourceText() throws {
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let flags = ["literalDOMAvailable", "literalDOMMatchesPrompt", "literalDOMMatchesRendered", "literalDOMFrameUnique",
                     "literalDOMFrameParsed", "literalDOMPayloadCompared", "literalDOMParsedJSONEqual"]
        let limits = ["literalDOMLength": 180_201, "literalDOMNodeCount": 8_193, "literalDOMMaxDepth": 65,
                      "literalDOMParagraphCount": 8_192, "literalDOMBRCount": 8_192]
        var source: [String: Any] = ["kind": "first_user_structure", "provider": "chatgpt", "reason": "snapshot_before_action",
            "scope": "digest", "action": "inspect", "root": ["tag": "div", "classes": []], "body": ["tag": "div", "classes": []],
            "userCount": 1, "textLength": 51_783, "lineCount": 98, "markerOccurrences": 1, "controlDescendants": 0,
            "markerFinalLine": true, "submitted": true, "markerMatches": true,
            "bodySelection": "whitespace_pre_wrap", "expansionOutcome": "text_mismatch",
            "literalDOMLength": 51_783, "literalDOMNodeCount": 340, "literalDOMMaxDepth": 3,
            "literalDOMParagraphCount": 1, "literalDOMBRCount": 168,
            "literalDOMUnavailableReason": "none", "literalDOMPayloadUnavailableReason": "none",
            "literalDOMText": "private_canary", "literalDOMHTML": "private_canary", "literalDOMAttribute": "private_canary",
            "prompt": "private_canary", "response": "private_canary", "url": "https://private_canary"]
        for key in flags { source[key] = true }
        source["literalDOMMatchesRendered"] = false
        let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(source), provider: .chatgpt))
        XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") && !$0.contains("https://") })
        let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let literal = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_literal_dom" })
        XCTAssertEqual(literal["literalDOMMatchesPrompt"] as? Bool, true)
        XCTAssertEqual(literal["literalDOMMatchesRendered"] as? Bool, false)
        XCTAssertEqual(literal["literalDOMBRCount"] as? Int, 168)
        XCTAssertEqual(literal["scope"] as? String, "digest")
        XCTAssertEqual(literal["action"] as? String, "inspect")
        XCTAssertNil(values[0]["literalDOMMatchesPrompt"])
        XCTAssertNil(try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_body" })["literalDOMMatchesPrompt"])
        for key in flags {
            for invalid in [1, 0, "private_canary", NSNull()] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
            var partial = source; partial.removeValue(forKey: key)
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(partial), provider: .chatgpt), key)
        }
        for (key, maximum) in limits {
            for invalid in [-1, maximum + 1, 1.5, true, NSNull(), "private_canary"] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        XCTAssertNil(literal["literalDOMLinkCount"], "Historical diagnostics without the optional count remain valid")
        var linked = source; linked["literalDOMLinkCount"] = 2
        linked["literalDOMLinkURL"] = "https://private_canary"; linked["literalDOMLinkText"] = "private_canary"
        let linkedRecords = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(linked), provider: .chatgpt))
        XCTAssertTrue(linkedRecords.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") && !$0.contains("https://") })
        let linkedValues = try linkedRecords.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let linkedLiteral = try XCTUnwrap(linkedValues.first { $0["kind"] as? String == "first_user_literal_dom" })
        XCTAssertEqual(linkedLiteral["literalDOMLinkCount"] as? Int, 2)
        for invalid in [-1, 8_193, 1.5, true, NSNull(), "private_canary"] as [Any] {
            var forged = linked; forged["literalDOMLinkCount"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        for changes in [["literalDOMLinkCount": 172], ["literalDOMParagraphCount": 0], ["literalDOMMaxDepth": 1]] as [[String: Any]] {
            var forged = linked; forged.merge(changes) { _, new in new }
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        for key in ["literalDOMUnavailableReason", "literalDOMPayloadUnavailableReason"] {
            for invalid in ["private_canary", 1, true, NSNull()] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        var otherProvider = source; otherProvider["provider"] = "gemini"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(otherProvider), provider: .gemini))
        for reason in ["read_failure", "hidden_markup", "inert_markup", "control_markup", "unsupported_markup", "node_budget", "depth_budget", "character_budget"] {
            var unavailable = source
            for key in flags { unavailable[key] = false }
            unavailable["literalDOMUnavailableReason"] = reason; unavailable["literalDOMPayloadUnavailableReason"] = "unavailable"
            if reason == "node_budget" { unavailable["literalDOMNodeCount"] = 8_193 }
            if reason == "depth_budget" { unavailable["literalDOMMaxDepth"] = 65 }
            if reason == "character_budget" { unavailable["literalDOMLength"] = 180_201 }
            XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(unavailable), provider: .chatgpt))
            unavailable["literalDOMMatchesPrompt"] = true
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(unavailable), provider: .chatgpt))
        }
        let failureKeys = ["literalDOMFailureNodeKind", "literalDOMFailureTag", "literalDOMFailureParentTag", "literalDOMFailureRule"]
        var unavailable = source
        for key in flags { unavailable[key] = false }
        unavailable["literalDOMUnavailableReason"] = "unsupported_markup"
        unavailable["literalDOMPayloadUnavailableReason"] = "unavailable"
        unavailable["literalDOMNodeCount"] = 2; unavailable["literalDOMMaxDepth"] = 1
        unavailable["literalDOMLength"] = 0; unavailable["literalDOMParagraphCount"] = 0; unavailable["literalDOMBRCount"] = 0
        for tuple in [["comment", "none", "div", "node_type"], ["other", "none", "div", "node_type"],
                      ["element", "pre", "div", "tag"], ["element", "other", "div", "tag"],
                      ["element", "div", "div", "nested_div"], ["element", "p", "span", "paragraph_parent"]] {
            var observed = unavailable
            for (key, value) in zip(failureKeys, tuple) { observed[key] = value }
            let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(observed), provider: .chatgpt))
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
            let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let literal = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_literal_dom" })
            for (key, value) in zip(failureKeys, tuple) { XCTAssertEqual(literal[key] as? String, value) }
            for key in failureKeys {
                var partial = observed; partial.removeValue(forKey: key)
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(partial), provider: .chatgpt))
                for invalid in ["private_canary", 1, true, NSNull()] as [Any] {
                    var forged = observed; forged[key] = invalid
                    XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
                }
            }
            var availableFailure = source
            for (key, value) in zip(failureKeys, tuple) { availableFailure[key] = value }
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(availableFailure), provider: .chatgpt))
        }
        for tag in ["a", "button", "input", "textarea", "span", "div", "other"] {
            var observed = unavailable
            observed["literalDOMUnavailableReason"] = "control_markup"
            observed["literalDOMLength"] = 23_609; observed["literalDOMNodeCount"] = 293
            observed["literalDOMMaxDepth"] = 4; observed["literalDOMParagraphCount"] = 1; observed["literalDOMBRCount"] = 99
            let tuple = ["element", tag, "p", "control"]
            for (key, value) in zip(failureKeys, tuple) { observed[key] = value }
            let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(observed), provider: .chatgpt))
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") && !$0.contains("https://") })
            let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let literal = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_literal_dom" })
            for (key, value) in zip(failureKeys, tuple) { XCTAssertEqual(literal[key] as? String, value) }
            XCTAssertEqual(literal["literalDOMLength"] as? Int, 23_609)
            for key in failureKeys {
                var partial = observed; partial.removeValue(forKey: key)
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(partial), provider: .chatgpt))
                for invalid in ["private_canary", 1, true, NSNull()] as [Any] {
                    var forged = observed; forged[key] = invalid
                    XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
                }
            }
            for changes in [["literalDOMUnavailableReason": "unsupported_markup"], ["literalDOMUnavailableReason": "hidden_markup"],
                            ["literalDOMFailureNodeKind": "comment"], ["literalDOMFailureNodeKind": "other"],
                            ["literalDOMFailureTag": "none"], ["literalDOMFailureRule": "tag"],
                            ["literalDOMAvailable": true]] as [[String: Any]] {
                var forged = observed; forged.merge(changes) { _, new in new }
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
            }
        }
        for tuple in [["element", "none", "div", "node_type"], ["comment", "pre", "div", "node_type"],
                      ["element", "span", "div", "tag"], ["element", "pre", "div", "nested_div"],
                      ["element", "p", "none", "paragraph_parent"], ["element", "div", "none", "nested_div"]] {
            var forged = unavailable
            for (key, value) in zip(failureKeys, tuple) { forged[key] = value }
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        for changes in [
            ["literalDOMFrameUnique": false], ["literalDOMFrameParsed": false], ["literalDOMPayloadCompared": false],
            ["literalDOMUnavailableReason": "hidden_markup"], ["literalDOMPayloadUnavailableReason": "unavailable"],
            ["literalDOMLength": 180_201], ["literalDOMNodeCount": 8_193], ["literalDOMMaxDepth": 65],
        ] as [[String: Any]] {
            var forged = source; forged.merge(changes) { _, new in new }
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
    }

    func testExpansionTextComparisonDiagnosticsAreFiniteStrictAndSeparateFromBody() throws {
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let flags = ["expansionTextAnalyzed", "expansionClicked", "expansionExactPrefixMatches",
                     "expansionASCIIPrefixMatches", "expansionASCIIPromptMatches"]
        let lengths = ["expansionASCIIRenderedLength", "expansionASCIIPrefixLength", "expansionASCIIPromptLength", "expansionFirstMismatchOffset"]
        let counts = ["expansionUnicodeSpaceCount", "expansionExpectedUnicodeSpaceCount", "expansionFormatCount", "expansionExpectedFormatCount"]
        var source: [String: Any] = ["kind": "first_user_structure", "provider": "chatgpt",
            "root": ["tag": "article", "classes": Array(repeating: "whitespace-pre-wrap", count: 6)],
            "body": ["tag": "div", "classes": Array(repeating: "whitespace-pre-wrap", count: 6)],
            "userCount": 1, "textLength": 220_001, "lineCount": 220_001, "markerOccurrences": 1, "controlDescendants": 1_000,
            "markerFinalLine": true, "submitted": true, "markerMatches": true,
            "reason": "snapshot_before_action", "scope": "action_final_guard", "action": "verifyProductMode",
            "allowFirstUserBinding": true, "allowFirstUserExpansion": true, "privatePinPresent": false, "expectedFingerprintPresent": false,
            "markerValid": true, "firstPromptPresent": true, "firstPromptMatches": true,
            "snapshot": ["rootSame": true, "bodySame": true, "bodyConnected": true, "textSame": true,
                         "countSame": true, "urlSame": true, "originSame": true, "ownerSame": true],
            "bodySelection": "whitespace_pre_wrap", "expansionOutcome": "text_mismatch", "bodyInnerTextLength": 220_001,
            "expansionPrivatePrefix": "private_canary", "expansionActualScalar": 123456,
            "prompt": "private_canary", "response": "private_canary", "fingerprint": "private_canary"]
        for key in flags { source[key] = true }
        for key in lengths { source[key] = 180_200 }
        for key in counts { source[key] = 1_000 }
        for mismatch in ["none", "end", "ascii_space", "unicode_space", "format", "punctuation", "content"] {
            var candidate = source; candidate["expansionFirstMismatchClass"] = mismatch
            if mismatch == "none" { candidate.removeValue(forKey: "expansionFirstMismatchOffset") }
            let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(candidate), provider: .chatgpt))
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") && !$0.contains("123456") })
            let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let text = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_text" })
            XCTAssertEqual(text["expansionFirstMismatchClass"] as? String, mismatch)
            XCTAssertEqual(text["expansionASCIIRenderedLength"] as? Int, 180_200)
            XCTAssertEqual(text["expansionFormatCount"] as? Int, 1_000)
            XCTAssertEqual(text["scope"] as? String, "action_final_guard")
            XCTAssertNil(text["reason"], "The finite text record cannot duplicate first_bound log ownership")
            let body = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_body" })
            XCTAssertNil(body["expansionFirstMismatchClass"])
        }
        source["expansionFirstMismatchClass"] = "content"
        var measured = source
        measured["expansionASCIIPromptMatches"] = false
        measured["expansionFirstActualCharacter"] = "backslash"
        measured["expansionFirstExpectedCharacter"] = "double_quote"
        let characterRecords = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(measured), provider: .chatgpt))
        let characterValues = try characterRecords.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let characterText = try XCTUnwrap(characterValues.first { $0["kind"] as? String == "first_user_text" })
        XCTAssertEqual(characterText["expansionFirstActualCharacter"] as? String, "backslash")
        XCTAssertEqual(characterText["expansionFirstExpectedCharacter"] as? String, "double_quote")
        XCTAssertTrue(characterRecords.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") && !$0.contains("123456") })
        for key in ["expansionFirstActualCharacter", "expansionFirstExpectedCharacter"] {
            for invalid in [65, 123456, 1.5, true, NSNull(), "private_canary", "A", "123456"] as [Any] {
                var forged = measured; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        var incomplete = measured; incomplete.removeValue(forKey: "expansionFirstExpectedCharacter")
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(incomplete), provider: .chatgpt))
        var equal = measured; equal["expansionFirstExpectedCharacter"] = "backslash"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(equal), provider: .chatgpt))
        equal["expansionFirstActualCharacter"] = "other"; equal["expansionFirstExpectedCharacter"] = "other"
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(equal), provider: .chatgpt))
        var matching = measured; matching["expansionASCIIPromptMatches"] = true
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(matching), provider: .chatgpt))
        var noOffset = measured; noOffset.removeValue(forKey: "expansionFirstMismatchOffset")
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(noOffset), provider: .chatgpt))
        var end = measured; end["expansionFirstMismatchClass"] = "end"; end["expansionFirstActualCharacter"] = "end"
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(end), provider: .chatgpt))
        end["expansionFirstExpectedCharacter"] = "end"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(end), provider: .chatgpt))
        for key in flags {
            for invalid in [1, 0, "private_canary", NSNull()] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        for key in lengths + counts {
            for invalid in [-1, lengths.contains(key) ? 180_201 : 1_001, 1.5, true, NSNull(), "private_canary"] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        for invalid in ["private_canary", 1, true, NSNull()] as [Any] {
            var forged = source; forged["expansionFirstMismatchClass"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        var unavailable = source; unavailable["expansionTextAnalyzed"] = false
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(unavailable), provider: .chatgpt))
        for key in lengths + counts + Array(flags.dropFirst(2)) + ["expansionFirstMismatchClass"] { unavailable.removeValue(forKey: key) }
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(unavailable), provider: .chatgpt))
        var impossibleOffset = source; impossibleOffset["expansionFirstMismatchClass"] = "none"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(impossibleOffset), provider: .chatgpt))
    }

    func testProductProofFailureDiagnosticsAreFiniteBoundedAndSeparateFromBody() throws {
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let source: [String: Any] = ["kind": "first_user_structure", "provider": "chatgpt", "reason": "marker_not_final",
            "scope": "marker_validation", "action": "inspect", "root": ["tag": "div", "classes": []],
            "body": ["tag": "div", "classes": []], "userCount": 1, "textLength": 10_240, "lineCount": 98,
            "markerOccurrences": 0, "controlDescendants": 0, "markerFinalLine": false, "submitted": true, "markerMatches": true,
            "expansionOutcome": "context_changed", "expansionContextFailure": "product",
            "productMutationRelevantCount": 513, "productMutationIgnoredCount": 1_000,
            "productProof": "private_canary", "productControls": "private_canary", "prompt": "private_canary"]
        for failure in ["work_selected", "mutation_overflow", "mutation_scan_overflow", "mutation_uninspectable",
                        "product_history_ambiguous", "group_overflow", "work_overflow", "contradictory_controls",
                        "owner", "document", "frame", "origin", "route", "not_ready", "temporary_unclaimed"] {
            var candidate = source; candidate["productProofFailure"] = failure
            let records = try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(candidate), provider: .chatgpt))
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
            let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let product = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_product_proof" })
            XCTAssertEqual(product["productProofFailure"] as? String, failure)
            XCTAssertEqual(product["productMutationRelevantCount"] as? Int, 513)
            XCTAssertEqual(product["productMutationIgnoredCount"] as? Int, 1_000)
            XCTAssertEqual(product["scope"] as? String, "marker_validation")
            let body = try XCTUnwrap(values.first { $0["kind"] as? String == "first_user_body" })
            XCTAssertEqual(body["expansionContextFailure"] as? String, "product")
            XCTAssertNil(body["productProofFailure"])
        }
        for key in ["productMutationRelevantCount", "productMutationIgnoredCount"] {
            for invalid in [-1, 1_001, 1.5, true, NSNull(), "private_canary"] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        for invalid in ["private_canary", "none", 1, true, NSNull()] as [Any] {
            var forged = source; forged["productProofFailure"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
    }

    func testChatGPTAlternateBodyDiagnosticsRejectPrivateValuesAndDistinguishUnavailableAnalysis() throws {
        func encode(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let lengths = ["bodyInnerTextLength", "bodyTextContentLength", "rootRenderedTextLength", "rootTextContentLength", "firstPromptLength"]
        let counts = ["bodyTextContentMarkerOccurrences", "rootRenderedMarkerOccurrences", "rootTextContentMarkerOccurrences", "scopedExpandControlCount"]
        let flags = ["bodyTextContentAnalyzed", "rootRenderedAnalyzed", "rootTextContentAnalyzed", "firstPromptAnalyzed",
                     "bodyTextContentMarkerFinalLine", "rootRenderedMarkerFinalLine", "rootTextContentMarkerFinalLine", "renderedPrefixOfFirstPrompt"]
        var source: [String: Any] = ["kind": "first_user_structure", "provider": "chatgpt", "reason": "marker_not_final",
            "scope": "marker_validation", "action": "inspect", "root": ["tag": "div", "classes": []],
            "body": ["tag": "div", "classes": []], "userCount": 1, "textLength": 10_240, "lineCount": 98,
            "markerOccurrences": 0, "controlDescendants": 0, "markerFinalLine": false, "submitted": true, "markerMatches": true,
            "bodySelection": "markdown_user_message", "bodyTextContent": "private_canary", "rootTextContent": "private_canary",
            "firstPrompt": "private_canary", "selector": "private_canary", "expandControlLabel": "private_canary",
            "ownerToken": "private_canary", "marker": "private_canary", "url": "https://private_canary"]
        for key in lengths { source[key] = 100 }
        for key in counts { source[key] = 1 }
        for key in flags { source[key] = true }
        func projected(_ value: [String: Any]) throws -> [String] {
            try XCTUnwrap(EmbeddedWebModelTransport.firstUserStructureDiagnosticRecords(try encode(value), provider: .chatgpt))
        }
        for selection in ["markdown_user_message", "whitespace_pre_wrap", "author_user", "root_fallback", "none", "unmatched"] {
            var candidate = source; candidate["bodySelection"] = selection
            let records = try projected(candidate)
            XCTAssertEqual(records.count, 2)
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[1].utf8)) as? [String: Any])
            XCTAssertEqual(body["bodySelection"] as? String, selection)
            XCTAssertEqual(body["bodyTextContentMarkerFinalLine"] as? Bool, true)
        }
        for outcome in ["not_requested", "ineligible", "unavailable", "ambiguous", "disabled", "obstructed", "claimed",
                        "model_unverified", "timeout", "context_changed", "node_changed", "text_mismatch", "expanded", "failed"] {
            var candidate = source; candidate["expansionOutcome"] = outcome
            let records = try projected(candidate)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[1].utf8)) as? [String: Any])
            XCTAssertEqual(body["expansionOutcome"] as? String, outcome)
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
        }
        for invalid in ["private_canary", 1, true, NSNull()] as [Any] {
            var forged = source; forged["expansionOutcome"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        for error in ["model_unverified", "model_unavailable", "model_mismatch", "document_changed",
                      "conversation_changed", "product_mode_unverified", "temporary_mode_unverified"] {
            var candidate = source; candidate["expansionModelError"] = error
            let records = try projected(candidate)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[1].utf8)) as? [String: Any])
            XCTAssertEqual(body["expansionModelError"] as? String, error)
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
        }
        for invalid in ["private_canary", "https://private_canary", "timeout", "", 1, true, NSNull(),
                        ["error": "model_unverified"]] as [Any] {
            var forged = source; forged["expansionModelError"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        for failure in ["frame", "provider", "origin", "owner", "user_count", "submission", "submission_count",
                        "marker", "prompt", "private_pin", "product", "temporary", "root", "body",
                        "conversation_route", "conversation_identity", "url", "continuation", "deadline"] {
            var candidate = source; candidate["expansionContextFailure"] = failure
            let records = try projected(candidate)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[1].utf8)) as? [String: Any])
            XCTAssertEqual(body["expansionContextFailure"] as? String, failure)
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
        }
        for invalid in ["private_canary", "none", 1, true, NSNull()] as [Any] {
            var forged = source; forged["expansionContextFailure"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        for failure in ["suppressed", "action", "binding", "native_pin", "private_pin", "claim_spent",
                        "user_count", "submission", "submission_count", "marker", "prompt", "model_choice", "text_prefix",
                        "frame", "provider", "origin", "owner", "product", "temporary", "root", "body",
                        "conversation_route", "conversation_identity", "url"] {
            var candidate = source; candidate["expansionAdmissionFailure"] = failure
            let records = try projected(candidate)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(records[1].utf8)) as? [String: Any])
            XCTAssertEqual(body["expansionAdmissionFailure"] as? String, failure)
            XCTAssertTrue(records.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") })
        }
        for invalid in ["private_canary", "none", "timeout", 1, true, NSNull()] as [Any] {
            var forged = source; forged["expansionAdmissionFailure"] = invalid
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        }
        for key in lengths + counts {
            for invalid in [-1, lengths.contains(key) ? 220_002 : 1_001, 1.5, true, NSNull(), "private_canary"] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        for key in flags {
            for invalid in [1, 0, NSNull(), "private_canary"] as [Any] {
                var forged = source; forged[key] = invalid
                XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt), key)
            }
        }
        var forged = source; forged["bodySelection"] = "private_canary"
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(forged), provider: .chatgpt))
        var unavailable = source
        for key in lengths { unavailable[key] = 220_001 }
        for prefix in ["bodyTextContent", "rootRendered", "rootTextContent"] {
            unavailable[prefix + "Analyzed"] = false
            unavailable.removeValue(forKey: prefix + "MarkerOccurrences")
            unavailable.removeValue(forKey: prefix + "MarkerFinalLine")
        }
        unavailable["firstPromptAnalyzed"] = false
        unavailable.removeValue(forKey: "renderedPrefixOfFirstPrompt")
        let unavailableRecords = try projected(unavailable)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(unavailableRecords[1].utf8)) as? [String: Any])
        XCTAssertEqual(body["bodyTextContentAnalyzed"] as? Bool, false)
        XCTAssertEqual(body["bodyTextContentLength"] as? Int, 220_001)
        XCTAssertNil(body["bodyTextContentMarkerFinalLine"], "Unavailable analysis is not a verified absence")
        XCTAssertNil(body["renderedPrefixOfFirstPrompt"])
        for key in ["bodyTextContentMarkerFinalLine", "rootRenderedMarkerOccurrences", "rootTextContentMarkerFinalLine", "renderedPrefixOfFirstPrompt"] {
            var contradictory = unavailable; contradictory[key] = source[key]
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedFirstUserStructure(try encode(contradictory), provider: .chatgpt))
        }
    }

    func testNativeFirstUserFailureContextProjectsPresenceWithoutPrivateValues() throws {
        let entry = EmbeddedWebModelTransport.FirstUserNativeState(sequence: 1, confirmedUsers: 0,
            pendingSubmission: true, submitted: true, temporary: true, fingerprintPresent: false)
        let current = EmbeddedWebModelTransport.FirstUserNativeState(sequence: 1, confirmedUsers: 1,
            pendingSubmission: false, submitted: true, temporary: true, fingerprintPresent: true)
        func records(_ observed: [String: Any], action: String = "inspect",
                     stage: EmbeddedWebModelTransport.FirstUserNativeStage = .bindingNotAuthorized) -> [String]? {
            EmbeddedWebModelTransport.firstUserNativeDiagnosticRecords(provider: .chatgpt, action: action, stage: stage,
                entry: entry, current: current, observed: observed, refresh: false, modelRecheck: true, productRecheck: false)
        }
        let fingerprint = String(repeating: "a", count: 64)
        let projected = try XCTUnwrap(records(["firstUserVerified": true, "firstUserMarkerVerified": false,
            "temporary": NSNumber(value: 1), "userCount": 1, "firstUserFingerprint": fingerprint,
            "debugStructure": "private_canary", "prompt": "private_canary", "response": "private_canary",
            "ownerToken": "private_canary", "url": "https://private_canary", "marker": "private_canary"]))
        XCTAssertEqual(projected.count, 3)
        XCTAssertTrue(projected.allSatisfy { $0.utf8.count <= 960 && !$0.contains("private_canary") && !$0.contains(fingerprint) })
        let values = try projected.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(values[0]["stage"] as? String, "binding_not_authorized")
        XCTAssertEqual(values[0]["temporary"] as? String, "invalid")
        XCTAssertEqual(values[0]["firstUserVerified"] as? String, "true")
        XCTAssertEqual(values[0]["firstUserMarkerVerified"] as? String, "false")
        XCTAssertEqual(values[0]["fingerprintState"] as? String, "valid")
        XCTAssertEqual(values[0]["adapterDiagnosticPresent"] as? Bool, true)
        XCTAssertEqual(values[0]["adapterDiagnosticAccepted"] as? Bool, false)
        XCTAssertEqual(values[1]["phase"] as? String, "entry")
        XCTAssertEqual(values[1]["bindingAllowed"] as? Bool, true)
        XCTAssertEqual(values[2]["phase"] as? String, "current")
        XCTAssertEqual(values[2]["bindingAllowed"] as? Bool, false)
        XCTAssertNil(records([:], action: "private_canary"))
        for invalid in [true, -1, 1.5, 10_001, "private_canary", NSNull()] as [Any] {
            let invalidRecords = try XCTUnwrap(records(["userCount": invalid, "firstUserFingerprint": "private_canary"]))
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(invalidRecords[0].utf8)) as? [String: Any])
            XCTAssertEqual(value["userCountState"] as? String, "invalid")
            XCTAssertNil(value["userCount"])
            XCTAssertEqual(value["fingerprintState"] as? String, "invalid")
        }
        let absent = try XCTUnwrap(records([:]))
        let absentValue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(absent[0].utf8)) as? [String: Any])
        XCTAssertEqual(absentValue["userCountState"] as? String, "absent")
        XCTAssertEqual(absentValue["firstUserVerified"] as? String, "absent")
        XCTAssertEqual(absentValue["fingerprintState"] as? String, "absent")
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

    func testGeminiQueryParagraphsProveEveryLiteralLineAcrossTwoOwnedSubmissions() async throws {
        let fixture = try Fixture(page: Self.geminiQueryParagraphPage())
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: tabID)
        let prompt = (0..<167).map { index in
            index == 41 || index == 42 ? "" : "Row \(index): 'literal' \"quoted\" \\path  spaces\tNBSP\u{00a0}emoji 🚀"
        }.joined(separator: "\n")
        XCTAssertEqual(prompt.components(separatedBy: "\n").count, 167)
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
        let first = try await waitForState("complete", fixture.transport, token: token)
        let firstProof = try XCTUnwrap(first["modelProofContext"] as? [String: Any])
        let firstFingerprint = try XCTUnwrap(firstProof["firstUserFingerprint"] as? String)
        XCTAssertEqual(first["turnContinuationCapability"] as? String, "per_submission_ownership_v1")
        XCTAssertEqual(firstProof["sequence"] as? Int, 1)
        XCTAssertEqual(firstProof["baselineResponseCount"] as? Int, 0)
        XCTAssertEqual(firstProof["responseCount"] as? Int, 1)
        XCTAssertEqual(firstProof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(prompt))
        let renderedValue = try await evaluate(view, #"""
            const payload = document.querySelector('user-query .user-query-bubble-with-background > span.ng-star-inserted');
            const query = payload.querySelector(':scope > div.query-text.gds-body-l');
            const rows = [...query.querySelectorAll(':scope > p.query-text-line')];
            const literal = rows.map(row => [...row.childNodes].map(node => node.nodeType === Node.TEXT_NODE ? node.data : '').join('')).join('\n');
            return { rowCount: rows.length, blankRows: rows.filter(row => row.childNodes.length === 1 && row.firstChild.nodeName === 'BR').length,
              literalMatchesOutbound: literal === window.fixturePrompts[0], rawInnerTextDiffers: payload.innerText !== literal };
            """#)
        let rendered = try XCTUnwrap(renderedValue as? [String: Any])
        XCTAssertEqual(rendered["rowCount"] as? Int, 169, "The private blank line and nonce add exactly two physical query rows")
        XCTAssertEqual(rendered["blankRows"] as? Int, 3)
        XCTAssertEqual(rendered["literalMatchesOutbound"] as? Bool, true)
        XCTAssertEqual(rendered["rawInnerTextDiffers"] as? Bool, true, "Real WebKit must include layout/accessibility text that is absent from the literal paragraph stream")
        let firstOutboundValue = try await evaluate(view, "return window.fixturePrompts[0];")
        let firstOutbound = try XCTUnwrap(firstOutboundValue as? String)
        XCTAssertEqual(firstFingerprint, EmbeddedWebModelTransport.outboundFingerprint(firstOutbound))

        let nextPrompt = "Distinct tool result\n\nKeep  two spaces, apostrophe's and NBSP\u{00a0}unchanged"
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": nextPrompt])
        let second = try await waitForState("complete", fixture.transport, token: token)
        let secondProof = try XCTUnwrap(second["modelProofContext"] as? [String: Any])
        XCTAssertEqual(secondProof["sequence"] as? Int, 2)
        XCTAssertEqual(secondProof["baselineResponseCount"] as? Int, 1)
        XCTAssertEqual(secondProof["responseCount"] as? Int, 2)
        XCTAssertEqual(secondProof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(nextPrompt))
        XCTAssertEqual(secondProof["firstUserFingerprint"] as? String, firstFingerprint)
        XCTAssertEqual(secondProof["documentGeneration"] as? String, firstProof["documentGeneration"] as? String)
        XCTAssertEqual(fixture.browser.documentGeneration(for: tabID), generation)
        let captured = try await capturedUserPrompts(view)
        XCTAssertEqual(captured, [prompt, nextPrompt])
        let inputCount = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(inputCount, 2)
        XCTAssertEqual(fixture.createdTabs, [tabID], "Both rounds must keep the sole owned physical conversation")
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        try await assertHumanTabIntact(fixture)
    }

    func testGeminiUniformQueryRowFramesPreserveUserSpacesAcrossTwoOwnedSubmissions() async throws {
        let fixture = try Fixture(page: Self.geminiQueryParagraphPage(.framed))
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let prompts = ["  Leading user spaces\n\n Middle  spaces\tand NBSP\u{00a0} \nUser trailing spaces  ",
                       "Distinct second result\n  Both user margins  \n\nFinal user margin \t"]
        var firstProof: [String: Any]?
        for (index, prompt) in prompts.enumerated() {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
            let completed = try await waitForState("complete", fixture.transport, token: token)
            let proof = try XCTUnwrap(completed["modelProofContext"] as? [String: Any])
            XCTAssertEqual(proof["sequence"] as? Int, index + 1)
            XCTAssertEqual(proof["baselineResponseCount"] as? Int, index)
            XCTAssertEqual(proof["responseCount"] as? Int, index + 1)
            XCTAssertEqual(proof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(prompt))
            if let firstProof {
                XCTAssertEqual(proof["firstUserFingerprint"] as? String, firstProof["firstUserFingerprint"] as? String)
                XCTAssertEqual(proof["documentGeneration"] as? String, firstProof["documentGeneration"] as? String)
            } else {
                firstProof = proof
                let outboundValue = try await evaluate(view, "return window.fixturePrompts[0];")
                let outbound = try XCTUnwrap(outboundValue as? String)
                XCTAssertEqual(proof["firstUserFingerprint"] as? String, EmbeddedWebModelTransport.outboundFingerprint(outbound))
            }
            let shapeValue = try await evaluate(view, #"""
                const rows = [...document.querySelectorAll('user-query')].at(-1).querySelectorAll('.query-text > p.query-text-line');
                const lines = [...rows].map(row => row.childNodes.length === 1 && row.firstChild.nodeName === 'BR' ? null : row.textContent);
                const raw = lines.map(line => line ?? '').join('\n');
                const projected = lines.map(line => line === null ? '' : line.slice(1, -1)).join('\n');
                return { allNonblankRowsFramed: lines.filter(line => line !== null).every(line => line.startsWith(' ') && line.endsWith(' ')),
                  projectedMatchesActualOutbound: projected === window.fixturePrompts.at(-1), rawDiffers: raw !== projected,
                  preservesBlankBR: lines.some(line => line === null), sends: window.fixturePrompts.length, inputs: window.fixtureInputCount };
                """#)
            let shape = try XCTUnwrap(shapeValue as? [String: Any])
            XCTAssertEqual(shape["allNonblankRowsFramed"] as? Bool, true)
            XCTAssertEqual(shape["projectedMatchesActualOutbound"] as? Bool, true, "Remove only the two template spaces, retaining every user byte")
            XCTAssertEqual(shape["rawDiffers"] as? Bool, true)
            XCTAssertEqual(shape["preservesBlankBR"] as? Bool, true)
            XCTAssertEqual(shape["sends"] as? Int, index + 1)
            XCTAssertEqual(shape["inputs"] as? Int, index + 1)
        }
        let captured = try await capturedUserPrompts(view)
        XCTAssertEqual(captured, prompts)
        XCTAssertEqual(fixture.createdTabs, [tabID])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        try await assertHumanTabIntact(fixture)
    }

    func testGeminiVerifiedFirstQueryReplacementBetweenInvocationsRequiresOneFreshInspect() async throws {
        let choice = Self.fixtureChoice(.gemini)
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini, initiallySelectTarget: true,
            unmountClosedMenu: true, basePage: Self.geminiQueryParagraphPage(.framed)))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: tabID)
        var replacement: [String: Any]?
        var followingActions: [String] = []
        var discardedProof: [String: Any]?
        var freshProof: [String: Any]?
        fixture.transport.setBeforePageResultValidationForTesting { action in
            do {
                if replacement != nil {
                    followingActions.append(action)
                    if action == "inspect" {
                        let observed = try await self.evaluate(view, """
                            const state = globalThis.__computaGeminiSubmissionState, record = state?.lastVerified;
                            const root = document.querySelector('user-query');
                            const body = root?.querySelector('.user-query-bubble-with-background > span.ng-star-inserted');
                            return {verified: record?.phase === 'verified', revoked: state?.revoked === true,
                              currentPointers: record?.root === root && record?.body === body,
                              certificateLinksOldAndCurrent: !!record?.remount
                                && record.remount.previousRoot === record.root && record.remount.previousBody === record.body
                                && !record.root.isConnected && !record.body.isConnected
                                && record.remount.root === root && record.remount.body === body,
                              receiptConsumed: record?.remount == null, fingerprint: record?.fingerprint};
                            """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
                        if discardedProof == nil {
                            discardedProof = observed
                        } else {
                            freshProof = observed
                            fixture.transport.setBeforePageResultValidationForTesting(nil)
                        }
                    }
                } else if action == "inspect" {
                    // The initial script has already proved the submitted body.
                    // Replace only its DOM before native finishes binding its
                    // first pin. The post-await recheck therefore uses inspect;
                    // its discard requires one further fresh inspect.
                    replacement = try await self.replaceVerifiedGeminiQuery(view, bodyOnly: false, changeText: false)
                }
            } catch { XCTFail("Could not establish the between-invocation fixture: \(error)") }
        }
        defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
        let prompt = "  Preserve exact first query\n\nUser spaces  and NBSP\u{00a0}\nFinal user margin \t"
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
        let completed = try await waitForState("complete", fixture.transport, token: token)
        let replaced = try XCTUnwrap(replacement)
        XCTAssertEqual(replaced["verifiedBeforeReplacement"] as? Bool, true)
        XCTAssertEqual(replaced["firstPinMatches"] as? Bool, true)
        XCTAssertEqual(replaced["oldRootDisconnected"] as? Bool, true)
        XCTAssertEqual(replaced["oldBodyDisconnected"] as? Bool, true)
        XCTAssertEqual(replaced["recordKeepsOldPointers"] as? Bool, true)
        XCTAssertEqual(followingActions, ["inspect", "inspect"], "The pre-pin recheck discards once, then spends one native fresh-inspect allowance")
        XCTAssertEqual(discardedProof?["verified"] as? Bool, true)
        XCTAssertEqual(discardedProof?["revoked"] as? Bool, false)
        XCTAssertEqual(discardedProof?["currentPointers"] as? Bool, false)
        XCTAssertEqual(discardedProof?["certificateLinksOldAndCurrent"] as? Bool, true)
        XCTAssertEqual(discardedProof?["receiptConsumed"] as? Bool, false)
        XCTAssertEqual(discardedProof?["fingerprint"] as? String, replaced["fingerprint"] as? String)
        XCTAssertEqual(freshProof?["verified"] as? Bool, true)
        XCTAssertEqual(freshProof?["revoked"] as? Bool, false)
        XCTAssertEqual(freshProof?["currentPointers"] as? Bool, true)
        XCTAssertEqual(freshProof?["receiptConsumed"] as? Bool, true)
        XCTAssertEqual(freshProof?["fingerprint"] as? String, replaced["fingerprint"] as? String)
        XCTAssertEqual(completed["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        try assertChoiceEvidence(completed, choice: choice)
        let proof = try XCTUnwrap(completed["modelProofContext"] as? [String: Any])
        XCTAssertEqual(proof["sequence"] as? Int, 1)
        XCTAssertEqual(proof["responseCount"] as? Int, 1)
        XCTAssertEqual(proof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(prompt))
        XCTAssertEqual(proof["firstUserFingerprint"] as? String, replaced["fingerprint"] as? String)
        let outboundValue = try await evaluate(view, "return window.fixturePrompts[0];")
        let outbound = try XCTUnwrap(outboundValue as? String)
        XCTAssertEqual(proof["firstUserFingerprint"] as? String, EmbeddedWebModelTransport.outboundFingerprint(outbound))
        XCTAssertEqual(fixture.browser.documentGeneration(for: tabID), generation)
        let captured = try await capturedUserPrompts(view)
        XCTAssertEqual(captured, [prompt])
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
        XCTAssertEqual(fixture.createdTabs, [tabID])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        try await assertHumanTabIntact(fixture)
    }

    func testGeminiLaterQueryRemountAndNextSendPreflightPreserveThreeRoundLineage() async throws {
        let choice = Self.fixtureChoice(.gemini)
        let fixture = try Fixture(page: Self.modelChoicePage(.gemini, initiallySelectTarget: true,
            unmountClosedMenu: true, basePage: Self.geminiQueryParagraphPage(.framed)))
        defer { fixture.shutdown() }
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let generation = fixture.browser.documentGeneration(for: tabID)
        let prompts = ["Preserve first query\n\nInitial exact context", "  Preserve second query\n\nLiteral user spaces \t",
                       "Preserve third query\nDistinct tool result and NBSP\u{00a0}"]
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompts[0]])
        let first = try await waitForState("complete", fixture.transport, token: token)
        let firstProof = try XCTUnwrap(first["modelProofContext"] as? [String: Any])
        var replacement: [String: Any]?
        var followingActions: [String] = []
        var replacementObservations: [[String: Any]] = []
        fixture.transport.setBeforePageResultValidationForTesting { action in
            do {
                if replacement != nil {
                    followingActions.append(action)
                    if ["verifyModel", "inspect"].contains(action) {
                        replacementObservations.append(try await self.geminiVerifiedQueryState(view, sequence: 2))
                        if action == "inspect" { fixture.transport.setBeforePageResultValidationForTesting(nil) }
                    }
                } else if action == "inspect" {
                    replacement = try await self.replaceVerifiedGeminiQuery(view, sequence: 2, bodyOnly: false, changeText: false)
                }
            } catch { XCTFail("Could not observe second-round remount: \(error)") }
        }
        defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompts[1]])
        let second = try await waitForState("complete", fixture.transport, token: token)
        let replaced = try XCTUnwrap(replacement)
        XCTAssertEqual(replaced["oldRootDisconnected"] as? Bool, true)
        XCTAssertEqual(replaced["oldBodyDisconnected"] as? Bool, true)
        XCTAssertEqual(replaced["recordKeepsOldPointers"] as? Bool, true)
        XCTAssertEqual(followingActions, ["verifyModel", "inspect"])
        XCTAssertEqual(replacementObservations.count, 2)
        let discarded = try XCTUnwrap(replacementObservations.first)
        let rebound = try XCTUnwrap(replacementObservations.last)
        XCTAssertEqual(discarded["currentPointers"] as? Bool, false)
        XCTAssertEqual(discarded["certificateLinksOldAndCurrent"] as? Bool, true)
        XCTAssertEqual(rebound["currentPointers"] as? Bool, true)
        XCTAssertEqual(rebound["receiptConsumed"] as? Bool, true)
        XCTAssertEqual(rebound["revoked"] as? Bool, false)
        let outboundValue = try await evaluate(view, "return window.fixturePrompts[1];")
        let outbound = try XCTUnwrap(outboundValue as? String)
        let secondDigest = EmbeddedWebModelTransport.outboundFingerprint(outbound)
        for observed in replacementObservations {
            XCTAssertEqual(observed["sequence"] as? Int, 2)
            XCTAssertEqual(observed["fingerprint"] as? String, secondDigest)
            XCTAssertEqual(observed["firstFingerprint"] as? String, firstProof["firstUserFingerprint"] as? String)
        }

        // This replacement already exists when a new Send is requested. Its
        // read-only preflight must recover before prepare focuses the editor.
        let stalePrior = try await replaceVerifiedGeminiQuery(view, sequence: 2, bodyOnly: false, changeText: false)
        XCTAssertNotNil(stalePrior)
        _ = try await evaluate(view, """
            const editor = document.getElementById('fixture-editor'); editor.blur();
            window.fixtureContinuationFocuses = 0;
            editor.addEventListener('focus', () => { window.fixtureContinuationFocuses++; }); return true;
            """)
        var preflightActions: [String] = []
        var preflightObservations: [[String: Any]] = []
        var prepareLedger: [String: Any]?
        fixture.transport.setBeforePageResultValidationForTesting { action in
            do {
                preflightActions.append(action)
                if action == "inspect" {
                    var proof = try await self.geminiVerifiedQueryState(view, sequence: 2)
                    let ledger = try await self.evaluate(view, "return {focuses: window.fixtureContinuationFocuses, sends: window.fixturePrompts.length, inputs: window.fixtureInputCount};") as? [String: Any]
                    proof.merge(try XCTUnwrap(ledger)) { _, new in new }
                    preflightObservations.append(proof)
                } else if action == "prepare" {
                    prepareLedger = try await self.evaluate(view, "return {focuses: window.fixtureContinuationFocuses, sends: window.fixturePrompts.length, inputs: window.fixtureInputCount};") as? [String: Any]
                    fixture.transport.setBeforePageResultValidationForTesting(nil)
                }
            } catch { XCTFail("Could not observe continuation preflight: \(error)") }
        }
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompts[2]])
        let third = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(Array(preflightActions.prefix(2)), ["inspect", "inspect"])
        XCTAssertEqual(preflightActions.last, "prepare")
        XCTAssertTrue(preflightActions.dropLast().allSatisfy { ["inspect", "verifyModel"].contains($0) })
        XCTAssertEqual(preflightObservations.count, 2)
        XCTAssertEqual(preflightObservations.first?["certificateLinksOldAndCurrent"] as? Bool, true)
        XCTAssertEqual(preflightObservations.last?["currentPointers"] as? Bool, true)
        XCTAssertEqual(preflightObservations.last?["receiptConsumed"] as? Bool, true)
        for observed in preflightObservations {
            XCTAssertEqual(observed["fingerprint"] as? String, secondDigest)
            XCTAssertEqual(observed["focuses"] as? Int, 0)
            XCTAssertEqual(observed["sends"] as? Int, 2)
            XCTAssertEqual(observed["inputs"] as? Int, 2)
        }
        XCTAssertEqual(prepareLedger?["focuses"] as? Int, 1)
        XCTAssertEqual(prepareLedger?["sends"] as? Int, 2)
        XCTAssertEqual(prepareLedger?["inputs"] as? Int, 2)
        for (index, snapshot) in [first, second, third].enumerated() {
            let proof = try XCTUnwrap(snapshot["modelProofContext"] as? [String: Any])
            XCTAssertEqual(proof["sequence"] as? Int, index + 1)
            XCTAssertEqual(proof["baselineResponseCount"] as? Int, index)
            XCTAssertEqual(proof["responseCount"] as? Int, index + 1)
            XCTAssertEqual(proof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(prompts[index]))
            XCTAssertEqual(proof["firstUserFingerprint"] as? String, firstProof["firstUserFingerprint"] as? String)
            XCTAssertEqual(proof["documentGeneration"] as? String, firstProof["documentGeneration"] as? String)
            XCTAssertEqual(snapshot["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
            try assertChoiceEvidence(snapshot, choice: choice)
        }
        XCTAssertEqual(fixture.browser.documentGeneration(for: tabID), generation)
        let captured = try await capturedUserPrompts(view)
        XCTAssertEqual(captured, prompts)
        try await assertChoiceLedger(view, insertions: 3, sends: 3, selections: 0)
        XCTAssertEqual(fixture.createdTabs, [tabID])
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        try await assertHumanTabIntact(fixture)
    }

    func testGeminiNextSendPreflightRejectsBodyOnlyOrAlteredPriorQueryBeforeFocus() async throws {
        for bodyOnly in [true, false] {
            let choice = Self.fixtureChoice(.gemini)
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini, initiallySelectTarget: true,
                unmountClosedMenu: true, basePage: Self.geminiQueryParagraphPage(.framed)))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            for prompt in ["Preserve first payload", "Preserve second payload\n\nExact prior content"] {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
                _ = try await waitForState("complete", fixture.transport, token: token)
            }
            let value = try await replaceVerifiedGeminiQuery(view, sequence: 2, bodyOnly: bodyOnly, changeText: !bodyOnly)
            let replaced = try XCTUnwrap(value)
            XCTAssertEqual(replaced["oldRootDisconnected"] as? Bool, !bodyOnly)
            XCTAssertEqual(replaced["oldBodyDisconnected"] as? Bool, true)
            _ = try await evaluate(view, """
                const editor = document.getElementById('fixture-editor'); editor.blur();
                window.fixtureContinuationFocuses = 0;
                editor.addEventListener('focus', () => { window.fixtureContinuationFocuses++; }); return true;
                """)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Do not insert third payload"])
                XCTFail("Unproved prior replacement must fail before continuation preparation")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never retry the rejected append"])
            let focuses = try await evaluate(view, "return window.fixtureContinuationFocuses;") as? Int
            XCTAssertEqual(focuses, 0)
            try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 0)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
            try await assertHumanTabIntact(fixture, retaining: tabID)
        }
    }

    func testGeminiBetweenInvocationBodyOnlyOrChangedQueryCannotRebindOrReplay() async throws {
        for bodyOnly in [true, false] {
            let choice = Self.fixtureChoice(.gemini)
            let fixture = try Fixture(page: Self.modelChoicePage(.gemini, initiallySelectTarget: true,
                unmountClosedMenu: true, basePage: Self.geminiQueryParagraphPage(.framed)))
            defer { fixture.shutdown() }
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            var replacement: [String: Any]?
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "inspect", replacement == nil else { return }
                do {
                    replacement = try await self.replaceVerifiedGeminiQuery(view, bodyOnly: bodyOnly, changeText: !bodyOnly)
                } catch { XCTFail("Could not establish the rejected replacement fixture: \(error)") }
            }
            defer { fixture.transport.setBeforePageResultValidationForTesting(nil) }
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "Preserve exact first query\n\nAnd its nonce"])
                _ = try await waitForState("complete", fixture.transport, token: token)
                XCTFail("Neither a body-only replacement nor changed whole-root content may rebind")
            } catch {
                let failure = try XCTUnwrap(error as? EmbeddedWebModelTransport.Failure)
                XCTAssertTrue(failure == .ownershipFailure(.javaScriptSubmission) || failure == .ownershipFailure(.javaScriptFirstUser))
            }
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            let replaced = try XCTUnwrap(replacement)
            XCTAssertEqual(replaced["verifiedBeforeReplacement"] as? Bool, true)
            XCTAssertEqual(replaced["firstPinMatches"] as? Bool, true)
            XCTAssertEqual(replaced["oldRootDisconnected"] as? Bool, !bodyOnly)
            XCTAssertEqual(replaced["oldBodyDisconnected"] as? Bool, true)
            XCTAssertEqual(replaced["recordKeepsOldPointers"] as? Bool, true)
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never replay or append after rejected replacement"])
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 0)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
            try await assertHumanTabIntact(fixture, retaining: tabID)
        }
    }

    func testGeminiQueryParagraphsRejectUnrecognizedHeadersExtraRowsAndControlsWithoutReplay() async throws {
        for variant in [GeminiQueryParagraphVariant.unclippedHeader, .forgedHeader, .extraRow, .rowControl, .mixedFrame] {
            let fixture = try Fixture(page: Self.geminiQueryParagraphPage(variant))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "An exact query\n\nLast literal line"])
                _ = try await waitForState("complete", fixture.transport, token: token)
                XCTFail("Malformed query payload must not complete: \(variant)")
            } catch {
                let failure = try XCTUnwrap(error as? EmbeddedWebModelTransport.Failure)
                XCTAssertTrue(failure == .ownershipFailure(.javaScriptSubmission) || failure == .ownershipFailure(.javaScriptFirstUser), "\(variant): \(failure)")
            }
            await assertRejected(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never replay the failed query"])
            let countValue = try await evaluate(view, "return { sends: window.fixturePrompts.length, inputs: window.fixtureInputCount };")
            let counts = try XCTUnwrap(countValue as? [String: Any])
            XCTAssertEqual(counts["sends"] as? Int, 1, "\(variant)")
            XCTAssertEqual(counts["inputs"] as? Int, 1, "\(variant)")
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed", "An unproved payload must retain its failed lease")
            XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
            try await assertHumanTabIntact(fixture, retaining: tabID)
        }
    }

    func testGeminiChangedPriorQueryParagraphRejectsSecondSubmissionWithoutInsertion() async throws {
        for variant in [GeminiQueryParagraphVariant.literal, .framed] {
            let fixture = try Fixture(page: Self.geminiQueryParagraphPage(variant))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "gemini"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let tabID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: tabID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Preserve the first row\n\nAnd the final row"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            _ = try await evaluate(view, "document.querySelector('user-query .query-text-line').firstChild.data = 'Changed prior row'; return true;")
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Never insert after prior payload drift"])
                XCTFail("A changed prior row must revoke second-round admission")
            } catch {
                let failure = try XCTUnwrap(error as? EmbeddedWebModelTransport.Failure)
                XCTAssertTrue(failure == .ownershipFailure(.javaScriptSubmission) || failure == .ownershipFailure(.javaScriptFirstUser))
            }
            let countValue = try await evaluate(view, "return { sends: window.fixturePrompts.length, inputs: window.fixtureInputCount };")
            let counts = try XCTUnwrap(countValue as? [String: Any])
            XCTAssertEqual(counts["sends"] as? Int, 1)
            XCTAssertEqual(counts["inputs"] as? Int, 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            XCTAssertTrue(fixture.browser.webView(for: tabID) === view)
            try await assertHumanTabIntact(fixture, retaining: tabID)
        }
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

    func testChatTurnSubmissionProofRetainsOneOwnedViewAcrossThreeExactRounds() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await fixturePhaseProbe("start") { try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"]) }
        XCTAssertEqual(started["turnContinuationCapability"] as? String, "per_submission_ownership_v1")
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await fixturePhaseProbe("wait_fixture") { try await waitForFixture(view) }
        _ = try await fixturePhaseProbe("ready") { try await waitForState("ready", fixture.transport, token: token) }
        let prompts = ["Complete first request {\"input\":[\"literal .:/-\"]}",
        "Full second request\n  preserved spaces\tand\u{00a0}NBSP", "Complete third request"]
        var firstPin: String?
        for (index, prompt) in prompts.enumerated() {
            let sent = try await fixturePhaseProbe("send") { try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt]) }
            XCTAssertEqual(sent["state"] as? String, "running")
            let complete = try await fixturePhaseProbe("complete") { try await waitForState("complete", fixture.transport, token: token) }
            let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            XCTAssertEqual(proof["sequence"] as? Int, index + 1)
            XCTAssertEqual(proof["responseCount"] as? Int, index + 1)
            XCTAssertEqual(proof["baselineResponseCount"] as? Int, index)
            XCTAssertEqual(proof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(prompt))
            let pin = try XCTUnwrap(proof["firstUserFingerprint"] as? String)
            if let firstPin { XCTAssertEqual(pin, firstPin) } else { firstPin = pin }
            XCTAssertTrue(fixture.browser.webView(for: ownedID) === view)
        }
        let capturedPrompts = try await capturedUserPrompts(view)
        let captured = try XCTUnwrap(capturedPrompts)
        XCTAssertEqual(captured.map { $0.trimmingCharacters(in: .newlines) }, prompts)
        let inputCount = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        XCTAssertEqual(inputCount, 3)
        let closed = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(closed["cleanup"] as? String, "not_created")
        XCTAssertNil(fixture.browser.webView(for: ownedID))
        XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID])
    }

    func testChatCollapsedSecondSubmissionWaitsForPollBeforeOneAuthorizedExpansion() async throws {
        for changedExpandedBody in [false, true] {
            let fixture = try Fixture(page: Self.collapsedSecondChatSubmissionPage(changedExpandedBody: changedExpandedBody))
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Exact first owned request"])
            let first = try await waitForState("complete", fixture.transport, token: token)
            let firstContext = try XCTUnwrap(first["modelProofContext"] as? [String: Any])
            let firstPin = try XCTUnwrap(firstContext["firstUserFingerprint"] as? String)
            var pendingProductReads = 0, expandedModelReads = 0
            var order: [String] = []
            fixture.transport.setBeforePageResultValidationDetailedForTesting { action, enforceModel in
                let observation = try? await self.evaluate(view, """
                    const state = globalThis.__computaChatSubmissionState;
                    return { users: document.querySelectorAll('[data-message-author-role="user"]').length,
                      pendingSequence: state?.pending?.sequence || 0, lastSequence: state?.lastVerified?.sequence || 0,
                      attempted: state?.pending?.expansionAttempted === true,
                      clicks: Number(document.getElementById('messages')?.getAttribute('data-fixture-current-expansion-clicks') || 0) };
                    """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
                guard let facts = observation, facts["users"] as? Int == 2 else { return }
                if action == "verifyProductMode", !enforceModel, facts["pendingSequence"] as? Int == 2 {
                    pendingProductReads += 1; order.append("pending_product")
                    XCTAssertEqual(facts["attempted"] as? Bool, false)
                    XCTAssertEqual(facts["clicks"] as? Int, 0)
                    XCTAssertEqual(facts["lastSequence"] as? Int, 1)
                }
                if ["inspect", "verifyModel"].contains(action), enforceModel, facts["lastSequence"] as? Int == 2 {
                    expandedModelReads += 1; order.append("expanded_model")
                    XCTAssertEqual(facts["clicks"] as? Int, 1)
                }
            }
            let prompt = "Complete second canonical request\n" + String(repeating: "A", count: 512)
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
            try assertRunningOrVerifiedChoice(sent, choice: Self.fixtureChoice(.chatgpt))
            XCTAssertEqual(sent["text"] as? String, "")
            XCTAssertEqual(pendingProductReads, 0, "A continuation dispatch receipt must not inspect the pending body")
            let beforePollClicks = try await evaluate(view, "return window.fixtureCurrentExpansionClicks || 0;") as? Int
            XCTAssertEqual(beforePollClicks, 0, "Only a later inspection can claim expansion")
            if changedExpandedBody {
                do {
                    _ = try await waitForState("complete", fixture.transport, token: token)
                    XCTFail("A pending product result cannot authorize changed expanded body bytes")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
            } else {
                let complete = try await waitForState("complete", fixture.transport, token: token)
                let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
                XCTAssertEqual(proof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(prompt))
                XCTAssertEqual(proof["firstUserFingerprint"] as? String, firstPin)
                XCTAssertEqual(proof["sequence"] as? Int, 2)
                XCTAssertEqual(proof["responseCount"] as? Int, 2)
                XCTAssertGreaterThan(expandedModelReads, 0)
                XCTAssertEqual(order.first, "expanded_model")
            }
            fixture.transport.setBeforePageResultValidationDetailedForTesting(nil)
            XCTAssertEqual(pendingProductReads, 0)
            let captured = try await capturedUserPrompts(view)
            XCTAssertEqual(captured?.map { $0.trimmingCharacters(in: .newlines) }, ["Exact first owned request", prompt])
            let inputs = try await evaluate(view, "return window.fixtureInputCount;") as? Int
            let clicks = try await evaluate(view, "return window.fixtureCurrentExpansionClicks;") as? Int
            XCTAssertEqual(inputs, 2); XCTAssertEqual(clicks, 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, changedExpandedBody ? "failed" : "not_created")
            try await assertHumanTabIntact(fixture, retaining: changedExpandedBody ? ownedID : nil)
        }
    }

    func testChatSubmissionFailurePublishesFinitePhysicalFactsWithoutAnotherInput() async throws {
        for bodyOnly in [false, true] {
            let fixture = try Fixture()
            defer { fixture.shutdown() }
            let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await waitForFixture(view)
            _ = try await waitForState("ready", fixture.transport, token: token)
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "PRIVATE_CHAT_DIAGNOSTIC_CANARY"])
            _ = try await waitForState("complete", fixture.transport, token: token)
            _ = try await evaluate(view, bodyOnly ? """
                const body = document.querySelector('[data-markdown-text-style="user-message"]');
                body.replaceWith(body.cloneNode(true)); return true;
                """ : """
                const root = document.querySelector('[data-message-author-role="user"]');
                root.replaceWith(root.cloneNode(true)); return true;
                """)
            var emissions: [(String, String)] = []
            fixture.transport.setSubmissionDiagnosticsObserverForTesting { event, encoded in emissions.append((event, encoded)) }
            do {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Must not insert another request"])
                XCTFail("An uncertified physical replacement must remain rejected")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
            fixture.transport.setSubmissionDiagnosticsObserverForTesting(nil)
            let adapter = try XCTUnwrap(emissions.first { $0.0 == "submissionChatAdapter" })
            let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(adapter.1.utf8)) as? [String: Any])
            XCTAssertEqual(facts["stage"] as? String, "observe_body")
            XCTAssertEqual(facts["recordSequence"] as? Int, 1)
            XCTAssertEqual(facts["userCount"] as? Int, 1)
            XCTAssertEqual(facts["canonicalMatches"] as? Bool, true)
            XCTAssertEqual(facts["contextMatches"] as? Bool, true)
            XCTAssertEqual(facts["nativePinMatches"] as? Bool, true)
            XCTAssertEqual(facts["rootSame"] as? Bool, bodyOnly)
            XCTAssertEqual(facts["bodySame"] as? Bool, false)
            XCTAssertEqual(facts["oldRootConnected"] as? Bool, bodyOnly)
            XCTAssertEqual(facts["oldBodyConnected"] as? Bool, false)
            XCTAssertEqual(facts["currentRootConnected"] as? Bool, true)
            XCTAssertEqual(facts["currentBodyConnected"] as? Bool, true)
            XCTAssertTrue(emissions.contains { $0.0 == "submissionNative" })
            XCTAssertTrue(emissions.allSatisfy { $0.1.utf8.count <= 960 && !$0.1.contains("PRIVATE_CHAT_DIAGNOSTIC_CANARY") && !$0.1.contains(token) })
            let inputCount = try await evaluate(view, "return window.fixtureInputCount;") as? Int
            let sends = try await evaluate(view, "return window.fixturePrompts.length;") as? Int
            XCTAssertEqual(inputCount, 1); XCTAssertEqual(sends, 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            try await assertHumanTabIntact(fixture, retaining: ownedID)
        }
    }

    func testChatTurnPilotLimitsRejectBeforeAnotherInsertionAndKeepCleanupOwned() async throws {
        for largePrompts in [false, true] {
            let fixture = try Fixture()
            defer { fixture.shutdown() }
            let started = try await fixturePhaseProbe("start") { try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"]) }
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
            try await fixturePhaseProbe("wait_fixture") { try await waitForFixture(view) }
            _ = try await fixturePhaseProbe("ready") { try await waitForState("ready", fixture.transport, token: token) }
            let accepted = EmbeddedWebModelTransport.maximumTurnSubmissions
            let prompt = largePrompts ? String(repeating: "A", count: 170_000) : "Exact bounded round"
            XCTAssertEqual(EmbeddedWebModelTransport.maximumTurnUTF8Bytes,
                           EmbeddedWebModelTransport.maximumTurnSubmissions * EmbeddedWebModelTransport.maximumSubmissionUTF8Bytes)
            if largePrompts { XCTAssertGreaterThan(accepted * prompt.utf8.count, 1_048_576) }
            for _ in 0..<accepted {
                _ = try await fixturePhaseProbe("send") { try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt]) }
                _ = try await fixturePhaseProbe("complete") { try await waitForState("complete", fixture.transport, token: token) }
            }
            for _ in 0..<2 {
                do {
                    _ = try await fixturePhaseProbe("send") { try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt]) }
                    XCTFail("No insertion or Send beyond the pilot bound")
                } catch let failure as EmbeddedWebModelTransport.Failure { XCTAssertEqual(failure, .turnLimit) }
            }
            let inputCount = try await evaluate(view, "return window.fixtureInputCount;") as? Int
            let sends = try await evaluate(view, "return window.fixturePrompts.length;") as? Int
            XCTAssertEqual(inputCount, accepted); XCTAssertEqual(sends, accepted)
            XCTAssertEqual(fixture.createdTabs.count, 1)
            let closed = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(closed["cleanup"] as? String, "not_created")
            XCTAssertNil(fixture.browser.webView(for: ownedID))
            XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.humanID])
        }
    }

    func testOwnedTemporaryChatSendsLiteralTextAndClosesOnlyItsTab() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await fixturePhaseProbe("start") { try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"]) }
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let ownedView = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        XCTAssertEqual(fixture.browser.selectedTabID, fixture.humanID)
        XCTAssertTrue(ownedView.configuration.websiteDataStore === fixture.humanView.configuration.websiteDataStore)
        try await fixturePhaseProbe("wait_fixture") { try await waitForFixture(ownedView) }
        let documentURL = try await fixturePhaseProbe("evaluate_document") { try await evaluate(ownedView, "return document.URL;") } as? String
        XCTAssertEqual(documentURL, "https://chatgpt.com/")
        _ = try await fixturePhaseProbe("ready") { try await waitForState("ready", fixture.transport, token: token) }
        let temporaryURL = try await fixturePhaseProbe("evaluate_document") { try await evaluate(ownedView, "return document.URL;") } as? String
        XCTAssertEqual(temporaryURL, "https://chatgpt.com/?temporary-chat=true")

        let prompt = "A \"quote\", a \\ backslash, C++ & Swift\n\nASCII  spaces\tand\u{00a0}NBSP\n  {\"key\":\"escaped tags </script><script>window.fixtureInjected = true</script>\"}\nTail \"double quote\""
        let sent = try await fixturePhaseProbe("send") { try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt]) }
        XCTAssertEqual(sent["state"] as? String, "running")
        let complete = try await fixturePhaseProbe("complete") { try await waitForState("complete", fixture.transport, token: token) }
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

    func testChatTurnRenderedMarkdownCannotSupplyTheFullOutboundDigest() async throws {
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
        do {
            _ = try await fixturePhaseProbe("rendered_markdown_send") { try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt]) }
            XCTFail("Rendered CODE nodes missing literal source delimiters cannot prove the complete outbound request")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
        let captured = try await capturedUserPrompts(view)
        XCTAssertTrue(captured == [prompt] || captured == [prompt + "\n"])
        let codeCount = try await evaluate(view, "return document.querySelector('[data-user-message-bubble]').querySelectorAll('code').length;") as? Int
        XCTAssertEqual(codeCount, 2)
        let rawBody = try await evaluate(view, "return document.querySelector('.whitespace-pre-wrap').innerText;") as? String
        XCTAssertFalse(rawBody?.contains("`tool_calls`") == true)
        for operation in ["webProviderPoll", "webProviderSend"] {
            var params = ["sessionToken": token]
            if operation == "webProviderSend" { params["prompt"] = "Must not continue an unverified body" }
            do { _ = try await call(fixture.transport, operation, params); XCTFail("No response or next Send after canonical mismatch") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptSubmission)) }
        }
        let inputs = try await evaluate(view, "return window.fixtureInputCount;") as? Int
        let sends = try await evaluate(view, "return window.fixturePrompts.length;") as? Int
        XCTAssertEqual(inputs, 1); XCTAssertEqual(sends, 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        try await assertHumanTabIntact(fixture, retaining: ownedID)
    }

    func testChatTurnExactLiteralMarkdownDelimitersRetainTheFullOutboundDigest() async throws {
        let fixture = try Fixture()
        defer { fixture.shutdown() }
        let started = try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        try await waitForFixture(view)
        _ = try await waitForState("ready", fixture.transport, token: token)
        let prompts = ["Use `tool_calls` and `exec_command` with literal source delimiters", "Exact second request"]
        for prompt in prompts {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": prompt])
            let complete = try await waitForState("complete", fixture.transport, token: token)
            let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            XCTAssertEqual(proof["submittedPromptFingerprint"] as? String, EmbeddedWebModelTransport.promptFingerprint(prompt))
        }
        let captured = try await capturedUserPrompts(view)
        XCTAssertEqual(captured?.map { $0.trimmingCharacters(in: .newlines) }, prompts)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
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
        print("WKFixturePhase test=changing_first_prompt phase=fixture boundary=begin")
        let fixture = try Fixture()
        fixture.traceLifecycle = true
        print("WKFixturePhase test=changing_first_prompt phase=fixture boundary=end")
        defer { fixture.shutdown() }
        let started = try await fixturePhaseProbe("changing_start", trace: true) {
            try await call(fixture.transport, "webProviderStart", ["provider": "chatgpt"])
        }
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let ownedID = try XCTUnwrap(fixture.createdTabs.last)
        let view = try XCTUnwrap(fixture.browser.webView(for: ownedID))
        try await fixturePhaseProbe("changing_fixture_ready", trace: true) { try await waitForFixture(view) }
        _ = try await evaluate(view, """
            document.querySelector('[data-testid="send-button"]').addEventListener('click', () => {
                history.pushState({}, '', '/c/local-chatgpt%3Afixture?temporary-chat=true');
            }); return true;
            """)
        _ = try await fixturePhaseProbe("changing_provider_ready", trace: true) {
            try await waitForState("ready", fixture.transport, token: token)
        }
        _ = try await fixturePhaseProbe("changing_send", trace: true) {
            try await call(fixture.transport, "webProviderSend", ["sessionToken": token, "prompt": "Original owned prompt"])
        }
        _ = try await fixturePhaseProbe("changing_complete", trace: true) {
            try await waitForState("complete", fixture.transport, token: token)
        }
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
        let finished = try await fixturePhaseProbe("changing_finish", trace: true) {
            try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        }
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

    private func stageModernOnlyEmptyChatGPTAnswer(_ view: WKWebView) async throws {
        let shape = try await evaluate(view, """
            const user = document.querySelector('[data-message-author-role="user"]');
            const userBody = user.querySelector('[data-markdown-text-style="user-message"]');
            userBody.removeAttribute('data-markdown-text-style'); userBody.classList.add('whitespace-pre-wrap');
            const answer = document.querySelector('[data-markdown-text-style="assistant-message"]');
            const body = answer.firstElementChild;
            body.removeAttribute('data-markdown-text-style'); body.textContent = '';
            body.id = 'fixture-empty-modern-answer-body';
            const copy = answer.parentElement.querySelector('button[aria-label="Copy"]');
            return { modernUsers: document.querySelectorAll('[data-markdown-text-style="user-message"]').length,
              legacyUsers: document.querySelectorAll('[data-message-author-role="user"]').length,
              modernAssistants: document.querySelectorAll('[data-markdown-text-style="assistant-message"]').length,
              legacyAssistants: document.querySelectorAll('[data-message-author-role="assistant"], article[data-turn="assistant"]').length,
              rootChildren: answer.childElementCount, rootTextLength: answer.textContent.length,
              bodyChildren: body.childElementCount, bodyTextLength: body.textContent.length,
              enabledCopy: !!copy && !copy.disabled,
              stop: !!document.querySelector('button[data-testid="stop-button"], button[aria-label="Stop streaming"], button[aria-label="Stop generating"], button[aria-label="Stop"]') };
            """) as? [String: Any]
        XCTAssertEqual(shape?["modernUsers"] as? Int, 0)
        XCTAssertEqual(shape?["legacyUsers"] as? Int, 1)
        XCTAssertEqual(shape?["modernAssistants"] as? Int, 1)
        XCTAssertEqual(shape?["legacyAssistants"] as? Int, 0)
        XCTAssertEqual(shape?["rootChildren"] as? Int, 1)
        XCTAssertEqual(shape?["rootTextLength"] as? Int, 0)
        XCTAssertEqual(shape?["bodyChildren"] as? Int, 0)
        XCTAssertEqual(shape?["bodyTextLength"] as? Int, 0)
        XCTAssertEqual(shape?["enabledCopy"] as? Bool, true)
        XCTAssertEqual(shape?["stop"] as? Bool, false)
    }

    func testChatGPTEmptyModernAnswerCannotPublishOrExtendTheResponseDeadline() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .seconds(3))
        let began = ContinuousClock.now
        _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
            "prompt": "An empty assistant with a footer cannot complete this response"])
        try await stageModernOnlyEmptyChatGPTAnswer(view)
        var diagnostics: [String] = []
        fixture.transport.setResponseProgressDiagnosticObserverForTesting { diagnostics.append($0) }
        var pendingReads = 0
        var expired = false
        let bound = began + .seconds(5)
        while ContinuousClock.now < bound {
            do {
                let pending = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(pending["state"] as? String, "running")
                try assertRunningOrVerifiedChoice(pending, choice: choice)
                XCTAssertNil(pending["completionEvidence"])
                pendingReads += 1
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline)
                expired = true
                break
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        XCTAssertGreaterThan(pendingReads, 1)
        XCTAssertTrue(expired, "Repeated empty completed-footer reads must not renew the original response deadline")
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(4_500))
        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(diagnostic.utf8)) as? [String: Any])
        XCTAssertEqual(record["cause"] as? String, "response_deadline")
        let inspection = try XCTUnwrap(record["lastInspection"] as? [String: Any])
        XCTAssertEqual(inspection["responseCount"] as? Int, 1)
        XCTAssertEqual(inspection["userCount"] as? Int, 1)
        XCTAssertEqual(inspection["answerComplete"] as? Bool, true)
        XCTAssertEqual(inspection["busy"] as? Bool, false)
        XCTAssertEqual(inspection["textBytes"] as? Int, 0)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTDelayedModernAnswerStartsItsOwnQuietIntervalAndFullProof() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(
            prompt: "Wait for nonempty content in the same modern assistant", bindFirstRead: false)
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        try await stageModernOnlyEmptyChatGPTAnswer(view)
        let empty = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(empty["state"] as? String, "running")
        try assertRunningOrVerifiedChoice(empty, choice: choice)
        let pickerClicksValue = try await evaluate(view, "return window.fixtureModelTriggerClicks;")
        let pickerClicks = try XCTUnwrap(pickerClicksValue as? Int)
        try await Task.sleep(for: .milliseconds(1_750))
        let stillEmpty = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(stillEmpty["state"] as? String, "running")
        try assertRunningOrVerifiedChoice(stillEmpty, choice: choice)
        let emptyPickerClicks = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
        XCTAssertEqual(emptyPickerClicks, pickerClicks, "Empty text must not trigger a full completion picker proof")
        _ = try await evaluate(view, #"document.getElementById('fixture-empty-modern-answer-body').textContent = '{"type":"message","text":"Actual delayed answer"}'; return true;"#)
        let nonemptyBegan = ContinuousClock.now
        let candidate = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(candidate["state"] as? String, "running", "Time spent empty cannot satisfy the answer's quiet interval")
        try assertRunningOrVerifiedChoice(candidate, choice: choice)
        let candidatePickerClicks = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
        XCTAssertEqual(candidatePickerClicks, pickerClicks)
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - nonemptyBegan, .milliseconds(1_500))
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Actual delayed answer"}"#)
        try assertChoiceEvidence(complete, choice: choice)
        XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
        let context = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual(context["responseCount"] as? Int, 1)
        let verifiedPickerClicksValue = try await evaluate(view, "return window.fixtureModelTriggerClicks;")
        let verifiedPickerClicks = try XCTUnwrap(verifiedPickerClicksValue as? Int)
        XCTAssertGreaterThan(verifiedPickerClicks, pickerClicks, "Only the later real answer may obtain fresh full model proof")
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
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

    func testChatGPTQuietCompletionUsesOneFreshFullInspectionAcrossRetainedRounds() async throws {
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt))
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        let started = try await startChoice(choice, in: fixture)
        let token = try XCTUnwrap(started["sessionToken"] as? String)
        let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
        _ = try await waitForState("ready", fixture.transport, token: token)
        for sequence in 1...2 {
            _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "Verify fresh quiet completion round \(sequence)"])
            let candidate = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(candidate["state"] as? String, "running")
            try assertRunningOrVerifiedChoice(candidate, choice: choice)
            try await Task.sleep(for: .milliseconds(1_650))
            var actions: [String] = []
            fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
            let complete = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertEqual(complete["state"] as? String, "complete")
            XCTAssertEqual(actions, ["inspect"], "The quiet poll must perform one current full proof, not a deferred read followed by another inspect")
            try assertChoiceEvidence(complete, choice: choice)
            XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
            let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            XCTAssertEqual(proof["sequence"] as? Int, sequence)
            XCTAssertEqual(proof["responseCount"] as? Int, sequence)
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        }
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTQuietCompletionChangedAnswerRearmsBeforePublishing() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Do not publish an answer changed after its quiet candidate")
        defer { fixture.shutdown() }
        try await Task.sleep(for: .milliseconds(1_650))
        let pickerObserved = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
        let pickerBefore = try XCTUnwrap(pickerObserved)
        _ = try await evaluate(view, """
            const answers = [...document.querySelectorAll('[data-markdown-text-style="assistant-message"]')];
            answers.at(-1).textContent = '{"type":"message","text":"Changed quiet reply"}'; return true;
            """)
        var actions: [String] = []
        fixture.transport.setBeforePageResultValidationForTesting { actions.append($0) }
        let changed = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertEqual(changed["state"] as? String, "running")
        try assertRunningOrVerifiedChoice(changed, choice: Self.fixtureChoice(.chatgpt))
        XCTAssertEqual(actions, ["inspect"])
        let pickerAfter = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
        XCTAssertEqual(pickerAfter, pickerBefore, "Changed candidate bytes must return a deferred observation without opening the picker")
        let began = ContinuousClock.now
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(1_500), "Changed bytes require a new full quiet interval")
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Changed quiet reply"}"#)
        try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTQuietCompletionBusyOrMissingFooterCannotPublish() async throws {
        for interrupted in ["busy", "footer"] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Require a currently complete answer after quiet: \(interrupted)")
            defer { fixture.shutdown() }
            try await Task.sleep(for: .milliseconds(1_650))
            let pickerObserved = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
            let pickerBefore = try XCTUnwrap(pickerObserved)
            _ = try await evaluate(view, interrupted == "busy" ? """
                const stop = document.createElement('button'); stop.id = 'fixture-quiet-stop';
                stop.setAttribute('data-testid', 'stop-button'); stop.textContent = 'Stop generating'; document.body.append(stop); return true;
                """ : "document.querySelector('button[aria-label=\"Copy\"]').disabled = true; return true;")
            let incomplete = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(incomplete["state"] as? String, "running", interrupted)
            try assertRunningOrVerifiedChoice(incomplete, choice: Self.fixtureChoice(.chatgpt))
            let pickerAfter = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
            XCTAssertEqual(pickerAfter, pickerBefore, "A newly busy answer or missing completion footer must not open the picker")
            _ = try await evaluate(view, interrupted == "busy"
                ? "document.getElementById('fixture-quiet-stop').remove(); return true;"
                : "document.querySelector('button[aria-label=\"Copy\"]').disabled = false; return true;")
            let candidate = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(candidate["state"] as? String, "running", "Restoring completion controls starts a new candidate")
            let began = ContinuousClock.now
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(1_500), interrupted)
            try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created", interrupted)
            try await assertHumanTabIntact(fixture)
        }
    }

    func testChatGPTQuietCompletionRejectsAnswerChangesDuringFinalPickerProof() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Keep the exact answer across the full quiet model proof")
        defer { fixture.shutdown() }
        try await Task.sleep(for: .milliseconds(1_650))
        _ = try await evaluate(view, """
            window.fixtureQuietFullProofOpens = 0; window.fixtureQuietAnswerChanged = false;
            document.getElementById('fixture-model-trigger').addEventListener('click', event => {
              if (event.currentTarget.getAttribute('aria-expanded') !== 'true') return;
              window.fixtureQuietFullProofOpens++;
              // The second full model read is the action's final guard. Its
              // captured answer must survive this awaited picker interaction.
              if (window.fixtureQuietFullProofOpens !== 2) return;
              const answers = [...document.querySelectorAll('[data-markdown-text-style="assistant-message"]')];
              answers.at(-1).textContent = '{"type":"message","text":"Changed during full proof"}';
              window.fixtureQuietAnswerChanged = true;
            }); return true;
            """)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A completed answer changed across the final picker await must not publish")
        } catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptConversation))
        }
        let changed = try await evaluate(view, "return window.fixtureQuietAnswerChanged === true;") as? Bool
        XCTAssertEqual(changed, true)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTQuietCompletionChangedAnswerCountCannotUseTheOldCandidate() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Keep the answer count bound to the quiet candidate")
        defer { fixture.shutdown() }
        try await Task.sleep(for: .milliseconds(1_650))
        _ = try await evaluate(view, """
            window.fixtureQuietAnswerAppended = false;
            document.getElementById('fixture-model-trigger').addEventListener('click', event => {
              if (window.fixtureQuietAnswerAppended || event.currentTarget.getAttribute('aria-expanded') !== 'true') return;
              window.fixtureQuietAnswerAppended = true;
              const messages = document.getElementById('messages');
              messages.append(messages.querySelector('section').cloneNode(true));
            }); return true;
            """)
        let changed = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(changed["state"] as? String, "running", "A count changed during full verification requires a new candidate even when text is identical")
        try assertRunningOrVerifiedChoice(changed, choice: Self.fixtureChoice(.chatgpt))
        let appended = try await evaluate(view, "return window.fixtureQuietAnswerAppended === true;") as? Bool
        XCTAssertEqual(appended, true)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTQuietCompletionRejectsModelAndProductDrift() async throws {
        for drift in ["model", "work"] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Keep current model and Chat mode at quiet completion")
            defer { fixture.shutdown() }
            let ownedID = try XCTUnwrap(fixture.createdTabs.last)
            try await Task.sleep(for: .milliseconds(1_650))
            _ = try await evaluate(view, drift == "model"
                ? "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;"
                : "document.getElementById('fixture-composer-mode').hidden = false; document.getElementById('fixture-chat-mode').setAttribute('aria-pressed','false'); document.getElementById('fixture-work-mode').setAttribute('aria-pressed','true'); return true;")
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("Quiet completion cannot accept \(drift) drift")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure,
                    drift == "model" ? .modelMismatch : .productModeUnverified)
            }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, drift == "work" ? "failed" : "not_created")
            try await assertHumanTabIntact(fixture, retaining: drift == "work" ? ownedID : nil)
        }
    }

    func testChatGPTQuietCompletionCancellationCannotPublishItsFullProof() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Cancellation cannot release a quiet completed answer")
        defer { fixture.shutdown() }
        try await Task.sleep(for: .milliseconds(1_650))
        var blocked = false
        var actions: [String] = []
        fixture.transport.setBeforePageResultValidationForTesting { action in
            actions.append(action)
            guard action == "inspect", !blocked else { return }
            blocked = true
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let polling = Task<Void, Error> { _ = try await self.call(fixture.transport, "webProviderPoll", ["sessionToken": token]) }
        let until = ContinuousClock.now + .seconds(10)
        while !blocked && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        polling.cancel()
        do { try await polling.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertTrue(blocked); XCTAssertEqual(actions, ["inspect"])
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testChatGPTQuietCompletionKeepsTheOriginalResponseDeadline() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "A full quiet proof cannot extend the response deadline")
        defer { fixture.shutdown() }
        fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .seconds(4))
        try await Task.sleep(for: .milliseconds(1_650))
        var crossed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect", !crossed else { return }
            crossed = true
            try? await Task.sleep(for: .milliseconds(4_050))
        }
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A late full completion proof cannot publish")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .deadline) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertTrue(crossed)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        try await assertHumanTabIntact(fixture)
    }

    func testCompletionMatchDiagnosticsRejectUnboundedOrAuthorityLikeFields() {
        let diagnostic = EmbeddedWebModelTransport.completionMatchDiagnostic(["reason": "text_relation", "routeKind": "server"])
        XCTAssertEqual(diagnostic?.reason, "text_relation")
        XCTAssertEqual(diagnostic?.routeKind, "server")
        for invalid: [String: Any] in [
            ["reason": "page text must not reach logs", "routeKind": "server"],
            ["reason": "matched", "routeKind": "https://chatgpt.com/c/private-id"],
            ["reason": "matched", "routeKind": "server", "terminalCompletionMatched": true],
            ["reason": "matched", "routeKind": 1],
            ["reason": "matched"],
        ] {
            XCTAssertNil(EmbeddedWebModelTransport.completionMatchDiagnostic(invalid))
        }
    }

    func testChatGPTTerminalCompletionPublishesBeforeQuietOnlyAfterFreshOwnedFullProofAcrossRounds() async throws {
        let (fixture, token, view) = try await terminalCompletionFixture()
        defer { fixture.shutdown() }
        let choice = Self.fixtureChoice(.chatgpt)
        for sequence in 1...2 {
            if sequence > 1 {
                _ = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                    "prompt": "A distinct owned terminal round \(sequence)"])
            }
            let arm = try await evaluate(view, "return {sequence:window.fixtureCompletion.arm.sequence,sha:window.fixtureCompletion.arm.inputSHA256,bytes:window.fixtureCompletion.arm.inputUTF8Bytes,prompt:window.fixturePrompts.at(-1)};")
            let armFields = try XCTUnwrap(arm as? [String: Any])
            XCTAssertEqual(armFields["sequence"] as? Int, sequence)
            let renderedPrompt = try XCTUnwrap(armFields["prompt"] as? String)
            let markerPrefix = "\n\nComputa session marker: "
            let markerRange = try XCTUnwrap(renderedPrompt.range(of: markerPrefix, options: .backwards))
            let renderedMarker = String(renderedPrompt[markerRange.upperBound...])
            // This fixture reads contenteditable.innerText, which can contribute
            // one presentation LF after its final paragraph. Native arms bind
            // the exact outbound string before that DOM presentation, not the LF.
            let marker = renderedMarker.hasSuffix("\n") ? String(renderedMarker.dropLast()) : renderedMarker
            XCTAssertEqual(UUID(uuidString: marker)?.uuidString.lowercased(), marker.lowercased())
            let userPrompt = sequence == 1 ? "A synthetic owned decoded-terminal response"
                : "A distinct owned terminal round \(sequence)"
            let exactOutbound = userPrompt + markerPrefix + marker
            XCTAssertTrue(renderedPrompt.utf8.elementsEqual(exactOutbound.utf8)
                || renderedPrompt.utf8.elementsEqual((exactOutbound + "\n").utf8),
                "Only the known one terminal presentation LF may differ; no broad trim or prefix reconstruction")
            XCTAssertEqual(armFields["sha"] as? String, EmbeddedWebModelTransport.promptFingerprint(exactOutbound))
            XCTAssertEqual(armFields["bytes"] as? Int, exactOutbound.utf8.count)
            let began = ContinuousClock.now
            try await postTerminalCompletion(in: fixture, view: view, token: token)
            let complete = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(complete["state"] as? String, "complete")
            XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(1_500),
                              "A matching decoded terminal must use fresh proof without waiting the 1600ms quiet guard")
            XCTAssertEqual(complete["text"] as? String, "HI")
            try assertChoiceEvidence(complete, choice: choice)
            XCTAssertNoThrow(try WebsiteProductModeEvidence.parse(complete["productModeEvidence"], requireTemporary: true))
            let context = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
            XCTAssertEqual(context["sequence"] as? Int, sequence)
            XCTAssertEqual(context["responseCount"] as? Int, sequence)
            XCTAssertNil(try terminalReceipt(in: fixture, view: view, token: token, sequence: sequence),
                         "Publication consumes the optional candidate rather than retaining completion authority")
        }
        try await assertChoiceLedger(view, insertions: 2, sends: 2, selections: 1)
        try await finishTerminalFixture(fixture, token: token)
    }

    func testChatGPTTerminalStreamFailureAbortsOnlyAfterFreshOwnedProofWithoutSendReplay() async throws {
        for reason in ["empty_stream", "provider_error"] {
            let (fixture, token, view) = try await terminalCompletionFixture()
            defer { fixture.shutdown() }
            _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"assistant-message\"]').closest('section').remove(); return true;")
            try await postTerminalFailure(in: fixture, view: view, token: token, reason: reason)
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A verified owned terminal empty/error stream must end in the current poll")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure,
                    .responseStreamFailed(reason == "empty_stream" ? .emptyStream : .providerError))
            }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            try await finishTerminalFixture(fixture, token: token)
        }
    }

    func testChatGPTTerminalStreamFailureCannotAbortBusyOrPositiveDOMResponse() async throws {
        for mode in ["busy", "positive"] {
            let (fixture, token, view) = try await terminalCompletionFixture()
            defer { fixture.shutdown() }
            if mode == "busy" {
                _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"assistant-message\"] > div').textContent=''; const stop=document.createElement('button');stop.setAttribute('data-testid','stop-button');stop.textContent='Stop';document.body.append(stop);return true;")
            }
            try await postTerminalFailure(in: fixture, view: view, token: token)
            let state = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertTrue(["running", "complete"].contains(state["state"] as? String ?? ""))
            if mode == "busy" { XCTAssertEqual(state["state"] as? String, "running") }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            try await finishTerminalFixture(fixture, token: token)
        }
    }

    func testChatGPTTerminalStreamFailureRechecksModelAndRevocationAcrossInspection() async throws {
        for mode in ["model", "revoke", "deadline"] {
            let (fixture, token, view) = try await terminalCompletionFixture()
            defer { fixture.shutdown() }
            _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"assistant-message\"]').closest('section').remove(); return true;")
            try await postTerminalFailure(in: fixture, view: view, token: token)
            if mode == "model" { _ = try await evaluate(view, "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;") }
            if mode == "deadline" { fixture.transport.setTimeoutsForTesting(preparation: .seconds(45), response: .milliseconds(1)) }
            let tab = try XCTUnwrap(fixture.createdTabs.last)
            var revoked = false
            if mode == "revoke" {
                fixture.transport.setBeforePageResultValidationForTesting { action in
                    guard action == "inspect", !revoked else { return }
                    revoked = true; fixture.browser.revokeChatGPTResponseCompletion(tabID: tab, ownerToken: token)
                }
            }
            do {
                let value = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTAssertEqual(mode, "revoke"); XCTAssertTrue(revoked)
                XCTAssertEqual(value["state"] as? String, "running")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, mode == "model" ? .modelMismatch : .deadline)
            }
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            try await finishTerminalFixture(fixture, token: token)
        }
    }

    func testChatGPTTerminalStreamFailureCannotBypassChangedCurrentSubmission() async throws {
        let (fixture, token, view) = try await terminalCompletionFixture()
        defer { fixture.shutdown() }
        _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"assistant-message\"]').closest('section').remove(); return true;")
        try await postTerminalFailure(in: fixture, view: view, token: token)
        _ = try await evaluate(view, "const body=document.querySelector('[data-markdown-text-style=\"user-message\"]');window.fixtureOriginalSubmissionBody=body.textContent;body.textContent='A different unowned submission';return true;")
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A terminal failure candidate cannot replace current-submission proof")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser)) }
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"user-message\"]').textContent=window.fixtureOriginalSubmissionBody;return true;")
        try await finishTerminalFixture(fixture, token: token)
    }

    func testChatGPTTerminalStreamFailureCancellationDuringFreshProofCannotAbortOrAccept() async throws {
        let (fixture, token, view) = try await terminalCompletionFixture()
        defer { fixture.shutdown() }
        _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"assistant-message\"]').closest('section').remove(); return true;")
        try await postTerminalFailure(in: fixture, view: view, token: token)
        var cancelled = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect", !cancelled else { return }
            cancelled = true
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let poll = Task { @MainActor in
            _ = try await self.call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        }
        do { _ = try await poll.value; XCTFail("Cancellation must win over a terminal observation") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertTrue(cancelled)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        try await finishTerminalFixture(fixture, token: token)
    }

    func testChatGPTTerminalCompletionBeforeDOMCannotPublishUntilExactNonemptyAnswerAndFooter() async throws {
        let (fixture, token, view) = try await terminalCompletionFixture()
        defer { fixture.shutdown() }
        _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"assistant-message\"] > div').textContent=''; document.querySelector('button[aria-label=\"Copy\"]').disabled=true; return true;")
        try await postTerminalCompletion(in: fixture, view: view, token: token)
        let empty = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(empty["state"] as? String, "running")
        XCTAssertEqual(empty["text"] as? String, "")
        try assertRunningOrVerifiedChoice(empty, choice: Self.fixtureChoice(.chatgpt))
        _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"assistant-message\"] > div').textContent='HI'; return true;")
        let noFooter = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(noFooter["state"] as? String, "running", "Terminal evidence cannot replace a currently enabled scoped footer")
        _ = try await evaluate(view, "document.querySelector('button[aria-label=\"Copy\"]').disabled=false; return true;")
        let began = ContinuousClock.now
        let complete = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(complete["state"] as? String, "complete")
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(1_500))
        try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
        try await finishTerminalFixture(fixture, token: token)
    }

    func testChatGPTTerminalCompletionAbsentStaleWrongMessageOrDifferentBytesRetainsQuietFallback() async throws {
        for mismatch in ["absent", "sequence", "message", "text"] {
            let (fixture, token, view) = try await terminalCompletionFixture()
            defer { fixture.shutdown() }
            if mismatch != "absent" {
                let overrides: [String: Any] = mismatch == "sequence" ? ["sequence": 2]
                    : mismatch == "message" ? ["messageID": UUID().uuidString.lowercased()]
                    : ["text": "HI\n"]
                try await postTerminalCompletion(in: fixture, view: view, token: token,
                    overrides: overrides, expectsReceipt: mismatch != "sequence")
            }
            let began = ContinuousClock.now
            let pending = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(pending["state"] as? String, "running", mismatch)
            try assertRunningOrVerifiedChoice(pending, choice: Self.fixtureChoice(.chatgpt))
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(1_500), mismatch)
            XCTAssertEqual(complete["text"] as? String, "HI", "The observed answer is never replaced by candidate text")
            try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            try await finishTerminalFixture(fixture, token: token)
        }
    }

    func testChatGPTTerminalCompletionChangedFinalDOMCannotUseOldTerminalBytes() async throws {
        let (fixture, token, view) = try await terminalCompletionFixture()
        defer { fixture.shutdown() }
        try await postTerminalCompletion(in: fixture, view: view, token: token)
        _ = try await evaluate(view, "document.querySelector('[data-markdown-text-style=\"assistant-message\"] > div').textContent='Changed final text'; return true;")
        let began = ContinuousClock.now
        let pending = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(pending["state"] as? String, "running")
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(1_500))
        XCTAssertEqual(complete["text"] as? String, "Changed final text")
        try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
        try await finishTerminalFixture(fixture, token: token)
    }

    func testChatGPTTerminalCompletionAnswerMutationDuringFinalPickerProofCannotPublish() async throws {
        let (fixture, token, view) = try await terminalCompletionFixture()
        defer { fixture.shutdown() }
        try await postTerminalCompletion(in: fixture, view: view, token: token)
        _ = try await evaluate(view, """
            window.fixtureTerminalProofOpens=0; window.fixtureTerminalMutated=false;
            document.getElementById('fixture-model-trigger').addEventListener('click', event => {
              if (event.currentTarget.getAttribute('aria-expanded') !== 'true') return;
              if (++window.fixtureTerminalProofOpens !== 2) return;
              document.querySelector('[data-markdown-text-style="assistant-message"] > div').textContent='Changed across final proof';
              window.fixtureTerminalMutated=true;
            }); return true;
            """)
        do {
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            XCTFail("A terminal cannot release bytes changed during the final full picker proof")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptConversation)) }
        let mutated = try await evaluate(view, "return window.fixtureTerminalMutated;") as? Bool
        XCTAssertEqual(mutated, true)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        try await finishTerminalFixture(fixture, token: token)
    }

    func testChatGPTTerminalCompletionRevokedDuringFinalAwaitCannotPublish() async throws {
        let (fixture, token, view) = try await terminalCompletionFixture()
        defer { fixture.shutdown() }
        try await postTerminalCompletion(in: fixture, view: view, token: token)
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        var inspections = 0
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect" else { return }
            inspections += 1
            if inspections == 2 { fixture.browser.revokeChatGPTResponseCompletion(tabID: tabID, ownerToken: token) }
        }
        let pending = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertEqual(inspections, 2, "Exercise revocation after the full proof's WebKit await, not before candidate admission")
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertNil(try terminalReceipt(in: fixture, view: view, token: token))
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["state"] as? String, "complete", "Revocation retains ordinary quiet completion")
        try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
        try await finishTerminalFixture(fixture, token: token)
    }

    func testChatGPTTerminalCompletionCancellationDuringFinalAwaitCannotPublish() async throws {
        let (fixture, token, view) = try await terminalCompletionFixture()
        defer { fixture.shutdown() }
        try await postTerminalCompletion(in: fixture, view: view, token: token)
        var inspections = 0, blocked = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            guard action == "inspect" else { return }
            inspections += 1
            guard inspections == 2 else { return }
            blocked = true
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let polling = Task<Void, Error> { _ = try await self.call(fixture.transport, "webProviderPoll", ["sessionToken": token]) }
        let until = ContinuousClock.now + .seconds(10)
        while !blocked && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        polling.cancel()
        do { try await polling.value; XCTFail("A cancelled final proof cannot publish decoded terminal completion") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.transport.setBeforePageResultValidationForTesting(nil)
        XCTAssertTrue(blocked)
        XCTAssertEqual(inspections, 2)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        try await finishTerminalFixture(fixture, token: token)
    }

    /// This source substitutes only the website stream decoder. Arming and all
    /// callbacks still cross the actual main-world WK handler, native lease,
    /// transport, isolated adapter, and current picker/product/answer proof.
    private static let terminalCompletionFixtureSource = #"""
    (() => {
      const config=__COMPUTA_COMPLETION_CONFIG__;
      window.fixtureCompletion={arm:null,posts:0,stops:0};
      const api=Object.freeze({arm(arm){ window.fixtureCompletion.arm=Object.freeze({...arm}); return {armed:true}; },
        stop(correlationID){ if(window.fixtureCompletion.arm?.correlationID===correlationID) {
          window.fixtureCompletion.stops++; window.fixtureCompletion.arm=null;
        } }});
      Object.defineProperty(window,config.key,{value:api,configurable:false,writable:false});
      window.fixturePostTerminal=overrides => {
        const arm=window.fixtureCompletion.arm;
        if(!arm) throw new Error('fixture has no native completion arm');
        const sequence=window.fixturePrompts.length;
        const id=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0');
        const packet={version:1,kind:'terminal',correlationID:arm.correlationID,sequence:arm.sequence,
          inputSHA256:arm.inputSHA256,inputMessageID:id(sequence*2+1),
          conversationID:'00000000-0000-0000-0000-000000000100',messageID:id(sequence*2+2),text:'HI',...overrides};
        window.webkit.messageHandlers[config.handlerName].postMessage(packet);
        window.fixtureCompletion.posts++; return true;
      };
      window.fixturePostStreamFailure=reason => {
        const arm=window.fixtureCompletion.arm;
        const packet={version:1,kind:'terminal_failure',correlationID:arm.correlationID,sequence:arm.sequence,
          inputSHA256:arm.inputSHA256,inputMessageID:'00000000-0000-0000-0000-000000000003',
          conversationID:'00000000-0000-0000-0000-000000000100',reason,calls:reason==='empty_stream'?3:4,assistantMessages:0,
          messageTerminalCount:1,mainTerminalCount:1};
        window.webkit.messageHandlers[config.handlerName].postMessage(packet);return true;
      };
    })();
    """#

    private func terminalCompletionFixture() async throws -> (Fixture, String, WKWebView) {
        let browser = EmbeddedBrowserSession(persistent: false)
        browser.setChatGPTResponseCompletionSourceForTesting(Self.terminalCompletionFixtureSource)
        let page = Self.page
            .replacingOccurrences(of: "const prompt = composer.innerText;", with: """
                const prompt = composer.innerText;
                history.pushState({},'', '/c/00000000-0000-0000-0000-000000000100?temporary-chat=true');
                """)
            .replacingOccurrences(of: "answer.setAttribute('data-chatgpt-selection-conversation-id', 'fixture-conversation');", with: """
                answer.setAttribute('data-chatgpt-selection-conversation-id', '00000000-0000-0000-0000-000000000100');
                answer.setAttribute('data-chatgpt-selection-message-id', '00000000-0000-0000-0000-'+String(window.fixturePrompts.length*2+2).padStart(12,'0'));
                """)
            .replacingOccurrences(of: "answerBody.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';", with: "answerBody.textContent = 'HI';")
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, basePage: page), browser: browser)
        do {
            let started = try await startChoice(Self.fixtureChoice(.chatgpt), in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            let sent = try await call(fixture.transport, "webProviderSend", ["sessionToken": token,
                "prompt": "A synthetic owned decoded-terminal response"])
            let pending = try XCTUnwrap(sent["pendingSubmissionContext"] as? [String: Any])
            XCTAssertEqual(pending["firstUserFingerprint"] as? String, "",
                           "The first poll must establish body proof before any terminal decision")
            let armed = try await evaluate(view, "return window.fixtureCompletion?.arm?.sequence === 1;") as? Bool
            XCTAssertEqual(armed, true, "The local observer must be armed by the actual native Send preparation")
            return (fixture, token, view)
        } catch { fixture.shutdown(); throw error }
    }

    private func terminalReceipt(in fixture: Fixture, view: WKWebView, token: String, sequence: Int = 1) throws -> ChatGPTResponseCompletion.Receipt? {
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        return fixture.browser.chatGPTResponseCompletionReceipt(tabID: tabID, view: view, ownerToken: token,
            generation: try XCTUnwrap(fixture.browser.documentGeneration(for: tabID)), sequence: sequence)
    }

    private func postTerminalCompletion(in fixture: Fixture, view: WKWebView, token: String,
                                        overrides: [String: Any] = [:], expectsReceipt: Bool = true) async throws {
        let data = try JSONSerialization.data(withJSONObject: overrides, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await evaluate(view, "return window.fixturePostTerminal(\(json));")
        // WKScriptMessage dispatch is asynchronous relative to JS evaluation.
        // Wait for the real receipt, not an arbitrary sleep or a test injection.
        let sequenceValue = try await evaluate(view, "return window.fixturePrompts.length;")
        let sequence = try XCTUnwrap(sequenceValue as? Int)
        if expectsReceipt {
            let until = ContinuousClock.now + .seconds(2)
            while try terminalReceipt(in: fixture, view: view, token: token, sequence: sequence) == nil,
                  ContinuousClock.now < until { await Task.yield() }
            XCTAssertNotNil(try terminalReceipt(in: fixture, view: view, token: token, sequence: sequence))
        } else {
            // A foreign packet must produce no current candidate even after a
            // subsequent main-world round trip has drained its actual handler.
            _ = try await evaluate(view, "return window.fixtureCompletion.posts;")
            XCTAssertNil(try terminalReceipt(in: fixture, view: view, token: token, sequence: sequence))
        }
    }

    private func postTerminalFailure(in fixture: Fixture, view: WKWebView, token: String,
                                     reason: String = "empty_stream") async throws {
        _ = try await evaluate(view, "return window.fixturePostStreamFailure(\(String(reflecting: reason)));")
        let tab = try XCTUnwrap(fixture.createdTabs.last), generation = try XCTUnwrap(fixture.browser.documentGeneration(for: tab))
        func receipt() -> ChatGPTResponseCompletion.FailureReceipt? {
            fixture.browser.chatGPTResponseFailureReceipt(tabID: tab, view: view, ownerToken: token, generation: generation, sequence: 1)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while receipt() == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(receipt(), "The failure crosses the actual WK message handler and native lease")
    }

    private func finishTerminalFixture(_ fixture: Fixture, token: String) async throws {
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        XCTAssertNotEqual(finished["cleanup"] as? String, "failed")
        XCTAssertNil(fixture.browser.webView(for: tabID))
        try await assertHumanTabIntact(fixture)
    }

    private func startChoice(_ choice: WebsiteModelChoice, in fixture: Fixture) async throws -> [String: Any] {
        try await call(fixture.transport, "webProviderStart", ["provider": choice.provider,
            "modelChoice": try XCTUnwrap(choice.canonicalJSONString)])
    }

    private func assertModelMismatchBeforePublication(_ transport: EmbeddedWebModelTransport, token: String,
                                                      choice: WebsiteModelChoice, file: StaticString = #filePath,
                                                      line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let observedRevision = try await transport.changeRevision(sessionToken: token)
            let revision = try XCTUnwrap(observedRevision)
            let value: [String: Any]
            do { value = try await call(transport, "webProviderPoll", ["sessionToken": token]) }
            catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .modelMismatch, file: file, line: line)
                return
            }
            XCTAssertEqual(value["state"] as? String, "running", "A mismatched model must never complete", file: file, line: line)
            try assertRunningOrVerifiedChoice(value, choice: choice, file: file, line: line)
            if value["state"] as? String != "running" { return }
            _ = try await transport.waitForChange(sessionToken: token, after: revision, until: deadline)
        }
        XCTFail("Full final model proof must reject drift before publication", file: file, line: line)
    }

    private func assertRunningOrVerifiedChoice(_ snapshot: [String: Any], choice: WebsiteModelChoice,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        if choice.chatGPTPower != nil, snapshot["state"] as? String == "running" {
            XCTAssertEqual(snapshot["modelVerificationPending"] as? Bool, true, file: file, line: line)
            XCTAssertNil(snapshot["modelEvidence"], file: file, line: line)
            XCTAssertNil(snapshot["modelProofContext"], file: file, line: line)
            XCTAssertNil(snapshot["completionEvidence"], file: file, line: line)
            XCTAssertEqual(snapshot["text"] as? String, "", file: file, line: line)
            XCTAssertNotNil(snapshot["pendingSubmissionContext"], file: file, line: line)
            return
        }
        XCTAssertNil(snapshot["modelVerificationPending"], file: file, line: line)
        try assertChoiceEvidence(snapshot, choice: choice, file: file, line: line)
    }

    private func assertChoiceEvidence(_ snapshot: [String: Any], choice: WebsiteModelChoice,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let evidence = try WebsiteModelEvidence.parse(snapshot["modelEvidence"], provider: choice.provider, expected: choice)
        XCTAssertEqual(evidence.selected.key, choice.key, file: file, line: line)
        XCTAssertEqual(evidence.selected.label, choice.label, file: file, line: line)
        XCTAssertEqual(evidence.verification, "website_selection", file: file, line: line)
        XCTAssertNil(evidence.response, "The fixture exposes selection controls, not backend response attribution", file: file, line: line)
        if let power = choice.chatGPTPower {
            XCTAssertEqual(evidence.chatSelection?.family, WebsiteModelEvidence.Identity(key: "GPT-6", label: "GPT-6"), file: file, line: line)
            XCTAssertEqual(evidence.chatSelection?.power, WebsiteModelEvidence.Identity(key: power.rawValue, label: power.label), file: file, line: line)
            XCTAssertEqual(evidence.chatSelection?.automaticFamily.policy, "highest_offered_plain_gpt", file: file, line: line)
            XCTAssertEqual(evidence.source, "selected_model_indicator", file: file, line: line)
        }
    }

    private func assertChoiceLedger(_ view: WKWebView, insertions: Int, sends: Int, selections: Int,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let observed = try await evaluate(view, "return {insertions: window.fixtureInputCount, sends: window.fixturePrompts.length, selections: window.fixtureModelSelectionClicks};")
        let ledger = try XCTUnwrap(observed as? [String: Int], file: file, line: line)
        XCTAssertEqual(ledger["insertions"], insertions, file: file, line: line)
        XCTAssertEqual(ledger["sends"], sends, file: file, line: line)
        XCTAssertEqual(ledger["selections"], selections, file: file, line: line)
    }

    private func assertChatPowerControl(_ view: WKWebView, index: Int, events: Int,
                                        thumbInert: Bool = true, metadataInertAncestor: Bool = false,
                                        metadataAriaHidden: Bool = true,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let observed = try await evaluate(view, """
            // Fixture-only ledger references remain readable after the real
            // popup disconnects. The adapter never sees these references.
            const thumb = window.fixtureChatPowerThumb;
            const power = window.fixtureChatPowerItem;
            return {thumbInert: thumb.inert, ancestorInert: thumb.parentElement.closest('[inert]') !== null,
              metadataAriaHidden: thumb.closest('[aria-hidden="true"]') !== null,
              powerInert: power.closest('[inert]') !== null, powerAriaHidden: power.closest('[aria-hidden="true"]') !== null,
              value: Number(thumb.getAttribute('aria-valuenow')), powerEvents: window.fixturePowerKeyEvents,
              thumbEvents: window.fixturePowerThumbKeyEvents, wrongTargetEvents: window.fixturePowerWrongTargetEvents,
              powerIsLocalMenuItem: thumb.closest('[role="menuitem"]') === power && power.getAttribute('role') === 'menuitem'
                && power.getAttribute('aria-label') === 'Power'};
            """)
        let state = try XCTUnwrap(observed as? [String: Any], file: file, line: line)
        XCTAssertEqual(state["thumbInert"] as? Bool, thumbInert, file: file, line: line)
        XCTAssertEqual(state["ancestorInert"] as? Bool, metadataInertAncestor, file: file, line: line)
        XCTAssertEqual(state["metadataAriaHidden"] as? Bool, metadataAriaHidden, file: file, line: line)
        XCTAssertEqual(state["powerInert"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(state["powerAriaHidden"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(state["powerIsLocalMenuItem"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(state["value"] as? Int, index, file: file, line: line)
        XCTAssertEqual(state["powerEvents"] as? Int, events, "Only the owned Power item may change the preset", file: file, line: line)
        XCTAssertEqual(state["thumbEvents"] as? Int, 0, "The inert thumb is metadata, not a keyboard target", file: file, line: line)
        XCTAssertEqual(state["wrongTargetEvents"] as? Int, 0, file: file, line: line)
    }

    private func assertChatClosedPowerAndRememberedFamily(_ view: WKWebView, power: String,
                                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let observed = try await evaluate(view, """
            return {header: document.getElementById('fixture-model-header').innerText,
              expanded: document.getElementById('fixture-model-trigger').getAttribute('aria-expanded'),
              menuAbsent: document.getElementById('fixture-model-menu') === null,
              remembered: window.fixtureModelRememberedView,
              powerHidden: window.fixtureChatPowerItem.parentElement.hidden,
              openHeaders: window.fixtureModelOpenHeaders,
              powerAtFamilySelections: window.fixturePowerAtFamilySelections};
            """)
        let state = try XCTUnwrap(observed as? [String: Any], file: file, line: line)
        XCTAssertEqual(state["header"] as? String, power, file: file, line: line)
        XCTAssertEqual(state["expanded"] as? String, "false", file: file, line: line)
        XCTAssertEqual(state["menuAbsent"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(state["remembered"] as? String, "family", file: file, line: line)
        XCTAssertEqual(state["powerHidden"] as? Bool, true, file: file, line: line)
        let openHeaders = try XCTUnwrap(state["openHeaders"] as? [String], file: file, line: line)
        XCTAssertFalse(openHeaders.isEmpty, file: file, line: line)
        XCTAssertTrue(openHeaders.allSatisfy { $0 == "Thinking effort" }, file: file, line: line)
        let selections = try XCTUnwrap(state["powerAtFamilySelections"] as? [String], file: file, line: line)
        XCTAssertEqual(selections, [power], "The fresh visible Power mutation must precede the one family selection", file: file, line: line)
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
        case .chatgpt: ["GPT-6", "GPT-5.6 Sol", "GPT-5.5"]
        case .gemini: ["3.5 Flash-Lite", "3.8 Flash", "3.1 Pro"]
        case .claude: ["Sonnet 5.5", "Haiku 4.5", "Sonnet 5", "Sonnet 4.6"]
        }
    }

    private func retainedInstantPrepare(_ fixture: Fixture, view: WKWebView, token: String) async throws -> [String: Any] {
        let tabID = try XCTUnwrap(fixture.createdTabs.last)
        let operation = UUID(), browser = fixture.browser
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Computa/Resources/BrowserModels/chatgpt.js"), encoding: .utf8)
        try browser.beginModelDiagnostic(tabID: tabID, ownerToken: token, operationID: operation)
        defer { browser.endModelDiagnostic(tabID: tabID, operationID: operation) }
        return try await withTaskCancellationHandler {
            let result = try await evaluate(view, """
                const input = {provider:'chatgpt', action:'prepare', ownerToken:\(String(reflecting: token)),
                  operationID:\(String(reflecting: operation.uuidString)), expectedURL:document.URL,
                  expectedUserCounts:[0], expectedModelChoice:{key:'chat/latest/instant',label:'Instant'}};
                \(source)
                """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
            try Task.checkCancellation()
            let observed = try XCTUnwrap(result)
            if observed["error"] != nil { throw EmbeddedWebModelTransport.Failure.modelUnverified }
            return observed
        } onCancel: {
            Task { @MainActor in browser.endModelDiagnostic(tabID: tabID, operationID: operation) }
        }
    }

    private func assertRetainedInstantPrepareRejected(_ fixture: Fixture, view: WKWebView, token: String,
                                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await retainedInstantPrepare(fixture, view: view, token: token)
            XCTFail("Unverified retained prepare must reject without editor input", file: file, line: line)
        } catch { }
    }

    private func readyInstantPrepareFixture(synchronousReadiness: Bool = false) async throws -> (Fixture, WKWebView, String, WebsiteModelChoice) {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let fixture = try Fixture(page: Self.modelChoicePage(.chatgpt, initiallySelectTarget: true)
            .replacingOccurrences(of: "aria-valuenow=\"1\"", with: "aria-valuenow=\"0\""))
        do {
            let started = try await startChoice(choice, in: fixture)
            let token = try XCTUnwrap(started["sessionToken"] as? String)
            let view = try XCTUnwrap(fixture.browser.webView(for: XCTUnwrap(fixture.createdTabs.last)))
            _ = try await waitForState("ready", fixture.transport, token: token)
            if synchronousReadiness {
                _ = try await evaluate(view, """
                    document.getElementById('fixture-editor').addEventListener('input', () => {
                      document.querySelector('[data-testid="send-button"]').disabled = false;
                    }); return true;
                    """)
            }
            return (fixture, view, token, choice)
        } catch { fixture.shutdown(); throw error }
    }

    private func armFirstPrepareOpening(_ view: WKWebView, behavior: String) async throws {
        _ = try await evaluate(view, """
            const trigger = document.getElementById('fixture-model-trigger');
            const composer = document.getElementById('fixture-editor');
            let armed = true;
            let phaseEnded = false;
            window.fixturePrepareOpeningAttempts = 0; window.fixturePreparePhysicalClicks = 0;
            document.addEventListener('keydown', event => {
              if (event.key === 'Escape' && window.fixturePreparePhysicalClicks > 0) phaseEnded = true;
            }, true);
            trigger.addEventListener('click', event => {
              if (phaseEnded || composer.getAttribute('data-fixture-prepare-focus') !== 'true') return;
              window.fixturePreparePhysicalClicks++;
              if (!armed) return;
              window.fixturePrepareOpeningAttempts++;
              if ('\(behavior)' === 'ignore_once' && window.fixturePrepareOpeningAttempts > 1) { armed = false; return; }
              if ('\(behavior)' === 'transient_recovery' && window.fixturePrepareOpeningAttempts === 2) {
                armed = false;
                queueMicrotask(() => {
                  const menu = window.fixtureChatPowerItem.closest('[role="menu"]');
                  menu.style.display = 'none'; menu.remove(); trigger.setAttribute('aria-expanded','false'); window.fixtureModelUpdateHeader();
                });
                return;
              }
              event.preventDefault(); event.stopImmediatePropagation();
              if ('\(behavior)' === 'cancel_busy') {
                setTimeout(() => {
                  const until = Date.now() + 1_200;
                  while (Date.now() < until) {}
                  window.fixturePrepareBusyFinished = true;
                }, 100);
              } else if ('\(behavior)' === 'late') {
                armed = false;
                setTimeout(() => {
                  const menu = window.fixtureChatPowerItem.closest('[role="menu"]');
                  document.body.appendChild(menu); window.fixtureShowPowerView(); menu.style.display = 'block';
                  trigger.setAttribute('aria-expanded', 'true'); window.fixtureModelUpdateHeader();
                }, 80);
              } else if ('\(behavior)' === 'header_restore') {
                const header = document.getElementById('fixture-model-header');
                header.textContent = 'High'; header.textContent = 'Instant';
              } else if ('\(behavior)' === 'unassociated') {
                const menu = document.createElement('div'); menu.setAttribute('role', 'menu'); menu.textContent = 'Foreign'; document.body.appendChild(menu);
              } else if ('\(behavior)' === 'route') history.pushState({}, '', '/c/foreign-prepare?temporary-chat=true');
              else if ('\(behavior)' === 'temporary') document.querySelector('[aria-label="Turn off temporary chat"]').setAttribute('aria-label','Temporary chat');
              else if (['user','assistant'].includes('\(behavior)')) {
                const message = document.createElement('article'); message.setAttribute('data-message-author-role','\(behavior)');
                message.textContent = 'Foreign fixture message'; document.body.appendChild(message);
              } else if ('\(behavior)' === 'owner') composer.setAttribute('data-fixture-owner-drift','true');
            }, true);
            return true;
            """)
        _ = try await evaluate(view, """
            const composer = document.getElementById('fixture-editor');
            globalThis.__fixturePrepareComposer = composer;
            const originalFocus = composer.focus;
            composer.focus = function(...args) {
              composer.setAttribute('data-fixture-prepare-focus', 'true');
              return originalFocus.apply(this, args);
            };
            if ('\(behavior)' === 'owner') {
              globalThis.__fixturePrepareOwnerObserver = new MutationObserver(() => {
                globalThis.__computaModelOwner = '00000000-0000-4000-8000-000000000001';
              });
              globalThis.__fixturePrepareOwnerObserver.observe(composer, {attributes:true, attributeFilter:['data-fixture-owner-drift']});
            }
            return true;
            """, world: .world(name: "computa-chatgpt-model-v1"))
    }

    private static func fixtureChoice(_ provider: EmbeddedWebModelTransport.Provider) -> WebsiteModelChoice {
        if provider == .chatgpt { return syntheticChatGPTChoice }
        let label = choiceLabels(provider)[provider == .gemini ? 1 : choiceLabels(provider).count - 1]
        return WebsiteModelChoice(provider: provider.rawValue, key: label, label: label)
    }

    private static let fixtureToolReply = #"{"type":"tool_calls","calls":[{"name":"exec_command","arguments":{"cmd":"printf fixture"}}]}"#

    /// Mirrors the separately observed generic closed label and Escape/reopen
    /// returning to Power. Neither fixture state nor labels supply model proof.
    private static func genericClosedChatPowerPage(resetAfterFamily: Bool = false) -> String {
        let page = modelChoicePage(.chatgpt, initiallySelectTarget: !resetAfterFamily)
            .replacingOccurrences(of: """
              document.getElementById('fixture-model-header').textContent = open ? 'Thinking effort'
                : ['Instant', 'Medium', 'High', 'Extra High', 'Pro'][Number(powerThumb.getAttribute('aria-valuenow'))];
            """, with: """
              document.getElementById('fixture-model-header').textContent = 'Thinking effort';
              if (!open) window.fixtureModelRememberedView = 'power';
            """)
        guard resetAfterFamily else { return page }
        return page.replacingOccurrences(of: "</body>", with: """
            <script>
            // Start at Medium independently of the initially checked family.
            window.fixtureChatPowerThumb.setAttribute('aria-valuenow', '1');
            document.querySelectorAll('[data-fixture-model]').forEach(node => node.addEventListener('click', () => {
              window.fixtureChatPowerThumb.setAttribute('aria-valuenow', '4');
            }));
            </script></body>
            """)
    }

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

    private static func collapsedSecondChatSubmissionPage(changedExpandedBody: Bool) -> String {
        page.replacingOccurrences(of: "user.appendChild(userBody);", with: """
            user.appendChild(userBody);
            if (window.fixturePrompts.length === 2) {
              userBody.textContent = prompt.slice(0, 96);
              const more = document.createElement('button');
              more.textContent = 'Show more'; more.setAttribute('aria-label', 'Show more');
              window.fixtureCurrentExpansionClicks = 0;
              document.getElementById('messages').setAttribute('data-fixture-current-expansion-clicks', '0');
              more.addEventListener('click', () => {
                window.fixtureCurrentExpansionClicks++;
                document.getElementById('messages').setAttribute('data-fixture-current-expansion-clicks', String(window.fixtureCurrentExpansionClicks));
                userBody.textContent = prompt + \(changedExpandedBody ? "'!'" : "''");
                more.remove();
              });
              user.appendChild(more);
            }
            """)
    }

    private static func optimisticTemporarySubmissionPage() -> String {
        temporaryOutlineFirstUserPage().replacingOccurrences(of: "window.fixtureTemporaryOutline = outline;", with: """
            window.fixtureTemporaryOutline = outline;
            const optimistic = document.createElement('span');
            optimistic.className = 'whitespace-pre-wrap'; optimistic.style.whiteSpace = 'pre-wrap'; optimistic.textContent = prompt;
            user.replaceChildren(outline, optimistic);
            document.addEventListener('fixture-commit-durable-user', () => {
              const durable = user.cloneNode(false);
              durable.append(outline.cloneNode(true), content); user.replaceWith(durable);
            }, {once:true});
            """)
    }

    private static func temporaryOutlineFirstUserPage(variant: String = "valid") -> String {
        collapsedFirstUserPage()
            .replacingOccurrences(of: "document.getElementById('messages').appendChild(user);", with: """
                document.getElementById('messages').appendChild(user);
                const variant = \(String(reflecting: variant));
                if (window.fixturePrompts.length === 1) {
                  document.querySelector('[aria-label="Turn off temporary chat"]')?.remove();
                  document.getElementById('fixture-composer-mode')?.remove();
                  const style = document.createElement('style');
                  style.textContent = '[data-user-message-bubble="true"]{position:relative} svg.temporaryOutline-bbkcxS{pointer-events:none;position:absolute;inset:0;height:100%;width:100%}';
                  document.head.appendChild(style);
                }
                user.removeAttribute('data-message-author-role'); user.setAttribute('data-user-message-bubble','true');
                userBody.removeAttribute('data-markdown-text-style'); userBody.className = 'whitespace-pre-wrap';
                const content = document.createElement('div');
                while (user.firstChild) content.appendChild(user.firstChild);
                const outline = document.createElementNS('http://www.w3.org/2000/svg','svg');
                outline.setAttribute('class','pointer-events-none absolute inset-0 h-full w-full temporaryOutline-bbkcxS');
                outline.setAttribute('aria-hidden','true'); outline.setAttribute('focusable','false');
                const rect = document.createElementNS('http://www.w3.org/2000/svg','rect');
                for (const [key,value] of Object.entries({x:'0.5',y:'0.5',width:'calc(100% - 1px)',height:'calc(100% - 1px)',
                  fill:'none',stroke:'currentColor','stroke-opacity':'0.4','stroke-width':'1','stroke-dasharray':'8 8','vector-effect':'non-scaling-stroke'})) rect.setAttribute(key,value);
                outline.appendChild(rect); user.append(outline, content); window.fixtureTemporaryOutline = outline;
                if (variant === 'url_only') outline.remove();
                if (variant === 'duplicate') user.prepend(outline.cloneNode(true));
                if (variant === 'nested_body') userBody.prepend(outline);
                if (variant === 'code') { const code = document.createElement('code'); code.appendChild(outline); user.prepend(code); }
                if (variant === 'interactive') { user.setAttribute('role','button'); user.setAttribute('tabindex','0'); }
                if (variant === 'malformed') rect.setAttribute('stroke-dasharray','8 7');
                if (variant === 'fake_class') outline.setAttribute('class','pointer-events-none absolute inset-0 h-full w-full temporaryOutline-not!observed');
                if (variant === 'hidden') user.hidden = true;
                if (variant === 'inert') user.inert = true;
                if (variant === 'opacity') user.style.opacity = '0';
                if (variant === 'queryless' || variant === 'duplicate_query') {
                  const url = new URL(document.URL); url.searchParams.delete('temporary-chat');
                  if (variant === 'duplicate_query') { url.searchParams.append('temporary-chat','true'); url.searchParams.append('temporary-chat','true'); }
                  history.replaceState({},'',url);
                }
                """)
            .replacingOccurrences(of: "document.getElementById('messages').appendChild(turn);", with: """
                document.getElementById('messages').appendChild(turn);
                if (\(String(reflecting: variant)) === 'assistant') answer.prepend(window.fixtureTemporaryOutline);
                """)
    }

    private static func collapsedFirstUserPage(deferred: Bool = false, ignored: Bool = false,
                                               expansionScript: String = "", expansionDelayMilliseconds: Int = 25,
                                               earlyExpansionScript: String = "") -> String {
        var page = acknowledgedAppendRacePage().replacingOccurrences(of: "user.appendChild(userBody);", with: """
            user.appendChild(userBody);
            if (window.fixturePrompts.length === 1) {
              userBody.textContent = prompt.slice(0, 10240);
              const expand = document.createElement('button');
              expand.type = 'button'; expand.textContent = 'Show more';
              expand.setAttribute('aria-label', 'Show more');
              window.fixtureExpansionClicks = 0;
              expand.addEventListener('click', () => {
                window.fixtureExpansionClicks++;
                if (\(ignored ? "true" : "false")) return;
                \(earlyExpansionScript)
                setTimeout(() => { userBody.textContent = prompt; expand.remove(); \(expansionScript) }, \(expansionDelayMilliseconds));
              });
              user.appendChild(expand);
            }
            """)
        if !deferred {
            page = page.replacingOccurrences(of: "window.fixturePendingUser = user;", with: "document.getElementById('messages').appendChild(user);")
                .replacingOccurrences(of: "window.fixturePendingTurn = turn;", with: "document.getElementById('messages').appendChild(turn);")
        }
        return page
    }

    private static func firstSendRoutePromotionPage() -> String {
        modelChoicePage(.chatgpt, genericHeader: true, unmountClosedMenu: true)
            .replacingOccurrences(of: "answerBody.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';",
                with: "answerBody.textContent = window.fixturePrompts.length === 1 ? '\(fixtureToolReply)' : '{\"type\":\"message\",\"text\":\"Fixture reply\"}';")
    }

    /// Send still inserts and clicks once. Its user/answer DOM is committed
    /// asynchronously after native sees the submit acknowledgment. Its render
    /// does not depend on a model picker being opened during the response.
    private static func acknowledgedAppendRacePage() -> String {
        modelChoicePage(.chatgpt, genericHeader: true, unmountClosedMenu: true)
            .replacingOccurrences(of: "window.fixturePrompts = [];", with: """
                window.fixturePrompts = [];
                window.fixtureRaceArmed = false; window.fixtureRaceCorruption = 'none';
                window.fixtureDelayedAppendCommits = 0; window.fixtureRaceRenderedCounts = [];
                window.fixtureRaceRoutes = []; window.fixtureRaceRenderedRoutes = [];
                window.fixturePendingUser = null; window.fixturePendingTurn = null;
                """)
            .replacingOccurrences(of: "document.getElementById('messages').appendChild(user);",
                with: "window.fixturePendingUser = user;")
            .replacingOccurrences(of: "document.getElementById('messages').appendChild(turn);",
                with: "window.fixturePendingTurn = turn;")
            .replacingOccurrences(of: "answerBody.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';",
                with: "answerBody.textContent = window.fixturePrompts.length === 1 ? '\(fixtureToolReply)' : '{\"type\":\"message\",\"text\":\"Fixture reply\"}';")
            .replacingOccurrences(of: "window.fixturePendingUser = null; window.fixturePendingTurn = null;", with: """
                window.fixturePendingUser = null; window.fixturePendingTurn = null;
                // A normal asynchronous render is independent of model-picker
                // interaction. Arming after the native Send acknowledgement
                // preserves delayed append/route and corruption boundaries.
                let raceArmed = false, renderQueued = false;
                Object.defineProperty(window, 'fixtureRaceArmed', {
                  get: () => raceArmed,
                  set: value => {
                    raceArmed = value;
                    if (!value || !window.fixturePendingUser || renderQueued) return;
                    renderQueued = true;
                    const pendingUser = window.fixturePendingUser, pendingTurn = window.fixturePendingTurn;
                    setTimeout(() => {
                      renderQueued = false;
                      if (!raceArmed || window.fixturePendingUser !== pendingUser) return;
                      raceArmed = false; window.fixtureDelayedAppendCommits++;
                      window.fixturePendingUser = null; window.fixturePendingTurn = null;
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
                  }
                });
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
    /// Chat reproduces the measured presentation: closed preset text becomes
    /// "Thinking effort" while open, and a disconnected Family popup reopens
    /// in Family with inactive Power metadata still hidden. Fixture ledgers are
    /// kept outside adapter evidence so a successful test needs the live DOM.
    private static func modelChoicePage(_ provider: EmbeddedWebModelTransport.Provider,
                                        disableTarget: Bool = false, initiallySelectTarget: Bool = false,
                                        deferSelectionCommit: Bool = false, genericHeader: Bool = false,
                                        unmountClosedMenu: Bool = false, ignoreModelEscape: Bool = false,
                                        returnToParentAfterSelection: Bool = false, driftTemporaryInParent: Bool = false,
                                        hideComposerInPicker: Bool = false, holdSecondReply: Bool = false,
                                        basePage: String? = nil) -> String {
        precondition(!returnToParentAfterSelection || provider == .chatgpt)
        precondition(!(driftTemporaryInParent || hideComposerInPicker) || returnToParentAfterSelection)
        precondition(!holdSecondReply || provider == .chatgpt)
        let labels = choiceLabels(provider)
        let initial = provider == .chatgpt ? labels[1] : provider == .gemini ? labels[2] : labels[0]
        let target = provider == .chatgpt ? labels[0] : fixtureChoice(provider).label
        let aria = provider == .chatgpt ? "Select ChatGPT model" : provider == .gemini
            ? "Open mode picker, currently Gemini Pro" : "Model: \(initial) Medium"
        let disabled = provider == .chatgpt ? "GPT-4.9" : provider == .gemini ? "3.7 Flash" : "Opus 4.5"
        let upgrade = provider == .chatgpt ? "GPT-5.9" : provider == .gemini ? "4.0 Pro" : "Fable 5.5"
        let escapeClosesPopup = provider == .chatgpt
        let rows = labels.map { label in
            if provider == .chatgpt {
                return "<div role=\"menuitemradio\" tabindex=\"-1\" aria-checked=\"false\" data-fixture-model=\"\(label)\"><span>\(label)</span></div>"
            }
            return "<button role=\"menuitemradio\" aria-checked=\"false\" data-fixture-model=\"\(label)\" \(disableTarget && label == target ? "disabled" : "")><span>\(label)</span><span>Fixture description, independent of the family label</span></button>"
        }.joined()
        let picker = """
        <button id="fixture-model-trigger" aria-label="\(aria)" aria-controls="fixture-model-menu" aria-haspopup="menu" aria-expanded="false"><span id="fixture-model-header"></span></button>
        <div id="fixture-model-menu" role="menu" aria-labelledby="fixture-model-trigger" style="display:none">
        \(provider == .chatgpt ? """
        <div id="fixture-chat-power-view">
          <div id="fixture-chat-power-item" role="menuitem" aria-label="Power" tabindex="-1">
            <div id="fixture-chat-power-visual" aria-hidden="true">
              <span id="fixture-chat-power-slider" role="slider" inert aria-valuemin="0" aria-valuemax="4" aria-valuenow="\(initiallySelectTarget ? 1 : 0)" tabindex="-1" aria-orientation="horizontal" style="display:block;width:120px;height:20px" \(disableTarget ? "aria-disabled=\"true\"" : "")></span>
            </div>
          </div>
          <div id="fixture-select-family" role="menuitem" tabindex="-1">Select model</div>
        </div>
        <div id="fixture-chat-family-view" hidden>
        """ : "")
        \(rows)
        \(provider == .chatgpt ? "</div>" : """
        <button role="menuitemradio" disabled><span>\(disabled)</span></button>
        <button role="menuitemradio"><span>\(upgrade)</span><span>Upgrade</span></button>
        <button role="menuitemradio"><span>Extended thinking</span></button>
        <button role="menuitemradio"><span>Medium</span></button>
        """)
        \(returnToParentAfterSelection ? "<button id=\"fixture-parent-option\" role=\"menuitem\" hidden>Adjust thinking time</button>" : "")
        </div>
        <script>
        window.fixtureModelInitialLabel = '\(initial)';
        window.fixtureModelSelectionClicks = 0; window.fixtureModelTriggerClicks = 0;
        window.fixtureModelEscapeEvents = 0; window.fixtureModelEscapeClosures = 0;
        const modelTrigger = document.getElementById('fixture-model-trigger');
        const modelMenu = document.getElementById('fixture-model-menu');
        \(provider == .chatgpt ? """
        window.fixturePowerKeyEvents = 0; window.fixturePowerThumbKeyEvents = 0; window.fixturePowerWrongTargetEvents = 0;
        window.fixtureModelRememberedView = 'power'; window.fixtureModelOpenViews = [];
        window.fixtureModelClosedHeaders = []; window.fixtureModelOpenHeaders = [];
        window.fixturePowerAtFamilySelections = [];
        window.fixtureModelFamilyOpenCount = 0; window.fixtureModelPowerOpenCount = 0;
        const powerView = document.getElementById('fixture-chat-power-view');
        const familyView = document.getElementById('fixture-chat-family-view');
        const powerItem = document.getElementById('fixture-chat-power-item');
        const powerThumb = document.getElementById('fixture-chat-power-slider');
        window.fixtureChatPowerItem = powerItem; window.fixtureChatPowerThumb = powerThumb;
        window.fixtureModelUpdateHeader = () => {
          const open = modelTrigger.getAttribute('aria-expanded') === 'true';
          document.getElementById('fixture-model-header').textContent = open ? 'Thinking effort'
            : ['Instant', 'Medium', 'High', 'Extra High', 'Pro'][Number(powerThumb.getAttribute('aria-valuenow'))];
        };
        window.fixtureShowPowerView = () => {
          window.fixtureModelRememberedView = 'power';
          powerView.hidden = false; familyView.hidden = true;
        };
        window.fixtureShowFamilyView = () => {
          window.fixtureModelRememberedView = 'family';
          powerView.hidden = true; familyView.hidden = false;
        };
        document.getElementById('fixture-select-family').addEventListener('click', window.fixtureShowFamilyView);
        powerThumb.addEventListener('keydown', () => window.fixturePowerThumbKeyEvents++);
        powerItem.addEventListener('keydown', event => {
          if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
          if (event.target !== powerItem) { window.fixturePowerWrongTargetEvents++; return; }
          if (powerItem.closest('[inert]') || powerItem.getAttribute('aria-disabled') === 'true'
            || powerThumb.getAttribute('aria-disabled') === 'true' || powerView.hidden || !modelMenu.isConnected) return;
          event.preventDefault(); window.fixturePowerKeyEvents++;
          const direction = event.key === 'ArrowRight' ? 1 : -1;
          const value = Number(powerThumb.getAttribute('aria-valuenow'));
          powerThumb.setAttribute('aria-valuenow', String(Math.max(0, Math.min(4, value + direction))));
          window.fixtureModelUpdateHeader();
        });
        """ : "")
        \(returnToParentAfterSelection ? """
        window.fixtureModelParentActive = false; window.fixtureModelParentReturns = 0;
        window.fixtureModelParentObservations = [];
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
          \(provider == .chatgpt ? "window.fixtureModelUpdateHeader();" : "document.getElementById('fixture-model-header').textContent = \(genericHeader ? (provider == .gemini ? "'Pro'" : "'ChatGPT'") : "label");")
          modelMenu.querySelectorAll('[data-fixture-model]').forEach(node => node.setAttribute('aria-checked', String(node.dataset.fixtureModel === label)));
          \(provider == .claude ? "modelTrigger.setAttribute('aria-label', 'Model: ' + label + ' Medium');" : "")
        };
        modelTrigger.addEventListener('click', () => {
          window.fixtureModelTriggerClicks++;
          const open = !modelMenu.isConnected || modelMenu.style.display === 'none';
          \(escapeClosesPopup ? "if (!open) return; // Observed ChatGPT clicks do not close an already-open portal." : "")
          if (open && !modelMenu.isConnected) document.body.appendChild(modelMenu);
          \(provider == .chatgpt ? """
          if (open) {
            if (window.fixtureModelRememberedView === 'family') window.fixtureShowFamilyView();
            else window.fixtureShowPowerView();
            window.fixtureModelOpenViews.push(window.fixtureModelRememberedView);
            if (window.fixtureModelRememberedView === 'family') window.fixtureModelFamilyOpenCount++;
            else window.fixtureModelPowerOpenCount++;
          }
          """ : "")
          modelMenu.style.display = open ? 'block' : 'none';
          modelTrigger.setAttribute('aria-expanded', String(open));
          \(provider == .chatgpt ? "window.fixtureModelUpdateHeader(); window.fixtureModelOpenHeaders.push(document.getElementById('fixture-model-header').textContent);" : "")
          \(returnToParentAfterSelection ? """
          modelMenu.setAttribute('data-state', open ? 'open' : 'closed');
          modelTrigger.setAttribute('data-state', open ? 'open' : 'closed');
          if (open) {
            modelMenu.querySelectorAll('[role="menuitemradio"]').forEach(node => { node.hidden = false; });
            document.getElementById('fixture-parent-option').hidden = true;
            if (window.fixtureModelParentEscapeClosures === 1) window.fixtureModelFreshProofReadOpens++;
          }
          // The site hides its background only after a family selection
          // returns to the owned parent modal. Initial visible Power input
          // must keep the enabled trigger exposed; its negative is separate.
          window.fixtureModelSetModalHidden(open && window.fixtureModelParentActive);
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
          window.fixtureModelUpdateHeader();
          window.fixtureModelClosedHeaders.push(document.getElementById('fixture-model-header').textContent);
          \(returnToParentAfterSelection ? """
          modelMenu.setAttribute('data-state', 'closed'); modelTrigger.setAttribute('data-state', 'closed');
          window.fixtureModelSetModalHidden(false);
          if (window.fixtureModelParentActive) {
            window.fixtureModelParentActive = false; window.fixtureModelParentEscapeClosures++;
          }
          """ : "")
          modelMenu.remove();
          modelTrigger.focus(); window.fixtureModelEscapeClosures++;
        });
        """ : "")
        modelMenu.querySelectorAll('[data-fixture-model]').forEach(node => node.addEventListener('click', () => {
          window.fixtureModelSelectionClicks++;
          \(provider == .chatgpt ? "window.fixturePowerAtFamilySelections.push(['Instant', 'Medium', 'High', 'Extra High', 'Pro'][Number(powerThumb.getAttribute('aria-valuenow'))]);" : "")
          \(deferSelectionCommit ? "window.fixturePendingModelSelection = node.dataset.fixtureModel;" : "window.fixtureModelSelect(node.dataset.fixtureModel);")
          \(returnToParentAfterSelection ? """
          window.fixtureModelParentActive = true; window.fixtureModelParentReturns++;
          window.fixtureShowPowerView();
          modelMenu.querySelectorAll('[role="menuitemradio"]').forEach(row => { row.hidden = true; });
          document.getElementById('fixture-parent-option').hidden = false;
          modelMenu.style.display = 'block'; modelTrigger.setAttribute('aria-expanded', 'true');
          modelMenu.setAttribute('data-state', 'open'); modelTrigger.setAttribute('data-state', 'open');
          window.fixtureModelSetModalHidden(true);
          const checkedFamily = modelMenu.querySelector('[data-fixture-model][aria-checked="true"]');
          window.fixtureModelParentObservations.push({
            active: window.fixtureModelParentActive, connected: modelMenu.isConnected,
            expanded: modelTrigger.getAttribute('aria-expanded') === 'true',
            checked: checkedFamily?.dataset.fixtureModel ?? null, checkedHidden: checkedFamily?.hidden === true,
            temporaryHidden: temporaryButtons[0].getAttribute('aria-hidden') === 'true',
            composerHidden: document.getElementById('fixture-editor').closest('[aria-hidden="true"]') != null,
            users: document.querySelectorAll('[data-message-author-role="user"]').length,
            assistants: document.querySelectorAll('[data-message-author-role="assistant"]').length,
            inputs: window.fixtureInputCount, sends: window.fixturePrompts.length
          });
          \(driftTemporaryInParent ? """
          temporaryButtons[0].setAttribute('aria-label', 'Start temporary chat');
          temporaryButtons[0].textContent = 'Start temporary chat'; window.fixtureModelTemporaryDrifted = true;
          """ : "")
          return; // The actual family choice returns to its associated primary popup.
          """ : "")
          modelMenu.style.display = 'none'; modelTrigger.setAttribute('aria-expanded', 'false');
          \(provider == .chatgpt ? "window.fixtureModelUpdateHeader();" : "")
          \(unmountClosedMenu || provider == .chatgpt ? "modelMenu.remove();" : "")
        }));
        window.fixtureModelSelect('\(initiallySelectTarget ? target : initial)');
        \(unmountClosedMenu ? "modelMenu.remove();" : "")
        </script>
        """
        var base = basePage ?? (provider == .chatgpt ? page : providerPage(provider))
        if holdSecondReply {
            let append = "document.getElementById('messages').appendChild(turn);"
            precondition(base.components(separatedBy: append).count == 2)
            base = base.replacingOccurrences(of: append, with: append + """

              if (window.fixturePrompts.length === 2) {
                const stop = document.createElement('button'); stop.id = 'fixture-held-response-stop';
                stop.setAttribute('data-testid', 'stop-button'); stop.setAttribute('aria-label', 'Stop generating');
                stop.textContent = 'Stop generating'; document.body.appendChild(stop);
              }
            """)
        }
        return base.replacingOccurrences(of: "</body>", with: picker + "</body>")
    }

    private func call(_ transport: EmbeddedWebModelTransport, _ operation: String,
                      _ params: [String: String]) async throws -> [String: Any] {
        var parameters = params
        if operation == "webProviderStart", parameters["provider"] == "chatgpt", parameters["modelChoice"] == nil {
            parameters["modelChoice"] = syntheticChatGPTChoice.canonicalJSONString
        }
        let data = try JSONSerialization.data(withJSONObject: parameters)
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

    /// Finite local-fixture errors are captured before the
    /// caller's defer disposes WebKit and can obscure the original phase.
    private func fixturePhaseProbe<T>(_ phase: String, trace: Bool = false,
                                      _ operation: @MainActor () async throws -> T) async throws -> T {
        if trace { print("WKFixturePhase phase=\(phase) boundary=begin") }
        do {
            let result = try await operation()
            if trace { print("WKFixturePhase phase=\(phase) boundary=end") }
            return result
        }
        catch {
            let value = error as NSError
            let failure = (error as? EmbeddedWebModelTransport.Failure).map { String(describing: $0) } ?? "other"
            print("WKFixtureOriginalError phase=\(phase) type=\(String(reflecting: type(of: error))) domain=\(value.domain) code=\(value.code) native=\(failure)")
            throw error
        }
    }

    private func capturedUserPrompts(_ view: WKWebView) async throws -> [String]? {
        let value = try await evaluate(view, "return window.fixturePrompts;")
        var prompts = try XCTUnwrap(value as? [String])
        let perSubmission = ["gemini.google.com", "chatgpt.com"].contains(view.url?.host ?? "")
        var markers = Set<String>()
        for index in prompts.indices where index == 0 || perSubmission {
            // Every proof-capable round has its own final transport nonce.
            // Claude retains first-message metadata only. Decode no source
            // text before this exact UUID-shaped final suffix.
            let raw = prompts[index]
            let suffix = try XCTUnwrap(raw.range(of: #"\n\nComputa session marker: [A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\n?$"#, options: .regularExpression))
            let marker = String(raw[suffix]).trimmingCharacters(in: .newlines)
            XCTAssertTrue(markers.insert(marker).inserted, "Each admitted round must use a different transport nonce")
            prompts[index] = String(raw[..<suffix.lowerBound])
            if raw.hasSuffix("\n") { prompts[index] += "\n" }
        }
        if !perSubmission {
            XCTAssertFalse(prompts.dropFirst().contains { $0.contains("Computa session marker:") }, "Unsupported continuations retain first-message metadata only")
        }
        return prompts
    }

    private func waitForQuietRevision(_ transport: EmbeddedWebModelTransport, token: String) async throws -> UInt64 {
        // Use the same event channel as production. A quiet window must exceed
        // its 100 ms native burst batch; any signal resets this bounded wait.
        let deadline = ContinuousClock.now + .seconds(2)
        let observedRevision = try await transport.changeRevision(sessionToken: token)
        var revision = try XCTUnwrap(observedRevision)
        while ContinuousClock.now < deadline {
            let quietDeadline = min(deadline, ContinuousClock.now + .milliseconds(250))
            let observed = try await transport.waitForChange(sessionToken: token, after: revision, until: quietDeadline)
            let after = try XCTUnwrap(observed)
            if after == revision, quietDeadline < deadline { return after }
            revision = after
        }
        XCTFail("Fixture notification channel did not become quiet within its deadline")
        throw FixtureFailure.timeout
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
            const expectedFirstBody = document.querySelector('user-query .user-query-bubble-with-background > span.ng-star-inserted > span')?.textContent;
            if (typeof expectedFirstBody !== 'string' || document.querySelectorAll('user-query').length !== 1
              || globalThis.__computaGeminiSubmissionState?.pending?.phase !== 'send_claimed'
              || globalThis.__computaGeminiSubmissionState.pending.sequence !== 2)
              throw new Error('Expected one proved first body and an acknowledged pending second Send');
            const canonical = expectedFirstBody.replace(/\\r\\n?/g, '\\n').normalize('NFC').trim();
            let armed = true;
            crypto.subtle.digest = async (...digestArguments) => {
              const digest = await original(...digestArguments);
              if (armed && new TextDecoder().decode(digestArguments[1]) === canonical) {
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

    /// Occupy a real WebContent queue before enqueuing the transport read.
    /// The start receipt is independent of the blocked script's completion.
    private final class FixtureWebContentWork: NSObject, WKScriptMessageHandler {
        private weak var view: WKWebView?
        private let started = FixtureScriptResult()
        private let completed = FixtureScriptResult()
        private static let handler = "computaFixtureWorkStarted"

        init(view: WKWebView) {
            self.view = view
            super.init()
            view.configuration.userContentController.add(self, name: Self.handler)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === view, message.frameInfo.isMainFrame,
                  message.body as? String == "started" else { return }
            started.complete(.success(Data()))
        }

        func start(milliseconds: Int, completionScript: String = "") async throws {
            let view = try XCTUnwrap(view)
            _ = try await wait(started, maximumWait: .seconds(2)) {
                view.callAsyncJavaScript("""
                    window.webkit.messageHandlers.computaFixtureWorkStarted.postMessage('started');
                    const until = performance.now() + milliseconds;
                    while (performance.now() < until) { }
                    \(completionScript)
                    return true;
                    """, arguments: ["milliseconds": milliseconds], in: nil, in: .page) { [completed] result in
                    switch result {
                    case .success: completed.complete(.success(Data()))
                    case .failure(let error): completed.complete(.failure(error))
                    }
                }
            }
        }

        func waitForCompletion() async throws {
            _ = try await wait(completed, maximumWait: .seconds(20), enqueue: {})
        }

        func detach() {
            view?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler)
        }

        private func wait(_ result: FixtureScriptResult, maximumWait: Duration,
                          enqueue: () -> Void) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                result.setTimeout(Task {
                    do {
                        try await Task.sleep(for: maximumWait)
                        result.complete(.failure(FixtureFailure.evaluationTimeout))
                    } catch { }
                })
                enqueue()
            }
        }
    }

    private final class PrewarmFixtureWebView: WKWebView {
        let fixtureHTML: String
        private(set) var requestLoadCount = 0

        init(configuration: WKWebViewConfiguration, fixtureHTML: String) {
            self.fixtureHTML = fixtureHTML
            super.init(frame: .zero, configuration: configuration)
        }

        required init?(coder: NSCoder) { fatalError("Local fixture has no coder initializer") }

        override func load(_ request: URLRequest) -> WKNavigation? {
            requestLoadCount += 1
            return super.loadHTMLString(fixtureHTML, baseURL: request.url)
        }
    }

    @MainActor
    private final class Fixture {
        let browser: EmbeddedBrowserSession
        let renderWindow: FixtureRenderWindow
        let renderHost: EmbeddedModelRenderContainer
        let humanID: UUID
        let humanView: WKWebView
        var createdTabs: [UUID] = []
        var isolatedViews: [PrewarmFixtureWebView] = []
        var page: String
        var initialURL: URL?
        private(set) var transport: EmbeddedWebModelTransport!
        var traceLifecycle = false

        init(page: String = EmbeddedWebModelTransportTests.page, initialURL: URL? = nil, isolatedInference: Bool = false,
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
            if isolatedInference {
                browser.setModelViewFactoryForTesting { [unowned self] configuration in
                    let view = PrewarmFixtureWebView(configuration: configuration, fixtureHTML: self.page)
                    self.isolatedViews.append(view)
                    return view
                }
                transport = EmbeddedWebModelTransport(browser: browser)
                return
            }
            transport = EmbeddedWebModelTransport(browser: browser, createTabForTesting: { [unowned self] url in
                // Load only the local fixture, retaining the product's model
                // ownership, render-host mounting, and inactive-tab behavior.
                let id = try self.browser.createUnloadedModelTabForTesting()
                let view = try XCTUnwrap(self.browser.webView(for: id))
                view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
                let html: String
                if !self.page.contains("fixture-model-trigger"), url.host == "chatgpt.com" {
                    html = EmbeddedWebModelTransportTests.modelChoicePage(.chatgpt, basePage: self.page)
                } else if !self.page.contains("fixture-model-trigger"), url.host == "gemini.google.com" {
                    // A bare provider start still needs observed checked family
                    // proof. Generic Pro has no version: the unchanged local
                    // page must reveal its actual selected family in the picker.
                    html = EmbeddedWebModelTransportTests.modelChoicePage(.gemini, genericHeader: true, basePage: self.page)
                } else { html = self.page }
                view.loadHTMLString(html, baseURL: self.initialURL ?? url)
                self.createdTabs.append(id)
                return id
            })
        }

        func shutdown() {
            if traceLifecycle { print("WKFixturePhase phase=shutdown_browser boundary=begin") }
            browser.shutdown()
            if traceLifecycle { print("WKFixturePhase phase=shutdown_browser boundary=end") }
            renderHost.detach()
            if traceLifecycle { print("WKFixturePhase phase=shutdown_host_detached boundary=end") }
            renderWindow.orderOut(nil)
            if traceLifecycle { print("WKFixturePhase phase=shutdown_window_ordered_out boundary=end") }
            renderWindow.close()
            if traceLifecycle { print("WKFixturePhase phase=shutdown_window_closed boundary=end") }
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
            """).replacingOccurrences(of: "body.textContent = '{\"type\":\"message\",\"text\":\"Fixture reply\"}';",
                with: "body.textContent = window.fixturePrompts.length === 2 ? '{\"type\":\"message\",\"text\":\"Appended fixture reply\"}' : '{\"type\":\"message\",\"text\":\"Fixture reply\"}';")
    }

    /// Observe private proof without writing it; the fixture changes only real
    /// DOM nodes after a completed adapter read and before the next invocation.
    private func replaceVerifiedGeminiQuery(_ view: WKWebView, sequence: Int = 1, bodyOnly: Bool, changeText: Bool) async throws -> [String: Any]? {
        try await evaluate(view, """
            const state = globalThis.__computaGeminiSubmissionState, record = state?.lastVerified;
            const root = [...document.querySelectorAll('user-query')][\(sequence - 1)];
            const body = root?.querySelector('.user-query-bubble-with-background > span.ng-star-inserted');
            if (!record || record.sequence !== \(sequence) || record.phase !== 'verified' || state.revoked
              || state.pending || record.root !== root || record.body !== body || !root?.isConnected || !body?.isConnected) return null;
            const firstPinMatches = globalThis.__computaModelFirstProof?.fingerprint === record.fingerprint;
            const replacement = (\(bodyOnly ? "true" : "false") ? body : root).cloneNode(true);
            if (\(changeText ? "true" : "false")) {
              const row = replacement.querySelector('.query-text-line');
              row.textContent = row.textContent.replace('Preserve', 'Changed');
            }
            if (\(bodyOnly ? "true" : "false")) body.replaceWith(replacement); else root.replaceWith(replacement);
            return {verifiedBeforeReplacement: true, firstPinMatches,
              oldRootDisconnected: !root.isConnected, oldBodyDisconnected: !body.isConnected,
              recordKeepsOldPointers: record.root === root && record.body === body, fingerprint: record.fingerprint};
            """, world: .world(name: "computa-chatgpt-model-v1")) as? [String: Any]
    }

    private func geminiVerifiedQueryState(_ view: WKWebView, sequence: Int) async throws -> [String: Any] {
        let value = try await evaluate(view, """
            const state = globalThis.__computaGeminiSubmissionState, record = state?.lastVerified;
            const root = [...document.querySelectorAll('user-query')][\(sequence - 1)];
            const body = root?.querySelector('.user-query-bubble-with-background > span.ng-star-inserted');
            return {sequence: record?.sequence, revoked: state?.revoked === true,
              currentPointers: record?.root === root && record?.body === body,
              certificateLinksOldAndCurrent: !!record?.remount
                && record.remount.previousRoot === record.root && record.remount.previousBody === record.body
                && !record.root.isConnected && !record.body.isConnected
                && record.remount.root === root && record.remount.body === body,
              receiptConsumed: record?.remount == null, fingerprint: record?.fingerprint,
              firstFingerprint: globalThis.__computaModelFirstProof?.fingerprint};
            """, world: .world(name: "computa-chatgpt-model-v1"))
        return try XCTUnwrap(value as? [String: Any])
    }

    private enum GeminiQueryParagraphVariant {
        case literal, framed, mixedFrame, unclippedHeader, forgedHeader, extraRow, rowControl
    }

    private static func geminiQueryParagraphPage(_ variant: GeminiQueryParagraphVariant = .literal) -> String {
        // Only these tests use the measured query component. The original
        // provider fixture remains a simple literal SPAN for legacy coverage.
        providerPage(.gemini).replacingOccurrences(of: "const prompt = editor.innerText;", with: #"""
            // Quill's terminal editor block contributes one LF after the
            // private nonce. The measured query renderer omits only that LF.
            const prompt = editor.innerText.replace(/(\n\nComputa session marker: [A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12})\n(?![\s\S])/, '$1');
            """#).replacingOccurrences(
            of: "const literal = document.createElement('span'); literal.textContent = prompt; payload.appendChild(literal);",
            with: """
            const query = document.createElement('div'); query.className = 'query-text gds-body-l';
            const heading = document.createElement('h2');
            heading.className = 'cdk-visually-hidden';
            \(variant == .forgedHeader ? "heading.setAttribute('role', 'presentation');" : "")
            heading.style.cssText = '\(variant == .unclippedHeader ? "position:static;width:auto;height:auto;overflow:visible;clip:auto;" : "position:absolute;width:1px;height:1px;padding:0;margin:-1px;border:0;overflow:hidden;clip:rect(0px,0px,0px,0px);clip-path:inset(50%);white-space:nowrap;user-select:none;")';
            const headingText = document.createElement('span'); headingText.textContent = 'Synthetic accessibility heading '.repeat(4);
            heading.appendChild(headingText); query.appendChild(heading);
            prompt.split('\\n').forEach((line, index) => {
              const row = document.createElement('p'); row.className = 'query-text-line ng-star-inserted';
              const framed = \(variant == .framed ? "true" : variant == .mixedFrame ? "index === 0" : "false");
              if (!line) row.appendChild(document.createElement('br'));
              else {
                if (framed) row.appendChild(document.createTextNode(' '));
                row.appendChild(document.createTextNode(line));
                if (framed) row.appendChild(document.createTextNode(' '));
              }
              query.appendChild(row);
            });
            \(variant == .extraRow ? "const extra = document.createElement('p'); extra.className = 'query-text-line ng-star-inserted'; extra.textContent = 'Unowned extra line'; query.appendChild(extra);" : "")
            \(variant == .rowControl ? "const control = document.createElement('button'); control.textContent = 'Unowned control'; query.querySelector('p').appendChild(control);" : "")
            payload.appendChild(query);
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


@MainActor
extension EmbeddedWebModelTransportTests {
    private func installRendererRecoveryFailureFixture(_ view: WKWebView) async throws {
        _ = try await evaluate(view, """
            const main = document.createElement('main'), messages = document.getElementById('messages');
            document.body.append(main); main.append(messages);
            const answer = messages.querySelector('[data-markdown-text-style="assistant-message"]');
            const portal = document.createElement('div'); portal.className = 'PortalBoundary-Fixture Renderer-Fixture';
            const renderer = document.createElement('div'); renderer.className = 'DilRenderer-Fixture DilResponseRoot-Fixture';
            const leaf = document.createElement('div'); leaf.textContent = 'This response couldn’t load';
            renderer.append(leaf); portal.append(renderer); answer.replaceChildren(portal);
            return true;
            """)
    }

    func testRendererRecoveryRefusesBusyAndExtraCurrentResponses() async throws {
        for mutation in ["busy", "extra_response"] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Do not recover an incomplete or ambiguous response")
            defer { fixture.shutdown() }
            try await installRendererRecoveryFailureFixture(view)
            _ = try await evaluate(view, mutation == "busy" ? """
                const stop = document.createElement('button'); stop.id = 'fixture-renderer-stop';
                stop.setAttribute('data-testid', 'stop-button'); stop.textContent = 'Stop generating';
                document.body.append(stop); return true;
                """ : """
                const answer = document.querySelector('[data-markdown-text-style="assistant-message"]');
                document.getElementById('messages').append(answer.parentElement.cloneNode(true)); return true;
                """)
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A \(mutation) renderer error cannot become a recoverable current response")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt), mutation) }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await evaluate(view, "document.getElementById('fixture-renderer-stop')?.remove(); return true;")
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
        }
    }

    func testRendererRecoveryRefusesExtraUserAndMissingOrChangedModel() async throws {
        for mutation in ["extra_user", "missing_model", "changed_model"] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Keep renderer recovery bound to current ownership and model")
            defer { fixture.shutdown() }
            try await installRendererRecoveryFailureFixture(view)
            let script: String
            switch mutation {
            case "extra_user":
                script = """
                    const user = document.querySelector('[data-message-author-role="user"]');
                    window.fixtureExtraRendererUser = user.cloneNode(true);
                    document.getElementById('messages').append(window.fixtureExtraRendererUser); return true;
                    """
            case "missing_model":
                script = """
                    window.fixtureRemovedRendererModel = document.getElementById('fixture-model-trigger');
                    window.fixtureRemovedRendererModel.remove(); return true;
                    """
            default: script = "window.fixtureModelSelect(window.fixtureModelInitialLabel); return true;"
            }
            _ = try await evaluate(view, script)
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A \(mutation) observation cannot authorize renderer recovery")
            } catch {
                let failure = try XCTUnwrap(error as? EmbeddedWebModelTransport.Failure)
                XCTAssertNotEqual(failure, .responseRenderingFailed, mutation)
                if mutation == "changed_model" { XCTAssertEqual(failure, .modelMismatch) }
                if mutation == "missing_model" {
                    XCTAssertTrue(failure == .modelMismatch || failure == .modelUnverified, "Unexpected missing-model rejection: \(failure)")
                }
                if mutation == "extra_user" {
                    if case .ownershipFailure = failure {} else {
                        XCTFail("Expected an ownership rejection, received \(failure)")
                    }
                }
            }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await evaluate(view, """
                if (window.fixtureRemovedRendererModel) document.body.append(window.fixtureRemovedRendererModel);
                return true;
                """)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, mutation == "extra_user" ? "failed" : "not_created")
            try await assertHumanTabIntact(fixture, retaining: mutation == "extra_user" ? fixture.createdTabs.last : nil)
        }
    }

    func testRendererRecoveryDoesNotPromoteLiteralOrMismatchedRendererLabels() async throws {
        for mutation in ["literal_label", "different_label"] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Do not promote an unclassified label into renderer recovery")
            defer { fixture.shutdown() }
            try await installRendererRecoveryFailureFixture(view)
            _ = try await evaluate(view, """
                const main = document.querySelector('main');
                const answer = main.querySelector('[data-markdown-text-style="assistant-message"]');
                if (\(mutation == "literal_label" ? "true" : "false")) answer.textContent = 'This response couldn’t load';
                else answer.querySelector('.DilRenderer-Fixture > div').textContent = 'This response could not load';
                const notice = document.createElement('div'), label = document.createElement('span'), retry = document.createElement('button');
                label.textContent = 'Load failed'; retry.textContent = 'Retry';
                window.fixtureRendererRetryClicks = 0; retry.addEventListener('click', () => window.fixtureRendererRetryClicks++);
                notice.append(label, retry); main.append(notice); return true;
                """)
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A generic load error plus \(mutation) cannot become renderer recovery")
            } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt), mutation) }
            let retryClicks = try await evaluate(view, "return window.fixtureRendererRetryClicks;") as? Int
            XCTAssertEqual(retryClicks, 0)
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
        }
    }

    func testRendererRecoveryRequiresOneFreshModelInspectionAndUnchangedAnswer() async throws {
        for changeAnswer in [false, true] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Reprove only this completed renderer failure")
            defer { fixture.shutdown() }
            try await installRendererRecoveryFailureFixture(view)
            let pickerBefore = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
            var inspections = 0
            fixture.transport.setBeforePageResultValidationForTesting { action in
                guard action == "inspect" else { return }
                inspections += 1
                guard changeAnswer, inspections == 1 else { return }
                do {
                    _ = try await self.evaluate(view, """
                        document.querySelector('.DilRenderer-Fixture > div').textContent = '{"type":"message","text":"Changed after the failed-body observation"}';
                        return true;
                        """)
                } catch { XCTFail("Unable to install changed-answer fixture: \(error)") }
            }
            do {
                _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
                XCTFail("A failed renderer cannot publish an answer")
            } catch {
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure,
                    changeAnswer ? .responseFailed(.chatgpt) : .responseRenderingFailed)
            }
            fixture.transport.setBeforePageResultValidationForTesting(nil)
            XCTAssertEqual(inspections, 2, "The initial deferred read permits exactly one full positive model inspection")
            let pickerAfter = try await evaluate(view, "return window.fixtureModelTriggerClicks;") as? Int
            XCTAssertGreaterThan(try XCTUnwrap(pickerAfter), try XCTUnwrap(pickerBefore),
                "Recovery needs a fresh positive model proof rather than only pending continuity")
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            let finished = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            XCTAssertEqual(finished["cleanup"] as? String, "not_created")
            try await assertHumanTabIntact(fixture)
        }
    }
}

extension EmbeddedWebModelTransportTests {
    func testRendererStateDiagnosticArmIsOptionalFiniteAndSingleUse() async throws {
        let key = "ComputaRendererFailureDiagnosticExpiresAt"
        for kind in ["absent", "boolean", "expired", "too_far", "missing_source", "armed"] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Private diagnostic does not authorize a response")
            defer { fixture.shutdown() }
            try await installRendererRecoveryFailureFixture(view)
            let suite = "ComputaRendererDiagnosticTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            switch kind {
            case "boolean": defaults.set(true, forKey: key)
            case "expired": defaults.set(Date().timeIntervalSince1970 - 1, forKey: key)
            case "too_far": defaults.set(Date().timeIntervalSince1970 + 3_600, forKey: key)
            case "missing_source", "armed": defaults.set(Date().timeIntervalSince1970 + 60, forKey: key)
            default: break
            }
            var captures: [Data] = []
            fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults,
                source: kind == "missing_source" ? nil : "window.fixtureRendererDiagnosticCalls=(window.fixtureRendererDiagnosticCalls||0)+1; return {version:1,status:'unavailable',reason:'committed_runner_snapshot_missing'};") { captures.append($0) }
            for _ in 0..<2 {
                do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("The failure must remain terminal") }
                catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseRenderingFailed, kind) }
            }
            let calls = try await evaluate(view, "return window.fixtureRendererDiagnosticCalls||0;") as? Int
            XCTAssertEqual(calls, kind == "armed" ? 1 : 0, kind)
            XCTAssertEqual(captures.count, kind == "armed" ? 1 : 0, kind)
            if ["armed", "missing_source"].contains(kind) { XCTAssertNil(defaults.object(forKey: key)) }
            if let capture = captures.first {
                XCTAssertLessThanOrEqual(capture.count, 8_192)
                let record = try XCTUnwrap(JSONSerialization.jsonObject(with: capture) as? [String: Any])
                XCTAssertEqual(record["sessionID"] as? String, UUID(uuidString: token)?.uuidString)
                XCTAssertEqual(record["sequence"] as? Int, 1)
                XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererWorkDiagnostic(record["work"]),
                    "The same armed adapter result supplies finite work without another page read")
            }
            if !["armed", "missing_source"].contains(kind) {
                XCTAssertNil(fixture.transport.rendererWorkDiagnosticForTesting(sessionToken: token),
                    "An invalid or absent arm must not cache work")
            }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
        }
    }

    func testRendererStateDiagnosticTimeoutDoesNotChangeFailureOrRepeatPageWork() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "A diagnostic timeout is not an inference retry")
        defer { fixture.shutdown() }
        try await installRendererRecoveryFailureFixture(view)
        let suite = "ComputaRendererDiagnosticTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "ComputaRendererFailureDiagnosticExpiresAt"
        defaults.set(Date().timeIntervalSince1970 + 60, forKey: key)
        var captures: [Data] = []
        fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults,
            source: "window.fixtureRendererDiagnosticCalls=(window.fixtureRendererDiagnosticCalls||0)+1; await new Promise(resolve=>setTimeout(resolve,1_000)); return {version:1,status:'unavailable',reason:'read_failed'};") { captures.append($0) }
        let began = ContinuousClock.now
        do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Original renderer failure expected") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseRenderingFailed) }
        let elapsed = ContinuousClock.now - began
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450))
        XCTAssertLessThan(elapsed, .seconds(2), "The diagnostic must not extend to the ordinary30s inspection budget")
        XCTAssertTrue(captures.isEmpty); XCTAssertNil(defaults.object(forKey: key))
        let calls = try await evaluate(view, "return window.fixtureRendererDiagnosticCalls||0;") as? Int
        XCTAssertEqual(calls, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testRendererStateDiagnosticSanitizerRejectsArbitraryFieldsAndInvalidTypes() {
        let valid: [String: Any] = ["version": 1, "status": "unavailable", "reason": "context_mismatch"]
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererStateDiagnostic(valid))
        for mutation: [String: Any] in [valid.merging(["pageText": "PRIVATE_SENTINEL"], uniquingKeysWith: { _, new in new }),
            ["version": true, "status": "unavailable", "reason": "context_mismatch"],
            ["version": 1, "status": "unavailable", "reason": "PRIVATE_SENTINEL"],
            ["version": 1, "status": "captured", "error": "PRIVATE_SENTINEL"]] {
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedRendererStateDiagnostic(mutation))
        }
    }

    func testRendererStartupDiagnosticAcceptsOnlyFiniteBoundedStageRecords() {
        let event: [String: Any] = ["realm": "worker", "operation": "harden_worker", "phase": "returned",
            "localTimeMs": 12.5, "timeOriginMs": 1_792_980_000_000, "workerGeneration": 1, "artifactId": "DrCNBd66", "reason": "bundle_evaluation"]
        let valid: [String: Any] = ["version": 1, "events": [event], "dropped": 0]
        XCTAssertTrue(EmbeddedWebModelTransport.validRendererStartupDiagnostic(valid))
        XCTAssertTrue(EmbeddedWebModelTransport.validRendererStartupDiagnostic(["version": 1, "events": [], "dropped": 0]))
        for change: [String: Any] in [["realm": "page"], ["operation": "PRIVATE_SENTINEL"], ["phase": "private"],
            ["message": "PRIVATE_SENTINEL"], ["url": "https://example.invalid/private"], ["runnerId": "private"],
            ["localTimeMs": true], ["localTimeMs": -1], ["localTimeMs": Double.infinity], ["localTimeMs": 1e16],
            ["workerGeneration": 1.5], ["artifactId": "../private"], ["errorName": "PRIVATE_SENTINEL"], ["reason": "PRIVATE_SENTINEL"]] {
            let mutated = event.merging(change, uniquingKeysWith: { _, next in next })
            XCTAssertFalse(EmbeddedWebModelTransport.validRendererStartupDiagnostic(["version": 1, "events": [mutated], "dropped": 0]))
        }
        for change: [String: Any] in [["version": true], ["version": 0], ["dropped": true], ["dropped": -1],
            ["dropped": 1_000_001], ["events": Array(repeating: event, count: 65)], ["source": "PRIVATE_SENTINEL"]] {
            XCTAssertFalse(EmbeddedWebModelTransport.validRendererStartupDiagnostic(valid.merging(change, uniquingKeysWith: { _, next in next })))
        }
    }

    func testRendererWorkDiagnosticRejectsNonfiniteUnboundedAndArbitraryContent() {
        let valid: [String: Any] = ["version": 1, "invocationCount": 2,
            "stages": Array(repeating: [1, 20.5, 20.5], count: 13),
            "slowSpans": [[0, 1_792_980_000_000, 20.5]], "saturated": false]
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererWorkDiagnostic(valid))
        for change: [String: Any] in [
            ["version": true], ["version": 0], ["invocationCount": true], ["invocationCount": 257],
            ["stages": Array(repeating: [1, 1, 1], count: 14)],
            ["stages": Array(repeating: [true, 1, 1], count: 13)],
            ["stages": Array(repeating: [1, Double.infinity, 1], count: 13)],
            ["stages": Array(repeating: [1, Double.nan, 1], count: 13)],
            ["stages": Array(repeating: [0, 1, 1], count: 13)],
            ["stages": Array(repeating: [4_097, 1, 1], count: 13)],
            ["stages": Array(repeating: [1, 1, 2], count: 13)],
            ["slowSpans": [[13, 1, 10]]], ["slowSpans": [[0, 1, 9]]],
            ["slowSpans": [[0, 1e16, 10]]], ["slowSpans": [[0, 1, 600_001]]],
            ["slowSpans": Array(repeating: [0, 1, 10], count: 9)],
            ["saturated": 1], ["prompt": "PRIVATE_SENTINEL"], ["taskDelay": [1, 1, 1]]
        ] {
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedRendererWorkDiagnostic(
                valid.merging(change, uniquingKeysWith: { _, next in next })))
        }
    }

    private func rendererRegexDiagnosticFixture() -> [String: Any] {
        ["version": 3, "callCount": 128, "totalDurationMs": 5_500.5, "maxDurationMs": 5_000.5,
         "saturated": false, "stopReason": "active", "records": [[
            "kind": "slow", "sampleCallCount": 128,
            "patternHash": "09abcdef", "patternLength": 80, "inputLength": 120_000,
            "flags": "gim", "startEpochMs": 1_792_980_000_000, "durationMs": 5_000.5,
            "publicStack": "https://chatgpt.com/cdn/assets/async/123456.0123456789.js:1:456"]]]
    }

    private func rendererSuccessDiagnosticFixtureSource(delay: Int = 0) throws -> String {
        let projection: [String: Any] = ["version": 1, "status": "regex_captured", "regex": rendererRegexDiagnosticFixture()]
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: projection), encoding: .utf8))
        return "window.fixtureRendererSuccessCalls=(window.fixtureRendererSuccessCalls||0)+1;"
            + "await new Promise(resolve=>setTimeout(resolve,\(delay))); return \(json);"
    }

    func testRendererSuccessDiagnosticRequiresMatchingFiniteSecondArmAndIsSingleUse() async throws {
        let failureKey = "ComputaRendererFailureDiagnosticExpiresAt", successKey = "ComputaRendererSuccessDiagnosticExpiresAt"
        for kind in ["absent", "mismatch", "boolean", "expired", "too_far", "missing_source", "armed"] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Success diagnostic arm fixture \(kind)")
            defer { fixture.shutdown() }
            let suite = "ComputaRendererSuccessTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let expiry = Date().timeIntervalSince1970 + (kind == "expired" ? -1 : kind == "too_far" ? 3_600 : 60)
            defaults.set(expiry, forKey: failureKey)
            if kind != "absent" { defaults.set(kind == "mismatch" ? expiry - 1 : expiry, forKey: successKey) }
            if kind == "boolean" { defaults.set(true, forKey: successKey) }
            var captures: [Data] = []
            fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults,
                source: kind == "missing_source" ? nil : try rendererSuccessDiagnosticFixtureSource()) { captures.append($0) }
            let complete = try await waitForState("complete", fixture.transport, token: token)
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
            try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            let calls = try await evaluate(view, "return window.fixtureRendererSuccessCalls||0;") as? Int
            XCTAssertEqual(calls, kind == "armed" ? 1 : 0, kind)
            XCTAssertEqual(captures.count, kind == "armed" ? 1 : 0, kind)
            XCTAssertEqual(defaults.double(forKey: failureKey), expiry, "Success does not consume the failure arm")
            if ["armed", "missing_source"].contains(kind) { XCTAssertNil(defaults.object(forKey: successKey)) }
            if let capture = captures.first {
                XCTAssertLessThanOrEqual(capture.count, 4_096)
                let record = try XCTUnwrap(JSONSerialization.jsonObject(with: capture) as? [String: Any])
                XCTAssertEqual(record["kind"] as? String, "verified_response_regex")
                XCTAssertEqual(record["sessionID"] as? String, UUID(uuidString: token)?.uuidString)
                XCTAssertEqual(record["sequence"] as? Int, 1)
                XCTAssertEqual(record["documentGeneration"] as? String,
                    fixture.browser.documentGeneration(for: try XCTUnwrap(fixture.createdTabs.last))?.uuidString)
                XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererSuccessDiagnostic(record["projection"]))
                XCTAssertNil(complete["projection"])
            }
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
        }
    }

    func testRendererSuccessDiagnosticTimeoutOrInvalidDataDoesNotChangeVerifiedResponse() async throws {
        for timeout in [false, true] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Discard a failed optional success diagnostic")
            defer { fixture.shutdown() }
            let suite = "ComputaRendererSuccessTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let expiry = Date().timeIntervalSince1970 + 60
            defaults.set(expiry, forKey: "ComputaRendererFailureDiagnosticExpiresAt")
            defaults.set(expiry, forKey: "ComputaRendererSuccessDiagnosticExpiresAt")
            var captures: [Data] = []
            fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults,
                source: timeout ? try rendererSuccessDiagnosticFixtureSource(delay: 1_000)
                    : "window.fixtureRendererSuccessCalls=1; return {version:1,status:'regex_captured',regex:{text:'PRIVATE_SENTINEL'}};") { captures.append($0) }
            try await Task.sleep(for: .milliseconds(1_650))
            let began = ContinuousClock.now
            let complete = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            let elapsed = ContinuousClock.now - began
            XCTAssertEqual(complete["state"] as? String, "complete")
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
            if timeout { XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450)) }
            XCTAssertLessThan(elapsed, .milliseconds(900), "Only the optional500ms read budget may delay completion")
            XCTAssertTrue(captures.isEmpty)
            XCTAssertNil(defaults.object(forKey: "ComputaRendererSuccessDiagnosticExpiresAt"))
            let calls = try await evaluate(view, "return window.fixtureRendererSuccessCalls||0;") as? Int
            XCTAssertEqual(calls, 1)
            _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
            _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
            try await assertHumanTabIntact(fixture)
        }
    }

    func testRendererSuccessDiagnosticDiscardsCancelledOrClosedViewRead() async throws {
        for cancelled in [true, false] {
            let (fixture, token, view) = try await boundInspectionFixture(prompt: "Diagnostic cannot preserve stale completion proof")
            defer { fixture.shutdown() }
            let suite = "ComputaRendererSuccessTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let expiry = Date().timeIntervalSince1970 + 60
            defaults.set(expiry, forKey: "ComputaRendererFailureDiagnosticExpiresAt")
            defaults.set(expiry, forKey: "ComputaRendererSuccessDiagnosticExpiresAt")
            var captures: [Data] = []
            fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults,
                source: try rendererSuccessDiagnosticFixtureSource(delay: 300)) { captures.append($0) }
            try await Task.sleep(for: .milliseconds(1_650))
            let polling = Task { @MainActor in
                _ = try await self.call(fixture.transport, "webProviderPoll", ["sessionToken": token])
            }
            defer { polling.cancel() }
            let limit = ContinuousClock.now + .seconds(2)
            while try await evaluate(view, "return window.fixtureRendererSuccessCalls||0;") as? Int != 1 {
                guard ContinuousClock.now < limit else { XCTFail("Success read was not dispatched"); return }
                try await Task.sleep(for: .milliseconds(10))
            }
            if cancelled { polling.cancel() }
            else { fixture.browser.closeTab(try XCTUnwrap(fixture.createdTabs.last)) }
            do { _ = try await polling.value; XCTFail("Cancelled or stale proof must not publish") }
            catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .staleSession) }
            }
            XCTAssertTrue(captures.isEmpty)
            XCTAssertNil(defaults.object(forKey: "ComputaRendererSuccessDiagnosticExpiresAt"))
            if cancelled { _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token]) }
            try await assertHumanTabIntact(fixture)
        }
    }

    func testRendererSuccessDiagnosticWaitsForOrdinaryCompletionProof() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Diagnostic requires the ordinary completion footer")
        defer { fixture.shutdown() }
        let suite = "ComputaRendererSuccessTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let expiry = Date().timeIntervalSince1970 + 60
        defaults.set(expiry, forKey: "ComputaRendererFailureDiagnosticExpiresAt")
        defaults.set(expiry, forKey: "ComputaRendererSuccessDiagnosticExpiresAt")
        var captures: [Data] = []
        fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults,
            source: try rendererSuccessDiagnosticFixtureSource()) { captures.append($0) }
        _ = try await evaluate(view, "document.querySelector('button[aria-label=\"Copy\"]').disabled=true; return true;")
        try await Task.sleep(for: .milliseconds(1_650))
        let pending = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertEqual(pending["state"] as? String, "running")
        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(defaults.double(forKey: "ComputaRendererSuccessDiagnosticExpiresAt"), expiry)
        let calls = try await evaluate(view, "return window.fixtureRendererSuccessCalls||0;") as? Int
        XCTAssertEqual(calls, 0)
        _ = try await evaluate(view, "document.querySelector('button[aria-label=\"Copy\"]').disabled=false; return true;")
        _ = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(captures.count, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testRendererSuccessDiagnosticSchemaCannotBeUsedAsFailureEvidence() {
        let valid: [String: Any] = ["version": 1, "status": "regex_captured", "regex": rendererRegexDiagnosticFixture()]
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererSuccessDiagnostic(valid))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedRendererStateDiagnostic(valid))
        for change: [String: Any] in [["version": true], ["status": "captured"], ["status": "unavailable"],
            ["text": "PRIVATE_SENTINEL"], ["regex": ["input": "PRIVATE_SENTINEL"]]] {
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedRendererSuccessDiagnostic(
                valid.merging(change, uniquingKeysWith: { _, next in next })))
        }
    }

    func testRendererSuccessDiagnosticCannotAmendAlreadyAcceptedResponse() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Freeze the verified response before optional diagnostics")
        defer { fixture.shutdown() }
        let suite = "ComputaRendererSuccessTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let expiry = Date().timeIntervalSince1970 + 60
        defaults.set(expiry, forKey: "ComputaRendererFailureDiagnosticExpiresAt")
        defaults.set(expiry, forKey: "ComputaRendererSuccessDiagnosticExpiresAt")
        var captures: [Data] = []
        fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults, source: """
            document.querySelector('[data-markdown-text-style="assistant-message"]').textContent = 'CHANGED_AFTER_ACCEPTANCE';
            document.querySelector('button[aria-label="Copy"]').disabled = true;
            window.fixtureModelSelect(window.fixtureModelInitialLabel);
            \(try rendererSuccessDiagnosticFixtureSource())
            """) { captures.append($0) }
        let complete = try await waitForState("complete", fixture.transport, token: token)
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Fixture reply"}"#)
        try assertChoiceEvidence(complete, choice: Self.fixtureChoice(.chatgpt))
        let changed = try await evaluate(view, "return document.querySelector('[data-markdown-text-style=\"assistant-message\"]').textContent;") as? String
        XCTAssertEqual(changed, "CHANGED_AFTER_ACCEPTANCE")
        XCTAssertEqual(captures.count, 1, "Diagnostic data may be kept but cannot amend the already accepted output")
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    private func rendererStateWithRegexFixture(_ regex: Any) -> [String: Any] {
        ["version": 1, "status": "captured", "ancestorDepth": 0, "snapshotVersion": 1,
         "treeIsNull": true, "runnerDisposed": false,
         "error": ["name": "Error", "message": NSNull(), "messageTruncated": false,
                   "publicStack": "", "stage": "worker_timeout"],
         "lifecycle": ["failureStage": "worker_timeout", "frameReady": true, "frameRecovering": false,
                       "workerReady": false, "firstSnapshotSucceeded": false],
         "frame": ["readyResolved": true, "disposed": false, "retired": true,
                   "retriedPreReadyFrame": false, "moduleErrorPresent": false, "policyDenied": NSNull()],
         "regex": regex]
    }

    func testRendererRegexDiagnosticBoundsAndPrivateContent() throws {
        let valid = rendererRegexDiagnosticFixture()
        let record = try XCTUnwrap((valid["records"] as? [[String: Any]])?.first)
        XCTAssertTrue(EmbeddedWebModelTransport.validRendererRegexDiagnostic(valid))
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererStateDiagnostic(rendererStateWithRegexFixture(valid)))
        for reason in ["active", "expired", "pagehide", "limit", "replaced"] {
            XCTAssertTrue(EmbeddedWebModelTransport.validRendererRegexDiagnostic(
                valid.merging(["stopReason": reason, "records": []], uniquingKeysWith: { _, next in next })))
        }
        let unknownInput = record.merging(["inputLength": NSNull(), "flags": "", "publicStack": ""], uniquingKeysWith: { _, next in next })
        XCTAssertTrue(EmbeddedWebModelTransport.validRendererRegexDiagnostic(
            valid.merging(["stopReason": "limit", "records": Array(repeating: unknownInput, count: 4)], uniquingKeysWith: { _, next in next })))
        for change: [String: Any] in [
            ["kind": "PRIVATE_SENTINEL"], ["kind": "periodic"], ["sampleCallCount": true], ["sampleCallCount": 0],
            ["sampleCallCount": 1.5], ["sampleCallCount": 129], ["sampleCallCount": 1_000_001],
            ["patternHash": "PRIVATE_SENTINEL"], ["patternHash": "09ABCDEF"],
            ["patternLength": true], ["patternLength": -1], ["patternLength": 1.5], ["patternLength": 16_385],
            ["inputLength": "PRIVATE_SENTINEL"], ["inputLength": true], ["inputLength": 1.5], ["inputLength": 1_000_000_001],
            ["flags": "gg"], ["flags": "ig"], ["flags": "uv"], ["flags": "x"],
            ["startEpochMs": true], ["startEpochMs": -1], ["startEpochMs": Double.nan], ["startEpochMs": 1e16],
            ["durationMs": 99.9], ["durationMs": Double.infinity], ["durationMs": 600_001],
            ["publicStack": "PRIVATE_SENTINEL"], ["publicStack": "https://chatgpt.com/c/private:1:2"],
            ["publicStack": "https://chatgpt.com/cdn/assets/123456.0123456789.js?private=1:1:2"],
            ["publicStack": Array(repeating: record["publicStack"] as! String, count: 3).joined(separator: "\n")],
            ["input": "PRIVATE_SENTINEL"], ["pattern": "PRIVATE_SENTINEL"]
        ] {
            let mutated = valid.merging(["records": [record.merging(change, uniquingKeysWith: { _, next in next })]], uniquingKeysWith: { _, next in next })
            XCTAssertFalse(EmbeddedWebModelTransport.validRendererRegexDiagnostic(mutated), "Mutation keys: \(change.keys)")
            XCTAssertNil(EmbeddedWebModelTransport.sanitizedRendererStateDiagnostic(rendererStateWithRegexFixture(mutated)))
        }
        for change: [String: Any] in [["version": true], ["version": 0], ["version": 1], ["version": 2], ["stopReason": "PRIVATE_SENTINEL"],
            ["callCount": true], ["callCount": -1], ["callCount": 1.5], ["callCount": 1_000_001], ["callCount": 0],
            ["totalDurationMs": Double.infinity], ["totalDurationMs": 1e10], ["totalDurationMs": -1],
            ["maxDurationMs": Double.nan], ["maxDurationMs": 600_001], ["maxDurationMs": 5_501], ["saturated": 1],
            ["records": Array(repeating: record, count: 5)], ["records": ["PRIVATE_SENTINEL"]], ["source": "PRIVATE_SENTINEL"]] {
            XCTAssertFalse(EmbeddedWebModelTransport.validRendererRegexDiagnostic(valid.merging(change, uniquingKeysWith: { _, next in next })))
        }
        let work: [String: Any] = ["version": 1, "invocationCount": 1, "stages": Array(repeating: [0, 0, 0], count: 13),
            "slowSpans": [], "saturated": false, "regex": valid]
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererWorkDiagnostic(work))
        XCTAssertNil(EmbeddedWebModelTransport.sanitizedRendererWorkDiagnostic(work.merging(["regex": ["input": "PRIVATE_SENTINEL"]], uniquingKeysWith: { _, next in next })))
    }

    func testRendererRegexPeriodicSamplesRequireExactCheckpointAndDistinctDurationRule() throws {
        let valid = rendererRegexDiagnosticFixture()
        let record = try XCTUnwrap((valid["records"] as? [[String: Any]])?.first)
        let checkpoints = [250_000, 500_000, 750_000, 1_000_000]
        let records = checkpoints.map { checkpoint in
            record.merging(["kind": "periodic", "sampleCallCount": checkpoint, "durationMs": 0.5], uniquingKeysWith: { _, next in next })
        }
        let periodic = valid.merging(["callCount": 1_000_000, "records": records, "stopReason": "limit"], uniquingKeysWith: { _, next in next })
        XCTAssertTrue(EmbeddedWebModelTransport.validRendererRegexDiagnostic(periodic))
        for mutation: [String: Any] in [["sampleCallCount": 249_999], ["sampleCallCount": 500_001],
            ["sampleCallCount": "250000"], ["durationMs": -0.1], ["durationMs": Double.nan], ["kind": "slow"]] {
            let bad = records[0].merging(mutation, uniquingKeysWith: { _, next in next })
            XCTAssertFalse(EmbeddedWebModelTransport.validRendererRegexDiagnostic(periodic.merging(["records": [bad]], uniquingKeysWith: { _, next in next })))
        }
        XCTAssertFalse(EmbeddedWebModelTransport.validRendererRegexDiagnostic(periodic.merging(["callCount": 999_999], uniquingKeysWith: { _, next in next })),
            "A record cannot claim a checkpoint the aggregate has not reached")
    }

    func testRendererRegexDiagnosticCapturePreservesFailureAndSinglePageRead() async throws {
        let (fixture, token, view) = try await boundInspectionFixture(prompt: "Private regex attribution must not authorize output")
        defer { fixture.shutdown() }
        try await installRendererRecoveryFailureFixture(view)
        let suite = "ComputaRendererRegexTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "ComputaRendererFailureDiagnosticExpiresAt"
        let expiry = Date().timeIntervalSince1970 + 60
        defaults.set(expiry, forKey: key)
        let projection = rendererStateWithRegexFixture(rendererRegexDiagnosticFixture())
        let encoded = try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys])
        let literal = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let regexLiteral = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: rendererRegexDiagnosticFixture()), encoding: .utf8))
        _ = try await evaluate(view, """
            Object.defineProperty(globalThis, '__computaRendererRegexDiagnosticV1', {value:{
              expiresAtUnixSeconds:\(expiry), snapshot:()=> (\(regexLiteral))}}); return true;
            """, world: WKContentWorld.world(name: "computa-chatgpt-model-v1"))
        var captures: [Data] = []
        fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults,
            source: "window.fixtureRendererDiagnosticCalls=(window.fixtureRendererDiagnosticCalls||0)+1; return \(literal);") { captures.append($0) }
        for _ in 0..<2 {
            do { _ = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Renderer failure must remain terminal") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseRenderingFailed) }
        }
        XCTAssertEqual(captures.count, 1)
        XCTAssertNil(defaults.object(forKey: key))
        let capture = try XCTUnwrap(captures.first)
        XCTAssertLessThanOrEqual(capture.count, 16_384)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: capture) as? [String: Any])
        let persisted = try XCTUnwrap(envelope["projection"] as? [String: Any])
        XCTAssertNotNil(EmbeddedWebModelTransport.sanitizedRendererStateDiagnostic(persisted))
        XCTAssertTrue(EmbeddedWebModelTransport.validRendererRegexDiagnostic(try XCTUnwrap(persisted["regex"])))
        let work = try XCTUnwrap(envelope["work"] as? [String: Any])
        XCTAssertTrue(EmbeddedWebModelTransport.validRendererRegexDiagnostic(try XCTUnwrap(work["regex"])),
            "Private-world metadata must reach the same capture through the existing owned adapter result")
        let calls = try await evaluate(view, "return window.fixtureRendererDiagnosticCalls||0;") as? Int
        XCTAssertEqual(calls, 1)
        try await assertChoiceLedger(view, insertions: 1, sends: 1, selections: 1)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }

    func testRendererWorkDiagnosticExpiryClearsCacheWithoutChangingResponse() async throws {
        let (fixture, token, _) = try await boundInspectionFixture(prompt: "Finite timing never changes response authority")
        defer { fixture.shutdown() }
        let suite = "ComputaRendererWorkTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        fixture.transport.setRendererFailureDiagnosticForTesting(defaults: defaults, source: nil) { _ in XCTFail("No renderer failure") }
        let key = "ComputaRendererFailureDiagnosticExpiresAt"
        XCTAssertNil(fixture.transport.rendererWorkDiagnosticForTesting(sessionToken: token))
        defaults.set(Date().timeIntervalSince1970 + 60, forKey: key)
        let armed = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertNotNil(fixture.transport.rendererWorkDiagnosticForTesting(sessionToken: token))
        XCTAssertNil(armed["rendererWorkDiagnostic"])
        defaults.set(Date().timeIntervalSince1970 - 1, forKey: key)
        let expired = try await call(fixture.transport, "webProviderPoll", ["sessionToken": token])
        XCTAssertNil(fixture.transport.rendererWorkDiagnosticForTesting(sessionToken: token))
        XCTAssertNil(expired["rendererWorkDiagnostic"])
        XCTAssertEqual(expired["text"] as? String, armed["text"] as? String)
        _ = try await call(fixture.transport, "webProviderFinish", ["sessionToken": token])
        try await assertHumanTabIntact(fixture)
    }
}

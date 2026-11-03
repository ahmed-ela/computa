import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class QwenWebModelTransportTests: XCTestCase {
    private let world = WKContentWorld.world(name: "computa-chatgpt-model-v1")

    func testUnexpectedRouteDiagnosticSeparatesOriginPathAndQueryWithoutChangingAdmission() throws {
        let canonical = "https://chat.qwen.ai/c/11111111-abcd-4333-8444-555555555555"
        let cases: [(String, Bool, [String])] = [
            ("https://chat.qwen.ai/", true, ["scheme=https", "host=expected", "path=root", "query=absent"]),
            (canonical, true, ["host=expected", "path=conversation_uuid", "queryKey=absent", "fragment=false"]),
            ("https://private-host.example/c/11111111-abcd-4333-8444-555555555555", false, ["host=other", "path=conversation_uuid"]),
            ("http://chat.qwen.ai/", false, ["scheme=http", "host=expected", "path=root"]),
            ("https://chat.qwen.ai/c/private-conversation-canary", false, ["path=conversation_other"]),
            ("https://chat.qwen.ai/private-path-canary", false, ["path=other"]),
            (canonical.uppercased().replacingOccurrences(of: "HTTPS://CHAT.QWEN.AI/C/", with: "https://chat.qwen.ai/c/"),
                false, ["path=conversation_other", "uuid=upper", "pathEncoded=false", "trailingSlash=false"]),
            (canonical.replacingOccurrences(of: "abcd", with: "AbCd"), false, ["uuid=mixed"]),
            (canonical + "/", false, ["path=conversation_other", "uuid=lower", "trailingSlash=true"]),
            (canonical.replacingOccurrences(of: "/c/1", with: "/c/%31"), false, ["pathEncoded=true", "uuid=lower"]),
            (canonical + "?model=PRIVATE_QUERY_VALUE", false, ["path=conversation_uuid", "query=present", "queryKey=model"]),
            (canonical + "?", false, ["query=empty", "queryKey=empty"]),
            (canonical + "#PRIVATE_FRAGMENT", false, ["fragment=true"]),
            ("https://chat.qwen.ai:443/", false, ["port=https_default"]),
            ("https://private-user:private-password@chat.qwen.ai/", false, ["userInfo=true"]),
        ]
        for (raw, admitted, fragments) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(EmbeddedWebModelTransport.Provider.qwen.accepts(raw), admitted)
            let result = EmbeddedWebModelTransport.unexpectedQwenRouteDiagnostic(url)
            for fragment in fragments { XCTAssertTrue(result.split(separator: " ").contains(Substring(fragment)), fragment) }
            XCTAssertEqual(EmbeddedWebModelTransport.Provider.qwen.accepts(raw), admitted,
                "Diagnostic classification never grants route authority")
            XCTAssertLessThanOrEqual(result.utf8.count, 384)
            for forbidden in ["PRIVATE_", "private-", "11111111", "http://", "https://", "chat.qwen.ai"] {
                XCTAssertFalse(result.contains(forbidden))
            }
        }
    }

    func testUnexpectedRouteDiagnosticNeverPublishesUnknownKeysOrValues() throws {
        let queries = [
            "PRIVATE_KEY=PRIVATE_VALUE": "other",
            "%6dodel=PRIVATE_VALUE": "model",
            "chat_id=PRIVATE_VALUE": "chat_id",
            "model=PRIVATE_VALUE&PRIVATE_KEY=PRIVATE_SECOND_VALUE": "multiple",
            String(repeating: "X", count: 4096) + "=PRIVATE_VALUE": "other",
        ]
        let allowedKeys = Set(["absent", "empty", "model", "model_id", "chat_id", "conversation_id", "chat_enter_method", "multiple", "other"])
        for (query, expectedKey) in queries {
            let url = try XCTUnwrap(URL(string: "https://chat.qwen.ai/?" + query))
            let result = EmbeddedWebModelTransport.unexpectedQwenRouteDiagnostic(url)
            let fields = Dictionary(uniqueKeysWithValues: result.split(separator: " ").map { field in
                let pair = field.split(separator: "=", maxSplits: 1)
                return (String(pair[0]), String(pair[1]))
            })
            XCTAssertEqual(Set(fields.keys), ["scheme", "host", "port", "userInfo", "path", "pathEncoded", "trailingSlash", "uuid", "segments", "tokenBytes", "tokenChars", "tokenPrefix", "query", "queryKey", "fragment"])
            XCTAssertEqual(fields["queryKey"], expectedKey)
            XCTAssertTrue(allowedKeys.contains(try XCTUnwrap(fields["queryKey"])))
            XCTAssertFalse(result.contains("PRIVATE"))
            XCTAssertFalse(result.contains(String(repeating: "X", count: 128)))
            XCTAssertLessThanOrEqual(result.utf8.count, 384)
            XCTAssertFalse(EmbeddedWebModelTransport.Provider.qwen.accepts(url.absoluteString))
        }
        XCTAssertEqual(EmbeddedWebModelTransport.unexpectedQwenRouteDiagnostic(nil),
            "scheme=absent host=absent port=absent userInfo=false path=absent pathEncoded=false trailingSlash=false uuid=absent segments=0 tokenBytes=absent tokenChars=absent tokenPrefix=absent query=absent queryKey=absent fragment=false")
    }

    func testUnexpectedRouteTokenShapesStayFiniteAndNeverAdmitUnknownConversations() throws {
        let cases: [(String, [String])] = [
            ("new", ["segments=2", "tokenBytes=3", "tokenChars=ascii_alnum", "tokenPrefix=new"]),
            ("undefined", ["tokenBytes=9", "tokenPrefix=undefined"]),
            ("null", ["tokenBytes=4", "tokenPrefix=null"]),
            ("temp-PRIVATE_TOKEN", ["tokenChars=ascii_slug", "tokenPrefix=temp"]),
            ("temporary_PRIVATE_TOKEN", ["tokenPrefix=temporary"]),
            ("local:PRIVATE_TOKEN", ["tokenChars=other", "tokenPrefix=local"]),
            ("pending-PRIVATE_TOKEN", ["tokenPrefix=pending"]),
            ("00000000000000000000000000000000", ["tokenBytes=32", "tokenChars=digits", "tokenPrefix=other"]),
            ("abcdefabcdefabcdefabcdefabcdefab", ["tokenBytes=32", "tokenChars=lower_hex"]),
            ("ABCDEFABCDEFABCDEFABCDEFABCDEFAB", ["tokenBytes=32", "tokenChars=upper_hex"]),
            ("privateToken123", ["tokenChars=ascii_alnum", "tokenPrefix=other"]),
            ("private-token_123", ["tokenChars=ascii_slug", "tokenPrefix=other"]),
            ("newspaper-private", ["tokenPrefix=other"]),
            ("%C3%A9-private", ["pathEncoded=true", "tokenChars=other", "tokenPrefix=other"]),
            ("private/extra", ["segments=3plus"]),
            (String(repeating: "x", count: 4096), ["tokenBytes=over128", "tokenChars=oversized", "tokenPrefix=other"]),
        ]
        for (token, fragments) in cases {
            let url = try XCTUnwrap(URL(string: "https://chat.qwen.ai/c/" + token))
            let result = EmbeddedWebModelTransport.unexpectedQwenRouteDiagnostic(url)
            for fragment in fragments { XCTAssertTrue(result.split(separator: " ").contains(Substring(fragment)), fragment) }
            XCTAssertFalse(EmbeddedWebModelTransport.Provider.qwen.accepts(url.absoluteString),
                "Shape diagnostics must never authorize an unobserved route, including reserved-looking tokens")
            XCTAssertLessThanOrEqual(result.utf8.count, 384)
            for forbidden in ["PRIVATE_TOKEN", "privateToken123", "private-token_123", "newspaper-private", "abcdefabcdef", "ABCDEFABCDEF", String(repeating: "x", count: 128), "https://", "chat.qwen.ai"] {
                XCTAssertFalse(result.contains(forbidden), "No raw conversation token or origin is retained")
            }
        }
    }

    func testProvisionalPendingReceiptIsExactNegativeShapeAndLiteralRouteOnly() {
        let url = "https://chat.qwen.ai/c/new-chat"
        let valid: [String: Any] = ["qwenProvisionalRoutePending": true, "url": url,
            "sessionLifecycle": "saved_conversation_delete", "temporary": false]
        XCTAssertTrue(EmbeddedWebModelTransport.isQwenProvisionalRoutePendingObservation(valid, url: url))
        for (key, value) in [("qwenProvisionalRoutePending", 1 as Any), ("temporary", 0 as Any),
            ("qwenProvisionalRoutePending", false as Any), ("sessionLifecycle", "temporary" as Any),
            ("text", "" as Any), ("modelEvidence", NSNull() as Any), ("modeEvidence", NSNull() as Any),
            ("firstUserFingerprint", "" as Any), ("userCount", 0 as Any)] {
            var changed = valid; changed[key] = value
            XCTAssertFalse(EmbeddedWebModelTransport.isQwenProvisionalRoutePendingObservation(changed, url: url), key)
        }
        for other in ["https://chat.qwen.ai/", "https://chat.qwen.ai/c/new", "https://chat.qwen.ai/c/new-chat/",
            "https://chat.qwen.ai/c/new-chat?", "https://chat.qwen.ai/c/NEW-CHAT", "https://chat.qwen.ai/c/%6eew-chat",
            "https://chat.qwen.ai/c/11111111-abcd-4333-8444-555555555555"] {
            var changed = valid; changed["url"] = other
            XCTAssertFalse(EmbeddedWebModelTransport.isQwenProvisionalRoutePendingObservation(changed, url: other))
            XCTAssertFalse(EmbeddedWebModelTransport.isQwenProvisionalRoutePendingObservation(valid, url: other))
        }
    }

    func testInitialResponseIdentityReceiptIsNegativeOnlyAndCanonicalOnly() {
        assertCanonicalNegativeReceipt("qwenInitialResponseIdentityPending",
            validate: EmbeddedWebModelTransport.isQwenInitialResponseIdentityPendingObservation)
    }

    func testFirstBodyExpansionReceiptIsNegativeOnlyAndCanonicalOnly() {
        assertCanonicalNegativeReceipt("qwenFirstBodyExpansionPending",
            validate: EmbeddedWebModelTransport.isQwenFirstBodyExpansionPendingObservation)
    }

    private func assertCanonicalNegativeReceipt(_ flag: String, validate: ([String: Any], String) -> Bool) {
        let url = "https://chat.qwen.ai/c/11111111-abcd-4333-8444-555555555555"
        let valid: [String: Any] = [flag: true, "url": url,
            "sessionLifecycle": "saved_conversation_delete", "temporary": false]
        XCTAssertTrue(validate(valid, url))
        for (key, value) in [(flag, 1 as Any), ("temporary", 0 as Any),
            (flag, false as Any), ("sessionLifecycle", "temporary" as Any),
            ("text", "" as Any), ("modelEvidence", NSNull() as Any), ("answerComplete", false as Any),
            ("firstUserFingerprint", "" as Any), ("userCount", 0 as Any)] {
            var changed = valid; changed[key] = value
            XCTAssertFalse(validate(changed, url), key)
        }
        for other in ["https://chat.qwen.ai/", "https://chat.qwen.ai/c/new-chat", url + "/", url + "?", url + "#",
            url.replacingOccurrences(of: "abcd", with: "ABCD"), url.replacingOccurrences(of: "ai/", with: "ai:443/")] {
            var changed = valid; changed["url"] = other
            XCTAssertFalse(validate(changed, other))
            XCTAssertFalse(validate(valid, other))
        }
    }

    func testUnverifiedLongDisplayCannotExpandOrDeleteDuringCleanup() async throws {
        let fixture = try Fixture(setup: "qwenFixture.options.firstLongMessageDisplay=true; qwenFixture.options.holdResponseIdentity=true;")
        defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: String(repeating: "Synthetic long pending message ", count: 600))
        let pending = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1")
        _ = try await evaluate(fixture.view, "qwenFixture.revealPreview(); return true;")
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "failed")
        let clicks = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
        XCTAssertEqual(clicks, 0)
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
    }

    func testLongDisplayOnlyClicksAnExposedPartOfItsPinnedButton() async throws {
        for fullyCovered in [false, true] {
            let fixture = try Fixture(setup: "qwenFixture.options.firstLongMessageDisplay=true; qwenFixture.options.holdResponseIdentity=true;")
            defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: String(repeating: "Literal display geometry ", count: 600))
            let initial = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(initial["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1")
            let hits = try await evaluate(fixture.view, """
                qwenFixture.revealPreview(); qwenFixture.settleResponseIdentity();
                const control = document.querySelector('.chat-user-message-expand-toggle');
                control.style.cssText = 'position:fixed;left:100px;top:150px;width:120px;height:32px;margin:0;z-index:3';
                const cover = document.createElement('a');
                cover.href = '#other';
                cover.style.cssText = 'position:fixed;top:150px;height:32px;z-index:4;left:\(fullyCovered ? 100 : 140)px;width:\(fullyCovered ? 120 : 40)px';
                document.body.append(cover);
                return [document.elementFromPoint(160,166) === cover, document.elementFromPoint(115,166) === control];
                """) as? [Bool]
            XCTAssertEqual(hits, [true, !fullyCovered])
            let pair = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pair["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1")
            let beforeClick = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
            XCTAssertEqual(beforeClick, 0)

            if fullyCovered {
                do {
                    _ = try await wait(fixture, token, state: "complete")
                    XCTFail("A covering link cannot authorize expansion")
                } catch {
                    XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser))
                }
            } else {
                let pending = try await call(fixture, "webProviderPoll", token)
                XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1")
                let context = try XCTUnwrap(pending["pendingSubmissionContext"] as? [String: Any])
                XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
            }
            let clicks = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
            XCTAssertEqual(clicks, fullyCovered ? 0 : 1)
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        }
    }

    func testExpandCanUseTheSmallPartOfThePinnedButtonInsideAnOverflowClip() async throws {
        let fixture = try Fixture(setup: "qwenFixture.options.firstLongMessageDisplay=true; qwenFixture.options.holdResponseIdentity=true;")
        defer { fixture.shutdown() }
        let token = try await start(fixture, label: "Qwen3.7-Plus")
        _ = try await call(fixture, "webProviderSend", token, prompt: String(repeating: "Literal clipped fixture ", count: 610))
        _ = try await call(fixture, "webProviderPoll", token)
        let initial = try await evaluate(fixture.view, """
            qwenFixture.revealPreview(); qwenFixture.settleResponseIdentity();
            const button = document.querySelector('.chat-user-message-expand-toggle');
            button.parentElement.style.cssText = 'position:fixed;left:100px;top:150px;width:40px;height:50px;overflow:clip;z-index:3';
            button.style.cssText = 'position:absolute;left:38px;top:10px;width:160px;height:32px;margin:0';
            return [button.contains(document.elementFromPoint(139,176)), button.contains(document.elementFromPoint(158,176))];
            """) as? [Bool]
        XCTAssertEqual(initial, [true, false])
        let pair = try await call(fixture, "webProviderPoll", token)
        XCTAssertEqual(pair["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1")
        XCTAssertNil(pair["modelProofContext"])
        _ = try await call(fixture, "webProviderPoll", token)
        let clicks = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
        XCTAssertEqual(clicks, 1)
        try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        _ = try await evaluate(fixture.view, "qwenFixture.completeResponse(); return true;")
        let complete = try await wait(fixture, token, state: "complete")
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic Qwen native reply"}"#)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
    }

    func testLongDisplayScrollRevealsClippedOrCoveredControlWithoutCrossingPersistentOverlay() async throws {
        for layout in ["overflow", "fixedHeader", "renderReveal", "renderReplacement", "fullCover"] {
            let deferred = ["renderReveal", "renderReplacement", "fullCover"].contains(layout)
            let fixture = try Fixture(setup: "qwenFixture.options.firstLongMessageDisplay=true; qwenFixture.options.holdResponseIdentity=true;")
            defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: String(repeating: "Literal scroll fixture ", count: 620))
            let initial = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(initial["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1")
            let blocked = try await evaluate(fixture.view, """
                qwenFixture.revealPreview(); qwenFixture.settleResponseIdentity();
                const area = document.querySelector('#transcript'), control = area.querySelector('.chat-user-message-expand-toggle');
                area.style.cssText = 'position:fixed;top:80px;left:32px;width:440px;height:180px;overflow:auto;scroll-behavior:smooth';
                control.parentElement.style.cssText = 'padding-top:220px;padding-bottom:300px';
                if ('\(layout)' !== 'overflow') {
                  area.scrollTo({top:control.getBoundingClientRect().top-area.getBoundingClientRect().top-8,behavior:'instant'});
                  const cover = document.createElement('a');
                  cover.href = '#foreign';
                  cover.style.cssText = 'position:fixed;left:32px;top:80px;width:440px;height:\(deferred ? 180 : 64)px;z-index:5';
                  document.body.append(cover);
                  if (['renderReveal','renderReplacement'].includes('\(layout)')) {
                    window.qwenReleaseCover = () => {
                      if (area.scrollTop === window.qwenPriorScroll) return false;
                      if ('\(layout)' === 'renderReplacement') control.replaceWith(control.cloneNode(true));
                      cover.remove();
                      return true;
                    };
                  }
                }
                const box = control.getBoundingClientRect();
                const points=[.125,.5,.875];
                const covered=points.every(u=>points.every(v=>!control.contains(document.elementFromPoint(box.left+box.width*u,box.top+box.height*v))));
                const port=area.getBoundingClientRect();
                window.qwenPriorScroll = area.scrollTop;
                return [covered, area.scrollHeight>area.clientHeight, box.top>=0 && box.bottom<=innerHeight,
                  '\(layout)' === 'overflow' ? box.top>port.bottom : box.top>=port.top && box.bottom<port.top+64];
                """) as? [Bool]
            XCTAssertEqual(blocked, [true,true,true,true], layout)
            let pair = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pair["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1")
            let beforeClick = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
            XCTAssertEqual(beforeClick, 0)

            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1", layout)
            let provisional = try XCTUnwrap(pending["pendingSubmissionContext"] as? [String: Any])
            XCTAssertEqual(provisional["firstUserFingerprint"] as? String, "", layout)
            if deferred {
                let initialClicks = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
                XCTAssertEqual(initialClicks, 0, layout)
                if layout != "fullCover" {
                    // A separate site update removes the verified blocker after the negative
                    // receipt. A hidden model tab may never deliver requestAnimationFrame.
                    let removed = try await evaluate(fixture.view, "return window.qwenReleaseCover();") as? Bool
                    XCTAssertEqual(removed, true, layout)
                }
            }
            let refused = ["renderReplacement", "fullCover"].contains(layout)
            if refused {
                do {
                    _ = try await wait(fixture, token, state: "complete")
                    XCTFail("Persistent cover or a replaced button cannot authorize a click")
                } catch {
                    XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser))
                }
            } else if layout == "renderReveal" {
                let deadline = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < deadline {
                    let revision = try await fixture.transport.changeRevision(sessionToken: token)
                    _ = try await call(fixture, "webProviderPoll", token)
                    let clicks = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
                    if clicks == 1 { break }
                    _ = try await fixture.transport.waitForChange(sessionToken: token, after: try XCTUnwrap(revision), until: deadline)
                }
            }
            let result = try await evaluate(fixture.view, """
                return [document.querySelector('#transcript').scrollTop !== window.qwenPriorScroll,
                  qwenFixture.counts.displayClicks === \(refused ? 0 : 1), !location.hash];
                """) as? [Bool]
            XCTAssertEqual(result, [true,true,true], layout)
            if layout == "renderReveal" {
                _ = try await evaluate(fixture.view, "qwenFixture.settleResponseIdentity(); qwenFixture.completeResponse(); return true;")
                let complete = try await wait(fixture, token, state: "complete")
                let proof = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
                XCTAssertEqual((proof["firstUserFingerprint"] as? String)?.count, 64)
                XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic Qwen native reply"}"#)
                let finished = try await call(fixture, "webProviderFinish", token)
                XCTAssertEqual(finished["cleanup"] as? String, "deleted")
                try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
            } else {
                try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
            }
        }
    }

    func testLongFirstDisplayRequiresOneLocalClickThenFullBodyAndSelectedModelForBothModels() async throws {
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let fixture = try Fixture(setup: "qwenFixture.options.firstLongMessageDisplay=true; qwenFixture.options.holdResponseIdentity=true;")
            defer { fixture.shutdown() }
            let token = try await start(fixture, label: label)
            let prompt = String(repeating: "Literal Qwen disclosure fixture 👋 日本語\n", count: 600)
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            let display = "qwen_first_body_expansion_v1"
            let steps: [(String, Int)] = [
                ("return true;", 0), ("qwenFixture.revealPreview(); return true;", 0),
                ("""
                 document.querySelector('.chat-user-message-container').setAttribute('data-msg-id','494d93fb-ad37-43ab-868d-5dade1cdc4b1');
                 qwenFixture.settleResponseIdentity(); return true;
                 """, 0),
                ("return true;", 1)
            ]
            for (stage, clicks) in steps {
                _ = try await evaluate(fixture.view, stage)
                let pending = try await call(fixture, "webProviderPoll", token)
                XCTAssertEqual(pending["state"] as? String, "running")
                XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, display, label)
                XCTAssertEqual(pending["text"] as? String, "")
                XCTAssertNil(pending["modelEvidence"])
                XCTAssertNil(pending["modelProofContext"])
                XCTAssertNil(pending["completionEvidence"])
                let context = try XCTUnwrap(pending["pendingSubmissionContext"] as? [String: Any])
                XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
                let observed = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
                XCTAssertEqual(observed, clicks)
            }
            let settled = try await call(fixture, "webProviderPoll", token)
            XCTAssertNil(settled["modelVerificationPending"])
            let context = try XCTUnwrap(settled["modelProofContext"] as? [String: Any])
            XCTAssertEqual((context["firstUserFingerprint"] as? String)?.count, 64)
            _ = try await evaluate(fixture.view, "qwenFixture.completeResponse(); return true;")
            let complete = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic Qwen native reply"}"#)
            let choice = WebsiteModelChoice(provider: "qwen", key: label, label: label)
            _ = try WebsiteModelEvidence.parse(complete["modelEvidence"], provider: "qwen", expected: choice)
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            let clicks = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
            XCTAssertEqual(clicks, 1)
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        }
    }

    func testBothModelsRefuseChangedUserOrAnswerAfterFirstSettledPairWithoutExpandingOrDeleting() async throws {
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            for field in ["user", "answer"] {
                let fixture = try Fixture(setup: "qwenFixture.options.firstLongMessageDisplay=true; qwenFixture.options.holdResponseIdentity=true;")
                defer { fixture.shutdown() }
                let token = try await start(fixture, label: label)
                _ = try await call(fixture, "webProviderSend", token, prompt: String(repeating: "Synthetic settled pair ", count: 750))
                for step in ["qwenFixture.revealPreview(); return true;", "qwenFixture.settleResponseIdentity(); return true;"] {
                    _ = try await evaluate(fixture.view, step)
                    let pending = try await call(fixture, "webProviderPoll", token)
                    XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, "qwen_first_body_expansion_v1", label)
                    XCTAssertNil(pending["modelEvidence"])
                    XCTAssertNil(pending["modelProofContext"])
                    XCTAssertEqual(pending["text"] as? String, "")
                }
                let change = field == "user"
                    ? "document.querySelector('.chat-user-message-container').setAttribute('data-msg-id','494d93fb-ad37-43ab-868d-5dade1cdc4b1')"
                    : "document.querySelector('.chat-response-message').id='chat-response-message-494d93fb-ad37-43ab-868d-5dade1cdc4b1'"
                _ = try await evaluate(fixture.view, change + "; return true;")
                do {
                    _ = try await call(fixture, "webProviderPoll", token)
                    XCTFail("\(label) must refuse a changed settled \(field) identity")
                } catch {
                    XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptFirstUser))
                }
                let finished = try await call(fixture, "webProviderFinish", token)
                XCTAssertEqual(finished["cleanup"] as? String, "failed")
                let clicks = try await evaluate(fixture.view, "return qwenFixture.counts.displayClicks;") as? Int
                XCTAssertEqual(clicks, 0)
                try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
            }
        }
    }

    func testInitialEmptyResponseIDWaitsWithoutProofAndIDOnlyMutationWakesStrictReadForBothModels() async throws {
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let fixture = try Fixture(setup: "qwenFixture.options.holdResponseIdentity=true")
            defer { fixture.shutdown() }
            let token = try await start(fixture, label: label)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic exact empty response ID fixture")
            for _ in 0..<2 {
                let pending = try await call(fixture, "webProviderPoll", token)
                XCTAssertEqual(pending["state"] as? String, "running"); XCTAssertEqual(pending["text"] as? String, "")
                XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, "qwen_initial_response_identity_v1")
                XCTAssertNil(pending["modelEvidence"]); XCTAssertNil(pending["modelProofContext"])
                XCTAssertNil(pending["completionEvidence"])
                let context = try XCTUnwrap(pending["pendingSubmissionContext"] as? [String: Any])
                XCTAssertEqual(context["firstUserFingerprint"] as? String, ""); XCTAssertEqual(context["responseCount"] as? Int, 0)
            }
            let revision = try await fixture.transport.changeRevision(sessionToken: token)
            _ = try await evaluate(fixture.view, "qwenFixture.settleResponseIdentity(); return true;")
            let changed = try await fixture.transport.waitForChange(sessionToken: token,
                after: try XCTUnwrap(revision), until: .now + .seconds(2))
            XCTAssertNotNil(changed, "An ID-only mutation must wake the existing observer")
            let settled = try await call(fixture, "webProviderPoll", token)
            XCTAssertNil(settled["modelVerificationPending"]); XCTAssertEqual(settled["text"] as? String, "")
            XCTAssertEqual(settled["state"] as? String, "running")
            let context = try XCTUnwrap(settled["modelProofContext"] as? [String: Any])
            XCTAssertEqual((context["firstUserFingerprint"] as? String)?.count, 64)
            _ = try await evaluate(fixture.view, "qwenFixture.completeResponse(); return true;")
            let complete = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic Qwen native reply"}"#)
            XCTAssertNil(complete["modelVerificationPending"])
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        }
    }

    func testMaxFirstAssistantRootWaitsForContainerAndRejectsReplacementAndDuplicates() async throws {
        for scenario in ["mount", "duplicate", "removeMounted", "replaceRoot"] {
            let fixture = try Fixture(setup: "qwenFixture.options.holdResponseIdentity=true; qwenFixture.options.holdResponseContainer=true;")
            defer { fixture.shutdown() }
            let token = try await start(fixture, label: "Qwen3.8-Max")
            _ = try await call(fixture, "webProviderSend", token, prompt: "Identify this synthetic code.")
            let initial = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(initial["modelVerificationPendingReason"] as? String, "qwen_initial_response_identity_v1", scenario)
            XCTAssertNil(initial["modelEvidence"])
            XCTAssertNil(initial["completionEvidence"])
            let ctx = try XCTUnwrap(initial["pendingSubmissionContext"] as? [String: Any])
            XCTAssertEqual(ctx["firstUserFingerprint"] as? String, "")
            XCTAssertEqual(ctx["responseCount"] as? Int, 0)
            let mutation = scenario == "replaceRoot"
                ? "const old=document.querySelector('.qwen-chat-message-assistant'); old.replaceWith(old.cloneNode(false));"
                : "qwenFixture.mountResponseContainer();"
            _ = try await evaluate(fixture.view, mutation + " return true;")
            if scenario == "mount" || scenario == "removeMounted" {
                let pending = try await call(fixture, "webProviderPoll", token)
                XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, "qwen_initial_response_identity_v1")
                XCTAssertNil(pending["completionEvidence"])
            }
            if scenario == "mount" {
                _ = try await evaluate(fixture.view, "qwenFixture.settleResponseIdentity(); qwenFixture.completeResponse(); return true;")
                let complete = try await wait(fixture, token, state: "complete")
                XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic Qwen native reply"}"#)
                let finished = try await call(fixture, "webProviderFinish", token)
                XCTAssertEqual(finished["cleanup"] as? String, "deleted")
                try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
                continue
            }
            if scenario == "duplicate" {
                _ = try await evaluate(fixture.view, "const a=document.querySelector('.chat-response-message'); a.after(a.cloneNode(true)); return true;")
            } else if scenario == "removeMounted" {
                _ = try await evaluate(fixture.view, "document.querySelector('.chat-response-message').remove(); return true;")
            }
            do {
                _ = try await call(fixture, "webProviderPoll", token)
                XCTFail("Poll must refuse " + scenario)
            } catch {
                let reason: EmbeddedWebModelTransport.OwnershipReason = scenario == "replaceRoot" ? .javaScriptConversation : .javaScriptDocument
                XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(reason), scenario)
            }
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "failed")
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
        }
    }

    func testObservedPlaceholderWithholdsModelAndAnswerUntilExactCanonicalBodyForBothModels() async throws {
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let fixture = try Fixture(setup: "qwenFixture.options.useProvisional=true; qwenFixture.options.holdProvisional=true")
            defer { fixture.shutdown() }
            let token = try await start(fixture, label: label)
            let prompt = String(repeating: "Synthetic exact Qwen café 👋 'quote' <tag>\n", count: 1_500)
            _ = try await call(fixture, "webProviderSend", token, prompt: prompt)
            let before = try await evaluate(fixture.view,
                "return [qwenFixture.counts.modelOpens,qwenFixture.counts.modelSelections,qwenFixture.counts.input,qwenFixture.counts.sends];") as? [Int]
            for _ in 0..<2 {
                let pending = try await call(fixture, "webProviderPoll", token)
                XCTAssertEqual(pending["state"] as? String, "running"); XCTAssertEqual(pending["text"] as? String, "")
                XCTAssertEqual(pending["modelVerificationPending"] as? Bool, true)
                XCTAssertEqual(pending["modelVerificationPendingReason"] as? String, "qwen_initial_provisional_route_v1")
                XCTAssertNil(pending["modelEvidence"]); XCTAssertNil(pending["modeEvidence"])
                XCTAssertNil(pending["modelProofContext"]); XCTAssertNil(pending["completionEvidence"])
                let context = try XCTUnwrap(pending["pendingSubmissionContext"] as? [String: Any])
                XCTAssertEqual(context["firstUserFingerprint"] as? String, "")
                XCTAssertEqual(context["responseCount"] as? Int, 0)
            }
            let revision = try await fixture.transport.changeRevision(sessionToken: token)
            _ = try await evaluate(fixture.view, "qwenFixture.canonicalize(); return true;")
            let changed = try await fixture.transport.waitForChange(sessionToken: token,
                after: try XCTUnwrap(revision), until: .now + .seconds(2))
            XCTAssertNotNil(changed)
            let complete = try await wait(fixture, token, state: "complete")
            XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic Qwen native reply"}"#)
            XCTAssertNil(complete["modelVerificationPending"])
            let choice = WebsiteModelChoice(provider: "qwen", key: label, label: label)
            let proof = try WebsiteModelEvidence.parse(complete["modelEvidence"], provider: "qwen", expected: choice)
            XCTAssertEqual(proof.selected.key, label); XCTAssertEqual(proof.selected.label, label)
            let echoValue = try await evaluate(fixture.view, "return document.querySelector('p.user-message-content').textContent;")
            let echo = try XCTUnwrap(echoValue as? String)
            let prefix = prompt + "\n\nComputa session marker: "
            XCTAssertTrue(echo.hasPrefix(prefix)); XCTAssertNotNil(UUID(uuidString: String(echo.dropFirst(prefix.count))))
            let after = try await evaluate(fixture.view,
                "return [qwenFixture.counts.modelOpens,qwenFixture.counts.modelSelections,qwenFixture.counts.input,qwenFixture.counts.sends];") as? [Int]
            XCTAssertEqual(after, before, "Read-only pending/canonical proof must not reopen selection or replay input")
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "deleted")
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        }
    }

    func testServerReleasesHeldPlaceholderOnlyAfterCanonicalProofAndDurableDeletion() async throws {
        for label in ["Qwen3.7-Plus", "Qwen3.8-Max"] {
            let fixture = try Fixture(setup: "qwenFixture.options.useProvisional=true; qwenFixture.options.holdProvisional=true")
            defer { fixture.shutdown() }
            var observedPending = 0
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect",
                   (try? await self.evaluate(fixture.view, "return location.pathname === '/c/new-chat';")) as? Bool == true {
                    observedPending += 1
                    if observedPending == 1 {
                        _ = try? await self.evaluate(fixture.view, "setTimeout(()=>qwenFixture.canonicalize(),100); return true;")
                    }
                }
            }
            let choice = WebsiteModelChoice(provider: "qwen", key: label, label: label)
            try await assertSavedProviderServerStream(transport: fixture.transport, provider: .qwen,
                modelID: choice.modelID, selection: .model(choice), expectedText: "Synthetic Qwen native reply")
            XCTAssertGreaterThanOrEqual(observedPending, 1)
            try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
        }
    }

    func testProvisionalInspectCrossingToCanonicalDiscardsOldReceiptAndVerifiesFullBodyOnce() async throws {
        let fixture = try Fixture(setup: "qwenFixture.options.useProvisional=true; qwenFixture.options.holdProvisional=true")
        defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic route crossing during the pending callback")
        var crossed = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !crossed {
                crossed = true
                _ = try? await self.evaluate(fixture.view, "qwenFixture.canonicalize(); return true;")
            }
        }
        let complete = try await wait(fixture, token, state: "complete")
        XCTAssertTrue(crossed)
        XCTAssertNil(complete["modelVerificationPending"])
        XCTAssertEqual(complete["text"] as? String, #"{"type":"message","text":"Synthetic Qwen native reply"}"#)
        let context = try XCTUnwrap(complete["modelProofContext"] as? [String: Any])
        XCTAssertEqual((context["firstUserFingerprint"] as? String)?.count, 64)
        XCTAssertEqual(context["responseCount"] as? Int, 1)
        let finished = try await call(fixture, "webProviderFinish", token)
        XCTAssertEqual(finished["cleanup"] as? String, "deleted")
        try await assertCounts(fixture, sends: 1, headers: 1, selections: 1, confirmations: 1)
    }

    func testObservedPlaceholderCannotStartDiscoveryOrPreSendPreparation() async throws {
        let discovery = try Fixture(setup: "history.replaceState({},'', '/c/new-chat')")
        defer { discovery.shutdown() }
        discovery.transport.setTimeoutsForTesting(preparation: .seconds(2), response: .seconds(2))
        do {
            _ = try await discovery.transport.discoverModels(provider: "qwen")
            XCTFail("A recognized placeholder is never an unbound fresh page")
        } catch { XCTAssertNotNil(error as? EmbeddedWebModelTransport.Failure) }
        try await assertCounts(discovery, sends: 0, headers: 0, selections: 0, confirmations: 0)
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let token = try await start(fixture)
        _ = try await evaluate(fixture.view, "history.replaceState({},'', '/c/new-chat'); return true;")
        do {
            _ = try await call(fixture, "webProviderSend", token, prompt: "Must not submit from an unowned placeholder")
            XCTFail("Pre-Send drift to a placeholder cannot gain submission authority")
        } catch { XCTAssertNotNil(error as? EmbeddedWebModelTransport.Failure) }
        let inputCount = try await evaluate(fixture.view, "return qwenFixture.counts.input;") as? Int
        XCTAssertEqual(inputCount, 0)
        try await assertCounts(fixture, sends: 0, headers: 0, selections: 0, confirmations: 0)
    }

    func testHeldPlaceholderCannotRenewDeadlineAcceptUnknownRouteOrBacktrack() async throws {
        for kind in ["deadline", "unknown", "backtrack", "model-changed"] {
            let fixture = try Fixture(setup: "qwenFixture.options.useProvisional=true; qwenFixture.options.holdProvisional=true")
            defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic held provisional route")
            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["modelVerificationPending"] as? Bool, true)
            if kind == "deadline" { fixture.transport.setTimeoutsForTesting(preparation: .seconds(10), response: .milliseconds(1)) }
            else if kind == "model-changed" {
                _ = try await evaluate(fixture.view,
                    "document.querySelector('.wms-trigger__text').textContent='Qwen3.7-Plus'; qwenFixture.canonicalize(); return true;")
            } else {
                _ = try await evaluate(fixture.view,
                    "history.replaceState({},'', '\(kind == "unknown" ? "/c/unknown-private" : "/")'); return true;")
            }
            do {
                _ = try await call(fixture, "webProviderPoll", token)
                XCTFail("A held placeholder must not survive \(kind)")
            } catch let failure as EmbeddedWebModelTransport.Failure {
                if kind == "deadline" { XCTAssertEqual(failure, .deadline) }
                else if kind == "unknown" { XCTAssertEqual(failure, .unexpectedPage(.qwen)) }
                else if kind == "model-changed" { XCTAssertEqual(failure, .modelUnverified) }
                else { XCTAssertEqual(failure, .ownershipFailure(.routeBefore)) }
            }
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
            let inputs = try await evaluate(fixture.view, "return qwenFixture.counts.input;") as? Int
            XCTAssertEqual(inputs, 1)
        }
    }

    func testDocumentReplacementCannotInheritHeldPlaceholderAndCancellationCannotReplay() async throws {
        for replaceDocument in [false, true] {
            let fixture = try Fixture(setup: "qwenFixture.options.useProvisional=true; qwenFixture.options.holdProvisional=true")
            defer { fixture.shutdown() }
            let token = try await start(fixture)
            _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic held page cancellation")
            let pending = try await call(fixture, "webProviderPoll", token)
            XCTAssertEqual(pending["modelVerificationPending"] as? Bool, true)
            try await assertCounts(fixture, sends: 1, headers: 0, selections: 0, confirmations: 0)
            if replaceDocument {
                let createdID = try XCTUnwrap(fixture.createdID)
                let oldGeneration = fixture.browser.documentGeneration(for: createdID)
                fixture.view.loadHTMLString(QwenFixturePage.html, baseURL: URL(string: "https://chat.qwen.ai/c/new-chat"))
                let deadline = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < deadline,
                      fixture.view.isLoading || fixture.browser.documentGeneration(for: createdID) == oldGeneration {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertNotEqual(fixture.browser.documentGeneration(for: createdID), oldGeneration)
                do {
                    _ = try await call(fixture, "webProviderPoll", token)
                    XCTFail("A new document cannot inherit the submitted lease")
                } catch let failure as EmbeddedWebModelTransport.Failure {
                    XCTAssertEqual(failure, .ownershipFailure(.documentGenerationBefore))
                }
            }
            let finished = try await call(fixture, "webProviderFinish", token)
            XCTAssertEqual(finished["cleanup"] as? String, "failed", "A provisional route cannot authorize deletion")
            let cancelled = try await call(fixture, "webProviderCancel", token)
            XCTAssertEqual(cancelled["cleanup"] as? String, "failed", "No canonical body exists to authorize deletion")
            do {
                _ = try await call(fixture, "webProviderSend", token, prompt: "Synthetic held page cancellation")
                XCTFail("Cancellation must not make the Send claim reusable")
            } catch { }
            try await assertCounts(fixture, sends: replaceDocument ? 0 : 1, headers: 0, selections: 0, confirmations: 0)
            XCTAssertNotNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        }
    }

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

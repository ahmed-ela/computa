import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

/// Exercises the real browser change notification path; no live site/network.
@MainActor
final class SavedProviderInitialHydrationTests: XCTestCase {
    func testLateControlsAndAttributeOnlyHydrationWakeBothSavedProvidersWithoutActions() async throws {
        for provider in ["qwen", "deepseek"] {
            for attributesOnly in [false, true] {
                let setup: String
                if attributesOnly {
                    setup = provider == "qwen" ? """
                        const control=document.querySelector('.wms-trigger'); control.removeAttribute('role');
                        window.restoreFixture=()=>control.setAttribute('role','button');
                        """ : """
                        const control=document.querySelector('textarea'); control.removeAttribute('placeholder');
                        window.restoreFixture=()=>control.setAttribute('placeholder','Message DeepSeek');
                        """
                } else {
                    setup = """
                        const controls=[...document.body.children].filter(n=>n.tagName!=='SCRIPT');
                        controls.forEach(n=>n.remove()); window.restoreFixture=()=>controls.forEach(n=>document.body.append(n));
                        """
                }
                let fixture = try Fixture(provider: provider, setup: setup); defer { fixture.shutdown() }
                var observedPending = false
                fixture.transport.setBeforePageResultValidationForTesting { action in
                    if action == "inspect", !observedPending {
                        observedPending = true
                        let before = try? await self.counts(fixture, provider: provider)
                        XCTAssertEqual(before, [0,0,0])
                        _ = try? await self.evaluate(fixture.view, "setTimeout(restoreFixture,100); return true;")
                    }
                }
                let choices = try await discover(fixture, provider: provider)
                XCTAssertTrue(observedPending)
                XCTAssertEqual(choices, provider == "qwen" ? ["Qwen3.7-Plus","Qwen3.8-Max"] : ["chat","deepthink"])
                let after = try await counts(fixture, provider: provider)
                XCTAssertEqual(after, [0,0,0])
                XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
            }
        }
    }

    func testQwenDelayedOverlayWaitsForDOMChangeBeforeItsFirstVerifiedPickerClick() async throws {
        let fixture = try Fixture(provider: "qwen", setup: Self.qwenInitialOverlay); defer { fixture.shutdown() }
        var observedBlockedRead = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !observedBlockedRead {
                observedBlockedRead = true
                let opens = try? await self.evaluate(fixture.view, "return qwenFixture.counts.modelOpens;")
                XCTAssertEqual(opens as? Int, 0)
                let blocked = try? await self.evaluate(fixture.view, """
                    const t=document.querySelector('.wms-trigger'),r=t.getBoundingClientRect();
                    return document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)===document.getElementById('fixture-overlay');
                    """)
                XCTAssertEqual(blocked as? Bool, true)
                _ = try? await self.evaluate(fixture.view, "setTimeout(()=>document.getElementById('fixture-overlay').remove(),100); return true;")
            }
        }
        let choices = try await discover(fixture, provider: "qwen")
        XCTAssertTrue(observedBlockedRead)
        XCTAssertEqual(choices, ["Qwen3.7-Plus", "Qwen3.8-Max"])
        let after = try await counts(fixture, provider: "qwen")
        XCTAssertEqual(after, [0,0,0])
        let opens = try await evaluate(fixture.view, "return qwenFixture.counts.modelOpens;")
        XCTAssertEqual(opens as? Int, 1, "Discovery opens the picker only after the same retained target passes its hit test")
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    func testQwenRetainedPickerReplacementDuringOcclusionFailsBeforeAnyClick() async throws {
        let fixture = try Fixture(provider: "qwen", setup: Self.qwenInitialOverlay); defer { fixture.shutdown() }
        var replaced = false
        fixture.transport.setBeforePageResultValidationForTesting { action in
            if action == "inspect", !replaced {
                replaced = true
                let opens = try? await self.evaluate(fixture.view, "return qwenFixture.counts.modelOpens;")
                XCTAssertEqual(opens as? Int, 0)
                _ = try? await self.evaluate(fixture.view, """
                    setTimeout(()=>{const t=document.querySelector('.wms-trigger');t.replaceWith(t.cloneNode(true));
                    document.getElementById('fixture-overlay').remove();},100);return true;
                    """)
            }
        }
        do { _ = try await discover(fixture, provider: "qwen"); XCTFail("A replacement cannot inherit the blocked target's readiness") }
        catch {
            XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .ownershipFailure(.javaScriptDocument))
        }
        XCTAssertTrue(replaced)
        let after = try await counts(fixture, provider: "qwen")
        XCTAssertEqual(after, [0,0,0])
        let opens = try await evaluate(fixture.view, "return qwenFixture.counts.modelOpens;")
        XCTAssertEqual(opens as? Int, 0)
    }

    func testQwenPermanentOverlayReachesOriginalPreparationDeadlineWithoutInput() async throws {
        let fixture = try Fixture(provider: "qwen", setup: Self.qwenInitialOverlay); defer { fixture.shutdown() }
        do { _ = try await discover(fixture, provider: "qwen"); XCTFail("An occluded target must never become ready") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .preparationDeadline) }
        let after = try await counts(fixture, provider: "qwen")
        XCTAssertEqual(after, [0,0,0])
        let opens = try await evaluate(fixture.view, "return qwenFixture.counts.modelOpens;")
        XCTAssertEqual(opens as? Int, 0)
        XCTAssertNil(fixture.browser.webView(for: try XCTUnwrap(fixture.createdID)))
        XCTAssertNotNil(fixture.browser.webView(for: fixture.humanID))
    }

    private static let qwenInitialOverlay = """
        const overlay=document.createElement('div');overlay.id='fixture-overlay';
        overlay.style.cssText='position:fixed;inset:0;z-index:2147483647;pointer-events:auto;background:white';
        document.body.append(overlay);
        """

    func testDuplicatePresentControlsAreRejectedWithoutHydrationOrInput() async throws {
        for provider in ["qwen", "deepseek"] {
            let fixture = try Fixture(provider: provider, setup: "const e=document.querySelector('textarea'); e.after(e.cloneNode(true));")
            defer { fixture.shutdown() }
            do { _ = try await discover(fixture, provider: provider); XCTFail("Duplicate controls must be terminal") }
            catch { }
            let after = try await counts(fixture, provider: provider)
            XCTAssertEqual(after, [0,0,0])
        }
    }

    func testASeenControlCannotBeReplacedAcrossPendingReads() async throws {
        for provider in ["qwen", "deepseek"] {
            // Leave the editor mounted so it is pinned, while a different
            // required control is absent from this initial empty root.
            let selector = provider == "qwen" ? ".wms-trigger" : ".ds-button--circle"
            let fixture = try Fixture(provider: provider, setup: "window.pendingControl=document.querySelector('\(selector)'); window.pendingParent=pendingControl.parentNode; window.pendingNext=pendingControl.nextSibling; pendingControl.remove();")
            defer { fixture.shutdown() }
            var changed = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect", !changed {
                    changed = true
                    _ = try? await self.evaluate(fixture.view, """
                        setTimeout(()=>{const e=document.querySelector('textarea'); e.replaceWith(e.cloneNode(true));
                        pendingParent.insertBefore(pendingControl,pendingNext);},100); return true;
                        """)
                }
            }
            do { _ = try await discover(fixture, provider: provider); XCTFail("A replaced pinned editor cannot hydrate") }
            catch { }
            XCTAssertTrue(changed)
            let after = try await counts(fixture, provider: provider)
            XCTAssertEqual(after, [0,0,0])
        }
    }

    func testChangedNativeRouteDuringPendingCallbackCannotAcquireDocumentAuthority() async throws {
        for provider in ["qwen", "deepseek"] {
            let fixture = try Fixture(provider: provider, setup: "document.querySelector('textarea').remove();")
            defer { fixture.shutdown() }
            var changed = false
            fixture.transport.setBeforePageResultValidationForTesting { action in
                if action == "inspect", !changed {
                    changed = true
                    let path = provider == "qwen" ? "/c/11111111-abcd-4333-8444-555555555555" : "/a/chat/s/11111111-abcd-4333-8444-555555555555"
                    _ = try? await self.evaluate(fixture.view, "history.replaceState({},'', '\(path)'); return true;")
                }
            }
            do { _ = try await discover(fixture, provider: provider); XCTFail("Changed native binding must be terminal") }
            catch { }
            XCTAssertTrue(changed)
            let after = try await counts(fixture, provider: provider)
            XCTAssertEqual(after, [0,0,0])
        }
    }

    func testMissingControlsAfterReadyCannotReenterInitialWait() async throws {
        for provider in ["qwen", "deepseek"] {
            let fixture = try Fixture(provider: provider); defer { fixture.shutdown() }
            let parameters: [String: String]
            if provider == "qwen" {
                let choice=WebsiteModelChoice(provider: provider,key:"Qwen3.8-Max",label:"Qwen3.8-Max")
                parameters=["provider":provider,"modelChoice":try XCTUnwrap(choice.canonicalJSONString)]
            } else { parameters=["provider":provider,"modeChoice":WebsiteModeChoice(deepSeekMode:.chat).canonicalJSONString] }
            let initial = try await fixture.transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: parameters))
            let token = try XCTUnwrap((JSONSerialization.jsonObject(with: initial) as? [String:Any])?["sessionToken"] as? String)
            let deadline=ContinuousClock.now + .seconds(3)
            var ready=false
            while ContinuousClock.now < deadline {
                let revision=try await fixture.transport.changeRevision(sessionToken:token)
                let bytes=try await fixture.transport.request(operation:"webProviderPoll",params:JSONSerialization.data(withJSONObject:["sessionToken":token]))
                if (try JSONSerialization.jsonObject(with:bytes) as? [String:Any])?["state"] as? String == "ready" {ready=true;break}
                _ = try await fixture.transport.waitForChange(sessionToken:token,after:try XCTUnwrap(revision),until:deadline)
            }
            XCTAssertTrue(ready)
            _ = try await evaluate(fixture.view,"document.querySelector('textarea').remove(); return true;")
            do {
                _ = try await fixture.transport.request(operation:"webProviderSend",params:JSONSerialization.data(withJSONObject:["sessionToken":token,"prompt":"Synthetic missing claimed editor"]))
                XCTFail("Bound controls cannot fall back to initial hydration")
            } catch { }
            let after=try await counts(fixture,provider:provider)
            XCTAssertEqual(Array(after.prefix(2)), [0,0])
        }
    }

    private func discover(_ fixture: Fixture, provider: String) async throws -> Set<String> {
        if provider == "deepseek" { return Set(try await fixture.transport.discoverModes(provider:provider).map(\.key)) }
        return Set(try await fixture.transport.discoverModels(provider:provider).map(\.key))
    }
    private func counts(_ fixture: Fixture, provider: String) async throws -> [Int] {
        let script=provider == "qwen"
            ? "return [qwenFixture.counts.input,qwenFixture.counts.sends,qwenFixture.counts.modelSelections];"
            : "return [deepseekFixture.counters.inputs,deepseekFixture.counters.sends,deepseekFixture.counters.deepThinkClicks];"
        let value = try await evaluate(fixture.view, script)
        return try XCTUnwrap(value as? [Int])
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
        init(provider: String, setup: String = "") throws {
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
                let source = provider == "qwen" ? QwenFixturePage.html : DeepSeekFixturePage.html
                let html = source + "<script>" + setup + "</script>"
                view.loadHTMLString(html, baseURL: url)
                return id
            })
            transport.setTimeoutsForTesting(preparation: .seconds(3), response: .seconds(5))
        }
        func shutdown() {
            browser.shutdown(); host.detach(); window.orderOut(nil); window.close()
        }
    }
}

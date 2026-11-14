import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class ClaudeResponseStreamBrowserTests: XCTestCase {
    func testCreationUsesOneOrdinaryNavigationAndUnavailableDiagnosticDoesNotReplay() async throws {
        for revoked in [false, true] {
            let arm = try ClaudeResponseStreamLeaseFixture(); defer { arm.cleanup() }
            let lease = try XCTUnwrap(arm.lease())
            if revoked { lease.revoke() }
            let browser = EmbeddedBrowserSession(persistent: false); defer { browser.shutdown() }
            let human = try browser.createTab()
            var created: ClaudeStreamLocalNavigationView?
            browser.setModelViewFactoryForTesting { configuration in
                let view = ClaudeStreamLocalNavigationView(frame: .zero, configuration: configuration)
                view.fixtureHTML = Self.html
                created = view
                return view
            }
            let id = try browser.createModelTab(url: URL(string: "https://claude.ai/new?incognito")!, claudeResponseStream: lease)
            let view = try XCTUnwrap(created)
            try await wait {
                guard !view.isLoading else { return false }
                return (try? await view.evaluateJavaScript("document.title")) as? String == "Claude passive local fixture"
            }
            XCTAssertEqual(view.loadCalls, 1)
            XCTAssertEqual(browser.tabs.count, 2); XCTAssertEqual(browser.selectedTabID, human)
            XCTAssertTrue(browser.webView(for: id) === view)
            XCTAssertEqual(hasObserver(view), !revoked)
            XCTAssertEqual(lease.isCurrent, !revoked)
        }
    }

    func testOrdinaryAndHumanViewsHaveNoObserverAndOnlyBlankOwnedViewCanClaim() throws {
        let browser = EmbeddedBrowserSession(persistent: false); defer { browser.shutdown() }
        let human = try browser.createTab(), model = try browser.createUnloadedModelTabForTesting()
        let humanView = try XCTUnwrap(browser.webView(for: human)), modelView = try XCTUnwrap(browser.webView(for: model))
        XCTAssertFalse(hasObserver(humanView)); XCTAssertFalse(hasObserver(modelView))
        let rejected = try ClaudeResponseStreamLeaseFixture(); defer { rejected.cleanup() }
        let humanLease = try XCTUnwrap(rejected.lease())
        XCTAssertFalse(browser.installClaudeResponseStream(humanLease, tabID: human))
        XCTAssertFalse(humanLease.isCurrent); XCTAssertFalse(hasObserver(humanView))
        let accepted = try ClaudeResponseStreamLeaseFixture(); defer { accepted.cleanup() }
        let lease = try XCTUnwrap(accepted.lease())
        XCTAssertTrue(browser.installClaudeResponseStream(lease, tabID: model))
        let script = try observer(modelView), config = try configuration(script.source)
        XCTAssertEqual(script.injectionTime, .atDocumentStart); XCTAssertTrue(script.isForMainFrameOnly)
        XCTAssertEqual(Set(config.keys), ["key", "durationMs"])
        XCTAssertLessThanOrEqual(try XCTUnwrap(config["durationMs"] as? Int), 60_000)
        XCTAssertFalse(script.source.contains("__computaInstallClaudeStreamProbe382"))
        XCTAssertFalse(script.source.contains(lease.expectedMarker), "The prompt/marker is supplied only at exact native arm")
        browser.closeTab(model)
        XCTAssertFalse(lease.isCurrent); XCTAssertFalse(hasObserver(modelView))
    }

    func testProductionObserverPreservesRealStreamAndSavesOnlyFiniteMetadataBeforeRemoval() async throws {
        let f = try await loaded(); defer { f.cleanup() }
        let clipboard = NSPasteboard.general.changeCount
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let prompt = f.arm.request.prompt + "\n\nComputa session marker: SYNTHETICOWNERSHIP382"
        let armed = await f.browser.armClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner, expectedPrompt: prompt)
        XCTAssertTrue(armed)
        let secondArm = await f.browser.armClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner, expectedPrompt: prompt)
        XCTAssertFalse(secondArm)
        let facts = try await f.view.callAsyncJavaScript("""
            history.pushState(null,'','/chat/00000000-0000-4000-8000-000000000001');
            const body='event: content_block_delta\\r\\ndata: '+JSON.stringify({type:'content_block_delta',index:0,
              delta:{type:'text_delta',text:'é🙂'+marker+' PRIVATECANARY'}})+'\\r\\n\\r\\n';
            const bytes=new TextEncoder().encode(body);let position=0;
            const stream=new ReadableStream({pull(c){if(position<bytes.length){const end=Math.min(bytes.length,position+3);
              c.enqueue(bytes.slice(position,end));position=end;}else c.close();}});
            window.fixtureResponse=new Response(stream,{headers:{'content-type':'text/event-stream'}});
            window.fixturePromise=Promise.resolve(window.fixtureResponse);
            const init={method:'POST',body:JSON.stringify({content:[{text:prompt}]})},receiver={};
            const result=fetch.call(receiver,'https://claude.ai/api/organizations/00000000-0000-4000-8000-000000000001/completion',init);
            const samePromise=result===window.fixturePromise,sameResponse=(await result)===window.fixtureResponse;
            const originalBody=await window.fixtureResponse.text();await new Promise(r=>setTimeout(r,25));
            return {samePromise,sameResponse,sameReceiver:window.fixtureReceiver===receiver,sameInit:window.fixtureArguments[1]===init,
              originalBodyUnchanged:originalBody===body,calls:window.fixtureCalls,fixedInstaller:typeof window.__computaInstallClaudeStreamProbe382};
            """, arguments: ["prompt": prompt, "marker": f.lease.expectedMarker], in: nil, contentWorld: .page) as? [String: Any]
        for key in ["samePromise", "sameResponse", "sameReceiver", "sameInit", "originalBodyUnchanged"] {
            XCTAssertEqual(facts?[key] as? Bool, true, key)
        }
        XCTAssertEqual(facts?["calls"] as? Int, 1); XCTAssertEqual(facts?["fixedInstaller"] as? String, "undefined")
        let value = await f.browser.stopClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner)
        let snapshot = try XCTUnwrap(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encodedData) as? [String: Any])
        XCTAssertEqual(object["markerPresent"] as? Bool, true)
        XCTAssertEqual(object["matchedCalls"] as? Int, 1); XCTAssertEqual(object["eventCount"] as? Int, 1)
        XCTAssertEqual(object["terminalReason"] as? String, "end_of_stream")
        XCTAssertEqual(object["transitionCount"] as? Int, 1)
        XCTAssertGreaterThan(try XCTUnwrap(object["readCalls"] as? Int), 20)
        let text = String(decoding: snapshot.encodedData, as: UTF8.self)
        for secret in ["PRIVATECANARY", f.lease.expectedMarker, "SYNTHETICOWNERSHIP382", "00000000-0000-4000"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertTrue(f.lease.isCurrent, "Transport must be allowed to persist before explicit revoke")
        XCTAssertFalse(hasObserver(f.view))
        let disposed = try await f.view.callAsyncJavaScript("return typeof window[key] === 'undefined' && fetch === window.fixtureFetch;",
                                                          arguments: ["key": f.key], in: nil, contentWorld: .page)
        XCTAssertEqual(disposed as? Bool, true)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboard)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, foreground)
        XCTAssertEqual(f.browser.selectedTabID, f.human)
        f.browser.closeTab(f.id)
        XCTAssertFalse(f.lease.isCurrent, "Closing also revokes an already stopped observer's retained lease")
    }

    func testWrongOwnerOrViewCannotConsumeArmAndUnmatchedRequestsStayUnobserved() async throws {
        let f = try await loaded(); defer { f.cleanup() }
        let prompt = f.arm.request.prompt
        let wrongOwner = await f.browser.armClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: UUID().uuidString, expectedPrompt: prompt)
        let wrongView = await f.browser.armClaudeResponseStream(tabID: f.id, view: try XCTUnwrap(f.browser.webView(for: f.human)), ownerToken: f.owner, expectedPrompt: prompt)
        XCTAssertFalse(wrongOwner); XCTAssertFalse(wrongView)
        let armed = await f.browser.armClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner, expectedPrompt: prompt)
        XCTAssertTrue(armed)
        _ = try await f.view.callAsyncJavaScript("""
            window.fixtureResponse=new Response('unmatched',{headers:{'content-type':'text/event-stream'}});
            window.fixturePromise=Promise.resolve(window.fixtureResponse);
            fetch('https://claude.ai/completion',{method:'POST',body:JSON.stringify({a:prompt,b:prompt})});
            fetch('https://claude.ai/completion',{method:'POST',body:JSON.stringify({prompt:'unrelated'})});return true;
            """, arguments: ["prompt": prompt], in: nil, contentWorld: .page)
        let result = await f.browser.stopClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner)
        let snapshot = try XCTUnwrap(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encodedData) as? [String: Any])
        XCTAssertEqual(object["matchedCalls"] as? Int, 0); XCTAssertEqual(object["eventCount"] as? Int, 0)
        XCTAssertEqual(object["terminalReason"] as? String, "stopped")
    }

    func testOneFreshConversationRouteRemainsDiagnosticOnlyAndSecondRouteRevokes() async throws {
        let f = try await loaded(); defer { f.cleanup() }
        let armed = await f.browser.armClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner, expectedPrompt: f.arm.request.prompt)
        XCTAssertTrue(armed)
        _ = try await f.view.evaluateJavaScript("history.pushState(null,'','/chat/00000000-0000-4000-8000-000000000001')")
        try await wait { f.browser.tabs.first(where: { $0.id == f.id })?.url?.path == "/chat/00000000-0000-4000-8000-000000000001" }
        XCTAssertTrue(f.lease.isCurrent)
        _ = try await f.view.evaluateJavaScript("history.pushState(null,'','/chat/00000000-0000-4000-8000-000000000002')")
        try await wait { !f.lease.isCurrent }
        XCTAssertFalse(hasObserver(f.view))
        let stale = await f.browser.stopClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner)
        XCTAssertNil(stale)
        XCTAssertTrue(f.browser.webView(for: f.id) === f.view)
    }

    func testDocumentReplacementBeforeArmCannotReinstallAndShutdownRevokes() async throws {
        let f = try await loaded(); defer { f.cleanup() }
        XCTAssertTrue(f.lease.isCurrent)
        f.view.loadHTMLString(Self.html, baseURL: URL(string: "https://claude.ai/new?incognito"))
        try await wait { !f.lease.isCurrent }
        XCTAssertFalse(hasObserver(f.view))
        let armed = await f.browser.armClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner, expectedPrompt: f.arm.request.prompt)
        XCTAssertFalse(armed)
        let other = try await loaded(); defer { other.cleanup() }
        other.browser.shutdown()
        XCTAssertFalse(other.lease.isCurrent); XCTAssertNil(other.browser.webView(for: other.id))
    }

    func testLateArmCallbackCannotEstablishCaptureOrReplayOrdinaryWork() async throws {
        let f = try await loaded(); defer { f.cleanup() }
        _ = try await f.view.callAsyncJavaScript("""
            const original=window[key];Object.defineProperty(window,key,{configurable:true,value:async function(...args){
              if(args[0]==='arm')await new Promise(r=>setTimeout(r,1100));return original(...args);}});return true;
            """, arguments: ["key": f.key], in: nil, contentWorld: .page)
        let start = ContinuousClock.now
        let armed = await f.browser.armClaudeResponseStream(tabID: f.id, view: f.view, ownerToken: f.owner, expectedPrompt: f.arm.request.prompt)
        XCTAssertFalse(armed); XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertFalse(f.lease.isCurrent); XCTAssertFalse(hasObserver(f.view))
        XCTAssertTrue(f.browser.webView(for: f.id) === f.view)
        let calls = try await f.view.evaluateJavaScript("window.fixtureCalls")
        XCTAssertEqual(calls as? Int, 0)
    }

    func testDocumentChangesDuringArmDiscardItsLateCallback() async throws {
        let f = try await loaded(); defer { f.cleanup() }
        _ = try await f.view.callAsyncJavaScript("""
            const original=window[key];Object.defineProperty(window,key,{configurable:true,value:async function(...args){
              if(args[0]==='arm')await new Promise(r=>setTimeout(r,100));return original(...args);}});return true;
            """, arguments: ["key": f.key], in: nil, contentWorld: .page)
        let pending = Task { await f.browser.armClaudeResponseStream(tabID: f.id, view: f.view,
            ownerToken: f.owner, expectedPrompt: f.arm.request.prompt) }
        try await Task.sleep(for: .milliseconds(25))
        f.view.loadHTMLString(Self.html, baseURL: URL(string: "https://claude.ai/new?incognito"))
        let armed = await pending.value
        XCTAssertFalse(armed); XCTAssertFalse(f.lease.isCurrent); XCTAssertFalse(hasObserver(f.view))
        XCTAssertTrue(f.browser.webView(for: f.id) === f.view)
    }

    private static let html = """
        <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'">
        <title>Claude passive local fixture</title>
        """
    private static let underlay = """
        window.fixtureCalls=0;
        window.fixtureFetch=function(...args){window.fixtureCalls++;window.fixtureReceiver=this;window.fixtureArguments=args;
          if(!window.fixturePromise)throw new Error('Synthetic response not prepared');return window.fixturePromise;};
        Object.defineProperty(window,'fetch',{value:window.fixtureFetch,configurable:true,writable:true,enumerable:true});
        """

    @MainActor private struct Loaded {
        let arm: ClaudeResponseStreamLeaseFixture, lease: ClaudeResponseStreamLease, browser: EmbeddedBrowserSession
        let id: UUID, human: UUID, view: WKWebView, owner: String, key: String
        func cleanup() { browser.shutdown(); arm.cleanup() }
    }

    private func loaded() async throws -> Loaded {
        let arm = try ClaudeResponseStreamLeaseFixture(), lease = try XCTUnwrap(arm.lease())
        let browser = EmbeddedBrowserSession(persistent: false)
        do {
            let human = try browser.createTab(), id = try browser.createUnloadedModelTabForTesting()
            let view = try XCTUnwrap(browser.webView(for: id))
            view.configuration.userContentController.addUserScript(WKUserScript(source: Self.underlay,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            XCTAssertTrue(browser.installClaudeResponseStream(lease, tabID: id))
            let key = try XCTUnwrap(configuration(observer(view).source)["key"] as? String)
            let owner = UUID().uuidString
            try browser.installModelChangeSignal(tabID: id, ownerToken: owner, world: .world(name: "claude-stream-fixture"), originHost: "claude.ai")
            view.loadHTMLString(Self.html, baseURL: URL(string: "https://claude.ai/new?incognito"))
            try await wait {
                guard !view.isLoading else { return false }
                return (try? await view.evaluateJavaScript("document.title")) as? String == "Claude passive local fixture"
            }
            XCTAssertTrue(lease.isCurrent, "The initial ordinary document must preserve its dormant observer")
            return Loaded(arm: arm, lease: lease, browser: browser, id: id, human: human, view: view, owner: owner, key: key)
        } catch { browser.shutdown(); arm.cleanup(); throw error }
    }

    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Offline WebKit fixture condition did not complete")
        throw EmbeddedBrowserSession.Failure.tabClosed
    }
    private func hasObserver(_ view: WKWebView) -> Bool {
        view.configuration.userContentController.userScripts.contains { $0.source.contains("__computaClaudeResponseStream_") }
    }
    private func observer(_ view: WKWebView) throws -> WKUserScript {
        try XCTUnwrap(view.configuration.userContentController.userScripts.first { $0.source.contains("__computaClaudeResponseStream_") })
    }
    private func configuration(_ source: String) throws -> [String: Any] {
        let start = try XCTUnwrap(source.range(of: "const config = ")).upperBound
        let end = try XCTUnwrap(source[start...].firstIndex(of: ";"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source[start..<end].utf8)) as? [String: Any])
    }
}

/// Intercepts only the fixture's normal native navigation; never calls real
/// network loading. The unchanged production install/navigate lifecycle runs.
@MainActor
private final class ClaudeStreamLocalNavigationView: WKWebView {
    var fixtureHTML = ""
    var loadCalls = 0
    override func load(_ request: URLRequest) -> WKNavigation? {
        loadCalls += 1
        return loadHTMLString(fixtureHTML, baseURL: request.url)
    }
}

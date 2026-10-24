import AppKit
import CryptoKit
import Darwin
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class ChatGPTRequestMetadataBrowserTests: XCTestCase {
    func testUnarmedAndHumanViewsHaveNoPageObserver() throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let human = try browser.createTab()
        let model = try browser.createUnloadedModelTabForTesting()
        XCTAssertTrue(try XCTUnwrap(browser.webView(for: human)).configuration.userContentController.userScripts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(browser.webView(for: model)).configuration.userContentController.userScripts.isEmpty)
        let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
        XCTAssertFalse(browser.installModelRequestMetadata(try arm.lease(), tabID: human))
        XCTAssertTrue(try XCTUnwrap(browser.webView(for: human)).configuration.userContentController.userScripts.isEmpty)
        let decodedArm = try RequestMetadataIntegrationArm(); defer { decodedArm.remove() }
        XCTAssertFalse(browser.installModelRequestMetadata(try decodedArm.lease(decoded: true), tabID: human))
        XCTAssertTrue(try XCTUnwrap(browser.webView(for: human)).configuration.userContentController.userScripts.isEmpty)
    }

    func testOnlyExplicitDecodedPurposeAddsTheOptInConfigurationKey() throws {
        for decoded in [false, true] {
            let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
            let browser = EmbeddedBrowserSession(persistent: false); defer { browser.shutdown() }
            let id = try browser.createUnloadedModelTabForTesting()
            let view = try XCTUnwrap(browser.webView(for: id))
            XCTAssertTrue(browser.installModelRequestMetadata(try arm.lease(decoded: decoded), tabID: id))
            let source = try XCTUnwrap(view.configuration.userContentController.userScripts.first).source
            let config = try injectedConfiguration(source)
            XCTAssertEqual(Set(config.keys), decoded ? ["key", "durationMs", "captureDecodedEvents"] : ["key", "durationMs"])
            if decoded { XCTAssertEqual(config["captureDecodedEvents"] as? Bool, true) }
            else { XCTAssertNil(config["captureDecodedEvents"]) }
            for nativeID in [arm.task, arm.thread, arm.turn, arm.preparation] {
                XCTAssertFalse(source.contains(nativeID.uuidString.lowercased()))
            }
        }
    }

    func testAsyncDiagnosticHookIsAwaitedButCannotUpgradeOrDowngradeTheLeaseMode() async throws {
        for decoded in [false, true] {
            let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
            let browser = EmbeddedBrowserSession(persistent: false); defer { browser.shutdown() }
            let id = try browser.createUnloadedModelTabForTesting()
            let view = try XCTUnwrap(browser.webView(for: id))
            XCTAssertTrue(browser.installModelRequestMetadata(try arm.lease(decoded: decoded), tabID: id))
            let source = try XCTUnwrap(view.configuration.userContentController.userScripts.first).source
            let key = try XCTUnwrap(injectedConfiguration(source)["key"] as? String)
            let token = UUID().uuidString
            try browser.installModelChangeSignal(tabID: id, ownerToken: token, world: .world(name: "metadata-browser-test"))
            view.loadHTMLString("<!doctype html><title>Local metadata fixture</title>", baseURL: URL(string: "https://chatgpt.com/"))
            try await ready(view)
            func replaceHook(decodedMode: Bool) async throws {
                var snapshot: [String: Any] = ["schemaVersion": decodedMode ? 2 : 1, "active": true, "expired": false, "rows": []]
                if decodedMode {
                    snapshot["decoder"] = ["state": "installed", "completionCalls": 0, "programObservations": 0,
                                           "recoveredNullObservations": 0, "lastProgram": NSNull()]
                }
                _ = try await view.callAsyncJavaScript("""
                    Object.defineProperty(window, key, {configurable:true, value:async function() {
                      await Promise.resolve(); return snapshot;
                    }}); return true;
                    """, arguments: ["key": key, "snapshot": snapshot], in: nil, contentWorld: .page)
            }
            try await replaceHook(decodedMode: !decoded)
            let crossed = await browser.modelRequestMetadata(command: "activate", tabID: id, view: view, ownerToken: token)
            XCTAssertNil(crossed, "A finite page snapshot still cannot change the explicitly armed capture mode")
            try await replaceHook(decodedMode: decoded)
            let matching = await browser.modelRequestMetadata(command: "snapshot", tabID: id, view: view, ownerToken: token)
            XCTAssertEqual(try XCTUnwrap(matching).schemaVersion, decoded ? 2 : 1)
            XCTAssertTrue(try XCTUnwrap(matching).active, "The bridge must await an asynchronous hook before serialization")
            browser.closeTab(id)
        }
    }

    func testLateDecodedActivationIsUnknownAndDoesNotCloseTheOrdinaryOwnedView() async throws {
        let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
        let lease = try arm.lease(decoded: true)
        let browser = EmbeddedBrowserSession(persistent: false); defer { browser.shutdown() }
        let human = try browser.createTab()
        let id = try browser.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(browser.webView(for: id))
        XCTAssertTrue(browser.installModelRequestMetadata(lease, tabID: id))
        let source = try XCTUnwrap(view.configuration.userContentController.userScripts.first).source
        let key = try XCTUnwrap(injectedConfiguration(source)["key"] as? String)
        let token = UUID().uuidString
        try browser.installModelChangeSignal(tabID: id, ownerToken: token, world: .world(name: "metadata-browser-test"))
        view.loadHTMLString("<!doctype html><title>Local metadata fixture</title>", baseURL: URL(string: "https://chatgpt.com/"))
        try await ready(view)
        _ = try await view.callAsyncJavaScript("""
            Object.defineProperty(window, key, {configurable:true, value:async function() {
              await new Promise(resolve => setTimeout(resolve, 1100));
              return {schemaVersion:2,active:true,expired:false,rows:[],decoder:{state:'installed',
                completionCalls:0,programObservations:0,recoveredNullObservations:0,lastProgram:null}};
            }}); return true;
            """, arguments: ["key": key], in: nil, contentWorld: .page)
        let late = await browser.modelRequestMetadata(command: "activate", tabID: id, view: view, ownerToken: token)
        XCTAssertNil(late, "A late observation cannot establish activation within the existing one-second budget")
        XCTAssertTrue(browser.webView(for: id) === view, "The diagnostic read itself cannot close or replay ordinary model work")
        XCTAssertTrue(lease.isCurrent)
        XCTAssertEqual(browser.selectedTabID, human)
        browser.closeTab(id)
    }

    func testProductionDecodedObserverImportsLocalESMAndRestoresTheActualClassDescriptor() async throws {
        let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
        let browser = EmbeddedBrowserSession(persistent: false); defer { browser.shutdown() }
        let human = try browser.createTab()
        let id = try browser.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(browser.webView(for: id))
        XCTAssertTrue(browser.installModelRequestMetadata(try arm.lease(decoded: true), tabID: id))
        let controller = view.configuration.userContentController
        let installed = try XCTUnwrap(controller.userScripts.first)
        // Match the version-pinned minified method and namespace getter in a
        // real WebKit ESM namespace. Only the import URL changes in production JS.
        let module = """
            const T={safeParse(e){window.localOriginalCalls++;return{success:true,data:{type:"message_stream_complete"}}}};
            class O{
            recordCompletion(e){let t=T.safeParse(e);return t.success&&"message_stream_complete"===t.data.type&&(this.messageStreamCompleted=!0),e}
            }
            const exports={};Object.defineProperty(exports,'c',{enumerable:true,get:()=>O});
            function __webpack_require__(){window.localRequireCalls++;throw new Error('No fixture factory may run');}
            __webpack_require__.c={dd:{exports}};
            window.localOriginalCalls=0;window.localRequireCalls=0;window.localDecoder=O;
            window.localOriginalDescriptor=Object.getOwnPropertyDescriptor(O.prototype,'recordCompletion');
            export {__webpack_require__};
            """
        let runtimeURL = "https://chatgpt.com/cdn/assets/633146.1f9c264032.js"
        XCTAssertEqual(installed.source.components(separatedBy: runtimeURL).count, 2)
        let moduleURL = "data:text/javascript;base64," + Data(module.utf8).base64EncodedString()
        let localSource = installed.source.replacingOccurrences(of: runtimeURL, with: moduleURL)
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: localSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        let token = UUID().uuidString
        try browser.installModelChangeSignal(tabID: id, ownerToken: token, world: .world(name: "metadata-browser-test"))
        let conversation = "00000000-0000-4000-8000-000000000001"
        view.loadHTMLString("<!doctype html><title>Local metadata fixture</title>",
                            baseURL: URL(string: "https://chatgpt.com/c/" + conversation))
        try await ready(view)
        let importedBeforeActivation = try await view.evaluateJavaScript("typeof window.localDecoder !== 'undefined'")
        XCTAssertEqual(importedBeforeActivation as? Bool, false, "Installation cannot import or initialize a decoder")
        let activationResult = await browser.modelRequestMetadata(command: "activate", tabID: id, view: view, ownerToken: token)
        let activated = try XCTUnwrap(activationResult)
        XCTAssertTrue(activated.active, "The actual ESM import and prototype checks must finish before native activation succeeds")
        XCTAssertEqual(activated.schemaVersion, 2)
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: activated.encodedData) as? [String: Any])
        XCTAssertEqual((initial["decoder"] as? [String: Any])?["state"] as? String, "installed")
        let knownNull = #"DIL.render(__dil.jsx(()=>{const __dilConstants=DIL.useConstants();const __dilModelDataBindings=DIL.useAppData((appData)=>appData.opGenui?.modelDataBindings??{});return null;},{"key":"body:0"}));"#
        XCTAssertEqual(knownNull.utf16.count, 194)
        let facts = try await view.callAsyncJavaScript("""
            const payload={conversation_id:conversation,message:{author:{role:'assistant'},status:'finished_successfully',
              content:{parts:['PRIVATE_MESSAGE']},metadata:{model_dil_v2:{code,
                constants:{PRIVATE_CONSTANT:'PRIVATE'},appData:{PRIVATE_APP_DATA:'PRIVATE'},fallbackMarkdown:'',
                recoveryDiagnostics:[{code:'unterminated_braced_value',action:'recovered_parse',line:1,column:1}]}}}};
            const instance=new window.localDecoder();
            const result=Reflect.apply(instance.recordCompletion,instance,[payload,'PRIVATE_ARGUMENT']);
            const current=Object.getOwnPropertyDescriptor(window.localDecoder.prototype,'recordCompletion');
            return {sameResult:result===payload,completed:instance.messageStreamCompleted===true,
              calls:window.localOriginalCalls,requires:window.localRequireCalls,wrapped:current.value!==window.localOriginalDescriptor.value,
              writable:current.writable,configurable:current.configurable,enumerable:current.enumerable};
            """, arguments: ["code": knownNull, "conversation": conversation], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(facts?["sameResult"] as? Bool, true)
        XCTAssertEqual(facts?["completed"] as? Bool, true, "The original receiver and result are preserved")
        XCTAssertEqual(facts?["calls"] as? Int, 1); XCTAssertEqual(facts?["requires"] as? Int, 0)
        XCTAssertEqual(facts?["wrapped"] as? Bool, true)
        XCTAssertEqual(facts?["writable"] as? Bool, true); XCTAssertEqual(facts?["configurable"] as? Bool, true)
        XCTAssertEqual(facts?["enumerable"] as? Bool, false)
        let snapshotResult = await browser.modelRequestMetadata(command: "snapshot", tabID: id, view: view, ownerToken: token)
        let snapshot = try XCTUnwrap(snapshotResult)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encodedData) as? [String: Any])
        let decoder = try XCTUnwrap(object["decoder"] as? [String: Any])
        XCTAssertEqual(snapshot.rowCount, 0, "No fetch, provider request or native Send is involved")
        XCTAssertEqual(decoder["completionCalls"] as? Int, 1)
        XCTAssertEqual(decoder["programObservations"] as? Int, 1)
        XCTAssertEqual(decoder["recoveredNullObservations"] as? Int, 1)
        let program = try XCTUnwrap(decoder["lastProgram"] as? [String: Any])
        XCTAssertEqual(program["carrier"] as? String, "message")
        XCTAssertEqual(program["messageStatus"] as? String, "finished_successfully")
        XCTAssertEqual(program["codeLength"] as? Int, 194)
        XCTAssertEqual(program["knownNullProgram"] as? Bool, true)
        XCTAssertEqual(program["emptyFallbackMarkdown"] as? Bool, true)
        XCTAssertEqual(program["conversationMatchesDocument"] as? Bool, true)
        XCTAssertEqual(program["recovery"] as? String, "unterminated_braced_value_recovered_parse")
        XCTAssertEqual(program["recoveryLine"] as? Int, 1); XCTAssertEqual(program["recoveryColumn"] as? Int, 1)
        let serialized = String(decoding: snapshot.encodedData, as: UTF8.self)
        for privateValue in ["PRIVATE", knownNull, conversation] { XCTAssertFalse(serialized.contains(privateValue)) }
        let stopResult = await browser.modelRequestMetadata(command: "stop", tabID: id, view: view, ownerToken: token)
        let stopped = try XCTUnwrap(stopResult)
        XCTAssertFalse(stopped.active)
        let stoppedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: stopped.encodedData) as? [String: Any])
        XCTAssertEqual((stoppedObject["decoder"] as? [String: Any])?["state"] as? String, "restored")
        let restored = try await view.evaluateJavaScript("""
            (()=>{const now=Object.getOwnPropertyDescriptor(window.localDecoder.prototype,'recordCompletion'),old=window.localOriginalDescriptor;
              return now.value===old.value&&now.writable===old.writable&&now.configurable===old.configurable&&now.enumerable===old.enumerable
                &&!Object.getOwnPropertyNames(window).some(key=>/^__computaRequestMetadata_[a-f0-9]{32}$/.test(key));})()
            """)
        XCTAssertEqual(restored as? Bool, true, "Stopping restores the exact original class descriptor and removes the hook")
        // The fixture substituted a new WKUserScript identity, so remove that
        // local clone explicitly after production stop has restored the class.
        controller.removeAllUserScripts()
        XCTAssertEqual(browser.selectedTabID, human)
        browser.closeTab(id)
    }

    func testDocumentStartObserverActivatesOnlyByExactNativeViewOwnerAndStopsBeforeCleanup() async throws {
        let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
        let lease = try arm.lease()
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let human = try browser.createTab()
        let id = try browser.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(browser.webView(for: id))
        let cookieStore = view.configuration.websiteDataStore.httpCookieStore
        let syntheticCookies = try [
            cookie(name: "synthetic_a", value: "alpha"),
            cookie(name: "synthetic_b", value: "beta", secure: true),
            cookie(domain: "other.test", name: "synthetic_foreign", value: "excluded"),
            cookie(path: "/backend-api/f/conversations", name: "synthetic_other_path", value: "excluded")
        ]
        for cookie in syntheticCookies {
            await withCheckedContinuation { continuation in cookieStore.setCookie(cookie) { continuation.resume() } }
        }
        let cookiesBefore = await withCheckedContinuation { continuation in cookieStore.getAllCookies { continuation.resume(returning: $0) } }
        // This fixture-only predecessor routes eligible URLs to WebKit's real
        // native data fetch. It runs before the production observer, so the
        // cached vendor fetch still returns an actual, unread WebKit Response
        // without accessing ChatGPT or any external network endpoint.
        let localFetch = WKUserScript(source: """
            (() => {
              const nativeFetch = window.fetch, call = Reflect.apply;
              window.localNativeFetchCalls = 0;
              window.fetch = function(input, init) {
                window.localNativeFetchCalls++;
                if (typeof input === 'string') {
                  const url = new URL(input, location.href);
                  if (url.origin === location.origin &&
                      ['/backend-api/f/conversation/prepare', '/backend-api/f/conversation'].includes(url.pathname)) {
                    return call(nativeFetch, this, ['data:text/plain,LOCAL_PRIVATE_RESPONSE']);
                  }
                }
                return call(nativeFetch, this, arguments);
              };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        view.configuration.userContentController.addUserScript(localFetch)
        XCTAssertTrue(browser.installModelRequestMetadata(lease, tabID: id))
        let source = try XCTUnwrap(view.configuration.userContentController.userScripts.last).source
        for nativeID in [arm.task, arm.thread, arm.turn, arm.preparation] {
            XCTAssertFalse(source.contains(nativeID.uuidString.lowercased()))
        }
        let token = UUID().uuidString
        try browser.installModelChangeSignal(tabID: id, ownerToken: token, world: .world(name: "metadata-browser-test"))
        view.loadHTMLString("<!doctype html><title>Local metadata fixture</title><script>window.cachedFetch = window.fetch;</script>",
                            baseURL: URL(string: "https://chatgpt.com/"))
        try await ready(view)
        let before = await browser.modelRequestMetadata(command: "snapshot", tabID: id, view: view, ownerToken: token)
        XCTAssertNil(before, "Native activation must bind the generation before reading any page snapshot")
        let wrong = await browser.modelRequestMetadata(command: "activate", tabID: id, view: view, ownerToken: UUID().uuidString)
        XCTAssertNil(wrong)
        let otherView = try XCTUnwrap(browser.webView(for: human))
        let wrongView = await browser.modelRequestMetadata(command: "activate", tabID: id, view: otherView, ownerToken: token)
        XCTAssertNil(wrongView)
        let active = await browser.modelRequestMetadata(command: "activate", tabID: id, view: view, ownerToken: token)
        XCTAssertTrue(try XCTUnwrap(active).active)
        XCTAssertNil(active?.profileCookieBudget, "Activation must not collect a profile cookie estimate")
        let fetchFacts = try await view.callAsyncJavaScript("""
            let unrelatedUnread = true;
            for (let i = 0; i < 10; i++) {
              const response = await window.cachedFetch('data:text/plain,LOCAL_PRIVATE_URL' + i);
              unrelatedUnread = unrelatedUnread && response.status === 200 && !response.bodyUsed;
            }
            const prepare = await window.cachedFetch('/backend-api/f/conversation/prepare',
              {method:'POST',body:'LOCAL_PRIVATE_BODY'});
            const response = await window.cachedFetch('/backend-api/f/conversation',
              {method:'POST',body:'LOCAL_PRIVATE_BODY'});
            return {status: response.status, bodyUsed: response.bodyUsed, prepareStatus: prepare.status,
              prepareBodyUsed: prepare.bodyUsed, unrelatedUnread, calls: window.localNativeFetchCalls};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(fetchFacts?["status"] as? Int, 200)
        XCTAssertEqual(fetchFacts?["bodyUsed"] as? Bool, false)
        XCTAssertEqual(fetchFacts?["prepareStatus"] as? Int, 200)
        XCTAssertEqual(fetchFacts?["prepareBodyUsed"] as? Bool, false)
        XCTAssertEqual(fetchFacts?["unrelatedUnread"] as? Bool, true)
        XCTAssertEqual(fetchFacts?["calls"] as? Int, 12, "Every cached fetch reaches its predecessor exactly once")
        let snapshot = await browser.modelRequestMetadata(command: "snapshot", tabID: id, view: view, ownerToken: token)
        let captured = try XCTUnwrap(snapshot)
        let cookieBudget = try XCTUnwrap(captured.profileCookieBudget)
        XCTAssertEqual(cookieBudget.cookieCount, 2)
        XCTAssertEqual(cookieBudget.totalNameUTF8Bytes, 22)
        XCTAssertEqual(cookieBudget.totalValueUTF8Bytes, 9)
        XCTAssertEqual(cookieBudget.estimatedCookieHeaderUTF8Bytes, 35)
        XCTAssertEqual(captured.rowCount, 2, "Ten unrelated fetches must leave both submission capture slots available")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.encodedData) as? [String: Any])
        let rows = try XCTUnwrap(values["rows"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["ordinal"] as? Int, 1)
        XCTAssertEqual(rows[0]["endpoint"] as? String, "preparation")
        XCTAssertEqual(rows[0]["bodyType"] as? String, "string")
        XCTAssertEqual(rows[0]["outcome"] as? String, "headers")
        XCTAssertEqual(rows[0]["status"] as? Int, 200)
        XCTAssertEqual(rows[1]["ordinal"] as? Int, 2)
        XCTAssertEqual(rows[1]["endpoint"] as? String, "conversation")
        XCTAssertEqual(rows[1]["outcome"] as? String, "headers")
        XCTAssertEqual(rows[1]["status"] as? Int, 200, "The observer uses WebKit's actual Response.status getter")
        let text = String(decoding: captured.encodedData, as: UTF8.self)
        XCTAssertFalse(text.contains("LOCAL_PRIVATE_URL")); XCTAssertFalse(text.contains("LOCAL_PRIVATE_BODY"))
        XCTAssertFalse(text.contains("LOCAL_PRIVATE_RESPONSE"))
        let stopped = await browser.modelRequestMetadata(command: "stop", tabID: id, view: view, ownerToken: token)
        XCTAssertFalse(try XCTUnwrap(stopped).active)
        XCTAssertEqual(stopped?.profileCookieBudget, cookieBudget)
        let cookiesAfter = await withCheckedContinuation { continuation in cookieStore.getAllCookies { continuation.resume(returning: $0) } }
        func syntheticFacts(_ cookies: [HTTPCookie]) -> Set<String> {
            Set(cookies.map { [$0.domain, $0.path, $0.name, $0.value].joined(separator: "|") })
        }
        XCTAssertEqual(syntheticFacts(cookiesAfter), syntheticFacts(cookiesBefore), "The diagnostic only reads this nonpersistent synthetic cookie store")
        XCTAssertEqual(view.configuration.userContentController.userScripts.map(\.source), [localFetch.source],
            "Stopping removes the production observer while preserving the unrelated fixture predecessor")
        view.configuration.userContentController.removeAllUserScripts()
        let hooksRemain = try await view.evaluateJavaScript("Object.getOwnPropertyNames(window).some(key => /^__computaRequestMetadata_[a-f0-9]{32}$/.test(key))")
        XCTAssertEqual(hooksRemain as? Bool, false)
        XCTAssertEqual(browser.selectedTabID, human)
        XCTAssertFalse(view.isInspectable)
        browser.closeTab(id)
        lease.revoke()
        XCTAssertFalse(lease.isCurrent)
    }

    func testForeignOriginNavigationExpiryAndCloseRevokeOnlyDiagnostic() async throws {
        for mode in ["foreign", "navigation", "expiry", "close"] {
            let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
            let lease = try arm.lease(expiresIn: mode == "expiry" ? 3 : 60)
            let browser = EmbeddedBrowserSession(persistent: false)
            defer { browser.shutdown() }
            let id = try browser.createUnloadedModelTabForTesting()
            let view = try XCTUnwrap(browser.webView(for: id))
            XCTAssertTrue(browser.installModelRequestMetadata(lease, tabID: id))
            let token = UUID().uuidString
            try browser.installModelChangeSignal(tabID: id, ownerToken: token, world: .world(name: "metadata-browser-test"))
            view.loadHTMLString("<!doctype html><title>Local metadata fixture</title>",
                baseURL: URL(string: mode == "foreign" ? "https://example.test/" : "https://chatgpt.com/"))
            try await ready(view)
            let active = await browser.modelRequestMetadata(command: "activate", tabID: id, view: view, ownerToken: token)
            if mode == "foreign" { XCTAssertNil(active); continue }
            XCTAssertTrue(try XCTUnwrap(active).active)
            switch mode {
            case "navigation":
                try browser.navigate(tabID: id, to: XCTUnwrap(URL(string: "about:blank")))
            case "expiry": try await Task.sleep(for: .milliseconds(3_100))
            case "close": browser.closeTab(id)
            default: break
            }
            let stale = await browser.modelRequestMetadata(command: "snapshot", tabID: id, view: view, ownerToken: token)
            XCTAssertNil(stale, mode)
            XCTAssertFalse(lease.isCurrent, mode)
            XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
            XCTAssertFalse(view.isInspectable)
        }
    }

    private func ready(_ view: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if !view.isLoading, (try? await view.evaluateJavaScript("document.title")) as? String == "Local metadata fixture" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The entirely in-memory WebKit fixture did not load")
    }

    private func injectedConfiguration(_ source: String) throws -> [String: Any] {
        let start = try XCTUnwrap(source.range(of: "const config = ")).upperBound
        let end = try XCTUnwrap(source[start...].firstIndex(of: ";"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source[start..<end].utf8)) as? [String: Any])
    }

    private func cookie(domain: String = "chatgpt.com", path: String = "/", name: String, value: String,
                        secure: Bool = false) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value]
        if secure { properties[.secure] = "TRUE" }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}

final class ChatGPTRequestMetadataServerTests: XCTestCase {
    func testUnavailableDecodedActivationStopsAndPersistsBeforeCleanupWithoutSendWhileV1Continues() async throws {
        for decoded in [false, true] {
            let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }; try arm.arm(decoded: decoded)
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: arm.root.appendingPathComponent("WebsiteReplyDiagnostics-v1"))
            let transport = MetadataIntegrationTransport(activationSucceeds: false)
            await server.configureEmbeddedTransport(transport)
            do {
                _ = try await server.fixtureInfer(arm.request(), taskID: arm.task.uuidString,
                    threadID: arm.thread.uuidString, turnID: arm.turn.uuidString, preparationID: arm.preparation)
                XCTAssertFalse(decoded)
            } catch {
                XCTAssertTrue(decoded)
                guard let failure = error as? WebModelServer.Failure, case .requestMetadataUnavailable = failure else {
                    return XCTFail("Expected the explicitly armed diagnostic-unavailable error")
                }
                XCTAssertEqual(WebModelServer.errorPresentation(for: error).code, "request_metadata_unavailable")
                XCTAssertTrue(error.localizedDescription.contains("not submitted"))
            }
            let beforeFinish = await transport.events()
            XCTAssertEqual(beforeFinish.filter { $0 == "metadata_activate" }.count, 1)
            XCTAssertEqual(beforeFinish.filter { $0 == "webProviderSend" }.count, decoded ? 0 : 1)
            XCTAssertEqual(beforeFinish.filter { $0 == "metadata_stop" }.count, 1)
            let cleanup = try XCTUnwrap(beforeFinish.firstIndex(where: { ["webProviderFinish", "webProviderCancel"].contains($0) }))
            XCTAssertLessThan(try XCTUnwrap(beforeFinish.firstIndex(of: "metadata_stop")), cleanup)
            XCTAssertEqual(beforeFinish.filter { ["webProviderFinish", "webProviderCancel"].contains($0) }.count, 1)
            let sidecars = try FileManager.default.contentsOfDirectory(atPath: arm.directory.path).filter { $0.hasPrefix("request-metadata-") }
            XCTAssertEqual(sidecars.count, 1)
            let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: arm.directory.appendingPathComponent(try XCTUnwrap(sidecars.first)))) as? [String: Any])
            XCTAssertEqual(sidecar["purpose"] as? String, decoded ? "request_and_decoded_metadata_v2" : "request_metadata_v1")
            if decoded {
                let diagnostic = try XCTUnwrap(sidecar["diagnostic"] as? [String: Any])
                XCTAssertEqual((diagnostic["decoder"] as? [String: Any])?["state"] as? String, "unavailable")
            }
            _ = await server.fixtureFinish(taskID: arm.task.uuidString)
            let finalEvents = await transport.events()
            XCTAssertEqual(finalEvents.filter { $0 == "webProviderSend" }.count, decoded ? 0 : 1, "Cleanup cannot replay the prompt")
        }
    }

    func testDecodedActivationSucceedsBeforeTheOnlySendAndPersistsItsMode() async throws {
        let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }; try arm.arm(decoded: true)
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
            rejectedReplyDirectory: arm.root.appendingPathComponent("WebsiteReplyDiagnostics-v1"))
        let transport = MetadataIntegrationTransport()
        await server.configureEmbeddedTransport(transport)
        _ = try await server.fixtureInfer(arm.request(), taskID: arm.task.uuidString,
            threadID: arm.thread.uuidString, turnID: arm.turn.uuidString, preparationID: arm.preparation)
        let events = await transport.events()
        XCTAssertEqual(events.filter { $0 == "webProviderSend" }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "metadata_activate")), try XCTUnwrap(events.firstIndex(of: "webProviderSend")))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "metadata_stop")), try XCTUnwrap(events.firstIndex(of: "webProviderFinish")))
    }
    func testSameTurnToolContinuationKeepsOneCaptureClockUntilFinalOrSecondRoundFailure() async throws {
        for fails in [false, true] {
            let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }; try arm.arm()
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: arm.root.appendingPathComponent("WebsiteReplyDiagnostics-v1"))
            await server.retainChatGPTConversationForTesting()
            let transport = MetadataIntegrationTransport(failsOnSequence: fails ? 2 : nil, toolFirst: true)
            await server.configureEmbeddedTransport(transport)
            var input: [[String: Any]] = [["role": "user", "content": "Say OK"]]
            let first = try await server.fixtureInfer(arm.request(input: input, tools: true), taskID: arm.task.uuidString,
                threadID: arm.thread.uuidString, turnID: arm.turn.uuidString, preparationID: arm.preparation)
            let output = try XCTUnwrap((JSONSerialization.jsonObject(with: first) as? [String: Any])?["output"] as? [[String: Any]])
            var events = await transport.events()
            XCTAssertTrue(events.contains("metadata_snapshot")); XCTAssertFalse(events.contains("metadata_stop"))
            let firstCaptureIsCurrent = await transport.captureIsCurrent()
            XCTAssertTrue(firstCaptureIsCurrent)
            input += output + [["type": "function_call_output", "call_id": try XCTUnwrap(output.first?["call_id"] as? String), "output": "Observed fixture result"]]
            do {
                _ = try await server.fixtureInfer(arm.request(input: input, tools: true), taskID: arm.task.uuidString,
                    threadID: arm.thread.uuidString, turnID: arm.turn.uuidString, preparationID: arm.preparation)
                XCTAssertFalse(fails)
            } catch { XCTAssertTrue(fails); XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt)) }
            _ = await server.fixtureFinish(taskID: arm.task.uuidString)
            events = await transport.events()
            XCTAssertEqual(events.filter { $0 == "metadata_start" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "metadata_activate" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "metadata_snapshot" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "metadata_stop" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "webProviderStart" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "webProviderSend" }.count, 2)
            let finalCaptureIsCurrent = await transport.captureIsCurrent()
            XCTAssertFalse(finalCaptureIsCurrent)
            let sidecars = try FileManager.default.contentsOfDirectory(atPath: arm.directory.path).filter { $0.hasPrefix("request-metadata-") }
            XCTAssertEqual(sidecars.count, 2, "Each inference retains an immutable finite snapshot of this one turn-scoped capture")
        }
    }

    func testFreshToolHandoffsStopCaptureBeforeClosureAndNeverReuseTheSingleArm() async throws {
        for fails in [false, true] {
            let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }; try arm.arm()
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: arm.root.appendingPathComponent("WebsiteReplyDiagnostics-v1"))
            let transport = MetadataIntegrationTransport(failsOnSequence: fails ? 2 : nil, toolFirst: true)
            await server.configureEmbeddedTransport(transport)
            var input: [[String: Any]] = [["role": "user", "content": "Say OK"]]
            let first = try await server.fixtureInfer(arm.request(input: input, tools: true), taskID: arm.task.uuidString,
                threadID: arm.thread.uuidString, turnID: arm.turn.uuidString, preparationID: arm.preparation)
            let output = try XCTUnwrap((JSONSerialization.jsonObject(with: first) as? [String: Any])?["output"] as? [[String: Any]])
            let current = await transport.captureIsCurrent()
            XCTAssertFalse(current, "A closed physical page cannot retain diagnostic authority through a pending tool result")
            input += output + [["type": "function_call_output", "call_id": try XCTUnwrap(output.first?["call_id"] as? String), "output": "Observed fixture result"]]
            do {
                _ = try await server.fixtureInfer(arm.request(input: input, tools: true), taskID: arm.task.uuidString,
                    threadID: arm.thread.uuidString, turnID: arm.turn.uuidString, preparationID: arm.preparation)
                XCTAssertFalse(fails)
            } catch { XCTAssertTrue(fails); XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt)) }
            _ = await server.fixtureFinish(taskID: arm.task.uuidString)
            let events = await transport.events()
            XCTAssertEqual(events.filter { $0 == "metadata_start" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "metadata_activate" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "metadata_snapshot" }.count, 0)
            XCTAssertEqual(events.filter { $0 == "metadata_stop" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "webProviderStart" }.count, 2)
            XCTAssertEqual(events.filter { $0 == "webProviderSend" }.count, 2)
            XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "metadata_stop")), try XCTUnwrap(events.firstIndex(of: "webProviderFinish")))
            let sidecars = try FileManager.default.contentsOfDirectory(atPath: arm.directory.path).filter { $0.hasPrefix("request-metadata-") }
            XCTAssertEqual(sidecars.count, 1, "The single-use grant cannot observe the later replacement page")
        }
    }

    func testMaintenanceDoesNotConsumeArmAndUserStartCapturesBeforeSingleSend() async throws {
        for maintenance in [true, false] {
            let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
            try arm.arm()
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
                rejectedReplyDirectory: arm.root.appendingPathComponent("WebsiteReplyDiagnostics-v1"))
            let transport = MetadataIntegrationTransport()
            await server.configureEmbeddedTransport(transport)
            try await server.prepareInferenceTurn(taskID: arm.task.uuidString, threadID: arm.thread.uuidString,
                runtimeGeneration: websiteInferenceFixtureGeneration, preparationID: arm.preparation, isMaintenance: maintenance)
            try await server.registerInferenceTurn(taskID: arm.task.uuidString, threadID: arm.thread.uuidString,
                turnID: arm.turn.uuidString, runtimeGeneration: websiteInferenceFixtureGeneration, preparationID: arm.preparation)
            _ = try await server.infer(arm.request(), taskID: arm.task.uuidString)
            let events = await transport.events()
            XCTAssertEqual(events.filter { $0 == "webProviderStart" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "webProviderSend" }.count, 1)
            XCTAssertEqual(events.contains("metadata_start"), !maintenance)
            XCTAssertEqual(FileManager.default.fileExists(atPath: arm.directory.appendingPathComponent("arm.json").path), maintenance)
            let sidecars = try FileManager.default.contentsOfDirectory(atPath: arm.directory.path).filter { $0.hasPrefix("request-metadata-") }
            XCTAssertEqual(sidecars.count, maintenance ? 0 : 1)
            if !maintenance {
                XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "metadata_start")), try XCTUnwrap(events.firstIndex(of: "webProviderStart")))
                XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "metadata_activate")), try XCTUnwrap(events.firstIndex(of: "webProviderSend")))
                XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "metadata_stop")), try XCTUnwrap(events.firstIndex(of: "webProviderFinish")))
                let path = arm.directory.appendingPathComponent(sidecars[0])
                let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
                XCTAssertEqual(permissions?.intValue, 0o600)
            }
        }
    }

    func testOriginalWebsiteFailureIsUnchangedAndDiagnosticStopsBeforeCleanup() async throws {
        let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }; try arm.arm()
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self,
            rejectedReplyDirectory: arm.root.appendingPathComponent("WebsiteReplyDiagnostics-v1"))
        let transport = MetadataIntegrationTransport(fails: true)
        await server.configureEmbeddedTransport(transport)
        do { _ = try await server.fixtureInfer(arm.request(), taskID: arm.task.uuidString,
            threadID: arm.thread.uuidString, turnID: arm.turn.uuidString, preparationID: arm.preparation); XCTFail("Expected original website error") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .responseFailed(.chatgpt)) }
        _ = await server.fixtureFinish(taskID: arm.task.uuidString)
        let events = await transport.events()
        XCTAssertEqual(events.filter { $0 == "webProviderSend" }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "metadata_stop")), try XCTUnwrap(events.firstIndex(of: "webProviderFinish")))
    }
}

private final class RequestMetadataIntegrationArm {
    let root: URL, directory: URL
    let task = UUID(), thread = UUID(), turn = UUID(), preparation = UUID()
    init() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("metadata-integration-" + UUID().uuidString)
        directory = root.appendingPathComponent("WebsiteRequestMetadataDiagnostics-v1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func arm(expiresIn: TimeInterval = 60, decoded: Bool = false) throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        let data = try JSONSerialization.data(withJSONObject: ["taskID": task.uuidString.lowercased(), "threadID": thread.uuidString.lowercased(),
            "provider": "chatgpt", "purpose": decoded ? "request_and_decoded_metadata_v2" : "request_metadata_v1", "expiresAt": formatter.string(from: Date().addingTimeInterval(expiresIn))])
        let path = directory.appendingPathComponent("arm.json"); try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func lease(expiresIn: TimeInterval = 60, decoded: Bool = false) throws -> ChatGPTRequestMetadataLease {
        try arm(expiresIn: expiresIn, decoded: decoded)
        return try XCTUnwrap(ChatGPTRequestMetadataLease.consume(directory: directory, taskID: task, threadID: thread, turnID: turn, preparationID: preparation))
    }
    func request(input: [[String: Any]]? = nil, tools: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": syntheticChatGPTModelID,
            "input": input ?? [["role": "user", "content": "Say OK"]],
            "tools": tools ? [["type": "function", "name": "exec_command", "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]]] : [],
            "stream": false,
            "client_metadata": ["x-codex-turn-metadata": try websiteInferenceFixtureMetadata(taskID: task.uuidString,
                threadID: thread.uuidString, turnID: turn.uuidString)]])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor MetadataIntegrationTransport: WebModelTransport {
    let base: WebsiteInferenceFixtureTransport
    let failsOnSequence: Int?
    let turnScoped: Bool
    let activationSucceeds: Bool
    private var sends = 0
    private var fingerprint = ""
    private var authorization: ChatGPTRequestMetadataLease?
    private var ledger: [String] = []
    init(fails: Bool = false, failsOnSequence: Int? = nil, toolFirst: Bool = false, activationSucceeds: Bool = true) {
        self.failsOnSequence = failsOnSequence ?? (fails ? 1 : nil); turnScoped = toolFirst
        self.activationSucceeds = activationSucceeds
        base = WebsiteInferenceFixtureTransport(MetadataWireTransport(toolFirst: toolFirst), defaultChatChoice: syntheticChatGPTChoice)
    }
    func events() -> [String] { ledger }
    func captureIsCurrent() -> Bool { authorization?.isCurrent == true }
    func request(operation: String, params: Data) async throws -> Data {
        ledger.append(operation)
        if operation == "webProviderSend", let input = try JSONSerialization.jsonObject(with: params) as? [String: String] {
            sends += 1
            fingerprint = SHA256.hash(data: Data((input["prompt"] ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        if operation == "webProviderPoll", failsOnSequence == sends { throw EmbeddedWebModelTransport.Failure.responseFailed(.chatgpt) }
        let data = try await base.request(operation: operation, params: params)
        guard turnScoped, var value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["ready", "running", "complete"].contains(value["state"] as? String ?? "") else { return data }
        value["turnContinuationCapability"] = "per_submission_ownership_v1"
        if var context = value["modelProofContext"] as? [String: Any] {
            context["submittedPromptFingerprint"] = fingerprint
            value["modelProofContext"] = context
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func startWithRequestMetadata(params: Data, authorization: ChatGPTRequestMetadataLease) async throws -> Data {
        ledger.append("metadata_start"); XCTAssertTrue(authorization.isCurrent); self.authorization = authorization
        return try await request(operation: "webProviderStart", params: params)
    }
    func activateRequestMetadata(sessionToken: String) async -> Bool { ledger.append("metadata_activate"); return activationSucceeds }
    func snapshotRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot? {
        ledger.append("metadata_snapshot")
        return metadataSnapshot(active: activationSucceeds)
    }
    func stopRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot? {
        ledger.append("metadata_stop")
        return metadataSnapshot(active: false)
    }
    func revokeRequestMetadata(sessionToken: String) async { ledger.append("metadata_revoke") }
    private func metadataSnapshot(active: Bool) -> ChatGPTRequestMetadataSnapshot? {
        let decoded = authorization?.capturesDecodedEvents == true
        var value: [String: Any] = ["schemaVersion": decoded ? 2 : 1, "active": active, "expired": false, "rows": []]
        if decoded {
            value["decoder"] = ["state": activationSucceeds ? "restored" : "unavailable", "completionCalls": 0,
                                "programObservations": 0, "recoveredNullObservations": 0, "lastProgram": NSNull()]
        }
        return (try? JSONSerialization.data(withJSONObject: value)).flatMap { try? ChatGPTRequestMetadataSnapshot.parse($0) }
    }
}

private actor MetadataWireTransport: WebModelTransport {
    private var token = ""
    let toolFirst: Bool
    private var sends = 0
    init(toolFirst: Bool = false) { self.toolFirst = toolFirst }
    func request(operation: String, params: Data) throws -> Data {
        let value: [String: Any]
        switch operation {
        case "webProviderStart":
            token = UUID().uuidString
            value = ["sessionToken": token, "state": "ready"]
        case "webProviderSend": sends += 1; value = ["state": "running"]
        case "webProviderPoll": value = ["state": "complete", "text": toolFirst && sends == 1
            ? "{\"type\":\"tool_calls\",\"calls\":[{\"name\":\"exec_command\",\"arguments\":{\"cmd\":\"fixture\"}}]}"
            : "{\"type\":\"message\",\"text\":\"OK\"}"]
        default: value = ["cleanup": "not_created"]
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(value))
    }
}

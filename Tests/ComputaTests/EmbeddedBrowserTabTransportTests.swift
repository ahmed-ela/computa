import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

/// Real WebKit, isolated storage, synthetic page. No live provider/login state
/// or native global-input permission is involved in these backend checks.
@MainActor
final class EmbeddedBrowserTabTransportTests: XCTestCase {
    private let fixture = """
    <!doctype html><html><head><title>Flight fixture</title></head><body><main>
    <h1>Flight status</h1><label>Flight number <input id="flight" placeholder="Flight number"></label>
    <button id="check">Check flight</button><p id="result" role="status">No flight checked</p>
    <p hidden>HIDDEN_PRIVATE_SENTINEL</p><label>Password <input type="password" value="PASSWORD_PRIVATE_SENTINEL"></label>
    <input type="password" role="button" value="ROLE_PASSWORD_PRIVATE_SENTINEL">
    <button role="textbox" aria-label="Fake field">Pretend editable</button>
    <div role="textbox" aria-label="Fake div">Fake text</div>
    <input readonly aria-label="Read only" value="retained">
    <div inert><input value="INERT_PRIVATE_SENTINEL"></div>
    <button role="\(String(repeating: "x", count: 1_000))">Oversized role</button>
    <script>document.getElementById('check').onclick=()=>{
      window.clicks=(window.clicks||0)+1;
      setTimeout(()=>document.getElementById('result').textContent=document.getElementById('flight').value+' departs at 18:45',30);
    };</script></main></body></html>
    """

    func testRealWebKitReadsFillsPressesAndWaitsForVisibleFlightResult() async throws {
        let session=EmbeddedBrowserSession(persistent:false), transport=EmbeddedBrowserTabTransport(session:session)
        defer { session.shutdown() }
        let id=try session.createTab(), view=try XCTUnwrap(session.webView(for:id))
        view.frame=NSRect(x:0,y:0,width:1024,height:768)
        view.loadHTMLString(fixture,baseURL:URL(string:"http://localhost:8123/flight"))
        try await session.waitForHumanTabReady(id:id,until:.now + .seconds(10))
        let available=try await transport.target(id:id.uuidString)
        let target=try XCTUnwrap(available)
        let observed=try await transport.observe(target:target)
        XCTAssertEqual(observed.sourceName,"computa_webkit_dom")
        XCTAssertFalse(observed.nodes.contains { $0.name.contains("HIDDEN_PRIVATE_SENTINEL") || ($0.value ?? "").contains("PASSWORD_PRIVATE_SENTINEL") })
        XCTAssertFalse(observed.nodes.contains { $0.name.contains("ROLE_PASSWORD_PRIVATE_SENTINEL") || ($0.value ?? "").contains("ROLE_PASSWORD_PRIVATE_SENTINEL") })
        XCTAssertFalse(observed.nodes.contains { ($0.value ?? "").contains("INERT_PRIVATE_SENTINEL") })
        for name in ["Fake field","Fake div","Read only"] {
            let node=try XCTUnwrap(observed.nodes.first { $0.name==name })
            XCTAssertTrue(node.isReadOnly)
            XCTAssertFalse(node.isEditable)
        }
        XCTAssertTrue(observed.sourceTruncated,"An oversized custom role is explicitly omitted from complete semantic coverage")
        let field=try XCTUnwrap(observed.nodes.first { $0.role=="textbox" && $0.name=="Flight number" })
        try await transport.setText(target:target,backendNodeID:XCTUnwrap(field.backendNodeID),text:"UA 123",document:observed,permit:BrowserMutationPermit())
        let afterFill=try await transport.observe(target:target)
        XCTAssertEqual(afterFill.nodes.first { $0.backendNodeID==field.backendNodeID }?.value,"UA 123")
        let check=try XCTUnwrap(afterFill.nodes.first { $0.role=="button" && $0.name=="Check flight" })
        try await transport.press(target:target,backendNodeID:XCTUnwrap(check.backendNodeID),document:afterFill,permit:BrowserMutationPermit())
        let matched=try await transport.wait(target:target,text:"UA 123 departs at 18:45",timeoutMS:2_000)
        XCTAssertTrue(matched)
        let result=try await transport.observe(target:target)
        XCTAssertTrue(result.nodes.contains { $0.name=="UA 123 departs at 18:45" })
        let clicks=try await script(view,"return window.clicks;")
        XCTAssertEqual(clicks,Data("1".utf8))
        let missing=try await transport.wait(target:target,text:"Does not exist",timeoutMS:20)
        XCTAssertFalse(missing)
    }

    func testUnicodeRoleOverByteLimitPreservesBoundedUsableObservation() async throws {
        let role=String(repeating:"界",count:40)
        XCTAssertLessThan(role.utf16.count,100)
        XCTAssertGreaterThan(role.utf8.count,100)
        let session=EmbeddedBrowserSession(persistent:false), transport=EmbeddedBrowserTabTransport(session:session)
        defer { session.shutdown() }
        let id=try session.createTab(), view=try XCTUnwrap(session.webView(for:id))
        view.frame=NSRect(x:0,y:0,width:1024,height:768)
        view.loadHTMLString("<button role='\(role)'>Unicode role</button><button>Continue</button>",baseURL:URL(string:"http://localhost:8123/role"))
        try await session.waitForHumanTabReady(id:id,until:.now + .seconds(10))
        let available=try await transport.target(id:id.uuidString)
        let target=try XCTUnwrap(available), observation=try await transport.observe(target:target)
        XCTAssertTrue(observation.sourceTruncated)
        let limited=try XCTUnwrap(observation.nodes.first { $0.name=="Unicode role" })
        XCTAssertEqual(limited.role,"generic")
        XCTAssertFalse(limited.isEditable)
        XCTAssertFalse(limited.isDOMClickable)
        XCTAssertTrue(observation.nodes.contains { $0.role=="button" && $0.name=="Continue" })
    }

    func testLowercaseExpansionOfRolePreservesOtherActionableControls() async throws {
        let role=String(repeating:"\u{0130}",count:40)
        XCTAssertLessThan(role.utf8.count,100)
        let session=EmbeddedBrowserSession(persistent:false), transport=EmbeddedBrowserTabTransport(session:session)
        defer { session.shutdown() }
        let id=try session.createTab(), view=try XCTUnwrap(session.webView(for:id))
        view.frame=NSRect(x:0,y:0,width:1024,height:768)
        view.loadHTMLString("<button role='\(role)'>Expanded role</button><button id='continue' onclick='window.clicks=(window.clicks||0)+1'>Continue</button>",baseURL:URL(string:"http://localhost:8123/role-expansion"))
        try await session.waitForHumanTabReady(id:id,until:.now + .seconds(10))
        let normalized=try await script(view,"return new TextEncoder().encode('\(role)'.toLowerCase()).length;")
        XCTAssertEqual(normalized,Data("120".utf8),"The real WebKit normalization exceeds the native role byte bound")
        let available=try await transport.target(id:id.uuidString)
        let target=try XCTUnwrap(available), observation=try await transport.observe(target:target)
        XCTAssertTrue(observation.sourceTruncated)
        let limited=try XCTUnwrap(observation.nodes.first { $0.name=="Expanded role" })
        XCTAssertEqual(limited.role,"generic")
        XCTAssertFalse(limited.isEditable)
        XCTAssertFalse(limited.isDOMClickable)
        let normal=try XCTUnwrap(observation.nodes.first { $0.role=="button" && $0.name=="Continue" })
        XCTAssertFalse(normal.isDisabled)
        XCTAssertTrue(normal.isDOMClickable)
        try await transport.press(target:target,backendNodeID:XCTUnwrap(normal.backendNodeID),document:observation,permit:BrowserMutationPermit())
        let clicks=try await script(view,"return window.clicks||0;")
        XCTAssertEqual(clicks,Data("1".utf8),"The oversized normalized role must not disable unrelated controls")
    }

    func testPrivateWorldResistsPageForgedIDsAndStaleNodeMetadata() async throws {
        let session=EmbeddedBrowserSession(persistent:false), transport=EmbeddedBrowserTabTransport(session:session)
        defer { session.shutdown() }
        let id=try session.createTab(), view=try XCTUnwrap(session.webView(for:id))
        view.frame=NSRect(x:0,y:0,width:1024,height:768)
        view.loadHTMLString(fixture,baseURL:URL(string:"http://localhost:8123/flight"))
        try await session.waitForHumanTabReady(id:id,until:.now + .seconds(10))
        let available=try await transport.target(id:id.uuidString)
        let target=try XCTUnwrap(available), observed=try await transport.observe(target:target)
        let button=try XCTUnwrap(observed.nodes.first { $0.role=="button" })
        _ = try await script(view,"globalThis.__computaBrowserControlV1={nodes:new Map(),documentToken:'forged'}; document.getElementById('check').textContent='Delete trip'; return true;")
        do { try await transport.press(target:target,backendNodeID:XCTUnwrap(button.backendNodeID),document:observed,permit:BrowserMutationPermit()); XCTFail("Changed control must not be dispatched") } catch { }
        let clicks=try await script(view,"return window.clicks||0;")
        XCTAssertEqual(clicks,Data("0".utf8))
        let fresh=try await transport.observe(target:target)
        XCTAssertTrue(fresh.nodes.contains { $0.name=="Delete trip" })
    }

    func testModelTabsExcludedAndOwnedTabStaysBackgroundAndUserTabCannotClose() async throws {
        let session=EmbeddedBrowserSession(persistent:false), transport=EmbeddedBrowserTabTransport(session:session)
        defer { session.shutdown() }
        let human=try session.createTab(), model=try session.createModelTab(url:XCTUnwrap(URL(string:"about:blank")))
        let tool=try session.createToolTab(url:XCTUnwrap(URL(string:"about:blank")))
        XCTAssertEqual(session.selectedTabID,human)
        let inventory=try await transport.humanTargets()
        XCTAssertTrue(inventory.contains { $0.targetID==tool.uuidString })
        XCTAssertFalse(inventory.contains { $0.targetID==model.uuidString })
        let modelTarget=try await transport.target(id:model.uuidString)
        XCTAssertNil(modelTarget)
        let existingTarget=try await transport.target(id:human.uuidString)
        let humanTarget=try XCTUnwrap(existingTarget)
        do { try await transport.closeTarget(target:humanTarget); XCTFail("Driver cannot close an existing human tab") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.ownershipMismatch) }
        XCTAssertNotNil(session.humanTab(id:human))
    }

    func testTaskOwnedRenderSurfaceReattachesAfterHumanPresentation() throws {
        let session=EmbeddedBrowserSession(persistent:false)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1024,height:768),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSView(frame:NSRect(x:0,y:0,width:1024,height:768)), presented=NSView(frame:host.frame)
        window.contentView=host
        session.installModelRenderHost(host)
        defer { session.shutdown(); window.close() }
        let id=try session.createToolTab(url:XCTUnwrap(URL(string:"about:blank"))), view=try XCTUnwrap(session.webView(for:id))
        XCTAssertNil(session.selectedTabID)
        XCTAssertTrue(view.superview===host)
        try session.presentTab(id,in:presented)
        XCTAssertTrue(view.superview===presented)
        session.detachPresentedTab(id,from:presented)
        XCTAssertTrue(view.superview===host)
        XCTAssertTrue(session.humanTabs.contains { $0.id==id })
    }

    func testIdenticalReplacementOverlayAndURLChangeCannotPressOldReference() async throws {
        let session=EmbeddedBrowserSession(persistent:false), transport=EmbeddedBrowserTabTransport(session:session)
        defer { session.shutdown() }
        let id=try session.createTab(), view=try XCTUnwrap(session.webView(for:id))
        view.frame=NSRect(x:0,y:0,width:1024,height:768)
        view.loadHTMLString(fixture,baseURL:URL(string:"http://localhost:8123/flight"))
        try await session.waitForHumanTabReady(id:id,until:.now + .seconds(10))
        let available=try await transport.target(id:id.uuidString), target=try XCTUnwrap(available)
        var observed=try await transport.observe(target:target)
        var button=try XCTUnwrap(observed.nodes.first { $0.name=="Check flight" })
        _ = try await script(view,"let old=document.getElementById('check'), clone=old.cloneNode(true); clone.onclick=()=>window.clicks=(window.clicks||0)+1; old.replaceWith(clone); return true;")
        do { try await transport.press(target:target,backendNodeID:XCTUnwrap(button.backendNodeID),document:observed,permit:BrowserMutationPermit()); XCTFail("Identical replacement cannot inherit the old identity") } catch { }
        observed=try await transport.observe(target:target)
        button=try XCTUnwrap(observed.nodes.first { $0.name=="Check flight" })
        _ = try await script(view,"let cover=document.createElement('div');cover.id='cover';cover.style='position:fixed;inset:0;z-index:99999;background:white';document.body.append(cover);return true;")
        do { try await transport.press(target:target,backendNodeID:XCTUnwrap(button.backendNodeID),document:observed,permit:BrowserMutationPermit()); XCTFail("Obstructed control must not dispatch") } catch { }
        _ = try await script(view,"document.getElementById('cover').remove();history.pushState({},'', '/changed');return true;")
        do { try await transport.press(target:target,backendNodeID:XCTUnwrap(button.backendNodeID),document:observed,permit:BrowserMutationPermit()); XCTFail("A changed URL requires a fresh read") } catch { }
        let clicks=try await script(view,"return window.clicks||0;")
        XCTAssertEqual(clicks,Data("0".utf8))
    }

    func testRevokedPermitAndFullNavigationNeverFillOrPressOldDocument() async throws {
        let session=EmbeddedBrowserSession(persistent:false), transport=EmbeddedBrowserTabTransport(session:session)
        defer { session.shutdown() }
        let id=try session.createTab(), view=try XCTUnwrap(session.webView(for:id))
        view.frame=NSRect(x:0,y:0,width:1024,height:768)
        view.loadHTMLString(fixture,baseURL:URL(string:"http://localhost:8123/flight"))
        try await session.waitForHumanTabReady(id:id,until:.now + .seconds(10))
        let available=try await transport.target(id:id.uuidString), target=try XCTUnwrap(available)
        let observed=try await transport.observe(target:target)
        let field=try XCTUnwrap(observed.nodes.first { $0.role=="textbox" && $0.name=="Flight number" })
        let permit=BrowserMutationPermit();permit.revoke()
        do { try await transport.setText(target:target,backendNodeID:XCTUnwrap(field.backendNodeID),text:"MUST_NOT_APPEAR",document:observed,permit:permit);XCTFail("Revoked permit must prevent actual WebKit dispatch") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        let value=try await script(view,"return document.getElementById('flight').value;")
        XCTAssertEqual(value,Data("\"\"".utf8))
        view.loadHTMLString(fixture,baseURL:URL(string:"http://localhost:8123/new-document"))
        try await session.waitForHumanTabReady(id:id,until:.now + .seconds(10))
        do { try await transport.setText(target:target,backendNodeID:XCTUnwrap(field.backendNodeID),text:"MUST_NOT_APPEAR",document:observed,permit:BrowserMutationPermit());XCTFail("Navigation retires old document references") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleDocument) }
        let fresh=try await transport.observe(target:target)
        XCTAssertNotEqual(fresh.loaderID,observed.loaderID)
        XCTAssertFalse(fresh.nodes.contains { $0.value=="MUST_NOT_APPEAR" })
    }

    private func script(_ view:WKWebView,_ source:String) async throws -> Data {
        // Fixture oracles and deliberate DOM changes are synchronous. Avoid an
        // unnecessary asynchronous-function lifetime for scalar return values;
        // execute once in the page world and propagate every actual failure.
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript("(function(){\n\(source)\n})();") { value,error in
                if let error { continuation.resume(throwing:error); return }
                do { let value=try XCTUnwrap(value); continuation.resume(returning:try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed])) }
                catch { continuation.resume(throwing:error) }
            }
        }
    }
}

import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

/// Real WebKit, isolated storage, synthetic page. No live provider/login state
/// or native global-input permission is involved in these backend checks.
@MainActor
final class EmbeddedBrowserTabTransportTests: XCTestCase {
    func testRealWebKitReadOnlyGridcellCannotSubstituteForItsSameLabelLink() async throws {
        let html = """
        <!doctype html><html><body><main>
        <div role="gridcell"><span role="link" tabindex="0" id="link"
          onclick="window.clicks=(window.clicks||0)+1;document.getElementById('result').textContent='Opened fixture';">Shared fixture title</span></div>
        <p id="result">Unopened fixture</p></main></body></html>
        """
        func reference(_ read: String, role: String) throws -> [String: Any] {
            let header = try XCTUnwrap(read.split(separator: "\n").first)
            let id = try XCTUnwrap(header.split(separator: " ").first { $0.hasPrefix("id=") })
            let row = try XCTUnwrap(read.split(separator: "\n").first {
                $0.hasPrefix("#") && $0.contains("semantic_role=\"\(role)\"")
            })
            let index = try XCTUnwrap(Int(row.dropFirst().prefix { $0.isNumber }))
            return ["snapshot_id": String(id.dropFirst(3)), "element_index": index]
        }
        for change in ["unchanged", "disabled", "replaced"] {
            let session = EmbeddedBrowserSession(persistent: false)
            let transport = EmbeddedBrowserTabTransport(session: session)
            let controller = EmbeddedBrowserToolController(transport: transport)
            defer { session.shutdown() }
            let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
            view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            view.loadHTMLString(html, baseURL: URL(string: "http://localhost:8123/grid-fixture"))
            try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
            _ = try await controller.execute(taskKey: "grid", tool: "browser_tabs", arguments: Data("{}".utf8))
            _ = try await controller.execute(taskKey: "grid", tool: "browser_bind",
                arguments: JSONSerialization.data(withJSONObject: ["tab_id": id.uuidString]))
            let content = try await controller.execute(taskKey: "grid", tool: "browser_read",
                arguments: Data(#"{"view":"content"}"#.utf8))
            let container = try reference(content, role: "gridcell")
            let row = try XCTUnwrap(content.split(separator: "\n").first { $0.contains("semantic_role=\"gridcell\"") })
            XCTAssertTrue(row.contains("actions=[]")); XCTAssertTrue(row.contains("enabled=true"))
            XCTAssertFalse(content.contains("semantic_role=\"link\""), "Content and action views are distinct")
            let containerData = try JSONSerialization.data(withJSONObject: container)
            do {
                try await controller.preflightMutation(taskKey: "grid", tool: "browser_click", arguments: containerData)
                XCTFail("An enabled content wrapper has no inherited press capability")
            } catch { XCTAssertEqual(error as? EmbeddedBrowserTools.MutationEligibilityFailure, .pressUnavailable) }
            do {
                _ = try await controller.execute(taskKey: "grid", tool: "browser_click", arguments: containerData)
                XCTFail("Direct execution must not retarget to the child")
            } catch { XCTAssertEqual(error as? EmbeddedBrowserTools.MutationEligibilityFailure, .pressUnavailable) }
            let deniedClicks = try await script(view, "return window.clicks || 0;")
            XCTAssertEqual(deniedClicks, Data("0".utf8))
            let links = try await controller.execute(taskKey: "grid", tool: "browser_read",
                arguments: Data(#"{"view":"links","query":"Shared fixture title"}"#.utf8))
            XCTAssertTrue(links.contains("actions=[\"AXPress\"]"))
            let linkData = try JSONSerialization.data(withJSONObject: reference(links, role: "link"))
            try await controller.preflightMutation(taskKey: "grid", tool: "browser_click", arguments: linkData)
            if change == "disabled" {
                _ = try await script(view, "document.getElementById('link').setAttribute('aria-disabled','true'); return true;")
            } else if change == "replaced" {
                _ = try await script(view, "let old=document.getElementById('link'); old.replaceWith(old.cloneNode(true)); return true;")
            }
            do {
                _ = try await controller.execute(taskKey: "grid", tool: "browser_click", arguments: linkData)
                XCTAssertEqual(change, "unchanged", "Approval cannot preserve changed physical semantics")
            } catch {
                XCTAssertNotEqual(change, "unchanged", "The actual same-label link should dispatch once")
                XCTAssertEqual(error as? BrowserTabBrokerError, change == "disabled" ? .elementChanged : .elementNotFound)
            }
            do {
                _ = try await controller.execute(taskKey: "grid", tool: "browser_click", arguments: linkData)
                XCTFail("An admitted mutation, including a rejected revalidation, cannot replay")
            } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
            let clicks = try await script(view, "return window.clicks || 0;")
            XCTAssertEqual(clicks, Data((change == "unchanged" ? "1" : "0").utf8))
            if change == "unchanged" {
                let result = try await controller.execute(taskKey: "grid", tool: "browser_read",
                    arguments: Data(#"{"view":"content"}"#.utf8))
                XCTAssertTrue(result.contains("Opened fixture"))
            }
            let cleanup = await controller.shutdown()
            XCTAssertTrue(cleanup.isEmpty)
            XCTAssertNotNil(session.webView(for: id), "The borrowed human fixture is preserved")
        }
    }

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

    private let popupFixture = """
    <!doctype html><html><body>
    <button id="sync">Open synchronous popup</button>
    <button id="deferred">Defer popup</button><p id="result">No popup requested</p>
    <script>
    document.getElementById('sync').onclick=()=>{
      window.syncClicks=(window.syncClicks||0)+1;
      window.syncPopupBlocked=!window.open('about:blank','tool-sync-popup');
      document.getElementById('result').textContent=window.syncPopupBlocked?'Synchronous popup blocked':'Synchronous popup opened';
    };
    document.getElementById('deferred').onclick=()=>{
      new Promise(resolve=>window.releasePopup=resolve).then(()=>{
        window.deferredPopupBlocked=!window.open('about:blank','tool-deferred-popup');
        document.getElementById('result').textContent=window.deferredPopupBlocked?'Deferred popup blocked':'Deferred popup opened';
      });
      document.getElementById('result').textContent='Deferred popup scheduled';
    };
    </script></body></html>
    """

    func testRealWebKitReadsFillsPressesAndWaitsForVisibleFlightResult() async throws {
        for iteration in 0..<10 {
            let session=EmbeddedBrowserSession(persistent:false), transport=EmbeddedBrowserTabTransport(session:session)
            defer { session.shutdown() }
            let id=try session.createTab(), view=try XCTUnwrap(session.webView(for:id))
            view.frame=NSRect(x:0,y:0,width:1024,height:768)
            view.loadHTMLString(fixture,baseURL:URL(string:"http://localhost:8123/flight"))
            var phase = "navigation"
            do {
                try await session.waitForHumanTabReady(id:id,until:.now + .seconds(10))
                phase = "target"
                let available=try await transport.target(id:id.uuidString)
                let target=try XCTUnwrap(available)
                phase = "observation"
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
                phase = "fill"
                try await transport.setText(target:target,backendNodeID:XCTUnwrap(field.backendNodeID),text:"UA 123",document:observed,permit:BrowserMutationPermit())
                phase = "filled_observation"
                let afterFill=try await transport.observe(target:target)
                XCTAssertEqual(afterFill.nodes.first { $0.backendNodeID==field.backendNodeID }?.value,"UA 123")
                let check=try XCTUnwrap(afterFill.nodes.first { $0.role=="button" && $0.name=="Check flight" })
                phase = "press"
                try await transport.press(target:target,backendNodeID:XCTUnwrap(check.backendNodeID),document:afterFill,permit:BrowserMutationPermit())
                phase = "result_wait"
                let matched=try await transport.wait(target:target,text:"UA 123 departs at 18:45",timeoutMS:2_000)
                XCTAssertTrue(matched)
                phase = "result_observation"
                let result=try await transport.observe(target:target)
                XCTAssertTrue(result.nodes.contains { $0.name=="UA 123 departs at 18:45" })
                phase = "click_oracle"
                let clicks=try await script(view,"return window.clicks;")
                XCTAssertEqual(clicks,Data("1".utf8))
                phase = "missing_result_wait"
                let missing=try await transport.wait(target:target,text:"Does not exist",timeoutMS:20)
                XCTAssertFalse(missing)
            } catch {
                let diagnostic = error as NSError
                print("embeddedFlightFixtureFailure iteration=\(iteration) phase=\(phase) domain=\(diagnostic.domain) code=\(diagnostic.code) detail=\(String(describing: error).prefix(512))")
                throw error
        }
        }
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

    func testRealWebKitPopupLinkIsReadableWithoutOfferingAnUndispatchablePress() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let transport = EmbeddedBrowserTabTransport(session: session)
        let controller = EmbeddedBrowserToolController(transport: transport)
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString("""
            <a href="/sign-in?return=%2Fmail%2F&amp;literal=A-B" target="_blank">Sign in</a>
            <a href="#ordinary" target="_self" onclick="event.preventDefault();window.clicks=(window.clicks||0)+1">Continue</a>
            """, baseURL: URL(string: "http://localhost:8123/popup-links"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        _ = try await controller.execute(taskKey: "popup-link", tool: "browser_tabs", arguments: Data("{}".utf8))
        _ = try await controller.execute(taskKey: "popup-link", tool: "browser_bind",
            arguments: JSONSerialization.data(withJSONObject: ["tab_id": id.uuidString]))
        let read = try await controller.execute(taskKey: "popup-link", tool: "browser_read",
            arguments: Data(#"{"view":"links"}"#.utf8))
        let popup = try XCTUnwrap(read.split(separator: "\n").first { $0.contains("label=\"Sign in\"") })
        let ordinary = try XCTUnwrap(read.split(separator: "\n").first { $0.contains("label=\"Continue\"") })
        XCTAssertTrue(popup.contains("href=\"http://localhost:8123/sign-in?return=%2Fmail%2F&literal=A-B\""))
        XCTAssertTrue(popup.contains("enabled=true")); XCTAssertTrue(popup.contains("actions=[]"))
        XCTAssertFalse(popup.contains("follow_link=true"))
        XCTAssertTrue(ordinary.contains("actions=[\"AXPress\"]")); XCTAssertTrue(ordinary.contains("follow_link=true"))
        let header = try XCTUnwrap(read.split(separator: "\n").first)
        let snapshot = try XCTUnwrap(header.split(separator: " ").first { $0.hasPrefix("id=") })
        func arguments(_ row: Substring) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["snapshot_id": String(snapshot.dropFirst(3)),
                "element_index": try XCTUnwrap(Int(row.dropFirst().prefix { $0.isNumber }))])
        }
        do {
            _ = try await controller.execute(taskKey: "popup-link", tool: "browser_click", arguments: arguments(popup))
            XCTFail("A popup-only link is read-only before any backend input")
        } catch { XCTAssertEqual(error as? EmbeddedBrowserTools.MutationEligibilityFailure, .pressUnavailable) }
        XCTAssertEqual(session.humanTabs.count, 1)
        _ = try await controller.execute(taskKey: "popup-link", tool: "browser_click", arguments: arguments(ordinary))
        let clicks = try await script(view, "return window.clicks || 0;")
        XCTAssertEqual(clicks, Data("1".utf8), "Rejecting the popup-only press preserves the read for a supported action")
        _ = await controller.shutdown()
    }

    func testRealWebKitReadWaitsForSemanticDOMWithoutTreatingItsTitleAsContent() async throws {
        let (session, transport, view, target) = try await semanticReadinessFixture()
        defer { session.shutdown() }
        let generation = session.documentGeneration(for: try XCTUnwrap(UUID(uuidString: target.targetID)))
        let pending = Task { try await transport.observe(target: target) }
        try await waitForSemanticObserver(view)
        _ = try await script(view, "const p=document.createElement('p');p.textContent='Rendered fixture content';document.body.appendChild(p);return true;")
        let observed = try await pending.value
        XCTAssertEqual(observed.semanticReadiness, .ready)
        XCTAssertTrue(observed.nodes.contains { $0.role == "statictext" && $0.name == "Rendered fixture content" })
        XCTAssertEqual(observed.loaderID, generation?.uuidString)
        XCTAssertEqual(observed.title, "Outlook")
    }

    func testSemanticReadinessNavigationContextFailureRemainsAStaleRead() async throws {
        let (session, transport, view, target) = try await semanticReadinessFixture()
        defer { session.shutdown() }
        let pending = Task { try await transport.observe(target: target) }
        try await waitForSemanticObserver(view)
        let id = try XCTUnwrap(UUID(uuidString: target.targetID))
        try session.navigate(tabID: id, to: XCTUnwrap(URL(string: "about:blank")))
        do { _ = try await pending.value; XCTFail("The old document cannot publish after navigation destroys its context") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleDocument) }
        XCTAssertTrue(session.webView(for: id) === view)
    }

    func testSemanticReadinessCannotPublishAfterCancellationOrTabClosure() async throws {
        for closed in [false, true] {
            let (session, transport, view, target) = try await semanticReadinessFixture()
            let pending = Task { try await transport.observe(target: target) }
            try await waitForSemanticObserver(view)
            let id = try XCTUnwrap(UUID(uuidString: target.targetID))
            if closed { session.closeTab(id) } else { pending.cancel() }
            // Release the synthetic DOM wait too; its late result cannot revive
            // a canceled continuation or this never-reused closed tab identity.
            _ = try? await script(view, "const p=document.createElement('p');p.textContent='Late fixture content';document.body.appendChild(p);return true;")
            do { _ = try await pending.value; XCTFail("Retired read cannot publish content") }
            catch {
                if closed { XCTAssertEqual(error as? BrowserTabBrokerError, .targetClosed) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            session.shutdown()
        }
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

    func testBorrowedToolMutationRejectsSynchronousAndPostCleanupDeferredPopupsWithoutSelectingOrphans() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let transport = EmbeddedBrowserTabTransport(session: session)
        defer { session.shutdown() }
        let id = try session.createTab(select: false), selected = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString(popupFixture, baseURL: URL(string: "http://localhost:8123/tool-popup"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString)
        let target = try XCTUnwrap(available)
        let observation = try await transport.observe(target: target)
        let button = try XCTUnwrap(observation.nodes.first { $0.name == "Open synchronous popup" })
        do {
            try await transport.press(target: target, backendNodeID: XCTUnwrap(button.backendNodeID),
                                      document: observation, permit: BrowserMutationPermit())
            XCTFail("A synchronously rejected popup must produce the native no-replay diagnostic")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pop-up was blocked"))
            XCTAssertTrue(error.localizedDescription.contains("No replay is allowed"))
        }
        let synchronous = try await script(view, "return window.syncPopupBlocked;")
        XCTAssertEqual(synchronous, Data("true".utf8))
        XCTAssertEqual(session.tabs.map(\.id), [id, selected])
        XCTAssertEqual(session.selectedTabID, selected)
        XCTAssertNil(session.humanTab(id: id)?.error)

        let fresh = try await transport.observe(target: target)
        let deferred = try XCTUnwrap(fresh.nodes.first { $0.name == "Defer popup" })
        let permit = BrowserMutationPermit()
        try await transport.press(target: target, backendNodeID: XCTUnwrap(deferred.backendNodeID),
                                  document: fresh, permit: permit)
        permit.revoke()
        let cleanup = await transport.closeOwnedTargets()
        XCTAssertTrue(cleanup.isEmpty)
        session.stop(tabID: id)
        // Release the page callback only after the action, permit retirement,
        // cleanup and Stop. No timer race can make this an already-open child.
        _ = try await script(view, "window.releasePopup(); return true;")
        let matched = try await transport.wait(target: target, text: "Deferred popup blocked", timeoutMS: 2_000)
        XCTAssertTrue(matched)
        let late = try await script(view, "return window.deferredPopupBlocked;")
        XCTAssertEqual(late, Data("true".utf8))
        XCTAssertEqual(session.tabs.map(\.id), [id, selected])
        XCTAssertEqual(session.selectedTabID, selected)
        XCTAssertNil(session.humanTab(id: id)?.error)
        let after = try await transport.observe(target: target)
        XCTAssertTrue(after.nodes.contains { $0.name == "Deferred popup blocked" })
    }

    func testRevokedToolPermitPreservesAsyncHumanPopupPolicyAndSharedProfile() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let transport = EmbeddedBrowserTabTransport(session: session)
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString(popupFixture, baseURL: URL(string: "http://localhost:8123/denied-popup"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString)
        let target = try XCTUnwrap(available)
        let observation = try await transport.observe(target: target)
        let button = try XCTUnwrap(observation.nodes.first { $0.name == "Open synchronous popup" })
        let permit = BrowserMutationPermit()
        permit.revoke()
        do {
            try await transport.press(target: target, backendNodeID: XCTUnwrap(button.backendNodeID),
                                      document: observation, permit: permit)
            XCTFail("A denied permit must not dispatch the button or change the document popup policy")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let clicks = try await script(view, "return window.syncClicks || 0;")
        XCTAssertEqual(clicks, Data("0".utf8))
        try await assertAsyncHumanPopup(session: session, transport: transport, target: target, opener: view)
    }

    func testCommittedReplacementDocumentRestoresAsyncHumanPopupPolicy() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let transport = EmbeddedBrowserTabTransport(session: session)
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString(popupFixture, baseURL: URL(string: "http://localhost:8123/old-popup-document"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString)
        let target = try XCTUnwrap(available)
        let observation = try await transport.observe(target: target)
        let button = try XCTUnwrap(observation.nodes.first { $0.name == "Open synchronous popup" })
        do {
            try await transport.press(target: target, backendNodeID: XCTUnwrap(button.backendNodeID),
                                      document: observation, permit: BrowserMutationPermit())
            XCTFail("The original document's tool popup must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("pop-up was blocked")) }
        let generation = try XCTUnwrap(session.documentGeneration(for: id))
        let deadline = ContinuousClock.now + .seconds(10)
        view.loadHTMLString(popupFixture, baseURL: URL(string: "http://localhost:8123/replacement-popup-document"))
        // An existing tab is ready until WebKit starts this load. Observe that
        // transition before using its ordinary committed-load readiness gate.
        while session.documentGeneration(for: id) == generation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await session.waitForHumanTabReady(id: id, until: deadline)
        XCTAssertNotEqual(session.documentGeneration(for: id), generation)
        try await assertAsyncHumanPopup(session: session, transport: transport, target: target, opener: view)
    }

    private func assertAsyncHumanPopup(session: EmbeddedBrowserSession, transport: EmbeddedBrowserTabTransport,
                                      target: BrowserTarget, opener: WKWebView) async throws {
        _ = try await script(opener, """
        setTimeout(()=>{
          window.humanPopup=window.open('about:blank','human-oauth-popup');
          document.getElementById('result').textContent=window.humanPopup?'Human popup ready':'Human popup blocked';
        },0);
        return true;
        """)
        let matched = try await transport.wait(target: target, text: "Human popup ready", timeoutMS: 2_000)
        XCTAssertTrue(matched)
        let child = try XCTUnwrap(session.tabs.first { $0.id.uuidString != target.targetID })
        let childView = try XCTUnwrap(session.webView(for: child.id))
        XCTAssertTrue(child.isPopup)
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertEqual(session.selectedTabID, child.id)
        XCTAssertTrue(childView.configuration.websiteDataStore === opener.configuration.websiteDataStore)
        let usable = try await script(opener, "return !!window.humanPopup && !window.humanPopup.closed && window.humanPopup.opener === window;")
        XCTAssertEqual(usable, Data("true".utf8))
        session.closeTab(child.id)
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.selectedTabID?.uuidString, target.targetID)
        let openerID = try XCTUnwrap(UUID(uuidString: target.targetID))
        XCTAssertTrue(session.webView(for: openerID) === opener)
        XCTAssertNil(session.humanTab(id: openerID)?.error)
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

    private func semanticReadinessFixture() async throws -> (EmbeddedBrowserSession, EmbeddedBrowserTabTransport, WKWebView, BrowserTarget) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resource = root.appendingPathComponent("Sources/Computa/Resources/BrowserModels/browser-control.js")
        let source = try String(contentsOf: resource, encoding: .utf8)
        let registration = "observer.observe(document, {subtree:true,childList:true,characterData:true,attributes:true});"
        XCTAssertEqual(source.components(separatedBy: registration).count, 2)
        // A fixture-only DOM signal lets the test await actual observer
        // registration, without timing sleeps or polling either WebView.
        let instrumented = source.replacingOccurrences(of: registration, with:
            registration + "\ndocument.documentElement.setAttribute('data-computa-readiness-test-armed','yes');")
        let session = EmbeddedBrowserSession(persistent: false)
        let transport = EmbeddedBrowserTabTransport(session: session, script: instrumented)
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString("<!doctype html><title>Outlook</title><body><main aria-label='Outlook'></main></body>",
                            baseURL: URL(string: "http://localhost:8123/semantic-readiness"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString)
        return (session, transport, view, try XCTUnwrap(available))
    }

    private func waitForSemanticObserver(_ view: WKWebView) async throws {
        let source = """
        if(document.documentElement.getAttribute('data-computa-readiness-test-armed')==='yes')return true;
        return await new Promise((resolve,reject)=>{
          const observer=new MutationObserver(changed);
          const timer=setTimeout(()=>{observer.disconnect();reject(new Error('Fixture observer did not arm'));},5000);
          function changed(){if(document.documentElement.getAttribute('data-computa-readiness-test-armed')==='yes'){
            observer.disconnect();clearTimeout(timer);resolve(true);}}
          observer.observe(document,{subtree:true,attributes:true,childList:true});changed();
        });
        """
        let matched = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { reply in
                do { continuation.resume(returning: try XCTUnwrap(reply.get() as? Bool)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        XCTAssertTrue(matched)
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

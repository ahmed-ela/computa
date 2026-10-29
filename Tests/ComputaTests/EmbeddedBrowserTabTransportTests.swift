import AppKit
import AutomationCore
import Foundation
import Network
import WebKit
import XCTest
@testable import Computa

/// Real WebKit, isolated storage, synthetic page. No live provider/login state
/// or native global-input permission is involved in these backend checks.
@MainActor
final class EmbeddedBrowserTabTransportTests: XCTestCase {
    func testHitTestDiagnosticClosedSchemaRelationshipsAndLegacyCompatibility() throws {
        let valid: [String: Any] = ["reason":"foreign_hit", "centerX":"inside", "centerY":"inside", "hitTag":"div", "hitRole":"listbox", "relation":"other"]
        func envelope(_ hit: Any, stage: String = "initial_hit_test", code: String = "element_obstructed") -> [String: Any] {
            ["browserActionFailure":["version":1,"operation":"fill","stage":stage,"code":code,"hitTest":hit]]
        }
        let shapes: [[String: Any]] = [
            valid,
            ["reason":"rect_nonfinite","centerX":"unknown","centerY":"inside","hitTag":"none","hitRole":"none","relation":"none"],
            ["reason":"rect_nonpositive","centerX":"inside","centerY":"inside","hitTag":"input","hitRole":"textbox","relation":"self"],
            ["reason":"outside_viewport","centerX":"before","centerY":"inside","hitTag":"none","hitRole":"none","relation":"none"],
            ["reason":"null_hit","centerX":"inside","centerY":"inside","hitTag":"none","hitRole":"none","relation":"none"]
        ]
        for shape in shapes { XCTAssertNotNil(BrowserActionFailureDiagnostic.decode(envelope(shape), operation: "fill")) }
        XCTAssertNotNil(BrowserActionFailureDiagnostic.decode(envelope(valid, stage:"focused_hit_test"), operation:"fill"))
        for stage in ["initial_revalidation", "focus", "value_write"] {
            XCTAssertNil(BrowserActionFailureDiagnostic.decode(envelope(valid,stage:stage),operation:"fill"))
        }
        XCTAssertNil(BrowserActionFailureDiagnostic.decode(envelope(valid,code:"unexpected"),operation:"fill"))
        for key in valid.keys {
            for bad in ["PRIVATE_CANARY", 1, true, NSNull()] as [Any] {
                var invalid=valid; invalid[key]=bad
                XCTAssertNil(BrowserActionFailureDiagnostic.decode(envelope(invalid),operation:"fill"),key)
            }
            var missing=valid;missing.removeValue(forKey:key)
            XCTAssertNil(BrowserActionFailureDiagnostic.decode(envelope(missing),operation:"fill"),key)
        }
        for alteration: [String: Any] in [["hitTag":"none"], ["relation":"none"], ["relation":"self"], ["relation":"descendant"],
                                        ["reason":"null_hit"], ["reason":"outside_viewport"], ["text":"PRIVATE_CANARY"], ["rect":[1,2,3,4]]] {
            var invalid=valid;invalid.merge(alteration){ _,new in new }
            XCTAssertNil(BrowserActionFailureDiagnostic.decode(envelope(invalid),operation:"fill"))
        }
        XCTAssertNil(BrowserActionFailureDiagnostic.decode(envelope(NSNull()),operation:"fill"))
        let legacy: [String: Any] = ["browserActionFailure":["version":1,"operation":"fill","stage":"initial_hit_test","code":"element_obstructed"]]
        let old = try XCTUnwrap(BrowserActionFailureDiagnostic.decode(legacy,operation:"fill"))
        XCTAssertNil(old.hitTest)
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil(oldJSON["hitTest"], "Legacy logs retain their exact key set")
        let maximum = BrowserActionFailureDiagnostic(operation:.fill,stage:.focusedHitTest,code:.elementObstructed,
            hitTest:.init(reason:.rectNonpositive,centerX:.unknown,centerY:.unknown,hitTag:.textarea,hitRole:.alertdialog,relation:.descendant))
        let bytes = try JSONEncoder().encode(BrowserActionFailureLogRecord(tabID:UUID(),generation:UUID(),failure:maximum))
        XCTAssertLessThanOrEqual(bytes.count,512)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("PRIVATE"))
        print("browserHitTestMaximumEncoding bytes=\(bytes.count)")
    }

    func testHitTestDiagnosticFindsRecipientOverlayBeforeSubjectFocus() async throws {
        let body = """
            <input id='recipient' aria-label='Recipients' style='position:fixed;left:20px;top:20px;width:200px;height:24px'>
            <input id='subject' aria-label='Subject' style='position:fixed;left:20px;top:80px;width:200px;height:24px'>
            <script>window.inputs=0;window.changes=0;window.subjectFocuses=0;
            document.addEventListener('input',()=>window.inputs++);document.addEventListener('change',()=>window.changes++);
            document.getElementById('subject').addEventListener('focus',()=>window.subjectFocuses++);
            document.getElementById('recipient').addEventListener('input',()=>{
              const cover=document.createElement('div');cover.id='cover';cover.setAttribute('role','listbox');
              cover.style='position:fixed;left:20px;top:80px;width:220px;height:36px;z-index:999;background:white';document.body.append(cover);
            });</script>
            """
        let (session,transport,view,target) = try await semanticReadinessFixture(body:body)
        let window=attachRenderHost(to:session);defer { session.shutdown();window.close() }
        let lifetime=BrowserTabLifetime();try await transport.acquireRendering(target:target,lifetime:lifetime)
        let first=try await transport.observe(target:target)
        let recipient=try XCTUnwrap(first.nodes.first { $0.name=="Recipients" })
        try await transport.setText(target:target,backendNodeID:XCTUnwrap(recipient.backendNodeID),text:"synthetic@example.test",document:first,permit:BrowserMutationPermit())
        let fresh=try await transport.observe(target:target)
        let subject=try XCTUnwrap(fresh.nodes.first { $0.name=="Subject" })
        XCTAssertTrue(subject.isEditable);XCTAssertFalse(subject.isDisabled)
        let oracle=try await script(view,"const r=document.getElementById('subject').getBoundingClientRect();return document.elementFromPoint(r.left+r.width/2,r.top+r.height/2).id;")
        XCTAssertEqual(oracle,Data("\"cover\"".utf8))
        try await assertHitTestRejection(transport,target:target,field:subject,document:fresh,stage:.initialHitTest,
            reason:.foreignHit,tag:.div,role:.listbox,relation:.other,x:.inside,y:.inside)
        let state=try await script(view,"return {value:document.getElementById('subject').value,focus:window.subjectFocuses,inputs:window.inputs,changes:window.changes,active:document.activeElement.id};")
        let fields=try XCTUnwrap(JSONSerialization.jsonObject(with:state) as? [String:Any])
        XCTAssertEqual(fields["value"] as? String,"");XCTAssertEqual(fields["focus"] as? Int,0)
        XCTAssertEqual(fields["inputs"] as? Int,1);XCTAssertEqual(fields["changes"] as? Int,1)
        XCTAssertEqual(fields["active"] as? String,"recipient")
        lifetime.revoke();await transport.releaseRendering(target:target,lifetime:lifetime)
    }

    func testHitTestDiagnosticClassifiesFixedOffscreenFieldWithoutFocusing() async throws {
        let body="""
            <input id='field' aria-label='Subject' style='position:fixed;left:-2048px;top:40px;width:200px;height:24px'>
            <script>window.focuses=0;window.inputs=0;document.getElementById('field').addEventListener('focus',()=>window.focuses++);document.addEventListener('input',()=>window.inputs++);</script>
            """
        let (session,transport,view,target)=try await semanticReadinessFixture(body:body)
        let window=attachRenderHost(to:session);defer { session.shutdown();window.close() }
        let lifetime=BrowserTabLifetime();try await transport.acquireRendering(target:target,lifetime:lifetime)
        let observed=try await transport.observe(target:target)
        let field=try XCTUnwrap(observed.nodes.first { $0.name=="Subject" })
        XCTAssertTrue(field.isEditable)
        try await assertHitTestRejection(transport,target:target,field:field,document:observed,stage:.initialHitTest,
            reason:.outsideViewport,tag:.none,role:.none,relation:.none,x:.before,y:.inside)
        let effects=try await script(view,"return {value:document.getElementById('field').value,focus:window.focuses,input:window.inputs};")
        let fields=try XCTUnwrap(JSONSerialization.jsonObject(with:effects) as? [String:Any])
        XCTAssertEqual(fields["value"] as? String,"");XCTAssertEqual(fields["focus"] as? Int,0);XCTAssertEqual(fields["input"] as? Int,0)
        lifetime.revoke();await transport.releaseRendering(target:target,lifetime:lifetime)
    }

    func testHitTestDiagnosticRetainsSecondGuardAfterFocusCreatesOverlay() async throws {
        let body="""
            <input id='field' aria-label='Subject' style='position:fixed;left:20px;top:80px;width:200px;height:24px'>
            <script>window.focuses=0;window.inputs=0;window.changes=0;
            document.addEventListener('input',()=>window.inputs++);document.addEventListener('change',()=>window.changes++);
            document.getElementById('field').addEventListener('focus',()=>{window.focuses++;
              const cover=document.createElement('div');cover.setAttribute('role','tooltip');
              cover.style='position:fixed;left:20px;top:80px;width:220px;height:36px;z-index:999;background:white';document.body.append(cover);
            });</script>
            """
        let (session,transport,view,target)=try await semanticReadinessFixture(body:body)
        let window=attachRenderHost(to:session);defer { session.shutdown();window.close() }
        let lifetime=BrowserTabLifetime();try await transport.acquireRendering(target:target,lifetime:lifetime)
        let observed=try await transport.observe(target:target)
        let field=try XCTUnwrap(observed.nodes.first { $0.name=="Subject" })
        try await assertHitTestRejection(transport,target:target,field:field,document:observed,stage:.focusedHitTest,
            reason:.foreignHit,tag:.div,role:.tooltip,relation:.other,x:.inside,y:.inside)
        let effects=try await script(view,"return {value:document.getElementById('field').value,focus:window.focuses,input:window.inputs,change:window.changes};")
        let fields=try XCTUnwrap(JSONSerialization.jsonObject(with:effects) as? [String:Any])
        XCTAssertEqual(fields["value"] as? String,"");XCTAssertEqual(fields["focus"] as? Int,1)
        XCTAssertEqual(fields["input"] as? Int,0);XCTAssertEqual(fields["change"] as? Int,0)
        lifetime.revoke();await transport.releaseRendering(target:target,lifetime:lifetime)
    }

    private func assertHitTestRejection(_ transport:EmbeddedBrowserTabTransport,target:BrowserTarget,field:BrowserDocumentNode,
        document:BrowserDocumentObservation,stage:BrowserActionFailureDiagnostic.Stage,reason:BrowserActionFailureDiagnostic.HitTest.Reason,
        tag:BrowserActionFailureDiagnostic.HitTest.Tag,role:BrowserActionFailureDiagnostic.HitTest.Role,
        relation:BrowserActionFailureDiagnostic.HitTest.Relation,x:BrowserActionFailureDiagnostic.HitTest.Axis,y:BrowserActionFailureDiagnostic.HitTest.Axis,
        file:StaticString = #filePath,line:UInt = #line) async throws {
        do {
            try await transport.setText(target:target,backendNodeID:XCTUnwrap(field.backendNodeID),text:"MUST_NOT_APPEAR",document:document,permit:BrowserMutationPermit())
            XCTFail("The hit-test guard must retain its original rejection",file:file,line:line)
        } catch {
            XCTAssertEqual(error as? BrowserTabBrokerError,.browserUnavailable("The built-in action could not be confirmed. No replay is allowed; read the page before deciding what to do next."),file:file,line:line)
        }
        let diagnostic=try XCTUnwrap(transport.actionFailureDiagnosticForTesting,file:file,line:line)
        XCTAssertEqual(diagnostic.stage,stage,file:file,line:line);XCTAssertEqual(diagnostic.code,.elementObstructed,file:file,line:line)
        let hit=try XCTUnwrap(diagnostic.hitTest,file:file,line:line)
        XCTAssertEqual(hit.reason,reason,file:file,line:line);XCTAssertEqual(hit.hitTag,tag,file:file,line:line)
        XCTAssertEqual(hit.hitRole,role,file:file,line:line);XCTAssertEqual(hit.relation,relation,file:file,line:line)
        XCTAssertEqual(hit.centerX,x,file:file,line:line);XCTAssertEqual(hit.centerY,y,file:file,line:line)
        let log=try JSONEncoder().encode(BrowserActionFailureLogRecord(tabID:UUID(),generation:UUID(),failure:diagnostic))
        XCTAssertLessThanOrEqual(log.count,512,file:file,line:line)
        XCTAssertFalse(String(decoding:log,as:UTF8.self).contains("MUST_NOT_APPEAR"),file:file,line:line)
    }

    func testActionFailureDiagnosticStrictFiniteEnvelopeAndBoundedEncoding() throws {
        let pressOnly: Set<BrowserActionFailureDiagnostic.Stage> = [.pressPrecheck, .pressDispatch, .constraintFeedback]
        let fillOnly: Set<BrowserActionFailureDiagnostic.Stage> = [.focus, .focusedRevalidation, .focusConfirmation, .focusedHitTest, .valueWrite, .inputEvent, .changeEvent]
        var maximum = 0
        for operation in BrowserActionFailureDiagnostic.Operation.allCases {
            for stage in BrowserActionFailureDiagnostic.Stage.allCases where stage != .unknown {
                for code in BrowserActionFailureDiagnostic.Code.allCases {
                    let fields: [String: Any] = ["version": 1, "operation": operation.rawValue, "stage": stage.rawValue, "code": code.rawValue]
                    let decoded = BrowserActionFailureDiagnostic.decode(["browserActionFailure": fields], operation: operation.rawValue)
                    if operation == .press ? fillOnly.contains(stage) : pressOnly.contains(stage) {
                        XCTAssertNil(decoded); continue
                    }
                    let valid = try XCTUnwrap(decoded)
                    XCTAssertEqual(valid.operation, operation); XCTAssertEqual(valid.stage, stage); XCTAssertEqual(valid.code, code)
                    let record = BrowserActionFailureLogRecord(tabID: UUID(), generation: UUID(), failure: valid)
                    let bytes = try JSONEncoder().encode(record); maximum = max(maximum, bytes.count)
                    XCTAssertLessThanOrEqual(bytes.count, 512)
                    let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    XCTAssertEqual(Set(outer.keys), ["kind", "tabID", "generation", "failure"])
                    XCTAssertEqual(outer["kind"] as? String, "browser_action_failure_v1")
                }
            }
        }
        let valid: [String: Any] = ["version": 1, "operation": "fill", "stage": "focused_revalidation", "code": "element_changed"]
        for (key, value) in [("version", true as Any), ("version", 1.5 as Any), ("version", "1" as Any),
                             ("operation", "PRIVATE_CANARY" as Any), ("stage", "PRIVATE_CANARY" as Any),
                             ("stage", "unknown" as Any), ("stage", "press_dispatch" as Any),
                             ("code", "PRIVATE_CANARY" as Any), ("code", NSNull() as Any), ("text", "PRIVATE_CANARY" as Any)] {
            var bad = valid; bad[key] = value
            XCTAssertNil(BrowserActionFailureDiagnostic.decode(["browserActionFailure": bad], operation: "fill"), key)
        }
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertNil(BrowserActionFailureDiagnostic.decode(["browserActionFailure": missing], operation: "fill"), key)
        }
        XCTAssertNil(BrowserActionFailureDiagnostic.decode(["browserActionFailure": valid, "dispatched": true], operation: "fill"))
        XCTAssertNil(BrowserActionFailureDiagnostic.decode(["browserActionFailure": valid], operation: "press"))
        XCTAssertNil(BrowserActionFailureDiagnostic.decode(["browserActionFailure": valid], operation: "PRIVATE_CANARY"))
        XCTAssertNil(BrowserActionFailureDiagnostic.decode(["browserActionFailure": NSNull()], operation: "fill"))
        print("browserActionFailureMaximumEncoding bytes=\(maximum)")
    }

    func testActionFailureEnvelopeKeepsUnknownDispatchAndNeverLeaksPrivateErrors() async throws {
        let known = "return {browserActionFailure:{version:1,operation:'fill',stage:'input_event',code:'unexpected'}};"
        let cases = [
            ("before", known, "", BrowserActionFailureDiagnostic.Stage.inputEvent),
            ("after", "document.getElementById('field').value='PRIVATE_WRITTEN_VALUE';" + known, "PRIVATE_WRITTEN_VALUE", .inputEvent),
            ("malformed", "return {browserActionFailure:{version:1,operation:'fill',stage:'PRIVATE_STAGE',code:'PRIVATE_ERROR',text:'PRIVATE_TEXT'}};", "", .unknown),
            ("mixed_success", "return {dispatched:true,browserActionFailure:{version:1,operation:'fill',stage:'input_event',code:'unexpected'}};", "", .unknown),
            ("exception", "throw new Error('PRIVATE_ERROR_WITH_EMAIL_AND_SECRET');", "", .unknown)
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Computa/Resources/BrowserModels/browser-control.js"), encoding: .utf8)
        for (name, statement, expectedValue, expectedStage) in cases {
            let (session, _, view, target) = try await semanticReadinessFixture(body: "<input id='field' aria-label='Subject'>")
            defer { session.shutdown() }
            let transport = EmbeddedBrowserTabTransport(session: session, script: "if(input.operation==='fill'){\(statement)}\n" + source)
            let observation = try await transport.observe(target: target)
            let field = try XCTUnwrap(observation.nodes.first { $0.name == "Subject" })
            do {
                try await transport.setText(target: target, backendNodeID: XCTUnwrap(field.backendNodeID), text: "PRIVATE_REQUESTED_VALUE",
                                         document: observation, permit: BrowserMutationPermit())
                XCTFail("A driver failure must never return an input receipt: \(name)")
            } catch {
                XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("The built-in action could not be confirmed. No replay is allowed; read the page before deciding what to do next."), name)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE_"), name)
                XCTAssertFalse(error.localizedDescription.contains("not dispatched"), name)
            }
            let diagnostic = try XCTUnwrap(transport.actionFailureDiagnosticForTesting)
            XCTAssertEqual(diagnostic.operation, .fill); XCTAssertEqual(diagnostic.stage, expectedStage)
            XCTAssertEqual(diagnostic.code, .unexpected)
            let log = try JSONEncoder().encode(BrowserActionFailureLogRecord(tabID: UUID(), generation: UUID(), failure: diagnostic))
            XCTAssertLessThanOrEqual(log.count, 512)
            XCTAssertFalse(String(decoding: log, as: UTF8.self).contains("PRIVATE_"))
            let value = try await script(view, "return document.getElementById('field').value;")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed]) as? String, expectedValue,
                           "The same unconfirmed error applies both before and after an actual value write: \(name)")
        }
    }

    func testActionFailureDiagnosticIdentifiesRevalidationBeforeAndAfterFocus() async throws {
        for focused in [false, true] {
            let body = """
                <input id='field' aria-label='Subject'><script>
                window.focusEvents=0;window.inputEvents=0;
                document.getElementById('field').addEventListener('focus',()=>{
                  window.focusEvents++;\(focused ? "document.getElementById('field').setAttribute('aria-label','Changed subject');" : "")
                });
                document.addEventListener('input',()=>window.inputEvents++);
                </script>
                """
            let (session, transport, view, target) = try await semanticReadinessFixture(body: body)
            defer { session.shutdown() }
            let observed = try await transport.observe(target: target)
            let field = try XCTUnwrap(observed.nodes.first { $0.name == "Subject" })
            if !focused { _ = try await script(view, "document.getElementById('field').setAttribute('aria-label','Changed subject');return true;") }
            do {
                try await transport.setText(target: target, backendNodeID: XCTUnwrap(field.backendNodeID), text: "PRIVATE_REQUESTED_VALUE",
                                         document: observed, permit: BrowserMutationPermit())
                XCTFail("Changed field metadata must still reject")
            } catch {
                XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("The built-in action could not be confirmed. No replay is allowed; read the page before deciding what to do next."))
            }
            let diagnostic = try XCTUnwrap(transport.actionFailureDiagnosticForTesting)
            XCTAssertEqual(diagnostic.stage, focused ? .focusedRevalidation : .initialRevalidation)
            XCTAssertEqual(diagnostic.code, .elementChanged)
            let state = try await script(view, "return {value:document.getElementById('field').value,focus:window.focusEvents,input:window.inputEvents};")
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: state) as? [String: Any])
            XCTAssertEqual(fields["value"] as? String, ""); XCTAssertEqual(fields["input"] as? Int, 0)
            XCTAssertEqual(fields["focus"] as? Int, focused ? 1 : 0)
        }
    }

    func testOpposingPriorityDialogBeforeFormRetainsControlsAndExpandedFields() async throws {
        try await verifyOpposingPriorityPanel(dialog: true, panelFirst: true)
    }

    func testOpposingPriorityDialogAfterFormRetainsControlsAndExpandedFields() async throws {
        try await verifyOpposingPriorityPanel(dialog: true, panelFirst: false)
    }

    func testOpposingPriorityNamedPanelBeforeFormRetainsControlsAndExpandedFields() async throws {
        try await verifyOpposingPriorityPanel(dialog: false, panelFirst: true)
    }

    func testOpposingPriorityNamedPanelAfterFormRetainsControlsAndExpandedFields() async throws {
        try await verifyOpposingPriorityPanel(dialog: false, panelFirst: false)
    }

    private func verifyOpposingPriorityPanel(dialog: Bool, panelFirst: Bool) async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let window = attachRenderHost(to: session)
        defer { session.shutdown(); window.close() }
        let transport = EmbeddedBrowserTabTransport(session: session)
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        let paragraphs = (0..<300).map { "<p>Synthetic record \($0): \(String(repeating: "x", count: 1_000))</p>" }.joined()
        let background = "<form aria-label='Background records'>\(paragraphs)</form>"
        let panel = """
        <div id="panel" aria-label="Synthetic panel"\(dialog ? " role='dialog'" : "")>
          <h2>New message</h2><div><div>
            <button type="button" id="action" onclick="window.expandPanel()">Full screen</button>
            <button type="button" onclick="window.closes++">Save &amp; close</button>
          </div></div>
        </div>
        """
        view.loadHTMLString("""
            <!doctype html><main aria-label="Fixture root">\(panelFirst ? panel + background : background + panel)</main>
            <script>
            window.actions=0;window.closes=0;window.sends=0;window.inputEvents=0;
            document.addEventListener('input',()=>window.inputEvents++);
            window.expandPanel=()=>{
              window.actions++;
              document.getElementById('panel').innerHTML='<h2>New message</h2>'
                +Array.from({length:100},(_,i)=>'<span>Panel detail '+i+'</span>').join('')
                +'<input type="email" aria-label="Recipients"><input aria-label="Subject">'
                +'<div contenteditable="true" aria-label="Message body"></div>'
                +'<button type="button" onclick="window.sends++">Send</button>';
            };
            </script>
            """, baseURL: URL(string: "http://localhost:8123/opposing-\(dialog)-\(panelFirst)"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString), target = try XCTUnwrap(available)
        let lifetime = BrowserTabLifetime()
        try await transport.acquireRendering(target: target, lifetime: lifetime)
        let generation = session.documentGeneration(for: id)
        let raw = try await transport.observe(target: target)
        let diagnostics = try XCTUnwrap(transport.captureDiagnosticsForTesting)
        XCTAssertTrue(raw.sourceTruncated)
        XCTAssertEqual(diagnostics.stopReason, .byteBudget)
        XCTAssertLessThanOrEqual(diagnostics.visited, 20_000)
        XCTAssertLessThanOrEqual(diagnostics.emitted, 3_000)
        XCTAssertLessThanOrEqual(diagnostics.estimatedBytes, 224_096)
        let root = try XCTUnwrap(raw.nodes.first { $0.name == "Fixture root" })
        let capturedPanel = try XCTUnwrap(raw.nodes.first { $0.name == "Synthetic panel" })
        let capturedBackground = try XCTUnwrap(raw.nodes.first { $0.name == "Background records" })
        let action = try XCTUnwrap(raw.nodes.first { $0.name == "Full screen" },
            "Capturing the panel root alone must not let the competing form consume its controls' budget")
        let close = try XCTUnwrap(raw.nodes.first { $0.name == "Save & close" })
        let expectedOrder = panelFirst ? [capturedPanel, capturedBackground] : [capturedBackground, capturedPanel]
        XCTAssertEqual(root.childNodeIDs, try expectedOrder.map { try XCTUnwrap($0.nodeID) })
        XCTAssertEqual(capturedPanel.parentNodeID, root.nodeID)
        XCTAssertEqual(action.parentNodeID, close.parentNodeID, "Nested control wrappers retain their real ancestry")
        XCTAssertTrue(action.isDOMClickable)
        XCTAssertTrue(close.isDOMClickable)
        XCTAssertFalse(capturedPanel.isDOMClickable)
        let untouched = try await script(view, "return {actions:window.actions,closes:window.closes,sends:window.sends,inputs:window.inputEvents};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: untouched) as? [String: Int],
                       ["actions": 0, "closes": 0, "sends": 0, "inputs": 0])

        let task = "opposing-\(dialog)-\(panelFirst)"
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: task, processIdentifier: 42, target: target)
        let before = try await broker.snapshot(taskKey: task, binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(query: "Full screen", view: .all))
        let oldAction = try XCTUnwrap(before.snapshot.elements.first { $0.label == "Full screen" })
        _ = try await script(view, "const old=document.getElementById('action');old.replaceWith(old.cloneNode(true));return true;")
        do {
            try await broker.perform(taskKey: task, binding: before.binding, snapshot: before.snapshot,
                                     elementIndex: oldAction.index, action: "AXPress")
            XCTFail("Identical replacement controls must not inherit a previously observed action reference")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .elementNotFound) }
        let fresh = try await broker.snapshot(taskKey: task, binding: before.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(query: "Full screen", view: .all))
        let currentAction = try XCTUnwrap(fresh.snapshot.elements.first { $0.label == "Full screen" })
        try await broker.perform(taskKey: task, binding: fresh.binding, snapshot: fresh.snapshot,
                                 elementIndex: currentAction.index, action: "AXPress")

        let expanded = try await transport.observe(target: target)
        let expandedDiagnostics = try XCTUnwrap(transport.captureDiagnosticsForTesting)
        XCTAssertTrue(expanded.sourceTruncated)
        XCTAssertEqual(expandedDiagnostics.stopReason, .byteBudget)
        XCTAssertLessThanOrEqual(expandedDiagnostics.visited, 20_000)
        XCTAssertLessThanOrEqual(expandedDiagnostics.emitted, 3_000)
        XCTAssertLessThanOrEqual(expandedDiagnostics.estimatedBytes, 224_096)
        XCTAssertEqual(expanded.nodes.filter(\.isEditable).map(\.name), ["Recipients", "Subject", "Message body"])
        let send = try XCTUnwrap(expanded.nodes.first { $0.name == "Send" })
        XCTAssertTrue(send.isDOMClickable)
        let finalState = try await script(view, """
            return {actions:window.actions,closes:window.closes,sends:window.sends,inputs:window.inputEvents,
              expandedChildren:document.getElementById('panel').children.length,
              fieldFocused:document.activeElement.matches('input,[contenteditable]')};
            """)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: finalState) as? [String: Any])
        XCTAssertEqual(state["actions"] as? Int, 1, "Exactly one freshly observed Full screen control was pressed")
        XCTAssertEqual(state["closes"] as? Int, 0)
        XCTAssertEqual(state["sends"] as? Int, 0)
        XCTAssertEqual(state["inputs"] as? Int, 0)
        XCTAssertGreaterThan(try XCTUnwrap(state["expandedChildren"] as? Int), 64)
        XCTAssertEqual(state["fieldFocused"] as? Bool, false, "Expanded fields must be discoverable without autofocus")
        XCTAssertEqual(session.documentGeneration(for: id), generation)
        try await broker.revoke(taskKey: task, binding: fresh.binding)
        lifetime.revoke(); await transport.releaseRendering(target: target, lifetime: lifetime)
    }

    func testGlobalCaptureFrontierRetainsLaterDialogAfterFocusedInboxBranch() async throws {
        try await verifyGlobalCaptureFrontier(focused: true)
    }

    func testGlobalCaptureFrontierRetainsLaterNamedPanelAfterEarlierForm() async throws {
        try await verifyGlobalCaptureFrontier(focused: false)
    }

    private func verifyGlobalCaptureFrontier(focused: Bool) async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let window = attachRenderHost(to: session)
        defer { session.shutdown(); window.close() }
        let transport = EmbeddedBrowserTabTransport(session: session)
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        let paragraphs = (0..<300).map { "<p>Synthetic record \($0): \(String(repeating: "x", count: 1_000))</p>" }.joined()
        let branch = focused ? "div" : "form", panelRole = focused ? " role='dialog'" : ""
        view.loadHTMLString("""
            <!doctype html><main aria-label="Fixture root"><\(branch) aria-label="Primary region">
            <button type="button" id="search" onclick="window.searches++">Search</button>\(paragraphs)</\(branch)>
            <div\(panelRole) aria-label="Synthetic panel"><p>Panel context</p>
            <button type="button" id="action" onclick="window.actions++">Full screen</button></div></main>
            <script>window.searches=0;window.actions=0;window.inputEvents=0;document.addEventListener('input',()=>window.inputEvents++);</script>
            """, baseURL: URL(string: "http://localhost:8123/frontier-\(focused ? "focus" : "form")"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString), target = try XCTUnwrap(available)
        let lifetime = BrowserTabLifetime()
        try await transport.acquireRendering(target: target, lifetime: lifetime)
        if focused {
            let focusedID = try await script(view, "document.getElementById('search').focus();return document.activeElement.id;")
            XCTAssertEqual(focusedID, Data(#""search""#.utf8))
        }
        let generation = session.documentGeneration(for: id)
        let raw = try await transport.observe(target: target)
        let diagnostics = try XCTUnwrap(transport.captureDiagnosticsForTesting)
        XCTAssertTrue(raw.sourceTruncated)
        XCTAssertEqual(diagnostics.stopReason, .byteBudget)
        XCTAssertLessThanOrEqual(diagnostics.visited, 20_000)
        XCTAssertLessThanOrEqual(diagnostics.emitted, 3_000)
        XCTAssertLessThanOrEqual(diagnostics.estimatedBytes, 224_096, "Prioritization must not increase the existing220KB capture budget")
        let action = try XCTUnwrap(raw.nodes.first { $0.name == "Full screen" },
                                  "A discovered later panel must not be starved by a higher/equal-priority ancestor's bulk text")
        let panel = try XCTUnwrap(raw.nodes.first { $0.name == "Synthetic panel" })
        let primary = try XCTUnwrap(raw.nodes.first { $0.name == "Primary region" })
        let root = try XCTUnwrap(raw.nodes.first { $0.name == "Fixture root" })
        let text = try XCTUnwrap(raw.nodes.first { $0.name == "Panel context" })
        XCTAssertEqual(root.childNodeIDs, [try XCTUnwrap(primary.nodeID), try XCTUnwrap(panel.nodeID)],
                       "Priority visitation must preserve actual sibling order in the published ancestry")
        XCTAssertEqual(panel.parentNodeID, root.nodeID)
        XCTAssertEqual(action.parentNodeID, panel.nodeID)
        XCTAssertEqual(text.parentNodeID, panel.nodeID)
        XCTAssertEqual(panel.childNodeIDs, [try XCTUnwrap(text.nodeID), try XCTUnwrap(action.nodeID)])
        XCTAssertTrue(action.isDOMClickable)
        XCTAssertFalse(panel.isDOMClickable)
        XCTAssertFalse(panel.isEditable)
        let untouched = try await script(view, "return {searches:window.searches,actions:window.actions,inputs:window.inputEvents};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: untouched) as? [String: Int],
                       ["searches": 0, "actions": 0, "inputs": 0], "Discovery/capture must never execute page input")
        XCTAssertEqual(session.documentGeneration(for: id), generation)
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: "frontier", processIdentifier: 42, target: target)
        let before = try await broker.snapshot(taskKey: "frontier", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(query: "Full screen", view: .all))
        let beforeAction = try XCTUnwrap(before.snapshot.elements.first { $0.label == "Full screen" })
        _ = try await script(view, "let old=document.getElementById('action');old.replaceWith(old.cloneNode(true));return true;")
        do {
            try await broker.perform(taskKey: "frontier", binding: before.binding, snapshot: before.snapshot,
                                     elementIndex: beforeAction.index, action: "AXPress")
            XCTFail("An identical replacement must not inherit the prior captured action reference")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .elementNotFound) }
        let after = try await broker.snapshot(taskKey: "frontier", binding: before.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(query: "Full screen", view: .all))
        let currentAction = try XCTUnwrap(after.snapshot.elements.first { $0.label == "Full screen" })
        try await broker.perform(taskKey: "frontier", binding: after.binding, snapshot: after.snapshot,
                                 elementIndex: currentAction.index, action: "AXPress")
        let actions = try await script(view, "return window.actions;")
        XCTAssertEqual(actions, Data("1".utf8), "Only the separately authorized current reference may act once")
        try await broker.revoke(taskKey: "frontier", binding: after.binding)
        lifetime.revoke(); await transport.releaseRendering(target: target, lifetime: lifetime)
    }

    private func attachRenderHost(to session: EmbeddedBrowserSession) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_024, height: 768),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = EmbeddedModelRenderContainer(session: session)
        host.frame = NSRect(x: 0, y: 0, width: 1_024, height: 768)
        window.contentView = host
        session.installModelRenderHost(host)
        return window
    }

    func testDocumentChangeWaitIgnoresLoadedChooserThenSettlesOneDelayedClickNavigation() async throws {
        let destination = try HeldBrowserNavigationFixture(body: "<!doctype html><main><h1>Mailbox ready</h1></main>")
        let destinationURL = try await destination.start()
        let chooserBody = """
        <!doctype html><main><h1>Pick an account</h1>
        <button onclick="window.clicks++;fetch('/release').then(()=>location.assign('\(destinationURL.absoluteString)'))">Use fixture account</button>
        </main><script>window.clicks=0;</script>
        """
        let chooser = try HeldBrowserNavigationFixture(body: "release", immediateBody: chooserBody)
        let chooserURL = try await chooser.start()
        defer { chooser.stop(); destination.stop() }
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let transport = EmbeddedBrowserTabTransport(session: session)
        let target = try await transport.createTarget(url: chooserURL)
        let id = try XCTUnwrap(UUID(uuidString: target.targetID))
        let view = try XCTUnwrap(session.webView(for: id))
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: "delayed-change", processIdentifier: 42, target: target)
        let before = try await broker.snapshot(taskKey: "delayed-change", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        let button = try XCTUnwrap(before.snapshot.elements.first { $0.label == "Use fixture account" })
        try await broker.perform(taskKey: "delayed-change", binding: before.binding,
            snapshot: before.snapshot, elementIndex: button.index, action: "AXPress")
        await fulfillment(of: [chooser.received], timeout: 5)
        let clicks = try await script(view, "return window.clicks;")
        XCTAssertEqual(clicks, Data("1".utf8))
        XCTAssertFalse(view.isLoading, "A held fetch has not started document navigation")
        let afterClick = try await broker.snapshot(taskKey: "delayed-change", binding: before.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .overview))
        let checkpoint = try await broker.documentChangeCheckpoint(taskKey: "delayed-change",
            binding: afterClick.binding, snapshotID: afterClick.snapshot.id)
        XCTAssertEqual(checkpoint.documentURL, chooserURL)
        let legacyMatched = try await transport.wait(target: target, text: nil, timeoutMS: 1_000)
        XCTAssertTrue(legacyMatched, "Existing readiness wait legitimately matches the loaded chooser before any navigation")
        let registered = expectation(description: "Wait registered on unchanged loaded chooser")
        let navigationPending = expectation(description: "Changed document is still loading")
        var sawRegistration = false, sawNavigation = false, completed = false
        session.documentChangeWaitRegisteredForTesting = {
            if !sawRegistration { sawRegistration = true; registered.fulfill() }
            if view.isLoading, !sawNavigation { sawNavigation = true; navigationPending.fulfill() }
        }
        let pending = Task { @MainActor in
            defer { completed = true }
            return try await transport.waitForDocumentChange(target: target, checkpoint: checkpoint,
                timeoutMS: 5_000, authorization: { _ in })
        }
        defer { pending.cancel(); session.documentChangeWaitRegisteredForTesting = nil }
        await fulfillment(of: [registered], timeout: 5)
        XCTAssertFalse(completed, "Already-loaded chooser is not a future document change")
        chooser.release()
        await fulfillment(of: [destination.received, navigationPending], timeout: 5)
        XCTAssertFalse(completed, "A changed loader alone does not establish navigation readiness")
        destination.release()
        let result = try await pending.value
        XCTAssertEqual(result, .init(changed: true, navigationReady: true))
        let fresh = try await transport.observeForRead(target: target, readiness: .content)
        XCTAssertEqual(fresh.url, destinationURL)
        XCTAssertNotEqual(fresh.loaderID, checkpoint.loaderID)
        XCTAssertTrue(fresh.nodes.contains { $0.name == "Mailbox ready" })
        XCTAssertEqual(chooser.requestPaths.filter { $0 == "/release" }.count, 1, "No click or fetch replay")
        XCTAssertEqual(destination.requestPaths, ["/"])
        XCTAssertTrue(session.webView(for: id) === view, "The wait preserves the original tab identity")
    }

    func testDocumentChangeWaitMatchesURLOnlyChangeAndSameURLReload() async throws {
        for reload in [false, true] {
            let fixture = try HeldBrowserNavigationFixture(body: "<!doctype html><main><h1>Ready document</h1></main>")
            let url = try await fixture.start()
            fixture.release()
            defer { fixture.stop() }
            let session = EmbeddedBrowserSession(persistent: false)
            defer { session.shutdown() }
            let transport = EmbeddedBrowserTabTransport(session: session)
            let target = try await transport.createTarget(url: url)
            let id = try XCTUnwrap(UUID(uuidString: target.targetID)), view = try XCTUnwrap(session.webView(for: id))
            let (_, checkpoint) = try await documentChangeCheckpoint(transport: transport, target: target)
            let registered = expectation(description: "Future-change wait registered before trigger")
            var armed = false, completed = false
            session.documentChangeWaitRegisteredForTesting = {
                if !armed { armed = true; registered.fulfill() }
            }
            let pending = Task { @MainActor in
                defer { completed = true }
                return try await transport.waitForDocumentChange(target: target, checkpoint: checkpoint,
                    timeoutMS: 5_000, authorization: { _ in })
            }
            defer { pending.cancel(); session.documentChangeWaitRegisteredForTesting = nil }
            await fulfillment(of: [registered], timeout: 5)
            XCTAssertFalse(completed)
            if reload { view.reload() }
            else { _ = try await script(view, "history.pushState({},'', '/next');return true;") }
            let result = try await pending.value
            XCTAssertEqual(result, .init(changed: true, navigationReady: true))
            let fresh = try await transport.observeForRead(target: target, readiness: .content)
            if reload {
                XCTAssertEqual(fresh.url, url)
                XCTAssertNotEqual(fresh.loaderID, checkpoint.loaderID)
                XCTAssertEqual(fixture.requestPaths, ["/", "/"])
            } else {
                XCTAssertEqual(fresh.url, url.appendingPathComponent("next"))
                XCTAssertEqual(fresh.loaderID, checkpoint.loaderID)
                XCTAssertEqual(fixture.requestPaths, ["/"], "History API change does not fetch another document")
            }
        }
    }

    func testDocumentChangeWaitIgnoresDOMMutationAndKeepsOriginalCheckpointDeadline() async throws {
        let (session, transport, view, target) = try await semanticReadinessFixture(
            body: "<main><h1>Ready chooser</h1></main>")
        defer { session.shutdown() }
        let (_, checkpoint) = try await documentChangeCheckpoint(transport: transport, target: target,
            readLifetime: .milliseconds(300))
        let registered = expectation(description: "Unchanged-document wait registered")
        var armed = false, completed = false
        session.documentChangeWaitRegisteredForTesting = {
            if !armed { armed = true; registered.fulfill() }
        }
        let started = ContinuousClock.now
        let pending = Task { @MainActor in
            defer { completed = true }
            return try await transport.waitForDocumentChange(target: target, checkpoint: checkpoint,
                timeoutMS: 10_000, authorization: { _ in })
        }
        defer { pending.cancel(); session.documentChangeWaitRegisteredForTesting = nil }
        await fulfillment(of: [registered], timeout: 5)
        _ = try await script(view, "document.querySelector('h1').textContent='Changed visible text';return true;")
        XCTAssertFalse(completed, "DOM/text changes do not imply document or URL transition")
        let result = try await pending.value
        XCTAssertEqual(result, .init(changed: false, navigationReady: false))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now, checkpoint.expiresAt)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2), "The requested ten seconds cannot renew the shorter checkpoint lifetime")
    }

    func testDocumentChangeWaitCancellationAndClosureCannotReturnLateMatch() async throws {
        for closesTab in [false, true] {
            let (session, transport, _, target) = try await semanticReadinessFixture(
                body: "<main><h1>Ready chooser</h1></main>")
            defer { session.shutdown() }
            let (_, checkpoint) = try await documentChangeCheckpoint(transport: transport, target: target)
            let registered = expectation(description: "Wait registered before retirement")
            var armed = false
            session.documentChangeWaitRegisteredForTesting = {
                if !armed { armed = true; registered.fulfill() }
            }
            let pending = Task { @MainActor in
                try await transport.waitForDocumentChange(target: target, checkpoint: checkpoint,
                    timeoutMS: 5_000, authorization: { _ in })
            }
            defer { pending.cancel(); session.documentChangeWaitRegisteredForTesting = nil }
            await fulfillment(of: [registered], timeout: 5)
            if closesTab { session.closeTab(try XCTUnwrap(UUID(uuidString: target.targetID))) }
            else { pending.cancel() }
            do { _ = try await pending.value; XCTFail("A retired wait cannot report a ready changed document") }
            catch {
                if closesTab { XCTAssertEqual(error as? EmbeddedBrowserSession.Failure, .tabClosed) }
                else { XCTAssertTrue(error is CancellationError) }
            }
        }
    }

    func testDocumentChangeWaitDoesNotExtendDeadlineWhileChangedNavigationIsHeld() async throws {
        let destination = try HeldBrowserNavigationFixture()
        let destinationURL = try await destination.start()
        defer { destination.stop() }
        let (session, transport, view, target) = try await semanticReadinessFixture(
            body: "<main><h1>Ready chooser</h1></main>")
        defer { session.shutdown() }
        let (_, checkpoint) = try await documentChangeCheckpoint(transport: transport, target: target,
            readLifetime: .milliseconds(300))
        let registered = expectation(description: "Wait registered before held navigation")
        var armed = false
        session.documentChangeWaitRegisteredForTesting = {
            if !armed { armed = true; registered.fulfill() }
        }
        let started = ContinuousClock.now
        let pending = Task { @MainActor in
            try await transport.waitForDocumentChange(target: target, checkpoint: checkpoint,
                timeoutMS: 10_000, authorization: { _ in })
        }
        defer { pending.cancel(); session.documentChangeWaitRegisteredForTesting = nil }
        await fulfillment(of: [registered], timeout: 5)
        let id = try XCTUnwrap(UUID(uuidString: target.targetID))
        try session.navigate(tabID: id, to: destinationURL)
        await fulfillment(of: [destination.received], timeout: 5)
        XCTAssertTrue(view.isLoading)
        let result = try await pending.value
        XCTAssertEqual(result, .init(changed: true, navigationReady: false))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now, checkpoint.expiresAt)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2), "Readiness cannot start a second ten-second budget")
        destination.release()
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(5))
        XCTAssertEqual(result, .init(changed: true, navigationReady: false), "Late navigation does not rewrite the completed wait receipt")
    }

    private func documentChangeCheckpoint(transport: EmbeddedBrowserTabTransport, target: BrowserTarget,
                                          readLifetime: Duration = .seconds(120)) async throws
        -> (BrowserTabSessionBroker, BrowserDocumentChangeCheckpoint) {
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(),
            ownership: .borrowed, readLifetime: readLifetime)
        let binding = try await broker.bindBorrowed(taskKey: "change-checkpoint", processIdentifier: 42, target: target)
        let observed = try await broker.snapshot(taskKey: "change-checkpoint", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        let checkpoint = try await broker.documentChangeCheckpoint(taskKey: "change-checkpoint",
            binding: observed.binding, snapshotID: observed.snapshot.id)
        return (broker, checkpoint)
    }

    func testLifecycleOpenNavigateAndBorrowedBindExposeRealWebKitRefsWithoutSeparateReads() async throws {
        let body = "<!doctype html><main><h1>Settled lifecycle page</h1><button onclick='window.clicks++'>Inspect current page</button></main><script>window.clicks=0</script>"
        let firstServer = try HeldBrowserNavigationFixture(body: body), firstURL = try await firstServer.start()
        let nextServer = try HeldBrowserNavigationFixture(body: body), nextURL = try await nextServer.start()
        defer { firstServer.stop(); nextServer.stop() }
        let session = EmbeddedBrowserSession(persistent: false), transport = EmbeddedBrowserTabTransport(session: session)
        let renderWindow = attachRenderHost(to: session)
        defer { renderWindow.close() }
        let controller = EmbeddedBrowserToolController(transport: transport)
        defer { session.shutdown() }
        func page(_ result: EmbeddedBrowserToolExecution) throws -> String {
            XCTAssertTrue(result.completeObservation); XCTAssertNil(result.nativeRead)
            let cue = try XCTUnwrap(result.lifecycleReceipt)
            XCTAssertEqual(try BrowserCompleteObservation.excessBytes(result.response, actionReceipt: cue.compactText), 0)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.response.utf8)) as? [String: Any])
            XCTAssertEqual(body["operation_complete"] as? Bool, true); XCTAssertEqual(body["result_verified"] as? Bool, false)
            return try XCTUnwrap((body["current_observation"] as? [String: Any])?["text"] as? String)
        }
        let opening = Task { try await controller.executeResult(taskKey: "lifecycle", tool: "browser_open",
            arguments: JSONSerialization.data(withJSONObject: ["url": firstURL.absoluteString]), lifecycleObservationsEnabled: true) }
        await fulfillment(of: [firstServer.received], timeout: 5); firstServer.release()
        let opened = try await opening.value, original = try page(opened)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(opened.response.utf8)) as? [String: Any])
        let id = try XCTUnwrap(UUID(uuidString: XCTUnwrap(object["tab_id"] as? String)))
        let view = try XCTUnwrap(session.webView(for: id))
        let old = try JSONSerialization.data(withJSONObject: inputReference(original, label: "Inspect current page"))
        _ = try await controller.execute(taskKey: "lifecycle", tool: "browser_click", arguments: old)
        let firstClicks = try await script(view, "return window.clicks;")
        XCTAssertEqual(firstClicks, Data("1".utf8))
        let navigation = Task { try await controller.executeResult(taskKey: "lifecycle", tool: "browser_navigate",
            arguments: JSONSerialization.data(withJSONObject: ["url": nextURL.absoluteString]), lifecycleObservationsEnabled: true) }
        await fulfillment(of: [nextServer.received], timeout: 5); nextServer.release()
        let navigated = try await navigation.value, current = try page(navigated)
        XCTAssertTrue(current.contains(nextURL.absoluteString))
        do { _ = try await controller.execute(taskKey: "lifecycle", tool: "browser_click", arguments: old); XCTFail("Old document refs cannot act") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        _ = try await controller.execute(taskKey: "lifecycle", tool: "browser_click",
            arguments: JSONSerialization.data(withJSONObject: inputReference(current, label: "Inspect current page")))
        let nextClicks = try await script(view, "return window.clicks;")
        XCTAssertEqual(nextClicks, Data("1".utf8))
        _ = await controller.release(taskKey: "lifecycle")
        XCTAssertNil(session.webView(for: id))
        let human = try session.createTab(), humanView = try XCTUnwrap(session.webView(for: human))
        humanView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        humanView.loadHTMLString(body, baseURL: URL(string: "http://localhost:8123/human"))
        try await session.waitForHumanTabReady(id: human, until: .now + .seconds(10))
        _ = try await controller.execute(taskKey: "borrowed", tool: "browser_tabs", arguments: Data("{}".utf8))
        let borrowed = try await controller.executeResult(taskKey: "borrowed", tool: "browser_bind",
            arguments: JSONSerialization.data(withJSONObject: ["tab_id": human.uuidString]), lifecycleObservationsEnabled: true)
        _ = try await controller.execute(taskKey: "borrowed", tool: "browser_click",
            arguments: JSONSerialization.data(withJSONObject: inputReference(page(borrowed), label: "Inspect current page")))
        let humanClicks = try await script(humanView, "return window.clicks;")
        XCTAssertEqual(humanClicks, Data("1".utf8))
        _ = await controller.shutdown()
        XCTAssertNotNil(session.webView(for: human), "Borrowed user tab survives cleanup")
    }

    func testFreshReadAuthorizesSettledNativeTargetBeforeAnyDriverCapture() async throws {
        for denied in [false, true] {
            let fixture = try HeldBrowserNavigationFixture(), base = try await fixture.start()
            defer { fixture.stop() }
            let finalURL = base.appendingPathComponent("authorized")
            let session = EmbeddedBrowserSession(persistent: false)
            defer { session.shutdown() }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let driver = try String(contentsOf: root.appendingPathComponent("Sources/Computa/Resources/BrowserModels/browser-control.js"), encoding: .utf8)
            let instrumented = "document.documentElement.setAttribute('data-driver-captures', String(Number(document.documentElement.getAttribute('data-driver-captures') || 0) + 1));\n" + driver
            let transport = EmbeddedBrowserTabTransport(session: session, script: instrumented)
            let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
            view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            view.loadHTMLString("<main><h1>Prior page</h1></main>", baseURL: URL(string: "http://localhost:8123/prior"))
            try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
            let available = try await transport.target(id: id.uuidString), target = try XCTUnwrap(available)
            try session.navigate(tabID: id, to: finalURL)
            await fulfillment(of: [fixture.received], timeout: 5)
            XCTAssertTrue(view.isLoading)
            let audit = BrowserReadAuthorizationAudit(), started = expectation(description: "Fresh read entered the existing navigation wait")
            let read = Task { @MainActor in
                started.fulfill()
                return try await transport.observeForRead(target: target, readiness: .semanticContent, authorization: { candidate in
                    try audit.authorize(candidate, expectedURL: finalURL, denied: denied)
                })
            }
            await fulfillment(of: [started], timeout: 5)
            XCTAssertEqual(audit.count, 0, "An in-flight navigation must settle before evaluating its URL scope")
            fixture.release()
            if denied {
                do { _ = try await read.value; XCTFail("A denied settled page must not be captured") }
                catch { XCTAssertEqual(error as? BrowserTabBrokerError, .scopeDenied("Synthetic native scope denial")) }
                XCTAssertEqual(audit.count, 1)
            } else {
                let observed = try await read.value
                XCTAssertEqual(observed.url, finalURL)
                XCTAssertTrue(observed.nodes.contains { $0.name == "Settled authorized page" })
                XCTAssertGreaterThanOrEqual(audit.count, 1)
            }
            let captureCount = try await script(view, "return Number(document.documentElement.getAttribute('data-driver-captures') || 0);")
            XCTAssertEqual(captureCount, Data((denied ? "0" : "1").utf8), "Authorization adds no capture and denial happens before driver JS")
        }
    }

    func testFreshReadCancellationOrTabClosureDuringNavigationNeverAuthorizesCapture() async throws {
        for closesTab in [false, true] {
            let fixture = try HeldBrowserNavigationFixture(), base = try await fixture.start()
            defer { fixture.stop() }
            let session = EmbeddedBrowserSession(persistent: false), transport = EmbeddedBrowserTabTransport(session: session)
            defer { session.shutdown() }
            let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
            view.loadHTMLString("<main><h1>Prior page</h1></main>", baseURL: URL(string: "http://localhost:8123/prior"))
            try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
            let available = try await transport.target(id: id.uuidString), target = try XCTUnwrap(available)
            let finalURL = base.appendingPathComponent("authorized")
            try session.navigate(tabID: id, to: finalURL)
            await fulfillment(of: [fixture.received], timeout: 5)
            let audit = BrowserReadAuthorizationAudit(), started = expectation(description: "Read waiting before retirement")
            let read = Task { @MainActor in
                started.fulfill()
                return try await transport.observeForRead(target: target, readiness: .semanticContent, authorization: { candidate in
                    try audit.authorize(candidate, expectedURL: finalURL, denied: false)
                })
            }
            await fulfillment(of: [started], timeout: 5)
            if closesTab { session.closeTab(id) } else { read.cancel() }
            do { _ = try await read.value; XCTFail("A retired read must not capture") }
            catch {
                if !closesTab { XCTAssertTrue(error is CancellationError) }
            }
            XCTAssertEqual(audit.count, 0)
            XCTAssertNil(transport.captureDiagnosticsForTesting)
            fixture.release()
        }
    }

    /// These synthetic labels contain no escaped quotes. Read expectations from
    /// the emitted row, independently of the backend document used by the test.
    private func exposedField(_ name: String, in row: Substring) throws -> String {
        let range = try XCTUnwrap(row.range(of: "\(name)=\""))
        return String(row[range.upperBound...].prefix { $0 != "\"" })
    }

    private func inputReference(_ read: String, label: String, fill: Bool = false) throws -> [String: Any] {
        let row = try XCTUnwrap(read.split(separator: "\n").first {
            $0.hasPrefix("#") && $0.contains("label=\"\(label)\"")
        })
        return reference(in: row, fill: fill)
    }

    private func reference(in row: Substring, fill: Bool = false) -> [String: Any] {
        let field = fill ? "fill_ref" : "click_ref"
        // Read-only rows deliberately have no issued reference; the negative
        // cases exercise an unknown token rather than synthesizing authority.
        let token = row.range(of: "\(field)=\"").map { String(row[$0.upperBound...].prefix { $0 != "\"" }) }
        return [field: token ?? "unpublished-reference"]
    }

    func testRealWebKitReadScopeUsesCommittedDocumentAndIgnoresSameDocumentURLChanges() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        let renderWindow = attachRenderHost(to: session)
        defer { renderWindow.close() }
        let controller = EmbeddedBrowserToolController(transport: EmbeddedBrowserTabTransport(session: session))
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString("<main><h1>Initial document</h1></main>", baseURL: URL(string: "http://localhost:8123/first"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        _ = try await controller.executeResult(taskKey: "document-scope", tool: "browser_tabs", arguments: Data("{}".utf8))
        let bound = try await controller.executeResult(taskKey: "document-scope", tool: "browser_bind",
            arguments: JSONSerialization.data(withJSONObject: ["tab_id": id.uuidString]))
        let initial = try XCTUnwrap(bound.readFailureScope)
        _ = try await script(view, "history.pushState({}, '', '/same-document'); return true;")
        let sameDocument = try await controller.executeResult(taskKey: "document-scope", tool: "browser_read", arguments: Data("{}".utf8))
        XCTAssertEqual(sameDocument.readFailureScope, initial, "URL-derived broker epochs cannot reset the failure guard")
        XCTAssertTrue(sameDocument.response.contains("same-document"))
        view.loadHTMLString("<main><h1>Replacement document</h1></main>", baseURL: URL(string: "http://localhost:8123/replacement"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let replaced = try await controller.executeResult(taskKey: "document-scope", tool: "browser_read", arguments: Data("{}".utf8))
        let replacement = try XCTUnwrap(replaced.readFailureScope)
        XCTAssertEqual(replacement.bindingHandle, initial.bindingHandle)
        XCTAssertNotEqual(replacement.committedDocumentID, initial.committedDocumentID)
        XCTAssertTrue(replaced.response.contains("Replacement document"))
        _ = await controller.shutdown()
    }

    func testRealWebKitPostInputOverviewShowsReceiptBodyAndControlsWithoutVerifyingOutcomeOrReplaying() async throws {
        let receipt = "Receipt: cafe\u{301}-" + UUID().uuidString.lowercased()
        let navigation = (0..<35).map { "<a href='/item/\($0)'>Destination \($0)</a>" }.joined(separator: " ")
        let html = """
        <!doctype html><body><nav>\(navigation)<p>SIDEBAR_BODY_SENTINEL</p></nav>
        <main id="main"><h1>Compose record</h1><form id="form"><button type="submit">Send message</button></form></main>
        <script>window.submits=0;window.inspections=0;
        document.getElementById('form').addEventListener('submit',event=>{
          event.preventDefault();window.submits++;
          document.getElementById('main').innerHTML='<h1>Message sent</h1><p id="receipt"></p><p hidden>HIDDEN_BODY_SENTINEL</p><button id="inspect">Inspect record</button>';
          document.getElementById('receipt').textContent='\(receipt)';
          document.getElementById('inspect').addEventListener('click',()=>window.inspections++);
        });</script></body>
        """
        let session = EmbeddedBrowserSession(persistent: false)
        let renderWindow = attachRenderHost(to: session)
        defer { renderWindow.close() }
        let controller = EmbeddedBrowserToolController(transport: EmbeddedBrowserTabTransport(session: session))
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString(html, baseURL: URL(string: "http://localhost:8123/receipt-body"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        _ = try await controller.execute(taskKey: "receipt-body", tool: "browser_tabs", arguments: Data("{}".utf8))
        _ = try await controller.execute(taskKey: "receipt-body", tool: "browser_bind",
            arguments: JSONSerialization.data(withJSONObject: ["tab_id": id.uuidString]))
        let before = try await controller.execute(taskKey: "receipt-body", tool: "browser_read", arguments: Data("{}".utf8))
        XCTAssertFalse(before.contains(receipt), "The fixture script must not expose an unrendered receipt")
        let send = try JSONSerialization.data(withJSONObject: inputReference(before, label: "Send message"))
        let resultText = try await controller.execute(taskKey: "receipt-body", tool: "browser_click", arguments: send)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(resultText.utf8)) as? [String: Any])
        XCTAssertEqual(result["dispatched"] as? Bool, true)
        XCTAssertEqual(result["no_replay"] as? Bool, true)
        XCTAssertEqual(result["result_verified"] as? Bool, false, "A displayed receipt is observed text, not host verification")
        let current = try XCTUnwrap(result["current_observation"] as? [String: Any])
        XCTAssertEqual(current["status"] as? String, "available"); XCTAssertEqual(current["view"] as? String, "overview")
        let read = try XCTUnwrap(current["text"] as? String), rows = read.split(separator: "\n").filter { $0.hasPrefix("#") }
        XCTAssertTrue(read.contains("source_truncated=0")); XCTAssertTrue(read.contains("output_truncated=1"))
        XCTAssertTrue(rows.contains { $0.contains("label=\"Message sent\"") })
        XCTAssertTrue(rows.contains { $0.contains("label=\"Inspect record\"") && $0.contains("actions=[\"AXPress\"]") })
        let bodyRow = try XCTUnwrap(rows.first { $0.contains("label=\"\(receipt)\"") })
        XCTAssertEqual(Data(try exposedField("label", in: bodyRow).utf8), Data(receipt.utf8))
        XCTAssertTrue(bodyRow.contains("content_scope=main content_kind=readable"))
        XCTAssertTrue(read.contains("Defaults enabled=true settable=false actions=[]"))
        XCTAssertFalse(bodyRow.contains("click_ref=")); XCTAssertFalse(bodyRow.contains("fill_ref="))
        XCTAssertFalse(read.contains("SIDEBAR_BODY_SENTINEL")); XCTAssertFalse(read.contains("HIDDEN_BODY_SENTINEL"))
        XCTAssertLessThanOrEqual(rows.count, 18)
        XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + $1.utf8.count + 1 }, 6_000)
        XCTAssertLessThanOrEqual(read.utf8.count, 16_384); XCTAssertLessThanOrEqual(resultText.utf8.count, 20_480)
        do {
            _ = try await controller.execute(taskKey: "receipt-body", tool: "browser_click", arguments: send)
            XCTFail("Publishing body text cannot revive the consumed send reference")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        do {
            _ = try await controller.execute(taskKey: "receipt-body", tool: "browser_click",
                arguments: JSONSerialization.data(withJSONObject: inputReference(read, label: receipt)))
            XCTFail("A newly published body row has no action authority")
        } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
        _ = try await controller.execute(taskKey: "receipt-body", tool: "browser_click",
            arguments: JSONSerialization.data(withJSONObject: inputReference(read, label: "Inspect record")))
        let counters = try await script(view, "return {submits:window.submits,inspections:window.inspections};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: counters) as? [String: Int], ["submits": 1, "inspections": 1])
        _ = await controller.shutdown()
    }

    func testRealWebKitEarlierPageReferenceWorksAfterImmutableContinuationOnceOnly() async throws {
        let controls = (0..<70).map { "<button onclick='window.other++'>Other control \($0)</button>" }.joined()
        let html = """
        <!doctype html><body><main><button id="first" onclick="window.first++">First intended control</button>
        \(controls)</main><script>window.first=0;window.other=0;</script></body>
        """
        let session = EmbeddedBrowserSession(persistent: false)
        let renderWindow = attachRenderHost(to: session)
        defer { renderWindow.close() }
        let controller = EmbeddedBrowserToolController(transport: EmbeddedBrowserTabTransport(session: session))
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString(html, baseURL: URL(string: "http://localhost:8123/paged-controls"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        _ = try await controller.execute(taskKey: "paged", tool: "browser_tabs", arguments: Data("{}".utf8))
        _ = try await controller.execute(taskKey: "paged", tool: "browser_bind",
            arguments: JSONSerialization.data(withJSONObject: ["tab_id": id.uuidString]))
        let first = try await controller.execute(taskKey: "paged", tool: "browser_read", arguments: Data(#"{"view":"all"}"#.utf8))
        let arguments = try JSONSerialization.data(withJSONObject: inputReference(first, label: "First intended control"))
        let frozen = try await controller.prepareMutation(taskKey: "paged", tool: "browser_click", arguments: arguments)
        try await controller.preflightMutation(taskKey: "paged", tool: "browser_click", arguments: arguments, prepared: frozen)
        let cursorStart = try XCTUnwrap(first.range(of: "next_cursor="))
        let cursor = String(first[cursorStart.upperBound...].prefix { !$0.isWhitespace })
        let next = try await controller.execute(taskKey: "paged", tool: "browser_read",
            arguments: JSONSerialization.data(withJSONObject: ["cursor": cursor]))
        XCTAssertFalse(next.contains("label=\"First intended control\""))
        let result = try await controller.executeResult(taskKey: "paged", tool: "browser_click", arguments: arguments, prepared: frozen)
        XCTAssertTrue(result.completeObservation)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.response.utf8)) as? [String: Any])
        XCTAssertEqual(response["dispatched"] as? Bool, true); XCTAssertEqual(response["result_verified"] as? Bool, false)
        let actual = try await script(view, "return {first:window.first,other:window.other};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: actual) as? [String: Int], ["first": 1, "other": 0])
        do {
            _ = try await controller.executeResult(taskKey: "paged", tool: "browser_click", arguments: arguments, prepared: frozen)
            XCTFail("The input consumed the entire paged capture")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        _ = await controller.shutdown()
    }

    func testRealWebKitReadsPassiveFieldConstraintsWithoutHiddenOrSecureState() async throws {
        let html = """
        <!doctype html><body><main><h1>Constraints fixture</h1>
        <textarea aria-label="Message" required></textarea>
        <input aria-label="Optional">
        <input aria-label="Email" type="email" required value="invalid-address">
        <input aria-label="Custom" id="custom" value="visible">
        <input aria-label="Consent" type="checkbox" required>
        <select aria-label="Choice" required><option value="">Choose</option><option>One</option></select>
        <input aria-label="Disabled" disabled required>
        <input aria-label="Read only" readonly required>
        <input aria-label="Password" type="password" required value="SECURE_SENTINEL">
        <input type="hidden" required aria-label="HIDDEN_SENTINEL">
        <div hidden><input required aria-label="HIDDEN_ANCESTOR_SENTINEL"></div>
        <div aria-hidden="true"><input required aria-label="ARIA_HIDDEN_SENTINEL"></div>
        <div inert><input required aria-label="INERT_SENTINEL"></div>
        <div role="textbox" aria-label="Fake field" required></div>
        <script>
        document.getElementById('custom').setCustomValidity('PRIVATE_VALIDATION_MESSAGE');
        window.invalids=0;window.submits=0;
        document.addEventListener('invalid',()=>window.invalids++,true);
        document.addEventListener('submit',()=>window.submits++,true);
        </script></main></body>
        """
        let session = EmbeddedBrowserSession(persistent: false)
        let transport = EmbeddedBrowserTabTransport(session: session)
        let renderWindow = attachRenderHost(to: session)
        defer { renderWindow.close() }
        let controller = EmbeddedBrowserToolController(transport: transport)
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString(html, baseURL: URL(string: "http://localhost:8123/constraints"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString), target = try XCTUnwrap(available)
        let observed = try await transport.observe(target: target)
        func state(_ label: String) throws -> BrowserConstraintValidation {
            try XCTUnwrap(observed.nodes.first { $0.name == label }?.constraintValidation)
        }
        XCTAssertEqual(try state("Message"), .init(required: true, candidate: true, valid: false, issues: [.valueMissing]))
        XCTAssertEqual(try state("Optional"), .init(required: false, candidate: true, valid: true, issues: []))
        XCTAssertEqual(try state("Email").issues, [.typeMismatch])
        XCTAssertEqual(try state("Custom").issues, [.customError])
        XCTAssertEqual(try state("Consent").issues, [.valueMissing])
        XCTAssertEqual(try state("Choice").issues, [.valueMissing])
        XCTAssertFalse(try state("Disabled").candidate)
        XCTAssertFalse(try state("Read only").candidate)
        for name in ["Password", "Fake field"] {
            XCTAssertNil(try XCTUnwrap(observed.nodes.first { $0.name == name }).constraintValidation)
        }
        _ = try await controller.execute(taskKey: "constraints", tool: "browser_tabs", arguments: Data("{}".utf8))
        _ = try await controller.execute(taskKey: "constraints", tool: "browser_bind",
            arguments: JSONSerialization.data(withJSONObject: ["tab_id": id.uuidString]))
        let read = try await controller.execute(taskKey: "constraints", tool: "browser_read", arguments: Data(#"{"view":"all"}"#.utf8))
        let row = try XCTUnwrap(read.split(separator: "\n").first { $0.contains("label=\"Message\"") })
        XCTAssertTrue(row.contains("required=true constraint=invalid[value_missing]"))
        for excluded in ["SECURE_SENTINEL", "HIDDEN_SENTINEL", "HIDDEN_ANCESTOR_SENTINEL", "ARIA_HIDDEN_SENTINEL", "INERT_SENTINEL", "PRIVATE_VALIDATION_MESSAGE"] {
            XCTAssertFalse(read.contains(excluded), excluded)
        }
        let events = try await script(view, "return {invalids:window.invalids,submits:window.submits};")
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with: events) as? [String: Int])
        XCTAssertEqual(counts, ["invalids": 0, "submits": 0], "Passive reads must not run native constraint validation")
        _ = await controller.shutdown()
    }

    func testRealWebKitInvalidFormStillRunsClickHandlerAndCanBeCompletedWithoutReplay() async throws {
        let html = """
        <!doctype html><body><form id="form"><textarea id="body" aria-label="Message" required></textarea>
        <button id="send" type="submit">Send message</button></form><script>
        window.clicks=0;window.invalids=0;window.submits=0;
        document.getElementById('send').addEventListener('click',()=>window.clicks++);
        document.addEventListener('invalid',()=>window.invalids++,true);
        document.getElementById('form').addEventListener('submit',event=>{event.preventDefault();window.submits++;});
        </script></body>
        """
        let session = EmbeddedBrowserSession(persistent: false)
        let renderWindow = attachRenderHost(to: session)
        defer { renderWindow.close() }
        let controller = EmbeddedBrowserToolController(transport: EmbeddedBrowserTabTransport(session: session))
        defer { session.shutdown() }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString(html, baseURL: URL(string: "http://localhost:8123/invalid-form"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        _ = try await controller.execute(taskKey: "form", tool: "browser_tabs", arguments: Data("{}".utf8))
        _ = try await controller.execute(taskKey: "form", tool: "browser_bind",
            arguments: JSONSerialization.data(withJSONObject: ["tab_id": id.uuidString]))
        let before = try await controller.execute(taskKey: "form", tool: "browser_read", arguments: Data(#"{"view":"all"}"#.utf8))
        let firstClick = try JSONSerialization.data(withJSONObject: inputReference(before, label: "Send message"))
        let clicked = try await controller.execute(taskKey: "form", tool: "browser_click", arguments: firstClick)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(clicked.utf8)) as? [String: Any])
        XCTAssertEqual(result["dispatched"] as? Bool, true)
        XCTAssertEqual(result["no_replay"] as? Bool, true)
        XCTAssertEqual(result["result_verified"] as? Bool, false)
        XCTAssertTrue(clicked.contains("value_missing"))
        let feedback = try XCTUnwrap(result["input_feedback"] as? [String: Any])
        XCTAssertEqual(feedback["kind"] as? String, "native_constraint_validation_observed")
        XCTAssertEqual(feedback["during"] as? String, "synchronous_click")
        let fields = try XCTUnwrap(feedback["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?["label"] as? String, "Message")
        XCTAssertEqual(fields.first?["partial"] as? Bool, false)
        XCTAssertEqual(fields.first?["issues"] as? [String], ["value_missing"])
        XCTAssertFalse(clicked.contains("backendNodeID"))
        let firstCounts = try await script(view, "return {clicks:window.clicks,invalids:window.invalids,submits:window.submits};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: firstCounts) as? [String: Int], ["clicks": 1, "invalids": 1, "submits": 0])
        do {
            _ = try await controller.execute(taskKey: "form", tool: "browser_click", arguments: firstClick)
            XCTFail("Invalid form state cannot revive the consumed input reference")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleSnapshot) }
        let fresh = try await controller.execute(taskKey: "form", tool: "browser_read", arguments: Data(#"{"view":"all"}"#.utf8))
        var fill = try inputReference(fresh, label: "Message", fill: true); fill["text"] = "Requested body"
        _ = try await controller.execute(taskKey: "form", tool: "browser_fill", arguments: JSONSerialization.data(withJSONObject: fill))
        let completed = try await controller.execute(taskKey: "form", tool: "browser_read", arguments: Data(#"{"view":"all"}"#.utf8))
        let field = try XCTUnwrap(completed.split(separator: "\n").first { $0.contains("label=\"Message\"") })
        XCTAssertTrue(field.contains("value=\"Requested body\""))
        XCTAssertTrue(field.contains("constraint=valid"))
        let newClick = try JSONSerialization.data(withJSONObject: inputReference(completed, label: "Send message"))
        let submitted = try await controller.execute(taskKey: "form", tool: "browser_click", arguments: newClick)
        let newResult = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(submitted.utf8)) as? [String: Any])
        XCTAssertEqual(newResult["result_verified"] as? Bool, false, "A native submit event is not a delivery receipt")
        XCTAssertNil(newResult["input_feedback"], "Old invalid events are not reused by a later valid click")
        let finalCounts = try await script(view, "return {clicks:window.clicks,invalids:window.invalids,submits:window.submits};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: finalCounts) as? [String: Int], ["clicks": 2, "invalids": 1, "submits": 1])
        _ = await controller.shutdown()
    }

    func testRealWebKitConstraintStateDoesNotClaimSubmissionBlockedWhenValidationIsBypassed() async throws {
        for mode in ["novalidate", "formnovalidate"] {
            let html = """
            <!doctype html><body><form id="form" \(mode == "novalidate" ? "novalidate" : "")>
            <textarea aria-label="Message" required></textarea>
            <button type="submit" \(mode == "formnovalidate" ? "formnovalidate" : "")>Send message</button></form>
            <script>window.submits=0;window.invalids=0;
            document.addEventListener('invalid',()=>window.invalids++,true);
            document.getElementById('form').addEventListener('submit',event=>{event.preventDefault();window.submits++;});</script></body>
            """
            let session = EmbeddedBrowserSession(persistent: false), transport = EmbeddedBrowserTabTransport(session: session)
            defer { session.shutdown() }
            let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
            view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            view.loadHTMLString(html, baseURL: URL(string: "http://localhost:8123/\(mode)"))
            try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
            let available = try await transport.target(id: id.uuidString), target = try XCTUnwrap(available)
            let observed = try await transport.observe(target: target)
            XCTAssertEqual(observed.nodes.first { $0.name == "Message" }?.constraintValidation?.issues, [.valueMissing])
            let button = try XCTUnwrap(observed.nodes.first { $0.role == "button" })
            let feedback = try await transport.pressWithFeedback(target: target, backendNodeID: XCTUnwrap(button.backendNodeID), document: observed, permit: BrowserMutationPermit())
            XCTAssertNil(feedback, "Passive invalid flags cannot substitute for actual events: \(mode)")
            let counts = try await script(view, "return {invalids:window.invalids,submits:window.submits};")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: counts) as? [String: Int], ["invalids": 0, "submits": 1], mode)
        }
    }

    func testRealWebKitInvalidFeedbackExcludesForeignSyntheticHiddenSecureAndNewFieldsAndRemovesListener() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Computa/Resources/BrowserModels/browser-control.js"), encoding: .utf8)
        // Instrument only registration/removal of the actual production listener
        // in its isolated world. The DOM flag is an independent test oracle.
        let add = "if (form) window.addEventListener('invalid', invalid, true);"
        let remove = "if (form) window.removeEventListener('invalid', invalid, true);"
        XCTAssertEqual(source.components(separatedBy: add).count, 2)
        XCTAssertEqual(source.components(separatedBy: remove).count, 2)
        let instrumented = source.replacingOccurrences(of: add, with: add + " document.documentElement.dataset.listenerActive = form ? '1' : '0';")
            .replacingOccurrences(of: remove, with: remove + " document.documentElement.dataset.listenerActive = '0';")
        let html = """
        <!doctype html><body><form id="other"><input id="foreign" aria-label="Foreign" required></form>
        <form id="form"><input id="visible" aria-label="Visible field" required>
        <input aria-label="Second field" required><input aria-label="Third field" required><input aria-label="Fourth field" required>
        <input id="synthetic" aria-label="Synthetic field" required>
        <input id="secret" type="password" aria-label="Secure field" required>
        <input id="hidden" style="display:none" aria-label="Hidden field" required>
        <section hidden><input aria-label="Hidden ancestor field" required></section>
        <button id="send" type="submit">Continue</button><button id="ordinary" type="button">Ordinary</button></form>
        <script>window.clicks=0;window.requests=0;window.submits=0;
        document.getElementById('form').addEventListener('submit',e=>{e.preventDefault();window.submits++;});
        document.getElementById('send').addEventListener('click',()=>{
          window.clicks++;window.requests++;fetch('data:text/plain,independent-handler-request');
          document.getElementById('foreign').checkValidity();
          document.getElementById('synthetic').dispatchEvent(new Event('invalid',{bubbles:false}));
          document.getElementById('synthetic').value='now valid';
          let fresh=document.createElement('input');fresh.required=true;fresh.setAttribute('aria-label','Uncaptured field');document.getElementById('form').append(fresh);
        });
        document.getElementById('ordinary').addEventListener('click',()=>document.getElementById('visible').checkValidity());
        </script></body>
        """
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let transport = EmbeddedBrowserTabTransport(session: session, script: instrumented)
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString(html, baseURL: URL(string: "http://localhost:8123/feedback"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let visibility = try await script(view, """
        const form=document.getElementById('form');
        return {clobbered:form.hidden===document.getElementById('hidden'),attribute:Element.prototype.hasAttribute.call(form,'hidden')};
        """)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: visibility) as? [String: Bool], ["clobbered": true, "attribute": false])
        let available = try await transport.target(id: id.uuidString), target = try XCTUnwrap(available)
        let observed = try await transport.observe(target: target)
        XCTAssertFalse(observed.nodes.contains { ["Hidden field", "Hidden ancestor field"].contains($0.name) })
        let button = try XCTUnwrap(observed.nodes.first { $0.name == "Continue" })
        let response = try await transport.pressWithFeedback(target: target, backendNodeID: XCTUnwrap(button.backendNodeID),
            document: observed, permit: BrowserMutationPermit())
        let feedback = try XCTUnwrap(response)
        XCTAssertNotNil(feedback.committedDocumentID)
        XCTAssertEqual(feedback.committedDocumentID, observed.committedDocumentID)
        XCTAssertEqual(feedback.fields.map(\.backendNodeID), try ["Visible field", "Second field", "Third field"].map { label in
            try XCTUnwrap(observed.nodes.first { $0.name == label }?.backendNodeID)
        })
        XCTAssertEqual(feedback.fields.first?.issues, [.valueMissing])
        XCTAssertTrue(feedback.truncated, "Extra visible invalid fields stay bounded rather than expanding the result")
        let counts = try await script(view, "return {clicks:window.clicks,requests:window.requests,submits:window.submits,active:Number(document.documentElement.dataset.listenerActive)};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: counts) as? [String: Int],
                       ["clicks": 1, "requests": 1, "submits": 0, "active": 0],
                       "An invalid event does not prove that a click handler made no independent request")
        let fresh = try await transport.observe(target: target)
        let ordinary = try XCTUnwrap(fresh.nodes.first { $0.name == "Ordinary" })
        let later = try await transport.pressWithFeedback(target: target, backendNodeID: XCTUnwrap(ordinary.backendNodeID),
            document: fresh, permit: BrowserMutationPermit())
        XCTAssertNil(later, "Non-submit clicks must not adopt unrelated invalid events")
        let inactive = try await script(view, "return document.documentElement.dataset.listenerActive;")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: inactive, options: [.fragmentsAllowed]) as? String, "0")
    }

    func testRealWebKitReadOnlyGridcellCannotSubstituteForItsSameLabelLink() async throws {
        let html = """
        <!doctype html><html><body><main>
        <div role="gridcell" aria-label="Shared fixture title"><span role="link" tabindex="0" id="link"
          onclick="window.clicks=(window.clicks||0)+1;document.getElementById('result').textContent='Opened fixture';">Shared fixture title</span></div>
        <p id="result">Unopened fixture</p></main></body></html>
        """
        func reference(_ read: String, role: String) throws -> [String: Any] {
            let row = try XCTUnwrap(read.split(separator: "\n").first {
                $0.hasPrefix("#") && $0.contains("semantic_role=\"\(role)\"")
            }, read)
            return self.reference(in: row)
        }
        for change in ["unchanged", "disabled", "replaced"] {
            let session = EmbeddedBrowserSession(persistent: false)
            let transport = EmbeddedBrowserTabTransport(session: session)
            let renderWindow = attachRenderHost(to: session)
            defer { renderWindow.close() }
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
            XCTAssertTrue(row.contains("label=\"Shared fixture title\""), "The passive wrapper and actionable child deliberately share a label")
            XCTAssertTrue(content.contains("Defaults enabled=true settable=false actions=[]"))
            XCTAssertFalse(row.contains("click_ref=")); XCTAssertFalse(row.contains("fill_ref="))
            XCTAssertFalse(row.contains("enabled=false"))
            XCTAssertFalse(content.contains("semantic_role=\"link\""), "Content and action views are distinct")
            let containerData = try JSONSerialization.data(withJSONObject: container)
            do {
                try await controller.preflightMutation(taskKey: "grid", tool: "browser_click", arguments: containerData)
                XCTFail("An enabled content wrapper has no inherited press capability")
            } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
            do {
                _ = try await controller.execute(taskKey: "grid", tool: "browser_click", arguments: containerData)
                XCTFail("Direct execution must not retarget to the child")
            } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
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

    /// The older flight fixture reads input.value directly when clicked. That
    /// cannot detect a visible DOM value that never reached application state.
    /// This fixture models a controlled field's per-element value tracker and
    /// delegated input listener in the page world; the driver runs separately
    /// in its production isolated world. It is not a claim about Outlook's
    /// particular framework implementation.
    func testRealWebKitFillUpdatesDelegatedControlledStateBeforeSubmittingSearch() async throws {
        for kind in ["text", "search", "textarea"] {
            let fieldMarkup = kind == "textarea"
                ? "<textarea id='query' aria-label='Search query'></textarea>"
                : "<input id='query' type='\(kind)' aria-label='Search query'>"
            let html = """
            <!doctype html><html><body><main>
            \(fieldMarkup)<button id="search">Search</button>
            <output id="result">Previous results</output>
            <script>
            (() => {
              const field = document.getElementById('query');
              const prototype = field.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              const nativeValue = Object.getOwnPropertyDescriptor(prototype, 'value');
              let modelQuery = 'prior-query', trackedValue = modelQuery;
              let events = [], updates = 0, submits = 0, focuses = 0, blurs = 0;
              // Framework-owned writes update both the DOM and its tracker.
              // Native user edits (or the driver's native setter) change only
              // the DOM until the delegated input listener reconciles state.
              Object.defineProperty(field, 'value', {
                configurable: true,
                get() { return nativeValue.get.call(this); },
                set(value) { trackedValue = String(value); nativeValue.set.call(this, value); }
              });
              const render = () => { field.value = modelQuery; };
              render();
              field.addEventListener('focus', () => { focuses++; render(); });
              field.addEventListener('blur', () => { blurs++; render(); });
              document.addEventListener('input', event => {
                if (event.target !== field) return;
                events.push({type: event.type, focused: document.activeElement === field});
                const next = field.value;
                if (next !== trackedValue) {
                  trackedValue = next;
                  modelQuery = next;
                  updates++;
                  render();
                }
              });
              document.addEventListener('change', event => {
                if (event.target === field) events.push({type: event.type, focused: document.activeElement === field});
              });
              document.getElementById('search').addEventListener('click', () => {
                field.blur();
                submits++;
                // Deliberately use application state, never the field's value.
                document.getElementById('result').textContent = 'Results for ' + modelQuery;
              });
              window.controlledFieldAudit = () => ({modelQuery, domValue: field.value, updates, submits, focuses, blurs, events});
              window.resetControlledFieldDiagnostics = () => { events = []; focuses = 0; blurs = 0; };
            })();
            </script></main></body></html>
            """
            let session = EmbeddedBrowserSession(persistent: false)
            let transport = EmbeddedBrowserTabTransport(session: session)
            defer { session.shutdown() }
            let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
            view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            view.loadHTMLString(html, baseURL: URL(string: "http://localhost:8123/controlled-search"))
            try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))

            // Prove the oracle rejects the DOM-only implementation the previous
            // fixture would accept, then restore the original controlled state.
            let negative = try await script(view, """
                const field = document.getElementById('query');
                field.focus(); field.value = 'DOM-only';
                field.dispatchEvent(new Event('input', {bubbles: true}));
                return window.controlledFieldAudit();
                """)
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: negative) as? [String: Any])
            XCTAssertEqual(before["domValue"] as? String, "DOM-only", kind)
            XCTAssertEqual(before["modelQuery"] as? String, "prior-query", kind)
            XCTAssertEqual(before["updates"] as? Int, 0, kind)
            _ = try await script(view, "document.getElementById('query').blur(); window.resetControlledFieldDiagnostics(); return true;")

            let targetValue = try await transport.target(id: id.uuidString)
            let target = try XCTUnwrap(targetValue)
            let observed = try await transport.observe(target: target)
            let field = try XCTUnwrap(observed.nodes.first { $0.name == "Search query" && $0.isEditable })
            XCTAssertEqual(field.value, "prior-query", "Blur must restore retained application state")
            let query = "ODE & exact + search"
            try await transport.setText(target: target, backendNodeID: XCTUnwrap(field.backendNodeID),
                text: query, document: observed, permit: BrowserMutationPermit())
            let auditData = try await script(view, "return window.controlledFieldAudit();")
            let filled = try XCTUnwrap(JSONSerialization.jsonObject(with: auditData) as? [String: Any])
            XCTAssertEqual(filled["modelQuery"] as? String, query, "Delegated page-world state must receive the isolated-world fill: \(kind)")
            XCTAssertEqual(filled["domValue"] as? String, query, kind)
            XCTAssertEqual(filled["updates"] as? Int, 1, kind)
            XCTAssertEqual(filled["focuses"] as? Int, 1, kind)
            XCTAssertEqual(filled["submits"] as? Int, 0, "Fill must not submit")
            let events = try XCTUnwrap(filled["events"] as? [[String: Any]])
            XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["input", "change"], kind)
            XCTAssertTrue(events.allSatisfy { $0["focused"] as? Bool == true }, kind)

            let afterFill = try await transport.observe(target: target)
            let button = try XCTUnwrap(afterFill.nodes.first { $0.role == "button" && $0.name == "Search" })
            try await transport.press(target: target, backendNodeID: XCTUnwrap(button.backendNodeID),
                document: afterFill, permit: BrowserMutationPermit())
            let afterSubmit = try await transport.observe(target: target)
            XCTAssertTrue(afterSubmit.nodes.contains { $0.name == "Results for " + query }, kind)
            let submittedData = try await script(view, "return window.controlledFieldAudit();")
            let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: submittedData) as? [String: Any])
            XCTAssertEqual(submitted["modelQuery"] as? String, query, kind)
            XCTAssertEqual(submitted["domValue"] as? String, query, "Blur re-render must preserve the accepted query: \(kind)")
            XCTAssertEqual(submitted["updates"] as? Int, 1, kind)
            XCTAssertEqual(submitted["submits"] as? Int, 1, kind)
            XCTAssertEqual(submitted["blurs"] as? Int, 1, kind)
        }
    }

    func testNativeInputUnderContentEditableUsesItsValuePropertyAndPreservesItsChildren() async throws {
        try await verifyNativeValueUnderContentEditable("input")
    }

    func testNativeTextareaUnderContentEditableUsesItsValuePropertyAndPreservesDefaultValue() async throws {
        try await verifyNativeValueUnderContentEditable("textarea")
    }

    func testNativeSelectUnderContentEditableUsesItsValuePropertyAndPreservesOptions() async throws {
        try await verifyNativeValueUnderContentEditable("select")
    }

    func testActualContentEditableStillUsesItsRenderedTextAndDispatchesOneEventPair() async throws {
        try await verifyNativeValueUnderContentEditable("contenteditable")
    }

    private func verifyNativeValueUnderContentEditable(_ kind: String) async throws {
        let (session, transport, view, target, window) = try await nativeValueFixture(kind)
        defer { session.shutdown(); window.close() }
        let beforeData = try await script(view, "return window.nativeValueAudit();")
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeData) as? [String: Any])
        XCTAssertEqual(before["contentEditable"] as? Bool, true, "Real WebKit must exercise inherited editability: \(kind)")
        XCTAssertEqual(before["value"] as? String, "prior-value", kind)
        let observed = try await transport.observe(target: target)
        let field = try XCTUnwrap(observed.nodes.first { $0.name == "Fixture field" })
        XCTAssertTrue(field.isEditable, kind)
        XCTAssertEqual(field.value, "prior-value", "Observed native value must not be replaced by inherited contenteditable text: \(kind)")
        try await transport.setText(target: target, backendNodeID: XCTUnwrap(field.backendNodeID), text: "next-value",
            document: observed, permit: BrowserMutationPermit())
        let afterData = try await script(view, "return window.nativeValueAudit();")
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [String: Any])
        XCTAssertEqual(after["value"] as? String, "next-value", "Successful fill must update the actual native value property: \(kind)")
        if kind != "contenteditable" {
            XCTAssertEqual(after["text"] as? String, before["text"] as? String, "Native fill must not replace input/textarea/select children: \(kind)")
            XCTAssertEqual(after["defaultValue"] as? String, before["defaultValue"] as? String, kind)
            XCTAssertEqual(after["options"] as? [String], before["options"] as? [String], kind)
        } else {
            XCTAssertEqual(after["text"] as? String, "next-value")
        }
        let events = try XCTUnwrap(after["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["input", "change"], kind)
        XCTAssertEqual(events.compactMap { $0["value"] as? String }, ["next-value", "next-value"], kind)
        XCTAssertTrue(events.allSatisfy { $0["focused"] as? Bool == true }, kind)
        let fresh = try await transport.observe(target: target)
        XCTAssertEqual(fresh.nodes.first { $0.name == "Fixture field" }?.value, "next-value", kind)
    }

    func testInheritedContentEditableCannotGrantNativeUnsupportedSecureOrReadOnlyFieldsInputAuthority() async throws {
        for kind in ["file", "checkbox", "password", "readonly", "disabled"] {
            let (session, transport, view, target, window) = try await nativeValueFixture(kind)
            defer { session.shutdown(); window.close() }
            let beforeData = try await script(view, "return window.nativeValueAudit();")
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeData) as? [String: Any])
            XCTAssertEqual(before["contentEditable"] as? Bool, true, kind)
            let observed = try await transport.observe(target: target)
            let field = try XCTUnwrap(observed.nodes.first { $0.name == "Fixture field" })
            XCTAssertTrue(field.isReadOnly || field.isDisabled || !field.isEditable, kind)
            if ["file", "checkbox", "password"].contains(kind) { XCTAssertNil(field.value, kind) }
            do {
                try await transport.setText(target: target, backendNodeID: XCTUnwrap(field.backendNodeID), text: "MUST_NOT_APPEAR",
                    document: observed, permit: BrowserMutationPermit())
                XCTFail("Inherited editability cannot authorize native \(kind) input")
            } catch { }
            let afterData = try await script(view, "return window.nativeValueAudit();")
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [String: Any])
            XCTAssertEqual(after["value"] as? String, before["value"] as? String, kind)
            XCTAssertEqual(after["text"] as? String, before["text"] as? String, kind)
            XCTAssertTrue(try XCTUnwrap(after["events"] as? [Any]).isEmpty, kind)
        }
    }

    private func nativeValueFixture(_ kind: String) async throws
        -> (EmbeddedBrowserSession, EmbeddedBrowserTabTransport, WKWebView, BrowserTarget, NSWindow) {
        let markup: String
        switch kind {
        case "textarea": markup = "<textarea id='field' aria-label='Fixture field'>default-value</textarea>"
        case "select": markup = "<select id='field' aria-label='Fixture field'><option value='prior-value'>Prior option</option><option value='next-value'>Next option</option></select>"
        case "contenteditable": markup = "<div id='field' aria-label='Fixture field' role='textbox' contenteditable='true'>prior-value</div>"
        case "file", "checkbox", "password": markup = "<input id='field' aria-label='Fixture field' role='textbox' type='\(kind)'>"
        case "readonly", "disabled": markup = "<input id='field' aria-label='Fixture field' type='text' \(kind)>"
        default: markup = "<input id='field' aria-label='Fixture field' type='text' value='default-value'>"
        }
        let session = EmbeddedBrowserSession(persistent: false), window = attachRenderHost(to: session)
        let transport = EmbeddedBrowserTabTransport(session: session)
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let inherited = kind == "contenteditable" ? "" : "contenteditable='true'"
        view.loadHTMLString("""
            <!doctype html><main><div \(inherited)>\(markup)</div></main><script>
            const field=document.getElementById('field'), native=field.tagName!=='DIV', events=[];
            if(native && field.type!=='file') field.value='prior-value';
            const value=()=>native ? field.value : field.innerText;
            for(const type of ['input','change']) document.addEventListener(type,event=>{
              if(event.target===field)events.push({type,value:value(),focused:document.activeElement===field});
            });
            window.nativeValueAudit=()=>({contentEditable:field.isContentEditable,value:value(),text:field.textContent,
              defaultValue:field.defaultValue ?? null,options:field.options ? Array.from(field.options).map(option=>option.value) : [],events});
            </script>
            """, baseURL: URL(string: "http://localhost:8123/native-value-\(kind)"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString)
        let target = try XCTUnwrap(available)
        try await transport.acquireRendering(target: target, lifetime: BrowserTabLifetime())
        return (session, transport, view, target, window)
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
        let text=try XCTUnwrap(observation.nodes.first { $0.name=="Unicode role" })
        XCTAssertEqual(text.role,"statictext")
        let parentID=try XCTUnwrap(text.parentNodeID)
        let limited=try XCTUnwrap(observation.nodes.first { $0.nodeID==parentID })
        XCTAssertEqual(limited.role,"generic")
        XCTAssertEqual(limited.name,"")
        XCTAssertTrue(limited.childNodeIDs.contains(try XCTUnwrap(text.nodeID)))
        XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.isDOMClickable)
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
        let text=try XCTUnwrap(observation.nodes.first { $0.name=="Expanded role" })
        XCTAssertEqual(text.role,"statictext")
        let parentID=try XCTUnwrap(text.parentNodeID)
        let limited=try XCTUnwrap(observation.nodes.first { $0.nodeID==parentID })
        XCTAssertEqual(limited.role,"generic")
        XCTAssertEqual(limited.name,"")
        XCTAssertTrue(limited.childNodeIDs.contains(try XCTUnwrap(text.nodeID)))
        XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.isDOMClickable)
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
        let renderWindow = attachRenderHost(to: session)
        defer { renderWindow.close() }
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
        XCTAssertTrue(read.contains("Defaults enabled=true settable=false actions=[]"))
        XCTAssertFalse(popup.contains("enabled=false")); XCTAssertFalse(popup.contains("click_ref="))
        XCTAssertFalse(popup.contains("follow_link=true"))
        XCTAssertTrue(ordinary.contains("actions=[\"AXPress\"]")); XCTAssertTrue(ordinary.contains("follow_link=true"))
        func arguments(_ row: Substring) throws -> Data {
            try JSONSerialization.data(withJSONObject: reference(in: row))
        }
        do {
            _ = try await controller.execute(taskKey: "popup-link", tool: "browser_click", arguments: arguments(popup))
            XCTFail("A popup-only link is read-only before any backend input")
        } catch { XCTAssertEqual(error as? EmbeddedBrowserActionReferences.Failure, .invalidReference) }
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
        let pending = Task { try await transport.observeForRead(target: target) }
        try await waitForSemanticObserver(view)
        _ = try await script(view, "const p=document.createElement('p');p.textContent='Rendered fixture content';document.body.appendChild(p);return true;")
        let observed = try await pending.value
        XCTAssertEqual(observed.semanticReadiness, .ready)
        XCTAssertTrue(observed.nodes.contains { $0.role == "statictext" && $0.name == "Rendered fixture content" })
        XCTAssertEqual(observed.loaderID, generation?.uuidString)
        XCTAssertEqual(observed.title, "Outlook")
    }

    func testFreshContentReadWaitsForAsyncSearchBodyDespiteReadyToolbarAndPreservesResultActions() async throws {
        let body = """
        <div role="toolbar"><input id="query" type="search" aria-label="Search query">
        <button id="search">Search</button><p>Toolbar text is not a result</p></div>
        <nav><p>Navigation text is not a result</p></nav><footer>Footer text is not a result</footer>
        <div id="results"></div>
        <script>document.getElementById('search').onclick=()=>{
          window.submitted=document.getElementById('query').value;
          window.searches=(window.searches||0)+1;
          document.getElementById('results').replaceChildren();
          new Promise(resolve=>window.releaseSearch=resolve).then(html=>{
            document.getElementById('results').innerHTML=html;window.rendered=true;
          });
        };</script>
        """
        let cases: [(String, String, String)] = [
            ("positive", "<main><p>Fixture announcement: ODE exam on 8 November.</p></main>", "Fixture announcement: ODE exam on 8 November."),
            ("negative", "<main><p>No messages match the fixture query.</p></main>", "No messages match the fixture query."),
            ("unknown-scope", "<p>Readable fixture without landmarks.</p>", "Readable fixture without landmarks."),
            ("listbox", "<aside aria-label='Message list'><div role='listbox'><div role='group'><div id='result' role='option' onclick='window.resultOpens=(window.resultOpens||0)+1'>Selectable fixture announcement</div></div></div></aside>", "Selectable fixture announcement"),
        ]
        for (name, markup, expected) in cases {
            let (session, transport, view, target) = try await semanticReadinessFixture(body: body)
            defer { session.shutdown() }
            let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
            let binding = try await broker.bindBorrowed(taskKey: name, processIdentifier: 42, target: target)
            let first = try await broker.snapshot(taskKey: name, binding: binding,
                bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
            let field = try XCTUnwrap(first.snapshot.elements.first { $0.label == "Search query" })
            try await broker.setText(taskKey: name, binding: first.binding, snapshot: first.snapshot,
                elementIndex: field.index, text: "ODE")
            let filled = try await broker.snapshot(taskKey: name, binding: first.binding,
                bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
            let button = try XCTUnwrap(filled.snapshot.elements.first { $0.label == "Search" })
            try await broker.perform(taskKey: name, binding: filled.binding, snapshot: filled.snapshot,
                elementIndex: button.index, action: "AXPress")
            let submitted = try await script(view, "return {query:window.submitted,count:window.searches,rendered:window.rendered||false};")
            let submission = try XCTUnwrap(JSONSerialization.jsonObject(with: submitted) as? [String: Any])
            XCTAssertEqual(submission["query"] as? String, "ODE"); XCTAssertEqual(submission["count"] as? Int, 1)
            XCTAssertEqual(submission["rendered"] as? Bool, false)
            let fast = try await transport.observeForRead(target: target)
            XCTAssertEqual(fast.semanticReadiness, .ready, "Broad/post-action reads retain their fast toolbar observation")
            let before = try await script(view, "return document.documentElement.hasAttribute('data-computa-readiness-test-armed');")
            XCTAssertEqual(before, Data("false".utf8), "Binding, action preflight and broad reads do not await body text")

            let pending = Task { try await broker.snapshot(taskKey: name, binding: filled.binding,
                bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .content)) }
            try await waitForSemanticObserver(view)
            let literal = String(decoding: try JSONSerialization.data(withJSONObject: markup, options: .fragmentsAllowed), as: UTF8.self)
            _ = try await script(view, "window.releaseSearch(\(literal));return true;")
            let result = try await pending.value
            XCTAssertTrue(result.snapshot.formattedText.contains("semantic_readiness=ready"))
            XCTAssertTrue(result.snapshot.elements.contains { $0.label == expected }, name)
            XCTAssertFalse(result.snapshot.elements.contains { $0.label.contains("not a result") || $0.value == "ODE" })
            XCTAssertEqual(result.snapshot.loaderID, first.snapshot.loaderID)
            XCTAssertEqual(result.snapshot.tabHandle, first.snapshot.tabHandle)
            XCTAssertNotEqual(result.snapshot.id, filled.snapshot.id)
            XCTAssertFalse(result.snapshot.sourceTruncated)
            if name == "listbox" {
                let option = try XCTUnwrap(result.snapshot.elements.first { $0.semanticRole == "option" })
                XCTAssertEqual(option.contentScope, .complementary); XCTAssertEqual(option.contentKind, .control)
                XCTAssertTrue(option.supportsPress)
                try await broker.perform(taskKey: name, binding: result.binding, snapshot: result.snapshot,
                    elementIndex: option.index, action: "AXPress")
                let opened = try await script(view, "return window.resultOpens;")
                XCTAssertEqual(opened, Data("1".utf8), "The ready result retains its own current action reference")
            }
            _ = try await script(view, "document.documentElement.removeAttribute('data-computa-readiness-test-armed');return true;")
            let miss = try await broker.snapshot(taskKey: name, binding: result.binding,
                bundleIdentifier: "com.ahmedelamin.computa", read: .init(query: "unique-local-filter-miss", view: .content))
            XCTAssertTrue(miss.snapshot.elements.isEmpty)
            XCTAssertTrue(miss.snapshot.formattedText.contains("semantic_readiness=ready"))
            XCTAssertTrue(miss.snapshot.formattedText.contains("site_search_evaluated\":false"))
            let after = try await script(view, "return document.documentElement.hasAttribute('data-computa-readiness-test-armed');")
            XCTAssertEqual(after, Data("false".utf8), "A local query miss never waits for a website search or hides its actual empty state")
            try await broker.revoke(taskKey: name, binding: miss.binding)
        }
    }

    func testContentReadDeadlineDoesNotTreatControlsHiddenFrameOrShadowTextAsBody() async throws {
        let body = """
        <div role='toolbar'><input aria-label='Query' value='Input echo'><button>Search</button><p>Toolbar preview</p></div>
        <nav><p>Navigation preview</p></nav><main aria-label='Region metadata'><p hidden>Hidden body sentinel</p></main>
        <iframe srcdoc='<p>Frame body sentinel</p>'></iframe><div id='shadow' style='height:20px'></div>
        <script>document.getElementById('shadow').attachShadow({mode:'open'}).innerHTML='<p>Shadow body sentinel</p>';</script>
        """
        let (session, transport, view, target) = try await semanticReadinessFixture(body: body, timeoutMS: 80)
        defer { session.shutdown() }
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: "content-timeout", processIdentifier: 42, target: target)
        let fast = try await transport.observeForRead(target: target)
        XCTAssertEqual(fast.semanticReadiness, .ready)
        let pending = Task { try await broker.snapshot(taskKey: "content-timeout", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .content)) }
        try await waitForSemanticObserver(view)
        let read = try await pending.value
        XCTAssertTrue(read.snapshot.elements.isEmpty)
        XCTAssertTrue(read.snapshot.formattedText.contains("semantic_readiness=empty_at_deadline"))
        XCTAssertTrue(read.snapshot.formattedText.contains("Controls may already be present"))
        XCTAssertTrue(read.snapshot.formattedText.contains("does not establish website search results or absent content"))
        XCTAssertFalse(read.snapshot.formattedText.contains("Only a document shell or footer"))
        XCTAssertTrue(read.snapshot.sourceTruncated, "Frame/shadow boundaries remain explicit; no extra capture was attempted")
        XCTAssertFalse(read.snapshot.formattedText.contains("body sentinel"))
        try await broker.revoke(taskKey: "content-timeout", binding: read.binding)
    }

    func testDisplayContentsWrappersRetainRenderedTextControlsAndContentReadiness() async throws {
        let body = """
        <div role='toolbar'><button>Ready toolbar</button></div>
        <main id='landmark' style='display:contents'>
          <div id='wrapper' style='display:contents'>
            VISIBLE_DIRECT_TEXT
            <p id='body-text'>VISIBLE_CONTENTS_BODY</p>
            <button id='action'>VISIBLE_CONTENTS_ACTION</button>
          </div>
        </main>
        """
        let (session, transport, view, target) = try await semanticReadinessFixture(body: body, timeoutMS: 80)
        defer { session.shutdown() }
        let layoutBytes = try await script(view, """
        return {landmarkRects:document.getElementById('landmark').getClientRects().length,
          wrapperRects:document.getElementById('wrapper').getClientRects().length,
          bodyRects:document.getElementById('body-text').getClientRects().length,
          actionRects:document.getElementById('action').getClientRects().length};
        """)
        let layout = try XCTUnwrap(JSONSerialization.jsonObject(with: layoutBytes) as? [String: Int])
        XCTAssertEqual(layout["landmarkRects"], 0)
        XCTAssertEqual(layout["wrapperRects"], 0)
        XCTAssertGreaterThan(try XCTUnwrap(layout["bodyRects"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(layout["actionRects"]), 0)
        let raw = try await transport.observe(target: target)
        XCTAssertTrue(raw.nodes.contains { $0.name == "VISIBLE_CONTENTS_BODY" },
                      "A boxless display:contents wrapper does not hide its rendered descendants")
        XCTAssertTrue(raw.nodes.contains { $0.name == "VISIBLE_DIRECT_TEXT" },
                      "Bare text uses its own rendered range, not the boxless parent's missing rect")
        XCTAssertTrue(raw.nodes.contains { $0.name == "VISIBLE_CONTENTS_ACTION" && $0.isDOMClickable },
                      "The actual rendered child control remains observable; no wrapper gains its action")
        let content = try await transport.observeForRead(target: target, readiness: .content)
        XCTAssertEqual(content.semanticReadiness, .ready,
                       "Rendered body text below a boxless wrapper must release content readiness")
        XCTAssertTrue(content.nodes.contains { $0.name == "VISIBLE_CONTENTS_BODY" })
        XCTAssertFalse(raw.sourceTruncated, "This small light-DOM fixture has no capture boundary")
        let diagnostics = try XCTUnwrap(transport.captureDiagnosticsForTesting)
        XCTAssertEqual(diagnostics.stopReason, .none)
        XCTAssertEqual(diagnostics.boxlessContents, 2)
        XCTAssertEqual(diagnostics.emitted, content.nodes.count)
    }

    func testNamedDOMContainersPreserveConversationAndMessageAncestryWithoutNewActions() async throws {
        let body = """
        <main><section aria-label="Conversation">
          <div aria-label="Message" onclick="window.wrapperClicks=(window.wrapperClicks||0)+1" tabindex="0" style="cursor:pointer">
            <h2>Shared subject</h2><span>Sender A</span><h3>File-A.pdf</h3>
            <button onclick="event.stopPropagation();window.childClicks=(window.childClicks||0)+1">Existing child action</button>
          </div>
          <div aria-label="Message"><h2>Shared subject</h2><span>Sender B</span><h3>File-B.pdf</h3></div>
          <div role="group"><p>Unlabeled existing group</p></div>
          <div role="button" aria-label="Existing explicit action" onclick="window.explicitClicks=1"></div>
        </section></main>
        """
        let (session, transport, view, target) = try await semanticReadinessFixture(body: body)
        defer { session.shutdown() }
        let raw = try await transport.observe(target: target)
        let messages = raw.nodes.filter { $0.role == "group" && $0.name == "Message" }
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0.isExplicitlyNamedContainer && $0.isDisabled && $0.isReadOnly
            && !$0.isDOMClickable && !$0.isEditable && !$0.isFocusablePointer && $0.isPressUnsupported })
        XCTAssertFalse(messages.contains { $0.name.contains("Sender") || $0.name.contains("pdf") },
                       "The passive wrapper's label is not an aggregate of its messages or attachments")
        let unnamedBody = try XCTUnwrap(raw.nodes.first { $0.role == "statictext" && $0.name == "Unlabeled existing group" })
        let unnamed = try XCTUnwrap(raw.nodes.first { $0.nodeID == unnamedBody.parentNodeID })
        XCTAssertEqual(unnamed.role, "group")
        XCTAssertEqual(unnamed.name, "", "A structural container must not duplicate its descendant's text as a label")
        XCTAssertEqual(unnamed.childNodeIDs, [unnamedBody.nodeID], "The readable child retains the actual structural ancestor")
        XCTAssertFalse(unnamed.isExplicitlyNamedContainer, "Descendant text does not establish an explicitly named record")
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: "named-records", processIdentifier: 42, target: target)
        let content = try await broker.snapshot(taskKey: "named-records", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .content), compact: true)
        func path(_ label: String) throws -> [Int] {
            try XCTUnwrap(content.snapshot.elements.first { $0.label == label }).recordPath
        }
        XCTAssertEqual(try path("Sender A"), [1, 2]); XCTAssertEqual(try path("File-A.pdf"), [1, 2])
        XCTAssertEqual(try path("Sender B"), [1, 3]); XCTAssertEqual(try path("File-B.pdf"), [1, 3])
        XCTAssertEqual(content.snapshot.elements.filter { $0.label == "Shared subject" }.map(\.recordPath), [[1, 2], [1, 3]])
        XCTAssertEqual(try path("Unlabeled existing group"), [1])
        XCTAssertTrue(content.snapshot.formattedText.contains("not authorship"))
        let text = content.snapshot.formattedText + (try BrowserCompleteObservation.footer(cursor: content.snapshot.nextCursor))
        XCTAssertEqual(try BrowserCompleteObservation.excessBytes(text), 0)
        let all = try await broker.snapshot(taskKey: "named-records", binding: content.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        let wrapper = try XCTUnwrap(all.snapshot.elements.first { $0.semanticRole == "group" && $0.label == "Message" })
        XCTAssertFalse(wrapper.supportsPress); XCTAssertFalse(wrapper.supportsSetText)
        do {
            _ = try await broker.perform(taskKey: "named-records", binding: all.binding, snapshot: all.snapshot,
                elementIndex: wrapper.index, action: "AXPress")
            XCTFail("Naming never grants the wrapper an action")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .unsupportedAction("AXPress")) }
        let child = try XCTUnwrap(all.snapshot.elements.first { $0.label == "Existing child action" })
        XCTAssertTrue(child.supportsPress)
        try await broker.perform(taskKey: "named-records", binding: all.binding, snapshot: all.snapshot,
            elementIndex: child.index, action: "AXPress")
        let counts = try await script(view, "return {wrapper:window.wrapperClicks||0,child:window.childClicks||0};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: counts) as? [String: Int], ["wrapper": 0, "child": 1],
                       "New passive ancestry must agree with actual input revalidation of the unchanged child")
        XCTAssertTrue(raw.nodes.contains { $0.name == "Existing explicit action" && $0.isDOMClickable },
                      "Explicit control semantics remain unchanged")
    }

    func testPassiveContainerLabelsPreserveHiddenSecureMalformedAndBoxlessBoundaries() async throws {
        let body = """
        <main><h2 id="visible-label">Visible reference label</h2>
          <section aria-labelledby="visible-label"><p>Referenced body</p></section>
          <div aria-label="Boxless named container" style="display:contents" tabindex="0" onclick="window.bad=1">
            <p>Boxless body</p><input type="password" aria-label="Secure field" value="EXCLUDED_SECRET_VALUE">
          </div>
          <span hidden id="hidden-label">EXCLUDED_HIDDEN_LABEL</span>
          <div aria-labelledby="hidden-label"><p>Visible body with hidden reference</p></div>
          <div aria-labelledby="missing"><p>Missing reference body</p></div>
          <div aria-labelledby="visible-label missing"><p>Partly missing reference body</p></div>
          <div aria-labelledby="visible-label visible-label"><p>Repeated reference body</p></div>
          <div aria-labelledby="secure-label"><p>Secure reference body</p></div>
          <input id="secure-label" type="password" aria-label="Another secure field" value="EXCLUDED_OTHER_SECRET">
          <span id="aria-mixed">Visible aria label <span aria-hidden="true">EXCLUDED_ARIA_LABEL_CHILD</span></span>
          <div aria-labelledby="aria-mixed"><p>Aria mixed reference body</p></div>
          <span id="inert-mixed">Visible inert label <span inert>EXCLUDED_INERT_LABEL_CHILD</span></span>
          <div aria-labelledby="inert-mixed"><p>Inert mixed reference body</p></div>
          <span id="hidden-mixed">Visible hidden label <span hidden>EXCLUDED_HIDDEN_LABEL_CHILD</span></span>
          <div aria-labelledby="hidden-mixed"><p>Hidden mixed reference body</p></div>
          <div aria-label=" "><p>Empty label body</p></div>
          <div role="presentation" aria-label="Presentation remains unmapped"><p>Presentation body</p></div>
          <div hidden aria-label="EXCLUDED_HIDDEN_CONTAINER"><p>EXCLUDED_HIDDEN_BODY</p></div>
          <div aria-hidden="true" aria-label="EXCLUDED_ARIA_CONTAINER"><p>EXCLUDED_ARIA_BODY</p></div>
          <div inert aria-label="EXCLUDED_INERT_CONTAINER"><p>EXCLUDED_INERT_BODY</p></div>
        </main>
        """
        let (session, transport, _, target) = try await semanticReadinessFixture(body: body)
        defer { session.shutdown() }
        let raw = try await transport.observe(target: target)
        let groups = raw.nodes.filter { $0.role == "group" }
        XCTAssertEqual(Set(groups.map(\.name)), ["Visible reference label", "Boxless named container"])
        XCTAssertTrue(groups.allSatisfy { $0.isExplicitlyNamedContainer && $0.isDisabled && !$0.isEditable
            && !$0.isDOMClickable && !$0.isFocusablePointer && $0.isPressUnsupported })
        XCTAssertFalse(raw.nodes.contains { $0.name.contains("EXCLUDED_") || ($0.value ?? "").contains("EXCLUDED_") })
        XCTAssertTrue(raw.nodes.filter { $0.role == "textbox" }.allSatisfy { $0.value == nil && $0.isDisabled && !$0.isEditable })
        let boxless = try XCTUnwrap(groups.first { $0.name == "Boxless named container" })
        XCTAssertEqual(raw.nodes.first { $0.name == "Boxless body" }?.parentNodeID, boxless.nodeID)
        XCTAssertFalse(raw.nodes.contains { $0.name == "Presentation remains unmapped" })
        XCTAssertFalse(raw.sourceTruncated)
    }

    func testContainerNamingFlagStrictDecodeAndMissingFlagCompatibility() async throws {
        let (session, _, _, target) = try await semanticReadinessFixture(body: "<main><p>Fixture body</p></main>")
        defer { session.shutdown() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Computa/Resources/BrowserModels/browser-control.js"), encoding: .utf8)
        let anchor = "diagnostics.visited = visited; diagnostics.emitted = nodes.length; diagnostics.estimatedBytes = budget;"
        XCTAssertEqual(source.components(separatedBy: anchor).count, 2)
        for literal in ["null", "1", "0", "\"true\"", "{}", "[]"] {
            let modified = source.replacingOccurrences(of: anchor, with: anchor + " nodes[0].isExplicitlyNamedContainer = \(literal);")
            let transport = EmbeddedBrowserTabTransport(session: session, script: modified)
            do { _ = try await transport.observe(target: target); XCTFail("Reject malformed passive flag: \(literal)") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError, .browserUnavailable("The built-in page returned invalid container naming metadata.")) }
        }
        for statement in ["delete nodes[0].isExplicitlyNamedContainer;", "nodes[0].isExplicitlyNamedContainer = false;"] {
            let modified = source.replacingOccurrences(of: anchor, with: anchor + " " + statement)
            let observed = try await EmbeddedBrowserTabTransport(session: session, script: modified).observe(target: target)
            XCTAssertFalse(try XCTUnwrap(observed.nodes.first).isExplicitlyNamedContainer)
        }
    }

    func testCSSHiddenAncestorAllowsExplicitlyVisibleControlsWithoutExposingHiddenMetadata() async throws {
        try await verifyCSSVisibilityOverride("hidden")
    }

    func testCSSCollapsedAncestorAllowsExplicitlyVisibleControlsWithoutExposingHiddenMetadata() async throws {
        try await verifyCSSVisibilityOverride("collapse")
    }

    private func verifyCSSVisibilityOverride(_ visibility: String) async throws {
        let (session, transport, view, target, window) = try await cssVisibilityFixture(visibility)
        defer { session.shutdown(); window.close() }
        let oracle = try await script(view, """
            const parent=document.getElementById('toolbar'), action=document.getElementById('action');
            return {parent:getComputedStyle(parent).visibility, child:getComputedStyle(action).visibility,
              childHasBox:action.getClientRects().length>0,
              inherited:getComputedStyle(document.getElementById('inherited')).visibility};
            """)
        let shape = try XCTUnwrap(JSONSerialization.jsonObject(with: oracle) as? [String: Any])
        XCTAssertEqual(shape["parent"] as? String, visibility)
        XCTAssertEqual(shape["child"] as? String, "visible")
        XCTAssertEqual(shape["childHasBox"] as? Bool, true)
        XCTAssertEqual(shape["inherited"] as? String, visibility)
        let raw = try await transport.observe(target: target)
        let action = try XCTUnwrap(raw.nodes.first { $0.name == "Visible child action" },
            "WebKit renders a visibility:visible descendant even while its ancestor remains \(visibility)")
        let field = try XCTUnwrap(raw.nodes.first { $0.name == "Visible child field" })
        XCTAssertTrue(action.isDOMClickable); XCTAssertTrue(field.isEditable)
        let toolbar = try XCTUnwrap(raw.nodes.first { $0.nodeID == action.parentNodeID })
        let fieldParent = try XCTUnwrap(raw.nodes.first { $0.nodeID == field.parentNodeID })
        XCTAssertEqual(toolbar.role, "toolbar"); XCTAssertEqual(fieldParent.role, "textbox")
        for row in [toolbar, fieldParent] {
            XCTAssertTrue(row.isIgnored); XCTAssertTrue(row.isDisabled); XCTAssertTrue(row.isReadOnly)
            XCTAssertFalse(row.isDOMClickable); XCTAssertFalse(row.isEditable)
            XCTAssertEqual(row.name, ""); XCTAssertNil(row.value)
        }
        XCTAssertFalse(raw.nodes.contains { $0.name.contains("EXCLUDED_") || ($0.value ?? "").contains("EXCLUDED_") })
        let untouched = try await script(view, "return {clicks:window.clicks,inputs:window.inputs,hiddenClicks:window.hiddenClicks};")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: untouched) as? [String: Int],
            ["clicks": 0, "inputs": 0, "hiddenClicks": 0])
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: "css-\(visibility)", processIdentifier: 42, target: target)
        let all = try await broker.snapshot(taskKey: "css-\(visibility)", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        XCTAssertFalse(all.snapshot.elements.contains { $0.label.contains("EXCLUDED_") || ($0.value ?? "").contains("EXCLUDED_") })
        let observedAction = try XCTUnwrap(all.snapshot.elements.first { $0.label == "Visible child action" })
        try await broker.perform(taskKey: "css-\(visibility)", binding: all.binding, snapshot: all.snapshot,
            elementIndex: observedAction.index, action: "AXPress")
        let fresh = try await broker.snapshot(taskKey: "css-\(visibility)", binding: all.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        let observedField = try XCTUnwrap(fresh.snapshot.elements.first { $0.label == "Visible child field" })
        try await broker.setText(taskKey: "css-\(visibility)", binding: fresh.binding, snapshot: fresh.snapshot,
            elementIndex: observedField.index, text: "synthetic@example.test")
        let content = try await broker.snapshot(taskKey: "css-\(visibility)", binding: fresh.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .content))
        XCTAssertTrue(content.snapshot.elements.contains { $0.label == "Visible body" })
        for excluded in ["Visible child action", "VISIBLE_CONTROL_TEXT", "synthetic@example.test"] {
            XCTAssertFalse(content.snapshot.elements.contains { $0.label.contains(excluded) || ($0.value ?? "").contains(excluded) },
                "Ignored semantic ancestors must retain body-versus-control scope: \(excluded)")
        }
        let effects = try await script(view, "return {clicks:window.clicks,inputs:window.inputs,hiddenClicks:window.hiddenClicks,value:document.getElementById('field').value};")
        let final = try XCTUnwrap(JSONSerialization.jsonObject(with: effects) as? [String: Any])
        XCTAssertEqual(final["clicks"] as? Int, 1); XCTAssertEqual(final["inputs"] as? Int, 1)
        XCTAssertEqual(final["hiddenClicks"] as? Int, 0)
        XCTAssertEqual(final["value"] as? String, "synthetic@example.test")
        try await broker.revoke(taskKey: "css-\(visibility)", binding: content.binding)
    }

    func testCSSVisibilityOverrideCannotBypassCurrentHideObstructionOrChangedParent() async throws {
        let (session, transport, view, target, window) = try await cssVisibilityFixture("hidden")
        defer { session.shutdown(); window.close() }
        var observed = try await transport.observe(target: target)
        var action = try XCTUnwrap(observed.nodes.first { $0.name == "Visible child action" })
        _ = try await script(view, "document.getElementById('action').style.visibility='hidden'; return true;")
        do {
            try await transport.press(target: target, backendNodeID: XCTUnwrap(action.backendNodeID), document: observed, permit: BrowserMutationPermit())
            XCTFail("A currently hidden child cannot use a formerly visible reference")
        } catch { }
        _ = try await script(view, "document.getElementById('action').style.visibility='visible'; return true;")
        observed = try await transport.observe(target: target)
        let field = try XCTUnwrap(observed.nodes.first { $0.name == "Visible child field" })
        _ = try await script(view, "const cover=document.createElement('div');cover.id='cover';cover.style='position:fixed;inset:0;z-index:9999;background:white';document.body.append(cover);return true;")
        do {
            try await transport.setText(target: target, backendNodeID: XCTUnwrap(field.backendNodeID), text: "MUST_NOT_APPEAR", document: observed, permit: BrowserMutationPermit())
            XCTFail("The inherited visibility fix cannot bypass the real hit-test")
        } catch { }
        _ = try await script(view, "document.getElementById('cover').remove(); return true;")
        observed = try await transport.observe(target: target)
        action = try XCTUnwrap(observed.nodes.first { $0.name == "Visible child action" })
        _ = try await script(view, "const parent=document.getElementById('toolbar'), replacement=parent.cloneNode(false); parent.before(replacement); replacement.append(document.getElementById('action')); return true;")
        do {
            try await transport.press(target: target, backendNodeID: XCTUnwrap(action.backendNodeID), document: observed, permit: BrowserMutationPermit())
            XCTFail("A physical child moved to a new hidden semantic parent needs a fresh reference")
        } catch { }
        let effects = try await script(view, "return {clicks:window.clicks,inputs:window.inputs,value:document.getElementById('field').value};")
        let final = try XCTUnwrap(JSONSerialization.jsonObject(with: effects) as? [String: Any])
        XCTAssertEqual(final["clicks"] as? Int, 0); XCTAssertEqual(final["inputs"] as? Int, 0)
        XCTAssertEqual(final["value"] as? String, "")
    }

    func testCSSHiddenStructureAloneCannotEstablishSemanticReadiness() async throws {
        let body = """
        <div role="toolbar" aria-label="EXCLUDED_TOOLBAR" style="visibility:hidden">
          <button>EXCLUDED_ACTION</button><span style="visibility:visible"></span>
        </div>
        """
        let (session, transport, view, target) = try await semanticReadinessFixture(body: body, timeoutMS: 80)
        defer { session.shutdown() }
        let pending = Task { try await transport.observeForRead(target: target) }
        try await waitForSemanticObserver(view)
        let observed = try await pending.value
        XCTAssertEqual(observed.semanticReadiness, .emptyAtDeadline)
        XCTAssertFalse(observed.nodes.contains { $0.name.contains("EXCLUDED_") || ($0.value ?? "").contains("EXCLUDED_") })
        XCTAssertFalse(observed.nodes.contains { $0.isDOMClickable || $0.isEditable })
        XCTAssertFalse(observed.sourceTruncated, "CSS suppression is not a source-budget limit")
    }

    func testCSSHiddenStructureWithoutVisibleDescendantsDoesNotConsumeCaptureOutputBudget() async throws {
        let hidden = "<div role='button' aria-label='EXCLUDED_HIDDEN' style='visibility:hidden'>EXCLUDED_BODY</div>"
        let body = "<main>" + String(repeating: hidden, count: 700)
            + "<div role='toolbar' style='visibility:hidden'><button style='visibility:visible'>Later visible action</button></div></main>"
        let (session, transport, _, target) = try await semanticReadinessFixture(body: body)
        defer { session.shutdown() }
        let observed = try await transport.observe(target: target)
        let action = try XCTUnwrap(observed.nodes.first { $0.name == "Later visible action" })
        let parent = try XCTUnwrap(observed.nodes.first { $0.nodeID == action.parentNodeID })
        XCTAssertEqual(parent.role, "toolbar"); XCTAssertTrue(parent.isIgnored)
        XCTAssertFalse(observed.sourceTruncated, "Unrendered leaves must not starve later visible content by spending output bytes")
        XCTAssertLessThan(observed.nodes.count, 12)
        XCTAssertFalse(observed.nodes.contains { $0.name.contains("EXCLUDED_") })
        let diagnostic = try XCTUnwrap(transport.captureDiagnosticsForTesting)
        XCTAssertEqual(diagnostic.stopReason, .none)
        XCTAssertLessThan(diagnostic.estimatedBytes, 10_000)
    }

    func testDiscoveryDiagnosticsDistinguishBoundedPanelStatesWithoutReadingHiddenText() async throws {
        let body = """
        <main>
          <form><button>Rendered fixture action</button></form>
          <div role="dialog" style="display:none">EXCLUDED_DISPLAY<form></form></div>
          <div role="dialog" hidden style="display:block">EXCLUDED_HARD<form></form></div>
          <div role="dialog" style="visibility:hidden">EXCLUDED_VISIBILITY
            <button style="visibility:visible">Visible override</button>
          </div>
          <div role="dialog" style="display:contents"><p>Boxless fixture text</p></div>
        </main>
        """
        let (session, transport, _, target) = try await semanticReadinessFixture(body: body)
        defer { session.shutdown() }
        let observed = try await transport.observe(target: target)
        let diagnostic = try XCTUnwrap(transport.captureDiagnosticsForTesting)
        let discovery = try XCTUnwrap(diagnostic.discovery)
        XCTAssertEqual(discovery.panelsByState, [1, 1, 1, 1, 1])
        XCTAssertEqual(discovery.prunedSubtrees, 2, "Only outer-walk encountered hard exclusions are counted; their descendants remain unvisited")
        XCTAssertFalse(discovery.limitReached)
        XCTAssertFalse(observed.nodes.contains { $0.name.contains("EXCLUDED_") })
        XCTAssertTrue(observed.nodes.contains { $0.name == "Visible override" && $0.isDOMClickable })
        let encoded = try JSONEncoder().encode(diagnostic)
        XCTAssertLessThanOrEqual(encoded.count, 768)
        let text = String(decoding: encoded, as: UTF8.self)
        for privateText in ["EXCLUDED_", "fixture", "Visible override", "localhost"] {
            XCTAssertFalse(text.contains(privateText))
        }
    }

    private func cssVisibilityFixture(_ visibility: String) async throws
        -> (EmbeddedBrowserSession, EmbeddedBrowserTabTransport, WKWebView, BrowserTarget, NSWindow) {
        let session = EmbeddedBrowserSession(persistent: false), window = attachRenderHost(to: session)
        let transport = EmbeddedBrowserTabTransport(session: session)
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString("""
            <!doctype html><main><p>Visible body</p>
            <div id="toolbar" role="toolbar" aria-label="EXCLUDED_TOOLBAR_LABEL" style="visibility:\(visibility)">
              EXCLUDED_HIDDEN_TEXT<button id="action" style="visibility:visible" onclick="window.clicks++">Visible child action</button>
              <button id="inherited" onclick="window.hiddenClicks++">EXCLUDED_INHERITED_ACTION</button>
            </div>
            <div role="button" aria-label="EXCLUDED_CONTROL_LABEL" style="visibility:\(visibility)" onclick="window.hiddenClicks++">
              <span style="visibility:visible">VISIBLE_CONTROL_TEXT</span>
            </div>
            <div role="textbox" aria-label="EXCLUDED_FIELD_LABEL" style="visibility:\(visibility)">
              EXCLUDED_HIDDEN_VALUE<input id="field" aria-label="Visible child field" style="visibility:visible">
            </div>
            <div style="display:none"><button style="visibility:visible">EXCLUDED_DISPLAY_NONE_ACTION</button></div>
            <div hidden style="display:block"><button style="visibility:visible">EXCLUDED_HIDDEN_ATTRIBUTE_ACTION</button></div>
            <div inert><button style="visibility:visible">EXCLUDED_INERT_ACTION</button></div>
            <div aria-hidden="true"><button style="visibility:visible">EXCLUDED_ARIA_HIDDEN_ACTION</button></div>
            </main><script>window.clicks=0;window.inputs=0;window.hiddenClicks=0;
            document.addEventListener('input',()=>window.inputs++);</script>
            """, baseURL: URL(string: "http://localhost:8123/css-\(visibility)"))
        try await session.waitForHumanTabReady(id: id, until: .now + .seconds(10))
        let available = try await transport.target(id: id.uuidString)
        let target = try XCTUnwrap(available)
        try await transport.acquireRendering(target: target, lifetime: BrowserTabLifetime())
        return (session, transport, view, target, window)
    }

    func testDisplayContentsTraversalDoesNotExposeHiddenAriaHiddenOrInertDescendants() async throws {
        let body = """
        <main><p>VISIBLE_CONTROL_BODY</p>
          <div hidden><div style='display:contents'><p>EXCLUDED_HIDDEN_BODY</p><button>EXCLUDED_HIDDEN_ACTION</button></div></div>
          <div style='display:none'><div style='display:contents'><p>EXCLUDED_DISPLAY_NONE_BODY</p></div></div>
          <div style='visibility:hidden'><div style='display:contents'><p>EXCLUDED_VISIBILITY_BODY</p></div></div>
          <div aria-hidden='true'><div style='display:contents'><p id='aria-body'>EXCLUDED_ARIA_BODY</p><button>EXCLUDED_ARIA_ACTION</button></div></div>
          <div inert><div style='display:contents'><p id='inert-body'>EXCLUDED_INERT_BODY</p><input value='EXCLUDED_INERT_VALUE'></div></div>
        </main>
        """
        let (session, transport, view, target) = try await semanticReadinessFixture(body: body, timeoutMS: 80)
        defer { session.shutdown() }
        let laidOut = try await script(view, """
        return document.getElementById('aria-body').getClientRects().length > 0
          && document.getElementById('inert-body').getClientRects().length > 0;
        """)
        XCTAssertEqual(laidOut, Data("true".utf8), "ARIA-hidden and inert exclusions must hold even when descendants have layout boxes")
        for observation in [try await transport.observe(target: target),
                            try await transport.observeForRead(target: target, readiness: .content)] {
            XCTAssertTrue(observation.nodes.contains { $0.name == "VISIBLE_CONTROL_BODY" })
            XCTAssertFalse(observation.nodes.contains {
                $0.name.contains("EXCLUDED_") || ($0.value ?? "").contains("EXCLUDED_")
            }, "Traversing boxless wrappers must preserve every hidden/inert ancestor exclusion")
        }
    }

    func testBoxlessSemanticWrappersPreserveContentScopesWithoutInputAuthority() async throws {
        let body = """
        <main style='display:contents'><p>BODY_RESULT</p>
          <nav style='display:contents'><span>NAVIGATION_TEXT</span></nav>
          <div role='button' aria-label='Boxless control' style='display:contents'>CONTROL_TEXT
            <button onclick='window.childClicks=(window.childClicks||0)+1'>Rendered child action</button>
          </div>
          <div role='textbox' contenteditable='true' aria-label='Boxless field' style='display:contents'>FIELD_TEXT<span hidden>EXCLUDED_AGGREGATED_VALUE</span></div>
          <div role='heading' style='display:contents'>VISIBLE_WRAPPED_HEADING<span hidden>EXCLUDED_AGGREGATED_NAME</span></div>
        </main>
        """
        let (session, transport, view, target) = try await semanticReadinessFixture(body: body, timeoutMS: 80)
        defer { session.shutdown() }
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: "contents", processIdentifier: 42, target: target)
        let all = try await broker.snapshot(taskKey: "contents", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        XCTAssertFalse(all.snapshot.elements.contains {
            $0.label.contains("EXCLUDED_AGGREGATED_") || ($0.value ?? "").contains("EXCLUDED_AGGREGATED_")
        }, "A boxless wrapper's aggregate name/value must not bypass descendant hidden exclusions")
        let wrapper = try XCTUnwrap(all.snapshot.elements.first { $0.label == "Boxless control" })
        let field = try XCTUnwrap(all.snapshot.elements.first { $0.label == "Boxless field" })
        XCTAssertFalse(wrapper.isEnabled); XCTAssertFalse(wrapper.supportsPress)
        XCTAssertFalse(field.isEnabled); XCTAssertFalse(field.supportsSetText)
        do {
            try await broker.perform(taskKey: "contents", binding: all.binding, snapshot: all.snapshot,
                elementIndex: wrapper.index, action: "AXPress")
            XCTFail("A boxless semantic wrapper has no input authority")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .unsupportedAction("AXPress")) }
        let child = try XCTUnwrap(all.snapshot.elements.first { $0.label == "Rendered child action" })
        XCTAssertTrue(child.isEnabled); XCTAssertTrue(child.supportsPress)
        try await broker.perform(taskKey: "contents", binding: all.binding, snapshot: all.snapshot,
            elementIndex: child.index, action: "AXPress")
        let clicks = try await script(view, "return window.childClicks||0;")
        XCTAssertEqual(clicks, Data("1".utf8))
        let content = try await broker.snapshot(taskKey: "contents", binding: all.binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .content))
        XCTAssertTrue(content.snapshot.elements.contains { $0.label == "BODY_RESULT" })
        XCTAssertTrue(content.snapshot.elements.contains { $0.label == "VISIBLE_WRAPPED_HEADING" },
                      "Avoiding unsafe wrapper aggregation must preserve the separately rendered visible heading text")
        for excluded in ["NAVIGATION_TEXT", "CONTROL_TEXT", "FIELD_TEXT", "Rendered child action"] {
            XCTAssertFalse(content.snapshot.elements.contains { $0.label.contains(excluded) },
                           "Retained boxless ancestry must not promote navigation/control text into body content")
        }
        try await broker.revoke(taskKey: "contents", binding: content.binding)
    }

    func testCaptureDiagnosticsDistinguishBudgetAndCoverageBoundariesWithoutPageContent() async throws {
        let cases: [(String, String, BrowserCaptureDiagnostics.StopReason)] = [
            ("byte-budget", "<main>" + String(repeating: "<div role='group' aria-label='" + String(repeating: "x", count: 1_024) + "'><p>Fixture text</p></div>", count: 120) + "</main>", .byteBudget),
            ("boundaries", "<p>Visible fixture</p><iframe srcdoc='<p>Uncaptured frame</p>'></iframe><div id='shadow' style='height:20px'></div><script>document.getElementById('shadow').attachShadow({mode:'open'}).innerHTML='<p>Uncaptured shadow</p>';</script><button role='" + String(repeating: "r", count: 101) + "'>Oversized role</button><p>" + String(repeating: "x", count: 4_200) + "</p>", .none),
        ]
        for (name, body, stop) in cases {
            let (session, transport, _, target) = try await semanticReadinessFixture(body: body)
            defer { session.shutdown() }
            let capture = try await transport.observe(target: target)
            let diagnostics = try XCTUnwrap(transport.captureDiagnosticsForTesting)
            XCTAssertEqual(diagnostics.stopReason, stop, name)
            XCTAssertEqual(diagnostics.emitted, capture.nodes.count)
            XCTAssertTrue(capture.sourceTruncated)
            XCTAssertLessThanOrEqual(diagnostics.visited, 20_001)
            XCTAssertLessThanOrEqual(diagnostics.estimatedBytes, 1_000_000)
            XCTAssertGreaterThan(diagnostics.viewportWidth, 0); XCTAssertGreaterThan(diagnostics.viewportHeight, 0)
            if name == "byte-budget" {
                XCTAssertGreaterThan(diagnostics.estimatedBytes, 200_000)
                XCTAssertLessThanOrEqual(diagnostics.estimatedBytes, 220_000,
                    "Atomic visible-row and ancestry reservation stops before crossing the existing byte budget")
                XCTAssertEqual(diagnostics.frames + diagnostics.shadowRoots + diagnostics.oversizedRoles + diagnostics.clippedFields, 0)
            } else {
                XCTAssertEqual(diagnostics.frames, 1); XCTAssertEqual(diagnostics.shadowRoots, 1)
                XCTAssertEqual(diagnostics.oversizedRoles, 1); XCTAssertEqual(diagnostics.clippedFields, 1)
            }
            let encoded = try JSONEncoder().encode(diagnostics)
            XCTAssertLessThanOrEqual(encoded.count, 768)
            let text = String(decoding: encoded, as: UTF8.self)
            XCTAssertFalse(text.contains("Fixture")); XCTAssertFalse(text.contains("http"))
            var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            invalid["pageText"] = "MUST_NOT_LOG"
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(invalid, emitted: capture.nodes.count, sourceTruncated: true))
            invalid.removeValue(forKey: "pageText"); invalid["stopReason"] = "page_supplied_reason"
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(invalid, emitted: capture.nodes.count, sourceTruncated: true))
            invalid["stopReason"] = stop.rawValue; invalid["visited"] = 20_002
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(invalid, emitted: capture.nodes.count, sourceTruncated: true))
            invalid["visited"] = diagnostics.visited; invalid["visibilityState"] = "PAGE_PRIVATE_SENTINEL"
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(invalid, emitted: capture.nodes.count, sourceTruncated: true))
            invalid["visibilityState"] = diagnostics.visibilityState.rawValue; invalid["viewportWidth"] = -1
            XCTAssertThrowsError(try BrowserCaptureDiagnostics.decode(invalid, emitted: capture.nodes.count, sourceTruncated: true))
        }
    }

    func testBlankBindingAndMutationPreflightUseImmediateObservationWithoutWaitingForContent() async throws {
        let (session, transport, view, target) = try await semanticReadinessFixture()
        defer { session.shutdown() }
        let immediate = try await transport.observe(target: target)
        XCTAssertNil(immediate.semanticReadiness, "No semantic deadline was awaited for this identity observation")
        let broker = BrowserTabSessionBroker(transport: transport, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: "immediate", processIdentifier: 42, target: target)
        var armed = try await script(view, "return document.documentElement.hasAttribute('data-computa-readiness-test-armed');")
        XCTAssertEqual(armed, Data("false".utf8), "A blank binding does not register the semantic observer")
        _ = try await script(view, "const b=document.createElement('button');b.id='fixture-action';b.textContent='Continue';document.body.appendChild(b);return true;")
        let read = try await broker.snapshot(taskKey: "immediate", binding: binding,
            bundleIdentifier: "com.ahmedelamin.computa", read: .init(view: .all))
        let button = try XCTUnwrap(read.snapshot.elements.first { $0.label == "Continue" })
        _ = try await script(view, "document.getElementById('fixture-action').remove();return true;")
        do {
            try await broker.perform(taskKey: "immediate", binding: read.binding, snapshot: read.snapshot,
                                     elementIndex: button.index, action: "AXPress")
            XCTFail("The removed control cannot inherit input authority")
        } catch { XCTAssertEqual(error as? BrowserTabBrokerError, .elementNotFound) }
        armed = try await script(view, "return document.documentElement.hasAttribute('data-computa-readiness-test-armed');")
        XCTAssertEqual(armed, Data("false".utf8), "Mutation preflight observes the blank document immediately")
        try await broker.revoke(taskKey: "immediate", binding: read.binding)
    }

    func testSemanticReadinessNavigationContextFailureRemainsAStaleRead() async throws {
        for readiness in [BrowserReadReadiness.semanticContent, .content] {
        let (session, transport, view, target) = try await semanticReadinessFixture()
        defer { session.shutdown() }
        let pending = Task { try await transport.observeForRead(target: target, readiness: readiness) }
        try await waitForSemanticObserver(view)
        let id = try XCTUnwrap(UUID(uuidString: target.targetID))
        try session.navigate(tabID: id, to: XCTUnwrap(URL(string: "about:blank")))
        do { _ = try await pending.value; XCTFail("The old document cannot publish after navigation destroys its context") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError, .staleDocument) }
        XCTAssertTrue(session.webView(for: id) === view)
        }
    }

    func testSemanticReadinessCannotPublishAfterCancellationOrTabClosure() async throws {
        for readiness in [BrowserReadReadiness.semanticContent, .content] {
        for closed in [false, true] {
            let (session, transport, view, target) = try await semanticReadinessFixture()
            let pending = Task { try await transport.observeForRead(target: target, readiness: readiness) }
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
    }

    func testReadDeadlineWithoutJSReplyPreservesTimeoutOrReportsTheRetiredGeneration() async throws {
        for retired in [false, true] {
            let (session, _, view, target) = try await semanticReadinessFixture()
            let heldScript = """
            document.documentElement.setAttribute('data-computa-readiness-test-armed','yes');
            return await new Promise(resolve=>{
              document.addEventListener('computa-readiness-test-release',()=>resolve({}),{once:true});
            });
            """
            let transport = EmbeddedBrowserTabTransport(session: session, script: heldScript)
            let pending = Task { try await transport.observeForRead(target: target) }
            try await waitForSemanticObserver(view)
            if retired { session.stop(tabID: try XCTUnwrap(UUID(uuidString: target.targetID))) }
            do { _ = try await pending.value; XCTFail("A deliberately withheld JS response cannot publish content") }
            catch {
                if retired { XCTAssertEqual(error as? BrowserTabBrokerError, .staleDocument) }
                else {
                    XCTAssertEqual(error as? BrowserTabBrokerError,
                        .browserUnavailable("The built-in page observation timed out."))
                }
            }
            // Release the synthetic callback after the native deadline. It
            // cannot resume the already-finished result or regain authority.
            _ = try? await script(view, "document.dispatchEvent(new Event('computa-readiness-test-release'));return true;")
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

    private func semanticReadinessFixture(
        body: String = "<main aria-label='Outlook'></main>", timeoutMS: Int? = nil
    ) async throws -> (EmbeddedBrowserSession, EmbeddedBrowserTabTransport, WKWebView, BrowserTarget) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resource = root.appendingPathComponent("Sources/Computa/Resources/BrowserModels/browser-control.js")
        let source = try String(contentsOf: resource, encoding: .utf8)
        let registration = "observer.observe(document, {subtree:true,childList:true,characterData:true,attributes:true});"
        XCTAssertEqual(source.components(separatedBy: registration).count, 2)
        // A fixture-only DOM signal lets the test await actual observer
        // registration, without timing sleeps or polling either WebView.
        let instrumented = (timeoutMS.map { "input.timeoutMS = \($0);\n" } ?? "") + source.replacingOccurrences(of: registration, with:
            registration + "\ndocument.documentElement.setAttribute('data-computa-readiness-test-armed','yes');")
        let session = EmbeddedBrowserSession(persistent: false)
        let transport = EmbeddedBrowserTabTransport(session: session, script: instrumented)
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        view.loadHTMLString("<!doctype html><title>Outlook</title><body>\(body)</body>",
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

private final class BrowserReadAuthorizationAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func authorize(_ target: BrowserTarget, expectedURL: URL, denied: Bool) throws {
        lock.lock(); calls += 1; lock.unlock()
        guard target.url == expectedURL else { throw BrowserTabBrokerError.scopeDenied("Authorization observed an unsettled target") }
        if denied { throw BrowserTabBrokerError.scopeDenied("Synthetic native scope denial") }
    }
}

/// Holds an actual loopback HTTP navigation until the test explicitly releases
/// it. No timer controls ordering between readiness, authorization and capture.
private final class HeldBrowserNavigationFixture: @unchecked Sendable {
    let received = XCTestExpectation(description: "WebKit requested the held navigation")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ComputaTests.BrowserReadNavigation")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var held: [NWConnection] = []
    private var released = false
    private let responseBody: Data
    private let immediateBody: Data?
    private var paths: [String] = []
    private var didReceiveHeldRequest = false
    var requestPaths: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    init(body: String = "<!doctype html><main><h1>Settled authorized page</h1></main>",
         immediateBody: String? = nil) throws {
        responseBody = Data(body.utf8)
        self.immediateBody = immediateBody.map { Data($0.utf8) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(connection, bytes: Data())
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            guard let self, error == nil, let chunk, !chunk.isEmpty else { connection.cancel(); return }
            let combined = bytes + chunk
            guard combined.count <= 65_536 else { connection.cancel(); return }
            guard combined.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.receive(connection, bytes: combined) }
                return
            }
            let requestLine = String(decoding: combined, as: UTF8.self).components(separatedBy: "\r\n")[0]
            let path = requestLine.components(separatedBy: " ").dropFirst().first ?? ""
            self.lock.lock()
            self.paths.append(path)
            if path == "/", let body = self.immediateBody {
                self.lock.unlock()
                self.send(connection, body: body)
                return
            }
            let released = self.released
            if !released { self.held.append(connection) }
            let firstHeldRequest = !self.didReceiveHeldRequest
            self.didReceiveHeldRequest = true
            self.lock.unlock()
            if firstHeldRequest { self.received.fulfill() }
            if released { self.send(connection) }
        }
    }
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }
    func release() {
        lock.lock(); released = true; let pending = held; held.removeAll(); lock.unlock()
        pending.forEach(send)
    }
    private func send(_ connection: NWConnection) {
        send(connection, body: responseBody)
    }
    private func send(_ connection: NWConnection, body: Data) {
        var output = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        output.append(body)
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }
    func stop() {
        listener.cancel()
        lock.lock(); let sockets = connections; held.removeAll(); lock.unlock()
        sockets.forEach { $0.cancel() }
    }
}

import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor final class GroqOwnedStatusTests: XCTestCase {
    // Actual native server, normal ownership/selection/cleanup, real WebKit. No network endpoint is contacted.
    private final class LocalView: WKWebView {
        var html = ""
        override func load(_ request: URLRequest) -> WKNavigation? { loadHTMLString(html,baseURL:request.url) }
    }
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    func testSyntheticOwnedDeadlineDistinguishesPreflightAndOutstandingFetchWithoutAuthorizingCleanup() async throws {
        for (variant,expected) in [("preflight","no_matching_fetch_observed"),("pending","matched_fetch_unsettled"),("wrongBody","ambiguous"),("unarmed","none"),("nativeDeadline","no_matching_fetch_observed"),("retiredDuringRead","none")] {
            try await run(variant,expected:expected)
        }
    }
    func testSuccessfulOrdinaryReplyAndMismatchedSyntheticArmPublishNothing() async throws {
        try await run("success",expected:"none")
        try await run("wrongNonce",expected:"none")
    }
    func testRestoredOwnedDraftPreservesOriginalRejectionAndNeverSendsAgain() async throws {
        try await run("rollback",expected:"transport_rejected")
    }
    private func run(_ mode:String,expected:String) async throws {
        let path=try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil));defer{free(path)}
        let tmp=URL(fileURLWithPath:String(cString:path),isDirectory:true).appendingPathComponent("groq-status-"+UUID().uuidString)
        let directory=tmp.appendingPathComponent(GroqOwnedStatusLease.directoryName)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:tmp)}
        let nonce=UUID(),user=GroqOwnedStatusLease.userText(nonce),model=GroqOwnedStatusLease.choice
        let output=directory.appendingPathComponent("owned-status.json"),arm=directory.appendingPathComponent("arm.json")
        let date=ISO8601DateFormatter();date.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let data:[String:String]=["nonce":nonce.uuidString.lowercased(),"purpose":GroqOwnedStatusLease.purpose,"modelID":model.modelID,
            "userPromptSHA256":GroqOwnedStatusLease.digest(mode=="wrongNonce" ? "different" : user),"expiresAt":date.string(from:Date().addingTimeInterval(80))]
        if mode != "unarmed" {
            try JSONSerialization.data(withJSONObject:data).write(to:arm)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:arm.path)
        }
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/groq-chat.html")
        let html=try String(contentsOf:fixture,encoding:.utf8)
        let browser = EmbeddedBrowserSession(persistent:false)
        let window = Window(contentRect:NSRect(x:20,y:20,width:1024,height:768),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=EmbeddedModelRenderContainer(session:browser);host.frame=window.contentView!.bounds
        window.contentView=host;browser.installModelRenderHost(host);window.orderBack(nil)
        defer { browser.shutdown();host.detach();window.orderOut(nil);window.close() }
        let human=try browser.createTab()
        var view:LocalView?
        browser.setModelViewFactoryForTesting { config in
            let stub = WKUserScript(source:"window.fetch=function(){window.requests=(window.requests||0)+1;return window.variant==='rollback'?Promise.reject(Error('synthetic')):new Promise(()=>{})}",
                                    injectionTime:.atDocumentStart,forMainFrameOnly:true,in:.page)
            config.userContentController.addUserScript(stub)
            let created=LocalView(frame:.init(x:0,y:0,width:1024,height:768),configuration:config)
            created.html=html+"<script>window.variant='"+mode+"';"+Self.client+"</script>"; view=created;return created
        }
        let transport=EmbeddedWebModelTransport(browser:browser)
        let server=WebModelServer(rejectedReplyDirectory:tmp.appendingPathComponent("replies"))
        await server.configureEmbeddedTransport(transport)
        await server.setTimeoutsForTesting(readiness:.seconds(10),response:mode=="nativeDeadline" ? .seconds(6) : .seconds(3))
        if mode=="nativeDeadline" {transport.setTimeoutsForTesting(preparation:.seconds(10),response:.seconds(1))}
        var retired=false
        if mode=="retiredDuringRead" {
            let replacement=EmbeddedWebModelTransport(browser:browser)
            transport.setBeforePageResultValidationForTesting { action in
                guard action=="groqOwnedStatusObserved" else{return}
                await server.configureEmbeddedTransport(replacement)
                retired=true
            }
        }
        await server.configureEvidenceDirectory(tmp.appendingPathComponent("evidence"))
        let runtime=UUID(),task=UUID().uuidString.lowercased(),thread=UUID().uuidString.lowercased(),turn=UUID().uuidString.lowercased(),prep=UUID()
        await server.configureCleanupReceipts(directory:tmp.appendingPathComponent("cleanup"),runtimeGeneration:runtime){_ in}
        try await server.prepareInferenceTurn(taskID:task,threadID:thread,runtimeGeneration:runtime,preparationID:prep,isNewThread:true)
        func item(_ role:String,_ text:String)->[String:Any] {
            ["type":"message","role":role,"content":[["type":"input_text","text":text]]]
        }
        let request=try JSONSerialization.data(withJSONObject:["model":model.modelID,"input":[item("developer","Synthetic policy"),
            item("user","<environment_context><cwd>/tmp/marker</cwd><shell>zsh</shell></environment_context>"),
            item("user",user+"\n"+ComputaAgentInstructions.runtimeInteractionPolicy())],"tools":[]] as [String:Any])
        do {
            let result=try await server.fixtureInfer(request,taskID:task,threadID:thread,turnID:turn,runtimeGeneration:runtime,preparationID:prep)
            XCTAssertEqual(mode,"success")
            let response=try XCTUnwrap(JSONSerialization.jsonObject(with:result) as? [String:Any])
            XCTAssertEqual(response["status"] as? String,"completed")
            let items=try XCTUnwrap(response["output"] as? [[String:Any]])
            XCTAssertEqual(items.count,1)
            XCTAssertEqual((items.first?["content"] as? [[String:Any]])?.first?["text"] as? String,"Fixture complete")
        } catch {
            XCTAssertNotEqual(mode,"success")
            switch error {
            case EmbeddedWebModelTransport.Failure.ownershipFailure(.groqDraftRestored):XCTAssertEqual(mode,"rollback")
            case WebModelServer.Failure.deadline:XCTAssertNotEqual(mode,"nativeDeadline");XCTAssertNotEqual(mode,"rollback")
            case EmbeddedWebModelTransport.Failure.deadline:XCTAssertEqual(mode,"nativeDeadline")
            default:XCTFail("Unexpected synthetic terminal error: "+String(describing:error))
            }
        }
        XCTAssertEqual(retired,mode=="retiredDuringRead")
        let page=try XCTUnwrap(view)
        let count=try await page.evaluateJavaScript("window.groqFixture.sendCount") as? Int
        XCTAssertEqual(count,1)
        XCTAssertNotNil(browser.webView(for:human))
        _=await server.fixtureFinish(taskID:task,runtimeGeneration:runtime)
        let receipts=await server.latestCleanupReceipts()
        XCTAssertEqual(receipts.last?.outcome,mode=="success" ? .closed : .unconfirmed)
        XCTAssertEqual(receipts.last?.reason,mode=="success" ? .transcriptCleared : .cleanupUnverified)
        if expected=="none" {
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath:arm.path),mode=="wrongNonce")
        }
        else {
            XCTAssertFalse(FileManager.default.fileExists(atPath:arm.path),"Authorized arm must be consumed")
            let report=try XCTUnwrap(try? Data(contentsOf:output),"Missing finite packet for "+mode)
            let row=try XCTUnwrap(JSONSerialization.jsonObject(with:report) as? [String:Any])
            XCTAssertEqual(row["stage"] as? String,expected);XCTAssertEqual(row["taskID"] as? String,task)
            XCTAssertEqual(row["modelID"] as? String,model.modelID)
            XCTAssertEqual(row["trigger"] as? String,mode=="rollback" ? "groq_draft_restored" : "response_deadline")
            XCTAssertFalse(String(decoding:report,as:UTF8.self).contains(nonce.uuidString))
        }
        _=await server.shutdown()
    }
    private static let client = #"""
        const f=window.groqFixture,old=f.send.onclick;
        f.delayResponse=variant!=='success';
        if(variant==='success')f.reply=JSON.stringify({type:'message',text:'Fixture complete'});
        f.send.onclick=e=>{
          const prompt=f.editor.value;old.call(f.send,e);
          if(['preflight','unarmed','success','wrongNonce','nativeDeadline','retiredDuringRead'].includes(variant))return;
          const body=JSON.stringify({model:'openai/gpt-oss-20b',messages:[{content:'synthetic system',role:'system'},{content:variant==='wrongBody'?'different':prompt,role:'user'}],temperature:1,max_completion_tokens:16384,top_p:1,stream:true});
          fetch('https://api.groq.com/openai/v1/chat/completions',{method:'POST',body}).catch(()=>{
            setTimeout(()=>{f.turn.remove();f.editor.value=prompt;f.editor.disabled=false;f.send.disabled=false;},900);
          });
        };
        """#
}

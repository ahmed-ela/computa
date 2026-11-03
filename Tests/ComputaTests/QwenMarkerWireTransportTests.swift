import AppKit
import CryptoKit
import WebKit
import XCTest
@testable import Computa

@MainActor final class QwenMarkerWireTransportTests: XCTestCase {
    // Real WebKit and native transport/server. Only the site's responses are synthesised.
    // A separate real-loopback XHR/stream suite checks the browser's genuine network primitives.
    private final class LocalView: WKWebView {
        var html = ""
        var loads = 0
        override func load(_ request: URLRequest) -> WKNavigation? {
            loads += 1
            return loadHTMLString(html, baseURL: request.url)
        }
    }
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    func testTwoModelsCompareOnlyThroughOrdinaryNativeFinalAndPersistedSavedDeletion() async throws {
        for (label, disposition) in [("Qwen3.7-Plus","wire_equal"), ("Qwen3.8-Max","wire_equal"),
                                     ("Qwen3.8-Max","response_model_unobserved"), ("Qwen3.7-Plus","catalog_not_seen"),
                                     ("Qwen3.7-Plus","marker_mismatch"), ("Qwen3.8-Max","ordinary")] {
            try await run(label:label, disposition:disposition)
        }
    }

    func testRejectedCatalogPreservesNativeMarkerAndDeletionAndReportsOnlyFirstFailedCheck() async throws {
        for (label, stage) in [("Qwen3.7-Plus", "catalog_non_200"), ("Qwen3.8-Max", "catalog_final_url"),
                               ("Qwen3.7-Plus", "catalog_response_type"), ("Qwen3.8-Max", "catalog_not_done")] {
            try await run(label: label, disposition: stage)
        }
    }

    func testFailedSavedDeletionWithholdsWireComparison() async throws {
        try await run(label:"Qwen3.8-Max", disposition:"cleanup_unconfirmed")
    }

    private func run(label:String, disposition:String) async throws {
        let root = try websiteBenchmarkTemporaryDirectory().appendingPathComponent("qwen-integration-\(UUID())")
        let directory = root.appendingPathComponent(QwenMarkerWireLease.directoryName)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let nonce = UUID(), marker = QwenMarkerWireLease.marker(nonce), user = QwenMarkerWireLease.userText(nonce)
        let model = WebsiteModelChoice(provider:"qwen",key:label,label:label)
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let armURL = directory.appendingPathComponent("arm.json"), output = directory.appendingPathComponent("marker-wire.json")
        let arm: [String:Any] = ["schemaVersion":1,"purpose":QwenMarkerWireLease.purpose,"provider":"qwen","modelID":model.modelID,
            "nonce":nonce.uuidString.lowercased(),"expiresAt":format.string(from:Date().addingTimeInterval(90)),
            "userPromptSHA256":SHA256.hash(data:Data(user.utf8)).map{String(format:"%02x",$0)}.joined()]
        if disposition != "ordinary" {
            try JSONSerialization.data(withJSONObject:arm).write(to:armURL)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:armURL.path)
        }
        let browser = EmbeddedBrowserSession(persistent:false)
        let window = Window(contentRect:NSRect(x:20,y:20,width:1024,height:768),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=EmbeddedModelRenderContainer(session:browser);host.frame=window.contentView!.bounds
        window.contentView=host;browser.installModelRenderHost(host);window.orderBack(nil)
        defer { browser.shutdown();host.detach();window.orderOut(nil);window.close() }
        let human=try browser.createTab()
        var retained:LocalView?
        var initialScripts:[WKUserScript]=[]
        browser.setModelViewFactoryForTesting { configuration in
            let backend = WKUserScript(source:Self.fixtureBackend,injectionTime:.atDocumentStart,forMainFrameOnly:true,in:.page)
            configuration.userContentController.addUserScript(backend)
            initialScripts = configuration.userContentController.userScripts
            let view = LocalView(frame:NSRect(x:0,y:0,width:1024,height:768),configuration:configuration)
            view.html = QwenFixturePage.html + "<script>const QMARK='\(marker)', QDISPOSITION='\(disposition)';" + Self.site + "</script>"
            retained=view
            return view
        }
        let transport=EmbeddedWebModelTransport(browser:browser)
        transport.setBeforePageResultValidationForTesting { action in
            if ["deleteConversation","selectConversationDeletion","confirmConversationDeletion","observeDeletedConversation"].contains(action) {
                XCTAssertFalse(FileManager.default.fileExists(atPath:output.path), "The ordinary deletion proof is still pending")
            }
        }
        let server=WebModelServer(rejectedReplyDirectory:root.appendingPathComponent("replies"))
        await server.configureEmbeddedTransport(transport)
        await server.configureEvidenceDirectory(root.appendingPathComponent("evidence"))
        let runtime=UUID(),task=UUID().uuidString.lowercased(),thread=UUID().uuidString.lowercased(),turn=UUID().uuidString.lowercased(), preparation=UUID()
        await server.configureCleanupReceipts(directory:root.appendingPathComponent("cleanup"),runtimeGeneration:runtime){ _ in }
        try await server.prepareInferenceTurn(taskID:task,threadID:thread,runtimeGeneration:runtime,preparationID:preparation,isNewThread:true)
        func item(_ role:String,_ text:String)->[String:Any] {
            ["type":"message","role":role,"content":[["type":"input_text","text":text]]]
        }
        let data = try JSONSerialization.data(withJSONObject:["model":model.modelID,
            "input":[item("developer","Synthetic policy"),
                     item("user","<environment_context><cwd>/tmp/marker</cwd><shell>zsh</shell></environment_context>"),
                     item("user",user + "\n" + ComputaAgentInstructions.runtimeInteractionPolicy())],"tools":[]] as [String:Any])
        let encoded: Data
        do {
            encoded = try await server.fixtureInfer(data,taskID:task,threadID:thread,turnID:turn,
                                                   runtimeGeneration:runtime,preparationID:preparation)
        } catch {
            guard disposition=="cleanup_unconfirmed" else { throw error }
            let receipts=await server.latestCleanupReceipts()
            XCTAssertEqual(receipts.last?.outcome,.unconfirmed); XCTAssertEqual(receipts.last?.reason,.cleanupUnverified)
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
            _=await server.shutdown()
            return
        }
        XCTAssertNotEqual(disposition,"cleanup_unconfirmed")
        let completed=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertEqual(completed["status"] as? String,"completed")
        let items=try XCTUnwrap(completed["output"] as? [[String:Any]])
        XCTAssertEqual(items.count,1)
        XCTAssertEqual((items[0]["content"] as? [[String:Any]])?.first?["text"] as? String,marker)
        let receipts=await server.latestCleanupReceipts()
        XCTAssertEqual(receipts.count,1)
        let receipt=try XCTUnwrap(receipts.first)
        XCTAssertTrue(receipt.receiptSaved);XCTAssertEqual(receipt.reason,.deleted);XCTAssertEqual(receipt.outcome,.closed)
        let persisted=WebsiteSessionCleanupStore(directory:root.appendingPathComponent("cleanup")).latest()
        XCTAssertEqual(persisted,[receipt])
        if disposition=="ordinary" { XCTAssertFalse(FileManager.default.fileExists(atPath:output.path)) }
        else {
            let record=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
            XCTAssertEqual(record["stage"] as? String,disposition);XCTAssertEqual(record["cleanupAttemptID"] as? String,receipt.attemptID)
            XCTAssertEqual(record["sessionToken"] as? String,receipt.sessionToken);XCTAssertEqual(record["turnID"] as? String,turn)
        }
        let view=try XCTUnwrap(retained)
        XCTAssertEqual(view.loads,1);XCTAssertEqual(browser.selectedTabID,human)
        let counts=try await view.evaluateJavaScript("[qwenFixture.counts.sends,qwenFixture.counts.confirmations,fixturePosts]") as? [Int]
        XCTAssertEqual(counts,[1,1,1])
        let remaining=view.configuration.userContentController.userScripts
        XCTAssertTrue(initialScripts.allSatisfy { installed in remaining.contains { $0 === installed } })
        XCTAssertFalse(remaining.contains { $0.source.contains("__computaQwenMarker_") })
        _=await server.shutdown()
    }

    private static let fixtureBackend = #"""
        // No networking primitive in this fixture can send to the site.
        const rows=[{name:'Qwen3.7-Plus',id:'fixture-plus'},{name:'Qwen3.8-Max',id:'fixture-max'}];
        let timing;
        window.XMLHttpRequest=class extends EventTarget {
          open(method,url){this.path=new URL(url,location.href).href;}
          send(){timing=performance.now();this.dispatchEvent(new Event('loadend'));}
          get readyState(){return QDISPOSITION==='catalog_not_done'?3:4}
          get responseURL(){return QDISPOSITION==='catalog_final_url'?this.path+'alternate':this.path}
          get status(){return QDISPOSITION==='catalog_non_200'?403:200}
          get responseType(){return QDISPOSITION==='catalog_response_type'?'arraybuffer':''}
          get responseText(){if(QDISPOSITION.startsWith('catalog_'))throw Error('unscoped catalog read');return JSON.stringify({data:rows})}
          getResponseHeader(key){return key==='content-type'?'application/json':null}
        };
        Object.defineProperty(performance,'getEntriesByName',{value:(path,kind)=>timing && kind==='resource'?[{
          name:path,initiatorType:'xmlhttprequest',startTime:timing,requestStart:timing+1,responseStart:timing+2,responseEnd:timing+3,
          redirectStart:0,redirectEnd:0,workerStart:0,decodedBodySize:128}]:[]});
        window.fixturePosts=0;
        window.fetch=async(path,init)=>{
          window.fixturePosts++;const b=JSON.parse(init.body),chat=b.chat_id,user='902f136d-bddf-4078-a667-030715aeff87',reply='413e8269-7ba8-476b-84f3-c400e8bed55c';
          const content=QDISPOSITION==='marker_mismatch'?'{}':qwenFixture.options.reply;
          const events=[{'response.created':{chat_id:chat,parent_id:user,response_id:reply,response_index:0}},
            ...(QDISPOSITION==='response_model_unobserved'?[]:[{response_id:reply,selected_model_id:b.model}]),
            {choices:[{delta:{role:'assistant',phase:'answer',status:'finished',content}}],response_id:reply}];
          const raw=events.map(v=>'data: '+JSON.stringify(v)+'\n\n').join('')+'data: [DONE]\n\n';
          const res=new Response(raw,{headers:{'content-type':'text/event-stream'}});
          Object.defineProperty(res,'url',{value:new URL(path,location.href).href});return res;
        };
        """#
    private static let site = #"""
        qwenFixture.options.reply=JSON.stringify({type:'message',text:QMARK});
        qwenFixture.options.retainHistoryLink=QDISPOSITION==='cleanup_unconfirmed';
        if(QDISPOSITION!=='catalog_not_seen'){const cat=new XMLHttpRequest();cat.open('GET','/api/v2/models/',true);cat.send();}
        document.addEventListener('click',async e=>{
          if(!e.target.closest('.send-button'))return;
          const chat='b3669d48-0898-45f8-a25c-e33d50b21dea',wire=document.querySelector('.wms-trigger__text').textContent.endsWith('Plus')?'fixture-plus':'fixture-max';
          const body={stream:true,version:'2.1',incremental_output:true,chat_mode:'normal',model:wire,parent_id:null,parentId:'',chatId:chat,chat_id:chat,
                      messages:[{role:'user',id:'4e507fc6-5367-4cca-aea2-6765c9f06fb3',content:document.querySelector('textarea').value,user_action:'chat',models:[wire],files:[]}]};
          const res=await fetch('/api/v2/chat/completions?chat_id='+chat,{method:'post',headers:{Version:'0.3.32','X-Request-Id':'92c062c2-62d7-45ef-8f35-bf6966e7e696'},body:JSON.stringify(body)});
          const reader=res.body.getReader();while(!(await reader.read()).done){}
        },true);
        """#
}

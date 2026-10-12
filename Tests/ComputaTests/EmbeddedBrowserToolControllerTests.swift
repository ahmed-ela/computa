import Foundation
import XCTest
@testable import Computa

@MainActor
final class EmbeddedBrowserToolControllerTests: XCTestCase {
    func testBuiltInContinuationSchemasNameTheirOwnCursorTools() throws {
        for name in ["browser_read", "browser_tabs"] {
            let spec = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == name })
            let description = try XCTUnwrap(spec["description"] as? String)
            XCTAssertTrue(description.contains(name + "(cursor=next_cursor)"))
            XCTAssertTrue(description.contains("computer_v2_continue"))
            XCTAssertNoThrow(try EmbeddedBrowserTools.validate(tool: name, arguments: ["cursor": UUID().uuidString]))
        }
    }
    private func call(_ controller: EmbeddedBrowserToolController, _ tool: String, _ arguments: [String: Any] = [:], key: String = "turn-a", scope: ComputerTaskScope? = nil) async throws -> String {
        try await controller.execute(taskKey: key, tool: tool, arguments: JSONSerialization.data(withJSONObject: arguments), scope: scope)
    }

    func testContractRejectsUnknownArgumentsGuessedURLsAndBoolIndicesBeforeDispatch() throws {
        for (tool, arguments) in [
            ("browser_open", ["url":"javascript:alert(1)"]),
            ("browser_open", ["url":"https://user:password@example.com"]),
            ("browser_bind", ["tab_id":"invented"]),
            ("browser_click", ["snapshot_id":UUID().uuidString,"element_index":true]),
            ("browser_wait", ["timeout_ms":10_001]),
            ("browser_read", ["view":"everything"]),
            ("browser_close", ["tab_id":UUID().uuidString])
        ] as [(String,[String:Any])] { XCTAssertThrowsError(try EmbeddedBrowserTools.validate(tool: tool, arguments: arguments)) }
        XCTAssertEqual(Set(EmbeddedBrowserTools.definitions().compactMap { $0["name"] as? String }), EmbeddedBrowserTools.names)
        XCTAssertFalse(EmbeddedBrowserTools.requiresApproval(tool: "browser_read"))
        XCTAssertTrue(EmbeddedBrowserTools.requiresApproval(tool: "browser_fill"))
    }

    func testFlightReadFillClickAndResultRequireFreshSnapshotAndNeverReplay() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let first = try await call(controller,"browser_read")
        XCTAssertTrue(first.contains("Flight number"))
        let firstID = try snapshotID(first)
        _ = try await call(controller,"browser_fill",["snapshot_id":firstID,"element_index":0,"text":"UA 123"])
        do { _ = try await call(controller,"browser_fill",["snapshot_id":firstID,"element_index":0,"text":"UA 456"]); XCTFail("Consumed snapshot replay must fail") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        let second = try await call(controller,"browser_read")
        _ = try await call(controller,"browser_click",["snapshot_id":try snapshotID(second),"element_index":1])
        let result = try await call(controller,"browser_read",["view":"content"])
        XCTAssertTrue(result.contains("UA 123 departs at 18:45"))
        let counts = await backend.counts()
        XCTAssertEqual(counts.fills,1); XCTAssertEqual(counts.presses,1)
        let issues = await controller.release(taskKey:"turn-a")
        XCTAssertTrue(issues.isEmpty)
        let end = await backend.counts()
        XCTAssertEqual(end.closes,1)
    }

    func testObservedBuiltInLinkUsesBrowserClickAndConsumesOneSnapshot() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport: backend)
        await backend.setLink("http://localhost:8123/details")
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let read = try await call(controller,"browser_read",["view":"overview"])
        let linkLine = try XCTUnwrap(read.split(separator:"\n").first { $0.contains("label=\"Destination\"") })
        XCTAssertTrue(linkLine.contains("follow_link=true"))
        let index = try XCTUnwrap(Int(linkLine.dropFirst().prefix { $0.isNumber }))
        let id = try snapshotID(read)
        let definition = try XCTUnwrap(EmbeddedBrowserTools.definitions().first { $0["name"] as? String == "browser_read" })
        XCTAssertTrue((definition["description"] as? String)?.contains("Use browser_click for observed enabled links (including follow_link=true)") == true)
        _ = try await call(controller,"browser_click",["snapshot_id":id,"element_index":index])
        do { _ = try await call(controller,"browser_click",["snapshot_id":id,"element_index":index]); XCTFail("Consumed link snapshot cannot replay input") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses,1)
        XCTAssertEqual(counts.fills,0)
        let cleanup = await controller.release(taskKey:"turn-a")
        XCTAssertTrue(cleanup.isEmpty)
    }

    func testHumanTabLeaseRejectsOtherTaskAndCleanupPreservesExistingTab() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let human = await backend.humanID
        _ = try await call(controller,"browser_tabs")
        _ = try await call(controller,"browser_bind",["tab_id":human])
        _ = try await call(controller,"browser_tabs",key:"turn-b")
        do { _ = try await call(controller,"browser_bind",["tab_id":human],key:"turn-b"); XCTFail("Two task writers must not lease one tab") }
        catch { XCTAssertEqual(error as? BrowserTabBrokerError,.operationInProgress) }
        _ = await controller.release(taskKey:"turn-a")
        _ = try await call(controller,"browser_bind",["tab_id":human],key:"turn-b")
        _ = try await call(controller,"browser_close",key:"turn-b")
        let counts = await backend.counts()
        XCTAssertEqual(counts.closes,0)
        let available = try await backend.humanTargets()
        XCTAssertEqual(available.count,1)
    }

    func testSwitchingTargetsClosesCreatedTabAndRetainsTurnLifetime() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/first"])
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/second"])
        _ = try await call(controller,"browser_read")
        _ = try await call(controller,"browser_close")
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/third"])
        _ = await controller.shutdown()
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,3); XCTAssertEqual(counts.closes,3)
    }

    func testBindingAlreadyBoundCreatedTabPreservesItsOwnedPage() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let opened = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(opened.utf8)) as? [String:Any])
        let id = try XCTUnwrap(value["tab_id"] as? String)
        _ = try await call(controller,"browser_tabs")
        let rebound = try await call(controller,"browser_bind",["tab_id":id])
        XCTAssertTrue(rebound.contains("\"already_bound\":true"))
        _ = try await call(controller,"browser_read")
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,1); XCTAssertEqual(counts.closes,0); XCTAssertEqual(counts.navigations,0)
        _ = await controller.shutdown()
        let end = await backend.counts()
        XCTAssertEqual(end.closes,1)
    }

    func testReleaseDuringOpeningClosesLateTargetWithoutPublishingBinding() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        await backend.holdNextCreate()
        let operation = Task { try await self.call(controller,"browser_open",["url":"http://localhost:8123/flight"]) }
        await backend.waitUntilCreateHeld()
        _ = await controller.release(taskKey:"turn-a")
        await backend.resumeCreate()
        do { _ = try await operation.value; XCTFail("Canceled opening must not bind") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.handleMissing) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,1); XCTAssertEqual(counts.closes,1); XCTAssertEqual(counts.observes,0)
    }

    func testReleaseDuringMutationRevokesPermitBeforeLateDispatch() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let read = try await call(controller,"browser_read")
        await backend.holdNextMutation()
        let id = try snapshotID(read)
        let operation = Task { try await self.call(controller,"browser_click",["snapshot_id":id,"element_index":1]) }
        await backend.waitUntilMutationHeld()
        _ = await controller.release(taskKey:"turn-a")
        await backend.resumeMutation()
        do { _ = try await operation.value; XCTFail("Revoked mutation must not dispatch") } catch { }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses,0); XCTAssertEqual(counts.closes,1)
    }

    func testNavigationRetiresOldSnapshotAndWaitNeverCreatesOrMutates() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"])
        let read = try await call(controller,"browser_read")
        _ = try await call(controller,"browser_navigate",["url":"http://localhost:8123/other"])
        do { _ = try await call(controller,"browser_click",["snapshot_id":try snapshotID(read),"element_index":1]); XCTFail("Navigation retires old controls") } catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        let wait = try await call(controller,"browser_wait",["text":"No such result","timeout_ms":1])
        XCTAssertTrue(wait.contains("\"matched\":false"))
        let counts = await backend.counts()
        XCTAssertEqual(counts.navigations,1); XCTAssertEqual(counts.creates,1); XCTAssertEqual(counts.presses,0)
        _ = await controller.shutdown()
    }

    func testInventoryPagesAreBoundedAndCursorIsScopedToCurrentTurnAndInventory() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        await backend.addLongInventory()
        var page = try await call(controller,"browser_tabs")
        var identifiers = Set<String>(), firstCursor: String?
        while true {
            XCTAssertLessThanOrEqual(page.utf8.count,8_192)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(page.utf8)) as? [String:Any])
            let rows = try XCTUnwrap(value["tabs"] as? [[String:Any]])
            identifiers.formUnion(rows.compactMap { $0["tab_id"] as? String })
            guard let cursor = value["next_cursor"] as? String else { break }
            firstCursor = firstCursor ?? cursor
            do { _ = try await call(controller,"browser_tabs",["cursor":cursor],key:"turn-b"); XCTFail("Foreign inventory cursor must fail") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
            page = try await call(controller,"browser_tabs",["cursor":cursor])
        }
        XCTAssertEqual(identifiers.count,14)
        _ = try await call(controller,"browser_tabs")
        if let firstCursor {
            do { _ = try await call(controller,"browser_tabs",["cursor":firstCursor]); XCTFail("Replaced inventory cursor must fail") }
            catch { XCTAssertEqual(error as? BrowserTabBrokerError,.staleSnapshot) }
        }
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,0); XCTAssertEqual(counts.presses,0); XCTAssertEqual(counts.fills,0)
        _ = await controller.shutdown()
    }

    func testCombiningAndControlTitlesAlwaysIssueRowsWithinFiniteBoundedInventory() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let combining = "A" + String(repeating:"\u{0301}",count:6_000)
        XCTAssertEqual(combining.count,1,"The fixture is one oversized grapheme, not many ordinary characters")
        let controls = String(repeating:"\u{0000}",count:6_000)
        let url = try XCTUnwrap(URL(string:"http://localhost:8123/" + String(repeating:"/",count:2_000)))
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count,2_048)
        let combiningID = await backend.addInventoryTarget(title:combining,url:url)
        let otherCombiningID = await backend.addInventoryTarget(title:combining,url:url)
        let controlID = await backend.addInventoryTarget(title:controls,url:url)
        let humanID = await backend.humanID
        let expected = Set([combiningID,otherCombiningID,controlID,humanID])
        var issued = Set<String>(), pages = 0, firstPage = true
        var page = try await call(controller,"browser_tabs")
        while true {
            pages += 1
            XCTAssertLessThanOrEqual(pages,expected.count,"Every nonempty page must advance inventory")
            XCTAssertLessThanOrEqual(page.utf8.count,8_192)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(page.utf8)) as? [String:Any])
            let rows = try XCTUnwrap(value["tabs"] as? [[String:Any]])
            XCTAssertFalse(rows.isEmpty,"An oversized grapheme must not trap pagination at an empty page")
            XCTAssertEqual(value["returned"] as? Int,rows.count)
            for row in rows {
                let id = try XCTUnwrap(row["tab_id"] as? String)
                XCTAssertTrue(issued.insert(id).inserted,"Each retained inventory target is returned exactly once")
                let title = try XCTUnwrap(row["title"] as? String)
                XCTAssertLessThanOrEqual(title.utf8.count,256)
                if id == combiningID || id == otherCombiningID {
                    XCTAssertEqual(title,"A" + String(repeating:"\u{0301}",count:127))
                    XCTAssertEqual(row["title_truncated"] as? Bool,true)
                } else if id == controlID {
                    XCTAssertEqual(title,String(repeating:"\u{0000}",count:256))
                    XCTAssertEqual(row["title_truncated"] as? Bool,true)
                }
            }
            if firstPage {
                let unissued = try XCTUnwrap(expected.subtracting(issued).first)
                do { _ = try await call(controller,"browser_bind",["tab_id":unissued]); XCTFail("An unissued inventory target cannot be guessed") }
                catch { XCTAssertTrue((error as? BrowserTabBrokerError)?.errorDescription?.contains("List browser_tabs") == true) }
                firstPage = false
            }
            guard let cursor = value["next_cursor"] as? String else { break }
            guard pages < expected.count else { XCTFail("Inventory did not finish within its target count"); break }
            page = try await call(controller,"browser_tabs",["cursor":cursor])
        }
        XCTAssertEqual(issued,expected)
        _ = try await call(controller,"browser_bind",["tab_id":combiningID])
        let counts = await backend.counts()
        XCTAssertEqual(counts.creates,0); XCTAssertEqual(counts.presses,0); XCTAssertEqual(counts.fills,0)
        XCTAssertEqual(counts.observes,1,"Only binding the returned target can inspect its document")
        _ = await controller.shutdown()
    }

    func testHostScopeRejectsWrongOriginBeforeCreationOrInputAndRetainsOriginalTab() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let scope = ComputerTaskScope(userPrompt:"Use only http://localhost:8123/flight to check my flight.")
        do { _ = try await call(controller,"browser_open",["url":"https://example.com/flight"],scope:scope); XCTFail("Wrong destination must fail before creation") } catch { }
        let initial = await backend.counts()
        XCTAssertEqual(initial.creates,0)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:scope)
        let read = try await call(controller,"browser_read",scope:scope)
        do { _ = try await call(controller,"browser_navigate",["url":"http://localhost:8124/other"],scope:scope); XCTFail("Wrong port is outside exact user origin") } catch { }
        do { _ = try await call(controller,"browser_open",["url":"https://example.com/other"],scope:scope); XCTFail("Rejected open must not close current tab") } catch { }
        _ = try await call(controller,"browser_read",scope:scope)
        let during = await backend.counts()
        XCTAssertEqual(during.creates,1); XCTAssertEqual(during.closes,0); XCTAssertEqual(during.navigations,0); XCTAssertEqual(during.presses,0); XCTAssertEqual(during.fills,0)
        XCTAssertFalse(read.isEmpty)
        _ = await controller.shutdown()
    }

    func testRedirectedDocumentCannotPublishOrReuseOldActionUnderHostScope() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let scope = ComputerTaskScope(userPrompt:"Check http://localhost:8123/flight only.")
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:scope)
        let read = try await call(controller,"browser_read",scope:scope)
        await backend.redirectOnNextObserve(to:URL(string:"https://unrelated.example/other")!)
        do { _ = try await call(controller,"browser_read",scope:scope); XCTFail("Unrelated redirected content must not be published") } catch { }
        do { _ = try await call(controller,"browser_click",["snapshot_id":try snapshotID(read),"element_index":1],scope:scope); XCTFail("Redirected tab cannot reuse old action") } catch { }
        do { _ = try await call(controller,"browser_fill",["snapshot_id":try snapshotID(read),"element_index":0,"text":"MUST_NOT_APPEAR"],scope:scope); XCTFail("Redirected tab cannot fill") } catch { }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses,0); XCTAssertEqual(counts.fills,0)
        _ = await controller.shutdown()
    }

    func testExplicitChromeRestrictionDoesNotRejectGenericBackgroundBrowser() async throws {
        let chrome = ComputerTaskScope(userPrompt:"Use background Chrome only. Check my flight.")
        XCTAssertNotNil(chrome.embeddedBrowserToolViolation())
        let generic = ComputerTaskScope(userPrompt:"Use background browser only. Check my flight.")
        XCTAssertNil(generic.embeddedBrowserToolViolation())
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        do { _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:chrome); XCTFail("Explicit Chrome restriction must not admit another browser") } catch { }
        let before = await backend.counts()
        XCTAssertEqual(before.creates,0)
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:generic)
        _ = await controller.shutdown()
    }

    func testObservedOffsiteLinkIsRejectedBeforePressUnderHostScope() async throws {
        let backend = EmbeddedBrowserFixtureBackend(), controller = EmbeddedBrowserToolController(transport:backend)
        let scope = ComputerTaskScope(userPrompt:"Read http://localhost:8123/flight only.")
        _ = try await call(controller,"browser_open",["url":"http://localhost:8123/flight"],scope:scope)
        await backend.setLink("https://unrelated.example/other")
        let read = try await call(controller,"browser_read",["view":"links"],scope:scope)
        do { _ = try await call(controller,"browser_click",["snapshot_id":try snapshotID(read),"element_index":0],scope:scope); XCTFail("Known offsite destination must fail before press") } catch { }
        let counts = await backend.counts()
        XCTAssertEqual(counts.presses,0)
        _ = await controller.shutdown()
    }

    private func snapshotID(_ text: String) throws -> String {
        let prefix = "AXSNAPSHOT id="
        guard let start = text.range(of:prefix), let id = text[start.upperBound...].split(separator:" ").first, UUID(uuidString:String(id)) != nil else {
            throw BrowserTabBrokerError.staleSnapshot
        }
        return String(id)
    }
}

private actor EmbeddedBrowserFixtureBackend: EmbeddedBrowserControlBackend {
    struct Counts: Sendable { var creates=0,closes=0,observes=0,presses=0,fills=0,navigations=0 }
    let humanID = UUID().uuidString
    private var targets = [String: BrowserTarget](), owned = Set<String>(), stats = Counts()
    private var generation = UUID().uuidString, field = "", result = ""
    private var pendingRedirect: URL?
    private var link: String?
    private var holdCreate=false, createHeld=false, createContinuation: CheckedContinuation<Void,Never>?
    private var holdMutation=false, mutationHeld=false, mutationContinuation: CheckedContinuation<Void,Never>?
    private var createWaiters=[CheckedContinuation<Void,Never>](), mutationWaiters=[CheckedContinuation<Void,Never>]()

    init() { targets[humanID] = BrowserTarget(targetID:humanID,instanceToken:humanID,title:"Flights",url:URL(string:"http://localhost:8123/flight")!,webSocketURL:nil) }
    func counts() -> Counts { stats }
    func addInventoryTarget(title:String,url:URL) -> String {
        let id=UUID().uuidString
        targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:title,url:url,webSocketURL:nil)
        return id
    }
    func addLongInventory() {
        for index in 0..<12 {
            let id=UUID().uuidString
            targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:String(repeating:"🙂",count:200),
                url:URL(string:"http://localhost:8123/\(index)?q=" + String(repeating:"x",count:1_800))!,webSocketURL:nil)
        }
        let id=UUID().uuidString
        targets[id]=BrowserTarget(targetID:id,instanceToken:id,title:"Oversized URL",
            url:URL(string:"http://localhost:8123/?q=" + String(repeating:"x",count:3_000))!,webSocketURL:nil)
    }
    func humanTargets() async throws -> [BrowserTarget] { Array(targets.values) }
    func createTarget(url:URL) async throws -> BrowserTarget {
        stats.creates += 1
        let id=UUID().uuidString, target=BrowserTarget(targetID:id,instanceToken:id,title:"Flight fixture",url:url,webSocketURL:nil)
        targets[id]=target; owned.insert(id)
        if holdCreate {
            createHeld=true; createWaiters.forEach { $0.resume() }; createWaiters.removeAll()
            await withCheckedContinuation { createContinuation=$0 }
        }
        return target
    }
    func target(id:String) async throws -> BrowserTarget? { targets[id] }
    func activateTarget(id:String) async throws { }
    func closeTarget(target:BrowserTarget) async throws {
        guard targets[target.targetID]?.instanceToken == target.instanceToken else { throw BrowserTabBrokerError.targetClosed }
        guard owned.remove(target.targetID) != nil else { throw BrowserTabBrokerError.ownershipMismatch }
        targets.removeValue(forKey:target.targetID); stats.closes += 1
    }
    func closeOwnedTargets() async -> [String] {
        for id in Array(owned) { if let target=targets[id] { try? await closeTarget(target:target) } }; return []
    }
    func observe(target:BrowserTarget) async throws -> BrowserDocumentObservation {
        stats.observes += 1
        if let redirect = pendingRedirect {
            targets[target.targetID] = BrowserTarget(targetID:target.targetID,instanceToken:target.instanceToken,title:target.title,url:redirect,webSocketURL:nil)
            pendingRedirect = nil
        }
        var nodes = [
            BrowserDocumentNode(backendNodeID:1,role:"textbox",name:"Flight number",value:field,isDisabled:false,isReadOnly:false,isIgnored:false,nodeID:"1",isEditable:true),
            BrowserDocumentNode(backendNodeID:2,role:"button",name:"Check flight",value:nil,isDisabled:false,isReadOnly:false,isIgnored:false,nodeID:"2",isDOMClickable:true),
            BrowserDocumentNode(backendNodeID:3,role:"statictext",name:result,value:nil,isDisabled:true,isReadOnly:true,isIgnored:false,nodeID:"3")
        ]
        if let link {
            nodes.append(BrowserDocumentNode(backendNodeID:4,role:"link",name:"Destination",value:nil,isDisabled:false,isReadOnly:false,isIgnored:false,nodeID:"4",linkURL:link,isDOMClickable:true))
        }
        var observation=BrowserDocumentObservation(loaderID:generation,title:target.title,url:targets[target.targetID]?.url ?? target.url,nodes:nodes)
        observation.sourceName="computa_webkit_dom"
        return observation
    }
    func press(target:BrowserTarget,backendNodeID:Int64,document:BrowserDocumentObservation,permit:BrowserMutationPermit) async throws {
        if holdMutation {
            mutationHeld=true; mutationWaiters.forEach { $0.resume() }; mutationWaiters.removeAll()
            await withCheckedContinuation { mutationContinuation=$0 }
        }
        try permit.commit { stats.presses += 1; result="\(field) departs at 18:45" }
    }
    func setText(target:BrowserTarget,backendNodeID:Int64,text:String,document:BrowserDocumentObservation,permit:BrowserMutationPermit) async throws { try permit.commit { stats.fills += 1; field=text } }
    func navigate(target:BrowserTarget,url:URL,permit:BrowserMutationPermit) async throws {
        try permit.commit { stats.navigations += 1; generation=UUID().uuidString; targets[target.targetID]=BrowserTarget(targetID:target.targetID,instanceToken:target.instanceToken,title:target.title,url:url,webSocketURL:nil) }
    }
    func wait(target:BrowserTarget,text:String?,timeoutMS:Int) async throws -> Bool { text == nil || result.contains(text!) }
    func holdNextCreate() { holdCreate=true }
    func waitUntilCreateHeld() async { if !createHeld { await withCheckedContinuation { createWaiters.append($0) } } }
    func resumeCreate() { createContinuation?.resume(); createContinuation=nil; holdCreate=false }
    func holdNextMutation() { holdMutation=true }
    func waitUntilMutationHeld() async { if !mutationHeld { await withCheckedContinuation { mutationWaiters.append($0) } } }
    func resumeMutation() { mutationContinuation?.resume(); mutationContinuation=nil; holdMutation=false }
    func redirectOnNextObserve(to url: URL) { pendingRedirect = url }
    func setLink(_ url: String) { link = url }
}

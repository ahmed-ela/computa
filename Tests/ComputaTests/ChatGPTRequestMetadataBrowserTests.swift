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
    }

    func testDocumentStartObserverActivatesOnlyByExactNativeViewOwnerAndStopsBeforeCleanup() async throws {
        let arm = try RequestMetadataIntegrationArm(); defer { arm.remove() }
        let lease = try arm.lease()
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let human = try browser.createTab()
        let id = try browser.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(browser.webView(for: id))
        XCTAssertTrue(browser.installModelRequestMetadata(lease, tabID: id))
        let source = try XCTUnwrap(view.configuration.userContentController.userScripts.first).source
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
        let fetchFacts = try await view.callAsyncJavaScript("""
            await window.cachedFetch('data:text/plain,LOCAL_PRIVATE_URL', {method:'POST',body:'LOCAL_PRIVATE_BODY'}).catch(() => {});
            const response = await window.cachedFetch('data:text/plain,LOCAL_PRIVATE_RESPONSE');
            return {status: response.status, bodyUsed: response.bodyUsed};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(fetchFacts?["status"] as? Int, 200)
        XCTAssertEqual(fetchFacts?["bodyUsed"] as? Bool, false)
        let snapshot = await browser.modelRequestMetadata(command: "snapshot", tabID: id, view: view, ownerToken: token)
        let captured = try XCTUnwrap(snapshot)
        XCTAssertEqual(captured.rowCount, 2, "A page's cached document-start fetch is observed after activation")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.encodedData) as? [String: Any])
        let rows = try XCTUnwrap(values["rows"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["bodyType"] as? String, "string")
        XCTAssertEqual(rows[1]["outcome"] as? String, "headers")
        XCTAssertEqual(rows[1]["status"] as? Int, 200, "The observer uses WebKit's actual Response.status getter")
        let text = String(decoding: captured.encodedData, as: UTF8.self)
        XCTAssertFalse(text.contains("LOCAL_PRIVATE_URL")); XCTAssertFalse(text.contains("LOCAL_PRIVATE_BODY"))
        XCTAssertFalse(text.contains("LOCAL_PRIVATE_RESPONSE"))
        let stopped = await browser.modelRequestMetadata(command: "stop", tabID: id, view: view, ownerToken: token)
        XCTAssertFalse(try XCTUnwrap(stopped).active)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
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
}

final class ChatGPTRequestMetadataServerTests: XCTestCase {
    func testSameTurnToolContinuationKeepsOneCaptureClockUntilFinalOrSecondRoundFailure() async throws {
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
    func arm(expiresIn: TimeInterval = 60) throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        let data = try JSONSerialization.data(withJSONObject: ["taskID": task.uuidString.lowercased(), "threadID": thread.uuidString.lowercased(),
            "provider": "chatgpt", "purpose": "request_metadata_v1", "expiresAt": formatter.string(from: Date().addingTimeInterval(expiresIn))])
        let path = directory.appendingPathComponent("arm.json"); try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func lease(expiresIn: TimeInterval = 60) throws -> ChatGPTRequestMetadataLease {
        try arm(expiresIn: expiresIn)
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
    private var sends = 0
    private var fingerprint = ""
    private var authorization: ChatGPTRequestMetadataLease?
    private var ledger: [String] = []
    init(fails: Bool = false, failsOnSequence: Int? = nil, toolFirst: Bool = false) {
        self.failsOnSequence = failsOnSequence ?? (fails ? 1 : nil); turnScoped = toolFirst
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
    func activateRequestMetadata(sessionToken: String) async -> Bool { ledger.append("metadata_activate"); return true }
    func snapshotRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot? {
        ledger.append("metadata_snapshot")
        return try? ChatGPTRequestMetadataSnapshot.parse(Data("{\"schemaVersion\":1,\"active\":true,\"expired\":false,\"rows\":[]}".utf8))
    }
    func stopRequestMetadata(sessionToken: String) async -> ChatGPTRequestMetadataSnapshot? {
        ledger.append("metadata_stop")
        return try? ChatGPTRequestMetadataSnapshot.parse(Data("{\"schemaVersion\":1,\"active\":false,\"expired\":false,\"rows\":[]}".utf8))
    }
    func revokeRequestMetadata(sessionToken: String) async { ledger.append("metadata_revoke") }
}

private actor MetadataWireTransport: WebModelTransport {
    let token = UUID().uuidString
    let toolFirst: Bool
    private var sends = 0
    init(toolFirst: Bool = false) { self.toolFirst = toolFirst }
    func request(operation: String, params: Data) throws -> Data {
        let value: [String: Any]
        switch operation {
        case "webProviderStart": value = ["sessionToken": token, "state": "ready"]
        case "webProviderSend": sends += 1; value = ["state": "running"]
        case "webProviderPoll": value = ["state": "complete", "text": toolFirst && sends == 1
            ? "{\"type\":\"tool_calls\",\"calls\":[{\"name\":\"exec_command\",\"arguments\":{\"cmd\":\"fixture\"}}]}"
            : "{\"type\":\"message\",\"text\":\"OK\"}"]
        default: value = ["cleanup": "not_created"]
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(value))
    }
}

import ApplicationServices
import AutomationCore
import Foundation
import XCTest
@testable import Mactopus

/// Actual 4B model, bundled App Server, production Core and borrowed DOM
/// transport. Chrome/profile/pages are owned headless fixtures; no ordinary
/// Chrome attachment, human concurrency, screen input or OS noninterference
/// qualification is implied. Production instructions and tool choice are not
/// replaced with a scripted plan. Every native mutation approval is filtered.
@MainActor
final class BorrowedChromeQwenConcurrentLiveTests: XCTestCase {
    private let model = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
    private let value = "Qwen-7 東京 👋"
    private struct Failure: Error { let message: String }
    private struct NoGrounder: VisualGroundingClient {
        func prepare() async throws { }
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw Failure(message: "Visual grounding is outside this semantic fixture")
        }
        func shutdown() async -> [String] { [] }
    }

    func testStrictFixtureApprovalAdmitsObservedFocusAndEitherMutationOrderButNoRepeat() throws {
        let audit = approvalFixture()
        func observed() throws { audit.observe(try approvalSnapshot()) }
        try observed()
        XCTAssertTrue(audit.approve(try approvalRequest(summary: "AXPress on Fixture Unicode value", arguments: [
            "snapshot_id": fixtureSnapshotID, "element_index": 2, "ax_action": "AXPress",
        ])))
        try observed()
        XCTAssertTrue(audit.approve(try approvalRequest(summary: "Set text on Fixture Unicode value", arguments: [
            "snapshot_id": fixtureSnapshotID, "element_index": 2, "text": value,
        ])))
        try observed()
        XCTAssertTrue(audit.approve(try approvalRequest(summary: "AXPress on Increment fixture counter", arguments: [
            "snapshot_id": fixtureSnapshotID, "element_index": 1, "ax_action": "AXPress",
        ])))
        try observed()
        XCTAssertFalse(audit.approve(try approvalRequest(summary: "AXPress on Increment fixture counter", arguments: [
            "snapshot_id": fixtureSnapshotID, "element_index": 1, "ax_action": "AXPress",
        ])))
        XCTAssertEqual(audit.approvedFieldFocuses, 1)
        XCTAssertEqual(audit.approvedPresses, 1)
        XCTAssertEqual(audit.approvedTexts, 1)
    }

    func testStrictFixtureApprovalRejectsNativeForeignStaleAndWrongValueRequests() throws {
        let valid: [String: Any] = ["snapshot_id": fixtureSnapshotID, "element_index": 2, "text": value]
        for (arguments, target) in [
            (valid, ["observed_page_url": "file:///wrong-page"] as [String: Any]),
            (valid, ["process_id": 9876] as [String: Any]),
            (valid.merging(["snapshot_id": UUID().uuidString]) { _, new in new }, [:]),
            (valid.merging(["element_index": 1]) { _, new in new }, [:]),
            (valid.merging(["text": "wrong"]) { _, new in new }, [:]),
            (valid.merging(["key": "a"]) { _, new in new }, [:]),
        ] {
            let audit = approvalFixture()
            audit.observe(try approvalSnapshot())
            XCTAssertFalse(audit.approve(try approvalRequest(summary: "Set text on Fixture Unicode value", arguments: arguments, targetOverride: target)))
        }
        let audit = approvalFixture()
        audit.observe(try approvalSnapshot())
        for title in ["Allow computer input?", "Allow an application action?", "Allow a command?"] {
            XCTAssertFalse(audit.approve(.init(id: UUID().uuidString, taskID: "fixture-task", kind: .computerUse,
                title: title, summary: "Click or open", details: "{\"bundle_id\":\"com.google.Chrome\"}")))
        }
        XCTAssertEqual(audit.approvedPresses + audit.approvedTexts + audit.approvedFieldFocuses, 0)
    }

    func testTargetLifecycleExcludesOnlyExtensionBackgroundExecutionContexts() {
        let page: [String: Any] = ["targetId": "fixture-page", "type": "page", "url": "file:///fixture.html"]
        let worker: [String: Any] = ["targetId": "extension-worker", "type": "service_worker", "url": "chrome-extension://fixture/worker.js"]
        let background: [String: Any] = ["targetId": "extension-background", "type": "background_page", "url": "chrome-extension://fixture/background.html"]
        XCTAssertEqual(Self.stableTargets([page, worker, background]), Self.stableTargets([page]))
        for extra in [
            ["targetId": "other-page", "type": "page", "url": "chrome-extension://fixture/page.html"],
            ["targetId": "site-worker", "type": "service_worker", "url": "https://example.com/worker.js"],
            ["targetId": "site-background", "type": "background_page", "url": "https://example.com/background.html"],
            ["targetId": "internal", "type": "browser_ui", "url": "chrome://fixture/"],
        ] {
            XCTAssertNotEqual(Self.stableTargets([page, extra]), Self.stableTargets([page]))
        }
        XCTAssertNotEqual(Self.stableTargets([page.merging(["url": "file:///replaced.html"]) { _, new in new }]), Self.stableTargets([page]))
    }

    private let fixtureSnapshotID = "11111111-1111-4111-8111-111111111111"
    private let fixtureHandle = "22222222-2222-4222-8222-222222222222"
    private let fixtureEpoch = "33333333-3333-4333-8333-333333333333"
    private var fixtureURL: URL { URL(fileURLWithPath: "/fixture/page.html") }
    private func approvalFixture() -> QwenBorrowedApprovalAudit {
        .init(taskID: "fixture-task", pid: 4242, fixtureURL: fixtureURL, expectedValue: value)
    }
    private func approvalSnapshot() throws -> TimelineEntry {
        let text = """
        AXSNAPSHOT id=\(fixtureSnapshotID) pid=4242 bundle="com.google.Chrome" tab_handle=\(fixtureHandle) document_epoch=\(fixtureEpoch) source=chrome_devtools url="\(fixtureURL.absoluteString)"
        #1 role="AXButton" label="Increment fixture counter" enabled=true settable=false actions=["AXPress"]
        #2 role="AXTextField" label="Fixture Unicode value" value="" enabled=true settable=true actions=["AXPress"]
        """
        let input = String(data: try JSONSerialization.data(withJSONObject: ["contentItems": [["type": "inputText", "text": text]]]), encoding: .utf8)!
        return TimelineEntry(kind: .tool, title: "snapshot", body: "", toolEvent: .init(name: "computer_v2_snapshot", summary: "", status: .succeeded, input: input))
    }
    private func approvalRequest(summary: String, arguments: [String: Any], targetOverride: [String: Any] = [:]) throws -> ActionApprovalRequest {
        let target: [String: Any] = ["bundle_id": "com.google.Chrome", "process_id": 4242,
            "observed_page_url": fixtureURL.absoluteString, "tab_handle": fixtureHandle, "document_epoch": fixtureEpoch]
        let details = String(data: try JSONSerialization.data(withJSONObject: ["model_arguments": arguments,
            "resolved_target": target.merging(targetOverride) { _, new in new }]), encoding: .utf8)!
        return .init(id: UUID().uuidString, taskID: "fixture-task", kind: .computerUse, title: "Fixture action", summary: summary, details: details)
    }

    func testQwenChoosesBorrowedBackgroundToolsWhileIndependentTabChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless((environment["HEYDASH_QWEN_CONCURRENT_GATE"] ?? environment["TEST_RUNNER_HEYDASH_QWEN_CONCURRENT_GATE"]) == "1",
                          "Reserve the inference lane and explicitly opt in to this real Qwen headless gate.")
        try XCTSkipUnless(AXIsProcessTrusted(), "Existing Accessibility permission is required; this test never requests it.")
        try await requireNoMLXListener()
        let artifact = try MactopusRuntimeArtifact.resolve()
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: chrome.path), "Installed Chrome required.")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BorrowedChromeConcurrentFixture.html")
        let agentURL = try XCTUnwrap(URL(string: fixture.absoluteString + "?role=qwen-agent"))
        let peerURL = try XCTUnwrap(URL(string: fixture.absoluteString + "?role=independent-peer"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusQwenConcurrent-\(UUID().uuidString)")
        let profile = root.appendingPathComponent("chrome-profile"), home = root.appendingPathComponent("runtime-home")
        for directory in [root, profile, home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let traceURL = home.appendingPathComponent("app-server-wire.jsonl")
        let child = try OwnedChildProcess(executableURL: chrome, arguments: [
            "--headless=new", "--no-first-run", "--no-default-browser-check",
            "--user-data-dir=\(profile.path)", "--remote-debugging-port=0", agentURL.absoluteString,
        ])
        let taskID = "qwen-background-fixture"
        var runtime: CodexAppServerRuntime?, controller: BrowserCDPConnection?, owner: BorrowedChromeSessionOwner?
        var events: Task<Void, Never>?, independentWork: Task<[UInt64], Error>?
        var failure: Error?, runtimeCleanupVerified = false
        let audit = QwenBorrowedApprovalAudit(taskID: taskID, pid: child.processIdentifier, fixtureURL: agentURL, expectedValue: value)
        let wire = QwenBorrowedCommandAudit()
        let peerClock = QwenPeerClock()
        var evidence: [String: Any] = [
            "model": model, "app_server_binary_sha256": artifact.manifest.binarySHA256,
            "production_core": true, "bundled_app_server": true, "scripted_tool_plan": false,
            "ordinary_profile": false, "concurrent_human_input": false, "desktop_interference_qualified": false,
        ]
        do {
            let endpoint = try await endpoint(profile: profile, child: child)
            let control = BrowserCDPConnection(wire: try URLSessionBrowserCDPWire(endpoint: endpoint))
            controller = control
            _ = try await command(control, "Target.createTarget", ["url": peerURL.absoluteString])
            let before = try await targets(control)
            let agentID = try targetID(before, url: agentURL), peerID = try targetID(before, url: peerURL)
            let agentSession = try await attach(control, id: agentID), peerSession = try await attach(control, id: peerID)
            try await ready(control, session: agentSession, url: agentURL)
            try await ready(control, session: peerSession, url: peerURL)
            let consent = ChromeDebuggingConsent(approvedByUser: true)
            let file = try ChromeDebuggingEndpointFile.read(explicitlyApprovedUserDataDirectory: profile, consent: consent)
            let authority = ChromeDebuggingConnectionAuthority(endpoint: file.endpoint, consent: consent) {
                try file.validateIdentity()
                guard child.isRunning else { throw BrowserTabBrokerError.browserGenerationChanged }
            }
            let adapter = try await ChromeDebuggingConnection.connect(authority: authority, makeWire: {
                QwenBorrowedAuditedWire(base: try URLSessionBrowserCDPWire(endpoint: $0), audit: wire)
            })
            let identity = BorrowedChromeApplicationIdentity(processIdentifier: child.processIdentifier,
                bundleIdentifier: "com.google.Chrome", executableURL: chrome)
            let connectionOwner = try BorrowedChromeSessionOwner(application: identity, transport: adapter,
                consent: consent, verifyIdentity: { try authority.validate() })
            owner = connectionOwner
            let request = ChromeConnectionRequest(application: identity, userDataDirectory: profile, consent: consent)
            var configuration = CodexAppServerRuntime.Configuration.localQwen
            configuration.codexHomePath = home.path
            configuration.workspacePath = home.path
            configuration.model = model
            configuration.protocolTracePath = traceURL.path
            XCTAssertEqual(configuration.effectiveBackend, .headlessMLX)
            let instance = CodexAppServerRuntime(configuration: configuration, visualGrounder: NoGrounder(), borrowedChromeConnector: {
                guard $0.id == request.id else { throw Failure(message: "Unexpected fixture connection") }
                return connectionOwner
            })
            runtime = instance
            events = Task {
                for await event in instance.events() {
                    switch event {
                    case .timelineEntryAppended(let id, let entry) where id == taskID:
                        audit.observe(entry)
                    case .taskStatusChanged(let id, let status) where id == taskID:
                        audit.status = status
                    case .approvalRequested(let approval):
                        let allowed = audit.approve(approval)
                        try? await instance.resolveApproval(requestID: approval.id, approved: allowed)
                        if !allowed { try? await instance.interrupt(taskID: taskID) }
                    default: break
                    }
                }
            }
            _ = try await instance.loadTasks()
            try await instance.connectChrome(request)
            independentWork = Task {
                var times = [UInt64]()
                for tick in 1...3_000 {
                    try Task.checkCancellation()
                    let state = try await self.evaluate(control, session: peerSession, expression: """
                    (() => { document.querySelector('#increment').click();
                      const input = document.querySelector('#value'); input.value = 'Peer-\(tick) café';
                      input.dispatchEvent(new Event('input', {bubbles:true}));
                      return {count:document.querySelector('#count').textContent,value:input.value,
                              echo:document.querySelector('#echo').textContent}; })()
                    """)
                    guard state["count"] as? String == "Counter \(tick)", state["value"] as? String == "Peer-\(tick) café",
                          state["echo"] as? String == "Value Peer-\(tick) café" else { throw Failure(message: "Independent page was corrupted") }
                    times.append(DispatchTime.now().uptimeNanoseconds)
                    peerClock.tick = tick
                    if peerClock.finished { return times }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw Failure(message: "Independent fixture work exceeded its bound")
            }
            try await waitUntil(seconds: 5) { peerClock.tick >= 2 }
            let start = DispatchTime.now().uptimeNanoseconds
            try await instance.submit(prompt: """
                In the already connected Chrome session, find the tab with this exact address: \(agentURL.absoluteString)
                Increase its counter exactly once, and enter \(value) in the field labelled Fixture Unicode value.
                Verify the counter is 1 and the field contains that exact text, then tell me what you observed.
                Leave all other tabs unchanged and keep Chrome in the background.
                """, toTaskID: taskID, modelID: model)
            try await waitUntil(seconds: 180) { audit.status == .completed || audit.status == .waiting || !audit.denied.isEmpty }
            evidence["elapsed_ms"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            peerClock.finished = true
            let finishedWork = try XCTUnwrap(independentWork)
            let times = try await finishedWork.value
            independentWork = nil
            XCTAssertEqual(audit.status, .completed)
            XCTAssertEqual(audit.denied, [], "Only exact fixture semantic actions may receive approval.")
            XCTAssertEqual(audit.approvedPresses, 1)
            XCTAssertEqual(audit.approvedTexts, 1)
            XCTAssertTrue(audit.verifiedFinalSnapshot, "Qwen must observe the result after BOTH approved mutations.")
            XCTAssertFalse(audit.assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let agentState = try await state(control, session: agentSession), peerState = try await state(control, session: peerSession)
            XCTAssertEqual(agentState["url"] as? String, agentURL.absoluteString)
            XCTAssertEqual(agentState["count"] as? String, "Counter 1")
            XCTAssertEqual(agentState["value"] as? String, value)
            XCTAssertEqual(agentState["echo"] as? String, "Value \(value)")
            XCTAssertEqual(peerState["url"] as? String, peerURL.absoluteString)
            XCTAssertEqual(peerState["count"] as? String, "Counter \(times.count)")
            XCTAssertEqual(peerState["value"] as? String, "Peer-\(times.count) café")
            let mutations = wire.rows.filter { $0.method == "Runtime.callFunctionOn" }
            XCTAssertEqual(mutations.count, 2 + audit.approvedFieldFocuses)
            let first = try XCTUnwrap(mutations.first?.time), last = try XCTUnwrap(mutations.last?.time)
            let overlaps = times.filter { $0 > first && $0 < last }
            XCTAssertGreaterThanOrEqual(overlaps.count, 1, "Independent progress must occur between actual agent mutations.")
            let attachedSessions = Set(wire.sessions.filter { $0.value == agentID }.keys)
            XCTAssertEqual(attachedSessions.count, 1)
            XCTAssertEqual(Set(mutations.compactMap(\.session)), attachedSessions)
            XCTAssertEqual(Set(wire.rows.filter { $0.method == "Target.attachToTarget" }.compactMap(\.target)), [agentID])
            XCTAssertFalse(wire.rows.contains { Self.forbidden($0.method) })
            XCTAssertEqual(audit.unexpectedTools, [])
            let report = await instance.shutdown()
            runtimeCleanupVerified = report.succeeded
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            runtime = nil
            events?.cancel(); events = nil
            try await requireNoMLXListener()
            XCTAssertEqual(wire.rows.filter { $0.method == "Target.detachFromTarget" }.count, 1)
            let after = try await targets(control)
            let initialIdentities = Self.redactedTargets(before), finalIdentities = Self.redactedTargets(after)
            let initialIDs = Set(initialIdentities.compactMap { $0["id"] }), finalIDs = Set(finalIdentities.compactMap { $0["id"] })
            evidence["target_lifecycle"] = [
                "initial": initialIdentities, "final": finalIdentities,
                "added": finalIdentities.filter { !initialIDs.contains($0["id", default: ""]) },
                "removed": initialIdentities.filter { !finalIDs.contains($0["id", default: ""]) },
            ]
            XCTAssertEqual(Self.stableTargets(after), Self.stableTargets(before),
                           "Only observed extension service_worker/background_page lifecycles are excluded; page targets, browser UI and all other identities/URLs remain exact.")
            let trace = try AppServerWireTrace.load(traceURL)
            XCTAssertEqual(trace.parseFailures, [])
            for method in ["thread/start", "turn/start"] {
                let requests = trace.messages.filter { $0.direction == .clientToServer && $0.method == method }
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual((requests.first?.object["params"] as? [String: Any])?["model"] as? String, model)
            }
            evidence["independent_ticks"] = times.count
            evidence["interleaved_completions"] = overlaps.count
            evidence["agent_mutation_enqueue_ns"] = mutations.map(\.time)
            evidence["independent_completion_ns"] = times
            evidence["model_tools"] = audit.tools
            evidence["assistant"] = audit.assistant
            evidence["final_dom"] = agentState
            evidence["result"] = "observed; XCTest assertions remain authoritative"
        } catch {
            failure = error
            evidence["error"] = String(describing: error)
        }
        independentWork?.cancel()
        if let independentWork { _ = try? await independentWork.value }
        if let runtime {
            try? await runtime.interrupt(taskID: taskID)
            let report = await runtime.shutdown()
            runtimeCleanupVerified = report.succeeded
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        }
        events?.cancel()
        await owner?.disconnect()
        await controller?.close()
        let stop = await child.stop()
        XCTAssertTrue(stop.succeeded)
        if runtimeCleanupVerified {
            do { try await requireNoMLXListener() }
            catch { if failure == nil { failure = error }; evidence["cleanup_listener_error"] = String(describing: error) }
        }
        evidence["runtime_cleanup_verified"] = runtimeCleanupVerified
        evidence["headless_chrome_cleanup_verified"] = stop.succeeded
        evidence["approved_presses"] = audit.approvedPresses
        evidence["approved_texts"] = audit.approvedTexts
        evidence["approved_field_focuses"] = audit.approvedFieldFocuses
        evidence["denied_approvals"] = audit.denied
        evidence["model_tools"] = audit.tools
        evidence["assistant"] = audit.assistant
        evidence["transcript"] = audit.transcript
        let assertionFailures = testRun?.totalFailureCount ?? 0
        evidence["xctest_failures_at_cleanup"] = assertionFailures
        let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        let attachment = XCTAttachment(string: String(data: encoded, encoding: .utf8)!)
        attachment.name = "Real Qwen borrowed concurrent fixture evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        if FileManager.default.fileExists(atPath: traceURL.path) {
            let traceAttachment = XCTAttachment(data: try Data(contentsOf: traceURL), uniformTypeIdentifier: "public.json")
            traceAttachment.name = "Isolated real Qwen App Server transport trace"
            traceAttachment.lifetime = .keepAlways
            add(traceAttachment)
        }
        print("HEYDASH_QWEN_CONCURRENT_EVIDENCE=" + String(data: encoded, encoding: .utf8)!)
        // Keep a failure's isolated model transcript for diagnosis. No ordinary
        // user data is copied here. Remove the exact owned home only on success.
        if failure == nil && assertionFailures == 0 && runtimeCleanupVerified && stop.succeeded { try FileManager.default.removeItem(at: root) }
        else { print("HEYDASH_QWEN_CONCURRENT_ARTIFACT_DIR=" + root.path) }
        if let failure { throw failure }
    }

    private func requireNoMLXListener() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:1237/health")!)
            throw Failure(message: "Port 1237 is already serving; no unrelated server may be adopted or terminated")
        } catch let error as URLError where error.code == .cannotConnectToHost { return }
    }

    private func endpoint(profile: URL, child: OwnedChildProcess) async throws -> URL {
        let consent = ChromeDebuggingConsent(approvedByUser: true)
        defer { consent.revoke() }
        for _ in 0..<200 {
            guard child.isRunning else { throw Failure(message: "Isolated Chrome exited") }
            if let file = try? ChromeDebuggingEndpointFile.read(explicitlyApprovedUserDataDirectory: profile, consent: consent) { return file.endpoint }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Isolated Chrome readiness timed out")
    }
    private func command(_ connection: BrowserCDPConnection, _ method: String, _ parameters: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        let data = try await connection.command(method: method, params: JSONSerialization.data(withJSONObject: parameters), sessionID: session)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func targets(_ connection: BrowserCDPConnection) async throws -> [[String: Any]] {
        let result = try await command(connection, "Target.getTargets")
        return try XCTUnwrap(result["targetInfos"] as? [[String: Any]])
    }
    private func targetID(_ targets: [[String: Any]], url: URL) throws -> String {
        let matches = targets.filter { $0["type"] as? String == "page" && $0["url"] as? String == url.absoluteString }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first?["targetId"] as? String)
    }
    private func attach(_ connection: BrowserCDPConnection, id: String) async throws -> String {
        let reply = try await command(connection, "Target.attachToTarget", ["targetId": id, "flatten": true])
        return try XCTUnwrap(reply["sessionId"] as? String)
    }
    private func evaluate(_ connection: BrowserCDPConnection, session: String, expression: String) async throws -> [String: Any] {
        let reply = try await command(connection, "Runtime.evaluate", ["expression": expression, "returnByValue": true], session: session)
        guard reply["exceptionDetails"] == nil else { throw Failure(message: "Fixture evaluation failed") }
        let remote = try XCTUnwrap(reply["result"] as? [String: Any])
        return try XCTUnwrap(remote["value"] as? [String: Any])
    }
    private func state(_ connection: BrowserCDPConnection, session: String) async throws -> [String: Any] {
        try await evaluate(connection, session: session, expression: "({url:document.URL,count:document.querySelector('#count').textContent,value:document.querySelector('#value').value,echo:document.querySelector('#echo').textContent})")
    }
    private func ready(_ connection: BrowserCDPConnection, session: String, url: URL) async throws {
        for _ in 0..<200 {
            let result = try await evaluate(connection, session: session, expression: "({url:document.URL,ready:document.readyState,fixture:!!document.querySelector('#value')})")
            if result["url"] as? String == url.absoluteString, result["ready"] as? String == "complete", result["fixture"] as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "Fixture document not ready")
    }
    private func waitUntil(seconds: Int, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 10) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(message: "Real model fixture timed out after \(seconds) seconds")
    }
    private static func forbidden(_ method: String) -> Bool {
        method.hasPrefix("Input.") || ["Target.createTarget", "Target.activateTarget", "Target.closeTarget", "Browser.close",
            "Page.navigate", "Page.reload", "Page.bringToFront", "Runtime.evaluate"].contains(method)
    }
    private static func stableTargets(_ targets: [[String: Any]]) -> [[String: String]] {
        targets.filter {
            // Retained real-Chrome evidence showed extension service-worker
            // startup and background-page retirement. These are not user page
            // targets; their independent lifecycle must not disable extensions
            // or relax the exact two fixture-page identity/URL checks.
            !(Set(["service_worker", "background_page"]).contains($0["type"] as? String ?? "")
                && ($0["url"] as? String).flatMap(URL.init(string:))?.scheme == "chrome-extension")
        }.map {
            ["id": $0["targetId"] as? String ?? "missing", "type": $0["type"] as? String ?? "missing",
             "url": $0["url"] as? String ?? "missing"]
        }.sorted { $0["id", default: ""] < $1["id", default: ""] }
    }
    private static func redactedTargets(_ targets: [[String: Any]]) -> [[String: String]] {
        targets.map {
            ["id": $0["targetId"] as? String ?? "missing", "type": $0["type"] as? String ?? "missing",
             "scheme": ($0["url"] as? String).flatMap(URL.init(string:))?.scheme ?? "missing"]
        }.sorted { $0["id", default: ""] < $1["id", default: ""] }
    }
}

@MainActor
private final class QwenPeerClock { var tick = 0; var finished = false }

@MainActor
private final class QwenBorrowedApprovalAudit {
    let taskID: String, pid: Int32, fixtureURL: URL, expectedValue: String
    var status: TaskStatus?, assistant = "", tools = [String](), unexpectedTools = [String](), denied = [String]()
    var transcript = [[String: String]](), approvedPresses = 0, approvedTexts = 0, approvedFieldFocuses = 0, verifiedFinalSnapshot = false
    private var snapshotID: String?, tabHandle: String?, epoch: String?, buttonIndex: Int?, inputIndex: Int?
    private var fieldSupportsPress = false
    init(taskID: String, pid: Int32, fixtureURL: URL, expectedValue: String) {
        self.taskID = taskID; self.pid = pid; self.fixtureURL = fixtureURL; self.expectedValue = expectedValue
    }
    func observe(_ entry: TimelineEntry) {
        if entry.kind == .assistant { assistant += entry.body }
        guard let tool = entry.toolEvent, tool.status != .running,
              let object = Self.object(tool.input) else { return }
        let text = (object["contentItems"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        tools.append(tool.name)
        transcript.append(["tool": tool.name, "status": tool.status.rawValue, "text": text])
        if !["computer_v2_status", "computer_v2_tabs", "computer_v2_bind_tab", "computer_v2_snapshot", "computer_v2_ax", "computer_v2_set_text"].contains(tool.name) {
            unexpectedTools.append(tool.name)
        }
        guard tool.name == "computer_v2_snapshot", tool.status == .succeeded,
              text.contains("url=\"\(fixtureURL.absoluteString)\"") else { return }
        snapshotID = Self.match("AXSNAPSHOT id=([0-9A-Fa-f-]+)", text)
        tabHandle = Self.match("tab_handle=([0-9A-Fa-f-]+)", text)
        epoch = Self.match("document_epoch=([0-9A-Fa-f-]+)", text)
        buttonIndex = nil; inputIndex = nil; fieldSupportsPress = false
        for line in text.split(separator: "\n").map(String.init) {
            guard let index = Self.match("^#([0-9]+)", line).flatMap(Int.init) else { continue }
            if line.contains("label=\"Increment fixture counter\"") && line.contains("actions=[\"AXPress\"]") { buttonIndex = index }
            if line.contains("label=\"Fixture Unicode value\"") && line.contains("settable=true") {
                inputIndex = index
                fieldSupportsPress = line.contains("actions=[\"AXPress\"]")
            }
        }
        if approvedPresses == 1 && approvedTexts == 1,
           text.contains("label=\"Counter 1\" "), text.contains("label=\"Value \(expectedValue)\" ") { verifiedFinalSnapshot = true }
    }
    func approve(_ request: ActionApprovalRequest) -> Bool {
        func reject() -> Bool { denied.append(request.title + ": " + request.summary); return false }
        guard request.kind == .computerUse, request.taskID == taskID, let details = Self.object(request.details),
              let arguments = details["model_arguments"] as? [String: Any], let target = details["resolved_target"] as? [String: Any],
              target["bundle_id"] as? String == "com.google.Chrome", (target["process_id"] as? NSNumber)?.int32Value == pid,
              target["observed_page_url"] as? String == fixtureURL.absoluteString,
              let snapshotID, let tabHandle, let epoch,
              target["tab_handle"] as? String == tabHandle, target["document_epoch"] as? String == epoch,
              arguments["snapshot_id"] as? String == snapshotID,
              let index = (arguments["element_index"] as? NSNumber)?.intValue else { return reject() }
        if request.summary == "AXPress on Increment fixture counter", arguments["ax_action"] as? String == "AXPress",
           Set(arguments.keys) == ["snapshot_id", "element_index", "ax_action"], index == buttonIndex, approvedPresses == 0 {
            approvedPresses += 1
        } else if request.summary == "AXPress on Fixture Unicode value", arguments["ax_action"] as? String == "AXPress",
                  Set(arguments.keys) == ["snapshot_id", "element_index", "ax_action"], index == inputIndex,
                  fieldSupportsPress, approvedFieldFocuses == 0 {
            // A model may legitimately focus its observed field before typing.
            // This is separately bounded and never an extra counter click.
            approvedFieldFocuses += 1
        } else if request.summary == "Set text on Fixture Unicode value", arguments["text"] as? String == expectedValue,
                  Set(arguments.keys) == ["snapshot_id", "element_index", "text"], index == inputIndex, approvedTexts == 0 {
            approvedTexts += 1
        } else { return reject() }
        self.snapshotID = nil
        return true
    }
    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

private final class QwenBorrowedCommandAudit: @unchecked Sendable {
    struct Row: Sendable { let method: String; let session: String?; let target: String?; let time: UInt64 }
    private let lock = NSLock()
    private var records = [Row](), pending = [Int: String](), attached = [String: String]()
    var rows: [Row] { lock.withLock { records } }
    var sessions: [String: String] { lock.withLock { attached } }
    func sent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let method = object["method"] as? String else { return }
        let target = (object["params"] as? [String: Any])?["targetId"] as? String
        lock.withLock {
            records.append(.init(method: method, session: object["sessionId"] as? String, target: target, time: DispatchTime.now().uptimeNanoseconds))
            if method == "Target.attachToTarget", let id = object["id"] as? Int, let target { pending[id] = target }
        }
    }
    func received(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? Int,
              let session = (object["result"] as? [String: Any])?["sessionId"] as? String else { return }
        lock.withLock { if let target = pending.removeValue(forKey: id) { attached[session] = target } }
    }
}
private final class QwenBorrowedAuditedWire: BrowserCDPWire, @unchecked Sendable {
    let base: any BrowserCDPWire, audit: QwenBorrowedCommandAudit
    init(base: any BrowserCDPWire, audit: QwenBorrowedCommandAudit) { self.base = base; self.audit = audit }
    func waitUntilOpen() async throws { try await base.waitUntilOpen() }
    func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) { audit.sent(data); base.enqueue(data, completion: completion) }
    func receive() async throws -> Data { let data = try await base.receive(); audit.received(data); return data }
    func close() { base.close() }
}

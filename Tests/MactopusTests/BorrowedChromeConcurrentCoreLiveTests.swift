import ApplicationServices
import AutomationCore
import Foundation
import XCTest
@testable import Mactopus

/// Production Core + real Chrome DOM, with an independent controller changing
/// a second tab. Both pages/process/profile are disposable and test-owned.
/// This is NOT ordinary Chrome, Qwen, human concurrency, foreground, pointer or
/// clipboard qualification. Those require separate attributable live evidence.
@MainActor
final class BorrowedChromeConcurrentCoreLiveTests: XCTestCase {
    private struct Failure: Error { let message: String }
    private struct NoGrounder: VisualGroundingClient {
        func prepare() async throws { }
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw Failure(message: "The concurrent fixture must not call a model")
        }
        func shutdown() async -> [String] { [] }
    }
    private final class RuntimeAudit {
        var status: TaskStatus?
        var approvals = 0
    }

    func testConcurrentSeparateTabProgressAndSameTargetConflictRecoveryThroughProductionCore() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless((env["HEYDASH_CONCURRENT_CORE_GATE"] ?? env["TEST_RUNNER_HEYDASH_CONCURRENT_CORE_GATE"]) == "1",
                          "Explicit isolated headless Chrome production-Core gate required.")
        try XCTSkipUnless(AXIsProcessTrusted(), "Existing Accessibility permission required; never requested by this test.")
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: chrome.path), "Installed Chrome required.")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let page = fixtures.appendingPathComponent("BorrowedChromeConcurrentFixture.html")
        let agentURL = try XCTUnwrap(URL(string: page.absoluteString + "?role=agent"))
        let peerURL = try XCTUnwrap(URL(string: page.absoluteString + "?role=independent"))
        let navigatedURL = try XCTUnwrap(URL(string: page.absoluteString + "?role=agent&revision=2"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusConcurrentCore-\(UUID().uuidString)")
        let profile = root.appendingPathComponent("chrome-profile")
        let home = root.appendingPathComponent("runtime-home")
        for directory in [root, profile, home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let executable = home.appendingPathComponent("app-server.ts")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("BorrowedChromeConcurrentAppServer.ts"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(agentURL.absoluteString.utf8).write(to: home.appendingPathComponent("agent-url"))
        let child = try OwnedChildProcess(executableURL: chrome, arguments: [
            "--headless=new", "--no-first-run", "--no-default-browser-check",
            "--user-data-dir=\(profile.path)", "--remote-debugging-port=0", agentURL.absoluteString,
        ])
        var runtime: CodexAppServerRuntime?
        var controller: BrowserCDPConnection?
        var events: Task<Void, Never>?
        var peerWork: Task<[UInt64], Error>?
        var owner: BorrowedChromeSessionOwner?
        var capturedFailure: Error?
        do {
            let endpoint = try await waitForEndpoint(profile: profile, child: child)
            let control = BrowserCDPConnection(wire: try URLSessionBrowserCDPWire(endpoint: endpoint))
            controller = control
            // Only the external fixture OWNER creates its second page. The
            // production borrowed connection is audited separately below.
            _ = try await command(control, "Target.createTarget", ["url": peerURL.absoluteString])
            let initialTargets = try await targets(control)
            let agentID = try exactTarget(initialTargets, url: agentURL)
            let peerID = try exactTarget(initialTargets, url: peerURL)
            XCTAssertNotEqual(agentID, peerID)
            let agentSession = try await attach(control, targetID: agentID)
            let peerSession = try await attach(control, targetID: peerID)
            try await waitForDocument(control, session: agentSession, url: agentURL)
            try await waitForDocument(control, session: peerSession, url: peerURL)

            let consent = ChromeDebuggingConsent(approvedByUser: true)
            let endpointFile = try ChromeDebuggingEndpointFile.read(explicitlyApprovedUserDataDirectory: profile, consent: consent)
            let authority = ChromeDebuggingConnectionAuthority(endpoint: endpointFile.endpoint, consent: consent) {
                try endpointFile.validateIdentity()
                guard child.isRunning else { throw BrowserTabBrokerError.browserGenerationChanged }
            }
            let wireAudit = ConcurrentBorrowedWireAudit()
            let adapter = try await ChromeDebuggingConnection.connect(authority: authority, makeWire: {
                ConcurrentBorrowedAuditWire(base: try URLSessionBrowserCDPWire(endpoint: $0), audit: wireAudit)
            })
            let identity = BorrowedChromeApplicationIdentity(processIdentifier: child.processIdentifier,
                bundleIdentifier: "com.google.Chrome", executableURL: chrome)
            let connectionOwner = try BorrowedChromeSessionOwner(application: identity, transport: adapter,
                consent: consent, verifyIdentity: { try authority.validate() })
            owner = connectionOwner
            let request = ChromeConnectionRequest(application: identity, userDataDirectory: profile, consent: consent)
            var config = CodexAppServerRuntime.Configuration.localQwen
            config.executable = .fixture(path: executable.path)
            config.codexHomePath = home.path
            let instance = CodexAppServerRuntime(configuration: config, visualGrounder: NoGrounder(), borrowedChromeConnector: {
                guard $0.id == request.id else { throw Failure(message: "Unexpected native connection request") }
                return connectionOwner
            })
            runtime = instance
            let audit = RuntimeAudit()
            events = Task {
                for await event in instance.events() {
                    switch event {
                    case .taskStatusChanged(_, let status): audit.status = status
                    case .approvalRequested(let approval):
                        audit.approvals += 1
                        try? await instance.resolveApproval(requestID: approval.id, approved: true)
                    default: break
                    }
                }
            }
            _ = try await instance.loadTasks()
            try await instance.connectChrome(request)
            // Independent, test-owned actor. Uses a different flattened
            // session/connection; it never touches a user's page or desktop.
            let peerClock = ConcurrentPeerClock()
            peerWork = Task {
                var timestamps = [UInt64]()
                for tick in 1...5_000 {
                    try Task.checkCancellation()
                    let expected = "Peer-\(tick) café 👋"
                    let literal = String(data: try JSONSerialization.data(withJSONObject: expected, options: [.fragmentsAllowed]), encoding: .utf8)!
                    let expression = """
                    (() => { document.querySelector('#increment').click();
                      const input = document.querySelector('#value'); input.value = \(literal);
                      input.dispatchEvent(new Event('input', {bubbles:true}));
                      return {count:document.querySelector('#count').textContent,
                              value:input.value, echo:document.querySelector('#echo').textContent}; })()
                    """
                    let state = try await self.evaluate(control, session: peerSession, expression: expression)
                    guard state["count"] as? String == "Counter \(tick)", state["value"] as? String == expected,
                          state["echo"] as? String == "Value \(expected)" else { throw Failure(message: "Peer page was corrupted") }
                    let now = DispatchTime.now().uptimeNanoseconds
                    timestamps.append(now)
                    peerClock.record(tick: tick)
                    if peerClock.isFinished { return timestamps }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw Failure(message: "Concurrent fixture exceeded bounded peer work")
            }
            try await waitFor { peerClock.tick >= 2 }
            try await instance.submit(prompt: "Run the isolated concurrent tab fixture", toTaskID: "concurrent-task",
                                      modelID: "lmstudio-community/Qwen3.5-4B-MLX-4bit")
            try await waitForFile("navigate-agent-now", in: home, audit: audit)
            let beforeConflictMutations = wireAudit.rows.filter { $0.method == "Runtime.callFunctionOn" }.count
            XCTAssertEqual(beforeConflictMutations, 4)
            _ = try await command(control, "Page.navigate", ["url": navigatedURL.absoluteString], session: agentSession)
            try await waitForDocument(control, session: agentSession, url: navigatedURL)
            try Data("ready".utf8).write(to: home.appendingPathComponent("agent-navigation-complete"))
            try await waitForFile("stale-refused", in: home, audit: audit)
            let stateAfterRefusal = try await readState(control, session: agentSession)
            XCTAssertEqual(stateAfterRefusal["count"] as? String, "Counter 0")
            XCTAssertEqual(stateAfterRefusal["value"] as? String, "")
            XCTAssertEqual(wireAudit.rows.filter { $0.method == "Runtime.callFunctionOn" }.count, beforeConflictMutations,
                           "The stale request must be rejected before any DOM mutation enqueue.")
            try Data("ready".utf8).write(to: home.appendingPathComponent("confirm-no-stale-mutation"))
            try await waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            peerClock.finish()
            let finishedPeerWork = try XCTUnwrap(peerWork)
            let ticks = try await finishedPeerWork.value
            peerWork = nil
            let finalAgent = try await readState(control, session: agentSession)
            XCTAssertEqual(finalAgent["url"] as? String, navigatedURL.absoluteString)
            XCTAssertEqual(finalAgent["count"] as? String, "Counter 3", "Two successful clicks preceded navigation; three followed fresh observation.")
            XCTAssertEqual(finalAgent["value"] as? String, "Agent-5 東京 👋")
            XCTAssertEqual(finalAgent["echo"] as? String, "Value Agent-5 東京 👋")
            let finalPeer = try await readState(control, session: peerSession)
            XCTAssertEqual(finalPeer["url"] as? String, peerURL.absoluteString)
            XCTAssertEqual(finalPeer["count"] as? String, "Counter \(ticks.count)")
            XCTAssertEqual(finalPeer["value"] as? String, "Peer-\(ticks.count) café 👋")
            XCTAssertEqual(finalPeer["echo"] as? String, "Value Peer-\(ticks.count) café 👋")
            let rows = wireAudit.rows
            let mutations = rows.filter { $0.method == "Runtime.callFunctionOn" }
            XCTAssertEqual(mutations.count, 10)
            let firstMutation = try XCTUnwrap(mutations.first?.time), lastMutation = try XCTUnwrap(mutations.last?.time)
            let overlappingTicks = ticks.filter { $0 > firstMutation && $0 < lastMutation }
            XCTAssertGreaterThanOrEqual(overlappingTicks.count, 2, "Both actors must actually interleave, not merely run sequentially.")
            XCTAssertTrue(mutations.contains { mutation in ticks.contains { $0 < mutation.time } && ticks.contains { $0 > mutation.time } })
            XCTAssertEqual(Set(rows.filter { $0.method == "Target.attachToTarget" }.compactMap(\.targetID)), [agentID])
            XCTAssertEqual(Set(mutations.compactMap(\.sessionID)).count, 1)
            XCTAssertFalse(mutations.contains { $0.sessionID == nil })
            let attachedAgentSessions = Set(wireAudit.attachedSessions.filter { $0.value == agentID }.keys)
            XCTAssertEqual(attachedAgentSessions.count, 1)
            XCTAssertEqual(Set(mutations.compactMap(\.sessionID)), attachedAgentSessions,
                           "Every production mutation must use the exact session returned for the agent target.")
            XCTAssertFalse(rows.contains { $0.method.hasPrefix("Input.") || [
                "Target.createTarget", "Target.activateTarget", "Target.closeTarget", "Browser.close",
                "Page.navigate", "Page.reload", "Page.bringToFront", "Runtime.evaluate",
            ].contains($0.method) }, "The borrowed production connection must not perform global input or browser lifecycle actions.")
            let toolRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("results.json"))) as? [[String: Any]])
            let failures = toolRows.filter { $0["success"] as? Bool == false }
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(failures.first?["stage"] as? String, "stale-press")
            let stopped = await instance.shutdown()
            runtime = nil
            XCTAssertTrue(stopped.succeeded, stopped.issues.joined(separator: "; "))
            events?.cancel(); events = nil
            XCTAssertEqual(wireAudit.rows.filter { $0.method == "Target.detachFromTarget" }.count, 1)
            let finalTargets = try await targets(control)
            let initialIdentities = redactedTargets(initialTargets, agentID: agentID, peerID: peerID)
            let finalIdentities = redactedTargets(finalTargets, agentID: agentID, peerID: peerID)
            let initialIDs = Set(initialIdentities.compactMap { $0["id"] })
            let finalIDs = Set(finalIdentities.compactMap { $0["id"] })
            let addedTargets = finalIdentities.filter { !initialIDs.contains($0["id", default: ""]) }
            let removedTargets = initialIdentities.filter { !finalIDs.contains($0["id", default: ""]) }
            let targetEvidence: [String: Any] = [
                "initial": initialIdentities, "final": finalIdentities,
                "added": addedTargets, "removed": removedTargets,
                "allowed_churn": "extension service_worker only; all other target identities/types/source classes must match",
            ]
            let targetText = String(data: try JSONSerialization.data(withJSONObject: targetEvidence, options: [.sortedKeys]), encoding: .utf8)!
            print("HEYDASH_CONCURRENT_TARGETS=" + targetText)
            let targetAttachment = XCTAttachment(string: targetText)
            targetAttachment.name = "Isolated Chrome target identity and type lifecycle evidence"
            targetAttachment.lifetime = .keepAlways
            add(targetAttachment)
            let initialPages = Set(initialTargets.filter { $0["type"] as? String == "page" }.compactMap { $0["targetId"] as? String })
            let finalPages = Set(finalTargets.filter { $0["type"] as? String == "page" }.compactMap { $0["targetId"] as? String })
            XCTAssertEqual(initialPages, [agentID, peerID], "No other page may enter this isolated fixture.")
            XCTAssertEqual(finalPages, initialPages, "Every fixture page identity must survive borrowed cleanup unchanged.")
            // The retained diagnostic run observed one chrome-extension:
            // service_worker starting, with both fixture pages and all other
            // identities unchanged. Keep extensions/enforcement enabled; admit
            // only that independently managed target class, never page churn.
            let allowedWorker: ([String: String]) -> Bool = {
                $0["type"] == "service_worker" && $0["source_class"] == "extension" && $0["fixture_role"] == "none"
            }
            XCTAssertTrue((addedTargets + removedTargets).allSatisfy(allowedWorker),
                          "Every added/removed target must be an extension service worker, never a page or another target class.")
            XCTAssertEqual(finalIdentities.filter { !allowedWorker($0) }, initialIdentities.filter { !allowedWorker($0) },
                           "All non-extension-service-worker IDs, types, source classes and fixture roles must remain exact.")
            XCTAssertTrue(child.isRunning)
            let timeline: [String: Any] = [
                "agent_mutation_enqueue_ns": mutations.map(\.time), "independent_completion_ns": ticks,
                "interleaved_independent_completions": overlappingTicks.count,
                "same_target_stale_mutation_enqueues": 0, "human_input_tested": false,
                "desktop_interference_qualified": false,
            ]
            let timelineText = String(data: try JSONSerialization.data(withJSONObject: timeline, options: [.sortedKeys]), encoding: .utf8)!
            let timelineAttachment = XCTAttachment(string: timelineText)
            timelineAttachment.name = "Concurrent actor monotonic timing evidence"
            timelineAttachment.lifetime = .keepAlways
            add(timelineAttachment)
            print("HEYDASH_CONCURRENT_CORE_EVIDENCE production_core=true real_dom=true agent_cycles=5 mutation_enqueues=\(mutations.count) stale_mutation_enqueues=0 fresh_observation_recovery=true independent_ticks=\(ticks.count) interleaved_ticks=\(overlappingTicks.count) borrowed_lifecycle_mutations=0 model_used=false ordinary_profile=false concurrent_human_input=false desktop_interference_qualified=false")
        } catch {
            capturedFailure = error
            print("HEYDASH_CONCURRENT_CORE_ERROR \(error)")
        }
        if let results = try? String(contentsOf: home.appendingPathComponent("results.json"), encoding: .utf8) {
            let attachment = XCTAttachment(string: results)
            attachment.name = "Isolated concurrent production Core fixture results"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        peerWork?.cancel()
        if let peerWork { _ = try? await peerWork.value }
        if let runtime { _ = await runtime.shutdown() }
        events?.cancel()
        await owner?.disconnect()
        await controller?.close()
        let stopped = await child.stop()
        XCTAssertTrue(stopped.succeeded, "Only the fixture owner stops its exact headless child; preserve profile if cleanup is uncertain.")
        if stopped.succeeded { try FileManager.default.removeItem(at: root) }
        if let capturedFailure { throw capturedFailure }
    }

    private func waitForEndpoint(profile: URL, child: OwnedChildProcess) async throws -> URL {
        let consent = ChromeDebuggingConsent(approvedByUser: true)
        defer { consent.revoke() }
        for _ in 0..<200 {
            guard child.isRunning else { throw Failure(message: "Headless fixture exited") }
            if let file = try? ChromeDebuggingEndpointFile.read(explicitlyApprovedUserDataDirectory: profile, consent: consent) { return file.endpoint }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message: "Headless endpoint readiness timed out")
    }

    private func command(_ connection: BrowserCDPConnection, _ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        let data = try await connection.command(method: method, params: JSONSerialization.data(withJSONObject: params), sessionID: session)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func targets(_ connection: BrowserCDPConnection) async throws -> [[String: Any]] {
        let result = try await command(connection, "Target.getTargets")
        return try XCTUnwrap(result["targetInfos"] as? [[String: Any]])
    }

    private func exactTarget(_ targets: [[String: Any]], url: URL) throws -> String {
        let matches = targets.filter { $0["type"] as? String == "page" && $0["url"] as? String == url.absoluteString }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first?["targetId"] as? String)
    }

    private func redactedTargets(_ targets: [[String: Any]], agentID: String, peerID: String) -> [[String: String]] {
        targets.map { target in
            let id = target["targetId"] as? String ?? "missing"
            let scheme = (target["url"] as? String).flatMap(URL.init(string:))?.scheme ?? "missing"
            let source: String
            switch scheme {
            case "chrome-extension": source = "extension"
            case "chrome", "chrome-untrusted", "devtools": source = "browser_internal"
            case "file": source = "local_file"
            case "about": source = "about"
            default: source = "other"
            }
            return ["id": id, "type": target["type"] as? String ?? "missing", "source_class": source,
                    "fixture_role": id == agentID ? "agent" : id == peerID ? "independent" : "none"]
        }.sorted { $0["id", default: ""] < $1["id", default: ""] }
    }

    private func attach(_ connection: BrowserCDPConnection, targetID: String) async throws -> String {
        let result = try await command(connection, "Target.attachToTarget", ["targetId": targetID, "flatten": true])
        return try XCTUnwrap(result["sessionId"] as? String)
    }

    private func evaluate(_ connection: BrowserCDPConnection, session: String, expression: String) async throws -> [String: Any] {
        let result = try await command(connection, "Runtime.evaluate", ["expression": expression, "returnByValue": true], session: session)
        guard result["exceptionDetails"] == nil else { throw Failure(message: "Fixture evaluation raised an exception") }
        let remote = try XCTUnwrap(result["result"] as? [String: Any])
        return try XCTUnwrap(remote["value"] as? [String: Any])
    }

    private func readState(_ connection: BrowserCDPConnection, session: String) async throws -> [String: Any] {
        try await evaluate(connection, session: session, expression: "({url:document.URL,count:document.querySelector('#count').textContent,value:document.querySelector('#value').value,echo:document.querySelector('#echo').textContent})")
    }

    private func waitForDocument(_ connection: BrowserCDPConnection, session: String, url: URL) async throws {
        for _ in 0..<200 {
            let state = try await evaluate(connection, session: session, expression: "({url:document.URL,ready:document.readyState,fixture:!!document.querySelector('#value')})")
            if state["url"] as? String == url.absoluteString, state["ready"] as? String == "complete", state["fixture"] as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "Exact fixture document did not become ready")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<3_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "Concurrent runtime fixture timed out")
    }

    private func waitForFile(_ file: String, in directory: URL, audit: RuntimeAudit) async throws {
        try await waitFor { FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) || audit.status == .completed || audit.status == .waiting }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
            throw Failure(message: "Core completed before fixture barrier \(file)")
        }
    }
}

@MainActor
private final class ConcurrentPeerClock {
    private(set) var tick = 0
    private(set) var isFinished = false
    func record(tick: Int) { self.tick = tick }
    func finish() { isFinished = true }
}

private final class ConcurrentBorrowedWireAudit: @unchecked Sendable {
    struct Row: Sendable { let method: String; let sessionID: String?; let targetID: String?; let time: UInt64 }
    private let lock = NSLock()
    private var recorded = [Row]()
    private var pendingAttachments = [Int: String]()
    private var attached = [String: String]()
    var rows: [Row] { lock.withLock { recorded } }
    var attachedSessions: [String: String] { lock.withLock { attached } }
    func record(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any]
        lock.withLock {
            recorded.append(Row(method: method, sessionID: object["sessionId"] as? String,
                targetID: params?["targetId"] as? String, time: DispatchTime.now().uptimeNanoseconds))
            if method == "Target.attachToTarget", let id = object["id"] as? Int, let target = params?["targetId"] as? String {
                pendingAttachments[id] = target
            }
        }
    }
    func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int, let result = object["result"] as? [String: Any],
              let session = result["sessionId"] as? String else { return }
        lock.withLock {
            if let target = pendingAttachments.removeValue(forKey: id) { attached[session] = target }
        }
    }
}

private final class ConcurrentBorrowedAuditWire: BrowserCDPWire, @unchecked Sendable {
    private let base: any BrowserCDPWire
    private let audit: ConcurrentBorrowedWireAudit
    init(base: any BrowserCDPWire, audit: ConcurrentBorrowedWireAudit) { self.base = base; self.audit = audit }
    func waitUntilOpen() async throws { try await base.waitUntilOpen() }
    func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        audit.record(data)
        base.enqueue(data, completion: completion)
    }
    func receive() async throws -> Data {
        let data = try await base.receive()
        audit.receive(data)
        return data
    }
    func close() { base.close() }
}

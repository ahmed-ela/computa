import AutomationCore
import Foundation
import XCTest
@testable import HeyDash

/// Actual production Core, turn tracking, tool validation, approval and routing
/// over an owned JSON-RPC fixture and inert borrowed adapter. No real Chrome,
/// model, filesystem permissions, desktop input or system settings are used.
@MainActor
final class BorrowedChromeRuntimeRoutingTests: XCTestCase {
    private let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"

    func testProductionToolLifecycleUsesBorrowedOwnerAndNeverGlobalInput() async throws {
        try await withHarness(mode: "full") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Inert borrowed browser workflow", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 14)
            XCTAssertEqual(rows.prefix(10).compactMap { $0["success"] as? Bool },
                           [true, true, true, true, false, true, true, true, true, true])
            XCTAssertEqual(rows.suffix(4).compactMap { $0["success"] as? Bool }, Array(repeating: false, count: 4))
            XCTAssertEqual(audit.approvals, 2, "Read-only inventory/attachment must not request desktop-action approval")
            let entry = try await connector.entry(request.id)
            try await self.waitForAsync { await entry.transport.counts().detaches == 1 }
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.attachIDs, ["target-1"])
            XCTAssertEqual(counts.presses, 1)
            XCTAssertEqual(counts.text, "HDé7 東京 👋")
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(counts.shutdowns, 0, "Turn completion detaches sessions but keeps the explicitly connected browser connection")
            let fresh = try await entry.owner.beginTurn(taskKey: "task", turnID: "after-completion")
            await entry.owner.revoke(turn: fresh)
            let specs = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("specs.json"))) as? [[String: Any]]
            XCTAssertTrue(specs?.contains { $0["name"] as? String == "computer_v2_tabs" } == true)
            XCTAssertTrue(specs?.contains { $0["name"] as? String == "computer_v2_bind_tab" } == true)
        }
    }

    func testToolsWithoutNativeConnectionFailWithoutCallingConnector() async throws {
        try await withHarness(mode: "no-connection") { runtime, root, audit, connector in
            try await runtime.submit(prompt: "List tabs without consent", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["success"] as? Bool, false)
            let diagnostic = try XCTUnwrap(rows.first?["text"] as? String)
            XCTAssertTrue(diagnostic.contains("not evidence that macOS computer-use permission was denied"))
            XCTAssertTrue(diagnostic.contains("Do not retry computer_v2_tabs"))
            XCTAssertTrue(diagnostic.contains("Connect Chrome menu"))
            let calls = await connector.count
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(audit.approvals, 0)
        }
    }

    func testUnsupportedBrowserCapabilitiesFailBeforeApprovalAndPreserveSnapshotForSupportedAction() async throws {
        try await withHarness(mode: "unsupported-actions") { runtime, root, audit, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Check capability admission without extra approvals", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { audit.status == .completed || audit.status == .waiting }
            XCTAssertEqual(audit.status, .completed)
            let rows = try self.results(root)
            XCTAssertEqual(rows.count, 13)
            guard rows.count == 13 else { return }
            XCTAssertEqual(rows[3...8].compactMap { $0["success"] as? Bool }, Array(repeating: false, count: 6))
            XCTAssertTrue(rows[3...8].allSatisfy { ($0["text"] as? String)?.contains("No approval or action was requested") == true })
            XCTAssertTrue((rows[3]["text"] as? String)?.contains("computer_v2_set_text directly") == true)
            XCTAssertEqual(audit.approvals, 2, "Only the supported text entry and button press require approval; six rejected requests never ask.")
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.presses, 1)
            XCTAssertEqual(counts.text, "Supported direct text")
            XCTAssertEqual(counts.forbidden, 0)
        }
    }

    func testInterruptRevokesInventoryOnlyTurnWithoutClosingUserResources() async throws {
        try await withHarness(mode: "inventory-hold") { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold after listing", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            try await runtime.interrupt(taskID: "task")
            let entry = try await connector.entry(request.id)
            let fresh = try await entry.owner.beginTurn(taskKey: "task", turnID: "after-interrupt")
            await entry.owner.revoke(turn: fresh)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.attachIDs, [])
            XCTAssertEqual(counts.detaches, 0)
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(counts.shutdowns, 0)
        }
    }

    func testActiveTurnCannotGrantOrReplaceNativeConnection() async throws {
        try await withHarness(mode: "inventory-hold") { runtime, root, _, connector in
            let first = self.request()
            try await runtime.connectChrome(first)
            try await runtime.submit(prompt: "Hold after listing", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            let denied = self.request()
            do { try await runtime.connectChrome(denied); XCTFail("A model-active runtime cannot grant a native connection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("idle")) }
            XCTAssertThrowsError(try denied.consent.check())
            XCTAssertNoThrow(try first.consent.check())
            let count = await connector.count
            XCTAssertEqual(count, 1)
            try await runtime.interrupt(taskID: "task")
        }
    }

    func testPendingNativeHandshakeBlocksTurnAndCompactionAdmission() async throws {
        try await withHarness(mode: "full") { runtime, _, _, connector in
            let request = self.request(), gate = BorrowedRuntimeConnectGate()
            await connector.holdNext(gate)
            let connection = Task { try await runtime.connectChrome(request) }
            await gate.waitForArrival()
            do {
                try await runtime.submit(prompt: "Must not start", toTaskID: "task", modelID: self.modelID)
                XCTFail("Prompt admission must wait for native connection")
            } catch { XCTAssertTrue(error.localizedDescription.contains("native Chrome connection")) }
            do { try await runtime.compact(taskID: "task"); XCTFail("Compaction must not start") }
            catch { XCTAssertTrue(error.localizedDescription.contains("native Chrome connection")) }
            connection.cancel()
            XCTAssertThrowsError(try request.consent.check())
            await gate.release()
            do { try await connection.value; XCTFail("Cancelled connection cannot publish") }
            catch { XCTAssertTrue(error is CancellationError) }
            let entry = try await connector.entry(request.id)
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.shutdowns, 1)
        }
    }

    func testLateCancelledConnectionCannotCloseReplacementConnection() async throws {
        try await withHarness(mode: "full") { runtime, _, audit, connector in
            let old = self.request(), fresh = self.request(), gate = BorrowedRuntimeConnectGate()
            await connector.holdNext(gate)
            let first = Task { try await runtime.connectChrome(old) }
            await gate.waitForArrival()
            let second = Task { try await runtime.connectChrome(fresh) }
            try await self.waitFor { audit.chrome.contains { $0.0 == fresh.id && $0.1 == .connecting } }
            XCTAssertThrowsError(try old.consent.check())
            await gate.release()
            do { try await first.value; XCTFail("Old connection result cannot publish") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await second.value
            let oldEntry = try await connector.entry(old.id), freshEntry = try await connector.entry(fresh.id)
            XCTAssertNoThrow(try fresh.consent.check())
            let oldCounts = await oldEntry.transport.counts(), freshCounts = await freshEntry.transport.counts()
            XCTAssertEqual(oldCounts.shutdowns, 1)
            XCTAssertEqual(freshCounts.shutdowns, 0)
            try await self.waitFor { audit.chrome.contains { $0.0 == fresh.id && $0.1 == .connected } }
            XCTAssertFalse(audit.chrome.contains { $0.0 == old.id && $0.1 == .connected })
        }
    }

    func testDisconnectIsAvailableDuringActiveTurnAndRevokesExactOwner() async throws {
        try await withHarness(mode: "inventory-hold") { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold after listing", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            await runtime.disconnectChrome()
            XCTAssertThrowsError(try request.consent.check())
            let entry = try await connector.entry(request.id)
            do { _ = try await entry.owner.beginTurn(taskKey: "task", turnID: "new"); XCTFail("Owner must be disconnected") }
            catch { XCTAssertEqual(error as? BorrowedChromeSessionOwnerError, .disconnected) }
            let counts = await entry.transport.counts()
            XCTAssertEqual(counts.shutdowns, 1)
            XCTAssertEqual(counts.forbidden, 0)
            try await runtime.interrupt(taskID: "task")
        }
    }

    func testConnectionErrorsAreRedactedBeforeEventsAndThrownMessage() async throws {
        try await withHarness(mode: "full") { runtime, _, audit, connector in
            await connector.failNext()
            let request = self.request()
            do { try await runtime.connectChrome(request); XCTFail("Must fail") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains("secret-endpoint"))
                XCTAssertFalse(error.localizedDescription.contains("private-profile"))
            }
            try await self.waitFor { audit.chrome.contains { id, state in
                if case .failed = state { return id == request.id }; return false
            } }
            for (_, state) in audit.chrome {
                if case .failed(let message) = state {
                    XCTAssertFalse(message.contains("secret-endpoint"))
                    XCTAssertFalse(message.contains("private-profile"))
                }
            }
            XCTAssertThrowsError(try request.consent.check())
        }
    }

    func testBorrowedDisconnectPreservesCoexistingOwnedBindingUntilInterrupt() async throws {
        let owned = try await BorrowedRuntimeOwnedFixture.make()
        try await withHarness(mode: "inventory-hold", browserBroker: owned.broker) { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold inventory beside owned binding", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            try await runtime.installOwnedBrowserBindingForFixture(taskID: "task", binding: owned.binding)
            await runtime.disconnectChrome()
            XCTAssertNoThrow(try owned.binding.lifetime.check())
            let before = await owned.transport.closedTargets
            XCTAssertEqual(before, [])
            try await runtime.interrupt(taskID: "task")
            XCTAssertThrowsError(try owned.binding.lifetime.check())
            let after = await owned.transport.closedTargets
            XCTAssertEqual(after, [owned.binding.targetID])
            let borrowed = try await connector.entry(request.id)
            let counts = await borrowed.transport.counts()
            XCTAssertEqual(counts.shutdowns, 1)
            XCTAssertEqual(counts.forbidden, 0)
        }
    }

    func testInterruptCleansBorrowedInventoryAndIndependentOwnedBinding() async throws {
        let owned = try await BorrowedRuntimeOwnedFixture.make()
        try await withHarness(mode: "inventory-hold", browserBroker: owned.broker) { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Hold inventory beside owned binding", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            try await runtime.installOwnedBrowserBindingForFixture(taskID: "task", binding: owned.binding)
            try await runtime.interrupt(taskID: "task")
            XCTAssertThrowsError(try owned.binding.lifetime.check())
            let closed = await owned.transport.closedTargets
            XCTAssertEqual(closed, [owned.binding.targetID])
            let borrowed = try await connector.entry(request.id)
            let fresh = try await borrowed.owner.beginTurn(taskKey: "task", turnID: "after-both-cleaned")
            await borrowed.owner.revoke(turn: fresh)
            let counts = await borrowed.transport.counts()
            XCTAssertEqual(counts.forbidden, 0)
            XCTAssertEqual(counts.shutdowns, 0)
        }
    }

    func testUnknownCandidatePreservesCoexistingOwnedBindingAndSnapshot() async throws {
        let owned = try await BorrowedRuntimeOwnedFixture.make()
        try await withHarness(mode: "invalid-owned-hold", browserBroker: owned.broker) { runtime, root, _, connector in
            let request = self.request()
            try await runtime.connectChrome(request)
            try await runtime.submit(prompt: "Reject an unobserved candidate", toTaskID: "task", modelID: self.modelID)
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("inventory-ready").path) }
            try await runtime.installOwnedBrowserBindingForFixture(taskID: "task", binding: owned.binding)
            let before = try await runtime.browserStateForFixture(taskID: "task")
            XCTAssertNotNil(before.1)
            try Data("ready".utf8).write(to: root.appendingPathComponent("try-invalid-token"))
            try await self.waitFor { FileManager.default.fileExists(atPath: root.appendingPathComponent("invalid-token-result.json").path) }
            let after = try await runtime.browserStateForFixture(taskID: "task")
            XCTAssertEqual(before.0, after.0)
            XCTAssertEqual(before.1, after.1)
            XCTAssertNoThrow(try owned.binding.lifetime.check())
            let closed = await owned.transport.closedTargets
            XCTAssertEqual(closed, [])
            let borrowed = try await connector.entry(request.id)
            let counts = await borrowed.transport.counts()
            XCTAssertEqual(counts.attachIDs, [])
            XCTAssertEqual(counts.forbidden, 0)
            try await runtime.interrupt(taskID: "task")
        }
    }

    private final class Audit {
        var status: TaskStatus?
        var approvals = 0
        var chrome = [(UUID, ChromeConnectionState)]()
    }

    private struct NoModelGrounder: VisualGroundingClient {
        func prepare() async throws { }
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw NSError(domain: "NoGrounderInBorrowedFixture", code: 1)
        }
        func shutdown() async -> [String] { [] }
    }

    private func request() -> ChromeConnectionRequest {
        ChromeConnectionRequest(
            application: .init(processIdentifier: 4242, bundleIdentifier: "com.google.Chrome",
                               executableURL: URL(fileURLWithPath: "/fixture/Google Chrome")),
            userDataDirectory: URL(fileURLWithPath: "/fixture/private-profile"),
            consent: ChromeDebuggingConsent(approvedByUser: true)
        )
    }

    private func results(_ root: URL) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results.json"))) as? [[String: Any]])
    }

    private func withHarness(
        mode: String,
        browserBroker: ChromeTabBroker = ChromeTabBroker(),
        body: (CodexAppServerRuntime, URL, Audit, BorrowedRuntimeConnector) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeyDashBorrowedRuntime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BorrowedChromeRuntimeAppServer.ts")
        let executable = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.executable = .fixture(path: executable.path)
        config.codexHomePath = root.path
        let connector = BorrowedRuntimeConnector()
        let runtime = CodexAppServerRuntime(configuration: config, browserBroker: browserBroker, visualGrounder: NoModelGrounder(),
                                           borrowedChromeConnector: { try await connector.connect($0) })
        let audit = Audit()
        let events = Task {
            for await event in runtime.events() {
                switch event {
                case .taskStatusChanged(_, let status): audit.status = status
                case .chromeConnectionChanged(let id, let state): audit.chrome.append((id, state))
                case .approvalRequested(let request):
                    audit.approvals += 1
                    try? await runtime.resolveApproval(requestID: request.id, approved: true)
                default: break
                }
            }
        }
        do {
            _ = try await runtime.loadTasks()
            try await body(runtime, root, audit, connector)
            let report = await runtime.shutdown()
            events.cancel()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        } catch {
            _ = await runtime.shutdown()
            events.cancel()
            throw error
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Borrowed runtime fixture timed out", code: 1)
    }

    private func waitForAsync(_ condition: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Borrowed cleanup fixture timed out", code: 1)
    }
}

private struct BorrowedRuntimeOwnedFixture: Sendable {
    let broker: ChromeTabBroker
    let binding: BrowserTabBinding
    let transport: BorrowedRuntimeOwnedTransport

    static func make() async throws -> Self {
        let generation = UUID(), transport = BorrowedRuntimeOwnedTransport()
        let sessions = BrowserTabSessionBroker(transport: transport, browserGeneration: generation, ownership: .owned)
        let binding = try await sessions.open(taskKey: "task", processIdentifier: 5555,
                                             url: URL(string: "https://example.com/inert-owned")!)
        let initial = ChromeTabBroker.BrowserProcess(
            process: BorrowedRuntimeOwnedChild(), dataDirectory: URL(fileURLWithPath: "/not-created/borrowed-runtime-owned-fixture"),
            generation: generation, transport: SystemChromeDevToolsTransport(port: 1), sessions: sessions
        )
        return Self(broker: ChromeTabBroker(initialBrowser: initial, removeProfile: { _ in nil }),
                    binding: binding, transport: transport)
    }
}

private struct BorrowedRuntimeOwnedChild: BrowserOwnedChild {
    let processIdentifier: Int32 = 5555
    let isRunning = true
    func stop() async -> OwnedChildProcess.StopResult { .init(rootReaped: true, groupGone: true, issues: []) }
}

private actor BorrowedRuntimeOwnedTransport: BrowserTabTransport {
    private var target: BrowserTarget?
    private(set) var closedTargets = [String]()
    func createTarget(url: URL) -> BrowserTarget {
        let created = BrowserTarget(targetID: "owned-inert-target", instanceToken: UUID().uuidString,
                                    title: "Owned inert fixture", url: url, webSocketURL: nil)
        target = created
        return created
    }
    func target(id: String) -> BrowserTarget? { target?.targetID == id ? target : nil }
    func activateTarget(id: String) { }
    func closeTarget(target: BrowserTarget) throws {
        guard self.target == target else { throw BrowserTabBrokerError.targetReplaced }
        closedTargets.append(target.targetID)
        self.target = nil
    }
    func observe(target: BrowserTarget) -> BrowserDocumentObservation {
        .init(loaderID: "owned-loader", title: target.title, url: target.url, nodes: [])
    }
    func press(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
               permit: BrowserMutationPermit) throws { throw BrowserTabBrokerError.unsupportedAction("inert owned press") }
    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
                 permit: BrowserMutationPermit) throws { throw BrowserTabBrokerError.unsupportedAction("inert owned text") }
}

private actor BorrowedRuntimeConnectGate {
    private var arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func pause() async {
        arrived = true
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}

private actor BorrowedRuntimeConnector {
    struct Entry: Sendable {
        let owner: BorrowedChromeSessionOwner
        let transport: BorrowedRuntimeTransport
    }
    private(set) var count = 0
    private var entries = [UUID: Entry]()
    private var gate: BorrowedRuntimeConnectGate?
    private var shouldFail = false
    func holdNext(_ gate: BorrowedRuntimeConnectGate) { self.gate = gate }
    func failNext() { shouldFail = true }
    func connect(_ request: ChromeConnectionRequest) async throws -> BorrowedChromeSessionOwner {
        count += 1
        if shouldFail {
            shouldFail = false
            throw NSError(domain: "private-profile secret-endpoint", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ws://secret-endpoint /private-profile"])
        }
        let transport = BorrowedRuntimeTransport(consent: request.consent)
        let owner = try BorrowedChromeSessionOwner(application: request.application, transport: transport,
            consent: request.consent, verifyIdentity: { try request.consent.check() })
        entries[request.id] = Entry(owner: owner, transport: transport)
        let pendingGate = gate
        gate = nil
        await pendingGate?.pause()
        // Deliberately return late even if cancelled, to exercise ownership
        // cleanup of an already-created exact connection.
        return owner
    }
    func entry(_ id: UUID) throws -> Entry {
        guard let value = entries[id] else { throw NSError(domain: "Missing inert connection", code: 1) }
        return value
    }
}

private actor BorrowedRuntimeTransport: BorrowedChromeSessionTransport {
    struct Counts: Sendable {
        let attachIDs: [String]
        let detaches: Int
        let shutdowns: Int
        let presses: Int
        let forbidden: Int
        let text: String
    }
    nonisolated let generation = UUID()
    private let consent: ChromeDebuggingConsent
    private var targets = [String: BrowserTarget]()
    private var attachIDs = [String]()
    private var detaches = 0, shutdowns = 0, presses = 0, forbidden = 0
    private var text = "", closed = false
    private let url = URL(string: "https://example.com/inert")!
    init(consent: ChromeDebuggingConsent) { self.consent = consent }
    func counts() -> Counts {
        Counts(attachIDs: attachIDs, detaches: detaches, shutdowns: shutdowns,
               presses: presses, forbidden: forbidden, text: text)
    }
    func validateConnection() throws {
        try consent.check()
        if closed { throw BrowserTabBrokerError.browserGenerationChanged }
    }
    func listCandidates() throws -> [BorrowedChromeTabCandidate] {
        try validateConnection()
        return (0..<2).map { .init(targetID: "target-\($0)", title: "Identical fixture tabs", url: url) }
    }
    func attach(targetID: String) throws -> BrowserTarget {
        try validateConnection()
        guard ["target-0", "target-1"].contains(targetID) else { throw BrowserTabBrokerError.targetClosed }
        if let existing = targets[targetID] { return existing }
        let target = BrowserTarget(targetID: targetID, title: "Fixture", url: url,
            attachedSession: .init(connectionGeneration: generation, sessionID: UUID().uuidString, incarnation: UUID()))
        targets[targetID] = target
        attachIDs.append(targetID)
        return target
    }
    func target(id: String) throws -> BrowserTarget? { try validateConnection(); return targets[id] }
    func observe(target: BrowserTarget) throws -> BrowserDocumentObservation {
        try validateConnection()
        return BrowserDocumentObservation(loaderID: "inert-loader", title: "Fixture", url: url, nodes: [
            .init(backendNodeID: 1, role: "button", name: "Increment", value: nil, isDisabled: false, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 2, role: "textbox", name: "Text", value: text, isDisabled: false, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 3, role: "StaticText", name: "Count", value: String(presses), isDisabled: false, isReadOnly: true, isIgnored: false),
            .init(backendNodeID: 4, role: "button", name: "Disabled button", value: nil, isDisabled: true, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 5, role: "textbox", name: "Disabled text", value: "", isDisabled: true, isReadOnly: false, isIgnored: false),
            .init(backendNodeID: 6, role: "textbox", name: "Read only text", value: "", isDisabled: false, isReadOnly: true, isIgnored: false)
        ])
    }
    func press(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation,
               permit: BrowserMutationPermit) throws {
        try validateConnection()
        try permit.commit { presses += 1 }
    }
    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation,
                 permit: BrowserMutationPermit) throws {
        try validateConnection()
        try permit.commit { self.text = text }
    }
    func detach(target: BrowserTarget) throws {
        try validateConnection()
        guard targets[target.targetID]?.attachedSession == target.attachedSession else { throw BrowserTabBrokerError.targetReplaced }
        targets.removeValue(forKey: target.targetID)
        detaches += 1
    }
    func shutdown() { closed = true; shutdowns += 1; targets.removeAll() }
    func createTarget(url: URL) throws -> BrowserTarget { forbidden += 1; throw BrowserTabBrokerError.ownershipMismatch }
    func activateTarget(id: String) throws { forbidden += 1; throw BrowserTabBrokerError.ownershipMismatch }
    func closeTarget(target: BrowserTarget) throws { forbidden += 1; throw BrowserTabBrokerError.ownershipMismatch }
}

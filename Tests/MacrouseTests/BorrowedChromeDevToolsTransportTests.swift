import Foundation
import XCTest
@testable import Macrouse

/// Only an in-memory CDP peer. No endpoint discovery, Chrome, permissions or UI.
final class BorrowedChromeDevToolsTransportTests: XCTestCase {
    func testExactTargetAttachAndDocumentCommandsCarrySessionIdentity() async throws {
        let fixture = BorrowedTransportFixture()
        let candidates = try await fixture.transport.listCandidates()
        XCTAssertEqual(candidates.map(\.targetID), ["tab-a", "tab-b"])
        let target = try await fixture.transport.attach(targetID: "tab-b")
        XCTAssertEqual(target.targetID, "tab-b")
        XCTAssertNil(target.webSocketURL)
        let identity = try XCTUnwrap(target.attachedSession)
        XCTAssertEqual(identity.connectionGeneration, fixture.generation)
        let document = try await fixture.transport.observe(target: target)
        XCTAssertEqual(document.loaderID, "loader-1")
        XCTAssertEqual(document.nodes.first?.backendNodeID, 42)
        let requests = fixture.wire.requests
        let attaches = requests.filter { $0.method == "Target.attachToTarget" }
        XCTAssertEqual(attaches.count, 1)
        XCTAssertEqual(try attaches.first?.parameters()["targetId"] as? String, "tab-b")
        XCTAssertEqual(try attaches.first?.parameters()["flatten"] as? Bool, true)
        XCTAssertNil(attaches.first?.sessionID)
        let pageRequests = requests.filter { !$0.method.hasPrefix("Target.") }
        XCTAssertFalse(pageRequests.isEmpty)
        XCTAssertTrue(pageRequests.allSatisfy { $0.sessionID == identity.sessionID })
        await fixture.transport.shutdown()
    }

    func testSameURLTabsRemainDistinctAndNeverResolveByTitleOrURL() async throws {
        let fixture = BorrowedTransportFixture()
        let candidates = try await fixture.transport.listCandidates()
        XCTAssertEqual(candidates[0].url, candidates[1].url)
        XCTAssertEqual(candidates[0].title, candidates[1].title)
        let one = try await fixture.transport.attach(targetID: "tab-a")
        let two = try await fixture.transport.attach(targetID: "tab-b")
        XCTAssertNotEqual(one.attachedSession, two.attachedSession)
        XCTAssertNotEqual(one.instanceToken, two.instanceToken)
        try await fixture.transport.detach(target: one)
        let stillBound = try await fixture.transport.target(id: "tab-b")
        XCTAssertEqual(stillBound?.attachedSession, two.attachedSession)
        XCTAssertEqual(fixture.wire.targets, Set(["tab-a", "tab-b"]))
        XCTAssertFalse(fixture.wire.requests.contains { $0.method == "Target.closeTarget" })
        await fixture.transport.shutdown()
    }

    func testReusedSessionIDForDifferentTargetDisconnectsWithoutMutation() async throws {
        let fixture = BorrowedTransportFixture()
        fixture.wire.reuseSessionIdentity = true
        _ = try await fixture.transport.attach(targetID: "tab-a")
        do { _ = try await fixture.transport.attach(targetID: "tab-b"); XCTFail("A session cannot change target identity.") }
        catch let error as BrowserCDPConnectionError { XCTAssertEqual(error, .sessionMismatch) }
        XCTAssertEqual(fixture.wire.closeCount, 1)
        XCTAssertEqual(fixture.wire.targets.count, 2)
        XCTAssertEqual(fixture.wire.requests.filter { $0.method == "Target.attachToTarget" }.count, 2)
        XCTAssertFalse(fixture.wire.requests.contains { $0.method == "Runtime.callFunctionOn" })
        await fixture.transport.shutdown()
    }

    func testCreationActivationAndCloseAreForbiddenWithoutWireRequests() async throws {
        let fixture = BorrowedTransportFixture()
        let target = try await fixture.transport.attach(targetID: "tab-a")
        let before = fixture.wire.requests.count
        await expectBrokerError(.ownershipMismatch) { _ = try await fixture.transport.createTarget(url: target.url) }
        await expectBrokerError(.ownershipMismatch) { try await fixture.transport.activateTarget(id: target.targetID) }
        await expectBrokerError(.ownershipMismatch) { try await fixture.transport.closeTarget(target: target) }
        XCTAssertEqual(fixture.wire.requests.count, before)
        await fixture.transport.shutdown()
        XCTAssertFalse(fixture.wire.requests.contains {
            ["Target.createTarget", "Target.activateTarget", "Target.closeTarget", "Browser.close"].contains($0.method)
        })
        XCTAssertEqual(fixture.wire.targets.count, 2)
    }

    func testDetachAndShutdownDoNotCloseTabsOrStopBrowser() async throws {
        let fixture = BorrowedTransportFixture()
        let target = try await fixture.transport.attach(targetID: "tab-a")
        try await fixture.transport.detach(target: target)
        let detached = try await fixture.transport.target(id: "tab-a")
        XCTAssertNil(detached)
        let commands = fixture.wire.requests.filter { $0.method == "Target.detachFromTarget" }
        XCTAssertEqual(commands.count, 1)
        XCTAssertNil(commands[0].sessionID)
        XCTAssertEqual(try commands[0].parameters()["sessionId"] as? String, target.attachedSession?.sessionID)
        await fixture.transport.shutdown()
        await fixture.transport.shutdown()
        XCTAssertEqual(fixture.wire.closeCount, 1)
        XCTAssertEqual(fixture.wire.targets, Set(["tab-a", "tab-b"]))
    }

    func testPreCancelledDetachStillCleansExactSessionInUncancelledTask() async throws {
        let fixture = BorrowedTransportFixture()
        let target = try await fixture.transport.attach(targetID: "tab-a")
        let detachment = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.transport.detach(target: target)
        }
        // Either propagation of the caller's cancellation or successful cleanup
        // is acceptable, but cancellation must not skip remote cleanup.
        do { try await detachment.value } catch is CancellationError { }
        let detaches = fixture.wire.requests.filter { $0.method == "Target.detachFromTarget" }
        XCTAssertEqual(detaches.count, 1)
        let detach = try XCTUnwrap(detaches.first)
        XCTAssertEqual(try detach.parameters()["sessionId"] as? String, target.attachedSession?.sessionID)
        XCTAssertNil(detach.sessionID)
        XCTAssertFalse(detach.wasCancelled)
        XCTAssertEqual(fixture.wire.closeCount, 0, "Confirmed cleanup need not disrupt other target sessions.")
        let removed = try await fixture.transport.target(id: "tab-a")
        XCTAssertNil(removed)
        assertNoUserResourceMutation(fixture)
        await fixture.transport.shutdown()
    }

    func testRejectedDetachClosesConnectionWithoutClosingUserTargets() async throws {
        let fixture = BorrowedTransportFixture()
        let target = try await fixture.transport.attach(targetID: "tab-a")
        _ = try await fixture.transport.attach(targetID: "tab-b")
        fixture.wire.failDetach = true
        do {
            try await fixture.transport.detach(target: target)
            XCTFail("An unconfirmed remote detach must not retain the connection.")
        } catch let error as BrowserCDPConnectionError {
            XCTAssertEqual(error, .commandRejected(-32_001))
        }
        let detaches = fixture.wire.requests.filter { $0.method == "Target.detachFromTarget" }
        XCTAssertEqual(detaches.count, 1)
        XCTAssertEqual(try detaches.first?.parameters()["sessionId"] as? String, target.attachedSession?.sessionID)
        XCTAssertEqual(fixture.wire.closeCount, 1)
        let count = fixture.wire.requests.count
        do { _ = try await fixture.transport.target(id: "tab-b"); XCTFail("The abandoned connection must not retain authority.") }
        catch { }
        XCTAssertEqual(fixture.wire.requests.count, count)
        assertNoUserResourceMutation(fixture)
        await fixture.transport.shutdown()
        XCTAssertEqual(fixture.wire.closeCount, 1)
    }

    func testReconnectWithSameTargetAndSessionStringsRejectsOldIdentity() async throws {
        let first = BorrowedTransportFixture()
        let stale = try await first.transport.attach(targetID: "tab-a")
        await first.transport.shutdown()
        let second = BorrowedTransportFixture()
        let fresh = try await second.transport.attach(targetID: "tab-a")
        XCTAssertEqual(stale.targetID, fresh.targetID)
        XCTAssertEqual(stale.attachedSession?.sessionID, fresh.attachedSession?.sessionID)
        XCTAssertNotEqual(stale.attachedSession?.connectionGeneration, fresh.attachedSession?.connectionGeneration)
        XCTAssertNotEqual(stale.instanceToken, fresh.instanceToken)
        let before = second.wire.requests.count
        await expectBrokerError(.targetReplaced) { _ = try await second.transport.observe(target: stale) }
        await expectBrokerError(.targetReplaced) { try await second.transport.detach(target: stale) }
        XCTAssertEqual(second.wire.requests.count, before)
        _ = try await second.transport.observe(target: fresh)
        await second.transport.shutdown()
    }

    func testDetachDuringObservationRejectsWithoutPublishingOrReattachment() async throws {
        let fixture = BorrowedTransportFixture()
        let target = try await fixture.transport.attach(targetID: "tab-a")
        fixture.wire.detachBeforeReply(to: "Accessibility.getFullAXTree")
        do { _ = try await fixture.transport.observe(target: target); XCTFail("Detached observation must not publish.") }
        catch let error as BrowserCDPConnectionError { XCTAssertEqual(error, .sessionInvalidated) }
        let before = fixture.wire.requests.count
        do { _ = try await fixture.transport.observe(target: target); XCTFail("Detached identity must stay revoked.") }
        catch let error as BrowserCDPConnectionError { XCTAssertEqual(error, .sessionInvalidated) }
        XCTAssertEqual(fixture.wire.requests.count, before)
        XCTAssertEqual(fixture.wire.requests.filter { $0.method == "Target.attachToTarget" }.count, 1)
        await fixture.transport.shutdown()
    }

    func testProcessValidationRefusesAtActualConnectionEnqueueBoundary() async throws {
        let fixture = BorrowedTransportFixture()
        // listCandidates checks once locally, then once at the wire boundary.
        fixture.verifier.failBrowserCheck(number: 2)
        do { _ = try await fixture.transport.listCandidates(); XCTFail("Changed process must not receive a request.") }
        catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .browserGenerationChanged) }
        XCTAssertEqual(fixture.verifier.browserChecks, 2)
        XCTAssertTrue(fixture.wire.requests.isEmpty)
        await fixture.transport.shutdown()
    }

    func testPermissionRevokedDuringTargetLookupPreventsAttachment() async throws {
        let fixture = BorrowedTransportFixture()
        fixture.wire.onEnqueue(method: "Target.getTargetInfo") { fixture.verifier.revokePermission() }
        do { _ = try await fixture.transport.attach(targetID: "tab-a"); XCTFail("Attach must recheck permission after the lookup await.") }
        catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .mutationRejected("synthetic permission revoked")) }
        XCTAssertFalse(fixture.wire.requests.contains { $0.method == "Target.attachToTarget" })
        await fixture.transport.shutdown()
    }

    func testMutationCleanupUsesOriginalSessionAndDoesNotReplayOnReleaseFailure() async throws {
        let fixture = BorrowedTransportFixture()
        let target = try await fixture.transport.attach(targetID: "tab-a")
        let document = try await fixture.transport.observe(target: target)
        fixture.wire.failGroupRelease = true
        do {
            try await fixture.transport.press(target: target, backendNodeID: 42, document: document, permit: BrowserMutationPermit())
            XCTFail("Failed cleanup cannot be silently reported as success.")
        } catch let error as BrowserCDPConnectionError { XCTAssertEqual(error, .commandRejected(-32_000)) }
        let requests = fixture.wire.requests
        let mutations = requests.filter { $0.method == "Runtime.callFunctionOn" }
        let releases = requests.filter { $0.method == "Runtime.releaseObjectGroup" }
        let detaches = requests.filter { $0.method == "Target.detachFromTarget" }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.sessionID, target.attachedSession?.sessionID)
        XCTAssertEqual(detaches.count, 1)
        XCTAssertEqual(try detaches.first?.parameters()["sessionId"] as? String, target.attachedSession?.sessionID)
        XCTAssertEqual(requests.filter { $0.method == "Target.attachToTarget" }.count, 1)
        let before = requests.count
        do { _ = try await fixture.transport.observe(target: target); XCTFail("Cleanup failure invalidates original session.") }
        catch let error as BrowserCDPConnectionError { XCTAssertEqual(error, .sessionInvalidated) }
        XCTAssertEqual(fixture.wire.requests.count, before)
        await fixture.transport.shutdown()
    }

    func testGroupReleaseAndDetachRejectionClosesOriginalConnectionWithoutReplay() async throws {
        let fixture = BorrowedTransportFixture()
        let target = try await fixture.transport.attach(targetID: "tab-a")
        let document = try await fixture.transport.observe(target: target)
        fixture.wire.failGroupRelease = true
        fixture.wire.failDetach = true
        do {
            try await fixture.transport.press(target: target, backendNodeID: 42, document: document, permit: BrowserMutationPermit())
            XCTFail("Failed group release and detach must abandon the original connection.")
        } catch let error as BrowserCDPConnectionError {
            XCTAssertEqual(error, .commandRejected(-32_000), "Retain the original release error.")
        }
        let requests = fixture.wire.requests
        XCTAssertEqual(requests.filter { $0.method == "Runtime.callFunctionOn" }.count, 1)
        let releases = requests.filter { $0.method == "Runtime.releaseObjectGroup" }
        let detaches = requests.filter { $0.method == "Target.detachFromTarget" }
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.sessionID, target.attachedSession?.sessionID)
        XCTAssertEqual(detaches.count, 1)
        XCTAssertEqual(try detaches.first?.parameters()["sessionId"] as? String, target.attachedSession?.sessionID)
        XCTAssertEqual(detaches.first?.wasCancelled, false)
        XCTAssertEqual(requests.filter { $0.method == "Target.attachToTarget" }.count, 1)
        XCTAssertEqual(fixture.wire.closeCount, 1)
        do { _ = try await fixture.transport.observe(target: target); XCTFail("Abandoned connection must not be reused.") }
        catch { }
        XCTAssertEqual(fixture.wire.requests.count, requests.count)
        assertNoUserResourceMutation(fixture)
        await fixture.transport.shutdown()
        XCTAssertEqual(fixture.wire.closeCount, 1)
    }

    func testCancellationAfterMutationEnqueueCleansOriginalGroupWithoutReplay() async throws {
        let fixture = BorrowedTransportFixture()
        let target = try await fixture.transport.attach(targetID: "tab-a")
        let document = try await fixture.transport.observe(target: target)
        fixture.wire.holdMutationReply = true
        let action = Task {
            try await fixture.transport.press(target: target, backendNodeID: 42, document: document, permit: BrowserMutationPermit())
        }
        await fixture.wire.waitFor(method: "Runtime.callFunctionOn")
        action.cancel()
        do { try await action.value; XCTFail("Expected cancellation.") } catch is CancellationError { }
        let requests = fixture.wire.requests
        XCTAssertEqual(requests.filter { $0.method == "Runtime.callFunctionOn" }.count, 1)
        let release = try XCTUnwrap(requests.first { $0.method == "Runtime.releaseObjectGroup" })
        XCTAssertEqual(release.sessionID, target.attachedSession?.sessionID)
        XCTAssertEqual(requests.filter { $0.method == "Target.attachToTarget" }.count, 1)
        XCTAssertEqual(fixture.wire.targets.count, 2)
        await fixture.transport.shutdown()
    }

    func testAttachmentTimeoutIdentifiesUnansweredCommandWithoutReplayOrTabMutation() async throws {
        let phases: [(String, BorrowedChromeCommandTimeout.Stage)] = [
            ("Target.getTargetInfo", .targetValidation),
            ("Target.attachToTarget", .attachment),
        ]
        for (method, stage) in phases {
            let fixture = BorrowedTransportFixture(requestTimeout: .milliseconds(100))
            fixture.wire.holdReply(to: method)
            do {
                _ = try await fixture.transport.attach(targetID: "tab-a")
                XCTFail("An unanswered command must not publish a binding.")
            } catch let error as BorrowedChromeCommandTimeout {
                XCTAssertEqual(error, BorrowedChromeCommandTimeout(stage: stage, method: method))
                assertTimeoutContainsOnlyOperationMetadata(error)
            }
            XCTAssertEqual(fixture.wire.requests.filter { $0.method == method }.count, 1)
            XCTAssertEqual(fixture.wire.closeCount, 1)
            let count = fixture.wire.requests.count
            do { _ = try await fixture.transport.attach(targetID: "tab-a"); XCTFail("A timed-out connection cannot replay attachment.") }
            catch { }
            XCTAssertEqual(fixture.wire.requests.count, count)
            assertNoUserResourceMutation(fixture)
            await fixture.transport.shutdown()
        }
    }

    func testObservationTimeoutNamesEachPossibleBindObservationCommand() async throws {
        // bindBorrowed includes this initial observation. A tool-level bind
        // timeout alone cannot distinguish attachment from these commands.
        for method in ["Page.getFrameTree", "Accessibility.enable", "Accessibility.getFullAXTree"] {
            let fixture = BorrowedTransportFixture(requestTimeout: .milliseconds(100))
            let target = try await fixture.transport.attach(targetID: "tab-a")
            fixture.wire.holdReply(to: method)
            do {
                _ = try await fixture.transport.observe(target: target)
                XCTFail("An unanswered observation must not be published.")
            } catch let error as BorrowedChromeCommandTimeout {
                XCTAssertEqual(error, BorrowedChromeCommandTimeout(stage: .documentObservation, method: method))
                assertTimeoutContainsOnlyOperationMetadata(error)
            }
            XCTAssertEqual(fixture.wire.requests.filter { $0.method == method }.count, 1)
            XCTAssertEqual(fixture.wire.requests.filter { $0.method == "Target.attachToTarget" }.count, 1)
            XCTAssertEqual(fixture.wire.closeCount, 1)
            assertNoUserResourceMutation(fixture)
            await fixture.transport.shutdown()
        }
    }

    func testDetachTimeoutKeepsStageAndClosesOnlyConnectionWithoutRetry() async throws {
        let fixture = BorrowedTransportFixture(requestTimeout: .milliseconds(100))
        let target = try await fixture.transport.attach(targetID: "tab-a")
        fixture.wire.holdReply(to: "Target.detachFromTarget")
        do { try await fixture.transport.detach(target: target); XCTFail("Unknown detach must not be reported as success.") }
        catch let error as BorrowedChromeCommandTimeout {
            XCTAssertEqual(error, BorrowedChromeCommandTimeout(stage: .detachment, method: "Target.detachFromTarget"))
            assertTimeoutContainsOnlyOperationMetadata(error)
        }
        XCTAssertEqual(fixture.wire.requests.filter { $0.method == "Target.detachFromTarget" }.count, 1)
        XCTAssertEqual(fixture.wire.closeCount, 1)
        assertNoUserResourceMutation(fixture)
        await fixture.transport.shutdown()
    }

    private func assertTimeoutContainsOnlyOperationMetadata(
        _ error: BorrowedChromeCommandTimeout, file: StaticString = #filePath, line: UInt = #line
    ) {
        let message = error.localizedDescription
        XCTAssertTrue(message.contains(error.method), file: file, line: line)
        XCTAssertTrue(message.contains("outcome may be unknown"), file: file, line: line)
        for privateValue in ["tab-a", "session-1", "fixture.example", "Same synthetic title", "targetId", "sessionId"] {
            XCTAssertFalse(message.contains(privateValue), file: file, line: line)
        }
    }

    private func assertNoUserResourceMutation(
        _ fixture: BorrowedTransportFixture, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(fixture.wire.targets, Set(["tab-a", "tab-b"]), file: file, line: line)
        XCTAssertFalse(fixture.wire.requests.contains {
            ["Target.createTarget", "Target.activateTarget", "Target.closeTarget", "Browser.close"].contains($0.method)
        }, file: file, line: line)
    }

    private func expectBrokerError(
        _ expected: BrowserTabBrokerError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as BrowserTabBrokerError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line) }
    }
}

private struct BorrowedTransportFixture: Sendable {
    let generation = UUID()
    let wire = BorrowedFixtureWire()
    let verifier = BorrowedFixtureVerifier()
    let connection: BrowserCDPConnection
    let transport: BorrowedChromeDevToolsTransport

    init(requestTimeout: Duration = .seconds(15)) {
        var configuration = BrowserCDPConnection.Configuration()
        configuration.requestTimeout = requestTimeout
        connection = BrowserCDPConnection(wire: wire, configuration: configuration)
        let verifier = verifier
        transport = BorrowedChromeDevToolsTransport(
            connection: connection, generation: generation,
            verifyBrowser: { try verifier.verifyBrowser() },
            requirePermission: { try verifier.verifyPermission() }
        )
    }
}

private final class BorrowedFixtureVerifier: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private var refuseAt: Int?
    private var permitted = true
    var browserChecks: Int { lock.withLock { checks } }
    func failBrowserCheck(number: Int) { lock.withLock { refuseAt = number } }
    func revokePermission() { lock.withLock { permitted = false } }
    func verifyBrowser() throws {
        try lock.withLock {
            checks += 1
            if let refuseAt, checks >= refuseAt { throw BrowserTabBrokerError.browserGenerationChanged }
        }
    }
    func verifyPermission() throws {
        try lock.withLock {
            guard permitted else { throw BrowserTabBrokerError.mutationRejected("synthetic permission revoked") }
        }
    }
}

private struct BorrowedFixtureRequest: Sendable {
    let method: String
    let sessionID: String?
    let params: Data
    let wasCancelled: Bool
    func parameters() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
    }
}

private final class BorrowedFixtureWire: BrowserCDPWire, @unchecked Sendable {
    func waitUntilOpen() async throws { try Task.checkCancellation() }
    private let lock = NSLock()
    private var recorded: [BorrowedFixtureRequest] = []
    private var queued: [Data] = []
    private var reader: CheckedContinuation<Data, Error>?
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []
    private var closed = false
    private var closes = 0
    private var sequence = 0
    private var detachMethod: String?
    private var releaseFails = false
    private var detachFails = false
    private var mutationHeld = false
    private var reusedSession = false
    private var heldReplyMethod: String?
    private var hooks: [String: @Sendable () -> Void] = [:]
    // This fixture intentionally never implements tab/process lifecycle writes.
    let targets: Set<String> = ["tab-a", "tab-b"]
    var requests: [BorrowedFixtureRequest] { lock.withLock { recorded } }
    var closeCount: Int { lock.withLock { closes } }
    var failGroupRelease: Bool {
        get { lock.withLock { releaseFails } }
        set { lock.withLock { releaseFails = newValue } }
    }
    var failDetach: Bool {
        get { lock.withLock { detachFails } }
        set { lock.withLock { detachFails = newValue } }
    }
    var holdMutationReply: Bool {
        get { lock.withLock { mutationHeld } }
        set { lock.withLock { mutationHeld = newValue } }
    }
    var reuseSessionIdentity: Bool {
        get { lock.withLock { reusedSession } }
        set { lock.withLock { reusedSession = newValue } }
    }
    func detachBeforeReply(to method: String) { lock.withLock { detachMethod = method } }
    func holdReply(to method: String) { lock.withLock { heldReplyMethod = method } }
    func onEnqueue(method: String, _ hook: @escaping @Sendable () -> Void) { lock.withLock { hooks[method] = hook } }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"], let method = request["method"] as? String,
                  let params = request["params"] as? [String: Any] else {
                throw BrowserCDPConnectionError.invalidRequest
            }
            let session = request["sessionId"] as? String
            let record = BorrowedFixtureRequest(
                method: method, sessionID: session,
                params: try JSONSerialization.data(withJSONObject: params), wasCancelled: Task.isCancelled
            )
            let output: ([Data], (@Sendable () -> Void)?) = try lock.withLock {
                guard !closed else { throw BrowserCDPConnectionError.closed }
                recorded.append(record)
                let ready = waiters.filter { $0.0 == method }
                waiters.removeAll { $0.0 == method }
                for waiter in ready { waiter.1.resume() }
                var result: [String: Any] = [:]
                switch method {
                case "Target.getTargets": result = ["targetInfos": [Self.info("tab-a"), Self.info("tab-b")]]
                case "Target.getTargetInfo": result = ["targetInfo": Self.info(params["targetId"] as? String ?? "missing")]
                case "Target.attachToTarget": sequence += 1; result = ["sessionId": "session-\(reusedSession ? 1 : sequence)"]
                case "Target.detachFromTarget", "Accessibility.enable", "Runtime.releaseObjectGroup": break
                case "Page.getFrameTree": result = ["frameTree": ["frame": ["id": "frame-1", "loaderId": "loader-1", "url": Self.url]]]
                case "Accessibility.getFullAXTree": result = ["nodes": [["backendDOMNodeId": 42, "role": ["value": "button"], "name": ["value": "Synthetic +1"], "ignored": false]]]
                case "Page.createIsolatedWorld": result = ["executionContextId": 99]
                case "DOM.resolveNode": result = ["object": ["objectId": "object-42"]]
                case "Runtime.callFunctionOn": result = ["result": ["value": true]]
                default: throw BrowserCDPConnectionError.invalidRequest
                }
                var reply: [String: Any] = ["id": id, "result": result]
                if let session { reply["sessionId"] = session }
                if releaseFails && method == "Runtime.releaseObjectGroup" {
                    reply.removeValue(forKey: "result")
                    reply["error"] = ["code": -32_000, "message": "synthetic release refusal"]
                }
                if detachFails && method == "Target.detachFromTarget" {
                    reply.removeValue(forKey: "result")
                    reply["error"] = ["code": -32_001, "message": "synthetic detach refusal"]
                }
                var responses: [Data] = []
                if detachMethod == method, let session {
                    detachMethod = nil
                    responses.append(try JSONSerialization.data(withJSONObject: ["method": "Target.detachedFromTarget", "params": ["sessionId": session]]))
                }
                if !(mutationHeld && method == "Runtime.callFunctionOn") && heldReplyMethod != method {
                    responses.append(try JSONSerialization.data(withJSONObject: reply))
                }
                return (responses, hooks.removeValue(forKey: method))
            }
            output.1?()
            completion(.success(()))
            for response in output.0 { deliver(response) }
        } catch { completion(.failure(error)) }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if !queued.isEmpty { continuation.resume(returning: queued.removeFirst()) }
                else if closed { continuation.resume(throwing: BrowserCDPConnectionError.closed) }
                else if reader != nil { continuation.resume(throwing: BrowserCDPConnectionError.malformedMessage) }
                else { reader = continuation }
            }
        }
    }

    func waitFor(method: String) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if recorded.contains(where: { $0.method == method }) { continuation.resume() }
                else { waiters.append((method, continuation)) }
            }
        }
    }

    private func deliver(_ data: Data) {
        lock.withLock {
            if let reader { self.reader = nil; reader.resume(returning: data) }
            else { queued.append(data) }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            closes += 1
            reader?.resume(throwing: BrowserCDPConnectionError.closed)
            reader = nil
        }
    }

    private static let url = "https://fixture.example/same"
    private static func info(_ target: String) -> [String: Any] {
        ["targetId": target, "type": "page", "title": "Same synthetic title", "url": url]
    }
}

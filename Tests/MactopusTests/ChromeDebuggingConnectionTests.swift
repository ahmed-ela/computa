import Foundation
import XCTest
@testable import Mactopus

/// In-memory admission/protocol tests only. Never reads a Chrome profile,
/// requests macOS permissions, launches a browser, or opens a socket.
final class ChromeDebuggingConnectionTests: XCTestCase {
    func testDeniedConsentPreventsIdentityPermissionAndWireCreation() async {
        let fixture = ChromeConnectionTestHarness(approved: false)
        await assertFailure { _ = try await fixture.connect() }
        XCTAssertEqual(fixture.identity.checks, 0)
        XCTAssertEqual(fixture.permission.checks, 0)
        XCTAssertEqual(fixture.creations.value, 0)
        XCTAssertTrue(fixture.peer.methods.isEmpty)
    }

    func testStaleIdentityAndDeniedPermissionPreventWireCreation() async {
        for staleIdentity in [true, false] {
            let fixture = ChromeConnectionTestHarness()
            if staleIdentity { fixture.identity.reject() } else { fixture.permission.reject() }
            await assertFailure { _ = try await fixture.connect() }
            XCTAssertEqual(fixture.creations.value, 0)
            XCTAssertTrue(fixture.peer.methods.isEmpty)
            XCTAssertEqual(fixture.peer.closeCount, 0, "No wire was created to close.")
            if staleIdentity { XCTAssertEqual(fixture.permission.checks, 0) }
        }
    }

    func testInvalidEndpointDoesNotCreateWire() async {
        let fixture = ChromeConnectionTestHarness(endpoint: URL(string: "ws://example.com:9222/devtools/browser/test")!)
        await assertFailure { _ = try await fixture.connect() }
        XCTAssertEqual(fixture.creations.value, 0)
        XCTAssertTrue(fixture.peer.methods.isEmpty)
    }

    func testAlreadyCancelledConnectDoesNotCreateWire() async {
        let fixture = ChromeConnectionTestHarness()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.connect()
        }
        await assertFailure { _ = try await operation.value }
        XCTAssertEqual(fixture.creations.value, 0)
        XCTAssertEqual(fixture.identity.checks, 0)
    }

    func testWireFactoryFailureDoesNotRetryOrStartHandshake() async {
        let fixture = ChromeConnectionTestHarness()
        await assertFailure {
            _ = try await ChromeDebuggingConnection.connect(
                authority: fixture.authority, requirePermission: { try fixture.permission.check() },
                makeWire: { _ in
                    fixture.creations.increment()
                    throw ChromeConnectionTestError.denied
                }
            )
        }
        XCTAssertEqual(fixture.creations.value, 1)
        XCTAssertTrue(fixture.peer.methods.isEmpty)
        XCTAssertEqual(fixture.peer.closeCount, 0)
    }

    func testHandshakeUsesOnlyVersionThenReadOnlyTargetListAndLocalClose() async throws {
        for product in ["Chrome/140.0", "HeadlessChrome/140.0"] {
            let fixture = ChromeConnectionTestHarness()
            defer { fixture.peer.close() }
            let pending = Task { try await fixture.connect() }
            let handshake = try await fixture.peer.request(at: 0)
            XCTAssertEqual(handshake.method, "Browser.getVersion")
            XCTAssertNil(handshake.sessionID)
            XCTAssertEqual(handshake.parameters, Data("{}".utf8))
            try fixture.peer.reply(to: handshake, result: ["product": product, "protocolVersion": "1.3"])
            let transport = try await pending.value
            XCTAssertEqual(fixture.peer.methods, ["Browser.getVersion"])
            let listing = Task { try await transport.listCandidates() }
            let list = try await fixture.peer.request(at: 1)
            XCTAssertEqual(list.method, "Target.getTargets")
            XCTAssertNil(list.sessionID)
            try fixture.peer.reply(to: list, result: ["targetInfos": [[
                "targetId": "existing-tab", "type": "page", "title": "Fixture",
                "url": "https://example.com/fixture",
            ]]])
            let candidates = try await listing.value
            XCTAssertEqual(candidates.map(\.targetID), ["existing-tab"])
            await transport.shutdown()
            await transport.shutdown()
            XCTAssertEqual(fixture.creations.value, 1)
            XCTAssertEqual(fixture.peer.closeCount, 1)
            XCTAssertEqual(fixture.peer.methods, ["Browser.getVersion", "Target.getTargets"],
                           "Admission and shutdown must not activate, create, navigate, or close a user tab.")
        }
    }

    func testMalformedVersionClosesWithoutPublishingOrRetry() async throws {
        let versions: [[String: Any]] = [
            [:], ["product": "Other/1", "protocolVersion": "1.3"],
            ["product": "Chrome/1"], ["product": "Chrome/1", "protocolVersion": ""],
            ["product": "Chrome/1", "protocolVersion": 1.3],
            ["product": "Chrome/" + String(repeating: "x", count: 256), "protocolVersion": "1.3"],
            ["product": "Chrome/1", "protocolVersion": String(repeating: "x", count: 33)],
        ]
        for version in versions {
            let fixture = ChromeConnectionTestHarness()
            defer { fixture.peer.close() }
            let pending = Task { try await fixture.connect() }
            let request = try await fixture.peer.request(at: 0)
            try fixture.peer.reply(to: request, result: version)
            await assertFailure { _ = try await pending.value }
            XCTAssertEqual(fixture.creations.value, 1)
            XCTAssertEqual(fixture.peer.closeCount, 1)
            XCTAssertEqual(fixture.peer.methods, ["Browser.getVersion"])
        }
    }

    func testMalformedProtocolHandshakeClosesWire() async throws {
        let fixture = ChromeConnectionTestHarness()
        defer { fixture.peer.close() }
        let pending = Task { try await fixture.connect() }
        _ = try await fixture.peer.request(at: 0)
        fixture.peer.emit(Data("not-json".utf8))
        await assertFailure { _ = try await pending.value }
        XCTAssertEqual(fixture.peer.closeCount, 1)
        XCTAssertEqual(fixture.creations.value, 1)
    }

    func testHandshakeTimeoutClosesWithoutRetry() async {
        let fixture = ChromeConnectionTestHarness()
        var configuration = BrowserCDPConnection.Configuration()
        configuration.requestTimeout = .milliseconds(40)
        do { _ = try await fixture.connect(configuration: configuration); XCTFail("Expected handshake deadline") }
        catch { XCTAssertEqual(error as? ChromeDebuggingAdmissionError, .handshakeTimedOut) }
        XCTAssertEqual(fixture.peer.methods, ["Browser.getVersion"])
        XCTAssertEqual(fixture.peer.closeCount, 1)
        XCTAssertEqual(fixture.creations.value, 1)
    }

    func testOpeningWaitDoesNotConsumeProtocolDeadline() async throws {
        let fixture = ChromeConnectionTestHarness(opened: false)
        defer { fixture.peer.close() }
        var configuration = BrowserCDPConnection.Configuration()
        configuration.requestTimeout = .milliseconds(80)
        let pending = Task { try await fixture.connect(configuration: configuration) }
        try await fixture.peer.waitForOpening()
        // Exceed the protocol budget while Chrome's opening is still pending.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(fixture.peer.methods.isEmpty)
        XCTAssertEqual(fixture.peer.closeCount, 0)
        fixture.peer.opened()
        let handshake = try await fixture.peer.request(at: 0)
        try fixture.peer.reply(to: handshake, result: ["product": "Chrome/140", "protocolVersion": "1.3"])
        let transport = try await pending.value
        XCTAssertEqual(fixture.creations.value, 1)
        await transport.shutdown()
    }

    func testInjectedOpeningDeadlineClosesSilentWireWithoutSendingOrRetrying() async throws {
        let fixture = ChromeConnectionTestHarness(opened: false)
        let deadline = ChromeConnectionTestOpeningDeadline()
        let pending = Task {
            try await fixture.connect(openingTimeout: .seconds(120), sleepForOpeningDeadline: { try await deadline.sleep($0) })
        }
        defer { pending.cancel(); fixture.peer.close() }
        try await fixture.peer.waitForOpening()
        try await deadline.waitUntilStarted()
        XCTAssertEqual(deadline.duration, .seconds(120))
        XCTAssertTrue(fixture.peer.methods.isEmpty)
        deadline.fire()
        do { _ = try await pending.value; XCTFail("Expected opening deadline") }
        catch { XCTAssertEqual(error as? ChromeDebuggingAdmissionError, .openingTimedOut) }
        fixture.peer.opened()
        XCTAssertEqual(fixture.peer.closeCount, 1)
        XCTAssertEqual(fixture.creations.value, 1)
        XCTAssertTrue(fixture.peer.methods.isEmpty)
    }

    func testCancellationDuringOpeningClosesAndRejectsLateOpen() async throws {
        let fixture = ChromeConnectionTestHarness(opened: false)
        let pending = Task { try await fixture.connect() }
        try await fixture.peer.waitForOpening()
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled admission must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.peer.opened()
        XCTAssertTrue(fixture.peer.methods.isEmpty)
        XCTAssertEqual(fixture.peer.closeCount, 1)
        XCTAssertEqual(fixture.creations.value, 1)
    }

    func testIdentityPermissionAndConsentChangesDuringOpeningPreventHandshake() async throws {
        for change in 0..<3 {
            let fixture = ChromeConnectionTestHarness(opened: false)
            let pending = Task { try await fixture.connect() }
            try await fixture.peer.waitForOpening()
            switch change {
            case 0: fixture.identity.reject()
            case 1: fixture.permission.reject()
            default: fixture.consent.revoke()
            }
            fixture.peer.opened()
            await assertFailure { _ = try await pending.value }
            XCTAssertTrue(fixture.peer.methods.isEmpty)
            XCTAssertEqual(fixture.peer.closeCount, 1)
            XCTAssertEqual(fixture.creations.value, 1)
        }
    }

    func testOpeningFailurePublishesOnlyFixedSafeCategory() async throws {
        let fixture = ChromeConnectionTestHarness(opened: false)
        let pending = Task { try await fixture.connect() }
        try await fixture.peer.waitForOpening()
        fixture.peer.failOpening(NSError(domain: "secret-profile", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "secret-endpoint and private page contents"]))
        do { _ = try await pending.value; XCTFail("Expected opening failure") }
        catch {
            XCTAssertEqual(error as? ChromeDebuggingAdmissionError, .openingFailed)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
            XCTAssertFalse(error.localizedDescription.contains("page contents"))
        }
        XCTAssertTrue(fixture.peer.methods.isEmpty)
        XCTAssertEqual(fixture.peer.closeCount, 1)
    }

    func testTransportOpeningTimeoutHasOpeningCategory() async throws {
        let fixture = ChromeConnectionTestHarness(opened: false)
        let pending = Task { try await fixture.connect() }
        try await fixture.peer.waitForOpening()
        fixture.peer.failOpening(BrowserCDPConnectionError.deadlineExceeded)
        do { _ = try await pending.value; XCTFail("Expected opening timeout") }
        catch { XCTAssertEqual(error as? ChromeDebuggingAdmissionError, .openingTimedOut) }
        XCTAssertTrue(fixture.peer.methods.isEmpty)
        XCTAssertEqual(fixture.peer.closeCount, 1)
    }

    func testInvalidOpeningBudgetDoesNotCreateWire() async {
        for timeout in [Duration.zero, .seconds(-1), .seconds(121)] {
            let fixture = ChromeConnectionTestHarness()
            await assertFailure { _ = try await fixture.connect(openingTimeout: timeout) }
            XCTAssertEqual(fixture.creations.value, 0)
        }
    }

    func testCancelledHandshakeClosesWithoutRetry() async throws {
        let fixture = ChromeConnectionTestHarness()
        defer { fixture.peer.close() }
        let pending = Task { try await fixture.connect() }
        _ = try await fixture.peer.request(at: 0)
        pending.cancel()
        await assertFailure { _ = try await pending.value }
        XCTAssertEqual(fixture.peer.closeCount, 1)
        XCTAssertEqual(fixture.peer.methods, ["Browser.getVersion"])
        XCTAssertEqual(fixture.creations.value, 1)
    }

    func testChangedIdentityOrPermissionAfterCreationPreventsHandshakeEnqueue() async {
        for changeIdentity in [true, false] {
            let fixture = ChromeConnectionTestHarness()
            await assertFailure {
                _ = try await fixture.connect(afterCreation: {
                    if changeIdentity { fixture.identity.reject() } else { fixture.permission.reject() }
                })
            }
            XCTAssertEqual(fixture.creations.value, 1)
            XCTAssertTrue(fixture.peer.methods.isEmpty)
            XCTAssertEqual(fixture.peer.closeCount, 1)
        }
    }

    func testIdentityPermissionOrConsentChangeDuringHandshakePreventsPublishing() async throws {
        for change in 0..<3 {
            let fixture = ChromeConnectionTestHarness()
            defer { fixture.peer.close() }
            let pending = Task { try await fixture.connect() }
            let request = try await fixture.peer.request(at: 0)
            switch change {
            case 0: fixture.identity.reject()
            case 1: fixture.permission.reject()
            default: fixture.consent.revoke()
            }
            try fixture.peer.reply(to: request, result: ["product": "Chrome/140", "protocolVersion": "1.3"])
            await assertFailure { _ = try await pending.value }
            XCTAssertEqual(fixture.peer.closeCount, 1)
            XCTAssertEqual(fixture.creations.value, 1)
            XCTAssertEqual(fixture.peer.methods, ["Browser.getVersion"])
        }
    }

    func testRevokedOrChangedAuthorityAtBoundWireEnqueueSendsNothing() throws {
        for changeIdentity in [true, false] {
            let fixture = ChromeConnectionTestHarness()
            let wire = ChromeDebuggingBoundWire(base: fixture.peer, authority: fixture.authority)
            if changeIdentity { fixture.identity.reject() } else { fixture.consent.revoke() }
            let outcome = ChromeConnectionTestOutcome()
            wire.enqueue(Data(#"{"id":1,"method":"Target.getTargets","params":{}}"#.utf8)) { outcome.record($0) }
            XCTAssertEqual(outcome.count, 1)
            XCTAssertTrue(outcome.failed)
            XCTAssertTrue(fixture.peer.methods.isEmpty)
            XCTAssertEqual(fixture.peer.closeCount, 1)
            wire.close()
            XCTAssertEqual(fixture.peer.closeCount, 1)
        }
    }

    func testResponseArrivingAfterConsentRevocationIsRejectedAndClosesWire() async throws {
        let fixture = ChromeConnectionTestHarness()
        defer { fixture.peer.close() }
        let wire = ChromeDebuggingBoundWire(base: fixture.peer, authority: fixture.authority)
        let response = Task { try await wire.receive() }
        try await fixture.peer.waitForReceive()
        fixture.consent.revoke()
        fixture.peer.emit(Data("already-in-flight-response".utf8))
        do { _ = try await response.value; XCTFail("Revoked response must not be published.") }
        catch { XCTAssertEqual(error as? ChromeDebuggingEndpointError, .consentRequired) }
        XCTAssertEqual(fixture.peer.closeCount, 1)
        XCTAssertTrue(fixture.peer.methods.isEmpty)
    }

    func testFailureAfterSuccessfulConnectionNeverReconnects() async throws {
        let fixture = ChromeConnectionTestHarness()
        defer { fixture.peer.close() }
        let pending = Task { try await fixture.connect() }
        let request = try await fixture.peer.request(at: 0)
        try fixture.peer.reply(to: request, result: ["product": "Chrome/140", "protocolVersion": "1.3"])
        let transport = try await pending.value
        let listing = Task { try await transport.listCandidates() }
        _ = try await fixture.peer.request(at: 1)
        fixture.peer.failReceive()
        await assertFailure { _ = try await listing.value }
        await assertFailure { _ = try await transport.listCandidates() }
        await transport.shutdown()
        XCTAssertEqual(fixture.creations.value, 1)
        XCTAssertEqual(fixture.peer.closeCount, 1)
        XCTAssertEqual(fixture.peer.methods, ["Browser.getVersion", "Target.getTargets"])
    }

    func testConsentRevocationWaitsForAdmittedSynchronousOperationThenBlocksNewWork() {
        let consent = ChromeDebuggingConsent(approvedByUser: true)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0), revoking = DispatchSemaphore(value: 0)
        let revoked = DispatchSemaphore(value: 0)
        let order = ChromeConnectionTestOrder()
        defer { release.signal() }
        DispatchQueue.global().async {
            do {
                try consent.withApproval {
                    order.append("admitted")
                    entered.signal()
                    if release.wait(timeout: .now() + 2) != .success { order.append("timeout") }
                    order.append("submitted")
                }
            } catch { order.append("unexpected-denial") }
            exited.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            revoking.signal()
            consent.revoke()
            order.append("revoked")
            revoked.signal()
        }
        XCTAssertEqual(revoking.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revoked.wait(timeout: .now() + .milliseconds(30)), .timedOut,
                       "Revocation cannot return while the earlier synchronous submission is admitted.")
        release.signal()
        XCTAssertEqual(exited.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revoked.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(order.values, ["admitted", "submitted", "revoked"])
        XCTAssertThrowsError(try consent.withApproval { order.append("forbidden") }) { error in
            XCTAssertEqual(error as? ChromeDebuggingEndpointError, .consentRequired)
        }
        XCTAssertFalse(order.values.contains("forbidden"))
    }

    private func assertFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected fail-closed admission.", file: file, line: line) }
        catch { }
    }
}

private enum ChromeConnectionTestError: Error { case denied, expired }

private final class ChromeConnectionTestOpeningDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = BrowserCDPWireOpening()
    private var requested: Duration?
    var duration: Duration? { lock.withLock { requested } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { requested = duration }
        try await gate.wait()
    }

    func fire() { gate.finish(.success(())) }

    func waitUntilStarted() async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(2)
        while clock.now < deadline {
            if duration != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ChromeConnectionTestError.expired
    }
}

private final class ChromeConnectionTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var count = 0
    var checks: Int { lock.withLock { count } }
    func reject() { lock.withLock { allowed = false } }
    func check() throws {
        try lock.withLock {
            count += 1
            guard allowed else { throw ChromeConnectionTestError.denied }
        }
    }
}

private final class ChromeConnectionTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ChromeConnectionTestOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var values: [String] { lock.withLock { entries } }
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
}

private final class ChromeConnectionTestOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var didFail = false
    var count: Int { lock.withLock { calls } }
    var failed: Bool { lock.withLock { didFail } }
    func record(_ result: Result<Void, Error>) {
        lock.withLock {
            calls += 1
            if case .failure = result { didFail = true }
        }
    }
}

private struct ChromeConnectionTestHarness: Sendable {
    let consent: ChromeDebuggingConsent
    let identity = ChromeConnectionTestGate()
    let permission = ChromeConnectionTestGate()
    let creations = ChromeConnectionTestCounter()
    let peer: ChromeConnectionTestPeer
    let endpoint: URL

    init(
        approved: Bool = true, opened: Bool = true,
        endpoint: URL = URL(string: "ws://127.0.0.1:9222/devtools/browser/synthetic")!
    ) {
        consent = ChromeDebuggingConsent(approvedByUser: approved)
        peer = ChromeConnectionTestPeer(opened: opened)
        self.endpoint = endpoint
    }

    var authority: ChromeDebuggingConnectionAuthority {
        ChromeDebuggingConnectionAuthority(endpoint: endpoint, consent: consent) { try identity.check() }
    }

    func connect(
        configuration: BrowserCDPConnection.Configuration? = nil,
        openingTimeout: Duration = .seconds(2),
        sleepForOpeningDeadline: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        afterCreation: @escaping @Sendable () -> Void = {}
    ) async throws -> BorrowedChromeDevToolsTransport {
        var bounded = configuration ?? BrowserCDPConnection.Configuration()
        if configuration == nil { bounded.requestTimeout = .seconds(2) }
        return try await ChromeDebuggingConnection.connect(
            authority: authority, requirePermission: { try permission.check() }, configuration: bounded,
            openingTimeout: openingTimeout, sleepForOpeningDeadline: sleepForOpeningDeadline,
            makeWire: { requestedEndpoint in
                guard requestedEndpoint == endpoint else { throw ChromeConnectionTestError.denied }
                creations.increment()
                afterCreation()
                return peer
            }
        )
    }
}

private final class ChromeConnectionTestPeer: BrowserCDPWire, @unchecked Sendable {
    struct Request: Sendable {
        let id: Int
        let method: String
        let sessionID: String?
        let parameters: Data
    }

    private let lock = NSLock()
    private let opening = BrowserCDPWireOpening()
    private var openingWaits = 0
    private var requests: [Request] = []
    private var queued: [Result<Data, Error>] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var receives = 0
    private var closed = false
    private var closes = 0

    var methods: [String] { lock.withLock { requests.map(\.method) } }
    var closeCount: Int { lock.withLock { closes } }

    init(opened: Bool = true) {
        if opened { opening.finish(.success(())) }
    }

    func waitUntilOpen() async throws {
        lock.withLock { openingWaits += 1 }
        try await opening.wait()
    }

    func opened() { opening.finish(.success(())) }
    func failOpening(_ error: Error) { opening.finish(.failure(error)) }

    func waitForOpening() async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(2)
        while clock.now < deadline {
            if lock.withLock({ openingWaits > 0 }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ChromeConnectionTestError.expired
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = value["id"] as? Int, let method = value["method"] as? String else {
                throw BrowserCDPConnectionError.malformedMessage
            }
            let request = Request(id: id, method: method, sessionID: value["sessionId"] as? String,
                                  parameters: try JSONSerialization.data(withJSONObject: value["params"] ?? [:], options: [.sortedKeys]))
            try lock.withLock {
                guard !closed else { throw BrowserCDPConnectionError.closed }
                requests.append(request)
            }
            completion(.success(()))
        } catch { completion(.failure(error)) }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                receives += 1
                if closed { continuation.resume(throwing: BrowserCDPConnectionError.closed) }
                else if !queued.isEmpty { continuation.resume(with: queued.removeFirst()) }
                else if receiver != nil { continuation.resume(throwing: BrowserCDPConnectionError.malformedMessage) }
                else { receiver = continuation }
            }
        }
    }

    func request(at index: Int) async throws -> Request {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(2)
        while clock.now < deadline {
            if let request = lock.withLock({ requests.indices.contains(index) ? requests[index] : nil }) { return request }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ChromeConnectionTestError.expired
    }

    func waitForReceive() async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(2)
        while clock.now < deadline {
            if lock.withLock({ receives > 0 }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ChromeConnectionTestError.expired
    }

    func reply(to request: Request, result: [String: Any]) throws {
        var envelope: [String: Any] = ["id": request.id, "result": result]
        if let sessionID = request.sessionID { envelope["sessionId"] = sessionID }
        emit(try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]))
    }

    func emit(_ data: Data) { deliver(.success(data)) }
    func failReceive() { deliver(.failure(BrowserCDPConnectionError.transportFailed)) }

    private func deliver(_ result: Result<Data, Error>) {
        lock.withLock {
            guard !closed else { return }
            if let receiver { self.receiver = nil; receiver.resume(with: result) }
            else { queued.append(result) }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            closes += 1
            opening.finish(.failure(BrowserCDPConnectionError.closed))
            queued.removeAll()
            let pending = receiver
            receiver = nil
            pending?.resume(throwing: BrowserCDPConnectionError.closed)
        }
    }
}

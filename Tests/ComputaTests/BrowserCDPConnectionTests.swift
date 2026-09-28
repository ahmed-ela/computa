import Foundation
import XCTest
@testable import Computa

final class BrowserCDPConnectionTests: XCTestCase {
    func testOpeningResultCanArriveBeforeWaiter() async throws {
        let opening = BrowserCDPWireOpening()
        opening.finish(.success(()))
        try await opening.wait()
        try await opening.wait()
    }

    func testOpeningFailureCannotBeReplacedByLateSuccess() async {
        let opening = BrowserCDPWireOpening()
        opening.finish(.failure(BrowserCDPConnectionError.transportFailed))
        opening.finish(.success(()))
        do { try await opening.wait(); XCTFail("A failed opening must remain failed") }
        catch { XCTAssertEqual(error as? BrowserCDPConnectionError, .transportFailed) }
    }

    func testCancelledOpeningWaitAlwaysReturnsCancellation() async {
        let opening = BrowserCDPWireOpening()
        let waiting = Task { try await opening.wait() }
        waiting.cancel()
        opening.finish(.success(()))
        do { try await waiting.value; XCTFail("Cancellation must win for its waiter") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testWebSocketDelegateOnlyAdmitsSuccessfulOpeningAndRefusesRedirects() async throws {
        // Tasks are never resumed: direct delegate callbacks exercise opening
        // state without opening sockets or touching a real browser.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let endpoint = try XCTUnwrap(URL(string: "ws://127.0.0.1:9222/devtools/browser/inert"))
        let task = session.webSocketTask(with: endpoint)

        let opened = BrowserCDPWireOpening()
        let openedDelegate = BrowserCDPWebSocketDelegate(opening: opened)
        openedDelegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        try await opened.wait()

        for error in [nil, URLError(.cannotConnectToHost), URLError(.timedOut)] {
            let failed = BrowserCDPWireOpening()
            let delegate = BrowserCDPWebSocketDelegate(opening: failed)
            delegate.urlSession(session, task: task, didCompleteWithError: error)
            delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
            do { try await failed.wait(); XCTFail("Completion before opening must fail") }
            catch let actual as BrowserCDPConnectionError {
                XCTAssertEqual(actual, error?.code == .timedOut ? .deadlineExceeded : .transportFailed)
            }
        }

        let closed = BrowserCDPWireOpening()
        let closedDelegate = BrowserCDPWebSocketDelegate(opening: closed)
        closedDelegate.urlSession(session, webSocketTask: task, didCloseWith: .normalClosure,
                                  reason: Data("private peer detail".utf8))
        closedDelegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        do { try await closed.wait(); XCTFail("A closed transport cannot become open") }
        catch { XCTAssertEqual(error as? BrowserCDPConnectionError, .closed) }

        let redirected = BrowserCDPWireOpening()
        let redirectDelegate = BrowserCDPWebSocketDelegate(opening: redirected)
        let response = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: 302,
                                                     httpVersion: "HTTP/1.1", headerFields: [:]))
        let completionCount = CDPTestCounter()
        redirectDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                     newRequest: URLRequest(url: endpoint)) { request in
            XCTAssertNil(request)
            completionCount.increment()
        }
        XCTAssertEqual(completionCount.value, 1)
        do { try await redirected.wait(); XCTFail("Redirect must fail opening") }
        catch { XCTAssertEqual(error as? BrowserCDPConnectionError, .transportFailed) }
    }

    func testInterleavedResponsesAndEventsUseOneReaderAndExactSessions() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let first = Task { try await connection.command(method: "Page.getFrameTree", sessionID: "first") }
        let second = Task { try await connection.command(method: "DOM.getDocument", sessionID: "second") }
        let sent = await wire.waitForEnqueues(2)
        let frames = try sent.map(Self.object)
        let one = try XCTUnwrap(frames.first { $0["sessionId"] as? String == "first" })
        let two = try XCTUnwrap(frames.first { $0["sessionId"] as? String == "second" })
        try wire.inject(["method": "Target.targetDestroyed", "params": ["targetId": "synthetic"]])
        try wire.inject(["id": two["id"]!, "sessionId": "second", "result": ["value": 2]])
        try wire.inject(["method": "DOM.documentUpdated", "sessionId": "first"])
        try wire.inject(["id": one["id"]!, "sessionId": "first", "result": ["value": 1]])
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(try Self.object(firstResult)["value"] as? Int, 1)
        XCTAssertEqual(try Self.object(secondResult)["value"] as? Int, 2)
        var events = connection.events.makeAsyncIterator()
        let destroyed = try await events.next()
        let updated = try await events.next()
        XCTAssertEqual(destroyed?.method, "Target.targetDestroyed")
        XCTAssertNil(destroyed?.sessionID)
        XCTAssertEqual(updated?.method, "DOM.documentUpdated")
        XCTAssertEqual(updated?.sessionID, "first")
        XCTAssertEqual(updated?.params, Data("{}".utf8))
        XCTAssertEqual(wire.maximumConcurrentReceives, 1)
        XCTAssertEqual(wire.frames.count, 2)
        await connection.close()
    }

    func testWrongSessionAndUnknownIDDisconnectWithoutRetry() async throws {
        for mismatch in [true, false] {
            let wire = FakeBrowserCDPWire()
            let connection = BrowserCDPConnection(wire: wire)
            let request = Task { try await connection.command(method: "DOM.getDocument", sessionID: "expected") }
            let sent = try Self.object(await wire.waitForEnqueues(1)[0])
            try wire.inject([
                "id": mismatch ? sent["id"]! : 500,
                "sessionId": mismatch ? "wrong" : "expected", "result": [:],
            ])
            await expectError(mismatch ? .sessionMismatch : .unexpectedResponse) { try await request.value }
            await expectError(mismatch ? .sessionMismatch : .unexpectedResponse) {
                try await connection.command(method: "Target.getTargets")
            }
            XCTAssertEqual(wire.frames.count, 1)
            XCTAssertEqual(wire.closeCount, 1)
        }
    }

    func testMissingAndUnexpectedSessionAreRejected() async throws {
        for requestedSession in [nil, "expected"] as [String?] {
            let wire = FakeBrowserCDPWire()
            let connection = BrowserCDPConnection(wire: wire)
            let request = Task { try await connection.command(method: "DOM.getDocument", sessionID: requestedSession) }
            let sent = try Self.object(await wire.waitForEnqueues(1)[0])
            var reply: [String: Any] = ["id": sent["id"]!, "result": [:]]
            if requestedSession == nil { reply["sessionId"] = "unexpected" }
            try wire.inject(reply)
            await expectError(.sessionMismatch) { try await request.value }
        }
    }

    func testMalformedAndOversizedMessagesFailClosed() async throws {
        let malformed = [
            Data("not-json".utf8), Data("[]".utf8),
            Data(#"{"id":true,"result":{}}"#.utf8),
            Data(#"{"id":1.5,"result":{}}"#.utf8),
            Data(#"{"id":1,"result":[],"sessionId":"session"}"#.utf8),
            Data(#"{"id":1,"result":{},"error":{"code":1,"message":"bad"}}"#.utf8),
            Data(#"{"method":"Page.loadEventFired","params":null}"#.utf8),
            Data(#"{"id":1,"error":{"code":true,"message":"bad"}}"#.utf8),
        ]
        for bytes in malformed + [Data(repeating: 32, count: 1_025)] {
            let wire = FakeBrowserCDPWire()
            var configuration = BrowserCDPConnection.Configuration()
            configuration.maximumMessageBytes = 1_024
            let connection = BrowserCDPConnection(wire: wire, configuration: configuration)
            let request = Task { try await connection.command(method: "Target.getTargets") }
            _ = await wire.waitForEnqueues(1)
            wire.inject(bytes)
            await expectError(bytes.count > 1_024 ? .messageTooLarge : .malformedMessage) {
                try await request.value
            }
            XCTAssertEqual(wire.frames.count, 1)
            XCTAssertEqual(wire.closeCount, 1)
        }
    }

    func testCommandErrorRedactsPeerMessageAndDoesNotDisconnect() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let first = Task { try await connection.command(method: "Target.getTargets") }
        let one = try Self.object(await wire.waitForEnqueues(1)[0])
        try wire.inject(["id": one["id"]!, "error": ["code": -32_000, "message": "SYNTHETIC_SECRET_DO_NOT_EXPOSE"]])
        await expectError(.commandRejected(-32_000)) { try await first.value }
        XCTAssertFalse(BrowserCDPConnectionError.commandRejected(-32_000).localizedDescription.contains("SYNTHETIC_SECRET"))
        let second = Task { try await connection.command(method: "Target.getTargets") }
        let two = try Self.object(await wire.waitForEnqueues(2)[1])
        try wire.inject(["id": two["id"]!, "result": [:]])
        _ = try await second.value
        XCTAssertEqual(wire.closeCount, 0)
        await connection.close()
    }

    func testCancellationBeforeEnqueueAndRevokedPermitSubmitNothing() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await connection.command(method: "DOM.getDocument")
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let permit = BrowserMutationPermit()
        permit.revoke()
        do {
            _ = try await connection.command(method: "Runtime.callFunctionOn", permit: permit)
            XCTFail("A revoked permit must reject before the wire.")
        } catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .staleSnapshot) }
        XCTAssertTrue(wire.frames.isEmpty)
        await connection.close()
    }

    func testPermitGuardsActualEnqueueAndIsConsumedOnce() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let permit = BrowserMutationPermit()
        let first = Task { try await connection.command(method: "Runtime.callFunctionOn", permit: permit) }
        let frame = try Self.object(await wire.waitForEnqueues(1)[0])
        try wire.inject(["id": frame["id"]!, "result": [:]])
        _ = try await first.value
        do {
            _ = try await connection.command(method: "Runtime.callFunctionOn", permit: permit)
            XCTFail("A mutation permit is single use.")
        } catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .staleSnapshot) }
        XCTAssertEqual(wire.frames.count, 1)
        await connection.close()
    }

    func testCancellationAfterEnqueueAcceptsOneLateReplyAndPreservesOtherRequest() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let first = Task { try await connection.command(method: "DOM.getDocument", sessionID: "cancel") }
        let one = try Self.object(await wire.waitForEnqueues(1)[0])
        let other = Task { try await connection.command(method: "Page.getFrameTree", sessionID: "other") }
        let two = try Self.object(await wire.waitForEnqueues(2)[1])
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        try wire.inject(["id": one["id"]!, "sessionId": "cancel", "result": [:]])
        try wire.inject(["id": two["id"]!, "sessionId": "other", "result": ["ok": true]])
        let result = try await other.value
        XCTAssertEqual(try Self.object(result)["ok"] as? Bool, true)
        XCTAssertEqual(wire.frames.count, 2)
        XCTAssertEqual(wire.closeCount, 0)
        await connection.close()
    }

    func testCancelledLateReplyStillRequiresExactSession() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let first = Task { try await connection.command(method: "DOM.getDocument", sessionID: "expected") }
        let one = try Self.object(await wire.waitForEnqueues(1)[0])
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let next = Task { try await connection.command(method: "Target.getTargets") }
        _ = await wire.waitForEnqueues(2)
        try wire.inject(["id": one["id"]!, "sessionId": "wrong", "result": [:]])
        await expectError(.sessionMismatch) { try await next.value }
        XCTAssertEqual(wire.frames.count, 2)
    }

    func testDuplicateResponseIsNotSilentlyDiscarded() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let first = Task { try await connection.command(method: "Target.getTargets") }
        let one = try Self.object(await wire.waitForEnqueues(1)[0])
        let response: [String: Any] = ["id": one["id"]!, "result": [:]]
        try wire.inject(response)
        _ = try await first.value
        let next = Task { try await connection.command(method: "Target.getTargets") }
        _ = await wire.waitForEnqueues(2)
        try wire.inject(response)
        await expectError(.unexpectedResponse) { try await next.value }
    }

    func testDeadlineDisconnectsAllPendingWithoutReplay() async throws {
        let wire = FakeBrowserCDPWire()
        var configuration = BrowserCDPConnection.Configuration()
        configuration.requestTimeout = .milliseconds(100)
        let connection = BrowserCDPConnection(wire: wire, configuration: configuration)
        let first = Task { try await connection.command(method: "Runtime.callFunctionOn") }
        let second = Task { try await connection.command(method: "DOM.getDocument") }
        _ = await wire.waitForEnqueues(2)
        await expectError(.deadlineExceeded) { try await first.value }
        await expectError(.deadlineExceeded) { try await second.value }
        await expectError(.deadlineExceeded) { try await connection.command(method: "Target.getTargets") }
        XCTAssertEqual(wire.frames.count, 2)
        XCTAssertEqual(wire.closeCount, 1)
    }

    func testReceiveAndSendFailureInvalidatePendingAndNeverRetry() async throws {
        for sendFailure in [true, false] {
            let wire = FakeBrowserCDPWire()
            wire.failSends = sendFailure
            let connection = BrowserCDPConnection(wire: wire)
            let first = Task { try await connection.command(method: "Runtime.callFunctionOn") }
            _ = await wire.waitForEnqueues(1)
            if !sendFailure { wire.failReceive() }
            await expectError(.transportFailed) { try await first.value }
            await expectError(.transportFailed) { try await connection.command(method: "Target.getTargets") }
            XCTAssertEqual(wire.frames.count, 1)
            XCTAssertEqual(wire.closeCount, 1)
        }
    }

    func testPendingLimitRejectsWithoutEnqueueAndCloseResolvesWaiter() async throws {
        let wire = FakeBrowserCDPWire()
        var configuration = BrowserCDPConnection.Configuration()
        configuration.maximumPendingRequests = 1
        let connection = BrowserCDPConnection(wire: wire, configuration: configuration)
        let first = Task { try await connection.command(method: "Target.getTargets") }
        _ = await wire.waitForEnqueues(1)
        await expectError(.requestLimit) { try await connection.command(method: "Target.getTargets") }
        await connection.close()
        await expectError(.closed) { try await first.value }
        await connection.close()
        XCTAssertEqual(wire.closeCount, 1)
        XCTAssertEqual(wire.frames.count, 1)
    }

    func testEventOverflowInvalidatesRatherThanLosingDetachAuthority() async throws {
        let wire = FakeBrowserCDPWire()
        var configuration = BrowserCDPConnection.Configuration()
        configuration.maximumBufferedEvents = 1
        let connection = BrowserCDPConnection(wire: wire, configuration: configuration)
        let first = Task { try await connection.command(method: "Target.getTargets") }
        _ = await wire.waitForEnqueues(1)
        try wire.inject(["method": "Target.targetDestroyed", "params": ["targetId": "one"]])
        try wire.inject(["method": "Target.targetDestroyed", "params": ["targetId": "two"]])
        await expectError(.eventOverflow) { try await first.value }
        var iterator = connection.events.makeAsyncIterator()
        _ = try await iterator.next()
        do { _ = try await iterator.next(); XCTFail("Stream must report lost authority.") }
        catch let error as BrowserCDPConnectionError { XCTAssertEqual(error, .eventOverflow) }
        XCTAssertEqual(wire.closeCount, 1)
    }

    func testUnresolvedCancelledRequestLimitIsBounded() async throws {
        let wire = FakeBrowserCDPWire()
        var configuration = BrowserCDPConnection.Configuration()
        configuration.maximumCancelledRequests = 1
        let connection = BrowserCDPConnection(wire: wire, configuration: configuration)
        for count in 1...2 {
            let request = Task { try await connection.command(method: "DOM.getDocument") }
            _ = await wire.waitForEnqueues(count)
            request.cancel()
            do { _ = try await request.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        }
        await expectError(.cancelledRequestLimit) { try await connection.command(method: "Target.getTargets") }
        XCTAssertEqual(wire.frames.count, 2)
    }

    func testInvalidRequestAndOversizedRequestNeverReachWire() async throws {
        let wire = FakeBrowserCDPWire()
        var configuration = BrowserCDPConnection.Configuration()
        configuration.maximumMessageBytes = 128
        let connection = BrowserCDPConnection(wire: wire, configuration: configuration)
        await expectError(.invalidRequest) { try await connection.command(method: "not a method") }
        await expectError(.invalidRequest) { try await connection.command(method: "DOM.getDocument", params: Data("[]".utf8)) }
        await expectError(.invalidRequest) { try await connection.command(method: "DOM.getDocument", sessionID: "bad session") }
        let params = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "x", count: 100)])
        await expectError(.messageTooLarge) { try await connection.command(method: "DOM.getDocument", params: params) }
        XCTAssertTrue(wire.frames.isEmpty)
        await connection.close()
    }

    func testEndpointValidationDoesNotConnectAndRejectsNonLoopbackOrPageEndpoints() throws {
        for raw in ["ws://127.0.0.1:9222/devtools/browser/test-id", "ws://[::1]:9222/devtools/browser/test_id"] {
            try URLSessionBrowserCDPWire.validate(endpoint: XCTUnwrap(URL(string: raw)))
        }
        for raw in [
            "ws://localhost:9222/devtools/browser/id", "ws://192.168.1.1:9222/devtools/browser/id",
            "wss://127.0.0.1:9222/devtools/browser/id", "ws://127.0.0.1/devtools/browser/id",
            "ws://127.0.0.1:9222/devtools/page/id", "ws://127.0.0.1:9222/devtools/browser/",
            "ws://user@127.0.0.1:9222/devtools/browser/id", "ws://127.0.0.1:9222/devtools/browser/id?token=secret",
            "ws://127.0.0.1:9222/devtools/browser/id#fragment", "ws://127.0.0.1:9222/devtools/browser/a%2Fb",
        ] {
            XCTAssertThrowsError(try URLSessionBrowserCDPWire.validate(endpoint: XCTUnwrap(URL(string: raw))))
        }
    }

    func testDetachInvalidatesBeforeFollowingResponseWithoutEventConsumer() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let affected = Task { try await connection.command(method: "DOM.getDocument", sessionID: "old") }
        let one = try Self.object(await wire.waitForEnqueues(1)[0])
        let unaffected = Task { try await connection.command(method: "DOM.getDocument", sessionID: "other") }
        let two = try Self.object(await wire.waitForEnqueues(2)[1])
        try wire.inject(["method": "Target.detachedFromTarget", "params": ["sessionId": "old"]])
        try wire.inject(["id": one["id"]!, "sessionId": "old", "result": [:]])
        try wire.inject(["id": two["id"]!, "sessionId": "other", "result": [:]])
        await expectError(.sessionInvalidated) { try await affected.value }
        _ = try await unaffected.value
        do { try await connection.checkSession("old"); XCTFail("Detached session must stay revoked.") }
        catch let error as BrowserCDPConnectionError { XCTAssertEqual(error, .sessionInvalidated) }
        await expectError(.sessionInvalidated) { try await connection.command(method: "DOM.getDocument", sessionID: "old") }
        XCTAssertEqual(wire.frames.count, 2)
        XCTAssertEqual(wire.closeCount, 0)
        await connection.close()
    }

    func testTargetDestructionInvalidatesAttachmentBeforeNextResult() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let params = Data(#"{"targetId":"synthetic","flatten":true}"#.utf8)
        let attachment = Task { try await connection.command(method: "Target.attachToTarget", params: params) }
        let one = try Self.object(await wire.waitForEnqueues(1)[0])
        try wire.inject(["id": one["id"]!, "result": ["sessionId": "attached"]])
        _ = try await attachment.value
        let read = Task { try await connection.command(method: "DOM.getDocument", sessionID: "attached") }
        let two = try Self.object(await wire.waitForEnqueues(2)[1])
        try wire.inject(["method": "Target.targetDestroyed", "params": ["targetId": "synthetic"]])
        try wire.inject(["id": two["id"]!, "sessionId": "attached", "result": [:]])
        await expectError(.sessionInvalidated) { try await read.value }
        await expectError(.sessionInvalidated) { try await connection.command(method: "DOM.getDocument", sessionID: "attached") }
        XCTAssertEqual(wire.frames.count, 2)
        await connection.close()
    }

    func testDestroyedTargetCannotPublishLateAttachment() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let params = Data(#"{"targetId":"synthetic","flatten":true}"#.utf8)
        let attachment = Task { try await connection.command(method: "Target.attachToTarget", params: params) }
        let one = try Self.object(await wire.waitForEnqueues(1)[0])
        try wire.inject(["method": "Target.targetDestroyed", "params": ["targetId": "synthetic"]])
        try wire.inject(["id": one["id"]!, "result": ["sessionId": "too-late"]])
        await expectError(.targetDestroyed) { try await attachment.value }
        await expectError(.sessionInvalidated) { try await connection.command(method: "DOM.getDocument", sessionID: "too-late") }
        XCTAssertEqual(wire.frames.count, 1)
        await connection.close()
    }

    func testLocalSessionInvalidationPreservesConnectionAndOtherSessions() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let affected = Task { try await connection.command(method: "DOM.getDocument", sessionID: "old") }
        _ = await wire.waitForEnqueues(1)
        await connection.invalidateSession("old")
        await expectError(.sessionInvalidated) { try await affected.value }
        let detached = Task { try await connection.command(method: "Target.detachFromTarget", params: Data(#"{"sessionId":"old"}"#.utf8)) }
        let two = try Self.object(await wire.waitForEnqueues(2)[1])
        try wire.inject(["id": two["id"]!, "result": [:]])
        _ = try await detached.value
        XCTAssertEqual(wire.closeCount, 0)
        await connection.close()
    }

    func testFinalValidatorRefusalPreventsEnqueueAndConsumesMutationPermit() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let permit = BrowserMutationPermit()
        await expectError(.invalidRequest) {
            try await connection.command(method: "Runtime.callFunctionOn", permit: permit) {
                XCTAssertTrue(wire.frames.isEmpty)
                throw BrowserCDPConnectionError.invalidRequest
            }
        }
        XCTAssertTrue(wire.frames.isEmpty)
        do {
            _ = try await connection.command(method: "Runtime.callFunctionOn", permit: permit)
            XCTFail("A refused final validation cannot reuse approval authority.")
        } catch let error as BrowserTabBrokerError { XCTAssertEqual(error, .staleSnapshot) }
        await connection.close()
    }

    func testFinalValidatorRunsExactlyOnceBeforeSynchronousWireEnqueue() async throws {
        let wire = FakeBrowserCDPWire()
        let connection = BrowserCDPConnection(wire: wire)
        let validator = CDPTestCounter()
        let request = Task {
            try await connection.command(method: "DOM.getDocument", beforeEnqueue: {
                validator.increment()
                XCTAssertTrue(wire.frames.isEmpty)
            })
        }
        let frame = try Self.object(await wire.waitForEnqueues(1)[0])
        XCTAssertEqual(validator.value, 1)
        try wire.inject(["id": frame["id"]!, "result": [:]])
        _ = try await request.value
        XCTAssertEqual(validator.value, 1)
        XCTAssertEqual(wire.frames.count, 1)
        await connection.close()
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expectError(
        _ expected: BrowserCDPConnectionError,
        file: StaticString = #filePath, line: UInt = #line,
        _ operation: () async throws -> Data
    ) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as BrowserCDPConnectionError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line) }
    }
}

private final class CDPTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class FakeBrowserCDPWire: BrowserCDPWire, @unchecked Sendable {
    func waitUntilOpen() async throws { try Task.checkCancellation() }
    private let lock = NSLock()
    private var sent: [Data] = []
    private var queued: [Result<Data, Error>] = []
    private var reader: CheckedContinuation<Data, Error>?
    private var enqueueWaiters: [(Int, CheckedContinuation<[Data], Never>)] = []
    private var closed = false
    private var closes = 0
    private var receiveMaximum = 0
    private var sendsFail = false

    var frames: [Data] { lock.withLock { sent } }
    var closeCount: Int { lock.withLock { closes } }
    var maximumConcurrentReceives: Int { lock.withLock { receiveMaximum } }
    var failSends: Bool {
        get { lock.withLock { sendsFail } }
        set { lock.withLock { sendsFail = newValue } }
    }

    func enqueue(_ data: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let result: Result<Void, Error> = lock.withLock {
            guard !closed else { return .failure(BrowserCDPConnectionError.closed) }
            sent.append(data)
            let ready = enqueueWaiters.filter { $0.0 <= sent.count }
            enqueueWaiters.removeAll { $0.0 <= sent.count }
            for waiter in ready { waiter.1.resume(returning: sent) }
            return sendsFail ? .failure(BrowserCDPConnectionError.transportFailed) : .success(())
        }
        completion(result)
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                receiveMaximum = max(receiveMaximum, reader == nil ? 1 : 2)
                guard reader == nil else {
                    continuation.resume(throwing: BrowserCDPConnectionError.malformedMessage)
                    return
                }
                if !queued.isEmpty { continuation.resume(with: queued.removeFirst()) }
                else if closed { continuation.resume(throwing: BrowserCDPConnectionError.closed) }
                else { reader = continuation }
            }
        }
    }

    func waitForEnqueues(_ count: Int) async -> [Data] {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if sent.count >= count { continuation.resume(returning: sent) }
                else { enqueueWaiters.append((count, continuation)) }
            }
        }
    }

    func inject(_ object: [String: Any]) throws {
        inject(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    func inject(_ data: Data) { deliver(.success(data)) }
    func failReceive() { deliver(.failure(BrowserCDPConnectionError.transportFailed)) }

    private func deliver(_ result: Result<Data, Error>) {
        lock.withLock {
            if let reader {
                self.reader = nil
                reader.resume(with: result)
            } else { queued.append(result) }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            closes += 1
            let waiting = reader
            reader = nil
            waiting?.resume(throwing: BrowserCDPConnectionError.closed)
        }
    }
}

import Foundation
import XCTest
@testable import Computa

final class WebModelFailureDiagnosticTests: XCTestCase {
    func testAuthenticatedHTTPFailureRetainsTheExactFiniteGateDiagnosticForItsOwnTaskOnce() async throws {
        let server = WebModelServer()
        await server.configureEmbeddedTransport(FailureReceiptTransport(mode: .quota))
        do {
            let base = try await server.start()
            let (body, status) = try await Self.post(base, server: server, taskID: "receipt-task")
            XCTAssertEqual(status, 429)
            let diagnostic = try XCTUnwrap(server.takeFailureDiagnostic(taskID: "receipt-task"))
            XCTAssertEqual(Data(diagnostic.utf8), body, "The local receipt must preserve the actual standardized HTTP error body")
            let fields = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(diagnostic.utf8)) as? [String: Any])?["error"] as? [String: Any])
            XCTAssertEqual(fields["code"] as? String, "website_usage_limit")
            XCTAssertEqual(fields["required_action"] as? String, "wait_for_quota_reset")
            XCTAssertEqual(fields["retryable"] as? Bool, false)
            XCTAssertNil(server.takeFailureDiagnostic(taskID: "other-task"))
            XCTAssertNil(server.takeFailureDiagnostic(taskID: "receipt-task"))
            _ = await server.shutdown()
        } catch { _ = await server.shutdown(); throw error }
    }

    func testNewTurnSuccessCleanupAndShutdownEachClearPendingDiagnostics() async throws {
        for boundary in ["turn", "success", "cleanup", "shutdown"] {
            let server = WebModelServer()
            await server.configureEmbeddedTransport(FailureReceiptTransport(mode: .failureThenSuccess))
            do {
                let base = try await server.start()
                let (_, failureStatus) = try await Self.post(base, server: server, taskID: boundary)
                XCTAssertEqual(failureStatus, 429)
                switch boundary {
                case "turn": await server.registerEvidenceThread(taskID: boundary, threadID: UUID().uuidString)
                case "success":
                    let (_, successStatus) = try await Self.post(base, server: server, taskID: boundary)
                    XCTAssertEqual(successStatus, 200)
                case "cleanup": _ = await server.finish(taskID: boundary)
                default: _ = await server.shutdown()
                }
                XCTAssertNil(server.takeFailureDiagnostic(taskID: boundary), "The \(boundary) boundary must not leak a prior turn's error")
                _ = await server.shutdown()
            } catch { _ = await server.shutdown(); throw error }
        }
    }

    func testLateHTTPFailureCannotRestoreADiagnosticAfterTheNextTurnHasRegistered() async throws {
        let server = WebModelServer()
        let transport = FailureReceiptTransport(mode: .pausedQuota)
        await server.configureEmbeddedTransport(transport)
        do {
            let base = try await server.start()
            let request = Task.detached {
                try await WebModelFailureDiagnosticTests.post(base, server: server, taskID: "racing-task")
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while !(await transport.hasEntered()), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard await transport.hasEntered() else {
                request.cancel()
                throw NSError(domain: "FailureReceiptFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The HTTP fixture did not enter its bounded send"])
            }
            await server.registerEvidenceThread(taskID: "racing-task", threadID: UUID().uuidString)
            await transport.release()
            let (_, status) = try await request.value
            XCTAssertEqual(status, 429)
            XCTAssertNil(server.takeFailureDiagnostic(taskID: "racing-task"), "A revoked writer epoch cannot populate the new turn")
            _ = await server.shutdown()
        } catch { await transport.release(); _ = await server.shutdown(); throw error }
    }

    func testArbitraryTransportProseIsNotPromotedIntoALocalFailureReceipt() async throws {
        let server = WebModelServer()
        await server.configureEmbeddedTransport(FailureReceiptTransport(mode: .arbitraryError))
        do {
            let base = try await server.start()
            let (_, status) = try await Self.post(base, server: server, taskID: "untrusted-task")
            XCTAssertEqual(status, 500)
            XCTAssertNil(server.takeFailureDiagnostic(taskID: "untrusted-task"))
            _ = await server.shutdown()
        } catch { _ = await server.shutdown(); throw error }
    }

    func testDiagnosticStoreRevokesWritersAndBoundsBytesAndTaskRetention() throws {
        let store = WebModelFailureDiagnosticStore()
        let body = try WebModelServer.errorBody(for: EmbeddedWebModelTransport.Failure.usageLimited(.chatgpt))
        let oldEpoch = store.epoch(taskID: "same-task")
        store.record(body, taskID: "same-task", epoch: oldEpoch)
        store.clear(taskID: "same-task")
        store.record(body, taskID: "same-task", epoch: oldEpoch)
        XCTAssertNil(store.take(taskID: "same-task"))
        let newEpoch = store.epoch(taskID: "same-task")
        XCTAssertNotEqual(oldEpoch, newEpoch)
        store.record(Data(repeating: 0x41, count: WebModelFailureDiagnosticStore.maximumDiagnosticBytes + 1),
                     taskID: "same-task", epoch: newEpoch)
        XCTAssertNil(store.take(taskID: "same-task"))
        store.record(body, taskID: "same-task", epoch: newEpoch)
        XCTAssertEqual(store.take(taskID: "same-task"), body)
        XCTAssertNil(store.take(taskID: "same-task"))
        store.removeAll()
        store.record(body, taskID: "same-task", epoch: newEpoch)
        XCTAssertNil(store.take(taskID: "same-task"))
        for index in 0...WebModelFailureDiagnosticStore.maximumEntries {
            let taskID = "bounded-\(index)"
            let epoch = store.epoch(taskID: taskID)
            store.record(body, taskID: taskID, epoch: epoch)
        }
        XCTAssertNil(store.take(taskID: "bounded-0"), "The oldest inactive task must be evicted at the fixed memory bound")
        for index in 1...WebModelFailureDiagnosticStore.maximumEntries {
            XCTAssertEqual(store.take(taskID: "bounded-\(index)"), body)
        }
    }

    private static func post(_ base: URL, server: WebModelServer, taskID: String) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer " + server.bearerToken, forHTTPHeaderField: "Authorization")
        request.setValue(taskID, forHTTPHeaderField: "X-Computa-Task-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": LocalModelCatalog.chatGPTBrowserModelID, "input": "Synthetic failure receipt check", "stream": true,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
    }
}

private actor FailureReceiptTransport: WebModelTransport {
    enum Mode: Sendable { case quota, failureThenSuccess, pausedQuota, arbitraryError }
    let mode: Mode
    let token = UUID().uuidString
    var sends = 0
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    init(mode: Mode) { self.mode = mode }
    func hasEntered() -> Bool { entered }
    func release() { continuation?.resume(); continuation = nil }
    func request(operation: String, params: Data) async throws -> Data {
        let result: [String: Any]
        switch operation {
        case "webProviderStart": result = ["sessionToken": token, "state": "ready"]
        case "webProviderSend":
            sends += 1
            if mode == .pausedQuota {
                entered = true
                await withCheckedContinuation { continuation = $0 }
            }
            if mode == .arbitraryError {
                throw NSError(domain: "SyntheticUnknownTransport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "UNTRUSTED_PAGE_COPY_CANARY"])
            }
            if mode != .failureThenSuccess || sends == 1 {
                throw EmbeddedWebModelTransport.Failure.usageLimited(.chatgpt)
            }
            result = ["state": "running"]
        case "webProviderPoll": result = ["state": "complete", "text": #"{"type":"message","text":"OK"}"#]
        case "webProviderFinish", "webProviderCancel": result = ["cleanup": "not_created"]
        default: throw WebModelServer.Failure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: syntheticPreparedWebsiteSnapshot(result))
    }
}

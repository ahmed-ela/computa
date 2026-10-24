import Foundation
import XCTest
@testable import Computa

final class WebModelFailureDiagnosticTests: XCTestCase {
    func testNativeBrowserFailuresHaveClosedNonretryableDiagnostics() throws {
        let cases: [(any Error, WebModelServer.NativeBrowserFailure)] = [
            (ChatGPTInferenceCookieSeed.Failure.unavailable, .profileUnavailable),
            (ChatGPTInferenceCookieSeed.Failure.bounds, .profileBounds),
            (ChatGPTInferenceCookieSeed.Failure.invalidSource, .profileInvalidSource),
            (ChatGPTInferenceCookieSeed.Failure.destinationNotEmpty, .profileDestinationNotEmpty),
            (ChatGPTInferenceCookieSeed.Failure.verificationFailed, .profileVerificationFailed),
            (ChatGPTInferenceCookieSeed.Failure.deadline, .profileDeadline),
            (EmbeddedBrowserSession.Failure.tabLimit(Int.max), .tabLimit),
            (EmbeddedBrowserSession.Failure.tabClosed, .tabClosed),
            (EmbeddedBrowserSession.Failure.sessionClosed, .sessionClosed),
            (EmbeddedBrowserSession.Failure.modelTabPrivate, .modelTabPrivate),
            (EmbeddedBrowserSession.Failure.modelPopupUnsupported, .modelPopupUnsupported),
            (EmbeddedBrowserSession.Failure.toolPopupUnsupported, .toolPopupUnsupported),
            (EmbeddedBrowserSession.Failure.popupProfileMismatch, .popupProfileMismatch),
            (EmbeddedBrowserSession.Failure.inspectionUnavailable, .inspectionUnavailable),
            (EmbeddedBrowserSession.Failure.cookieMaintenancePending, .cookieMaintenancePending),
        ]
        XCTAssertEqual(Set(cases.map { $0.1 }), Set(WebModelServer.NativeBrowserFailure.allCases))
        for (native, expected) in cases {
            XCTAssertEqual(WebModelServer.NativeBrowserFailure(native), expected)
            XCTAssertEqual(WebModelServer.errorPresentation(for: native).status, "400 Bad Request",
                "Known local failures must not invite the engine's HTTP 5xx retry/high-demand path")
            let data = try WebModelServer.errorBody(for: native)
            let fields = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])
            XCTAssertEqual(Set(fields.keys), ["type", "message", "code", "param", "reason", "retryable"])
            XCTAssertEqual(fields["type"] as? String, "model_error")
            XCTAssertEqual(fields["code"] as? String, expected.code)
            XCTAssertEqual(fields["reason"] as? String, expected.rawValue)
            XCTAssertEqual(fields["message"] as? String, expected.localizedDescription)
            XCTAssertEqual(fields["retryable"] as? Bool, false)
            XCTAssertTrue(fields["param"] is NSNull)
            XCTAssertLessThan(data.count, 512)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(String(Int.max)))
        }
        let arbitrary = NSError(domain: "PRIVATE_COOKIE_DOMAIN", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "chatgpt_profile_preparation_failed verification_failed PRIVATE_COOKIE_VALUE"])
        XCTAssertNil(WebModelServer.NativeBrowserFailure(arbitrary), "Matching prose never creates native provenance")
        XCTAssertEqual(WebModelServer.errorPresentation(for: arbitrary).code, "internal_error")
    }

    func testNativeStartupFailureIsRecordedWithoutSubmissionOrAssumedCleanup() async throws {
        let failures: [any Error] = [ChatGPTInferenceCookieSeed.Failure.verificationFailed,
                                   EmbeddedBrowserSession.Failure.cookieMaintenancePending]
        for failure in failures {
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
            let transport = StartupFailureReceiptTransport(failure: failure)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport, defaultChatChoice: syntheticChatGPTChoice))
            do {
                let base = try await server.start()
                let (body, status) = try await Self.post(base, server: server, taskID: "native-startup")
                XCTAssertEqual(status, 400)
                let taskID = websiteInferenceFixtureTaskID("native-startup")
                let diagnostic = try XCTUnwrap(server.takeFailureDiagnostic(taskID: taskID))
                XCTAssertEqual(Data(diagnostic.utf8), body)
                XCTAssertNil(server.takeFailureDiagnostic(taskID: taskID))
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: WebModelServer.errorBody(for: failure)) as? [String: Any])
                XCTAssertTrue(NSDictionary(dictionary: decoded).isEqual(to: expected))
                let operations = await transport.operations()
                XCTAssertEqual(operations, ["webProviderStart"], "No Send, poll, or retried startup follows the native failure")
                let issues = await server.fixtureFinish(taskID: "native-startup")
                XCTAssertTrue(issues.contains(WebModelServer.Failure.startOwnershipUnconfirmed.localizedDescription),
                    "A finite diagnostic cannot certify no owned tab when startup returned no token")
                let afterCleanup = await transport.operations()
                XCTAssertEqual(afterCleanup, operations, "Cleanup cannot invent a session token or replay startup")
                _ = await server.shutdown()
            } catch { _ = await server.shutdown(); throw error }
        }
    }

    func testAuthenticatedHTTPFailureRetainsTheExactFiniteGateDiagnosticForItsOwnTaskOnce() async throws {
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(FailureReceiptTransport(mode: .quota), defaultChatChoice: syntheticChatGPTChoice))
        do {
            let base = try await server.start()
            let (body, status) = try await Self.post(base, server: server, taskID: "receipt-task")
            XCTAssertEqual(status, 429)
            let diagnostic = try XCTUnwrap(server.takeFailureDiagnostic(taskID: websiteInferenceFixtureTaskID("receipt-task")))
            XCTAssertEqual(Data(diagnostic.utf8), body, "The local receipt must preserve the actual standardized HTTP error body")
            let fields = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(diagnostic.utf8)) as? [String: Any])?["error"] as? [String: Any])
            XCTAssertEqual(fields["code"] as? String, "website_usage_limit")
            XCTAssertEqual(fields["required_action"] as? String, "wait_for_quota_reset")
            XCTAssertEqual(fields["retryable"] as? Bool, false)
            XCTAssertNil(server.takeFailureDiagnostic(taskID: websiteInferenceFixtureTaskID("other-task")))
            XCTAssertNil(server.takeFailureDiagnostic(taskID: websiteInferenceFixtureTaskID("receipt-task")))
            _ = await server.shutdown()
        } catch { _ = await server.shutdown(); throw error }
    }

    func testNewTurnSuccessCleanupAndShutdownEachClearPendingDiagnostics() async throws {
        for boundary in ["turn", "success", "cleanup", "shutdown"] {
            let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
            await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(FailureReceiptTransport(mode: .failureThenSuccess), defaultChatChoice: syntheticChatGPTChoice))
            do {
                let base = try await server.start()
                let (_, failureStatus) = try await Self.post(base, server: server, taskID: boundary)
                XCTAssertEqual(failureStatus, 429)
                switch boundary {
                case "turn": await server.registerEvidenceThread(taskID: websiteInferenceFixtureTaskID(boundary), threadID: UUID().uuidString)
                case "success":
                    let issues = await server.fixtureFinish(taskID: boundary)
                    XCTAssertEqual(issues, [], "A failed lease must close before the following successful inference")
                    let (_, successStatus) = try await Self.post(base, server: server, taskID: boundary)
                    XCTAssertEqual(successStatus, 200)
                case "cleanup": _ = await server.fixtureFinish(taskID: boundary)
                default: _ = await server.shutdown()
                }
                XCTAssertNil(server.takeFailureDiagnostic(taskID: websiteInferenceFixtureTaskID(boundary)), "The \(boundary) boundary must not leak a prior turn's error")
                _ = await server.shutdown()
            } catch { _ = await server.shutdown(); throw error }
        }
    }

    func testLateHTTPFailureCannotRestoreADiagnosticAfterTheNextTurnHasRegistered() async throws {
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        let transport = FailureReceiptTransport(mode: .pausedQuota)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(transport, defaultChatChoice: syntheticChatGPTChoice))
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
            await server.registerEvidenceThread(taskID: websiteInferenceFixtureTaskID("racing-task"), threadID: UUID().uuidString)
            await transport.release()
            let (_, status) = try await request.value
            XCTAssertEqual(status, 429)
            XCTAssertNil(server.takeFailureDiagnostic(taskID: websiteInferenceFixtureTaskID("racing-task")), "A revoked writer epoch cannot populate the new turn")
            _ = await server.shutdown()
        } catch { await transport.release(); _ = await server.shutdown(); throw error }
    }

    func testArbitraryTransportProseIsNotPromotedIntoALocalFailureReceipt() async throws {
        let server = try await makeWebsiteInferenceFixtureServer(testCase: self)
        await server.configureEmbeddedTransport(WebsiteInferenceFixtureTransport(FailureReceiptTransport(mode: .arbitraryError), defaultChatChoice: syntheticChatGPTChoice))
        do {
            let base = try await server.start()
            let (_, status) = try await Self.post(base, server: server, taskID: "untrusted-task")
            XCTAssertEqual(status, 500)
            XCTAssertNil(server.takeFailureDiagnostic(taskID: websiteInferenceFixtureTaskID("untrusted-task")))
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
        let nativeTaskID = try await bindWebsiteInferenceFixtureTurn(server, taskID: taskID)
        var request = URLRequest(url: base.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer " + server.bearerToken, forHTTPHeaderField: "Authorization")
        request.setValue(nativeTaskID, forHTTPHeaderField: "X-Computa-Task-ID")
        request.setValue(try websiteInferenceFixtureMetadata(taskID: taskID), forHTTPHeaderField: "x-codex-turn-metadata")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": syntheticChatGPTModelID, "input": "Synthetic failure receipt check", "stream": true,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
    }
}

private actor StartupFailureReceiptTransport: WebModelTransport {
    let failure: any Error
    private var ledger: [String] = []
    init(failure: any Error) { self.failure = failure }
    func operations() -> [String] { ledger }
    func request(operation: String, params: Data) async throws -> Data {
        ledger.append(operation)
        guard operation == "webProviderStart" else { throw WebModelServer.Failure.invalidRequest }
        throw failure
    }
}

private actor FailureReceiptTransport: WebModelTransport {
    enum Mode: Sendable { case quota, failureThenSuccess, pausedQuota, arbitraryError }
    let mode: Mode
    var token = UUID().uuidString
    var sends = 0
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    init(mode: Mode) { self.mode = mode }
    func hasEntered() -> Bool { entered }
    func release() { continuation?.resume(); continuation = nil }
    func request(operation: String, params: Data) async throws -> Data {
        let result: [String: Any]
        switch operation {
        case "webProviderStart": token = UUID().uuidString; result = ["sessionToken": token, "state": "ready"]
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

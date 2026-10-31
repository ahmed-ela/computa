import AppKit
import Darwin
import WebKit
import XCTest
@testable import Computa

@MainActor
final class GeminiCAPTCHADiagnosticIntegrationTests: XCTestCase {
    func testChallengeResponseSavesSanitizedFileBeforeImmediateClose() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try Fixture(directory: directory)
        defer { f.session.shutdown() }
        let generation = try XCTUnwrap(f.session.documentGeneration(for: f.id))
        var saved: [URL] = []
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { report in
            XCTAssertTrue(f.session.webView(for: f.id) === f.view, "Persistence must precede removal from the session")
            XCTAssertEqual(f.session.documentGeneration(for: f.id), generation)
            let url = try GeminiCAPTCHADiagnosticStore(directory: directory).save(report)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            saved.append(url)
            return url
        }
        var request = URLRequest(url: URL(string: "https://gemini.google.com/app?PRIVATE_QUERY")!)
        request.setValue("PRIVATE_COOKIE_VALUE", forHTTPHeaderField: "Cookie")
        request.setValue("PRIVATE_AUTH_VALUE", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("PRIVATE_BODY".utf8)
        f.session.observeGeminiNavigationRequestForTesting(request, isMainFrame: true, view: f.view, tabID: f.id)
        f.observe(try response(status: 429, headers: ["Set-Cookie": "PRIVATE_SET_COOKIE", "X-Private": "PRIVATE_HEADER"]))
        XCTAssertEqual(saved.count, 1, "The response callback itself must save, without requiring cleanup or another poll")
        f.session.closeTab(f.id)
        XCTAssertNil(f.session.webView(for: f.id))
        XCTAssertEqual(saved.count, 1)
        let data = try Data(contentsOf: XCTUnwrap(saved.first))
        let report = try object(data)
        XCTAssertEqual(report["kind"] as? String, "gemini_captcha_diagnostic")
        XCTAssertEqual(report["trigger"] as? String, "response")
        XCTAssertEqual((report["generation"] as? String).flatMap(UUID.init(uuidString:)), generation)
        XCTAssertEqual(report["role"] as? String, "model")
        let events = try navigationEvents(report)
        XCTAssertEqual(events.compactMap { $0["kind"] as? String }, ["request", "response"])
        XCTAssertEqual((events.last?["response"] as? [String: Any])?["statusCode"] as? Int, 429)
        let requestMetadata = try XCTUnwrap(events.first?["request"] as? [String: Any])
        XCTAssertEqual(requestMetadata["cookie"] as? String, "present_in_request_metadata")
        XCTAssertEqual(report["requestCookiesTransmitted"] as? String, "unknown")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(try files(in: directory), saved)
    }

    func testDuplicateTriggersKeepOnlyTheFirstFrozenIncident() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        var reports: [Data] = []
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { report in
            reports.append(try report.encodedData())
            return self.unusedReceiptURL
        }
        f.observe(try response(status: 429))
        for _ in 0..<3 {
            f.observe(try response(status: 429))
            f.session.captureGeminiCAPTCHA(tabID: f.id, view: f.view, trigger: .transport)
            f.session.captureGeminiCAPTCHA(tabID: f.id, view: f.view, trigger: .humanCheckpoint)
        }
        f.session.closeTab(f.id)
        f.session.closeTab(f.id)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(try navigationEvents(object(XCTUnwrap(reports.first))).count, 1)
        XCTAssertNil(f.session.webView(for: f.id))
    }

    func testLateChallengeResponseAddsOneLinkedSupplementWithoutReplacingFirstCapture() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        var reports: [GeminiCAPTCHADiagnostic.Report] = []
        var bytes: [Data] = []
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { report in
            XCTAssertTrue(f.session.webView(for: f.id) === f.view)
            reports.append(report)
            bytes.append(try report.encodedData())
            return self.unusedReceiptURL
        }
        f.session.captureGeminiCAPTCHA(tabID: f.id, view: f.view, trigger: .transport)
        let first = try XCTUnwrap(reports.first)
        let firstBytes = try XCTUnwrap(bytes.first)
        XCTAssertEqual(first.trigger, .transport)
        XCTAssertNil(first.precedingCaptureID)
        f.observe(try response(status: 429))
        XCTAssertEqual(reports.count, 2)
        let supplement = try XCTUnwrap(reports.last)
        XCTAssertEqual(supplement.trigger, .response)
        XCTAssertEqual(supplement.precedingCaptureID, first.id)
        XCTAssertNotEqual(supplement.id, first.id)
        XCTAssertEqual(supplement.generation, first.generation)
        XCTAssertEqual(try navigationEvents(object(firstBytes)).count, 0)
        let events = try navigationEvents(object(supplement.encodedData()))
        XCTAssertEqual((events.last?["response"] as? [String: Any])?["statusCode"] as? Int, 429)
        for _ in 0..<3 {
            f.observe(try response(status: 429))
            f.session.captureGeminiCAPTCHA(tabID: f.id, view: f.view, trigger: .transport)
        }
        f.session.closeTab(f.id)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(bytes.first, firstBytes)
        XCTAssertNil(f.session.webView(for: f.id))
    }

    func testFailedFirstSaveRetriesOnceAtCloseUsingIdenticalEvidence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try Fixture(directory: directory)
        defer { f.session.shutdown() }
        var attempted: [Data] = []
        var saved: URL?
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { report in
            XCTAssertTrue(f.session.webView(for: f.id) === f.view)
            attempted.append(try report.encodedData())
            if attempted.count == 1 { throw TestFailure.storage }
            let url = try GeminiCAPTCHADiagnosticStore(directory: directory).save(report)
            saved = url
            return url
        }
        f.observe(try response(status: 429))
        for _ in 0..<4 { f.session.captureGeminiCAPTCHA(tabID: f.id, view: f.view, trigger: .transport) }
        XCTAssertEqual(attempted.count, 1, "Repeated checks must not retry a failing disk")
        // A later document must not replace the first failed incident at teardown.
        try f.session.navigate(tabID: f.id, to: URL(string: "about:blank")!)
        f.session.closeTab(f.id)
        XCTAssertNil(f.session.webView(for: f.id))
        XCTAssertEqual(attempted.count, 2)
        XCTAssertEqual(attempted.first, attempted.last)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved)), attempted.first)
        XCTAssertEqual(try files(in: directory).count, 1)
    }

    func testGenerationAdvanceWithOldChallengeURLStillRetriesOriginalIncidentAtClose() async throws {
        let f = try Fixture(viewFactory: { RetainingURLWebView(frame: .zero, configuration: $0) })
        defer { f.session.shutdown() }
        let challengeURL = try XCTUnwrap(URL(string: "https://www.google.com/sorry/index"))
        f.view.loadHTMLString("<!doctype html><title>Local retained URL</title><p>Local only</p>", baseURL: challengeURL)
        let deadline = ContinuousClock.now + .seconds(5)
        while f.view.isLoading || f.view.url != challengeURL {
            guard ContinuousClock.now < deadline else { throw TestFailure.localDocumentTimeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        var attempted: [Data] = []
        var ids: [UUID] = []
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { report in
            XCTAssertTrue(f.session.webView(for: f.id) === f.view)
            attempted.append(try report.encodedData())
            ids.append(report.id)
            if attempted.count == 1 { throw TestFailure.storage }
            return self.unusedReceiptURL
        }
        f.observe(try response(challengeURL.absoluteString, status: 429))
        let originalGeneration = f.session.documentGeneration(for: f.id)
        // The public navigation path advances native generation, while this
        // local view deliberately retains the old URL without issuing a load.
        try f.session.navigate(tabID: f.id, to: URL(string: "about:blank")!)
        XCTAssertNotEqual(f.session.documentGeneration(for: f.id), originalGeneration)
        XCTAssertEqual(f.view.url, challengeURL)
        f.session.closeTab(f.id)
        XCTAssertEqual(attempted.count, 2)
        XCTAssertEqual(attempted.first, attempted.last)
        XCTAssertEqual(ids.first, ids.last)
        XCTAssertNil(f.session.webView(for: f.id))
    }

    func testPermanentStorageFailureDoesNotPreventCloseOrAlterVerification() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        f.session.recordHumanVerificationRequired(provider: "gemini")
        let checkpoints = f.session.savedHumanVerificationCheckpointIDs
        var attempts = 0
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { _ in
            attempts += 1
            XCTAssertTrue(f.session.webView(for: f.id) === f.view)
            throw TestFailure.storage
        }
        f.observe(try response(status: 429))
        f.session.closeTab(f.id)
        f.session.closeTab(f.id)
        f.session.shutdown()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(f.session.webView(for: f.id))
        XCTAssertEqual(f.session.savedHumanVerificationCheckpointIDs, checkpoints)
    }

    func testShutdownRetriesPendingSaveBeforeReleasingTheView() throws {
        let f = try Fixture()
        var attempts: [Data] = []
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { report in
            XCTAssertTrue(f.session.webView(for: f.id) === f.view)
            attempts.append(try report.encodedData())
            if attempts.count == 1 { throw TestFailure.storage }
            return self.unusedReceiptURL
        }
        f.observe(try response(status: 429))
        f.session.shutdown()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first, attempts.last)
        XCTAssertNil(f.session.webView(for: f.id))
    }

    func testCancelledCallerStillSavesSynchronouslyBeforeClose() async throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        var saved = 0
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { _ in
            XCTAssertTrue(Task.isCancelled)
            XCTAssertTrue(f.session.webView(for: f.id) === f.view)
            saved += 1
            return self.unusedReceiptURL
        }
        let challenge = try response(status: 429)
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            f.observe(challenge)
            f.session.closeTab(f.id)
        }
        await caller.value
        XCTAssertEqual(saved, 1)
        XCTAssertNil(f.session.webView(for: f.id))
    }

    func testForeignClosedSubframeAndUntrustedCallbacksDoNotCreateOrPolluteAnIncident() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        var reports: [GeminiCAPTCHADiagnostic.Report] = []
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { report in reports.append(report); return self.unusedReceiptURL }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let foreign = WKWebView(frame: .zero, configuration: configuration)
        let challenge = try response(status: 429)
        f.session.observeGeminiNavigationResponseForTesting(response: challenge, isMainFrame: true, view: foreign, tabID: f.id)
        f.session.observeGeminiNavigationResponseForTesting(response: challenge, isMainFrame: true, view: f.view, tabID: UUID())
        f.session.observeGeminiNavigationResponseForTesting(response: challenge, isMainFrame: false, view: f.view, tabID: f.id)
        let request = URLRequest(url: URL(string: "https://gemini.google.com/app")!)
        f.session.observeGeminiNavigationRequestForTesting(request, isMainFrame: false, view: f.view, tabID: f.id)
        f.session.observeGeminiNavigationRequestForTesting(request, isMainFrame: true, view: foreign, tabID: f.id)
        for url in ["http://www.google.com/sorry", "https://www.google.com.evil.invalid/sorry", "https://user:PRIVATE@www.google.com/sorry", "https://www.google.com:444/sorry", "https://www.google.com/sorry-evil"] {
            f.observe(try response(url, status: 429))
        }
        XCTAssertTrue(reports.isEmpty)
        f.observe(challenge)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(try navigationEvents(object(XCTUnwrap(reports.first).encodedData())).count, 1)
        f.session.closeTab(f.id)
        f.observe(challenge)
        f.session.captureGeminiCAPTCHA(tabID: f.id, view: f.view, trigger: .transport)
        XCTAssertEqual(reports.count, 1)
    }

    func testExhaustedResponseLogBudgetsStillPersistTheChallengeResponse() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        var logs: [String] = []
        var reports: [GeminiCAPTCHADiagnostic.Report] = []
        f.session.setGeminiNavigationResponseObserverForTesting { logs.append($0) }
        let instant = ContinuousClock.now
        f.session.setGeminiNavigationResponseClockForTesting { instant }
        f.session.setGeminiCAPTCHADiagnosticWriterForTesting { report in reports.append(report); return self.unusedReceiptURL }
        let healthy = try response("https://gemini.google.com/app", status: 200)
        for index in 0..<6 {
            let id = index == 0 ? f.id : try f.session.createUnloadedModelTabForTesting()
            let view = try XCTUnwrap(f.session.webView(for: id))
            for _ in 0..<2 { f.session.observeGeminiNavigationResponseForTesting(response: healthy, isMainFrame: true, view: view, tabID: id) }
        }
        XCTAssertEqual(logs.count, 12)
        f.observe(try response(status: 429))
        XCTAssertEqual(logs.count, 12, "Both the per-generation and session OSLog budgets are exhausted")
        XCTAssertEqual(reports.count, 1)
        let events = try navigationEvents(object(XCTUnwrap(reports.first).encodedData()))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual((events.last?["response"] as? [String: Any])?["statusCode"] as? Int, 429)
    }

    func testTransportRejectionPersistsBeforeCancelAndLeavesInheritedGateWithoutNewCapture() async throws {
        let f = try TransportFixture()
        defer { f.browser.shutdown() }
        var reports: [GeminiCAPTCHADiagnostic.Report] = []
        f.browser.setGeminiCAPTCHADiagnosticWriterForTesting { report in
            XCTAssertNotNil(f.browser.webView(for: report.tabID))
            reports.append(report)
            return self.unusedReceiptURL
        }
        let token = try await f.start()
        do { _ = try await call(f.transport, "webProviderPoll", ["sessionToken": token]); XCTFail("Expected the observed checkpoint") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.trigger, .transport)
        XCTAssertTrue(f.browser.savedHumanVerificationProviders.contains("gemini"))
        let receipt = try await call(f.transport, "webProviderCancel", ["sessionToken": token])
        XCTAssertEqual(receipt["cleanup"] as? String, "not_created")
        XCTAssertNil(f.browser.webView(for: try XCTUnwrap(f.created.first)))
        XCTAssertEqual(reports.count, 1)
        for _ in 0..<2 {
            do { _ = try await call(f.transport, "webProviderStart", ["provider": "gemini"]); XCTFail("Saved gate must block admission") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        }
        XCTAssertEqual(f.created.count, 1)
        XCTAssertEqual(reports.count, 1, "An inherited checkpoint has no new failing page to capture")
        XCTAssertNotNil(f.browser.webView(for: f.humanID))
    }

    func testCleanupFirstTransportCaptureSurvivesCallerCancellationAndStorageFailure() async throws {
        for storageFails in [false, true] {
            let f = try TransportFixture()
            defer { f.browser.shutdown() }
            var attempts: [Data] = []
            f.browser.setGeminiCAPTCHADiagnosticWriterForTesting { report in
                XCTAssertNotNil(f.browser.webView(for: report.tabID))
                attempts.append(try report.encodedData())
                if storageFails { throw TestFailure.storage }
                return self.unusedReceiptURL
            }
            let token = try await f.start()
            let params = try JSONSerialization.data(withJSONObject: ["sessionToken": token])
            let caller = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.transport.request(operation: "webProviderCancel", params: params)
            }
            let data = try await caller.value
            let receipt = try object(data)
            XCTAssertEqual(receipt["cleanup"] as? String, "not_created")
            XCTAssertEqual(receipt["state"] as? String, "finished")
            XCTAssertEqual(attempts.count, storageFails ? 2 : 1)
            XCTAssertEqual(attempts.first, attempts.last)
            XCTAssertEqual(try object(XCTUnwrap(attempts.first))["trigger"] as? String, "transport")
            XCTAssertTrue(f.browser.savedHumanVerificationProviders.contains("gemini"))
            XCTAssertNil(f.browser.webView(for: try XCTUnwrap(f.created.first)))
            XCTAssertNotNil(f.browser.webView(for: f.humanID))
        }
    }

    private enum TestFailure: Error { case storage, localDocumentTimeout }
    private var unusedReceiptURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("unused-gemini-diagnostic-test-receipt") }
    private func temporaryDirectory() throws -> URL {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("GeminiCAPTCHAIntegration-\(UUID())", isDirectory: true)
    }
    private func files(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }
    private func response(_ url: String = "https://www.google.com/sorry/index?PRIVATE_QUERY", status: Int,
                          headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: url)), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func navigationEvents(_ report: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap((report["navigation"] as? [String: Any])?["events"] as? [[String: Any]])
    }
    private func call(_ transport: EmbeddedWebModelTransport, _ operation: String, _ params: [String: String]) async throws -> [String: Any] {
        let parameters = try JSONSerialization.data(withJSONObject: params)
        let data = try await transport.request(operation: operation, params: parameters)
        return try object(data)
    }

    @MainActor private final class Fixture {
        let session: EmbeddedBrowserSession
        let id: UUID
        let view: WKWebView
        init(directory: URL? = nil, viewFactory: (@MainActor (WKWebViewConfiguration) -> WKWebView)? = nil) throws {
            session = EmbeddedBrowserSession(persistent: false, geminiDiagnosticDirectory: directory)
            id = try session.createUnloadedModelTabForTesting(viewFactory: viewFactory)
            view = try XCTUnwrap(session.webView(for: id))
            view.navigationDelegate = nil
        }
        func observe(_ response: URLResponse) {
            session.observeGeminiNavigationResponseForTesting(response: response, isMainFrame: true, view: view, tabID: id)
        }
    }

    @MainActor private final class RetainingURLWebView: WKWebView {
        override func load(_ request: URLRequest) -> WKNavigation? { nil }
    }

    /// The ordinary native transport sees an actual local WebKit document at a
    /// challenge URL. Detaching its navigation delegate isolates the transport
    /// observation path from the separately covered response-policy hook.
    @MainActor private final class TransportFixture {
        let browser = EmbeddedBrowserSession(persistent: false)
        let humanID: UUID
        var created: [UUID] = []
        private(set) var transport: EmbeddedWebModelTransport!
        init() throws {
            humanID = try browser.createTab()
            transport = EmbeddedWebModelTransport(browser: browser, geminiPostBlockDiagnostic: false, createTabForTesting: { [unowned self] _ in
                let id = try self.browser.createUnloadedModelTabForTesting()
                let view = try XCTUnwrap(self.browser.webView(for: id))
                view.navigationDelegate = nil
                view.loadHTMLString("<!doctype html><title>Local challenge fixture</title><p>Local only</p>",
                                    baseURL: URL(string: "https://www.google.com/sorry/index?PRIVATE_QUERY"))
                self.created.append(id)
                return id
            })
        }
        func start() async throws -> String {
            let data = try await transport.request(operation: "webProviderStart", params: Data(#"{"provider":"gemini"}"#.utf8))
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let token = try XCTUnwrap(reply["sessionToken"] as? String)
            let view = try XCTUnwrap(browser.webView(for: XCTUnwrap(created.last)))
            let deadline = ContinuousClock.now + .seconds(5)
            while view.isLoading || view.url?.host != "www.google.com" {
                guard ContinuousClock.now < deadline else { throw TestFailure.localDocumentTimeout }
                try await Task.sleep(for: .milliseconds(10))
            }
            return token
        }
    }
}

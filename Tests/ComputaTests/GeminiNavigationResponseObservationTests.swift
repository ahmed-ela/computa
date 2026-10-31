import AppKit
import Network
import WebKit
import XCTest
@testable import Computa

@MainActor
final class GeminiNavigationResponseObservationTests: XCTestCase {
    func testTrustedMainFrameResponseIsFiniteAndCannotChangeNavigationOrVerification() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        f.session.recordHumanVerificationRequired(provider: "gemini")
        let checkpoints = f.session.savedHumanVerificationCheckpointIDs
        let generation = f.session.documentGeneration(for: f.id)
        let tabs = f.session.tabs.map(\.id)
        var recoveries = 0
        f.session.onHumanVerificationRecoveryCandidate = { _ in recoveries += 1 }
        let response = try http("https://www.google.com/sorry/index?continue=PRIVATE_QUERY", status: 429,
                                headers: ["Set-Cookie": "PRIVATE_COOKIE_VALUE=SECRET; Path=/",
                                          "Location": "https://private.invalid/PRIVATE_LOCATION",
                                          "X-Private": "PRIVATE_HEADER", "Cache-Control": "no-store"])
        f.observe(response)
        let line = try XCTUnwrap(f.logs.first)
        let parsed = try parse(line)
        XCTAssertEqual(f.logs.count, 1)
        XCTAssertEqual(parsed.prefix["role"], "model")
        XCTAssertEqual(parsed.prefix["sample"], "1")
        XCTAssertEqual(parsed.prefix["tab"].flatMap(UUID.init(uuidString:)), f.id)
        XCTAssertEqual(parsed.prefix["generation"].flatMap(UUID.init(uuidString:)), generation)
        XCTAssertLessThanOrEqual(line.utf8.count, 1_000)
        XCTAssertEqual(Set(parsed.snapshot.keys), ["kind", "evidence", "responseSource", "requestCookie", "redirectChain",
                                                   "navigationIdentity", "destination", "responseKind", "statusCode", "cacheControl"])
        XCTAssertEqual(parsed.snapshot["kind"] as? String, "gemini_navigation_response_v1")
        XCTAssertEqual(parsed.snapshot["evidence"] as? String, "callback_time_response_metadata_not_wire_proof")
        XCTAssertEqual(parsed.snapshot["destination"] as? String, "google_www_sorry")
        XCTAssertEqual(parsed.snapshot["responseKind"] as? String, "http")
        XCTAssertEqual(parsed.snapshot["statusCode"] as? Int, 429)
        XCTAssertEqual((parsed.snapshot["cacheControl"] as? [String: Bool])?["noStore"], true)
        for field in ["responseSource", "requestCookie", "redirectChain", "navigationIdentity"] {
            XCTAssertEqual(parsed.snapshot[field] as? String, "unknown", field)
        }
        for secret in ["PRIVATE", "SECRET", "Set-Cookie", "https://", "private.invalid", "continue="] {
            XCTAssertFalse(line.contains(secret), secret)
        }
        XCTAssertNil(f.view.url)
        XCTAssertFalse(f.view.isLoading)
        XCTAssertEqual(f.session.documentGeneration(for: f.id), generation)
        XCTAssertEqual(f.session.tabs.map(\.id), tabs)
        XCTAssertEqual(f.session.savedHumanVerificationCheckpointIDs, checkpoints)
        XCTAssertTrue(f.session.humanVerificationRecoveryReports.isEmpty)
        XCTAssertEqual(recoveries, 0)
    }

    func testForeignClosedSubframeAndUntrustedResponsesCannotConsumeTheTwoRecordBudget() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        let trusted = try http("https://gemini.google.com/app", status: 200)
        let foreignConfiguration = WKWebViewConfiguration()
        foreignConfiguration.websiteDataStore = .nonPersistent()
        let foreign = WKWebView(frame: .zero, configuration: foreignConfiguration)
        f.session.observeGeminiNavigationResponseForTesting(response: trusted, isMainFrame: true, view: foreign, tabID: f.id)
        f.session.observeGeminiNavigationResponseForTesting(response: trusted, isMainFrame: true, view: f.view, tabID: UUID())
        f.observe(trusted, mainFrame: false)
        for url in ["https://gemini.google.com.evil.invalid/app", "http://gemini.google.com/app",
                    "https://user:PRIVATE_PASSWORD@gemini.google.com/app", "https://gemini.google.com:8443/app",
                    "https://gemini.google.com/signin", "https://www.google.com/search?q=PRIVATE_QUERY",
                    "https://www.google.com/sorry-evil"] {
            f.observe(try http(url, status: 200))
        }
        f.observe(URLResponse(url: URL(string: "about:blank")!, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil))
        XCTAssertTrue(f.logs.isEmpty)
        f.observe(trusted); f.observe(trusted)
        XCTAssertEqual(f.logs.count, 2)
        f.session.closeTab(f.id)
        f.observe(trusted)
        XCTAssertEqual(f.logs.count, 2)
        f.session.shutdown()
        f.observe(trusted)
        XCTAssertEqual(f.logs.count, 2)
    }

    func testHumanAndModelResponsesRetainTheirRoleAndNonHTTPRemainsUnknown() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        let human = try f.session.createTab()
        let humanView = try XCTUnwrap(f.session.webView(for: human))
        humanView.navigationDelegate = nil
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        let nonHTTP = URLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)
        f.session.observeGeminiNavigationResponseForTesting(response: nonHTTP, isMainFrame: true, view: humanView, tabID: human)
        f.observe(try http(url.absoluteString, status: 200))
        XCTAssertEqual(f.logs.count, 2)
        XCTAssertEqual(try parse(f.logs[0]).prefix["role"], "human")
        XCTAssertEqual(try parse(f.logs[1]).prefix["role"], "model")
        let unknown = try parse(f.logs[0]).snapshot
        XCTAssertEqual(unknown["responseKind"] as? String, "non_http")
        for field in ["statusCode", "cacheControl", "dateAge", "age", "expires"] { XCTAssertNil(unknown[field], field) }
        for field in ["responseSource", "requestCookie", "redirectChain", "navigationIdentity"] {
            XCTAssertEqual(unknown[field] as? String, "unknown", field)
        }
        XCTAssertEqual(try parse(f.logs[1]).snapshot["statusCode"] as? Int, 200)
    }

    func testTwoRecordsPerGenerationResetOnlyAfterANewDocumentGeneration() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        let response = try http("https://www.google.com/sorry/index", status: 429)
        let first = f.session.documentGeneration(for: f.id)
        for _ in 0..<5 { f.observe(response) }
        XCTAssertEqual(f.logs.count, 2)
        try f.nextGeneration()
        let second = f.session.documentGeneration(for: f.id)
        XCTAssertNotEqual(first, second)
        for _ in 0..<5 { f.observe(response) }
        XCTAssertEqual(f.logs.count, 4)
        XCTAssertEqual(try f.logs.map { try parse($0).prefix["sample"] }, ["1", "2", "1", "2"])
        XCTAssertEqual(try parse(f.logs[2]).prefix["generation"].flatMap(UUID.init(uuidString:)), second)
    }

    func testTwelveRecordSessionWindowIsSharedAcrossTabsAndReopensAtSixtySeconds() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        let anchor = ContinuousClock.now
        var clock = anchor
        f.session.setGeminiNavigationResponseClockForTesting { clock }
        let response = try http("https://gemini.google.com/app", status: 200)
        let secondID = try f.session.createUnloadedModelTabForTesting()
        let secondView = try XCTUnwrap(f.session.webView(for: secondID))
        secondView.navigationDelegate = nil
        for _ in 0..<3 {
            for _ in 0..<2 {
                f.observe(response)
                f.session.observeGeminiNavigationResponseForTesting(response: response, isMainFrame: true, view: secondView, tabID: secondID)
            }
            try f.nextGeneration()
            try f.session.navigate(tabID: secondID, to: URL(string: "about:blank")!)
        }
        XCTAssertEqual(f.logs.count, 12)
        f.observe(response)
        clock = anchor + .seconds(59)
        f.observe(response)
        XCTAssertEqual(f.logs.count, 12)
        clock = anchor + .seconds(60)
        try f.nextGeneration()
        f.observe(response); f.observe(response); f.observe(response)
        XCTAssertEqual(f.logs.count, 14)
        XCTAssertTrue(f.logs.allSatisfy { $0.utf8.count <= 1_000 })
    }

    func testStaggeredRollingWindowFreesOnlyExpiredRecordCapacity() throws {
        let f = try Fixture()
        defer { f.session.shutdown() }
        let anchor = ContinuousClock.now
        var clock = anchor
        f.session.setGeminiNavigationResponseClockForTesting { clock }
        let response = try http("https://gemini.google.com/app", status: 200)
        f.observe(response) // One record at t=0.
        clock = anchor + .seconds(30)
        f.observe(response)
        for _ in 0..<5 {
            try f.nextGeneration()
            f.observe(response); f.observe(response)
        }
        XCTAssertEqual(f.logs.count, 12, "Eleven records are still only 30s old at the next boundary")
        clock = anchor + .seconds(60)
        for _ in 0..<6 {
            try f.nextGeneration()
            f.observe(response); f.observe(response)
        }
        XCTAssertEqual(f.logs.count, 13, "Only the t=0 record expired; an anchored reset would incorrectly admit 12")
        clock = anchor + .seconds(89)
        try f.nextGeneration()
        f.observe(response)
        XCTAssertEqual(f.logs.count, 13)
        clock = anchor + .seconds(90)
        try f.nextGeneration()
        f.observe(response); f.observe(response)
        XCTAssertEqual(f.logs.count, 15, "The eleven t=30 records expire at t=90")
    }

    /// Public WebKit callback coverage only. This loopback fixture does not
    /// relax Computa's trusted route filter or establish real Google behavior.
    func testRealWebKitRedirectResponseCallbackExposesFinalStatusWithoutEveryHop() async throws {
        let server = try NavigationResponseHTTPFixture()
        defer { server.stop() }
        let origin = try await server.start()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let probe = NavigationResponseDelegateProbe()
        view.navigationDelegate = probe
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.load(URLRequest(url: origin.appendingPathComponent("start")))
        let deadline = ContinuousClock.now + .seconds(10)
        while !probe.finished, probe.failureCode == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(probe.finished, "The local navigation must finish, not just yield a policy callback")
        XCTAssertNil(probe.failureCode)
        XCTAssertEqual(server.paths, ["/start", "/final"])
        XCTAssertEqual(probe.redirects, 1)
        XCTAssertEqual(probe.statuses, [429], "Current public WebKit response policy reports the final response, not a complete HTTP redirect-chain transcript")
        XCTAssertEqual(probe.responsePaths, ["/final"])
        XCTAssertEqual(view.url, origin.appendingPathComponent("final"))
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    }

    private func http(_ rawURL: String, status: Int, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: rawURL)), statusCode: status,
                                    httpVersion: "HTTP/1.1", headerFields: headers))
    }

    private func parse(_ line: String) throws -> (prefix: [String: String], snapshot: [String: Any], json: String) {
        XCTAssertTrue(line.hasPrefix("geminiNavigationResponse "))
        let start = try XCTUnwrap(line.firstIndex(of: "{"))
        let fields = line[..<start].split(separator: " ").dropFirst().compactMap { token -> (String, String)? in
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        }
        let json = String(line[start...])
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return (Dictionary(uniqueKeysWithValues: fields), snapshot, json)
    }

    @MainActor private final class Fixture {
        let session = EmbeddedBrowserSession(persistent: false)
        let id: UUID
        let view: WKWebView
        var logs: [String] = []
        init() throws {
            id = try session.createUnloadedModelTabForTesting()
            view = try XCTUnwrap(session.webView(for: id))
            view.navigationDelegate = nil
            session.setGeminiNavigationResponseObserverForTesting { [weak self] line in self?.logs.append(line) }
        }
        func observe(_ response: URLResponse, mainFrame: Bool = true) {
            session.observeGeminiNavigationResponseForTesting(response: response, isMainFrame: mainFrame, view: view, tabID: id)
        }
        func nextGeneration() throws {
            try session.navigate(tabID: id, to: URL(string: "about:blank")!)
        }
    }
}

@MainActor
private final class NavigationResponseDelegateProbe: NSObject, WKNavigationDelegate {
    var statuses: [Int] = []
    var responsePaths: [String] = []
    var redirects = 0
    var finished = false
    var failureCode: Int?
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse {
            statuses.append(http.statusCode); responsePaths.append(http.url?.path ?? "")
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) { redirects += 1 }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failureCode = (error as NSError).code }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failureCode = (error as NSError).code }
}

private final class NavigationResponseHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ComputaTests.NavigationResponseHTTP")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var recordedPaths: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return recordedPaths }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self, error == nil, let bytes, !bytes.isEmpty else { connection.cancel(); return }
            let data = accumulated + bytes
            guard data.count <= 16_384 else { connection.cancel(); return }
            guard data.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: data) }
                return
            }
            let request = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            guard request.count == 3, request[0] == "GET", ["/start", "/final"].contains(String(request[1])) else { connection.cancel(); return }
            let path = String(request[1])
            self.lock.lock(); self.recordedPaths.append(path); self.lock.unlock()
            let body = path == "/final" ? Data("<!doctype html><p>Local response fixture</p>".utf8) : Data()
            let status = path == "/start" ? "302 Found" : "429 Too Many Requests"
            let location = path == "/start" ? "Location: /final\r\n" : ""
            var output = Data("HTTP/1.1 \(status)\r\n\(location)Content-Type: text/html\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            output.append(body)
            connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }
    func stop() {
        listener.cancel()
        lock.lock(); let live = connections; connections.removeAll(); lock.unlock()
        live.forEach { $0.cancel() }
    }
}

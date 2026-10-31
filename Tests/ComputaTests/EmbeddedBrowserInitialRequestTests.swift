import AppKit
import Network
import WebKit
import XCTest
@testable import Computa

/// Wire observations from an isolated loopback origin, through the production
/// tab factories and navigation delegates. This does not model Google's HTTPS,
/// cross-site cookie policy, TLS fingerprint, or server-side risk decisions.
@MainActor
final class EmbeddedBrowserInitialRequestTests: XCTestCase {
    func testHumanThenModelShareInitialCookieAndIdentityAcrossOneRedirect() async throws {
        try await compareFactories(order: ["human", "model"], finalStatus: 200)
    }

    func testModelThenHumanDoNotReplayAnHTTP429Redirect() async throws {
        try await compareFactories(order: ["model", "human"], finalStatus: 429)
    }

    private func compareFactories(order: [String], finalStatus: Int) async throws {
        let server = try InitialRequestHTTPFixture(finalStatus: finalStatus)
        let origin = try await server.start()
        defer { server.stop() }
        let suite = "Computa.InitialRequestTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = EmbeddedBrowserSession(persistent: false, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_024, height: 768),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { session.shutdown(); window.close() }
        let root = try XCTUnwrap(window.contentView)
        let background = EmbeddedModelRenderContainer(session: session)
        background.frame = root.bounds
        root.addSubview(background)
        session.installModelRenderHost(background)
        let foreground = NSView(frame: root.bounds)
        root.addSubview(foreground)
        // The window stays unshown; this tests attachment without stealing focus.
        let humanID = try session.createTab()
        let human = try XCTUnwrap(session.webView(for: humanID))
        try session.presentTab(humanID, in: foreground)
        let store = human.configuration.websiteDataStore
        XCTAssertFalse(store.isPersistent)
        let shared = try XCTUnwrap(HTTPCookie(properties: [
            .name: "factory-shared", .value: "synthetic-kept", .domain: "127.0.0.1", .path: "/"
        ]))
        let excluded = try XCTUnwrap(HTTPCookie(properties: [
            .name: "factory-excluded", .value: "synthetic-path-control", .domain: "127.0.0.1", .path: "/excluded"
        ]))
        for cookie in [shared, excluded] {
            await withCheckedContinuation { continuation in
                store.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
        XCTAssertTrue(server.requests.isEmpty, "Creating a blank human tab and seeding cookies must not load a page")
        var delegates: [AnyObject] = []
        for role in order {
            let initial = origin.appendingPathComponent(role + "/start")
            let final = origin.appendingPathComponent(role + "/final")
            let id: UUID
            if role == "human" {
                id = humanID
                try session.navigate(tabID: id, to: initial)
            } else {
                // No testing factory, delegate replacement, load override, or
                // provider routing change: this is the ordinary model factory.
                id = try session.createModelTab(url: initial)
            }
            let view = try XCTUnwrap(session.webView(for: id))
            let delegate = try XCTUnwrap(view.navigationDelegate)
            delegates.append(delegate)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertTrue(view.window === window)
            XCTAssertEqual(session.selectedTabID, humanID)
            try await InitialRequestLoadBoundary(view: view, finalURL: final).wait()
            let text: String = try await withCheckedThrowingContinuation { continuation in
                view.evaluateJavaScript("document.body.textContent") { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let text = value as? String { continuation.resume(returning: text) }
                    else { continuation.resume(throwing: URLError(.cannotParseResponse)) }
                }
            }
            XCTAssertEqual(text, "Synthetic final \(finalStatus)")
            XCTAssertTrue(view.navigationDelegate === delegate, "Keep the actual app navigation policy throughout the redirect")
            let observed = server.requests.filter { $0.path.hasPrefix("/" + role + "/") }
            XCTAssertEqual(observed.map(\.path), ["/\(role)/start", "/\(role)/final"],
                           "One initial dispatch and one server redirect; no app replay, including HTTP 429")
        }
        let requests = server.requests
        XCTAssertEqual(requests.map(\.path), order.flatMap { ["/\($0)/start", "/\($0)/final"] })
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body.isEmpty })
        XCTAssertEqual(Set(requests.compactMap { $0.headers["host"] }), ["127.0.0.1:\(origin.port!)"])
        let userAgents = requests.compactMap { $0.headers["user-agent"] }
        XCTAssertEqual(userAgents.count, 4)
        XCTAssertEqual(Set(userAgents).count, 1, "Compare actual transmitted UA, not configuration properties")
        XCTAssertTrue(userAgents.allSatisfy { $0.hasSuffix(" " + EmbeddedBrowserIdentity.currentApplicationName) })
        for request in requests {
            let cookies = (request.headers["cookie"] ?? "").split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertTrue(cookies.contains("factory-shared=synthetic-kept"), request.path)
            XCTAssertFalse(cookies.contains { $0.hasPrefix("factory-excluded=") }, request.path)
        }
        let retained = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(retained.first { $0.name == shared.name }?.value, shared.value)
        XCTAssertEqual(retained.first { $0.name == excluded.name }?.value, excluded.value)
        XCTAssertEqual(delegates.count, 2)
        print("INITIAL_REQUEST_WIRE_CONTROL order=\(order.joined(separator: ",")) finalStatus=\(finalStatus) requests=\(requests.count) sharedCookie=verified userAgent=same")
    }
}

/// Observe native loading state without replacing the app's delegate or issuing
/// polling requests. The final DOM read above confirms the returned document.
@MainActor
private final class InitialRequestLoadBoundary {
    private let view: WKWebView
    private let finalURL: URL
    private var observation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    init(view: WKWebView, finalURL: URL) { self.view = view; self.finalURL = finalURL }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            observation = view.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.check() }
            }
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finish(.failure(URLError(.timedOut)))
            }
        }
    }
    private func check() {
        if !view.isLoading, view.url == finalURL { finish(.success(())) }
    }
    private func finish(_ result: Result<Void, Error>) {
        guard let current = continuation else { return }
        continuation = nil
        observation?.invalidate(); observation = nil
        timeout?.cancel(); timeout = nil
        current.resume(with: result)
    }
}

/// The only listener is IPv4 loopback on an ephemeral port. Responses have no
/// scripts or external resources; all request evidence is synthetic and in RAM.
private final class InitialRequestHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let finalStatus: Int
    private let queue = DispatchQueue(label: "ComputaTests.InitialRequestHTTP")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var recorded: [APIModelServer.HTTPRequest] = []
    var requests: [APIModelServer.HTTPRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(finalStatus: Int) throws {
        self.finalStatus = finalStatus
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
            do {
                guard let request = try APIModelServer.parseRequest(data) else {
                    if complete { connection.cancel() } else { self.receive(connection, accumulated: data) }
                    return
                }
                self.lock.lock(); self.recorded.append(request); self.lock.unlock()
                let parts = request.path.split(separator: "/")
                guard parts.count == 2, ["human", "model"].contains(String(parts[0])),
                      ["start", "final"].contains(String(parts[1])), request.method == "GET" else {
                    self.respond(connection, status: 404, location: nil, body: Data()); return
                }
                if parts[1] == "start" {
                    self.respond(connection, status: 302, location: "/\(parts[0])/final", body: Data())
                } else {
                    let html = "<!doctype html><meta charset=utf-8><link rel=icon href='data:,'><body>Synthetic final \(self.finalStatus)</body>"
                    self.respond(connection, status: self.finalStatus, location: nil, body: Data(html.utf8))
                }
            } catch { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, status: Int, location: String?, body: Data) {
        let redirect = location.map { "Location: \($0)\r\n" } ?? ""
        var response = Data("HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n\(redirect)Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; img-src data:\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    listener.stateUpdateHandler = nil; continuation.resume(returning: port.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
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

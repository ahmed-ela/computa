import AppKit
import WebKit
import XCTest
import Network
@testable import Computa

final class EmbeddedBrowserIdentityTests: XCTestCase {
    private let safari = EmbeddedBrowserIdentity.Product(identifier: "com.apple.Safari", version: "26.5", build: "21624.2.5.11.4")
    private let webKit = EmbeddedBrowserIdentity.Product(identifier: "com.apple.WebKit", version: "21624", build: "21624.2.5.11.4")

    func testCompatibilityIdentityRequiresAnExactEngineBuildMatch() {
        XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: safari, webKit: webKit, appVersion: "0.7.0"),
                       "Version/26.5 Safari/605.1.15 Computa/0.7.0")
        let older = EmbeddedBrowserIdentity.Product(identifier: "com.apple.Safari", version: "18.6.1", build: "20621.3.11.11.4")
        XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: older, webKit: webKit, appVersion: "0.7.0"),
                       "Computa/0.7.0", "Do not claim a Safari version with a different engine")
        let newer = EmbeddedBrowserIdentity.Product(identifier: "com.apple.Safari", version: "27.0", build: "22630.1.1")
        XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: newer, webKit: webKit, appVersion: "0.7.0"), "Computa/0.7.0")
    }

    func testIdentityTracksCorroboratedSafariVersionsRatherThanAPinnedLatestVersion() {
        for version in ["17.6", "18.6.1", "26.5", "27.1"] {
            let installed = EmbeddedBrowserIdentity.Product(identifier: "com.apple.Safari", version: version, build: webKit.build)
            XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: installed, webKit: webKit, appVersion: "0.8.2"),
                           "Version/\(version) Safari/605.1.15 Computa/0.8.2")
        }
    }

    func testUnavailableOrDifferentProductsDoNotInventSafariSupport() {
        XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: nil, webKit: webKit, appVersion: "0.7.0"), "Computa/0.7.0")
        XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: safari, webKit: nil, appVersion: "0.7.0"), "Computa/0.7.0")
        let otherSafari = EmbeddedBrowserIdentity.Product(identifier: "com.apple.SafariTechnologyPreview", version: safari.version, build: safari.build)
        let otherEngine = EmbeddedBrowserIdentity.Product(identifier: "example.WebKit", version: webKit.version, build: webKit.build)
        XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: otherSafari, webKit: webKit, appVersion: "0.7.0"), "Computa/0.7.0")
        XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: safari, webKit: otherEngine, appVersion: "0.7.0"), "Computa/0.7.0")
    }

    func testMalformedMetadataCannotInjectUserAgentTokens() {
        for malformed in ["", "26..5", " 26.5", "26.5 ", "26.5\r\nSafari/99", "26.5 Safari/99", "٢٦.٥", ".26", "26.", String(repeating: "1", count: 49)] {
            let product = EmbeddedBrowserIdentity.Product(identifier: safari.identifier, version: malformed, build: safari.build)
            XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: product, webKit: webKit, appVersion: "0.7.0"), "Computa/0.7.0")
            let invalidBuild = EmbeddedBrowserIdentity.Product(identifier: safari.identifier, version: safari.version, build: malformed)
            let matchingInvalidBuild = EmbeddedBrowserIdentity.Product(identifier: webKit.identifier, version: webKit.version, build: malformed)
            XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: invalidBuild, webKit: matchingInvalidBuild, appVersion: "0.7.0"), "Computa/0.7.0")
            XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: safari, webKit: webKit, appVersion: malformed),
                           "Version/26.5 Safari/605.1.15 Computa")
        }
        XCTAssertEqual(EmbeddedBrowserIdentity.applicationName(safari: nil, webKit: nil, appVersion: nil), "Computa")
    }

    @MainActor
    func testNativeViewsUseTheSameIdentityBeforeAnyNavigation() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let humanID = try session.createTab()
        let human = try XCTUnwrap(session.webView(for: humanID))
        var modelConstructionIdentity: String?
        let modelID = try session.createUnloadedModelTabForTesting { configuration in
            modelConstructionIdentity = configuration.applicationNameForUserAgent
            return WKWebView(frame: .zero, configuration: configuration)
        }
        let model = try XCTUnwrap(session.webView(for: modelID))
        let tool = try XCTUnwrap(session.webView(for: session.createToolTab(url: XCTUnwrap(URL(string: "about:blank")))))
        let expected = EmbeddedBrowserIdentity.currentApplicationName
        XCTAssertEqual(modelConstructionIdentity, expected)
        for view in [human, model, tool] {
            XCTAssertEqual(view.configuration.applicationNameForUserAgent, expected)
            XCTAssertTrue(view.customUserAgent?.isEmpty != false, "Retain WebKit's own platform/engine prefix")
            let ua = try await userAgent(view)
            XCTAssertTrue(ua.hasSuffix(" " + expected), ua)
            XCTAssertTrue(ua.contains("AppleWebKit/"), ua)
            XCTAssertFalse(view.isInspectable)
        }
        XCTAssertTrue(human.configuration.websiteDataStore === tool.configuration.websiteDataStore)
        XCTAssertTrue(human.configuration.userContentController.userScripts.isEmpty)
        XCTAssertTrue(tool.configuration.userContentController.userScripts.isEmpty)
        XCTAssertFalse(tool.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(model.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertEqual(session.selectedTabID, humanID)
        XCTAssertNil(human.url, "Identification must not load a hidden page")
    }

    @MainActor
    func testPopupRetainsBrowserIdentityAndProfileWithoutCustomUserAgent() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let openerID = try session.createTab()
        let opener = try XCTUnwrap(session.webView(for: openerID))
        opener.loadHTMLString("<p id='identity-ready'>Ready</p><a id='identity-popup' target='_blank' href='about:blank'>Open</a>", baseURL: nil)
        let loadDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < loadDeadline {
            if !opener.isLoading,
               (try? await opener.evaluateJavaScript("!!document.getElementById('identity-ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let ready = try await opener.evaluateJavaScript("!!document.getElementById('identity-ready')") as? Bool
        XCTAssertEqual(ready, true)
        _ = try await opener.evaluateJavaScript("document.getElementById('identity-popup').click()")
        let popupDeadline = ContinuousClock.now + .seconds(5)
        while session.tabs.count < 2, ContinuousClock.now < popupDeadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(session.tabs.count, 2)
        let popupID = try XCTUnwrap(session.tabs.first(where: { $0.id != openerID })).id
        let popup = try XCTUnwrap(session.webView(for: popupID))
        XCTAssertEqual(popup.configuration.applicationNameForUserAgent, EmbeddedBrowserIdentity.currentApplicationName)
        XCTAssertTrue(popup.customUserAgent?.isEmpty != false, "No popup-specific user-agent override")
        let popupUserAgent = try await userAgent(popup)
        let openerUserAgent = try await userAgent(opener)
        XCTAssertEqual(popupUserAgent, openerUserAgent)
        XCTAssertTrue(popup.configuration.websiteDataStore === opener.configuration.websiteDataStore)
        XCTAssertTrue(popup.configuration.userContentController.userScripts.isEmpty)
        XCTAssertFalse(popup.isInspectable)
    }

    @MainActor
    private func userAgent(_ view: WKWebView) async throws -> String {
        let result = try await view.evaluateJavaScript("navigator.userAgent")
        return try XCTUnwrap(result as? String)
    }

    @MainActor
    func testCacheMigrationSharesOneNativeClearAndPersistsOnlyItsCallback() async throws {
        let suite = "Computa.IdentityTests.\(UUID())", profile = UUID(), probe = CacheRemovalProbe()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = EmbeddedBrowserCacheIdentity.defaultsKey(profileID: profile)
        let migration = EmbeddedBrowserCacheIdentity(profileID: profile, identity: "new", defaults: defaults, remove: probe.remove)
        defer { migration.close() }
        let first = Task { await migration.wait(until: .now + .seconds(2)) }
        let second = Task { await migration.wait(until: .now + .seconds(2)) }
        await probe.waitForStart()
        first.cancel()
        let cancelled = await first.value
        XCTAssertFalse(cancelled)
        XCTAssertNil(defaults.string(forKey: key))
        XCTAssertEqual(probe.calls, 1)
        probe.complete()
        let admitted = await second.value
        XCTAssertTrue(admitted)
        XCTAssertEqual(defaults.string(forKey: key), "new")
        let restarted = EmbeddedBrowserCacheIdentity(profileID: profile, identity: "new", defaults: defaults, remove: probe.remove)
        let ready = await restarted.wait(until: .now + .seconds(1))
        XCTAssertTrue(ready)
        XCTAssertEqual(probe.calls, 1, "Unchanged identity must not clear again")
        restarted.close()
        let different = EmbeddedBrowserCacheIdentity(profileID: UUID(), identity: "new", defaults: defaults, remove: probe.remove)
        XCTAssertFalse(different.ready, "Identity is scoped to the exact persistent profile")
        different.close()
        let changed = EmbeddedBrowserCacheIdentity(profileID: profile, identity: "next", defaults: defaults, remove: probe.remove)
        XCTAssertFalse(changed.ready)
        changed.close()
        XCTAssertEqual(EmbeddedBrowserCacheIdentity.cacheDataTypes, [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
    }

    @MainActor
    func testCacheTimeoutDoesNotReplayOrStartAnotherClearAndCloseCannotMarkSuccess() async throws {
        let suite = "Computa.IdentityTests.\(UUID())", profile = UUID(), probe = CacheRemovalProbe()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = EmbeddedBrowserCacheIdentity.defaultsKey(profileID: profile)
        let migration = EmbeddedBrowserCacheIdentity(profileID: profile, identity: "new", defaults: defaults, remove: probe.remove)
        let timedOut = await migration.wait(until: .now + .milliseconds(5))
        XCTAssertFalse(timedOut)
        XCTAssertNil(defaults.string(forKey: key))
        let secondTimeout = await migration.wait(until: .now + .milliseconds(5))
        XCTAssertFalse(secondTimeout)
        XCTAssertEqual(probe.calls, 1)
        probe.complete()
        XCTAssertFalse(timedOut, "Late completion cannot admit a finished caller")
        let fresh = await migration.wait(until: .now + .seconds(1))
        XCTAssertTrue(fresh)
        migration.close()
        let nextProbe = CacheRemovalProbe()
        let closed = EmbeddedBrowserCacheIdentity(profileID: profile, identity: "next", defaults: defaults, remove: nextProbe.remove)
        let waiter = Task { await closed.wait(until: .now + .seconds(5)) }
        await nextProbe.waitForStart()
        closed.close()
        let closedResult = await waiter.value
        XCTAssertFalse(closedResult)
        nextProbe.complete()
        XCTAssertEqual(defaults.string(forKey: key), "new", "Shutdown cannot persist an unfinished migration")
    }

    @MainActor
    func testCacheNavigationAdmissionRejectsStoppedSupersededClosedAndShutdownViews() async throws {
        for mutation in ["stop", "replace", "close", "shutdown"] {
            let suite = "Computa.IdentityTests.\(UUID())", profile = ownedPersistentProfile(), probe = CacheRemovalProbe()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = EmbeddedBrowserSession(profileID: profile, defaults: defaults)
            session.cacheIdentityRemovalForTesting = probe.remove
            defer { session.shutdown() }
            let tab = try session.createTab(), url = try XCTUnwrap(URL(string: "https://example.invalid/owned"))
            let view = try XCTUnwrap(session.webView(for: tab))
            let pending = Task { await session.admitCacheIdentityForTesting(tabID: tab, view: view, url: url, until: .now + .seconds(2)) }
            await probe.waitForStart()
            switch mutation {
            case "stop": session.stop(tabID: tab)
            case "replace": try session.navigate(tabID: tab, to: XCTUnwrap(URL(string: "about:blank")))
            case "close": session.closeTab(tab)
            default: session.shutdown()
            }
            probe.complete()
            let result = await pending.value
            XCTAssertEqual(result, .cancelled, mutation)
            XCTAssertNil(view.url?.host, "The rejected request must never be dispatched")
        }
    }

    @MainActor
    func testCacheAdmissionTimeoutSurfacesAnErrorAndPrivateSessionsBypassMigration() async throws {
        let suite = "Computa.IdentityTests.\(UUID())", probe = CacheRemovalProbe()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = EmbeddedBrowserSession(profileID: ownedPersistentProfile(), defaults: defaults)
        session.cacheIdentityRemovalForTesting = probe.remove
        defer { session.shutdown() }
        let tab = try session.createTab(), view = try XCTUnwrap(session.webView(for: tab))
        let url = try XCTUnwrap(URL(string: "https://example.invalid/owned"))
        let result = await session.admitCacheIdentityForTesting(tabID: tab, view: view, url: url, until: .now + .milliseconds(5))
        XCTAssertEqual(result, .timedOut)
        XCTAssertFalse(try XCTUnwrap(session.tabs.first).isLoading)
        XCTAssertTrue(session.errorMessage?.contains("browser cache update") == true)
        probe.complete()
        XCTAssertNil(view.url, "Native completion cannot dispatch the timed-out request")
        let privateSession = EmbeddedBrowserSession(persistent: false, defaults: defaults)
        privateSession.cacheIdentityRemovalForTesting = probe.remove
        defer { privateSession.shutdown() }
        let privateTab = try privateSession.createTab(), privateView = try XCTUnwrap(privateSession.webView(for: privateTab))
        let privateResult = await privateSession.admitCacheIdentityForTesting(tabID: privateTab, view: privateView, url: url, until: .now + .seconds(1))
        XCTAssertEqual(privateResult, .allowed)
        XCTAssertEqual(probe.calls, 1, "Private profiles must not touch the persistent cache migration")
    }

    @MainActor
    func testFirstNavigationClearsLegacyHTTPCacheAcrossPathsAndPreservesWebsiteStorage() async throws {
        let server = try IdentityHTTPFixture(), origin = try await server.start()
        defer { server.stop() }
        let suite = "Computa.IdentityTests.\(UUID())", profile = ownedPersistentProfile()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WKWebsiteDataStore(forIdentifier: profile)
        var views: [WKWebView] = []
        func rawView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = store
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            views.append(view)
            return view
        }
        let firstURL = origin.appendingPathComponent("one"), secondURL = origin.appendingPathComponent("two")
        let seed = rawView()
        seed.load(URLRequest(url: firstURL))
        let oldFirst = try await fixtureEvidence(seed, url: firstURL)
        XCTAssertEqual(oldFirst["count"] as? Int, 1)
        _ = try await seed.evaluateJavaScript("document.cookie='identity-cookie=kept; path=/; SameSite=Lax'; localStorage.setItem('identity-local','kept'); sessionStorage.setItem('identity-session','kept')")
        let secondSeed = rawView()
        secondSeed.load(URLRequest(url: secondURL))
        let oldSecond = try await fixtureEvidence(secondSeed, url: secondURL)
        XCTAssertEqual(oldSecond["count"] as? Int, 1)
        // Establish a real cache hit first. Without this control, a passing
        // migration test could simply be exercising uncached responses.
        let cached = rawView()
        cached.load(URLRequest(url: firstURL))
        let sameIdentity = try await fixtureEvidence(cached, url: firstURL)
        XCTAssertEqual(sameIdentity["count"] as? Int, 1)
        XCTAssertEqual(server.count(path: "/one"), 1)

        let session = EmbeddedBrowserSession(profileID: profile, defaults: defaults)
        defer { session.shutdown(); views.forEach { $0.stopLoading() } }
        let firstTab = try session.createTab(url: firstURL)
        let first = try XCTUnwrap(session.webView(for: firstTab))
        let fresh = try await fixtureEvidence(first, url: firstURL)
        XCTAssertEqual(fresh["count"] as? Int, 2, "First navigation must replace cached old-identity HTML")
        XCTAssertTrue((fresh["ua"] as? String)?.hasSuffix(EmbeddedBrowserIdentity.currentApplicationName) == true)
        XCTAssertTrue((fresh["cookie"] as? String)?.contains("identity-cookie=kept") == true)
        let retainedLocal = try await first.evaluateJavaScript("localStorage.getItem('identity-local')") as? String
        let retainedSession = try await seed.evaluateJavaScript("sessionStorage.getItem('identity-session')") as? String
        XCTAssertEqual(retainedLocal, "kept")
        XCTAssertEqual(retainedSession, "kept")
        let secondTab = try session.createTab(url: secondURL)
        let second = try XCTUnwrap(session.webView(for: secondTab))
        let secondFresh = try await fixtureEvidence(second, url: secondURL)
        XCTAssertEqual(secondFresh["count"] as? Int, 2, "Migration must cover other old paths, not just the first URL")
        let thirdTab = try session.createTab(url: firstURL)
        let third = try XCTUnwrap(session.webView(for: thirdTab))
        let reused = try await fixtureEvidence(third, url: firstURL)
        XCTAssertEqual(reused["count"] as? Int, 2)
        XCTAssertEqual(server.count(path: "/one"), 2, "One fresh dispatch; no hidden reload or repeated cache clearing")
        XCTAssertEqual(server.count(path: "/two"), 2)
        XCTAssertEqual(defaults.string(forKey: EmbeddedBrowserCacheIdentity.defaultsKey(profileID: profile)),
                       EmbeddedBrowserIdentity.currentCacheIdentity)
        XCTAssertTrue(server.methods.allSatisfy { $0 == "GET" })
        session.shutdown()
        views.forEach { $0.stopLoading() }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    @MainActor
    func testRealPolicyCancellationNeverDispatchesStoppedReplacedOrClosedRequests() async throws {
        let server = try IdentityHTTPFixture(), origin = try await server.start()
        defer { server.stop() }
        for mutation in ["stop", "replace", "close"] {
            let suite = "Computa.IdentityTests.\(UUID())", probe = CacheRemovalProbe()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = EmbeddedBrowserSession(profileID: ownedPersistentProfile(), defaults: defaults)
            session.cacheIdentityRemovalForTesting = probe.remove
            defer { session.shutdown() }
            let blockedURL = origin.appendingPathComponent(mutation + "-blocked")
            let freshURL = origin.appendingPathComponent(mutation + "-fresh")
            let oldTab = try session.createTab(url: blockedURL)
            await probe.waitForStart()
            XCTAssertEqual(server.count(path: blockedURL.path), 0)
            let freshTab: UUID
            switch mutation {
            case "stop":
                session.stop(tabID: oldTab)
                freshTab = oldTab
                try session.navigate(tabID: freshTab, to: freshURL)
            case "replace":
                freshTab = oldTab
                try session.navigate(tabID: freshTab, to: freshURL)
            default:
                session.closeTab(oldTab)
                freshTab = try session.createTab(url: freshURL)
            }
            probe.complete()
            let fresh = try XCTUnwrap(session.webView(for: freshTab))
            let result = try await fixtureEvidence(fresh, url: freshURL)
            XCTAssertEqual(result["count"] as? Int, 1, mutation)
            XCTAssertEqual(server.count(path: blockedURL.path), 0, "Cancelled policy must not be admitted by a late native callback: \(mutation)")
            XCTAssertEqual(server.count(path: freshURL.path), 1, mutation)
            XCTAssertEqual(probe.calls, 1)
        }
    }

    @MainActor
    private func fixtureEvidence(_ view: WKWebView, url: URL) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !view.isLoading, view.url == url,
               let text = (try? await view.evaluateJavaScript("document.getElementById('identity-evidence')?.textContent")) as? String,
               let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out loading identity fixture: \(url)")
        throw URLError(.timedOut)
    }

    @MainActor
    private func ownedPersistentProfile() -> UUID {
        let id = UUID()
        print("IDENTITY_TEST_PROFILE \(id.uuidString)")
        addTeardownBlock { @MainActor in
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                print("IDENTITY_TEST_PROFILE_REMOVED \(id.uuidString)")
            } catch {
                // WebKit can still hold a native view while XCTest tears down.
                // Retain its exact owned ID for cleanup after the test process.
                print("IDENTITY_TEST_PROFILE_CLEANUP_PENDING \(id.uuidString): \(error.localizedDescription)")
            }
        }
        return id
    }
}

@MainActor
private final class CacheRemovalProbe {
    private(set) var calls = 0
    private var completion: (@MainActor @Sendable () -> Void)?
    func remove(_ completion: @escaping @MainActor @Sendable () -> Void) { calls += 1; self.completion = completion }
    func complete() { let callback = completion; completion = nil; callback?() }
    func waitForStart() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while calls == 0, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(calls, 1)
    }
}

/// Loopback-only synthetic responses deliberately omit Vary: User-Agent to
/// reproduce persistent WebKit HTTP cache reuse across a changed UA identity.
private final class IdentityHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ComputaTests.IdentityHTTP")
    private let lock = NSLock()
    private var sockets: [NWConnection] = []
    private var counts: [String: Int] = [:]
    private var recordedMethods: [String] = []
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return recordedMethods }
    func count(path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.sockets.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(connection, bytes: Data())
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            guard let self, error == nil, let chunk, !chunk.isEmpty else { connection.cancel(); return }
            let combined = bytes + chunk
            guard combined.count <= 65_536 else { connection.cancel(); return }
            guard combined.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.receive(connection, bytes: combined) }
                return
            }
            let lines = String(decoding: combined, as: UTF8.self).components(separatedBy: "\r\n")
            let parts = lines[0].components(separatedBy: " "), path = parts.count > 1 ? parts[1] : "/"
            func header(_ name: String) -> String {
                lines.first(where: { $0.lowercased().hasPrefix(name + ":") })?.split(separator: ":", maxSplits: 1).last
                    .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            }
            self.lock.lock()
            self.counts[path, default: 0] += 1
            let count = self.counts[path, default: 0]
            self.recordedMethods.append(parts.first ?? "")
            self.lock.unlock()
            let value: [String: Any] = ["count": count, "path": path, "ua": header("user-agent"), "cookie": header("cookie")]
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let body = Data("<!doctype html><html><body><pre id='identity-evidence'>\(json)</pre></body></html>".utf8)
            var output = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: public, max-age=86400\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
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
        lock.lock(); let connections = sockets; sockets.removeAll(); lock.unlock()
        connections.forEach { $0.cancel() }
    }
}

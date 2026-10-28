import AppKit
import WebKit
import XCTest
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
}

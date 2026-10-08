import AppKit
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedHumanVerificationSessionTests: XCTestCase {
    func testRecreatedProfilePreservesCheckpointIDsWithoutOpeningTabs() throws {
        let suite = "Computa.HumanVerification.SessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let original = EmbeddedBrowserSession(profileID: profile, defaults: defaults)
        original.recordHumanVerificationRequired(provider: "gemini")
        original.recordHumanVerificationRequired(provider: "chatgpt")
        let saved = original.savedHumanVerificationCheckpointIDs
        original.recordHumanVerificationRequired(provider: "gemini")
        original.recordHumanVerificationRequired(provider: "Gemini")
        original.recordHumanVerificationRequired(provider: "https://google.com/sorry")
        XCTAssertEqual(original.savedHumanVerificationCheckpointIDs, saved, "Transport propagation must remain idempotent")
        XCTAssertTrue(original.tabs.isEmpty)
        original.shutdown()

        let recreated = EmbeddedBrowserSession(profileID: profile, defaults: defaults)
        let otherProfile = EmbeddedBrowserSession(profileID: UUID(), defaults: defaults)
        defer { recreated.shutdown(); otherProfile.shutdown() }
        XCTAssertEqual(recreated.savedHumanVerificationCheckpointIDs, saved)
        XCTAssertEqual(recreated.savedHumanVerificationProviders, ["gemini", "chatgpt"])
        XCTAssertTrue(otherProfile.savedHumanVerificationProviders.isEmpty)
        recreated.clearHumanVerificationRequired(provider: "Gemini")
        XCTAssertEqual(recreated.savedHumanVerificationCheckpointIDs, saved)
        recreated.clearHumanVerificationRequired(provider: "gemini")
        XCTAssertEqual(recreated.savedHumanVerificationCheckpointIDs, ["chatgpt": try XCTUnwrap(saved["chatgpt"])])
        XCTAssertEqual(original.savedHumanVerificationProviders, ["chatgpt"])
        XCTAssertNil(defaults.object(forKey: EmbeddedBrowserSession.profileDefaultsKey), "Explicit profiles must not change the production profile preference")
        XCTAssertTrue(recreated.tabs.isEmpty)
        XCTAssertTrue(otherProfile.tabs.isEmpty)
    }

    func testWebKitAndCheckpointStorageUseTheSameResolvedProfile() throws {
        let suite = "Computa.HumanVerification.SessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = EmbeddedBrowserSession(defaults: defaults)
        defer { session.shutdown() }
        session.recordHumanVerificationRequired(provider: "gemini")
        let resolved = try XCTUnwrap(defaults.string(forKey: EmbeddedBrowserSession.profileDefaultsKey).flatMap(UUID.init(uuidString:)))
        let replacement = UUID()
        defaults.set(replacement.uuidString, forKey: EmbeddedBrowserSession.profileDefaultsKey)
        let tab = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: tab))
        XCTAssertEqual(view.configuration.websiteDataStore.identifier, resolved)
        session.recordHumanVerificationRequired(provider: "claude")
        XCTAssertEqual(Set(EmbeddedHumanVerificationStore(defaults: defaults, profileID: resolved).load().keys), ["gemini", "claude"])
        XCTAssertTrue(EmbeddedHumanVerificationStore(defaults: defaults, profileID: replacement).load().isEmpty)
        XCTAssertEqual(defaults.string(forKey: EmbeddedBrowserSession.profileDefaultsKey), replacement.uuidString)
        XCTAssertNil(view.url)
        XCTAssertFalse(view.isLoading)
    }

    func testPrivateSessionNeverReadsOrMutatesPersistentCheckpoints() throws {
        let suite = "Computa.HumanVerification.SessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        defaults.set(profile.uuidString, forKey: EmbeddedBrowserSession.profileDefaultsKey)
        EmbeddedHumanVerificationStore(defaults: defaults, profileID: profile).save(["gemini": UUID()])
        let before = NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:])
        let session = EmbeddedBrowserSession(persistent: false, profileID: profile, defaults: defaults)
        let other = EmbeddedBrowserSession(persistent: false, profileID: profile, defaults: defaults)
        defer { session.shutdown(); other.shutdown() }
        XCTAssertTrue(session.savedHumanVerificationProviders.isEmpty)
        session.recordHumanVerificationRequired(provider: "chatgpt")
        XCTAssertEqual(session.savedHumanVerificationProviders, ["chatgpt"])
        XCTAssertTrue(other.savedHumanVerificationProviders.isEmpty)
        session.clearHumanVerificationRequired(provider: "chatgpt")
        let view = try XCTUnwrap(session.webView(for: session.createTab()))
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(before.isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    func testCheckpointChangesWakeOwnedWaitersWithoutNavigationOrNewTabs() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let human = try session.createTab()
        let model = try session.createUnloadedModelTabForTesting()
        try session.installModelChangeSignal(tabID: model, ownerToken: UUID().uuidString,
                                             world: .world(name: "human-checkpoint-wake"))
        let revisions = session.tabs.map(\.documentGeneration)
        let before = try session.modelChangeRevision(for: model)
        let waiter = Task { try await session.waitForModelChange(tabID: model, after: before, until: .now + .seconds(5)) }
        await Task.yield()
        session.recordHumanVerificationRequired(provider: "gemini")
        let after = try await waiter.value
        XCTAssertGreaterThan(after, before)
        session.recordHumanVerificationRequired(provider: "gemini")
        XCTAssertEqual(try session.modelChangeRevision(for: model), after)
        session.clearHumanVerificationRequired(provider: "gemini")
        XCTAssertGreaterThan(try session.modelChangeRevision(for: model), after)
        XCTAssertEqual(session.tabs.map(\.id), [human, model])
        XCTAssertEqual(session.tabs.map(\.documentGeneration), revisions)
        XCTAssertEqual(session.selectedTabID, human)
        for tab in session.tabs {
            let view = try XCTUnwrap(session.webView(for: tab.id))
            XCTAssertNil(view.url)
            XCTAssertFalse(view.isLoading)
            XCTAssertFalse(view.canGoBack)
        }
    }

    func testHumanCheckpointRenewsOncePerDocumentAndURLTransitionWithoutReplayingNavigation() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let human = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: human))
        let model = try session.createUnloadedModelTabForTesting()
        try session.installModelChangeSignal(tabID: model, ownerToken: UUID().uuidString,
                                             world: .world(name: "human-checkpoint-native-url"))
        let before = try session.modelChangeRevision(for: model)
        let url = try XCTUnwrap(URL(string: "https://www.google.com/sorry/index?fixture=first"))
        try await loadLocalFixture(view, at: url)
        let first = try XCTUnwrap(session.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertGreaterThan(try session.modelChangeRevision(for: model), before)
        view.navigationDelegate?.webView?(view, didCommit: nil)
        view.navigationDelegate?.webView?(view, didFinish: nil)
        session.recordHumanVerificationRequired(provider: "gemini")
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs["gemini"], first)

        // This fixture is supplied entirely from memory. Changing its same-origin
        // URL causes WebKit's native URL observation, with no website request.
        _ = try await view.evaluateJavaScript("history.replaceState(null, '', '/sorry/index?fixture=second')")
        let changedURL = try XCTUnwrap(URL(string: "https://www.google.com/sorry/index?fixture=second"))
        try await waitForNativeURL(view, at: changedURL)
        let second = try XCTUnwrap(session.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertNotEqual(second, first)
        session.clearHumanVerificationRequired(provider: "gemini")
        view.navigationDelegate?.webView?(view, didCommit: nil)
        view.navigationDelegate?.webView?(view, didFinish: nil)
        XCTAssertTrue(session.savedHumanVerificationProviders.isEmpty, "A duplicate callback for the cleared document must not renew its checkpoint")

        try await loadLocalFixture(view, at: changedURL)
        let reloaded = try XCTUnwrap(session.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertNotEqual(reloaded, second, "A new document at the same checkpoint URL must renew recovery's observation ID")
        XCTAssertEqual(session.tabs.map(\.id), [human, model])
        XCTAssertEqual(session.selectedTabID, human)
        XCTAssertEqual(view.url, changedURL)
        XCTAssertFalse(view.isLoading)
        XCTAssertNil(session.webView(for: model)?.url, "A human checkpoint must not navigate the model tab")
    }

    func testModelOwnedCheckpointURLDoesNotActAsAHumanObservation() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let model = try session.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(session.webView(for: model))
        try await loadLocalFixture(view, at: XCTUnwrap(URL(string: "https://google.com/sorry/index")))
        XCTAssertTrue(session.savedHumanVerificationProviders.isEmpty)
        XCTAssertTrue(session.humanTabs.isEmpty)
    }

    func testFailedProvisionalDelegateBoundaryCannotRenewTheOldHumanCheckpoint() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        let human = try session.createTab()
        let view = try XCTUnwrap(session.webView(for: human))
        let url = try XCTUnwrap(URL(string: "https://google.com/sorry/index?fixture=provisional-boundary"))
        try await loadLocalFixture(view, at: url)
        let checkpoint = try XCTUnwrap(session.savedHumanVerificationCheckpointIDs["gemini"])
        let generation = session.documentGeneration(for: human)
        let delegate = try XCTUnwrap(view.navigationDelegate)
        // Exercise the native delegate boundary deterministically while the
        // committed inline document remains unchanged. This does not claim a
        // real navigation failed or rely on WebKit's stop-versus-commit timing.
        delegate.webView?(view, didStartProvisionalNavigation: nil)
        XCTAssertNotEqual(session.documentGeneration(for: human), generation,
                          "The existing conservative model generation must still invalidate at provisional start")
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        delegate.webView?(view, didFailProvisionalNavigation: nil,
                          withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs["gemini"], checkpoint,
                       "A provisional failure callback cannot turn the old committed checkpoint into a new observation")
        XCTAssertFalse(session.tabs[0].isLoading)
        session.clearHumanVerificationRequired(provider: "gemini")
        // A nil commit callback and later refresh cannot supply a new document.
        delegate.webView?(view, didCommit: nil)
        delegate.webView?(view, didFinish: nil)
        await Task.yield()
        XCTAssertTrue(session.savedHumanVerificationProviders.isEmpty)
        XCTAssertEqual(view.url, url)
        XCTAssertEqual(session.tabs.map(\.id), [human])
    }

    private func loadLocalFixture(_ view: WKWebView, at url: URL) async throws {
        view.loadHTMLString("<!doctype html><title>Local checkpoint fixture</title><p>Fixture</p>", baseURL: url)
        try await waitForNativeURL(view, at: url)
    }

    private func waitForNativeURL(_ view: WKWebView, at url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while (view.isLoading || view.url != url), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        // URL KVO is deliberately delivered onto the main actor by the browser.
        await Task.yield()
        XCTAssertEqual(view.url, url)
        XCTAssertFalse(view.isLoading)
    }
}

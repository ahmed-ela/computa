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

    func testSettledHumanRecoveryIsOncePerCheckpointAndCommittedDocumentWithoutClearance() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        session.recordHumanVerificationRequired(provider: "gemini")
        let checkpoint = try XCTUnwrap(session.savedHumanVerificationCheckpointIDs["gemini"])
        var candidates: [EmbeddedBrowserSession.HumanVerificationRecoveryCandidate] = []
        session.onHumanVerificationRecoveryCandidate = { candidates.append($0) }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        try await loadLocalFixture(view, at: url)
        try await waitForRecovery { candidates.count == 1 }
        XCTAssertEqual(candidates.count, 1)
        let first = try XCTUnwrap(candidates.first)
        XCTAssertEqual(first.provider, "gemini"); XCTAssertEqual(first.checkpointID, checkpoint)
        XCTAssertTrue(session.isHumanVerificationRecoveryCandidateCurrent(first))
        view.navigationDelegate?.webView?(view, didCommit: nil)
        view.navigationDelegate?.webView?(view, didFinish: nil)
        await Task.yield()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        XCTAssertEqual(session.tabs.map(\.id), [id], "An event is an intent, never a provider probe or prompt")

        try await loadLocalFixture(view, at: url)
        try await waitForRecovery { candidates.count == 2 }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(first))
        let second = try XCTUnwrap(candidates.last)
        XCTAssertNotEqual(second.committedDocumentID, first.committedDocumentID)
        XCTAssertTrue(session.isHumanVerificationRecoveryCandidateCurrent(second))
        session.closeTab(id)
        XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(second))
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
    }

    func testPostDiscoveryFreshnessRequiresAbsentCheckpointWithoutChangingPreDiscoveryAuthority() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        session.recordHumanVerificationRequired(provider: "gemini")
        let checkpoint = try XCTUnwrap(session.savedHumanVerificationCheckpointIDs["gemini"])
        var candidates: [EmbeddedBrowserSession.HumanVerificationRecoveryCandidate] = []
        session.onHumanVerificationRecoveryCandidate = { candidates.append($0) }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        try await loadLocalFixture(view, at: url)
        try await waitForRecovery { candidates.count == 1 }
        let candidate = try XCTUnwrap(candidates.first)
        let generation = session.documentGeneration(for: id)

        XCTAssertTrue(session.isHumanVerificationRecoveryCandidateCurrent(candidate))
        XCTAssertFalse(session.isHumanVerificationRecoverySourceCurrentAfterDiscovery(candidate))
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs["gemini"], checkpoint,
                       "A freshness query must not clear the checkpoint")
        session.clearHumanVerificationRequired(provider: "gemini")
        XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(candidate),
                       "Post-discovery freshness must not renew the old probe authorization")
        XCTAssertTrue(session.isHumanVerificationRecoverySourceCurrentAfterDiscovery(candidate))
        XCTAssertEqual(session.documentGeneration(for: id), generation)
        XCTAssertEqual(session.tabs.map(\.id), [id])
        XCTAssertEqual(candidates.count, 1, "Neither predicate emits another recovery intent")

        session.recordHumanVerificationRequired(provider: "gemini")
        let replacement = try XCTUnwrap(session.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertNotEqual(replacement, checkpoint)
        XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(candidate))
        XCTAssertFalse(session.isHumanVerificationRecoverySourceCurrentAfterDiscovery(candidate),
                       "A new checkpoint must prevent consuming queued manual recovery")
        XCTAssertEqual(session.savedHumanVerificationCheckpointIDs["gemini"], replacement)
    }

    func testPostDiscoveryFreshnessRejectsRevokedHumanSourceWithNoCheckpoint() async throws {
        for fault in ["newDocument", "untrustedRoute", "provisional", "failed", "toolUsed", "closed", "shutdown"] {
            let session = EmbeddedBrowserSession(persistent: false)
            defer { session.shutdown() }
            session.recordHumanVerificationRequired(provider: "gemini")
            var candidates: [EmbeddedBrowserSession.HumanVerificationRecoveryCandidate] = []
            session.onHumanVerificationRecoveryCandidate = { candidates.append($0) }
            let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
            let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
            try await loadLocalFixture(view, at: url)
            try await waitForRecovery { candidates.count == 1 }
            let candidate = try XCTUnwrap(candidates.first)
            session.clearHumanVerificationRequired(provider: "gemini")
            XCTAssertTrue(session.isHumanVerificationRecoverySourceCurrentAfterDiscovery(candidate), fault)

            switch fault {
            case "newDocument": try await loadLocalFixture(view, at: url)
            case "untrustedRoute":
                try await loadLocalFixture(view, at: XCTUnwrap(URL(string: "https://example.invalid/local-fixture")))
            case "provisional": view.navigationDelegate?.webView?(view, didStartProvisionalNavigation: nil)
            case "failed":
                view.navigationDelegate?.webView?(view, didStartProvisionalNavigation: nil)
                view.navigationDelegate?.webView?(view, didFailProvisionalNavigation: nil,
                    withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
            case "toolUsed":
                _ = try session.prepareToolMutation(tabID: id, generation: XCTUnwrap(session.documentGeneration(for: id)))
            case "closed": session.closeTab(id)
            case "shutdown": session.shutdown()
            default: XCTFail("Unknown freshness fixture")
            }
            XCTAssertFalse(session.isHumanVerificationRecoverySourceCurrentAfterDiscovery(candidate), fault)
            XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(candidate), fault)
            XCTAssertNil(session.savedHumanVerificationCheckpointIDs["gemini"], "Freshness checks do not manufacture a checkpoint: \(fault)")
            XCTAssertEqual(candidates.count, 1, "No checkpoint means no automatic recovery probe intent: \(fault)")
        }
    }

    func testRealBackendBorrowAndReobserveRevokeRecoveryEvenAfterLeaseRelease() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        session.recordHumanVerificationRequired(provider: "gemini")
        var candidates: [EmbeddedBrowserSession.HumanVerificationRecoveryCandidate] = []
        session.onHumanVerificationRecoveryCandidate = { candidates.append($0) }
        let id = try session.createTab(), view = try XCTUnwrap(session.webView(for: id))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        try await loadLocalFixture(view, at: url)
        try await waitForRecovery { candidates.count == 1 }
        let first = try XCTUnwrap(candidates.last)
        let backend = EmbeddedBrowserTabTransport(session: session)
        let targets = try await backend.humanTargets()
        let target = try XCTUnwrap(targets.first { $0.targetID == id.uuidString })
        let broker = BrowserTabSessionBroker(transport: backend, browserGeneration: UUID(), ownership: .borrowed)
        let binding = try await broker.bindBorrowed(taskKey: "recovery-borrow-fixture", processIdentifier: 1, target: target)
        XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(first), "Binding performs a marked observation before publishing its lease")
        try await loadLocalFixture(view, at: url)
        try await waitForRecovery { candidates.count == 2 }
        let second = try XCTUnwrap(candidates.last)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(session.isHumanVerificationRecoveryCandidateCurrent(second))
        _ = try await broker.snapshot(taskKey: "recovery-borrow-fixture", binding: binding, bundleIdentifier: "fixture", query: nil)
        XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(second), "An old binding must reobserve the new document before input")
        try await broker.revoke(taskKey: "recovery-borrow-fixture", binding: binding)
        XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(second), "Release cannot restore a used document's recovery intent")
        try await loadLocalFixture(view, at: url)
        try await waitForRecovery { candidates.count == 3 }
        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(session.isHumanVerificationRecoveryCandidateCurrent(try XCTUnwrap(candidates.last)))
        XCTAssertNotNil(session.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertEqual(session.tabs.map(\.id), [id])
    }

    func testFailedNavigationAndModelOrToolPagesCannotOfferRecovery() async throws {
        let session = EmbeddedBrowserSession(persistent: false)
        defer { session.shutdown() }
        session.recordHumanVerificationRequired(provider: "gemini")
        var candidates: [EmbeddedBrowserSession.HumanVerificationRecoveryCandidate] = []
        session.onHumanVerificationRecoveryCandidate = { candidates.append($0) }
        let url = try XCTUnwrap(URL(string: "https://gemini.google.com/app"))
        let human = try session.createTab(), view = try XCTUnwrap(session.webView(for: human))
        try await loadLocalFixture(view, at: url)
        try await waitForRecovery { candidates.count == 1 }
        let initial = try XCTUnwrap(candidates.first)
        view.navigationDelegate?.webView?(view, didStartProvisionalNavigation: nil)
        view.navigationDelegate?.webView?(view, didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        view.navigationDelegate?.webView?(view, didFinish: nil)
        await Task.yield()
        XCTAssertFalse(session.isHumanVerificationRecoveryCandidateCurrent(initial))
        XCTAssertEqual(candidates.count, 1)
        let model = try session.createUnloadedModelTabForTesting()
        let tool = try session.createToolTab(url: XCTUnwrap(URL(string: "about:blank")))
        for id in [model, tool] { try await loadLocalFixture(XCTUnwrap(session.webView(for: id)), at: url) }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNotNil(session.savedHumanVerificationCheckpointIDs["gemini"])
    }

    private func waitForRecovery(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The native committed/settled recovery event did not arrive")
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

import AppKit
import AutomationCore
import WebKit
import XCTest
@testable import Computa

@MainActor
final class BrowserTerminationLifecycleTests: XCTestCase {
    private final class References {
        weak var sharedStore: WKWebsiteDataStore?
        weak var dedicatedStore: WKWebsiteDataStore?
        var views: [WeakView] = []
    }
    private final class WeakView {
        weak var value: WKWebView?
        init(_ value: WKWebView) { self.value = value }
    }
    private struct NoPermissions: AutomationPermissionClient {
        func current() -> AutomationPermissionSnapshot {
            .init(accessibility: .notGranted, screenRecording: .notGranted)
        }
        func requestAccessibility() -> AutomationPermissionSnapshot { current() }
        func requestScreenRecording() -> AutomationPermissionSnapshot { current() }
    }
    private func fixture(persistent: Bool) throws -> (EmbeddedBrowserSession, AppState) {
        let profile = UUID(), suite = "Computa.TerminationTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let session = EmbeddedBrowserSession(persistent: persistent, profileID: profile, defaults: defaults,
            cookieRetirementDirectory: directory.appendingPathComponent("cookies"),
            geminiDiagnosticDirectory: directory.appendingPathComponent("diagnostics"))
        let state = AppState(tasks: [], permissionClient: NoPermissions(), preferences: defaults,
                             browserSession: session, cookieMaintenanceOnlyLaunch: false)
        addTeardownBlock { @MainActor in
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        if persistent { removeProfileAfterTest(profile) }
        return (session, state)
    }
    private func removeProfileAfterTest(_ id: UUID) {
        addTeardownBlock { @MainActor in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let bootstrap = WKWebView(frame: .zero, configuration: configuration)
            if await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id) {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
            }
            withExtendedLifetime(bootstrap) {}
        }
    }
    private func waitForViewRelease(_ references: References) async throws {
        for _ in 0..<40 where references.views.contains(where: { $0.value != nil }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(references.views.allSatisfy { $0.value == nil }, "Termination retention must never keep a page alive")
    }

    func testTerminationPreparationDoesNotCreateProfilesOrRetainPrivateStores() async throws {
        let (unused, unusedState) = try fixture(persistent: true)
        let unusedDelegate = ComputaAppDelegate()
        unusedDelegate.state = unusedState
        unusedDelegate.prepareBrowserProfilesForTermination()
        XCTAssertTrue(unused.persistentDataStoresForApplicationTermination.isEmpty)
        XCTAssertTrue(unused.tabs.isEmpty)
        _ = await unusedState.shutdownRuntime()

        let (privateSession, privateState) = try fixture(persistent: false)
        let delegate = ComputaAppDelegate()
        delegate.state = privateState
        let references = References()
        try autoreleasepool {
            let tab = try privateSession.createTab()
            let view = try XCTUnwrap(privateSession.webView(for: tab))
            references.views = [WeakView(view)]
            references.sharedStore = view.configuration.websiteDataStore
        }
        delegate.prepareBrowserProfilesForTermination()
        XCTAssertTrue(privateSession.persistentDataStoresForApplicationTermination.isEmpty)
        _ = await privateState.shutdownRuntime()
        try await waitForViewRelease(references)
        XCTAssertNil(references.sharedStore)
        withExtendedLifetime(delegate) {}
    }

    func testApplicationTerminationRetainsProfilesWhileReleasingAllPages() async throws {
        let (session, state) = try fixture(persistent: true)
        var delegate: ComputaAppDelegate? = ComputaAppDelegate()
        delegate?.state = state
        let references = References()
        try autoreleasepool {
            let shared = try session.createTab()
            let owned = try session.createUnloadedModelTabForTesting()
            let dedicated = try session.openKimiModelSignInForTesting()
            let dedicatedID = try XCTUnwrap(session.kimiModelProfileID)
            removeProfileAfterTest(dedicatedID)
            let dedicatedOwned = try session.createUnloadedKimiModelTabForTesting(profileID: dedicatedID)
            references.views = try [shared, owned, dedicated, dedicatedOwned].map {
                WeakView(try XCTUnwrap(session.webView(for: $0)))
            }
            references.sharedStore = session.webView(for: shared)?.configuration.websiteDataStore
            references.dedicatedStore = session.webView(for: dedicated)?.configuration.websiteDataStore
            let profiles = session.persistentDataStoresForApplicationTermination
            XCTAssertEqual(profiles.count, 2)
            XCTAssertTrue(profiles.contains { $0 === references.sharedStore })
            XCTAssertTrue(profiles.contains { $0 === references.dedicatedStore })
        }
        delegate?.prepareBrowserProfilesForTermination()
        _ = await state.shutdownRuntime()
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertThrowsError(try session.createTab())
        try await waitForViewRelease(references)
        XCTAssertNotNil(references.sharedStore, "The delegate must retain the shared profile after browser shutdown")
        XCTAssertNotNil(references.dedicatedStore)
        delegate = nil
        for _ in 0..<40 where references.sharedStore != nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(references.sharedStore, "The termination owner must not retain stores globally")
    }

    func testOrdinaryShutdownDoesNotRetainTheSharedProfile() async throws {
        let (session, state) = try fixture(persistent: true)
        let delegate = ComputaAppDelegate()
        delegate.state = state
        let references = References()
        try autoreleasepool {
            let tab = try session.createTab()
            let view = try XCTUnwrap(session.webView(for: tab))
            references.views = [WeakView(view)]
            references.sharedStore = view.configuration.websiteDataStore
        }
        _ = await state.shutdownRuntime()
        try await waitForViewRelease(references)
        for _ in 0..<40 where references.sharedStore != nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(references.sharedStore, "Ordinary/test shutdown must not acquire application-termination retention")
        withExtendedLifetime(delegate) {}
    }
}

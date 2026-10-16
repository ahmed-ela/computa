import Darwin
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor final class ChatGPTTemporaryCookieRetirementTests: XCTestCase {
    private let owned = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let canonical = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let unrelated = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

    func testOnlyStrictNativeChatGPTRoutesAreRetainedAndPromotionKeepsBoth() {
        var routes = ChatGPTTemporaryConversationRoutes()
        for text in ["http://chatgpt.com/c/\(owned)", "https://other.test/c/\(owned)",
                     "https://chatgpt.com.evil.test/c/\(owned)", "https://chatgpt.com/c/fixture",
                     "https://chatgpt.com/?conversation=\(owned)", "https://user@chatgpt.com/c/\(owned)"] {
            routes.observe(URL(string: text))
        }
        XCTAssertTrue(routes.candidates.isEmpty)
        routes.observe(URL(string: "https://chatgpt.com/c/local-chatgpt%3A" + owned.uuidString.lowercased()))
        routes.observe(URL(string: "https://chatgpt.com/c/" + canonical.uuidString.lowercased() + "?temporary-chat=true"))
        routes.observe(URL(string: "https://chatgpt.com/c/" + unrelated.uuidString.lowercased()))
        XCTAssertEqual(routes.candidates, [owned, canonical])
    }

    func testRetirementDeletesOnlyRegisteredExactCookieIdentitiesAndIsIdempotent() async throws {
        let store = RetirementCookieStore()
        store.cookies = try [cookie(owned), cookie(owned, marker: true), cookie(unrelated), cookie(unrelated, marker: true),
                             cookie(owned, domain: "other.test"), cookie(owned, path: "/other"), authCookie()]
        let retirement = ChatGPTTemporaryCookieRetirement(store: store, protection: { [] })
        XCTAssertTrue(retirement.registerClosedOwnedIDs([owned]))
        await assertSettlement(retirement)
        XCTAssertEqual(store.deletes.count, 2)
        XCTAssertEqual(store.cookies.count, 5)
        XCTAssertTrue(store.cookies.contains { $0.name == "auth_fixture" && $0.value == "PRIVATE_AUTH_VALUE" })
        XCTAssertTrue(retirement.registerClosedOwnedIDs([owned]))
        await assertSettlement(retirement)
        XCTAssertEqual(store.deletes.count, 2)
        retirement.stop()
    }

    func testProtectedAndUnknownInventoriesDeferWithoutDeletingAndResumeAfterRelease() async throws {
        let store = RetirementCookieStore(); store.cookies = try [cookie(owned), authCookie()]
        var protection: Set<UUID>? = [owned]
        let retirement = ChatGPTTemporaryCookieRetirement(store: store, protection: { protection })
        XCTAssertTrue(retirement.registerClosedOwnedIDs([owned]))
        await assertSettlement(retirement)
        XCTAssertTrue(store.deletes.isEmpty)
        protection = nil; store.onChange?()
        await assertSettlement(retirement, expected: false)
        XCTAssertTrue(store.deletes.isEmpty)
        protection = []; store.onChange?()
        await assertSettlement(retirement)
        XCTAssertEqual(store.deletes.count, 1)
        retirement.stop()
    }

    func testWaiterDeadlineAndCancellationNeverReleaseAnIssuedCallbackPermit() async throws {
        let store = RetirementCookieStore(); store.cookies = try [cookie(owned)]; store.holdReads = true; store.holdDeletes = true
        let retirement = ChatGPTTemporaryCookieRetirement(store: store, protection: { [] })
        XCTAssertTrue(retirement.registerClosedOwnedIDs([owned]))
        await assertSettlement(retirement, expected: false, wait: .milliseconds(25))
        XCTAssertTrue(retirement.hasPendingCallback); XCTAssertEqual(store.reads, 1)
        let waiter = Task { await retirement.settle(until: .now + .seconds(2)) }
        await Task.yield(); waiter.cancel()
        let cancelled = await waiter.value; XCTAssertFalse(cancelled)
        XCTAssertTrue(retirement.hasPendingCallback); XCTAssertEqual(store.reads, 1)
        store.releaseRead(twice: true)
        XCTAssertEqual(store.deletes.count, 1); XCTAssertTrue(retirement.hasPendingCallback)
        await assertSettlement(retirement, expected: false, wait: .milliseconds(25))
        XCTAssertEqual(store.reads, 1, "A timed-out delete cannot admit another read")
        store.holdReads = false; store.releaseDelete(twice: true)
        await assertSettlement(retirement)
        XCTAssertEqual(store.deletes.count, 1); XCTAssertFalse(retirement.hasPendingCallback)
        retirement.stop()
    }

    func testCookieEventsRetireLateWritersOnlyForDurablyRegisteredIDs() async throws {
        let fixture = try RetirementRegistryFixture(); defer { fixture.remove() }
        let store = RetirementCookieStore(); store.cookies = try [cookie(owned)]
        let first = ChatGPTTemporaryCookieRetirement(store: store, registry: fixture.registry, protection: { [] })
        XCTAssertTrue(first.registerClosedOwnedIDs([owned]))
        await assertSettlement(first); first.stop()
        store.cookies = try [cookie(owned), cookie(owned, marker: true), cookie(unrelated), authCookie()]
        let restarted = ChatGPTTemporaryCookieRetirement(store: store, registry: fixture.registry, protection: { [] })
        await assertSettlement(restarted)
        XCTAssertEqual(store.cookies.count, 2)
        store.cookies.append(try cookie(owned)); store.onChange?()
        await assertSettlement(restarted)
        XCTAssertEqual(store.cookies.count, 2)
        XCTAssertEqual(restarted.registeredCount, 1)
        restarted.stop()
    }

    func testCookieChangeWhileAReadIsPendingIsNotLost() async throws {
        let store = RetirementCookieStore(); store.holdReads = true
        let retirement = ChatGPTTemporaryCookieRetirement(store: store, protection: { [] })
        XCTAssertTrue(retirement.registerClosedOwnedIDs([owned]))
        await assertSettlement(retirement, expected: false, wait: .milliseconds(25))
        store.cookies = try [cookie(owned)]; store.onChange?()
        store.holdReads = false; store.releaseRead(snapshot: [])
        await assertSettlement(retirement)
        XCTAssertEqual(store.deletes.count, 1); XCTAssertTrue(store.cookies.isEmpty)
        retirement.stop()
    }

    func testUnknownProtectionAfterIssuedDeleteStopsFurtherWritesUntilCallbackSettles() async throws {
        let store = RetirementCookieStore(); store.cookies = try [cookie(owned), cookie(owned, marker: true), authCookie()]
        store.holdDeletes = true
        var protection: Set<UUID>? = []
        let retirement = ChatGPTTemporaryCookieRetirement(store: store, protection: { protection })
        XCTAssertTrue(retirement.registerClosedOwnedIDs([owned]))
        await assertSettlement(retirement, expected: false, wait: .milliseconds(25))
        XCTAssertEqual(store.deletes.count, 1)
        protection = nil
        XCTAssertFalse(retirement.canAdmit)
        await assertSettlement(retirement, expected: false, wait: .milliseconds(25))
        XCTAssertEqual(store.deletes.count, 1)
        store.releaseDelete()
        await assertSettlement(retirement, expected: false)
        XCTAssertTrue(retirement.canAdmit)
        XCTAssertEqual(store.deletes.count, 1)
        XCTAssertTrue(store.cookies.contains { $0.name.hasPrefix("history_off_") })
        XCTAssertTrue(store.cookies.contains { $0.name == "auth_fixture" })
        retirement.stop()
    }

    func testRegistryRequiresPrivateUnlinkedBoundedDataAndExpiresOwnership() throws {
        let fixture = try RetirementRegistryFixture(); defer { fixture.remove() }
        let now = Date()
        XCTAssertEqual(fixture.registry.load(now: now), [:])
        XCTAssertFalse(fixture.registry.save(Dictionary(uniqueKeysWithValues: (0...4_096).map { _ in (UUID(), now) })))
        XCTAssertTrue(fixture.registry.save([owned: now, unrelated: now.addingTimeInterval(-ChatGPTTemporaryCookieRetirement.lifetime - 1)]))
        XCTAssertEqual(Set(try XCTUnwrap(fixture.registry.load(now: now)).keys), [owned])
        let file = fixture.directory.appendingPathComponent("owned.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains("conv_key"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertNil(fixture.registry.load(now: now)); XCTAssertFalse(fixture.registry.save([owned: now]))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let linkPath = fixture.directory.appendingPathComponent("linked")
        XCTAssertEqual(link(file.path, linkPath.path), 0)
        XCTAssertNil(fixture.registry.load(now: now)); XCTAssertFalse(fixture.registry.save([owned: now]))
    }

    func testUnavailableOwnershipRegistryDisablesDeletionWithoutBlockingAdmission() async throws {
        let fixture = try RetirementRegistryFixture(); defer { fixture.remove() }
        XCTAssertTrue(fixture.registry.save([owned: Date()]))
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
            ofItemAtPath: fixture.directory.appendingPathComponent("owned.json").path)
        let store = RetirementCookieStore(); store.cookies = try [cookie(owned), authCookie()]
        let retirement = ChatGPTTemporaryCookieRetirement(store: store, registry: fixture.registry, protection: { [] })
        await assertSettlement(retirement, expected: false)
        XCTAssertFalse(retirement.registerClosedOwnedIDs([canonical]))
        XCTAssertTrue(retirement.canAdmit)
        XCTAssertFalse(retirement.hasPendingCallback)
        XCTAssertEqual(store.reads, 0); XCTAssertTrue(store.deletes.isEmpty)
        XCTAssertEqual(store.cookies.count, 2)
        retirement.stop()
    }

    func testExclusiveSuspensionNeverStartsOrChainsRetirementBeforeReadOnlyMaintenance() async throws {
        let fixture = try RetirementRegistryFixture(); defer { fixture.remove() }
        XCTAssertTrue(fixture.registry.save([owned: Date()]))
        let store = RetirementCookieStore(); store.cookies = try [cookie(owned), cookie(owned, marker: true), authCookie()]
        store.holdReads = true
        let retirement = ChatGPTTemporaryCookieRetirement(store: store, registry: fixture.registry,
            initiallySuspended: true, protection: { [] })
        await assertSettlement(retirement)
        store.onChange?()
        await Task.yield()
        XCTAssertEqual(store.reads, 0); XCTAssertTrue(store.deletes.isEmpty)

        XCTAssertTrue(retirement.setSuspended(false))
        await assertSettlement(retirement, expected: false, wait: .milliseconds(25))
        XCTAssertEqual(store.reads, 1); XCTAssertTrue(retirement.hasPendingCallback)
        XCTAssertTrue(retirement.setSuspended(true))
        store.releaseRead()
        await assertSettlement(retirement, expected: false)
        XCTAssertEqual(store.reads, 1); XCTAssertTrue(store.deletes.isEmpty)
        XCTAssertFalse(retirement.hasPendingCallback); XCTAssertFalse(retirement.canAdmit)

        store.holdReads = false; store.holdDeletes = true
        XCTAssertTrue(retirement.setSuspended(false))
        await assertSettlement(retirement, expected: false, wait: .milliseconds(25))
        XCTAssertEqual(store.deletes.count, 1)
        let readsBeforeDeleteSettled = store.reads
        XCTAssertTrue(retirement.setSuspended(true))
        store.releaseDelete()
        await assertSettlement(retirement, expected: false)
        XCTAssertEqual(store.deletes.count, 1); XCTAssertEqual(store.reads, readsBeforeDeleteSettled)
        XCTAssertFalse(retirement.hasPendingCallback)
        XCTAssertTrue(store.cookies.contains { $0.name.hasPrefix("history_off_") })

        store.holdDeletes = false
        XCTAssertTrue(retirement.setSuspended(false))
        await assertSettlement(retirement)
        XCTAssertEqual(store.deletes.count, 2)
        XCTAssertEqual(store.cookies.map(\.name), ["auth_fixture"])
        retirement.stop()
    }

    func testExclusiveStartupLeaseBlocksAllTabAdmissionUntilOperationActuallyReturns() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        var release: CheckedContinuation<Void, Never>?
        let operation = Task { @MainActor in
            await browser.withExclusiveCookieMaintenance { _, _, isCurrent in
                XCTAssertTrue(isCurrent())
                XCTAssertEqual(browser.cookieMaintenanceProtectedIDs(), [])
                do { _ = try browser.createTab(); XCTFail("Exclusive maintenance admitted a tab") } catch {}
                await withCheckedContinuation { release = $0 }
                XCTAssertTrue(isCurrent())
                return true
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while release == nil {
            guard ContinuousClock.now < deadline else { XCTFail("Lease did not start"); operation.cancel(); browser.shutdown(); return }
            await Task.yield()
        }
        operation.cancel()
        XCTAssertThrowsError(try browser.createTab(), "Cancellation cannot release an outstanding native operation")
        release?.resume(); release = nil
        let completed = await operation.value
        XCTAssertEqual(completed, true)
        let tab = try browser.createTab(); browser.closeTab(tab); browser.shutdown()
    }

    func testNonpersistentNativeBrowserClosesProvenViewBeforeRetiringAndProtectsResumeOwner() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        let id = try browser.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(browser.webView(for: id))
        view.loadHTMLString("<html><body>offline fixture</body></html>", baseURL: URL(string: "https://chatgpt.com/"))
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isLoading || view.url == nil {
            guard ContinuousClock.now < deadline else { XCTFail("Local fixture did not settle"); browser.shutdown(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let owner = UUID().uuidString
        try browser.installModelChangeSignal(tabID: id, ownerToken: owner,
            world: WKContentWorld.world(name: "cookie-retirement-fixture"), originHost: "chatgpt.com")
        let generation = try XCTUnwrap(browser.documentGeneration(for: id))
        browser.recordOwnedTemporaryChatGPTRoutes([unrelated], tabID: id, view: view, ownerToken: owner,
            generation: generation, firstUserFingerprint: "invalid")
        let store = view.configuration.websiteDataStore.httpCookieStore
        for item in try [cookie(owned), cookie(owned, marker: true), cookie(unrelated), authCookie()] { await store.setCookie(item) }
        browser.recordOwnedTemporaryChatGPTRoutes([owned], tabID: id, view: view, ownerToken: owner,
            generation: generation, firstUserFingerprint: String(repeating: "a", count: 64))
        let resumeOwner = UUID(); browser.holdChatGPTConversationResumeIDs([owned], owner: resumeOwner)
        browser.closeTab(id)
        XCTAssertNil(browser.webView(for: id))
        let protectedSettled = await browser.settleChatGPTTemporaryCookieRetirement(until: .now + .seconds(2))
        XCTAssertTrue(protectedSettled)
        let protectedCookies = await store.allCookies()
        XCTAssertEqual(protectedCookies.count, 4)
        let humanID = try browser.createTab()
        let human = try XCTUnwrap(browser.webView(for: humanID))
        human.loadHTMLString("<html><body>human offline fixture</body></html>", baseURL: URL(string: "https://chatgpt.com/"))
        let humanDeadline = ContinuousClock.now + .seconds(5)
        while human.isLoading || human.url == nil {
            guard ContinuousClock.now < humanDeadline else { XCTFail("Human fixture did not settle"); browser.shutdown(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        browser.releaseChatGPTConversationResumeIDs(owner: resumeOwner)
        let deferred = await browser.settleChatGPTTemporaryCookieRetirement(until: .now + .seconds(2))
        XCTAssertFalse(deferred, "A live human ChatGPT SPA defers the entire sweep")
        let admission = await browser.admitChatGPTAfterCookieCallbacks(until: .now + .seconds(2))
        XCTAssertTrue(admission, "Deferral cannot block normal provider admission after callbacks settle")
        let whileHumanOpen = await store.allCookies()
        XCTAssertEqual(whileHumanOpen.count, 4)
        browser.closeTab(humanID)
        let releasedSettled = await browser.settleChatGPTTemporaryCookieRetirement(until: .now + .seconds(2))
        XCTAssertTrue(releasedSettled)
        let remaining = await store.allCookies()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains { $0.name == "auth_fixture" && $0.value == "PRIVATE_AUTH_VALUE" })
        browser.shutdown()
    }

    private func assertSettlement(_ retirement: ChatGPTTemporaryCookieRetirement, expected: Bool = true,
                                  wait: Duration = .seconds(2), file: StaticString = #filePath, line: UInt = #line) async {
        let settled = await retirement.settle(until: .now + wait)
        XCTAssertEqual(settled, expected, file: file, line: line)
    }
    private func cookie(_ id: UUID, marker: Bool = false, domain: String = "chatgpt.com", path: String = "/") throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: path,
            .name: (marker ? "history_off_" : "conv_key_") + id.uuidString.lowercased(), .value: marker ? "1" : "PRIVATE_VALUE"]))
    }
    private func authCookie() throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.domain: "chatgpt.com", .path: "/", .name: "auth_fixture", .value: "PRIVATE_AUTH_VALUE"]))
    }
}

@MainActor private final class RetirementCookieStore: ChatGPTTemporaryCookieStore {
    var onChange: (@MainActor () -> Void)?
    var cookies: [HTTPCookie] = []
    var holdReads = false, holdDeletes = false
    var reads = 0
    var deletes: [String] = []
    private var readReply: (@MainActor ([HTTPCookie]) -> Void)?
    private var deleteReply: (@MainActor () -> Void)?
    func read(_ completion: @escaping @MainActor ([HTTPCookie]) -> Void) {
        reads += 1
        if holdReads { readReply = completion } else { completion(cookies) }
    }
    func delete(_ cookie: HTTPCookie, completion: @escaping @MainActor () -> Void) {
        deletes.append(cookie.name)
        cookies.removeAll { $0.domain == cookie.domain && $0.path == cookie.path && $0.name == cookie.name }
        if holdDeletes { deleteReply = completion } else { completion() }
    }
    func releaseRead(twice: Bool = false, snapshot: [HTTPCookie]? = nil) {
        let callback = readReply; readReply = nil; let value = snapshot ?? cookies
        callback?(value); if twice { callback?(value) }
    }
    func releaseDelete(twice: Bool = false) {
        let callback = deleteReply; deleteReply = nil
        callback?(); if twice { callback?() }
    }
    func stopObserving() { onChange = nil }
}

private struct RetirementRegistryFixture {
    let directory: URL
    let registry: ChatGPTTemporaryCookieRegistry
    init() throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(physical) }
        directory = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("computa-cookie-retirement-" + UUID().uuidString, isDirectory: true)
        registry = ChatGPTTemporaryCookieRegistry(directory: directory, profileID: UUID())
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
